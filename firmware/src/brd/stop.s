@ =============================================================================
@ stop.s - BRD: power-down of the peripherals, STOP preparation and STOP entry, PWR library routines
@
@ Replaces FUN_0801C522 (STOP preparation), power_down_peripherals 0x0801C584, FUN_0801C8EC, FUN_0801C908,
@ FUN_0801C92E, FUN_0801C9A4, FUN_0801C9AE, FUN_0801C9D8, FUN_0801CA0C, FUN_0801CA22, FUN_080207CC (STOP entry)
@ and the PWR library routines 0x080207A4, 0x080207AC, 0x080207B4, 0x08020808, 0x08020822 (v2.05).
@ Sequence: DESIGN.md 3.6, 4.3.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .rodata.brd.stop, "a", %progbits
@ HW-02: PF0..PF2 (HY3131 CK, CS, DI) analog immediately before PE9 low
brd_desc_hybus_an:
    GPIO_DESC 0x0007, GPIO_MODE_AN, GPIO_SPEED_400K, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
@ FUN_0801CA22 structures (0x0801CA2A..0x0801CA86): analog, speed 0, push-pull, no pull
brd_desc_all_an:
    GPIO_DESC 0xFFFF, GPIO_MODE_AN, GPIO_SPEED_400K, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pa_an:                             @ port A without PA13/PA14 (SWD): mask 0x9FFF (0x0801CA80)
    GPIO_DESC 0x9FFF, GPIO_MODE_AN, GPIO_SPEED_400K, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP

    .section .text.brd.stop, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0801C522 - everything before STOP: power-down, timers, regulator, clocks, pins, wake lines
@ Replaces : 0x0801C522 FUN_0801C522 (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (enter_stop_and_reinit), sys_fault_safe
@ Spec     : DESIGN.md 3.6; waits for VOSF and SWS bounded by SYS_WAIT_POLLS (v2.05 0x0801C54E, 0x0801C564)
@ -----------------------------------------------------------------------------
FUNC fn_0801C522
    push {r4, lr}
    bl power_down_peripherals               @ 0x0801C524
    bl fn_0801C92E                          @ timers off (0x0801C528)
    bl fn_0801C9A4                          @ PVD off (0x0801C52C)
    bl fn_0801C9AE                          @ ULP, minimal clocks (0x0801C530)
    bl fn_0801C9D8                          @ SysTick off, CWUF (0x0801C534)
    bl fn_0801FD1C                          @ RCC to reset configuration (0x0801C538)
    movs r1, #1
    mov r0, #RCC_APB1_PWR
    bl fn_0801FFBC                          @ PWR clock on (0x0801C542)
    mov r0, #PWR_CR_VOS_RANGE3
    bl fn_080207B4                          @ voltage range 3 (0x0801C54A)
    ldr r4, =SYS_WAIT_POLLS
.Lc522_vos:                                 @ wait VOSF clear (0x0801C54E)
    movs r0, #PWR_CSR_VOSF
    bl fn_08020808
    cbz r0, .Lc522_vos_ok
    subs r4, r4, #1
    bne .Lc522_vos
.Lc522_vos_ok:
    movs r0, #RCC_ICSCR_MSIRANGE_0
    bl fn_0801FDCA                          @ MSI 65.536 kHz (0x0801C55A)
    movs r0, #RCC_CFGR_SW_MSI
    bl fn_0801FE06                          @ SW = MSI (0x0801C560)
    ldr r4, =SYS_WAIT_POLLS
.Lc522_sws:                                 @ wait SWS = MSI (0x0801C564)
    bl fn_0801FE1E
    cbz r0, .Lc522_sws_ok
    subs r4, r4, #1
    bne .Lc522_sws
.Lc522_sws_ok:
    movs r1, #0
    mov r0, #RTC_IT_WUT
    bl fn_080209A8                          @ RTC wake-up interrupt off (0x0801C572)
    bl fn_0801CA0C                          @ HSI, HSE, LSE off (0x0801C576)
    bl fn_0801CA22                          @ every pin analog except PA13/PA14 (0x0801C57A)
    bl fn_0801C61C                          @ dial and key lines as wake-up interrupts (0x0801C57E)
    pop {r4, pc}
ENDFUNC fn_0801C522

@ -----------------------------------------------------------------------------
@ power_down_peripherals - outputs to their power-down levels, LCD, USART2 and ADC off, PE9 low
@ Replaces : 0x0801C584 power_down_peripherals (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main, sys_fault_safe
@ Spec     : DESIGN.md 3.6, 4.3 (STOP row)
@ Deviation: HW-02 (PF0..PF2 analog immediately before PE9 low)
@ -----------------------------------------------------------------------------
FUNC power_down_peripherals
    push {r4, lr}
    GPIO_CLR GPIOE_BASE, 0x0080             @ PE7 buzzer low (0x0801C58C)
    GPIO_CLR GPIOE_BASE, 0x0100             @ PE8 backlight low (0x0801C596)
    bl fn_0801C908                          @ LCD blank and off (0x0801C598)
    GPIO_SET GPIOB_BASE, 0x0040             @ PB6 high (0x0801C5A2)
    GPIO_SET GPIOB_BASE, 0x0080             @ PB7 high = released, open-drain (HW-01) (0x0801C5AA)
    GPIO_CLR GPIOB_BASE, 0x0040             @ PB6 low (0x0801C5B2)
    bl fn_0801C8EC                          @ HY3131 bus idle levels (0x0801C5B4)
    movs r0, #0x64
    bl fn_0800FC60                          @ PD0, PF4, PF5, PC11, PD7 default levels (0x0801C5BA)
    GPIO_CLR GPIOE_BASE, 0x1000             @ PE12 low (0x0801C5C6)
    GPIO_CLR GPIOE_BASE, 0x2000             @ PE13 low (0x0801C5D0)
    GPIO_CLR GPIOE_BASE, 0x0020             @ PE5 low (0x0801C5D8)
    GPIO_CLR GPIOA_BASE, 0x0800             @ PA11 low (0x0801C5E2)
    GPIO_CLR GPIOA_BASE, 0x1000             @ PA12 low (0x0801C5EC)
    GPIO_CLR GPIOH_BASE, 0x0004             @ PH2 low (0x0801C5F4)
    GPIO_CLR GPIOE_BASE, 0x8000             @ PE15 low (0x0801C5FE)
    GPIO_CLR GPIOF_BASE, 0x0040             @ PF6 low (0x0801C606)
    bl usart2_deinit_pf15_low               @ BLE off, PF15 low (0x0801C608)
    bl fn_0801C97E                          @ ADC off (0x0801C60C)
    ldr r1, =brd_desc_hybus_an
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ HW-02: HY3131 bus high impedance before its supply goes
    GPIO_CLR GPIOE_BASE, 0x0200             @ PE9 (PWR_CTL) low (0x0801C618)
    pop {r4, pc}
ENDFUNC power_down_peripherals

@ -----------------------------------------------------------------------------
@ fn_0801C8EC - HY3131 bus idle levels: PF1 (CS) high, PF2 (DI) high, PF0 (CK) low
@ Replaces : 0x0801C8EC FUN_0801C8EC (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main, sys_fault_safe (power-down)
@ -----------------------------------------------------------------------------
LFUNC fn_0801C8EC
    GPIO_SET GPIOF_BASE, 0x0002             @ 0x0801C8F0
    GPIO_SET GPIOF_BASE, 0x0004             @ 0x0801C8F6
    GPIO_CLR GPIOF_BASE, 0x0001             @ 0x0801C8FC
    bx lr
ENDFUNC fn_0801C8EC

@ -----------------------------------------------------------------------------
@ fn_0801C908 - LCD blank, commit, controller off, wait for ENS clear, LCD clock off
@ Replaces : 0x0801C908 FUN_0801C908 (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Deviation: HW-07 (the ENS wait is bounded by LCD_WAIT_POLLS; v2.05 waits without bound at 0x0801C918)
@ -----------------------------------------------------------------------------
LFUNC fn_0801C908
    push {r4, lr}
    bl fn_0801A81C                          @ LCD shadow cleared (LCD) (0x0801C90A)
    bl lcd_commit_shadow                    @ (LCD) (0x0801C90E)
    movs r0, #0
    bl fn_080203FA                          @ LCDEN = 0 (LCD) (0x0801C914)
    ldr r4, =LCD_WAIT_POLLS
.Lc908_ens:
    movs r0, #LCD_SR_ENS
    bl fn_08020492                          @ LCD_GetFlagStatus(ENS) (LCD) (0x0801C91A)
    cmp r0, #1
    bne .Lc908_off
    subs r4, r4, #1
    bne .Lc908_ens
.Lc908_off:
    movs r1, #0
    mov r0, #RCC_APB1_LCD
    bl fn_0801FFBC                          @ LCD clock off (0x0801C928)
    pop {r4, pc}
ENDFUNC fn_0801C908

@ -----------------------------------------------------------------------------
@ fn_0801C92E - TIM2 and TIM3 off, their clocks off
@ Replaces : 0x0801C92E FUN_0801C92E (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (calls other routines)
@ Context  : main, sys_fault_safe (STOP preparation)
@ Deviation: OF-73: v2.05 stops the timers and gates their clocks with DIER.UIE and SR.UIF as they are.  An update
@            flag left set keeps the timer's interrupt request asserted; after the wake sys_nvic_init enables IRQ28 /
@            IRQ29 with interrupts unmasked, the handler's SR write is ignored while the timer's clock is off, and the
@            handler is entered again for ever (the meter beeps the wake marker, then stays dark; on a meter
@            2026-11-07, TIM3 in the emulator).  Here DIER and SR are cleared first, while the clocks still run;
@            sys_tim2_init / sys_tim3_init set them again after the wake.
@ -----------------------------------------------------------------------------
LFUNC fn_0801C92E
    push {r3, lr}
    movs r0, #0
    ldr r1, =TIM2_BASE
    strh r0, [r1, #TIM_DIER]                @ OF-73: no update interrupt request left behind
    strh r0, [r1, #TIM_SR]
    ldr r1, =TIM3_BASE
    strh r0, [r1, #TIM_DIER]
    strh r0, [r1, #TIM_SR]
    movs r1, #0
    mov r0, #TIM2_BASE
    bl fn_0802096C                          @ 0x0801C936
    movs r1, #0
    movs r0, #RCC_APB1_TIM2
    bl fn_0801FFBC                          @ 0x0801C93E
    movs r1, #0
    ldr r0, =TIM3_BASE
    bl fn_0802096C                          @ 0x0801C946
    movs r1, #0
    movs r0, #RCC_APB1_TIM3
    bl fn_0801FFBC                          @ 0x0801C94E
    pop {r3, pc}
ENDFUNC fn_0801C92E

@ -----------------------------------------------------------------------------
@ fn_0801C9A4 - PVD off
@ Replaces : 0x0801C9A4 FUN_0801C9A4 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (calls other routines)
@ Context  : main, sys_fault_safe (STOP preparation)
@ -----------------------------------------------------------------------------
LFUNC fn_0801C9A4
    movs r0, #0
    b fn_080207A4                           @ tail call (0x0801C9A8)
ENDFUNC fn_0801C9A4

@ -----------------------------------------------------------------------------
@ fn_0801C9AE - ultra-low-power mode on, only GPIOA/GPIOC and PWR clocks left on
@ Replaces : 0x0801C9AE FUN_0801C9AE (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (calls other routines)
@ Context  : main, sys_fault_safe (STOP preparation)
@ Spec     : RM0038 5.4.1 (ULP), 6.3.8..6.3.11
@ -----------------------------------------------------------------------------
LFUNC fn_0801C9AE
    push {r3, lr}
    movs r0, #1
    bl fn_080207AC                          @ ULP = 1 (0x0801C9B2)
    movs r0, #(RCC_AHBENR_GPIOAEN | RCC_AHBENR_GPIOCEN)
    ldr r1, =RCC_AHBENR
    str r0, [r1]                            @ AHBENR = 5 (0x0801C9BA)
    ldr r1, =RCC_AHBLPENR
    str r0, [r1]                            @ AHBLPENR = 5 (0x0801C9C0)
    mov r0, #RCC_APB1_PWR
    ldr r1, =RCC_APB1ENR
    str r0, [r1]                            @ APB1ENR = PWR only (0x0801C9C8)
    movs r0, #0
    ldr r1, =RCC_APB2ENR
    str r0, [r1]                            @ APB2ENR = 0 (0x0801C9CE)
    pop {r3, pc}
ENDFUNC fn_0801C9AE

@ -----------------------------------------------------------------------------
@ fn_0801C9D8 - SysTick off and its interrupt off, wake-up flag cleared
@ Replaces : 0x0801C9D8 FUN_0801C9D8 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (calls other routines)
@ Context  : main, sys_fault_safe (STOP preparation)
@ -----------------------------------------------------------------------------
LFUNC fn_0801C9D8
    push {r3, lr}
    movs r0, #0
    ldr r1, =STK_CTRL
    str r0, [r1]                            @ 0x0801C9DE
    ldr r0, [r1]
    bic r0, r0, #STK_CTRL_TICKINT
    str r0, [r1]                            @ 0x0801C9EA
    movs r0, #1
    bl fn_08020822                          @ PWR_CR |= CWUF (0x0801C9EE)
    pop {r3, pc}
ENDFUNC fn_0801C9D8

@ -----------------------------------------------------------------------------
@ fn_0801CA0C - HSI, HSE and LSE off
@ Replaces : 0x0801CA0C FUN_0801CA0C (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (calls other routines)
@ Context  : main, sys_fault_safe (STOP preparation)
@ -----------------------------------------------------------------------------
LFUNC fn_0801CA0C
    push {r3, lr}
    movs r0, #0
    bl fn_0801FDE2                          @ HSI off (0x0801CA10)
    movs r0, #0
    bl fn_0801FD7A                          @ HSE off (0x0801CA16)
    movs r0, #0
    bl rcc_lse_config                       @ LSE off (0x0801CA1C)
    pop {r3, pc}
ENDFUNC fn_0801CA0C

@ -----------------------------------------------------------------------------
@ fn_0801CA22 - every pin analog (port A except PA13/PA14), GPIO clocks off
@ Replaces : 0x0801CA22 FUN_0801CA22 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main, sys_fault_safe (STOP preparation)
@ Spec     : DESIGN.md 4.2 (PA13/PA14 never reconfigured)
@ -----------------------------------------------------------------------------
FUNC fn_0801CA22
    push {r4, lr}
    bl fn_0801BFC6                          @ GPIO clocks on (0x0801CA26)
    ldr r4, =brd_desc_all_an
    mov r1, r4
    ldr r0, =GPIOB_BASE
    bl brd_gpio_init                        @ 0x0801CA4C
    mov r1, r4
    ldr r0, =GPIOC_BASE
    bl brd_gpio_init                        @ 0x0801CA54
    mov r1, r4
    ldr r0, =GPIOG_BASE
    bl brd_gpio_init                        @ 0x0801CA5C
    mov r1, r4
    ldr r0, =GPIOH_BASE
    bl brd_gpio_init                        @ 0x0801CA64
    mov r1, r4
    ldr r0, =GPIOD_BASE
    bl brd_gpio_init                        @ 0x0801CA6C
    mov r1, r4
    ldr r0, =GPIOE_BASE
    bl brd_gpio_init                        @ 0x0801CA74
    mov r1, r4
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ 0x0801CA7C
    ldr r1, =brd_desc_pa_an
    ldr r0, =GPIOA_BASE
    bl brd_gpio_init                        @ 0x0801CA8A
    bl fn_0801BFD2                          @ GPIO clocks off (0x0801CA8E)
    pop {r4, pc}
ENDFUNC fn_0801CA22

@ -----------------------------------------------------------------------------
@ fn_080207CC - enter STOP and stay there until an armed EXTI line is pending (race-free)
@ Replaces : 0x080207CC FUN_080207CC (v2.05: PWR_CR LPSDSR/PDDS = r0, SLEEPDEEP, one WFI (r1 = 1) or WFE)
@ In       : r0 = PWR_CR bits 1:0 (1 = low-power regulator in STOP), r1 = 1 WFI, otherwise WFE
@ Out      : - (returns with SYSCLK = MSI, RM0038 5.3.7 "Exiting the Stop mode"; the caller's PRIMASK restored,
@            so the pending EXTI interrupt is taken right after the return if the caller had interrupts on)
@ Clobbers : r0-r3, r12, flags
@ Context  : main, sys_fault_safe
@ Spec     : DESIGN.md 3.6 NF-05; RM0038 5.3.7 Table 32, 10.2.3 (WFE wake-up by a pending interrupt with
@            SEVONPEND); PM0056 2.5.2 ("if the SEVONPEND bit in the SCR is set to 1, any new pending interrupt
@            triggers an event and wakes up the processor, even if the interrupt is disabled or has insufficient
@            priority to cause exception entry")
@ Deviation: NF-05: v2.05 executes a single WFE (0x080207F6) and returns on any event.  Here, with PRIMASK set
@            and SEVONPEND = 1, the loop re-enters STOP until (EXTI_PR & EXTI_IMR) != 0; an edge between the test
@            and the WFE sets the event register, so the WFE returns at once and the test sees it.
@ -----------------------------------------------------------------------------
FUNC fn_080207CC
    push {r4, r5, r6, lr}
    uxtb r5, r1                             @ r5 = entry instruction selector (v2.05 uxtb r1 at 0x080207EC)
    ldr r3, =PWR_CR
    ldr r2, [r3]
    bic r2, r2, #(PWR_CR_LPSDSR | PWR_CR_PDDS) @ v2.05 lsrs/lsls #2 (0x080207D6)
    orrs r2, r2, r0
    str r2, [r3]                            @ 0x080207DE
    CRIT_ENTER r4                           @ r4 = caller's PRIMASK
    ldr r3, =SCB_SCR
    ldr r2, [r3]
    orr r2, r2, #(SCB_SCR_SLEEPDEEP | SCB_SCR_SEVONPEND)
    str r2, [r3]                            @ SLEEPDEEP as v2.05 0x080207EA, SEVONPEND added (NF-05)
    ldr r6, =EXTI_IMR
.L207cc_loop:
    ldr r0, [r6]                            @ EXTI_IMR: the armed lines
    ldr r1, [r6, #(EXTI_PR - EXTI_IMR)]     @ EXTI_PR
    tst r0, r1
    bne .L207cc_woken                       @ an armed line is pending: leave STOP
    cmp r5, #1
    bne .L207cc_wfe
    wfi                                     @ entry by WFI (v2.05 0x080207F2)
    b .L207cc_loop
.L207cc_wfe:
    wfe                                     @ entry by WFE (v2.05 0x080207F6)
    b .L207cc_loop
.L207cc_woken:
    ldr r3, =SCB_SCR
    ldr r2, [r3]
    bic r2, r2, #(SCB_SCR_SLEEPDEEP | SCB_SCR_SEVONPEND)
    str r2, [r3]                            @ SLEEPDEEP cleared as v2.05 0x08020802
    CRIT_EXIT r4
    isb                                     @ a pending EXTI interrupt is taken here when PRIMASK was 0
    pop {r4, r5, r6, pc}
ENDFUNC fn_080207CC

@ =============================================================================
@ PWR library routines (v2.05 StdPeriph code, same register effects)
@ =============================================================================

@ -----------------------------------------------------------------------------
@ fn_080207A4 - PVD on/off (PWR_PVDCmd), bit-band PWR_CR PVDE
@ Replaces : 0x080207A4 (v2.05)
@ In       : r0 = 0/1
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main (STOP preparation)
@ -----------------------------------------------------------------------------
LFUNC fn_080207A4
    uxtb r0, r0
    ldr r1, =PWR_CR_PVDE_BB
    str r0, [r1]
    bx lr
ENDFUNC fn_080207A4

@ -----------------------------------------------------------------------------
@ fn_080207AC - ultra-low-power mode on/off (PWR_UltraLowPowerCmd), bit-band PWR_CR ULP
@ Replaces : 0x080207AC (v2.05)
@ In       : r0 = 0/1
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main (STOP preparation)
@ -----------------------------------------------------------------------------
LFUNC fn_080207AC
    uxtb r0, r0
    ldr r1, =PWR_CR_ULP_BB
    str r0, [r1]
    bx lr
ENDFUNC fn_080207AC

@ -----------------------------------------------------------------------------
@ fn_080207B4 - voltage range (PWR_VoltageScalingConfig)
@ Replaces : 0x080207B4 (v2.05), called by SYS
@ In       : r0 = VOS field value (bits 12:11)
@ Out      : -
@ Clobbers : r1-r3
@ Context  : main
@ Spec     : RM0038 5.4.1 (the write-1 bits CWUF/CSBF are written 0)
@ -----------------------------------------------------------------------------
FUNC fn_080207B4
    ldr r3, =PWR_CR
    ldr r2, [r3]
    bic r1, r2, #PWR_CR_VOS_MASK
    orrs r1, r1, r0
    bic r2, r1, #(PWR_CR_CWUF | PWR_CR_CSBF) @ v2.05 bics r2,r1,#0xc (0x080207C2)
    str r2, [r3]
    bx lr
ENDFUNC fn_080207B4

@ -----------------------------------------------------------------------------
@ fn_08020808 - PWR_CSR flag status (PWR_GetFlagStatus)
@ Replaces : 0x08020808 (v2.05), called by SYS
@ In       : r0 = flag mask
@ Out      : r0 = 1 set, 0 clear
@ Clobbers : r1, r2
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_08020808
    ldr r2, =PWR_CSR
    ldr r2, [r2]
    tst r2, r0
    ite ne                                  @ result from the flag test
    movne r0, #1                            @ set
    moveq r0, #0                            @ clear
    bx lr
ENDFUNC fn_08020808

@ -----------------------------------------------------------------------------
@ fn_08020822 - clear PWR flags (PWR_ClearFlag): PWR_CR |= r0 << 2 (CWUF, CSBF)
@ Replaces : 0x08020822 (v2.05), called by SYS
@ In       : r0 = flag mask (1 WUF, 2 SBF)
@ Out      : -
@ Clobbers : r1, r2
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_08020822
    ldr r2, =PWR_CR
    ldr r1, [r2]
    orr r1, r1, r0, lsl #2
    str r1, [r2]
    bx lr
ENDFUNC fn_08020822

    .ltorg
