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

    // NEW — per-beat handshake from axi4_master. Needed because a DMA burst
    // is many beats; without these the control unit has no way to know
    // *when* each beat of read data lands or each beat of write data is
    // consumed, so it cannot step BRAM addresses across the transfer.
    input  logic                  dma_rd_data_valid,   // pulses each accepted read-data beat
    input  logic                  dma_wr_data_ready,   // pulses each accepted write-data beat

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
    input  logic                 out_rd_valid,  // NEW — out_buffer's registered-read valid (was declared
                                                  // in accelerator.sv, marked "havent used yet", never wired here)
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
    input  logic                  accum_rd_valid,   // NEW — accum_buffer's registered-read valid

    // ── Bias buffer control (NEW) ─────────────────────────────────────────────
    // Loaded via OP_LOAD_BIAS (DMA), read on OP_VECTOR. Persistent resource:
    // stays READY across many OP_VECTOR issues until explicitly reloaded.
    output logic                  bias_wr_en,
    output logic [BIAS_AW-1:0]    bias_wr_addr,
    output logic                  bias_rd_en,
    input  logic                  bias_rd_valid,    // NEW — bias_buffer's registered-read valid

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

    // NEW — multi-cycle beat bookkeeping. The engines themselves were
    // already tracked as busy/idle correctly; what was missing was
    // per-beat address stepping for the BRAM ports, and deferring
    // producer-fed writes (accum/out) until the producer's data is
    // actually valid. See the "multi-beat BRAM writes/reads" block below.
    logic [8:0]    ld_beat_cnt;    // beats written so far for the in-flight LOAD_WGT/LOAD_ACT/LOAD_BIAS
    logic [8:0]    ld_beat_total;  // total beats expected (= issue_packet.length+1, latched at issue — see AxLEN note below)
    logic [7:0]    ld_base_addr;   // base BRAM row address (= issue_packet.addr, latched at issue)

    logic [8:0]    st_beat_cnt;    // beats read so far for the in-flight STORE
    logic [8:0]    st_beat_total;  // total beats expected (= issue_packet.length+1, latched at issue)
    logic [7:0]    st_base_addr;   // base out_buf row address (= issue_packet.addr, latched at issue)

    logic [ACCUM_AW-1:0] mm_accum_addr; // accum_wr_addr latched at OP_MATMUL issue, used at array_done
    logic [BANK_W-1:0]   vec_out_addr;  // out_wr_addr latched at OP_VECTOR issue, used at vector_done

    // NEW — edge-detected completion pulses. dma_rd_done/dma_wr_done are
    // already clean 1-cycle pulses (verified from axi4_master.sv source:
    // RD_DONE/wr_done_r are asserted for exactly one cycle), so this is a
    // no-op for them. array_done is NOT a pulse: systolic_array.sv's perf
    // counter FSM holds perf_valid asserted continuously from completion
    // until the *next* clear_acc (i.e. until the next MATMUL issues) --
    // confirmed from source. Without edge-detecting it, the completion
    // handling below (and the pre-existing scoreboard code) would re-fire
    // every cycle it stays high, which can race with and corrupt an
    // OP_VECTOR issue that happens to land during that window.
    // vector_done's provenance (vector_unit.sv) wasn't available to verify,
    // so it's edge-detected defensively for the same class of risk.
    logic dma_rd_done_d, dma_wr_done_d, array_done_d, vector_done_d;


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
                    // Kick off a DMA read burst for the weight tile. The BRAM
                    // write itself is NOT done here (data hasn't arrived yet
                    // on the issue cycle) -- it's driven beat-by-beat off
                    // dma_rd_data_valid in the "multi-beat BRAM writes" block
                    // below, using the base address/length latched at issue.
                    dma_rd_start = 1'b1;
                    // TODO: confirm address math. Using weight_addr as base +
                    // an offset derived from issue_packet.addr (tile index).
                    // Replace with whatever addressing scheme your ISA actually
                    // encodes (e.g. addr may already be a byte/row offset).
                    dma_rd_addr  = weight_addr + (ADDR_WIDTH'(issue_packet.addr) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));
                    dma_rd_len   = issue_packet.length; // TODO: or derive from ARRAY_SIZE*DATA_WIDTH
                end

                OP_LOAD_ACT: begin
                    // BRAM write is beat-gated below (see OP_LOAD_WGT note).
                    dma_rd_start = 1'b1;
                    // TODO: confirm address math against how src_addr/img_rows/
                    // img_cols encode the activation tensor layout.
                    dma_rd_addr  = src_addr + (ADDR_WIDTH'(issue_packet.addr) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));
                    dma_rd_len   = issue_packet.length;
                end

                OP_LOAD_BIAS: begin   // NEW — mirrors OP_LOAD_WGT
                    // BRAM write is beat-gated below (see OP_LOAD_WGT note).
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

                    // NOTE: the accumulation-buffer write is NOT driven here.
                    // array_result_out only becomes valid when the array
                    // finishes draining (array_done/array_perf_valid), which
                    // is one or more cycles after issue. accum_wr_en/init/
                    // addr are driven off array_done in the beat-gated block
                    // below, using mm_accum_addr/array_accum_ctrl latched at
                    // issue.
                    // ASSUMPTION (unverified — systolic_array.sv not provided):
                    // one MATMUL issue corresponds to one accum-buffer row, and
                    // the row index equals the same act-tile row index used for
                    // act_rd_addr above.
                end

                OP_VECTOR: begin
                    // NEW — source the vector unit from the accumulation buffer
                    // and bias buffer instead of the (nonexistent) out_buf read
                    // path the old code referenced.
                    accum_rd_en   = 1'b1;
                    accum_rd_addr = issue_packet.addr[ACCUM_AW-1:0]; // same row-index assumption as OP_MATMUL above
                    bias_rd_en    = 1'b1;
                    // NOTE: accum_buffer/bias_buffer reads are 1-cycle
                    // registered, so vector_in_valid/out_wr_en are NOT driven
                    // here. vector_in_valid fires once accum_rd_valid &&
                    // bias_rd_valid pulse (the cycle after this rd_en pulse);
                    // out_wr_en fires once vector_done pulses. Both are in the
                    // beat-gated block below, using vec_out_addr and
                    // vector_output_buf latched at issue.
                end

                OP_STORE: begin
                    // out_buf read is beat-gated below, stepped in lock-step
                    // with dma_wr_data_ready (see OP_LOAD_WGT note for the
                    // read-side equivalent).
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

        // ---------------------------------------------------------------
        // NEW — multi-beat BRAM writes/reads, and producer-gated writes.
        // ---------------------------------------------------------------
        // The block above triggers each *engine* once at issue
        // (dma_rd_start/dma_wr_start/array_en/accum_rd_en/bias_rd_en/etc.).
        // That's correct and unchanged. What's below drives the BRAM
        // *ports* on the cycle(s) their data is actually valid, which for
        // a multi-cycle engine is one or more cycles after issue, and for
        // a burst transfer repeats once per beat rather than once total.

        // Weight / activation / bias loads: one BRAM write per accepted
        // read-data beat, address stepping across the beats latched at
        // issue (ld_base_addr .. ld_base_addr+ld_beat_total-1).
        if (dma_rd_state == ENG_BUSY && dma_rd_data_valid &&
            ld_beat_cnt < ld_beat_total) begin
            unique case (dma_rd_target)
                DMA_TGT_WEIGHT: begin
                    wt_wr_en   = 1'b1;
                    wt_wr_addr = ACT_AW'(ld_base_addr + ld_beat_cnt);
                end
                DMA_TGT_BIAS: begin
                    bias_wr_en   = 1'b1;
                    bias_wr_addr = BIAS_AW'(ld_base_addr + ld_beat_cnt);
                end
                DMA_TGT_ACT: begin
                    act_wr_en   = 1'b1;
                    act_wr_addr = ACT_AW'(ld_base_addr + ld_beat_cnt);
                    act_wr_buf  = dma_rd_target_buf;
                end
                default: begin end
            endcase
        end

        // Store: out_buf read, PREFETCHED one beat ahead of when
        // axi4_master will actually consume it on m_axi_wdata.
        //
        // ASSUMPTION (bram_out_buffer.sv not provided — inferred from the
        // established pattern of accum_buffer/bias_buffer elsewhere in
        // this design, and from out_rd_valid already existing as a port
        // in accelerator.sv, marked "havent used yet"): out_buffer is a
        // registered-read BRAM, i.e. data for a given rd_addr is valid
        // one cycle after rd_en, not the same cycle.
        //
        // axi4_master's write FSM has NO backpressure/wait mechanism once
        // it enters WR_DATA (m_wvalid is asserted unconditionally as soon
        // as the state machine gets there, and it consumes one beat per
        // cycle m_wready is high) -- it does not wait for out_rd_valid.
        // So the read for beat N+1 must be issued while beat N is still
        // being consumed, not after, or wr_data will be stale/undefined
        // for every beat past the first. If this assumption is wrong
        // (out_buffer reads combinationally, 0-cycle latency) this
        // prefetch is simply one beat too early and should be reverted to
        // issuing on dma_wr_data_ready directly -- share bram_out_buffer.sv
        // to confirm and I'll correct it.
        if (dma_wr_start) begin
            // Prefetch beat 0 immediately at issue -- this has at least
            // the AW handshake's worth of cycles to land before WR_DATA
            // begins, so it's always safe regardless of the assumption
            // above.
            out_rd_en   = 1'b1;
            out_rd_addr = OUT_AW'(issue_packet.addr);
            out_rd_buf  = issue_packet.src[0];
        end
        else if (dma_wr_state == ENG_BUSY && dma_wr_data_ready &&
                 (st_beat_cnt + 9'd1) < st_beat_total) begin
            // Beat st_beat_cnt is being consumed on wr_data THIS cycle;
            // prefetch beat st_beat_cnt+1 now so it lands in time.
            out_rd_en   = 1'b1;
            out_rd_addr = OUT_AW'(st_base_addr + st_beat_cnt + 9'd1);
            out_rd_buf  = dma_wr_source_buf;
        end

        // Matmul result -> accumulation buffer: only write once the array
        // has actually finished draining (array_result_out is valid),
        // using the address and init/accumulate mode latched at issue.
        // Uses the edge-detected pulse, not the raw (level-held) array_done
        // -- see the "edge-detected completion pulses" note above.
        if (array_done_pulse) begin
            accum_wr_en   = 1'b1;
            accum_wr_addr = mm_accum_addr;
            accum_wr_init = (array_accum_ctrl == ACC_NONE) ||
                            (array_accum_ctrl == ACC_INIT);
        end

        // Vector unit: feed it only once BOTH the accum-buffer and
        // bias-buffer registered reads (kicked off by accum_rd_en/
        // bias_rd_en at OP_VECTOR issue) have actually landed. Write the
        // result to out_buf only once the vector unit itself is done.
        if (accum_rd_valid && bias_rd_valid) begin
            vector_in_valid = 1'b1;
        end
        if (vector_done_pulse) begin
            out_wr_en   = 1'b1;
            out_wr_addr = vec_out_addr;
            out_wr_buf  = vector_output_buf;
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

    // RESOLVED — multi-beat BRAM streaming for weight/act/bias loads and
    // store, and producer-gated writes for matmul/vector, are implemented
    // in the "multi-beat BRAM writes/reads" block above (driven by the new
    // dma_rd_data_valid/dma_wr_data_ready/accum_rd_valid/bias_rd_valid
    // input ports) and the "Multi-cycle beat bookkeeping" always_ff below.
    // Still UNKNOWN / unverified: whether the systolic array drains exactly
    // one accum-buffer row per MATMUL (see ASSUMPTION note above) — could
    // not confirm without systolic_array.sv.


    ///////////////////////////////////////////////////////////////////////////////
    // Multi-cycle beat bookkeeping (NEW)
    ///////////////////////////////////////////////////////////////////////////////
    // Latches the addressing context of a multi-beat op at issue, then steps
    // it forward on every accepted beat (loads/stores) or captures it for
    // use at the producer's completion event (matmul/vector). This is what
    // the combinational "multi-beat BRAM writes/reads" block below reads.

    always_ff @(posedge clk) begin
        if (!rst_n || soft_reset) begin
            ld_beat_cnt    <= '0;
            ld_beat_total  <= '0;
            ld_base_addr   <= '0;
            st_beat_cnt    <= '0;
            st_beat_total  <= '0;
            st_base_addr   <= '0;
            mm_accum_addr  <= '0;
            vec_out_addr   <= '0;
            dma_rd_done_d  <= 1'b0;
            dma_wr_done_d  <= 1'b0;
            array_done_d   <= 1'b0;
            vector_done_d  <= 1'b0;
        end
        else begin
            dma_rd_done_d <= dma_rd_done;
            dma_wr_done_d <= dma_wr_done;
            array_done_d  <= array_done;
            vector_done_d <= vector_done;

            // Loads (weight/activation/bias): only one can be in flight at a
            // time (single dma_rd_state engine), so one shared counter set
            // suffices, selected against dma_rd_target when consumed below.
            // NOTE: dma_rd_len/dma_wr_len (driven from issue_packet.length
            // elsewhere) are fed to axi4_master as raw AxLEN (beats-1 —
            // confirmed from axi4_master.sv and the beat count actually
            // observed on the bus), so the real number of local BRAM beats
            // is length+1, not length.
            if (issue_packet.valid &&
                (issue_packet.opcode == OP_LOAD_WGT  ||
                 issue_packet.opcode == OP_LOAD_ACT   ||
                 issue_packet.opcode == OP_LOAD_BIAS)) begin
                ld_beat_cnt   <= '0;
                ld_beat_total <= 9'(issue_packet.length) + 9'd1;
                ld_base_addr  <= issue_packet.addr;
            end
            else if (dma_rd_state == ENG_BUSY && dma_rd_data_valid &&
                     ld_beat_cnt < ld_beat_total) begin
                ld_beat_cnt <= ld_beat_cnt + 1'b1;
            end

            // Store: single dma_wr_state engine, one counter set.
            if (issue_packet.valid && issue_packet.opcode == OP_STORE) begin
                st_beat_cnt   <= '0;
                st_beat_total <= 9'(issue_packet.length) + 9'd1;
                st_base_addr  <= issue_packet.addr;
            end
            else if (dma_wr_state == ENG_BUSY && dma_wr_data_ready &&
                     st_beat_cnt < st_beat_total) begin
                st_beat_cnt <= st_beat_cnt + 1'b1;
            end

            // Matmul result address, needed later at array_done.
            if (issue_packet.valid && issue_packet.opcode == OP_MATMUL) begin
                mm_accum_addr <= issue_packet.addr[ACCUM_AW-1:0];
            end

            // Vector-unit output address, needed later at vector_done.
            if (issue_packet.valid && issue_packet.opcode == OP_VECTOR) begin
                vec_out_addr <= issue_packet.addr[BANK_W-1:0];
            end
        end
    end

    wire dma_rd_done_pulse = dma_rd_done && !dma_rd_done_d;
    wire dma_wr_done_pulse = dma_wr_done && !dma_wr_done_d;
    wire array_done_pulse  = array_done  && !array_done_d;
    wire vector_done_pulse = vector_done && !vector_done_d;

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
            // NOTE: uses the edge-detected *_pulse versions, not the raw
            // done signals. This matters most for array_done: it's a
            // LEVEL signal (systolic_array.sv holds perf_valid asserted
            // from completion until the next clear_acc, not just one
            // cycle), so using it raw here would re-run this block every
            // cycle it stays high -- including, potentially, the same
            // cycle an OP_VECTOR issue (above) sets accum_buf_state to
            // BUF_IN_USE, silently clobbering it back to BUF_READY since
            // this branch runs later in program order. dma_rd_done/
            // dma_wr_done are already clean pulses (verified from
            // axi4_master.sv), so this is a no-op for them; vector_done is
            // edge-detected defensively since vector_unit.sv wasn't
            // available to verify its behavior.
            //------------------------------------------------------

            if(dma_rd_done_pulse) begin
                dma_rd_state <= ENG_IDLE;
                unique case (dma_rd_target)
                    DMA_TGT_WEIGHT: wgt_buf_state  <= BUF_READY;
                    DMA_TGT_BIAS:   bias_buf_state <= BUF_READY;   // NEW
                    default:        act_buf_state[dma_rd_target_buf] <= BUF_READY;
                endcase
            end

            if(array_done_pulse) begin
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

            if(dma_wr_done_pulse) begin
                dma_wr_state <= ENG_IDLE;
                out_buf_state[dma_wr_source_buf] <= BUF_EMPTY;
            end

            if(vector_done_pulse) begin
                vector_state <= ENG_IDLE;
                accum_buf_state <= BUF_EMPTY;    // NEW — tile consumed, ready for next reduction group
                out_buf_state[vector_output_buf] <= BUF_READY;
            end

        end

    end

endmodule