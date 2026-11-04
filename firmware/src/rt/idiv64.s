@ =============================================================================
@ idiv64.s - RT: 64-bit integer division with remainder
@
@ Port of the v2.05 helpers
@   fn_08013FE4  signed 64-bit division with remainder    (__aeabi_ldivmod shape)
@   fn_08014028  unsigned 64-bit division with remainder  (__aeabi_uldivmod shape), with its return-only tail at
@                0x0802038C
@
@ Calling convention (DESIGN.md 6, exception for RT): dividend in r0 (low word) : r1 (high word), divisor in r2 : r3;
@ quotient in r0 : r1, remainder in r2 : r3; r12 and the flags are scratch, r4-r11 are preserved.  The routines
@ are copies of the v2.05 instruction sequences, re-expressed with symbolic labels, so every register, flag and
@ result bit is the one v2.05 produces.
@
@ Behaviour observed by executing the original: division by zero returns with the registers unchanged, that is the
@ dividend as quotient in r0 : r1 and the zero divisor as remainder in r2 : r3 (no trap, no errno); the quotient of the signed routine is truncated toward zero and the remainder has the sign
@ of the dividend (-7 / 2 gives -3 remainder -1); 0x8000000000000000 / -1 gives 0x8000000000000000 remainder 0.
@
@ Context: ISR-safe (stack use only), no state.
@
@ OF-51: a zero divisor gives a defined result instead of the unchanged registers:
@ unsigned, quotient 0xFFFFFFFFFFFFFFFF and remainder = dividend; signed, quotient -1 and remainder = dividend (the
@ convention of hardware dividers such as RISC-V's M extension; no trap, no errno).  Every other operand gives the
@ v2.05 result bit for bit.  No v2.05 caller divides by zero (ORIGINAL_FIRMWARE_ISSUES.md OF-51); the strict image keeps
@ the v2.05 behaviour.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "config.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08013FE4 - signed 64-bit division with remainder
@ Replaces : 0x08013FE4 (v2.05 FUN_08013fe4, the signed 64-bit division helper)
@ In       : r0:r1 = dividend, r2:r3 = divisor (signed 64-bit, low word first)
@ Out      : r0:r1 = quotient (toward zero), r2:r3 = remainder (sign of the dividend)
@ Clobbers : r0-r3, r12, flags (r4 and lr are saved and restored)
@ Context  : ISR-safe (stack use only)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none in the strict image; OF-51 in the production image (zero divisor: quotient -1, remainder = dividend)
@ -----------------------------------------------------------------------------
FUNC fn_08013FE4
    orrs r12, r2, r3                       @ OF-51: divisor zero?
    bne .Lldivmod_v205
    mov r2, r0                             @ remainder = dividend
    mov r3, r1
    mov r0, #-1                            @ quotient = -1
    mov r1, #-1
    bx lr
.Lldivmod_v205:
    ands r12, r3, #0x80000000              @ r12 = sign bit of the divisor; N = divisor negative
    bpl .Lldivmod_08013FF2                 @ divisor non-negative: skip the negation
    negs r3, r3                            @ divisor negative: r3 = -r3 ...
    negs r2, r2                            @ ... r2 = -r2 (C = 1 only when r2 was zero) ...
    sbc r3, r3, #0                         @ ... r3 = r3 - borrow: together a 64-bit negation
    @ Signs of the quotient and the remainder.
.Lldivmod_08013FF2:
    eors r12, r12, r1, asr #0x20           @ r12 = divisor sign bit XOR (all ones when the dividend is negative); C = sign of the dividend; Z when both operands are non-negative
    beq fn_08014028                        @ both non-negative: unsigned division, tail call
    push {r4, lr}                          @ save r4 and the return address
    mov r4, r12                            @ r4 = r12: bit 31 = quotient sign, bit 30 = dividend sign
    bcc .Lldivmod_08014008                 @ dividend non-negative: skip the negation
    negs r1, r1                            @ dividend negative: r1 = -r1 ...
    negs r0, r0                            @ ... r0 = -r0 (C = 1 only when r0 was zero) ...
    sbc r1, r1, #0                         @ ... r1 = r1 - borrow: a 64-bit negation
    @ Unsigned division of the magnitudes.
.Lldivmod_08014008:
    bl fn_08014028                         @ r1:r0 = quotient, r3:r2 = remainder (of the magnitudes)
    lsls r4, r4, #1                        @ C = quotient sign (bit 31 of r4); N = dividend sign (bit 30 of r4 moved to bit 31)
    bcc .Lldivmod_0801401A                 @ quotient non-negative: skip the negation
    negs r1, r1                            @ quotient negative: r1 = -r1 ...
    negs r0, r0                            @ ... r0 = -r0 ...
    sbc r1, r1, #0                         @ ... r1 = r1 - borrow
    tst r4, r4                             @ N = dividend sign again (the flags of the negation are not used)
    @ Remainder sign.
.Lldivmod_0801401A:
    bpl .Lldivmod_08014024                 @ dividend non-negative: the remainder keeps its sign
    negs r3, r3                            @ dividend negative: r3 = -r3 ...
    negs r2, r2                            @ ... r2 = -r2 ...
    sbc r3, r3, #0                         @ ... r3 = r3 - borrow
    @ Return.
.Lldivmod_08014024:
    pop {r4, pc}                           @ restore r4 and return
ENDFUNC fn_08013FE4

@ -----------------------------------------------------------------------------
@ fn_08014028 - unsigned 64-bit division with remainder
@ Replaces : 0x08014028 (v2.05 FUN_08014028, the unsigned 64-bit division helper) and its return-only tail at 0x0802038C
@ In       : r0:r1 = dividend, r2:r3 = divisor (unsigned 64-bit, low word first)
@ Out      : r0:r1 = quotient, r2:r3 = remainder; division by zero returns all registers unchanged (file header)
@ Clobbers : r0-r3, r12, flags (r4-r6 and lr are saved and restored where used)
@ Context  : ISR-safe (stack use only)
@ RAM      : none
@ Spec     : DESIGN.md 6.5
@ Deviation: none in the strict image; OF-51 in the production image (zero divisor: quotient all ones, remainder = dividend)
@ -----------------------------------------------------------------------------
FUNC fn_08014028
    orrs r12, r2, r3                       @ OF-51: divisor zero?
    bne .Luldivmod_v205
    mov r2, r0                             @ remainder = dividend
    mov r3, r1
    mov r0, #-1                            @ quotient = all ones
    mov r1, #-1
    bx lr
.Luldivmod_v205:
    tst r3, r3                             @ divisor high word zero?
    bne .Luldivmod_d64                     @ no: 64-bit divisor
    tst r1, r1                             @ dividend high word zero?
    bne .Luldivmod_dhi0                    @ no: 64-bit dividend with a 32-bit divisor
    cbz r2, .Luldivmod_0801403E            @ both high words zero: divisor zero?
    mov r12, r0                            @ r12 = dividend
    udiv r0, r0, r2                        @ r0 = dividend / divisor
    mls r2, r2, r0, r12                    @ r2 = remainder (r1 = r3 = 0 stay)
    bx lr                                  @ return
    @ Division by zero: return with the registers unchanged (through the return-only tail at 0x0802038C).
.Luldivmod_0801403E:
    b .Luldivmod_ret                       @ tail: bx lr
    @ Divisor below 2 (dividend high word non-zero): carry clear means divisor 0.
.Luldivmod_d_le1:
    bcc .Luldivmod_0801403E                @ divisor zero (carry clear after the compare with 1): division by zero
    movs r2, #0                            @ divisor 1: remainder 0 ...
    movs r3, #0                            @ ... (high word)
    bx lr                                  @ the quotient is the dividend, unchanged
    @ Dividend below the 64-bit divisor: quotient 0, remainder = dividend.
.Luldivmod_less:
    movs r3, r1                            @ r3 = dividend high word
    movs r2, r0                            @ r2 = dividend low word
    movs r1, #0                            @ r1 = 0 ...
    movs r0, #0                            @ ... r0 = 0
    bx lr                                  @ return
    @ 64-bit divisor (high word non-zero).
.Luldivmod_d64:
    cmp r0, r2                             @ compare the dividend with the divisor (low word) ...
    sbcs r12, r1, r3                       @ ... (high word, borrow)
    bcc .Luldivmod_less                    @ dividend below divisor: quotient 0
    push {r4, r5, r6, lr}                  @ save r4-r6 and the return address
    clz r4, r1                             @ r4 = leading zero count of the dividend high word
    clz r5, r3                             @ r5 = leading zero count of the divisor high word
    subs r4, r5, r4                        @ r4 = shift that aligns the divisor with the dividend
    lsls r3, r4                            @ divisor high word << shift
    @ Align the divisor and run the shift-and-subtract loop (r4 = shift < 32, r3 = divisor high word already shifted, r2 = divisor low word).
.Luldivmod_align:
    rsb r5, r4, #0x20                      @ r5 = 32 - shift
    lsrs r6, r2, r5                        @ r6 = divisor low word >> (32 - shift)
    orrs r3, r6                            @ merge into the divisor high word
    lsls r2, r4                            @ divisor low word << shift
    movs r6, #0x80000000                   @ r6 = 0x80000000 ...
    lsrs r6, r4                            @ ... >> shift: the quotient bit that marks the end of the loop
    b .Luldivmod_08014084                  @ enter the loop
    @ Shift-and-subtract loop: move the divisor one place down.
.Luldivmod_0801407E:
    lsrs r3, r3, #1                        @ divisor >>= 1 (high word) ...
    rrxs r2, r2                            @ ... (low word through the carry)
    @ Trial subtraction of the divisor from the dividend.
.Luldivmod_08014084:
    subs r4, r0, r2                        @ trial subtraction: r4:r5 = dividend - divisor (low word) ...
    sbcs r5, r1, r3                        @ ... (high word)
    itt cs                                 @ no borrow: the subtraction is kept ...
    movcs r0, r4
    movcs r1, r5                           @ ... (high word)
    adcs r6, r6                            @ shift the carry into the quotient bits; the marker bit comes out last
    bcc .Luldivmod_0801407E                @ marker not out yet: next bit
    movs r2, r0                            @ r3:r2 = remainder
    movs r3, r1
    movs r0, r6                            @ r0 = quotient
    movs r1, #0                            @ r1 = 0
    pop {r4, r5, r6, pc}                   @ return
    @ Divisor high word zero, dividend high word non-zero.
.Luldivmod_dhi0:
    cmp r2, #1                             @ divisor below 2?
    bls .Luldivmod_d_le1                   @ yes: special cases above
    push {r4, r5, r6, lr}                  @ save r4-r6 and the return address
    lsrs r4, r2, #0x10                     @ divisor below 65536?
    beq .Luldivmod_d16                     @ yes: three-digit division with 16-bit digits
    clz r4, r1                             @ r4 = leading zero count of the dividend high word
    clz r5, r2                             @ r5 = leading zero count of the divisor
    rsb r4, r4, #0x20                      @ r4 = 32 - clz(dividend high word)
    adds r4, r4, r5                        @ r4 = 32 - clz(dividend high word) + clz(divisor): shift that aligns the divisor with the dividend
    subs r6, r4, #0x20                     @ r6 = r4 - 32; borrow when r4 < 32
    bcc .Luldivmod_align                   @ shift below 32: shared aligned loop
    lsls r2, r6                            @ divisor << (r4 - 32): r2 becomes the high word of the shifted divisor (r3 = 0 is its low word)
    movs r4, #0x80000000                   @ r4 = 0x80000000 ...
    lsrs r4, r6                            @ ... >> shift: the end marker, collected in a 64-bit quotient r5:r4
    movs r5, #0                            @ r5 = 0
    b .Luldivmod_080140CE                  @ enter the loop
    @ Shift-and-subtract loop (64-bit quotient): move the divisor one place down.
.Luldivmod_080140C8:
    lsrs r2, r2, #1                        @ divisor >>= 1 (high word r2) ...
    rrxs r3, r3                            @ ... (low word r3 through the carry)
    @ Trial subtraction of the divisor from the dividend.
.Luldivmod_080140CE:
    subs r6, r0, r3                        @ trial subtraction: r6:lr = dividend - divisor (low word) ...
    sbcs lr, r1, r2                        @ ... (high word)
    itt cs                                 @ no borrow: the subtraction is kept ...
    movcs r0, r6
    movcs r1, lr                           @ ... (high word)
    adcs r4, r4                            @ shift the carry into the 64-bit quotient ...
    adcs r5, r5                            @ ... (high word)
    bcc .Luldivmod_080140C8                @ marker not out yet: next bit
    movs r2, r0                            @ r3:r2 = remainder
    movs r3, r1
    movs r0, r4                            @ r1:r0 = quotient
    movs r1, r5
    pop {r4, r5, r6, pc}                   @ return
    @ Divisor below 65536, dividend high word non-zero: long division with 16-bit digits.
.Luldivmod_d16:
    mov r4, r1                             @ r4 = dividend high word
    udiv r1, r1, r2                        @ r1 = high word of the quotient
    mls r5, r2, r1, r4                     @ r5 = remainder of the high word
    lsls r5, r5, #0x10                     @ remainder << 16
    orr r5, r5, r0, lsr #0x10              @ merge the top half of the dividend low word
    udiv r4, r5, r2                        @ r4 = first 16-bit digit
    mls r5, r2, r4, r5                     @ r5 = new remainder
    uxth r0, r0                            @ r0 = low half of the dividend low word
    orr r5, r0, r5, lsl #0x10              @ remainder << 16 merged with it
    udiv r0, r5, r2                        @ r0 = second 16-bit digit
    mls r2, r2, r0, r5                     @ r2 = final remainder
    orr r0, r0, r4, lsl #0x10              @ r0 = second digit | first digit << 16: the low word of the quotient
    pop {r4, r5, r6, pc}                   @ return
    @ Return-only tail (jumped to for division by zero).
.Luldivmod_ret:
    bx lr
ENDFUNC fn_08014028

