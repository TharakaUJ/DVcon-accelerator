"""
test_tiled_gemm.py -- proves, reproducibly:

    numpy GEMM (A @ B)  ==  generated tiled microcode  ==  software microcode simulator

for the tiling strategy documented in tiling.py, on the current
accelerator's semantics (single-tile primitives + the scoreboard
constraints already verified in sim.py / test_gemm_microcode.py).

Run:  python3 test_tiled_gemm.py
"""

import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # opcode_generator/ (so `python3 tests/thisfile.py` works standalone; pytest uses conftest.py)
import numpy as np
from scripts.opcode_generator.sim import AcceleratorConfig, reference_gemm
from scripts.opcode_generator.tiling import build_tiled_gemm_runs, execute_tiled_program, tiling_geometry, instruction_count


def check(name: str, M: int, K: int, N: int, cfg: AcceleratorConfig, seed: int,
          use_bias: bool = False) -> bool:
    rng = np.random.default_rng(seed)
    A = rng.integers(-3, 4, size=(M, K)).astype(np.int64)
    B = rng.integers(-3, 4, size=(K, N)).astype(np.int64)
    bias = rng.integers(-4, 5, size=(N,)).astype(np.int64) if use_bias else None

    ref = reference_gemm(A, B)
    if bias is not None:
        ref = ref + bias[None, :]

    runs = build_tiled_gemm_runs(M, K, N, cfg)
    got = execute_tiled_program(runs, A, B, cfg, bias=bias)

    ok = np.array_equal(ref, got)
    row_tiles, k_tiles, col_tiles = tiling_geometry(M, K, N, cfg.array_size)
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: M={M},K={K},N={N} "
          f"(tiles: {len(row_tiles)}x{len(k_tiles)}x{len(col_tiles)} row/k/col, "
          f"{len(runs)} run(s), {instruction_count(runs)} instrs)")
    if not ok:
        print("  max abs diff:", np.abs(ref - got).max())
        bad = np.argwhere(ref != got)[:5]
        for (rr, cc) in bad:
            print(f"    C[{rr},{cc}]: ref={ref[rr,cc]} got={got[rr,cc]}")
    return ok


def main():
    all_ok = True
    cfg = AcceleratorConfig(array_size=16, data_width=8, dma_width=128, acc_width=32)
    # NOTE: dma_width bumped to 128 so ELEMENTS_PER_BEAT(=128/8=16) == ARRAY_SIZE(16),
    # satisfying AcceleratorConfig's "one beat == one row" requirement at P=16
    # (see sim.py limitation #4). This is a different DMA_WIDTH than the P=8
    # reference config verified in test_gemm_microcode.py, but the same
    # underlying assumption -- just re-derived for the requested ARRAY_SIZE=16.

    print("=" * 78)
    print("PRIMARY EXAMPLE:  ARRAY_SIZE=16, M=32, N=32, K=48")
    print("(all three dims exercise multiple tiles: 2 row tiles x 3 k-tiles x 2 col tiles)")
    print("=" * 78)
    ok = check("primary example", M=32, K=48, N=32, cfg=cfg, seed=42)
    all_ok &= ok

    # Dump the generated microprogram for inspection (first run only, since
    # there are 2 column-tile runs for N=32/P=16 -- see tiling.py Constraint #3).
    runs = build_tiled_gemm_runs(32, 48, 32, cfg)
    print(f"\nGenerated {len(runs)} run(s) totalling {instruction_count(runs)} instructions.")
    print(f"Run 0 (column tile j=0) has {len(runs[0].instructions)} instructions; first 12:")
    for ins in runs[0].instructions[:12]:
        print("   ", ins)
    print("   ...")

    # -----------------------------------------------------------------
    print("\n" + "=" * 78)
    print("SIZE SWEEP")
    print("=" * 78)
    cfg8 = AcceleratorConfig(array_size=8, data_width=8, dma_width=64, acc_width=32)

    cases = [
        # (name, M, K, N, cfg)
        ("exactly divisible, single tile",           8,  8,  8,  cfg8),
        ("exactly divisible, multi tile (M=K=N=2P)", 16, 16, 16, cfg8),
        ("not divisible in all dims",                10, 13,  9,  cfg8),
        ("larger in M only",                         20,  8,  8,  cfg8),
        ("larger in N only",                          8,  8, 20,  cfg8),
        ("larger in K only",                           8, 20,  8,  cfg8),
        ("larger in M and K",                         17, 25,  6,  cfg8),
        ("larger in all dims, non-divisible",         21, 19, 23,  cfg8),
        ("M=1 (single row) tiled K",                   1, 20,  8,  cfg8),
        ("N=1 (single column) tiled K",                8, 20,  1,  cfg8),
        ("K exactly one tile boundary short",          8, 15,  8,  cfg8),
        ("K exactly one tile boundary over",           8, 17,  8,  cfg8),
    ]
    for i, (name, M, K, N, c) in enumerate(cases):
        all_ok &= check(name, M, K, N, c, seed=100 + i)

    # -----------------------------------------------------------------
    print("\n" + "=" * 78)
    print("BIAS ACROSS MULTIPLE COLUMN TILES (exercises Constraint #3: one")
    print("LOAD_BIAS per run, one run per column tile, fresh accelerator state")
    print("per run)")
    print("=" * 78)
    all_ok &= check("multi-column-tile with distinct bias per tile", 10, 12, 20, cfg8, seed=999, use_bias=True)

    # -----------------------------------------------------------------
    print("\n" + "=" * 78)
    print("RANDOMIZED SWEEP")
    print("=" * 78)
    rng = np.random.default_rng(7)
    n_random = 25
    passed = 0
    for t in range(n_random):
        P = int(rng.choice([4, 8]))
        c = AcceleratorConfig(array_size=P, data_width=8, dma_width=8 * P, acc_width=32)
        M = int(rng.integers(1, 3 * P + 1))
        K = int(rng.integers(1, 3 * P + 1))
        N = int(rng.integers(1, 3 * P + 1))
        use_bias = bool(rng.integers(0, 2))
        ok = check(f"random[{t:02d}] P={P}", M, K, N, c, seed=2000 + t, use_bias=use_bias)
        passed += int(ok)
        all_ok &= ok
    print(f"\nrandomized: {passed}/{n_random} passed")

    # -----------------------------------------------------------------
    print("\n" + "=" * 78)
    if all_ok:
        print("ALL CHECKS PASSED")
        print("numpy GEMM == generated tiled microcode == software microcode simulator")
    else:
        print("SOME CHECKS FAILED -- see FAIL lines above")
    print("=" * 78)
    return 0 if all_ok else 1


def test_all_checks_pass():
    """pytest entry point: runs every check in main()."""
    assert main() == 0


if __name__ == "__main__":
    raise SystemExit(main())
