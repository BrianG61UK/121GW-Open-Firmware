@ =============================================================================
@ log10.s - RT: logarithm of a double (log10, natural logarithm and base-2 variants of one routine)
@
@ Port of the v2.05 helper fn_0801BB5C and its body at 0x080204C4 (the ARM compiler maths library logarithm).  The
@ entry 0x0801BB5C is "movs r2, #1; b 0x080204C4": the body selects the result by the flag in r2:
@   r2 > 0   log10(x)   (the only variant v2.05 calls, through fn_0801BB5C)
@   r2 = 0   ln(x)      (reachable only through fn_080204C4)
@   r2 < 0   log2(x)    (reachable only through fn_080204C4)
@ All three are ported because the code is in the image (nothing is dropped); the routine tests run the ln and log2
@ variants as well.
@
@ Algorithm of the body (same structure as the classic logarithm of the C maths library): x = 2^k * x' with x' in
@ [sqrt(1/2), sqrt(2)); f = x' - 1; s = f / (x' + 1); z = s * s; P(z) = c1 + c2 z + ... + c7 z^6 (Horner, seven
@ constants from the pool); R = z * P; ln(x) = k * ln2_hi + ((f - s * (f - R)) + k * ln2_lo); the log10 and log2
@ variants scale the same three parts by 1/ln(10) or log2(e), each constant split in a high part and a low part
@ (ivln10_hi + ivln10_lo, log10_2_hi + log10_2_lo, log2e_hi + log2e_lo) so that the products with f and k stay exact.
@ All arithmetic is done with the RT helpers (dmul fn_0801BB64, dadd fn_080131B8, dsub fn_0801FB9C, ddiv fn_0801B874,
@ i2d fn_08013EC4, dcmp fn_08023F2C, the subnormal normaliser fn_08023EE8 and the errno pointer fn_08023EDC).
@
@ Calling convention (DESIGN.md 6, exception for RT): x in r0 (low word) : r1 (high word), result in r0 : r1; r2,
@ r3, r12 and the flags are scratch, r4-r11 are preserved.  The routine is a copy of the v2.05 instruction sequence,
@ re-expressed with symbolic labels, so every register, flag and result bit is the one v2.05 produces.
@
@ Behaviour observed by executing the original: log10(0) = -infinity (r0 = 0, r1 = 0xFFF00000) with errno 0x22
@ (ERANGE); log10 of a negative operand (including -infinity) = r0 = 0xFFFFFFFF, r1 = 0x7FFFFFFF with errno 0x21
@ (EDOM); log10(+infinity) and log10 of a NaN are returned unchanged; log10(100.0) = 2.0 exactly; the result is not
@ always the correctly rounded value (DESIGN.md 6.5).
@
@ Stack: the body pushes ten registers, the operand and 16 bytes of locals (64 bytes) plus the stack use of the
@ helpers it calls.
@ Context: ISR-safe in principle (no state except errno 0x20000228); v2.05 calls it from the main loop only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0801BB5C - log10 of a double (entry) with the body fn_080204C4 (flag-selected log10 / ln / log2)
@ Replaces : 0x0801BB5C (entry; v2.05 FUN_0801bb5c) and 0x080204C4 (body; v2.05 LAB_080204c4 inside the same function)
@ In       : fn_0801BB5C: r0:r1 = x.  fn_080204C4: r0:r1 = x, r2 = flag (> 0 log10, 0 ln, < 0 log2)
@ Out      : r0:r1 = the logarithm; for the special operands see the file header
@ Clobbers : r0-r3, r12, flags (r4-r8, r10, r11 saved and restored)
@ Context  : stack use of 64 bytes plus the called helpers; writes errno 0x20000228 for x <= 0
@ RAM      : writes v_20000228 (errno) through fn_08023EDC
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801BB5C
    movs r2, #1                            @ flag = 1: log10
    b fn_080204C4                          @ continue in the body
    @ Body.  In: r0:r1 = x, r2 = flag.  The flag and r1 are saved at [sp, #0x18] and [sp, #0x1c] of the frame built below; x is kept at [sp, #0x10] (low word) and [sp, #0x14] (high word).
FUNC fn_080204C4
    stmdb sp!, {r1, r2, r4, r5, r6, r7, r8, r10, r11, lr} @ save the registers and r1, r2 (the flag ends up at [sp, #0x1c] after the pushes below)
    push {r0, r1}                          @ push x
    ubfx r0, r1, #0x14, #0xb               @ r0 = exponent field of x
    movw r1, #0x7ff                        @ r1 = 0x7FF
    cmp r0, r1                             @ exponent 0x7FF (infinity or NaN)?
    sub sp, #0x10                          @ 16 bytes of locals (flags unchanged)
    bne .Llog10_080204F2                   @ not 0x7FF: normal, subnormal or zero
    ldr r0, [sp, #0x14]                    @ infinity/NaN: r0 = high word of x
    movs r7, #0                            @ r7 = 0 (k = 0 for the special cases)
    lsls r0, r0, #0xc                      @ mantissa bits of the high word (Z when they are all zero)
    itt eq                                 @ high mantissa bits zero: ...
    ldreq r0, [sp, #0x10]                  @ ... test the low word as well
    cmpeq r0, #0
    bne .Llog10_080204EC                   @ mantissa not zero: a NaN, returned unchanged
    ldr r0, [sp, #0x14]                    @ infinity: r0 = high word, test the sign
    cmp r0, #0
    bmi .Llog10_0802051C                   @ negative infinity: handle as a negative operand
    @ Return x unchanged.
.Llog10_080204EC:
    ldrd r0, r1, [sp, #0x10]               @ r0:r1 = x
    b .Llog10_08020710
    @ Exponent field is not 0x7FF.
.Llog10_080204F2:
    cmp r0, #1                             @ exponent field >= 1: a normal number
    bge .Llog10_0802050E
    add r0, sp, #0x10                      @ exponent field 0: zero or subnormal; r0 = address of x ...
    bl fn_08023EE8                         @ ... normalise it: r0 = 1 - shift count (the exponent adjustment), the mantissa in place is normalised
    cmp r0, #1                             @ adjustment < 1: a subnormal, continue
    blt .Llog10_0802050E
    bl fn_08023EDC                         @ x is zero: r0 = address of errno ...
    movs r1, #0x22                         @ ... errno = 0x22 (ERANGE)
    str r1, [r0, #0]
    movs r0, #0                            @ result low word 0 ...
    ldr r1, =0xFFF00000                    @ ... high word 0xFFF00000: -infinity
    b .Llog10_08020710                     @ return
    @ Normal or normalised subnormal operand: scale x into [0.5, 1).
.Llog10_0802050E:
    ldr r2, [sp, #0x14]                    @ r2 = high word of x
    movw r1, #0x3fe                        @ r1 = 0x3FE, the exponent field of a number in [0.5, 1)
    bfi r2, r1, #0x14, #0xb                @ replace the exponent field of x by 0x3FE
    str r2, [sp, #0x14]                    @ store the scaled x
    subs r7, r0, r1                        @ r7 = k = exponent field (or adjustment) - 0x3FE
    @ Sign test (also the entry for a negative infinity).
.Llog10_0802051C:
    ldr r0, [sp, #0x14]                    @ r0 = high word of x
    cmp r0, #0
    bpl .Llog10_08020534                   @ non-negative: compute the logarithm
    bl fn_08023EDC                         @ negative operand: r0 = address of errno ...
    movs r1, #0x21                         @ ... errno = 0x21 (EDOM)
    str r1, [r0, #0]
    mov r0, #0xffffffff                    @ result low word 0xFFFFFFFF ...
    mvn r1, #0x80000000                    @ ... high word 0x7FFFFFFF
    b .Llog10_08020710                     @ return
    @ Reduce x' to [sqrt(1/2), sqrt(2)).
.Llog10_08020534:
    ldrd r0, r1, [sp, #0x10]               @ r0:r1 = x'
    ldr r2, =0x667F3BCD                    @ r2 = low word of sqrt(1/2) = 0x3FE6A09E667F3BCD
    ldr r3, =0x3FE6A09E                    @ r3 = high word of sqrt(1/2)
    bl fn_08023F2C                         @ compare x' with sqrt(1/2) (double compare, flags)
    bcs .Llog10_08020556                   @ x' >= sqrt(1/2): no scaling
    ldrd r2, r3, [sp, #0x10]               @ x' < sqrt(1/2): r2:r3 = x' ...
    movs r0, #0                            @ ... r0:r1 = 2.0 (0x4000000000000000) ...
    mov r1, #0x40000000
    bl fn_0801BB64                         @ ... x' * 2 ...
    strd r0, r1, [sp, #0x10]               @ ... store it
    subs r7, r7, #1                        @ ... k = k - 1
    @ f = x' - 1, then s = f / (x' + 1) and z = s * s.
.Llog10_08020556:
    ldrd r2, r3, [sp, #0x10]               @ r2:r3 = x'
    movs r0, #0                            @ r0 = 0
    ldr r1, =0xBFF00000                    @ r1 = high word of -1.0 (0xBFF00000)
    bl fn_080131B8                         @ r0:r1 = x' - 1 = f
    ldrd r2, r3, [sp, #0x10]               @ r2:r3 = x'
    mov r4, r0                             @ r4:r5 = f
    mov r5, r1
    movs r0, #0                            @ r0 = 0
    ldr r1, =0x3FF00000                    @ r1 = high word of 1.0 (0x3FF00000)
    bl fn_080131B8                         @ r0:r1 = x' + 1
    mov r2, r0                             @ r2:r3 = x' + 1
    mov r3, r1
    mov r0, r4                             @ r0:r1 = f
    mov r1, r5
    bl fn_0801B874                         @ r0:r1 = s = f / (x' + 1)
    mov r10, r0                            @ r10:r11 = s
    mov r11, r1
    mov r2, r10                            @ r2:r3 = s
    mov r3, r11
    bl fn_0801BB64                         @ r0:r1 = s * s = z
    mov r6, r0                             @ r6:r8 = z
    mov r8, r1
    @ Horner evaluation of P(z) = c1 + z * (c2 + z * (c3 + ... + z * c7)): each step multiplies by z and adds the next constant.
    ldr r0, =0xBF29DEF7                    @ r0 = low word of c7 = 0x3FC2F8D8BF29DEF7 (0.14821919759901167)
    ldr r1, =0x3FC2F8D8                    @ r1 = high word of c7
    mov r2, r6                             @ r2:r3 = z
    mov r3, r8
    bl fn_0801BB64                         @ r0:r1 = c7 * z
    ldr r2, =0xCCFEB3F4                    @ r2 = low word of c6 = 0x3FC3991ACCFEB3F4 (0.15310988435285788)
    ldr r3, =0x3FC3991A                    @ r3 = high word of c6
    bl fn_080131B8                         @ r0:r1 = c7 * z + c6
    mov r2, r6                             @ r2:r3 = z
    mov r3, r8
    bl fn_0801BB64                         @ r0:r1 *= z
    ldr r2, =0xD968CB62                    @ r2 = low word of c5 = 0x3FC7466FD968CB62 (0.1818370639390095)
    ldr r3, =0x3FC7466F                    @ r3 = high word of c5
    bl fn_080131B8                         @ r0:r1 += c5
    mov r2, r6                             @ r2:r3 = z
    mov r3, r8
    bl fn_0801BB64                         @ r0:r1 *= z
    ldr r2, =0xDA12C9C6                    @ r2 = low word of c4 = 0x3FCC71C4DA12C9C6 (0.22222195289721308)
    ldr r3, =0x3FCC71C4                    @ r3 = high word of c4
    bl fn_080131B8                         @ r0:r1 += c4
    mov r2, r6                             @ r2:r3 = z
    mov r3, r8
    bl fn_0801BB64                         @ r0:r1 *= z
    ldr r2, =0x948AE94A                    @ r2 = low word of c3 = 0x3FD24924948AE94A (0.28571428781619501)
    ldr r3, =0x3FD24924                    @ r3 = high word of c3
    bl fn_080131B8                         @ r0:r1 += c3
    mov r2, r6                             @ r2:r3 = z
    mov r3, r8
    bl fn_0801BB64                         @ r0:r1 *= z
    ldr r2, =0x99975FF7                    @ r2 = low word of c2 = 0x3FD9999999975FF7 (0.399999999991905)
    ldr r3, =0x3FD99999                    @ r3 = high word of c2
    bl fn_080131B8                         @ r0:r1 += c2
    mov r2, r6                             @ r2:r3 = z
    mov r3, r8
    bl fn_0801BB64                         @ r0:r1 *= z
    ldr r2, =0x555555BC                    @ r2 = low word of c1 = 0x3FE55555555555BC (0.66666666666667806)
    ldr r3, =0x3FE55555                    @ r3 = high word of c1
    bl fn_080131B8                         @ r0:r1 += c1 = P(z)
    mov r2, r6                             @ r2:r3 = z
    mov r3, r8
    bl fn_0801BB64                         @ r0:r1 = R = z * P(z)
    mov r2, r0                             @ r2:r3 = R
    mov r3, r1
    mov r0, r4                             @ r0:r1 = f
    mov r1, r5
    bl fn_0801FB9C                         @ r0:r1 = f - R
    mov r2, r10                            @ r2:r3 = s
    mov r3, r11
    bl fn_0801BB64                         @ r0:r1 = s * (f - R)
    mov r6, r0                             @ r6:r8 = s * (f - R)
    mov r8, r1
    sxth r0, r7                            @ r0 = k as a signed 16-bit number
    bl fn_08013EC4                         @ r0:r1 = (double) k
    mov r7, r0                             @ r7 = low word of (double) k
    ldr r0, [sp, #0x1c]                    @ r0 = flag
    mov r11, r1                            @ r11 = high word of (double) k
    cbnz r0, .Llog10_08020654              @ flag not zero: log10 or log2 variant
    @ Flag = 0: natural logarithm.  ln(x) = k * ln2_hi + ((k * ln2_lo - s * (f - R)) + f), summed in this order.
    ldr r0, =0xF79ABC9E                    @ r0 = low word of ln2_lo = ln2 - ln2_hi = 0x3E7F7D1CF79ABC9E (1.1730463525082348e-07)
    ldr r1, =0x3E7F7D1C                    @ r1 = high word
    mov r2, r7                             @ r2:r3 = (double) k
    mov r3, r11
    bl fn_0801BB64                         @ r0:r1 = k * (that constant)
    mov r2, r6                             @ r2:r3 = s * (f - R)
    mov r3, r8
    bl fn_0801FB9C                         @ r0:r1 = k * const - s * (f - R)
    mov r2, r4                             @ r2:r3 = f
    mov r3, r5
    bl fn_080131B8                         @ r0:r1 += f
    mov r4, r0                             @ r4:r5 = that sum
    mov r5, r1
    mov r0, #0xc0000000                    @ r0 = low word of ln2_hi = 0xC0000000 (ln2_hi = 0x3FE62E42C0000000 = 0.6931470632553101)
    ldr r1, =0x3FE62E42                    @ r1 = high word of ln2_hi
    mov r2, r7                             @ r2:r3 = (double) k
    mov r3, r11
    bl fn_0801BB64                         @ r0:r1 = k * ln2_hi
    mov r2, r4                             @ r2:r3 = the sum
    mov r3, r5
    b .Llog10_0802070C                     @ add and return (at 0x0802070C)
    @ Flag non-zero: positive = log10, negative = log2.
.Llog10_08020654:
    cmp r0, #1                             @ flag < 1: log2 variant
    blt .Llog10_080206C6
    movs r0, #0                            @ r0 = 0
    ldr r1, =0x3FDBCB7B                    @ r1 = high word of ivln10_hi (the high part of 1/ln(10)) = 0x3FDBCB7B00000000 (0.4342944622039795)
    mov r2, r4                             @ r2:r3 = f
    mov r3, r5
    bl fn_0801BB64                         @ r0:r1 = f * ivln10_hi
    strd r0, r1, [sp, #8]                  @ store it at [sp, #8]
    mov r2, r4                             @ r2 = low word of f
    ldr r0, =0x0E32A6AB                    @ r0 = low word of ivln10_lo = 1/ln(10) - ivln10_hi = 0x3E5526E50E32A6AB (1.9699272335463627e-08)
    ldr r1, =0x3E5526E5                    @ r1 = high word
    mov r3, r5                             @ r3 = high word of f
    bl fn_0801BB64                         @ r0:r1 = f * ivln10_lo
    strd r0, r1, [sp]                      @ store it at [sp, #0]
    mov r2, r7                             @ r2 = low word of (double) k
    ldr r0, =0x7FBCC47C                    @ r0 = low word of log10_2_lo = log10(2) - log10_2_hi = 0x3E7427DE7FBCC47C (7.5085978265526235e-08)
    ldr r1, =0x3E7427DE                    @ r1 = high word
    mov r3, r11                            @ r3 = high word of (double) k
    bl fn_0801BB64                         @ r0:r1 = k * constant
    mov r4, r0                             @ r4:r5 = k * constant
    mov r5, r1
    mov r0, r6                             @ r0:r1 = s * (f - R)
    mov r1, r8
    ldr r2, =0x1526E50E                    @ r2 = low word of 1/ln(10) = 0x3FDBCB7B1526E50E (0.43429448190325182)
    ldr r3, =0x3FDBCB7B                    @ r3 = high word
    bl fn_0801BB64                         @ r0:r1 = s * (f - R) * (1/ln(10))
    mov r2, r0                             @ r2:r3 = that product
    mov r3, r1
    mov r0, r4                             @ r0:r1 = k * constant
    mov r1, r5
    bl fn_0801FB9C                         @ r0:r1 = k * constant - s * (f - R) / ln(10)
    ldrd r2, r3, [sp]                      @ r2:r3 = f * ivln10_lo (from [sp, #0])
    bl fn_080131B8                         @ r0:r1 += f * ivln10_lo
    ldrd r2, r3, [sp, #8]                  @ r2:r3 = f * ivln10_hi (from [sp, #8])
    bl fn_080131B8                         @ r0:r1 += f * ivln10_hi
    mov r4, r0                             @ r4:r5 = the sum
    mov r5, r1
    movs r0, #0                            @ r0 = 0
    ldr r1, =0x3FD34413                    @ r1 = high word of log10_2_hi = 0x3FD3441300000000 (0.30102992057800293)
    mov r2, r7                             @ r2:r3 = (double) k
    mov r3, r11
    bl fn_0801BB64                         @ r0:r1 = k * log10_2_hi
    mov r2, r4                             @ r2:r3 = the sum
    mov r3, r5
    b .Llog10_0802070C                     @ add and return (at 0x0802070C)
    @ Flag negative: base-2 logarithm.
.Llog10_080206C6:
    mov r0, #0x60000000                    @ r0 = low word of log2e_hi (the high part of log2(e)) = 0x60000000 (0x3FF7154760000000 = 1.4426950216293335)
    ldr r1, =0x3FF71547                    @ r1 = high word
    mov r2, r4                             @ r2:r3 = f
    mov r3, r5
    bl fn_0801BB64                         @ r0:r1 = f * log2e_hi
    strd r0, r1, [sp]                      @ store it at [sp, #0]
    mov r2, r4                             @ r2 = low word of f
    ldr r0, =0xF85DDF44                    @ r0 = low word of log2e_lo = log2(e) - log2e_hi = 0x3E54AE0BF85DDF44 (1.9259629911266175e-08)
    ldr r1, =0x3E54AE0B                    @ r1 = high word
    mov r3, r5                             @ r3 = high word of f
    bl fn_0801BB64                         @ r0:r1 = f * log2e_lo
    mov r4, r0                             @ r4:r5 = f * log2e_lo
    mov r5, r1
    ldr r0, =0x652B82FE                    @ r0 = low word of log2(e) = 0x3FF71547652B82FE (1.4426950408889634)
    ldr r1, =0x3FF71547                    @ r1 = high word
    mov r2, r6                             @ r2:r3 = s * (f - R)
    mov r3, r8
    bl fn_0801BB64                         @ r0:r1 = s * (f - R) * log2(e)
    mov r2, r0                             @ r2:r3 = that product
    mov r3, r1
    mov r0, r4                             @ r0:r1 = f * log2e_lo
    mov r1, r5
    bl fn_0801FB9C                         @ r0:r1 = f * log2e_lo - s * (f - R) * log2(e)
    ldrd r2, r3, [sp]                      @ r2:r3 = f * log2e_hi (from [sp, #0])
    bl fn_080131B8                         @ r0:r1 += f * log2e_hi
    mov r2, r7                             @ r2:r3 = (double) k
    mov r3, r11
    @ Final addition of the three variants: result = r0:r1 + r2:r3.
.Llog10_0802070C:
    bl fn_080131B8                         @ r0:r1 += r2:r3
    @ Return.
.Llog10_08020710:
    add sp, #0x20                          @ drop the locals and the saved x, r1, r2 (0x20 bytes)
    ldmia sp!, {r4, r5, r6, r7, r8, r10, r11, pc} @ restore the registers and return
ENDFUNC fn_0801BB5C
    .ltorg

