`timescale 1ns/1ps

module tb_buffer_reg;
    parameter integer BUFFER_WIDTH = 32;

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

    buffer_reg #(
        .BUFFER_WIDTH(BUFFER_WIDTH)
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
        @(posedge clk);
        #1; // Small delay after edge to avoid sampling race conditions
        check_int("Reset State Check", buffer_out, 32'd0);

        // --- TEST 2: Try to write data while EN is LOW ---
        buffer_in = 32'd42;
        en        = 0;
        @(posedge clk);
        #1;
        check_int("Disabled Write Check", buffer_out, 32'd0);

        // --- TEST 3: Enable write (EN is HIGH) ---
        en = 1;
        @(posedge clk);
        #1;
        check_int("Enabled Write Check", buffer_out, 32'd42);

        // --- TEST 4: Hold data when EN goes LOW again ---
        en        = 0;
        buffer_in = 32'd99; // Input changes, but output should hold 42
        @(posedge clk);
        #1;
        check_int("Hold Data Check", buffer_out, 32'd42);

        // --- TEST 5: Signed Value Handling ---
        en        = 1;
        buffer_in = -32'd15; // Drive a negative signed number
        @(posedge clk);
        #1;
        check_int("Signed Negative Check", buffer_out, -32'd15);

        // --- TEST 6: Asynchronous Reset Test ---
        en        = 0;
        #3;        // Assert reset mid-clock cycle
        rst_n     = 0; 
        #1;        // Verify immediate drop without waiting for posedge clk
        check_int("Async Reset Check", buffer_out, 32'd0);

        // --- Final Report ---
        $display("\n==================================");
        $display("  SIMULATION COMPLETE");
        $display("  Total Tests Passed: %0d", pass_cnt);
        $display("  Total Tests Failed: %0d", fail_cnt);
        $display("==================================");
        
        $finish; // End simulation
    end

endmodule
