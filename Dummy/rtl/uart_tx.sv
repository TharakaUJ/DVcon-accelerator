//==============================================================================
// uart_tx.sv  --  8N1 UART transmitter.
//
// Pulse `start` with a byte on `data`; it shifts out start + 8 data + stop bits
// at the configured baud. `busy` high during a frame, `done` pulses at the end.
//==============================================================================

module uart_tx #(
  parameter int CLK_HZ = 150_000_000,
  parameter int BAUD   = 115_200
)(
  input  logic       clk,
  input  logic       rst_n,
  input  logic [7:0] data,
  input  logic       start,
  output logic       tx,
  output logic       busy,
  output logic       done
);
  localparam int CPB = CLK_HZ / BAUD;          // clocks per bit

  typedef enum logic [1:0] {IDLE, START, DATA, STOP} st_e;
  st_e st;

  logic [$clog2(CPB)-1:0] cnt;
  logic [2:0]             bit_idx;
  logic [7:0]             sh;

  wire bit_done = (cnt == CPB-1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= IDLE; tx <= 1'b1; busy <= 1'b0; done <= 1'b0;
      cnt <= '0; bit_idx <= '0; sh <= '0;
    end else begin
      done <= 1'b0;
      case (st)
        IDLE: begin
          tx <= 1'b1; busy <= 1'b0; cnt <= '0; bit_idx <= '0;
          if (start) begin sh <= data; busy <= 1'b1; st <= START; end
        end
        START: begin
          tx <= 1'b0;                                   // start bit
          if (bit_done) begin cnt <= '0; st <= DATA; end else cnt <= cnt + 1;
        end
        DATA: begin
          tx <= sh[bit_idx];                            // LSB first
          if (bit_done) begin
            cnt <= '0;
            if (bit_idx == 3'd7) st <= STOP;
            else bit_idx <= bit_idx + 1;
          end else cnt <= cnt + 1;
        end
        STOP: begin
          tx <= 1'b1;                                   // stop bit
          if (bit_done) begin cnt <= '0; busy <= 1'b0; done <= 1'b1; st <= IDLE; end
          else cnt <= cnt + 1;
        end
        default: st <= IDLE;
      endcase
    end
  end

endmodule
