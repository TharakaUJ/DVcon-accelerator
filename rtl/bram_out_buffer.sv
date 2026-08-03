`timescale 1ns/1ps

module bram_out_buffer #(
    parameter integer DATA_W           = 8,
    parameter integer OC_LANES         = 16,
    parameter integer OUT_DEPTH        = 1024,   
    parameter integer ALL_ELEMENTS      = OC_LANES * OUT_DEPTH,              
    parameter integer DMA_WIDTH        = 64,
    parameter integer ELEMENTS_PER_DMA = DMA_WIDTH / DATA_W,
    parameter integer WR_ADDR_W        = $clog2(OUT_DEPTH),
    parameter integer RD_ADDR_W        = $clog2(ALL_ELEMENTS / ELEMENTS_PER_DMA)
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // ── Write a full output vector (from vector_unit) ────────────────────────
    input  logic                       wr_en,
    input  logic                       wr_buf,
    input  logic [WR_ADDR_W-1:0]       wr_addr,
    input  logic signed [DATA_W-1:0]   wr_vec [0:OC_LANES-1],

    // ── Read a full output vector (drain) ────────────────────────────────────
    input  logic                       rd_en,
    input  logic                       rd_buf,
    input  logic [RD_ADDR_W-1:0]       rd_addr,
    output logic signed [DMA_WIDTH-1:0] rd_vec,
    output logic                       rd_valid
);

    localparam int WR_WIDTH = OC_LANES * DATA_W;
    localparam int WR_DEPTH = OUT_DEPTH;
    localparam int RD_RATIO = OC_LANES / ELEMENTS_PER_DMA;

    initial begin
        if (OC_LANES % ELEMENTS_PER_DMA != 0)
            $error("bram_out_buffer: OC_LANES must be an integer multiple of ELEMENTS_PER_DMA");
    end

    (* ram_style = "block" *) logic [WR_WIDTH-1:0] mem0 [0:WR_DEPTH-1];
    (* ram_style = "block" *) logic [WR_WIDTH-1:0] mem1 [0:WR_DEPTH-1];

    // ── Write Logic ──────────────────────────────────────────────────────────
    logic [WR_WIDTH-1:0] packed_wr_vec;
    always_comb begin
        for (int i = 0; i < OC_LANES; i++) begin
            packed_wr_vec[i*DATA_W +: DATA_W] = wr_vec[i];
        end
    end

    always_ff @(posedge clk) begin
        if (wr_en) begin
            if (wr_buf == 1'b0) mem0[wr_addr] <= packed_wr_vec;
            else                mem1[wr_addr] <= packed_wr_vec;
        end
    end

    // ── Read Logic ───────────────────────────────────────────────────────────
    int unsigned rd_mem_addr;
    int unsigned rd_mem_offset;

    // Map the narrow rd_addr to the wide word address and slice offset
    assign rd_mem_addr   = rd_addr / RD_RATIO;
    assign rd_mem_offset = rd_addr % RD_RATIO;

    always_ff @(posedge clk) begin
        if (rd_en) begin
            // Synthesizers will correctly map this to BRAM output + local MUXing
            if (rd_buf == 1'b0) 
                rd_vec <= mem0[rd_mem_addr][rd_mem_offset * DMA_WIDTH +: DMA_WIDTH];
            else                
                rd_vec <= mem1[rd_mem_addr][rd_mem_offset * DMA_WIDTH +: DMA_WIDTH];
        end else begin
            rd_vec <= '0; // Clean bus
        end
    end

    // Read valid pipeline
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_valid <= 1'b0;
        else        rd_valid <= rd_en;
    end

endmodule