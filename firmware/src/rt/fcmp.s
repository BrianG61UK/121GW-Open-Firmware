@ =============================================================================
@ fcmp.s - RT: floating-point comparisons that return their result in the flags
@
@ Port of the v2.05 helpers
@   fn_0801BD08  float equality     (__aeabi_cfcmpeq shape)
@   fn_08020390  float a versus b   (__aeabi_cfcmple shape)
@   fn_0802035C  float b versus a   (__aeabi_cfrcmple shape: the same comparison with the operands exchanged)
@   fn_08023F2C  double a versus b  (__aeabi_cdcmple shape)
@
@ The result is only in the CPSR flags (DESIGN.md 6: the helper exception to AAPCS).  Arguments: a in r0, b in r1 for
@ the float helpers; a in r0 (low) : r1 (high), b in r2 : r3 for the double helper.  r12 and the flags are scratch.
@ The flags encode the order the way an unsigned compare of the bit patterns does for non-negative operands
@ (C = 0 "lower": a < b; Z = 1: a == b; C = 1 and Z = 0 "higher": a > b); for negative operands the compare is made
@ with the operands exchanged, which reverses the bit-pattern order; zeros of either sign are equal; a NaN gives
@ C = 1, Z = 0 (the same as "higher"; the helpers cannot report "unordered" separately).  Every routine is a copy of
@ the v2.05 instruction sequence, re-expressed with symbolic labels, so every flag is the one v2.05 produces.
@
@ A note on the IT blocks: where an instruction inside an IT block changes the flags, the condition of a following
@ "else" instruction is tested on the new flags (this is how v2.05 chains the low-word compare of fn_08023F2C onto the
@ high-word compare); the sequences below are unchanged.
@
@ Context: ISR-safe, no memory access, no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0801BD08 - float equality test, result in the flags
@ Replaces : 0x0801BD08 (v2.05 FUN_0801bd08)
@ In       : r0 = a, r1 = b (binary32 bit patterns)
@ Out      : flags only: Z = 1 when a == b (+0 equals -0); Z = 0 otherwise (a NaN also gives C = 1)
@ Clobbers : r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801BD08
    orr r12, r0, r1                        @ r12 = a | b
    lsls r12, r12, #1                      @ r12 <<= 1: Z when both operands are +-0
    beq .Lfcmpeq_0801BD22                  @ both zero: equal, return
    cmp r0, r1                             @ compare the bit patterns
    bne .Lfcmpeq_0801BD22                  @ different patterns: not equal, return with the flags of the compare
    lsl r12, r0, #1                        @ identical patterns: r12 = a << 1
    cmn r12, #0x1000000                    @ r12 + 0x01000000: C = 1 when a is infinity or NaN, Z = 1 when it is exactly an infinity
    it ls                                  @ finite number or infinity (C = 0 or Z = 1): ...
    cmpls r0, r0                           @ ... equal (compare a register with itself: Z = 1, C = 1); a NaN keeps C = 1, Z = 0
    @ Return.
.Lfcmpeq_0801BD22:
    bx lr
ENDFUNC fn_0801BD08

@ -----------------------------------------------------------------------------
@ fn_08020390 - float comparison a versus b, result in the flags
@ Replaces : 0x08020390 (v2.05 FUN_08020390)
@ In       : r0 = a, r1 = b (binary32 bit patterns)
@ Out      : flags only: see the file header (C = 0: a < b, Z = 1: a == b, C = 1 and Z = 0: a > b or a NaN)
@ Clobbers : r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08020390
    mov r12, #0x1000000                    @ r12 = 0x01000000
    cmn r12, r0, lsl #1                    @ r12 + (a << 1): C = 1 when a is infinity or NaN, Z = 1 when it is exactly an infinity
    ite ls                                 @ a is finite or an infinity (C = 0 or Z = 1): ...
    cmnls r12, r1, lsl #1                  @ ... same test for b
    bhi .Lfcmple_080203AC                  @ a NaN in a or in b (C = 1 and Z = 0): return with these flags
    orr r12, r0, r1                        @ r12 = a | b
    lsls r12, r12, #1                      @ r12 <<= 1: C = sign bit of a | b (some operand is negative); Z when both are +-0
    bcs .Lfcmple_080203AE                  @ some operand negative: reversed compare below
    cmp r0, r1                             @ both non-negative: compare the bit patterns
    @ Return.
.Lfcmple_080203AC:
    bx lr
    @ Some operand is negative.
.Lfcmple_080203AE:
    it ne                                  @ not both zero: ...
    cmpne r1, r0                           @ ... compare b with a (the order of negative bit patterns is reversed); both zero: the flags of the shift (Z = 1, equal)
    bx lr
ENDFUNC fn_08020390

@ -----------------------------------------------------------------------------
@ fn_0802035C - float comparison b versus a (reverse operands), result in the flags
@ Replaces : 0x0802035C (v2.05 FUN_0802035c)
@ In       : r0 = a, r1 = b (binary32 bit patterns)
@ Out      : flags only: the flags of fn_08020390 with the operands exchanged (C = 0: b < a, Z = 1: equal, C = 1 and Z = 0: b > a or a NaN)
@ Clobbers : r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0802035C
    mov r12, #0x1000000                    @ r12 = 0x01000000
    cmn r12, r0, lsl #1                    @ r12 + (a << 1): C = 1 when a is infinity or NaN, Z = 1 when it is exactly an infinity
    ite ls                                 @ a is finite or an infinity (C = 0 or Z = 1): ...
    cmnls r12, r1, lsl #1                  @ ... same test for b
    bhi .Lfcmpr_08020378                   @ a NaN in a or in b (C = 1 and Z = 0): return with these flags
    orr r12, r0, r1                        @ r12 = a | b
    lsls r12, r12, #1                      @ r12 <<= 1: C = sign bit of a | b (some operand is negative); Z when both are +-0
    bcs .Lfcmpr_0802037A                   @ some operand negative: reversed compare below
    cmp r1, r0                             @ both non-negative: compare b with a
    @ Return.
.Lfcmpr_08020378:
    bx lr
    @ Some operand is negative.
.Lfcmpr_0802037A:
    it ne                                  @ not both zero: ...
    cmpne r0, r1                           @ ... compare a with b; both zero: the flags of the shift (Z = 1, equal)
    bx lr
ENDFUNC fn_0802035C

@ -----------------------------------------------------------------------------
@ fn_08023F2C - double comparison a versus b, result in the flags
@ Replaces : 0x08023F2C (v2.05 FUN_08023f2c)
@ In       : r0:r1 = a, r2:r3 = b (binary64 bit patterns, low word first)
@ Out      : flags only: see the file header (C = 0: a < b, Z = 1: a == b, C = 1 and Z = 0: a > b or a NaN)
@ Clobbers : r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08023F2C
    mov r12, #0x200000                     @ r12 = 0x00200000
    cmn r12, r1, lsl #1                    @ r12 + (high word of a << 1): C = 1 when the exponent field of a is 0x7FF, Z = 1 when the high mantissa bits are zero as well
    ite ls                                 @ a finite or infinity-like (C = 0 or Z = 1): ...
    cmnls r12, r3, lsl #1                  @ ... same test for b
    bhi .Ldcmple_08023F50                  @ a NaN (non-zero high mantissa bits) in a or b: return with these flags
    orr r12, r1, r3                        @ r12 = a_hi | b_hi
    orrs r12, r0, r12, lsl #1              @ r12 = a_lo | ((a_hi | b_hi) << 1); C = sign bit of a_hi | b_hi (some operand negative)
    orrs r12, r2, r12                      @ r12 |= b_lo; Z when both operands are +-0 (C unchanged)
    bcs .Ldcmple_08023F52                  @ some operand negative: reversed compare below
    cmp r1, r3                             @ both non-negative: compare the high words ...
    it eq                                  @ ... and, when equal, the low words
    cmpeq r0, r2
    @ Return.
.Ldcmple_08023F50:
    bx lr
    @ Some operand is negative.
.Ldcmple_08023F52:
    ite ne                                 @ not both zero (NE): ...
    cmpne r3, r1                           @ ... compare the high words reversed (b with a); equal high words make the next instruction run
    cmpeq r2, r0                           @ ... compare the low words reversed (b with a), also for both operands zero (Z = 1 from the shift)
    bx lr
ENDFUNC fn_08023F2C

