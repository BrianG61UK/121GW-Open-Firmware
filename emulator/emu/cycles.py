"""Cortex-M3 core clock cycle estimate per instruction, computed once per translated block (Machine._on_block).

Source: ARM DDI 0337H, Cortex-M3 Technical Reference Manual r2p0, chapter "Programmers Model":
  "Cortex-M3 instructions", Table 3.1 "Cortex-M3 instruction set summary" (cycle counts, "based on a system with zero
  wait states"), and the topic "Load/store timings".  Cited below as "T3.1" and "LST".
  The flash wait state penalty of a branch is RM0038 3.3.2 (DocID15965 Rev 15), note below Figure 5.

The estimate is the best case the manuals give, so the emulated time of a code path is a lower bound of the hardware
time (up to the effects listed under "not modelled"):
  data processing, MOV/MOVW/MOVT/ADR, compare, logical, shift, extend, bit field, REV/RBIT, CLZ, SSAT/USAT, MUL,
    NOP, SEV, CLREX                                       1        (T3.1)
  MLA, MLS                                                2        (T3.1)
  SMULL, UMULL                                            3        (T3.1 "3 to 5", early termination: minimum)
  SMLAL, UMLAL                                            4        (T3.1 "4 to 7": minimum)
  SDIV, UDIV                                              2        (T3.1 "2 to 12": minimum)
  LDR/LDRB/LDRH/LDRSB/LDRSH (also T forms, PC-relative),
    LDREX/STREX (all sizes)                               2        (T3.1 "2[c]"; LST: LDREX/STREX pipeline as LDR)
  STR/STRB/STRH with immediate offset or no offset        1        (LST "STR Rx,[Ry,#imm] is always one cycle")
  STR/STRB/STRH with register offset                      2        (T3.1)
  pipelining: a single load or store that directly follows a single LDR (no base update, not to PC) whose destination
    register is not used for its address costs 1 cycle less (LST "LDR [any] are pipelined when possible ... one cycle is
    removed from the cost of the next instruction"); nothing is pipelined after a store (LST); LDR with base update is
    "not normally pipelined" (LST): a load or store with base update is not pipelined in either direction here
  LDRD, STRD                                              3        (T3.1 1 + N, LST "requires three cycles")
  LDM, STM, PUSH, POP                                     1 + N    (T3.1, N registers including PC / LR)
  B, BL, BX, BLX, B<cond>, CBZ, CBNZ, MOV/ADD to PC       1        + P when taken (T3.1)
  LDR to PC                                               2        + P (T3.1)
  POP / LDM with PC                                       1 + N    + P (T3.1)
  TBB, TBH                                                2        + P (T3.1)
  IT                                                      1, or 0 when it follows a 16-bit instruction in the same
                                                          block (T3.1 note e: "can be folded onto a preceding 16-bit
                                                          Thumb instruction, enabling execution in zero cycles")
  CPSID, CPSIE, MRS, MSR                                  1        (T3.1 "1 or 2": minimum)
  DMB, DSB                                                1        (T3.1 1 + B, "For DSB and DMB, the minimum number of
                                                          cycles is zero")
  ISB                                                     2        (T3.1 1 + B, "For ISB, the minimum ... is equivalent to
                                                          the number required for a pipeline refill": P = 1)
  WFI, WFE                                                1 + W    (T3.1; counted by Machine._sleep, not here)
  SVC, BKPT                                               1        (T3.1 gives no count; the firmware does not use them)
  conditional instructions inside an IT block are charged their own count whether or not the condition passes
  (T3.1 gives no separate figure).
Taken branch (charged by Machine._on_block when a block is entered at another address than the end of the block before):
  P = 1 (T3.1: "ranges from 1 to 3 depending on the alignment and width of the target instruction ...": minimum), plus the
  flash LATENCY (FLASH_ACR bit 0) when the target is in flash and lies neither in the 64-bit line of the branch
  instruction nor, with prefetch on (PRFTEN), in the next line: RM0038 3.3.2 "the instruction may not be present neither
  in the current instruction line used nor in the prefetched instruction line.  In this case, the penalty in terms of
  number of cycles is at least equal to the number of Wait States."
A taken branch to the next sequential address (B to the next instruction, CBZ / CBNZ over nothing, TBB / TBH entry 0)
is not told apart from falling through and gets no refill.
Not modelled (each makes the hardware slower than the estimate): the upper ends of the ranges above (P = 2 or 3,
data-dependent multiply / divide), flash wait states of data loads from flash and of sequential fetches without
prefetch, APB / AHB bus and bridge wait states of peripheral accesses, unaligned access penalties (LST), the possible
extra cycle of a PC-relative LDR from contention with the fetch unit (LST), and the LDR-with-base-update reduction of
LST ("if the next instruction does not require to read from a register, the load is reduced to one cycle") which would
make the estimate 1 cycle lower for such pairs.
"""
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS
from capstone import arm_const as A

_LOAD1 = {A.ARM_INS_LDR, A.ARM_INS_LDRB, A.ARM_INS_LDRH, A.ARM_INS_LDRSB, A.ARM_INS_LDRSH, A.ARM_INS_LDRT,
          A.ARM_INS_LDRBT, A.ARM_INS_LDRHT, A.ARM_INS_LDRSBT, A.ARM_INS_LDRSHT, A.ARM_INS_LDREX, A.ARM_INS_LDREXB,
          A.ARM_INS_LDREXH}
_STORE1 = {A.ARM_INS_STR, A.ARM_INS_STRB, A.ARM_INS_STRH, A.ARM_INS_STRT, A.ARM_INS_STRBT, A.ARM_INS_STRHT}
_STREX = {A.ARM_INS_STREX, A.ARM_INS_STREXB, A.ARM_INS_STREXH}
_DUAL = {A.ARM_INS_LDRD, A.ARM_INS_STRD, A.ARM_INS_LDREXD, A.ARM_INS_STREXD}
_MULTI = {A.ARM_INS_LDM, A.ARM_INS_LDMDB, A.ARM_INS_LDMDA, A.ARM_INS_LDMIB, A.ARM_INS_STM, A.ARM_INS_STMDB,
          A.ARM_INS_STMDA, A.ARM_INS_STMIB, A.ARM_INS_PUSH, A.ARM_INS_POP}
_FIXED = {A.ARM_INS_MLA: 2, A.ARM_INS_MLS: 2, A.ARM_INS_SMULL: 3, A.ARM_INS_UMULL: 3, A.ARM_INS_SMLAL: 4,
          A.ARM_INS_UMLAL: 4, A.ARM_INS_SDIV: 2, A.ARM_INS_UDIV: 2, A.ARM_INS_TBB: 2, A.ARM_INS_TBH: 2,
          A.ARM_INS_ISB: 2}
_PC = A.ARM_REG_PC


class CycleModel:
    def __init__(self):
        self.cs = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
        self.cs.detail = True

    def block(self, code, addr):
        """(instruction addresses, cumulative costs, WFI addresses) of the code of one translated block: cum[i] is the
        cost of the instructions before instruction i, cum[-1] the cost of the whole block (taken-branch refill
        excluded)."""
        addrs, cum, wfi = [], [0], []
        prev = None                                   # (instruction, destination of a single LDR that can pipeline)
        for i in self.cs.disasm(code, addr):
            c, ldr_dst = self._cost(i, prev)
            addrs.append(i.address)
            cum.append(cum[-1] + c)
            if i.id == A.ARM_INS_WFI:
                wfi.append(i.address)
            prev = (i, ldr_dst)
        # Capstone stops at an encoding it rejects while Unicorn translated the block to its end: the rest is counted
        # as instructions of 1 cycle each, 32-bit when the first halfword is 0b11101 / 0b11110 / 0b11111 xxxxxxxxxxx
        # (ARMv7-M ARM A5.1), so that every address Unicorn can stop at has a slot
        if not code:                                  # empty block (Unicorn reports an invalid instruction): one slot
            return (addr,), (0, 1), []
        a = addrs[-1] + prev[0].size if addrs else addr
        end = addr + len(code)
        while a < end:
            hw = int.from_bytes(code[a - addr:a - addr + 2], 'little')
            addrs.append(a)
            cum.append(cum[-1] + 1)
            a += 4 if hw >> 11 in (0b11101, 0b11110, 0b11111) else 2
        return tuple(addrs), tuple(cum), wfi

    @staticmethod
    def _mem(i):
        for o in i.operands:
            if o.type == A.ARM_OP_MEM:
                return o.mem
        return None

    def _cost(self, i, prev):
        """Cost of instruction i (prev: the instruction before it in the block) and, when i is a single LDR that can
        pipeline into the next instruction, its destination register (else None)."""
        iid = i.id
        if iid in _LOAD1 or iid in _STORE1 or iid in _STREX:
            mem = self._mem(i)
            wb = i.writeback
            dst = i.operands[0].reg if i.operands and i.operands[0].type == A.ARM_OP_REG else None
            if iid in _STORE1:
                c = 2 if (mem is not None and mem.index != 0) else 1
            else:
                c = 2
            if (not wb and prev is not None and prev[1] is not None and mem is not None
                    and prev[1] not in (mem.base, mem.index)):
                c = max(1, c - 1)                     # LST: pipelined behind the preceding LDR
            if iid in _LOAD1 and dst == _PC:
                return 2, None                        # LDR to PC: blocking (+ P when the branch is taken)
            pipe = dst if (iid in _LOAD1 or iid in _STREX) and not wb else None
            return c, pipe
        if iid in _DUAL:
            return 3, None
        if iid in _MULTI:
            n = sum(1 for o in i.operands if o.type == A.ARM_OP_REG)
            if iid in (A.ARM_INS_LDM, A.ARM_INS_LDMDB, A.ARM_INS_LDMDA, A.ARM_INS_LDMIB,
                       A.ARM_INS_STM, A.ARM_INS_STMDB, A.ARM_INS_STMDA, A.ARM_INS_STMIB):
                n -= 1                                # the first register operand is the base, not in the list
            return 1 + n, None
        if iid == A.ARM_INS_IT:
            return (0 if prev is not None and prev[0].size == 2 else 1), None
        return _FIXED.get(iid, 1), None
