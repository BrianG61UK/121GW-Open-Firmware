@ =============================================================================
@ dmul.s - RT: double-precision multiplication
@
@ Port of the v2.05 helper fn_0801BB64 (the ARM compiler floating-point library multiplication, binary64; the 106-bit
@ significand product is formed from four umull/umlal products).
@
@ Calling convention (DESIGN.md 6, exception for RT): a in r0 (low word) : r1 (high word), b in r2 : r3, result in
@ r0 : r1; r12 and the flags are scratch, r4-r11 and lr are preserved (r4, r5, r7 and lr are pushed; lr is used as a
@ scratch register inside).  The routine is a copy of the v2.05 instruction sequence, re-expressed with symbolic
@ labels, so every register, flag and result bit is the one v2.05 produces.
@
@ Behaviour observed by comparing the original with exact round-to-nearest-even arithmetic over random and edge
@ operands (W2 test, 15 000 random pairs per class, including subnormal operands and subnormal or overflowing
@ results): no difference from IEEE 754 for finite operands.  A zero times an infinity gives r1 = 0xFFFFFFFF with r0
@ left as the low word of a (0 for a zero or an infinity); a NaN operand is returned with the high word of the NaN operand (b is
@ looked at first) and the low word of a, i.e. not necessarily the NaN's own low word; infinity times a finite
@ non-zero number gives a signed infinity.
@
@ Context: ISR-safe (stack use only), no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0801BB64 - double-precision multiplication
@ Replaces : 0x0801BB64 (v2.05 FUN_0801bb64, the double multiplication helper)
@ In       : r0:r1 = a, r2:r3 = b (binary64 bit patterns, low word first)
@ Out      : r0:r1 = a * b, rounded to nearest, ties to even (see the file header for the NaN and zero cases)
@ Clobbers : r0-r3, r12, flags (r4, r5, r7, lr are saved and restored)
@ Context  : ISR-safe (stack use only)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801BB64
    push {r4, r5, r7, lr}                  @ save r4, r5, r7 and the return address (lr is used as a scratch register below)
    eor r12, r1, r3                        @ r12 = a_hi XOR b_hi
    and r12, r12, #0x80000000              @ r12 = sign of the result
    movw r5, #0x7ff                        @ r5 = 0x7FF, exponent mask
    ands r4, r5, r1, lsr #0x14             @ r4 = biased exponent of a (Z when 0)
    ittte ne                               @ IT block on ne: then, then, then, else (else = opposite condition, tested on the flags as they are at that instruction)
    andsne r7, r5, r3, lsr #0x14           @ a exponent not 0: r7 = biased exponent of b ...
    cmpne r4, r5                           @ ... a exponent 0x7FF?
    cmpne r7, r5                           @ ... b exponent 0x7FF?
    beq .Ldmul_0801BBF6                    @ an exponent is 0 or 0x7FF (zero, subnormal, infinity, NaN): special path
    adds r4, r4, r7                        @ r4 = ea + eb
    bic r3, r3, r5, lsl #0x15              @ clear the sign and exponent bits of the high word of b
    orr r3, r3, #0x100000                  @ set the leading one: r3:r2 = significand of b (53 bits)
    @ Normalised operands.  r3:r2 = significand of b with the leading one in bit 52, r1:r0 = a (high word still holds sign and exponent), r4 = exponent sum, r12 = result sign.
.Ldmul_0801BB8C:
    lsls r1, r1, #0xb                      @ a high word: mantissa bits shifted up ...
    orr r1, r1, #0x80000000                @ ... leading one in bit 31
    orr lr, r1, r0, lsr #0x15              @ lr = high word of (significand of a << 11): leading one in bit 63 of lr:r7
    lsls r7, r0, #0xb                      @ r7 = low word of (significand of a << 11)
    @ Multiply lr:r7 (a significand << 11) by r3:r2 (b significand).  Also entered from the subnormal paths.
.Ldmul_0801BB98:
    movs r1, r2                            @ r1 = b_lo
    umull r0, r2, r7, r2                   @ r2:r0 = a_lo * b_lo (r2 = high word, r0 = low word)
    cmp r0, #0                             @ Z = the lowest word of the 128-bit product is zero (it only matters as a sticky bit)
    mov r0, #0                             @ r0 = 0
    umlal r2, r0, lr, r1                   @ r0:r2 += a_hi * b_lo
    mov r1, #0                             @ r1 = 0
    umlal r2, r1, r3, r7                   @ r1:r2 += b_hi * a_lo
    it ne                                  @ lowest product word was not zero: ...
    orrne r2, r2, #1                       @ ... set the sticky bit 0 of r2
    adds r0, r0, r1                        @ add the two partial sums that went into r0 and r1
    movs r1, #0                            @ r1 = carry of that addition
    adcs r1, r1
    umlal r0, r1, r3, lr                   @ r1:r0 += b_hi * a_hi: product words r1 (bits 127..96), r0 (95..64), r2 (63..32)
    sub r4, r4, #0x400                     @ r4 = ea + eb - 0x400
    lsls r7, r1, #0xc                      @ C = bit 20 of r1: the product's leading one is in bit 116 (set) or bit 115
    bcs .Ldmul_0801BBCE                    @ leading one in bit 116: no shift
    lsls r2, r2, #1                        @ leading one in bit 115: shift the product left by one place ...
    adcs r0, r0                            @ ... (r0)
    adcs r1, r1                            @ ... (r1)
    @ Exponent adjust and rounding (entered from both normalisation cases).
.Ldmul_0801BBCE:
    adcs r4, r4, #1                        @ r4 = ea + eb - 0x400 + 1 + C = biased exponent of the result
    ble .Ldmul_0801BCAE                    @ r4 <= 0: subnormal result or underflow
    lsrs r7, r0, #1                        @ C = lowest bit of the 52-bit fraction (low word)
    sbcs r2, r2, #0x80000000               @ round to nearest even: carry = 1 when the bits below (r2) are above one half, or exactly one half and the lowest fraction bit is 1
    adcs r0, r0, #0                        @ round the low word
    adcs r1, r1, r4, lsl #0x14             @ r1 = fraction high bits (with the leading one) + exponent << 20 + carry
    sub r1, r1, #0x100000                  @ take the leading one out again; N set when the exponent overflowed past 0x7FE
    itt pl                                 @ no overflow: ...
    orrpl r1, r1, r12                      @ ... add the sign ...
    poppl {r4, r5, r7, pc}                 @ ... and return
    orr r1, r12, r5, lsl #0x14             @ overflow: sign | 0x7FF00000 ...
    movs r0, #0                            @ ... low word 0 (signed infinity)
    pop {r4, r5, r7, pc}
    @ An exponent is 0 or 0x7FF.
.Ldmul_0801BBF6:
    and r7, r5, r3, lsr #0x14              @ r7 = exponent of b
    cmp r4, r5                             @ a exponent 0x7FF?
    ite ne                                 @ IT block on ne: then, else (else = opposite condition, tested on the flags as they are at that instruction)
    cmpne r7, r5                           @ a not 0x7FF: b exponent 0x7FF?
    beq .Ldmul_0801BC86                    @ a or b is infinity/NaN
    orrs lr, r0, r1, lsl #1                @ lr = a << 1 (Z when a is +-0)
    itt ne                                 @ IT block on ne: 2 instructions run only when ne
    orrsne lr, r2, r3, lsl #1              @ a not zero: lr = b << 1 (Z when b is +-0)
    bne .Ldmul_0801BC14                    @ neither is zero: one operand is subnormal
    @ Signed zero result.
.Ldmul_0801BC0E:
    mov r1, r12                            @ r1 = result sign
    movs r0, #0                            @ r0 = 0
    @ Return.
.Ldmul_0801BC12:
    pop {r4, r5, r7, pc}
    @ Both operands non-zero, none is infinity/NaN, at least one is subnormal (r7 = eb).
.Ldmul_0801BC14:
    tst r4, r4                             @ Z = (ea is 0)
    add r4, r7                             @ r4 = ea + eb
    bne .Ldmul_0801BC52                    @ a normal (b subnormal): normalise b below
    movs lr, r7                            @ a subnormal: lr = eb
    beq .Ldmul_0801BC0E                    @ eb = 0 as well: both subnormal, the product underflows to a signed zero
    lsls r1, r1, #0xc                      @ high mantissa bits of a, Z when they are all zero
    ittt eq                                @ high bits zero: ...
    moveq r1, r0                           @ ... move the low word to the high word ...
    moveq r0, #0                           @ ... low word 0
    subeq lr, lr, #0x14                    @ ... and account for the 32-bit move (-20 in the exponent sum)
    clz r7, r1                             @ r7 = leading zero count of the mantissa word
    sub r4, lr, r7                         @ r4 = exponent sum adjusted by the normalisation
    lsl lr, r1, r7                         @ lr = mantissa word << r7
    adds r7, #0xc                          @ r7 = shift + 12 for the low-word part
    rsb r1, r7, #0x20                      @ r1 = 32 - r7
    lsl r7, r0, r7                         @ r7 = low word << r7
    lsrs r0, r1                            @ low word >> (32 - r7) ...
    orr lr, lr, r0                         @ ... merged into lr: lr:r7 = normalised significand of a, leading one in bit 63
    bic r3, r3, r5, lsl #0x15              @ b significand: clear sign and exponent ...
    orr r3, r3, #0x100000                  @ ... set the leading one
    b .Ldmul_0801BB98                      @ multiply
    @ b is subnormal, a is normal.
.Ldmul_0801BC52:
    bics r3, r3, #0x80000000               @ clear the sign of b_hi
    clz r7, r3                             @ r7 = leading zero count of b_hi
    itt eq                                 @ b_hi zero: add the leading zero count of b_lo
    clzeq lr, r2
    addeq r7, lr
    subs r7, #0xb                          @ r7 = shift that puts the leading one at bit 52 (clz - 11)
    subs r4, r4, r7                        @ r4 = exponent sum - shift
    subs lr, r7, #0x20                     @ r3:r2 shift left by r7: 
    iteee cs                               @ r7 >= 32: high word = low word << (r7 - 32)
    lslcs r3, r2, lr
    lslcc r3, r7                           @ r7 < 32: high word << r7 ...
    rsbcc lr, r7, #0x20                    @ ... plus the bits that come from the low word
    lsrcc lr, r2, lr
    it cc                                  @ IT block on cc: 1 instruction run only when cc
    orrcc r3, r3, lr
    lsls r2, r7                            @ low word << r7
    adds r4, r4, #1                        @ r4 += 1
    b .Ldmul_0801BB8C                      @ continue with the multiplication
    @ a or b is infinity/NaN.
.Ldmul_0801BC86:
    orrs lr, r0, r1, lsl #1                @ Z = a is zero
    ite ne                                 @ IT block on ne: then, else (else = opposite condition, tested on the flags as they are at that instruction)
    orrsne lr, r2, r3, lsl #1              @ a not zero: Z = b is zero. Z set (a or b zero): ...
    mvneq r1, #0                           @ ... r1 = 0xFFFFFFFF (NaN result for zero times infinity)
    mov r7, #0x200000                      @ r7 = 0x00200000
    cmn r7, r3, lsl #1                     @ compare b << 1 with 0xFFE00000: hi when b is a NaN
    itet hi                                @ the next three instructions: hi = b is a NaN (high mantissa bits non-zero)
    movhi r1, r3                           @ b is a NaN: r1 = b_hi (the low word r0 stays the low word of a)
    cmnls r7, r1, lsl #1                   @ b is not a NaN: compare a << 1 with 0xFFE00000 the same way
    bhi .Ldmul_0801BC12                    @ NaN in b (flags of the first compare) or in a (flags of the second compare): return
    orr r1, r12, r5, lsl #0x14             @ infinity result: sign | 0x7FF00000 ...
    movs r0, #0                            @ ... low word 0
    pop {r4, r5, r7, pc}
    @ Result exponent below 1: subnormal result or underflow.
.Ldmul_0801BCAE:
    rsbs r4, r4, #1                        @ r4 = 1 - r4: right shift count (1 or more)
    subs r7, r4, #0x20                     @ r7 = count - 32
    bge .Ldmul_0801BCD8                    @ count >= 32: separate path
    rsb r7, r4, #0x20                      @ r7 = 32 - count
    lsrs r2, r2, #1                        @ guard word r2 >> 1 ...
    it cs                                  @ ... C = the bit that fell out: ...
    orrcs r2, r2, #1                       @ ... keep it as a sticky bit
    lsls r5, r0, r7                        @ r5 = low-word bits shifted out; C = lowest kept bit
    lsl r7, r1, r7                         @ r7 = high-word bits that move into the low word
    @ v2.05 itttt al here: the next 4 instructions run unconditionally; narrow forms in the IT block do not set flags (wide non-flag-setting forms used, gas rejects IT AL)
    orr.w r2, r2, r5                       @ guard word |= bits shifted out of the low word
    lsr.w r0, r0, r4                       @ low word >>= count
    orr.w r0, r0, r7                       @ low word |= bits from the high word
    lsr.w r1, r1, r4                       @ high word >>= count
    b .Ldmul_0801BCF8                      @ round and add the sign
    @ Right shift count 32 or more (r4 = count, r7 = count - 32).
.Ldmul_0801BCD8:
    cmp r4, #0x35                          @ count > 53: the result is zero
    bgt .Ldmul_0801BC0E
    rsb r4, r7, #0x20                      @ r4 = 32 - r7
    orrs r2, r2, r0, lsl #1                @ Z = guard word and low word contribute no sticky bits ...
    lsr r2, r0, r7                         @ r2 = low word >> r7
    it ne                                  @ sticky bits present: ...
    orrne r2, r2, #1                       @ ... set bit 0
    lsrs r0, r1, r7                        @ r0 = high word >> r7; C = lowest kept bit
    lsls r1, r4                            @ high-word bits that fall below the window ...
    orrs r2, r1                            @ ... into the guard word
    movs r1, #0                            @ high word = 0
    @ Round and pack a subnormal result.
.Ldmul_0801BCF8:
    sbcs r2, r2, #0x80000000               @ round to nearest even: carry = 1 when the guard word is above one half, or exactly one half and the lowest kept bit is 1
    adcs r0, r0, #0                        @ round the low word
    adcs r1, r1, r12                       @ high word + sign + carry (the exponent field of a subnormal is 0)
    pop {r4, r5, r7, pc}                   @ return
ENDFUNC fn_0801BB64

