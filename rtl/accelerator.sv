`timescale 1ns/1ps

module accelerator #(
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = 64,
    parameter int INSTR_WINDOW_SIZE = 4,
    parameter int SYSTOLIC_ARRAY_ROWS = 32
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

    input logic [63:0] s_axi_wdata,
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

    input  logic s_axi_rready,
    output logic s_axi_rid,
    output logic [63:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rlast,
    output logic s_axi_rvalid
);


    // internal signals
    // axi master interface
    logic master_rd_start, master_wr_start;
    logic [ADDR_WIDTH-1:0] master_rd_addr, master_wr_addr;
    logic [7:0] master_rd_len, master_wr_len;
    logic [63:0] master_rd_data;
    logic [63:0] master_wr_data;
    logic master_rd_data_valid, master_wr_data_ready;
    logic master_rd_done, master_wr_done;
    logic master_rd_error, master_wr_error;

    // axi slave interface
    logic start_pulse;
    logic soft_reset;
    logic [ADDR_WIDTH-1:0] src_addr, dst_addr;
    logic [15:0] img_rows, img_cols;
    logic [ADDR_WIDTH-1:0] weight_addr;
    logic [31:0] weight_size;
    logic busy, done, error;
    logic [3:0] fsm_state;


    // bram act buffer interface
    logic act_wr_en, act_rd_en;
    logic [4:0] act_wr_bank;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS*SYSTOLIC_ARRAY_ROWS*DATA_WIDTH/ADDR_WIDTH)-1:0] act_wr_addr;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS)-1:0] act_rd_addr;
    logic act_wr_buf, act_rd_buf;
    logic act_rd_valid; // havent used yet



    // bram weight buffer interface
    logic wt_wr_en, wt_rd_en;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS*SYSTOLIC_ARRAY_ROWS*DATA_WIDTH/ADDR_WIDTH)-1:0] wt_wr_addr;
    logic [4:0] wt_wr_row;
    logic wt_rd_valid; // havent used yet

    // bram out buffer interface
    logic out_rd_en;
    logic out_wr_en;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS*SYSTOLIC_ARRAY_ROWS*DATA_WIDTH/ADDR_WIDTH)-1:0] out_rd_addr;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS)-1:0] out_wr_addr;
    logic out_wr_buf, out_rd_buf;
    logic out_rd_valid; // havent used yet

    // systolic array interface
    logic array_en, array_clear_acc, array_weight_load;
    logic signed [DATA_WIDTH-1:0] systolic_array_act_in [0:SYSTOLIC_ARRAY_ROWS-1];
    logic signed [DATA_WIDTH-1:0] systolic_array_weight_in [0:SYSTOLIC_ARRAY_ROWS*SYSTOLIC_ARRAY_ROWS-1];
    logic signed [31:0] array_result_out [0:SYSTOLIC_ARRAY_ROWS-1];
    logic [31:0] array_result_valid; // havent used yet
    logic [31:0] array_perf_cycles; // havent used yet
    logic array_perf_valid;

    logic [15:0] num_acts;

    localparam int INSTR_WIDTH = 24;

    // vector unit interface
    logic vector_in_valid; // havent used yet
    logic signed [31:0] vector_bias [0:SYSTOLIC_ARRAY_ROWS-1]; // have to wire thise. define a new memory may be
    logic [15:0] vector_requant_mult; // have to wire this. define a new memory may be
    logic [4:0] vector_requant_shift; // have to wire this. define a new memory may be
    logic [1:0] vector_act_type;
    logic vector_out_valid; // havent used yet
    logic signed [DATA_WIDTH-1:0] vector_unit_out [0:SYSTOLIC_ARRAY_ROWS-1];

    // instruction fifo interface
    logic fifo_pop_en;
    logic [$clog2(INSTR_WINDOW_SIZE)-1:0] fifo_pop_idx;
    logic [INSTR_WIDTH-1:0] fifo_window [0:INSTR_WINDOW_SIZE-1];

    // control unit interface
    logic loading_weights, streaming_acts, weight_swap;

    
    axi4_master u_axi4_master (
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

        // wire internal signals
        .rd_start (master_rd_start),
        .rd_addr (master_rd_addr),
        .rd_len (master_rd_len),
        .rd_data (master_rd_data),
        .rd_data_valid (master_rd_data_valid),
        .rd_done (master_rd_done),
        .rd_error (master_rd_error),

        .wr_start (master_wr_start),
        .wr_addr (master_wr_addr),
        .wr_len (master_wr_len),
        .wr_data (master_wr_data),
        .wr_data_ready(master_wr_data_ready),
        .wr_done (master_wr_done),
        .wr_error (master_wr_error)
    );



    axi4_lite_slave u_axi4_lite_slave (
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

        // wire internal signals
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


    bram_act_buffer #(
        .DATA_W(DATA_WIDTH),
        .ACT_BANKS(SYSTOLIC_ARRAY_ROWS),
        .ACT_DEPTH(SYSTOLIC_ARRAY_ROWS*SYSTOLIC_ARRAY_ROWS)
    ) u_bram_act_buffer (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),

        .wr_en (act_wr_en),
        .wr_buf (act_wr_buf),
        .wr_bank (act_wr_bank),
        .wr_addr (act_wr_addr),
        .wr_data (master_rd_data),

        .rd_en (act_rd_en),
        .rd_buf (act_rd_buf),
        .rd_addr (act_rd_addr),
        .rd_data (systolic_array_act_in),
        .rd_valid (act_rd_valid)
    );

    bram_weight_buffer #(
        .DATA_W(DATA_WIDTH),
        .ROWS(32),
        .COLS(32)
    ) u_bram_weight_buffer (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .wr_en (wt_wr_en),
        .wr_row (wt_wr_row),
        .wr_data (master_rd_data),
        .wr_addr (wt_wr_addr),
        .rd_en (wt_rd_en),
        .weight_data (systolic_array_weight_in),
        .rd_valid (wt_rd_valid)
    );

    bram_out_buffer #(
        .DATA_W(DATA_WIDTH),
        .OC_LANES(32),
        .OUT_DEPTH(1024)
    ) u_bram_out_buffer (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .wr_en (out_wr_en),
        .wr_buf (out_wr_buf),
        .wr_addr (out_wr_addr),
        .wr_vec (vector_unit_out),
        .rd_en (out_rd_en),
        .rd_buf (out_rd_buf),
        .rd_addr (out_rd_addr),
        .rd_vec (master_wr_data),
        .rd_valid (out_rd_valid)
    );

    systolic_array #(
        .ROWS(SYSTOLIC_ARRAY_ROWS),
        .COLS(SYSTOLIC_ARRAY_ROWS)
    ) u_systolic_array (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .en (array_en),
        .clear_acc (array_clear_acc),
        .weight_load(array_weight_load),
        .weight_data(systolic_array_weight_in),
        .act_in(systolic_array_act_in),
        .result_out(array_result_out),
        .result_valid(array_result_valid),
        .perf_cycles(array_perf_cycles),
        .perf_valid(array_perf_valid)
    );

    vector_unit #(
        .SILU_SCALE(16.0)
    ) u_vector_unit (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .in_valid (vector_in_valid),
        .acc(array_result_out),
        .bias(vector_bias),
        .requant_mult(vector_requant_mult),
        .requant_shift(vector_requant_shift),
        .act_type(vector_act_type),
        .out_valid (vector_out_valid),
        .q (vector_unit_out)
    );

    control_unit #(
        .ARRAY_SIZE(32),
        .ACT_DEPTH(1024),
        .OUT_DEPTH(1024),
        .INSTR_WINDOW_SIZE(INSTR_WINDOW_SIZE)
    ) u_control_unit (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .start_pulse (start_pulse),
        .soft_reset (soft_reset),
        .perf_valid (array_perf_valid),
        .dma_rd_done (master_rd_done),
        .dma_wr_done (master_wr_done),
        .array_done (array_perf_valid),
        .vector_done (vector_out_valid),
        .num_acts (num_acts), // haven't defined
        .busy (busy),
        .done (done),
        .fsm_state (fsm_state),

        .loading_weights (loading_weights), // haven't defined
        .streaming_acts (streaming_acts), // haven't defined


        .wt_wr_en (wt_wr_en),
        .wt_wr_row (wt_wr_row),
        .wt_rd_en (wt_rd_en),
        .weight_swap (weight_swap), // haven't defined

        .act_wr_en (act_wr_en),
        .act_wr_bank (act_wr_bank),
        .act_wr_addr (act_wr_addr),
        .act_wr_buf (act_wr_buf),
        .act_rd_en (act_rd_en),
        .act_rd_addr (act_rd_addr),
        .act_rd_buf (act_rd_buf),
        .out_rd_en (out_rd_en),
        .out_rd_addr (out_rd_addr),
        .out_rd_buf (out_rd_buf),
        .out_wr_en (out_wr_en),
        .out_wr_buf(out_wr_buf),
        .out_wr_addr(out_wr_addr),

        .array_en (array_en),
        .array_clear_acc (array_clear_acc),
        .array_weight_load (array_weight_load),

        .fifo_pop_en (fifo_pop_en),
        .fifo_pop_idx (fifo_pop_idx),
        .fifo_window (fifo_window)
    );

    instruction_fifo_window #(
        .INSTR_WIDTH(INSTR_WIDTH),
        .INSTR_DEPTH(16),
        .WINDOW_SIZE(INSTR_WINDOW_SIZE)
    ) u_instruction_fifo (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .pop_en (fifo_pop_en),
        .pop_idx (fifo_pop_idx),
        .window (fifo_window)
    );

endmodule
