@ =============================================================================
@ dsqrt.s - RT: double-precision square root
@
@ Port of the v2.05 helper fn_08013EF4 (the ARM compiler floating-point library square root, binary64, a digit
@ recurrence on the 53-bit significand) with its tail at 0x08020380 (negative operand: errno).
@
@ Calling convention (DESIGN.md 6, exception for RT): the operand in r0 (low word) : r1 (high word), the result in
@ r0 : r1; r2, r3, r12 and the flags are scratch, r4-r11 are preserved (r4 and r5 are pushed).  The routine is a copy
@ of the v2.05 instruction sequence, re-expressed with symbolic labels, so every register, flag and result bit is
@ the one v2.05 produces.
@
@ Behaviour observed by executing the original: sqrt(+0) = +0, sqrt(+infinity) and the square root of a positive NaN
@ are returned unchanged; sqrt(-0) returns +0 (r1 is overwritten by the zero test at 0x08013FD8); a negative NaN whose
@ high mantissa bits are non-zero is returned unchanged; every other negative operand (including -infinity) gives r0
@ unchanged and r1 = NOT (sign and exponent field) (for -1.0: r0 = 0, r1 = 0xFFFFF400) and writes 0x21 (EDOM) to
@ errno (RAM 0x20000228, v_20000228); the tail preserves r0-r3.
@
@ Context: ISR-safe; the only memory write is the errno word 0x20000228 (DESIGN.md 6.5).
@
@ OF-51: the operands with the sign bit set are answered before the v2.05 sequence
@ as IEEE 754 requires: sqrt(-0) = -0; a negative NaN is returned quiet (quiet bit 0x00080000 of the high word set); every
@ other negative operand (negative finite, -infinity) gives the default quiet NaN 0x7FF8000000000000; errno is not written.
@ Operands without the sign bit take the v2.05 sequence, which is IEEE-correct for them (+0, +infinity, a positive NaN
@ returned unchanged, positive finite operands correctly rounded).  The strict image keeps the v2.05 behaviour.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "config.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08013EF4 - double-precision square root
@ Replaces : 0x08013EF4 (v2.05 FUN_08013ef4, the double square-root helper) and its tail at 0x08020380
@ In       : r0:r1 = binary64 bit pattern of the operand
@ Out      : r0:r1 = square root, correctly rounded for non-negative finite operands (see the file header for the special operands)
@ Clobbers : r0-r3, r12, flags (r4, r5 are saved and restored)
@ Context  : ISR-safe (stack use only); writes errno 0x20000228 for a negative operand
@ RAM      : writes v_20000228 (errno) through fn_08023EDC
@ Spec     : DESIGN.md 6.5
@ Deviation: none in the strict image (copy of the v2.05 sequence); OF-51 in the production image (negative operands)
@ -----------------------------------------------------------------------------
FUNC fn_08013EF4
    tst r1, #0x80000000                    @ OF-51: sign bit set?
    beq .Ldsqrt_v205                       @ no: the v2.05 sequence
    bic r2, r1, #0x80000000                @ r2 = high word without the sign
    orrs r3, r2, r0
    beq .Ldsqrt_ret                        @ -0: sqrt(-0) = -0, returned unchanged
    movw r3, #0
    movt r3, #0x7FF0                       @ r3 = exponent field all ones
    cmp r2, r3
    bhi .Ldsqrt_nan                        @ above: a NaN with a non-zero high mantissa
    bne .Ldsqrt_inval                      @ below: negative finite (or subnormal): invalid
    cmp r0, #0
    beq .Ldsqrt_inval                      @ exactly 0x7FF00000:0 = -infinity: invalid
.Ldsqrt_nan:
    orr r1, r1, #0x00080000                @ a negative NaN is returned quiet
    bx lr
.Ldsqrt_inval:
    movs r0, #0
    movw r1, #0
    movt r1, #0x7FF8                       @ default quiet NaN 0x7FF8000000000000
.Ldsqrt_ret:
    bx lr
.Ldsqrt_v205:
    movw r12, #0x7ff                       @ r12 = 0x7FF, exponent mask
    lsrs r3, r1, #0x14                     @ r3 = sign and exponent of the operand (12 bits)
    beq .Ldsqrt_08013F98                   @ zero (+0) or a positive subnormal: separate path
    cmp r3, r12                            @ sign set or exponent 0x7FF: infinity, NaN or negative operand
    bcs .Ldsqrt_08013FCE
    push {r4, r5}                          @ save r4, r5
    bic r1, r1, r3, lsl #0x14              @ clear the exponent field (the sign is 0)
    orr r1, r1, #0x100000                  @ set the leading one: r1:r0 = significand with the leading one in bit 52
    @ Common start (also entered for a normalised subnormal with r3 = adjusted exponent).
.Ldsqrt_08013F0A:
    addw r12, r3, #0x3fd                   @ r12 = e + 0x3FD
    lsrs r12, r12, #1                      @ r12 = (e + 0x3FD) / 2 = exponent of the result; C = the low bit (odd exponent)
    bcc .Ldsqrt_08013F18                   @ even exponent: no adjustment
    adds r0, r0, r0                        @ odd exponent: significand << 1 (low word) ...
    adcs r1, r1                            @ ... (high word)
    @ Scale the radicand by four for the digit recurrence.
.Ldsqrt_08013F18:
    lsls r1, r1, #2                        @ significand << 2: high word ...
    orr r1, r1, r0, lsr #0x1e              @ ... bits from the low word
    lsls r0, r0, #2                        @ ... low word
    @ Digit recurrence.  Register roles: r1:r0 = remainder (the radicand at the start), r4:r3 = root accumulator, r5:r2 = digit weight (r5 for the high-word digits, r2 for the low-word digits, shifted right by one on every pass), r12 = exponent of the result.
    mov r4, #0x300000                      @ r4 = 0x00300000: initial high word of the root accumulator
    movs r3, #0                            @ r3 = 0: low word of the root accumulator
    lsls r2, r4, #0xb                      @ r2 = 0x80000000 (r4 << 11): initial weight of the low-word digits
    lsrs r5, r2, #0xb                      @ r5 = 0x00100000: initial weight of the high-word digits
    subs r1, r1, #0x900000                 @ remainder (high word) -= 0x00900000, the first trial value; N = negative
    bmi .Ldsqrt_08013F40                   @ negative: the first digit adds back (0x08013F40)
    @ High-word digit loop, remainder non-negative: one digit per pass.
.Ldsqrt_08013F30:
    lsrs r5, r5, #1                        @ digit weight (high word) >> 1; C = the weight is exhausted
    bcs .Ldsqrt_08013F70                   @ weight exhausted: continue with the low-word digits
    subs r1, r1, r4                        @ remainder -= root accumulator (high word)
    adds r4, r4, r5                        @ root accumulator += digit weight
    adds r0, r0, r0                        @ remainder <<= 1: low word ...
    adcs r1, r1                            @ ... high word
    subs r1, r1, r5                        @ remainder -= digit weight
    bpl .Ldsqrt_08013F30                   @ remainder still non-negative: next digit
    @ Remainder negative: the next digit adds back.
.Ldsqrt_08013F40:
    lsrs r5, r5, #1                        @ digit weight (high word) >> 1; C = the weight is exhausted
    bcs .Ldsqrt_08013F5A                   @ weight exhausted: low-word digits (add-back step at 0x08013F5A); otherwise the add-back loop follows
    @ High-word digit loop, remainder negative.
.Ldsqrt_08013F44:
    adds r1, r1, r4                        @ remainder += root accumulator (high word)
    subs r4, r4, r5                        @ root accumulator -= digit weight
    adds r0, r0, r0                        @ remainder <<= 1: low word ...
    adcs r1, r1                            @ ... high word
    subs r1, r1, r5                        @ remainder -= digit weight
    bpl .Ldsqrt_08013F30                   @ remainder non-negative again: back to the subtracting loop
    lsrs r5, r5, #1                        @ digit weight (high word) >> 1
    bcc .Ldsqrt_08013F44                   @ not exhausted: stay in the add-back loop
    b .Ldsqrt_08013F5A                     @ exhausted: low-word digits
    @ Low-word digit loop, remainder negative after the step.
.Ldsqrt_08013F56:
    lsrs r2, r2, #1                        @ digit weight (low word) >> 1
    beq .Ldsqrt_08013F8A                   @ exhausted: final rounding step
    @ Low-word digit loop, add-back step (the remainder was negative).
.Ldsqrt_08013F5A:
    adds r0, r0, r3                        @ remainder += root accumulator (low word) ...
    adcs r1, r4                            @ ... (high word)
    subs r3, r3, r2                        @ root accumulator -= digit weight (low word) ...
    sbcs r4, r5                            @ ... (high word)
    adds r0, r0, r0                        @ remainder <<= 1: low word ...
    adcs r1, r1                            @ ... high word
    subs r0, r0, r2                        @ remainder -= digit weight (low word) ...
    sbcs r1, r5                            @ ... (high word)
    bmi .Ldsqrt_08013F56                   @ remainder negative: next add-back digit
    lsrs r2, r2, #1                        @ digit weight (low word) >> 1
    beq .Ldsqrt_08013F86                   @ exhausted: final rounding step
    @ Low-word digit loop, subtract step (the remainder was non-negative).
.Ldsqrt_08013F70:
    subs r0, r0, r3                        @ remainder -= root accumulator (low word) ...
    sbcs r1, r4                            @ ... (high word)
    adds r3, r3, r2                        @ root accumulator += digit weight (low word) ...
    adcs r4, r5                            @ ... (high word)
    adds r0, r0, r0                        @ remainder <<= 1: low word ...
    adcs r1, r1                            @ ... high word
    subs r0, r0, r2                        @ remainder -= digit weight (low word) ...
    sbcs r1, r5                            @ ... (high word)
    bmi .Ldsqrt_08013F56                   @ remainder negative: add-back digit
    lsrs r2, r2, #1                        @ digit weight (low word) >> 1
    bne .Ldsqrt_08013F70                   @ not exhausted: next subtract digit
    @ Final rounding step.
.Ldsqrt_08013F86:
    adds r3, r3, #1                        @ root accumulator += 1 (low word) ...
    adcs r4, r5                            @ ... (high word)
    @ Pack the result.
.Ldsqrt_08013F8A:
    lsrs r1, r4, #1                        @ r1 = root accumulator (high word) >> 1
    rrx r0, r3                             @ r0 = accumulator low word >> 1 with the bit shifted out of the high word
    add r1, r1, r12, lsl #0x14             @ add the exponent of the result (r12 << 20)
    pop {r4, r5}                           @ restore r4, r5
    @ Return (also the result for operands that are returned unchanged).
.Ldsqrt_08013F96:
    bx lr
    @ Zero or positive subnormal operand (sign and exponent are 0).
.Ldsqrt_08013F98:
    orrs r3, r0, r1                        @ r3 = low word | high word; Z when the operand is +0
    beq .Ldsqrt_08013F96                   @ +0: return it
    push {r4, r5}                          @ save r4, r5
    clz r3, r1                             @ r3 = leading zero count of the high word
    cbnz r1, .Ldsqrt_08013FAC              @ high word not zero: skip the low word count
    clz r4, r0                             @ high word zero: r4 = leading zero count of the low word ...
    adds r3, r3, r4                        @ ... r3 = 32 + that count
    @ r3 = leading zero count of the 64-bit mantissa.
.Ldsqrt_08013FAC:
    subs r3, #0xb                          @ r3 = shift that puts the leading one at bit 52 (clz - 11)
    subs r4, r3, #0x20                     @ r4 = shift - 32; C = shift >= 32
    iteee cs                               @ the next five instructions: 64-bit left shift of r1:r0 by r3
    lslcs r1, r0, r4                       @ shift >= 32: high word = low word << (shift - 32)
    lslcc r1, r3                           @ shift < 32: high word << shift ...
    rsbcc r4, r3, #0x20                    @ ... r4 = 32 - shift
    lsrcc r4, r0, r4                       @ ... r4 = low word >> (32 - shift)
    it cc                                  @ ...
    orrcc r1, r4                           @ ... merged into the high word
    lsls r0, r3                            @ low word << shift
    rsbs r3, r3, #1                        @ r3 = 1 - shift: the exponent of the normalised value
    b .Ldsqrt_08013F0A                     @ continue with the common start
    @ Sign set or exponent 0x7FF.
.Ldsqrt_08013FCE:
    cmp r3, r12                            @ exponent 0x7FF?
    beq .Ldsqrt_08013F96                   @ +infinity or positive NaN (sign 0, exponent 0x7FF): returned unchanged
    cmn r1, #0x100000                      @ high word + 0x00100000: C = 1 and Z = 0 when the high word is above 0xFFF00000, a negative NaN
    bhi .Ldsqrt_08013F96                   @ negative NaN: returned unchanged
    orrs r1, r0, r1, lsl #1                @ r1 = low word | high word << 1 (the operand's high word is overwritten); Z when the operand is -0
    beq .Ldsqrt_08013F96                   @ -0: returned with r1 = 0, i.e. as +0
    mvns r1, r3                            @ r1 = NOT (sign and exponent)
    b .Ldsqrt_neg                          @ errno = EDOM through the tail
    @ Tail: set errno to 0x21 and return (r0-r3 are preserved).
.Ldsqrt_neg:
    push {r0, r1, r2, r3, r4, lr}          @ save r0-r4 and the return address
    bl fn_08023EDC                         @ r0 = address of errno
    movs r1, #0x21                         @ r1 = 0x21 (EDOM)
    str r1, [r0, #0]                       @ errno = 0x21
    pop {r0, r1, r2, r3, r4, pc}           @ restore r0-r4 and return
ENDFUNC fn_08013EF4

