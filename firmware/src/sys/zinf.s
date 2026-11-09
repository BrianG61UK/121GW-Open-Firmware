@ =============================================================================
@ zinf.s - inflate: unpack one final dynamic-code deflate block (RFC 1951 3.2.7) into a buffer of known length
@ (DESIGN.md 10 IMP-63)
@
@ Used by the firmware's page Ld (ble/bft.s: packed update files) and, assembled from this same file, by the
@ two-part bootloader's update mode (bootloader/src/bl_ble.s).  The sender packs each piece with zlib (raw deflate,
@ window up to 32 KiB) and sends it packed only when zlib made it one final block with the dynamic code (BFINAL 1,
@ BTYPE 2: every piece of the F-1.31 and B-1.14 images, 2026-11-09); any other piece goes as raw bytes, so the
@ stored and fixed-code blocks are not needed here (the bootloader's flash has no room for them).
@
@ Strict: the stream must be that one block, use exactly srclen bytes (the block ends in the last byte; the bits after
@ it in that byte are padding) and produce exactly dstlen bytes.  Every read is checked against the end of the source, every
@ written byte and every match length against the end of the destination, every distance against the bytes already
@ produced; a code that is not in the table, an over-subscribed code, a bad dynamic header, a stored block whose
@ LEN / NLEN differ: an error, never a wrong byte outside the destination.  The destination may be partly written
@ when an error is returned.
@
@ Huffman decoding as tinf (J. Ibsen): the code lengths give per length the number of codes (counts) and the symbols
@ in code order (syms); a symbol is found bit by bit (at most 15 steps), the codes being canonical (RFC 1951 3.2.2).
@
@ Registers inside zinf (the helpers keep them): r4 work area, r5 bit buffer (unread bits, LSB first), r6 bits in
@ r5 (0..7 between reads), r7 next source byte, r8 end of source, r9 next destination byte, r10 end of destination,
@ r11 start of destination.  An error anywhere jumps to zi_fail, which restores the stack pointer saved at entry.
@
@ RAM: zinf_work, ZC_SIZE (1060) bytes in .bss_port (both linker scripts collect .bss_port*).  No EEPROM, calibration or flash
@ access.  Context: main only (not reentrant).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .equ ZC_SP,     0               @ stack pointer after the entry push (zi_fail returns through it)
    .equ ZC_LENS,   4               @ code lengths, 288 + 32 bytes (at 4: reached with a 16-bit add)
    .equ ZC_LCNT,   324             @ literal / length code: counts[16] (u16; [0] unused)
    .equ ZC_LSYM,   356             @ literal / length code: syms[288] (u16)
    .equ ZC_DCNT,   932             @ distance code (also the code length code of a dynamic header): counts[16]
    .equ ZC_DSYM,   964             @ distance code: syms[32] (u16)
    .equ ZC_OFFS,   1028            @ zi_build: first index per length, u16[16]
    .equ ZC_SIZE,   1060

    .equ ZE_SRC,    1               @ the source ended inside the stream
    .equ ZE_TYPE,   2               @ not one final dynamic-code block
    .equ ZE_CODE,   4               @ a code not in the table, or a symbol out of range
    .equ ZE_TREE,   5               @ over-subscribed code lengths, or a bad dynamic header
    .equ ZE_DIST,   6               @ a distance before the start of the destination
    .equ ZE_OVER,   7               @ more bytes than dstlen
    .equ ZE_END,    8               @ source bytes left after the block, or fewer bytes than dstlen

    .section .bss_port.zinf, "aw", %nobits
    .balign 4
zinf_work:      .space ZC_SIZE

    .section .rodata.zinf, "a", %progbits
zinf_clord:     .byte 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15   @ code length code order

    .section .text.sys.zinf, "ax", %progbits

@ -----------------------------------------------------------------------------
@ zinf - unpack the raw deflate stream r0 (r1 bytes) into r2 (exactly r3 bytes)
@ In       : r0 source, r1 source length, r2 destination, r3 destination length
@ Out      : r0 = 0 done, else ZE_* (1 .. 8)
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ Stack    : 36 + 24 bytes of locals + 24 in the helpers
@ -----------------------------------------------------------------------------
FUNC zinf
    push {r4-r11, lr}
    ldr r4, =zinf_work
    mov r7, r0
    add r8, r0, r1
    mov r9, r2
    mov r11, r2
    add r10, r2, r3
    movs r5, #0
    movs r6, #0
    mov r0, sp
    str r0, [r4, #ZC_SP]                    @ zi_fail returns from here
    sub sp, sp, #24                         @ [sp] hlit, [4] total lengths, [8] lengths read, [12] match length,
                                            @ [16] match distance base
.Lzi_block:
    movs r0, #3
    bl zi_bits                              @ BFINAL, BTYPE: one final block of the dynamic code, 1 | 2 << 1
    cmp r0, #5
    beq .Lzi_dynamic
    movs r0, #ZE_TYPE
    b zi_fail

@ dynamic code: HLIT, HDIST, HCLEN, the code length code, then the lengths of both codes
.Lzi_dynamic:
    movs r0, #5
    bl zi_bits
    addw r0, r0, #257
    movw r1, #286
    cmp r0, r1
    bhi .Lzi_tree_bad
    str r0, [sp, #0]                        @ hlit
    movs r0, #5
    bl zi_bits
    adds r0, r0, #1
    cmp r0, #30
    bhi .Lzi_tree_bad
    ldr r1, [sp, #0]
    add r0, r0, r1
    str r0, [sp, #4]                        @ total = hlit + hdist
    adds r0, r4, #ZC_LENS                   @ the 19 code length code lengths cleared
    movs r1, #0
    movs r2, #0
1:  strb r2, [r0, r1]
    adds r1, r1, #1
    cmp r1, #19
    bne 1b
    movs r0, #4
    bl zi_bits
    adds r3, r0, #4                         @ r3 = hclen 4 .. 19, r2 = index (zi_bits keeps r2, r3)
2:  movs r0, #3
    bl zi_bits
    ldr r1, =zinf_clord
    ldrb r1, [r1, r2]
    add r1, r1, r4
    strb r0, [r1, #ZC_LENS]
    adds r2, r2, #1
    cmp r2, r3
    bne 2b
    adds r0, r4, #ZC_LENS                   @ the code length code, in the distance tables
    movs r1, #19
    addw r2, r4, #ZC_DCNT
    addw r3, r4, #ZC_DSYM
    bl zi_build
    movs r0, #0
    str r0, [sp, #8]                        @ n = lengths read
3:  ldr r0, [sp, #8]
    ldr r1, [sp, #4]
    cmp r0, r1
    bhs 9f
    addw r0, r4, #ZC_DCNT
    addw r1, r4, #ZC_DSYM
    bl zi_decode                            @ r0 = 0 .. 18
    cmp r0, #16
    bhs 4f
    ldr r1, [sp, #8]                        @ 0 .. 15: one length
    add r2, r4, r1
    strb r0, [r2, #ZC_LENS]
    adds r1, r1, #1
    str r1, [sp, #8]
    b 3b
4:  bne 5f
    ldr r1, [sp, #8]                        @ 16: the previous length 3 .. 6 times
    cmp r1, #0
    beq .Lzi_tree_bad                       @ 16 as the first length
    add r2, r4, r1
    ldrb r2, [r2, #(ZC_LENS - 1)]           @ r2 = value (zi_bits keeps it)
    movs r0, #2
    bl zi_bits
    adds r0, r0, #3
    b 7f
5:  movs r2, #0                             @ 17: zero 3 .. 10 times; 18: zero 11 .. 138 times
    cmp r0, #17
    bne 6f
    movs r0, #3
    bl zi_bits
    adds r0, r0, #3
    b 7f
6:  movs r0, #7
    bl zi_bits
    adds r0, r0, #11
7:  ldr r1, [sp, #8]                        @ r0 = repeat count
    add r3, r1, r0
    ldr r12, [sp, #4]
    cmp r3, r12
    bhi .Lzi_tree_bad                       @ beyond hlit + hdist
    str r3, [sp, #8]
    add r3, r4, r1
    adds r3, r3, #ZC_LENS
8:  strb r2, [r3], #1
    subs r0, r0, #1
    bne 8b
    b 3b
9:  adds r0, r4, #ZC_LENS
    ldrb r1, [r0, #256]
    cmp r1, #0
    beq .Lzi_tree_bad                       @ no end-of-block code
    ldr r1, [sp, #0]
    addw r2, r4, #ZC_LCNT
    addw r3, r4, #ZC_LSYM
    bl zi_build                             @ literal / length code from lens[0 .. hlit)
    ldr r1, [sp, #0]
    adds r0, r4, #ZC_LENS
    add r0, r0, r1
    ldr r2, [sp, #4]
    sub r1, r2, r1                          @ hdist
    addw r2, r4, #ZC_DCNT
    addw r3, r4, #ZC_DSYM
    bl zi_build                             @ distance code from lens[hlit .. total)
    b .Lzi_data
.Lzi_tree_bad:
    movs r0, #ZE_TREE
    b zi_fail

@ compressed data of a fixed or dynamic block: literals, matches, end of block
.Lzi_data:
    addw r0, r4, #ZC_LCNT
    addw r1, r4, #ZC_LSYM
    bl zi_decode
    cmp r0, #256
    bhs 1f
    cmp r9, r10                             @ a literal
    bhs .Lzi_over
    strb r0, [r9], #1
    b .Lzi_data
1:  beq .Lzi_next                           @ 256: end of block
    @ length (RFC 1951 3.2.5): s = code - 257; s < 8: 3 + s; s = 28: 258; else e = s / 4 - 1 extra bits on
    @ ((4 | s mod 4) << e) + 3
    subw r0, r0, #257
    cmp r0, #29
    bhs .Lzi_code_bad
    adds r2, r0, #3
    cmp r0, #8
    blo 2f
    movw r2, #258
    cmp r0, #28
    beq 2f
    and r2, r0, #3
    orr r2, r2, #4
    lsrs r0, r0, #2
    subs r0, r0, #1
    lsls r2, r2, r0
    adds r2, r2, #3
    b 3f
2:  movs r0, #0
3:  bl zi_bits                              @ r2 (base) kept by zi_bits
    add r2, r2, r0
    str r2, [sp, #12]                       @ match length 3 .. 258
    @ distance: d < 4: 1 + d; else e = d / 2 - 1 extra bits on ((2 | d mod 2) << e) + 1
    addw r0, r4, #ZC_DCNT
    addw r1, r4, #ZC_DSYM
    bl zi_decode
    cmp r0, #30
    bhs .Lzi_code_bad
    adds r2, r0, #1
    cmp r0, #4
    blo 4f
    and r2, r0, #1
    orr r2, r2, #2
    lsrs r0, r0, #1
    subs r0, r0, #1
    lsls r2, r2, r0
    adds r2, r2, #1
    b 5f
4:  movs r0, #0
5:  bl zi_bits
    add r2, r2, r0                          @ r2 = distance 1 .. 32768
    sub r3, r9, r11
    cmp r2, r3
    bls 6f
    movs r0, #ZE_DIST
    b zi_fail
6:  ldr r1, [sp, #12]
    sub r3, r10, r9
    cmp r1, r3
    bhi .Lzi_over
    sub r2, r9, r2
7:  ldrb r3, [r2], #1                       @ byte by byte: an overlapping match repeats the last bytes
    strb r3, [r9], #1
    subs r1, r1, #1
    bne 7b
    b .Lzi_data
.Lzi_code_bad:
    movs r0, #ZE_CODE
    b zi_fail
.Lzi_over:
    movs r0, #ZE_OVER
    b zi_fail

@ after the block: the checks of the end
.Lzi_next:
    cmp r7, r8
    it eq
    cmpeq r9, r10
    beq 1f
    movs r0, #ZE_END                        @ source bytes left, or fewer bytes than dstlen
    b zi_fail
1:  movs r0, #0
    add sp, sp, #24
    pop {r4-r11, pc}
ENDFUNC zinf

@ -----------------------------------------------------------------------------
@ zi_fail - error exit of zinf from any depth: r0 = ZE_*
@ -----------------------------------------------------------------------------
LFUNC zi_fail
    ldr r1, [r4, #ZC_SP]
    mov sp, r1
    pop {r4-r11, pc}
ENDFUNC zi_fail

@ -----------------------------------------------------------------------------
@ zi_bits - the next r0 bits (0 .. 16) of the stream, LSB first
@ Out      : r0 = value; Clobbers r1, flags; updates r5, r6, r7
@ -----------------------------------------------------------------------------
LFUNC zi_bits
1:  cmp r6, r0
    bhs 2f
    cmp r7, r8
    bhs 3f
    ldrb r1, [r7], #1
    lsl r1, r1, r6
    orr r5, r5, r1
    adds r6, r6, #8
    b 1b
2:  movs r1, #1
    lsl r1, r1, r0
    subs r1, r1, #1
    and r1, r5, r1
    lsr r5, r5, r0
    sub r6, r6, r0
    mov r0, r1
    bx lr
3:  movs r0, #ZE_SRC
    b zi_fail
ENDFUNC zi_bits

@ -----------------------------------------------------------------------------
@ zi_decode - the next symbol of the code r0 (counts[16]) / r1 (syms)
@ Out      : r0 = symbol; Clobbers r1-r3, r12, flags; updates r5, r6, r7
@ Note     : canonical code: per length the codes of that length follow those of the shorter ones; cur counts the
@            code read so far minus the codes of its length, sum the codes of all lengths so far (tinf_decode_symbol)
@ -----------------------------------------------------------------------------
LFUNC zi_decode
    push {lr}
    movs r2, #0                             @ cur
    movs r3, #0                             @ sum
    mov lr, #15                             @ lengths left
1:  cbnz r6, 2f
    cmp r7, r8
    bhs 4f
    ldrb r5, [r7], #1                       @ r5 was 0 (no bits left)
    movs r6, #8
2:  and r12, r5, #1
    lsrs r5, r5, #1
    subs r6, r6, #1
    orr r2, r12, r2, lsl #1                 @ cur = 2 cur + bit
    ldrh r12, [r0, #2]!                     @ counts[len]
    add r3, r3, r12
    subs r2, r2, r12
    bmi 3f                                  @ the code has this length
    subs lr, lr, #1
    bne 1b
    movs r0, #ZE_CODE                       @ 15 bits and no code: not in the table
    b zi_fail
3:  add r3, r3, r2
    ldrh r0, [r1, r3, lsl #1]
    pop {pc}
4:  movs r0, #ZE_SRC
    b zi_fail
ENDFUNC zi_decode

@ -----------------------------------------------------------------------------
@ zi_build - the code of r1 lengths at r0 (bytes, 0 = unused symbol) into counts r2 and syms r3
@ Clobbers : r0-r3, r12, flags (r4-r8 kept)
@ Note     : an over-subscribed set of lengths is refused (ZE_TREE); an incomplete one is allowed (RFC 1951 allows a
@            single distance code) and a code outside it is refused by zi_decode
@ -----------------------------------------------------------------------------
LFUNC zi_build
    push {r4-r8, lr}
    movs r12, #0
    movs r5, #0
1:  strh r12, [r2, r5]                      @ counts cleared
    adds r5, r5, #2
    cmp r5, #32
    bne 1b
    movs r5, #0
2:  cmp r5, r1                              @ counts[length]++
    bhs 3f
    ldrb r6, [r0, r5]
    lsls r6, r6, #1
    ldrh r7, [r2, r6]
    adds r7, r7, #1
    strh r7, [r2, r6]
    adds r5, r5, #1
    b 2b
3:  strh r12, [r2]                          @ counts[0] = 0
    movs r5, #1                             @ codes left of the current length
    movs r6, #2
4:  lsls r5, r5, #1
    ldrh r7, [r2, r6]
    subs r5, r5, r7
    bmi 9f
    adds r6, r6, #2
    cmp r6, #32
    bne 4b
    addw r8, r4, #ZC_OFFS                   @ offs[len] = codes of the shorter lengths
    movs r5, #0
    movs r6, #0
5:  strh r5, [r8, r6]
    ldrh r7, [r2, r6]
    adds r5, r5, r7
    adds r6, r6, #2
    cmp r6, #32
    bne 5b
    movs r5, #0
6:  cmp r5, r1                              @ syms in code order
    bhs 8f
    ldrb r6, [r0, r5]
    cbz r6, 7f
    lsls r6, r6, #1
    ldrh r7, [r8, r6]
    strh r5, [r3, r7, lsl #1]
    adds r7, r7, #1
    strh r7, [r8, r6]
7:  adds r5, r5, #1
    b 6b
8:  pop {r4-r8, pc}
9:  movs r0, #ZE_TREE
    b zi_fail
ENDFUNC zi_build
