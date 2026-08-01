`timescale 1ns/1ps

module tb_instruction_fifo_window;
    localparam integer INSTR_WIDTH = 24;
    localparam integer INSTR_DEPTH  = 16;
    localparam integer WINDOW_SIZE  = 4;
    localparam integer CLK_PERIOD   = 10;

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rst_n;
    reg pop_en;
    reg [$clog2(WINDOW_SIZE)-1:0] pop_idx;
    wire [INSTR_WIDTH-1:0] window [0:WINDOW_SIZE-1];

    instruction_fifo_window #(
        .INSTR_WIDTH(INSTR_WIDTH),
        .INSTR_DEPTH(INSTR_DEPTH),
        .WINDOW_SIZE(WINDOW_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .pop_en(pop_en),
        .pop_idx(pop_idx),
        .window(window)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check_word;
        input [255:0] tag;
        input [INSTR_WIDTH-1:0] got;
        input [INSTR_WIDTH-1:0] exp;
        begin
            if (got === exp) begin
                $display("  PASS %s got=0x%06h", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %s got=0x%06h exp=0x%06h", tag, got, exp);
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

        tick;
        tick;
        rst_n = 1'b1;
        tick;

        check_window("reset window", 24'h000000, 24'h000001, 24'h000002, 24'h000003);

        pulse_pop(0);
        check_window("pop0", 24'h000001, 24'h000002, 24'h000003, 24'h000004);

        pulse_pop(2);
        check_window("pop2", 24'h000001, 24'h000002, 24'h000004, 24'h000005);

        repeat (11) pulse_pop(0);
        check_window("wrap", 24'h00000D, 24'h00000E, 24'h00000F, 24'h000000);

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