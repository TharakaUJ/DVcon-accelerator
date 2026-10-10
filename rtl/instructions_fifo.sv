`timescale 1ns/1ps

module instruction_fifo_window #(
    parameter integer INSTR_WIDTH = 32,   // was 24; widened to fit the accum_ctrl field (see control_unit.sv)
    parameter integer INSTR_DEPTH = 16,
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
    input  wire [INSTR_WIDTH-1:0]             wr_data
);

    logic [INSTR_WIDTH-1:0] rom [0:INSTR_DEPTH-1];

    logic [$clog2(INSTR_DEPTH)-1:0] fetch_ptr;

    //=========================================================================
    // CHANGE — power-on/reset default content.
    //
    // Previously this `initial` block loaded a fixed 11-instruction GEMM demo
    // program (rom[0..10]) with rom[11..15] pre-set to END as padding. Now
    // that `rom` is a CPU-writable instruction memory (see wr_en/wr_addr/
    // wr_data below and REG_INSTR_ADDR/REG_INSTR_DATA/REG_PROG_LEN in
    // axi4_lite_slave.sv), the *safety* default matters more than the demo
    // content: every slot must decode as OP_END (32'h8000_0000, opcode=8,
    // all other fields 0) at reset, not just the slots past some assumed
    // program length. If a CPU forgets to fully (re)write the program before
    // pulsing START — or writes a shorter program than a previous run left
    // behind — fetch must terminate immediately/harmlessly instead of
    // executing whatever instruction word happens to be sitting in an
    // unwritten or stale slot.
    //
    // So: `rom` is now synchronously reset to all-END in the same always_ff
    // block that already handles window/fetch_ptr reset below (single reset
    // domain, no separate initial block content is relied on for correctness
    // in simulation or on real silicon — `initial` alone is not synthesizable
    // reset behavior on an ASIC flow anyway, only on FPGA BRAM initial
    // values). The old GEMM demo program content is dropped entirely: it is
    // no longer needed as a "default program" now that the CPU is expected
    // to program instruction memory itself before every run, and keeping it
    // around as reset content would silently mask a CPU that forgot to write
    // REG_PROG_LEN / the instruction stream (it would appear to "work" by
    // running the stale demo instead of visibly doing nothing / hitting END
    // immediately).
    //=========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // NEW — reset every slot to OP_END (32'h8000_0000) rather than
            // relying on `initial` content. See comment block above.
            for (int i = 0; i < INSTR_DEPTH; i++) begin
                rom[i] <= 32'h8000_0000;
            end
        end
        else if (wr_en) begin
            // NEW — CPU write port. One word per pulse. Deliberately does not
            // interact with pop_en/restart in this same cycle beyond normal
            // Verilog non-blocking-assignment semantics: if wr_en and pop_en
            // both happen to be asserted the same cycle (shouldn't occur —
            // wr_en is gated with !busy upstream, and pop_en only asserts
            // while busy — see hazard notes in the proposal doc), the write
            // still lands in `rom` this cycle and the *next* pop_en's
            // rom[fetch_ptr] read (a cycle later) will already observe it;
            // the in-flight `window` shift below reads the OLD rom via a
          // separate always_ff (see below), so no same-cycle read/write
            // collision on the same memory word is possible in the intended
            // usage (write-while-idle, pop-while-busy never overlap).
            rom[wr_addr] <= wr_data;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || restart) begin
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
                    window[i] <= window[i+1];
                end
            end

            fetch_ptr <= (fetch_ptr + 1) % INSTR_DEPTH;
        end
    end

endmodule
