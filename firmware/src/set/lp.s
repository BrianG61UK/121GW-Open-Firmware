@ =============================================================================
@ lp.s - SET: SETUP page LP, the current-loop percent view of DCmA (production image only, DESIGN.md 10 IMP-24,
@ FEATURES.md 2.14)
@
@ The page LP (setup item 37, offered in DCmA only, after dSP) selects how DCmA is shown:
@     code  text     main display
@     0     "LPOFF"  the current, as v2.05 (default)
@     1     "L4-20"  percent of a 4..20 mA loop: (I - 4 mA) / 16 mA x 100 %
@     2     "L0-20"  percent of a 0..20 mA loop: I / 20 mA x 100 %
@ (ui/loop.s draws the view.)  Long SETUP starts the edit (the value blinks), REL steps up, PEAK steps down, long SETUP
@ again saves, SETUP short ends the edit without a save, the edit times out after about 2 minutes (fn_0800D190 then
@ re-reads the EEPROM).  Storage: EEPROM 0x028 (EEPROM_MAP.md 4.1); a value above 2, 0xFF included, reads as 0.
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


    .equ SET_LP_EEPROM,       0x028         @ EEPROM offset of the loop code (EEPROM_MAP.md 4.1)
    .equ SET_LP_CODE_MAX,     2
    .equ set_lp_redraw,       v_20008062    @ sub display redraw request
    .equ set_lp_commit_req,   v_2000805B    @ LCD commit request

    .section .bss_port.set, "aw", %nobits
@ set_lp_code: 0 off, 1 4..20 mA, 2 0..20 mA (owner SET; read by ui_loop_view / ui_loop_draw)
    .global set_lp_code
set_lp_code:    .space 1

    .section .rodata.set.lp, "a", %progbits
set_lp_texts:
    .ascii "LPOFF"
    .ascii "L4-20"
    .ascii "L0-20"
    .size set_lp_texts, . - set_lp_texts

    .section .text.set.lp, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_lp_load - load the loop code from the EEPROM
@ Replaces : nothing in v2.05 (new: EEPROM 0x028 is not accessed by v2.05)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ -----------------------------------------------------------------------------
FUNC set_lp_load
    push {r4, lr}
    movs r0, #SET_LP_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x028 (cache or EEPROM, NVM reader)
    cmp r0, #SET_LP_CODE_MAX
    bls 1f
    movs r0, #0                             @ anything else: off
1:  ldr r1, =set_lp_code
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_lp_load

@ -----------------------------------------------------------------------------
@ set_lp_edit - edit action of the page LP (setup item 37)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ Note     : up: off, 4..20, 0..20, then off again; down in the reverse order; the main display follows at once.  Save
@            writes EEPROM 0x028 through set_nvm_store (NVM skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_lp_edit
    push {r4, lr}
    uxtb r4, r0
    ldr r1, =set_lp_code
    ldrb r0, [r1]
    cmp r4, #1
    beq .Lle_up
    cmp r4, #2
    beq .Lle_down
    mov r1, r0                              @ save (100): EEPROM 0x028 = code
    movs r0, #SET_LP_EEPROM
    movs r2, #1
    bl set_nvm_store
    b .Lle_redraw
.Lle_up:
    adds r0, r0, #1
    cmp r0, #SET_LP_CODE_MAX
    bls 1f
    movs r0, #0
    b 1f
.Lle_down:
    subs r0, r0, #1
    bpl 1f
    movs r0, #SET_LP_CODE_MAX
1:  strb r0, [r1]
.Lle_redraw:
    movs r0, #1
    ldr r1, =set_lp_redraw
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_lp_edit

@ -----------------------------------------------------------------------------
@ set_lp_draw - draw the page LP
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads set_lp_code; writes lcd_shadow (sub minus and decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_lp_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    str r1, [r0, #0x10]
    movs r0, #0
    bl fn_08017FB4                          @ sub decimal points off
    ldr r0, =set_lp_code
    ldrb r0, [r0]
    cmp r0, #SET_LP_CODE_MAX
    bls 1f
    movs r0, #0
1:  add r0, r0, r0, lsl #2                  @ code * 5
    ldr r1, =set_lp_texts
    add r1, r1, r0
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_lp_commit_req
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_lp_draw

    .ltorg

