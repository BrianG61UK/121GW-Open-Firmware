@ =============================================================================
@ isr_tim2.s - SYS: TIM2 update interrupt (IRQ28, every 10.02 ms at MSI 4.194 MHz)
@
@ Replaces IRQ28_Handler 0x0802428C..0x08024720 (v2.05) step for step, with these changes:
@  - the BLE frame start 0x08024630..0x0802465A (test of BLE-on 0x2000802B, 0x20008031 = 0, first frame byte
@    into USART2_DR, TXE interrupt on) is the BLE routine ble_tx_start_frame (OF-10, DESIGN.md 6.26);
@  - the setup page 7 blink drawing fn_0801896C(1) (0x080246FC) is replaced by setting rtc_blink_request; the
@    main loop draws on its next pass (NF-11, DESIGN.md 3.4).
@  - every tick calls ble_tx_tick (BLE) after the 500 ms block, before the 1 s counter; it starts a frame that
@    NF-04 deferred during SD access.
@  - production image: the FREQ / PULSE / DUTY no-signal timeout that publishes a zero result also increments
@    ar_freq_tmo_count (AR), which ends the OF-32 blanking of the main digits (owner decision).
@ Only ISR-safe routines are called: fn_080153AC (UI), pe7_on_with_timeout (BZB), ble_tx_start_frame and
@ ble_tx_tick (BLE).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.sys.isr_tim2, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sys_tim2_isr - 10 ms tick: flags, countdowns, logging tick, timeouts, BLE frame timing, blink phases
@ Replaces : 0x0802428C IRQ28_Handler (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12 (stacked by the exception entry)
@ Context  : IRQ28, priority 0xA0 (preemption 2)
@ RAM      : writes 0x200080D0, 0x20008035/36, 0x20007FA8, 0x20007FFA, 0x20007FE2, 0x20007FAA, 0x200080B4,
@            0x200080AA, 0x20008062, 0x20007FC4, 0x200080A3, 0x20007FC6, 0x20007FC0, 0x20007D64, 0x2000803D,
@            0x20008052, 0x20008051, 0x20007FB2, 0x2000805D, 0x2000804B, 0x2000803E, 0x20007D84, 0x20007F00,
@            0x200080D1, 0x2000802C, 0x20007F04, 0x200080D3, 0x20008077, 0x2000806F, 0x200080D5, 0x20007F08,
@            rtc_blink_request (port, RTC), ar_freq_tmo_count (port, AR; production only, this handler is its only writer)
@ Spec     : DESIGN.md 3.4 (table row IRQ28), 6.1
@ Deviation: NF-11, OF-10 (frame start in BLE), NF-04 (ble_tx_tick), OF-32 (production: ar_freq_tmo_count)
@ -----------------------------------------------------------------------------
FUNC sys_tim2_isr
    push {r4, lr}                           @ r4 = meter_mode copy where noted; keeps 8-byte stack alignment
    movs r1, #TIM_SR_UIF
    mov r0, #TIM2_BASE
    bl fn_0802099E                          @ clear the update flag (0x08024294)
    movs r0, #1
    ldr r1, =v_200080D0
    strb r0, [r1]                           @ 10 ms flag (0x0802429E)

    @ countdown 0x20008036 while 0x20008035 is set (0x080242A0..0x080242D2)
    ldr r0, =v_20008035
    ldrb r0, [r0]
    cbz r0, .Lt2_log
    ldr r1, =v_20008036
    ldrb r0, [r1]
    cbz r0, .Lt2_log
    subs r0, r0, #1
    strb r0, [r1]
    uxtb r0, r0
    cbnz r0, .Lt2_log
    ldr r1, =v_20008035
    strb r0, [r1]                           @ countdown over: 0x20008035 = 0 (0x080242D2)

.Lt2_log:
    @ logging tick for interval 0 (0x080242D4..0x08024330): every 16 ticks, up to 6 log requests per second
    ldr r0, =v_20007FE1
    ldrb r0, [r0]
    cbz r0, .Lt2_memview                    @ logging off
    ldr r0, =v_2000022C
    ldrh r0, [r0]
    cbnz r0, .Lt2_memview                   @ interval > 0: counted by the main loop
    ldr r0, =log_trig
    ldrb r0, [r0]
    cbnz r0, .Lt2_memview                   @ IMP-21: tr-Ch / tr-Lt: interval 0 means the trigger only
    ldr r0, =v_20008050
    ldrb r0, [r0]
    cbnz r0, .Lt2_memview                   @ auto-hold stage 2
    ldr r1, =v_20007FA8
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    uxth r0, r0
    cmp r0, #16
    blt .Lt2_memview                        @ signed compare as v2.05 (0x08024308)
    movs r0, #0
    strh r0, [r1]
    ldr r1, =v_20007FFA
    ldrb r0, [r1]
    adds r0, r0, #1
    strb r0, [r1]
    uxtb r0, r0
    cmp r0, #6
    bge .Lt2_memview                        @ 6 records this second already (0x08024328)
    movs r0, #1
    ldr r1, =v_20007FE2
    strb r0, [r1]                           @ log-write request (0x08024330)

.Lt2_memview:
    @ MEM view timeout (0x08024332..0x08024356): after more than 1000 ticks leave the view
    ldr r0, =v_20007FE4
    ldrb r0, [r0]
    cbz r0, .Lt2_b4
    ldr r1, =v_20007FAA
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    uxth r0, r0
    cmp r0, #1000
    ble .Lt2_b4
    bl fn_080153AC                          @ ISR-safe (DESIGN.md 3.4) (0x08024356)

.Lt2_b4:
    @ countdown 0x200080B4 (0x0802435A..0x08024370)
    ldr r1, =v_200080B4
    ldrb r0, [r1]
    cbz r0, .Lt2_page
    subs r0, r0, #1
    strb r0, [r1]

.Lt2_page:
    @ setup page timeout 0x200080AA: pages 10 in modes 16..21, or page 12 (0x08024372..0x080243EA)
    ldr r0, =meter_mode
    ldrb r4, [r0]                           @ r4 = meter_mode for the following blocks
    cmp r4, #0x10
    beq .Lt2_page_cur
    cmp r4, #0x12
    beq .Lt2_page_cur
    cmp r4, #0x14
    beq .Lt2_page_cur
    cmp r4, #0x11
    beq .Lt2_page_cur
    cmp r4, #0x13
    beq .Lt2_page_cur
    cmp r4, #0x15
    bne .Lt2_page_12
.Lt2_page_cur:                              @ current modes 16..21
    ldr r0, =v_20008037
    ldrb r0, [r0]
    cmp r0, #10
    beq .Lt2_page_dec
.Lt2_page_12:
    ldr r0, =v_20008037
    ldrb r0, [r0]
    cmp r0, #12
    bne .Lt2_cap
.Lt2_page_dec:
    ldr r1, =v_200080AA
    ldrb r0, [r1]
    cbz r0, .Lt2_cap
    subs r0, r0, #1
    strb r0, [r1]
    uxtb r0, r0
    cbnz r0, .Lt2_cap
    movs r0, #1
    ldr r1, =v_20008062
    strb r0, [r1]                           @ redraw request (0x080243EA)

.Lt2_cap:
    @ CAP: countdown 0x20007FC4 in mode 12 (0x080243EC..0x0802441E)
    cmp r4, #12
    bne .Lt2_fc6
    ldr r1, =v_20007FC4
    ldrh r0, [r1]
    cbz r0, .Lt2_fc6
    subs r0, r0, #1
    strh r0, [r1]
    uxth r0, r0
    cbnz r0, .Lt2_fc6
    movs r0, #1
    ldr r1, =v_200080A3
    strb r0, [r1]                           @ CAP timeout flag (0x0802441E)

.Lt2_fc6:
    ldr r1, =v_20007FC6
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]                           @ free-running tick counter (0x0802442C)

    @ FREQ/PULSE/DUTY no-signal timeout: more than 300 ticks (0x0802442E..0x080244C4)
    cmp r4, #6
    beq .Lt2_freq
    cmp r4, #7
    beq .Lt2_freq
    cmp r4, #8
    bne .Lt2_ac
.Lt2_freq:
    ldr r1, =v_20007FC0
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    uxth r0, r0
    cmp r0, #300
    ble .Lt2_ac
    movs r0, #0
    strh r0, [r1]
    ldr r1, =v_20007D64
    str r0, [r1]                            @ reading = 0 (0x08024474)
    ldr r0, =range_manual
    ldrb r0, [r0]
    cbnz r0, .Lt2_freq_hold
    movs r0, #0
    ldr r1, =meter_range
    strb r0, [r1]                           @ auto range: back to range 0 (0x08024486)
.Lt2_freq_hold:
    ldr r0, =v_20008050
    ldrb r0, [r0]
    cbz r0, .Lt2_freq_mean
    movs r0, #1
    ldr r1, =v_20008052
    strb r0, [r1]                           @ 0x08024498
    movs r0, #0
    ldr r1, =v_20008051
    strb r0, [r1]                           @ 0x080244A0
    ldr r1, =v_20007FB2
    strh r0, [r1]                           @ 0x080244A8
    b .Lt2_ac
.Lt2_freq_mean:
    movs r0, #1
    ldr r1, =v_2000805D
    strb r0, [r1]                           @ new (zero) mean (0x080244B2)
    ldr r1, =ar_freq_tmo_count
    ldrb r0, [r1]
    adds r0, r0, #1
    strb r0, [r1]                           @ production: count the published timeout zero (AR shows it, OF-32 decision)
    ldr r0, =range_manual
    ldrb r0, [r0]
    cbnz r0, .Lt2_ac
    movs r0, #1
    ldr r1, =v_2000804B
    strb r0, [r1]                           @ range apply request (0x080244C4)

.Lt2_ac:
    @ AC modes 16, 18, 20, 2, 4: more than 2000 ticks (0x080244C6..0x08024530)
    cmp r4, #0x10
    beq .Lt2_ac_cnt
    cmp r4, #0x12
    beq .Lt2_ac_cnt
    cmp r4, #0x14
    beq .Lt2_ac_cnt
    cmp r4, #2
    beq .Lt2_ac_cnt
    cmp r4, #4
    bne .Lt2_lowz
.Lt2_ac_cnt:
    ldr r1, =v_20007FC0
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    uxth r0, r0
    cmp r0, #2000
    ble .Lt2_lowz
    bl tim2_fc0_expired                     @ 0x08024512..0x08024530

.Lt2_lowz:
    @ LowZ with its AC state 0x20008098: more than 500 ticks (0x08024532..0x0802457E)
    cbnz r4, .Lt2_hold
    ldr r0, =v_20008098
    ldrb r0, [r0]
    cbz r0, .Lt2_hold
    ldr r1, =v_20007FC0
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    uxth r0, r0
    cmp r0, #500
    ble .Lt2_hold
    bl tim2_fc0_expired                     @ 0x08024560..0x0802457E

.Lt2_hold:
    @ auto-hold stage 2 beep timer 0x20007FB2 (0x08024580..0x080245CC)
    ldr r0, =v_20008050
    ldrb r0, [r0]
    ldr r1, =v_20008052
    ldrb r1, [r1]
    eor r1, r1, #1
    tst r0, r1                              @ stage 2 set and 0x20008052 clear (bitwise, as v2.05)
    beq .Lt2_hold_cap
    ldr r1, =v_20007FB2
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    uxth r0, r0
    cmp r0, #50
    bne .Lt2_hold_cap
    movs r0, #0
    strh r0, [r1]
    movs r0, #1
    ldr r1, =v_20008051
    strb r0, [r1]                           @ 0x080245BA
.Lt2_hold_cap:
    ldr r1, =v_20007FB2
    ldrh r0, [r1]
    cmp r0, #50
    blt .Lt2_100ms
    movs r0, #0
    strh r0, [r1]                           @ 0x080245CC

.Lt2_100ms:
    @ 100 ms flag (0x080245CE..0x080245F4)
    ldr r1, =v_20007F00
    ldr r0, [r1]
    adds r0, r0, #1
    str r0, [r1]
    cmp r0, #10
    blo .Lt2_ble_req
    movs r0, #0
    str r0, [r1]
    movs r0, #1
    ldr r1, =v_200080D1
    strb r0, [r1]

.Lt2_ble_req:
    bl bft_tick                             @ IMP-28: idle time of the Bluetooth file transfer parser (every tick)
    @ IMP-09: a selected frame rate above 2 per second runs on its own counter (ble/rate.s); the 500 ms counter below
    @ then only serves its other users (500 ms flag, blink phases, jack-warning beep)
    ldr r0, =ble_rate
    ldrb r0, [r0]
    cbz r0, .Lt2_ble_v205                   @ 2 per second: the v2.05 request and start below
    bl ble_rate_tick                        @ build request and frame start of the selected rate
    ldr r1, =v_20007F04
    b .Lt2_500ms
.Lt2_ble_v205:
    @ BLE frame build request at count 40 of the 500 ms counter (0x080245F6..0x08024606)
    ldr r1, =v_20007F04
    ldr r0, [r1]
    cmp r0, #40
    bne .Lt2_500ms
    movs r0, #1
    ldr r2, =v_2000802C
    strb r0, [r2]

.Lt2_500ms:
    @ 500 ms block (0x08024608..0x080246FE)
    ldr r0, [r1]                            @ r1 = 0x20007F04
    adds r0, r0, #1
    str r0, [r1]
    cmp r0, #50
    blo .Lt2_1s
    movs r0, #0
    str r0, [r1]
    movs r0, #1
    ldr r1, =v_200080D3
    strb r0, [r1]                           @ 500 ms flag (0x0802462E)
    ldr r0, =ble_rate
    ldrb r0, [r0]
    cbnz r0, .Lt2_no_start                  @ IMP-09: a faster rate starts its frames in ble_rate_tick
    bl ble_tx_start_frame                   @ BLE frame start, replaces 0x08024630..0x0802465A (OF-10)
.Lt2_no_start:
    @ jack-warning blink phase 0x20008077 (0x0802465E..0x0802467A)
    ldr r1, =v_20008077
    ldrb r0, [r1]
    cmp r0, #1
    ite eq                                  @ toggle between 0 and 1 (teq #1 at 0x08024664)
    moveq r0, #0                            @ was 1: becomes 0
    movne r0, #1                            @ anything else: becomes 1
    strb r0, [r1]
    @ jack-warning beep (0x0802467C..0x0802469E)
    ldr r0, =v_20008076
    ldrb r0, [r0]
    ldr r2, =v_200080B2
    ldrb r2, [r2]
    orrs r0, r0, r2
    uxtb r0, r0
    cbz r0, .Lt2_setup_blink
    ldrb r0, [r1]                           @ 0x20008077 re-read (0x08024690)
    cbz r0, .Lt2_setup_blink
    mov r0, #500
    bl pe7_on_with_timeout                  @ 500 TIM3 ticks (0x0802469E)
.Lt2_setup_blink:
    @ setup edit blink 0x2000806F (0x080246A2..0x080246D0)
    ldr r0, =v_2000806E
    ldrb r0, [r0]
    cbz r0, .Lt2_page7
    ldr r1, =v_2000806F
    ldrb r0, [r1]
    cmp r0, #1
    ite eq                                  @ toggle (teq #1 at 0x080246B2)
    moveq r0, #0                            @ was 1: becomes 0
    movne r0, #1                            @ anything else: becomes 1
    strb r0, [r1]
    movs r0, #1
    ldr r1, =v_20008062
    strb r0, [r1]                           @ redraw request (0x080246D0)
.Lt2_page7:
    @ setup page 7 (date/time) blink 0x200080D5 (0x080246D2..0x080246FC)
    ldr r0, =v_20008037
    ldrb r0, [r0]
    cmp r0, #7
    bne .Lt2_1s
    ldr r1, =v_200080D5
    ldrb r0, [r1]
    cmp r0, #1
    ite eq                                  @ toggle (teq #1 at 0x080246E2)
    moveq r0, #0                            @ was 1: becomes 0
    movne r0, #1                            @ anything else: becomes 1
    strb r0, [r1]
    movs r0, #1
    ldr r1, =rtc_blink_request
    strb r0, [r1]                           @ NF-11: main draws fn_0801896C(1) (v2.05 calls it here, 0x080246FC)

.Lt2_1s:
    bl ble_tx_tick                          @ every tick, after the 500 ms block: a BLE frame deferred while
                                            @ SYSCLK was HSE starts on the first tick back on MSI (NF-04,
                                            @ DESIGN.md 6.26; BLE interface, firmware/requests/W9_to_W1.md item 1)
    @ 1 s counter 0x20007F08 (0x08024700..0x0802471E)
    ldr r1, =v_20007F08
    ldr r0, [r1]
    adds r0, r0, #1
    str r0, [r1]
    cmp r0, #100
    blo .Lt2_done
    movs r0, #0
    str r0, [r1]
.Lt2_done:
    pop {r4, pc}
ENDFUNC sys_tim2_isr

@ -----------------------------------------------------------------------------
@ tim2_fc0_expired - common action of the two AC/LowZ timeouts of IRQ28
@ Replaces : the identical blocks 0x08024512..0x08024530 and 0x08024560..0x0802457E of IRQ28_Handler (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : IRQ28 only
@ RAM      : 0x20007FC0 = 0, 0x2000803E = 0, 0x20008062 = 1, 0x20007D84 = 0
@ -----------------------------------------------------------------------------
LFUNC tim2_fc0_expired
    movs r0, #0
    ldr r1, =v_20007FC0
    strh r0, [r1]
    ldr r1, =v_2000803E
    strb r0, [r1]
    movs r0, #1
    ldr r1, =v_20008062
    strb r0, [r1]
    movs r0, #0
    ldr r1, =v_20007D84
    str r0, [r1]
    bx lr
ENDFUNC tim2_fc0_expired

    .ltorg
