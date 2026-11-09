@ =============================================================================
@ zdef.s - deflate: pack a buffer into one raw deflate block with the fixed code (RFC 1951 3.2.6; DESIGN.md 10 IMP-63)
@
@ Used by the card request READZ (ble/bftsd.s): the companion unpacks with zlib (raw deflate).  One final block,
@ BTYPE 01 (the fixed literal / length and distance codes: no code tables to build or send).  LZ77 greedy: the next
@ three bytes are hashed into a table of the last position seen (1024 entries), one candidate is compared, the
@ longest match from it (3 .. 258 bytes, distance 1 .. the bytes before) is taken, else a literal; every position is
@ entered into the table, also the ones inside a match.  The source may be at most 65534 bytes (positions + 1 in u16;
@ READZ asks for at most 4096, so distances stay below 32768 as the format requires).
@
@ Bits: LSB first into the output bytes; the Huffman codes go most significant bit first (RFC 1951 3.1.1), so each
@ code is bit-reversed (rbit) before it is added; extra bits go as numbers, LSB first.
@ Fixed literal / length code: 0 .. 143 -> 8 bits 0x30 + v; 144 .. 255 -> 9 bits 0x190 + v - 144; 256 .. 279 -> 7
@ bits v - 256; 280 .. 287 -> 8 bits 0xC0 + v - 280.  Distance codes: 5 bits, the code number.
@
@ Registers inside zdef: r4 source, r5 source length, r6 position, r7 next output byte, r8 end of the output room,
@ r9 bit accumulator, r10 bits in r9 (0 .. 7 between codes), r11 hash table.
@ RAM: zdef_head, 2048 bytes in .bss_port.  No EEPROM, calibration or flash access.  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .equ ZD_HBITS,  10                      @ hash table of 2^10 entries
    .equ ZD_MAXLEN, 258

    .section .bss_port.zdef, "aw", %nobits
    .balign 4
zdef_head:      .space (1 << ZD_HBITS) * 2  @ per hash: last position + 1 (0 = none)
zdef_sp:        .space 4                    @ stack pointer after the entry push (zd_full returns through it)

    .section .rodata.zdef, "a", %progbits
    .balign 2
zdef_lbase:     .hword 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31     @ length codes 257 .. 285 (RFC 1951
                .hword 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258   @ 3.2.5): base length
zdef_dbase:     .hword 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193  @ distance codes 0 .. 29: base
                .hword 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145
                .hword 8193, 12289, 16385, 24577
zdef_lext:      .byte 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2               @ extra bits of the length codes
                .byte 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
zdef_dext:      .byte 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6               @ extra bits of the distance codes
                .byte 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13

    .section .text.sys.zdef, "ax", %progbits

@ -----------------------------------------------------------------------------
@ zdef - pack r1 bytes at r0 into r2 (room r3 bytes)
@ Out      : r0 = packed length, 0 when the room was too small
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ -----------------------------------------------------------------------------
FUNC zdef
    push {r4-r11, lr}
    ldr r12, =zdef_sp
    str sp, [r12]
    mov r4, r0
    mov r5, r1
    mov r7, r2
    add r8, r2, r3
    ldr r11, =zdef_head
    movs r0, #0                             @ table cleared
    mov r1, #(1 << ZD_HBITS)
1:  subs r1, r1, #1
    strh r0, [r11, r1, lsl #1]
    bne 1b
    mov r9, #0
    mov r10, #0
    movs r6, #0
    mov r12, r2                             @ start of the output (for the length)
    push {r12}
    movs r0, #3                             @ BFINAL 1, BTYPE 01 (as a number: 1 then 1 -> bits 1, 1, 0)
    movs r1, #3
    bl zd_bits
.Lzd_loop:
    cmp r6, r5
    bhs .Lzd_end
    add r0, r6, #3
    cmp r0, r5
    bhi .Lzd_lit                            @ fewer than 3 bytes left: literals
    mov r0, r6
    bl zd_hash                              @ r0 = hash, r1 = table entry address
    ldrh r2, [r1]                           @ candidate + 1
    add r3, r6, #1
    strh r3, [r1]
    cmp r2, #0
    beq .Lzd_lit
    subs r2, r2, #1                         @ r2 = candidate position (< r6)
    sub r3, r5, r6                          @ longest possible: min(258, bytes left)
    movw r12, #ZD_MAXLEN
    cmp r3, r12
    it hi
    movhi r3, r12
    add r0, r4, r2                          @ r0 = candidate bytes, r1 = current bytes
    add r1, r4, r6
    movs r12, #0
2:  cmp r12, r3
    bhs 3f
    ldrb r2, [r0, r12]
    ldrb lr, [r1, r12]
    cmp r2, lr
    bne 3f
    add r12, r12, #1
    b 2b
3:  cmp r12, #3
    blo .Lzd_lit
    sub r0, r1, r0                          @ distance
    mov r1, r12                             @ length
    push {r1}
    bl zd_match
    pop {r1}
    add r3, r6, r1                          @ the positions inside the match into the table
    adds r6, r6, #1
4:  cmp r6, r3
    bhs .Lzd_loop
    add r0, r6, #3
    cmp r0, r5
    bhi 5f
    mov r0, r6
    bl zd_hash
    add r2, r6, #1
    strh r2, [r1]
5:  adds r6, r6, #1
    b 4b
.Lzd_lit:
    ldrb r0, [r4, r6]
    bl zd_lit
    adds r6, r6, #1
    b .Lzd_loop
.Lzd_end:
    movs r0, #0                             @ end of block: code 256 = 7 zero bits
    movs r1, #7
    bl zd_bits
    cmp r10, #0                             @ the last bits padded to a byte
    beq 6f
    movs r0, #0
    rsb r1, r10, #8
    bl zd_bits
6:  pop {r12}
    sub r0, r7, r12
    pop {r4-r11, pc}
ENDFUNC zdef

@ zd_full - the output room is used up: zdef returns 0 (from any depth; the stack is unwound to the entry frame)
LFUNC zd_full
    ldr r0, =zdef_sp
    ldr r0, [r0]
    mov sp, r0
    movs r0, #0
    pop {r4-r11, pc}
ENDFUNC zd_full

@ -----------------------------------------------------------------------------
@ zd_hash - hash of the three bytes at r4 + r0
@ Out      : r0 = hash (0 .. 1023), r1 = address of its table entry; Clobbers r2, flags
@ -----------------------------------------------------------------------------
LFUNC zd_hash
    add r1, r4, r0
    ldrb r0, [r1]
    ldrb r2, [r1, #1]
    orr r0, r0, r2, lsl #8
    ldrb r2, [r1, #2]
    orr r0, r0, r2, lsl #16
    ldr r2, =0x9E3779B1                     @ Fibonacci hashing: the top bits of the product
    muls r0, r2, r0
    lsrs r0, r0, #(32 - ZD_HBITS)
    add r1, r11, r0, lsl #1
    bx lr
ENDFUNC zd_hash

@ -----------------------------------------------------------------------------
@ zd_bits - add the r1 low bits of r0 (r1 0 .. 16) to the output, LSB first
@ Clobbers : r0-r2, flags; updates r7, r9, r10
@ -----------------------------------------------------------------------------
LFUNC zd_bits
    lsl r0, r0, r10
    orr r9, r9, r0
    add r10, r10, r1
1:  cmp r10, #8
    blo 2f
    cmp r7, r8
    bhs zd_full
    strb r9, [r7], #1
    lsr r9, r9, #8
    sub r10, r10, #8
    b 1b
2:  bx lr
ENDFUNC zd_bits

@ -----------------------------------------------------------------------------
@ zd_code - add the Huffman code r0 of r1 bits (most significant bit first)
@ Clobbers : r0-r2, flags
@ -----------------------------------------------------------------------------
LFUNC zd_code
    rbit r0, r0
    rsb r2, r1, #32
    lsr r0, r0, r2
    b zd_bits
ENDFUNC zd_code

@ -----------------------------------------------------------------------------
@ zd_lit - the literal r0 (0 .. 255) in the fixed code
@ Clobbers : r0-r2, flags
@ -----------------------------------------------------------------------------
LFUNC zd_lit
    cmp r0, #144
    bhs 1f
    adds r0, r0, #0x30
    movs r1, #8
    b zd_code
1:  add r0, r0, #(0x190 - 144)
    movs r1, #9
    b zd_code
ENDFUNC zd_lit

@ -----------------------------------------------------------------------------
@ zd_match - a match of length r1 (3 .. 258) at distance r0 (1 .. 32768) in the fixed code
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC zd_match
    push {r4, r5, lr}
    mov r4, r0                              @ r4 = distance (r4 / r5 of zdef saved)
    ldr r2, =zdef_lbase                     @ the length code: the last base not above the length
    movs r3, #28
1:  ldrh r12, [r2, r3, lsl #1]
    cmp r12, r1
    bls 2f
    subs r3, r3, #1
    b 1b
2:  sub r5, r1, r12                         @ r5 = extra value
    addw r0, r3, #257                       @ symbol 257 .. 285
    cmp r0, #280
    bhs 3f
    sub r0, r0, #256                        @ 257 .. 279: 7 bits
    movs r1, #7
    b 4f
3:  sub r0, r0, #(280 - 0xC0)               @ 280 .. 285: 8 bits 0xC0 + v - 280
    movs r1, #8
4:  push {r3}
    bl zd_code
    pop {r3}
    ldr r2, =zdef_lext
    ldrb r1, [r2, r3]
    mov r0, r5
    bl zd_bits                              @ length extra bits
    ldr r2, =zdef_dbase                     @ the distance code
    movs r3, #29
5:  ldrh r12, [r2, r3, lsl #1]
    cmp r12, r4
    bls 6f
    subs r3, r3, #1
    b 5b
6:  sub r5, r4, r12
    push {r3}
    mov r0, r3
    movs r1, #5
    bl zd_code
    pop {r3}
    ldr r2, =zdef_dext
    ldrb r1, [r2, r3]
    mov r0, r5
    bl zd_bits                              @ distance extra bits
    pop {r4, r5, pc}
ENDFUNC zd_match
