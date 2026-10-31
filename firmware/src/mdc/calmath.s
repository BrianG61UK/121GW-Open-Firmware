@ =============================================================================
@ calmath.s - MDC: calibration arithmetic (offset subtraction, division by the gain, gain selection)
@
@ Replaces v2.05 FUN_0800EEF0 0x0800EEF0, FUN_0800F2FC 0x0800F2FC, cal_subtract_offset_clamp 0x0800F368, FUN_0800F37E 0x0800F37E,
@ cal_divide_by_gain 0x0800F3B8 and FUN_0800F648 0x0800F648.
@
@ The calibration record of the current (mode, range) is held in RAM: offset 0x20007E00 (i32), gain 0x20007E10 (float32); the VA
@ modes (13, 14, 15, 22, 23, 24) use two offset/gain pairs (0x20007E24/0x20007E28 and 0x20007E2C/0x20007E30, selected by 0x200080C4).
@ This module only reads them (the EEPROM and its RAM copies belong to CAL / NVM).  The float work goes through the RT helpers
@ fn_08012F60 (int -> float), fn_08012F94 (float divide), fn_08013168 (float -> double), fn_080131B8 (double add), fn_080132A0
@ (double -> int, truncating), fn_0801BD08 (float compare).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mdc.cal, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800F648 - gain of the current calibration record
@ Replaces : 0x0800F648 FUN_0800F648 (v2.05)
@ In       : -
@ Out      : r0 = gain (float32 bit pattern)
@ Clobbers : r0, r1, flags
@ Context  : main only
@ RAM      : reads  0x20007E10 cal_gain, 0x2000803C meter_mode, 0x20007E2C, 0x20007E30, 0x200080C4 va_channel
@ Spec     : analysis/hy3131_model.md 5.1
@ Deviation: none
@ VA modes 13, 14, 15, 22, 23, 24: 0x20007E2C when va_channel (0x200080C4) = 0, else 0x20007E30; all other modes: 0x20007E10 (cal_gain).
@ -----------------------------------------------------------------------------
FUNC fn_0800F648
    ldr r1, =meter_mode                @ 0x0800F648 pool 0x0800FD7C = 0x2000803C  VA mode test
    ldrb r1, [r1, #0]                  @ 0x0800F64C
    cmp r1, #13                        @ 0x0800F64E
    beq .L0800F684                     @ 0x0800F650
    ldr r1, =meter_mode                @ 0x0800F652 pool 0x0800FD7C = 0x2000803C
    ldrb r1, [r1, #0]                  @ 0x0800F656
    cmp r1, #14                        @ 0x0800F658
    beq .L0800F684                     @ 0x0800F65A
    ldr r1, =meter_mode                @ 0x0800F65C pool 0x0800FD7C = 0x2000803C
    ldrb r1, [r1, #0]                  @ 0x0800F660
    cmp r1, #15                        @ 0x0800F662
    beq .L0800F684                     @ 0x0800F664
    ldr r1, =meter_mode                @ 0x0800F666 pool 0x0800FD7C = 0x2000803C
    ldrb r1, [r1, #0]                  @ 0x0800F66A
    cmp r1, #22                        @ 0x0800F66C
    beq .L0800F684                     @ 0x0800F66E
    ldr r1, =meter_mode                @ 0x0800F670 pool 0x0800FD7C = 0x2000803C
    ldrb r1, [r1, #0]                  @ 0x0800F674
    cmp r1, #23                        @ 0x0800F676
    beq .L0800F684                     @ 0x0800F678
    ldr r1, =meter_mode                @ 0x0800F67A pool 0x0800FD7C = 0x2000803C
    ldrb r1, [r1, #0]                  @ 0x0800F67E
    cmp r1, #24                        @ 0x0800F680
    bne .L0800F6A2                     @ 0x0800F682
.L0800F684:                              @ reached from 0x0800F650 beq, 0x0800F65A beq, 0x0800F664 beq, 0x0800F66E beq, 0x0800F678 beq
    ldr r1, =va_channel                @ 0x0800F684 pool 0x0800FDA4 = 0x200080C4
    ldrb r1, [r1, #0]                  @ 0x0800F688
    cmp r1, #0                         @ 0x0800F68A
    bne .L0800F698                     @ 0x0800F68C
    ldr r1, =v_20007E2C                @ 0x0800F68E pool 0x080100BC = 0x20007E2C
    ldr r1, [r1, #0]                   @ 0x0800F692
    movs r0, r1                        @ 0x0800F694
    b .L0800F6AA                       @ 0x0800F696
.L0800F698:                              @ reached from 0x0800F68C bne
    ldr r1, =v_20007E30                @ 0x0800F698 pool 0x080100C0 = 0x20007E30
    ldr r1, [r1, #0]                   @ 0x0800F69C
    movs r0, r1                        @ 0x0800F69E
    b .L0800F6AA                       @ 0x0800F6A0
.L0800F6A2:                              @ reached from 0x0800F682 bne
    ldr r1, =cal_gain                  @ 0x0800F6A2 pool 0x0801010C = 0x20007E10
    ldr r1, [r1, #0]                   @ 0x0800F6A6
    movs r0, r1                        @ 0x0800F6A8
.L0800F6AA:                              @ reached from 0x0800F696 b, 0x0800F6A0 b
    bx lr                              @ 0x0800F6AA
    .ltorg
ENDFUNC fn_0800F648

@ -----------------------------------------------------------------------------
@ fn_0800F2FC - subtract the record offset
@ Replaces : 0x0800F2FC FUN_0800F2FC (v2.05)
@ In       : r0 = code (mean or sample)
@ Out      : r0 = code - offset
@ Clobbers : r0-r2, flags
@ Context  : main only
@ RAM      : reads  0x20007E00 cal_offset, 0x2000803C meter_mode, 0x20007E24, 0x20007E28, 0x200080C4 va_channel
@ Spec     : analysis/hy3131_model.md 5.2 step 2
@ Deviation: none
@ VA modes: offset 0x20007E24 (va_channel = 0) or 0x20007E28; other modes: 0x20007E00 (cal_offset).  No clamp.
@ -----------------------------------------------------------------------------
FUNC fn_0800F2FC
    movs r1, r0                        @ 0x0800F2FC  r1 = code
    ldr r2, =meter_mode                @ 0x0800F2FE pool 0x0800FD7C = 0x2000803C
    ldrb r2, [r2, #0]                  @ 0x0800F302
    cmp r2, #13                        @ 0x0800F304
    beq .L0800F33A                     @ 0x0800F306
    ldr r2, =meter_mode                @ 0x0800F308 pool 0x0800FD7C = 0x2000803C
    ldrb r2, [r2, #0]                  @ 0x0800F30C
    cmp r2, #14                        @ 0x0800F30E
    beq .L0800F33A                     @ 0x0800F310
    ldr r2, =meter_mode                @ 0x0800F312 pool 0x0800FD7C = 0x2000803C
    ldrb r2, [r2, #0]                  @ 0x0800F316
    cmp r2, #15                        @ 0x0800F318
    beq .L0800F33A                     @ 0x0800F31A
    ldr r2, =meter_mode                @ 0x0800F31C pool 0x0800FD7C = 0x2000803C
    ldrb r2, [r2, #0]                  @ 0x0800F320
    cmp r2, #22                        @ 0x0800F322
    beq .L0800F33A                     @ 0x0800F324
    ldr r2, =meter_mode                @ 0x0800F326 pool 0x0800FD7C = 0x2000803C
    ldrb r2, [r2, #0]                  @ 0x0800F32A
    cmp r2, #23                        @ 0x0800F32C
    beq .L0800F33A                     @ 0x0800F32E
    ldr r2, =meter_mode                @ 0x0800F330 pool 0x0800FD7C = 0x2000803C
    ldrb r2, [r2, #0]                  @ 0x0800F334
    cmp r2, #24                        @ 0x0800F336
    bne .L0800F35C                     @ 0x0800F338
.L0800F33A:                              @ reached from 0x0800F306 beq, 0x0800F310 beq, 0x0800F31A beq, 0x0800F324 beq, 0x0800F32E beq
    ldr r2, =va_channel                @ 0x0800F33A pool 0x0800FDA4 = 0x200080C4
    ldrb r2, [r2, #0]                  @ 0x0800F33E
    cmp r2, #0                         @ 0x0800F340
    bne .L0800F350                     @ 0x0800F342
    ldr r2, =v_20007E24                @ 0x0800F344 pool 0x0800FDA8 = 0x20007E24
    ldr r2, [r2, #0]                   @ 0x0800F348
    subs r2, r1, r2                    @ 0x0800F34A
    movs r0, r2                        @ 0x0800F34C
    b .L0800F366                       @ 0x0800F34E
.L0800F350:                              @ reached from 0x0800F342 bne
    ldr r2, =v_20007E28                @ 0x0800F350 pool 0x0800FDAC = 0x20007E28
    ldr r2, [r2, #0]                   @ 0x0800F354
    subs r2, r1, r2                    @ 0x0800F356
    movs r0, r2                        @ 0x0800F358
    b .L0800F366                       @ 0x0800F35A
.L0800F35C:                              @ reached from 0x0800F338 bne
    ldr r2, =cal_offset                @ 0x0800F35C pool 0x0800FC48 = 0x20007E00
    ldr r2, [r2, #0]                   @ 0x0800F360
    subs r2, r1, r2                    @ 0x0800F362
    movs r0, r2                        @ 0x0800F364
.L0800F366:                              @ reached from 0x0800F34E b, 0x0800F35A b
    bx lr                              @ 0x0800F366
    .ltorg
ENDFUNC fn_0800F2FC

@ -----------------------------------------------------------------------------
@ cal_subtract_offset_clamp - subtract the record offset and clamp at 0 (AC chains)
@ Replaces : 0x0800F368 cal_subtract_offset_clamp (v2.05)
@ In       : r0 = code
@ Out      : r0 = code - offset, or 0 when that is below 1
@ Clobbers : r0-r2, flags
@ Context  : main only
@ RAM      : reads  0x20007E00 cal_offset
@ Spec     : analysis/hy3131_model.md 5.2 (AC/ACmV clamp)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC cal_subtract_offset_clamp
    movs r1, r0                        @ 0x0800F368
    movs r0, r1                        @ 0x0800F36A
    ldr r2, =cal_offset                @ 0x0800F36C pool 0x0800FC48 = 0x20007E00
    ldr r2, [r2, #0]                   @ 0x0800F370
    subs r0, r0, r2                    @ 0x0800F372
    cmp r0, #1                         @ 0x0800F374
    bge .L0800F37C                     @ 0x0800F376
    movs r2, #0                        @ 0x0800F378
    movs r0, r2                        @ 0x0800F37A
.L0800F37C:                              @ reached from 0x0800F376 bge
    bx lr                              @ 0x0800F37C
    .ltorg
ENDFUNC cal_subtract_offset_clamp

@ -----------------------------------------------------------------------------
@ fn_0800EEF0 - mean code minus the record offset (DIODE: unchanged)
@ Replaces : 0x0800EEF0 FUN_0800EEF0 (v2.05)
@ In       : r0 = mean code
@ Out      : r0 = mean - offset; DIODE (mode 11): the mean unchanged; with a capture running (0x2000808C) CAL fn_0800EF44(r0)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x2000808C
@ Spec     : hy3131_modes_misc.md 6.3 (DIODE has no offset on the mean path)
@ Deviation: none
@ While a calibration capture is running (0x2000808C != 0) the CAL routine fn_0800EF44 takes the mean instead (it arms NVM itself).
@ -----------------------------------------------------------------------------
FUNC fn_0800EEF0
    push {r3, r4, r5, lr}              @ 0x0800EEF0
    movs r4, r0                        @ 0x0800EEF2
    movs r5, #0                        @ 0x0800EEF4
    ldr r0, =meter_mode                @ 0x0800EEF6 pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800EEFA
    cmp r0, #11                        @ 0x0800EEFC
    bne .L0800EF04                     @ 0x0800EEFE
    movs r5, r4                        @ 0x0800EF00
    b .L0800EF20                       @ 0x0800EF02
.L0800EF04:                              @ reached from 0x0800EEFE bne
    ldr r0, =v_2000808C                @ 0x0800EF04 pool 0x0800F9DC = 0x2000808C
    ldrb r0, [r0, #0]                  @ 0x0800EF08
    cmp r0, #0                         @ 0x0800EF0A
    beq .L0800EF18                     @ 0x0800EF0C
    movs r0, r4                        @ 0x0800EF0E
    bl fn_0800EF44                     @ 0x0800EF10
    movs r5, r0                        @ 0x0800EF14
    b .L0800EF20                       @ 0x0800EF16
.L0800EF18:                              @ reached from 0x0800EF0C beq
    movs r0, r4                        @ 0x0800EF18
    bl fn_0800F2FC                     @ 0x0800EF1A
    movs r5, r0                        @ 0x0800EF1E
.L0800EF20:                              @ reached from 0x0800EF02 b, 0x0800EF16 b
    movs r0, r5                        @ 0x0800EF20
    pop {r1, r4, r5, pc}               @ 0x0800EF22
    .ltorg
ENDFUNC fn_0800EEF0

@ -----------------------------------------------------------------------------
@ fn_0800F37E - divide the offset-corrected mean by the gain
@ Replaces : 0x0800F37E FUN_0800F37E (v2.05)
@ In       : r0 = offset-corrected mean
@ Out      : r0 = calibrated value; with a capture running (0x2000808E or 0x20008090) CAL fn_0800F470(r0)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x2000808E, 0x20008090
@ Spec     : analysis/hy3131_model.md 5.2 step 3
@ Deviation: none
@ Normal operation: cal_divide_by_gain.  While a capture is running the CAL routine fn_0800F470 takes the value instead.
@ -----------------------------------------------------------------------------
FUNC fn_0800F37E
    push {r3, r4, r5, lr}              @ 0x0800F37E
    movs r4, r0                        @ 0x0800F380
    movs r5, #0                        @ 0x0800F382
    ldr r0, =v_20008090                @ 0x0800F384 pool 0x0800FDCC = 0x20008090
    ldrb r0, [r0, #0]                  @ 0x0800F388
    cmp r0, #0                         @ 0x0800F38A
    beq .L0800F398                     @ 0x0800F38C
    movs r0, r4                        @ 0x0800F38E
    bl fn_0800F470                     @ 0x0800F390
    movs r5, r0                        @ 0x0800F394
    b .L0800F3B4                       @ 0x0800F396
.L0800F398:                              @ reached from 0x0800F38C beq
    ldr r0, =v_2000808E                @ 0x0800F398 pool 0x0800FF00 = 0x2000808E
    ldrb r0, [r0, #0]                  @ 0x0800F39C
    cmp r0, #0                         @ 0x0800F39E
    beq .L0800F3AC                     @ 0x0800F3A0
    movs r0, r4                        @ 0x0800F3A2
    bl fn_0800F470                     @ 0x0800F3A4
    movs r5, r0                        @ 0x0800F3A8
    b .L0800F3B4                       @ 0x0800F3AA
.L0800F3AC:                              @ reached from 0x0800F3A0 beq
    movs r0, r4                        @ 0x0800F3AC
    bl cal_divide_by_gain              @ 0x0800F3AE
    movs r5, r0                        @ 0x0800F3B2
.L0800F3B4:                              @ reached from 0x0800F396 b, 0x0800F3AA b
    movs r0, r5                        @ 0x0800F3B4
    pop {r1, r4, r5, pc}               @ 0x0800F3B6
    .ltorg
ENDFUNC fn_0800F37E

@ -----------------------------------------------------------------------------
@ cal_divide_by_gain - calibrated value = round(x / gain)
@ Replaces : 0x0800F3B8 cal_divide_by_gain (v2.05)
@ In       : r0 = x, the offset-corrected code (i32)
@ Out      : r0 = round(x / gain) as i32, 0 when the gain is 0.0
@ Clobbers : r0-r3, r12, flags (r4-r8 preserved)
@ Context  : main only
@ RAM      : reads  0x200080B9 filter_1khz, 0x2000803C meter_mode
@ Spec     : analysis/hy3131_model.md 5.2 steps 3, 3a; ORIGINAL_FIRMWARE_ISSUES.md OF-15, OF-26
@ Deviation: OF-15
@ q = (float)x / gain in single precision; with the 1 kHz filter on in ACV / ACmV the gain is first divided by 10.0f (counts are then
@ 10x larger; MAC scales them back, OF-26).  v2.05 added 0.5 and truncated toward zero (0x0800F424..0x0800F42E), which rounds only
@ positive quotients correctly: -12344.6 became -12344.  The port adds +0.5 for q >= 0 and -0.5 for q < 0 before the truncating
@ double -> int conversion (round half away from zero); the helper sequence is otherwise unchanged.
@ -----------------------------------------------------------------------------
FUNC cal_divide_by_gain
    @ r4 = x (offset-corrected code), r6 = gain
    stmdb sp!, {r4, r5, r6, r7, r8, lr} @ 0x0800F3B8
    movs r4, r0                        @ 0x0800F3BC
    bl fn_0800F648                     @ 0x0800F3BE  r0 = gain (float32)
    movs r6, r0                        @ 0x0800F3C2
    movs r0, r6                        @ 0x0800F3C4
    movs r1, #0                        @ 0x0800F3C6
    bl fn_0801BD08                     @ 0x0800F3C8  compare gain with 0.0
    bne .L0800F3D4                     @ 0x0800F3CC  gain != 0: divide
    movs r0, #0                        @ 0x0800F3CE  gain == 0: quotient 0.0f (v2.05 divide-by-zero result kept)
    movs r5, r0                        @ 0x0800F3D0
    b .L0800F41E                       @ 0x0800F3D2
.L0800F3D4:                              @ reached from 0x0800F3CC bne
    ldr r0, =meter_mode                @ 0x0800F3D4 pool 0x0800FD7C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800F3D8
    cmp r0, #2                         @ 0x0800F3DA  mode 2 (ACV)?
    beq .L0800F3E8                     @ 0x0800F3DC
    ldr r0, =meter_mode                @ 0x0800F3DE pool 0x0800FD7C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800F3E2
    cmp r0, #4                         @ 0x0800F3E4  mode 4 (ACmV)?
    bne .L0800F410                     @ 0x0800F3E6
.L0800F3E8:                              @ reached from 0x0800F3DC beq
    ldr r0, =filter_1khz               @ 0x0800F3E8 pool 0x0800FE0C = 0x200080B9
    ldrb r0, [r0, #0]                  @ 0x0800F3EC
    cmp r0, #1                         @ 0x0800F3EE  1 kHz filter on?
    bne .L0800F410                     @ 0x0800F3F0
    movs r0, r4                        @ 0x0800F3F2
    bl fn_08012F60                     @ 0x0800F3F4  (float)x
    mov r8, r0                         @ 0x0800F3F8
    movs r0, r6                        @ 0x0800F3FA
    ldr r1, =0x41200000                @ 0x0800F3FC pool 0x0800FE10 = 0x41200000  10.0f
    bl fn_08012F94                     @ 0x0800F400  gain / 10.0f: the filter divides the AC reading by a tenth of the gain, so the count is 10x (OF-26: MAC scales it back)
    movs r1, r0                        @ 0x0800F404
    mov r0, r8                         @ 0x0800F406
    bl fn_08012F94                     @ 0x0800F408  (float)x / (gain / 10)
    movs r5, r0                        @ 0x0800F40C
    b .L0800F41E                       @ 0x0800F40E
.L0800F410:                              @ reached from 0x0800F3E6 bne, 0x0800F3F0 bne
    movs r0, r4                        @ 0x0800F410
    bl fn_08012F60                     @ 0x0800F412  (float)x
    movs r1, r6                        @ 0x0800F416
    bl fn_08012F94                     @ 0x0800F418  (float)x / gain
    movs r5, r0                        @ 0x0800F41C
.L0800F41E:                              @ reached from 0x0800F3D2 b, 0x0800F40E b
    @ r5 = float quotient: round to an integer (OF-15)
    movs r0, r5                        @ 0x0800F41E
    bl fn_08013168                     @ 0x0800F420  quotient as double
    movs r2, #0                             @ low word of +-0.5
    cmp r1, #0                              @ r1 = high word of the double quotient: bit 31 set = negative (also -0.0)
    blt .Ldg_neg
    ldr r3, =0x3FE00000                     @ +0.5 for a quotient >= 0 (v2.05 0x0800F426)
    b .Ldg_add
.Ldg_neg:
    ldr r3, =0xBFE00000                     @ OF-15: -0.5 for a negative quotient, so that the truncation below rounds half away from zero
.Ldg_add:
    bl fn_080131B8                          @ q + 0.5 (q >= 0) or q - 0.5 (q < 0), double add (v2.05 0x0800F42A)
    bl fn_080132A0                     @ 0x0800F42E
    movs r7, r0                        @ 0x0800F432
    movs r0, r7                        @ 0x0800F434
    ldmia.w sp!, {r4, r5, r6, r7, r8, pc} @ 0x0800F436
    .ltorg
ENDFUNC cal_divide_by_gain
