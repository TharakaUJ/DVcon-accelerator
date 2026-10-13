`timescale 1ns/1ps

module instruction_fifo_window #(
    parameter integer INSTR_WIDTH = 32,   // was 24; widened to fit the accum_ctrl field (see control_unit.sv)
    parameter integer INSTR_DEPTH = 1024,   // was 16; programs are CPU-written now
    parameter integer WINDOW_SIZE = 4
)(
    input  wire                               clk,
    input  wire                               rst_n,

    input  wire                               pop_en,
    input  wire [$clog2(WINDOW_SIZE)-1:0]     pop_idx,
    output logic [INSTR_WIDTH-1:0]            window [0:WINDOW_SIZE-1],

    // NEW — FIX for "OP_END wraparound" (see control_unit.sv comment). Pulses
    // on start_pulse || soft_reset; rewinds fetch_ptr/window to instruction 0.
    input  wire                               restart,

    // NEW — CPU write port (see RTL_INSTRUCTION_MEMORY_PROPOSAL.md). Driven by
    // axi4_lite_slave's REG_INSTR_ADDR/REG_INSTR_DATA registers, already
    // gated with !busy upstream (accelerator.sv) so this port never toggles
    // while accel_state == ENG_BUSY. One write per pulse, one cycle, no
    // read-modify-write — plain single-port BRAM-style write.
    input  wire                               wr_en,
    input  wire [$clog2(INSTR_DEPTH)-1:0]     wr_addr,
    input  wire [INSTR_WIDTH-1:0]             wr_data,

    // Number of valid instructions (REG_PROG_LEN). Fetches at or past it
    // return OP_END, so a program never runs into unwritten/stale slots and
    // instruction memory needs no reset.
    input  wire [31:0]                        prog_len
);

    localparam logic [INSTR_WIDTH-1:0] END_WORD = 32'h8000_0000;   // OP_END, all other fields 0

    // Instruction memory. No reset (a reset loop over every slot would turn
    // it into INSTR_DEPTH*INSTR_WIDTH flip-flops); "unprogrammed" is handled
    // by prog_len instead: anything at or past prog_len reads as OP_END.
    // Written only while the accelerator is idle (wr_en is gated with !busy
    // in accelerator.sv). Reads are asynchronous, so on FPGA this maps to
    // distributed RAM rather than block RAM.
    logic [INSTR_WIDTH-1:0] rom [0:INSTR_DEPTH-1];

    // One wider than an address so it can sit at INSTR_DEPTH without wrapping.
    logic [$clog2(INSTR_DEPTH):0] fetch_ptr;

    function automatic logic [INSTR_WIDTH-1:0] fetch(input logic [$clog2(INSTR_DEPTH):0] idx);
        if (idx < INSTR_DEPTH && 32'(idx) < prog_len)
            return rom[idx[$clog2(INSTR_DEPTH)-1:0]];
        return END_WORD;
    endfunction

    always_ff @(posedge clk) begin
        if (wr_en)
            rom[wr_addr] <= wr_data;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < WINDOW_SIZE; i++)
                window[i] <= END_WORD;
            fetch_ptr <= '0;
        end
        else if (restart) begin
            for (int i = 0; i < WINDOW_SIZE; i++)
                window[i] <= fetch(i);
            fetch_ptr <= WINDOW_SIZE;
        end
        else if (pop_en) begin
            for (int i = 0; i < WINDOW_SIZE; i++) begin
                if (i == WINDOW_SIZE - 1) begin
                    window[i] <= fetch(fetch_ptr);
                end
                else if (i >= pop_idx) begin
                    window[i] <= window[i+1];
                end
            end
            // No wrap-around: past the end of memory (or prog_len) the
            // window just keeps filling with OP_END.
            if (fetch_ptr < INSTR_DEPTH)
                fetch_ptr <= fetch_ptr + 1'b1;
        end
    end

endmodule
