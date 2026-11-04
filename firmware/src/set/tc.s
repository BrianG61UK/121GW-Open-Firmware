@ =============================================================================
@ tc.s - SET: SETUP page tc, the thermocouple type (production image only, DESIGN.md 10 IMP-10 and IMP-26, FEATURES.md 2.8)
@
@ SET module, part 8.  A setup page in the style of the page bt (bt.s), reached only in TEMP (mode 5): after the page bt
@ SETUP short shows tc in TEMP and item 0 in every other mode.  Long SETUP starts the edit (the value blinks), REL steps
@ up, PEAK steps down, long SETUP again saves, SETUP short ends the edit without a save, the edit times out after about
@ 2 minutes (fn_0800D190 then re-reads the EEPROM through set_tc_load).  Each step selects the type at once
@ (mtmp_tc_select), so the reading follows it.
@
@ Type code (EEPROM 0x00F, EEPROM_MAP.md 4.1): 0 = K (v2.05, default; also the value of an erased or unknown byte),
@ 1 = J, 2 = T, 3 = N, 4 = R, 5 = S (IMP-26).  The tables and input windows are mtmp/tctype.s and mtmp/tc_tables.s.
@
@ Page text (five characters, font of analysis/lcd_map.md 2: 't' 0xAC, 'c' 0xA4, '-' 0x04, 'K' 0x2D, 'J' 0xB1; N and R
@ in the lower-case forms 'n' and 'r', as 't'; 'S' looks like '5' on seven segments):
@     "tc-K "   "tc-J "   "tc-t "   "tc-n "   "tc-r "   "tc-S "
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


    .equ SET_TC_EEPROM,       0x00F         @ EEPROM offset of the type code (EEPROM_MAP.md 4.1)
    .equ SET_TC_CODE_MAX,     5             @ highest valid code = S
    .equ set_tc_redraw,       v_20008062    @ sub display redraw request
    .equ set_tc_commit_req,   v_2000805B    @ LCD commit request

    .section .rodata.set.tc, "a", %progbits
@ set_tc_texts: the page text per code, five characters each
set_tc_texts:
    .ascii "tc-K "
    .ascii "tc-J "
    .ascii "tc-t "
    .ascii "tc-n "
    .ascii "tc-r "
    .ascii "tc-S "
    .size set_tc_texts, . - set_tc_texts

    .section .text.set.tc, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_tc_load - load the thermocouple type from the EEPROM and select it
@ Replaces : nothing in v2.05 (new: EEPROM 0x00F is not accessed by v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ RAM      : writes mtmp_tc_type, mtmp_tc_descp (mtmp_tc_select)
@ Spec     : EEPROM_MAP.md 4.1 (a value above 5, 0xFF included, reads as 0 = K; the byte is left as found)
@ -----------------------------------------------------------------------------
FUNC set_tc_load
    push {r4, lr}
    movs r0, #SET_TC_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x00F (cache or EEPROM, NVM reader)
    bl mtmp_tc_select                       @ 0..5 selected, anything else selects K
    pop {r4, pc}
ENDFUNC set_tc_load

@ -----------------------------------------------------------------------------
@ set_tc_edit - edit action of the page tc (setup item 23)
@ Replaces : nothing in v2.05 (new; model: FUN_08015A22, the APO page)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads mtmp_tc_type; writes mtmp_tc_type, mtmp_tc_descp (mtmp_tc_select), set_tc_redraw
@ Spec     : EEPROM_MAP.md 4.1, 9.2
@ Note     : up: K, J, T, N, R, S, then K again; down in the reverse order.  Save writes EEPROM 0x00F through set_nvm_store (NVM_ARM
@            SETTINGS and nvm_write_setting; NVM rejects any offset outside the class, and skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_tc_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =mtmp_tc_type
    ldrb r0, [r1]                           @ r0 = code
    cmp r4, #1
    beq .Lce_up
    cmp r4, #2
    beq .Lce_down
@ save (100): EEPROM 0x00F = code
    mov r1, r0                              @ value
    movs r0, #SET_TC_EEPROM                 @ offset
    movs r2, #1                             @ width: one byte
    bl set_nvm_store                        @ SETTINGS class, armed inside
    b .Lce_redraw
.Lce_up:
    adds r0, r0, #1
    cmp r0, #SET_TC_CODE_MAX
    bls 1f
    movs r0, #0                             @ past S: K
    b 1f
.Lce_down:
    subs r0, r0, #1
    bpl 1f
    movs r0, #SET_TC_CODE_MAX               @ below K: S
1:  bl mtmp_tc_select                       @ the new type converts the next reading
.Lce_redraw:
    movs r0, #1
    ldr r1, =set_tc_redraw
    strb r0, [r1]                           @ redraw the page
    pop {r4, pc}
ENDFUNC set_tc_edit

@ -----------------------------------------------------------------------------
@ set_tc_draw - draw the page tc
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 23)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads mtmp_tc_type; writes lcd_shadow (sub minus and decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_tc_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off (the item-0 page draws a negative board temperature with it)
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r0, =mtmp_tc_type
    ldrb r0, [r0]
    cmp r0, #SET_TC_CODE_MAX
    bls 1f
    movs r0, #0                             @ kept in range by mtmp_tc_select; the test keeps the index in the table
1:  add r0, r0, r0, lsl #2                  @ code * 5
    ldr r1, =set_tc_texts
    add r1, r1, r0                          @ r1 = text of the code
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_tc_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_tc_draw

    .ltorg

