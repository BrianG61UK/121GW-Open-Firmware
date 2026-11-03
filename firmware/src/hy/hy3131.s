@ =============================================================================
@ hy3131.s - HY: HY3131 configuration (row selection, interrupt enable, counter restart)
@
@ Replaces v2.05 FUN_0800B974 0x0800B974, hy3131_load_config_regs 0x0800B994, hy3131_set_irq_enable 0x0800BEAC,
@ hy3131_counter_restart 0x0800BF8C and the two register writes of the peak restart in FUN_0800A7FC (0x0800A872, 0x0800A88C).
@
@ Every row written to the HY3131 comes from the 15 v2.05 tables of hy_rows.s (DESIGN.md 4.1 item 1); the only byte changes are
@ the two v2.05 ones (LowZ AC, OHM range 6 with 0x20007FE0 set).  hy3131_write_regs checks the final frame against the
@ whitelist again (spi.s).  Port RAM of this module: hy_row_r20 / hy_row_r29 = R20 / R29 of the row last written (HW-05),
@ hy_row_valid = 1 once a row has been written, hy_restart_pend = 1 while a counter restart waits for its phases 2 and 3
@ (production), hy_restart_ticks = TIM3 ticks left of that wait (production; counted down by bzb_tim3_isr),
@ hy_refused_count = refused requests.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    @ Production counter restart wait in TIM3 ticks, never shorter than v2.05's delay(10000) at 0x0800BFCA..0x0800BFCE
    @ (17.1 ms, analysis/autorange_and_scheduler.md 5.2 P6, emulator measurement).  TIM3 period = (PSC 260 + 1) x
    @ (ARR 15 + 1) / 4194304 Hz = 0.99564 ms (sys/main.s sys_tim3_base, DESIGN.md 3.3).  The wait is armed at any phase
    @ of the period, so 19 ticks end after more than 18 periods = 17.92 ms (>= 17.1 ms) and at most 19 periods = 18.92 ms.
    .equ HY_RESTART_TICKS, 19

    .section .text.hy.cfg, "ax", %progbits


@ -----------------------------------------------------------------------------
@ hy_check_mode_range - bounds check of (mode, range) before a row is selected
@ Replaces : new (DESIGN.md 4.1 item 2, NF-15)
@ In       : r0 = mode, r1 = range
@ Out      : r0 = 0 valid (mode <= 24 and range < range_count[mode]), 1 refused (counted in hy_refused_count)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x20000000 range_count
@ Spec     : DESIGN.md 4.1 item 2
@ Deviation: NF-15 (v2.05 would send 20 uninitialised stack bytes for a mode above 24, 0x0800BA2E)
@ -----------------------------------------------------------------------------
FUNC hy_check_mode_range
    cmp r0, #24
    bhi .Lcm_bad                            @ no row exists for modes above 24
    ldr r2, =range_count
    ldrb r2, [r2, r0]                       @ number of ranges of this mode
    cmp r1, r2
    bhs .Lcm_bad                            @ range outside the mode's range count
    movs r0, #0
    bx lr
.Lcm_bad:
    push {lr}
    bl hy_note_refusal
    movs r0, #1
    pop {pc}
    .ltorg
ENDFUNC hy_check_mode_range

@ -----------------------------------------------------------------------------
@ fn_0800B974 - apply the HY3131 configuration for (mode, range)
@ Replaces : 0x0800B974 FUN_0800B974 (v2.05)
@ In       : r0 = mode (0..24)
@            r1 = range
@ Out      : r0 = 0 applied, 1 refused (bounds, DESIGN.md 4.1 item 2; v2.05 returns nothing)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : production: writes mdc_first_mean
@ Spec     : analysis/hy3131_model.md 3; DESIGN.md 4.1; analysis/autorange_and_scheduler.md 5.2 P5
@ Deviation: NF-15, IMP-01
@ v2.05 order kept: configuration row, interrupt enable, counter restart (0x0800B982, 0x0800B98A, 0x0800B98E).  A refused step
@ ends the sequence: no INTE or counter write follows a row that was not written.  Production: a completed sequence arms
@ mdc_first_mean (IMP-01 P5: first displayed value of the new configuration from a short mean, MDC).
@ -----------------------------------------------------------------------------
FUNC fn_0800B974
    push {r3, r4, r5, lr}              @ 0x0800B974
    movs r4, r0                             @ r4 = mode
    movs r5, r1                             @ r5 = range
    uxtb r0, r4
    uxtb r1, r5
    bl hy_check_mode_range                  @ NF-15: mode > 24 or range >= range_count[mode] writes nothing
    cbnz r0, .Lap_refused
    uxtb r1, r5
    uxtb r0, r4
    bl hy3131_load_config_regs              @ v2.05 0x0800B982: row into registers 0x20..0x33
    cbnz r0, .Lap_refused                   @ row refused by the frame check
    uxtb r0, r4
    bl hy3131_set_irq_enable                @ v2.05 0x0800B98A: INTF = 0, INTE per mode
    cbnz r0, .Lap_refused
    bl hy3131_counter_restart               @ v2.05 0x0800B98E: counter off, preset, counter on
.if LOOP_V205 == 0
    movs r0, #1
    ldr r1, =mdc_first_mean
    strb r0, [r1]                           @ IMP-01 P5: the first value after this configuration is a short mean (MDC ad1_accumulate_average)
    bl mdc_dcv_reset                        @ IMP-23: the DCV window holds nothing of the previous configuration
.endif
    movs r0, #0
    pop {r3, r4, r5, pc}
.Lap_refused:
    movs r0, #1                             @ refused: nothing further written
    pop {r3, r4, r5, pc}
    .ltorg
ENDFUNC fn_0800B974

@ -----------------------------------------------------------------------------
@ hy3131_load_config_regs - select the 20-byte configuration row and write it to registers 0x20..0x33
@ Replaces : 0x0800B994 hy3131_load_config_regs (v2.05)
@ In       : r0 = mode (0..24)
@            r1 = range
@ Out      : r0 = 0 row written, 1 refused (bounds or frame check)
@ Clobbers : r0-r3, r12, flags (r4-r8 preserved)
@ Context  : main only
@ RAM      : reads  0x200080BA acdc_active, 0x200080BD acdc_use_dcv_cal, 0x200080B9 filter_1khz,
@            0x200080B7 peak_hold, v205_tab_08028F1C, v205_tab_08028FBC, v205_tab_08029150, 0x20007FDF, 0x20007FE0,
@            0x20008098, 0x200080C6, 0x200080C7, 0x200080C4 va_channel
@            writes hy_row_r20, hy_row_r29, hy_row_valid, 0x2000807D
@ Spec     : analysis/hy3131_model.md 3; analysis/hy3131_modes_misc.md 3.1; DESIGN.md 4.1
@ Deviation: NF-15, HW-05
@ Row tables (hy_rows.s): 0x080285BC OHM, 0x080286D0 CAP (PF8), 0x08028748 CAP, 0x080288A0 DCV, 0x08028904 ACV peak, 0x080289C8 ACV,
@ 0x08028D1C AC current / VA current, 0x08028D58 DC VA, 0x08028D94 DC current, 0x08028F1C DCmV/TEMP, 0x08028F44 ACmV,
@ 0x08028F6C ACmV peak, 0x08028F94 DIODE, 0x08028FBC FREQ/PULSE/DUTY, 0x08029150 BEEP.
@ -----------------------------------------------------------------------------
FUNC hy3131_load_config_regs
    stmdb sp!, {r4, r5, r6, r7, r8, lr} @ 0x0800B994
    sub sp, #24                        @ 0x0800B998
    movs r4, r0                        @ 0x0800B99A
    movs r5, r1                        @ 0x0800B99C
    @ ---- NF-15: refuse before anything is selected (mode > 24 or range >= range_count[mode]) ----
    uxtb r0, r4
    uxtb r1, r5
    bl hy_check_mode_range
    cbz r0, .Llc_args_ok
    add sp, #24                             @ refused: release the 20-byte row buffer + padding
    movs r0, #1
    ldmia.w sp!, {r4, r5, r6, r7, r8, pc}
.Llc_args_ok:
    @ r4 = mode, r5 = range, r6 = byte index 0..19, r8 = 20 (row length), stack [sp+0..19] = row buffer
    @ Selection is done byte by byte as in v2.05 (0x0800B9A8..0x0800BE60): for every index the mode ladder picks the
    @ table row and copies byte r6 into the buffer.  Table rows are 20 bytes: row address = table + 20 * row index.
    movs.w r8, #20                     @ 0x0800B99E  row length
    movs r7, #0                        @ 0x0800B9A2  r7 unused scratch (v2.05)
    movs r0, #0                        @ 0x0800B9A4
    movs r6, r0                        @ 0x0800B9A6
.L0800B9A8:                              @ reached from 0x0800BE60 b
    movs r0, r6                        @ 0x0800B9A8
    mov r1, r8                         @ 0x0800B9AA
    uxtb r0, r0                        @ 0x0800B9AC
    uxtb r1, r1                        @ 0x0800B9AE
    cmp r0, r1                         @ 0x0800B9B0
    bcs .L0800BE62                     @ 0x0800B9B2
    @ ---- mode ladder: binary-search compare chain of v2.05 (0x0800B9B6..0x0800BA2E); each target below is one mode ----
    uxtb r4, r4                        @ 0x0800B9B6
    cmp r4, #0                         @ 0x0800B9B8
    beq .L0800BA30                     @ 0x0800B9BA
    cmp r4, #2                         @ 0x0800B9BC
    beq .L0800BC4A                     @ 0x0800B9BE
    bcc .L0800BD56                     @ 0x0800B9C2
    cmp r4, #4                         @ 0x0800B9C6
    beq .L0800BCF4                     @ 0x0800B9C8
    bcc .L0800BD70                     @ 0x0800B9CC
    cmp r4, #6                         @ 0x0800B9D0
    beq .L0800BDDE                     @ 0x0800B9D2
    bcc .L0800BD8A                     @ 0x0800B9D6
    cmp r4, #8                         @ 0x0800B9DA
    beq .L0800BDDE                     @ 0x0800B9DC
    bcc .L0800BDDE                     @ 0x0800B9E0
    cmp r4, #10                        @ 0x0800B9E4
    beq .L0800BDB4                     @ 0x0800B9E6
    bcc .L0800BD9A                     @ 0x0800B9EA
    cmp r4, #12                        @ 0x0800B9EE
    beq .L0800BDEE                     @ 0x0800B9F0
    bcc .L0800BDC4                     @ 0x0800B9F4
    cmp r4, #14                        @ 0x0800B9F8
    beq .L0800BBB6                     @ 0x0800B9FA
    bcc .L0800BB74                     @ 0x0800B9FE
    cmp r4, #16                        @ 0x0800BA02
    beq .L0800BE2C                     @ 0x0800BA04
    bcc .L0800BBF8                     @ 0x0800BA08
    cmp r4, #18                        @ 0x0800BA0C
    beq .L0800BE2C                     @ 0x0800BA0E
    bcc .L0800BE46                     @ 0x0800BA12
    cmp r4, #20                        @ 0x0800BA16
    beq .L0800BE2C                     @ 0x0800BA18
    bcc .L0800BE46                     @ 0x0800BA1C
    cmp r4, #22                        @ 0x0800BA20
    beq .L0800BA9E                     @ 0x0800BA22
    bcc .L0800BE46                     @ 0x0800BA24
    cmp r4, #24                        @ 0x0800BA28
    beq .L0800BB22                     @ 0x0800BA2A
    bcc .L0800BAE0                     @ 0x0800BA2C
    b .L0800BE5E                       @ 0x0800BA2E
.L0800BA30:                              @ reached from 0x0800B9BA beq
    @ ---- mode 0 LowZ: row 3 (offset 0x3C) of the DCV table 0x080288A0 when 0x20008098 = 0 (DC), else row 3 of the ACV
    @      table 0x080289C8 with the two LowZ AC changes: byte 10 |= 0x20, byte 14 = (byte 14 & 0x7F) | 0x20 ----
    ldr r0, =v_20008098                @ 0x0800BA30 pool 0x0800C20C = 0x20008098
    ldrb r0, [r0, #0]                  @ 0x0800BA34
    cmp r0, #0                         @ 0x0800BA36
    beq .L0800BA8A                     @ 0x0800BA38
    ldr r0, =v205_tab_080289C8         @ 0x0800BA3A pool 0x0800C210 = 0x080289C8
    uxtb r6, r6                        @ 0x0800BA3E
    add r0, r6                         @ 0x0800BA40
    ldrb.w r0, [r0, #60]               @ 0x0800BA42
    mov r1, sp                         @ 0x0800BA46
    uxtb r6, r6                        @ 0x0800BA48
    strb r0, [r1, r6]                  @ 0x0800BA4A
    uxtb r6, r6                        @ 0x0800BA4C
    cmp r6, #10                        @ 0x0800BA4E
    bne .L0800BA62                     @ 0x0800BA50
    mov r0, sp                         @ 0x0800BA52
    uxtb r6, r6                        @ 0x0800BA54
    ldrb r0, [r0, r6]                  @ 0x0800BA56
    orrs.w r0, r0, #32                 @ 0x0800BA58
    mov r1, sp                         @ 0x0800BA5C
    uxtb r6, r6                        @ 0x0800BA5E
    strb r0, [r1, r6]                  @ 0x0800BA60
.L0800BA62:                              @ reached from 0x0800BA50 bne
    uxtb r6, r6                        @ 0x0800BA62
    cmp r6, #14                        @ 0x0800BA64
    bne .L0800BA9C                     @ 0x0800BA66
    mov r0, sp                         @ 0x0800BA68
    uxtb r6, r6                        @ 0x0800BA6A
    ldrb r0, [r0, r6]                  @ 0x0800BA6C
    ands.w r0, r0, #127                @ 0x0800BA6E
    mov r1, sp                         @ 0x0800BA72
    uxtb r6, r6                        @ 0x0800BA74
    strb r0, [r1, r6]                  @ 0x0800BA76
    mov r0, sp                         @ 0x0800BA78
    uxtb r6, r6                        @ 0x0800BA7A
    ldrb r0, [r0, r6]                  @ 0x0800BA7C
    orrs.w r0, r0, #32                 @ 0x0800BA7E
    mov r1, sp                         @ 0x0800BA82
    uxtb r6, r6                        @ 0x0800BA84
    strb r0, [r1, r6]                  @ 0x0800BA86
    b .L0800BA9C                       @ 0x0800BA88
.L0800BA8A:                              @ reached from 0x0800BA38 beq
    @ ---- LowZ DC: row 3 of 0x080288A0 (the DCV range 3 row) ----
    ldr r0, =v205_tab_080288A0         @ 0x0800BA8A pool 0x0800C214 = 0x080288A0
    uxtb r6, r6                        @ 0x0800BA8E
    add r0, r6                         @ 0x0800BA90
    ldrb.w r0, [r0, #60]               @ 0x0800BA92
    mov r1, sp                         @ 0x0800BA96
    uxtb r6, r6                        @ 0x0800BA98
    strb r0, [r1, r6]                  @ 0x0800BA9A
.L0800BA9C:                              @ reached from 0x0800BA66 bne, 0x0800BA88 b
    b .L0800BE5E                       @ 0x0800BA9C
.L0800BA9E:                              @ reached from 0x0800BA22 beq
    @ ---- mode 22 DCuVA: va_channel (0x200080C4) = 0: row c6 (0x200080C6) of 0x080288A0; else row c7 (0x200080C7) of
    @      the DC-current VA table 0x08028D58 ----
    ldr r0, =va_channel                @ 0x0800BA9E pool 0x0800C218 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x0800BAA2
    cmp r0, #0                         @ 0x0800BAA4
    bne .L0800BAC4                     @ 0x0800BAA6
    ldr r0, =v205_tab_080288A0         @ 0x0800BAA8 pool 0x0800C214 = 0x080288A0
    ldr r1, =v_200080C6                @ 0x0800BAAC pool 0x0800C21C = 0x200080C6
    ldrb r1, [r1, #0]                  @ 0x0800BAB0
    movs r2, #20                       @ 0x0800BAB2
    muls r1, r2                        @ 0x0800BAB4
    add r0, r1                         @ 0x0800BAB6
    uxtb r6, r6                        @ 0x0800BAB8
    ldrb r0, [r0, r6]                  @ 0x0800BABA
    mov r1, sp                         @ 0x0800BABC
    uxtb r6, r6                        @ 0x0800BABE
    strb r0, [r1, r6]                  @ 0x0800BAC0
    b .L0800BADE                       @ 0x0800BAC2
.L0800BAC4:                              @ reached from 0x0800BAA6 bne
    ldr r0, =v205_tab_08028D58         @ 0x0800BAC4 pool 0x0800C220 = 0x08028D58
    ldr r1, =v_200080C7                @ 0x0800BAC8 pool 0x0800C224 = 0x200080C7
    ldrb r1, [r1, #0]                  @ 0x0800BACC
    movs r2, #20                       @ 0x0800BACE
    muls r1, r2                        @ 0x0800BAD0
    add r0, r1                         @ 0x0800BAD2
    uxtb r6, r6                        @ 0x0800BAD4
    ldrb r0, [r0, r6]                  @ 0x0800BAD6
    mov r1, sp                         @ 0x0800BAD8
    uxtb r6, r6                        @ 0x0800BADA
    strb r0, [r1, r6]                  @ 0x0800BADC
.L0800BADE:                              @ reached from 0x0800BAC2 b
    b .L0800BE5E                       @ 0x0800BADE
.L0800BAE0:                              @ reached from 0x0800BA2C bcc
    @ ---- mode 23 DCmVA: same selection as mode 22 ----
    ldr r0, =va_channel                @ 0x0800BAE0 pool 0x0800C218 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x0800BAE4
    cmp r0, #0                         @ 0x0800BAE6
    bne .L0800BB06                     @ 0x0800BAE8
    ldr r0, =v205_tab_080288A0         @ 0x0800BAEA pool 0x0800C214 = 0x080288A0
    ldr r1, =v_200080C6                @ 0x0800BAEE pool 0x0800C21C = 0x200080C6
    ldrb r1, [r1, #0]                  @ 0x0800BAF2
    movs r2, #20                       @ 0x0800BAF4
    muls r1, r2                        @ 0x0800BAF6
    add r0, r1                         @ 0x0800BAF8
    uxtb r6, r6                        @ 0x0800BAFA
    ldrb r0, [r0, r6]                  @ 0x0800BAFC
    mov r1, sp                         @ 0x0800BAFE
    uxtb r6, r6                        @ 0x0800BB00
    strb r0, [r1, r6]                  @ 0x0800BB02
    b .L0800BB20                       @ 0x0800BB04
.L0800BB06:                              @ reached from 0x0800BAE8 bne
    ldr r0, =v205_tab_08028D58         @ 0x0800BB06 pool 0x0800C220 = 0x08028D58
    ldr r1, =v_200080C7                @ 0x0800BB0A pool 0x0800C224 = 0x200080C7
    ldrb r1, [r1, #0]                  @ 0x0800BB0E
    movs r2, #20                       @ 0x0800BB10
    muls r1, r2                        @ 0x0800BB12
    add r0, r1                         @ 0x0800BB14
    uxtb r6, r6                        @ 0x0800BB16
    ldrb r0, [r0, r6]                  @ 0x0800BB18
    mov r1, sp                         @ 0x0800BB1A
    uxtb r6, r6                        @ 0x0800BB1C
    strb r0, [r1, r6]                  @ 0x0800BB1E
.L0800BB20:                              @ reached from 0x0800BB04 b
    b .L0800BE5E                       @ 0x0800BB20
.L0800BB22:                              @ reached from 0x0800BA2A beq
    @ ---- mode 24 DCVA: va_channel = 0: row c6 of 0x080288A0; else row 0 or 2 of 0x08028D58 (2 when c7 != 0) ----
    ldr r0, =va_channel                @ 0x0800BB22 pool 0x0800C218 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x0800BB26
    cmp r0, #0                         @ 0x0800BB28
    bne .L0800BB48                     @ 0x0800BB2A
    ldr r0, =v205_tab_080288A0         @ 0x0800BB2C pool 0x0800C214 = 0x080288A0
    ldr r1, =v_200080C6                @ 0x0800BB30 pool 0x0800C21C = 0x200080C6
    ldrb r1, [r1, #0]                  @ 0x0800BB34
    movs r2, #20                       @ 0x0800BB36
    muls r1, r2                        @ 0x0800BB38
    add r0, r1                         @ 0x0800BB3A
    uxtb r6, r6                        @ 0x0800BB3C
    ldrb r0, [r0, r6]                  @ 0x0800BB3E
    mov r1, sp                         @ 0x0800BB40
    uxtb r6, r6                        @ 0x0800BB42
    strb r0, [r1, r6]                  @ 0x0800BB44
    b .L0800BB72                       @ 0x0800BB46
.L0800BB48:                              @ reached from 0x0800BB2A bne
    movs r0, #0                        @ 0x0800BB48
    movs r7, r0                        @ 0x0800BB4A
    ldr r0, =v_200080C7                @ 0x0800BB4C pool 0x0800C224 = 0x200080C7
    ldrb r0, [r0, #0]                  @ 0x0800BB50
    cmp r0, #0                         @ 0x0800BB52
    beq .L0800BB5A                     @ 0x0800BB54
    movs r0, #2                        @ 0x0800BB56
    movs r7, r0                        @ 0x0800BB58
.L0800BB5A:                              @ reached from 0x0800BB54 beq
    ldr r0, =v205_tab_08028D58         @ 0x0800BB5A pool 0x0800C220 = 0x08028D58
    uxtb r7, r7                        @ 0x0800BB5E
    movs r1, #20                       @ 0x0800BB60
    mul.w r1, r1, r7                   @ 0x0800BB62
    add r0, r1                         @ 0x0800BB66
    uxtb r6, r6                        @ 0x0800BB68
    ldrb r0, [r0, r6]                  @ 0x0800BB6A
    mov r1, sp                         @ 0x0800BB6C
    uxtb r6, r6                        @ 0x0800BB6E
    strb r0, [r1, r6]                  @ 0x0800BB70
.L0800BB72:                              @ reached from 0x0800BB46 b
    b .L0800BE5E                       @ 0x0800BB72
.L0800BB74:                              @ reached from 0x0800B9FE bcc
    @ ---- mode 13 uVA: va_channel = 0: row c6 of the ACV table 0x080289C8; else row c7 of the AC-current table 0x08028D1C ----
    ldr r0, =va_channel                @ 0x0800BB74 pool 0x0800C218 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x0800BB78
    cmp r0, #0                         @ 0x0800BB7A
    bne .L0800BB9A                     @ 0x0800BB7C
    ldr r0, =v205_tab_080289C8         @ 0x0800BB7E pool 0x0800C210 = 0x080289C8
    ldr r1, =v_200080C6                @ 0x0800BB82 pool 0x0800C21C = 0x200080C6
    ldrb r1, [r1, #0]                  @ 0x0800BB86
    movs r2, #20                       @ 0x0800BB88
    muls r1, r2                        @ 0x0800BB8A
    add r0, r1                         @ 0x0800BB8C
    uxtb r6, r6                        @ 0x0800BB8E
    ldrb r0, [r0, r6]                  @ 0x0800BB90
    mov r1, sp                         @ 0x0800BB92
    uxtb r6, r6                        @ 0x0800BB94
    strb r0, [r1, r6]                  @ 0x0800BB96
    b .L0800BBB4                       @ 0x0800BB98
.L0800BB9A:                              @ reached from 0x0800BB7C bne
    ldr r0, =v205_tab_08028D1C         @ 0x0800BB9A pool 0x0800C228 = 0x08028D1C
    ldr r1, =v_200080C7                @ 0x0800BB9E pool 0x0800C224 = 0x200080C7
    ldrb r1, [r1, #0]                  @ 0x0800BBA2
    movs r2, #20                       @ 0x0800BBA4
    muls r1, r2                        @ 0x0800BBA6
    add r0, r1                         @ 0x0800BBA8
    uxtb r6, r6                        @ 0x0800BBAA
    ldrb r0, [r0, r6]                  @ 0x0800BBAC
    mov r1, sp                         @ 0x0800BBAE
    uxtb r6, r6                        @ 0x0800BBB0
    strb r0, [r1, r6]                  @ 0x0800BBB2
.L0800BBB4:                              @ reached from 0x0800BB98 b
    b .L0800BE5E                       @ 0x0800BBB4
.L0800BBB6:                              @ reached from 0x0800B9FA beq
    @ ---- mode 14 mVA: same selection as mode 13 ----
    ldr r0, =va_channel                @ 0x0800BBB6 pool 0x0800C218 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x0800BBBA
    cmp r0, #0                         @ 0x0800BBBC
    bne .L0800BBDC                     @ 0x0800BBBE
    ldr r0, =v205_tab_080289C8         @ 0x0800BBC0 pool 0x0800C210 = 0x080289C8
    ldr r1, =v_200080C6                @ 0x0800BBC4 pool 0x0800C21C = 0x200080C6
    ldrb r1, [r1, #0]                  @ 0x0800BBC8
    movs r2, #20                       @ 0x0800BBCA
    muls r1, r2                        @ 0x0800BBCC
    add r0, r1                         @ 0x0800BBCE
    uxtb r6, r6                        @ 0x0800BBD0
    ldrb r0, [r0, r6]                  @ 0x0800BBD2
    mov r1, sp                         @ 0x0800BBD4
    uxtb r6, r6                        @ 0x0800BBD6
    strb r0, [r1, r6]                  @ 0x0800BBD8
    b .L0800BBF6                       @ 0x0800BBDA
.L0800BBDC:                              @ reached from 0x0800BBBE bne
    ldr r0, =v205_tab_08028D1C         @ 0x0800BBDC pool 0x0800C228 = 0x08028D1C
    ldr r1, =v_200080C7                @ 0x0800BBE0 pool 0x0800C224 = 0x200080C7
    ldrb r1, [r1, #0]                  @ 0x0800BBE4
    movs r2, #20                       @ 0x0800BBE6
    muls r1, r2                        @ 0x0800BBE8
    add r0, r1                         @ 0x0800BBEA
    uxtb r6, r6                        @ 0x0800BBEC
    ldrb r0, [r0, r6]                  @ 0x0800BBEE
    mov r1, sp                         @ 0x0800BBF0
    uxtb r6, r6                        @ 0x0800BBF2
    strb r0, [r1, r6]                  @ 0x0800BBF4
.L0800BBF6:                              @ reached from 0x0800BBDA b
    b .L0800BE5E                       @ 0x0800BBF6
.L0800BBF8:                              @ reached from 0x0800BA08 bcc
    @ ---- mode 15 VA: va_channel = 0: row c6 of 0x080289C8; else row 0 or 2 (2 when c7 != 0) of 0x08028D1C ----
    ldr r0, =va_channel                @ 0x0800BBF8 pool 0x0800C218 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x0800BBFC
    cmp r0, #0                         @ 0x0800BBFE
    bne .L0800BC1E                     @ 0x0800BC00
    ldr r0, =v205_tab_080289C8         @ 0x0800BC02 pool 0x0800C210 = 0x080289C8
    ldr r1, =v_200080C6                @ 0x0800BC06 pool 0x0800C21C = 0x200080C6
    ldrb r1, [r1, #0]                  @ 0x0800BC0A
    movs r2, #20                       @ 0x0800BC0C
    muls r1, r2                        @ 0x0800BC0E
    add r0, r1                         @ 0x0800BC10
    uxtb r6, r6                        @ 0x0800BC12
    ldrb r0, [r0, r6]                  @ 0x0800BC14
    mov r1, sp                         @ 0x0800BC16
    uxtb r6, r6                        @ 0x0800BC18
    strb r0, [r1, r6]                  @ 0x0800BC1A
    b .L0800BC48                       @ 0x0800BC1C
.L0800BC1E:                              @ reached from 0x0800BC00 bne
    movs r0, #0                        @ 0x0800BC1E
    movs r7, r0                        @ 0x0800BC20
    ldr r0, =v_200080C7                @ 0x0800BC22 pool 0x0800C224 = 0x200080C7
    ldrb r0, [r0, #0]                  @ 0x0800BC26
    cmp r0, #0                         @ 0x0800BC28
    beq .L0800BC30                     @ 0x0800BC2A
    movs r0, #2                        @ 0x0800BC2C
    movs r7, r0                        @ 0x0800BC2E
.L0800BC30:                              @ reached from 0x0800BC2A beq
    ldr r0, =v205_tab_08028D1C         @ 0x0800BC30 pool 0x0800C228 = 0x08028D1C
    uxtb r7, r7                        @ 0x0800BC34
    movs r1, #20                       @ 0x0800BC36
    mul.w r1, r1, r7                   @ 0x0800BC38
    add r0, r1                         @ 0x0800BC3C
    uxtb r6, r6                        @ 0x0800BC3E
    ldrb r0, [r0, r6]                  @ 0x0800BC40
    mov r1, sp                         @ 0x0800BC42
    uxtb r6, r6                        @ 0x0800BC44
    strb r0, [r1, r6]                  @ 0x0800BC46
.L0800BC48:                              @ reached from 0x0800BC1C b
    b .L0800BE5E                       @ 0x0800BC48
.L0800BC4A:                              @ reached from 0x0800B9BE beq
    @ ---- mode 2 ACV: AC+DC (0x200080BA) set: 0x080288A0 (DCV rows) when 0x200080BD set, else 0x080289C8;
    @      AC+DC clear: 0x080289C8 when the 1 kHz filter (0x200080B9) is set; otherwise PEAK (0x200080B7) set: peak table
    @      0x08028904, else 0x080289C8; row = range ----
    ldr r0, =acdc_active               @ 0x0800BC4A pool 0x0800C22C = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x0800BC4E
    cmp r0, #0                         @ 0x0800BC50
    beq .L0800BC92                     @ 0x0800BC52
    ldr r0, =acdc_use_dcv_cal          @ 0x0800BC54 pool 0x0800C230 = 0x200080BD
    ldrb r0, [r0, #0]                  @ 0x0800BC58
    cmp r0, #0                         @ 0x0800BC5A
    beq .L0800BC78                     @ 0x0800BC5C
    ldr r0, =v205_tab_080288A0         @ 0x0800BC5E pool 0x0800C214 = 0x080288A0
    uxtb r5, r5                        @ 0x0800BC62
    movs r1, #20                       @ 0x0800BC64
    mul.w r1, r1, r5                   @ 0x0800BC66
    add r0, r1                         @ 0x0800BC6A
    uxtb r6, r6                        @ 0x0800BC6C
    ldrb r0, [r0, r6]                  @ 0x0800BC6E
    mov r1, sp                         @ 0x0800BC70
    uxtb r6, r6                        @ 0x0800BC72
    strb r0, [r1, r6]                  @ 0x0800BC74
    b .L0800BCF2                       @ 0x0800BC76
.L0800BC78:                              @ reached from 0x0800BC5C beq
    ldr r0, =v205_tab_080289C8         @ 0x0800BC78 pool 0x0800C210 = 0x080289C8
    uxtb r5, r5                        @ 0x0800BC7C
    movs r1, #20                       @ 0x0800BC7E
    mul.w r1, r1, r5                   @ 0x0800BC80
    add r0, r1                         @ 0x0800BC84
    uxtb r6, r6                        @ 0x0800BC86
    ldrb r0, [r0, r6]                  @ 0x0800BC88
    mov r1, sp                         @ 0x0800BC8A
    uxtb r6, r6                        @ 0x0800BC8C
    strb r0, [r1, r6]                  @ 0x0800BC8E
    b .L0800BCF2                       @ 0x0800BC90
.L0800BC92:                              @ reached from 0x0800BC52 beq
    ldr r0, =filter_1khz               @ 0x0800BC92 pool 0x0800C234 = 0x200080B9
    ldrb r0, [r0, #0]                  @ 0x0800BC96
    cmp r0, #0                         @ 0x0800BC98
    beq .L0800BCB6                     @ 0x0800BC9A
    ldr r0, =v205_tab_080289C8         @ 0x0800BC9C pool 0x0800C210 = 0x080289C8
    uxtb r5, r5                        @ 0x0800BCA0
    movs r1, #20                       @ 0x0800BCA2
    mul.w r1, r1, r5                   @ 0x0800BCA4
    add r0, r1                         @ 0x0800BCA8
    uxtb r6, r6                        @ 0x0800BCAA
    ldrb r0, [r0, r6]                  @ 0x0800BCAC
    mov r1, sp                         @ 0x0800BCAE
    uxtb r6, r6                        @ 0x0800BCB0
    strb r0, [r1, r6]                  @ 0x0800BCB2
    b .L0800BCF2                       @ 0x0800BCB4
.L0800BCB6:                              @ reached from 0x0800BC9A beq
    ldr r0, =peak_hold                 @ 0x0800BCB6 pool 0x0800C238 = 0x200080B7
    ldrb r0, [r0, #0]                  @ 0x0800BCBA
    cmp r0, #0                         @ 0x0800BCBC
    beq .L0800BCDA                     @ 0x0800BCBE
    ldr r0, =v205_tab_08028904         @ 0x0800BCC0 pool 0x0800C23C = 0x08028904
    uxtb r5, r5                        @ 0x0800BCC4
    movs r1, #20                       @ 0x0800BCC6
    mul.w r1, r1, r5                   @ 0x0800BCC8
    add r0, r1                         @ 0x0800BCCC
    uxtb r6, r6                        @ 0x0800BCCE
    ldrb r0, [r0, r6]                  @ 0x0800BCD0
    mov r1, sp                         @ 0x0800BCD2
    uxtb r6, r6                        @ 0x0800BCD4
    strb r0, [r1, r6]                  @ 0x0800BCD6
    b .L0800BCF2                       @ 0x0800BCD8
.L0800BCDA:                              @ reached from 0x0800BCBE beq
    ldr r0, =v205_tab_080289C8         @ 0x0800BCDA pool 0x0800C210 = 0x080289C8
    uxtb r5, r5                        @ 0x0800BCDE
    movs r1, #20                       @ 0x0800BCE0
    mul.w r1, r1, r5                   @ 0x0800BCE2
    add r0, r1                         @ 0x0800BCE6
    uxtb r6, r6                        @ 0x0800BCE8
    ldrb r0, [r0, r6]                  @ 0x0800BCEA
    mov r1, sp                         @ 0x0800BCEC
    uxtb r6, r6                        @ 0x0800BCEE
    strb r0, [r1, r6]                  @ 0x0800BCF0
.L0800BCF2:                              @ reached from 0x0800BC76 b, 0x0800BC90 b, 0x0800BCB4 b, 0x0800BCD8 b
    b .L0800BE5E                       @ 0x0800BCF2
.L0800BCF4:                              @ reached from 0x0800B9C8 beq
    @ ---- mode 4 ACmV: filter set: 0x08028F44; filter clear: PEAK set: 0x08028F6C, else 0x08028F44; row = range ----
    ldr r0, =filter_1khz               @ 0x0800BCF4 pool 0x0800C234 = 0x200080B9
    ldrb r0, [r0, #0]                  @ 0x0800BCF8
    cmp r0, #0                         @ 0x0800BCFA
    beq .L0800BD18                     @ 0x0800BCFC
    ldr r0, =v205_tab_08028F44         @ 0x0800BCFE pool 0x0800C240 = 0x08028F44
    uxtb r5, r5                        @ 0x0800BD02
    movs r1, #20                       @ 0x0800BD04
    mul.w r1, r1, r5                   @ 0x0800BD06
    add r0, r1                         @ 0x0800BD0A
    uxtb r6, r6                        @ 0x0800BD0C
    ldrb r0, [r0, r6]                  @ 0x0800BD0E
    mov r1, sp                         @ 0x0800BD10
    uxtb r6, r6                        @ 0x0800BD12
    strb r0, [r1, r6]                  @ 0x0800BD14
    b .L0800BD54                       @ 0x0800BD16
.L0800BD18:                              @ reached from 0x0800BCFC beq
    ldr r0, =peak_hold                 @ 0x0800BD18 pool 0x0800C238 = 0x200080B7
    ldrb r0, [r0, #0]                  @ 0x0800BD1C
    cmp r0, #0                         @ 0x0800BD1E
    beq .L0800BD3C                     @ 0x0800BD20
    ldr r0, =v205_tab_08028F6C         @ 0x0800BD22 pool 0x0800C244 = 0x08028F6C
    uxtb r5, r5                        @ 0x0800BD26
    movs r1, #20                       @ 0x0800BD28
    mul.w r1, r1, r5                   @ 0x0800BD2A
    add r0, r1                         @ 0x0800BD2E
    uxtb r6, r6                        @ 0x0800BD30
    ldrb r0, [r0, r6]                  @ 0x0800BD32
    mov r1, sp                         @ 0x0800BD34
    uxtb r6, r6                        @ 0x0800BD36
    strb r0, [r1, r6]                  @ 0x0800BD38
    b .L0800BD54                       @ 0x0800BD3A
.L0800BD3C:                              @ reached from 0x0800BD20 beq
    ldr r0, =v205_tab_08028F44         @ 0x0800BD3C pool 0x0800C240 = 0x08028F44
    uxtb r5, r5                        @ 0x0800BD40
    movs r1, #20                       @ 0x0800BD42
    mul.w r1, r1, r5                   @ 0x0800BD44
    add r0, r1                         @ 0x0800BD48
    uxtb r6, r6                        @ 0x0800BD4A
    ldrb r0, [r0, r6]                  @ 0x0800BD4C
    mov r1, sp                         @ 0x0800BD4E
    uxtb r6, r6                        @ 0x0800BD50
    strb r0, [r1, r6]                  @ 0x0800BD52
.L0800BD54:                              @ reached from 0x0800BD16 b, 0x0800BD3A b
    @ ---- mode 1 DCV: row = range of 0x080288A0 ----
    b .L0800BE5E                       @ 0x0800BD54
.L0800BD56:                              @ reached from 0x0800B9C2 bcc
    ldr r0, =v205_tab_080288A0         @ 0x0800BD56 pool 0x0800C214 = 0x080288A0
    uxtb r5, r5                        @ 0x0800BD5A
    movs r1, #20                       @ 0x0800BD5C
    mul.w r1, r1, r5                   @ 0x0800BD5E
    add r0, r1                         @ 0x0800BD62
    uxtb r6, r6                        @ 0x0800BD64
    ldrb r0, [r0, r6]                  @ 0x0800BD66
    mov r1, sp                         @ 0x0800BD68
    uxtb r6, r6                        @ 0x0800BD6A
    strb r0, [r1, r6]                  @ 0x0800BD6C
    b .L0800BE5E                       @ 0x0800BD6E
.L0800BD70:                              @ reached from 0x0800B9CC bcc
    ldr r0, =v205_tab_08028F1C         @ 0x0800BD70 pool 0x0800C248 = 0x08028F1C
    uxtb r5, r5                        @ 0x0800BD74
    movs r1, #20                       @ 0x0800BD76
    mul.w r1, r1, r5                   @ 0x0800BD78
    add r0, r1                         @ 0x0800BD7C
    uxtb r6, r6                        @ 0x0800BD7E
    ldrb r0, [r0, r6]                  @ 0x0800BD80
    mov r1, sp                         @ 0x0800BD82
    uxtb r6, r6                        @ 0x0800BD84
    strb r0, [r1, r6]                  @ 0x0800BD86
    b .L0800BE5E                       @ 0x0800BD88
.L0800BD8A:                              @ reached from 0x0800B9D6 bcc
    ldr r0, =v205_tab_08028F1C         @ 0x0800BD8A pool 0x0800C248 = 0x08028F1C
    uxtb r6, r6                        @ 0x0800BD8E
    ldrb r0, [r0, r6]                  @ 0x0800BD90
    mov r1, sp                         @ 0x0800BD92
    uxtb r6, r6                        @ 0x0800BD94
    strb r0, [r1, r6]                  @ 0x0800BD96
    b .L0800BE5E                       @ 0x0800BD98
.L0800BD9A:                              @ reached from 0x0800B9EA bcc
    ldr r0, =v205_tab_080285BC         @ 0x0800BD9A pool 0x0800C24C = 0x080285BC
    uxtb r5, r5                        @ 0x0800BD9E
    movs r1, #20                       @ 0x0800BDA0
    mul.w r1, r1, r5                   @ 0x0800BDA2
    add r0, r1                         @ 0x0800BDA6
    uxtb r6, r6                        @ 0x0800BDA8
    ldrb r0, [r0, r6]                  @ 0x0800BDAA
    mov r1, sp                         @ 0x0800BDAC
    uxtb r6, r6                        @ 0x0800BDAE
    strb r0, [r1, r6]                  @ 0x0800BDB0
    b .L0800BE5E                       @ 0x0800BDB2
.L0800BDB4:                              @ reached from 0x0800B9E6 beq
    @ ---- mode 10 BEEP: the single row of 0x08029150 ----
    ldr r0, =v205_tab_08029150         @ 0x0800BDB4 pool 0x0800C250 = 0x08029150
    uxtb r6, r6                        @ 0x0800BDB8
    ldrb r0, [r0, r6]                  @ 0x0800BDBA
    mov r1, sp                         @ 0x0800BDBC
    uxtb r6, r6                        @ 0x0800BDBE
    strb r0, [r1, r6]                  @ 0x0800BDC0
    b .L0800BE5E                       @ 0x0800BDC2
.L0800BDC4:                              @ reached from 0x0800B9F4 bcc
    @ ---- mode 11 DIODE: row = range of 0x08028F94 ----
    ldr r0, =v205_tab_08028F94         @ 0x0800BDC4 pool 0x0800C254 = 0x08028F94
    uxtb r5, r5                        @ 0x0800BDC8
    movs r1, #20                       @ 0x0800BDCA
    mul.w r1, r1, r5                   @ 0x0800BDCC
    add r0, r1                         @ 0x0800BDD0
    uxtb r6, r6                        @ 0x0800BDD2
    ldrb r0, [r0, r6]                  @ 0x0800BDD4
    mov r1, sp                         @ 0x0800BDD6
    uxtb r6, r6                        @ 0x0800BDD8
    strb r0, [r1, r6]                  @ 0x0800BDDA
    b .L0800BE5E                       @ 0x0800BDDC
.L0800BDDE:                              @ reached from 0x0800B9D2 beq, 0x0800B9DC beq, 0x0800B9E0 bcc
    @ ---- modes 6, 7, 8 FREQ, PULSE, DUTY: the single row of 0x08028FBC ----
    ldr r0, =v205_tab_08028FBC         @ 0x0800BDDE pool 0x0800C258 = 0x08028FBC
    uxtb r6, r6                        @ 0x0800BDE2
    ldrb r0, [r0, r6]                  @ 0x0800BDE4
    mov r1, sp                         @ 0x0800BDE6
    uxtb r6, r6                        @ 0x0800BDE8
    strb r0, [r1, r6]                  @ 0x0800BDEA
    b .L0800BE5E                       @ 0x0800BDEC
.L0800BDEE:                              @ reached from 0x0800B9F0 beq
    @ ---- mode 12 CAP: 0x20007FDF (PF8 strap) set: table 0x080286D0, clear: 0x08028748; row = range ----
    ldr r0, =v_20007FDF                @ 0x0800BDEE pool 0x0800C25C = 0x20007FDF
    ldrb r0, [r0, #0]                  @ 0x0800BDF2
    cmp r0, #0                         @ 0x0800BDF4
    beq .L0800BE12                     @ 0x0800BDF6
    ldr r0, =v205_tab_080286D0         @ 0x0800BDF8 pool 0x0800C260 = 0x080286D0
    uxtb r5, r5                        @ 0x0800BDFC
    movs r1, #20                       @ 0x0800BDFE
    mul.w r1, r1, r5                   @ 0x0800BE00
    add r0, r1                         @ 0x0800BE04
    uxtb r6, r6                        @ 0x0800BE06
    ldrb r0, [r0, r6]                  @ 0x0800BE08
    mov r1, sp                         @ 0x0800BE0A
    uxtb r6, r6                        @ 0x0800BE0C
    strb r0, [r1, r6]                  @ 0x0800BE0E
    b .L0800BE2A                       @ 0x0800BE10
.L0800BE12:                              @ reached from 0x0800BDF6 beq
    ldr r0, =v205_tab_08028748         @ 0x0800BE12 pool 0x0800C264 = 0x08028748
    uxtb r5, r5                        @ 0x0800BE16
    movs r1, #20                       @ 0x0800BE18
    mul.w r1, r1, r5                   @ 0x0800BE1A
    add r0, r1                         @ 0x0800BE1E
    uxtb r6, r6                        @ 0x0800BE20
    ldrb r0, [r0, r6]                  @ 0x0800BE22
    mov r1, sp                         @ 0x0800BE24
    uxtb r6, r6                        @ 0x0800BE26
    strb r0, [r1, r6]                  @ 0x0800BE28
.L0800BE2A:                              @ reached from 0x0800BE10 b
    b .L0800BE5E                       @ 0x0800BE2A
.L0800BE2C:                              @ reached from 0x0800BA04 beq, 0x0800BA0E beq, 0x0800BA18 beq
    @ ---- modes 16, 18, 20 AC currents: row = range of 0x08028D1C ----
    ldr r0, =v205_tab_08028D1C         @ 0x0800BE2C pool 0x0800C228 = 0x08028D1C
    uxtb r5, r5                        @ 0x0800BE30
    movs r1, #20                       @ 0x0800BE32
    mul.w r1, r1, r5                   @ 0x0800BE34
    add r0, r1                         @ 0x0800BE38
    uxtb r6, r6                        @ 0x0800BE3A
    ldrb r0, [r0, r6]                  @ 0x0800BE3C
    mov r1, sp                         @ 0x0800BE3E
    uxtb r6, r6                        @ 0x0800BE40
    strb r0, [r1, r6]                  @ 0x0800BE42
    b .L0800BE5E                       @ 0x0800BE44
.L0800BE46:                              @ reached from 0x0800BA12 bcc, 0x0800BA1C bcc, 0x0800BA24 bcc
    @ ---- modes 17, 19, 21 DC currents: row = range of 0x08028D94 ----
    ldr r0, =v205_tab_08028D94         @ 0x0800BE46 pool 0x0800C268 = 0x08028D94
    uxtb r5, r5                        @ 0x0800BE4A
    movs r1, #20                       @ 0x0800BE4C
    mul.w r1, r1, r5                   @ 0x0800BE4E
    add r0, r1                         @ 0x0800BE52
    uxtb r6, r6                        @ 0x0800BE54
    ldrb r0, [r0, r6]                  @ 0x0800BE56
    mov r1, sp                         @ 0x0800BE58
    uxtb r6, r6                        @ 0x0800BE5A
    strb r0, [r1, r6]                  @ 0x0800BE5C
.L0800BE5E:                              @ reached from 0x0800BA2E b, 0x0800BA9C b, 0x0800BADE b, 0x0800BB20 b, 0x0800BB72 b, 0x0800BBB4 b, 0x0800BBF6 b, 0x0800BC48 b, 0x0800BCF2 b, 0x0800BD54 b, 0x0800BD6E b, 0x0800BD88 b, 0x0800BD98 b, 0x0800BDB2 b, 0x0800BDC2 b, 0x0800BDDC b, 0x0800BDEC b, 0x0800BE2A b, 0x0800BE44 b
    @ ---- next byte of the row ----
    adds r6, r6, #1                    @ 0x0800BE5E
    b .L0800B9A8                       @ 0x0800BE60
.L0800BE62:                              @ reached from 0x0800B9B2 bcs
    @ ---- row complete: OHM range 6 with 0x20007FE0 != 0 clears byte 10 bit 3 (PS0 closed otherwise, hy3131_modes_misc.md 3.1) ----
    uxtb r4, r4                        @ 0x0800BE62
    cmp r4, #9                         @ 0x0800BE64
    bne .L0800BE84                     @ 0x0800BE66
    uxtb r5, r5                        @ 0x0800BE68
    cmp r5, #6                         @ 0x0800BE6A
    bne .L0800BE84                     @ 0x0800BE6C
    ldr r0, =v_20007FE0                @ 0x0800BE6E pool 0x0800C26C = 0x20007FE0
    ldrb r0, [r0, #0]                  @ 0x0800BE72
    cmp r0, #0                         @ 0x0800BE74
    beq .L0800BE84                     @ 0x0800BE76
    ldrb.w r0, [sp, #10]               @ 0x0800BE78
    ands.w r0, r0, #247                @ 0x0800BE7C
    strb.w r0, [sp, #10]               @ 0x0800BE80
.L0800BE84:                              @ reached from 0x0800BE66 bne, 0x0800BE6C bne, 0x0800BE76 beq
    @ ---- write the row to registers 0x20..0x33 through the checked frame writer (v2.05 0x0800BE94) ----
    movs r2, #20                            @ byte count
    movs r1, #32                            @ first register 0x20
    mov r0, sp                              @ the assembled row
    bl hy3131_write_regs                    @ r0 = 0 sent, 1 refused by the whitelist (spi.s)
    cbnz r0, .Llc_done                      @ refused: row state variables stay as they were
    ldrb.w r1, [sp]                         @ byte 0 = R20
    ldr r2, =v_2000807D
    strb r1, [r2]                           @ v2.05 copy of R20 (0x0800BE84..0x0800BE8C), mirror kept for compatibility
    ldr r2, =hy_row_r20
    strb r1, [r2]                           @ HW-05: R20 of the row, source of every counter-restart byte
    ldrb.w r1, [sp, #9]                     @ byte 9 = R29
    ldr r2, =hy_row_r29
    strb r1, [r2]                           @ HW-05: R29 of the row, source of the peak-restart bytes
    movs r1, #1
    ldr r2, =hy_row_valid
    strb r1, [r2]                           @ a row has been written
.Llc_done:
    add sp, #24
    ldmia.w sp!, {r4, r5, r6, r7, r8, pc}   @ r0 = write status
    .ltorg
ENDFUNC hy3131_load_config_regs

@ -----------------------------------------------------------------------------
@ hy3131_set_irq_enable - write INTF = 0 and the per-mode interrupt-enable value INTE to registers 0x1E, 0x1F
@ Replaces : 0x0800BEAC hy3131_set_irq_enable (v2.05)
@ In       : r0 = mode (0..24)
@ Out      : r0 = 0 written, 1 refused (mode > 24, or the frame check)
@ Clobbers : r0-r3, r12, flags (r4 preserved)
@ Context  : main only
@ RAM      : reads  0x200080BA acdc_active, 0x200080BD acdc_use_dcv_cal, 0x200080B7 peak_hold, 0x20008098
@ Spec     : analysis/hy3131_model.md 2.1 (INTE table); DESIGN.md 4.1
@ Deviation: NF-15
@ INTE set: 0x01, 0x04, 0x05, 0x11 (the four values v2.05 writes; hy_frame_allowed checks it again).
@ -----------------------------------------------------------------------------
FUNC hy3131_set_irq_enable
    @ ---- NF-15: no INTE value exists for a mode above 24 (v2.05 would write an uninitialised byte, 0x0800BF06) ----
    uxtb r1, r0
    cmp r1, #24
    bls .Lsi_go
    movs r0, #1                             @ refused, nothing sent
    bx lr
.Lsi_go:
    push {r4, lr}                      @ 0x0800BEAC
    sub sp, #8                         @ 0x0800BEAE
    movs r4, r0                        @ 0x0800BEB0
    @ frame buffer [sp] = INTF (always 0), [sp+1] = INTE chosen below; written as one 2-byte frame to registers 0x1E, 0x1F
    movs r0, #0                        @ 0x0800BEB2
    strb.w r0, [sp]                    @ 0x0800BEB4
    @ ---- mode ladder (v2.05 0x0800BEB8..0x0800BF06); INTE bits: 0 CTIE, 2 AD1IE, 4 RMSIE (DS p19) ----
    uxtb r4, r4                        @ 0x0800BEB8
    cmp r4, #0                         @ 0x0800BEBA
    beq .L0800BF08                     @ 0x0800BEBC
    cmp r4, #2                         @ 0x0800BEBE
    beq .L0800BF20                     @ 0x0800BEC0
    bcc .L0800BF50                     @ 0x0800BEC2
    cmp r4, #4                         @ 0x0800BEC4
    beq .L0800BF38                     @ 0x0800BEC6
    bcc .L0800BF50                     @ 0x0800BEC8
    cmp r4, #6                         @ 0x0800BECA
    beq .L0800BF68                     @ 0x0800BECC
    bcc .L0800BF50                     @ 0x0800BECE
    cmp r4, #8                         @ 0x0800BED0
    beq .L0800BF68                     @ 0x0800BED2
    bcc .L0800BF68                     @ 0x0800BED4
    cmp r4, #10                        @ 0x0800BED6
    beq .L0800BF50                     @ 0x0800BED8
    bcc .L0800BF50                     @ 0x0800BEDA
    cmp r4, #12                        @ 0x0800BEDC
    beq .L0800BF60                     @ 0x0800BEDE
    bcc .L0800BF50                     @ 0x0800BEE0
    cmp r4, #14                        @ 0x0800BEE2
    beq .L0800BF48                     @ 0x0800BEE4
    bcc .L0800BF48                     @ 0x0800BEE6
    cmp r4, #16                        @ 0x0800BEE8
    beq .L0800BF48                     @ 0x0800BEEA
    bcc .L0800BF48                     @ 0x0800BEEC
    cmp r4, #18                        @ 0x0800BEEE
    beq .L0800BF48                     @ 0x0800BEF0
    bcc .L0800BF50                     @ 0x0800BEF2
    cmp r4, #20                        @ 0x0800BEF4
    beq .L0800BF48                     @ 0x0800BEF6
    bcc .L0800BF50                     @ 0x0800BEF8
    cmp r4, #22                        @ 0x0800BEFA
    beq .L0800BF50                     @ 0x0800BEFC
    bcc .L0800BF58                     @ 0x0800BEFE
    cmp r4, #24                        @ 0x0800BF00
    beq .L0800BF50                     @ 0x0800BF02
    bcc .L0800BF50                     @ 0x0800BF04
    b .L0800BF6E                       @ 0x0800BF06
.L0800BF08:                              @ reached from 0x0800BEBC beq
    @ ---- mode 0 LowZ: INTE 0x05 (AD1IE + CTIE) for the AC variant (0x20008098 != 0), else 0x04 (AD1IE) ----
    ldr r0, =v_20008098                @ 0x0800BF08 pool 0x0800C20C = 0x20008098
    ldrb r0, [r0, #0]                  @ 0x0800BF0A
    cmp r0, #0                         @ 0x0800BF0C
    beq .L0800BF18                     @ 0x0800BF0E
    movs r0, #5                        @ 0x0800BF10
    strb.w r0, [sp, #1]                @ 0x0800BF12
    b .L0800BF1E                       @ 0x0800BF16
.L0800BF18:                              @ reached from 0x0800BF0E beq
    movs r0, #4                        @ 0x0800BF18
    strb.w r0, [sp, #1]                @ 0x0800BF1A
.L0800BF1E:                              @ reached from 0x0800BF16 b
    b .L0800BF6E                       @ 0x0800BF1E
.L0800BF20:                              @ reached from 0x0800BEC0 beq
    @ ---- mode 2 ACV: AC+DC (0x200080BA) and 0x200080BD both set: INTE 0x04; otherwise as mode 4 below ----
    ldr r0, =acdc_active               @ 0x0800BF20 pool 0x0800C22C = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x0800BF22
    cmp r0, #0                         @ 0x0800BF24
    beq .L0800BF38                     @ 0x0800BF26
    ldr r0, =acdc_use_dcv_cal          @ 0x0800BF28 pool 0x0800C230 = 0x200080BD
    ldrb r0, [r0, #0]                  @ 0x0800BF2A
    cmp r0, #0                         @ 0x0800BF2C
    beq .L0800BF38                     @ 0x0800BF2E
    movs r0, #4                        @ 0x0800BF30
    strb.w r0, [sp, #1]                @ 0x0800BF32
    b .L0800BF6E                       @ 0x0800BF36
.L0800BF38:                              @ reached from 0x0800BEC6 beq, 0x0800BF26 beq, 0x0800BF2E beq
    @ ---- modes 4 and 2: PEAK (0x200080B7) = 1: INTE 0x11 (RMSIE + CTIE, ENAD1 off); else 0x05 ----
    ldr r0, =peak_hold                 @ 0x0800BF38 pool 0x0800C238 = 0x200080B7
    ldrb r0, [r0, #0]                  @ 0x0800BF3A
    cmp r0, #1                         @ 0x0800BF3C
    bne .L0800BF48                     @ 0x0800BF3E
    movs r0, #17                       @ 0x0800BF40
    strb.w r0, [sp, #1]                @ 0x0800BF42
    b .L0800BF6E                       @ 0x0800BF46
.L0800BF48:                              @ reached from 0x0800BEE4 beq, 0x0800BEE6 bcc, 0x0800BEEA beq, 0x0800BEEC bcc, 0x0800BEF0 beq, 0x0800BEF6 beq, 0x0800BF3E bne
    @ ---- INTE 0x05: AD1IE + CTIE (modes 13..16, 18, 20, ACV/ACmV without PEAK) ----
    movs r0, #5                        @ 0x0800BF48
    strb.w r0, [sp, #1]                @ 0x0800BF4A
    b .L0800BF6E                       @ 0x0800BF4E
.L0800BF50:                              @ reached from 0x0800BEC2 bcc, 0x0800BEC8 bcc, 0x0800BECE bcc, 0x0800BED8 beq, 0x0800BEDA bcc, 0x0800BEE0 bcc, 0x0800BEF2 bcc, 0x0800BEF8 bcc, 0x0800BEFC beq, 0x0800BF02 beq, 0x0800BF04 bcc
    @ ---- INTE 0x04: AD1IE only (modes 1, 3, 5, 9, 10, 11 and the DC modes) ----
    movs r0, #4                        @ 0x0800BF50
    strb.w r0, [sp, #1]                @ 0x0800BF52
    b .L0800BF6E                       @ 0x0800BF56
.L0800BF58:                              @ reached from 0x0800BEFE bcc
    @ ---- INTE 0x04 (mode 21) ----
    movs r0, #4                        @ 0x0800BF58
    strb.w r0, [sp, #1]                @ 0x0800BF5A
    b .L0800BF6E                       @ 0x0800BF5E
.L0800BF60:                              @ reached from 0x0800BEDE beq
    @ ---- mode 12 CAP: INTE 0x01 (CTIE) ----
    movs r0, #1                        @ 0x0800BF60
    strb.w r0, [sp, #1]                @ 0x0800BF62
    b .L0800BF6E                       @ 0x0800BF66
.L0800BF68:                              @ reached from 0x0800BECC beq, 0x0800BED2 beq, 0x0800BED4 bcc
    @ ---- modes 6, 7, 8 FREQ, PULSE, DUTY: INTE 0x01 (CTIE) ----
    movs r0, #1                        @ 0x0800BF68
    strb.w r0, [sp, #1]                @ 0x0800BF6A
.L0800BF6E:                              @ reached from 0x0800BF06 b, 0x0800BF1E b, 0x0800BF36 b, 0x0800BF46 b, 0x0800BF4E b, 0x0800BF56 b, 0x0800BF5E b, 0x0800BF66 b
    @ ---- write INTF = 0 and INTE to registers 0x1E, 0x1F (v2.05 0x0800BF74) ----
    movs r2, #2                        @ 0x0800BF6E
    movs r1, #30                       @ 0x0800BF70
    mov r0, sp                         @ 0x0800BF72
    bl hy3131_write_regs               @ 0x0800BF74
    add sp, #8                              @ release the frame; r0 = status of the frame write is kept (v2.05 popped r0, r1)
    pop {r4, pc}
    .ltorg
ENDFUNC hy3131_set_irq_enable


@ -----------------------------------------------------------------------------
@ Counter restart (HY3131 registers 0x20 bit 1 ENCTR, 0x1B..0x1D CTA)
@ v2.05 hy3131_counter_restart 0x0800BF8C does, in this order: R20 <- R20 & 0xFD (modes 6, 7, 8) or & 0xF9 (other modes);
@ delay(10000); CTA <- 00, preset low, preset high (preset = word 0x2000001C); read CTA back; R20 <- R20 | 0x02.
@ HW-05: R20 comes from the row last written (hy_row_r20), not from the SPI read-back copy 0x2000807D.  The values are equal
@ whenever the read-back is right (analysis: the chip holds the row byte, bit 1 set after a restart, and & 0xFD / & 0xF9 clear
@ it again), and a corrupted read can no longer put a value outside the whitelist on the bus.
@ A restart before any row was written (hy_row_valid = 0) does nothing.
@ -----------------------------------------------------------------------------

.if LOOP_V205
@ -----------------------------------------------------------------------------
@ hy3131_counter_restart - restart the HY3131 frequency counter (baseline: blocking)
@ Replaces : 0x0800BF8C hy3131_counter_restart (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  hy_row_r20, hy_row_valid, 0x2000803C meter_mode
@ Spec     : analysis/hy3131_model.md 3 (counter preset); hy3131_modes_misc.md 0
@ Deviation: HW-05
@ LOOP_V205 = 1: the whole sequence runs inside this call as in v2.05, including delay(10000) (0x0800BFCA..0x0800BFCE).
@ -----------------------------------------------------------------------------
FUNC hy3131_counter_restart
    ldr r0, =hy_row_valid
    ldrb r0, [r0]
    cbnz r0, .Lcr_go
    bx lr                                   @ no row written yet: nothing to restart
.Lcr_go:
    push {r7, lr}                      @ 0x0800BF8C
    ldr r0, =meter_mode                @ 0x0800BF8E pool 0x0800C274 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800BF90
    cmp r0, #6                         @ 0x0800BF92
    beq .L0800BFA6                     @ 0x0800BF94
    ldr r0, =meter_mode                @ 0x0800BF96 pool 0x0800C274 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800BF98
    cmp r0, #7                         @ 0x0800BF9A
    beq .L0800BFA6                     @ 0x0800BF9C
    ldr r0, =meter_mode                @ 0x0800BF9E pool 0x0800C274 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800BFA0
    cmp r0, #8                         @ 0x0800BFA2
    bne .L0800BFB4                     @ 0x0800BFA4
.L0800BFA6:                              @ reached from 0x0800BF94 beq, 0x0800BF9C beq
    @ ---- modes 6, 7, 8: clear ENCTR only (R20 & 0xFD, v2.05 0x0800BFAA) ----
    ldr r0, =hy_row_r20                @ 0x0800BFA6 pool 0x0800C270 = 0x2000807D
    ldrb r0, [r0, #0]                  @ 0x0800BFA8
    ands.w r0, r0, #253                @ 0x0800BFAA
    strb.w r0, [sp]                    @ 0x0800BFAE
    b .L0800BFC0                       @ 0x0800BFB2
.L0800BFB4:                              @ reached from 0x0800BFA4 bne
    @ ---- other modes: clear ENCTR and ENPCMPO (R20 & 0xF9, v2.05 0x0800BFB8) ----
    ldr r0, =hy_row_r20                @ 0x0800BFB4 pool 0x0800C270 = 0x2000807D
    ldrb r0, [r0, #0]                  @ 0x0800BFB6
    ands.w r0, r0, #249                @ 0x0800BFB8
    strb.w r0, [sp]                    @ 0x0800BFBC
.L0800BFC0:                              @ reached from 0x0800BFB2 b
    @ ---- phase 1: write R20 (1 byte at register 0x20), wait, then phase 2 ----
    movs r2, #1                        @ 0x0800BFC0
    movs r1, #32                       @ 0x0800BFC2
    mov r0, sp                         @ 0x0800BFC4
    bl hy3131_write_regs               @ 0x0800BFC6
    @ delay(10000): the counter must be off before CTA is written (v2.05; the datasheet gives no figure, ARS 5.2 P6)
    movw r0, #10000                    @ 0x0800BFCA
    bl fn_0800ECF6                     @ 0x0800BFCE
    @ phase 2: CTA<7:0> = 0, CTA<15:8> = word 0x2000001C byte 0, CTA<23:16> = byte 1 (DS p36 (4)); write registers 0x1B..0x1D
    movs r0, #0                        @ 0x0800BFD2
    strb.w r0, [sp]                    @ 0x0800BFD4
    ldr r0, =v_2000001C                @ 0x0800BFD8 pool 0x0800C278 = 0x2000001C
    ldr r0, [r0, #0]                   @ 0x0800BFDA
    strb.w r0, [sp, #1]                @ 0x0800BFDC
    ldr r0, =v_2000001C                @ 0x0800BFE0 pool 0x0800C278 = 0x2000001C
    ldr r0, [r0, #0]                   @ 0x0800BFE2
    lsrs r0, r0, #8                    @ 0x0800BFE4
    strb.w r0, [sp, #2]                @ 0x0800BFE6
    movs r2, #3                        @ 0x0800BFEA
    movs r1, #27                       @ 0x0800BFEC
    mov r0, sp                         @ 0x0800BFEE
    bl hy3131_write_regs               @ 0x0800BFF0
    @ read CTA back (v2.05 0x0800BFFA; the result is never examined; lands at the mirror position 0x1B in the port)
    movs r2, #3                        @ 0x0800BFF4
    movs r1, #27                       @ 0x0800BFF6
    ldr r0, =adc_regs                  @ 0x0800BFF8 pool 0x0800C27C = 0x200077D0
    bl hy3131_read_regs_to_rxbuf       @ 0x0800BFFA
    ldr r0, =meter_mode                @ 0x0800BFFE pool 0x0800C274 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800C000
    cmp r0, #6                         @ 0x0800C002
    beq .L0800C016                     @ 0x0800C004
    ldr r0, =meter_mode                @ 0x0800C006 pool 0x0800C274 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800C008
    cmp r0, #7                         @ 0x0800C00A
    beq .L0800C016                     @ 0x0800C00C
    ldr r0, =meter_mode                @ 0x0800C00E pool 0x0800C274 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800C010
    cmp r0, #8                         @ 0x0800C012
    bne .L0800C024                     @ 0x0800C014
.L0800C016:                              @ reached from 0x0800C004 beq, 0x0800C00C beq
    @ ---- phase 3: R20 | 0x02 (ENCTR on), modes 6, 7, 8 (identical value in both branches, v2.05 0x0800C01A / 0x0800C028) ----
    ldr r0, =hy_row_r20                @ 0x0800C016 pool 0x0800C270 = 0x2000807D
    ldrb r0, [r0, #0]                  @ 0x0800C018
    orrs.w r0, r0, #2                  @ 0x0800C01A
    strb.w r0, [sp]                    @ 0x0800C01E
    b .L0800C030                       @ 0x0800C022
.L0800C024:                              @ reached from 0x0800C014 bne
    ldr r0, =hy_row_r20                @ 0x0800C024 pool 0x0800C270 = 0x2000807D
    ldrb r0, [r0, #0]                  @ 0x0800C026
    orrs.w r0, r0, #2                  @ 0x0800C028
    strb.w r0, [sp]                    @ 0x0800C02C
.L0800C030:                              @ reached from 0x0800C022 b
    movs r2, #1                        @ 0x0800C030
    movs r1, #32                       @ 0x0800C032
    mov r0, sp                         @ 0x0800C034
    bl hy3131_write_regs               @ 0x0800C036
    pop {r0, pc}                       @ 0x0800C03A
    .ltorg
ENDFUNC hy3131_counter_restart
.else
@ -----------------------------------------------------------------------------
@ hy3131_counter_restart (production) - start a counter restart; hy_counter_restart_step finishes it
@ Replaces : 0x0800BF8C hy3131_counter_restart (v2.05), with the wait of delay(10000) taken apart (DESIGN.md 3.5)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  hy_row_r20, hy_row_valid, 0x2000803C meter_mode
@            writes hy_restart_ticks, hy_restart_pend
@ Spec     : DESIGN.md 3.5 (blocking routines as state machines), 6.13; analysis/autorange_and_scheduler.md 5.2 P6
@ Deviation: IMP-06
@ Phase 1 (R20 & mask) is sent here; the wait of v2.05 (fn_0800ECF6(10000), 0x0800BFCE, 17.1 ms) is measured in TIM3 ticks
@ (HY_RESTART_TICKS, counted down by bzb_tim3_isr), not in main-loop passes, so its length does not depend on how long a
@ pass lasts (the production loop sleeps with WFI between passes); hy3131_poll calls hy_counter_restart_step every pass and
@ phases 2 and 3 follow in the first pass after the count reached 0.  A second start before the sequence has finished
@ starts it again from phase 1.
@ -----------------------------------------------------------------------------
FUNC hy3131_counter_restart
    ldr r0, =hy_row_valid
    ldrb r0, [r0]
    cbnz r0, .Lcs_go
    bx lr                                   @ no row written yet
.Lcs_go:
    push {r4, lr}
    sub sp, #8                              @ frame buffer (3 bytes used), keeps 8-byte alignment
    ldr r0, =meter_mode
    ldrb r0, [r0]                           @ r0 = mode
    ldr r1, =hy_row_r20
    ldrb r1, [r1]                           @ r1 = R20 of the loaded row (HW-05)
    cmp r0, #6
    blo .Lcs_f9                             @ mode < 6
    cmp r0, #8
    bhi .Lcs_f9                             @ mode > 8
    and r1, r1, #0xFD                       @ modes 6, 7, 8: clear ENCTR only (v2.05 0x0800BFAA)
    b .Lcs_w
.Lcs_f9:
    and r1, r1, #0xF9                       @ other modes: clear ENCTR and ENPCMPO (v2.05 0x0800BFB8)
.Lcs_w:
    strb r1, [sp]
    movs r2, #1
    movs r1, #32                            @ register 0x20
    mov r0, sp
    bl hy3131_write_regs                    @ phase 1 (v2.05 0x0800BFC6)
    movs r0, #HY_RESTART_TICKS
    ldr r1, =hy_restart_ticks
    strb r0, [r1]                           @ wait armed (single byte store: atomic against bzb_tim3_isr)
    movs r0, #1
    ldr r1, =hy_restart_pend
    strb r0, [r1]                           @ phases 2 and 3 pending
    add sp, #8
    pop {r4, pc}
    .ltorg
ENDFUNC hy3131_counter_restart
.endif

.if LOOP_V205
@ -----------------------------------------------------------------------------
@ hy_counter_restart_step (baseline) - nothing is ever pending: the restart ran to completion inside the call
@ Replaces : new (the production variant below finishes a split restart; v2.05 has no such step)
@ In       : -
@ Out      : r0 = 1 (idle)
@ Clobbers : r0
@ Context  : main only (hy3131_poll does not call it in the baseline)
@ RAM      : none
@ Spec     : DESIGN.md 3.5, 6.13
@ Deviation: none (baseline keeps the v2.05 blocking restart)
@ -----------------------------------------------------------------------------
FUNC hy_counter_restart_step
    movs r0, #1                             @ 1 = done / idle
    bx lr
ENDFUNC hy_counter_restart_step
.else
@ -----------------------------------------------------------------------------
@ hy_counter_restart_step - finish a pending counter restart once its TIM3 wait has run out
@ Replaces : the second half of 0x0800BF8C hy3131_counter_restart (v2.05), see hy3131_counter_restart (production)
@ In       : -
@ Out      : r0 = 1 idle or finished, 0 busy (wait still running)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only (called by hy3131_poll once per pass)
@ RAM      : reads  hy_restart_pend, hy_restart_ticks, hy_row_r20, 0x2000001C
@            writes hy_restart_pend
@ Spec     : DESIGN.md 3.5, 6.13
@ Deviation: IMP-06
@ -----------------------------------------------------------------------------
FUNC hy_counter_restart_step
    ldr r1, =hy_restart_pend
    ldrb r0, [r1]
    cbnz r0, .Lst_pend
    movs r0, #1                             @ nothing pending
    bx lr
.Lst_pend:
    ldr r0, =hy_restart_ticks
    ldrb r0, [r0]
    cbz r0, .Lst_go
    movs r0, #0                             @ busy: the wait of v2.05 delay(10000) (0x0800BFCE) is still running
    bx lr
.Lst_go:
    movs r0, #0
    strb r0, [r1]                           @ no longer pending (only main writes hy_restart_pend)
    push {r4, lr}
    sub sp, #8                              @ frame buffer
    @ ---- phase 2 (v2.05 0x0800BFD2..0x0800BFFA): CTA <- 0, preset; read back ----
    movs r0, #0
    strb r0, [sp]                           @ CTA<7:0> = 0
    ldr r0, =v_2000001C
    ldr r0, [r0]                            @ counter preset word (0xE000 or 0x8000)
    strb r0, [sp, #1]                       @ CTA<15:8> = preset byte 0
    lsrs r0, r0, #8
    strb r0, [sp, #2]                       @ CTA<23:16> = preset byte 1
    movs r2, #3
    movs r1, #27                            @ register 0x1B
    mov r0, sp
    bl hy3131_write_regs
    movs r2, #3
    movs r1, #27
    ldr r0, =adc_regs
    bl hy3131_read_regs_to_rxbuf            @ read CTA back (v2.05 0x0800BFFA)
    @ ---- phase 3 (v2.05 0x0800C016..0x0800C036): R20 | 0x02 ----
    ldr r0, =hy_row_r20
    ldrb r0, [r0]
    orr r0, r0, #2                          @ ENCTR on again
    strb r0, [sp]
    movs r2, #1
    movs r1, #32
    mov r0, sp
    bl hy3131_write_regs
    add sp, #8
    movs r0, #1                             @ finished
    pop {r4, pc}
    .ltorg
ENDFUNC hy_counter_restart_step
.endif

@ -----------------------------------------------------------------------------
@ hy_peak_restart - reset the HY3131 peak registers (R29 ENPKH 0, then back)
@ Replaces : the register writes of FUN_0800A7FC at 0x0800A872 and 0x0800A88C (v2.05); MAC keeps the rest of the routine
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  hy_row_r29, hy_row_valid
@ Spec     : analysis/hy3131_modes_misc.md 7.1 (R29 echo); DESIGN.md 4.1 item 3, Appendix C.2
@ Deviation: HW-05 (v2.05 writes the SPI read-back copy 0x2000807E; the port writes R29 of the loaded row)
@ Sequence (v2.05): R29 <- R29 & 0xFB (ENPKH = 0 resets PKHMAX/PKHMIN, DS p34); delay(10); R29 <- R29.
@ -----------------------------------------------------------------------------
FUNC hy_peak_restart
    ldr r0, =hy_row_valid
    ldrb r0, [r0]
    cbnz r0, .Lpk_go
    bx lr                                   @ no row written yet
.Lpk_go:
    push {r4, lr}
    sub sp, #8                              @ one-byte frame buffer
    ldr r4, =hy_row_r29
    ldrb r4, [r4]                           @ r4 = R29 of the loaded row
    and r0, r4, #0xFB                       @ ENPKH (bit 2) cleared
    strb r0, [sp]
    movs r2, #1
    movs r1, #41                            @ register 0x29
    mov r0, sp
    bl hy3131_write_regs                    @ v2.05 0x0800A872
    movs r0, #10
    bl fn_0800ECF6                          @ delay(10), v2.05 0x0800A87A
    strb r4, [sp]                           @ restore R29
    movs r2, #1
    movs r1, #41
    mov r0, sp
    bl hy3131_write_regs                    @ v2.05 0x0800A88C
    add sp, #8
    pop {r4, pc}
    .ltorg
ENDFUNC hy_peak_restart

@ -----------------------------------------------------------------------------
@ Port RAM of module HY
@ -----------------------------------------------------------------------------
    .section .bss_port.hy, "aw", %nobits
    .global hy_row_r20, hy_row_r29, hy_row_valid, hy_restart_pend, hy_restart_ticks, hy_refused_count
hy_row_r20:        .space 1                 @ R20 of the row last written to registers 0x20..0x33 (HW-05)
hy_row_r29:        .space 1                 @ R29 of that row
hy_row_valid:      .space 1                 @ 1 once a row has been written, 0 after reset
hy_restart_pend:   .space 1                 @ production: 1 while a counter restart waits for its phases 2 and 3 (0 = none)
hy_restart_ticks:  .space 1                 @ production: TIM3 ticks left of that wait (decremented by bzb_tim3_isr)
hy_refused_count:  .space 1                 @ refused HY3131 requests, saturating (diagnostic, probe build 9.4 level 5)
