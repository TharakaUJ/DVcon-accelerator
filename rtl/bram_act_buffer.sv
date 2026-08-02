`timescale 1ns/1ps

module bram_act_buffer #(
    parameter integer DATA_W    = 8,
    parameter integer ACT_BANKS = 16,                 
    parameter integer ACT_DEPTH = 512,
    parameter integer DMA_WIDTH = 64,
    parameter integer ELEMENTS_PER_DMA = DMA_WIDTH / DATA_W,
    parameter integer WR_ADDR_W = $clog2((ACT_BANKS * ACT_DEPTH) / ELEMENTS_PER_DMA),
    parameter integer RD_ADDR_W = $clog2(ACT_DEPTH)
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // Write port
    input  logic                       wr_en,
    input  logic                       wr_buf,         
    input  logic [$clog2(ACT_BANKS)-1:0] wr_bank,
    input  logic [WR_ADDR_W-1:0]       wr_addr,
    input  logic signed [DMA_WIDTH-1:0] wr_data,

    // Read port
    input  logic                       rd_en,
    input  logic                       rd_buf,         
    input  logic [RD_ADDR_W-1:0]       rd_addr,
    output logic signed [DATA_W-1:0]   rd_data [0:ACT_BANKS-1],
    output logic                       rd_valid
);

    initial begin
        if (DMA_WIDTH % DATA_W != 0)
            $error("bram_act_buffer: DMA_WIDTH (%0d) must be a multiple of DATA_W (%0d)", DMA_WIDTH, DATA_W);
    end

    (* ram_style = "block" *) logic signed [DATA_W-1:0] mem0 [0:ACT_BANKS-1][0:ACT_DEPTH-1];
    (* ram_style = "block" *) logic signed [DATA_W-1:0] mem1 [0:ACT_BANKS-1][0:ACT_DEPTH-1];

    // Write Logic
    always_ff @(posedge clk) begin
        if (wr_en) begin
            int linear_idx;
            int b_idx;
            int d_idx;
            for (int i = 0; i < ELEMENTS_PER_DMA; i++) begin
                linear_idx = (wr_addr * ELEMENTS_PER_DMA) + i;
                b_idx = linear_idx % ACT_BANKS;
                d_idx = linear_idx / ACT_BANKS;
                
                if (wr_buf == 1'b0) 
                    mem0[b_idx][d_idx] <= wr_data[DATA_W*i +: DATA_W];
                else                
                    mem1[b_idx][d_idx] <= wr_data[DATA_W*i +: DATA_W];
            end
        end
    end
        
    genvar b;
    generate
        for (b = 0; b < ACT_BANKS; b++) begin : g_read_banks
            always_ff @(posedge clk) begin
                if (rd_en)
                    rd_data[b] <= (rd_buf == 1'b0) ? mem0[b][rd_addr] : mem1[b][rd_addr];
                else
                    rd_data[b] <= '0; // Clear bus
            end
        end
    endgenerate

    // Read valid pipeline
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_valid <= 1'b0;
        else        rd_valid <= rd_en;
    end

endmodule