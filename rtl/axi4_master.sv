// axi4_master.sv
// AXI4 full master — burst read and write channels for DDR access.
// 64-bit data/address, INCR bursts, AxSIZE=3 (8B/beat), ID=0 (single master).
// Concurrent read and write FSMs — both channels operate independently.

`timescale 1ns/1ps

module axi4_master #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 64,
    parameter int ID_WIDTH   = 4
)(
    input  logic clk,
    input  logic rst_n,

    // ── AXI4 Read Address Channel (AR) ───────────────────────────────────────
    output logic [ID_WIDTH-1:0]     m_arid,
    output logic [ADDR_WIDTH-1:0]   m_araddr,
    output logic [7:0]              m_arlen,
    output logic [2:0]              m_arsize,
    output logic [1:0]              m_arburst,
    output logic [2:0]              m_arprot,
    output logic                    m_arvalid,
    input  logic                    m_arready,

    // ── AXI4 Read Data Channel (R) ───────────────────────────────────────────
    input  logic [ID_WIDTH-1:0]     m_rid,
    input  logic [DATA_WIDTH-1:0]   m_rdata,
    input  logic [1:0]              m_rresp,
    input  logic                    m_rlast,
    input  logic                    m_rvalid,
    output logic                    m_rready,

    // ── AXI4 Write Address Channel (AW) ──────────────────────────────────────
    output logic [ID_WIDTH-1:0]     m_awid,
    output logic [ADDR_WIDTH-1:0]   m_awaddr,
    output logic [7:0]              m_awlen,
    output logic [2:0]              m_awsize,
    output logic [1:0]              m_awburst,
    output logic [2:0]              m_awprot,
    output logic                    m_awvalid,
    input  logic                    m_awready,

    // ── AXI4 Write Data Channel (W) ──────────────────────────────────────────
    output logic [DATA_WIDTH-1:0]   m_wdata,
    output logic [DATA_WIDTH/8-1:0] m_wstrb,
    output logic                    m_wlast,
    output logic                    m_wvalid,
    input  logic                    m_wready,

    // ── AXI4 Write Response Channel (B) ──────────────────────────────────────
    input  logic [ID_WIDTH-1:0]     m_bid,
    input  logic [1:0]              m_bresp,
    input  logic                    m_bvalid,
    output logic                    m_bready,

    // ── Internal read interface ───────────────────────────────────────────────
    // Upstream pulses rd_start for one cycle while presenting rd_addr/rd_len.
    // rd_data_valid is asserted for one cycle per received beat.
    // rd_done pulses for one cycle when the burst completes.
    input  logic                    rd_start,
    input  logic [ADDR_WIDTH-1:0]   rd_addr,
    input  logic [7:0]              rd_len,       // AxLEN: beats-1 (e.g. 8'h07 = 8 beats)
    output logic [DATA_WIDTH-1:0]   rd_data,
    output logic                    rd_data_valid,
    output logic                    rd_done,
    output logic                    rd_error,

    // ── Internal write interface ──────────────────────────────────────────────
    // Upstream pulses wr_start with wr_addr/wr_len.
    // wr_data_ready goes high each cycle a beat is consumed (use as pop signal).
    // Upstream must hold wr_data stable until wr_data_ready is observed.
    // wr_done pulses for one cycle when B-channel handshake completes.
    input  logic                    wr_start,
    input  logic [ADDR_WIDTH-1:0]   wr_addr,
    input  logic [7:0]              wr_len,
    input  logic [DATA_WIDTH-1:0]   wr_data,
    output logic                    wr_data_ready,
    output logic                    wr_done,
    output logic                    wr_error
);

    // =========================================================================
    // Fixed AXI4 field values (Claude.md Section 6)
    // =========================================================================
    localparam logic [2:0]              AXI_SIZE  = 3'b011;  // 8 bytes/beat
    localparam logic [1:0]              AXI_BURST = 2'b01;   // INCR
    localparam logic [2:0]              AXI_PROT  = 3'b000;  // normal/non-secure/data
    localparam logic [ID_WIDTH-1:0]     AXI_ID    = '0;

    // =========================================================================
    // Read FSM
    // =========================================================================
    typedef enum logic [1:0] {
        RD_IDLE = 2'd0,
        RD_ADDR = 2'd1,   // AR channel: assert arvalid, wait for arready
        RD_DATA = 2'd2,   // R  channel: stream beats, check rresp
        RD_DONE = 2'd3    // one-cycle done pulse then back to idle
    } rd_state_t;

    rd_state_t rd_state;

    logic [ADDR_WIDTH-1:0] rd_addr_lat;
    logic [7:0]            rd_len_lat;
    logic [7:0]            rd_beat_cnt;   // counts down from AxLEN to 0
    logic                  rd_err_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_state    <= RD_IDLE;
            rd_addr_lat <= '0;
            rd_len_lat  <= '0;
            rd_beat_cnt <= '0;
            rd_err_lat  <= 1'b0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    rd_err_lat <= 1'b0;
                    if (rd_start) begin
                        rd_addr_lat <= rd_addr;
                        rd_len_lat  <= rd_len;
                        rd_beat_cnt <= rd_len;
                        rd_state    <= RD_ADDR;
                    end
                end

                RD_ADDR: begin
                    // Hold arvalid until arready — do not deassert early
                    if (m_arvalid && m_arready)
                        rd_state <= RD_DATA;
                end

                RD_DATA: begin
                    if (m_rvalid && m_rready) begin
                        if (m_rresp != 2'b00)
                            rd_err_lat <= 1'b1;
                        if (m_rlast || rd_beat_cnt == 8'h00)
                            rd_state <= RD_DONE;
                        else
                            rd_beat_cnt <= rd_beat_cnt - 8'h01;
                    end
                end

                RD_DONE: begin
                    rd_state <= RD_IDLE;
                end

                default: rd_state <= RD_IDLE;
            endcase
        end
    end

    // AR channel
    assign m_arid    = AXI_ID;
    assign m_araddr  = rd_addr_lat;
    assign m_arlen   = rd_len_lat;
    assign m_arsize  = AXI_SIZE;
    assign m_arburst = AXI_BURST;
    assign m_arprot  = AXI_PROT;
    assign m_arvalid = (rd_state == RD_ADDR);

    // R channel
    assign m_rready      = (rd_state == RD_DATA);
    assign rd_data       = m_rdata;
    assign rd_data_valid = (rd_state == RD_DATA) && m_rvalid && m_rready;
    assign rd_done       = (rd_state == RD_DONE);
    assign rd_error      = (rd_state == RD_DONE) && rd_err_lat;

    // =========================================================================
    // Write FSM
    // =========================================================================
    typedef enum logic [1:0] {
        WR_IDLE = 2'd0,
        WR_ADDR = 2'd1,   // AW channel: assert awvalid, wait for awready
        WR_DATA = 2'd2,   // W  channel: stream beats, assert wlast on final
        WR_RESP = 2'd3    // B  channel: wait for bvalid/bready
    } wr_state_t;

    wr_state_t wr_state;

    logic [ADDR_WIDTH-1:0] wr_addr_lat;
    logic [7:0]            wr_len_lat;
    logic [7:0]            wr_beat_cnt;
    logic                  wr_err_lat;
    logic                  wr_done_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_state    <= WR_IDLE;
            wr_addr_lat <= '0;
            wr_len_lat  <= '0;
            wr_beat_cnt <= '0;
            wr_err_lat  <= 1'b0;
            wr_done_r   <= 1'b0;
        end else begin
            wr_done_r <= 1'b0;  // default: deassert each cycle

            case (wr_state)
                WR_IDLE: begin
                    wr_err_lat <= 1'b0;
                    if (wr_start) begin
                        wr_addr_lat <= wr_addr;
                        wr_len_lat  <= wr_len;
                        wr_beat_cnt <= wr_len;
                        wr_state    <= WR_ADDR;
                    end
                end

                WR_ADDR: begin
                    if (m_awvalid && m_awready)
                        wr_state <= WR_DATA;
                end

                WR_DATA: begin
                    if (m_wvalid && m_wready) begin
                        if (wr_beat_cnt == 8'h00)
                            wr_state <= WR_RESP;          // WLAST beat accepted
                        else
                            wr_beat_cnt <= wr_beat_cnt - 8'h01;
                    end
                end

                WR_RESP: begin
                    if (m_bvalid && m_bready) begin
                        if (m_bresp != 2'b00)
                            wr_err_lat <= 1'b1;
                        wr_done_r <= 1'b1;
                        wr_state  <= WR_IDLE;
                    end
                end

                default: wr_state <= WR_IDLE;
            endcase
        end
    end

    // AW channel
    assign m_awid    = AXI_ID;
    assign m_awaddr  = wr_addr_lat;
    assign m_awlen   = wr_len_lat;
    assign m_awsize  = AXI_SIZE;
    assign m_awburst = AXI_BURST;
    assign m_awprot  = AXI_PROT;
    assign m_awvalid = (wr_state == WR_ADDR);

    // W channel — upstream must hold wr_data stable until wr_data_ready pulses
    assign m_wdata       = wr_data;
    assign m_wstrb       = {(DATA_WIDTH/8){1'b1}};
    assign m_wlast       = (wr_state == WR_DATA) && (wr_beat_cnt == 8'h00);
    assign m_wvalid      = (wr_state == WR_DATA);
    assign wr_data_ready = (wr_state == WR_DATA) && m_wready;

    // B channel
    assign m_bready  = (wr_state == WR_RESP);
    assign wr_done   = wr_done_r;
    assign wr_error  = wr_done_r && wr_err_lat;

endmodule
