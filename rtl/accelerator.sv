`timescale 1ns/1ps

module accelerator #(
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = 32
)(
    // axi master
    output logic m_axi_awvalid,
    output logic [11:0] m_axi_awid,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic [0:0] m_axi_awlock,
    output logic [3:0] m_axi_awcache,
    output logic [3:0] m_axi_awqos,
    output logic [63:0] m_axi_awaddr,
    output logic [2:0] m_axi_awprot,
    input  logic m_axi_awready,

    output logic m_axi_wvalid,
    output logic m_axi_wlast,
    output logic [63:0] m_axi_wdata,
    output logic [7:0] m_axi_wstrb,
    input  logic m_axi_wready,

    output logic m_axi_bready,
    input  logic m_axi_bvalid,
    input  logic [11:0] m_axi_bid,
    input  logic [1:0] m_axi_bresp,

    output logic m_axi_arvalid,
    output logic [11:0] m_axi_arid,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic [0:0] m_axi_arlock,
    output logic [3:0] m_axi_arcache,
    output logic [3:0] m_axi_arqos,
    output logic [63:0] m_axi_araddr,
    output logic [2:0] m_axi_arprot,
    input  logic m_axi_arready,

    output logic m_axi_rready,
    input  logic m_axi_rvalid,
    input  logic [11:0] m_axi_rid,
    input  logic m_axi_rlast,
    input  logic [1:0] m_axi_rresp,
    input  logic [63:0] m_axi_rdata,

    // axi slave
    input logic s_axi_aclk,
    input logic s_axi_aresetn,

    input logic s_axi_awid,
    input logic [63:0] s_axi_awaddr,
    input logic [7:0] s_axi_awlen,
    input logic [2:0] s_axi_awsize,
    input logic [1:0] s_axi_awburst,
    input logic s_axi_awlock,
    input logic [3:0] s_axi_awcache,
    input logic [2:0] s_axi_awprot,
    input logic [3:0] s_axi_awqos,
    input logic s_axi_awvalid,
    output logic s_axi_awready,

    input logic s_axi_wdata,
    input logic [7:0] s_axi_wstrb,
    input logic s_axi_wlast,
    input logic s_axi_wvalid,
    output logic s_axi_wready,

    input logic s_axi_bready,
    output logic s_axi_bid,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,

    input logic s_axi_arid,
    input logic [63:0] s_axi_araddr,
    input logic [7:0] s_axi_arlen,
    input logic [2:0] s_axi_arsize,
    input logic [1:0] s_axi_arburst,
    input logic s_axi_arlock,
    input logic [3:0] s_axi_arcache,
    input logic [2:0] s_axi_arprot,
    input logic [3:0] s_axi_arqos,
    input logic s_axi_arvalid,
    output logic s_axi_arready,

    output logic s_axi_rready,
    output logic s_axi_rid,
    output logic [63:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rlast,
    output logic s_axi_rvalid
);


    // internal signals
    // axi master interface
    logic rd_start, wr_start;
    logic [ADDR_WIDTH-1:0] rd_addr, wr_addr;
    logic [7:0] rd_len, wr_len;
    logic [DATA_WIDTH-1:0] rd_data, wr_data;
    logic rd_data_valid, wr_data_ready;
    logic rd_done, wr_done;
    logic rd_error, wr_error;

    // axi slave interface
    logic start_pulse;
    logic soft_reset;
    logic [ADDR_WIDTH-1:0] src_addr, dst_addr;
    logic [31:0] img_rows, img_cols;
    logic [ADDR_WIDTH-1:0] weight_addr;
    logic [31:0] weight_size;
    logic busy, done, error;
    logic [3:0] fsm_state;



    
    axi4_master #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_axi4_master (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),

        .m_arid (m_axi_arid),
        .m_araddr (m_axi_araddr),
        .m_arlen (m_axi_arlen),
        .m_arsize (m_axi_arsize),
        .m_arburst (m_axi_arburst),
        .m_arprot (m_axi_arprot),
        .m_arvalid (m_axi_arvalid),
        .m_arready (m_axi_arready),

        .m_rid (m_axi_rid),
        .m_rdata (m_axi_rdata),
        .m_rresp (m_axi_rresp),
        .m_rlast (m_axi_rlast),
        .m_rvalid (m_axi_rvalid),
        .m_rready (m_axi_rready),

        .m_awid (m_axi_awid),
        .m_awaddr (m_axi_awaddr),
        .m_awlen (m_axi_awlen),
        .m_awsize (m_axi_awsize),
        .m_awburst (m_axi_awburst),
        .m_awprot (m_axi_awprot),
        .m_awvalid (m_axi_awvalid),
        .m_awready (m_axi_awready),

        .m_wdata (m_axi_wdata),
        .m_wstrb (m_axi_wstrb),
        .m_wlast (m_axi_wlast),
        .m_wvalid (m_axi_wvalid),
        .m_wready (m_axi_wready),

        .m_bid (m_axi_bid),
        .m_bresp (m_axi_bresp),
        .m_bvalid (m_axi_bvalid),
        .m_bready (m_axi_bready),

        .rd_start (rd_start),
        .rd_addr (rd_addr),
        .rd_len (rd_len),
        .rd_data (rd_data),
        .rd_data_valid (rd_data_valid),
        .rd_done (rd_done),
        .rd_error (rd_error),

        .wr_start (wr_start),
        .wr_addr (wr_addr),
        .wr_len (wr_len),
        .wr_data (wr_data),
        .wr_data_ready(wr_data_ready),
        .wr_done (wr_done),
        .wr_error (wr_error)
    );



    axi4_lite_slave #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_axi4_lite_slave (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),

        .s_awvalid (s_axi_awvalid),
        .s_awready (s_axi_awready),
        .s_awaddr (s_axi_awaddr),

        .s_wvalid (s_axi_wvalid),
        .s_wready (s_axi_wready),
        .s_wdata (s_axi_wdata),
        .s_wstrb (s_axi_wstrb),

        .s_bvalid (s_axi_bvalid),
        .s_bready (s_axi_bready),
        .s_bresp (s_axi_bresp),

        .s_arvalid (s_axi_arvalid),
        .s_arready (s_axi_arready),
        .s_araddr (s_axi_araddr),

        .s_rvalid (s_axi_rvalid),
        .s_rready (s_axi_rready),
        .s_rdata (s_axi_rdata),
        .s_rresp (s_axi_rresp),

        .start_pulse (start_pulse),
        .soft_reset (soft_reset),
        .src_addr (src_addr),
        .dst_addr (dst_addr),
        .img_rows (img_rows),
        .img_cols (img_cols),
        .weight_addr (weight_addr),

        .busy (busy),
        .done (done),
        .error (error),
        .fsm_state (fsm_state)
    );


    

endmodule
