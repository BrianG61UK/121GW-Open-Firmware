@ =============================================================================
@ isr_tim3.s - BZB: TIM3 update interrupt (IRQ29, every 0.996 ms at MSI 4.194 MHz)
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ BZB_PE7, 0x0080                    @ PE7 = buzzer

    .section .text.bzb.isr_tim3, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bzb_tim3_isr - 1 ms tick: power-on window counter, buzzer pulse countdown and pattern phases
@ Replaces : 0x08024722 IRQ29_Handler (v2.05), step for step; production adds the HY counter restart wait count
@ In/Out   : - / -
@ Clobbers : r0-r3, r12 (stacked by the exception entry)
@ Context  : IRQ29, priority 0x50 (preemption 1); preempts sys_tim2_isr and main
@ RAM      : writes 0x200080CF = 1 (1 ms flag), 0x2000022E (window counter, u16), 0x20007FB4, 0x20008079,
@            0x2000807A; reads 0x2000803A (power-off pending stops the countdown), 0x20007FB6, 0x20008078;
@            production: hy_restart_ticks (HY) decremented while not 0 (this handler is its only decrementer)
@ Spec     : DESIGN.md 3.4 (IRQ29 row), 4.5, 6.4
@ Deviation: IMP-06 (production: the wait of the HY3131 counter restart, v2.05 delay(10000) 0x0800BFCE, is counted
@            in these ticks instead of main-loop passes; see hy3131_counter_restart)
@ -----------------------------------------------------------------------------
FUNC bzb_tim3_isr
    push {r3, lr}
    movs r1, #TIM_SR_UIF
    ldr r0, =TIM3_BASE
    bl fn_0802099E                          @ clear the update flag (0x0802472A)
    movs r0, #1
    ldr r1, =v_200080CF
    strb r0, [r1]                           @ 0x08024734
    ldr r1, =v_2000022E                     @ power-on window counter (0x08024736..0x0802474C)
    ldrh r0, [r1]
    cbz r0, .Lt3_buzz
    subs r0, r0, #1
    strh r0, [r1]
.Lt3_buzz:
    ldr r1, =hy_restart_ticks               @ production: HY counter restart wait (IMP-06)
    ldrb r0, [r1]
    cbz r0, .Lt3_hy
    subs r0, r0, #1
    strb r0, [r1]
.Lt3_hy:
    ldr r1, =v_20007FB4                     @ r1 = pulse countdown address
    ldrh r0, [r1]
    cbz r0, .Lt3_done                       @ no pulse (0x08024756)
    ldr r2, =v_2000803A
    ldrb r2, [r2]
    cbnz r2, .Lt3_done                      @ power-off pending: countdown frozen (0x08024760)
    subs r0, r0, #1
    strh r0, [r1]                           @ 0x0802476E
    uxth r0, r0
    cbnz r0, .Lt3_done                      @ pulse still running (0x08024778)
    movs r0, #0
    ldr r2, =v_20008079
    strb r0, [r2]                           @ buzzer off (0x08024780)
    movs r0, #BZB_PE7
    ldr r2, =(GPIOE_BASE + GPIO_BSRRH)
    strh r0, [r2]                           @ PE7 low (0x08024788)
    ldr r2, =v_2000807A
    ldrb r0, [r2]
    cbz r0, .Lt3_done                       @ no phases left (0x08024792)
    ldr r3, =v_20007FB6
    ldrh r3, [r3]
    strh r3, [r1]                           @ next phase as long as the pulse (0x0802479E)
    subs r0, r0, #1
    strb r0, [r2]                           @ 0x080247AC
    uxtb r0, r0
    tst r0, #1                              @ odd count left: a sounding phase (v2.05 sdiv/mls modulo 2 of a
    beq .Lt3_done                           @ value 0..255 at 0x080247B6..0x080247C0)
    movs r0, #1
    ldr r2, =v_20008079
    strb r0, [r2]                           @ buzzer on (0x080247C6)
    ldr r0, =v_20008078
    ldrb r0, [r0]
    cbz r0, .Lt3_done                       @ buzzer setting off: silent phase
    movs r0, #BZB_PE7
    ldr r2, =(GPIOE_BASE + GPIO_BSRRL)
    strh r0, [r2]                           @ PE7 high (0x080247D4)
.Lt3_done:
    pop {r3, pc}
ENDFUNC bzb_tim3_isr

    .ltorg
