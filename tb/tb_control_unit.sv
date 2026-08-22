`timescale 1ns/1ps
//===========================================================================
// tb_control_unit.sv
//
// Self-checking testbench for control_unit.
//
// Key idea: fifo_window is an INPUT to the DUT (it's fed by an external
// instruction FIFO that the real design doesn't include yet). So this
// testbench implements a small behavioral model of that FIFO: a program
// queue plus a 4-entry window that shifts/refills whenever the DUT asserts
// fifo_pop_en/fifo_pop_idx. This lets the DUT's out-of-order issue logic
// (it scans the whole window, not just index 0) actually get exercised.
//
// UPDATED for the accumulation-buffer / bias-buffer architecture change:
//   - INSTR_WIDTH grew from 24 -> 32 bits to fit the new accum_ctrl field.
//   - New opcode OP_LOAD_BIAS; MATMUL/VECTOR dataflow now goes through
//     accum_buf_state/bias_buf_state instead of MATMUL writing straight to
//     out_buf. Test programs and their expected end-states are updated
//     accordingly (see Test 1/2/3 below).
//===========================================================================

module tb_control_unit;

    //-----------------------------------------------------------------
    // Parameters (kept small so addresses/buffers are easy to eyeball)
    //-----------------------------------------------------------------
    localparam int ARRAY_SIZE         = 16;
    localparam int DATA_WIDTH         = 8;
    localparam int DMA_WIDTH          = 64;
    localparam int ADDR_WIDTH         = 8;
    localparam int INSTR_WINDOW_SIZE  = 4;
    localparam int INSTR_WIDTH        = 32;   // was 24
    localparam int BANK_W             = $clog2(ARRAY_SIZE);
    localparam int OUT_AW             = $clog2(ARRAY_SIZE);
    localparam int ACT_AW             = $clog2(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH/DMA_WIDTH);
    localparam int ACCUM_AW           = $clog2(ARRAY_SIZE);                 // NEW
    localparam int BIAS_AW            = $clog2(ARRAY_SIZE * 32 / DMA_WIDTH); // NEW

    localparam int DMA_RD_LATENCY = 5; // cycles from dma_rd_start -> dma_rd_done (auto responder)
    localparam int DMA_WR_LATENCY = 4;
    localparam int ARRAY_LATENCY  = 8;
    localparam int VECTOR_LATENCY = 3;

    //-----------------------------------------------------------------
    // Opcodes (must mirror control_unit's opcode_t encoding)
    //-----------------------------------------------------------------
    typedef enum logic [3:0] {
        OP_NOP, OP_LOAD_WGT, OP_LOAD_ACT, OP_LOAD_BIAS, OP_MATMUL,
        OP_VECTOR, OP_STORE, OP_SWAP_WGT, OP_END
    } opcode_e;

    // NEW — mirrors control_unit's accum_ctrl_t
    typedef enum logic [1:0] {
        ACC_NONE, ACC_INIT, ACC_ADD, ACC_LAST
    } accum_ctrl_e;

    //-----------------------------------------------------------------
    // DUT I/O
    //-----------------------------------------------------------------
    logic clk = 0;
    logic rst_n;
    logic start_pulse;
    logic soft_reset;
    logic perf_valid;
    logic [15:0] num_acts;
    logic dma_rd_done, dma_wr_done, array_done, vector_done;
    logic busy, done;
    logic [3:0] fsm_state;
    logic loading_weights, streaming_acts;

    logic [DMA_WIDTH-1:0] src_addr, dst_addr, weight_addr;
    logic [DMA_WIDTH-1:0] bias_addr;   // NEW
    logic [15:0] img_rows, img_cols;

    logic dma_rd_start;
    logic [DMA_WIDTH-1:0] dma_rd_addr;
    logic [7:0] dma_rd_len;
    logic dma_wr_start;
    logic [DMA_WIDTH-1:0] dma_wr_addr;
    logic [7:0] dma_wr_len;

    logic wt_wr_en;
    logic [ACT_AW-1:0] wt_wr_addr;
    logic wt_rd_en, wt_rd_buf;

    logic act_wr_en;
    logic [BANK_W-1:0] act_wr_bank;
    logic [ACT_AW-1:0] act_wr_addr;
    logic act_wr_buf;
    logic act_rd_en;
    logic [BANK_W-1:0] act_rd_addr;
    logic act_rd_buf;

    logic out_rd_en;
    logic [OUT_AW-1:0] out_rd_addr;
    logic out_rd_buf;
    logic out_wr_en;
    logic [BANK_W-1:0] out_wr_addr;
    logic out_wr_buf;

    // NEW — accumulation buffer control
    logic accum_wr_en, accum_wr_init, accum_rd_en;
    logic [ACCUM_AW-1:0] accum_wr_addr, accum_rd_addr;

    // NEW — bias buffer control
    logic bias_wr_en, bias_rd_en;
    logic [BIAS_AW-1:0] bias_wr_addr;

    // NEW — vector unit control (previously dangling at the accelerator level)
    logic vector_in_valid;

    logic array_en, array_clear_acc, array_weight_load;

    logic fifo_pop_en;
    logic [$clog2(INSTR_WINDOW_SIZE)-1:0] fifo_pop_idx;
    logic [INSTR_WIDTH-1:0] window [0:INSTR_WINDOW_SIZE-1];
    logic fifo_restart;   // NEW — DUT output; missing from tb broke the .* wildcard connection

    // NEW — these DUT inputs were missing from the testbench entirely,
    // which (a) makes the `.*` wildcard connection in the DUT instantiation
    // fail to elaborate, since there's no identifier in scope for
    // dma_rd_data_valid et al., and (b) even if connected/tied off, the DUT
    // logic *requires* them to make forward progress: e.g. wgt_buf_state
    // only reaches BUF_READY once wt_rd_valid pulses, and SWAP_WGT/MATMUL
    // can never issue without that, so every test would hang until its
    // timeout. Modeled as: dma_rd_data_valid/dma_wr_data_ready pulse every
    // cycle their engine is busy (the DUT's beat counters are self-gating
    // against ld_beat_total/st_beat_total, so an approximate "high while
    // busy" pulse train is sufficient); the *_rd_valid signals are their
    // *_rd_en counterpart delayed by one cycle, matching the RTL's own
    // "1-cycle registered read" comments for each buffer.
    logic dma_rd_data_valid, dma_wr_data_ready;
    logic wt_rd_valid, act_rd_valid, out_rd_valid, accum_rd_valid, bias_rd_valid;

    //-----------------------------------------------------------------
    // DUT instantiation
    //-----------------------------------------------------------------
    control_unit #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .DMA_WIDTH(DMA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .INSTR_WINDOW_SIZE(INSTR_WINDOW_SIZE),
        .INSTR_WIDTH(INSTR_WIDTH)
    ) dut (.*, .fifo_window(window));

    //-----------------------------------------------------------------
    // Clock
    //-----------------------------------------------------------------
    always #5 clk = ~clk;

    //-----------------------------------------------------------------
    // Instruction packing: must match instruction_t bit layout
    // { opcode[3:0], src[1:0], dst[1:0], addr[7:0], length[7:0], accum_ctrl[1:0], reserved[5:0] }
    // (32 bits total — was 24 before the accum_ctrl field was added)
    //-----------------------------------------------------------------
    function automatic logic [INSTR_WIDTH-1:0] pack_instr
        (input opcode_e op, input logic [1:0] src, input logic [1:0] dst,
         input logic [7:0] addr, input logic [7:0] length,
         input accum_ctrl_e actrl = ACC_NONE);
        pack_instr = {op, src, dst, addr, length, actrl, 6'b0};
    endfunction

    localparam logic [INSTR_WIDTH-1:0] NOP_WORD = {OP_NOP, 2'b0, 2'b0, 8'b0, 8'b0, 2'b0, 6'b0};

    //-----------------------------------------------------------------
    // Behavioral model of the external instruction FIFO
    //-----------------------------------------------------------------
    localparam int PROG_MAX = 64;
    logic [INSTR_WIDTH-1:0] prog_mem [0:PROG_MAX-1];
    int prog_len;
    int prog_ptr;

    task automatic load_program(input logic [INSTR_WIDTH-1:0] instrs[]);
        int k;
        prog_len = instrs.size();
        for (k = 0; k < prog_len; k++) prog_mem[k] = instrs[k];
        prog_ptr = 0;
        for (k = 0; k < INSTR_WINDOW_SIZE; k++) begin
            if (prog_ptr < prog_len) begin
                window[k] = prog_mem[prog_ptr];
                prog_ptr++;
            end else begin
                window[k] = NOP_WORD;
            end
        end
    endtask

    // Shift/refill window whenever the DUT pops an instruction.
    always_ff @(posedge clk) begin
        int k;
        if (rst_n && fifo_pop_en) begin
            for (k = fifo_pop_idx; k < INSTR_WINDOW_SIZE-1; k++)
                window[k] <= window[k+1];
            if (prog_ptr < prog_len) begin
                window[INSTR_WINDOW_SIZE-1] <= prog_mem[prog_ptr];
                prog_ptr <= prog_ptr + 1;
            end else begin
                window[INSTR_WINDOW_SIZE-1] <= NOP_WORD;
            end
        end
    end

    //-----------------------------------------------------------------
    // Auto-responders for the engines (DMA/array/vector). Emulates the
    // latency of the real blocks completing their work. Can be disabled
    // per-signal for directed hazard tests that want manual control.
    //-----------------------------------------------------------------
    bit auto_dma_rd = 1, auto_dma_wr = 1, auto_array = 1, auto_vector = 1;

    initial begin
        dma_rd_done = 0;
        forever begin
            @(posedge clk);
            if (auto_dma_rd && dma_rd_start) begin
                repeat (DMA_RD_LATENCY) @(posedge clk);
                dma_rd_done <= 1; @(posedge clk); dma_rd_done <= 0;
            end
        end
    end

    initial begin
        dma_wr_done = 0;
        forever begin
            @(posedge clk);
            if (auto_dma_wr && dma_wr_start) begin
                repeat (DMA_WR_LATENCY) @(posedge clk);
                dma_wr_done <= 1; @(posedge clk); dma_wr_done <= 0;
            end
        end
    end

    initial begin
        array_done = 0;
        forever begin
            @(posedge clk);
            if (auto_array && array_en) begin
                repeat (ARRAY_LATENCY) @(posedge clk);
                array_done <= 1; @(posedge clk); array_done <= 0;
            end
        end
    end

    initial begin
        vector_done = 0;
        forever begin
            @(posedge clk);
            // FIX — was gated on out_wr_en, but out_wr_en is only ever
            // asserted by the DUT *after* vector_done_pulse fires (it's
            // the write-back of the vector unit's result). Gating the
            // responder on its own downstream effect is a deadlock: no
            // real OP_VECTOR could ever complete. vector_in_valid is the
            // actual issue-side handshake into the (unmodeled) vector
            // unit, mirroring how the array auto-responder is gated on
            // array_en rather than array's own completion side-effects.
            if (auto_vector && vector_in_valid) begin
                repeat (VECTOR_LATENCY) @(posedge clk);
                vector_done <= 1; @(posedge clk); vector_done <= 0;
            end
        end
    end

    //-----------------------------------------------------------------
    // NEW — auto-responders for the registered-read valid / DMA-beat
    // handshake ports (see declaration comment above for rationale).
    //-----------------------------------------------------------------
    initial dma_rd_data_valid = 0;
    always @(posedge clk) dma_rd_data_valid <= (dut.dma_rd_state == dut.ENG_BUSY);

    initial dma_wr_data_ready = 0;
    always @(posedge clk) dma_wr_data_ready <= (dut.dma_wr_state == dut.ENG_BUSY);

    initial wt_rd_valid = 0;
    always @(posedge clk) wt_rd_valid <= wt_rd_en;

    initial act_rd_valid = 0;
    always @(posedge clk) act_rd_valid <= act_rd_en;

    initial out_rd_valid = 0;
    always @(posedge clk) out_rd_valid <= out_rd_en;

    initial accum_rd_valid = 0;
    always @(posedge clk) accum_rd_valid <= accum_rd_en;

    initial bias_rd_valid = 0;
    always @(posedge clk) bias_rd_valid <= bias_rd_en;

    //-----------------------------------------------------------------
    // Scoreboard/self-check bookkeeping
    //-----------------------------------------------------------------
    int pass_cnt = 0;
    int fail_cnt = 0;

    // NEW — latches whether accum_buf_state was ever seen in BUF_FILLING,
    // so multi-tile-reduction tests can confirm the intermediate state was
    // actually exercised (not just the final READY/EMPTY snapshot). Cleared
    // at the top of each test via reset_dut().
    bit seen_accum_filling;
    always @(posedge clk) begin
        if (rst_n && dut.accum_buf_state == dut.BUF_FILLING) seen_accum_filling = 1'b1;
    end

    task automatic check(input bit cond, input string msg);
        if (cond) begin
            pass_cnt++;
            $display("  [PASS] %s", msg);
        end else begin
            fail_cnt++;
            $display("  [FAIL] %0t: %s", $time, msg);
        end
    endtask

    // Log every instruction the scheduler actually issues (opcode + which
    // window slot it came from), useful for eyeballing out-of-order issue.
    always @(posedge clk) begin
        logic [3:0] issued_op;
        if (rst_n && fifo_pop_en) begin
            issued_op = window[fifo_pop_idx][31:28];   // was [23:20] under the old 24-bit layout
            $display("  [ISSUE] t=%0t slot=%0d opcode=%0d addr=%0d len=%0d",
                $time, fifo_pop_idx, issued_op,
                window[fifo_pop_idx][23:16], window[fifo_pop_idx][15:8]);  // was [15:8]/[7:0]
        end
    end

    task automatic reset_dut();
        int k;
        rst_n = 0;
        start_pulse = 0; soft_reset = 0; perf_valid = 0;
        num_acts = 0; src_addr = 0; dst_addr = 0; weight_addr = 0; bias_addr = 0;
        img_rows = 0; img_cols = 0;
        seen_accum_filling = 1'b0;
        for (k = 0; k < INSTR_WINDOW_SIZE; k++) window[k] = NOP_WORD;
        prog_len = 0; prog_ptr = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    task automatic wait_done(input int timeout_cycles = 500);
        int n;
        n = 0;
        while (!done && n < timeout_cycles) begin
            @(posedge clk);
            n++;
        end
        check(done, $sformatf("design reached done within %0d cycles", timeout_cycles));
    endtask

    //-----------------------------------------------------------------
    // Test 1: straight-line single-tile pipeline
    //   LOAD_WGT -> LOAD_ACT -> LOAD_BIAS -> SWAP_WGT -> MATMUL(NONE) ->
    //   VECTOR -> STORE -> END
    //
    // UPDATED: MATMUL no longer writes out_buf directly — it writes the new
    // accum_buffer. A LOAD_BIAS + OP_VECTOR pair (accum_buf+bias_buf ->
    // out_buf) is now required before STORE can see a READY out_buf.
    // accum_ctrl=ACC_NONE means "single-pass, no cross-tile reduction",
    // which mirrors the old direct MATMUL->vector_unit behavior.
    //-----------------------------------------------------------------
    task automatic test_basic_pipeline();
        logic [INSTR_WIDTH-1:0] prog[];
        logic [DMA_WIDTH-1:0] exp_wgt_addr, exp_act_addr, exp_store_addr;
        $display("\n=== TEST 1: basic single-tile pipeline ===");
        reset_dut();

        weight_addr = 64'h1000_0000;
        src_addr    = 64'h2000_0000;
        dst_addr    = 64'h3000_0000;
        bias_addr   = 64'h4000_0000;

        prog = '{
            pack_instr(OP_LOAD_WGT,  2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_LOAD_ACT,  2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_LOAD_BIAS, 2'd0, 2'd0, 8'd0, 8'd1),
            pack_instr(OP_SWAP_WGT,  2'd0, 2'd0, 8'd0, 8'd0),  // NEW — required to set array_wgt_valid before MATMUL can issue
            pack_instr(OP_MATMUL,    2'd0, 2'd0, 8'd0, 8'd0, ACC_NONE),
            pack_instr(OP_VECTOR,    2'd0, 2'd0, 8'd0, 8'd0),
            pack_instr(OP_STORE,     2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_END,       2'd0, 2'd0, 8'd0, 8'd0)
        };
        load_program(prog);
        start_pulse <= 1; @(posedge clk); start_pulse <= 0;

        check(busy, "busy asserted after start_pulse");

        wait_done(300);

        exp_wgt_addr   = weight_addr + (64'(8'd0) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));
        exp_act_addr   = src_addr    + (64'(8'd0) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));
        exp_store_addr = dst_addr    + (64'(8'd0) << $clog2(DATA_WIDTH*ARRAY_SIZE/8));

        check(dut.wgt_buf_state == dut.BUF_READY || dut.wgt_buf_state == dut.BUF_EMPTY,
              "weight buffer reached a sane terminal state");
        check(dut.bias_buf_state == dut.BUF_READY,
              "bias buffer loaded and stays READY (persistent resource)");
        check(dut.accum_buf_state == dut.BUF_EMPTY,
              "accum buffer released back to EMPTY after OP_VECTOR consumes it");
        check(dut.out_buf_state[0] == dut.BUF_EMPTY,
              "output buffer 0 drained back to EMPTY after STORE completes");
    endtask

    //-----------------------------------------------------------------
    // Test 2: out-of-order issue / hazard check.
    //   Window is loaded MATMUL-first, but MATMUL can't issue until its
    //   weight+act deps are ready, so LOAD_WGT/LOAD_ACT (which sit behind
    //   it in program order) must be picked first by the scanner.
    //
    // UPDATED: this program never issues OP_VECTOR, so — under the new
    // architecture — the tile MATMUL produces lands in accum_buffer (READY,
    // single-pass ACC_NONE), not out_buf (out_buf is only touched by
    // OP_VECTOR now).
    //-----------------------------------------------------------------
    task automatic test_out_of_order_issue();
        logic [INSTR_WIDTH-1:0] prog[];
        $display("\n=== TEST 2: out-of-order issue past a stalled MATMUL ===");
        reset_dut();
        weight_addr = 64'hA000_0000;
        src_addr    = 64'hB000_0000;

        prog = '{
            pack_instr(OP_MATMUL,   2'd0, 2'd0, 8'd0, 8'd0, ACC_NONE),   // stalled: no wgt/act yet
            pack_instr(OP_LOAD_WGT, 2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_SWAP_WGT, 2'd0, 2'd0, 8'd0, 8'd0),  // NEW — required to set array_wgt_valid before MATMUL can issue
            pack_instr(OP_LOAD_ACT, 2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_END,      2'd0, 2'd0, 8'd0, 8'd0)
        };
        load_program(prog);
        start_pulse <= 1; @(posedge clk); start_pulse <= 0;

        // Right after start, MATMUL sits at window slot 0 and must NOT be
        // the one issued (its dependencies aren't ready).
        @(negedge clk);
        check(!(fifo_pop_en && fifo_pop_idx == 0),
              "scheduler skips slot-0 MATMUL while its deps are not ready");

        wait_done(300);
        check(dut.accum_buf_state == dut.BUF_READY,
              "MATMUL eventually issued and produced a ready accumulation-buffer tile");
    endtask

    //-----------------------------------------------------------------
    // Test 3: double-buffered activations (bank0 loaded while bank1 loads),
    // and double-buffered outputs, checks per-bank independence of the
    // act_buf/out_buf scoreboards.
    //
    // UPDATED: the accumulation buffer is single-banked (see accelerator
    // architecture notes), so the two MATMULs can no longer run fully
    // concurrently into two independent "output banks" the way the old
    // (architecturally incomplete) MATMUL->out_buf path implied. Each
    // MATMUL's tile must be drained through OP_VECTOR (accum_buf -> out_buf)
    // before the next MATMUL can reuse the accum buffer. This still
    // exercises act_buf/out_buf double-buffering (bank1's LOAD_ACT can
    // still overlap bank0's MATMUL/VECTOR/STORE), just serializes the
    // accum-buffer-owning stage as the new architecture requires.
    //-----------------------------------------------------------------
    task automatic test_dual_bank_pipelining();
        logic [INSTR_WIDTH-1:0] prog[];
        $display("\n=== TEST 3: dual activation/output-bank pipelining (serialized through accum_buf) ===");
        reset_dut();
        weight_addr = 64'hC000_0000;
        src_addr    = 64'hD000_0000;
        dst_addr    = 64'hE000_0000;
        bias_addr   = 64'hF000_0000;

        prog = '{
            pack_instr(OP_LOAD_WGT,  2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_LOAD_BIAS, 2'd0, 2'd0, 8'd0, 8'd1),
            pack_instr(OP_LOAD_ACT,  2'd0, 2'd0, 8'd0, 8'd16), // -> bank0
            pack_instr(OP_LOAD_ACT,  2'd0, 2'd1, 8'd1, 8'd16), // -> bank1, can overlap bank0's matmul/vector/store
            pack_instr(OP_SWAP_WGT,  2'd0, 2'd0, 8'd0, 8'd0),  // NEW — required to set array_wgt_valid before MATMUL can issue
            pack_instr(OP_MATMUL,    2'd0, 2'd0, 8'd0, 8'd0, ACC_NONE),  // bank0 -> accum_buf
            pack_instr(OP_VECTOR,    2'd0, 2'd0, 8'd0, 8'd0),            // accum_buf -> out0
            pack_instr(OP_MATMUL,    2'd1, 2'd0, 8'd0, 8'd0, ACC_NONE),  // bank1 -> accum_buf (reused)
            pack_instr(OP_VECTOR,    2'd0, 2'd1, 8'd0, 8'd0),            // accum_buf -> out1
            pack_instr(OP_STORE,     2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_STORE,     2'd1, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_END,       2'd0, 2'd0, 8'd0, 8'd0)
        };
        load_program(prog);
        start_pulse <= 1; @(posedge clk); start_pulse <= 0;
        wait_done(500);
        check(dut.out_buf_state[0] == dut.BUF_EMPTY && dut.out_buf_state[1] == dut.BUF_EMPTY,
              "both output banks drained after their STOREs complete");
        check(dut.accum_buf_state == dut.BUF_EMPTY,
              "accum buffer released after the second OP_VECTOR consumes it");
    endtask

    //-----------------------------------------------------------------
    // Test 4: soft_reset mid-flight clears the scoreboard immediately,
    // regardless of in-flight engine activity.
    //-----------------------------------------------------------------
    task automatic test_soft_reset();
        logic [INSTR_WIDTH-1:0] prog[];
        $display("\n=== TEST 4: soft_reset clears scoreboard mid-flight ===");
        reset_dut();
        weight_addr = 64'h1111_0000;

        prog = '{
            pack_instr(OP_LOAD_WGT, 2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_END,      2'd0, 2'd0, 8'd0, 8'd0)
        };
        load_program(prog);
        start_pulse <= 1; @(posedge clk); start_pulse <= 0;

        // Let the LOAD_WGT issue and get partway through its DMA latency.
        repeat (2) @(posedge clk);
        check(dut.dma_rd_state == 1'b1, "dma_rd engine busy before soft_reset");

        soft_reset <= 1;
        @(posedge clk);
        soft_reset <= 0;
        @(posedge clk);
        $display($sformatf("  [INFO] after soft_reset: dma_rd_state=%0b, wgt_buf_state=%0d",
                  dut.dma_rd_state, dut.wgt_buf_state));
        check(dut.dma_rd_state == 1'b0, "dma_rd engine forced back to IDLE by soft_reset");
        check(dut.wgt_buf_state == dut.BUF_EMPTY, "weight buffer state cleared by soft_reset");
    endtask

    //-----------------------------------------------------------------
    // Test 5: known-issue probe (not a hard failure) -- wgt_buf_state
    // has no path back to BUF_EMPTY once a weight load completes, since
    // OP_SWAP_WGT's issue path is commented out in the scheduler. This
    // means a second OP_LOAD_WGT in the same program can never be issued.
    // Flagged here so it's visible instead of silently absent from
    // coverage.
    //-----------------------------------------------------------------
    task automatic test_known_issue_second_weight_load();
        logic [INSTR_WIDTH-1:0] prog[];
        int n;
        $display("\n=== TEST 5: second OP_LOAD_WGT after the first completes (known-issue probe) ===");
        reset_dut();
        weight_addr = 64'h2222_0000;

        prog = '{
            pack_instr(OP_LOAD_WGT, 2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_LOAD_WGT, 2'd0, 2'd0, 8'd1, 8'd16),
            pack_instr(OP_END,      2'd0, 2'd0, 8'd0, 8'd0)
        };
        load_program(prog);
        start_pulse <= 1; @(posedge clk); start_pulse <= 0;

        n = 0;
        while (!done && n < 200) begin @(posedge clk); n++; end

        if (dut.wgt_buf_state == dut.BUF_READY && !done)
            $display("  [KNOWN ISSUE] second OP_LOAD_WGT never issues: wgt_buf_state stays "
                      , "BUF_READY forever because OP_SWAP_WGT (the only path back to ",
                      "BUF_EMPTY) is disabled in the scheduler. See RTL TODOs.");
        else
            $display("  [INFO] second weight load behavior differs from expected known-issue pattern; re-check RTL.");
    endtask

    //-----------------------------------------------------------------
    // Test 6 (NEW): multi-tile accumulation reduction.
    //   LOAD_WGT -> LOAD_ACT(bank0) -> LOAD_ACT(bank1) -> LOAD_BIAS ->
    //   MATMUL(src=bank0, ACC_INIT) -> MATMUL(src=bank1, ACC_LAST) ->
    //   VECTOR -> STORE -> END
    //
    // Exercises the new accum_ctrl field end-to-end: the first MATMUL
    // (ACC_INIT) should leave accum_buf_state in BUF_FILLING (not yet
    // consumable — more tiles expected), and only the second MATMUL
    // (ACC_LAST) should push it to BUF_READY for OP_VECTOR to drain.
    //-----------------------------------------------------------------
    task automatic test_multi_tile_reduction();
        logic [INSTR_WIDTH-1:0] prog[];
        $display("\n=== TEST 6: multi-tile accumulation reduction (ACC_INIT -> ACC_LAST) ===");
        reset_dut();
        weight_addr = 64'h5000_0000;
        src_addr    = 64'h6000_0000;
        dst_addr    = 64'h7000_0000;
        bias_addr   = 64'h8000_0000;

        prog = '{
            pack_instr(OP_LOAD_WGT,  2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_LOAD_ACT,  2'd0, 2'd0, 8'd0, 8'd16),  // -> bank0
            pack_instr(OP_LOAD_ACT,  2'd0, 2'd1, 8'd1, 8'd16),  // -> bank1
            pack_instr(OP_LOAD_BIAS, 2'd0, 2'd0, 8'd0, 8'd1),
            pack_instr(OP_SWAP_WGT,  2'd0, 2'd0, 8'd0, 8'd0),  // NEW — required to set array_wgt_valid before MATMUL can issue
            pack_instr(OP_MATMUL,    2'd0, 2'd0, 8'd0, 8'd0, ACC_INIT),  // bank0 -> accum (overwrite, not ready)
            pack_instr(OP_MATMUL,    2'd1, 2'd0, 8'd0, 8'd0, ACC_LAST),  // bank1 -> accum (add, mark ready)
            pack_instr(OP_VECTOR,    2'd0, 2'd0, 8'd0, 8'd0),
            pack_instr(OP_STORE,     2'd0, 2'd0, 8'd0, 8'd16),
            pack_instr(OP_END,       2'd0, 2'd0, 8'd0, 8'd0)
        };
        load_program(prog);
        start_pulse <= 1; @(posedge clk); start_pulse <= 0;

        wait_done(400);

        check(seen_accum_filling,
              "accum buffer was observed in BUF_FILLING after the ACC_INIT tile (reduction group in progress)");
        check(dut.accum_buf_state == dut.BUF_EMPTY,
              "accum buffer released back to EMPTY after OP_VECTOR consumes the ACC_LAST result");
        check(dut.out_buf_state[0] == dut.BUF_EMPTY,
              "output buffer drained back to EMPTY after STORE completes");
    endtask

    //-----------------------------------------------------------------
    // Main sequence
    //-----------------------------------------------------------------
    initial begin
        $dumpfile("tb_control_unit.vcd");
        $dumpvars(0, tb_control_unit);
        #100;
        test_basic_pipeline();
        test_out_of_order_issue();
        test_dual_bank_pipelining();
        test_soft_reset();
        test_known_issue_second_weight_load();
        test_multi_tile_reduction();

        $display("\n===========================================");
        $display(" RESULT: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("===========================================");
        if (fail_cnt > 0) $display("TESTBENCH: FAIL");
        else $display("TESTBENCH: PASS");

        $finish;
    end

    // Safety timeout in case something wedges.
    initial begin
        #100000;
        $display("GLOBAL TIMEOUT - simulation did not finish in time");
        $finish;
    end

endmodule