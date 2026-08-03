`timescale 1ns/1ps

module instruction_fifo_window #(
    parameter integer INSTR_WIDTH = 24,
    parameter integer INSTR_DEPTH = 16,
    parameter integer WINDOW_SIZE = 4
)(
    input  wire                               clk,
    input  wire                               rst_n,
    
    input  wire                               pop_en, 
    input  wire [$clog2(WINDOW_SIZE)-1:0]     pop_idx,
    output logic [INSTR_WIDTH-1:0]            window [0:WINDOW_SIZE-1]
);

    logic [INSTR_WIDTH-1:0] rom [0:INSTR_DEPTH-1];
    
    logic [$clog2(INSTR_DEPTH)-1:0] fetch_ptr;

    initial begin
        rom[0]  = 16'h0000; 
        rom[1]  = 16'h0001; 
        rom[2]  = 16'h0002;
        rom[3]  = 16'h0003;
        rom[4]  = 16'h0004;
        rom[5]  = 16'h0005;
        rom[6]  = 16'h0006;
        rom[7]  = 16'h0007;
        rom[8]  = 16'h0008;
        rom[9]  = 16'h0009;
        rom[10] = 16'h000A;
        rom[11] = 16'h000B;
        rom[12] = 16'h000C;
        rom[13] = 16'h000D;
        rom[14] = 16'h000E;
        rom[15] = 16'h000F;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < WINDOW_SIZE; i++) begin
                window[i] <= rom[i];
            end
            fetch_ptr <= WINDOW_SIZE; 
        end 
        else if (pop_en) begin
            for (int i = 0; i < WINDOW_SIZE; i++) begin
                if (i == WINDOW_SIZE - 1) begin
                    window[i] <= rom[fetch_ptr];
                end 
                else if (i >= pop_idx) begin
                    window[i] <= window[i+1]; // old window[i+1] value
                end
            end
            
            fetch_ptr <= (fetch_ptr + 1) % INSTR_DEPTH;
        end
    end

endmodule