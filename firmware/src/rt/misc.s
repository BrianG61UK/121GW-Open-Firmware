@ =============================================================================
@ misc.s - RT: string length, errno access and the subnormal normaliser of the maths library
@
@ Port of the v2.05 helpers
@   fn_08023CA0  strlen                                  (C library strlen shape, word-at-a-time scan)
@   fn_08023EDC  address of errno                        (v2.05 returns 0x20000228, through the shared "bx lr" at 0x08024278)
@   fn_08023EE8  normalise a subnormal double in memory  (helper of the logarithm, RT log10.s)
@
@ Calling convention (DESIGN.md 6, exception for RT): arguments and results in r0 (r1-r3 scratch), r4-r11 preserved.
@ Every routine is a copy of the v2.05 instruction sequence, re-expressed with symbolic labels.
@ Context: ISR-safe; fn_08023EE8 reads and writes the 8 bytes at the address in r0, nothing else.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"

    .section .text.rt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08023CA0 - length of a NUL-terminated string
@ Replaces : 0x08023CA0 (v2.05 FUN_08023ca0, called by the SD log code for file-name strings)
@ In       : r0 = pointer to the string
@ Out      : r0 = number of bytes before the terminating 0
@ Clobbers : r1-r3, flags
@ Context  : ISR-safe (reads the string, word reads only at word-aligned addresses)
@ RAM      : none (reads the string)
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08023CA0
    add r3, r0, #1                         @ r3 = start + 1
    lsls r1, r0, #0x1e                     @ r1 = start << 30: Z when the pointer is word aligned
    beq .Lstrlen_08023CB2                  @ word aligned: scan words
    @ Byte scan up to a word boundary.
.Lstrlen_08023CA8:
    ldrb r1, [r0], #1                      @ r1 = next byte, pointer advanced
    cbz r1, .Lstrlen_08023CD2              @ byte is the terminator
    lsls r1, r0, #0x1e                     @ r1 = pointer << 30: Z at a word boundary
    bne .Lstrlen_08023CA8                  @ not at a word boundary: next byte
    @ Word scan: test four bytes at a time for a zero byte.
.Lstrlen_08023CB2:
    ldr r2, [r0, #0]                       @ r2 = the word at the pointer
    @ Test the word in r2.
.Lstrlen_08023CB4:
    subs r1, r2, #0x1010101                @ r1 = word - 0x01010101
    bics r1, r2                            @ r1 = (word - 0x01010101) AND NOT word
    tst r1, #0x80808080                    @ any byte with its top bit set in r1 means a zero byte in the word
    itt eq                                 @ no zero byte: ...
    ldreq r2, [r0, #4]!                    @ ... load the next word, pointer += 4 ...
    beq .Lstrlen_08023CB4                  @ ... and test it
    ldrb r1, [r0], #1                      @ a zero byte is in the word: step byte by byte (r1 = byte, pointer advanced)
    @ Byte scan inside the last word.
.Lstrlen_08023CCA:
    cbz r1, .Lstrlen_08023CD2              @ terminator found
    ldrb r1, [r0], #1                      @ next byte
    b .Lstrlen_08023CCA                    @ repeat
    @ Terminator found: pointer is one past it.
.Lstrlen_08023CD2:
    subs r0, r0, r3                        @ length = pointer - (start + 1)
    bx lr
ENDFUNC fn_08023CA0

@ -----------------------------------------------------------------------------
@ fn_08023EDC - address of the C library errno variable
@ Replaces : 0x08023EDC (v2.05 FUN_08023edc, which branches to the shared "bx lr" at 0x08024278)
@ In       : none
@ Out      : r0 = 0x20000228, the address of errno
@ Clobbers : r0
@ Context  : ISR-safe
@ RAM      : none (returns the address of v_20000228)
@ Spec     : DESIGN.md 6.5, 5.1
@ Deviation: none (the return is a local "bx lr" instead of the shared one at 0x08024278)
@ -----------------------------------------------------------------------------
FUNC fn_08023EDC
    ldr r0, =v_20000228                    @ r0 = address of errno (v_20000228, pool word)
    b .Lerrno_ret                          @ return through the "bx lr" below (v2.05 uses the one at 0x08024278)
    @ Return.
.Lerrno_ret:
    bx lr
ENDFUNC fn_08023EDC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08023EE8 - normalise a subnormal double stored in memory
@ Replaces : 0x08023EE8 (v2.05 FUN_08023ee8, called by the logarithm for operands with exponent field 0)
@ In       : r0 = pointer to the double (low word at +0, high word at +4)
@ Out      : r0 = 1 - (number of left shifts that put the leading one at bit 52 of the mantissa); the exponent field
@            of the stored double is left at 0 and the leading one is removed from the mantissa, the sign is kept;
@            a zero mantissa gives r0 = 1 and a stored zero
@ Clobbers : r0-r3, flags (r4, r5 saved and restored)
@ Context  : ISR-safe (reads and writes the 8 bytes at r0)
@ RAM      : the 8 bytes at the address in r0
@ Spec     : DESIGN.md 6.5
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08023EE8
    push {r4, r5}                          @ save r4, r5
    ldr r3, [r0, #4]                       @ r3 = high word
    and r2, r3, #0x80000000                @ r2 = sign bit
    movs r1, #1                            @ r1 = 1, the exponent adjustment counter
    ubfx r3, r3, #0, #0x14                 @ r3 = high mantissa bits (20 bits; sign and exponent removed)
    str r3, [r0, #4]                       @ store the high word without sign and exponent
    cmp r3, #0                             @ high mantissa bits zero?
    itt eq                                 @ yes: test the low word as well ...
    ldreq r3, [r0, #0]
    cmpeq r3, #0                           @ ... low word zero?
    bne .Lnorm_08023F14                    @ mantissa not zero: normalise
    b .Lnorm_08023F20                      @ mantissa zero: finish
    @ Shift the 64-bit mantissa left by one place and count it.
.Lnorm_08023F04:
    ldr r3, [r0, #0]                       @ r3 = low word
    lsrs r5, r3, #0x1f                     @ r5 = top bit of the low word
    orr r4, r5, r4, lsl #1                 @ r4 = high word << 1 | that bit
    str r4, [r0, #4]                       @ store the high word
    lsls r3, r3, #1                        @ low word << 1
    str r3, [r0, #0]                       @ store the low word
    subs r1, r1, #1                        @ counter -= 1
    @ Test whether the leading one has reached bit 52 (bit 20 of the high word).
.Lnorm_08023F14:
    ldr r4, [r0, #4]                       @ r4 = high word
    lsls r3, r4, #0xb                      @ bit 20 of the high word moved to bit 31
    bpl .Lnorm_08023F04                    @ bit 20 clear: shift again
    ubfx r3, r4, #0, #0x14                 @ bit 20 set: remove the leading one ...
    str r3, [r0, #4]                       @ ... and store the high word
    @ Restore the sign and return.
.Lnorm_08023F20:
    ldr r3, [r0, #4]                       @ r3 = high word
    orrs r2, r3                            @ add the sign bit
    str r2, [r0, #4]                       @ store the high word
    mov r0, r1                             @ result = counter
    pop {r4, r5}                           @ restore r4, r5
    bx lr
ENDFUNC fn_08023EE8

