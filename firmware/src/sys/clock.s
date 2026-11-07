@ =============================================================================
@ clock.s - SYS: reset clock pre-initialisation, run/SD clock selection, LSI/RTC clock, RCC helpers
@
@ Replaces the v2.05 reset_preinit 0x08025F70, SetSysClock 0x08025FC2, FUN_0801BF1A, rcc_lsi_as_rtc_lcd_clock
@ 0x0801BF92 and the RCC/PWR library routines of DESIGN.md Appendix A SYS (0x0801FD1C..0x0801FFF8, 0x0802079C).
@ Clock plan: DESIGN.md 3.3.  Every hardware ready-flag wait is bounded by SYS_WAIT_POLLS polls (DESIGN.md 3.2
@ step 3); v2.05 waits without bound at 0x08026046 (VOSF), 0x0802608A (PLLRDY), 0x080260AA (SWS), 0x0801BF2A
@ (HSIRDY), 0x0801BFAC (LSIRDY) and loops forever at 0x0801BF58 (NF-02).
@ This is the only object that addresses FLASH_ACR (DESIGN.md 9.3 item 2).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ SYS_TIM_PSC_MSI, 260               @ 4 194 304 / 261 / 161 = 99.81 Hz (TIM2), / 16 = 1004.4 Hz (TIM3), as v2.05
    .equ SYS_STEP_LOOPS, 64                 @ subs + bne: at least 2 cycles each (PM0056 3.3), 128 cycles = 8 us at 16 MHz
    .equ SYS_TIM_PSC_PLL, 1990              @ 32 000 000 / 1991 / 161 = 99.83 Hz, / 16 = 1004.5 Hz (IMP-41)

    .section .text.sys.clock, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sys_clock_preinit - clock set-up at reset (SystemInit shape, then the PLL attempt)
@ Replaces : 0x08025F70 reset_preinit (v2.05), except its final VTOR = 0x08000000 (0x08025FB8..0x08025FBE):
@            sys_reset has set VTOR = 0x08006000 already and it stays (DESIGN.md 3.2 step 3)
@ In       : -
@ Out      : - (SYSCLK = PLL from HSE x12 /3 if every step succeeds, else MSI)
@ Clobbers : r0-r3, r12, flags
@ Context  : reset (interrupts masked)
@ Spec     : DESIGN.md 3.1, 3.2 step 3
@ -----------------------------------------------------------------------------
FUNC sys_clock_preinit
    push {r3, lr}
    bl fn_0801FD1C                          @ RCC to reset state: identical sequence to reset_preinit
                                            @ 0x08025F72..0x08025FB2
    bl sys_set_sysclk                       @ SetSysClock (0x08025FB4)
    pop {r3, pc}
ENDFUNC sys_clock_preinit

@ -----------------------------------------------------------------------------
@ sys_set_sysclk - start HSE and switch SYSCLK to the PLL (HSE x12 /3), bounded
@ Replaces : 0x08025FC2 SetSysClock (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : reset
@ Spec     : DESIGN.md 3.1 (sequence), 3.2 step 3 (bounds, MSI fallback); RM0038 6.3.1, 6.3.3, 3.9.1, 5.4.1
@ Note     : on a VOSF, PLLRDY or SWS timeout the sequence stops and SW is set to MSI (DESIGN.md 3.2 step 3);
@            if HSE does not start the routine returns at once as v2.05 does (0x0802600C), SYSCLK stays MSI.
@ -----------------------------------------------------------------------------
LFUNC sys_set_sysclk
    @ r1 = RCC_CR address, r2 = poll counter
    ldr r1, =RCC_CR
    ldr r0, [r1]
    orr r0, r0, #RCC_CR_HSEON               @ HSEON (0x08025FD0)
    str r0, [r1]
    movs r2, #0                             @ counter [sp+4] of v2.05
.Lsss_hse_wait:
    ldr r0, [r1]
    ands r0, r0, #RCC_CR_HSERDY             @ status = HSERDY (0x08025FDC)
    add r2, r2, #1                          @ counter++ (0x08025FE4)
    bne .Lsss_hse_test                      @ ready: leave the poll loop (0x08025FEC)
    cmp r2, #SYS_WAIT_POLLS                 @ 0x5000 polls as v2.05 (0x08025FF0)
    bne .Lsss_hse_wait
.Lsss_hse_test:
    ldr r0, [r1]
    tst r0, #RCC_CR_HSERDY                  @ re-read HSERDY as v2.05 (0x08025FF6)
    beq .Lsss_done                          @ HSE did not start: stay on MSI (0x0802600C)

    @ flash: 64-bit access, prefetch, one wait state, in the v2.05 order (0x0802600E..0x08026030)
    ldr r1, =FLASH_ACR
    ldr r0, [r1]
    orr r0, r0, #FLASH_ACR_ACC64
    str r0, [r1]
    ldr r0, [r1]
    orr r0, r0, #FLASH_ACR_PRFTEN
    str r0, [r1]
    ldr r0, [r1]
    orr r0, r0, #FLASH_ACR_LATENCY
    str r0, [r1]

    @ power interface clock and voltage range 1 (0x08026032..0x08026044)
    ldr r1, =RCC_APB1ENR
    ldr r0, [r1]
    orr r0, r0, #RCC_APB1_PWR
    str r0, [r1]
    ldr r1, =PWR_CR
    mov r0, #PWR_CR_VOS_RANGE1              @ PWR_CR = 0x800 (v2.05 writes the whole register)
    str r0, [r1]
    ldr r1, =PWR_CSR
    ldr r2, =SYS_WAIT_POLLS
.Lsss_vos_wait:                             @ wait VOSF clear (v2.05 0x08026046, unbounded there)
    ldr r0, [r1]
    tst r0, #PWR_CSR_VOSF
    beq .Lsss_vos_ok
    subs r2, r2, #1
    bne .Lsss_vos_wait
    b .Lsss_fail                            @ timeout: stop, run on MSI
.Lsss_vos_ok:
    @ HCLK = SYSCLK, PCLK2 = HCLK, PCLK1 = HCLK: v2.05 rewrites RCFGR unchanged three times
    @ (0x0802604E..0x08026064, the /1 settings OR in zero)
    ldr r1, =RCC_CFGR
    ldr r0, [r1]
    str r0, [r1]
    ldr r0, [r1]
    str r0, [r1]
    ldr r0, [r1]
    str r0, [r1]
    @ PLL: source HSE, x12, /3 (0x08026066..0x0802607C)
    ldr r0, [r1]
    bic r0, r0, #RCC_CFGR_PLL_MASK
    str r0, [r1]
    ldr r0, [r1]
    orr r0, r0, #RCC_CFGR_PLL_HSE_X12_DIV3
    str r0, [r1]
    @ PLL on and wait PLLRDY (0x0802607E..0x08026090)
    ldr r1, =RCC_CR
    ldr r0, [r1]
    orr r0, r0, #RCC_CR_PLLON
    str r0, [r1]
    ldr r2, =SYS_WAIT_POLLS
.Lsss_pll_wait:
    ldr r0, [r1]
    tst r0, #RCC_CR_PLLRDY
    bne .Lsss_pll_ok
    subs r2, r2, #1
    bne .Lsss_pll_wait
    b .Lsss_fail
.Lsss_pll_ok:
    @ SW = PLL (0x08026092..0x080260A8); OF-70: v2.05 goes from MSI 2.097 MHz to 16 MHz in one step (7.6 x), RM0038
    @ 6.2.7 allows less than 4 x per step with 5 us between two changes: SW = PLL together with HCLK = SYSCLK / 2
    @ (8 MHz, 3.8 x), at least 5 us, then HPRE = /1 (16 MHz, 2 x)
    ldr r1, =RCC_CFGR
    ldr r0, [r1]
    bic r0, r0, #(RCC_CFGR_SW_MASK | RCC_CFGR_HPRE_MASK)
    orr r0, r0, #(RCC_CFGR_SW_PLL | RCC_CFGR_HPRE_DIV2)
    str r0, [r1]
    ldr r2, =SYS_WAIT_POLLS
.Lsss_sws_wait:                             @ wait SWS = PLL (0x080260AA..0x080260B4)
    ldr r0, [r1]
    and r0, r0, #RCC_CFGR_SWS_MASK
    cmp r0, #RCC_CFGR_SWS_PLL
    beq .Lsss_step
    subs r2, r2, #1
    bne .Lsss_sws_wait
.Lsss_fail:                                 @ a step timed out: select MSI and continue on it
    ldr r1, =RCC_CFGR
    ldr r0, [r1]
    bic r0, r0, #(RCC_CFGR_SW_MASK | RCC_CFGR_HPRE_MASK) @ SW = 00 = MSI, HCLK = SYSCLK
    str r0, [r1]
    bx lr
.Lsss_step:
    movs r2, #SYS_STEP_LOOPS                @ at least 2 cycles a pass at 8 MHz: 16 us
1:  subs r2, r2, #1
    bne 1b
    ldr r0, [r1]
    bic r0, r0, #RCC_CFGR_HPRE_MASK         @ HCLK = SYSCLK = 16 MHz
    str r0, [r1]
.Lsss_done:
    bx lr
ENDFUNC sys_set_sysclk

@ -----------------------------------------------------------------------------
@ sys_pll_session - IMP-41: SYSCLK = PLL from HSE x24 /3 for a card session (VCO 96 MHz, SYSCLK = HCLK = PCLK1 =
@                   PCLK2 = 32 MHz, SDIOCLK = VCO / 2 = 48 MHz)
@ In       : HSE running (HSERDY), SYSCLK = MSI
@ Out      : r0 = 1 SYSCLK = PLL, 0 a step did not complete (SYSCLK still MSI, timer prescalers unchanged)
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : RM0038 6.2 ("If the USB or SDIO interface is used ... the PLL VCO clock ... must be programmed to output a
@            96 MHz frequency", SDIOCLK = PLLVCO/2); 6.3.3 PLLMUL 0110 = x24, "can be written only when the PLL is
@            disabled", VCO at most 96 MHz in Range 1; 3.3.2 / Table 13: 32 MHz needs Range 1, 64-bit access and one
@            wait state, set before the frequency is raised.  v2.05 ran every card session on HSE 4 MHz (SYSCLK 4 MHz,
@            SDIOCLK 24 MHz from a 48 MHz VCO): at that clock the DMA stopped feeding the SDIO after a few words (GitHub
@            issue 5: TXUNDERR on a meter).  The PLL is configured here at every session, so a session does not depend
@            on the boot-time PLL setup (issue 6: the STOP preparation clears it).
@ -----------------------------------------------------------------------------
FUNC sys_pll_session
    push {r4, lr}
    ldr r0, =PWR_CR
    ldr r1, [r0]
    and r1, r1, #PWR_CR_VOS_MASK
    cmp r1, #PWR_CR_VOS_RANGE1
    bne .Lsps_fail                          @ not Range 1 (sys_system_init sets it): no 32 MHz
    ldr r0, =FLASH_ACR
    ldr r1, [r0]
    orr r1, r1, #FLASH_ACR_ACC64
    str r1, [r0]                            @ 64-bit access first (RM0038 3.3.2)
    orr r1, r1, #FLASH_ACR_LATENCY
    str r1, [r0]                            @ then one wait state
    ldr r1, [r0]
    tst r1, #FLASH_ACR_LATENCY
    beq .Lsps_fail                          @ not taken: no 32 MHz
    ldr r2, =RCC_CR
    ldr r1, [r2]
    bic r1, r1, #RCC_CR_PLLON
    str r1, [r2]                            @ PLL off: its fields can be written only then (SYSCLK is MSI here)
    ldr r4, =SYS_WAIT_POLLS
1:  ldr r1, [r2]
    tst r1, #RCC_CR_PLLRDY
    beq 2f
    subs r4, r4, #1
    bne 1b
    b .Lsps_fail
2:  ldr r3, =RCC_CFGR
    ldr r1, [r3]
    bic r1, r1, #RCC_CFGR_PLL_MASK
    orr r1, r1, #RCC_CFGR_PLL_HSE_X24_DIV3
    str r1, [r3]                            @ HSE x24 /3
    ldr r1, [r2]
    orr r1, r1, #RCC_CR_PLLON
    str r1, [r2]
    ldr r4, =SYS_WAIT_POLLS
3:  ldr r1, [r2]
    tst r1, #RCC_CR_PLLRDY
    bne 4f
    subs r4, r4, #1
    bne 3b
    b .Lsps_fail
4:  ldr r1, [r3]
    bic r1, r1, #(RCC_CFGR_HPRE_MASK | RCC_CFGR_SW_MASK)
    orr r1, r1, #(RCC_CFGR_HPRE_DIV2 | RCC_CFGR_SW_PLL)
    str r1, [r3]                            @ SW = PLL and HCLK = SYSCLK / 2 in one write: MSI 4.194 MHz -> 16 MHz -> 32 MHz,
                                            @ each step below 4 x (RM0038 6.2.7 note, datasheet Table 4 note 2: VCORE
                                            @ drop); two writes would pass through MSI / 2 = 2.1 MHz -> 16 MHz (7.6 x)
    ldr r4, =SYS_WAIT_POLLS
5:  ldr r1, [r3]
    and r1, r1, #RCC_CFGR_SWS_MASK
    cmp r1, #RCC_CFGR_SWS_PLL
    beq 6f
    subs r4, r4, #1
    bne 5b
    movs r0, #RCC_CFGR_SW_MSI
    bl fn_0801FE06                          @ the switch did not complete: back to MSI
    bl sys_hclk_div1                        @ and HCLK = SYSCLK again
    b .Lsps_fail
6:  movs r4, #SYS_STEP_LOOPS                @ at least 5 us at 16 MHz between the two changes (RM0038 6.2.7 note)
7:  subs r4, r4, #1
    bne 7b
    bl sys_hclk_div1                        @ HCLK = SYSCLK = 32 MHz
    movw r0, #SYS_TIM_PSC_PLL
    bl sys_timers_psc                       @ TIM2 / TIM3 ticks keep their length at 32 MHz
    movs r0, #1
    pop {r4, pc}
.Lsps_fail:
    movs r0, #0
    pop {r4, pc}
ENDFUNC sys_pll_session

@ sys_hclk_div1 - HPRE = /1 (HCLK = SYSCLK); clobbers r0, r1
FUNC sys_hclk_div1
    ldr r1, =RCC_CFGR
    ldr r0, [r1]
    bic r0, r0, #RCC_CFGR_HPRE_MASK
    str r0, [r1]
    bx lr
ENDFUNC sys_hclk_div1

@ -----------------------------------------------------------------------------
@ sys_timers_run - IMP-41: the TIM2 / TIM3 prescalers for the run clock (MSI 4.194 MHz: 260, as v2.05 sets them)
@ Clobbers : r0, r1
@ -----------------------------------------------------------------------------
FUNC sys_timers_run
    movw r0, #SYS_TIM_PSC_MSI
    b sys_timers_psc
ENDFUNC sys_timers_run

@ sys_timers_psc - r0 = prescaler for TIM2 and TIM3 (ARR unchanged: TIM2 160, TIM3 15); the prescaler is preloaded and
@ takes effect at the next update event (RM0038 17.3.1), so the tick that runs during the switch is the only one of
@ another length; clobbers r1
FUNC sys_timers_psc
    ldr r1, =(TIM2_BASE + TIM_PSC)
    str r0, [r1]
    ldr r1, =(TIM3_BASE + TIM_PSC)
    str r0, [r1]
    bx lr
ENDFUNC sys_timers_psc
    .ltorg

@ -----------------------------------------------------------------------------
@ sys_clock_select - run clock (MSI range 6) or SD-card clock (PLL 32 MHz from HSE, IMP-41)
@ Replaces : 0x0801BF1A FUN_0801BF1A (v2.05); canonical symbol fn_0801BF1A is an alias
@ In       : r0 = 0 run (TIM2 / TIM3 prescalers for MSI, HSI on, SYSCLK = MSI 4.194 MHz, LSE and HSE off); any other
@            value: SD (HSE on; if HSERDY within 0x5000 polls: SYSCLK = PLL 32 MHz by sys_pll_session, or HSE as v2.05
@            when the PLL does not come up; HSI off then; else unchanged)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : DESIGN.md 3.1, 3.3, C.2; NF-02 (bounded wait for HSERDY clear instead of 0x0801BF58 b .); IMP-41
@ -----------------------------------------------------------------------------
FUNC sys_clock_select
    .global fn_0801BF1A
    .thumb_set fn_0801BF1A, sys_clock_select
    push {r4, lr}
    uxtb r4, r0                             @ v2.05 0x0801BF1E
    cbnz r4, .Lscs_sd                       @ non-zero: SD clock (0x0801BF22)
    @ run clock
    bl sys_timers_run                       @ IMP-41: the timer prescalers for MSI again before the switch
    movs r0, #1
    bl fn_0801FDE2                          @ HSION (0x0801BF26)
    ldr r4, =SYS_WAIT_POLLS
.Lscs_hsi_wait:                             @ wait HSIRDY (0x0801BF2A, unbounded in v2.05)
    movs r0, #RCC_FLAG_HSIRDY
    bl fn_0801FFF8
    cbnz r0, .Lscs_hsi_ok
    subs r4, r4, #1
    bne .Lscs_hsi_wait
.Lscs_hsi_ok:
    movs r0, #RCC_CFGR_SW_MSI
    bl fn_0801FE06                          @ SW = MSI, no SWS wait as v2.05 (0x0801BF36)
    mov r0, #RCC_ICSCR_MSIRANGE_6
    bl fn_0801FDCA                          @ MSIRANGE = 6, 4.194 MHz (0x0801BF3E)
    movs r0, #0
    bl rcc_lse_config                       @ LSE off (0x0801BF44)
    movs r0, #0
    bl fn_0801FD7A                          @ HSE off (0x0801BF4A)
    ldr r4, =SYS_WAIT_POLLS
.Lscs_hse_clear:                            @ NF-02: v2.05 loops forever if HSERDY reads 1 here (0x0801BF58)
    movs r0, #RCC_FLAG_HSERDY
    bl fn_0801FFF8
    cbz r0, .Lscs_common
    subs r4, r4, #1
    bne .Lscs_hse_clear
    b .Lscs_common                          @ bound reached: continue (NF-02)
.Lscs_sd:
    movs r0, #1
    bl fn_0801FD7A                          @ HSE on (0x0801BF5C)
    bl fn_0801FD8A                          @ wait HSERDY, 0x5000 polls (0x0801BF60)
    uxtb r0, r0
    cmp r0, #1
    bne .Lscs_common                        @ HSE did not start: stay on the present clock (0x0801BF6A)
    bl sys_pll_session                      @ IMP-41: SYSCLK = PLL 32 MHz (r0 = 1), else 0
    cbnz r0, 1f
    movs r0, #RCC_CFGR_SW_HSE
    bl fn_0801FE06                          @ the PLL did not come up: SW = HSE as v2.05 (0x0801BF6E)
1:  movs r0, #0
    bl fn_0801FDE2                          @ HSI off (0x0801BF74)
.Lscs_common:
    bl fn_0801BFC6                          @ GPIO A..H clocks on (0x0801BF78)
    movs r1, #1
    ldr r0, =(RCC_APB1_PWR | RCC_APB1_LCD)  @ 0x10000200 (0x0801BF7E)
    bl fn_0801FFBC                          @ APB1ENR |= PWR, LCD
    movs r1, #1
    movw r0, #(RCC_APB2_ADC1 | RCC_APB2_SYSCFG) @ 0x201 (0x0801BF88)
    bl fn_0801FF9E                          @ APB2ENR |= ADC1, SYSCFG
    pop {r4, pc}
ENDFUNC sys_clock_select

@ -----------------------------------------------------------------------------
@ rcc_lsi_as_rtc_lcd_clock - backup-domain reset, LSI on, RTC/LCD clock = LSI
@ Replaces : 0x0801BF92 rcc_lsi_as_rtc_lcd_clock (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : DESIGN.md 3.1, 3.3; RM0038 6.3.14
@ -----------------------------------------------------------------------------
FUNC rcc_lsi_as_rtc_lcd_clock
    push {r4, lr}
    movs r0, #1
    bl fn_0802079C                          @ PWR_CR DBP = 1, backup domain writable (0x0801BF96)
    movs r0, #1
    bl fn_0801FF78                          @ RTCRST = 1 (0x0801BF9C)
    movs r0, #0
    bl fn_0801FF78                          @ RTCRST = 0 (0x0801BFA2)
    movs r0, #1
    bl fn_0801FDFC                          @ LSION (0x0801BFA8)
    ldr r4, =SYS_WAIT_POLLS
.Lrlr_lsi_wait:                             @ wait LSIRDY (0x0801BFAC, unbounded in v2.05)
    movs r0, #RCC_FLAG_LSIRDY
    bl fn_0801FFF8
    cbnz r0, .Lrlr_lsi_ok
    subs r4, r4, #1
    bne .Lrlr_lsi_wait
.Lrlr_lsi_ok:
    movs r0, #1
    bl fn_0801FF70                          @ RTCEN (0x0801BFB8)
    mov r0, #RCC_CSR_RTCSEL_LSI
    bl fn_0801FF34                          @ RTCSEL = LSI, the LCD runs from RTCCLK (0x0801BFC0)
    pop {r4, pc}
ENDFUNC rcc_lsi_as_rtc_lcd_clock

@ -----------------------------------------------------------------------------
@ fn_0801BFC6 - clocks of GPIO ports A..H on
@ Replaces : 0x0801BFC6 (v2.05): RCC_AHBPeriphClockCmd(0xFF, ENABLE)
@ In/Out   : - / -
@ Clobbers : r0-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0801BFC6
    movs r1, #1
    movs r0, #RCC_AHBENR_GPIO_ALL
    b fn_0801FF80                           @ tail call, returns to the caller
ENDFUNC fn_0801BFC6

@ -----------------------------------------------------------------------------
@ fn_0801BFD2 - clocks of GPIO ports A..H off
@ Replaces : 0x0801BFD2 (v2.05): RCC_AHBPeriphClockCmd(0xFF, DISABLE)
@ In/Out   : - / -
@ Clobbers : r0-r3, flags
@ Context  : main (STOP preparation)
@ -----------------------------------------------------------------------------
FUNC fn_0801BFD2
    movs r1, #0
    movs r0, #RCC_AHBENR_GPIO_ALL
    b fn_0801FF80
ENDFUNC fn_0801BFD2

    .ltorg

@ =============================================================================
@ RCC / PWR library routines (v2.05 StdPeriph code, same register effects; canonical names fn_XXXXXXXX)
@ =============================================================================

@ -----------------------------------------------------------------------------
@ fn_0801FD1C - RCC to its reset clock configuration (RCC_DeInit)
@ Replaces : 0x0801FD1C (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r2, flags
@ Context  : reset, main (STOP preparation 0x0801C538)
@ Spec     : RM0038 6.3.1, 6.3.3, 6.3.4
@ -----------------------------------------------------------------------------
FUNC fn_0801FD1C
    ldr r1, =RCC_CR
    ldr r0, [r1]
    orr r0, r0, #RCC_CR_MSION               @ MSION (0x0801FD22)
    str r0, [r1]
    ldr r1, =RCC_CFGR
    ldr r0, [r1]
    ldr r2, =RCC_CFGR_RESET_KEEP            @ clear SW, HPRE, PPRE1, PPRE2, MCOSEL, MCOPRE (0x0801FD32)
    ands r0, r0, r2
    str r0, [r1]
    ldr r1, =RCC_CR
    ldr r0, [r1]
    ldr r2, =RCC_CR_RESET_KEEP              @ clear HSION, HSEON, CSSON, PLLON (0x0801FD44)
    ands r0, r0, r2
    str r0, [r1]
    ldr r0, [r1]
    bic r0, r0, #RCC_CR_HSEBYP              @ HSEBYP off (0x0801FD56)
    str r0, [r1]
    ldr r1, =RCC_CFGR
    ldr r0, [r1]
    bic r0, r0, #RCC_CFGR_PLL_MASK          @ PLLSRC, PLLMUL, PLLDIV cleared (0x0801FD66)
    str r0, [r1]
    movs r0, #0
    ldr r1, =RCC_CIR
    str r0, [r1]                            @ all clock interrupts off (0x0801FD76)
    bx lr
ENDFUNC fn_0801FD1C

@ -----------------------------------------------------------------------------
@ fn_0801FD7A - HSE configuration (RCC_HSEConfig)
@ Replaces : 0x0801FD7A (v2.05)
@ In       : r0 = byte for RCC_CR bits 23:16 (0 off, 1 = HSEON)
@ Out      : -
@ Clobbers : r1, r2
@ Context  : main (clock selection, STOP preparation)
@ Spec     : RM0038 6.3.1 (HSEON/HSEBYP)
@ -----------------------------------------------------------------------------
FUNC fn_0801FD7A
    movs r1, #0
    ldr r2, =RCC_CR_B2
    strb r1, [r2]                           @ HSEON = HSEBYP = 0 first (0x0801FD80)
    strb r0, [r2]                           @ then the requested value (0x0801FD86)
    bx lr
ENDFUNC fn_0801FD7A

@ -----------------------------------------------------------------------------
@ fn_0801FD8A - wait for HSE start-up (RCC_WaitForHSEStartUp)
@ Replaces : 0x0801FD8A (v2.05)
@ In       : -
@ Out      : r0 = 1 HSERDY set, 0 not set after 0x5000 polls
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC fn_0801FD8A
    push {r4, lr}
    movs r4, #0                             @ counter (v2.05 [sp])
.Lfd8a_loop:
    movs r0, #RCC_FLAG_HSERDY
    bl fn_0801FFF8
    adds r4, r4, #1
    cmp r4, #SYS_WAIT_POLLS                 @ 0x5000 (0x0801FDA4)
    beq .Lfd8a_end
    cmp r0, #0
    beq .Lfd8a_loop
.Lfd8a_end:
    movs r0, #RCC_FLAG_HSERDY
    bl fn_0801FFF8                          @ final read decides the result (0x0801FDB0)
    pop {r4, pc}
ENDFUNC fn_0801FD8A

@ -----------------------------------------------------------------------------
@ fn_0801FDCA - MSI range (RCC_MSIRangeConfig)
@ Replaces : 0x0801FDCA (v2.05)
@ In       : r0 = MSIRANGE field value already in bits 15:13
@ Out      : -
@ Clobbers : r1, r2
@ Context  : main (clock selection, STOP preparation)
@ Spec     : RM0038 6.3.2
@ -----------------------------------------------------------------------------
FUNC fn_0801FDCA
    ldr r2, =RCC_ICSCR
    ldr r1, [r2]
    bic r1, r1, #RCC_ICSCR_MSIRANGE_MASK
    orrs r1, r1, r0
    str r1, [r2]
    bx lr
ENDFUNC fn_0801FDCA

@ -----------------------------------------------------------------------------
@ fn_0801FDE2 - HSI on/off (RCC_HSICmd), bit-band write of RCC_CR HSION
@ Replaces : 0x0801FDE2 (v2.05)
@ In       : r0 = 0 off, 1 on (low byte used)
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main (clock selection, STOP preparation)
@ -----------------------------------------------------------------------------
FUNC fn_0801FDE2
    uxtb r0, r0
    ldr r1, =RCC_CR_HSION_BB
    str r0, [r1]
    bx lr
ENDFUNC fn_0801FDE2

@ -----------------------------------------------------------------------------
@ rcc_lse_config - LSE configuration (RCC_LSEConfig)
@ Replaces : 0x0801FDEC rcc_lse_config (v2.05)
@ In       : r0 = byte for RCC_CSR bits 15:8 (0 = LSE off)
@ Out      : -
@ Clobbers : r1, r2
@ Context  : main (clock selection, STOP preparation)
@ Spec     : RM0038 6.3.14
@ -----------------------------------------------------------------------------
FUNC rcc_lse_config
    movs r1, #0
    ldr r2, =RCC_CSR_B1
    strb r1, [r2]                           @ LSEON = LSEBYP = 0 first (0x0801FDF2)
    strb r0, [r2]                           @ requested value (0x0801FDF8)
    bx lr
ENDFUNC rcc_lse_config

@ -----------------------------------------------------------------------------
@ fn_0801FDFC - LSI on/off (RCC_LSICmd), bit-band write of RCC_CSR LSION
@ Replaces : 0x0801FDFC (v2.05)
@ In       : r0 = 0 off, 1 on
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main (rcc_lsi_as_rtc_lcd_clock)
@ -----------------------------------------------------------------------------
LFUNC fn_0801FDFC
    uxtb r0, r0
    ldr r1, =RCC_CSR_LSION_BB
    str r0, [r1]
    bx lr
ENDFUNC fn_0801FDFC

@ -----------------------------------------------------------------------------
@ fn_0801FE06 - system clock switch (RCC_SYSCLKConfig)
@ Replaces : 0x0801FE06 (v2.05)
@ In       : r0 = SW value 0..3
@ Out      : -
@ Clobbers : r1, r2
@ Context  : main (clock selection, STOP preparation)
@ Spec     : RM0038 6.3.3
@ -----------------------------------------------------------------------------
FUNC fn_0801FE06
    ldr r2, =RCC_CFGR
    ldr r1, [r2]
    bic r1, r1, #RCC_CFGR_SW_MASK           @ v2.05: lsrs/lsls #2 (0x0801FE10)
    orrs r1, r1, r0
    str r1, [r2]
    bx lr
ENDFUNC fn_0801FE06

@ -----------------------------------------------------------------------------
@ fn_0801FE1E - present system clock source (RCC_GetSYSCLKSource)
@ Replaces : 0x0801FE1E (v2.05)
@ In       : -
@ Out      : r0 = RCC_CFGR & 0xC (SWS)
@ Clobbers : r0
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0801FE1E
    ldr r0, =RCC_CFGR
    ldr r0, [r0]
    and r0, r0, #RCC_CFGR_SWS_MASK
    bx lr
ENDFUNC fn_0801FE1E

@ -----------------------------------------------------------------------------
@ fn_0801FE2A - clock frequencies (RCC_GetClocksFreq)
@ Replaces : 0x0801FE2A (v2.05), called by BLE (USART_Init 0x0801CB48)
@ In       : r0 = pointer to 4 words {SYSCLK, HCLK, PCLK1, PCLK2} in Hz
@ Out      : the 4 words written
@ Clobbers : r1-r3, r12, flags (r4-r7 saved; v2.05 kills r1-r3, r12)
@ Context  : main
@ RAM      : reads the v2.05 tables v_2000020C (PLLMUL factors) and v_20000218 (prescaler shifts)
@ Spec     : RM0038 6.2, 6.3.2, 6.3.3
@ -----------------------------------------------------------------------------
FUNC fn_0801FE2A
    push {r4-r7}
    ldr r7, =RCC_CFGR
    ldr r7, [r7]
    and r1, r7, #RCC_CFGR_SWS_MASK          @ SWS (0x0801FE3C)
    cmp r1, #0x0
    beq .Lfe2a_msi
    cmp r1, #0x4
    beq .Lfe2a_hsi
    cmp r1, #0x8
    beq .Lfe2a_hse
    cmp r1, #0xC
    beq .Lfe2a_pll
    b .Lfe2a_msi                            @ (unreachable 2-bit field) default = MSI as v2.05 0x0801FECA
.Lfe2a_hsi:
    ldr r7, =HSI_VALUE                      @ 16 MHz (0x0801FE76)
    str r7, [r0]
    b .Lfe2a_bus
.Lfe2a_hse:
    ldr r7, =HSE_VALUE                      @ 8 MHz, the library constant (0x0801FE7C)
    str r7, [r0]
    b .Lfe2a_bus
.Lfe2a_pll:
    ldr r7, =RCC_CFGR
    ldr r7, [r7]
    and r2, r7, #0x003C0000                 @ PLLMUL (0x0801FE86)
    and r3, r7, #0x00C00000                 @ PLLDIV (0x0801FE90)
    ldr r6, =v_2000020C                     @ PLLMUL factor table in RAM (init data)
    lsrs r2, r2, #18
    ldrb r2, [r6, r2]                       @ multiplier
    lsrs r3, r3, #22
    adds r3, r3, #1                         @ divider
    and r4, r7, #0x00010000                 @ PLLSRC (0x0801FEA4)
    cbnz r4, .Lfe2a_pll_hse
    ldr r7, =HSI_VALUE
    mul r7, r7, r2
    udiv r7, r7, r3
    str r7, [r0]
    b .Lfe2a_bus
.Lfe2a_pll_hse:
    ldr r7, =HSE_VALUE
    mul r7, r7, r2
    udiv r7, r7, r3
    str r7, [r0]
    b .Lfe2a_bus
.Lfe2a_msi:
    ldr r7, =RCC_ICSCR
    ldr r7, [r7]
    ubfx r6, r7, #13, #3                    @ MSIRANGE (0x0801FE5A)
    cmp r6, #6
    bne 1f
    ldr r7, =ck_status                      @ IMP-46: range 6 measured against HSE (sys/msical.s): the measured value
    ldrb r7, [r7]
    cmp r7, #CK_ST_OK
    it ne
    cmpne r7, #CK_ST_UNDO
    bne 1f
    ldr r7, =ck_hz
    ldr r7, [r7]
    str r7, [r0]
    b .Lfe2a_bus
1:
    adds r12, r6, #1
    movs r7, #1
    lsl r7, r7, r12
    mov r12, #0x8000
    mul r7, r12, r7                         @ 32768 * 2^(range+1) (0x0801FE6E)
    str r7, [r0]
.Lfe2a_bus:
    ldr r6, =v_20000218                     @ prescaler shift table in RAM (init data)
    ldr r7, =RCC_CFGR
    ldr r7, [r7]
    and r1, r7, #0xF0                       @ HPRE (0x0801FEEC)
    lsrs r1, r1, #4
    ldrb r5, [r6, r1]
    ldr r7, [r0]
    lsrs r7, r7, r5
    str r7, [r0, #4]                        @ HCLK
    ldr r7, =RCC_CFGR
    ldr r7, [r7]
    and r1, r7, #0x700                      @ PPRE1 (0x0801FF04)
    lsrs r1, r1, #8
    ldrb r5, [r6, r1]
    ldr r7, [r0, #4]
    lsrs r7, r7, r5
    str r7, [r0, #8]                        @ PCLK1
    ldr r7, =RCC_CFGR
    ldr r7, [r7]
    and r1, r7, #0x3800                     @ PPRE2 (0x0801FF1C)
    lsrs r1, r1, #11
    ldrb r5, [r6, r1]
    ldr r7, [r0, #4]
    lsrs r7, r7, r5
    str r7, [r0, #12]                       @ PCLK2
    pop {r4-r7}
    bx lr
ENDFUNC fn_0801FE2A

@ -----------------------------------------------------------------------------
@ fn_0801FF34 - RTC clock source (RCC_RTCCLKConfig)
@ Replaces : 0x0801FF34 (v2.05)
@ In       : r0 = RTCSEL bits 17:16 (with RTCPRE bits 30:29 for the HSE source)
@ Out      : -
@ Clobbers : r1-r3
@ Context  : main (rcc_lsi_as_rtc_lcd_clock)
@ Spec     : RM0038 6.3.1 (RTCPRE), 6.3.14 (RTCSEL)
@ -----------------------------------------------------------------------------
FUNC fn_0801FF34
    and r2, r0, #RCC_CSR_RTCSEL_MASK
    cmp r2, #RCC_CSR_RTCSEL_HSE
    bne .Lff34_sel                          @ only the HSE source sets RTCPRE (0x0801FF3E)
    ldr r3, =RCC_CR
    ldr r1, [r3]
    bic r1, r1, #RCC_CR_RTCPRE_MASK
    and r2, r0, #RCC_CR_RTCPRE_MASK
    orrs r1, r1, r2
    str r1, [r3]
.Lff34_sel:
    ldr r3, =RCC_CSR
    ldr r2, [r3]
    bic r2, r2, #RCC_CSR_RTCSEL_MASK        @ clear RTCSEL (0x0801FF58)
    str r2, [r3]
    ldr r2, [r3]
    and r1, r0, #RCC_CSR_RTCSEL_MASK
    orrs r2, r2, r1                         @ set the requested source (0x0801FF68)
    str r2, [r3]
    bx lr
ENDFUNC fn_0801FF34

@ -----------------------------------------------------------------------------
@ fn_0801FF70 - RTC clock enable (RCC_RTCCLKCmd), bit-band RCC_CSR RTCEN
@ Replaces : 0x0801FF70 (v2.05)
@ In       : r0 = 0/1
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main (rcc_lsi_as_rtc_lcd_clock)
@ -----------------------------------------------------------------------------
LFUNC fn_0801FF70
    uxtb r0, r0
    ldr r1, =RCC_CSR_RTCEN_BB
    str r0, [r1]
    bx lr
ENDFUNC fn_0801FF70

@ -----------------------------------------------------------------------------
@ fn_0801FF78 - backup domain software reset (RCC_RTCResetCmd), bit-band RCC_CSR RTCRST
@ Replaces : 0x0801FF78 (v2.05)
@ In       : r0 = 1 assert, 0 release
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main (rcc_lsi_as_rtc_lcd_clock)
@ -----------------------------------------------------------------------------
LFUNC fn_0801FF78
    uxtb r0, r0
    ldr r1, =RCC_CSR_RTCRST_BB
    str r0, [r1]
    bx lr
ENDFUNC fn_0801FF78

@ -----------------------------------------------------------------------------
@ fn_0801FF80 - AHB peripheral clocks on/off (RCC_AHBPeriphClockCmd)
@ Replaces : 0x0801FF80 (v2.05)
@ In       : r0 = RCC_AHBENR bit mask, r1 = 0 clear the bits, else set them (low byte tested)
@ Out      : -
@ Clobbers : r1-r3, flags
@ Context  : main (used by BRD, BLE, LCD, SD)
@ Spec     : RM0038 6.3.8 (6.3.9, 6.3.10, 6.3.6 for the three routines below)
@ -----------------------------------------------------------------------------
FUNC fn_0801FF80
    ldr r3, =RCC_AHBENR
    b rcc_bits_cmd
ENDFUNC fn_0801FF80

@ -----------------------------------------------------------------------------
@ fn_0801FF9E - APB2 peripheral clocks on/off (RCC_APB2PeriphClockCmd)
@ Replaces : 0x0801FF9E (v2.05)
@ In       : r0 = RCC_APB2ENR bit mask, r1 = 0 clear, else set
@ Out      : -
@ Clobbers : r1-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0801FF9E
    ldr r3, =RCC_APB2ENR
    b rcc_bits_cmd
ENDFUNC fn_0801FF9E

@ -----------------------------------------------------------------------------
@ fn_0801FFBC - APB1 peripheral clocks on/off (RCC_APB1PeriphClockCmd)
@ Replaces : 0x0801FFBC (v2.05)
@ In       : r0 = RCC_APB1ENR bit mask, r1 = 0 clear, else set
@ Out      : -
@ Clobbers : r1-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0801FFBC
    ldr r3, =RCC_APB1ENR
    b rcc_bits_cmd
ENDFUNC fn_0801FFBC

@ -----------------------------------------------------------------------------
@ fn_0801FFDA - APB2 peripheral reset on/off (RCC_APB2PeriphResetCmd)
@ Replaces : 0x0801FFDA (v2.05)
@ In       : r0 = RCC_APB2RSTR bit mask, r1 = 0 release, else assert
@ Out      : -
@ Clobbers : r1-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0801FFDA
    ldr r3, =RCC_APB2RSTR
    b rcc_bits_cmd
ENDFUNC fn_0801FFDA

@ -----------------------------------------------------------------------------
@ rcc_bits_cmd - set or clear bits of an RCC register (common body of the four routines above)
@ Replaces : - (the identical bodies of 0x0801FF80, 0x0801FF9E, 0x0801FFBC, 0x0801FFDA)
@ In       : r3 = register address, r0 = bit mask, r1 = 0 clear, else set (low byte tested)
@ Out      : -
@ Clobbers : r1, r2, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC rcc_bits_cmd
    uxtb r1, r1                             @ FunctionalState is a byte (v2.05 0x0801FF80 uxtb r1)
    ldr r2, [r3]
    cbz r1, .Lrbc_clear
    orrs r2, r2, r0                         @ ENABLE: set the bits
    str r2, [r3]
    bx lr
.Lrbc_clear:
    bics r2, r2, r0                         @ DISABLE: clear the bits
    str r2, [r3]
    bx lr
ENDFUNC rcc_bits_cmd

@ -----------------------------------------------------------------------------
@ fn_0801FFF8 - RCC flag status (RCC_GetFlagStatus)
@ Replaces : 0x0801FFF8 (v2.05)
@ In       : r0 = flag: bits 7:5 register (1 = RCC_CR, else RCC_CSR), bits 4:0 bit number
@ Out      : r0 = 1 set, 0 clear
@ Clobbers : r1, r2, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0801FFF8
    uxtb r0, r0
    lsrs r1, r0, #5
    cmp r1, #1
    ite eq                                  @ register select (0x0802000C)
    ldreq r2, =RCC_CR                       @ 1: RCC_CR
    ldrne r2, =RCC_CSR                      @ otherwise RCC_CSR
    ldr r2, [r2]
    and r1, r0, #0x1F                       @ bit number
    lsr r2, r2, r1
    and r0, r2, #1
    bx lr
ENDFUNC fn_0801FFF8

@ -----------------------------------------------------------------------------
@ fn_0802079C - backup domain write access (PWR_RTCAccessCmd), bit-band PWR_CR DBP
@ Replaces : 0x0802079C (v2.05)
@ In       : r0 = 0/1
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main (rcc_lsi_as_rtc_lcd_clock)
@ -----------------------------------------------------------------------------
LFUNC fn_0802079C
    uxtb r0, r0
    ldr r1, =PWR_CR_DBP_BB
    str r0, [r1]
    bx lr
ENDFUNC fn_0802079C

    .ltorg
