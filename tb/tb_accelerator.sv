`timescale 1ns/1ps

module tb_accelerator;

    localparam integer CLK_PERIOD = 10;
    localparam logic [63:0] REG_CTRL        = 64'h0000_0000_0000_0000;
    localparam logic [63:0] REG_STATUS      = 64'h0000_0000_0000_0004;
    localparam logic [63:0] REG_SRC_ADDR    = 64'h0000_0000_0000_0008;
    localparam logic [63:0] REG_DST_ADDR    = 64'h0000_0000_0000_000C;
    localparam logic [63:0] REG_IMG_DIM     = 64'h0000_0000_0000_0010;
    localparam logic [63:0] REG_WEIGHT_ADDR = 64'h0000_0000_0000_0014;

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg rst_n;

    wire m_axi_awvalid;
    wire [11:0] m_axi_awid;
    wire [7:0] m_axi_awlen;
    wire [2:0] m_axi_awsize;
    wire [1:0] m_axi_awburst;
    wire [0:0] m_axi_awlock;
    wire [3:0] m_axi_awcache;
    wire [3:0] m_axi_awqos;
    wire [63:0] m_axi_awaddr;
    wire [2:0] m_axi_awprot;
    reg  m_axi_awready = 1'b1;

    wire m_axi_wvalid;
    wire m_axi_wlast;
    wire [63:0] m_axi_wdata;
    wire [7:0] m_axi_wstrb;
    reg  m_axi_wready = 1'b1;

    wire m_axi_bready;
    reg  m_axi_bvalid = 1'b0;
    reg  [11:0] m_axi_bid = 12'd0;
    reg  [1:0] m_axi_bresp = 2'b00;

    wire m_axi_arvalid;
    wire [11:0] m_axi_arid;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire [0:0] m_axi_arlock;
    wire [3:0] m_axi_arcache;
    wire [3:0] m_axi_arqos;
    wire [63:0] m_axi_araddr;
    wire [2:0] m_axi_arprot;
    reg  m_axi_arready = 1'b1;

    wire m_axi_rready;
    reg  m_axi_rvalid = 1'b0;
    reg  [11:0] m_axi_rid = 12'd0;
    reg  m_axi_rlast = 1'b0;
    reg  [1:0] m_axi_rresp = 2'b00;
    reg  [63:0] m_axi_rdata = 64'd0;

    wire s_axi_awready;
    wire s_axi_wready;
    wire s_axi_bvalid;
    wire [1:0] s_axi_bresp;
    wire s_axi_arready;
    wire s_axi_rvalid;
    wire [63:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire s_axi_rlast;

    wire s_axi_aclk = clk;
    reg  s_axi_aresetn;
    reg  s_axi_awid = 1'b0;
    reg  [63:0] s_axi_awaddr;
    reg  [7:0] s_axi_awlen;
    reg  [2:0] s_axi_awsize;
    reg  [1:0] s_axi_awburst;
    reg  s_axi_awlock = 1'b0;
    reg  [3:0] s_axi_awcache;
    reg  [2:0] s_axi_awprot;
    reg  [3:0] s_axi_awqos;
    reg  s_axi_awvalid;
    reg  s_axi_wdata;
    reg  [7:0] s_axi_wstrb;
    reg  s_axi_wlast;
    reg  s_axi_wvalid;
    reg  s_axi_bready;
    reg  s_axi_arid = 1'b0;
    reg  [63:0] s_axi_araddr;
    reg  [7:0] s_axi_arlen;
    reg  [2:0] s_axi_arsize;
    reg  [1:0] s_axi_arburst;
    reg  s_axi_arlock = 1'b0;
    reg  [3:0] s_axi_arcache;
    reg  [2:0] s_axi_arprot;
    reg  [3:0] s_axi_arqos;
    reg  s_axi_arvalid;
    reg  s_axi_rready;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    accelerator dut (
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awid    (m_axi_awid),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awlock  (m_axi_awlock),
        .m_axi_awcache (m_axi_awcache),
        .m_axi_awqos   (m_axi_awqos),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awprot  (m_axi_awprot),
        .m_axi_awready (m_axi_awready),

        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wready  (m_axi_wready),

        .m_axi_bready  (m_axi_bready),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bid     (m_axi_bid),
        .m_axi_bresp   (m_axi_bresp),

        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arid    (m_axi_arid),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arlock  (m_axi_arlock),
        .m_axi_arcache (m_axi_arcache),
        .m_axi_arqos   (m_axi_arqos),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arprot  (m_axi_arprot),
        .m_axi_arready (m_axi_arready),

        .m_axi_rready  (m_axi_rready),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rid     (m_axi_rid),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rdata   (m_axi_rdata),

        .s_axi_aclk    (s_axi_aclk),
        .s_axi_aresetn (s_axi_aresetn),
        .s_axi_awid    (s_axi_awid),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awlen   (s_axi_awlen),
        .s_axi_awsize  (s_axi_awsize),
        .s_axi_awburst (s_axi_awburst),
        .s_axi_awlock  (s_axi_awlock),
        .s_axi_awcache (s_axi_awcache),
        .s_axi_awprot  (s_axi_awprot),
        .s_axi_awqos   (s_axi_awqos),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),

        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wlast   (s_axi_wlast),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),

        .s_axi_bready  (s_axi_bready),
        .s_axi_bid     (),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),

        .s_axi_arid    (s_axi_arid),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arlen   (s_axi_arlen),
        .s_axi_arsize  (s_axi_arsize),
        .s_axi_arburst (s_axi_arburst),
        .s_axi_arlock  (s_axi_arlock),
        .s_axi_arcache (s_axi_arcache),
        .s_axi_arprot  (s_axi_arprot),
        .s_axi_arqos   (s_axi_arqos),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),

        .s_axi_rready  (s_axi_rready),
        .s_axi_rid     (),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rlast   (s_axi_rlast),
        .s_axi_rvalid  (s_axi_rvalid)
    );

    task check_bit;
        input [255:0] tag;
        input got;
        input exp;
        begin
            if (got === exp) begin
                $display("  PASS %s got=%0b", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %s got=%0b exp=%0b", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task check_word;
        input [255:0] tag;
        input [63:0] got;
        input [63:0] exp;
        begin
            if (got === exp) begin
                $display("  PASS %s got=0x%016h", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL %s got=0x%016h exp=0x%016h", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task axi_lite_write;
        input [63:0] addr;
        input bit data_bit;
        begin
            @(negedge s_axi_aclk);
            s_axi_awaddr  = addr;
            s_axi_awlen   = 8'd0;
            s_axi_awsize  = 3'd0;
            s_axi_awburst = 2'd0;
            s_axi_awcache = 4'd0;
            s_axi_awprot  = 3'd0;
            s_axi_awqos   = 4'd0;
            s_axi_awvalid = 1'b1;

            s_axi_wdata   = data_bit;
            s_axi_wstrb   = 8'h01;
            s_axi_wlast   = 1'b1;
            s_axi_wvalid  = 1'b1;

            fork
                begin
                    while (!(s_axi_awvalid && s_axi_awready)) @(posedge s_axi_aclk);
                    @(negedge s_axi_aclk);
                    s_axi_awvalid = 1'b0;
                end
                begin
                    while (!(s_axi_wvalid && s_axi_wready)) @(posedge s_axi_aclk);
                    @(negedge s_axi_aclk);
                    s_axi_wvalid = 1'b0;
                end
            join

            @(negedge s_axi_aclk);
            s_axi_bready = 1'b1;
            while (!(s_axi_bvalid && s_axi_bready)) @(posedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_bready = 1'b0;
        end
    endtask

    task axi_lite_read;
        input [63:0] addr;
        output bit data_bit;
        begin
            @(negedge s_axi_aclk);
            s_axi_araddr  = addr;
            s_axi_arlen   = 8'd0;
            s_axi_arsize  = 3'd0;
            s_axi_arburst = 2'd0;
            s_axi_arcache = 4'd0;
            s_axi_arprot  = 3'd0;
            s_axi_arqos   = 4'd0;
            s_axi_arvalid = 1'b1;

            while (!(s_axi_arvalid && s_axi_arready)) @(posedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_arvalid = 1'b0;

            s_axi_rready = 1'b1;
            while (!(s_axi_rvalid && s_axi_rready)) @(posedge s_axi_aclk);
            data_bit = s_axi_rdata[0];
            @(negedge s_axi_aclk);
            s_axi_rready = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("tb_accelerator.vcd");
        $dumpvars(0, tb_accelerator);

        s_axi_aclk    = 0;
        s_axi_aresetn  = 0;
        s_axi_awaddr   = 64'd0;
        s_axi_awlen    = 8'd0;
        s_axi_awsize   = 3'd0;
        s_axi_awburst  = 2'd0;
        s_axi_awcache  = 4'd0;
        s_axi_awprot   = 3'd0;
        s_axi_awqos    = 4'd0;
        s_axi_awvalid  = 1'b0;
        s_axi_wdata    = 1'b0;
        s_axi_wstrb    = 8'd0;
        s_axi_wlast    = 1'b0;
        s_axi_wvalid   = 1'b0;
        s_axi_bready   = 1'b0;
        s_axi_araddr   = 64'd0;
        s_axi_arlen    = 8'd0;
        s_axi_arsize   = 3'd0;
        s_axi_arburst  = 2'd0;
        s_axi_arcache  = 4'd0;
        s_axi_arprot   = 3'd0;
        s_axi_arqos    = 4'd0;
        s_axi_arvalid  = 1'b0;
        s_axi_rready   = 1'b0;

        repeat (4) @(posedge s_axi_aclk);
        @(negedge s_axi_aclk);
        s_axi_aresetn = 1'b1;
        repeat (2) @(posedge s_axi_aclk);

        check_bit("m_axi_awvalid idle", m_axi_awvalid, 1'b0);
        check_bit("m_axi_wvalid idle",  m_axi_wvalid,  1'b0);
        check_bit("m_axi_arvalid idle", m_axi_arvalid, 1'b0);

        begin
            bit ctrl_bit;
            axi_lite_read(REG_CTRL, ctrl_bit);
            check_bit("ctrl default bit0", ctrl_bit, 1'b0);
            axi_lite_write(REG_CTRL, 1'b1);
            repeat (2) @(posedge s_axi_aclk);
            axi_lite_read(REG_CTRL, ctrl_bit);
            check_bit("ctrl self-clear bit0", ctrl_bit, 1'b0);
        end

        begin
            bit status_bit;
            axi_lite_read(REG_STATUS, status_bit);
            check_bit("status idle bit0", status_bit, 1'b0);
        end

        begin
            bit src_bit;
            axi_lite_write(REG_SRC_ADDR, 1'b1);
            axi_lite_read(REG_SRC_ADDR, src_bit);
            check_bit("src addr bit0", src_bit, 1'b1);
        end

        check_word("m_axi_awaddr idle", m_axi_awaddr, 64'd0);

        $display("\n==================================");
        $display("  ACCELERATOR SMOKE TB: Passed=%0d Failed=%0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("  ALL ACCELERATOR TESTS PASSED");
        else               $display("  ACCELERATOR TESTS FAILED");
        $display("==================================");
        $finish;
    end

    initial begin
        #(CLK_PERIOD * 20000);
        $display("ACCELERATOR WATCHDOG");
        $finish;
    end

endmodule