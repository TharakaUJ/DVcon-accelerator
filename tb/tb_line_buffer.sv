// tb_line_buffer.sv — self-checking testbench for line_buffer
// Simulator: Icarus Verilog (iverilog -g2012)
// Waveform:  GTKWave (build/line_buffer_wave.vcd)
//
// Test image (5 rows × 8 cols, INT8, 1-indexed values):
//   Row 0: [ 1  2  3  4  5  6  7  8]
//   Row 1: [ 9 10 11 12 13 14 15 16]
//   Row 2: [17 18 19 20 21 22 23 24]
//   Row 3: [25 26 27 28 29 30 31 32]
//   Row 4: [33 34 35 36 37 38 39 40]
//
// Valid output windows: (5-2) rows × (8-2) cols = 18 windows
// Window(r, c) = 3×3 patch with bottom-right at image[r][c], r∈[2..4], c∈[2..7]
//
// Test groups:
//   1. First 6 windows of row 2 (all columns) — verifies initial fill
//   2. All windows of rows 3 and 4           — verifies row rotation
//   3. Flush + re-run                        — verifies state reset
//   4. Back-to-back pixel injection          — no gaps between rows

`timescale 1ns/1ps

module tb_line_buffer;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int MAX_COLS   = 1024;
    localparam int DATA_WIDTH = 8;
    localparam int NUM_ROWS   = 5;
    localparam int NUM_COLS   = 8;

    // =========================================================================
    // Clock & reset
    // =========================================================================
    logic clk = 0;
    always #10 clk = ~clk;   // 50 MHz

    logic rst_n;

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic        flush        = 0;
    logic [15:0] num_cols_sig = NUM_COLS;

    logic signed [7:0] pixel_in    = '0;
    logic              pixel_valid = 0;

    // Flat 9×8 bus; tap i = window_out_flat[i*8+:8] (see line_buffer port note)
    logic [DATA_WIDTH*9-1:0] window_out_flat;
    logic                    window_valid;
    logic                    row_complete;

    // Convenience unpacking using explicit constant slices (Icarus safe)
    wire signed [7:0] wo0 = window_out_flat[ 7: 0];
    wire signed [7:0] wo1 = window_out_flat[15: 8];
    wire signed [7:0] wo2 = window_out_flat[23:16];
    wire signed [7:0] wo3 = window_out_flat[31:24];
    wire signed [7:0] wo4 = window_out_flat[39:32];
    wire signed [7:0] wo5 = window_out_flat[47:40];
    wire signed [7:0] wo6 = window_out_flat[55:48];
    wire signed [7:0] wo7 = window_out_flat[63:56];
    wire signed [7:0] wo8 = window_out_flat[71:64];

    // Helper function to index window output by tap
    function automatic logic signed [7:0] wo(input int tap);
        case (tap)
            0: wo = wo0; 1: wo = wo1; 2: wo = wo2;
            3: wo = wo3; 4: wo = wo4; 5: wo = wo5;
            6: wo = wo6; 7: wo = wo7; 8: wo = wo8;
            default: wo = '0;
        endcase
    endfunction

    // =========================================================================
    // DUT
    // =========================================================================
    line_buffer #(
        .MAX_COLS  (MAX_COLS),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .flush       (flush),
        .num_cols    (num_cols_sig),
        .pixel_in    (pixel_in),
        .pixel_valid (pixel_valid),
        .window_out  (window_out_flat),
        .window_valid(window_valid),
        .row_complete(row_complete)
    );

    // =========================================================================
    // VCD
    // =========================================================================
    initial begin
        $dumpfile("build/line_buffer_wave.vcd");
        $dumpvars(0, tb_line_buffer);
    end

    // =========================================================================
    // Score tracking
    // =========================================================================
    int pass_count = 0;
    int fail_count = 0;

    task automatic check8(
        input string       label,
        input logic signed [7:0] got,
        input logic signed [7:0] expected
    );
        if (got === expected) begin
            $display("PASS  %-45s  exp=%4d  got=%4d", label, expected, got);
            pass_count++;
        end else begin
            $display("FAIL  %-45s  exp=%4d  got=%4d", label, expected, got);
            fail_count++;
        end
    endtask

    task automatic check1(
        input string label,
        input logic  got,
        input logic  expected
    );
        if (got === expected) begin
            $display("PASS  %-45s  exp=%0b  got=%0b", label, expected, got);
            pass_count++;
        end else begin
            $display("FAIL  %-45s  exp=%0b  got=%0b", label, expected, got);
            fail_count++;
        end
    endtask

    // =========================================================================
    // Test image — image[row][col] (1-indexed: row 0 col 0 = 1)
    // =========================================================================
    logic signed [7:0] image [0:NUM_ROWS-1][0:NUM_COLS-1];

    initial begin
        for (int r = 0; r < NUM_ROWS; r++)
            for (int c = 0; c < NUM_COLS; c++)
                image[r][c] = 8'(r * NUM_COLS + c + 1);
    end

    // Expected window at bottom-right pixel (r, c): 3×3 patch rows r-2..r, cols c-2..c
    function automatic logic signed [7:0] exp_win(input int r, input int c, input int tap);
        int dr = tap / 3;   // 0=oldest, 1=middle, 2=current
        int dc = tap % 3;   // 0=left, 1=center, 2=right
        return image[r - 2 + dr][c - 2 + dc];
    endfunction

    // =========================================================================
    // BFM: stream all rows of the image, one pixel per clock
    // =========================================================================
    logic signed [7:0] captured_window [0:8];
    int                windows_received;

    task automatic stream_image(input int start_row, input int end_row);
        for (int r = start_row; r <= end_row; r++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                @(negedge clk);
                pixel_in    = image[r][c];
                pixel_valid = 1'b1;
                @(posedge clk);
                // Capture window if valid on this posedge
                if (window_valid) begin
                    for (int i = 0; i < 9; i++)
                        captured_window[i] = wo(i);
                    windows_received++;
                end
            end
        end
        @(negedge clk);
        pixel_valid = 1'b0;
        // Drain remaining valid windows (BRAM + SR pipeline tail)
        repeat (4) begin
            @(posedge clk);
            if (window_valid) begin
                for (int i = 0; i < 9; i++)
                    captured_window[i] = wo(i);
                windows_received++;
            end
        end
        @(negedge clk);
    endtask

    // =========================================================================
    // Window collection: stream all rows and store every window
    // =========================================================================
    // Max 18 windows for 5×8 image
    logic signed [7:0] all_windows [0:17][0:8];
    int                win_idx;

    task automatic collect_all_windows;
        win_idx = 0;
        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                @(negedge clk);
                pixel_in    = image[r][c];
                pixel_valid = 1'b1;
                @(posedge clk);
                if (window_valid && win_idx < 18) begin
                    for (int i = 0; i < 9; i++)
                        all_windows[win_idx][i] = wo(i);
                    win_idx++;
                end
            end
        end
        @(negedge clk);
        pixel_valid = 1'b0;
        repeat (4) begin
            @(posedge clk);
            if (window_valid && win_idx < 18) begin
                for (int i = 0; i < 9; i++)
                    all_windows[win_idx][i] = wo(i);
                win_idx++;
            end
        end
        @(negedge clk);
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        // Reset
        rst_n = 0;
        repeat(4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ==================================================================
        // TEST 1+2: Collect all 18 windows, verify against expected
        // ==================================================================
        $display("\n--- Tests 1+2: all windows from 5x8 image ---");
        collect_all_windows;

        // Expected window order: row 2 cols 2..7, row 3 cols 2..7, row 4 cols 2..7
        begin
            int idx = 0;
            for (int r = 2; r < NUM_ROWS; r++) begin
                for (int c = 2; c < NUM_COLS; c++) begin
                    for (int tap = 0; tap < 9; tap++) begin
                        check8($sformatf("win[%0d] r=%0d c=%0d tap=%0d", idx, r, c, tap),
                               all_windows[idx][tap], exp_win(r, c, tap));
                    end
                    idx++;
                end
            end
            check1("total windows = 18", logic'(win_idx == 18), 1'b1);
        end

        // ==================================================================
        // TEST 3: Flush then re-run — must produce same windows
        // ==================================================================
        $display("\n--- Test 3: flush + re-run ---");
        @(negedge clk);
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;
        repeat(2) @(posedge clk);

        collect_all_windows;

        begin
            int idx = 0;
            for (int r = 2; r < NUM_ROWS; r++) begin
                for (int c = 2; c < NUM_COLS; c++) begin
                    // Spot-check first tap of each window
                    check8($sformatf("flush re-run win[%0d] tap0", idx),
                           all_windows[idx][0], exp_win(r, c, 0));
                    idx++;
                end
            end
            check1("flush re-run total windows = 18", logic'(win_idx == 18), 1'b1);
        end

        // ==================================================================
        // TEST 4: No-gap streaming (pixel_valid always high across rows)
        // ==================================================================
        $display("\n--- Test 4: continuous pixel_valid (no inter-row gap) ---");
        @(negedge clk);
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;
        repeat(2) @(posedge clk);

        win_idx = 0;
        @(negedge clk);
        pixel_valid = 1'b1;
        for (int r = 0; r < NUM_ROWS; r++) begin
            for (int c = 0; c < NUM_COLS; c++) begin
                pixel_in = image[r][c];
                @(posedge clk);
                if (window_valid && win_idx < 18) begin
                    for (int i = 0; i < 9; i++)
                        all_windows[win_idx][i] = wo(i);
                    win_idx++;
                end
                @(negedge clk);
            end
        end
        pixel_valid = 1'b0;
        repeat(4) begin
            @(posedge clk);
            if (window_valid && win_idx < 18) begin
                for (int i = 0; i < 9; i++)
                    all_windows[win_idx][i] = wo(i);
                win_idx++;
            end
        end

        begin
            int idx = 0;
            for (int r = 2; r < NUM_ROWS; r++) begin
                for (int c = 2; c < NUM_COLS; c++) begin
                    check8($sformatf("no-gap win[%0d] tap0", idx),
                           all_windows[idx][0], exp_win(r, c, 0));
                    idx++;
                end
            end
            check1("no-gap total windows = 18", logic'(win_idx == 18), 1'b1);
        end

        repeat(4) @(posedge clk);

        // ==================================================================
        // Summary
        // ==================================================================
        $display("\n--------------------------------------");
        $display("Results: %0d PASSED, %0d FAILED", pass_count, fail_count);
        if (fail_count == 0) $display("ALL TESTS PASSED");
        else                 $display("SOME TESTS FAILED");
        $display("--------------------------------------");
        $finish;
    end

    // Watchdog
    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
