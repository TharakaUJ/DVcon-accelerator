"""
test_gemm_compiler.py -- proves, for the reusable generator:

    NumPy A @ B  ==  execute_microcode(generate_gemm(...))

and that the generator's file output (Stage 5: .hex + .asm + manifest) is
well-formed and internally consistent with the in-memory program.

Run:  python3 test_gemm_compiler.py
"""

import os
import shutil
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # opcode_generator/ (so `python3 tests/thisfile.py` works standalone; pytest uses conftest.py)
import numpy as np

from scripts.opcode_generator.sim import reference_gemm
from scripts.opcode_generator.tiling import execute_tiled_program
from scripts.opcode_generator.gemm_compiler import GemmParams, generate_gemm


OUT_DIR = "/tmp/gemm_compiler_out"


def check(name: str, M: int, N: int, K: int, array_size: int, seed: int,
          use_bias: bool = False, emit_files: bool = False) -> bool:
    rng = np.random.default_rng(seed)
    A = rng.integers(-3, 4, size=(M, K)).astype(np.int64)
    B = rng.integers(-3, 4, size=(K, N)).astype(np.int64)
    bias = rng.integers(-4, 5, size=(N,)).astype(np.int64) if use_bias else None

    params = GemmParams(M=M, N=N, K=K, array_size=array_size,
                         a_base_address=0x1000_0000,
                         b_base_address=0x2000_0000,
                         c_base_address=0x3000_0000,
                         bias_base_address=0x4000_0000 if use_bias else None)
    program = generate_gemm(params)

    ref = reference_gemm(A, B)
    if bias is not None:
        ref = ref + bias[None, :]

    got = execute_tiled_program(program.runs, A, B, params.accel_config(), bias=bias)
    ok = np.array_equal(ref, got)

    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {name}: M={M},N={N},K={K},P={array_size},bias={use_bias} "
          f"({len(program.runs)} run(s), {program.total_instructions()} instrs)")
    if not ok:
        print("  max abs diff:", np.abs(ref - got).max())

    if emit_files:
        files = program.to_files(OUT_DIR, prefix=f"{name.replace(' ', '_')}")
        for k, v in files.items():
            n_lines = sum(1 for _ in open(v))
            print(f"    wrote {k}: {v} ({n_lines} lines)")
        # Stage-5 output sanity: hex word count must equal instruction count,
        # and the .asm listing must have exactly one instruction line per
        # instruction (plus the 3-line header).
        for run in program.runs:
            hex_path = files[f'hex_run{run.j_tile}']
            asm_path = files[f'asm_run{run.j_tile}']
            with open(hex_path) as hf:
                hex_lines = [l.strip() for l in hf if l.strip()]
            assert len(hex_lines) == len(run.instructions), \
                f"hex line count mismatch for run {run.j_tile}"
            for w, ins in zip(hex_lines, run.instructions):
                assert int(w, 16) == ins.encode(), "hex word does not match instruction encoding"
            with open(asm_path) as af:
                asm_lines = af.readlines()
            asm_instr_lines = [l for l in asm_lines if l[:4].strip().isdigit()]
            assert len(asm_instr_lines) == len(run.instructions), \
                f"asm line count mismatch for run {run.j_tile}"

    return ok


def main():
    if os.path.isdir(OUT_DIR):
        shutil.rmtree(OUT_DIR)

    all_ok = True

    print("=" * 78)
    print("Stage-5 output check (emits .hex/.asm/manifest and validates them)")
    print("=" * 78)
    all_ok &= check("emitted 16x32x48", M=32, N=32, K=48, array_size=16, seed=1, emit_files=True)
    all_ok &= check("emitted 8x20x20 bias", M=20, N=20, K=8, array_size=8, seed=2, use_bias=True, emit_files=True)

    print("\n" + "=" * 78)
    print("Correctness sweep: NumPy A@B  vs  execute_microcode(generate_gemm(...))")
    print("=" * 78)
    cases = [
        ("divisible small",        8,  8,  8, 8),
        ("divisible multi-tile",  24, 16, 32, 8),
        ("not divisible",         13, 11, 17, 8),
        ("M only larger",         37,  6,  6, 8),
        ("N only larger",          6, 37,  6, 8),
        ("K only larger",          6,  6, 37, 8),
        ("array_size=4 small",     6,  6,  6, 4),
        ("array_size=16 primary", 32, 32, 48, 16),
        ("M=1 edge",                1, 10, 12, 8),
        ("N=1 edge",               10,  1, 12, 8),
        ("K=1 edge",               10, 12,  1, 8),
        ("all=1 edge",              1,  1,  1, 8),
    ]
    for i, (name, M, N, K, P) in enumerate(cases):
        all_ok &= check(name, M, N, K, P, seed=10 + i, use_bias=(i % 3 == 0))

    print("\n" + "=" * 78)
    print("Randomized sweep")
    print("=" * 78)
    rng = np.random.default_rng(123)
    n_random = 20
    passed = 0
    for t in range(n_random):
        P = int(rng.choice([4, 8]))
        M = int(rng.integers(1, 3 * P + 1))
        N = int(rng.integers(1, 3 * P + 1))
        K = int(rng.integers(1, 3 * P + 1))
        ub = bool(rng.integers(0, 2))
        ok = check(f"random[{t:02d}]", M, N, K, P, seed=500 + t, use_bias=ub)
        passed += int(ok)
        all_ok &= ok
    print(f"\nrandomized: {passed}/{n_random} passed")

    print("\n" + "=" * 78)
    print("ALL CHECKS PASSED" if all_ok else "SOME CHECKS FAILED")
    print("=" * 78)
    return 0 if all_ok else 1


def test_all_checks_pass():
    """pytest entry point: runs every check in main()."""
    assert main() == 0


if __name__ == "__main__":
    raise SystemExit(main())
