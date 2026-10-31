@ =============================================================================
@ exti.s - BRD: wake-up lines (EXTI on the dial and key inputs) and the EXTI / RTC wake-up handlers
@
@ Replaces FUN_0801C61C (arm the PG lines before STOP), FUN_0801C6F4 (arm one line), FUN_0801C756 (line -> IRQ),
@ FUN_0801C7AA (line -> mask), FUN_0801C852 (line -> pin source), the SYSCFG/EXTI library routines 0x08020A74,
@ 0x08020AC8, 0x08020B50, 0x08020B6A, the RTC library routines 0x080209A8, 0x080209FC, 0x08020A46 and the
@ handlers IRQ6..IRQ10 0x080248E8..0x08024938, IRQ23 0x0802494C, IRQ40 0x080249A8, IRQ3 0x080248C8 (v2.05).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.brd.exti, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0801C61C - arm the dial lines PG0..PG7 (except the latched position) and the keys PG8..PG15 as falling-
@               edge EXTI interrupts before STOP
@ Replaces : 0x0801C61C FUN_0801C61C (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (STOP preparation)
@ RAM      : reads 0x20008065 (latched one-hot dial position, owner DIAL)
@ Spec     : DESIGN.md 3.6
@ -----------------------------------------------------------------------------
FUNC fn_0801C61C
    push {r4, r5, r6, lr}
    movs r1, #1
    movs r0, #RCC_AHBENR_GPIOGEN
    bl fn_0801FF80                          @ GPIOG clock on (0x0801C622)
    ldr r0, =v_20008065
    ldrb r0, [r0]
    bl gpio_init_pg_inputs                  @ 0x0801C62C
    movs r1, #1
    movs r0, #RCC_APB2_SYSCFG
    bl fn_0801FF9E                          @ SYSCFG clock on (0x0801C634)
    @ lines 7..0: line n is armed unless the latched value is 1 << (7 - n) (0x0801C638..0x0801C6B4)
    ldr r6, =v_20008065
    movs r4, #7                             @ r4 = line
    movs r5, #1                             @ r5 = one-hot value that excludes line r4
.Lc61c_dial:
    ldrb r0, [r6]                           @ re-read for every line as v2.05 does
    cmp r0, r5
    beq .Lc61c_skip
    mov r0, r4
    bl fn_0801C6F4
.Lc61c_skip:
    lsls r5, r5, #1
    subs r4, r4, #1
    bpl .Lc61c_dial                         @ down to line 0
    @ keys: lines 8..15 always (0x0801C6B8..0x0801C6E4)
    movs r4, #8
.Lc61c_keys:
    mov r0, r4
    bl fn_0801C6F4
    adds r4, r4, #1
    cmp r4, #16
    blo .Lc61c_keys
    pop {r4, r5, r6, pc}
ENDFUNC fn_0801C61C

@ -----------------------------------------------------------------------------
@ fn_0801C6F4 - one PG line: SYSCFG source port G, EXTI falling-edge interrupt, NVIC priority and enable
@ Replaces : 0x0801C6F4 FUN_0801C6F4 (v2.05)
@ In       : r0 = line 0..15
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (STOP preparation)
@ Spec     : RM0038 8.5.3, 10.3; NVIC preemption 0, subpriority = line (masked to 2 bits by fn_08020876)
@ -----------------------------------------------------------------------------
LFUNC fn_0801C6F4
    push {r4-r7, lr}
    sub sp, sp, #12                         @ two structures: [sp] NVIC (4 bytes), [sp+4] EXTI (8 bytes)
    uxtb r4, r0                             @ r4 = line
    mov r0, r4
    bl fn_0801C852                          @ pin source (0x0801C6FC)
    uxtb r1, r0
    movs r0, #EXTI_PORTSOURCE_G
    bl fn_08020A74                          @ SYSCFG EXTI line -> port G (0x0801C708)
    mov r0, r4
    bl fn_0801C7AA                          @ line mask (0x0801C710)
    str r0, [sp, #4]                        @ EXTI line
    movs r0, #0
    strb r0, [sp, #8]                       @ mode: interrupt (offset 0 = EXTI_IMR)
    movs r0, #0x0C
    strb r0, [sp, #9]                       @ trigger: falling (offset 0x0C = EXTI_FTSR)
    movs r0, #1
    strb r0, [sp, #10]                      @ enable
    add r0, sp, #4
    bl fn_08020AC8                          @ EXTI_Init (0x0801C72C)
    mov r0, r4
    bl fn_0801C756                          @ IRQ channel (0x0801C734)
    strb r0, [sp]                           @ channel
    movs r0, #0
    strb r0, [sp, #1]                       @ preemption priority 0
    strb r4, [sp, #2]                       @ subpriority = line
    movs r0, #1
    strb r0, [sp, #3]                       @ enable
    mov r0, sp
    bl fn_08020876                          @ NVIC_Init (0x0801C750)
    add sp, sp, #12
    pop {r4-r7, pc}
ENDFUNC fn_0801C6F4

@ -----------------------------------------------------------------------------
@ fn_0801C756 - IRQ number of an EXTI line
@ Replaces : 0x0801C756 FUN_0801C756 (v2.05)
@ In       : r0 = line
@ Out      : r0 = 6..10 for lines 0..4, 23 for 5..9, 40 for 10..15; any other line: r0 returned unchanged
@            (low byte), as v2.05 (0x0801C77C)
@ Clobbers : r1, r2, flags
@ Context  : main (STOP preparation)
@ -----------------------------------------------------------------------------
LFUNC fn_0801C756
    uxtb r1, r0
    cmp r1, #4
    bhi .Lc756_hi
    adds r0, r1, #IRQ_EXTI0                 @ lines 0..4 -> IRQ 6..10
    b .Lc756_done
.Lc756_hi:
    subs r2, r1, #5
    cmp r2, #4
    bhi .Lc756_hi2
    movs r0, #IRQ_EXTI9_5                   @ lines 5..9 -> IRQ 23
    b .Lc756_done
.Lc756_hi2:
    subs r2, r2, #5
    cmp r2, #5
    bhi .Lc756_done                         @ above 15: unchanged
    movs r0, #IRQ_EXTI15_10                 @ lines 10..15 -> IRQ 40
.Lc756_done:
    uxtb r0, r0
    bx lr
ENDFUNC fn_0801C756

@ -----------------------------------------------------------------------------
@ fn_0801C7AA - EXTI mask of a line
@ Replaces : 0x0801C7AA FUN_0801C7AA (v2.05)
@ In       : r0 = line
@ Out      : r0 = 1 << line for 0..15; any other value returned unchanged (v2.05 0x0801C7E0)
@ Clobbers : r1, flags
@ Context  : main (STOP preparation)
@ -----------------------------------------------------------------------------
LFUNC fn_0801C7AA
    uxtb r1, r0
    cmp r1, #15
    bhi .Lc7aa_done
    movs r0, #1
    lsls r0, r0, r1
.Lc7aa_done:
    bx lr
ENDFUNC fn_0801C7AA

@ -----------------------------------------------------------------------------
@ fn_0801C852 - SYSCFG pin source of an EXTI line (the line number itself)
@ Replaces : 0x0801C852 FUN_0801C852 (v2.05)
@ In       : r0 = line
@ Out      : r0 = line (low byte) for every value, as v2.05 (0..15 by table, others unchanged)
@ Clobbers : none
@ Context  : main (STOP preparation)
@ -----------------------------------------------------------------------------
LFUNC fn_0801C852
    uxtb r0, r0
    bx lr
ENDFUNC fn_0801C852

@ -----------------------------------------------------------------------------
@ fn_08020A74 - EXTI line source port (SYSCFG_EXTILineConfig)
@ Replaces : 0x08020A74 (v2.05)
@ In       : r0 = port source (7 = port G), r1 = pin source 0..15
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main (STOP preparation)
@ Spec     : RM0038 8.5.3..8.5.6
@ -----------------------------------------------------------------------------
LFUNC fn_08020A74
    push {r4}
    uxtb r1, r1
    uxtb r0, r0
    and r2, r1, #3
    lsls r2, r2, #2                         @ field shift
    lsrs r3, r1, #2                         @ EXTICR index
    ldr r4, =SYSCFG_EXTICR1
    add r3, r4, r3, lsl #2
    ldr r4, [r3]
    movs r1, #0xF
    lsls r1, r1, r2
    bics r4, r4, r1                         @ clear the field (0x08020A98)
    str r4, [r3]
    ldr r4, [r3]
    lsls r0, r0, r2
    orrs r4, r4, r0                         @ set the port (0x08020ABC)
    str r4, [r3]
    pop {r4}
    bx lr
ENDFUNC fn_08020A74

@ -----------------------------------------------------------------------------
@ fn_08020AC8 - EXTI line configuration (EXTI_Init)
@ Replaces : 0x08020AC8 (v2.05)
@ In       : r0 = structure {u32 line mask, u8 mode offset (0 IMR, 4 EMR), u8 trigger offset (8 RTSR, 0x0C FTSR,
@            0x10 both), u8 enable}
@ Out      : -
@ Clobbers : r1-r3, flags
@ Context  : main (STOP preparation)
@ Spec     : RM0038 10.3.1..10.3.4
@ -----------------------------------------------------------------------------
LFUNC fn_08020AC8
    ldr r1, =EXTI_BASE
    ldr r3, [r0]                            @ r3 = line mask
    ldrb r2, [r0, #6]
    cbz r2, .L20ac8_off
    ldr r2, [r1, #0]
    bics r2, r2, r3
    str r2, [r1, #0]                        @ IMR bits cleared (0x08020ADE)
    ldr r2, [r1, #4]
    bics r2, r2, r3
    str r2, [r1, #4]                        @ EMR bits cleared (0x08020AEA)
    ldrb r2, [r0, #4]
    ldr r12, [r1, r2]
    orr r12, r12, r3
    str r12, [r1, r2]                       @ IMR or EMR bits set (0x08020AF6)
    ldr r2, [r1, #8]
    bics r2, r2, r3
    str r2, [r1, #8]                        @ RTSR cleared
    ldr r2, [r1, #12]
    bics r2, r2, r3
    str r2, [r1, #12]                       @ FTSR cleared
    ldrb r2, [r0, #5]
    cmp r2, #0x10
    bne .L20ac8_one
    ldr r2, [r1, #8]
    orrs r2, r2, r3
    str r2, [r1, #8]                        @ both edges
    ldr r2, [r1, #12]
    orrs r2, r2, r3
    str r2, [r1, #12]
    bx lr
.L20ac8_one:
    ldr r12, [r1, r2]
    orr r12, r12, r3
    str r12, [r1, r2]                       @ the selected edge register (0x08020B3E)
    bx lr
.L20ac8_off:
    ldrb r2, [r0, #4]
    ldr r12, [r1, r2]
    bic r12, r12, r3
    str r12, [r1, r2]                       @ IMR or EMR bits cleared (0x08020B4C)
    bx lr
ENDFUNC fn_08020AC8

@ -----------------------------------------------------------------------------
@ fn_08020B50 - EXTI pending status of lines (EXTI_GetITStatus as v2.05: EXTI_PR only)
@ Replaces : 0x08020B50 (v2.05)
@ In       : r0 = line mask
@ Out      : r0 = 1 if any of the lines is pending, else 0
@ Clobbers : r1, r2
@ Context  : ISR-safe
@ -----------------------------------------------------------------------------
LFUNC fn_08020B50
    ldr r2, =EXTI_PR
    ldr r2, [r2]
    tst r2, r0
    ite ne                                  @ result from the pending test
    movne r0, #1                            @ pending
    moveq r0, #0                            @ not pending
    bx lr
ENDFUNC fn_08020B50

@ -----------------------------------------------------------------------------
@ fn_08020B6A - clear EXTI pending lines (EXTI_ClearITPendingBit): EXTI_PR = mask (rc_w1)
@ Replaces : 0x08020B6A (v2.05)
@ In       : r0 = line mask
@ Out      : -
@ Clobbers : r1
@ Context  : ISR-safe
@ -----------------------------------------------------------------------------
LFUNC fn_08020B6A
    ldr r1, =EXTI_PR
    str r0, [r1]
    bx lr
ENDFUNC fn_08020B6A

@ -----------------------------------------------------------------------------
@ brd_exti_isr - EXTI handler for IRQ6..IRQ10, IRQ23, IRQ40: clear the pending bits of the handler's lines
@ Replaces : 0x080248E8 IRQ6, 0x080248FC IRQ7, 0x08024910 IRQ8, 0x08024924 IRQ9, 0x08024938 IRQ10,
@            0x0802494C IRQ23 (lines 5..9), 0x080249A8 IRQ40 (lines 10..15) (v2.05).  The active IRQ is taken
@            from IPSR; each line of that IRQ is tested and cleared in ascending order as the v2.05 handlers do.
@ In/Out   : - / -
@ Clobbers : r0-r3, r12 (exception frame)
@ Context  : EXTI IRQs, preemption priority 0 (armed only before STOP; disabled after wake, NF-06)
@ -----------------------------------------------------------------------------
FUNC brd_exti_isr
    push {r4, r5, r6, lr}
    mrs r0, ipsr
    sub r0, r0, #16                         @ IRQ number
    cmp r0, #IRQ_EXTI0
    blo .Lbei_done                          @ not an EXTI IRQ of this table
    cmp r0, #IRQ_EXTI4
    bhi .Lbei_grp
    subs r0, r0, #IRQ_EXTI0                 @ IRQ6..10 -> line 0..4
    movs r4, #1
    lsls r4, r4, r0                         @ first line mask
    mov r5, r4                              @ last line mask
    b .Lbei_loop
.Lbei_grp:
    cmp r0, #IRQ_EXTI9_5
    bne .Lbei_grp2
    movs r4, #0x20                          @ lines 5..9
    mov r5, #0x200
    b .Lbei_loop
.Lbei_grp2:
    cmp r0, #IRQ_EXTI15_10
    bne .Lbei_done                          @ not an EXTI IRQ of this table
    mov r4, #0x400                          @ lines 10..15
    mov r5, #0x8000
.Lbei_loop:                                 @ r4 = present line mask, r5 = last line mask
    mov r0, r4
    bl fn_08020B50
    cbz r0, .Lbei_next
    mov r0, r4
    bl fn_08020B6A
.Lbei_next:
    cmp r4, r5
    beq .Lbei_done
    lsls r4, r4, #1
    b .Lbei_loop
.Lbei_done:
    pop {r4, r5, r6, pc}
ENDFUNC brd_exti_isr

@ -----------------------------------------------------------------------------
@ brd_rtcwkup_isr - RTC wake-up timer interrupt (never enabled by v2.05; ported so that no code is dropped)
@ Replaces : 0x080248C8 IRQ3_Handler (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12 (exception frame)
@ Context  : IRQ3
@ -----------------------------------------------------------------------------
FUNC brd_rtcwkup_isr
    push {r3, lr}
    mov r0, #RTC_IT_WUT
    bl fn_080209FC                          @ RTC_GetITStatus(WUT) (0x080248CE)
    cbz r0, .Lbrw_done
    mov r0, #RTC_IT_WUT
    bl fn_08020A46                          @ RTC_ClearITPendingBit(WUT) (0x080248DA)
    mov r0, #EXTI_LINE20_RTC_WKUP
    bl fn_08020B6A                          @ EXTI line 20 cleared (0x080248E2)
.Lbrw_done:
    pop {r3, pc}
ENDFUNC brd_rtcwkup_isr

@ -----------------------------------------------------------------------------
@ fn_080209A8 - RTC interrupt enable bits (RTC_ITConfig), with the write-protection key sequence
@ Replaces : 0x080209A8 (v2.05)
@ In       : r0 = interrupt bits (RTC_CR bits, bit 2 = TAMPIE in RTC_TAFCR), r1 = 0 disable, else enable
@ Out      : -
@ Clobbers : r1-r3, flags
@ Context  : main (STOP preparation)
@ Spec     : RM0038 20.6.3, 20.6.10, 20.6.17
@ -----------------------------------------------------------------------------
FUNC fn_080209A8
    ldr r3, =RTC_WPR
    movs r2, #RTC_WPR_KEY1
    str r2, [r3]                            @ unlock key 1 (0x080209AC)
    movs r2, #RTC_WPR_KEY2
    str r2, [r3]                            @ unlock key 2 (0x080209B2)
    uxtb r1, r1
    cbz r1, .L209a8_off
    ldr r3, =RTC_CR
    ldr r2, [r3]
    bic r1, r0, #RTC_TAFCR_TAMPIE
    orrs r2, r2, r1
    str r2, [r3]                            @ RTC_CR bits set (0x080209C6)
    ldr r3, =RTC_TAFCR
    ldr r2, [r3]
    and r1, r0, #RTC_TAFCR_TAMPIE
    orrs r2, r2, r1
    str r2, [r3]                            @ 0x080209D4
    b .L209a8_lock
.L209a8_off:
    ldr r3, =RTC_CR
    ldr r2, [r3]
    bic r1, r0, #RTC_TAFCR_TAMPIE
    bics r2, r2, r1
    str r2, [r3]                            @ RTC_CR bits cleared (0x080209E4)
    ldr r3, =RTC_TAFCR
    ldr r2, [r3]
    and r1, r0, #RTC_TAFCR_TAMPIE
    bics r2, r2, r1
    str r2, [r3]                            @ 0x080209F2
.L209a8_lock:
    ldr r3, =RTC_WPR
    movs r2, #RTC_WPR_LOCK
    str r2, [r3]                            @ protection back on (0x080209F8)
    bx lr
ENDFUNC fn_080209A8

@ -----------------------------------------------------------------------------
@ fn_080209FC - RTC interrupt status (RTC_GetITStatus)
@ Replaces : 0x080209FC (v2.05)
@ In       : r0 = interrupt code
@ Out      : r0 = 1 enabled and flag set, else 0
@ Clobbers : r1-r3, r12, flags
@ Context  : IRQ3 (brd_rtcwkup_isr)
@ -----------------------------------------------------------------------------
LFUNC fn_080209FC
    push {r4, r5, r6}
    mov r1, r0                              @ r1 = code
    ldr r4, =RTC_TAFCR
    ldr r4, [r4]
    and r2, r4, #RTC_TAFCR_TAMPIE           @ r2 = TAMPIE (0x08020A0A)
    ldr r4, =RTC_CR
    ldr r4, [r4]
    ands r4, r4, r1                         @ enable bits in RTC_CR
    lsrs r5, r1, #18
    lsr r6, r1, r5                          @ v2.05 0x08020A1A
    and r5, r2, r6, lsr #15
    orr r3, r4, r5                          @ r3 = enabled
    ldr r4, =RTC_ISR
    ldr r4, [r4]
    and r2, r4, r1, lsr #4                  @ r2 = flag bits (0x08020A28)
    movs r0, #0
    cbz r3, .L209fc_done
    lsls r4, r2, #16                        @ low halfword of the flag bits
    beq .L209fc_done
    movs r0, #1
.L209fc_done:
    pop {r4, r5, r6}
    bx lr
ENDFUNC fn_080209FC

@ -----------------------------------------------------------------------------
@ fn_08020A46 - clear RTC interrupt flag (RTC_ClearITPendingBit)
@ Replaces : 0x08020A46 (v2.05)
@ In       : r0 = interrupt code
@ Out      : -
@ Clobbers : r1-r3
@ Context  : IRQ3 (brd_rtcwkup_isr)
@ Spec     : RM0038 20.6.4 (INIT bit 7 kept)
@ -----------------------------------------------------------------------------
LFUNC fn_08020A46
    lsrs r2, r0, #4
    uxth r2, r2
    orr r2, r2, #0x80                       @ v2.05 0x08020A4E
    ldr r1, =RTC_ISR
    ldr r3, [r1]
    and r3, r3, #0x80
    orn r2, r3, r2                          @ ISR = (ISR & INIT) | ~bits (0x08020A5A)
    str r2, [r1]
    bx lr
ENDFUNC fn_08020A46

    .ltorg
