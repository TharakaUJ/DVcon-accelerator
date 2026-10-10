"""
tiling.py -- Tiled GEMM microprogram generator + executor for the
*current* accelerator architecture (control_unit.sv), building on the
verified single-tile programming model in sim.py.

======================================================================
TILING STRATEGY, derived from control_unit.sv's actual scoreboard rules
======================================================================

C[M x N] = A[M x K] @ B[K x N], with M, K, N possibly > ARRAY_SIZE (P).

Tile the problem the standard way:
    row tiles    i = 0 .. ceil(M/P)-1     (rows_in_tile = min(P, M-i*P))
    col tiles    j = 0 .. ceil(N/P)-1     (cols_in_tile = min(P, N-j*P))
    k tiles      kt = 0 .. ceil(K/P)-1    (k_in_tile   = min(P, K-kt*P))

For output tile C[i,j]:
    C[i,j] = sum_kt  A[i,kt] @ B[kt,j]

Mapped onto MATMUL/accum_ctrl:
    kt == 0                     -> ACC_INIT  (overwrite accum row)
    0 < kt < num_k_tiles-1       -> ACC_ADD   (accumulate into accum row)
    kt == num_k_tiles-1 (>0)     -> ACC_LAST  (accumulate + mark READY)
    num_k_tiles == 1             -> ACC_NONE  (single pass, no reduction
                                                group needed at all)

---------------------------------------------------------------------
CONSTRAINT #1 (why rows can't be batched across a K-reduction):
---------------------------------------------------------------------
control_unit.sv's `accum_buf_state` is a SINGLE scalar for the *entire*
accumulation buffer, not one state per row, even though
bram_accum_buffer.sv physically stores ARRAY_SIZE independent rows.
can_issue_matmul() requires accum_buf_state==EMPTY for ACC_NONE/ACC_INIT
and ==FILLING for ACC_ADD/ACC_LAST; the scoreboard-update block sets it
to FILLING after any INIT/ADD MATMUL and back to READY only after a
NONE/LAST MATMUL, and OP_VECTOR is the only thing that resets it back to
EMPTY. So only ONE row's INIT->ADD->...->LAST chain can be "open" at a
time system-wide: you cannot start row r+1's ACC_INIT while row r's
reduction is still in FILLING state, and row r's own VECTOR must drain
the buffer (accum_buf_state -> EMPTY) before row r+1 can even begin.

=> Consequence: for each output tile, the K-reduction MUST be run to
completion, MATMUL-then-VECTOR, one activation row at a time (row-outer,
k-tile-inner loop nesting) -- exactly the pattern instructions_fifo.sv's
own reference program comment already calls out as a "known, unfixed
limitation" for the K=1-tile case; tiling makes the same limitation bite
harder, because it also forces weight-tile reload (see below).

---------------------------------------------------------------------
CONSTRAINT #2 (why the weight tile gets reloaded far more than you'd
like, once K needs more than one tile):
---------------------------------------------------------------------
The weight path has two stages: a staging buffer (bram_weight_buffer,
single-banked) and the array's own parked registers (array_weight,
loaded by SWAP_WGT). can_issue_load_wgt() only requires the STAGING
buffer to be EMPTY (true immediately after any SWAP_WGT), and
array_wgt_valid, once set, never clears itself -- so as long as you never
need to change WHICH tile is parked in the array, you can matmul many
rows against it without ever reissuing LOAD_WGT/SWAP_WGT (this is what
the original single-tile program already exploited: one LOAD_WGT+
SWAP_WGT, then M independent MATMUL/VECTOR pairs).

But per Constraint #1, a tiled K-reduction for one row must walk through
ALL num_k_tiles distinct weight sub-tiles (kt=0..num_k_tiles-1)
back-to-back before that row's VECTOR can fire -- and then the NEXT row
starts its own reduction from kt=0 again, needing the *same* kt=0 weight
tile that was overwritten by kt=1 partway through the previous row. There
is no way to keep more than one weight tile "warm" at once (single
staging buffer, single array register, no double-buffering), so:

    LOAD_WGT/SWAP_WGT count per output tile (i,j)
        = rows_in_tile * num_k_tiles          (if num_k_tiles > 1)
        = 1                                    (if num_k_tiles == 1 --
          the weight tile never changes across rows, so this model loads
          it once up front and reuses array_wgt_valid across every row
          in every row-tile of that column, matching the original
          single-tile program exactly)

This is a real inefficiency inherent to the CURRENT scoreboard/weight
buffer design, not an artifact of this software model -- see the report
at the bottom of test_tiled_gemm.py / the chat summary for the RTL change
that would fix it (per-row accum tracking + a double-buffered weight
path).

---------------------------------------------------------------------
CONSTRAINT #3 (bias buffer can only be loaded ONCE per accelerator run):
---------------------------------------------------------------------
bias_buf_state starts EMPTY, LOAD_BIAS drives it FILLING->READY, and
per the "persistent resource" comment in control_unit.sv it deliberately
never goes back to EMPTY on its own -- the ONLY things that reset it to
EMPTY are `!rst_n` or `soft_reset`. can_issue_load_bias() requires EMPTY.
So a second OP_LOAD_BIAS later in the SAME instruction stream can never
issue (it would stall forever on real hardware) -- and soft_reset isn't
a mid-program tool either: it's wired straight into `fifo_restart`
(`fifo_restart = start_pulse || soft_reset`), which rewinds the
instruction fetch pointer back to program address 0. So soft_reset
doesn't "reset just the bias buffer mid-stream", it restarts the whole
program from instruction 0.

=> Consequence: under CURRENT semantics, a single continuous microcode
run can only ever use ONE bias vector. Since bias is indexed by output
channel (column), a GEMM with more than one column tile (N > ARRAY_SIZE)
needs a *different* bias slice per column tile -- which the hardware, as
specified today, cannot do within one run. This model makes that
explicit rather than papering over it: it structures the program as one
independent "run" per column tile j (each with its own LOAD_BIAS for
that tile's bias slice), corresponding to a separate host-triggered
`start_pulse` transaction (the host would rewrite the bias_addr/
weight_addr/src_addr AXI-lite registers between runs). Runs are executed
against a fresh accelerator scoreboard state (see `Accelerator()`
construction in `execute_tiled_program`), which is exactly what a real
soft_reset (or power-up) does.

If bias is all-zero (as in every test in this file unless stated
otherwise) this distinction is invisible in the output, but the
multi-run structure is kept regardless, so the generated program stays
honest about what current hardware can and cannot do in one shot.

---------------------------------------------------------------------
CONSTRAINT #4 (no strided/2D DMA burst -- tiles must arrive pre-packed):
---------------------------------------------------------------------
control_unit.sv computes `dma_rd_addr = weight_addr + (addr << shift)`
and axi4_master.sv only issues a single simple INCR burst per rd_start
pulse -- there is no row-stride parameter anywhere in this path. A
LOAD_WGT/LOAD_ACT burst can only ever pull a *contiguous* run of beats
starting at one address. That is exactly a full ARRAY_SIZE x ARRAY_SIZE
tile when the tile's row width equals the *stored* row width in DRAM
(no gap between tile rows) -- but a sub-tile carved out of a larger
K x N (or M x K) row-major matrix with N > ARRAY_SIZE (or K > ARRAY_SIZE)
is NOT contiguous: consecutive tile rows are separated by
(full_row_width - ARRAY_SIZE) elements belonging to other column tiles.

=> Consequence: correctly loading a sub-tile from a larger row-major
matrix in ONE burst is not something the current DMA/control_unit
addressing scheme supports at all -- confirmed against axi4_master.sv
(no strided-burst logic) and control_unit.sv (no per-row re-trigger
logic within a single LOAD_* dispatch). A real system would need either
(a) a host-side repacking pass that stages each tile contiguously in a
scratch DRAM region before the corresponding LOAD_WGT/LOAD_ACT/
LOAD_BIAS, or (b) an RTL change adding row-stride/2D-burst support to
axi4_master + a stride register to control_unit. This model takes
option (a) as given (see `LoadMeta`/`execute_tiled_program` below, which
binds each LOAD_* instruction directly to its already-tile-shaped source
slice, addr=0 always) and flags it here rather than silently assuming a
capability the RTL doesn't have. This is a second, independent
concrete RTL gap to report alongside Constraint #2/#3.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import List, Dict, Tuple, Optional
import numpy as np

from scripts.opcode_generator.isa import Instruction, MATMUL, VECTOR, LOAD_WGT, LOAD_ACT, LOAD_BIAS, \
    SWAP_WGT, STORE, NOP, END, AccumCtrl
from scripts.opcode_generator.sim import AcceleratorConfig, Accelerator, ActType


def _ceil_div(a: int, b: int) -> int:
    return -(-a // b)


@dataclass
class LoadMeta:
    kind: str          # 'weight' | 'act' | 'bias'
    indices: tuple      # 'weight': (kt, j)   'act': (i, r, kt)   'bias': (j,)


@dataclass
class StoreMeta:
    i: int
    j: int
    rows: int
    cols: int


@dataclass
class TiledRun:
    """One accelerator invocation (one `start_pulse`/soft_reset epoch) --
    see Constraint #3 above for why bias forces a run boundary per
    column tile."""
    j_tile: int
    instructions: List[Instruction]
    load_meta: Dict[int, LoadMeta] = field(default_factory=dict)
    store_meta: Dict[int, StoreMeta] = field(default_factory=dict)

    def hexdump(self) -> List[str]:
        return [ins.hex() for ins in self.instructions]


def tiling_geometry(M: int, K: int, N: int, array_size: int):
    P = array_size
    num_row_tiles = _ceil_div(M, P)
    num_k_tiles = _ceil_div(K, P)
    num_col_tiles = _ceil_div(N, P)
    row_tiles = [(i, min(P, M - i * P)) for i in range(num_row_tiles)]
    k_tiles = [(kt, min(P, K - kt * P)) for kt in range(num_k_tiles)]
    col_tiles = [(j, min(P, N - j * P)) for j in range(num_col_tiles)]
    return row_tiles, k_tiles, col_tiles


def build_tiled_gemm_runs(M: int, K: int, N: int, cfg: AcceleratorConfig) -> List[TiledRun]:
    """Generate the complete tiled-GEMM microprogram (as a list of
    per-column-tile runs -- see Constraint #3) for C[MxN] = A[MxK] @ B[KxN]
    on an ARRAY_SIZE x ARRAY_SIZE systolic array, following the strategy
    documented in this module's docstring. Pure structure: does not touch
    A/B/bias data (see execute_tiled_program for that)."""
    P = cfg.array_size
    row_tiles, k_tiles, col_tiles = tiling_geometry(M, K, N, P)
    bias_epb = cfg.bias_elements_per_beat
    assert P % bias_epb == 0

    runs: List[TiledRun] = []
    for j, cols_in_tile in col_tiles:
        instructions: List[Instruction] = [NOP()]
        load_meta: Dict[int, LoadMeta] = {}
        store_meta: Dict[int, StoreMeta] = {}

        idx = len(instructions)
        instructions.append(LOAD_BIAS(addr=0, length=(P // bias_epb) - 1))
        load_meta[idx] = LoadMeta('bias', (j,))

        single_weight_tile = (len(k_tiles) == 1)
        if single_weight_tile:
            # Constraint #2's fast path: the weight tile never changes
            # across rows/row-tiles for this column, so load+swap it once
            # and reuse array_wgt_valid for everything below (exactly
            # like the original, already-verified single-tile program).
            kt0, _ = k_tiles[0]
            idx = len(instructions)
            instructions.append(LOAD_WGT(addr=0, length=P - 1))
            load_meta[idx] = LoadMeta('weight', (kt0, j))
            instructions.append(SWAP_WGT())

        for i, rows_in_tile in row_tiles:
            for r in range(rows_in_tile):
                if single_weight_tile:
                    idx = len(instructions)
                    instructions.append(LOAD_ACT(dst=0, addr=r, length=0))
                    load_meta[idx] = LoadMeta('act', (i, r, k_tiles[0][0]))
                    instructions.append(MATMUL(src=0, addr=r, accum_ctrl=AccumCtrl.NONE))
                else:
                    # Constraint #1 + #2: full K-reduction for this row,
                    # reloading the weight tile at every step.
                    for kt_pos, (kt, k_in_tile) in enumerate(k_tiles):
                        idx = len(instructions)
                        instructions.append(LOAD_WGT(addr=0, length=P - 1))
                        load_meta[idx] = LoadMeta('weight', (kt, j))

                        idx = len(instructions)
                        instructions.append(LOAD_ACT(dst=0, addr=r, length=0))
                        load_meta[idx] = LoadMeta('act', (i, r, kt))

                        instructions.append(SWAP_WGT())

                        if kt_pos == 0:
                            ctrl = AccumCtrl.INIT
                        elif kt_pos == len(k_tiles) - 1:
                            ctrl = AccumCtrl.LAST
                        else:
                            ctrl = AccumCtrl.ADD
                        instructions.append(MATMUL(src=0, addr=r, accum_ctrl=ctrl))

                instructions.append(VECTOR(dst=0, addr=r))

            idx = len(instructions)
            instructions.append(STORE(src=0, addr=0, length=rows_in_tile - 1))
            store_meta[idx] = StoreMeta(i=i, j=j, rows=rows_in_tile, cols=cols_in_tile)

        instructions.append(END())
        runs.append(TiledRun(j_tile=j, instructions=instructions,
                              load_meta=load_meta, store_meta=store_meta))
    return runs


def _padded_weight_tile(B: np.ndarray, kt: int, j: int, P: int) -> np.ndarray:
    K, N = B.shape
    tile = np.zeros((P, P), dtype=np.int64)
    k0, k1 = kt * P, min(kt * P + P, K)
    n0, n1 = j * P, min(j * P + P, N)
    tile[:k1 - k0, :n1 - n0] = B[k0:k1, n0:n1]
    return tile


def _padded_act_row(A: np.ndarray, i: int, r: int, kt: int, P: int) -> np.ndarray:
    M, K = A.shape
    buf = np.zeros((P, P), dtype=np.int64)   # only row `r` is meaningful; see LOAD_ACT addr==r
    row_idx = i * P + r
    k0, k1 = kt * P, min(kt * P + P, K)
    buf[r, :k1 - k0] = A[row_idx, k0:k1]
    return buf


def _padded_bias_tile(bias: np.ndarray, j: int, P: int) -> np.ndarray:
    N = bias.shape[0]
    vec = np.zeros(P, dtype=np.int64)
    n0, n1 = j * P, min(j * P + P, N)
    vec[:n1 - n0] = bias[n0:n1]
    return vec


def execute_tiled_program(runs: List[TiledRun], A: np.ndarray, B: np.ndarray,
                           cfg: AcceleratorConfig,
                           bias: Optional[np.ndarray] = None,
                           requant_mult: int = 1, requant_shift: int = 0,
                           act_type: ActType = ActType.NONE) -> np.ndarray:
    """Execute a tiled microprogram produced by build_tiled_gemm_runs
    against real A/B/bias data, binding each LOAD_* instruction's DMA
    source tile-by-tile (see Constraint #4), and assembling the final
    C[MxN] from every STORE's output. Each TiledRun starts from a fresh
    Accelerator (see Constraint #3 -- this mirrors a distinct
    start_pulse/soft_reset boundary on real hardware)."""
    P = cfg.array_size
    M, K = A.shape
    K2, N = B.shape
    assert K == K2
    if bias is None:
        bias = np.zeros(N, dtype=np.int64)
    assert bias.shape == (N,)

    C = np.zeros((M, N), dtype=np.int64)

    for run in runs:
        accel = Accelerator(cfg, requant_mult=requant_mult, requant_shift=requant_shift, act_type=act_type)
        for idx, ins in enumerate(run.instructions):
            meta = run.load_meta.get(idx)
            if meta is not None:
                if meta.kind == 'weight':
                    kt, j = meta.indices
                    accel.bind_weight_source(_padded_weight_tile(B, kt, j, P))
                elif meta.kind == 'act':
                    i, r, kt = meta.indices
                    accel.bind_act_source(_padded_act_row(A, i, r, kt, P))
                elif meta.kind == 'bias':
                    (j,) = meta.indices
                    accel.bind_bias_source(_padded_bias_tile(bias, j, P))
                else:
                    raise ValueError(meta.kind)

            accel.step(ins)

            sm = run.store_meta.get(idx)
            if sm is not None:
                rows = accel.stored_rows()
                for rr in range(sm.rows):
                    C[sm.i * P + rr, sm.j * P: sm.j * P + sm.cols] = rows[rr][:sm.cols]
                accel.clear_dram_out()
    return C


def instruction_count(runs: List[TiledRun]) -> int:
    return sum(len(r.instructions) for r in runs)
