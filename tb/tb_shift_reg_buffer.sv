`timescale 1ns/1ps

module tb_shift_reg_buffer;
    parameter integer DATA_WIDTH   = 8;
    parameter integer BUFFER_WIDTH = 32;
    parameter integer BUFFER_DEPTH = 3;
    parameter bit     EXPOSE_INTERNAL_WIRES = 1;

    reg                          clk;
    reg                          rst_n;
    reg                          en;
    
    reg  signed [DATA_WIDTH-1:0] buffer_in  [0:BUFFER_WIDTH-1];
    wire signed [DATA_WIDTH-1:0] buffer_out [0:BUFFER_WIDTH-1];
    
    wire signed [DATA_WIDTH-1:0] connect_wires_out [0:(BUFFER_WIDTH*BUFFER_DEPTH)-1];

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // --- Helper Tasks ---
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

    // Helper task to clear or fill the whole buffer input channel easily
    task set_buffer_in(input int value);
        int idx;
        begin
            for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
                buffer_in[idx] = value[DATA_WIDTH-1:0];
            end
        end
    endtask

    // --- DUT Instantiation ---
    shift_reg_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .BUFFER_WIDTH(BUFFER_WIDTH),
        .BUFFER_DEPTH(BUFFER_DEPTH),
        .EXPOSE_INTERNAL_WIRES(EXPOSE_INTERNAL_WIRES)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .buffer_in(buffer_in),
        .buffer_out(buffer_out),
        .connect_wires_out(connect_wires_out)
    );

    // --- Clock Generator ---
    always begin
        #5 clk = ~clk;
    end

    // --- Main Test Loop ---
    initial begin
        clk   = 0;
        rst_n = 0;
        en    = 0;
        set_buffer_in(0);

        #15;
        rst_n = 1;
        $display("--- Reset Released ---");

        // --- TEST 1: Check output after reset before clocking data ---
        @(posedge clk); #1; 
        check_int("Reset State Check", buffer_out[0], 0);

        // --- TEST 2: Try to write data while EN is LOW ---
        set_buffer_in(42);
        en = 0;
        @(posedge clk); #1; check_int("Disabled Write Check (1st cycle)", buffer_out[0], 0);
        @(posedge clk); #1; check_int("Disabled Write Check (2nd cycle)", buffer_out[0], 0);
        @(posedge clk); #1; check_int("Disabled Write Check (3rd cycle)", buffer_out[0], 0);

        // --- TEST 3: Propagate single value through depth of 3 ---
        en = 1;
        set_buffer_in(42);
        @(posedge clk); #1; check_int("Propagate T1", buffer_out[0], 0);
        
        // Debug Wire Checks (uses flat indexed math to find the target stage element)
        if (EXPOSE_INTERNAL_WIRES) begin
            // Stage 1, element 0
            check_int("Debug Capture Stage 1", connect_wires_out[(0 * BUFFER_WIDTH) + 0], 42);
        end

        set_buffer_in(69); 
        @(posedge clk); #1; check_int("Propagate T2", buffer_out[0], 0);
        
        if (EXPOSE_INTERNAL_WIRES) begin
            check_int("Debug Capture Stage 1", connect_wires_out[(0 * BUFFER_WIDTH) + 0], 69);
            check_int("Debug Capture Stage 2", connect_wires_out[(1 * BUFFER_WIDTH) + 0], 42);
        end

        set_buffer_in(0);
        @(posedge clk); #1; check_int("Propagate T4", buffer_out[0], 69);  

        // --- TEST 4: Continuous Streaming Data ---
        $display("--- Starting Test 4: Continuous Stream ---");
        en = 1;
        set_buffer_in(10); @(posedge clk); #1;
        set_buffer_in(20); @(posedge clk); #1;
        set_buffer_in(30); @(posedge clk); #1; check_int("Stream Out 10", buffer_out[0], 10);
        set_buffer_in(40); @(posedge clk); #1; check_int("Stream Out 20", buffer_out[0], 20);
        set_buffer_in(50); @(posedge clk); #1; check_int("Stream Out 30", buffer_out[0], 30);
        set_buffer_in(0);  @(posedge clk); #1; check_int("Stream Out 40", buffer_out[0], 40);
                            @(posedge clk); #1; check_int("Stream Out 50", buffer_out[0], 50);

        // --- TEST 5: Mid-Pipeline Pause (De-assert EN) ---
        $display("--- Starting Test 5: Mid-Pipeline Pause ---");
        en = 1;
        set_buffer_in(77); @(posedge clk); #1; 
        set_buffer_in(88); @(posedge clk); #1; 
        
        en = 0; 
        set_buffer_in(99); 
        @(posedge clk); #1; check_int("Paused Cycle 1", buffer_out[0], 0);
        @(posedge clk); #1; check_int("Paused Cycle 2", buffer_out[0], 0);
        
        en = 1; 
        set_buffer_in(0);
        @(posedge clk); #1; check_int("Unfreeze T3", buffer_out[0], 77); 
        @(posedge clk); #1; check_int("Unfreeze T4", buffer_out[0], 88); 
        @(posedge clk); #1; check_int("Unfreeze T5", buffer_out[0], 0);  

        // --- TEST 6: Signed Extremes Boundary Test ---
        $display("--- Starting Test 6: Signed Limits ---");
        en = 1;
        
        // Using dynamically sized sign boundaries based on your parameters
        set_buffer_in(-(1 << (DATA_WIDTH-1))); // Min signed bound
        @(posedge clk); #1;
        set_buffer_in((1 << (DATA_WIDTH-1)) - 1); // Max signed bound
        @(posedge clk); #1;
        set_buffer_in(-1);          
        @(posedge clk); #1; check_int("Verify Min Signed", buffer_out[0], -(1 << (DATA_WIDTH-1)));
        set_buffer_in(0);
        @(posedge clk); #1; check_int("Verify Max Signed", buffer_out[0], (1 << (DATA_WIDTH-1)) - 1);
        @(posedge clk); #1; check_int("Verify Neg One",    buffer_out[0], -1);

        // --- TEST 7: Mid-Cycle Asynchronous Reset ---
        $display("--- Starting Test 7: Asynchronous Reset ---");
        en = 1;
        set_buffer_in(55);
        @(posedge clk); #1;
        @(posedge clk); #1; 
        
        #3; 
        rst_n = 0;
        #1; 
        check_int("Instant Async Reset Check", buffer_out[0], 0);
        
        #10;
        rst_n = 1; 

        // --- Final Report ---
        $display("\n==================================");
        $display("  SIMULATION COMPLETE");
        $display("  Total Tests Passed: %0d", pass_cnt);
        $display("  Total Tests Failed: %0d", fail_cnt);
        $display("==================================");
        
        $finish; 
    end

endmodule