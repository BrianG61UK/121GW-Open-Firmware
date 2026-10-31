@ =============================================================================
@ fault.s - SYS: fault-safe state (DESIGN.md 4.7, NF-14)
@
@ v2.05 hangs in `b .` with every output as it was and PE9 high (HardFault_Handler 0x0802427E, MemManage
@ 0x08024280, BusFault 0x08024282, UsageFault 0x08024284, unused IRQs 0x08029298..0x08029340).  The port makes
@ the outputs safe, powers down through the v2.05 STOP preparation, waits in STOP for a key or dial edge and then
@ requests a system reset, so the bootloader runs and its update path stays reachable.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "config.inc"

    .section .rodata.sys.fault, "a", %progbits
@ PF0..PF2 (HY3131 CK, CS, DI) analog: no MCU output drives an HY3131 input (DESIGN.md 4.7, as HW-02)
sys_fault_desc_hybus:
    GPIO_DESC 0x0007, GPIO_MODE_AN, GPIO_SPEED_400K, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
@ PB7 (NJU6350 DATA) input without pull: the MCU stops driving a line the NJU6350 may drive (DESIGN.md 4.7)
sys_fault_desc_pb7:
    GPIO_DESC 0x0080, GPIO_MODE_IN, GPIO_SPEED_400K, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP

    .section .text.sys.fault, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sys_fault_safe - make the outputs safe, power down, STOP, reset on wake
@ Replaces : 0x0802427E HardFault_Handler, 0x08024280 MemManage_Handler, 0x08024282 BusFault_Handler,
@            0x08024284 UsageFault_Handler, IRQ0..IRQ56 default handlers 0x08029298..0x08029340 (v2.05 `b .`)
@ In       : - (any exception state; the stack contents are not trusted)
@ Out      : does not return (system reset after a wake-up)
@ Clobbers : all
@ Context  : fault / unused IRQ / defect return from sys_main
@ Spec     : DESIGN.md 4.7 order: interrupts off; MSP = 0x20001240; buzzer silent and PE7 low; PF6 low then
@            PE15 high (boost off); PF0..PF2 analog; PB7 input; then the STOP sequence of 3.6 (fn_0801C522: USART2
@            off and PF15 low, LCD blank and off with bounded waits, HW-02, PE9 low, all pins analog, EXTI wake
@            lines); STOP until an armed EXTI line is pending; SCB_AIRCR SYSRESETREQ.
@ Deviation: NF-14
@ -----------------------------------------------------------------------------
FUNC sys_fault_safe
    cpsid i                                 @ nothing may preempt the safe-state sequence
    ldr r0, =__stack_top
    msr msp, r0                             @ MSP = 0x20001240: the stack may be the cause of the fault
    isb
    bl bzb_silence                          @ buzzer state cleared, PE7 low (BZB)
    GPIO_CLR GPIOF_BASE, 0x0040             @ PF6 (ENB, RT9271 boost enable) low first (HW-06 order)
    GPIO_SET GPIOE_BASE, 0x8000             @ then PE15 high: the 15 V path is off
    ldr r1, =sys_fault_desc_hybus
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ PF0..PF2 analog
    ldr r1, =sys_fault_desc_pb7
    ldr r0, =GPIOB_BASE
    bl brd_gpio_init                        @ PB7 input
    bl fn_0801C522                          @ v2.05 STOP preparation (BRD): power-down, PE9 low, analog, EXTI
    movs r1, #2
    movs r0, #1
    bl fn_080207CC                          @ STOP (low-power regulator, WFE) until an armed EXTI line is
                                            @ pending (NF-05); PRIMASK stays set: no handler runs
    ldr r1, =SCB_AIRCR
    ldr r0, [r1]
    and r0, r0, #SCB_AIRCR_PRIGROUP_MASK    @ keep PRIGROUP, VECTKEY required for the write (PM0056 4.4.5)
    ldr r2, =(SCB_AIRCR_VECTKEY | SCB_AIRCR_SYSRESETREQ)
    orrs r0, r0, r2                         @ write key and SYSRESETREQ
    dsb                                     @ every earlier store done before the reset request
    str r0, [r1]
    dsb
.Lsfs_wait:
    b .Lsfs_wait                            @ the reset takes effect within a few cycles
ENDFUNC sys_fault_safe

    .ltorg
