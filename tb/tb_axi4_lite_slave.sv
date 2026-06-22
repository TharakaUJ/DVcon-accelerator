// tb_axi4_lite_slave.sv — self-checking testbench for axi4_lite_slave
// Simulator: Icarus Verilog (iverilog -g2012)
// Waveform:  GTKWave (build/axi4_lite_slave_wave.vcd)

`timescale 1ns/1ps

module tb_axi4_lite_slave;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam int ADDR_WIDTH = 64;
    localparam int DATA_WIDTH = 32;

    // Register offsets
    localparam logic [7:0] REG_CTRL        = 8'h00;
    localparam logic [7:0] REG_STATUS      = 8'h04;
    localparam logic [7:0] REG_SRC_ADDR    = 8'h08;
    localparam logic [7:0] REG_DST_ADDR    = 8'h0C;
    localparam logic [7:0] REG_IMG_DIM     = 8'h10;
    localparam logic [7:0] REG_WEIGHT_ADDR = 8'h14;

    // =========================================================================
    // Clock & reset
    // =========================================================================
    logic clk = 0;
    always #10 clk = ~clk; // 50 MHz

    logic rst_n;

    // =========================================================================
    // AXI4-Lite signals
    // =========================================================================
    logic                    s_awvalid, s_awready;
    logic [ADDR_WIDTH-1:0]   s_awaddr;
    logic                    s_wvalid,  s_wready;
    logic [DATA_WIDTH-1:0]   s_wdata;
    logic [DATA_WIDTH/8-1:0] s_wstrb;
    logic                    s_bvalid,  s_bready;
    logic [1:0]              s_bresp;
    logic                    s_arvalid, s_arready;
    logic [ADDR_WIDTH-1:0]   s_araddr;
    logic                    s_rvalid,  s_rready;
    logic [DATA_WIDTH-1:0]   s_rdata;
    logic [1:0]              s_rresp;

    // =========================================================================
    // Accelerator status inputs (driven by testbench)
    // =========================================================================
    logic        busy      = 0;
    logic        done      = 0;
    logic        error     = 0;
    logic [3:0]  fsm_state = 4'h0;

    // =========================================================================
    // Accelerator control outputs (observed by testbench)
    // =========================================================================
    logic        start_pulse;
    logic        soft_reset;
    logic [31:0] src_addr;
    logic [31:0] dst_addr;
    logic [15:0] img_rows;
    logic [15:0] img_cols;
    logic [31:0] weight_addr;

    // =========================================================================
    // DUT
    // =========================================================================
    axi4_lite_slave #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_awvalid     (s_awvalid),
        .s_awready     (s_awready),
        .s_awaddr      (s_awaddr),
        .s_wvalid      (s_wvalid),
        .s_wready      (s_wready),
        .s_wdata       (s_wdata),
        .s_wstrb       (s_wstrb),
        .s_bvalid      (s_bvalid),
        .s_bready      (s_bready),
        .s_bresp       (s_bresp),
        .s_arvalid     (s_arvalid),
        .s_arready     (s_arready),
        .s_araddr      (s_araddr),
        .s_rvalid      (s_rvalid),
        .s_rready      (s_rready),
        .s_rdata       (s_rdata),
        .s_rresp       (s_rresp),
        .start_pulse   (start_pulse),
        .soft_reset    (soft_reset),
        .src_addr      (src_addr),
        .dst_addr      (dst_addr),
        .img_rows      (img_rows),
        .img_cols      (img_cols),
        .weight_addr   (weight_addr),
        .busy          (busy),
        .done          (done),
        .error         (error),
        .fsm_state     (fsm_state)
    );

    // =========================================================================
    // VCD dump
    // =========================================================================
    initial begin
        $dumpfile("build/axi4_lite_slave_wave.vcd");
        $dumpvars(0, tb_axi4_lite_slave);
    end

    // =========================================================================
    // start_pulse capture — latch the 1-cycle pulse so we can check it
    // =========================================================================
    logic start_seen;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)           start_seen <= 1'b0;
        else if (start_pulse) start_seen <= 1'b1;
    end

    task automatic clear_start_seen;
        @(negedge clk);
    endtask

    // =========================================================================
    // Score tracking
    // =========================================================================
    int pass_count = 0;
    int fail_count = 0;

    task automatic check(
        input string    label,
        input logic [31:0] got,
        input logic [31:0] expected
    );
        if (got === expected) begin
            $display("PASS  %-35s  expected=0x%08X  got=0x%08X", label, expected, got);
            pass_count++;
        end else begin
            $display("FAIL  %-35s  expected=0x%08X  got=0x%08X", label, expected, got);
            fail_count++;
        end
    endtask

    // =========================================================================
    // AXI-Lite BFM — write transaction
    // Drives AW and W simultaneously (most common CPU behaviour)
    // =========================================================================
    task automatic axi_write(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] data
    );
        // Present AW and W in the same cycle
        @(negedge clk);
        s_awaddr  = addr;
        s_wdata   = data;
        s_wstrb   = 4'hF;
        s_awvalid = 1'b1;
        s_wvalid  = 1'b1;

        // Wait for both handshakes (may take multiple cycles)
        fork
            begin : aw_wait
                while (!(s_awvalid && s_awready)) @(posedge clk);
                @(negedge clk);
                s_awvalid = 1'b0;
            end
            begin : w_wait
                while (!(s_wvalid && s_wready)) @(posedge clk);
                @(negedge clk);
                s_wvalid = 1'b0;
            end
        join

        // Wait for write response
        @(negedge clk);
        s_bready = 1'b1;
        while (!(s_bvalid && s_bready)) @(posedge clk);
        @(negedge clk);
        s_bready = 1'b0;
    endtask

    // =========================================================================
    // AXI-Lite BFM — read transaction
    // =========================================================================
    logic [31:0] read_data;

    task automatic axi_read(
        input  logic [ADDR_WIDTH-1:0] addr,
        output logic [DATA_WIDTH-1:0] data
    );
        @(negedge clk);
        s_araddr  = addr;
        s_arvalid = 1'b1;

        // Wait for AR handshake
        while (!(s_arvalid && s_arready)) @(posedge clk);
        @(negedge clk);
        s_arvalid = 1'b0;

        // Wait for read data
        s_rready = 1'b1;
        while (!(s_rvalid && s_rready)) @(posedge clk);
        data = s_rdata;
        @(negedge clk);
        s_rready = 1'b0;
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    initial begin
        // Idle all AXI signals
        s_awvalid = 0; s_awaddr  = '0;
        s_wvalid  = 0; s_wdata   = '0; s_wstrb = 4'hF;
        s_bready  = 0;
        s_arvalid = 0; s_araddr  = '0;
        s_rready  = 0;

        // Reset
        rst_n = 0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        // TEST GROUP 1: Check reset/default values
        // ------------------------------------------------------------------
        $display("\n--- Reset default values ---");
        axi_read(REG_CTRL,        read_data); check("CTRL default",        read_data, 32'h0000_0000);
        axi_read(REG_SRC_ADDR,    read_data); check("SRC_ADDR default",    read_data, 32'h8000_0000);
        axi_read(REG_DST_ADDR,    read_data); check("DST_ADDR default",    read_data, 32'h8100_0000);
        axi_read(REG_IMG_DIM,     read_data); check("IMG_DIM default",     read_data, 32'h0020_0020);
        axi_read(REG_WEIGHT_ADDR, read_data); check("WEIGHT_ADDR default", read_data, 32'h8080_0000);

        // ------------------------------------------------------------------
        // TEST GROUP 2: CPU write sequence from spec (Section 5 of Claude.md)
        // ------------------------------------------------------------------
        $display("\n--- CPU config write sequence ---");
        axi_write(REG_SRC_ADDR,    32'h8000_4000);
        axi_write(REG_DST_ADDR,    32'h8100_4000);
        axi_write(REG_IMG_DIM,     32'h0010_0010); // 16x16
        axi_write(REG_WEIGHT_ADDR, 32'h8080_4000);

        axi_read(REG_SRC_ADDR,    read_data); check("SRC_ADDR write",    read_data, 32'h8000_4000);
        axi_read(REG_DST_ADDR,    read_data); check("DST_ADDR write",    read_data, 32'h8100_4000);
        axi_read(REG_IMG_DIM,     read_data); check("IMG_DIM write",     read_data, 32'h0010_0010);
        axi_read(REG_WEIGHT_ADDR, read_data); check("WEIGHT_ADDR write", read_data, 32'h8080_4000);

        // Check output ports reflect the written values
        check("src_addr port",    src_addr,             32'h8000_4000);
        check("dst_addr port",    dst_addr,             32'h8100_4000);
        check("img_rows port",    {16'h0, img_rows},    32'h0000_0010);
        check("img_cols port",    {16'h0, img_cols},    32'h0000_0010);
        check("weight_addr port", weight_addr,          32'h8080_4000);

        // ------------------------------------------------------------------
        // TEST GROUP 3: START pulse and self-clear
        // ------------------------------------------------------------------
        $display("\n--- START self-clear ---");
        axi_write(REG_CTRL, 32'h0000_0001); // write START=1

        // start_pulse is a 1-cycle pulse during the B-response cycle.
        // Check the latched flag rather than the live signal.
        @(posedge clk);
        check("start_pulse seen", {31'h0, start_seen}, 32'h0000_0001);

        // One cycle later it should self-clear
        @(posedge clk);
        check("start_pulse cleared", {31'h0, start_pulse}, 32'h0000_0000);

        // CTRL[0] should read back as 0
        axi_read(REG_CTRL, read_data);
        check("CTRL START cleared", read_data & 32'h1, 32'h0000_0000);

        // ------------------------------------------------------------------
        // TEST GROUP 4: STATUS is hardware-driven — writes ignored
        // ------------------------------------------------------------------
        $display("\n--- STATUS register protection ---");
        busy      = 1;
        done      = 0;
        error     = 0;
        fsm_state = 4'h3;
        @(posedge clk);

        axi_read(REG_STATUS, read_data);
        check("STATUS BUSY=1",      read_data & 32'h1,  32'h0000_0001);
        check("STATUS FSM_STATE=3", read_data & 32'hF0, 32'h0000_0030);

        // Try to corrupt STATUS via write — should be ignored
        axi_write(REG_STATUS, 32'hFFFF_FFFF);
        axi_read(REG_STATUS, read_data);
        check("STATUS write ignored BUSY", read_data & 32'h1,  32'h0000_0001);
        check("STATUS write ignored FSM",  read_data & 32'hF0, 32'h0000_0030);

        // ------------------------------------------------------------------
        // TEST GROUP 5: DONE pulse visible in STATUS
        // ------------------------------------------------------------------
        $display("\n--- DONE flag in STATUS ---");
        busy = 0;
        done = 1;
        @(posedge clk);
        axi_read(REG_STATUS, read_data);
        check("STATUS BUSY=0 DONE=1", read_data & 32'h3, 32'h0000_0002);
        done = 0;

        // ------------------------------------------------------------------
        // TEST GROUP 6: Byte strobe — partial word write
        // ------------------------------------------------------------------
        $display("\n--- Byte strobe partial write ---");
        axi_write(REG_SRC_ADDR, 32'hAABB_CCDD); // set known value first
        // Write only upper byte (strobe = 4'b1000)
        @(negedge clk);
        s_awaddr  = REG_SRC_ADDR;
        s_wdata   = 32'hFF00_0000;
        s_wstrb   = 4'b1000;       // only byte 3
        s_awvalid = 1'b1;
        s_wvalid  = 1'b1;
        fork
            begin while (!(s_awvalid && s_awready)) @(posedge clk); @(negedge clk); s_awvalid = 0; end
            begin while (!(s_wvalid  && s_wready))  @(posedge clk); @(negedge clk); s_wvalid  = 0; end
        join
        @(negedge clk); s_bready = 1;
        while (!(s_bvalid && s_bready)) @(posedge clk);
        @(negedge clk); s_bready = 0;

        axi_read(REG_SRC_ADDR, read_data);
        check("Byte strobe upper byte", read_data, 32'hFFBB_CCDD);

        repeat (4) @(posedge clk);

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
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
