// Here everything gets connected together. It handles the data flow between these components.
`timescale 1ns/1ps

module accelerator #(
    parameter integer ARRAY_SIZE = 32,
    parameter integer DATA_WIDTH = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          en,

    input  wire signed [DATA_WIDTH-1:0]            input_data[0:ARRAY_SIZE-1],
    input  wire                   systolic_input_select_A,
    output wire [3:0] fsm_state,

    // following ports probably will be removed in the future.
    input wire en_input_buffer_A,
    input wire en_input_buffer_B,
    input wire weight_load,
    output wire perf_valid,
    output wire [31:0] perf_cycles,
    output wire [31:0] result_valid,


    // AXI4 Master interface
    output wire [3:0] m_arid,
    output wire [31:0] m_araddr,
    output wire [7:0] m_arlen,
    output wire [2:0] m_arsize,
    output wire [1:0] m_arburst,
    output wire [2:0] m_arprot,
    output wire m_arvalid,
    input  wire m_arready,
    input  wire [3:0] m_rid,
    input  wire [31:0] m_rdata,
    input  wire [1:0] m_rresp,
    input  wire m_rlast,
    input  wire m_rvalid,
    output wire m_rready,
    output wire [3:0] m_awid,
    output wire [31:0] m_awaddr,
    output wire [7:0] m_awlen,
    output wire [2:0] m_awsize,
    output wire [1:0] m_awburst,
    output wire [2:0] m_awprot,
    output wire m_awvalid,
    input  wire m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0] m_wstrb,
    output wire m_wlast,
    output wire m_wvalid,
    input  wire m_wready,
    input  wire [3:0] m_bid,
    input  wire [1:0] m_bresp,
    input  wire m_bvalid,
    output wire m_bready,
    output wire wr_error,



    // AXI4-Lite Slave interface
    input  wire s_awvalid,
    output wire s_awready,
    input  wire [31:0] s_awaddr,
    input  wire s_wvalid,
    output wire s_wready,
    input  wire [31:0] s_wdata,
    input  wire [3:0] s_wstrb,
    output wire s_bvalid,
    input  wire s_bready,
    output wire [1:0] s_bresp,
    input  wire s_arvalid,
    output wire s_arready,
    input  wire [31:0] s_araddr,
    output wire s_rvalid,
    input  wire s_rready,
    output wire [31:0] s_rdata,
    output wire [1:0] s_rresp,
    output wire start_pulse,
    output wire soft_reset,
    output wire [31:0] src_addr,
    output wire [31:0] dst_addr,
    output wire [15:0] img_rows,
    output wire [15:0] img_cols,
    output wire [31:0] weight_addr,
    output  wire busy,
    output  wire done,
    input  wire error



);

    wire signed [DATA_WIDTH-1:0]            buffered_data_A[0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0]            buffered_data_B[0:ARRAY_SIZE-1];
    wire signed [31:0]                      compute_output[0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0]            systolic_input[0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0]            weight_data [0:(ARRAY_SIZE*ARRAY_SIZE)-1];

    wire [(DATA_WIDTH * ARRAY_SIZE)-1:0] flat_buffered_data_A;
    wire [(DATA_WIDTH * ARRAY_SIZE)-1:0] flat_buffered_data_B;
    wire [(DATA_WIDTH * ARRAY_SIZE)-1:0] flat_systolic_input;
    wire [(32 * ARRAY_SIZE)-1:0]         flat_compute_output;


    // AXI4-Lite Slave internal wires
    

    // AXI4 Master internal wires
    wire        rd_start;
    wire [31:0] rd_addr;
    wire [7:0]  rd_len;
    wire [31:0] rd_data;
    wire        rd_data_valid;
    wire        rd_done;
    wire        rd_error;
    wire        wr_start;
    wire [31:0] wr_addr;
    wire [7:0]  wr_len;
    wire [31:0] wr_data;
    wire        wr_data_ready;
    wire        wr_done;

    wire        ctrl_busy;
    wire        ctrl_done;
    wire [3:0]  ctrl_fsm_state;

    wire        cu_en_input_buffer_A;
    wire        cu_en_input_buffer_B;
    wire        cu_weight_load;
    wire        cu_systolic_input_select_A;

    wire        datapath_en_input_buffer_A;
    wire        datapath_en_input_buffer_B;
    wire        datapath_weight_load;
    wire        datapath_systolic_input_select_A;


    // Add these new wires at the top of your internal wire declarations in accelerator.v
    wire [2:0]  cu_rd_word_idx;
    wire [4:0]  cu_wr_word_idx;
    reg  [255:0] axi_rx_shift_reg;
    wire signed [DATA_WIDTH-1:0] axi_rx_data_array [0:ARRAY_SIZE-1];

    // 1. DESERIALIZE AXI READS (32-bit -> 256-bit)
    always @(posedge clk) begin
        if (rd_data_valid) begin
            // Shift in 32 bits at a time from AXI Master
            axi_rx_shift_reg <= {rd_data, axi_rx_shift_reg[255:32]};
        end
    end

    // Pack the 256-bit register into the 8-bit array format for your buffers
    generate
        genvar j;
        for (j = 0; j < ARRAY_SIZE; j = j + 1) begin : rx_pack
            assign axi_rx_data_array[j] = axi_rx_shift_reg[(j*DATA_WIDTH) +: DATA_WIDTH];
        end
    endgenerate

    // 2. SERIALIZE SYSTOLIC ARRAY OUTPUT (1024-bit -> 32-bit)
    assign wr_data = compute_output[cu_wr_word_idx];


    generate
        genvar i;
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : flat_assign
            assign flat_buffered_data_A[i * DATA_WIDTH +: DATA_WIDTH] = buffered_data_A[i];
            assign flat_buffered_data_B[i * DATA_WIDTH +: DATA_WIDTH] = buffered_data_B[i];
            assign systolic_input[i] = flat_systolic_input[i * DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    assign datapath_en_input_buffer_A = en_input_buffer_A | cu_en_input_buffer_A;
    assign datapath_en_input_buffer_B = en_input_buffer_B | cu_en_input_buffer_B;
    assign datapath_weight_load = weight_load | cu_weight_load;
    assign datapath_systolic_input_select_A = systolic_input_select_A | cu_systolic_input_select_A;


    shift_reg_buffer #(
        .DATA_WIDTH(8),
        .BUFFER_WIDTH(32),
        .BUFFER_DEPTH(32)
    ) input_buffer_A (
        .clk(clk),
        .rst_n(rst_n),
        .en(datapath_en_input_buffer_A),
        .buffer_in(axi_rx_data_array),
        .buffer_out(buffered_data_A)
    );

    shift_reg_buffer #(
        .DATA_WIDTH(8),
        .BUFFER_WIDTH(32),
        .BUFFER_DEPTH(32),
        .EXPOSE_INTERNAL_WIRES(1)
    ) input_buffer_B (
        .clk(clk),
        .rst_n(rst_n),
        .en(datapath_en_input_buffer_B),
        .buffer_in(axi_rx_data_array),
        .buffer_out(buffered_data_B),
        .connect_wires_out(weight_data)
    );

    generic_mux #(
        .WIDTH(32*DATA_WIDTH),
        .NUM_INPUTS(2)
    ) accelerator_input (
        .in({flat_buffered_data_B, flat_buffered_data_A}), // 0->A, 1->B
        .sel(datapath_systolic_input_select_A),
        .out(flat_systolic_input)
    );

    systolic_array #(
        .ROWS(32),
        .COLS(32),
        .FRAC_BITS(0),
        .ACCUM_WIDTH(32)
    ) systolic_array_32x32 (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .clear_acc(1'b0),
        .weight_load(datapath_weight_load),
        .weight_data(weight_data),
        .act_in(systolic_input),
        .result_out(compute_output),
        .result_valid(result_valid),
        .perf_cycles(perf_cycles),
        .perf_valid(perf_valid)
    );

    axi4_lite_slave #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32)
    ) axi4_lite_slave_inst (
        .clk(clk),
        .rst_n(rst_n),
        .s_awvalid(s_awvalid),
        .s_awready(s_awready),
        .s_awaddr(s_awaddr),
        .s_wvalid(s_wvalid),
        .s_wready(s_wready),
        .s_wdata(s_wdata),
        .s_wstrb(s_wstrb),
        .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_bresp(s_bresp),
        .s_arvalid(s_arvalid),
        .s_arready(s_arready),
        .s_araddr(s_araddr),
        .s_rvalid(s_rvalid),
        .s_rready(s_rready),
        .s_rdata(s_rdata),
        .s_rresp(s_rresp),
        .start_pulse(start_pulse),
        .soft_reset(soft_reset),
        .src_addr(src_addr),
        .dst_addr(dst_addr),
        .img_rows(img_rows),
        .img_cols(img_cols),
        .weight_addr(weight_addr),
        .busy(ctrl_busy),
        .done(ctrl_done),
        .error(error),
        .fsm_state(ctrl_fsm_state)
    );


    axi4_master #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32)
    ) axi4_master_inst (
        .clk(clk),
        .rst_n(rst_n),
        .m_arid(m_arid),
        .m_araddr(m_araddr),
        .m_arlen(m_arlen),
        .m_arsize(m_arsize),
        .m_arburst(m_arburst),
        .m_arprot(m_arprot),
        .m_arvalid(m_arvalid),
        .m_arready(m_arready),
        .m_rid(m_rid),
        .m_rdata(m_rdata),
        .m_rresp(m_rresp),
        .m_rlast(m_rlast),
        .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .m_awid(m_awid),
        .m_awaddr(m_awaddr),
        .m_awlen(m_awlen),
        .m_awsize(m_awsize),
        .m_awburst(m_awburst),
        .m_awprot(m_awprot),
        .m_awvalid(m_awvalid),
        .m_awready(m_awready),
        .m_wdata(m_wdata),
        .m_wstrb(m_wstrb),
        .m_wlast(m_wlast),
        .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bid(m_bid),
        .m_bresp(m_bresp),
        .m_bvalid(m_bvalid),
        .m_bready(m_bready),
        .rd_start(rd_start),
        .rd_addr(rd_addr),
        .rd_len(rd_len),
        .rd_data(rd_data),
        .rd_data_valid(rd_data_valid),
        .rd_done(rd_done),
        .rd_error(rd_error),
        .wr_start(wr_start),
        .wr_addr(wr_addr),
        .wr_len(wr_len),
        .wr_data(wr_data),
        .wr_data_ready(wr_data_ready),
        .wr_done(wr_done),
        .wr_error(wr_error)
    );


    control_unit #(
        .ROM_DEPTH(16)
    ) control_unit_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start_pulse(start_pulse),
        .src_addr(src_addr),
        .weight_addr(weight_addr),
        .dst_addr(dst_addr),
        .busy(ctrl_busy),
        .done(ctrl_done),
        
        .rd_start(rd_start),
        .rd_addr(rd_addr),
        .rd_len(rd_len),
        .rd_done(rd_done),
        .rd_data_valid(rd_data_valid),
        .perf_valid(perf_valid),
        
        .wr_start(wr_start),
        .wr_addr(wr_addr),
        .wr_len(wr_len),
        .wr_done(wr_done),
        .wr_data_ready(wr_data_ready),
        
        .fsm_state(ctrl_fsm_state),
        .en_input_buffer_A(cu_en_input_buffer_A),
        .en_input_buffer_B(cu_en_input_buffer_B),
        .weight_load(cu_weight_load),
        .systolic_input_select_A(cu_systolic_input_select_A),
        
        .rd_word_idx(cu_rd_word_idx),
        .wr_word_idx(cu_wr_word_idx) 
    );

    assign fsm_state = ctrl_fsm_state;
    assign busy = ctrl_busy;
    assign done = ctrl_done;

endmodule