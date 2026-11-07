@ =============================================================================
@ macros.inc - assembler macros and interface constants shared by every module (DESIGN.md 8.3)
@
@ Every source file starts with:
@       .syntax unified
@       .cpu cortex-m3
@       .thumb
@       .include "macros.inc"
@ followed by hw.inc, ram_v205.inc and config.inc as needed.
@ =============================================================================

    .ifndef MACROS_INC
    .equ MACROS_INC, 1

@ -----------------------------------------------------------------------------
@ FUNC name / LFUNC name / ENDFUNC name
@ Start a global (FUNC) or file-local (LFUNC) Thumb routine on a halfword boundary; ENDFUNC records its size so
@ the map file, the listing and the routine-level test runner see each routine's extent.
@ -----------------------------------------------------------------------------
    .macro FUNC name
    .global \name
    .type \name, %function
    .align 1
    .thumb_func
\name:
    .endm

    .macro LFUNC name
    .type \name, %function
    .align 1
    .thumb_func
\name:
    .endm

    .macro ENDFUNC name
    .size \name, . - \name
    .endm

@ -----------------------------------------------------------------------------
@ CRIT_ENTER rX / CRIT_EXIT rX
@ Critical section for main-context read-modify-write of a variable that an ISR also writes (DESIGN.md 3.4).
@ CRIT_ENTER saves PRIMASK in rX and masks interrupts; CRIT_EXIT restores the saved PRIMASK, so sections nest.
@ -----------------------------------------------------------------------------
    .macro CRIT_ENTER reg
    mrs \reg, primask                       @ save the interrupt mask state
    cpsid i                                 @ mask all configurable-priority interrupts
    .endm

    .macro CRIT_EXIT reg
    msr primask, \reg                       @ restore the saved mask state (re-enables only if it was enabled)
    .endm

@ -----------------------------------------------------------------------------
@ GPIO_SET port_base, mask [, rv, ra] / GPIO_CLR port_base, mask [, rv, ra]
@ Halfword store of mask to BSRRL (+0x18, set) / BSRRH (+0x1A, reset), as v2.05 drives its outputs (it never
@ writes ODR).  rv/ra are the scratch registers for value and address (default r0, r1).
@ -----------------------------------------------------------------------------
    .macro GPIO_SET base, mask, rv=r0, ra=r1
    ldr \ra, =(\base + 0x18)                @ GPIOx_BSRR low half: 1 = set ODR bit (RM0038 7.4.7)
    .if (\mask) < 256
    movs \rv, #(\mask)
    .else
    movw \rv, #(\mask)
    .endif
    strh \rv, [\ra]
    .endm

    .macro GPIO_CLR base, mask, rv=r0, ra=r1
    ldr \ra, =(\base + 0x1A)                @ GPIOx_BSRR high half: 1 = reset ODR bit (RM0038 7.4.7)
    .if (\mask) < 256
    movs \rv, #(\mask)
    .else
    movw \rv, #(\mask)
    .endif
    strh \rv, [\ra]
    .endm

@ -----------------------------------------------------------------------------
@ DELAY n
@ Busy delay with the v2.05 loop fn_0800ECF6 (n iterations of cmp/bcs/nop/adds/b).  Clobbers r0..r2, lr.
@ -----------------------------------------------------------------------------
    .macro DELAY n
    .if (\n) < 256
    movs r0, #(\n)
    .else
    ldr r0, =(\n)
    .endif
    bl fn_0800ECF6
    .endm

@ -----------------------------------------------------------------------------
@ TABLE_V205 v205_address, length
@ Marks the data that follows as a byte-for-byte copy of the v2.05 image at v205_address (length bytes).  The
@ macro writes one 12-byte record into the non-loaded section .v205tab:
@       word 0  v2.05 address of the table
@       word 1  length in bytes
@       word 2  address of the copy in this image
@ The build check (DESIGN.md 9.3 item 3) compares each copy with inputs/binaries/EEVBlog2_05.bin.
@ Place the macro immediately before the table label; it emits no bytes into the current section.
@ -----------------------------------------------------------------------------
    .macro TABLE_V205 addr, len
    .pushsection .v205tab, "", %progbits
    .balign 4
    .word \addr
    .word \len
    .word 9998f
    .popsection
9998:
    .endm

@ -----------------------------------------------------------------------------
@ NVM_ARM class
@ Arms the NVM module for exactly one following writer call of the given class (DESIGN.md 6.21).
@ class is one of SETTINGS, IDENT, USERZERO, CAL, RESTORE.  Clobbers r0..r3, r12, lr (AAPCS call).
@ -----------------------------------------------------------------------------
    .macro NVM_ARM class
    ldr r0, =NVM_KEY_\class
    bl nvm_arm
    .endm

@ -----------------------------------------------------------------------------
@ GPIO_DESC mask, mode, speed, otype, pupd, af, level
@ Pin descriptor for brd_gpio_init (DESIGN.md Appendix C.2), 12 bytes, word aligned:
@       +0  u32 pin mask (bit n = pin n of the port)
@       +4  u8  mode   GPIO_MODE_IN / _OUT / _AF / _AN (hw.inc, RM0038 7.4.1)
@       +5  u8  speed  OSPEEDR value 0..3 (7.4.3), written for output and AF modes as v2.05 gpio_init does
@       +6  u8  otype  GPIO_OT_PP / GPIO_OT_OD (7.4.2), written for output and AF modes
@       +7  u8  pupd   GPIO_PUPD_NONE / _UP / _DOWN (7.4.4), written for every mode
@       +8  u8  af     alternate function number 0..15 (7.4.9/7.4.10), written for AF mode
@       +9  u8  level  BRD_LEVEL_LOW / BRD_LEVEL_HIGH: ODR bits set through BSRR before MODER (HW-04);
@                      BRD_LEVEL_KEEP: ODR left as it is
@       +10 u16 padding (0)
@ brd_gpio_init checks the descriptor against brd_pin_policy before any register write.
@ -----------------------------------------------------------------------------
    .equ BRD_LEVEL_LOW,  0
    .equ BRD_LEVEL_HIGH, 1
    .equ BRD_LEVEL_KEEP, 0xFF
    .equ GPIO_DESC_SIZE, 12

@ ck_status values (sys/msical.s, IMP-46): the result of the last MSI measurement
    .equ CK_ST_NONE,     0                  @ not run since reset
    .equ CK_ST_OK,       1                  @ measured; ck_hz is the MSI frequency (used for the USART2 baud)
    .equ CK_ST_NOTMSI,   2                  @ SYSCLK was not MSI: nothing measured
    .equ CK_ST_HSEON,    3                  @ HSE was already on (RTCPRE cannot be set): nothing measured
    .equ CK_ST_NOHSE,    4                  @ HSE did not start: nothing measured
    .equ CK_ST_NOCAP,    5                  @ no HSE_RTC captures on TIM11 (or every attempt lost one)
    .equ CK_ST_RANGE,    6                  @ the measured frequency was more than 6 % from 4.194304 MHz
    .equ CK_ST_UNDO,     7                  @ the trimmed clock measured worse: trim taken back, ck_hz is the first value

    .macro GPIO_DESC mask, mode, speed, otype, pupd, af, level
    .balign 4
    .word \mask
    .byte \mode, \speed, \otype, \pupd, \af, \level
    .hword 0
    .endm

    .endif
