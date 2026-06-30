// =============================================================================
// tb_im2col_engine.sv  —  CR-3: HW im2col vs software golden (bit-exact)
//   Run: iverilog -g2012 -o tb ../rtl/line_buffer.sv ../rtl/im2col_engine.sv \
//                              tb_im2col_engine.sv && vvp tb
//
//  4×4 input, 3×3 kernel, stride 1, pad 1 → 4×4 = 16 output positions, each a
//  9-element lowered column. The TB:
//    - acts as the raster pixel producer (in_valid/in_data) and the column
//      consumer (col_valid/col_ready),
//    - precomputes the software im2col golden (OOB→0),
//    - checks every emitted window in order (oy outer, ox inner).
// =============================================================================

`timescale 1ns/1ps

module tb_im2col_engine;
    localparam integer DATA_W = 8;
    localparam integer K      = 3;
    localparam integer IW = 4, IH = 4, S = 1, P = 1;
    localparam integer OW = (IW + 2*P - K)/S + 1;   // 4
    localparam integer OH = (IH + 2*P - K)/S + 1;   // 4
    localparam integer NPOS = OW*OH;                // 16
    localparam         CLK_PERIOD = 10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                       start;
    reg  [15:0]               cfg_img_w, cfg_img_h;
    reg  [3:0]                cfg_stride, cfg_pad;
    wire                      busy, done;
    reg                       in_valid;
    reg  signed [DATA_W-1:0]  in_data;
    wire                      in_ready;
    wire                      col_valid;
    wire signed [DATA_W-1:0]  col_data [0:K*K-1];
    reg                       col_ready;

    im2col_engine #(.DATA_W(DATA_W), .IMG_W_MAX(64), .K(K)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .cfg_img_w(cfg_img_w), .cfg_img_h(cfg_img_h),
        .cfg_stride(cfg_stride), .cfg_pad(cfg_pad), .busy(busy), .done(done),
        .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
        .col_valid(col_valid), .col_data(col_data), .col_ready(col_ready));

    // image + golden
    reg signed [DATA_W-1:0] img [0:IH-1][0:IW-1];
    reg signed [DATA_W-1:0] g   [0:NPOS*K*K-1];
    integer pass_cnt = 0, fail_cnt = 0;
    integer r, c, oy, ox, ky, kx, iy, ix, pos, e;

    // ---- producer (raster pixels) ----
    reg [31:0] praster;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) praster <= 0;
        else if (in_ready && in_valid) praster <= praster + 1;
    end
    always @(*) begin
        in_valid = (praster < IW*IH);
        in_data  = (praster < IW*IH) ? img[praster / IW][praster % IW] : 8'sd0;
    end

    // ---- consumer (collect windows in emit order) ----
    reg [31:0] ccount;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ccount <= 0;
        else if (col_valid && col_ready) begin
            for (e = 0; e < K*K; e = e + 1) begin
                if (col_data[e] === g[ccount*K*K + e]) pass_cnt = pass_cnt + 1;
                else begin
                    $display("  FAIL pos=%0d elem=%0d got=%0d exp=%0d",
                             ccount, e, col_data[e], g[ccount*K*K + e]);
                    fail_cnt = fail_cnt + 1;
                end
            end
            ccount <= ccount + 1;
        end
    end

    initial begin
        $dumpfile("tb_im2col_engine.vcd"); $dumpvars(0, tb_im2col_engine);
        start=0; cfg_img_w=IW; cfg_img_h=IH; cfg_stride=S; cfg_pad=P;
        in_valid=0; in_data=0; col_ready=1;

        // image: img[r][c] = r*IW + c + 1
        for (r=0;r<IH;r=r+1) for (c=0;c<IW;c=c+1) img[r][c] = r*IW + c + 1;

        // software golden im2col (OOB → 0), order oy outer / ox inner
        for (oy=0; oy<OH; oy=oy+1)
          for (ox=0; ox<OW; ox=ox+1) begin
            pos = oy*OW + ox;
            for (ky=0; ky<K; ky=ky+1)
              for (kx=0; kx<K; kx=kx+1) begin
                iy = oy*S - P + ky;
                ix = ox*S - P + kx;
                if (iy>=0 && iy<IH && ix>=0 && ix<IW)
                    g[pos*K*K + ky*K + kx] = img[iy][ix];
                else
                    g[pos*K*K + ky*K + kx] = 0;
              end
          end

        rst_n=0; repeat(4) @(posedge clk); @(negedge clk); rst_n=1; repeat(2) @(posedge clk);

        // kick off
        @(negedge clk); start=1; @(negedge clk); start=0;

        // wait until all windows consumed
        wait (ccount == NPOS);
        repeat(2) @(posedge clk);

        $display("\n==================================");
        $display("  IM2COL TB: Passed=%0d Failed=%0d (windows=%0d)", pass_cnt, fail_cnt, ccount);
        if (fail_cnt==0) $display("  ALL IM2COL TESTS PASSED");
        else             $display("  IM2COL TESTS FAILED");
        $display("==================================");
        $finish;
    end
    initial begin #(CLK_PERIOD*40000); $display("IM2COL WATCHDOG (ccount=%0d)", ccount); $finish; end
endmodule
