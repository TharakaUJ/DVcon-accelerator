`timescale 1ns/1ps

module shift_reg_buffer #(
    parameter integer BUFFER_WIDTH = 32,
    parameter integer BUFFER_DEPTH = 32
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          en,

    input  wire signed [BUFFER_WIDTH-1:0] buffer_in,
    output wire signed [BUFFER_WIDTH-1:0] buffer_out
);

    wire signed [BUFFER_WIDTH-1:0] connect_wires [0:BUFFER_DEPTH];

    assign connect_wires[0] = buffer_in;
    assign buffer_out       = connect_wires[BUFFER_DEPTH];

    generate
        genvar i;
        for (i = 0; i < BUFFER_DEPTH; i = i + 1) 
        begin : buffer_gen
            buffer_reg #(
                .BUFFER_WIDTH(BUFFER_WIDTH)
            ) buffer_inst (
                .clk(clk),
                .rst_n(rst_n),
                .en(en),
                .buffer_in(connect_wires[i]),
                .buffer_out(connect_wires[i+1])
            );
        end        
    endgenerate

endmodule
