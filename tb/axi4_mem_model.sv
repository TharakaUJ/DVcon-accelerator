// axi4_mem_model.sv — AXI4 slave memory model for simulation.
// Byte-array backed. Responds to AR/R and AW/W/B channels with OKAY.
// Supports 64-bit INCR bursts. Shared between unit tests and integration TB.
// inject_rresp_err / inject_bresp_err ports allow single-burst error injection.

`timescale 1ns/1ps

module axi4_mem_model #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 64,
    parameter int ID_WIDTH   = 4,
    parameter int MEM_BYTES  = 65536    // total addressable bytes
)(
    input  logic clk,
    input  logic rst_n,

    // ── AXI4 Read Address Channel ─────────────────────────────────────────────
    input  logic [ID_WIDTH-1:0]     s_arid,
    input  logic [ADDR_WIDTH-1:0]   s_araddr,
    input  logic [7:0]              s_arlen,
    input  logic [2:0]              s_arsize,
    input  logic [1:0]              s_arburst,
    input  logic                    s_arvalid,
    output logic                    s_arready,

    // ── AXI4 Read Data Channel ────────────────────────────────────────────────
    output logic [ID_WIDTH-1:0]     s_rid,
    output logic [DATA_WIDTH-1:0]   s_rdata,
    output logic [1:0]              s_rresp,
    output logic                    s_rlast,
    output logic                    s_rvalid,
    input  logic                    s_rready,

    // ── AXI4 Write Address Channel ────────────────────────────────────────────
    input  logic [ID_WIDTH-1:0]     s_awid,
    input  logic [ADDR_WIDTH-1:0]   s_awaddr,
    input  logic [7:0]              s_awlen,
    input  logic [2:0]              s_awsize,
    input  logic [1:0]              s_awburst,
    input  logic                    s_awvalid,
    output logic                    s_awready,

    // ── AXI4 Write Data Channel ───────────────────────────────────────────────
    input  logic [DATA_WIDTH-1:0]   s_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_wstrb,
    input  logic                    s_wlast,
    input  logic                    s_wvalid,
    output logic                    s_wready,

    // ── AXI4 Write Response Channel ───────────────────────────────────────────
    output logic [ID_WIDTH-1:0]     s_bid,
    output logic [1:0]              s_bresp,
    output logic                    s_bvalid,
    input  logic                    s_bready,

    // ── Error injection (testbench use only) ─────────────────────────────────
    input  logic                    inject_rresp_err,   // force SLVERR on next read burst
    input  logic                    inject_bresp_err    // force SLVERR on next write response
);

    localparam int BPB = DATA_WIDTH / 8;    // bytes per beat

    // =========================================================================
    // Memory array — byte-addressable, word-aligned accesses only in practice
    // =========================================================================
    logic [7:0] mem [0:MEM_BYTES-1];

    // =========================================================================
    // Read FSM
    // =========================================================================
    typedef enum logic {
        RS_IDLE = 1'b0,
        RS_DATA = 1'b1
    } rs_t;
    rs_t rs_state;

    logic [ADDR_WIDTH-1:0] r_cur_addr;
    logic [7:0]            r_beat_cnt;
    logic [ID_WIDTH-1:0]   r_id;
    logic                  r_inject;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rs_state   <= RS_IDLE;
            r_cur_addr <= '0;
            r_beat_cnt <= '0;
            r_id       <= '0;
            r_inject   <= 1'b0;
        end else begin
            case (rs_state)
                RS_IDLE: begin
                    if (s_arvalid && s_arready) begin
                        r_cur_addr <= s_araddr;
                        r_beat_cnt <= s_arlen;
                        r_id       <= s_arid;
                        r_inject   <= inject_rresp_err;
                        rs_state   <= RS_DATA;
                    end
                end
                RS_DATA: begin
                    if (s_rvalid && s_rready) begin
                        if (r_beat_cnt == 8'h00)
                            rs_state <= RS_IDLE;
                        else begin
                            r_cur_addr <= r_cur_addr + ADDR_WIDTH'(BPB);
                            r_beat_cnt <= r_beat_cnt - 8'h01;
                        end
                    end
                end
                default: rs_state <= RS_IDLE;
            endcase
        end
    end

    assign s_arready = (rs_state == RS_IDLE);
    assign s_rvalid  = (rs_state == RS_DATA);
    assign s_rlast   = (rs_state == RS_DATA) && (r_beat_cnt == 8'h00);
    assign s_rid     = r_id;
    assign s_rresp   = r_inject ? 2'b10 : 2'b00;  // SLVERR or OKAY

    always_comb begin
        s_rdata = '0;
        for (int i = 0; i < BPB; i++)
            s_rdata[i*8 +: 8] = mem[(int'(r_cur_addr[15:0]) + i) % MEM_BYTES];
    end

    // =========================================================================
    // Write FSM
    // =========================================================================
    typedef enum logic [1:0] {
        WS_IDLE = 2'd0,
        WS_DATA = 2'd1,
        WS_RESP = 2'd2
    } ws_t;
    ws_t ws_state;

    logic [ADDR_WIDTH-1:0] w_cur_addr;
    logic [7:0]            w_beat_cnt;
    logic [ID_WIDTH-1:0]   w_id;
    logic                  w_inject;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ws_state   <= WS_IDLE;
            w_cur_addr <= '0;
            w_beat_cnt <= '0;
            w_id       <= '0;
            w_inject   <= 1'b0;
        end else begin
            case (ws_state)
                WS_IDLE: begin
                    if (s_awvalid && s_awready) begin
                        w_cur_addr <= s_awaddr;
                        w_beat_cnt <= s_awlen;
                        w_id       <= s_awid;
                        w_inject   <= inject_bresp_err;
                        ws_state   <= WS_DATA;
                    end
                end
                WS_DATA: begin
                    if (s_wvalid && s_wready) begin
                        for (int i = 0; i < BPB; i++) begin
                            if (s_wstrb[i])
                                mem[(int'(w_cur_addr[15:0]) + i) % MEM_BYTES] <= s_wdata[i*8 +: 8];
                        end
                        if (s_wlast || w_beat_cnt == 8'h00)
                            ws_state <= WS_RESP;
                        else begin
                            w_cur_addr <= w_cur_addr + ADDR_WIDTH'(BPB);
                            w_beat_cnt <= w_beat_cnt - 8'h01;
                        end
                    end
                end
                WS_RESP: begin
                    if (s_bvalid && s_bready)
                        ws_state <= WS_IDLE;
                end
                default: ws_state <= WS_IDLE;
            endcase
        end
    end

    assign s_awready = (ws_state == WS_IDLE);
    assign s_wready  = (ws_state == WS_DATA);
    assign s_bvalid  = (ws_state == WS_RESP);
    assign s_bid     = w_id;
    assign s_bresp   = w_inject ? 2'b10 : 2'b00;

endmodule
