# Zero-Shot Detection Accelerator (SystemVerilog)

INT8 convolution accelerator for prompt-conditioned object detection
(YOLO26n + model2vec), targeting **Genesys 2 / Kintex-7 XC7K325T-2** alongside a
**C-DAC VEGA** RISC-V soft core. Architecture: [docs/architecture.md](docs/architecture.md).

The accelerator is an AXI4 peripheral: **AXI4-Lite slave** (VEGA control/status),
**AXI4 master** (DDR3 weights/feature-maps/detections), single IRQ. VEGA kicks once, the
accelerator self-walks a DDR descriptor list and writes all detections to DDR; the CPU
scores them (Option B).

## RTL files (`rtl/`)

| File | Role | Status |
|---|---|---|
| `accel_pkg.sv` | params, types, layer descriptor | — |
| `mac_tile.sv` | 16×32 INT8 MAC tile (512 MAC → 256 DSP packed) | unit-tested |
| `vector_unit.sv` | bias + requant + activation (NONE/RELU/SiLU) | unit-tested |
| `silu_lut.sv` | INT8 SiLU ROM, self-computed at elaboration (no hex file) | unit-tested |
| `axi_lite_slave.sv` | control/status register file | reviewed |
| `axi_read_master.sv` | AXI4 burst read engine | reviewed |
| `axi_write_master.sv` | AXI4 burst write engine | reviewed |
| `uart_tx.sv` / `uart_rx.sv` | 8N1 UART transmitter / receiver | reviewed |
| `uart_diag.sv` | standalone UART status/heartbeat port | reviewed |
| `conv_controller.sv` | descriptor-chained GEMM FSM | **reference — needs co-sim** |
| `accel_top.sv` | top-level integration (package as IP) | reviewed |

**Result handling = Option B.** The accelerator runs the whole network (backbone + neck +
head) and writes **all detections to DDR** (the head layer's `out_addr`). The CPU reads that
tensor and does scoring/argmax — `score = conf / (rank+1)` — in software, **in parallel** with
model2vec. No hardware box-picker, no rank-weight registers, no result registers. This
decouples the two engines: model2vec never has to finish before inference.

The accelerator's **UART port** (`uart_tx_o`/`uart_rx_i`) is independent of the AXI data path
and only reports status/heartbeat (alive, busy/done/err, inference count) for bring-up. The
image and all real data move over AXI ↔ DDR, never UART.

## Verification status (read this)

- **Datapath (`mac_tile`, `vector_unit`, `silu_lut`)**: self-checking testbench
  `sim/tb_datapath.sv` (dot product, accumulate, requant/clamp). Run it first.
- **AXI masters / AXI-Lite slave / UART**: standard handshake logic,
  reviewed by inspection — verify with an AXI VIP or the BD before trusting.
- **`conv_controller`**: structurally complete weight-stationary GEMM FSM, but the
  MAC-accumulate pipeline alignment and the per-phase counters are **not yet
  cycle-verified**. It must be RTL-simulated against golden GEMM vectors (and
  debugged) before hardware bring-up. This is the next milestone.
- No simulator/Vivado was available in the authoring environment — nothing here
  has been compiled yet. Expect to fix elaboration nits on first `xvlog`.

## Build (Vivado)

```sh
cd 0Accelaraator
vivado -mode batch -source scripts/create_project.tcl     # create project
# in the GUI or batch:
#   launch_simulation                                       # datapath TB
#   launch_runs synth_1 -jobs 4                             # synth/resource check
vivado -mode batch -source scripts/create_project.tcl -source scripts/package_ip.tcl
```

`package_ip.tcl` emits an AXI IP into `ip_repo/`. Add it to a block design with the
VEGA core + MIG (DDR3); connect `S_AXIL` to VEGA, `M_AXI` to the MIG, `irq` to VEGA's
interrupt controller, and route `uart_tx_o`/`uart_rx_i` to the board's USB-UART pins.
Target clock 150 MHz (`constraints/accel_timing.xdc`).

## Quick sims (no Vivado)

```sh
cd sim
# matrix-multiply check (C = A*W^T through mac_tile, vs golden)
iverilog -g2012 -o tb ../rtl/accel_pkg.sv ../rtl/mac_tile.sv tb_matmul.sv && vvp tb
# datapath check (dot / accumulate / requant / SiLU)
iverilog -g2012 -o tb ../rtl/accel_pkg.sv ../rtl/mac_tile.sv ../rtl/silu_lut.sv ../rtl/vector_unit.sv tb_datapath.sv && vvp tb
```

The SiLU ROM is computed inside `silu_lut.sv` at elaboration — no hex file, nothing to copy.
Change its `SCALE` parameter (propagated from `vector_unit`'s `SILU_SCALE`) to match a layer's
real activation scale.

## Not yet implemented (next steps)

1. Co-sim + debug `conv_controller` against golden GEMM/conv vectors.
2. Upsample/concat addressing in the controller for the neck (strided DMA).
3. Per-channel requant scales (currently per-tensor `requant_mult/shift`).
4. K-splitting for layers with K > `MAX_K` (host-side DDR partial-sum accumulation).
5. VEGA bare-metal: model2vec ranking, descriptor builder, DDR detection scoring, driver.
