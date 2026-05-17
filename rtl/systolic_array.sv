// =============================================================================
// systolic_array_4x4.v  —  4×4 Weight-Stationary Systolic Array
// =============================================================================
//
//  Computes a vector-matrix product each invocation:
//
//      result_out[c] = sum_{r=0}^{ROWS-1}  act_in[r] * W[r][c]
//
//  where W is the stationary weight matrix loaded once into PE registers,
//  and act_in is a ROWS-element activation vector presented each cycle.
//
//  To multiply a matrix A (M×ROWS) by W (ROWS×COLS):
//      - Stream each row of A as act_in[r] on successive cycles (K=1 per row)
//      - result_out will carry one row of C = A*W per invocation,
//        separated by LATENCY cycles between outputs.
//
//  Weight-Stationary Systolic Flow
//  --------------------------------
//   PE[r][c] holds weight W[r][c].
//
//   Diagonal skew ensures PE[r][c] receives the correct activation and
//   that the partial sum from PE[r-1][c] is ready exactly when PE[r][c] fires:
//
//     en_diag[d]        : single shift-register; PE[r][c].en  = en_diag[r+c]
//     act_pipe[row][d]  : per-row shift-register; PE[r][c].act = act_pipe[r][r+c]
//
//   Partial sums flow strictly downward:
//     PE[0][c].psum_in  = 0
//     PE[r][c].psum_in  = PE[r-1][c].psum_out   (registered, arrives 1 cycle later)
//
//   Because PE[r][c] fires at T+r+c and PE[r-1][c].psum_out is valid at T+r-1+c+1
//   = T+r+c, the timing is perfectly matched.
//
//  Latency
//  -------
//   DIAG_DEPTH = ROWS + COLS - 2  (deepest diagonal stage = PE[3][3])
//   result_out[c] appears ROWS+c cycles after the en pulse
//   Last output (c=COLS-1) appears ROWS+COLS-1 = 7 cycles after en
//
//  Cycle counter
//  -------------
//   perf_cycles counts from first en to last column's out_valid.
//
//  Winograd extensibility
//  -----------------------
//   PIPELINE_TYPE=0: direct MAC (this module)
//   PIPELINE_TYPE=1: Winograd (future wrapper)
//   xform_* ports are stubs; xform_out = result_out when PIPELINE_TYPE=0.
//
//  Parameters
//  ----------
//   ROWS, COLS        grid dimensions (default 4×4)
//   FRAC_BITS         fractional bits passed to each systolic_pe
//   ACCUM_WIDTH       psum / output width
//   SATURATE          saturation enable
//   ROUND_POLICY      0=floor, 1=round-half-up
//   PIPELINE_TYPE     0=direct, 1=Winograd stub (future)
//
// =============================================================================

`timescale 1ns/1ps

module systolic_array_4x4 #(
    parameter integer ROWS          = 4,
    parameter integer COLS          = 4,
    parameter integer FRAC_BITS     = 0,
    parameter integer ACCUM_WIDTH   = 32,
    parameter integer SATURATE      = 1,
    parameter integer ROUND_POLICY  = 1,
    parameter integer PIPELINE_TYPE = 0
)(
    input  wire clk,
    input  wire rst_n,

    // ── Control ──────────────────────────────────────────────────────────────
    input  wire en,           // assert for one cycle per activation vector
    input  wire clear_acc,    // resets perf counter and weight registers
    input  wire weight_load,  // strobe: load weight_data → weight registers

    // ── Weight bus (flat, W[r][c] = weight_data[r*COLS+c]) ──────────────────
    input  wire signed [7:0] weight_data [0:ROWS*COLS-1],

    // ── Activation input vector ──────────────────────────────────────────────
    input  wire signed [7:0] act_in [0:ROWS-1],

    // ── Output ───────────────────────────────────────────────────────────────
    output wire signed [ACCUM_WIDTH-1:0] result_out   [0:COLS-1],
    output wire [0:COLS-1]               result_valid,

    // ── Performance counter ───────────────────────────────────────────────────
    output reg  [31:0] perf_cycles,
    output reg         perf_valid,

    // ── Winograd extension stubs ─────────────────────────────────────────────
    input  wire signed [7:0]             xform_act_in [0:ROWS-1],
    input  wire signed [7:0]             xform_wt_in  [0:ROWS*COLS-1],
    output wire signed [ACCUM_WIDTH-1:0] xform_out    [0:COLS-1]
);

    // =========================================================================
    // Parameters & local constants
    // =========================================================================
    localparam integer DIAG_DEPTH = ROWS + COLS - 2;  // 6 for 4×4

    // =========================================================================
    // Input mux — direct vs Winograd
    // =========================================================================
    wire signed [7:0] eff_act [0:ROWS-1];
    wire signed [7:0] eff_wt  [0:ROWS*COLS-1];
    generate
        genvar gi;
        if (PIPELINE_TYPE == 0) begin : g_direct
            for (gi = 0; gi < ROWS;      gi = gi+1) assign eff_act[gi] = act_in[gi];
            for (gi = 0; gi < ROWS*COLS; gi = gi+1) assign eff_wt [gi] = weight_data[gi];
        end else begin : g_winograd
            for (gi = 0; gi < ROWS;      gi = gi+1) assign eff_act[gi] = xform_act_in[gi];
            for (gi = 0; gi < ROWS*COLS; gi = gi+1) assign eff_wt [gi] = xform_wt_in [gi];
        end
    endgenerate

    // =========================================================================
    // Weight registers
    // =========================================================================
    reg signed [7:0] weight_reg [0:ROWS-1][0:COLS-1];
    integer wr, wc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (wr = 0; wr < ROWS; wr = wr+1)
                for (wc = 0; wc < COLS; wc = wc+1)
                    weight_reg[wr][wc] <= 8'sd0;
        end else if (weight_load) begin
            for (wr = 0; wr < ROWS; wr = wr+1)
                for (wc = 0; wc < COLS; wc = wc+1)
                    weight_reg[wr][wc] <= eff_wt[wr * COLS + wc];
        end
    end

    // =========================================================================
    // Diagonal skew — en shift register  (depth DIAG_DEPTH+1)
    // =========================================================================
    // en_diag[0] = en (registered 0 cycles = direct)
    // en_diag[d] = en delayed d cycles
    // PE[r][c].en = en_diag[r+c]
    reg [DIAG_DEPTH:0] en_diag;   // [DIAG_DEPTH:0] gives indices 0..DIAG_DEPTH
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            en_diag <= {(DIAG_DEPTH+1){1'b0}};
        else
            en_diag <= {en_diag[DIAG_DEPTH-1:0], en};  // shift in from LSB
    end
    // en_diag[0] = en registered 1 cycle (shifts in next clock)
    // We need en_diag index d = delay d from en:
    //   d=0 → direct (combinatorial) → just use 'en' signal
    //   d=1 → en_diag[0] (registered once)
    //   d=DIAG_DEPTH → en_diag[DIAG_DEPTH-1]
    // Build an array for clean indexing:
    wire en_sked [0:DIAG_DEPTH];
    genvar gd;
    generate
        assign en_sked[0] = en;
        for (gd = 1; gd <= DIAG_DEPTH; gd = gd+1)
            assign en_sked[gd] = en_diag[gd-1];
    endgenerate

    // =========================================================================
    // Diagonal skew — activation pipeline  (per row, depth DIAG_DEPTH+1)
    // =========================================================================
    // act_pipe[r][0] = eff_act[r] (direct)
    // act_pipe[r][d] = eff_act[r] delayed d cycles
    // PE[r][c].act_in = act_pipe[r][r+c]
    reg signed [7:0] act_dly [0:ROWS-1][0:DIAG_DEPTH]; // [row][delay_stage]
    integer adr, adc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (adr = 0; adr < ROWS; adr = adr+1)
                for (adc = 0; adc <= DIAG_DEPTH; adc = adc+1)
                    act_dly[adr][adc] <= 8'sd0;
        end else begin
            for (adr = 0; adr < ROWS; adr = adr+1) begin
                act_dly[adr][0] <= eff_act[adr];
                begin : blk_act_shift
                    integer sd;
                    for (sd = 1; sd <= DIAG_DEPTH; sd = sd+1)
                        act_dly[adr][sd] <= act_dly[adr][sd-1];
                end
            end
        end
    end
    // act_sked[r][d] : activation for row r delayed d cycles
    wire signed [7:0] act_sked [0:ROWS-1][0:DIAG_DEPTH];
    generate
        genvar gr, gsd;
        for (gr = 0; gr < ROWS; gr = gr+1) begin : g_act_sked_row
            assign act_sked[gr][0] = eff_act[gr];
            for (gsd = 1; gsd <= DIAG_DEPTH; gsd = gsd+1) begin : g_act_sked_d
                assign act_sked[gr][gsd] = act_dly[gr][gsd-1];
            end
        end
    endgenerate

    // =========================================================================
    // PE array
    // =========================================================================
    wire signed [ACCUM_WIDTH-1:0] psum_wire  [0:ROWS][0:COLS-1]; // row boundary
    wire                          psum_valid [0:ROWS][0:COLS-1];

    // Top boundary: no upstream psum
    generate
        genvar tc;
        for (tc = 0; tc < COLS; tc = tc+1) begin : g_top
            assign psum_wire [0][tc] = {ACCUM_WIDTH{1'b0}};
            assign psum_valid[0][tc] = 1'b0;
        end
    endgenerate

    // PE outputs
    wire signed [ACCUM_WIDTH-1:0] pe_psum  [0:ROWS-1][0:COLS-1];
    wire                          pe_valid [0:ROWS-1][0:COLS-1];

    generate
        genvar pr, pc;
        for (pr = 0; pr < ROWS; pr = pr+1) begin : g_row
            for (pc = 0; pc < COLS; pc = pc+1) begin : g_col
                systolic_pe #(
                    .FRAC_BITS   (FRAC_BITS),
                    .ACCUM_WIDTH (ACCUM_WIDTH),
                    .SATURATE    (SATURATE),
                    .ROUND_POLICY(ROUND_POLICY)
                ) u_pe (
                    .clk           (clk),
                    .rst_n         (rst_n),
                    .en            (en_sked[pr + pc]),
                    .weight_in     (weight_reg[pr][pc]),
                    .act_in        (act_sked[pr][pr + pc]),
                    .psum_in       (psum_wire [pr][pc]),
                    .psum_in_valid (psum_valid[pr][pc]),
                    .psum_out      (pe_psum  [pr][pc]),
                    .out_valid     (pe_valid [pr][pc])
                );

                // Feed this PE's output into next row's psum input
                if (pr < ROWS-1) begin : g_psum_chain
                    assign psum_wire [pr+1][pc] = pe_psum  [pr][pc];
                    assign psum_valid[pr+1][pc] = pe_valid [pr][pc];
                end
            end
        end
    endgenerate

    // =========================================================================
    // Output — bottom row
    // =========================================================================
    generate
        genvar oc;
        for (oc = 0; oc < COLS; oc = oc+1) begin : g_out
            assign result_out  [oc] = pe_psum  [ROWS-1][oc];
            assign result_valid[oc] = pe_valid [ROWS-1][oc];
        end
    endgenerate

    // Winograd stub: pass-through when PIPELINE_TYPE=0
    generate
        genvar xc;
        for (xc = 0; xc < COLS; xc = xc+1) begin : g_xform_out
            assign xform_out[xc] = result_out[xc];
        end
    endgenerate

    // =========================================================================
    // Performance counter
    // =========================================================================
    //  PM_IDLE    : waiting for first en
    //  PM_RUNNING : counting from first en; stops when all columns have fired
    //  PM_DONE    : frozen until clear_acc
    //
    localparam PM_IDLE    = 2'd0;
    localparam PM_RUNNING = 2'd1;
    localparam PM_DONE    = 2'd2;

    reg [1:0]        pm_state;
    reg [COLS-1:0]   col_seen;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pm_state    <= PM_IDLE;
            perf_cycles <= 32'd0;
            perf_valid  <= 1'b0;
            col_seen    <= {COLS{1'b0}};
        end else begin
            case (pm_state)
                PM_IDLE: begin
                    perf_valid  <= 1'b0;
                    perf_cycles <= 32'd0;
                    col_seen    <= {COLS{1'b0}};
                    if (en) begin
                        pm_state    <= PM_RUNNING;
                        perf_cycles <= 32'd1;
                    end
                end

                PM_RUNNING: begin
                    perf_cycles <= perf_cycles + 32'd1;
                    begin : blk_col_track
                        integer cs;
                        for (cs = 0; cs < COLS; cs = cs+1)
                            if (result_valid[cs]) col_seen[cs] <= 1'b1;
                    end
                    if (&(col_seen | result_valid)) begin
                        pm_state    <= PM_DONE;
                        perf_valid  <= 1'b1;
                    end
                end

                PM_DONE: begin
                    if (clear_acc) begin
                        pm_state    <= PM_IDLE;
                        perf_valid  <= 1'b0;
                        perf_cycles <= 32'd0;
                        col_seen    <= {COLS{1'b0}};
                    end
                end

                default: pm_state <= PM_IDLE;
            endcase
        end
    end

endmodule