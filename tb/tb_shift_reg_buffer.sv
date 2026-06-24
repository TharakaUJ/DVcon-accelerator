`timescale 1ns/1ps

module tb_shift_reg_buffer;
    parameter integer BUFFER_WIDTH = 32;
    parameter integer BUFFER_DEPTH = 3;

    reg                          clk;
    reg                          rst_n;
    reg                          en;
    reg signed [BUFFER_WIDTH-1:0] buffer_in;

    wire signed [BUFFER_WIDTH-1:0] buffer_out;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

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

    shift_reg_buffer #(
        .BUFFER_WIDTH(BUFFER_WIDTH),
        .BUFFER_DEPTH(BUFFER_DEPTH)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .buffer_in(buffer_in),
        .buffer_out(buffer_out)
    );

    always begin
        #5 clk = ~clk;
    end

    initial begin
        clk       = 0;
        rst_n     = 0;
        en        = 0;
        buffer_in = 0;

        #15;
        rst_n = 1;
        $display("--- Reset Released ---");

        // --- TEST 1: Check output after reset before clocking data ---
        @(posedge clk); #1; 
        check_int("Reset State Check", buffer_out, 32'd0);

        // --- TEST 2: Try to write data while EN is LOW ---
        buffer_in = 32'd42;
        en        = 0;
        @(posedge clk); #1; check_int("Disabled Write Check (1st cycle)", buffer_out, 32'd0);
        @(posedge clk); #1; check_int("Disabled Write Check (2nd cycle)", buffer_out, 32'd0);
        @(posedge clk); #1; check_int("Disabled Write Check (3rd cycle)", buffer_out, 32'd0);

        // --- TEST 3: Propagate single value through depth of 3 ---
        en = 1;
        buffer_in = 32'd42;
        @(posedge clk); #1; check_int("Propagate T1", buffer_out, 32'd0);
        buffer_in = 32'd69; // Clear input to prove it's a moving pulse
        @(posedge clk); #1; check_int("Propagate T2", buffer_out, 32'd0);
        @(posedge clk); #1; check_int("Propagate T3", buffer_out, 32'd42); // Value arrives
        buffer_in = 32'd0;
        @(posedge clk); #1; check_int("Propagate T4", buffer_out, 32'd69);  // Value leaves

        // --- NEW TEST 4: Continuous Streaming Data ---
        $display("--- Starting Test 4: Continuous Stream ---");
        en = 1;
        buffer_in = 32'd10; @(posedge clk); #1;
        buffer_in = 32'd20; @(posedge clk); #1;
        buffer_in = 32'd30; @(posedge clk); #1; check_int("Stream Out 10", buffer_out, 32'd10);
        buffer_in = 32'd40; @(posedge clk); #1; check_int("Stream Out 20", buffer_out, 32'd20);
        buffer_in = 32'd50; @(posedge clk); #1; check_int("Stream Out 30", buffer_out, 32'd30);
        buffer_in = 32'd0;  @(posedge clk); #1; check_int("Stream Out 40", buffer_out, 32'd40);
                            @(posedge clk); #1; check_int("Stream Out 50", buffer_out, 32'd50);

        // --- NEW TEST 5: Mid-Pipeline Pause (De-assert EN) ---
        $display("--- Starting Test 5: Mid-Pipeline Pause ---");
        en = 1;
        buffer_in = 32'd77; @(posedge clk); #1; // Pushed into stage 1
        buffer_in = 32'd88; @(posedge clk); #1; // 77 moves to stage 2, 88 to stage 1
        
        en = 0; // Freeze the entire pipeline
        buffer_in = 32'd99; // This input should be completely ignored
        @(posedge clk); #1; check_int("Paused Cycle 1", buffer_out, 32'd0);
        @(posedge clk); #1; check_int("Paused Cycle 2", buffer_out, 32'd0);
        
        en = 1; // Unfreeze pipeline
        buffer_in = 32'd0;
        @(posedge clk); #1; check_int("Unfreeze T3", buffer_out, 32'd77); // 77 finally arrives
        @(posedge clk); #1; check_int("Unfreeze T4", buffer_out, 32'd88); // 88 arrives
        @(posedge clk); #1; check_int("Unfreeze T5", buffer_out, 32'd0);  // 99 was ignored

        // --- NEW TEST 6: Signed Extremes Boundary Test ---
        $display("--- Starting Test 6: Signed Limits ---");
        en = 1;
        buffer_in = -32'd2147483648; // Minimum signed 32-bit integer (0x80000000)
        @(posedge clk); #1;
        buffer_in = 32'd2147483647;  // Maximum signed 32-bit integer (0x7FFFFFFF)
        @(posedge clk); #1;
        buffer_in = -32'd1;          // Negative one (0xFFFFFFFF)
        @(posedge clk); #1; check_int("Verify Min Signed", buffer_out, -32'd2147483648);
        buffer_in = 32'd0;
        @(posedge clk); #1; check_int("Verify Max Signed", buffer_out, 32'd2147483647);
        @(posedge clk); #1; check_int("Verify Neg One",    buffer_out, -32'd1);

        // --- NEW TEST 7: Mid-Cycle Asynchronous Reset ---
        $display("--- Starting Test 7: Asynchronous Reset ---");
        en = 1;
        buffer_in = 32'd55;
        @(posedge clk); #1;
        @(posedge clk); #1; // Data is deeply embedded in the middle stages
        
        #3; // Drop reset asynchronously 3ns after the clock edge
        rst_n = 0;
        #1; // Sample immediately to prove it didn't wait for a posedge clk
        check_int("Instant Async Reset Check", buffer_out, 32'd0);
        
        #10;
        rst_n = 1; // Bring it back up for safety

        // --- Final Report ---
        $display("\n==================================");
        $display("  SIMULATION COMPLETE");
        $display("  Total Tests Passed: %0d", pass_cnt);
        $display("  Total Tests Failed: %0d", fail_cnt);
        $display("==================================");
        
        $finish; 
    end

endmodule
