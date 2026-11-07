@ =============================================================================
@ setup.s - SET: SETUP menu
@
@ SET module, part 4: the SETUP menu (analysis/keys_setup.md 4): item advance, edit actions, the page dispatcher
@ and the page drawers.
@
@ Replaces the v2.05 routines 0x08015410, 0x08015A22..0x08016190, 0x080165F4, 0x0801797C, 0x08017F94..0x08018A00.
@ Deviation IMP-05: item 10 of BEEP offers 16 continuity thresholds (analysis/autorange_and_scheduler.md 9).
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
    .equ set_log_interval,      v_2000022C   @ logging interval in seconds, u16, EEPROM 0x018 (EMAP)
    .equ set_text5,             v_20007C30   @ 5-character text buffer drawn on the secondary display by lcd_draw_5char(1, ...)
    .equ set_id,                v_20007D14   @ serial/ID number, u32, EEPROM 0x003..0x006 (< 100000)
    .equ set_id_edit,           v_20007D18   @ ID number edit buffer, u32
    .equ set_view_value,        v_20007D38   @ value shown by setup page 100 (MEM view / logging)
    .equ set_sub_value,         v_20007D84   @ value shown by setup item 10 in modes 2 and 4, scaled by 1/10
    .equ set_lcd_digit3,        v_20007DB4   @ digit word d3 (thousands)
    .equ set_lcd_digit1,        v_20007DBC   @ digit word d1 (tens)
    .equ set_lcd_digit0,        v_20007DC0   @ digit word d0 (units)
    .equ set_acv_float,         v_20007E94   @ float input of setup item 11 in ACV (scaled value)
    .equ set_acv_scaled,        v_20007E98   @ signed result of setup item 11 in ACV (also BLE sub display case 11)
    .equ set_va_volt,           v_20007EAC   @ VA voltage s32 (sub display page 10/11 helpers)
    .equ set_va_cur,            v_20007EB0   @ VA current s32
    .equ set_interval_edit,     v_20007FA6   @ logging interval edit buffer (item 9), u16
    .equ set_bat_value,         v_20007FBA   @ processed battery value u16
    .equ set_item12_value,      v_20007FCA   @ s16 value of setup item 12 of the VA modes (also BLE sub display case 12)
    .equ set_temp_value,        v_20007FCC   @ s16 temperature value (PA4 thermistor)
    .equ set_msg_code,          v_2000801B   @ SD / logging message code shown instead of the setup page (UI screens), 0x14 handled apart
    .equ set_msg_flag,          v_2000801D   @ message flag: non-zero shows fn_080198FC instead of the setup page
    .equ set_item,              v_20008037   @ setup item shown on the secondary display (0..12, 100 = MEM view)
    .equ set_apo_disable,       v_20008039   @ auto-power-off disable, 0 = APO on, EEPROM 0x016
    .equ set_freq_range,        v_2000803E   @ frequency range 0..? (>= 2 sets the sub "k" in the BLE helper 0x0800CE78)
    .equ set_sub_dp,            v_20008040   @ decimal-point code of the secondary display (lcd_show_value_pos0_4 argument)
    .equ set_ovl,               v_20008046   @ overload flag (drawn once)
    .equ set_commit_req,        v_2000805B   @ LCD commit request (set instead of committing immediately)
    .equ set_redraw,            v_20008062   @ secondary display redraw request
    .equ set_edit,              v_2000806E   @ setup edit mode active (toggled by long SETUP)
    .equ set_edit_blink,        v_2000806F   @ edit blink phase, toggled by the TIM2 handler while set_edit
    .equ set_edit_timer,        v_20008070   @ edit timeout tick counter (0xF1 ticks, FUN_0800D190)
    .equ set_digit_pos,         v_20008071   @ cursor digit 0..4 of the ID edit (item 8)
    .equ set_buzzer_on,         v_20008078   @ buzzer enable, EEPROM 0x01E
    .equ set_cal_mode,          v_2000808A   @ calibration mode flag (owner CAL)
    .equ set_cal_item_cnt,      v_20008097   @ calibration-mode setup item countdown; meaning UNPROVEN beyond the code (FUN_0801797C 0x08017A60..0x08017A98)
    .equ set_cur_opt,           v_200080A5   @ current-mode setup option flag (setup items 10/11 of the six current modes); meaning UNPROVEN beyond the code
    .equ set_cur_opt_edit,      v_200080A6   @ edit buffer of set_cur_opt (setup item 10 of the current modes)
    .equ set_va_bd,             v_200080A8   @ VA burden option "bd", EEPROM 0x01B
    .equ set_va_bd_edit,        v_200080A9   @ VA "bd" edit buffer (setup item 11 of the VA modes)
    .equ set_item_timer,        v_200080AA   @ set to 100 by FUN_08015410 on entering item 12 and by FUN_0800D718; cleared by the display code; meaning UNPROVEN
    .equ set_temp_celsius,      v_200080AB   @ temperature unit, 1 = degC, 0 = degF, EEPROM 0x010
    .equ set_temp_flag,         v_200080AE   @ temperature flag (BLE sub flag bit 7)
    .equ set_diode_15v,         v_200080B3   @ DIODE source 0 = 3 V, 1 = 15 V (EEPROM 0x012 read at boot, forced 0, OF-23)
    .equ set_cont_code,         v_200080B6   @ continuity threshold code, EEPROM 0x014 (v2.05 0..3, port 0..15, IMP-05)
    .equ set_va_sub,            v_200080C2   @ VA sub-range flag 0 / non-zero (BLE helper selector)
    .equ set_va_sub2,           v_200080C7   @ VA sub-range flag (scales the item 12 value by 10 or 100)
    .equ set_va_ovl1,           v_200080CA   @ VA overload flag (s8)
    .equ set_va_ovl2,           v_200080CB   @ VA overload flag (s8)
    .equ set_stage,             v_200080D6   @ date/time edit stage: 0 = month or hour, 1 = day or minute
    .equ set_year,              v_200080D7   @ year 0..99 (BCD-converted NJU6350 register 2)
    .equ set_month,             v_200080D8   @ month 1..12 (register 4)
    .equ set_day,               v_200080D9   @ day 1..31 (register 6)
    .equ set_hour,              v_200080DA   @ hour 0..23 (register 10)
    .equ set_minute,            v_200080DB   @ minute 0..59 (register 12)
    .equ set_year_edit,         v_200080DD   @ year edit buffer (item 5)
    .equ set_month_edit,        v_200080DE   @ month edit buffer (item 6)
    .equ set_day_edit,          v_200080DF   @ day edit buffer (item 6)
    .equ set_hour_edit,         v_200080E0   @ hour edit buffer (item 7)
    .equ set_minute_edit,       v_200080E1   @ minute edit buffer (item 7)

    .equ SET_ITEM_BL, 20                    @ IMP-07: setup item of the backlight auto-off page bL (v2.05 uses 0..12 and 100)
    .equ SET_ITEM_BT, 21                    @ IMP-09: setup item of the Bluetooth frame rate page bt (after bL)
    .equ SET_ITEM_RELP, 22                  @ IMP-11: setup item of the REL view page rEL (after bt)
    .equ SET_ITEM_DSP, 24                   @ IMP-12: setup item of the display level page dSP (after rEL, or tc in TEMP)
    .equ SET_ITEM_CLK, 25                   @ IMP-13: setup item of the clock page CL (after dSP, or bH, LP, Pt, HUnt)
    .equ SET_ITEM_ST_N, 32                  @ IMP-14: statistics page n (only while MIN/MAX is on)
    .equ SET_ITEM_ST_SD, 33                 @ IMP-14: statistics page Sd (only while MIN/MAX is on)
    .equ SET_ITEM_T_HI, 34                  @ IMP-21: time of the MIN/MAX maximum, page tHI (only while MIN/MAX is on)
    .equ SET_ITEM_T_LO, 35                  @ IMP-21: time of the minimum, page tLo (only while MIN/MAX is on)
    .equ SET_ITEM_BH, 26                    @ IMP-16: continuity hold page bH (BEEP only, between dSP and CL)
    .equ SET_ITEM_LP, 37                    @ IMP-24: current-loop percent page LP (DCmA only, between dSP and CL)
    .equ SET_ITEM_RTD, 38                   @ IMP-25: RTD temperature page Pt (OHM only, between dSP and CL)
    .equ SET_ITEM_BFT, 39                   @ IMP-28: Bluetooth file transfer page Ld (between bt and rEL)
    .equ SET_ITEM_FMT, 40                   @ IMP-32: card format page Fr (between Ld and rEL, two-part bootloader only)
    .equ SET_ITEM_HUNT, 41                  @ IMP-45: capacitance anti-hunting page HUnt (CAP only, between dSP and CL)
    .equ SET_ITEM_LT, 27                    @ IMP-20: limit test pages Lt (27), Lo (28), HI (29), verdict (36)
    .equ SET_ITEM_LO, 28
    .equ SET_ITEM_HI, 29
    .equ SET_ITEM_VERDICT, 36
    .equ SET_ITEM_TR, 30                    @ IMP-21: logging trigger page tr
    .equ SET_ITEM_CH, 31                    @ IMP-21: change threshold page Ch (with tr-Ch only)
    .equ SET_ITEM_TC, 23                    @ IMP-10: setup item of the thermocouple type page tc (after bt, TEMP only)

    .section .text.set, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08015410 - SETUP short press: advance to the next setup item
@ Replaces : 0x08015410 FUN_08015410 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : main only (KEY, handle_pg8_15_short_press)
@ RAM      : reads acdc_active, meter_mode, set_cur_opt, set_day, set_hour, set_id, set_log_interval, set_minute,
@            set_month, set_va_bd, set_year; writes set_cur_opt_edit, set_day_edit, set_digit_pos, set_edit,
@            set_edit_timer, set_hour_edit, set_id_edit, set_interval_edit, set_item, set_item_timer, set_minute_edit,
@            set_month_edit, set_stage, set_va_bd_edit, set_year_edit
@ Spec     : analysis/keys_setup.md 4 (SETUP menu) (item list, extra items by mode, wrap limits)
@ Note     : During the ID edit (item 8, set_edit non-zero) the key moves the digit cursor set_digit_pos instead (4,
@            then 3, 2, 1, 0, 4); in any other item an active edit is ended without saving.  The item then increments
@            with these wrap limits: ACV (not AC+DC) 12 (items 0..11); the VA modes (13, 14, 15, 22, 23, 24) 13 with
@            set_va_bd, else 12; the AC currents (16, 18, 20) 12; the DC currents (17, 19, 21) 12 with set_cur_opt,
@            else 11; ACmV, BEEP, DIODE 11; all other modes 10.  On entering a new item the edit buffer is loaded:
@            year/month/day/hour/minute from the live time, the ID from set_id, the interval into set_interval_edit;
@            entering item 10 calls fn_0800D6E0 in the VA modes, item 12 sets set_item_timer = 100.
@ -----------------------------------------------------------------------------
FUNC fn_08015410
    push {r7, lr}                           @ 08015410
    @ IMP-07, IMP-09, IMP-11, IMP-10, IMP-12: SETUP short on the page bL (item 20, the page after the last v2.05 item) goes
    @ to the page bt (item 21), on bt to the page Ld (item 39, IMP-28), on Ld to the page rEL (item 22); on rEL to the page tc (item 23) in TEMP (mode 5), else to
    @ the page dSP (item 24); on tc to dSP; on dSP to the page bH (item 26, IMP-16) in BEEP (mode 10), to the page LP
    @ (item 37, IMP-24) in DCmA (mode 19), to the page Pt (item 38, IMP-25) in OHM (mode 9), to the page HUnt (item 41, IMP-45)
    @ in CAP (mode 12), else to the page CL (item 25); on bH, LP, Pt and HUnt to CL; on CL to the limit pages Lt, Lo, HI (27..29, IMP-20); on HI to the verdict page (36) while
    @ the test is on; then to the logging pages tr (30) and, with tr-Ch, Ch (31) (IMP-21); then, while MIN/MAX is on, to
    @ the statistics page n (item 32, IMP-14); on n to Sd (item 33); on Sd to the time pages tHI (34) and tLo (35)
    @ (IMP-21); on tLo to item 0.  Each step ends an edit.
    ldr.w r0, =set_item
    ldrb r0, [r0, #0x0]
    cmp r0, #SET_ITEM_BL
    beq .Lsn_bl
    cmp r0, #SET_ITEM_BT
    beq .Lsn_bt
    cmp r0, #SET_ITEM_BFT
    beq .Lsn_bft
    cmp r0, #SET_ITEM_FMT
    beq .Lsn_fmt
    cmp r0, #SET_ITEM_T_LO
    beq .Lsn_to0                            @ tLo: next is item 0
    cmp r0, #SET_ITEM_T_HI
    bne 5f
    movs r0, #SET_ITEM_T_LO                 @ tHI: next is tLo
    b .Lsn_port_set
5:  cmp r0, #SET_ITEM_ST_SD
    bne 6f
    movs r0, #SET_ITEM_T_HI                 @ Sd: next is tHI
    b .Lsn_port_set
6:
    cmp r0, #SET_ITEM_ST_N
    beq .Lsn_to_sd                          @ n: next is Sd
    cmp r0, #SET_ITEM_CLK
    bne .Lsn_not_clk
    movs r0, #SET_ITEM_LT                   @ CL: next is Lt
    b .Lsn_port_set
.Lsn_not_clk:
    cmp r0, #SET_ITEM_LT
    bne 1f
    movs r0, #SET_ITEM_LO                   @ Lt: next is Lo
    b .Lsn_port_set
1:  cmp r0, #SET_ITEM_LO
    bne 2f
    movs r0, #SET_ITEM_HI                   @ Lo: next is HI
    b .Lsn_port_set
2:  cmp r0, #SET_ITEM_HI
    bne 3f
    ldr.w r0, =lt_on
    ldrb r0, [r0, #0x0]
    cbnz r0, .Lsn_hi_on
    b .Lsn_to_tr                            @ HI, test off: the page tr (a branch: cbz no longer reaches it, IMP-45 code grew the function)
.Lsn_hi_on:
    movs r0, #SET_ITEM_VERDICT              @ HI, test on: the verdict page
    b .Lsn_port_set
3:  cmp r0, #SET_ITEM_VERDICT
    beq .Lsn_to_tr                          @ verdict: the page tr
    cmp r0, #SET_ITEM_TR
    bne 4f
    ldr.w r0, =log_trig
    ldrb r0, [r0, #0x0]
    cmp r0, #1
    bne .Lsn_after_lt                       @ tr, not tr-Ch: the statistics or item 0
    movs r0, #SET_ITEM_CH                   @ tr-Ch: the page Ch
    b .Lsn_port_set
4:  cmp r0, #SET_ITEM_CH
    bne .Lsn_not_lt
.Lsn_after_lt:
    ldr.w r0, =minmax_state
    ldrb r0, [r0, #0x0]
    cbz r0, .Lsn_to0                        @ MIN/MAX off: next is item 0
    movs r0, #SET_ITEM_ST_N                 @ MIN/MAX on: next is n
    b .Lsn_port_set
.Lsn_not_lt:
    cmp r0, #SET_ITEM_BH
    beq .Lsn_to_clk                         @ bH: next is CL
    cmp r0, #SET_ITEM_LP
    beq .Lsn_to_clk                         @ LP: next is CL
    cmp r0, #SET_ITEM_RTD
    beq .Lsn_to_clk                         @ Pt: next is CL
    cmp r0, #SET_ITEM_HUNT
    beq .Lsn_to_clk                         @ HUnt: next is CL
    cmp r0, #SET_ITEM_DSP
    bne .Lsn_not_dsp
    ldr.w r0, =meter_mode
    ldrb r0, [r0, #0x0]
    cmp r0, #19
    bne 7f
    movs r0, #SET_ITEM_LP                   @ dSP in DCmA: next is LP (IMP-24)
    b .Lsn_port_set
7:  cmp r0, #9
    bne 8f
    movs r0, #SET_ITEM_RTD                  @ dSP in OHM: next is Pt (IMP-25)
    b .Lsn_port_set
8:  cmp r0, #12
    bne 9f
    movs r0, #SET_ITEM_HUNT                 @ dSP in CAP: next is HUnt (IMP-45)
    b .Lsn_port_set
9:  cmp r0, #0xa
    bne .Lsn_to_clk                         @ dSP outside BEEP, DCmA, OHM and CAP: next is CL
    movs r0, #SET_ITEM_BH                   @ dSP in BEEP: next is bH
    b .Lsn_port_set
.Lsn_not_dsp:
    cmp r0, #SET_ITEM_TC
    beq .Lsn_to_dsp                         @ tc: next is dSP
    cmp r0, #SET_ITEM_RELP
    bne .Lsn_not_bl                         @ any other item: the v2.05 sequence below
    ldr.w r0, =meter_mode
    ldrb r0, [r0, #0x0]
    cmp r0, #0x5
    bne .Lsn_to_dsp                         @ rEL outside TEMP: next is dSP
    movs r0, #SET_ITEM_TC                   @ rEL in TEMP: next is tc
    b .Lsn_port_set
.Lsn_to_dsp:
    movs r0, #SET_ITEM_DSP
    b .Lsn_port_set
.Lsn_to_clk:
    movs r0, #SET_ITEM_CLK
    b .Lsn_port_set
.Lsn_to_sd:
    movs r0, #SET_ITEM_ST_SD
    b .Lsn_port_set
.Lsn_to_tr:
    movs r0, #SET_ITEM_TR
    b .Lsn_port_set
.Lsn_bt:
    movs r0, #SET_ITEM_BFT                  @ bt: next is Ld (IMP-28)
    b .Lsn_port_set
.Lsn_bft:
    bl set_fmt_available                    @ IMP-32: Ld: next is For while the two-part bootloader is installed
    cbz r0, .Lsn_fmt
    bl set_fmt_enter                        @ the page starts at "Fr no"
    movs r0, #SET_ITEM_FMT
    b .Lsn_port_set
.Lsn_fmt:
    movs r0, #SET_ITEM_RELP                 @ Ld (or For): next is rEL
    b .Lsn_port_set
.Lsn_to0:
    movs r0, #0x0
    b .Lsn_port_set
.Lsn_bl:
    movs r0, #SET_ITEM_BT                   @ bL: next is bt
.Lsn_port_set:
    @ IMP-45: the page HUnt shows its value on the main display, so entering or leaving it asks for a redraw of that display
    @ (CAP results can be 2.5 s apart): r0 = the new item, the old one is still in set_item
    ldr.w r1, =set_item
    ldrb r1, [r1, #0x0]
    cmp r1, #SET_ITEM_HUNT
    beq 1f
    cmp r0, #SET_ITEM_HUNT
    bne 2f
1:  push {r0}
    movs r0, #0x1
    ldr.w r1, =v_2000805F
    strb r0, [r1, #0x0]                     @ main value redraw request
    pop {r0}
2:  ldr.w r1, =set_item
    strb r0, [r1, #0x0]                     @ set_item = 21..41 or 0
    movs r0, #0x0
    ldr.w r1, =set_edit
    strb r0, [r1, #0x0]                     @ set_edit = 0 (v2.05 clears it at 0x08015422 for every item but 8)
    pop {r7, pc}
.Lsn_not_bl:
    ldr.w r0, =set_item                     @ 08015412
    ldrb r0, [r0, #0x0]                     @ 08015416  r0 = set_item
    cmp r0, #0x8                            @ 08015418  compare set_item with 8
    beq .L08015424                          @ 0801541A  if set_item == 8
    movs r0, #0x0                           @ 0801541C
    ldr.w r1, =set_edit                     @ 0801541E
    strb r0, [r1, #0x0]                     @ 08015422  set_edit = 0
.L08015424:  @ reached from 0801541A beq (set_item == 8)
    ldr.w r0, =set_edit                     @ 08015424
    ldrb r0, [r0, #0x0]                     @ 08015428  r0 = set_edit
    cmp r0, #0x0                            @ 0801542A  compare set_edit with 0
    beq .L08015464                          @ 0801542C  if set_edit == 0
    ldr.w r0, =set_item                     @ 0801542E
    ldrb r0, [r0, #0x0]                     @ 08015432  r0 = set_item
    cmp r0, #0x8                            @ 08015434  compare set_item with 8
    bne .L08015464                          @ 08015436  if set_item != 8
    ldr.w r0, =set_digit_pos                @ 08015438
    ldrb r0, [r0, #0x0]                     @ 0801543C  r0 = set_digit_pos
    cmp r0, #0x0                            @ 0801543E  compare set_digit_pos with 0
    bne .L0801544C                          @ 08015440  if set_digit_pos != 0
    movs r0, #0x4                           @ 08015442
    ldr.w r1, =set_digit_pos                @ 08015444
    strb r0, [r1, #0x0]                     @ 08015448  set_digit_pos = 4
    b .L0801545A                            @ 0801544A
.L0801544C:  @ reached from 08015440 bne (set_digit_pos != 0)
    ldr.w r0, =set_digit_pos                @ 0801544C
    ldrb r0, [r0, #0x0]                     @ 08015450  r0 = set_digit_pos
    subs r0, r0, #0x1                       @ 08015452  r0 = set_digit_pos - 1
    ldr.w r1, =set_digit_pos                @ 08015454
    strb r0, [r1, #0x0]                     @ 08015458  set_digit_pos = (set_digit_pos - 1)
.L0801545A:  @ reached from 0801544A b
    movs r0, #0x0                           @ 0801545A
    ldr.w r1, =set_edit_timer               @ 0801545C
    strb r0, [r1, #0x0]                     @ 08015460  set_edit_timer = 0
    b .L08015680                            @ 08015462
.L08015464:  @ reached from 0801542C beq (set_edit == 0), 08015436 bne (set_item != 8)
    ldr.w r0, =meter_mode                   @ 08015464
    ldrb r0, [r0, #0x0]                     @ 08015468  r0 = meter_mode
    cmp r0, #0x2                            @ 0801546A  compare meter_mode with 2
    bne .L0801549C                          @ 0801546C  if meter_mode != 2
    ldr.w r0, =acdc_active                  @ 0801546E
    ldrb r0, [r0, #0x0]                     @ 08015472  r0 = acdc_active
    cmp r0, #0x0                            @ 08015474  compare acdc_active with 0
    bne .L0801549C                          @ 08015476  if acdc_active != 0
    ldr.w r0, =set_item                     @ 08015478
    ldrb r0, [r0, #0x0]                     @ 0801547C  r0 = set_item
    adds r0, r0, #0x1                       @ 0801547E  r0 = set_item + 1
    ldr.w r1, =set_item                     @ 08015480
    strb r0, [r1, #0x0]                     @ 08015484  set_item = (set_item + 1)
    ldr.w r0, =set_item                     @ 08015486
    ldrb r0, [r0, #0x0]                     @ 0801548A  r0 = set_item
    cmp r0, #0xc                            @ 0801548C  compare set_item with 12 (0xC)
    blt .L08015680                          @ 0801548E  if set_item <s 12 (0xC)
    movs r0, #0x0                           @ 08015492
    ldr.w r1, =set_item                     @ 08015494
    strb r0, [r1, #0x0]                     @ 08015498  set_item = 0
    b .L08015680                            @ 0801549A
.L0801549C:  @ reached from 0801546C bne (meter_mode != 2), 08015476 bne (acdc_active != 0)
    ldr.w r0, =meter_mode                   @ 0801549C
    ldrb r0, [r0, #0x0]                     @ 080154A0  r0 = meter_mode
    cmp r0, #0xd                            @ 080154A2  compare meter_mode with 13 (0xD)
    beq .L080154D8                          @ 080154A4  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 080154A6
    ldrb r0, [r0, #0x0]                     @ 080154AA  r0 = meter_mode
    cmp r0, #0xe                            @ 080154AC  compare meter_mode with 14 (0xE)
    beq .L080154D8                          @ 080154AE  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 080154B0
    ldrb r0, [r0, #0x0]                     @ 080154B4  r0 = meter_mode
    cmp r0, #0xf                            @ 080154B6  compare meter_mode with 15 (0xF)
    beq .L080154D8                          @ 080154B8  if meter_mode == 15 (0xF)
    ldr.w r0, =meter_mode                   @ 080154BA
    ldrb r0, [r0, #0x0]                     @ 080154BE  r0 = meter_mode
    cmp r0, #0x16                           @ 080154C0  compare meter_mode with 22 (0x16)
    beq .L080154D8                          @ 080154C2  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 080154C4
    ldrb r0, [r0, #0x0]                     @ 080154C8  r0 = meter_mode
    cmp r0, #0x17                           @ 080154CA  compare meter_mode with 23 (0x17)
    beq .L080154D8                          @ 080154CC  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 080154CE
    ldrb r0, [r0, #0x0]                     @ 080154D2  r0 = meter_mode
    cmp r0, #0x18                           @ 080154D4  compare meter_mode with 24 (0x18)
    bne .L08015552                          @ 080154D6  if meter_mode != 24 (0x18)
.L080154D8:  @ reached from 080154A4 beq (meter_mode == 13 (0xD)), 080154AE beq (meter_mode == 14 (0xE)), 080154B8 beq (meter_mode == 15 (0xF)), 080154C2 beq (meter_mode == 22 (0x16)), 080154CC beq (meter_mode == 23 (0x17))
    ldr.w r0, =set_item                     @ 080154D8
    ldrb r0, [r0, #0x0]                     @ 080154DC  r0 = set_item
    adds r0, r0, #0x1                       @ 080154DE  r0 = set_item + 1
    ldr.w r1, =set_item                     @ 080154E0
    strb r0, [r1, #0x0]                     @ 080154E4  set_item = (set_item + 1)
    ldr.w r0, =set_item                     @ 080154E6
    ldrb r0, [r0, #0x0]                     @ 080154EA  r0 = set_item
    cmp r0, #0xb                            @ 080154EC  compare set_item with 11 (0xB)
    bne .L080154FE                          @ 080154EE  if set_item != 11 (0xB)
    ldr.w r0, =set_va_bd                    @ 080154F0
    ldrb r0, [r0, #0x0]                     @ 080154F4  r0 = set_va_bd
    ldr.w r1, =set_va_bd_edit               @ 080154F6
    strb r0, [r1, #0x0]                     @ 080154FA  set_va_bd_edit = set_va_bd
    b .L0801552E                            @ 080154FC
.L080154FE:  @ reached from 080154EE bne (set_item != 11 (0xB))
    ldr.w r0, =set_va_bd                    @ 080154FE
    ldrb r0, [r0, #0x0]                     @ 08015502  r0 = set_va_bd
    cmp r0, #0x0                            @ 08015504  compare set_va_bd with 0
    beq .L0801551C                          @ 08015506  if set_va_bd == 0
    ldr.w r0, =set_item                     @ 08015508
    ldrb r0, [r0, #0x0]                     @ 0801550C  r0 = set_item
    cmp r0, #0xd                            @ 0801550E  compare set_item with 13 (0xD)
    blt .L0801552E                          @ 08015510  if set_item <s 13 (0xD)
    movs r0, #0x0                           @ 08015512
    ldr.w r1, =set_item                     @ 08015514
    strb r0, [r1, #0x0]                     @ 08015518  set_item = 0
    b .L0801552E                            @ 0801551A
.L0801551C:  @ reached from 08015506 beq (set_va_bd == 0)
    ldr.w r0, =set_item                     @ 0801551C
    ldrb r0, [r0, #0x0]                     @ 08015520  r0 = set_item
    cmp r0, #0xc                            @ 08015522  compare set_item with 12 (0xC)
    blt .L0801552E                          @ 08015524  if set_item <s 12 (0xC)
    movs r0, #0x0                           @ 08015526
    ldr.w r1, =set_item                     @ 08015528
    strb r0, [r1, #0x0]                     @ 0801552C  set_item = 0
.L0801552E:  @ reached from 080154FC b, 08015510 blt (set_item <s 13 (0xD)), 0801551A b, 08015524 blt (set_item <s 12 (0xC))
    ldr.w r0, =set_item                     @ 0801552E
    ldrb r0, [r0, #0x0]                     @ 08015532  r0 = set_item
    cmp r0, #0xa                            @ 08015534  compare set_item with 10 (0xA)
    bne .L0801553C                          @ 08015536  if set_item != 10 (0xA)
    bl fn_0800D6E0                          @ 08015538  default setup item preparation [r0=set_item]
.L0801553C:  @ reached from 08015536 bne (set_item != 10 (0xA))
    ldr.w r0, =set_item                     @ 0801553C
    ldrb r0, [r0, #0x0]                     @ 08015540  r0 = set_item
    cmp r0, #0xc                            @ 08015542  compare set_item with 12 (0xC)
    bne .L08015680                          @ 08015544  if set_item != 12 (0xC)
    movs r0, #0x64                          @ 08015548
    ldr.w r1, =set_item_timer               @ 0801554A
    strb r0, [r1, #0x0]                     @ 0801554E  set_item_timer = 100 (0x64)
    b .L08015680                            @ 08015550
.L08015552:  @ reached from 080154D6 bne (meter_mode != 24 (0x18))
    ldr.w r0, =meter_mode                   @ 08015552
    ldrb r0, [r0, #0x0]                     @ 08015556  r0 = meter_mode
    cmp r0, #0x10                           @ 08015558  compare meter_mode with 16 (0x10)
    beq .L08015570                          @ 0801555A  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 0801555C
    ldrb r0, [r0, #0x0]                     @ 08015560  r0 = meter_mode
    cmp r0, #0x12                           @ 08015562  compare meter_mode with 18 (0x12)
    beq .L08015570                          @ 08015564  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 08015566
    ldrb r0, [r0, #0x0]                     @ 0801556A  r0 = meter_mode
    cmp r0, #0x14                           @ 0801556C  compare meter_mode with 20 (0x14)
    bne .L080155AA                          @ 0801556E  if meter_mode != 20 (0x14)
.L08015570:  @ reached from 0801555A beq (meter_mode == 16 (0x10)), 08015564 beq (meter_mode == 18 (0x12))
    ldr.w r0, =set_item                     @ 08015570
    ldrb r0, [r0, #0x0]                     @ 08015574  r0 = set_item
    adds r0, r0, #0x1                       @ 08015576  r0 = set_item + 1
    ldr.w r1, =set_item                     @ 08015578
    strb r0, [r1, #0x0]                     @ 0801557C  set_item = (set_item + 1)
    ldr.w r0, =set_item                     @ 0801557E
    ldrb r0, [r0, #0x0]                     @ 08015582  r0 = set_item
    cmp r0, #0xa                            @ 08015584  compare set_item with 10 (0xA)
    bne .L08015596                          @ 08015586  if set_item != 10 (0xA)
    ldr.w r0, =set_cur_opt                  @ 08015588
    ldrb r0, [r0, #0x0]                     @ 0801558C  r0 = set_cur_opt
    ldr.w r1, =set_cur_opt_edit             @ 0801558E
    strb r0, [r1, #0x0]                     @ 08015592  set_cur_opt_edit = set_cur_opt
    b .L08015680                            @ 08015594
.L08015596:  @ reached from 08015586 bne (set_item != 10 (0xA))
    ldr.w r0, =set_item                     @ 08015596
    ldrb r0, [r0, #0x0]                     @ 0801559A  r0 = set_item
    cmp r0, #0xc                            @ 0801559C  compare set_item with 12 (0xC)
    blt .L08015680                          @ 0801559E  if set_item <s 12 (0xC)
    movs r0, #0x0                           @ 080155A0
    ldr.w r1, =set_item                     @ 080155A2
    strb r0, [r1, #0x0]                     @ 080155A6  set_item = 0
    b .L08015680                            @ 080155A8
.L080155AA:  @ reached from 0801556E bne (meter_mode != 20 (0x14))
    ldr.w r0, =meter_mode                   @ 080155AA
    ldrb r0, [r0, #0x0]                     @ 080155AE  r0 = meter_mode
    cmp r0, #0x11                           @ 080155B0  compare meter_mode with 17 (0x11)
    beq .L080155C8                          @ 080155B2  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 080155B4
    ldrb r0, [r0, #0x0]                     @ 080155B8  r0 = meter_mode
    cmp r0, #0x13                           @ 080155BA  compare meter_mode with 19 (0x13)
    beq .L080155C8                          @ 080155BC  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 080155BE
    ldrb r0, [r0, #0x0]                     @ 080155C2  r0 = meter_mode
    cmp r0, #0x15                           @ 080155C4  compare meter_mode with 21 (0x15)
    bne .L08015620                          @ 080155C6  if meter_mode != 21 (0x15)
.L080155C8:  @ reached from 080155B2 beq (meter_mode == 17 (0x11)), 080155BC beq (meter_mode == 19 (0x13))
    ldr.w r0, =set_item                     @ 080155C8
    ldrb r0, [r0, #0x0]                     @ 080155CC  r0 = set_item
    adds r0, r0, #0x1                       @ 080155CE  r0 = set_item + 1
    ldr.w r1, =set_item                     @ 080155D0
    strb r0, [r1, #0x0]                     @ 080155D4  set_item = (set_item + 1)
    ldr.w r0, =set_item                     @ 080155D6
    ldrb r0, [r0, #0x0]                     @ 080155DA  r0 = set_item
    cmp r0, #0xa                            @ 080155DC  compare set_item with 10 (0xA)
    bne .L080155EE                          @ 080155DE  if set_item != 10 (0xA)
    ldr.w r0, =set_cur_opt                  @ 080155E0
    ldrb r0, [r0, #0x0]                     @ 080155E4  r0 = set_cur_opt
    ldr.w r1, =set_cur_opt_edit             @ 080155E6
    strb r0, [r1, #0x0]                     @ 080155EA  set_cur_opt_edit = set_cur_opt
    b .L08015680                            @ 080155EC
.L080155EE:  @ reached from 080155DE bne (set_item != 10 (0xA))
    ldr.w r0, =set_cur_opt                  @ 080155EE
    ldrb r0, [r0, #0x0]                     @ 080155F2  r0 = set_cur_opt
    cmp r0, #0x0                            @ 080155F4  compare set_cur_opt with 0
    beq .L0801560C                          @ 080155F6  if set_cur_opt == 0
    ldr.w r0, =set_item                     @ 080155F8
    ldrb r0, [r0, #0x0]                     @ 080155FC  r0 = set_item
    cmp r0, #0xc                            @ 080155FE  compare set_item with 12 (0xC)
    blt .L08015680                          @ 08015600  if set_item <s 12 (0xC)
    movs r0, #0x0                           @ 08015602
    ldr.w r1, =set_item                     @ 08015604
    strb r0, [r1, #0x0]                     @ 08015608  set_item = 0
    b .L08015680                            @ 0801560A
.L0801560C:  @ reached from 080155F6 beq (set_cur_opt == 0)
    ldr.w r0, =set_item                     @ 0801560C
    ldrb r0, [r0, #0x0]                     @ 08015610  r0 = set_item
    cmp r0, #0xb                            @ 08015612  compare set_item with 11 (0xB)
    blt .L08015680                          @ 08015614  if set_item <s 11 (0xB)
    movs r0, #0x0                           @ 08015616
    ldr.w r1, =set_item                     @ 08015618
    strb r0, [r1, #0x0]                     @ 0801561C  set_item = 0
    b .L08015680                            @ 0801561E
.L08015620:  @ reached from 080155C6 bne (meter_mode != 21 (0x15))
    ldr.w r0, =meter_mode                   @ 08015620
    ldrb r0, [r0, #0x0]                     @ 08015624  r0 = meter_mode
    cmp r0, #0xb                            @ 08015626  compare meter_mode with 11 (0xB)
    beq .L0801563E                          @ 08015628  if meter_mode == 11 (0xB)
    ldr.w r0, =meter_mode                   @ 0801562A
    ldrb r0, [r0, #0x0]                     @ 0801562E  r0 = meter_mode
    cmp r0, #0xa                            @ 08015630  compare meter_mode with 10 (0xA)
    beq .L0801563E                          @ 08015632  if meter_mode == 10 (0xA)
    ldr.w r0, =meter_mode                   @ 08015634
    ldrb r0, [r0, #0x0]                     @ 08015638  r0 = meter_mode
    cmp r0, #0x4                            @ 0801563A  compare meter_mode with 4
    bne .L08015660                          @ 0801563C  if meter_mode != 4
.L0801563E:  @ reached from 08015628 beq (meter_mode == 11 (0xB)), 08015632 beq (meter_mode == 10 (0xA))
    ldr.w r0, =set_item                     @ 0801563E
    ldrb r0, [r0, #0x0]                     @ 08015642  r0 = set_item
    adds r0, r0, #0x1                       @ 08015644  r0 = set_item + 1
    ldr.w r1, =set_item                     @ 08015646
    strb r0, [r1, #0x0]                     @ 0801564A  set_item = (set_item + 1)
    ldr.w r0, =set_item                     @ 0801564C
    ldrb r0, [r0, #0x0]                     @ 08015650  r0 = set_item
    cmp r0, #0xb                            @ 08015652  compare set_item with 11 (0xB)
    blt .L08015680                          @ 08015654  if set_item <s 11 (0xB)
    movs r0, #0x0                           @ 08015656
    ldr.w r1, =set_item                     @ 08015658
    strb r0, [r1, #0x0]                     @ 0801565C  set_item = 0
    b .L08015680                            @ 0801565E
.L08015660:  @ reached from 0801563C bne (meter_mode != 4)
    ldr.w r0, =set_item                     @ 08015660
    ldrb r0, [r0, #0x0]                     @ 08015664  r0 = set_item
    adds r0, r0, #0x1                       @ 08015666  r0 = set_item + 1
    ldr.w r1, =set_item                     @ 08015668
    strb r0, [r1, #0x0]                     @ 0801566C  set_item = (set_item + 1)
    ldr.w r0, =set_item                     @ 0801566E
    ldrb r0, [r0, #0x0]                     @ 08015672  r0 = set_item
    cmp r0, #0xa                            @ 08015674  compare set_item with 10 (0xA)
    blt .L08015680                          @ 08015676  if set_item <s 10 (0xA)
    movs r0, #0x0                           @ 08015678
    ldr.w r1, =set_item                     @ 0801567A
    strb r0, [r1, #0x0]                     @ 0801567E  set_item = 0
.L08015680:  @ reached from 08015462 b, 0801548E blt (set_item <s 12 (0xC)), 0801549A b, 08015544 bne (set_item != 12 (0xC)), 08015550 b, 08015594 b, 0801559E blt (set_item <s 12 (0xC)), 080155A8 b, 080155EC b, 08015600 blt (set_item <s 12 (0xC)), 0801560A b, 08015614 blt (set_item <s 11 (0xB)), 0801561E b, 08015654 blt (set_item <s 11 (0xB)), 0801565E b, 08015676 blt (set_item <s 10 (0xA))
    @ IMP-07: a wrap of the item to 0 (set_item + 1 reached the mode's limit) lands on the page bL instead; an item that is
    @ already 0 here can only come from a wrap, because the item-8 digit cursor path keeps 8 and every other path adds 1
    ldr.w r0, =set_item
    ldrb r1, [r0, #0x0]
    cbnz r1, .Lsn_no_wrap
    movs r1, #SET_ITEM_BL
    strb r1, [r0, #0x0]                     @ set_item = 20
.Lsn_no_wrap:
    ldr.w r0, =set_item                     @ 08015680
    ldrb r0, [r0, #0x0]                     @ 08015684  r0 = set_item
    cmp r0, #0x5                            @ 08015686  compare set_item with 5
    bne .L08015698                          @ 08015688  if set_item != 5
    ldr.w r0, =set_year                     @ 0801568A
    ldrb r0, [r0, #0x0]                     @ 0801568E  r0 = set_year
    ldr.w r1, =set_year_edit                @ 08015690
    strb r0, [r1, #0x0]                     @ 08015694  set_year_edit = set_year
    b .L08015726                            @ 08015696
.L08015698:  @ reached from 08015688 bne (set_item != 5)
    ldr.w r0, =set_item                     @ 08015698
    ldrb r0, [r0, #0x0]                     @ 0801569C  r0 = set_item
    cmp r0, #0x6                            @ 0801569E  compare set_item with 6
    bne .L080156C4                          @ 080156A0  if set_item != 6
    ldr.w r0, =set_month                    @ 080156A2
    ldrb r0, [r0, #0x0]                     @ 080156A6  r0 = set_month
    ldr.w r1, =set_month_edit               @ 080156A8
    strb r0, [r1, #0x0]                     @ 080156AC  set_month_edit = set_month
    ldr.w r0, =set_day                      @ 080156AE
    ldrb r0, [r0, #0x0]                     @ 080156B2  r0 = set_day
    ldr.w r1, =set_day_edit                 @ 080156B4
    strb r0, [r1, #0x0]                     @ 080156B8  set_day_edit = set_day
    movs r0, #0x0                           @ 080156BA
    ldr.w r1, =set_stage                    @ 080156BC
    strb r0, [r1, #0x0]                     @ 080156C0  set_stage = 0
    b .L08015726                            @ 080156C2
.L080156C4:  @ reached from 080156A0 bne (set_item != 6)
    ldr.w r0, =set_item                     @ 080156C4
    ldrb r0, [r0, #0x0]                     @ 080156C8  r0 = set_item
    cmp r0, #0x7                            @ 080156CA  compare set_item with 7
    bne .L080156F0                          @ 080156CC  if set_item != 7
    ldr.w r0, =set_hour                     @ 080156CE
    ldrb r0, [r0, #0x0]                     @ 080156D2  r0 = set_hour
    ldr.w r1, =set_hour_edit                @ 080156D4
    strb r0, [r1, #0x0]                     @ 080156D8  set_hour_edit = set_hour
    ldr.w r0, =set_minute                   @ 080156DA
    ldrb r0, [r0, #0x0]                     @ 080156DE  r0 = set_minute
    ldr.w r1, =set_minute_edit              @ 080156E0
    strb r0, [r1, #0x0]                     @ 080156E4  set_minute_edit = set_minute
    movs r0, #0x0                           @ 080156E6
    ldr.w r1, =set_stage                    @ 080156E8
    strb r0, [r1, #0x0]                     @ 080156EC  set_stage = 0
    b .L08015726                            @ 080156EE
.L080156F0:  @ reached from 080156CC bne (set_item != 7)
    ldr.w r0, =set_edit                     @ 080156F0
    ldrb r0, [r0, #0x0]                     @ 080156F4  r0 = set_edit
    cmp r0, #0x0                            @ 080156F6  compare set_edit with 0
    bne .L08015712                          @ 080156F8  if set_edit != 0
    ldr.w r0, =set_item                     @ 080156FA
    ldrb r0, [r0, #0x0]                     @ 080156FE  r0 = set_item
    cmp r0, #0x8                            @ 08015700  compare set_item with 8
    bne .L08015712                          @ 08015702  if set_item != 8
    ldr.w r0, =set_id                       @ 08015704
    ldr r0, [r0, #0x0]                      @ 08015708  r0 = set_id
    ldr.w r1, =set_id_edit                  @ 0801570A
    str r0, [r1, #0x0]                      @ 0801570E  set_id_edit = set_id
    b .L08015726                            @ 08015710
.L08015712:  @ reached from 080156F8 bne (set_edit != 0), 08015702 bne (set_item != 8)
    ldr.w r0, =set_item                     @ 08015712
    ldrb r0, [r0, #0x0]                     @ 08015714  r0 = set_item
    cmp r0, #0x9                            @ 08015716  compare set_item with 9
    bne .L08015726                          @ 08015718  if set_item != 9
    ldr.w r0, =set_log_interval             @ 0801571A
    ldrh r0, [r0, #0x0]                     @ 0801571E  r0 = set_log_interval
    ldr.w r1, =set_interval_edit            @ 08015720
    strh r0, [r1, #0x0]                     @ 08015724  set_interval_edit = set_log_interval
.L08015726:  @ reached from 08015696 b, 080156C2 b, 080156EE b, 08015710 b, 08015718 bne (set_item != 9)
    pop {r0, pc}                            @ 08015726
ENDFUNC fn_08015410
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015A22 - item 2 (APO) edit action
@ Replaces : 0x08015A22 FUN_08015A22 (v2.05)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : writes set_apo_disable, set_redraw
@ Spec     : analysis/keys_setup.md 4 (SETUP menu)
@ Note     : Up or down steps through APO.oF, APO. 1, APO.15, APO.30, APO.60 (IMP-49, set/apot.s set_apot_step; v2.05
@            toggles set_apo_disable) and updates the APO annunciator (fn_08019C5C); save writes EEPROM 0x016
@            (fn_080112EC) and the time code 0x02B (set_apot_store).
@ -----------------------------------------------------------------------------
FUNC fn_08015A22
    push {r4, lr}                           @ 08015A22
    movs r4, r0                             @ 08015A24
    uxtb r4, r4                             @ 08015A26
    cmp r4, #0x1                            @ 08015A28  compare r4 with 1
    beq .L08015A32                          @ 08015A2A  if r4 == 1
    uxtb r4, r4                             @ 08015A2C
    cmp r4, #0x2                            @ 08015A2E  compare r4 with 2
    bne .L08015A58                          @ 08015A30  if r4 != 2
.L08015A32:  @ reached from 08015A2A beq (r4 == 1)
    mov r0, r4                              @ IMP-49: 1 next, 2 previous of the five values (v2.05 0x08015A32..0x08015A4E
    bl set_apot_step                        @ toggled set_apo_disable)
.L08015A50:  @ reached from 08015A46 b
    movs r0, #0x1                           @ 08015A50
    bl fn_08019C5C                          @ 08015A52  APO annunciator update [r0=1]
    b .L08015A62                            @ 08015A56
.L08015A58:  @ reached from 08015A30 bne (r4 != 2)
    ldr.w r0, =set_apo_disable              @ 08015A58
    ldrb r0, [r0, #0x0]                     @ 08015A5C  r0 = set_apo_disable
    bl fn_080112EC                          @ 08015A5E  save the APO setting [r0=set_apo_disable]
    bl set_apot_store                       @ IMP-49: and the time code (EEPROM 0x02B)
.L08015A62:  @ reached from 08015A56 b
    movs r0, #0x1                           @ 08015A62
    ldr.w r1, =set_redraw                   @ 08015A64
    strb r0, [r1, #0x0]                     @ 08015A66  set_redraw = 1
    pop {r4, pc}                            @ 08015A68
ENDFUNC fn_08015A22
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015A74 - item 3 (buzzer) edit action
@ Replaces : 0x08015A74 FUN_08015A74 (v2.05)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : writes set_buzzer_on, set_redraw
@ Spec     : analysis/keys_setup.md 4 (SETUP menu)
@ Note     : Up or down toggles set_buzzer_on; save writes EEPROM 0x01E (fn_08011438).
@ -----------------------------------------------------------------------------
FUNC fn_08015A74
    push {r4, lr}                           @ 08015A74
    movs r4, r0                             @ 08015A76
    uxtb r4, r4                             @ 08015A78
    cmp r4, #0x1                            @ 08015A7A  compare r4 with 1
    beq .L08015A84                          @ 08015A7C  if r4 == 1
    uxtb r4, r4                             @ 08015A7E
    cmp r4, #0x2                            @ 08015A80  compare r4 with 2
    bne .L08015AA4                          @ 08015A82  if r4 != 2
.L08015A84:  @ reached from 08015A7C beq (r4 == 1)
    ldr.w r0, =set_buzzer_on                @ 08015A84
    ldrb r0, [r0, #0x0]                     @ 08015A88  r0 = set_buzzer_on
    teq r0, #0x1                            @ 08015A8A  test set_buzzer_on ^ 1
    beq .L08015A9A                          @ 08015A8E  if set_buzzer_on == 1
    movs r0, #0x1                           @ 08015A90
    ldr.w r1, =set_buzzer_on                @ 08015A92
    strb r0, [r1, #0x0]                     @ 08015A96  set_buzzer_on = 1
    b .L08015AAE                            @ 08015A98
.L08015A9A:  @ reached from 08015A8E beq (set_buzzer_on == 1)
    movs r0, #0x0                           @ 08015A9A
    ldr.w r1, =set_buzzer_on                @ 08015A9C
    strb r0, [r1, #0x0]                     @ 08015AA0  set_buzzer_on = 0
    b .L08015AAE                            @ 08015AA2
.L08015AA4:  @ reached from 08015A82 bne (r4 != 2)
    ldr.w r0, =set_buzzer_on                @ 08015AA4
    ldrb r0, [r0, #0x0]                     @ 08015AA8  r0 = set_buzzer_on
    bl fn_08011438                          @ 08015AAA  save the buzzer setting [r0=set_buzzer_on]
.L08015AAE:  @ reached from 08015A98 b, 08015AA2 b
    movs r0, #0x1                           @ 08015AAE
    ldr.w r1, =set_redraw                   @ 08015AB0
    strb r0, [r1, #0x0]                     @ 08015AB2  set_redraw = 1
    pop {r4, pc}                            @ 08015AB4
ENDFUNC fn_08015A74
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015AC0 - item 9 (logging interval) edit action
@ Replaces : 0x08015AC0 FUN_08015AC0 (v2.05)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : writes set_interval_edit, set_log_interval, set_redraw
@ Spec     : analysis/keys_setup.md 4 (SETUP menu)
@ Note     : Up increments set_interval_edit 0..999 with wrap, down decrements; save copies it to set_log_interval and
@            writes EEPROM 0x018 (fn_08011248).
@ -----------------------------------------------------------------------------
FUNC fn_08015AC0
    push {r4, lr}                           @ 08015AC0
    movs r4, r0                             @ 08015AC2
    uxtb r4, r4                             @ 08015AC4
    cmp r4, #0x1                            @ 08015AC6  compare r4 with 1
    bne .L08015AF2                          @ 08015AC8  if r4 != 1
    ldr.w r0, =set_interval_edit            @ 08015ACA
    ldrh r0, [r0, #0x0]                     @ 08015ACE  r0 = set_interval_edit
    movw r1, #0x3e7                         @ 08015AD0
    cmp r0, r1                              @ 08015AD4  compare set_interval_edit with 999 (0x3E7)
    blt .L08015AE2                          @ 08015AD6  if set_interval_edit <s 999 (0x3E7)
    movs r0, #0x0                           @ 08015AD8
    ldr.w r1, =set_interval_edit            @ 08015ADA
    strh r0, [r1, #0x0]                     @ 08015ADE  set_interval_edit = 0
    b .L08015B34                            @ 08015AE0
.L08015AE2:  @ reached from 08015AD6 blt (set_interval_edit <s 999 (0x3E7))
    ldr.w r0, =set_interval_edit            @ 08015AE2
    ldrh r0, [r0, #0x0]                     @ 08015AE6  r0 = set_interval_edit
    adds r0, r0, #0x1                       @ 08015AE8  r0 = set_interval_edit + 1
    ldr.w r1, =set_interval_edit            @ 08015AEA
    strh r0, [r1, #0x0]                     @ 08015AEE  set_interval_edit = (set_interval_edit + 1)
    b .L08015B34                            @ 08015AF0
.L08015AF2:  @ reached from 08015AC8 bne (r4 != 1)
    uxtb r4, r4                             @ 08015AF2
    cmp r4, #0x2                            @ 08015AF4  compare r4 with 2
    bne .L08015B1E                          @ 08015AF6  if r4 != 2
    ldr.w r0, =set_interval_edit            @ 08015AF8
    ldrh r0, [r0, #0x0]                     @ 08015AFC  r0 = set_interval_edit
    cmp r0, #0x0                            @ 08015AFE  compare set_interval_edit with 0
    bne .L08015B0E                          @ 08015B00  if set_interval_edit != 0
    movw r0, #0x3e7                         @ 08015B02
    ldr.w r1, =set_interval_edit            @ 08015B06
    strh r0, [r1, #0x0]                     @ 08015B0A  set_interval_edit = 999 (0x3E7)
    b .L08015B34                            @ 08015B0C
.L08015B0E:  @ reached from 08015B00 bne (set_interval_edit != 0)
    ldr.w r0, =set_interval_edit            @ 08015B0E
    ldrh r0, [r0, #0x0]                     @ 08015B12  r0 = set_interval_edit
    subs r0, r0, #0x1                       @ 08015B14  r0 = set_interval_edit - 1
    ldr.w r1, =set_interval_edit            @ 08015B16
    strh r0, [r1, #0x0]                     @ 08015B1A  set_interval_edit = (set_interval_edit - 1)
    b .L08015B34                            @ 08015B1C
.L08015B1E:  @ reached from 08015AF6 bne (r4 != 2)
    ldr.w r0, =set_interval_edit            @ 08015B1E
    ldrh r0, [r0, #0x0]                     @ 08015B22  r0 = set_interval_edit
    ldr.w r1, =set_log_interval             @ 08015B24
    strh r0, [r1, #0x0]                     @ 08015B28  set_log_interval = set_interval_edit
    ldr.w r0, =set_log_interval             @ 08015B2A
    ldrh r0, [r0, #0x0]                     @ 08015B2E  r0 = set_log_interval
    bl fn_08011248                          @ 08015B30  save the logging interval [r0=set_log_interval, r1=&set_log_interval]
.L08015B34:  @ reached from 08015AE0 b, 08015AF0 b, 08015B0C b, 08015B1C b
    movs r0, #0x1                           @ 08015B34
    ldr.w r1, =set_redraw                   @ 08015B36
    strb r0, [r1, #0x0]                     @ 08015B3A  set_redraw = 1
    pop {r4, pc}                            @ 08015B3C
ENDFUNC fn_08015AC0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015B54 - item 4 (LCD contrast) edit action
@ Replaces : 0x08015B54 FUN_08015B54 (v2.05)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : writes lcd_contrast, set_redraw
@ Spec     : analysis/keys_setup.md 4 (SETUP menu)
@ Note     : Up increments set_lcd_contrast 10..17 with wrap (17 to 10), down decrements (10 to 17); the new value is
@            applied at once with lcd_init; save writes EEPROM 0x01A (fn_08011294).  Values 10 and 11 are kept across
@            a power cycle (OF-38/NF-17).
@ -----------------------------------------------------------------------------
FUNC fn_08015B54
    push {r4, lr}                           @ 08015B54
    movs r4, r0                             @ 08015B56
    uxtb r4, r4                             @ 08015B58
    cmp r4, #0x1                            @ 08015B5A  compare r4 with 1
    bne .L08015B82                          @ 08015B5C  if r4 != 1
    ldr.w r0, =lcd_contrast                 @ 08015B5E
    ldrb r0, [r0, #0x0]                     @ 08015B62  r0 = lcd_contrast
    cmp r0, #0x11                           @ 08015B64  compare lcd_contrast with 17 (0x11)
    bne .L08015B72                          @ 08015B66  if lcd_contrast != 17 (0x11)
    movs r0, #0xa                           @ 08015B68
    ldr.w r1, =lcd_contrast                 @ 08015B6A
    strb r0, [r1, #0x0]                     @ 08015B6E  lcd_contrast = 10 (0xA)
    b .L08015BB6                            @ 08015B70
.L08015B72:  @ reached from 08015B66 bne (lcd_contrast != 17 (0x11))
    ldr.w r0, =lcd_contrast                 @ 08015B72
    ldrb r0, [r0, #0x0]                     @ 08015B76  r0 = lcd_contrast
    adds r0, r0, #0x1                       @ 08015B78  r0 = lcd_contrast + 1
    ldr.w r1, =lcd_contrast                 @ 08015B7A
    strb r0, [r1, #0x0]                     @ 08015B7E  lcd_contrast = (lcd_contrast + 1)
    b .L08015BB6                            @ 08015B80
.L08015B82:  @ reached from 08015B5C bne (r4 != 1)
    uxtb r4, r4                             @ 08015B82
    cmp r4, #0x2                            @ 08015B84  compare r4 with 2
    bne .L08015BAC                          @ 08015B86  if r4 != 2
    ldr.w r0, =lcd_contrast                 @ 08015B88
    ldrb r0, [r0, #0x0]                     @ 08015B8C  r0 = lcd_contrast
    cmp r0, #0xa                            @ 08015B8E  compare lcd_contrast with 10 (0xA)
    bne .L08015B9C                          @ 08015B90  if lcd_contrast != 10 (0xA)
    movs r0, #0x11                          @ 08015B92
    ldr.w r1, =lcd_contrast                 @ 08015B94
    strb r0, [r1, #0x0]                     @ 08015B98  lcd_contrast = 17 (0x11)
    b .L08015BB6                            @ 08015B9A
.L08015B9C:  @ reached from 08015B90 bne (lcd_contrast != 10 (0xA))
    ldr.w r0, =lcd_contrast                 @ 08015B9C
    ldrb r0, [r0, #0x0]                     @ 08015BA0  r0 = lcd_contrast
    subs r0, r0, #0x1                       @ 08015BA2  r0 = lcd_contrast - 1
    ldr.w r1, =lcd_contrast                 @ 08015BA4
    strb r0, [r1, #0x0]                     @ 08015BA8  lcd_contrast = (lcd_contrast - 1)
    b .L08015BB6                            @ 08015BAA
.L08015BAC:  @ reached from 08015B86 bne (r4 != 2)
    ldr.w r0, =lcd_contrast                 @ 08015BAC
    ldrb r0, [r0, #0x0]                     @ 08015BB0  r0 = lcd_contrast
    bl fn_08011294                          @ 08015BB2  save the contrast [r0=lcd_contrast]
.L08015BB6:  @ reached from 08015B70 b, 08015B80 b, 08015B9A b, 08015BAA b
    movs r1, #0x0                           @ 08015BB6
    ldr.w r0, =lcd_contrast                 @ 08015BB8
    ldrb r0, [r0, #0x0]                     @ 08015BBC  r0 = lcd_contrast
    bl lcd_init                             @ 08015BBE  initialise the LCD, r0 = contrast [r0=lcd_contrast, r1=0]
    movs r0, #0x1                           @ 08015BC2
    ldr.w r1, =set_redraw                   @ 08015BC4
    strb r0, [r1, #0x0]                     @ 08015BC8  set_redraw = 1
    pop {r4, pc}                            @ 08015BCA
ENDFUNC fn_08015B54
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015BE0 - item 0 (temperature unit) edit action
@ Replaces : 0x08015BE0 FUN_08015BE0 (v2.05)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : writes set_redraw, set_temp_celsius
@ Spec     : analysis/keys_setup.md 4 (SETUP menu)
@ Note     : Up or down toggles set_temp_celsius and updates the unit annunciator (fn_0801A3A4); save writes EEPROM
@            0x010 (fn_08011330).
@ -----------------------------------------------------------------------------
FUNC fn_08015BE0
    push {r4, lr}                           @ 08015BE0
    movs r4, r0                             @ 08015BE2
    uxtb r4, r4                             @ 08015BE4
    cmp r4, #0x1                            @ 08015BE6  compare r4 with 1
    beq .L08015BF0                          @ 08015BE8  if r4 == 1
    uxtb r4, r4                             @ 08015BEA
    cmp r4, #0x2                            @ 08015BEC  compare r4 with 2
    bne .L08015C06                          @ 08015BEE  if r4 != 2
.L08015BF0:  @ reached from 08015BE8 beq (r4 == 1)
    ldr.w r0, =set_temp_celsius             @ 08015BF0
    ldrb r0, [r0, #0x0]                     @ 08015BF4  r0 = set_temp_celsius
    eors r0, r0, #0x1                       @ 08015BF6  r0 = set_temp_celsius ^ 1
    ldr.w r1, =set_temp_celsius             @ 08015BFA
    strb r0, [r1, #0x0]                     @ 08015BFE  set_temp_celsius = (set_temp_celsius ^ 1)
    bl fn_0801A3A4                          @ 08015C00  temperature unit annunciator [r0=(set_temp_celsius ^ 1), r1=&set_temp_celsius]
    b .L08015C10                            @ 08015C04
.L08015C06:  @ reached from 08015BEE bne (r4 != 2)
    ldr.w r0, =set_temp_celsius             @ 08015C06
    ldrb r0, [r0, #0x0]                     @ 08015C0A  r0 = set_temp_celsius
    bl fn_08011330                          @ 08015C0C  save the temperature unit [r0=set_temp_celsius]
.L08015C10:  @ reached from 08015C04 b
    movs r0, #0x1                           @ 08015C10
    ldr.w r1, =set_redraw                   @ 08015C12
    strb r0, [r1, #0x0]                     @ 08015C16  set_redraw = 1
    pop {r4, pc}                            @ 08015C18
ENDFUNC fn_08015BE0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015F7C - item 8 (ID number) edit action
@ Replaces : 0x08015F7C FUN_08015F7C (v2.05)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads set_digit_pos; writes set_id, set_id_edit, set_redraw
@ Spec     : analysis/keys_setup.md 4 (SETUP menu)
@ Note     : Up or down changes the digit selected by set_digit_pos of set_id_edit (0..9 with wrap); save copies
@            set_id_edit to set_id and stores it in EEPROM 0x003..0x006 (fn_08010FB8, IDENT class).
@ -----------------------------------------------------------------------------
FUNC fn_08015F7C
    push {r4, lr}                           @ 08015F7C
    sub sp, #0x18                           @ 08015F7E
    movs r4, r0                             @ 08015F80
    uxtb r4, r4                             @ 08015F82
    cmp r4, #0x64                           @ 08015F84  compare r4 with 100 (0x64)
    bne .L08015F96                          @ 08015F86  if r4 != 100 (0x64)
    ldr.w r0, =set_id_edit                  @ 08015F88
    ldr r0, [r0, #0x0]                      @ 08015F8A  r0 = set_id_edit
    ldr.w r1, =set_id                       @ 08015F8C
    str r0, [r1, #0x0]                      @ 08015F8E  set_id = set_id_edit
    bl fn_08010FB8                          @ 08015F90  store the ID number to EEPROM 0x003 (IDENT) [r0=set_id_edit, r1=&set_id]
    b .L080160B0                            @ 08015F94
.L08015F96:  @ reached from 08015F86 bne (r4 != 100 (0x64))
    movs r0, #0xa                           @ 08015F96
    ldr.w r1, =set_id_edit                  @ 08015F98
    ldr r1, [r1, #0x0]                      @ 08015F9A  r1 = set_id_edit
    ldr.w r2, =set_id_edit                  @ 08015F9C
    ldr r2, [r2, #0x0]                      @ 08015F9E  r2 = set_id_edit
    udiv r2, r2, r0                         @ 08015FA0  r2 = set_id_edit / 10 (0xA)
    mls r0, r0, r2, r1                      @ 08015FA4  r0 = set_id_edit - 10 (0xA) * (set_id_edit / 10 (0xA))
    str r0, [sp, #0x0]                      @ 08015FA8  local [sp+0] = (set_id_edit - 10 (0xA) * (set_id_edit / 10 (0xA)))
    movs r0, #0x64                          @ 08015FAA
    ldr.w r1, =set_id_edit                  @ 08015FAC
    ldr r1, [r1, #0x0]                      @ 08015FAE  r1 = set_id_edit
    ldr.w r2, =set_id_edit                  @ 08015FB0
    ldr r2, [r2, #0x0]                      @ 08015FB2  r2 = set_id_edit
    udiv r2, r2, r0                         @ 08015FB4  r2 = set_id_edit / 100 (0x64)
    mls r0, r0, r2, r1                      @ 08015FB8  r0 = set_id_edit - 100 (0x64) * (set_id_edit / 100 (0x64))
    movs r1, #0xa                           @ 08015FBC
    udiv r0, r0, r1                         @ 08015FBE  r0 = (set_id_edit - 100 (0x64) * (set_id_edit / 100 (0x64))) / 10 (0xA)
    str r0, [sp, #0x4]                      @ 08015FC2  local [sp+4] = ((set_id_edit - 100 (0x64) * (set_id_edit / 100 (0x64))) / 10 (0xA))
    mov r0, #0x3e8                          @ 08015FC4
    ldr.w r1, =set_id_edit                  @ 08015FC8
    ldr r1, [r1, #0x0]                      @ 08015FCA  r1 = set_id_edit
    ldr.w r2, =set_id_edit                  @ 08015FCC
    ldr r2, [r2, #0x0]                      @ 08015FCE  r2 = set_id_edit
    udiv r2, r2, r0                         @ 08015FD0  r2 = set_id_edit / 1000 (0x3E8)
    mls r0, r0, r2, r1                      @ 08015FD4  r0 = set_id_edit - 1000 (0x3E8) * (set_id_edit / 1000 (0x3E8))
    movs r1, #0x64                          @ 08015FD8
    udiv r0, r0, r1                         @ 08015FDA  r0 = (set_id_edit - 1000 (0x3E8) * (set_id_edit / 1000 (0x3E8))) / 100 (0x64)
    str r0, [sp, #0x8]                      @ 08015FDE  local [sp+8] = ((set_id_edit - 1000 (0x3E8) * (set_id_edit / 1000 (0x3E8))) / 100 (0x64))
    movw r0, #0x2710                        @ 08015FE0
    ldr.w r1, =set_id_edit                  @ 08015FE4
    ldr r1, [r1, #0x0]                      @ 08015FE6  r1 = set_id_edit
    ldr.w r2, =set_id_edit                  @ 08015FE8
    ldr r2, [r2, #0x0]                      @ 08015FEA  r2 = set_id_edit
    udiv r2, r2, r0                         @ 08015FEC  r2 = set_id_edit / 10000 (0x2710)
    mls r0, r0, r2, r1                      @ 08015FF0  r0 = set_id_edit - 10000 (0x2710) * (set_id_edit / 10000 (0x2710))
    mov r1, #0x3e8                          @ 08015FF4
    udiv r0, r0, r1                         @ 08015FF8  r0 = (set_id_edit - 10000 (0x2710) * (set_id_edit / 10000 (0x2710))) / 1000 (0x3E8)
    str r0, [sp, #0xc]                      @ 08015FFC  local [sp+12] = ((set_id_edit - 10000 (0x2710) * (set_id_edit / 10000 (0x2710))) / 1000 (0x3E8))
    ldr.w r0, =set_id_edit                  @ 08015FFE
    ldr r0, [r0, #0x0]                      @ 08016000  r0 = set_id_edit
    movw r1, #0x2710                        @ 08016002
    udiv r0, r0, r1                         @ 08016006  r0 = set_id_edit / 10000 (0x2710)
    str r0, [sp, #0x10]                     @ 0801600A  local [sp+16] = (set_id_edit / 10000 (0x2710))
    uxtb r4, r4                             @ 0801600C
    cmp r4, #0x1                            @ 0801600E  compare r4 with 1
    bne .L0801604C                          @ 08016010  if r4 != 1
    mov r0, sp                              @ 08016012
    ldr.w r1, =set_digit_pos                @ 08016014
    ldrb r1, [r1, #0x0]                     @ 08016018  r1 = set_digit_pos
    ldr r0, [r0, r1, lsl #0x2]              @ 0801601A  r0 = [r0 + r1 << 0x2]
    adds r0, r0, #0x1                       @ 0801601E  r0 = r0 + 1
    mov r1, sp                              @ 08016020
    ldr.w r2, =set_digit_pos                @ 08016022
    ldrb r2, [r2, #0x0]                     @ 08016026  r2 = set_digit_pos
    str r0, [r1, r2, lsl #0x2]              @ 08016028  [r1 + r2 << 0x2] = (r0 + 1)
    mov r0, sp                              @ 0801602C
    ldr.w r1, =set_digit_pos                @ 0801602E
    ldrb r1, [r1, #0x0]                     @ 08016032  r1 = set_digit_pos
    ldr r0, [r0, r1, lsl #0x2]              @ 08016034  r0 = [r0 + r1 << 0x2]
    cmp r0, #0xa                            @ 08016038  compare r0 with 10 (0xA)
    bcc .L08016086                          @ 0801603A  if r0 <u 10 (0xA)
    movs r0, #0x0                           @ 0801603C
    mov r1, sp                              @ 0801603E
    ldr.w r2, =set_digit_pos                @ 08016040
    ldrb r2, [r2, #0x0]                     @ 08016044  r2 = set_digit_pos
    str r0, [r1, r2, lsl #0x2]              @ 08016046  [r1 + r2 << 0x2] = 0
    b .L08016086                            @ 0801604A
.L0801604C:  @ reached from 08016010 bne (r4 != 1)
    mov r0, sp                              @ 0801604C
    ldr.w r1, =set_digit_pos                @ 0801604E
    ldrb r1, [r1, #0x0]                     @ 08016052  r1 = set_digit_pos
    ldr r0, [r0, r1, lsl #0x2]              @ 08016054  r0 = [r0 + r1 << 0x2]
    cmp r0, #0x0                            @ 08016058  compare r0 with 0
    bne .L0801606C                          @ 0801605A  if r0 != 0
    movs r0, #0x9                           @ 0801605C
    mov r1, sp                              @ 0801605E
    ldr.w r2, =set_digit_pos                @ 08016060
    ldrb r2, [r2, #0x0]                     @ 08016064  r2 = set_digit_pos
    str r0, [r1, r2, lsl #0x2]              @ 08016066  [r1 + r2 << 0x2] = 9
    b .L08016086                            @ 0801606A
.L0801606C:  @ reached from 0801605A bne (r0 != 0)
    mov r0, sp                              @ 0801606C
    ldr.w r1, =set_digit_pos                @ 0801606E
    ldrb r1, [r1, #0x0]                     @ 08016072  r1 = set_digit_pos
    ldr r0, [r0, r1, lsl #0x2]              @ 08016074  r0 = [r0 + r1 << 0x2]
    subs r0, r0, #0x1                       @ 08016078  r0 = r0 - 1
    mov r1, sp                              @ 0801607A
    ldr.w r2, =set_digit_pos                @ 0801607C
    ldrb r2, [r2, #0x0]                     @ 08016080  r2 = set_digit_pos
    str r0, [r1, r2, lsl #0x2]              @ 08016082  [r1 + r2 << 0x2] = (r0 - 1)
.L08016086:  @ reached from 0801603A bcc (r0 <u 10 (0xA)), 0801604A b, 0801606A b
    ldr r0, [sp, #0x10]                     @ 08016086  r0 = local [sp+16]
    movw r1, #0x2710                        @ 08016088
    ldr r2, [sp, #0xc]                      @ 0801608C  r2 = local [sp+12]
    mov r3, #0x3e8                          @ 0801608E
    muls r2, r3                             @ 08016092  r2 = r2 * 1000 (0x3E8)
    mla r0, r1, r0, r2                      @ 08016094  r0 = 10000 (0x2710) * r0 + (r2 * 1000 (0x3E8))
    ldr r1, [sp, #0x8]                      @ 08016098  r1 = local [sp+8]
    movs r2, #0x64                          @ 0801609A
    mla r0, r2, r1, r0                      @ 0801609C  r0 = 100 (0x64) * r1 + (10000 (0x2710) * r0 + (r2 * 1000 (0x3E8)))
    ldr r1, [sp, #0x4]                      @ 080160A0  r1 = local [sp+4]
    movs r2, #0xa                           @ 080160A2
    mla r0, r2, r1, r0                      @ 080160A4  r0 = 10 (0xA) * r1 + (100 (0x64) * r1 + (10000 (0x2710) * r0 + (r2 * 1000 (0x3E8))))
    ldr r1, [sp, #0x0]                      @ 080160A8  r1 = local [sp+0]
    adds r0, r1, r0                         @ 080160AA  r0 = r1 + (10 (0xA) * r1 + (100 (0x64) * r1 + (10000 (0x2710) * r0 + (r2 * 1000 (0x3E8)))))
    ldr.w r1, =set_id_edit                  @ 080160AC
    str r0, [r1, #0x0]                      @ 080160AE  set_id_edit = (r1 + (10 (0xA) * r1 + (100 (0x64) * r1 + (10000 (0x2710) * r0 + (r2 * 1000 (0x3E8))))))
.L080160B0:  @ reached from 08015F94 b
    movs r0, #0x1                           @ 080160B0
    ldr.w r1, =set_redraw                   @ 080160B2
    strb r0, [r1, #0x0]                     @ 080160B6  set_redraw = 1
    add sp, #0x18                           @ 080160B8
    pop {r4, pc}                            @ 080160BA
ENDFUNC fn_08015F7C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080160E8 - item 10 (current option) edit action in the current modes
@ Replaces : 0x080160E8 FUN_080160E8 (v2.05)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads meter_mode; writes set_cur_opt, set_cur_opt_edit, set_redraw, v_200080C5, va_channel
@ Spec     : analysis/keys_setup.md 4 (SETUP menu)
@ Note     : Up or down toggles set_cur_opt_edit; save copies it to set_cur_opt (RAM only) and applies it through
@            fn_080080C8 (DC currents) or fn_08006774 (AC currents).
@ -----------------------------------------------------------------------------
FUNC fn_080160E8
    push {r4, lr}                           @ 080160E8
    movs r4, r0                             @ 080160EA
    uxtb r4, r4                             @ 080160EC
    cmp r4, #0x64                           @ 080160EE  compare r4 with 100 (0x64)
    bne .L0801615C                          @ 080160F0  if r4 != 100 (0x64)
    ldr.w r0, =set_cur_opt_edit             @ 080160F2
    ldrb r0, [r0, #0x0]                     @ 080160F6  r0 = set_cur_opt_edit
    ldr.w r1, =set_cur_opt                  @ 080160F8
    strb r0, [r1, #0x0]                     @ 080160FC  set_cur_opt = set_cur_opt_edit
    movs r0, #0x0                           @ 080160FE
    ldr.w r1, =va_channel                   @ 08016100
    strb r0, [r1, #0x0]                     @ 08016104  va_channel = 0
    movs r0, #0x0                           @ 08016106
    ldr.w r1, =v_200080C5                   @ 08016108
    strb r0, [r1, #0x0]                     @ 0801610C  v_200080C5 = 0
    ldr.w r0, =meter_mode                   @ 0801610E
    ldrb r0, [r0, #0x0]                     @ 08016112  r0 = meter_mode
    cmp r0, #0x11                           @ 08016114  compare meter_mode with 17 (0x11)
    beq .L0801612C                          @ 08016116  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 08016118
    ldrb r0, [r0, #0x0]                     @ 0801611C  r0 = meter_mode
    cmp r0, #0x13                           @ 0801611E  compare meter_mode with 19 (0x13)
    beq .L0801612C                          @ 08016120  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 08016122
    ldrb r0, [r0, #0x0]                     @ 08016126  r0 = meter_mode
    cmp r0, #0x15                           @ 08016128  compare meter_mode with 21 (0x15)
    bne .L08016144                          @ 0801612A  if meter_mode != 21 (0x15)
.L0801612C:  @ reached from 08016116 beq (meter_mode == 17 (0x11)), 08016120 beq (meter_mode == 19 (0x13))
    ldr.w r0, =va_channel                   @ 0801612C
    ldrb r0, [r0, #0x0]                     @ 08016130  r0 = va_channel
    cmp r0, #0x0                            @ 08016132  compare va_channel with 0
    beq .L0801613A                          @ 08016134  if va_channel == 0
    movs r0, #0x1                           @ 08016136
    b .L0801613C                            @ 08016138
.L0801613A:  @ reached from 08016134 beq (va_channel == 0)
    movs r0, #0x0                           @ 0801613A
.L0801613C:  @ reached from 08016138 b
    uxtb r0, r0                             @ 0801613C
    bl fn_080080C8                          @ 0801613E  apply the DC current burden state (r0)
    b .L0801617A                            @ 08016142
.L08016144:  @ reached from 0801612A bne (meter_mode != 21 (0x15))
    ldr.w r0, =va_channel                   @ 08016144
    ldrb r0, [r0, #0x0]                     @ 08016148  r0 = va_channel
    cmp r0, #0x0                            @ 0801614A  compare va_channel with 0
    beq .L08016152                          @ 0801614C  if va_channel == 0
    movs r0, #0x1                           @ 0801614E
    b .L08016154                            @ 08016150
.L08016152:  @ reached from 0801614C beq (va_channel == 0)
    movs r0, #0x0                           @ 08016152
.L08016154:  @ reached from 08016150 b
    uxtb r0, r0                             @ 08016154
    bl fn_08006774                          @ 08016156  apply the AC current burden state (r0)
    b .L0801617A                            @ 0801615A
.L0801615C:  @ reached from 080160F0 bne (r4 != 100 (0x64))
    ldr.w r0, =set_cur_opt_edit             @ 0801615C
    ldrb r0, [r0, #0x0]                     @ 08016160  r0 = set_cur_opt_edit
    teq r0, #0x1                            @ 08016162  test set_cur_opt_edit ^ 1
    beq .L08016172                          @ 08016166  if set_cur_opt_edit == 1
    movs r0, #0x1                           @ 08016168
    ldr.w r1, =set_cur_opt_edit             @ 0801616A
    strb r0, [r1, #0x0]                     @ 0801616E  set_cur_opt_edit = 1
    b .L0801617A                            @ 08016170
.L08016172:  @ reached from 08016166 beq (set_cur_opt_edit == 1)
    movs r0, #0x0                           @ 08016172
    ldr.w r1, =set_cur_opt_edit             @ 08016174
    strb r0, [r1, #0x0]                     @ 08016178  set_cur_opt_edit = 0
.L0801617A:  @ reached from 08016142 b, 0801615A b, 08016170 b
    movs r0, #0x1                           @ 0801617A
    ldr.w r1, =set_redraw                   @ 0801617C
    strb r0, [r1, #0x0]                     @ 08016180  set_redraw = 1
    pop {r4, pc}                            @ 08016182
ENDFUNC fn_080160E8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08016190 - item 11 (VA "bd" option) edit action
@ Replaces : 0x08016190 FUN_08016190 (v2.05)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : writes set_redraw, set_va_bd, set_va_bd_edit
@ Spec     : analysis/keys_setup.md 4 (SETUP menu)
@ Note     : Up or down toggles set_va_bd_edit; save copies it to set_va_bd and writes EEPROM 0x01B (fn_08011400).
@ -----------------------------------------------------------------------------
FUNC fn_08016190
    push {r4, lr}                           @ 08016190
    movs r4, r0                             @ 08016192
    uxtb r4, r4                             @ 08016194
    cmp r4, #0x64                           @ 08016196  compare r4 with 100 (0x64)
    bne .L080161B2                          @ 08016198  if r4 != 100 (0x64)
    ldr.w r0, =set_va_bd_edit               @ 0801619A
    ldrb r0, [r0, #0x0]                     @ 0801619E  r0 = set_va_bd_edit
    ldr.w r1, =set_va_bd                    @ 080161A0
    strb r0, [r1, #0x0]                     @ 080161A4  set_va_bd = set_va_bd_edit
    ldr.w r0, =set_va_bd                    @ 080161A6
    ldrb r0, [r0, #0x0]                     @ 080161AA  r0 = set_va_bd
    bl fn_08011400                          @ 080161AC  save the VA "bd" option [r0=set_va_bd, r1=&set_va_bd]
    b .L080161D0                            @ 080161B0
.L080161B2:  @ reached from 08016198 bne (r4 != 100 (0x64))
    ldr.w r0, =set_va_bd_edit               @ 080161B2
    ldrb r0, [r0, #0x0]                     @ 080161B6  r0 = set_va_bd_edit
    teq r0, #0x1                            @ 080161B8  test set_va_bd_edit ^ 1
    beq .L080161C8                          @ 080161BC  if set_va_bd_edit == 1
    movs r0, #0x1                           @ 080161BE
    ldr.w r1, =set_va_bd_edit               @ 080161C0
    strb r0, [r1, #0x0]                     @ 080161C4  set_va_bd_edit = 1
    b .L080161D0                            @ 080161C6
.L080161C8:  @ reached from 080161BC beq (set_va_bd_edit == 1)
    movs r0, #0x0                           @ 080161C8
    ldr.w r1, =set_va_bd_edit               @ 080161CA
    strb r0, [r1, #0x0]                     @ 080161CE  set_va_bd_edit = 0
.L080161D0:  @ reached from 080161B0 b, 080161C6 b
    movs r0, #0x1                           @ 080161D0
    ldr.w r1, =set_redraw                   @ 080161D2
    strb r0, [r1, #0x0]                     @ 080161D6  set_redraw = 1
    pop {r4, pc}                            @ 080161D8
ENDFUNC fn_08016190
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015C20 - item 10 (continuity threshold) edit action in BEEP
@ Replaces : 0x08015C20 FUN_08015C20 (v2.05)
@ In       : r0 = action: 1 up (next in the display order), 2 down (previous), anything else (100) save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads set_cont_code; writes set_redraw
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/autorange_and_scheduler.md 9 (UI order of the 16 codes)
@ Deviation: IMP-05: the 16 codes cycle in the display order DN 1, DN 5, DN 10, DN 30, DN 50, DN100, DN200, DN300, UP
@            1, UP 5, UP 10, UP 30, UP 50, UP100, UP200, UP300 (v2.05: codes 0..3 in code order); the code is edited
@            in place (set_cont_code) and written by fn_080113CC
@ Note     : The table set_cont_pos gives the display position of a code, set_cont_order the code of a display
@            position; the position moves by +1 or -1 modulo 16.
@ -----------------------------------------------------------------------------
FUNC fn_08015C20
    push {r4, lr}                           @ 08015C20
    movs r4, r0                             @ 08015C22
    uxtb r4, r4                             @ 08015C24
    cmp r4, #1                           @ up?
    beq .Lcc_up
    cmp r4, #2                           @ down?
    bne .L08015C76                       @ neither: save (v2.05 0x08015C50)
    movs r2, #15                         @ down: position - 1 = position + 15 (mod 16)
    b .Lcc_step
.Lcc_up:
    movs r2, #1                          @ up: position + 1
.Lcc_step:
    ldr.w r0, =set_cont_code
    ldrb r0, [r0]                        @ current code
    ands r0, r0, #15                     @ keep the table index in range
    ldr.w r1, =set_cont_pos
    ldrb r0, [r1, r0]                    @ its display position
    adds r0, r0, r2                      @ move one step
    ands r0, r0, #15                     @ wrap at 16
    ldr.w r1, =set_cont_order
    ldrb r0, [r1, r0]                    @ the code at the new position
    ldr.w r1, =set_cont_code
    strb r0, [r1]                        @ set_cont_code = new code
    b .L08015C80
.L08015C76:  @ save path (action neither 1 nor 2), v2.05 0x08015C50 bne
    ldr.w r0, =set_cont_code                @ 08015C76
    ldrb r0, [r0, #0x0]                     @ 08015C7A  r0 = set_cont_code
    bl fn_080113CC                          @ 08015C7C  save the continuity threshold code [r0=set_cont_code]
.L08015C80:  @ reached from the replacement code above
    movs r0, #0x1                           @ 08015C80
    ldr.w r1, =set_redraw                   @ 08015C82
    strb r0, [r1, #0x0]                     @ 08015C86  set_redraw = 1
    pop {r4, pc}                            @ 08015C88
ENDFUNC fn_08015C20
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080165F4 - edit action dispatcher: forward REL (up), PEAK (down) and the long-SETUP save to the editor of the item
@ Replaces : 0x080165F4 FUN_080165F4 (v2.05)
@ In       : r0 = action: 0 query, 1 up, 2 down, 100 save
@ Out      : r0 = 1 if the item is editable (query only), else 0
@ Clobbers : r0-r3, r12, flags
@ Context  : main only (KEY, handle_pg8_15_long_press and REL / PEAK in edit mode)
@ RAM      : reads meter_mode, set_item; writes set_edit_timer
@ Spec     : analysis/keys_setup.md 4 (SETUP menu) (edit mechanics, table of items)
@ Note     : Item selection: 10 and 11 depend on the mode (VA modes: 11 = fn_08016190; current modes: 10 =
@            fn_080160E8; BEEP: 10 = fn_08015C20); 0, 2, 3, 4, 9, 5, 6, 7, 8 = fn_08015BE0, fn_08015A22, fn_08015A74,
@            fn_08015B54, fn_08015AC0, fn_08015C94, fn_08015D40, fn_08015E74, fn_08015F7C.  Items 1 (battery), 10 and
@            11 of ACV and the value pages are not editable: the query returns 0 and the key is refused.
@ -----------------------------------------------------------------------------
FUNC fn_080165F4
    push {r3, r4, r5, lr}                   @ 080165F4
    movs r4, r0                             @ 080165F6
    movs r5, #0x0                           @ 080165F8
    movs r0, #0x0                           @ 080165FA
    ldr.w r1, =set_edit_timer               @ 080165FC
    strb r0, [r1, #0x0]                     @ 08016600  set_edit_timer = 0
    ldr.w r0, =meter_mode                   @ 08016602
    ldrb r0, [r0, #0x0]                     @ 08016606  r0 = meter_mode
    cmp r0, #0xd                            @ 08016608  compare meter_mode with 13 (0xD)
    beq .L0801663E                          @ 0801660A  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 0801660C
    ldrb r0, [r0, #0x0]                     @ 08016610  r0 = meter_mode
    cmp r0, #0xe                            @ 08016612  compare meter_mode with 14 (0xE)
    beq .L0801663E                          @ 08016614  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 08016616
    ldrb r0, [r0, #0x0]                     @ 0801661A  r0 = meter_mode
    cmp r0, #0xf                            @ 0801661C  compare meter_mode with 15 (0xF)
    beq .L0801663E                          @ 0801661E  if meter_mode == 15 (0xF)
    ldr.w r0, =meter_mode                   @ 08016620
    ldrb r0, [r0, #0x0]                     @ 08016624  r0 = meter_mode
    cmp r0, #0x16                           @ 08016626  compare meter_mode with 22 (0x16)
    beq .L0801663E                          @ 08016628  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 0801662A
    ldrb r0, [r0, #0x0]                     @ 0801662E  r0 = meter_mode
    cmp r0, #0x17                           @ 08016630  compare meter_mode with 23 (0x17)
    beq .L0801663E                          @ 08016632  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 08016634
    ldrb r0, [r0, #0x0]                     @ 08016638  r0 = meter_mode
    cmp r0, #0x18                           @ 0801663A  compare meter_mode with 24 (0x18)
    bne .L0801665C                          @ 0801663C  if meter_mode != 24 (0x18)
.L0801663E:  @ reached from 0801660A beq (meter_mode == 13 (0xD)), 08016614 beq (meter_mode == 14 (0xE)), 0801661E beq (meter_mode == 15 (0xF)), 08016628 beq (meter_mode == 22 (0x16)), 08016632 beq (meter_mode == 23 (0x17))
    ldr.w r0, =set_item                     @ 0801663E
    ldrb r0, [r0, #0x0]                     @ 08016642  r0 = set_item
    cmp r0, #0xb                            @ 08016644  compare set_item with 11 (0xB)
    bne .L0801665C                          @ 08016646  if set_item != 11 (0xB)
    uxtb r4, r4                             @ 08016648
    cmp r4, #0x0                            @ 0801664A  compare r4 with 0
    bne .L08016654                          @ 0801664C  if r4 != 0
    movs r0, #0x1                           @ 0801664E
    movs r5, r0                             @ 08016650
    b .L0801665C                            @ 08016652
.L08016654:  @ reached from 0801664C bne (r4 != 0)
    movs r0, r4                             @ 08016654
    uxtb r0, r0                             @ 08016656
    bl fn_08016190                          @ 08016658  VA "bd" edit action
.L0801665C:  @ reached from 0801663C bne (meter_mode != 24 (0x18)), 08016646 bne (set_item != 11 (0xB)), 08016652 b
    ldr.w r0, =meter_mode                   @ 0801665C
    ldrb r0, [r0, #0x0]                     @ 08016660  r0 = meter_mode
    cmp r0, #0x10                           @ 08016662  compare meter_mode with 16 (0x10)
    beq .L08016698                          @ 08016664  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 08016666
    ldrb r0, [r0, #0x0]                     @ 0801666A  r0 = meter_mode
    cmp r0, #0x12                           @ 0801666C  compare meter_mode with 18 (0x12)
    beq .L08016698                          @ 0801666E  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 08016670
    ldrb r0, [r0, #0x0]                     @ 08016674  r0 = meter_mode
    cmp r0, #0x14                           @ 08016676  compare meter_mode with 20 (0x14)
    beq .L08016698                          @ 08016678  if meter_mode == 20 (0x14)
    ldr.w r0, =meter_mode                   @ 0801667A
    ldrb r0, [r0, #0x0]                     @ 0801667E  r0 = meter_mode
    cmp r0, #0x11                           @ 08016680  compare meter_mode with 17 (0x11)
    beq .L08016698                          @ 08016682  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 08016684
    ldrb r0, [r0, #0x0]                     @ 08016688  r0 = meter_mode
    cmp r0, #0x13                           @ 0801668A  compare meter_mode with 19 (0x13)
    beq .L08016698                          @ 0801668C  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 0801668E
    ldrb r0, [r0, #0x0]                     @ 08016692  r0 = meter_mode
    cmp r0, #0x15                           @ 08016694  compare meter_mode with 21 (0x15)
    bne .L080166B8                          @ 08016696  if meter_mode != 21 (0x15)
.L08016698:  @ reached from 08016664 beq (meter_mode == 16 (0x10)), 0801666E beq (meter_mode == 18 (0x12)), 08016678 beq (meter_mode == 20 (0x14)), 08016682 beq (meter_mode == 17 (0x11)), 0801668C beq (meter_mode == 19 (0x13))
    ldr.w r0, =set_item                     @ 08016698
    ldrb r0, [r0, #0x0]                     @ 0801669C  r0 = set_item
    cmp r0, #0xa                            @ 0801669E  compare set_item with 10 (0xA)
    bne .L080166B8                          @ 080166A0  if set_item != 10 (0xA)
    uxtb r4, r4                             @ 080166A2
    cmp r4, #0x0                            @ 080166A4  compare r4 with 0
    bne .L080166AE                          @ 080166A6  if r4 != 0
    movs r0, #0x1                           @ 080166A8
    movs r5, r0                             @ 080166AA
    b .L08016800                            @ 080166AC
.L080166AE:  @ reached from 080166A6 bne (r4 != 0)
    movs r0, r4                             @ 080166AE
    uxtb r0, r0                             @ 080166B0
    bl fn_080160E8                          @ 080166B2  current option edit action
    b .L08016800                            @ 080166B6
.L080166B8:  @ reached from 08016696 bne (meter_mode != 21 (0x15)), 080166A0 bne (set_item != 10 (0xA))
    ldr.w r0, =meter_mode                   @ 080166B8
    ldrb r0, [r0, #0x0]                     @ 080166BC  r0 = meter_mode
    cmp r0, #0xa                            @ 080166BE  compare meter_mode with 10 (0xA)
    bne .L080166E2                          @ 080166C0  if meter_mode != 10 (0xA)
    ldr.w r0, =set_item                     @ 080166C2
    ldrb r0, [r0, #0x0]                     @ 080166C6  r0 = set_item
    cmp r0, #0xa                            @ 080166C8  compare set_item with 10 (0xA)
    bne .L080166E2                          @ 080166CA  if set_item != 10 (0xA)
    uxtb r4, r4                             @ 080166CC
    cmp r4, #0x0                            @ 080166CE  compare r4 with 0
    bne .L080166D8                          @ 080166D0  if r4 != 0
    movs r0, #0x1                           @ 080166D2
    movs r5, r0                             @ 080166D4
    b .L08016800                            @ 080166D6
.L080166D8:  @ reached from 080166D0 bne (r4 != 0)
    movs r0, r4                             @ 080166D8
    uxtb r0, r0                             @ 080166DA
    bl fn_08015C20                          @ 080166DC  continuity threshold edit action
    b .L08016800                            @ 080166E0
.L080166E2:  @ reached from 080166C0 bne (meter_mode != 10 (0xA)), 080166CA bne (set_item != 10 (0xA))
    ldr.w r0, =set_item                     @ 080166E2
    ldrb r0, [r0, #0x0]                     @ 080166E6  r0 = set_item
    cmp r0, #0x0                            @ 080166E8  compare set_item with 0
    bne .L08016702                          @ 080166EA  if set_item != 0
    uxtb r4, r4                             @ 080166EC
    cmp r4, #0x0                            @ 080166EE  compare r4 with 0
    bne .L080166F8                          @ 080166F0  if r4 != 0
    movs r0, #0x1                           @ 080166F2
    movs r5, r0                             @ 080166F4
    b .L08016800                            @ 080166F6
.L080166F8:  @ reached from 080166F0 bne (r4 != 0)
    movs r0, r4                             @ 080166F8
    uxtb r0, r0                             @ 080166FA
    bl fn_08015BE0                          @ 080166FC  temperature unit edit action
    b .L08016800                            @ 08016700
.L08016702:  @ reached from 080166EA bne (set_item != 0)
    ldr.w r0, =set_item                     @ 08016702
    ldrb r0, [r0, #0x0]                     @ 08016706  r0 = set_item
    cmp r0, #0x2                            @ 08016708  compare set_item with 2
    bne .L08016722                          @ 0801670A  if set_item != 2
    uxtb r4, r4                             @ 0801670C
    cmp r4, #0x0                            @ 0801670E  compare r4 with 0
    bne .L08016718                          @ 08016710  if r4 != 0
    movs r0, #0x1                           @ 08016712
    movs r5, r0                             @ 08016714
    b .L08016800                            @ 08016716
.L08016718:  @ reached from 08016710 bne (r4 != 0)
    movs r0, r4                             @ 08016718
    uxtb r0, r0                             @ 0801671A
    bl fn_08015A22                          @ 0801671C  APO edit action
    b .L08016800                            @ 08016720
.L08016722:  @ reached from 0801670A bne (set_item != 2)
    ldr.w r0, =set_item                     @ 08016722
    ldrb r0, [r0, #0x0]                     @ 08016726  r0 = set_item
    cmp r0, #0x3                            @ 08016728  compare set_item with 3
    bne .L08016742                          @ 0801672A  if set_item != 3
    uxtb r4, r4                             @ 0801672C
    cmp r4, #0x0                            @ 0801672E  compare r4 with 0
    bne .L08016738                          @ 08016730  if r4 != 0
    movs r0, #0x1                           @ 08016732
    movs r5, r0                             @ 08016734
    b .L08016800                            @ 08016736
.L08016738:  @ reached from 08016730 bne (r4 != 0)
    movs r0, r4                             @ 08016738
    uxtb r0, r0                             @ 0801673A
    bl fn_08015A74                          @ 0801673C  buzzer edit action
    b .L08016800                            @ 08016740
.L08016742:  @ reached from 0801672A bne (set_item != 3)
    ldr.w r0, =set_item                     @ 08016742
    ldrb r0, [r0, #0x0]                     @ 08016746  r0 = set_item
    cmp r0, #0x4                            @ 08016748  compare set_item with 4
    bne .L08016762                          @ 0801674A  if set_item != 4
    uxtb r4, r4                             @ 0801674C
    cmp r4, #0x0                            @ 0801674E  compare r4 with 0
    bne .L08016758                          @ 08016750  if r4 != 0
    movs r0, #0x1                           @ 08016752
    movs r5, r0                             @ 08016754
    b .L08016800                            @ 08016756
.L08016758:  @ reached from 08016750 bne (r4 != 0)
    movs r0, r4                             @ 08016758
    uxtb r0, r0                             @ 0801675A
    bl fn_08015B54                          @ 0801675C  contrast edit action
    b .L08016800                            @ 08016760
.L08016762:  @ reached from 0801674A bne (set_item != 4)
    ldr.w r0, =set_item                     @ 08016762
    ldrb r0, [r0, #0x0]                     @ 08016766  r0 = set_item
    cmp r0, #0x9                            @ 08016768  compare set_item with 9
    bne .L08016782                          @ 0801676A  if set_item != 9
    uxtb r4, r4                             @ 0801676C
    cmp r4, #0x0                            @ 0801676E  compare r4 with 0
    bne .L08016778                          @ 08016770  if r4 != 0
    movs r0, #0x1                           @ 08016772
    movs r5, r0                             @ 08016774
    b .L08016800                            @ 08016776
.L08016778:  @ reached from 08016770 bne (r4 != 0)
    movs r0, r4                             @ 08016778
    uxtb r0, r0                             @ 0801677A
    bl fn_08015AC0                          @ 0801677C  interval edit action
    b .L08016800                            @ 08016780
.L08016782:  @ reached from 0801676A bne (set_item != 9)
    ldr.w r0, =set_item                     @ 08016782
    ldrb r0, [r0, #0x0]                     @ 08016786  r0 = set_item
    cmp r0, #0x5                            @ 08016788  compare set_item with 5
    bne .L080167A2                          @ 0801678A  if set_item != 5
    uxtb r4, r4                             @ 0801678C
    cmp r4, #0x0                            @ 0801678E  compare r4 with 0
    bne .L08016798                          @ 08016790  if r4 != 0
    movs r0, #0x1                           @ 08016792
    movs r5, r0                             @ 08016794
    b .L08016800                            @ 08016796
.L08016798:  @ reached from 08016790 bne (r4 != 0)
    movs r0, r4                             @ 08016798
    uxtb r0, r0                             @ 0801679A
    bl fn_08015C94                          @ 0801679C  year edit action
    b .L08016800                            @ 080167A0
.L080167A2:  @ reached from 0801678A bne (set_item != 5)
    ldr.w r0, =set_item                     @ 080167A2
    ldrb r0, [r0, #0x0]                     @ 080167A6  r0 = set_item
    cmp r0, #0x6                            @ 080167A8  compare set_item with 6
    bne .L080167C2                          @ 080167AA  if set_item != 6
    uxtb r4, r4                             @ 080167AC
    cmp r4, #0x0                            @ 080167AE  compare r4 with 0
    bne .L080167B8                          @ 080167B0  if r4 != 0
    movs r0, #0x1                           @ 080167B2
    movs r5, r0                             @ 080167B4
    b .L08016800                            @ 080167B6
.L080167B8:  @ reached from 080167B0 bne (r4 != 0)
    movs r0, r4                             @ 080167B8
    uxtb r0, r0                             @ 080167BA
    bl fn_08015D40                          @ 080167BC  month/day edit action
    b .L08016800                            @ 080167C0
.L080167C2:  @ reached from 080167AA bne (set_item != 6)
    ldr.w r0, =set_item                     @ 080167C2
    ldrb r0, [r0, #0x0]                     @ 080167C6  r0 = set_item
    cmp r0, #0x7                            @ 080167C8  compare set_item with 7
    bne .L080167E2                          @ 080167CA  if set_item != 7
    uxtb r4, r4                             @ 080167CC
    cmp r4, #0x0                            @ 080167CE  compare r4 with 0
    bne .L080167D8                          @ 080167D0  if r4 != 0
    movs r0, #0x1                           @ 080167D2
    movs r5, r0                             @ 080167D4
    b .L08016800                            @ 080167D6
.L080167D8:  @ reached from 080167D0 bne (r4 != 0)
    movs r0, r4                             @ 080167D8
    uxtb r0, r0                             @ 080167DA
    bl fn_08015E74                          @ 080167DC  hour/minute edit action
    b .L08016800                            @ 080167E0
.L080167E2:  @ reached from 080167CA bne (set_item != 7)
    ldr.w r0, =set_item                     @ 080167E2
    ldrb r0, [r0, #0x0]                     @ 080167E6  r0 = set_item
    cmp r0, #0x8                            @ 080167E8  compare set_item with 8
    bne .Lse_port                           @ 080167EA  if set_item != 8: IMP-07 checks the page bL before leaving
    uxtb r4, r4                             @ 080167EC
    cmp r4, #0x0                            @ 080167EE  compare r4 with 0
    bne .L080167F8                          @ 080167F0  if r4 != 0
    movs r0, #0x1                           @ 080167F2
    movs r5, r0                             @ 080167F4
    b .L08016800                            @ 080167F6
.L080167F8:  @ reached from 080167F0 bne (r4 != 0)
    movs r0, r4                             @ 080167F8
    uxtb r0, r0                             @ 080167FA
    bl fn_08015F7C                          @ 080167FC  ID edit action
    b .L08016800
.Lse_port:  @ IMP-07, IMP-08: reached from 080167EA bne with r0 = set_item
    cmp r0, #0x1                            @ IMP-27: the battery page (item 1) edits the battery trim
    bne .Lse_not_btrim
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_btrim_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable (v2.05: not editable)
    b .L08016800
.Lse_btrim_act:
    movs r0, r4
    uxtb r0, r0
    bl set_btrim_edit                       @ up, down or save of the battery trim
    b .L08016800
.Lse_not_btrim:
    cmp r0, #0xb                            @ IMP-08: item 11 ...
    bne .Lse_bl
    ldr r1, =meter_mode
    ldrb r1, [r1]
    cmp r1, #0x2                            @ ... in ACV (mode 2): the dBm page, editable reference
    bne .L08016800                          @ item 11 of another mode (VA: handled above): nothing more
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_dbm_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_dbm_act:
    movs r0, r4
    uxtb r0, r0
    bl set_dbm_edit                         @ up, down or save of the dBm reference
    b .L08016800
.Lse_bl:
    cmp r0, #SET_ITEM_TC                    @ IMP-10: the thermocouple type page tc (item 23)
    bne .Lse_not_tc
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_tc_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_tc_act:
    movs r0, r4
    uxtb r0, r0
    bl set_tc_edit                          @ up, down or save of the thermocouple type
    b .L08016800
.Lse_not_tc:
    cmp r0, #SET_ITEM_RELP                  @ IMP-11: the REL view page rEL (item 22)
    bne .Lse_not_relp
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_relp_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_relp_act:
    movs r0, r4
    uxtb r0, r0
    bl set_relp_edit                        @ switch or save of the REL view
    b .L08016800
.Lse_not_relp:
    cmp r0, #SET_ITEM_DSP                   @ IMP-12: the display level page dSP (item 24)
    bne .Lse_not_dsp
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_dsp_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_dsp_act:
    movs r0, r4
    uxtb r0, r0
    bl set_dsp_edit                         @ switch or save of the display level
    b .L08016800
.Lse_not_dsp:
    cmp r0, #SET_ITEM_FMT                   @ IMP-32: the card format page For (item 40)
    bne .Lse_not_fmt
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_fmt_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_fmt_act:
    movs r0, r4
    uxtb r0, r0
    bl set_fmt_edit                         @ switch, or confirm (formats with "yes")
    b .L08016800
.Lse_not_fmt:
    cmp r0, #SET_ITEM_BH                    @ IMP-16: the continuity hold page bH (item 26)
    bne .Lse_not_bh
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_bh_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_bh_act:
    movs r0, r4
    uxtb r0, r0
    bl set_bh_edit                          @ up, down or save of the hold time
    b .L08016800
.Lse_not_bh:
    cmp r0, #SET_ITEM_LP                    @ IMP-24: the current-loop page LP (item 37)
    bne .Lse_not_lp
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_lp_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_lp_act:
    movs r0, r4
    uxtb r0, r0
    bl set_lp_edit                          @ up, down or save of the loop view
    b .L08016800
.Lse_not_lp:
    cmp r0, #SET_ITEM_RTD                   @ IMP-25: the RTD page Pt (item 38)
    bne .Lse_not_rtd
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_rtd_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_rtd_act:
    movs r0, r4
    uxtb r0, r0
    bl set_rtd_edit                         @ up, down or save of the RTD view
    b .L08016800
.Lse_not_rtd:
    cmp r0, #SET_ITEM_HUNT                  @ IMP-45: the anti-hunting page HUnt (item 41)
    bne .Lse_not_hunt
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_hunt_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_hunt_act:
    movs r0, r4
    uxtb r0, r0
    bl set_hunt_edit                        @ up, down or save of the anti-hunting setting
    b .L08016800
.Lse_not_hunt:
    sub r1, r0, #SET_ITEM_LT                @ IMP-20: the limit pages Lt, Lo, HI (27..29)
    cmp r1, #2
    bhi .Lse_not_lt
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_lt_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_lt_act:
    mov r1, r0                              @ item
    movs r0, r4
    uxtb r0, r0
    bl set_lt_edit                          @ switch, capture or end of the edit
    b .L08016800
.Lse_not_lt:
    cmp r0, #SET_ITEM_TR                    @ IMP-21: the logging pages tr (30) and Ch (31)
    beq .Lse_lg
    cmp r0, #SET_ITEM_CH
    bne .Lse_not_lg
.Lse_lg:
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_lg_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_lg_act:
    cmp r0, #SET_ITEM_TR
    mov r0, r4                              @ (mov and uxtb keep the flags of the compare)
    uxtb r0, r0
    bne 1f
    bl set_tr_edit
    b .L08016800
1:  bl set_ch_edit
    b .L08016800
.Lse_not_lg:
    cmp r0, #SET_ITEM_CLK                   @ IMP-13: the clock page CL (item 25)
    bne .Lse_not_clk
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_clk_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_clk_act:
    movs r0, r4
    uxtb r0, r0
    bl set_clk_edit                         @ switch or save of the clock
    b .L08016800
.Lse_not_clk:
    cmp r0, #SET_ITEM_BT                    @ IMP-09: the Bluetooth frame rate page bt (item 21)
    bne .Lse_bl_item
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_bt_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_bt_act:
    movs r0, r4
    uxtb r0, r0
    bl set_bt_edit                          @ up, down or save of the frame rate
    b .L08016800
.Lse_bl_item:
    cmp r0, #SET_ITEM_BL                    @ the backlight page bL (item 20)
    bne .L08016800                          @ any other item: not editable, query result 0
    uxtb r4, r4
    cmp r4, #0x0                            @ query?
    bne .Lse_bl_act
    movs r0, #0x1
    movs r5, r0                             @ query result: editable
    b .L08016800
.Lse_bl_act:
    movs r0, r4
    uxtb r0, r0
    bl set_bl_edit                          @ up, down or save of the backlight setting
.L08016800:  @ reached from 080166AC b, 080166B6 b, 080166D6 b, 080166E0 b, 080166F6 b, 08016700 b, 08016716 b, 08016720 b, 08016736 b, 08016740 b, 08016756 b, 08016760 b, 08016776 b, 08016780 b, 08016796 b, 080167A0 b, 080167B6 b, 080167C0 b, 080167D6 b, 080167E0 b, 080167EA bne (set_item != 8), 080167F6 b
    movs r0, r5                             @ 08016800
    uxtb r0, r0                             @ 08016802
    pop {r1, r4, r5, pc}                    @ 08016804
ENDFUNC fn_080165F4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801797C - setup page dispatcher: draw the secondary display for the current setup item
@ Replaces : 0x0801797C FUN_0801797C (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ Context  : main only (UI, fn_08016D34, when set_redraw is set)
@ RAM      : reads acdc_active, lcd_contrast, meter_mode, set_apo_disable, set_bat_value, set_buzzer_on, set_cal_mode,
@            set_cont_code, set_cur_opt, set_cur_opt_edit, set_day, set_day_edit, set_edit, set_edit_blink, set_hour,
@            set_hour_edit, set_interval_edit, set_log_interval, set_minute, set_minute_edit, set_month,
@            set_month_edit, set_msg_code, set_msg_flag, set_temp_value, set_va_bd, set_va_bd_edit, set_va_cur,
@            set_va_ovl1, set_va_ovl2, set_va_sub, set_va_sub2, set_va_volt, set_view_value, set_year, set_year_edit,
@            v_20007E6C, v_20007F9C, v_20007FE1, v_200080C0, v_200080C1; writes lcd_shadow, set_cal_item_cnt,
@            set_item, set_redraw
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ Note     : Clears set_redraw, then chooses the page: the message flag set_msg_flag (fn_080198FC) or message code
@            set_msg_code (codes 0x14 and, OF-47, 0x64: fn_080198B0, others: fn_08019948) replace the setup page; item 100 (logging /
@            MEM view) shows the u16 0x20007F9C while 0x20007FE1 is clear, else the u32 set_view_value (divided by 10
@            with the k annunciator from 100000); while an edit is active and the blink phase is off the blank state
@            is drawn (fn_0801813A); in calibration mode the " CAL " screen (fn_08019880), or, while set_cal_item_cnt
@            is non-zero, the count is decremented and item 0 is shown; otherwise per item: 0 temperature
@            (fn_08018A00), 1 battery (fn_0801839A), 2 APO (fn_08018460), 3 buzzer (fn_08018490), 4 contrast
@            (fn_08018410), 5, 6, 7 year, month-day, hour-minute, 8 ID (fn_080189B0), 9 interval (fn_080184D4), 10,
@            11, 12 by mode (value pages, option texts, fn_0801871C for the BEEP thresholds).  The function body has
@            two address ranges in v2.05 (0x0801797C..0x08017B1B and 0x08017B20..0x08017F27); the second holds the
@            common exit at 0x08017F26.
@ -----------------------------------------------------------------------------
FUNC fn_0801797C
    push {r3, r4, r5, lr}                   @ 0801797C
    movs r5, #0x2                           @ 0801797E
    movs r0, #0x0                           @ 08017980
    ldr.w r1, =set_redraw                   @ 08017982
    strb r0, [r1, #0x0]                     @ 08017984  set_redraw = 0
    ldr.w r0, =set_msg_flag                 @ 08017986
    ldrb r0, [r0, #0x0]                     @ 0801798A  r0 = set_msg_flag
    cmp r0, #0x0                            @ 0801798C  compare set_msg_flag with 0
    beq .L08017996                          @ 0801798E  if set_msg_flag == 0
    bl fn_080198FC                          @ 08017990  message screen for the message flag [r0=set_msg_flag, r1=&set_redraw]
    b .L08017F26                            @ 08017994
.L08017996:  @ reached from 0801798E beq (set_msg_flag == 0)
    ldr.w r0, =set_msg_code                 @ 08017996
    ldrb r0, [r0, #0x0]                     @ 0801799A  r0 = set_msg_code
    cmp r0, #0x0                            @ 0801799C  compare set_msg_code with 0
    beq .L080179BC                          @ 0801799E  if set_msg_code == 0
    ldr.w r0, =set_msg_code                 @ 080179A0
    ldrb r0, [r0, #0x0]                     @ 080179A4  r0 = set_msg_code
    cmp r0, #0x14                           @ 080179A6  compare set_msg_code with 20 (0x14)
    beq .Lof47_lobat                        @ OF-47  code 0x14: logging refused, battery low
    cmp r0, #0x64                           @ OF-47  code 100 (0x64): logging stopped by a low battery (log/files.s 0x0801D316);
    bne .L080179B0                          @ OF-47  v2.05 drew "SdE" and two blank digits for it
.Lof47_lobat:
    bl fn_080198B0                          @ 080179AA  message screen for message code 0x14 and (OF-47) 0x64 [r0=set_msg_code]
    b .L080179BA                            @ 080179AE
.L080179B0:  @ reached from 080179A8 bne (set_msg_code != 20 (0x14))
    ldr.w r0, =set_msg_code                 @ 080179B0
    ldrb r0, [r0, #0x0]                     @ 080179B4  r0 = set_msg_code
    bl fn_08019948                          @ 080179B6  message screen for a message code [r0=set_msg_code]
.L080179BA:  @ reached from 080179AE b
    b .L08017F26                            @ 080179BA
.L080179BC:  @ reached from 0801799E beq (set_msg_code == 0)
    ldr.w r0, =set_item                     @ 080179BC
    ldrb r0, [r0, #0x0]                     @ 080179C0  r0 = set_item
    cmp r0, #0x64                           @ 080179C2  compare set_item with 100 (0x64)
    bne .L08017A3C                          @ 080179C4  if set_item != 100 (0x64)
    ldr.w r0, =v_20007FE1                   @ 080179C6
    ldrb r0, [r0, #0x0]                     @ 080179CA  r0 = v_20007FE1
    cmp r0, #0x0                            @ 080179CC  compare v_20007FE1 with 0
    beq .L08017A2C                          @ 080179CE  if v_20007FE1 == 0
    ldr.w r0, =set_view_value               @ 080179D0
    ldr r0, [r0, #0x0]                      @ 080179D4  r0 = set_view_value
    ldr.w r1, =0x000186A0                   @ 080179D6
    cmp r0, r1                              @ 080179DA  compare set_view_value with 0x000186A0
    bcs .L080179FC                          @ 080179DC  if set_view_value >=u 0x000186A0
    movs r0, #0x0                           @ 080179DE
    movs r5, r0                             @ 080179E0
    ldr.w r0, =set_view_value               @ 080179E2
    ldr r0, [r0, #0x0]                      @ 080179E6  r0 = set_view_value
    movs r4, r0                             @ 080179E8
    ldr.w r0, =lcd_shadow                   @ 080179EA
    ldr r0, [r0, #0x10]                     @ 080179EE  r0 = lcd_shadow+16
    bics r0, r0, #0x20000                   @ 080179F0  r0 = lcd_shadow+16 &~ 0x20000
    ldr.w r1, =lcd_shadow                   @ 080179F4
    str r0, [r1, #0x10]                     @ 080179F8  lcd_shadow+16 = (lcd_shadow+16 &~ 0x20000)
    b .L08017A1E                            @ 080179FA
.L080179FC:  @ reached from 080179DC bcs (set_view_value >=u 0x000186A0)
    movs r0, #0x2                           @ 080179FC
    movs r5, r0                             @ 080179FE
    ldr.w r0, =set_view_value               @ 08017A00
    ldr r0, [r0, #0x0]                      @ 08017A04  r0 = set_view_value
    movs r1, #0xa                           @ 08017A06
    udiv r0, r0, r1                         @ 08017A08  r0 = set_view_value / 10 (0xA)
    movs r4, r0                             @ 08017A0C
    ldr.w r0, =lcd_shadow                   @ 08017A0E
    ldr r0, [r0, #0x10]                     @ 08017A12  r0 = lcd_shadow+16
    orrs r0, r0, #0x20000                   @ 08017A14  r0 = lcd_shadow+16 | 0x20000
    ldr.w r1, =lcd_shadow                   @ 08017A18
    str r0, [r1, #0x10]                     @ 08017A1C  lcd_shadow+16 = (lcd_shadow+16 | 0x20000)
.L08017A1E:  @ reached from 080179FA b
    movs r2, #0x0                           @ 08017A1E
    movs r1, r5                             @ 08017A20
    uxtb r1, r1                             @ 08017A22
    movs r0, r4                             @ 08017A24
    bl lcd_show_value_pos0_4                @ 08017A26  draw a number on the secondary display [r2=0]
    b .L08017A3A                            @ 08017A2A
.L08017A2C:  @ reached from 080179CE beq (v_20007FE1 == 0)
    movs r2, #0x0                           @ 08017A2C
    movs r1, #0x0                           @ 08017A2E
    ldr.w r0, =v_20007F9C                   @ 08017A30
    ldrh r0, [r0, #0x0]                     @ 08017A34  r0 = v_20007F9C
    bl lcd_show_value_pos0_4                @ 08017A36  draw a number on the secondary display [r0=v_20007F9C, r1=0, r2=0]
.L08017A3A:  @ reached from 08017A2A b
    b .L08017F26                            @ 08017A3A
.L08017A3C:  @ reached from 080179C4 bne (set_item != 100 (0x64))
    ldr.w r0, =set_edit                     @ 08017A3C
    ldrb r0, [r0, #0x0]                     @ 08017A40  r0 = set_edit
    ldr.w r1, =set_edit_blink               @ 08017A42
    ldrb r1, [r1, #0x0]                     @ 08017A46  r1 = set_edit_blink
    eors r1, r1, #0x1                       @ 08017A48  r1 = set_edit_blink ^ 1
    tst r0, r1                              @ 08017A4C  test set_edit & (set_edit_blink ^ 1)
    beq .L08017A56                          @ 08017A4E  if (set_edit & (set_edit_blink ^ 1)) == 0
    bl fn_0801813A                          @ 08017A50  draw the edit-blink blank state [r0=set_edit, r1=(set_edit_blink ^ 1)]
    b .L08017F26                            @ 08017A54
.L08017A56:  @ reached from 08017A4E beq ((set_edit & (set_edit_blink ^ 1)) == 0)
    ldr.w r0, =set_cal_mode                 @ 08017A56
    ldrb r0, [r0, #0x0]                     @ 08017A5A  r0 = set_cal_mode
    cmp r0, #0x0                            @ 08017A5C  compare set_cal_mode with 0
    beq .L08017A70                          @ 08017A5E  if set_cal_mode == 0
    ldr.w r0, =set_cal_item_cnt             @ 08017A60
    ldrb r0, [r0, #0x0]                     @ 08017A64  r0 = set_cal_item_cnt
    cmp r0, #0x0                            @ 08017A66  compare set_cal_item_cnt with 0
    bne .L08017A70                          @ 08017A68  if set_cal_item_cnt != 0
    bl fn_08019880                          @ 08017A6A  show " CAL " on the secondary display [r0=set_cal_item_cnt]
    b .L08017F26                            @ 08017A6E
.L08017A70:  @ reached from 08017A5E beq (set_cal_mode == 0), 08017A68 bne (set_cal_item_cnt != 0)
    ldr.w r0, =set_cal_mode                 @ 08017A70
    ldrb r0, [r0, #0x0]                     @ 08017A74  r0 = set_cal_mode
    cmp r0, #0x0                            @ 08017A76  compare set_cal_mode with 0
    beq .L08017A9A                          @ 08017A78  if set_cal_mode == 0
    ldr.w r0, =set_cal_item_cnt             @ 08017A7A
    ldrb r0, [r0, #0x0]                     @ 08017A7E  r0 = set_cal_item_cnt
    cmp r0, #0x0                            @ 08017A80  compare set_cal_item_cnt with 0
    beq .L08017A9A                          @ 08017A82  if set_cal_item_cnt == 0
    ldr.w r0, =set_cal_item_cnt             @ 08017A84
    ldrb r0, [r0, #0x0]                     @ 08017A88  r0 = set_cal_item_cnt
    subs r0, r0, #0x1                       @ 08017A8A  r0 = set_cal_item_cnt - 1
    ldr.w r1, =set_cal_item_cnt             @ 08017A8C
    strb r0, [r1, #0x0]                     @ 08017A90  set_cal_item_cnt = (set_cal_item_cnt - 1)
    movs r0, #0x0                           @ 08017A92
    ldr.w r1, =set_item                     @ 08017A94
    strb r0, [r1, #0x0]                     @ 08017A98  set_item = 0
.L08017A9A:  @ reached from 08017A78 beq (set_cal_mode == 0), 08017A82 beq (set_cal_item_cnt == 0)
    ldr.w r0, =set_item                     @ 08017A9A
    ldrb r0, [r0, #0x0]                     @ 08017A9E  r0 = set_item
    cmp r0, #0xc                            @ 08017AA0  compare set_item with 12 (0xC)
    bne .L08017B52                          @ 08017AA2  if set_item != 12 (0xC)
    ldr.w r0, =meter_mode                   @ 08017AA4
    ldrb r0, [r0, #0x0]                     @ 08017AA8  r0 = meter_mode
    cmp r0, #0xd                            @ 08017AAA  compare meter_mode with 13 (0xD)
    beq .L08017AE0                          @ 08017AAC  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 08017AAE
    ldrb r0, [r0, #0x0]                     @ 08017AB2  r0 = meter_mode
    cmp r0, #0xe                            @ 08017AB4  compare meter_mode with 14 (0xE)
    beq .L08017AE0                          @ 08017AB6  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 08017AB8
    ldrb r0, [r0, #0x0]                     @ 08017ABC  r0 = meter_mode
    cmp r0, #0xf                            @ 08017ABE  compare meter_mode with 15 (0xF)
    beq .L08017AE0                          @ 08017AC0  if meter_mode == 15 (0xF)
    ldr.w r0, =meter_mode                   @ 08017AC2
    ldrb r0, [r0, #0x0]                     @ 08017AC6  r0 = meter_mode
    cmp r0, #0x16                           @ 08017AC8  compare meter_mode with 22 (0x16)
    beq .L08017AE0                          @ 08017ACA  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 08017ACC
    ldrb r0, [r0, #0x0]                     @ 08017AD0  r0 = meter_mode
    cmp r0, #0x17                           @ 08017AD2  compare meter_mode with 23 (0x17)
    beq .L08017AE0                          @ 08017AD4  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 08017AD6
    ldrb r0, [r0, #0x0]                     @ 08017ADA  r0 = meter_mode
    cmp r0, #0x18                           @ 08017ADC  compare meter_mode with 24 (0x18)
    bne .L08017B20                          @ 08017ADE  if meter_mode != 24 (0x18)
.L08017AE0:  @ reached from 08017AAC beq (meter_mode == 13 (0xD)), 08017AB6 beq (meter_mode == 14 (0xE)), 08017AC0 beq (meter_mode == 15 (0xF)), 08017ACA beq (meter_mode == 22 (0x16)), 08017AD4 beq (meter_mode == 23 (0x17))
    ldr.w r0, =set_va_bd                    @ 08017AE0
    ldrb r0, [r0, #0x0]                     @ 08017AE4  r0 = set_va_bd
    cmp r0, #0x0                            @ 08017AE6  compare set_va_bd with 0
    beq .L08017B20                          @ 08017AE8  if set_va_bd == 0
    ldr.w r0, =set_va_sub2                  @ 08017AEA
    ldrb r0, [r0, #0x0]                     @ 08017AEE  r0 = set_va_sub2
    cmp r0, #0x0                            @ 08017AF0  compare set_va_sub2 with 0
    beq .L08017B02                          @ 08017AF2  if set_va_sub2 == 0
    ldr.w r0, =set_va_cur                   @ 08017AF4
    ldr r0, [r0, #0x0]                      @ 08017AF8  r0 = set_va_cur
    movs r1, #0xa                           @ 08017AFA
    muls r0, r1                             @ 08017AFC  r0 = set_va_cur * 10 (0xA)
    movs r4, r0                             @ 08017AFE
    b .L08017B0E                            @ 08017B00
.L08017B02:  @ reached from 08017AF2 beq (set_va_sub2 == 0)
    ldr.w r0, =set_va_cur                   @ 08017B02
    ldr r0, [r0, #0x0]                      @ 08017B06  r0 = set_va_cur
    movs r1, #0x64                          @ 08017B08
    muls r0, r1                             @ 08017B0A  r0 = set_va_cur * 100 (0x64)
    movs r4, r0                             @ 08017B0C
.L08017B0E:  @ reached from 08017B00 b
    ldr.w r0, =set_va_sub2                  @ 08017B0E
    ldrb r1, [r0, #0x0]                     @ 08017B12  r1 = set_va_sub2
    movs r0, r4                             @ 08017B14
    bl fn_08018228                          @ 08017B16  draw a scaled signed value (item 11/12) [r1=set_va_sub2]
    b .L08017F26                            @ 08017B1A
.L08017B20:  @ reached from 08017ADE bne (meter_mode != 24 (0x18)), 08017AE8 beq (set_va_bd == 0)
    ldr.w r0, =meter_mode                   @ 08017B20
    ldrb r0, [r0, #0x0]                     @ 08017B24  r0 = meter_mode
    cmp r0, #0x10                           @ 08017B26  compare meter_mode with 16 (0x10)
    beq .L08017B40                          @ 08017B28  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 08017B2A
    ldrb r0, [r0, #0x0]                     @ 08017B2E  r0 = meter_mode
    cmp r0, #0x12                           @ 08017B30  compare meter_mode with 18 (0x12)
    beq .L08017B40                          @ 08017B32  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 08017B34
    ldrb r0, [r0, #0x0]                     @ 08017B38  r0 = meter_mode
    cmp r0, #0x14                           @ 08017B3A  compare meter_mode with 20 (0x14)
    bne .L08017F26                          @ 08017B3C  if meter_mode != 20 (0x14)
.L08017B40:  @ reached from 08017B28 beq (meter_mode == 16 (0x10)), 08017B32 beq (meter_mode == 18 (0x12))
    ldr.w r0, =set_cur_opt                  @ 08017B40
    ldrb r0, [r0, #0x0]                     @ 08017B44  r0 = set_cur_opt
    cmp r0, #0x0                            @ 08017B46  compare set_cur_opt with 0
    beq .L08017F26                          @ 08017B48  if set_cur_opt == 0
    bl fn_08017F94                          @ 08017B4C  draw the setup item 10 value [r0=set_cur_opt]
    b .L08017F26                            @ 08017B50
.L08017B52:  @ reached from 08017AA2 bne (set_item != 12 (0xC))
    ldr.w r0, =set_item                     @ 08017B52
    ldrb r0, [r0, #0x0]                     @ 08017B56  r0 = set_item
    cmp r0, #0xb                            @ 08017B58  compare set_item with 11 (0xB)
    bne .L08017C46                          @ 08017B5A  if set_item != 11 (0xB)
    ldr.w r0, =meter_mode                   @ 08017B5C
    ldrb r0, [r0, #0x0]                     @ 08017B60  r0 = meter_mode
    cmp r0, #0x2                            @ 08017B62  compare meter_mode with 2
    bne .L08017B6C                          @ 08017B64  if meter_mode != 2
    ldr r0, =set_edit
    ldrb r0, [r0]
    cbz r0, 1f                              @ IMP-08: no edit: the dBm value as in v2.05
    bl set_dbm_draw                         @ IMP-08: edit active (blink phase on): the reference text
    b .L08017F26
1:
    bl fn_08018590                          @ 08017B66  draw the ACV scaled value (item 11) [r0=meter_mode]
    b .L08017F26                            @ 08017B6A
.L08017B6C:  @ reached from 08017B64 bne (meter_mode != 2)
    ldr.w r0, =meter_mode                   @ 08017B6C
    ldrb r0, [r0, #0x0]                     @ 08017B70  r0 = meter_mode
    cmp r0, #0xd                            @ 08017B72  compare meter_mode with 13 (0xD)
    beq .L08017BA8                          @ 08017B74  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 08017B76
    ldrb r0, [r0, #0x0]                     @ 08017B7A  r0 = meter_mode
    cmp r0, #0xe                            @ 08017B7C  compare meter_mode with 14 (0xE)
    beq .L08017BA8                          @ 08017B7E  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 08017B80
    ldrb r0, [r0, #0x0]                     @ 08017B84  r0 = meter_mode
    cmp r0, #0xf                            @ 08017B86  compare meter_mode with 15 (0xF)
    beq .L08017BA8                          @ 08017B88  if meter_mode == 15 (0xF)
    ldr.w r0, =meter_mode                   @ 08017B8A
    ldrb r0, [r0, #0x0]                     @ 08017B8E  r0 = meter_mode
    cmp r0, #0x16                           @ 08017B90  compare meter_mode with 22 (0x16)
    beq .L08017BA8                          @ 08017B92  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 08017B94
    ldrb r0, [r0, #0x0]                     @ 08017B98  r0 = meter_mode
    cmp r0, #0x17                           @ 08017B9A  compare meter_mode with 23 (0x17)
    beq .L08017BA8                          @ 08017B9C  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 08017B9E
    ldrb r0, [r0, #0x0]                     @ 08017BA2  r0 = meter_mode
    cmp r0, #0x18                           @ 08017BA4  compare meter_mode with 24 (0x18)
    bne .L08017BB4                          @ 08017BA6  if meter_mode != 24 (0x18)
.L08017BA8:  @ reached from 08017B74 beq (meter_mode == 13 (0xD)), 08017B7E beq (meter_mode == 14 (0xE)), 08017B88 beq (meter_mode == 15 (0xF)), 08017B92 beq (meter_mode == 22 (0x16)), 08017B9C beq (meter_mode == 23 (0x17))
    ldr.w r0, =set_va_bd_edit               @ 08017BA8
    ldrb r0, [r0, #0x0]                     @ 08017BAC  r0 = set_va_bd_edit
    bl fn_080186AC                          @ 08017BAE  draw the "bd" state [r0=set_va_bd_edit]
    b .L08017F26                            @ 08017BB2
.L08017BB4:  @ reached from 08017BA6 bne (meter_mode != 24 (0x18))
    ldr.w r0, =meter_mode                   @ 08017BB4
    ldrb r0, [r0, #0x0]                     @ 08017BB8  r0 = meter_mode
    cmp r0, #0x10                           @ 08017BBA  compare meter_mode with 16 (0x10)
    beq .L08017BF0                          @ 08017BBC  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 08017BBE
    ldrb r0, [r0, #0x0]                     @ 08017BC2  r0 = meter_mode
    cmp r0, #0x12                           @ 08017BC4  compare meter_mode with 18 (0x12)
    beq .L08017BF0                          @ 08017BC6  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 08017BC8
    ldrb r0, [r0, #0x0]                     @ 08017BCC  r0 = meter_mode
    cmp r0, #0x14                           @ 08017BCE  compare meter_mode with 20 (0x14)
    beq .L08017BF0                          @ 08017BD0  if meter_mode == 20 (0x14)
    ldr.w r0, =meter_mode                   @ 08017BD2
    ldrb r0, [r0, #0x0]                     @ 08017BD6  r0 = meter_mode
    cmp r0, #0x11                           @ 08017BD8  compare meter_mode with 17 (0x11)
    beq .L08017BF0                          @ 08017BDA  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 08017BDC
    ldrb r0, [r0, #0x0]                     @ 08017BE0  r0 = meter_mode
    cmp r0, #0x13                           @ 08017BE2  compare meter_mode with 19 (0x13)
    beq .L08017BF0                          @ 08017BE4  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 08017BE6
    ldrb r0, [r0, #0x0]                     @ 08017BEA  r0 = meter_mode
    cmp r0, #0x15                           @ 08017BEC  compare meter_mode with 21 (0x15)
    bne .L08017C08                          @ 08017BEE  if meter_mode != 21 (0x15)
.L08017BF0:  @ reached from 08017BBC beq (meter_mode == 16 (0x10)), 08017BC6 beq (meter_mode == 18 (0x12)), 08017BD0 beq (meter_mode == 20 (0x14)), 08017BDA beq (meter_mode == 17 (0x11)), 08017BE4 beq (meter_mode == 19 (0x13))
    ldr.w r0, =set_cur_opt                  @ 08017BF0
    ldrb r0, [r0, #0x0]                     @ 08017BF4  r0 = set_cur_opt
    cmp r0, #0x0                            @ 08017BF6  compare set_cur_opt with 0
    beq .L08017C08                          @ 08017BF8  if set_cur_opt == 0
    movs r1, #0x64                          @ 08017BFA
    ldr.w r0, =v_20007E6C                   @ 08017BFC
    ldr r0, [r0, #0x0]                      @ 08017C00  r0 = v_20007E6C
    bl fn_08018228                          @ 08017C02  draw a scaled signed value (item 11/12) [r0=v_20007E6C, r1=100 (0x64)]
    b .L08017F26                            @ 08017C06
.L08017C08:  @ reached from 08017BEE bne (meter_mode != 21 (0x15)), 08017BF8 beq (set_cur_opt == 0)
    ldr.w r0, =meter_mode                   @ 08017C08
    ldrb r0, [r0, #0x0]                     @ 08017C0C  r0 = meter_mode
    cmp r0, #0x10                           @ 08017C0E  compare meter_mode with 16 (0x10)
    beq .L08017C28                          @ 08017C10  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 08017C12
    ldrb r0, [r0, #0x0]                     @ 08017C16  r0 = meter_mode
    cmp r0, #0x12                           @ 08017C18  compare meter_mode with 18 (0x12)
    beq .L08017C28                          @ 08017C1A  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 08017C1C
    ldrb r0, [r0, #0x0]                     @ 08017C20  r0 = meter_mode
    cmp r0, #0x14                           @ 08017C22  compare meter_mode with 20 (0x14)
    bne .L08017F26                          @ 08017C24  if meter_mode != 20 (0x14)
.L08017C28:  @ reached from 08017C10 beq (meter_mode == 16 (0x10)), 08017C1A beq (meter_mode == 18 (0x12))
    ldr.w r0, =set_cur_opt                  @ 08017C28
    ldrb r0, [r0, #0x0]                     @ 08017C2C  r0 = set_cur_opt
    cmp r0, #0x0                            @ 08017C2E  compare set_cur_opt with 0
    bne .L08017F26                          @ 08017C30  if set_cur_opt != 0
    ldr.w r0, =set_cur_opt                  @ 08017C34
    ldrb r0, [r0, #0x0]                     @ 08017C38  r0 = set_cur_opt
    cmp r0, #0x0                            @ 08017C3A  compare set_cur_opt with 0
    bne .L08017F26                          @ 08017C3C  if set_cur_opt != 0
    bl fn_08017F94                          @ 08017C40  draw the setup item 10 value [r0=set_cur_opt]
    b .L08017F26                            @ 08017C44
.L08017C46:  @ reached from 08017B5A bne (set_item != 11 (0xB))
    ldr.w r0, =set_item                     @ 08017C46
    ldrb r0, [r0, #0x0]                     @ 08017C4A  r0 = set_item
    cmp r0, #0xa                            @ 08017C4C  compare set_item with 10 (0xA)
    bne .L08017DC4                          @ 08017C4E  if set_item != 10 (0xA)
    ldr.w r0, =meter_mode                   @ 08017C52
    ldrb r0, [r0, #0x0]                     @ 08017C56  r0 = meter_mode
    cmp r0, #0xd                            @ 08017C58  compare meter_mode with 13 (0xD)
    beq .L08017C8E                          @ 08017C5A  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 08017C5C
    ldrb r0, [r0, #0x0]                     @ 08017C60  r0 = meter_mode
    cmp r0, #0xe                            @ 08017C62  compare meter_mode with 14 (0xE)
    beq .L08017C8E                          @ 08017C64  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 08017C66
    ldrb r0, [r0, #0x0]                     @ 08017C6A  r0 = meter_mode
    cmp r0, #0xf                            @ 08017C6C  compare meter_mode with 15 (0xF)
    beq .L08017C8E                          @ 08017C6E  if meter_mode == 15 (0xF)
    ldr.w r0, =meter_mode                   @ 08017C70
    ldrb r0, [r0, #0x0]                     @ 08017C74  r0 = meter_mode
    cmp r0, #0x16                           @ 08017C76  compare meter_mode with 22 (0x16)
    beq .L08017C8E                          @ 08017C78  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 08017C7A
    ldrb r0, [r0, #0x0]                     @ 08017C7E  r0 = meter_mode
    cmp r0, #0x17                           @ 08017C80  compare meter_mode with 23 (0x17)
    beq .L08017C8E                          @ 08017C82  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 08017C84
    ldrb r0, [r0, #0x0]                     @ 08017C88  r0 = meter_mode
    cmp r0, #0x18                           @ 08017C8A  compare meter_mode with 24 (0x18)
    bne .L08017D1C                          @ 08017C8C  if meter_mode != 24 (0x18)
.L08017C8E:  @ reached from 08017C5A beq (meter_mode == 13 (0xD)), 08017C64 beq (meter_mode == 14 (0xE)), 08017C6E beq (meter_mode == 15 (0xF)), 08017C78 beq (meter_mode == 22 (0x16)), 08017C82 beq (meter_mode == 23 (0x17))
    ldr.w r0, =set_va_sub                   @ 08017C8E
    ldrb r0, [r0, #0x0]                     @ 08017C92  r0 = set_va_sub
    cmp r0, #0x0                            @ 08017C94  compare set_va_sub with 0
    bne .L08017CDA                          @ 08017C96  if set_va_sub != 0
    bl fn_0801801E                          @ 08017C98  select the decimal point for the VA item 10 value [r0=set_va_sub]
    ldr.w r0, =v_200080C0                   @ 08017C9C
    ldrb r0, [r0, #0x0]                     @ 08017CA0  r0 = v_200080C0
    cmp r0, #0x0                            @ 08017CA2  compare v_200080C0 with 0
    beq .L08017CAE                          @ 08017CA4  if v_200080C0 == 0
    movs r0, #0x1                           @ 08017CA6
    bl fn_08019A86                          @ 08017CA8  show open text (r0) [r0=1]
    b .L08017F26                            @ 08017CAC
.L08017CAE:  @ reached from 08017CA4 beq (v_200080C0 == 0)
    ldr.w r0, =set_va_ovl1                  @ 08017CAE
    ldrsb r0, [r0, #0x0]                    @ 08017CB2  r0 = set_va_ovl1
    cmp r0, #0x0                            @ 08017CB6  compare set_va_ovl1 with 0
    bne .L08017CC6                          @ 08017CB8  if set_va_ovl1 != 0
    ldr.w r0, =set_va_ovl2                  @ 08017CBA
    ldrsb r0, [r0, #0x0]                    @ 08017CBE  r0 = set_va_ovl2
    cmp r0, #0x0                            @ 08017CC2  compare set_va_ovl2 with 0
    beq .L08017CCE                          @ 08017CC4  if set_va_ovl2 == 0
.L08017CC6:  @ reached from 08017CB8 bne (set_va_ovl1 != 0)
    movs r0, #0x1                           @ 08017CC6
    bl fn_080199B4                          @ 08017CC8  show " OFL " or burden text (r0) [r0=1]
    b .L08017F26                            @ 08017CCC
.L08017CCE:  @ reached from 08017CC4 beq (set_va_ovl2 == 0)
    ldr.w r0, =set_va_volt                  @ 08017CCE
    ldr r0, [r0, #0x0]                      @ 08017CD2  r0 = set_va_volt
    bl fn_080181B6                          @ 08017CD4  draw a signed value on the secondary display [r0=set_va_volt]
    b .L08017F26                            @ 08017CD8
.L08017CDA:  @ reached from 08017C96 bne (set_va_sub != 0)
    bl fn_0801803C                          @ 08017CDA  select the decimal point for the VA item 10 value (second variant)
    ldr.w r0, =v_200080C1                   @ 08017CDE
    ldrb r0, [r0, #0x0]                     @ 08017CE2  r0 = v_200080C1
    cmp r0, #0x0                            @ 08017CE4  compare v_200080C1 with 0
    beq .L08017CF0                          @ 08017CE6  if v_200080C1 == 0
    movs r0, #0x1                           @ 08017CE8
    bl fn_08019A86                          @ 08017CEA  show open text (r0) [r0=1]
    b .L08017F26                            @ 08017CEE
.L08017CF0:  @ reached from 08017CE6 beq (v_200080C1 == 0)
    ldr.w r0, =set_va_ovl2                  @ 08017CF0
    ldrsb r0, [r0, #0x0]                    @ 08017CF4  r0 = set_va_ovl2
    cmp r0, #0x0                            @ 08017CF8  compare set_va_ovl2 with 0
    bne .L08017D08                          @ 08017CFA  if set_va_ovl2 != 0
    ldr.w r0, =set_va_ovl1                  @ 08017CFC
    ldrsb r0, [r0, #0x0]                    @ 08017D00  r0 = set_va_ovl1
    cmp r0, #0x0                            @ 08017D04  compare set_va_ovl1 with 0
    beq .L08017D10                          @ 08017D06  if set_va_ovl1 == 0
.L08017D08:  @ reached from 08017CFA bne (set_va_ovl2 != 0)
    movs r0, #0x1                           @ 08017D08
    bl fn_080199B4                          @ 08017D0A  show " OFL " or burden text (r0) [r0=1]
    b .L08017F26                            @ 08017D0E
.L08017D10:  @ reached from 08017D06 beq (set_va_ovl1 == 0)
    ldr.w r0, =set_va_cur                   @ 08017D10
    ldr r0, [r0, #0x0]                      @ 08017D14  r0 = set_va_cur
    bl fn_080181B6                          @ 08017D16  draw a signed value on the secondary display [r0=set_va_cur]
    b .L08017F26                            @ 08017D1A
.L08017D1C:  @ reached from 08017C8C bne (meter_mode != 24 (0x18))
    ldr.w r0, =meter_mode                   @ 08017D1C
    ldrb r0, [r0, #0x0]                     @ 08017D20  r0 = meter_mode
    cmp r0, #0xb                            @ 08017D22  compare meter_mode with 11 (0xB)
    bne .L08017D2C                          @ 08017D24  if meter_mode != 11 (0xB)
    bl fn_080186E0                          @ 08017D26  draw the DIODE source text [r0=meter_mode]
    b .L08017F26                            @ 08017D2A
.L08017D2C:  @ reached from 08017D24 bne (meter_mode != 11 (0xB))
    ldr.w r0, =meter_mode                   @ 08017D2C
    ldrb r0, [r0, #0x0]                     @ 08017D30  r0 = meter_mode
    cmp r0, #0xa                            @ 08017D32  compare meter_mode with 10 (0xA)
    bne .L08017D42                          @ 08017D34  if meter_mode != 10 (0xA)
    ldr.w r0, =set_cont_code                @ 08017D36
    ldrb r0, [r0, #0x0]                     @ 08017D3A  r0 = set_cont_code
    bl fn_0801871C                          @ 08017D3C  draw the continuity threshold text [r0=set_cont_code]
    b .L08017F26                            @ 08017D40
.L08017D42:  @ reached from 08017D34 bne (meter_mode != 10 (0xA))
    ldr.w r0, =meter_mode                   @ 08017D42
    ldrb r0, [r0, #0x0]                     @ 08017D46  r0 = meter_mode
    cmp r0, #0x10                           @ 08017D48  compare meter_mode with 16 (0x10)
    beq .L08017D7E                          @ 08017D4A  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 08017D4C
    ldrb r0, [r0, #0x0]                     @ 08017D50  r0 = meter_mode
    cmp r0, #0x12                           @ 08017D52  compare meter_mode with 18 (0x12)
    beq .L08017D7E                          @ 08017D54  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 08017D56
    ldrb r0, [r0, #0x0]                     @ 08017D5A  r0 = meter_mode
    cmp r0, #0x14                           @ 08017D5C  compare meter_mode with 20 (0x14)
    beq .L08017D7E                          @ 08017D5E  if meter_mode == 20 (0x14)
    ldr.w r0, =meter_mode                   @ 08017D60
    ldrb r0, [r0, #0x0]                     @ 08017D64  r0 = meter_mode
    cmp r0, #0x11                           @ 08017D66  compare meter_mode with 17 (0x11)
    beq .L08017D7E                          @ 08017D68  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 08017D6A
    ldrb r0, [r0, #0x0]                     @ 08017D6E  r0 = meter_mode
    cmp r0, #0x13                           @ 08017D70  compare meter_mode with 19 (0x13)
    beq .L08017D7E                          @ 08017D72  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 08017D74
    ldrb r0, [r0, #0x0]                     @ 08017D78  r0 = meter_mode
    cmp r0, #0x15                           @ 08017D7A  compare meter_mode with 21 (0x15)
    bne .L08017D8A                          @ 08017D7C  if meter_mode != 21 (0x15)
.L08017D7E:  @ reached from 08017D4A beq (meter_mode == 16 (0x10)), 08017D54 beq (meter_mode == 18 (0x12)), 08017D5E beq (meter_mode == 20 (0x14)), 08017D68 beq (meter_mode == 17 (0x11)), 08017D72 beq (meter_mode == 19 (0x13))
    ldr.w r0, =set_cur_opt_edit             @ 08017D7E
    ldrb r0, [r0, #0x0]                     @ 08017D82  r0 = set_cur_opt_edit
    bl fn_080186AC                          @ 08017D84  draw the "bd" state [r0=set_cur_opt_edit]
    b .L08017F26                            @ 08017D88
.L08017D8A:  @ reached from 08017D7C bne (meter_mode != 21 (0x15))
    ldr.w r0, =meter_mode                   @ 08017D8A
    ldrb r0, [r0, #0x0]                     @ 08017D8E  r0 = meter_mode
    cmp r0, #0x2                            @ 08017D90  compare meter_mode with 2
    bne .L08017D9E                          @ 08017D92  if meter_mode != 2
    ldr.w r0, =acdc_active                  @ 08017D94
    ldrb r0, [r0, #0x0]                     @ 08017D98  r0 = acdc_active
    cmp r0, #0x0                            @ 08017D9A  compare acdc_active with 0
    beq .L08017DA8                          @ 08017D9C  if acdc_active == 0
.L08017D9E:  @ reached from 08017D92 bne (meter_mode != 2)
    ldr.w r0, =meter_mode                   @ 08017D9E
    ldrb r0, [r0, #0x0]                     @ 08017DA2  r0 = meter_mode
    cmp r0, #0x4                            @ 08017DA4  compare meter_mode with 4
    bne .L08017DAE                          @ 08017DA6  if meter_mode != 4
.L08017DA8:  @ reached from 08017D9C beq (acdc_active == 0)
    bl fn_08017F94                          @ 08017DA8  draw the setup item 10 value
    b .L08017F26                            @ 08017DAC
.L08017DAE:  @ reached from 08017DA6 bne (meter_mode != 4)
    movs r0, #0x0                           @ 08017DAE
    ldr.w r1, =set_item                     @ 08017DB0
    strb r0, [r1, #0x0]                     @ 08017DB4  set_item = 0
    ldr.w r0, =set_temp_value               @ 08017DB6
    ldrsh r0, [r0, #0x0]                    @ 08017DBA  r0 = set_temp_value
    bl fn_08018A00                          @ 08017DBE  draw the board temperature page [r0=set_temp_value, r1=&set_item]
    b .L08017F26                            @ 08017DC2
.L08017DC4:  @ reached from 08017C4E bne (set_item != 10 (0xA))
    ldr.w r0, =set_item                     @ 08017DC4
    ldrb r0, [r0, #0x0]                     @ 08017DC8  r0 = set_item
    cmp r0, #0x4                            @ 08017DCA  compare set_item with 4
    bne .L08017DDA                          @ 08017DCC  if set_item != 4
    ldr.w r0, =lcd_contrast                 @ 08017DCE
    ldrb r0, [r0, #0x0]                     @ 08017DD2  r0 = lcd_contrast
    bl fn_08018410                          @ 08017DD4  draw "Lcd-n" [r0=lcd_contrast]
    b .L08017F26                            @ 08017DD8
.L08017DDA:  @ reached from 08017DCC bne (set_item != 4)
    ldr.w r0, =set_item                     @ 08017DDA
    ldrb r0, [r0, #0x0]                     @ 08017DDE  r0 = set_item
    cmp r0, #0x7                            @ 08017DE0  compare set_item with 7
    bne .L08017E16                          @ 08017DE2  if set_item != 7
    ldr.w r0, =set_edit                     @ 08017DE4
    ldrb r0, [r0, #0x0]                     @ 08017DE8  r0 = set_edit
    cmp r0, #0x0                            @ 08017DEA  compare set_edit with 0
    beq .L08017E02                          @ 08017DEC  if set_edit == 0
    ldr.w r0, =set_minute_edit              @ 08017DEE
    ldrb r2, [r0, #0x0]                     @ 08017DF2  r2 = set_minute_edit
    ldr.w r0, =set_hour_edit                @ 08017DF4
    ldrb r1, [r0, #0x0]                     @ 08017DF8  r1 = set_hour_edit
    movs r0, #0x0                           @ 08017DFA
    bl fn_080188A0                          @ 08017DFC  draw the hour-minute page [r0=0, r1=set_hour_edit, r2=set_minute_edit]
    b .L08017F26                            @ 08017E00
.L08017E02:  @ reached from 08017DEC beq (set_edit == 0)
    ldr.w r0, =set_minute                   @ 08017E02
    ldrb r2, [r0, #0x0]                     @ 08017E06  r2 = set_minute
    ldr.w r0, =set_hour                     @ 08017E08
    ldrb r1, [r0, #0x0]                     @ 08017E0C  r1 = set_hour
    movs r0, #0x0                           @ 08017E0E
    bl fn_080188A0                          @ 08017E10  draw the hour-minute page [r0=0, r1=set_hour, r2=set_minute]
    b .L08017F26                            @ 08017E14
.L08017E16:  @ reached from 08017DE2 bne (set_item != 7)
    ldr.w r0, =set_item                     @ 08017E16
    ldrb r0, [r0, #0x0]                     @ 08017E1A  r0 = set_item
    cmp r0, #0x6                            @ 08017E1C  compare set_item with 6
    bne .L08017E52                          @ 08017E1E  if set_item != 6
    ldr.w r0, =set_edit                     @ 08017E20
    ldrb r0, [r0, #0x0]                     @ 08017E24  r0 = set_edit
    cmp r0, #0x0                            @ 08017E26  compare set_edit with 0
    beq .L08017E3E                          @ 08017E28  if set_edit == 0
    ldr.w r0, =set_day_edit                 @ 08017E2A
    ldrb r2, [r0, #0x0]                     @ 08017E2E  r2 = set_day_edit
    ldr.w r0, =set_month_edit               @ 08017E30
    ldrb r1, [r0, #0x0]                     @ 08017E34  r1 = set_month_edit
    movs r0, #0x0                           @ 08017E36
    bl fn_080187D8                          @ 08017E38  draw the month-day page [r0=0, r1=set_month_edit, r2=set_day_edit]
    b .L08017F26                            @ 08017E3C
.L08017E3E:  @ reached from 08017E28 beq (set_edit == 0)
    ldr.w r0, =set_day                      @ 08017E3E
    ldrb r2, [r0, #0x0]                     @ 08017E42  r2 = set_day
    ldr.w r0, =set_month                    @ 08017E44
    ldrb r1, [r0, #0x0]                     @ 08017E48  r1 = set_month
    movs r0, #0x0                           @ 08017E4A
    bl fn_080187D8                          @ 08017E4C  draw the month-day page [r0=0, r1=set_month, r2=set_day]
    b .L08017F26                            @ 08017E50
.L08017E52:  @ reached from 08017E1E bne (set_item != 6)
    ldr.w r0, =set_item                     @ 08017E52
    ldrb r0, [r0, #0x0]                     @ 08017E56  r0 = set_item
    cmp r0, #0x5                            @ 08017E58  compare set_item with 5
    bne .L08017E82                          @ 08017E5A  if set_item != 5
    ldr.w r0, =set_edit                     @ 08017E5C
    ldrb r0, [r0, #0x0]                     @ 08017E60  r0 = set_edit
    cmp r0, #0x0                            @ 08017E62  compare set_edit with 0
    beq .L08017E74                          @ 08017E64  if set_edit == 0
    ldr.w r0, =set_year_edit                @ 08017E66
    ldrb r1, [r0, #0x0]                     @ 08017E6A  r1 = set_year_edit
    movs r0, #0x0                           @ 08017E6C
    bl fn_08018788                          @ 08017E6E  draw the year page [r0=0, r1=set_year_edit]
    b .L08017F26                            @ 08017E72
.L08017E74:  @ reached from 08017E64 beq (set_edit == 0)
    ldr.w r0, =set_year                     @ 08017E74
    ldrb r1, [r0, #0x0]                     @ 08017E78  r1 = set_year
    movs r0, #0x0                           @ 08017E7A
    bl fn_08018788                          @ 08017E7C  draw the year page [r0=0, r1=set_year]
    b .L08017F26                            @ 08017E80
.L08017E82:  @ reached from 08017E5A bne (set_item != 5)
    ldr.w r0, =set_item                     @ 08017E82
    ldrb r0, [r0, #0x0]                     @ 08017E86  r0 = set_item
    cmp r0, #0x8                            @ 08017E88  compare set_item with 8
    bne .L08017E94                          @ 08017E8A  if set_item != 8
    movs r0, #0x1                           @ 08017E8C
    bl fn_080189B0                          @ 08017E8E  draw the ID number [r0=1]
    b .L08017F26                            @ 08017E92
.L08017E94:  @ reached from 08017E8A bne (set_item != 8)
    ldr.w r0, =set_item                     @ 08017E94
    ldrb r0, [r0, #0x0]                     @ 08017E98  r0 = set_item
    cmp r0, #0x9                            @ 08017E9A  compare set_item with 9
    bne .L08017EC0                          @ 08017E9C  if set_item != 9
    ldr.w r0, =set_edit                     @ 08017E9E
    ldrb r0, [r0, #0x0]                     @ 08017EA2  r0 = set_edit
    cmp r0, #0x0                            @ 08017EA4  compare set_edit with 0
    beq .L08017EB4                          @ 08017EA6  if set_edit == 0
    ldr.w r0, =set_interval_edit            @ 08017EA8
    ldrh r0, [r0, #0x0]                     @ 08017EAC  r0 = set_interval_edit
    bl fn_080184D4                          @ 08017EAE  draw "In" and the logging interval [r0=set_interval_edit]
    b .L08017F26                            @ 08017EB2
.L08017EB4:  @ reached from 08017EA6 beq (set_edit == 0)
    ldr.w r0, =set_log_interval             @ 08017EB4
    ldrh r0, [r0, #0x0]                     @ 08017EB8  r0 = set_log_interval
    bl fn_080184D4                          @ 08017EBA  draw "In" and the logging interval [r0=set_log_interval]
    b .L08017F26                            @ 08017EBE
.L08017EC0:  @ reached from 08017E9C bne (set_item != 9)
    ldr.w r0, =set_item                     @ 08017EC0
    ldrb r0, [r0, #0x0]                     @ 08017EC4  r0 = set_item
    cmp r0, #0x2                            @ 08017EC6  compare set_item with 2
    bne .L08017ED6                          @ 08017EC8  if set_item != 2
    ldr.w r0, =set_apo_disable              @ 08017ECA
    ldrb r0, [r0, #0x0]                     @ 08017ECE  r0 = set_apo_disable
    bl fn_08018460                          @ 08017ED0  draw the APO state [r0=set_apo_disable]
    b .L08017F26                            @ 08017ED4
.L08017ED6:  @ reached from 08017EC8 bne (set_item != 2)
    ldr.w r0, =set_item                     @ 08017ED6
    ldrb r0, [r0, #0x0]                     @ 08017EDA  r0 = set_item
    cmp r0, #0x3                            @ 08017EDC  compare set_item with 3
    bne .L08017EEC                          @ 08017EDE  if set_item != 3
    ldr.w r0, =set_buzzer_on                @ 08017EE0
    ldrb r0, [r0, #0x0]                     @ 08017EE4  r0 = set_buzzer_on
    bl fn_08018490                          @ 08017EE6  draw the buzzer state [r0=set_buzzer_on]
    b .L08017F26                            @ 08017EEA
.L08017EEC:  @ reached from 08017EDE bne (set_item != 3)
    ldr.w r0, =set_item                     @ 08017EEC
    ldrb r0, [r0, #0x0]                     @ 08017EF0  r0 = set_item
    cmp r0, #0x1                            @ 08017EF2  compare set_item with 1
    bne .Lsd_port                           @ 08017EF4  if set_item != 1: IMP-07 checks the page bL before the item-0 fallback
    ldr.w r0, =lcd_shadow                   @ 08017EF6
    ldr r0, [r0, #0x8]                      @ 08017EFA  r0 = lcd_shadow+8
    orrs r0, r0, #0x20000                   @ 08017EFC  r0 = lcd_shadow+8 | 0x20000
    ldr.w r1, =lcd_shadow                   @ 08017F00
    str r0, [r1, #0x8]                      @ 08017F04  lcd_shadow+8 = (lcd_shadow+8 | 0x20000)
    ldr r0, =set_edit
    ldrb r0, [r0]
    cbz r0, 1f
    bl set_btrim_draw                       @ IMP-27: while the trim is edited, "bA" and the voltage in 0.01 V
    b .L08017F26
1:
    ldr.w r0, =set_bat_value                @ 08017F06
    ldrh r0, [r0, #0x0]                     @ 08017F0A  r0 = set_bat_value
    bl fn_0801839A                          @ 08017F0C  draw "BAT" and the battery value [r0=set_bat_value, r1=&lcd_shadow]
    b .L08017F26                            @ 08017F10
.Lsd_port:  @ IMP-07, IMP-09, IMP-10: reached from 08017EF4 bne with r0 = set_item
    cmp r0, #SET_ITEM_VERDICT               @ IMP-20: the limit pages Lt, Lo, HI (27..29) and the verdict (36)
    beq .Lsd_lt
    sub r1, r0, #SET_ITEM_LT
    cmp r1, #2
    bhi .Lsd_not_lt
.Lsd_lt:
    bl set_lt_draw                          @ r0 = item; returns 0 for the verdict page without a test
    cbnz r0, .Lsd_lt_done
    ldr.w r1, =set_item
    strb r0, [r1, #0x0]                     @ no test: item 0 again
    b .L08017F12
.Lsd_lt_done:
    b .L08017F26
.Lsd_not_lt:
    cmp r0, #SET_ITEM_TR                    @ IMP-21: the logging pages tr (30) and Ch (31)
    beq .Lsd_lg
    cmp r0, #SET_ITEM_CH
    bne .Lsd_not_lg
.Lsd_lg:
    bl set_lg_draw                          @ r0 = item
    b .L08017F26
.Lsd_not_lg:
    sub r1, r0, #SET_ITEM_ST_N              @ IMP-14, IMP-21: the statistics pages n (32), Sd (33) and the time pages
    cmp r1, #SET_ITEM_T_LO - SET_ITEM_ST_N  @ tHI (34), tLo (35) ...
    bhi .Lsd_not_stats
.Lsd_stats:
    ldr.w r1, =minmax_state
    ldrb r1, [r1, #0x0]
    cbnz r1, .Lsd_stats_on
    movs r0, #0x0                           @ ... exist only while MIN/MAX is on: item 0 again (MIN/MAX ended by its key,
    ldr.w r1, =set_item                     @ HOLD or a mode change)
    strb r0, [r1, #0x0]
    b .L08017F12                            @ v2.05 item-0 page
.Lsd_stats_on:
    bl ui_stats_page                        @ r0 = item
    b .L08017F26
.Lsd_not_stats:
    cmp r0, #SET_ITEM_TC                    @ IMP-10: the thermocouple type page tc (item 23)
    bne .Lsd_not_tc
    bl set_tc_draw                          @ draw "tc-" and the type
    b .L08017F26
.Lsd_not_tc:
    cmp r0, #SET_ITEM_RELP                  @ IMP-11: the REL view page rEL (item 22)
    bne .Lsd_not_relp
    bl set_relp_draw                        @ draw "rEL-d" or "rEL-P"
    b .L08017F26
.Lsd_not_relp:
    cmp r0, #SET_ITEM_DSP                   @ IMP-12: the display level page dSP (item 24)
    bne .Lsd_not_dsp
    bl set_dsp_draw                         @ draw "dSP 1" or "dSP 2"
    b .L08017F26
.Lsd_not_dsp:
    cmp r0, #SET_ITEM_BH                    @ IMP-16: the continuity hold page bH (item 26)
    bne .Lsd_not_bh
    bl set_bh_draw                          @ draw "bH" and the hold time
    b .L08017F26
.Lsd_not_bh:
    cmp r0, #SET_ITEM_LP                    @ IMP-24: the current-loop page LP (item 37)
    bne .Lsd_not_lp
    bl set_lp_draw
    b .L08017F26
.Lsd_not_lp:
    cmp r0, #SET_ITEM_RTD                   @ IMP-25: the RTD page Pt (item 38)
    bne .Lsd_not_rtd
    bl set_rtd_draw
    b .L08017F26
.Lsd_not_rtd:
    cmp r0, #SET_ITEM_HUNT                  @ IMP-45: the anti-hunting page HUnt (item 41)
    bne .Lsd_not_hunt
    bl set_hunt_draw
    b .L08017F26
.Lsd_not_hunt:
    cmp r0, #SET_ITEM_BFT                   @ IMP-28: the Bluetooth file transfer page Ld (item 39)
    bne .Lsd_not_bft
    bl set_bft_draw
    b .L08017F26
.Lsd_not_bft:
    cmp r0, #SET_ITEM_FMT                   @ IMP-32: the card format page For (item 40)
    bne .Lsd_not_fmt
    bl set_fmt_draw
    b .L08017F26
.Lsd_not_fmt:
    cmp r0, #SET_ITEM_CLK                   @ IMP-13: the clock page CL (item 25)
    bne .Lsd_not_clk
    bl set_clk_draw                         @ draw "CL 24" or "CL 12"
    b .L08017F26
.Lsd_not_clk:
    cmp r0, #SET_ITEM_BT                    @ IMP-09: the Bluetooth frame rate page bt (item 21)
    bne .Lsd_not_bt
    bl set_bt_draw                          @ draw "bt" and the rate
    b .L08017F26
.Lsd_not_bt:
    cmp r0, #SET_ITEM_BL                    @ the backlight page bL (item 20)
    bne .L08017F12                          @ any other item: v2.05 fallback (item 0, board temperature)
    ldr.w r0, =pwr_bl_setting
    ldrb r0, [r0, #0x0]                     @ r0 = setting code
    bl set_bl_draw                          @ draw "bL" and the value
    b .L08017F26
.L08017F12:  @ reached from 08017EF4 bne (set_item != 1)
    movs r0, #0x0                           @ 08017F12
    ldr.w r1, =set_item                     @ 08017F14
    strb r0, [r1, #0x0]                     @ 08017F18  set_item = 0
    ldr.w r0, =set_temp_value               @ 08017F1A
    ldrsh r0, [r0, #0x0]                    @ 08017F1E  r0 = set_temp_value
    bl fn_08018A00                          @ 08017F22  draw the board temperature page [r0=set_temp_value, r1=&set_item]
.L08017F26:  @ reached from 08017994 b, 080179BA b, 08017A3A b, 08017A54 b, 08017A6E b, 08017B1A b, 08017B3C bne (meter_mode != 20 (0x14)), 08017B48 beq (set_cur_opt == 0), 08017B50 b, 08017B6A b, 08017BB2 b, 08017C06 b, 08017C24 bne (meter_mode != 20 (0x14)), 08017C30 bne (set_cur_opt != 0), 08017C3C bne (set_cur_opt != 0), 08017C44 b, 08017CAC b, 08017CCC b, 08017CD8 b, 08017CEE b, 08017D0E b, 08017D1A b, 08017D2A b, 08017D40 b, 08017D88 b, 08017DAC b, 08017DC2 b, 08017DD8 b, 08017E00 b, 08017E14 b, 08017E3C b, 08017E50 b, 08017E72 b, 08017E80 b, 08017E92 b, 08017EB2 b, 08017EBE b, 08017ED4 b, 08017EEA b, 08017F10 b
    pop {r0, r4, r5, pc}                    @ 08017F26
ENDFUNC fn_0801797C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08017F94 - draw the item 10 value (modes 2, 4 and the current modes)
@ Replaces : 0x08017F94 FUN_08017F94 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_sub_dp, set_sub_value
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_08017F94
    push {r7, lr}                           @ 08017F94
    bl fn_080180AA                          @ 08017F96  select the decimal point of the item 10 value
    movs r2, #0x0                           @ 08017F9A
    ldr.w r0, =set_sub_dp                   @ 08017F9C
    ldrb r1, [r0, #0x0]                     @ 08017FA0  r1 = set_sub_dp
    ldr.w r0, =set_sub_value                @ 08017FA2
    ldr r0, [r0, #0x0]                      @ 08017FA6  r0 = set_sub_value
    movs r3, #0xa                           @ 08017FA8
    sdiv r0, r0, r3                         @ 08017FAA  r0 = set_sub_value / 10 (0xA)
    bl lcd_show_value_pos0_4                @ 08017FAE  draw a number on the secondary display [r0=(set_sub_value / 10 (0xA)), r1=set_sub_dp, r2=0, r3=10 (0xA)]
    pop {r0, pc}                            @ 08017FB2
ENDFUNC fn_08017F94
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801801E - select the decimal point of the VA item 10 value (voltage page)
@ Replaces : 0x0801801E FUN_0801801E (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads v_200080C6; writes set_sub_dp
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_0801801E
    ldr.w r0, =v_200080C6                   @ 0801801E
    ldrb r0, [r0, #0x0]                     @ 08018022  r0 = v_200080C6
    cmp r0, #0x0                            @ 08018024  compare v_200080C6 with 0
    beq .L08018032                          @ 08018026  if v_200080C6 == 0
    movs r0, #0x3                           @ 08018028
    ldr.w r1, =set_sub_dp                   @ 0801802A
    strb r0, [r1, #0x0]                     @ 0801802E  set_sub_dp = 3
    b .L0801803A                            @ 08018030
.L08018032:  @ reached from 08018026 beq (v_200080C6 == 0)
    movs r0, #0x4                           @ 08018032
    ldr.w r1, =set_sub_dp                   @ 08018034
    strb r0, [r1, #0x0]                     @ 08018038  set_sub_dp = 4
.L0801803A:  @ reached from 08018030 b
    bx lr                                   @ 0801803A
ENDFUNC fn_0801801E
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801803C - select the decimal point of the VA item 10 value (current page)
@ Replaces : 0x0801803C FUN_0801803C (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads meter_mode, set_va_sub2; writes set_sub_dp
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_0801803C
    ldr.w r0, =meter_mode                   @ 0801803C
    ldrb r0, [r0, #0x0]                     @ 08018040  r0 = meter_mode
    cmp r0, #0xd                            @ 08018042  compare meter_mode with 13 (0xD)
    beq .L08018050                          @ 08018044  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 08018046
    ldrb r0, [r0, #0x0]                     @ 0801804A  r0 = meter_mode
    cmp r0, #0x16                           @ 0801804C  compare meter_mode with 22 (0x16)
    bne .L0801805A                          @ 0801804E  if meter_mode != 22 (0x16)
.L08018050:  @ reached from 08018044 beq (meter_mode == 13 (0xD))
    movs r0, #0x4                           @ 08018050
    ldr.w r1, =set_sub_dp                   @ 08018052
    strb r0, [r1, #0x0]                     @ 08018056  set_sub_dp = 4
    b .L080180A8                            @ 08018058
.L0801805A:  @ reached from 0801804E bne (meter_mode != 22 (0x16))
    ldr.w r0, =meter_mode                   @ 0801805A
    ldrb r0, [r0, #0x0]                     @ 0801805E  r0 = meter_mode
    cmp r0, #0xe                            @ 08018060  compare meter_mode with 14 (0xE)
    beq .L0801806E                          @ 08018062  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 08018064
    ldrb r0, [r0, #0x0]                     @ 08018068  r0 = meter_mode
    cmp r0, #0x17                           @ 0801806A  compare meter_mode with 23 (0x17)
    bne .L0801808C                          @ 0801806C  if meter_mode != 23 (0x17)
.L0801806E:  @ reached from 08018062 beq (meter_mode == 14 (0xE))
    ldr.w r0, =set_va_sub2                  @ 0801806E
    ldrb r0, [r0, #0x0]                     @ 08018072  r0 = set_va_sub2
    cmp r0, #0x0                            @ 08018074  compare set_va_sub2 with 0
    beq .L08018082                          @ 08018076  if set_va_sub2 == 0
    movs r0, #0x3                           @ 08018078
    ldr.w r1, =set_sub_dp                   @ 0801807A
    strb r0, [r1, #0x0]                     @ 0801807E  set_sub_dp = 3
    b .L080180A8                            @ 08018080
.L08018082:  @ reached from 08018076 beq (set_va_sub2 == 0)
    movs r0, #0x4                           @ 08018082
    ldr.w r1, =set_sub_dp                   @ 08018084
    strb r0, [r1, #0x0]                     @ 08018088  set_sub_dp = 4
    b .L080180A8                            @ 0801808A
.L0801808C:  @ reached from 0801806C bne (meter_mode != 23 (0x17))
    ldr.w r0, =set_va_sub2                  @ 0801808C
    ldrb r0, [r0, #0x0]                     @ 08018090  r0 = set_va_sub2
    cmp r0, #0x0                            @ 08018092  compare set_va_sub2 with 0
    beq .L080180A0                          @ 08018094  if set_va_sub2 == 0
    movs r0, #0x3                           @ 08018096
    ldr.w r1, =set_sub_dp                   @ 08018098
    strb r0, [r1, #0x0]                     @ 0801809C  set_sub_dp = 3
    b .L080180A8                            @ 0801809E
.L080180A0:  @ reached from 08018094 beq (set_va_sub2 == 0)
    movs r0, #0x2                           @ 080180A0
    ldr.w r1, =set_sub_dp                   @ 080180A2
    strb r0, [r1, #0x0]                     @ 080180A6  set_sub_dp = 2
.L080180A8:  @ reached from 08018058 b, 08018080 b, 0801808A b, 0801809E b
    bx lr                                   @ 080180A8
ENDFUNC fn_0801803C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080180AA - select the decimal point code of the item 10 value
@ Replaces : 0x080180AA FUN_080180AA (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads meter_mode, set_freq_range; writes set_sub_dp
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_080180AA
    push {r7, lr}                           @ 080180AA
    movs r0, #0x0                           @ 080180AC
    ldr.w r1, =set_sub_dp                   @ 080180AE
    strb r0, [r1, #0x0]                     @ 080180B2  set_sub_dp = 0
    ldr.w r0, =meter_mode                   @ 080180B4
    ldrb r0, [r0, #0x0]                     @ 080180B8  r0 = meter_mode
    cmp r0, #0x10                           @ 080180BA  compare meter_mode with 16 (0x10)
    beq .L080180E6                          @ 080180BC  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 080180BE
    ldrb r0, [r0, #0x0]                     @ 080180C2  r0 = meter_mode
    cmp r0, #0x12                           @ 080180C4  compare meter_mode with 18 (0x12)
    beq .L080180E6                          @ 080180C6  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 080180C8
    ldrb r0, [r0, #0x0]                     @ 080180CC  r0 = meter_mode
    cmp r0, #0x14                           @ 080180CE  compare meter_mode with 20 (0x14)
    beq .L080180E6                          @ 080180D0  if meter_mode == 20 (0x14)
    ldr.w r0, =meter_mode                   @ 080180D2
    ldrb r0, [r0, #0x0]                     @ 080180D6  r0 = meter_mode
    cmp r0, #0x2                            @ 080180D8  compare meter_mode with 2
    beq .L080180E6                          @ 080180DA  if meter_mode == 2
    ldr.w r0, =meter_mode                   @ 080180DC
    ldrb r0, [r0, #0x0]                     @ 080180E0  r0 = meter_mode
    cmp r0, #0x4                            @ 080180E2  compare meter_mode with 4
    bne .L080180F6                          @ 080180E4  if meter_mode != 4
.L080180E6:  @ reached from 080180BC beq (meter_mode == 16 (0x10)), 080180C6 beq (meter_mode == 18 (0x12)), 080180D0 beq (meter_mode == 20 (0x14)), 080180DA beq (meter_mode == 2)
    ldr.w r0, =set_freq_range               @ 080180E6
    ldrb r0, [r0, #0x0]                     @ 080180EA  r0 = set_freq_range
    bl fn_08018102                          @ 080180EC  decimal-point code table for the item 10 value [r0=set_freq_range]
    ldr.w r1, =set_sub_dp                   @ 080180F0
    strb r0, [r1, #0x0]                     @ 080180F4  set_sub_dp = r0
.L080180F6:  @ reached from 080180E4 bne (meter_mode != 4)
    ldr.w r0, =set_sub_dp                   @ 080180F6
    ldrb r0, [r0, #0x0]                     @ 080180FA  r0 = set_sub_dp
    bl fn_08017FB4                          @ 080180FC  secondary display decimal point / unit setup, r0 = code [r0=set_sub_dp]
    pop {r0, pc}                            @ 08018100
ENDFUNC fn_080180AA
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018102 - map a decimal point code to the next code
@ Replaces : 0x08018102 FUN_08018102 (v2.05)
@ In       : r0 = code
@ Out      : r0 = code
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_08018102
    movs r1, r0                             @ 08018102
    movs r0, #0x0                           @ 08018104
    uxtb r1, r1                             @ 08018106
    cmp r1, #0x0                            @ 08018108  compare r1 with 0
    beq .L0801811A                          @ 0801810A  if r1 == 0
    cmp r1, #0x2                            @ 0801810C  compare r1 with 2
    beq .L08018126                          @ 0801810E  if r1 == 2
    bcc .L08018120                          @ 08018110  if r1 <u 2
    cmp r1, #0x4                            @ 08018112  compare r1 with 4
    beq .L08018132                          @ 08018114  if r1 == 4
    bcc .L0801812C                          @ 08018116  if r1 <u 4
    b .L08018136                            @ 08018118
.L0801811A:  @ reached from 0801810A beq (r1 == 0)
    movs r2, #0x2                           @ 0801811A
    movs r0, r2                             @ 0801811C
    b .L08018136                            @ 0801811E
.L08018120:  @ reached from 08018110 bcc (r1 <u 2)
    movs r2, #0x1                           @ 08018120
    movs r0, r2                             @ 08018122
    b .L08018136                            @ 08018124
.L08018126:  @ reached from 0801810E beq (r1 == 2)
    movs r2, #0x3                           @ 08018126
    movs r0, r2                             @ 08018128
    b .L08018136                            @ 0801812A
.L0801812C:  @ reached from 08018116 bcc (r1 <u 4)
    movs r2, #0x2                           @ 0801812C
    movs r0, r2                             @ 0801812E
    b .L08018136                            @ 08018130
.L08018132:  @ reached from 08018114 beq (r1 == 4)
    movs r2, #0x1                           @ 08018132
    movs r0, r2                             @ 08018134
.L08018136:  @ reached from 08018118 b, 0801811E b, 08018124 b, 0801812A b, 08018130 b
    uxtb r0, r0                             @ 08018136
    bx lr                                   @ 08018138
ENDFUNC fn_08018102
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801813A - draw the blank edit-blink phase of an editable item
@ Replaces : 0x0801813A FUN_0801813A (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_digit_pos, set_item, set_stage; writes lcd_shadow, set_commit_req
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_0801813A
    push {r7, lr}                           @ 0801813A
    ldr.w r0, =lcd_shadow                   @ 0801813C
    ldr r0, [r0, #0x10]                     @ 08018140  r0 = lcd_shadow+16
    bics r0, r0, #0x20000000                @ 08018142  r0 = lcd_shadow+16 &~ 0x20000000
    ldr.w r1, =lcd_shadow                   @ 08018146
    str r0, [r1, #0x10]                     @ 0801814A  lcd_shadow+16 = (lcd_shadow+16 &~ 0x20000000)
    movs r0, #0x0                           @ 0801814C
    bl fn_08017FB4                          @ 0801814E  secondary display decimal point / unit setup, r0 = code [r0=0, r1=&lcd_shadow]
    ldr.w r0, =set_item                     @ 08018152
    ldrb r0, [r0, #0x0]                     @ 08018156  r0 = set_item
    cmp r0, #0x7                            @ 08018158  compare set_item with 7
    beq .L08018166                          @ 0801815A  if set_item == 7
    ldr.w r0, =set_item                     @ 0801815C
    ldrb r0, [r0, #0x0]                     @ 08018160  r0 = set_item
    cmp r0, #0x6                            @ 08018162  compare set_item with 6
    bne .L08018184                          @ 08018164  if set_item != 6
.L08018166:  @ reached from 0801815A beq (set_item == 7)
    ldr.w r0, =set_stage                    @ 08018166
    ldrb r0, [r0, #0x0]                     @ 0801816A  r0 = set_stage
    cmp r0, #0x0                            @ 0801816C  compare set_stage with 0
    bne .L0801817A                          @ 0801816E  if set_stage != 0
    ldr.w r1, =v205_tab_0801840C            @ 08018170
    movs r0, #0x0                           @ 08018172
    bl fn_08019B24                          @ 08018174  draw the clock separator [r0=0]
    b .L080181AC                            @ 08018178
.L0801817A:  @ reached from 0801816E bne (set_stage != 0)
    ldr.w r1, =v205_tab_0801840C            @ 0801817A
    movs r0, #0x3                           @ 0801817C
    bl fn_08019B24                          @ 0801817E  draw the clock separator [r0=3]
    b .L080181AC                            @ 08018182
.L08018184:  @ reached from 08018164 bne (set_item != 6)
    ldr.w r0, =set_item                     @ 08018184
    ldrb r0, [r0, #0x0]                     @ 08018188  r0 = set_item
    cmp r0, #0x8                            @ 0801818A  compare set_item with 8
    bne .L080181A2                          @ 0801818C  if set_item != 8
    ldr.w r1, =v205_tab_0801845C            @ 0801818E
    ldr.w r0, =set_digit_pos                @ 08018190
    ldrb r0, [r0, #0x0]                     @ 08018194  r0 = set_digit_pos
    rsbs r0, r0, #0x4                       @ 08018196  r0 = -set_digit_pos
    uxtb r0, r0                             @ 0801819A
    bl fn_08019B12                          @ 0801819C  draw the ID digit cursor [r0=(-set_digit_pos)]
    b .L080181AC                            @ 080181A0
.L080181A2:  @ reached from 0801818C bne (set_item != 8)
    ldr.w r1, =v205_tab_080291B0            @ 080181A2
    movs r0, #0x1                           @ 080181A6
    bl lcd_draw_5char                       @ 080181A8  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
.L080181AC:  @ reached from 08018178 b, 08018182 b, 080181A0 b
    movs r0, #0x1                           @ 080181AC
    ldr.w r1, =set_commit_req               @ 080181AE
    strb r0, [r1, #0x0]                     @ 080181B2  set_commit_req = 1
    pop {r0, pc}                            @ 080181B4
ENDFUNC fn_0801813A
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080181B6 - draw a signed value on the secondary display
@ Replaces : 0x080181B6 FUN_080181B6 (v2.05)
@ In       : r0 = signed value
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_sub_dp; writes lcd_shadow, set_commit_req
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_080181B6
    push {r3, r4, r5, lr}                   @ 080181B6
    movs r4, r0                             @ 080181B8
    cmp r4, #0x0                            @ 080181BA  compare r4 with 0
    bpl .L080181C4                          @ 080181BC  if r4 >=0 0
    rsbs r0, r4, #0                         @ 080181BE  r0 = -r4
    movs r5, r0                             @ 080181C0
    b .L080181C6                            @ 080181C2
.L080181C4:  @ reached from 080181BC bpl (r4 >=0 0)
    movs r5, r4                             @ 080181C4
.L080181C6:  @ reached from 080181C2 b
    ldr.w r0, =set_sub_dp                   @ 080181C6
    ldrb r0, [r0, #0x0]                     @ 080181CA  r0 = set_sub_dp
    bl fn_08017FB4                          @ 080181CC  secondary display decimal point / unit setup, r0 = code [r0=set_sub_dp]
    movs r0, r5                             @ 080181D0
    bl fn_0801B090                          @ 080181D2  split r0 into the five digit words lcd_digit4..0
    ldr.w r0, =set_sub_dp                   @ 080181D6
    ldrb r0, [r0, #0x0]                     @ 080181DA  r0 = set_sub_dp
    bl fn_0801B130                          @ 080181DC  convert the digit words for display (blanking, decimal point r0) [r0=set_sub_dp]
    ldr.w r1, =set_text5                    @ 080181E0
    movs r0, #0x1                           @ 080181E4
    bl lcd_draw_5char                       @ 080181E6  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
    cmp r4, #0x0                            @ 080181EA  compare r4 with 0
    bpl .L08018200                          @ 080181EC  if r4 >=0 0
    ldr.w r0, =lcd_shadow                   @ 080181EE
    ldr r0, [r0, #0x10]                     @ 080181F2  r0 = lcd_shadow+16
    orrs r0, r0, #0x20000000                @ 080181F4  r0 = lcd_shadow+16 | 0x20000000
    ldr.w r1, =lcd_shadow                   @ 080181F8
    str r0, [r1, #0x10]                     @ 080181FC  lcd_shadow+16 = (lcd_shadow+16 | 0x20000000)
    b .L08018210                            @ 080181FE
.L08018200:  @ reached from 080181EC bpl (r4 >=0 0)
    ldr.w r0, =lcd_shadow                   @ 08018200
    ldr r0, [r0, #0x10]                     @ 08018204  r0 = lcd_shadow+16
    bics r0, r0, #0x20000000                @ 08018206  r0 = lcd_shadow+16 &~ 0x20000000
    ldr.w r1, =lcd_shadow                   @ 0801820A
    str r0, [r1, #0x10]                     @ 0801820E  lcd_shadow+16 = (lcd_shadow+16 &~ 0x20000000)
.L08018210:  @ reached from 080181FE b
    movs r0, #0x1                           @ 08018210
    ldr.w r1, =set_commit_req               @ 08018212
    strb r0, [r1, #0x0]                     @ 08018216  set_commit_req = 1
    pop {r0, r4, r5, pc}                    @ 08018218
ENDFUNC fn_080181B6
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018228 - draw a scaled signed value (item 11 / 12 pages)
@ Replaces : 0x08018228 FUN_08018228 (v2.05)
@ In       : r0 = value, r1 = scale code (0, 100 or other)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_item_timer, v_200080A7; writes lcd_shadow, set_commit_req, set_item12_value, set_sub_dp,
@            set_text5
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_08018228
    push {r4, r5, r6, r7, r8, lr}           @ 08018228
    movs r4, r0                             @ 0801822C
    movs r5, r1                             @ 0801822E
    movs r8, #0x0                           @ 08018230
    ldr.w r0, =set_item_timer               @ 08018234
    ldrb r0, [r0, #0x0]                     @ 08018238  r0 = set_item_timer
    cmp r0, #0x0                            @ 0801823A  compare set_item_timer with 0
    beq .L08018244                          @ 0801823C  if set_item_timer == 0
    bl fn_08018356                          @ 0801823E  draw "burdn" [r0=set_item_timer]
    b .L0801834A                            @ 08018242
.L08018244:  @ reached from 0801823C beq (set_item_timer == 0)
    movs r6, r4                             @ 08018244
    cmp r6, #0x0                            @ 08018246  compare r6 with 0
    bpl .L08018250                          @ 08018248  if r6 >=0 0
    rsbs r6, r6, #0                         @ 0801824A  r6 = -r6
    movs r0, #0x1                           @ 0801824C
    mov r8, r0                              @ 0801824E
.L08018250:  @ reached from 08018248 bpl (r6 >=0 0)
    uxtb r5, r5                             @ 08018250
    cmp r5, #0x64                           @ 08018252  compare r5 with 100 (0x64)
    bne .L0801825A                          @ 08018254  if r5 != 100 (0x64)
    movs r7, r6                             @ 08018256
    b .L08018298                            @ 08018258
.L0801825A:  @ reached from 08018254 bne (r5 != 100 (0x64))
    uxtb r5, r5                             @ 0801825A
    cmp r5, #0x0                            @ 0801825C  compare r5 with 0
    bne .L08018280                          @ 0801825E  if r5 != 0
    mov r0, #0x3e8                          @ 08018260
    sdiv r0, r6, r0                         @ 08018264  r0 = r6 / 1000 (0x3E8)
    movs r7, r0                             @ 08018268
    mov r0, #0x3e8                          @ 0801826A
    sdiv r1, r6, r0                         @ 0801826E  r1 = r6 / 1000 (0x3E8)
    mls r0, r0, r1, r6                      @ 08018272  r0 = r6 - 1000 (0x3E8) * (r6 / 1000 (0x3E8))
    cmp r0, #0x1f4                          @ 08018276  compare (r6 - 1000 (0x3E8) * (r6 / 1000 (0x3E8))) with 500 (0x1F4)
    blt .L08018298                          @ 0801827A  if (r6 - 1000 (0x3E8) * (r6 / 1000 (0x3E8))) <s 500 (0x1F4)
    adds r7, r7, #0x1                       @ 0801827C  r7 = (r6 / 1000 (0x3E8)) + 1
    b .L08018298                            @ 0801827E
.L08018280:  @ reached from 0801825E bne (r5 != 0)
    movs r0, #0x64                          @ 08018280
    sdiv r0, r6, r0                         @ 08018282  r0 = r6 / 100 (0x64)
    movs r7, r0                             @ 08018286
    movs r0, #0x64                          @ 08018288
    sdiv r1, r6, r0                         @ 0801828A  r1 = r6 / 100 (0x64)
    mls r0, r0, r1, r6                      @ 0801828E  r0 = r6 - 100 (0x64) * (r6 / 100 (0x64))
    cmp r0, #0x32                           @ 08018292  compare (r6 - 100 (0x64) * (r6 / 100 (0x64))) with 50 (0x32)
    blt .L08018298                          @ 08018294  if (r6 - 100 (0x64) * (r6 / 100 (0x64))) <s 50 (0x32)
    adds r7, r7, #0x1                       @ 08018296  r7 = (r6 / 100 (0x64)) + 1
.L08018298:  @ reached from 08018258 b, 0801827A blt ((r6 - 1000 (0x3E8) * (r6 / 1000 (0x3E8))) <s 500 (0x1F4)), 0801827E b, 08018294 blt ((r6 - 100 (0x64) * (r6 / 100 (0x64))) <s 50 (0x32))
    ldr.w r0, =set_item12_value             @ 08018298
    strh r7, [r0, #0x0]                     @ 0801829C  set_item12_value = r7
    uxtb r8, r8                             @ 0801829E
    cmp r8, #0x0                            @ 080182A2  compare r8 with 0
    beq .L080182B8                          @ 080182A6  if r8 == 0
    ldr.w r0, =set_item12_value             @ 080182A8
    ldrsh r0, [r0, #0x0]                    @ 080182AC  r0 = set_item12_value
    rsbs r0, r0, #0                         @ 080182B0  r0 = -set_item12_value
    ldr.w r1, =set_item12_value             @ 080182B2
    strh r0, [r1, #0x0]                     @ 080182B6  set_item12_value = (-set_item12_value)
.L080182B8:  @ reached from 080182A6 beq (r8 == 0)
    uxtb r5, r5                             @ 080182B8
    cmp r5, #0x64                           @ 080182BA  compare r5 with 100 (0x64)
    bne .L080182EA                          @ 080182BC  if r5 != 100 (0x64)
    ldr.w r0, =v_200080A7                   @ 080182BE
    ldrb r0, [r0, #0x0]                     @ 080182C2  r0 = v_200080A7
    cmp r0, #0x0                            @ 080182C4  compare v_200080A7 with 0
    beq .L080182EA                          @ 080182C6  if v_200080A7 == 0
    movs r0, #0x20                          @ 080182C8
    ldr.w r1, =set_text5                    @ 080182CA
    strb r0, [r1, #0x1]                     @ 080182CE  set_text5+1 = 32 (0x20)
    movs r0, #0x4f                          @ 080182D0
    ldr.w r1, =set_text5                    @ 080182D2
    strb r0, [r1, #0x2]                     @ 080182D6  set_text5+2 = 79 (0x4F)
    movs r0, #0x46                          @ 080182D8
    ldr.w r1, =set_text5                    @ 080182DA
    strb r0, [r1, #0x3]                     @ 080182DE  set_text5+3 = 70 (0x46)
    movs r0, #0x4c                          @ 080182E0
    ldr.w r1, =set_text5                    @ 080182E2
    strb r0, [r1, #0x4]                     @ 080182E6  set_text5+4 = 76 (0x4C)
    b .L0801830C                            @ 080182E8
.L080182EA:  @ reached from 080182BC bne (r5 != 100 (0x64)), 080182C6 beq (v_200080A7 == 0)
    movs r0, r7                             @ 080182EA
    bl fn_0801B090                          @ 080182EC  split r0 into the five digit words lcd_digit4..0
    movs r0, #0x1                           @ 080182F0
    ldr.w r1, =set_sub_dp                   @ 080182F2
    strb r0, [r1, #0x0]                     @ 080182F6  set_sub_dp = 1
    ldr.w r0, =set_sub_dp                   @ 080182F8
    ldrb r0, [r0, #0x0]                     @ 080182FC  r0 = set_sub_dp
    bl fn_08017FB4                          @ 080182FE  secondary display decimal point / unit setup, r0 = code [r0=set_sub_dp, r1=&set_sub_dp]
    ldr.w r0, =set_sub_dp                   @ 08018302
    ldrb r0, [r0, #0x0]                     @ 08018306  r0 = set_sub_dp
    bl fn_0801B130                          @ 08018308  convert the digit words for display (blanking, decimal point r0) [r0=set_sub_dp]
.L0801830C:  @ reached from 080182E8 b
    uxtb r8, r8                             @ 0801830C
    cmp r8, #0x0                            @ 08018310  compare r8 with 0
    beq .L08018328                          @ 08018314  if r8 == 0
    ldr.w r0, =lcd_shadow                   @ 08018316
    ldr r0, [r0, #0x10]                     @ 0801831A  r0 = lcd_shadow+16
    orrs r0, r0, #0x20000000                @ 0801831C  r0 = lcd_shadow+16 | 0x20000000
    ldr.w r1, =lcd_shadow                   @ 08018320
    str r0, [r1, #0x10]                     @ 08018324  lcd_shadow+16 = (lcd_shadow+16 | 0x20000000)
    b .L08018338                            @ 08018326
.L08018328:  @ reached from 08018314 beq (r8 == 0)
    ldr.w r0, =lcd_shadow                   @ 08018328
    ldr r0, [r0, #0x10]                     @ 0801832C  r0 = lcd_shadow+16
    bics r0, r0, #0x20000000                @ 0801832E  r0 = lcd_shadow+16 &~ 0x20000000
    ldr.w r1, =lcd_shadow                   @ 08018332
    str r0, [r1, #0x10]                     @ 08018336  lcd_shadow+16 = (lcd_shadow+16 &~ 0x20000000)
.L08018338:  @ reached from 08018326 b
    movs r0, #0x62                          @ 08018338
    ldr.w r1, =set_text5                    @ 0801833A
    strb r0, [r1, #0x0]                     @ 0801833E  set_text5 = 98 (0x62)
    ldr.w r1, =set_text5                    @ 08018340
    movs r0, #0x1                           @ 08018344
    bl lcd_draw_5char                       @ 08018346  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
.L0801834A:  @ reached from 08018242 b
    movs r0, #0x1                           @ 0801834A
    ldr.w r1, =set_commit_req               @ 0801834C
    strb r0, [r1, #0x0]                     @ 08018350  set_commit_req = 1
    pop {r4, r5, r6, r7, r8, pc}            @ 08018352
ENDFUNC fn_08018228
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018356 - draw "burdn" on the secondary display
@ Replaces : 0x08018356 FUN_08018356 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_commit_req, set_text5
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_08018356
    push {r7, lr}                           @ 08018356
    movs r0, #0x0                           @ 08018358
    bl fn_08017FB4                          @ 0801835A  secondary display decimal point / unit setup, r0 = code [r0=0]
    movs r0, #0x62                          @ 0801835E
    ldr.w r1, =set_text5                    @ 08018360
    strb r0, [r1, #0x0]                     @ 08018364  set_text5 = 98 (0x62)
    movs r0, #0x75                          @ 08018366
    ldr.w r1, =set_text5                    @ 08018368
    strb r0, [r1, #0x1]                     @ 0801836C  set_text5+1 = 117 (0x75)
    movs r0, #0x72                          @ 0801836E
    ldr.w r1, =set_text5                    @ 08018370
    strb r0, [r1, #0x2]                     @ 08018374  set_text5+2 = 114 (0x72)
    movs r0, #0x64                          @ 08018376
    ldr.w r1, =set_text5                    @ 08018378
    strb r0, [r1, #0x3]                     @ 0801837C  set_text5+3 = 100 (0x64)
    movs r0, #0x6e                          @ 0801837E
    ldr.w r1, =set_text5                    @ 08018380
    strb r0, [r1, #0x4]                     @ 08018384  set_text5+4 = 110 (0x6E)
    ldr.w r1, =set_text5                    @ 08018386
    movs r0, #0x1                           @ 0801838A
    bl lcd_draw_5char                       @ 0801838C  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
    movs r0, #0x1                           @ 08018390
    ldr.w r1, =set_commit_req               @ 08018392
    strb r0, [r1, #0x0]                     @ 08018396  set_commit_req = 1
    pop {r0, pc}                            @ 08018398
ENDFUNC fn_08018356
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801839A - draw "BAT" and the battery value (item 1)
@ Replaces : 0x0801839A FUN_0801839A (v2.05)
@ In       : r0 = battery value (limited to 99)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_lcd_digit0, set_lcd_digit1; writes set_commit_req, set_sub_dp, set_text5
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_0801839A
    push {r4, lr}                           @ 0801839A
    movs r4, r0                             @ 0801839C
    movs r0, #0x1                           @ 0801839E
    ldr.w r1, =set_sub_dp                   @ 080183A0
    strb r0, [r1, #0x0]                     @ 080183A4  set_sub_dp = 1
    ldr.w r0, =set_sub_dp                   @ 080183A6
    ldrb r0, [r0, #0x0]                     @ 080183AA  r0 = set_sub_dp
    bl fn_08017FB4                          @ 080183AC  secondary display decimal point / unit setup, r0 = code [r0=set_sub_dp, r1=&set_sub_dp]
    uxth r4, r4                             @ 080183B0
    cmp r4, #0x64                           @ 080183B2  compare r4 with 100 (0x64)
    blt .L080183BA                          @ 080183B4  if r4 <s 100 (0x64)
    movs r0, #0x63                          @ 080183B6
    movs r4, r0                             @ 080183B8
.L080183BA:  @ reached from 080183B4 blt (r4 <s 100 (0x64))
    uxth r4, r4                             @ 080183BA
    movs r0, r4                             @ 080183BC
    bl fn_0801B090                          @ 080183BE  split r0 into the five digit words lcd_digit4..0
    movs r0, #0x42                          @ 080183C2
    ldr.w r1, =set_text5                    @ 080183C4
    strb r0, [r1, #0x0]                     @ 080183C8  set_text5 = 66 (0x42)
    movs r0, #0x41                          @ 080183CA
    ldr.w r1, =set_text5                    @ 080183CC
    strb r0, [r1, #0x1]                     @ 080183D0  set_text5+1 = 65 (0x41)
    movs r0, #0x54                          @ 080183D2
    ldr.w r1, =set_text5                    @ 080183D4
    strb r0, [r1, #0x2]                     @ 080183D8  set_text5+2 = 84 (0x54)
    ldr.w r0, =set_lcd_digit1               @ 080183DA
    ldr r0, [r0, #0x0]                      @ 080183DE  r0 = set_lcd_digit1
    adds r0, #0x30                          @ 080183E0  r0 = set_lcd_digit1 + 48 (0x30)
    ldr.w r1, =set_text5                    @ 080183E2
    strb r0, [r1, #0x3]                     @ 080183E6  set_text5+3 = (set_lcd_digit1 + 48 (0x30))
    ldr.w r0, =set_lcd_digit0               @ 080183E8
    ldr r0, [r0, #0x0]                      @ 080183EC  r0 = set_lcd_digit0
    adds r0, #0x30                          @ 080183EE  r0 = set_lcd_digit0 + 48 (0x30)
    ldr.w r1, =set_text5                    @ 080183F0
    strb r0, [r1, #0x4]                     @ 080183F4  set_text5+4 = (set_lcd_digit0 + 48 (0x30))
    ldr.w r1, =set_text5                    @ 080183F6
    movs r0, #0x1                           @ 080183FA
    bl lcd_draw_5char                       @ 080183FC  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
    movs r0, #0x1                           @ 08018400
    ldr.w r1, =set_commit_req               @ 08018402
    strb r0, [r1, #0x0]                     @ 08018406  set_commit_req = 1
    pop {r4, pc}                            @ 08018408
ENDFUNC fn_0801839A
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018410 - draw "Lcd-n" (item 4)
@ Replaces : 0x08018410 FUN_08018410 (v2.05)
@ In       : r0 = contrast
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_commit_req, set_text5
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_08018410
    push {r4, lr}                           @ 08018410
    movs r4, r0                             @ 08018412
    movs r0, #0x0                           @ 08018414
    bl fn_08017FB4                          @ 08018416  secondary display decimal point / unit setup, r0 = code [r0=0]
    movs r0, #0x4c                          @ 0801841A
    ldr.w r1, =set_text5                    @ 0801841C
    strb r0, [r1, #0x0]                     @ 08018420  set_text5 = 76 (0x4C)
    movs r0, #0x63                          @ 08018422
    ldr.w r1, =set_text5                    @ 08018424
    strb r0, [r1, #0x1]                     @ 08018428  set_text5+1 = 99 (0x63)
    movs r0, #0x64                          @ 0801842A
    ldr.w r1, =set_text5                    @ 0801842C
    strb r0, [r1, #0x2]                     @ 08018430  set_text5+2 = 100 (0x64)
    movs r0, #0x2d                          @ 08018432
    ldr.w r1, =set_text5                    @ 08018434
    strb r0, [r1, #0x3]                     @ 08018438  set_text5+3 = 45 (0x2D)
    subs r0, r4, #0xa                       @ 0801843A  r0 = r4 - 10 (0xA)
    adds r0, #0x30                          @ 0801843E  r0 = (r4 - 10 (0xA)) + 48 (0x30)
    ldr.w r1, =set_text5                    @ 08018440
    strb r0, [r1, #0x4]                     @ 08018444  set_text5+4 = ((r4 - 10 (0xA)) + 48 (0x30))
    ldr.w r1, =set_text5                    @ 08018446
    movs r0, #0x1                           @ 0801844A
    bl lcd_draw_5char                       @ 0801844C  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
    movs r0, #0x1                           @ 08018450
    ldr.w r1, =set_commit_req               @ 08018452
    strb r0, [r1, #0x0]                     @ 08018456  set_commit_req = 1
    pop {r4, pc}                            @ 08018458
ENDFUNC fn_08018410
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018460 - draw the APO state, "APO.oF" or the time "APO. 1" / "APO.15" / "APO.30" / "APO.60" (item 2, IMP-49)
@ Replaces : 0x08018460 FUN_08018460 (v2.05)
@ In       : r0 = set_apo_disable
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_commit_req
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_08018460
    push {r4, lr}                           @ 08018460
    movs r4, r0                             @ 08018462
    movs r0, #0x2                           @ 08018464
    bl fn_08017FB4                          @ 08018466  secondary display decimal point / unit setup, r0 = code [r0=2]
    uxtb r4, r4                             @ 0801846A
    cmp r4, #0x0                            @ 0801846C  compare r4 with 0
    bne .L0801847C                          @ 0801846E  if r4 != 0
    bl set_apot_text                        @ IMP-49: "APO30", "APO 1", "APO15" or "APO60" (v2.05 0x08018470: "APOoN")
    mov r1, r0
    movs r0, #0x1                           @ 08018474
    bl lcd_draw_5char                       @ 08018476  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
    b .L08018486                            @ 0801847A
.L0801847C:  @ reached from 0801846E bne (r4 != 0)
    ldr.w r1, =v205_tab_080291C0            @ 0801847C
    movs r0, #0x1                           @ 08018480
    bl lcd_draw_5char                       @ 08018482  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
.L08018486:  @ reached from 0801847A b
    movs r0, #0x1                           @ 08018486
    ldr.w r1, =set_commit_req               @ 08018488
    strb r0, [r1, #0x0]                     @ 0801848C  set_commit_req = 1
    pop {r4, pc}                            @ 0801848E
ENDFUNC fn_08018460
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018490 - draw the buzzer state, "b-On " or "b-OFF" (item 3)
@ Replaces : 0x08018490 FUN_08018490 (v2.05)
@ In       : r0 = set_buzzer_on
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_commit_req
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_08018490
    push {r4, lr}                           @ 08018490
    movs r4, r0                             @ 08018492
    movs r0, #0x0                           @ 08018494
    bl fn_08017FB4                          @ 08018496  secondary display decimal point / unit setup, r0 = code [r0=0]
    uxtb r4, r4                             @ 0801849A
    cmp r4, #0x0                            @ 0801849C  compare r4 with 0
    beq .L080184AC                          @ 0801849E  if r4 == 0
    ldr.w r1, =v205_tab_080291C8            @ 080184A0
    movs r0, #0x1                           @ 080184A4
    bl lcd_draw_5char                       @ 080184A6  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
    b .L080184B6                            @ 080184AA
.L080184AC:  @ reached from 0801849E beq (r4 == 0)
    ldr.w r1, =v205_tab_080291D0            @ 080184AC
    movs r0, #0x1                           @ 080184B0
    bl lcd_draw_5char                       @ 080184B2  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
.L080184B6:  @ reached from 080184AA b
    movs r0, #0x1                           @ 080184B6
    ldr.w r1, =set_commit_req               @ 080184B8
    strb r0, [r1, #0x0]                     @ 080184BC  set_commit_req = 1
    pop {r4, pc}                            @ 080184BE
ENDFUNC fn_08018490
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080184D4 - draw "In" and the logging interval (item 9)
@ Replaces : 0x080184D4 FUN_080184D4 (v2.05)
@ In       : r0 = interval 0..999
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_commit_req, set_text5
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_080184D4
    push {r3, r4, r5, lr}                   @ 080184D4
    movs r4, r0                             @ 080184D6
    movs r5, r4                             @ 080184D8
    movs r0, #0x0                           @ 080184DA
    bl fn_08017FB4                          @ 080184DC  secondary display decimal point / unit setup, r0 = code [r0=0]
    movs r0, #0x49                          @ 080184E0
    ldr.w r1, =set_text5                    @ 080184E2
    strb r0, [r1, #0x0]                     @ 080184E6  set_text5 = 73 (0x49)
    movs r0, #0x6e                          @ 080184E8
    ldr.w r1, =set_text5                    @ 080184EA
    strb r0, [r1, #0x1]                     @ 080184EE  set_text5+1 = 110 (0x6E)
    uxth r4, r4                             @ 080184F0
    cmp r4, #0x64                           @ 080184F2  compare r4 with 100 (0x64)
    blt .L08018514                          @ 080184F4  if r4 <s 100 (0x64)
    uxth r5, r5                             @ 080184F6
    movs r0, #0x64                          @ 080184F8
    sdiv r0, r5, r0                         @ 080184FA  r0 = r5 / 100 (0x64)
    adds r0, #0x30                          @ 080184FE  r0 = (r5 / 100 (0x64)) + 48 (0x30)
    ldr.w r1, =set_text5                    @ 08018500
    strb r0, [r1, #0x2]                     @ 08018504  set_text5+2 = ((r5 / 100 (0x64)) + 48 (0x30))
    uxth r5, r5                             @ 08018506
    movs r0, #0x64                          @ 08018508
    sdiv r1, r5, r0                         @ 0801850A  r1 = r5 / 100 (0x64)
    mls r5, r0, r1, r5                      @ 0801850E  r5 = r5 - 100 (0x64) * (r5 / 100 (0x64))
    b .L0801851C                            @ 08018512
.L08018514:  @ reached from 080184F4 blt (r4 <s 100 (0x64))
    movs r0, #0x20                          @ 08018514
    ldr.w r1, =set_text5                    @ 08018516
    strb r0, [r1, #0x2]                     @ 0801851A  set_text5+2 = 32 (0x20)
.L0801851C:  @ reached from 08018512 b
    uxth r4, r4                             @ 0801851C
    cmp r4, #0xa                            @ 0801851E  compare r4 with 10 (0xA)
    blt .L08018534                          @ 08018520  if r4 <s 10 (0xA)
    uxth r5, r5                             @ 08018522
    movs r0, #0xa                           @ 08018524
    sdiv r0, r5, r0                         @ 08018526  r0 = r5 / 10 (0xA)
    adds r0, #0x30                          @ 0801852A  r0 = (r5 / 10 (0xA)) + 48 (0x30)
    ldr.w r1, =set_text5                    @ 0801852C
    strb r0, [r1, #0x3]                     @ 08018530  set_text5+3 = ((r5 / 10 (0xA)) + 48 (0x30))
    b .L0801853C                            @ 08018532
.L08018534:  @ reached from 08018520 blt (r4 <s 10 (0xA))
    movs r0, #0x20                          @ 08018534
    ldr.w r1, =set_text5                    @ 08018536
    strb r0, [r1, #0x3]                     @ 0801853A  set_text5+3 = 32 (0x20)
.L0801853C:  @ reached from 08018532 b
    uxth r5, r5                             @ 0801853C
    movs r0, #0xa                           @ 0801853E
    sdiv r1, r5, r0                         @ 08018540  r1 = r5 / 10 (0xA)
    mls r0, r0, r1, r5                      @ 08018544  r0 = r5 - 10 (0xA) * (r5 / 10 (0xA))
    adds r0, #0x30                          @ 08018548  r0 = (r5 - 10 (0xA) * (r5 / 10 (0xA))) + 48 (0x30)
    ldr.w r1, =set_text5                    @ 0801854A
    strb r0, [r1, #0x4]                     @ 0801854E  set_text5+4 = ((r5 - 10 (0xA) * (r5 / 10 (0xA))) + 48 (0x30))
    ldr.w r1, =set_text5                    @ 08018550
    movs r0, #0x1                           @ 08018554
    bl lcd_draw_5char                       @ 08018556  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
    movs r0, #0x1                           @ 0801855A
    ldr.w r1, =set_commit_req               @ 0801855C
    strb r0, [r1, #0x0]                     @ 08018560  set_commit_req = 1
    pop {r0, r4, r5, pc}                    @ 08018562
ENDFUNC fn_080184D4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018590 - draw the scaled ACV value (item 11 of ACV)
@ Replaces : 0x08018590 FUN_08018590 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_acv_float, set_ovl; writes lcd_shadow, set_acv_scaled, set_commit_req, set_sub_dp
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ Deviation: OF-46 (dBm of a zero reading, -infinity: five dashes instead of the integer conversion of the infinity)
@ -----------------------------------------------------------------------------
FUNC fn_08018590
    push {r3, r4, r5, lr}                   @ 08018590
    ldr.w r0, =set_ovl                      @ 08018592
    ldrb r0, [r0, #0x0]                     @ 08018596  r0 = set_ovl
    cmp r0, #0x0                            @ 08018598  compare set_ovl with 0
    beq .L080185A4                          @ 0801859A  if set_ovl == 0
    movs r0, #0x1                           @ 0801859C
    bl fn_080199B4                          @ 0801859E  show " OFL " or burden text (r0) [r0=1]
    b .L080186AA                            @ 080185A2
.L080185A4:  @ reached from 0801859A beq (set_ovl == 0)
    @ OF-46: a zero ACV reading gives dBm = 10 log10(0) = -infinity (0xFF800000); v2.05 converted it to the unsigned integer
    @ 0xFFFFFFFF and drew "- 7295".  There is no finite value to show: draw the five dashes of the v2.05 text 0x08029288
    @ (the "no value" text of the VA sub display, fn_08019A86 at 0x08017CA8; " OFL " is the overload text and would be wrong
    @ for a reading of zero), no minus sign and no decimal point; set_acv_scaled (BLE sub display case 11) gets 0 instead of 1.
    ldr.w r0, =set_acv_float                @ OF-46
    ldr r0, [r0, #0x0]                      @ OF-46  r0 = set_acv_float
    ldr.w r1, =0xFF800000                   @ OF-46  -infinity
    cmp r0, r1                              @ OF-46
    bne .Lof46_finite                       @ OF-46  finite dBm: the v2.05 path
    movs r0, #0x0                           @ OF-46
    ldr.w r1, =set_acv_scaled               @ OF-46
    str r0, [r1, #0x0]                      @ OF-46  set_acv_scaled = 0
    ldr.w r1, =set_sub_dp                   @ OF-46
    strb r0, [r1, #0x0]                     @ OF-46  set_sub_dp = 0
    bl fn_08017FB4                          @ OF-46  no sub decimal point [r0=0]
    ldr.w r0, =lcd_shadow                   @ OF-46
    ldr r1, [r0, #0x10]                     @ OF-46  r1 = lcd_shadow+16
    bics r1, r1, #0x20000000                @ OF-46  sub minus sign off
    str r1, [r0, #0x10]                     @ OF-46
    movs r0, #0x1                           @ OF-46
    bl fn_08019A86                          @ OF-46  "-----" on the sub display [r0=1]
    b .Lof46_commit                         @ OF-46
.Lof46_finite:
    ldr.w r0, =set_acv_float                @ 080185A4
    ldr r0, [r0, #0x0]                      @ 080185A8  r0 = set_acv_float
    movs r1, #0x0                           @ 080185AA
    bl fn_08020390                          @ 080185AC  float compare r0 with r1 (result in the flags) [r0=set_acv_float, r1=0]
    bcs .L080185CC                          @ 080185B0  if 0 >=u 0 (flags of the last result)
    ldr.w r0, =lcd_shadow                   @ 080185B2
    ldr r0, [r0, #0x10]                     @ 080185B4  r0 = lcd_shadow+16
    orrs r0, r0, #0x20000000                @ 080185B6  r0 = lcd_shadow+16 | 0x20000000
    ldr.w r1, =lcd_shadow                   @ 080185BA
    str r0, [r1, #0x10]                     @ 080185BC  lcd_shadow+16 = (lcd_shadow+16 | 0x20000000)
    ldr.w r0, =set_acv_float                @ 080185BE
    ldr r0, [r0, #0x0]                      @ 080185C2  r0 = set_acv_float
    eors r0, r0, #0x80000000                @ 080185C4  r0 = set_acv_float ^ 0x80000000
    movs r4, r0                             @ 080185C8
    b .L080185E0                            @ 080185CA
.L080185CC:  @ reached from 080185B0 bcs (0 >=u 0 (flags of the last result))
    ldr.w r0, =lcd_shadow                   @ 080185CC
    ldr r0, [r0, #0x10]                     @ 080185CE  r0 = lcd_shadow+16
    bics r0, r0, #0x20000000                @ 080185D0  r0 = lcd_shadow+16 &~ 0x20000000
    ldr.w r1, =lcd_shadow                   @ 080185D4
    str r0, [r1, #0x10]                     @ 080185D6  lcd_shadow+16 = (lcd_shadow+16 &~ 0x20000000)
    ldr.w r0, =set_acv_float                @ 080185D8
    ldr r0, [r0, #0x0]                      @ 080185DC  r0 = set_acv_float
    movs r4, r0                             @ 080185DE
.L080185E0:  @ reached from 080185CA b
    movs r0, r4                             @ 080185E0
    ldr.w r1, =0x447A0000                   @ 080185E2
    bl fn_0802035C                          @ 080185E6  float compare r0 with r1 (result in the flags)
    bhi .L080185FE                          @ 080185EA  if r4 >u 0 (flags of the last result)
    movs r0, #0x0                           @ 080185EC
    ldr.w r1, =set_sub_dp                   @ 080185EE
    strb r0, [r1, #0x0]                     @ 080185F2  set_sub_dp = 0
    movs r0, r4                             @ 080185F4
    bl fn_0801BD24                          @ 080185F6  float to unsigned integer (f2uiz) [r1=&set_sub_dp]
    movs r5, r0                             @ 080185FA
    b .L08018662                            @ 080185FC
.L080185FE:  @ reached from 080185EA bhi (r4 >u 0 (flags of the last result))
    movs r0, r4                             @ 080185FE
    ldr.w r1, =0x42C80000                   @ 08018600
    bl fn_0802035C                          @ 08018604  float compare r0 with r1 (result in the flags)
    bhi .L08018624                          @ 08018608  if r4 >u 0 (flags of the last result)
    movs r0, #0x1                           @ 0801860A
    ldr.w r1, =set_sub_dp                   @ 0801860C
    strb r0, [r1, #0x0]                     @ 08018610  set_sub_dp = 1
    ldr.w r0, =0x41200000                   @ 08018612
    movs r1, r4                             @ 08018616
    bl fn_08013090                          @ 08018618  float multiply r0 * r1
    bl fn_0801BD24                          @ 0801861C  float to unsigned integer (f2uiz)
    movs r5, r0                             @ 08018620
    b .L08018662                            @ 08018622
.L08018624:  @ reached from 08018608 bhi (r4 >u 0 (flags of the last result))
    movs r0, r4                             @ 08018624
    ldr.w r1, =0x41200000                   @ 08018626
    bl fn_0802035C                          @ 0801862A  float compare r0 with r1 (result in the flags)
    bhi .L0801864A                          @ 0801862E  if r4 >u 0 (flags of the last result)
    movs r0, #0x2                           @ 08018630
    ldr.w r1, =set_sub_dp                   @ 08018632
    strb r0, [r1, #0x0]                     @ 08018636  set_sub_dp = 2
    ldr.w r0, =0x42C80000                   @ 08018638
    movs r1, r4                             @ 0801863C
    bl fn_08013090                          @ 0801863E  float multiply r0 * r1
    bl fn_0801BD24                          @ 08018642  float to unsigned integer (f2uiz)
    movs r5, r0                             @ 08018646
    b .L08018662                            @ 08018648
.L0801864A:  @ reached from 0801862E bhi (r4 >u 0 (flags of the last result))
    movs r0, #0x3                           @ 0801864A
    ldr.w r1, =set_sub_dp                   @ 0801864C
    strb r0, [r1, #0x0]                     @ 08018650  set_sub_dp = 3
    ldr.w r0, =0x447A0000                   @ 08018652
    movs r1, r4                             @ 08018656
    bl fn_08013090                          @ 08018658  float multiply r0 * r1
    bl fn_0801BD24                          @ 0801865C  float to unsigned integer (f2uiz)
    movs r5, r0                             @ 08018660
.L08018662:  @ reached from 080185FC b, 08018622 b, 08018648 b
    ldr.w r0, =set_acv_float                @ 08018662
    ldr r0, [r0, #0x0]                      @ 08018666  r0 = set_acv_float
    movs r1, #0x0                           @ 08018668
    bl fn_08020390                          @ 0801866A  float compare r0 with r1 (result in the flags) [r0=set_acv_float, r1=0]
    bcs .L0801867A                          @ 0801866E  if 0 >=u 0 (flags of the last result)
    rsbs r0, r5, #0                         @ 08018670  r0 = -r5
    ldr.w r1, =set_acv_scaled               @ 08018672
    str r0, [r1, #0x0]                      @ 08018676  set_acv_scaled = (-r5)
    b .L08018680                            @ 08018678
.L0801867A:  @ reached from 0801866E bcs (0 >=u 0 (flags of the last result))
    ldr.w r0, =set_acv_scaled               @ 0801867A
    str r5, [r0, #0x0]                      @ 0801867E  set_acv_scaled = r5
.L08018680:  @ reached from 08018678 b
    ldr.w r0, =set_sub_dp                   @ 08018680
    ldrb r0, [r0, #0x0]                     @ 08018684  r0 = set_sub_dp
    bl fn_08017FB4                          @ 08018686  secondary display decimal point / unit setup, r0 = code [r0=set_sub_dp]
    movs r0, r5                             @ 0801868A
    bl fn_0801B090                          @ 0801868C  split r0 into the five digit words lcd_digit4..0
    ldr.w r0, =set_sub_dp                   @ 08018690
    ldrb r0, [r0, #0x0]                     @ 08018694  r0 = set_sub_dp
    bl fn_0801B130                          @ 08018696  convert the digit words for display (blanking, decimal point r0) [r0=set_sub_dp]
    ldr.w r1, =set_text5                    @ 0801869A
    movs r0, #0x1                           @ 0801869C
    bl lcd_draw_5char                       @ 0801869E  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
.Lof46_commit:
    movs r0, #0x1                           @ 080186A2
    ldr.w r1, =set_commit_req               @ 080186A4
    strb r0, [r1, #0x0]                     @ 080186A8  set_commit_req = 1
.L080186AA:  @ reached from 080185A2 b
    pop {r0, r4, r5, pc}                    @ 080186AA
ENDFUNC fn_08018590
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080186AC - draw the "bd" option state, "bdOn " or "bdOFF"
@ Replaces : 0x080186AC FUN_080186AC (v2.05)
@ In       : r0 = option
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_commit_req
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_080186AC
    push {r4, lr}                           @ 080186AC
    movs r4, r0                             @ 080186AE
    movs r0, #0x3                           @ 080186B0
    bl fn_08017FB4                          @ 080186B2  secondary display decimal point / unit setup, r0 = code [r0=3]
    uxtb r4, r4                             @ 080186B6
    cmp r4, #0x0                            @ 080186B8  compare r4 with 0
    beq .L080186C8                          @ 080186BA  if r4 == 0
    ldr.w r1, =v205_tab_080291D8            @ 080186BC
    movs r0, #0x1                           @ 080186C0
    bl lcd_draw_5char                       @ 080186C2  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
    b .L080186D2                            @ 080186C6
.L080186C8:  @ reached from 080186BA beq (r4 == 0)
    ldr.w r1, =v205_tab_080291E0            @ 080186C8
    movs r0, #0x1                           @ 080186CC
    bl lcd_draw_5char                       @ 080186CE  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
.L080186D2:  @ reached from 080186C6 b
    movs r0, #0x1                           @ 080186D2
    ldr.w r1, =set_commit_req               @ 080186D4
    strb r0, [r1, #0x0]                     @ 080186D8  set_commit_req = 1
    pop {r4, pc}                            @ 080186DA
ENDFUNC fn_080186AC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080186E0 - draw the DIODE source text, "    3" or "   15" (item 10)
@ Replaces : 0x080186E0 FUN_080186E0 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_diode_15v; writes set_commit_req
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_080186E0
    push {r7, lr}                           @ 080186E0
    movs r0, #0x0                           @ 080186E2
    bl fn_08017FB4                          @ 080186E4  secondary display decimal point / unit setup, r0 = code [r0=0]
    ldr.w r0, =set_diode_15v                @ 080186E8
    ldrb r0, [r0, #0x0]                     @ 080186EC  r0 = set_diode_15v
    cmp r0, #0x0                            @ 080186EE  compare set_diode_15v with 0
    beq .L080186FE                          @ 080186F0  if set_diode_15v == 0
    ldr.w r1, =v205_tab_080291E8            @ 080186F2
    movs r0, #0x1                           @ 080186F6
    bl lcd_draw_5char                       @ 080186F8  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
    b .L08018708                            @ 080186FC
.L080186FE:  @ reached from 080186F0 beq (set_diode_15v == 0)
    ldr.w r1, =v205_tab_080291F0            @ 080186FE
    movs r0, #0x1                           @ 08018702
    bl lcd_draw_5char                       @ 08018704  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1]
.L08018708:  @ reached from 080186FC b
    movs r0, #0x1                           @ 08018708
    ldr.w r1, =set_commit_req               @ 0801870A
    strb r0, [r1, #0x0]                     @ 0801870E  set_commit_req = 1
    pop {r0, pc}                            @ 08018710
ENDFUNC fn_080186E0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080189B0 - draw the ID number (item 8)
@ Replaces : 0x080189B0 FUN_080189B0 (v2.05)
@ In       : r0 = 0 deferred commit, else commit now
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_id_edit; writes set_commit_req
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_080189B0
    push {r4, lr}                           @ 080189B0
    movs r4, r0                             @ 080189B2
    movs r0, #0x0                           @ 080189B4
    bl fn_08017FB4                          @ 080189B6  secondary display decimal point / unit setup, r0 = code [r0=0]
    ldr.w r0, =set_id_edit                  @ 080189BA
    ldr r0, [r0, #0x0]                      @ 080189BE  r0 = set_id_edit
    bl fn_0801B090                          @ 080189C0  split r0 into the five digit words lcd_digit4..0 [r0=set_id_edit]
    movs r0, #0x4                           @ 080189C4
    bl fn_0801B130                          @ 080189C6  convert the digit words for display (blanking, decimal point r0) [r0=4]
    ldr.w r1, =set_text5                    @ 080189CA
    movs r0, #0x1                           @ 080189CC
    bl lcd_draw_5char                       @ 080189CE  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
    uxtb r4, r4                             @ 080189D2
    cmp r4, #0x0                            @ 080189D4  compare r4 with 0
    bne .L080189E0                          @ 080189D6  if r4 != 0
    movs r0, #0x1                           @ 080189D8
    ldr.w r1, =set_commit_req               @ 080189DA
    strb r0, [r1, #0x0]                     @ 080189DC  set_commit_req = 1
    b .L080189E4                            @ 080189DE
.L080189E0:  @ reached from 080189D6 bne (r4 != 0)
    bl lcd_commit_shadow                    @ 080189E0  commit the LCD shadow words to the LCD
.L080189E4:  @ reached from 080189DE b
    pop {r4, pc}                            @ 080189E4
ENDFUNC fn_080189B0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018A00 - draw the board temperature page (item 0)
@ Replaces : 0x08018A00 FUN_08018A00 (v2.05)
@ In       : r0 = temperature value (s16)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads set_lcd_digit3, set_temp_celsius, set_temp_flag; writes lcd_shadow, set_commit_req, set_text5
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/lcd_map.md
@ -----------------------------------------------------------------------------
FUNC fn_08018A00
    push {r4, r5, r6, lr}                   @ 08018A00
    movs r4, r0                             @ 08018A02
    movs r5, #0x0                           @ 08018A04
    ldr.w r0, =lcd_shadow                   @ 08018A06
    ldr r0, [r0, #0x10]                     @ 08018A08  r0 = lcd_shadow+16
    bics r0, r0, #0x20000000                @ 08018A0A  r0 = lcd_shadow+16 &~ 0x20000000
    ldr.w r1, =lcd_shadow                   @ 08018A0E
    str r0, [r1, #0x10]                     @ 08018A10  lcd_shadow+16 = (lcd_shadow+16 &~ 0x20000000)
    movs r0, r4                             @ 08018A12
    sxth r0, r0                             @ 08018A14
    bl fn_08018AD8                          @ 08018A16  temperature for display (C or F, rounded to 0.1) [r1=&lcd_shadow]
    movs r6, r0                             @ 08018A1A
    ldr.w r0, =set_temp_flag                @ 08018A1C
    ldrb r0, [r0, #0x0]                     @ 08018A20  r0 = set_temp_flag
    cmp r0, #0x0                            @ 08018A22  compare set_temp_flag with 0
    beq .L08018A34                          @ 08018A24  if set_temp_flag == 0
    movs r0, #0x0                           @ 08018A26
    bl fn_08017FB4                          @ 08018A28  secondary display decimal point / unit setup, r0 = code [r0=0]
    movs r0, #0x1                           @ 08018A2C
    bl fn_08019A22                          @ 08018A2E  show temperature fault text (r0) [r0=1]
    b .L08018AD2                            @ 08018A32
.L08018A34:  @ reached from 08018A24 beq (set_temp_flag == 0)
    movs r0, #0x2                           @ 08018A34
    bl fn_08017FB4                          @ 08018A36  secondary display decimal point / unit setup, r0 = code [r0=2]
    sxth r6, r6                             @ 08018A3A
    cmp r6, #0x0                            @ 08018A3C  compare r6 with 0
    bpl .L08018A4A                          @ 08018A3E  if r6 >=0 0
    movs r0, #0x1                           @ 08018A40
    movs r5, r0                             @ 08018A42
    sxth r6, r6                             @ 08018A44
    rsbs r6, r6, #0                         @ 08018A46  r6 = -r6
    b .L08018A4E                            @ 08018A48
.L08018A4A:  @ reached from 08018A3E bpl (r6 >=0 0)
    movs r0, #0x0                           @ 08018A4A
    movs r5, r0                             @ 08018A4C
.L08018A4E:  @ reached from 08018A48 b
    sxth r6, r6                             @ 08018A4E
    movs r0, #0xa                           @ 08018A50
    mul r0, r0, r6                          @ 08018A52  r0 = 10 (0xA) * r6
    bl fn_0801B090                          @ 08018A56  split r0 into the five digit words lcd_digit4..0 [r0=(10 (0xA) * r6)]
    movs r0, #0x2                           @ 08018A5A
    bl fn_0801B130                          @ 08018A5C  convert the digit words for display (blanking, decimal point r0) [r0=2]
    uxtb r5, r5                             @ 08018A60
    cmp r5, #0x1                            @ 08018A62  compare r5 with 1
    bne .L08018A82                          @ 08018A64  if r5 != 1
    ldr.w r0, =set_lcd_digit3               @ 08018A66
    ldr r0, [r0, #0x0]                      @ 08018A6A  r0 = set_lcd_digit3
    cmp r0, #0x20                           @ 08018A6C  compare set_lcd_digit3 with 32 (0x20)
    bne .L08018A7A                          @ 08018A6E  if set_lcd_digit3 != 32 (0x20)
    movs r0, #0x2d                          @ 08018A70
    ldr.w r1, =set_text5                    @ 08018A72
    strb r0, [r1, #0x1]                     @ 08018A76  set_text5+1 = 45 (0x2D)
    b .L08018A82                            @ 08018A78
.L08018A7A:  @ reached from 08018A6E bne (set_lcd_digit3 != 32 (0x20))
    movs r0, #0x2d                          @ 08018A7A
    ldr.w r1, =set_text5                    @ 08018A7C
    strb r0, [r1, #0x0]                     @ 08018A80  set_text5 = 45 (0x2D)
.L08018A82:  @ reached from 08018A64 bne (r5 != 1), 08018A78 b
    ldr.w r0, =set_text5                    @ 08018A82
    ldrb r0, [r0, #0x0]                     @ 08018A86  r0 = set_text5
    cmp r0, #0x20                           @ 08018A88  compare set_text5 with 32 (0x20)
    bne .L08018AA6                          @ 08018A8A  if set_text5 != 32 (0x20)
    movs r0, #0x0                           @ 08018A8C
    ldr.w r1, =set_text5                    @ 08018A8E
    strb r0, [r1, #0x0]                     @ 08018A92  set_text5 = 0
    ldr.w r0, =set_text5                    @ 08018A94
    ldrb r0, [r0, #0x1]                     @ 08018A98  r0 = set_text5+1
    cmp r0, #0x20                           @ 08018A9A  compare set_text5+1 with 32 (0x20)
    bne .L08018AA6                          @ 08018A9C  if set_text5+1 != 32 (0x20)
    movs r0, #0x0                           @ 08018A9E
    ldr.w r1, =set_text5                    @ 08018AA0
    strb r0, [r1, #0x1]                     @ 08018AA4  set_text5+1 = 0
.L08018AA6:  @ reached from 08018A8A bne (set_text5 != 32 (0x20)), 08018A9C bne (set_text5+1 != 32 (0x20))
    ldr.w r0, =set_temp_celsius             @ 08018AA6
    ldrb r0, [r0, #0x0]                     @ 08018AAA  r0 = set_temp_celsius
    cmp r0, #0x0                            @ 08018AAC  compare set_temp_celsius with 0
    beq .L08018ABA                          @ 08018AAE  if set_temp_celsius == 0
    movs r0, #0x63                          @ 08018AB0
    ldr.w r1, =set_text5                    @ 08018AB2
    strb r0, [r1, #0x4]                     @ 08018AB6  set_text5+4 = 99 (0x63)
    b .L08018AC2                            @ 08018AB8
.L08018ABA:  @ reached from 08018AAE beq (set_temp_celsius == 0)
    movs r0, #0x46                          @ 08018ABA
    ldr.w r1, =set_text5                    @ 08018ABC
    strb r0, [r1, #0x4]                     @ 08018AC0  set_text5+4 = 70 (0x46)
.L08018AC2:  @ reached from 08018AB8 b
    ldr.w r1, =set_text5                    @ 08018AC2
    movs r0, #0x1                           @ 08018AC6
    bl lcd_draw_5char                       @ 08018AC8  draw 5 characters, r0 = 0 main (positions 5..9) or 1 secondary (0..4), r1 = text [r0=1, r1=&set_text5]
    movs r0, #0x1                           @ 08018ACC
    ldr.w r1, =set_commit_req               @ 08018ACE
    strb r0, [r1, #0x0]                     @ 08018AD0  set_commit_req = 1
.L08018AD2:  @ reached from 08018A32 b
    pop {r4, r5, r6, pc}                    @ 08018AD2
ENDFUNC fn_08018A00
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801871C - draw the continuity threshold text (item 10 of BEEP)
@ Replaces : 0x0801871C FUN_0801871C (v2.05)
@ In       : r0 = code 0..15
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes lcd_shadow, set_commit_req
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); analysis/autorange_and_scheduler.md 9
@ Deviation: IMP-05: codes 0..15 (v2.05: 0..3, text pointers 0x08029200 etc.); codes above 15 draw nothing, as v2.05
@            does for codes above 3
@ Note     : The text pointer comes from set_cont_text[code]: codes 0..3 point at the four v2.05 strings "DN 30", "UP
@            30", "DN300", "UP300" (v205_tab_080291F8, 08029200, 08029208, 08029210), codes 4..15 at new strings of
@            the same 5-glyph format.
@ -----------------------------------------------------------------------------
FUNC fn_0801871C
    push {r4, lr}                           @ 0801871C
    movs r4, r0                             @ 0801871E
    ldr.w r0, =lcd_shadow                   @ 08018720
    ldr r0, [r0, #0x10]                     @ 08018724  r0 = lcd_shadow+16
    bics r0, r0, #0x20000000                @ 08018726  r0 = lcd_shadow+16 &~ 0x20000000
    ldr.w r1, =lcd_shadow                   @ 0801872A
    str r0, [r1, #0x10]                     @ 0801872E  lcd_shadow+16 = (lcd_shadow+16 &~ 0x20000000)
    movs r0, #0x0                           @ 08018730
    bl fn_08017FB4                          @ 08018732  secondary display decimal point / unit setup, r0 = code [r0=0, r1=&lcd_shadow]
    uxtb r4, r4                             @ 08018736
    cmp r4, #15                          @ IMP-05: codes 0..15
    bhi .L08018776                       @ above 15: nothing drawn (v2.05 for codes above 3)
    ldr.w r1, =set_cont_text
    ldr.w r1, [r1, r4, lsl #2]           @ pointer to the 5-character text of the code
    movs r0, #1                          @ secondary display
    bl lcd_draw_5char
.L08018776:  @ reached from the replacement code above
    movs r0, #0x1                           @ 08018776
    ldr.w r1, =set_commit_req               @ 08018778
    strb r0, [r1, #0x0]                     @ 0801877C  set_commit_req = 1
    pop {r4, pc}                            @ 0801877E
ENDFUNC fn_0801871C
    .ltorg

    .section .rodata.set, "a", %progbits
    .balign 4
@ IMP-05: continuity threshold codes (EEPROM 0x014, set_cont_code).  Display order DN 1, DN 5, DN 10, DN 30,
@ DN 50, DN100, DN200, DN300, UP 1, UP 5, UP 10, UP 30, UP 50, UP100, UP200, UP300 (analysis/autorange_and_
@ scheduler.md 9).  Codes 0..3 are the v2.05 codes (DN 30, UP 30, DN300, UP300).
    .global set_cont_order
set_cont_order:                         @ display position -> code
    .byte 4, 5, 6, 0, 7, 8, 9, 2, 10, 11, 12, 1, 13, 14, 15, 3
    .size set_cont_order, . - set_cont_order
    .global set_cont_pos
set_cont_pos:                           @ code -> display position (inverse of set_cont_order)
    .byte 3, 11, 7, 15, 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14
    .size set_cont_pos, . - set_cont_pos
    .balign 4
    .global set_cont_text
set_cont_text:                          @ code -> pointer to the 5-character text
    .word v205_tab_080291F8             @ 0  "DN 30" (v2.05)
    .word v205_tab_08029200             @ 1  "UP 30" (v2.05)
    .word v205_tab_08029208             @ 2  "DN300" (v2.05)
    .word v205_tab_08029210             @ 3  "UP300" (v2.05)
    .word set_str_dn1                   @ 4  "DN  1"
    .word set_str_dn5                   @ 5  "DN  5"
    .word set_str_dn10                  @ 6  "DN 10"
    .word set_str_dn50                  @ 7  "DN 50"
    .word set_str_dn100                 @ 8  "DN100"
    .word set_str_dn200                 @ 9  "DN200"
    .word set_str_up1                   @ 10 "UP  1"
    .word set_str_up5                   @ 11 "UP  5"
    .word set_str_up10                  @ 12 "UP 10"
    .word set_str_up50                  @ 13 "UP 50"
    .word set_str_up100                 @ 14 "UP100"
    .word set_str_up200                 @ 15 "UP200"
    .size set_cont_text, . - set_cont_text
@ New texts: 5 glyphs followed by three zero bytes, the format of the v2.05 texts at 0x080291B8..0x08029210.
    .balign 4
set_str_dn1:
    .ascii "DN  1"
    .byte 0, 0, 0
set_str_dn5:
    .ascii "DN  5"
    .byte 0, 0, 0
set_str_dn10:
    .ascii "DN 10"
    .byte 0, 0, 0
set_str_dn50:
    .ascii "DN 50"
    .byte 0, 0, 0
set_str_dn100:
    .ascii "DN100"
    .byte 0, 0, 0
set_str_dn200:
    .ascii "DN200"
    .byte 0, 0, 0
set_str_up1:
    .ascii "UP  1"
    .byte 0, 0, 0
set_str_up5:
    .ascii "UP  5"
    .byte 0, 0, 0
set_str_up10:
    .ascii "UP 10"
    .byte 0, 0, 0
set_str_up50:
    .ascii "UP 50"
    .byte 0, 0, 0
set_str_up100:
    .ascii "UP100"
    .byte 0, 0, 0
set_str_up200:
    .ascii "UP200"
    .byte 0, 0, 0
