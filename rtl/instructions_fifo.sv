`timescale 1ns/1ps

module instruction_fifo_window #(
    parameter integer INSTR_WIDTH = 32,   // was 24; widened to fit the new accum_ctrl field (see control_unit.sv)
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

    // NEW 32-bit encoding (was 24-bit — see control_unit.sv for the widened
    // instruction_t/opcode_t/accum_ctrl_t definitions this must match).
    // Byte layout: [opcode(4)|src(2)|dst(2)] [addr(8)] [length(8)] [accum_ctrl(2)|reserved(6)]
    //
    // opcode encoding: NOP=0 LOAD_WGT=1 LOAD_ACT=2 LOAD_BIAS=3 MATMUL=4
    //                  VECTOR=5 STORE=6 SWAP_WGT=7 END=8
    // accum_ctrl encoding: NONE=0 INIT=1 ADD=2 LAST=3
    //
    // Sample single-pass program (no cross-tile reduction, accum_ctrl=NONE):
    //   0: NOP
    //   1: LOAD_WGT  dst=0 addr=0 len=4
    //   2: LOAD_ACT  dst=0 addr=0 len=4
    //   3: LOAD_BIAS      addr=0 len=1
    //   4: SWAP_WGT
    //   5: MATMUL    src=0       addr=0          accum_ctrl=NONE
    //   6: VECTOR          dst=0 addr=0
    //   7: STORE     src=0       addr=0 len=5
    //   8: END
    initial begin
        rom[0]  = 32'h00000000;  // NOP
        rom[1]  = 32'h10000400;  // LOAD_WGT  dst=0 addr=0x00 len=4
        rom[2]  = 32'h20000400;  // LOAD_ACT  dst=0 addr=0x00 len=4
        rom[3]  = 32'h30000100;  // LOAD_BIAS       addr=0x00 len=1
        rom[4]  = 32'h70000000;  // SWAP_WGT
        rom[5]  = 32'h40000000;  // MATMUL    src=0 addr=0x00        accum_ctrl=NONE
        rom[6]  = 32'h50000000;  // VECTOR          dst=0 addr=0x00
        rom[7]  = 32'h60000500;  // STORE     src=0 addr=0x00 len=5
        rom[8]  = 32'h80000000;  // END
        rom[9]  = 32'h00000000;
        rom[10] = 32'h00000000;
        rom[11] = 32'h00000000;
        rom[12] = 32'h00000000;
        rom[13] = 32'h00000000;
        rom[14] = 32'h00000000;
        rom[15] = 32'h00000000;
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