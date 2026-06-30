// =============================================================================
// tb_control_unit.sv  —  sequencing/strobe check for the standalone Control Unit
//   Run: iverilog -g2012 -o tb ../rtl/control_unit.sv tb_control_unit.sv && vvp tb
//
//  Drives one run (start → … → done) with num_acts=3, ARRAY_SIZE=4, and checks
//  the emitted strobe cycle-counts and address sequencing match the spec:
//    weight preload = ARRAY_SIZE writes, 1 swap, act writes = num_acts*ARRAY_SIZE,
//    act reads = num_acts, drain reads = num_acts.
// =============================================================================

`timescale 1ns/1ps

module tb_control_unit;
    localparam integer ARRAY_SIZE = 4;
    localparam integer ACT_DEPTH  = 64;
    localparam integer OUT_DEPTH  = 64;
    localparam integer ACT_AW     = $clog2(ACT_DEPTH);
    localparam integer OUT_AW     = $clog2(OUT_DEPTH);
    localparam integer BANK_W     = $clog2(ARRAY_SIZE);
    localparam integer NACTS      = 3;
    localparam [3:0] S_COMPUTE = 4'd7;
    localparam       CLK_PERIOD = 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg               start_pulse, soft_reset;
    reg  [15:0]       num_acts;
    wire              busy, done;
    wire [3:0]        fsm_state;
    wire              loading_weights, streaming_acts;
    wire              wt_wr_en, wt_rd_en, weight_swap, wt_wr_buf, wt_rd_buf;
    wire [BANK_W-1:0] wt_wr_row;
    wire              act_wr_en, act_rd_en, act_wr_buf, act_rd_buf;
    wire [BANK_W-1:0] act_wr_bank;
    wire [ACT_AW-1:0] act_wr_addr, act_rd_addr;
    wire              out_rd_en, out_wr_buf;
    wire [OUT_AW-1:0] out_rd_addr;

    // perf_valid: assert once the FSM reaches COMPUTE
    reg perf_valid;
    always @(*) perf_valid = (fsm_state == S_COMPUTE);

    control_unit #(.ARRAY_SIZE(ARRAY_SIZE), .ACT_DEPTH(ACT_DEPTH), .OUT_DEPTH(OUT_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .start_pulse(start_pulse), .soft_reset(soft_reset),
        .perf_valid(perf_valid), .num_acts(num_acts),
        .busy(busy), .done(done), .fsm_state(fsm_state),
        .loading_weights(loading_weights), .streaming_acts(streaming_acts),
        .wt_wr_en(wt_wr_en), .wt_wr_row(wt_wr_row), .wt_wr_buf(wt_wr_buf),
        .wt_rd_en(wt_rd_en), .wt_rd_buf(wt_rd_buf), .weight_swap(weight_swap),
        .act_wr_en(act_wr_en), .act_wr_bank(act_wr_bank), .act_wr_addr(act_wr_addr),
        .act_wr_buf(act_wr_buf),
        .act_rd_en(act_rd_en), .act_rd_addr(act_rd_addr), .act_rd_buf(act_rd_buf),
        .out_rd_en(out_rd_en), .out_rd_addr(out_rd_addr), .out_wr_buf(out_wr_buf));

    integer pass_cnt=0, fail_cnt=0;
    integer c_wt=0, c_swap=0, c_awr=0, c_ard=0, c_ord=0;
    reg seen_wrow0, seen_wrowN, seen_ard0, seen_ardN, seen_ord0, seen_ordN;

    // strobe monitors
    always @(posedge clk) begin
        if (wt_wr_en)   begin c_wt=c_wt+1; if (wt_wr_row==0) seen_wrow0=1; if (wt_wr_row==ARRAY_SIZE-1) seen_wrowN=1; end
        if (weight_swap)  c_swap=c_swap+1;
        if (act_wr_en)    c_awr=c_awr+1;
        if (act_rd_en)  begin c_ard=c_ard+1; if (act_rd_addr==0) seen_ard0=1; if (act_rd_addr==NACTS-1) seen_ardN=1; end
        if (out_rd_en)  begin c_ord=c_ord+1; if (out_rd_addr==0) seen_ord0=1; if (out_rd_addr==NACTS-1) seen_ordN=1; end
    end

    task check(input [255:0] tag, input integer got, exp);
        begin if (got===exp) pass_cnt=pass_cnt+1;
              else begin $display("  FAIL %s got=%0d exp=%0d",tag,got,exp); fail_cnt=fail_cnt+1; end end
    endtask

    initial begin
        $dumpfile("tb_control_unit.vcd"); $dumpvars(0, tb_control_unit);
        start_pulse=0; soft_reset=0; num_acts=NACTS;
        seen_wrow0=0; seen_wrowN=0; seen_ard0=0; seen_ardN=0; seen_ord0=0; seen_ordN=0;
        rst_n=0; repeat(4) @(posedge clk); @(negedge clk); rst_n=1; repeat(2) @(posedge clk);

        @(negedge clk); start_pulse=1; @(negedge clk); start_pulse=0;

        wait (done === 1'b1);
        repeat(2) @(posedge clk);

        check("weight writes",  c_wt,   ARRAY_SIZE);
        check("weight swaps",   c_swap, 1);
        check("act writes",     c_awr,  NACTS*ARRAY_SIZE);
        check("act reads",      c_ard,  NACTS);
        check("drain reads",    c_ord,  NACTS);
        check("wrow hit 0",     seen_wrow0, 1);
        check("wrow hit N-1",   seen_wrowN, 1);
        check("ard hit 0",      seen_ard0, 1);
        check("ard hit N-1",    seen_ardN, 1);
        check("ord hit 0",      seen_ord0, 1);
        check("ord hit N-1",    seen_ordN, 1);

        $display("\n==================================");
        $display("  CONTROL_UNIT TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL CONTROL_UNIT TESTS PASSED");
        else             $display("  CONTROL_UNIT TESTS FAILED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*20000); $display("CONTROL_UNIT WATCHDOG (done=%0b)", done); $finish; end
endmodule
