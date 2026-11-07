@ =============================================================================
@ msical.s - SYS: measure the MSI run clock against the HSE crystal, trim it, and give the USART2 baud the measured
@ frequency (DESIGN.md 10 IMP-46, FEATURES.md 2.20)
@
@ Why.  The meter runs on MSI range 6 (4.194304 MHz nominal), an RC oscillator: +-0.5 % after factory calibration at
@ 25 degC, +-3 % drift over 0..105 degC, 2.5 %/V (STM32L152xD datasheet Table 32).  v2.05 computes the USART2 baud
@ (19200, to the BLE112) from the nominal value (fn_0801FE2A), so every MSI error goes 1:1 into the baud, and the same
@ error is in the 10 ms tick, the 1 ms tick, the HY3131 bit timing and every delay loop.  A user's report (GitHub issue
@ 9) shows single damaged bytes from the meter that look like a receiver whose bit timing does not match (not proven).
@
@ Reference.  The 4.000 MHz crystal X2 (HSE).  The board has no LSE (the clock is the NJU6350; RTC / LCD run on LSI), so
@ the measurement uses the path RM0038 6.2.14 offers for crystal-less parts: TIM11_OR TI1_RMP = 10 puts HSE_RTC
@ (HSE / RTCPRE) on TIM11 channel 1 (rm0038.txt:27834..27840).  RTCPRE = 11 gives 250 kHz; input capture 1 with
@ prescaler 8 captures every 32.000 us; TIM11 counts on PCLK2 = SYSCLK = MSI (HPRE and PPRE2 /1, checked).  n captures
@ span n * 32 us, so f(MSI) = sum * 31250 / n: n = 256 (8.192 ms) f = sum * 15625 / 128, n = 1024 (32.768 ms)
@ f = sum * 15625 / 512.
@ RTC clock selection: on a meter (2026-11-07, F-1.17 test image) TIM11 counted but captured nothing while RTCSEL was LSI
@ (as the previous initialisation left it; SR showed UIF, never CC1IF), and captured with RTCSEL = HSE and RTCEN = 1.
@ RM0038 does not state this condition.  So ck_run resets the RTC domain (RTCRST, backup domain writable), selects HSE as
@ the RTC clock for the measurement and resets the RTC domain again afterwards.  This loses nothing: the next step of
@ sys_system_init, rcc_lsi_as_rtc_lcd_clock, resets the RTC domain and selects LSI at every initialisation, as v2.05 does
@ (0x0801BF92); the LCD (clocked by RTCCLK) is not running yet at either call.
@
@ HSE.  sys_clock_select(0) switches HSE off (sys/clock.s), so ck_run always finds HSEON = 0: it writes RTCPRE (only
@ possible while HSEON = 0, RM0038 6.3.1), starts HSE, measures, and switches HSE off again.  The PLL may still be on
@ (power-on: sys_set_sysclk left it on) and locks to HSE meanwhile; SYSCLK stays MSI throughout.
@
@ Trim.  MSITRIM (RCC_ICSCR 31:24) is added to the factory value MSICAL (RM0038 6.3.2).  Neither RM0038 nor the
@ datasheet gives the size or sign of one trim step for MSI, so every step is measured and kept only if the error got
@ smaller; a step that leaves +-6 % is taken back at once.  The walk: t0 (MSITRIM as found: 0 after reset, kept over
@ STOP, RM0038 6.2.3), then t0 + 1, + 2, ... while the error shrinks; if t0 + 1 is not better, t0 - 1, - 2, ...; at
@ most CK_STEPS_MAX measurements and |trim| <= CK_TRIM_MAX.  Within CK_DEAD (0.05 %) no walk.  The best trim is
@ measured again over 32.768 ms (ck_hz); if that is worse than before the walk, the trim goes back to t0
@ (CK_ST_UNDO) and ck_hz is the first measurement.
@
@ Use.  fn_0801FE2A (sys/clock.s, RCC_GetClocksFreq) returns ck_hz for MSI range 6 when ck_status is CK_ST_OK or
@ CK_ST_UNDO; its only caller is USART_Init (ble/usart.s), so the USART2 BRR is computed from the measured clock.  Any
@ failure (status 2..6) leaves MSITRIM as found and the nominal frequency in use: the meter then works as before.
@
@ Runs: sys_system_init right after sys_clock_select(0): at power-on and at every wake from STOP.  Interrupts are
@ masked during the measurement (PRIMASK saved and restored); TIM11's interrupt is never enabled (DIER stays 0).
@ Nothing is written to the EEPROM or the flash.
@
@ Diagnosis: ck_hz0, ck_hz, ck_trim, ck_status, ck_steps (page Ld STATUS 49 .. 54, ble/bft.s; 55 is USART2_BRR) and the
@ frame FA answered to the key code 0x96 (ck_send, ble/commands.s), which also carries MSICAL (RCC_ICSCR 23:16) as left
@ by ck_run and at the time of the answer: RM0038 6.3.2 says MSICAL is the factory value plus MSITRIM, and every
@ sys_clock_select(0) rewrites ICSCR (fn_0801FDCA); the two values show on a meter whether that rewrite moves MSICAL.
@
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "config.inc"

    .equ CK_NOM_HZ,     4194304             @ MSI range 6 nominal: 32768 * 2^7 (RM0038 6.2.3)
    .equ CK_RANGE_HZ,   251658              @ 6 % of CK_NOM_HZ: beyond this a result is not used (DS Table 32: 0.5 + 3 %
                                            @ + supply drift, with margin)
    .equ CK_DEAD_HZ,    2097                @ 0.05 %: no trim walk below this error
    .equ CK_STEPS_MAX,  24                  @ measurements of one run at most (24 x 8.2 ms + 32.8 ms)
    .equ CK_TRIM_MAX,   64                  @ |MSITRIM| bound of the walk
    .equ CK_POLLS,      1024                @ SR polls per capture (a capture every 32 us = about 134 MSI clocks; a poll
                                            @ is 4 instructions): bound for a missing HSE_RTC signal
    .equ CK_TRIES,      3                   @ attempts of one measurement when a capture was lost (CC1OF)
    .equ CK_N_SHORT,    256                 @ captures of a walk measurement (8.192 ms, 1 count = 29 ppm)
    .equ CK_N_LONG,     1024                @ captures of the final measurement (32.768 ms, 1 count = 7 ppm)
    .equ CK_SUM_MAX,    274877              @ sum * 15625 must stay below 2^32 (2^32 / 15625 = 274877.9)
    .equ CK_FRAME_LEN,  20                  @ frame FA
    .equ CK_MARK,       0xFA                @ first byte of the frame

    .section .bss_port.msical, "aw", %nobits
    .balign 4
@ The order is the order of the page Ld STATUS values 49 .. 54 (halfwords) and of the frame FA.
    .global ck_hz0
ck_hz0:         .space 4                    @ MSI Hz measured with the trim as found (0: not measured)
    .global ck_hz
ck_hz:          .space 4                    @ MSI Hz in use after the run (0: not measured)
    .global ck_trim
ck_trim:        .space 1                    @ MSITRIM after the run (two's complement view)
    .global ck_status
ck_status:      .space 1                    @ CK_ST_* (macros.inc)
    .global ck_steps
ck_steps:       .space 2                    @ measurements of the last run
ck_frame:       .space CK_FRAME_LEN         @ the frame FA being queued
ck_cal:         .space 1                    @ MSICAL (RCC_ICSCR 23:16) at the end of ck_run

    .section .text.sys.msical, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ck_capture - one measurement: n captures of HSE_RTC / 8 on TIM11, counted in MSI clocks
@ In       : r0 = n (CK_N_SHORT or CK_N_LONG); HSE running, RTCPRE = 11, SYSCLK = MSI, interrupts masked
@ Out      : r0 = MSI frequency in Hz (rounded), 0 when no capture came within CK_POLLS polls, every one of CK_TRIES
@            attempts lost a capture (CC1OF), or the sum is out of the arithmetic range
@ Clobbers : r1-r3, r12, flags (r4-r7 saved)
@ Context  : main, interrupts masked (ck_run)
@ Spec     : RM0038 18.3.5 (input capture), 18.5.4 (CC1IF cleared by reading CCR1, CC1OF), 18.5.6, 18.5.7, 18.5.13
@ -----------------------------------------------------------------------------
LFUNC ck_capture
    push {r4, r5, r6, r7, lr}
    mov r7, r0                              @ n
    movs r6, #CK_TRIES
.Lcc_try:
    ldr r1, =TIM11_BASE
    movs r0, #0
    strh r0, [r1, #TIM_CR1]                 @ counter stopped
    strh r0, [r1, #TIM_CCER]                @ CC1E = 0: CC1S writable, capture prescaler reset (18.5.6 note)
    movs r0, #TIM11_OR_HSE_RTC
    strh r0, [r1, #TIM11_OR]                @ TI1 = HSE_RTC
    movs r0, #0
    strh r0, [r1, #TIM_PSC]                 @ one count per MSI clock
    movw r0, #0xFFFF
    strh r0, [r1, #TIM_ARR]                 @ free-running 16-bit counter
    movs r0, #TIM_CCMR1_IC1_PSC8
    strh r0, [r1, #TIM_CCMR1]               @ IC1 on TI1, every 8th rising edge, no filter
    movs r0, #TIM_EGR_UG
    strh r0, [r1, #TIM_EGR]                 @ load PSC
    movs r0, #0
    strh r0, [r1, #TIM_SR]                  @ clear UIF of the UG, CC1IF, CC1OF
    movs r0, #TIM_CCER_CC1E
    strh r0, [r1, #TIM_CCER]                @ capture on
    movs r0, #TIM_CR1_CEN
    strh r0, [r1, #TIM_CR1]                 @ count
    @ r1 = TIM11, r2 = previous capture, r3 = scratch, r4 = sum, r5 = poll bound, r12 = captures left
    mov r12, r7
    movs r4, #0
    mov r5, #CK_POLLS                       @ the first capture only sets the start
1:  ldrh r3, [r1, #TIM_SR]
    tst r3, #TIM_SR_CC1IF
    bne 2f
    subs r5, r5, #1
    bne 1b
    b .Lcc_none
2:  ldrh r2, [r1, #TIM_CCR1]                @ start; reading CCR1 clears CC1IF
3:  mov r5, #CK_POLLS
4:  ldrh r3, [r1, #TIM_SR]
    tst r3, #TIM_SR_CC1IF
    bne 5f
    subs r5, r5, #1
    bne 4b
    b .Lcc_none
5:  ldrh r3, [r1, #TIM_CCR1]
    subs r0, r3, r2                         @ counts since the previous capture, modulo 2^16
    uxth r0, r0
    adds r4, r4, r0
    mov r2, r3
    subs r12, r12, #1
    bne 3b
    ldrh r3, [r1, #TIM_SR]
    tst r3, #TIM_SR_CC1OF                   @ a capture overwritten before it was read: the count is short
    beq .Lcc_sum
    subs r6, r6, #1
    bne .Lcc_try
.Lcc_none:
    movs r0, #0
    b .Lcc_stop
.Lcc_sum:
    ldr r0, =CK_SUM_MAX
    cmp r4, r0
    bhi .Lcc_none                           @ cannot be a 4 MHz clock; keeps the product below 2^32
    ldr r0, =15625
    mul r0, r4, r0                          @ sum * 15625
    lsrs r1, r7, #1                         @ divisor n / 2 (128 or 512)
    add r0, r0, r1, lsr #1                  @ + divisor / 2: rounded
    udiv r0, r0, r1
.Lcc_stop:
    ldr r1, =TIM11_BASE
    movs r2, #0
    strh r2, [r1, #TIM_CR1]
    strh r2, [r1, #TIM_CCER]
    pop {r4, r5, r6, r7, pc}
ENDFUNC ck_capture

@ -----------------------------------------------------------------------------
@ ck_err - |f - CK_NOM_HZ|
@ In       : r0 = f
@ Out      : r0 = absolute error in Hz
@ Clobbers : r1, flags
@ -----------------------------------------------------------------------------
LFUNC ck_err
    ldr r1, =CK_NOM_HZ
    subs r0, r0, r1
    it mi
    negmi r0, r0
    bx lr
ENDFUNC ck_err

@ -----------------------------------------------------------------------------
@ ck_run - measure MSI against HSE, trim it, publish ck_hz (DESIGN.md 10 IMP-46)
@ In       : SYSCLK = MSI range 6 (sys_clock_select(0) just ran), HSE off
@ Out      : ck_hz0, ck_hz, ck_trim, ck_status, ck_steps written; MSITRIM possibly changed; HSE off, TIM11 clock off,
@            TIM11_OR 0, RTCPRE = 11
@ Clobbers : r0-r3, flags (r4-r11 saved)
@ Context  : main (sys_system_init: power-on and STOP wake, before rcc_lsi_as_rtc_lcd_clock)
@ Spec     : RM0038 6.2.3 (MSI calibration), 6.2.14, 6.3.1 (RTCPRE, HSEON), 6.3.2 (MSITRIM), 18.5
@ -----------------------------------------------------------------------------
FUNC ck_run
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    CRIT_ENTER r11
    ldr r4, =ck_hz0
    movs r0, #0
    str r0, [r4]                            @ ck_hz0 = 0
    str r0, [r4, #4]                        @ ck_hz = 0
    strh r0, [r4, #10]                      @ ck_steps = 0
    ldr r1, =RCC_ICSCR_MSITRIM_B
    ldrsb r5, [r1]                          @ r5 = t0, the trim as found
    strb r5, [r4, #8]                       @ ck_trim = t0
    @ SYSCLK must be MSI (sys_clock_select(0) sets SW without waiting for SWS), and TIM11 must count on it: HPRE /1 and
    @ PPRE2 /1 (with PPRE2 /1 the APB2 timer clock is PCLK2, RM0038 6.2)
    ldr r1, =RCC_CFGR
    ldr r0, [r1]
    ldr r2, =(RCC_CFGR_SWS_MASK | RCC_CFGR_HPRE_MASK | RCC_CFGR_PPRE2_MASK)
    tst r0, r2
    mov r0, #CK_ST_NOTMSI                   @ mov without s: the flags of the test stay
    bne .Lcr_status
    @ HSE must be off: RTCPRE can be written only then
    ldr r1, =RCC_CR
    ldr r0, [r1]
    tst r0, #(RCC_CR_HSEON | RCC_CR_HSERDY)
    mov r0, #CK_ST_HSEON
    bne .Lcr_status
    ldr r0, [r1]
    orr r0, r0, #RCC_CR_RTCPRE_DIV16
    str r0, [r1]                            @ HSE_RTC = HSE / 16 = 250 kHz
    movs r0, #1
    bl fn_0801FD7A                          @ HSEON (HSEBYP 0)
    ldr r2, =SYS_WAIT_POLLS
    ldr r1, =RCC_CR
1:  ldr r0, [r1]
    tst r0, #RCC_CR_HSERDY
    bne 2f
    subs r2, r2, #1
    bne 1b
    movs r0, #CK_ST_NOHSE
    b .Lcr_hse_off
2:  @ HSE as the RTC clock for the measurement (see the header): backup domain writable, RTC domain reset, RTCSEL = HSE,
    @ RTCEN
    ldr r1, =PWR_CR_DBP_BB
    movs r0, #1
    str r0, [r1]
    ldr r1, =RCC_CSR_RTCRST_BB
    movs r0, #1
    str r0, [r1]
    movs r0, #0
    str r0, [r1]
    ldr r0, =(RCC_CSR_RTCSEL_HSE | RCC_CR_RTCPRE_DIV16)
    bl fn_0801FF34                          @ RTCSEL = HSE (its RTCPRE write is ignored while HSEON = 1: /16 stays)
    ldr r1, =RCC_CSR_RTCEN_BB
    movs r0, #1
    str r0, [r1]
    ldr r1, =RCC_APB2ENR
    ldr r0, [r1]
    orr r0, r0, #RCC_APB2_TIM11
    str r0, [r1]                            @ TIM11 clock on
    ldr r0, [r1]                            @ read back: the enable has reached the bus before TIM11 is written
    @ first measurement at t0
    movs r0, #CK_N_SHORT
    bl ck_capture
    ldrh r1, [r4, #10]
    adds r1, r1, #1
    strh r1, [r4, #10]
    cbnz r0, 3f
    movs r0, #CK_ST_NOCAP
    b .Lcr_tim_off
3:  str r0, [r4]                            @ ck_hz0
    mov r9, r0                              @ r9 = f0
    bl ck_err
    ldr r1, =CK_RANGE_HZ
    cmp r0, r1
    bls 4f
    movs r0, #CK_ST_RANGE
    b .Lcr_tim_off
4:  @ r5 = t0, r6 = best trim, r7 = best error, r8 = direction (+1 / -1), r9 = f0, r10 = trim being tried,
    @ [sp] = walk position (the trim of the last kept step, or t0)
    mov r6, r5
    mov r7, r0
    ldr r1, =CK_DEAD_HZ
    cmp r0, r1
    bls .Lcr_keep                           @ within 0.05 %: no walk, ck_hz = f0
    movs r8, #1                             @ first direction: +1
    push {r5}                               @ [sp] = walk position
.Lcr_step:
    ldrh r1, [r4, #10]
    cmp r1, #CK_STEPS_MAX
    bhs .Lcr_walk_end
    ldr r0, [sp]
    add r0, r0, r8                          @ next trim
    cmp r0, #CK_TRIM_MAX
    bgt .Lcr_turn
    cmn r0, #CK_TRIM_MAX
    blt .Lcr_turn
    mov r10, r0                             @ r10 = trim being tried
    ldr r1, =RCC_ICSCR_MSITRIM_B
    strb r0, [r1]                           @ MSITRIM = trial
    movs r0, #CK_N_SHORT
    bl ck_capture
    ldrh r1, [r4, #10]
    adds r1, r1, #1
    strh r1, [r4, #10]
    cbz r0, .Lcr_bad                        @ no measurement at this trim: take it back, stop
    bl ck_err
    ldr r1, =CK_RANGE_HZ
    cmp r0, r1
    bhi .Lcr_bad                            @ outside +-6 %: take it back at once, stop
    cmp r0, r7
    bhs .Lcr_turn                           @ not better
    mov r7, r0                              @ better: keep it and go on
    mov r6, r10
    str r10, [sp]
    b .Lcr_step
.Lcr_turn:                                  @ the first step up was not better: try down from t0; else stop
    cmp r8, #1
    bne .Lcr_walk_end
    cmp r6, r5
    bne .Lcr_walk_end
    mov r8, #-1
    str r5, [sp]
    b .Lcr_step
.Lcr_bad:
.Lcr_walk_end:
    pop {r0}
    ldr r1, =RCC_ICSCR_MSITRIM_B
    strb r6, [r1]                           @ MSITRIM = best trim
    cmp r6, r5
    beq .Lcr_keep                           @ no step was better: ck_hz = f0
    movs r0, #CK_N_LONG
    bl ck_capture                           @ the trimmed clock, 32.768 ms
    ldrh r1, [r4, #10]
    adds r1, r1, #1
    strh r1, [r4, #10]
    mov r10, r0                             @ r10 = f of the trimmed clock
    cbz r0, .Lcr_undo
    mov r0, r9
    bl ck_err                               @ e0 (ck_err clobbers r1 only)
    ldr r1, =CK_DEAD_HZ
    add r3, r0, r1                          @ r3 = e0 + 0.05 %
    mov r0, r10
    bl ck_err                               @ error of the trimmed clock
    cmp r0, r3
    bhi .Lcr_undo                           @ worse than before the walk (beyond 0.05 %)
    str r10, [r4, #4]                       @ ck_hz = trimmed measurement
    strb r6, [r4, #8]                       @ ck_trim
    movs r0, #CK_ST_OK
    b .Lcr_tim_off
.Lcr_undo:
    ldr r1, =RCC_ICSCR_MSITRIM_B
    strb r5, [r1]                           @ trim back to t0
    str r9, [r4, #4]                        @ ck_hz = f0
    strb r5, [r4, #8]
    movs r0, #CK_ST_UNDO
    b .Lcr_tim_off
.Lcr_keep:
    str r9, [r4, #4]                        @ ck_hz = f0 (trim t0)
    movs r0, #CK_ST_OK
.Lcr_tim_off:
    ldr r1, =TIM11_BASE
    movs r2, #0
    strh r2, [r1, #TIM_CR1]
    strh r2, [r1, #TIM_CCER]
    strh r2, [r1, #TIM11_OR]
    ldr r1, =RCC_APB2ENR
    ldr r2, [r1]
    bic r2, r2, #RCC_APB2_TIM11
    str r2, [r1]                            @ TIM11 clock off
    ldr r1, =RCC_CSR_RTCRST_BB
    movs r2, #1
    str r2, [r1]
    movs r2, #0
    str r2, [r1]                            @ RTC domain reset: no RTC clock selected (the caller selects LSI next)
.Lcr_hse_off:
    mov r6, r0                              @ status across the calls
    movs r0, #0
    bl fn_0801FD7A                          @ HSE off again (as sys_clock_select(0) left it)
    ldr r2, =SYS_WAIT_POLLS
    ldr r1, =RCC_CR
1:  ldr r0, [r1]
    tst r0, #RCC_CR_HSERDY
    beq 2f
    subs r2, r2, #1
    bne 1b
2:  mov r0, r6
.Lcr_status:
    strb r0, [r4, #9]                       @ ck_status
    ldr r1, =(RCC_ICSCR + 2)
    ldrb r1, [r1]
    ldr r2, =ck_cal
    strb r1, [r2]                           @ MSICAL now
    CRIT_EXIT r11
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC ck_run
    .ltorg

@ -----------------------------------------------------------------------------
@ ck_send - key code 0x96: queue the frame FA (the clock measurement; answered whenever asked)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main only (fn_0800C332, ble/commands.s)
@ RAM      : reads ck_hz0 .. ck_steps, USART2_BRR; writes ck_frame
@ Note     : frame FA, 20 bytes: FA, ck_hz0 u32 LE (1..4), ck_hz u32 LE (5..8), ck_trim (9), ck_status (10), ck_steps
@            u16 LE (11, 12), USART2_BRR u16 LE (13, 14), MSICAL at the end of ck_run (15), MSICAL now (16), 0 (17, 18),
@            XOR of bytes 0..18 (19).  A frame refused by a full
@            transmit queue is not repeated: the host asks again.
@ -----------------------------------------------------------------------------
FUNC ck_send
    push {r4, lr}
    ldr r4, =ck_frame
    movs r0, #CK_MARK
    strb r0, [r4]                           @ byte 0
    ldr r1, =ck_hz0
    adds r2, r4, #1
    movs r3, #12                            @ ck_hz0, ck_hz, ck_trim, ck_status, ck_steps: bytes 1 .. 12
1:  ldrb r0, [r1], #1
    strb r0, [r2], #1
    subs r3, r3, #1
    bne 1b
    ldr r1, =(USART2_BASE + USART_BRR)
    ldrh r0, [r1]
    strb r0, [r4, #13]
    lsrs r0, r0, #8
    strb r0, [r4, #14]
    ldr r1, =ck_cal
    ldrb r0, [r1]
    strb r0, [r4, #15]                      @ MSICAL at the end of ck_run
    ldr r1, =(RCC_ICSCR + 2)
    ldrb r0, [r1]
    strb r0, [r4, #16]                      @ MSICAL now
    movs r0, #0
    strb r0, [r4, #17]                      @ bytes 17, 18: 0
    strb r0, [r4, #18]
    movs r1, #0
2:  ldrb r2, [r4, r1]
    eors r0, r0, r2
    adds r1, r1, #1
    cmp r1, #(CK_FRAME_LEN - 1)
    bne 2b
    strb r0, [r4, #(CK_FRAME_LEN - 1)]      @ byte 19: XOR of bytes 0 .. 18
    mov r0, r4
    movs r1, #CK_FRAME_LEN
    bl ble_tx_queue_put
    pop {r4, pc}
ENDFUNC ck_send
    .ltorg
