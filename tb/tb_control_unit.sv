// =============================================================================
// tb_control_unit.sv -- smoke test for the refactored Control Unit
//   Run: iverilog -g2012 -o tb ../rtl/control_unit.sv tb_control_unit.sv && vvp tb
//
//  This test drives a small decoded instruction window through the scheduler,
//  checks that the controller issues one packet at a time, and models simple
//  one-cycle completion events from the dispatched pulses.
// =============================================================================

`timescale 1ns/1ps

module tb_control_unit;
    localparam integer ARRAY_SIZE = 4;
    localparam integer ACT_DEPTH  = 64;
    localparam integer OUT_DEPTH  = 64;
    localparam integer ACT_AW     = $clog2(ACT_DEPTH);
    localparam integer OUT_AW     = $clog2(OUT_DEPTH);
    localparam integer BANK_W     = $clog2(ARRAY_SIZE);
    localparam integer WINDOW_SIZE = 4;
    localparam integer INSTR_WIDTH = 24;
    localparam       CLK_PERIOD = 10;

    localparam logic [3:0] OP_NOP      = 4'd0;
    localparam logic [3:0] OP_LOAD_WGT = 4'd1;
    localparam logic [3:0] OP_LOAD_ACT = 4'd2;
    localparam logic [3:0] OP_MATMUL   = 4'd3;
    localparam logic [3:0] OP_VECTOR   = 4'd4;
    localparam logic [3:0] OP_STORE    = 4'd5;
    localparam logic [3:0] OP_SWAP_WGT = 4'd6;
    localparam logic [3:0] OP_END      = 4'd7;

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
    wire              out_rd_en, out_wr_en, out_wr_buf, out_rd_buf;
    wire [OUT_AW-1:0] out_rd_addr;
    wire              array_en, array_clear_acc, array_weight_load;
    wire              fifo_pop_en;
    wire [$clog2(WINDOW_SIZE)-1:0] fifo_pop_idx;
    reg  [INSTR_WIDTH-1:0] fifo_window [0:WINDOW_SIZE-1];
    reg  [INSTR_WIDTH-1:0] program [0:7];
    integer program_ptr;

    reg prev_wt_wr_en, prev_act_wr_en, prev_array_en, prev_out_rd_en, prev_out_wr_en;
    wire dma_rd_done = prev_wt_wr_en | prev_act_wr_en;
    wire dma_wr_done = prev_out_rd_en;
    wire array_done  = prev_array_en;
    wire vector_done = prev_out_wr_en;

    integer pass_cnt=0, fail_cnt=0;
    integer c_wt=0, c_swap=0, c_awr=0, c_ard=0, c_ord=0, c_vec=0;
    reg seen_wrow0, seen_ard0, seen_ord0;

    function automatic [INSTR_WIDTH-1:0] make_inst(
        input logic [3:0] opcode,
        input logic [1:0] src,
        input logic [1:0] dst,
        input logic [7:0] addr,
        input logic [7:0] length
    );
        make_inst = {length, addr, dst, src, opcode};
    endfunction

    task check(input [255:0] tag, input integer got, exp);
        begin
            if (got === exp) pass_cnt = pass_cnt + 1;
            else begin
                $display("  FAIL %s got=%0d exp=%0d", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task load_window_from_program;
        integer i;
        begin
            for (i = 0; i < WINDOW_SIZE; i = i + 1) begin
                if ((program_ptr + i) < 8)
                    fifo_window[i] = program[program_ptr + i];
                else
                    fifo_window[i] = make_inst(OP_NOP, 2'd0, 2'd0, 8'd0, 8'd0);
            end
            program_ptr = program_ptr + WINDOW_SIZE;
        end
    endtask

    always @(posedge clk) begin
        prev_wt_wr_en   <= wt_wr_en;
        prev_act_wr_en  <= act_wr_en;
        prev_array_en   <= array_en;
        prev_out_rd_en  <= out_rd_en;
        prev_out_wr_en  <= out_wr_en;

        if (wt_wr_en) begin
            c_wt = c_wt + 1;
            if (wt_wr_row == 0) seen_wrow0 = 1;
        end
        if (weight_swap) c_swap = c_swap + 1;
        if (act_wr_en) c_awr = c_awr + 1;
        if (act_rd_en) begin
            c_ard = c_ard + 1;
            if (act_rd_addr == 0) seen_ard0 = 1;
        end
        if (out_rd_en) begin
            c_ord = c_ord + 1;
            if (out_rd_addr == 3) seen_ord0 = 1;
        end
        if (out_wr_en) c_vec = c_vec + 1;

        if (fifo_pop_en) begin
            integer j;
            for (j = fifo_pop_idx; j < WINDOW_SIZE - 1; j = j + 1) begin
                fifo_window[j] <= fifo_window[j + 1];
            end
            if (program_ptr < 8) begin
                fifo_window[WINDOW_SIZE - 1] <= program[program_ptr];
                program_ptr <= program_ptr + 1;
            end
            else begin
                fifo_window[WINDOW_SIZE - 1] <= make_inst(OP_NOP, 2'd0, 2'd0, 8'd0, 8'd0);
            end
        end
    end

    control_unit #(.ARRAY_SIZE(ARRAY_SIZE), .ACT_DEPTH(ACT_DEPTH), .OUT_DEPTH(OUT_DEPTH)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_pulse(start_pulse),
        .soft_reset(soft_reset),
        .perf_valid(array_done),
        .num_acts(num_acts),
        .dma_rd_done(dma_rd_done),
        .dma_wr_done(dma_wr_done),
        .array_done(array_done),
        .vector_done(vector_done),
        .busy(busy),
        .done(done),
        .fsm_state(fsm_state),
        .loading_weights(loading_weights),
        .streaming_acts(streaming_acts),
        .wt_wr_en(wt_wr_en),
        .wt_wr_row(wt_wr_row),
        .wt_wr_buf(wt_wr_buf),
        .wt_rd_en(wt_rd_en),
        .wt_rd_buf(wt_rd_buf),
        .weight_swap(weight_swap),
        .act_wr_en(act_wr_en),
        .act_wr_bank(act_wr_bank),
        .act_wr_addr(act_wr_addr),
        .act_wr_buf(act_wr_buf),
        .act_rd_en(act_rd_en),
        .act_rd_addr(act_rd_addr),
        .act_rd_buf(act_rd_buf),
        .out_rd_en(out_rd_en),
        .out_rd_addr(out_rd_addr),
        .out_rd_buf(out_rd_buf),
        .out_wr_en(out_wr_en),
        .out_wr_addr(),
        .out_wr_buf(out_wr_buf),
        .array_en(array_en),
        .array_clear_acc(array_clear_acc),
        .array_weight_load(array_weight_load),
        .fifo_pop_en(fifo_pop_en),
        .fifo_pop_idx(fifo_pop_idx),
        .fifo_window(fifo_window)
    );

    initial begin
        $dumpfile("tb_control_unit.vcd");
        $dumpvars(0, tb_control_unit);

        start_pulse = 0;
        soft_reset = 0;
        num_acts = 16'd1;
        seen_wrow0 = 0;
        seen_ard0 = 0;
        seen_ord0 = 0;
        rst_n = 0;

        program[0] = make_inst(OP_LOAD_WGT, 2'd0, 2'd0, 8'd0, 8'd1);
        program[1] = make_inst(OP_SWAP_WGT, 2'd0, 2'd0, 8'd0, 8'd0);
        program[2] = make_inst(OP_LOAD_ACT, 2'd0, 2'd0, 8'd1, 8'd1);
        program[3] = make_inst(OP_MATMUL,   2'd0, 2'd0, 8'd2, 8'd1);
        program[4] = make_inst(OP_VECTOR,   2'd0, 2'd1, 8'd3, 8'd1);
        program[5] = make_inst(OP_STORE,    2'd1, 2'd0, 8'd4, 8'd1);
        program[6] = make_inst(OP_END,      2'd0, 2'd0, 8'd0, 8'd0);
        program[7] = make_inst(OP_NOP,      2'd0, 2'd0, 8'd0, 8'd0);
        program_ptr = 4;
        load_window_from_program();

        repeat(4) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat(2) @(posedge clk);

        @(negedge clk); start_pulse = 1;
        @(negedge clk); start_pulse = 0;

        wait (done === 1'b1);
        repeat(2) @(posedge clk);

        check("weight writes", c_wt, 1);
        check("weight swaps", c_swap, 1);
        check("act writes", c_awr, 1);
        check("act reads", c_ard, 1);
        check("drain reads", c_ord, 1);
        check("vector writes", c_vec, 1);
        check("wrow hit 0", seen_wrow0, 1);
        check("ard hit 0", seen_ard0, 1);
        check("ord hit 0", seen_ord0, 1);

        $display("\n==================================");
        $display("  CONTROL_UNIT TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("  ALL CONTROL_UNIT TESTS PASSED");
        else               $display("  CONTROL_UNIT TESTS FAILED");
        $display("==================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 20000);
        $display("CONTROL_UNIT WATCHDOG (done=%0b)", done);
        $finish;
    end
endmodule
