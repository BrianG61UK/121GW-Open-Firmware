@ =============================================================================
@ board.s - BRD: board pin set-up at start and wake, key/dial inputs, fuse inputs, analog pins, PF8 sample
@
@ Replaces board_gpio_init 0x0801C056, gpio_init_pg_inputs 0x0801C2C6, gpio_init_pe10_pe11_inputs 0x0801C368,
@ gpio_init_analog 0x0801C43E and sample_pf8_at_boot 0x0800C28C (v2.05).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .rodata.brd.board, "a", %progbits
@ Pin descriptors of board_gpio_init (v2.05 structures built on the stack at the cited addresses; mode,
@ speed, otype, pupd as v2.05; every output level is written by board_gpio_init before the descriptor is
@ applied, so the descriptors keep the ODR)
brd_desc_pd_out:                            @ PD0, PD1 (PWR_CTL2), PD7 (0x0801C068..0x0801C08A)
    GPIO_DESC 0x0083, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pe_out:                            @ PE5, PE7, PE8, PE9, PE12, PE13, PE15 (0x0801C09E..0x0801C0C2)
    GPIO_DESC 0xB3A0, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pb_clk:                            @ PB6 NJU6350 CLK (v2.05 0x0801C1A8..0x0801C1CA with PB7)
    GPIO_DESC 0x0040, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pb_data:                           @ PB7 NJU6350 DATA: open-drain with the internal pull-up, the
                                            @ configuration RTC uses for every transaction (HW-01, DESIGN.md 4.2;
                                            @ v2.05 push-pull at 0x0801C1CA)
    GPIO_DESC 0x0080, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_OD, GPIO_PUPD_UP, 0, BRD_LEVEL_KEEP
brd_desc_pc_out:                            @ PC11, PC13 (0x0801C1DE..0x0801C202)
    GPIO_DESC 0x2800, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pf_out:                            @ PF4, PF5, PF6 (ENB), PF15 (BLE supply) (0x0801C210..0x0801C234)
    GPIO_DESC 0x8070, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_ph_out:                            @ PH2 (0x0801C242..0x0801C264)
    GPIO_DESC 0x0004, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pa_out:                            @ PA11, PA12 (0x0801C268..0x0801C28C)
    GPIO_DESC 0x1800, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_hy_di:                             @ PF2 HY_DI (0x0801C0FE..0x0801C120)
    GPIO_DESC 0x0004, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_hy_ck:                             @ PF0 HY_CK (0x0801C124..0x0801C146)
    GPIO_DESC 0x0001, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_hy_cs:                             @ PF1 HY_CS (0x0801C14A..0x0801C16C)
    GPIO_DESC 0x0002, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_hy_do:                             @ PF3 HY_DO input with pull-up (0x0801C170..0x0801C18C)
    GPIO_DESC 0x0008, GPIO_MODE_IN, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_UP, 0, BRD_LEVEL_KEEP
brd_desc_pg_high:                           @ PG8..PG15 keys, input pull-up (0x0801C344..0x0801C362)
    GPIO_DESC 0xFF00, GPIO_MODE_IN, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_UP, 0, BRD_LEVEL_KEEP
brd_desc_pe_fuse:                           @ PE10, PE11 fuse comparators, input no pull (0x0801C36C..0x0801C38A)
    GPIO_DESC 0x0C00, GPIO_MODE_IN, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pa_adc:                            @ PA4, PA5 ADC inputs analog (0x0801C442..0x0801C45E)
    GPIO_DESC 0x0030, GPIO_MODE_AN, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pf_an:                             @ PF11, PF13, PF14 analog (0x0801C462..0x0801C480)
    GPIO_DESC 0x6800, GPIO_MODE_AN, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP
brd_desc_pf8_in:                            @ PF8 input pull-up for the sample (0x0800C29A..0x0800C2B8)
    GPIO_DESC 0x0100, GPIO_MODE_IN, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_UP, 0, BRD_LEVEL_KEEP
brd_desc_pf8_an:                            @ PF8 analog after the sample (0x0800C2E4..0x0800C302)
    GPIO_DESC 0x0100, GPIO_MODE_AN, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_NONE, 0, BRD_LEVEL_KEEP

@ PG0..PG7 masks of gpio_init_pg_inputs (0x0801C2F4..0x0801C326): argument -> pins configured.  The argument
@ is the latched one-hot dial value 0x20008065 (or 0); its pin stays as it is.
brd_pg_arg:
    .byte 0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
brd_pg_mask:
    .byte 0xFF, 0x7F, 0xBF, 0xDF, 0xEF, 0xF7, 0xFB, 0xFD, 0xFE

    .section .text.brd.board, "ax", %progbits

@ -----------------------------------------------------------------------------
@ board_gpio_init - all board pins to their run state (cold start and wake from STOP)
@ Replaces : 0x0801C056 board_gpio_init (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : DESIGN.md 4.3 (power order), 4.2; v2.05 order 0x0801C05A..0x0801C2C0 kept, with
@            HW-04: every pin gets its v2.05 board-init level (including the levels of fn_0800FC60(0x64) at
@                   0x0801C2C0 and the later writes 0x0801C294..0x0801C2BC) before it becomes an output;
@            HW-03: the HY3131 bus PF0..PF3 is configured last, after every other pin, preceded by
@                   HY_VDD_SETTLE_US (config.inc, default 0);
@            HW-01: PB7 is configured open-drain.
@            Supply order unchanged: PD1 high (with PD0, PD7) before PE9 high, PE9 high before the HY3131 bus.
@ Deviation: HW-01, HW-03, HW-04
@ -----------------------------------------------------------------------------
FUNC board_gpio_init
    push {r4, lr}
    bl fn_0801BFC6                          @ GPIO clocks on (0x0801C05A)
    movs r0, #0
    bl gpio_init_pg_inputs                  @ PG0..PG15 inputs with pull-up (0x0801C060)
    bl gpio_init_pe10_pe11_inputs           @ 0x0801C064
    @ PD0, PD1, PD7: levels H (PD1 0x0801C094, PD7 0x0801C09C, PD0 and PD7 by fn_0800FC60(0x64)), then outputs
    GPIO_SET GPIOD_BASE, 0x0083
    ldr r1, =brd_desc_pd_out
    ldr r0, =GPIOD_BASE
    bl brd_gpio_init
    @ PE9 H (0x0801C0CE); PE8, PE7, PE12, PE13, PE5 L (0x0801C0D8..0x0801C0FC); PE15 L (0x0801C2A2)
    GPIO_SET GPIOE_BASE, 0x0200
    GPIO_CLR GPIOE_BASE, 0x0100
    GPIO_CLR GPIOE_BASE, 0x0080
    GPIO_CLR GPIOE_BASE, 0x1000
    GPIO_CLR GPIOE_BASE, 0x2000
    GPIO_CLR GPIOE_BASE, 0x0020
    GPIO_CLR GPIOE_BASE, 0x8000
    ldr r1, =brd_desc_pe_out
    ldr r0, =GPIOE_BASE
    bl brd_gpio_init
    @ PB6, PB7 L (0x0801C1D4, 0x0801C1DC), then PB6 push-pull and PB7 open-drain outputs
    GPIO_CLR GPIOB_BASE, 0x0040
    GPIO_CLR GPIOB_BASE, 0x0080
    ldr r1, =brd_desc_pb_clk
    ldr r0, =GPIOB_BASE
    bl brd_gpio_init
    ldr r1, =brd_desc_pb_data
    ldr r0, =GPIOB_BASE
    bl brd_gpio_init
    @ PC13 L (0x0801C20E), PC11 H (fn_0800FC60(0x64): mode != 9)
    GPIO_CLR GPIOC_BASE, 0x2000
    GPIO_SET GPIOC_BASE, 0x0800
    ldr r1, =brd_desc_pc_out
    ldr r0, =GPIOC_BASE
    bl brd_gpio_init
    @ PF15 L (0x0801C240), PF6 L (0x0801C2AA), PF4 H, PF5 H (fn_0800FC60(0x64) default branch)
    GPIO_CLR GPIOF_BASE, 0x8000
    GPIO_CLR GPIOF_BASE, 0x0040
    GPIO_SET GPIOF_BASE, 0x0010
    GPIO_SET GPIOF_BASE, 0x0020
    ldr r1, =brd_desc_pf_out
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init
    @ PH2 L (0x0801C2BC)
    GPIO_CLR GPIOH_BASE, 0x0004
    ldr r1, =brd_desc_ph_out
    ldr r0, =GPIOH_BASE
    bl brd_gpio_init
    @ PA12 H (0x0801C298), PA11 L (0x0801C2B4)
    GPIO_SET GPIOA_BASE, 0x1000
    GPIO_CLR GPIOA_BASE, 0x0800
    ldr r1, =brd_desc_pa_out
    ldr r0, =GPIOA_BASE
    bl brd_gpio_init
    @ v2.05 tail 0x0801C290..0x0801C2C0: the same level writes in the v2.05 order (all already in place, so they
    @ change nothing) and fn_0800FC60(0x64)
    GPIO_SET GPIOA_BASE, 0x1000             @ PA12 H (0x0801C298)
    GPIO_CLR GPIOE_BASE, 0x8000             @ PE15 L (0x0801C2A2)
    GPIO_CLR GPIOF_BASE, 0x0040             @ PF6 L (0x0801C2AA)
    GPIO_CLR GPIOA_BASE, 0x0800             @ PA11 L (0x0801C2B4)
    GPIO_CLR GPIOH_BASE, 0x0004             @ PH2 L (0x0801C2BC)
    movs r0, #0x64
    bl fn_0800FC60                          @ PD0 H, PF4 H, PF5 H, PC11 H, PD7 H (0x0801C2C0)

    @ HW-03: HY3131 bus last.  Levels PF1 H, PF2 H, PF0 L (0x0801C196..0x0801C1A6) before the outputs.
    .if HY_VDD_SETTLE_US > 0
    @ at least HY_VDD_SETTLE_US: each fn_0800ECF6 iteration is 5 instructions, i.e. at least 5 cycles of the
    @ 4.194304 MHz MSI clock (1.19 us), so HY_VDD_SETTLE_US * 0.839 + 1 iterations last at least that long
    DELAY ((HY_VDD_SETTLE_US * 839) / 1000 + 1)
    .endif
    GPIO_SET GPIOF_BASE, 0x0002             @ PF1 (CS) H
    GPIO_SET GPIOF_BASE, 0x0004             @ PF2 (DI) H
    GPIO_CLR GPIOF_BASE, 0x0001             @ PF0 (CK) L
    ldr r1, =brd_desc_hy_di
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ PF2 output (v2.05 order: PF2, PF0, PF1, PF3)
    ldr r1, =brd_desc_hy_ck
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ PF0 output
    ldr r1, =brd_desc_hy_cs
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ PF1 output
    ldr r1, =brd_desc_hy_do
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ PF3 input pull-up
    pop {r4, pc}
ENDFUNC board_gpio_init

@ -----------------------------------------------------------------------------
@ gpio_init_pg_inputs - dial lines PG0..PG7 (except the latched one) and keys PG8..PG15: input pull-up
@ Replaces : 0x0801C2C6 gpio_init_pg_inputs (v2.05)
@ In       : r0 = latched one-hot dial value (0 = configure all of PG0..PG7)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Spec     : analysis/rotary.md; DESIGN.md 3.6
@ Deviation: OF-06 (an argument outside 0/1/2/4/8/0x10/0x20/0x40/0x80 configures no PG0..PG7 pin; v2.05 uses
@            the uninitialised stack word as the pin mask, 0x0801C2F2)
@ -----------------------------------------------------------------------------
FUNC gpio_init_pg_inputs
    push {r4, lr}
    sub sp, sp, #(GPIO_DESC_SIZE + 4)       @ descriptor on the stack, 8-byte alignment kept
    uxtb r0, r0                             @ v2.05 uxtb r4 (0x0801C2CA)
    ldr r1, =brd_pg_arg
    movs r2, #0                             @ r2 = case index
    movs r3, #0                             @ r3 = pin mask (OF-06: 0 when no case matches)
.Lgpi_case:
    ldrb r12, [r1, r2]
    cmp r12, r0
    beq .Lgpi_found
    adds r2, r2, #1
    cmp r2, #9
    blo .Lgpi_case
    b .Lgpi_desc
.Lgpi_found:
    ldr r1, =brd_pg_mask
    ldrb r3, [r1, r2]
.Lgpi_desc:
    str r3, [sp]                            @ mask
    movs r0, #GPIO_MODE_IN
    strb r0, [sp, #4]                       @ mode input (0x0801C32A)
    movs r0, #GPIO_SPEED_40M
    strb r0, [sp, #5]                       @ speed 3 (0x0801C336)
    movs r0, #GPIO_OT_PP
    strb r0, [sp, #6]                       @ otype (not used for inputs)
    movs r0, #GPIO_PUPD_UP
    strb r0, [sp, #7]                       @ pull-up (0x0801C330)
    movs r0, #0
    strb r0, [sp, #8]                       @ af (not used)
    movs r0, #BRD_LEVEL_KEEP
    strb r0, [sp, #9]
    movs r0, #0
    strh r0, [sp, #10]
    mov r1, sp
    ldr r0, =GPIOG_BASE
    bl brd_gpio_init                        @ 0x0801C340
    ldr r1, =brd_desc_pg_high
    ldr r0, =GPIOG_BASE
    bl brd_gpio_init                        @ PG8..PG15 (0x0801C362)
    add sp, sp, #(GPIO_DESC_SIZE + 4)
    pop {r4, pc}
ENDFUNC gpio_init_pg_inputs

@ -----------------------------------------------------------------------------
@ gpio_init_pe10_pe11_inputs - fuse comparator outputs PE10, PE11 as inputs without pull
@ Replaces : 0x0801C368 gpio_init_pe10_pe11_inputs (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC gpio_init_pe10_pe11_inputs
    ldr r1, =brd_desc_pe_fuse
    ldr r0, =GPIOE_BASE
    b brd_gpio_init                         @ tail call
ENDFUNC gpio_init_pe10_pe11_inputs

@ -----------------------------------------------------------------------------
@ gpio_init_analog - ADC inputs PA4, PA5 and PF11, PF13, PF14 analog
@ Replaces : 0x0801C43E gpio_init_analog (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC gpio_init_analog
    push {r4, lr}
    ldr r1, =brd_desc_pa_adc
    ldr r0, =GPIOA_BASE
    bl brd_gpio_init                        @ 0x0801C45E
    ldr r1, =brd_desc_pf_an
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ 0x0801C480
    pop {r4, pc}
ENDFUNC gpio_init_analog

@ -----------------------------------------------------------------------------
@ sample_pf8_at_boot - sample PF8 with pull-up 20 times; fewer than 10 high samples -> 0x20007FDF = 1
@ Replaces : 0x0800C28C sample_pf8_at_boot (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (start-up)
@ RAM      : writes 0x20007FDF (board variant flag, owner BRD)
@ -----------------------------------------------------------------------------
FUNC sample_pf8_at_boot
    push {r4, r5, r6, lr}
    movs r5, #0                             @ r5 = count of high samples
    movs r0, #0
    ldr r1, =v_20007FDF
    strb r0, [r1]                           @ 0x0800C298
    ldr r1, =brd_desc_pf8_in
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ PF8 input pull-up (0x0800C2B8)
    movs r4, #0                             @ r4 = sample index
    ldr r6, =(GPIOF_BASE + GPIO_IDR)        @ 0x40021810
.Lsp8_loop:
    cmp r4, #20
    bge .Lsp8_done
    ldrh r0, [r6]
    tst r0, #0x0100                         @ PF8 (v2.05 lsls #0x17 at 0x0800C2CC)
    it ne                                   @ high sample
    addne r5, r5, #1                        @ count it
    adds r4, r4, #1
    b .Lsp8_loop
.Lsp8_done:
    uxtb r5, r5
    cmp r5, #10
    bge .Lsp8_cfg                           @ 10 or more high samples: flag stays 0
    movs r0, #1
    ldr r1, =v_20007FDF
    strb r0, [r1]                           @ 0x0800C2E2
.Lsp8_cfg:
    ldr r1, =brd_desc_pf8_an
    ldr r0, =GPIOF_BASE
    bl brd_gpio_init                        @ PF8 analog (0x0800C302)
    pop {r4, r5, r6, pc}
ENDFUNC sample_pf8_at_boot

    .ltorg
