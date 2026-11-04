@ =============================================================================
@ lowz.s - MRES: LowZ voltage mode (mode 0): chain selection, voltage detector and AC/DC auto-selection
@
@ Replaces v2.05 FUN_08006540 0x08006540, FUN_08006558 0x08006558 and FUN_0800662C 0x0800662C.
@
@ LowZ (mode 0) measures with a low input impedance and decides by itself whether the voltage present is DC or AC (analysis/
@ hy3131_model.md 3, keys_setup.md): the state 0x20008098 selects the HY3131 row and the handler (0 = DC chain FUN_08007714,
@ 1 = AC chain FUN_08006AEC).  Without a voltage above the threshold the state toggles every 5 means (0x20000239 counts down) and the
@ mode is re-applied; with a voltage above the threshold the detector confirms it over 5 means (0x2000023A) and shows it.
@
@ OF-30 (ORIGINAL_FIRMWARE_ISSUES.md, owner decision): v2.05 stored 0 into the displayed value 0x20007D64 for every mean above the
@ threshold until the fifth, so "0.0" was shown for 1.1 to 2.4 s while 100..600 V were present, and the HV symbol (which looks at
@ the displayed value) came up to 1.58 s late.  The port keeps the real
@ value in 0x20007D64 (the HV logic sees it at the first mean) and sets the UI request byte ui_blank_req (W3, port RAM) to 2 while
@ the voltage is not yet confirmed; the main digits show five dashes then (firmware/requests/W3_to_W5.md 1).
@ OF-30 port correction (both builds, 2026-11-03): for the first unconfirmed mean the request is 3 (the digits on the glass stay): on a meter with nothing
@ connected, the first mean after each AC/DC re-apply of the dead band rises above the threshold for one mean (Bluetooth log
@ of a meter: one frame with a full bar about every 2.9 s), and the request 2 of OF-30 flashed "-----" for it.
@ Production image only: the bargraph ignores the samples of that first mean as well (lowz_bar_hold, read by fn_08018B14):
@ on the meter the bar jumped to full scale with the polarity sign flipping for it (seen on a meter, v0.9.8; the hold is
@ verified working on a meter, v0.9.9).  A real
@ voltage that arrives within that mean moves the bar one mean later.  The byte is 0
@ whenever no voltage is pending.  The AC/DC selection logic is unchanged.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .bss_port.mres, "aw", %nobits
@ lowz_bar_hold: 1 from the AC/DC re-apply of the dead band until the next mean has been handled by fn_08006558 (owner
@ MRES; read by fn_08018B14): the bargraph keeps its segments for the samples of that mean, the settling mean of OF-30
@ (production image only)
    .global lowz_bar_hold
lowz_bar_hold:  .space 1

    .section .text.mres.lowz, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08006540 - LowZ handler: choose the DC or the AC chain
@ Replaces : 0x08006540 FUN_08006540 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x20008098
@ Spec     : analysis/hy3131_model.md 4.2
@ Deviation: none
@ Called by ad1_ready_dispatch for every conversion in mode 0: state 0 (DC) -> FUN_08007714, state 1 (AC) -> FUN_08006AEC (MAC).
@ -----------------------------------------------------------------------------
FUNC fn_08006540
    push {r7, lr}                      @ 0x08006540
    ldr r0, =v_20008098                @ 0x08006542 pool 0x08006AE4 = 0x20008098
    ldrb r0, [r0, #0]                  @ 0x08006546
    cmp r0, #0                         @ 0x08006548
    beq .L08006552                     @ 0x0800654A
    bl fn_08006AEC                     @ 0x0800654C
    b .L08006556                       @ 0x08006550
.L08006552:                              @ reached from 0x0800654A beq
    bl fn_08007714                     @ 0x08006552
.L08006556:                              @ reached from 0x08006550 b
    pop {r0, pc}                       @ 0x08006556
    .ltorg
ENDFUNC fn_08006540

@ -----------------------------------------------------------------------------
@ fn_0800662C - reload the LowZ AC/DC toggle countdown
@ Replaces : 0x0800662C FUN_0800662C (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : main only
@ RAM      : reads  0x20008098
@            writes 0x20000239
@ Spec     : analysis/hy3131_model.md 3 (LowZ)
@ Deviation: none
@ 0x20000239 = 5 whatever the state (v2.05 has the same store in both branches of the state test, 0x08006636 and 0x0800663C).
@ -----------------------------------------------------------------------------
FUNC fn_0800662C
    ldr r0, =v_20008098                @ 0x0800662C pool 0x08006AE4 = 0x20008098
    ldrb r0, [r0, #0]                  @ 0x08006630
    cmp r0, #0                         @ 0x08006632
    beq .L08006640                     @ 0x08006634
    movs r0, #5                        @ 0x08006636
    ldr r1, =v_20000239                @ 0x08006638 pool 0x080070A0 = 0x20000239
    strb r0, [r1, #0]                  @ 0x0800663C
    b .L08006648                       @ 0x0800663E
.L08006640:                              @ reached from 0x08006634 beq
    movs r0, #5                        @ 0x08006640
    ldr r1, =v_20000239                @ 0x08006642 pool 0x080070A0 = 0x20000239
    strb r0, [r1, #0]                  @ 0x08006646
.L08006648:                              @ reached from 0x0800663E b
    bx lr                              @ 0x08006648
    .ltorg
ENDFUNC fn_0800662C

@ -----------------------------------------------------------------------------
@ fn_08006558 - LowZ voltage detector and AC/DC auto-selection
@ Replaces : 0x08006558 FUN_08006558 (v2.05)
@ In       : - (called by the main loop in mode 0 when a new value 0x2000805D is set)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 preserved)
@ Context  : main only
@ RAM      : reads  0x20000239, 0x2000023A, 0x20007D64, 0x20008046, 0x20008098, 0x20008099
@            writes ui_blank_req, 0x20000239, 0x2000023A, 0x20007D64, 0x20008060, 0x20008098, 0x20008099
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-30; analysis/hy3131_model.md 3, 4.2
@ Deviation: OF-30
@ Threshold: 100 counts when 0x20008099 = 0, 30 counts when 1.  |D| <= threshold and no overload: D = 0, 0x20008099 = 0, 0x2000023A = 5,
@ and every 5th such mean the AC/DC state 0x20008098 toggles and mode 0 is applied again.  Otherwise a voltage is present: 5 means
@ confirm it (0x2000023A -> 0, 0x20008099 = 1).
@ -----------------------------------------------------------------------------
FUNC fn_08006558
    push {r4, lr}                      @ 0x08006558
    movs r0, #0
    ldr r1, =lowz_bar_hold
    strb r0, [r1]                           @ a mean has arrived: the bargraph follows the samples again
    ldr r0, =v_20008099                @ 0x0800655A pool 0x08006D34 = 0x20008099
    ldrb r0, [r0, #0]                  @ 0x0800655E
    cmp r0, #0                         @ 0x08006560
    bne .L0800656A                     @ 0x08006562
    movs r0, #100                      @ 0x08006564
    movs r4, r0                        @ 0x08006566
    b .L0800656E                       @ 0x08006568
.L0800656A:                              @ reached from 0x08006562 bne
    movs r0, #30                       @ 0x0800656A
    movs r4, r0                        @ 0x0800656C
.L0800656E:                              @ reached from 0x08006568 b
    @ r4 = threshold in counts (0.1 V): 100 (10.0 V) until the voltage is confirmed, 30 (3.0 V) after
    ldr r0, =v_20007D64                @ 0x0800656E pool 0x08006D28 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08006572
    cmp r4, r0                         @ 0x08006574
    blt .L080065EC                     @ 0x08006576  threshold < D?
    ldr r0, =v_20007D64                @ 0x08006578 pool 0x08006D28 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x0800657C
    cmn r0, r4                         @ 0x0800657E
    blt .L080065EC                     @ 0x08006580  D < -threshold?
    ldr r0, =v_20008046                @ 0x08006582 pool 0x08006D38 = 0x20008046
    ldrb r0, [r0, #0]                  @ 0x08006586
    cmp r0, #0                         @ 0x08006588
    bne .L080065EC                     @ 0x0800658A  overload flag set: treat as a voltage
    @ ---- |D| within the threshold and no overload: dead band, show 0.0 (D = 0), voltage not present ----
    movs r0, #0
    ldr r1, =ui_blank_req
    strb r0, [r1]                           @ OF-30: nothing pending when the voltage is gone
    movs r0, #0                        @ 0x0800658C
    ldr r1, =v_20007D64                @ 0x0800658E pool 0x08006D28 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08006592
    @ 0x20008099 = 0 (not confirmed), 0x2000023A = 5 (means needed to confirm), 0x20008060 = 1 (annunciator refresh)
    movs r0, #0                        @ 0x08006594
    ldr r1, =v_20008099                @ 0x08006596 pool 0x08006D34 = 0x20008099
    strb r0, [r1, #0]                  @ 0x0800659A
    movs r0, #5                        @ 0x0800659C
    ldr r1, =v_2000023A                @ 0x0800659E pool 0x08006D3C = 0x2000023A
    strb r0, [r1, #0]                  @ 0x080065A2
    movs r0, #1                        @ 0x080065A4
    ldr r1, =v_20008060                @ 0x080065A6 pool 0x0800709C = 0x20008060
    strb r0, [r1, #0]                  @ 0x080065AA
    @ ---- AC/DC toggle countdown 0x20000239: after 5 means without a voltage switch between the DC and AC variants and re-apply ----
    ldr r0, =v_20000239                @ 0x080065AC pool 0x080070A0 = 0x20000239
    ldrb r0, [r0, #0]                  @ 0x080065B0
    subs r0, r0, #1                    @ 0x080065B2
    ldr r1, =v_20000239                @ 0x080065B4 pool 0x080070A0 = 0x20000239
    strb r0, [r1, #0]                  @ 0x080065B8
    ldr r0, =v_20000239                @ 0x080065BA pool 0x080070A0 = 0x20000239
    ldrb r0, [r0, #0]                  @ 0x080065BE
    cmp r0, #0                         @ 0x080065C0
    bne .L0800662A                     @ 0x080065C2
    ldr r0, =v_20008098                @ 0x080065C4 pool 0x08006AE4 = 0x20008098
    ldrb r0, [r0, #0]                  @ 0x080065C8
    cmp r0, #0                         @ 0x080065CA
    beq .L080065D8                     @ 0x080065CC
    movs r0, #0                        @ 0x080065CE
    ldr r1, =v_20008098                @ 0x080065D0 pool 0x08006AE4 = 0x20008098
    strb r0, [r1, #0]                  @ 0x080065D4
    b .L080065E0                       @ 0x080065D6
.L080065D8:                              @ reached from 0x080065CC beq
    movs r0, #1                        @ 0x080065D8
    ldr r1, =v_20008098                @ 0x080065DA pool 0x08006AE4 = 0x20008098
    strb r0, [r1, #0]                  @ 0x080065DE
.L080065E0:                              @ reached from 0x080065D6 b
    bl fn_0800662C                     @ 0x080065E0
    movs r0, #1
    ldr r1, =lowz_bar_hold
    strb r0, [r1]                           @ the first mean after this re-apply settles: the bargraph waits for it
    movs r0, #0                        @ 0x080065E4
    bl meter_apply_mode_range          @ 0x080065E6
    b .L0800662A                       @ 0x080065EA
.L080065EC:                              @ reached from 0x08006576 blt, 0x08006580 blt, 0x0800658A bne
    @ ---- |D| above the threshold, or overload: a voltage is present ----
    bl fn_0800662C                          @ reload the toggle countdown (v2.05 0x080065EC)
    ldr r0, =v_20008099
    ldrb r0, [r0]
    cmp r0, #0
    bne .Llz_confirmed                      @ already confirmed: the real value is shown
    ldr r0, =v_2000023A
    ldrb r0, [r0]
    subs r0, r0, #1                         @ one more mean with a voltage present
    ldr r1, =v_2000023A
    strb r0, [r1]
    @ OF-30: not confirmed yet - D keeps the real value; v2.05 stored D = 0 here (0x080065FA..0x08006600).  The first
    @ such mean (count 5 -> 4) keeps the digits on the glass (ui_blank_req = 3): on a meter the first mean after the AC/DC
    @ re-apply of the dead band is a settling spike, which v2.05 hid behind its D = 0 and which must not flash
    @ "-----"; from the second mean on, five dashes (ui_blank_req = 2, W3_to_W5.md 1).
    cmp r0, #4
    ite hs
    movhs r2, #3                            @ first mean above the threshold: keep the previous digits
    movlo r2, #2                            @ second and later: dashes
    ldr r1, =ui_blank_req
    strb r2, [r1]
    cmp r0, #0
    bne .L0800662A                          @ fewer than 5 means: keep waiting (pending stays set)
    movs r0, #1
    ldr r1, =v_20008099
    strb r0, [r1]                           @ confirmed after 5 means (v2.05 0x0800661A)
    movs r0, #1
    ldr r1, =v_20008060
    strb r0, [r1]                           @ annunciator refresh
.Llz_confirmed:
    movs r0, #0
    ldr r1, =ui_blank_req
    strb r0, [r1]                           @ decision taken: the value is shown
.L0800662A:                              @ reached from 0x080065C2 bne, 0x080065EA b, 0x080065F8 bne, 0x08006618 bne
    pop {r4, pc}                       @ 0x0800662A
    .ltorg
ENDFUNC fn_08006558
