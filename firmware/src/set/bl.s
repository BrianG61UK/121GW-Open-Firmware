@ =============================================================================
@ bl.s - SET: SETUP page bL, the backlight auto-off timer setting (production image only, DESIGN.md 10 IMP-07)
@
@ SET module, part 5.  A setup page in the style of v2.05's pages APO and buzzer (FUN_08015A22, FUN_08018460): the page is
@ drawn on the five characters of the sub display, long SETUP starts the edit (the value blinks), REL steps up, PEAK steps
@ down, long SETUP again saves, SETUP short abandons the edit, the edit times out after about 2 minutes.
@
@ The setting is one code, 0..100: 0 = OFF (never switch off, the default), 1 = 30 s, 2..100 = 1..99 minutes (code - 1).
@ It is kept in EEPROM 0x017 (a byte v2.05 never accesses, EEPROM_MAP.md 4.1), written only by set_bl_edit(100) through
@ the NVM SETTINGS class, read at boot and wake by set_bl_load; a value above 100 reads as OFF (the byte is not changed).
@
@ Page text (five characters, font of analysis/lcd_map.md 2):
@     OFF      "bLOFF"
@     30 s     "bL30S"   the characters 'b' 'L' '3' '0' 'S' (the font draws S as the 7-segment S, same shape as 5)
@     1..9     "bL  1" .. "bL  9"   minutes
@     10..99   "bL 10" .. "bL 99"   minutes
@ (the value is in minutes; the five characters are b, L, a blank and the two-character field)
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


    .equ SET_BL_EEPROM,       0x017         @ EEPROM offset of the setting (EEPROM_MAP.md 4.1)
    .equ SET_BL_CODE_MAX,     100           @ highest valid code = 99 minutes
    .equ SET_BL_CODE_30S,     1             @ code of 30 s
    .equ set_bl_text5,        v_20007C30    @ 5-character text buffer drawn on the sub display (as set_text5 in setup.s)
    .equ set_bl_redraw,       v_20008062    @ sub display redraw request
    .equ set_bl_commit_req,   v_2000805B    @ LCD commit request

    .section .text.set.bl, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_bl_load - load the backlight auto-off setting from the EEPROM
@ Replaces : nothing in v2.05 (new: EEPROM 0x017 is not accessed by v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and wake, fn_0800D190 when an edit times out)
@ RAM      : writes pwr_bl_setting
@ Spec     : EEPROM_MAP.md 4.1: a value above 100 reads as 0 (OFF)
@ -----------------------------------------------------------------------------
FUNC set_bl_load
    push {r4, lr}
    movs r0, #SET_BL_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x017 (cache or EEPROM, NVM reader)
    movs r4, #0                             @ r4 = remembered backlight state (bit 7)
    cmp r0, #0xFF
    beq 2f                                  @ erased or corrupt byte: everything off
    lsrs r4, r0, #7                         @ bit 7: the backlight was on at the last MODE long press
    and r0, r0, #0x7F                       @ bits 6..0: auto-off code
    cmp r0, #SET_BL_CODE_MAX
    bls 1f                                  @ 0..100: valid
2:  movs r0, #0                             @ above 100 (or 0xFF): OFF
1:  ldr r1, =pwr_bl_setting
    strb r0, [r1]
    ldr r1, =pwr_bl_saved_on
    strb r4, [r1]
    pop {r4, pc}
ENDFUNC set_bl_load

@ -----------------------------------------------------------------------------
@ set_bl_store - write EEPROM 0x017: auto-off code in bits 6..0, remembered backlight state in bit 7
@ Replaces : nothing in v2.05 (new: EEPROM 0x017 is not accessed by v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (save of the backlight page; pwr_bl_remember after a MODE long press)
@ RAM      : reads pwr_bl_setting and pwr_bl_saved_on
@ Spec     : EEPROM_MAP.md 4.1, 9.2 (SETTINGS class through set_nvm_store; NVM skips an unchanged byte, OPT-03)
@ -----------------------------------------------------------------------------
    .global set_bl_store
FUNC set_bl_store
    push {r4, lr}
    ldr r0, =pwr_bl_setting
    ldrb r1, [r0]                           @ code 0..100
    ldr r0, =pwr_bl_saved_on
    ldrb r0, [r0]
    orr r1, r1, r0, lsl #7                  @ value = code | state << 7
    movs r0, #SET_BL_EEPROM                 @ offset 0x017
    movs r2, #1                             @ width: one byte
    bl set_nvm_store                        @ SETTINGS class, armed inside
    pop {r4, pc}
ENDFUNC set_bl_store

@ -----------------------------------------------------------------------------
@ set_bl_edit - edit action of the backlight page (setup item 20)
@ Replaces : nothing in v2.05 (new; model: FUN_08015A22, the APO page)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads and writes pwr_bl_setting; writes set_bl_redraw
@ Spec     : EEPROM_MAP.md 4.1, 9.2
@ Note     : up: OFF, 30 s, 1 min .. 99 min, then OFF again; down in the reverse order.  Each step restarts the countdown
@            from the new value (pwr_bl_restart), so a backlight that is on obeys the value at once.  Save writes EEPROM
@            0x017 through set_nvm_store (NVM_ARM SETTINGS and nvm_write_setting; NVM rejects any other offset).
@ -----------------------------------------------------------------------------
FUNC set_bl_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    cmp r4, #1
    beq .Lbe_up
    cmp r4, #2
    beq .Lbe_down
@ save (100): EEPROM 0x017 = code | remembered state << 7
    bl set_bl_store
    b .Lbe_redraw
.Lbe_up:
    ldr r1, =pwr_bl_setting
    ldrb r0, [r1]
    cmp r0, #SET_BL_CODE_MAX
    bhs 1f                                  @ 99 minutes: wrap to OFF
    adds r0, r0, #1
    b 2f
1:  movs r0, #0
2:  strb r0, [r1]
    bl pwr_bl_restart
    b .Lbe_redraw
.Lbe_down:
    ldr r1, =pwr_bl_setting
    ldrb r0, [r1]
    cbz r0, 1f                              @ OFF: wrap to 99 minutes
    subs r0, r0, #1
    b 2f
1:  movs r0, #SET_BL_CODE_MAX
2:  strb r0, [r1]
    bl pwr_bl_restart
.Lbe_redraw:
    movs r0, #1
    ldr r1, =set_bl_redraw
    strb r0, [r1]                           @ redraw the page
    pop {r4, pc}
ENDFUNC set_bl_edit

@ -----------------------------------------------------------------------------
@ set_bl_draw - draw the backlight page on the sub display
@ Replaces : nothing in v2.05 (new; model: FUN_08018460 / FUN_080184D4)
@ In       : r0 = setting code 0..100
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C, setup item 20)
@ RAM      : writes set_bl_text5, set_bl_commit_req, lcd_shadow (through fn_08017FB4 and lcd_draw_5char)
@ -----------------------------------------------------------------------------
FUNC set_bl_draw
    push {r4, r5, lr}
    mov r4, r0                              @ r4 = code
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r5, =set_bl_text5
    movs r0, #'b'
    strb r0, [r5, #0]
    movs r0, #'L'
    strb r0, [r5, #1]
    cbz r4, .Lbd_off
    cmp r4, #SET_BL_CODE_30S
    beq .Lbd_half
@ 1..99 minutes: position 2 blank, position 3 the tens (blank below 10), position 4 the units
    subs r4, r4, #1                         @ minutes
    movs r0, #0x20
    strb r0, [r5, #2]
    movs r1, #10
    udiv r2, r4, r1                         @ tens
    mls r3, r2, r1, r4                      @ units = minutes - 10 * tens
    cbz r2, 1f
    adds r2, r2, #'0'
    strb r2, [r5, #3]
    b 2f
1:  movs r0, #0x20
    strb r0, [r5, #3]                       @ no leading zero
2:  adds r3, r3, #'0'
    strb r3, [r5, #4]
    b .Lbd_draw
.Lbd_half:
    movs r0, #'3'
    strb r0, [r5, #2]
    movs r0, #'0'
    strb r0, [r5, #3]
    movs r0, #'S'
    strb r0, [r5, #4]                       @ "30S": 30 seconds (font 'S' = 0x9E, the 7-segment S, owner)
    b .Lbd_draw
.Lbd_off:
    movs r0, #'O'
    strb r0, [r5, #2]
    movs r0, #'F'
    strb r0, [r5, #3]
    strb r0, [r5, #4]
.Lbd_draw:
    movs r0, #1                             @ sub display
    mov r1, r5
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_bl_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, r5, pc}
ENDFUNC set_bl_draw

    .ltorg

