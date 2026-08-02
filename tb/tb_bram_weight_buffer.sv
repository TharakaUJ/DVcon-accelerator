`timescale 1ns/1ps
//
// tb_bram_weight_buffer.sv
//
// Self-checking testbench for bram_weight_buffer.
//   - Maintains a behavioral reference model (a simple 2-D byte array).
//   - Drives writes (directed corner cases + randomized bursts).
//   - Triggers reads, waits for rd_valid, and compares every element of the
//     flattened weight_data bus against the reference model.
//   - Also checks rd_valid timing/latency and that rd_valid deasserts when
//     rd_en is not pulsed, and that it drops correctly on reset.
//
module tb_bram_weight_buffer;

    // ---------------------------------------------------------------
    // Parameters (kept small-ish for fast sim, but non-trivial)
    // ---------------------------------------------------------------
    localparam integer DATA_W    = 8;
    localparam integer ROWS      = 16;
    localparam integer COLS      = 16;
    localparam integer DMA_WIDTH = 64;
    localparam integer EPD       = DMA_WIDTH / DATA_W;                 // elements per DMA beat
    localparam integer CHUNKS    = COLS / EPD;                        // chunks per row
    localparam integer ROW_W     = (ROWS > 1) ? $clog2(ROWS) : 1;
    localparam integer WR_ADDR_W = (CHUNKS > 1) ? $clog2(CHUNKS) : 1;

    localparam integer NUM_RAND_TESTS = 300;

    // ---------------------------------------------------------------
    // DUT I/O
    // ---------------------------------------------------------------
    reg                    clk;
    reg                    rst_n;

    reg                    wr_en;
    reg  [ROW_W-1:0]       wr_row;
    reg  [WR_ADDR_W-1:0]   wr_addr;
    reg  [DMA_WIDTH-1:0]   wr_data;

    reg                    rd_en;
    wire signed [DATA_W-1:0] weight_data [0:ROWS*COLS-1];
    wire                   rd_valid;

    // ---------------------------------------------------------------
    // Reference model: byte-accurate shadow memory
    // ---------------------------------------------------------------
    reg signed [DATA_W-1:0] ref_mem [0:ROWS-1][0:COLS-1];

    integer errors;
    integer checks;

    // ---------------------------------------------------------------
    // DUT instantiation
    // ---------------------------------------------------------------
    bram_weight_buffer #(
        .DATA_W (DATA_W),
        .ROWS   (ROWS),
        .COLS   (COLS),
        .DMA_WIDTH (DMA_WIDTH)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .wr_en       (wr_en),
        .wr_row      (wr_row),
        .wr_addr     (wr_addr),
        .wr_data     (wr_data),
        .rd_en       (rd_en),
        .weight_data (weight_data),
        .rd_valid    (rd_valid)
    );

    // ---------------------------------------------------------------
    // Clock: 10 ns period
    // ---------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---------------------------------------------------------------
    // Tasks
    // ---------------------------------------------------------------

    // Drive one write beat (chunk) into row/addr with given data, and
    // update the reference model to match.
    task automatic do_write(input [ROW_W-1:0] row,
                             input [WR_ADDR_W-1:0] addr,
                             input [DMA_WIDTH-1:0] data);
        integer i;
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_row  = row;
            wr_addr = addr;
            wr_data = data;
            @(negedge clk); // beat is captured on the intervening posedge
            wr_en   = 1'b0;

            for (i = 0; i < EPD; i = i + 1) begin
                ref_mem[row][addr*EPD + i] = data[DATA_W*i +: DATA_W];
            end
        end
    endtask

    // Pulse rd_en for one cycle, then wait for rd_valid, then compare the
    // entire flattened bus against the reference model.
    task automatic do_read_and_check(input [ROW_W-1:0] dummy_unused);
        integer r, c;
        reg signed [DATA_W-1:0] exp;
        reg signed [DATA_W-1:0] got;
        begin
            @(negedge clk);
            rd_en = 1'b1;
            @(negedge clk);
            rd_en = 1'b0;

            // rd_valid and weight_data are both registered off the same
            // rd_en sample, so they should be valid right now (we're
            // sitting at the negedge just after that posedge).
            if (rd_valid !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] ERROR: rd_valid did not assert one cycle after rd_en pulse", $time);
            end

            for (r = 0; r < ROWS; r = r + 1) begin
                for (c = 0; c < COLS; c = c + 1) begin
                    exp = ref_mem[r][c];
                    got = weight_data[r*COLS + c];
                    checks = checks + 1;
                    if (got !== exp) begin
                        errors = errors + 1;
                        $display("[%0t] ERROR: weight_data mismatch row=%0d col=%0d exp=%0d got=%0d",
                                  $time, r, c, exp, got);
                    end
                end
            end

            // rd_valid should drop the cycle after, since rd_en was only
            // pulsed for one cycle.
            @(negedge clk);
            if (rd_valid !== 1'b0) begin
                errors = errors + 1;
                $display("[%0t] ERROR: rd_valid did not deassert after single-cycle rd_en pulse", $time);
            end
        end
    endtask

    // ---------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------
    integer row_i, chunk_i, t;
    reg [DMA_WIDTH-1:0] rand_data;
    reg [ROW_W-1:0]     rand_row;
    reg [WR_ADDR_W-1:0] rand_addr;

    initial begin
        errors = 0;
        checks = 0;
        wr_en  = 1'b0;
        rd_en  = 1'b0;
        wr_row  = 0;
        wr_addr = 0;
        wr_data = 0;
        rst_n  = 1'b0;

        // init reference model to 0 (matches X-free expectation only after
        // corresponding locations are written; we only compare locations
        // we've written, see full-tile fill below)
        for (row_i = 0; row_i < ROWS; row_i = row_i + 1)
            for (chunk_i = 0; chunk_i < COLS; chunk_i = chunk_i + 1)
                ref_mem[row_i][chunk_i] = '0;

        // -----------------------------------------------------------
        // Reset
        // -----------------------------------------------------------
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        if (rd_valid !== 1'b0) begin
            errors = errors + 1;
            $display("[%0t] ERROR: rd_valid not low after reset", $time);
        end

        // -----------------------------------------------------------
        // Directed test 1: fill the entire array deterministically
        // (row r, chunk k -> data = {..., row, chunk, elem_idx} pattern)
        // then read back and check full tile.
        // -----------------------------------------------------------
        $display("=== Directed test: full deterministic fill ===");
        for (row_i = 0; row_i < ROWS; row_i = row_i + 1) begin
            for (chunk_i = 0; chunk_i < CHUNKS; chunk_i = chunk_i + 1) begin
                reg [DMA_WIDTH-1:0] beat;
                integer e;
                beat = '0;
                for (e = 0; e < EPD; e = e + 1) begin
                    beat[DATA_W*e +: DATA_W] = (row_i * 17 + chunk_i * 5 + e) & {DATA_W{1'b1}};
                end
                do_write(row_i[ROW_W-1:0], chunk_i[WR_ADDR_W-1:0], beat);
            end
        end
        do_read_and_check(0);

        // -----------------------------------------------------------
        // Directed test 2: corner cases - row 0 / last row, chunk 0 / last
        // chunk, all-zero data, all-one data, alternating pattern.
        // -----------------------------------------------------------
        $display("=== Directed test: corner cases ===");
        do_write({ROW_W{1'b0}}, {WR_ADDR_W{1'b0}}, {DMA_WIDTH{1'b0}});
        do_write(ROWS-1, CHUNKS-1, {DMA_WIDTH{1'b1}});
        do_write({ROW_W{1'b0}}, CHUNKS-1, 64'hDEAD_BEEF_CAFE_F00D);
        do_write(ROWS-1, {WR_ADDR_W{1'b0}}, 64'hA5A5_5A5A_1234_5678);
        do_read_and_check(0);

        // -----------------------------------------------------------
        // Directed test 3: back-to-back writes to same row, different
        // chunks, verifying no cross-chunk corruption.
        // -----------------------------------------------------------
        $display("=== Directed test: same-row multi-chunk writes ===");
        for (chunk_i = 0; chunk_i < CHUNKS; chunk_i = chunk_i + 1) begin
            reg [DMA_WIDTH-1:0] beat;
            beat = {DMA_WIDTH{1'b0}} | (chunk_i + 1);
            // spread a distinct byte pattern per chunk
            beat = {8{(chunk_i[7:0] ^ 8'hF0)}};
            do_write(ROWS/2, chunk_i[WR_ADDR_W-1:0], beat);
        end
        do_read_and_check(0);

        // -----------------------------------------------------------
        // Randomized regression
        // -----------------------------------------------------------
        $display("=== Randomized regression: %0d writes ===", NUM_RAND_TESTS);
        for (t = 0; t < NUM_RAND_TESTS; t = t + 1) begin
            rand_row  = $urandom_range(ROWS-1, 0);
            rand_addr = $urandom_range(CHUNKS-1, 0);
            rand_data = {$urandom, $urandom};
            do_write(rand_row, rand_addr, rand_data);

            // Periodically read back and check full tile
            if (t % 25 == 24) begin
                do_read_and_check(0);
            end
        end
        // final check
        do_read_and_check(0);

        // -----------------------------------------------------------
        // Reset-during-operation check: assert rd_en, then assert reset
        // before the read completes, rd_valid must drop.
        // -----------------------------------------------------------
        $display("=== Directed test: async reset during read ===");
        @(negedge clk);
        rd_en = 1'b1;
        @(negedge clk);
        rd_en = 1'b0;
        // rd_valid should be 1 here
        if (rd_valid !== 1'b1) begin
            errors = errors + 1;
            $display("[%0t] ERROR: rd_valid expected high before reset assertion", $time);
        end
        rst_n = 1'b0;
        #1; // allow async reset to propagate
        if (rd_valid !== 1'b0) begin
            errors = errors + 1;
            $display("[%0t] ERROR: rd_valid did not clear asynchronously on reset", $time);
        end
        @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // -----------------------------------------------------------
        // Wrap up
        // -----------------------------------------------------------
        $display("=========================================");
        $display("TOTAL CHECKS: %0d", checks);
        if (errors == 0) begin
            $display("*** TEST PASSED ***");
        end else begin
            $display("*** TEST FAILED: %0d error(s) ***", errors);
        end
        $display("=========================================");

        $finish;
    end

    // Safety timeout
    initial begin
        #200000;
        $display("ERROR: TESTBENCH TIMEOUT");
        $finish;
    end

endmodule