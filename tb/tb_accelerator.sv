`timescale 1ns/1ps

module tb_accelerator;

    // Parameters
    parameter ARRAY_SIZE = 32;
    parameter DATA_WIDTH = 8;
    parameter CLK_PERIOD = 10;

    // Clock and Reset
    reg clk;
    reg rst_n;

    // Global signals
    reg en;
    reg systolic_input_select_A;
    wire [3:0] fsm_state;

    // Legacy datapath ports (driven to 0; retained because the accelerator
    // wrapper still exposes them)
    reg signed [DATA_WIDTH-1:0] input_data[0:ARRAY_SIZE-1];
    reg en_input_buffer_A, en_input_buffer_B, weight_load;

    // Status outputs
    wire perf_valid;
    wire [31:0] perf_cycles;
    wire [31:0] result_valid;
    wire busy, done, error;
    wire start_pulse, soft_reset;
    wire [31:0] src_addr, dst_addr, weight_addr;
    wire [15:0] img_rows, img_cols;

    // ---------------------------------------------------------
    // AXI4-Lite Slave Interfaces (Driven by TB to simulate CPU)
    // ---------------------------------------------------------
    reg  s_awvalid;
    wire s_awready;
    reg  [31:0] s_awaddr;
    reg  s_wvalid;
    wire s_wready;
    reg  [31:0] s_wdata;
    reg  [3:0] s_wstrb;
    wire s_bvalid;
    reg  s_bready;
    wire [1:0] s_bresp;
    reg  s_arvalid;
    wire s_arready;
    reg  [31:0] s_araddr;
    wire s_rvalid;
    reg  s_rready;
    wire [31:0] s_rdata;
    wire [1:0] s_rresp;

    // ---------------------------------------------------------
    // AXI4 Master Interfaces (Driven by DUT, responded to by TB)
    // ---------------------------------------------------------
    wire [3:0] m_arid, m_awid;
    wire [31:0] m_araddr, m_awaddr;
    wire [7:0] m_arlen, m_awlen;
    wire [2:0] m_arsize, m_awsize;
    wire [1:0] m_arburst, m_awburst;
    wire [2:0] m_arprot, m_awprot;
    wire m_arvalid, m_awvalid;
    reg  m_arready, m_awready;
    
    wire [3:0] m_wstrb;
    wire m_wlast, m_wvalid;
    reg  m_wready;
    wire [31:0] m_wdata;
    
    reg  [3:0] m_rid;
    reg  [31:0] m_rdata;
    reg  [1:0] m_rresp;
    reg  m_rlast, m_rvalid;
    wire m_rready;
    
    reg  [3:0] m_bid;
    reg  [1:0] m_bresp;
    reg  m_bvalid;
    wire m_bready;
    wire wr_error;

    localparam [31:0] REG_CTRL        = 32'h0000_0000;
    localparam [31:0] REG_SRC_ADDR    = 32'h0000_0008;
    localparam [31:0] REG_DST_ADDR    = 32'h0000_000C;
    localparam [31:0] REG_IMG_DIM     = 32'h0000_0010;
    localparam [31:0] REG_WEIGHT_ADDR = 32'h0000_0014;
    localparam [31:0] SRC_BASE        = 32'h0000_0000;
    localparam [31:0] WEIGHT_BASE     = 32'h0000_0100;
    localparam [31:0] DST_BASE        = 32'h0000_0200;

    // ---------------------------------------------------------
    // DUT Instantiation
    // ---------------------------------------------------------
    accelerator #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .en(en),
        .input_data(input_data),
        .systolic_input_select_A(systolic_input_select_A),
        .fsm_state(fsm_state),
        
        .en_input_buffer_A(en_input_buffer_A),
        .en_input_buffer_B(en_input_buffer_B),
        .weight_load(weight_load),
        
        .perf_valid(perf_valid), .perf_cycles(perf_cycles), .result_valid(result_valid),
        
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
        .m_arburst(m_arburst), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rvalid(m_rvalid), .m_rready(m_rready),
        
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
        .m_awburst(m_awburst), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready), .wr_error(wr_error),
        
        .s_awvalid(s_awvalid), .s_awready(s_awready), .s_awaddr(s_awaddr),
        .s_wvalid(s_wvalid), .s_wready(s_wready), .s_wdata(s_wdata), .s_wstrb(s_wstrb),
        .s_bvalid(s_bvalid), .s_bready(s_bready), .s_bresp(s_bresp),
        .s_arvalid(s_arvalid), .s_arready(s_arready), .s_araddr(s_araddr),
        .s_rvalid(s_rvalid), .s_rready(s_rready), .s_rdata(s_rdata), .s_rresp(s_rresp),
        
        .start_pulse(start_pulse), .soft_reset(soft_reset),
        .src_addr(src_addr), .dst_addr(dst_addr), .weight_addr(weight_addr),
        .img_rows(img_rows), .img_cols(img_cols),
        .busy(busy), .done(done), .error(error)
    );

    // ---------------------------------------------------------
    // Clock Generation
    // ---------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---------------------------------------------------------
    // Mock Memory for AXI Master Data (256 Words = 1KB)
    // ---------------------------------------------------------
    reg [31:0] mock_ram [0:255];
    
    // Read Channel Mock
    reg [7:0]  read_burst_count;
    reg [31:0] current_raddr;
    reg        is_reading;
    integer    write_beat_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_arready <= 0;
            m_rvalid  <= 0;
            m_rlast   <= 0;
            is_reading <= 0;
            m_rresp   <= 2'b00;
            write_beat_count <= 0;
        end else begin
            // Address Phase
            if (m_arvalid && !is_reading) begin
                m_arready <= 1;
                current_raddr <= m_araddr;
                read_burst_count <= m_arlen;
                is_reading <= 1;
            end else begin
                m_arready <= 0;
            end

            // Data Phase
            if (is_reading && !m_arready) begin
                m_rvalid <= 1;
                m_rdata  <= mock_ram[current_raddr[9:2]]; // Word aligned lookup
                m_rlast  <= (read_burst_count == 0);

                if (m_rvalid && m_rready) begin
                    current_raddr <= current_raddr + 4;
                    if (read_burst_count == 0) begin
                        is_reading <= 0;
                        m_rvalid <= 0;
                        m_rlast <= 0;
                    end else begin
                        read_burst_count <= read_burst_count - 1;
                    end
                end
            end
        end
    end

    // Write Channel Mock
    reg [31:0] current_waddr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_awready <= 0;
            m_wready  <= 0;
            m_bvalid  <= 0;
        end else begin
            // Accept Write Address
            if (m_awvalid && !m_awready) begin
                m_awready <= 1;
                current_waddr <= m_awaddr;
            end else begin
                m_awready <= 0;
            end

            // Accept Write Data
            if (m_wvalid && !m_wready) begin
                m_wready <= 1;
            end else if (m_wvalid && m_wready) begin
                mock_ram[current_waddr[9:2]] <= m_wdata;
                current_waddr <= current_waddr + 4;
                write_beat_count <= write_beat_count + 1;
                if (m_wlast) m_wready <= 0; // Wait for next valid
            end else begin
                m_wready <= 0;
            end

            // Write Response
            if (m_wvalid && m_wready && m_wlast) begin
                m_bvalid <= 1;
                m_bresp  <= 2'b00;
            end else if (m_bvalid && m_bready) begin
                m_bvalid <= 0;
            end
        end
    end

    // ---------------------------------------------------------
    // AXI-Lite Write Task (Simulate CPU sending configuration)
    // ---------------------------------------------------------
    task axi_lite_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_awvalid = 1; s_awaddr = addr;
            s_wvalid = 1;  s_wdata = data; s_wstrb = 4'hF; s_bready = 1;
            
            wait (s_awready && s_wready);
            @(posedge clk);
            s_awvalid = 0; s_wvalid = 0;
            
            wait (s_bvalid);
            @(posedge clk);
            s_bready = 0;
        end
    endtask

    // ---------------------------------------------------------
    // Main Test Sequence
    // ---------------------------------------------------------
    integer i;
    initial begin
        // 1. Initialize Inputs
        clk = 0;
        rst_n = 0;
        en = 1;
        systolic_input_select_A = 0;
        en_input_buffer_A = 0;
        en_input_buffer_B = 0;
        weight_load = 0;
        
        s_awvalid = 0; s_wvalid = 0; s_bready = 0;
        s_arvalid = 0; s_rready = 0;

        // Initialize Memory with deterministic values.
        for (i = 0; i < 256; i = i + 1) begin
            mock_ram[i] = i * 8 + 3; 
        end

        // 2. Reset Sequence
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 5);

        $display("[%0t] Reset complete. Configuring via AXI-Lite...", $time);

        // 3. Configure Registers
        axi_lite_write(REG_SRC_ADDR, SRC_BASE);
        axi_lite_write(REG_WEIGHT_ADDR, WEIGHT_BASE);
        axi_lite_write(REG_DST_ADDR, DST_BASE);
        axi_lite_write(REG_IMG_DIM, 32'h0020_0020); // 32x32, packed as rows:cols

        $display("[%0t] Registers configured. Triggering start...", $time);
        
        // Trigger start.
        axi_lite_write(REG_CTRL, 32'h0000_0001);

        // 4. Wait for processing to complete
        $display("[%0t] Waiting for processing to finish...", $time);
        
        // Wait for the done signal to be asserted by the control unit
        wait (done == 1'b1);
        
        $display("[%0t] Accelerator done!", $time);

        // 5. Inspect memory to verify results were written back
        #(CLK_PERIOD * 5);
        $display("Data written back to memory at DST_ADDR (0x200):");
        $display("Write beats observed: %0d", write_beat_count);
        for (i = 128; i < 160; i = i + 1) begin
            $display("mock_ram[%0d] = %h", i, mock_ram[i]);
        end

        if (write_beat_count !== 32) begin
            $display("ERROR: Expected 32 write beats, saw %0d", write_beat_count);
        end

        $finish;
    end

endmodule