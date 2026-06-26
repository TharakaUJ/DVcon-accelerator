`timescale 1ns/1ps

module tb_accelerator;

    // Testbench global counters
    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // DUT Inputs
    reg         clk;
    reg         rst_n;
    reg         en;
    reg  signed [31:0] input_data;
    reg  [1:0]  systolic_input_select_A;
    reg  [1:0]  systolic_input_select_B;
    reg  [0:0]  output_select;

    // DUT Outputs
    wire signed [31:0] output_data;

    // Instantiate Device Under Test (DUT)
    accelerator u_dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .input_data(input_data),
        .output_data(output_data),
        .systolic_input_select_A(systolic_input_select_A),
        .systolic_input_select_B(systolic_input_select_B),
        .output_select(output_select)
    );

    // Clock Generation (50MHz)
    always #10 clk = ~clk;

    // Validation Task
    task check_int;
        input [255:0] tag;
        input integer got;
        input integer exp;
        begin
            if (got === exp) begin
                $display("  PASS  %s  got=%0d", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %s  got=%0d  exp=%0d", tag, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Main Stimulus Blocks
    initial begin
        // Initialize Inputs
        clk = 0;
        rst_n = 0;
        en = 0;
        input_data = 0;
        systolic_input_select_A = 0;
        systolic_input_select_B = 0;
        output_select = 0;

        // Apply Reset
        #40;
        rst_n = 1;
        en = 1;
        #20;

        $display("--- Starting Data-Path Verification ---");

        // Step 1: Drive data into the input buffers
        input_data = 32'd100;
        #20; 

        // Note: Assuming behavioral mock models route directly, 
        // We configure output mux to read out the values to test the connections.
        
        // Let's test output_select routes properly via the tasks 
        // (Modify values based on how your real buffers delay or change data)
        check_int("Verify baseline output stream", output_data, 0);

        // Final Report
        #100;
        $display("\n--- TEST RESULTS ---");
        $display("TOTAL PASSED: %0d", pass_cnt);
        $display("TOTAL FAILED: %0d", fail_cnt);
        if (fail_cnt == 0) begin
            $display(">>> ALL TESTS PASSED SUCCESSFULLY <<<");
        end else begin
            $display(">>> FAILURE DETECTED IN SIMULATION <<<");
        end
        $finish;
    end

endmodule


// ==========================================
// BEHAVIORAL MOCK MODELS FOR COMPILATION
// ==========================================
// Replace or remove these if you already have the separate files for them.

module shift_reg_buffer #(
    parameter BUFFER_WIDTH = 32,
    parameter BUFFER_DEPTH = 32
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      en,
    input  wire [BUFFER_WIDTH-1:0]   buffer_in,
    output reg  [BUFFER_WIDTH-1:0]   buffer_out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) buffer_out <= 0;
        else if (en) buffer_out <= buffer_in; // Simple bypass mock
    end
endmodule

module generic_mux #(
    parameter WIDTH = 32,
    parameter NUM_INPUTS = 4
)(
    input  wire [(WIDTH*NUM_INPUTS)-1:0] in,
    input  wire [$clog2(NUM_INPUTS)-1:0] sel,
    output reg  [WIDTH-1:0]              out
);
    integer i;
    always @(*) begin
        out = 0;
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin
            if (sel == i) begin
                // Extracts the correctly indexed segment from the flattened bus 
                out = in[((NUM_INPUTS-1-i)*WIDTH) +: WIDTH];
            end
        end
    end
endmodule

module systolic_array #(
    parameter ARRAY_SIZE = 32,
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  en,
    input  wire [DATA_WIDTH-1:0] input_A,
    input  wire [DATA_WIDTH-1:0] input_B,
    output reg  [DATA_WIDTH-1:0] output_C
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) output_C <= 0;
        else if (en) output_C <= input_A + input_B; // Simple math function mock
    end
endmodule
