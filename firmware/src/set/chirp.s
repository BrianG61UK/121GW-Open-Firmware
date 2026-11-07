@ =============================================================================
@ chirp.s - SET: SETUP page CHIrP, the DIODE contact chirp (production image only, DESIGN.md 10 IMP-51, FEATURES.md 2.25)
@
@ SET module.  The page CHIrP (item 42, DIODE only, after dSP and before CL like bH / LP / Pt / HUnt) chooses what the
@ double beep of DIODE reports (mres/chirp.s): off (default) v2.05's jump chirp, on the contact chirp.  Like HUnt its
@ name fills the sub display, so the sub display shows "CHIrP" and the main display the value, "   on" or "  oFF"
@ (ui/hunt.s draws it for both pages).  Long SETUP starts the edit (the sub display blinks), REL or PEAK switches,
@ long SETUP again saves, SETUP short leaves without a save; an edit that times out re-reads the EEPROM (fn_0800D190).
@ Storage: EEPROM 0x02C (EEPROM_MAP.md 4.1), 0 = off, 1 = on; any other value (an erased 0xFF included) reads as off
@ and the byte is left as found.  Idea of the contact chirp: GitHub PR 22.
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

    .equ SET_CHIRP_EEPROM,     0x02C        @ EEPROM offset (EEPROM_MAP.md 4.1)
    .equ set_chirp_redraw,     v_20008062   @ sub display redraw request
    .equ set_chirp_commit_req, v_2000805B   @ LCD commit request
    .equ set_chirp_value_req,  v_2000805F   @ main display value redraw request (the value is shown there)

    .section .bss_port.set, "aw", %nobits
@ set_chirp_on: DIODE contact chirp, 0 = off (v2.05's jump chirp, default), 1 = on (owner SET; read by mres/diode.s,
@ ui/hunt.s)
    .global set_chirp_on
set_chirp_on:   .space 1

    .section .rodata.set.chirp, "a", %progbits
set_chirp_text:
    .ascii "CHIrP"                          @ the name of the page, the same for both values (the value is on the main display)
    .size set_chirp_text, . - set_chirp_text

    .section .text.set.chirp, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_chirp_load - the DIODE chirp setting from EEPROM 0x02C
@ Replaces : nothing in v2.05 (new)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit of the page times out)
@ RAM      : writes set_chirp_on; the contact state (mres_chirp_reset)
@ -----------------------------------------------------------------------------
FUNC set_chirp_load
    push {r4, lr}
    movs r0, #SET_CHIRP_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x02C (cache or EEPROM, NVM reader)
    cmp r0, #1
    it hi
    movhi r0, #0                            @ not 0 or 1 (an erased 0xFF included): off, the byte is left as found
    ldr r1, =set_chirp_on
    strb r0, [r1]
    bl mres_chirp_reset                     @ the next confirmed contact chirps
    pop {r4, pc}
ENDFUNC set_chirp_load

@ -----------------------------------------------------------------------------
@ set_chirp_edit - edit action of the page CHIrP (setup item 42)
@ Replaces : nothing in v2.05 (new; model: set_hunt_edit, a two-value toggle)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4; bftset.s with action 100 after a Bluetooth PUT)
@ RAM      : reads and writes set_chirp_on; writes the sub and main display redraw requests, the contact state
@ Note     : up and down both switch between off and on; save writes EEPROM 0x02C through set_nvm_store (class SETTINGS).
@ -----------------------------------------------------------------------------
FUNC set_chirp_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =set_chirp_on
    ldrb r0, [r1]
    cmp r4, #100
    beq .Lce_save
    eor r0, r0, #1                          @ up or down: the other value
    strb r0, [r1]
    bl mres_chirp_reset                     @ the new behaviour starts from "no contact yet"
    b .Lce_redraw
.Lce_save:
    mov r1, r0                              @ value
    movs r0, #SET_CHIRP_EEPROM
    movs r2, #1                             @ one byte
    bl set_nvm_store
.Lce_redraw:
    movs r0, #1
    ldr r1, =set_chirp_redraw
    strb r0, [r1]                           @ redraw the sub display
    ldr r1, =set_chirp_value_req
    strb r0, [r1]                           @ and the value on the main display
    pop {r4, pc}
ENDFUNC set_chirp_edit

@ -----------------------------------------------------------------------------
@ set_chirp_draw - draw the page CHIrP: the name on the sub display (the value is drawn on the main display by ui_hunt_draw)
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 42)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : writes lcd_shadow (sub minus and decimal points off, five characters), commit request, 0x2000805F
@ -----------------------------------------------------------------------------
FUNC set_chirp_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r1, =set_chirp_text
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_chirp_commit_req
    strb r0, [r1]                           @ commit the shadow
    ldr r1, =set_chirp_value_req
    strb r0, [r1]                           @ the main display shows the value
    pop {r4, pc}
ENDFUNC set_chirp_draw

    .ltorg
