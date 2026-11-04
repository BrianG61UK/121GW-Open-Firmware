@ =============================================================================
@ beep.s - MRES: continuity (BEEP, mode 10) handler, decision and thresholds
@
@ Replaces v2.05 FUN_080078B8 0x080078B8, FUN_080078D8 0x080078D8 and FUN_08007940 0x08007940.
@
@ BEEP is the OHM chain with range 0 (record 0x120) plus the continuity decision on every AD1 sample (hy3131_modes_misc.md 6.3):
@ the per-sample value v = 0x20007D68 (0.01 ohm) is compared as an UNSIGNED number with the threshold from fn_08007940; the state
@ byte 0x200080B5 (1 = tone on) gives the hysteresis; while it holds pe7_on_with_timeout(100) re-arms the buzzer (not gated by the
@ key beep enable).  The setting byte is 0x200080B6 (EEPROM 0x14, loaded by SET).
@
@ IMP-04 (production): the decision is made on every conversion because the loop services every conversion (HY).  IMP-05
@ (production): continuity codes 4..15 (ARS 9) in addition to the v2.05 codes 0..3; the thresholds are table driven (mres_beep_thr).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ MRES_BEEP_CODES, 16               @ continuity codes 0..15 (IMP-05)
    .equ MRES_BEEP_UP_MASK, 0xFC0A         @ bit n = 1: code n is an "UP" code (beep while v >= threshold): 1, 3, 10..15

    .section .text.mres.beep, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_080078B8 - BEEP handler: OHM chain (range 0), then the continuity decision on the per-sample value
@ Replaces : 0x080078B8 FUN_080078B8 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x20007D68
@ Spec     : analysis/hy3131_modes_misc.md 6.3
@ Deviation: none
@ FUN_080079C4 (OHM chain, mean branch and per-sample value), then fn_080078D8(0x20007D68).
@ -----------------------------------------------------------------------------
FUNC fn_080078B8
    push {r7, lr}                      @ 0x080078B8
    bl fn_080079C4                     @ 0x080078BA
    ldr r0, =v_20007D68                @ 0x080078BE pool 0x08008340 = 0x20007D68
    ldr r0, [r0, #0]                   @ 0x080078C2
    bl fn_080078D8                     @ 0x080078C4
    pop {r0, pc}                       @ 0x080078C8
    .ltorg
ENDFUNC fn_080078B8

@ -----------------------------------------------------------------------------
@ fn_080078D8 - continuity decision: tone on/off with hysteresis
@ Replaces : 0x080078D8 FUN_080078D8 (v2.05)
@ In       : r0 = per-sample value v (0.01 ohm, compared unsigned)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4, r5 preserved)
@ Context  : main only
@ RAM      : reads  0x200080B6
@            writes 0x200080B5
@ Spec     : analysis/hy3131_modes_misc.md 6.3; autorange_and_scheduler.md 8, 9
@ Deviation: IMP-04, IMP-05, IMP-16 (production: the hold time of the tone from the page bH, set_bh_ticks)
@ t = fn_08007940() (start threshold when 0x200080B5 = 0, continue threshold when 1).  DN codes (0, 2, 4..9): tone while v <= t;
@ UP codes (1, 3, 10..15): tone while v >= t.  Tone: 0x200080B5 = 1 and pe7_on_with_timeout(100); otherwise 0x200080B5 = 0.
@ -----------------------------------------------------------------------------
FUNC fn_080078D8
    push {r3, r4, r5, lr}              @ 0x080078D8
    movs r4, r0                        @ 0x080078DA
    bl fn_08007940                     @ 0x080078DC
    movs r5, r0                        @ 0x080078E0
    @ IMP-05: direction from the code table: bit n of MRES_BEEP_UP_MASK = 1 -> UP code (beep while v >= threshold)
    ldr r0, =v_200080B6
    ldrb r0, [r0]
    cmp r0, #MRES_BEEP_CODES
    blo 1f
    movs r0, #0                             @ code outside 0..15: DN 30
1:
    movw r1, #MRES_BEEP_UP_MASK
    lsrs r1, r1, r0
    lsls r1, r1, #31                        @ bit 0 (the code's UP bit) to the sign flag
    bpl .L080078F6                          @ DN code
    b .L08007914                            @ UP code
.L080078F6:                              @ reached from 0x080078EA beq
    @ ---- DN code: v > t (unsigned): off; else on (v2.05 0x080078F6) ----
    cmp r5, r4                         @ 0x080078F6
    bcc .L0800790A                     @ 0x080078F8
    movs r0, #1                        @ 0x080078FA
    ldr r1, =v_200080B5                @ 0x080078FC pool 0x080082D0 = 0x200080B5
    strb r0, [r1, #0]                  @ 0x08007900
    bl set_bh_ticks                    @ IMP-16: hold time of the page bH (100 ticks by default, as v2.05)
    bl pe7_on_with_timeout             @ 0x08007904
    b .L08007930                       @ 0x08007908
.L0800790A:                              @ reached from 0x080078F8 bcc
    movs r0, #0                        @ 0x0800790A
    ldr r1, =v_200080B5                @ 0x0800790C pool 0x080082D0 = 0x200080B5
    strb r0, [r1, #0]                  @ 0x08007910
    b .L08007930                       @ 0x08007912
.L08007914:                              @ reached from 0x080078F4 bne
    @ ---- UP code: v < t (unsigned): off; else on (v2.05 0x08007914) ----
    cmp r4, r5                         @ 0x08007914
    bcc .L08007928                     @ 0x08007916
    movs r0, #1                        @ 0x08007918
    ldr r1, =v_200080B5                @ 0x0800791A pool 0x080082D0 = 0x200080B5
    strb r0, [r1, #0]                  @ 0x0800791E
    bl set_bh_ticks                    @ IMP-16: hold time of the page bH (100 ticks by default, as v2.05)
    bl pe7_on_with_timeout             @ 0x08007922
    b .L08007930                       @ 0x08007926
.L08007928:                              @ reached from 0x08007916 bcc
    movs r0, #0                        @ 0x08007928
    ldr r1, =v_200080B5                @ 0x0800792A pool 0x080082D0 = 0x200080B5
    strb r0, [r1, #0]                  @ 0x0800792E
.L08007930:                              @ reached from 0x08007908 b, 0x08007912 b, 0x08007926 b
    pop {r0, r4, r5, pc}               @ 0x08007930
    .ltorg
ENDFUNC fn_080078D8

@ -----------------------------------------------------------------------------
@ fn_08007940 (production) - continuity threshold from the code table
@ Replaces : 0x08007940 FUN_08007940 (v2.05)
@ In       : - (reads 0x200080B5 state, 0x200080B6 code)
@ Out      : r0 = threshold in 0.01 ohm (start value when 0x200080B5 = 0, continue value when 1)
@ Clobbers : r0-r2, flags
@ Context  : main only
@ RAM      : reads  0x200080B5, 0x200080B6
@ Spec     : analysis/autorange_and_scheduler.md 9 (codes 0..15)
@ Deviation: IMP-05
@ Codes 0..3 give the v2.05 values; 4..15 are the ARS 9 extension; a code of 16 or more (not reachable, SET accepts < 16) uses code 0.
@ -----------------------------------------------------------------------------
FUNC fn_08007940
    ldr r1, =v_200080B6
    ldrb r1, [r1]                           @ continuity code
    cmp r1, #MRES_BEEP_CODES
    blo 1f
    movs r1, #0                             @ code >= 16 is not a valid code: use code 0
1:
    ldr r2, =mres_beep_thr
    add r2, r2, r1, lsl #2                  @ entry of the code: u16 start, u16 continue
    ldr r1, =v_200080B5
    ldrb r1, [r1]                           @ 0: tone off (start threshold), 1: tone on (continue threshold)
    cmp r1, #0
    bne 2f
    ldrh r0, [r2]                           @ start threshold
    bx lr
2:
    ldrh r0, [r2, #2]                       @ continue threshold (hysteresis)
    bx lr
    .ltorg
ENDFUNC fn_08007940

    .section .rodata.mres.beep, "a", %progbits
    .balign 4
@ Continuity thresholds in 0.01 ohm per code: {start, continue}.  Codes 0..3: v2.05 0x08007940 (3000/0xDAC, 3000/0x9C4,
@ 30000/0x7724, 30000/0x733C); codes 4..15: analysis/autorange_and_scheduler.md 9 (hysteresis 5.00 ohm for thresholds >= 30 ohm,
@ below that T/6 rounded to 0.01 ohm, at least 0.20 ohm).
mres_beep_thr:
    .hword 3000, 3500                       @  0 DN 30
    .hword 3000, 2500                       @  1 UP 30
    .hword 30000, 30500                     @  2 DN300
    .hword 30000, 29500                     @  3 UP300
    .hword 100, 120                         @  4 DN  1
    .hword 500, 583                         @  5 DN  5
    .hword 1000, 1167                       @  6 DN 10
    .hword 5000, 5500                       @  7 DN 50
    .hword 10000, 10500                     @  8 DN100
    .hword 20000, 20500                     @  9 DN200
    .hword 100, 80                          @ 10 UP  1
    .hword 500, 417                         @ 11 UP  5
    .hword 1000, 833                        @ 12 UP 10
    .hword 5000, 4500                       @ 13 UP 50
    .hword 10000, 9500                      @ 14 UP100
    .hword 20000, 19500                     @ 15 UP200
