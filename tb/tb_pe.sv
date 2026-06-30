// =============================================================================
// pe_mac_int8.v  —  INT8 Fixed-Point MAC Processing Element
// =============================================================================
//
//  Parameters
//  ----------
//  FRAC_BITS        : number of fractional bits in Q(8-FRAC_BITS).FRAC_BITS
//                     representation (0 = pure integer, ≤7 recommended)
//  ACCUM_WIDTH      : accumulator width (default 32 bits)
//  SATURATE         : 1 = saturate on overflow, 0 = wrap (truncate)
//  ROUND_POLICY     : 0 = truncate toward -∞ (floor)
//                     1 = round-half-up
//                     2 = round-half-to-even (banker's rounding)
//
//  Ports
//  -----
//  clk              : clock (rising-edge triggered)
//  rst_n            : async active-low reset
//  en               : enable / valid-in
//  clear_acc        : synchronous accumulator clear (sets acc to 0)
//  a_in  [7:0]      : signed INT8 multiplicand
//  b_in  [7:0]      : signed INT8 multiplier
//  acc_in[ACCUM_WIDTH-1:0]: forwarded accumulator from upstream PE
//  use_forwarded    : 1 = start MAC from acc_in instead of internal acc
//
//  out   [ACCUM_WIDTH-1:0]: current accumulator value (registered)
//  out_valid        : output valid (registered, mirrors en one cycle later)
//  fwd_out[ACCUM_WIDTH-1:0]: forwarding port → feeds downstream PE's acc_in
//  fwd_valid        : forwarding valid
//
// =============================================================================

`timescale 1ns/1ps

module pe_mac_int8 #(
    parameter integer FRAC_BITS   = 0,
    parameter integer ACCUM_WIDTH = 32,
    parameter integer SATURATE    = 1,
    parameter integer ROUND_POLICY = 1       // 0=floor 1=half-up 2=half-even
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     en,
    input  wire                     clear_acc,

    // Data inputs
    input  wire signed [7:0]        a_in,
    input  wire signed [7:0]        b_in,

    // Forwarding / systolic interface
    input  wire signed [ACCUM_WIDTH-1:0] acc_in,
    input  wire                          use_forwarded,

    // Outputs
    output reg  signed [ACCUM_WIDTH-1:0] out,
    output reg                           out_valid,

    // Forwarding outputs (registered, for systolic chaining)
    output reg  signed [ACCUM_WIDTH-1:0] fwd_out,
    output reg                           fwd_valid
);

    // -------------------------------------------------------------------------
    // Local parameters
    // -------------------------------------------------------------------------
    localparam integer PROD_WIDTH = 16;           // 8b × 8b → 16b signed product
    localparam integer SHIFT      = FRAC_BITS;    // re-quantisation right-shift

    // Saturation limits for ACCUM_WIDTH
    localparam signed [ACCUM_WIDTH-1:0] SAT_MAX =
        {1'b0, {(ACCUM_WIDTH-1){1'b1}}};          // +2^(N-1)-1
    localparam signed [ACCUM_WIDTH-1:0] SAT_MIN =
        {1'b1, {(ACCUM_WIDTH-1){1'b0}}};          // -2^(N-1)

    // -------------------------------------------------------------------------
    // Stage 1 — Multiply (combinational)
    // -------------------------------------------------------------------------
    wire signed [PROD_WIDTH-1:0] product;
    assign product = a_in * b_in;                 // signed × signed

    // -------------------------------------------------------------------------
    // Stage 2 — Requantise product to accumulator word (combinational)
    // -------------------------------------------------------------------------
    // Full precision before shift: widen product to ACCUM_WIDTH
    wire signed [ACCUM_WIDTH-1:0] prod_wide;
    assign prod_wide = {{(ACCUM_WIDTH-PROD_WIDTH){product[PROD_WIDTH-1]}}, product};

    // Rounding increment
    wire signed [ACCUM_WIDTH-1:0] round_inc;
    generate
        if (FRAC_BITS == 0) begin : g_no_round
            assign round_inc = {ACCUM_WIDTH{1'b0}};
        end else if (ROUND_POLICY == 0) begin : g_floor
            // Truncate — no increment
            assign round_inc = {ACCUM_WIDTH{1'b0}};
        end else if (ROUND_POLICY == 1) begin : g_half_up
            // Round-half-up: add 0.5 LSB before shift
            // The '0.5 LSB' in the pre-shift domain is 2^(FRAC_BITS-1)
            assign round_inc = {{(ACCUM_WIDTH-FRAC_BITS){1'b0}},
                                {1'b1},
                                {(FRAC_BITS-1){1'b0}}};
        end else begin : g_half_even
            // Banker's rounding: add 0.5 LSB only when the bit just below
            // the shift point is 1 AND the result is not already exact half
            wire halfway;
            wire [FRAC_BITS-1:0] frac_bits_val;
            assign frac_bits_val = prod_wide[FRAC_BITS-1:0];
            // halfway when lower bits == 1000...0
            assign halfway = (frac_bits_val == (1 << (FRAC_BITS-1)));
            // sticky: any bit below the half bit
            wire sticky = (FRAC_BITS > 1) ?
                          |prod_wide[FRAC_BITS-2:0] : 1'b0;
            // lsb of result after shift (used for tie-break)
            wire result_lsb = prod_wide[FRAC_BITS];
            // round up when: not halfway, or halfway and result_lsb==1
            wire do_round = halfway ? result_lsb : prod_wide[FRAC_BITS-1];
            assign round_inc = do_round ?
                {{(ACCUM_WIDTH-FRAC_BITS){1'b0}}, {1'b1}, {(FRAC_BITS-1){1'b0}}} :
                {ACCUM_WIDTH{1'b0}};
        end
    endgenerate

    wire signed [ACCUM_WIDTH-1:0] prod_rounded;
    assign prod_rounded = prod_wide + round_inc;

    // Arithmetic right-shift (sign-extending)
    wire signed [ACCUM_WIDTH-1:0] prod_shifted;
    assign prod_shifted = prod_rounded >>> SHIFT;

    // -------------------------------------------------------------------------
    // Stage 3 — Accumulate (combinational)
    // -------------------------------------------------------------------------
    wire signed [ACCUM_WIDTH-1:0] acc_base;
    assign acc_base = (use_forwarded) ? acc_in : out;

    // Full-precision sum before saturation (one extra bit to detect overflow)
    wire signed [ACCUM_WIDTH:0] sum_full;
    assign sum_full = {acc_base[ACCUM_WIDTH-1], acc_base} +
                      {prod_shifted[ACCUM_WIDTH-1], prod_shifted};

    // Overflow detection
    wire overflow_pos = (~sum_full[ACCUM_WIDTH] & sum_full[ACCUM_WIDTH-1]);
    wire overflow_neg = ( sum_full[ACCUM_WIDTH] & ~sum_full[ACCUM_WIDTH-1]);
    wire overflow     = overflow_pos | overflow_neg;

    // Saturated or wrapped result
    wire signed [ACCUM_WIDTH-1:0] sum_sat;
    generate
        if (SATURATE) begin : g_sat
            assign sum_sat = overflow_pos ? SAT_MAX :
                             overflow_neg ? SAT_MIN :
                             sum_full[ACCUM_WIDTH-1:0];
        end else begin : g_wrap
            assign sum_sat = sum_full[ACCUM_WIDTH-1:0];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Stage 4 — Register outputs
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out       <= {ACCUM_WIDTH{1'b0}};
            out_valid <= 1'b0;
            fwd_out   <= {ACCUM_WIDTH{1'b0}};
            fwd_valid <= 1'b0;
        end else begin
            // Forwarding outputs mirror the registered accumulator
            fwd_out   <= out;
            fwd_valid <= out_valid;

            if (clear_acc) begin
                out       <= {ACCUM_WIDTH{1'b0}};
                out_valid <= 1'b0;
            end else if (en) begin
                out       <= sum_sat;
                out_valid <= 1'b1;
            end
            // If !en and !clear_acc: hold accumulator, deassert valid
            else begin
                out_valid <= 1'b0;
            end
        end
    end

endmodule

// =============================================================================
// tb_pe  —  Self-checking testbench for systolic_pe (the PE used by the array)
//   Run: iverilog -g2012 -o tb ../rtl/pe.sv tb_pe.sv && vvp tb
// =============================================================================
module tb_pe;

    localparam integer ACCUM_WIDTH = 32;
    localparam         CLK_PERIOD  = 10;

    reg  clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg                            rst_n;
    reg                            en;
    reg  signed [7:0]              weight_in;
    reg  signed [7:0]              act_in;
    reg  signed [ACCUM_WIDTH-1:0]  psum_in;
    reg                            psum_in_valid;
    wire signed [ACCUM_WIDTH-1:0]  psum_out;
    wire                           out_valid;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // FRAC_BITS=0 → pure integer MAC, matches the array configuration
    systolic_pe #(
        .FRAC_BITS(0), .ACCUM_WIDTH(ACCUM_WIDTH),
        .SATURATE(1),  .ROUND_POLICY(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .en(en),
        .weight_in(weight_in), .act_in(act_in),
        .psum_in(psum_in), .psum_in_valid(psum_in_valid),
        .psum_out(psum_out), .out_valid(out_valid)
    );

    task tick; @(posedge clk); #1; endtask

    task check;
        input [255:0] tag;
        input integer got;
        input integer exp;
        begin
            if (got === exp) begin
                $display("  PASS  %s  got=%0d", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %s  got=%0d  exp=%0d", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Drive one enabled MAC and sample the registered result
    task do_mac;
        input signed [7:0]             a;
        input signed [7:0]             w;
        input signed [ACCUM_WIDTH-1:0] pin;
        input                          pin_valid;
        begin
            act_in        = a;
            weight_in     = w;
            psum_in       = pin;
            psum_in_valid = pin_valid;
            en            = 1'b1;
            tick;                 // result registers on this edge
            en            = 1'b0;
        end
    endtask

    localparam signed [ACCUM_WIDTH-1:0] SAT_MAX = {1'b0, {(ACCUM_WIDTH-1){1'b1}}};
    localparam signed [ACCUM_WIDTH-1:0] SAT_MIN = {1'b1, {(ACCUM_WIDTH-1){1'b0}}};

    initial begin
        $dumpfile("tb_pe.vcd");
        $dumpvars(0, tb_pe);

        rst_n=0; en=0; weight_in=0; act_in=0; psum_in=0; psum_in_valid=0;
        tick; tick; rst_n=1; tick;

        // 1. Plain integer MAC, no upstream psum
        do_mac(8'sd3, 8'sd4, 32'sd0, 1'b0);
        check("MAC 3*4 (no psum)", psum_out, 12);
        check("out_valid after en", out_valid, 1);

        // 2. Accumulate with a valid upstream partial sum
        do_mac(8'sd2, 8'sd5, 32'sd100, 1'b1);
        check("MAC 2*5 + psum 100", psum_out, 110);

        // 3. Signed product
        do_mac(-8'sd3, 8'sd4, 32'sd0, 1'b0);
        check("MAC -3*4", psum_out, -12);

        // 4. psum_in ignored when psum_in_valid=0
        do_mac(8'sd7, 8'sd1, 32'sd999, 1'b0);
        check("psum_in ignored (valid=0)", psum_out, 7);

        // 5. Hold value and drop valid when en=0
        en = 1'b0; tick;
        check("psum_out held when en=0", psum_out, 7);
        check("out_valid low when en=0", out_valid, 0);

        // 6. Positive saturation
        do_mac(8'sd2, 8'sd2, SAT_MAX, 1'b1);
        check("positive saturation", psum_out, SAT_MAX);

        // 7. Negative saturation
        do_mac(-8'sd2, 8'sd2, SAT_MIN, 1'b1);
        check("negative saturation", psum_out, SAT_MIN);

        $display("\n==================================");
        $display("  PE TESTBENCH COMPLETE");
        $display("  Passed: %0d   Failed: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("  ALL PE TESTS PASSED");
        else               $display("  SOME PE TESTS FAILED");
        $display("==================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 2000);
        $display("PE TB WATCHDOG TIMEOUT");
        $finish;
    end

endmodule