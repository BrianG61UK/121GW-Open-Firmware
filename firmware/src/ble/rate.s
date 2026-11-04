@ =============================================================================
@ rate.s - BLE: selectable status frame rate (production image only, DESIGN.md 10 IMP-09, FEATURES.md 2.5)
@
@ BLE module, part 3.  v2.05 builds the 19-byte status frame at count 40 of the TIM2 counter 0x20007F04 and starts it at
@ count 50 (one frame per 50 ticks of 10.02 ms = 0.501 s, analysis/ble_packet.md 2).  The same counter also makes the
@ 500 ms flag, the blink phases and the jack-warning beep, so its period cannot change.  For the faster rates the port
@ uses its own counter ble_rate_cnt, stepped on every TIM2 tick by ble_rate_tick:
@
@     code  frames/s  period (ticks)  build request at count  build-to-start (ticks)
@     0     2         50              40                      10     v2.05: the counter 0x20007F04, not this file
@     1     4         25              15                      10
@     2     10        10               5                       5
@     3     20         5               3                       2     the build comes 3 ticks after the previous start,
@                                                                    when that frame (9.9 ms at 19200 baud) is out
@
@ Build and transmission stay those of the port (OF-10): the builder fills ble_frame_b and marks it complete, the start
@ only requests a transmission, and the transmit pump copies the frame only when it is complete; a start that finds no
@ complete frame sends nothing (as for an invalid value, OF-34), so a rate is a maximum and a frame is never torn.
@ Echoes of received commands are queued and sent between frames (usart.s).
@
@ Context: ble_rate_tick in the TIM2 interrupt; ble_rate is written by main (set/bt.s) and read by the interrupt (one
@ byte, single-copy atomic).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ ble_build_req,       v_2000802C    @ status frame build request, cleared and served by sys_main step 7

    .section .bss_port.ble, "aw", %nobits
@ ble_rate: frame rate code 0..3 (2, 4, 10, 20 per second), loaded from EEPROM 0x015 at boot and wake, edited on the
@ SETUP page bt (owner SET; read by sys_tim2_isr and ble_rate_tick)
    .global ble_rate
ble_rate:       .space 1
@ ble_rate_cnt: TIM2 tick count of the present frame period, 0 .. period - 1 (owner BLE, TIM2 interrupt only)
    .global ble_rate_cnt
ble_rate_cnt:   .space 1

    .section .rodata.ble.rate, "a", %progbits
@ ble_rate_table: per code the period in ticks and the count at which the build is requested
ble_rate_table:
    .byte 50, 40                            @ 0: 2 per second (as v2.05; not used, code 0 runs the v2.05 counter)
    .byte 25, 15                            @ 1: 4 per second
    .byte 10, 5                             @ 2: 10 per second
    .byte 5, 3                              @ 3: 20 per second
    .size ble_rate_table, . - ble_rate_table

    .section .text.ble.rate, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ble_rate_tick - one TIM2 tick of the selectable frame rate (codes 1..3)
@ Replaces : for codes 1..3, the build request at count 40 (0x080245F6..0x08024606) and the frame start at count 50 of
@            IRQ28_Handler 0x0802428C (port: ble_tx_start_frame)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : TIM2 interrupt (sys_tim2_isr), only while ble_rate != 0
@ RAM      : reads ble_rate; reads and writes ble_rate_cnt; writes ble_build_req (0x2000802C)
@ Note     : As v2.05 at its counter: the build request is tested on the count before the increment, the start when the
@            incremented count reaches the period (then the count restarts at 0).  A count at or above the period of a
@            newly selected code (the code changed during a period) also restarts it.
@ -----------------------------------------------------------------------------
FUNC ble_rate_tick
    push {r4, lr}
    ldr r0, =ble_rate
    ldrb r0, [r0]
    and r0, r0, #3                          @ index inside the 4-entry table
    ldr r1, =ble_rate_table
    add r1, r1, r0, lsl #1                  @ 2 bytes per code
    ldrb r2, [r1]                           @ r2 = period
    ldrb r3, [r1, #1]                       @ r3 = build count
    ldr r1, =ble_rate_cnt
    ldrb r0, [r1]                           @ r0 = count
    cmp r0, r3
    bne 1f
    movs r4, #1
    ldr r12, =ble_build_req
    strb r4, [r12]                          @ build request (served by sys_main step 7 while BLE is on)
1:  adds r0, r0, #1
    cmp r0, r2
    bhs 2f                                  @ period complete
    strb r0, [r1]
    pop {r4, pc}
2:  movs r0, #0
    strb r0, [r1]                           @ a new period
    bl ble_tx_start_frame                   @ frame start request (nothing while BLE is off)
    pop {r4, pc}
ENDFUNC ble_rate_tick

    .ltorg

