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
    
    wire signed [1023:0] output_data;
    reg systolic_input_select_A;
    reg [0:0] output_select;

    reg en_input_buffer_A;
    reg en_input_buffer_B;
    reg en_output_buffer_A;
    reg en_output_buffer_B;
    reg weight_load;
    
    wire perf_valid;
    wire [31:0] perf_cycles;
    wire [31:0] result_valid;

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
        .output_select(output_select),
        .en_input_buffer_A(en_input_buffer_A),
        .en_input_buffer_B(en_input_buffer_B),
        .en_output_buffer_A(en_output_buffer_A),
        .en_output_buffer_B(en_output_buffer_B),
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
            output_select = 0;
            en_input_buffer_A = 0;
            en_input_buffer_B = 0;
            en_output_buffer_A = 0;
            en_output_buffer_B = 0;
            weight_load = 0;
            clear_input_data();
            
            #(CLK_PERIOD * 5);
            rst_n = 1;
            #(CLK_PERIOD * 2);
        end
    endtask

    // Load Weights into Buffer B
    // Buffer B is a shift register. We must push ARRAY_SIZE rows into it
    // so the exposed internal wires populate the entire 32x32 weight matrix.
    task load_weights_to_buffer;
        integer row, col;
        begin
            $display("[%0t] Starting Weight Load Sequence...", $time);
            for (row = 0; row < ARRAY_SIZE; row = row + 1) begin
                // Example: Fill a simple identity matrix pattern or constants
                for (col = 0; col < ARRAY_SIZE; col = col + 1) begin
                    input_data[col] = (row == col) ? 8'sd1 : 8'sd0; // Identity matrix
                end
                
                en_input_buffer_B = 1;
                #(CLK_PERIOD);
            end
            
            en_input_buffer_B = 0;
            
            // Strobe weight_load to copy from Buffer B internal wires to systolic array PEs
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
            systolic_input_select_A = 1'b0; // Select Buffer A (Assuming 0 selects flat_buffered_data_A)
            
            for (c = 0; c < num_cycles; c = c + 1) begin
                // Generate some dummy activation data (e.g., all 2s)
                for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                    input_data[i] = 8'sd2;
                end
                
                en_input_buffer_A = 1;  // Push to buffer A
                en = 1;                 // Fire systolic array PE enable
                #(CLK_PERIOD);
            end
            
            // Stop streaming
            en_input_buffer_A = 0;
            en = 0;
            clear_input_data();
        end
    endtask

    // Wait for output validity and latch it
    task capture_output;
        begin
            $display("[%0t] Waiting for result_valid...", $time);
            
            // Wait until the first valid output column appears
            wait(result_valid > 0);
            
            // Wait an additional latency period for the pipeline to fully drain 
            // (ARRAY_SIZE - 1 cycles for the rest of the columns to finish)
            #(CLK_PERIOD * (ARRAY_SIZE + 2)); 
            
            // Latch the final compute output into the register bank
            en_output_buffer_A = 1;
            #(CLK_PERIOD);
            en_output_buffer_A = 0;
            
            $display("[%0t] Results latched into output_buffer.", $time);
            $display("[%0t] output_data[31:0] (PE 0 output): %0d", $time, $signed(output_data[31:0]));
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

        // 2. Setup Weights (Buffer B -> PE array)
        load_weights_to_buffer();

        // 3. Setup and Run Activations
        // Let's stream K=4 rows of activations
        stream_activations(4);

        // 4. Wait for array completion and Latch Output
        capture_output();
        
        // 5. Finalize
        #(CLK_PERIOD * 10);
        $display("[%0t] Simulation Complete.", $time);
        $finish;
    end

    // Watchdog Timer
    initial begin
        #(CLK_PERIOD * 5000);
        $display("[%0t] ERROR: Watchdog timeout!", $time);
        $finish;
    end

endmodule