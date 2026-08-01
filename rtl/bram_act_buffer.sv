`timescale 1ns/1ps

module bram_act_buffer #(
    parameter integer DATA_W    = 8,
    parameter integer ACT_BANKS = 16,                 
    parameter integer ACT_DEPTH = 512,                
    parameter integer DMA_WIDTH = 64,
    parameter integer ELEMENTS_PER_DMA = DMA_WIDTH / DATA_W,
    parameter integer WR_ADDR_W = $clog2(ACT_DEPTH / ELEMENTS_PER_DMA), // chunk address (write side)
    parameter integer RD_ADDR_W = $clog2(ACT_DEPTH/ACT_BANKS)                     // element address (read side)
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // ── Write port (stream / im2col) ─────────────────────────────────────────
    input  wire                       wr_en,
    input  wire                       wr_buf,         
    input  wire [$clog2(ACT_BANKS)-1:0] wr_bank,
    input  wire [WR_ADDR_W-1:0]       wr_addr,        // Base address for the DMA chunk
    input  wire signed [DMA_WIDTH-1:0]   wr_data,

    // ── Read port (to skew network) ──────────────────────────────────────────
    input  wire                       rd_en,
    input  wire                       rd_buf,         
    input  wire [RD_ADDR_W-1:0]       rd_addr,        // element address, not chunk address
    output reg  signed [DATA_W-1:0]   rd_data [0:ACT_BANKS-1],
    output reg                        rd_valid
);

    // Guard against a DMA_WIDTH that doesn't split evenly into DATA_W-wide elements
    initial begin
        if (DMA_WIDTH % DATA_W != 0)
            $error("bram_act_buffer: DMA_WIDTH (%0d) must be a multiple of DATA_W (%0d)", DMA_WIDTH, DATA_W);
    end

    genvar b;
    generate
        for (b = 0; b < ACT_BANKS; b = b + 1) begin : g_bank
            (* ram_style = "block" *) reg signed [DATA_W-1:0] mem0 [0:ACT_DEPTH-1];
            (* ram_style = "block" *) reg signed [DATA_W-1:0] mem1 [0:ACT_DEPTH-1];

            wire bank_wr = wr_en && (wr_bank == b);

            // Write port (synchronous)
            always @(posedge clk) begin
                if (bank_wr) begin: bank_write_block
                    integer i;
                    // Loop bound must be the number of segments, NOT the width of the segment
                    for (i = 0; i < ELEMENTS_PER_DMA; i = i + 1) begin
                        if (wr_buf == 1'b0) 
                            mem0[wr_addr * ELEMENTS_PER_DMA + i] <= wr_data[DATA_W*i +: DATA_W];
                        else                
                            mem1[wr_addr * ELEMENTS_PER_DMA + i] <= wr_data[DATA_W*i +: DATA_W];
                    end
                end
            end

            // Read port (synchronous, 1-cycle latency)
            // rd_addr is a full element address into mem0/mem1 (0 .. ACT_DEPTH-1),
            // matching the element-granular addressing used by the write side internally.
            always @(posedge clk) begin
                if (rd_en)
                    rd_data[b] <= (rd_buf == 1'b0) ? mem0[rd_addr] : mem1[rd_addr];
                else
                    rd_data[b] <= {DATA_W{1'b0}}; // Safe practice: clear bus when not reading
            end
        end
    endgenerate

    // Read-valid follows rd_en by one cycle
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_valid <= 1'b0;
        else        rd_valid <= rd_en;
    end

endmodule