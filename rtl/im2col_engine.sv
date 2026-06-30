// =============================================================================
// im2col_engine.sv  —  CR-3: convolution lowering front-end (one input channel)
// =============================================================================
//
//  Lowers a conv into GEMM activation columns, reusing overlapping pixels via
//  the K-row line_buffer. Per output position it emits the flattened K*K window
//  (one input channel) as one lowered activation column; the systolic GEMM then
//  multiplies it by the lowered C_in*K*K × C_out weight matrix staged by CR-2.
//  Channel reduction (C_in tiles) is handled by repeating a pass per channel
//  tile and accumulating in the array — driven by the FSM / tile controller.
//
//  Locality: per output-row band only S new input rows are loaded; the other
//  K-S rows are reused from the line buffer (bank rotation), and within a band
//  all OW windows reuse the same buffered rows. → each pixel fetched ~once per
//  band (CR-3 acceptance).
//
//  Modes:
//    K=1, STRIDE=1, PAD=0  → degenerate im2col = pass-through (1×1 conv).
//    K=3                   → dominant YOLO26n 3×3 kernel.
//  STRIDE and PAD are runtime (cfg_stride/cfg_pad); K is a build parameter
//  (= line_buffer banks). Square kernel assumed (KH=KW=K).
//
//  Index math is signed so PAD pulls window indices negative → OOB → 0.
//
//  ⚠ Highest-regression-risk block (off-by-one in nested geometry). Gate with
//    the CR-3 directed bit-exact test (HW vs software im2col) before trusting.
// =============================================================================

`timescale 1ns/1ps

module im2col_engine #(
    parameter integer DATA_W    = 8,
    parameter integer IMG_W_MAX = 640,
    parameter integer K         = 3,
    parameter integer XW        = $clog2(IMG_W_MAX),
    parameter integer DIMW      = 16            // feature-map dimension width
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // ── Run control / geometry (latched at start) ────────────────────────────
    input  wire                       start,
    input  wire [DIMW-1:0]            cfg_img_w,    // input width  W
    input  wire [DIMW-1:0]            cfg_img_h,    // input height H
    input  wire [3:0]                 cfg_stride,   // S  (>=1)
    input  wire [3:0]                 cfg_pad,      // P
    output reg                        busy,
    output reg                        done,

    // ── Pushed raster pixel input (one channel) ──────────────────────────────
    input  wire                       in_valid,
    input  wire signed [DATA_W-1:0]   in_data,
    output wire                       in_ready,

    // ── Lowered activation-column output (K*K elements) ──────────────────────
    output reg                        col_valid,
    output reg  signed [DATA_W-1:0]   col_data [0:K*K-1],
    input  wire                       col_ready
);

    // -------------------------------------------------------------------------
    // Geometry registers (latched on start)
    // -------------------------------------------------------------------------
    reg [DIMW-1:0] img_w, img_h;
    reg [3:0]      stride, pad;
    reg [DIMW-1:0] ow, oh;             // output dims

    // -------------------------------------------------------------------------
    // Line buffer
    // -------------------------------------------------------------------------
    reg                       lb_wr_en;
    reg  [$clog2(K)-1:0]      lb_wr_row;
    reg  [XW-1:0]             lb_wr_x;
    reg  signed [DATA_W-1:0]  lb_wr_data;
    reg                       lb_rd_en;
    reg  [XW-1:0]             lb_rd_x;
    wire signed [DATA_W-1:0]  lb_col_pix [0:K-1];
    wire                      lb_rd_valid;

    line_buffer #(
        .DATA_W(DATA_W), .IMG_W_MAX(IMG_W_MAX), .KH(K)
    ) u_lb (
        .clk(clk), .rst_n(rst_n),
        .wr_en(lb_wr_en), .wr_row(lb_wr_row), .wr_x(lb_wr_x), .wr_data(lb_wr_data),
        .rd_en(lb_rd_en), .rd_x(lb_rd_x), .col_pix(lb_col_pix), .rd_valid(lb_rd_valid)
    );

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0,
                     S_LOAD = 3'd1,   // accept raster pixels for needed rows
                     S_EMITX= 3'd2,   // emit windows across one output row band
                     S_RD   = 3'd3,   // wait line-buffer read latency
                     S_PUSH = 3'd4,   // drive col_valid, wait col_ready
                     S_NEXT = 3'd5,   // advance band
                     S_DONE = 3'd6;

    reg [2:0]       state;
    reg [DIMW-1:0]  in_row, in_col;        // raster position being loaded
    reg [DIMW-1:0]  rows_loaded;           // total input rows written so far
    reg signed [DIMW:0] oy, ox;            // current output position
    reg [$clog2(K)-1:0] kx;                // window column index being gathered
    reg signed [DATA_W-1:0] win [0:K*K-1]; // window assembly buffer

    // Highest real input row referenced by output band oy = oy*S - P + (K-1)
    wire signed [DIMW+4:0] band_top_row = $signed({1'b0,oy[DIMW-1:0]}) * $signed({1'b0,stride})
                                          - $signed({1'b0,pad}) + (K-1);
    // Need rows_loaded to cover min(band_top_row, img_h-1)+1
    wire signed [DIMW+4:0] need_rows = (band_top_row >= $signed({1'b0,img_h})) ?
                                       $signed({1'b0,img_h}) : (band_top_row + 1);

    assign in_ready = (state == S_LOAD);

    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            in_row <= 0; in_col <= 0; rows_loaded <= 0;
            oy <= 0; ox <= 0; kx <= 0;
            col_valid <= 1'b0;
            lb_wr_en <= 1'b0; lb_rd_en <= 1'b0;
        end else begin
            lb_wr_en <= 1'b0;
            lb_rd_en <= 1'b0;
            done     <= 1'b0;

            case (state)
                // -----------------------------------------------------------------
                S_IDLE: begin
                    col_valid <= 1'b0;
                    if (start) begin
                        img_w  <= cfg_img_w;  img_h <= cfg_img_h;
                        stride <= (cfg_stride==0) ? 4'd1 : cfg_stride;
                        pad    <= cfg_pad;
                        // OW = (W + 2P - K)/S + 1 ; OH likewise
                        ow <= ((cfg_img_w + 2*cfg_pad - K) /
                               ((cfg_stride==0)?16'd1:cfg_stride)) + 1;
                        oh <= ((cfg_img_h + 2*cfg_pad - K) /
                               ((cfg_stride==0)?16'd1:cfg_stride)) + 1;
                        in_row <= 0; in_col <= 0; rows_loaded <= 0;
                        oy <= 0; ox <= 0; kx <= 0;
                        busy <= 1'b1;
                        state <= S_LOAD;
                    end
                end

                // -----------------------------------------------------------------
                // Load raster pixels until the current band's input rows are present
                S_LOAD: begin
                    if ($signed({1'b0,rows_loaded}) >= need_rows) begin
                        state <= S_EMITX;
                        ox <= 0; kx <= 0;
                    end else if (in_valid) begin
                        lb_wr_en   <= 1'b1;
                        lb_wr_row  <= (in_row % K);               // bank = row mod K
                        lb_wr_x    <= in_col[XW-1:0];
                        lb_wr_data <= in_data;
                        if (in_col == img_w-1) begin
                            in_col      <= 0;
                            in_row      <= in_row + 1;
                            rows_loaded <= rows_loaded + 1;
                        end else begin
                            in_col <= in_col + 1;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // For output position (oy,ox): gather K*K window, kx column at a time
                S_EMITX: begin
                    // issue a vertical-slice read at ix = ox*S - P + kx
                    begin : issue_rd
                        reg signed [DIMW+4:0] ix;
                        ix = $signed({1'b0,ox[DIMW-1:0]}) * $signed({1'b0,stride})
                             - $signed({1'b0,pad}) + $signed({{(DIMW+1){1'b0}},kx});
                        if (ix >= 0 && ix < $signed({1'b0,img_w})) begin
                            lb_rd_en <= 1'b1;
                            lb_rd_x  <= ix[XW-1:0];
                        end else begin
                            lb_rd_en <= 1'b0;     // OOB column → zeros (handled in S_RD)
                        end
                    end
                    state <= S_RD;
                end

                // -----------------------------------------------------------------
                // Capture the slice (1-cycle line-buffer latency) into win[]
                S_RD: begin
                    begin : capture
                        reg signed [DIMW+4:0] ix;
                        reg signed [DIMW+4:0] iy;
                        integer ky;
                        ix = $signed({1'b0,ox[DIMW-1:0]}) * $signed({1'b0,stride})
                             - $signed({1'b0,pad}) + $signed({{(DIMW+1){1'b0}},kx});
                        for (ky = 0; ky < K; ky = ky + 1) begin
                            iy = $signed({1'b0,oy[DIMW-1:0]}) * $signed({1'b0,stride})
                                 - $signed({1'b0,pad}) + ky;
                            if (ix < 0 || ix >= $signed({1'b0,img_w}) ||
                                iy < 0 || iy >= $signed({1'b0,img_h}))
                                win[ky*K + kx] <= '0;                 // pad
                            else
                                // bank holding input row iy is (iy mod K)
                                win[ky*K + kx] <= lb_col_pix[iy % K];
                        end
                    end
                    if (kx == K-1) begin
                        kx <= 0;
                        state <= S_PUSH;
                    end else begin
                        kx <= kx + 1;
                        state <= S_EMITX;
                    end
                end

                // -----------------------------------------------------------------
                // Present the assembled window; advance on handshake
                S_PUSH: begin
                    col_valid <= 1'b1;
                    for (ii = 0; ii < K*K; ii = ii + 1) col_data[ii] <= win[ii];
                    if (col_valid && col_ready) begin
                        col_valid <= 1'b0;
                        if (ox == ow-1) state <= S_NEXT;   // band finished
                        else begin ox <= ox + 1; kx <= 0; state <= S_EMITX; end
                    end
                end

                // -----------------------------------------------------------------
                S_NEXT: begin
                    if (oy == oh-1) begin
                        state <= S_DONE;
                    end else begin
                        oy    <= oy + 1;
                        ox    <= 0; kx <= 0;
                        // Next band needs up to S more input rows; bank rotation is
                        // automatic (bank = row mod K), so just go reload.
                        state <= S_LOAD;
                    end
                end

                // -----------------------------------------------------------------
                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
