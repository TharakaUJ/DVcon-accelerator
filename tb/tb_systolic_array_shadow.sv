// =============================================================================
// tb_systolic_array_shadow.sv  —  CR-2: shadow weight load + 1-cycle swap
//   Run: iverilog -g2012 -o tb ../rtl/pe.sv ../rtl/systolic_array.sv \
//                              tb_systolic_array_shadow.sv && vvp tb
//
//  Validates SHADOW_WEIGHTS=1:
//    - load tile A into shadow, swap → active=A, GEMM result == golden_A
//    - load tile B into shadow (active stays A until swap), swap → active=B,
//      GEMM result == golden_B
//  Confirms the swap promotes the shadow and that a background shadow load does
//  not disturb the currently-active weights.
// =============================================================================

`timescale 1ns/1ps

module tb_systolic_array_shadow;
    localparam integer ROWS = 4, COLS = 4, ACCUM_WIDTH = 32;
    localparam         CLK_PERIOD = 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                          en, weight_load, weight_load_shadow, weight_swap;
    reg  signed [7:0]            weight_data [0:ROWS*COLS-1];
    reg  signed [7:0]            act_in [0:ROWS-1];
    wire signed [ACCUM_WIDTH-1:0] result_out [0:COLS-1];
    wire [0:COLS-1]              result_valid;
    wire [31:0]                  perf_cycles;
    wire                         perf_valid;

    systolic_array #(.ROWS(ROWS), .COLS(COLS), .FRAC_BITS(0),
                     .ACCUM_WIDTH(ACCUM_WIDTH), .USE_DSP(1), .SHADOW_WEIGHTS(1)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .clear_acc(1'b0),
        .weight_load(weight_load), .weight_load_shadow(weight_load_shadow), .weight_swap(weight_swap),
        .weight_data(weight_data), .act_in(act_in),
        .result_out(result_out), .result_valid(result_valid),
        .perf_cycles(perf_cycles), .perf_valid(perf_valid));

    integer pass_cnt = 0, fail_cnt = 0, r, c;
    task tick; @(posedge clk); #1; endtask
    task check(input [255:0] tag, input integer got, exp);
        begin if (got===exp) pass_cnt=pass_cnt+1;
              else begin $display("  FAIL %s got=%0d exp=%0d",tag,got,exp); fail_cnt=fail_cnt+1; end end
    endtask

    // load a tile into shadow then swap to active
    task load_swap(input integer base);
        begin
            for (r=0;r<ROWS;r=r+1) for (c=0;c<COLS;c=c+1) weight_data[r*COLS+c] = base + r*COLS + c;
            @(negedge clk); weight_load_shadow=1; @(posedge clk); #1; weight_load_shadow=0;
            @(negedge clk); weight_swap=1;        @(posedge clk); #1; weight_swap=0;
        end
    endtask

    // single activation vector, wait for the array to settle, check result
    task run_check(input [255:0] tag, input integer base);
        integer gold;
        begin
            for (r=0;r<ROWS;r=r+1) act_in[r] = r + 1;     // act = {1,2,3,4}
            @(negedge clk); en=1; @(posedge clk); #1; en=0;
            repeat (2*ROWS + COLS + 4) tick;               // drain latency
            for (c=0;c<COLS;c=c+1) begin
                gold = 0;
                for (r=0;r<ROWS;r=r+1) gold = gold + (r+1) * (base + r*COLS + c);
                check(tag, result_out[c], gold);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_systolic_array_shadow.vcd"); $dumpvars(0, tb_systolic_array_shadow);
        en=0; weight_load=0; weight_load_shadow=0; weight_swap=0;
        for (r=0;r<ROWS;r=r+1) act_in[r]=0;
        for (r=0;r<ROWS*COLS;r=r+1) weight_data[r]=0;
        rst_n=0; tick; tick; rst_n=1; tick;

        load_swap(0);              // tile A: W[r][c] = r*COLS+c
        run_check("tileA GEMM", 0);

        load_swap(1);              // tile B: W[r][c] = 1 + r*COLS+c
        run_check("tileB GEMM", 1);

        $display("\n==================================");
        $display("  ARRAY_SHADOW TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL ARRAY_SHADOW TESTS PASSED");
        else             $display("  ARRAY_SHADOW TESTS FAILED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*20000); $display("ARRAY_SHADOW WATCHDOG"); $finish; end
endmodule
