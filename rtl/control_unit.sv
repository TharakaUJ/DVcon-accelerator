`timescale 1ns/1ps

module control_unit #(
    parameter integer ARRAY_SIZE = 16,
    parameter integer OUT_DEPTH  = 2,
    parameter integer DATA_WIDTH = 8,
    parameter integer DMA_WIDTH = 64,
    parameter integer ADDR_WIDTH = 8,
    parameter integer ACT_AW     = $clog2(ARRAY_SIZE * ARRAY_SIZE * DATA_WIDTH / DMA_WIDTH),
    parameter integer OUT_AW     = $clog2(ARRAY_SIZE),
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

    // ── Descriptor registers (from AXI-lite slave) ───────────────────────────
    // NOTE: these were previously dead-ended at the top level; control_unit
    // needs them to actually program the DMA engine.
    input  logic [DMA_WIDTH-1:0] src_addr,
    input  logic [DMA_WIDTH-1:0] dst_addr,
    input  logic [DMA_WIDTH-1:0] weight_addr,
    input  logic [15:0]           img_rows,
    input  logic [15:0]           img_cols,

    // ── DMA (axi4_master) trigger interface ──────────────────────────────────
    // NOTE: new. axi4_master's rd_start/wr_start were previously unwired
    // from anything, so the DMA engine could never actually start a burst.
    output logic                  dma_rd_start,
    output logic [DMA_WIDTH-1:0] dma_rd_addr,
    output logic [7:0]            dma_rd_len,
    output logic                  dma_wr_start,
    output logic [DMA_WIDTH-1:0] dma_wr_addr,
    output logic [7:0]            dma_wr_len,

    // ── Weight BRAM control ──────────────────────────────────────────────────
    output logic                 wt_wr_en,
    output logic [ACT_AW-1:0]    wt_wr_addr,
    output logic                 wt_rd_en,
    output logic                 wt_rd_buf,

    // ── Activation BRAM control ──────────────────────────────────────────────
    output logic                 act_wr_en,
    output logic [ACT_AW-1:0]    act_wr_addr,
    output logic                 act_wr_buf,
    output logic                 act_rd_en,
    output logic [BANK_W-1:0]    act_rd_addr,
    output logic                 act_rd_buf,

    // ── Output BRAM control ──────────────────────────────────────────────────
    output logic                 out_rd_en,
    output logic [OUT_AW-1:0]    out_rd_addr,
    output logic                 out_rd_buf,
    output logic                 out_wr_en,
    output logic [BANK_W-1:0]    out_wr_addr,
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

    // function automatic logic can_issue_swap_wgt;
    //     return
    //         wgt_buf_state == BUF_READY &&
    //         array_state == ENG_IDLE;
    // endfunction

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
        wt_wr_addr = '0;
        wt_rd_en = 1'b0;
        wt_rd_buf = 1'b0;

        act_wr_en = 1'b0;
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

        dma_rd_start = 1'b0;
        dma_rd_addr  = '0;
        dma_rd_len   = '0;
        dma_wr_start = 1'b0;
        dma_wr_addr  = '0;
        dma_wr_len   = '0;

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

                    // OP_SWAP_WGT:
                    //     if(can_issue_swap_wgt()) begin
                    //         issue_packet.valid  = 1'b1;
                    //         issue_packet.opcode = current_inst.opcode;
                    //         issue_packet.src    = current_inst.src;
                    //         issue_packet.dst    = current_inst.dst;
                    //         issue_packet.addr   = current_inst.addr;
                    //         issue_packet.length = current_inst.length;
                    //         issue_valid = 1'b1;
                    //         issue_index = i;
                    //         already_selected = 1'b1;
                    //     end

                    OP_END: begin
                        if (i == 0 && (dma_rd_state == ENG_IDLE) && (dma_wr_state == ENG_IDLE) && (array_state == ENG_IDLE) && (vector_state == ENG_IDLE)) begin
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
                    // Kick off a DMA read burst for the weight tile. wt_wr_en/
                    // wt_wr_addr here only pulse the *first* BRAM write; actually
                    // walking wt_wr_addr across ARRAY_SIZE rows as beats arrive
                    // from master_rd_data needs a beat counter driven off
                    // master_rd_data_valid -- see TODO block below.
                    wt_wr_en  = 1'b1;
                    wt_wr_addr = issue_packet.addr[BANK_W-1:0];

                    dma_rd_start = 1'b1;
                    // TODO: confirm address math. Using weight_addr as base +
                    // an offset derived from issue_packet.addr (tile index).
                    // Replace with whatever addressing scheme your ISA actually
                    // encodes (e.g. addr may already be a byte/row offset).
                    dma_rd_addr  = weight_addr + (ADDR_WIDTH'(issue_packet.addr) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));
                    dma_rd_len   = issue_packet.length; // TODO: or derive from ARRAY_SIZE*DATA_WIDTH
                end

                OP_LOAD_ACT: begin
                    act_wr_en   = 1'b1;
                    act_wr_addr = issue_packet.addr[ACT_AW-1:0];
                    act_wr_buf  = issue_packet.dst[0];

                    dma_rd_start = 1'b1;
                    // TODO: confirm address math against how src_addr/img_rows/
                    // img_cols encode the activation tensor layout.
                    dma_rd_addr  = src_addr + (ADDR_WIDTH'(issue_packet.addr) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));
                    dma_rd_len   = issue_packet.length;
                end

                OP_LOAD_WGT: begin
                    // TODO: confirm address math. and rest too
                    wt_wr_en  = 1'b1;
                    wt_wr_addr = issue_packet.addr[ACT_AW-1:0];

                    dma_rd_start = 1'b1;
                    dma_rd_addr  = weight_addr + (ADDR_WIDTH'(issue_packet.addr) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));
                    dma_rd_len   = issue_packet.length;
                end

                OP_MATMUL: begin
                    wt_rd_en          = 1'b1;
                    wt_rd_buf         = 1'b0;
                    act_rd_en         = 1'b1;
                    act_rd_addr       = issue_packet.addr[ACT_AW-1:0];
                    act_rd_buf        = issue_packet.src[0];
                    array_en          = 1'b1;
                    array_clear_acc   = 1'b1;
                    // FIX: array_weight_load removed from here. Reloading
                    // weights on every MATMUL was redundant with OP_SWAP_WGT,
                    // which already exists to reload weights explicitly.
                end

                OP_VECTOR: begin
                    out_wr_en   = 1'b1;
                    out_wr_addr = issue_packet.addr[BANK_W-1:0];
                    out_wr_buf  = issue_packet.dst[0];
                end

                OP_STORE: begin
                    out_rd_en   = 1'b1;
                    out_rd_addr = issue_packet.addr[OUT_AW-1:0];
                    out_rd_buf  = issue_packet.src[0];

                    dma_wr_start = 1'b1;
                    // TODO: confirm address math against dst_addr layout.
                    dma_wr_addr  = dst_addr + (ADDR_WIDTH'(issue_packet.addr) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));
                    dma_wr_len   = issue_packet.length;
                end

                // OP_SWAP_WGT: begin
                //     array_weight_load = 1'b1;
                // end

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

    // TODO -- MULTI-BEAT BRAM STREAMING (hand-tune against axi4_master timing)
    // ---------------------------------------------------------------------
    // OP_LOAD_WGT currently only pulses wt_wr_en/wt_wr_addr for ONE row on the
    // cycle it's issued. A full weight tile is ARRAY_SIZE rows, arriving over
    // ARRAY_SIZE (or more, depending on DMA_WIDTH vs DATA_WIDTH*ARRAY_SIZE)
    // beats of master_rd_data_valid from axi4_master. Same issue for
    // OP_LOAD_ACT (num_acts beats) and OP_STORE (draining out_buf).
    //
    // Skeleton for what's needed here:
    //
    //   logic [BANK_W:0] wt_beat_cnt;
    //   always_ff @(posedge clk) begin
    //     if(!rst_n) wt_beat_cnt <= '0;
    //     else if(issue_packet.valid && issue_packet.opcode == OP_LOAD_WGT)
    //       wt_beat_cnt <= '0;
    //     else if(dma_rd_state == ENG_BUSY && dma_rd_is_weight && master_rd_data_valid)
    //       wt_beat_cnt <= wt_beat_cnt + 1'b1;
    //   end
    //   // then drive wt_wr_en/wt_wr_addr off (dma_rd_is_weight && master_rd_data_valid)
    //   // instead of only off issue_packet.valid, indexing wt_wr_addr by wt_beat_cnt.
    //
    // This needs master_rd_data_valid piped into control_unit (new input port)
    // and an equivalent counter/mux for act_wr_addr (indexed by num_acts) and
    // out_rd_addr (indexed by store length). Left unimplemented since it
    // depends on axi4_master's exact beat-valid timing, which I haven't seen.


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