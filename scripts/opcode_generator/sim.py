"""
sim.py -- A small, explicit, software model of the accelerator's *current*
microcode semantics (single-tile GEMM only, no tiling), for verifying
microprograms without running RTL simulation.

This is NOT a cycle-accurate re-implementation of control_unit.sv. It is a
functional / data-flow model: each instruction is executed to completion,
in program order, with the same *precondition checks* the RTL's scheduler
uses (the can_issue_* functions in control_unit.sv) asserted before it
runs. If a hand-written microprogram would stall/deadlock or violate a
buffer-scoreboard precondition on real hardware, this model raises an
AssertionError naming the violated precondition, instead of silently
producing a wrong answer.

======================================================================
IMPORTANT MODELING LIMITATIONS (flagged, not silently assumed away)
======================================================================

1. NO CONCURRENCY / NO PIPELINE TIMING.
   Real hardware can have a DMA load in flight while the systolic array is
   still draining a previous MATMUL (that's the whole point of the 4-deep
   instruction window / out-of-order scheduler in control_unit.sv). This
   model executes one instruction at a time to full completion before
   starting the next. It therefore CANNOT reproduce cycle-level races --
   e.g. the exact hazard control_unit.sv documents around array_done_pulse
   landing on the same cycle as an OP_VECTOR issue (control_unit.sv,
   "Completion events" comment block, ~line 1143-1157), or any bug that
   only manifests from edge-detection / same-cycle ordering of pulses.

   FLAG: the user-reported anomaly around instruction `32'h50010000`
   (rom[8], the second VECTOR in the reference program) was observed in a
   waveform (sim.vcd) and could well be exactly this class of cycle-level
   issue. This model executes that instruction's *data dependencies*
   correctly (accum row 1 was written by the preceding MATMUL, bias is
   persistent and READY, out_buf[0] is not IN_USE) and finds no
   precondition violation -- so if the real bug is a same-cycle scoreboard
   race, this model will NOT catch it. Confirming/root-causing that
   specific anomaly still requires the RTL waveform, not this tool.

2. INSTRUCTION-WINDOW / OUT-OF-ORDER ISSUE NOT MODELED.
   control_unit.sv scans a 4-deep instruction window and issues the first
   *ready* instruction, which can reorder relative to program order. This
   model executes strictly in the order given. This is fine for verifying
   a hand-written, already-correctly-ordered microprogram (which is the
   goal here), but it means this model cannot discover whether a given
   ordering would *also* work out-of-order, or whether the real scheduler
   would issue something earlier than written.

3. SINGLE-TILE ONLY (no tiling).
   K (contraction dim) and N (output width) must each fit in one
   ARRAY_SIZE x ARRAY_SIZE weight tile; M (activation rows) must fit in
   one act-buffer bank (<= ARRAY_SIZE, since ACT_DEPTH == ARRAY_SIZE in
   accelerator.sv's instantiation). accum_ctrl is therefore always NONE
   in the generated program (no INIT/ADD/LAST reduction group is needed
   for a single tile) -- ACC_INIT/ACC_ADD/ACC_LAST are implemented and
   exercised by the low-level `matmul()` op below and covered by a
   dedicated multi-tile-accumulation unit test, but the single-tile
   `build_single_tile_gemm_program()` generator does not use them.

4. DMA / AXI BEAT ADDRESSING IS SIMPLIFIED, WITH AN EXPLICIT ASSERTION.
   control_unit.sv's `addr` field for LOAD_WGT/LOAD_ACT/LOAD_BIAS/STORE is
   a DMA-*beat* index, and the beat-to-row/element mapping is config
   dependent (see bram_weight_buffer.sv, bram_act_buffer.sv,
   bram_bias_buffer.sv). This model only supports the configuration used
   by the reference program in instructions_fifo.sv, where
   DMA_WIDTH/DATA_WIDTH == ARRAY_SIZE, i.e. ELEMENTS_PER_BEAT ==
   ARRAY_SIZE, so one DMA beat == exactly one row for weight/activation
   loads (confirmed against bram_weight_buffer.sv's wr_row = wr_addr /
   (COLS/ELEMENTS_PER_DMA), which collapses to wr_row == wr_addr when
   COLS == ELEMENTS_PER_DMA). This is asserted at construction time
   (`Accelerator.__init__`); other DMA_WIDTH/DATA_WIDTH/ARRAY_SIZE
   combinations would need the full beat/bank arithmetic control_unit.sv
   implements, which is out of scope here ("do not implement tiled GEMM
   yet" / keep the model simple and explicit).

   The bias buffer's beat packing (ELEMENTS_PER_DMA = DMA_WIDTH / ACC_W,
   ACC_W=32) *is* modeled faithfully (bram_bias_buffer.sv), since it
   differs from the weight/act beat convention even in the reference
   config (2 bias elements per 64-bit beat, not 8).

5. QUANTIZATION / VECTOR-UNIT PATH.
   OP_VECTOR runs the full vector_unit.sv pipeline: s0 = acc + bias,
   s1 = (s0 * requant_mult) >>> requant_shift, clamp to INT8, then an
   activation (NONE/RELU/SILU via the 256-entry LUT in silu_lut.sv, which
   this model reproduces bit-for-bit using the same real-arithmetic
   construction). Default vec-ctrl (requant_mult=1, requant_shift=0,
   act_type=NONE) is an identity pass-through matching
   axi4_lite_slave.sv's REG_VEC_CTRL reset value, which is what lets
   `A @ B == execute_microcode(...)` hold *exactly* for small test
   matrices whose dot products don't saturate INT8/INT32.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum
from typing import List, Dict, Optional
import numpy as np

from scripts.opcode_generator.isa import Instruction, Opcode, AccumCtrl, NOP, LOAD_WGT, LOAD_ACT, LOAD_BIAS, \
    MATMUL, VECTOR, STORE, SWAP_WGT, END


# ---------------------------------------------------------------------------
# Buffer scoreboard states -- mirrors control_unit.sv's buffer_state_t
# ---------------------------------------------------------------------------

class BufState(Enum):
    EMPTY = "EMPTY"
    FILLING = "FILLING"
    READY = "READY"
    IN_USE = "IN_USE"


class SchedulingError(AssertionError):
    """Raised when a hand-written microprogram would violate one of
    control_unit.sv's can_issue_* preconditions -- i.e. it would stall or
    behave unexpectedly on real hardware."""


# ---------------------------------------------------------------------------
# silu_lut.sv, reproduced bit-for-bit (same real-arithmetic construction,
# same rounding, same clamp) so OP_VECTOR's SILU path matches hardware
# exactly, not just approximately.
# ---------------------------------------------------------------------------

def _build_silu_lut(scale: float = 16.0) -> List[int]:
    import math
    rom = [0] * 256
    for i in range(256):
        code_in = i if i < 128 else i - 256
        v = code_in / scale
        s = 1.0 / (1.0 + math.exp(-v))
        yv = v * s
        code_out = int(math.floor(yv * scale + (0.5 if yv >= 0.0 else -0.5)))
        if code_out > 127:
            code_out = 127
        if code_out < -128:
            code_out = -128
        rom[i] = code_out
    return rom

_SILU_LUT = _build_silu_lut(16.0)


def _clamp8(v: int) -> int:
    if v > 127:
        return 127
    if v < -128:
        return -128
    return v


class ActType(Enum):
    NONE = 0
    RELU = 1
    SILU = 2


def _vector_unit(acc_row: np.ndarray, bias_row: np.ndarray,
                  requant_mult: int, requant_shift: int,
                  act_type: ActType) -> np.ndarray:
    """vector_unit.sv, functionally: per-lane bias-add -> requant -> clamp
    -> activation. acc_row/bias_row are INT32 vectors of length OC_LANES."""
    out = np.zeros_like(acc_row, dtype=np.int64)
    for c in range(len(acc_row)):
        s0 = int(acc_row[c]) + int(bias_row[c])
        prod = s0 * requant_mult          # requant_mult modeled unsigned, >= 0 (per RTL comment)
        sh = prod >> requant_shift        # arithmetic shift, matches >>> on signed value in SV
        r = _clamp8(sh)
        if act_type == ActType.RELU:
            y = 0 if r < 0 else r
        elif act_type == ActType.SILU:
            y = _SILU_LUT[r & 0xFF]
        else:
            y = r
        out[c] = y
    return out


# ---------------------------------------------------------------------------
# Accelerator state machine
# ---------------------------------------------------------------------------

@dataclass
class AcceleratorConfig:
    array_size: int = 8      # ARRAY_SIZE (ROWS == COLS for the systolic array)
    data_width: int = 8      # DATA_WIDTH (INT8 activations/weights)
    dma_width: int = 64      # DMA_WIDTH (AXI beat width, bits)
    acc_width: int = 32      # ACC_W (INT32 accumulator)

    def __post_init__(self):
        elements_per_beat = self.dma_width // self.data_width
        # See module docstring, limitation (4): this model only supports
        # configs where one DMA beat == exactly one activation/weight row.
        assert elements_per_beat == self.array_size, (
            "AcceleratorConfig: this simplified model requires "
            "DMA_WIDTH/DATA_WIDTH == ARRAY_SIZE (one beat == one row for "
            "weight/activation loads), matching the reference program's "
            f"config. Got ELEMENTS_PER_BEAT={elements_per_beat} != "
            f"ARRAY_SIZE={self.array_size}. General beat/bank addressing "
            "(the full control_unit.sv arithmetic) is not implemented here."
        )

    @property
    def elements_per_beat(self) -> int:
        return self.dma_width // self.data_width

    @property
    def bias_elements_per_beat(self) -> int:
        return self.dma_width // self.acc_width


class Accelerator:
    """Functional model of accelerator.sv's datapath + control_unit.sv's
    scheduling preconditions, restricted to a single GEMM tile."""

    def __init__(self, cfg: AcceleratorConfig,
                 requant_mult: int = 1, requant_shift: int = 0,
                 act_type: ActType = ActType.NONE):
        self.cfg = cfg
        N = cfg.array_size

        # weight staging buffer (bram_weight_buffer) + array-parked weights
        self.wgt_buf_state = BufState.EMPTY
        self.wgt_staging: Optional[np.ndarray] = None      # (N,N) once loaded
        self.array_weight: Optional[np.ndarray] = None     # (N,N) once swapped in
        self.array_wgt_valid = False

        # two activation banks (bram_act_buffer)
        self.act_buf_state = [BufState.EMPTY, BufState.EMPTY]
        self.act_rows_remaining = [0, 0]
        self.act_data: List[Dict[int, np.ndarray]] = [{}, {}]

        # bias buffer (single-banked, persistent)
        self.bias_buf_state = BufState.EMPTY
        self.bias_data: Optional[np.ndarray] = None

        # accumulation buffer (bram_accum_buffer)
        self.accum_buf_state = BufState.EMPTY
        self.accum_data: Dict[int, np.ndarray] = {}

        # two output banks (bram_out_buffer)
        self.out_buf_state = [BufState.EMPTY, BufState.EMPTY]
        self.out_data: List[Dict[int, np.ndarray]] = [{}, {}]

        # vector-unit config (mirrors axi4_lite_slave.sv REG_VEC_CTRL)
        self.requant_mult = requant_mult
        self.requant_shift = requant_shift
        self.act_type = act_type

        # "DRAM" sources, bound via load_sources() before running a program
        self._dram_weight: Optional[np.ndarray] = None   # (N,N)
        self._dram_act: Optional[np.ndarray] = None       # (>=rows, N)
        self._dram_bias: Optional[np.ndarray] = None       # (N,)
        self._dram_out: Dict[int, np.ndarray] = {}          # STORE destination, row -> vec

        self._ended = False

    # -- binds the "DRAM-side" source/destination arrays an instruction's
    # addr/length fields index into. Kept separate from register state
    # because this model doesn't simulate byte-addressed DRAM. --
    def load_sources(self, weight_tile: np.ndarray, act_rows: np.ndarray,
                      bias_vec: np.ndarray):
        N = self.cfg.array_size
        assert weight_tile.shape == (N, N)
        assert act_rows.shape[1] == N
        assert bias_vec.shape == (N,)
        self._dram_weight = weight_tile
        self._dram_act = act_rows
        self._dram_bias = bias_vec
        self._dram_out = {}

    # ------------------------------------------------------------------
    # can_issue_* -- ports of control_unit.sv's dependency checker
    # ------------------------------------------------------------------
    def _can_issue_load_wgt(self) -> bool:
        return self.wgt_buf_state == BufState.EMPTY

    def _can_issue_load_act(self, dst: int) -> bool:
        return self.act_buf_state[dst] == BufState.EMPTY

    def _can_issue_load_bias(self) -> bool:
        return self.bias_buf_state == BufState.EMPTY

    def _can_issue_matmul(self, src: int, accum_ctrl: AccumCtrl) -> bool:
        if accum_ctrl in (AccumCtrl.NONE, AccumCtrl.INIT):
            accum_ok = self.accum_buf_state == BufState.EMPTY
        else:
            accum_ok = self.accum_buf_state == BufState.FILLING
        return (self.array_wgt_valid and
                self.act_buf_state[src] == BufState.READY and
                accum_ok)

    def _can_issue_store(self, src: int) -> bool:
        return self.out_buf_state[src] == BufState.READY

    def _can_issue_swap_wgt(self) -> bool:
        return self.wgt_buf_state == BufState.READY

    def _can_issue_vector(self, dst: int) -> bool:
        return (self.accum_buf_state == BufState.READY and
                self.bias_buf_state == BufState.READY and
                self.out_buf_state[dst] != BufState.IN_USE)

    def _can_issue_end(self) -> bool:
        return True  # engines are always "idle" between instructions in this model

    # ------------------------------------------------------------------
    # Execute a single instruction to completion.
    # ------------------------------------------------------------------
    def step(self, ins: Instruction):
        assert not self._ended, "program already ended (OP_END issued); no further instructions expected"
        op = ins.opcode
        N = self.cfg.array_size

        if op == Opcode.NOP:
            return

        elif op == Opcode.LOAD_WGT:
            if not self._can_issue_load_wgt():
                raise SchedulingError(f"LOAD_WGT: wgt_buf_state must be EMPTY, is {self.wgt_buf_state}")
            beats = ins.length + 1
            assert beats == N, (
                f"LOAD_WGT: this model expects one instruction to load the "
                f"full {N}x{N} tile (beats=length+1={beats} != ARRAY_SIZE={N}); "
                "partial/chunked weight loads across multiple instructions "
                "are not modeled (single-tile only)."
            )
            # rows [addr, addr+beats) of the weight tile, one row/beat
            # (see AcceleratorConfig beat==row assumption)
            self.wgt_staging = self._dram_weight[ins.addr: ins.addr + beats, :].copy()
            self.wgt_buf_state = BufState.FILLING
            # DMA completion + registered BRAM read landing modeled as
            # instantaneous in this non-timed simulator.
            self.wgt_buf_state = BufState.READY

        elif op == Opcode.LOAD_ACT:
            if not self._can_issue_load_act(ins.dst):
                raise SchedulingError(f"LOAD_ACT: act_buf_state[{ins.dst}] must be EMPTY, is {self.act_buf_state[ins.dst]}")
            beats = ins.length + 1
            rows = (beats * self.cfg.elements_per_beat) // N   # mirrors control_unit.sv's act_rows_remaining calc
            self.act_buf_state[ins.dst] = BufState.FILLING
            for i in range(rows):
                self.act_data[ins.dst][ins.addr + i] = self._dram_act[ins.addr + i, :].copy()
            self.act_rows_remaining[ins.dst] = rows
            self.act_buf_state[ins.dst] = BufState.READY

        elif op == Opcode.LOAD_BIAS:
            if not self._can_issue_load_bias():
                raise SchedulingError(f"LOAD_BIAS: bias_buf_state must be EMPTY, is {self.bias_buf_state}")
            beats = ins.length + 1
            epb = self.cfg.bias_elements_per_beat
            assert beats * epb == N, (
                f"LOAD_BIAS: this model expects one instruction to load the "
                f"full {N}-lane bias vector (beats*ELEMENTS_PER_DMA="
                f"{beats * epb} != ARRAY_SIZE={N})."
            )
            self.bias_buf_state = BufState.FILLING
            self.bias_data = self._dram_bias.copy()
            self.bias_buf_state = BufState.READY

        elif op == Opcode.MATMUL:
            if not self._can_issue_matmul(ins.src, ins.accum_ctrl):
                raise SchedulingError(
                    f"MATMUL: precondition failed (array_wgt_valid={self.array_wgt_valid}, "
                    f"act_buf_state[{ins.src}]={self.act_buf_state[ins.src]}, "
                    f"accum_buf_state={self.accum_buf_state}, accum_ctrl={ins.accum_ctrl.name})"
                )
            act_row = self.act_data[ins.src][ins.addr]
            # systolic_array.sv: result_out[c] = sum_r act_in[r] * W[r][c]
            result = (act_row.astype(np.int64) @ self.array_weight.astype(np.int64))
            wr_init = ins.accum_ctrl in (AccumCtrl.NONE, AccumCtrl.INIT)
            if wr_init:
                self.accum_data[ins.addr] = result
            else:
                prev = self.accum_data.get(ins.addr, np.zeros(N, dtype=np.int64))
                self.accum_data[ins.addr] = prev + result
            # scoreboard: act bank row-accounting (control_unit.sv array_done_pulse block)
            self.act_rows_remaining[ins.src] -= 1
            self.act_buf_state[ins.src] = (BufState.EMPTY if self.act_rows_remaining[ins.src] <= 0
                                            else BufState.READY)
            if ins.accum_ctrl in (AccumCtrl.NONE, AccumCtrl.LAST):
                self.accum_buf_state = BufState.READY
            else:
                self.accum_buf_state = BufState.FILLING

        elif op == Opcode.VECTOR:
            if not self._can_issue_vector(ins.dst):
                raise SchedulingError(
                    f"VECTOR: precondition failed (accum_buf_state={self.accum_buf_state}, "
                    f"bias_buf_state={self.bias_buf_state}, out_buf_state[{ins.dst}]={self.out_buf_state[ins.dst]})"
                )
            acc_row = self.accum_data[ins.addr]
            q = _vector_unit(acc_row, self.bias_data, self.requant_mult,
                              self.requant_shift, self.act_type)
            self.out_data[ins.dst][ins.addr] = q
            self.accum_buf_state = BufState.EMPTY
            self.out_buf_state[ins.dst] = BufState.READY

        elif op == Opcode.STORE:
            if not self._can_issue_store(ins.src):
                raise SchedulingError(f"STORE: out_buf_state[{ins.src}] must be READY, is {self.out_buf_state[ins.src]}")
            beats = ins.length + 1
            self.out_buf_state[ins.src] = BufState.IN_USE
            for i in range(beats):
                row = ins.addr + i
                self._dram_out[row] = self.out_data[ins.src][row].copy()
            self.out_buf_state[ins.src] = BufState.EMPTY

        elif op == Opcode.SWAP_WGT:
            if not self._can_issue_swap_wgt():
                raise SchedulingError(f"SWAP_WGT: wgt_buf_state must be READY, is {self.wgt_buf_state}")
            self.array_weight = self.wgt_staging
            self.array_wgt_valid = True
            self.wgt_buf_state = BufState.EMPTY

        elif op == Opcode.END:
            if not self._can_issue_end():
                raise SchedulingError("END: engines not idle")
            self._ended = True

        else:
            raise ValueError(f"unhandled opcode {op}")

    def run(self, program: List[Instruction]):
        for ins in program:
            self.step(ins)
            if self._ended:
                break
        assert self._ended, "program did not reach OP_END"

    def stored_rows(self) -> Dict[int, np.ndarray]:
        return self._dram_out

    # ------------------------------------------------------------------
    # Fine-grained DMA-source rebinding, used by the tiled-GEMM driver
    # (tiling.py) to point each individual LOAD_WGT/LOAD_ACT/LOAD_BIAS at
    # the correct tile of the full matrices *before* stepping that
    # instruction. This models a host that reprograms weight_addr/
    # src_addr/bias_addr (or, equivalently, stages each tile contiguously
    # in scratch DRAM) ahead of every DMA-triggering instruction -- see
    # tiling.py's module docstring for why this is necessary given
    # axi4_master.sv only implements simple linear INCR bursts (no 2D/
    # strided burst support for pulling a sub-tile out of a larger
    # row-major matrix in one shot).
    # ------------------------------------------------------------------
    def bind_weight_source(self, tile: np.ndarray):
        N = self.cfg.array_size
        assert tile.shape == (N, N)
        self._dram_weight = tile

    def bind_act_source(self, rows: np.ndarray):
        N = self.cfg.array_size
        assert rows.shape[1] == N
        self._dram_act = rows

    def bind_bias_source(self, vec: np.ndarray):
        N = self.cfg.array_size
        assert vec.shape == (N,)
        self._dram_bias = vec

    def clear_dram_out(self):
        """Drop already-drained STORE output so a fresh row-tile's
        out_buf-local row addresses (0..rows_in_tile-1) don't collide with
        a previous row-tile's STORE'd rows within the same run."""
        self._dram_out = {}


# ---------------------------------------------------------------------------
# Reference GEMM
# ---------------------------------------------------------------------------

def reference_gemm(A: np.ndarray, B: np.ndarray) -> np.ndarray:
    """C = A @ B, plain integer matmul, no quantization."""
    return A.astype(np.int64) @ B.astype(np.int64)


# ---------------------------------------------------------------------------
# Microprogram generator for the *single-tile* GEMM established in the
# previous step (matches instructions_fifo.sv's hand-assembled ROM,
# generalized to arbitrary M/K/N <= ARRAY_SIZE and arbitrary bias).
# ---------------------------------------------------------------------------

def build_single_tile_gemm_program(M: int, cfg: AcceleratorConfig) -> List[Instruction]:
    """Program shape mirrors instructions_fifo.sv's reference ROM exactly:
    NOP, LOAD_WGT (full tile), LOAD_ACT (M rows), LOAD_BIAS (full vector),
    SWAP_WGT, then M x (MATMUL, VECTOR) alternating pairs (accum_ctrl=NONE
    -- required because accum_buf_state is single-banked, see the
    instructions_fifo.sv comment this mirrors), STORE (M rows), END.
    """
    N = cfg.array_size
    assert 1 <= M <= N, f"single-tile model requires 1 <= M <= ARRAY_SIZE ({N}), got M={M}"

    prog: List[Instruction] = [
        NOP(),
        LOAD_WGT(addr=0, length=N - 1),
        LOAD_ACT(dst=0, addr=0, length=M - 1),
        LOAD_BIAS(addr=0, length=(N // cfg.bias_elements_per_beat) - 1),
        SWAP_WGT(),
    ]
    for row in range(M):
        prog.append(MATMUL(src=0, addr=row, accum_ctrl=AccumCtrl.NONE))
        prog.append(VECTOR(dst=0, addr=row))
    prog.append(STORE(src=0, addr=0, length=M - 1))
    prog.append(END())
    return prog


def execute_microcode(program: List[Instruction], A: np.ndarray, B: np.ndarray,
                       cfg: Optional[AcceleratorConfig] = None,
                       bias: Optional[np.ndarray] = None,
                       requant_mult: int = 1, requant_shift: int = 0,
                       act_type: ActType = ActType.NONE) -> np.ndarray:
    """Run `program` on the functional accelerator model against A (M0,K0)
    and B (K0,N0) with M0,K0,N0 <= ARRAY_SIZE, zero-padded into ARRAY_SIZE
    x ARRAY_SIZE tiles the way a real caller would pad in DRAM before
    kicking off the run. Returns the (M0, N0) result actually produced by
    the STORE'd rows.
    """
    if cfg is None:
        cfg = AcceleratorConfig()
    N = cfg.array_size
    M0, K0 = A.shape
    K0b, N0 = B.shape
    assert K0 == K0b
    assert M0 <= N and K0 <= N and N0 <= N, (
        f"single-tile only: A/B must fit in one {N}x{N} tile "
        f"(got M={M0},K={K0},N={N0})"
    )

    weight_tile = np.zeros((N, N), dtype=np.int64)
    weight_tile[:K0, :N0] = B
    act_rows = np.zeros((N, N), dtype=np.int64)
    act_rows[:M0, :K0] = A
    bias_vec = np.zeros(N, dtype=np.int64)
    if bias is not None:
        assert bias.shape == (N0,)
        bias_vec[:N0] = bias

    accel = Accelerator(cfg, requant_mult=requant_mult, requant_shift=requant_shift, act_type=act_type)
    accel.load_sources(weight_tile, act_rows, bias_vec)
    accel.run(program)

    rows = accel.stored_rows()
    C = np.zeros((M0, N0), dtype=np.int64)
    for r in range(M0):
        assert r in rows, f"row {r} was never STORE'd by the microprogram"
        C[r, :] = rows[r][:N0]
    return C
