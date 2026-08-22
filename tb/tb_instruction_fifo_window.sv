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

        tick;
        tick;
        rst_n = 1'b1;
        tick;

        // NOTE: expected values below are derived from the ACTUAL rom[] program
        // in instructions_fifo.sv (opcode-encoded, not sequential indices):
        //   rom[0]=NOP            32'h00000000
        //   rom[1]=LOAD_WGT       32'h10000400
        //   rom[2]=LOAD_ACT       32'h20000400
        //   rom[3]=LOAD_BIAS      32'h30000100
        //   rom[4]=SWAP_WGT       32'h70000000
        //   rom[5]=MATMUL         32'h40000000
        //   rom[6..15]=0 (rom[6]=VECTOR/rom[7]=STORE/rom[8]=END unused by this
        //   generic windowing test, since it only ever pops far enough to reach
        //   rom[5] before wrapping into the trailing zero-filled entries).
        check_window("reset window", 32'h00000000, 32'h10000400, 32'h20000400, 32'h30000100);

        pulse_pop(0);
        check_window("pop0", 32'h10000400, 32'h20000400, 32'h30000100, 32'h70000000);

        pulse_pop(2);
        check_window("pop2", 32'h10000400, 32'h20000400, 32'h70000000, 32'h40000000);

        // 11 more full-window pops walk fetch_ptr from 6 up through 15, wrap to
        // 0, and land on 1 — i.e. the window ends up holding rom[13..15] and
        // rom[0], all of which are zero-valued in this program.
        repeat (11) pulse_pop(0);
        check_window("wrap", 32'h00000000, 32'h00000000, 32'h00000000, 32'h00000000);

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