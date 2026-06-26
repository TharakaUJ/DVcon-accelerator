`timescale 1ns/1ps

module tb_register_bank;
    // --- Parameters ---
    parameter int DATA_WIDTH   = 8;
    parameter int BUFFER_WIDTH = 4; // Scaled down to 4 for simple tracing

    // --- Signals ---
    logic                          clk;
    logic                          rst_n;
    logic                          en;
    logic [$clog2(BUFFER_WIDTH)-1:0] input_reg_select;
    logic [$clog2(BUFFER_WIDTH)-1:0] output_reg_select;
    logic signed [DATA_WIDTH-1:0]  register_data_in;
    
    wire signed [DATA_WIDTH-1:0]   register_data_out;
    wire signed [DATA_WIDTH-1:0]   connect_wires_out [0:BUFFER_WIDTH-1];

    // --- UUT Instantiation ---
    register_bank #(
        .DATA_WIDTH(DATA_WIDTH),
        .BUFFER_WIDTH(BUFFER_WIDTH),
        .EXPOSE_INTERNAL_WIRES(1)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .input_reg_select(input_reg_select),
        .output_reg_select(output_reg_select),
        .register_data_in(register_data_in),
        .register_data_out(register_data_out),
        .connect_wires_out(connect_wires_out)
    );

    // --- Clock Generation (100MHz) ---
    always #5 clk = ~clk;

    // --- Main Verification Flow ---
    initial begin
        // Initialize everything
        clk               = 0;
        rst_n             = 0;
        en                = 0;
        input_reg_select  = 0;
        output_reg_select = 0;
        register_data_in  = 0;

        // Apply Reset
        #15 rst_n = 1;
        $display("[%0t ns] --- System Reset Released ---", $time);

        // --- STEP 1: Test Write/Read to Register 0 ---
        @(posedge clk);
        #1;
        en               = 1;
        input_reg_select = 2'd0; // Address 0
        register_data_in = 8'd42; // Data payload
        
        @(posedge clk); // Data locks into Reg 0 here
        #1;
        en               = 0;   // Turn off write enable
        output_reg_select = 2'd0; // Point read mux to Address 0
        
        #1; // Allow combinational mux read propagation
        if (register_data_out === 8'd42) 
            $display("PASS: Successfully wrote and read 42 from Reg 0.");
        else 
            $display("FAIL: Reg 0 read back %0d instead of 42.", register_data_out);

        // --- STEP 2: Test Write to Register 2 and Verify Isolation ---
        @(posedge clk);
        #1;
        en               = 1;
        input_reg_select = 2'd2; // Address 2
        register_data_in = -8'd10; // Signed data payload
        
        @(posedge clk); // Data locks into Reg 2 here
        #1;
        en               = 0;
        
        // Read back Reg 2
        output_reg_select = 2'd2; 
        #1;
        if (register_data_out === -8'd10)
            $display("PASS: Successfully wrote and read -10 from Reg 2.");
        else
            $display("FAIL: Reg 2 read back %0d.", register_data_out);

        // Check Reg 0 to make sure it wasn't overwritten by the Reg 2 operation
        output_reg_select = 2'd0;
        #1;
        if (register_data_out === 8'd42)
            $display("PASS: Reg 0 kept its contents perfectly (Isolation holds).");
        else
            $display("FAIL: Reg 0 was corrupted! Value is %0d.", register_data_out);

        // --- STEP 3: Check Debug / Exposed Internal Wires ---
        if (connect_wires_out[2] === -8'd10)
            $display("PASS: Internal wires debug interface accurately exposed Reg 2.");
        else
            $display("FAIL: Internal wire debug matrix mismatch.");

        $display("[%0t ns] --- Simulation Complete ---", $time);
        $finish;
    end

endmodule