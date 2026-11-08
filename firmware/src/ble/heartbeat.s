@ =============================================================================
@ heartbeat.s - BLE: the link watch (production image only, DESIGN.md 10 IMP-56, FEATURES.md 2.30; GitHub issue 23)
@
@ BLE module, part 9.  The meter takes one Bluetooth connection and advertises only while it has none.  When the computer
@ keeps a connection the companion has given up (Windows was seen to keep it after the companion's Disconnect: the
@ meter no longer advertised and a new Connect found nothing until Bluetooth was switched off and on), no program on the
@ computer can end it.  The meter can: switching its Bluetooth module off ends the radio link, and the computer must
@ let go.
@
@ Protocol (owner design 2026-11-08, reviewed): the companion writes the single byte 0xFE ("still here") every 5 s when
@ it has written nothing else, and 0xFD before a clean disconnect.  On the measuring pages the receive parser ignores
@ a first byte that is neither F4 nor F8 (ble/usart.s .Lrx_resync), so older firmware ignores both bytes, and this
@ firmware takes 0xFE as "watch on" and 0xFD as "watch off" there.  The phone app never sends 0xFE: the watch never
@ runs for it.  On page Ld every byte belongs to the file transfer (bft_rx_byte) and the bytes are not looked at.
@
@ The watch: every byte received from the module sets hb_seen (ble_usart2_isr, any byte: anything from the computer
@ proves it is there; bytes received under HSE count too, their parser reset is NF-04's).  The TIM2 tick (hb_tick, the
@ only writer of hb_cnt) clears hb_cnt on hb_seen and else counts 10 ms ticks while the watch is on, the module is on
@ and page Ld is not shown (page Ld: an idle page receives nothing for minutes; the count is held at 0 there).  At
@ HB_LIMIT (15 s without a byte) the watch goes off and main (hb_service) switches the module off
@ (usart2_deinit_pf15_low: the radio link ends); HB_OFF later (5 s: the computer notices a lost link only after its
@ supervision timeout, several seconds) main switches it on again as a long PEAK does (fn_0800C51A(1)): the module
@ advertises, the companion reconnects and sends 0xFE again.  Every switching of Bluetooth on or off (long PEAK,
@ power-up, wake, this module's own step) ends a reset in progress (hb_cancel, called by fn_0800C51A).
@
@ No EEPROM, calibration or option access.  Context: hb_tick in the TIM2 interrupt (priority 0xA0), the receive part
@ in ble_usart2_isr (priority 0, it preempts TIM2: it only writes the bytes hb_seen and hb_on), hb_service and
@ hb_cancel in main.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ HB_LIMIT,      1500                @ 10 ms ticks without a byte from the computer: 15 s
    .equ HB_OFF,        500                 @ 10 ms ticks with the module off: 5 s
    .equ HB_REQ_OFF,    1                   @ hb_req: switch the module off
    .equ HB_REQ_ON,     2                   @ hb_req: switch it on again
    .equ hb_ble_enable, v_2000802B          @ Bluetooth switched on by the user (long PEAK; key_ble_on)

    .section .bss_port.ble.hb, "aw", %nobits
@ hb_on: 1 while the companion's watch runs (0xFE received on a measuring page), 0 else (owner BLE; written by
@ ble_usart2_isr and by hb_tick at the timeout)
    .global hb_on
hb_on:          .space 1
@ hb_seen: 1 when a byte came from the computer since the last tick (written 1 by ble_usart2_isr, 0 by hb_tick)
    .global hb_seen
hb_seen:        .space 1
@ hb_phase: 1 while the module is off for a reset (main sets it, hb_tick ends it); hb_req: work for main
hb_phase:       .space 1
hb_req:         .space 1
    .balign 2
@ hb_cnt: 10 ms ticks without a byte (hb_tick only); hb_off_cnt: ticks of the off phase (hb_tick only, zeroed by main
@ before the phase starts)
hb_cnt:         .space 2
hb_off_cnt:     .space 2

    .section .text.ble.heartbeat, "ax", %progbits

@ -----------------------------------------------------------------------------
@ hb_tick - one TIM2 tick of the watch (10 ms)
@ In/Out   : - / -
@ Clobbers : r0-r3, flags
@ Context  : TIM2 interrupt (sys_tim2_isr)
@ RAM      : reads hb_phase, hb_on, ble_usart_on, bft_active; reads and clears hb_seen; writes hb_cnt, hb_off_cnt,
@            hb_on (0 at the timeout), hb_req, hb_phase (0 at the end of the off phase)
@ -----------------------------------------------------------------------------
FUNC hb_tick
    ldr r3, =hb_phase
    ldrb r0, [r3]
    cbz r0, 1f
    ldr r1, =hb_off_cnt                     @ the module is off: count the off phase
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    cmp r0, #HB_OFF
    blo 9f
    movs r0, #0
    strb r0, [r3]                           @ the off phase ends
    movs r0, #HB_REQ_ON
    ldr r1, =hb_req
    strb r0, [r1]                           @ main switches the module on again
    bx lr
1:  ldr r1, =hb_cnt
    ldr r2, =hb_on
    ldrb r0, [r2]
    cbz r0, 8f                              @ no watch: nothing counts
    ldr r0, =ble_usart_on
    ldrb r0, [r0]
    cbz r0, 8f                              @ the module is off (long PEAK): nothing counts
    ldr r0, =bft_active
    ldrb r0, [r0]
    cbnz r0, 8f                             @ page Ld: an idle page receives nothing, the count is held at 0
    ldr r0, =hb_seen
    ldrb r2, [r0]
    cbz r2, 3f
    movs r2, #0
    strb r2, [r0]                           @ a byte came: the count starts again
    strh r2, [r1]
    bx lr
3:  ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    movw r2, #HB_LIMIT                      @ 1500 is no modified immediate: compare through a register
    cmp r0, r2
    blo 9f
    movs r0, #0
    strh r0, [r1]
    ldr r2, =hb_on
    strb r0, [r2]                           @ 15 s without a byte: the watch ends (the companion arms it again)
    movs r0, #HB_REQ_OFF
    ldr r2, =hb_req
    strb r0, [r2]                           @ main switches the module off
9:  bx lr
8:  movs r0, #0
    strh r0, [r1]
    ldr r1, =hb_seen
    strb r0, [r1]
    bx lr
ENDFUNC hb_tick

@ -----------------------------------------------------------------------------
@ hb_service - main loop step: switch the module off or on for a reset of the link
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (sys_main, after step 11)
@ RAM      : reads and clears hb_req; reads hb_ble_enable; writes hb_off_cnt, hb_phase
@ Note     : only while Bluetooth is switched on by the user: a long PEAK that switched it off in the meantime wins
@ -----------------------------------------------------------------------------
FUNC hb_service
    push {r4, lr}
    ldr r4, =hb_req
    ldrb r0, [r4]
    cbz r0, 9f
    movs r1, #0
    strb r1, [r4]
    ldr r1, =hb_ble_enable
    ldrb r1, [r1]
    cbz r1, 9f                              @ Bluetooth switched off by the user: no reset
    cmp r0, #HB_REQ_OFF
    bne 2f
    ldr r1, =hb_seen
    ldrb r2, [r1]
    ldr r1, =hb_on
    ldrb r1, [r1]
    orrs r1, r1, r2
    bne 9f                                  @ a byte came after the timeout: the link is alive, no reset (critique 2026-11-08)
    bl usart2_deinit_pf15_low               @ the module off: the radio link ends, the computer must let go
    movs r0, #0
    ldr r1, =hb_off_cnt
    strh r0, [r1]                           @ the off phase starts at 0 ...
    movs r0, #1
    ldr r1, =hb_phase
    strb r0, [r1]                           @ ... and only then hb_tick counts it
    b 9f
2:  movs r0, #1
    bl fn_0800C51A                          @ the module on again as a long PEAK does (frame start, BT annunciator)
9:  pop {r4, pc}
ENDFUNC hb_service

@ -----------------------------------------------------------------------------
@ hb_cancel - end a reset in progress and the watch; called at every switching of Bluetooth on or off (fn_0800C51A:
@            long PEAK, power-up, wake, the watch's own switch-on)
@ In/Out   : - / -
@ Clobbers : r0, r1
@ Context  : main only
@ RAM      : writes hb_phase = 0, hb_req = 0, hb_on = 0, hb_seen = 0
@ Note     : the watch starts disarmed on every new link (critique 2026-11-08: armed across a PEAK off/on or a wake it
@            would reset a link a phone app had just made); the companion arms it again with its next 0xFE.  hb_cnt is
@            zeroed by hb_tick's next pass (no watch).  hb_phase is cleared before hb_req, so a tick in between sets no
@            request (it needs hb_phase 1)
@ -----------------------------------------------------------------------------
FUNC hb_cancel
    movs r0, #0
    ldr r1, =hb_phase
    strb r0, [r1]
    ldr r1, =hb_req
    strb r0, [r1]
    ldr r1, =hb_on
    strb r0, [r1]
    ldr r1, =hb_seen
    strb r0, [r1]
    bx lr
ENDFUNC hb_cancel

    .ltorg
