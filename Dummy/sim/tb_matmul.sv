//==============================================================================
// tb_matmul.sv  --  Self-checking matrix-multiply testbench for mac_tile.
//
// Verifies the weight-stationary GEMM the accelerator performs:
//     C[M][N] = A[M][K] * W[N][K]^T      (INT8 inputs, INT32 accumulate)
// using the exact schedule conv_controller uses:
//   for kc in 0..KC-1:
//     load OC_LANES weight columns (one IC_LANES-chunk each)
//     for m in 0..M-1: dot = A[m,kc] . W[:,kc]; accm[m] += dot
// then compares accm against a behavioral golden product.
//
// Run (Vivado xsim):
//   xvlog -sv ../rtl/accel_pkg.sv ../rtl/mac_tile.sv tb_matmul.sv
//   xelab -debug typical tb_matmul -s tb && xsim tb -R
// Run (Icarus):
//   iverilog -g2012 -o tb ../rtl/accel_pkg.sv ../rtl/mac_tile.sv tb_matmul.sv && vvp tb
//==============================================================================

module tb_matmul;
  import accel_pkg::*;

  // ---- problem size (K must be a multiple of IC_LANES) ----
  localparam int M  = 4;                 // rows of A
  localparam int N  = OC_LANES;          // cols of C  (= weight columns, 32)
  localparam int KC = 3;                 // IC_LANES-chunks of depth
  localparam int K  = KC * IC_LANES;     // 48

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ---- DUT I/O ----
  logic                          w_load;
  logic [$clog2(OC_LANES)-1:0]   w_col;
  logic [IC_LANES*WGT_W-1:0]     w_data;
  logic                          a_valid, a_first, a_last;
  logic [IC_LANES*ACT_W-1:0]     a_data;
  logic                          r_valid, dot_valid;
  logic signed [ACC_W-1:0]       acc [OC_LANES];
  logic signed [ACC_W-1:0]       dot [OC_LANES];

  mac_tile dut (
    .clk, .rst_n, .w_load, .w_col, .w_data,
    .a_valid, .a_first, .a_last, .a_data,
    .r_valid, .acc, .dot_valid, .dot
  );

  // ---- test data + golden ----
  logic signed [7:0] A [M][K];
  logic signed [7:0] W [N][K];
  int  golden [M][N];
  int  accm   [M][N];        // accumulated from the DUT
  int  errors = 0;

  // pack one IC_LANES chunk of a row into the flat bus
  function automatic logic [IC_LANES*WGT_W-1:0] packW(int n, int kc);
    for (int l = 0; l < IC_LANES; l++)
      packW[l*WGT_W +: WGT_W] = W[n][kc*IC_LANES + l];
  endfunction
  function automatic logic [IC_LANES*ACT_W-1:0] packA(int m, int kc);
    for (int l = 0; l < IC_LANES; l++)
      packA[l*ACT_W +: ACT_W] = A[m][kc*IC_LANES + l];
  endfunction

  // load all N weight columns for chunk kc
  task automatic load_weights(int kc);
    for (int n = 0; n < N; n++) begin
      @(posedge clk);
      w_load <= 1; w_col <= n[$clog2(OC_LANES)-1:0]; w_data <= packW(n, kc);
    end
    @(posedge clk); w_load <= 0;
  endtask

  // present A[m,kc], wait for registered dot, accumulate into accm[m][*]
  // mac_tile latency: a_valid sampled at edge E -> dot_valid & dot valid in the
  // (E .. E+1) window. Sample at the negedge inside that window.
  task automatic mac_one(int m, int kc);
    @(posedge clk);
    a_valid <= 1; a_data <= packA(m, kc);
    @(posedge clk);               // edge E: mac samples a_valid=1 -> dot<=product
    a_valid <= 0;
    @(negedge clk);               // dot_valid=1, dot stable here
    if (!dot_valid) begin $error("dot_valid not asserted (m=%0d kc=%0d)", m, kc); errors++; end
    for (int n = 0; n < N; n++) accm[m][n] += dot[n];
  endtask

  initial begin
    w_load=0; a_valid=0; a_first=0; a_last=0; a_data='0; w_data='0; w_col='0;

    // random INT8 in [-16,15] (keeps numbers readable, exercises sign)
    for (int m = 0; m < M; m++) for (int k = 0; k < K; k++) A[m][k] = ($random % 32) - 16;
    for (int n = 0; n < N; n++) for (int k = 0; k < K; k++) W[n][k] = ($random % 32) - 16;

    // golden product
    for (int m = 0; m < M; m++)
      for (int n = 0; n < N; n++) begin
        golden[m][n] = 0;
        for (int k = 0; k < K; k++) golden[m][n] += A[m][k] * W[n][k];
        accm[m][n] = 0;
      end

    repeat (4) @(posedge clk); rst_n <= 1; repeat (2) @(posedge clk);

    // run the GEMM, weight-stationary over kc
    for (int kc = 0; kc < KC; kc++) begin
      load_weights(kc);
      for (int m = 0; m < M; m++) mac_one(m, kc);
    end

    // check
    for (int m = 0; m < M; m++)
      for (int n = 0; n < N; n++)
        if (accm[m][n] !== golden[m][n]) begin
          $error("C[%0d][%0d] = %0d  expected %0d", m, n, accm[m][n], golden[m][n]);
          errors++;
        end

    if (errors == 0)
      $display("\n>>> MATMUL TEST PASSED : C[%0dx%0d] = A * W^T (K=%0d) all correct <<<", M, N, K);
    else
      $display("\n>>> MATMUL TEST FAILED : %0d mismatches <<<", errors);
    $finish;
  end

  // safety timeout
  initial begin #100000; $display("TIMEOUT"); $finish; end

endmodule
