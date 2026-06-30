// =============================================================================
// tb_bram_weight_buffer.sv  —  CR-2: weight BRAM, row-write / tile-read
//   Run: iverilog -g2012 -o tb ../rtl/bram_weight_buffer.sv tb_bram_weight_buffer.sv && vvp tb
//
//  Checks: per-row write, whole-tile flat read (1-cycle latency), and that the
//  two double-buffer slots hold independent tiles.
// =============================================================================

`timescale 1ns/1ps

module tb_bram_weight_buffer;
    localparam integer DATA_W = 8;
    localparam integer ROWS   = 4;
    localparam integer COLS   = 4;
    localparam integer ROW_W  = COLS*DATA_W;
    localparam         CLK_PERIOD = 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                       wr_en, wr_buf;
    reg  [$clog2(ROWS)-1:0]   wr_row;
    reg  [ROW_W-1:0]          wr_row_data;
    reg                       rd_en, rd_buf;
    wire signed [DATA_W-1:0]  weight_data [0:ROWS*COLS-1];
    wire                      rd_valid;

    bram_weight_buffer #(.DATA_W(DATA_W), .ROWS(ROWS), .COLS(COLS)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_buf(wr_buf), .wr_row(wr_row), .wr_row_data(wr_row_data),
        .rd_en(rd_en), .rd_buf(rd_buf), .weight_data(weight_data), .rd_valid(rd_valid));

    integer pass_cnt = 0, fail_cnt = 0, r, c;
    task tick; @(posedge clk); #1; endtask

    task check(input [255:0] tag, input integer got, exp);
        begin if (got===exp) pass_cnt=pass_cnt+1;
              else begin $display("  FAIL %s got=%0d exp=%0d",tag,got,exp); fail_cnt=fail_cnt+1; end end
    endtask

    // pack a row: W[r][c] = base + r*COLS + c
    task wr_row_t(input bf, input [$clog2(ROWS)-1:0] rr, input integer base);
        integer cc; reg [ROW_W-1:0] word;
        begin
            word = 0;
            for (cc=0; cc<COLS; cc=cc+1) word[cc*DATA_W +: DATA_W] = (base + rr*COLS + cc);
            @(negedge clk); wr_en=1; wr_buf=bf; wr_row=rr; wr_row_data=word; @(posedge clk); #1; wr_en=0;
        end
    endtask

    initial begin
        $dumpfile("tb_bram_weight_buffer.vcd"); $dumpvars(0, tb_bram_weight_buffer);
        wr_en=0; wr_buf=0; wr_row=0; wr_row_data=0; rd_en=0; rd_buf=0;
        rst_n=0; tick; tick; rst_n=1; tick;

        // slot0: base 0 ; slot1: base 100
        for (r=0; r<ROWS; r=r+1) wr_row_t(1'b0, r[$clog2(ROWS)-1:0], 0);
        for (r=0; r<ROWS; r=r+1) wr_row_t(1'b1, r[$clog2(ROWS)-1:0], 100);

        // read slot0 tile
        @(negedge clk); rd_en=1; rd_buf=1'b0; @(posedge clk); #1; rd_en=0;
        check("slot0 rd_valid", rd_valid, 1);
        for (r=0;r<ROWS;r=r+1) for (c=0;c<COLS;c=c+1)
            check("slot0 W", weight_data[r*COLS+c], r*COLS+c);

        // read slot1 tile
        @(negedge clk); rd_en=1; rd_buf=1'b1; @(posedge clk); #1; rd_en=0;
        for (r=0;r<ROWS;r=r+1) for (c=0;c<COLS;c=c+1)
            check("slot1 W", weight_data[r*COLS+c], 100 + r*COLS+c);

        $display("\n==================================");
        $display("  BRAM_WGT TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL BRAM_WGT TESTS PASSED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*20000); $display("BRAM_WGT WATCHDOG"); $finish; end
endmodule
