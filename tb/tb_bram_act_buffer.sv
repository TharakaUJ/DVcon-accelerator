// =============================================================================
// tb_bram_act_buffer.sv  —  CR-1: banked ping-pong activation BRAM (DMA-chunk write)
//   Run: iverilog -g2012 -o tb ../rtl/bram_act_buffer.sv tb_bram_act_buffer.sv && vvp tb
//
//  Matches CURRENT DUT interface:
//    - wr_data is a DMA_WIDTH-wide chunk = ELEMENTS_PER_DMA elements packed together
//    - wr_addr is a CHUNK address (WR_ADDR_W = clog2(ACT_DEPTH/ELEMENTS_PER_DMA))
//    - rd_addr is an ELEMENT address but only RD_ADDR_W = clog2(ACT_DEPTH/ACT_BANKS)
//      bits wide, so only the first (ACT_DEPTH/ACT_BANKS) elements of each bank's
//      memory are reachable from the read port. That is a DUT limitation, not a
//      TB bug — see NOTE below. This TB writes the full depth but only checks the
//      read-reachable window.
//
//  Checks: chunk write -> per-element readback, 1-cycle read latency, full
//  vector read in one cycle, ping-pong half isolation (buf0 vs buf1).
// =============================================================================

`timescale 1ns/1ps

module tb_bram_act_buffer;
    localparam integer DATA_W    = 8;
    localparam integer ACT_BANKS = 4;
    localparam integer ACT_DEPTH = 16;
    localparam integer DMA_WIDTH = 32;
    localparam integer ELEMENTS_PER_DMA = DMA_WIDTH / DATA_W;              // 4
    localparam integer WR_ADDR_W = $clog2(ACT_DEPTH / ELEMENTS_PER_DMA);   // clog2(4) = 2
    localparam integer RD_ADDR_W = $clog2(ACT_DEPTH / ACT_BANKS);          // clog2(4) = 2
    localparam integer NUM_CHUNKS      = ACT_DEPTH / ELEMENTS_PER_DMA;     // 4
    localparam integer RD_REACHABLE    = (1 << RD_ADDR_W);                 // 4 elements/bank reachable
    localparam         CLK_PERIOD= 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                          wr_en, wr_buf;
    reg  [$clog2(ACT_BANKS)-1:0] wr_bank;
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
        .wr_en(wr_en), .wr_buf(wr_buf), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_buf(rd_buf), .rd_addr(rd_addr), .rd_data(rd_data), .rd_valid(rd_valid));

    integer pass_cnt = 0, fail_cnt = 0;
    integer bk, ch, el, ea;

    // Reference model: mem_ref[buf][bank][element_addr]
    reg signed [DATA_W-1:0] mem_ref [0:1][0:ACT_BANKS-1][0:ACT_DEPTH-1];

    task tick; @(posedge clk); #1; endtask

    // Write one DMA chunk (ELEMENTS_PER_DMA elements) to (buf,bank,chunk)
    task wr_chunk(input bf, input [$clog2(ACT_BANKS)-1:0] bk_i, input [WR_ADDR_W-1:0] chunk_i);
        reg signed [DMA_WIDTH-1:0] packed_data;
        integer i;
        integer base_elem;
        integer val;
        begin
            base_elem = chunk_i * ELEMENTS_PER_DMA;
            packed_data = {DMA_WIDTH{1'b0}};
            for (i = 0; i < ELEMENTS_PER_DMA; i = i + 1) begin
                // unique, sign-friendly pattern per (buf,bank,element)
                val = (base_elem + i) * 4 + bk_i;
                if (bf) val = -val;
                packed_data[DATA_W*i +: DATA_W] = val[DATA_W-1:0];
                mem_ref[bf][bk_i][base_elem + i] = val[DATA_W-1:0];
            end
            @(negedge clk);
            wr_en = 1; wr_buf = bf; wr_bank = bk_i; wr_addr = chunk_i; wr_data = packed_data;
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
        wr_en=0; wr_buf=0; wr_bank=0; wr_addr=0; wr_data=0; rd_en=0; rd_buf=0; rd_addr=0;
        rst_n=0; tick; tick; rst_n=1; tick;

        // ---- Write full depth of every bank, both buffers, via DMA chunks ----
        for (bk = 0; bk < ACT_BANKS; bk = bk + 1)
          for (ch = 0; ch < NUM_CHUNKS; ch = ch + 1) begin
            wr_chunk(1'b0, bk[$clog2(ACT_BANKS)-1:0], ch[WR_ADDR_W-1:0]);
            wr_chunk(1'b1, bk[$clog2(ACT_BANKS)-1:0], ch[WR_ADDR_W-1:0]);
          end

        // ---- NOTE ----
        // rd_addr is only RD_ADDR_W bits wide, so element addresses
        // [0 .. RD_REACHABLE-1] are all that can be read back per bank,
        // even though ACT_DEPTH elements were written per bank. Elements
        // at chunk>=1*ELEMENTS_PER_DMA (i.e. addr >= RD_REACHABLE) are
        // unreachable through this read port with current parameters.
        // This TB verifies correctness only within the reachable window
        // and flags the gap rather than silently ignoring it.
        if (RD_REACHABLE < ACT_DEPTH)
            $display("  NOTE: read port only reaches %0d of %0d elements/bank (RD_ADDR_W=%0d) - DUT limitation, not a TB gap",
                      RD_REACHABLE, ACT_DEPTH, RD_ADDR_W);

        // ---- Read buf0: reachable window, full vector each cycle, 1-cycle latency ----
        for (ea = 0; ea < RD_REACHABLE; ea = ea + 1) begin
            @(negedge clk); rd_en=1; rd_buf=1'b0; rd_addr=ea[RD_ADDR_W-1:0];
            @(posedge clk); #1;            // rd_data registered on this edge
            rd_en=0;
            check("buf0.rd_valid", rd_valid, 1);
            for (bk = 0; bk < ACT_BANKS; bk = bk + 1)
                check("buf0 vec", rd_data[bk], mem_ref[0][bk][ea]);
        end

        // ---- Ping-pong isolation: same addresses from buf1 give buf1's data ----
        for (ea = 0; ea < RD_REACHABLE; ea = ea + 1) begin
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