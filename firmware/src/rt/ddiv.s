@ =============================================================================
@ ddiv.s - RT: double-precision division
@
@ Port of the v2.05 helper fn_0801B874 (the ARM compiler floating-point library division, binary64; the quotient is
@ produced in five digits of 11, 11, 10, 11 and 11 bits, each from the hardware udiv of the top remainder bits by the
@ high word of the divisor significand, followed by a one-step correction).
@
@ Calling convention (DESIGN.md 6, exception for RT): a (dividend) in r0 (low word) : r1 (high word), b (divisor) in
@ r2 : r3, result in r0 : r1; r12 and the flags are scratch, r4-r11 and lr are preserved (r4-r8 and lr are pushed).
@ The routine is a copy of the v2.05 instruction sequence, re-expressed with symbolic labels, so every register, flag
@ and result bit is the one v2.05 produces.
@
@ Behaviour observed by comparing the original with exact round-to-nearest-even arithmetic over random and edge
@ operands (W2 test, 15 000 random pairs per class): no difference from IEEE 754 for normal results, overflowing
@ results and subnormal operands; a subnormal quotient can differ (example 0x482E3C0455B2DB / 0xC37112C5AD632FB4
@ gives 0x8000000000000000, IEEE 0x8000000000000001: the rounding of the shifted quotient uses the carry of a
@ different shift than the rounding bit).  Special operands: x / 0 gives a signed infinity, 0 / x a signed zero,
@ 0 / 0, infinity / infinity and every NaN operand give r0 = 0, r1 = 0xFFFFFFFF, infinity / finite gives a signed
@ infinity, finite / infinity a signed zero.
@
@ Context: ISR-safe (stack use only), no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0801B874 - double-precision division
@ Replaces : 0x0801B874 (v2.05 FUN_0801b874, the double division helper)
@ In       : r0:r1 = a (dividend), r2:r3 = b (divisor), binary64 bit patterns, low word first
@ Out      : r0:r1 = a / b, rounded to nearest, ties to even (see the file header for the exceptions)
@ Clobbers : r0-r3, r12, flags (r4-r8 and lr are saved and restored)
@ Context  : ISR-safe (stack use only)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801B874
    stmdb sp!, {r4, r5, r6, r7, r8, lr}    @ save r4-r8 and the return address
    movw r5, #0x7ff                        @ r5 = 0x7FF, exponent mask
    eor r12, r1, r3                        @ r12 = a_hi XOR b_hi
    and r12, r12, #0x80000000              @ r12 = sign of the quotient
    ands r4, r5, r1, lsr #0x14             @ r4 = biased exponent of a (Z when 0)
    ittte ne                               @ IT block on ne: then, then, then, else (else = opposite condition, tested on the flags as they are at that instruction)
    andsne r7, r5, r3, lsr #0x14           @ a exponent not 0: r7 = biased exponent of b ...
    cmpne r4, r5                           @ ... a exponent 0x7FF?
    cmpne r7, r5                           @ ... b exponent 0x7FF?
    beq .Lddiv_0801BA68                    @ an exponent is 0 or 0x7FF: special path
    sbcs r4, r7                            @ r4 = ea - eb - 1 (the carry is clear here)
    @ Division of the significands (also entered from the subnormal paths).  r1:r0 = a, r3:r2 = b (high words still hold sign and exponent), r4 = exponent difference, r12 = quotient sign.
.Lddiv_0801B896:
    ubfx r1, r1, #0, #0x14                 @ r1 = fraction bits 51..32 of a
    ubfx r3, r3, #0, #0x14                 @ r3 = fraction bits 51..32 of b
    subs r0, r0, r2                        @ r1:r0 = fraction of a - fraction of b (64-bit)
    sbcs r1, r3
    orr r3, r3, #0x100000                  @ r3:r2 = significand of b with the leading one (bit 52)
    bcs .Lddiv_0801B8B2                    @ fraction of a >= fraction of b: quotient >= 1
    subs r4, r4, #1                        @ quotient < 1: exponent - 1 ...
    lsls r0, r0, #1                        @ ... remainder = 2 * (fraction a - fraction b) + significand b = 2 * (significand a) - (significand b)
    adcs r1, r1
    adds r0, r0, r2
    adcs r1, r3
    @ Digit 1 (11 bits).  r1:r0 = remainder, r3:r2 = divisor significand.
.Lddiv_0801B8B2:
    lsls r1, r1, #0xb                      @ form the top 32 bits of (remainder << 11)
    orr r1, r1, r0, lsr #0x15
    udiv r6, r1, r3                        @ r6 = estimate of the digit: top bits / divisor high word
    mls r1, r3, r6, r1                     @ r1 = remainder of that division
    umull r7, r5, r2, r6                   @ r5:r7 = divisor low word * digit
    rsbs r0, r7, r0, lsl #0xb              @ r0 = (remainder low word << 11) - r7
    sbcs r1, r5                            @ r1 = r1 - r5 - borrow: the true remainder, negative when the digit was too large
    bcs .Lddiv_0801B8D2                    @ no correction needed
    subs r6, r6, #1                        @ digit too large: digit - 1 ...
    adds r0, r0, r2                        @ ... add the divisor back
    adcs r1, r3
    @ Digit 2 (11 bits).
.Lddiv_0801B8D2:
    lsls r1, r1, #0xb                      @ top 32 bits of (remainder << 11)
    orr r1, r1, r0, lsr #0x15
    udiv lr, r1, r3                        @ lr = digit estimate
    mls r1, r3, lr, r1                     @ r1 = remainder of the division
    umull r7, r5, r2, lr                   @ r5:r7 = divisor low word * digit
    rsbs r0, r7, r0, lsl #0xb              @ r0 = (remainder low word << 11) - r7
    sbcs r1, r5                            @ true remainder
    bcs .Lddiv_0801B8F4                    @ no correction needed
    sub lr, lr, #1                         @ digit too large: digit - 1 ...
    adds r0, r0, r2                        @ ... add the divisor back
    adcs r1, r3
    @ Digit 3 (10 bits).
.Lddiv_0801B8F4:
    lsls r1, r1, #0xa                      @ top 32 bits of (remainder << 10)
    orr r1, r1, r0, lsr #0x16
    lsls r6, r6, #0x15                     @ r6 = digit 1 << 21
    orr lr, r6, lr, lsl #0xa               @ lr = digit 1 << 21 | digit 2 << 10
    udiv r6, r1, r3                        @ r6 = digit estimate
    mls r1, r3, r6, r1                     @ r1 = remainder of the division
    umull r7, r5, r2, r6                   @ r5:r7 = divisor low word * digit
    rsbs r0, r7, r0, lsl #0xa              @ r0 = (remainder low word << 10) - r7
    sbcs r1, r5                            @ true remainder
    bcs .Lddiv_0801B91A                    @ no correction needed
    subs r6, r6, #1                        @ digit too large: digit - 1 ...
    adds r0, r0, r2                        @ ... add the divisor back
    adcs r1, r3
    @ Digit 4 (11 bits).
.Lddiv_0801B91A:
    lsls r1, r1, #0xb                      @ top 32 bits of (remainder << 11)
    orr r1, r1, r0, lsr #0x15
    orr lr, lr, r6                         @ lr |= digit 3: lr = digits 1..3 (32 quotient bits)
    udiv r6, r1, r3                        @ r6 = digit estimate
    mls r1, r3, r6, r1                     @ r1 = remainder of the division
    umull r7, r5, r2, r6                   @ r5:r7 = divisor low word * digit
    rsbs r0, r7, r0, lsl #0xb              @ r0 = (remainder low word << 11) - r7
    sbcs r1, r5                            @ true remainder
    bcs .Lddiv_0801B93E                    @ no correction needed
    subs r6, r6, #1                        @ digit too large: digit - 1 ...
    adds r0, r0, r2                        @ ... add the divisor back
    adcs r1, r3
    @ Digit 5 (11 bits) with the sticky bit.
.Lddiv_0801B93E:
    lsls r1, r1, #0xb                      @ top 32 bits of (remainder << 11)
    orr r1, r1, r0, lsr #0x15
    udiv r7, r1, r3                        @ r7 = digit estimate
    mls r1, r3, r7, r1                     @ r1 = remainder of the division
    umull r3, r5, r2, r7                   @ r5:r3 = divisor low word * digit
    rsbs r0, r3, r0, lsl #0xb              @ r0 = (remainder low word << 11) - r3
    sbcs r1, r5                            @ true remainder (borrow when the digit was too large)
    sbc r7, r7, #0                         @ digit -= borrow
    ite eq                                 @ remainder high word zero: test the low word ...
    tsteq r0, r0                           @ ... Z when the remainder is zero
    orrne r7, r7, #1                       @ remainder not zero: set the sticky bit 0 of the digit
    bfi r7, r6, #0xb, #0xb                 @ r7 = digit 5 | digit 4 << 11
    mov r1, lr, lsr #0xc                   @ r1 = digits 1..3 >> 12: fraction bits 51..32 of the quotient
    lsrs r0, r7, #2                        @ r0 = digits 4 and 5 >> 2; C = the round bit
    adds r4, r4, #0x400                    @ r4 = ea - eb - 1 + 0x400 = biased exponent of the quotient
    ble .Lddiv_0801B99C                    @ r4 <= 0: subnormal quotient or underflow
    lsls r5, r7, #0x1e                     @ r5 = the round and sticky bits, left aligned; C = lowest fraction bit
    sbcs r2, r5, #0x80000000               @ round to nearest even: carry = 1 when the round and sticky bits are above one half, or exactly one half and the lowest fraction bit is 1
    adcs r0, r0, lr, lsl #0x14             @ low word = digits 4 and 5 >> 2 + (digits 1..3 << 20) + carry
    adcs r1, r1, r4, lsl #0x14             @ high word = fraction + exponent << 20 + carry
    cmn r1, #0x100000                      @ N set when the exponent field overflowed past 0x7FE
    itt pl                                 @ no overflow: ...
    orrpl r1, r1, r12                      @ ... add the sign ...
    ldmiapl sp!, {r4, r5, r6, r7, r8, pc}  @ ... and return
    orr r1, r12, #0xff00000                @ overflow: sign | 0x7FF00000 ...
    orr r1, r1, #0x70000000
    movs r0, #0                            @ ... low word 0 (signed infinity)
    ldmia sp!, {r4, r5, r6, r7, r8, pc}
    @ Exponent field below 1: subnormal quotient or underflow (r4 = biased exponent, <= 0).
.Lddiv_0801B99C:
    lsls r5, r7, #0x1e                     @ r5 = the round and sticky bits, left aligned
    lsrs r5, r5, #1                        @ r5 >>= 1; C = bit shifted out
    orr r0, r0, lr, lsl #0x14              @ low word complete
    orr r1, r1, #0x100000                  @ set the leading one of the significand
    rsbs r4, r4, #1                        @ r4 = 1 - exponent = right shift count
    subs r6, r4, #0x20                     @ r6 = count - 32
    bge .Lddiv_0801B9C8                    @ count >= 32: separate path
    rsb r6, r4, #0x20                      @ r6 = 32 - count
    movs r2, r0                            @ r2 = low word (bits shifted out of it)
    lsrs r0, r4                            @ low word >> count
    lsl r3, r1, r6                         @ r3 = high-word bits that move into the low word
    lsrs r1, r4                            @ high word >> count
    orrs r0, r3                            @ merged low word
    lsls r2, r6                            @ r2 = bits shifted out of the low word, left aligned
    orrs r5, r2                            @ merged into the round and sticky word
    b .Lddiv_0801B9E6                      @ round and pack
    @ Right shift count 32 or more (r6 = count - 32).
.Lddiv_0801B9C8:
    cmp r4, #0x34                          @ count > 52: the result is zero
    bgt .Lddiv_0801B9F6
    rsb r4, r6, #0x20                      @ r4 = 32 - r6
    orr r5, r5, r0, lsl #1                 @ round and sticky word with the low word bits
    lsrs r5, r5, #1                        @ ... shifted back by one place
    lsr r2, r0, r6                         @ r2 = low word >> r6
    orrs r5, r2                            @ merged
    lsr r0, r1, r6                         @ low word = high word >> r6
    lsls r1, r4                            @ r1 = high-word bits shifted out
    orrs r5, r1                            @ merged into the round and sticky word
    movs r1, #0                            @ high word 0
    @ Round and pack a subnormal quotient.
.Lddiv_0801B9E6:
    sbcs r2, r5, #0x80000000               @ round to nearest even
    adcs r0, r0, #0                        @ round the low word
    adcs r1, r1, r12                       @ add the sign (the exponent field of a subnormal is 0) and the carry
    ldmia sp!, {r4, r5, r6, r7, r8, pc}
    @ Underflow to zero: signed zero.
.Lddiv_0801B9F6:
    movs r0, #0
    movs r1, r12
    ldmia sp!, {r4, r5, r6, r7, r8, pc}
    @ Both operands non-zero, none is infinity/NaN, at least one is subnormal (r7 = eb, r4 = ea).
.Lddiv_0801BA00:
    cbnz r7, .Lddiv_0801BA36               @ eb not zero: b is normal and a is the subnormal operand
    adds r2, r2, r2                        @ b subnormal: shift the 64-bit significand left by one ...
    adcs r3, r3                            @ ... (second word)
    clz r7, r3                             @ r7 = leading zero count of b
    itt eq                                 @ high word zero: add the leading zero count of the low word
    clzeq r6, r2
    addeq r7, r7, r6
    subs r7, #0xb                          @ r7 = shift that puts the leading one at bit 52
    subs r6, r7, #0x20                     @ r6 = shift - 32
    iteee cs                               @ shift >= 32: high word = low word << (shift - 32) ...
    lslcs r3, r2, r6
    lslcc r3, r7                           @ ... shift < 32: high word << shift ...
    rsbcc r6, r7, #0x20
    lsrcc r6, r2, r6                       @ ... plus the bits from the low word
    it cc                                  @ IT block on cc: 1 instruction run only when cc
    orrcc r3, r6
    lsls r2, r7                            @ low word << shift
    cbz r4, .Lddiv_0801BA38                @ ea = 0 too (both subnormal): normalise a below
    adds r4, r4, r7                        @ r4 = ea + shift
    subs r4, r4, #1                        @ r4 -= 1
    b .Lddiv_0801B896                      @ divide
    @ b is normal (r7 = eb), a is subnormal.
.Lddiv_0801BA36:
    negs r7, r7                            @ r7 = -eb
    @ Normalise the subnormal dividend (also entered when both are subnormal, with r7 = shift of b).
.Lddiv_0801BA38:
    bics r1, r1, #0x80000000               @ clear the sign of a_hi
    clz r4, r1                             @ r4 = leading zero count of a
    itt eq                                 @ high word zero: add the leading zero count of the low word
    clzeq r6, r0
    addeq r4, r4, r6
    subs r4, #0xb                          @ r4 = shift that puts the leading one at bit 52
    subs r6, r4, #0x20                     @ r6 = shift - 32
    iteee cs                               @ shift >= 32: high word = low word << (shift - 32) ...
    lslcs r1, r0, r6
    lslcc r1, r4                           @ ... shift < 32: high word << shift ...
    rsbcc r6, r4, #0x20
    lsrcc r6, r0, r6                       @ ... plus the bits from the low word
    it cc                                  @ IT block on cc: 1 instruction run only when cc
    orrcc r1, r6
    lsls r0, r4                            @ low word << shift
    subs r4, r7, r4                        @ r4 = exponent difference of the normalised operands
    b .Lddiv_0801B896                      @ divide
    @ An exponent is 0 or 0x7FF.
.Lddiv_0801BA68:
    cmp r4, r5                             @ a exponent 0x7FF?
    itte ne                                @ IT block on ne: then, then, else (else = opposite condition, tested on the flags as they are at that instruction)
    andne r7, r5, r3, lsr #0x14            @ a is not 0x7FF: r7 = biased exponent of b ...
    cmpne r7, r5                           @ ... b exponent 0x7FF?
    beq .Lddiv_0801BA9E                    @ a or b is infinity/NaN
    orrs r6, r0, r1, lsl #1                @ r6 = a_lo | a_hi << 1 (Z when a is zero)
    itt ne                                 @ IT block on ne: 2 instructions run only when ne
    orrsne r6, r2, r3, lsl #1              @ a not zero: r6 = b_lo | b_hi << 1 (Z when b is zero)
    bne .Lddiv_0801BA00                    @ both non-zero: one operand is subnormal
    orrs r7, r0, r1, lsl #1                @ Z = a is zero
    mov r0, r6                             @ r0 = r6 = 0 (a or b is zero)
    mov r1, r12                            @ r1 = sign of the quotient
    itt ne                                 @ a not zero (so b is zero): ...
    orrne r1, r1, r5, lsl #0x14            @ ... r1 = sign | 0x7FF00000 (division by zero: signed infinity) ...
    ldmiane sp!, {r4, r5, r6, r7, r8, pc}  @ ... and return
    orrs r12, r2, r3, lsl #1               @ a is zero: Z = b is zero
    it eq                                  @ 0 / 0: r1 = NOT r0 = 0xFFFFFFFF (otherwise r1 = sign: signed zero)
    mvneq r1, r0
    ldmia sp!, {r4, r5, r6, r7, r8, pc}
    @ a or b has exponent 0x7FF.
.Lddiv_0801BA9E:
    movs r0, #0                            @ r0 = 0 (low word of every result below)
    mov r6, #0x200000                      @ r6 = 0x00200000
    cmn r6, r1, lsl #1                     @ flags of a: C = 1 when a is infinity/NaN, Z = 1 when its high mantissa bits are zero as well (infinity-like)
    it ls                                  @ a is finite or infinity-like (C = 0 or Z = 1): ...
    cmnls r6, r3, lsl #1                   @ ... take the flags of b instead (a NaN a skips this and keeps its own flags)
    it eq                                  @ flags say "infinity-like" (Z = 1): ...
    cmneq r6, r1, lsl #1                   @ ... repeat the test for a, so that C reports a again
    itt cs                                 @ C set (a NaN, b NaN, or infinity / infinity): ...
    mvncs r1, r0                           @ ... r1 = 0xFFFFFFFF ...
    bcs .Lddiv_0801BAC6                    @ ... and return (r0 = 0)
    cmn r6, r3, lsl #1                     @ a is finite (b is the infinity/NaN-like one) or a is an infinity and b is finite: flags of b
    ite eq                                 @ b is an infinity (Z): finite / infinity is a signed zero, r1 = sign
    moveq r1, r12
    orrne r1, r12, r5, lsl #0x14           @ otherwise (a infinity, b finite): r1 = sign | 0x7FF00000, a signed infinity
    @ Return.
.Lddiv_0801BAC6:
    ldmia sp!, {r4, r5, r6, r7, r8, pc}
ENDFUNC fn_0801B874

