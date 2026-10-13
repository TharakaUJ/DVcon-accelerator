# Opcode generator (GEMM microcode)

Generates instruction streams for the accelerator's control unit
(`rtl/control_unit.sv`) and checks them against a cycle-free Python model of
its scoreboard rules. Restored from commit `954ce2f` (branch `end-end`).

| File | Role |
|---|---|
| `isa.py` | 32-bit instruction encoding, opcodes and `accum_ctrl`, identical to `control_unit.sv`'s `instruction_t` |
| `sim.py` | software model of the accelerator (buffers, scoreboard, systolic array, vector unit) and the single-tile GEMM program builder |
| `tiling.py` | tiled GEMM scheduler for M/K/N larger than the array; its docstring lists the RTL constraints it works around |
| `gemm_compiler.py` | `generate_gemm(GemmParams(...))` writes `.hex` + `.asm` per run and a CSR manifest |

## Usage

Run from the repository root (modules import as `scripts.opcode_generator.*`):

```python
from scripts.opcode_generator.gemm_compiler import GemmParams, generate_gemm

prog = generate_gemm(GemmParams(M=20, N=12, K=20, array_size=8,
                                a_base_address=0x1000, b_base_address=0x2000,
                                c_base_address=0x3000))
prog.to_files("build/gemm")   # gemm_run<N>.hex / .asm, gemm.manifest.txt
```

## Tests

```bash
pytest scripts/opcode_generator/tests     # or: python3 -m scripts.opcode_generator.tests.test_tiled_gemm
```

- `test_gemm_microcode.py`, `test_tiled_gemm.py`, `test_gemm_compiler.py`:
  numpy `A @ B` (+ bias) equals the generated program executed on `sim.py`,
  with fixed and randomized shapes.
- `test_rtl_consistency.py`: `isa.py`'s opcodes/`accum_ctrl` match
  `control_unit.sv`, and the generated 2-row GEMM is bit-identical to the
  demo program in `instructions_fifo.sv`'s ROM.

All of this checks the generator against the Python model and the RTL's
encoding, not against RTL simulation.

## Gaps between generated programs and the current RTL

These need RTL decisions before generated programs can run on hardware:

1. **No way to load a program.** `instruction_fifo_window` is a hardcoded
   16-word ROM with no write port. `954ce2f` proposed a CPU-writable
   instruction memory (`documentation/RTL_INSTRUCTION_MEMORY_PROPOSAL.md`:
   AXI-lite registers at 0x20-0x28, write port gated by `!busy`); that RTL
   change was not restored here.
2. **16 instructions is far too few.** A 20x12x20 GEMM on an 8x8 array is
   2 runs of 266 instructions each.
3. **Tile addresses come from CSRs, not instructions.** Every LOAD uses
   `addr=0`; the host must rewrite `weight_addr`/`src_addr` before almost
   every LOAD (see the manifest), which a CPU cannot do mid-run. Each LOAD
   needs its own base/offset (wider `addr` field or an address table).
4. **No strided DMA** (`tiling.py` constraint #4): sub-tiles of a larger
   row-major matrix must be pre-packed contiguously in DRAM.
5. **One open accumulation, one weight tile, one bias load per run**
   (constraints #1-#3): forces row-by-row K reductions, reloading weight
   tiles for every row when K > array size, and one run per column tile.
6. **Array size.** `sim.py` requires one DMA beat == one array row
   (`DMA_WIDTH / DATA_WIDTH == ARRAY_SIZE`, i.e. the 8x8 config). The
   RTL's top-level default is `SYSTOLIC_ARRAY_ROWS = 32`, where a row is
   4 beats; that configuration is not modelled.
