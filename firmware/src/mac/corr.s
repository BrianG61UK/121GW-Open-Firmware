@ =============================================================================
@ corr.s - MAC module: frequency-dependent AC correction
@
@ The AC chains subtract a correction CORR(D, calibration words, frequency) from the calibrated count D.
@ fn_0800742C selects it for the mode (gates, index), fn_080075FA fetches the words and the frequency and calls
@ the curve routines fn_080124F4 (all ranges except ACV 0/1) and fn_080129EE (ACV 0/1); fn_080070CC is the
@ extra correction of ACV range 0.  Spec: analysis/hy3131_modes_ac_current.md 5.1..5.4.
@ Tables (read-only, 4-byte entries, v2.05 copies in tables_v205.s): frequency tables 0x0802900C, 0x08029030,
@ 0x08029054, 0x080290F0, 0x08028C58; curve tables 0x08028A18..0x08028EB0, 0x08028AA8..0x08028C10, 0x08028648.
@ Every table index is bounded by the search (k <= N - 1) and k >= 1 holds because F >= 51 Hz is checked
@ before and the first table entry is 50 Hz (or 20000 Hz for the high-frequency tables, used only for F >= 20001).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.mac, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800742C (mac_ac_correction) - frequency correction of an AC count: returns D - CORR (and, in ACV range 0, D - CORR - CORR70)
@ Replaces : 0x0800742C FUN_0800742c (v2.05)
@ In       : r0 = meter mode (only the low byte is used)
@            r1 = D (calibrated count)
@ Out      : r0 = corrected count (D unchanged when no correction applies)
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080067D6, fn_080069B4, fn_08006AEC)
@ Registers: r4 = mode, r5 = D (argument), r6 = curve index idx, r7 = working value D
@ RAM      : reads  0x20007D84 freq_stored, 0x20007E5C corr_value, 0x2000803D meter_range, 0x2000803E freq_range,
@            0x20008087 marker1f_flag, 0x2000808A cal_mode, 0x200080A5 burden_on, 0x200080B9 filter_1khz
@            writes 0x20007E5C corr_value
@ Spec     : analysis/hy3131_modes_ac_current.md 4 step 5, 5.1
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800742C
    push {r3, r4, r5, r6, r7, lr}        @ 0800742C
    movs r4, r0                          @ 0800742E
    movs r5, r1                          @ 08007430
    movs r6, #0                          @ 08007432
    movs r7, r5                          @ 08007434
    @ burden display on (burden_on != 0): no correction
    ldr r0, =v_200080A5                  @ 08007436
    ldrb r0, [r0]                        @ 0800743A  r0 = burden_on (u8)
    cmp r0, #0                           @ 0800743C
    beq .Lmac_ac_correction_08007444     @ 0800743E  if burden_on == 0
    movs r0, r7                          @ 08007440
    b .Lmac_ac_correction_exit           @ 08007442
.Lmac_ac_correction_08007444:   @ branch target from 0800743E
    @ modes 2 and 4 with the 1 kHz filter on: no correction (the filter routine applies its own)
    uxtb r4, r4                          @ 08007444
    cmp r4, #2                           @ 08007446
    beq .Lmac_ac_correction_08007450     @ 08007448  if mode == 2
    uxtb r4, r4                          @ 0800744A
    cmp r4, #4                           @ 0800744C
    bne .Lmac_ac_correction_0800745C     @ 0800744E  if mode != 4
.Lmac_ac_correction_08007450:   @ branch target from 08007448
    ldr r0, =filter_1khz                 @ 08007450
    ldrb r0, [r0]                        @ 08007452  r0 = filter_1khz (u8)
    cmp r0, #1                           @ 08007454
    bne .Lmac_ac_correction_0800745C     @ 08007456  if filter_1khz != 1
    movs r0, r7                          @ 08007458
    b .Lmac_ac_correction_exit           @ 0800745A
.Lmac_ac_correction_0800745C:   @ branch target from 0800744E, 08007456
    @ calibration mode: no correction
    ldr r0, =v_2000808A                  @ 0800745C
    ldrb r0, [r0]                        @ 08007460  r0 = cal_mode (u8)
    cmp r0, #0                           @ 08007462
    bne .Lmac_ac_correction_out          @ 08007464  if cal_mode != 0
    @ only the modes 16, 18, 20, 2, 4 are corrected
    uxtb r4, r4                          @ 08007466
    cmp r4, #0x10                        @ 08007468
    beq .Lmac_ac_correction_08007484     @ 0800746A  if mode == 16
    uxtb r4, r4                          @ 0800746C
    cmp r4, #0x12                        @ 0800746E
    beq .Lmac_ac_correction_08007484     @ 08007470  if mode == 18
    uxtb r4, r4                          @ 08007472
    cmp r4, #0x14                        @ 08007474
    beq .Lmac_ac_correction_08007484     @ 08007476  if mode == 20
    uxtb r4, r4                          @ 08007478
    cmp r4, #2                           @ 0800747A
    beq .Lmac_ac_correction_08007484     @ 0800747C  if mode == 2
    uxtb r4, r4                          @ 0800747E
    cmp r4, #4                           @ 08007480
    bne .Lmac_ac_correction_out          @ 08007482  if mode != 4
.Lmac_ac_correction_08007484:   @ branch target from 0800746A, 08007470, 08007476, 0800747C
    @ index idx for the curve: ACmV range, ACV range + 2, ACuA 6, ACmA 7, ACA 8 (LowZ 5 is unreachable here)
    uxtb r4, r4                          @ 08007484
    cmp r4, #4                           @ 08007486
    bne .Lmac_ac_correction_08007494     @ 08007488  if mode != 4
    ldr r0, =meter_range                 @ 0800748A
    ldrb r0, [r0]                        @ 0800748E  r0 = meter_range (u8)
    movs r6, r0                          @ 08007490
    b .Lmac_ac_correction_080074E0       @ 08007492
.Lmac_ac_correction_08007494:   @ branch target from 08007488
    uxtb r4, r4                          @ 08007494
    cmp r4, #2                           @ 08007496
    bne .Lmac_ac_correction_080074A6     @ 08007498  if mode != 2
    ldr r0, =meter_range                 @ 0800749A
    ldrb r0, [r0]                        @ 0800749E  r0 = meter_range (u8)
    adds r0, r0, #2                      @ 080074A0  r0 = meter_range + 2
    movs r6, r0                          @ 080074A2
    b .Lmac_ac_correction_080074E0       @ 080074A4
.Lmac_ac_correction_080074A6:   @ branch target from 08007498
    uxtb r4, r4                          @ 080074A6
    cmp r4, #0                           @ 080074A8
    bne .Lmac_ac_correction_080074B2     @ 080074AA  if mode != 0
    movs r0, #5                          @ 080074AC
    movs r6, r0                          @ 080074AE
    b .Lmac_ac_correction_080074E0       @ 080074B0
.Lmac_ac_correction_080074B2:   @ branch target from 080074AA
    uxtb r4, r4                          @ 080074B2
    cmp r4, #0x10                        @ 080074B4
    beq .Lmac_ac_correction_080074C4     @ 080074B6  if mode == 16
    uxtb r4, r4                          @ 080074B8
    cmp r4, #0x12                        @ 080074BA
    beq .Lmac_ac_correction_080074C4     @ 080074BC  if mode == 18
    uxtb r4, r4                          @ 080074BE
    cmp r4, #0x14                        @ 080074C0
    bne .Lmac_ac_correction_080074E0     @ 080074C2  if mode != 20
.Lmac_ac_correction_080074C4:   @ branch target from 080074B6, 080074BC
    uxtb r4, r4                          @ 080074C4
    cmp r4, #0x10                        @ 080074C6
    bne .Lmac_ac_correction_080074D0     @ 080074C8  if mode != 16
    movs r0, #6                          @ 080074CA
    movs r6, r0                          @ 080074CC
    b .Lmac_ac_correction_080074E0       @ 080074CE
.Lmac_ac_correction_080074D0:   @ branch target from 080074C8
    uxtb r4, r4                          @ 080074D0
    cmp r4, #0x12                        @ 080074D2
    bne .Lmac_ac_correction_080074DC     @ 080074D4  if mode != 18
    movs r0, #7                          @ 080074D6
    movs r6, r0                          @ 080074D8
    b .Lmac_ac_correction_080074E0       @ 080074DA
.Lmac_ac_correction_080074DC:   @ branch target from 080074D4
    movs r0, #8                          @ 080074DC
    movs r6, r0                          @ 080074DE
.Lmac_ac_correction_080074E0:   @ branch target from 08007492, 080074A4, 080074B0, 080074C2, 080074CE, 080074DA
    @ corr = fn_080075FA(idx, D); D = D - corr
    movs r1, r7                          @ 080074E0
    movs r0, r6                          @ 080074E2
    uxtb r0, r0                          @ 080074E4
    bl fn_080075FA                       @ 080074E6  MAC: correction selector and call of the curve routine
    ldr r1, =v_20007E5C                  @ 080074EA
    str r0, [r1]                         @ 080074EE  corr_value (u32) = r0
    ldr r0, =v_20007E5C                  @ 080074F0
    ldr r0, [r0]                         @ 080074F4  r0 = corr_value (u32)
    subs r7, r7, r0                      @ 080074F6  r7 = r7 - corr_value
    @ ACV range 0 with marker 0x1F not written (marker1f_flag): second correction CORR70
    ldr r0, =v_20008087                  @ 080074F8
    ldrb r0, [r0]                        @ 080074FC  r0 = marker1f_flag (u8)
    cmp r0, #0                           @ 080074FE
    beq .Lmac_ac_correction_out          @ 08007500  if marker1f_flag == 0
    uxtb r4, r4                          @ 08007502
    cmp r4, #2                           @ 08007504
    bne .Lmac_ac_correction_out          @ 08007506  if mode != 2
    ldr r0, =meter_range                 @ 08007508
    ldrb r0, [r0]                        @ 0800750C  r0 = meter_range (u8)
    cmp r0, #0                           @ 0800750E
    bne .Lmac_ac_correction_out          @ 08007510  if meter_range != 0
    ldr r0, =v_2000803E                  @ 08007512
    ldrb r2, [r0]                        @ 08007514  r2 = freq_range (u8)
    ldr r0, =v_20007D84                  @ 08007516
    ldr r1, [r0]                         @ 08007518  r1 = freq_stored (u32)
    movs r0, r7                          @ 0800751A
    bl fn_080070CC                       @ 0800751C  MAC: ACV range 0 correction (CORR70)
    ldr r1, =v_20007E5C                  @ 08007520
    str r0, [r1]                         @ 08007524  corr_value (u32) = r0
    ldr r0, =v_20007E5C                  @ 08007526
    ldr r0, [r0]                         @ 0800752A  r0 = corr_value (u32)
    subs r7, r7, r0                      @ 0800752C  r7 = (r7 - corr_value) - corr_value
.Lmac_ac_correction_out:   @ return D
    movs r0, r7                          @ 0800752E
.Lmac_ac_correction_exit:   @ return
    pop {r1, r4, r5, r6, r7, pc}         @ 08007530
    .ltorg
ENDFUNC fn_0800742C
    .global mac_ac_correction
    .set mac_ac_correction, fn_0800742C

@ -----------------------------------------------------------------------------
@ fn_080075FA (mac_ac_corr_select) - select the frequency source and call the correction curve with the four AC calibration words
@ Replaces : 0x080075FA FUN_080075fa (v2.05)
@ In       : r0 = index idx (ACmV range 0/1, ACV range + 2, ACuA 6, ACmA 7, ACA 8)
@            r1 = D (calibrated count)
@ Out      : r0 = CORR(D)
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_0800742C)
@ Registers: r4 = idx, r5 = D, r6 = result
@ RAM      : reads  0x20007D84 freq_stored, 0x20007E4C ac_w0, 0x20007E50 ac_w1, 0x20007E54 ac_w2, 0x20007E58 ac_w3,
@            0x20007E60 acdc_freq, 0x20007E64 lowz_freq, 0x2000803C meter_mode, 0x2000803E freq_range,
@            0x20008087 marker1f_flag, 0x20008098 lowz_ac, 0x200080A0 lowz_fr, 0x200080A1 lowz_fr2,
@            0x200080BA acdc_active
@            writes 0x20007D84 freq_stored, 0x2000803E freq_range
@ Spec     : analysis/hy3131_modes_ac_current.md 5.1, 5.2
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_080075FA
    push {r4, r5, r6, lr}                @ 080075FA
    sub sp, #0x18                        @ 080075FC  sp = sp - 0x18
    movs r4, r0                          @ 080075FE
    movs r5, r1                          @ 08007600
    movs r6, #0                          @ 08007602
    ldr r0, =meter_mode                  @ 08007604
    ldrb r0, [r0]                        @ 08007606  r0 = meter_mode (u8)
    cmp r0, #0x10                        @ 08007608
    beq .Lmac_ac_corr_select_0800762C    @ 0800760A  if meter_mode == 16
    ldr r0, =meter_mode                  @ 0800760C
    ldrb r0, [r0]                        @ 0800760E  r0 = meter_mode (u8)
    cmp r0, #0x12                        @ 08007610
    beq .Lmac_ac_corr_select_0800762C    @ 08007612  if meter_mode == 18
    ldr r0, =meter_mode                  @ 08007614
    ldrb r0, [r0]                        @ 08007616  r0 = meter_mode (u8)
    cmp r0, #0x14                        @ 08007618
    beq .Lmac_ac_corr_select_0800762C    @ 0800761A  if meter_mode == 20
    ldr r0, =meter_mode                  @ 0800761C
    ldrb r0, [r0]                        @ 0800761E  r0 = meter_mode (u8)
    cmp r0, #2                           @ 08007620
    beq .Lmac_ac_corr_select_0800762C    @ 08007622  if meter_mode == 2
    ldr r0, =meter_mode                  @ 08007624
    ldrb r0, [r0]                        @ 08007626  r0 = meter_mode (u8)
    cmp r0, #4                           @ 08007628
    bne .Lmac_ac_corr_select_08007654    @ 0800762A  if meter_mode != 4
.Lmac_ac_corr_select_0800762C:   @ branch target from 0800760A, 08007612, 0800761A, 08007622
    @ AC+DC (mode 2, acdc_active): frequency and range of the AC phase come from the AC+DC copies
    ldr r0, =meter_mode                  @ 0800762C
    ldrb r0, [r0]                        @ 0800762E  r0 = meter_mode (u8)
    cmp r0, #2                           @ 08007630
    bne .Lmac_ac_corr_select_call        @ 08007632  if meter_mode != 2
    ldr r0, =acdc_active                 @ 08007634
    ldrb r0, [r0]                        @ 08007638  r0 = acdc_active (u8)
    cmp r0, #0                           @ 0800763A
    beq .Lmac_ac_corr_select_call        @ 0800763C  if acdc_active == 0
    ldr r0, =v_20007E60                  @ 0800763E
    ldr r0, [r0]                         @ 08007642  r0 = acdc_freq (u32)
    ldr r1, =v_20007D84                  @ 08007644
    str r0, [r1]                         @ 08007646  freq_stored (u32) = acdc_freq
    ldr r0, =v_200080A0                  @ 08007648
    ldrb r0, [r0]                        @ 0800764C  r0 = lowz_fr (u8)
    ldr r1, =v_2000803E                  @ 0800764E
    strb r0, [r1]                        @ 08007650  freq_range (u8) = lowz_fr
    b .Lmac_ac_corr_select_call          @ 08007652
.Lmac_ac_corr_select_08007654:   @ branch target from 0800762A
    @ LowZ AC: copies of the LowZ frequency (unreachable through fn_0800742C, kept as v2.05)
    ldr r0, =meter_mode                  @ 08007654
    ldrb r0, [r0]                        @ 08007656  r0 = meter_mode (u8)
    cmp r0, #0                           @ 08007658
    bne .Lmac_ac_corr_select_call        @ 0800765A  if meter_mode != 0
    ldr r0, =v_20008098                  @ 0800765C
    ldrb r0, [r0]                        @ 08007660  r0 = lowz_ac (u8)
    cmp r0, #0                           @ 08007662
    beq .Lmac_ac_corr_select_call        @ 08007664  if lowz_ac == 0
    ldr r0, =v_20007E64                  @ 08007666
    ldr r0, [r0]                         @ 0800766A  r0 = lowz_freq (u32)
    ldr r1, =v_20007D84                  @ 0800766C
    str r0, [r1]                         @ 0800766E  freq_stored (u32) = lowz_freq
    ldr r0, =v_200080A1                  @ 08007670
    ldrb r0, [r0]                        @ 08007674  r0 = lowz_fr2 (u8)
    ldr r1, =v_2000803E                  @ 08007676
    strb r0, [r1]                        @ 08007678  freq_range (u8) = lowz_fr2
.Lmac_ac_corr_select_call:   @ frequency source chosen
    @ arguments of fn_080124F4(D, w0, w1, w2, w3, idx, F, fr, marker1f_flag)
    ldr r0, =v_20008087                  @ 0800767A
    ldrb r0, [r0]                        @ 0800767E  r0 = marker1f_flag (u8)
    str r0, [sp, #0x10]                  @ 08007680
    ldr r0, =v_2000803E                  @ 08007682
    ldrb r0, [r0]                        @ 08007684  r0 = freq_range (u8)
    str r0, [sp, #0xc]                   @ 08007686
    ldr r0, =v_20007D84                  @ 08007688
    ldr r0, [r0]                         @ 0800768A  r0 = freq_stored (u32)
    str r0, [sp, #8]                     @ 0800768C
    movs r0, r4                          @ 0800768E
    uxtb r0, r0                          @ 08007690
    str r0, [sp, #4]                     @ 08007692
    ldr r0, =v_20007E58                  @ 08007694
    ldr r0, [r0]                         @ 08007698  r0 = ac_w3 (u32)
    str r0, [sp]                         @ 0800769A
    ldr r0, =v_20007E54                  @ 0800769C
    ldr r3, [r0]                         @ 080076A0  r3 = ac_w2 (u32)
    ldr r0, =v_20007E50                  @ 080076A2
    ldr r2, [r0]                         @ 080076A6  r2 = ac_w1 (u32)
    ldr r0, =v_20007E4C                  @ 080076A8
    ldr r1, [r0]                         @ 080076AC  r1 = ac_w0 (u32)
    movs r0, r5                          @ 080076AE
    bl fn_080124F4                       @ 080076B0  MAC: correction curve (D, w0, w1, w2, w3, idx, F, fr, flag)
    movs r6, r0                          @ 080076B4
    movs r0, r6                          @ 080076B6
    add sp, #0x18                        @ 080076B8  sp = sp + 0x18
    pop {r4, r5, r6, pc}                 @ 080076BA
    .ltorg
ENDFUNC fn_080075FA
    .global mac_ac_corr_select
    .set mac_ac_corr_select, fn_080075FA

@ -----------------------------------------------------------------------------
@ fn_080124F4 (mac_corr_curve) - correction CORR(D, w0..w3, idx, F, fr, flag) for all indices except ACV ranges 0 and 1
@ Replaces : 0x080124F4 FUN_080124f4 (v2.05)
@ In       : r0 = D, r1 = w0, r2 = w1, r3 = w2
@            stack: [sp] = w3, [sp+4] = idx, [sp+8] = stored frequency, [sp+12] = fr (frequency range), [sp+16] = marker1f_flag
@ Out      : r0 = CORR (0 when D is at or above the range limit, F < 51 Hz, or idx >= 8)
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080075FA)
@ Registers: r6 = D, r8 = w1, sb = w3 for the whole routine; at entry r4 = idx, r5 = marker1f_flag, r7 = w0 (r4, r5, r7 are reused as scratch later); sl = second-row flag hi, fp = number of columns N; w2 is kept at [sp, #0x10]
@ RAM      : reads  0x20007F0C cv_result, 0x20007F10 cv_f_hz, 0x20007F14 cv_p, 0x20007F18 cv_span,
@            0x20007F1C cv_delta, 0x20007F20 cv_a, 0x20007F24 cv_b, 0x20007F28 cv_l, 0x20007F2C cv_h,
@            0x20007F30 cv_x_k, 0x20007F34 cv_x_km1, 0x20007F38 cv_base, 0x20007F3C cv_w0, 0x20007F40 cv_w1,
@            0x20007F44 cv_zero, 0x20007F48 cv_t, 0x20007F4C cv_q
@            writes 0x20007F0C cv_result, 0x20007F10 cv_f_hz, 0x20007F14 cv_p, 0x20007F18 cv_span,
@            0x20007F1C cv_delta, 0x20007F20 cv_a, 0x20007F24 cv_b, 0x20007F28 cv_l, 0x20007F2C cv_h,
@            0x20007F30 cv_x_k, 0x20007F34 cv_x_km1, 0x20007F38 cv_base, 0x20007F3C cv_w0, 0x20007F40 cv_w1,
@            0x20007F44 cv_zero, 0x20007F48 cv_t, 0x20007F4C cv_q
@ Spec     : analysis/hy3131_modes_ac_current.md 5.2
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_080124F4
    push {r3, r4, r5, r6, r7, r8, sb, sl, fp, lr} @ 080124F4
    sub sp, #0x10                        @ 080124F8  sp = sp - 0x10
    movs r6, r0                          @ 080124FA
    movs r7, r1                          @ 080124FC
    mov r8, r2                           @ 080124FE
    ldr sb, [sp, #0x38]                  @ 08012500
    ldr r1, [sp, #0x40]                  @ 08012504
    ldr r0, [sp, #0x44]                  @ 08012506
    ldr r5, [sp, #0x48]                  @ 08012508
    @ r10 = 1 (second-row flag, cleared below for D < 5001), r11 = N = 9 columns; cv_result = 0 and cv_zero = 0
    movs sl, #1                          @ 0801250A
    movs fp, #9                          @ 0801250E
    ldr r2, =v_20007F0C                  @ 08012512
    movs r3, #0                          @ 08012516
    str r3, [r2]                         @ 08012518  cv_result (u32) = 0
    ldr r2, =v_20007F44                  @ 0801251A
    movs r3, #0                          @ 0801251E
    str r3, [r2]                         @ 08012520  cv_zero (u32) = 0
    @ upper limits: idx 5 (ACV r3): D >= 6600, idx 4 (ACV r2): D >= 60000, others D >= 55000: no correction
    ldr r4, [sp, #0x3c]                  @ 08012522
    uxtb r4, r4                          @ 08012524
    cmp r4, #5                           @ 08012526
    bne .Lmac_corr_curve_chk4            @ 08012528  if r4 != 5
    movw r2, #0x19c8                     @ 0801252A  = 6600
    cmp r6, r2                           @ 0801252E
    blt .Lmac_corr_curve_chk4            @ 08012530  if D < (signed) 6600
    ldr r0, =v_20007F0C                  @ 08012532
    ldr r0, [r0]                         @ 08012536  r0 = cv_result (u32)
    b .Lmac_corr_curve_exit              @ 08012538
.Lmac_corr_curve_chk4:   @ not idx 5
    uxtb r4, r4                          @ 0801253A
    cmp r4, #4                           @ 0801253C
    bne .Lmac_corr_curve_chk55           @ 0801253E  if r4 != 4
    movw r2, #0xea60                     @ 08012540  = 60000
    cmp r6, r2                           @ 08012544
    blt .Lmac_corr_curve_chk55           @ 08012546  if D < (signed) 60000
    ldr r0, =v_20007F0C                  @ 08012548
    ldr r0, [r0]                         @ 0801254C  r0 = cv_result (u32)
    b .Lmac_corr_curve_exit              @ 0801254E
.Lmac_corr_curve_chk55:   @ not idx 4
    movw r2, #0xd6d8                     @ 08012550  = 55000
    cmp r6, r2                           @ 08012554
    blt .Lmac_corr_curve_chkidx          @ 08012556  if D < (signed) 55000
    ldr r0, =v_20007F0C                  @ 08012558
    ldr r0, [r0]                         @ 0801255C  r0 = cv_result (u32)
    b .Lmac_corr_curve_exit              @ 0801255E
.Lmac_corr_curve_chkidx:   @ D below the limit
    @ idx >= 8 (ACA): no correction
    uxtb r4, r4                          @ 08012560
    cmp r4, #8                           @ 08012562
    blt .Lmac_corr_curve_freq            @ 08012564  if r4 < (signed) 8
    ldr r0, =v_20007F0C                  @ 08012566
    ldr r0, [r0]                         @ 0801256A  r0 = cv_result (u32)
    b .Lmac_corr_curve_exit              @ 0801256C
.Lmac_corr_curve_freq:   @ D below the limit; idx < 8
    @ F = frequency in Hz (fn_08012F28); F < 51 Hz: no correction
    uxtb r0, r0                          @ 0801256E
    bl fn_08012F28                       @ 08012570  MFRQ: frequency in Hz from the stored value (r1) and its range (r0)
    ldr r1, =v_20007F10                  @ 08012574
    str r0, [r1]                         @ 08012578  cv_f_hz (u32) = r0
    ldr r0, =v_20007F10                  @ 0801257A
    ldr r0, [r0]                         @ 0801257E  r0 = cv_f_hz (u32)
    cmp r0, #0x33                        @ 08012580
    bge .Lmac_corr_curve_freq_ok         @ 08012582  if cv_f_hz >= (signed) 51
    ldr r0, =v_20007F0C                  @ 08012584
    ldr r0, [r0]                         @ 08012588  r0 = cv_result (u32)
    b .Lmac_corr_curve_exit              @ 0801258A
.Lmac_corr_curve_freq_ok:   @ F >= 51
    @ idx 2, 3 (ACV ranges 0, 1): fn_080129EE
    uxtb r4, r4                          @ 0801258C
    cmp r4, #2                           @ 0801258E
    beq .Lmac_corr_curve_08012598        @ 08012590  if r4 == 2
    uxtb r4, r4                          @ 08012592
    cmp r4, #3                           @ 08012594
    bne .Lmac_corr_curve_table           @ 08012596  if r4 != 3
.Lmac_corr_curve_08012598:   @ branch target from 08012590
    uxtb r5, r5                          @ 08012598
    str r5, [sp, #0xc]                   @ 0801259A
    ldr r0, =v_20007F10                  @ 0801259C
    ldr r0, [r0]                         @ 080125A0  r0 = cv_f_hz (u32)
    str r0, [sp, #8]                     @ 080125A2
    uxtb r4, r4                          @ 080125A4
    str r4, [sp, #4]                     @ 080125A6
    str sb, [sp]                         @ 080125A8
    ldr r3, [sp, #0x10]                  @ 080125AC
    mov r2, r8                           @ 080125AE
    movs r1, r7                          @ 080125B0
    movs r0, r6                          @ 080125B2
    bl fn_080129EE                       @ 080125B4  MAC: ACV range 0/1 correction curve
    ldr r1, =v_20007F0C                  @ 080125B8
    str r0, [r1]                         @ 080125BC  cv_result (u32) = r0
    ldr r0, =v_20007F0C                  @ 080125BE
    ldr r0, [r0]                         @ 080125C2  r0 = cv_result (u32)
    b .Lmac_corr_curve_exit              @ 080125C4
.Lmac_corr_curve_table:   @ idx 0, 1, 4..7
    @ N = 9 columns (idx 0, 1: ACmV) or 7 (idx 4..7)
    uxtb r4, r4                          @ 080125C6
    cmp r4, #4                           @ 080125C8
    blt .Lmac_corr_curve_080125D0        @ 080125CA  if r4 < (signed) 4
    movs fp, #7                          @ 080125CC
.Lmac_corr_curve_080125D0:   @ branch target from 080125CA
    @ k = first i with F <= FT[i] (FT = 0x0802900C for idx < 2, else 0x080290F0), else N - 1
    subs r5, fp, #1                      @ 080125D0  r5 = fp - 1
    movs r0, #0                          @ 080125D4
    b .Lmac_corr_curve_080125DA          @ 080125D6
.Lmac_corr_curve_080125D8:   @ branch target from 080125F4, 080125FE, 08012610
    adds r0, r0, #1                      @ 080125D8  r0 = r0 + 1
.Lmac_corr_curve_080125DA:   @ branch target from 080125D6
    cmp r0, fp                           @ 080125DA
    bge .Lmac_corr_curve_weight          @ 080125DC  if r0 >= (signed) fp
    uxtb r4, r4                          @ 080125DE
    cmp r4, #2                           @ 080125E0
    bge .Lmac_corr_curve_080125FA        @ 080125E2  if r4 >= (signed) 2
    ldr r1, =v205_tab_0802900C           @ 080125E4
    ldr r1, [r1, r0, lsl #2]             @ 080125E8
    ldr r2, =v_20007F10                  @ 080125EC
    ldr r2, [r2]                         @ 080125F0  r2 = cv_f_hz (u32)
    cmp r1, r2                           @ 080125F2
    blt .Lmac_corr_curve_080125D8        @ 080125F4  if r1 < (signed) cv_f_hz
    movs r5, r0                          @ 080125F6
    b .Lmac_corr_curve_weight            @ 080125F8
.Lmac_corr_curve_080125FA:   @ branch target from 080125E2
    uxtb r4, r4                          @ 080125FA
    cmp r4, #4                           @ 080125FC
    blt .Lmac_corr_curve_080125D8        @ 080125FE  if r4 < (signed) 4
    ldr r1, =v205_tab_080290F0           @ 08012600
    ldr r1, [r1, r0, lsl #2]             @ 08012604
    ldr r2, =v_20007F10                  @ 08012608
    ldr r2, [r2]                         @ 0801260C  r2 = cv_f_hz (u32)
    cmp r1, r2                           @ 0801260E
    blt .Lmac_corr_curve_080125D8        @ 08012610  if r1 < (signed) cv_f_hz
    movs r5, r0                          @ 08012612
.Lmac_corr_curve_weight:   @ index k found
    @ t = (F - FT[k-1]) / (FT[k] - FT[k-1]) as float32
    ldr r0, =v_20007F3C                  @ 08012614
    str r7, [r0]                         @ 08012618  cv_w0 (u32) = r7
    ldr r0, =v_20007F40                  @ 0801261A
    str r8, [r0]                         @ 0801261E  cv_w1 (u32) = w1
    uxtb r4, r4                          @ 08012622
    cmp r4, #2                           @ 08012624
    bge .Lmac_corr_curve_0801264A        @ 08012626  if r4 >= (signed) 2
    ldr r0, =v205_tab_0802900C           @ 08012628
    ldr r0, [r0, r5, lsl #2]             @ 0801262C
    ldr r1, =v_20007F30                  @ 08012630
    str r0, [r1]                         @ 08012634  cv_x_k (u32) = r0
    ldr r0, =v205_tab_0802900C           @ 08012636
    adds r0, r0, r5, lsl #2              @ 0801263A  r0 = r0 + (r5 << 2)
    ldr r0, [r0, #-0x4]                  @ 0801263E
    ldr r1, =v_20007F34                  @ 08012642
    str r0, [r1]                         @ 08012646  cv_x_km1 (u32) = r0
    b .Lmac_corr_curve_08012670          @ 08012648
.Lmac_corr_curve_0801264A:   @ branch target from 08012626
    uxtb r4, r4                          @ 0801264A
    cmp r4, #4                           @ 0801264C
    blt .Lmac_corr_curve_08012670        @ 0801264E  if r4 < (signed) 4
    ldr r0, =v205_tab_080290F0           @ 08012650
    ldr r0, [r0, r5, lsl #2]             @ 08012654
    ldr r1, =v_20007F30                  @ 08012658
    str r0, [r1]                         @ 0801265C  cv_x_k (u32) = r0
    ldr r0, =v205_tab_080290F0           @ 0801265E
    adds r0, r0, r5, lsl #2              @ 08012662  r0 = r0 + (r5 << 2)
    ldr r0, [r0, #-0x4]                  @ 08012666
    ldr r1, =v_20007F34                  @ 0801266A
    str r0, [r1]                         @ 0801266E  cv_x_km1 (u32) = r0
.Lmac_corr_curve_08012670:   @ branch target from 08012648, 0801264E
    ldr r0, =v_20007F30                  @ 08012670
    ldr r0, [r0]                         @ 08012674  r0 = cv_x_k (u32)
    ldr r1, =v_20007F34                  @ 08012676
    ldr r1, [r1]                         @ 0801267A  r1 = cv_x_km1 (u32)
    subs r0, r0, r1                      @ 0801267C  r0 = cv_x_k - cv_x_km1
    ldr r1, =v_20007F18                  @ 0801267E
    str r0, [r1]                         @ 08012682  cv_span (u32) = (cv_x_k - cv_x_km1)
    ldr r0, =v_20007F10                  @ 08012684
    ldr r0, [r0]                         @ 08012688  r0 = cv_f_hz (u32)
    ldr r1, =v_20007F34                  @ 0801268A
    ldr r1, [r1]                         @ 0801268E  r1 = cv_x_km1 (u32)
    subs r0, r0, r1                      @ 08012690  r0 = cv_f_hz - cv_x_km1
    ldr r1, =v_20007F1C                  @ 08012692
    str r0, [r1]                         @ 08012696  cv_delta (u32) = (cv_f_hz - cv_x_km1)
    ldr r0, =v_20007F1C                  @ 08012698
    ldr r0, [r0]                         @ 0801269C  r0 = cv_delta (u32)
    bl fn_08012F60                       @ 0801269E  RT: float32 = (int32)r0
    movs r7, r0                          @ 080126A2
    ldr r0, =v_20007F18                  @ 080126A4
    ldr r0, [r0]                         @ 080126A8  r0 = cv_span (u32)
    bl fn_08012F60                       @ 080126AA  RT: float32 = (int32)r0
    movs r1, r0                          @ 080126AE
    movs r0, r7                          @ 080126B0
    bl fn_08012F94                       @ 080126B2  RT: float32 r0 = r0 / r1
    ldr r1, =v_20007F48                  @ 080126B6
    str r0, [r1]                         @ 080126BA  cv_t (u32) = r0
    @ hi = 0 for D < 5001 (first row of X), 1 otherwise (second row)
    movw r0, #0x1389                     @ 080126BC  = 5001
    cmp r6, r0                           @ 080126C0
    bge .Lmac_corr_curve_xsel            @ 080126C2  if D >= (signed) 5001
    movs sl, #0                          @ 080126C4
.Lmac_corr_curve_xsel:   @ hi row chosen
    @ curve table X by idx: 0 -> 0x08028A18 (row stride 0x24), 1 -> 0x08028A60, 4 -> 0x08028E08 (stride 0x1C), 5 -> 0x08028E40, 6 -> 0x08028E78, 7 -> 0x08028EB0
    uxtb r4, r4                          @ 080126C8
    movs r0, r4                          @ 080126CA
    cmp r0, #0                           @ 080126CC
    beq .Lmac_corr_curve_080126E6        @ 080126CE  if r0 == 0
    cmp r0, #1                           @ 080126D0
    beq .Lmac_corr_curve_08012714        @ 080126D2  if r0 == 1
    cmp r0, #4                           @ 080126D4
    beq .Lmac_corr_curve_08012742        @ 080126D6  if r0 == 4
    cmp r0, #5                           @ 080126D8
    beq .Lmac_corr_curve_08012770        @ 080126DA  if r0 == 5
    cmp r0, #6                           @ 080126DC
    beq .Lmac_corr_curve_0801279E        @ 080126DE  if r0 == 6
    cmp r0, #7                           @ 080126E0
    beq .Lmac_corr_curve_080127CC        @ 080126E2  if r0 == 7
    b .Lmac_corr_curve_interp            @ 080126E4
.Lmac_corr_curve_080126E6:   @ branch target from 080126CE
    movs r0, #0x24                       @ 080126E6  = 36
    ldr r1, =v205_tab_08028A18           @ 080126E8
    mla r0, r0, sl, r1                   @ 080126EC  r0 = 36 * sl + r1
    ldr r0, [r0, r5, lsl #2]             @ 080126F0
    ldr r1, =v_20007F30                  @ 080126F4
    str r0, [r1]                         @ 080126F8  cv_x_k (u32) = r0
    movs r0, #0x24                       @ 080126FA  = 36
    ldr r1, =v205_tab_08028A18           @ 080126FC
    mla r0, r0, sl, r1                   @ 08012700  r0 = 36 * sl + r1
    adds r0, r0, r5, lsl #2              @ 08012704  r0 = (36 * sl + r1) + (r5 << 2)
    ldr r0, [r0, #-0x4]                  @ 08012708
    ldr r1, =v_20007F34                  @ 0801270C
    str r0, [r1]                         @ 08012710  cv_x_km1 (u32) = r0
    b .Lmac_corr_curve_interp            @ 08012712
.Lmac_corr_curve_08012714:   @ branch target from 080126D2
    movs r0, #0x24                       @ 08012714  = 36
    ldr r1, =v205_tab_08028A60           @ 08012716
    mla r0, r0, sl, r1                   @ 0801271A  r0 = 36 * sl + r1
    ldr r0, [r0, r5, lsl #2]             @ 0801271E
    ldr r1, =v_20007F30                  @ 08012722
    str r0, [r1]                         @ 08012726  cv_x_k (u32) = r0
    movs r0, #0x24                       @ 08012728  = 36
    ldr r1, =v205_tab_08028A60           @ 0801272A
    mla r0, r0, sl, r1                   @ 0801272E  r0 = 36 * sl + r1
    adds r0, r0, r5, lsl #2              @ 08012732  r0 = (36 * sl + r1) + (r5 << 2)
    ldr r0, [r0, #-0x4]                  @ 08012736
    ldr r1, =v_20007F34                  @ 0801273A
    str r0, [r1]                         @ 0801273E  cv_x_km1 (u32) = r0
    b .Lmac_corr_curve_interp            @ 08012740
.Lmac_corr_curve_08012742:   @ branch target from 080126D6
    movs r0, #0x1c                       @ 08012742  = 28
    ldr r1, =v205_tab_08028E08           @ 08012744
    mla r0, r0, sl, r1                   @ 08012748  r0 = 28 * sl + r1
    ldr r0, [r0, r5, lsl #2]             @ 0801274C
    ldr r1, =v_20007F30                  @ 08012750
    str r0, [r1]                         @ 08012754  cv_x_k (u32) = r0
    movs r0, #0x1c                       @ 08012756  = 28
    ldr r1, =v205_tab_08028E08           @ 08012758
    mla r0, r0, sl, r1                   @ 0801275C  r0 = 28 * sl + r1
    adds r0, r0, r5, lsl #2              @ 08012760  r0 = (28 * sl + r1) + (r5 << 2)
    ldr r0, [r0, #-0x4]                  @ 08012764
    ldr r1, =v_20007F34                  @ 08012768
    str r0, [r1]                         @ 0801276C  cv_x_km1 (u32) = r0
    b .Lmac_corr_curve_interp            @ 0801276E
    .ltorg
.Lmac_corr_curve_08012770:   @ branch target from 080126DA
    movs r0, #0x1c                       @ 08012770  = 28
    ldr r1, =v205_tab_08028E40           @ 08012772
    mla r0, r0, sl, r1                   @ 08012776  r0 = 28 * sl + r1
    ldr r0, [r0, r5, lsl #2]             @ 0801277A
    ldr r1, =v_20007F30                  @ 0801277E
    str r0, [r1]                         @ 08012782  cv_x_k (u32) = r0
    movs r0, #0x1c                       @ 08012784  = 28
    ldr r1, =v205_tab_08028E40           @ 08012786
    mla r0, r0, sl, r1                   @ 0801278A  r0 = 28 * sl + r1
    adds r0, r0, r5, lsl #2              @ 0801278E  r0 = (28 * sl + r1) + (r5 << 2)
    ldr r0, [r0, #-0x4]                  @ 08012792
    ldr r1, =v_20007F34                  @ 08012796
    str r0, [r1]                         @ 0801279A  cv_x_km1 (u32) = r0
    b .Lmac_corr_curve_interp            @ 0801279C
.Lmac_corr_curve_0801279E:   @ branch target from 080126DE
    movs r0, #0x1c                       @ 0801279E  = 28
    ldr r1, =v205_tab_08028E78           @ 080127A0
    mla r0, r0, sl, r1                   @ 080127A4  r0 = 28 * sl + r1
    ldr r0, [r0, r5, lsl #2]             @ 080127A8
    ldr r1, =v_20007F30                  @ 080127AC
    str r0, [r1]                         @ 080127B0  cv_x_k (u32) = r0
    movs r0, #0x1c                       @ 080127B2  = 28
    ldr r1, =v205_tab_08028E78           @ 080127B4
    mla r0, r0, sl, r1                   @ 080127B8  r0 = 28 * sl + r1
    adds r0, r0, r5, lsl #2              @ 080127BC  r0 = (28 * sl + r1) + (r5 << 2)
    ldr r0, [r0, #-0x4]                  @ 080127C0
    ldr r1, =v_20007F34                  @ 080127C4
    str r0, [r1]                         @ 080127C8  cv_x_km1 (u32) = r0
    b .Lmac_corr_curve_interp            @ 080127CA
.Lmac_corr_curve_080127CC:   @ branch target from 080126E2
    movs r0, #0x1c                       @ 080127CC  = 28
    ldr r1, =v205_tab_08028EB0           @ 080127CE
    mla r0, r0, sl, r1                   @ 080127D2  r0 = 28 * sl + r1
    ldr r0, [r0, r5, lsl #2]             @ 080127D6
    ldr r1, =v_20007F30                  @ 080127DA
    str r0, [r1]                         @ 080127DE  cv_x_k (u32) = r0
    movs r0, #0x1c                       @ 080127E0  = 28
    ldr r1, =v205_tab_08028EB0           @ 080127E2
    mla r0, r0, sl, r1                   @ 080127E6  r0 = 28 * sl + r1
    adds r0, r0, r5, lsl #2              @ 080127EA  r0 = (28 * sl + r1) + (r5 << 2)
    ldr r0, [r0, #-0x4]                  @ 080127EE
    ldr r1, =v_20007F34                  @ 080127F2
    str r0, [r1]                         @ 080127F6  cv_x_km1 (u32) = r0
.Lmac_corr_curve_interp:   @ x[k], x[k-1] fetched
    @ P = X[k-1] + RND(t * (X[k] - X[k-1])), percentage of the calibration word
    ldr r0, =v_20007F18                  @ 080127F8
    ldr r1, =v_20007F34                  @ 080127FC
    ldr r1, [r1]                         @ 08012800  r1 = cv_x_km1 (u32)
    str r1, [r0]                         @ 08012802  cv_span (u32) = cv_x_km1
    ldr r0, =v_20007F30                  @ 08012804
    ldr r0, [r0]                         @ 08012808  r0 = cv_x_k (u32)
    ldr r1, =v_20007F34                  @ 0801280A
    ldr r1, [r1]                         @ 0801280E  r1 = cv_x_km1 (u32)
    subs r0, r0, r1                      @ 08012810  r0 = cv_x_k - cv_x_km1
    ldr r1, =v_20007F1C                  @ 08012812
    str r0, [r1]                         @ 08012816  cv_delta (u32) = (cv_x_k - cv_x_km1)
    ldr r0, =v_20007F18                  @ 08012818
    ldr r5, [r0]                         @ 0801281C  r5 = cv_span (u32)
    ldr r0, =v_20007F1C                  @ 0801281E
    ldr r0, [r0]                         @ 08012822  r0 = cv_delta (u32)
    bl fn_08012F60                       @ 08012824  RT: float32 = (int32)r0
    ldr r1, =v_20007F48                  @ 08012828
    ldr r1, [r1]                         @ 0801282C  r1 = cv_t (u32)
    bl fn_08013090                       @ 0801282E  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 08012832  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 08012836
    ldr r3, =0x3FE00000                  @ 08012838  0x3FE00000:0 = 0.5 (double): rounding term
    bl fn_080131B8                       @ 0801283C  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 08012840  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, r5                      @ 08012844  r0 = r0 + cv_span
    ldr r1, =v_20007F14                  @ 08012846
    str r0, [r1]                         @ 0801284A  cv_p (u32) = (r0 + cv_span)
    @ A = f2iz(P * w0 / 100), B = f2iz(P * w1 / 100)
    ldr r0, =v_20007F3C                  @ 0801284C
    ldr r0, [r0]                         @ 08012850  r0 = cv_w0 (u32)
    bl fn_08012F60                       @ 08012852  RT: float32 = (int32)r0
    movs r5, r0                          @ 08012856
    ldr r0, =v_20007F14                  @ 08012858
    ldr r0, [r0]                         @ 0801285C  r0 = cv_p (u32)
    bl fn_08012F60                       @ 0801285E  RT: float32 = (int32)r0
    movs r1, r5                          @ 08012862
    bl fn_08013090                       @ 08012864  RT: float32 r0 = r0 * r1
    ldr r1, =0x42C80000                  @ 08012868  0x42C80000 = 100.0f
    bl fn_08012F94                       @ 0801286C  RT: float32 r0 = r0 / r1
    bl fn_08013370                       @ 08012870  RT: int32 r0 = (int)float32 r0 (truncating)
    ldr r1, =v_20007F20                  @ 08012874
    str r0, [r1]                         @ 08012878  cv_a (u32) = r0
    ldr r0, =v_20007F40                  @ 0801287A
    ldr r0, [r0]                         @ 0801287E  r0 = cv_w1 (u32)
    bl fn_08012F60                       @ 08012880  RT: float32 = (int32)r0
    movs r5, r0                          @ 08012884
    ldr r0, =v_20007F14                  @ 08012886
    ldr r0, [r0]                         @ 0801288A  r0 = cv_p (u32)
    bl fn_08012F60                       @ 0801288C  RT: float32 = (int32)r0
    movs r1, r5                          @ 08012890
    bl fn_08013090                       @ 08012892  RT: float32 r0 = r0 * r1
    ldr r1, =0x42C80000                  @ 08012896  0x42C80000 = 100.0f
    bl fn_08012F94                       @ 0801289A  RT: float32 r0 = r0 / r1
    bl fn_08013370                       @ 0801289E  RT: int32 r0 = (int)float32 r0 (truncating)
    ldr r1, =v_20007F24                  @ 080128A2
    str r0, [r1]                         @ 080128A6  cv_b (u32) = r0
    @ idx 5: L = A + 600, H = B + 5400, base 600; others L = A + 5000, H = B + 45000, base 5000
    uxtb r4, r4                          @ 080128A8
    cmp r4, #5                           @ 080128AA
    bne .Lmac_corr_curve_080128DC        @ 080128AC  if r4 != 5
    ldr r0, =v_20007F20                  @ 080128AE
    ldr r0, [r0]                         @ 080128B2  r0 = cv_a (u32)
    adds r0, r0, #0x258                  @ 080128B4  r0 = cv_a + 0x258
    ldr r1, =v_20007F28                  @ 080128B8
    str r0, [r1]                         @ 080128BC  cv_l (u32) = (cv_a + 0x258)
    ldr r0, =v_20007F24                  @ 080128BE
    ldr r0, [r0]                         @ 080128C2  r0 = cv_b (u32)
    add r0, r0, #0x1500                  @ 080128C4  + 5400 (0x1518)
    adds r0, #0x18                       @ 080128C8  r0 = (cv_b + 0x1500) + 0x18
    ldr r1, =v_20007F2C                  @ 080128CA
    str r0, [r1]                         @ 080128CE  cv_h (u32) = ((cv_b + 0x1500) + 0x18)
    ldr r0, =v_20007F38                  @ 080128D0
    mov r1, #0x258                       @ 080128D4  600
    str r1, [r0]                         @ 080128D8  cv_base (u32) = 600
    b .Lmac_corr_curve_branch            @ 080128DA
.Lmac_corr_curve_080128DC:   @ branch target from 080128AC
    ldr r0, =v_20007F20                  @ 080128DC
    ldr r0, [r0]                         @ 080128E0  r0 = cv_a (u32)
    add r0, r0, #0x1300                  @ 080128E2  r0 = cv_a + 0x1300
    adds r0, #0x88                       @ 080128E6  r0 = (cv_a + 0x1300) + 0x88
    ldr r1, =v_20007F28                  @ 080128E8
    str r0, [r1]                         @ 080128EC  cv_l (u32) = ((cv_a + 0x1300) + 0x88)
    ldr r0, =v_20007F24                  @ 080128EE
    ldr r0, [r0]                         @ 080128F2  r0 = cv_b (u32)
    add r0, r0, #0xaf00                  @ 080128F4  r0 = cv_b + 0xAF00
    adds r0, #0xc8                       @ 080128F8  r0 = (cv_b + 0xAF00) + 0xC8
    ldr r1, =v_20007F2C                  @ 080128FA
    str r0, [r1]                         @ 080128FE  cv_h (u32) = ((cv_b + 0xAF00) + 0xC8)
    ldr r0, =v_20007F38                  @ 08012900
    movw r1, #0x1388                     @ 08012904  = 5000
    str r1, [r0]                         @ 08012908  cv_base (u32) = 5000
.Lmac_corr_curve_branch:   @ A, B, L, H known
    @ D <= L: result = f2iz(A * (D / L)); else B + f2iz((B - A) * ((D - base) / H - 1))
    ldr r0, =v_20007F28                  @ 0801290A
    ldr r0, [r0]                         @ 0801290E  r0 = cv_l (u32)
    cmp r0, r6                           @ 08012910
    blt .Lmac_corr_curve_high            @ 08012912  if cv_l < (signed) D
    ldr r0, =v_20007F30                  @ 08012914
    movs r1, #0                          @ 08012918
    str r1, [r0]                         @ 0801291A  cv_x_k (u32) = 0
    movs r0, r6                          @ 0801291C
    bl fn_08012F60                       @ 0801291E  RT: float32 = (int32)r0
    movs r4, r0                          @ 08012922
    ldr r0, =v_20007F28                  @ 08012924
    ldr r0, [r0]                         @ 08012928  r0 = cv_l (u32)
    bl fn_08012F60                       @ 0801292A  RT: float32 = (int32)r0
    movs r1, r0                          @ 0801292E
    movs r0, r4                          @ 08012930
    bl fn_08012F94                       @ 08012932  RT: float32 r0 = r0 / r1
    movs r4, r0                          @ 08012936
    ldr r0, =v_20007F20                  @ 08012938
    ldr r0, [r0]                         @ 0801293C  r0 = cv_a (u32)
    bl fn_08012F60                       @ 0801293E  RT: float32 = (int32)r0
    movs r1, r4                          @ 08012942
    bl fn_08013090                       @ 08012944  RT: float32 r0 = r0 * r1
    ldr r1, =v_20007F4C                  @ 08012948
    str r0, [r1]                         @ 0801294C  cv_q (u32) = r0
    b .Lmac_corr_curve_sum               @ 0801294E
.Lmac_corr_curve_high:   @ D > L
    ldr r0, =v_20007F30                  @ 08012950
    ldr r1, =v_20007F24                  @ 08012954
    ldr r1, [r1]                         @ 08012958  r1 = cv_b (u32)
    str r1, [r0]                         @ 0801295A  cv_x_k (u32) = cv_b
    ldr r0, =v_20007F24                  @ 0801295C
    ldr r0, [r0]                         @ 08012960  r0 = cv_b (u32)
    ldr r1, =v_20007F20                  @ 08012962
    ldr r1, [r1]                         @ 08012966  r1 = cv_a (u32)
    subs r0, r0, r1                      @ 08012968  r0 = cv_b - cv_a
    ldr r1, =v_20007F34                  @ 0801296A
    str r0, [r1]                         @ 0801296E  cv_x_km1 (u32) = (cv_b - cv_a)
    ldr r0, =v_20007F38                  @ 08012970
    ldr r0, [r0]                         @ 08012974  r0 = cv_base (u32)
    subs r0, r6, r0                      @ 08012976  r0 = D - cv_base
    bl fn_08012F60                       @ 08012978  RT: float32 = (int32)r0
    movs r4, r0                          @ 0801297C
    ldr r0, =v_20007F2C                  @ 0801297E
    ldr r0, [r0]                         @ 08012982  r0 = cv_h (u32)
    bl fn_08012F60                       @ 08012984  RT: float32 = (int32)r0
    movs r1, r0                          @ 08012988
    movs r0, r4                          @ 0801298A
    bl fn_08012F94                       @ 0801298C  RT: float32 r0 = r0 / r1
    bl fn_08013168                       @ 08012990  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 08012994
    ldr r3, =0xBFF00000                  @ 08012996  0xBFF00000:0 = -1.0 (double)
    bl fn_080131B8                       @ 0801299A  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_0801BACC                       @ 0801299E  RT: float32 r0 = (float)double r0:r1
    ldr r1, =v_20007F4C                  @ 080129A2
    str r0, [r1]                         @ 080129A6  cv_q (u32) = r0
    ldr r0, =v_20007F34                  @ 080129A8
    ldr r0, [r0]                         @ 080129AC  r0 = cv_x_km1 (u32)
    bl fn_08012F60                       @ 080129AE  RT: float32 = (int32)r0
    ldr r1, =v_20007F4C                  @ 080129B2
    ldr r1, [r1]                         @ 080129B6  r1 = cv_q (u32)
    bl fn_08013090                       @ 080129B8  RT: float32 r0 = r0 * r1
    ldr r1, =v_20007F4C                  @ 080129BC
    str r0, [r1]                         @ 080129C0  cv_q (u32) = r0
.Lmac_corr_curve_sum:   @ q known
    ldr r0, =v_20007F30                  @ 080129C2
    ldr r4, [r0]                         @ 080129C6  r4 = cv_x_k (u32)
    ldr r0, =v_20007F4C                  @ 080129C8
    ldr r0, [r0]                         @ 080129CC  r0 = cv_q (u32)
    bl fn_08013370                       @ 080129CE  RT: int32 r0 = (int)float32 r0 (truncating)
    adds r0, r0, r4                      @ 080129D2  r0 = r0 + cv_x_k
    ldr r1, =v_20007F44                  @ 080129D4
    ldr r1, [r1]                         @ 080129D8  r1 = cv_zero (u32)
    adds r0, r1, r0                      @ 080129DA  r0 = cv_zero + (r0 + cv_x_k)
    ldr r1, =v_20007F0C                  @ 080129DC
    str r0, [r1]                         @ 080129E0  cv_result (u32) = (cv_zero + (r0 + cv_x_k))
    ldr r0, =v_20007F0C                  @ 080129E2
    ldr r0, [r0]                         @ 080129E6  r0 = cv_result (u32)
.Lmac_corr_curve_exit:   @ return
    add sp, #0x14                        @ 080129E8  sp = sp + 0x14
    pop {r4, r5, r6, r7, r8, sb, sl, fp, pc} @ 080129EA
    .ltorg
    .ltorg
ENDFUNC fn_080124F4
    .global mac_corr_curve
    .set mac_corr_curve, fn_080124F4

@ -----------------------------------------------------------------------------
@ fn_080129EE (mac_corr_acv01) - correction curve of ACV ranges 0 and 1 (idx 2, 3) with two correction rows and the low/high frequency tables
@ Replaces : 0x080129EE FUN_080129ee (v2.05)
@ In       : r0 = D, r1 = w0, r2 = w1, r3 = w2
@            stack: [sp] = w3, [sp+4] = idx (2 or 3), [sp+8] = F (Hz), [sp+12] = marker1f_flag
@ Out      : r0 = CORR
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080124F4)
@ Registers: r6 = w3 and r7 = F (Hz) for the whole routine; r4 = D, r5 = w2, r8 = idx, sb = marker1f_flag at entry (r4, r5, r8, sb are reused as scratch later); sl = table index k, fp = scratch
@ RAM      : reads  0x20007F50 ca_result, 0x20007F54 ca_d1, 0x20007F58 ca_d0, 0x20007F5C ca_p1, 0x20007F60 ca_p2,
@            0x20007F64 ca_base, 0x20007F68 ca_delta, 0x20007F6C ca_pct, 0x20007F70 ca_l, 0x20007F74 ca_x_k,
@            0x20007F78 ca_x_km1, 0x20007F7C ca_y_k, 0x20007F80 ca_y_km1, 0x20007F84 ca_a, 0x20007F88 ca_b,
@            0x20007F8C ca_out, 0x20007F90 ca_ba, 0x20007F94 ca_t
@            writes 0x20007F50 ca_result, 0x20007F54 ca_d1, 0x20007F58 ca_d0, 0x20007F5C ca_p1, 0x20007F60 ca_p2,
@            0x20007F64 ca_base, 0x20007F68 ca_delta, 0x20007F6C ca_pct, 0x20007F70 ca_l, 0x20007F74 ca_x_k,
@            0x20007F78 ca_x_km1, 0x20007F7C ca_y_k, 0x20007F80 ca_y_km1, 0x20007F84 ca_a, 0x20007F88 ca_b,
@            0x20007F8C ca_out, 0x20007F90 ca_ba, 0x20007F94 ca_t
@ Spec     : analysis/hy3131_modes_ac_current.md 5.3
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_080129EE
    push {r4, r5, r6, r7, r8, sb, sl, fp, lr} @ 080129EE
    movs r4, r0                          @ 080129F2
    movs r5, r3                          @ 080129F4
    ldr r8, [sp, #0x28]                  @ 080129F6
    ldr sb, [sp, #0x30]                  @ 080129FA
    movs r0, #9                          @ 080129FE
    ldr r6, [sp, #0x24]                  @ 08012A00
    @ ca_d1 = w1 - w3, ca_d0 = w0 - w2
    subs r2, r2, r6                      @ 08012A02  r2 = w1 - w3
    ldr r3, =v_20007F54                  @ 08012A04
    str r2, [r3]                         @ 08012A08  ca_d1 (u32) = (w1 - w3)
    subs r1, r1, r5                      @ 08012A0A  r1 = w0 - w2
    ldr r2, =v_20007F58                  @ 08012A0C
    str r1, [r2]                         @ 08012A10  ca_d0 (u32) = (w0 - w2)
    @ k = first i in 0..8 with F <= FT[i], else 8; FT = 0x08029030 for F < 20001, else 0x08029054
    subs sl, r0, #1                      @ 08012A12  sl = 9 - 1
    movs r1, #0                          @ 08012A16
    ldr r7, [sp, #0x2c]                  @ 08012A18
    b .Lmac_corr_acv01_08012A1E          @ 08012A1A
.Lmac_corr_acv01_08012A1C:   @ branch target from 08012A34, 08012A44
    adds r1, r1, #1                      @ 08012A1C  r1 = r1 + 1
.Lmac_corr_acv01_08012A1E:   @ branch target from 08012A1A
    cmp r1, r0                           @ 08012A1E
    bge .Lmac_corr_acv01_08012A48        @ 08012A20  if r1 >= (signed) r0
    movw r2, #0x4e21                     @ 08012A22  = 20001
    cmp r7, r2                           @ 08012A26
    blt .Lmac_corr_acv01_08012A3A        @ 08012A28  if F < (signed) 20001
    ldr r2, =v205_tab_08029054           @ 08012A2A
    ldr r2, [r2, r1, lsl #2]             @ 08012A2E
    cmp r2, r7                           @ 08012A32
    blt .Lmac_corr_acv01_08012A1C        @ 08012A34  if r2 < (signed) F
    mov sl, r1                           @ 08012A36
    b .Lmac_corr_acv01_08012A48          @ 08012A38
.Lmac_corr_acv01_08012A3A:   @ branch target from 08012A28
    ldr r2, =v205_tab_08029030           @ 08012A3A
    ldr r2, [r2, r1, lsl #2]             @ 08012A3E
    cmp r2, r7                           @ 08012A42
    blt .Lmac_corr_acv01_08012A1C        @ 08012A44  if r2 < (signed) F
    mov sl, r1                           @ 08012A46
.Lmac_corr_acv01_08012A48:   @ branch target from 08012A20, 08012A38
    @ x[k], x[k-1] from the frequency table
    movw r0, #0x4e21                     @ 08012A48  = 20001
    cmp r7, r0                           @ 08012A4C
    blt .Lmac_corr_acv01_08012A72        @ 08012A4E  if F < (signed) 20001
    ldr r0, =v205_tab_08029054           @ 08012A50
    ldr r0, [r0, sl, lsl #2]             @ 08012A54
    ldr r1, =v_20007F74                  @ 08012A58
    str r0, [r1]                         @ 08012A5C  ca_x_k (u32) = r0
    ldr r0, =v205_tab_08029054           @ 08012A5E
    adds r0, r0, sl, lsl #2              @ 08012A62  r0 = r0 + (sl << 2)
    ldr r0, [r0, #-0x4]                  @ 08012A66
    ldr r1, =v_20007F78                  @ 08012A6A
    str r0, [r1]                         @ 08012A6E  ca_x_km1 (u32) = r0
    b .Lmac_corr_acv01_08012A92          @ 08012A70
.Lmac_corr_acv01_08012A72:   @ branch target from 08012A4E
    ldr r0, =v205_tab_08029030           @ 08012A72
    ldr r0, [r0, sl, lsl #2]             @ 08012A76
    ldr r1, =v_20007F74                  @ 08012A7A
    str r0, [r1]                         @ 08012A7E  ca_x_k (u32) = r0
    ldr r0, =v205_tab_08029030           @ 08012A80
    adds r0, r0, sl, lsl #2              @ 08012A84  r0 = r0 + (sl << 2)
    ldr r0, [r0, #-0x4]                  @ 08012A88
    ldr r1, =v_20007F78                  @ 08012A8C
    str r0, [r1]                         @ 08012A90  ca_x_km1 (u32) = r0
.Lmac_corr_acv01_08012A92:   @ branch target from 08012A70
    @ t = (F - FT[k-1]) / (FT[k] - FT[k-1])
    ldr r0, =v_20007F74                  @ 08012A92
    ldr r0, [r0]                         @ 08012A96  r0 = ca_x_k (u32)
    ldr r1, =v_20007F78                  @ 08012A98
    ldr r1, [r1]                         @ 08012A9C  r1 = ca_x_km1 (u32)
    subs r0, r0, r1                      @ 08012A9E  r0 = ca_x_k - ca_x_km1
    ldr r1, =v_20007F64                  @ 08012AA0
    str r0, [r1]                         @ 08012AA4  ca_base (u32) = (ca_x_k - ca_x_km1)
    ldr r0, =v_20007F78                  @ 08012AA6
    ldr r0, [r0]                         @ 08012AAA  r0 = ca_x_km1 (u32)
    subs r0, r7, r0                      @ 08012AAC  r0 = F - ca_x_km1
    ldr r1, =v_20007F68                  @ 08012AAE
    str r0, [r1]                         @ 08012AB2  ca_delta (u32) = (F - ca_x_km1)
    ldr r0, =v_20007F68                  @ 08012AB4
    ldr r0, [r0]                         @ 08012AB8  r0 = ca_delta (u32)
    bl fn_08012F60                       @ 08012ABA  RT: float32 = (int32)r0
    mov fp, r0                           @ 08012ABE
    ldr r0, =v_20007F64                  @ 08012AC0
    ldr r0, [r0]                         @ 08012AC4  r0 = ca_base (u32)
    bl fn_08012F60                       @ 08012AC6  RT: float32 = (int32)r0
    movs r1, r0                          @ 08012ACA
    mov r0, fp                           @ 08012ACC
    bl fn_08012F94                       @ 08012ACE  RT: float32 r0 = r0 / r1
    ldr r1, =v_20007F94                  @ 08012AD2
    str r0, [r1]                         @ 08012AD6  ca_t (u32) = r0
    @ row tables by idx and marker1f_flag: idx 2: flag 0 -> 0x08028B38 / 0x08028B80, flag 1 -> 0x08028AA8 / 0x08028AF0; idx 3: 0x08028BC8 / 0x08028C10 (low / high frequency)
    uxtb r8, r8                          @ 08012AD8
    cmp r8, #2                           @ 08012ADC
    beq .Lmac_corr_acv01_08012AEC        @ 08012AE0  if r8 == 2
    cmp r8, #3                           @ 08012AE2
    beq .Lmac_corr_acv01_08012BFC        @ 08012AE6  if r8 == 3
    b .Lmac_corr_acv01_08012C66          @ 08012AEA
.Lmac_corr_acv01_08012AEC:   @ branch target from 08012AE0
    uxtb sb, sb                          @ 08012AEC
    cmp sb, #0                           @ 08012AF0
    beq .Lmac_corr_acv01_08012B82        @ 08012AF4  if flag87 == 0
    movw r0, #0x4e21                     @ 08012AF6  = 20001
    cmp r7, r0                           @ 08012AFA
    blt .Lmac_corr_acv01_08012B40        @ 08012AFC  if F < (signed) 20001
    ldr r0, =v205_tab_08028AF0           @ 08012AFE
    ldr r0, [r0, sl, lsl #2]             @ 08012B02
    ldr r1, =v_20007F74                  @ 08012B06
    str r0, [r1]                         @ 08012B0A  ca_x_k (u32) = r0
    ldr r0, =v205_tab_08028AF0           @ 08012B0C
    adds r0, r0, sl, lsl #2              @ 08012B10  r0 = r0 + (sl << 2)
    ldr r0, [r0, #-0x4]                  @ 08012B14
    ldr r1, =v_20007F78                  @ 08012B18
    str r0, [r1]                         @ 08012B1C  ca_x_km1 (u32) = r0
    ldr r0, =v205_tab_08028AF0           @ 08012B1E
    adds r0, r0, sl, lsl #2              @ 08012B22  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x24]                  @ 08012B26
    ldr r1, =v_20007F7C                  @ 08012B28
    str r0, [r1]                         @ 08012B2C  ca_y_k (u32) = r0
    ldr r0, =v205_tab_08028AF0           @ 08012B2E
    adds r0, r0, sl, lsl #2              @ 08012B32  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x20]                  @ 08012B36
    ldr r1, =v_20007F80                  @ 08012B38
    str r0, [r1]                         @ 08012B3C  ca_y_km1 (u32) = r0
    b .Lmac_corr_acv01_08012BFA          @ 08012B3E
.Lmac_corr_acv01_08012B40:   @ branch target from 08012AFC
    ldr r0, =v205_tab_08028AA8           @ 08012B40
    ldr r0, [r0, sl, lsl #2]             @ 08012B44
    ldr r1, =v_20007F74                  @ 08012B48
    str r0, [r1]                         @ 08012B4C  ca_x_k (u32) = r0
    ldr r0, =v205_tab_08028AA8           @ 08012B4E
    adds r0, r0, sl, lsl #2              @ 08012B52  r0 = r0 + (sl << 2)
    ldr r0, [r0, #-0x4]                  @ 08012B56
    ldr r1, =v_20007F78                  @ 08012B5A
    str r0, [r1]                         @ 08012B5E  ca_x_km1 (u32) = r0
    ldr r0, =v205_tab_08028AA8           @ 08012B60
    adds r0, r0, sl, lsl #2              @ 08012B64  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x24]                  @ 08012B68
    ldr r1, =v_20007F7C                  @ 08012B6A
    str r0, [r1]                         @ 08012B6E  ca_y_k (u32) = r0
    ldr r0, =v205_tab_08028AA8           @ 08012B70
    adds r0, r0, sl, lsl #2              @ 08012B74  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x20]                  @ 08012B78
    ldr r1, =v_20007F80                  @ 08012B7A
    str r0, [r1]                         @ 08012B7E  ca_y_km1 (u32) = r0
    b .Lmac_corr_acv01_08012BFA          @ 08012B80
.Lmac_corr_acv01_08012B82:   @ branch target from 08012AF4
    movw r0, #0x4e21                     @ 08012B82  = 20001
    cmp r7, r0                           @ 08012B86
    blt .Lmac_corr_acv01_08012BCA        @ 08012B88  if F < (signed) 20001
    ldr r0, =v205_tab_08028B80           @ 08012B8A
    ldr r0, [r0, sl, lsl #2]             @ 08012B8E
    ldr r1, =v_20007F74                  @ 08012B92
    str r0, [r1]                         @ 08012B96  ca_x_k (u32) = r0
    ldr r0, =v205_tab_08028B80           @ 08012B98
    adds r0, r0, sl, lsl #2              @ 08012B9C  r0 = r0 + (sl << 2)
    ldr r0, [r0, #-0x4]                  @ 08012BA0
    ldr r1, =v_20007F78                  @ 08012BA4
    str r0, [r1]                         @ 08012BA8  ca_x_km1 (u32) = r0
    ldr r0, =v205_tab_08028B80           @ 08012BAA
    adds r0, r0, sl, lsl #2              @ 08012BAE  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x24]                  @ 08012BB2
    ldr r1, =v_20007F7C                  @ 08012BB4
    str r0, [r1]                         @ 08012BB8  ca_y_k (u32) = r0
    ldr r0, =v205_tab_08028B80           @ 08012BBA
    adds r0, r0, sl, lsl #2              @ 08012BBE  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x20]                  @ 08012BC2
    ldr r1, =v_20007F80                  @ 08012BC4
    str r0, [r1]                         @ 08012BC6  ca_y_km1 (u32) = r0
    b .Lmac_corr_acv01_08012BFA          @ 08012BC8
.Lmac_corr_acv01_08012BCA:   @ branch target from 08012B88
    ldr r0, =v205_tab_08028B38           @ 08012BCA
    ldr r0, [r0, sl, lsl #2]             @ 08012BCC
    ldr r1, =v_20007F74                  @ 08012BD0
    str r0, [r1]                         @ 08012BD2  ca_x_k (u32) = r0
    ldr r0, =v205_tab_08028B38           @ 08012BD4
    adds r0, r0, sl, lsl #2              @ 08012BD6  r0 = r0 + (sl << 2)
    ldr r0, [r0, #-0x4]                  @ 08012BDA
    ldr r1, =v_20007F78                  @ 08012BDE
    str r0, [r1]                         @ 08012BE0  ca_x_km1 (u32) = r0
    ldr r0, =v205_tab_08028B38           @ 08012BE2
    adds r0, r0, sl, lsl #2              @ 08012BE4  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x24]                  @ 08012BE8
    ldr r1, =v_20007F7C                  @ 08012BEA
    str r0, [r1]                         @ 08012BEC  ca_y_k (u32) = r0
    ldr r0, =v205_tab_08028B38           @ 08012BEE
    adds r0, r0, sl, lsl #2              @ 08012BF0  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x20]                  @ 08012BF4
    ldr r1, =v_20007F80                  @ 08012BF6
    str r0, [r1]                         @ 08012BF8  ca_y_km1 (u32) = r0
.Lmac_corr_acv01_08012BFA:   @ branch target from 08012B3E, 08012B80, 08012BC8
    b .Lmac_corr_acv01_08012C66          @ 08012BFA
.Lmac_corr_acv01_08012BFC:   @ branch target from 08012AE6
    movw r0, #0x4e21                     @ 08012BFC  = 20001
    cmp r7, r0                           @ 08012C00
    blt .Lmac_corr_acv01_08012C36        @ 08012C02  if F < (signed) 20001
    ldr r0, =v205_tab_08028C10           @ 08012C04
    ldr r0, [r0, sl, lsl #2]             @ 08012C06
    ldr r1, =v_20007F74                  @ 08012C0A
    str r0, [r1]                         @ 08012C0C  ca_x_k (u32) = r0
    ldr r0, =v205_tab_08028C10           @ 08012C0E
    adds r0, r0, sl, lsl #2              @ 08012C10  r0 = r0 + (sl << 2)
    ldr r0, [r0, #-0x4]                  @ 08012C14
    ldr r1, =v_20007F78                  @ 08012C18
    str r0, [r1]                         @ 08012C1A  ca_x_km1 (u32) = r0
    ldr r0, =v205_tab_08028C10           @ 08012C1C
    adds r0, r0, sl, lsl #2              @ 08012C1E  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x24]                  @ 08012C22
    ldr r1, =v_20007F7C                  @ 08012C24
    str r0, [r1]                         @ 08012C26  ca_y_k (u32) = r0
    ldr r0, =v205_tab_08028C10           @ 08012C28
    adds r0, r0, sl, lsl #2              @ 08012C2A  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x20]                  @ 08012C2E
    ldr r1, =v_20007F80                  @ 08012C30
    str r0, [r1]                         @ 08012C32  ca_y_km1 (u32) = r0
    b .Lmac_corr_acv01_08012C66          @ 08012C34
.Lmac_corr_acv01_08012C36:   @ branch target from 08012C02
    ldr r0, =v205_tab_08028BC8           @ 08012C36
    ldr r0, [r0, sl, lsl #2]             @ 08012C38
    ldr r1, =v_20007F74                  @ 08012C3C
    str r0, [r1]                         @ 08012C3E  ca_x_k (u32) = r0
    ldr r0, =v205_tab_08028BC8           @ 08012C40
    adds r0, r0, sl, lsl #2              @ 08012C42  r0 = r0 + (sl << 2)
    ldr r0, [r0, #-0x4]                  @ 08012C46
    ldr r1, =v_20007F78                  @ 08012C4A
    str r0, [r1]                         @ 08012C4C  ca_x_km1 (u32) = r0
    ldr r0, =v205_tab_08028BC8           @ 08012C4E
    adds r0, r0, sl, lsl #2              @ 08012C50  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x24]                  @ 08012C54
    ldr r1, =v_20007F7C                  @ 08012C56
    str r0, [r1]                         @ 08012C58  ca_y_k (u32) = r0
    ldr r0, =v205_tab_08028BC8           @ 08012C5A
    adds r0, r0, sl, lsl #2              @ 08012C5C  r0 = r0 + (sl << 2)
    ldr r0, [r0, #0x20]                  @ 08012C60
    ldr r1, =v_20007F80                  @ 08012C62
    str r0, [r1]                         @ 08012C64  ca_y_km1 (u32) = r0
.Lmac_corr_acv01_08012C66:   @ branch target from 08012AEA, 08012BFA, 08012C34
    @ P1 = INTERP of the first row, P2 = INTERP of the second row (second row is 9 words further)
    ldr r0, =v_20007F64                  @ 08012C66
    ldr r1, =v_20007F78                  @ 08012C68
    ldr r1, [r1]                         @ 08012C6A  r1 = ca_x_km1 (u32)
    str r1, [r0]                         @ 08012C6C  ca_base (u32) = ca_x_km1
    ldr r0, =v_20007F74                  @ 08012C6E
    ldr r0, [r0]                         @ 08012C70  r0 = ca_x_k (u32)
    ldr r1, =v_20007F78                  @ 08012C72
    ldr r1, [r1]                         @ 08012C74  r1 = ca_x_km1 (u32)
    subs r0, r0, r1                      @ 08012C76  r0 = ca_x_k - ca_x_km1
    ldr r1, =v_20007F68                  @ 08012C78
    str r0, [r1]                         @ 08012C7A  ca_delta (u32) = (ca_x_k - ca_x_km1)
    ldr r0, =v_20007F64                  @ 08012C7C
    ldr r8, [r0]                         @ 08012C7E  r8 = ca_base (u32)
    ldr r0, =v_20007F68                  @ 08012C82
    ldr r0, [r0]                         @ 08012C84  r0 = ca_delta (u32)
    bl fn_08012F60                       @ 08012C86  RT: float32 = (int32)r0
    ldr r1, =v_20007F94                  @ 08012C8A
    ldr r1, [r1]                         @ 08012C8C  r1 = ca_t (u32)
    bl fn_08013090                       @ 08012C8E  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 08012C92  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 08012C96
    ldr r3, =0x3FE00000                  @ 08012C98  0x3FE00000:0 = 0.5 (double), the rounding term of the RND() sequence
    bl fn_080131B8                       @ 08012C9A  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 08012C9E  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, r8                      @ 08012CA2  r0 = r0 + ca_base
    ldr r1, =v_20007F5C                  @ 08012CA6
    str r0, [r1]                         @ 08012CA8  ca_p1 (u32) = (r0 + ca_base)
    ldr r0, =v_20007F64                  @ 08012CAA
    ldr r1, =v_20007F80                  @ 08012CAC
    ldr r1, [r1]                         @ 08012CAE  r1 = ca_y_km1 (u32)
    str r1, [r0]                         @ 08012CB0  ca_base (u32) = ca_y_km1
    ldr r0, =v_20007F7C                  @ 08012CB2
    ldr r0, [r0]                         @ 08012CB4  r0 = ca_y_k (u32)
    ldr r1, =v_20007F80                  @ 08012CB6
    ldr r1, [r1]                         @ 08012CB8  r1 = ca_y_km1 (u32)
    subs r0, r0, r1                      @ 08012CBA  r0 = ca_y_k - ca_y_km1
    ldr r1, =v_20007F68                  @ 08012CBC
    str r0, [r1]                         @ 08012CBE  ca_delta (u32) = (ca_y_k - ca_y_km1)
    ldr r0, =v_20007F64                  @ 08012CC0
    ldr r8, [r0]                         @ 08012CC2  r8 = ca_base (u32)
    ldr r0, =v_20007F68                  @ 08012CC6
    ldr r0, [r0]                         @ 08012CC8  r0 = ca_delta (u32)
    bl fn_08012F60                       @ 08012CCA  RT: float32 = (int32)r0
    ldr r1, =v_20007F94                  @ 08012CCE
    ldr r1, [r1]                         @ 08012CD0  r1 = ca_t (u32)
    bl fn_08013090                       @ 08012CD2  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 08012CD6  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 08012CDA
    ldr r3, =0x3FE00000                  @ 08012CDC  0x3FE00000:0 = 0.5 (double), the rounding term of the RND() sequence
    bl fn_080131B8                       @ 08012CDE  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 08012CE2  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, r8                      @ 08012CE6  r0 = r0 + ca_base
    ldr r1, =v_20007F60                  @ 08012CEA
    str r0, [r1]                         @ 08012CEC  ca_p2 (u32) = (r0 + ca_base)
    @ F < 20001: A = P1 * w2 / 100, B = P2 * w3 / 100; else A = w2 + P1 * (w0 - w2) / 100, B = w3 + P2 * (w1 - w3) / 100
    movw r0, #0x4e21                     @ 08012CEE  = 20001
    cmp r7, r0                           @ 08012CF2
    blt .Lmac_corr_acv01_08012D34        @ 08012CF4  if F < (signed) 20001
    ldr r0, =v_20007F58                  @ 08012CF6
    ldr r0, [r0]                         @ 08012CF8  r0 = ca_d0 (u32)
    ldr r1, =v_20007F5C                  @ 08012CFA
    ldr r1, [r1]                         @ 08012CFC  r1 = ca_p1 (u32)
    muls r0, r1, r0                      @ 08012CFE  r0 = ca_p1 * ca_d0
    movs r1, #0x64                       @ 08012D00  = 100
    sdiv r0, r0, r1                      @ 08012D02  r0 = (ca_p1 * ca_d0) / 100
    ldr r1, =v_20007F84                  @ 08012D06
    str r0, [r1]                         @ 08012D08  ca_a (u32) = ((ca_p1 * ca_d0) / 100)
    ldr r0, =v_20007F84                  @ 08012D0A
    ldr r0, [r0]                         @ 08012D0C  r0 = ca_a (u32)
    adds r0, r5, r0                      @ 08012D0E  r0 = r5 + ca_a
    ldr r1, =v_20007F84                  @ 08012D10
    str r0, [r1]                         @ 08012D12  ca_a (u32) = (r5 + ca_a)
    ldr r0, =v_20007F54                  @ 08012D14
    ldr r0, [r0]                         @ 08012D16  r0 = ca_d1 (u32)
    ldr r1, =v_20007F60                  @ 08012D18
    ldr r1, [r1]                         @ 08012D1A  r1 = ca_p2 (u32)
    muls r0, r1, r0                      @ 08012D1C  r0 = ca_p2 * ca_d1
    movs r1, #0x64                       @ 08012D1E  = 100
    sdiv r0, r0, r1                      @ 08012D20  r0 = (ca_p2 * ca_d1) / 100
    ldr r1, =v_20007F88                  @ 08012D24
    str r0, [r1]                         @ 08012D26  ca_b (u32) = ((ca_p2 * ca_d1) / 100)
    ldr r0, =v_20007F88                  @ 08012D28
    ldr r0, [r0]                         @ 08012D2A  r0 = ca_b (u32)
    adds r0, r6, r0                      @ 08012D2C  r0 = w3 + ca_b
    ldr r1, =v_20007F88                  @ 08012D2E
    str r0, [r1]                         @ 08012D30  ca_b (u32) = (w3 + ca_b)
    b .Lmac_corr_acv01_08012D58          @ 08012D32
    .ltorg
.Lmac_corr_acv01_08012D34:   @ branch target from 08012CF4
    ldr r0, =v_20007F5C                  @ 08012D34
    ldr r0, [r0]                         @ 08012D36  r0 = ca_p1 (u32)
    mul r0, r0, r5                       @ 08012D38  r0 = ca_p1 * r5
    movs r1, #0x64                       @ 08012D3C  = 100
    sdiv r0, r0, r1                      @ 08012D3E  r0 = (ca_p1 * r5) / 100
    ldr r1, =v_20007F84                  @ 08012D42
    str r0, [r1]                         @ 08012D44  ca_a (u32) = ((ca_p1 * r5) / 100)
    ldr r0, =v_20007F60                  @ 08012D46
    ldr r0, [r0]                         @ 08012D48  r0 = ca_p2 (u32)
    mul r0, r0, r6                       @ 08012D4A  r0 = ca_p2 * w3
    movs r1, #0x64                       @ 08012D4E  = 100
    sdiv r0, r0, r1                      @ 08012D50  r0 = (ca_p2 * w3) / 100
    ldr r1, =v_20007F88                  @ 08012D54
    str r0, [r1]                         @ 08012D56  ca_b (u32) = ((ca_p2 * w3) / 100)
.Lmac_corr_acv01_08012D58:   @ branch target from 08012D32
    @ L = w2 + 5000
    add r0, r5, #0x1300                  @ 08012D58  + 5000 (0x1388)
    adds r0, #0x88                       @ 08012D5C  r0 = (r5 + 0x1300) + 0x88
    ldr r1, =v_20007F70                  @ 08012D5E
    str r0, [r1]                         @ 08012D60  ca_l (u32) = ((r5 + 0x1300) + 0x88)
    ldr r0, =v_20007F70                  @ 08012D62
    ldr r0, [r0]                         @ 08012D64  r0 = ca_l (u32)
    cmp r0, r4                           @ 08012D66
    @ L < D: pct = (D - L) / (50000 - L) * 100, result = B - ((B - A) - pct * (B - A) / 100); else pct = (L - D) / L * 100, result = A - pct * A / 100
    bge .Lmac_corr_acv01_08012DE2        @ 08012D68  if ca_l >= (signed) r4
    movs r0, r4                          @ 08012D6A
    bl fn_08012F60                       @ 08012D6C  RT: float32 = (int32)r0
    movs r4, r0                          @ 08012D70
    ldr r0, =v_20007F70                  @ 08012D72
    ldr r0, [r0]                         @ 08012D74  r0 = ca_l (u32)
    bl fn_08012F60                       @ 08012D76  RT: float32 = (int32)r0
    movs r1, r0                          @ 08012D7A
    movs r0, r4                          @ 08012D7C
    bl fn_080133B4                       @ 08012D7E  RT: float32 r0 = r0 - r1
    movs r4, r0                          @ 08012D82
    ldr r0, =v_20007F70                  @ 08012D84
    ldr r0, [r0]                         @ 08012D86  r0 = ca_l (u32)
    bl fn_08012F60                       @ 08012D88  RT: float32 = (int32)r0
    movs r1, r0                          @ 08012D8C
    ldr r0, =0x47435000                  @ 08012D8E  0x47435000 = 50000.0f
    bl fn_080133B4                       @ 08012D90  RT: float32 r0 = r0 - r1
    movs r1, r0                          @ 08012D94
    movs r0, r4                          @ 08012D96
    bl fn_08012F94                       @ 08012D98  RT: float32 r0 = r0 / r1
    ldr r1, =0x42C80000                  @ 08012D9C  0x42C80000 = 100.0f
    bl fn_08013090                       @ 08012D9E  RT: float32 r0 = r0 * r1
    bl fn_08013370                       @ 08012DA2  RT: int32 r0 = (int)float32 r0 (truncating)
    ldr r1, =v_20007F6C                  @ 08012DA6
    str r0, [r1]                         @ 08012DA8  ca_pct (u32) = r0
    ldr r0, =v_20007F88                  @ 08012DAA
    ldr r0, [r0]                         @ 08012DAC  r0 = ca_b (u32)
    ldr r1, =v_20007F84                  @ 08012DAE
    ldr r1, [r1]                         @ 08012DB0  r1 = ca_a (u32)
    subs r0, r0, r1                      @ 08012DB2  r0 = ca_b - ca_a
    ldr r1, =v_20007F90                  @ 08012DB4
    str r0, [r1]                         @ 08012DB6  ca_ba (u32) = (ca_b - ca_a)
    ldr r0, =v_20007F90                  @ 08012DB8
    ldr r0, [r0]                         @ 08012DBA  r0 = ca_ba (u32)
    ldr r1, =v_20007F90                  @ 08012DBC
    ldr r1, [r1]                         @ 08012DBE  r1 = ca_ba (u32)
    ldr r2, =v_20007F6C                  @ 08012DC0
    ldr r2, [r2]                         @ 08012DC2  r2 = ca_pct (u32)
    muls r1, r2, r1                      @ 08012DC4  r1 = ca_pct * ca_ba
    movs r2, #0x64                       @ 08012DC6  = 100
    sdiv r1, r1, r2                      @ 08012DC8  r1 = (ca_pct * ca_ba) / 100
    subs r0, r0, r1                      @ 08012DCC  r0 = ca_ba - ((ca_pct * ca_ba) / 100)
    ldr r1, =v_20007F8C                  @ 08012DCE
    str r0, [r1]                         @ 08012DD0  ca_out (u32) = (ca_ba - ((ca_pct * ca_ba) / 100))
    ldr r0, =v_20007F88                  @ 08012DD2
    ldr r0, [r0]                         @ 08012DD4  r0 = ca_b (u32)
    ldr r1, =v_20007F8C                  @ 08012DD6
    ldr r1, [r1]                         @ 08012DD8  r1 = ca_out (u32)
    subs r0, r0, r1                      @ 08012DDA  r0 = ca_b - ca_out
    ldr r1, =v_20007F8C                  @ 08012DDC
    str r0, [r1]                         @ 08012DDE  ca_out (u32) = (ca_b - ca_out)
    b .Lmac_corr_acv01_08012E3C          @ 08012DE0
.Lmac_corr_acv01_08012DE2:   @ branch target from 08012D68
    ldr r0, =v_20007F70                  @ 08012DE2
    ldr r0, [r0]                         @ 08012DE4  r0 = ca_l (u32)
    bl fn_08012F60                       @ 08012DE6  RT: float32 = (int32)r0
    movs r5, r0                          @ 08012DEA
    movs r0, r4                          @ 08012DEC
    bl fn_08012F60                       @ 08012DEE  RT: float32 = (int32)r0
    movs r1, r0                          @ 08012DF2
    movs r0, r5                          @ 08012DF4
    bl fn_080133B4                       @ 08012DF6  RT: float32 r0 = r0 - r1
    movs r4, r0                          @ 08012DFA
    ldr r0, =v_20007F70                  @ 08012DFC
    ldr r0, [r0]                         @ 08012DFE  r0 = ca_l (u32)
    bl fn_08012F60                       @ 08012E00  RT: float32 = (int32)r0
    movs r1, r0                          @ 08012E04
    movs r0, r4                          @ 08012E06
    bl fn_08012F94                       @ 08012E08  RT: float32 r0 = r0 / r1
    ldr r1, =0x42C80000                  @ 08012E0C  0x42C80000 = 100.0f
    bl fn_08013090                       @ 08012E0E  RT: float32 r0 = r0 * r1
    bl fn_08013370                       @ 08012E12  RT: int32 r0 = (int)float32 r0 (truncating)
    ldr r1, =v_20007F6C                  @ 08012E16
    str r0, [r1]                         @ 08012E18  ca_pct (u32) = r0
    ldr r0, =v_20007F90                  @ 08012E1A
    ldr r1, =v_20007F84                  @ 08012E1C
    ldr r1, [r1]                         @ 08012E1E  r1 = ca_a (u32)
    str r1, [r0]                         @ 08012E20  ca_ba (u32) = ca_a
    ldr r0, =v_20007F90                  @ 08012E22
    ldr r0, [r0]                         @ 08012E24  r0 = ca_ba (u32)
    ldr r1, =v_20007F90                  @ 08012E26
    ldr r1, [r1]                         @ 08012E28  r1 = ca_ba (u32)
    ldr r2, =v_20007F6C                  @ 08012E2A
    ldr r2, [r2]                         @ 08012E2C  r2 = ca_pct (u32)
    muls r1, r2, r1                      @ 08012E2E  r1 = ca_pct * ca_ba
    movs r2, #0x64                       @ 08012E30  = 100
    sdiv r1, r1, r2                      @ 08012E32  r1 = (ca_pct * ca_ba) / 100
    subs r0, r0, r1                      @ 08012E36  r0 = ca_ba - ((ca_pct * ca_ba) / 100)
    ldr r1, =v_20007F8C                  @ 08012E38
    str r0, [r1]                         @ 08012E3A  ca_out (u32) = (ca_ba - ((ca_pct * ca_ba) / 100))
.Lmac_corr_acv01_08012E3C:   @ branch target from 08012DE0
    ldr r0, =v_20007F50                  @ 08012E3C
    ldr r1, =v_20007F8C                  @ 08012E3E
    ldr r1, [r1]                         @ 08012E40  r1 = ca_out (u32)
    str r1, [r0]                         @ 08012E42  ca_result (u32) = ca_out
    ldr r0, =v_20007F50                  @ 08012E44
    ldr r0, [r0]                         @ 08012E46  r0 = ca_result (u32)
    pop {r4, r5, r6, r7, r8, sb, sl, fp, pc} @ 08012E48
    .ltorg
ENDFUNC fn_080129EE
    .global mac_corr_acv01
    .set mac_corr_acv01, fn_080129EE

@ -----------------------------------------------------------------------------
@ fn_080070CC (mac_corr70) - extra correction CORR70 of ACV range 0 (used while marker 0x1F is not 0xA5): two curves over frequency,
@   blended by the count
@ Replaces : 0x080070CC FUN_080070cc (v2.05)
@ In       : r0 = D (count after the first correction)
@            r1 = stored frequency (0x20007D84)
@            r2 = frequency range fr
@ Out      : r0 = CORR70 (0 for D >= 57000 or F < 51 Hz)
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_0800742C)
@ Registers: r4 = D, r5 = fr, r6 = table index k, r7 = search index, r8 = stored frequency, sb = scratch
@ RAM      : reads  0x20007C8C c70_result, 0x20007C90 c70_f_hz, 0x20007C94 c70_c94, 0x20007C98 c70_c98,
@            0x20007C9C c70_span, 0x20007CA0 c70_delta, 0x20007CA4 c70_pct, 0x20007CA8 c70_ca8, 0x20007CAC c70_x_k,
@            0x20007CB0 c70_x_km1, 0x20007CB4 c70_y_k, 0x20007CB8 c70_y_km1, 0x20007CBC c70_t
@            writes 0x20007C8C c70_result, 0x20007C90 c70_f_hz, 0x20007C94 c70_c94, 0x20007C98 c70_c98,
@            0x20007C9C c70_span, 0x20007CA0 c70_delta, 0x20007CA4 c70_pct, 0x20007CA8 c70_ca8, 0x20007CAC c70_x_k,
@            0x20007CB0 c70_x_km1, 0x20007CB4 c70_y_k, 0x20007CB8 c70_y_km1, 0x20007CBC c70_t
@ Spec     : analysis/hy3131_modes_ac_current.md 5.4
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_080070CC
    push {r3, r4, r5, r6, r7, r8, sb, lr} @ 080070CC
    movs r4, r0                          @ 080070D0
    mov r8, r1                           @ 080070D2
    movs r5, r2                          @ 080070D4
    @ result 0
    movs r0, #0                          @ 080070D6
    ldr r1, =v_20007C8C                  @ 080070D8
    str r0, [r1]                         @ 080070DC  c70_result (u32) = 0
    @ D >= 57000 (0xDEA8): no correction
    movw r0, #0xdea8                     @ 080070DE  = 57000
    cmp r4, r0                           @ 080070E2
    blt .Lmac_corr70_080070EE            @ 080070E4  if D < (signed) 57000
    ldr r0, =v_20007C8C                  @ 080070E6
    ldr r0, [r0]                         @ 080070EA  r0 = c70_result (u32)
    b .Lmac_corr70_0800741A              @ 080070EC
.Lmac_corr70_080070EE:   @ branch target from 080070E4
    @ F = frequency in Hz; F < 51: no correction
    mov r1, r8                           @ 080070EE
    movs r0, r5                          @ 080070F0
    uxtb r0, r0                          @ 080070F2
    bl fn_08012F28                       @ 080070F4  MFRQ: frequency in Hz from the stored value (r1) and its range (r0)
    ldr r1, =v_20007C90                  @ 080070F8
    str r0, [r1]                         @ 080070FC  c70_f_hz (u32) = r0
    ldr r0, =v_20007C90                  @ 080070FE
    ldr r0, [r0]                         @ 08007102  r0 = c70_f_hz (u32)
    cmp r0, #0x33                        @ 08007104
    bge .Lmac_corr70_08007110            @ 08007106  if c70_f_hz >= (signed) 51
    ldr r0, =v_20007C8C                  @ 08007108
    ldr r0, [r0]                         @ 0800710C  r0 = c70_result (u32)
    b .Lmac_corr70_0800741A              @ 0800710E
.Lmac_corr70_08007110:   @ branch target from 08007106
    @ k = first i in 0..16 with F <= FT[i] (FT = 0x08028C58, 17 entries 50 Hz..100 kHz), else 16
    movs r0, #0x10                       @ 08007110  = 16
    movs r6, r0                          @ 08007112
    movs r0, #0                          @ 08007114
    movs r7, r0                          @ 08007116
.Lmac_corr70_08007118:   @ branch target from 08007134
    cmp r7, #0x11                        @ 08007118
    bge .Lmac_corr70_08007136            @ 0800711A  if r7 >= (signed) 17
    ldr r0, =v205_tab_08028C58           @ 0800711C
    ldr r0, [r0, r7, lsl #2]             @ 08007120
    ldr r1, =v_20007C90                  @ 08007124
    ldr r1, [r1]                         @ 08007128  r1 = c70_f_hz (u32)
    cmp r0, r1                           @ 0800712A
    blt .Lmac_corr70_08007132            @ 0800712C  if r0 < (signed) c70_f_hz
    movs r6, r7                          @ 0800712E
    b .Lmac_corr70_08007136              @ 08007130
.Lmac_corr70_08007132:   @ branch target from 0800712C
    adds r7, r7, #1                      @ 08007132  r7 = r7 + 1
    b .Lmac_corr70_08007118              @ 08007134
.Lmac_corr70_08007136:   @ branch target from 0800711A, 08007130
    @ t = (F - FT[k-1]) / (FT[k] - FT[k-1]) as float32
    ldr r0, =v205_tab_08028C58           @ 08007136
    ldr r0, [r0, r6, lsl #2]             @ 0800713A
    ldr r1, =v_20007CAC                  @ 0800713E
    str r0, [r1]                         @ 08007142  c70_x_k (u32) = r0
    ldr r0, =v205_tab_08028C58           @ 08007144
    add r0, r0, r6, lsl #2               @ 08007148  r0 = r0 + (r6 << 2)
    ldr r0, [r0, #-0x4]                  @ 0800714C
    ldr r1, =v_20007CB0                  @ 08007150
    str r0, [r1]                         @ 08007154  c70_x_km1 (u32) = r0
    ldr r0, =v_20007CAC                  @ 08007156
    ldr r0, [r0]                         @ 0800715A  r0 = c70_x_k (u32)
    ldr r1, =v_20007CB0                  @ 0800715C
    ldr r1, [r1]                         @ 08007160  r1 = c70_x_km1 (u32)
    subs r0, r0, r1                      @ 08007162  r0 = c70_x_k - c70_x_km1
    ldr r1, =v_20007C9C                  @ 08007164
    str r0, [r1]                         @ 08007168  c70_span (u32) = (c70_x_k - c70_x_km1)
    ldr r0, =v_20007C90                  @ 0800716A
    ldr r0, [r0]                         @ 0800716E  r0 = c70_f_hz (u32)
    ldr r1, =v_20007CB0                  @ 08007170
    ldr r1, [r1]                         @ 08007174  r1 = c70_x_km1 (u32)
    subs r0, r0, r1                      @ 08007176  r0 = c70_f_hz - c70_x_km1
    ldr r1, =v_20007CA0                  @ 08007178
    str r0, [r1]                         @ 0800717C  c70_delta (u32) = (c70_f_hz - c70_x_km1)
    ldr r0, =v_20007CA0                  @ 0800717E
    ldr r0, [r0]                         @ 08007182  r0 = c70_delta (u32)
    bl fn_08012F60                       @ 08007184  RT: float32 = (int32)r0
    mov sb, r0                           @ 08007188
    ldr r0, =v_20007C9C                  @ 0800718A
    ldr r0, [r0]                         @ 0800718E  r0 = c70_span (u32)
    bl fn_08012F60                       @ 08007190  RT: float32 = (int32)r0
    movs r1, r0                          @ 08007194
    mov r0, sb                           @ 08007196
    bl fn_08012F94                       @ 08007198  RT: float32 r0 = r0 / r1
    ldr r1, =v_20007CBC                  @ 0800719C
    str r0, [r1]                         @ 080071A0  c70_t (u32) = r0
    @ D < 5001: C94 = 0, C98 = INTERP(row 1); otherwise C94 = INTERP(row 1), C98 = INTERP(row 2) (row 2 is 17 words further)
    movw r0, #0x1389                     @ 080071A2  = 5001
    cmp r4, r0                           @ 080071A6
    bge .Lmac_corr70_080071DC            @ 080071A8  if D >= (signed) 5001
    movs r0, #0                          @ 080071AA
    ldr r1, =v_20007CAC                  @ 080071AC
    str r0, [r1]                         @ 080071B0  c70_x_k (u32) = 0
    movs r0, #0                          @ 080071B2
    ldr r1, =v_20007CB0                  @ 080071B4
    str r0, [r1]                         @ 080071B8  c70_x_km1 (u32) = 0
    ldr r0, =v205_tab_08028648           @ 080071BA
    ldr r0, [r0, r6, lsl #2]             @ 080071BE
    ldr r1, =v_20007CB4                  @ 080071C2
    str r0, [r1]                         @ 080071C6  c70_y_k (u32) = r0
    ldr r0, =v205_tab_08028648           @ 080071C8
    add r0, r0, r6, lsl #2               @ 080071CC  r0 = r0 + (r6 << 2)
    ldr r0, [r0, #-0x4]                  @ 080071D0
    ldr r1, =v_20007CB8                  @ 080071D4
    str r0, [r1]                         @ 080071D8  c70_y_km1 (u32) = r0
    b .Lmac_corr70_0800721C              @ 080071DA
.Lmac_corr70_080071DC:   @ branch target from 080071A8
    ldr r0, =v205_tab_08028648           @ 080071DC
    ldr r0, [r0, r6, lsl #2]             @ 080071E0
    ldr r1, =v_20007CAC                  @ 080071E4
    str r0, [r1]                         @ 080071E8  c70_x_k (u32) = r0
    ldr r0, =v205_tab_08028648           @ 080071EA
    add r0, r0, r6, lsl #2               @ 080071EE  r0 = r0 + (r6 << 2)
    ldr r0, [r0, #-0x4]                  @ 080071F2
    ldr r1, =v_20007CB0                  @ 080071F6
    str r0, [r1]                         @ 080071FA  c70_x_km1 (u32) = r0
    ldr r0, =v205_tab_08028648           @ 080071FC
    add r0, r0, r6, lsl #2               @ 08007200  r0 = r0 + (r6 << 2)
    ldr r0, [r0, #0x44]                  @ 08007204
    ldr r1, =v_20007CB4                  @ 08007206
    str r0, [r1]                         @ 0800720A  c70_y_k (u32) = r0
    ldr r0, =v205_tab_08028648           @ 0800720C
    add r0, r0, r6, lsl #2               @ 08007210  r0 = r0 + (r6 << 2)
    ldr r0, [r0, #0x40]                  @ 08007214
    ldr r1, =v_20007CB8                  @ 08007216
    str r0, [r1]                         @ 0800721A  c70_y_km1 (u32) = r0
.Lmac_corr70_0800721C:   @ branch target from 080071DA
    ldr r0, =v_20007CB0                  @ 0800721C
    ldr r0, [r0]                         @ 08007220  r0 = c70_x_km1 (u32)
    ldr r1, =v_20007C9C                  @ 08007222
    str r0, [r1]                         @ 08007226  c70_span (u32) = c70_x_km1
    ldr r0, =v_20007CAC                  @ 08007228
    ldr r0, [r0]                         @ 0800722C  r0 = c70_x_k (u32)
    ldr r1, =v_20007CB0                  @ 0800722E
    ldr r1, [r1]                         @ 08007232  r1 = c70_x_km1 (u32)
    subs r0, r0, r1                      @ 08007234  r0 = c70_x_k - c70_x_km1
    ldr r1, =v_20007CA0                  @ 08007236
    str r0, [r1]                         @ 0800723A  c70_delta (u32) = (c70_x_k - c70_x_km1)
    ldr r0, =v_20007C9C                  @ 0800723C
    ldr sb, [r0]                         @ 08007240  sb = c70_span (u32)
    ldr r0, =v_20007CA0                  @ 08007244
    ldr r0, [r0]                         @ 08007248  r0 = c70_delta (u32)
    bl fn_08012F60                       @ 0800724A  RT: float32 = (int32)r0
    ldr r1, =v_20007CBC                  @ 0800724E
    ldr r1, [r1]                         @ 08007252  r1 = c70_t (u32)
    bl fn_08013090                       @ 08007254  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 08007258  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 0800725C
    ldr r3, =0x3FE00000                  @ 0800725E  0x3FE00000:0 = 0.5 (double), the rounding term of the RND() sequence
    bl fn_080131B8                       @ 08007262  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 08007266  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, sb                      @ 0800726A  r0 = r0 + c70_span
    ldr r1, =v_20007C94                  @ 0800726E
    str r0, [r1]                         @ 08007272  c70_c94 (u32) = (r0 + c70_span)
    ldr r0, =v_20007CB8                  @ 08007274
    ldr r0, [r0]                         @ 08007278  r0 = c70_y_km1 (u32)
    ldr r1, =v_20007C9C                  @ 0800727A
    str r0, [r1]                         @ 0800727E  c70_span (u32) = c70_y_km1
    ldr r0, =v_20007CB4                  @ 08007280
    ldr r0, [r0]                         @ 08007284  r0 = c70_y_k (u32)
    ldr r1, =v_20007CB8                  @ 08007286
    ldr r1, [r1]                         @ 0800728A  r1 = c70_y_km1 (u32)
    subs r0, r0, r1                      @ 0800728C  r0 = c70_y_k - c70_y_km1
    ldr r1, =v_20007CA0                  @ 0800728E
    str r0, [r1]                         @ 08007292  c70_delta (u32) = (c70_y_k - c70_y_km1)
    ldr r0, =v_20007C9C                  @ 08007294
    ldr sb, [r0]                         @ 08007298  sb = c70_span (u32)
    ldr r0, =v_20007CA0                  @ 0800729C
    ldr r0, [r0]                         @ 080072A0  r0 = c70_delta (u32)
    bl fn_08012F60                       @ 080072A2  RT: float32 = (int32)r0
    ldr r1, =v_20007CBC                  @ 080072A6
    ldr r1, [r1]                         @ 080072AA  r1 = c70_t (u32)
    bl fn_08013090                       @ 080072AC  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 080072B0  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 080072B4
    ldr r3, =0x3FE00000                  @ 080072B6  0x3FE00000:0 = 0.5 (double), the rounding term of the RND() sequence
    bl fn_080131B8                       @ 080072BA  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 080072BE  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, sb                      @ 080072C2  r0 = r0 + c70_span
    ldr r1, =v_20007C98                  @ 080072C6
    str r0, [r1]                         @ 080072CA  c70_c98 (u32) = (r0 + c70_span)
    @ CA8 = C94 + 5000
    ldr r0, =v_20007C94                  @ 080072CC
    ldr r0, [r0]                         @ 080072D0  r0 = c70_c94 (u32)
    add r0, r0, #0x1300                  @ 080072D2  + 5000 (0x1300 + 0x88)
    adds r0, #0x88                       @ 080072D6  r0 = (c70_c94 + 0x1300) + 0x88
    ldr r1, =v_20007CA8                  @ 080072D8
    str r0, [r1]                         @ 080072DC  c70_ca8 (u32) = ((c70_c94 + 0x1300) + 0x88)
    @ CA8 < D: pct = (D - CA8) / (50000 - CA8) * 100; else pct = (CA8 - D) / CA8 * 100
    ldr r0, =v_20007CA8                  @ 080072DE
    ldr r0, [r0]                         @ 080072E2  r0 = c70_ca8 (u32)
    cmp r0, r4                           @ 080072E4
    bge .Lmac_corr70_0800737E            @ 080072E6  if c70_ca8 >= (signed) D
    movs r0, r4                          @ 080072E8
    bl fn_08012F60                       @ 080072EA  RT: float32 = (int32)r0
    mov sb, r0                           @ 080072EE
    ldr r0, =v_20007CA8                  @ 080072F0
    ldr r0, [r0]                         @ 080072F4  r0 = c70_ca8 (u32)
    bl fn_08012F60                       @ 080072F6  RT: float32 = (int32)r0
    movs r1, r0                          @ 080072FA
    mov r0, sb                           @ 080072FC
    bl fn_080133B4                       @ 080072FE  RT: float32 r0 = r0 - r1
    mov sb, r0                           @ 08007302
    ldr r0, =v_20007CA8                  @ 08007304
    ldr r0, [r0]                         @ 08007308  r0 = c70_ca8 (u32)
    bl fn_08012F60                       @ 0800730A  RT: float32 = (int32)r0
    movs r1, r0                          @ 0800730E
    ldr r0, =0x47435000                  @ 08007310  0x47435000 = 50000.0f
    bl fn_080133B4                       @ 08007314  RT: float32 r0 = r0 - r1
    movs r1, r0                          @ 08007318
    mov r0, sb                           @ 0800731A
    bl fn_08012F94                       @ 0800731C  RT: float32 r0 = r0 / r1
    ldr r1, =0x42C80000                  @ 08007320  0x42C80000 = 100.0f
    bl fn_08013090                       @ 08007324  RT: float32 r0 = r0 * r1
    bl fn_08013370                       @ 08007328  RT: int32 r0 = (int)float32 r0 (truncating)
    ldr r1, =v_20007CA4                  @ 0800732C
    str r0, [r1]                         @ 08007330  c70_pct (u32) = r0
    @ result = C98 - ((C98 - C94) - pct * (C98 - C94) / 100)
    ldr r0, =v_20007C98                  @ 08007332
    ldr r0, [r0]                         @ 08007336  r0 = c70_c98 (u32)
    ldr r1, =v_20007C94                  @ 08007338
    ldr r1, [r1]                         @ 0800733C  r1 = c70_c94 (u32)
    subs r0, r0, r1                      @ 0800733E  r0 = c70_c98 - c70_c94
    ldr r1, =v_20007CAC                  @ 08007340
    str r0, [r1]                         @ 08007344  c70_x_k (u32) = (c70_c98 - c70_c94)
    ldr r0, =v_20007CAC                  @ 08007346
    ldr r0, [r0]                         @ 0800734A  r0 = c70_x_k (u32)
    ldr r1, =v_20007CAC                  @ 0800734C
    ldr r1, [r1]                         @ 08007350  r1 = c70_x_k (u32)
    ldr r2, =v_20007CA4                  @ 08007352
    ldr r2, [r2]                         @ 08007356  r2 = c70_pct (u32)
    muls r1, r2, r1                      @ 08007358  r1 = c70_pct * c70_x_k
    movs r2, #0x64                       @ 0800735A  = 100
    sdiv r1, r1, r2                      @ 0800735C  r1 = (c70_pct * c70_x_k) / 100
    subs r0, r0, r1                      @ 08007360  r0 = c70_x_k - ((c70_pct * c70_x_k) / 100)
    ldr r1, =v_20007CB0                  @ 08007362
    str r0, [r1]                         @ 08007366  c70_x_km1 (u32) = (c70_x_k - ((c70_pct * c70_x_k) / 100))
    ldr r0, =v_20007C98                  @ 08007368
    ldr r0, [r0]                         @ 0800736C  r0 = c70_c98 (u32)
    ldr r1, =v_20007CB0                  @ 0800736E
    ldr r1, [r1]                         @ 08007372  r1 = c70_x_km1 (u32)
    subs r0, r0, r1                      @ 08007374  r0 = c70_c98 - c70_x_km1
    ldr r1, =v_20007CB4                  @ 08007376
    str r0, [r1]                         @ 0800737A  c70_y_k (u32) = (c70_c98 - c70_x_km1)
    b .Lmac_corr70_08007408              @ 0800737C
    .ltorg
.Lmac_corr70_0800737E:   @ branch target from 080072E6
    ldr r0, =v_20007CA8                  @ 0800737E
    ldr r0, [r0]                         @ 08007382  r0 = c70_ca8 (u32)
    bl fn_08012F60                       @ 08007384  RT: float32 = (int32)r0
    mov sb, r0                           @ 08007388
    movs r0, r4                          @ 0800738A
    bl fn_08012F60                       @ 0800738C  RT: float32 = (int32)r0
    movs r1, r0                          @ 08007390
    mov r0, sb                           @ 08007392
    bl fn_080133B4                       @ 08007394  RT: float32 r0 = r0 - r1
    mov sb, r0                           @ 08007398
    ldr r0, =v_20007CA8                  @ 0800739A
    ldr r0, [r0]                         @ 0800739E  r0 = c70_ca8 (u32)
    bl fn_08012F60                       @ 080073A0  RT: float32 = (int32)r0
    movs r1, r0                          @ 080073A4
    mov r0, sb                           @ 080073A6
    bl fn_08012F94                       @ 080073A8  RT: float32 r0 = r0 / r1
    ldr r1, =0x42C80000                  @ 080073AC  0x42C80000 = 100.0f
    bl fn_08013090                       @ 080073B0  RT: float32 r0 = r0 * r1
    bl fn_08013370                       @ 080073B4  RT: int32 r0 = (int)float32 r0 (truncating)
    ldr r1, =v_20007CA4                  @ 080073B8
    str r0, [r1]                         @ 080073BC  c70_pct (u32) = r0
    ldr r0, =v_20007C98                  @ 080073BE
    ldr r0, [r0]                         @ 080073C2  r0 = c70_c98 (u32)
    ldr r1, =v_20007C94                  @ 080073C4
    ldr r1, [r1]                         @ 080073C8  r1 = c70_c94 (u32)
    subs r0, r0, r1                      @ 080073CA  r0 = c70_c98 - c70_c94
    ldr r1, =v_20007CAC                  @ 080073CC
    str r0, [r1]                         @ 080073D0  c70_x_k (u32) = (c70_c98 - c70_c94)
    ldr r0, =v_20007CAC                  @ 080073D2
    ldr r0, [r0]                         @ 080073D6  r0 = c70_x_k (u32)
    ldr r1, =v_20007CAC                  @ 080073D8
    ldr r1, [r1]                         @ 080073DC  r1 = c70_x_k (u32)
    ldr r2, =v_20007CA4                  @ 080073DE
    ldr r2, [r2]                         @ 080073E2  r2 = c70_pct (u32)
    muls r1, r2, r1                      @ 080073E4  r1 = c70_pct * c70_x_k
    movs r2, #0x64                       @ 080073E6  = 100
    sdiv r1, r1, r2                      @ 080073E8  r1 = (c70_pct * c70_x_k) / 100
    subs r0, r0, r1                      @ 080073EC  r0 = c70_x_k - ((c70_pct * c70_x_k) / 100)
    ldr r1, =v_20007CB0                  @ 080073EE
    str r0, [r1]                         @ 080073F2  c70_x_km1 (u32) = (c70_x_k - ((c70_pct * c70_x_k) / 100))
    ldr r0, =v_20007C98                  @ 080073F4
    ldr r0, [r0]                         @ 080073F8  r0 = c70_c98 (u32)
    ldr r1, =v_20007CB0                  @ 080073FA
    ldr r1, [r1]                         @ 080073FE  r1 = c70_x_km1 (u32)
    subs r0, r0, r1                      @ 08007400  r0 = c70_c98 - c70_x_km1
    ldr r1, =v_20007CB4                  @ 08007402
    str r0, [r1]                         @ 08007406  c70_y_k (u32) = (c70_c98 - c70_x_km1)
.Lmac_corr70_08007408:   @ branch target from 0800737C
    ldr r0, =v_20007CB4                  @ 08007408
    ldr r0, [r0]                         @ 0800740C  r0 = c70_y_k (u32)
    ldr r1, =v_20007C8C                  @ 0800740E
    str r0, [r1]                         @ 08007412  c70_result (u32) = c70_y_k
    ldr r0, =v_20007C8C                  @ 08007414
    ldr r0, [r0]                         @ 08007418  r0 = c70_result (u32)
.Lmac_corr70_0800741A:   @ branch target from 080070EC, 0800710E
    pop {r1, r4, r5, r6, r7, r8, sb, pc} @ 0800741A
    .ltorg
ENDFUNC fn_080070CC
    .global mac_corr70
    .set mac_corr70, fn_080070CC

