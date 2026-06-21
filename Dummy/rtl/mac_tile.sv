//==============================================================================
// mac_tile.sv  --  Weight-stationary INT8 MAC tile.
//
// OC_LANES output columns, each computing a IC_LANES-wide dot product per
// cycle and accumulating over the GEMM depth K (streamed in IC_LANES chunks).
//
//   512 multiply-accumulates (16x32) -> 256 DSP48E1 with 2-MAC/DSP packing.
//
// Dataflow per output tile (one block of 32 output channels):
//   1) load 32 weight columns (32 writes of 16 INT8 each)
//   2) stream K/IC_LANES activation vectors; first asserts a_first (clear),
//      last asserts a_last (latch result one cycle later)
//   3) read acc[0..31] (INT32), hand to vector_unit for requant+activation
//==============================================================================

module mac_tile
  import accel_pkg::*;
(
  input  logic clk,
  input  logic rst_n,

  // Weight load port (one output-channel column of IC_LANES weights per write)
  input  logic                          w_load,
  input  logic [$clog2(OC_LANES)-1:0]   w_col,
  input  logic [IC_LANES*WGT_W-1:0]     w_data,

  // Activation stream
  input  logic                          a_valid,
  input  logic                          a_first,   // clear accumulators
  input  logic                          a_last,    // last chunk of this K
  input  logic [IC_LANES*ACT_W-1:0]     a_data,

  // Result
  output logic                          r_valid,   // pulses one cycle after a_last
  output logic signed [ACC_W-1:0]       acc [OC_LANES],

  // Combinational partial (a_data . weights) registered 1 cycle, NOT accumulated.
  // Used by conv_controller for weight-stationary GEMM (accumulate in BRAM).
  output logic                          dot_valid, // 1 cycle after a_valid
  output logic signed [ACC_W-1:0]       dot [OC_LANES]
);

  // Stationary weights: [column][lane]
  logic signed [WGT_W-1:0] wreg [OC_LANES][IC_LANES];

  // Weight load (synchronous, slices the flat bus into IC_LANES weights)
  always_ff @(posedge clk) begin
    if (w_load) begin
      for (int l = 0; l < IC_LANES; l++) begin
        wreg[w_col][l] <= $signed(w_data[l*WGT_W +: WGT_W]);
      end
    end
  end

  // Per-column dot product (combinational adder tree) + registered accumulate
  genvar c;
  generate
    for (c = 0; c < OC_LANES; c++) begin : g_col
      logic signed [ACC_W-1:0] dot_comb;

      always_comb begin
        dot_comb = '0;
        for (int l = 0; l < IC_LANES; l++) begin
          dot_comb = dot_comb + ($signed(a_data[l*ACT_W +: ACT_W]) * wreg[c][l]);
        end
      end

      always_ff @(posedge clk) begin
        if (!rst_n) begin
          acc[c] <= '0;
          dot[c] <= '0;
        end else begin
          if (a_valid)
            acc[c] <= a_first ? dot_comb : (acc[c] + dot_comb);
          dot[c] <= dot_comb;          // registered partial (no accumulate)
        end
      end
    end
  endgenerate

  // Result valid: one cycle after the last accumulation lands
  always_ff @(posedge clk) begin
    if (!rst_n) begin r_valid <= 1'b0; dot_valid <= 1'b0; end
    else        begin r_valid <= a_valid & a_last; dot_valid <= a_valid; end
  end

endmodule
