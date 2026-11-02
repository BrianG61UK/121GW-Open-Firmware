@ =============================================================================
@ relp.s - SET: SETUP page rEL, REL as difference or percent (production image only, DESIGN.md 10 IMP-11, FEATURES.md 2.3)
@
@ SET module, part 9.  A setup page in the style of the page bt (bt.s), item 22, after bt in every mode: long SETUP starts
@ the edit (the value blinks), REL or PEAK switches between the two values, long SETUP again saves, SETUP short ends the
@ edit without a save, the edit times out after about 2 minutes (fn_0800D190 then re-reads the EEPROM through
@ set_relp_load).  The view itself is ui/relpct.s.
@
@ Storage: bit 0 of EEPROM 0x020 (EEPROM_MAP.md 4.1): 0 = difference (v2.05, default), 1 = percent.  The other bits of the
@ byte are kept as found (FEATURES.md 3 assigns bits 2..1 to the logging trigger of 2.6); an erased byte (0xFF) reads as
@ 0 for every bit.
@
@ Page text (five characters, font of analysis/lcd_map.md 2: 'r' 0x24, 'E', 'L', '-' 0x04, 'd' 0xB5, 'P'):
@     "rEL-d"   difference          "rEL-P"   percent
@
@ Not present in the strict image (LOOP_V205 = 1): this file assembles to nothing there.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .if LOOP_V205 == 0

    .equ SET_RELP_EEPROM,     0x020         @ EEPROM offset of the byte holding the REL view in bit 0 (EEPROM_MAP.md 4.1)
    .equ set_relp_redraw,     v_20008062    @ sub display redraw request
    .equ set_relp_commit_req, v_2000805B    @ LCD commit request

    .section .bss_port.set, "aw", %nobits
@ set_relp: REL view, 0 = difference, 1 = percent (owner SET; read by ui_relpct_view)
    .global set_relp
set_relp:       .space 1
@ set_relp_byte: EEPROM byte 0x020 as loaded (0xFF read as 0), bits other than 0 written back unchanged by the save
set_relp_byte:  .space 1

    .section .rodata.set.relp, "a", %progbits
set_relp_texts:
    .ascii "rEL-d"
    .ascii "rEL-P"
    .size set_relp_texts, . - set_relp_texts

    .section .text.set.relp, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_relp_load - load the REL view from EEPROM 0x020 bit 0
@ Replaces : nothing in v2.05 (new: EEPROM 0x020 is not accessed by v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ RAM      : writes set_relp, set_relp_byte
@ -----------------------------------------------------------------------------
FUNC set_relp_load
    push {r4, lr}
    movs r0, #SET_RELP_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x020 (cache or EEPROM, NVM reader)
    cmp r0, #0xFF
    bne 1f
    movs r0, #0                             @ erased byte: every bit 0 (v2.05 behaviour for every feature of the byte)
1:  ldr r1, =set_relp_byte
    strb r0, [r1]
    and r0, r0, #1
    ldr r1, =set_relp
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_relp_load

@ -----------------------------------------------------------------------------
@ set_relp_edit - edit action of the page rEL (setup item 22)
@ Replaces : nothing in v2.05 (new; model: FUN_08015A22, the APO page, a two-value toggle)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads and writes set_relp; reads set_relp_byte; writes set_relp_redraw
@ Note     : up and down both switch the value.  Save writes EEPROM 0x020 = (set_relp_byte with bit 0 = set_relp) through
@            set_nvm_store (NVM_ARM SETTINGS and nvm_write_setting; NVM skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_relp_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =set_relp
    ldrb r0, [r1]
    cmp r4, #100
    beq .Lre_save
    eor r0, r0, #1                          @ up or down: the other value
    strb r0, [r1]
    b .Lre_redraw
.Lre_save:
    ldr r2, =set_relp_byte
    ldrb r1, [r2]
    bic r1, r1, #1
    orr r1, r1, r0                          @ bit 0 = the view, other bits as loaded
    strb r1, [r2]                           @ the RAM copy follows the stored byte
    movs r0, #SET_RELP_EEPROM               @ offset
    movs r2, #1                             @ width: one byte
    bl set_nvm_store                        @ SETTINGS class, armed inside
.Lre_redraw:
    movs r0, #1
    ldr r1, =set_relp_redraw
    strb r0, [r1]                           @ redraw the page
    pop {r4, pc}
ENDFUNC set_relp_edit

@ -----------------------------------------------------------------------------
@ set_relp_draw - draw the page rEL
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 22)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads set_relp; writes lcd_shadow (sub minus and decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_relp_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r0, =set_relp
    ldrb r0, [r0]
    and r0, r0, #1
    add r0, r0, r0, lsl #2                  @ value * 5
    ldr r1, =set_relp_texts
    add r1, r1, r0
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_relp_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_relp_draw

    .ltorg

    .endif
