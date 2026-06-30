// =============================================================================
// tb_system_top.sv  —  Self-checking testbench for system_top
// Simulator: Icarus Verilog (iverilog -g2012)
//
//  Exercises the full auto-sequencing flow:
//    1. CPU programs IMG_DIM (K = #activation vectors) over AXI4-Lite
//    2. CPU writes CTRL[0]=START
//    3. FSM loads an identity weight matrix (driven on input_data during the
//       loading_weights phase) and latches it
//    4. FSM streams constant activations (=2) during the streaming_acts phase
//    5. TB waits for sys_done and checks output_data[c] == 2 for every column
// =============================================================================

`timescale 1ns/1ps

module tb_system_top;

    localparam integer ARRAY_SIZE = 32;
    localparam integer DATA_WIDTH = 8;
    localparam integer ADDR_WIDTH = 64;
    localparam integer AXI_DATA_W = 32;
    localparam         CLK_PERIOD = 10;

    // Register offsets (mirror axi4_lite_slave)
    localparam [7:0] REG_CTRL    = 8'h00;
    localparam [7:0] REG_IMG_DIM = 8'h10;

    // =========================================================================
    // Clock / reset
    // =========================================================================
    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    // =========================================================================
    // AXI4-Lite signals
    // =========================================================================
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

    // =========================================================================
    // Datapath / status
    // =========================================================================
    reg  signed [DATA_WIDTH-1:0] input_data [0:ARRAY_SIZE-1];
    wire signed [1023:0]         output_data;
    wire [31:0]                  perf_cycles;
    wire                         perf_valid;
    wire [31:0]                  result_valid;
    wire                         loading_weights;
    wire                         streaming_acts;
    wire                         sys_busy;
    wire                         sys_done;
    wire [31:0]                  src_addr, dst_addr, weight_addr;

    integer error_count = 0;

    // =========================================================================
    // DUT
    // =========================================================================
    system_top #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .AXI_DATA_W(AXI_DATA_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
        .s_wvalid(s_wvalid), .s_wready(s_wready), .s_wdata(s_wdata), .s_wstrb(s_wstrb),
        .s_bvalid(s_bvalid), .s_bready(s_bready), .s_bresp(s_bresp),
        .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
        .s_rvalid(s_rvalid), .s_rready(s_rready), .s_rdata(s_rdata), .s_rresp(s_rresp),
        .input_data(input_data),
        .output_data(output_data),
        .perf_cycles(perf_cycles),
        .perf_valid(perf_valid),
        .result_valid(result_valid),
        .loading_weights(loading_weights),
        .streaming_acts(streaming_acts),
        .sys_busy(sys_busy),
        .sys_done(sys_done),
        .src_addr(src_addr), .dst_addr(dst_addr), .weight_addr(weight_addr)
    );

    // =========================================================================
    // Data-source model: the FSM drives the phase strobes; this block presents
    // the matching bytes on input_data (no DMA exists in the DV set).
    //   loading_weights : present identity-matrix row `load_idx`
    //   streaming_acts  : present constant activation 2 on every lane
    // =========================================================================
    reg [15:0] load_idx;
    integer    di;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               load_idx <= 16'd0;
        else if (loading_weights) load_idx <= load_idx + 16'd1;
        else                      load_idx <= 16'd0;
    end

    always @(*) begin
        for (di = 0; di < ARRAY_SIZE; di = di + 1) input_data[di] = 8'sd0;
        if (loading_weights)
            input_data[load_idx] = 8'sd1;          // identity row
        else if (streaming_acts)
            for (di = 0; di < ARRAY_SIZE; di = di + 1) input_data[di] = 8'sd2;
    end

    // =========================================================================
    // AXI4-Lite BFM
    // =========================================================================
    task axi_write(input [ADDR_WIDTH-1:0] addr, input [AXI_DATA_W-1:0] data);
        begin
            @(negedge clk);
            s_awaddr = addr; s_wdata = data; s_wstrb = 4'hF;
            s_awvalid = 1'b1; s_wvalid = 1'b1;
            do @(posedge clk); while (!(s_awready && s_wready));
            @(negedge clk); s_awvalid = 1'b0; s_wvalid = 1'b0; s_bready = 1'b1;
            do @(posedge clk); while (!s_bvalid);
            @(negedge clk); s_bready = 1'b0;
        end
    endtask

    // =========================================================================
    // Main test
    // =========================================================================
    integer pe_idx;
    reg signed [31:0] actual_val;
    localparam signed [31:0] EXPECTED = 32'sd2; // act(2) * identity(1)

    initial begin
        $dumpfile("tb_system_top.vcd");
        $dumpvars(0, tb_system_top);

        // Idle AXI
        s_awvalid=0; s_awaddr=0; s_wvalid=0; s_wdata=0; s_wstrb=4'hF;
        s_bready=0; s_arvalid=0; s_araddr=0; s_rready=0;
        for (di=0; di<ARRAY_SIZE; di=di+1) input_data[di]=0;

        // Reset
        rst_n = 0;
        repeat (5) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (2) @(posedge clk);

        // Program K = 96 activation vectors (rows), cols = 32
        // IMG_DIM = {rows[31:16], cols[15:0]} = 0x0060_0020
        $display("[%0t] Configuring IMG_DIM (K=96)...", $time);
        axi_write({56'h0, REG_IMG_DIM}, 32'h0060_0020);

        // Kick off the run
        $display("[%0t] Writing START...", $time);
        axi_write({56'h0, REG_CTRL}, 32'h0000_0001);

        // Wait for the FSM to finish the whole sequence
        $display("[%0t] Waiting for sys_done...", $time);
        wait (sys_done === 1'b1);
        $display("[%0t] sys_done asserted. perf_cycles=%0d", $time, perf_cycles);

        // Let the final results settle on output_data
        repeat (4) @(posedge clk);

        // Check every column output
        for (pe_idx = 0; pe_idx < ARRAY_SIZE; pe_idx = pe_idx + 1) begin
            actual_val = output_data[(pe_idx*32) +: 32];
            if (actual_val !== EXPECTED) begin
                $display("  FAIL PE[%0d] expected=%0d got=%0d", pe_idx, EXPECTED, actual_val);
                error_count = error_count + 1;
            end
        end

        $display("\n========================================");
        if (error_count == 0)
            $display("  SYSTEM TOP TEST: PASSED (32/32 columns = 2)");
        else
            $display("  SYSTEM TOP TEST: FAILED (%0d errors)", error_count);
        $display("========================================\n");
        $finish;
    end

    // Watchdog
    initial begin
        #(CLK_PERIOD * 8000);
        $display("[%0t] ERROR: Watchdog timeout (sys_done never asserted)", $time);
        $finish;
    end

endmodule
