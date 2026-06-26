// Scalable N-to-1 Multiplexer
`timescale 1ns/1ps

module generic_mux #(
    parameter integer WIDTH = 32,
    parameter integer NUM_INPUTS = 4
)(
    input  wire [(WIDTH * NUM_INPUTS)-1:0] in,
    input  wire [$clog2(NUM_INPUTS)-1:0]   sel,
    output wire [WIDTH-1:0]                out
);
    assign out = in[sel * WIDTH +: WIDTH];
endmodule
