@ =============================================================================
@ link2.s - BLE: link 2 for the old BLE112 module (production image only, DESIGN.md 10 IMP-62; GitHub issue 30)
@
@ BLE module, part 10.  Only while the companion asks (key code 0xA8).  Everything the meter sends goes in 20-byte
@ blocks, at a steady pace, each block protected by three Reed-Solomon parity bytes; other apps never ask and keep the
@ v2.05 status frames F2.
@
@ Why (owner 2026-11-09, research and two reviews): the BLE112's own firmware forwards the UART bytes as ATT indications
@ of at most 20 bytes, one at a time, each waiting for its confirmation (Ghidra of the module); about one byte in 700
@ arrives damaged (read 1..3 bit times late); a 19-byte status frame per reading repeats data that never or rarely
@ changes.  Each kind of data now goes at the rate it changes:
@   STATE block (type 3): the settings of the reading (function, range, flags, sub page, bar scale, status bytes), the
@       serial / date, the reading period, the battery; sent when it changes (a new version number) and every 2 s.
@   READ block (type 1): the readings of one settings version.  It starts with a full reading and its sub display, so
@       it decodes on its own (a lost block costs its readings, never a later one: no chain across blocks); the
@       following readings are differences.
@   TEXT block (type 2): the plain bytes of every answer (key echoes, version, diagnosis, clock), first in line.
@ The companion finds the blocks in the byte stream by their parity (the module's indication boundaries are not
@ the blocks'), corrects one damaged byte per block and shows a reading only when its version equals the last STATE.
@
@ Block: H, payload[16], P2, P1, P0.  H = type (bits 7..6: 1 READ, 2 TEXT, 3 STATE) | seq (bits 5..0, +1 per block).
@ Parity: GF(256) polynomial 0x11D, alpha 2, generator (x - 1)(x - 2)(x - 4) = x^3 + 7x^2 + 14x + 8 over H and the
@ payload (17 bytes, the first one the highest power), distance 4.
@ STATE payload: ver, frame bytes [5]&0x3F, [6]&0x3F, [9], [13]&0xFB, [15], [16], [17], [1], [2], [3], [4], the reading
@   period in 10 ms ticks, the battery (u16 0x20007FBA, big-endian), readings dropped (u8, wrapping).
@ READ payload: ver, age (10 ms ticks from the newest reading of the block to the block; 255 = 255 or more), the sub
@   bytes [10] [11] [12] of the first reading, then records:
@     0x00               end (the rest is 0)
@     0x80 | d           1 byte: next reading, value + d (d -32..31), bar, overload and sub unchanged
@     0xC0 + bar, x      2 bytes: next reading with this bar (0..25); x bit 7 = bar sign, bits 6..0 = d (-64..63)
@     0xE0 | o, v2 v1 v0 4 bytes: next reading absolute (o = overload), bar unchanged
@     0xE2 | o, v2 v1 v0, b   5 bytes: next reading absolute with the bar b (bits 4..0 bar, bit 5 bar sign)
@     0xF0, s10 s11 s12  4 bytes: the sub bytes from the next reading on
@     0xF4, n            2 bytes: n reading periods without a reading before the next one (timestamps)
@   The first record is always 0xE2|o.  v: sign-magnitude, bit 23 = negative (frame [6] bit 6), bits 17..0 = the
@   absolute value (frame [5] bits 7..6, [7], [8]); differences use the signed value and are never taken from or to a
@   negative zero.
@
@ Pace: one block at most every l2_pace TIM2 ticks (default 20 = 5 blocks a second, about 100 bytes a second: the
@ worst link seen carried 7.5 indications a second x 20 bytes); key codes 0xAA..0xB2 choose 30, 25, 20, 17, 14, 12, 10,
@ 8 or 7 ticks (the companion lowers it on loss, raises it slowly).
@ On / off: 0xA8 asks for it (and arms the link watch, IMP-56, so a vanished companion frees the meter); it starts when
@ the echo and any frame in flight are out.  0xFD (the companion's goodbye), ble_link_reset (Bluetooth off / on,
@ wake) end it; page Ld suspends it (the card transfer keeps its own packets) and it starts again after the page.
@
@ Context: l2_tick in the TIM2 interrupt; l2_frame (from the status frame builder) and l2_step in main; ble_tx_pump
@ (USART2 interrupt) sends a built block (l2_blk while l2_blk_ready) and nothing else while link 2 is on.
@ No EEPROM, calibration or option access.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ L2_BLK,        20              @ block length
    .equ L2_PAYEND,     17              @ blk index after the payload (payload = blk[1..16])
    .equ L2_T_READ,     0x40
    .equ L2_T_TEXT,     0x80
    .equ L2_T_STATE,    0xC0
    .equ L2_ENT,        12              @ bytes per queued reading: ver, v2 v1 v0, ob, s10 s11 s12, gap, tick lo, tick hi, -
    .equ L2_NENT,       16              @ queued readings (power of two)
    .equ L2_STATE_EVERY, 200            @ ticks between STATE blocks when nothing changed (2 s)
    .equ L2_PACE_DEF,   20              @ ticks between blocks at the start (5 a second)
    .equ ble_battery,   v_20007FBA      @ u16 battery value (ble/packet.s sub code 1)

    .section .bss_port.ble.l2, "aw", %nobits
    .global l2_on
l2_on:          .space 1                @ 1 = blocks instead of status frames (read by ble_tx_pump / ble_tx_kick)
l2_want:        .space 1                @ 1 = the companion asked (kept through page Ld)
l2_req:         .space 1                @ 1 = start when the link is idle
    .global l2_blk_ready
l2_blk_ready:   .space 1                @ 1 = l2_blk built, not yet sent completely (cleared by ble_tx_pump)
l2_seq:         .space 1
l2_pace:        .space 1
l2_state_due:   .space 1
l2_ver:         .space 1
l2_dropped:     .space 1
    .global l2_eh, l2_et                @ (global for the emulator test test_link2.py)
l2_eh:          .space 1                @ reading queue head (main)
l2_et:          .space 1                @ reading queue tail (main)
l2_rs:          .space 3                @ encoder registers R2, R1, R0
    .balign 2
l2_tickc:       .space 2                @ TIM2 ticks (l2_tick)
l2_last_blk:    .space 2
l2_last_state:  .space 2
l2_last_ent:    .space 2
l2_st:          .space 11               @ the STATE bytes of the last frame ([5]..[17] parts and [1..4])
    .balign 4
    .global l2_blk
l2_blk:         .space L2_BLK
l2_tmp:         .space 12               @ one encoded record group
l2_ents:        .space L2_ENT * L2_NENT

    .section .rodata.ble.l2, "a", %progbits
l2_pace_tab:    .byte 30, 25, 20, 17, 14, 12, 10, 8, 7

    .section .text.ble.l2, "ax", %progbits

@ -----------------------------------------------------------------------------
@ l2_tick - one TIM2 tick (10.02 ms) of link 2's time base
@ Context  : TIM2 interrupt (sys_tim2_isr); Clobbers r0, r1
@ -----------------------------------------------------------------------------
FUNC l2_tick
    ldr r0, =l2_tickc
    ldrh r1, [r0]
    adds r1, r1, #1
    strh r1, [r0]
    bx lr
ENDFUNC l2_tick

@ -----------------------------------------------------------------------------
@ l2_request - key code 0xA8: link 2 wanted; starts in l2_step once the echo is out
@ Context  : main (ble/commands.s); Clobbers r0, r1
@ RAM      : writes l2_want, l2_req, hb_on (IMP-56: the watch frees the meter if the companion vanishes)
@ -----------------------------------------------------------------------------
FUNC l2_request
    movs r0, #1
    ldr r1, =l2_want
    strb r0, [r1]
    ldr r1, =l2_req
    strb r0, [r1]
    ldr r1, =hb_on
    strb r0, [r1]
    bx lr
ENDFUNC l2_request

@ -----------------------------------------------------------------------------
@ l2_set_pace - key codes 0xAA..0xB2: r0 = index 0..8 into l2_pace_tab
@ Context  : main (ble/commands.s); Clobbers r0, r1
@ -----------------------------------------------------------------------------
FUNC l2_set_pace
    ldr r1, =l2_pace_tab
    ldrb r0, [r1, r0]
    ldr r1, =l2_pace
    strb r0, [r1]
    bx lr
ENDFUNC l2_set_pace

@ -----------------------------------------------------------------------------
@ l2_off - end link 2 (0xFD from the receive interrupt, ble_link_reset)
@ Context  : any (single byte stores); Clobbers r0, r1
@ Note     : a block in transmission is finished by ble_tx_pump; status frames follow
@ -----------------------------------------------------------------------------
FUNC l2_off
    movs r0, #0
    ldr r1, =l2_on
    strb r0, [r1]
    ldr r1, =l2_want
    strb r0, [r1]
    ldr r1, =l2_req
    strb r0, [r1]
    bx lr
ENDFUNC l2_off

@ -----------------------------------------------------------------------------
@ l2_start - link 2 on: everything reset, the first block will be a STATE
@ Context  : main (l2_step, with the transmitter idle and the echo queue empty)
@ Clobbers : r0-r3
@ -----------------------------------------------------------------------------
LFUNC l2_start
    mrs r3, primask
    cpsid i
    movs r0, #0
    ldr r1, =l2_req
    strb r0, [r1]
    ldr r1, =ble_start_pending
    strb r0, [r1]                           @ no status frame start left over
    ldr r1, =ble_frame_ready
    strb r0, [r1]
    ldr r1, =l2_blk_ready
    strb r0, [r1]
    ldr r1, =l2_seq
    strb r0, [r1]
    ldr r1, =l2_eh
    strb r0, [r1]
    ldr r1, =l2_et
    strb r0, [r1]                           @ no reading queued
    ldr r1, =l2_pace
    ldrb r2, [r1]
    cbnz r2, 1f
    movs r2, #L2_PACE_DEF
    strb r2, [r1]                           @ the default pace unless the companion chose one
1:  movs r0, #1
    ldr r1, =l2_state_due
    strb r0, [r1]                           @ STATE first
    ldr r1, =l2_tickc
    ldrh r0, [r1]
    subs r0, r0, r2
    ldr r1, =l2_last_blk
    strh r0, [r1]                           @ the first block may go at once
    ldr r1, =l2_tickc
    ldrh r0, [r1]
    ldr r1, =l2_last_ent
    strh r0, [r1]
    movs r0, #1
    ldr r1, =l2_on
    strb r0, [r1]
    msr primask, r3
    bx lr
ENDFUNC l2_start

@ -----------------------------------------------------------------------------
@ l2_frame - a complete status frame (ble_frame_b) while link 2 is on: queue the reading, note a STATE change
@ In/Out   : - / -
@ Clobbers : r0-r3, r12 (r4-r7 saved)
@ Context  : main (build_status_packet_19b, only for a frame with a reading, OF-34)
@ RAM      : reads ble_frame_b, l2_tickc; writes l2_st, l2_ver, l2_state_due, l2_ents, l2_eh, l2_last_ent, l2_dropped
@ -----------------------------------------------------------------------------
FUNC l2_frame
    push {r4-r7, lr}
    ldr r4, =ble_frame_b
    ldr r5, =l2_tmp                         @ the 11 STATE bytes of this frame, built in l2_tmp
    ldrb r0, [r4, #5]
    and r0, r0, #0x3F
    strb r0, [r5, #0]
    ldrb r0, [r4, #6]
    and r0, r0, #0x3F
    strb r0, [r5, #1]
    ldrb r0, [r4, #9]
    strb r0, [r5, #2]
    ldrb r0, [r4, #13]
    and r0, r0, #0xFB
    strb r0, [r5, #3]
    ldrb r0, [r4, #15]
    strb r0, [r5, #4]
    ldrb r0, [r4, #16]
    strb r0, [r5, #5]
    ldrb r0, [r4, #17]
    strb r0, [r5, #6]
    ldrb r0, [r4, #1]
    strb r0, [r5, #7]
    ldrb r0, [r4, #2]
    strb r0, [r5, #8]
    ldrb r0, [r4, #3]
    strb r0, [r5, #9]
    ldrb r0, [r4, #4]
    strb r0, [r5, #10]
    ldr r6, =l2_st                          @ compare with the last; a change: copy, new version, STATE due
    movs r2, #0
    movs r3, #0
1:  ldrb r0, [r5, r2]
    ldrb r1, [r6, r2]
    cmp r0, r1
    beq 2f
    strb r0, [r6, r2]
    movs r3, #1
2:  adds r2, r2, #1
    cmp r2, #11
    blo 1b
    cbz r3, 3f
    ldr r1, =l2_ver
    ldrb r0, [r1]
    adds r0, r0, #1
    strb r0, [r1]
    movs r0, #1
    ldr r1, =l2_state_due
    strb r0, [r1]
3:  ldr r1, =l2_eh                          @ queue full (15 of 16): this reading is dropped and counted
    ldrb r6, [r1]
    ldr r1, =l2_et
    ldrb r0, [r1]
    subs r0, r6, r0
    and r0, r0, #(L2_NENT - 1)
    cmp r0, #(L2_NENT - 1)
    blo 4f
    ldr r1, =l2_dropped
    ldrb r0, [r1]
    adds r0, r0, #1
    strb r0, [r1]
    pop {r4-r7, pc}
4:  movs r0, #L2_ENT
    mul r0, r6, r0
    ldr r7, =l2_ents
    add r7, r7, r0                          @ r7 = the new entry
    ldr r1, =l2_ver
    ldrb r0, [r1]
    strb r0, [r7, #0]                       @ the settings version of this reading
    ldrb r0, [r4, #6]
    and r1, r0, #0x40
    lsls r1, r1, #1                         @ bit 7 = negative
    ldrb r2, [r4, #5]
    lsrs r2, r2, #6                         @ value bits 17..16
    orrs r1, r1, r2
    strb r1, [r7, #1]                       @ v2 = sign | bits 17..16
    ldrb r1, [r4, #7]
    strb r1, [r7, #2]
    ldrb r1, [r4, #8]
    strb r1, [r7, #3]
    and r1, r0, #0x80                       @ overload ([6] bit 7)
    ldrb r2, [r4, #14]
    and r2, r2, #0x1F                       @ bar 0..25
    orrs r1, r1, r2
    ldrb r2, [r4, #13]
    and r2, r2, #0x04
    lsls r2, r2, #3                         @ bar sign ([13] bit 2) -> bit 5
    orrs r1, r1, r2
    strb r1, [r7, #4]                       @ ob
    ldrb r0, [r4, #10]
    strb r0, [r7, #5]
    ldrb r0, [r4, #11]
    strb r0, [r7, #6]
    ldrb r0, [r4, #12]
    strb r0, [r7, #7]
    bl ble_rate_period                      @ r0 = ticks per reading
    mov r5, r0
    ldr r1, =l2_tickc
    ldrh r2, [r1]
    strb r2, [r7, #9]
    lsrs r3, r2, #8
    strb r3, [r7, #10]                      @ the time of this reading
    ldr r1, =l2_last_ent
    ldrh r3, [r1]
    strh r2, [r1]
    subs r2, r2, r3
    uxth r2, r2                             @ ticks since the previous reading
    lsrs r3, r5, #1
    adds r2, r2, r3
    udiv r2, r2, r5                         @ periods, rounded
    cmp r2, #1
    it lo
    movlo r2, #1
    cmp r2, #255
    it hi
    movhi r2, #255
    strb r2, [r7, #8]                       @ gap: periods since the previous reading (1 = none missing)
    adds r6, r6, #1
    and r6, r6, #(L2_NENT - 1)
    ldr r1, =l2_eh
    strb r6, [r1]
    pop {r4-r7, pc}
ENDFUNC l2_frame

@ -----------------------------------------------------------------------------
@ l2_step - main loop step: start / suspend link 2, build the next block at the pace
@ Context  : main (sys_main, after step 11); Clobbers r0-r3, r12 (r4-r11 saved)
@ -----------------------------------------------------------------------------
FUNC l2_step
    push {r4-r11, lr}
    ldr r0, =bft_active
    ldrb r0, [r0]
    cbz r0, 1f
    ldr r1, =l2_on                          @ page Ld: blocks stop, they start again after the page
    ldrb r0, [r1]
    cmp r0, #0
    beq 9f
    movs r0, #0
    strb r0, [r1]
    movs r0, #1
    ldr r1, =l2_req
    strb r0, [r1]
    b 9f
1:  ldr r0, =l2_req
    ldrb r0, [r0]
    cbz r0, 2f
    ldr r0, =l2_want
    ldrb r0, [r0]
    cmp r0, #0
    beq 9f
    ldr r0, =ble_tx_state
    ldrb r0, [r0]
    cmp r0, #0
    bne 9f                                  @ a frame or the echo still goes out
    ldr r0, =ble_txq_tail
    ldrb r0, [r0]
    ldr r1, =ble_txq_head
    ldrb r1, [r1]
    cmp r0, r1
    bne 9f
    bl l2_start
2:  ldr r0, =l2_on
    ldrb r0, [r0]
    cmp r0, #0
    beq 9f
    ldr r0, =l2_blk_ready
    ldrb r0, [r0]
    cmp r0, #0
    bne 9f                                  @ the previous block is still going out
    ldr r0, =l2_tickc
    ldrh r4, [r0]                           @ r4 = now
    ldr r0, =l2_last_blk
    ldrh r0, [r0]
    subs r0, r4, r0
    uxth r0, r0
    ldr r1, =l2_pace
    ldrb r1, [r1]
    cmp r0, r1
    blo 9f                                  @ not yet: the pace
    ldr r0, =ble_txq_tail                   @ answers first
    ldrb r0, [r0]
    ldr r1, =ble_txq_head
    ldrb r1, [r1]
    cmp r0, r1
    beq 3f
    bl l2_build_text
    b 8f
3:  ldr r0, =l2_eh                          @ readings queued under an older settings version go before the new STATE
    ldrb r0, [r0]
    ldr r1, =l2_et
    ldrb r1, [r1]
    cmp r0, r1
    beq 6f
    mov r0, r1
    bl l2_entry
    ldrb r0, [r0]
    ldr r1, =l2_ver
    ldrb r1, [r1]
    cmp r0, r1
    beq 6f
    bl l2_build_read
    b 8f
6:  ldr r0, =l2_state_due
    ldrb r0, [r0]
    cbnz r0, 4f
    ldr r0, =l2_last_state
    ldrh r0, [r0]
    subs r0, r4, r0
    uxth r0, r0
    cmp r0, #L2_STATE_EVERY
    blo 5f
4:  bl l2_build_state
    b 8f
5:  ldr r0, =l2_eh
    ldrb r0, [r0]
    ldr r1, =l2_et
    ldrb r1, [r1]
    cmp r0, r1
    beq 9f                                  @ nothing to send
    bl l2_build_read
8:  ldr r0, =l2_last_blk
    strh r4, [r0]
    bl l2_parity
    movs r0, #1
    ldr r1, =l2_blk_ready
    strb r0, [r1]
    bl ble_tx_kick
9:  pop {r4-r11, pc}
ENDFUNC l2_step

@ -----------------------------------------------------------------------------
@ l2_head - r0 = type: write H (type | seq) into l2_blk[0], seq + 1, zero the payload
@ Clobbers : r0-r3
@ -----------------------------------------------------------------------------
LFUNC l2_head
    ldr r1, =l2_seq
    ldrb r2, [r1]
    orrs r0, r0, r2
    adds r2, r2, #1
    and r2, r2, #0x3F
    strb r2, [r1]
    ldr r1, =l2_blk
    strb r0, [r1]
    movs r0, #0
    movs r2, #1
1:  strb r0, [r1, r2]
    adds r2, r2, #1
    cmp r2, #L2_PAYEND
    blo 1b
    bx lr
ENDFUNC l2_head

@ -----------------------------------------------------------------------------
@ l2_build_text - TEXT block: up to 15 bytes of the answer queue (ble_txq)
@ Clobbers : r0-r3, r12 (r4-r6 saved)
@ -----------------------------------------------------------------------------
LFUNC l2_build_text
    push {r4-r6, lr}
    movs r0, #L2_T_TEXT
    bl l2_head
    ldr r4, =l2_blk
    ldr r5, =ble_txq_tail
    ldrb r2, [r5]                           @ tail
    ldr r1, =ble_txq_head
    ldrb r3, [r1]                           @ head
    ldr r6, =ble_txq
    movs r1, #0                             @ n
1:  cmp r2, r3
    beq 2f
    cmp r1, #15
    bhs 2f
    ldrb r0, [r6, r2]
    adds r12, r1, #2
    strb r0, [r4, r12]
    adds r2, r2, #1
    and r2, r2, #0xFF                       @ BLE_TXQ_LEN 256
    adds r1, r1, #1
    b 1b
2:  strb r2, [r5]                           @ tail: the bytes are taken
    strb r1, [r4, #1]                       @ n
    pop {r4-r6, pc}
ENDFUNC l2_build_text

@ -----------------------------------------------------------------------------
@ l2_build_state - STATE block (section header)
@ Clobbers : r0-r3 (r4, r5 saved)
@ -----------------------------------------------------------------------------
LFUNC l2_build_state
    push {r4, r5, lr}
    movs r0, #L2_T_STATE
    bl l2_head
    ldr r4, =l2_blk
    ldr r1, =l2_ver
    ldrb r0, [r1]
    strb r0, [r4, #1]
    ldr r5, =l2_st
    movs r2, #0
1:  ldrb r0, [r5, r2]
    adds r3, r2, #2
    strb r0, [r4, r3]
    adds r2, r2, #1
    cmp r2, #11
    blo 1b
    bl ble_rate_period
    strb r0, [r4, #13]
    ldr r1, =ble_battery
    ldrh r0, [r1]
    lsrs r1, r0, #8
    strb r1, [r4, #14]
    strb r0, [r4, #15]
    ldr r1, =l2_dropped
    ldrb r0, [r1]
    strb r0, [r4, #16]
    movs r0, #0
    ldr r1, =l2_state_due
    strb r0, [r1]
    ldr r1, =l2_tickc
    ldrh r0, [r1]
    ldr r1, =l2_last_state
    strh r0, [r1]
    pop {r4, r5, pc}
ENDFUNC l2_build_state

@ -----------------------------------------------------------------------------
@ l2_build_read - READ block from the queued readings of one version (section header)
@ Clobbers : r0-r3, r12 (r4-r11 saved by l2_step's frame; this routine saves its own)
@ Register use: r4 l2_blk, r5 write index, r6 entry index (tail), r7 entry, r8 previous entry, r9 head,
@               r10 signed value of the previous reading, r11 the block's version
@ -----------------------------------------------------------------------------
LFUNC l2_build_read
    push {r4-r11, lr}
    movs r0, #L2_T_READ
    bl l2_head
    ldr r4, =l2_blk
    ldr r0, =l2_et
    ldrb r6, [r0]
    ldr r0, =l2_eh
    ldrb r9, [r0]
    mov r0, r6
    bl l2_entry                             @ r0 = entry address
    mov r7, r0
    ldrb r11, [r7, #0]                      @ the version of the block = that of its first reading
    strb r11, [r4, #1]
    ldrb r0, [r7, #5]
    strb r0, [r4, #3]
    ldrb r0, [r7, #6]
    strb r0, [r4, #4]
    ldrb r0, [r7, #7]
    strb r0, [r4, #5]                       @ the first reading's sub bytes
    ldrb r0, [r7, #4]
    lsrs r0, r0, #7
    orr r0, r0, #0xE2
    strb r0, [r4, #6]                       @ absolute with bar, overload bit
    ldrb r0, [r7, #1]
    strb r0, [r4, #7]
    ldrb r0, [r7, #2]
    strb r0, [r4, #8]
    ldrb r0, [r7, #3]
    strb r0, [r4, #9]
    ldrb r0, [r7, #4]
    and r0, r0, #0x3F
    strb r0, [r4, #10]                      @ bar | bar sign
    movs r5, #11
    mov r8, r7
    mov r0, r7
    bl l2_signed
    mov r10, r0
    adds r6, r6, #1
    and r6, r6, #(L2_NENT - 1)
.Lbr_next:
    cmp r6, r9
    beq .Lbr_done                           @ no more queued readings
    mov r0, r6
    bl l2_entry
    mov r7, r0
    ldrb r0, [r7, #0]
    cmp r0, r11
    bne .Lbr_done                           @ another settings version: the next block (after its STATE)
    ldr r12, =l2_tmp                        @ encode this reading into l2_tmp, r3 = its length
    movs r3, #0
    ldrb r0, [r7, #8]
    cmp r0, #1
    bls 1f
    movs r1, #0xF4
    strb r1, [r12, r3]
    adds r3, r3, #1
    subs r0, r0, #1
    strb r0, [r12, r3]                      @ GAP: periods without a reading
    adds r3, r3, #1
1:  ldrb r0, [r7, #5]                       @ sub changed?
    ldrb r1, [r8, #5]
    cmp r0, r1
    bne 2f
    ldrb r0, [r7, #6]
    ldrb r1, [r8, #6]
    cmp r0, r1
    bne 2f
    ldrb r0, [r7, #7]
    ldrb r1, [r8, #7]
    cmp r0, r1
    beq 3f
2:  movs r1, #0xF0
    strb r1, [r12, r3]
    adds r3, r3, #1
    ldrb r0, [r7, #5]
    strb r0, [r12, r3]
    adds r3, r3, #1
    ldrb r0, [r7, #6]
    strb r0, [r12, r3]
    adds r3, r3, #1
    ldrb r0, [r7, #7]
    strb r0, [r12, r3]
    adds r3, r3, #1
3:  mov r0, r7
    bl l2_signed                            @ r0 = signed value, r1 = 1 for a negative zero (r2, r3? no: see l2_signed)
    @ r0 signed value of this reading, r1 negative-zero flag; the previous: r10
    ldrb r2, [r7, #4]
    ldrb r12, [r8, #4]
    eor r12, r12, r2                        @ differences in ob
    tst r12, #0x80
    bne .Lbr_abs                            @ overload changed: absolute
    cbnz r1, .Lbr_abs                       @ a negative zero: absolute
    push {r0}
    mov r0, r8
    bl l2_signed
    mov r2, r1                              @ previous negative zero?
    pop {r0}
    cbnz r2, .Lbr_abs
    subs r1, r0, r10                        @ d
    ldrb r2, [r7, #4]
    ldrb r12, [r8, #4]
    eor r12, r12, r2
    tst r12, #0x3F
    bne .Lbr_bar                            @ bar or bar sign changed
    cmn r1, #32
    blt .Lbr_abs
    cmp r1, #31
    bgt .Lbr_abs
    and r1, r1, #0x3F
    orr r1, r1, #0x80
    ldr r12, =l2_tmp
    strb r1, [r12, r3]
    adds r3, r3, #1
    b .Lbr_put
.Lbr_bar:
    cmn r1, #64
    blt .Lbr_abs
    cmp r1, #63
    bgt .Lbr_abs
    ldr r12, =l2_tmp
    and r2, r2, #0x1F
    adds r2, r2, #0xC0
    strb r2, [r12, r3]
    adds r3, r3, #1
    and r1, r1, #0x7F
    ldrb r2, [r7, #4]
    tst r2, #0x20
    beq 4f
    orr r1, r1, #0x80
4:  strb r1, [r12, r3]
    adds r3, r3, #1
    b .Lbr_put
.Lbr_abs:
    ldr r12, =l2_tmp
    ldrb r2, [r7, #4]
    lsrs r1, r2, #7                         @ overload bit
    ldrb r2, [r8, #4]
    ldrb r0, [r7, #4]
    eor r2, r2, r0
    tst r2, #0x3F
    beq 5f
    orr r1, r1, #0xE2                       @ absolute with bar
    b 6f
5:  orr r1, r1, #0xE0                       @ absolute, bar unchanged
6:  strb r1, [r12, r3]
    adds r3, r3, #1
    ldrb r0, [r7, #1]
    strb r0, [r12, r3]
    adds r3, r3, #1
    ldrb r0, [r7, #2]
    strb r0, [r12, r3]
    adds r3, r3, #1
    ldrb r0, [r7, #3]
    strb r0, [r12, r3]
    adds r3, r3, #1
    tst r1, #0x02
    beq .Lbr_put
    ldrb r0, [r7, #4]
    and r0, r0, #0x3F
    strb r0, [r12, r3]
    adds r3, r3, #1
.Lbr_put:
    adds r0, r5, r3
    cmp r0, #L2_PAYEND
    bhi .Lbr_done                           @ does not fit: the next block
    ldr r12, =l2_tmp                        @ copy the reading's records into the block
    movs r1, #0
7:  ldrb r2, [r12, r1]
    strb r2, [r4, r5]
    adds r5, r5, #1
    adds r1, r1, #1
    cmp r1, r3
    blo 7b
    mov r0, r7
    bl l2_signed
    mov r10, r0
    mov r8, r7
    adds r6, r6, #1
    and r6, r6, #(L2_NENT - 1)
    b .Lbr_next
.Lbr_done:
    ldr r0, =l2_et
    strb r6, [r0]                           @ the readings in the block are taken
    ldrb r0, [r8, #9]                       @ age: ticks since the newest reading of the block
    ldrb r1, [r8, #10]
    orr r0, r0, r1, lsl #8
    ldr r1, =l2_tickc
    ldrh r1, [r1]
    subs r1, r1, r0
    uxth r1, r1
    cmp r1, #255
    it hi
    movhi r1, #255
    strb r1, [r4, #2]
    pop {r4-r11, pc}
ENDFUNC l2_build_read

@ -----------------------------------------------------------------------------
@ l2_entry - r0 = queue index -> r0 = entry address.  Clobbers r1
@ -----------------------------------------------------------------------------
LFUNC l2_entry
    movs r1, #L2_ENT
    mul r0, r0, r1
    ldr r1, =l2_ents
    add r0, r0, r1
    bx lr
ENDFUNC l2_entry

@ -----------------------------------------------------------------------------
@ l2_signed - r0 = entry address -> r0 = signed value, r1 = 1 if a negative zero (else 0).  Clobbers r2
@ -----------------------------------------------------------------------------
LFUNC l2_signed
    ldrb r1, [r0, #1]
    ldrb r2, [r0, #2]
    lsls r2, r2, #8
    ldrb r0, [r0, #3]
    orrs r2, r2, r0
    and r0, r1, #0x03
    orr r0, r2, r0, lsl #16                 @ absolute value, 18 bits
    tst r1, #0x80
    beq 1f
    cbz r0, 2f
    rsbs r0, r0, #0                         @ negative
1:  movs r1, #0
    bx lr
2:  movs r1, #1                             @ negative zero
    bx lr
ENDFUNC l2_signed

@ -----------------------------------------------------------------------------
@ l2_parity - Reed-Solomon parity of l2_blk[0..16] into l2_blk[17..19]
@ Clobbers : r0-r3, r12 (r4, r5 saved)
@ -----------------------------------------------------------------------------
LFUNC l2_parity
    push {r4, r5, lr}
    ldr r0, =l2_rs
    movs r1, #0
    strb r1, [r0]
    strb r1, [r0, #1]
    strb r1, [r0, #2]
    ldr r4, =l2_blk
    movs r5, #0
1:  ldrb r1, [r4, r5]
    bl l2_rs_feed
    adds r5, r5, #1
    cmp r5, #L2_PAYEND
    blo 1b
    ldr r0, =l2_rs
    ldrb r1, [r0]
    strb r1, [r4, #17]
    ldrb r1, [r0, #1]
    strb r1, [r4, #18]
    ldrb r1, [r0, #2]
    strb r1, [r4, #19]
    pop {r4, r5, pc}
ENDFUNC l2_parity

@ -----------------------------------------------------------------------------
@ l2_rs_feed - one byte into the Reed-Solomon encoder (was ble_rs_feed of IMP-60)
@ In       : r1 = the byte (kept)
@ Clobbers : r0, r2, r3, r12 (r4 saved)
@ Note     : fb = byte ^ R2; R2 = R1 ^ 7*fb; R1 = R0 ^ 14*fb; R0 = 8*fb over GF(256)/0x11D; m2 = 2*fb, m4 = 2*m2,
@            m8 = 2*m4 (x << 1, ^ 0x1D when bit 7 was set); 7*fb = m4^m2^fb, 14*fb = m8^m4^m2.  No tables.
@ -----------------------------------------------------------------------------
LFUNC l2_rs_feed
    push {r4, lr}
    ldr r12, =l2_rs
    ldrb r0, [r12]
    eors r0, r0, r1
    lsls r2, r0, #1
    tst r2, #0x100
    beq 1f
    eor r2, r2, #0x1D
1:  uxtb r2, r2
    lsls r3, r2, #1
    tst r3, #0x100
    beq 2f
    eor r3, r3, #0x1D
2:  uxtb r3, r3
    lsls r4, r3, #1
    tst r4, #0x100
    beq 3f
    eor r4, r4, #0x1D
3:  uxtb r4, r4
    eors r0, r0, r2
    eors r0, r0, r3                         @ 7 * fb
    eors r2, r2, r3
    eors r2, r2, r4                         @ 14 * fb
    ldrb r3, [r12, #1]
    eors r0, r0, r3
    strb r0, [r12]
    ldrb r3, [r12, #2]
    eors r2, r2, r3
    strb r2, [r12, #1]
    strb r4, [r12, #2]
    pop {r4, pc}
ENDFUNC l2_rs_feed

    .ltorg
