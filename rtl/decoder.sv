// general decoder module
`timescale 1ns/1ps

module decoder #(
    parameter integer INPUT_WIDTH = 5
)(
    input  wire [INPUT_WIDTH-1:0] in,
    output wire [(1 << INPUT_WIDTH)-1:0] out
);
    assign out = 1'b1 << in;
endmodule
