@ =============================================================================
@ dbm.s - SET: selectable dBm reference of the ACV page 11 (production image only, DESIGN.md 10 IMP-08, FEATURES.md 2.2)
@
@ SET module, part 6.  v2.05 shows on ACV setup page 11 the value 10 log10(x^2 / 0.6) (dBm into 600 ohm, mac_dbm
@ 0x0800A74C, constant 0.6 at 0x0800A7C6..0x0800A7CA) and refuses the edit there.  The port makes the page editable in the
@ style of v2.05's APO and buzzer pages (FUN_08015A22): long SETUP starts the edit (the reference text blinks), REL steps
@ up, PEAK steps down, long SETUP again saves, SETUP short ends the edit without a save, the edit times out after about
@ 2 minutes.  As on those pages the step takes effect at once in RAM; only the save writes the EEPROM.
@
@ Reference code (EEPROM 0x011, EEPROM_MAP.md 4.1), divisor of x^2 = 1 mW times the load:
@     0   600 ohm   0.6     "r 600"   (v2.05: the same double, 0x3FE3333333333333; also the value of an erased or
@                                       unknown byte)
@     1    50 ohm   0.05    "r  50"
@     2    75 ohm   0.075   "r  75"
@     3   dBV       1.0     "r dbV"   (20 log10(x / 1 V) = 10 log10(x^2 / 1.0); V is drawn as U by the font)
@ The units of the page (FUN_0801A440, 0x0801A546..0x0801A564): dB and m for codes 0..2, dB alone for code 3.
@ Characters (font of analysis/lcd_map.md 2): 'r' = 0x24 (e g), 'd' = 0xB5, 'b' = 0xBC, 'V' = 0xB9 (as U).
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


    .equ SET_DBM_EEPROM,      0x011         @ EEPROM offset of the reference code (EEPROM_MAP.md 4.1)
    .equ SET_DBM_CODE_MAX,    3             @ highest valid code = dBV
    .equ set_dbm_text5,       v_20007C30    @ 5-character text buffer drawn on the sub display (as set_text5 in setup.s)
    .equ set_dbm_redraw,      v_20008062    @ sub display redraw request
    .equ set_dbm_commit_req,  v_2000805B    @ LCD commit request

    .section .bss_port.set, "aw", %nobits
@ set_dbm_ref: dBm reference code 0..3, loaded from EEPROM 0x011 at boot and wake, edited on ACV page 11 (owner SET)
    .global set_dbm_ref
set_dbm_ref:    .space 1

    .section .rodata.set.dbm, "a", %progbits
    .align 3
@ set_dbm_divisor: the divisor of x^2 per reference code, IEEE 754 double, little-endian words (low word first, as the
@ register pair r2:r3 of the runtime divide fn_0801B874)
    .global set_dbm_divisor
set_dbm_divisor:
    .word 0x33333333, 0x3FE33333            @ 0: 0.6   (600 ohm; the v2.05 constant, 0x0800A7C6..0x0800A7CA)
    .word 0x9999999A, 0x3FA99999            @ 1: 0.05  (50 ohm)
    .word 0x33333333, 0x3FB33333            @ 2: 0.075 (75 ohm)
    .word 0x00000000, 0x3FF00000            @ 3: 1.0   (dBV)
    .size set_dbm_divisor, . - set_dbm_divisor

@ set_dbm_texts: the page text per code during the edit, five characters each
set_dbm_texts:
    .ascii "r 600"
    .ascii "r  50"
    .ascii "r  75"
    .ascii "r dbV"
    .size set_dbm_texts, . - set_dbm_texts

    .section .text.set.dbm, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_dbm_load - load the dBm reference from the EEPROM
@ Replaces : nothing in v2.05 (new: EEPROM 0x011 is not accessed by v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset, at boot and after a STOP wake)
@ RAM      : writes set_dbm_ref
@ Spec     : EEPROM_MAP.md 4.1 (a value above 3, 0xFF included, reads as 0 = 600 ohm; the byte is left as found)
@ -----------------------------------------------------------------------------
FUNC set_dbm_load
    push {r4, lr}
    movs r0, #SET_DBM_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x011 (cache or EEPROM, NVM reader)
    cmp r0, #SET_DBM_CODE_MAX
    bls 1f                                  @ 0..3: valid
    movs r0, #0                             @ anything else: 600 ohm, the v2.05 reference
1:  ldr r1, =set_dbm_ref
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_dbm_load

@ -----------------------------------------------------------------------------
@ set_dbm_edit - edit action of the ACV page 11 (dBm reference)
@ Replaces : nothing in v2.05 (new; model: FUN_08015A22, the APO page)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads and writes set_dbm_ref; writes set_dbm_redraw
@ Spec     : EEPROM_MAP.md 4.1, 9.2
@ Note     : up: 600, 50, 75, dBV, then 600 again; down in the reverse order.  The new code is used by the next dBm value
@            (mac_dbm).  Save writes EEPROM 0x011 through set_nvm_store (NVM_ARM SETTINGS and nvm_write_setting; NVM
@            rejects any offset outside the class, and skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_dbm_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =set_dbm_ref
    ldrb r0, [r1]                           @ r0 = code
    cmp r4, #1
    beq .Lde_up
    cmp r4, #2
    beq .Lde_down
@ save (100): EEPROM 0x011 = code
    mov r1, r0                              @ value
    movs r0, #SET_DBM_EEPROM                @ offset
    movs r2, #1                             @ width: one byte
    bl set_nvm_store                        @ SETTINGS class, armed inside
    b .Lde_redraw
.Lde_up:
    adds r0, r0, #1
    cmp r0, #SET_DBM_CODE_MAX
    bls 1f
    movs r0, #0                             @ past dBV: 600 ohm
    b 1f
.Lde_down:
    subs r0, r0, #1
    bpl 1f
    movs r0, #SET_DBM_CODE_MAX              @ below 600 ohm: dBV
1:  strb r0, [r1]
.Lde_redraw:
    movs r0, #1
    ldr r1, =set_dbm_redraw
    strb r0, [r1]                           @ redraw the page
    pop {r4, pc}
ENDFUNC set_dbm_edit

@ -----------------------------------------------------------------------------
@ set_dbm_draw - draw the reference text of the ACV page 11 while its edit is active (blink phase on)
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it instead of fn_08018590 while set_edit is set)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads set_dbm_ref; writes lcd_shadow (sub minus off, sub decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_dbm_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off (the bit fn_08018590 sets for a negative value)
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r0, =set_dbm_ref
    ldrb r0, [r0]
    and r0, r0, #SET_DBM_CODE_MAX           @ 0..3 (the code is kept in range; the mask keeps the index in the table)
    add r0, r0, r0, lsl #2                  @ code * 5
    ldr r1, =set_dbm_texts
    add r1, r1, r0                          @ r1 = text of the code
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_dbm_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_dbm_draw

    .ltorg

