// =============================================================================
// tb_systolic_array_4x4.v  —  Testbench for systolic_array_4x4
// =============================================================================
//
//  The 4×4 array computes ONE vector-matrix product per invocation:
//
//    result_out[c] = sum_{r=0}^{3} act_in[r] * W[r][c]
//
//  Test suites
//  -----------
//  1.  Identity W  → result_out[c] = act_in[c]
//  2.  All-ones W  → result_out[c] = sum(act_in)
//  3.  Arbitrary W — exhaustive golden check
//  4.  Timing: result_out[c] appears ROWS+c cycles after en pulse
//  5.  Back-to-back invocations
//  6.  Weight reload between invocations
//  7.  Zero activations → all outputs 0
//  8.  Perf counter: freeze and clear
//  9.  Winograd stub: xform_out == result_out (PIPELINE_TYPE=0)
//
// =============================================================================

`timescale 1ns/1ps

module tb_systolic_array_4x4;

    // =========================================================================
    // Parameters (mirror DUT)
    // =========================================================================
    localparam integer ROWS        = 4;
    localparam integer COLS        = 4;
    localparam integer ACCUM_WIDTH = 32;

    // Latency: result_out[c] valid ROWS+c cycles after en.
    // Last output (c=COLS-1) appears ROWS+COLS-1 = 7 cycles after en.
    localparam integer LATENCY_MAX = ROWS + COLS - 1;  // 7

    // =========================================================================
    // Clock
    // =========================================================================
    localparam CLK_PERIOD = 10;
    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    task check_int;
        input [255:0] tag;
        input integer got;
        input integer exp;
        begin
            if (got === exp) begin
                $display("  PASS  %s  got=%0d", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %s  got=%0d  exp=%0d", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // DUT signals — scalar bridge for iverilog compatibility
    // =========================================================================
    reg  rst_n, en, clear_acc, weight_load;

    reg  signed [7:0]
        wd0,wd1,wd2,wd3, wd4,wd5,wd6,wd7,
        wd8,wd9,wd10,wd11, wd12,wd13,wd14,wd15;
    reg  signed [7:0] ai0, ai1, ai2, ai3;

    wire signed [ACCUM_WIDTH-1:0] ro0,ro1,ro2,ro3;
    wire rv0,rv1,rv2,rv3;
    wire [31:0] perf_cycles;
    wire        perf_valid;
    wire signed [ACCUM_WIDTH-1:0] xo0,xo1,xo2,xo3;

    // Array bridges
    wire signed [7:0] wd_a[0:ROWS*COLS-1];
    wire signed [7:0] ai_a[0:ROWS-1];
    wire signed [7:0] xai_a[0:ROWS-1];
    wire signed [7:0] xwi_a[0:ROWS*COLS-1];
    wire signed [ACCUM_WIDTH-1:0] ro_a[0:COLS-1];
    wire [0:COLS-1] rv_a;
    wire signed [ACCUM_WIDTH-1:0] xo_a[0:COLS-1];

    assign wd_a[0]=wd0;   assign wd_a[1]=wd1;   assign wd_a[2]=wd2;
    assign wd_a[3]=wd3;   assign wd_a[4]=wd4;   assign wd_a[5]=wd5;
    assign wd_a[6]=wd6;   assign wd_a[7]=wd7;   assign wd_a[8]=wd8;
    assign wd_a[9]=wd9;   assign wd_a[10]=wd10; assign wd_a[11]=wd11;
    assign wd_a[12]=wd12; assign wd_a[13]=wd13; assign wd_a[14]=wd14;
    assign wd_a[15]=wd15;
    assign ai_a[0]=ai0; assign ai_a[1]=ai1; assign ai_a[2]=ai2; assign ai_a[3]=ai3;

    genvar gx;
    generate
        for (gx=0;gx<ROWS;gx=gx+1)      assign xai_a[gx]=8'sd0;
        for (gx=0;gx<ROWS*COLS;gx=gx+1) assign xwi_a[gx]=8'sd0;
    endgenerate

    assign ro0=ro_a[0]; assign ro1=ro_a[1]; assign ro2=ro_a[2]; assign ro3=ro_a[3];
    assign rv0=rv_a[0]; assign rv1=rv_a[1]; assign rv2=rv_a[2]; assign rv3=rv_a[3];
    assign xo0=xo_a[0]; assign xo1=xo_a[1]; assign xo2=xo_a[2]; assign xo3=xo_a[3];

    // =========================================================================
    // DUT
    // =========================================================================
    systolic_array_4x4 #(
        .ROWS(ROWS),.COLS(COLS),
        .FRAC_BITS(0),.ACCUM_WIDTH(ACCUM_WIDTH),
        .SATURATE(1),.ROUND_POLICY(1),.PIPELINE_TYPE(0)
    ) DUT (
        .clk(clk),.rst_n(rst_n),
        .en(en),.clear_acc(clear_acc),.weight_load(weight_load),
        .weight_data(wd_a),.act_in(ai_a),
        .result_out(ro_a),.result_valid(rv_a),
        .perf_cycles(perf_cycles),.perf_valid(perf_valid),
        .xform_act_in(xai_a),.xform_wt_in(xwi_a),.xform_out(xo_a)
    );

    // =========================================================================
    // Shared test state
    // =========================================================================
    // Weight matrix: wm[r][c] = W[r][c] = wm_flat[r*COLS+c]
    // Activation vector: av[r]
    reg signed [7:0] wm_flat[0:ROWS*COLS-1];
    reg signed [7:0] av[0:ROWS-1];

    // Expected results (golden)
    integer gold[0:COLS-1];

    // Captured outputs
    integer cap[0:COLS-1];
    integer cap_cycle[0:COLS-1]; // cycle at which each column was captured

    // =========================================================================
    // Tasks
    // =========================================================================
    task tick; @(posedge clk); #1; endtask
    task ticks; input integer n; integer i; begin for(i=0;i<n;i=i+1) tick; end endtask

    task do_reset;
        integer i;
        begin
            rst_n=0; en=0; clear_acc=0; weight_load=0;
            ai0=0; ai1=0; ai2=0; ai3=0;
            {wd0,wd1,wd2,wd3,wd4,wd5,wd6,wd7} = 64'd0;
            {wd8,wd9,wd10,wd11,wd12,wd13,wd14,wd15} = 64'd0;
            ticks(2); rst_n=1; ticks(2);
        end
    endtask

    task push_weights;
        begin
            wd0=wm_flat[0];  wd1=wm_flat[1];  wd2=wm_flat[2];  wd3=wm_flat[3];
            wd4=wm_flat[4];  wd5=wm_flat[5];  wd6=wm_flat[6];  wd7=wm_flat[7];
            wd8=wm_flat[8];  wd9=wm_flat[9];  wd10=wm_flat[10];wd11=wm_flat[11];
            wd12=wm_flat[12];wd13=wm_flat[13];wd14=wm_flat[14];wd15=wm_flat[15];
            weight_load=1; tick; weight_load=0;
        end
    endtask

    // Compute golden: gold[c] = sum_r av[r]*W[r][c]
    task compute_golden;
        integer r, c, acc;
        begin
            for (c=0; c<COLS; c=c+1) begin
                acc=0;
                for (r=0; r<ROWS; r=r+1)
                    acc = acc + av[r] * wm_flat[r*COLS+c];
                gold[c] = acc;
            end
        end
    endtask

    // Fire one en pulse with current av[] on ai ports
    task fire_activation;
        begin
            ai0=av[0]; ai1=av[1]; ai2=av[2]; ai3=av[3];
            en=1; tick; en=0;
            ai0=0; ai1=0; ai2=0; ai3=0;
        end
    endtask

    // Wait for all columns to produce a valid output, capture values.
    // Each col c fires at ROWS+c cycles after en → col 0 at +4, col 3 at +7.
    // We track each independently and latch on the cycle the valid fires.
    integer cap0_l, cap1_l, cap2_l, cap3_l;
    task capture_results;
        input integer timeout;
        integer t;
        reg s0,s1,s2,s3;
        begin
            s0=0; s1=0; s2=0; s3=0; t=0;
            while (!(s0&&s1&&s2&&s3) && t<timeout) begin
                if (rv0 && !s0) begin cap0_l=ro0; s0=1; end
                if (rv1 && !s1) begin cap1_l=ro1; s1=1; end
                if (rv2 && !s2) begin cap2_l=ro2; s2=1; end
                if (rv3 && !s3) begin cap3_l=ro3; s3=1; end
                tick; t=t+1;
            end
            cap[0]=cap0_l; cap[1]=cap1_l; cap[2]=cap2_l; cap[3]=cap3_l;
            if (!(s0&&s1&&s2&&s3)) begin
                $display("  TIMEOUT: only %0b%0b%0b%0b cols captured after %0d cycles",
                         s0,s1,s2,s3,timeout);
                fail_cnt=fail_cnt+1;
            end
        end
    endtask

    task check_all_cols;
        input [255:0] suite;
        begin
            if(cap[0]===gold[0]) begin $display("  PASS  %s col[0] got=%0d",suite,cap[0]); pass_cnt=pass_cnt+1; end
            else begin $display("  FAIL  %s col[0] got=%0d exp=%0d",suite,cap[0],gold[0]); fail_cnt=fail_cnt+1; end
            if(cap[1]===gold[1]) begin $display("  PASS  %s col[1] got=%0d",suite,cap[1]); pass_cnt=pass_cnt+1; end
            else begin $display("  FAIL  %s col[1] got=%0d exp=%0d",suite,cap[1],gold[1]); fail_cnt=fail_cnt+1; end
            if(cap[2]===gold[2]) begin $display("  PASS  %s col[2] got=%0d",suite,cap[2]); pass_cnt=pass_cnt+1; end
            else begin $display("  FAIL  %s col[2] got=%0d exp=%0d",suite,cap[2],gold[2]); fail_cnt=fail_cnt+1; end
            if(cap[3]===gold[3]) begin $display("  PASS  %s col[3] got=%0d",suite,cap[3]); pass_cnt=pass_cnt+1; end
            else begin $display("  FAIL  %s col[3] got=%0d exp=%0d",suite,cap[3],gold[3]); fail_cnt=fail_cnt+1; end
        end
    endtask

    // Shortcut: fire activation, then capture in the same test
    task run_and_capture;
        input [255:0] suite;
        begin
            fire_activation;
            capture_results(LATENCY_MAX + 4);
            check_all_cols(suite);
        end
    endtask

    // =========================================================================
    // MAIN TEST
    // =========================================================================
    integer r_i, c_i;

    initial begin
        $dumpfile("tb_systolic_array_4x4.vcd");
        $dumpvars(0, tb_systolic_array_4x4);

        // ------------------------------------------------------------------ //
        // Suite 1 — Identity weights: result_out[c] = act_in[c]             //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 1: Identity weights — result_out[c] = act_in[c] ===");
        do_reset;
        // W[r][c] = (r==c) ? 1 : 0
        for (r_i=0; r_i<ROWS; r_i=r_i+1)
            for (c_i=0; c_i<COLS; c_i=c_i+1)
                wm_flat[r_i*COLS+c_i] = (r_i==c_i) ? 8'sd1 : 8'sd0;
        // av = [10, 20, 30, 40]
        av[0]=8'sd10; av[1]=8'sd20; av[2]=8'sd30; av[3]=8'sd40;
        push_weights;
        compute_golden;
        run_and_capture("S1-Identity");

        // ------------------------------------------------------------------ //
        // Suite 2 — All-ones weights: result_out[c] = sum(act_in)           //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 2: All-ones weights — result_out[c] = sum(act_in) ===");
        do_reset;
        for (r_i=0; r_i<ROWS*COLS; r_i=r_i+1) wm_flat[r_i]=8'sd1;
        av[0]=8'sd1; av[1]=8'sd2; av[2]=8'sd3; av[3]=8'sd4;
        push_weights;
        compute_golden;
        run_and_capture("S2-AllOnes");

        // ------------------------------------------------------------------ //
        // Suite 3 — Arbitrary weights                                        //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 3: Arbitrary weights ===");
        do_reset;
        wm_flat[0]=8'sd2;  wm_flat[1]=-8'sd3; wm_flat[2]=8'sd1;  wm_flat[3]=8'sd4;
        wm_flat[4]=-8'sd1; wm_flat[5]=8'sd5;  wm_flat[6]=-8'sd2; wm_flat[7]=8'sd3;
        wm_flat[8]=8'sd7;  wm_flat[9]=-8'sd1; wm_flat[10]=8'sd4; wm_flat[11]=-8'sd2;
        wm_flat[12]=-8'sd3;wm_flat[13]=8'sd2; wm_flat[14]=8'sd6; wm_flat[15]=-8'sd1;
        av[0]=8'sd3; av[1]=-8'sd2; av[2]=8'sd5; av[3]=8'sd1;
        push_weights;
        compute_golden;
        run_and_capture("S3-Arbitrary");

        // ------------------------------------------------------------------ //
        // Suite 4 — Timing verification                                      //
        //   result_out[c] appears ROWS+c cycles after en pulse.              //
        //   col0 → T+4,  col1 → T+5,  col2 → T+6,  col3 → T+7             //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 4: Timing — result_out[c] at T+ROWS+c ===");
        do_reset;
        for (r_i=0; r_i<ROWS*COLS; r_i=r_i+1) wm_flat[r_i]=8'sd1;
        av[0]=8'sd1; av[1]=8'sd1; av[2]=8'sd1; av[3]=8'sd1;
        push_weights;

        begin : blk_s4_timing
            integer t4;
            reg s0t,s1t,s2t,s3t;
            integer t4_c0,t4_c1,t4_c2,t4_c3;
            s0t=0;s1t=0;s2t=0;s3t=0; t4_c0=0;t4_c1=0;t4_c2=0;t4_c3=0;

            fire_activation;
            for (t4=1; t4<=LATENCY_MAX+2; t4=t4+1) begin
                if (rv0 && !s0t) begin t4_c0=t4; s0t=1; end
                if (rv1 && !s1t) begin t4_c1=t4; s1t=1; end
                if (rv2 && !s2t) begin t4_c2=t4; s2t=1; end
                if (rv3 && !s3t) begin t4_c3=t4; s3t=1; end
                tick;
            end
            check_int("S4-col0 fires at T+ROWS+0=T+4", t4_c0, ROWS+0);
            check_int("S4-col1 fires at T+ROWS+1=T+5", t4_c1, ROWS+1);
            check_int("S4-col2 fires at T+ROWS+2=T+6", t4_c2, ROWS+2);
            check_int("S4-col3 fires at T+ROWS+3=T+7", t4_c3, ROWS+3);
        end

        // ------------------------------------------------------------------ //
        // Suite 5 — Back-to-back invocations                                 //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 5: Back-to-back (pipeline fill) ===");
        do_reset;
        for (r_i=0; r_i<ROWS*COLS; r_i=r_i+1) wm_flat[r_i]=8'sd1;
        push_weights;

        // Invocation A: av = [1,2,3,4]  → gold = 10
        av[0]=8'sd1; av[1]=8'sd2; av[2]=8'sd3; av[3]=8'sd4;
        compute_golden;
        fire_activation;
        capture_results(LATENCY_MAX+4);
        check_all_cols("S5-InvocA");

        // Invocation B: av = [5,5,5,5]  → gold = 20
        av[0]=8'sd5; av[1]=8'sd5; av[2]=8'sd5; av[3]=8'sd5;
        compute_golden;
        fire_activation;
        capture_results(LATENCY_MAX+4);
        check_all_cols("S5-InvocB");

        // ------------------------------------------------------------------ //
        // Suite 6 — Weight reload                                            //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 6: Weight reload ===");
        do_reset;
        // First load: W = identity
        for (r_i=0; r_i<ROWS; r_i=r_i+1)
            for (c_i=0; c_i<COLS; c_i=c_i+1)
                wm_flat[r_i*COLS+c_i] = (r_i==c_i) ? 8'sd1 : 8'sd0;
        push_weights;
        av[0]=8'sd1; av[1]=8'sd2; av[2]=8'sd3; av[3]=8'sd4;
        compute_golden;
        fire_activation;
        capture_results(LATENCY_MAX+4);
        check_all_cols("S6-before-reload");

        // Reload: W = all twos
        for (r_i=0; r_i<ROWS*COLS; r_i=r_i+1) wm_flat[r_i]=8'sd2;
        push_weights;
        compute_golden;   // recompute with new weights
        fire_activation;
        capture_results(LATENCY_MAX+4);
        check_all_cols("S6-after-reload");

        // ------------------------------------------------------------------ //
        // Suite 7 — Zero activations                                        //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 7: Zero activations → all outputs 0 ===");
        do_reset;
        for (r_i=0; r_i<ROWS*COLS; r_i=r_i+1) wm_flat[r_i]=$signed(r_i+1);
        av[0]=8'sd0; av[1]=8'sd0; av[2]=8'sd0; av[3]=8'sd0;
        push_weights;
        compute_golden;
        run_and_capture("S7-ZeroAct");

        // ------------------------------------------------------------------ //
        // Suite 8 — Perf counter freeze and clear                           //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 8: Perf counter ===");
        do_reset;
        for (r_i=0; r_i<ROWS*COLS; r_i=r_i+1) wm_flat[r_i]=8'sd1;
        av[0]=8'sd1; av[1]=8'sd2; av[2]=8'sd3; av[3]=8'sd4;
        push_weights;
        fire_activation;
        // wait until perf_valid
        begin : blk_s8
            integer t8; reg pv_seen;
            pv_seen=0; t8=0;
            while (!pv_seen && t8<20) begin
                if (perf_valid) pv_seen=1;
                tick; t8=t8+1;
            end
            check_int("S8-perf_valid asserted", pv_seen, 1);
            $display("  INFO  perf_cycles=%0d  (expected ~%0d)",
                     perf_cycles, ROWS+COLS-1+1);
            check_int("S8-perf_cycles >= ROWS+COLS-1", (perf_cycles >= ROWS+COLS-1), 1);

            // Freeze check — counter must not change after DONE
            begin : blk_s8_freeze
                integer frozen;
                frozen = perf_cycles;
                ticks(10);
                check_int("S8-perf_cycles frozen", perf_cycles, frozen);
            end

            // Clear
            clear_acc=1; tick; clear_acc=0; ticks(2);
            check_int("S8-perf_valid cleared", perf_valid, 0);
            check_int("S8-perf_cycles reset",  perf_cycles, 0);
        end

        // ------------------------------------------------------------------ //
        // Suite 9 — Winograd stub: xform_out == result_out                  //
        // ------------------------------------------------------------------ //
        $display("\n=== Suite 9: Winograd pass-through (PIPELINE_TYPE=0) ===");
        do_reset;
        for (r_i=0; r_i<ROWS*COLS; r_i=r_i+1) wm_flat[r_i]=8'sd1;
        av[0]=8'sd3; av[1]=8'sd1; av[2]=8'sd4; av[3]=8'sd1;
        push_weights;
        fire_activation;
        capture_results(LATENCY_MAX+4);
        // xform_out is wired to result_out when PIPELINE_TYPE=0
        if(xo0===ro0) begin $display("  PASS  xform_out[0]==result_out[0] (%0d)",xo0); pass_cnt=pass_cnt+1; end
        else begin $display("  FAIL  xo0=%0d ro0=%0d",xo0,ro0); fail_cnt=fail_cnt+1; end
        if(xo1===ro1) begin $display("  PASS  xform_out[1]==result_out[1] (%0d)",xo1); pass_cnt=pass_cnt+1; end
        else begin $display("  FAIL  xo1=%0d ro1=%0d",xo1,ro1); fail_cnt=fail_cnt+1; end
        if(xo2===ro2) begin $display("  PASS  xform_out[2]==result_out[2] (%0d)",xo2); pass_cnt=pass_cnt+1; end
        else begin $display("  FAIL  xo2=%0d ro2=%0d",xo2,ro2); fail_cnt=fail_cnt+1; end
        if(xo3===ro3) begin $display("  PASS  xform_out[3]==result_out[3] (%0d)",xo3); pass_cnt=pass_cnt+1; end
        else begin $display("  FAIL  xo3=%0d ro3=%0d",xo3,ro3); fail_cnt=fail_cnt+1; end

        // ------------------------------------------------------------------ //
        // Efficiency report                                                  //
        // ------------------------------------------------------------------ //
        $display("\n--- Cycle Efficiency Report ---");
        $display("  Array size              : %0dx%0d", ROWS, COLS);
        $display("  DIAG_DEPTH (warmup)     : %0d  (ROWS+COLS-2)", ROWS+COLS-2);
        $display("  Result latency col[c]   : ROWS+c cycles after en");
        $display("  Last output (col COLS-1): %0d cycles after en", ROWS+COLS-1);
        $display("");
        $display("  For K-vector GEMM (streaming K act vectors, 1 per cycle):");
        $display("    Total cycles = DIAG_DEPTH + K + (ROWS-1)");
        $display("    K=1  : %0d + 1 + %0d = %0d  eff=%.1f%%",
                 ROWS+COLS-2, ROWS-1, ROWS+COLS-2+1+ROWS-1,
                 100.0*ROWS*COLS / (ROWS+COLS-2+1+ROWS-1));
        $display("    K=4  : %0d + 4 + %0d = %0d  eff=%.1f%%",
                 ROWS+COLS-2, ROWS-1, ROWS+COLS-2+4+ROWS-1,
                 100.0*ROWS*COLS*4 / ((ROWS+COLS-2+4+ROWS-1)*ROWS*COLS));
        $display("    K=16 : %0d + 16 + %0d = %0d  eff=%.1f%%",
                 ROWS+COLS-2, ROWS-1, ROWS+COLS-2+16+ROWS-1,
                 100.0*16 / (ROWS+COLS-2+16+ROWS-1));
        $display("");
        $display("  --- Winograd comparison (same 4x4 array) ---");
        $display("  Winograd F(2,3): 3 MACs instead of 4 per 2-element output");
        $display("  K_eff per tile  = 3 vs K_direct = 4");
        $display("  Direct  K=4  total=%0d  useful=4  eff=%.1f%%",
                 ROWS+COLS-2+4+ROWS-1,
                 100.0*4 / (ROWS+COLS-2+4+ROWS-1));
        $display("  Winograd K=3 total=%0d  useful=4  eff=%.1f%%  (+%.1f%% speedup)",
                 ROWS+COLS-2+3+ROWS-1,
                 100.0*4 / (ROWS+COLS-2+3+ROWS-1),
                 100.0*(1.0/(ROWS+COLS-2+3+ROWS-1) - 1.0/(ROWS+COLS-2+4+ROWS-1))
                 / (1.0/(ROWS+COLS-2+4+ROWS-1)));

        // ------------------------------------------------------------------ //
        $display("\n======================================================");
        $display("  RESULT: %0d passed, %0d failed", pass_cnt, fail_cnt);
        $display("======================================================");
        if (fail_cnt==0) $display("  ALL TESTS PASSED");
        else             $display("  SOME TESTS FAILED — see FAIL lines above");

        $finish;
    end

    initial begin #5_000_000; $display("WATCHDOG TIMEOUT"); $finish; end

endmodule