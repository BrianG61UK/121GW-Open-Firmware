@ =============================================================================
@ rtd.s - UI: the platinum RTD temperature view of OHM (production image only, DESIGN.md 10 IMP-25, FEATURES.md 2.15)
@
@ With the SETUP page Pt (set/rtd.s) at Pt100 or Pt1000, OHM (mode 9) shows on the main display the temperature of the
@ sensor instead of its resistance, in degC or degF as TEMP (0x200080AB), with one decimal (0.1 degree).
@ The resistance R is taken from the displayed reading D: OHM range 0 is 50.000 ohm (D in 1 mohm), range 1 500.00 ohm
@ (10 mohm), range 2 5.0000 kohm (100 mohm), range 3 50.000 kohm (1 ohm) (decimal_position_for_mode_range row 9; full
@ scale 50000 counts).  W = R / R0 in ppm is then D x 10^range x 10 for a Pt100 (1 mohm = 10 ppm of 100 ohm) and
@ D x 10^range for a Pt1000 (1 mohm = 1 ppm of 1000 ohm).  The temperature is the linear interpolation of W in the table
@ mtmp_rtd_tab (mtmp/rtd_table.s: W at every 5 degC from -200 to 850 degC, IEC 60751), in 0.01 degC rounded half away
@ from zero, converted to degF by fn_08013B76 when degF is selected, then rounded to 0.1 degree half
@ away from zero as TEMP does (fn_08007840, OF-21).  Largest conversion error, every 0.01 ohm of a Pt100: 0.0074 degC
@ before the rounding to 0.1 (rtd_table.s).
@ The temperatures shown are -200.0 .. 850.0 degC: a W just outside the table is extrapolated from the first or last
@ interval, and kept when it rounds into that span (-200.04 .. 850.04 degC in 0.01 degC; a Pt100 at exactly -200 degC
@ reads 18.520 ohm, W = 185200 ppm, one ppm below the first entry).
@ Outside that span (or in range 4 and above) the main display shows " OFL " above it and "-OFL" below it;
@ the reading itself is not an overload (the OL flag is not touched).  A real overload shows the v2.05 OFL (the overload
@ path of fn_08016E08 comes first).
@ 2-wire measurement: the lead resistance adds to R (0.1 ohm on a Pt100 is about 0.26 degC).  REL subtracts it: with REL
@ on the view stays and converts D = R - base.  REL fixes the range (keys_setup.md 2), so the range of the sensor is
@ selected with RANGE before the leads are shorted and REL is pressed (Pt100: 500.00 ohm, Pt1000: 5.0000 kohm).  With REL
@ in percent (SETUP rEL-P) the REL percent view is shown instead (it comes first).
@ When the view is shown: OHM, setting not off, outside calibration mode, not while logging (0x20007FE1) and not in the
@ MEM view (0x20007FE4), as the current-loop view (ui/loop.s).  Only the main display changes: D, logging, MIN/MAX and
@ the BLE frame keep the resistance in counts (the BLE value 0x20007D70 is set to D, as ui_relpct_draw does).  While it
@ is shown, the unit and prefix signs are off and degC or degF is on (ui_relpct_mask).  Nothing is drawn while HOLD is
@ active (the held display stays, as the D draw of v2.05).
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


    .equ UI_RTD_MODE_OHM,     9
    .equ UI_RTD_RANGE_MAX,    3             @ 50.000 kohm: the highest range converted
    .equ UI_RTD_T_LO,         -20000        @ first table entry: -200.00 degC
    .equ UI_RTD_T_STEP,       500           @ table step: 5.00 degC
    .equ UI_RTD_T_MIN,        -20004        @ lowest temperature shown: -200.04 degC rounds to -200.0
    .equ UI_RTD_T_MAX,        85004         @ highest: 850.04 degC rounds to 850.0
    .equ ui_rtd_reading,      v_20007D64    @ displayed reading D (counts)
    .equ ui_rtd_last_drawn,   v_20007D70    @ last drawn main value, the BLE value
    .equ ui_rtd_unit_c,       v_200080AB    @ temperature unit: non-zero degC, 0 degF

    .section .text.ui.rtd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ui_rtd_view - is the RTD temperature view shown?
@ Out      : r0 = 1 shown, 0 not
@ Clobbers : r1, flags
@ Context  : main only (fn_08016E08, ui_relpct_mask)
@ -----------------------------------------------------------------------------
FUNC ui_rtd_view
    ldr r0, =set_rtd_code
    ldrb r0, [r0]
    cbz r0, 1f                              @ setting off
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #UI_RTD_MODE_OHM
    bne 2f                                  @ only OHM
    ldr r1, =v_2000808A
    ldrb r1, [r1]
    cbnz r1, 2f                             @ calibration mode: the resistance
    ldr r1, =v_20007FE1
    ldrb r1, [r1]
    cbnz r1, 2f                             @ logging
    ldr r1, =v_20007FE4
    ldrb r1, [r1]
    cbnz r1, 2f                             @ MEM view
    movs r0, #1
    bx lr
2:  movs r0, #0
1:  bx lr
ENDFUNC ui_rtd_view

@ -----------------------------------------------------------------------------
@ ui_rtd_draw - draw the RTD temperature on the main display
@ Replaces : for the RTD view, the draw of D in fn_08016E08 (0x0801702E..0x08017090)
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main only (fn_08016E08, only while ui_rtd_view = 1, no overload)
@ -----------------------------------------------------------------------------
FUNC ui_rtd_draw
    push {r4-r6, lr}
    ldr r0, =hold_active
    ldrb r0, [r0]
    cmp r0, #0
    bne 9f                                  @ HOLD: the held display stays
    ldr r0, =ui_rtd_reading
    ldr r4, [r0]                            @ r4 = D
    ldr r0, =meter_range
    ldrb r0, [r0]
    cmp r0, #UI_RTD_RANGE_MAX
    bhi .Lrd_over                           @ above 50 kohm: above every sensor temperature
    movs r1, #10
1:  cbz r0, 2f
    muls r4, r1, r4                         @ x 10 per range: D in 1 mohm (|D| <= 55000 x 1000)
    subs r0, r0, #1
    b 1b
2:  ldr r0, =set_rtd_code
    ldrb r0, [r0]
    cmp r0, #1
    bne 3f
    muls r4, r1, r4                         @ Pt100: 1 mohm = 10 ppm of R0 (|W| <= 5.5e8)
3:  ldr r5, =mtmp_rtd_tab                   @ r4 = W in ppm; r5 = &W[k] of the interval used
    ldr r0, [r5]
    cmp r4, r0
    bge 4f
    ldr r2, [r5, #4]                        @ below W[0]: the first interval, extended down by one step at most
    subs r2, r2, r0
    subs r2, r0, r2                         @ W[0] - (W[1] - W[0])
    cmp r4, r2
    blt .Lrd_under                          @ below -205 degC (also a negative D after REL)
    b 5f
4:  ldr r1, =mtmp_rtd_end
    ldr r0, [r1, #-4]                       @ last entry
    cmp r4, r0
    ble 6f
    ldr r2, [r1, #-8]                       @ above it: the last interval, extended up by one step at most
    subs r2, r0, r2
    adds r2, r0, r2
    cmp r4, r2
    bgt .Lrd_over                           @ above 855 degC
    sub r5, r1, #8
    b 5f
6:  ldr r2, [r5, #4]                        @ W[k + 1]
    cmp r4, r2
    ble 5f                                  @ W[k] <= W <= W[k + 1] (ends at the last interval: W <= last entry)
    adds r5, r5, #4
    b 6b
5:  ldr r0, [r5]                            @ W[k]
    ldr r2, [r5, #4]
    subs r2, r2, r0                         @ d = W[k + 1] - W[k] (> 0: the table rises strictly)
    subs r4, r4, r0                         @ W - W[k] (-d .. 2d)
    movw r1, #UI_RTD_T_STEP
    muls r4, r1, r4                         @ x 500 (0.01 degC per 5 degC step; |x| < 2^31)
    cmp r4, #0
    ite ge
    addge r4, r4, r2, lsr #1                @ + d / 2 ...
    sublt r4, r4, r2, lsr #1                @ ... or - d / 2: rounds half away from zero
    sdiv r4, r4, r2
    ldr r0, =mtmp_rtd_tab
    subs r6, r5, r0
    lsrs r6, r6, #2                         @ k
    mla r4, r6, r1, r4                      @ + 500 k
    ldr r0, =UI_RTD_T_LO
    adds r4, r4, r0                         @ T in 0.01 degC
    ldr r0, =UI_RTD_T_MIN
    cmp r4, r0
    blt .Lrd_under                          @ would show below -200.0
    ldr r0, =UI_RTD_T_MAX
    cmp r4, r0
    bgt .Lrd_over                           @ would show above 850.0
    ldr r0, =ui_rtd_unit_c
    ldrb r0, [r0]
    cbnz r0, 6f
    mov r0, r4
    bl fn_08013B76                          @ degF in 0.01 degree
    mov r4, r0
6:  cmp r4, #0                              @ 0.1 degree, half away from zero on the hundredths (as fn_08007840, OF-21)
    ite ge
    addge r4, r4, #5
    sublt r4, r4, #5
    movs r0, #10
    sdiv r2, r4, r0
    movs r1, #1                             @ one decimal
    movs r3, #1                             @ skip while hold is active, as the D draw (0x0801707C)
    ldr r0, =meter_mode
    ldrb r0, [r0]
    bl lcd_show_value_pos5_9
    b .Lrd_store
    @ outside the table: " OFL " above, "-OFL" below (the reading is valid: the OL flag is not touched)
.Lrd_under:
    movs r5, #1
    b 7f
.Lrd_over:
    movs r5, #0
7:  movs r0, #0
    bl fn_080199B4                          @ " OFL " on the main display (its minus sign follows 0x20008045 ...)
    movs r0, #0
    bl fn_0801717E                          @ main decimal point: none
    ldr r1, =lcd_shadow
    ldr r0, [r1, #12]
    bic r0, r0, #0x80                       @ ... so w3 b7, the main minus, is set here: off above ...
    cbz r5, 8f
    orr r0, r0, #0x80                       @ ... on below
8:  str r0, [r1, #12]
.Lrd_store:
    ldr r0, =ui_rtd_reading
    ldr r0, [r0]
    ldr r1, =ui_rtd_last_drawn
    str r0, [r1]                            @ the BLE frame keeps reporting the resistance in counts
    movs r0, #1
    ldr r1, =v_2000805B
    strb r0, [r1]                           @ commit request (the OFL drawer does not set it itself)
9:  pop {r4-r6, pc}
ENDFUNC ui_rtd_draw

    .ltorg

