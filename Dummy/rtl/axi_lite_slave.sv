//==============================================================================
// axi_lite_slave.sv  --  Control/status register file (AXI4-Lite, 32-bit).
//
// Register map (byte offset), see docs/architecture.md §8a:
//   0x00 CTRL        [0]START(W1P) [1]IRQ_EN [2]SOFT_RST(W1P)
//   0x04 STATUS  RO  [0]BUSY [1]DONE [2]ERR
//   0x08 LAYER_CFG0  (single-layer mode, optional)
//   0x0C LAYER_CFG1
//   0x10 LAYER_CFG2
//   0x14 LAYER_CFG3
//   0x18 WT_ADDR
//   0x1C IN_ADDR
//   0x20 OUT_ADDR
//   0x24 BIAS_ADDR
//   0x28 REQUANT     [15:0]mult [20:16]shift [22:21]act
//   0x2C IRQ_ACK (W1P) clear DONE/ERR
//   0x30 DESC_BASE
//   0x34 DESC_COUNT
//
// Option B: the accelerator writes ALL detections to DDR (head out_addr in the
// descriptor). The CPU reads that tensor and does scoring/argmax in software
// (in parallel with model2vec). No result or rank-weight registers here.
//==============================================================================

module axi_lite_slave
  import accel_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // ---- AXI4-Lite ----
  input  logic [AXIL_ADDR_W-1:0] s_awaddr,
  input  logic                   s_awvalid,
  output logic                   s_awready,
  input  logic [AXIL_DATA_W-1:0] s_wdata,
  input  logic [AXIL_DATA_W/8-1:0] s_wstrb,
  input  logic                   s_wvalid,
  output logic                   s_wready,
  output logic [1:0]             s_bresp,
  output logic                   s_bvalid,
  input  logic                   s_bready,
  input  logic [AXIL_ADDR_W-1:0] s_araddr,
  input  logic                   s_arvalid,
  output logic                   s_arready,
  output logic [AXIL_DATA_W-1:0] s_rdata,
  output logic [1:0]             s_rresp,
  output logic                   s_rvalid,
  input  logic                   s_rready,

  // ---- decoded control out ----
  output logic                   start_pulse,
  output logic                   soft_rst,
  output logic                   irq_en,
  output logic                   irq_ack,
  output logic [31:0]            desc_base,
  output logic [31:0]            desc_count,
  output logic [31:0]            wt_addr, in_addr, out_addr, bias_addr,
  output logic [15:0]            requant_mult,
  output logic [4:0]             requant_shift,
  output logic [1:0]             act_type,

  // ---- status in ----
  input  logic                   busy,
  input  logic                   done,
  input  logic                   err,

  output logic                   irq
);

  // Writable registers
  logic [31:0] reg_ctrl, reg_requant, reg_descbase, reg_desccount;
  logic [31:0] reg_wt, reg_in, reg_out, reg_bias;

  assign irq_en        = reg_ctrl[1];
  assign desc_base     = reg_descbase;
  assign desc_count    = reg_desccount;
  assign wt_addr       = reg_wt;
  assign in_addr       = reg_in;
  assign out_addr      = reg_out;
  assign bias_addr     = reg_bias;
  assign requant_mult  = reg_requant[15:0];
  assign requant_shift = reg_requant[20:16];
  assign act_type      = reg_requant[22:21];

  // ---- Write channel ----
  logic aw_hs, w_hs;
  assign aw_hs = s_awvalid & s_awready;
  assign w_hs  = s_wvalid  & s_wready;

  // accept address+data together when no response pending
  wire wr_ready = ~s_bvalid;
  assign s_awready = wr_ready & s_awvalid & s_wvalid;
  assign s_wready  = wr_ready & s_awvalid & s_wvalid;

  wire        wr_en   = aw_hs & w_hs;
  wire [AXIL_ADDR_W-1:0] wr_addr = s_awaddr;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      reg_ctrl <= 0; reg_requant <= 0; reg_descbase <= 0; reg_desccount <= 0;
      reg_wt <= 0; reg_in <= 0; reg_out <= 0; reg_bias <= 0;
      start_pulse <= 0; soft_rst <= 0; irq_ack <= 0;
    end else begin
      // default one-cycle pulses low
      start_pulse <= 0; soft_rst <= 0; irq_ack <= 0;

      if (wr_en) begin
        unique case (wr_addr[7:2])
          6'h00: begin // CTRL
            reg_ctrl    <= s_wdata;
            start_pulse <= s_wdata[0];
            soft_rst    <= s_wdata[2];
          end
          6'h02: reg_requant   <= s_wdata; // 0x08 LAYER_CFG0 (alias unused here)
          6'h06: reg_wt        <= s_wdata; // 0x18
          6'h07: reg_in        <= s_wdata; // 0x1C
          6'h08: reg_out       <= s_wdata; // 0x20
          6'h09: reg_bias      <= s_wdata; // 0x24
          6'h0A: reg_requant   <= s_wdata; // 0x28 REQUANT
          6'h0B: irq_ack       <= 1'b1;    // 0x2C IRQ_ACK
          6'h0C: reg_descbase  <= s_wdata; // 0x30
          6'h0D: reg_desccount <= s_wdata; // 0x34
          default: ;
        endcase
      end
    end
  end

  // bvalid handshake
  always_ff @(posedge clk) begin
    if (!rst_n) s_bvalid <= 1'b0;
    else if (wr_en) s_bvalid <= 1'b1;
    else if (s_bvalid & s_bready) s_bvalid <= 1'b0;
  end
  assign s_bresp = 2'b00;

  // ---- Read channel ----
  assign s_arready = ~s_rvalid;
  logic [AXIL_ADDR_W-1:0] rd_addr;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_rvalid <= 1'b0; s_rdata <= 32'h0;
    end else begin
      if (s_arvalid & s_arready) begin
        s_rvalid <= 1'b1;
        rd_addr  <= s_araddr;
        unique case (s_araddr[7:2])
          6'h00: s_rdata <= reg_ctrl;
          6'h01: s_rdata <= {29'd0, err, done, busy};        // STATUS
          6'h06: s_rdata <= reg_wt;
          6'h07: s_rdata <= reg_in;
          6'h08: s_rdata <= reg_out;
          6'h09: s_rdata <= reg_bias;
          6'h0A: s_rdata <= reg_requant;
          6'h0C: s_rdata <= reg_descbase;
          6'h0D: s_rdata <= reg_desccount;
          default: s_rdata <= 32'h0;
        endcase
      end else if (s_rvalid & s_rready) begin
        s_rvalid <= 1'b0;
      end
    end
  end
  assign s_rresp = 2'b00;

  // ---- IRQ : level set on done|err, cleared by irq_ack ----
  logic irq_pending;
  always_ff @(posedge clk) begin
    if (!rst_n) irq_pending <= 1'b0;
    else if (irq_ack) irq_pending <= 1'b0;
    else if ((done | err) & irq_en) irq_pending <= 1'b1;
  end
  assign irq = irq_pending;

endmodule
