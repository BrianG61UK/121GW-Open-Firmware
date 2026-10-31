@ =============================================================================
@ reset.s - SYS: reset entry (DESIGN.md 3.2 steps 1..4)
@
@ Replaces the v2.05 start-up chain Reset_Handler 0x08029174 -> reset_preinit 0x08025F70 -> c_startup 0x0802919C
@ -> cmain 0x0802910C -> low_level_init 0x08029126 -> data_init 0x08028FE4 (zero_init 0x08028CDC, lz77_init
@ 0x080287C0) -> main 0x08024B40.  Carried over as equivalent code (DESIGN.md 6.27, OPT-01): the RAM content at
@ the entry of main is identical (574-byte .data_v205 image = analysis/decompile/ram_init.txt, written by
@ firmware/tools/extract_tables.py into src/sys/data_v205.s; 0x20001240..0x200080FB zero).  Not reachable in
@ either image and therefore not present: cmain's exit path 0x08029122 -> exit 0x0802912A/0x08029130 ->
@ semihosting_exit 0x0802913C (main and sys_main never return).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "config.inc"

    .equ SYS_STACK_CANARY,       0x5354434B   @ pattern of the 4 canary words (DESIGN.md 5.3)
    .equ SYS_STACK_CANARY_ADDR,  0x20000240   @ first word-aligned addresses of the stack region 0x2000023E..

    .global SYS_STACK_CANARY_ADDR
    .global SYS_STACK_CANARY

    .section .text.sys.reset, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sys_reset - reset vector: make the bootloader's state safe, clocks, RAM, then sys_main
@ Replaces : 0x08029174 Reset_Handler, 0x08025F70 reset_preinit (clock part in sys_clock_preinit),
@            0x0802919C c_startup, 0x0802910C cmain, 0x08029126 low_level_init, 0x08028FE4 data_init,
@            0x08028CDC zero_init, 0x080287C0 lz77_init (v2.05)
@ In       : - (entered from the bootloader's blx at 0x080049BE with interrupts enabled, VTOR = 0x08000000,
@            TIM2 and its IRQ28 live, FLASH_PECR = 0x00000004: DESIGN.md 2.1)
@ Out      : does not return
@ Clobbers : all
@ Context  : reset
@ RAM      : writes 0x20000000..0x2000023D (.data_v205), 0x20001240..0x200080FB, .bss_port, canary words
@ Spec     : DESIGN.md 3.2 steps 1..4, 5.3
@ Deviation: NF-12 (IRQs disabled and cleared, VTOR first), NF-13 (PELOCK at reset)
@ -----------------------------------------------------------------------------
FUNC sys_reset
    @ step 1: mask interrupts, disable and clear every NVIC source (the bootloader leaves IRQ28/45/53 enabled
    @ with its own TIM2 handler 0x08004DD4 active, DESIGN.md 2.1)
    @ TIM2 is stopped before the NVIC pending bits are cleared, so an update between the two cannot leave IRQ28
    @ pending (DESIGN.md 3.2 lists the NVIC writes first; the result is the same with no spurious tick)
    cpsid i
    ldr r0, =TIM2_BASE
    movs r1, #0
    strh r1, [r0, #TIM_CR1]                 @ TIM2 counter stopped (RM0038 17.4.1)
    strh r1, [r0, #TIM_DIER]                @ update interrupt off (17.4.4)
    strh r1, [r0, #TIM_SR]                  @ pending update flag cleared (17.4.5)
    mov r1, #0xFFFFFFFF
    ldr r0, =NVIC_ICER0
    str r1, [r0]                            @ ICER0: IRQ 0..31 disabled
    str r1, [r0, #4]                        @ ICER1: IRQ 32..63 disabled
    ldr r0, =NVIC_ICPR0
    str r1, [r0]                            @ ICPR0: pending IRQ 0..31 cleared
    str r1, [r0, #4]                        @ ICPR1: pending IRQ 32..63 cleared
    bl nvm_reset_lock                       @ FLASH_PECR PELOCK = 1 (NVM; RM0038 3.9.2: PRGLOCK and OPTLOCK
                                            @ follow PELOCK)

    @ step 2: own vector table before anything can fault (v2.05 does this only in main, 0x08024B4A)
    mov r1, #(APP_BASE - FLASH_PROG_BASE)   @ offset 0x6000 (v2.05 0x08024B42)
    mov r0, #FLASH_PROG_BASE                @ base 0x08000000 (v2.05 0x08024B46)
    bl nvic_set_vector_table                @ VTOR = 0x08006000
    dsb                                     @ VTOR write complete before any exception can be taken
    isb

    @ step 3: clock pre-initialisation with bounded waits and MSI fallback
    bl sys_clock_preinit

    @ step 4: RAM initialisation
    ldr r0, =__data_v205_load               @ source: image of .data_v205 in flash
    ldr r1, =__data_v205_start              @ 0x20000000
    ldr r2, =__data_v205_end                @ 0x2000023E
.Lsr_copy:                                  @ byte copy, 574 bytes (length not a multiple of 4)
    cmp r1, r2
    bhs .Lsr_copy_done
    ldrb r3, [r0], #1
    strb r3, [r1], #1
    b .Lsr_copy
.Lsr_copy_done:
    movs r3, #0
    ldr r1, =__bss_v205_start               @ 0x20001240
    ldr r2, =__bss_v205_end                 @ 0x200080FC (both word aligned, asserted by the linker script)
.Lsr_zero_v205:
    cmp r1, r2
    bhs .Lsr_zero_v205_done
    str r3, [r1], #4
    b .Lsr_zero_v205
.Lsr_zero_v205_done:
    ldr r1, =__bss_port_start
    ldr r2, =__bss_port_end                 @ word aligned (ALIGN(4) in the linker script)
.Lsr_zero_port:
    cmp r1, r2
    bhs .Lsr_zero_port_done
    str r3, [r1], #4
    b .Lsr_zero_port
.Lsr_zero_port_done:
    ldr r0, =SYS_STACK_CANARY_ADDR
    ldr r1, =SYS_STACK_CANARY
    str r1, [r0]                            @ canary words 0x20000240..0x2000024F (DESIGN.md 5.3)
    str r1, [r0, #4]
    str r1, [r0, #8]
    str r1, [r0, #12]

    .if MPU_GUARD
    bl sys_mpu_guard                        @ Q12: program flash and option bytes read-only through the MPU
    .endif

    @ step 5: sys_main never returns; a return would be a defect, handled as a fault
    bl sys_main
    b sys_fault_safe
ENDFUNC sys_reset

@ -----------------------------------------------------------------------------
@ nvic_set_vector_table - VTOR = base | (offset & 0x1FFFFF80)
@ Replaces : 0x080208E0 nvic_set_vector_table (v2.05)
@ In       : r0 = base (0x08000000), r1 = offset
@ Out      : -
@ Clobbers : r2, r3
@ Context  : reset
@ Spec     : PM0056 4.4.4
@ -----------------------------------------------------------------------------
FUNC nvic_set_vector_table
    ldr r2, =SCB_VTOR_MASK
    ands r2, r2, r1                         @ offset & 0x1FFFFF80 (0x080208E2)
    orrs r2, r2, r0                         @ | base (0x080208E4)
    ldr r3, =SCB_VTOR
    str r2, [r3]
    bx lr
ENDFUNC nvic_set_vector_table

    .if MPU_GUARD
@ -----------------------------------------------------------------------------
@ sys_mpu_guard - MPU regions that make program flash and the option-byte page read-only
@ Replaces : - (new, decision Q12)
@ In/Out   : - / -
@ Clobbers : r0-r2
@ Context  : reset
@ Spec     : PM0056 4.2.6..4.2.9.  Region 0: 0x08000000, 512 KB (SIZE = 18), AP = 110 (read-only at every
@            privilege), executable, normal memory (TEX 000, C 1, B 0).  Region 1: 0x1FF80000, 256 bytes (SIZE = 7),
@            AP = 110, XN.  PRIVDEFENA = 1 keeps the default map for every other address, so RAM, peripherals and
@            the data EEPROM 0x08080000 (outside region 0) are unchanged.  A store into either region raises a
@            MemManage fault (escalated to HardFault: SHCSR is not changed) -> sys_fault_safe.
@ -----------------------------------------------------------------------------
LFUNC sys_mpu_guard
    ldr r2, =MPU_RNR
    movs r0, #0
    str r0, [r2]                            @ region 0
    ldr r0, =FLASH_PROG_BASE
    str r0, [r2, #(MPU_RBAR - MPU_RNR)]     @ base 0x08000000 (VALID = 0: region number from RNR)
    ldr r0, =((6 << 24) | (1 << 17) | (18 << 1) | 1) @ AP = 110, C = 1, SIZE = 18 (512 KB), ENABLE
    str r0, [r2, #(MPU_RASR - MPU_RNR)]
    movs r0, #1
    str r0, [r2]                            @ region 1
    ldr r0, =0x1FF80000
    str r0, [r2, #(MPU_RBAR - MPU_RNR)]     @ option-byte page
    ldr r0, =((1 << 28) | (6 << 24) | (7 << 1) | 1) @ XN, AP = 110, SIZE = 7 (256 bytes), ENABLE
    str r0, [r2, #(MPU_RASR - MPU_RNR)]
    ldr r1, =MPU_CTRL
    movs r0, #(MPU_CTRL_ENABLE | MPU_CTRL_PRIVDEFENA)
    str r0, [r1]
    dsb                                     @ the MPU settings apply to the following accesses
    isb
    bx lr
ENDFUNC sys_mpu_guard
    .endif

    .ltorg
