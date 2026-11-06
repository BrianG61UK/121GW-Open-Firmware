@ =============================================================================
@ xdiag.s - BLE: extended link diagnosis counters (DESIGN.md 10 IMP-44, FEATURES.md 2.11)
@
@ Counts what happens on the Bluetooth link inside the meter, so a report can tell damage on the module's serial line
@ (USART2) from damage on the radio or in the computer.  New in the port (v2.05 has nothing like it).  The counting is
@ switched by the companion with three key codes of the key frame F4 (ble/commands.s, as the version request 0x90):
@   0x93  counting on: all counters cleared, then the flag xd_on set to 1
@   0x94  counting off: the flag cleared (the counters keep their values)
@   0x95  counters request: answered with the frame F9 when the flag is on, with nothing but the echo when it is off
@ The flag lives in RAM only (.bss_port, 0 at every reset): it is never written to the EEPROM or the flash, and counting
@ never changes what the link does.  While the flag is 0 every counting call returns after one byte test.
@
@ Counters (u16, saturating at 0xFFFF, one block in this order; the order is the order of the frame F9 and of the page Ld
@ STATUS indices 40 .. 47, ble/bft.s):
@   0 xd_rx_bytes        bytes received on USART2 (every byte read from USART_DR by the receive interrupt)
@   1 xd_err_ore         SR.ORE seen in the receive interrupt: a byte was lost because the previous one was not read in time
@   2 xd_err_ne          SR.NE seen with a received byte: noise detected on the RX line
@   3 xd_err_fe          SR.FE seen with a received byte: framing error (wrong stop bit: line level or baud rate)
@   4 xd_rx_dropped_hse  bytes discarded because SYSCLK was not MSI (card session, NF-04, ble/usart.s)
@   5 xd_bad_frames      F4 key frames whose two code pairs differ and F8 set-clock frames whose XOR is wrong (ble/commands.s)
@   6 xd_bft_crc_bad     page Ld packets answered with status 1, CRC wrong (ble/bft.s)
@   7 xd_tx_q_full       answers / echoes not queued because the transmit queue lacked room (ble_tx_queue_put)
@ and a value that is not counted: 8 battery voltage pwr_bat_cv (0.01 V), read when the frame is built or STATUS 48 asked.
@ No parity counter: the link is 8N1, so SR.PE cannot be set.
@
@ Frame F9 (20 bytes): F9, the nine values above as u16 little-endian (18 bytes), XOR of the 19 bytes before it.
@
@ Context: xd_inc / xd_rx_account: main and USART2 interrupt; the rest: main only (commands.s).  A counter is written by
@ one context only (the receive counters by the interrupt, the others by main), so no read-modify-write is shared; the
@ clear in xd_start is a plain store of 0.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"

    .equ XD_NCOUNT,     8                   @ counters in the block
    .equ XD_FRAME_LEN,  20                  @ frame F9: marker, nine u16, XOR
    .equ XD_MARK,       0xF9                @ first byte of the frame

    .section .bss_port.xdiag, "aw", %nobits
    .balign 4
    .global xd_on
xd_on:              .space 1                @ 1 = counting (RAM only, 0 at reset)
    .balign 2
    .global xd_rx_bytes
xd_rx_bytes:        .space 2                @ counter 0
    .global xd_err_ore
xd_err_ore:         .space 2                @ counter 1
    .global xd_err_ne
xd_err_ne:          .space 2                @ counter 2
    .global xd_err_fe
xd_err_fe:          .space 2                @ counter 3
    .global xd_rx_dropped_hse
xd_rx_dropped_hse:  .space 2                @ counter 4
    .global xd_bad_frames
xd_bad_frames:      .space 2                @ counter 5
    .global xd_bft_crc_bad
xd_bft_crc_bad:     .space 2                @ counter 6
    .global xd_tx_q_full
xd_tx_q_full:       .space 2                @ counter 7
xd_frame:           .space XD_FRAME_LEN     @ the frame F9 being queued

    .section .text.ble.xdiag, "ax", %progbits

@ -----------------------------------------------------------------------------
@ xd_add - add 1 to a counter, saturating at 0xFFFF (no flag test)
@ In       : r0 = address of the u16 counter
@ Out      : -
@ Clobbers : r1, r2, flags
@ Context  : main, USART2 interrupt
@ -----------------------------------------------------------------------------
LFUNC xd_add
    ldrh r1, [r0]
    movw r2, #0xFFFF
    cmp r1, r2
    itt ne                                  @ at 0xFFFF the counter stays
    addne r1, r1, #1
    strhne r1, [r0]
    bx lr
ENDFUNC xd_add

@ -----------------------------------------------------------------------------
@ xd_inc - count one event
@ In       : r0 = address of the u16 counter
@ Out      : -
@ Clobbers : r0-r2, flags
@ Context  : main, USART2 interrupt
@ RAM      : reads xd_on; writes the counter when xd_on is 1
@ -----------------------------------------------------------------------------
FUNC xd_inc
    ldr r1, =xd_on
    ldrb r1, [r1]
    cbz r1, 1f                              @ counting off: nothing
    b xd_add
1:  bx lr
ENDFUNC xd_inc
    .ltorg

@ -----------------------------------------------------------------------------
@ xd_rx_account - count one pass of the receive interrupt that read USART_DR
@ In       : r0 = the SR value read before the DR read (the first half of the clearing sequence, RM0038 27.6.1),
@            r1 = 1 if the DR read delivered a received byte, 0 if it only cleared an overrun (OF-71)
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : USART2 interrupt
@ RAM      : reads xd_on; writes xd_rx_bytes, xd_err_ore, xd_err_ne, xd_err_fe
@ Note     : ORE is counted for every pass that saw it.  NE and FE belong to the received word (they are set together with
@            RXNE, RM0038 27.6.1), so they are counted only with a received byte.
@ -----------------------------------------------------------------------------
FUNC xd_rx_account
    push {r4, r5, lr}
    ldr r2, =xd_on
    ldrb r2, [r2]
    cbz r2, 9f                              @ counting off: nothing
    mov r4, r0                              @ SR value
    mov r5, r1                              @ received-byte flag
    cbz r5, 1f
    ldr r0, =xd_rx_bytes
    bl xd_add
1:  tst r4, #USART_SR_ORE
    beq 2f
    ldr r0, =xd_err_ore
    bl xd_add
2:  cbz r5, 9f                              @ no word received: NE / FE do not apply
    tst r4, #USART_SR_NF
    beq 3f
    ldr r0, =xd_err_ne
    bl xd_add
3:  tst r4, #USART_SR_FE
    beq 9f
    ldr r0, =xd_err_fe
    bl xd_add
9:  pop {r4, r5, pc}
ENDFUNC xd_rx_account
    .ltorg

@ -----------------------------------------------------------------------------
@ xd_start - key code 0x93: clear the counters and switch counting on
@ In       : -
@ Out      : -
@ Clobbers : r0-r2, flags
@ Context  : main only (fn_0800C332)
@ RAM      : writes xd_on and the eight counters
@ -----------------------------------------------------------------------------
FUNC xd_start
    movs r0, #0
    ldr r1, =xd_on
    strb r0, [r1]                           @ counting off while the block is cleared
    ldr r1, =xd_rx_bytes
    movs r2, #XD_NCOUNT
1:  strh r0, [r1], #2                       @ counter = 0
    subs r2, r2, #1
    bne 1b
    movs r0, #1
    ldr r1, =xd_on
    strb r0, [r1]                           @ counting on
    bx lr
ENDFUNC xd_start

@ -----------------------------------------------------------------------------
@ xd_stop - key code 0x94: switch counting off (the counters keep their values)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main only (fn_0800C332)
@ RAM      : writes xd_on
@ -----------------------------------------------------------------------------
FUNC xd_stop
    movs r0, #0
    ldr r1, =xd_on
    strb r0, [r1]
    bx lr
ENDFUNC xd_stop

@ -----------------------------------------------------------------------------
@ xd_send - key code 0x95: queue the frame F9 (only while counting is on)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main only (fn_0800C332)
@ RAM      : reads xd_on, the eight counters, pwr_bat_cv; writes xd_frame
@ Note     : every value is read with one halfword load, so an interrupt between two loads cannot tear a value.  A frame
@            refused by a full transmit queue is not repeated: the host asks again (and the refusal is counted in
@            xd_tx_q_full).
@ -----------------------------------------------------------------------------
FUNC xd_send
    push {r4, lr}
    ldr r0, =xd_on
    ldrb r0, [r0]
    cbz r0, 9f                              @ counting off: only the echo has gone out
    ldr r4, =xd_frame
    movs r0, #XD_MARK
    strb r0, [r4]                           @ byte 0
    ldr r1, =xd_rx_bytes
    adds r2, r4, #1                         @ destination: bytes 1 .. 16
    movs r3, #XD_NCOUNT
1:  ldrh r0, [r1], #2                       @ counter
    strb r0, [r2], #1                       @ low byte
    lsrs r0, r0, #8
    strb r0, [r2], #1                       @ high byte
    subs r3, r3, #1
    bne 1b
    ldr r1, =pwr_bat_cv
    ldrh r0, [r1]                           @ battery voltage, 0.01 V (pwr/battery.s)
    strb r0, [r2], #1                       @ byte 17
    lsrs r0, r0, #8
    strb r0, [r2], #1                       @ byte 18
    movs r0, #0
    movs r1, #0
2:  ldrb r2, [r4, r1]
    eors r0, r0, r2
    adds r1, r1, #1
    cmp r1, #(XD_FRAME_LEN - 1)
    bne 2b
    strb r0, [r4, #(XD_FRAME_LEN - 1)]      @ byte 19: XOR of bytes 0 .. 18
    mov r0, r4
    movs r1, #XD_FRAME_LEN
    bl ble_tx_queue_put
9:  pop {r4, pc}
ENDFUNC xd_send
    .ltorg
