//==============================================================================
// tb_silu.sv  --  Unit test for silu_lut (self-computed SiLU ROM).
//
// SiLU(x) = x*sigmoid(x). INT8 fixed point, SCALE=16 (value = code/16).
// Hand-traceable expected values:
//   x=0   -> silu(0)=0                     -> 0    (0x00)
//   x=16  -> v=1.0 : 1*0.7311=0.731  *16  -> 12   (0x0C)
//   x=32  -> v=2.0 : 2*0.8808=1.762  *16  -> 28   (0x1C)
//   x=64  -> v=4.0 : 4*0.9820=3.928  *16  -> 63   (0x3F)
//   x=-16 -> v=-1.0: -1*0.2689=-0.269*16  -> -4   (0xFC)
//   x=127 -> ~7.9  : saturates             -> 127  (0x7F)
//
// Run: iverilog -g2012 -o tb ../rtl/silu_lut.sv tb_silu.sv && vvp tb
//==============================================================================

module tb_silu;
  logic clk = 0;  always #5 clk = ~clk;

  logic signed [7:0] x, y;
  silu_lut #(.SCALE(16.0)) dut (.clk(clk), .x(x), .y(y));

  int errors = 0;

  task automatic check(input int xi, input int exp);
    @(posedge clk); x <= xi;
    @(posedge clk);            // ROM is 1-cycle
    @(posedge clk);            // sample after update
    if (y !== exp) begin
      $error("SiLU(%0d) = %0d  expected %0d", xi, y, exp); errors++;
    end else
      $display("[ok] SiLU(%0d) = %0d", xi, y);
  endtask

  initial begin
    x = 0;
    check(0,    0);
    check(16,   12);
    check(32,   28);
    check(64,   63);
    check(-16, -4);
    check(127, 127);
    if (errors==0) $display("\n>>> SiLU UNIT TEST PASSED <<<");
    else           $display("\n>>> SiLU FAILED (%0d) <<<", errors);
    $finish;
  end
endmodule
