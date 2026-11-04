@ =============================================================================
@ datetime.s - RTC: date/time editing and pages
@
@ RTC module, part 2: date and time editing (setup items 5, 6, 7), the date/time pages and the blink request.
@
@ Replaces the v2.05 routines 0x08015C94, 0x08015D40, 0x08015E74, 0x08015F44, 0x08018788, 0x080187D8,
@ 0x080188A0, 0x0801896C (analysis/keys_setup.md 4).  OF-41/NF-11: the TIM2 handler no longer draws page 7; it
@ sets rtc_blink_request and the main loop calls fn_0801896C(1) (DESIGN.md 3.4, 3.5 step 4).
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

@ Module-local names of v2.05 RAM variables (address = the v_XXXXXXXX symbol of ram_v205.inc)
    .equ rtc_text5,             v_20007C30   @ 5-character text buffer drawn on the secondary display by lcd_draw_5char(1, ...)
    .equ rtc_lcd_digit1,        v_20007DBC   @ digit word d1 (tens)
    .equ rtc_lcd_digit0,        v_20007DC0   @ digit word d0 (units)
    .equ rtc_date_code,         v_20007F9A   @ date code YYMM, u16, EEPROM 0x001 (default 1708)
    .equ rtc_commit_req,        v_2000805B   @ LCD commit request (set instead of committing immediately)
    .equ rtc_redraw,            v_20008062   @ secondary display redraw request
    .equ rtc_edit,              v_2000806E   @ setup edit mode active (toggled by long SETUP)
    .equ rtc_date_edit_en,      v_2000808B   @ SETUP pressed in the power-on window: date-code editing enabled
    .equ rtc_blink_phase,       v_200080D5   @ setup page 7 blink phase, toggled by the TIM2 handler
    .equ rtc_stage,             v_200080D6   @ date/time edit stage: 0 = month or hour, 1 = day or minute
    .equ rtc_year,              v_200080D7   @ year 0..99 (BCD-converted NJU6350 register 2)
    .equ rtc_month,             v_200080D8   @ month 1..12 (register 4)
    .equ rtc_day,               v_200080D9   @ day 1..31 (register 6)
    .equ rtc_hour,              v_200080DA   @ hour 0..23 (register 10)
    .equ rtc_minute,            v_200080DB   @ minute 0..59 (register 12)
    .equ rtc_year_edit,         v_200080DD   @ year edit buffer (item 5)
    .equ rtc_month_edit,        v_200080DE   @ month edit buffer (item 6)
    .equ rtc_day_edit,          v_200080DF   @ day edit buffer (item 6)
    .equ rtc_hour_edit,         v_200080E0   @ hour edit buffer (item 7)
    .equ rtc_minute_edit,       v_200080E1   @ minute edit buffer (item 7)

    .section .bss_port.rtc, "aw", %nobits
@ rtc_blink_request: set by sys_tim2_isr every blink period while setup item 7 is shown (OF-41/NF-11); the main
@ loop clears it and redraws the page with fn_0801896C(1).  Byte, owner RTC.
    .global rtc_blink_request
rtc_blink_request:
    .space 1

    .section .text.rtc, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08015C94 - setup item 5 (year) edit action
@ Replaces : 0x08015C94 FUN_08015C94 (v2.05)
@ In       : r0 = action: 1 up, 2 down, anything else (100) save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads rtc_month; writes rtc_day, rtc_redraw, rtc_year, rtc_year_edit
@ Spec     : analysis/keys_setup.md 4 item 5; DESIGN.md 6.25
@ Note     : Up and down change the edit buffer rtc_year_edit 0..99 with wrap.  Save copies it to rtc_year, limits the
@            day to the new month length (fn_080103A8), writes the clock (fn_0801016C) and, if SETUP was pressed in
@            the power-on window, stores the date code (fn_08015F44).  Sets the redraw request.
@ -----------------------------------------------------------------------------
FUNC fn_08015C94
    push {r4, lr}                           @ 08015C94
    movs r4, r0                             @ 08015C96
    uxtb r4, r4                             @ 08015C98
    cmp r4, #0x1                            @ 08015C9A  compare r4 with 1
    bne .L08015CC0                          @ 08015C9C  if r4 != 1
    ldr.w r0, =rtc_year_edit                @ 08015C9E
    ldrb r0, [r0, #0x0]                     @ 08015CA2  r0 = rtc_year_edit
    adds r0, r0, #0x1                       @ 08015CA4  r0 = rtc_year_edit + 1
    ldr.w r1, =rtc_year_edit                @ 08015CA6
    strb r0, [r1, #0x0]                     @ 08015CAA  rtc_year_edit = (rtc_year_edit + 1)
    ldr.w r0, =rtc_year_edit                @ 08015CAC
    ldrb r0, [r0, #0x0]                     @ 08015CB0  r0 = rtc_year_edit
    cmp r0, #0x64                           @ 08015CB2  compare rtc_year_edit with 100 (0x64)
    blt .L08015D1A                          @ 08015CB4  if rtc_year_edit <s 100 (0x64)
    movs r0, #0x0                           @ 08015CB6
    ldr.w r1, =rtc_year_edit                @ 08015CB8
    strb r0, [r1, #0x0]                     @ 08015CBC  rtc_year_edit = 0
    b .L08015D1A                            @ 08015CBE
.L08015CC0:  @ reached from 08015C9C bne (r4 != 1)
    uxtb r4, r4                             @ 08015CC0
    cmp r4, #0x2                            @ 08015CC2  compare r4 with 2
    bne .L08015CEA                          @ 08015CC4  if r4 != 2
    ldr.w r0, =rtc_year_edit                @ 08015CC6
    ldrb r0, [r0, #0x0]                     @ 08015CCA  r0 = rtc_year_edit
    cmp r0, #0x0                            @ 08015CCC  compare rtc_year_edit with 0
    bne .L08015CDA                          @ 08015CCE  if rtc_year_edit != 0
    movs r0, #0x63                          @ 08015CD0
    ldr.w r1, =rtc_year_edit                @ 08015CD2
    strb r0, [r1, #0x0]                     @ 08015CD6  rtc_year_edit = 99 (0x63)
    b .L08015D1A                            @ 08015CD8
.L08015CDA:  @ reached from 08015CCE bne (rtc_year_edit != 0)
    ldr.w r0, =rtc_year_edit                @ 08015CDA
    ldrb r0, [r0, #0x0]                     @ 08015CDE  r0 = rtc_year_edit
    subs r0, r0, #0x1                       @ 08015CE0  r0 = rtc_year_edit - 1
    ldr.w r1, =rtc_year_edit                @ 08015CE2
    strb r0, [r1, #0x0]                     @ 08015CE6  rtc_year_edit = (rtc_year_edit - 1)
    b .L08015D1A                            @ 08015CE8
.L08015CEA:  @ reached from 08015CC4 bne (r4 != 2)
    ldr.w r0, =rtc_year_edit                @ 08015CEA
    ldrb r0, [r0, #0x0]                     @ 08015CEE  r0 = rtc_year_edit
    ldr.w r1, =rtc_year                     @ 08015CF0
    strb r0, [r1, #0x0]                     @ 08015CF4  rtc_year = rtc_year_edit
    ldr.w r0, =rtc_day                      @ 08015CF6
    ldrb r2, [r0, #0x0]                     @ 08015CFA  r2 = rtc_day
    ldr.w r0, =rtc_month                    @ 08015CFC
    ldrb r1, [r0, #0x0]                     @ 08015D00  r1 = rtc_month
    ldr.w r0, =rtc_year                     @ 08015D02
    ldrb r0, [r0, #0x0]                     @ 08015D06  r0 = rtc_year
    bl fn_080103A8                          @ 08015D08  clamp the day to the days of the month [r0=rtc_year, r1=rtc_month, r2=rtc_day]
    ldr.w r1, =rtc_day                      @ 08015D0C
    strb r0, [r1, #0x0]                     @ 08015D10  rtc_day = r0
    bl fn_0801016C                          @ 08015D12  write the six time registers from RAM [r1=&rtc_day]
    bl fn_08015F44                          @ 08015D16  store the date code (only after SETUP in the power-on window)
.L08015D1A:  @ reached from 08015CB4 blt (rtc_year_edit <s 100 (0x64)), 08015CBE b, 08015CD8 b, 08015CE8 b
    movs r0, #0x1                           @ 08015D1A
    ldr.w r1, =rtc_redraw                   @ 08015D1C
    strb r0, [r1, #0x0]                     @ 08015D20  rtc_redraw = 1
    pop {r4, pc}                            @ 08015D22
ENDFUNC fn_08015C94
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015D40 - setup item 6 (month, then day) edit action
@ Replaces : 0x08015D40 FUN_08015D40 (v2.05)
@ In       : r0 = action: 1 up, 2 down, anything else (100) save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads rtc_year; writes rtc_day, rtc_day_edit, rtc_edit, rtc_month, rtc_month_edit, rtc_redraw, rtc_stage
@ Spec     : analysis/keys_setup.md 4 item 6
@ Note     : Stage rtc_stage = 0 edits the month (1..12, wrap), stage 1 the day (1..days of the month, wrap).  The
@            month save writes the clock and the date code (as item 5), moves to stage 1 and sets rtc_edit again, so
@            the day can be edited at once (the editor re-enters edit mode); the day save writes the clock and returns
@            to stage 0.
@ -----------------------------------------------------------------------------
FUNC fn_08015D40
    push {r3, r4, r5, lr}                   @ 08015D40
    movs r4, r0                             @ 08015D42
    ldr.w r0, =rtc_stage                    @ 08015D44
    ldrb r0, [r0, #0x0]                     @ 08015D48  r0 = rtc_stage
    cmp r0, #0x0                            @ 08015D4A  compare rtc_stage with 0
    bne .L08015DD4                          @ 08015D4C  if rtc_stage != 0
    uxtb r4, r4                             @ 08015D4E
    cmp r4, #0x1                            @ 08015D50  compare r4 with 1
    bne .L08015D76                          @ 08015D52  if r4 != 1
    ldr.w r0, =rtc_month_edit               @ 08015D54
    ldrb r0, [r0, #0x0]                     @ 08015D58  r0 = rtc_month_edit
    adds r0, r0, #0x1                       @ 08015D5A  r0 = rtc_month_edit + 1
    ldr.w r1, =rtc_month_edit               @ 08015D5C
    strb r0, [r1, #0x0]                     @ 08015D60  rtc_month_edit = (rtc_month_edit + 1)
    ldr.w r0, =rtc_month_edit               @ 08015D62
    ldrb r0, [r0, #0x0]                     @ 08015D66  r0 = rtc_month_edit
    cmp r0, #0xd                            @ 08015D68  compare rtc_month_edit with 13 (0xD)
    blt .L08015E4C                          @ 08015D6A  if rtc_month_edit <s 13 (0xD)
    movs r0, #0x1                           @ 08015D6C
    ldr.w r1, =rtc_month_edit               @ 08015D6E
    strb r0, [r1, #0x0]                     @ 08015D72  rtc_month_edit = 1
    b .L08015E4C                            @ 08015D74
.L08015D76:  @ reached from 08015D52 bne (r4 != 1)
    uxtb r4, r4                             @ 08015D76
    cmp r4, #0x2                            @ 08015D78  compare r4 with 2
    bne .L08015DA0                          @ 08015D7A  if r4 != 2
    ldr.w r0, =rtc_month_edit               @ 08015D7C
    ldrb r0, [r0, #0x0]                     @ 08015D80  r0 = rtc_month_edit
    cmp r0, #0x2                            @ 08015D82  compare rtc_month_edit with 2
    bge .L08015D90                          @ 08015D84  if rtc_month_edit >=s 2
    movs r0, #0xc                           @ 08015D86
    ldr.w r1, =rtc_month_edit               @ 08015D88
    strb r0, [r1, #0x0]                     @ 08015D8C  rtc_month_edit = 12 (0xC)
    b .L08015E4C                            @ 08015D8E
.L08015D90:  @ reached from 08015D84 bge (rtc_month_edit >=s 2)
    ldr.w r0, =rtc_month_edit               @ 08015D90
    ldrb r0, [r0, #0x0]                     @ 08015D94  r0 = rtc_month_edit
    subs r0, r0, #0x1                       @ 08015D96  r0 = rtc_month_edit - 1
    ldr.w r1, =rtc_month_edit               @ 08015D98
    strb r0, [r1, #0x0]                     @ 08015D9C  rtc_month_edit = (rtc_month_edit - 1)
    b .L08015E4C                            @ 08015D9E
.L08015DA0:  @ reached from 08015D7A bne (r4 != 2)
    ldr.w r0, =rtc_month_edit               @ 08015DA0
    ldrb r0, [r0, #0x0]                     @ 08015DA2  r0 = rtc_month_edit
    ldr.w r1, =rtc_month                    @ 08015DA4
    strb r0, [r1, #0x0]                     @ 08015DA6  rtc_month = rtc_month_edit
    ldr.w r0, =rtc_day                      @ 08015DA8
    ldrb r2, [r0, #0x0]                     @ 08015DAA  r2 = rtc_day
    ldr.w r0, =rtc_month                    @ 08015DAC
    ldrb r1, [r0, #0x0]                     @ 08015DAE  r1 = rtc_month
    ldr.w r0, =rtc_year                     @ 08015DB0
    ldrb r0, [r0, #0x0]                     @ 08015DB2  r0 = rtc_year
    bl fn_080103A8                          @ 08015DB4  clamp the day to the days of the month [r0=rtc_year, r1=rtc_month, r2=rtc_day]
    ldr.w r1, =rtc_day                      @ 08015DB8
    strb r0, [r1, #0x0]                     @ 08015DBA  rtc_day = r0
    bl fn_0801016C                          @ 08015DBC  write the six time registers from RAM [r1=&rtc_day]
    bl fn_08015F44                          @ 08015DC0  store the date code (only after SETUP in the power-on window)
    movs r0, #0x1                           @ 08015DC4
    ldr.w r1, =rtc_stage                    @ 08015DC6
    strb r0, [r1, #0x0]                     @ 08015DC8  rtc_stage = 1
    movs r0, #0x1                           @ 08015DCA
    ldr.w r1, =rtc_edit                     @ 08015DCC
    strb r0, [r1, #0x0]                     @ 08015DD0  rtc_edit = 1
    b .L08015E4C                            @ 08015DD2
.L08015DD4:  @ reached from 08015D4C bne (rtc_stage != 0)
    ldr.w r0, =rtc_month                    @ 08015DD4
    ldrb r1, [r0, #0x0]                     @ 08015DD6  r1 = rtc_month
    ldr.w r0, =rtc_year                     @ 08015DD8
    ldrb r0, [r0, #0x0]                     @ 08015DDA  r0 = rtc_year
    bl fn_080103D8                          @ 08015DDC  days in month (year r0, month r1) [r0=rtc_year, r1=rtc_month]
    movs r5, r0                             @ 08015DE0
    uxtb r4, r4                             @ 08015DE2
    cmp r4, #0x1                            @ 08015DE4  compare r4 with 1
    bne .L08015E06                          @ 08015DE6  if r4 != 1
    ldr.w r0, =rtc_day_edit                 @ 08015DE8
    ldrb r0, [r0, #0x0]                     @ 08015DEA  r0 = rtc_day_edit
    adds r0, r0, #0x1                       @ 08015DEC  r0 = rtc_day_edit + 1
    ldr.w r1, =rtc_day_edit                 @ 08015DEE
    strb r0, [r1, #0x0]                     @ 08015DF0  rtc_day_edit = (rtc_day_edit + 1)
    movs r0, r5                             @ 08015DF2
    ldr.w r1, =rtc_day_edit                 @ 08015DF4
    ldrb r1, [r1, #0x0]                     @ 08015DF6  r1 = rtc_day_edit
    uxtb r0, r0                             @ 08015DF8
    cmp r0, r1                              @ 08015DFA  compare r0 with rtc_day_edit
    bcs .L08015E4C                          @ 08015DFC  if r0 >=u rtc_day_edit
    movs r0, #0x1                           @ 08015DFE
    ldr.w r1, =rtc_day_edit                 @ 08015E00
    strb r0, [r1, #0x0]                     @ 08015E02  rtc_day_edit = 1
    b .L08015E4C                            @ 08015E04
.L08015E06:  @ reached from 08015DE6 bne (r4 != 1)
    uxtb r4, r4                             @ 08015E06
    cmp r4, #0x2                            @ 08015E08  compare r4 with 2
    bne .L08015E26                          @ 08015E0A  if r4 != 2
    ldr.w r0, =rtc_day_edit                 @ 08015E0C
    ldrb r0, [r0, #0x0]                     @ 08015E0E  r0 = rtc_day_edit
    cmp r0, #0x2                            @ 08015E10  compare rtc_day_edit with 2
    bge .L08015E1A                          @ 08015E12  if rtc_day_edit >=s 2
    ldr.w r0, =rtc_day_edit                 @ 08015E14
    strb r5, [r0, #0x0]                     @ 08015E16  rtc_day_edit = r5
    b .L08015E4C                            @ 08015E18
.L08015E1A:  @ reached from 08015E12 bge (rtc_day_edit >=s 2)
    ldr.w r0, =rtc_day_edit                 @ 08015E1A
    ldrb r0, [r0, #0x0]                     @ 08015E1C  r0 = rtc_day_edit
    subs r0, r0, #0x1                       @ 08015E1E  r0 = rtc_day_edit - 1
    ldr.w r1, =rtc_day_edit                 @ 08015E20
    strb r0, [r1, #0x0]                     @ 08015E22  rtc_day_edit = (rtc_day_edit - 1)
    b .L08015E4C                            @ 08015E24
.L08015E26:  @ reached from 08015E0A bne (r4 != 2)
    ldr.w r0, =rtc_day_edit                 @ 08015E26
    ldrb r0, [r0, #0x0]                     @ 08015E28  r0 = rtc_day_edit
    ldr.w r1, =rtc_day                      @ 08015E2A
    strb r0, [r1, #0x0]                     @ 08015E2C  rtc_day = rtc_day_edit
    ldr.w r0, =rtc_day                      @ 08015E2E
    ldrb r2, [r0, #0x0]                     @ 08015E30  r2 = rtc_day
    ldr.w r0, =rtc_month                    @ 08015E32
    ldrb r1, [r0, #0x0]                     @ 08015E34  r1 = rtc_month
    ldr.w r0, =rtc_year                     @ 08015E36
    ldrb r0, [r0, #0x0]                     @ 08015E38  r0 = rtc_year
    bl fn_080103A8                          @ 08015E3A  clamp the day to the days of the month [r0=rtc_year, r1=rtc_month, r2=rtc_day]
    ldr.w r1, =rtc_day                      @ 08015E3E
    strb r0, [r1, #0x0]                     @ 08015E40  rtc_day = r0
    bl fn_0801016C                          @ 08015E42  write the six time registers from RAM [r1=&rtc_day]
    movs r0, #0x0                           @ 08015E46
    ldr.w r1, =rtc_stage                    @ 08015E48
    strb r0, [r1, #0x0]                     @ 08015E4A  rtc_stage = 0
.L08015E4C:  @ reached from 08015D6A blt (rtc_month_edit <s 13 (0xD)), 08015D74 b, 08015D8E b, 08015D9E b, 08015DD2 b, 08015DFC bcs (r0 >=u rtc_day_edit), 08015E04 b, 08015E18 b, 08015E24 b
    movs r0, #0x1                           @ 08015E4C
    ldr.w r1, =rtc_redraw                   @ 08015E4E
    strb r0, [r1, #0x0]                     @ 08015E52  rtc_redraw = 1
    pop {r0, r4, r5, pc}                    @ 08015E54
ENDFUNC fn_08015D40
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015E74 - setup item 7 (hour, then minute) edit action
@ Replaces : 0x08015E74 FUN_08015E74 (v2.05)
@ In       : r0 = action: 1 up, 2 down, anything else (100) save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : writes rtc_edit, rtc_hour, rtc_hour_edit, rtc_minute, rtc_minute_edit, rtc_redraw, rtc_stage
@ Spec     : analysis/keys_setup.md 4 item 7
@ Note     : Stage 0 edits the hour (0..23, wrap), stage 1 the minute (0..59, wrap); each save writes the clock
@            (fn_0801016C); the hour save moves to stage 1 and sets rtc_edit again so the minute can be edited at
@            once.
@ -----------------------------------------------------------------------------
FUNC fn_08015E74
    push {r4, lr}                           @ 08015E74
    movs r4, r0                             @ 08015E76
    ldr.w r0, =rtc_stage                    @ 08015E78
    ldrb r0, [r0, #0x0]                     @ 08015E7A  r0 = rtc_stage
    cmp r0, #0x0                            @ 08015E7C  compare rtc_stage with 0
    bne .L08015EDE                          @ 08015E7E  if rtc_stage != 0
    uxtb r4, r4                             @ 08015E80
    cmp r4, #0x1                            @ 08015E82  compare r4 with 1
    bne .L08015EA0                          @ 08015E84  if r4 != 1
    ldr.w r0, =rtc_hour_edit                @ 08015E86
    ldrb r0, [r0, #0x0]                     @ 08015E88  r0 = rtc_hour_edit
    adds r0, r0, #0x1                       @ 08015E8A  r0 = rtc_hour_edit + 1
    ldr.w r1, =rtc_hour_edit                @ 08015E8C
    strb r0, [r1, #0x0]                     @ 08015E8E  rtc_hour_edit = (rtc_hour_edit + 1)
    ldr.w r0, =rtc_hour_edit                @ 08015E90
    ldrb r0, [r0, #0x0]                     @ 08015E92  r0 = rtc_hour_edit
    cmp r0, #0x18                           @ 08015E94  compare rtc_hour_edit with 24 (0x18)
    blt .L08015F32                          @ 08015E96  if rtc_hour_edit <s 24 (0x18)
    movs r0, #0x0                           @ 08015E98
    ldr.w r1, =rtc_hour_edit                @ 08015E9A
    strb r0, [r1, #0x0]                     @ 08015E9C  rtc_hour_edit = 0
    b .L08015F32                            @ 08015E9E
.L08015EA0:  @ reached from 08015E84 bne (r4 != 1)
    uxtb r4, r4                             @ 08015EA0
    cmp r4, #0x2                            @ 08015EA2  compare r4 with 2
    bne .L08015EC2                          @ 08015EA4  if r4 != 2
    ldr.w r0, =rtc_hour_edit                @ 08015EA6
    ldrb r0, [r0, #0x0]                     @ 08015EA8  r0 = rtc_hour_edit
    cmp r0, #0x0                            @ 08015EAA  compare rtc_hour_edit with 0
    bne .L08015EB6                          @ 08015EAC  if rtc_hour_edit != 0
    movs r0, #0x17                          @ 08015EAE
    ldr.w r1, =rtc_hour_edit                @ 08015EB0
    strb r0, [r1, #0x0]                     @ 08015EB2  rtc_hour_edit = 23 (0x17)
    b .L08015F32                            @ 08015EB4
.L08015EB6:  @ reached from 08015EAC bne (rtc_hour_edit != 0)
    ldr.w r0, =rtc_hour_edit                @ 08015EB6
    ldrb r0, [r0, #0x0]                     @ 08015EB8  r0 = rtc_hour_edit
    subs r0, r0, #0x1                       @ 08015EBA  r0 = rtc_hour_edit - 1
    ldr.w r1, =rtc_hour_edit                @ 08015EBC
    strb r0, [r1, #0x0]                     @ 08015EBE  rtc_hour_edit = (rtc_hour_edit - 1)
    b .L08015F32                            @ 08015EC0
.L08015EC2:  @ reached from 08015EA4 bne (r4 != 2)
    ldr.w r0, =rtc_hour_edit                @ 08015EC2
    ldrb r0, [r0, #0x0]                     @ 08015EC4  r0 = rtc_hour_edit
    ldr.w r1, =rtc_hour                     @ 08015EC6
    strb r0, [r1, #0x0]                     @ 08015EC8  rtc_hour = rtc_hour_edit
    bl fn_0801016C                          @ 08015ECA  write the six time registers from RAM [r0=rtc_hour_edit, r1=&rtc_hour]
    movs r0, #0x1                           @ 08015ECE
    ldr.w r1, =rtc_stage                    @ 08015ED0
    strb r0, [r1, #0x0]                     @ 08015ED2  rtc_stage = 1
    movs r0, #0x1                           @ 08015ED4
    ldr.w r1, =rtc_edit                     @ 08015ED6
    strb r0, [r1, #0x0]                     @ 08015EDA  rtc_edit = 1
    b .L08015F32                            @ 08015EDC
.L08015EDE:  @ reached from 08015E7E bne (rtc_stage != 0)
    uxtb r4, r4                             @ 08015EDE
    cmp r4, #0x1                            @ 08015EE0  compare r4 with 1
    bne .L08015EFE                          @ 08015EE2  if r4 != 1
    ldr.w r0, =rtc_minute_edit              @ 08015EE4
    ldrb r0, [r0, #0x0]                     @ 08015EE6  r0 = rtc_minute_edit
    adds r0, r0, #0x1                       @ 08015EE8  r0 = rtc_minute_edit + 1
    ldr.w r1, =rtc_minute_edit              @ 08015EEA
    strb r0, [r1, #0x0]                     @ 08015EEC  rtc_minute_edit = (rtc_minute_edit + 1)
    ldr.w r0, =rtc_minute_edit              @ 08015EEE
    ldrb r0, [r0, #0x0]                     @ 08015EF0  r0 = rtc_minute_edit
    cmp r0, #0x3c                           @ 08015EF2  compare rtc_minute_edit with 60 (0x3C)
    blt .L08015F32                          @ 08015EF4  if rtc_minute_edit <s 60 (0x3C)
    movs r0, #0x0                           @ 08015EF6
    ldr.w r1, =rtc_minute_edit              @ 08015EF8
    strb r0, [r1, #0x0]                     @ 08015EFA  rtc_minute_edit = 0
    b .L08015F32                            @ 08015EFC
.L08015EFE:  @ reached from 08015EE2 bne (r4 != 1)
    uxtb r4, r4                             @ 08015EFE
    cmp r4, #0x2                            @ 08015F00  compare r4 with 2
    bne .L08015F20                          @ 08015F02  if r4 != 2
    ldr.w r0, =rtc_minute_edit              @ 08015F04
    ldrb r0, [r0, #0x0]                     @ 08015F06  r0 = rtc_minute_edit
    cmp r0, #0x0                            @ 08015F08  compare rtc_minute_edit with 0
    bne .L08015F14                          @ 08015F0A  if rtc_minute_edit != 0
    movs r0, #0x3b                          @ 08015F0C
    ldr.w r1, =rtc_minute_edit              @ 08015F0E
    strb r0, [r1, #0x0]                     @ 08015F10  rtc_minute_edit = 59 (0x3B)
    b .L08015F32                            @ 08015F12
.L08015F14:  @ reached from 08015F0A bne (rtc_minute_edit != 0)
    ldr.w r0, =rtc_minute_edit              @ 08015F14
    ldrb r0, [r0, #0x0]                     @ 08015F16  r0 = rtc_minute_edit
    subs r0, r0, #0x1                       @ 08015F18  r0 = rtc_minute_edit - 1
    ldr.w r1, =rtc_minute_edit              @ 08015F1A
    strb r0, [r1, #0x0]                     @ 08015F1C  rtc_minute_edit = (rtc_minute_edit - 1)
    b .L08015F32                            @ 08015F1E
.L08015F20:  @ reached from 08015F02 bne (r4 != 2)
    ldr.w r0, =rtc_minute_edit              @ 08015F20
    ldrb r0, [r0, #0x0]                     @ 08015F22  r0 = rtc_minute_edit
    ldr.w r1, =rtc_minute                   @ 08015F24
    strb r0, [r1, #0x0]                     @ 08015F26  rtc_minute = rtc_minute_edit
    bl fn_0801016C                          @ 08015F28  write the six time registers from RAM [r0=rtc_minute_edit, r1=&rtc_minute]
    movs r0, #0x0                           @ 08015F2C
    ldr.w r1, =rtc_stage                    @ 08015F2E
    strb r0, [r1, #0x0]                     @ 08015F30  rtc_stage = 0
.L08015F32:  @ reached from 08015E96 blt (rtc_hour_edit <s 24 (0x18)), 08015E9E b, 08015EB4 b, 08015EC0 b, 08015EDC b, 08015EF4 blt (rtc_minute_edit <s 60 (0x3C)), 08015EFC b, 08015F12 b, 08015F1E b
    movs r0, #0x1                           @ 08015F32
    ldr.w r1, =rtc_redraw                   @ 08015F34
    strb r0, [r1, #0x0]                     @ 08015F38  rtc_redraw = 1
    pop {r4, pc}                            @ 08015F3A
ENDFUNC fn_08015E74
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015F44 - store the date code YYMM after a year or month save
@ Replaces : 0x08015F44 FUN_08015F44 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads rtc_date_edit_en, rtc_month, rtc_year; writes rtc_date_code
@ Spec     : EEPROM_MAP.md 4 (0x001..0x002); DESIGN.md Appendix C.2 nvm_write_ident
@ Note     : Only when rtc_date_edit_en (SETUP pressed in the power-on window) is non-zero: date code = year * 100 +
@            month, stored by fn_08010F74 (CAL; IDENT class, gate re-checked in NVM).
@ -----------------------------------------------------------------------------
FUNC fn_08015F44
    push {r7, lr}                           @ 08015F44
    ldr.w r0, =rtc_date_edit_en             @ 08015F46
    ldrb r0, [r0, #0x0]                     @ 08015F4A  r0 = rtc_date_edit_en
    cmp r0, #0x0                            @ 08015F4C  compare rtc_date_edit_en with 0
    beq .L08015F68                          @ 08015F4E  if rtc_date_edit_en == 0
    ldr.w r0, =rtc_year                     @ 08015F50
    ldrb r0, [r0, #0x0]                     @ 08015F52  r0 = rtc_year
    movs r1, #0x64                          @ 08015F54
    ldr.w r2, =rtc_month                    @ 08015F56
    ldrb r2, [r2, #0x0]                     @ 08015F58  r2 = rtc_month
    mla r0, r1, r0, r2                      @ 08015F5A  r0 = 100 (0x64) * rtc_year + rtc_month
    ldr.w r1, =rtc_date_code                @ 08015F5E
    strh r0, [r1, #0x0]                     @ 08015F62  rtc_date_code = (100 (0x64) * rtc_year + rtc_month)
    bl fn_08010F74                          @ 08015F64  store the date code to EEPROM 0x001 (IDENT) [r0=(100 (0x64) * rtc_year + rtc_month), r1=&rtc_date_code, r2=rtc_month]
.L08015F68:  @ reached from 08015F4E beq (rtc_date_edit_en == 0)
    pop {r0, pc}                            @ 08015F68
ENDFUNC fn_08015F44
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018788 - draw the year page ("20yy") on the secondary display
@ Replaces : 0x08018788 FUN_08018788 (v2.05)
@ In       : r0 = 0 request a deferred commit, else commit now; r1 = year 0..99
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes rtc_commit_req
@ -----------------------------------------------------------------------------
FUNC fn_08018788
    push {r4, r5, r6, lr}                   @ 08018788
    movs r4, r0                             @ 0801878A
    movs r5, r1                             @ 0801878C
    uxtb r5, r5                             @ 0801878E
    adds r6, r5, #0x7d0                     @ 08018790  r6 = r5 + 2000 (0x7D0)
    movs r0, #0x0                           @ 08018794
    bl fn_08017FB4                          @ 08018796  secondary display decimal point / unit setup, r0 = code [r0=0]
    movs r0, r6                             @ 0801879A
    bl fn_0801B090                          @ 0801879C  split r0 into the five digit words lcd_digit4..0 [r0=(r5 + 2000 (0x7D0))]
    movs r0, #0x0                           @ 080187A0
    bl fn_0801B130                          @ 080187A2  convert the digit words for display (blanking, decimal point r0) [r0=0]
    ldr.w r1, =rtc_text5                    @ 080187A6
    movs r0, #0x1                           @ 080187A8
    bl lcd_draw_5char                       @ 080187AA  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&rtc_text5]
    uxtb r4, r4                             @ 080187AE
    cmp r4, #0x0                            @ 080187B0  compare r4 with 0
    bne .L080187BE                          @ 080187B2  if r4 != 0
    movs r0, #0x1                           @ 080187B4
    ldr.w r1, =rtc_commit_req               @ 080187B6
    strb r0, [r1, #0x0]                     @ 080187BA  rtc_commit_req = 1
    b .L080187C2                            @ 080187BC
.L080187BE:  @ reached from 080187B2 bne (r4 != 0)
    bl lcd_commit_shadow                    @ 080187BE  commit the LCD shadow words to the LCD
.L080187C2:  @ reached from 080187BC b
    pop {r4, r5, r6, pc}                    @ 080187C2
ENDFUNC fn_08018788
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080187D8 - draw the month-day page ("MM-DD")
@ Replaces : 0x080187D8 FUN_080187D8 (v2.05)
@ In       : r0 = 0 deferred commit, else commit now; r1 = month, r2 = day
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes rtc_commit_req, rtc_lcd_digit0, rtc_lcd_digit1, rtc_text5
@ -----------------------------------------------------------------------------
FUNC fn_080187D8
    push {r4, r5, r6, r7, r8, lr}           @ 080187D8
    movs r4, r0                             @ 080187DC
    movs r5, r1                             @ 080187DE
    movs r6, r2                             @ 080187E0
    movs r7, r5                             @ 080187E2
    mov r8, r6                              @ 080187E4
    movs r0, #0x0                           @ 080187E6
    bl fn_08017FB4                          @ 080187E8  secondary display decimal point / unit setup, r0 = code [r0=0]
    uxtb r7, r7                             @ 080187EC
    movs r0, r7                             @ 080187EE
    bl fn_0801B090                          @ 080187F0  split r0 into the five digit words lcd_digit4..0
    ldr.w r0, =rtc_lcd_digit1               @ 080187F4
    ldr r0, [r0, #0x0]                      @ 080187F8  r0 = rtc_lcd_digit1
    adds r0, #0x30                          @ 080187FA  r0 = rtc_lcd_digit1 + 48 (0x30)
    ldr.w r1, =rtc_lcd_digit1               @ 080187FC
    str r0, [r1, #0x0]                      @ 08018800  rtc_lcd_digit1 = (rtc_lcd_digit1 + 48 (0x30))
    ldr.w r0, =rtc_lcd_digit1               @ 08018802
    ldr r0, [r0, #0x0]                      @ 08018806  r0 = rtc_lcd_digit1
    ldr.w r1, =rtc_text5                    @ 08018808
    strb r0, [r1, #0x0]                     @ 0801880A  rtc_text5 = rtc_lcd_digit1
    ldr.w r0, =rtc_lcd_digit0               @ 0801880C
    ldr r0, [r0, #0x0]                      @ 08018810  r0 = rtc_lcd_digit0
    adds r0, #0x30                          @ 08018812  r0 = rtc_lcd_digit0 + 48 (0x30)
    ldr.w r1, =rtc_lcd_digit0               @ 08018814
    str r0, [r1, #0x0]                      @ 08018818  rtc_lcd_digit0 = (rtc_lcd_digit0 + 48 (0x30))
    ldr.w r0, =rtc_lcd_digit0               @ 0801881A
    ldr r0, [r0, #0x0]                      @ 0801881E  r0 = rtc_lcd_digit0
    ldr.w r1, =rtc_text5                    @ 08018820
    strb r0, [r1, #0x1]                     @ 08018822  rtc_text5+1 = rtc_lcd_digit0
    movs r0, #0x2d                          @ 08018824
    ldr.w r1, =rtc_text5                    @ 08018826
    strb r0, [r1, #0x2]                     @ 08018828  rtc_text5+2 = 45 (0x2D)
    uxtb r8, r8                             @ 0801882A
    mov r0, r8                              @ 0801882E
    bl fn_0801B090                          @ 08018830  split r0 into the five digit words lcd_digit4..0 [r1=&rtc_text5]
    ldr.w r0, =rtc_lcd_digit1               @ 08018834
    ldr r0, [r0, #0x0]                      @ 08018838  r0 = rtc_lcd_digit1
    adds r0, #0x30                          @ 0801883A  r0 = rtc_lcd_digit1 + 48 (0x30)
    ldr.w r1, =rtc_lcd_digit1               @ 0801883C
    str r0, [r1, #0x0]                      @ 08018840  rtc_lcd_digit1 = (rtc_lcd_digit1 + 48 (0x30))
    ldr.w r0, =rtc_lcd_digit1               @ 08018842
    ldr r0, [r0, #0x0]                      @ 08018846  r0 = rtc_lcd_digit1
    ldr.w r1, =rtc_text5                    @ 08018848
    strb r0, [r1, #0x3]                     @ 0801884A  rtc_text5+3 = rtc_lcd_digit1
    ldr.w r0, =rtc_lcd_digit0               @ 0801884C
    ldr r0, [r0, #0x0]                      @ 08018850  r0 = rtc_lcd_digit0
    adds r0, #0x30                          @ 08018852  r0 = rtc_lcd_digit0 + 48 (0x30)
    ldr.w r1, =rtc_lcd_digit0               @ 08018854
    str r0, [r1, #0x0]                      @ 08018858  rtc_lcd_digit0 = (rtc_lcd_digit0 + 48 (0x30))
    ldr.w r0, =rtc_lcd_digit0               @ 0801885A
    ldr r0, [r0, #0x0]                      @ 0801885E  r0 = rtc_lcd_digit0
    ldr.w r1, =rtc_text5                    @ 08018860
    strb r0, [r1, #0x4]                     @ 08018862  rtc_text5+4 = rtc_lcd_digit0
    ldr.w r1, =rtc_text5                    @ 08018864
    movs r0, #0x1                           @ 08018866
    bl lcd_draw_5char                       @ 08018868  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&rtc_text5]
    uxtb r4, r4                             @ 0801886C
    cmp r4, #0x0                            @ 0801886E  compare r4 with 0
    bne .L0801887A                          @ 08018870  if r4 != 0
    movs r0, #0x1                           @ 08018872
    ldr.w r1, =rtc_commit_req               @ 08018874
    strb r0, [r1, #0x0]                     @ 08018876  rtc_commit_req = 1
    b .L0801887E                            @ 08018878
.L0801887A:  @ reached from 08018870 bne (r4 != 0)
    bl lcd_commit_shadow                    @ 0801887A  commit the LCD shadow words to the LCD
.L0801887E:  @ reached from 08018878 b
    pop {r4, r5, r6, r7, r8, pc}            @ 0801887E
ENDFUNC fn_080187D8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080188A0 - draw the hour-minute page ("HH:MM")
@ Replaces : 0x080188A0 FUN_080188A0 (v2.05)
@ In       : r0 = 0 deferred commit, else commit now; r1 = hour, r2 = minute
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads rtc_blink_phase; writes rtc_commit_req, rtc_lcd_digit0, rtc_lcd_digit1, rtc_text5
@ Note     : The separator character is a dash while rtc_colon is non-zero, else a space.
@ Deviation: IMP-13 (production: 12-hour display with the SETUP page CL, hour 1..12, leading zero blank)
@ -----------------------------------------------------------------------------
FUNC fn_080188A0
    push {r4, r5, r6, r7, r8, lr}           @ 080188A0
    @ IMP-13: 12-hour clock (SETUP page CL): hour 0 -> 12, 13..23 -> 1..11; the clock chip and the edit keep 0..23
    ldr r3, =set_clk12
    ldrb r3, [r3]
    cbz r3, 1f                              @ 24-hour: as v2.05
    uxtb r1, r1
    cmp r1, #12
    it hs
    subhs r1, r1, #12                       @ 12..23 -> 0..11
    cbnz r1, 1f
    movs r1, #12                            @ 0 -> 12
1:
    movs r4, r0                             @ 080188A4
    movs r5, r1                             @ 080188A6
    movs r6, r2                             @ 080188A8
    movs r7, r5                             @ 080188AA
    mov r8, r6                              @ 080188AC
    movs r0, #0x0                           @ 080188AE
    bl fn_08017FB4                          @ 080188B0  secondary display decimal point / unit setup, r0 = code [r0=0]
    uxtb r7, r7                             @ 080188B4
    movs r0, r7                             @ 080188B6
    bl fn_0801B090                          @ 080188B8  split r0 into the five digit words lcd_digit4..0
    ldr.w r0, =rtc_lcd_digit1               @ 080188BC
    ldr r0, [r0, #0x0]                      @ 080188C0  r0 = rtc_lcd_digit1
    adds r0, #0x30                          @ 080188C2  r0 = rtc_lcd_digit1 + 48 (0x30)
    ldr.w r1, =rtc_lcd_digit1               @ 080188C4
    str r0, [r1, #0x0]                      @ 080188C8  rtc_lcd_digit1 = (rtc_lcd_digit1 + 48 (0x30))
    ldr.w r0, =rtc_lcd_digit1               @ 080188CA
    ldr r0, [r0, #0x0]                      @ 080188CE  r0 = rtc_lcd_digit1
    ldr.w r1, =rtc_text5                    @ 080188D0
    strb r0, [r1, #0x0]                     @ 080188D2  rtc_text5 = rtc_lcd_digit1
    ldr r3, =set_clk12
    ldrb r3, [r3]
    cbz r3, 2f                              @ 24-hour: the leading zero stays, as v2.05
    cmp r0, #0x30
    bne 2f
    movs r0, #0x20
    strb r0, [r1, #0x0]                     @ IMP-13: 12-hour: tens of the hour blank when 0 (" 2-30")
2:
    ldr.w r0, =rtc_lcd_digit0               @ 080188D4
    ldr r0, [r0, #0x0]                      @ 080188D8  r0 = rtc_lcd_digit0
    adds r0, #0x30                          @ 080188DA  r0 = rtc_lcd_digit0 + 48 (0x30)
    ldr.w r1, =rtc_lcd_digit0               @ 080188DC
    str r0, [r1, #0x0]                      @ 080188E0  rtc_lcd_digit0 = (rtc_lcd_digit0 + 48 (0x30))
    ldr.w r0, =rtc_lcd_digit0               @ 080188E2
    ldr r0, [r0, #0x0]                      @ 080188E6  r0 = rtc_lcd_digit0
    ldr.w r1, =rtc_text5                    @ 080188E8
    strb r0, [r1, #0x1]                     @ 080188EA  rtc_text5+1 = rtc_lcd_digit0
    ldr.w r0, =rtc_blink_phase              @ 080188EC
    ldrb r0, [r0, #0x0]                     @ 080188F0  r0 = rtc_blink_phase
    cmp r0, #0x0                            @ 080188F2  compare rtc_blink_phase with 0
    beq .L080188FE                          @ 080188F4  if rtc_blink_phase == 0
    movs r0, #0x2d                          @ 080188F6
    ldr.w r1, =rtc_text5                    @ 080188F8
    strb r0, [r1, #0x2]                     @ 080188FA  rtc_text5+2 = 45 (0x2D)
    b .L08018904                            @ 080188FC
.L080188FE:  @ reached from 080188F4 beq (rtc_blink_phase == 0)
    movs r0, #0x20                          @ 080188FE
    ldr.w r1, =rtc_text5                    @ 08018900
    strb r0, [r1, #0x2]                     @ 08018902  rtc_text5+2 = 32 (0x20)
.L08018904:  @ reached from 080188FC b
    uxtb r8, r8                             @ 08018904
    mov r0, r8                              @ 08018908
    bl fn_0801B090                          @ 0801890A  split r0 into the five digit words lcd_digit4..0
    ldr.w r0, =rtc_lcd_digit1               @ 0801890E
    ldr r0, [r0, #0x0]                      @ 08018912  r0 = rtc_lcd_digit1
    adds r0, #0x30                          @ 08018914  r0 = rtc_lcd_digit1 + 48 (0x30)
    ldr.w r1, =rtc_lcd_digit1               @ 08018916
    str r0, [r1, #0x0]                      @ 0801891A  rtc_lcd_digit1 = (rtc_lcd_digit1 + 48 (0x30))
    ldr.w r0, =rtc_lcd_digit1               @ 0801891C
    ldr r0, [r0, #0x0]                      @ 08018920  r0 = rtc_lcd_digit1
    ldr.w r1, =rtc_text5                    @ 08018922
    strb r0, [r1, #0x3]                     @ 08018924  rtc_text5+3 = rtc_lcd_digit1
    ldr.w r0, =rtc_lcd_digit0               @ 08018926
    ldr r0, [r0, #0x0]                      @ 0801892A  r0 = rtc_lcd_digit0
    adds r0, #0x30                          @ 0801892C  r0 = rtc_lcd_digit0 + 48 (0x30)
    ldr.w r1, =rtc_lcd_digit0               @ 0801892E
    str r0, [r1, #0x0]                      @ 08018932  rtc_lcd_digit0 = (rtc_lcd_digit0 + 48 (0x30))
    ldr.w r0, =rtc_lcd_digit0               @ 08018934
    ldr r0, [r0, #0x0]                      @ 08018938  r0 = rtc_lcd_digit0
    ldr.w r1, =rtc_text5                    @ 0801893A
    strb r0, [r1, #0x4]                     @ 0801893C  rtc_text5+4 = rtc_lcd_digit0
    ldr.w r1, =rtc_text5                    @ 0801893E
    movs r0, #0x1                           @ 08018940
    bl lcd_draw_5char                       @ 08018942  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&rtc_text5]
    uxtb r4, r4                             @ 08018946
    cmp r4, #0x0                            @ 08018948  compare r4 with 0
    bne .L08018954                          @ 0801894A  if r4 != 0
    movs r0, #0x1                           @ 0801894C
    ldr.w r1, =rtc_commit_req               @ 0801894E
    strb r0, [r1, #0x0]                     @ 08018950  rtc_commit_req = 1
    b .L08018958                            @ 08018952
.L08018954:  @ reached from 0801894A bne (r4 != 0)
    bl lcd_commit_shadow                    @ 08018954  commit the LCD shadow words to the LCD
.L08018958:  @ reached from 08018952 b
    pop {r4, r5, r6, r7, r8, pc}            @ 08018958
ENDFUNC fn_080188A0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801896C - draw the hour-minute page with the blink phase
@ Replaces : 0x0801896C FUN_0801896C (v2.05)
@ In       : r0 = 0 deferred commit, else commit now
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads rtc_edit, rtc_hour, rtc_hour_edit, rtc_minute, rtc_minute_edit
@ Deviation: OF-41/NF-11: v2.05 calls this from the TIM2 handler (0x080246FC); the port calls it from the main loop
@            when rtc_blink_request is set (loop step 4)
@ Note     : Draws the edit buffers (rtc_hour_edit, rtc_minute_edit) while the edit mode rtc_edit is non-zero and the
@            live time (rtc_hour, rtc_minute) otherwise, through fn_080188A0; the colon between hours and minutes is
@            shown in one phase of rtc_blink_phase (toggled by the TIM2 handler) and hidden in the other.
@ -----------------------------------------------------------------------------
FUNC fn_0801896C
    push {r4, lr}                           @ 0801896C
    movs r4, r0                             @ 0801896E
    ldr.w r0, =rtc_edit                     @ 08018970
    ldrb r0, [r0, #0x0]                     @ 08018974  r0 = rtc_edit
    cmp r0, #0x0                            @ 08018976  compare rtc_edit with 0
    beq .L08018990                          @ 08018978  if rtc_edit == 0
    ldr.w r0, =rtc_minute_edit              @ 0801897A
    ldrb r2, [r0, #0x0]                     @ 0801897E  r2 = rtc_minute_edit
    ldr.w r0, =rtc_hour_edit                @ 08018980
    ldrb r1, [r0, #0x0]                     @ 08018984  r1 = rtc_hour_edit
    movs r0, r4                             @ 08018986
    uxtb r0, r0                             @ 08018988
    bl fn_080188A0                          @ 0801898A  draw the hour-minute page [r1=rtc_hour_edit, r2=rtc_minute_edit]
    b .L080189A4                            @ 0801898E
.L08018990:  @ reached from 08018978 beq (rtc_edit == 0)
    ldr.w r0, =rtc_minute                   @ 08018990
    ldrb r2, [r0, #0x0]                     @ 08018994  r2 = rtc_minute
    ldr.w r0, =rtc_hour                     @ 08018996
    ldrb r1, [r0, #0x0]                     @ 0801899A  r1 = rtc_hour
    movs r0, r4                             @ 0801899C
    uxtb r0, r0                             @ 0801899E
    bl fn_080188A0                          @ 080189A0  draw the hour-minute page [r1=rtc_hour, r2=rtc_minute]
.L080189A4:  @ reached from 0801898E b
    pop {r4, pc}                            @ 080189A4
ENDFUNC fn_0801896C
    .ltorg
