@ =============================================================================
@ dconv.s - RT: conversions between integers, single and double precision (double side)
@
@ Port of the v2.05 run-time helpers
@   fn_080132A0  double -> signed 32-bit integer, truncating, saturating   (__aeabi_d2iz shape; body fn_080132CC)
@   fn_08013EC4  signed 32-bit integer -> double                           (__aeabi_i2d shape)
@   fn_08013ED8  unsigned 32-bit integer -> double                         (__aeabi_ui2d shape; body fn_08013EDC)
@   fn_0801BACC  double -> float                                           (__aeabi_d2f shape)
@
@ Calling convention (DESIGN.md 6, exception for RT): a double is in r0 (low word) : r1 (high word), a float or a
@ 32-bit integer in r0; r2, r3, r12 and the flags are scratch, r4-r11 are preserved.  Every routine is a copy of the
@ v2.05 instruction sequence, re-expressed with symbolic labels, so every register, flag and result bit is the one
@ v2.05 produces.  Bit-exactness against the original routines is verified by executing both under Unicorn.
@ Context: ISR-safe, no memory access, no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_080132A0 / fn_080132CC - convert a double to a signed 32-bit integer: truncation toward zero, saturating
@ Replaces : 0x080132A0 (entry; v2.05 FUN_080132a0, the double-to-int helper) and 0x080132CC (magnitude body; v2.05 FUN_080132cc)
@ In       : r0:r1 = binary64 bit pattern
@ Out      : r0 = signed integer; |x| < 1 gives 0; x >= 2^31, +infinity and every NaN with sign bit 0 give 0x7FFFFFFF;
@            x <= -2^31, -infinity and every NaN with sign bit 1 give 0x80000000 (observed by execution of the original)
@ Clobbers : r0, r1, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_080132A0
    mov r12, lr                            @ keep the return address (the magnitude body is entered with bl)
    lsrs r0, r0, #0x15                     @ r0 = top 11 bits of the low word ...
    orr r0, r0, r1, lsl #0xb               @ ... merged with the high word shifted left by 11: r0 = 32-bit window of the mantissa (bit 31 still holds an exponent bit)
    lsls r1, r1, #1                        @ C = sign bit, r1 = exponent field in bits 31..21
    bcs .Ld2iz_080132BA                    @ negative number: separate path
    bl fn_080132CC                         @ positive: r0 = magnitude (0xFFFFFFFF when the exponent is above 31)
    tst r0, r0                             @ magnitude with bit 31 set: ...
    it mi                                  @ ... saturate to 0x7FFFFFFF
    mvnmi r0, #0x80000000
    bx r12                                 @ return to the original caller
    @ Negative number.
.Ld2iz_080132BA:
    bl fn_080132CC                         @ r0 = magnitude
    mov r1, #0x80000000                    @ r1 = 0x80000000
    cmp r0, r1                             @ magnitude above 0x80000000?
    ite hi                                 @ yes: result 0x80000000 ...
    movhi r0, r1
    negls r0, r0                           @ no: r0 = -magnitude (also 0x80000000 for a magnitude of exactly 2^31)
    bx r12                                 @ return to the original caller
    @ Body: magnitude of the integer part.  In: r0 = mantissa window, r1 = exponent field in bits 31..21.  Out: r0 = |x| truncated (0xFFFFFFFF when the exponent is above 31, 0 when |x| < 1).
FUNC fn_080132CC
    orr r0, r0, #0x80000000                @ set the leading one in bit 31
    lsrs r1, r1, #0x15                     @ r1 = biased exponent
    sub r1, r1, #0x400                     @ r1 = biased exponent - 1024 ...
    adds r1, r1, #1                        @ ... + 1 = unbiased exponent e
    bmi .Ld2iz_080132E6                    @ e < 0: |x| < 1, the result is 0
    rsbs r1, r1, #0x1f                     @ r1 = 31 - e (right shift count); negative when e > 31
    ite pl                                 @ e <= 31: r0 >>= 31 - e
    lsrpl r0, r1
    asrmi r0, r0, #0x1f                    @ e > 31 (this includes infinity and NaN): r0 = 0xFFFFFFFF
    bx lr                                  @ return
    @ |x| < 1: result 0.
.Ld2iz_080132E6:
    mov r0, #0                             @ r0 = 0 (flags unchanged)
    bx lr
ENDFUNC fn_080132A0

@ -----------------------------------------------------------------------------
@ fn_08013EC4 / fn_08013ED8 / fn_08013EDC - convert an integer to a double
@ Replaces : 0x08013EC4 (signed; v2.05 FUN_08013ec4), 0x08013ED8 (unsigned entry; v2.05 FUN_08013ed8) and 0x08013EDC (unsigned body; v2.05 FUN_08013edc)
@ In       : r0 = signed (fn_08013EC4) or unsigned (fn_08013ED8) 32-bit integer
@ Out      : r0 = low word, r1 = high word of the binary64 bit pattern (exact: every 32-bit integer fits in 53 bits)
@ Clobbers : r0, r1, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08013EC4
    movs r1, r0                            @ r1 = r0, flags from r0 (sign, zero)
    bpl fn_08013EDC                        @ positive or zero: convert directly (the body returns zero as r0 = r1 = 0)
    mov r12, lr                            @ negative: keep the return address, the body is entered with bl
    negs r0, r0                            @ r0 = magnitude
    bl fn_08013EDC                         @ convert the magnitude
    orrs r1, r1, #0x80000000               @ set the sign bit in the high word
    bx r12                                 @ return to the original caller
FUNC fn_08013ED8
    movs r1, r0                            @ entry fn_08013ED8 (unsigned): r1 = r0, Z for the zero test of the body
    nop                                    @ alignment padding of the v2.05 image (executed nop), kept
    @ Body: convert the unsigned integer in r0 (Z set when r0 is 0).
FUNC fn_08013EDC
    beq .Li2d_08013EF2                     @ zero: return r0 = 0, r1 = 0 (r1 was set from r0)
    clz r1, r0                             @ r1 = leading zero count
    lsls r0, r1                            @ shift the leading one up to bit 31
    adds r1, r1, #3                        @ r1 = clz + 3
    rsb r1, r1, #0x420                     @ r1 = 0x420 - (clz + 3) = biased exponent minus one (the leading one added below supplies the +1)
    lsls r1, r1, #0x14                     @ exponent into bits 30..20
    add r1, r1, r0, lsr #0xb               @ high word = exponent + the top 20 mantissa bits (the leading one adds the +1 of the exponent)
    lsls r0, r0, #0x15                     @ low word = the remaining 11 mantissa bits
    @ return (also the zero result).
.Li2d_08013EF2:
    bx lr
ENDFUNC fn_08013EC4

@ -----------------------------------------------------------------------------
@ fn_0801BACC - convert a double to a single-precision float
@ Replaces : 0x0801BACC (v2.05 FUN_0801bacc, the double-to-float helper)
@ In       : r0:r1 = binary64 bit pattern
@ Out      : r0 = binary32 bit pattern, rounded to nearest, ties to even; exponent overflow gives a signed infinity; a
@            NaN gives 0xFFFFFFFF; exponent underflow gives a (rounded) subnormal or a signed zero
@ Clobbers : r0, r1, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801BACC
    ror r12, r1, #0x1f                     @ r12 = r1 rotated left by one: exponent in bits 31..21, mantissa high bits in 20..1, sign in bit 0
    subs r12, r12, #0x70000000             @ subtract the exponent bias difference (1023 - 127 = 896, in bits 31..21); C = no borrow
    ite cs                                 @ no borrow: C = new exponent >= 1
    cmpcs r12, #0x200000
    bcc .Ld2f_0801BB00                     @ new exponent below 1: subnormal float or zero
    lsls r12, r12, #1                      @ shift left once more; C = the top exponent bit (set for an exponent of 1024 or more after the subtraction)
    ite cc                                 @ no carry: compare with 255 << 22 ...
    cmpcc r12, #0x3fc00000
    bcs .Ld2f_0801BB46                     @ exponent 255 or more (including the carry case): infinity/NaN path
    lsrs r12, r12, #2                      @ shift right by two; C = the sign bit (bit 1 before)
    lsl r12, r12, #4                       @ exponent into bits 31..24
    rrx r12, r12                           @ rotate the sign in from C: r12 = sign, 8-bit exponent (bits 30..23), 20 high mantissa bits (bits 22..3)
    lsls r1, r0, #3                        @ r1 = the 29 mantissa bits of the low word that do not fit, left aligned; C = bit 29 = lowest kept bit
    sbcs r1, r1, #0x80000000               @ round to nearest even: carry = 1 when the discarded bits are above one half, or exactly one half and the lowest kept bit is 1
    adc r0, r12, r0, lsr #0x1d             @ r0 = sign, exponent, high mantissa bits + the 3 top bits of the low word + rounding carry
    bx lr                                  @ return
    @ Exponent below the float range: subnormal float or zero.
.Ld2f_0801BB00:
    lsls r1, r1, #0xb                      @ r1 = mantissa high bits shifted up ...
    orr r1, r1, r0, lsr #0x15              @ ... plus the top 11 bits of the low word
    lsls r0, r0, #0xb                      @ r0 = low word << 11 (Z when no bits remain)
    it ne                                  @ bits remain: ...
    orrne r1, r1, #1                       @ ... fold them into the sticky bit 0
    orr r1, r1, #0x80000000                @ set the leading one: r1 = 32-bit significand window
    asr r0, r12, #0x15                     @ r0 = new exponent as a signed number (zero or negative)
    rsb r0, r0, #9                         @ r0 = 9 - exponent = right shift count of the significand
    cmp r0, #0x21                          @ count >= 33: the result is zero
    bcs .Ld2f_0801BB40
    orr r12, r0, r12, lsl #0x1f            @ r12 = count | sign << 31 (the sign travels in the top bit, the register shift counts use only the low byte)
    rsb r12, r12, #0x20                    @ r12 = 32 - count, sign kept in bit 31
    lsls r0, r1, r12                       @ r0 = r1 << (32 - count); C = lowest kept bit
    sbcs r0, r0, #0x80000000               @ round to nearest even: carry = 1 when the discarded bits are above one half, or exactly one half and the lowest kept bit is 1
    rsb r12, r12, #0x20                    @ r12 = count (sign in bit 31)
    lsr r0, r1, r12                        @ r0 = r1 >> count
    and r12, r12, #0x80000000              @ r12 = sign bit only
    adc r0, r0, r12                        @ r0 += sign + rounding carry
    bx lr                                  @ return
    @ Shift count 33 or more: signed zero.
.Ld2f_0801BB40:
    lsl r0, r12, #0x1f                     @ r0 = sign bit (bit 0 of r12 shifted to bit 31)
    bx lr
    @ Exponent too large (infinity, NaN, or a finite value above the float range).
.Ld2f_0801BB46:
    lsls r1, r1, #1                        @ r1 = high word << 1
    cmn r1, #0x200000                      @ compare with 0xFFE00000
    bhi .Ld2f_0801BB58                     @ NaN (high mantissa bits non-zero): see below
    lsl r0, r12, #7                        @ r0 = r12 << 7: bit 8 holds the sign, bits 7..0 are zero
    adds r0, #0xff                         @ r0 + 0xFF: bits 7..0 all ones, bit 8 = sign
    lsls r0, r0, #0x17                     @ r0 = sign | 0xFF << 23: a signed infinity
    bx lr
    @ NaN.
.Ld2f_0801BB58:
    asrs r0, r1, #0x1f                     @ r0 = 0xFFFFFFFF (r1 << 1 has its top bit set)
    bx lr
ENDFUNC fn_0801BACC

