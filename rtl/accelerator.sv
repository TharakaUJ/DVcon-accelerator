`timescale 1ns/1ps

module accelerator #(
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = 64,
    parameter int INSTR_WINDOW_SIZE = 4,
    parameter int SYSTOLIC_ARRAY_ROWS = 32
)(
    // NOTE (UNKNOWN — requires clarification): bias_addr is wired below as an
    // internal descriptor register input to control_unit, mirroring
    // weight_addr, but axi4_lite_slave.sv was not provided so there is no
    // confirmed AXI-lite register backing it yet. Until that register exists,
    // it is tied to a fixed placeholder offset from weight_addr — see the
    // note at the bias_addr assignment below.

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

    input logic [11:0] s_axi_awid,
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
    output logic [11:0] s_axi_bid,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,

    input logic [11:0] s_axi_arid,
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
    output logic [11:0] s_axi_rid,
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
    logic [$clog2(SYSTOLIC_ARRAY_ROWS*SYSTOLIC_ARRAY_ROWS*DATA_WIDTH/ADDR_WIDTH)-1:0] act_wr_addr;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS)-1:0] act_rd_addr;
    logic act_wr_buf, act_rd_buf;
    logic act_rd_valid; // havent used yet



    // bram weight buffer interface
    logic wt_wr_en, wt_rd_en;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS*SYSTOLIC_ARRAY_ROWS*DATA_WIDTH/ADDR_WIDTH)-1:0] wt_wr_addr;
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

    localparam int INSTR_WIDTH = 32;   // was 24; widened to fit the new accum_ctrl instruction field

    // bram accum buffer interface (NEW) — sits between systolic array and vector unit
    localparam int ACC_W = 32;         // matches vector_unit's ACC_W localparam
    logic accum_wr_en, accum_wr_init, accum_rd_en;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS)-1:0] accum_wr_addr, accum_rd_addr;
    logic signed [ACC_W-1:0] accum_rd_data [0:SYSTOLIC_ARRAY_ROWS-1];
    logic accum_rd_valid;

    // bram bias buffer interface (NEW)
    logic bias_wr_en, bias_rd_en;
    logic [$clog2(SYSTOLIC_ARRAY_ROWS*ACC_W/64)-1:0] bias_wr_addr;
    logic signed [ACC_W-1:0] bias_rd_data [0:SYSTOLIC_ARRAY_ROWS-1];
    logic bias_rd_valid;

    // NOTE (UNKNOWN — requires clarification): no confirmed AXI-lite register
    // exists for bias_addr yet (axi4_lite_slave.sv not provided). Tied to a
    // placeholder offset from weight_addr so the datapath is complete and
    // simulatable; replace with a real descriptor register once the slave's
    // register map is extended.
    logic [ADDR_WIDTH-1:0] bias_addr;
    assign bias_addr = weight_addr + (ADDR_WIDTH'(SYSTOLIC_ARRAY_ROWS) * (DATA_WIDTH*SYSTOLIC_ARRAY_ROWS/8));

    // vector unit interface
    logic vector_in_valid; // NEW — now driven by control_unit (was dangling)
    logic signed [31:0] vector_bias [0:SYSTOLIC_ARRAY_ROWS-1]; // NEW — now driven by bias_buffer's rd_data
    logic [15:0] vector_requant_mult; // still unwired — no descriptor/CSR source identified (UNKNOWN, see summary)
    logic [4:0] vector_requant_shift; // still unwired — no descriptor/CSR source identified (UNKNOWN, see summary)
    logic [1:0] vector_act_type;      // still unwired — no descriptor/CSR source identified (UNKNOWN, see summary)
    logic vector_out_valid; // havent used yet
    logic signed [DATA_WIDTH-1:0] vector_unit_out [0:SYSTOLIC_ARRAY_ROWS-1];

    // instruction fifo interface
    logic fifo_pop_en;
    logic [$clog2(INSTR_WINDOW_SIZE)-1:0] fifo_pop_idx;
    logic [INSTR_WIDTH-1:0] fifo_window [0:INSTR_WINDOW_SIZE-1];

    // control unit interface
    logic loading_weights, streaming_acts, weight_swap;

    // dma trigger (new)
    logic [ADDR_WIDTH-1:0] cu_dma_rd_addr, cu_dma_wr_addr;
    logic [7:0] cu_dma_rd_len, cu_dma_wr_len;

    
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
        .ACT_DEPTH(SYSTOLIC_ARRAY_ROWS)
    ) u_bram_act_buffer (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),

        .wr_en (act_wr_en),
        .wr_buf (act_wr_buf),
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
        .ROWS(SYSTOLIC_ARRAY_ROWS),
        .COLS(SYSTOLIC_ARRAY_ROWS)
    ) u_bram_weight_buffer (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .wr_en (wt_wr_en),
        .wr_data (master_rd_data),
        .wr_addr (wt_wr_addr),
        .rd_en (wt_rd_en),
        .weight_data (systolic_array_weight_in),
        .rd_valid (wt_rd_valid)
    );

    bram_out_buffer #(
        .DATA_W(DATA_WIDTH),
        .OC_LANES(SYSTOLIC_ARRAY_ROWS),
        .OUT_DEPTH(SYSTOLIC_ARRAY_ROWS)
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

    // NEW — accumulation buffer. Sits between the systolic array and the
    // vector unit; array_result_out feeds its write port directly (one tile
    // row per write, init-or-accumulate per control_unit.accum_wr_init), and
    // its registered read port feeds vector_unit.acc.
    bram_accum_buffer #(
        .ACC_W(ACC_W),
        .LANES(SYSTOLIC_ARRAY_ROWS),
        .DEPTH(SYSTOLIC_ARRAY_ROWS)
    ) u_bram_accum_buffer (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .wr_en   (accum_wr_en),
        .wr_init (accum_wr_init),
        .wr_addr (accum_wr_addr),
        .wr_data (array_result_out),
        .rd_en   (accum_rd_en),
        .rd_addr (accum_rd_addr),
        .rd_data (accum_rd_data),
        .rd_valid(accum_rd_valid)
    );

    // NEW — bias buffer. DMA-loaded (OP_LOAD_BIAS), read on OP_VECTOR, feeds
    // vector_unit.bias. Flat/persistent — see control_unit scoreboard notes.
    bram_bias_buffer #(
        .ACC_W(ACC_W),
        .LANES(SYSTOLIC_ARRAY_ROWS)
    ) u_bram_bias_buffer (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .wr_en    (bias_wr_en),
        .wr_addr  (bias_wr_addr),
        .wr_data  (master_rd_data),
        .rd_en    (bias_rd_en),
        .bias_data(bias_rd_data),
        .rd_valid (bias_rd_valid)
    );

    assign vector_bias = bias_rd_data;   // NEW — was a dangling/never-written register

    vector_unit #(
        .SILU_SCALE(16.0)
    ) u_vector_unit (
        .clk (s_axi_aclk),
        .rst_n (s_axi_aresetn),
        .in_valid (vector_in_valid),
        .acc(accum_rd_data),          // CHANGED — was array_result_out directly; now reads through accum_buffer
        .bias(vector_bias),
        .requant_mult(vector_requant_mult),
        .requant_shift(vector_requant_shift),
        .act_type(vector_act_type),
        .out_valid (vector_out_valid),
        .q (vector_unit_out)
    );

    control_unit #(
        .ARRAY_SIZE(SYSTOLIC_ARRAY_ROWS),
        .DMA_WIDTH(ADDR_WIDTH),                 // NEW — pass through top-level param
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
        .num_acts (num_acts),
        .busy (busy),
        .done (done),
        .fsm_state (fsm_state),

        // descriptor registers, previously dead-ended at the slave
        .src_addr    (src_addr),
        .dst_addr    (dst_addr),
        .weight_addr (weight_addr),
        .bias_addr   (bias_addr),      // NEW — see UNKNOWN note at its declaration above
        .img_rows    (img_rows),
        .img_cols    (img_cols),

        // DMA trigger, wire straight into axi4_master's rd/wr start ports
        .dma_rd_start (master_rd_start),
        .dma_rd_addr  (master_rd_addr),
        .dma_rd_len   (master_rd_len),
        .dma_wr_start (master_wr_start),
        .dma_wr_addr  (master_wr_addr),
        .dma_wr_len   (master_wr_len),

        // NEW — per-beat handshake, was generated by axi4_master but never
        // reached control_unit, so multi-beat BRAM writes/reads had no way
        // to know when to step.
        .dma_rd_data_valid (master_rd_data_valid),
        .dma_wr_data_ready (master_wr_data_ready),

        .loading_weights (loading_weights),
        .streaming_acts (streaming_acts),

        .wt_wr_en (wt_wr_en),
        .wt_wr_addr (wt_wr_addr),
        .wt_rd_en (wt_rd_en),

        .act_wr_en (act_wr_en),
        .act_wr_addr (act_wr_addr),
        .act_wr_buf (act_wr_buf),
        .act_rd_en (act_rd_en),
        .act_rd_addr (act_rd_addr),
        .act_rd_buf (act_rd_buf),
        .out_rd_en (out_rd_en),
        .out_rd_addr (out_rd_addr),
        .out_rd_buf (out_rd_buf),
        .out_rd_valid (out_rd_valid),  // NEW — was generated by bram_out_buffer, never reached control_unit
        .out_wr_en (out_wr_en),
        .out_wr_buf(out_wr_buf),
        .out_wr_addr(out_wr_addr),

        // NEW — accumulation buffer control
        .accum_wr_en   (accum_wr_en),
        .accum_wr_init (accum_wr_init),
        .accum_wr_addr (accum_wr_addr),
        .accum_rd_en   (accum_rd_en),
        .accum_rd_addr (accum_rd_addr),
        .accum_rd_valid(accum_rd_valid),  // NEW — was generated by bram_accum_buffer, never reached control_unit

        // NEW — bias buffer control
        .bias_wr_en   (bias_wr_en),
        .bias_wr_addr (bias_wr_addr),
        .bias_rd_en   (bias_rd_en),
        .bias_rd_valid(bias_rd_valid),    // NEW — was generated by bram_bias_buffer, never reached control_unit

        // NEW — vector unit control (previously dangling)
        .vector_in_valid (vector_in_valid),

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
