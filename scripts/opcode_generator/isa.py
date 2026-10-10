"""
isa.py -- Instruction encoding for the accelerator's microcode, matching
control_unit.sv's `instruction_t` bit layout exactly.

Source of truth (control_unit.sv, ~line 203-217):

    typedef struct packed {
        opcode_t       opcode;      // [31:28]  4 bits
        logic [1:0]    src;         // [27:26]  2 bits
        logic [1:0]    dst;         // [25:24]  2 bits
        logic [7:0]    addr;        // [23:16]  8 bits
        logic [7:0]    length;      // [15:8]   8 bits
        accum_ctrl_t   accum_ctrl;  // [7:6]    2 bits
        logic [5:0]    reserved;    // [5:0]    6 bits
    } instruction_t;

opcode_t (control_unit.sv):
    NOP=0 LOAD_WGT=1 LOAD_ACT=2 LOAD_BIAS=3 MATMUL=4 VECTOR=5 STORE=6
    SWAP_WGT=7 END=8 SET_BASE=9

accum_ctrl_t (control_unit.sv ~line 176-181):
    NONE=0 INIT=1 ADD=2 LAST=3

Field *meaning* is opcode-dependent (confirmed against control_unit.sv's
dispatch block, ~line 641-780):

  LOAD_WGT : dst   unused (weight buffer is single-banked; wt_wr_addr does
                    not depend on dst anywhere in control_unit.sv)
             addr  DMA-beat index into the weight buffer (chunk offset)
             length beats-1 (AxLEN convention); real beat count = length+1
  LOAD_ACT : dst   which act bank (0/1) to fill
             addr  DMA-beat index into that bank
             length beats-1
  LOAD_BIAS: src/dst unused (bias buffer is single-banked & persistent)
             addr  DMA-beat index (chunk offset) into the bias buffer
             length beats-1
  MATMUL   : src   which act bank to read the activation row from
             dst   NOT consumed anywhere in control_unit.sv's OP_MATMUL
                   dispatch or scoreboard-update blocks -- FLAG: appears to
                   be a genuinely unused/reserved field for this opcode.
             addr  activation-row index within the bank, AND (per the
                   "one accum row per MATMUL" assumption confirmed against
                   systolic_array.sv) the accumulation-buffer row written
             accum_ctrl  NONE/INIT/ADD/LAST -- controls accum_wr_init and
                   the accum_buf_state transition at array completion
  VECTOR   : dst   which out_buf bank (0/1) to write
             src   NOT consumed anywhere in control_unit.sv's OP_VECTOR
                   dispatch -- FLAG: same as MATMUL's dst, appears unused.
             addr  accum-buffer row to read AND out_buf row to write
                   (same "addr" latched once, reused for both -- confirmed
                   via mm_accum_addr/vec_out_addr latch code)
  STORE    : src   which out_buf bank to drain
             addr  DMA-beat index (out_buf beat/row) to start draining from
             length beats-1
  SWAP_WGT : no fields consumed
  END      : no fields consumed
  NOP      : no fields consumed
  SET_BASE : dst   which DMA base offset to set (Base: WGT/ACT/BIAS/OUT)
             bits [23:0] (addr|length|accum_ctrl|reserved) = offset in DMA
                   beats; every later LOAD_*/STORE on that base addresses
                   CSR_base + offset*beat_bytes + (addr << beat shift).
                   Offsets reset to 0 at START.

FLAG (unclear / worth confirming against RTL sim, not assumed further
here): MATMUL.dst and VECTOR.src are present in the encoding and set to 0
in the reference program, but nothing in control_unit.sv reads them for
those opcodes. They are preserved in the encoding below for fidelity, but
this model does not attach any behavior to them for those two opcodes.
"""

from __future__ import annotations
from dataclasses import dataclass
from enum import IntEnum


class Opcode(IntEnum):
    NOP = 0
    LOAD_WGT = 1
    LOAD_ACT = 2
    LOAD_BIAS = 3
    MATMUL = 4
    VECTOR = 5
    STORE = 6
    SWAP_WGT = 7
    END = 8
    SET_BASE = 9


class Base(IntEnum):
    """SET_BASE dst: which DMA base offset (control_unit.sv BASE_*)."""
    WGT = 0
    ACT = 1
    BIAS = 2
    OUT = 3


SET_BASE_MAX_BEATS = (1 << 24) - 1


class AccumCtrl(IntEnum):
    NONE = 0
    INIT = 1
    ADD = 2
    LAST = 3


@dataclass(frozen=True)
class Instruction:
    opcode: Opcode
    src: int = 0
    dst: int = 0
    addr: int = 0
    length: int = 0
    accum_ctrl: AccumCtrl = AccumCtrl.NONE
    reserved: int = 0

    def __post_init__(self):
        assert 0 <= int(self.opcode) <= 0xF
        assert 0 <= self.src <= 0x3, f"src field is 2 bits: {self.src}"
        assert 0 <= self.dst <= 0x3, f"dst field is 2 bits: {self.dst}"
        assert 0 <= self.addr <= 0xFF, f"addr field is 8 bits: {self.addr}"
        assert 0 <= self.length <= 0xFF, f"length field is 8 bits: {self.length}"
        assert 0 <= int(self.accum_ctrl) <= 0x3
        assert 0 <= self.reserved <= 0x3F

    def encode(self) -> int:
        """Pack to the same 32-bit word control_unit.sv/instruction_fifo.sv use."""
        word = 0
        word |= (int(self.opcode) & 0xF) << 28
        word |= (self.src & 0x3) << 26
        word |= (self.dst & 0x3) << 24
        word |= (self.addr & 0xFF) << 16
        word |= (self.length & 0xFF) << 8
        word |= (int(self.accum_ctrl) & 0x3) << 6
        word |= (self.reserved & 0x3F)
        return word & 0xFFFFFFFF

    @staticmethod
    def decode(word: int) -> "Instruction":
        word &= 0xFFFFFFFF
        opcode = Opcode((word >> 28) & 0xF)
        src = (word >> 26) & 0x3
        dst = (word >> 24) & 0x3
        addr = (word >> 16) & 0xFF
        length = (word >> 8) & 0xFF
        accum_ctrl = AccumCtrl((word >> 6) & 0x3)
        reserved = word & 0x3F
        return Instruction(opcode, src, dst, addr, length, accum_ctrl, reserved)

    def hex(self) -> str:
        return f"32'h{self.encode():08x}"

    def __repr__(self):
        return (f"{self.opcode.name}(src={self.src},dst={self.dst},"
                f"addr=0x{self.addr:02x},len={self.length},"
                f"accum={self.accum_ctrl.name})  [{self.hex()}]")


# ---------------------------------------------------------------------------
# Convenience builders -- one per opcode, mirroring instructions_fifo.sv's
# hand-assembled ROM comments so a microprogram reads like the RTL's own
# documentation of the ISA.
# ---------------------------------------------------------------------------

def NOP() -> Instruction:
    return Instruction(Opcode.NOP)

def LOAD_WGT(addr: int, length: int) -> Instruction:
    return Instruction(Opcode.LOAD_WGT, addr=addr, length=length)

def LOAD_ACT(dst: int, addr: int, length: int) -> Instruction:
    return Instruction(Opcode.LOAD_ACT, dst=dst, addr=addr, length=length)

def LOAD_BIAS(addr: int, length: int) -> Instruction:
    return Instruction(Opcode.LOAD_BIAS, addr=addr, length=length)

def MATMUL(src: int, addr: int, accum_ctrl: AccumCtrl = AccumCtrl.NONE) -> Instruction:
    return Instruction(Opcode.MATMUL, src=src, addr=addr, accum_ctrl=accum_ctrl)

def VECTOR(dst: int, addr: int) -> Instruction:
    return Instruction(Opcode.VECTOR, dst=dst, addr=addr)

def STORE(src: int, addr: int, length: int) -> Instruction:
    return Instruction(Opcode.STORE, src=src, addr=addr, length=length)

def SWAP_WGT() -> Instruction:
    return Instruction(Opcode.SWAP_WGT)

def END() -> Instruction:
    return Instruction(Opcode.END)

def SET_BASE(base: Base, offset_beats: int) -> Instruction:
    """Set a DMA base offset; the 24-bit immediate spans addr|length|accum_ctrl|reserved."""
    assert 0 <= offset_beats <= SET_BASE_MAX_BEATS, f"SET_BASE offset is 24 bits (beats): {offset_beats}"
    return Instruction(Opcode.SET_BASE, dst=int(base),
                       addr=(offset_beats >> 16) & 0xFF,
                       length=(offset_beats >> 8) & 0xFF,
                       accum_ctrl=AccumCtrl((offset_beats >> 6) & 0x3),
                       reserved=offset_beats & 0x3F)

def set_base_offset(ins: Instruction) -> int:
    """Inverse of SET_BASE(): the 24-bit beat offset."""
    return (ins.addr << 16) | (ins.length << 8) | (int(ins.accum_ctrl) << 6) | ins.reserved
