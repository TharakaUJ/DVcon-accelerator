`timescale 1ns/1ps

module control_unit #(
    parameter integer ARRAY_SIZE = 16,
    parameter integer ACT_DEPTH  = 512,
    parameter integer OUT_DEPTH  = 1024,
    parameter integer DATA_WIDTH = 8,
    parameter integer DMA_WIDTH = 64,
    parameter integer ACT_AW     = $clog2(ACT_DEPTH),
    parameter integer OUT_AW     = $clog2(OUT_DEPTH),
    parameter integer BANK_W     = $clog2(ARRAY_SIZE),
    parameter integer INSTR_WINDOW_SIZE = 4,
    parameter integer INSTR_WIDTH = 24
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // ── Run control / status ─────────────────────────────────────────────────
    input  logic                 start_pulse,
    input  logic                 soft_reset,
    input  logic                 perf_valid,    // array finished draining
    input  logic [15:0]          num_acts,      // K activation vectors
    input  logic                 dma_rd_done,
    input  logic                 dma_wr_done,
    input  logic                 array_done,
    input  logic                 vector_done,
    output logic                 busy,
    output logic                 done,
    output logic [3:0]           fsm_state,
    output logic                 loading_weights,
    output logic                 streaming_acts,

    // ── Weight BRAM control ──────────────────────────────────────────────────
    output logic                 wt_wr_en,
    output logic [BANK_W-1:0]    wt_wr_row,
    output logic                 wt_wr_buf,
    output logic                 wt_rd_en,
    output logic                 wt_rd_buf,
    output logic                 weight_swap,

    // ── Activation BRAM control ──────────────────────────────────────────────
    output logic                 act_wr_en,
    output logic [BANK_W-1:0]    act_wr_bank,
    output logic [ACT_AW-1:0]    act_wr_addr,
    output logic                 act_wr_buf,
    output logic                 act_rd_en,
    output logic [ACT_AW-1:0]    act_rd_addr,
    output logic                 act_rd_buf,

    // ── Output BRAM control ──────────────────────────────────────────────────
    output logic                 out_rd_en,
    output logic [OUT_AW-1:0]    out_rd_addr,
    output logic                 out_rd_buf,
    output logic                 out_wr_en,
    output logic [OUT_AW-1:0]    out_wr_addr,
    output logic                 out_wr_buf,

    // ── Systolic Array control ────────────────────────────────────────────────
    output logic                 array_en,
    output logic                 array_clear_acc,
    output logic                 array_weight_load,

    // Instruction FIFO interface
    output logic                 fifo_pop_en,
    output logic [$clog2(INSTR_WINDOW_SIZE)-1:0] fifo_pop_idx,
    input  logic [INSTR_WIDTH-1:0] fifo_window [0:INSTR_WINDOW_SIZE-1]
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

    typedef struct packed {
        opcode_t       opcode;
        logic [1:0]    src;
        logic [1:0]    dst;
        logic [7:0]    addr;
        logic [7:0]    length;
    } instruction_t;

    typedef struct packed {
        logic          valid;
        opcode_t       opcode;
        logic [1:0]    src;
        logic [1:0]    dst;
        logic [7:0]    addr;
        logic [7:0]    length;
    } issue_packet_t;


    ///////////////////////////////////////////////////////////////////////////////
    // Scoreboard
    ///////////////////////////////////////////////////////////////////////////////

    // Resource scoreboard: this block only stores ownership state.
    // All issue decisions are made combinationally from these registers.

    buffer_state_t act_buf_state[2];
    buffer_state_t out_buf_state[2];
    buffer_state_t wgt_buf_state;

    engine_state_t dma_rd_state;
    engine_state_t dma_wr_state;
    engine_state_t array_state;
    engine_state_t vector_state;

    logic          dma_rd_target_buf;
    logic          dma_rd_is_weight;
    logic          dma_wr_source_buf;
    logic          array_input_buf;
    logic          array_output_buf;
    logic          vector_input_buf;
    logic          vector_output_buf;


    ///////////////////////////////////////////////////////////////////////////////
    // Instruction window and issue packet
    ///////////////////////////////////////////////////////////////////////////////

    instruction_t  decoded_window [0:INSTR_WINDOW_SIZE-1];
    issue_packet_t issue_packet;
    logic          issue_valid;
    logic [$clog2(INSTR_WINDOW_SIZE)-1:0] issue_index;
    logic          already_selected;

    ///////////////////////////////////////////////////////////////////////////////
    // Dependency checker
    ///////////////////////////////////////////////////////////////////////////////
    function automatic logic can_issue_load_wgt;

        return
            dma_rd_state == ENG_IDLE &&
            wgt_buf_state == BUF_EMPTY;

    endfunction


    function automatic logic can_issue_load_act(
        input logic [1:0] dst
    );

        return
            dma_rd_state == ENG_IDLE &&
            act_buf_state[dst] == BUF_EMPTY;

    endfunction


    function automatic logic can_issue_matmul(
        input logic [1:0] src,
        input logic [1:0] dst
    );

        return
            array_state == ENG_IDLE &&
            wgt_buf_state == BUF_READY &&
            act_buf_state[src] == BUF_READY &&
            out_buf_state[dst] == BUF_EMPTY;

    endfunction


    function automatic logic can_issue_store(
        input logic [1:0] src
    );

        return
            dma_wr_state == ENG_IDLE &&
            out_buf_state[src] == BUF_READY;

    endfunction


    function automatic logic can_issue_swap_wgt;

        return
            wgt_buf_state == BUF_READY &&
            array_state == ENG_IDLE;

    endfunction


    function automatic logic can_issue_vector(
        input logic [1:0] src,
        input logic [1:0] dst
    );

        return
            vector_state == ENG_IDLE &&
            out_buf_state[src] == BUF_READY &&
            out_buf_state[dst] == BUF_EMPTY;

    endfunction


    ///////////////////////////////////////////////////////////////////////////////
    // Scheduler / dispatch
    ///////////////////////////////////////////////////////////////////////////////

    always_comb begin
        integer i;
        instruction_t current_inst;

        issue_packet = '0;
        issue_valid = 1'b0;
        issue_index = '0;
        already_selected = 1'b0;

        fifo_pop_en  = 1'b0;
        fifo_pop_idx = '0;

        wt_wr_en = 1'b0;
        wt_wr_row = '0;
        wt_wr_buf = 1'b0;
        wt_rd_en = 1'b0;
        wt_rd_buf = 1'b0;
        weight_swap = 1'b0;

        act_wr_en = 1'b0;
        act_wr_bank = '0;
        act_wr_addr = '0;
        act_wr_buf = 1'b0;
        act_rd_en = 1'b0;
        act_rd_addr = '0;
        act_rd_buf = 1'b0;

        out_rd_en = 1'b0;
        out_rd_addr = '0;
        out_rd_buf = 1'b0;
        out_wr_en = 1'b0;
        out_wr_addr = '0;
        out_wr_buf = 1'b0;

        array_en = 1'b0;
        array_clear_acc = 1'b0;
        array_weight_load = 1'b0;

        loading_weights = (dma_rd_state == ENG_BUSY && dma_rd_is_weight) ||
            (wgt_buf_state == BUF_FILLING);
        streaming_acts = (dma_rd_state == ENG_BUSY && !dma_rd_is_weight) ||
            (array_state == ENG_BUSY);

        for(i = 0; i < INSTR_WINDOW_SIZE; i = i + 1) begin
            decoded_window[i] = instruction_t'(fifo_window[i]);
        end

        // Scan the instruction window and select the first ready instruction.
        for(i = 0; i < INSTR_WINDOW_SIZE; i = i + 1) begin
            current_inst = decoded_window[i];

            if(!already_selected) begin
                unique case(current_inst.opcode)

                    OP_LOAD_WGT:
                        if(can_issue_load_wgt()) begin
                            issue_packet.valid  = 1'b1;
                            issue_packet.opcode = current_inst.opcode;
                            issue_packet.src    = current_inst.src;
                            issue_packet.dst    = current_inst.dst;
                            issue_packet.addr   = current_inst.addr;
                            issue_packet.length = current_inst.length;
                            issue_valid = 1'b1;
                            issue_index = i;
                            already_selected = 1'b1;
                        end

                    OP_LOAD_ACT:
                        if(can_issue_load_act(current_inst.dst)) begin
                            issue_packet.valid  = 1'b1;
                            issue_packet.opcode = current_inst.opcode;
                            issue_packet.src    = current_inst.src;
                            issue_packet.dst    = current_inst.dst;
                            issue_packet.addr   = current_inst.addr;
                            issue_packet.length = current_inst.length;
                            issue_valid = 1'b1;
                            issue_index = i;
                            already_selected = 1'b1;
                        end

                    OP_MATMUL:
                        if(can_issue_matmul(current_inst.src, current_inst.dst)) begin
                            issue_packet.valid  = 1'b1;
                            issue_packet.opcode = current_inst.opcode;
                            issue_packet.src    = current_inst.src;
                            issue_packet.dst    = current_inst.dst;
                            issue_packet.addr   = current_inst.addr;
                            issue_packet.length = current_inst.length;
                            issue_valid = 1'b1;
                            issue_index = i;
                            already_selected = 1'b1;
                        end

                    OP_VECTOR:
                        if(can_issue_vector(current_inst.src, current_inst.dst)) begin
                            issue_packet.valid  = 1'b1;
                            issue_packet.opcode = current_inst.opcode;
                            issue_packet.src    = current_inst.src;
                            issue_packet.dst    = current_inst.dst;
                            issue_packet.addr   = current_inst.addr;
                            issue_packet.length = current_inst.length;
                            issue_valid = 1'b1;
                            issue_index = i;
                            already_selected = 1'b1;
                        end

                    OP_STORE:
                        if(can_issue_store(current_inst.src)) begin
                            issue_packet.valid  = 1'b1;
                            issue_packet.opcode = current_inst.opcode;
                            issue_packet.src    = current_inst.src;
                            issue_packet.dst    = current_inst.dst;
                            issue_packet.addr   = current_inst.addr;
                            issue_packet.length = current_inst.length;
                            issue_valid = 1'b1;
                            issue_index = i;
                            already_selected = 1'b1;
                        end

                    OP_SWAP_WGT:
                        if(can_issue_swap_wgt()) begin
                            issue_packet.valid  = 1'b1;
                            issue_packet.opcode = current_inst.opcode;
                            issue_packet.src    = current_inst.src;
                            issue_packet.dst    = current_inst.dst;
                            issue_packet.addr   = current_inst.addr;
                            issue_packet.length = current_inst.length;
                            issue_valid = 1'b1;
                            issue_index = i;
                            already_selected = 1'b1;
                        end

                    OP_END: begin
                        issue_packet.valid  = 1'b1;
                        issue_packet.opcode = current_inst.opcode;
                        issue_packet.src    = current_inst.src;
                        issue_packet.dst    = current_inst.dst;
                        issue_packet.addr   = current_inst.addr;
                        issue_packet.length = current_inst.length;
                        issue_valid = 1'b1;
                        issue_index = i;
                        already_selected = 1'b1;
                    end

                    default: begin
                    end

                endcase
            end
        end

        fifo_pop_en  = issue_valid;
        fifo_pop_idx = issue_index;

        // Dispatch block: convert the selected issue packet into engine pulses.
        if(issue_packet.valid) begin
            unique case(issue_packet.opcode)

                OP_LOAD_WGT: begin
                    wt_wr_en  = 1'b1;
                    wt_wr_row = issue_packet.addr[BANK_W-1:0];
                    wt_wr_buf = 1'b0;
                end

                OP_LOAD_ACT: begin
                    act_wr_en   = 1'b1;
                    act_wr_bank = issue_packet.dst;
                    act_wr_addr = issue_packet.addr[ACT_AW-1:0];
                    act_wr_buf  = issue_packet.dst[0];
                end

                OP_MATMUL: begin
                    wt_rd_en          = 1'b1;
                    wt_rd_buf         = 1'b0;
                    act_rd_en         = 1'b1;
                    act_rd_addr       = issue_packet.addr[ACT_AW-1:0];
                    act_rd_buf        = issue_packet.src[0];
                    array_en          = 1'b1;
                    array_clear_acc   = 1'b1;
                    array_weight_load = 1'b1;
                end

                OP_VECTOR: begin
                    out_wr_en   = 1'b1;
                    out_wr_addr = issue_packet.addr[OUT_AW-1:0];
                    out_wr_buf  = issue_packet.dst[0];
                end

                OP_STORE: begin
                    out_rd_en   = 1'b1;
                    out_rd_addr = issue_packet.addr[OUT_AW-1:0];
                    out_rd_buf  = issue_packet.src[0];
                end

                OP_SWAP_WGT: begin
                    weight_swap       = 1'b1;
                    array_weight_load = 1'b1;
                end

                default: begin
                end

            endcase
        end

        if(dma_rd_state != ENG_IDLE) begin
            fsm_state = dma_rd_is_weight ? 4'd1 : 4'd2;
        end
        else if(array_state == ENG_BUSY) begin
            fsm_state = 4'd3;
        end
        else if(dma_wr_state == ENG_BUSY) begin
            fsm_state = 4'd4;
        end
        else if(vector_state == ENG_BUSY) begin
            fsm_state = 4'd5;
        end
        else if(issue_packet.valid && issue_packet.opcode == OP_END) begin
            fsm_state = 4'd7;
        end
        else begin
            fsm_state = 4'd0;
        end

        busy = start_pulse ||
            (dma_rd_state == ENG_BUSY) ||
            (dma_wr_state == ENG_BUSY) ||
            (array_state == ENG_BUSY) ||
            (vector_state == ENG_BUSY) ||
            issue_packet.valid;

        done = (issue_packet.valid && issue_packet.opcode == OP_END) ||
            (perf_valid &&
            (dma_rd_state == ENG_IDLE) &&
            (dma_wr_state == ENG_IDLE) &&
            (array_state == ENG_IDLE) &&
            (vector_state == ENG_IDLE) &&
            !issue_packet.valid);
    end


    ///////////////////////////////////////////////////////////////////////////////
    // Scoreboard update
    ///////////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk) begin

        if(!rst_n || soft_reset) begin

            act_buf_state[0] <= BUF_EMPTY;
            act_buf_state[1] <= BUF_EMPTY;

            out_buf_state[0] <= BUF_EMPTY;
            out_buf_state[1] <= BUF_EMPTY;

            wgt_buf_state <= BUF_EMPTY;

            dma_rd_state <= ENG_IDLE;
            dma_wr_state <= ENG_IDLE;
            array_state  <= ENG_IDLE;
            vector_state <= ENG_IDLE;

            dma_rd_target_buf <= 1'b0;
            dma_rd_is_weight  <= 1'b0;
            dma_wr_source_buf <= 1'b0;
            array_input_buf   <= 1'b0;
            array_output_buf  <= 1'b0;
            vector_input_buf  <= 1'b0;
            vector_output_buf <= 1'b0;

        end

        else begin

            //------------------------------------------------------
            // Reserve resources immediately after issue.
            //------------------------------------------------------

            if(issue_packet.valid) begin

                unique case(issue_packet.opcode)

                    OP_LOAD_WGT: begin

                        dma_rd_state     <= ENG_BUSY;
                        dma_rd_is_weight <= 1'b1;
                        wgt_buf_state    <= BUF_FILLING;

                    end

                    OP_LOAD_ACT: begin

                        dma_rd_state      <= ENG_BUSY;
                        dma_rd_is_weight  <= 1'b0;
                        dma_rd_target_buf <= issue_packet.dst[0];
                        act_buf_state[issue_packet.dst] <= BUF_FILLING;

                    end

                    OP_MATMUL: begin

                        array_state      <= ENG_BUSY;
                        array_input_buf  <= issue_packet.src[0];
                        array_output_buf <= issue_packet.dst[0];

                        act_buf_state[issue_packet.src] <= BUF_IN_USE;
                        out_buf_state[issue_packet.dst] <= BUF_IN_USE;

                    end

                    OP_VECTOR: begin

                        vector_state      <= ENG_BUSY;
                        vector_input_buf  <= issue_packet.src[0];
                        vector_output_buf <= issue_packet.dst[0];

                        out_buf_state[issue_packet.src] <= BUF_IN_USE;
                        out_buf_state[issue_packet.dst] <= BUF_IN_USE;

                    end

                    OP_STORE: begin

                        dma_wr_state      <= ENG_BUSY;
                        dma_wr_source_buf <= issue_packet.src[0];
                        out_buf_state[issue_packet.src] <= BUF_IN_USE;

                    end

                    OP_SWAP_WGT: begin

                        wgt_buf_state <= BUF_READY;

                    end

                    default: begin
                    end

                endcase

            end

            //------------------------------------------------------
            // Completion events.
            //------------------------------------------------------

            if(dma_rd_done) begin

                dma_rd_state <= ENG_IDLE;

                if(dma_rd_is_weight) begin
                    wgt_buf_state <= BUF_READY;
                end
                else begin
                    act_buf_state[dma_rd_target_buf] <= BUF_READY;
                end

            end

            if(array_done) begin

                array_state <= ENG_IDLE;

                act_buf_state[array_input_buf] <= BUF_EMPTY;
                out_buf_state[array_output_buf] <= BUF_READY;

            end

            if(dma_wr_done) begin

                dma_wr_state <= ENG_IDLE;
                out_buf_state[dma_wr_source_buf] <= BUF_EMPTY;

            end

            if(vector_done) begin

                vector_state <= ENG_IDLE;
                out_buf_state[vector_input_buf] <= BUF_EMPTY;
                out_buf_state[vector_output_buf] <= BUF_READY;

            end

        end

    end


endmodule
