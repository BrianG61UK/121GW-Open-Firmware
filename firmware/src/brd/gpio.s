@ =============================================================================
@ gpio.s - BRD: the only GPIO configuration path of the firmware (DESIGN.md 4.2, 6.2)
@
@ Replaces gpio_init 0x0801BD48, fn_0801BDEC (GPIO_StructInit) and gpio_set_alternate_function 0x0801BE04.
@ Every MODER/OTYPER/OSPEEDR/PUPDR/AFR write of the firmware is made here, after the request has been checked
@ against brd_pin_policy; a request outside the policy is refused as a whole (nothing written) and counted in
@ brd_policy_refusals.  Register order per pin: output level first (BSRR, HW-04), then AFR, OSPEEDR, OTYPER,
@ PUPDR, and MODER last, so a pin never drives before its type, pull and level are set (v2.05 writes MODER
@ first, 0x0801BD86).  Pins are handled one by one in ascending order as v2.05 does.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "config.inc"

    .equ BRD_AF_KEEP, 0xFF                  @ descriptor af value: leave AFR unchanged (gpio_init wrapper)
    .equ BRD_AF_NONE, 0xFF                  @ brd_pin_policy AF number: no alternate function allowed

    .section .bss_port.brd, "aw", %nobits
    .balign 4
@ brd_policy_refusals: number of GPIO requests refused by brd_pin_policy since reset (u32, read by the tests
@ of DESIGN.md 9.4 level 5; owner BRD)
    .global brd_policy_refusals
brd_policy_refusals:
    .space 4

    .section .rodata.brd.gpio, "a", %progbits
    .balign 4
@ -----------------------------------------------------------------------------
@ brd_pin_policy - allowed configurations per port (DESIGN.md 4.2 table and mechanism, 9.3 item 4)
@ One 28-byte entry per port in the order of the port index (base - 0x40020000) / 0x400:
@ A, B, C, D, E, H, F, G.  Entry layout:
@   +0  u16 pins allowed as push-pull output
@   +2  u16 pins allowed as open-drain output
@   +4  u16 pins allowed in alternate-function mode
@   +6  u16 pins allowed as input
@   +8  u16 pins allowed as analog
@   +10 u16 padding
@   +12 u8[16] alternate-function number allowed per pin (0xFF = none; AF0, the reset value, is always
@       accepted by gpio_set_alternate_function because sdio_gpio_deinit 0x08023CD8 writes it)
@ Sources: every gpio_init / gpio_set_alternate_function call of v2.05 (call sites decoded from the listing:
@ board_gpio_init 0x0801C08A..0x0801C28C, gpio_init_pg_inputs 0x0801C340/0x0801C362,
@ gpio_init_pe10_pe11_inputs 0x0801C38A, gpio_init_analog 0x0801C45E/0x0801C480, FUN_0801CA22 0x0801CA4C..
@ 0x0801CA8A, sample_pf8_at_boot 0x0800C2B8/0x0800C302, rtc_data_pin_output 0x08010360,
@ rtc_data_pin_input_pullup 0x08010396, LCD FUN_0801B4D6 0x0801B4F6..0x0801B702, usart2_init 0x0801C3C8..
@ 0x0801C3E0, sdio_gpio_init 0x08023D6A..0x08023DCE, sdio_gpio_deinit 0x08023CFE..0x08023D50) and the port
@ rules of DESIGN.md 4.2: PF3, PE10, PE11 never output or AF; PD6 only AF7 or analog; PC8, PD2 only AF12,
@ input or analog; PH0, PH1 analog only; PA13, PA14 never; PG0..PG15 input or analog; PB7 never push-pull (HW-01).
@ -----------------------------------------------------------------------------
    .global brd_pin_policy
brd_pin_policy:
    @ port A: PA11, PA12 outputs; LCD AF11 on PA1..3, PA6..10, PA15; PA4/PA5 ADC analog; analog everywhere
    @ except PA13/PA14 (SWD, mask 0x9FFF of FUN_0801CA22)
    .hword 0x1800, 0x0000, 0x87CE, 0x0000, 0x9FFF, 0
    .byte 0xFF, 11, 11, 11, 0xFF, 0xFF, 11, 11, 11, 11, 11, 0xFF, 0xFF, 0xFF, 0xFF, 11
    @ port B: PB6 (NJU6350 CLK) output; PB7 (NJU6350 DATA) open-drain output or input (HW-01); LCD AF11 on
    @ PB0, PB1, PB3..PB5, PB8..PB15
    .hword 0x0040, 0x0080, 0xFF3B, 0x0080, 0xFFFF, 0
    .byte 11, 11, 0xFF, 11, 11, 11, 0xFF, 0xFF, 11, 11, 11, 11, 11, 11, 11, 11
    @ port C: PC11 (OHM switch), PC13 (NJU6350 CE) outputs; LCD AF11 on PC0..PC7, PC9, PC10; SD AF12 on PC8
    @ (D0) and PC12 (CK), input after sdio_gpio_deinit
    .hword 0x2800, 0x0000, 0x17FF, 0x1100, 0xFFFF, 0
    .byte 11, 11, 11, 11, 11, 11, 11, 11, 12, 11, 11, 0xFF, 12, 0xFF, 0xFF, 0xFF
    @ port D: PD0, PD1 (PWR_CTL2), PD7 outputs; PD2 SD CMD AF12 or input; PD5/PD6 USART2 AF7; LCD AF11 on
    @ PD8..PD15
    .hword 0x0083, 0x0000, 0xFF64, 0x0004, 0xFFFF, 0
    .byte 0xFF, 0xFF, 12, 0xFF, 0xFF, 7, 7, 0xFF, 11, 11, 11, 11, 11, 11, 11, 11
    @ port E: PE5, PE7 (buzzer), PE8 (backlight), PE9 (PWR_CTL), PE12, PE13, PE15 outputs; PE10/PE11 fuse
    @ comparator inputs; LCD AF11 on PE0..PE3
    .hword 0xB3A0, 0x0000, 0x000F, 0x0C00, 0xFFFF, 0
    .byte 11, 11, 11, 11, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    @ port H: PH2 output; PH0/PH1 (crystal) analog only
    .hword 0x0004, 0x0000, 0x0000, 0x0000, 0xFFFF, 0
    .byte 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    @ port F: PF0..PF2 (HY3131 CK, CS, DI), PF4, PF5, PF6 (ENB), PF15 (BLE supply) outputs; PF3 (HY_DO) and PF8
    @ inputs; PF11, PF13, PF14 and the rest analog
    .hword 0x8077, 0x0000, 0x0000, 0x0108, 0xFFFF, 0
    .byte 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    @ port G: dial and key switches, input or analog only
    .hword 0x0000, 0x0000, 0x0000, 0xFFFF, 0xFFFF, 0
    .byte 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
    .size brd_pin_policy, . - brd_pin_policy

    .equ POL_PP,     0
    .equ POL_OD,     2
    .equ POL_AF,     4
    .equ POL_IN,     6
    .equ POL_AN,     8
    .equ POL_AFNUM,  12
    .equ POL_SIZE,   28

    .section .text.brd.gpio, "ax", %progbits

@ -----------------------------------------------------------------------------
@ brd_policy_entry - policy entry of a GPIO port base
@ In       : r0 = port base (GPIOA..GPIOG)
@ Out      : r0 = address of the brd_pin_policy entry, or 0 if r0 is not a GPIO port base
@ Clobbers : r1, flags
@ Replaces : - (new, policy table access)
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC brd_policy_entry
    ldr r1, =GPIOA_BASE
    subs r0, r0, r1                         @ offset from GPIOA
    bcc .Lbpe_bad                           @ below GPIOA
    lsls r1, r0, #22                        @ low 10 bits of the offset
    bne .Lbpe_bad                           @ not a port base (ports are 0x400 apart)
    lsrs r0, r0, #10                        @ port index
    cmp r0, #8
    bhs .Lbpe_bad
    movs r1, #POL_SIZE
    muls r0, r1, r0
    ldr r1, =brd_pin_policy
    add r0, r0, r1
    bx lr
.Lbpe_bad:
    movs r0, #0
    bx lr
ENDFUNC brd_policy_entry

@ -----------------------------------------------------------------------------
@ brd_gpio_init - checked GPIO configuration (replaces gpio_init + gpio_set_alternate_function)
@ Replaces : 0x0801BD48 gpio_init and 0x0801BE04 gpio_set_alternate_function (v2.05), with the policy check
@ In       : r0 = port base, r1 = pointer to a GPIO_DESC descriptor (macros.inc)
@ Out      : r0 = 0 done, 1 refused by brd_pin_policy (nothing written)
@ Clobbers : r1-r3, r12, flags
@ Context  : main (also sys_fault_safe)
@ RAM      : brd_policy_refusals (+1 on refusal)
@ Spec     : DESIGN.md 4.2, Appendix C.2
@ Deviation: HW-04 (level before MODER), HW-01 (PB7 push-pull refused)
@ -----------------------------------------------------------------------------
FUNC brd_gpio_init
    push {r4-r11, lr}
    sub sp, sp, #4                          @ 8-byte stack alignment at the call below
    mov r4, r0                              @ r4 = port base
    mov r5, r1                              @ r5 = descriptor
    bl brd_policy_entry
    movs r6, r0                             @ r6 = policy entry
    beq .Lbgi_refuse                        @ not a GPIO port
    ldr r7, [r5]                            @ r7 = pin mask
    movw r0, #0xFFFF
    bics r0, r7, r0
    bne .Lbgi_refuse                        @ pin numbers above 15
    ldrb r8, [r5, #4]                       @ r8 = mode
    ldrb r9, [r5, #5]                       @ r9 = speed
    ldrb r10, [r5, #6]                      @ r10 = otype
    ldrb r11, [r5, #7]                      @ r11 = pupd
    cmp r8, #GPIO_MODE_OUT                  @ speed and output type are used only for output and AF modes,
    beq .Lbgi_chk_drive                     @ as v2.05 gpio_init (0x0801BD88), so they are checked only there
    cmp r8, #GPIO_MODE_AF                   @ (v2.05 gpio_init_pg_inputs leaves the otype byte unset)
    bne .Lbgi_chk_pupd
.Lbgi_chk_drive:
    cmp r9, #3
    bhi .Lbgi_refuse                        @ OSPEEDR value 0..3
    cmp r10, #1
    bhi .Lbgi_refuse                        @ OTYPER value 0..1
.Lbgi_chk_pupd:
    cmp r11, #2
    bhi .Lbgi_refuse                        @ PUPDR value 0..2 (3 is reserved, RM0038 7.4.4)
    ldrb r0, [r5, #9]                       @ level
    cmp r0, #BRD_LEVEL_HIGH
    bls .Lbgi_lvl_ok
    cmp r0, #BRD_LEVEL_KEEP
    bne .Lbgi_refuse
.Lbgi_lvl_ok:
    @ mode against the allowed masks
    cmp r8, #GPIO_MODE_IN
    bne .Lbgi_not_in
    ldrh r0, [r6, #POL_IN]
    b .Lbgi_mask
.Lbgi_not_in:
    cmp r8, #GPIO_MODE_OUT
    bne .Lbgi_not_out
    cmp r10, #GPIO_OT_OD
    ite eq                                  @ output: mask depends on the output type
    ldrheq r0, [r6, #POL_OD]                @ open-drain outputs
    ldrhne r0, [r6, #POL_PP]                @ push-pull outputs
    b .Lbgi_mask
.Lbgi_not_out:
    cmp r8, #GPIO_MODE_AF
    bne .Lbgi_not_af
    ldrh r0, [r6, #POL_AF]
    bics r1, r7, r0
    bne .Lbgi_refuse                        @ a pin without an allowed alternate function
    ldrb r2, [r5, #8]                       @ requested AF number
    cmp r2, #BRD_AF_KEEP
    beq .Lbgi_check_ok                      @ AFR left as it is (gpio_init wrapper)
    cmp r2, #15
    bhi .Lbgi_refuse
    add r3, r6, #POL_AFNUM                  @ every pin of the mask must allow exactly this AF number
    movs r12, #0                            @ r12 = pin number
.Lbgi_afchk:
    lsr r1, r7, r12
    tst r1, #1
    beq .Lbgi_afnext
    ldrb r1, [r3, r12]
    cmp r1, r2
    bne .Lbgi_refuse
.Lbgi_afnext:
    add r12, r12, #1
    cmp r12, #16
    blo .Lbgi_afchk
    b .Lbgi_check_ok
.Lbgi_not_af:
    cmp r8, #GPIO_MODE_AN
    bne .Lbgi_refuse                        @ mode value above 3
    ldrh r0, [r6, #POL_AN]
.Lbgi_mask:
    bics r1, r7, r0
    bne .Lbgi_refuse                        @ a pin not allowed in this mode
.Lbgi_check_ok:
    @ HW-04: output level before the pin becomes an output
    cmp r8, #GPIO_MODE_OUT
    bne .Lbgi_pins
    ldrb r0, [r5, #9]
    cmp r0, #BRD_LEVEL_KEEP
    beq .Lbgi_pins
    cmp r0, #BRD_LEVEL_HIGH
    ite eq                                  @ BSRR half: set or reset
    strheq r7, [r4, #GPIO_BSRRL]            @ level high: set the ODR bits
    strhne r7, [r4, #GPIO_BSRRH]            @ level low: reset the ODR bits
.Lbgi_pins:
    @ per pin, ascending: AFR, OSPEEDR, OTYPER, PUPDR, MODER; r12 = pin number
    movs r12, #0
.Lbgi_pin:
    lsr r0, r7, r12
    tst r0, #1
    beq .Lbgi_next
    lsl r3, r12, #1                         @ r3 = 2 * pin (2-bit field shift)
    cmp r8, #GPIO_MODE_AF
    bne .Lbgi_speed
    ldrb r2, [r5, #8]
    cmp r2, #BRD_AF_KEEP
    beq .Lbgi_speed
    lsr r0, r12, #3                         @ AFRL (pins 0..7) or AFRH (8..15)
    add r0, r4, r0, lsl #2
    and r1, r12, #7
    lsls r1, r1, #2                         @ 4-bit field shift
    ldr r6, [r0, #GPIO_AFRL]
    movs r10, #0xF
    lsl r10, r10, r1
    bic r6, r6, r10
    lsl r2, r2, r1
    orr r6, r6, r2
    str r6, [r0, #GPIO_AFRL]
    ldrb r10, [r5, #6]                      @ r10 = otype again (used as scratch above)
.Lbgi_speed:
    cmp r8, #GPIO_MODE_OUT                  @ speed and type only for output and AF modes (v2.05 0x0801BD88)
    beq .Lbgi_drive
    cmp r8, #GPIO_MODE_AF
    bne .Lbgi_pupd
.Lbgi_drive:
    ldr r0, [r4, #GPIO_OSPEEDR]
    movs r1, #3
    lsl r1, r1, r3
    bic r0, r0, r1
    lsl r1, r9, r3
    orr r0, r0, r1
    str r0, [r4, #GPIO_OSPEEDR]
    ldrh r0, [r4, #GPIO_OTYPER]
    movs r1, #1
    lsl r1, r1, r12
    bic r0, r0, r1
    lsl r1, r10, r12
    orr r0, r0, r1
    strh r0, [r4, #GPIO_OTYPER]
.Lbgi_pupd:
    ldr r0, [r4, #GPIO_PUPDR]
    movs r1, #3
    lsl r1, r1, r3
    bic r0, r0, r1
    lsl r1, r11, r3
    orr r0, r0, r1
    str r0, [r4, #GPIO_PUPDR]
    ldr r0, [r4, #GPIO_MODER]               @ MODER last
    movs r1, #3
    lsl r1, r1, r3
    bic r0, r0, r1
    lsl r1, r8, r3
    orr r0, r0, r1
    str r0, [r4, #GPIO_MODER]
.Lbgi_next:
    add r12, r12, #1
    cmp r12, #16
    blo .Lbgi_pin
    movs r0, #0
    b .Lbgi_ret
.Lbgi_refuse:
    ldr r1, =brd_policy_refusals
    ldr r0, [r1]
    adds r0, r0, #1
    str r0, [r1]
    movs r0, #1
.Lbgi_ret:
    add sp, sp, #4
    pop {r4-r11, pc}
ENDFUNC brd_gpio_init

@ -----------------------------------------------------------------------------
@ gpio_init - v2.05 GPIO configuration entry, through the policy check
@ Replaces : 0x0801BD48 gpio_init (v2.05)
@ In       : r0 = port base, r1 = pointer to the v2.05 structure {u32 pin mask, u8 mode, u8 speed, u8 otype,
@            u8 pupd}
@ Out      : r0 = 0 done, 1 refused (v2.05 returns nothing; callers ignore r0)
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ Spec     : DESIGN.md 4.2; the ODR and AFR are left as they are (BRD_LEVEL_KEEP, BRD_AF_KEEP), as v2.05
@ -----------------------------------------------------------------------------
FUNC gpio_init
    push {r4, lr}
    sub sp, sp, #GPIO_DESC_SIZE + 4         @ descriptor on the stack (16 bytes keeps 8-byte alignment)
    ldr r2, [r1]
    str r2, [sp]                            @ pin mask
    ldr r2, [r1, #4]
    str r2, [sp, #4]                        @ mode, speed, otype, pupd (bytes 4..7 as v2.05)
    movs r2, #BRD_AF_KEEP
    strb r2, [sp, #8]                       @ af: keep AFR
    movs r2, #BRD_LEVEL_KEEP
    strb r2, [sp, #9]                       @ level: keep ODR
    movs r2, #0
    strh r2, [sp, #10]
    mov r1, sp
    bl brd_gpio_init
    add sp, sp, #GPIO_DESC_SIZE + 4
    pop {r4, pc}
ENDFUNC gpio_init

@ -----------------------------------------------------------------------------
@ fn_0801BDEC - default v2.05 GPIO structure (GPIO_StructInit)
@ Replaces : 0x0801BDEC (v2.05), called by LCD (0x0801B4E0)
@ In       : r0 = pointer to the v2.05 structure
@ Out      : {0xFFFF, mode 0, speed 0, otype 0, pupd 0}
@ Clobbers : r1
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0801BDEC
    movw r1, #0xFFFF
    str r1, [r0]
    movs r1, #0
    strb r1, [r0, #4]
    strb r1, [r0, #5]
    strb r1, [r0, #6]
    strb r1, [r0, #7]
    bx lr
ENDFUNC fn_0801BDEC

@ -----------------------------------------------------------------------------
@ gpio_set_alternate_function - set the AF number of one pin, through the policy check
@ Replaces : 0x0801BE04 gpio_set_alternate_function (v2.05)
@ In       : r0 = port base, r1 = pin number 0..15, r2 = AF number 0..15
@ Out      : r0 = 0 done, 1 refused (pin without that AF in brd_pin_policy; AF0 always accepted)
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ Spec     : RM0038 7.4.9, 7.4.10; DESIGN.md 4.2
@ -----------------------------------------------------------------------------
FUNC gpio_set_alternate_function
    push {r4-r6, lr}
    mov r4, r0                              @ r4 = port base
    uxth r5, r1                             @ r5 = pin number (v2.05 uxth r1)
    uxtb r6, r2                             @ r6 = AF number (v2.05 uxtb r2)
    bl brd_policy_entry
    cbz r0, .Lgsa_refuse
    cmp r5, #15
    bhi .Lgsa_refuse
    cmp r6, #15
    bhi .Lgsa_refuse
    cbz r6, .Lgsa_write                     @ AF0 = reset value, accepted for every pin
    ldrh r1, [r0, #POL_AF]
    lsr r1, r1, r5
    tst r1, #1
    beq .Lgsa_refuse                        @ pin has no alternate function
    add r0, r0, #POL_AFNUM
    ldrb r1, [r0, r5]
    cmp r1, r6
    bne .Lgsa_refuse                        @ a different AF number than allowed
.Lgsa_write:
    lsrs r0, r5, #3
    add r0, r4, r0, lsl #2                  @ AFRL or AFRH (v2.05 asrs r5,r1,#3)
    and r1, r5, #7
    lsls r1, r1, #2
    ldr r2, [r0, #GPIO_AFRL]
    movs r3, #0xF
    lsls r3, r3, r1
    bics r2, r2, r3                         @ clear the field (v2.05 0x0801BE3E)
    str r2, [r0, #GPIO_AFRL]
    ldr r2, [r0, #GPIO_AFRL]
    lsl r3, r6, r1
    orrs r2, r2, r3                         @ set the AF number (v2.05 0x0801BE4C)
    str r2, [r0, #GPIO_AFRL]
    movs r0, #0
    pop {r4-r6, pc}
.Lgsa_refuse:
    ldr r1, =brd_policy_refusals
    ldr r0, [r1]
    adds r0, r0, #1
    str r0, [r1]
    movs r0, #1
    pop {r4-r6, pc}
ENDFUNC gpio_set_alternate_function

    .ltorg
