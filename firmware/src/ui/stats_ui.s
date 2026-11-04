@ =============================================================================
@ stats_ui.s - UI: the statistics pages n and Sd while MIN/MAX is on (production image only, DESIGN.md 10 IMP-14,
@ FEATURES.md 2.7)
@
@ Setup item 32, page n: the number of readings in the statistics (func/stats.s) on the sub display: "n" and the count
@ right-aligned up to 9999 ("n  42", "n1234"); from 10000 the count in thousands with the sub k sign (w4b17, the sign of
@ the frequency pages): "n  12" k .. "n1000" k (the count stops at 1 000 000).
@ Setup item 33, page Sd: the sub display shows "Sd" ('S' is drawn like 5); the main display shows the sample standard
@ deviation of the readings in the unit, range and decimal point of the reading, with one more decimal when the range
@ allows (decimal point code below 4 and the value at most 99999), rounded to nearest; "-----" for fewer than two
@ readings, " OFL " above 99999 counts.  The BLE value 0x20007D70 keeps the MIN/MAX value in counts (as ui_relpct_draw).
@ The pages exist only while MIN/MAX is on (minmax_state != 0): the dispatcher (set/setup.s .Lsd_port) sends an item 32
@ or 33 back to item 0 when MIN/MAX has ended (by its key, HOLD or a mode change), and SETUP short reaches them only
@ while MIN/MAX is on.  Switching MIN/MAX on shows page n (fn_08015974).  The time pages tHI (34) and tLo (35) of
@ ui/mmtime.s follow Sd and share this gating, the redraw request and the sub display drawer (labels "tHI", "tLo").
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


    .equ UI_ST_ITEM_N,        32            @ setup item of the page n
    .equ UI_ST_ITEM_SD,       33            @ setup item of the page Sd
    .equ UI_ST_ITEM_THI,      34            @ setup item of the page tHI (ui/mmtime.s, IMP-21)
    .equ UI_ST_ITEM_TLO,      35            @ setup item of the page tLo
    .equ UI_ST_SUBK,          0x00020000    @ lcd_shadow word 4 bit 17: sub k sign
    .equ ui_st_text5,         v_20007C30    @ 5-character text buffer
    .equ ui_st_reading,       v_20007D64    @ displayed value D (counts)
    .equ ui_st_last_drawn,    v_20007D70    @ last drawn main value, the BLE value
    .equ ui_st_dp,            v_2000803F    @ decimal-point position of the reading (0..4)

    .section .text.ui.stats, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ui_stats_view - is the standard deviation shown on the main display?
@ Out      : r0 = 1 while MIN/MAX is on and the page Sd is selected, else 0
@ Clobbers : r1, flags
@ Context  : main only (fn_08016E08)
@ -----------------------------------------------------------------------------
FUNC ui_stats_view
    ldr r0, =minmax_state
    ldrb r0, [r0]
    cbz r0, 1f                              @ MIN/MAX off
    ldr r0, =v_20008037
    ldrb r0, [r0]
    cmp r0, #UI_ST_ITEM_SD
    ite eq
    moveq r0, #1
    movne r0, #0
1:  bx lr
ENDFUNC ui_stats_view

@ -----------------------------------------------------------------------------
@ ui_stats_tick - request a sub display redraw while a statistics page or a time page (tHI, tLo) is selected
@ Replaces : nothing in v2.05 (new; called at the entry of fn_08016E08, once per new result, overloads included)
@ Clobbers : r0, r1, flags
@ Context  : main only
@ RAM      : reads set_item; writes the sub display redraw request 0x20008062
@ Note     : the redraw shows the new count on page n, and sends either page back to item 0 when MIN/MAX has ended
@            (the dispatcher's test, set/setup.s .Lsd_stats); the redraw is served in the same refresh pass.
@ -----------------------------------------------------------------------------
FUNC ui_stats_tick
    ldr r0, =v_20008037
    ldrb r0, [r0]
    sub r0, r0, #UI_ST_ITEM_N
    cmp r0, #UI_ST_ITEM_TLO - UI_ST_ITEM_N
    bhi 1f                                  @ none of the items 32..35
    movs r0, #1
    ldr r1, =v_20008062
    strb r0, [r1]                           @ sub display redraw
1:  bx lr
ENDFUNC ui_stats_tick

@ -----------------------------------------------------------------------------
@ ui_stats_text_prep - main decimal point and minus sign off before a text replaces the digits
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ui_stats_text_prep
    push {r4, lr}
    movs r0, #0
    bl fn_0801717E                          @ main decimal point: none
    ldr r1, =lcd_shadow
    ldr r0, [r1, #12]
    bic r0, r0, #0x80                       @ w3 b7: main minus off
    str r0, [r1, #12]
    pop {r4, pc}
ENDFUNC ui_stats_text_prep

@ -----------------------------------------------------------------------------
@ ui_stats_draw - draw the standard deviation on the main display
@ Replaces : for the page Sd, the draw of D in fn_08016E08 (0x0801702E..0x08017090)
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Context  : main only (fn_08016E08, only while ui_stats_view = 1, no overload)
@ RAM      : reads func_stats_*, ui_st_dp, hold_active, meter_mode; writes lcd_shadow (drawers), ui_st_last_drawn,
@            commit request
@ Note     : nothing is drawn while HOLD is active (the texts as the digits: lcd_show_value_pos5_9 skips with r3 = 1).
@            q = round(sigma * 10) with decimal point code + 1 when the code is below 4 and q <= 99999; else
@            q = round(sigma) with the code of the reading; q > 99999: " OFL ".  Rounding: binary32 sigma (>= 0) + 0.5,
@            truncated (fn_08013370); the binary32 value is exact to 1 part in 2^24.
@ -----------------------------------------------------------------------------
FUNC ui_stats_draw
    push {r4-r7, lr}
    sub sp, #4
    ldr r0, =hold_active
    ldrb r0, [r0]
    cbnz r0, 3f                             @ HOLD: the held display stays, as lcd_show_value_pos5_9 skips (r3 = 1)
    bl func_stats_sd_float                  @ r0 = 1 and r1 = sigma (binary32), or r0 = 0
    cbnz r0, 1f
    bl ui_stats_text_prep                   @ fewer than two readings
    movs r0, #0
    bl fn_08019A86                          @ "-----" on the main display
    b .Lsdw_store
1:  mov r4, r1                              @ r4 = sigma
    ldr r0, =ui_st_dp
    ldrb r5, [r0]                           @ r5 = decimal point code of the reading
    cmp r5, #4
    bhs .Lsdw_plain                         @ no room for one more decimal
    mov r0, r4
    ldr r1, =0x41200000                     @ 10.0f
    bl fn_08013090                          @ sigma * 10
    ldr r1, =0x3F000000                     @ 0.5f
    bl fn_080132EC                          @ + 0.5
    bl fn_08013370                          @ truncate: round(sigma * 10)
    ldr r1, =99999
    cmp r0, r1
    bhi .Lsdw_plain                         @ too large with one more decimal
    mov r2, r0
    adds r1, r5, #1                         @ one more decimal
    b .Lsdw_draw
.Lsdw_plain:
    mov r0, r4
    ldr r1, =0x3F000000                     @ 0.5f
    bl fn_080132EC                          @ sigma + 0.5
    bl fn_08013370                          @ truncate: round(sigma)
    ldr r1, =99999
    cmp r0, r1
    bls 2f
    bl ui_stats_text_prep                   @ above 99999 counts
    movs r0, #0
    bl fn_080199B4                          @ " OFL " (the OL flag is not touched)
    b .Lsdw_store
2:  mov r2, r0
    mov r1, r5
.Lsdw_draw:
    movs r3, #1                             @ skip while hold is active, as the D draw (0x0801707C)
    ldr r0, =meter_mode
    ldrb r0, [r0]
    bl lcd_show_value_pos5_9                @ sigma, not negative: the minus sign is cleared by the drawer
.Lsdw_store:
    ldr r0, =hold_active
    ldrb r0, [r0]
    cbnz r0, 3f                             @ held: nothing drawn, the BLE value stays
    ldr r0, =ui_st_reading
    ldr r0, [r0]
    ldr r1, =ui_st_last_drawn
    str r0, [r1]                            @ the BLE frame keeps reporting the MIN/MAX value in counts
    movs r0, #1
    ldr r1, =v_2000805B
    strb r0, [r1]                           @ commit request (the text drawers do not set it)
3:  add sp, #4
    pop {r4-r7, pc}
ENDFUNC ui_stats_draw

@ -----------------------------------------------------------------------------
@ ui_stats_page - draw the sub display of the page n (item 32), Sd (item 33), tHI (34) or tLo (35)
@ In       : r0 = item (32..35)
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main only (fn_0801797C)
@ RAM      : reads func_stats_n; writes lcd_shadow (sub minus, decimal points, k sign, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC ui_stats_page
    push {r4-r6, lr}
    mov r6, r0                              @ r6 = item
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    bic r1, r1, #UI_ST_SUBK                 @ sub k off (set below for a count in thousands)
    str r1, [r0, #0x10]
    movs r0, #0
    bl fn_08017FB4                          @ sub decimal points off
    ldr r4, =ui_st_text5
    cmp r6, #UI_ST_ITEM_THI
    blo 5f
    movs r0, #'t'                           @ pages tHI / tLo (IMP-21): "tHI  " / "tLo  "
    strb r0, [r4, #0]
    cmp r6, #UI_ST_ITEM_THI
    ite eq
    moveq r0, #'H'
    movne r0, #'L'
    strb r0, [r4, #1]
    ite eq
    moveq r0, #'I'
    movne r0, #'o'
    strb r0, [r4, #2]
    movs r0, #' '
    strb r0, [r4, #3]
    strb r0, [r4, #4]
    b .Lsp_draw
5:  cmp r6, #UI_ST_ITEM_SD
    bne .Lsp_n
    movs r0, #'S'                           @ page Sd: "Sd   "
    strb r0, [r4, #0]
    movs r0, #'d'
    strb r0, [r4, #1]
    movs r0, #' '
    strb r0, [r4, #2]
    strb r0, [r4, #3]
    strb r0, [r4, #4]
    b .Lsp_draw
.Lsp_n:
    ldr r0, =func_stats_n
    ldr r5, [r0]                            @ r5 = count
    movw r0, #9999
    cmp r5, r0
    bls 1f
    movw r0, #1000
    udiv r5, r5, r0                         @ thousands (10 .. 1000)
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    orr r1, r1, #UI_ST_SUBK                 @ sub k sign
    str r1, [r0, #0x10]
1:  movs r0, #'n'
    strb r0, [r4, #0]
    movs r1, #4                             @ characters 4 .. 1: the count right-aligned, leading zeros blank
    movs r2, #10
2:  udiv r3, r5, r2
    mls r12, r3, r2, r5                     @ r12 = last digit
    cmp r1, #4
    beq 3f                                  @ the units digit is always drawn
    cbnz r5, 3f
    movs r0, #' '                           @ no more digits: blank
    b 4f
3:  add r0, r12, #'0'
4:  strb r0, [r4, r1]
    mov r5, r3
    subs r1, r1, #1
    bne 2b
.Lsp_draw:
    movs r0, #1                             @ sub display
    mov r1, r4
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =v_2000805B
    strb r0, [r1]                           @ commit the shadow
    pop {r4-r6, pc}
ENDFUNC ui_stats_page

    .ltorg

