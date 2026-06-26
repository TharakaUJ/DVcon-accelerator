// Here everything gets connected together. The accelerator is the top-level module that instantiates the controller, memory, and compute units. It also handles the data flow between these components.
`timescale 1ns/1ps

module accelerator #(
    parameter integer ARRAY_SIZE = 32,
    parameter integer DATA_WIDTH = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          en,

    input  wire signed [DATA_WIDTH-1:0]            input_data[0:ARRAY_SIZE-1],
    output wire signed [1023:0]            output_data,
    input  wire                   systolic_input_select_A,
    input  wire [0:0]                    output_select,

    // following ports probably will be removed in the future.
    input wire en_input_buffer_A,
    input wire en_input_buffer_B,
    input wire en_output_buffer_A,
    input wire en_output_buffer_B,
    input wire weight_load,
    output wire perf_valid,
    output wire [31:0] perf_cycles,
    output wire [31:0] result_valid
);

    wire signed [DATA_WIDTH-1:0]            buffered_data_A[0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0]            buffered_data_B[0:ARRAY_SIZE-1];
    wire signed [31:0]                      compute_output[0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0]            output_buffered_data[0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0]            systolic_input[0:ARRAY_SIZE-1];
    wire signed [DATA_WIDTH-1:0]            weight_data [0:(ARRAY_SIZE*ARRAY_SIZE)-1];

    wire [(DATA_WIDTH * ARRAY_SIZE)-1:0] flat_buffered_data_A;
    wire [(DATA_WIDTH * ARRAY_SIZE)-1:0] flat_buffered_data_B;
    wire [(DATA_WIDTH * ARRAY_SIZE)-1:0] flat_systolic_input;
    wire [(32 * ARRAY_SIZE)-1:0]         flat_compute_output;

    generate
        genvar i;
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : flat_assign
            assign flat_buffered_data_A[i * DATA_WIDTH +: DATA_WIDTH] = buffered_data_A[i];
            assign flat_buffered_data_B[i * DATA_WIDTH +: DATA_WIDTH] = buffered_data_B[i];
            assign flat_systolic_input[i * DATA_WIDTH +: DATA_WIDTH]  = systolic_input[i];
            assign flat_compute_output[i * 32 +: 32]                  = compute_output[i];
        end
    endgenerate



    shift_reg_buffer #(
        .BUFFER_WIDTH(32),
        .BUFFER_DEPTH(32)
    ) input_buffer_A (
        .clk(clk),
        .rst_n(rst_n),
        .en(en_input_buffer_A),
        .buffer_in(input_data),
        .buffer_out(buffered_data_A)
    );

    shift_reg_buffer #(
        .BUFFER_WIDTH(32),
        .BUFFER_DEPTH(32),
        .EXPOSE_INTERNAL_WIRES(1)
    ) input_buffer_B (
        .clk(clk),
        .rst_n(rst_n),
        .en(en_input_buffer_B),
        .buffer_in(input_data),
        .buffer_out(buffered_data_B),
        .connect_wires_out(weight_data)
    );

    register_bank #(
        .DATA_WIDTH(32*32),
        .BUFFER_WIDTH(1)
    ) output_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .en(en_output_buffer_A),
        .register_data_in(flat_compute_output),
        .register_data_out(output_data),
        .input_reg_select(2'b0),
        .output_reg_select(2'b0)
    );

    generic_mux #(
        .WIDTH(32*DATA_WIDTH),
        .NUM_INPUTS(2)
    ) accelerator_input (
        .in({flat_buffered_data_A, flat_buffered_data_B}),
        .sel(systolic_input_select_A),
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
        .weight_load(weight_load),
        .weight_data(weight_data),
        .act_in(systolic_input),
        .result_out(compute_output),
        .result_valid(result_valid),
        .perf_cycles(perf_cycles),
        .perf_valid(perf_valid)
    );

endmodule