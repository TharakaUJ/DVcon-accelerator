// =============================================================================
// tb_bram_act_buffer.sv  —  CR-1: ping-pong activation BRAM (DMA-chunk write,
//                            interleaved-across-banks addressing, no wr_bank)
//   Run: iverilog -g2012 -o tb ../rtl/bram_act_buffer.sv tb_bram_act_buffer.sv && vvp tb
//
//  Matches CURRENT DUT interface:
//    - wr_data is a DMA_WIDTH-wide chunk = ELEMENTS_PER_DMA elements packed together
//    - wr_addr is a GLOBAL chunk address over the whole (ACT_BANKS*ACT_DEPTH)
//      element space; there is no separate bank-select input. Each chunk's
//      elements are written round-robin across banks:
//          linear_idx = wr_addr*ELEMENTS_PER_DMA + i
//          bank       = linear_idx % ACT_BANKS
//          depth      = linear_idx / ACT_BANKS
//      WR_ADDR_W = clog2((ACT_BANKS*ACT_DEPTH)/ELEMENTS_PER_DMA)
//    - rd_addr is a per-bank DEPTH address, full width, no truncation:
//          RD_ADDR_W = clog2(ACT_DEPTH)
//      One read returns ACT_BANKS elements in parallel (one per bank), i.e.
//      ACT_BANKS consecutive elements of the flattened write order.
//
//  Checks: chunk write -> per-element readback (via interleave reconstruction),
//  1-cycle read latency, full vector read in one cycle, ping-pong half
//  isolation (buf0 vs buf1), rd_en de-assert clears the bus.
// =============================================================================

`timescale 1ns/1ps

module tb_bram_act_buffer;
    localparam integer DATA_W    = 8;
    localparam integer ACT_BANKS = 4;
    localparam integer ACT_DEPTH = 16;                                       // per-bank depth
    localparam integer DMA_WIDTH = 32;
    localparam integer ELEMENTS_PER_DMA = DMA_WIDTH / DATA_W;                // 4
    localparam integer TOTAL_ELEMS = ACT_BANKS * ACT_DEPTH;                  // 64
    localparam integer WR_ADDR_W = $clog2(TOTAL_ELEMS / ELEMENTS_PER_DMA);   // clog2(16) = 4
    localparam integer RD_ADDR_W = $clog2(ACT_DEPTH);                        // clog2(16) = 4
    localparam integer NUM_CHUNKS = TOTAL_ELEMS / ELEMENTS_PER_DMA;          // 16
    localparam         CLK_PERIOD= 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                          wr_en, wr_buf;
    reg  [WR_ADDR_W-1:0]         wr_addr;
    reg  signed [DMA_WIDTH-1:0]  wr_data;
    reg                          rd_en, rd_buf;
    reg  [RD_ADDR_W-1:0]         rd_addr;
    wire signed [DATA_W-1:0]     rd_data [0:ACT_BANKS-1];
    wire                         rd_valid;

    bram_act_buffer #(
        .DATA_W(DATA_W), .ACT_BANKS(ACT_BANKS), .ACT_DEPTH(ACT_DEPTH),
        .DMA_WIDTH(DMA_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_buf(wr_buf), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_buf(rd_buf), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid));

    integer pass_cnt = 0, fail_cnt = 0;
    integer bk, ch, ea;

    // Reference model: mem_ref[buf][bank][depth]
    reg signed [DATA_W-1:0] mem_ref [0:1][0:ACT_BANKS-1][0:ACT_DEPTH-1];

    task tick; @(posedge clk); #1; endtask

    // Write one DMA chunk (ELEMENTS_PER_DMA elements) at global chunk address chunk_i.
    // Elements interleave round-robin across banks per the DUT's addressing scheme.
    task wr_chunk(input bf, input [WR_ADDR_W-1:0] chunk_i);
        reg signed [DMA_WIDTH-1:0] packed_data;
        integer i;
        integer linear_idx;
        integer b_idx, d_idx;
        integer val;
        begin
            packed_data = {DMA_WIDTH{1'b0}};
            for (i = 0; i < ELEMENTS_PER_DMA; i = i + 1) begin
                linear_idx = chunk_i * ELEMENTS_PER_DMA + i;
                b_idx = linear_idx % ACT_BANKS;
                d_idx = linear_idx / ACT_BANKS;
                // unique, sign-friendly pattern per (buf,linear element)
                val = linear_idx * 3 + 1;
                if (bf) val = -val;
                packed_data[DATA_W*i +: DATA_W] = val[DATA_W-1:0];
                mem_ref[bf][b_idx][d_idx] = val[DATA_W-1:0];
            end
            @(negedge clk);
            wr_en = 1; wr_buf = bf; wr_addr = chunk_i; wr_data = packed_data;
            @(posedge clk); #1;
            wr_en = 0;
        end
    endtask

    task check(input [255:0] tag, input integer got, exp);
        begin if (got===exp) pass_cnt=pass_cnt+1;
              else begin $display("  FAIL %s got=%0d exp=%0d",tag,got,exp); fail_cnt=fail_cnt+1; end end
    endtask

    initial begin
        $dumpfile("tb_bram_act_buffer.vcd"); $dumpvars(0, tb_bram_act_buffer);
        wr_en=0; wr_buf=0; wr_addr=0; wr_data=0; rd_en=0; rd_buf=0; rd_addr=0;
        rst_n=0; tick; tick; rst_n=1; tick;

        // ---- Write the entire interleaved address space, both buffers ----
        for (ch = 0; ch < NUM_CHUNKS; ch = ch + 1) begin
            wr_chunk(1'b0, ch[WR_ADDR_W-1:0]);
            wr_chunk(1'b1, ch[WR_ADDR_W-1:0]);
        end

        // ---- Read buf0: full depth, full vector each cycle, 1-cycle latency ----
        for (ea = 0; ea < ACT_DEPTH; ea = ea + 1) begin
            @(negedge clk); rd_en=1; rd_buf=1'b0; rd_addr=ea[RD_ADDR_W-1:0];
            @(posedge clk); #1;            // rd_data registered on this edge
            rd_en=0;
            check("buf0.rd_valid", rd_valid, 1);
            for (bk = 0; bk < ACT_BANKS; bk = bk + 1)
                check("buf0 vec", rd_data[bk], mem_ref[0][bk][ea]);
        end

        // ---- Ping-pong isolation: same addresses from buf1 give buf1's data ----
        for (ea = 0; ea < ACT_DEPTH; ea = ea + 1) begin
            @(negedge clk); rd_en=1; rd_buf=1'b1; rd_addr=ea[RD_ADDR_W-1:0];
            @(posedge clk); #1; rd_en=0;
            for (bk = 0; bk < ACT_BANKS; bk = bk + 1)
                check("buf1 vec", rd_data[bk], mem_ref[1][bk][ea]);
        end

        // ---- rd_en de-assert clears the bus next cycle ----
        @(negedge clk); rd_en=1; rd_buf=1'b0; rd_addr=0;
        @(posedge clk); #1; rd_en=0;
        @(posedge clk); #1; // one more cycle with rd_en=0
        for (bk = 0; bk < ACT_BANKS; bk = bk + 1)
            check("rd_data clears when rd_en=0", rd_data[bk], 0);
        check("rd_valid follows rd_en low", rd_valid, 0);

        $display("\n==================================");
        $display("  BRAM_ACT TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt==0) $display("  ALL BRAM_ACT TESTS PASSED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*20000); $display("BRAM_ACT WATCHDOG"); $finish; end
endmodule