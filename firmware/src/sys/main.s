@ =============================================================================
@ main.s - SYS: system initialisation, main loop, NVIC and timer set-up, critical sections, SysTick
@
@ Replaces the v2.05 main 0x08024B40 (start-up calls and the endless loop 0x08024B6A..0x08024DDE), FUN_0801BE76
@ (system init), FUN_0801BFDE (NVIC), FUN_0801C486 / FUN_0801C4D4 (TIM2 / TIM3), the NVIC, TIM and DBGMCU
@ library routines 0x0801BE60, 0x08020848, 0x0802086C, 0x08020876, 0x08020908, 0x0802096C, 0x08020988,
@ 0x0802099E, SysTick_Handler 0x080248B0 with FUN_0800ED0C.
@ Loop structure: DESIGN.md 3.5.
@ Appendix A SYS functions that are not in the SYS objects: the FLASH driver 0x0801F9FC, 0x0801FAFA, 0x0801FB00,
@ 0x0801FB60 is ported by NVM (DESIGN.md 6.1, 6.21); the option-byte routines 0x0801FA68, 0x0801FA8E, 0x0801FAA0,
@ 0x0801FAEE (BOR rewrite with OBL_LAUNCH, called only from 0x0801BEAC..0x0801BED4) are not carried over (NF-03).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .bss_port.sys, "aw", %nobits
    .balign 4
@ sys_bootwin_open: 1 while the power-on window of the production loop is open (bootwin_step is then called
@ once per pass until it returns 1); always 0 in baseline builds, where the window runs to completion before
@ the loop (DESIGN.md 7.1).  Owner SYS; written by sys_bootwin_begin and the loop.
    .global sys_bootwin_open
sys_bootwin_open:
    .space 1

    .section .rodata.sys.main, "a", %progbits
    .balign 4
@ TIM_TimeBaseInit structures of FUN_0801C486 / FUN_0801C4D4 (v2.05 builds them on the stack:
@ 0x0801C490..0x0801C4A4 and 0x0801C4DE..0x0801C4F2): u16 prescaler, u16 counter mode, u32 period,
@ u16 clock division, u16 padding.  TIM2: PSC 260, ARR 160 -> 99.81 Hz; TIM3: PSC 260, ARR 15 -> 1004.4 Hz at
@ MSI 4.194304 MHz (DESIGN.md 3.3).
sys_tim2_base:
    .hword 0x0104, 0x0000
    .word  0x000000A0
    .hword 0x0000, 0x0000
sys_tim3_base:
    .hword 0x0104, 0x0000
    .word  0x0000000F
    .hword 0x0000, 0x0000

@ NVIC_Init structures of FUN_0801BFDE (stack bytes {channel, preemption, sub, enable}: 0x0801BFE8..0x0801C04A)
sys_nvic_cfg:
    .byte IRQ_SDIO,     0, 0, 1             @ IRQ45 SDIO: IPR 0x00 (0x0801BFE8)
    .byte IRQ_DMA2_CH4, 0, 0, 1             @ IRQ53 DMA2 channel 4: IPR 0x00 (0x0801C006; sub/enable kept from
                                            @ the previous structure in v2.05: 0 and 1)
    .byte IRQ_TIM2,     2, 2, 1             @ IRQ28 TIM2: IPR 0xA0 (0x0801C018)
    .byte IRQ_TIM3,     1, 1, 1             @ IRQ29 TIM3: IPR 0x50 (0x0801C036)

    .section .text.sys.main, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sys_main - start-up sequence after RAM init, then the main loop (never returns)
@ Replaces : 0x08024B40 main (v2.05) except its VTOR write 0x08024B4A (done first in sys_reset)
@ In       : -
@ Out      : does not return
@ Clobbers : all
@ Context  : main
@ Spec     : DESIGN.md 3.2 step 5, 3.5 (loop table), 7.1 (window)
@ Deviation: IMP-02 and IMP-06; NF-11 (blink drawing moved here)
@ -----------------------------------------------------------------------------
FUNC sys_main
    bl sys_system_init                      @ FUN_0801BE76 (0x08024B4E)
    bl sample_pf8_at_boot                   @ 0x08024B52
    bl set_state_reset                      @ FUN_08024DE0 (0x08024B56)
                                            @ (the calibration cache is loaded by bootwin_start, inside the splash commit's wait)
    movs r1, #1
    ldr r0, =lcd_contrast                   @ 0x20000237 (0x08024B5C)
    ldrb r0, [r0]
    bl lcd_init                             @ lcd_init(contrast, 1) (0x08024B62)
    bl sys_bootwin_begin                    @ power-on window (FUN_0800EA3A at 0x08024B66)
    .if BLE_AT_POWERUP
    bl blcmd_ble_on                         @ development build: Bluetooth on as a long PEAK would switch it on
    .endif

    @ ---------------------------------------------------------------- main loop 0x08024B6A..0x08024DDE
    @ r4 = scratch across calls (callee-saved)
.Lmain_loop:
    @ step 1: HY3131 event line
    bl hy3131_poll                          @ 0x08024B6A

    @ step 2: new mean available
    ldr r0, =v_2000805D
    ldrb r0, [r0]
    cbz r0, .Lmain_step3
    bl fn_0800DCFC                          @ post-processing (0x08024B78)
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cbnz r0, .Lmain_s2_flag                 @ mode 0 (LowZ) only:
    bl fn_08006558                          @ LowZ AC/DC select (0x08024B86)
.Lmain_s2_flag:
    movs r0, #1
    ldr r1, =v_20008061
    strb r0, [r1]                           @ 0x08024B8A
.Lmain_step3:
    @ step 3: display refresh
    bl fn_08016D34                          @ 0x08024B92

    @ step 4: 10 ms flag
    ldr r1, =v_200080D0
    ldrb r0, [r1]
    cbz r0, .Lmain_step5
    movs r0, #0
    strb r0, [r1]                           @ consume the flag (0x08024BA6)
    bl fn_08014948                          @ dial (0x08024BA8)
    bl fn_0801680C                          @ keys (0x08024BAC)
    bl sense_pe10_pe11                      @ jack sense (0x08024BB0)
    bl fn_0800ED64                          @ counter preset (0x08024BB4)
    bl fn_0800D664                          @ UI timers (0x08024BB8)
    bl fn_080100C4                          @ RTC seconds (0x08024BBC)
    ldr r1, =rtc_blink_request              @ NF-11: drawing requested by sys_tim2_isr (v2.05 draws in IRQ28,
    ldrb r0, [r1]                           @ 0x080246FC)
    cbz r0, .Lmain_step5
    movs r0, #0
    strb r0, [r1]                           @ request consumed before drawing (a new one is not lost)
    movs r0, #1
    bl fn_0801896C                          @ setup page 7 blink drawing, argument 1 as in v2.05
.Lmain_step5:
    @ IMP-02: one power-on window step per pass after step 4 (interface of the CAL module: bootwin_step neither
    @ waits nor consumes the 10 ms flag nor calls the key processing; step 4 does that), until it returns 1
    ldr r0, =sys_bootwin_open
    ldrb r0, [r0]
    cbz r0, .Lmain_s5_flag                  @ window closed
    bl bootwin_step                         @ r0 = 0 window open, 1 closed
    cbz r0, .Lmain_s5_flag
    movs r0, #0
    ldr r1, =sys_bootwin_open
    strb r0, [r1]                           @ window over
.Lmain_s5_flag:
    @ step 5: 100 ms flag
    ldr r1, =v_200080D1
    ldrb r0, [r1]
    cbz r0, .Lmain_step6
    movs r0, #0
    strb r0, [r1]                           @ 0x08024BD0
    bl fn_0800FF18                          @ RTC (0x08024BD2)
    bl fn_0801349C                          @ ADC alternation (0x08024BD6)
    bl log_compose_mode_range               @ 0x08024BDA
.Lmain_step6:
    @ step 6: flag 0x200080D2 (no setter in v2.05; cleared as v2.05 does)
    ldr r1, =v_200080D2
    ldrb r0, [r1]
    cbz r0, .Lmain_step7
    movs r0, #0
    strb r0, [r1]                           @ 0x08024BEE
.Lmain_step7:
    @ step 7: BLE frame request (set by sys_tim2_isr at count 40)
    ldr r1, =v_2000802C
    ldrb r0, [r1]
    cbz r0, .Lmain_step8
    movs r0, #0
    strb r0, [r1]                           @ 0x08024C00
    ldr r0, =v_2000802B
    ldrb r0, [r0]
    cbz r0, .Lmain_step8                    @ BLE off
    bl fn_0800C5D2                          @ build the status frame (0x08024C0C)
.Lmain_step8:
    @ step 8: 500 ms flag
    ldr r1, =v_200080D3
    ldrb r0, [r1]
    cbz r0, .Lmain_step9
    movs r0, #0
    strb r0, [r1]                           @ 0x08024C20
    ldr r0, =v_2000806E
    ldrb r0, [r0]
    cbz r0, .Lmain_step9                    @ no setup edit in progress
    bl fn_0800D190                          @ 0x08024C2C
.Lmain_step9:
    @ step 9: 1 s flag
    ldr r1, =v_200080D4
    ldrb r0, [r1]
    cmp r0, #0
    beq .Lmain_step10
    movs r0, #0
    strb r0, [r1]                           @ 0x08024C42
    bl fn_0800FF18                          @ 0x08024C44
    movs r0, #0
    ldr r1, =v_20007FFA
    strb r0, [r1]                           @ 0x08024C4E
    @ logging interval (0x08024C50..0x08024CAC); r4 = 0x20007FE1 logging-on flag
    ldr r0, =v_20007FE1
    ldrb r4, [r0]
    cbz r4, .Lmain_apo                      @ logging off: neither block runs
    ldr r0, =v_20008050
    ldrb r0, [r0]
    cbnz r0, .Lmain_apo                     @ auto-hold stage 2: neither block runs
    ldr r0, =v_2000022C
    ldrh r1, [r0]                           @ r1 = logging interval in seconds
    cbnz r1, .Lmain_log_count
    movs r0, #0
    ldr r2, =v_20007FA8
    strh r0, [r2]                           @ interval 0: counter = 0 (0x08024C70)
    b .Lmain_log_trig                       @ IMP-21: the trigger test of the second
.Lmain_log_count:                           @ interval > 0: count seconds (0x08024C8C..0x08024CAC)
    ldr r2, =v_20007FA8
    CRIT_ENTER r3                           @ 0x20007FA8 is also incremented by sys_tim2_isr (DESIGN.md 3.4)
    ldrh r0, [r2]
    adds r0, r0, #1
    strh r0, [r2]
    CRIT_EXIT r3
    uxth r0, r0
    cmp r0, r1
    blo .Lmain_log_trig                     @ counter < interval (0x08024CA0 bcc)
    movs r0, #0
    strh r0, [r2]                           @ counter = 0
    bl log_trig_interval                    @ IMP-21: log-write request (0x08024CAC) as the trigger allows
.Lmain_log_trig:
    bl log_trig_second                      @ IMP-21: tr-Ch change test (logging on, not in auto-hold stage 2)
.Lmain_apo:
    bl pwr_apo_second                       @ APO block 0x08024CAE..0x08024D1A (PWR)
    bl pwr_bl_second                        @ IMP-07: backlight auto-off countdown, same 1 s flag (PWR, src/pwr/backlight.s)
    @ 0x200080E6 = (APO counter < 60) (0x08024D1C..0x08024D30)
    ldr r0, =apo_countdown                  @ 0x20000230 (u16)
    ldrh r0, [r0]
    movs r1, #0
    cmp r0, #60
    it lt                                   @ signed compare as v2.05 (0x08024D22 bge)
    movlt r1, #1                            @ counter < 60: APO warning state
    ldr r0, =v_200080E6
    strb r1, [r0]
    cbz r1, .Lmain_step10
    bl fn_08019CBC                          @ APO symbol (0x08024D3A)
.Lmain_step10:
    @ step 10: log record request (0x08024D3E..0x08024D4A): bitwise AND of the two flag bytes
    ldr r0, =v_20007FE1
    ldrb r0, [r0]
    ldr r1, =v_20007FE2
    ldrb r1, [r1]
    tst r0, r1
    beq .Lmain_step11
    @ IMP-06 (W8_to_W1.md item 3): while the step-12 write machine is between two attempts (log_write_state != 0)
    @ no record is taken.  In v2.05 the loop is frozen during a write, so no record is taken then either; taking
    @ records between attempts could wrap the 60-slot ring over rows that are still pending.
    ldr r0, =log_write_state
    ldrb r0, [r0]
    cbnz r0, .Lmain_step11                  @ a write is in progress: skip the record
    bl fn_08010B64
.Lmain_step11:
    bl bft_poll                             @ IMP-28: Bluetooth file transfer while the SETUP page Ld is shown
    @ step 11: BLE command received
    ldr r0, =v_20008030
    ldrb r0, [r0]
    cbz r0, .Lmain_step12
    bl fn_0800C332                          @ 0x08024D56
.Lmain_step12:
    @ step 12: SD log write
    @ IMP-06 (LOG, W8_to_W1.md item 3): the write is a state machine, one v2.05 session attempt (log_session_once) per
    @ pass, so a failing card no longer blocks the loop for up to 40 attempts in a row.  The attempt order, the retry
    @ counts and the error handling below are v2.05's (0x08024D5A..0x08024D7C).  The request flag 0x2000801C stays
    @ set while the machine is busy and is cleared when the write is done, as v2.05 clears it after the call.
    ldr r0, =log_write_state
    ldrb r0, [r0]
    cbnz r0, .Lmain_s12_step                @ a write is in progress: its next attempt
    ldr r0, =v_2000801C
    ldrb r0, [r0]
    cbz r0, .Lmain_step13                   @ no write requested
    bl log_write_start                      @ arm the machine: first series of 20 attempts
.Lmain_s12_step:
    bl log_write_step                       @ r0 = 0 busy (continue on the next pass), 1 done
    cbz r0, .Lmain_step13
    ldr r0, =log_write_result
    ldrb r0, [r0]                           @ 0 written, 1 failed (v2.05 r0 of 0x08024D62)
    cbz r0, .Lmain_s12_clear
    movs r0, #0
    bl fn_08010AF8                          @ OF-61: log_stop(0): range freeze undone, counters, stop time and MEM view window
                                            @ saved, setup page back to its default (v2.05 only clears the flag: autorange
                                            @ stayed off after a failed card); the rows cannot be written, the card failed 40 times
    movs r0, #0
    ldr r1, =v_20007FE1
    strb r0, [r1]                           @ logging off (0x08024D6E)
    bl fn_08022932                          @ SD power-off (0x08024D70)
    bl fn_080153AC                          @ leave MEM view (0x08024D74)
.Lmain_s12_clear:
    movs r0, #0
    ldr r1, =v_2000801C
    strb r0, [r1]                           @ 0x08024D7C
.Lmain_step13:
    @ step 13: mode/range apply request (0x08024D7E..0x08024DCE)
    ldr r0, =v_2000804A
    ldrb r0, [r0]
    ldr r1, =v_2000804B
    ldrb r1, [r1]
    orrs r0, r0, r1
    uxtb r0, r0
    cbz r0, .Lmain_step14
    movs r0, #1
    bl meter_apply_mode_range               @ 0x08024D90
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #6                              @ FREQ, PULSE, DUTY, CAP keep the HOLD stage-2 state
    beq .Lmain_step14
    cmp r0, #7
    beq .Lmain_step14
    cmp r0, #8
    beq .Lmain_step14
    cmp r0, #12
    beq .Lmain_step14
    ldr r0, =v_20008050
    ldrb r0, [r0]
    cbz r0, .Lmain_step14
    movs r0, #0
    ldr r1, =v_2000805D
    strb r0, [r1]                           @ 0x08024DC0
    ldr r1, =v_20008060
    strb r0, [r1]                           @ 0x08024DC4
    ldr r1, =v_20008062
    strb r0, [r1]                           @ 0x08024DC8
    movs r0, #1
    ldr r1, =v_20008054
    strb r0, [r1]                           @ 0x08024DCE
.Lmain_step14:
    @ step 14: APO power-off request
    ldr r0, =v_2000803A
    ldrb r0, [r0]
    cbz r0, .Lmain_end
    bl enter_stop_and_reinit                @ 0x08024DDA
.Lmain_end:
    wfi                                     @ IMP-06: sleep until the next interrupt (TIM3 at least every
                                            @ 0.996 ms); v2.05 never sleeps
    b .Lmain_loop
ENDFUNC sys_main

@ -----------------------------------------------------------------------------
@ sys_bootwin_begin - open the power-on window
@ Replaces : the call of FUN_0800EA3A at 0x08024B66 (main) and 0x08024F00 (enter_stop_and_reinit)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : DESIGN.md 7.1: calls bootwin_start and lets the main loop call bootwin_step once per pass after step 4
@            (IMP-02); interface of the CAL module (firmware/requests/W7_to_W1.md item 4)
@ -----------------------------------------------------------------------------
FUNC sys_bootwin_begin
    push {r3, lr}
    bl bootwin_start                        @ window opened (CAL)
    movs r0, #1
    ldr r1, =sys_bootwin_open
    strb r0, [r1]                           @ the loop steps the window from now on
    pop {r3, pc}
ENDFUNC sys_bootwin_begin

@ -----------------------------------------------------------------------------
@ sys_system_init - power flags, clocks, RTC/LCD clock, pins, ADC, NVIC, timers
@ Replaces : 0x0801BE76 FUN_0801BE76 (v2.05) without the option-byte block 0x0801BEAC..0x0801BED4 (NF-03);
@            canonical symbol fn_0801BE76 is an alias
@ In       : -
@ Out      : - (interrupts enabled on return)
@ Clobbers : r0-r3, r12, flags
@ Context  : main (sys_main, enter_stop_and_reinit)
@ RAM      : writes 0x20007FDE (wake-up flag seen)
@ Spec     : DESIGN.md 3.1, 3.2 step 5 and 6
@ Deviation: NF-02, NF-03, NF-18 (DBGMCU only with DEBUG = 1); all ready-flag waits bounded
@ -----------------------------------------------------------------------------
FUNC sys_system_init
    .global fn_0801BE76
    .thumb_set fn_0801BE76, sys_system_init
    push {r4, lr}
    movs r0, #PWR_CSR_WUF
    bl fn_08020808                          @ PWR_GetFlagStatus(WUF) (0x0801BE7A)
    cbz r0, .Lssi_no_wuf
    movs r1, #1
    mov r0, #RCC_APB1_PWR
    bl fn_0801FFBC                          @ PWR clock on (0x0801BE88)
    movs r0, #2
    bl fn_08020822                          @ PWR_ClearFlag(2): PWR_CR |= CSBF, as v2.05 (0x0801BE8E)
    movs r0, #1
    b .Lssi_wuf_store
.Lssi_no_wuf:
    movs r0, #0
.Lssi_wuf_store:
    ldr r1, =v_20007FDE
    strb r0, [r1]                           @ 0x0801BE98 / 0x0801BEA2
    bl nvm_clear_errors                     @ FLASH_SR <- 0x1F02 where v2.05 does it (0x0801BEA4)
    @ v2.05 0x0801BEAC..0x0801BED4 (FLASH_OBR read into 0x20007D0C and BOR rewrite with OBL_LAUNCH) is not
    @ carried over (NF-03).  0x20007D0C has no reader in v2.05 and stays 0 (the BOR level of the supplied unit,
    @ option byte USER 0xF0, DESIGN.md 2.1).
    mov r0, #PWR_CR_VOS_RANGE1
    bl fn_080207B4                          @ voltage range 1 (0x0801BEDC)
    ldr r4, =SYS_WAIT_POLLS
.Lssi_vos_wait:                             @ wait VOSF clear (0x0801BEE0, unbounded in v2.05)
    movs r0, #PWR_CSR_VOSF
    bl fn_08020808
    cbz r0, .Lssi_vos_ok
    subs r4, r4, #1
    bne .Lssi_vos_wait
.Lssi_vos_ok:
    movs r0, #0
    bl sys_clock_select                     @ run clock (0x0801BEEC)
    bl ck_run                               @ IMP-46: MSI measured against HSE and trimmed (sys/msical.s)
    bl rcc_lsi_as_rtc_lcd_clock             @ 0x0801BEF0
    .if DEBUG
    movs r1, #1
    movs r0, #DBGMCU_CR_SLEEP_STOP_STANDBY
    bl fn_08020848                          @ DBGMCU_CR |= 7 (0x0801BEF8), debug builds only (NF-18)
    .endif
    bl board_gpio_init                      @ 0x0801BEFC
    bl gpio_init_analog                     @ 0x0801BF00
    bl fn_08013DD4                          @ ADC init (0x0801BF04)
    bl sys_nvic_init                        @ FUN_0801BFDE (0x0801BF08)
    cpsie i                                 @ DESIGN.md 3.2 step 6: interrupts live after the NVIC set-up
    bl sys_tim2_init                        @ FUN_0801C486 (0x0801BF0C)
    bl sys_tim3_init                        @ FUN_0801C4D4 (0x0801BF10)
    bl fn_0801BFC6                          @ GPIO clocks on (0x0801BF14)
    pop {r4, pc}
ENDFUNC sys_system_init

@ -----------------------------------------------------------------------------
@ sys_nvic_init - priority grouping and the v2.05 interrupt set
@ Replaces : 0x0801BFDE FUN_0801BFDE (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : DESIGN.md 3.4: PRIGROUP 5; IRQ45, IRQ53 priority 0, IRQ28 0xA0, IRQ29 0x50, all enabled.  Every
@            other IRQ priority byte is written 0 first, so no value left by the bootloader survives (the
@            bootloader left IRQ28 = 0xA0 and all others 0 in an emulator run of inputs/binaries/bootloader.bin
@            (not established from the bootloader code itself); with that start the end state equals v2.05's);
@            IRQ38 (USART2, enabled by BLE) keeps priority 0 as in v2.05.
@ -----------------------------------------------------------------------------
LFUNC sys_nvic_init
    push {r4, lr}
    mov r0, #SCB_AIRCR_PRIGROUP_2_2
    bl fn_0802086C                          @ AIRCR = 0x05FA0500 (0x0801BFE4)
    ldr r0, =NVIC_IPR0
    movs r1, #0
    movs r2, #NVIC_IPR_WORDS
.Lsni_ipr:                                  @ IPR0..IPR14 = 0 (IRQ 0..59)
    str r1, [r0], #4
    subs r2, r2, #1
    bne .Lsni_ipr
    ldr r4, =sys_nvic_cfg
    mov r0, r4
    bl fn_08020876                          @ IRQ45 (0x0801C002)
    adds r0, r4, #4
    bl fn_08020876                          @ IRQ53 (0x0801C014)
    adds r0, r4, #8
    bl fn_08020876                          @ IRQ28 (0x0801C032)
    adds r0, r4, #12
    bl fn_08020876                          @ IRQ29 (0x0801C050)
    pop {r4, pc}
ENDFUNC sys_nvic_init

@ -----------------------------------------------------------------------------
@ sys_tim2_init - TIM2: 10.02 ms period with update interrupt
@ Replaces : 0x0801C486 FUN_0801C486 (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : DESIGN.md 3.3; RM0038 17.4
@ -----------------------------------------------------------------------------
LFUNC sys_tim2_init
    push {r3, lr}
    movs r1, #1
    movs r0, #RCC_APB1_TIM2
    bl fn_0801FFBC                          @ TIM2 clock on (0x0801C48C)
    ldr r1, =sys_tim2_base
    mov r0, #TIM2_BASE
    bl fn_08020908                          @ PSC 260, ARR 160 (0x0801C4AE)
    movs r1, #TIM_SR_UIF
    mov r0, #TIM2_BASE
    bl fn_0802099E                          @ clear the update flag set by UG (0x0801C4B8)
    movs r2, #1
    movs r1, #TIM_DIER_UIE
    mov r0, #TIM2_BASE
    bl fn_08020988                          @ update interrupt on (0x0801C4C4)
    movs r1, #1
    mov r0, #TIM2_BASE
    bl fn_0802096C                          @ counter on (0x0801C4CE)
    pop {r3, pc}
ENDFUNC sys_tim2_init

@ -----------------------------------------------------------------------------
@ sys_tim3_init - TIM3: 0.996 ms period with update interrupt
@ Replaces : 0x0801C4D4 FUN_0801C4D4 (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : DESIGN.md 3.3; RM0038 17.4
@ -----------------------------------------------------------------------------
LFUNC sys_tim3_init
    push {r4, lr}
    movs r1, #1
    movs r0, #RCC_APB1_TIM3
    bl fn_0801FFBC                          @ TIM3 clock on (0x0801C4DA)
    ldr r4, =TIM3_BASE
    ldr r1, =sys_tim3_base
    mov r0, r4
    bl fn_08020908                          @ PSC 260, ARR 15 (0x0801C4FC)
    movs r1, #TIM_SR_UIF
    mov r0, r4
    bl fn_0802099E                          @ 0x0801C506
    movs r2, #1
    movs r1, #TIM_DIER_UIE
    mov r0, r4
    bl fn_08020988                          @ 0x0801C512
    movs r1, #1
    mov r0, r4
    bl fn_0802096C                          @ 0x0801C51C
    pop {r4, pc}
ENDFUNC sys_tim3_init

    .ltorg

@ =============================================================================
@ Critical sections (DESIGN.md 3.4, Appendix C.2)
@ =============================================================================

@ -----------------------------------------------------------------------------
@ sys_crit_enter - mask interrupts, return the previous PRIMASK
@ Replaces : - (new)
@ In       : -
@ Out      : r0 = saved PRIMASK
@ Clobbers : r0
@ Context  : any
@ -----------------------------------------------------------------------------
FUNC sys_crit_enter
    mrs r0, primask
    cpsid i
    bx lr
ENDFUNC sys_crit_enter

@ -----------------------------------------------------------------------------
@ sys_crit_exit - restore PRIMASK saved by sys_crit_enter
@ Replaces : - (new)
@ In       : r0 = saved PRIMASK
@ Out      : -
@ Clobbers : none
@ Context  : any
@ -----------------------------------------------------------------------------
FUNC sys_crit_exit
    msr primask, r0
    bx lr
ENDFUNC sys_crit_exit

@ =============================================================================
@ SysTick (never started by v2.05: no STK_LOAD/STK_VAL literal; ported so that no v2.05 code is dropped)
@ =============================================================================

@ -----------------------------------------------------------------------------
@ sys_systick_isr - SysTick handler
@ Replaces : 0x080248B0 SysTick_Handler (v2.05)
@ In/Out   : - / -
@ Clobbers : r0, r1 (exception frame)
@ Context  : SysTick exception
@ -----------------------------------------------------------------------------
FUNC sys_systick_isr
    push {r3, lr}
    bl fn_0800ED0C                          @ 0x080248B2
    pop {r3, pc}
ENDFUNC sys_systick_isr

@ -----------------------------------------------------------------------------
@ fn_0800ED0C - decrement the SysTick countdown 0x20007D10 if it is not zero
@ Replaces : 0x0800ED0C (v2.05)
@ In/Out   : - / -
@ Clobbers : r0, r1
@ Context  : SysTick exception
@ RAM      : 0x20007D10 (u32, read/write)
@ -----------------------------------------------------------------------------
LFUNC fn_0800ED0C
    ldr r1, =v_20007D10
    ldr r0, [r1]
    cbz r0, .Led0c_done
    subs r0, r0, #1
    str r0, [r1]
.Led0c_done:
    bx lr
ENDFUNC fn_0800ED0C

@ =============================================================================
@ NVIC / SCB / DBGMCU / TIM library routines (v2.05 StdPeriph code, same register effects)
@ =============================================================================

@ -----------------------------------------------------------------------------
@ fn_0801BE60 - enable one IRQ in the NVIC (NVIC_EnableIRQ)
@ Replaces : 0x0801BE60 (v2.05), called by BLE (usart2_init 0x0801C436)
@ In       : r0 = IRQ number (signed byte as v2.05)
@ Out      : -
@ Clobbers : r0-r3
@ Context  : main
@ Spec     : PM0056 4.3.2
@ -----------------------------------------------------------------------------
FUNC fn_0801BE60
    movs r1, #1
    and r2, r0, #0x1F
    lsls r1, r1, r2                         @ bit within ISERn
    ldr r2, =NVIC_ISER0
    sxtb r0, r0
    lsrs r3, r0, #5                         @ register index (v2.05 0x0801BE6E)
    str r1, [r2, r3, lsl #2]
    bx lr
ENDFUNC fn_0801BE60

@ -----------------------------------------------------------------------------
@ fn_08020848 - DBGMCU_CR bits on/off (DBGMCU_Config)
@ Replaces : 0x08020848 (v2.05)
@ In       : r0 = mask, r1 = 0 clear, else set
@ Out      : -
@ Clobbers : r1-r3
@ Context  : main
@ Spec     : RM0038 30.16.3
@ -----------------------------------------------------------------------------
FUNC fn_08020848
    uxtb r1, r1
    ldr r3, =DBGMCU_CR
    ldr r2, [r3]
    cbz r1, .L20848_clear
    orrs r2, r2, r0
    str r2, [r3]
    bx lr
.L20848_clear:
    bics r2, r2, r0
    str r2, [r3]
    bx lr
ENDFUNC fn_08020848

@ -----------------------------------------------------------------------------
@ fn_0802086C - priority grouping (NVIC_PriorityGroupConfig): AIRCR = VECTKEY | r0
@ Replaces : 0x0802086C (v2.05)
@ In       : r0 = PRIGROUP field (bits 10:8)
@ Out      : -
@ Clobbers : r1, r2
@ Context  : main
@ Spec     : PM0056 4.4.5
@ -----------------------------------------------------------------------------
LFUNC fn_0802086C
    ldr r1, =SCB_AIRCR_VECTKEY
    orrs r1, r1, r0
    ldr r2, =SCB_AIRCR
    str r1, [r2]
    bx lr
ENDFUNC fn_0802086C

@ -----------------------------------------------------------------------------
@ fn_08020876 - configure one IRQ (NVIC_Init)
@ Replaces : 0x08020876 (v2.05), called by BRD (EXTI arming 0x0801C750)
@ In       : r0 = pointer to bytes {channel, preemption priority, subpriority, enable}
@ Out      : -
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ Spec     : PM0056 4.3.2, 4.3.3, 4.3.7 (priority in bits 7:4)
@ -----------------------------------------------------------------------------
FUNC fn_08020876
    push {r4-r6}
    ldrb r4, [r0, #3]                       @ enable
    cbz r4, .L20876_disable
    ldr r4, =SCB_AIRCR
    ldr r4, [r4]
    and r4, r4, #SCB_AIRCR_PRIGROUP_MASK
    rsb r4, r4, #0x700
    lsrs r3, r4, #8                         @ subpriority bit count (2 for PRIGROUP 5)
    rsb r1, r3, #4                          @ preemption shift
    movs r2, #0xF
    asrs r2, r2, r3                         @ subpriority mask
    ldrb r4, [r0, #1]
    lsls r4, r4, r1                         @ preemption << shift
    ldrb r12, [r0, #2]
    and r12, r12, r2                        @ subpriority & mask
    orr r3, r4, r12
    lsls r3, r3, #4                         @ STM32L1 implements priority bits 7:4
    ldr r4, =NVIC_IPR0
    ldrb r5, [r0]
    strb r3, [r4, r5]                       @ IPR byte of the channel (0x080208B0)
    movs r4, #1
    ldrb r5, [r0]
    and r5, r5, #0x1F
    lsls r4, r4, r5
    ldr r5, =NVIC_ISER0
    ldrb r6, [r0]
    asrs r6, r6, #5
    str r4, [r5, r6, lsl #2]                @ enable (0x080208C2)
    pop {r4-r6}
    bx lr
.L20876_disable:
    movs r4, #1
    ldrb r5, [r0]
    and r5, r5, #0x1F
    lsls r4, r4, r5
    ldr r5, =NVIC_ICER0
    ldrb r6, [r0]
    asrs r6, r6, #5
    str r4, [r5, r6, lsl #2]                @ disable (0x080208D8)
    pop {r4-r6}
    bx lr
ENDFUNC fn_08020876

@ -----------------------------------------------------------------------------
@ fn_08020908 - timer time base (TIM_TimeBaseInit)
@ Replaces : 0x08020908 (v2.05)
@ In       : r0 = TIMx base, r1 = pointer to {u16 prescaler, u16 counter mode, u32 period, u16 clock division}
@ Out      : -
@ Clobbers : r2, r3
@ Context  : main
@ Spec     : RM0038 17.4.1, 17.4.6, 17.4.11, 17.4.12
@ -----------------------------------------------------------------------------
LFUNC fn_08020908
    ldrh r2, [r0, #TIM_CR1]
    cmp r0, #TIM2_BASE                      @ counter mode only on TIM2..TIM5 (0x0802090E..0x08020924)
    beq .L20908_mode
    ldr r3, =TIM3_BASE
    cmp r0, r3
    beq .L20908_mode
    ldr r3, =TIM4_BASE
    cmp r0, r3
    beq .L20908_mode
    ldr r3, =TIM5_BASE
    cmp r0, r3
    bne .L20908_ckd
.L20908_mode:
    movw r3, #TIM_CR1_KEEP_CMS_DIR
    ands r2, r2, r3
    ldrh r3, [r1, #2]
    orrs r2, r2, r3
.L20908_ckd:
    ldr r3, =TIM6_BASE                      @ no clock division on TIM6/TIM7 (0x08020930..0x0802093A)
    cmp r0, r3
    beq .L20908_store
    ldr r3, =TIM7_BASE
    cmp r0, r3
    beq .L20908_store
    movw r3, #TIM_CR1_KEEP_CKD
    ands r2, r2, r3
    ldrh r3, [r1, #8]
    orrs r2, r2, r3
.L20908_store:
    strh r2, [r0, #TIM_CR1]
    ldr r3, [r1, #4]
    str r3, [r0, #TIM_ARR]                  @ period (0x0802094A)
    ldrh r3, [r1]
    strh r3, [r0, #TIM_PSC]                 @ prescaler (0x0802094E)
    movs r3, #TIM_EGR_UG
    strh r3, [r0, #TIM_EGR]                 @ update event loads PSC (0x08020952)
    bx lr
ENDFUNC fn_08020908

@ -----------------------------------------------------------------------------
@ fn_0802096C - timer counter on/off (TIM_Cmd)
@ Replaces : 0x0802096C (v2.05), also called by BRD (0x0801C936, 0x0801C946)
@ In       : r0 = TIMx base, r1 = 0 off, else on
@ Out      : -
@ Clobbers : r1-r3
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0802096C
    uxtb r1, r1
    ldrh r2, [r0, #TIM_CR1]
    cbz r1, .L2096c_off
    orr r2, r2, #TIM_CR1_CEN
    strh r2, [r0, #TIM_CR1]
    bx lr
.L2096c_off:
    movw r3, #0xFFFE
    ands r2, r2, r3                         @ CEN = 0 (0x08020982)
    strh r2, [r0, #TIM_CR1]
    bx lr
ENDFUNC fn_0802096C

@ -----------------------------------------------------------------------------
@ fn_08020988 - timer interrupt enable bits (TIM_ITConfig)
@ Replaces : 0x08020988 (v2.05)
@ In       : r0 = TIMx base, r1 = DIER bits, r2 = 0 clear, else set
@ Out      : -
@ Clobbers : r2, r3
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC fn_08020988
    uxtb r2, r2
    ldrh r3, [r0, #TIM_DIER]
    cbz r2, .L20988_clear
    orrs r3, r3, r1
    strh r3, [r0, #TIM_DIER]
    bx lr
.L20988_clear:
    bics r3, r3, r1
    strh r3, [r0, #TIM_DIER]
    bx lr
ENDFUNC fn_08020988

@ -----------------------------------------------------------------------------
@ fn_0802099E - clear timer interrupt flags (TIM_ClearITPendingBit): SR = ~bits
@ Replaces : 0x0802099E (v2.05), also used by sys_tim2_isr and bzb_tim3_isr
@ In       : r0 = TIMx base, r1 = flag bits
@ Out      : -
@ Clobbers : r1, r2
@ Context  : ISR-safe
@ -----------------------------------------------------------------------------
FUNC fn_0802099E
    uxth r1, r1
    mvns r2, r1
    strh r2, [r0, #TIM_SR]                  @ rc_w0 bits: writing 0 clears, 1 leaves (RM0038 17.4.5)
    bx lr
ENDFUNC fn_0802099E

    .ltorg
