@ =============================================================================
@ dsp.s - SET: SETUP page dSP, the display response level (production image only, DESIGN.md 10 IMP-12, FEATURES.md 2.4)
@
@ SET module, part 10.  A setup page in the style of the page rEL (relp.s), item 24, the last port page in every mode:
@ long SETUP starts the edit (the value blinks), REL or PEAK switches between the two levels, long SETUP again saves,
@ SETUP short ends the edit without a save, the edit times out after about 2 minutes (fn_0800D190 then re-reads the
@ EEPROM through set_dsp_load).
@
@ Level (EEPROM 0x013, EEPROM_MAP.md 4.1): 0 = level 1 (v2.05 smoothing, default; also the value of an erased or unknown
@ byte), 1 = level 2 (a quarter of every smoothing depth, func/smooth.s).  The mean lengths, the update rate of the digits,
@ auto-ranging and the HY3131 settings are not changed by the level.
@
@ Page text (five characters, font of analysis/lcd_map.md 2: 'd' 0xB5, 'S' 0x9E (the shape of 5), 'P'):
@     "dSP 1"   "dSP 2"
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


    .equ SET_DSP_EEPROM,      0x013         @ EEPROM offset of the level (EEPROM_MAP.md 4.1)
    .equ set_dsp_redraw,      v_20008062    @ sub display redraw request
    .equ set_dsp_commit_req,  v_2000805B    @ LCD commit request

    .section .bss_port.set, "aw", %nobits
@ func_dsp_level: display level, 0 = level 1 (v2.05), 1 = level 2 (owner SET; read by func_avg_core and func_hist_core)
    .global func_dsp_level
func_dsp_level: .space 1

    .section .rodata.set.dsp, "a", %progbits
set_dsp_texts:
    .ascii "dSP 1"
    .ascii "dSP 2"
    .size set_dsp_texts, . - set_dsp_texts

    .section .text.set.dsp, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_dsp_load - load the display level from the EEPROM
@ Replaces : nothing in v2.05 (new: EEPROM 0x013 is not accessed by v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ RAM      : writes func_dsp_level
@ Spec     : EEPROM_MAP.md 4.1 (a value above 1, 0xFF included, reads as 0 = level 1; the byte is left as found)
@ -----------------------------------------------------------------------------
FUNC set_dsp_load
    push {r4, lr}
    movs r0, #SET_DSP_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x013 (cache or EEPROM, NVM reader)
    cmp r0, #1
    bls 1f                                  @ 0 or 1: valid
    movs r0, #0                             @ anything else: level 1
1:  ldr r1, =func_dsp_level
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_dsp_load

@ -----------------------------------------------------------------------------
@ set_dsp_edit - edit action of the page dSP (setup item 24)
@ Replaces : nothing in v2.05 (new; model: FUN_08015A22, the APO page, a two-value toggle)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads and writes func_dsp_level; writes set_dsp_redraw
@ Note     : up and down both switch the level; the next smoothed value uses it.  Save writes EEPROM 0x013 through
@            set_nvm_store (NVM_ARM SETTINGS and nvm_write_setting; NVM skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_dsp_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =func_dsp_level
    ldrb r0, [r1]
    cmp r4, #100
    beq .Lde_save
    eor r0, r0, #1                          @ up or down: the other level
    strb r0, [r1]
    b .Lde_redraw
.Lde_save:
    mov r1, r0                              @ value
    movs r0, #SET_DSP_EEPROM                @ offset
    movs r2, #1                             @ width: one byte
    bl set_nvm_store                        @ SETTINGS class, armed inside
.Lde_redraw:
    movs r0, #1
    ldr r1, =set_dsp_redraw
    strb r0, [r1]                           @ redraw the page
    pop {r4, pc}
ENDFUNC set_dsp_edit

@ -----------------------------------------------------------------------------
@ set_dsp_draw - draw the page dSP
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 24)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads func_dsp_level; writes lcd_shadow (sub minus and decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_dsp_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r0, =func_dsp_level
    ldrb r0, [r0]
    and r0, r0, #1
    add r0, r0, r0, lsl #2                  @ level * 5
    ldr r1, =set_dsp_texts
    add r1, r1, r0
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_dsp_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_dsp_draw

    .ltorg

