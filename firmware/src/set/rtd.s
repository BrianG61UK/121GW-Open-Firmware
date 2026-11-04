@ =============================================================================
@ rtd.s - SET: SETUP page Pt, the platinum RTD temperature view of OHM (production image only, DESIGN.md 10 IMP-25,
@ FEATURES.md 2.15)
@
@ The page Pt (setup item 38, offered in OHM only, after dSP) selects how OHM is shown:
@     code  text     main display
@     0     "PtOFF"  the resistance, as v2.05 (default)
@     1     "Pt100"  the temperature of a Pt100 sensor (R0 = 100 ohm, IEC 60751)
@     2     "P1000"  the temperature of a Pt1000 sensor (R0 = 1000 ohm, IEC 60751)
@ (ui/rtd.s draws the view.)  Long SETUP starts the edit (the value blinks), REL steps up, PEAK steps down, long SETUP
@ again saves, SETUP short ends the edit without a save, the edit times out after about 2 minutes (fn_0800D190 then
@ re-reads the EEPROM).  Storage: EEPROM 0x029 (EEPROM_MAP.md 4.1); a value above 2, 0xFF included, reads as 0.
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

    .equ SET_RTD_EEPROM,      0x029         @ EEPROM offset of the RTD code (EEPROM_MAP.md 4.1)
    .equ SET_RTD_CODE_MAX,    2
    .equ set_rtd_redraw,      v_20008062    @ sub display redraw request
    .equ set_rtd_commit_req,  v_2000805B    @ LCD commit request

    .section .bss_port.set, "aw", %nobits
@ set_rtd_code: 0 off, 1 Pt100, 2 Pt1000 (owner SET; read by ui_rtd_view / ui_rtd_draw)
    .global set_rtd_code
set_rtd_code:   .space 1

    .section .rodata.set.rtd, "a", %progbits
set_rtd_texts:
    .ascii "PtOFF"
    .ascii "Pt100"
    .ascii "P1000"
    .size set_rtd_texts, . - set_rtd_texts

    .section .text.set.rtd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_rtd_load - load the RTD code from the EEPROM
@ Replaces : nothing in v2.05 (new: EEPROM 0x029 is not accessed by v2.05)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ -----------------------------------------------------------------------------
FUNC set_rtd_load
    push {r4, lr}
    movs r0, #SET_RTD_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x029 (cache or EEPROM, NVM reader)
    cmp r0, #SET_RTD_CODE_MAX
    bls 1f
    movs r0, #0                             @ anything else: off
1:  ldr r1, =set_rtd_code
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_rtd_load

@ -----------------------------------------------------------------------------
@ set_rtd_edit - edit action of the page Pt (setup item 38)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ Note     : up: off, Pt100, Pt1000, then off again; down in the reverse order; the main display follows at once.  Save
@            writes EEPROM 0x029 through set_nvm_store (NVM skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_rtd_edit
    push {r4, lr}
    uxtb r4, r0
    ldr r1, =set_rtd_code
    ldrb r0, [r1]
    cmp r4, #1
    beq .Lre_up
    cmp r4, #2
    beq .Lre_down
    mov r1, r0                              @ save (100): EEPROM 0x029 = code
    movs r0, #SET_RTD_EEPROM
    movs r2, #1
    bl set_nvm_store
    b .Lre_redraw
.Lre_up:
    adds r0, r0, #1
    cmp r0, #SET_RTD_CODE_MAX
    bls 1f
    movs r0, #0
    b 1f
.Lre_down:
    subs r0, r0, #1
    bpl 1f
    movs r0, #SET_RTD_CODE_MAX
1:  strb r0, [r1]
.Lre_redraw:
    movs r0, #1
    ldr r1, =set_rtd_redraw
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_rtd_edit

@ -----------------------------------------------------------------------------
@ set_rtd_draw - draw the page Pt
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads set_rtd_code; writes lcd_shadow (sub minus and decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_rtd_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    str r1, [r0, #0x10]
    movs r0, #0
    bl fn_08017FB4                          @ sub decimal points off
    ldr r0, =set_rtd_code
    ldrb r0, [r0]
    cmp r0, #SET_RTD_CODE_MAX
    bls 1f
    movs r0, #0
1:  add r0, r0, r0, lsl #2                  @ code * 5
    ldr r1, =set_rtd_texts
    add r1, r1, r0
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_rtd_commit_req
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_rtd_draw

    .ltorg

    .endif
