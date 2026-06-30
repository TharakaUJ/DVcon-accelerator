//==============================================================================
// tb_datapath.sv  --  Self-checking testbench for mac_tile + vector_unit.
//
// Run (Vivado xsim):
//   xvlog -sv accel_pkg.sv mac_tile.sv silu_lut.sv vector_unit.sv \
//             ../sim/tb_datapath.sv
//   xelab -debug typical tb_datapath -s tb && xsim tb -R
// (iverilog/verilator also work; SiLU ROM is self-computed, no hex needed.)
//==============================================================================

module tb_datapath;
  import accel_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  int errors = 0;

  // ---------------- mac_tile ----------------
  logic                          w_load;
  logic [$clog2(OC_LANES)-1:0]   w_col;
  logic [IC_LANES*WGT_W-1:0]     w_data;
  logic                          a_valid, a_first, a_last;
  logic [IC_LANES*ACT_W-1:0]     a_data;
  logic                          r_valid, dot_valid;
  logic signed [ACC_W-1:0]       acc [OC_LANES];
  logic signed [ACC_W-1:0]       dot [OC_LANES];

  mac_tile u_mac (
    .clk, .rst_n, .w_load, .w_col, .w_data,
    .a_valid, .a_first, .a_last, .a_data,
    .r_valid, .acc, .dot_valid, .dot
  );

  task automatic load_weight(input int col, input int wval);
    logic [IC_LANES*WGT_W-1:0] bus;
    for (int l = 0; l < IC_LANES; l++) bus[l*WGT_W +: WGT_W] = wval[7:0];
    @(posedge clk); w_load <= 1; w_col <= col[$clog2(OC_LANES)-1:0]; w_data <= bus;
    @(posedge clk); w_load <= 0;
  endtask

  task automatic drive_act(input int aval, input bit first, input bit last);
    logic [IC_LANES*ACT_W-1:0] bus;
    for (int l = 0; l < IC_LANES; l++) bus[l*ACT_W +: ACT_W] = aval[7:0];
    @(posedge clk); a_valid <= 1; a_first <= first; a_last <= last; a_data <= bus;
    @(posedge clk); a_valid <= 0; a_first <= 0; a_last <= 0;
  endtask

  // ---------------- vector_unit ----------------
  logic                    vu_iv, vu_ov;
  logic signed [ACC_W-1:0] vu_acc [OC_LANES];
  logic signed [ACC_W-1:0] vu_bias[OC_LANES];
  logic [15:0]             vu_mult;
  logic [4:0]              vu_shift;
  logic [1:0]              vu_act;
  logic signed [ACT_W-1:0] vu_q   [OC_LANES];

  vector_unit u_vec (
    .clk, .rst_n, .in_valid(vu_iv), .acc(vu_acc), .bias(vu_bias),
    .requant_mult(vu_mult), .requant_shift(vu_shift), .act_type(vu_act),
    .out_valid(vu_ov), .q(vu_q)
  );

  initial begin
    w_load=0; a_valid=0; a_first=0; a_last=0; vu_iv=0;
    vu_mult=16'd256; vu_shift=5'd8; vu_act=ACT_NONE; // scale = 256/256 = 1.0
    repeat (4) @(posedge clk);
    rst_n <= 1;
    repeat (2) @(posedge clk);

    // ---- TEST 1: mac_tile dot product ----
    // weights col c = (c+1); a_data = 2 -> dot[c] = 16 * 2 * (c+1)
    for (int c = 0; c < OC_LANES; c++) load_weight(c, c+1);
    drive_act(2, 1, 1);
    // dot_valid 1 cycle after a_valid
    @(posedge clk);
    wait (dot_valid);
    @(posedge clk); // sample registered dot
    for (int c = 0; c < OC_LANES; c++) begin
      int exp = 16 * 2 * (c+1);
      if (dot[c] !== exp) begin
        $error("MAC dot[%0d]=%0d exp %0d", c, dot[c], exp); errors++;
      end
    end
    if (errors==0) $display("[TEST1] mac_tile dot   PASS");

    // ---- TEST 2: accumulate (two chunks) ----
    // acc should clear on first then add second: a=2 then a=3 -> per col (16*(c+1))*(2+3)
    drive_act(2, 1, 0);
    drive_act(3, 0, 1);
    repeat (3) @(posedge clk);
    for (int c = 0; c < OC_LANES; c++) begin
      int exp = 16*(c+1)*5;
      if (acc[c] !== exp) begin
        $error("MAC acc[%0d]=%0d exp %0d", c, acc[c], exp); errors++;
      end
    end
    if (errors==0) $display("[TEST2] mac_tile acc   PASS");

    // ---- TEST 3: vector_unit requant + clamp (ACT_NONE, scale 1) ----
    for (int c = 0; c < OC_LANES; c++) begin vu_acc[c]=c-16; vu_bias[c]=0; end
    @(posedge clk); vu_iv <= 1;
    @(posedge clk); vu_iv <= 0;
    wait (vu_ov);
    @(posedge clk);
    for (int c = 0; c < OC_LANES; c++) begin
      int v = c-16; int exp = (v>127)?127:((v<-128)?-128:v);
      if (vu_q[c] !== exp) begin
        $error("VEC q[%0d]=%0d exp %0d", c, vu_q[c], exp); errors++;
      end
    end
    if (errors==0) $display("[TEST3] vector_unit     PASS");

    if (errors==0) $display("\n>>> ALL DATAPATH TESTS PASSED <<<");
    else           $display("\n>>> %0d FAILURES <<<", errors);
    $finish;
  end

endmodule
