// =============================================================================
// tb_system_top_bram.sv  —  Integration test of the NEW BRAM/DSP datapath
//   Run: iverilog -g2012 -o tb ../rtl/*.sv tb_system_top_bram.sv && vvp tb
//   (exclude the other tb_*.sv; compile rtl + this file only)
//
//  system_top #(.ARRAY_SIZE(4), .USE_BRAM_PATH(1)). Exercises CR-1 (activation
//  BRAM), CR-2 (weight preload → shadow load → 1-cycle swap), CR-4 (DSP PE).
//  Identity weights + constant activation 2 ⇒ every array column result = 2.
//  Checked on the raw INT32 observability bus output_data (race-free vs the
//  drain handshake; the INT8 drain path is covered by tb_bram_out_buffer).
// =============================================================================

`timescale 1ns/1ps

module tb_system_top_bram;
    localparam integer ARRAY_SIZE = 4;
    localparam integer DATA_WIDTH = 8;
    localparam integer ADDR_WIDTH = 64;
    localparam integer AXI_DATA_W = 32;
    localparam integer ACCUM_WIDTH= 32;
    localparam         CLK_PERIOD = 10;

    localparam [7:0] REG_CTRL    = 8'h00;
    localparam [7:0] REG_IMG_DIM = 8'h10;

    reg clk = 0; always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    reg                      s_awvalid; wire s_awready;
    reg  [ADDR_WIDTH-1:0]    s_awaddr;
    reg                      s_wvalid;  wire s_wready;
    reg  [AXI_DATA_W-1:0]    s_wdata;
    reg  [AXI_DATA_W/8-1:0]  s_wstrb;
    wire                     s_bvalid;  reg  s_bready;
    wire [1:0]               s_bresp;
    reg                      s_arvalid; wire s_arready;
    reg  [ADDR_WIDTH-1:0]    s_araddr;
    wire                     s_rvalid;  reg  s_rready;
    wire [AXI_DATA_W-1:0]    s_rdata;
    wire [1:0]               s_rresp;

    reg  signed [DATA_WIDTH-1:0] input_data [0:ARRAY_SIZE-1];
    wire signed [ARRAY_SIZE*ACCUM_WIDTH-1:0] output_data;
    wire [31:0]              perf_cycles;
    wire                     perf_valid;
    wire [ARRAY_SIZE-1:0]    result_valid;
    wire signed [DATA_WIDTH-1:0] out_vec [0:ARRAY_SIZE-1];
    wire                     out_rd_valid;
    wire                     loading_weights, streaming_acts, sys_busy, sys_done;
    wire [31:0]              src_addr, dst_addr, weight_addr;

    integer error_count = 0;

    system_top #(.ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH),
                 .ADDR_WIDTH(ADDR_WIDTH), .AXI_DATA_W(AXI_DATA_W),
                 .ACCUM_WIDTH(ACCUM_WIDTH), .USE_BRAM_PATH(1),
                 .ACT_DEPTH(64), .OUT_DEPTH(64)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
        .s_wvalid(s_wvalid), .s_wready(s_wready), .s_wdata(s_wdata), .s_wstrb(s_wstrb),
        .s_bvalid(s_bvalid), .s_bready(s_bready), .s_bresp(s_bresp),
        .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
        .s_rvalid(s_rvalid), .s_rready(s_rready), .s_rdata(s_rdata), .s_rresp(s_rresp),
        .input_data(input_data), .output_data(output_data),
        .perf_cycles(perf_cycles), .perf_valid(perf_valid), .result_valid(result_valid),
        .out_vec(out_vec), .out_rd_valid(out_rd_valid),
        .loading_weights(loading_weights), .streaming_acts(streaming_acts),
        .sys_busy(sys_busy), .sys_done(sys_done),
        .src_addr(src_addr), .dst_addr(dst_addr), .weight_addr(weight_addr));

    // Data-source model: identity weight rows during preload, constant act 2 else.
    reg [15:0] load_idx; integer di;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               load_idx <= 0;
        else if (loading_weights) load_idx <= load_idx + 1;
        else                      load_idx <= 0;
    end
    always @(*) begin
        for (di=0; di<ARRAY_SIZE; di=di+1) input_data[di] = 8'sd2;  // activations
        if (loading_weights) begin
            for (di=0; di<ARRAY_SIZE; di=di+1) input_data[di] = 8'sd0;
            input_data[load_idx] = 8'sd1;                           // identity row
        end
    end

    task axi_write(input [ADDR_WIDTH-1:0] addr, input [AXI_DATA_W-1:0] data);
        begin
            @(negedge clk);
            s_awaddr=addr; s_wdata=data; s_wstrb=4'hF; s_awvalid=1; s_wvalid=1;
            do @(posedge clk); while (!(s_awready && s_wready));
            @(negedge clk); s_awvalid=0; s_wvalid=0; s_bready=1;
            do @(posedge clk); while (!s_bvalid);
            @(negedge clk); s_bready=0;
        end
    endtask

    integer c; reg signed [31:0] val;
    initial begin
        $dumpfile("tb_system_top_bram.vcd"); $dumpvars(0, tb_system_top_bram);
        s_awvalid=0; s_awaddr=0; s_wvalid=0; s_wdata=0; s_wstrb=4'hF;
        s_bready=0; s_arvalid=0; s_araddr=0; s_rready=0;
        for (di=0; di<ARRAY_SIZE; di=di+1) input_data[di]=0;

        rst_n=0; repeat(5) @(posedge clk); @(negedge clk); rst_n=1; repeat(2) @(posedge clk);

        // IMG_DIM rows=4 (K activation vectors), cols=4 → 0x0004_0004
        axi_write({56'h0, REG_IMG_DIM}, 32'h0004_0004);
        // START
        axi_write({56'h0, REG_CTRL}, 32'h0000_0001);

        wait (sys_done === 1'b1);
        repeat(4) @(posedge clk);

        // identity * act(2) ⇒ each column = 2 on the raw INT32 bus
        for (c=0; c<ARRAY_SIZE; c=c+1) begin
            val = output_data[c*ACCUM_WIDTH +: ACCUM_WIDTH];
            if (val !== 32'sd2) begin
                $display("  FAIL col[%0d] expected=2 got=%0d", c, val);
                error_count = error_count + 1;
            end
        end

        $display("\n========================================");
        if (error_count==0) $display("  SYSTEM_TOP_BRAM TEST: PASSED (%0d cols = 2)", ARRAY_SIZE);
        else                $display("  SYSTEM_TOP_BRAM TEST: FAILED (%0d errors)", error_count);
        $display("  perf_cycles=%0d", perf_cycles);
        $display("========================================\n");
        $finish;
    end

    initial begin #(CLK_PERIOD*20000); $display("BRAM TOP WATCHDOG (state stuck?)"); $finish; end
endmodule
