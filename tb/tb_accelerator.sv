`timescale 1ns/1ps

module tb_accelerator;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam integer ARRAY_SIZE = 32;
    localparam integer DATA_WIDTH = 8;
    localparam CLK_PERIOD = 10;

    // =========================================================================
    // Signals
    // =========================================================================
    reg clk;
    reg rst_n;
    reg en;
    
    // 2D Array for input data to match DUT ports
    reg signed [DATA_WIDTH-1:0] input_data [0:ARRAY_SIZE-1];
    
    wire signed [1023:0] output_data; // 32 PEs * 32-bit output = 1023:0
    reg systolic_input_select_A;

    reg en_input_buffer_A;
    reg en_input_buffer_B;
    reg weight_load;
    
    wire perf_valid;
    wire [31:0] perf_cycles;
    wire [31:0] result_valid;

    // Test Tracking Variables
    integer error_count = 0;

    // =========================================================================
    // Clock Generation
    // =========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    accelerator #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .input_data(input_data),
        .output_data(output_data),
        .systolic_input_select_A(systolic_input_select_A),
        .en_input_buffer_A(en_input_buffer_A),
        .en_input_buffer_B(en_input_buffer_B),
        .weight_load(weight_load),
        .perf_valid(perf_valid),
        .perf_cycles(perf_cycles),
        .result_valid(result_valid)
    );

    // =========================================================================
    // Tasks
    // =========================================================================
    
    // Clear the input_data bus
    task clear_input_data;
        integer i;
        begin
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                input_data[i] = 8'sd0;
            end
        end
    endtask

    // System Reset
    task apply_reset;
        begin
            rst_n = 0;
            en = 0;
            systolic_input_select_A = 0;
            en_input_buffer_A = 0;
            en_input_buffer_B = 0;
            weight_load = 0;
            clear_input_data();
            error_count = 0;
            
            #(CLK_PERIOD * 5);
            rst_n = 1;
            #(CLK_PERIOD * 2);
        end
    endtask

    // Load Weights into Buffer B
    task load_weights_to_buffer;
        integer row, col;
        begin
            $display("[%0t] Starting Weight Load Sequence...", $time);
            for (row = 0; row < ARRAY_SIZE; row = row + 1) begin
                for (col = 0; col < ARRAY_SIZE; col = col + 1) begin
                    input_data[col] = (row == col) ? 8'sd1 : 8'sd0; // Identity matrix
                end
                
                en_input_buffer_B = 1;
                #(CLK_PERIOD);
            end
            
            en_input_buffer_B = 0;
            
            #(CLK_PERIOD);
            weight_load = 1;
            #(CLK_PERIOD);
            weight_load = 0;
            clear_input_data();
            $display("[%0t] Weights Loaded into Systolic Array.", $time);
        end
    endtask

    // Stream Activations to Buffer A and pulse the Array
    task stream_activations;
        input integer num_cycles;
        integer c, i;
        begin
            $display("[%0t] Streaming Activations...", $time);
            systolic_input_select_A = 1'b0; 
            
            for (c = 0; c < num_cycles; c = c + 1) begin
                for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                    input_data[i] = 8'sd2; // Activation matrix values = 2
                end
                
                en_input_buffer_A = 1;  
                en = 1;                 
                #(CLK_PERIOD);
            end
            
            en_input_buffer_A = 0;
            en = 0;
            clear_input_data();
        end
    endtask

    // Wait for output validity, latch it, and check results
    task capture_and_validate_output;
        integer pe_idx;
        reg signed [31:0] expected_val;
        reg signed [31:0] actual_val;
        begin
            $display("[%0t] Waiting for result_valid...", $time);
            
            wait(result_valid > 0);
            #(CLK_PERIOD * (ARRAY_SIZE + 2)); 
            
            #(CLK_PERIOD);
            
            $display("[%0t] Results latched. Starting automated check...", $time);
            
            // Expected value logic: 
            // Input data was 2, Weight was Identity (1). 
            // Depending on how your MAC/accumulation is structured per cycle over K=4,
            // Expected output per active PE is 2 * 1 = 2 (if it clears/outputs per row)
            expected_val = 32'sd2; 

            for (pe_idx = 0; pe_idx < ARRAY_SIZE; pe_idx = pe_idx + 1) begin
                // Slice the 1024-bit wide output bus into individual 32-bit PE outputs
                actual_val = output_data[(pe_idx * 32) +: 32];
                
                if (actual_val !== expected_val) begin
                    $display("[%0t] ERROR: PE [%0d] mismatch! Expected: %0d, Actual: %0d", 
                             $time, pe_idx, expected_val, actual_val);
                    error_count = error_count + 1;
                end else begin
                    $display("[%0t] PASS: PE [%0d] correctly matched: %0d", 
                             $time, pe_idx, actual_val);
                end
            end
        end
    endtask

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $dumpfile("tb_accelerator.vcd");
        $dumpvars(0, tb_accelerator);

        // 1. Reset
        apply_reset();

        // 2. Setup Weights (Identity Matrix)
        load_weights_to_buffer();

        // 3. Setup and Run Activations (Stream constant 2s)
        stream_activations(96);

        // 4. Wait, Latch, and Check
        capture_and_validate_output();
        
        // 5. Finalize with clear status report
        #(CLK_PERIOD * 10);
        $display("\n========================================");
        if (error_count == 0) begin
            $display("  TEST RESULT: PASSED (0 errors)");
        end else begin
            $display("  TEST RESULT: FAILED (%0d errors)", error_count);
        end
        $display("========================================\n");
        
        $finish;
    end

    // Watchdog Timer
    initial begin
        #(CLK_PERIOD * 5000);
        $display("[%0t] ERROR: Watchdog timeout!", $time);
        $finish;
    end

endmodule