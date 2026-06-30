//==============================================================================
// uart_rx.sv  --  8N1 UART receiver.
//
// Double-registers the async serial input, detects the start bit, samples each
// data bit at mid-period, and pulses `valid` with the received byte on `data`.
//==============================================================================

module uart_rx #(
  parameter int CLK_HZ = 150_000_000,
  parameter int BAUD   = 115_200
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic       rx,
  output logic [7:0] data,
  output logic       valid
);
  localparam int CPB = CLK_HZ / BAUD;

  typedef enum logic [1:0] {IDLE, START, DATA, STOP} st_e;
  st_e st;

  logic rx_s1, rx_s2;                            // synchronizer
  always_ff @(posedge clk) begin rx_s1 <= rx; rx_s2 <= rx_s1; end

  logic [$clog2(CPB)-1:0] cnt;
  logic [2:0]             bit_idx;
  logic [7:0]             sh;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= IDLE; cnt <= '0; bit_idx <= '0; sh <= '0; data <= '0; valid <= 1'b0;
    end else begin
      valid <= 1'b0;
      case (st)
        IDLE: begin
          cnt <= '0; bit_idx <= '0;
          if (!rx_s2) st <= START;               // falling edge -> start
        end
        START: begin                             // wait to mid of start bit
          if (cnt == (CPB/2)-1) begin
            if (!rx_s2) begin cnt <= '0; st <= DATA; end  // still low: valid start
            else st <= IDLE;                              // glitch
          end else cnt <= cnt + 1;
        end
        DATA: begin                              // sample each bit at its centre
          if (cnt == CPB-1) begin
            cnt <= '0;
            sh[bit_idx] <= rx_s2;
            if (bit_idx == 3'd7) st <= STOP;
            else bit_idx <= bit_idx + 1;
          end else cnt <= cnt + 1;
        end
        STOP: begin
          if (cnt == CPB-1) begin
            data  <= sh;
            valid <= 1'b1;
            st    <= IDLE;
          end else cnt <= cnt + 1;
        end
        default: st <= IDLE;
      endcase
    end
  end

endmodule
