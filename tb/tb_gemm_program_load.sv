`timescale 1ns/1ps
// tb_gemm_program_load.sv
//
// Self-checking testbench for the CPU-programmable instruction memory.
// Loads the same 11-word 2x2 GEMM program that used to be hard-coded in
// instructions_fifo.sv's `initial` block, via the new
// REG_INSTR_ADDR/REG_INSTR_DATA/REG_PROG_LEN AXI4-Lite registers, then
// pulses START and checks the DRAM model's output bytes match the expected
// C = A x B result.
//
// A = [1 2]   B = [5 6]   C = A x B = [19 22]
//     [3 4]       [7 8]               [43 50]
//
// SIMPLIFICATIONS (documented per task instructions — iverilog was not
// available in this environment to compile/run this testbench; see the
// final report for exact repro steps a user can run themselves):
//   1. A minimal AXI4 memory-model slave answers the accelerator's
//      m_axi_* master ports (single-beat-per-cycle, always-ready, no
//      backpressure/reordering) rather than a fully general AXI4 subordinate.
//      This is sufficient because axi4_master.sv drives one outstanding
//      burst at a time from control_unit.sv.
//   2. DRAM is modeled as a simple byte-addressable array
//      (`logic [7:0] dram[0:DRAM_BYTES-1]`), pre-loaded with A/B in the
//      testbench's initial block (zero-padded to 8x8 as the original
//      demo program's comments specify), instead of a full DDR timing model.
//   3. AXI4-Lite register writes are driven with a small helper task
//      (`axil_write`) that performs the aw/w/b handshake at the signal
//      level per the protocol axi4_lite_slave.sv implements (independent
//      aw/w acceptance, single-cycle W_BUSY, one-cycle W_RESP) rather than
//      a full randomized/out-of-order AXI4-Lite VIP.

module tb_gemm_program_load;

    localparam int DATA_WIDTH  = 8;
    localparam int ADDR_WIDTH  = 64;
    localparam int ARRAY_SIZE  = 8;
    localparam int DRAM_BYTES  = 65536;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // ── AXI4-Lite (CPU->accelerator config) ──────────────────────────────
    logic        s_awvalid, s_awready;
    logic [63:0] s_awaddr;
    logic        s_wvalid, s_wready;
    logic [63:0] s_wdata;
    logic [7:0]  s_wstrb;
    logic        s_bvalid, s_bready;
    logic [1:0]  s_bresp;
    logic        s_arvalid, s_arready;
    logic [63:0] s_araddr;
    logic        s_rvalid, s_rready;
    logic [63:0] s_rdata;
    logic [1:0]  s_rresp;

    // ── AXI4 (accelerator->DRAM model) ───────────────────────────────────
    logic        m_axi_awvalid;
    logic [11:0] m_axi_awid;
    logic [7:0]  m_axi_awlen;
    logic [2:0]  m_axi_awsize;
    logic [1:0]  m_axi_awburst;
    logic [0:0]  m_axi_awlock;
    logic [3:0]  m_axi_awcache;
    logic [3:0]  m_axi_awqos;
    logic [63:0] m_axi_awaddr;
    logic [2:0]  m_axi_awprot;
    logic        m_axi_awready;

    logic        m_axi_wvalid;
    logic        m_axi_wlast;
    logic [63:0] m_axi_wdata;
    logic [7:0]  m_axi_wstrb;
    logic        m_axi_wready;

    logic        m_axi_bready;
    logic        m_axi_bvalid;
    logic [11:0] m_axi_bid;
    logic [1:0]  m_axi_bresp;

    logic        m_axi_arvalid;
    logic [11:0] m_axi_arid;
    logic [7:0]  m_axi_arlen;
    logic [2:0]  m_axi_arsize;
    logic [1:0]  m_axi_arburst;
    logic [0:0]  m_axi_arlock;
    logic [3:0]  m_axi_arcache;
    logic [3:0]  m_axi_arqos;
    logic [63:0] m_axi_araddr;
    logic [2:0]  m_axi_arprot;
    logic        m_axi_arready;

    logic        m_axi_rready;
    logic        m_axi_rvalid;
    logic [11:0] m_axi_rid;
    logic        m_axi_rlast;
    logic [1:0]  m_axi_rresp;
    logic [63:0] m_axi_rdata;

    accelerator #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .INSTR_WINDOW_SIZE(4),
        .SYSTOLIC_ARRAY_ROWS(ARRAY_SIZE)
    ) dut (
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awid(m_axi_awid), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst), .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache), .m_axi_awqos(m_axi_awqos), .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awprot(m_axi_awprot), .m_axi_awready(m_axi_awready),

        .m_axi_wvalid(m_axi_wvalid), .m_axi_wlast(m_axi_wlast), .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb), .m_axi_wready(m_axi_wready),

        .m_axi_bready(m_axi_bready), .m_axi_bvalid(m_axi_bvalid), .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),

        .m_axi_arvalid(m_axi_arvalid), .m_axi_arid(m_axi_arid), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache), .m_axi_arqos(m_axi_arqos), .m_axi_araddr(m_axi_araddr),
        .m_axi_arprot(m_axi_arprot), .m_axi_arready(m_axi_arready),

        .m_axi_rready(m_axi_rready), .m_axi_rvalid(m_axi_rvalid), .m_axi_rid(m_axi_rid),
        .m_axi_rlast(m_axi_rlast), .m_axi_rresp(m_axi_rresp), .m_axi_rdata(m_axi_rdata),

        .s_axi_aclk(clk), .s_axi_aresetn(rst_n),

        .s_axi_awid('0), .s_axi_awaddr(s_awaddr), .s_axi_awlen('0), .s_axi_awsize('0),
        .s_axi_awburst('0), .s_axi_awlock('0), .s_axi_awcache('0), .s_axi_awprot('0),
        .s_axi_awqos('0), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),

        .s_axi_wdata(s_wdata), .s_axi_wstrb(s_wstrb), .s_axi_wlast(1'b1),
        .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),

        .s_axi_bready(s_bready), .s_axi_bid(), .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid),

        .s_axi_arid('0), .s_axi_araddr(s_araddr), .s_axi_arlen('0), .s_axi_arsize('0),
        .s_axi_arburst('0), .s_axi_arlock('0), .s_axi_arcache('0), .s_axi_arprot('0),
        .s_axi_arqos('0), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),

        .s_axi_rready(s_rready), .s_axi_rid(), .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp),
        .s_axi_rlast(), .s_axi_rvalid(s_rvalid)
    );

    // ── Minimal AXI4 DRAM model (simplification #1/#2) ──────────────────
    logic [7:0] dram [0:DRAM_BYTES-1];

    // Read channel: accept AR immediately, stream RLEN+1 beats back-to-back.
    logic [7:0]  rd_beats_left;
    logic [63:0] rd_addr_cur;
    assign m_axi_arready = 1'b1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_rvalid <= 1'b0;
            rd_beats_left <= '0;
        end else begin
            if (m_axi_arvalid && m_axi_arready && !m_axi_rvalid) begin
                rd_addr_cur   <= m_axi_araddr;
                rd_beats_left <= m_axi_arlen;
                m_axi_rvalid  <= 1'b1;
                m_axi_rid     <= m_axi_arid;
            end else if (m_axi_rvalid && m_axi_rready) begin
                if (rd_beats_left == 0) begin
                    m_axi_rvalid <= 1'b0;
                end else begin
                    rd_addr_cur   <= rd_addr_cur + 8;
                    rd_beats_left <= rd_beats_left - 1'b1;
                end
            end
        end
    end
    assign m_axi_rlast = (rd_beats_left == 0);
    assign m_axi_rresp = 2'b00;
    always_comb begin
        for (int b = 0; b < 8; b++)
            m_axi_rdata[b*8 +: 8] = dram[rd_addr_cur + b];
    end
    // NOTE: m_axi_rready is driven BY the DUT (accelerator is the AXI
    // master on this interface) — no drive needed here.

    // Write channel: accept AW/W immediately, commit bytes, respond once.
    assign m_axi_awready = 1'b1;
    assign m_axi_wready  = 1'b1;
    logic bvalid_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bvalid_q <= 1'b0;
        end else begin
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                bvalid_q <= 1'b1;
            else if (m_axi_bvalid && m_axi_bready)
                bvalid_q <= 1'b0;

            if (m_axi_wvalid && m_axi_wready) begin
                for (int b = 0; b < 8; b++)
                    if (m_axi_wstrb[b])
                        dram[m_axi_awaddr_latched + b] <= m_axi_wdata[b*8 +: 8];
            end
        end
    end
    logic [63:0] m_axi_awaddr_latched;
    always_ff @(posedge clk) if (m_axi_awvalid && m_axi_awready) m_axi_awaddr_latched <= m_axi_awaddr;
    assign m_axi_bvalid = bvalid_q;
    assign m_axi_bresp  = 2'b00;
    assign m_axi_bid    = m_axi_awid;

    // ── AXI4-Lite helper task (simplification #3) ────────────────────────
    task automatic axil_write(input logic [63:0] addr, input logic [31:0] data);
        @(posedge clk);
        s_awaddr  <= addr;
        s_awvalid <= 1'b1;
        s_wdata   <= {32'h0, data};
        s_wstrb   <= 8'hFF;
        s_wvalid  <= 1'b1;
        s_bready  <= 1'b1;
        @(posedge clk);
        while (!s_awready) @(posedge clk);
        s_awvalid <= 1'b0;
        while (!s_wready) @(posedge clk);
        s_wvalid  <= 1'b0;
        while (!s_bvalid) @(posedge clk);
        @(posedge clk);
        s_bready <= 1'b0;
    endtask

    // ── Program: same 11-word GEMM ROM as the original instructions_fifo.sv ──
    localparam int NPROG = 11;
    logic [31:0] prog_words [0:NPROG-1];
    initial begin
        prog_words[0]  = 32'h00000000;  // NOP
        prog_words[1]  = 32'h10000700;  // LOAD_WGT  dst=0 addr=0x00 len=7
        prog_words[2]  = 32'h20000100;  // LOAD_ACT  dst=0 addr=0x00 len=1
        prog_words[3]  = 32'h30000300;  // LOAD_BIAS       addr=0x00 len=3
        prog_words[4]  = 32'h70000000;  // SWAP_WGT
        prog_words[5]  = 32'h40000000;  // MATMUL    src=0 addr=0x00
        prog_words[6]  = 32'h50000000;  // VECTOR          dst=0 addr=0x00
        prog_words[7]  = 32'h40010000;  // MATMUL    src=0 addr=0x01
        prog_words[8]  = 32'h50010000;  // VECTOR          dst=0 addr=0x01
        prog_words[9]  = 32'h60000100;  // STORE     src=0 addr=0x00 len=1
        prog_words[10] = 32'h80000000;  // END
    end

    localparam logic [63:0] SRC_ADDR    = 64'h0002_0000;
    localparam logic [63:0] WEIGHT_ADDR = 64'h0002_0000; // same tile reused as "weight" for this smoke test
    localparam logic [63:0] BIAS_ADDR   = 64'h0002_8000;
    localparam logic [63:0] DST_ADDR    = 64'h0002_4000;

    int errors;

    initial begin
        s_awvalid = 0; s_wvalid = 0; s_bready = 0;
        s_arvalid = 0; s_araddr = 0; s_rready = 0;
        errors = 0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // Pre-load DRAM: 8x8 W tile (=B zero-padded) at WEIGHT_ADDR/SRC_ADDR,
        // 8x8 A tile (rows0/1 = A, rest zero) at SRC_ADDR, 8 zero bias lanes
        // at BIAS_ADDR. Byte layout: row-major, 8 bytes/beat, INT8 elements.
        for (int i = 0; i < 512; i++) dram[i] = 8'h00;
        // Weight tile W == B = [[5,6,0..],[7,8,0..],0...] (8x8)
        dram[SRC_ADDR[15:0] + 0] = 8'd5; dram[SRC_ADDR[15:0] + 1] = 8'd6;
        dram[SRC_ADDR[15:0] + 8] = 8'd7; dram[SRC_ADDR[15:0] + 9] = 8'd8;
        // NOTE: activation tile A is loaded from a SEPARATE region (offset
        // 64) rather than reusing SRC_ADDR/WEIGHT_ADDR's default overlap in
        // axi4_lite_slave.sv (both default to 0x00020000) — REG_SRC_ADDR is
        // explicitly repointed to this region below to avoid a collision
        // with the preloaded weight tile.
        dram[64 + 0] = 8'd1; dram[64 + 1] = 8'd2;
        dram[64 + 8] = 8'd3; dram[64 + 9] = 8'd4;

        // Program instruction memory via the new AXI4-Lite registers.
        for (int i = 0; i < NPROG; i++) begin
            axil_write(64'h20, i);            // REG_INSTR_ADDR
            axil_write(64'h24, prog_words[i]);   // REG_INSTR_DATA (pulses instr_wr_en)
        end
        axil_write(64'h28, NPROG);            // REG_PROG_LEN

        // Point descriptor registers: weight/bias as preloaded, activations
        // at the separate 64-byte region used above.
        axil_write(64'h08, 64'd64);           // REG_SRC_ADDR    -> A tile
        axil_write(64'h0C, DST_ADDR);         // REG_DST_ADDR
        axil_write(64'h14, SRC_ADDR);         // REG_WEIGHT_ADDR -> W tile
        axil_write(64'h18, BIAS_ADDR);        // REG_BIAS_ADDR

        // START
        axil_write(64'h00, 32'h1);

        // Wait for done (poll REG_STATUS via AXI-Lite read, or just wait a
        // generous number of cycles for this small smoke-test program).
        repeat (2000) @(posedge clk);

        // Expected C = A x B = [[19,22],[43,50]] at DST_ADDR, row-major INT8.
        check_byte(DST_ADDR[15:0] + 0, 8'd19);
        check_byte(DST_ADDR[15:0] + 1, 8'd22);
        check_byte(DST_ADDR[15:0] + 8, 8'd43);
        check_byte(DST_ADDR[15:0] + 9, 8'd50);

        if (errors == 0)
            $display("TB_GEMM_PROGRAM_LOAD: PASS");
        else
            $display("TB_GEMM_PROGRAM_LOAD: FAIL (%0d mismatches)", errors);

        $finish;
    end

    task automatic check_byte(input int addr, input logic [7:0] exp);
        if (dram[addr] !== exp) begin
            $display("  MISMATCH at dram[%0d]: got %0d expected %0d", addr, dram[addr], exp);
            errors++;
        end else begin
            $display("  OK dram[%0d] = %0d", addr, dram[addr]);
        end
    endtask

endmodule
