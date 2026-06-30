// =============================================================================
// tb_bram_out_buffer.sv  —  CR-5: double-buffered INT8 output BRAM
//   Run: iverilog -g2012 -o tb ../rtl/bram_out_buffer.sv tb_bram_out_buffer.sv && vvp tb
//
//  Checks: vector write/read (1-cycle latency) and ping-pong half isolation.
// =============================================================================

`timescale 1ns/1ps

module tb_bram_out_buffer;
    localparam integer DATA_W    = 8;
    localparam integer OC_LANES  = 4;
    localparam integer OUT_DEPTH = 8;
    localparam integer ADDR_W    = $clog2(OUT_DEPTH);
    localparam         CLK_PERIOD= 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                       wr_en, wr_buf;
    reg  [ADDR_W-1:0]         wr_addr;
    reg  signed [DATA_W-1:0]  wr_vec [0:OC_LANES-1];
    reg                       rd_en, rd_buf;
    reg  [ADDR_W-1:0]         rd_addr;
    wire signed [DATA_W-1:0]  rd_vec [0:OC_LANES-1];
    wire                      rd_valid;

    bram_out_buffer #(.DATA_W(DATA_W), .OC_LANES(OC_LANES), .OUT_DEPTH(OUT_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_buf(wr_buf), .wr_addr(wr_addr), .wr_vec(wr_vec),
        .rd_en(rd_en), .rd_buf(rd_buf), .rd_addr(rd_addr), .rd_vec(rd_vec), .rd_valid(rd_valid));

    integer pass_cnt = 0, fail_cnt = 0, a, l;
    task tick; @(posedge clk); #1; endtask
    task check(input [255:0] tag, input integer got, exp);
        begin if (got===exp) pass_cnt=pass_cnt+1;
              else begin $display("  FAIL %s got=%0d exp=%0d",tag,got,exp); fail_cnt=fail_cnt+1; end end
    endtask

    task wr(input bf, input [ADDR_W-1:0] ad, input integer base);
        integer ll;
        begin
            for (ll=0; ll<OC_LANES; ll=ll+1) wr_vec[ll] = base + ll;
            @(negedge clk); wr_en=1; wr_buf=bf; wr_addr=ad; @(posedge clk); #1; wr_en=0;
        end
    endtask

    initial begin
        $dumpfile("tb_bram_out_buffer.vcd"); $dumpvars(0, tb_bram_out_buffer);
        wr_en=0; wr_buf=0; wr_addr=0; rd_en=0; rd_buf=0; rd_addr=0;
        for (l=0;l<OC_LANES;l=l+1) wr_vec[l]=0;
        rst_n=0; tick; tick; rst_n=1; tick;

        // buf0 holds +(a*10+l) (0..73), buf1 holds -(a*10+l); both fit signed-8.
        for (a=0;a<OUT_DEPTH;a=a+1) begin
            wr(1'b0, a[ADDR_W-1:0],  (a*10));
            wr(1'b1, a[ADDR_W-1:0], -(a*10));
        end

        for (a=0;a<OUT_DEPTH;a=a+1) begin
            @(negedge clk); rd_en=1; rd_buf=1'b0; rd_addr=a[ADDR_W-1:0]; @(posedge clk); #1; rd_en=0;
            check("buf0 rd_valid", rd_valid, 1);
            for (l=0;l<OC_LANES;l=l+1) check("buf0 vec", rd_vec[l], a*10+l);
        end
        for (a=0;a<OUT_DEPTH;a=a+1) begin
            @(negedge clk); rd_en=1; rd_buf=1'b1; rd_addr=a[ADDR_W-1:0]; @(posedge clk); #1; rd_en=0;
            for (l=0;l<OC_LANES;l=l+1) check("buf1 vec", rd_vec[l], -(a*10)+l);
        end

        $display("\n==================================");
        $display("  BRAM_OUT TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL BRAM_OUT TESTS PASSED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*20000); $display("BRAM_OUT WATCHDOG"); $finish; end
endmodule
