# CPU-Programmable Instruction Memory — Design Proposal

## 1. Proposed architecture

```
CPU (AXI4-Lite master)
   │  writes REG_INSTR_ADDR, REG_INSTR_DATA (repeated N times), REG_PROG_LEN, REG_CTRL[START]
   ▼
axi4_lite_slave.sv
   │  instr_wr_en / instr_wr_addr / instr_wr_data / prog_len  (new outputs)
   ▼
accelerator.sv
   │  instr_wr_en gated with !busy  →  wr_en/wr_addr/wr_data
   ▼
instruction_fifo_window (instructions_fifo.sv)  — internal `rom[0:INSTR_DEPTH-1]`
   │  pop_en / pop_idx / window[0:WINDOW_SIZE-1] / restart   (UNCHANGED interface)
   ▼
control_unit.sv  — scheduler/dispatcher (UNCHANGED)
   ▼
datapath (systolic_array, vector_unit, BRAM buffers, axi4_master DMA)
```

The CPU writes an arbitrary instruction stream into `rom[]` through a small
indirect register window in `axi4_lite_slave`, then starts the run exactly as
today (`REG_CTRL[START]`). `control_unit.sv` never learns that the program
source changed — it still only ever sees `fifo_pop_en/fifo_pop_idx/
fifo_window/fifo_restart`.

## 2. Required new interfaces/signals

`instruction_fifo_window` (instructions_fifo.sv) — new ports, added, not
replacing anything:
- `input  wr_en`
- `input  [$clog2(INSTR_DEPTH)-1:0] wr_addr`
- `input  [INSTR_WIDTH-1:0] wr_data`

`axi4_lite_slave` — new outputs:
- `instr_wr_en`
- `instr_wr_addr [$clog2(INSTR_DEPTH)-1:0]`
- `instr_wr_data [31:0]`
- `prog_len [31:0]`

`accelerator` — new internal wires: `instr_wr_en_raw`, `instr_wr_en` (gated),
`instr_wr_addr`, `instr_wr_data`, `prog_len`. No new top-level ports; these
are internal wiring between the two existing top-level AXI interfaces
(`s_axi_*` already carries the CPU's register writes).

## 3. CPU/AXI programming mechanism

New registers in `axi4_lite_slave.sv`, following the file's existing
`REG_*` / `apply_strobe` / `W_BUSY`-pulse conventions exactly:

| Offset | Name           | Semantics                                                                 |
|--------|----------------|----------------------------------------------------------------------------|
| 0x20   | REG_INSTR_ADDR | Plain register. Write sets the target `rom[]` index for the next data write. |
| 0x24   | REG_INSTR_DATA | Write-triggers a one-cycle `instr_wr_en` pulse, `instr_wr_addr = REG_INSTR_ADDR`, `instr_wr_data = <this write's data>`. Not itself a persistent register (shadow-latched only for debug readback). |
| 0x28   | REG_PROG_LEN   | Plain register. Host writes the number of valid instructions in the program it just loaded. Exposed as `prog_len` output — informational only (see §6). |

Programming sequence from the CPU:
```
for i in range(N):
    AXI_WRITE(REG_INSTR_ADDR, i)
    AXI_WRITE(REG_INSTR_DATA, program[i])   # pulses instr_wr_en, writes rom[i]
AXI_WRITE(REG_PROG_LEN, N)
AXI_WRITE(REG_CTRL, START_BIT)
```
`REG_INSTR_ADDR` does not auto-increment — the host must set it before every
`REG_INSTR_DATA` write. This mirrors the existing two-register indirect
pattern already implied by `REG_BIAS_ADDR`/`REG_WEIGHT_ADDR` style separation
in this file, and keeps the write-triggered-pulse logic identical in shape to
how `start_pulse` is already derived combinatorially from a `W_BUSY`-aligned
register write (see `instr_wr_en` assignment, which mirrors `start_pulse`'s
comment in the original file).

## 4. Instruction fetch behavior (unchanged)

`control_unit.sv` is not touched. Its `fifo_pop_en`, `fifo_pop_idx`,
`fifo_window[0:WINDOW_SIZE-1]`, `fifo_restart` ports and their semantics
(4-deep lookahead window, shift-on-pop, rewind-on-restart) are byte-for-byte
identical to today. The write port lives entirely on the side of
`instruction_fifo_window` that control_unit does not touch (it only reads
`rom[]` indirectly, through `window[]`).

## 5. Program start/end

- `REG_PROG_LEN` is **not** wired into `control_unit`'s scheduling logic in
  this change. The existing termination mechanism — the scheduler only
  retires when it decodes `OP_END` (`can_issue_end()` / `issue_packet.opcode
  == OP_END` in control_unit.sv, unchanged) — is preserved as-is. The CPU is
  responsible for terminating its program with an `OP_END` word (as the
  original demo ROM already did at `rom[10]`).
- `prog_len` is exposed as a plain output port from `axi4_lite_slave` for
  future use (bounds-checking, host-side readback/debug, or eventually
  wiring a "did fetch_ptr exceed prog_len without hitting END" fault into
  `error`). This is intentionally minimal-footprint for this change: no
  datapath logic consumes it yet.
- `start_pulse`/`fifo_restart` behavior is unchanged: `fifo_restart =
  start_pulse || soft_reset` in control_unit.sv already rewinds
  `fetch_ptr`/`window` to instruction 0 on every fresh run. This composes
  correctly with CPU-loaded programs with no changes: the CPU loads
  instructions 0..N-1 (ending in OP_END), writes `REG_PROG_LEN`, then pulses
  START; `fifo_restart` fires, the window re-primes from `rom[0]`, and
  fetch proceeds exactly as it did for the fixed demo ROM.

## 6. Hazards introduced by a writable memory, and mitigations

1. **Writing while the accelerator is busy.** A CPU write into `rom[]` mid-run
   could corrupt instructions the scheduler hasn't fetched yet (or, worse,
   ones already in the 4-deep `window[]` if `pop_en` and the write race).
   **Mitigation:** `instr_wr_en` is gated with `!busy` in `accelerator.sv`
   (`assign instr_wr_en = instr_wr_en_raw && !busy;`), not in
   `axi4_lite_slave.sv`. Placed in `accelerator.sv` because that module is
   already the sole place cross-module hazard wiring lives in this design
   (e.g. `fifo_restart`), and because `busy` is otherwise only a status bit
   inside `axi4_lite_slave` (feeds `REG_STATUS`) — folding write-gating logic
   into that module would make it responsible for scheduling hazards it has
   no other visibility into. The AXI write itself still completes normally
   (BRESP=OKAY) even while busy; only the resulting `instr_wr_en` pulse to
   the instruction memory is dropped, so the host sees a successful register
   write but the instruction word is silently discarded. This is documented
   behavior, not a bug: a host should poll `REG_STATUS[busy]==0` before
   reprogramming, exactly as it already must before touching
   `REG_SRC_ADDR`/`REG_WEIGHT_ADDR`/etc. for a new run.

2. **Window prefetching uninitialized/stale memory beyond the valid
   program.** Because `window[]` always holds `WINDOW_SIZE=4` live entries
   read ahead of `fetch_ptr`, the window can contain slots beyond the CPU's
   real program (e.g., if the program is 3 instructions long, the window
   will have already read `rom[3]` speculatively). If those slots contain
   garbage, they are irrelevant UNLESS the scheduler actually issues them —
   which only happens if it walks past `OP_END`, which `can_issue_end()`'s
   gating plus the existing "don't advance fetch_ptr past OP_END" fix in
   control_unit.sv already prevents. The remaining risk is purely at
   power-on / before the first program is loaded: **mitigated by resetting
   every `rom[]` slot to `32'h8000_0000` (OP_END) on `rst_n`** (see §6.4).

3. **Write/read collision on the same cycle.** `wr_en` (write) and `pop_en`
   (read of `rom[fetch_ptr]` into `window[WINDOW_SIZE-1]`) are two separate
   `always_ff` blocks both driven off `rom[]`, but under the hazard-1 gating
   above they can never both be active in practice: `wr_en` only asserts
   while `!busy`, and `pop_en` only asserts while `accel_state == ENG_BUSY`
   (`busy` asserted) per control_unit.sv's scheduler. So this is a hazard
   that exists in the RTL's generality but is closed by the `!busy` gate
   from hazard 1 — documented here rather than added as a second interlock,
   to avoid two redundant gating mechanisms.

4. **Uninitialized/stale instruction slots being issued as garbage.**
   Mitigated by changing `instruction_fifo_window`'s reset behavior: all
   `INSTR_DEPTH` slots of `rom[]` are synchronously reset to `32'h8000_0000`
   (`OP_END`, opcode=8, all other fields zero) on `!rst_n`, instead of
   relying on the old `initial` block's fixed demo program. This guarantees
   that any slot the CPU never gets around to writing (including a full
   `INSTR_DEPTH`-sized ROM when the host's program is shorter) always decodes
   as a harmless immediate-terminate instruction rather than a leftover
   opcode from a previous run or simulation `X`/garbage. See the coding
   comment in `instructions_fifo.sv` for the full rationale, including why
   the old demo-program `initial` content was dropped rather than kept as
   the reset default.

## 7. Exact RTL files modified

**Modified:**
- `instructions_fifo.sv` (module `instruction_fifo_window`) — added
  `wr_en`/`wr_addr`/`wr_data` port + write-port `always_ff` block; changed
  reset behavior from `initial`-block demo ROM to synchronous all-`OP_END`
  reset. `window`/`pop_en`/`pop_idx`/`restart` `always_ff` block, and the
  `WINDOW_SIZE`/`INSTR_DEPTH`/`INSTR_WIDTH` parameters, are untouched.
- `axi4_lite_slave.sv` — added `REG_INSTR_ADDR`(0x20)/`REG_INSTR_DATA`(0x24)/
  `REG_PROG_LEN`(0x28) localparams; added `reg_instr_addr`/`reg_prog_len`/
  `reg_instr_data_shadow` registers; added write-path `case` arms; added
  `instr_wr_en`/`instr_wr_addr`/`instr_wr_data`/`prog_len` output ports and
  their combinational assigns; added read-mux arms for the three new
  offsets. All pre-existing registers/ports/behavior untouched.
- `accelerator.sv` — added internal wires for the new instruction-memory
  write path; added the `!busy` gate (`instr_wr_en = instr_wr_en_raw &&
  !busy`); added the three new port connections on the
  `u_axi4_lite_slave` instantiation; added the three new port connections
  on the `u_instruction_fifo` instantiation. No other instantiation
  (`control_unit`, any `bram_*`, `systolic_array`, `vector_unit`,
  `axi4_master`) was touched.

**NOT modified (verbatim copies included in `rtl/` for a self-contained
buildable set):**
`control_unit.sv`, `systolic_array.sv`, `pe.sv`, `vector_unit.sv`,
`silu_lut.sv`, `axi4_master.sv`, `bram_bias_buffer.sv`,
`bram_accum_buffer.sv`, `bram_out_buffer.sv`, `bram_act_buffer.sv`,
`bram_weight_buffer.sv`.

`control_unit.sv` in particular required no change: its instruction-source
interface (`fifo_pop_en`/`fifo_pop_idx`/`fifo_window`/`fifo_restart`) and all
scheduling/dependency-checker logic are completely decoupled from where
`rom[]`'s contents come from.
