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
    input  wire                               restart
);

    logic [INSTR_WIDTH-1:0] rom [0:INSTR_DEPTH-1];

    logic [$clog2(INSTR_DEPTH)-1:0] fetch_ptr;

    //=========================================================================
    // Sample program: simple GEMM, ARRAY_SIZE=8, DATA_WIDTH=8, DMA_WIDTH=64.
    //
    //   A = [1 2]   B = [5 6]   C = A x B = [19 22]
    //       [3 4]       [7 8]               [43 50]
    //
    // A/B are zero-padded to 8x8 in DRAM before the run; only 2 of 8 possible
    // output rows are computed. Weight tile W == B (weight-stationary array
    // computes result_out[c] = sum_r act_in[r]*W[r][c] == C[row][c] when
    // act_in is a row of A). Bias is loaded as all-zero (identity path);
    // REG_VEC_CTRL defaults to mult=1/shift=0/act_type=0(passthrough), so no
    // extra CSR write is needed for this program.
    //
    // At this ARRAY_SIZE/DATA_WIDTH/DMA_WIDTH combo, ELEMENTS_PER_BEAT =
    // DMA_WIDTH/DATA_WIDTH = 8 = ARRAY_SIZE, so one DMA beat == one full row
    // for both the weight tile and the activation tile (no partial-row/
    // partial-beat accounting needed for this example).
    //
    // IMPORTANT — MATMUL/VECTOR are alternated per row (matmul(0), vector(0),
    // matmul(1), vector(1)) rather than batched, because accum_buf_state is
    // still single-banked (flagged as a known, unfixed limitation in the
    // handoff) — a second MATMUL can't issue until the first row's VECTOR
    // has drained the accum buffer.
    //
    // Byte layout: [opcode(4)|src(2)|dst(2)] [addr(8)] [length(8)] [accum_ctrl(2)|reserved(6)]
    //   opcode: NOP=0 LOAD_WGT=1 LOAD_ACT=2 LOAD_BIAS=3 MATMUL=4 VECTOR=5 STORE=6 SWAP_WGT=7 END=8
    //   accum_ctrl: NONE=0 INIT=1 ADD=2 LAST=3
    //   addr semantics: DMA-beat index for LOAD_WGT/LOAD_ACT/LOAD_BIAS/STORE;
    //                   row index for MATMUL/VECTOR.
    //   length semantics: beats-1 (AxLEN convention) for LOAD_*/STORE.
    //
    //  0: NOP
    //  1: LOAD_WGT   dst=0        addr=0x00 len=7   (8 beats = full 8x8 W tile, from weight_addr)
    //  2: LOAD_ACT   dst=0        addr=0x00 len=1   (2 beats = rows 0,1 of A, from src_addr)
    //  3: LOAD_BIAS               addr=0x00 len=3   (4 beats = 8 zero INT32 lanes, from bias_addr)
    //  4: SWAP_WGT                                  (parks W tile into the array's weight_reg)
    //  5: MATMUL     src=0        addr=0x00         accum_ctrl=NONE  (row 0: act row0 x W -> accum row0)
    //  6: VECTOR           dst=0  addr=0x00                          (drain accum row0 -> out_buf[0] row0)
    //  7: MATMUL     src=0        addr=0x01         accum_ctrl=NONE  (row 1: act row1 x W -> accum row1)
    //  8: VECTOR           dst=0  addr=0x01                          (drain accum row1 -> out_buf[0] row1)
    //  9: STORE      src=0        addr=0x00 len=1   (2 beats = 2 rows, out_buf[0] -> dst_addr)
    // 10: END
    initial begin
        rom[0]  = 32'h00000000;  // NOP
        rom[1]  = 32'h10000700;  // LOAD_WGT  dst=0 addr=0x00 len=7  (opcode=1)
        rom[2]  = 32'h20000100;  // LOAD_ACT  dst=0 addr=0x00 len=1  (opcode=2)
        rom[3]  = 32'h30000300;  // LOAD_BIAS       addr=0x00 len=3  (opcode=3)
        rom[4]  = 32'h70000000;  // SWAP_WGT                          (opcode=7)
        rom[5]  = 32'h40000000;  // MATMUL    src=0 addr=0x00        accum_ctrl=NONE (opcode=4)
        rom[6]  = 32'h50000000;  // VECTOR          dst=0 addr=0x00  (opcode=5)
        rom[7]  = 32'h40010000;  // MATMUL    src=0 addr=0x01        accum_ctrl=NONE
        rom[8]  = 32'h50010000;  // VECTOR          dst=0 addr=0x01
        rom[9]  = 32'h60000100;  // STORE     src=0 addr=0x00 len=1  (opcode=6)
        rom[10] = 32'h80000000;  // END                                (opcode=8)
        rom[11] = 32'h80000000;  // padding — never reached (fetch_ptr stops advancing at OP_END, see control_unit fix)
        rom[12] = 32'h80000000;
        rom[13] = 32'h80000000;
        rom[14] = 32'h80000000;
        rom[15] = 32'h80000000;
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
