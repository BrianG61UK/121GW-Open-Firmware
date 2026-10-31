@ =============================================================================
@ fdiv.s - RT: single-precision division
@
@ Port of the v2.05 helper fn_08012F94 (the ARM compiler floating-point library division, binary32; the quotient is
@ formed with the hardware udiv in three 8-bit digits).
@
@ Calling convention (DESIGN.md 6, exception for RT): a (dividend) in r0, b (divisor) in r1, result in r0; r2, r3,
@ r12 and the flags are scratch, r4-r11 and lr are preserved.  The routine is a copy of the v2.05 instruction
@ sequence, re-expressed with symbolic labels, so every register, flag and result bit is the one v2.05 produces.
@
@ Behaviour observed by comparing the original with exact round-to-nearest-even arithmetic over random and edge
@ operands (W2 test, 15 000 random pairs per class, including subnormal operands and results):
@   - a result whose biased exponent is 254 (the largest finite exponent) is returned as a signed infinity: the
@     compare at 0x08012FEA is "ge 254" where IEEE needs "ge 255" (example 0xC23C8DC1 / 0x828CAB39 gives 0x7F800000,
@     IEEE 0x7F2B9283).  Exponents below 254, subnormal operands and subnormal results gave the IEEE result;
@   - special operands: x / 0 gives a signed infinity, 0 / x a signed zero, 0 / 0 and infinity / infinity give
@     0xFFFFFFFF; infinity / finite keeps the infinity with the sign of the quotient; finite / infinity gives a signed
@     zero; a NaN dividend with a finite divisor is returned with its sign XOR the divisor sign, a NaN divisor is
@     returned unchanged.
@
@ Context: ISR-safe, no memory access, no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08012F94 - single-precision division
@ Replaces : 0x08012F94 (v2.05 FUN_08012f94, the float division helper)
@ In       : r0 = a (dividend), r1 = b (divisor), binary32 bit patterns
@ Out      : r0 = a / b, rounded to nearest, ties to even (see the file header for the exceptions)
@ Clobbers : r0-r3, r12, flags (r4 and lr are saved and restored)
@ Context  : ISR-safe (stack use only)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08012F94
    push {r4, lr}                          @ save r4 and the return address
    movs r3, #0xff                         @ r3 = 0xFF, exponent mask
    ands r4, r3, r0, lsr #0x17             @ r4 = biased exponent of a (Z when 0)
    ittte ne                               @ IT block on ne: then, then, then, else (else = opposite condition, tested on the flags as they are at that instruction)
    andsne r2, r3, r1, lsr #0x17           @ a exponent not 0: r2 = biased exponent of b ...
    cmpne r4, r3                           @ ... a exponent 255?
    cmpne r2, r3                           @ ... b exponent 255?
    beq .Lfdiv_0801301C                    @ an exponent is 0 or 255 (zero, subnormal, infinity, NaN): special path
    subs r4, r4, r2                        @ r4 = ea - eb
    lsls r2, r3, #0x1f                     @ r2 = 0x80000000
    eor r3, r0, r1                         @ r3 = a XOR b
    ands r3, r2                            @ r3 = sign of the quotient
    orr r1, r2, r1, lsl #8                 @ r1 = divisor mantissa with the leading one in bit 31
    orr r0, r2, r0, lsl #8                 @ r0 = dividend mantissa with the leading one in bit 31
    @ Division of the aligned mantissas (also entered from the subnormal paths).  r0 = dividend mantissa, r1 = divisor mantissa (leading one in bit 31), r4 = exponent difference, r3 = quotient sign.
.Lfdiv_08012FBA:
    subs r2, r0, r1                        @ r2 = ma - mb, C = (ma >= mb)
    itt cc                                 @ dividend below divisor: the quotient is below 1 ...
    subcc r4, r4, #1                       @ ... lower the exponent by one
    addcc r2, r1, r2, lsl #1               @ ... r2 = mb + 2 * (ma - mb) = 2 * ma - mb, the remainder for the doubled dividend
    lsrs r1, r1, #8                        @ r1 = divisor as a 24-bit integer
    udiv lr, r2, r1                        @ first quotient digit (0..255): lr = r2 / r1
    mls r2, r1, lr, r2                     @ r2 = remainder
    lsls r2, r2, #8                        @ next digit: remainder * 256
    udiv r0, r2, r1                        @ second quotient digit: r0 = r2 / r1
    mls r2, r1, r0, r2                     @ r2 = remainder
    bfi r0, lr, #8, #8                     @ r0 = first digit : second digit (bits 15..8 and 7..0)
    lsls r2, r2, #8                        @ remainder * 256
    udiv lr, r2, r1                        @ third quotient digit in lr (its remainder is only needed on the subnormal path)
    orr r0, lr, r0, lsl #8                 @ r0 = 24-bit fraction of the quotient (three digits)
    adds r4, #0x7f                         @ r4 = biased exponent of the quotient (ea - eb + 127, minus one if ma < mb)
    ble .Lfdiv_08012FF8                    @ r4 <= 0: subnormal result or underflow
    cmp r4, #0xfe                          @ r4 >= 254: signed infinity (v2.05 limit; IEEE needs 255, see the file header)
    bge .Lfdiv_08013038
    orrs r0, r3, r0, lsr #1                @ r0 = sign | fraction >> 1; C = bit shifted out (the round bit; an exact tie cannot occur for 24-bit mantissas)
    adcs r0, r0, r4, lsl #0x17             @ r0 = result = sign, fraction and exponent field (r4 << 23) plus the round bit
    pop {r4, pc}                           @ return
    @ Subnormal quotient or underflow (r4 <= 0).
.Lfdiv_08012FF8:
    rsbs r4, r4, #2                        @ r4 = 2 - r4: right shift count for the 25-bit significand
    mls r2, r1, lr, r2                     @ r2 = remainder after the third digit
    orr r1, r0, #0x1000000                 @ r1 = significand with its leading one in bit 24
    cmp r4, #0x19                          @ shift count above 25: the result is zero ...
    bgt .Lfdiv_08013044                    @ ... a signed zero
    lsr r0, r1, r4                         @ r0 = significand >> r4 (denormalised mantissa)
    rsb r4, r4, #0x20                      @ r4 = 32 - r4
    lsls r1, r4                            @ r1 = the significand bits that were shifted out, left aligned; C = lowest kept bit
    orrs r1, r2                            @ merge the remainder (sticky)
    sbcs r2, r1, #0x80000000               @ round to nearest even: carry = 1 when the discarded bits are above one half, or exactly one half and the lowest kept bit is 1
    adcs r0, r3                            @ add the rounding carry and the sign (the exponent field of a subnormal is 0)
    pop {r4, pc}                           @ return
    @ At least one exponent is 0 or 255.
.Lfdiv_0801301C:
    cmp r4, r3                             @ a exponent 255?
    itte ne                                @ a not 255: r2 = exponent of b ...
    andne r2, r3, r1, lsr #0x17
    cmpne r2, r3                           @ ... b exponent 255?
    beq .Lfdiv_08013048                    @ a or b is infinity or NaN
    eor lr, r0, r1                         @ lr = a XOR b
    and r3, lr, #0x80000000                @ r3 = sign of the quotient
    lsls r0, r0, #1                        @ r0 = a << 1 (Z when a is +-0)
    beq .Lfdiv_0801303E                    @ a is zero
    lsls r1, r1, #1                        @ r1 = b << 1 (Z when b is +-0)
    bne .Lfdiv_08013066                    @ b is not zero: one of the operands is subnormal
    @ Division by zero (or a result that overflowed): signed infinity.
.Lfdiv_08013038:
    orr r0, r3, #0x7f800000                @ r0 = sign | 0x7F800000
    pop {r4, pc}
    @ a is zero.
.Lfdiv_0801303E:
    lsls r1, r1, #1                        @ Z = (b is +-0)
    @ Zero or NaN result: r3 = sign of the quotient, or 0xFFFFFFFF when Z is set (0 / 0 and infinity / infinity).
.Lfdiv_08013040:
    it eq                                  @ Z set: ...
    mvneq r3, r2                           @ ... r3 = NOT r2 = 0xFFFFFFFF (r2 is 0 here)
    @ Return r3.
.Lfdiv_08013044:
    movs r0, r3                            @ r0 = r3
    pop {r4, pc}
    @ a or b has exponent 255.
.Lfdiv_08013048:
    cmp r4, r3                             @ a exponent 255?
    bne .Lfdiv_08013058                    @ a not 255: b is the infinity/NaN
    subs r2, r2, r3                        @ r2 = eb - 255; Z when both are 255
    beq .Lfdiv_08013040                    @ both infinity/NaN: 0xFFFFFFFF
    and r1, r1, #0x80000000                @ r1 = sign of b
    eors r0, r1                            @ r0 = a with its sign XOR the sign of b (infinity or NaN dividend over a finite divisor)
    pop {r4, pc}                           @ return
    @ b is infinity or NaN, a is finite.
.Lfdiv_08013058:
    lsls r2, r1, #9                        @ Z = mantissa of b is zero (b is infinity)
    itee ne                                @ IT block on ne: then, else, else (else = opposite condition, tested on the flags as they are at that instruction)
    movne r0, r1                           @ b is a NaN: return b
    eoreq r0, r1                           @ b is infinity: r0 = a XOR b ...
    andeq r0, r0, #0x80000000              @ ... only the sign bit: signed zero
    pop {r4, pc}                           @ return
    @ Both operands non-zero, none is infinity or NaN, at least one is subnormal.
.Lfdiv_08013066:
    cbnz r2, .Lfdiv_0801307C               @ r2 = exponent of b: non-zero means b is normal and a is the subnormal one
    lsls r1, r1, #8                        @ b subnormal: fraction in bits 30..8
    clz r2, r1                             @ r2 = leading zero count of the b fraction
    lsls r1, r2                            @ normalise b: the leading one to bit 31
    cbz r4, .Lfdiv_08013084                @ a exponent 0 as well: both subnormal
    adds r4, r4, r2                        @ r4 = ea + clz(b): the exponent difference for the normalised divisor
    lsls r0, r0, #7                        @ a mantissa: fraction ...
    orr r0, r0, #0x80000000                @ ... with the leading one set in bit 31
    b .Lfdiv_08012FBA                      @ divide
    @ a is subnormal, b is normal (r2 = eb).
.Lfdiv_0801307C:
    lsls r1, r1, #7                        @ b mantissa: fraction ...
    orr r1, r1, #0x80000000                @ ... with the leading one set in bit 31
    negs r2, r2                            @ r2 = -eb
    @ Normalise the subnormal dividend (also entered when both are subnormal, with r2 = clz(b)).
.Lfdiv_08013084:
    lsls r0, r0, #8                        @ a fraction in bits 30..8
    clz r4, r0                             @ r4 = leading zero count of a
    lsls r0, r4                            @ normalise a: the leading one to bit 31
    subs r4, r2, r4                        @ r4 = exponent difference of the normalised operands
    b .Lfdiv_08012FBA                      @ divide
ENDFUNC fn_08012F94

