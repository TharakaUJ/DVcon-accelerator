`timescale 1ns/1ps

module buffer_reg #(
    parameter integer DATA_WIDTH   = 8,
    parameter integer BUFFER_WIDTH = 32
)(
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire                             en,

    input  wire signed [DATA_WIDTH-1:0]     buffer_in  [0:BUFFER_WIDTH-1],
    output reg  signed [DATA_WIDTH-1:0]     buffer_out [0:BUFFER_WIDTH-1]
);

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < BUFFER_WIDTH; i = i + 1) begin
                buffer_out[i] <= {DATA_WIDTH{1'b0}};
            end
        end else if (en) begin
            for (i = 0; i < BUFFER_WIDTH; i = i + 1) begin
                buffer_out[i] <= buffer_in[i];
            end
        end
    end

endmodule
