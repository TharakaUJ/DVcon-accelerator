`timescale 1ns/1ps

module bram_weight_buffer #(
    parameter integer DATA_W = 8,
    parameter integer ROWS   = 16,
    parameter integer COLS   = 16,
    parameter integer DMA_WIDTH = 64,
    parameter integer ELEMENTS_PER_DMA = DMA_WIDTH / DATA_W,
    parameter integer WR_ADDR_W = $clog2(COLS*ROWS / ELEMENTS_PER_DMA)  // chunk address within a row
)(
    input  wire                          clk,
    input  wire                          rst_n,

    // ── Write port: one DMA chunk (ELEMENTS_PER_DMA elements) per beat ───────
    input  wire                          wr_en,
    input  wire [WR_ADDR_W-1:0]          wr_addr,   // chunk offset within the row
    input  wire [DMA_WIDTH-1:0]          wr_data,   // {W[row][chunk*EPD+EPD-1],...,W[row][chunk*EPD]}

    // ── Read port: latch whole tile into the flat bus ────────────────────────
    input  wire                          rd_en,
    output reg  signed [DATA_W-1:0]      weight_data [0:ROWS*COLS-1],
    output reg                           rd_valid
);

    logic [$clog2(ROWS)-1:0]       wr_row;
    logic [$clog2(COLS*DATA_W/ELEMENTS_PER_DMA)-1:0]       wr_col;

    assign wr_row = wr_addr / (COLS * DATA_W / ELEMENTS_PER_DMA);
    assign wr_col = wr_addr % (COLS * DATA_W / ELEMENTS_PER_DMA);
    // Guard against a DMA_WIDTH that doesn't split evenly into DATA_W-wide elements
    initial begin
        if (DMA_WIDTH % DATA_W != 0)
            $error("bram_weight_buffer: DMA_WIDTH (%0d) must be a multiple of DATA_W (%0d)", DMA_WIDTH, DATA_W);
        if (COLS % ELEMENTS_PER_DMA != 0)
            $error("bram_weight_buffer: COLS (%0d) must be a multiple of ELEMENTS_PER_DMA (%0d)", COLS, ELEMENTS_PER_DMA);
    end

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_rowbank
            // One BRAM per row, COLS deep, DATA_W wide (single buffer).
            (* ram_style = "block" *) reg signed [DATA_W-1:0] mem [0:COLS-1];

            wire row_wr = wr_en && (wr_row == r);
            always @(posedge clk) begin
                if (row_wr) begin: row_write_block
                    integer i;
                    // Loop bound must be the number of segments, NOT the width of the segment
                    for (i = 0; i < ELEMENTS_PER_DMA; i = i + 1) begin
                        mem[wr_col * ELEMENTS_PER_DMA + i] <= wr_data[DATA_W*i +: DATA_W];
                    end
                end
            end

            // Synchronous read: unpack the entire row into the registered flat
            // weight bus in one cycle (1-cycle latency) whenever rd_en fires.
            for (c = 0; c < COLS; c = c + 1) begin : g_unpack
                always @(posedge clk) begin
                    if (rd_en)
                        weight_data[r*COLS + c] <= mem[c];
                end
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_valid <= 1'b0;
        else        rd_valid <= rd_en;
    end

endmodule