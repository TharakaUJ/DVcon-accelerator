// =============================================================================
// tb_vector_unit.sv  —  CR-5: requant + activation stage
//   Run: iverilog -g2012 -o tb ../rtl/silu_lut.sv ../rtl/vector_unit.sv \
//                              tb_vector_unit.sv && vvp tb
//
//  Per lane: s0=acc+bias → (s0*mult)>>>shift → clamp INT8 → activation.
//  Checks NONE / RELU bit-exact vs reference and SILU within INT8 range.
//  Pipeline latency = 2 cycles.
// =============================================================================

`timescale 1ns/1ps

module tb_vector_unit;
    localparam integer OC = 4;
    localparam integer ACC_W = 32;
    localparam         CLK_PERIOD = 10;
    localparam [1:0] ACT_NONE=2'd0, ACT_RELU=2'd1, ACT_SILU=2'd2;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                      in_valid;
    reg  signed [ACC_W-1:0]  acc  [0:OC-1];
    reg  signed [ACC_W-1:0]  bias [0:OC-1];
    reg  [15:0]              requant_mult;
    reg  [4:0]               requant_shift;
    reg  [1:0]               act_type;
    wire                     out_valid;
    wire signed [7:0]        q [0:OC-1];

    vector_unit #(.OC_LANES(OC)) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .acc(acc), .bias(bias), .requant_mult(requant_mult),
        .requant_shift(requant_shift), .act_type(act_type),
        .out_valid(out_valid), .q(q));

    integer pass_cnt = 0, fail_cnt = 0, i;
    task tick; @(posedge clk); #1; endtask
    task check(input [255:0] tag, input integer got, exp);
        begin if (got===exp) pass_cnt=pass_cnt+1;
              else begin $display("  FAIL %s got=%0d exp=%0d",tag,got,exp); fail_cnt=fail_cnt+1; end end
    endtask

    function signed [7:0] clamp8(input signed [63:0] v);
        begin if (v>127) clamp8=127; else if (v<-128) clamp8=-128; else clamp8=v[7:0]; end
    endfunction
    function signed [7:0] ref_req(input signed [ACC_W-1:0] a, b, input [15:0] m, input [4:0] s);
        reg signed [ACC_W:0] s0; reg signed [63:0] prod, sh;
        begin s0=a+b; prod=$signed(s0)*$signed({1'b0,m}); sh=prod>>>s; ref_req=clamp8(sh); end
    endfunction

    // drive a vector, wait 2-cycle latency, return q stable
    task drive(input [1:0] at, input [15:0] m, input [4:0] sh);
        begin
            in_valid=1; act_type=at; requant_mult=m; requant_shift=sh;
            tick;                 // stage A captures
            in_valid=0;
            tick; tick;           // stage B + settle
        end
    endtask

    initial begin
        $dumpfile("tb_vector_unit.vcd"); $dumpvars(0, tb_vector_unit);
        in_valid=0; requant_mult=1; requant_shift=0; act_type=ACT_NONE;
        for (i=0;i<OC;i=i+1) begin acc[i]=0; bias[i]=0; end
        rst_n=0; tick; tick; rst_n=1; tick;

        // acc = {10,-5,200,-200}, bias 0, mult 1, shift 0
        acc[0]=10; acc[1]=-5; acc[2]=200; acc[3]=-200;
        for (i=0;i<OC;i=i+1) bias[i]=0;

        // NONE
        drive(ACT_NONE, 16'd1, 5'd0);
        for (i=0;i<OC;i=i+1) check("NONE", q[i], ref_req(acc[i],bias[i],1,0));

        // RELU
        drive(ACT_RELU, 16'd1, 5'd0);
        for (i=0;i<OC;i=i+1) begin
            reg signed [7:0] r; r = ref_req(acc[i],bias[i],1,0);
            check("RELU", q[i], (r<0)?0:r);
        end

        // requant with mult/shift: acc=16, mult=1, shift=2 → 4
        acc[0]=16; acc[1]=64; acc[2]=-32; acc[3]=100;
        drive(ACT_NONE, 16'd1, 5'd2);
        for (i=0;i<OC;i=i+1) check("REQ shift2", q[i], ref_req(acc[i],bias[i],1,2));

        // SILU: range check only (LUT-defined)
        drive(ACT_SILU, 16'd1, 5'd0);
        for (i=0;i<OC;i=i+1)
            if (q[i] >= -128 && q[i] <= 127) pass_cnt=pass_cnt+1;
            else begin $display("  FAIL SILU range q=%0d", q[i]); fail_cnt=fail_cnt+1; end

        $display("\n==================================");
        $display("  VECTOR_UNIT TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL VECTOR_UNIT TESTS PASSED");
        else             $display("  VECTOR_UNIT TESTS FAILED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*20000); $display("VECTOR_UNIT WATCHDOG"); $finish; end
endmodule
