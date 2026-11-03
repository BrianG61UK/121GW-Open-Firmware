@ =============================================================================
@ ad1.s - MDC: AD1 decode, averaging and the mean/per-sample calibration chains
@
@ Replaces v2.05 FUN_080062F8 0x080062F8, ad1_accumulate_average 0x08006342, FUN_08006418 0x08006418 and FUN_080064D6 0x080064D6.
@
@ Data flow of one AD1 conversion (analysis/hy3131_model.md 4.1, 5.2; hy3131_modes_misc.md 2):
@   ad1_ready_dispatch (HY) -> fn_080062F8 decodes registers 0x00..0x02 into a signed value (0x20007DCC, latest sample 0x20007D74)
@   -> ad1_accumulate_average adds it to the running sum 0x20007DD0 and, when N samples are in, stores the mean 0x20007DD4 and
@   returns 1 (0x20008081) -> the mode handler calls fn_08006418 (mean -> displayed value 0x20007D64) and fn_080064D6
@   (single sample -> 0x20007D68).
@
@ Port RAM of this module: see dc.s (mdc_acdc_dc_state).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ MDC_NFIRST, 4                      @ samples in the first displayed mean after a change (ARS 5.2 P5, N_first = 4)
    .equ MDC_FIRST_MASK, (1<<1)|(1<<2)|(1<<3)|(1<<4)|(1<<9)|(1<<10)|(0x3F<<16)   @ modes 1, 2, 3, 4, 9, 10 and the currents 16..21

    .section .text.mdc.ad1, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_080062F8 - decode the three AD1 data bytes into a signed 24-bit value
@ Replaces : 0x080062F8 FUN_080062F8 (v2.05)
@ In       : - (reads the register mirror adc_regs[0..2])
@ Out      : r0 = signed sample, -8388608 .. 8388607
@ Clobbers : r0-r3, flags
@ Context  : main only
@ RAM      : reads  0x200077D0 adc_regs
@            writes 0x20007DC8
@ Spec     : analysis/hy3131_model.md 2 (AD1_DATA), 4.1; ORIGINAL_FIRMWARE_ISSUES.md OF-14
@ Deviation: OF-14
@ raw24 = byte0 + 256 * byte1 + 65536 * byte2 (little-endian, DS p18).  v2.05 kept codes up to 0x800000 as positive and returned
@ code - 0xFFFFFF above it (0x0800631E..0x08006334), i.e. one LSB too high for every negative code and +8388608 for 0x800000.
@ The port sign-extends bit 23 (SBFX #0, #24): code - 0x1000000 for codes >= 0x800000.
@ -----------------------------------------------------------------------------
FUNC fn_080062F8
    ldr r2, =adc_regs                  @ 0x080062F8 pool 0x08006AD4 = 0x200077D0  r2 = AD1 byte 2 (bits 23:16)
    ldrb r2, [r2, #2]                  @ 0x080062FC
    ldr r3, =adc_regs                  @ 0x080062FE pool 0x08006AD4 = 0x200077D0
    ldrb r3, [r3, #1]                  @ 0x08006302
    lsls r3, r3, #8                    @ 0x08006304
    adds.w r2, r3, r2, lsl #16         @ 0x08006306  r2 = byte1 * 256 + byte2 * 65536
    ldr r3, =adc_regs                  @ 0x0800630A pool 0x08006AD4 = 0x200077D0
    ldrb r3, [r3, #0]                  @ 0x0800630E
    adds r2, r3, r2                    @ 0x08006310  r2 = raw24 (byte 0 added)
    ldr r3, =v_20007DC8                @ 0x08006312 pool 0x08006D14 = 0x20007DC8
    str r2, [r3, #0]                   @ 0x08006316  0x20007DC8 = raw24 (read by ar_sample users)
    sbfx r0, r2, #0, #24                    @ OF-14: sign-extend bit 23 (v2.05 0x08006318..0x08006336: raw > 0x800000 -> raw - 0xFFFFFF)
    bx lr
    .ltorg
ENDFUNC fn_080062F8

@ -----------------------------------------------------------------------------
@ ad1_accumulate_average - add one sample to the running sum and publish the mean when N samples are in
@ Replaces : 0x08006342 ad1_accumulate_average (v2.05)
@ In       : r0 = decoded sample (fn_080062F8)
@ Out      : r0 = 1 a mean was completed (0x20007DD4), 0 otherwise
@ Clobbers : r0-r3, r12, flags (r4 preserved)
@ Context  : main only
@ RAM      : reads  mdc_ohm_samples, 0x2000803C meter_mode, 0x2000803D meter_range, 0x20007DD0, 0x20008080, production: mdc_first_mean,
@            0x20000238, 0x200080BA, 0x2000808A, 0x200080A5
@            writes 0x20007DD0, 0x20007DD4, 0x20008080, production: mdc_first_mean
@ Spec     : analysis/hy3131_model.md 4.1 (N), hy3131_modes_misc.md 2; analysis/autorange_and_scheduler.md 5.2 P5, 7, 8.2
@ Deviation: IMP-03 (OHM block size, production only), IMP-04 (BEEP block of 64, production only), IMP-01 (first mean, production only),
@            IMP-23 (DCV outside calibration mode: mdc_dcv_accumulate, production only)
@ N = 16 for every mode except OHM (mode 9): v2.05 8 samples (range 5: 1 sample).  Sum and mean are signed 32-bit; the mean is
@ sum / count with SDIV (truncation toward zero).  Production: N for OHM ranges 0..6 = 8, 8, 32, 16, 16, 1, 8 (mdc_ohm_samples).
@ The block time is then 100 ms (r0, r1), 100 ms (r2, r3, r4) and 200 ms / 200 ms (r5, r6) at the row rates of hy3131_model.md 3.
@ Production, BEEP (mode 10): N = 64 (100 ms at the 640 sps row, ARS 8.2); v2.05 N = 16.
@ Production, IMP-01 P5: when fn_0800B974 has armed mdc_first_mean and the count reaches MDC_NFIRST = 4 in an eligible mode with the v2.05 settle count at 0,
@ the mean of those 4 samples is published (r0 = 1) without ending the block; see .Lac_early.
@ -----------------------------------------------------------------------------
FUNC ad1_accumulate_average
.if LOOP_V205 == 0
    @ IMP-23: DCV outside calibration mode: a 16-sample window published every 8 samples, restarted on a step (dcvavg.s)
    ldr r3, =meter_mode
    ldrb r3, [r3]
    cmp r3, #1
    bne 1f
    ldr r3, =v_2000808A
    ldrb r3, [r3]                           @ calibration mode: v2.05 blocks of 16
    cmp r3, #0
    bne 1f
    b mdc_dcv_accumulate                    @ tail call, same interface (r0 = sample in, r0 = 1 mean published)
1:
.endif
    push {r4}                          @ 0x08006342
    movs r1, r0                        @ 0x08006344  r1 = sample
    movs r0, #0                        @ 0x08006346
    movs r2, #16                       @ 0x08006348  r2 = N, default 16
    ldr r3, =meter_mode                @ 0x0800634A pool 0x08006AD0 = 0x2000803C
    ldrb r3, [r3, #0]                  @ 0x0800634E
    cmp r3, #17                        @ 0x08006350
    beq .L0800637C                     @ 0x08006352
    ldr r3, =meter_mode                @ 0x08006354 pool 0x08006AD0 = 0x2000803C
    ldrb r3, [r3, #0]                  @ 0x08006358
    cmp r3, #19                        @ 0x0800635A
    beq .L0800637C                     @ 0x0800635C
    ldr r3, =meter_mode                @ 0x0800635E pool 0x08006AD0 = 0x2000803C
    ldrb r3, [r3, #0]                  @ 0x08006362
    cmp r3, #21                        @ 0x08006364
    beq .L0800637C                     @ 0x08006366
    ldr r3, =meter_mode                @ 0x08006368 pool 0x08006AD0 = 0x2000803C
    ldrb r3, [r3, #0]                  @ 0x0800636C
    cmp r3, #1                         @ 0x0800636E
    beq .L0800637C                     @ 0x08006370
    ldr r3, =meter_mode                @ 0x08006372 pool 0x08006AD0 = 0x2000803C
    ldrb r3, [r3, #0]                  @ 0x08006376
    cmp r3, #3                         @ 0x08006378
    bne .L08006382                     @ 0x0800637A
.L0800637C:                              @ reached from 0x08006352 beq, 0x0800635C beq, 0x08006366 beq, 0x08006370 beq
    @ ---- modes 1, 3, 17, 19, 21 (and the default): N = 16 ----
    movs r3, #16                       @ 0x0800637C
    movs r2, r3                        @ 0x0800637E
    b .L080063B0                       @ 0x08006380
.L08006382:                              @ reached from 0x0800637A bne
    ldr r3, =meter_mode                @ 0x08006382 pool 0x08006AD0 = 0x2000803C
    ldrb r3, [r3, #0]                  @ 0x08006386
    cmp r3, #9                         @ 0x08006388  mode 9 = OHM
.if LOOP_V205 == 0
    bne .Lac_notohm                         @ production: BEEP (mode 10) gets a longer block, below
.else
    bne .L080063B0                     @ 0x0800638A
.endif
    ldr r3, =meter_range               @ 0x0800638C pool 0x08006CF8 = 0x2000803D
    ldrb r3, [r3, #0]                  @ 0x08006390
    cmp r3, #5                         @ 0x08006392  range 5: N = 1
    bne .L0800639C                     @ 0x08006394
    movs r3, #1                        @ 0x08006396
    movs r2, r3                        @ 0x08006398
    b .L080063B0                       @ 0x0800639A
.L0800639C:                              @ reached from 0x08006394 bne
    ldr r3, =meter_range               @ 0x0800639C pool 0x08006CF8 = 0x2000803D
    ldrb r3, [r3, #0]                  @ 0x080063A0
    cmp r3, #6                         @ 0x080063A2  range 6: N = 8
    bne .L080063AC                     @ 0x080063A4
    movs r3, #8                        @ 0x080063A6
    movs r2, r3                        @ 0x080063A8
    b .L080063B0                       @ 0x080063AA
.L080063AC:                              @ reached from 0x080063A4 bne
.if LOOP_V205 == 0
    @ IMP-03 (ARS 7): production services every conversion, so the OHM block is sized for >= 100 ms: ranges 0..6 -> 8, 8, 32, 16, 16, 1, 8 samples
    ldr r3, =meter_range
    ldrb r3, [r3]
    cmp r3, #7
    bhs .Lac_def8                           @ range outside 0..6: v2.05 default of 8
    ldr r2, =mdc_ohm_samples
    ldrb r2, [r2, r3]                       @ N for this OHM range
    b .L080063B0
.Lac_def8:
.endif
    movs r3, #8                             @ v2.05 0x080063AC: other OHM ranges (0..4): N = 8
    movs r2, r3
.if LOOP_V205 == 0
    b .L080063B0
.Lac_notohm:                                @ reached from the mode 9 test: any other mode, r3 = mode
    cmp r3, #10
    bne .L080063B0                          @ N = 16 as v2.05
    movs r2, #64                            @ IMP-04 (ARS 8.2): BEEP displays a block of >= 100 ms, 64 samples at its 640 sps row
.endif
.L080063B0:                              @ reached from 0x08006380 b, 0x0800638A bne, 0x0800639A b, 0x080063AA b
    @ ---- accumulate: count 0x20008080 = 0 starts a new sum (first sample stored), otherwise sum += sample ----
    ldr r3, =v_20008080                @ 0x080063B0 pool 0x08006D18 = 0x20008080
    ldrb r3, [r3, #0]                  @ 0x080063B4
    cmp r3, #0                         @ 0x080063B6
    bne .L080063C2                     @ 0x080063B8
    ldr r3, =v_20007DD0                @ 0x080063BA pool 0x08006D1C = 0x20007DD0
    str r1, [r3, #0]                   @ 0x080063BE
    b .L080063D0                       @ 0x080063C0
.L080063C2:                              @ reached from 0x080063B8 bne
    ldr r3, =v_20007DD0                @ 0x080063C2 pool 0x08006D1C = 0x20007DD0
    ldr r3, [r3, #0]                   @ 0x080063C6
    adds r3, r1, r3                    @ 0x080063C8
    ldr r4, =v_20007DD0                @ 0x080063CA pool 0x08006D1C = 0x20007DD0
    str r3, [r4, #0]                   @ 0x080063CE
.L080063D0:                              @ reached from 0x080063C0 b
    ldr r3, =v_20008080                @ 0x080063D0 pool 0x08006D18 = 0x20008080
    ldrb r3, [r3, #0]                  @ 0x080063D4
    adds r3, r3, #1                    @ 0x080063D6
    ldr r4, =v_20008080                @ 0x080063D8 pool 0x08006D18 = 0x20008080
    strb r3, [r4, #0]                  @ 0x080063DC
    ldr r3, =v_20008080                @ 0x080063DE pool 0x08006D18 = 0x20008080
    ldrb r3, [r3, #0]                  @ 0x080063E2
    cmp r3, r2                         @ 0x080063E4  count >= N?
.if LOOP_V205 == 0
    blt .Lac_early                          @ production: a block that is not complete may still give the first mean (IMP-01 P5)
.else
    blt .L08006412                     @ 0x080063E6
.endif
    ldr r3, =v_20007DD0                @ 0x080063E8 pool 0x08006D1C = 0x20007DD0
    ldr r3, [r3, #0]                   @ 0x080063EC
    ldr r4, =v_20008080                @ 0x080063EE pool 0x08006D18 = 0x20008080
    ldrb r4, [r4, #0]                  @ 0x080063F2
    sdiv r3, r3, r4                    @ 0x080063F4  mean = sum / count (signed, truncating)
    ldr r4, =v_20007DD4                @ 0x080063F8 pool 0x08006D20 = 0x20007DD4
    str r3, [r4, #0]                   @ 0x080063FC
    movs r3, #0                        @ 0x080063FE
    ldr r4, =v_20008080                @ 0x08006400 pool 0x08006D18 = 0x20008080
    strb r3, [r4, #0]                  @ 0x08006404
    movs r3, #0                        @ 0x08006406
    ldr r4, =v_20007DD0                @ 0x08006408 pool 0x08006D1C = 0x20007DD0
    str r3, [r4, #0]                   @ 0x0800640C
    movs r3, #1                        @ 0x0800640E
    movs r0, r3                        @ 0x08006410  r0 = 1: mean complete
.if LOOP_V205 == 0
    ldr r3, =v_20000238                     @ IMP-01 P5: a mean published while v2.05 still discards means (settle count != 0) is not the
    ldrb r3, [r3]                           @ first displayed value, so the request stays; a mean that is displayed ends it
    cbnz r3, .L08006412
    ldr r4, =mdc_first_mean
    strb r3, [r4]                           @ r3 = 0: the first value of this change is out
.endif
.L08006412:                              @ reached from 0x080063E6 blt
    uxtb r0, r0                        @ 0x08006412
    pop {r4}                           @ 0x08006414
    bx lr                              @ 0x08006416
.if LOOP_V205 == 0
@ ---- IMP-01 P5: count < N.  After a configuration change the first displayed value is the mean of MDC_NFIRST clean samples (ARS 5.2 P5) ----
@ The block is not restarted: it goes on to N samples (window grows to the v2.05 N), so only the first value after a change is a short mean.
@ Conditions: the apply armed mdc_first_mean (fn_0800B974), the count is exactly MDC_NFIRST, v2.05 no longer discards means of this change
@ (settle count 0x20000238 = 0: otherwise this block's mean would be discarded anyway and the discard time must stay as in the CP profile of AR),
@ and the mode is one whose handler displays every mean it is given: DCV, ACV (AC+DC off), DCmV, ACmV, OHM, BEEP and the current modes unless
@ the two-channel scheme counts means (0x200080A5 = 1 outside calibration mode: fn_08007FA8 and fn_0800664A switch channels after 3 means).
.Lac_early:                                 @ r0 = 0, r3 = count, r2 = N
    cmp r3, #MDC_NFIRST
    bne .L08006412                          @ not the first-mean count
    ldr r1, =mdc_first_mean
    ldrb r1, [r1]
    cmp r1, #0
    beq .L08006412                          @ no configuration change pending
    ldr r1, =v_20000238
    ldrb r1, [r1]
    cmp r1, #0
    bne .L08006412                          @ v2.05 still discards means after this change
    ldr r1, =meter_mode
    ldrb r1, [r1]                           @ r1 = mode
    movs r4, #1
    lsls r4, r4, r1                         @ bit of the mode (0 for a mode above 31)
    ldr r12, =MDC_FIRST_MASK
    tst r4, r12
    beq .L08006412                          @ mode not eligible
    cmp r1, #2
    bne 1f
    ldr r4, =acdc_active
    ldrb r4, [r4]
    cmp r4, #0
    bne .L08006412                          @ ACV with AC+DC: the phases are paced by MAC
    b 2f
1:  cmp r1, #16
    blo 2f
    ldr r4, =v_2000808A
    ldrb r4, [r4]                           @ calibration mode ...
    ldr r12, =v_200080A5
    ldrb r12, [r12]
    eor r12, r12, #1                        @ ... or burden option off (0x200080A5 != 1): single-channel chain
    orrs r4, r4, r12
    beq .L08006412                          @ two-channel scheme counts means: no short mean
2:  ldr r4, =v_20007DD0
    ldr r4, [r4]                            @ sum of the MDC_NFIRST samples
    sdiv r4, r4, r3                         @ mean (signed, truncating, as the full mean)
    ldr r1, =v_20007DD4
    str r4, [r1]
    movs r4, #0
    ldr r1, =mdc_first_mean
    strb r4, [r1]                           @ the first value is out
    movs r0, #1                             @ r0 = 1: a mean was completed (count and sum go on)
    b .L08006412
.endif
    .ltorg
ENDFUNC ad1_accumulate_average

@ -----------------------------------------------------------------------------
@ fn_08006418 - mean code -> calibrated displayed value 0x20007D64
@ Replaces : 0x08006418 FUN_08006418 (v2.05)
@ In       : - (reads the mean 0x20007DD4)
@ Out      : - (writes 0x20007D64)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x20007D64, 0x20007DD4, 0x2000808C, 0x2000808E
@            writes 0x20007D64
@ Spec     : analysis/hy3131_model.md 5.2 steps 1..3
@ Deviation: none
@ Non-VA modes: D = fn_0800F37E(fn_0800EEF0(mean)) = divide_by_gain(mean - offset) (offset skipped in DIODE).  VA modes (13, 14, 15, 22, 23, 24):
@ with the capture flag 0x2000808C set the mean is stored unchanged (calibration capture reads the raw mean); otherwise fn_0800EEF0, then
@ fn_0800F37E unless the second capture flag 0x2000808E is set.  fn_0800EEF0 and fn_0800F37E call the CAL capture routines when a
@ capture is running (0x2000808C / 0x2000808E / 0x20008090).
@ -----------------------------------------------------------------------------
FUNC fn_08006418
    push {r7, lr}                      @ 0x08006418
    ldr r0, =meter_mode                @ 0x0800641A pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800641E
    cmp r0, #13                        @ 0x08006420
    beq .L08006456                     @ 0x08006422
    ldr r0, =meter_mode                @ 0x08006424 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006428
    cmp r0, #14                        @ 0x0800642A
    beq .L08006456                     @ 0x0800642C
    ldr r0, =meter_mode                @ 0x0800642E pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006432
    cmp r0, #15                        @ 0x08006434
    beq .L08006456                     @ 0x08006436
    ldr r0, =meter_mode                @ 0x08006438 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800643C
    cmp r0, #22                        @ 0x0800643E
    beq .L08006456                     @ 0x08006440
    ldr r0, =meter_mode                @ 0x08006442 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006446
    cmp r0, #23                        @ 0x08006448
    beq .L08006456                     @ 0x0800644A
    ldr r0, =meter_mode                @ 0x0800644C pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006450
    cmp r0, #24                        @ 0x08006452
    bne .L0800646E                     @ 0x08006454
.L08006456:                              @ reached from 0x08006422 beq, 0x0800642C beq, 0x08006436 beq, 0x08006440 beq, 0x0800644A beq
    @ ---- VA modes 13, 14, 15, 22, 23, 24: capture flag 0x2000808C set -> displayed value = raw mean, no calibration ----
    ldr r0, =v_2000808C                @ 0x08006456 pool 0x08006D24 = 0x2000808C
    ldrb r0, [r0, #0]                  @ 0x0800645A
    cmp r0, #0                         @ 0x0800645C
    beq .L0800646E                     @ 0x0800645E
    ldr r0, =v_20007DD4                @ 0x08006460 pool 0x08006D20 = 0x20007DD4
    ldr r0, [r0, #0]                   @ 0x08006464
    ldr r1, =v_20007D64                @ 0x08006466 pool 0x08006D28 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800646A
    b .L080064D4                       @ 0x0800646C
.L0800646E:                              @ reached from 0x08006454 bne, 0x0800645E beq
    @ ---- D = fn_0800EEF0(mean): mean - offset (or the capture hook) ----
    ldr r0, =v_20007DD4                @ 0x0800646E pool 0x08006D20 = 0x20007DD4
    ldr r0, [r0, #0]                   @ 0x08006472
    bl fn_0800EEF0                     @ 0x08006474
    ldr r1, =v_20007D64                @ 0x08006478 pool 0x08006D28 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800647C
    ldr r0, =meter_mode                @ 0x0800647E pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006482
    cmp r0, #13                        @ 0x08006484
    beq .L080064BA                     @ 0x08006486
    ldr r0, =meter_mode                @ 0x08006488 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800648C
    cmp r0, #14                        @ 0x0800648E
    beq .L080064BA                     @ 0x08006490
    ldr r0, =meter_mode                @ 0x08006492 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006496
    cmp r0, #15                        @ 0x08006498
    beq .L080064BA                     @ 0x0800649A
    ldr r0, =meter_mode                @ 0x0800649C pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080064A0
    cmp r0, #22                        @ 0x080064A2
    beq .L080064BA                     @ 0x080064A4
    ldr r0, =meter_mode                @ 0x080064A6 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080064AA
    cmp r0, #23                        @ 0x080064AC
    beq .L080064BA                     @ 0x080064AE
    ldr r0, =meter_mode                @ 0x080064B0 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080064B4
    cmp r0, #24                        @ 0x080064B6
    bne .L080064C4                     @ 0x080064B8
.L080064BA:                              @ reached from 0x08006486 beq, 0x08006490 beq, 0x0800649A beq, 0x080064A4 beq, 0x080064AE beq
    @ ---- VA modes: 0x2000808E set -> no division by the gain ----
    ldr r0, =v_2000808E                @ 0x080064BA pool 0x08006D2C = 0x2000808E
    ldrb r0, [r0, #0]                  @ 0x080064BE
    cmp r0, #0                         @ 0x080064C0
    bne .L080064D4                     @ 0x080064C2
.L080064C4:                              @ reached from 0x080064B8 bne
    @ ---- D = fn_0800F37E(D): divide by the gain (or the capture hook) ----
    ldr r0, =v_20007D64                @ 0x080064C4 pool 0x08006D28 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x080064C8
    bl fn_0800F37E                     @ 0x080064CA
    ldr r1, =v_20007D64                @ 0x080064CE pool 0x08006D28 = 0x20007D64
    str r0, [r1, #0]                   @ 0x080064D2
.L080064D4:                              @ reached from 0x0800646C b, 0x080064C2 bne
    pop {r0, pc}                       @ 0x080064D4
    .ltorg
ENDFUNC fn_08006418

@ -----------------------------------------------------------------------------
@ fn_080064D6 - calibrated per-sample value 0x20007D68
@ Replaces : 0x080064D6 FUN_080064D6 (v2.05)
@ In       : - (reads the latest sample 0x20007D74)
@ Out      : - (writes 0x20007D68, flag 0x2000805E = 1)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  mdc_ps_done, 0x2000803C meter_mode, 0x20007D68, 0x20007D74
@            writes mdc_ps_done, 0x20007D68, 0x2000805E
@ Spec     : analysis/hy3131_modes_misc.md 2 (per-sample value), 6.3
@ Deviation: IMP-01 (production: skipped once after mdc_sample_precheck)
@ Not for VA modes (13, 14, 15, 22, 23, 24).  0x20007D68 = divide_by_gain(sample - offset); the DIODE offset skip of fn_0800EEF0 does
@ not apply here (hy3131_modes_misc.md DEF-8: the per-sample value subtracts the offset).
@ -----------------------------------------------------------------------------
FUNC fn_080064D6
.if LOOP_V205 == 0
    ldr r0, =mdc_ps_done
    ldrb r1, [r0]
    cbz r1, 1f
    movs r1, #0
    strb r1, [r0]                           @ IMP-01: mdc_sample_precheck computed this conversion's value already (it is in 0x20007D68)
    bx lr
1:
.endif
    push {r7, lr}                      @ 0x080064D6
    ldr r0, =meter_mode                @ 0x080064D8 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080064DC
    cmp r0, #22                        @ 0x080064DE
    beq .L08006514                     @ 0x080064E0
    ldr r0, =meter_mode                @ 0x080064E2 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080064E6
    cmp r0, #23                        @ 0x080064E8
    beq .L08006514                     @ 0x080064EA
    ldr r0, =meter_mode                @ 0x080064EC pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080064F0
    cmp r0, #24                        @ 0x080064F2
    beq .L08006514                     @ 0x080064F4
    ldr r0, =meter_mode                @ 0x080064F6 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080064FA
    cmp r0, #13                        @ 0x080064FC
    beq .L08006514                     @ 0x080064FE
    ldr r0, =meter_mode                @ 0x08006500 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006504
    cmp r0, #14                        @ 0x08006506
    beq .L08006514                     @ 0x08006508
    ldr r0, =meter_mode                @ 0x0800650A pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800650E
    cmp r0, #15                        @ 0x08006510
    bne .L08006516                     @ 0x08006512
.L08006514:                              @ reached from 0x080064E0 beq, 0x080064EA beq, 0x080064F4 beq, 0x080064FE beq, 0x08006508 beq
    b .L0800653E                       @ 0x08006514
.L08006516:                              @ reached from 0x08006512 bne
    @ ---- r0 = latest sample 0x20007D74 minus the record offset (fn_0800F2FC), then divided by the gain ----
    ldr r0, =v_20007D74                @ 0x08006516 pool 0x08006D08 = 0x20007D74
    ldr r0, [r0, #0]                   @ 0x0800651A
    bl fn_0800F2FC                     @ 0x0800651C  sample - offset
    ldr r1, =v_20007D68                @ 0x08006520 pool 0x08006D30 = 0x20007D68
    str r0, [r1, #0]                   @ 0x08006524
    ldr r0, =v_20007D68                @ 0x08006526 pool 0x08006D30 = 0x20007D68
    ldr r0, [r0, #0]                   @ 0x0800652A
    bl cal_divide_by_gain              @ 0x0800652C  cal_divide_by_gain
    ldr r1, =v_20007D68                @ 0x08006530 pool 0x08006D30 = 0x20007D68
    str r0, [r1, #0]                   @ 0x08006534
    movs r0, #1                        @ 0x08006536
    ldr r1, =v_2000805E                @ 0x08006538 pool 0x08007098 = 0x2000805E
    strb r0, [r1, #0]                  @ 0x0800653C  0x2000805E = 1: new per-sample value
.L0800653E:                              @ reached from 0x08006514 b
    pop {r0, pc}                       @ 0x0800653E
    .ltorg
ENDFUNC fn_080064D6


.if LOOP_V205 == 0
    .equ MDC_PRECHECK_MASK, (1<<1)|(1<<3)|(1<<9)|(1<<17)|(1<<19)|(1<<21)   @ modes DCV, DCmV, OHM, DCuA, DCmA, DCA
@ -----------------------------------------------------------------------------
@ mdc_sample_precheck - judge the auto-ranged DC modes' conversion by ar_sample before it is accumulated (production)
@ Replaces : new (IMP-01, analysis/autorange_and_scheduler.md 5.2 P2..P4; the call placed in ad1_ready_dispatch)
@ In       : - (the decoded sample is in 0x20007DCC, the latest sample in 0x20007D74)
@ Out      : r0 = 1 the conversion must be discarded (ar_sample: settling after an apply, or an apply is pending), 0 accept
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x20007D68, 0x20007DCC, 0x2000808A, 0x200080A5, 0x200080C4 va_channel
@            writes mdc_ps_done, 0x20007D68
@ Spec     : DESIGN.md 6.12 (ar_sample), 6.14; firmware/src/ar/arfast.s ar_sample
@ Deviation: IMP-01
@ Modes DCV (1), DCmV (3), OHM (9) and the DC currents (17, 19, 21; only while the current channel is measured: the same test as
@ FUN_08007FA8, 0x2000808A or 0x200080A5 != 1 or va_channel = 0) run the per-sample chain fn_080064D6 (OHM: negative values clamped
@ to 0 as FUN_080079C4 does afterwards) and pass 0x20007D68 and the decoded sample to ar_sample(value, code).  For an accepted conversion
@ mdc_ps_done is set, so that the mode handler's own call of fn_080064D6 (which follows in the same pass) does not repeat the float
@ work.  Every other mode returns 0 at once.
@ -----------------------------------------------------------------------------
FUNC mdc_sample_precheck
    ldr r0, =meter_mode
    ldrb r0, [r0]                           @ r0 = mode
    movs r1, #1
    lsls r1, r1, r0                         @ bit of the mode (a mode above 31 gives 0)
    ldr r2, =MDC_PRECHECK_MASK
    tst r1, r2
    beq .Lpc_skip                           @ not an auto-ranged DC mode
    cmp r0, #17
    blo .Lpc_go                             @ DCV, DCmV, OHM: always
    ldr r1, =v_2000808A
    ldrb r1, [r1]                           @ calibration mode ...
    ldr r2, =v_200080A5
    ldrb r2, [r2]
    eor r2, r2, #1                          @ ... or the two-channel scheme off (0x200080A5 != 1) ...
    orrs r1, r2
    bne .Lpc_go                             @ ... measure the current channel only (FUN_08007FA8 0x08007FB0..0x08007FC2)
    ldr r1, =va_channel
    ldrb r1, [r1]
    cbnz r1, .Lpc_skip                      @ channel 1 is the voltage channel: not ranged
.Lpc_go:
    push {r4, lr}
    movs r4, r0                             @ r4 = mode
    bl fn_080064D6                          @ 0x20007D68 = calibrated per-sample value
    cmp r4, #9
    bne 1f
    ldr r1, =v_20007D68
    ldr r0, [r1]
    cmp r0, #0
    bge 1f
    movs r0, #0
    str r0, [r1]                            @ OHM: negative per-sample values are 0 (FUN_080079C4 0x08007B1E..0x08007B28)
1:
    ldr r0, =v_20007D68
    ldr r0, [r0]                            @ calibrated per-sample value
    ldr r1, =v_20007DCC
    ldr r1, [r1]                            @ decoded sample, sign-extended 24-bit code
    bl ar_sample                            @ r0 = 1: discard
    cbnz r0, .Lpc_out
    movs r1, #1
    ldr r2, =mdc_ps_done
    strb r1, [r2]                           @ the handler's fn_080064D6 call is covered
.Lpc_out:
    pop {r4, pc}
.Lpc_skip:
    movs r0, #0
    bx lr
    .ltorg
ENDFUNC mdc_sample_precheck


    .section .bss_port.mdc, "aw", %nobits
    .global mdc_ps_done, mdc_first_mean
mdc_ps_done: .space 1                       @ 1 = the per-sample value of this conversion is in 0x20007D68 (consumed by fn_080064D6)
mdc_first_mean: .space 1                    @ 1 = a configuration was applied and its first displayed value is still to come (IMP-01 P5; set by fn_0800B974)
.endif


    .section .rodata.mdc.ad1, "a", %progbits
@ OHM (mode 9) samples per mean in production, by range 0..6 (IMP-03, analysis/autorange_and_scheduler.md 7)
mdc_ohm_samples:
    .byte 8, 8, 32, 16, 16, 1, 8
