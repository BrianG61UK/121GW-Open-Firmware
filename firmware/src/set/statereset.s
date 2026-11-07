@ =============================================================================
@ statereset.s - SET: set_state_reset
@
@ SET module, part 3: set_state_reset, the boot / wake state reset.
@
@ Replaces v2.05 FUN_08024DE0 (called by main 0x08024B56 and after a STOP wake 0x08024EF2).  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

@ Module-local names of v2.05 RAM variables (address = the v_XXXXXXXX symbol of ram_v205.inc)
    .equ set_bat_low,           v_2000803B   @ debounced low-battery flag
    .equ set_key_remote_req,    v_20008069   @ remote key request pending
    .equ set_key_remote_code,   v_2000806D   @ remote key code (1..8, 0x81..0x88)
    .equ set_cal_mode,          v_2000808A   @ calibration mode flag (owner CAL)
    .equ set_date_edit_en,      v_2000808B   @ SETUP pressed in the power-on window: date-code editing enabled
    .equ set_diode_15v,         v_200080B3   @ DIODE source 0 = 3 V, 1 = 15 V (EEPROM 0x012 read at boot, forced 0, OF-23)

    .section .text.set, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08024DE0 - set_state_reset: reload all stored settings and reset the run state (boot and STOP wake)
@ Replaces : 0x08024DE0 FUN_08024DE0 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (sys_main, enter_stop_and_reinit)
@ RAM      : reads v_20008038; writes acdc_active, filter_1khz, hold_active, hold_stage2, meter_mode, meter_range,
@            minmax_state, peak_hold, rel_active, set_bat_low, set_cal_mode, set_date_edit_en, set_diode_15v,
@            set_key_remote_code, set_key_remote_req, v_20007FE0, v_20008065, v_20008066, v_20008072, v_20008073,
@            v_20008087, v_200080B1, v_200080B2, v_200080C5, va_channel; the anti-hunting state and setting (ah_reset,
@            set_relp_load: set_hunt_on; IMP-45); strict image: v_2000807B = 0 (OF-55)
@ Spec     : EEPROM_MAP.md 6 (boot reads, order of the calls); analysis/keys_setup.md 3; DESIGN.md 3.2 step 5
@ Note     : Order as v2.05: read the NJU6350 (fn_0800FF18); markers 0x26 and 0x1F (fn_08010F10, fn_080104BC); board
@            temperature offset (load_cal_record_from_eeprom(0xC8, 0)); interval, contrast, APO, temperature unit,
@            DIODE flag, continuity code, VA "bd", buzzer; date code and ID number (fn_08010F4C, fn_08010F8C);
@            fn_08010BE8 (LOG); APO reload (fn_0800ED26).  Then the run state: low-battery flag, range, mode,
@            calibration mode and the date-edit enable are cleared, the default setup item chosen (fn_0800D718),
@            min/max, hold, hold stage 2, REL, peak, 1 kHz filter, DIODE 15 V, 0x200080B1, 0x200080B2, AC+DC, the VA
@            channel flags 0x200080C4 and 0x200080C5 and the dial sample and debounce bytes (0x20008065, 0x20008066)
@            are cleared; after a STOP wake (0x20008038 set) the key state is pre-set so a key held during the wake
@            counts as already counted (0x20008072 = 0x33, 0x20008073 = 10); finally the remote key request is cleared
@            and the contrast is applied (fn_0801B77A).
@ Note     : The EEPROM values are read through the NVM readers, which read the EEPROM directly before cal_cache_load
@            and the cache afterwards (firmware/requests/W7_to_W9.md item 3).
@ -----------------------------------------------------------------------------
FUNC fn_08024DE0
    push {r7, lr}                           @ 08024DE0
    bl fn_0800FF18                          @ 08024DE2  read year, month, day, hour, minute, second from the NJU6350
    bl fn_08010F10                          @ 08024DE6  read marker 0x26 (0 if 0xA5)
    ldr.w r1, =v_20007FE0                   @ 08024DEA
    strb r0, [r1, #0x0]                     @ 08024DEC  v_20007FE0 = r0
    bl fn_080104BC                          @ 08024DEE  read marker 0x1F (0 if 0xA5) [r1=&v_20007FE0]
    ldr.w r1, =v_20008087                   @ 08024DF2
    strb r0, [r1, #0x0]                     @ 08024DF4  v_20008087 = r0
    movs r1, #0x0                           @ 08024DF6
    movs r0, #0xc8                          @ 08024DF8
    bl load_cal_record_from_eeprom          @ 08024DFA  load a calibration record (mode r0, range r1) [r0=200 (0xC8), r1=0]
    bl fn_08011218                          @ 08024DFE  load the logging interval
    bl fn_08011258                          @ 08024E02  load the contrast
    bl fn_080112A4                          @ 08024E06  load the APO setting
    bl set_apot_load                        @ IMP-49: the auto power-off time (EEPROM 0x02B)
    bl fn_080112FC                          @ 08024E0A  load the temperature unit
    bl fn_08011340                          @ 08024E0E  load the DIODE 15 V flag
    bl fn_08011394                          @ 08024E12  load the continuity threshold code
    bl fn_080113DC                          @ 08024E16  load the VA "bd" option
    bl fn_08011410                          @ 08024E1A  load the buzzer setting
    bl set_bl_load                          @ IMP-07: load the backlight auto-off setting (EEPROM 0x017)
    bl set_dbm_load                         @ IMP-08: load the dBm reference (EEPROM 0x011)
    bl set_bt_load                          @ IMP-09: load the Bluetooth frame rate (EEPROM 0x015)
    bl set_tc_load                          @ IMP-10: load and select the thermocouple type (EEPROM 0x00F)
    bl set_relp_load                        @ IMP-11, IMP-13, IMP-45: load the REL view, the clock and the anti-hunting setting (EEPROM 0x020 bits 0, 3, 4)
    bl ah_reset                             @ IMP-45: no anti-hunting lock or counted timeout survives a STOP wake (RAM is kept in STOP)
    bl set_dsp_load                         @ IMP-12: load the display level (EEPROM 0x013)
    bl set_bh_load                          @ IMP-16: load the continuity hold time (EEPROM 0x021)
    bl lt_reset                             @ IMP-20: limit test off, no limits (RAM only)
    bl set_ch_load                          @ IMP-21: logging change threshold (EEPROM 0x022)
    bl set_lp_load                          @ IMP-24: current-loop percent view of DCmA (EEPROM 0x028)
    bl set_rtd_load                         @ IMP-25: RTD temperature view of OHM (EEPROM 0x029)
    bl set_btrim_load                       @ IMP-27: battery voltage trim (EEPROM 0x02A)
    bl fn_08010F4C                          @ 08024E1E  load the date code from EEPROM 0x001
    bl fn_08010F8C                          @ 08024E22  load the ID number from EEPROM 0x003
    bl fn_08010BE8                          @ 08024E26  logging state reset at boot
    bl fn_0800ED26                          @ 08024E2A  reload the auto-power-off counter
    bl pwr_bl_reset                         @ IMP-07: backlight flag and countdown follow PE8 (low after power-on and STOP wake)
    bl pwr_bl_restore                       @ IMP-07: switch the backlight on again if it was on at the last MODE long press
    movs r0, #0x0                           @ 08024E2E
    ldr.w r1, =set_bat_low                  @ 08024E30
    strb r0, [r1, #0x0]                     @ 08024E32  set_bat_low = 0
    movs r0, #0x0                           @ 08024E34
    ldr.w r1, =meter_range                  @ 08024E36
    strb r0, [r1, #0x0]                     @ 08024E38  meter_range = 0
    movs r0, #0x0                           @ 08024E3A
    ldr.w r1, =meter_mode                   @ 08024E3C
    strb r0, [r1, #0x0]                     @ 08024E3E  meter_mode = 0
    movs r0, #0x0                           @ 08024E40
    ldr.w r1, =set_cal_mode                 @ 08024E42
    strb r0, [r1, #0x0]                     @ 08024E44  set_cal_mode = 0
    movs r0, #0x0                           @ 08024E46
    ldr.w r1, =set_date_edit_en             @ 08024E48
    strb r0, [r1, #0x0]                     @ 08024E4A  set_date_edit_en = 0
    bl fn_0800D718                          @ 08024E4C  default setup item for the mode [r0=0, r1=&set_date_edit_en]
    movs r0, #0x0                           @ 08024E50
    ldr.w r1, =minmax_state                 @ 08024E52
    strb r0, [r1, #0x0]                     @ 08024E54  minmax_state = 0
    movs r0, #0x0                           @ 08024E56
    ldr.w r1, =hold_active                  @ 08024E58
    strb r0, [r1, #0x0]                     @ 08024E5A  hold_active = 0
    movs r0, #0x0                           @ 08024E5C
    ldr.w r1, =hold_stage2                  @ 08024E5E
    strb r0, [r1, #0x0]                     @ 08024E60  hold_stage2 = 0
    movs r0, #0x0                           @ 08024E62
    ldr.w r1, =rel_active                   @ 08024E64
    strb r0, [r1, #0x0]                     @ 08024E66  rel_active = 0
    movs r0, #0x0                           @ 08024E68
    ldr.w r1, =peak_hold                    @ 08024E6A
    strb r0, [r1, #0x0]                     @ 08024E6C  peak_hold = 0
    movs r0, #0x0                           @ 08024E6E
    ldr.w r1, =filter_1khz                  @ 08024E70
    strb r0, [r1, #0x0]                     @ 08024E72  filter_1khz = 0
    movs r0, #0x0                           @ 08024E74
    ldr.w r1, =set_diode_15v                @ 08024E76
    strb r0, [r1, #0x0]                     @ 08024E78  set_diode_15v = 0
    movs r0, #0x0                           @ 08024E7A
    ldr.w r1, =v_200080B1                   @ 08024E7C
    strb r0, [r1, #0x0]                     @ 08024E7E  v_200080B1 = 0
    movs r0, #0x0                           @ 08024E80
    ldr.w r1, =v_200080B2                   @ 08024E82
    strb r0, [r1, #0x0]                     @ 08024E84  v_200080B2 = 0
    movs r0, #0x0                           @ 08024E86
    ldr.w r1, =acdc_active                  @ 08024E88
    strb r0, [r1, #0x0]                     @ 08024E8A  acdc_active = 0
    movs r0, #0x0                           @ 08024E8C
    ldr.w r1, =va_channel                   @ 08024E8E
    strb r0, [r1, #0x0]                     @ 08024E90  va_channel = 0
    movs r0, #0x0                           @ 08024E92
    ldr.w r1, =v_200080C5                   @ 08024E94
    strb r0, [r1, #0x0]                     @ 08024E96  v_200080C5 = 0
    movs r0, #0x0                           @ 08024E98
    ldr.w r1, =v_20008065                   @ 08024E9A
    strb r0, [r1, #0x0]                     @ 08024E9C  v_20008065 = 0
    movs r0, #0x0                           @ 08024E9E
    ldr.w r1, =v_20008066                   @ 08024EA0
    strb r0, [r1, #0x0]                     @ 08024EA2  v_20008066 = 0
    ldr.w r0, =v_20008038                   @ 08024EA4
    ldrb r0, [r0, #0x0]                     @ 08024EA6  r0 = v_20008038
    cmp r0, #0x0                            @ 08024EA8  compare v_20008038 with 0
    beq .L08024EB8                          @ 08024EAA  if v_20008038 == 0
    movs r0, #0x33                          @ 08024EAC
    ldr.w r1, =v_20008072                   @ 08024EAE
    strb r0, [r1, #0x0]                     @ 08024EB0  v_20008072 = 51 (0x33)
    movs r0, #0xa                           @ 08024EB2
    ldr.w r1, =v_20008073                   @ 08024EB4
    strb r0, [r1, #0x0]                     @ 08024EB6  v_20008073 = 10 (0xA)
.L08024EB8:  @ reached from 08024EAA beq (v_20008038 == 0)
    movs r0, #0x0                           @ 08024EB8
    ldr.w r1, =set_key_remote_req           @ 08024EBA
    strb r0, [r1, #0x0]                     @ 08024EBC  set_key_remote_req = 0
    movs r0, #0x0                           @ 08024EBE
    ldr.w r1, =set_key_remote_code          @ 08024EC0
    strb r0, [r1, #0x0]                     @ 08024EC2  set_key_remote_code = 0
    bl fn_0801B77A                          @ 08024EC4  apply the LCD contrast setting [r0=0, r1=&set_key_remote_code]
    pop {r0, pc}                            @ 08024EC8
ENDFUNC fn_08024DE0
    .ltorg
    .global set_state_reset
    .thumb_set set_state_reset, fn_08024DE0
