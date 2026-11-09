@ =============================================================================
@ zdef.s - deflate: pack a buffer into one raw deflate block, dynamic or fixed code, whichever is shorter (RFC 1951;
@ DESIGN.md 10 IMP-63)
@
@ Used by the card request READZ (ble/bftsd.s); the companion unpacks with zlib.  The output is byte for byte that of
@ the reference model emulator/tools/zdyn.py (emulator/scripts/test_packed.py compares them), which is the
@ specification of every step below.  Owner 2026-11-09: "all the way", "max compression level".
@
@ LZ77 (zdyn.parse, zlib's deflate_slow at level 9: lazy and nice length 258): the next three bytes are hashed
@ (Fibonacci, 10 bits) into zdef_head (position + 1, 0 = none); zdef_prev[pos mod 512] chains the positions of one
@ hash.  A match is searched only when pos + 3 <= n; candidates are walked while the distance is at most ZD_MAXD (255:
@ measured on a meter log, shorter distances are cheaper to code than long ones save) and the positions decrease; the
@ longest wins (ties: the nearest); a match is written only when the one at the next position is not longer (lazy).
@ Two passes over the window with the same parse (head cleared before each; prev is read only for positions less
@ than ZD_MAXD back, written in the same pass): pass 1 counts the literal / length and distance symbols and the extra
@ bits, pass 2 writes them, so no token buffer is needed.
@ Code lengths (zd_huff = zdyn.huff_lengths): JPEG ITU-T T.81 K.2 code sizes by merging the two least frequent (ties:
@ the higher symbol), K.3 limited to 15 bits (7 for the code length code), at least two used symbols per code, the
@ lengths handed out in the order of the code sizes (ties: the lower symbol).  The literal / length and distance code
@ lengths are one run-length coded sequence (zd_rle_build: 0 by 17 / 18, other values once and then 16).  The block
@ is dynamic when its exact bit count (zd_costs) is below that of the fixed code, else fixed.
@ Bits go LSB first into the bytes; the codes are stored bit-reversed (zd_canon), so every field is written as a
@ number by zd_bits.  Room: the caller gives n - 1 bytes; zd_full returns 0 when the block does not fit (the caller
@ then sends the bytes themselves).
@
@ RAM: zdef_head 2048, zdef_prev 1024, zd_freq 670, zd_code 670, zd_st 56, zd_len 335 bytes in .bss_port; zd_huff's
@ working arrays and the run-length list in log_buf[8192 .. 9968) (READZ uses log_buf[0 .. 8191] for the bytes read
@ and the output; nothing else uses log_buf while page Ld runs a READZ).  No EEPROM, calibration or flash access.
@ Context: main only (READZ, inside the card session on the 32 MHz clock).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"

    .equ ZD_HBITS,  10                      @ hash of 2^10 entries
    .equ ZD_MAXLEN, 258
    .equ ZD_MAXD,   255                     @ longest distance searched
    .equ ZD_NLIT,   286                     @ literal / length symbols
    .equ ZD_NDIST,  30
    .equ ZD_NCL,    19
    .equ ZF_DIST,   572                     @ zd_freq / zd_code: offset of the distance part (286 u16)
    .equ ZF_CL,     632                     @ offset of the code length code part (286 + 30 u16)
    .equ ZL_DIST,   286                     @ zd_len: offset of the distance part
    .equ ZL_CL,     316
    .equ ZS_OTHERS, 0                       @ scratch: others i16[286]
    .equ ZS_WF,     572                     @ scratch: working frequencies u16[286]
    .equ ZS_RLE,    1144                    @ scratch: run-length list (symbol u8, extra u8) x at most 316
    .equ zd_scratch, v_20001240 + 8192      @ log_buf (log/files.s) + 8192: 1776 of its last 1808 bytes

    .equ ST_SRC,    0                       @ zd_st: source
    .equ ST_N,      4                       @ source length
    .equ ST_OUT,    8                       @ next output byte
    .equ ST_END,    12                      @ end of the output room
    .equ ST_START,  16                      @ first output byte
    .equ ST_ACC,    20                      @ bit accumulator
    .equ ST_CNT,    24                      @ bits in it (0 .. 7 between fields)
    .equ ST_EXTRA,  28                      @ extra bits of the lengths and distances (pass 1)
    .equ ST_HLIT,   32
    .equ ST_HDIST,  36
    .equ ST_HCLEN,  40
    .equ ST_NRLE,   44                      @ entries of the run-length list
    .equ ST_SP,     48                      @ stack pointer after the entry push (zd_full returns through it)
    .equ ST_MODE,   52                      @ 0 pass 1 (count), 1 pass 2 (write)

    .section .bss_port.zdef, "aw", %nobits
    .balign 4
zdef_head:      .space (1 << ZD_HBITS) * 2  @ per hash: last position + 1 (0 = none)
zdef_prev:      .space 512 * 2              @ per position mod 512: the previous position + 1 of its hash
zd_freq:        .space (ZD_NLIT + ZD_NDIST + ZD_NCL) * 2
zd_code:        .space (ZD_NLIT + ZD_NDIST + ZD_NCL) * 2   @ codes, bit-reversed (written LSB first)
zd_st:          .space 56
zd_len:         .space ZD_NLIT + ZD_NDIST + ZD_NCL
    .balign 4

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
zdef_clord:     .byte 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15   @ code length code order

    .section .text.sys.zdef, "ax", %progbits

@ -----------------------------------------------------------------------------
@ zdef - pack r1 bytes (1 .. 4096) at r0 into r2 (room r3 bytes)
@ Out      : r0 = packed length, 0 when the room was too small
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ -----------------------------------------------------------------------------
FUNC zdef
    push {r4-r11, lr}
    ldr r4, =zd_st
    str r0, [r4, #ST_SRC]
    str r1, [r4, #ST_N]
    str r2, [r4, #ST_OUT]
    str r2, [r4, #ST_START]
    add r3, r2, r3
    str r3, [r4, #ST_END]
    mov r0, sp
    str r0, [r4, #ST_SP]
    movs r0, #0
    str r0, [r4, #ST_EXTRA]
    str r0, [r4, #ST_ACC]
    str r0, [r4, #ST_CNT]
    strb r0, [r4, #ST_MODE]
    ldr r1, =zd_freq                        @ every frequency 0
    movw r2, #(ZD_NLIT + ZD_NDIST + ZD_NCL)
1:  subs r2, r2, #1
    strh r0, [r1, r2, lsl #1]
    bne 1b
    @ pass 1: the symbols counted
    bl zd_parse
    ldr r1, =zd_freq
    ldrh r0, [r1, #(256 * 2)]
    adds r0, r0, #1
    strh r0, [r1, #(256 * 2)]               @ the end of block, once
    ldr r0, =zd_freq                        @ code lengths: literal / length, distance
    mov r1, #ZD_NLIT
    ldr r2, =zd_len
    movs r3, #15
    bl zd_huff
    ldr r0, =(zd_freq + ZF_DIST)
    movs r1, #ZD_NDIST
    ldr r2, =(zd_len + ZL_DIST)
    movs r3, #15
    bl zd_huff
    bl zd_trim                              @ HLIT, HDIST
    bl zd_rle_build                         @ the run-length list and its symbol counts
    ldr r0, =(zd_freq + ZF_CL)
    movs r1, #ZD_NCL
    ldr r2, =(zd_len + ZL_CL)
    movs r3, #7
    bl zd_huff                              @ the code length code
    bl zd_hclen
    bl zd_costs                             @ r0 = 1: the dynamic block is shorter
    cmp r0, #0
    beq .Lzd_fixed
    @ dynamic: header, the code length code lengths, the run-length list
    ldr r0, =(zd_len + ZL_CL)
    movs r1, #ZD_NCL
    ldr r2, =(zd_code + ZF_CL)
    bl zd_canon
    movs r0, #5                             @ BFINAL 1, BTYPE 2
    movs r1, #3
    bl zd_bits
    ldr r0, [r4, #ST_HLIT]
    subw r0, r0, #257
    movs r1, #5
    bl zd_bits
    ldr r0, [r4, #ST_HDIST]
    subs r0, r0, #1
    movs r1, #5
    bl zd_bits
    ldr r0, [r4, #ST_HCLEN]
    subs r0, r0, #4
    movs r1, #4
    bl zd_bits
    movs r5, #0                             @ the code length code lengths in their order
2:  ldr r0, [r4, #ST_HCLEN]
    cmp r5, r0
    bhs 3f
    ldr r1, =zdef_clord
    ldrb r1, [r1, r5]
    ldr r0, =(zd_len + ZL_CL)
    ldrb r0, [r0, r1]
    movs r1, #3
    bl zd_bits
    adds r5, r5, #1
    b 2b
3:  ldr r6, =(zd_scratch + ZS_RLE)          @ the run-length list
    ldr r7, [r4, #ST_NRLE]
4:  cmp r7, #0
    beq .Lzd_codes
    ldrb r5, [r6], #1                       @ symbol
    ldrb r8, [r6], #1                       @ extra value
    ldr r0, =(zd_code + ZF_CL)
    ldrh r0, [r0, r5, lsl #1]
    ldr r1, =(zd_len + ZL_CL)
    ldrb r1, [r1, r5]
    bl zd_bits
    cmp r5, #16                             @ 16: 2 extra bits, 17: 3, 18: 7
    blo 5f
    movs r1, #2
    cmp r5, #17
    it eq
    moveq r1, #3
    cmp r5, #18
    it eq
    moveq r1, #7
    mov r0, r8
    bl zd_bits
5:  subs r7, r7, #1
    b 4b
.Lzd_fixed:
    bl zd_fixed_lengths
    movs r0, #3                             @ BFINAL 1, BTYPE 1
    movs r1, #3
    bl zd_bits
.Lzd_codes:
    ldr r0, =zd_len                         @ the codes of the lengths (dynamic or fixed)
    mov r1, #ZD_NLIT
    ldr r2, =zd_code
    bl zd_canon
    ldr r0, =(zd_len + ZL_DIST)
    movs r1, #ZD_NDIST
    ldr r2, =(zd_code + ZF_DIST)
    bl zd_canon
    @ pass 2: the same parse, the symbols written
    movs r0, #1
    strb r0, [r4, #ST_MODE]
    bl zd_parse
    ldr r0, =zd_code                        @ end of block
    ldrh r0, [r0, #(256 * 2)]
    ldr r1, =zd_len
    ldrb r1, [r1, #256]
    bl zd_bits
    ldr r1, [r4, #ST_CNT]                   @ the last bits padded to a byte
    cmp r1, #0
    beq 6f
    rsb r1, r1, #8
    movs r0, #0
    bl zd_bits
6:  ldr r0, [r4, #ST_OUT]
    ldr r1, [r4, #ST_START]
    sub r0, r0, r1
    pop {r4-r11, pc}
ENDFUNC zdef

@ zd_full - the output room is used up: zdef returns 0 (from any depth; the stack is unwound to the entry frame)
LFUNC zd_full
    ldr r0, =zd_st
    ldr r0, [r0, #ST_SP]
    mov sp, r0
    movs r0, #0
    pop {r4-r11, pc}
ENDFUNC zd_full

@ -----------------------------------------------------------------------------
@ zd_bits - add the r1 low bits of r0 (r1 0 .. 16) to the output, LSB first
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC zd_bits
    ldr r3, =zd_st
    ldr r2, [r3, #ST_CNT]
    ldr r12, [r3, #ST_ACC]
    lsl r0, r0, r2
    orr r12, r12, r0
    add r2, r2, r1
1:  cmp r2, #8
    blo 2f
    ldr r0, [r3, #ST_OUT]
    ldr r1, [r3, #ST_END]
    cmp r0, r1
    bhs zd_full
    strb r12, [r0], #1
    str r0, [r3, #ST_OUT]
    lsr r12, r12, #8
    subs r2, r2, #8
    b 1b
2:  str r12, [r3, #ST_ACC]
    str r2, [r3, #ST_CNT]
    bx lr
ENDFUNC zd_bits

@ -----------------------------------------------------------------------------
@ zd_insert - enter position r0 (r0 + 3 <= n) into the hash chains (zdyn.parse insert)
@ In       : r0 = position, r4 = source
@ Out      : r0 = the previous head of its hash (position + 1, 0 = none)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC zd_insert
    add r1, r4, r0
    ldrb r2, [r1]
    ldrb r3, [r1, #1]
    orr r2, r2, r3, lsl #8
    ldrb r3, [r1, #2]
    orr r2, r2, r3, lsl #16
    ldr r3, =0x9E3779B1                     @ Fibonacci hashing: the top 10 bits of the product
    muls r2, r3, r2
    lsrs r2, r2, #(32 - ZD_HBITS)
    ldr r3, =zdef_head
    add r3, r3, r2, lsl #1
    ldrh r1, [r3]                           @ old head
    add r12, r0, #1
    strh r12, [r3]                          @ head = position + 1
    ldr r3, =zdef_prev
    ubfx r2, r0, #0, #9
    strh r1, [r3, r2, lsl #1]               @ prev[position mod 512] = old head
    mov r0, r1
    bx lr
ENDFUNC zd_insert

@ -----------------------------------------------------------------------------
@ zd_longest - the longest match for position r6 among the chain from candidate r0 (zdyn.parse longest)
@ In       : r0 = candidate position (< r6), r4 source, r5 n, r6 position, r7 the length to beat (prev_len)
@ Out      : r0 = length (2 when none longer), r1 = distance (0 when none)
@ Clobbers : r2, r3, r12, flags (r4-r11 kept)
@ -----------------------------------------------------------------------------
LFUNC zd_longest
    push {r7-r11, lr}
    mov r2, r7                              @ best
    movs r3, #0                             @ its distance
    sub r12, r5, r6                         @ limit = min(258, n - position)
    cmp r12, #ZD_MAXLEN
    it hi
    movhi r12, #ZD_MAXLEN
    add r9, r4, r6                          @ the bytes at the position
1:  sub r1, r6, r0                          @ distance of this candidate
    cmp r1, #ZD_MAXD
    bhi 8f
    cmp r2, r12
    bhs 5f                                  @ nothing longer possible: the next candidate (as the model)
    add r8, r4, r0
    ldrb r10, [r8, r2]                      @ quick test: the byte after the best length
    ldrb r11, [r9, r2]
    cmp r10, r11
    bne 5f
    movs r7, #0                             @ k
3:  cmp r7, r12
    bhs 4f
    ldrb r10, [r8, r7]
    ldrb r11, [r9, r7]
    cmp r10, r11
    bne 4f
    adds r7, r7, #1
    b 3b
4:  cmp r7, r2
    bls 5f
    mov r2, r7
    mov r3, r1
    cmp r7, r12
    bhs 8f                                  @ as long as possible (the limit is at most the nice length 258)
5:  ldr r10, =zdef_prev
    ubfx r11, r0, #0, #9
    ldrh r10, [r10, r11, lsl #1]
    cmp r10, #0
    beq 8f
    subs r10, r10, #1
    cmp r10, r0
    bhs 8f                                  @ not an older position: the chain ends
    mov r0, r10
    b 1b
8:  cmp r3, #0
    ite eq
    moveq r0, #2
    movne r0, r2
    mov r1, r3
    pop {r7-r11, pc}
ENDFUNC zd_longest

@ -----------------------------------------------------------------------------
@ zd_parse - one pass of the LZ77 parse over zd_st's source (zdyn.parse); every token to zd_tok_lit / zd_tok_match
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ Registers: r4 source, r5 n, r6 position, r7 prev_len, r8 prev distance, r9 a literal is pending, r10 / r11 the
@            match at the position (length, distance)
@ -----------------------------------------------------------------------------
LFUNC zd_parse
    push {r4-r11, lr}
    ldr r0, =zd_st
    ldr r4, [r0, #ST_SRC]
    ldr r5, [r0, #ST_N]
    ldr r0, =zdef_head                      @ head cleared (prev needs no clearing: see the file header)
    movs r1, #0
    mov r2, #(1 << ZD_HBITS)
1:  subs r2, r2, #1
    strh r1, [r0, r2, lsl #1]
    bne 1b
    movs r7, #2
    mov r8, #0
    mov r9, #0
    movs r6, #0
.Lzp_loop:
    cmp r6, r5
    bhs .Lzp_end
    mov r10, #2
    mov r11, #0
    adds r0, r6, #3
    cmp r0, r5
    bhi 2f                                  @ fewer than 3 bytes left: no match
    mov r0, r6
    bl zd_insert                            @ r0 = candidate + 1 (0 = none)
    cmp r0, #0
    beq 2f
    cmp r7, #ZD_MAXLEN
    bhs 2f                                  @ the pending match is as long as possible (lazy 258)
    subs r0, r0, #1
    sub r1, r6, r0
    cmp r1, #ZD_MAXD
    bhi 2f
    bl zd_longest
    mov r10, r0
    mov r11, r1
2:  cmp r7, #3
    blo 4f
    cmp r10, r7
    bhi 4f
    mov r0, r7                              @ the pending match is written
    mov r1, r8
    bl zd_tok_match
    adds r10, r6, #1                        @ the positions inside it into the chains: p + 1 .. p + prev_len - 2
    add r11, r6, r7
    subs r11, r11, #1                       @ r11 = the position after the match
3:  cmp r10, r11
    bhs 31f
    adds r0, r10, #3
    cmp r0, r5
    bhi 30f
    mov r0, r10
    bl zd_insert
30: adds r10, r10, #1
    b 3b
31: mov r6, r11
    mov r9, #0
    movs r7, #2
    b .Lzp_loop
4:  cmp r9, #0
    beq 5f
    sub r0, r6, #1
    ldrb r0, [r4, r0]                       @ the pending literal
    bl zd_tok_lit
5:  mov r9, #1
    mov r7, r10
    mov r8, r11
    adds r6, r6, #1
    b .Lzp_loop
.Lzp_end:
    cmp r9, #0
    beq 6f
    sub r0, r5, #1
    ldrb r0, [r4, r0]
    bl zd_tok_lit
6:  pop {r4-r11, pc}
ENDFUNC zd_parse

@ -----------------------------------------------------------------------------
@ zd_tok_lit - the literal r0: counted (pass 1) or written (pass 2)
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC zd_tok_lit
    push {r4, lr}
    ldr r1, =zd_st
    ldrb r2, [r1, #ST_MODE]
    cmp r2, #0
    bne 1f
    ldr r1, =zd_freq
    ldrh r2, [r1, r0, lsl #1]
    adds r2, r2, #1
    strh r2, [r1, r0, lsl #1]
    pop {r4, pc}
1:  ldr r1, =zd_code
    ldrh r3, [r1, r0, lsl #1]
    ldr r1, =zd_len
    ldrb r1, [r1, r0]
    mov r0, r3
    bl zd_bits
    pop {r4, pc}
ENDFUNC zd_tok_lit

@ -----------------------------------------------------------------------------
@ zd_tok_match - the match of length r0 (3 .. 258) at distance r1 (1 .. 255): counted or written
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
LFUNC zd_tok_match
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    ldr r2, =zdef_lbase                     @ r6 = length code: the last base not above the length
    movs r6, #28
1:  ldrh r3, [r2, r6, lsl #1]
    cmp r3, r4
    bls 2f
    subs r6, r6, #1
    b 1b
2:  ldr r2, =zdef_dbase                     @ r7 = distance code
    movs r7, #29
3:  ldrh r3, [r2, r7, lsl #1]
    cmp r3, r5
    bls 4f
    subs r7, r7, #1
    b 3b
4:  ldr r1, =zd_st
    ldrb r2, [r1, #ST_MODE]
    cmp r2, #0
    bne 5f
    ldr r1, =zd_freq                        @ pass 1: counts and extra bits
    addw r2, r6, #257
    ldrh r3, [r1, r2, lsl #1]
    adds r3, r3, #1
    strh r3, [r1, r2, lsl #1]
    addw r2, r1, #ZF_DIST
    ldrh r3, [r2, r7, lsl #1]
    adds r3, r3, #1
    strh r3, [r2, r7, lsl #1]
    ldr r2, =zdef_lext
    ldrb r3, [r2, r6]
    ldr r2, =zdef_dext
    ldrb r2, [r2, r7]
    add r3, r3, r2
    ldr r1, =zd_st
    ldr r2, [r1, #ST_EXTRA]
    add r2, r2, r3
    str r2, [r1, #ST_EXTRA]
    pop {r4-r7, pc}
5:  addw r2, r6, #257                       @ pass 2: length code, extra, distance code, extra
    ldr r1, =zd_code
    ldrh r0, [r1, r2, lsl #1]
    ldr r1, =zd_len
    ldrb r1, [r1, r2]
    bl zd_bits
    ldr r2, =zdef_lbase
    ldrh r0, [r2, r6, lsl #1]
    sub r0, r4, r0
    ldr r2, =zdef_lext
    ldrb r1, [r2, r6]
    bl zd_bits
    ldr r1, =(zd_code + ZF_DIST)
    ldrh r0, [r1, r7, lsl #1]
    ldr r1, =(zd_len + ZL_DIST)
    ldrb r1, [r1, r7]
    bl zd_bits
    ldr r2, =zdef_dbase
    ldrh r0, [r2, r7, lsl #1]
    sub r0, r5, r0
    ldr r2, =zdef_dext
    ldrb r1, [r2, r7]
    bl zd_bits
    pop {r4-r7, pc}
ENDFUNC zd_tok_match

@ -----------------------------------------------------------------------------
@ zd_huff - code lengths (zdyn.huff_lengths) of r1 symbols with the frequencies r0 (u16) into r2 (u8), at most r3 bits
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ Registers: r4 frequencies, r5 n, r6 lengths (first the code sizes), r7 the limit, r8 others (i16, -1 = none), r9
@            working frequencies
@ Note     : a code size is at most 18 (the merging gives depth d only with a total frequency of at least the
@            Fibonacci number F(d + 2); the totals are at most 4098), so the counts bits[0 .. 32] on the stack hold
@            every size.
@ -----------------------------------------------------------------------------
LFUNC zd_huff
    push {r4-r11, lr}
    sub sp, sp, #68                         @ bits[0 .. 32], u16
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
    ldr r8, =(zd_scratch + ZS_OTHERS)
    ldr r9, =(zd_scratch + ZS_WF)
    mov r10, #0                             @ used symbols
    movs r0, #0
1:  cmp r0, r5                              @ copy, sizes 0, others -1
    bhs 2f
    ldrh r1, [r4, r0, lsl #1]
    strh r1, [r9, r0, lsl #1]
    cmp r1, #0
    it ne
    addne r10, r10, #1
    movs r2, #0
    strb r2, [r6, r0]
    movw r2, #0xFFFF
    strh r2, [r8, r0, lsl #1]
    adds r0, r0, #1
    b 1b
2:  movs r0, #0                             @ at least two used symbols: the lowest unused ones get 1
3:  cmp r10, #2
    bhs 5f
    cmp r0, r5
    bhs 5f
    ldrh r1, [r9, r0, lsl #1]
    cmp r1, #0
    bne 4f
    movs r1, #1
    strh r1, [r9, r0, lsl #1]
    add r10, r10, #1
4:  adds r0, r0, #1
    b 3b
5:  @ K.2: merge the two least frequent (ties: the higher symbol) until one is left
    mvn r11, #0                             @ v1
    movs r0, #0
6:  cmp r0, r5
    bhs 8f
    ldrh r1, [r9, r0, lsl #1]
    cmp r1, #0
    beq 7f
    cmp r11, #0
    blt 61f
    ldrh r2, [r9, r11, lsl #1]
    cmp r1, r2
    bhi 7f
61: mov r11, r0
7:  adds r0, r0, #1
    b 6b
8:  mvn r10, #0                             @ v2: as v1, not v1
    movs r0, #0
9:  cmp r0, r5
    bhs 11f
    cmp r0, r11
    beq 10f
    ldrh r1, [r9, r0, lsl #1]
    cmp r1, #0
    beq 10f
    cmp r10, #0
    blt 91f
    ldrh r2, [r9, r10, lsl #1]
    cmp r1, r2
    bhi 10f
91: mov r10, r0
10: adds r0, r0, #1
    b 9b
11: cmp r10, #0
    blt .Lzh_sizes                          @ one left: the code sizes are done
    ldrh r1, [r9, r11, lsl #1]              @ freq[v1] += freq[v2], freq[v2] = 0
    ldrh r2, [r9, r10, lsl #1]
    add r1, r1, r2
    strh r1, [r9, r11, lsl #1]
    movs r2, #0
    strh r2, [r9, r10, lsl #1]
12: ldrb r1, [r6, r11]                      @ size[v1]++ along its chain
    adds r1, r1, #1
    strb r1, [r6, r11]
    ldrsh r1, [r8, r11, lsl #1]
    cmp r1, #0
    blt 13f
    mov r11, r1
    b 12b
13: strh r10, [r8, r11, lsl #1]             @ others[v1] = v2
14: ldrb r1, [r6, r10]                      @ size[v2]++ along its chain
    adds r1, r1, #1
    strb r1, [r6, r10]
    ldrsh r1, [r8, r10, lsl #1]
    cmp r1, #0
    blt 5b
    mov r10, r1
    b 14b
.Lzh_sizes:
    movs r0, #0                             @ bits[] = 0
    movs r1, #0
15: strh r1, [sp, r0]
    adds r0, r0, #2
    cmp r0, #66
    bne 15b
    movs r0, #0                             @ bits[size]++
16: cmp r0, r5
    bhs 17f
    ldrb r1, [r6, r0]
    cmp r1, #0
    beq 161f
    lsls r1, r1, #1
    ldrh r2, [sp, r1]
    adds r2, r2, #1
    strh r2, [sp, r1]
161: adds r0, r0, #1
    b 16b
17: movs r0, #32                            @ K.3: no code longer than the limit; r0 = i
18: cmp r0, r7
    bls .Lzh_assign
    lsls r1, r0, #1
    ldrh r2, [sp, r1]
    cmp r2, #0
    bne 19f
    subs r0, r0, #1
    b 18b
19: sub r3, r0, #2                          @ j = i - 2, down to a used size
20: lsls r1, r3, #1
    ldrh r2, [sp, r1]
    cmp r2, #0
    bne 21f
    subs r3, r3, #1
    b 20b
21: lsls r1, r0, #1                         @ bits[i] -= 2
    ldrh r2, [sp, r1]
    subs r2, r2, #2
    strh r2, [sp, r1]
    subs r1, r1, #2                         @ bits[i - 1] += 1
    ldrh r2, [sp, r1]
    adds r2, r2, #1
    strh r2, [sp, r1]
    lsls r1, r3, #1                         @ bits[j + 1] += 2
    adds r1, r1, #2
    ldrh r2, [sp, r1]
    adds r2, r2, #2
    strh r2, [sp, r1]
    subs r1, r1, #2                         @ bits[j] -= 1
    ldrh r2, [sp, r1]
    subs r2, r2, #1
    strh r2, [sp, r1]
    b 18b
.Lzh_assign:
    @ the lengths 1 .. limit (bits[]) handed out in the order of the code sizes (ties: the lower symbol); an assigned
    @ symbol holds 0x80 | length until the end
    mov r10, #1                             @ the next length to give
    mov r11, #1                             @ size s
22: cmp r11, #32
    bhi 26f
    movs r0, #0
23: cmp r0, r5
    bhs 25f
    ldrb r1, [r6, r0]
    cmp r1, r11
    bne 24f
231: lsls r1, r10, #1                       @ the next length with a code left
    ldrh r2, [sp, r1]
    cmp r2, #0
    bne 232f
    add r10, r10, #1
    b 231b
232: subs r2, r2, #1
    strh r2, [sp, r1]
    orr r1, r10, #0x80
    strb r1, [r6, r0]
24: adds r0, r0, #1
    b 23b
25: add r11, r11, #1
    b 22b
26: movs r0, #0                             @ the marks off
27: cmp r0, r5
    bhs 28f
    ldrb r1, [r6, r0]
    and r1, r1, #0x7F
    strb r1, [r6, r0]
    adds r0, r0, #1
    b 27b
28: add sp, sp, #68
    pop {r4-r11, pc}
ENDFUNC zd_huff

@ -----------------------------------------------------------------------------
@ zd_trim - HLIT (257 .. 286) and HDIST (1 .. 30): the codes up to the last used one
@ Clobbers : r0-r3, flags
@ Note     : symbol 256 (end of block) always has a length, so the literal / length scan stops at 256 or above and
@            HLIT is 257 or more without a clamp
@ -----------------------------------------------------------------------------
LFUNC zd_trim
    ldr r1, =zd_len
    mov r0, #ZD_NLIT
1:  subs r0, r0, #1
    ldrb r2, [r1, r0]
    cmp r2, #0
    beq 1b
    adds r0, r0, #1
    ldr r3, =zd_st
    str r0, [r3, #ST_HLIT]
    ldr r1, =(zd_len + ZL_DIST)
    movs r0, #ZD_NDIST
2:  subs r0, r0, #1
    blt 3f
    ldrb r2, [r1, r0]
    cmp r2, #0
    beq 2b
3:  adds r0, r0, #1
    cmp r0, #1
    it lo
    movlo r0, #1
    str r0, [r3, #ST_HDIST]
    bx lr
ENDFUNC zd_trim

@ -----------------------------------------------------------------------------
@ zd_rle_build - the code lengths ll[0 .. HLIT) dl[0 .. HDIST) as one run-length list (zdyn.rle) at zd_scratch +
@                ZS_RLE (symbol, extra), and the symbol counts of the code length code
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ Registers: r4 index i, r5 total, r6 output, r7 value v, r8 run r, r9 HLIT
@ -----------------------------------------------------------------------------
LFUNC zd_rle_build
    push {r4-r11, lr}
    ldr r0, =zd_st
    ldr r9, [r0, #ST_HLIT]
    ldr r5, [r0, #ST_HDIST]
    add r5, r5, r9
    ldr r6, =(zd_scratch + ZS_RLE)
    movs r4, #0
1:  cmp r4, r5
    bhs .Lzr_count
    mov r0, r4
    bl zd_seq                               @ r0 = sequence[i]
    mov r7, r0
    mov r8, #1                              @ the run of v from i
2:  add r0, r4, r8
    cmp r0, r5
    bhs 3f
    bl zd_seq
    cmp r0, r7
    bne 3f
    add r8, r8, #1
    b 2b
3:  add r4, r4, r8
    cmp r7, #0
    bne 8f
4:  cmp r8, #11                             @ zeros: 18 for 11 .. 138, 17 for 3 .. 10, single 0 below 3
    blo 5f
    cmp r8, #138
    ite hi
    movhi r0, #138
    movls r0, r8
    sub r8, r8, r0
    movs r1, #18
    strb r1, [r6], #1
    subs r0, r0, #11
    strb r0, [r6], #1
    b 4b
5:  cmp r8, #3
    blo 6f
    movs r1, #17
    strb r1, [r6], #1
    sub r0, r8, #3
    strb r0, [r6], #1
    mov r8, #0
6:  cmp r8, #0                              @ the rest as single values
    beq 1b
    strb r7, [r6], #1
    movs r0, #0
    strb r0, [r6], #1
    sub r8, r8, #1
    b 6b
8:  strb r7, [r6], #1                       @ another value: once, then 16 for 3 .. 6 more
    movs r0, #0
    strb r0, [r6], #1
    sub r8, r8, #1
9:  cmp r8, #3
    blo 6b
    cmp r8, #6
    ite hi
    movhi r0, #6
    movls r0, r8
    sub r8, r8, r0
    movs r1, #16
    strb r1, [r6], #1
    subs r0, r0, #3
    strb r0, [r6], #1
    b 9b
.Lzr_count:
    ldr r0, =(zd_scratch + ZS_RLE)
    sub r1, r6, r0
    lsrs r1, r1, #1
    ldr r2, =zd_st
    str r1, [r2, #ST_NRLE]
    ldr r2, =(zd_freq + ZF_CL)              @ code length code counts
    movs r3, #0
    movs r4, #0
10: strh r3, [r2, r4, lsl #1]
    adds r4, r4, #1
    cmp r4, #ZD_NCL
    bne 10b
11: cmp r1, #0
    beq 12f
    ldrb r3, [r0], #2
    ldrh r4, [r2, r3, lsl #1]
    adds r4, r4, #1
    strh r4, [r2, r3, lsl #1]
    subs r1, r1, #1
    b 11b
12: pop {r4-r11, pc}
ENDFUNC zd_rle_build

@ zd_seq - element r0 of the code length sequence: zd_len[r0] below HLIT (r9), else the distance length r0 - HLIT
@ Clobbers : r0, r1, flags
LFUNC zd_seq
    cmp r0, r9
    bhs 1f
    ldr r1, =zd_len
    ldrb r0, [r1, r0]
    bx lr
1:  sub r0, r0, r9
    ldr r1, =(zd_len + ZL_DIST)
    ldrb r0, [r1, r0]
    bx lr
ENDFUNC zd_seq

@ -----------------------------------------------------------------------------
@ zd_hclen - HCLEN (4 .. 19): the code length code lengths up to the last used one in their order
@ Clobbers : r0-r3, flags
@ -----------------------------------------------------------------------------
LFUNC zd_hclen
    movs r0, #ZD_NCL
    ldr r2, =zdef_clord
    ldr r3, =(zd_len + ZL_CL)
1:  subs r0, r0, #1
    ldrb r1, [r2, r0]
    ldrb r1, [r3, r1]
    cmp r1, #0
    beq 1b                                  @ some code length code symbol is used (the list is not empty)
    adds r0, r0, #1
    cmp r0, #4
    it lo
    movlo r0, #4
    ldr r1, =zd_st
    str r0, [r1, #ST_HCLEN]
    bx lr
ENDFUNC zd_hclen

@ -----------------------------------------------------------------------------
@ zd_costs - the exact bits of the dynamic and of the fixed block (zdyn.compress)
@ Out      : r0 = 1 when the dynamic block is shorter, else 0
@ Clobbers : r0-r3, r12, flags (r4-r8 saved)
@ -----------------------------------------------------------------------------
LFUNC zd_costs
    push {r4-r8, lr}
    ldr r4, =zd_st
    ldr r5, [r4, #ST_EXTRA]                 @ r5 = dynamic, r6 = fixed: both carry the extra bits
    mov r6, r5
    ldr r0, [r4, #ST_HCLEN]
    add r0, r0, r0, lsl #1
    add r5, r5, r0
    adds r5, r5, #17                        @ 3 + 5 + 5 + 4 + 3 HCLEN
    adds r6, r6, #3
    ldr r0, =(zd_scratch + ZS_RLE)          @ the run-length list
    ldr r1, [r4, #ST_NRLE]
    ldr r2, =(zd_len + ZL_CL)
1:  cmp r1, #0
    beq 2f
    ldrb r3, [r0], #2
    ldrb r12, [r2, r3]
    add r5, r5, r12
    cmp r3, #16
    it eq
    addeq r5, r5, #2
    cmp r3, #17
    it eq
    addeq r5, r5, #3
    cmp r3, #18
    it eq
    addeq r5, r5, #7
    subs r1, r1, #1
    b 1b
2:  ldr r0, =zd_freq                        @ literal / length symbols: frequency x length, dynamic and fixed
    ldr r1, =zd_len
    movs r2, #0
3:  ldrh r3, [r0, r2, lsl #1]
    ldrb r12, [r1, r2]
    mla r5, r3, r12, r5
    mov r12, #8                             @ fixed: 8 (0 .. 143), 9 (144 .. 255), 7 (256 .. 279), 8 (280 ..)
    cmp r2, #144
    blo 4f
    mov r12, #9
    cmp r2, #256
    blo 4f
    mov r12, #7
    cmp r2, #280
    blo 4f
    mov r12, #8
4:  mla r6, r3, r12, r6
    adds r2, r2, #1
    cmp r2, #ZD_NLIT
    bne 3b
    addw r0, r0, #ZF_DIST                   @ distance symbols: dynamic lengths, fixed 5
    addw r1, r1, #ZL_DIST
    movs r2, #0
5:  ldrh r3, [r0, r2, lsl #1]
    ldrb r12, [r1, r2]
    mla r5, r3, r12, r5
    add r3, r3, r3, lsl #2
    add r6, r6, r3
    adds r2, r2, #1
    cmp r2, #ZD_NDIST
    bne 5b
    cmp r5, r6
    ite lo
    movlo r0, #1
    movhs r0, #0
    pop {r4-r8, pc}
ENDFUNC zd_costs

@ -----------------------------------------------------------------------------
@ zd_fixed_lengths - the fixed code (RFC 1951 3.2.6) in zd_len: literal / length 8, 9, 7, 8; distances 5
@ Clobbers : r0-r2, flags
@ -----------------------------------------------------------------------------
LFUNC zd_fixed_lengths
    ldr r0, =zd_len
    movs r1, #0
1:  movs r2, #8
    cmp r1, #144
    blo 2f
    movs r2, #9
    cmp r1, #256
    blo 2f
    movs r2, #7
    cmp r1, #280
    blo 2f
    movs r2, #8
2:  strb r2, [r0, r1]
    adds r1, r1, #1
    cmp r1, #ZD_NLIT
    bne 1b
    addw r0, r0, #ZL_DIST
    movs r1, #0
    movs r2, #5
3:  strb r2, [r0, r1]
    adds r1, r1, #1
    cmp r1, #ZD_NDIST
    bne 3b
    bx lr
ENDFUNC zd_fixed_lengths

@ -----------------------------------------------------------------------------
@ zd_canon - the canonical codes (RFC 1951 3.2.2) of r1 lengths at r0 into r2 (u16), bit-reversed for LSB-first writing
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
LFUNC zd_canon
    push {r4-r7, lr}
    sub sp, sp, #64                         @ [sp] count[16], [sp, #32] next[16] (u16)
    mov r4, r0
    mov r5, r1
    mov r6, r2
    movs r0, #0
    movs r1, #0
1:  strh r1, [sp, r0]
    adds r0, r0, #2
    cmp r0, #32
    bne 1b
    movs r0, #0                             @ count[length]++
2:  cmp r0, r5
    bhs 3f
    ldrb r1, [r4, r0]
    lsls r1, r1, #1
    ldrh r2, [sp, r1]
    adds r2, r2, #1
    strh r2, [sp, r1]
    adds r0, r0, #1
    b 2b
3:  movs r0, #0
    strh r0, [sp]                           @ count[0] = 0
    movs r1, #0                             @ code
    movs r2, #1                             @ bits
4:  sub r3, r2, #1
    lsls r3, r3, #1
    ldrh r3, [sp, r3]
    add r1, r1, r3
    lsls r1, r1, #1                         @ code = (code + count[bits - 1]) << 1
    lsls r3, r2, #1
    adds r3, r3, #32
    strh r1, [sp, r3]                       @ next[bits]
    adds r2, r2, #1
    cmp r2, #16
    bne 4b
    movs r0, #0                             @ every symbol: next[length]++, the code bit-reversed
5:  cmp r0, r5
    bhs 7f
    ldrb r1, [r4, r0]
    movs r7, #0
    cmp r1, #0
    beq 6f
    lsls r2, r1, #1
    adds r2, r2, #32
    ldrh r3, [sp, r2]
    add r12, r3, #1
    strh r12, [sp, r2]
    rbit r3, r3
    rsb r2, r1, #32
    lsr r7, r3, r2
6:  strh r7, [r6, r0, lsl #1]
    adds r0, r0, #1
    b 5b
7:  add sp, sp, #64
    pop {r4-r7, pc}
ENDFUNC zd_canon
