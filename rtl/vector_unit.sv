//==============================================================================
// vector_unit.sv  --  Post-processing for one OC_LANES-wide accumulator tile.
//
// Per channel:  s0 = acc + bias
//               s1 = (s0 * requant_mult) >>> requant_shift     (fixed-point)
//               r  = clamp(s1, -128, 127)                       -> INT8
//               y  = activation(r)   { NONE | RELU | SILU(LUT) }
//
// Latency: 2 cycles (requant register + activation/LUT register).
// requant_mult/shift are per-tensor here; per-channel scale is a future
// extension (load a scale vector alongside bias).
//==============================================================================
`timescale 1ns/1ps

module vector_unit
#(
  parameter real SILU_SCALE = 16.0,    // SiLU LUT fixed-point scale

  // ---- inlined from former accel_pkg (package removed) --------------------
  localparam int ACT_W    = 8,    // INT8 activations
  localparam int WGT_W    = 8,    // INT8 weights
  localparam int ACC_W    = 32,   // INT32 accumulation
  localparam int OC_LANES = 32,   // parallel output channels (tile width)

  localparam logic [1:0] ACT_NONE = 2'd0,
  localparam logic [1:0] ACT_RELU = 2'd1,
  localparam logic [1:0] ACT_SILU = 2'd2
)(
  input  logic clk,
  input  logic rst_n,

  input  logic                       in_valid,
  input  logic signed [ACC_W-1:0]    acc  [OC_LANES],
  input  logic signed [ACC_W-1:0]    bias [OC_LANES],
  input  logic [15:0]                requant_mult,
  input  logic [4:0]                 requant_shift,
  input  logic [1:0]                 act_type,

  output logic                       out_valid,
  output logic signed [ACT_W-1:0]    q [OC_LANES]
);

  // ---- Stage A : add bias, scale, shift, clamp to INT8 ----------------------
  logic signed [ACT_W-1:0] r_a [OC_LANES];
  logic                    va;
  logic [1:0]              act_a;

  function automatic logic signed [ACT_W-1:0] clamp8(input logic signed [63:0] v);
    if (v >  127) clamp8 =  8'sd127;
    else if (v < -128) clamp8 = -8'sd128;
    else clamp8 = v[ACT_W-1:0];
  endfunction

  genvar c;
  generate
    for (c = 0; c < OC_LANES; c++) begin : g_req
      logic signed [ACC_W:0]   s0;
      logic signed [63:0]      prod, sh;
      always_comb begin
        s0   = acc[c] + bias[c];
        prod = $signed(s0) * $signed({1'b0, requant_mult}); // mult >= 0
        sh   = prod >>> requant_shift;
      end
      always_ff @(posedge clk) begin
        if (!rst_n) r_a[c] <= '0;
        else        r_a[c] <= clamp8(sh);
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rst_n) begin va <= 1'b0; act_a <= 2'd0; end
    else        begin va <= in_valid; act_a <= act_type; end
  end

  // ---- Stage B : activation (NONE / RELU / SILU-LUT) ------------------------
  logic signed [ACT_W-1:0] r_b [OC_LANES];   // registered passthrough of r_a
  logic [1:0]              act_b;
  logic signed [ACT_W-1:0] silu_y [OC_LANES];

  generate
    for (c = 0; c < OC_LANES; c++) begin : g_act
      silu_lut #(.SCALE(SILU_SCALE)) u_silu (
        .clk (clk), .x (r_a[c]), .y (silu_y[c])
      );
      always_ff @(posedge clk) r_b[c] <= r_a[c];
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rst_n) begin out_valid <= 1'b0; act_b <= 2'd0; end
    else        begin out_valid <= va;   act_b <= act_a; end
  end

  generate
    for (c = 0; c < OC_LANES; c++) begin : g_out
      always_comb begin
        unique case (act_b)
          ACT_RELU: q[c] = (r_b[c] < 0) ? '0 : r_b[c];
          ACT_SILU: q[c] = silu_y[c];
          default:  q[c] = r_b[c];           // ACT_NONE
        endcase
      end
    end
  endgenerate

endmodule
