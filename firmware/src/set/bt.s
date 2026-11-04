@ =============================================================================
@ bt.s - SET: SETUP page bt, the Bluetooth frame rate (production image only, DESIGN.md 10 IMP-09, FEATURES.md 2.5)
@
@ SET module, part 7.  A setup page in the style of v2.05's APO and buzzer pages (FUN_08015A22, FUN_08018460) and of the
@ page bL (bl.s): the page is drawn on the five characters of the sub display, long SETUP starts the edit (the value
@ blinks), REL steps up, PEAK steps down, long SETUP again saves, SETUP short ends the edit without a save, the edit
@ times out after about 2 minutes (fn_0800D190 then re-reads the EEPROM through set_bt_load).
@
@ Rate code (EEPROM 0x015, EEPROM_MAP.md 4.1): 0 = 2 frames per second (v2.05, default; also the value of an erased or
@ unknown byte), 1 = 4, 2 = 10, 3 = 20.  The frame timing is ble/rate.s.
@
@ Page text (five characters, font of analysis/lcd_map.md 2: 'b' = 0xBC, 't' = 0xAC):
@     "bt  2"   "bt  4"   "bt 10"   "bt 20"
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


    .equ SET_BT_EEPROM,       0x015         @ EEPROM offset of the rate code (EEPROM_MAP.md 4.1)
    .equ SET_BT_CODE_MAX,     3             @ highest valid code = 20 frames per second
    .equ set_bt_redraw,       v_20008062    @ sub display redraw request
    .equ set_bt_commit_req,   v_2000805B    @ LCD commit request

    .section .rodata.set.bt, "a", %progbits
@ set_bt_texts: the page text per code, five characters each
set_bt_texts:
    .ascii "bt  2"
    .ascii "bt  4"
    .ascii "bt 10"
    .ascii "bt 20"
    .size set_bt_texts, . - set_bt_texts

    .section .text.set.bt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_bt_load - load the Bluetooth frame rate from the EEPROM
@ Replaces : nothing in v2.05 (new: EEPROM 0x015 is not accessed by v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ RAM      : writes ble_rate
@ Spec     : EEPROM_MAP.md 4.1 (a value above 3, 0xFF included, reads as 0 = 2 per second; the byte is left as found)
@ -----------------------------------------------------------------------------
FUNC set_bt_load
    push {r4, lr}
    movs r0, #SET_BT_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x015 (cache or EEPROM, NVM reader)
    cmp r0, #SET_BT_CODE_MAX
    bls 1f                                  @ 0..3: valid
    movs r0, #0                             @ anything else: 2 per second, the v2.05 rate
1:  ldr r1, =ble_rate
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_bt_load

@ -----------------------------------------------------------------------------
@ set_bt_edit - edit action of the page bt (setup item 21)
@ Replaces : nothing in v2.05 (new; model: FUN_08015A22, the APO page)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads and writes ble_rate; writes set_bt_redraw
@ Spec     : EEPROM_MAP.md 4.1, 9.2
@ Note     : up: 2, 4, 10, 20, then 2 again; down in the reverse order.  The new rate applies from the next TIM2 tick
@            (ble_rate_tick, sys_tim2_isr).  Save writes EEPROM 0x015 through set_nvm_store (NVM_ARM SETTINGS and
@            nvm_write_setting; NVM rejects any offset outside the class, and skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_bt_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =ble_rate
    ldrb r0, [r1]                           @ r0 = code
    cmp r4, #1
    beq .Lte_up
    cmp r4, #2
    beq .Lte_down
@ save (100): EEPROM 0x015 = code
    mov r1, r0                              @ value
    movs r0, #SET_BT_EEPROM                 @ offset
    movs r2, #1                             @ width: one byte
    bl set_nvm_store                        @ SETTINGS class, armed inside
    b .Lte_redraw
.Lte_up:
    adds r0, r0, #1
    cmp r0, #SET_BT_CODE_MAX
    bls 1f
    movs r0, #0                             @ past 20: 2 per second
    b 1f
.Lte_down:
    subs r0, r0, #1
    bpl 1f
    movs r0, #SET_BT_CODE_MAX               @ below 2: 20 per second
1:  strb r0, [r1]                           @ one byte, read by the TIM2 interrupt
.Lte_redraw:
    movs r0, #1
    ldr r1, =set_bt_redraw
    strb r0, [r1]                           @ redraw the page
    pop {r4, pc}
ENDFUNC set_bt_edit

@ -----------------------------------------------------------------------------
@ set_bt_draw - draw the page bt
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 21)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads ble_rate; writes lcd_shadow (sub decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_bt_draw
    push {r4, lr}
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r0, =ble_rate
    ldrb r0, [r0]
    and r0, r0, #SET_BT_CODE_MAX            @ 0..3 (the code is kept in range; the mask keeps the index in the table)
    add r0, r0, r0, lsl #2                  @ code * 5
    ldr r1, =set_bt_texts
    add r1, r1, r0                          @ r1 = text of the code
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_bt_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_bt_draw

    .ltorg

