// line_buffer.sv
// 3×3 sliding window extractor for convolution preprocessing.
// Two ring-buffer line buffers (depth MAX_COLS) delay the pixel stream by
// one and two rows respectively. A 3×3 grid of column shift registers forms
// the window. window_valid is a registered output; window_out is combinational
// from the column-shift FFs so both are stable after the same posedge.

`timescale 1ns/1ps

module line_buffer #(
    parameter int MAX_COLS  = 1024,
    parameter int DATA_WIDTH = 8
)(
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         flush,
    input  logic [15:0]                  num_cols,
    input  logic signed [DATA_WIDTH-1:0] pixel_in,
    input  logic                         pixel_valid,
    output logic [DATA_WIDTH*9-1:0]      window_out,
    output logic                         window_valid,
    output logic                         row_complete
);

    // =========================================================================
    // Ring-buffer line buffers
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] lb1 [0:MAX_COLS-1];   // row n-1 delay
    logic signed [DATA_WIDTH-1:0] lb2 [0:MAX_COLS-1];   // row n-2 delay
    logic [15:0] wr_ptr;

    // =========================================================================
    // Column shift registers: col_r[row][tap]
    //   row 0 = oldest (fed from lb2), row 2 = current (fed from pixel_in)
    //   tap 0 = most recent, tap 2 = oldest-in-row
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] col_r [0:2][0:2];

    // =========================================================================
    // Counters
    // =========================================================================
    logic [15:0] col_cnt;   // column index of current pixel (pre-update)
    logic [1:0]  row_cnt;   // saturates at 2

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr      <= '0;
            col_cnt     <= '0;
            row_cnt     <= '0;
            window_valid <= 1'b0;
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++)
                    col_r[i][j] <= '0;
        end else if (flush) begin
            wr_ptr      <= '0;
            col_cnt     <= '0;
            row_cnt     <= '0;
            window_valid <= 1'b0;
            for (int i = 0; i < 3; i++)
                for (int j = 0; j < 3; j++)
                    col_r[i][j] <= '0;
        end else if (pixel_valid) begin
            // --- Ring buffer update ---
            // All RHS evaluated in active region before any NBA fires,
            // so lb1[wr_ptr] / lb2[wr_ptr] below read the OLD (pre-write) values.
            lb2[wr_ptr] <= lb1[wr_ptr];
            lb1[wr_ptr] <= pixel_in;
            wr_ptr <= (wr_ptr == num_cols - 1) ? '0 : wr_ptr + 1;

            // --- Column shift registers ---
            // row 2: current row
            col_r[2][2] <= col_r[2][1];
            col_r[2][1] <= col_r[2][0];
            col_r[2][0] <= pixel_in;
            // row 1: middle row (row n-1), fed from lb1 before its NBA update
            col_r[1][2] <= col_r[1][1];
            col_r[1][1] <= col_r[1][0];
            col_r[1][0] <= lb1[wr_ptr];
            // row 0: oldest row (row n-2), fed from lb2 before its NBA update
            col_r[0][2] <= col_r[0][1];
            col_r[0][1] <= col_r[0][0];
            col_r[0][0] <= lb2[wr_ptr];

            // --- Counters ---
            if (col_cnt == num_cols - 1) begin
                col_cnt <= '0;
                if (row_cnt < 2)
                    row_cnt <= row_cnt + 1'b1;
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end

            // --- window_valid: registered, uses pre-update col_cnt/row_cnt ---
            window_valid <= (col_cnt >= 2) && (row_cnt == 2);
        end else begin
            window_valid <= 1'b0;
        end
    end

    // =========================================================================
    // Combinational outputs
    // =========================================================================
    // Tap mapping: tap = dr*3 + dc
    //   dr 0=oldest row, dc 0=leftmost column
    //   col_r[dr][0] = rightmost (dc=2), col_r[dr][2] = leftmost (dc=0)
    //   => col_r[dr][2-dc]
    generate
        genvar dr, dc;
        for (dr = 0; dr < 3; dr++) begin : gen_row
            for (dc = 0; dc < 3; dc++) begin : gen_col
                assign window_out[(dr*3 + dc)*DATA_WIDTH +: DATA_WIDTH] = col_r[dr][2-dc];
            end
        end
    endgenerate

    assign row_complete = pixel_valid && (col_cnt == num_cols - 1);

endmodule
