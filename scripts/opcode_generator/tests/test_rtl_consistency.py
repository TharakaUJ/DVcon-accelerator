"""
test_rtl_consistency.py -- guards against the generator drifting from the RTL:

  * isa.Opcode / isa.AccumCtrl match control_unit.sv's opcode_t / accum_ctrl_t
  * the generated 2-row single-tile GEMM program is bit-identical to the
    program tb/tb_gemm_program_load.sv loads into instruction memory and
    checks end to end in RTL simulation
  * SET_BASE encodes like the SET_BASE words in that testbench
"""

import os
import re

from scripts.opcode_generator.isa import AccumCtrl, Base, Opcode, SET_BASE, set_base_offset
from scripts.opcode_generator.sim import AcceleratorConfig, build_single_tile_gemm_program

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..")


def _read(name):
    with open(os.path.join(ROOT, name)) as f:
        return f.read()


def _tb_words(array_name):
    src = _read("tb/tb_gemm_program_load.sv")
    return [int(w.replace("_", ""), 16)
            for w in re.findall(array_name + r"\[\s*\d+\]\s*=\s*32'h([0-9a-fA-F_]+)", src)]


def _enum_body(src, type_name):
    m = re.search(r"typedef enum logic \[\d+:0\] \{(.*?)\}\s*" + type_name + ";", src, re.S)
    assert m, f"{type_name} not found"
    return re.sub(r"//[^\n]*", "", m.group(1))


def test_opcodes_match_control_unit():
    names = [n.strip() for n in _enum_body(_read("rtl/control_unit.sv"), "opcode_t").split(",") if n.strip()]
    assert names == ["OP_" + op.name for op in sorted(Opcode, key=int)]


def test_accum_ctrl_matches_control_unit():
    body = _enum_body(_read("rtl/control_unit.sv"), "accum_ctrl_t")
    values = {name: int(val) for name, val in re.findall(r"ACC_(\w+)\s*=\s*2'd(\d)", body)}
    assert values == {a.name: int(a) for a in AccumCtrl}


def test_generated_program_matches_rtl_testbench():
    program = [instr.encode() for instr in build_single_tile_gemm_program(2, AcceleratorConfig())]
    assert program == _tb_words("prog_words")


def test_set_base_encoding_matches_rtl_testbench():
    words = _tb_words("prog2_words")
    assert words[0] == SET_BASE(Base.ACT, 0x80).encode()
    assert words[1] == SET_BASE(Base.OUT, 0x100).encode()
    for beats in (0, 1, 0x3F, 0x40, 0x1234, 0xABCDEF, (1 << 24) - 1):
        assert set_base_offset(SET_BASE(Base.BIAS, beats)) == beats


def test_set_base_selectors_match_control_unit():
    values = {n: int(v) for n, v in re.findall(r"localparam int BASE_(\w+)\s*=\s*(\d+);", _read("rtl/control_unit.sv"))}
    assert values == {b.name: int(b) for b in Base}
