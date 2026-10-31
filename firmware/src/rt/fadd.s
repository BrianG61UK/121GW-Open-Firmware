@ =============================================================================
@ fadd.s - RT: single-precision addition and subtraction
@
@ Port of the v2.05 helpers
@   fn_080132EC  float + float    (entry; flips the sign of b and subtracts when the signs differ)
@   fn_080132FC  magnitude addition core (same signs)
@   fn_080133B4  float - float    (entry; flips the sign of b and adds when the signs differ)
@   fn_080133C4  magnitude subtraction core (same signs)
@
@ Calling convention (DESIGN.md 6, exception for RT): a in r0, b in r1, result in r0; r2, r3, r12 and the flags are
@ scratch, r4-r11 and lr are preserved.  Every routine is a copy of the v2.05 instruction sequence, re-expressed with
@ symbolic labels, so every register, flag and result bit is the one v2.05 produces.
@
@ Behaviour that differs from IEEE 754 (found by comparing the original helper with exact round-to-nearest-even
@ arithmetic over random and edge operands, W2 test, 15 000 random pairs per class; both operands normal with a normal
@ result: no difference found):
@   - in a magnitude subtraction a subnormal smaller operand enters at one half of its value, because the shift count
@     uses the exponent field 0 instead of 1 (0x01000000 - 0x00400000 gives 0x00E00000, IEEE 0x00C00000);
@   - a negative result whose exponent field becomes 0 is returned without its leading one
@     (fsub(0x00AAE475, 0x0112A19A) gives 0x8074BD7E, IEEE 0x807A5EBF);
@   - rare rounding differences when a subnormal operand is added.
@ Infinities and NaNs: the operand with the larger bit pattern decides (a NaN beats an infinity; in a subtraction the
@ result carries the sign of the swap rule of fn_080133C4); a subtraction of two infinity/NaN operands of equal sign
@ (after the sign adjustment of the entry) gives 0xFFFFFFFF.
@ These behaviours are kept bit for bit (DESIGN.md 6.5).
@
@ Context: ISR-safe, no memory access, no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_080132EC / fn_080132FC - single-precision addition
@ Replaces : 0x080132EC (entry; v2.05 FUN_080132ec) and 0x080132FC (same-sign core; v2.05 FUN_080132fc)
@ In       : r0 = a, r1 = b (binary32 bit patterns)
@ Out      : r0 = a + b, rounded to nearest, ties to even (see the file header for the non-IEEE cases)
@ Clobbers : r0-r3, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_080132EC
    teq r0, r1                             @ N = (sign of a) XOR (sign of b)
    itt mi                                 @ IT block on mi: 2 instructions run only when mi
    eormi r1, r1, #0x80000000              @ signs differ: b = -b ...
    bmi fn_080133C4                        @ ... and subtract the magnitudes in fn_080133C4
    nop                                    @ alignment padding of the v2.05 image (executed nop), kept
    @ Core: same sign, add the magnitudes.  Step 1: order the operands so that r0 has the larger bit pattern (the larger magnitude).
FUNC fn_080132FC
    subs r2, r0, r1                        @ r2 = a - b, C = (a >= b)
    itt cc                                 @ a < b: swap the operands without a temporary: ...
    subcc r0, r0, r2                       @ ... r0 = a - (a - b) = b
    addcc r1, r1, r2                       @ ... r1 = b + (a - b) = a
    mov r12, #0x80000000                   @ r12 = 0x80000000, the mantissa's leading one in the aligned form
    ubfx r2, r0, #0x17, #8                 @ r2 = exponent of the larger operand
    cmp r2, #0xff                          @ exponent 255 in the larger operand: infinity or NaN
    beq .Lfadd_0801335A                    @ ... the larger bit pattern is the result (NaN beats infinity)
    ubfx r3, r1, #0x17, #8                 @ r3 = exponent of the smaller operand
    cbz r3, .Lfadd_0801335C                @ exponent 0 (zero or subnormal): handled below
    subs r2, r2, r3                        @ r2 = exponent difference d = ea - eb
    rsbs r3, r2, #0x19                     @ r3 = 25 - d
    ble .Lfadd_0801336E                    @ d >= 25: the smaller operand does not reach the result, return the larger one
    orr r1, r12, r1, lsl #8                @ r1 = mantissa of the smaller operand with its leading one in bit 31
    @ Aligned addition.  r1 = smaller mantissa (leading one in bit 31), r2 = shift d, r3 = 25 - d (also entered with r3 = 23 - ea for a subnormal b).
.Lfadd_08013322:
    asr r3, r12, r3                        @ r3 = 0x80000000 >> r3 (arithmetic): a run of ones in the top bits
    bic r3, r1, r3                         @ r3 = r1 with its top 26 - d bits cleared: the low part of the smaller mantissa, kept for the rounding test
    lsrs r1, r2                            @ r1 >>= d: align the smaller mantissa
    lsrs r2, r0, #0x17                     @ r2 = sign and exponent of the larger operand (sign in bit 8)
    orr r0, r12, r0, lsl #8                @ r0 = larger mantissa with its leading one in bit 31
    adds r0, r0, r1                        @ r0 = sum of the aligned mantissas, C = carry out of bit 31
    ite cc                                 @ no carry out: ...
    biccc r0, r0, r12                      @ ... clear the leading one (it will come back as the +1 of the exponent field when the mantissa is added to the exponent below)
    orrcs r0, r12, r0, lsr #1              @ carry out: normalise by one place to the right, the leading one stays set
    lsls r2, r2, #0x17                     @ r2 = sign and exponent in place (sign in bit 31)
    orrs r3, r3, r0, lsl #0x18             @ r3 = bits below the mantissa: lost bits and the 8 guard bits of the sum; C = lowest mantissa bit
    sbcs r12, r3, r12                      @ round to nearest even: carry = 1 when the bits below are above one half, or exactly one half and the lowest mantissa bit is 1
    adcs r0, r2, r0, lsr #8                @ r0 = sign and exponent + mantissa (+1 exponent step from the leading one when it is set) + rounding carry
    lsls r2, r0, #1                        @ r2 = result << 1 to inspect the exponent field
    cmn r2, #0x1000000                     @ carry set when the exponent field reached 255
    it cc                                  @ exponent below 255: return the result
    bxcc lr
    lsrs r0, r0, #0x17                     @ overflow: clear the mantissa, leaving a signed infinity
    lsls r0, r0, #0x17
    @ Return (infinity/NaN operand or finished infinity).
.Lfadd_0801335A:
    bx lr
    @ Smaller operand has exponent 0.
.Lfadd_0801335C:
    lsls r1, r1, #9                        @ r1 = fraction of b left aligned in bits 31..9 (no leading one); Z = the fraction is zero
    itee ne                                @ b is not zero: this compare has no effect (its flags are overwritten by the rsbs below)
    cmpne r2, r3
    addeq r0, r0, r1, lsr #9               @ b is zero: a is the result (adds 0 to r0) ...
    beq .Lfadd_0801335A                    @ ... and return it
    rsbs r3, r2, #0x17                     @ r3 = 23 - ea (no exponent difference was formed: the subnormal b is aligned with the shift ea, as if its exponent field were 0)
    bpl .Lfadd_08013322                    @ ea <= 23: align and add as above
    @ ea > 23 (or d >= 25 above): the larger operand is the result.
.Lfadd_0801336E:
    bx lr
ENDFUNC fn_080132EC

@ -----------------------------------------------------------------------------
@ fn_080133B4 / fn_080133C4 - single-precision subtraction
@ Replaces : 0x080133B4 (entry; v2.05 FUN_080133b4) and 0x080133C4 (same-sign core; v2.05 FUN_080133c4)
@ In       : r0 = a, r1 = b (binary32 bit patterns)
@ Out      : r0 = a - b, rounded to nearest, ties to even (see the file header for the non-IEEE cases)
@ Clobbers : r0-r3, r12, flags
@ Context  : ISR-safe (no memory access)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_080133B4
    teq r0, r1                             @ N = (sign of a) XOR (sign of b)
    itt mi                                 @ IT block on mi: 2 instructions run only when mi
    eormi r1, r1, #0x80000000              @ signs differ: b = -b ...
    bmi fn_080132FC                        @ ... and add the magnitudes in fn_080132FC
    nop                                    @ alignment padding of the v2.05 image (executed nop), kept
    @ Core: same sign, subtract the smaller magnitude from the larger.  Step 1: order the operands so that r0 has the larger bit pattern.
FUNC fn_080133C4
    subs r3, r0, r1                        @ r3 = a - b, C = (a >= b)
    mov r2, #0x80000000                    @ r2 = 0x80000000, the sign bit
    ittt cc                                @ a < b: r3 = (a - b) with the top bit flipped ...
    eorcc r3, r2                           @ ... r0 = a - r3 = b with its sign flipped
    subcc r0, r0, r3
    addcc r1, r1, r3                       @ ... r1 = b + r3 = a with its sign flipped (swapped, signs inverted: the result takes the opposite sign)
    nop                                    @ alignment padding of the v2.05 image (executed nop), kept
    lsrs r3, r2, #7                        @ r3 = 0x01000000, the exponent step
    lsrs r12, r0, #0x17                    @ r12 = sign (bit 8) and exponent of the larger operand
    cmn r3, r0, lsl #1                     @ carry when the larger operand's exponent is 255
    ite cc                                 @ IT block on cc: then, else (else = opposite condition, tested on the flags as they are at that instruction)
    cmpcc r3, r1, lsl #1                   @ finite: compare the smaller operand shifted left by one with 0x01000000 (C = its exponent is 0, or it is exactly 2^-126)
    bcs .Lfsub_08013468                    @ larger operand is infinity/NaN, or the smaller one has exponent 0 (or is 2^-126): special path
    sbcs r3, r12, r1, lsr #0x17            @ r3 = (ea - eb) - 1 (the signs cancel), carry flag consumed
    bcc .Lfsub_08013406                    @ ea = eb: subtract the bit patterns directly
    orr r1, r2, r1, lsl #8                 @ r1 = smaller mantissa with the leading one in bit 31
    bhi .Lfsub_08013438                    @ d >= 2: far path
    rsbs r0, r1, r0, lsl #9                @ d = 1: r0 = (fraction of a, left aligned) - r1, C = no borrow
    bcc .Lfsub_0801340C                    @ borrow: the result is below 2^32, normalise with a left shift
    lsrs r0, r0, #9                        @ no borrow: r0 = result mantissa field (the carried leading one is implicit); C = bit 8 of the difference (round bit)
    it cs                                  @ round bit set: ...
    movscs r1, r0, lsr #1                  @ ... C = lowest mantissa bit (the bits below the round bit are zero, so this is the tie rule: round up only when the mantissa is odd)
    adc r0, r0, r12, lsl #0x17             @ r0 = mantissa + (sign and exponent of the larger operand) << 23 + rounding carry
    bx lr                                  @ return
    @ Equal exponents: r0 = r0 - r1 on the bit patterns gives the mantissa difference.
.Lfsub_08013406:
    subs r0, r0, r1                        @ mantissa difference (sign and exponent cancel)
    beq .Lfsub_08013436                    @ zero: return +0
    lsls r0, r0, #9                        @ difference left aligned in bits 31..9
    @ Normalise a difference that has its leading one somewhere below bit 31 (entered with r0 = fraction bits left aligned, r12 = sign/exponent).
.Lfsub_0801340C:
    clz r2, r0                             @ r2 = leading zero count
    adds r2, r2, #1                        @ r2 = shift that also removes the leading one
    lsls r0, r2                            @ r0 = bits after the leading one, left aligned
    lsrs r0, r0, #9                        @ r0 = 23-bit mantissa field
    ror r3, r12, #8                        @ r3 = exponent in bits 31..24, sign in bit 0 (r12 rotated right by 8)
    subs r3, r3, r2, lsl #0x18             @ r3 = exponent - shift (in the top byte); borrow when the exponent drops to zero or below
    itt hi                                 @ exponent still positive: ...
    addhi r0, r0, r3, ror #1               @ ... result = mantissa + (exponent, sign rotated into place); for a negative sign and an exponent that reaches 0, r3 = 1 is not zero and this path is taken too (v2.05 behaviour, see the file header)
    bhi .Lfsub_08013436                    @ ... return
    orr r0, r0, #0x800000                  @ subnormal result: restore the leading one in bit 23
    asrs r2, r3, #0x18                     @ r2 = exponent (zero or negative)
    lsls r3, r3, #0x1f                     @ r3 = sign in bit 31
    rsb r2, r2, #1                         @ r2 = 1 - exponent = right shift count
    lsrs r0, r2                            @ denormalise the mantissa (truncation)
    orrs r0, r3                            @ add the sign
    @ Return.
.Lfsub_08013436:
    bx lr
    @ Exponent difference d >= 2 (r3 = d - 1).
.Lfsub_08013438:
    cmp r3, #0x18                          @ d - 1 > 24: the smaller operand is lost
    bgt .Lfsub_08013436                    @ ... return the larger operand
    @ Aligned subtraction.  r1 = smaller mantissa (leading one in bit 31) or its fraction for a subnormal, r3 = shift d - 1.
.Lfsub_0801343C:
    lsrs r2, r1, r3                        @ r2 = r1 >> r3: aligned smaller mantissa
    lsl r3, r2, r3                         @ r3 = r2 << r3: the bits that survive the shift
    subs r1, r3, r1                        @ r1 = surviving bits - r1; borrow when bits were lost
    it cc                                  @ bits were lost: ...
    orrcc r2, r2, #1                       @ ... set sticky bit 0 of the aligned value
    rsbs r0, r2, r0, lsl #9                @ r0 = (fraction of the larger operand, left aligned) - r2, C = no borrow
    itt cc                                 @ borrow: the result is below 2^32 ...
    lslcc r0, r0, #1                       @ ... normalise by one place to the left ...
    subcc r12, r12, #1                     @ ... and lower the exponent by one
    lsls r12, r12, #0x17                   @ r12 = sign and exponent in place (sign in bit 31)
    lsls r2, r0, #0x17                     @ r2 = bits below the mantissa field, left aligned; C = lowest mantissa bit
    sbcs r1, r2, #0x80000000               @ round to nearest even: carry = 1 when the bits below are above one half, or exactly one half and the lowest mantissa bit is 1
    adc r0, r12, r0, lsr #9                @ r0 = sign and exponent + mantissa + rounding carry
    bx lr                                  @ return
    @ Larger operand is infinity/NaN, or smaller operand has exponent 0 (or is exactly 2^-126).
.Lfsub_08013468:
    cmn r3, r0, lsl #1                     @ carry when the larger operand's exponent is 255
    bcs .Lfsub_0801348E                    @ infinity/NaN: see below
    lsls r3, r1, #1                        @ r3 = smaller operand << 1
    beq .Lfsub_08013486                    @ smaller operand is zero: return the larger one (a zero result is tested at 08013486)
    sub r3, r12, r1, lsr #0x17             @ r3 = ea - eb (the smaller exponent is 0 or 1)
    cmp r3, #2                             @ d < 2
    blt .Lfsub_08013482                    @ ... direct subtraction of the bit patterns
    lsls r1, r1, #9                        @ r1 = fraction of the smaller operand, left aligned, without a leading one (subnormal operand)
    cmp r3, #0x17                          @ d <= 23: aligned subtraction with shift r3
    ble .Lfsub_0801343C
    bx lr                                  @ d > 23: the larger operand is the result
    @ d < 2: subtract the smaller bit pattern (sign cleared) from the larger.
.Lfsub_08013482:
    bics r1, r2                            @ r1 = smaller operand without its sign
    subs r0, r0, r1                        @ r0 = larger - smaller (bit patterns)
    @ Zero test of the result.
.Lfsub_08013486:
    lsls r3, r0, #1                        @ r3 = r0 << 1: Z when the result is zero
    bne .Lfsub_08013436                    @ non-zero: return it
    movs r0, #0                            @ zero result: +0
    bx lr
    @ Larger operand is infinity or NaN.
.Lfsub_0801348E:
    cmn r3, r1, lsl #1                     @ carry when the smaller operand is infinity/NaN as well
    bcc .Lfsub_08013436                    @ smaller operand finite: the infinity/NaN is the result
    mvn r0, #0                             @ both are infinity/NaN: the result is 0xFFFFFFFF
    bx lr
ENDFUNC fn_080133B4

