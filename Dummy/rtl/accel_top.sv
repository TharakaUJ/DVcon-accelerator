//==============================================================================
// accel_top.sv  --  Zero-shot detection accelerator top level.
//
// Exposes:
//   * AXI4-Lite slave  (S_AXIL_*)  -- VEGA control/status/result
//   * AXI4 master      (M_AXI_*)   -- DDR3 via MIG
//   * irq                          -- to VEGA interrupt controller
//
// Package this module as an AXI peripheral in Vivado IP Integrator and wire it
// next to the VEGA core + MIG (see scripts/create_project.tcl).
//==============================================================================

module accel_top
  import accel_pkg::*;
#(
  parameter int UART_CLK_HZ = 150_000_000,   // = aclk frequency
  parameter int UART_BAUD   = 115_200
)(
  input  logic aclk,
  input  logic aresetn,

  // ---------------- UART diagnostic port (independent of AXI) ----------------
  input  logic                    uart_rx_i,
  output logic                    uart_tx_o,

  // ---------------- AXI4-Lite slave (control) ----------------
  input  logic [AXIL_ADDR_W-1:0]  s_axil_awaddr,
  input  logic                    s_axil_awvalid,
  output logic                    s_axil_awready,
  input  logic [AXIL_DATA_W-1:0]  s_axil_wdata,
  input  logic [AXIL_DATA_W/8-1:0]s_axil_wstrb,
  input  logic                    s_axil_wvalid,
  output logic                    s_axil_wready,
  output logic [1:0]              s_axil_bresp,
  output logic                    s_axil_bvalid,
  input  logic                    s_axil_bready,
  input  logic [AXIL_ADDR_W-1:0]  s_axil_araddr,
  input  logic                    s_axil_arvalid,
  output logic                    s_axil_arready,
  output logic [AXIL_DATA_W-1:0]  s_axil_rdata,
  output logic [1:0]              s_axil_rresp,
  output logic                    s_axil_rvalid,
  input  logic                    s_axil_rready,

  // ---------------- AXI4 master (DDR) ----------------
  output logic [AXI_ID_W-1:0]     m_axi_awid,
  output logic [AXI_ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]              m_axi_awlen,
  output logic [2:0]              m_axi_awsize,
  output logic [1:0]              m_axi_awburst,
  output logic                    m_axi_awvalid,
  input  logic                    m_axi_awready,
  output logic [AXI_DATA_W-1:0]   m_axi_wdata,
  output logic [AXI_STRB_W-1:0]   m_axi_wstrb,
  output logic                    m_axi_wlast,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,
  input  logic [AXI_ID_W-1:0]     m_axi_bid,
  input  logic [1:0]              m_axi_bresp,
  input  logic                    m_axi_bvalid,
  output logic                    m_axi_bready,
  output logic [AXI_ID_W-1:0]     m_axi_arid,
  output logic [AXI_ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]              m_axi_arlen,
  output logic [2:0]              m_axi_arsize,
  output logic [1:0]              m_axi_arburst,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,
  input  logic [AXI_ID_W-1:0]     m_axi_rid,
  input  logic [AXI_DATA_W-1:0]   m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rlast,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready,

  output logic                    irq
);

  wire rst_n = aresetn;

  // ---- control wires ----
  logic        start_pulse, soft_rst, irq_en, irq_ack;
  logic [31:0] desc_base, desc_count;
  logic [31:0] wt_addr, in_addr, out_addr, bias_addr;
  logic [15:0] requant_mult;
  logic [4:0]  requant_shift;
  logic [1:0]  act_type;
  logic        busy, done, err;

  // ---- controller <-> masters ----
  logic        rd_req, rd_busy, rd_done, rd_valid, rd_ready;
  logic [31:0] rd_addr; logic [15:0] rd_len;
  logic [AXI_DATA_W-1:0] rd_data;
  logic        wr_req, wr_busy, wr_done, wr_valid, wr_ready;
  logic [31:0] wr_addr; logic [15:0] wr_len;
  logic [AXI_DATA_W-1:0] wr_data;

  // ============================ AXI4-Lite slave ============================
  axi_lite_slave u_axil (
    .clk(aclk), .rst_n(rst_n),
    .s_awaddr(s_axil_awaddr), .s_awvalid(s_axil_awvalid), .s_awready(s_axil_awready),
    .s_wdata(s_axil_wdata), .s_wstrb(s_axil_wstrb), .s_wvalid(s_axil_wvalid), .s_wready(s_axil_wready),
    .s_bresp(s_axil_bresp), .s_bvalid(s_axil_bvalid), .s_bready(s_axil_bready),
    .s_araddr(s_axil_araddr), .s_arvalid(s_axil_arvalid), .s_arready(s_axil_arready),
    .s_rdata(s_axil_rdata), .s_rresp(s_axil_rresp), .s_rvalid(s_axil_rvalid), .s_rready(s_axil_rready),
    .start_pulse(start_pulse), .soft_rst(soft_rst), .irq_en(irq_en), .irq_ack(irq_ack),
    .desc_base(desc_base), .desc_count(desc_count),
    .wt_addr(wt_addr), .in_addr(in_addr), .out_addr(out_addr), .bias_addr(bias_addr),
    .requant_mult(requant_mult), .requant_shift(requant_shift), .act_type(act_type),
    .busy(busy), .done(done), .err(err),
    .irq(irq)
  );

  // ============================ DMA masters ============================
  axi_read_master u_rd (
    .clk(aclk), .rst_n(rst_n),
    .req(rd_req), .addr(rd_addr), .len_beats(rd_len), .busy(rd_busy), .done(rd_done),
    .m_data(rd_data), .m_valid(rd_valid), .m_ready(rd_ready),
    .arid(m_axi_arid), .araddr(m_axi_araddr), .arlen(m_axi_arlen), .arsize(m_axi_arsize),
    .arburst(m_axi_arburst), .arvalid(m_axi_arvalid), .arready(m_axi_arready),
    .rid(m_axi_rid), .rdata(m_axi_rdata), .rresp(m_axi_rresp),
    .rlast(m_axi_rlast), .rvalid(m_axi_rvalid), .rready(m_axi_rready)
  );

  axi_write_master u_wr (
    .clk(aclk), .rst_n(rst_n),
    .req(wr_req), .addr(wr_addr), .len_beats(wr_len), .busy(wr_busy), .done(wr_done),
    .s_data(wr_data), .s_valid(wr_valid), .s_ready(wr_ready),
    .awid(m_axi_awid), .awaddr(m_axi_awaddr), .awlen(m_axi_awlen), .awsize(m_axi_awsize),
    .awburst(m_axi_awburst), .awvalid(m_axi_awvalid), .awready(m_axi_awready),
    .wdata(m_axi_wdata), .wstrb(m_axi_wstrb), .wlast(m_axi_wlast),
    .wvalid(m_axi_wvalid), .wready(m_axi_wready),
    .bid(m_axi_bid), .bresp(m_axi_bresp), .bvalid(m_axi_bvalid), .bready(m_axi_bready)
  );

  // ============================ Controller ============================
  conv_controller u_ctrl (
    .clk(aclk), .rst_n(rst_n & ~soft_rst),
    .start(start_pulse), .desc_base(desc_base), .desc_count(desc_count),
    .busy(busy), .done(done), .err(err),
    .rd_req(rd_req), .rd_addr(rd_addr), .rd_len(rd_len),
    .rd_busy(rd_busy), .rd_done(rd_done), .rd_data(rd_data),
    .rd_valid(rd_valid), .rd_ready(rd_ready),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_len(wr_len),
    .wr_busy(wr_busy), .wr_done(wr_done), .wr_data(wr_data),
    .wr_valid(wr_valid), .wr_ready(wr_ready)
  );

  // ============================ UART diagnostic ============================
  // Option B: detections go to DDR for the CPU to score. This port only reports
  // status/heartbeat (alive, busy/done/err, inference count) for bring-up.
  uart_diag #(.CLK_HZ(UART_CLK_HZ), .BAUD(UART_BAUD)) u_diag (
    .clk(aclk), .rst_n(rst_n),
    .uart_rx_i(uart_rx_i), .uart_tx_o(uart_tx_o),
    .busy(busy), .done(done), .err(err)
  );

endmodule
