// axi4_lite_slave.sv
// AXI4-Lite slave — configuration register file for the convolution accelerator.
// 32-bit data bus, 64-bit address bus, 6 registers at offsets 0x00–0x14.
// Base address (0x2000600000000000) is decoded externally; this module sees offsets only.

`timescale 1ns/1ps

module axi4_lite_slave #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 32
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // ── AXI4-Lite Write Address Channel ──────────────────────────────────────
    input  logic                    s_awvalid,
    output logic                    s_awready,
    input  logic [ADDR_WIDTH-1:0]   s_awaddr,

    // ── AXI4-Lite Write Data Channel ─────────────────────────────────────────
    input  logic                    s_wvalid,
    output logic                    s_wready,
    input  logic [DATA_WIDTH-1:0]   s_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_wstrb,

    // ── AXI4-Lite Write Response Channel ─────────────────────────────────────
    output logic                    s_bvalid,
    input  logic                    s_bready,
    output logic [1:0]              s_bresp,

    // ── AXI4-Lite Read Address Channel ───────────────────────────────────────
    input  logic                    s_arvalid,
    output logic                    s_arready,
    input  logic [ADDR_WIDTH-1:0]   s_araddr,

    // ── AXI4-Lite Read Data Channel ──────────────────────────────────────────
    output logic                    s_rvalid,
    input  logic                    s_rready,
    output logic [DATA_WIDTH-1:0]   s_rdata,
    output logic [1:0]              s_rresp,

    // ── Accelerator control outputs ───────────────────────────────────────────
    output logic                    start_pulse,
    output logic                    soft_reset,
    output logic [31:0]             src_addr,
    output logic [31:0]             dst_addr,
    output logic [15:0]             img_rows,
    output logic [15:0]             img_cols,
    output logic [31:0]             weight_addr,

    // ── Accelerator status inputs ─────────────────────────────────────────────
    input  logic                    busy,
    input  logic                    done,
    input  logic                    error,
    input  logic [3:0]              fsm_state
);

    // =========================================================================
    // Register offsets
    // =========================================================================
    localparam logic [7:0] REG_CTRL        = 8'h00;
    localparam logic [7:0] REG_STATUS      = 8'h04;
    localparam logic [7:0] REG_SRC_ADDR    = 8'h08;
    localparam logic [7:0] REG_DST_ADDR    = 8'h0C;
    localparam logic [7:0] REG_IMG_DIM     = 8'h10;
    localparam logic [7:0] REG_WEIGHT_ADDR = 8'h14;

    // =========================================================================
    // Register file
    // =========================================================================
    logic [31:0] reg_ctrl;        // [0]=START [1]=RESET [2]=INT_EN [3]=MODE
    logic [31:0] reg_src_addr;
    logic [31:0] reg_dst_addr;
    logic [31:0] reg_img_dim;
    logic [31:0] reg_weight_addr;

    // STATUS is hardware-driven; assembled combinatorially
    logic [31:0] reg_status;
    always_comb begin
        reg_status          = 32'h0;
        reg_status[0]       = busy;
        reg_status[1]       = done;
        reg_status[2]       = error;
        reg_status[7:4]     = fsm_state;
    end

    // =========================================================================
    // Write path FSM
    // =========================================================================
    typedef enum logic [1:0] {
        W_IDLE = 2'd0,
        W_BUSY = 2'd1,
        W_RESP = 2'd2
    } wstate_t;

    wstate_t wstate;

    logic [ADDR_WIDTH-1:0] wr_addr_lat;
    logic [DATA_WIDTH-1:0] wr_data_lat;
    logic [DATA_WIDTH/8-1:0] wr_strb_lat;

    // Latch write address and data independently; allow them to arrive in any order
    logic aw_latched, w_latched;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate       <= W_IDLE;
            aw_latched   <= 1'b0;
            w_latched    <= 1'b0;
            wr_addr_lat  <= '0;
            wr_data_lat  <= '0;
            wr_strb_lat  <= '0;
        end else begin
            case (wstate)
                W_IDLE: begin
                    // Accept address channel
                    if (s_awvalid && s_awready) begin
                        wr_addr_lat <= s_awaddr;
                        aw_latched  <= 1'b1;
                    end
                    // Accept data channel
                    if (s_wvalid && s_wready) begin
                        wr_data_lat <= s_wdata;
                        wr_strb_lat <= s_wstrb;
                        w_latched   <= 1'b1;
                    end
                    // Both arrived — move to write + respond
                    if ((aw_latched || (s_awvalid && s_awready)) &&
                        (w_latched  || (s_wvalid  && s_wready))) begin
                        wstate     <= W_BUSY;
                        aw_latched <= 1'b0;
                        w_latched  <= 1'b0;
                    end
                end

                W_BUSY: begin
                    wstate <= W_RESP;
                end

                W_RESP: begin
                    if (s_bvalid && s_bready)
                        wstate <= W_IDLE;
                end

                default: wstate <= W_IDLE;
            endcase
        end
    end

    // AWREADY / WREADY: accept while idle and not yet latched
    assign s_awready = (wstate == W_IDLE) && !aw_latched;
    assign s_wready  = (wstate == W_IDLE) && !w_latched;
    assign s_bvalid  = (wstate == W_RESP);
    assign s_bresp   = 2'b00; // OKAY

    // =========================================================================
    // Register write (executed in W_BUSY)
    // =========================================================================
    // Apply byte strobes helper
    function automatic logic [31:0] apply_strobe(
        input logic [31:0] current,
        input logic [31:0] wdata,
        input logic [3:0]  strb
    );
        logic [31:0] result;
        for (int i = 0; i < 4; i++)
            result[i*8 +: 8] = strb[i] ? wdata[i*8 +: 8] : current[i*8 +: 8];
        return result;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ctrl        <= 32'h0000_0000;
            reg_src_addr    <= 32'h8000_0000;
            reg_dst_addr    <= 32'h8100_0000;
            reg_img_dim     <= 32'h0020_0020;
            reg_weight_addr <= 32'h8080_0000;
        end else begin
            // Self-clear START bit one cycle after it is latched
            if (start_pulse)
                reg_ctrl[0] <= 1'b0;

            if (wstate == W_BUSY) begin
                case (wr_addr_lat[7:0])
                    REG_CTRL:        reg_ctrl        <= apply_strobe(reg_ctrl,        wr_data_lat, wr_strb_lat);
                    REG_SRC_ADDR:    reg_src_addr    <= apply_strobe(reg_src_addr,    wr_data_lat, wr_strb_lat);
                    REG_DST_ADDR:    reg_dst_addr    <= apply_strobe(reg_dst_addr,    wr_data_lat, wr_strb_lat);
                    REG_IMG_DIM:     reg_img_dim     <= apply_strobe(reg_img_dim,     wr_data_lat, wr_strb_lat);
                    REG_WEIGHT_ADDR: reg_weight_addr <= apply_strobe(reg_weight_addr, wr_data_lat, wr_strb_lat);
                    REG_STATUS:      ; // hardware-driven, writes ignored
                    default:         ; // unmapped address, ignore
                endcase
            end
        end
    end

    // START pulse: combinatorial decode so it appears the same cycle CTRL[0] is written
    // The self-clear above drops it next cycle
    assign start_pulse  = reg_ctrl[0];
    assign soft_reset   = reg_ctrl[1];

    // Output register values to accelerator datapath
    assign src_addr    = reg_src_addr;
    assign dst_addr    = reg_dst_addr;
    assign img_rows    = reg_img_dim[31:16];
    assign img_cols    = reg_img_dim[15:0];
    assign weight_addr = reg_weight_addr;

    // =========================================================================
    // Read path FSM
    // =========================================================================
    typedef enum logic {
        R_IDLE = 1'b0,
        R_DATA = 1'b1
    } rstate_t;

    rstate_t rstate;
    logic [ADDR_WIDTH-1:0] rd_addr_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate     <= R_IDLE;
            rd_addr_lat <= '0;
        end else begin
            case (rstate)
                R_IDLE: begin
                    if (s_arvalid && s_arready) begin
                        rd_addr_lat <= s_araddr;
                        rstate      <= R_DATA;
                    end
                end
                R_DATA: begin
                    if (s_rvalid && s_rready)
                        rstate <= R_IDLE;
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

    assign s_arready = (rstate == R_IDLE);
    assign s_rvalid  = (rstate == R_DATA);
    assign s_rresp   = 2'b00; // OKAY

    // Read data mux
    always_comb begin
        case (rd_addr_lat[7:0])
            REG_CTRL:        s_rdata = reg_ctrl;
            REG_STATUS:      s_rdata = reg_status;
            REG_SRC_ADDR:    s_rdata = reg_src_addr;
            REG_DST_ADDR:    s_rdata = reg_dst_addr;
            REG_IMG_DIM:     s_rdata = reg_img_dim;
            REG_WEIGHT_ADDR: s_rdata = reg_weight_addr;
            default:         s_rdata = 32'hDEAD_BEEF; // unmapped — visible in waveform
        endcase
    end

endmodule
