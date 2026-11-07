@ =============================================================================
@ poweroff.s - PWR: APO power-off into STOP and re-initialisation after the wake-up
@
@ Replaces enter_stop_and_reinit 0x08024ECA (v2.05).  Sequence: DESIGN.md 3.6.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ PWR_EXTI_PG_LINES, 0x0000FFFF      @ EXTI lines 0..15 armed by fn_0801C61C
    @ NVIC bits of the EXTI IRQs armed by fn_0801C61C: IRQ6..10, IRQ23 in ICER0/ICPR0, IRQ40 in ICER1/ICPR1
    .equ PWR_EXTI_NVIC0, ((1 << IRQ_EXTI0) | (1 << IRQ_EXTI1) | (1 << IRQ_EXTI2) | (1 << IRQ_EXTI3) | (1 << IRQ_EXTI4) | (1 << IRQ_EXTI9_5))
    .equ PWR_EXTI_NVIC1, (1 << (IRQ_EXTI15_10 - 32))
    .equ PWR_TIMER_NVIC0, ((1 << IRQ_TIM2) | (1 << IRQ_TIM3))

    .section .bss_port.pwroff, "aw", %nobits
@ pwr_ble_was_on: 0x2000802B (Bluetooth on) at the power-off, read after the wake (IMP-48; owner PWR)
pwr_ble_was_on: .space 1

    .section .text.pwr.poweroff, "ax", %progbits

@ -----------------------------------------------------------------------------
@ enter_stop_and_reinit - "-oFF-" with a 1 s beep, power down, STOP, then the full start-up again
@ Replaces : 0x08024ECA enter_stop_and_reinit (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (loop step 14, request 0x2000803A)
@ RAM      : writes 0x2000803A = 0, 0x2000802B = 0, 0x20008038 = 1 (woken from STOP), pwr_ble_was_on (IMP-48)
@ Spec     : DESIGN.md 3.6
@ Deviation: HW-08 (TIM2/TIM3 update interrupts off and buzzer silenced before the power-down; v2.05 stops the
@            timers only at 0x0801C92E, after power_down_peripherals cleared PE7 at 0x0801C58C), NF-05 (in
@            fn_080207CC), NF-06 (EXTI lines and their NVIC enables off after the wake-up; v2.05 leaves them on),
@            IMP-06 (production: the 1 s beep as a state machine stepped with WFI between the steps; PWR_CR LPSDSR
@            cleared after the wake so the production WFI sleep is the normal Sleep mode), IMP-48 (Bluetooth on again
@            after the wake when it was on before the power-off; v2.05 leaves it off)
@ -----------------------------------------------------------------------------
FUNC enter_stop_and_reinit
    push {r4, lr}
    @ "-oFF-" and the 1 s beep (v2.05 pe7_on_blocking_100_ticks 0x08024ECC)
    bl bzb_off_beep_start
.Lesr_beep:
    bl lcd_commit_retry                     @ IMP-06: fn_08017092 commits twice in a row, so the "-oFF-" commit finds UDR still set and
                                            @ is deferred; this loop never reaches fn_08016D34, so it repeats the commit itself
                                            @ (W3_to_W1.md item 8); without this call the screen stays blank during the beep
    wfi                                     @ IMP-06: sleep until the next interrupt (TIM2 sets the 10 ms flag)
    bl bzb_off_beep_step                    @ r0 = 1 after 100 ticks, PE7 low again
    cmp r0, #0
    beq .Lesr_beep
    ldr r1, =v_2000802B
    ldrb r0, [r1]
    ldr r1, =pwr_ble_was_on
    strb r0, [r1]                           @ IMP-48: Bluetooth state before the power-off, for the wake
    movs r0, #0
    ldr r1, =v_2000803A
    strb r0, [r1]                           @ power-off request consumed (0x08024ED4)
    ldr r1, =v_2000802B
    strb r0, [r1]                           @ BLE off (0x08024EDA)
    @ HW-08: no timer interrupt may raise PE7 again after this point
    ldr r1, =NVIC_ICER0
    ldr r0, =PWR_TIMER_NVIC0
    str r0, [r1]                            @ IRQ28 (TIM2), IRQ29 (TIM3) disabled
    dsb                                     @ the disable takes effect before the buzzer state is cleared
    isb
    bl bzb_silence                          @ buzzer state cleared, PE7 low
    bl fn_0801C522                          @ STOP preparation (0x08024EDC)
    movs r1, #2
    movs r0, #1
    bl fn_080207CC                          @ STOP, low-power regulator, WFE (0x08024EE4); returns after an armed
                                            @ EXTI line; its handler brd_exti_isr has cleared the pending bit
    @ NF-06: the wake-up lines are disarmed
    ldr r1, =EXTI_IMR
    ldr r0, [r1]
    bfc r0, #0, #16                         @ clear bits 15:0 (PWR_EXTI_PG_LINES)
    str r0, [r1]                            @ EXTI lines 0..15 masked
    ldr r1, =NVIC_ICER0
    ldr r0, =PWR_EXTI_NVIC0
    str r0, [r1]                            @ IRQ6..10, IRQ23 disabled
    ldr r1, =NVIC_ICPR0
    str r0, [r1]                            @ and their pending bits cleared
    ldr r1, =(NVIC_ICER0 + 4)
    mov r0, #PWR_EXTI_NVIC1
    str r0, [r1]                            @ IRQ40 disabled
    ldr r1, =(NVIC_ICPR0 + 4)
    str r0, [r1]                            @ and its pending bit cleared
    ldr r1, =EXTI_PR
    ldr r0, =PWR_EXTI_PG_LINES
    str r0, [r1]                            @ any edge that came after the handler ran is cleared
    @ IMP-06: the production loop sleeps with WFI.  fn_080207CC left PWR_CR LPSDSR = 1 (regulator in low-power mode
    @ during sleep, as v2.05 0x08024EE0..0x08024EE4); Low-power sleep needs VCORE range 2 and at most f_MSI range 1
    @ (RM0038 5.3.6), while the port runs range 1 at 4.194 MHz after the wake, so LPSDSR is cleared here and the
    @ sleep is the normal Sleep mode.  v2.05 never sleeps after the wake, so it never depends on this bit.
    ldr r1, =PWR_CR
    ldr r0, [r1]
    bic r0, r0, #PWR_CR_LPSDSR
    str r0, [r1]
    movs r0, #1
    ldr r1, =v_20008038
    strb r0, [r1]                           @ woken from STOP (0x08024EEC)
    bl sys_system_init                      @ FUN_0801BE76 (0x08024EEE), timers and IRQ28/29 enabled again
    bl set_state_reset                      @ FUN_08024DE0 (0x08024EF2)
                                            @ (the calibration cache is loaded by bootwin_start, DESIGN.md 3.2 step 5, 6.20)
    movs r1, #1
    ldr r0, =lcd_contrast
    ldrb r0, [r0]
    bl lcd_init                             @ 0x08024EFC
    bl sys_bootwin_begin                    @ power-on window (FUN_0800EA3A at 0x08024F00)
    ldr r1, =pwr_ble_was_on                 @ IMP-48: Bluetooth was on before the power-off: on again, as a long PEAK
    ldrb r0, [r1]                           @ switches it on (the RAM kept its value: the MCU supply VDD_P stays on in
    cbz r0, 1f                              @ STOP; a power-up clears it with the rest of .bss_port)
    bl blcmd_ble_on
1:  pop {r4, pc}
ENDFUNC enter_stop_and_reinit

    .ltorg
