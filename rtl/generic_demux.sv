// general demux module
`timescale 1ns/1ps

module generic_demux #(
    parameter integer WIDTH = 32,
    parameter integer NUM_OUTPUTS = 4
)(
    input  wire [WIDTH-1:0]                in,
    input  wire [$clog2(NUM_OUTPUTS)-1:0]  sel,
    output wire [(WIDTH * NUM_OUTPUTS)-1:0] out
);
    assign out = {NUM_OUTPUTS{in}} & ({NUM_OUTPUTS{1'b1}} << (sel * WIDTH));
endmodule