`timescale 1ns/1ps

module tb_generic_mux;
    parameter integer WIDTH = 32;
    parameter integer NUM_INPUTS = 4;

    reg                          clk;
    reg                          rst_n;
    reg                          en;
    reg signed [(WIDTH * NUM_INPUTS)-1:0] input_data;
    wire signed [WIDTH-1:0] output_data;
    reg [($clog2(NUM_INPUTS)-1):0] sel;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer i;

    // Helper variable to mirror the expected signed value
    reg signed [WIDTH-1:0] expected_out;

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

    generic_mux #(
        .WIDTH(WIDTH),
        .NUM_INPUTS(NUM_INPUTS)
    ) uut (
        .in(input_data),
        .sel(sel),
        .out(output_data)
    );

    always begin
        #5 clk = ~clk;
    end

    initial begin
        // --- Initialization ---
        sel        = 0;
        input_data = 0;

        // Initialize unique signed data for each input channel
        // Example: Ch0 = 10, Ch1 = -20, Ch2 = 30, Ch3 = -40
        input_data[(WIDTH*0) +: WIDTH] = 32'd10;
        input_data[(WIDTH*1) +: WIDTH] = -32'd20;
        input_data[(WIDTH*2) +: WIDTH] = 32'd30;
        input_data[(WIDTH*3) +: WIDTH] = -32'd40;

        #15; // Wait for global reset
        
        // --- Test Case 1: Reset Behavior ---
        @(posedge clk);
        #1; // Small delay after clock edge to sample output safely
        check_int("Reset active", output_data, 32'd0);

        // De-assert reset
        @(posedge clk);
        rst_n = 1;

        // --- Test Case 2: Enable Behavior (Disabled) ---
        en = 0;
        sel = 2'd2; // Point to 30
        @(posedge clk);
        #1;
        check_int("Enable inactive", output_data, 32'd0);

        // --- Test Case 3: Multiplexer Routing (Enabled) ---
        en = 1;
        
        // Loop through all channels to test selection logic
        for (i = 0; i < NUM_INPUTS; i = i + 1) begin
            sel = i;
            
            // Extract the expected data slice dynamically based on loop index
            expected_out = input_data[(WIDTH * i) +: WIDTH];
            
            @(posedge clk);
            #1; // Wait for design outputs to settle
            check_int("Channel Select", output_data, expected_out);
        end

        // --- Final Report ---
        $display("\n==================================");
        $display("  SIMULATION COMPLETE");
        $display("  Total Tests Passed: %0d", pass_cnt);
        $display("  Total Tests Failed: %0d", fail_cnt);
        $display("==================================");
        
        $finish; 
    end

endmodule
