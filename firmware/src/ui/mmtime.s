@ =============================================================================
@ mmtime.s - UI: the time of the MIN/MAX maximum and minimum, pages tHI and tLo (production image only, FEATURES.md 2.6,
@ DESIGN.md 10 IMP-21)
@
@ While MIN/MAX is on, fn_0800E604 calls ui_mmt_mark whenever it changes the maximum or the minimum: a reading above the
@ maximum or below the minimum (the first reading sets both), and an overload, which sets the maximum to +100000 or the
@ minimum to -100000 (v2.05, whatever the register held): the time is kept when the register was not that value already,
@ so the time of the first overload stays.  The hour
@ and minute come from the clock chip copy rtc_hour / rtc_minute (0x200080DA / 0x200080DB, read every 100 ms); RAM only.
@ Setup item 34, page tHI: the sub display shows "tHI", the main display the hour and minute of the maximum, "HH-MM" as page
@ 7 shows the clock (24-hour, or 12-hour with the SETUP page CL: hour 1..12, tens blank when 0, no AM/PM mark).  Item 35,
@ page tLo: the same for the minimum.  "-----" before the extreme has a value (no reading since MIN/MAX was switched on:
@ the maximum still holds the smallest s32, the minimum the largest, fn_08015974).  The main draw takes the place of the
@ value draw of fn_08016E08 at both of its sites: the reading (also during an overload, where v2.05 draws "OFL" and clears
@ the overload flag; the flag is still cleared) and the held display (nothing is drawn while HOLD is active, as the page Sd).
@ The pages follow Sd (item 33) and exist only while MIN/MAX is on (set/setup.s, ui_stats_tick, ui_stats_page).
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


    .equ UI_MMT_ITEM_HI,      34            @ setup item of the page tHI
    .equ UI_MMT_ITEM_LO,      35            @ setup item of the page tLo
    .equ ui_mmt_rtc_hour,     v_200080DA    @ hour 0..23 of the clock chip (rtc/datetime.s rtc_hour)
    .equ ui_mmt_rtc_minute,   v_200080DB    @ minute 0..59 (rtc_minute)
    .equ ui_mmt_max,          v_20007D88    @ MIN/MAX maximum (func_mm_max), 0x80000000 = no reading yet
    .equ ui_mmt_min,          v_20007D8C    @ MIN/MAX minimum (func_mm_min), 0x7FFFFFFF = no reading yet
    .equ ui_mmt_reading,      v_20007D64    @ displayed value D (counts)
    .equ ui_mmt_last_drawn,   v_20007D70    @ last drawn main value, the BLE value

    .section .bss_port.ui, "aw", %nobits
ui_mmt_hm:      .space 4                    @ hour, minute of the maximum; hour, minute of the minimum
ui_mmt_text:    .space 6                    @ "HH-MM" and a terminating zero

    .section .text.ui.mmtime, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ui_mmt_mark - a new extreme has been recorded: keep the time
@ In       : r0 = 0 maximum, 1 minimum
@ Clobbers : r0-r2, flags (r3, r4 untouched: fn_0800E604 keeps the reading in r4)
@ Context  : main only (fn_0800E604)
@ -----------------------------------------------------------------------------
FUNC ui_mmt_mark
    ldr r1, =ui_mmt_hm
    add r1, r1, r0, lsl #1                  @ r1 = &hour of the extreme
    ldr r2, =ui_mmt_rtc_hour
    ldrb r0, [r2]
    strb r0, [r1, #0]
    ldrb r0, [r2, #1]                       @ rtc_minute follows rtc_hour (0x200080DB)
    strb r0, [r1, #1]
    bx lr
ENDFUNC ui_mmt_mark

@ -----------------------------------------------------------------------------
@ ui_mmt_view - is a time page shown on the main display?
@ Out      : r0 = 1 while MIN/MAX is on and the page tHI or tLo is selected, else 0
@ Clobbers : r1, flags
@ Context  : main only (fn_08016E08)
@ -----------------------------------------------------------------------------
FUNC ui_mmt_view
    ldr r0, =minmax_state
    ldrb r0, [r0]
    cbz r0, 1f                              @ MIN/MAX off
    ldr r0, =v_20008037
    ldrb r0, [r0]
    sub r0, r0, #UI_MMT_ITEM_HI
    cmp r0, #1
    ite ls
    movls r0, #1                            @ item 34 or 35
    movhi r0, #0
1:  bx lr
ENDFUNC ui_mmt_view

@ -----------------------------------------------------------------------------
@ ui_mmt_draw - draw the time of the maximum (page tHI) or minimum (page tLo) on the main display
@ In       : r0 = 1 the value path of fn_08016E08 (the BLE value 0x20007D70 is set to D, as the value draw sets it),
@            0 the overload path (v2.05 draws "OFL" there and leaves 0x20007D70)
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main only (fn_08016E08, only while ui_mmt_view = 1)
@ RAM      : reads ui_mmt_hm, func_mm_max / func_mm_min, set_clk12, hold_active; writes ui_mmt_text, lcd_shadow, the BLE
@            value (r0 = 1), the commit request
@ -----------------------------------------------------------------------------
FUNC ui_mmt_draw
    push {r4-r6, lr}
    mov r6, r0                              @ r6 = 1: set the BLE value
    ldr r0, =hold_active
    ldrb r0, [r0]
    cmp r0, #0
    bne 9f                                  @ HOLD: the held display stays (as ui_stats_draw)
    bl ui_stats_text_prep                   @ main decimal point and minus sign off
    ldr r0, =v_20008037
    ldrb r0, [r0]
    cmp r0, #UI_MMT_ITEM_HI
    bne 1f
    ldr r1, =ui_mmt_max
    ldr r1, [r1]
    movs r0, #0x80000000
    cmp r1, r0                              @ the maximum still the smallest s32: no reading yet
    beq .Lmmt_none
    ldr r4, =ui_mmt_hm                      @ r4 = &hour, minute of the maximum
    b 2f
1:  ldr r1, =ui_mmt_min
    ldr r1, [r1]
    mvn r0, #0x80000000
    cmp r1, r0                              @ the minimum still the largest s32: no reading yet
    beq .Lmmt_none
    ldr r4, =ui_mmt_hm + 2                  @ r4 = &hour, minute of the minimum
2:  ldrb r0, [r4, #0]                       @ hour 0..23
    ldr r3, =set_clk12
    ldrb r5, [r3]                           @ r5 = 1: 12-hour clock (IMP-13, the rule of fn_080188A0)
    cbz r5, 3f
    cmp r0, #12
    it hs
    subhs r0, r0, #12                       @ 12..23 -> 0..11
    cbnz r0, 3f
    movs r0, #12                            @ 0 -> 12
3:  ldr r3, =ui_mmt_text
    movs r2, #10
    udiv r1, r0, r2                         @ tens of the hour
    mls r0, r1, r2, r0                      @ units of the hour
    adds r1, r1, #'0'
    cbz r5, 4f
    cmp r1, #'0'
    it eq
    moveq r1, #' '                          @ 12-hour: tens blank when 0 (" 2-30")
4:  strb r1, [r3, #0]
    adds r0, r0, #'0'
    strb r0, [r3, #1]
    movs r0, #'-'
    strb r0, [r3, #2]
    ldrb r0, [r4, #1]                       @ minute 0..59
    udiv r1, r0, r2
    mls r0, r1, r2, r0
    adds r1, r1, #'0'
    strb r1, [r3, #3]
    adds r0, r0, #'0'
    strb r0, [r3, #4]
    movs r0, #0
    strb r0, [r3, #5]
    movs r0, #0                             @ main display
    mov r1, r3
    bl lcd_draw_5char
    b .Lmmt_store
.Lmmt_none:
    movs r0, #0
    bl fn_08019A86                          @ "-----" on the main display
.Lmmt_store:
    cbz r6, 8f                              @ overload path: the BLE value stays, as after "OFL"
    ldr r0, =ui_mmt_reading
    ldr r0, [r0]
    ldr r1, =ui_mmt_last_drawn
    str r0, [r1]                            @ the BLE frame keeps reporting the MIN/MAX value in counts
8:  movs r0, #1
    ldr r1, =v_2000805B
    strb r0, [r1]                           @ commit request (the text drawers do not set it)
9:  pop {r4-r6, pc}
ENDFUNC ui_mmt_draw

    .ltorg

