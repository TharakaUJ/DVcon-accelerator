"""
gemm_compiler.py -- Reusable GEMM microcode generator ("first-generation
compiler") built on top of the tiling strategy verified in tiling.py /
test_tiled_gemm.py.

    generate_gemm(GemmParams(M, N, K, ARRAY_SIZE, A_base, B_base, C_base))
        -> GemmProgram

The GemmProgram's `.runs` (List[tiling.TiledRun]) are directly executable
by the existing software simulator (tiling.execute_tiled_program /
sim.execute_microcode) -- this generator does not introduce a new program
representation, it just wraps the already-verified one with clean stage
boundaries, DRAM address bookkeeping, and file output.

======================================================================
Pipeline stages (deliberately kept as separate functions, each callable
and testable on its own)
======================================================================

  1. tile_matrices()        -- pure geometry: how M/K/N split into
                                ARRAY_SIZE-sized row/k/col tiles.
  2. compute_addresses()     -- DRAM byte addresses (row-major) for every
                                weight/activation/bias/store tile, given
                                the base addresses. See the AddressPlan
                                docstring for what these addresses mean
                                given the current hardware's DMA
                                limitations (Constraint #4 in tiling.py).
  3. schedule_instructions()  -- opcode sequence, accum_ctrl assignment,
                                run/bias boundaries: delegates to
                                tiling.build_tiled_gemm_runs(), which is
                                the already-verified scheduler.
  4. encode_instructions()    -- Instruction -> 32-bit word, via isa.py
                                (unchanged encoding/opcodes, as required).
  5. write_program()          -- .hex (one file per run) + .asm listing
                                + a CSR manifest (what the host must
                                program into weight_addr/src_addr/
                                bias_addr/dst_addr before each run).
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import List, Dict, Optional
import os

from scripts.opcode_generator.isa import Instruction
from scripts.opcode_generator.sim import AcceleratorConfig
from scripts.opcode_generator.tiling import (TiledRun, LoadMeta, StoreMeta, tiling_geometry,
                     build_tiled_gemm_runs, instruction_count)


# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------

@dataclass
class GemmParams:
    M: int
    N: int
    K: int
    array_size: int
    a_base_address: int
    b_base_address: int
    c_base_address: int
    bias_base_address: Optional[int] = None   # None -> all-zero bias, no LOAD_BIAS DRAM addr computed
    data_width: int = 8      # bits, INT8 activations/weights/output
    dma_width: Optional[int] = None   # bits; defaults to data_width*array_size
                                        # (the "one beat == one row" config
                                        # this whole model requires -- see
                                        # sim.py AcceleratorConfig)
    acc_width: int = 32      # bits, INT32 bias/accumulator elements

    def __post_init__(self):
        if self.dma_width is None:
            self.dma_width = self.data_width * self.array_size
        assert self.M > 0 and self.N > 0 and self.K > 0
        assert self.array_size > 0

    def accel_config(self) -> AcceleratorConfig:
        return AcceleratorConfig(array_size=self.array_size, data_width=self.data_width,
                                  dma_width=self.dma_width, acc_width=self.acc_width)


# ---------------------------------------------------------------------------
# Stage 1: matrix tiling
# ---------------------------------------------------------------------------

@dataclass
class TileGeometry:
    row_tiles: List[tuple]   # [(i, rows_in_tile), ...]
    k_tiles: List[tuple]     # [(kt, k_in_tile), ...]
    col_tiles: List[tuple]   # [(j, cols_in_tile), ...]


def tile_matrices(p: GemmParams) -> TileGeometry:
    """Stage 1. Pure geometry -- does not touch addresses or opcodes."""
    row_tiles, k_tiles, col_tiles = tiling_geometry(p.M, p.K, p.N, p.array_size)
    return TileGeometry(row_tiles=row_tiles, k_tiles=k_tiles, col_tiles=col_tiles)


# ---------------------------------------------------------------------------
# Stage 2: address calculation
# ---------------------------------------------------------------------------
#
# All three matrices are assumed row-major in DRAM, element size
# data_width/8 bytes for A/B (INT8) and acc_width/8 bytes for the bias
# vector (INT32), matching bram_act_buffer.sv/bram_weight_buffer.sv
# (INT8) and bram_bias_buffer.sv (INT32).
#
# IMPORTANT (carried over from tiling.py's Constraint #4): these are the
# addresses of each tile *within the original, un-repacked matrix*. The
# current DMA/control_unit addressing scheme (a single flat INCR burst
# per LOAD_*, no row stride) can only correctly pull a tile in one burst
# when the tile is already contiguous in DRAM -- true for the FIRST row
# of every tile (that address below IS where a real burst would start),
# but NOT for row 2..ARRAY_SIZE of a tile when the matrix is wider than
# ARRAY_SIZE, since those rows are not adjacent to row 1 in a row-major
# layout. This stage still computes and reports these addresses (they
# are exactly what a host-side repacking step -- or a future strided-DMA
# RTL change -- would need), but the *simulator* (tiling.execute_tiled_program)
# does not DMA byte-for-byte from a flat address space; it binds each
# tile's data directly, which is the "assume already repacked / already
# correctly staged" modeling choice documented in tiling.py.
# ---------------------------------------------------------------------------

@dataclass
class TileAddress:
    kind: str          # 'weight' | 'act_row' | 'bias' | 'store'
    indices: tuple
    byte_address: int
    row_stride_bytes: int
    note: str = ""


@dataclass
class AddressPlan:
    weight: Dict[tuple, TileAddress] = field(default_factory=dict)   # (kt,j) -> addr
    act: Dict[tuple, TileAddress] = field(default_factory=dict)      # (i,r,kt) -> addr
    bias: Dict[tuple, TileAddress] = field(default_factory=dict)     # (j,) -> addr
    store: Dict[tuple, TileAddress] = field(default_factory=dict)    # (i,j) -> addr


def compute_addresses(p: GemmParams, geo: TileGeometry) -> AddressPlan:
    """Stage 2."""
    P = p.array_size
    a_elem = p.data_width // 8
    acc_elem = p.acc_width // 8

    plan = AddressPlan()

    b_row_stride = p.N * a_elem
    for kt, _ in geo.k_tiles:
        for j, _ in geo.col_tiles:
            row0 = kt * P
            col0 = j * P
            addr = p.b_base_address + row0 * b_row_stride + col0 * a_elem
            plan.weight[(kt, j)] = TileAddress(
                'weight', (kt, j), addr, b_row_stride,
                note=f"B[{row0}:{row0+P}, {col0}:{col0+P}] (top-left corner of tile; "
                     f"rows below the first are NOT contiguous with it when N > ARRAY_SIZE "
                     f"-- see AddressPlan/Constraint #4 note above)"
            )

    a_row_stride = p.K * a_elem
    for i, _ in geo.row_tiles:
        for r in range(P):
            for kt, _ in geo.k_tiles:
                row = i * P + r
                col0 = kt * P
                addr = p.a_base_address + row * a_row_stride + col0 * a_elem
                plan.act[(i, r, kt)] = TileAddress(
                    'act_row', (i, r, kt), addr, a_row_stride,
                    note=f"A[{row}, {col0}:{col0+P}] (one row is always contiguous, "
                         f"regardless of K vs ARRAY_SIZE -- single-row bursts have no "
                         f"stride problem)"
                )

    if p.bias_base_address is not None:
        for j, _ in geo.col_tiles:
            addr = p.bias_base_address + (j * P) * acc_elem
            plan.bias[(j,)] = TileAddress('bias', (j,), addr, acc_elem,
                                            note=f"bias[{j*P}:{j*P+P}] (INT32 elements)")

    c_row_stride = p.N * a_elem
    for i, _ in geo.row_tiles:
        for j, _ in geo.col_tiles:
            row0 = i * P
            col0 = j * P
            addr = p.c_base_address + row0 * c_row_stride + col0 * a_elem
            plan.store[(i, j)] = TileAddress(
                'store', (i, j), addr, c_row_stride,
                note=f"C[{row0}:{row0+P}, {col0}:{col0+P}] (same non-contiguity caveat "
                     f"as weight tiles when N > ARRAY_SIZE)"
            )
    return plan


# ---------------------------------------------------------------------------
# Stage 3: instruction scheduling  (delegates to the verified tiling.py logic)
# ---------------------------------------------------------------------------

def schedule_instructions(p: GemmParams) -> List[TiledRun]:
    """Stage 3. Opcode sequence, accum_ctrl (ACC_INIT/ACC_ADD/ACC_LAST)
    assignment, and run/bias-reload boundaries. This is exactly
    tiling.build_tiled_gemm_runs(), kept as its own stage function here so
    the pipeline has one call per stage."""
    return build_tiled_gemm_runs(p.M, p.K, p.N, p.accel_config())


# ---------------------------------------------------------------------------
# Stage 4: instruction encoding (isa.py; unchanged 32-bit format/opcodes)
# ---------------------------------------------------------------------------

def encode_instructions(runs: List[TiledRun]) -> List[List[int]]:
    """Stage 4. One list of 32-bit words per run."""
    return [[ins.encode() for ins in run.instructions] for run in runs]


# ---------------------------------------------------------------------------
# Stage 5: output -- .hex instruction memory + human-readable .asm listing
# ---------------------------------------------------------------------------

def _csr_writes_for_run(run: TiledRun, plan: AddressPlan) -> List[str]:
    """What the host must program via AXI-lite before triggering this run
    (best-effort/documentary -- see the Constraint #4 caveat above)."""
    lines = []
    # weight_addr / src_addr / bias_addr are single base registers reused
    # by every LOAD_WGT/LOAD_ACT/LOAD_BIAS in the run via `addr` (a small
    # beat offset) -- so, consistent with tiling.py's "each tile arrives
    # via its own freshly-bound, already-contiguous source" model, the
    # real host driver reprograms the relevant base register immediately
    # before each individual LOAD_* instruction, not once per run. We list
    # the full per-instruction address trace here rather than pretend a
    # single static base value covers the whole run.
    for idx, ins in enumerate(run.instructions):
        meta = run.load_meta.get(idx)
        if meta is None:
            continue
        if meta.kind == 'weight':
            ta = plan.weight[meta.indices]
            lines.append(f"  before instr {idx:04d} (LOAD_WGT): weight_addr <= 0x{ta.byte_address:08x}   ; {ta.note}")
        elif meta.kind == 'act':
            ta = plan.act[meta.indices]
            lines.append(f"  before instr {idx:04d} (LOAD_ACT): src_addr    <= 0x{ta.byte_address:08x}   ; {ta.note}")
        elif meta.kind == 'bias':
            ta = plan.bias.get(meta.indices)
            if ta is not None:
                lines.append(f"  before instr {idx:04d} (LOAD_BIAS): bias_addr  <= 0x{ta.byte_address:08x}   ; {ta.note}")
            else:
                lines.append(f"  before instr {idx:04d} (LOAD_BIAS): bias_addr  <= (unset; bias_base_address not given, all-zero bias assumed)")
    for idx, ins in enumerate(run.instructions):
        sm = run.store_meta.get(idx)
        if sm is None:
            continue
        ta = plan.store[(sm.i, sm.j)]
        lines.append(f"  before instr {idx:04d} (STORE):    dst_addr    <= 0x{ta.byte_address:08x}   ; {ta.note}")
    return lines


def write_program(runs: List[TiledRun], plan: AddressPlan, out_dir: str, prefix: str = "gemm") -> Dict[str, str]:
    """Stage 5. Writes, per run j:
         {prefix}_run{j}.hex   -- one 32-bit hex word per line (instruction memory image)
         {prefix}_run{j}.asm   -- human-readable "addr: MNEMONIC ..." listing
       plus one combined:
         {prefix}.manifest.txt -- run count, CSR programming sequence, sizes
    Returns a dict of the file paths written.
    """
    os.makedirs(out_dir, exist_ok=True)
    written = {}

    manifest_path = os.path.join(out_dir, f"{prefix}.manifest.txt")
    with open(manifest_path, "w") as mf:
        mf.write(f"GEMM microprogram manifest ({len(runs)} run(s), "
                  f"{instruction_count(runs)} instructions total)\n")
        mf.write("=" * 78 + "\n")
        for run in runs:
            mf.write(f"\nrun {run.j_tile} (column tile j={run.j_tile}): "
                      f"{len(run.instructions)} instructions\n")
            mf.write("CSR programming sequence for this run (host-side, before each\n"
                      "listed instruction executes -- see gemm_compiler.py Stage 2/5 notes\n"
                      "on current hardware's flat-burst DMA limitation):\n")
            for line in _csr_writes_for_run(run, plan):
                mf.write(line + "\n")
    written['manifest'] = manifest_path

    for run in runs:
        hex_path = os.path.join(out_dir, f"{prefix}_run{run.j_tile}.hex")
        with open(hex_path, "w") as hf:
            for ins in run.instructions:
                hf.write(f"{ins.encode():08x}\n")
        written[f'hex_run{run.j_tile}'] = hex_path

        asm_path = os.path.join(out_dir, f"{prefix}_run{run.j_tile}.asm")
        with open(asm_path, "w") as af:
            af.write(f"; GEMM microprogram, run {run.j_tile} (column tile j={run.j_tile})\n")
            af.write(f"; {len(run.instructions)} instructions\n\n")
            for idx, ins in enumerate(run.instructions):
                comment = ""
                meta = run.load_meta.get(idx)
                if meta is not None:
                    comment = f"  ; {meta.kind} tile {meta.indices}"
                sm = run.store_meta.get(idx)
                if sm is not None:
                    comment = f"  ; store tile (i={sm.i},j={sm.j}) rows={sm.rows} cols={sm.cols}"
                af.write(f"{idx:04d}: {str(ins):<60s}{comment}\n")
        written[f'asm_run{run.j_tile}'] = asm_path

    return written


# ---------------------------------------------------------------------------
# Top-level convenience
# ---------------------------------------------------------------------------

@dataclass
class GemmProgram:
    params: GemmParams
    geometry: TileGeometry
    address_plan: AddressPlan
    runs: List[TiledRun]
    encoded: List[List[int]]

    def to_files(self, out_dir: str, prefix: str = "gemm") -> Dict[str, str]:
        return write_program(self.runs, self.address_plan, out_dir, prefix)

    def total_instructions(self) -> int:
        return instruction_count(self.runs)


def generate_gemm(p: GemmParams) -> GemmProgram:
    """Run all five stages and return the complete, ready-to-execute (or
    ready-to-emit) GEMM microprogram."""
    geo = tile_matrices(p)
    plan = compute_addresses(p, geo)
    runs = schedule_instructions(p)
    encoded = encode_instructions(runs)
    return GemmProgram(params=p, geometry=geo, address_plan=plan, runs=runs, encoded=encoded)
