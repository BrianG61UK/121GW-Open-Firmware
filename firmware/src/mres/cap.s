@ =============================================================================
@ cap.s - MRES: capacitance (CAP, mode 12) chain, no-signal timeout and timeout reload
@
@ Replaces v2.05 FUN_0800B33C 0x0800B33C (counter result -> capacitance), FUN_0800B540 0x0800B540 (timeout, called from
@ hy3131_poll) and FUN_0800EC28 0x0800EC28 (timeout reload).
@
@ CAP uses the HY3131 counter (rows 0x080286D0 / 0x08028748): each counter result gives CTC (high ticks) and CTB (cycles) in
@ 0x20007E44 / 0x20007E40; X = CTC / CTB (ranges 0, 1, 5) or CTC * 100 / CTB (ranges 2, 3, 4) goes through the record (offset in
@ ranges 0, 1, gain in all) to counts; smoothing with threshold X/10 (range 5) or X/50 (min 20), depth 10 (analysis/hy3131_modes_misc.md 5.5).
@
@ No result within the timeout (0x20007FC4 counts down in IRQ28 to 0x200080A3 = 1): FUN_0800B540 raises overload (manual / calibration)
@ or jumps the range (auto: 0/1 -> 2, 2..4 -> 5) and re-applies.
@
@ OF-33: the range jump now sets the display-blank flag 0x2000805C (cleared by autorange_step at the next result, as for any range
@ change) and the value redraw request 0x2000805F (outside HOLD), so the refresh of the same pass draws blank digits before
@ meter_apply_mode_range commits the new range's decimal point; the old count is not drawn with it.
@ IMP-45: the anti-hunting rule (antihunt.s, SETUP page HUnt) counts a range-1 timeout here (ah_timeout_note, before the jump) and
@ follows each accepted result (ah_result); ar_sample / autorange_step refuse the step down from range 2 while it is locked.
@ IMP-01 (production): the unsmoothed count X is passed to ar_sample (r1 = 0: counter modes have no AD1 code); a discarded result is not smoothed or published.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mres.cap, "ax", %progbits

    .equ CAP_R1_AUTO_TICKS, 250                 @ IMP-43 (experimental): 2.5 s of 10 ms TIM2 ticks for CAP range 1 in auto range

@ -----------------------------------------------------------------------------
@ fn_0800EC28 - reload the CAP no-signal timeout
@ Replaces : 0x0800EC28 FUN_0800EC28 (v2.05)
@ In       : - (mode 12 only; other modes: nothing)
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x2000803D meter_range, 0x20008042 range_manual, 0x20007FDF
@            writes 0x20007FC4, 0x20007FC6, 0x200080A3
@ Spec     : analysis/hy3131_modes_misc.md 5.5 (timeout)
@ Deviation: IMP-43 (experimental): range 1 (100 nF) in auto range reloads CAP_R1_AUTO_TICKS (250 = 2.5 s) instead of
@            200 (strap 0) / 150 (strap 1): a slow 100 nF ceramic gets time for its result before the jump to range 2
@            (1 uF), which shows it with a tenth of the resolution
@ Reload in TIM2 ticks by 0x20007FDF (PF8 strap), manual flag 0x20008042 and range 0..5: strap 0: 200 for ranges 0..4 (300 for 0, 1 manual), 300 for 5;
@ strap 1: 200, 150 (300 manual), 200, 200, 200, 300 (v2.05; range 1 auto 250 in both, IMP-43).
@ -----------------------------------------------------------------------------
FUNC fn_0800EC28
    @ only in mode 12 (CAP)
    ldr r0, =meter_mode                @ 0x0800EC28 pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800EC2C
    cmp r0, #12                        @ 0x0800EC2E
    bne .L0800ECF4                     @ 0x0800EC30
    @ 0x200080A3 = 0, 0x20007FC6 = 0
    movs r0, #0                        @ 0x0800EC32
    ldr r1, =v_200080A3                @ 0x0800EC34 pool 0x0800F6AC = 0x200080A3
    strb r0, [r1, #0]                  @ 0x0800EC38
    movs r0, #0                        @ 0x0800EC3A
    ldr r1, =v_20007FC6                @ 0x0800EC3C pool 0x0800F6B0 = 0x20007FC6
    strh r0, [r1, #0]                  @ 0x0800EC40
    @ PF8 strap (0x20007FDF) set: 200, 150 (manual 300), 200, 200, 200, 300 by range; strap clear: 200 (manual 300) for
    @ ranges 0, 1, 200 for 2..4, 300 for 5 (reload in TIM2 ticks into 0x20007FC4); range 1 auto: CAP_R1_AUTO_TICKS (IMP-43)
    ldr r0, =v_20007FDF                @ 0x0800EC42 pool 0x0800F6B4 = 0x20007FDF
    ldrb r0, [r0, #0]                  @ 0x0800EC46
    cmp r0, #0                         @ 0x0800EC48
    beq .L0800ECA8                     @ 0x0800EC4A
    ldr r0, =meter_range               @ 0x0800EC4C pool 0x0800F6B8 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800EC50
    cmp r0, #0                         @ 0x0800EC52
    beq .L0800EC68                     @ 0x0800EC54
    cmp r0, #2                         @ 0x0800EC56
    beq .L0800EC92                     @ 0x0800EC58
    bcc .L0800EC72                     @ 0x0800EC5A
    cmp r0, #4                         @ 0x0800EC5C
    beq .L0800EC92                     @ 0x0800EC5E
    bcc .L0800EC92                     @ 0x0800EC60
    cmp r0, #5                         @ 0x0800EC62
    beq .L0800EC9C                     @ 0x0800EC64
    b .L0800ECF4                       @ 0x0800EC66
.L0800EC68:                              @ reached from 0x0800EC54 beq
    movs r0, #200                      @ 0x0800EC68
    ldr r1, =v_20007FC4                @ 0x0800EC6A pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800EC6E
    b .L0800ECF4                       @ 0x0800EC70
.L0800EC72:                              @ reached from 0x0800EC5A bcc
    ldr r0, =range_manual              @ 0x0800EC72 pool 0x0800F6BC = 0x20008042
    ldrb r0, [r0, #0]                  @ 0x0800EC76
    cmp r0, #0                         @ 0x0800EC78
    beq .L0800EC88                     @ 0x0800EC7A
    mov.w r0, #300                     @ 0x0800EC7C
    ldr r1, =v_20007FC4                @ 0x0800EC80 pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800EC84
    b .L0800EC90                       @ 0x0800EC86
.L0800EC88:                              @ reached from 0x0800EC7A beq
    movs r0, #CAP_R1_AUTO_TICKS        @ 0x0800EC88 v2.05: 150 (IMP-43)
    ldr r1, =v_20007FC4                @ 0x0800EC8A pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800EC8E
.L0800EC90:                              @ reached from 0x0800EC86 b
    b .L0800ECF4                       @ 0x0800EC90
.L0800EC92:                              @ reached from 0x0800EC58 beq, 0x0800EC5E beq, 0x0800EC60 bcc
    movs r0, #200                      @ 0x0800EC92
    ldr r1, =v_20007FC4                @ 0x0800EC94 pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800EC98
    b .L0800ECF4                       @ 0x0800EC9A
.L0800EC9C:                              @ reached from 0x0800EC64 beq
    mov.w r0, #300                     @ 0x0800EC9C
    ldr r1, =v_20007FC4                @ 0x0800ECA0 pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800ECA4
    b .L0800ECF4                       @ 0x0800ECA6
.L0800ECA8:                              @ reached from 0x0800EC4A beq
    ldr r0, =meter_range               @ 0x0800ECA8 pool 0x0800F6B8 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800ECAC
    cmp r0, #0                         @ 0x0800ECAE
    cmp r0, #1                         @ 0x0800ECB0
    bls .L0800ECC0                     @ 0x0800ECB2
    subs r0, r0, #2                    @ 0x0800ECB4
    cmp r0, #2                         @ 0x0800ECB6
    bls .L0800ECE0                     @ 0x0800ECB8
    subs r0, r0, #3                    @ 0x0800ECBA
    beq .L0800ECEA                     @ 0x0800ECBC
    b .L0800ECF4                       @ 0x0800ECBE
.L0800ECC0:                              @ reached from 0x0800ECB2 bls
    ldr r0, =range_manual              @ 0x0800ECC0 pool 0x0800F6BC = 0x20008042
    ldrb r0, [r0, #0]                  @ 0x0800ECC4
    cmp r0, #0                         @ 0x0800ECC6
    beq .L0800ECD6                     @ 0x0800ECC8
    mov.w r0, #300                     @ 0x0800ECCA
    ldr r1, =v_20007FC4                @ 0x0800ECCE pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800ECD2
    b .L0800ECDE                       @ 0x0800ECD4
.L0800ECD6:                              @ reached from 0x0800ECC8 beq
    ldr r0, =meter_range               @ ranges 0 and 1 share this reload in v2.05 (200)
    ldrb r0, [r0, #0]
    cmp r0, #1
    ite eq
    moveq r0, #CAP_R1_AUTO_TICKS       @ range 1 auto: IMP-43
    movne r0, #200                     @ 0x0800ECD6 range 0 auto: 200 as v2.05
    ldr r1, =v_20007FC4                @ 0x0800ECD8 pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800ECDC
.L0800ECDE:                              @ reached from 0x0800ECD4 b
    b .L0800ECF4                       @ 0x0800ECDE
.L0800ECE0:                              @ reached from 0x0800ECB8 bls
    movs r0, #200                      @ 0x0800ECE0
    ldr r1, =v_20007FC4                @ 0x0800ECE2 pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800ECE6
    b .L0800ECF4                       @ 0x0800ECE8
.L0800ECEA:                              @ reached from 0x0800ECBC beq
    mov.w r0, #300                     @ 0x0800ECEA
    ldr r1, =v_20007FC4                @ 0x0800ECEE pool 0x0800F8C4 = 0x20007FC4
    strh r0, [r1, #0]                  @ 0x0800ECF2
.L0800ECF4:                              @ reached from 0x0800EC30 bne, 0x0800EC66 b, 0x0800EC70 b, 0x0800EC90 b, 0x0800EC9A b, 0x0800ECA6 b, 0x0800ECBE b, 0x0800ECDE b, 0x0800ECE8 b
    bx lr                              @ 0x0800ECF4
    .ltorg
ENDFUNC fn_0800EC28

@ -----------------------------------------------------------------------------
@ fn_0800B33C - CAP chain: counter result -> displayed capacitance
@ Replaces : 0x0800B33C FUN_0800B33C (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 preserved)
@ Context  : main only
@ RAM      : reads  0x20007E10 cal_gain, 0x20007E00 cal_offset, 0x2000803D meter_range, 0x20008042 range_manual,
@            0x20007D08, 0x20007D64, 0x20007E40, 0x20007E44, 0x20007E68, 0x20007FC6, 0x2000808A, 0x2000808C,
@            0x2000808E, 0x200080A4 (ah_result: set_hunt_on, range_manual, 0x2000805C, ah_lock, ah_ref)
@            writes 0x20007D08, 0x20007D64, 0x20007E68, 0x20007FC8, 0x20008045, 0x2000805D, 0x200080A4
@ Spec     : analysis/hy3131_modes_misc.md 5.5
@ Deviation: IMP-01, IMP-45
@ X = CTC / CTB (ranges 0, 1, 5) or CTC * 100 / CTB; ranges 0, 1: X = X - offset (0 if offset >= X), then X = f2uiz(X / gain) if gain != 0 and X != 0;
@ ranges 2..5: X = f2uiz(X / gain) with no offset and no gain test (f2uiz truncates, DEF-11).  A capture running (0x2000808C / 0x2000808E) calls the CAL
@ routines fn_0800F034 / fn_0800F6C0 / fn_0800F470, which arm NVM themselves.  Smoothing: threshold X/10 (range 5) or X/50, at least 20, depth 10;
@ ranges 2..4 show 0 below 21 counts; 0x2000805D = 1 except in manual range 4 outside calibration while 0x200080A4 counts down.
@ IMP-45: every accepted result (ar_sample returned 0) calls ah_result (antihunt.s) before the timeout reload; it clears the
@ anti-hunting count on range 1 and keeps the lock reference / ends the lock on range 2.
@ -----------------------------------------------------------------------------
FUNC fn_0800B33C
    push {r4, lr}                      @ 0x0800B33C
    @ sign flag 0x20008045 = 0
    movs r0, #0                        @ 0x0800B33E
    ldr r1, =v_20008045                @ 0x0800B340 pool 0x0800BEA0 = 0x20008045
    strb r0, [r1, #0]                  @ 0x0800B344
    @ X (0x20007E68) = CTC / CTB (range 5 and ranges 0, 1) or CTC * 100 / CTB (ranges 2, 3, 4)
    ldr r0, =meter_range               @ 0x0800B346 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B34A
    cmp r0, #5                         @ 0x0800B34C
    bne .L0800B364                     @ 0x0800B34E
    ldr r0, =v_20007E44                @ 0x0800B350 pool 0x0800B6C8 = 0x20007E44
    ldr r0, [r0, #0]                   @ 0x0800B352
    ldr r1, =v_20007E40                @ 0x0800B354 pool 0x0800B678 = 0x20007E40
    ldr r1, [r1, #0]                   @ 0x0800B356
    udiv r0, r0, r1                    @ 0x0800B358
    ldr r1, =v_20007E68                @ 0x0800B35C pool 0x0800BEA4 = 0x20007E68
    str r0, [r1, #0]                   @ 0x0800B360
    b .L0800B398                       @ 0x0800B362
.L0800B364:                              @ reached from 0x0800B34E bne
    ldr r0, =meter_range               @ 0x0800B364 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B368
    cmp r0, #2                         @ 0x0800B36A
    bge .L0800B382                     @ 0x0800B36C
    ldr r0, =v_20007E44                @ 0x0800B36E pool 0x0800B6C8 = 0x20007E44
    ldr r0, [r0, #0]                   @ 0x0800B370
    ldr r1, =v_20007E40                @ 0x0800B372 pool 0x0800B678 = 0x20007E40
    ldr r1, [r1, #0]                   @ 0x0800B374
    udiv r0, r0, r1                    @ 0x0800B376
    ldr r1, =v_20007E68                @ 0x0800B37A pool 0x0800BEA4 = 0x20007E68
    str r0, [r1, #0]                   @ 0x0800B37E
    b .L0800B398                       @ 0x0800B380
.L0800B382:                              @ reached from 0x0800B36C bge
    ldr r0, =v_20007E44                @ 0x0800B382 pool 0x0800B6C8 = 0x20007E44
    ldr r0, [r0, #0]                   @ 0x0800B384
    movs r1, #100                      @ 0x0800B386
    muls r0, r1                        @ 0x0800B388
    ldr r1, =v_20007E40                @ 0x0800B38A pool 0x0800B678 = 0x20007E40
    ldr r1, [r1, #0]                   @ 0x0800B38C
    udiv r0, r0, r1                    @ 0x0800B38E
    ldr r1, =v_20007E68                @ 0x0800B392 pool 0x0800BEA4 = 0x20007E68
    str r0, [r1, #0]                   @ 0x0800B396
.L0800B398:                              @ reached from 0x0800B362 b, 0x0800B380 b
    @ ranges 0, 1: offset and gain; ranges 2..5: gain only
    ldr r0, =meter_range               @ 0x0800B398 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B39C
    cmp r0, #2                         @ 0x0800B39E
    bge .L0800B440                     @ 0x0800B3A0
    @ capture running (0x2000808C): CAL fn_0800F034 gives the reference value 0x20007D08
    ldr r0, =v_2000808C                @ 0x0800B3A2 pool 0x0800BEA8 = 0x2000808C
    ldrb r0, [r0, #0]                  @ 0x0800B3A6
    cmp r0, #0                         @ 0x0800B3A8
    beq .L0800B3BE                     @ 0x0800B3AA
    ldr r0, =v_20007E68                @ 0x0800B3AC pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B3B0
    bl fn_0800F034                     @ 0x0800B3B2
    ldr r1, =v_20007D08                @ 0x0800B3B6 pool 0x0800BF7C = 0x20007D08
    str r0, [r1, #0]                   @ 0x0800B3BA
    b .L0800B474                       @ 0x0800B3BC
.L0800B3BE:                              @ reached from 0x0800B3AA beq
    @ second capture (0x2000808E): CAL fn_0800F6C0(X, 0x20007D08)
    ldr r0, =v_2000808E                @ 0x0800B3BE pool 0x0800BF80 = 0x2000808E
    ldrb r0, [r0, #0]                  @ 0x0800B3C2
    cmp r0, #0                         @ 0x0800B3C4
    beq .L0800B3DA                     @ 0x0800B3C6
    ldr r0, =v_20007D08                @ 0x0800B3C8 pool 0x0800BF7C = 0x20007D08
    ldr r1, [r0, #0]                   @ 0x0800B3CC
    ldr r0, =v_20007E68                @ 0x0800B3CE pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B3D2
    bl fn_0800F6C0                     @ 0x0800B3D4
    b .L0800B474                       @ 0x0800B3D8
.L0800B3DA:                              @ reached from 0x0800B3C6 beq
    @ normal operation: X = X - offset (0 when the offset is not below X, unsigned compare)
    ldr r0, =cal_offset                @ 0x0800B3DA pool 0x0800BF84 = 0x20007E00
    ldr r0, [r0, #0]                   @ 0x0800B3DE
    ldr r1, =v_20007E68                @ 0x0800B3E0 pool 0x0800BEA4 = 0x20007E68
    ldr r1, [r1, #0]                   @ 0x0800B3E4
    cmp r0, r1                         @ 0x0800B3E6
    bcc .L0800B3F4                     @ 0x0800B3E8
    movs r0, #0                        @ 0x0800B3EA
    ldr r1, =v_20007E68                @ 0x0800B3EC pool 0x0800BEA4 = 0x20007E68
    str r0, [r1, #0]                   @ 0x0800B3F0
    b .L0800B408                       @ 0x0800B3F2
.L0800B3F4:                              @ reached from 0x0800B3E8 bcc
    ldr r0, =v_20007E68                @ 0x0800B3F4 pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B3F8
    ldr r1, =cal_offset                @ 0x0800B3FA pool 0x0800BF84 = 0x20007E00
    ldr r1, [r1, #0]                   @ 0x0800B3FE
    subs r0, r0, r1                    @ 0x0800B400
    ldr r1, =v_20007E68                @ 0x0800B402 pool 0x0800BEA4 = 0x20007E68
    str r0, [r1, #0]                   @ 0x0800B406
.L0800B408:                              @ reached from 0x0800B3F2 b
    @ gain != 0.0 and X != 0: X = f2uiz(X / gain)
    ldr r0, =cal_gain                  @ 0x0800B408 pool 0x0800BF88 = 0x20007E10
    ldr r0, [r0, #0]                   @ 0x0800B40C
    movs r1, #0                        @ 0x0800B40E
    bl fn_0801BD08                     @ 0x0800B410
    beq .L0800B474                     @ 0x0800B414
    ldr r0, =v_20007E68                @ 0x0800B416 pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B41A
    cmp r0, #0                         @ 0x0800B41C
    beq .L0800B474                     @ 0x0800B41E
    ldr r0, =v_20007E68                @ 0x0800B420 pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B424
    bl fn_08012F74                     @ 0x0800B426
    ldr r1, =cal_gain                  @ 0x0800B42A pool 0x0800BF88 = 0x20007E10
    ldr r1, [r1, #0]                   @ 0x0800B42E
    bl fn_08012F94                     @ 0x0800B430
    bl fn_0801BD24                     @ 0x0800B434
    ldr r1, =v_20007E68                @ 0x0800B438 pool 0x0800BEA4 = 0x20007E68
    str r0, [r1, #0]                   @ 0x0800B43C
    b .L0800B474                       @ 0x0800B43E
.L0800B440:                              @ reached from 0x0800B3A0 bge
    @ ranges 2..5: capture 0x2000808E -> CAL fn_0800F470(X); else X = f2uiz(X / gain) with no offset and no gain test (DEF-11)
    ldr r0, =v_2000808E                @ 0x0800B440 pool 0x0800BF80 = 0x2000808E
    ldrb r0, [r0, #0]                  @ 0x0800B444
    cmp r0, #0                         @ 0x0800B446
    beq .L0800B456                     @ 0x0800B448
    ldr r0, =v_20007E68                @ 0x0800B44A pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B44E
    bl fn_0800F470                     @ 0x0800B450
    b .L0800B474                       @ 0x0800B454
.L0800B456:                              @ reached from 0x0800B448 beq
    ldr r0, =v_20007E68                @ 0x0800B456 pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B45A
    bl fn_08012F74                     @ 0x0800B45C
    ldr r1, =cal_gain                  @ 0x0800B460 pool 0x0800BF88 = 0x20007E10
    ldr r1, [r1, #0]                   @ 0x0800B464
    bl fn_08012F94                     @ 0x0800B466
    bl fn_0801BD24                     @ 0x0800B46A
    ldr r1, =v_20007E68                @ 0x0800B46E pool 0x0800BEA4 = 0x20007E68
    str r0, [r1, #0]                   @ 0x0800B472
.L0800B474:                              @ reached from 0x0800B3BC b, 0x0800B3D8 b, 0x0800B414 beq, 0x0800B41E beq, 0x0800B43E b, 0x0800B454 b
    ldr r0, =v_20007E68
    ldr r0, [r0]                            @ X: unsmoothed count of this counter result
    movs r1, #0                             @ no AD1 code in the counter modes
    bl ar_sample                            @ IMP-01; r0 = 1: discard this result (settling after an apply / apply pending)
    cmp r0, #0
    bne .Lcap_discard
    ldr r0, =meter_range               @ 0x0800B474 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B478
    cmp r0, #5                         @ 0x0800B47A
    bne .L0800B48E                     @ 0x0800B47C
    ldr r0, =v_20007E68                @ 0x0800B47E pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B482
    movs r1, #10                       @ 0x0800B484
    udiv r0, r0, r1                    @ 0x0800B486
    movs r4, r0                        @ 0x0800B48A
    b .L0800B49C                       @ 0x0800B48C
.L0800B48E:                              @ reached from 0x0800B47C bne
    ldr r0, =v_20007E68                @ 0x0800B48E pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B492
    movs r1, #50                       @ 0x0800B494
    udiv r0, r0, r1                    @ 0x0800B496
    movs r4, r0                        @ 0x0800B49A
.L0800B49C:                              @ reached from 0x0800B48C b
    uxth r4, r4                        @ 0x0800B49C
    cmp r4, #20                        @ 0x0800B49E
    bge .L0800B4A6                     @ 0x0800B4A0
    movs r0, #20                       @ 0x0800B4A2
    movs r4, r0                        @ 0x0800B4A4
.L0800B4A6:                              @ reached from 0x0800B4A0 bge
    @ D = fn_0800B754(X, threshold, 10) with threshold X/10 (range 5) or X/50, at least 20
    movs r2, #10                       @ 0x0800B4A6
    uxth r4, r4                        @ 0x0800B4A8
    movs r1, r4                        @ 0x0800B4AA
    ldr r0, =v_20007E68                @ 0x0800B4AC pool 0x0800BEA4 = 0x20007E68
    ldr r0, [r0, #0]                   @ 0x0800B4B0
    bl fn_0800B754                     @ 0x0800B4B2
    ldr r1, =v_20007D64                @ 0x0800B4B6 pool 0x0800B970 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800B4BA
    @ ranges 2..4: D below 21 counts is shown as 0
    ldr r0, =meter_range               @ 0x0800B4BC pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B4C0
    cmp r0, #2                         @ 0x0800B4C2
    blt .L0800B4E2                     @ 0x0800B4C4
    ldr r0, =meter_range               @ 0x0800B4C6 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B4CA
    cmp r0, #5                         @ 0x0800B4CC
    bge .L0800B4E2                     @ 0x0800B4CE
    ldr r0, =v_20007D64                @ 0x0800B4D0 pool 0x0800B970 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x0800B4D4
    cmp r0, #21                        @ 0x0800B4D6
    bge .L0800B4E2                     @ 0x0800B4D8
    movs r0, #0                        @ 0x0800B4DA
    ldr r1, =v_20007D64                @ 0x0800B4DC pool 0x0800B970 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800B4E0
.L0800B4E2:                              @ reached from 0x0800B4C4 blt, 0x0800B4CE bge, 0x0800B4D8 bge
    @ 0x20007FC8 = 0x20007FC6; 0x2000805D = 1 except in manual range 4 outside calibration mode while 0x200080A4 counts down
    ldr r0, =v_20007FC6                @ 0x0800B4E2 pool 0x0800C0B0 = 0x20007FC6
    ldrh r0, [r0, #0]                  @ 0x0800B4E6
    ldr r1, =v_20007FC8                @ 0x0800B4E8 pool 0x0800C0B4 = 0x20007FC8
    strh r0, [r1, #0]                  @ 0x0800B4EC
    ldr r0, =range_manual              @ 0x0800B4EE pool 0x0800B73C = 0x20008042
    ldrb r0, [r0, #0]                  @ 0x0800B4F0
    ldr r1, =v_2000808A                @ 0x0800B4F2 pool 0x0800C0B8 = 0x2000808A
    ldrb r1, [r1, #0]                  @ 0x0800B4F6
    eors.w r1, r1, #1                  @ 0x0800B4F8
    tst r0, r1                         @ 0x0800B4FC
    beq .L0800B524                     @ 0x0800B4FE
    ldr r0, =meter_range               @ 0x0800B500 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B504
    cmp r0, #4                         @ 0x0800B506
    bne .L0800B524                     @ 0x0800B508
    ldr r0, =v_200080A4                @ 0x0800B50A pool 0x0800C0BC = 0x200080A4
    ldrb r0, [r0, #0]                  @ 0x0800B50E
    cmp r0, #0                         @ 0x0800B510
    beq .L0800B524                     @ 0x0800B512
    ldr r0, =v_200080A4                @ 0x0800B514 pool 0x0800C0BC = 0x200080A4
    ldrb r0, [r0, #0]                  @ 0x0800B518
    subs r0, r0, #1                    @ 0x0800B51A
    ldr r1, =v_200080A4                @ 0x0800B51C pool 0x0800C0BC = 0x200080A4
    strb r0, [r1, #0]                  @ 0x0800B520
    b .L0800B52C                       @ 0x0800B522
.L0800B524:                              @ reached from 0x0800B4FE beq, 0x0800B508 bne, 0x0800B512 beq
    movs r0, #1                        @ 0x0800B524
    ldr r1, =v_2000805D                @ 0x0800B526 pool 0x0800B968 = 0x2000805D
    strb r0, [r1, #0]                  @ 0x0800B52A
.L0800B52C:                              @ reached from 0x0800B522 b; every accepted result passes here
    bl ah_result                       @ IMP-45: anti-hunting state follows the accepted result (range 1: count reset; range 2: lock reference / unlock)
.Lcap_discard:                              @ discarded result: no smoothing, no new value; only the no-signal timeout is reloaded
    bl fn_0800EC28                     @ 0x0800B52C
    pop {r4, pc}                       @ 0x0800B530
    .ltorg
ENDFUNC fn_0800B33C

@ -----------------------------------------------------------------------------
@ fn_0800B540 - CAP no-signal timeout: overload (manual) or range jump (auto)
@ Replaces : 0x0800B540 FUN_0800B540 (v2.05)
@ In       : - (called by hy3131_poll in mode 12, range < 5)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x2000803D meter_range, 0x20008042 range_manual, 0x2000808A, 0x200080A2, 0x200080A3, hold_active, hold_stage2
@            (ah_timeout_note: set_hunt_on, ah_timeouts)
@            writes 0x2000803D meter_range, 0x20008046, 0x2000804A, 0x2000804B, 0x2000805C, 0x2000805D, 0x2000805F, 0x2000807C,
@            0x200080A2, 0x200080A3, 0x200080A4
@ Spec     : analysis/hy3131_modes_misc.md 5.5 (timeout); ORIGINAL_FIRMWARE_ISSUES.md OF-33
@ Deviation: OF-33, IMP-45
@ When the timeout flag 0x200080A3 is set: clear it and reload (fn_0800EC28).  Manual range or calibration mode: overload (0x20008046 = 1, new value
@ 0x2000805D = 1; range 4 also 0x200080A4 = 2).  Auto: ranges 0, 1 -> 2 and 2..4 -> 5, 0x2000807C = 0, 0x2000804A = 0, 0x2000804B = 1 (re-apply);
@ if the new range is 2 and 0x200080A2 is set: clear it, overload off, range 0.
@ IMP-45: in the auto branch the range the timeout leaves goes to ah_timeout_note first (antihunt.s), which counts a range-1 timeout
@ while 0x200080A2 is clear.
@ -----------------------------------------------------------------------------
FUNC fn_0800B540
    push {r7, lr}                      @ 0x0800B540
    @ timeout flag 0x200080A3 (set by IRQ28 when the countdown 0x20007FC4 reaches 0)
    ldr r0, =v_200080A3                @ 0x0800B542 pool 0x0800C134 = 0x200080A3
    ldrb r0, [r0, #0]                  @ 0x0800B546
    cmp r0, #0                         @ 0x0800B548
    beq .L0800B600                     @ 0x0800B54A
    movs r0, #0                        @ 0x0800B54C
    ldr r1, =v_200080A3                @ 0x0800B54E pool 0x0800C134 = 0x200080A3
    strb r0, [r1, #0]                  @ 0x0800B552
    @ reload the countdown (fn_0800EC28)
    bl fn_0800EC28                     @ 0x0800B554
    @ manual range (0x20008042) outside calibration mode in range 4: 0x200080A4 = 2
    ldr r0, =range_manual              @ 0x0800B558 pool 0x0800B73C = 0x20008042
    ldrb r0, [r0, #0]                  @ 0x0800B55A
    ldr r1, =v_2000808A                @ 0x0800B55C pool 0x0800C0B8 = 0x2000808A
    ldrb r1, [r1, #0]                  @ 0x0800B560
    eors.w r1, r1, #1                  @ 0x0800B562
    tst r0, r1                         @ 0x0800B566
    beq .L0800B57C                     @ 0x0800B568
    ldr r0, =meter_range               @ 0x0800B56A pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B56E
    cmp r0, #4                         @ 0x0800B570
    bne .L0800B57C                     @ 0x0800B572
    movs r0, #2                        @ 0x0800B574
    ldr r1, =v_200080A4                @ 0x0800B576 pool 0x0800C0BC = 0x200080A4
    strb r0, [r1, #0]                  @ 0x0800B57A
.L0800B57C:                              @ reached from 0x0800B568 beq, 0x0800B572 bne
    @ manual range or calibration mode: overload (0x20008046 = 1) and a new value (0x2000805D = 1)
    ldr r0, =range_manual              @ 0x0800B57C pool 0x0800B73C = 0x20008042
    ldrb r0, [r0, #0]                  @ 0x0800B57E
    ldr r1, =v_2000808A                @ 0x0800B580 pool 0x0800C0B8 = 0x2000808A
    ldrb r1, [r1, #0]                  @ 0x0800B584
    orrs r0, r1                        @ 0x0800B586
    uxtb r0, r0                        @ 0x0800B588
    cmp r0, #0                         @ 0x0800B58A
    beq .L0800B59E                     @ 0x0800B58C
    movs r0, #1                        @ 0x0800B58E
    ldr r1, =v_20008046                @ 0x0800B590 pool 0x0800B738 = 0x20008046
    strb r0, [r1, #0]                  @ 0x0800B592
    movs r0, #1                        @ 0x0800B594
    ldr r1, =v_2000805D                @ 0x0800B596 pool 0x0800B968 = 0x2000805D
    strb r0, [r1, #0]                  @ 0x0800B59A
    b .L0800B600                       @ 0x0800B59C
.L0800B59E:                              @ reached from 0x0800B58C beq
    @ ---- auto range: ranges 0, 1 -> 2; 2, 3, 4 -> 5 ----
    ldr r0, =meter_range               @ 0x0800B59E pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B5A2
    bl ah_timeout_note                 @ IMP-45: r0 = the range the timeout leaves; a range-1 timeout with 0x200080A2 clear is counted (r0 kept)
    cmp r0, #2                         @ 0x0800B5A4
    bge .L0800B5B2                     @ 0x0800B5A6
    movs r0, #2                        @ 0x0800B5A8
    ldr r1, =meter_range               @ 0x0800B5AA pool 0x0800B960 = 0x2000803D
    strb r0, [r1, #0]                  @ 0x0800B5AE
    b .L0800B5C2                       @ 0x0800B5B0
.L0800B5B2:                              @ reached from 0x0800B5A6 bge
    ldr r0, =meter_range               @ 0x0800B5B2 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B5B6
    cmp r0, #5                         @ 0x0800B5B8
    bge .L0800B5C2                     @ 0x0800B5BA
    movs r0, #5                        @ 0x0800B5BC
    ldr r1, =meter_range               @ 0x0800B5BE pool 0x0800B960 = 0x2000803D
    strb r0, [r1, #0]                  @ 0x0800B5C0
.L0800B5C2:                              @ reached from 0x0800B5B0 b, 0x0800B5BA bge
    movs r0, #1
    ldr r1, =v_2000805C
    strb r0, [r1]                           @ OF-33: blank the display across the jump (v2.05 drew the old count with the new decimal point)
    @ OF-33: the blank flag alone is not drawn in this pass: no new result is pending, so the refresh (main loop step 3) does not
    @ call fn_08016E08, and meter_apply_mode_range (step 13) then commits the old digits with the new range's decimal point
    @ (integration trace, cap_values 18.98 s).  A value redraw request (0x2000805F, set as meter_apply_mode_range sets it at
    @ 0x0800D548, i.e. not while HOLD is active or in auto-hold stage 2) makes step 3 draw the blank digits (fn_08019A98 via the
    @ v2.05 blank rule 0x08016FCE..0x08017004) before the apply commits.
    ldr r0, =hold_active
    ldrb r0, [r0]
    ldr r1, =hold_stage2
    ldrb r1, [r1]
    orrs r0, r1
    bne 1f                                  @ HOLD or auto-hold stage 2: the held digits stay (as at 0x0800D544)
    movs r0, #1
    ldr r1, =v_2000805F
    strb r0, [r1]                           @ display request: the refresh of this pass draws the blank digits
1:
    movs r0, #0                        @ 0x0800B5C2
    ldr r1, =v_2000807C                @ 0x0800B5C4 pool 0x0800C1B8 = 0x2000807C
    strb r0, [r1, #0]                  @ 0x0800B5C8
    movs r0, #0                        @ 0x0800B5CA
    ldr r1, =v_2000804A                @ 0x0800B5CC pool 0x0800C1D8 = 0x2000804A
    strb r0, [r1, #0]                  @ 0x0800B5D0
    movs r0, #1                        @ 0x0800B5D2
    ldr r1, =v_2000804B                @ 0x0800B5D4 pool 0x0800C1DC = 0x2000804B
    strb r0, [r1, #0]                  @ 0x0800B5D8
    @ new range 2 with 0x200080A2 set: clear it, overload off, range 0
    ldr r0, =meter_range               @ 0x0800B5DA pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B5DC
    cmp r0, #2                         @ 0x0800B5DE
    bne .L0800B600                     @ 0x0800B5E0
    ldr r0, =v_200080A2                @ 0x0800B5E2 pool 0x0800C1E0 = 0x200080A2
    ldrb r0, [r0, #0]                  @ 0x0800B5E6
    cmp r0, #0                         @ 0x0800B5E8
    beq .L0800B600                     @ 0x0800B5EA
    movs r0, #0                        @ 0x0800B5EC
    ldr r1, =v_200080A2                @ 0x0800B5EE pool 0x0800C1E0 = 0x200080A2
    strb r0, [r1, #0]                  @ 0x0800B5F2
    movs r0, #0                        @ 0x0800B5F4
    ldr r1, =v_20008046                @ 0x0800B5F6 pool 0x0800B738 = 0x20008046
    strb r0, [r1, #0]                  @ 0x0800B5F8
    movs r0, #0                        @ 0x0800B5FA
    ldr r1, =meter_range               @ 0x0800B5FC pool 0x0800B960 = 0x2000803D
    strb r0, [r1, #0]                  @ 0x0800B5FE
.L0800B600:                              @ reached from 0x0800B54A beq, 0x0800B59C b, 0x0800B5E0 bne, 0x0800B5EA beq
    pop {r0, pc}                       @ 0x0800B600
    .ltorg
ENDFUNC fn_0800B540
