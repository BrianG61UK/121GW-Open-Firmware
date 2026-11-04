@ =============================================================================
@ loop.s - UI: the current-loop percent view of DCmA (production image only, DESIGN.md 10 IMP-24, FEATURES.md 2.14)
@
@ With the SETUP page LP (set/lp.s) at 4..20 or 0..20 mA, DCmA (mode 19) shows on the main display the percent of the loop
@ span instead of the current:
@     4..20 mA:  p = (I - 4 mA) / 16 mA x 100 %       0..20 mA:  p = I / 20 mA x 100 %
@ with two decimals (0.01 %), rounded half away from zero once from the exact quotient.  I is taken in 0.1 uA from the
@ displayed reading D: DCmA range 0 is 5.0000 mA (D in 0.1 uA), range 1 is 50.000 mA (D in 1 uA, x 10)
@ (analysis/hy3131_modes_ac_current.md 7.6, full scale table: 50000 counts, 4 / 3 decimals).  Below 4 mA the percent is
@ negative (-25.00 % at 0 mA), up to 55 mA it stays within five digits (318.75 %).  An overload shows OFL as v2.05 (the
@ overload path of fn_08016E08 comes first).
@ When the view is shown: DCmA, setting not off, REL off (REL keeps its own display and its percent view), outside
@ calibration mode (0x2000808A), not with
@ 0x20007FE1 / 0x20007FE4 (as the REL sign).  Only the main display changes: D, logging, MIN/MAX and the BLE frame keep
@ the current in counts (the BLE value 0x20007D70 is set to D, as ui_relpct_draw does).  While it is shown the unit and
@ prefix signs are off and the % sign is on (ui_relpct_mask applies the same mask for either view).  Nothing is drawn while
@ HOLD is active (the held display stays, as the D draw of v2.05).
@
@ Not present in the strict image (LOOP_V205 = 1): this file assembles to nothing there.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .if LOOP_V205 == 0

    .equ UI_LP_MODE_DCMA,     19
    .equ ui_lp_reading,       v_20007D64    @ displayed reading D (counts)
    .equ ui_lp_last_drawn,    v_20007D70    @ last drawn main value, the BLE value

    .section .text.ui.loop, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ui_loop_view - is the loop percent view shown?
@ Out      : r0 = 1 shown, 0 not
@ Clobbers : r1, flags
@ Context  : main only (fn_08016E08, ui_relpct_mask)
@ -----------------------------------------------------------------------------
FUNC ui_loop_view
    ldr r0, =set_lp_code
    ldrb r0, [r0]
    cbz r0, 1f                              @ setting off
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #UI_LP_MODE_DCMA
    bne 2f                                  @ only DCmA
    ldr r0, =rel_active
    ldrb r0, [r0]
    cbnz r0, 2f                             @ REL keeps its own display
    ldr r1, =v_2000808A
    ldrb r1, [r1]
    cbnz r1, 2f                             @ calibration mode: the current
    ldr r1, =v_20007FE1
    ldrb r1, [r1]
    cbnz r1, 2f
    ldr r1, =v_20007FE4
    ldrb r1, [r1]
    cbnz r1, 2f                             @ MEM view
    movs r0, #1
    bx lr
2:  movs r0, #0
1:  bx lr
ENDFUNC ui_loop_view

@ -----------------------------------------------------------------------------
@ ui_loop_draw - draw the loop percent on the main display
@ Replaces : for the loop view, the draw of D in fn_08016E08 (0x0801702E..0x08017090)
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main only (fn_08016E08, only while ui_loop_view = 1, no overload)
@ -----------------------------------------------------------------------------
FUNC ui_loop_draw
    push {r4-r6, lr}
    ldr r0, =hold_active
    ldrb r0, [r0]
    cmp r0, #0
    bne 9f                                  @ HOLD: the held display stays
    ldr r0, =ui_lp_reading
    ldr r4, [r0]                            @ r4 = D
    ldr r0, =meter_range
    ldrb r0, [r0]
    cbz r0, 1f                              @ range 0: D in 0.1 uA
    add r4, r4, r4, lsl #2
    lsls r4, r4, #1                         @ range 1: D in 1 uA, x 10 -> 0.1 uA
1:  ldr r0, =set_lp_code
    ldrb r0, [r0]
    cmp r0, #1
    bne 2f
    ldr r1, =40000
    subs r4, r4, r1                         @ 4..20 mA: I - 4 mA ...
    movs r5, #16                            @ ... / 16 (160000 x 0.1 uA = 100.00 % = 10000)
    b 3f
2:  movs r5, #20                            @ 0..20 mA: I / 20 (200000 x 0.1 uA = 10000)
3:  movs r6, #0                             @ r6 = 1: negative
    cmp r4, #0
    bge 4f
    negs r4, r4
    movs r6, #1
4:  lsrs r0, r5, #1
    adds r4, r4, r0                         @ + divisor / 2: rounds half away from zero (magnitude)
    udiv r2, r4, r5                         @ |p| in 0.01 %
    cbz r6, 5f
    negs r2, r2
5:  movs r1, #2                             @ two decimals
    movs r3, #1                             @ skip while hold is active, as the D draw (0x0801707C)
    ldr r0, =meter_mode
    ldrb r0, [r0]
    bl lcd_show_value_pos5_9
    ldr r0, =ui_lp_reading
    ldr r0, [r0]
    ldr r1, =ui_lp_last_drawn
    str r0, [r1]                            @ the BLE frame keeps reporting the current in counts
    movs r0, #1
    ldr r1, =v_2000805B
    strb r0, [r1]                           @ commit request
9:  pop {r4-r6, pc}
ENDFUNC ui_loop_draw

    .ltorg

    .endif
