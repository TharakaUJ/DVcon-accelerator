`timescale 1ns/1ps

module tb_instruction_fifo_window;
    localparam integer INSTR_WIDTH = 32;   // was 24 — see control_unit.sv/instructions_fifo.sv (accum_ctrl field added)
    localparam integer INSTR_DEPTH  = 16;
    localparam integer WINDOW_SIZE  = 4;
    localparam integer CLK_PERIOD   = 10;

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rst_n;
    reg pop_en;
    reg [$clog2(WINDOW_SIZE)-1:0] pop_idx;
    wire [INSTR_WIDTH-1:0] window [0:WINDOW_SIZE-1];
    reg restart;
    reg wr_en;
    reg [$clog2(INSTR_DEPTH)-1:0] wr_addr;
    reg [INSTR_WIDTH-1:0] wr_data;
    reg [31:0] prog_len;

    localparam [INSTR_WIDTH-1:0] END_WORD = 32'h8000_0000;
    // distinct, recognisable word per slot (contents are opaque to the FIFO)
    function automatic [INSTR_WIDTH-1:0] W(input integer i);
        W = 32'h00C0_0000 | i;
    endfunction

    instruction_fifo_window #(
        .INSTR_WIDTH(INSTR_WIDTH),
        .INSTR_DEPTH(INSTR_DEPTH),
        .WINDOW_SIZE(WINDOW_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .pop_en(pop_en),
        .pop_idx(pop_idx),
        .window(window),
        .restart(restart),
        .wr_en(wr_en),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .prog_len(prog_len)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check_word;
        input [255:0] tag;
        input [INSTR_WIDTH-1:0] got;
        input [INSTR_WIDTH-1:0] exp;
        begin
            if (got === exp) begin
                $display("  PASS %s got=0x%08h", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %s got=0x%08h exp=0x%08h", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task pulse_pop;
        input [$clog2(WINDOW_SIZE)-1:0] idx;
        begin
            @(negedge clk);
            pop_idx = idx;
            pop_en  = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            pop_en  = 1'b0;
        end
    endtask

    task check_window;
        input [255:0] tag;
        input [INSTR_WIDTH-1:0] e0;
        input [INSTR_WIDTH-1:0] e1;
        input [INSTR_WIDTH-1:0] e2;
        input [INSTR_WIDTH-1:0] e3;
        begin
            check_word({tag, "[0]"}, window[0], e0);
            check_word({tag, "[1]"}, window[1], e1);
            check_word({tag, "[2]"}, window[2], e2);
            check_word({tag, "[3]"}, window[3], e3);
        end
    endtask

    initial begin
        $dumpfile("tb_instruction_fifo_window.vcd");
        $dumpvars(0, tb_instruction_fifo_window);

        rst_n = 0;
        pop_en = 0;
        pop_idx = 0;
        restart = 0;
        wr_en = 0;
        wr_addr = 0;
        wr_data = 0;
        prog_len = 0;

        tick;
        tick;
        rst_n = 1'b1;
        tick;

        // Reset: the window is all END, and with prog_len = 0 (nothing
        // programmed) a restart still only fetches END.
        check_window("reset window", END_WORD, END_WORD, END_WORD, END_WORD);
        @(negedge clk); restart = 1'b1;
        tick;
        @(negedge clk); restart = 1'b0;
        check_window("restart, prog_len=0", END_WORD, END_WORD, END_WORD, END_WORD);

        // Program every slot through the write port, then restart (as
        // start_pulse does) to refill the window from slot 0.
        for (integer i = 0; i < INSTR_DEPTH; i = i + 1) begin
            @(negedge clk);
            wr_en = 1'b1; wr_addr = i; wr_data = W(i);
        end
        @(negedge clk);
        wr_en = 1'b0;
        check_window("written, before restart", END_WORD, END_WORD, END_WORD, END_WORD);
        prog_len = INSTR_DEPTH;
        @(negedge clk); restart = 1'b1;
        tick;
        @(negedge clk); restart = 1'b0;
        check_window("restart window", W(0), W(1), W(2), W(3));

        pulse_pop(0);
        check_window("pop0", W(1), W(2), W(3), W(4));

        pulse_pop(2);
        check_window("pop2", W(1), W(2), W(4), W(5));

        // 11 more full-window pops fetch slots 6..15 and then run off the end
        // of memory: no wrap-around, the window fills with END.
        repeat (11) pulse_pop(0);
        check_window("end of memory", W(13), W(14), W(15), END_WORD);
        repeat (3) pulse_pop(0);
        check_window("past end of memory", END_WORD, END_WORD, END_WORD, END_WORD);

        // restart rewinds to slot 0 again
        @(negedge clk); restart = 1'b1;
        tick;
        @(negedge clk); restart = 1'b0;
        check_window("second restart", W(0), W(1), W(2), W(3));

        // A shorter program: slots at/after prog_len read as END even though
        // they still hold words from the previous program.
        prog_len = 6;
        @(negedge clk); restart = 1'b1;
        tick;
        @(negedge clk); restart = 1'b0;
        pulse_pop(0);
        check_window("prog_len=6 pop", W(1), W(2), W(3), W(4));
        pulse_pop(0);
        check_window("prog_len=6 at limit", W(2), W(3), W(4), W(5));
        pulse_pop(0);
        check_window("prog_len=6 past limit", W(3), W(4), W(5), END_WORD);

        $display("\n==================================");
        $display("  INSTR FIFO TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("  ALL INSTR FIFO TESTS PASSED");
        else               $display("  INSTR FIFO TESTS FAILED");
        $display("==================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 2000);
        $display("INSTR FIFO WATCHDOG");
        $finish;
    end

endmodule