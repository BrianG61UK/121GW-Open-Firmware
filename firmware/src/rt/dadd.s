@ =============================================================================
@ dadd.s - RT: double-precision addition and subtraction
@
@ Port of the v2.05 helpers
@   fn_080131B8  double + double   (entry; flips the sign of b and subtracts when the signs differ)
@   fn_080131CC  magnitude addition core (same signs)
@   fn_0801FB9C  double - double   (entry; flips the sign of b and adds when the signs differ)
@   fn_0801FBB0  magnitude subtraction core (same signs)
@
@ Calling convention (DESIGN.md 6, exception for RT): a in r0 (low word) : r1 (high word), b in r2 : r3, result in
@ r0 : r1; r12 and the flags are scratch, r4-r11 and lr are preserved (the entries push r4-r7 and the cores pop them
@ on every exit).  Every routine is a copy of the v2.05 instruction sequence, re-expressed with symbolic labels, so
@ every register, flag and result bit is the one v2.05 produces.
@
@ Behaviour that differs from IEEE 754 (found by comparing the original helpers with exact round-to-nearest-even
@ arithmetic over random and edge operands, W2 test, 15 000 random pairs per class; both operands normal with a normal
@ or overflowing result: no difference found).  With exactly one subnormal operand the result is exact when the larger
@ operand (after the sign adjustment of a subtraction) is positive, and wrong in about 10 percent of the sampled pairs
@ when it is negative: the special path for a subnormal smaller operand (0x08013286 and 0x0801FCF6) forms the exponent
@ difference from "sign and exponent" (sign in bit 11) minus 1; for a negative larger operand this is at least 0x800,
@ the test "d <= 52" fails and the larger operand is returned unchanged
@ (0x8010000000000000 + 0x8000000000000001 gives 0x8010000000000000, IEEE 0x8010000000000001;
@ 0x800B5B3E13F95954 - 0x0047152C8D4F9271 gives 0x8047152C8D4F9271, IEEE 0x804880944FCEBD9C).
@ Infinities and NaNs: the addition core returns the operand with the larger bit pattern unchanged; the subtraction
@ core replaces the high word of a NaN or of an infinity minus infinity by 0xFFFFFFFF (low word kept) and returns an
@ infinity minus a finite operand unchanged.
@ These behaviours are kept bit for bit (DESIGN.md 6.5).
@
@ Context: ISR-safe (stack use only), no state.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_080131B8 / fn_080131CC - double-precision addition
@ Replaces : 0x080131B8 (entry; v2.05 FUN_080131b8) and 0x080131CC (same-sign core; v2.05 FUN_080131cc)
@ In       : r0:r1 = a, r2:r3 = b (binary64 bit patterns, low word first)
@ Out      : r0:r1 = a + b, rounded to nearest, ties to even (see the file header for the non-IEEE cases)
@ Clobbers : r0-r3, r12, flags
@ Context  : ISR-safe (stack use only)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_080131B8
    push {r4, r5, r6, r7}                  @ save r4-r7 (the core restores them on every exit)
    mov r5, #0x80000000                    @ r5 = 0x80000000
    eors r12, r1, r3                       @ N = sign of a XOR sign of b
    itt mi                                 @ IT block on mi: 2 instructions run only when mi
    eormi r3, r5                           @ signs differ: b = -b ...
    bmi fn_0801FBB0                        @ ... and subtract the magnitudes in fn_0801FBB0
    nop                                    @ alignment padding of the v2.05 image (executed nop), kept
    @ Core: same sign, add the magnitudes.  Step 1: order the operands so that r0:r1 has the larger bit pattern.
FUNC fn_080131CC
    subs r4, r0, r2                        @ r4 = low word of a - b
    sbcs r6, r1, r3                        @ r6 = high word of a - b; C = (a >= b) as 64-bit unsigned patterns
    bcs .Ldadd_080131DC                    @ a >= b: no swap
    subs r0, r0, r4                        @ a < b: swap without a temporary, r0 = a_lo - (a - b)_lo = b_lo ...
    sbcs r1, r6                            @ ... r1 = b_hi
    adds r2, r2, r4                        @ ... r2 = b_lo + (a - b)_lo = a_lo ...
    adcs r3, r6                            @ ... r3 = a_hi
    @ Special-operand test.
.Ldadd_080131DC:
    mov r12, #0x200000                     @ r12 = 0x00200000, one step of the exponent field in the "<< 1" form
    cmn r12, r1, lsl #1                    @ C = 1 when the exponent field of the larger operand is 0x7FF (infinity or NaN)
    ite cc                                 @ IT block on cc: then, else (else = opposite condition, tested on the flags as they are at that instruction)
    sbcscc r4, r12, r3, lsl #1             @ larger operand finite: C = 1 when the exponent field of b is 0 (zero or subnormal)
    bcs .Ldadd_08013274                    @ larger operand is infinity/NaN, or b is zero/subnormal: special path
    lsrs r4, r1, #0x14                     @ r4 = sign and exponent of a (12 bits, sign in bit 11)
    sub r6, r4, r3, lsr #0x14              @ r6 = ea - eb (the signs are equal and cancel)
    cmp r6, #0x35                          @ d > 53: b does not reach the result, a is returned
    bgt .Ldadd_08013298
    orr r3, r5, r3, lsl #0xb               @ r3 = b high word with its leading one: 0x00100000 | mantissa bits 51..32
    lsrs r3, r3, #0xb
    @ Aligned addition (also entered for a subnormal b, with r3 = high word of b without a leading one and r6 = shift).  r6 = d.
.Ldadd_080131FC:
    orr r1, r5, r1, lsl #0xb               @ a high word becomes 0xFFF00000 | mantissa bits 51..32: the significand of a minus 2^53, so that the carry out of the addition tells whether the sum reaches 2^53
    asrs r1, r1, #0xb
    subs r5, r6, #0x20                     @ r5 = d - 32
    ble .Ldadd_08013224                    @ d <= 32: shift by d inside the two words
    ror r6, r3, r5                         @ d > 32: r6 = b high word rotated right by d - 32 ...
    lsrs r3, r5                            @ ... r3 = b high word >> (d - 32): the aligned low word (the aligned high word is 0)
    eor r5, r6, r3                         @ ... r5 = the bits rotated out, left aligned (guard and sticky bits)
    tst r2, r2                             @ test the low word of b (the bits that fall completely below the window)
    it ne                                  @ IT block on ne: 1 instruction run only when ne
    orrne r5, r5, #1                       @ low word of b not zero: set the sticky bit 0 of the guard word
    adds r0, r0, r3                        @ a_lo + aligned low word
    adcs r1, r1, #0                        @ propagate the carry into the high word, C = carry out of the 64-bit sum
    bcs .Ldadd_0801323C                    @ carry out: normalise by one place
    b .Ldadd_0801324C                      @ no carry out: pack
    @ d <= 32: 64-bit shift of b by d (r6 = d).
.Ldadd_08013224:
    ror r5, r2, r6                         @ r5 = b_lo rotated right by d
    lsrs r2, r6                            @ r2 = b_lo >> d
    eors r5, r2                            @ r5 = the bits shifted out of b_lo, left aligned
    rors r3, r6                            @ r3 = b_hi rotated right by d
    eors r2, r3                            @ r2 = (b_lo >> d) XOR rotated b_hi ...
    lsls r3, r6                            @ ... shift r3 (rotated b_hi) left by d ...
    lsrs r3, r6                            @ ... and back right by d: the top d bits are cleared, r3 = b_hi >> d, the aligned high word
    eors r2, r3                            @ ... r2 = (b_lo >> d) | (b_hi << (32 - d)): the aligned low word
    adds r0, r0, r2                        @ a + aligned b, low word
    adcs r1, r3                            @ high word, C = carry out of the 64-bit sum
    bcc .Ldadd_0801324C                    @ no carry out: pack
    @ Carry out of the sum: shift the 64-bit sum and the guard word right by one place, keeping the sticky bit.
.Ldadd_0801323C:
    lsrs r1, r1, #1                        @ r1 >>= 1
    rrxs r0, r0                            @ r0 = (carry in bit 31) | r0 >> 1 through the carry flag; C = bit shifted out
    rrxs r5, r5                            @ r5 = same for the guard word
    it cs                                  @ a one was shifted out of the guard word: ...
    orrcs r5, r5, #1                       @ ... keep it as the sticky bit 0
    @ Pack: round to nearest even and add sign and exponent.
.Ldadd_0801324C:
    add r1, r1, #0x100000                  @ r1 += 0x00100000: turns the 0xFFFxxxxx form into the fraction (no carry out earlier) or adds 1 to the exponent field (carry out earlier)
    lsrs r2, r0, #1                        @ C = lowest mantissa bit
    sbcs r2, r5, #0x80000000               @ round to nearest even: carry = 1 when the guard word is above one half, or exactly one half and the lowest mantissa bit is 1
    adcs r0, r0, #0                        @ round the low word
    adc r1, r1, r4, lsl #0x14              @ r1 = high word + sign and exponent (r4 << 20) + carry
    pop {r4, r5, r6, r7}                   @ restore r4-r7
    mov r12, #0x200000                     @ r12 = 0x00200000
    cmn r12, r1, lsl #1                    @ C = 1 when the exponent field of the result is 0x7FF (overflow)
    it cc                                  @ no overflow: return
    bxcc lr
    movs r0, #0                            @ overflow: ...
    lsrs r1, r1, #0x14                     @ ... clear the mantissa of the high word ...
    lsls r1, r1, #0x14
    bx lr                                  @ ... the result is a signed infinity
    @ Larger operand is infinity/NaN, or b is zero or subnormal.
.Ldadd_08013274:
    cmn r12, r1, lsl #1                    @ C = 1 when the larger operand is infinity/NaN
    bcs .Ldadd_0801329C                    @ infinity/NaN: it is the result
    orrs r6, r2, r3, lsl #1                @ Z = b is zero
    beq .Ldadd_08013298                    @ b is zero: a is the result
    cmp r12, r1, lsl #1                    @ compare the exponent field of a with 0 (flags for the branch below)
    bhi .Ldadd_08013292                    @ exponent of a is 0 too (both subnormal): add the bit patterns
    lsrs r4, r1, #0x14                     @ r4 = sign and exponent of a (sign in bit 11)
    bics r3, r5                            @ clear the sign of b
    subs r6, r4, #1                        @ r6 = (sign and exponent of a) - 1: the exponent of a subnormal operand counts as 1, but for a negative a the sign bit makes r6 >= 0x800 and the test below fails (v2.05 behaviour, see the file header)
    cmp r6, #0x34                          @ r6 <= 52: aligned addition with the subnormal b (no leading one)
    ble .Ldadd_080131FC
    b .Ldadd_08013298                      @ d too large: a is the result
    @ Both operands zero or subnormal: add the bit patterns.
.Ldadd_08013292:
    bics r3, r5                            @ clear the sign of b
    adds r0, r0, r2                        @ a + b, low word
    adcs r1, r3                            @ high word
    @ Return a (or the finished sum).
.Ldadd_08013298:
    pop {r4, r5, r6, r7}
    bx lr
    @ Return (infinity/NaN operand).
.Ldadd_0801329C:
    pop {r4, r5, r6, r7}
    bx lr
ENDFUNC fn_080131B8

@ -----------------------------------------------------------------------------
@ fn_0801FB9C / fn_0801FBB0 - double-precision subtraction
@ Replaces : 0x0801FB9C (entry; v2.05 FUN_0801fb9c) and 0x0801FBB0 (same-sign core; v2.05 FUN_0801fbb0)
@ In       : r0:r1 = a, r2:r3 = b (binary64 bit patterns, low word first)
@ Out      : r0:r1 = a - b, rounded to nearest, ties to even (see the file header for the non-IEEE cases)
@ Clobbers : r0-r3, r12, flags
@ Context  : ISR-safe (stack use only)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801FB9C
    push {r4, r5, r6, r7}                  @ save r4-r7 (the core restores them on every exit)
    mov r5, #0x80000000                    @ r5 = 0x80000000
    teq r1, r3                             @ N = sign of a XOR sign of b
    itt mi                                 @ IT block on mi: 2 instructions run only when mi
    eormi r3, r5                           @ signs differ: b = -b ...
    bmi fn_080131CC                        @ ... and add the magnitudes in fn_080131CC
    nop                                    @ alignment padding of the v2.05 image (executed nop), kept
    @ Core: same sign, subtract the smaller magnitude from the larger.  Step 1: order the operands so that r0:r1 has the larger bit pattern.
FUNC fn_0801FBB0
    subs r4, r0, r2                        @ r4 = low word of a - b
    sbcs r6, r1, r3                        @ r6 = high word of a - b; C = (a >= b)
    bcs .Ldsub_0801FBC2                    @ a >= b: no swap
    eors r6, r5                            @ a < b: r6 = (a - b)_hi with the top bit flipped ...
    subs r0, r0, r4                        @ ... r0:r1 = a - D = b with its sign flipped ...
    sbcs r1, r6
    adds r2, r2, r4                        @ ... r2:r3 = b + D = a with its sign flipped (swapped, signs inverted: the result takes the opposite sign)
    adcs r3, r6
    @ Special-operand test.
.Ldsub_0801FBC2:
    mov r12, #0x200000                     @ r12 = 0x00200000
    cmn r12, r1, lsl #1                    @ C = 1 when the exponent field of the larger operand is 0x7FF
    ite cc                                 @ IT block on cc: then, else (else = opposite condition, tested on the flags as they are at that instruction)
    sbcscc r6, r12, r3, lsl #1             @ larger operand finite: C = 1 when the exponent field of b is 0
    bcs .Ldsub_0801FCDC                    @ larger operand is infinity/NaN, or b is zero/subnormal: special path
    lsrs r4, r1, #0x14                     @ r4 = sign and exponent of a
    sub r6, r4, r3, lsr #0x14              @ r6 = ea - eb
    cmp r6, #0x36                          @ d > 54: a is the result
    bgt .Ldsub_0801FCD8
    cmp r6, #1                             @ d >= 2: far path
    bgt .Ldsub_0801FC68
    orr r3, r5, r3, lsl #0xb               @ r3 = b high word with its leading one and the top 11 bits of the low word: b significand left aligned in r3:r2 ...
    orr r3, r3, r2, lsr #0x15              @ ... (r2 >> 21 merged into the high word)
    itee ne                                @ the next three instructions depend on d (flags of the compare with 1): ne = (d = 0), eq = (d = 1)
    lslne r2, r2, #0xb                     @ d = 0: r2 = b_lo << 11 (significand leading one in bit 63)
    lsleq r2, r2, #0xa                     @ d = 1: r2 = b_lo << 10 ...
    lsreq r3, r3, #1                       @ d = 1: ... and r3 >>= 1 (b is one place lower than a)
    lsls r4, r4, #0x14                     @ r4 = sign and exponent of the larger operand, in place (sign in bit 31)
    orr r1, r5, r1, lsl #0xb               @ r1 = a significand left aligned (leading one in bit 63): high word ...
    orr r1, r1, r0, lsr #0x15              @ ... top 11 bits of the low word merged in
    rsbs r0, r2, r0, lsl #0xb              @ r0 = (a_lo << 11) - r2
    sbcs r1, r3                            @ r1 = r1 - r3 - borrow: r0:r1 = a - b, leading one expected in bit 63
    bmi .Ldsub_0801FC4E                    @ bit 63 set: normalised, round and pack
    bne .Ldsub_0801FC14                    @ high word not zero: normalise with a left shift
    clz r6, r0                             @ high word zero: r6 = leading zero count of the low word
    lsls r1, r0, r6                        @ r1 = low word << r6; Z when the difference is zero
    beq .Ldsub_0801FCD8                    @ difference is zero: return (r0:r1 = 0)
    movs r0, #0                            @ low word becomes zero ...
    adds r6, #0x20                         @ ... shift count + 32
    b .Ldsub_0801FC26                      @ continue with the exponent update
    @ Normalise a non-zero high word: 64-bit left shift by r6 = leading zero count of r1.
.Ldsub_0801FC14:
    clz r6, r1                             @ r6 = leading zero count of the high word
    lsls r1, r6                            @ r1 <<= r6
    rsb r2, r6, #0x20                      @ r2 = 32 - r6
    lsr r2, r0, r2                         @ r2 = low word >> (32 - r6)
    orrs r1, r2                            @ r1 = shifted high word with the bits from the low word
    lsls r0, r6                            @ r0 <<= r6
    @ Lower the exponent by the shift count (r4 = sign and exponent in place).
.Ldsub_0801FC26:
    ror r4, r4, #0x1f                      @ r4 rotated left by one: exponent in bits 31..21, sign in bit 0
    subs r4, r4, r6, lsl #0x15             @ exponent -= shift count; borrow when it goes below zero
    bics r6, r4, #1                        @ r6 = exponent without the sign bit (Z when the exponent field is zero)
    ror r4, r4, #1                         @ r4 rotated back: sign in bit 31, exponent in bits 30..20 (flags unchanged)
    bhi .Ldsub_0801FC4E                    @ exponent still positive: round and pack
    rsbs r6, r6, #0x200000                 @ subnormal result: r6 = 0x00200000 - r6 ...
    lsrs r6, r6, #0x15                     @ ... = right shift count 1 - exponent
    and r4, r4, #0x80000000                @ r4 = sign only
    lsrs r0, r6                            @ 64-bit shift right by r6: low word >> r6 ...
    ror r2, r1, r6                         @ ... high word rotated right by r6 ...
    eors r0, r2                            @ ... merged
    lsrs r1, r6                            @ ... high word >> r6
    eors r0, r1                            @ ... merged: the result is r0:r1 shifted
    @ Round and pack.  r0:r1 = difference with the leading one in bit 63 (or bit 52 shifted for subnormals), r4 = sign and exponent in place.
.Ldsub_0801FC4E:
    lsrs r0, r0, #0xb                      @ r0 >>= 11; C = the round bit
    orr r0, r0, r1, lsl #0x15              @ r0 |= r1 << 21: low word of the 52-bit fraction
    bic r1, r1, #0x80000000                @ clear the leading one
    it cs                                  @ round bit set: ...
    movscs r5, r0, lsr #1                  @ ... C = lowest mantissa bit (no bits lie below the round bit, so this is the tie rule)
    adcs r0, r0, #0                        @ round the low word
    adc r1, r4, r1, lsr #0xb               @ r1 = sign and exponent + fraction high bits (r1 >> 11) + carry
    b .Ldsub_0801FCD8                      @ return through the common exit
    @ Exponent difference d >= 2 (r6 = d).
.Ldsub_0801FC68:
    orr r3, r5, r3, lsl #0xb               @ b high word with its leading one at bit 20 ...
    lsrs r3, r3, #0xb                      @ ... r3 = 0x00100000 | mantissa bits
    @ Aligned subtraction (also entered for a subnormal b with r6 = ea - 1).
.Ldsub_0801FC6E:
    orr r1, r5, r1, lsl #0xb               @ a high word with its leading one at bit 20
    lsrs r1, r1, #0xb
    subs r5, r6, #0x20                     @ r5 = d - 32
    ble .Ldsub_0801FC98                    @ d <= 32
    orr r2, r2, r2, lsl #0x10              @ d > 32: fold the low word of b into 16 bits (only its non-zero-ness matters for the rounding) ...
    lsrs r2, r2, #0x10                     @ ... r2 = (low half | high half)
    rsb r6, r5, #0x20                      @ r6 = 32 - (d - 32)
    lsl r6, r3, r6                         @ r6 = b_hi << r6: bits that leave the low word
    lsrs r3, r5                            @ r3 = b_hi >> (d - 32): the aligned low word
    orr r5, r2, r6                         @ r5 = guard word (shifted-out bits merged with the folded low word)
    negs r5, r5                            @ r5 = -r5 (a - b needs the negated guard word)
    sbcs r0, r3                            @ r0 -= aligned low word
    sbc r1, r1, #0                         @ r1 -= borrow
    b .Ldsub_0801FCB4                      @ normalise
    @ d <= 32: 64-bit shift of b by d (r6 = d).
.Ldsub_0801FC98:
    ror r5, r2, r6                         @ r5 = b_lo rotated right by d
    lsrs r2, r6                            @ r2 = b_lo >> d
    eors r5, r2                            @ r5 = the bits shifted out of b_lo, left aligned
    ror r12, r3, r6                        @ r12 = b_hi rotated right by d
    eor r2, r2, r12                        @ r2 = (b_lo >> d) XOR rotated b_hi ...
    lsrs r3, r6                            @ ... r3 = b_hi >> d ...
    eors r2, r3                            @ ... r2 = (b_lo >> d) | (b_hi << (32 - d)): the aligned low word
    negs r5, r5                            @ r5 = -r5
    sbcs r0, r2                            @ r0 -= aligned low word
    sbc r1, r1, r3                         @ r1 -= aligned high word and borrow
    @ Normalise a difference whose leading one is at bit 20 or one place lower of the high word.
.Ldsub_0801FCB4:
    tst r1, #0x100000                      @ leading one still at bit 20 of the high word?
    bne .Ldsub_0801FCC6                    @ yes: round and pack
    subs r4, r4, #1                        @ no: exponent -= 1 ...
    lsls r2, r4, #0x15                     @ ... Z when the exponent field becomes zero (subnormal: no shift)
    beq .Ldsub_0801FCC6
    lsls r5, r5, #1                        @ shift the guard word and the difference left by one place
    adcs r0, r0
    adcs r1, r1
    @ Round and pack.
.Ldsub_0801FCC6:
    bic r1, r1, #0x100000                  @ clear the leading one
    lsrs r3, r0, #1                        @ C = lowest mantissa bit
    sbcs r3, r5, #0x80000000               @ round to nearest even: carry = 1 when the guard word is above one half, or exactly one half and the lowest mantissa bit is 1
    adcs r0, r0, #0                        @ round the low word
    adc r1, r1, r4, lsl #0x14              @ r1 = fraction + sign and exponent (r4 << 20) + carry
    @ Return (restore r4-r7).
.Ldsub_0801FCD8:
    pop {r4, r5, r6, r7}
    bx lr
    @ Larger operand is infinity/NaN, or b is zero/subnormal.
.Ldsub_0801FCDC:
    cmn r12, r1, lsl #1                    @ C = 1 when the larger operand is infinity/NaN
    bcs .Ldsub_0801FD0E                    @ infinity/NaN
    bic r3, r3, #0x80000000                @ clear the sign of b
    orrs r6, r2, r3, lsl #1                @ Z = b is zero
    beq .Ldsub_0801FD04                    @ b is zero: a is the result
    lsl r12, r12, #1                       @ r12 = 0x00400000
    cmp r12, r1, lsl #1                    @ compare with a << 1: hi when the exponent field of a is 0 or 1
    bhi .Ldsub_0801FD00                    @ exponent field of a is 0 or 1: subtract the bit patterns (both operands have the effective exponent 1)
    lsrs r4, r1, #0x14                     @ r4 = sign and exponent of a (sign in bit 11)
    subs r6, r4, #1                        @ r6 = (sign and exponent of a) - 1; for a negative a the sign bit makes r6 >= 0x800 and the test below fails (v2.05 behaviour, see the file header)
    cmp r6, #0x34                          @ r6 <= 52: aligned subtraction with the subnormal b
    ble .Ldsub_0801FC6E
    b .Ldsub_0801FCD8                      @ d too large: a is the result
    @ Both operands subnormal: subtract the bit patterns.
.Ldsub_0801FD00:
    subs r0, r0, r2                        @ low word
    sbcs r1, r3                            @ high word
    @ Zero test of the result.
.Ldsub_0801FD04:
    orrs r6, r0, r1, lsl #1                @ Z = result is zero
    it eq                                  @ zero: the high word is cleared (+0)
    moveq r1, #0
    b .Ldsub_0801FCD8                      @ return
    @ Larger operand is infinity/NaN.
.Ldsub_0801FD0E:
    it eq                                  @ Z (from the compare at 0x0801FCDC) = the high word of a has mantissa bits 51..32 equal to 0: a looks like an infinity; then ...
    cmneq r12, r3, lsl #1                  @ ... compare b the same way: C = 1 when b is infinity/NaN as well
    it cs                                  @ C is 1 when a is a NaN (high mantissa non-zero, C kept from the first compare) or when both are infinity/NaN: ...
    mvncs r1, #0                           @ ... the high word of the result is 0xFFFFFFFF
    b .Ldsub_0801FCD8                      @ return
ENDFUNC fn_0801FB9C

