//==============================================================================
// axi_read_master.sv  --  Simple AXI4 burst read engine.
//
// Command: pulse req with byte-addr + beat count. Streams read data out with
// valid/ready backpressure. Splits into INCR bursts of <= MAX_BURST beats and
// never crosses a 4 KB boundary. One outstanding burst (functional, simple).
//==============================================================================

module axi_read_master
  import accel_pkg::*;
#(
  parameter int MAX_BURST = 16
)(
  input  logic clk,
  input  logic rst_n,

  // command
  input  logic                    req,
  input  logic [AXI_ADDR_W-1:0]   addr,        // byte address (16-B aligned)
  input  logic [15:0]             len_beats,   // number of 128-bit beats
  output logic                    busy,
  output logic                    done,        // 1-cycle pulse when all beats read

  // output data stream (consumer asserts m_ready)
  output logic [AXI_DATA_W-1:0]   m_data,
  output logic                    m_valid,
  input  logic                    m_ready,

  // AXI4 read address/data channels
  output logic [AXI_ID_W-1:0]     arid,
  output logic [AXI_ADDR_W-1:0]   araddr,
  output logic [7:0]              arlen,
  output logic [2:0]              arsize,
  output logic [1:0]              arburst,
  output logic                    arvalid,
  input  logic                    arready,
  input  logic [AXI_ID_W-1:0]     rid,
  input  logic [AXI_DATA_W-1:0]   rdata,
  input  logic [1:0]              rresp,
  input  logic                    rlast,
  input  logic                    rvalid,
  output logic                    rready
);
  localparam int BYTES_PER_BEAT = AXI_DATA_W/8;

  typedef enum logic [1:0] {S_IDLE, S_AR, S_DATA, S_DONE} state_e;
  state_e state;

  logic [AXI_ADDR_W-1:0] cur_addr;
  logic [16:0]           beats_left;     // beats remaining in whole command
  logic [8:0]            burst_beats;    // beats in current burst (1..256)

  // beats from address to next 4 KB boundary
  function automatic logic [8:0] beats_to_4k(input logic [AXI_ADDR_W-1:0] a);
    logic [12:0] rem;
    rem = 13'd4096 - {1'b0, a[11:0]};
    beats_to_4k = rem[12:4];            // /16
  endfunction

  function automatic logic [8:0] next_burst(input logic [16:0] left,
                                            input logic [AXI_ADDR_W-1:0] a);
    logic [8:0] b4k, cap;
    b4k = beats_to_4k(a);
    cap = (left > MAX_BURST) ? MAX_BURST[8:0] : left[8:0];
    next_burst = (cap < b4k) ? cap : b4k;
  endfunction

  assign arid    = '0;
  assign arsize  = $clog2(BYTES_PER_BEAT);
  assign arburst = 2'b01; // INCR
  assign busy    = (state != S_IDLE);

  // data-channel handshake
  assign m_valid = (state == S_DATA) & rvalid;
  assign m_data  = rdata;
  assign rready  = (state == S_DATA) & m_ready;
  wire   beat    = rvalid & rready;     // a data beat transfers

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE; arvalid <= 1'b0; done <= 1'b0;
      cur_addr <= '0; beats_left <= '0; burst_beats <= '0;
      araddr <= '0; arlen <= '0;
    end else begin
      done <= 1'b0;
      case (state)
        S_IDLE: begin
          if (req && len_beats != 0) begin
            cur_addr   <= addr;
            beats_left <= {1'b0, len_beats};
            state      <= S_AR;
          end
        end
        S_AR: begin
          burst_beats <= next_burst(beats_left, cur_addr);
          araddr      <= cur_addr;
          arlen       <= next_burst(beats_left, cur_addr) - 9'd1;
          arvalid     <= 1'b1;
          if (arvalid && arready) begin
            arvalid <= 1'b0;
            state   <= S_DATA;
          end
        end
        S_DATA: begin
          if (beat && rlast) begin
            cur_addr   <= cur_addr + (burst_beats << $clog2(BYTES_PER_BEAT));
            beats_left <= beats_left - burst_beats;
            state      <= (beats_left == burst_beats) ? S_DONE : S_AR;
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
