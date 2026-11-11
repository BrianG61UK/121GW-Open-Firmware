@ =============================================================================
@ bat.s - SET: SETUP page bAt, the battery type (production image only, DESIGN.md 10 IMP-67, FEATURES.md 2.40)
@
@ SET module.  The page bAt (item 47, right after the battery page 1 in the meter walk, GitHub issue 36) chooses the type of
@ the cells for the low-battery warning: alkaline (default, the limit of v2.05, 4.1 V) or NiMH (limit 4.7 V, owner
@ decision 2026-11-10; the limit below which EEPROM writes are refused stays 4.1 V for both types, pwr/battery.s).
@ The page uses the sub display only (like bt and dSP): "bAtAL" for alkaline, "bAtnH" for NiMH (the font has no M).  Long
@ SETUP starts the edit (the sub display blinks), REL or PEAK switches, long SETUP again saves, SETUP short leaves without
@ a save (the saved type acts again at the next battery reading, set_bat_type); an edit that times out re-reads the EEPROM
@ (fn_0800D190).
@ Storage: EEPROM 0x023 (EEPROM_MAP.md 4.1), 0 = alkaline, 1 = NiMH; any other value (an erased 0xFF included) reads as
@ alkaline and the byte is left as found.  The type in effect is chosen by set_bat_type for pwr/battery.s (the warning
@ limit); the byte is written only here.
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

    .equ SET_BAT_EEPROM,      0x023         @ EEPROM offset of the battery type (EEPROM_MAP.md 4.1)
    .equ SET_BAT_ITEM,        47            @ the page bAt (set/setup.s SET_ITEM_BATT)
    .equ set_bat_redraw,      v_20008062    @ sub display redraw request
    .equ set_bat_commit_req,  v_2000805B    @ LCD commit request
    .equ set_bat_item,        v_20008037    @ set_item
    .equ set_bat_edit_on,     v_2000806E    @ set_edit

    .section .bss_port.set, "aw", %nobits
@ set_bat_nimh: battery type, 0 = alkaline (default), 1 = NiMH (owner SET; the page's value: the type being edited while
@ the page is in edit mode, else the saved type, which set_bat_type copies here; read by the page, ble/bftset.s)
@ set_bat_saved: the type in the EEPROM (set by set_bat_load and by the save), the one in effect outside an edit
    .global set_bat_nimh, set_bat_saved
set_bat_nimh:   .space 1
set_bat_saved:  .space 1

    .section .rodata.set.bat, "a", %progbits
@ set_bat_texts: the page text per type, five characters each
set_bat_texts:
    .ascii "bAtAL"
    .ascii "bAtnH"
    .size set_bat_texts, . - set_bat_texts

    .section .text.set.bat, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_bat_load - the battery type from EEPROM 0x023
@ Replaces : nothing in v2.05 (new: EEPROM 0x023 is not accessed by v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake, before the first battery reading; fn_0800D190
@            when an edit of the page times out)
@ RAM      : writes set_bat_nimh, set_bat_saved
@ Spec     : EEPROM_MAP.md 4.1 (a value above 1, 0xFF included, reads as 0 = alkaline; the byte is left as found)
@ -----------------------------------------------------------------------------
FUNC set_bat_load
    push {r4, lr}
    movs r0, #SET_BAT_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x023 (cache or EEPROM, NVM reader)
    cmp r0, #1
    it hi
    movhi r0, #0                            @ not 0 or 1 (an erased 0xFF included): alkaline, the byte is left as found
    ldr r1, =set_bat_nimh
    strb r0, [r1]
    ldr r1, =set_bat_saved
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_bat_load

@ -----------------------------------------------------------------------------
@ set_bat_type - the battery type in effect
@ Replaces : nothing in v2.05 (new, IMP-67)
@ In       : -
@ Out      : r0 = 0 alkaline, 1 NiMH: set_bat_nimh while the page bAt is being edited (so an edit acts at once), else
@            set_bat_saved, which is also copied to set_bat_nimh (an edit left without a save, by SETUP short, the dial
@            or a mode change, stops acting at the next reading, and the next edit starts from the saved type)
@ Clobbers : r1, r2, flags
@ Context  : main only (adc_ch5_process)
@ RAM      : reads set_edit, set_item, set_bat_nimh, set_bat_saved; writes set_bat_nimh
@ Note     : as pwr_bat_trim does for the battery trim.
@ -----------------------------------------------------------------------------
FUNC set_bat_type
    ldr r1, =set_bat_nimh
    ldr r2, =set_bat_edit_on
    ldrb r2, [r2]
    cbz r2, 1f                              @ no edit
    ldr r2, =set_bat_item
    ldrb r2, [r2]
    cmp r2, #SET_BAT_ITEM
    bne 1f                                  @ an edit of another page
    ldrb r0, [r1]                           @ the page bAt being edited: the edit value
    bx lr
1:  ldr r2, =set_bat_saved
    ldrb r0, [r2]                           @ otherwise the saved type ...
    strb r0, [r1]                           @ ... which is also the start value of the next edit
    bx lr
ENDFUNC set_bat_type

@ -----------------------------------------------------------------------------
@ set_bat_edit - edit action of the page bAt (setup item 47)
@ Replaces : nothing in v2.05 (new; model: set_chirp_edit, a two-value toggle)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4; bftset.s with action 100 after a Bluetooth PUT)
@ RAM      : reads and writes set_bat_nimh; the save writes set_bat_saved; writes the sub display redraw request
@ Note     : up and down both switch between alkaline and NiMH; save writes EEPROM 0x023 through set_nvm_store (class
@            SETTINGS; NVM skips a byte that does not change) and makes the type the saved one.  The type acts at the next
@            battery reading (pwr/battery.s, every 200 ms).
@ -----------------------------------------------------------------------------
FUNC set_bat_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =set_bat_nimh
    ldrb r0, [r1]
    cmp r4, #100
    beq .Lbe_save
    eor r0, r0, #1                          @ up or down: the other type
    strb r0, [r1]
    b .Lbe_redraw
.Lbe_save:
    mov r4, r0                              @ r4 = the type to save
    mov r1, r0                              @ value
    movs r0, #SET_BAT_EEPROM
    movs r2, #1                             @ one byte
    bl set_nvm_store                        @ r0 = status
    cbnz r0, .Lbe_redraw                    @ refused (battery under 4.1 V) or failed: the saved type stays the EEPROM's
    ldr r2, =set_bat_saved
    strb r4, [r2]                           @ written: the saved type is the new one
.Lbe_redraw:
    movs r0, #1
    ldr r1, =set_bat_redraw
    strb r0, [r1]                           @ redraw the sub display
    pop {r4, pc}
ENDFUNC set_bat_edit

@ -----------------------------------------------------------------------------
@ set_bat_draw - draw the page bAt: "bAtAL" or "bAtnH" on the sub display
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 47)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads set_bat_nimh; writes lcd_shadow (sub minus and decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_bat_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r0, =set_bat_nimh
    ldrb r0, [r0]
    and r0, r0, #1                          @ 0 or 1 (the type is kept in range; the mask keeps the index in the table)
    add r0, r0, r0, lsl #2                  @ type * 5
    ldr r1, =set_bat_texts
    add r1, r1, r0                          @ r1 = text of the type
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_bat_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_bat_draw

    .ltorg
