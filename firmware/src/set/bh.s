@ =============================================================================
@ bh.s - SET: SETUP page bH, the continuity beep hold time (production image only, DESIGN.md 10 IMP-16, FEATURES.md 2.13)
@
@ SET module, part 11.  v2.05 re-arms the continuity beep with pe7_on_with_timeout(100) on every reading that passes the
@ threshold (fn_080078D8, 0x08007902 and 0x08007920): the tone lasts 100 TIM3 ticks (about 100 ms) after the last
@ passing reading, so a short contact is stretched to an audible beep.  The page bH (item 26, offered in BEEP only,
@ between dSP and CL) selects that hold time:
@     code  text     TIM3 ticks (0.996 ms)
@     0     "bH100"  100     v2.05, default
@     1     "bH 50"   50
@     2     "bH 25"   25
@     3     "bHOFF"   15     the shortest hold that keeps a steady contact free of chopping: each passing reading
@                            re-arms the tone, and the re-arms of a steady 10 ohm contact come every 4.0 ms (median;
@                            3.1 .. 10.0 ms, 474 re-arms in 2 s, emulator, production image), so a hold of 10 ms or less
@                            runs out during the contact; 15 ms is the longest gap with 5 ms margin
@ Long SETUP starts the edit (the value blinks), REL steps up, PEAK steps down, long SETUP again saves, SETUP short ends
@ the edit without a save, the edit times out after about 2 minutes (fn_0800D190 then re-reads the EEPROM).
@ Storage: EEPROM 0x021 (EEPROM_MAP.md 4.1); a value above 3, 0xFF included, reads as 0 (100 ms).
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


    .equ SET_BH_EEPROM,       0x021         @ EEPROM offset of the hold code (EEPROM_MAP.md 4.1)
    .equ SET_BH_CODE_MAX,     3             @ highest valid code = off
    .equ set_bh_redraw,       v_20008062    @ sub display redraw request
    .equ set_bh_commit_req,   v_2000805B    @ LCD commit request

    .section .bss_port.set, "aw", %nobits
@ set_bh_code: continuity hold code 0..4 (owner SET; read by fn_080078D8 through set_bh_ticks)
    .global set_bh_code
set_bh_code:    .space 1

    .section .rodata.set.bh, "a", %progbits
set_bh_tick_table:
    .byte 100, 50, 25, 15                   @ TIM3 ticks per code
set_bh_texts:
    .ascii "bH100"
    .ascii "bH 50"
    .ascii "bH 25"
    .ascii "bHOFF"
    .size set_bh_texts, . - set_bh_texts

    .section .text.set.bh, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_bh_ticks - hold time of the continuity beep in TIM3 ticks
@ Out      : r0 = ticks (100 for code 0, the v2.05 value)
@ Clobbers : r1, flags
@ Context  : main only (fn_080078D8)
@ -----------------------------------------------------------------------------
FUNC set_bh_ticks
    ldr r0, =set_bh_code
    ldrb r0, [r0]
    cmp r0, #SET_BH_CODE_MAX
    bls 1f
    movs r0, #0                             @ kept in range by load and edit; the test keeps the index in the table
1:  ldr r1, =set_bh_tick_table
    ldrb r0, [r1, r0]
    bx lr
ENDFUNC set_bh_ticks

@ -----------------------------------------------------------------------------
@ set_bh_load - load the continuity hold code from the EEPROM
@ Replaces : nothing in v2.05 (new: EEPROM 0x021 is not accessed by v2.05)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ -----------------------------------------------------------------------------
FUNC set_bh_load
    push {r4, lr}
    movs r0, #SET_BH_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x021 (cache or EEPROM, NVM reader)
    cmp r0, #SET_BH_CODE_MAX
    bls 1f
    movs r0, #0                             @ anything else: 100 ms, the v2.05 hold
1:  ldr r1, =set_bh_code
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_bh_load

@ -----------------------------------------------------------------------------
@ set_bh_edit - edit action of the page bH (setup item 26)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ Note     : up: 100, 50, 25, off, then 100 again; down in the reverse order; the next passing reading uses the new
@            time.  Save writes EEPROM 0x021 through set_nvm_store (NVM skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_bh_edit
    push {r4, lr}
    uxtb r4, r0
    ldr r1, =set_bh_code
    ldrb r0, [r1]
    cmp r4, #1
    beq .Lhe_up
    cmp r4, #2
    beq .Lhe_down
    mov r1, r0                              @ save (100): EEPROM 0x021 = code
    movs r0, #SET_BH_EEPROM
    movs r2, #1
    bl set_nvm_store
    b .Lhe_redraw
.Lhe_up:
    adds r0, r0, #1
    cmp r0, #SET_BH_CODE_MAX
    bls 1f
    movs r0, #0                             @ past off: 100 ms
    b 1f
.Lhe_down:
    subs r0, r0, #1
    bpl 1f
    movs r0, #SET_BH_CODE_MAX               @ below 100 ms: off
1:  strb r0, [r1]
.Lhe_redraw:
    movs r0, #1
    ldr r1, =set_bh_redraw
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_bh_edit

@ -----------------------------------------------------------------------------
@ set_bh_draw - draw the page bH
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads set_bh_code; writes lcd_shadow (sub minus and decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_bh_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    str r1, [r0, #0x10]
    movs r0, #0
    bl fn_08017FB4                          @ sub decimal points off
    ldr r0, =set_bh_code
    ldrb r0, [r0]
    cmp r0, #SET_BH_CODE_MAX
    bls 1f
    movs r0, #0
1:  add r0, r0, r0, lsl #2                  @ code * 5
    ldr r1, =set_bh_texts
    add r1, r1, r0
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_bh_commit_req
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_bh_draw

    .ltorg

