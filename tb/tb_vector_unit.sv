//==============================================================================
// tb_vector_unit.sv  --  Unit test for vector_unit (bias add, requant, act).
//
// Datapath per channel:
//   s0 = acc + bias
//   s1 = (s0 * requant_mult) >>> requant_shift
//   r  = clamp(s1, -128, 127)              -> INT8
//   y  = activation(r)  { NONE | RELU | SILU(LUT, SCALE=16) }
// Latency: 2 clocks (out_valid / q valid two posedges after in_valid sampled).
//
// requant_mult=16, requant_shift=4  =>  *16/16 = identity (s0 passes through).
// SiLU LUT reference (SCALE=16, value=code/16): see tb_silu.sv
//   r=0 -> 0 ; r=16 -> 12 ; r=32 -> 28 ; r=64 -> 63 ; r=-16 -> -4 ; r=127 -> 127
//
// Run: iverilog -g2012 -o tb ../rtl/silu_lut.sv ../rtl/vector_unit.sv tb_vector_unit.sv && vvp tb
//==============================================================================

module tb_vector_unit;

  localparam int OC_LANES = 32;   // mirrors vector_unit
  localparam int ACC_W    = 32;
  localparam int ACT_W    = 8;

  // activation codes (match inlined localparams in vector_unit)
  localparam logic [1:0] ACT_NONE = 2'd0;
  localparam logic [1:0] ACT_RELU = 2'd1;
  localparam logic [1:0] ACT_SILU = 2'd2;

  logic clk = 0;  always #5 clk = ~clk;
  logic rst_n;

  logic                    in_valid;
  logic signed [ACC_W-1:0] acc  [OC_LANES];
  logic signed [ACC_W-1:0] bias [OC_LANES];
  logic [15:0]             requant_mult;
  logic [4:0]              requant_shift;
  logic [1:0]              act_type;

  logic                    out_valid;
  logic signed [ACT_W-1:0] q [OC_LANES];

  vector_unit #(.SILU_SCALE(16.0)) dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .in_valid     (in_valid),
    .acc          (acc),
    .bias         (bias),
    .requant_mult (requant_mult),
    .requant_shift(requant_shift),
    .act_type     (act_type),
    .out_valid    (out_valid),
    .q            (q)
  );

  int errors = 0;

  // Drive every lane with the same scalar, pulse in_valid for one cycle,
  // wait for out_valid, then check all lanes equal exp.
  task automatic run_case(
      input string         name,
      input int            acc_v,
      input int            bias_v,
      input logic [15:0]   mult,
      input logic [4:0]    shift,
      input logic [1:0]    act,
      input int            exp
  );
    @(negedge clk);
    for (int c = 0; c < OC_LANES; c++) begin
      acc[c]  = acc_v;
      bias[c] = bias_v;
    end
    requant_mult  = mult;
    requant_shift = shift;
    act_type      = act;
    in_valid      = 1'b1;

    @(posedge clk);                 // edge1: va, act_a, r_a latch
    @(negedge clk) in_valid = 1'b0; // one-cycle valid pulse
    @(posedge clk);                 // edge2: out_valid, r_b, silu_y, act_b latch
    #1;                             // settle combinational q

    if (out_valid !== 1'b1) begin
      $error("%s : out_valid not asserted", name);
      errors++;
    end

    begin
      bit fail = 0;
      for (int c = 0; c < OC_LANES; c++) begin
        if (q[c] !== exp) begin
          $error("%s : lane %0d  q=%0d  expected %0d", name, c, q[c], exp);
          errors++;
          fail = 1;
        end
      end
      if (!fail)
        $display("[ok] %-22s acc=%0d bias=%0d act=%0d -> q=%0d", name, acc_v, bias_v, act, exp);
    end
  endtask

  initial begin
    // reset
    in_valid = 0; acc = '{default:0}; bias = '{default:0};
    requant_mult = 16; requant_shift = 4; act_type = ACT_NONE;
    rst_n = 0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // ---- NONE: identity requant (mult/shift = *1) ----
    run_case("NONE add",      10,   5, 16, 4, ACT_NONE,   15);
    run_case("NONE pos sat", 1000,  0, 16, 4, ACT_NONE,  127);  // clamp +127
    run_case("NONE neg sat",-1000,  0, 16, 4, ACT_NONE, -128);  // clamp -128
    run_case("NONE bias neg",  20,-30, 16, 4, ACT_NONE,  -10);

    // ---- requant scaling: mult=8, shift=4 -> *0.5 ----
    run_case("REQ x0.5",       20,   0,  8, 4, ACT_NONE,  10);
    run_case("REQ x0.5 round", 21,   0,  8, 4, ACT_NONE,  10);  // 21*8>>4 = 10 (trunc)

    // ---- RELU ----
    run_case("RELU pos",       40,   0, 16, 4, ACT_RELU,  40);
    run_case("RELU neg->0",   -40,   0, 16, 4, ACT_RELU,   0);

    // ---- SILU (LUT, SCALE=16) ----
    run_case("SILU 0",          0,   0, 16, 4, ACT_SILU,   0);
    run_case("SILU 16",        16,   0, 16, 4, ACT_SILU,  12);
    run_case("SILU 32",        32,   0, 16, 4, ACT_SILU,  28);
    run_case("SILU 64",        64,   0, 16, 4, ACT_SILU,  63);
    run_case("SILU -16",      -16,   0, 16, 4, ACT_SILU,  -4);
    run_case("SILU 127 sat",  127,   0, 16, 4, ACT_SILU, 127);

    if (errors == 0) $display("\n>>> VECTOR_UNIT UNIT TEST PASSED <<<");
    else             $display("\n>>> VECTOR_UNIT FAILED (%0d errors) <<<", errors);
    $finish;
  end

  // safety timeout
  initial begin
    #100000;
    $error("TIMEOUT");
    $finish;
  end

endmodule
