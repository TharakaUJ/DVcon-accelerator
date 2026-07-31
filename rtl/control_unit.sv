`timescale 1ns/1ps

module control_unit #(
    parameter integer ARRAY_SIZE = 16,
    parameter integer ACT_DEPTH  = 512,
    parameter integer OUT_DEPTH  = 1024,
    parameter integer ACT_AW     = $clog2(ACT_DEPTH),
    parameter integer OUT_AW     = $clog2(OUT_DEPTH),
    parameter integer BANK_W     = $clog2(ARRAY_SIZE),
    parameter integer INSTR_WINDOW_SIZE = 16,
    parameter integer INSTR_WIDTH = 24
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ── Run control / status ─────────────────────────────────────────────────
    input  wire                  start_pulse,
    input  wire                  soft_reset,
    input  wire                  perf_valid,    // array finished draining
    input  wire [15:0]           num_acts,      // K activation vectors
    output reg                   busy,
    output reg                   done,
    output reg  [3:0]            fsm_state,
    output wire                  loading_weights,
    output wire                  streaming_acts,

    // ── Weight BRAM control ──────────────────────────────────────────────────
    output wire                  wt_wr_en,
    output wire [BANK_W-1:0]     wt_wr_row,
    output wire                  wt_wr_buf,
    output wire                  wt_rd_en,
    output wire                  wt_rd_buf,
    output wire                  weight_swap,

    // ── Activation BRAM control ──────────────────────────────────────────────
    output wire                  act_wr_en,
    output wire [BANK_W-1:0]     act_wr_bank,
    output wire [ACT_AW-1:0]     act_wr_addr,
    output wire                  act_wr_buf,
    output wire                  act_rd_en,
    output wire [ACT_AW-1:0]     act_rd_addr,
    output wire                  act_rd_buf,

    // ── Output BRAM control ──────────────────────────────────────────────────
    output wire                  out_rd_en,
    output wire [OUT_AW-1:0]     out_rd_addr,
    output wire                  out_rd_buf,
    output wire                  out_wr_en,
    output wire [OUT_AW-1:0]     out_wr_addr,
    output wire                  out_wr_buf,

    // ── Systolic Array control ────────────────────────────────────────────────
    output wire                  array_en,
    output wire                  array_clear_acc,
    output wire                  array_weight_load,

    // Instruction FIFO interface
    output  wire                  fifo_pop_en,
    output  wire [$clog2(INSTR_WINDOW_SIZE)-1:0] fifo_pop_idx,
    input  wire [INSTR_WIDTH-1:0] fifo_window [0:INSTR_WINDOW_SIZE-1]
);


    ///////////////////////////////////////////////////////////////////////////////
    // Types
    ///////////////////////////////////////////////////////////////////////////////

    typedef enum logic [3:0] {
        OP_NOP,
        OP_LOAD_WGT,
        OP_LOAD_ACT,
        OP_MATMUL,
        OP_VECTOR,
        OP_STORE,
        OP_SWAP_WGT,
        OP_END
    } opcode_t;

    typedef enum logic [1:0] {
        BUF_EMPTY,
        BUF_FILLING,
        BUF_READY,
        BUF_IN_USE
    } buffer_state_t;

    typedef enum logic {
        ENG_IDLE,
        ENG_BUSY
    } engine_state_t;


    localparam int INSTR_OPCODE_LSB = 0;
    localparam int INSTR_OPCODE_MSB = 3;
    localparam int INSTR_SRC_LSB    = 4;
    localparam int INSTR_SRC_MSB    = 5;
    localparam int INSTR_DST_LSB    = 6;
    localparam int INSTR_DST_MSB    = 7;
    localparam int INSTR_ADDR_LSB   = 8;
    localparam int INSTR_ADDR_MSB   = 15;
    localparam int INSTR_LENGTH_LSB = 16;
    localparam int INSTR_LENGTH_MSB = 23;


    ///////////////////////////////////////////////////////////////////////////////
    // Scoreboard
    ///////////////////////////////////////////////////////////////////////////////

    buffer_state_t act_buf_state[2];
    buffer_state_t out_buf_state[2];
    buffer_state_t wgt_buf_state;

    engine_state_t dma_rd_state;
    engine_state_t dma_wr_state;
    engine_state_t array_state;
    engine_state_t vector_state;


    ///////////////////////////////////////////////////////////////////////////////
    // Issue signals
    ///////////////////////////////////////////////////////////////////////////////

    logic issue_valid;
    logic [$clog2(INSTR_WINDOW_SIZE)-1:0] issue_index;

    ///////////////////////////////////////////////////////////////////////////////
    // Dependency checker
    ///////////////////////////////////////////////////////////////////////////////

    function automatic logic can_issue_load_act(
        input logic [INSTR_WIDTH-1:0] inst
    );

        return
            dma_rd_state == ENG_IDLE &&
            act_buf_state[inst[INSTR_DST_MSB:INSTR_DST_LSB]] == BUF_EMPTY;

    endfunction


    function automatic logic can_issue_matmul(
        input logic [INSTR_WIDTH-1:0] inst
    );

        return
            array_state == ENG_IDLE &&
            wgt_buf_state == BUF_READY &&
            act_buf_state[inst[INSTR_SRC_MSB:INSTR_SRC_LSB]] == BUF_READY &&
            out_buf_state[inst[INSTR_DST_MSB:INSTR_DST_LSB]] == BUF_EMPTY;

    endfunction


    function automatic logic can_issue_store(
        input logic [INSTR_WIDTH-1:0] inst
    );

        return
            dma_wr_state == ENG_IDLE &&
            out_buf_state[inst[INSTR_SRC_MSB:INSTR_SRC_LSB]] == BUF_READY;

    endfunction


    ///////////////////////////////////////////////////////////////////////////////
    // Scheduler
    ///////////////////////////////////////////////////////////////////////////////

    integer i;

    always_comb begin

        issue_valid = 1'b0;
        issue_index = '0;

        start_dma_rd = 0;
        start_dma_wr = 0;
        start_array  = 0;
        start_vector = 0;

        //----------------------------------------------------------
        // Scan instruction window
        //----------------------------------------------------------

        for(i=0;i<INSTR_WINDOW_SIZE;i++) begin

            unique case(fifo_window[i][INSTR_OPCODE_MSB:INSTR_OPCODE_LSB])

                OP_LOAD_ACT:

                    if(can_issue_load_act(fifo_window[i])) begin

                        issue_valid = 1;
                        issue_index = i;

                        start_dma_rd = 1;

                        break;
                    end

                OP_MATMUL:

                    if(can_issue_matmul(fifo_window[i])) begin

                        issue_valid = 1;
                        issue_index = i;

                        start_array = 1;

                        break;
                    end

                OP_STORE:

                    if(can_issue_store(fifo_window[i])) begin

                        issue_valid = 1;
                        issue_index = i;

                        start_dma_wr = 1;

                        break;
                    end

            endcase

        end

    end


    ///////////////////////////////////////////////////////////////////////////////
    // Scoreboard update
    ///////////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk) begin

        if(!rst_n) begin

            act_buf_state[0] <= BUF_EMPTY;
            act_buf_state[1] <= BUF_EMPTY;

            out_buf_state[0] <= BUF_EMPTY;
            out_buf_state[1] <= BUF_EMPTY;

            wgt_buf_state <= BUF_EMPTY;

            dma_rd_state <= ENG_IDLE;
            dma_wr_state <= ENG_IDLE;
            array_state  <= ENG_IDLE;
            vector_state <= ENG_IDLE;

        end

        else begin

            //------------------------------------------------------
            // Reserve resources immediately after issue
            //------------------------------------------------------

            if(issue_valid) begin

                unique case(fifo_window[issue_index][INSTR_OPCODE_MSB:INSTR_OPCODE_LSB])

                    OP_LOAD_ACT: begin

                        dma_rd_state <= ENG_BUSY;
                        act_buf_state[fifo_window[issue_index][INSTR_DST_MSB:INSTR_DST_LSB]]
                            <= BUF_FILLING;

                    end

                    OP_MATMUL: begin

                        array_state <= ENG_BUSY;

                        act_buf_state[fifo_window[issue_index][INSTR_SRC_MSB:INSTR_SRC_LSB]]
                            <= BUF_IN_USE;

                        out_buf_state[fifo_window[issue_index][INSTR_DST_MSB:INSTR_DST_LSB]]
                            <= BUF_IN_USE;

                    end

                    OP_STORE: begin

                        dma_wr_state <= ENG_BUSY;

                        out_buf_state[fifo_window[issue_index][INSTR_SRC_MSB:INSTR_SRC_LSB]]
                            <= BUF_IN_USE;

                    end

                endcase

            end

            //------------------------------------------------------
            // Completion events
            //------------------------------------------------------

            if(dma_rd_done) begin

                dma_rd_state <= ENG_IDLE;

                // Which buffer completed?
                // (Real design stores transaction context)
            end

            if(array_done) begin

                array_state <= ENG_IDLE;

                // Activation buffer becomes EMPTY
                // Output buffer becomes READY
            end

            if(dma_wr_done) begin

                dma_wr_state <= ENG_IDLE;

                // Output buffer becomes EMPTY
            end

        end

    end
    


endmodule