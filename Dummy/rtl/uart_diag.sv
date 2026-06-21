//==============================================================================
// uart_diag.sv  --  Standalone UART diagnostic port (status / heartbeat).
//
// Independent of the AXI data path. In Option B the detections live in DDR and
// the CPU scores them, so the accelerator has no "best box" to report. This port
// instead emits a small status frame on inference-done or on any received byte,
// so an external host can confirm the accelerator is alive and running:
//
//   [0] 0x5A  sync
//   [1] status = {5'b0, err, done_latched, busy}
//   [2] inference_count[15:8]
//   [3] inference_count[7:0]
//   [4] 0x0A  newline
//
// Wraps uart_tx + uart_rx. Exposes only the two serial pins.
//==============================================================================

module uart_diag #(
  parameter int CLK_HZ = 150_000_000,
  parameter int BAUD   = 115_200
)(
  input  logic        clk,
  input  logic        rst_n,

  // serial pins (to external host / FTDI)
  input  logic        uart_rx_i,
  output logic        uart_tx_o,

  // status from the accelerator
  input  logic        busy,
  input  logic        done,           // 1-cycle pulse at end of inference
  input  logic        err
);
  localparam int NBYTES = 5;

  // ---- sub-cores ----
  logic [7:0] tx_byte;  logic tx_start, tx_busy, tx_done;
  logic [7:0] rx_byte;  logic rx_valid;

  uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .clk, .rst_n, .data(tx_byte), .start(tx_start),
    .tx(uart_tx_o), .busy(tx_busy), .done(tx_done)
  );
  uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
    .clk, .rst_n, .rx(uart_rx_i), .data(rx_byte), .valid(rx_valid)
  );

  // ---- latch status + count inferences ----
  logic        done_l, err_l;
  logic [15:0] inf_cnt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin done_l<=0; err_l<=0; inf_cnt<=0; end
    else if (done) begin done_l<=1; err_l<=err; inf_cnt<=inf_cnt+1; end
  end

  // ---- frame buffer ----
  logic [7:0] fbuf [0:NBYTES-1];

  // ---- send FSM ----
  typedef enum logic [1:0] {IDLE, ASSERT, WAIT, NEXT} st_e;
  st_e st;
  logic [2:0] idx;
  wire  trig = done | rx_valid;          // dump on inference-done or host poke

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= IDLE; idx <= 0; tx_start <= 0; tx_byte <= 8'h00;
    end else begin
      tx_start <= 1'b0;
      case (st)
        IDLE: if (trig && !tx_busy) begin
          fbuf[0] <= 8'h5A;
          fbuf[1] <= {5'b0, err_l, done_l, busy};
          fbuf[2] <= inf_cnt[15:8];
          fbuf[3] <= inf_cnt[7:0];
          fbuf[4] <= 8'h0A;
          idx <= 0;
          st  <= ASSERT;
        end
        ASSERT: if (!tx_busy) begin
          tx_byte  <= fbuf[idx];
          tx_start <= 1'b1;
          st       <= WAIT;
        end
        WAIT: if (tx_done) st <= NEXT;
        NEXT: begin
          if (idx == NBYTES-1) st <= IDLE;
          else begin idx <= idx + 1; st <= ASSERT; end
        end
        default: st <= IDLE;
      endcase
    end
  end

endmodule
