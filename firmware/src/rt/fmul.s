@ =============================================================================
@ fmul.s - RT: single-precision multiplication
@
@ Port of the v2.05 helper fn_08013090 (the ARM compiler floating-point library multiplication, binary32).
@
@ Calling convention (DESIGN.md 6, exception for RT): a in r0, b in r1, result in r0; r2, r3, r12 and the flags are
@ scratch, r4-r11 and lr are preserved.  The routine is a copy of the v2.05 instruction sequence, re-expressed with
@ symbolic labels, so every register, flag and result bit is the one v2.05 produces.
@
@ Behaviour observed by comparing the original with exact round-to-nearest-even arithmetic over random and edge
@ operands (W2 test, 15 000 random pairs per class, including subnormal operands and subnormal or overflowing results):
@ no difference from IEEE 754 for finite operands.  Zero times infinity, and any NaN operand, give 0xFFFFFFFF (positive
@ result sign) or 0x7FFFFFFF (negative result sign); infinity times a finite non-zero number gives a signed infinity.
@
@ Context: ISR-safe, no memory access, no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08013090 - single-precision multiplication
@ Replaces : 0x08013090 (v2.05 FUN_08013090, the float multiplication helper)
@ In       : r0 = a, r1 = b (binary32 bit patterns)
@ Out      : r0 = a * b, rounded to nearest, ties to even (see the file header for the exceptions)
@ Clobbers : r0-r3, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08013090
    movs r2, #0xff                         @ r2 = 0xFF, exponent mask
    ands r12, r2, r0, lsr #0x17            @ r12 = biased exponent of a (Z when 0)
    ittte ne                               @ a exponent not 0: ...
    andsne r3, r2, r1, lsr #0x17           @ ... r3 = biased exponent of b
    cmpne r12, r2                          @ ... a exponent 255?
    cmpne r3, r2                           @ ... b exponent 255?
    beq .Lfmul_080130FA                    @ an exponent is 0 or 255 (zero, subnormal, infinity, NaN): special path
    add r12, r3                            @ r12 = ea + eb
    lsls r3, r2, #0x1f                     @ r3 = 0x80000000
    eor r2, r0, r1                         @ r2 = a XOR b
    ands r2, r3                            @ r2 = sign of the result
    orr r0, r3, r0, lsl #8                 @ r0 = mantissa of a with the leading one in bit 31 (sign and exponent shifted out)
    orr r1, r3, r1, lsl #8                 @ r1 = mantissa of b with the leading one in bit 31
    @ Multiply the normalised mantissas.  r0, r1 = mantissas with the leading one in bit 31 (also entered from the subnormal paths), r12 = ea + eb (or the adjusted sum), r2 = result sign.
.Lfmul_080130B4:
    umull r3, r0, r1, r0                   @ r0:r3 = r1 * r0 (64-bit product, r0 = high word, r3 = low word)
    lsls r1, r0, #1                        @ r1 = high word << 1: C = bit 63 of the product (set when the product is at least 2^63)
    it cc                                  @ product below 2^63: ...
    lslcc r0, r0, #1                       @ ... normalise the high word by one place to the left
    sbcs r1, r12, #0x7f                    @ r1 = ea + eb - 127 - (1 if the product was normalised by the left shift) = biased result exponent minus one (the leading one of the mantissa adds it back below)
    blt .Lfmul_080130DC                    @ r1 < 0: biased result exponent below 1, subnormal or zero result
    cmp r1, #0xfe                          @ r1 >= 254: biased result exponent 255 or more, signed infinity
    bge .Lfmul_0801315E
    lsrs r3, r3, #1                        @ r3 = low product word >> 1
    orr r1, r2, r1, lsl #0x17              @ r1 = sign + exponent field in place
    orrs r3, r3, r0, lsl #0x18             @ r3 = the bits below the 24-bit mantissa: guard bits of the high word merged into the top of the low word; C = lowest mantissa bit
    sbcs r12, r3, #0x80000000              @ round to nearest even: carry = 1 when the bits below are above one half, or exactly one half and the lowest mantissa bit is 1
    adcs r0, r1, r0, lsr #8                @ r0 = sign and exponent + mantissa (its leading one supplies the +1 of the exponent field) + rounding carry
    bx lr                                  @ return
    @ Result exponent below 1: subnormal result or underflow to zero (r1 = biased exponent minus one, negative or zero).
.Lfmul_080130DC:
    rsbs r12, r1, #8                       @ r12 = 8 - r1: right shift count that denormalises the mantissa
    rsbs r1, r12, #0x20                    @ r1 = 32 - r12
    blt .Lfmul_08013146                    @ shift count above 32: the result is zero
    lsrs r3, r3, #1                        @ r3 = low word >> 1
    lsls r1, r0, r1                        @ r1 = the high-word bits that the denormalising shift discards, left aligned; C = last bit shifted out (the lowest kept bit)
    orrs r3, r1                            @ merge them with the low word bits for the rounding test
    sbcs r1, r3, #0x80000000               @ round to nearest even as above
    lsr r0, r0, r12                        @ r0 = high word >> shift count (denormalised mantissa)
    adcs r0, r2                            @ add the sign and the rounding carry (the exponent field of a subnormal is 0)
    bx lr                                  @ return
    @ Special operands: an exponent is 0 (zero, subnormal) or 255 (infinity, NaN).
.Lfmul_080130FA:
    cmp r12, r2                            @ exponent of a equal 255?
    itt ne                                 @ a not 255: ...
    andne r3, r2, r1, lsr #0x17            @ ... r3 = exponent of b
    cmpne r3, r2                           @ ... b equal 255?
    eor r2, r0, r1                         @ r2 = a XOR b
    and r2, r2, #0x80000000                @ r2 = sign of the result
    beq .Lfmul_0801314A                    @ a or b is infinity/NaN
    lsls r0, r0, #1                        @ r0 = a << 1 (Z when a is +-0)
    beq .Lfmul_08013146                    @ a is zero: the result is a signed zero
    lsls r1, r1, #1                        @ r1 = b << 1
    beq .Lfmul_08013146                    @ b is zero: signed zero
    cbnz r3, .Lfmul_08013130               @ r3 = exponent of b: b normal, then a is the subnormal operand
    cmp r3, r12                            @ both exponents are 0 (r3 = r12 = 0): both subnormal, the product underflows: signed zero
    beq .Lfmul_08013146
    lsls r1, r1, #8                        @ b is subnormal and a is normal: b fraction in bits 30..8 (sign and exponent shifted out)
    clz r3, r1                             @ r3 = leading zero count of the b fraction
    lsls r1, r3                            @ normalise b: the leading one to bit 31
    subs r12, r12, r3                      @ r12 = ea - clz: the exponent sum adjusted for the normalisation of b
    lsls r0, r0, #7                        @ a mantissa: fraction in bits 30..8 ...
    orr r0, r0, #0x80000000                @ ... leading one set in bit 31 (overwrites the exponent bit that is still there)
    b .Lfmul_080130B4                      @ continue with the multiplication
    @ a is the subnormal operand (its exponent is 0), b is normal.
.Lfmul_08013130:
    lsls r0, r0, #8                        @ a fraction in bits 30..8 (sign and exponent shifted out)
    clz r12, r0                            @ r12 = leading zero count of the a fraction
    lsls r0, r0, r12                       @ normalise a: the leading one to bit 31
    subs r12, r3, r12                      @ r12 = eb - clz: the exponent sum adjusted for the normalisation of a
    lsls r1, r1, #7                        @ b mantissa: fraction in bits 30..8 ...
    orr r1, r1, #0x80000000                @ ... leading one set in bit 31
    b .Lfmul_080130B4                      @ continue with the multiplication
    @ Signed zero result (r2 = sign of the result).
.Lfmul_08013146:
    movs r0, r2                            @ r0 = sign bit
    bx lr
    @ An operand is infinity or NaN (r2 = result sign).
.Lfmul_0801314A:
    lsls r0, r0, #1                        @ r0 = a << 1
    beq .Lfmul_08013164                    @ a is zero (zero times infinity or NaN): NaN result
    lsls r1, r1, #1                        @ r1 = b << 1
    beq .Lfmul_08013164                    @ b is zero: NaN result
    cmn r0, #0x1000000                     @ a << 1 + 0x01000000: C = 1 when a << 1 >= 0xFF000000, Z = 1 when it is exactly 0xFF000000 (infinity); "ls" (C = 0 or Z = 1) holds for a finite a or an infinity, not for a NaN
    ite ls                                 @ IT block on ls: then, else (else = opposite condition, tested on the flags as they are at that instruction)
    cmnls r1, #0x1000000                   @ a is infinity or finite: test b the same way
    bhi .Lfmul_08013164                    @ a or b is NaN: NaN result
    @ Signed infinity.
.Lfmul_0801315E:
    orr r0, r2, #0x7f800000                @ r0 = result sign | 0x7F800000
    bx lr
    @ NaN result.
.Lfmul_08013164:
    mvns r0, r2                            @ r0 = NOT sign bit: 0xFFFFFFFF for a positive sign, 0x7FFFFFFF for a negative sign
    bx lr
ENDFUNC fn_08013090

