//==============================================================================
// tb_matmul.sv  --  Easy-to-follow matrix-multiply test for mac_tile.
//
// mac_tile is fixed at IC_LANES=16 reduction lanes, OC_LANES=32 columns.
// To keep it followable we use the SIMPLEST case: K = IC_LANES = 16, so there
// is ONE chunk and no cross-chunk accumulation -> the `dot` output IS the answer.
//
// Tiny example you can check by hand:
//   activations:  A[m][k] = (m+1)          -> row 0 all 1s, row 1 all 2s
//   weights:      W[c][k] = c              -> column c is all c's
//   dot[m][c] = sum over 16 k of A*W = (m+1) * (16*c)
//      pixel 0 (A=1): dot[c] = 16*c   -> 0, 16, 32, 48, ...
//      pixel 1 (A=2): dot[c] = 32*c   -> 0, 32, 64, 96, ...
//
//   c :   0    1    2    3   ...   examples
//   p0:   0   16   32   48   ...   dot[3]=48
//   p1:   0   32   64   96   ...   dot[3]=96
//
// Run: iverilog -g2012 -o tb ../rtl/accel_pkg.sv ../rtl/mac_tile.sv tb_matmul.sv && vvp tb
//==============================================================================

module tb_matmul;
  import accel_pkg::*;

  localparam int K = IC_LANES;     // 16  (one chunk -> dot = result)
  localparam int N = OC_LANES;     // 32  columns
  localparam int M = 2;            // pixels

  logic clk = 0;  always #5 clk = ~clk;
  logic rst_n = 0;

  // ---- DUT ----
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

  // ---- data + golden ----
  logic signed [7:0] A [M][K];
  logic signed [7:0] W [N][K];
  int golden [M][N];
  int errors = 0;

  // load column c (its K weights) into the array
  task automatic load_col(int c);
    logic [IC_LANES*WGT_W-1:0] bus = '0;
    for (int l=0;l<K;l++) bus[l*WGT_W +: WGT_W] = W[c][l];
    @(posedge clk); w_load <= 1; w_col <= c[$clog2(OC_LANES)-1:0]; w_data <= bus;
    @(posedge clk); w_load <= 0;
  endtask

  // stream one pixel (its K activations), then read the registered `dot`
  task automatic mac_pixel(int m);
    logic [IC_LANES*ACT_W-1:0] bus = '0;
    for (int l=0;l<K;l++) bus[l*ACT_W +: ACT_W] = A[m][l];
    @(posedge clk); a_valid <= 1; a_first <= 1; a_last <= 1; a_data <= bus;
    @(posedge clk); a_valid <= 0; a_first <= 0; a_last <= 0;   // sampled this edge
    @(negedge clk);                                            // dot now valid
    if (!dot_valid) begin $error("dot_valid low for pixel %0d", m); errors++; end
    // print + check
    $write("pixel %0d  dot = [", m);
    for (int c=0;c<N;c++) begin
      $write("%0d ", dot[c]);
      if (dot[c] !== golden[m][c]) begin
        $error("dot[%0d][%0d]=%0d exp %0d", m, c, dot[c], golden[m][c]); errors++;
      end
    end
    $display("]");
  endtask

  initial begin
    w_load=0; a_valid=0; a_first=0; a_last=0;

    // build data + golden
    for (int m=0;m<M;m++) for (int k=0;k<K;k++) A[m][k] = m+1;   // 1, 2
    for (int c=0;c<N;c++) for (int k=0;k<K;k++) W[c][k] = c;     // column = c
    for (int m=0;m<M;m++) for (int c=0;c<N;c++) begin
      golden[m][c]=0; for (int k=0;k<K;k++) golden[m][c]+=A[m][k]*W[c][k];
    end

    repeat (4) @(posedge clk); rst_n <= 1; repeat (2) @(posedge clk);

    // 1) load all N weight columns (weight-stationary)
    for (int c=0;c<N;c++) load_col(c);

    // 2) stream the M pixels, check each dot vector
    for (int m=0;m<M;m++) mac_pixel(m);

    if (errors==0) $display("\n>>> MATMUL TEST PASSED : dot[m][c] = (m+1)*16*c  for all 2x%0d <<<", N);
    else           $display("\n>>> MATMUL FAILED : %0d mismatches <<<", errors);
    $finish;
  end

  initial begin #50000; $display("TIMEOUT"); $finish; end
endmodule
