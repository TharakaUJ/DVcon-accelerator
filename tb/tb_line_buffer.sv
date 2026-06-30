// =============================================================================
// tb_line_buffer.sv  —  CR-3: K-row line buffer, vertical-slice read
//   Run: iverilog -g2012 -o tb ../rtl/line_buffer.sv tb_line_buffer.sv && vvp tb
//
//  Writes a known pattern into KH row banks, then checks that a read at column
//  x returns the full vertical KH-pixel slice in one cycle (1-cycle latency).
// =============================================================================

`timescale 1ns/1ps

module tb_line_buffer;
    localparam integer DATA_W    = 8;
    localparam integer IMG_W_MAX = 8;
    localparam integer KH        = 3;
    localparam integer XW        = $clog2(IMG_W_MAX);
    localparam         CLK_PERIOD= 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                       wr_en;
    reg  [$clog2(KH)-1:0]     wr_row;
    reg  [XW-1:0]             wr_x;
    reg  signed [DATA_W-1:0]  wr_data;
    reg                       rd_en;
    reg  [XW-1:0]             rd_x;
    wire signed [DATA_W-1:0]  col_pix [0:KH-1];
    wire                      rd_valid;

    line_buffer #(.DATA_W(DATA_W), .IMG_W_MAX(IMG_W_MAX), .KH(KH)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_row(wr_row), .wr_x(wr_x), .wr_data(wr_data),
        .rd_en(rd_en), .rd_x(rd_x), .col_pix(col_pix), .rd_valid(rd_valid));

    integer pass_cnt = 0, fail_cnt = 0, k, x;
    task tick; @(posedge clk); #1; endtask
    task check(input [255:0] tag, input integer got, exp);
        begin if (got===exp) pass_cnt=pass_cnt+1;
              else begin $display("  FAIL %s got=%0d exp=%0d",tag,got,exp); fail_cnt=fail_cnt+1; end end
    endtask

    task wr(input [$clog2(KH)-1:0] rr, input [XW-1:0] xx, input signed [DATA_W-1:0] d);
        begin @(negedge clk); wr_en=1; wr_row=rr; wr_x=xx; wr_data=d; @(posedge clk); #1; wr_en=0; end
    endtask

    initial begin
        $dumpfile("tb_line_buffer.vcd"); $dumpvars(0, tb_line_buffer);
        wr_en=0; wr_row=0; wr_x=0; wr_data=0; rd_en=0; rd_x=0;
        rst_n=0; tick; tick; rst_n=1; tick;

        // pattern: bank k, col x => k*10 + x
        for (k=0;k<KH;k=k+1) for (x=0;x<IMG_W_MAX;x=x+1)
            wr(k[$clog2(KH)-1:0], x[XW-1:0], k*10 + x);

        for (x=0;x<IMG_W_MAX;x=x+1) begin
            @(negedge clk); rd_en=1; rd_x=x[XW-1:0]; @(posedge clk); #1; rd_en=0;
            check("rd_valid", rd_valid, 1);
            for (k=0;k<KH;k=k+1) check("slice", col_pix[k], k*10 + x);
        end

        $display("\n==================================");
        $display("  LINE_BUF TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL LINE_BUF TESTS PASSED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*20000); $display("LINE_BUF WATCHDOG"); $finish; end
endmodule
