// conv_engine.sv — 3×3 INT8 convolution engine
// 9 systolic_pe instances chained in series.
// Latency: 9 cycles from en to result_valid.

`timescale 1ns/1ps

module conv_engine #(
    parameter int ACCUM_WIDTH = 32
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        en,

    input  logic signed [7:0] act_in    [0:8],  // 3×3 window, row-major
    input  logic signed [7:0] weight_in [0:8],  // 3×3 kernel, row-major

    output logic signed [ACCUM_WIDTH-1:0] result_out,
    output logic                          result_valid
);

    localparam int NUM_PE = 9;

    // en delay chain — en_sked[i] = en delayed i cycles
    logic [NUM_PE-2:0] en_dly;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) en_dly <= '0;
        else        en_dly <= {en_dly[NUM_PE-3:0], en};
    end

    logic en_sked [0:NUM_PE-1];
    assign en_sked[0] = en;
    for (genvar i = 1; i < NUM_PE; i++) begin : g_en
        assign en_sked[i] = en_dly[i-1];
    end

    // PE interconnect
    logic signed [ACCUM_WIDTH-1:0] psum       [0:NUM_PE-1];
    logic                          psum_valid [0:NUM_PE-1];

    // PE[0] — no upstream psum
    systolic_pe #(.ACCUM_WIDTH(ACCUM_WIDTH)) u_pe0 (
        .clk          (clk),
        .rst_n        (rst_n),
        .en           (en_sked[0]),
        .weight_in    (weight_in[0]),
        .act_in       (act_in[0]),
        .psum_in      ('0),
        .psum_in_valid(1'b0),
        .psum_out     (psum[0]),
        .out_valid    (psum_valid[0])
    );

    // PE[1..8] — chain psum downward
    for (genvar i = 1; i < NUM_PE; i++) begin : g_pe
        systolic_pe #(.ACCUM_WIDTH(ACCUM_WIDTH)) u_pe (
            .clk          (clk),
            .rst_n        (rst_n),
            .en           (en_sked[i]),
            .weight_in    (weight_in[i]),
            .act_in       (act_in[i]),
            .psum_in      (psum[i-1]),
            .psum_in_valid(psum_valid[i-1]),
            .psum_out     (psum[i]),
            .out_valid    (psum_valid[i])
        );
    end

    assign result_out   = psum[NUM_PE-1];
    assign result_valid = psum_valid[NUM_PE-1];

endmodule
