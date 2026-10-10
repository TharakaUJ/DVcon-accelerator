"""
test_rtl_consistency.py -- guards against the generator drifting from the RTL:

  * isa.Opcode / isa.AccumCtrl match control_unit.sv's opcode_t / accum_ctrl_t
  * the generated 2-row single-tile GEMM program is bit-identical to the
    hand-assembled demo program in instructions_fifo.sv's ROM
"""

import os
import re

from scripts.opcode_generator.isa import AccumCtrl, Opcode
from scripts.opcode_generator.sim import AcceleratorConfig, build_single_tile_gemm_program

RTL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "rtl")


def _read(name):
    with open(os.path.join(RTL, name)) as f:
        return f.read()


def _enum_body(src, type_name):
    m = re.search(r"typedef enum logic \[\d+:0\] \{(.*?)\}\s*" + type_name + ";", src, re.S)
    assert m, f"{type_name} not found"
    return re.sub(r"//[^\n]*", "", m.group(1))


def test_opcodes_match_control_unit():
    names = [n.strip() for n in _enum_body(_read("control_unit.sv"), "opcode_t").split(",") if n.strip()]
    assert names == ["OP_" + op.name for op in sorted(Opcode, key=int)]


def test_accum_ctrl_matches_control_unit():
    body = _enum_body(_read("control_unit.sv"), "accum_ctrl_t")
    values = {name: int(val) for name, val in re.findall(r"ACC_(\w+)\s*=\s*2'd(\d)", body)}
    assert values == {a.name: int(a) for a in AccumCtrl}


def test_generated_program_matches_rom_demo():
    rom = [int(w, 16) for w in re.findall(r"rom\[\s*\d+\]\s*=\s*32'h([0-9a-fA-F]+)", _read("instructions_fifo.sv"))]
    program = [instr.encode() for instr in build_single_tile_gemm_program(2, AcceleratorConfig())]
    assert program == rom[:len(program)]
