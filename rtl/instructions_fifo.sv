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
        rom[0]  = 24'h000000; 
        rom[1]  = 24'h200020; 
        rom[2]  = 24'h112020;
        rom[3]  = 24'h700003;
        rom[4]  = 24'h000004;
        rom[5]  = 24'h000005;
        rom[6]  = 24'h000006;
        rom[7]  = 24'h000007;
        rom[8]  = 24'h000000;
        rom[9]  = 24'h000000;
        rom[10] = 24'h000000;
        rom[11] = 24'h000000;
        rom[12] = 24'h000000;
        rom[13] = 24'h000000;
        rom[14] = 24'h000000;
        rom[15] = 24'h000000;
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