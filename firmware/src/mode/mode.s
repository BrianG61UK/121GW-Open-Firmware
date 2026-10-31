@ =============================================================================
@ mode.s - MODE: apply a mode and range to the measuring front end
@
@ Replaces the v2.05 functions meter_apply_mode_range 0x0800D2D0, load_full_scale 0x0800D5F4, FUN_0800D80C,
@ FUN_0800D81E, FUN_0800DB48 and decimal_position_for_mode_range 0x0800D920 (DESIGN.md 6.11, Appendix A MODE).
@ cycle.s holds the MODE and RANGE key helpers and the re-apply variants.
@
@ An apply runs in the main loop (step 13) when a key, the dial, the jack sense or auto-range has set
@ 0x2000804A (mode change) or 0x2000804B (range change): it clears the running mean, resets the per-mode state
@ after a mode change, sets the settle count, loads the full scale, writes the HY3131 row, loads the calibration
@ record and the user zero and sets the front-end pins (analysis/autorange_and_scheduler.md 2.3).
@
@ Deviations: OF-36 (cal_capture_cancel is called at every apply, DESIGN.md 7.2), OF-20 (every apply ends in
@ ar_apply, which clears the overload latch), OPT-06 (decimal_position_for_mode_range is a table).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "mode.inc"

    .section .text.mode.mode, "ax", %progbits

@ -----------------------------------------------------------------------------
@ meter_apply_mode_range - apply the present mode and range to the measuring front end
@ Replaces : 0x0800D2D0 meter_apply_mode_range (v2.05)
@ In       : r0 = 1 for a full apply (logging is stopped when the mode changed); the main loop and the jack sense
@            pass 1
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main (loop step 13 when 0x2000804A or 0x2000804B is set; sense_pe10_pe11; LowZ AC/DC switch of MRES)
@ RAM      : meter_mode, meter_range (read and, for a mode change, written), range_manual, filter_1khz, acdc_active,
@            peak_hold, hold_stage2, mode_mode_req 0x2000804A, mode_range_req 0x2000804B and the measuring state
@            that is cleared here (the blocks below list the addresses); calls load_full_scale, fn_0800D80C (HY3131
@            row, calibration record, user zero), fn_0800FBE8 (front-end pins)
@ Spec     : analysis/autorange_and_scheduler.md 2.3 (what happens after a decision); analysis/rotary.md 2
@ Deviation: OF-36 (cal_capture_cancel at every apply, switch CAL_CANCEL_ON_MODE_CHANGE), OF-20 (the overload latch is
@            cleared by ar_apply, called at the end of fn_0800DB48)
@ -----------------------------------------------------------------------------
FUNC meter_apply_mode_range

@ r4 = the argument.  OHM ranges 1..5 (not 0, not 6): the display skips the next two updates
    push {r4, lr}                       @ 0800D2D0
    movs r4, r0                         @ 0800D2D2
    ldr r0, =meter_mode                 @ 0800D2D4
    ldrb r0, [r0]                       @ 0800D2D6
    cmp r0, #9                          @ 0800D2D8
    bne .Lap_0800D2F8                   @ 0800D2DA
    ldr r0, =meter_range                @ 0800D2DC
    ldrb r0, [r0]                       @ 0800D2E0
    cmp r0, #0                          @ 0800D2E2
    beq .Lap_0800D2F8                   @ 0800D2E4
    ldr r0, =meter_range                @ 0800D2E6
    ldrb r0, [r0]                       @ 0800D2EA
    cmp r0, #6                          @ 0800D2EC
    bge .Lap_0800D2F8                   @ 0800D2EE
    movs r0, #2                         @ 0800D2F0
    ldr r1, =mode_ohm_skip              @ 0800D2F2
    strb r0, [r1]                       @ 0800D2F6

@ clear the running-mean state and the values of the old range: 0x200080A4, 0x2000809A, 0x200080C5, VA channel,
@ last drawn value, sample counters 0x20008081 / 0x20008080, 0x20007D7C / 0x20007D80 (VA), 0x20007E64, 0x200080A1
@ reached from 0800D2DA bne (not equal / non-zero) after cmp r0, #9
@              and from 0800D2E4 beq (equal / zero) after cmp r0, #0
@              and from 0800D2EE bge (signed >=) after cmp r0, #6
.Lap_0800D2F8:
    movs r0, #0                         @ 0800D2F8
    ldr r1, =v_200080A4                 @ 0800D2FA
    strb r0, [r1]                       @ 0800D2FE
    movs r0, #0                         @ 0800D300
    ldr r1, =v_2000809A                 @ 0800D302
    strb r0, [r1]                       @ 0800D306
    movs r0, #0                         @ 0800D308
    ldr r1, =v_200080C5                 @ 0800D30A
    strb r0, [r1]                       @ 0800D30E
    movs r0, #0                         @ 0800D310
    ldr r1, =va_channel                 @ 0800D312
    strb r0, [r1]                       @ 0800D316
    movs r0, #0                         @ 0800D318
    ldr r1, =mode_shown                 @ 0800D31A
    str r0, [r1]                        @ 0800D31E
    movs r0, #0                         @ 0800D320
    ldr r1, =v_20008081                 @ 0800D322
    strb r0, [r1]                       @ 0800D326
    movs r0, #0                         @ 0800D328
    ldr r1, =mode_sample_ctr            @ 0800D32A
    strb r0, [r1]                       @ 0800D32E
    movs r0, #0                         @ 0800D330
    ldr r1, =v_20007D7C                 @ 0800D332
    str r0, [r1]                        @ 0800D336
    movs r0, #0                         @ 0800D338
    ldr r1, =v_20007D80                 @ 0800D33A
    str r0, [r1]                        @ 0800D33E
    movs r0, #0                         @ 0800D340
    ldr r1, =v_20007E64                 @ 0800D342
    str r0, [r1]                        @ 0800D346
    movs r0, #0                         @ 0800D348
    ldr r1, =v_200080A1                 @ 0800D34A
    strb r0, [r1]                       @ 0800D34E

@ ACV with AC+DC: clear the AC and DC components 0x20007E9C / 0x20007EA0
    ldr r0, =meter_mode                 @ 0800D350
    ldrb r0, [r0]                       @ 0800D352
    cmp r0, #2                          @ 0800D354
    bne .Lap_0800D372                   @ 0800D356
    ldr r0, =acdc_active                @ 0800D358
    ldrb r0, [r0]                       @ 0800D35C
    cmp r0, #0                          @ 0800D35E
    beq .Lap_0800D372                   @ 0800D360
    movs r0, #0                         @ 0800D362
    ldr r1, =v_20007E9C                 @ 0800D364
    str r0, [r1]                        @ 0800D368
    movs r0, #0                         @ 0800D36A
    ldr r1, =v_20007EA0                 @ 0800D36C
    str r0, [r1]                        @ 0800D370

@ mode change requested (0x2000804A)?  No: skip to the work common to mode and range changes at 0x0800D48C
@ reached from 0800D356 bne (not equal / non-zero) after cmp r0, #2
@              and from 0800D360 beq (equal / zero) after cmp r0, #0
.Lap_0800D372:
    ldr r0, =mode_mode_req              @ 0800D372
    ldrb r0, [r0]                       @ 0800D376
    cmp r0, #0                          @ 0800D378
    beq .Lap_common                     @ 0800D37A

@ ---- mode change ----  clear the VA sub-range flags, DIODE keeps range_manual = 1 (single range, no ranging),
@ every other mode starts in auto-range; default setup item (fn_0800D718); burden option and setup edit off
    movs r0, #0                         @ 0800D37E
    ldr r1, =v_200080A2                 @ 0800D380
    strb r0, [r1]                       @ 0800D384
    movs r0, #0                         @ 0800D386
    ldr r1, =v_200080C6                 @ 0800D388
    strb r0, [r1]                       @ 0800D38C
    movs r0, #0                         @ 0800D38E
    ldr r1, =v_200080C7                 @ 0800D390
    strb r0, [r1]                       @ 0800D394
    movs r0, #0                         @ 0800D396
    ldr r1, =v_200080C2                 @ 0800D398
    strb r0, [r1]                       @ 0800D39C
    movs r0, #0                         @ 0800D39E
    ldr r1, =v_200080C8                 @ 0800D3A0
    strb r0, [r1]                       @ 0800D3A4
    movs r0, #0                         @ 0800D3A6
    ldr r1, =v_200080C9                 @ 0800D3A8
    strb r0, [r1]                       @ 0800D3AC
    ldr r0, =meter_mode                 @ 0800D3AE
    ldrb r0, [r0]                       @ 0800D3B0
    cmp r0, #0xB                        @ 0800D3B2
    bne .Lap_0800D3C0                   @ 0800D3B4
    movs r0, #1                         @ 0800D3B6
    ldr r1, =range_manual               @ 0800D3B8
    strb r0, [r1]                       @ 0800D3BC
    b .Lap_0800D3C8                     @ 0800D3BE
@ reached from 0800D3B4 bne (not equal / non-zero) after cmp r0, #0xB
.Lap_0800D3C0:
    movs r0, #0                         @ 0800D3C0
    ldr r1, =range_manual               @ 0800D3C2
    strb r0, [r1]                       @ 0800D3C6
@ reached from 0800D3BE b (jump)
.Lap_0800D3C8:
    bl fn_0800D718                      @ 0800D3C8
    movs r0, #0                         @ 0800D3CC
    ldr r1, =v_200080A6                 @ 0800D3CE
    strb r0, [r1]                       @ 0800D3D2
    ldr r0, =v_200080A6                 @ 0800D3D4
    ldrb r0, [r0]                       @ 0800D3D8
    ldr r1, =v_200080A5                 @ 0800D3DA
    strb r0, [r1]                       @ 0800D3DC
    movs r0, #0                         @ 0800D3DE
    ldr r1, =mode_setup_edit            @ 0800D3E0
    strb r0, [r1]                       @ 0800D3E4

@ ACV (not AC+DC) and ACmV: PEAK on keeps the (frozen) range, PEAK off starts at range 0.  OHM outside calibration
@ starts at range 6 (the highest, 50 Mohm); every other mode starts at range 0
    ldr r0, =meter_mode                 @ 0800D3E6
    ldrb r0, [r0]                       @ 0800D3E8
    cmp r0, #2                          @ 0800D3EA
    bne .Lap_0800D3F8                   @ 0800D3EC
    ldr r0, =acdc_active                @ 0800D3EE
    ldrb r0, [r0]                       @ 0800D3F2
    cmp r0, #0                          @ 0800D3F4
    beq .Lap_0800D400                   @ 0800D3F6
@ reached from 0800D3EC bne (not equal / non-zero) after cmp r0, #2
.Lap_0800D3F8:
    ldr r0, =meter_mode                 @ 0800D3F8
    ldrb r0, [r0]                       @ 0800D3FA
    cmp r0, #4                          @ 0800D3FC
    bne .Lap_0800D41E                   @ 0800D3FE
@ reached from 0800D3F6 beq (equal / zero) after cmp r0, #0
.Lap_0800D400:
    ldr r0, =peak_hold                  @ 0800D400
    ldrb r0, [r0]                       @ 0800D404
    cmp r0, #0                          @ 0800D406
    beq .Lap_0800D414                   @ 0800D408
    movs r0, #1                         @ 0800D40A
    ldr r1, =range_manual               @ 0800D40C
    strb r0, [r1]                       @ 0800D410
    b .Lap_0800D442                     @ 0800D412
@ reached from 0800D408 beq (equal / zero) after cmp r0, #0
.Lap_0800D414:
    movs r0, #0                         @ 0800D414
    ldr r1, =meter_range                @ 0800D416
    strb r0, [r1]                       @ 0800D41A
    b .Lap_0800D442                     @ 0800D41C
@ reached from 0800D3FE bne (not equal / non-zero) after cmp r0, #4
.Lap_0800D41E:
    ldr r0, =meter_mode                 @ 0800D41E
    ldrb r0, [r0]                       @ 0800D420
    cmp r0, #9                          @ 0800D422
    bne .Lap_0800D43A                   @ 0800D424
    ldr r0, =mode_cal_mode              @ 0800D426
    ldrb r0, [r0]                       @ 0800D42A
    cmp r0, #0                          @ 0800D42C
    bne .Lap_0800D43A                   @ 0800D42E
    movs r0, #6                         @ 0800D430
    ldr r1, =meter_range                @ 0800D432
    strb r0, [r1]                       @ 0800D436
    b .Lap_0800D442                     @ 0800D438
@ reached from 0800D424 bne (not equal / non-zero) after cmp r0, #9
@              and from 0800D42E bne (not equal / non-zero) after cmp r0, #0
.Lap_0800D43A:
    movs r0, #0                         @ 0800D43A
    ldr r1, =meter_range                @ 0800D43C
    strb r0, [r1]                       @ 0800D440

@ HOLD stage 2 and the helper state of HOLD / REL are cleared by a mode change
@ reached from 0800D412 b (jump)
@              and from 0800D41C b (jump)
@              and from 0800D438 b (jump)
.Lap_0800D442:
    movs r0, #0                         @ 0800D442
    ldr r1, =hold_stage2                @ 0800D444
    strb r0, [r1]                       @ 0800D448
    movs r0, #0                         @ 0800D44A
    ldr r1, =v_20008051                 @ 0800D44C
    strb r0, [r1]                       @ 0800D450
    movs r0, #0                         @ 0800D452
    ldr r1, =v_20008052                 @ 0800D454
    strb r0, [r1]                       @ 0800D458
    movs r0, #0                         @ 0800D45A
    ldr r1, =v_20008053                 @ 0800D45C
    strb r0, [r1]                       @ 0800D460
    movs r0, #0                         @ 0800D462
    ldr r1, =v_20007FB2                 @ 0800D464
    strh r0, [r1]                       @ 0800D468

@ r4 = 1 and logging on: stop logging (fn_08010AF8(1)) before the mode changes; end of MEM view (fn_080153AC)
    uxtb r4, r4                         @ 0800D46A
    cmp r4, #1                          @ 0800D46C
    bne .Lap_0800D488                   @ 0800D46E
    ldr r0, =mode_logging               @ 0800D470
    ldrb r0, [r0]                       @ 0800D474
    cmp r0, #0                          @ 0800D476
    beq .Lap_0800D488                   @ 0800D478
    movs r0, #1                         @ 0800D47A
    bl fn_08010AF8                      @ 0800D47C
    movs r0, #0                         @ 0800D480
    ldr r1, =mode_logging               @ 0800D482
    strb r0, [r1]                       @ 0800D486
@ reached from 0800D46E bne (not equal / non-zero) after cmp r4, #1
@              and from 0800D478 beq (equal / zero) after cmp r0, #0
.Lap_0800D488:
    bl fn_080153AC                      @ 0800D488

@ work common to every apply: timeouts 0x20007FC2 / 0x20007FC0, 0x200080B1 / 0x200080B2 cleared; 1 kHz filter off
@ outside ACV and ACmV; AC+DC off outside ACV; REL and MIN/MAX off; PEAK off unless ACV (no AC+DC) or ACmV
@ reached from 0800D37A beq (equal / zero) after cmp r0, #0
.Lap_common:
    movs r0, #0                         @ 0800D48C
    ldr r1, =v_20007FC2                 @ 0800D48E
    strh r0, [r1]                       @ 0800D492
    movs r0, #0                         @ 0800D494
    ldr r1, =v_20007FC0                 @ 0800D496
    strh r0, [r1]                       @ 0800D49A
    movs r0, #0                         @ 0800D49C
    ldr r1, =v_200080B1                 @ 0800D49E
    strb r0, [r1]                       @ 0800D4A2
    movs r0, #0                         @ 0800D4A4
    ldr r1, =v_200080B2                 @ 0800D4A6
    strb r0, [r1]                       @ 0800D4AA
    ldr r0, =meter_mode                 @ 0800D4AC
    ldrb r0, [r0]                       @ 0800D4AE
    cmp r0, #2                          @ 0800D4B0
    beq .Lap_0800D4C4                   @ 0800D4B2
    ldr r0, =meter_mode                 @ 0800D4B4
    ldrb r0, [r0]                       @ 0800D4B6
    cmp r0, #4                          @ 0800D4B8
    beq .Lap_0800D4C4                   @ 0800D4BA
    movs r0, #0                         @ 0800D4BC
    ldr r1, =filter_1khz                @ 0800D4BE
    strb r0, [r1]                       @ 0800D4C2
@ reached from 0800D4B2 beq (equal / zero) after cmp r0, #2
@              and from 0800D4BA beq (equal / zero) after cmp r0, #4
.Lap_0800D4C4:
    ldr r0, =meter_mode                 @ 0800D4C4
    ldrb r0, [r0]                       @ 0800D4C6
    cmp r0, #2                          @ 0800D4C8
    beq .Lap_0800D4D4                   @ 0800D4CA
    movs r0, #0                         @ 0800D4CC
    ldr r1, =acdc_active                @ 0800D4CE
    strb r0, [r1]                       @ 0800D4D2
@ reached from 0800D4CA beq (equal / zero) after cmp r0, #2
.Lap_0800D4D4:
    movs r0, #0                         @ 0800D4D4
    ldr r1, =rel_active                 @ 0800D4D6
    strb r0, [r1]                       @ 0800D4DA
    movs r0, #0                         @ 0800D4DC
    ldr r1, =minmax_state               @ 0800D4DE
    strb r0, [r1]                       @ 0800D4E2
    ldr r0, =meter_mode                 @ 0800D4E4
    ldrb r0, [r0]                       @ 0800D4E6
    cmp r0, #2                          @ 0800D4E8
    bne .Lap_0800D4F6                   @ 0800D4EA
    ldr r0, =acdc_active                @ 0800D4EC
    ldrb r0, [r0]                       @ 0800D4F0
    cmp r0, #0                          @ 0800D4F2
    beq .Lap_0800D506                   @ 0800D4F4
@ reached from 0800D4EA bne (not equal / non-zero) after cmp r0, #2
.Lap_0800D4F6:
    ldr r0, =meter_mode                 @ 0800D4F6
    ldrb r0, [r0]                       @ 0800D4F8
    cmp r0, #4                          @ 0800D4FA
    beq .Lap_0800D506                   @ 0800D4FC
    movs r0, #0                         @ 0800D4FE
    ldr r1, =peak_hold                  @ 0800D500
    strb r0, [r1]                       @ 0800D504

@ PEAK values cleared; display refresh requests 0x20008063, 0x20008060, 0x20008062 set; HOLD helper 0x2000804C
@ cleared; 0x2000805F set when HOLD is off
@ reached from 0800D4F4 beq (equal / zero) after cmp r0, #0
@              and from 0800D4FC beq (equal / zero) after cmp r0, #4
.Lap_0800D506:
    movs r0, #0                         @ 0800D506
    ldr r1, =v_20007E8C                 @ 0800D508
    str r0, [r1]                        @ 0800D50C
    movs r0, #0                         @ 0800D50E
    ldr r1, =v_20007E90                 @ 0800D510
    str r0, [r1]                        @ 0800D514
    movs r0, #1                         @ 0800D516
    ldr r1, =v_20008063                 @ 0800D518
    strb r0, [r1]                       @ 0800D51C
    ldr r1, =v_20008060                 @ 0800D51E
    strb r0, [r1]                       @ 0800D522
    ldr r1, =v_20008062                 @ 0800D524
    strb r0, [r1]                       @ 0800D528
    movs r0, #0                         @ 0800D52A
    ldr r1, =v_2000804C                 @ 0800D52C
    strb r0, [r1]                       @ 0800D530
    ldr r0, =hold_active                @ 0800D532
    ldrb r0, [r0]                       @ 0800D536
    ldr r1, =hold_stage2                @ 0800D538
    ldrb r1, [r1]                       @ 0800D53C
    orrs r0, r1                         @ 0800D53E
    uxtb r0, r0                         @ 0800D540
    cmp r0, #0                          @ 0800D542
    bne .Lap_0800D54E                   @ 0800D544
    movs r0, #1                         @ 0800D546
    ldr r1, =v_2000805F                 @ 0800D548
    strb r0, [r1]                       @ 0800D54C
@ reached from 0800D544 bne (not equal / non-zero) after cmp r0, #0
.Lap_0800D54E:
    bl fn_0800DB48                      @ 0800D54E settle count of the new mode and range (this also clears the overload latch through ar_apply: OF-20)

@ setup item text of the mode (fn_080171FA), full scale of the range, HY3131 row + calibration record + user zero
@ (fn_0800D80C(1)), then the old values are cleared (not for OHM range 6, whose reading stays)
    bl cal_capture_cancel                      @ OF-36: a pending calibration capture is cancelled by an apply
    bl fn_080171FA                      @ 0800D552
    bl load_full_scale                  @ 0800D556
    movs r0, #1                         @ 0800D55A
    bl fn_0800D80C                      @ 0800D55C
    ldr r0, =meter_mode                 @ 0800D560
    ldrb r0, [r0]                       @ 0800D562
    cmp r0, #9                          @ 0800D564
    bne .Lap_clear_reading              @ 0800D566
    ldr r0, =meter_range                @ 0800D568
    ldrb r0, [r0]                       @ 0800D56C
    cmp r0, #6                          @ 0800D56E
    bne .Lap_clear_reading              @ 0800D570
    nop                                 @ 0800D572
    b .Lap_va_prepare                   @ 0800D574
    .ltorg
@ reached from 0800D566 bne (not equal / non-zero) after cmp r0, #9
@              and from 0800D570 bne (not equal / non-zero) after cmp r0, #6
.Lap_clear_reading:
    movs r0, #0                         @ 0800D576
    ldr r1, =mode_reading               @ 0800D578
    str r0, [r1]                        @ 0800D57C
    movs r0, #0                         @ 0800D57E
    ldr r1, =mode_reading_smp           @ 0800D580
    str r0, [r1]                        @ 0800D584

@ VA preparation (fn_0800A560), then the front-end pins of the new mode and range (fn_0800FBE8)
@ reached from 0800D574 b (jump)
.Lap_va_prepare:
    bl fn_0800A560                      @ 0800D586
    ldr r0, =meter_range                @ 0800D58A
    ldrb r1, [r0]                       @ 0800D58E
    ldr r0, =meter_mode                 @ 0800D590
    ldrb r0, [r0]                       @ 0800D592
    bl fn_0800FBE8                      @ 0800D594 front-end pins: PD0, PF4, PF5, PC11, PD7, PE15, PF6, PA12, PA11, PH2, PE12, PE5 for (mode, range)

@ after a mode change: reload the auto-power-off counter and give a 300-tick click (pulse on the buzzer if enabled)
    ldr r0, =mode_mode_req              @ 0800D598
    ldrb r0, [r0]                       @ 0800D59C
    cmp r0, #0                          @ 0800D59E
    beq .Lap_0800D5AE                   @ 0800D5A0
    bl fn_0800ED26                      @ 0800D5A2
    mov.w r0, #0x12C                    @ 0800D5A6
    bl fn_0800EEA8                      @ 0800D5AA

@ both requests are served; HOLD stage 2: refresh requests cleared
@ reached from 0800D5A0 beq (equal / zero) after cmp r0, #0
.Lap_0800D5AE:
    movs r0, #0                         @ 0800D5AE
    ldr r1, =mode_mode_req              @ 0800D5B0
    strb r0, [r1]                       @ 0800D5B4
    movs r0, #0                         @ 0800D5B6
    ldr r1, =mode_range_req             @ 0800D5B8
    strb r0, [r1]                       @ 0800D5BC
    ldr r0, =hold_stage2                @ 0800D5BE
    ldrb r0, [r0]                       @ 0800D5C2
    cmp r0, #0                          @ 0800D5C4
    beq .Lap_0800D5E2                   @ 0800D5C6
    movs r0, #0                         @ 0800D5C8
    ldr r1, =v_20008061                 @ 0800D5CA
    strb r0, [r1]                       @ 0800D5CE
    ldr r1, =v_20008060                 @ 0800D5D0
    strb r0, [r1]                       @ 0800D5D4
    ldr r1, =v_2000805E                 @ 0800D5D6
    strb r0, [r1]                       @ 0800D5DA
    ldr r1, =mode_new_result            @ 0800D5DC
    strb r0, [r1]                       @ 0800D5E0
@ reached from 0800D5C6 beq (equal / zero) after cmp r0, #0
.Lap_0800D5E2:
    pop {r4, pc}                        @ 0800D5E2
ENDFUNC meter_apply_mode_range
    .ltorg

@ -----------------------------------------------------------------------------
@ load_full_scale - load the full scale of the present mode and range
@ Replaces : 0x0800D5F4 load_full_scale (v2.05)
@ In       : -
@ Out      : mode_full_scale (0x20007D60) = full scale in display counts
@ Clobbers : r0-r2, flags
@ Context  : main (meter_apply_mode_range)
@ RAM      : writes 0x20007D60; reads meter_mode, meter_range, 0x200080B3 (DIODE 15 V)
@ Spec     : analysis/autorange_and_scheduler.md 2.2 (full scale table 0x08025A3C, 7 words per mode)
@ -----------------------------------------------------------------------------
FUNC load_full_scale

@ DIODE (mode 11): the table entry is range 0 (3 V) or range 1 (15 V) by the 15 V flag, whatever meter_range is
    ldr r0, =meter_mode                 @ 0800D5F4
    ldrb r0, [r0]                       @ 0800D5F8
    cmp r0, #0xB                        @ 0800D5FA
    bne .L800d5f4_0800D63A              @ 0800D5FC
    ldr r0, =mode_diode_15v             @ 0800D5FE
    ldrb r0, [r0]                       @ 0800D602
    cmp r0, #0                          @ 0800D604
    beq .L800d5f4_0800D622              @ 0800D606
    ldr r0, =full_scale_table           @ 0800D608
    ldr r1, =meter_mode                 @ 0800D60C
    ldrb r1, [r1]                       @ 0800D610
    movs r2, #0x1C                      @ 0800D612
    muls r1, r2, r1                     @ 0800D614
    add r0, r1                          @ 0800D616
    ldr r0, [r0, #4]                    @ 0800D618
    ldr r1, =mode_full_scale            @ 0800D61A
    str r0, [r1]                        @ 0800D61E
    b .L800d5f4_0800D65A                @ 0800D620
@ reached from 0800D606 beq (equal / zero) after cmp r0, #0
.L800d5f4_0800D622:
    ldr r0, =full_scale_table           @ 0800D622
    ldr r1, =meter_mode                 @ 0800D626
    ldrb r1, [r1]                       @ 0800D62A
    movs r2, #0x1C                      @ 0800D62C
    muls r1, r2, r1                     @ 0800D62E
    ldr r0, [r0, r1]                    @ 0800D630
    ldr r1, =mode_full_scale            @ 0800D632
    str r0, [r1]                        @ 0800D636
    b .L800d5f4_0800D65A                @ 0800D638

@ every other mode: table[mode * 28 + range * 4]
@ reached from 0800D5FC bne (not equal / non-zero) after cmp r0, #0xB
.L800d5f4_0800D63A:
    ldr r0, =full_scale_table           @ 0800D63A
    ldr r1, =meter_mode                 @ 0800D63E
    ldrb r1, [r1]                       @ 0800D642
    movs r2, #0x1C                      @ 0800D644
    muls r1, r2, r1                     @ 0800D646
    add r0, r1                          @ 0800D648
    ldr r1, =meter_range                @ 0800D64A
    ldrb r1, [r1]                       @ 0800D64E
    ldr.w r0, [r0, r1, lsl #2]          @ 0800D650
    ldr r1, =mode_full_scale            @ 0800D654
    str r0, [r1]                        @ 0800D658
@ reached from 0800D620 b (jump)
@              and from 0800D638 b (jump)
.L800d5f4_0800D65A:
    bx lr                               @ 0800D65A
ENDFUNC load_full_scale
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800D80C - configure the HY3131 and load the calibration for the present mode and range
@ Replaces : 0x0800D80C FUN_0800D80C (v2.05)
@ In       : r0 = 1 full (calibration records and user zero are loaded too)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main (meter_apply_mode_range)
@ Spec     : analysis/autorange_and_scheduler.md 2.3 (apply)
@ -----------------------------------------------------------------------------
FUNC fn_0800D80C

@ fn_0800D81E(arg), then the capacitor-measurement state of MRES (fn_0800EC28)
    push {r4, lr}                       @ 0800D80C
    movs r4, r0                         @ 0800D80E
    movs r0, r4                         @ 0800D810
    uxtb r0, r0                         @ 0800D812
    bl fn_0800D81E                      @ 0800D814
    bl fn_0800EC28                      @ 0800D818
    pop {r4, pc}                        @ 0800D81C
ENDFUNC fn_0800D80C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800D81E - write the HY3131 row and load the calibration records
@ Replaces : 0x0800D81E FUN_0800D81E (v2.05)
@ In       : r0 = 1 full
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main (fn_0800D80C)
@ RAM      : reads meter_mode, meter_range
@ Spec     : analysis/autorange_and_scheduler.md 2.3; firmware/EEPROM_MAP.md 5 (records)
@ -----------------------------------------------------------------------------
FUNC fn_0800D81E

@ always: write the HY3131 configuration row of (mode, range) (fn_0800B974, HY)
    push {r4, lr}                       @ 0800D81E
    movs r4, r0                         @ 0800D820
    ldr r0, =meter_range                @ 0800D822
    ldrb r1, [r0]                       @ 0800D826
    ldr r0, =meter_mode                 @ 0800D828
    ldrb r0, [r0]                       @ 0800D82C
    bl fn_0800B974                      @ 0800D82E

@ full apply: load the calibration record of (mode, range) into RAM (load_cal_record_from_eeprom, CAL) and the
@ user zero of the current modes (current_extra_load, MVA)
    uxtb r4, r4                         @ 0800D832
    cmp r4, #1                          @ 0800D834
    bne .L800d81e_0800D858              @ 0800D836
    ldr r0, =meter_range                @ 0800D838
    ldrb r1, [r0]                       @ 0800D83C
    ldr r0, =meter_mode                 @ 0800D83E
    ldrb r0, [r0]                       @ 0800D842
    bl load_cal_record_from_eeprom      @ 0800D844
    ldr r0, =meter_range                @ 0800D848
    ldrb r1, [r0]                       @ 0800D84C
    ldr r0, =meter_mode                 @ 0800D84E
    ldrb r0, [r0]                       @ 0800D852
    bl current_extra_load               @ 0800D854

@ full apply outside FREQ: the FREQ record (mode 6 range 0) is loaded too, because the counter reference
@ frequency (0x20007E18) comes from it
@ reached from 0800D836 bne (not equal / non-zero) after cmp r4, #1
.L800d81e_0800D858:
    uxtb r4, r4                         @ 0800D858
    cmp r4, #1                          @ 0800D85A
    bne .L800d81e_0800D870              @ 0800D85C
    ldr r0, =meter_mode                 @ 0800D85E
    ldrb r0, [r0]                       @ 0800D862
    cmp r0, #6                          @ 0800D864
    beq .L800d81e_0800D870              @ 0800D866
    movs r1, #0                         @ 0800D868
    movs r0, #6                         @ 0800D86A
    bl load_cal_record_from_eeprom      @ 0800D86C

@ full apply in ACuA, ACmA, ACA, ACV, ACmV: the AC band words (fn_08011AA4); in LowZ the same
@ reached from 0800D85C bne (not equal / non-zero) after cmp r4, #1
@              and from 0800D866 beq (equal / zero) after cmp r0, #6
.L800d81e_0800D870:
    uxtb r4, r4                         @ 0800D870
    cmp r4, #1                          @ 0800D872
    bne .L800d81e_0800D8AC              @ 0800D874
    ldr r0, =meter_mode                 @ 0800D876
    ldrb r0, [r0]                       @ 0800D87A
    cmp r0, #0x10                       @ 0800D87C
    beq .L800d81e_0800D8A8              @ 0800D87E
    ldr r0, =meter_mode                 @ 0800D880
    ldrb r0, [r0]                       @ 0800D884
    cmp r0, #0x12                       @ 0800D886
    beq .L800d81e_0800D8A8              @ 0800D888
    ldr r0, =meter_mode                 @ 0800D88A
    ldrb r0, [r0]                       @ 0800D88E
    cmp r0, #0x14                       @ 0800D890
    beq .L800d81e_0800D8A8              @ 0800D892
    ldr r0, =meter_mode                 @ 0800D894
    ldrb r0, [r0]                       @ 0800D898
    cmp r0, #2                          @ 0800D89A
    beq .L800d81e_0800D8A8              @ 0800D89C
    ldr r0, =meter_mode                 @ 0800D89E
    ldrb r0, [r0]                       @ 0800D8A2
    cmp r0, #4                          @ 0800D8A4
    bne .L800d81e_0800D8AC              @ 0800D8A6
@ reached from 0800D87E beq (equal / zero) after cmp r0, #0x10
@              and from 0800D888 beq (equal / zero) after cmp r0, #0x12
@              and from 0800D892 beq (equal / zero) after cmp r0, #0x14
@              and from 0800D89C beq (equal / zero) after cmp r0, #2
.L800d81e_0800D8A8:
    bl fn_08011AA4                      @ 0800D8A8
@ reached from 0800D874 bne (not equal / non-zero) after cmp r4, #1
@              and from 0800D8A6 bne (not equal / non-zero) after cmp r0, #4
.L800d81e_0800D8AC:
    uxtb r4, r4                         @ 0800D8AC
    cmp r4, #1                          @ 0800D8AE
    bne .L800d81e_0800D8C0              @ 0800D8B0
    ldr r0, =meter_mode                 @ 0800D8B2
    ldrb r0, [r0]                       @ 0800D8B6
    cmp r0, #0                          @ 0800D8B8
    bne .L800d81e_0800D8C0              @ 0800D8BA
    bl fn_08011AA4                      @ 0800D8BC
@ reached from 0800D8B0 bne (not equal / non-zero) after cmp r4, #1
@              and from 0800D8BA bne (not equal / non-zero) after cmp r0, #0
.L800d81e_0800D8C0:
    pop {r4, pc}                        @ 0800D8C0
ENDFUNC fn_0800D81E
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800DB48 - set the settle count for the present mode and range
@ Replaces : 0x0800DB48 FUN_0800DB48 (v2.05)
@ In       : -
@ Out      : mode_settle (0x20000238) = results to pass before ranging resumes; while it is non-zero the main digits are
@            blank (ARS 2.2, 2.3)
@ Clobbers : r0-r3, r12, flags (tail call of ar_apply)
@ Context  : main (meter_apply_mode_range, fn_08006774, fn_080080C8 and MVA)
@ RAM      : writes 0x20000238; reads meter_mode, meter_range, 0x200080A5 (burden option), va_channel,
@            0x20008098 (LowZ AC), acdc_active, peak_hold
@ Spec     : analysis/autorange_and_scheduler.md 2.3 (table of settle counts)
@ Deviation: OF-20 and IMP-01: every apply ends in ar_apply(mode, range), which clears the overload latch 0x200080F8
@            and, in the production image, adjusts the settle count of the profile
@ -----------------------------------------------------------------------------
FUNC fn_0800DB48

@ current modes (0x10..0x15) with the burden option: 3, or 0 while the VA channel is the voltage channel
    ldr r0, =meter_mode                 @ 0800DB48
    ldrb r0, [r0]                       @ 0800DB4A
    cmp r0, #0x10                       @ 0800DB4C
    beq .L800db48_0800DB78              @ 0800DB4E
    ldr r0, =meter_mode                 @ 0800DB50
    ldrb r0, [r0]                       @ 0800DB52
    cmp r0, #0x12                       @ 0800DB54
    beq .L800db48_0800DB78              @ 0800DB56
    ldr r0, =meter_mode                 @ 0800DB58
    ldrb r0, [r0]                       @ 0800DB5A
    cmp r0, #0x14                       @ 0800DB5C
    beq .L800db48_0800DB78              @ 0800DB5E
    ldr r0, =meter_mode                 @ 0800DB60
    ldrb r0, [r0]                       @ 0800DB62
    cmp r0, #0x11                       @ 0800DB64
    beq .L800db48_0800DB78              @ 0800DB66
    ldr r0, =meter_mode                 @ 0800DB68
    ldrb r0, [r0]                       @ 0800DB6A
    cmp r0, #0x13                       @ 0800DB6C
    beq .L800db48_0800DB78              @ 0800DB6E
    ldr r0, =meter_mode                 @ 0800DB70
    ldrb r0, [r0]                       @ 0800DB72
    cmp r0, #0x15                       @ 0800DB74
    bne .L800db48_0800DB9E              @ 0800DB76
@ reached from 0800DB4E beq (equal / zero) after cmp r0, #0x10
@              and from 0800DB56 beq (equal / zero) after cmp r0, #0x12
@              and from 0800DB5E beq (equal / zero) after cmp r0, #0x14
@              ... and 2 more
.L800db48_0800DB78:
    ldr r0, =v_200080A5                 @ 0800DB78
    ldrb r0, [r0]                       @ 0800DB7C
    cmp r0, #0                          @ 0800DB7E
    beq .L800db48_0800DB9E              @ 0800DB80
    ldr r0, =va_channel                 @ 0800DB82
    ldrb r0, [r0]                       @ 0800DB84
    cmp r0, #0                          @ 0800DB86
    bne .L800db48_0800DB94              @ 0800DB88
    movs r0, #3                         @ 0800DB8A
    ldr r1, =mode_settle                @ 0800DB8C
    strb r0, [r1]                       @ 0800DB90
    b .L800db48_after                   @ 0800DB92
@ reached from 0800DB88 bne (not equal / non-zero) after cmp r0, #0
.L800db48_0800DB94:
    movs r0, #0                         @ 0800DB94
    ldr r1, =mode_settle                @ 0800DB96
    strb r0, [r1]                       @ 0800DB9A
    b .L800db48_after                   @ 0800DB9C

@ ACV 3, ACmV 4, FREQ / PULSE / DUTY 0, OHM 1 (ranges 0..4) or 2 (range 5 and 6), BEEP 0, DCV 2, DCmV 1,
@ LowZ 5 (DC state), CAP 1 (ranges 0..5), everything else 3
@ reached from 0800DB76 bne (not equal / non-zero) after cmp r0, #0x15
@              and from 0800DB80 beq (equal / zero) after cmp r0, #0
.L800db48_0800DB9E:
    ldr r0, =meter_mode                 @ 0800DB9E
    ldrb r0, [r0]                       @ 0800DBA0
    cmp r0, #2                          @ 0800DBA2
    bne .L800db48_0800DBB0              @ 0800DBA4
    movs r0, #3                         @ 0800DBA6
    ldr r1, =mode_settle                @ 0800DBA8
    strb r0, [r1]                       @ 0800DBAC
    b .L800db48_after                   @ 0800DBAE
@ reached from 0800DBA4 bne (not equal / non-zero) after cmp r0, #2
.L800db48_0800DBB0:
    ldr r0, =meter_mode                 @ 0800DBB0
    ldrb r0, [r0]                       @ 0800DBB2
    cmp r0, #4                          @ 0800DBB4
    bne .L800db48_0800DBC2              @ 0800DBB6
    movs r0, #4                         @ 0800DBB8
    ldr r1, =mode_settle                @ 0800DBBA
    strb r0, [r1]                       @ 0800DBBE
    b .L800db48_after                   @ 0800DBC0
@ reached from 0800DBB6 bne (not equal / non-zero) after cmp r0, #4
.L800db48_0800DBC2:
    ldr r0, =meter_mode                 @ 0800DBC2
    ldrb r0, [r0]                       @ 0800DBC4
    cmp r0, #6                          @ 0800DBC6
    beq .L800db48_0800DBDA              @ 0800DBC8
    ldr r0, =meter_mode                 @ 0800DBCA
    ldrb r0, [r0]                       @ 0800DBCC
    cmp r0, #7                          @ 0800DBCE
    beq .L800db48_0800DBDA              @ 0800DBD0
    ldr r0, =meter_mode                 @ 0800DBD2
    ldrb r0, [r0]                       @ 0800DBD4
    cmp r0, #8                          @ 0800DBD6
    bne .L800db48_0800DBE4              @ 0800DBD8
@ reached from 0800DBC8 beq (equal / zero) after cmp r0, #6
@              and from 0800DBD0 beq (equal / zero) after cmp r0, #7
.L800db48_0800DBDA:
    movs r0, #0                         @ 0800DBDA
    ldr r1, =mode_settle                @ 0800DBDC
    strb r0, [r1]                       @ 0800DBE0
    b .L800db48_after                   @ 0800DBE2
@ reached from 0800DBD8 bne (not equal / non-zero) after cmp r0, #8
.L800db48_0800DBE4:
    ldr r0, =meter_mode                 @ 0800DBE4
    ldrb r0, [r0]                       @ 0800DBE6
    cmp r0, #9                          @ 0800DBE8
    bne .L800db48_0800DC1A              @ 0800DBEA
    ldr r0, =meter_range                @ 0800DBEC
    ldrb r0, [r0]                       @ 0800DBEE
    cmp r0, #6                          @ 0800DBF0
    blt .L800db48_0800DBFE              @ 0800DBF2
    movs r0, #2                         @ 0800DBF4
    ldr r1, =mode_settle                @ 0800DBF6
    strb r0, [r1]                       @ 0800DBFA
    b .L800db48_after                   @ 0800DBFC
@ reached from 0800DBF2 blt (signed <) after cmp r0, #6
.L800db48_0800DBFE:
    ldr r0, =meter_range                @ 0800DBFE
    ldrb r0, [r0]                       @ 0800DC00
    cmp r0, #5                          @ 0800DC02
    bne .L800db48_0800DC10              @ 0800DC04
    movs r0, #2                         @ 0800DC06
    ldr r1, =mode_settle                @ 0800DC08
    strb r0, [r1]                       @ 0800DC0C
    b .L800db48_after                   @ 0800DC0E
@ reached from 0800DC04 bne (not equal / non-zero) after cmp r0, #5
.L800db48_0800DC10:
    movs r0, #1                         @ 0800DC10
    ldr r1, =mode_settle                @ 0800DC12
    strb r0, [r1]                       @ 0800DC16
    b .L800db48_after                   @ 0800DC18
@ reached from 0800DBEA bne (not equal / non-zero) after cmp r0, #9
.L800db48_0800DC1A:
    ldr r0, =meter_mode                 @ 0800DC1A
    ldrb r0, [r0]                       @ 0800DC1C
    cmp r0, #0xA                        @ 0800DC1E
    bne .L800db48_0800DC2C              @ 0800DC20
    movs r0, #0                         @ 0800DC22
    ldr r1, =mode_settle                @ 0800DC24
    strb r0, [r1]                       @ 0800DC28
    b .L800db48_after                   @ 0800DC2A
@ reached from 0800DC20 bne (not equal / non-zero) after cmp r0, #0xA
.L800db48_0800DC2C:
    ldr r0, =meter_mode                 @ 0800DC2C
    ldrb r0, [r0]                       @ 0800DC2E
    cmp r0, #1                          @ 0800DC30
    bne .L800db48_0800DC3E              @ 0800DC32
    movs r0, #2                         @ 0800DC34
    ldr r1, =mode_settle                @ 0800DC36
    strb r0, [r1]                       @ 0800DC3A
    b .L800db48_after                   @ 0800DC3C
@ reached from 0800DC32 bne (not equal / non-zero) after cmp r0, #1
.L800db48_0800DC3E:
    ldr r0, =meter_mode                 @ 0800DC3E
    ldrb r0, [r0]                       @ 0800DC40
    cmp r0, #3                          @ 0800DC42
    bne .L800db48_0800DC50              @ 0800DC44
    movs r0, #1                         @ 0800DC46
    ldr r1, =mode_settle                @ 0800DC48
    strb r0, [r1]                       @ 0800DC4C
    b .L800db48_after                   @ 0800DC4E
@ reached from 0800DC44 bne (not equal / non-zero) after cmp r0, #3
.L800db48_0800DC50:
    ldr r0, =meter_mode                 @ 0800DC50
    ldrb r0, [r0]                       @ 0800DC52
    cmp r0, #0                          @ 0800DC54
    bne .L800db48_0800DC6C              @ 0800DC56
    ldr r0, =v_20008098                 @ 0800DC58
    ldrb r0, [r0]                       @ 0800DC5C
    cmp r0, #0                          @ 0800DC5E
    bne .L800db48_0800DC6C              @ 0800DC60
    movs r0, #5                         @ 0800DC62
    ldr r1, =mode_settle                @ 0800DC64
    strb r0, [r1]                       @ 0800DC68
    b .L800db48_after                   @ 0800DC6A
@ reached from 0800DC56 bne (not equal / non-zero) after cmp r0, #0
@              and from 0800DC60 bne (not equal / non-zero) after cmp r0, #0
.L800db48_0800DC6C:
    ldr r0, =meter_mode                 @ 0800DC6C
    ldrb r0, [r0]                       @ 0800DC6E
    cmp r0, #0xC                        @ 0800DC70
    bne .L800db48_cap_check             @ 0800DC72
    ldr r0, =meter_range                @ 0800DC74
    ldrb r0, [r0]                       @ 0800DC76
    cmp r0, #2                          @ 0800DC78
    bge .L800db48_cap_check             @ 0800DC7A
    movs r0, #1                         @ 0800DC7C
    ldr r1, =mode_settle                @ 0800DC7E
    strb r0, [r1]                       @ 0800DC82
    b .L800db48_after                   @ 0800DC84
@ reached from 0800DC72 bne (not equal / non-zero) after cmp r0, #0xC
@              and from 0800DC7A bge (signed >=) after cmp r0, #2
.L800db48_cap_check:
    ldr r0, =meter_mode                 @ 0800DC86
    ldrb r0, [r0]                       @ 0800DC88
    cmp r0, #0xC                        @ 0800DC8A
    bne .L800db48_0800DCA8              @ 0800DC8C
    ldr r0, =meter_range                @ 0800DC8E
    ldrb r0, [r0]                       @ 0800DC90
    cmp r0, #2                          @ 0800DC92
    blt .L800db48_0800DCA8              @ 0800DC94
    ldr r0, =meter_range                @ 0800DC96
    ldrb r0, [r0]                       @ 0800DC98
    cmp r0, #5                          @ 0800DC9A
    bge .L800db48_0800DCA8              @ 0800DC9C
    movs r0, #1                         @ 0800DC9E
    ldr r1, =mode_settle                @ 0800DCA0
    strb r0, [r1]                       @ 0800DCA4
    b .L800db48_after                   @ 0800DCA6
@ reached from 0800DC8C bne (not equal / non-zero) after cmp r0, #0xC
@              and from 0800DC94 blt (signed <) after cmp r0, #2
@              and from 0800DC9C bge (signed >=) after cmp r0, #5
.L800db48_0800DCA8:
    ldr r0, =meter_mode                 @ 0800DCA8
    ldrb r0, [r0]                       @ 0800DCAA
    cmp r0, #0xC                        @ 0800DCAC
    bne .L800db48_default3              @ 0800DCAE
    ldr r0, =meter_range                @ 0800DCB0
    ldrb r0, [r0]                       @ 0800DCB2
    cmp r0, #5                          @ 0800DCB4
    bne .L800db48_default3              @ 0800DCB6
    movs r0, #1                         @ 0800DCB8
    ldr r1, =mode_settle                @ 0800DCBA
    strb r0, [r1]                       @ 0800DCBE
    b .L800db48_after                   @ 0800DCC0

@ any other mode (DIODE, TEMP, VA modes, LowZ in AC state, currents without the burden option): 3
@ reached from 0800DCAE bne (not equal / non-zero) after cmp r0, #0xC
@              and from 0800DCB6 bne (not equal / non-zero) after cmp r0, #5
.L800db48_default3:
    movs r0, #3                         @ 0800DCC2
    ldr r1, =mode_settle                @ 0800DCC4
    strb r0, [r1]                       @ 0800DCC8

@ ACV with AC+DC: 1.  ACV with PEAK: 5
@ reached from 0800DB92 b (jump)
@              and from 0800DB9C b (jump)
@              and from 0800DBAE b (jump)
@              ... and 12 more
.L800db48_after:
    ldr r0, =meter_mode                 @ 0800DCCA
    ldrb r0, [r0]                       @ 0800DCCC
    cmp r0, #2                          @ 0800DCCE
    bne .L800db48_0800DCE2              @ 0800DCD0
    ldr r0, =acdc_active                @ 0800DCD2
    ldrb r0, [r0]                       @ 0800DCD4
    cmp r0, #0                          @ 0800DCD6
    beq .L800db48_0800DCE2              @ 0800DCD8
    movs r0, #1                         @ 0800DCDA
    ldr r1, =mode_settle                @ 0800DCDC
    strb r0, [r1]                       @ 0800DCE0
@ reached from 0800DCD0 bne (not equal / non-zero) after cmp r0, #2
@              and from 0800DCD8 beq (equal / zero) after cmp r0, #0
.L800db48_0800DCE2:
    ldr r0, =meter_mode                 @ 0800DCE2
    ldrb r0, [r0]                       @ 0800DCE4
    cmp r0, #2                          @ 0800DCE6
    bne .L800db48_0800DCFA              @ 0800DCE8
    ldr r0, =peak_hold                  @ 0800DCEA
    ldrb r0, [r0]                       @ 0800DCEC
    cmp r0, #0                          @ 0800DCEE
    beq .L800db48_0800DCFA              @ 0800DCF0
    movs r0, #5                         @ 0800DCF2
    ldr r1, =mode_settle                @ 0800DCF4
    strb r0, [r1]                       @ 0800DCF8
@ reached from 0800DCE8 bne (not equal / non-zero) after cmp r0, #2
@              and from 0800DCF0 beq (equal / zero) after cmp r0, #0
.L800db48_0800DCFA:
    ldr r0, =meter_mode                     @ 0800DCFA replaces v2.05 bx lr
    ldrb r0, [r0]                              @ r0 = mode
    ldr r1, =meter_range
    ldrb r1, [r1]                              @ r1 = range
    b ar_apply                                  @ tail call: AR resets its state and clears the overload latch
ENDFUNC fn_0800DB48
    .ltorg

@ -----------------------------------------------------------------------------
@ decimal_position_for_mode_range - digits after the decimal point for a mode and range
@ Replaces : 0x0800D920 decimal_position_for_mode_range (v2.05 compare ladder, 233 instructions)
@ In       : r0 = mode (any byte), r1 = range (any byte)
@ Out      : r0 = 0..4 digits after the decimal point of the main display
@ Clobbers : r1, r2, flags
@ Context  : main (UI, LOG, MFRQ, MRES and frequency_select_range)
@ RAM      : reads 0x200080B3 (DIODE 15 V) for mode 11
@ Spec     : analysis/lcd_map.md 4.1 (decimal point from decimal_position_for_mode_range)
@ Deviation: OPT-06 (a table replaces the compare ladder).  The table rows were produced by running the v2.05 routine
@            for every range 0..255 of every mode 0..25 and checked against it for all 256 x 256 x 2 inputs
@            (mode, range and the DIODE flag): modes 11 (DIODE: 4 digits, 3 with the 15 V flag) and 26..255 (0 digits)
@            are decided in code, every other mode by its row; a range of 7 or more takes the last byte of the row.
@ -----------------------------------------------------------------------------
FUNC decimal_position_for_mode_range
    uxtb r2, r0                             @ r2 = mode
    uxtb r1, r1                             @ r1 = range
    cmp r2, #26
    bhs .Ldp_zero                           @ modes above 25: v2.05 returns 0 (0x0800D98E -> 0x0800DB00 with r3 = 0)
    cmp r2, #11
    beq .Ldp_diode                          @ DIODE depends on the 15 V flag, not on the range (0x0800DA1A)
    ldr r0, =dec_table
    add r0, r0, r2, lsl #3                  @ r0 = row of this mode (8 bytes)
    cmp r1, #7
    bhs .Ldp_tail                           @ range 7 and above: the row's last byte
    ldrb r0, [r0, r1]                       @ digits of this range
    bx lr
@ range 7 and above: the last byte of the row
.Ldp_tail:
    ldrb r0, [r0, #7]
    bx lr
@ mode 11 (DIODE): 4 digits on the 3 V range, 3 digits on the 15 V range
.Ldp_diode:
    ldr r1, =mode_diode_15v
    ldrb r1, [r1]
    movs r0, #4                             @ 3 V range: 4 digits
    cbz r1, .Ldp_out
    movs r0, #3                             @ 15 V range: 3 digits
@ result in r0
.Ldp_out:
    bx lr
@ mode above 25: no digits after the point
.Ldp_zero:
    movs r0, #0
    bx lr
ENDFUNC decimal_position_for_mode_range
    .ltorg

@ Digits after the decimal point: one row of 8 bytes per mode 0..25; bytes 0..6 are ranges 0..6, byte 7 is used for
@ every range above 6.  Mode 11 (DIODE) is not read from here.
    .section .rodata.mode.decpos, "a", %progbits
    .balign 4
dec_table:
    .byte 1, 1, 1, 1, 1, 1, 1, 1                  @ mode  0 LowZ
    .byte 4, 3, 2, 1, 2, 0, 0, 0                  @ mode  1 DCV
    .byte 4, 3, 2, 1, 2, 0, 0, 0                  @ mode  2 ACV
    .byte 3, 2, 4, 3, 2, 4, 3, 0                  @ mode  3 DCmV
    .byte 3, 2, 4, 3, 2, 4, 3, 0                  @ mode  4 ACmV
    .byte 1, 1, 1, 1, 1, 1, 1, 1                  @ mode  5 TEMP
    .byte 3, 2, 4, 3, 2, 4, 3, 0                  @ mode  6 FREQ
    .byte 4, 3, 2, 1, 2, 0, 0, 0                  @ mode  7 PULSE
    .byte 1, 1, 1, 1, 1, 1, 1, 1                  @ mode  8 DUTY
    .byte 3, 2, 4, 3, 2, 4, 3, 0                  @ mode  9 OHM
    .byte 2, 2, 2, 2, 2, 2, 2, 2                  @ mode 10 BEEP
    .byte 4, 4, 4, 4, 4, 4, 4, 4                  @ mode 11 DIODE
    .byte 3, 2, 4, 3, 2, 0, 0, 0                  @ mode 12 CAP
    .byte 2, 1, 1, 0, 0, 0, 0, 0                  @ mode 13 uVA
    .byte 3, 2, 2, 1, 0, 0, 0, 0                  @ mode 14 mVA
    .byte 1, 0, 3, 2, 0, 0, 0, 0                  @ mode 15 VA
    .byte 3, 2, 4, 3, 2, 4, 3, 0                  @ mode 16 ACuA
    .byte 3, 2, 4, 3, 2, 4, 3, 0                  @ mode 17 DCuA
    .byte 4, 3, 2, 1, 2, 0, 0, 0                  @ mode 18 ACmA
    .byte 4, 3, 2, 1, 2, 0, 0, 0                  @ mode 19 DCmA
    .byte 2, 4, 3, 0, 0, 0, 0, 0                  @ mode 20 ACA
    .byte 2, 4, 3, 0, 0, 0, 0, 0                  @ mode 21 DCA
    .byte 2, 1, 1, 0, 0, 0, 0, 0                  @ mode 22 DCuVA
    .byte 3, 2, 2, 1, 0, 0, 0, 0                  @ mode 23 DCmVA
    .byte 1, 0, 3, 2, 0, 0, 0, 0                  @ mode 24 DCVA
    .byte 1, 1, 1, 1, 1, 1, 1, 1                  @ mode 25 25
