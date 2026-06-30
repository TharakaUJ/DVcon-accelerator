`timescale 1ns/1ps

module control_unit #(
    parameter ROM_DEPTH = 16
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // Triggers and Addresses from AXI-Lite
    input  wire        start_pulse,
    input  wire [31:0] src_addr,
    input  wire [31:0] weight_addr,
    input  wire [31:0] dst_addr,
    
    // Status back to AXI-Lite
    output reg         busy,
    output reg         done,
    input  wire        perf_valid,
    
    // AXI Master Control
    output reg         rd_start,
    output reg  [31:0] rd_addr,
    output reg  [7:0]  rd_len,
    input  wire        rd_done,
    input  wire        rd_data_valid,
    
    output reg         wr_start,
    output reg  [31:0] wr_addr,
    output reg  [7:0]  wr_len,
    input  wire        wr_done,
    input  wire        wr_data_ready,
    
    // Datapath Control
    output reg  [3:0]  fsm_state,
    output reg         en_input_buffer_A,
    output reg         en_input_buffer_B,
    output reg         weight_load,
    output reg         systolic_input_select_A,
    
    // Alignment helpers for the datapath width mismatches
    output reg  [2:0]  rd_word_idx, // 0-7 (to pack eight 32-bit words into 256 bits)
    output reg  [4:0]  wr_word_idx  // 0-31 (to unpack 32 32-bit words for writing)
);

    // FSM States
    localparam IDLE         = 4'd0;
    localparam FETCH_WEIGHT = 4'd1;
    localparam LOAD_WEIGHT  = 4'd2;
    localparam FETCH_ACT    = 4'd3;
    localparam COMPUTE      = 4'd4;
    localparam WRITE_BACK   = 4'd5;
    localparam DONE_STATE   = 4'd6;

    reg [3:0] state, next_state;

    // FSM Sequential Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            rd_word_idx <= 0;
            wr_word_idx <= 0;
        end else begin
            state <= next_state;

            if (state == IDLE && start_pulse) begin
                rd_word_idx <= 0;
                wr_word_idx <= 0;
            end
            
            // Track incoming AXI reads to pack data
            if (rd_data_valid && (state == FETCH_WEIGHT || state == FETCH_ACT))
                rd_word_idx <= rd_word_idx + 1;
                
            // Track outgoing AXI writes when the master accepts a beat
            if (state == WRITE_BACK && wr_data_ready)
                wr_word_idx <= wr_word_idx + 1; // Assuming 1 word written per cycle during burst
        end
    end

    // FSM Combinational Logic
    always @(*) begin
        // Default assignments
        next_state = state;
        busy = 1'b1;
        done = 1'b0;
        rd_start = 1'b0;
        wr_start = 1'b0;
        en_input_buffer_A = 1'b0;
        en_input_buffer_B = 1'b0;
        weight_load = 1'b0;
        fsm_state = state;

        case (state)
            IDLE: begin
                busy = 1'b0;
                if (start_pulse) begin
                    next_state = FETCH_WEIGHT;
                end
            end

            FETCH_WEIGHT: begin
                rd_start = 1'b1;
                rd_addr  = weight_addr;
                rd_len   = 8'd31; // Fetching 32 bursts (example size, adjust to actual matrix reqs)
                en_input_buffer_B = rd_data_valid && (rd_word_idx == 3'd7); // Enable buffer shift every 8 words (256 bits)
                
                if (rd_done) next_state = LOAD_WEIGHT;
            end

            LOAD_WEIGHT: begin
                weight_load = 1'b1;
                next_state = FETCH_ACT;
            end

            FETCH_ACT: begin
                rd_start = 1'b1;
                rd_addr  = src_addr;
                rd_len   = 8'd31; 
                en_input_buffer_A = rd_data_valid && (rd_word_idx == 3'd7); // Enable shift every 8 words
                
                if (rd_done) next_state = COMPUTE;
            end

            COMPUTE: begin
                // Wait for the systolic array to finish before writing results back.
                if (perf_valid) next_state = WRITE_BACK;
            end

            WRITE_BACK: begin
                wr_start = 1'b1;
                wr_addr  = dst_addr;
                wr_len   = 8'd31; // Burst 32 words out (32 * 32-bits = 1024 bits of Q)
                if (wr_done) next_state = DONE_STATE;
            end

            DONE_STATE: begin
                done = 1'b1;
                busy = 1'b0;
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
endmodule