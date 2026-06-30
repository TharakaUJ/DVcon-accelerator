//==============================================================================
// axi_write_master.sv  --  Simple AXI4 burst write engine.
//
// Command: pulse req with byte-addr + beat count. Pulls write data from an
// input stream (s_valid/s_ready). INCR bursts of <= MAX_BURST beats, no 4 KB
// crossing, all-ones WSTRB. One outstanding burst (functional, simple).
//==============================================================================

module axi_write_master
  import accel_pkg::*;
#(
  parameter int MAX_BURST = 16
)(
  input  logic clk,
  input  logic rst_n,

  // command
  input  logic                    req,
  input  logic [AXI_ADDR_W-1:0]   addr,
  input  logic [15:0]             len_beats,
  output logic                    busy,
  output logic                    done,

  // input data stream (producer asserts s_valid)
  input  logic [AXI_DATA_W-1:0]   s_data,
  input  logic                    s_valid,
  output logic                    s_ready,

  // AXI4 write channels
  output logic [AXI_ID_W-1:0]     awid,
  output logic [AXI_ADDR_W-1:0]   awaddr,
  output logic [7:0]              awlen,
  output logic [2:0]              awsize,
  output logic [1:0]              awburst,
  output logic                    awvalid,
  input  logic                    awready,
  output logic [AXI_DATA_W-1:0]   wdata,
  output logic [AXI_STRB_W-1:0]   wstrb,
  output logic                    wlast,
  output logic                    wvalid,
  input  logic                    wready,
  input  logic [AXI_ID_W-1:0]     bid,
  input  logic [1:0]              bresp,
  input  logic                    bvalid,
  output logic                    bready
);
  localparam int BYTES_PER_BEAT = AXI_DATA_W/8;

  typedef enum logic [2:0] {S_IDLE, S_AW, S_W, S_B, S_DONE} state_e;
  state_e state;

  logic [AXI_ADDR_W-1:0] cur_addr;
  logic [16:0]           beats_left;
  logic [8:0]            burst_beats;
  logic [8:0]            wcnt;          // beats sent in current burst

  function automatic logic [8:0] beats_to_4k(input logic [AXI_ADDR_W-1:0] a);
    logic [12:0] rem;
    rem = 13'd4096 - {1'b0, a[11:0]};
    beats_to_4k = rem[12:4];
  endfunction
  function automatic logic [8:0] next_burst(input logic [16:0] left,
                                            input logic [AXI_ADDR_W-1:0] a);
    logic [8:0] b4k, cap;
    b4k = beats_to_4k(a);
    cap = (left > MAX_BURST) ? MAX_BURST[8:0] : left[8:0];
    next_burst = (cap < b4k) ? cap : b4k;
  endfunction

  assign awid    = '0;
  assign awsize  = $clog2(BYTES_PER_BEAT);
  assign awburst = 2'b01;
  assign wstrb   = '1;
  assign busy    = (state != S_IDLE);

  assign wdata   = s_data;
  assign wvalid  = (state == S_W) & s_valid;
  assign s_ready = (state == S_W) & wready;
  assign wlast   = (state == S_W) & (wcnt == burst_beats - 9'd1);
  wire   wbeat   = wvalid & wready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE; awvalid <= 1'b0; bready <= 1'b0; done <= 1'b0;
      cur_addr <= '0; beats_left <= '0; burst_beats <= '0; wcnt <= '0;
      awaddr <= '0; awlen <= '0;
    end else begin
      done <= 1'b0;
      case (state)
        S_IDLE: begin
          if (req && len_beats != 0) begin
            cur_addr   <= addr;
            beats_left <= {1'b0, len_beats};
            state      <= S_AW;
          end
        end
        S_AW: begin
          burst_beats <= next_burst(beats_left, cur_addr);
          awaddr      <= cur_addr;
          awlen       <= next_burst(beats_left, cur_addr) - 9'd1;
          awvalid     <= 1'b1;
          wcnt        <= '0;
          if (awvalid && awready) begin
            awvalid <= 1'b0;
            state   <= S_W;
          end
        end
        S_W: begin
          if (wbeat) begin
            wcnt <= wcnt + 9'd1;
            if (wlast) begin
              bready <= 1'b1;
              state  <= S_B;
            end
          end
        end
        S_B: begin
          if (bvalid && bready) begin
            bready     <= 1'b0;
            cur_addr   <= cur_addr + (burst_beats << $clog2(BYTES_PER_BEAT));
            beats_left <= beats_left - burst_beats;
            state      <= (beats_left == burst_beats) ? S_DONE : S_AW;
          end
        end
        S_DONE: begin
          done  <= 1'b1;
          state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
