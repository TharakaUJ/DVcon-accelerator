//==============================================================================
// silu_lut.sv  --  256-entry INT8 SiLU ROM, self-initialising (no hex file).
//
// SiLU(x) = x * sigmoid(x).  The table is computed at elaboration time in an
// initial block, so there is nothing to load with $readmemh. INT8 codes are
// interpreted in fixed point: value = code / SCALE (same scale in and out).
// Change SCALE to match a layer's real activation scale.
//
// The initial block uses real arithmetic, evaluated once at elaboration; Vivado
// uses it to initialise the block ROM (no runtime cost, no external file).
//==============================================================================
module silu_lut #(
  parameter real SCALE = 16.0      // INT8 codes per unit -> range [-8, +8)
)(
  input  logic                clk,
  input  logic signed [7:0]   x,   // pre-activation INT8
  output logic signed [7:0]   y    // SiLU(x) INT8, 1-cycle latency
);

  (* rom_style = "distributed" *) logic [7:0] rom [0:255];

  // ---- build the table at elaboration (no file) ----
  initial begin
    int   code_in, code_out;
    real  v, s, yv;
    for (int i = 0; i < 256; i++) begin
      code_in = (i < 128) ? i : i - 256;          // signed INT8 view
      v  = code_in / SCALE;                        // real value
      s  = 1.0 / (1.0 + $exp(-v));                 // sigmoid
      yv = v * s;                                  // SiLU
      code_out = $rtoi(yv * SCALE + (yv >= 0.0 ? 0.5 : -0.5)); // round
      if (code_out >  127) code_out =  127;        // clamp
      if (code_out < -128) code_out = -128;
      rom[i] = code_out[7:0];
    end
  end

  // index by the unsigned view of the signed input
  always_ff @(posedge clk)
    y <= $signed(rom[x[7:0]]);

endmodule
