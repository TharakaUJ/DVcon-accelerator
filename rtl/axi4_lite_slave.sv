// axi4_lite_slave.sv
// AXI4-Lite slave — configuration register file for the convolution accelerator.
// 32-bit data bus, 64-bit address bus, registers at offsets 0x00–0x28.
// Base address (0x2000600000000000) is decoded externally; this module sees offsets only.

`timescale 1ns/1ps

module axi4_lite_slave #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 64,
    parameter int INSTR_DEPTH = 1024 // must match instruction_fifo_window's INSTR_DEPTH
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
    output logic [ADDR_WIDTH-1:0]   src_addr,
    output logic [ADDR_WIDTH-1:0]   dst_addr,
    output logic [15:0]             img_rows,
    output logic [15:0]             img_cols,
    output logic [ADDR_WIDTH-1:0]   weight_addr,
    output logic [ADDR_WIDTH-1:0]   bias_addr,       // NEW — was previously not backed by any register;
                                                       // accelerator.sv hardwired it to weight_addr+offset.
    output logic [15:0]             vec_requant_mult, // NEW — was dangling in accelerator.sv/vector_unit
    output logic [4:0]              vec_requant_shift,// NEW — was dangling in accelerator.sv/vector_unit
    output logic [1:0]              vec_act_type,     // NEW — was dangling in accelerator.sv/vector_unit

    // NEW — CPU instruction-memory programming interface (see
    // RTL_INSTRUCTION_MEMORY_PROPOSAL.md). Indirect-write-through-two-
    // registers pattern: host writes REG_INSTR_ADDR, then writes
    // REG_INSTR_DATA, which pulses instr_wr_en for one cycle with
    // instr_wr_addr/instr_wr_data held from the latched registers.
    // instr_wr_en itself is NOT gated with !busy here — that gate lives in
    // accelerator.sv, ANDed onto this signal right before it reaches
    // instruction_fifo_window's wr_en port. See proposal doc section 6 for
    // why the gate is placed there instead of in this module.
    output logic                    instr_wr_en,
    output logic [$clog2(INSTR_DEPTH)-1:0] instr_wr_addr,
    output logic [31:0]             instr_wr_data,
    output logic [31:0]             prog_len,        // instruction_fifo_window returns OP_END at/after this

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
    localparam logic [7:0] REG_BIAS_ADDR   = 8'h18;   // NEW
    localparam logic [7:0] REG_VEC_CTRL    = 8'h1C;   // NEW — [15:0]=requant_mult [20:16]=requant_shift [22:21]=act_type
    localparam logic [7:0] REG_INSTR_ADDR  = 8'h20;   // NEW — target rom[] index for the next REG_INSTR_DATA write
    localparam logic [7:0] REG_INSTR_DATA  = 8'h24;   // NEW — write-triggers a one-cycle instr_wr_en pulse at REG_INSTR_ADDR
    localparam logic [7:0] REG_PROG_LEN    = 8'h28;   // NEW — host-declared valid instruction count; fetches at/after it read as OP_END

    // =========================================================================
    // Register file
    // =========================================================================
    logic [31:0] reg_ctrl;        // [0]=START [1]=RESET [2]=INT_EN [3]=MODE
    logic [31:0] reg_src_addr;
    logic [31:0] reg_dst_addr;
    logic [31:0] reg_img_dim;
    logic [31:0] reg_weight_addr;
    logic [31:0] reg_bias_addr;    // NEW
    logic [31:0] reg_vec_ctrl;     // NEW
    logic [31:0] reg_instr_addr;   // NEW — latched target address for the next instruction-memory write
    logic [31:0] reg_prog_len;     // NEW
    logic [31:0] reg_instr_data_shadow; // NEW — shadow copy of the last REG_INSTR_DATA write, for debug readback only

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
            reg_src_addr    <= 32'h00020000;
            reg_dst_addr    <= 32'h00024000;
            reg_img_dim     <= 32'h0020_0020;
            reg_weight_addr <= 32'h00020000;
            reg_bias_addr   <= 32'h00028000;  // NEW — independent default; no longer weight_addr+offset
            // NEW — default to an identity requant (mult=1, shift=0,
            // act_type=0/passthrough) rather than all-zero. FLAG: "0" for
            // act_type is assumed passthrough here because vector_unit.sv
            // was not provided — confirm this encoding once it's available.
            reg_vec_ctrl    <= {9'd0, 2'd0, 5'd0, 16'd1};
            reg_instr_addr  <= 32'h0000_0000;  // NEW
            reg_prog_len    <= 32'h0000_0000;  // NEW
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
                    REG_BIAS_ADDR:   reg_bias_addr   <= apply_strobe(reg_bias_addr,   wr_data_lat, wr_strb_lat); // NEW
                    REG_VEC_CTRL:    reg_vec_ctrl    <= apply_strobe(reg_vec_ctrl,    wr_data_lat, wr_strb_lat); // NEW
                    REG_INSTR_ADDR:  reg_instr_addr  <= apply_strobe(reg_instr_addr,  wr_data_lat, wr_strb_lat); // NEW
                    // NEW — REG_INSTR_DATA is write-only/pulse-only: the value written here is
                    // never latched into a register (there's nothing to read back — see the read
                    // mux below, which returns the last-programmed word straight out of
                    // reg_instr_data_shadow for debug visibility only). The actual instr_wr_en
                    // pulse is generated combinatorially below, following the same one-cycle
                    // W_BUSY-aligned pattern used for start_pulse.
                    REG_INSTR_DATA:  reg_instr_data_shadow <= apply_strobe(reg_instr_data_shadow, wr_data_lat, wr_strb_lat); // NEW
                    REG_PROG_LEN:    reg_prog_len    <= apply_strobe(reg_prog_len,    wr_data_lat, wr_strb_lat); // NEW
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

    // NEW — instr_wr_en: one-cycle pulse in W_BUSY when the write landing this
    // cycle targets REG_INSTR_DATA, exactly mirroring how start_pulse is a
    // combinational decode of reg_ctrl[0] that is live for exactly one cycle
    // (W_BUSY is itself already a single-cycle state — see the write-path FSM
    // above — so gating on wstate==W_BUSY && address-match is sufficient to
    // get a clean one-cycle pulse without any extra self-clear logic).
    assign instr_wr_en   = (wstate == W_BUSY) && (wr_addr_lat[7:0] == REG_INSTR_DATA);
    assign instr_wr_addr = reg_instr_addr[$clog2(INSTR_DEPTH)-1:0];
    assign instr_wr_data = apply_strobe(32'h0000_0000, wr_data_lat, wr_strb_lat); // NEW — full word, no byte-merge needed (fresh instruction word each time)
    assign prog_len      = reg_prog_len;   // NEW

    // Output register values to accelerator datapath
    assign src_addr    = reg_src_addr;
    assign dst_addr    = reg_dst_addr;
    assign img_rows    = reg_img_dim[31:16];
    assign img_cols    = reg_img_dim[15:0];
    assign weight_addr = reg_weight_addr;
    assign bias_addr        = reg_bias_addr;          // NEW
    assign vec_requant_mult  = reg_vec_ctrl[15:0];     // NEW
    assign vec_requant_shift = reg_vec_ctrl[20:16];    // NEW
    assign vec_act_type      = reg_vec_ctrl[22:21];    // NEW

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
    wire [7:0] rd_addr_byte = rd_addr_lat[7:0];

    always_comb begin
        case (rd_addr_byte)
            REG_CTRL:        s_rdata = reg_ctrl;
            REG_STATUS:      s_rdata = reg_status;
            REG_SRC_ADDR:    s_rdata = reg_src_addr;
            REG_DST_ADDR:    s_rdata = reg_dst_addr;
            REG_IMG_DIM:     s_rdata = reg_img_dim;
            REG_WEIGHT_ADDR: s_rdata = reg_weight_addr;
            REG_BIAS_ADDR:   s_rdata = reg_bias_addr;   // NEW
            REG_VEC_CTRL:    s_rdata = reg_vec_ctrl;    // NEW
            REG_INSTR_ADDR:  s_rdata = reg_instr_addr;  // NEW
            REG_INSTR_DATA:  s_rdata = reg_instr_data_shadow; // NEW — debug readback only
            REG_PROG_LEN:    s_rdata = reg_prog_len;    // NEW
            default:         s_rdata = 32'hDEAD_BEEF; // unmapped — visible in waveform
        endcase
    end

endmodule
