//==============================================================================
// conv_controller.sv  --  Descriptor-chained GEMM controller (REFERENCE).
//
// Conv is lowered to GEMM by the host (im2col); each descriptor describes one
// GEMM:  C[M,N] = A[M,K] * W[N,K]^T, then bias + requant + activation.
//
// Schedule (weight-stationary, tiled):
//   for each descriptor in [desc_base .. desc_base + desc_count):
//     load descriptor (64 B)
//     for n_tile in ceil(N/OC_LANES):
//       DMA weights[OC_LANES][K]      -> weight_mem  (col-major: col*KC + kc)
//       DMA bias[OC_LANES]            -> bias_mem
//       for m_tile in ceil(M/M_TILE):
//         DMA A rows (M_TILE x K)     -> act_mem     (m*KC + kc)
//         clear accm[*]
//         for kc in 0..KC-1:
//           load mac_tile weights for kc (OC_LANES cols)
//           for m in 0..M_TILE-1: accm[m] += dot(act_mem[m,kc], W[:,kc])
//         for m: vector_unit(accm[m], bias) -> q_mem[m]
//         DMA q_mem -> C[ m_tile, n_tile ]
//
// Constraints (host must tile to fit): K <= MAX_K, OC tile = OC_LANES,
// M tiled by M_TILE. K-splitting across descriptors (partial sums) is a host
// concern (accumulate in DDR) -- not handled here.
//
// STATUS: structurally complete, NOT YET co-simulated. The datapath blocks it
// drives (mac_tile, vector_unit) are unit-tested; this orchestration FSM needs
// RTL simulation against golden vectors before trusting it on hardware.
//==============================================================================

module conv_controller
  import accel_pkg::*;
#(
  parameter int M_TILE = 32,
  parameter int MAX_K  = 1024,                 // max GEMM depth per descriptor
  localparam int KC_MAX = MAX_K / IC_LANES     // max IC_LANES-chunks
)(
  input  logic clk,
  input  logic rst_n,

  // control
  input  logic        start,
  input  logic [31:0] desc_base,
  input  logic [31:0] desc_count,
  output logic        busy,
  output logic        done,
  output logic        err,

  // read-master command/stream
  output logic        rd_req,
  output logic [31:0] rd_addr,
  output logic [15:0] rd_len,
  input  logic        rd_busy,
  input  logic        rd_done,
  input  logic [AXI_DATA_W-1:0] rd_data,
  input  logic        rd_valid,
  output logic        rd_ready,

  // write-master command/stream
  output logic        wr_req,
  output logic [31:0] wr_addr,
  output logic [15:0] wr_len,
  input  logic        wr_busy,
  input  logic        wr_done,
  output logic [AXI_DATA_W-1:0] wr_data,
  output logic        wr_valid,
  input  logic        wr_ready
);

  // -------- on-chip memories --------
  // weight_mem: 128-bit words (IC_LANES INT8), col-major  [col*KC + kc]
  (* ram_style="block" *) logic [AXI_DATA_W-1:0] weight_mem [0:OC_LANES*KC_MAX-1];
  // act_mem: 128-bit words, [m*KC + kc]
  (* ram_style="block" *) logic [AXI_DATA_W-1:0] act_mem    [0:M_TILE*KC_MAX-1];
  // bias_mem: INT32 per output channel
  logic signed [ACC_W-1:0] bias_mem [0:OC_LANES-1];
  // accumulators / outputs (registers for simple parallel access)
  logic signed [ACC_W-1:0] accm  [0:M_TILE-1][0:OC_LANES-1];
  logic signed [ACT_W-1:0] q_mem [0:M_TILE-1][0:OC_LANES-1];

  // -------- descriptor --------
  logic [511:0] desc_raw;             // assembled from 4 x 128-bit DMA beats
  layer_desc_t  desc;
  assign desc = layer_desc_t'(desc_raw);
  logic [31:0] desc_idx;
  logic [15:0] KC;        // ceil(K/IC_LANES)
  logic [15:0] NT, MT;    // tile counts
  logic [15:0] nt, mt;    // current tiles
  logic [15:0] kc;
  logic [15:0] mi;        // pixel within m_tile

  // -------- FSM --------
  typedef enum logic [4:0] {
    S_IDLE, S_DESC_REQ, S_DESC_RX, S_DERIVE,
    S_WT_REQ, S_WT_RX, S_BIAS_REQ, S_BIAS_RX,
    S_ACT_REQ, S_ACT_RX,
    S_LOADW, S_MAC, S_MAC_WAIT,
    S_REQ_INIT, S_REQ_RUN, S_REQ_WAIT,
    S_WB_REQ, S_WB_TX,
    S_NEXT_M, S_NEXT_N, S_NEXT_DESC, S_DONE, S_ERR
  } st_e;
  st_e st;

  assign busy = (st != S_IDLE);

  // stream write index counters for RX phases
  logic [15:0] rx_cnt;       // generic beat counter
  logic [15:0] rx_total;

  // mac_tile interface
  logic                      mt_wload;
  logic [$clog2(OC_LANES)-1:0] mt_wcol;
  logic [IC_LANES*WGT_W-1:0] mt_wdata;
  logic                      mt_avalid, mt_afirst, mt_alast;
  logic [IC_LANES*ACT_W-1:0] mt_adata;
  logic                      mt_rvalid, mt_dvalid;
  logic signed [ACC_W-1:0]   mt_acc [OC_LANES];
  logic signed [ACC_W-1:0]   mt_dot [OC_LANES];

  mac_tile u_mac (
    .clk(clk), .rst_n(rst_n),
    .w_load(mt_wload), .w_col(mt_wcol), .w_data(mt_wdata),
    .a_valid(mt_avalid), .a_first(mt_afirst), .a_last(mt_alast), .a_data(mt_adata),
    .r_valid(mt_rvalid), .acc(mt_acc),
    .dot_valid(mt_dvalid), .dot(mt_dot)
  );

  // vector_unit interface
  logic                    vu_in_valid, vu_out_valid;
  logic signed [ACC_W-1:0] vu_acc  [OC_LANES];
  logic signed [ACC_W-1:0] vu_bias [OC_LANES];
  logic signed [ACT_W-1:0] vu_q    [OC_LANES];

  vector_unit u_vec (
    .clk(clk), .rst_n(rst_n),
    .in_valid(vu_in_valid), .acc(vu_acc), .bias(vu_bias),
    .requant_mult(desc.requant_mult), .requant_shift(desc.requant_shift[4:0]),
    .act_type(desc.act_type),
    .out_valid(vu_out_valid), .q(vu_q)
  );

  // helpers
  function automatic logic [15:0] ceil_div(input logic [31:0] a, input int b);
    ceil_div = (a + b - 1) / b;
  endfunction

  // pipeline registers for MAC accumulate (act read -> dot -> accumulate)
  logic [15:0] mac_mi_d, mac_mi_d2;
  logic        mac_vld_d, mac_vld_d2;
  logic        mac_first_d, mac_first_d2;

  // requant loop pipeline
  logic [15:0] req_mi_d;
  logic        req_vld_d;

  integer i;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE; done <= 0; err <= 0;
      rd_req <= 0; wr_req <= 0; wr_valid <= 0; rd_ready <= 0;
      mt_wload <= 0; mt_avalid <= 0; mt_afirst <= 0; mt_alast <= 0;
      vu_in_valid <= 0;
      desc_idx <= 0; nt <= 0; mt <= 0; kc <= 0; mi <= 0; rx_cnt <= 0;
      mac_vld_d <= 0; mac_vld_d2 <= 0; req_vld_d <= 0;
    end else begin
      // default pulses
      done <= 0; rd_req <= 0; wr_req <= 0;
      mt_wload <= 0; mt_avalid <= 0; vu_in_valid <= 0;

      case (st)
        // ---- idle / kickoff ----
        S_IDLE: if (start) begin desc_idx <= 0; st <= S_DESC_REQ; end

        // ---- descriptor fetch (64 B = 4 beats) ----
        S_DESC_REQ: begin
          rd_addr <= desc_base + desc_idx * DESC_BYTES;
          rd_len  <= 16'd4;
          rd_req  <= 1'b1;
          rd_ready<= 1'b1;
          rx_cnt  <= 0;
          st      <= S_DESC_RX;
        end
        S_DESC_RX: begin
          rd_ready <= 1'b1;
          if (rd_valid) begin
            // assemble 512-bit descriptor, beat0 -> [127:0] .. beat3 -> [511:384]
            desc_raw[rx_cnt*128 +: 128] <= rd_data;
            rx_cnt <= rx_cnt + 1;
          end
          if (rd_done) begin rd_ready <= 0; st <= S_DERIVE; end
        end
        S_DERIVE: begin
          KC <= ceil_div(desc.K, IC_LANES);
          NT <= ceil_div(desc.N, OC_LANES);
          MT <= ceil_div(desc.M, M_TILE);
          nt <= 0;
          if (desc.K > MAX_K) st <= S_ERR; else st <= S_WT_REQ;
        end

        // ---- weights for this n-tile : OC_LANES cols * KC beats ----
        S_WT_REQ: begin
          rd_addr  <= desc.wt_addr + nt * (OC_LANES * desc.K[15:0]);
          rd_len   <= OC_LANES * KC;        // 128-bit beats (16 weights each)
          rd_req   <= 1'b1; rd_ready <= 1'b1; rx_cnt <= 0;
          rx_total <= OC_LANES * KC;
          st       <= S_WT_RX;
        end
        S_WT_RX: begin
          rd_ready <= 1'b1;
          if (rd_valid) begin
            weight_mem[rx_cnt] <= rd_data;
            rx_cnt <= rx_cnt + 1;
          end
          if (rd_done) begin rd_ready <= 0; st <= S_BIAS_REQ; end
        end

        // ---- bias : OC_LANES INT32 = OC_LANES*4 bytes = OC_LANES/4 beats ----
        S_BIAS_REQ: begin
          rd_addr  <= desc.bias_addr + nt * (OC_LANES*4);
          rd_len   <= (OC_LANES*4)/(AXI_DATA_W/8);   // 32*4/16 = 8 beats
          rd_req   <= 1'b1; rd_ready <= 1'b1; rx_cnt <= 0;
          st       <= S_BIAS_RX;
        end
        S_BIAS_RX: begin
          rd_ready <= 1'b1;
          if (rd_valid) begin
            // 4 INT32 per 128-bit beat
            bias_mem[rx_cnt*4+0] <= $signed(rd_data[ 31:  0]);
            bias_mem[rx_cnt*4+1] <= $signed(rd_data[ 63: 32]);
            bias_mem[rx_cnt*4+2] <= $signed(rd_data[ 95: 64]);
            bias_mem[rx_cnt*4+3] <= $signed(rd_data[127: 96]);
            rx_cnt <= rx_cnt + 1;
          end
          if (rd_done) begin rd_ready <= 0; mt <= 0; st <= S_ACT_REQ; end
        end

        // ---- activations for this m-tile : M_TILE rows, KC beats each ----
        // (rows are strided in DDR; one read command per pixel)
        S_ACT_REQ: begin
          rd_addr  <= desc.in_addr + (mt*M_TILE + mi) * desc.in_row_stride;
          rd_len   <= KC;
          rd_req   <= 1'b1; rd_ready <= 1'b1; rx_cnt <= 0;
          st       <= S_ACT_RX;
        end
        S_ACT_RX: begin
          rd_ready <= 1'b1;
          if (rd_valid) begin
            act_mem[mi*KC + rx_cnt] <= rd_data;
            rx_cnt <= rx_cnt + 1;
          end
          if (rd_done) begin
            rd_ready <= 0;
            if (mi == M_TILE-1) begin mi <= 0; kc <= 0; st <= S_LOADW; end
            else                begin mi <= mi + 1; st <= S_ACT_REQ; end
          end
        end

        // ---- load mac_tile weights for current kc (OC_LANES cycles) ----
        S_LOADW: begin
          mt_wload <= 1'b1;
          mt_wcol  <= rx_cnt[$clog2(OC_LANES)-1:0];
          mt_wdata <= weight_mem[rx_cnt*KC + kc][IC_LANES*WGT_W-1:0];
          if (rx_cnt == OC_LANES-1) begin rx_cnt <= 0; mi <= 0; st <= S_MAC; end
          else rx_cnt <= rx_cnt + 1;
        end

        // ---- stream M_TILE activations for this kc, accumulate ----
        S_MAC: begin
          mt_avalid <= 1'b1;
          mt_afirst <= (kc == 0);     // not used (we accumulate in accm) but kept
          mt_adata  <= act_mem[mi*KC + kc][IC_LANES*ACT_W-1:0];
          if (mi == M_TILE-1) begin mi <= 0; st <= S_MAC_WAIT; end
          else mi <= mi + 1;
        end
        S_MAC_WAIT: begin
          // drain pipeline (dot_valid lags a_valid by 1)
          if (!mac_vld_d2) begin
            if (kc == KC-1) begin mi <= 0; st <= S_REQ_INIT; end
            else begin kc <= kc + 1; rx_cnt <= 0; st <= S_LOADW; end
          end
        end

        // ---- requantize: feed accm[m] through vector_unit ----
        S_REQ_INIT: begin mi <= 0; st <= S_REQ_RUN; end
        S_REQ_RUN: begin
          vu_in_valid <= 1'b1;
          for (i = 0; i < OC_LANES; i++) begin
            vu_acc[i]  <= accm[mi][i];
            vu_bias[i] <= bias_mem[i];
          end
          if (mi == M_TILE-1) begin mi <= 0; st <= S_REQ_WAIT; end
          else mi <= mi + 1;
        end
        S_REQ_WAIT: begin
          if (!req_vld_d) begin mi <= 0; st <= S_WB_REQ; end
        end

        // ---- write back q_mem to DDR : M_TILE pixels x OC_LANES bytes ----
        S_WB_REQ: begin
          wr_addr  <= desc.out_addr + ((mt*M_TILE + mi)*desc.N + nt*OC_LANES);
          wr_len   <= (OC_LANES*ACT_W)/AXI_DATA_W;   // 32*8/128 = 2 beats
          wr_req   <= 1'b1; rx_cnt <= 0;
          st       <= S_WB_TX;
        end
        S_WB_TX: begin
          wr_valid <= 1'b1;
          // pack 16 INT8 per 128-bit beat
          for (i = 0; i < AXI_DATA_W/ACT_W; i++)
            wr_data[i*ACT_W +: ACT_W] <= q_mem[mi][rx_cnt*(AXI_DATA_W/ACT_W)+i];
          if (wr_valid && wr_ready) begin
            if (rx_cnt == wr_len-1) begin
              wr_valid <= 1'b0;
            end else rx_cnt <= rx_cnt + 1;
          end
          if (wr_done) begin
            wr_valid <= 1'b0;
            if (mi == M_TILE-1) st <= S_NEXT_M;
            else begin mi <= mi + 1; st <= S_WB_REQ; end
          end
        end

        // ---- tile / descriptor advance ----
        S_NEXT_M: begin
          if (mt == MT-1) st <= S_NEXT_N;
          else begin mt <= mt + 1; mi <= 0; st <= S_ACT_REQ; end
        end
        S_NEXT_N: begin
          if (nt == NT-1) st <= S_NEXT_DESC;
          else begin nt <= nt + 1; st <= S_WT_REQ; end
        end
        S_NEXT_DESC: begin
          if (desc_idx == desc_count-1) st <= S_DONE;
          else begin desc_idx <= desc_idx + 1; st <= S_DESC_REQ; end
        end

        S_DONE: begin done <= 1'b1; st <= S_IDLE; end
        S_ERR : begin err  <= 1'b1; st <= S_IDLE; end
        default: st <= S_IDLE;
      endcase
    end
  end

  // ---- MAC accumulate pipeline: dot (1-cyc after a_valid) added into accm ----
  always_ff @(posedge clk) begin
    mac_vld_d  <= mt_avalid;            mac_mi_d  <= mi_at_issue;
    mac_vld_d2 <= mac_vld_d;            mac_mi_d2 <= mac_mi_d;
    mac_first_d  <= (st==S_MAC) && (kc==0);
    mac_first_d2 <= mac_first_d;
    if (mt_dvalid) begin
      for (int c = 0; c < OC_LANES; c++)
        accm[mac_mi_d2][c] <= (mac_first_d2 ? '0 : accm[mac_mi_d2][c]) + mt_dot[c];
    end
  end
  // capture which pixel index was issued (mi advances each S_MAC cycle)
  logic [15:0] mi_at_issue;
  always_ff @(posedge clk) mi_at_issue <= mi;

  // ---- requant output capture ----
  always_ff @(posedge clk) begin
    req_vld_d <= vu_in_valid;
    req_mi_d  <= mi;
    if (vu_out_valid) begin
      for (int c = 0; c < OC_LANES; c++)
        q_mem[req_mi_d2][c] <= vu_q[c];
    end
  end
  logic [15:0] req_mi_d2;
  always_ff @(posedge clk) req_mi_d2 <= req_mi_d;

endmodule
