# DV Testbench Regression

Self-checking testbenches for the BRAM/DSP/im2col accelerator (CR-001) and the
legacy plain-GEMM path. Two runners are provided — pick by your shell:

| Runner | Use when | Command |
|--------|----------|---------|
| `run_xsim.ps1` | Windows PowerShell (xsim tools are `.bat` wrappers) | `./run_xsim.ps1` |
| `Makefile` | A shell whose `make` resolves `xvlog`/`xelab`/`xsim` (Vivado cmd prompt) | `make` |

Both compile every `../rtl/*.sv` + `tb_*.sv` once, then elaborate + run each
testbench and write a pass/fail summary.

---

## 1. Prerequisites

- Vivado (xsim) on PATH. On this machine it lives at `D:\AMD\2025.2\Vivado\bin`.
- Run from this directory: `Accl2.srcs/sources_1/imports/DV/tb`.

Add Vivado to PATH for the session:

```powershell
# PowerShell
$env:PATH = 'D:\AMD\2025.2\Vivado\bin;' + $env:PATH
```
```bat
:: cmd
call D:\AMD\2025.2\Vivado\settings64.bat
```

Verify: `xvlog -version` prints a version string.

---

## 2. Run — PowerShell (recommended on Windows)

```powershell
$env:PATH = 'D:\AMD\2025.2\Vivado\bin;' + $env:PATH
./run_xsim.ps1                       # compile + run ALL testbenches
./run_xsim.ps1 -Only tb_im2col_engine # one testbench
```

## 3. Run — Makefile

Use a shell where `xvlog`/`xelab`/`xsim` resolve (a Vivado command prompt, or
GNU make invoking `cmd`). From this directory:

```
make            # compile all, run every tb, print + log the summary
make tb_pe_pair # run a single testbench
make summary    # re-print the summary from existing logs
make clean       # remove results/ + xsim work products
```

---

## 4. Where the outputs go

Everything lands under `results/`, one folder per testbench:

```
results/
├── regression_summary.log      # PASS/FAIL roll-up for all testbenches
├── xvlog.log                   # shared compile log
└── <tb>/                       # e.g. tb_im2col_engine/
    ├── xelab.log               # elaboration log
    ├── xelab.console           # elaboration stdout/stderr
    ├── <tb>.log                # simulation log (the PASS/FAIL lines)
    ├── <tb>.console            # simulation stdout/stderr
    ├── <tb>.vcd                # VCD waveform ($dumpfile)
    └── <tb>.wdb                # xsim native waveform database
```

Open a waveform in the xsim GUI:

```powershell
xsim --gui results/tb_im2col_engine/tb_im2col_engine.wdb
```
or load the `.vcd` in any VCD viewer (GTKWave, etc.).

A test **PASSES** when its `<tb>.log` prints a `... PASSED` / per-line `PASS`
verdict and the run hit `$finish` (no `WATCHDOG`/`TIMEOUT`). The summary flags
anything with a verdict-level failure marker (`TESTS FAILED`, `RESULT: FAILED`,
`FAILED (`, `ERROR:`, `  FAIL`, `WATCHDOG`).

---

## 5. Testbench coverage

| Testbench | DUT / CR | What it checks |
|-----------|----------|----------------|
| `tb_pe` | systolic_pe | INT8 MAC, saturation, round, hold |
| `tb_pe_pair` | pe_pair (CR-4) | DSP-packed dual MAC == behavioural ref (random + corners) |
| `tb_systolic_array` | systolic_array | skewed GEMM end-to-end |
| `tb_systolic_array_shadow` | systolic_array (CR-2) | shadow-load → swap, 2 tiles, GEMM vs golden |
| `tb_buffer_reg` / `tb_shift_reg_buffer` / `tb_register_bank` / `tb_generic_mux` | leaf blocks | original unit checks |
| `tb_bram_act_buffer` | CR-1 | banked ping-pong activation BRAM |
| `tb_bram_weight_buffer` | CR-2 | row-write / tile-read, 2 slots |
| `tb_bram_out_buffer` | CR-5 | vector write/read, ping-pong |
| `tb_line_buffer` | CR-3 | vertical KH-slice read |
| `tb_im2col_engine` | CR-3 | 3×3/s1/p1 lowering vs software im2col golden (bit-exact) |
| `tb_vector_unit` | CR-5 | requant + NONE/RELU bit-exact, SILU range |
| `tb_silu` | silu_lut | SiLU ROM |
| `tb_control_unit` | control_unit | FSM strobe counts + address sequencing |
| `tb_axi4_lite_slave` | axi4_lite_slave | AXI register file |
| `tb_accelerator` | accelerator (legacy) | plain-GEMM bypass, identity·2 |
| `tb_system_top` | system_top (legacy) | full auto-sequence, 32×32 |
| `tb_system_top_bram` | system_top `USE_BRAM_PATH=1` | new 16×16 BRAM/DSP path, identity·2 |

---

## 6. Notes

- The shared compile puts all tbs in one xsim work library; every `tb_*` module
  name is unique, so there are no collisions.
- New build is `system_top #(.ARRAY_SIZE(16), .USE_BRAM_PATH(1))`; defaults keep
  the legacy 32×32 path so the original testbenches still pass.
- Single-tb iteration is fastest with `./run_xsim.ps1 -Only <tb>` (skips the rest
  but still does the shared compile).
- Each `tb_*.sv` header comment also lists its minimal standalone compile file
  list if you want to build just one outside these runners.
