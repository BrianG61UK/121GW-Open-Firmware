@ =============================================================================
@ autorange.s - AR: the v2.05 auto-range decision and the OHM direction guard
@
@ Replaces the v2.05 functions autorange_step 0x0800DE24 and FUN_0800E2A0 (DESIGN.md 6.12, Appendix A MODE).
@ Both loop modes use this code once per new mean; the production fast path is in arfast.s.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "ar.inc"

    .section .text.ar.autorange, "ax", %progbits

@ -----------------------------------------------------------------------------
@ autorange_step - decide on a range change from the new smoothed reading (v2.05 algorithm)
@ Replaces : 0x0800DE24 autorange_step (v2.05)
@ In       : ar_reading (0x20007D64, signed display counts), ar_full_scale (0x20007D60), meter_mode, meter_range,
@            range_manual, minmax_state, hold_active, hold_stage2, range_count, mode_settle (0x20000238),
@            ar_cal_mode (0x2000808A), ar_ol_latch (0x200080F8)
@ Out      : meter_range and ar_range_req (0x2000804B) when the range changes; ar_overload (0x20008046), ar_negative
@            (0x20008045), ar_blank (0x2000805C), ar_ol_latch, mode_settle counted down
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main (FUNC fn_0800DCFC, loop step 2, once per new mean 0x2000805D; both loop modes)
@ RAM      : see ar.inc; IMP-45: ah_block_down (.Lar_under) reads the CAP anti-hunting state and may take its lock
@ Spec     : analysis/autorange_and_scheduler.md 2.2 (decision), 2.3
@            Thresholds: up when |D| > U with U = FS + FS/10 (FS + FS/12 while the previous result was an overload,
@            FS in DIODE); down when |D| < L with L = FS/10 (FS/100 in CAP range 5, 5 * FS/10 in ACA / DCA range 2).
@            One range per decision.  The production fast path (ar_sample) uses the same thresholds.
@ -----------------------------------------------------------------------------
FUNC autorange_step
    .global ar_step
    .thumb_set ar_step, autorange_step

@ r4 = |reading|, r5 = U, r6 = L during the decision (see below)
    push {r4, r5, r6, lr}               @ 0800DE24
        bl ar_result_seen                     @ OF-32: first real result of FREQ / PULSE / DUTY / BEEP releases the main digits
        bl ar_decision_pending                @ IMP-01: ar_sample has changed the range and its apply has not run yet: the
        cmp r0, #0                            @ reading belongs to the old range, so no decision is taken (v2.05 never has
        bne .Lar_end                          @ this state: it serves its own request in the pass that sets it)

@ CAP with a manual range and an overload: keep it (a manual timeout overload), clear the settle count and blank
    ldr r0, =meter_mode                 @ 0800DE26
    ldrb r0, [r0]                       @ 0800DE2A
    cmp r0, #0xC                        @ 0800DE2C mode 12 CAP
    bne .Lar_0800DE52                   @ 0800DE2E
    ldr r0, =range_manual               @ 0800DE30
    ldrb r0, [r0]                       @ 0800DE34
    ldr r1, =ar_overload                @ 0800DE36
    ldrb r1, [r1]                       @ 0800DE3A
    tst r0, r1                          @ 0800DE3C
    beq .Lar_0800DE52                   @ 0800DE3E
    movs r0, #0                         @ 0800DE40
    ldr r1, =ar_settle                  @ 0800DE42
    strb r0, [r1]                       @ 0800DE46
    movs r0, #0                         @ 0800DE48
    ldr r1, =ar_blank                   @ 0800DE4A
    strb r0, [r1]                       @ 0800DE4E
    b .Lar_end                          @ 0800DE50

@ the overload flag is cleared at each result, except in FREQ, PULSE, DUTY and the VA modes where other code owns it
@ reached from 0800DE2E bne (not equal / non-zero) after cmp r0, #0xC
@              and from 0800DE3E beq (equal / zero) after tst r0, r1
.Lar_0800DE52:
    ldr r0, =meter_mode                 @ 0800DE52
    ldrb r0, [r0]                       @ 0800DE56
    cmp r0, #6                          @ 0800DE58 mode 6 FREQ
    beq .Lar_0800DEB4                   @ 0800DE5A
    ldr r0, =meter_mode                 @ 0800DE5C
    ldrb r0, [r0]                       @ 0800DE60
    cmp r0, #7                          @ 0800DE62 mode 7 PULSE
    beq .Lar_0800DEB4                   @ 0800DE64
    ldr r0, =meter_mode                 @ 0800DE66
    ldrb r0, [r0]                       @ 0800DE6A
    cmp r0, #8                          @ 0800DE6C mode 8 DUTY
    beq .Lar_0800DEB4                   @ 0800DE6E
    ldr r0, =meter_mode                 @ 0800DE70
    ldrb r0, [r0]                       @ 0800DE74
    cmp r0, #0xD                        @ 0800DE76 mode 13 uVA
    beq .Lar_0800DEB4                   @ 0800DE78
    ldr r0, =meter_mode                 @ 0800DE7A
    ldrb r0, [r0]                       @ 0800DE7E
    cmp r0, #0xE                        @ 0800DE80 mode 14 mVA
    beq .Lar_0800DEB4                   @ 0800DE82
    ldr r0, =meter_mode                 @ 0800DE84
    ldrb r0, [r0]                       @ 0800DE88
    cmp r0, #0xF                        @ 0800DE8A mode 15 VA
    beq .Lar_0800DEB4                   @ 0800DE8C
    ldr r0, =meter_mode                 @ 0800DE8E
    ldrb r0, [r0]                       @ 0800DE92
    cmp r0, #0x16                       @ 0800DE94 mode 22 DCuVA
    beq .Lar_0800DEB4                   @ 0800DE96
    ldr r0, =meter_mode                 @ 0800DE98
    ldrb r0, [r0]                       @ 0800DE9C
    cmp r0, #0x17                       @ 0800DE9E mode 23 DCmVA
    beq .Lar_0800DEB4                   @ 0800DEA0
    ldr r0, =meter_mode                 @ 0800DEA2
    ldrb r0, [r0]                       @ 0800DEA6
    cmp r0, #0x18                       @ 0800DEA8 mode 24 DCVA
    beq .Lar_0800DEB4                   @ 0800DEAA
    movs r0, #0                         @ 0800DEAC
    ldr r1, =ar_overload                @ 0800DEAE
    strb r0, [r1]                       @ 0800DEB2

@ settle count running: count it down, clear the overload latch, blank the main digits, no decision
@ reached from 0800DE5A beq (equal / zero) after cmp r0, #6
@              and from 0800DE64 beq (equal / zero) after cmp r0, #7
@              and from 0800DE6E beq (equal / zero) after cmp r0, #8
@              ... and 6 more
.Lar_0800DEB4:
    ldr r0, =ar_settle                  @ 0800DEB4
    ldrb r0, [r0]                       @ 0800DEB8
    cmp r0, #0                          @ 0800DEBA
    beq .Lar_0800DEDE                   @ 0800DEBC
    ldr r0, =ar_settle                  @ 0800DEBE
    ldrb r0, [r0]                       @ 0800DEC2
    subs r0, r0, #1                     @ 0800DEC4
    ldr r1, =ar_settle                  @ 0800DEC6
    strb r0, [r1]                       @ 0800DECA
    movs r0, #0                         @ 0800DECC
    ldr r1, =ar_ol_latch                @ 0800DECE
    strb r0, [r1]                       @ 0800DED2
    movs r0, #1                         @ 0800DED4
    ldr r1, =ar_blank                   @ 0800DED6
    strb r0, [r1]                       @ 0800DEDA
    b .Lar_end                          @ 0800DEDC

@ settle done: unblank.  Calibration mode: no ranging (latch cleared).  VA modes: no ranging here
@ reached from 0800DEBC beq (equal / zero) after cmp r0, #0
.Lar_0800DEDE:
    movs r0, #0                         @ 0800DEDE
    ldr r1, =ar_blank                   @ 0800DEE0
    strb r0, [r1]                       @ 0800DEE4
    ldr r0, =ar_cal_mode                @ 0800DEE6
    ldrb r0, [r0]                       @ 0800DEEA
    cmp r0, #0                          @ 0800DEEC
    beq .Lar_0800DEFA                   @ 0800DEEE
    movs r0, #0                         @ 0800DEF0
    ldr r1, =ar_ol_latch                @ 0800DEF2
    strb r0, [r1]                       @ 0800DEF6
    b .Lar_end                          @ 0800DEF8
@ reached from 0800DEEE beq (equal / zero) after cmp r0, #0
.Lar_0800DEFA:
    ldr r0, =meter_mode                 @ 0800DEFA
    ldrb r0, [r0]                       @ 0800DEFE
    cmp r0, #0xD                        @ 0800DF00 mode 13 uVA
    beq .Lar_0800DF36                   @ 0800DF02
    ldr r0, =meter_mode                 @ 0800DF04
    ldrb r0, [r0]                       @ 0800DF08
    cmp r0, #0xE                        @ 0800DF0A mode 14 mVA
    beq .Lar_0800DF36                   @ 0800DF0C
    ldr r0, =meter_mode                 @ 0800DF0E
    ldrb r0, [r0]                       @ 0800DF12
    cmp r0, #0xF                        @ 0800DF14 mode 15 VA
    beq .Lar_0800DF36                   @ 0800DF16
    ldr r0, =meter_mode                 @ 0800DF18
    ldrb r0, [r0]                       @ 0800DF1C
    cmp r0, #0x16                       @ 0800DF1E mode 22 DCuVA
    beq .Lar_0800DF36                   @ 0800DF20
    ldr r0, =meter_mode                 @ 0800DF22
    ldrb r0, [r0]                       @ 0800DF26
    cmp r0, #0x17                       @ 0800DF28 mode 23 DCmVA
    beq .Lar_0800DF36                   @ 0800DF2A
    ldr r0, =meter_mode                 @ 0800DF2C
    ldrb r0, [r0]                       @ 0800DF30
    cmp r0, #0x18                       @ 0800DF32 mode 24 DCVA
    bne .Lar_0800DF38                   @ 0800DF34
@ reached from 0800DF02 beq (equal / zero) after cmp r0, #0xD
@              and from 0800DF0C beq (equal / zero) after cmp r0, #0xE
@              and from 0800DF16 beq (equal / zero) after cmp r0, #0xF
@              ... and 2 more
.Lar_0800DF36:
    b .Lar_end                          @ 0800DF36

@ FREQ, PULSE, DUTY choose their range in frequency_select_range: only the sign flag is cleared here
@ reached from 0800DF34 bne (not equal / non-zero) after cmp r0, #0x18
.Lar_0800DF38:
    ldr r0, =meter_mode                 @ 0800DF38
    ldrb r0, [r0]                       @ 0800DF3C
    cmp r0, #6                          @ 0800DF3E mode 6 FREQ
    beq .Lar_0800DF56                   @ 0800DF40
    ldr r0, =meter_mode                 @ 0800DF42
    ldrb r0, [r0]                       @ 0800DF46
    cmp r0, #7                          @ 0800DF48 mode 7 PULSE
    beq .Lar_0800DF56                   @ 0800DF4A
    ldr r0, =meter_mode                 @ 0800DF4C
    ldrb r0, [r0]                       @ 0800DF50
    cmp r0, #8                          @ 0800DF52 mode 8 DUTY
    bne .Lar_thresholds                 @ 0800DF54
@ reached from 0800DF40 beq (equal / zero) after cmp r0, #6
@              and from 0800DF4A beq (equal / zero) after cmp r0, #7
.Lar_0800DF56:
    movs r0, #0                         @ 0800DF56
    ldr r1, =ar_negative                @ 0800DF58
    strb r0, [r1]                       @ 0800DF5C
    b .Lar_end                          @ 0800DF5E

@ r5 = U: DIODE uses FS itself; others FS + FS/12 (latch set) or FS + FS/10
@ reached from 0800DF54 bne (not equal / non-zero) after cmp r0, #8
.Lar_thresholds:
    ldr r0, =meter_mode                 @ 0800DF60
    ldrb r0, [r0]                       @ 0800DF64
    cmp r0, #0xB                        @ 0800DF66 mode 11 DIODE
    bne .Lar_0800DF72                   @ 0800DF68
    ldr r0, =ar_full_scale              @ 0800DF6A
    ldr r0, [r0]                        @ 0800DF6C
    movs r5, r0                         @ 0800DF6E
    b .Lar_0800DFA2                     @ 0800DF70
@ reached from 0800DF68 bne (not equal / non-zero) after cmp r0, #0xB
.Lar_0800DF72:
    ldr r0, =ar_ol_latch                @ 0800DF72
    ldrb r0, [r0]                       @ 0800DF76
    cmp r0, #0                          @ 0800DF78
    beq .Lar_0800DF90                   @ 0800DF7A
    ldr r0, =ar_full_scale              @ 0800DF7C
    ldr r0, [r0]                        @ 0800DF7E
    ldr r1, =ar_full_scale              @ 0800DF80
    ldr r1, [r1]                        @ 0800DF82
    movs r2, #0xC                       @ 0800DF84
    udiv r1, r1, r2                     @ 0800DF86
    adds r0, r1, r0                     @ 0800DF8A
    movs r5, r0                         @ 0800DF8C
    b .Lar_0800DFA2                     @ 0800DF8E
@ reached from 0800DF7A beq (equal / zero) after cmp r0, #0
.Lar_0800DF90:
    ldr r0, =ar_full_scale              @ 0800DF90
    ldr r0, [r0]                        @ 0800DF92
    ldr r1, =ar_full_scale              @ 0800DF94
    ldr r1, [r1]                        @ 0800DF96
    movs r2, #0xA                       @ 0800DF98
    udiv r1, r1, r2                     @ 0800DF9A
    adds r0, r1, r0                     @ 0800DF9E
    movs r5, r0                         @ 0800DFA0

@ r6 = L: FS/100 for CAP range 5, FS/10 otherwise; times 5 for ACA / DCA (0x14, 0x15) at range 2
@ reached from 0800DF70 b (jump)
@              and from 0800DF8E b (jump)
.Lar_0800DFA2:
    ldr r0, =meter_mode                 @ 0800DFA2
    ldrb r0, [r0]                       @ 0800DFA6
    cmp r0, #0xC                        @ 0800DFA8 mode 12 CAP
    bne .Lar_0800DFC4                   @ 0800DFAA
    ldr r0, =meter_range                @ 0800DFAC
    ldrb r0, [r0]                       @ 0800DFB0
    cmp r0, #5                          @ 0800DFB2
    bne .Lar_0800DFC4                   @ 0800DFB4
    ldr r0, =ar_full_scale              @ 0800DFB6
    ldr r0, [r0]                        @ 0800DFB8
    movs r1, #0x64                      @ 0800DFBA
    udiv r0, r0, r1                     @ 0800DFBC
    movs r6, r0                         @ 0800DFC0
    b .Lar_0800DFD0                     @ 0800DFC2
    .ltorg
@ reached from 0800DFAA bne (not equal / non-zero) after cmp r0, #0xC
@              and from 0800DFB4 bne (not equal / non-zero) after cmp r0, #5
.Lar_0800DFC4:
    ldr r0, =ar_full_scale              @ 0800DFC4
    ldr r0, [r0]                        @ 0800DFC6
    movs r1, #0xA                       @ 0800DFC8
    udiv r0, r0, r1                     @ 0800DFCA
    movs r6, r0                         @ 0800DFCE
@ reached from 0800DFC2 b (jump)
.Lar_0800DFD0:
    ldr r0, =meter_mode                 @ 0800DFD0
    ldrb r0, [r0]                       @ 0800DFD4
    cmp r0, #0x14                       @ 0800DFD6 mode 20 ACA
    beq .Lar_0800DFE4                   @ 0800DFD8
    ldr r0, =meter_mode                 @ 0800DFDA
    ldrb r0, [r0]                       @ 0800DFDE
    cmp r0, #0x15                       @ 0800DFE0 mode 21 DCA
    bne .Lar_0800DFF2                   @ 0800DFE2
@ reached from 0800DFD8 beq (equal / zero) after cmp r0, #0x14
.Lar_0800DFE4:
    ldr r0, =meter_range                @ 0800DFE4
    ldrb r0, [r0]                       @ 0800DFE8
    cmp r0, #2                          @ 0800DFEA
    bne .Lar_0800DFF2                   @ 0800DFEC
    movs r0, #5                         @ 0800DFEE
    muls r6, r0, r6                     @ 0800DFF0

@ r4 = |reading|, ar_negative = (reading < 0)
@ reached from 0800DFE2 bne (not equal / non-zero) after cmp r0, #0x15
@              and from 0800DFEC bne (not equal / non-zero) after cmp r0, #2
.Lar_0800DFF2:
    ldr r0, =ar_reading                 @ 0800DFF2
    ldr r0, [r0]                        @ 0800DFF6
    cmp r0, #0                          @ 0800DFF8
    bpl .Lar_0800E010                   @ 0800DFFA
    ldr r0, =ar_reading                 @ 0800DFFC
    ldr r0, [r0]                        @ 0800E000
    rsbs r0, r0, #0                     @ 0800E002
    movs r4, r0                         @ 0800E004
    movs r0, #1                         @ 0800E006
    ldr r1, =ar_negative                @ 0800E008
    strb r0, [r1]                       @ 0800E00C
    b .Lar_allowed                      @ 0800E00E
@ reached from 0800DFFA bpl (positive or zero) after cmp r0, #0
.Lar_0800E010:
    ldr r0, =ar_reading                 @ 0800E010
    ldr r0, [r0]                        @ 0800E014
    movs r4, r0                         @ 0800E016
    movs r0, #0                         @ 0800E018
    ldr r1, =ar_negative                @ 0800E01A
    strb r0, [r1]                       @ 0800E01E

@ ranging is allowed when MIN/MAX is off, the range is not manual and the mode has two or more ranges
@ reached from 0800E00E b (jump)
.Lar_allowed:
    ldr r0, =minmax_state               @ 0800E020
    ldrb r0, [r0]                       @ 0800E024
    cmp r0, #0                          @ 0800E026
    bne .Lar_noranging                  @ 0800E028
    ldr r0, =range_manual               @ 0800E02A
    ldrb r0, [r0]                       @ 0800E02E
    cmp r0, #0                          @ 0800E030
    bne .Lar_noranging                  @ 0800E032
    ldr r0, =range_count                @ 0800E034
    ldr r1, =meter_mode                 @ 0800E038
    ldrb r1, [r1]                       @ 0800E03C
    ldrb r0, [r0, r1]                   @ 0800E03E
    cmp r0, #2                          @ 0800E040
    bge .Lar_ranging                    @ 0800E042

@ no ranging: TEMP takes the overload from the thermocouple state 0x200080AD (1 = open: OL, positive;
@ 2 = OL, negative); every other mode shows an overload when |D| > U
@ reached from 0800E028 bne (not equal / non-zero) after cmp r0, #0
@              and from 0800E032 bne (not equal / non-zero) after cmp r0, #0
.Lar_noranging:
    ldr r0, =meter_mode                 @ 0800E044
    ldrb r0, [r0]                       @ 0800E048
    cmp r0, #5                          @ 0800E04A mode 5 TEMP
    bne .Lar_0800E086                   @ 0800E04C
    ldr r0, =ar_tc_flag                 @ 0800E04E
    ldrb r0, [r0]                       @ 0800E052
    cmp r0, #1                          @ 0800E054
    bne .Lar_0800E06A                   @ 0800E056
    movs r0, #0                         @ 0800E058
    ldr r1, =ar_negative                @ 0800E05A
    strb r0, [r1]                       @ 0800E05E
    movs r0, #1                         @ 0800E060
    ldr r1, =ar_overload                @ 0800E062
    strb r0, [r1]                       @ 0800E066
    b .Lar_0800E092                     @ 0800E068
@ reached from 0800E056 bne (not equal / non-zero) after cmp r0, #1
.Lar_0800E06A:
    ldr r0, =ar_tc_flag                 @ 0800E06A
    ldrb r0, [r0]                       @ 0800E06E
    cmp r0, #2                          @ 0800E070
    bne .Lar_0800E092                   @ 0800E072
    movs r0, #1                         @ 0800E074
    ldr r1, =ar_negative                @ 0800E076
    strb r0, [r1]                       @ 0800E07A
    movs r0, #1                         @ 0800E07C
    ldr r1, =ar_overload                @ 0800E07E
    strb r0, [r1]                       @ 0800E082
    b .Lar_0800E092                     @ 0800E084
@ reached from 0800E04C bne (not equal / non-zero) after cmp r0, #5
.Lar_0800E086:
    cmp r5, r4                          @ 0800E086
    bcs .Lar_0800E092                   @ 0800E088
    movs r0, #1                         @ 0800E08A
    ldr r1, =ar_overload                @ 0800E08C
    strb r0, [r1]                       @ 0800E090
@ reached from 0800E068 b (jump)
@              and from 0800E072 bne (not equal / non-zero) after cmp r0, #2
@              and from 0800E084 b (jump)
@              and from 0800E088 bcs (unsigned >=) after cmp r5, r4
.Lar_0800E092:
    b .Lar_end                          @ 0800E092

@ |D| > U: go up, or overload at the top range / when up is not allowed
@ reached from 0800E042 bge (signed >=) after cmp r0, #2
.Lar_ranging:
    cmp r5, r4                          @ 0800E094
    bcs .Lar_notover                    @ 0800E096

@ HOLD off: try a range up.  HOLD on: overload instead, unless auto-hold stage 2 is also set and the mode is not
@ FREQ, PULSE, DUTY or CAP (then a range up is tried)
    ldr r0, =hold_active                @ 0800E098
    ldrb r0, [r0]                       @ 0800E09C
    cmp r0, #0                          @ 0800E09E
    beq .Lar_0800E0D4                   @ 0800E0A0
    ldr r0, =hold_stage2                @ 0800E0A2
    ldrb r0, [r0]                       @ 0800E0A6
    cmp r0, #0                          @ 0800E0A8
    beq .Lar_overload                   @ 0800E0AA
    ldr r0, =meter_mode                 @ 0800E0AC
    ldrb r0, [r0]                       @ 0800E0B0
    cmp r0, #6                          @ 0800E0B2 mode 6 FREQ
    beq .Lar_overload                   @ 0800E0B4
    ldr r0, =meter_mode                 @ 0800E0B6
    ldrb r0, [r0]                       @ 0800E0BA
    cmp r0, #7                          @ 0800E0BC mode 7 PULSE
    beq .Lar_overload                   @ 0800E0BE
    ldr r0, =meter_mode                 @ 0800E0C0
    ldrb r0, [r0]                       @ 0800E0C4
    cmp r0, #8                          @ 0800E0C6 mode 8 DUTY
    beq .Lar_overload                   @ 0800E0C8
    ldr r0, =meter_mode                 @ 0800E0CA
    ldrb r0, [r0]                       @ 0800E0CE
    cmp r0, #0xC                        @ 0800E0D0 mode 12 CAP
    beq .Lar_overload                   @ 0800E0D2

@ below the top range: the OHM direction guard (fn_0800E2A0(1)) may veto; else range + 1, apply request,
@ blank; in auto-hold stage 2 the captured value is cleared
@ reached from 0800E0A0 beq (equal / zero) after cmp r0, #0
.Lar_0800E0D4:
    ldr r0, =meter_range                @ 0800E0D4
    ldrb r0, [r0]                       @ 0800E0D8
    ldr r1, =range_count                @ 0800E0DA
    ldr r2, =meter_mode                 @ 0800E0DE
    ldrb r2, [r2]                       @ 0800E0E2
    ldrb r1, [r1, r2]                   @ 0800E0E4
    subs r1, r1, #1                     @ 0800E0E6
    cmp r0, r1                          @ 0800E0E8
    bge .Lar_overload                   @ 0800E0EA
    movs r0, #1                         @ 0800E0EC
    bl fn_0800E2A0                      @ 0800E0EE
    cmp r0, #0                          @ 0800E0F2
    bne .Lar_latch                      @ 0800E0F4
    ldr r0, =meter_range                @ 0800E0F8
    ldrb r0, [r0]                       @ 0800E0FC
    adds r0, r0, #1                     @ 0800E0FE
    ldr r1, =meter_range                @ 0800E100
    strb r0, [r1]                       @ 0800E104
    movs r0, #1                         @ 0800E106
    ldr r1, =ar_range_req               @ 0800E108
    strb r0, [r1]                       @ 0800E10C
    movs r0, #1                         @ 0800E10E
    ldr r1, =ar_blank                   @ 0800E110
    strb r0, [r1]                       @ 0800E114
    ldr r0, =hold_stage2                @ 0800E116
    ldrb r0, [r0]                       @ 0800E11A
    cmp r0, #0                          @ 0800E11C
    beq .Lar_latch                      @ 0800E11E
    movs r0, #0                         @ 0800E122
    ldr r1, =ar_hold_value              @ 0800E124
    str r0, [r1]                        @ 0800E128
    b .Lar_latch                        @ 0800E12A

@ overload: flag set.  OHM range 6 in auto-hold stage 2 (not manual, not calibration): remember it so that the
@ next non-overload result jumps to the stored range
@ reached from 0800E0AA beq (equal / zero) after cmp r0, #0
@              and from 0800E0B4 beq (equal / zero) after cmp r0, #6
@              and from 0800E0BE beq (equal / zero) after cmp r0, #7
@              ... and 3 more
.Lar_overload:
    movs r0, #1                         @ 0800E12C
    ldr r1, =ar_overload                @ 0800E12E
    strb r0, [r1]                       @ 0800E132
    ldr r0, =hold_stage2                @ 0800E134
    ldrb r0, [r0]                       @ 0800E138
    ldr r1, =range_manual               @ 0800E13A
    ldrb r1, [r1]                       @ 0800E13E
    eors r1, r1, #1                     @ 0800E140
    ands r0, r1                         @ 0800E144
    ldr r1, =ar_cal_mode                @ 0800E146
    ldrb r1, [r1]                       @ 0800E14A
    eors r1, r1, #1                     @ 0800E14C
    uxtb r0, r0                         @ 0800E150
    tst r0, r1                          @ 0800E152
    beq .Lar_latch                      @ 0800E154
    ldr r0, =meter_mode                 @ 0800E158
    ldrb r0, [r0]                       @ 0800E15C
    cmp r0, #9                          @ 0800E15E mode 9 OHM
    bne .Lar_latch                      @ 0800E160
    ldr r0, =meter_range                @ 0800E162
    ldrb r0, [r0]                       @ 0800E166
    cmp r0, #6                          @ 0800E168
    bne .Lar_latch                      @ 0800E16A
    movs r0, #1                         @ 0800E16C
    ldr r1, =ar_hold_jump               @ 0800E16E
    strb r0, [r1]                       @ 0800E172
    b .Lar_latch                        @ 0800E174
    .ltorg

@ |D| <= U: OHM auto-hold stage 2 after an overload: jump to the stored range (0x20008056)
@ reached from 0800E096 bcs (unsigned >=) after cmp r5, r4
.Lar_notover:
    ldr r0, =hold_stage2                @ 0800E176
    ldrb r0, [r0]                       @ 0800E17A
    ldr r1, =ar_hold_jump               @ 0800E17C
    ldrb r1, [r1]                       @ 0800E180
    ands r0, r1                         @ 0800E182
    ldr r1, =range_manual               @ 0800E184
    ldrb r1, [r1]                       @ 0800E188
    eors r1, r1, #1                     @ 0800E18A
    ands r0, r1                         @ 0800E18E
    ldr r1, =ar_cal_mode                @ 0800E190
    ldrb r1, [r1]                       @ 0800E194
    eors r1, r1, #1                     @ 0800E196
    uxtb r0, r0                         @ 0800E19A
    tst r0, r1                          @ 0800E19C
    beq .Lar_under                      @ 0800E19E
    ldr r0, =meter_mode                 @ 0800E1A0
    ldrb r0, [r0]                       @ 0800E1A4
    cmp r0, #9                          @ 0800E1A6 mode 9 OHM
    bne .Lar_under                      @ 0800E1A8
    ldr r0, =meter_range                @ 0800E1AA
    ldrb r0, [r0]                       @ 0800E1AE
    cmp r0, #6                          @ 0800E1B0
    bne .Lar_under                      @ 0800E1B2
    movs r0, #0                         @ 0800E1B4
    ldr r1, =ar_hold_jump               @ 0800E1B6
    strb r0, [r1]                       @ 0800E1BA
    ldr r0, =ar_hold_range              @ 0800E1BC
    ldrb r0, [r0]                       @ 0800E1C0
    ldr r1, =meter_range                @ 0800E1C2
    strb r0, [r1]                       @ 0800E1C6
    movs r0, #1                         @ 0800E1C8
    ldr r1, =ar_range_req               @ 0800E1CA
    strb r0, [r1]                       @ 0800E1CE
    movs r0, #1                         @ 0800E1D0
    ldr r1, =ar_blank                   @ 0800E1D2
    strb r0, [r1]                       @ 0800E1D6
    b .Lar_latch                        @ 0800E1D8

@ |D| < L: go down unless HOLD (stage 1) is on or the range is 0; the OHM guard may veto, and so does the CAP anti-hunting lock
@ (IMP-45, ah_block_down).  Leaving CAP range 2 with |D| < 11 sets 0x200080A2.  Range - 1, apply request, blank; auto-hold stage 2 clears the captured value
@ reached from 0800E19E beq (equal / zero) after tst r0, r1
@              and from 0800E1A8 bne (not equal / non-zero) after cmp r0, #9
@              and from 0800E1B2 bne (not equal / non-zero) after cmp r0, #6
.Lar_under:
    cmp r4, r6                          @ 0800E1DA
    bcs .Lar_inband                     @ 0800E1DC
    ldr r0, =hold_active                @ 0800E1DE
    ldrb r0, [r0]                       @ 0800E1E2
    cmp r0, #0                          @ 0800E1E4
    bne .Lar_latch                      @ 0800E1E6
    ldr r0, =meter_range                @ 0800E1E8
    ldrb r0, [r0]                       @ 0800E1EC
    cmp r0, #0                          @ 0800E1EE
    beq .Lar_latch                      @ 0800E1F0
    @ IMP-45: CAP range 2 locked by the anti-hunting rule (SETUP page HUnt): no step down (ar_sample takes the decision
    @ first in the production image; this keeps the v2.05 rule from stepping down on the same reading).  r4 = |D|
    mov r0, r4
    bl ah_block_down                    @ r0 = 1 refuse
    cmp r0, #0
    bne .Lar_latch
    movs r0, #0                         @ 0800E1F2
    bl fn_0800E2A0                      @ 0800E1F4
    cmp r0, #0                          @ 0800E1F8
    bne .Lar_latch                      @ 0800E1FA
    ldr r0, =meter_mode                 @ 0800E1FC
    ldrb r0, [r0]                       @ 0800E200
    cmp r0, #0xC                        @ 0800E202 mode 12 CAP
    bne .Lar_0800E21C                   @ 0800E204
    ldr r0, =meter_range                @ 0800E206
    ldrb r0, [r0]                       @ 0800E20A
    cmp r0, #2                          @ 0800E20C
    bne .Lar_0800E21C                   @ 0800E20E
    cmp r4, #0xB                        @ 0800E210
    bcs .Lar_0800E21C                   @ 0800E212
    movs r0, #1                         @ 0800E214
    ldr r1, =ar_cap_small               @ 0800E216
    strb r0, [r1]                       @ 0800E21A
@ reached from 0800E204 bne (not equal / non-zero) after cmp r0, #0xC
@              and from 0800E20E bne (not equal / non-zero) after cmp r0, #2
@              and from 0800E212 bcs (unsigned >=) after cmp r4, #0xB
.Lar_0800E21C:
    ldr r0, =meter_range                @ 0800E21C
    ldrb r0, [r0]                       @ 0800E220
    subs r0, r0, #1                     @ 0800E222
    ldr r1, =meter_range                @ 0800E224
    strb r0, [r1]                       @ 0800E228
    movs r0, #1                         @ 0800E22A
    ldr r1, =ar_range_req               @ 0800E22C
    strb r0, [r1]                       @ 0800E230
    movs r0, #1                         @ 0800E232
    ldr r1, =ar_blank                   @ 0800E234
    strb r0, [r1]                       @ 0800E238
    ldr r0, =hold_stage2                @ 0800E23A
    ldrb r0, [r0]                       @ 0800E23E
    cmp r0, #0                          @ 0800E240
    beq .Lar_latch                      @ 0800E242
    movs r0, #0                         @ 0800E244
    @ IMP-22: in OHM and DIODE 0 is a value auto-hold captures, so the reference after a range change is the impossible
    @ 1000000 (as v2.05 sets it for an OHM overload, 0x0800E47A); a reference of 0 would make a reading of 0 "not new" (the
    @ 400-count change test of fn_0800E30C) after every range step of the auto-ranging down to the short
    ldr r1, =meter_mode
    ldrb r1, [r1]
    cmp r1, #9
    beq 1f
    cmp r1, #11
    bne 2f
1:  ldr r0, =0x000F4240
2:
    ldr r1, =ar_hold_value              @ 0800E246
    str r0, [r1]                        @ 0800E24A
    b .Lar_latch                        @ 0800E24C

@ in the hysteresis band: forget the OHM direction
@ reached from 0800E1DC bcs (unsigned >=) after cmp r4, r6
.Lar_inband:
    movs r0, #0                         @ 0800E24E
    ldr r1, =ar_ohm_dir                 @ 0800E250
    strb r0, [r1]                       @ 0800E254

@ the overload latch follows the overload flag (it widens U to FS + FS/12 for the next result)
@ reached from 0800E0F4 bne (not equal / non-zero) after cmp r0, #0
@              and from 0800E11E beq (equal / zero) after cmp r0, #0
@              and from 0800E12A b (jump)
@              ... and 10 more
.Lar_latch:
    ldr r0, =ar_overload                @ 0800E256
    ldrb r0, [r0]                       @ 0800E25A
    cmp r0, #0                          @ 0800E25C
    beq .Lar_0800E26A                   @ 0800E25E
    movs r0, #1                         @ 0800E260
    ldr r1, =ar_ol_latch                @ 0800E262
    strb r0, [r1]                       @ 0800E266
    b .Lar_end                          @ 0800E268
@ reached from 0800E25E beq (equal / zero) after cmp r0, #0
.Lar_0800E26A:
    movs r0, #0                         @ 0800E26A
    ldr r1, =ar_ol_latch                @ 0800E26C
    strb r0, [r1]                       @ 0800E270
@ reached from 0800DE50 b (jump)
@              and from 0800DEDC b (jump)
@              and from 0800DEF8 b (jump)
@              ... and 4 more
.Lar_end:
    pop {r4, r5, r6, pc}                @ 0800E272
ENDFUNC autorange_step
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800E2A0 - OHM direction guard: veto a down step right after an up step
@ Replaces : 0x0800E2A0 FUN_0800E2A0 (v2.05)
@ In       : r0 = 1 for an up step, 0 for a down step
@ Out      : r0 = 1 refused, 0 allowed (the direction is then recorded)
@ Clobbers : r1, r2, flags
@ Context  : main (autorange_step; the fast path ar_sample uses it too)
@ RAM      : writes ar_ohm_dir 0x20008035 (1 up, 2 down, 0 none) and ar_ohm_dir_tmr 0x20008036 (reload 100); the
@            TIM2 handler counts the timer down and clears the direction at 0 (v2.05 0x080242A0..0x080242D2)
@ Spec     : analysis/autorange_and_scheduler.md 2.2 (OHM direction guard)
@ -----------------------------------------------------------------------------
FUNC fn_0800E2A0

@ only OHM (mode 9) with automatic range outside calibration mode is guarded; elsewhere the direction is
@ cleared and every step is allowed
    movs r1, r0                         @ 0800E2A0
    ldr r0, =range_manual               @ 0800E2A2
    ldrb r0, [r0]                       @ 0800E2A6
    ldr r2, =ar_cal_mode                @ 0800E2A8
    ldrb r2, [r2]                       @ 0800E2AC
    orrs r0, r2                         @ 0800E2AE
    uxtb r0, r0                         @ 0800E2B0
    cmp r0, #0                          @ 0800E2B2
    bne .L800e2a0_0800E2C0              @ 0800E2B4
    ldr r0, =meter_mode                 @ 0800E2B6
    ldrb r0, [r0]                       @ 0800E2BA
    cmp r0, #9                          @ 0800E2BC mode 9 OHM
    beq .L800e2a0_0800E2CC              @ 0800E2BE
@ reached from 0800E2B4 bne (not equal / non-zero) after cmp r0, #0
.L800e2a0_0800E2C0:
    movs r0, #0                         @ 0800E2C0
    ldr r2, =ar_ohm_dir                 @ 0800E2C2
    strb r0, [r2]                       @ 0800E2C6
    movs r0, #0                         @ 0800E2C8
    b .L800e2a0_0800E302                @ 0800E2CA

@ OHM: a down step is refused while the last step was up; any other step is recorded and the 100-tick timer
@ (1.00 s) started
@ reached from 0800E2BE beq (equal / zero) after cmp r0, #9
.L800e2a0_0800E2CC:
    uxtb r1, r1                         @ 0800E2CC
    cmp r1, #0                          @ 0800E2CE
    bne .L800e2a0_0800E2E0              @ 0800E2D0
    ldr r0, =ar_ohm_dir                 @ 0800E2D2
    ldrb r0, [r0]                       @ 0800E2D6
    cmp r0, #1                          @ 0800E2D8
    bne .L800e2a0_0800E2E0              @ 0800E2DA
    movs r0, #1                         @ 0800E2DC
    b .L800e2a0_0800E302                @ 0800E2DE
@ reached from 0800E2D0 bne (not equal / non-zero) after cmp r1, #0
@              and from 0800E2DA bne (not equal / non-zero) after cmp r0, #1
.L800e2a0_0800E2E0:
    uxtb r1, r1                         @ 0800E2E0
    cmp r1, #0                          @ 0800E2E2
    beq .L800e2a0_0800E2F0              @ 0800E2E4
    movs r0, #1                         @ 0800E2E6
    ldr r2, =ar_ohm_dir                 @ 0800E2E8
    strb r0, [r2]                       @ 0800E2EC
    b .L800e2a0_0800E2F8                @ 0800E2EE
@ reached from 0800E2E4 beq (equal / zero) after cmp r1, #0
.L800e2a0_0800E2F0:
    movs r0, #2                         @ 0800E2F0
    ldr r2, =ar_ohm_dir                 @ 0800E2F2
    strb r0, [r2]                       @ 0800E2F6
@ reached from 0800E2EE b (jump)
.L800e2a0_0800E2F8:
    movs r0, #0x64                      @ 0800E2F8
    ldr r2, =ar_ohm_dir_tmr             @ 0800E2FA
    strb r0, [r2]                       @ 0800E2FE
    movs r0, #0                         @ 0800E300
@ reached from 0800E2CA b (jump)
@              and from 0800E2DE b (jump)
.L800e2a0_0800E302:
    bx lr                               @ 0800E302
ENDFUNC fn_0800E2A0
    .ltorg
