@ =============================================================================
@ relpct.s - UI: REL in percent, a view of the REL reading (production image only, DESIGN.md 10 IMP-11, FEATURES.md 2.3)
@
@ v2.05 REL (fn_0800E594) replaces the reading D (0x20007D64) by x - base, the base 0x20007DA8 being the first result after
@ REL was switched on (or the last MIN/MAX reading).  With the SETUP page rEL set to percent (set_relp = 1) the main display
@ shows instead
@     p = (x - base) / base * 100 % = D * 100 / base %
@ with the decimal point placed by magnitude: 0.001 % resolution (xx.xxx) while |p| < 100 %, then 0.01, 0.1 and 1 %
@ (up to 99999 %); above that " OFL " (the reading itself is not an overload: the OL flag is not touched); a base of 0 has
@ no percent: "-----".  Every step rounds half away from zero once, from the exact quotient (no double rounding).
@ Only the main display changes: D, the logging, MIN/MAX and the BLE frame keep the REL value in counts (0x20007D70, the
@ value the BLE frame reports, is set to D after the percent is drawn, as v2.05 does for its REL overflow path
@ 0x08017046..0x08017078).
@
@ When the view is shown: exactly when v2.05 lights the REL sign (FUN_08019F2E 0x08019F82: rel_active != 0, 0x20007FE1 = 0,
@ 0x20007FE4 = 0) and set_relp = 1.  While it is shown, the unit and prefix signs of the main reading are off and the %
@ sign (Sub%, w0b17, the sign DUTY uses for its reading) is on.  The mask is applied to the shadow at every full commit
@ (lcd_commit_shadow; the partial commit writes bargraph bits only, analysis/lcd_map.md 1), so it holds whatever routine
@ redrew a sign before; when the view ends the redraw of every annunciator (0x20008060) and of the unit prefix (0x20008061)
@ is requested, which restores the signs of the mode.
@ Unit and prefix signs (analysis/lcd_map.md 4.1): w0 b8 k, b9 u, b11 M; w2 b8 Ohm, b9 n, b10 m; w4 b8 Hz, b9 F, b10 V,
@ b11 degC; w6 b10 A, b11 degF; w6 b0 ms (PULSE), left alone while peak hold shows "1ms" with it (0x200080B7).
@ Mode signs (LowZ, Beep, Diode), AC/DC and the status signs are not touched.
@
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ ui_rp_reading,       v_20007D64    @ displayed reading D (counts, after REL)
    .equ ui_rp_base,          v_20007DA8    @ REL base (counts)
    .equ ui_rp_last_drawn,    v_20007D70    @ last drawn main value, the BLE value
    .equ UI_RP_W0_MASK,       0x00000B00    @ w0: k (b8), u (b9), M (b11)
    .equ UI_RP_W0_PCT,        0x00020000    @ w0: % (b17)
    .equ UI_RP_W2_MASK,       0x00000700    @ w2: Ohm (b8), n (b9), m (b10)
    .equ UI_RP_W4_MASK,       0x00000F00    @ w4: Hz (b8), F (b9), V (b10), degC (b11)
    .equ UI_RP_W6_MASK,       0x00000C00    @ w6: A (b10), degF (b11)
    .equ UI_RP_W6_MS,         0x00000001    @ w6: ms (b0)
    .equ UI_RP_W4_DEGC,       0x00000800    @ w4: degC (b11)
    .equ UI_RP_W6_DEGF,       0x00000800    @ w6: degF (b11)

    .section .bss_port.ui, "aw", %nobits
@ ui_relpct_last: non-zero = a view was applied at the last full commit (1 percent, 2 RTD temperature) (owner UI)
ui_relpct_last: .space 1

    .section .rodata.ui.relpct, "a", %progbits
    .balign 4
@ powers of ten for the divisor |base| * 10^k, k = 0..3
ui_rp_pow10:
    .word 1, 10, 100, 1000

    .section .text.ui.relpct, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ui_relpct_view - is the percent view shown?
@ Replaces : nothing in v2.05 (new)
@ In       : -
@ Out      : r0 = 1 shown, 0 not
@ Clobbers : r1, flags
@ Context  : main only
@ RAM      : reads set_relp, rel_active, 0x20007FE1, 0x20007FE4
@ -----------------------------------------------------------------------------
FUNC ui_relpct_view
    ldr r0, =set_relp
    ldrb r0, [r0]
    cbz r0, 1f                              @ setting: difference
    ldr r0, =rel_active
    ldrb r0, [r0]
    cbz r0, 1f                              @ REL off
    ldr r1, =v_20007FE1
    ldrb r1, [r1]
    cbnz r1, 2f                             @ as the REL sign: not with 0x20007FE1
    ldr r1, =v_20007FE4
    ldrb r1, [r1]
    cbnz r1, 2f                             @ nor with 0x20007FE4 (MEM view)
    movs r0, #1
    bx lr
2:  movs r0, #0
1:  bx lr
ENDFUNC ui_relpct_view

@ -----------------------------------------------------------------------------
@ ui_relpct_draw - draw the REL reading as percent of the base on the main display
@ Replaces : for the percent view, the draw of D in fn_08016E08 (0x0801702E..0x08017090)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Context  : main only (fn_08016E08, only while ui_relpct_view = 1, no overload)
@ RAM      : reads ui_rp_reading, ui_rp_base, hold_active, meter_mode; writes lcd_shadow (through the drawers),
@            ui_rp_last_drawn
@ Note     : q_k = round(|D| * 10^(5 - k) / |base|) for k = 0, 1, 2, 3 (decimals 3, 2, 1, 0), the first q_k <= 99999 is
@            drawn; |D| * 10^5 < 2^48 and |base| * 10^k < 2^41, so the unsigned 64-bit divide fn_08014028 is exact.
@            Nothing is drawn while HOLD is active (the dashes and OFL texts as the digits, which lcd_show_value_pos5_9
@            skips with r3 = 1, the D draw of v2.05); 0x20007D70 then keeps its value.
@ -----------------------------------------------------------------------------
FUNC ui_relpct_draw
    push {r4, r5, r6, r7, lr}
    ldr r0, =hold_active
    ldrb r0, [r0]
    cmp r0, #0
    bne .Lrp_held                           @ HOLD: the held display stays (also for the dashes and OFL texts)
    ldr r0, =ui_rp_base
    ldr r5, [r0]                            @ r5 = base
    cbnz r5, 1f
    bl ui_rp_text_prep                      @ base 0: no percent; no decimal point, no minus sign
    movs r0, #0
    bl fn_08019A86                          @ "-----" on the main display
    b .Lrp_store
1:  ldr r0, =ui_rp_reading
    ldr r4, [r0]                            @ r4 = D
    eor r7, r4, r5                          @ r7 bit 31 = sign of the quotient
    cmp r4, #0
    it lt
    neglt r4, r4                            @ |D|
    cmp r5, #0
    it lt
    neglt r5, r5                            @ |base|
    movs r6, #0                             @ k = 0
.Lrp_try:
    @ q_k = round(|D| * 10^5 / (|base| * 10^k)) = round(|D| * 10^(5 - k) / |base|), one rounding from the exact quotient
    ldr r0, =100000
    umull r0, r1, r4, r0                    @ r1:r0 = |D| * 10^5
    ldr r2, =ui_rp_pow10
    ldr r2, [r2, r6, lsl #2]
    umull r2, r3, r5, r2                    @ r3:r2 = d = |base| * 10^k
    lsrs r12, r3, #1
    push {r2, r3}
    lsr r2, r2, #1
    orr r2, r2, r3, lsl #31                 @ r12:r2 = d / 2
    adds r0, r0, r2
    adc r1, r1, r12                         @ dividend + d / 2: rounds half away from zero (magnitudes)
    pop {r2, r3}
    bl fn_08014028                          @ r1:r0 = q_k
    cbnz r1, .Lrp_next                      @ >= 2^32: too large
    ldr r1, =99999
    cmp r0, r1
    bls .Lrp_fit
.Lrp_next:
    adds r6, r6, #1
    cmp r6, #4
    blo .Lrp_try
    bl ui_rp_text_prep                      @ above 99999 %: no decimal point, no minus sign ...
    movs r0, #0                             @ ... and " OFL " (the OL flag is not set: the reading is valid)
    bl fn_080199B4
    b .Lrp_store
.Lrp_fit:
    tst r7, #0x80000000
    it ne
    negne r0, r0                            @ sign of D / base
    mov r2, r0                              @ value
    rsb r1, r6, #3                          @ decimals 3 - k
    movs r3, #1                             @ skip while hold is active (as the D draw, 0x0801707C)
    ldr r0, =meter_mode
    ldrb r0, [r0]                           @ mode (unused by the drawer, passed as v2.05 does)
    bl lcd_show_value_pos5_9
.Lrp_store:
    ldr r0, =hold_active
    ldrb r0, [r0]
    cbnz r0, 2f                             @ held: nothing was drawn, the BLE value stays
    ldr r0, =ui_rp_reading
    ldr r0, [r0]
    ldr r1, =ui_rp_last_drawn
    str r0, [r1]                            @ the BLE frame keeps reporting D in counts
    movs r0, #1
    ldr r1, =v_2000805B
    strb r0, [r1]                           @ commit request (the dashes and OFL drawers do not set it themselves)
2:
.Lrp_held:
    pop {r4, r5, r6, r7, pc}
ENDFUNC ui_relpct_draw

@ -----------------------------------------------------------------------------
@ ui_rp_text_prep - clear the main decimal point and minus sign before a text replaces the digits
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only (ui_relpct_draw)
@ RAM      : writes lcd_shadow (decimal point through fn_0801717E, w3 bit 7)
@ Note     : The text drawers fn_08019A86 ("-----") and fn_080199B4 (" OFL ") write the five characters only; a percent
@            drawn before leaves its point and sign, which this clears (as lcd_show_value_pos5_9 sets both for a value).
@ -----------------------------------------------------------------------------
LFUNC ui_rp_text_prep
    push {r4, lr}
    movs r0, #0
    bl fn_0801717E                          @ main decimal point: none
    ldr r1, =lcd_shadow
    ldr r0, [r1, #12]
    bic r0, r0, #0x80                       @ w3 b7: main minus off
    str r0, [r1, #12]
    pop {r4, pc}
ENDFUNC ui_rp_text_prep

@ -----------------------------------------------------------------------------
@ ui_relpct_mask - apply the percent view (REL percent, IMP-11, or the DCmA loop view, IMP-24) or the OHM RTD temperature
@ view (IMP-25) to the shadow before a full commit
@ Replaces : nothing in v2.05 (new; called first by lcd_commit_shadow)
@ In/Out   : - / -
@ Clobbers : r0-r3, flags
@ Context  : main only
@ RAM      : reads and writes lcd_shadow words 0, 2, 4, 6, ui_relpct_last; reads peak_hold, 0x200080AB; writes 0x20008060,
@            0x20008061 when the view ends
@ Note     : the percent views clear the unit and prefix signs and light %; the RTD view clears them (% included) and
@            lights degC (0x200080AB non-zero) or degF (0), the signs of TEMP (fn_0801A3A4).  The views are tried in the
@            order of fn_08016E08, so the mask belongs to the view that is drawn; the pages Sd, tHI, tLo and HUnt (IMP-45), drawn there
@            before every view, take no mask (before IMP-25 the percent mask also covered the standard deviation of Sd).
@ -----------------------------------------------------------------------------
FUNC ui_relpct_mask
    push {r4, lr}
    bl ui_stats_view
    cbnz r0, 0f                             @ page Sd on the main digits (IMP-14): the reading's own unit, no view
    bl ui_mmt_view
    cbnz r0, 0f                             @ page tHI / tLo on the main digits (IMP-21): no view
    bl ui_hunt_view
    cbnz r0, 0f                             @ page HUnt on the main digits (IMP-45): no view
    bl ui_relpct_view
    cbnz r0, 1f
    bl ui_loop_view                         @ IMP-24: the DCmA loop percent view uses the same mask
    cbnz r0, 1f
    bl ui_rtd_view                          @ IMP-25: the RTD view, kind 2
    lsls r0, r0, #1                         @ r0 = 0 none, 1 percent, 2 temperature
    b 1f
0:  movs r0, #0
1:  mov r4, r0
    ldr r1, =ui_relpct_last
    ldrb r2, [r1]
    strb r0, [r1]                           @ remember for the next commit
    cbnz r0, .Lrm_apply
    cbz r2, .Lrm_ret                        @ off, and was off: nothing
    movs r0, #1                             @ the view has ended: redraw every annunciator and the unit prefix
    ldr r1, =v_20008060
    strb r0, [r1]
    ldr r1, =v_20008061
    strb r0, [r1]
    b .Lrm_ret
.Lrm_apply:
    ldr r3, =lcd_shadow
    ldr r0, [r3, #0]
    bic r0, r0, #UI_RP_W0_MASK
    bic r0, r0, #UI_RP_W0_PCT
    cmp r4, #1
    it eq
    orreq r0, r0, #UI_RP_W0_PCT             @ % on for a percent view; k / u / M off
    str r0, [r3, #0]
    ldr r0, [r3, #8]
    bic r0, r0, #UI_RP_W2_MASK              @ Ohm / n / m off
    str r0, [r3, #8]
    ldr r0, [r3, #16]
    bic r0, r0, #UI_RP_W4_MASK              @ Hz / F / V / degC off
    str r0, [r3, #16]
    ldr r0, [r3, #24]
    bic r0, r0, #UI_RP_W6_MASK              @ A / degF off
    ldr r1, =peak_hold
    ldrb r1, [r1]
    cbnz r1, 1f                             @ peak hold: w6 b0 belongs to "1ms"
    bic r0, r0, #UI_RP_W6_MS                @ ms off
1:  str r0, [r3, #24]
    cmp r4, #2
    bne .Lrm_ret
    ldr r1, =v_200080AB                     @ IMP-25: the temperature sign of TEMP
    ldrb r1, [r1]
    cbz r1, 2f
    ldr r0, [r3, #16]
    orr r0, r0, #UI_RP_W4_DEGC              @ degC
    str r0, [r3, #16]
    b .Lrm_ret
2:  ldr r0, [r3, #24]
    orr r0, r0, #UI_RP_W6_DEGF              @ degF
    str r0, [r3, #24]
.Lrm_ret:
    pop {r4, pc}
ENDFUNC ui_relpct_mask

    .ltorg

