@ =============================================================================
@ fconv.s - RT: conversions between integers, single and double precision (float side)
@
@ Port of the v2.05 run-time helpers (the ARM compiler floating-point library that is linked into the v2.05 image):
@   fn_08012F60  signed 32-bit integer -> float          (__aeabi_i2f shape)
@   fn_08012F74  unsigned 32-bit integer -> float        (__aeabi_ui2f shape; entry 0x08012F78 is the shared body)
@   fn_08013168  float -> double                         (__aeabi_f2d shape)
@   fn_08013370  float -> signed 32-bit integer, truncating, saturating     (__aeabi_f2iz shape)
@   fn_0801BD24  float -> unsigned 32-bit integer, truncating, saturating   (__aeabi_f2uiz shape)
@   fn_08014118  signed 64-bit integer -> float          (__aeabi_l2f shape; pieces 0x08014134, 0x08014140, 0x08014158, 0x0801415A)
@
@ Calling convention (DESIGN.md 6, exception for RT): a float argument and a float result are in r0, a double is in
@ r0 (low word) : r1 (high word), a 64-bit integer likewise; r2/r3/r12 and the flags are scratch; r4-r11 are preserved.
@ Every routine is a copy of the v2.05 instruction sequence (same operations in the same order, so every register,
@ flag and result bit is the one v2.05 produces), re-expressed with symbolic labels.
@ Context: ISR-safe, no memory access, no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08012F60 - convert a signed 32-bit integer to a single-precision float
@ Replaces : 0x08012F60 (v2.05 FUN_08012f60, the integer-to-float helper)
@ In       : r0 = signed 32-bit integer
@ Out      : r0 = IEEE 754 binary32 bit pattern, rounded to nearest, ties to even
@ Clobbers : r0-r2, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5; the magnitude is converted by fn_08012F78 and the sign bit is set afterwards
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08012F60
    cmp r0, #0                             @ sign test; the flags (N, Z) also reach the zero test at the start of fn_08012F78
    bpl fn_08012F78                        @ positive or zero: convert directly, the shared body returns to the caller (r0 = 0 gives 0.0)
    mov r12, lr                            @ negative: keep the return address, the body below is entered with bl
    negs r0, r0                            @ r0 = magnitude (0x80000000 stays 0x80000000, which the unsigned body reads as 2^31)
    bl fn_08012F78                         @ convert the magnitude as an unsigned integer (Z = 0 here, r0 is not zero)
    orrs r0, r0, #0x80000000               @ set the sign bit of the result
    bx r12                                 @ return to the original caller
ENDFUNC fn_08012F60

@ -----------------------------------------------------------------------------
@ fn_08012F74 / fn_08012F78 - convert an unsigned 32-bit integer to a single-precision float
@ Replaces : 0x08012F74 (entry that sets Z) and 0x08012F78 (body; v2.05 FUN_08012f78), the unsigned integer-to-float helper
@ In       : r0 = unsigned 32-bit integer (entry fn_08012F78: Z must reflect r0 = 0, as set by the caller)
@ Out      : r0 = IEEE 754 binary32 bit pattern, rounded to nearest, ties to even
@ Clobbers : r0-r2, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5; the body fn_08012F78 is also entered, with bl, by fn_08012F60 (signed conversion)
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08012F74
    cmp r0, #0                             @ entry fn_08012F74: Z = (r0 == 0) for the test below
    nop                                    @ alignment padding of the v2.05 image (an executed nop with no effect), kept so the sequence is the original one
    @ Body (entry fn_08012F78): normalise the integer, build exponent and mantissa, round to nearest even.
FUNC fn_08012F78
    beq .Lui2f_zero                        @ r0 = 0: the result 0.0 is r0 itself
    clz r1, r0                             @ r1 = number of leading zero bits of r0
    lsls r0, r1                            @ shift the leading one up to bit 31
    rsbs r1, r1, #0x9d                     @ r1 = 157 - clz: biased exponent minus one (the implicit leading one added below supplies the missing +1)
    lsls r1, r1, #0x17                     @ move the exponent into bits 30..23
    lsls r2, r0, #0x18                     @ r2 = the 8 bits that are discarded when the mantissa is cut to 24 bits, left aligned; C = lowest kept mantissa bit
    sbcs r2, r2, #0x80000000               @ compare the discarded bits with one half: carry afterwards = 1 when they are above one half, or exactly one half and the lowest kept bit is 1 (ties to even)
    adc r0, r1, r0, lsr #8                 @ r0 = exponent field + (mantissa with its leading one in bit 23, which adds the +1 of the exponent) + rounding carry; a mantissa overflow carries into the exponent correctly
    @ r0 = 0 (zero input): return.
.Lui2f_zero:
    bx lr
ENDFUNC fn_08012F74

@ -----------------------------------------------------------------------------
@ fn_08013168 - convert a single-precision float to a double
@ Replaces : 0x08013168 (v2.05 FUN_08013168, the float-to-double helper)
@ In       : r0 = binary32 bit pattern
@ Out      : r0 = low word, r1 = high word of the binary64 bit pattern
@ Clobbers : r0, r1, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence).  Observed by execution of the original: a NaN input gives r0 = 0,
@            r1 = 0xFFFFFFFF whatever its payload; infinity keeps its sign (r1 = 0x7FF00000 or 0xFFF00000, r0 = 0).
@ -----------------------------------------------------------------------------
FUNC fn_08013168
    movs r12, #0xff                        @ r12 = 0xFF, exponent mask
    ands r1, r12, r0, lsr #0x17            @ r1 = biased exponent of the float (Z set when it is 0)
    ite ne                                 @ if the exponent is not 0 ...
    cmpne r1, r12                          @ ... compare it with 255; the beq below takes both special cases (exponent 0 or 255)
    beq .Lf2d_08013184                     @ exponent 0 (zero, subnormal) or 255 (infinity, NaN): special handling
    asrs r1, r0, #3                        @ normal number: r1 = sign, exponent and top mantissa bits shifted down by 3 (sign extended)
    lsls r0, r0, #0x1d                     @ r0 = low word: the 3 low mantissa bits go to bits 31..29
    bic r1, r1, #0x70000000                @ clear the three copies of the sign that the arithmetic shift put into bits 30..28
    add r1, r1, #0x38000000                @ rebias the exponent: +(1023 - 127) << 20 = 0x38000000
    bx lr                                  @ return
    @ Exponent field 0 or 255.
.Lf2d_08013184:
    cbnz r1, .Lf2d_080131A6                @ exponent field not 0, therefore 255: infinity or NaN
    and r1, r0, #0x80000000                @ zero or subnormal: r1 = sign bit
    lsls r0, r0, #8                        @ r0 = mantissa in bits 30..8 (the sign and the exponent field are shifted out); Z = mantissa is zero
    beq .Lf2d_080131A4                     @ zero: return the signed zero (r0 = 0, r1 = sign)
    clz r12, r0                            @ subnormal: r12 = leading zero count of the mantissa
    lsl r0, r0, r12                        @ shift the leading one up to bit 31
    add r1, r1, #0x38000000                @ start the exponent from the bias difference
    sub r1, r1, r12, lsl #0x14             @ subtract the shift count from the exponent field
    add r1, r1, r0, lsr #0xb               @ add the mantissa bits that fit in the high word; its leading one (bit 31 >> 11 = bit 20) adds the +1 of the exponent
    lsls r0, r0, #0x15                     @ low word of the result
    @ Zero (Z set by lsls above) and every finished path: return.
.Lf2d_080131A4:
    bx lr
    @ Infinity or NaN.
.Lf2d_080131A6:
    lsls r1, r0, #9                        @ Z = mantissa is zero
    ite eq                                 @ infinity: ...
    orreq r1, r0, #0x700000                @ ... r1 = float bits | 0x700000: exponent field 0x7FF in the high word, sign kept
    mvnne r1, #0                           @ NaN: r1 = 0xFFFFFFFF
    movs r0, #0                            @ low word 0
    bx lr                                  @ return
ENDFUNC fn_08013168

@ -----------------------------------------------------------------------------
@ fn_08013370 - convert a float to a signed 32-bit integer: truncation toward zero, saturating
@ Replaces : 0x08013370 (v2.05 FUN_08013370, the float-to-int helper)
@ In       : r0 = binary32 bit pattern
@ Out      : r0 = signed integer; |x| < 1 gives 0; x >= 2^31 or +infinity or a NaN with sign bit 0 gives 0x7FFFFFFF;
@            x <= -2^31 or -infinity or a NaN with sign bit 1 gives 0x80000000 (observed by execution of the original)
@ Clobbers : r0, r1, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08013370
    lsls r1, r0, #1                        @ drop the sign: exponent in bits 31..24
    lsrs r1, r1, #0x18                     @ r1 = biased exponent
    subs r1, #0x7f                         @ r1 = unbiased exponent e
    bmi .Lf2iz_080133A4                    @ e < 0: |x| < 1, the result is 0
    rsbs r1, r1, #0x1f                     @ r1 = 31 - e (right shift count); negative when e > 31
    bmi .Lf2iz_080133A8                    @ e > 31 (this includes infinity and NaN): saturate
    lsls r0, r0, #1                        @ C = sign bit, r0 = exponent and mantissa left aligned
    bcs .Lf2iz_08013392                    @ negative: separate path
    lsls r0, r0, #7                        @ mantissa to bits 31..9
    orr r0, r0, #0x80000000                @ add the leading one
    lsrs r0, r1                            @ integer part of |x| (shift right by 31 - e); N set when bit 31 is still set (|x| = 2^31 .. 2^32)
    it mi                                  @ |x| >= 2^31 positive: ...
    mvnmi r0, #0x80000000                  @ ... saturate to 0x7FFFFFFF
    bx lr                                  @ return
    @ Negative number: same shift, then negate.
.Lf2iz_08013392:
    lsls r0, r0, #7                        @ mantissa to bits 31..9
    orr r0, r0, #0x80000000                @ add the leading one
    lsrs r0, r1                            @ integer part of |x|; N set when |x| >= 2^31
    ite mi                                 @ |x| >= 2^31: ...
    movmi r0, #0x80000000                  @ ... result 0x80000000 (the most negative integer)
    negpl r0, r0                           @ otherwise r0 = -|x| (flags still those of the shift: N clear)
    bx lr                                  @ return
    @ e < 0: |x| < 1 gives 0.
.Lf2iz_080133A4:
    movs r0, #0
    bx lr
    @ e > 31 (or infinity, NaN): saturate by the sign bit of the input.
.Lf2iz_080133A8:
    tst r0, r0                             @ N = sign of the input
    mov r0, #0x80000000                    @ assume the negative result 0x80000000
    it pl                                  @ positive input: r0 = ~0x80000000 = 0x7FFFFFFF
    mvnpl r0, r0
    bx lr
ENDFUNC fn_08013370

@ -----------------------------------------------------------------------------
@ fn_0801BD24 - convert a float to an unsigned 32-bit integer: truncation toward zero, saturating
@ Replaces : 0x0801BD24 (v2.05 FUN_0801bd24, the float-to-unsigned helper)
@ In       : r0 = binary32 bit pattern
@ Out      : r0 = unsigned integer; negative numbers and |x| < 1 give 0; x >= 2^32, +infinity, every NaN with
@            exponent 255 give 0xFFFFFFFF (a NaN with sign bit 1 gives 0), observed by execution of the original
@ Clobbers : r0, r1, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801BD24
    lsls r0, r0, #1                        @ C = sign bit, r0 = exponent and mantissa left aligned
    bcs .Lf2uiz_0801BD44                   @ negative: result 0
    lsrs r1, r0, #0x18                     @ r1 = biased exponent
    subs r1, #0x7f                         @ r1 = unbiased exponent e
    bmi .Lf2uiz_0801BD44                   @ e < 0: |x| < 1, result 0
    rsbs r1, r1, #0x1f                     @ r1 = 31 - e; negative when e > 31
    bmi .Lf2uiz_0801BD3E                   @ x >= 2^32 (this includes infinity and NaN): saturate
    lsls r0, r0, #7                        @ mantissa to bits 31..9
    orr r0, r0, #0x80000000                @ add the leading one
    lsrs r0, r1                            @ integer part (shift right by 31 - e)
    bx lr                                  @ return
    @ e > 31: saturate.
.Lf2uiz_0801BD3E:
    mvns r0, #0                            @ r0 = 0xFFFFFFFF
    bx lr
    @ Negative or |x| < 1: result 0.
.Lf2uiz_0801BD44:
    movs r0, #0
    bx lr
ENDFUNC fn_0801BD24

@ -----------------------------------------------------------------------------
@ fn_08014118 - convert a signed 64-bit integer to a single-precision float
@ Replaces : 0x08014118 (v2.05 FUN_08014118, the 64-bit-integer-to-float helper) with the pieces 0x08014134, 0x08014140,
@            0x08014158 and 0x0801415A (v2.05 FUN_08014140, FUN_08014158 and their shared labels)
@ In       : r0 = low word, r1 = high word of the signed 64-bit integer
@ Out      : r0 = IEEE 754 binary32 bit pattern, rounded to nearest, ties to even (bits below the 32-bit window are folded into a sticky bit)
@ Clobbers : r0-r2, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08014118
    cmp r1, #0                             @ sign of the 64-bit value
    bpl .Ll2f_nonneg                       @ non-negative: skip the negation
    mov r12, lr                            @ negative: keep the return address in r12 (the conversion below is entered with bl)
    negs r1, r1                            @ r1 = -r1
    negs r0, r0                            @ r0 = -r0, borrow = (r0 was not 0)
    sbcs r1, r1, #0                        @ r1 = -r1 - borrow: together a 64-bit negation (r1 was negated first, the borrow of the low word is subtracted after)
    bl fn_08014140                         @ convert the magnitude (r1 high word, r0 low word)
    orrs r0, r0, #0x80000000               @ set the sign bit
    bx r12                                 @ return to the original caller
    @ Non-negative value.
.Ll2f_nonneg:
    orrs r2, r0, r1                        @ Z = (low word | high word) == 0
    beq fn_08014158                        @ value is 0: return 0.0 (r0 is already 0)
    tst r1, r1                             @ set N/Z from the high word; the nop is alignment padding of the v2.05 image and is executed
    nop
    @ Conversion of the magnitude in r1:r0 (r1 = high word).
FUNC fn_08014140
    bne .Ll2f_0801415A                     @ high word not zero: separate path
    clz r1, r0                             @ high word zero: r1 = leading zero count of the low word
    lsls r0, r1                            @ shift the leading one up to bit 31
    rsb r1, r1, #0x9d                      @ r1 = 157 - clz (biased exponent minus one)
    @ Common tail: r1 = exponent minus one, r0 = 32-bit window with the leading one in bit 31.
.Ll2f_0801414C:
    lsls r1, r1, #0x17                     @ exponent into bits 30..23
    lsls r2, r0, #0x18                     @ r2 = the 8 discarded mantissa bits, left aligned; C = lowest kept bit
    sbcs r2, r2, #0x80000000               @ round to nearest even: carry = 1 when the discarded bits are above one half, or exactly one half and the kept LSB is 1 (bit 0 of r0 holds the sticky bit of lower words)
    adc r0, r1, r0, lsr #8                 @ r0 = exponent field + mantissa (the leading one adds the +1 of the exponent) + rounding carry
    @ return.
FUNC fn_08014158
    bx lr
    @ High word not zero.
.Ll2f_0801415A:
    clz r2, r1                             @ r2 = n = leading zero count of the high word
    eors r1, r0                            @ r1 = high ^ low
    lsls r0, r2                            @ r0 = low << n (the low bits that stay below the 32-bit window; Z = no such bits)
    rsb r2, r2, #0x20                      @ r2 = 32 - n
    ror r1, r1, r2                         @ r1 = (high ^ low) rotated right by 32 - n
    eor r0, r1, r0                         @ r0 = r1 ^ r0 = (high << n) | (low >> (32 - n)): the top 32 bits of the normalised 64-bit value (no flag change: Z still from the lsls above)
    it ne                                  @ bits shifted out below the window: set the sticky bit 0
    orrne r0, r0, #1
    add r1, r2, #0x9d                      @ r1 = 189 - n: biased exponent minus one for a 64-bit magnitude (157 + 32 - n)
    b .Ll2f_0801414C                       @ continue with the common tail
ENDFUNC fn_08014118

