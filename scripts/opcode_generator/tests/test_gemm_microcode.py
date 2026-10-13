"""
test_gemm_microcode.py -- proves, reproducibly:

        A @ B == execute_microcode(program, A, B)

for the single-tile GEMM programming model established from
instructions_fifo.sv's reference ROM, using the software model in sim.py
(no RTL simulation involved).

Run:  python3 test_gemm_microcode.py
"""

import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # opcode_generator/ (so `python3 tests/thisfile.py` works standalone; pytest uses conftest.py)
import numpy as np
from scripts.opcode_generator.isa import Instruction, MATMUL, VECTOR, AccumCtrl
from scripts.opcode_generator.sim import (AcceleratorConfig, Accelerator, ActType,
                  reference_gemm, build_single_tile_gemm_program, execute_microcode)


def check(name: str, A: np.ndarray, B: np.ndarray, cfg: AcceleratorConfig,
          bias: np.ndarray = None) -> bool:
    M = A.shape[0]
    program = build_single_tile_gemm_program(M, cfg)
    ref = reference_gemm(A, B)
    if bias is not None:
        ref = ref + bias.astype(np.int64)[None, :]
    got = execute_microcode(program, A, B, cfg=cfg, bias=bias)
    ok = np.array_equal(ref, got)
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {name}: A{A.shape} @ B{B.shape}"
          + (f" + bias{bias.shape}" if bias is not None else ""))
    if not ok:
        print("  reference:\n", ref)
        print("  simulator:\n", got)
        print("  diff:\n", ref - got)
    return ok


def main():
    all_ok = True
    cfg = AcceleratorConfig(array_size=8, data_width=8, dma_width=64, acc_width=32)

    # -----------------------------------------------------------------
    # 0. Encoding fidelity: our program-builder must reproduce exactly
    #    the ROM instructions_fifo.sv hand-assembled for its 2x2 example.
    # -----------------------------------------------------------------
    print("=== 0. Encoding fidelity vs instructions_fifo.sv ROM ===")
    A2 = np.array([[1, 2], [3, 4]], dtype=np.int64)
    B2 = np.array([[5, 6], [7, 8]], dtype=np.int64)
    prog2 = build_single_tile_gemm_program(M=2, cfg=cfg)
    rom_ref = [0x00000000, 0x10000700, 0x20000100, 0x30000300, 0x70000000,
               0x40000000, 0x50000000, 0x40010000, 0x50010000, 0x60000100, 0x80000000]
    built_hex = [ins.encode() for ins in prog2]
    enc_ok = built_hex == rom_ref
    print("  " + ("PASS" if enc_ok else "FAIL") + f": generated program == reference ROM ({len(rom_ref)} words)")
    if not enc_ok:
        for i, (r, b) in enumerate(zip(rom_ref, built_hex)):
            if r != b:
                print(f"    rom[{i}] ref=0x{r:08x} got=0x{b:08x}")
    all_ok &= enc_ok

    # -----------------------------------------------------------------
    # 1. Deterministic small matrices (the worked example from
    #    instructions_fifo.sv: C = [[19,22],[43,50]])
    # -----------------------------------------------------------------
    print("\n=== 1. Deterministic tests ===")
    all_ok &= check("2x2 worked example", A2, B2, cfg)

    A3 = np.array([[1, 0, -1], [2, 1, 0], [0, -2, 3], [1, 1, 1]], dtype=np.int64)
    B3 = np.array([[1, 2, -1, 0], [0, 1, 1, 1], [2, -1, 0, 1]], dtype=np.int64)
    all_ok &= check("4x3 @ 3x4, signed entries", A3, B3, cfg)

    A4 = np.zeros((3, 3), dtype=np.int64)
    B4 = np.eye(3, dtype=np.int64) * 2
    A4[0] = [1, 2, 3]
    A4[1] = [-1, -2, -3]
    A4[2] = [4, -4, 0]
    all_ok &= check("identity-like weight tile", A4, B4, cfg)

    bias3 = np.array([10, -5, 0, 3], dtype=np.int64)
    all_ok &= check("4x3 @ 3x4 with nonzero bias", A3, B3, cfg, bias=bias3)

    # full-size (M=K=N=ARRAY_SIZE) tile, no padding at all
    rng_det = np.random.default_rng(0)
    A_full = rng_det.integers(-3, 4, size=(8, 8)).astype(np.int64)
    B_full = rng_det.integers(-3, 4, size=(8, 8)).astype(np.int64)
    all_ok &= check("full 8x8 tile (no zero-padding)", A_full, B_full, cfg)

    # -----------------------------------------------------------------
    # 2. Randomized tests. Values are kept small enough that A@B (+bias)
    #    cannot saturate the INT8 output clamp with the default identity
    #    vec-ctrl (mult=1, shift=0) -- otherwise "A @ B == execute_
    #    microcode(...)" would not hold exactly, since real hardware
    #    quantizes/clamps to INT8 in OP_VECTOR. This mirrors running the
    #    accelerator with small activations/weights, a realistic use case
    #    for verifying microcode logic in isolation from quantization.
    # -----------------------------------------------------------------
    print("\n=== 2. Randomized tests (small-magnitude, no INT8 saturation) ===")
    n_random = 40
    rng = np.random.default_rng(1234)
    random_pass = 0
    for t in range(n_random):
        M = int(rng.integers(1, 9))
        K = int(rng.integers(1, 9))
        Nc = int(rng.integers(1, 9))
        # keep |sum_k a*b| < 128 with high probability: values in [-3,3], K<=8
        A = rng.integers(-3, 4, size=(M, K)).astype(np.int64)
        B = rng.integers(-3, 4, size=(K, Nc)).astype(np.int64)
        use_bias = bool(rng.integers(0, 2))
        bias = rng.integers(-5, 6, size=(Nc,)).astype(np.int64) if use_bias else None
        ok = check(f"random[{t:02d}] M={M},K={K},N={Nc},bias={use_bias}", A, B, cfg, bias=bias)
        random_pass += int(ok)
        all_ok &= ok
    print(f"\nrandomized: {random_pass}/{n_random} passed")

    # -----------------------------------------------------------------
    # 3. Scheduling-precondition sanity check: a program that issues a
    #    second MATMUL before its row's VECTOR has drained the (single-
    #    banked) accumulation buffer must be rejected by this model, the
    #    same way control_unit.sv's can_issue_matmul() would block it on
    #    real hardware (accum_buf_state stuck FILLING/READY, not EMPTY).
    #    This is exactly why instructions_fifo.sv documents alternating
    #    MATMUL/VECTOR pairs instead of batching all MATMULs first.
    # -----------------------------------------------------------------
    print("\n=== 3. Negative test: batched MATMULs must be rejected ===")
    from scripts.opcode_generator.sim import SchedulingError
    bad_program = [
        Instruction.decode(0x00000000),   # NOP
        Instruction.decode(0x10000700),   # LOAD_WGT
        Instruction.decode(0x20000100),   # LOAD_ACT (2 rows)
        Instruction.decode(0x30000300),   # LOAD_BIAS
        Instruction.decode(0x70000000),   # SWAP_WGT
        MATMUL(src=0, addr=0),
        MATMUL(src=0, addr=1),            # <-- illegal: accum buffer still FILLING... actually READY but not EMPTY
        VECTOR(dst=0, addr=0),
        VECTOR(dst=0, addr=1),
    ]
    try:
        execute_microcode(bad_program, A2, B2, cfg=cfg)
        print("  FAIL: expected SchedulingError, none was raised")
        all_ok = False
    except SchedulingError as e:
        print(f"  PASS: correctly rejected with: {e}")

    # -----------------------------------------------------------------
    # 4. ACC_INIT/ACC_ADD/ACC_LAST reduction-group behavior (exercised
    #    directly against the accum buffer, independent of the
    #    single-tile program builder above, since a single tile never
    #    needs a multi-tile reduction group).
    # -----------------------------------------------------------------
    print("\n=== 4. ACC_INIT/ACC_ADD/ACC_LAST accumulation semantics ===")
    accel = Accelerator(cfg)
    N = cfg.array_size
    w1 = np.zeros((N, N), dtype=np.int64); w1[:2, :2] = [[1, 0], [0, 1]]
    w2 = np.zeros((N, N), dtype=np.int64); w2[:2, :2] = [[2, 0], [0, 2]]
    act = np.zeros((N, N), dtype=np.int64); act[0, :2] = [3, 4]
    bias0 = np.zeros(N, dtype=np.int64)

    accel.load_sources(w1, act, bias0)
    accel.step(Instruction.decode(0x10000700))  # LOAD_WGT full tile
    accel.step(Instruction.decode(0x20000000))  # LOAD_ACT 1 row (len=0 -> beats=1)
    accel.step(Instruction.decode(0x30000300))  # LOAD_BIAS
    accel.step(Instruction.decode(0x70000000))  # SWAP_WGT (parks w1)
    accel.step(MATMUL(src=0, addr=0, accum_ctrl=AccumCtrl.INIT))   # accum row0 = act @ w1
    expect_after_init = (act[0].astype(np.int64) @ w1.astype(np.int64))
    init_ok = np.array_equal(accel.accum_data[0], expect_after_init)
    print(f"  {'PASS' if init_ok else 'FAIL'}: ACC_INIT wrote accum row0 = {accel.accum_data[0][:2]} (expected {expect_after_init[:2]})")
    all_ok &= init_ok
    assert accel.accum_buf_state.name == "FILLING"

    # reload act bank (row consumed) and weight staging for the second tile
    accel.act_buf_state[0] = accel.act_buf_state[0]  # (still consumed/EMPTY as expected)
    accel._dram_weight = w2
    accel.step(Instruction.decode(0x10000700))  # LOAD_WGT tile 2 (staging was freed by SWAP_WGT)
    accel.step(Instruction.decode(0x20000000))  # LOAD_ACT row again (bank was freed after MATMUL consumed it)
    accel.step(Instruction.decode(0x70000000))  # SWAP_WGT (parks w2)
    accel.step(MATMUL(src=0, addr=0, accum_ctrl=AccumCtrl.LAST))   # accum row0 += act @ w2, mark READY
    expect_after_last = expect_after_init + (act[0].astype(np.int64) @ w2.astype(np.int64))
    last_ok = (np.array_equal(accel.accum_data[0], expect_after_last)
               and accel.accum_buf_state.name == "READY")
    print(f"  {'PASS' if last_ok else 'FAIL'}: ACC_LAST accum row0 = {accel.accum_data[0][:2]} (expected {expect_after_last[:2]}), state={accel.accum_buf_state.name}")
    all_ok &= last_ok

    # -----------------------------------------------------------------
    print("\n" + "=" * 70)
    if all_ok:
        print("ALL CHECKS PASSED  --  A @ B == execute_microcode(program, A, B)")
    else:
        print("SOME CHECKS FAILED -- see FAIL lines above")
    print("=" * 70)
    return 0 if all_ok else 1


def test_all_checks_pass():
    """pytest entry point: runs every check in main()."""
    assert main() == 0


if __name__ == "__main__":
    raise SystemExit(main())
