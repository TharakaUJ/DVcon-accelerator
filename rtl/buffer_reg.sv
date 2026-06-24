`timescale 1ns/1ps

module buffer_reg #(
    parameter integer BUFFER_WIDTH = 32
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          en,

    input  wire signed [BUFFER_WIDTH-1:0] buffer_in,
    output reg  signed [BUFFER_WIDTH-1:0] buffer_out
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer_out <= {BUFFER_WIDTH{1'b0}};
        end else if (en) begin
            buffer_out <= buffer_in;
        end
    end

endmodule
