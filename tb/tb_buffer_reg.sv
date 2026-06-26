`timescale 1ns/1ps

module tb_buffer_reg;
    parameter integer DATA_WIDTH   = 8;   
    parameter integer BUFFER_WIDTH = 32;

    reg                             clk;
    reg                             rst_n;
    reg                             en;
    
    reg  signed [DATA_WIDTH-1:0]    buffer_in  [0:BUFFER_WIDTH-1];
    wire signed [DATA_WIDTH-1:0]    buffer_out [0:BUFFER_WIDTH-1];

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer idx;

    task check_int;
        input [255:0] tag;
        input integer index;
        input integer got;
        input integer exp;
        begin
            if (got === exp) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %s [Index %0d]  got=%0d  exp=%0d", tag, index, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    buffer_reg #(
        .DATA_WIDTH(DATA_WIDTH),
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
        clk   = 0;
        rst_n = 0;
        en    = 0;
        
        // Initialize the input array to 0
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            buffer_in[idx] = 0;
        end

        #15;
        rst_n = 1;
        $display("--- Reset Released ---");

        // --- TEST 1: Check output after reset before clocking data ---
        @(posedge clk);
        #1; 
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            check_int("Reset State Check", idx, buffer_out[idx], 0);
        end

        // --- TEST 2: Try to write data while EN is LOW ---
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            buffer_in[idx] = idx + 10; // Fills array with 10, 11, 12...
        end
        en = 0;
        @(posedge clk);
        #1;
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            check_int("Disabled Write Check", idx, buffer_out[idx], 0);
        end

        // --- TEST 3: Enable write (EN is HIGH) ---
        en = 1;
        @(posedge clk);
        #1;
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            check_int("Enabled Write Check", idx, buffer_out[idx], idx + 10);
        end

        // --- TEST 4: Hold data when EN goes LOW again ---
        en = 0;
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            buffer_in[idx] = idx + 50; // Changing input array
        end
        @(posedge clk);
        #1;
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            // Should still hold old values (idx + 10)
            check_int("Hold Data Check", idx, buffer_out[idx], idx + 10);
        end

        // --- TEST 5: Signed Value Handling ---
        en = 1;
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            buffer_in[idx] = -idx - 1; // Negative signed values
        end
        @(posedge clk);
        #1;
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            check_int("Signed Negative Check", idx, buffer_out[idx], -idx - 1);
        end

        // --- TEST 6: Asynchronous Reset Test ---
        en = 0;
        #3;
        rst_n = 0; 
        #1; // Verify immediate drop without waiting for posedge clk
        for (idx = 0; idx < BUFFER_WIDTH; idx = idx + 1) begin
            check_int("Async Reset Check", idx, buffer_out[idx], 0);
        end

        // --- Final Report ---
        $display("\n==================================");
        $display("  SIMULATION COMPLETE");
        if (fail_cnt == 0) begin
            $display("  SUCCESS: All array checks passed perfectly!");
        end else begin
            $display("  FAILURE: Found errors during check.");
        end
        $display("  Total Element Checks Passed: %0d", pass_cnt);
        $display("  Total Element Checks Failed: %0d", fail_cnt);
        $display("==================================");
        
        $finish; 
    end

endmodule
