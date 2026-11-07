@ =============================================================================
@ settings.s - SET: settings in the data EEPROM
@
@ SET module, part 1: settings loaders and savers, the setup edit timeout and the default setup item.
@
@ Replaces the v2.05 routines 0x08011218..0x08011438, 0x0800D190 and 0x0800D718.  Loaders read the data EEPROM
@ through the NVM readers (eeprom_read_u8 / eeprom_read_u16_be) with the v2.05 validation and defaults
@ (EEPROM_MAP.md 4, 6); savers write only through set_nvm_store (NVM class SETTINGS), never directly.
@ Deviations: OF-38/NF-17 (contrast 10 and 11 accepted, switch SET_ACCEPT_CONTRAST_10_11), OF-23 (0x012 not
@ written), IMP-05 (continuity code 0..15).  Context: main only unless stated.
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
    .equ set_id,                v_20007D14   @ serial/ID number, u32, EEPROM 0x003..0x006 (< 100000)
    .equ set_id_edit,           v_20007D18   @ ID number edit buffer, u32
    .equ set_item,              v_20008037   @ setup item shown on the secondary display (0..12, 100 = MEM view)
    .equ set_apo_disable,       v_20008039   @ auto-power-off disable, 0 = APO on, EEPROM 0x016
    .equ set_redraw,            v_20008062   @ secondary display redraw request
    .equ set_edit,              v_2000806E   @ setup edit mode active (toggled by long SETUP)
    .equ set_edit_timer,        v_20008070   @ edit timeout tick counter (0xF1 ticks, FUN_0800D190)
    .equ set_buzzer_on,         v_20008078   @ buzzer enable, EEPROM 0x01E
    .equ set_date_edit_en,      v_2000808B   @ SETUP pressed in the power-on window: date-code editing enabled
    .equ set_va_bd,             v_200080A8   @ VA burden option "bd", EEPROM 0x01B
    .equ set_item_timer,        v_200080AA   @ set to 100 by FUN_08015410 on entering item 12 and by FUN_0800D718; cleared by the display code; meaning UNPROVEN
    .equ set_temp_celsius,      v_200080AB   @ temperature unit, 1 = degC, 0 = degF, EEPROM 0x010
    .equ set_diode_15v,         v_200080B3   @ DIODE source 0 = 3 V, 1 = 15 V (EEPROM 0x012 read at boot, forced 0, OF-23)
    .equ set_cont_code,         v_200080B6   @ continuity threshold code, EEPROM 0x014 (v2.05 0..3, port 0..15, IMP-05)
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

    .section .text.set, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_nvm_store - store a setting byte or halfword through the NVM SETTINGS class
@ Replaces : the calls of eeprom_write_u8 0x080120D0 / eeprom_write_u16_be 0x080120A8 made by the SET routines
@ In       : r0 = EEPROM offset, r1 = value, r2 = width (1 or 2)
@ Out      : r0 = NVM status (0 written and verified or unchanged, 1 refused, 2 failed); v2.05 callers ignore it
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main only
@ Spec     : DESIGN.md 6.21, Appendix C.2; EEPROM_MAP.md 7.1, 9.2 (class SETTINGS: 0x008..0x00E, 0x010, 0x014, 0x016,
@            0x018..0x01A, 0x01B, 0x01E)
@ Note     : nvm_arm is called here, immediately before the writer; NVM re-checks every byte against its allowed
@            table and refuses (status 1) anything else, so a wrong offset can never reach another EEPROM byte.
@ -----------------------------------------------------------------------------
FUNC set_nvm_store
    push {r4-r6, lr}
    mov r4, r0                              @ offset
    mov r5, r1                              @ value
    mov r6, r2                              @ width
    ldr r0, =NVM_KEY_SETTINGS               @ class key (config.inc)
    bl nvm_arm                              @ arm one SETTINGS write (clobbers r0, r1)
    mov r0, r4
    mov r1, r5
    mov r2, r6
    bl nvm_write_setting                    @ r0 = status
    pop {r4-r6, pc}
ENDFUNC set_nvm_store
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011218 - load the logging interval from the EEPROM
@ Replaces : 0x08011218 FUN_08011218 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_log_interval
@ Spec     : EEPROM_MAP.md 4: EEPROM u16 BE at 0x018; a value below 1000 is kept, otherwise 1 (EEPROM_MAP.md 4)
@ -----------------------------------------------------------------------------
FUNC fn_08011218
    push {r4, lr}                           @ 08011218
    movs r0, #0x18                          @ 0801121A
    bl eeprom_read_u16_be                   @ 0801121C  read EEPROM u16 (big endian) at offset r0 [r0=24 (0x18)]
    movs r4, r0                             @ 08011220
    uxth r4, r4                             @ 08011222
    cmp r4, #0x3e8                          @ 08011224  compare r4 with 1000 (0x3E8)
    bge .L08011230                          @ 08011228  if r4 >=s 1000 (0x3E8)
    ldr.w r0, =set_log_interval             @ 0801122A
    strh r4, [r0, #0x0]                     @ 0801122C  set_log_interval = r4
    b .L08011236                            @ 0801122E
.L08011230:  @ reached from 08011228 bge (r4 >=s 1000 (0x3E8))
    movs r0, #0x1                           @ 08011230
    ldr.w r1, =set_log_interval             @ 08011232
    strh r0, [r1, #0x0]                     @ 08011234  set_log_interval = 1
.L08011236:  @ reached from 0801122E b
    pop {r4, pc}                            @ 08011236
ENDFUNC fn_08011218
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011248 - save the logging interval to the EEPROM
@ Replaces : 0x08011248 FUN_08011248 (v2.05)
@ In       : r0 = interval 0..999
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : EEPROM_MAP.md 4: EEPROM u16 BE at 0x018, class SETTINGS (EEPROM_MAP.md 7.1)
@ -----------------------------------------------------------------------------
FUNC fn_08011248
    push {r4, lr}                           @ 08011248
    movs r4, r0                             @ 0801124A
    movs r1, r4                             @ 0801124C
    uxth r1, r1                             @ 0801124E
    movs r0, #0x18                          @ 08011250
    movs r2, #2                          @ width 2 bytes, big endian @ 08011252
    bl set_nvm_store                        @           [r0=24 (0x18)]
    pop {r4, pc}                            @ 08011256
ENDFUNC fn_08011248
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011258 - load the LCD contrast from the EEPROM
@ Replaces : 0x08011258 FUN_08011258 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes lcd_contrast
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x01A; kept if in range, otherwise 14 (EEPROM_MAP.md 4)
@ Deviation: OF-38/NF-17 / Q11: with SET_ACCEPT_CONTRAST_10_11 = 1 (default) the accepted range is 10..17, i.e. what
@            the setup editor offers and saves; v2.05 accepts 12..17 only (0x08011264), so a saved 10 or 11 became 14
@            after power-up
@ -----------------------------------------------------------------------------
FUNC fn_08011258
    push {r4, lr}                           @ 08011258
    movs r0, #0x1a                          @ 0801125A
    bl eeprom_read_u8                       @ 0801125C  read EEPROM byte at offset r0 [r0=26 (0x1A)]
    movs r4, r0                             @ 08011260
    uxtb r4, r4                             @ 08011262
    .if SET_ACCEPT_CONTRAST_10_11           @ 08011264
        cmp r4, #10                      @ OF-38/NF-17 / Q11: 10 and 11 are accepted too @         
    .else                                   @         
        cmp r4, #12                      @ v2.05 0x08011264 @         
    .endif                                  @           compare r4 with 10 (0xA)
    blt .L08011276                          @ 08011266  if r4 <s 10 (0xA)
    uxtb r4, r4                             @ 08011268
    cmp r4, #0x12                           @ 0801126A  compare r4 with 18 (0x12)
    bge .L08011276                          @ 0801126C  if r4 >=s 18 (0x12)
    ldr.w r0, =lcd_contrast                 @ 0801126E
    strb r4, [r0, #0x0]                     @ 08011272  lcd_contrast = r4
    b .L0801127E                            @ 08011274
.L08011276:  @ reached from 08011266 blt (r4 <s 10 (0xA)), 0801126C bge (r4 >=s 18 (0x12))
    movs r0, #0xe                           @ 08011276
    ldr.w r1, =lcd_contrast                 @ 08011278
    strb r0, [r1, #0x0]                     @ 0801127C  lcd_contrast = 14 (0xE)
.L0801127E:  @ reached from 08011274 b
    pop {r4, pc}                            @ 0801127E
ENDFUNC fn_08011258
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011294 - save the LCD contrast to the EEPROM
@ Replaces : 0x08011294 FUN_08011294 (v2.05)
@ In       : r0 = contrast 10..17
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x01A, class SETTINGS
@ -----------------------------------------------------------------------------
FUNC fn_08011294
    push {r4, lr}                           @ 08011294
    movs r4, r0                             @ 08011296
    movs r1, r4                             @ 08011298
    uxtb r1, r1                             @ 0801129A
    movs r0, #0x1a                          @ 0801129C
    movs r2, #1                          @ width 1 byte @ 0801129E
    bl set_nvm_store                        @           [r0=26 (0x1A)]
    pop {r4, pc}                            @ 080112A2
ENDFUNC fn_08011294
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080112A4 - load the auto-power-off disable flag from the EEPROM
@ Replaces : 0x080112A4 FUN_080112A4 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_apo_disable
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x016: 1 gives 1 (APO off), anything else 0 (EEPROM_MAP.md 4)
@ -----------------------------------------------------------------------------
FUNC fn_080112A4
    push {r4, lr}                           @ 080112A4
    movs r0, #0x16                          @ 080112A6
    bl eeprom_read_u8                       @ 080112A8  read EEPROM byte at offset r0 [r0=22 (0x16)]
    movs r4, r0                             @ 080112AC
    uxtb r4, r4                             @ 080112AE
    cmp r4, #0x2                            @ 080112B0  compare r4 with 2
    bge .L080112CE                          @ 080112B2  if r4 >=s 2
    uxtb r4, r4                             @ 080112B4
    cmp r4, #0x0                            @ 080112B6  compare r4 with 0
    beq .L080112C4                          @ 080112B8  if r4 == 0
    movs r0, #0x1                           @ 080112BA
    ldr.w r1, =set_apo_disable              @ 080112BC
    strb r0, [r1, #0x0]                     @ 080112C0  set_apo_disable = 1
    b .L080112D6                            @ 080112C2
.L080112C4:  @ reached from 080112B8 beq (r4 == 0)
    movs r0, #0x0                           @ 080112C4
    ldr.w r1, =set_apo_disable              @ 080112C6
    strb r0, [r1, #0x0]                     @ 080112CA  set_apo_disable = 0
    b .L080112D6                            @ 080112CC
.L080112CE:  @ reached from 080112B2 bge (r4 >=s 2)
    movs r0, #0x0                           @ 080112CE
    ldr.w r1, =set_apo_disable              @ 080112D0
    strb r0, [r1, #0x0]                     @ 080112D4  set_apo_disable = 0
.L080112D6:  @ reached from 080112C2 b, 080112CC b
    pop {r4, pc}                            @ 080112D6
ENDFUNC fn_080112A4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080112EC - save the auto-power-off disable flag to the EEPROM
@ Replaces : 0x080112EC FUN_080112EC (v2.05)
@ In       : r0 = 0 or 1
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x016, class SETTINGS
@ -----------------------------------------------------------------------------
FUNC fn_080112EC
    push {r4, lr}                           @ 080112EC
    movs r4, r0                             @ 080112EE
    movs r1, r4                             @ 080112F0
    uxtb r1, r1                             @ 080112F2
    movs r0, #0x16                          @ 080112F4
    movs r2, #1                          @ width 1 byte @ 080112F6
    bl set_nvm_store                        @           [r0=22 (0x16)]
    pop {r4, pc}                            @ 080112FA
ENDFUNC fn_080112EC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080112FC - load the temperature unit from the EEPROM
@ Replaces : 0x080112FC FUN_080112FC (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_temp_celsius
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x010: a value below 2 is kept (1 degC, 0 degF), otherwise 0
@ -----------------------------------------------------------------------------
FUNC fn_080112FC
    push {r4, lr}                           @ 080112FC
    movs r0, #0x10                          @ 080112FE
    bl eeprom_read_u8                       @ 08011300  read EEPROM byte at offset r0 [r0=16 (0x10)]
    movs r4, r0                             @ 08011304
    uxtb r4, r4                             @ 08011306
    cmp r4, #0x2                            @ 08011308  compare r4 with 2
    bge .L08011314                          @ 0801130A  if r4 >=s 2
    ldr.w r0, =set_temp_celsius             @ 0801130C
    strb r4, [r0, #0x0]                     @ 08011310  set_temp_celsius = r4
    b .L0801131C                            @ 08011312
.L08011314:  @ reached from 0801130A bge (r4 >=s 2)
    movs r0, #0x0                           @ 08011314
    ldr.w r1, =set_temp_celsius             @ 08011316
    strb r0, [r1, #0x0]                     @ 0801131A  set_temp_celsius = 0
.L0801131C:  @ reached from 08011312 b
    pop {r4, pc}                            @ 0801131C
ENDFUNC fn_080112FC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011330 - save the temperature unit to the EEPROM
@ Replaces : 0x08011330 FUN_08011330 (v2.05)
@ In       : r0 = 0 or 1
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x010, class SETTINGS
@ -----------------------------------------------------------------------------
FUNC fn_08011330
    push {r4, lr}                           @ 08011330
    movs r4, r0                             @ 08011332
    movs r1, r4                             @ 08011334
    uxtb r1, r1                             @ 08011336
    movs r0, #0x10                          @ 08011338
    movs r2, #1                          @ width 1 byte @ 0801133A
    bl set_nvm_store                        @           [r0=16 (0x10)]
    pop {r4, pc}                            @ 0801133E
ENDFUNC fn_08011330
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011340 - load the DIODE 15 V flag from the EEPROM
@ Replaces : 0x08011340 FUN_08011340 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_diode_15v
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x012: 0 and 1 kept, otherwise 0 (EEPROM_MAP.md 4); set_state_reset then forces
@            the flag to 0 (v2.05 0x08024E76), so the value read has no effect
@ Deviation: OF-23 / Q6: the flag is never written back; this loader is kept as in v2.05
@ -----------------------------------------------------------------------------
FUNC fn_08011340
    push {r4, lr}                           @ 08011340
    movs r0, #0x12                          @ 08011342
    bl eeprom_read_u8                       @ 08011344  read EEPROM byte at offset r0 [r0=18 (0x12)]
    movs r4, r0                             @ 08011348
    uxtb r4, r4                             @ 0801134A
    cmp r4, #0x2                            @ 0801134C  compare r4 with 2
    bge .L0801136A                          @ 0801134E  if r4 >=s 2
    uxtb r4, r4                             @ 08011350
    cmp r4, #0x0                            @ 08011352  compare r4 with 0
    beq .L08011360                          @ 08011354  if r4 == 0
    movs r0, #0x1                           @ 08011356
    ldr.w r1, =set_diode_15v                @ 08011358
    strb r0, [r1, #0x0]                     @ 0801135C  set_diode_15v = 1
    b .L08011372                            @ 0801135E
.L08011360:  @ reached from 08011354 beq (r4 == 0)
    movs r0, #0x0                           @ 08011360
    ldr.w r1, =set_diode_15v                @ 08011362
    strb r0, [r1, #0x0]                     @ 08011366  set_diode_15v = 0
    b .L08011372                            @ 08011368
.L0801136A:  @ reached from 0801134E bge (r4 >=s 2)
    movs r0, #0x0                           @ 0801136A
    ldr.w r1, =set_diode_15v                @ 0801136C
    strb r0, [r1, #0x0]                     @ 08011370  set_diode_15v = 0
.L08011372:  @ reached from 0801135E b, 08011368 b
    pop {r4, pc}                            @ 08011372
ENDFUNC fn_08011340
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011394 - load the continuity threshold code from the EEPROM
@ Replaces : 0x08011394 FUN_08011394 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_cont_code
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x014 (analysis/autorange_and_scheduler.md 9)
@ Deviation: IMP-05: codes 0..15 are kept (v2.05: 0..3, 0x080113A0 cmp #4); any other value gives 0 (DN 30)
@ -----------------------------------------------------------------------------
FUNC fn_08011394
    push {r4, lr}                           @ 08011394
    movs r0, #0x14                          @ 08011396
    bl eeprom_read_u8                       @ 08011398  read EEPROM byte at offset r0 [r0=20 (0x14)]
    movs r4, r0                             @ 0801139C
    uxtb r4, r4                             @ 0801139E
        cmp r4, #16                          @ IMP-05: codes 0..15 (v2.05 0x080113A0: cmp r4, #4) @ 080113A0  compare r4 with 16 (0x10)
    bge .L080113AC                          @ 080113A2  if r4 >=s 16 (0x10)
    ldr.w r0, =set_cont_code                @ 080113A4
    strb r4, [r0, #0x0]                     @ 080113A8  set_cont_code = r4
    b .L080113B4                            @ 080113AA
.L080113AC:  @ reached from 080113A2 bge (r4 >=s 16 (0x10))
    movs r0, #0x0                           @ 080113AC
    ldr.w r1, =set_cont_code                @ 080113AE
    strb r0, [r1, #0x0]                     @ 080113B2  set_cont_code = 0
.L080113B4:  @ reached from 080113AA b
    pop {r4, pc}                            @ 080113B4
ENDFUNC fn_08011394
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080113CC - save the continuity threshold code to the EEPROM
@ Replaces : 0x080113CC FUN_080113CC (v2.05)
@ In       : r0 = code 0..15
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x014, class SETTINGS (the only writer of that byte, as v2.05)
@ Deviation: IMP-05: the byte now holds 0..15
@ -----------------------------------------------------------------------------
FUNC fn_080113CC
    push {r4, lr}                           @ 080113CC
    movs r4, r0                             @ 080113CE
    movs r1, r4                             @ 080113D0
    uxtb r1, r1                             @ 080113D2
    movs r0, #0x14                          @ 080113D4
    movs r2, #1                          @ width 1 byte @ 080113D6
    bl set_nvm_store                        @           [r0=20 (0x14)]
    pop {r4, pc}                            @ 080113DA
ENDFUNC fn_080113CC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080113DC - load the VA "bd" option from the EEPROM
@ Replaces : 0x080113DC FUN_080113DC (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_va_bd
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x01B: 1 gives 1, anything else 0
@ -----------------------------------------------------------------------------
FUNC fn_080113DC
    push {r4, lr}                           @ 080113DC
    movs r0, #0x1b                          @ 080113DE
    bl eeprom_read_u8                       @ 080113E0  read EEPROM byte at offset r0 [r0=27 (0x1B)]
    movs r4, r0                             @ 080113E4
    uxtb r4, r4                             @ 080113E6
    cmp r4, #0x1                            @ 080113E8  compare r4 with 1
    bne .L080113F6                          @ 080113EA  if r4 != 1
    movs r0, #0x1                           @ 080113EC
    ldr.w r1, =set_va_bd                    @ 080113EE
    strb r0, [r1, #0x0]                     @ 080113F2  set_va_bd = 1
    b .L080113FE                            @ 080113F4
.L080113F6:  @ reached from 080113EA bne (r4 != 1)
    movs r0, #0x0                           @ 080113F6
    ldr.w r1, =set_va_bd                    @ 080113F8
    strb r0, [r1, #0x0]                     @ 080113FC  set_va_bd = 0
.L080113FE:  @ reached from 080113F4 b
    pop {r4, pc}                            @ 080113FE
ENDFUNC fn_080113DC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011400 - save the VA "bd" option to the EEPROM
@ Replaces : 0x08011400 FUN_08011400 (v2.05)
@ In       : r0 = 0 or 1
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x01B, class SETTINGS
@ -----------------------------------------------------------------------------
FUNC fn_08011400
    push {r4, lr}                           @ 08011400
    movs r4, r0                             @ 08011402
    movs r1, r4                             @ 08011404
    uxtb r1, r1                             @ 08011406
    movs r0, #0x1b                          @ 08011408
    movs r2, #1                          @ width 1 byte @ 0801140A
    bl set_nvm_store                        @           [r0=27 (0x1B)]
    pop {r4, pc}                            @ 0801140E
ENDFUNC fn_08011400
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011410 - load the buzzer enable from the EEPROM
@ Replaces : 0x08011410 FUN_08011410 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : writes set_buzzer_on
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x01E: 1 gives 1, anything else 0
@ -----------------------------------------------------------------------------
FUNC fn_08011410
    push {r4, lr}                           @ 08011410
    movs r0, #0x1e                          @ 08011412
    bl eeprom_read_u8                       @ 08011414  read EEPROM byte at offset r0 [r0=30 (0x1E)]
    movs r4, r0                             @ 08011418
    uxtb r4, r4                             @ 0801141A
    cmp r4, #0x1                            @ 0801141C  compare r4 with 1
    bne .L0801142A                          @ 0801141E  if r4 != 1
    movs r0, #0x1                           @ 08011420
    ldr.w r1, =set_buzzer_on                @ 08011422
    strb r0, [r1, #0x0]                     @ 08011426  set_buzzer_on = 1
    b .L08011432                            @ 08011428
.L0801142A:  @ reached from 0801141E bne (r4 != 1)
    movs r0, #0x0                           @ 0801142A
    ldr.w r1, =set_buzzer_on                @ 0801142C
    strb r0, [r1, #0x0]                     @ 08011430  set_buzzer_on = 0
.L08011432:  @ reached from 08011428 b
    pop {r4, pc}                            @ 08011432
ENDFUNC fn_08011410
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011438 - save the buzzer enable to the EEPROM
@ Replaces : 0x08011438 FUN_08011438 (v2.05)
@ In       : r0 = 0 or 1
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : EEPROM_MAP.md 4: EEPROM 0x01E, class SETTINGS
@ -----------------------------------------------------------------------------
FUNC fn_08011438
    push {r4, lr}                           @ 08011438
    movs r4, r0                             @ 0801143A
    movs r1, r4                             @ 0801143C
    uxtb r1, r1                             @ 0801143E
    movs r0, #0x1e                          @ 08011440
    movs r2, #1                          @ width 1 byte @ 08011442
    bl set_nvm_store                        @           [r0=30 (0x1E)]
    pop {r4, pc}                            @ 08011446
ENDFUNC fn_08011438
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011384 - save the DIODE 15 V flag (v2.05) - no longer writes
@ Replaces : 0x08011384 FUN_08011384 (v2.05)
@ In       : r0 = flag (ignored)
@ Out      : -
@ Clobbers : none
@ Context  : main only (fn_080159C8 in MRES, RANGE short in DIODE)
@ Spec     : EEPROM_MAP.md 4 (0x012), 10 (OF-23); ORIGINAL_FIRMWARE_ISSUES.md OF-23; DESIGN.md 12.2 Q6
@ Deviation: OF-23 / Q6: v2.05 wrote the flag to EEPROM 0x012 on every RANGE press in DIODE (0x0801138C..0x0801138E:
@            eeprom_write_u8(0x12, r0)), but the value is never used: set_state_reset forces the flag to 0
@            (0x08024E76) and every mode apply writes 0 (0x0800FC0A).  The 15 V choice is never applied without a
@            key press (a remembered 15 V source switched onto a circuit under test could damage it), so the
@            write only wears the EEPROM.  EEPROM byte 0x012 is left as found; it is in no NVM write class.
@ -----------------------------------------------------------------------------
FUNC fn_08011384
    bx lr                                   @ nothing to store (OF-23)
ENDFUNC fn_08011384


@ -----------------------------------------------------------------------------
@ fn_0800D190 - setup edit timeout: abandon an unsaved edit after 241 calls (about 2 minutes)
@ Replaces : 0x0800D190 FUN_0800D190 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (loop step 8, every 500 ms while set_edit is non-zero)
@ RAM      : reads meter_mode, set_day, set_hour, set_id, set_item, set_minute, set_month, set_year; writes
@            set_day_edit, set_edit, set_edit_timer, set_hour_edit, set_id_edit, set_minute_edit, set_month_edit,
@            set_redraw, set_stage, set_year_edit
@ Spec     : analysis/keys_setup.md 4 (SETUP menu); DESIGN.md 3.5 step 8
@ Note     : set_edit_timer is incremented on every call (one per 500 ms); above 0xF0, i.e. after 241 calls or about
@            120 s, the edit mode is switched off and the value being edited is restored from its stored source: item
@            8 (ID) from set_id, 5 (year), 6 (month, day) and 7 (hour, minute) from the live time (edit stage
@            cleared), 2, 3, 0 and, in BEEP, 10 re-read from the EEPROM (fn_080112A4, fn_08011410, fn_080112FC,
@            fn_08011394); then a redraw is requested.  Nothing is written to the EEPROM.
@ Note     : The call of fn_08011394 (item 10 in BEEP) now accepts the codes 0..15 (IMP-05).
@ Note     : Production image only: item 20 (bL, set_bl_load), 21 (bt, set_bt_load), 22 (rEL, set_relp_load), 23 (tc,
@            set_tc_load), 24 (dSP, set_dsp_load), 25 (CL, set_relp_load), 26 (bH, set_bh_load), 30 (tr, set_relp_load),
@            31 (Ch, set_ch_load), 37 (LP, set_lp_load), 38 (Pt, set_rtd_load), 41 (HUnt, set_relp_load), 1 (battery trim, set_btrim_load) and 11 of ACV (dBm reference, set_dbm_load)
@            are re-read from the EEPROM in the same way (IMP-07, IMP-09, IMP-11, IMP-10, IMP-12, IMP-13, IMP-16, IMP-21,
@            IMP-24, IMP-25, IMP-45, IMP-27, IMP-08).
@ -----------------------------------------------------------------------------
FUNC fn_0800D190
    push {r7, lr}                           @ 0800D190
    ldr.w r0, =set_edit_timer               @ 0800D192
    ldrb r0, [r0, #0x0]                     @ 0800D196  r0 = set_edit_timer
    adds r0, r0, #0x1                       @ 0800D198  r0 = set_edit_timer + 1
    ldr.w r1, =set_edit_timer               @ 0800D19A
    strb r0, [r1, #0x0]                     @ 0800D19E  set_edit_timer = (set_edit_timer + 1)
    ldr.w r0, =set_edit_timer               @ 0800D1A0
    ldrb r0, [r0, #0x0]                     @ 0800D1A4  r0 = set_edit_timer
    cmp r0, #0xf1                           @ 0800D1A6  compare set_edit_timer with 241 (0xF1)
    blt .L0800D288                          @ 0800D1A8  if set_edit_timer <s 241 (0xF1)
    movs r0, #0x0                           @ 0800D1AA
    ldr.w r1, =set_edit                     @ 0800D1AC
    strb r0, [r1, #0x0]                     @ 0800D1B0  set_edit = 0
    ldr.w r0, =set_item                     @ 0800D1B2
    ldrb r0, [r0, #0x0]                     @ 0800D1B6  r0 = set_item
    cmp r0, #0x8                            @ 0800D1B8  compare set_item with 8
    bne .L0800D1CA                          @ 0800D1BA  if set_item != 8
    ldr.w r0, =set_id                       @ 0800D1BC
    ldr r0, [r0, #0x0]                      @ 0800D1C0  r0 = set_id
    ldr.w r1, =set_id_edit                  @ 0800D1C2
    str r0, [r1, #0x0]                      @ 0800D1C6  set_id_edit = set_id
    b .L0800D280                            @ 0800D1C8
.L0800D1CA:  @ reached from 0800D1BA bne (set_item != 8)
    ldr.w r0, =set_item                     @ 0800D1CA
    ldrb r0, [r0, #0x0]                     @ 0800D1CE  r0 = set_item
    cmp r0, #0x5                            @ 0800D1D0  compare set_item with 5
    bne .L0800D1E2                          @ 0800D1D2  if set_item != 5
    ldr.w r0, =set_year                     @ 0800D1D4
    ldrb r0, [r0, #0x0]                     @ 0800D1D8  r0 = set_year
    ldr.w r1, =set_year_edit                @ 0800D1DA
    strb r0, [r1, #0x0]                     @ 0800D1DE  set_year_edit = set_year
    b .L0800D280                            @ 0800D1E0
.L0800D1E2:  @ reached from 0800D1D2 bne (set_item != 5)
    ldr.w r0, =set_item                     @ 0800D1E2
    ldrb r0, [r0, #0x0]                     @ 0800D1E6  r0 = set_item
    cmp r0, #0x6                            @ 0800D1E8  compare set_item with 6
    bne .L0800D20E                          @ 0800D1EA  if set_item != 6
    ldr.w r0, =set_month                    @ 0800D1EC
    ldrb r0, [r0, #0x0]                     @ 0800D1F0  r0 = set_month
    ldr.w r1, =set_month_edit               @ 0800D1F2
    strb r0, [r1, #0x0]                     @ 0800D1F6  set_month_edit = set_month
    ldr.w r0, =set_day                      @ 0800D1F8
    ldrb r0, [r0, #0x0]                     @ 0800D1FC  r0 = set_day
    ldr.w r1, =set_day_edit                 @ 0800D1FE
    strb r0, [r1, #0x0]                     @ 0800D202  set_day_edit = set_day
    movs r0, #0x0                           @ 0800D204
    ldr.w r1, =set_stage                    @ 0800D206
    strb r0, [r1, #0x0]                     @ 0800D20A  set_stage = 0
    b .L0800D280                            @ 0800D20C
.L0800D20E:  @ reached from 0800D1EA bne (set_item != 6)
    ldr.w r0, =set_item                     @ 0800D20E
    ldrb r0, [r0, #0x0]                     @ 0800D212  r0 = set_item
    cmp r0, #0x7                            @ 0800D214  compare set_item with 7
    bne .L0800D23A                          @ 0800D216  if set_item != 7
    ldr.w r0, =set_hour                     @ 0800D218
    ldrb r0, [r0, #0x0]                     @ 0800D21C  r0 = set_hour
    ldr.w r1, =set_hour_edit                @ 0800D21E
    strb r0, [r1, #0x0]                     @ 0800D222  set_hour_edit = set_hour
    ldr.w r0, =set_minute                   @ 0800D224
    ldrb r0, [r0, #0x0]                     @ 0800D228  r0 = set_minute
    ldr.w r1, =set_minute_edit              @ 0800D22A
    strb r0, [r1, #0x0]                     @ 0800D22E  set_minute_edit = set_minute
    movs r0, #0x0                           @ 0800D230
    ldr.w r1, =set_stage                    @ 0800D232
    strb r0, [r1, #0x0]                     @ 0800D236  set_stage = 0
    b .L0800D280                            @ 0800D238
.L0800D23A:  @ reached from 0800D216 bne (set_item != 7)
    ldr.w r0, =set_item                     @ 0800D23A
    ldrb r0, [r0, #0x0]                     @ 0800D23E  r0 = set_item
    cmp r0, #0x2                            @ 0800D240  compare set_item with 2
    bne .L0800D24A                          @ 0800D242  if set_item != 2
    bl fn_080112A4                          @ 0800D244  load the APO setting [r0=set_item]
    bl set_apot_load                        @ IMP-49: and the time
    b .L0800D280                            @ 0800D248
.L0800D24A:  @ reached from 0800D242 bne (set_item != 2)
    ldr.w r0, =set_item                     @ 0800D24A
    ldrb r0, [r0, #0x0]                     @ 0800D24E  r0 = set_item
    cmp r0, #0x3                            @ 0800D250  compare set_item with 3
    bne .L0800D25A                          @ 0800D252  if set_item != 3
    bl fn_08011410                          @ 0800D254  load the buzzer setting [r0=set_item]
    b .L0800D280                            @ 0800D258
.L0800D25A:  @ reached from 0800D252 bne (set_item != 3)
    ldr.w r0, =set_item                     @ 0800D25A
    ldrb r0, [r0, #0x0]                     @ 0800D25E  r0 = set_item
    cmp r0, #0x0                            @ 0800D260  compare set_item with 0
    bne .L0800D26A                          @ 0800D262  if set_item != 0
    bl fn_080112FC                          @ 0800D264  load the temperature unit [r0=set_item]
    b .L0800D280                            @ 0800D268
.L0800D26A:  @ reached from 0800D262 bne (set_item != 0)
    ldr.w r0, =set_item                     @ IMP-07: an unsaved edit of the page bL (item 20) is dropped: setting re-read from the EEPROM
    ldrb r0, [r0, #0x0]
    cmp r0, #20
    bne .Lto_not_bl
    bl set_bl_load
    b .L0800D280
.Lto_not_bl:
    cmp r0, #21                             @ IMP-09: the same for the page bt (item 21)
    bne .Lto_not_bt
    bl set_bt_load
    b .L0800D280
.Lto_not_bt:
    cmp r0, #23                             @ IMP-10: the same for the page tc (item 23)
    bne .Lto_not_tc
    bl set_tc_load
    b .L0800D280
.Lto_not_tc:
    cmp r0, #22                             @ IMP-11: the same for the page rEL (item 22)
    bne .Lto_not_relp
    bl set_relp_load
    b .L0800D280
.Lto_not_relp:
    cmp r0, #24                             @ IMP-12: the same for the page dSP (item 24)
    bne .Lto_not_dsp
    bl set_dsp_load
    b .L0800D280
.Lto_not_dsp:
    cmp r0, #25                             @ IMP-13: the same for the page CL (item 25; byte 0x020, as rEL)
    bne .Lto_not_clk
    bl set_relp_load
    b .L0800D280
.Lto_not_clk:
    cmp r0, #26                             @ IMP-16: the same for the page bH (item 26)
    bne .Lto_not_bh
    bl set_bh_load
    b .L0800D280
.Lto_not_bh:
    cmp r0, #37                             @ IMP-24: the same for the page LP (item 37)
    bne .Lto_not_lp
    bl set_lp_load
    b .L0800D280
.Lto_not_lp:
    cmp r0, #38                             @ IMP-25: the same for the page Pt (item 38)
    bne .Lto_not_rtd
    bl set_rtd_load
    b .L0800D280
.Lto_not_rtd:
    cmp r0, #41                             @ IMP-45: the same for the page HUnt (item 41; byte 0x020, as rEL)
    bne .Lto_not_hunt
    bl set_relp_load
    b .L0800D280
.Lto_not_hunt:
    cmp r0, #1                              @ IMP-27: the same for the battery trim (item 1)
    bne .Lto_not_btrim
    bl set_btrim_load
    b .L0800D280
.Lto_not_btrim:
    cmp r0, #30                             @ IMP-21: the same for the page tr (item 30; byte 0x020)
    bne 1f
    bl set_relp_load
    b .L0800D280
1:  cmp r0, #31                             @ IMP-21: and for the page Ch (item 31)
    bne .Lto_not_lg
    bl set_ch_load
    b .L0800D280
.Lto_not_lg:
    cmp r0, #11                             @ IMP-08: the same for the dBm reference (item 11 of ACV)
    bne .Lto_not_dbm
    ldr.w r0, =meter_mode
    ldrb r0, [r0, #0x0]
    cmp r0, #2
    bne .Lto_not_dbm
    bl set_dbm_load
    b .L0800D280
.Lto_not_dbm:
    ldr.w r0, =meter_mode                   @ 0800D26A
    ldrb r0, [r0, #0x0]                     @ 0800D26C  r0 = meter_mode
    cmp r0, #0xa                            @ 0800D26E  compare meter_mode with 10 (0xA)
    bne .L0800D280                          @ 0800D270  if meter_mode != 10 (0xA)
    ldr.w r0, =set_item                     @ 0800D272
    ldrb r0, [r0, #0x0]                     @ 0800D276  r0 = set_item
    cmp r0, #0xa                            @ 0800D278  compare set_item with 10 (0xA)
    bne .L0800D280                          @ 0800D27A  if set_item != 10 (0xA)
    bl fn_08011394                          @ 0800D27C  load the continuity threshold code [r0=set_item]
.L0800D280:  @ reached from 0800D1C8 b, 0800D1E0 b, 0800D20C b, 0800D238 b, 0800D248 b, 0800D258 b, 0800D268 b, 0800D270 bne (meter_mode != 10 (0xA)), 0800D27A bne (set_item != 10 (0xA))
    movs r0, #0x1                           @ 0800D280
    ldr.w r1, =set_redraw                   @ 0800D282
    strb r0, [r1, #0x0]                     @ 0800D286  set_redraw = 1
.L0800D288:  @ reached from 0800D1A8 blt (set_edit_timer <s 241 (0xF1))
    pop {r0, pc}                            @ 0800D288
ENDFUNC fn_0800D190
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800D718 - default setup item for the mode (called at every mode or range apply)
@ Replaces : 0x0800D718 FUN_0800D718 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : ISR-safe (byte stores only; also called by fn_080153AC from the TIM2 handler)
@ RAM      : reads acdc_active, meter_mode, set_date_edit_en; writes set_item, set_item_timer
@ Spec     : analysis/keys_setup.md 4 (SETUP menu) (reset of the item); DESIGN.md 3.4
@ Note     : Item 5 (year) when SETUP was pressed in the power-on window (set_date_edit_en); otherwise item 10 for ACV
@            (not AC+DC), ACmV, the VA modes (13, 14, 15, 22, 23, 24) and the six current modes (the six current modes
@            also set set_item_timer = 100), else item 0 (analysis/keys_setup.md 4).
@ -----------------------------------------------------------------------------
FUNC fn_0800D718
    ldr.w r0, =set_date_edit_en             @ 0800D718
    ldrb r0, [r0, #0x0]                     @ 0800D71C  r0 = set_date_edit_en
    cmp r0, #0x0                            @ 0800D71E  compare set_date_edit_en with 0
    beq .L0800D72C                          @ 0800D720  if set_date_edit_en == 0
    movs r0, #0x5                           @ 0800D722
    ldr.w r1, =set_item                     @ 0800D724
    strb r0, [r1, #0x0]                     @ 0800D728  set_item = 5
    b .L0800D7FA                            @ 0800D72A
.L0800D72C:  @ reached from 0800D720 beq (set_date_edit_en == 0)
    ldr.w r0, =meter_mode                   @ 0800D72C
    ldrb r0, [r0, #0x0]                     @ 0800D730  r0 = meter_mode
    cmp r0, #0x2                            @ 0800D732  compare meter_mode with 2
    bne .L0800D74A                          @ 0800D734  if meter_mode != 2
    ldr.w r0, =acdc_active                  @ 0800D736
    ldrb r0, [r0, #0x0]                     @ 0800D73A  r0 = acdc_active
    cmp r0, #0x0                            @ 0800D73C  compare acdc_active with 0
    bne .L0800D74A                          @ 0800D73E  if acdc_active != 0
    movs r0, #0xa                           @ 0800D740
    ldr.w r1, =set_item                     @ 0800D742
    strb r0, [r1, #0x0]                     @ 0800D746  set_item = 10 (0xA)
    b .L0800D7FA                            @ 0800D748
.L0800D74A:  @ reached from 0800D734 bne (meter_mode != 2), 0800D73E bne (acdc_active != 0)
    ldr.w r0, =meter_mode                   @ 0800D74A
    ldrb r0, [r0, #0x0]                     @ 0800D74E  r0 = meter_mode
    cmp r0, #0x4                            @ 0800D750  compare meter_mode with 4
    bne .L0800D75E                          @ 0800D752  if meter_mode != 4
    movs r0, #0xa                           @ 0800D754
    ldr.w r1, =set_item                     @ 0800D756
    strb r0, [r1, #0x0]                     @ 0800D75A  set_item = 10 (0xA)
    b .L0800D7FA                            @ 0800D75C
.L0800D75E:  @ reached from 0800D752 bne (meter_mode != 4)
    ldr.w r0, =meter_mode                   @ 0800D75E
    ldrb r0, [r0, #0x0]                     @ 0800D762  r0 = meter_mode
    cmp r0, #0xd                            @ 0800D764  compare meter_mode with 13 (0xD)
    beq .L0800D79A                          @ 0800D766  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 0800D768
    ldrb r0, [r0, #0x0]                     @ 0800D76C  r0 = meter_mode
    cmp r0, #0xe                            @ 0800D76E  compare meter_mode with 14 (0xE)
    beq .L0800D79A                          @ 0800D770  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 0800D772
    ldrb r0, [r0, #0x0]                     @ 0800D776  r0 = meter_mode
    cmp r0, #0xf                            @ 0800D778  compare meter_mode with 15 (0xF)
    beq .L0800D79A                          @ 0800D77A  if meter_mode == 15 (0xF)
    ldr.w r0, =meter_mode                   @ 0800D77C
    ldrb r0, [r0, #0x0]                     @ 0800D780  r0 = meter_mode
    cmp r0, #0x16                           @ 0800D782  compare meter_mode with 22 (0x16)
    beq .L0800D79A                          @ 0800D784  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 0800D786
    ldrb r0, [r0, #0x0]                     @ 0800D78A  r0 = meter_mode
    cmp r0, #0x17                           @ 0800D78C  compare meter_mode with 23 (0x17)
    beq .L0800D79A                          @ 0800D78E  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 0800D790
    ldrb r0, [r0, #0x0]                     @ 0800D794  r0 = meter_mode
    cmp r0, #0x18                           @ 0800D796  compare meter_mode with 24 (0x18)
    bne .L0800D7A4                          @ 0800D798  if meter_mode != 24 (0x18)
.L0800D79A:  @ reached from 0800D766 beq (meter_mode == 13 (0xD)), 0800D770 beq (meter_mode == 14 (0xE)), 0800D77A beq (meter_mode == 15 (0xF)), 0800D784 beq (meter_mode == 22 (0x16)), 0800D78E beq (meter_mode == 23 (0x17))
    movs r0, #0xa                           @ 0800D79A
    ldr.w r1, =set_item                     @ 0800D79C
    strb r0, [r1, #0x0]                     @ 0800D7A0  set_item = 10 (0xA)
    b .L0800D7FA                            @ 0800D7A2
.L0800D7A4:  @ reached from 0800D798 bne (meter_mode != 24 (0x18))
    ldr.w r0, =meter_mode                   @ 0800D7A4
    ldrb r0, [r0, #0x0]                     @ 0800D7A8  r0 = meter_mode
    cmp r0, #0x10                           @ 0800D7AA  compare meter_mode with 16 (0x10)
    beq .L0800D7E0                          @ 0800D7AC  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 0800D7AE
    ldrb r0, [r0, #0x0]                     @ 0800D7B2  r0 = meter_mode
    cmp r0, #0x12                           @ 0800D7B4  compare meter_mode with 18 (0x12)
    beq .L0800D7E0                          @ 0800D7B6  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 0800D7B8
    ldrb r0, [r0, #0x0]                     @ 0800D7BC  r0 = meter_mode
    cmp r0, #0x14                           @ 0800D7BE  compare meter_mode with 20 (0x14)
    beq .L0800D7E0                          @ 0800D7C0  if meter_mode == 20 (0x14)
    ldr.w r0, =meter_mode                   @ 0800D7C2
    ldrb r0, [r0, #0x0]                     @ 0800D7C6  r0 = meter_mode
    cmp r0, #0x11                           @ 0800D7C8  compare meter_mode with 17 (0x11)
    beq .L0800D7E0                          @ 0800D7CA  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 0800D7CC
    ldrb r0, [r0, #0x0]                     @ 0800D7D0  r0 = meter_mode
    cmp r0, #0x13                           @ 0800D7D2  compare meter_mode with 19 (0x13)
    beq .L0800D7E0                          @ 0800D7D4  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 0800D7D6
    ldrb r0, [r0, #0x0]                     @ 0800D7DA  r0 = meter_mode
    cmp r0, #0x15                           @ 0800D7DC  compare meter_mode with 21 (0x15)
    bne .L0800D7F2                          @ 0800D7DE  if meter_mode != 21 (0x15)
.L0800D7E0:  @ reached from 0800D7AC beq (meter_mode == 16 (0x10)), 0800D7B6 beq (meter_mode == 18 (0x12)), 0800D7C0 beq (meter_mode == 20 (0x14)), 0800D7CA beq (meter_mode == 17 (0x11)), 0800D7D4 beq (meter_mode == 19 (0x13))
    movs r0, #0xa                           @ 0800D7E0
    ldr.w r1, =set_item                     @ 0800D7E2
    strb r0, [r1, #0x0]                     @ 0800D7E6  set_item = 10 (0xA)
    movs r0, #0x64                          @ 0800D7E8
    ldr.w r1, =set_item_timer               @ 0800D7EA
    strb r0, [r1, #0x0]                     @ 0800D7EE  set_item_timer = 100 (0x64)
    b .L0800D7FA                            @ 0800D7F0
.L0800D7F2:  @ reached from 0800D7DE bne (meter_mode != 21 (0x15))
    movs r0, #0x0                           @ 0800D7F2
    ldr.w r1, =set_item                     @ 0800D7F4
    strb r0, [r1, #0x0]                     @ 0800D7F8  set_item = 0
.L0800D7FA:  @ reached from 0800D72A b, 0800D748 b, 0800D75C b, 0800D7A2 b, 0800D7F0 b
    bx lr                                   @ 0800D7FA
ENDFUNC fn_0800D718
    .ltorg
