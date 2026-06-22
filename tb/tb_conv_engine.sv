// tb_conv_engine.sv — self-checking testbench for conv_engine
// Simulator: Icarus Verilog (iverilog -g2012)

`timescale 1ns/1ps

module tb_conv_engine;

    localparam int ACCUM_WIDTH = 32;
    localparam int LATENCY     = 9;

    // -------------------------------------------------------------------------
    // Clock & reset
    // -------------------------------------------------------------------------
    logic clk = 0;
    always #10 clk = ~clk;

    logic rst_n;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    logic        en;
    logic signed [7:0] act_in    [0:8];
    logic signed [7:0] weight_in [0:8];
    logic signed [ACCUM_WIDTH-1:0] result_out;
    logic                          result_valid;

    conv_engine #(.ACCUM_WIDTH(ACCUM_WIDTH)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (en),
        .act_in      (act_in),
        .weight_in   (weight_in),
        .result_out  (result_out),
        .result_valid(result_valid)
    );

    // -------------------------------------------------------------------------
    // VCD dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("build/conv_engine_wave.vcd");
        $dumpvars(0, tb_conv_engine);
    end

    // -------------------------------------------------------------------------
    // Shared test input registers (set before calling run_test)
    // -------------------------------------------------------------------------
    reg signed [7:0] t_act    [0:8];
    reg signed [7:0] t_weight [0:8];
    reg signed [31:0] t_expected;

    int pass_count = 0;
    int fail_count = 0;

    // -------------------------------------------------------------------------
    // run_test — drives shared t_act / t_weight, checks result
    // -------------------------------------------------------------------------
    task automatic run_test(input string test_name);
        // Compute reference
        integer s;
        s = 0;
        for (int i = 0; i < 9; i++) s = s + (t_act[i] * t_weight[i]);
        t_expected = s;

        // Drive
        @(negedge clk);
        for (int i = 0; i < 9; i++) act_in[i]    = t_act[i];
        for (int i = 0; i < 9; i++) weight_in[i] = t_weight[i];
        en = 1'b1;
        @(negedge clk);
        en = 1'b0;

        // Wait for the 1-cycle result_valid pulse (timeout after 20 cycles)
        begin
            int wait_cnt;
            wait_cnt = 0;
            while (!result_valid && wait_cnt < 20) begin
                @(posedge clk);
                wait_cnt++;
            end
        end

        if (result_valid && (result_out === t_expected)) begin
            $display("PASS  %-20s  expected=%0d  got=%0d", test_name, t_expected, result_out);
            pass_count++;
        end else begin
            $display("FAIL  %-20s  expected=%0d  got=%0d  valid=%b",
                     test_name, t_expected, result_out, result_valid);
            fail_count++;
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        rst_n = 0; en = 0;
        for (int i = 0; i < 9; i++) act_in[i]    = 8'sd0;
        for (int i = 0; i < 9; i++) weight_in[i] = 8'sd0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        // Test 1: all-ones — expected = 9
        // ------------------------------------------------------------------
        for (int i = 0; i < 9; i++) t_act[i]    = 8'sd1;
        for (int i = 0; i < 9; i++) t_weight[i] = 8'sd1;
        run_test("all_ones");

        // ------------------------------------------------------------------
        // Test 2: identity kernel (centre=1, rest=0) — expected = 5
        // ------------------------------------------------------------------
        t_act[0]=8'sd1; t_act[1]=8'sd2; t_act[2]=8'sd3;
        t_act[3]=8'sd4; t_act[4]=8'sd5; t_act[5]=8'sd6;
        t_act[6]=8'sd7; t_act[7]=8'sd8; t_act[8]=8'sd9;
        for (int i = 0; i < 9; i++) t_weight[i] = 8'sd0;
        t_weight[4] = 8'sd1;
        run_test("identity_kernel");

        // ------------------------------------------------------------------
        // Test 3: hand-computed — expected = 570
        // act=[2,4,6,8,10,12,14,16,18], weight=[1..9]
        // ------------------------------------------------------------------
        for (int i = 0; i < 9; i++) t_act[i]    = signed'(8'(2*(i+1)));
        for (int i = 0; i < 9; i++) t_weight[i] = signed'(8'(i+1));
        run_test("hand_computed");

        // ------------------------------------------------------------------
        // Test 4: negative activations — expected = -45
        // ------------------------------------------------------------------
        for (int i = 0; i < 9; i++) t_act[i]    = -signed'(8'(i+1));
        for (int i = 0; i < 9; i++) t_weight[i] = 8'sd1;
        run_test("negative_acts");

        // ------------------------------------------------------------------
        // Test 5: max INT8 — expected = 9 × 127 × 127 = 145161
        // ------------------------------------------------------------------
        for (int i = 0; i < 9; i++) t_act[i]    = 8'sd127;
        for (int i = 0; i < 9; i++) t_weight[i] = 8'sd127;
        run_test("max_int8");

        repeat (4) @(posedge clk);

        $display("--------------------------------------");
        $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");
        $display("--------------------------------------");
        $finish;
    end

    initial begin
        #200000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
