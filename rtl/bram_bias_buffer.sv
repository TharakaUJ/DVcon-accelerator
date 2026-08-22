`timescale 1ns/1ps

//==============================================================================
// bram_bias_buffer.sv  --  Per-output-channel bias storage (NEW).
//
// Flat, single-bank store of LANES signed ACC_W-bit bias values, feeding
// vector_unit.bias directly. Unlike act/weight/out buffers, bias is treated
// as a *persistent* resource in the control-unit scoreboard: it is loaded
// once (OP_LOAD_BIAS) and stays valid/reusable across many output-tile
// OP_VECTOR passes until explicitly reloaded — it is not consumed per-tile.
//
// Write port: chunked DMA-beat writes, same convention as bram_weight_buffer
// (ELEMENTS_PER_DMA = DMA_WIDTH / ACC_W elements land per beat).
// Read port: whole bias vector latched in one cycle, 1-cycle latency.
//==============================================================================

module bram_bias_buffer #(
    parameter integer ACC_W    = 32,
    parameter integer LANES    = 32,
    parameter integer DMA_WIDTH = 64,
    parameter integer ELEMENTS_PER_DMA = DMA_WIDTH / ACC_W,
    parameter integer WR_ADDR_W = $clog2(LANES / ELEMENTS_PER_DMA)
)(
    input  wire                            clk,
    input  wire                            rst_n,

    // ── Write port: one DMA chunk (ELEMENTS_PER_DMA elements) per beat ───────
    input  wire                            wr_en,
    input  wire [WR_ADDR_W-1:0]            wr_addr,   // chunk offset
    input  wire [DMA_WIDTH-1:0]            wr_data,

    // ── Read port: latch whole bias vector onto the flat bus ─────────────────
    input  wire                            rd_en,
    output reg  signed [ACC_W-1:0]         bias_data [0:LANES-1],
    output reg                             rd_valid
);

    (* ram_style = "distributed" *) logic signed [ACC_W-1:0] mem [0:LANES-1];

    initial begin
        if (DMA_WIDTH % ACC_W != 0)
            $error("bram_bias_buffer: DMA_WIDTH (%0d) must be a multiple of ACC_W (%0d)", DMA_WIDTH, ACC_W);
        if (LANES % ELEMENTS_PER_DMA != 0)
            $error("bram_bias_buffer: LANES (%0d) must be a multiple of ELEMENTS_PER_DMA (%0d)", LANES, ELEMENTS_PER_DMA);
    end

    integer i;
    always_ff @(posedge clk) begin
        if (wr_en) begin
            for (i = 0; i < ELEMENTS_PER_DMA; i = i + 1) begin
                mem[wr_addr * ELEMENTS_PER_DMA + i] <= wr_data[ACC_W*i +: ACC_W];
            end
        end
    end

    integer k;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
            for (k = 0; k < LANES; k = k + 1) bias_data[k] <= '0;
        end
        else begin
            rd_valid <= rd_en;
            if (rd_en) begin
                for (k = 0; k < LANES; k = k + 1) bias_data[k] <= mem[k];
            end
        end
    end

endmodule
