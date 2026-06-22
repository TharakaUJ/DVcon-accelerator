# Convolutional Engine (`conv_engine.sv`)

## What it does

Computes a single 3×3 convolution — takes a 3×3 window of pixels and a 3×3 kernel of weights, multiplies each pair, and sums all 9 results into one output value. This is the fundamental operation inside every convolutional neural network layer.

---

## Architecture

9 MAC (multiply-accumulate) units chained in series. Each unit does one multiply-and-add, then passes its partial result to the next unit.

```
act[0]×w[0] ──► PE0 ──► PE1 ──► PE2 ──► PE3 ──► PE4 ──► PE5 ──► PE6 ──► PE7 ──► PE8 ──► result_out
                        ▲        ▲        ▲        ▲        ▲        ▲        ▲        ▲
               act[1]×w[1]  act[2]×w[2]  ...                                   act[8]×w[8]
```

Each PE fires one cycle after the previous one — so PE0 fires on cycle 0, PE1 on cycle 1, and PE8 on cycle 8. The final answer comes out 9 clock cycles after the start signal.

---

## Signal diagram

```
         ┌─────────────────────────────────┐
en  ────►│                                 │
         │                                 ├──► result_out [31:0]
act_in   │        conv_engine              │
[0:8] ──►│                                 ├──► result_valid
         │                                 │
weight_in│                                 │
[0:8] ──►│                                 │
         └─────────────────────────────────┘
clk ────►
rst_n ──►
```

---

## Ports

| Port | Direction | Width | Description |
|---|---|---|---|
| `clk` | input | 1 | 50 MHz clock |
| `rst_n` | input | 1 | Active-low reset |
| `en` | input | 1 | Start pulse — assert for 1 cycle |
| `act_in[0:8]` | input | 8-bit signed × 9 | 3×3 pixel window, row-major |
| `weight_in[0:8]` | input | 8-bit signed × 9 | 3×3 kernel weights, row-major |
| `result_out` | output | 32-bit signed | Dot product result |
| `result_valid` | output | 1 | Pulses high for 1 cycle when result is ready |

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `ACCUM_WIDTH` | 32 | Accumulator bit width. 32-bit handles max INT8 overflow: 9 × 127 × 127 = 145,161 |

---

## Timing

```
Cycle:      0    1    2    3    4    5    6    7    8    9
            │    │    │    │    │    │    │    │    │    │
en:       ──┤▔▔▔├────────────────────────────────────────
            │    │    │    │    │    │    │    │    │    │
PE0 fires:  │▔▔▔│    │    │    │    │    │    │    │    │
PE1 fires:  │    │▔▔▔│    │    │    │    │    │    │    │
...         │    │    │ ...│    │    │    │    │    │    │
PE8 fires:  │    │    │    │    │    │    │    │    │▔▔▔│
            │    │    │    │    │    │    │    │    │    │
result_valid:                                           │▔▔▔│
```

**Latency: 9 clock cycles** from `en` rising edge to `result_valid`.

---

## Input layout (row-major)

```
act_in / weight_in index mapping for a 3×3 window:

  [0] [1] [2]
  [3] [4] [5]
  [6] [7] [8]
```

Index 4 is the centre pixel/weight.

---

## How to use it

1. Load `act_in` and `weight_in` with your 3×3 window and kernel.
2. Assert `en` for exactly **1 clock cycle**.
3. Hold `act_in` and `weight_in` **stable** for the full 9-cycle pipeline duration.
4. Wait for `result_valid` to pulse — read `result_out` on that cycle.

---

## Dependencies

| Module | File | Role |
|---|---|---|
| `systolic_pe` | `rtl/pe.sv` | Leaf MAC unit — one per pipeline stage |

---

## Verified test cases

| Test | Input | Kernel | Expected | Result |
|---|---|---|---|---|
| All ones | 9× `1` | 9× `1` | 9 | PASS |
| Identity kernel | `[1..9]` | centre=1, rest=0 | 5 | PASS |
| Hand-computed | `[2,4,6..18]` | `[1,2,3..9]` | 570 | PASS |
| Negative activations | `[-1..-9]` | 9× `1` | -45 | PASS |
| Max INT8 | 9× `127` | 9× `127` | 145,161 | PASS |

Simulation waveform: `build/conv_engine_wave.vcd` — open with GTKWave.

---

## Resource estimate (Kintex-7 target)

Each `systolic_pe` uses 1 DSP48E1 slice for the INT8 multiply. 9 PEs = **9 DSP slices**.  
Total DSP budget: ~180 available after platform base system (90% free = ~162 free).  
This module consumes ~5.5% of the available DSP budget.

---

## Simulation

```bash
make sim TB=conv     # compile + run testbench
make wave TB=conv    # open waveform in GTKWave
```
