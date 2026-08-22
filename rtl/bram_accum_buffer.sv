`timescale 1ns/1ps

//==============================================================================
// bram_accum_buffer.sv  --  Tile-accumulation buffer (NEW).
//
// Sits between the systolic array's raw per-tile output (array_result_out,
// signed 32b/lane, one tile drained row-by-row) and the vector_unit's `acc`
// input. Holds a full output tile (ARRAY_SIZE rows x LANES x ACC_W) at full
// accumulator precision so that multiple OP_MATMUL passes (e.g. a reduction
// over input-channel sub-tiles wider than the systolic array) can be summed
// before bias/requant/activation is applied.
//
// Write modes (driven by control_unit, one row per write pulse):
//   wr_init = 1 : overwrite mem[wr_addr]      (first tile of a reduction group,
//                                               or a single-pass matmul)
//   wr_init = 0 : mem[wr_addr] += wr_data      (accumulate into existing partial sum)
//
// Read: registered, 1-cycle latency, same convention as bram_weight_buffer.
//
// NOTE (implementation detail, not a functional gap): because accumulate
// writes need same-cycle read-modify-write of mem[wr_addr], this is coded as
// a flip-flop/LUTRAM array rather than a single-port block-RAM inference
// pragma. For ARRAY_SIZE=32 this is 32*32*32b = 32Kbit, which is acceptable
// on most FPGAs; revisit with a true 2-stage read-add-write BRAM pipeline if
// area becomes a concern for larger ARRAY_SIZE.
//==============================================================================

module bram_accum_buffer #(
    parameter integer ACC_W = 32,          // matches vector_unit's ACC_W localparam
    parameter integer LANES = 32,          // matches SYSTOLIC_ARRAY_ROWS / OC_LANES
    parameter integer DEPTH = 32,          // output tile rows, matches SYSTOLIC_ARRAY_ROWS
    parameter integer ADDR_W = $clog2(DEPTH)
)(
    input  wire                            clk,
    input  wire                            rst_n,

    // ── Write port: one output-tile row per pulse ────────────────────────────
    input  wire                            wr_en,
    input  wire                            wr_init,   // 1=overwrite, 0=accumulate
    input  wire [ADDR_W-1:0]               wr_addr,
    input  wire signed [ACC_W-1:0]         wr_data [0:LANES-1],

    // ── Read port: one output-tile row per pulse, 1-cycle latency ────────────
    input  wire                            rd_en,
    input  wire [ADDR_W-1:0]               rd_addr,
    output reg  signed [ACC_W-1:0]         rd_data [0:LANES-1],
    output reg                             rd_valid
);

    (* ram_style = "distributed" *) logic signed [ACC_W-1:0] mem [0:DEPTH-1][0:LANES-1];

    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : g_lane
            always_ff @(posedge clk) begin
                if (wr_en) begin
                    if (wr_init) mem[wr_addr][l] <= wr_data[l];
                    else         mem[wr_addr][l] <= mem[wr_addr][l] + wr_data[l];
                end
            end
        end
    endgenerate

    integer k;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid <= 1'b0;
            for (k = 0; k < LANES; k = k + 1) rd_data[k] <= '0;
        end
        else begin
            rd_valid <= rd_en;
            if (rd_en) begin
                for (k = 0; k < LANES; k = k + 1) rd_data[k] <= mem[rd_addr][k];
            end
        end
    end

endmodule
