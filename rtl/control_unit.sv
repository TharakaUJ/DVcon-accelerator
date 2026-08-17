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
    parameter integer INSTR_WIDTH = 32,                                        // NEW — was 24; grew to fit accum_ctrl field
    parameter integer ACCUM_AW   = $clog2(ARRAY_SIZE),                          // NEW — accum buffer row address width
    parameter integer BIAS_AW    = $clog2(ARRAY_SIZE * 32 / DMA_WIDTH)          // NEW — bias buffer chunk address width (32b elements)
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
    input  logic [DMA_WIDTH-1:0] bias_addr,     // NEW — UNKNOWN: not yet backed by an axi4_lite_slave register (see summary)
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

    // ── Accumulation buffer control (NEW) ─────────────────────────────────────
    // Sits between systolic array and vector unit. wr_* driven on OP_MATMUL,
    // rd_* driven on OP_VECTOR.
    output logic                  accum_wr_en,
    output logic                  accum_wr_init,     // 1=overwrite row, 0=accumulate into row
    output logic [ACCUM_AW-1:0]   accum_wr_addr,
    output logic                  accum_rd_en,
    output logic [ACCUM_AW-1:0]   accum_rd_addr,

    // ── Bias buffer control (NEW) ─────────────────────────────────────────────
    // Loaded via OP_LOAD_BIAS (DMA), read on OP_VECTOR. Persistent resource:
    // stays READY across many OP_VECTOR issues until explicitly reloaded.
    output logic                  bias_wr_en,
    output logic [BIAS_AW-1:0]    bias_wr_addr,
    output logic                  bias_rd_en,

    // ── Vector unit control (NEW — was previously undriven/dangling) ─────────
    output logic                  vector_in_valid,

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
        OP_LOAD_BIAS,    // NEW — DMA-load the bias buffer (mirrors OP_LOAD_WGT)
        OP_MATMUL,
        OP_VECTOR,
        OP_STORE,
        OP_SWAP_WGT,
        OP_END
    } opcode_t;

    // NEW — per-OP_MATMUL control of how the array's tile result is combined
    // into the accumulation buffer.
    //   ACC_NONE : single-pass matmul, no external reduction. Overwrite the
    //              accum row and mark it READY immediately (equivalent to the
    //              old direct array->vector_unit behavior).
    //   ACC_INIT : first tile of a multi-tile reduction group. Overwrite the
    //              accum row; buffer stays FILLING (more tiles expected).
    //   ACC_ADD  : middle tile of a reduction group. Add into the accum row;
    //              buffer stays FILLING.
    //   ACC_LAST : final tile of a reduction group. Add into the accum row
    //              and mark the buffer READY for OP_VECTOR to consume.
    typedef enum logic [1:0] {
        ACC_NONE = 2'd0,
        ACC_INIT = 2'd1,
        ACC_ADD  = 2'd2,
        ACC_LAST = 2'd3
    } accum_ctrl_t;

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

    // NEW — which resource the current/last DMA read targeted. Replaces the
    // old single-bit dma_rd_is_weight now that bias is also DMA-loaded.
    typedef enum logic [1:0] {
        DMA_TGT_ACT,
        DMA_TGT_WEIGHT,
        DMA_TGT_BIAS
    } dma_rd_target_t;

    // instruction_t / issue_packet_t: widened to 32 bits total to make room
    // for accum_ctrl. Layout is byte-aligned:
    //   [31:28] opcode  [27:26] src  [25:24] dst  (byte 0)
    //   [23:16] addr                              (byte 1)
    //   [15:8]  length                             (byte 2)
    //   [7:6]   accum_ctrl  [5:0] reserved         (byte 3)
    typedef struct packed {
        opcode_t       opcode;
        logic [1:0]    src;
        logic [1:0]    dst;
        logic [7:0]    addr;
        logic [7:0]    length;
        accum_ctrl_t   accum_ctrl;
        logic [5:0]    reserved;
    } instruction_t;

    typedef struct packed {
        logic          valid;
        opcode_t       opcode;
        logic [1:0]    src;
        logic [1:0]    dst;
        logic [7:0]    addr;
        logic [7:0]    length;
        accum_ctrl_t   accum_ctrl;
        logic [5:0]    reserved;
    } issue_packet_t;

    typedef enum logic [3:0] {
        FLAG_IDLE = 4'd0,
        FLAG_RD_WEIGHT = 4'd1,     // also covers bias loads — see summary note
        FLAG_RD_DATA = 4'd2,
        FLAG_ARRAY = 4'd4,
        FLAG_DMA_WR = 4'd8
    } fsm_state_t;


    ///////////////////////////////////////////////////////////////////////////////
    // Scoreboard
    ///////////////////////////////////////////////////////////////////////////////

    buffer_state_t act_buf_state[2];
    buffer_state_t out_buf_state[2];
    buffer_state_t wgt_buf_state;
    buffer_state_t accum_buf_state;   // NEW — single-banked accumulation buffer
    buffer_state_t bias_buf_state;    // NEW — single-banked, persistent bias buffer

    engine_state_t dma_rd_state;
    engine_state_t dma_wr_state;
    engine_state_t array_state;
    engine_state_t vector_state;
    engine_state_t accel_state;

    logic          dma_rd_target_buf;      // which act_buf bank a DMA read targets
    dma_rd_target_t dma_rd_target;         // NEW — replaces dma_rd_is_weight (act/weight/bias)
    logic          dma_wr_source_buf;
    logic          array_input_buf;
    accum_ctrl_t   array_accum_ctrl;       // NEW — accum_ctrl latched at OP_MATMUL issue, used at array_done
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

    // NEW — mirrors can_issue_load_wgt. Bias buffer is single-banked and
    // persistent (see scoreboard-update comments), so — like the weight
    // buffer — this only fires while it's still EMPTY (i.e. before its first
    // load). Reloading a previously-loaded bias buffer shares the same
    // known limitation OP_LOAD_WGT already has today; not addressed here
    // per the "don't fix scheduling bugs yet" scope.
    function automatic logic can_issue_load_bias;
        return
            dma_rd_state == ENG_IDLE &&
            bias_buf_state == BUF_EMPTY;
    endfunction

    // UPDATED — OP_MATMUL no longer targets out_buf; it targets the
    // accumulation buffer. Which accum state is required depends on
    // accum_ctrl: INIT/NONE start a fresh tile (must be EMPTY), ADD/LAST
    // continue an in-progress reduction group (must be FILLING).
    function automatic logic can_issue_matmul(
        input logic [1:0]      src,
        input accum_ctrl_t     actrl
    );
        logic accum_ok;
        accum_ok = (actrl == ACC_NONE || actrl == ACC_INIT) ?
                        (accum_buf_state == BUF_EMPTY) :
                        (accum_buf_state == BUF_FILLING);
        return
            array_state == ENG_IDLE &&
            wgt_buf_state == BUF_READY &&
            act_buf_state[src] == BUF_READY &&
            accum_ok;
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

    // UPDATED — OP_VECTOR now sources from accum_buffer (must be READY, i.e.
    // the reduction group's last tile has landed) and bias_buffer (must be
    // READY, i.e. loaded at least once), and still writes out_buf[dst].
    function automatic logic can_issue_vector(
        input logic [1:0] dst
    );
        return
            vector_state == ENG_IDLE &&
            accum_buf_state == BUF_READY &&
            bias_buf_state == BUF_READY &&
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

        accum_wr_en   = 1'b0;
        accum_wr_init = 1'b0;
        accum_wr_addr = '0;
        accum_rd_en   = 1'b0;
        accum_rd_addr = '0;

        bias_wr_en   = 1'b0;
        bias_wr_addr = '0;
        bias_rd_en   = 1'b0;

        vector_in_valid = 1'b0;

        array_en = 1'b0;
        array_clear_acc = 1'b0;
        array_weight_load = 1'b0;

        dma_rd_start = 1'b0;
        dma_rd_addr  = '0;
        dma_rd_len   = '0;
        dma_wr_start = 1'b0;
        dma_wr_addr  = '0;
        dma_wr_len   = '0;

        // NOTE: bias loads are folded into loading_weights (not activations)
        // since the external fsm_state status register is only 4 bits wide
        // with all 4 bits already spoken for (see fsm_state assembly below);
        // adding a distinct FLAG_RD_BIAS was out of scope for a minimal
        // change. Bias and weight loads are mutually exclusive in time
        // anyway (both go through the single DMA read engine).
        loading_weights = (dma_rd_state == ENG_BUSY && dma_rd_target != DMA_TGT_ACT) ||
            (wgt_buf_state == BUF_FILLING) || (bias_buf_state == BUF_FILLING);
        streaming_acts = (dma_rd_state == ENG_BUSY && dma_rd_target == DMA_TGT_ACT) ||
            (array_state == ENG_BUSY);

        for(i = 0; i < INSTR_WINDOW_SIZE; i = i + 1) begin
            decoded_window[i] = instruction_t'(fifo_window[i]);
        end

        if (accel_state == ENG_BUSY) begin
            // Scan the instruction window and select the first ready instruction.
            for(i = 0; i < INSTR_WINDOW_SIZE; i = i + 1) begin
                current_inst = decoded_window[i];

                if(!already_selected) begin
                    unique case(current_inst.opcode)

                        OP_NOP: begin
                            issue_packet.valid  = 1'b1;
                            issue_packet.opcode = current_inst.opcode;
                            issue_packet.src    = current_inst.src;
                            issue_packet.dst    = current_inst.dst;
                            issue_packet.addr   = current_inst.addr;
                            issue_packet.length = current_inst.length;
                            issue_packet.accum_ctrl = current_inst.accum_ctrl;
                            issue_valid         = 1'b1;
                            issue_index         = i;
                            already_selected    = 1'b1;
                        end

                        OP_LOAD_WGT:
                            if(can_issue_load_wgt()) begin
                                issue_packet.valid  = 1'b1;
                                issue_packet.opcode = current_inst.opcode;
                                issue_packet.src    = current_inst.src;
                                issue_packet.dst    = current_inst.dst;
                                issue_packet.addr   = current_inst.addr;
                                issue_packet.length = current_inst.length;
                                issue_packet.accum_ctrl = current_inst.accum_ctrl;
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
                                issue_packet.accum_ctrl = current_inst.accum_ctrl;
                                issue_valid = 1'b1;
                                issue_index = i;
                                already_selected = 1'b1;
                            end

                        OP_LOAD_BIAS:  // NEW
                            if(can_issue_load_bias()) begin
                                issue_packet.valid  = 1'b1;
                                issue_packet.opcode = current_inst.opcode;
                                issue_packet.src    = current_inst.src;
                                issue_packet.dst    = current_inst.dst;
                                issue_packet.addr   = current_inst.addr;
                                issue_packet.length = current_inst.length;
                                issue_packet.accum_ctrl = current_inst.accum_ctrl;
                                issue_valid = 1'b1;
                                issue_index = i;
                                already_selected = 1'b1;
                            end

                        OP_MATMUL:
                            if(can_issue_matmul(current_inst.src, current_inst.accum_ctrl)) begin
                                issue_packet.valid  = 1'b1;
                                issue_packet.opcode = current_inst.opcode;
                                issue_packet.src    = current_inst.src;
                                issue_packet.dst    = current_inst.dst;
                                issue_packet.addr   = current_inst.addr;
                                issue_packet.length = current_inst.length;
                                issue_packet.accum_ctrl = current_inst.accum_ctrl;
                                issue_valid = 1'b1;
                                issue_index = i;
                                already_selected = 1'b1;
                            end

                        OP_VECTOR:
                            if(can_issue_vector(current_inst.dst)) begin
                                issue_packet.valid  = 1'b1;
                                issue_packet.opcode = current_inst.opcode;
                                issue_packet.src    = current_inst.src;
                                issue_packet.dst    = current_inst.dst;
                                issue_packet.addr   = current_inst.addr;
                                issue_packet.length = current_inst.length;
                                issue_packet.accum_ctrl = current_inst.accum_ctrl;
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
                                issue_packet.accum_ctrl = current_inst.accum_ctrl;
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
                                issue_packet.accum_ctrl = current_inst.accum_ctrl;
                                issue_valid = 1'b1;
                                issue_index = i;
                                already_selected = 1'b1;
                            end

                        OP_END: begin
                            if (i == 0 && (dma_rd_state == ENG_IDLE) && (dma_wr_state == ENG_IDLE) && (array_state == ENG_IDLE) && (vector_state == ENG_IDLE)) begin
                                issue_packet.valid  = 1'b1;
                                issue_packet.opcode = current_inst.opcode;
                                issue_packet.src    = current_inst.src;
                                issue_packet.dst    = current_inst.dst;
                                issue_packet.addr   = current_inst.addr;
                                issue_packet.length = current_inst.length;
                                issue_packet.accum_ctrl = current_inst.accum_ctrl;
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
        end

        fifo_pop_en  = issue_valid;
        fifo_pop_idx = issue_index;

        // Dispatch block: convert the selected issue packet into engine pulses.
        if(issue_packet.valid) begin
            unique case(issue_packet.opcode)
                OP_NOP: begin
                    // Do nothing; NOP is always ready to issue.
                end

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

                OP_LOAD_BIAS: begin   // NEW — mirrors OP_LOAD_WGT
                    bias_wr_en   = 1'b1;
                    bias_wr_addr = issue_packet.addr[BIAS_AW-1:0];

                    dma_rd_start = 1'b1;
                    // TODO: confirm address math once axi4_lite_slave.sv exposes
                    // a real bias_addr register (UNKNOWN — see summary).
                    dma_rd_addr  = bias_addr + (ADDR_WIDTH'(issue_packet.addr) << $clog2(32/8));
                    dma_rd_len   = issue_packet.length;
                end

                OP_MATMUL: begin
                    wt_rd_en          = 1'b1;
                    wt_rd_buf         = 1'b0;
                    act_rd_en         = 1'b1;
                    act_rd_addr       = issue_packet.addr[ACT_AW-1:0];
                    act_rd_buf        = issue_packet.src[0];
                    array_en          = 1'b1;
                    array_clear_acc   = 1'b1;   // internal PE accumulator reset for THIS pass;
                                                 // unrelated to the external accum buffer below

                    // NEW — drive the accumulation-buffer write for this tile.
                    // wr_init overwrites the row; otherwise it's summed into the
                    // existing partial sum (see accum_ctrl_t comment).
                    // ASSUMPTION (unverified — systolic_array.sv not provided):
                    // one MATMUL issue corresponds to one accum-buffer row, and
                    // the row index equals the same act-tile row index used for
                    // act_rd_addr above. If the systolic array instead drains a
                    // full tile (multiple rows) per MATMUL, accum_wr_addr will
                    // need its own per-row beat counter — same class of TODO as
                    // the wt/act/out multi-beat streaming note below.
                    accum_wr_en   = 1'b1;
                    accum_wr_init = (issue_packet.accum_ctrl == ACC_NONE) ||
                                    (issue_packet.accum_ctrl == ACC_INIT);
                    accum_wr_addr = issue_packet.addr[ACCUM_AW-1:0];
                end

                OP_VECTOR: begin
                    // NEW — source the vector unit from the accumulation buffer
                    // and bias buffer instead of the (nonexistent) out_buf read
                    // path the old code referenced.
                    accum_rd_en   = 1'b1;
                    accum_rd_addr = issue_packet.addr[ACCUM_AW-1:0]; // same row-index assumption as OP_MATMUL above
                    bias_rd_en    = 1'b1;
                    // TODO: accum_buffer/bias_buffer reads are 1-cycle
                    // registered (see bram_accum_buffer.sv / bram_bias_buffer.sv),
                    // so vector_in_valid firing the same cycle as accum_rd_en/
                    // bias_rd_en is almost certainly off by one cycle relative
                    // to when accum_rd_data/bias_data actually land. Left as a
                    // same-cycle stub, to be pipelined correctly during the
                    // control-unit timing/debug pass (out of scope here).
                    vector_in_valid = 1'b1;

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

                OP_SWAP_WGT: begin
                    array_weight_load = 1'b1;
                end

                default: begin
                end

            endcase
        end

        fsm_state = FLAG_IDLE;
        // NOTE: bias loads (DMA_TGT_BIAS) intentionally report as FLAG_RD_WEIGHT
        // rather than getting a dedicated flag — see loading_weights comment above.
        if(dma_rd_state != ENG_IDLE && dma_rd_target != DMA_TGT_ACT) begin
            fsm_state = fsm_state | FLAG_RD_WEIGHT;
        end
        if (dma_rd_state != ENG_IDLE && dma_rd_target == DMA_TGT_ACT) begin
            fsm_state = fsm_state | FLAG_RD_DATA;
        end
        if(array_state == ENG_BUSY) begin
            fsm_state = fsm_state | FLAG_ARRAY;
        end
        if(dma_wr_state == ENG_BUSY) begin
            fsm_state = fsm_state | FLAG_DMA_WR;
        end


        busy = start_pulse ||
            (dma_rd_state == ENG_BUSY) ||
            (dma_wr_state == ENG_BUSY) ||
            (array_state == ENG_BUSY) ||
            (vector_state == ENG_BUSY) ||
            issue_packet.valid;

        done = (issue_packet.valid && issue_packet.opcode == OP_END);
    end

    // TODO -- MULTI-BEAT BRAM STREAMING (hand-tune against axi4_master timing)
    // ---------------------------------------------------------------------
    // OP_LOAD_WGT currently only pulses wt_wr_en/wt_wr_addr for ONE row on the
    // cycle it's issued. A full weight tile is ARRAY_SIZE rows, arriving over
    // ARRAY_SIZE (or more, depending on DMA_WIDTH vs DATA_WIDTH*ARRAY_SIZE)
    // beats of master_rd_data_valid from axi4_master. Same issue for
    // OP_LOAD_ACT (num_acts beats), OP_LOAD_BIAS (bias chunk beats), OP_STORE
    // (draining out_buf), and — NEW — OP_MATMUL's accum_wr_addr / OP_VECTOR's
    // accum_rd_addr, which today likewise only pulse a single row per issue
    // (see the ASSUMPTION note on OP_MATMUL/OP_VECTOR dispatch above).
    //
    // Skeleton for what's needed here:
    //
    //   logic [BANK_W:0] wt_beat_cnt;
    //   always_ff @(posedge clk) begin
    //     if(!rst_n) wt_beat_cnt <= '0;
    //     else if(issue_packet.valid && issue_packet.opcode == OP_LOAD_WGT)
    //       wt_beat_cnt <= '0;
    //     else if(dma_rd_state == ENG_BUSY && dma_rd_target == DMA_TGT_WEIGHT && master_rd_data_valid)
    //       wt_beat_cnt <= wt_beat_cnt + 1'b1;
    //   end
    //   // then drive wt_wr_en/wt_wr_addr off (dma_rd_target==DMA_TGT_WEIGHT && master_rd_data_valid)
    //   // instead of only off issue_packet.valid, indexing wt_wr_addr by wt_beat_cnt.
    //
    // This needs master_rd_data_valid piped into control_unit (new input port)
    // and equivalent counters/muxes for act_wr_addr (indexed by num_acts),
    // bias_wr_addr (indexed by bias chunk count), out_rd_addr (indexed by
    // store length), and accum_wr_addr/accum_rd_addr (indexed by array drain
    // row / vector-unit row). Left unimplemented since it depends on
    // axi4_master's and systolic_array's exact beat-valid timing, neither of
    // which I have full visibility into yet.


    ///////////////////////////////////////////////////////////////////////////////
    // Scoreboard update
    ///////////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk) begin

        if(!rst_n || soft_reset) begin

            act_buf_state[0] <= BUF_EMPTY;
            act_buf_state[1] <= BUF_EMPTY;

            out_buf_state[0] <= BUF_EMPTY;
            out_buf_state[1] <= BUF_EMPTY;

            wgt_buf_state   <= BUF_EMPTY;
            accum_buf_state <= BUF_EMPTY;   // NEW
            bias_buf_state  <= BUF_EMPTY;   // NEW

            dma_rd_state <= ENG_IDLE;
            dma_wr_state <= ENG_IDLE;
            array_state  <= ENG_IDLE;
            vector_state <= ENG_IDLE;
            accel_state  <= ENG_IDLE;

            dma_rd_target_buf <= 1'b0;
            dma_rd_target     <= DMA_TGT_ACT;  // NEW — replaces dma_rd_is_weight
            dma_wr_source_buf <= 1'b0;
            array_input_buf   <= 1'b0;
            array_accum_ctrl  <= ACC_NONE;     // NEW
            vector_output_buf <= 1'b0;

        end

        else begin

            if (start_pulse) begin
                accel_state <= ENG_BUSY;
            end
            else if (done) begin
                accel_state <= ENG_IDLE; // Return to IDLE on completion
            end

        if(issue_packet.valid) begin

            unique case(issue_packet.opcode)

                OP_LOAD_WGT: begin
                    dma_rd_state   <= ENG_BUSY;
                    dma_rd_target  <= DMA_TGT_WEIGHT;
                    wgt_buf_state  <= BUF_FILLING;
                end

                OP_LOAD_ACT: begin
                    dma_rd_state      <= ENG_BUSY;
                    dma_rd_target     <= DMA_TGT_ACT;
                    dma_rd_target_buf <= issue_packet.dst[0];
                    act_buf_state[issue_packet.dst] <= BUF_FILLING;
                end

                OP_LOAD_BIAS: begin   // NEW — mirrors OP_LOAD_WGT
                    dma_rd_state   <= ENG_BUSY;
                    dma_rd_target  <= DMA_TGT_BIAS;
                    bias_buf_state <= BUF_FILLING;
                end

                OP_MATMUL: begin
                    array_state      <= ENG_BUSY;
                    array_input_buf  <= issue_packet.src[0];
                    array_accum_ctrl <= issue_packet.accum_ctrl;  // NEW — latched for use at array_done

                    act_buf_state[issue_packet.src] <= BUF_IN_USE;
                    accum_buf_state  <= BUF_FILLING;              // NEW — busy being written; see array_done below
                end

                OP_VECTOR: begin
                    vector_state      <= ENG_BUSY;
                    vector_output_buf <= issue_packet.dst[0];

                    accum_buf_state  <= BUF_IN_USE;   // NEW — being drained by the vector unit
                    // bias_buf_state intentionally left untouched: bias is a
                    // persistent resource, reused across many OP_VECTOR issues
                    // until explicitly reloaded via a fresh OP_LOAD_BIAS.
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
                unique case (dma_rd_target)
                    DMA_TGT_WEIGHT: wgt_buf_state  <= BUF_READY;
                    DMA_TGT_BIAS:   bias_buf_state <= BUF_READY;   // NEW
                    default:        act_buf_state[dma_rd_target_buf] <= BUF_READY;
                endcase
            end

            if(array_done) begin
                array_state <= ENG_IDLE;
                act_buf_state[array_input_buf] <= BUF_EMPTY;

                // NEW — accum buffer state depends on whether this MATMUL was
                // the last tile of a reduction group (or a single-pass op).
                if (array_accum_ctrl == ACC_NONE || array_accum_ctrl == ACC_LAST) begin
                    accum_buf_state <= BUF_READY;   // ready for OP_VECTOR to consume
                end
                else begin
                    accum_buf_state <= BUF_FILLING; // more tiles expected (INIT/ADD)
                end
            end

            if(dma_wr_done) begin
                dma_wr_state <= ENG_IDLE;
                out_buf_state[dma_wr_source_buf] <= BUF_EMPTY;
            end

            if(vector_done) begin
                vector_state <= ENG_IDLE;
                accum_buf_state <= BUF_EMPTY;    // NEW — tile consumed, ready for next reduction group
                out_buf_state[vector_output_buf] <= BUF_READY;
            end

        end

    end

endmodule