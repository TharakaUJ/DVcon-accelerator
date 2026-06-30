// =============================================================================
// tb_bram_act_buffer.sv  —  CR-1: banked ping-pong activation BRAM
//   Run: iverilog -g2012 -o tb ../rtl/bram_act_buffer.sv tb_bram_act_buffer.sv && vvp tb
//
//  Checks: per-bank write/read, 1-cycle read latency, full vector read in one
//  cycle, and ping-pong half isolation (buf0 vs buf1).
// =============================================================================

`timescale 1ns/1ps

module tb_bram_act_buffer;
    localparam integer DATA_W    = 8;
    localparam integer ACT_BANKS = 4;
    localparam integer ACT_DEPTH = 8;
    localparam integer ADDR_W    = $clog2(ACT_DEPTH);
    localparam         CLK_PERIOD= 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                       wr_en, wr_buf;
    reg  [$clog2(ACT_BANKS)-1:0] wr_bank;
    reg  [ADDR_W-1:0]         wr_addr;
    reg  signed [DATA_W-1:0]  wr_data;
    reg                       rd_en, rd_buf;
    reg  [ADDR_W-1:0]         rd_addr;
    wire signed [DATA_W-1:0]  rd_data [0:ACT_BANKS-1];
    wire                      rd_valid;

    bram_act_buffer #(.DATA_W(DATA_W), .ACT_BANKS(ACT_BANKS), .ACT_DEPTH(ACT_DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_buf(wr_buf), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_buf(rd_buf), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid));

    integer pass_cnt = 0, fail_cnt = 0, a, b;
    task tick; @(posedge clk); #1; endtask

    task wr(input bf, input [$clog2(ACT_BANKS)-1:0] bk, input [ADDR_W-1:0] ad, input signed [DATA_W-1:0] d);
        begin @(negedge clk); wr_en=1; wr_buf=bf; wr_bank=bk; wr_addr=ad; wr_data=d; @(posedge clk); #1; wr_en=0; end
    endtask

    task check(input [255:0] tag, input integer got, exp);
        begin if (got===exp) pass_cnt=pass_cnt+1;
              else begin $display("  FAIL %s got=%0d exp=%0d",tag,got,exp); fail_cnt=fail_cnt+1; end end
    endtask

    initial begin
        $dumpfile("tb_bram_act_buffer.vcd"); $dumpvars(0, tb_bram_act_buffer);
        wr_en=0; wr_buf=0; wr_bank=0; wr_addr=0; wr_data=0; rd_en=0; rd_buf=0; rd_addr=0;
        rst_n=0; tick; tick; rst_n=1; tick;

        // Fill buf0 with v=addr*4+bank ; buf1 with v=-(addr*4+bank)
        for (a=0; a<ACT_DEPTH; a=a+1)
          for (b=0; b<ACT_BANKS; b=b+1) begin
            wr(1'b0, b[$clog2(ACT_BANKS)-1:0], a[ADDR_W-1:0],  a*4+b);
            wr(1'b1, b[$clog2(ACT_BANKS)-1:0], a[ADDR_W-1:0], -(a*4+b));
          end

        // Read each address from buf0, full vector, 1-cycle latency
        for (a=0; a<ACT_DEPTH; a=a+1) begin
            @(negedge clk); rd_en=1; rd_buf=1'b0; rd_addr=a[ADDR_W-1:0];
            @(posedge clk); #1;            // rd_data registered on this edge
            rd_en=0;
            check("buf0.rd_valid", rd_valid, 1);
            for (b=0; b<ACT_BANKS; b=b+1) check("buf0 vec", rd_data[b], a*4+b);
        end

        // Ping-pong isolation: same addresses from buf1 give negated values
        for (a=0; a<ACT_DEPTH; a=a+1) begin
            @(negedge clk); rd_en=1; rd_buf=1'b1; rd_addr=a[ADDR_W-1:0];
            @(posedge clk); #1; rd_en=0;
            for (b=0; b<ACT_BANKS; b=b+1) check("buf1 vec", rd_data[b], -(a*4+b));
        end

        $display("\n==================================");
        $display("  BRAM_ACT TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL BRAM_ACT TESTS PASSED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*20000); $display("BRAM_ACT WATCHDOG"); $finish; end
endmodule
