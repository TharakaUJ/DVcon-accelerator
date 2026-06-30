// =============================================================================
// tb_pe_pair.sv  —  CR-4: bit-exact check of the DSP-packed dual MAC
//   Run: iverilog -g2012 -o tb ../rtl/pe_pair.sv tb_pe_pair.sv && vvp tb
//
//  Verifies pe_pair (PACK_DSP=1 packed and PACK_DSP=0 unpacked) produce the
//  same registered psum results as a behavioural reference across randomized
//  INT8 inputs, including saturation corners. (CR-4 acceptance.)
// =============================================================================

`timescale 1ns/1ps

module tb_pe_pair;
    localparam integer ACCUM_WIDTH = 32;
    localparam         CLK_PERIOD  = 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                          en0, en1;
    reg  signed [7:0]            act, w0, w1;
    reg  signed [ACCUM_WIDTH-1:0] p0_in, p1_in;
    reg                          p0_v, p1_v;

    wire signed [ACCUM_WIDTH-1:0] p0_out_pk, p1_out_pk, p0_out_un, p1_out_un;
    wire                          v0_pk, v1_pk, v0_un, v1_un;

    localparam signed [ACCUM_WIDTH-1:0] SAT_MAX = {1'b0,{(ACCUM_WIDTH-1){1'b1}}};
    localparam signed [ACCUM_WIDTH-1:0] SAT_MIN = {1'b1,{(ACCUM_WIDTH-1){1'b0}}};

    pe_pair #(.ACCUM_WIDTH(ACCUM_WIDTH), .PACK_DSP(1)) dut_pk (
        .clk(clk), .rst_n(rst_n), .en0(en0), .en1(en1),
        .act_in(act), .weight0_in(w0), .weight1_in(w1),
        .psum0_in(p0_in), .psum0_in_valid(p0_v),
        .psum1_in(p1_in), .psum1_in_valid(p1_v),
        .psum0_out(p0_out_pk), .out0_valid(v0_pk),
        .psum1_out(p1_out_pk), .out1_valid(v1_pk));

    pe_pair #(.ACCUM_WIDTH(ACCUM_WIDTH), .PACK_DSP(0)) dut_un (
        .clk(clk), .rst_n(rst_n), .en0(en0), .en1(en1),
        .act_in(act), .weight0_in(w0), .weight1_in(w1),
        .psum0_in(p0_in), .psum0_in_valid(p0_v),
        .psum1_in(p1_in), .psum1_in_valid(p1_v),
        .psum0_out(p0_out_un), .out0_valid(v0_un),
        .psum1_out(p1_out_un), .out1_valid(v1_un));

    integer pass_cnt = 0, fail_cnt = 0, i;
    task tick; @(posedge clk); #1; endtask

    // Behavioural reference for one lane (FRAC_BITS=0, SATURATE=1)
    function signed [ACCUM_WIDTH-1:0] ref_lane(
        input signed [7:0] a, input signed [7:0] w,
        input signed [ACCUM_WIDTH-1:0] pin, input pv);
        reg signed [ACCUM_WIDTH-1:0] base, prod;
        reg signed [ACCUM_WIDTH:0]   s;
        begin
            base = pv ? pin : 0;
            prod = a * w;
            s = {base[ACCUM_WIDTH-1],base} + {prod[ACCUM_WIDTH-1],prod};
            if (~s[ACCUM_WIDTH] &  s[ACCUM_WIDTH-1]) ref_lane = SAT_MAX;
            else if ( s[ACCUM_WIDTH] & ~s[ACCUM_WIDTH-1]) ref_lane = SAT_MIN;
            else ref_lane = s[ACCUM_WIDTH-1:0];
        end
    endfunction

    task check(input [255:0] tag, input signed [ACCUM_WIDTH-1:0] got, exp);
        begin
            if (got === exp) pass_cnt = pass_cnt + 1;
            else begin
                $display("  FAIL %s got=%0d exp=%0d", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task drive(input signed [7:0] a, ww0, ww1,
               input signed [ACCUM_WIDTH-1:0] pi0, pi1, input pv0, pv1);
        reg signed [ACCUM_WIDTH-1:0] e0, e1;
        begin
            act=a; w0=ww0; w1=ww1; p0_in=pi0; p1_in=pi1; p0_v=pv0; p1_v=pv1;
            en0=1; en1=1; tick; en0=0; en1=0;
            e0 = ref_lane(a, ww0, pi0, pv0);
            e1 = ref_lane(a, ww1, pi1, pv1);
            check("pk lane0", p0_out_pk, e0);
            check("pk lane1", p1_out_pk, e1);
            check("un lane0", p0_out_un, e0);
            check("un lane1", p1_out_un, e1);
        end
    endtask

    initial begin
        $dumpfile("tb_pe_pair.vcd"); $dumpvars(0, tb_pe_pair);
        en0=0; en1=0; act=0; w0=0; w1=0; p0_in=0; p1_in=0; p0_v=0; p1_v=0;
        rst_n=0; tick; tick; rst_n=1; tick;

        // directed sign corners
        drive(8'sd3,  8'sd4,  -8'sd4, 32'sd0,   32'sd0,   0, 0);
        drive(-8'sd5, 8'sd7,   8'sd2, 32'sd100, 32'sd50,  1, 1);
        drive(-8'sd1, -8'sd1, -8'sd128,32'sd0,  32'sd0,   0, 0);
        drive(8'sd2,  8'sd2,   8'sd2, SAT_MAX,  SAT_MIN,  1, 1); // saturation

        // randomized
        for (i = 0; i < 500; i = i + 1) begin
            drive($random, $random, $random, $random, $random, $random&1, $random&1);
        end

        $display("\n==================================");
        $display("  PE_PAIR TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL PE_PAIR TESTS PASSED");
        $display("==================================");
        $finish;
    end

    initial begin #(CLK_PERIOD*20000); $display("PE_PAIR WATCHDOG"); $finish; end
endmodule
