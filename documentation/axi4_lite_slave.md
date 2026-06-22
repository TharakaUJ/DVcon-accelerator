# AXI4-Lite Slave (`axi4_lite_slave.sv`)

## What it does

Configuration register file for the convolution accelerator. A CPU (or AXI master) writes register values over AXI4-Lite to configure source/destination addresses, image dimensions, and weight location, then asserts START. The module exposes those values as combinatorial outputs to the accelerator datapath and reflects hardware status (busy/done/error/FSM state) back through the STATUS register.

---

## Architecture

```
        AXI4-Lite Master
              │
    ┌─────────┴──────────┐
    │   Write Path FSM   │   Write Address (AW) + Write Data (W) channels
    │   W_IDLE → W_BUSY  │   accepted independently, committed together
    │        → W_RESP    │
    └─────────┬──────────┘
              │ register write
    ┌─────────┴──────────┐
    │    Register File   │   6 × 32-bit registers
    │  CTRL / STATUS     │
    │  SRC / DST / DIM   │
    │  WEIGHT_ADDR       │
    └─────────┬──────────┘
              │ combinatorial outputs / status inputs
    ┌─────────┴──────────┐
    │  Accelerator Core  │   start_pulse, src_addr, dst_addr,
    │  (conv_engine /    │   img_rows, img_cols, weight_addr
    │   systolic_array)  │   ← busy, done, error, fsm_state
    └────────────────────┘
```

---

## Parameters

| Parameter    | Default | Description                     |
|-------------|---------|----------------------------------|
| `ADDR_WIDTH` | 64      | AXI address bus width (bits)    |
| `DATA_WIDTH` | 32      | AXI data bus width (bits)       |

---

## Register Map

Base address `0x2000_6000_0000_0000` decoded externally; this module receives offsets only.

| Offset | Name          | Access | Reset Value  | Description                          |
|--------|---------------|--------|--------------|--------------------------------------|
| `0x00` | `CTRL`        | R/W    | `0x0000_0000`| `[0]` START (self-clears), `[1]` SOFT_RESET, `[2]` INT_EN, `[3]` MODE |
| `0x04` | `STATUS`      | RO     | HW-driven    | `[0]` BUSY, `[1]` DONE, `[2]` ERROR, `[7:4]` FSM_STATE |
| `0x08` | `SRC_ADDR`    | R/W    | `0x8000_0000`| Source buffer base address           |
| `0x0C` | `DST_ADDR`    | R/W    | `0x8100_0000`| Destination buffer base address      |
| `0x10` | `IMG_DIM`     | R/W    | `0x0020_0020`| `[31:16]` img_rows, `[15:0]` img_cols |
| `0x14` | `WEIGHT_ADDR` | R/W    | `0x8080_0000`| Weight buffer base address           |

Writes to `STATUS` are silently ignored. Reads from unmapped addresses return `0xDEAD_BEEF` (visible in waveform for debug).

---

## Port List

### Clock / Reset

| Port    | Dir | Width | Description                     |
|---------|-----|-------|---------------------------------|
| `clk`   | in  | 1     | System clock                    |
| `rst_n` | in  | 1     | Active-low synchronous reset    |

### AXI4-Lite Write Address Channel (AW)

| Port        | Dir | Width | Description                  |
|------------|-----|-------|------------------------------|
| `s_awvalid` | in  | 1     | Master address valid         |
| `s_awready` | out | 1     | Slave address ready          |
| `s_awaddr`  | in  | 64    | Write address                |

### AXI4-Lite Write Data Channel (W)

| Port       | Dir | Width | Description                  |
|-----------|-----|-------|------------------------------|
| `s_wvalid` | in  | 1     | Master data valid            |
| `s_wready` | out | 1     | Slave data ready             |
| `s_wdata`  | in  | 32    | Write data                   |
| `s_wstrb`  | in  | 4     | Byte strobes (one per byte)  |

### AXI4-Lite Write Response Channel (B)

| Port       | Dir | Width | Description                  |
|-----------|-----|-------|------------------------------|
| `s_bvalid` | out | 1     | Slave response valid         |
| `s_bready` | in  | 1     | Master response ready        |
| `s_bresp`  | out | 2     | Response code (always OKAY=0b00) |

### AXI4-Lite Read Address Channel (AR)

| Port        | Dir | Width | Description                  |
|------------|-----|-------|------------------------------|
| `s_arvalid` | in  | 1     | Master address valid         |
| `s_arready` | out | 1     | Slave address ready          |
| `s_araddr`  | in  | 64    | Read address                 |

### AXI4-Lite Read Data Channel (R)

| Port       | Dir | Width | Description                  |
|-----------|-----|-------|------------------------------|
| `s_rvalid` | out | 1     | Slave data valid             |
| `s_rready` | in  | 1     | Master data ready            |
| `s_rdata`  | out | 32    | Read data                    |
| `s_rresp`  | out | 2     | Response code (always OKAY=0b00) |

### Accelerator Control Outputs

| Port          | Dir | Width | Description                                    |
|--------------|-----|-------|------------------------------------------------|
| `start_pulse` | out | 1     | 1-cycle pulse when CTRL[0] is written '1'     |
| `soft_reset`  | out | 1     | Level signal, mirrors CTRL[1]                 |
| `src_addr`    | out | 32    | Source DMA address                            |
| `dst_addr`    | out | 32    | Destination DMA address                       |
| `img_rows`    | out | 16    | Image height in pixels                        |
| `img_cols`    | out | 16    | Image width in pixels                         |
| `weight_addr` | out | 32    | Weight buffer address                         |

### Accelerator Status Inputs

| Port        | Dir | Width | Description                        |
|------------|-----|-------|------------------------------------|
| `busy`      | in  | 1     | Accelerator currently processing   |
| `done`      | in  | 1     | Last operation complete            |
| `error`     | in  | 1     | Error flag from datapath           |
| `fsm_state` | in  | 4     | Accelerator FSM state (debug)      |

---

## Write Path FSM

```
         ┌──────────────────────────────────────────────┐
         │ AW handshake → latch wr_addr_lat             │
         │ W  handshake → latch wr_data_lat, wr_strb_lat│
W_IDLE ──┤                                              ├──► W_BUSY (both latched)
         │ AWREADY = 1 while !aw_latched               │
         │ WREADY  = 1 while !w_latched                │
         └──────────────────────────────────────────────┘
              │
         W_BUSY  (1 cycle — commit register write with byte strobes applied)
              │
         W_RESP  ──── BVALID=1 until BREADY handshake ──► W_IDLE
```

AW and W channels may arrive in any order; each is latched independently. The register is written on the W_BUSY cycle.

---

## Read Path FSM

```
R_IDLE ── ARVALID & ARREADY → latch rd_addr_lat ──► R_DATA
R_DATA ── RVALID=1, present mux output ── RREADY handshake ──► R_IDLE
```

One cycle of read latency (address latched on AR handshake, data presented in R_DATA state).

---

## START Self-Clear Behaviour

`CTRL[0]` (START) self-clears the cycle after it is written:

```
cycle N:   CPU writes CTRL = 0x1 → W_BUSY commits, CTRL[0]=1
cycle N+1: start_pulse asserts (combinatorial from reg_ctrl[0])
           self-clear logic: reg_ctrl[0] <= 0
cycle N+2: start_pulse deasserts
```

The testbench latches `start_pulse` into `start_seen` to verify the single-cycle pulse without a race.

---

## Byte Strobe Behaviour

`apply_strobe()` applies byte-enable masks:

```systemverilog
result[i*8 +: 8] = strb[i] ? wdata[i*8 +: 8] : current[i*8 +: 8];
```

Writing `s_wstrb = 4'b1000` with `s_wdata = 32'hFF00_0000` to a register holding `0xAABB_CCDD` yields `0xFFBB_CCDD` — only byte 3 is updated.

---

## CPU Write Sequence (typical)

```
1. Write SRC_ADDR    ← source buffer pointer
2. Write DST_ADDR    ← destination buffer pointer
3. Write WEIGHT_ADDR ← weight buffer pointer
4. Write IMG_DIM     ← {rows[31:16], cols[15:0]}
5. Write CTRL = 0x1  ← assert START (self-clears next cycle)
6. Poll STATUS[0]    ← wait until BUSY deasserts
7. Check STATUS[1]   ← verify DONE
8. Check STATUS[2]   ← check ERROR flag
```

---

## Simulation

```bash
make sim TB=axilite        # compile + simulate, generates build/axi4_lite_slave_wave.vcd
make wave TB=axilite       # open GTKWave with saved signal layout
```

Test groups covered by `tb/tb_axi4_lite_slave.sv`:

| Group | Description                              | Checks |
|-------|------------------------------------------|--------|
| 1     | Reset / default register values          | 5      |
| 2     | CPU config write sequence + output ports | 9      |
| 3     | START self-clear                         | 3      |
| 4     | STATUS hardware-driven, writes ignored   | 4      |
| 5     | DONE flag in STATUS                      | 1      |
| 6     | Byte strobe partial word write           | 1      |

All 23 checks pass (`0 FAILED`).

---

## Waveform Reference (`build/axilite.gtkw`)

Signal groups in the saved GTKWave layout:

| Group              | Signals                                              |
|-------------------|------------------------------------------------------|
| Clock/Reset        | `clk`, `rst_n`                                      |
| Write Address (AW) | `s_awvalid`, `s_awready`, `s_awaddr[63:0]`          |
| Write Data (W)     | `s_wvalid`, `s_wready`, `s_wdata[31:0]`, `s_wstrb[3:0]` |
| Write Response (B) | `s_bvalid`, `s_bready`, `s_bresp[1:0]`             |
| Read Address (AR)  | `s_arvalid`, `s_arready`, `s_araddr[63:0]`          |
| Read Data (R)      | `s_rvalid`, `s_rready`, `s_rdata[31:0]`, `s_rresp[1:0]` |
| Control Outputs    | `start_pulse`, `soft_reset`, `src_addr`, `dst_addr`, `img_rows`, `img_cols`, `weight_addr` |
| Status Inputs      | `busy`, `done`, `error`, `fsm_state[3:0]`           |
| Write FSM          | `dut.wstate[1:0]`                                   |
| Read FSM           | `dut.rstate`                                        |
