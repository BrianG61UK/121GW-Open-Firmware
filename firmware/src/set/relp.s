@ =============================================================================
@ relp.s - SET: SETUP pages rEL (REL as difference or percent) and CL (12 / 24-hour clock), the owner of EEPROM byte 0x020
@ (production image only, DESIGN.md 10 IMP-11, IMP-13; FEATURES.md 2.3, 2.12)
@
@ SET module, part 9.  A setup page in the style of the page bt (bt.s), item 22, after bt in every mode: long SETUP starts
@ the edit (the value blinks), REL or PEAK switches between the two values, long SETUP again saves, SETUP short ends the
@ edit without a save, the edit times out after about 2 minutes (fn_0800D190 then re-reads the EEPROM through
@ set_relp_load).  The view itself is ui/relpct.s.
@
@ The page CL (item 25, after dSP) works the same way and selects how the time page shows the hour (rtc/datetime.s
@ fn_080188A0): 24-hour (v2.05, default) or 12-hour (1..12, leading zero blank, no AM/PM mark: the five characters are
@ all used by "HH-MM").
@
@ The page HUnt (item 41, CAP only, after dSP and before CL like bH / LP / Pt; IMP-45) switches the capacitance anti-hunting
@ rule of mres/antihunt.s.  Its name does not fit together with the value in the five characters of the sub display, so the
@ sub display shows "HUnt " and the main display shows the value, "   on" or "  oFF", as the pages Sd, tHI and tLo show their
@ values on the main display (ui/hunt.s draws it).  The page works like rEL: long SETUP starts the edit (the sub display
@ blinks), REL or PEAK switches, long SETUP again saves.
@
@ Storage: EEPROM 0x020 (EEPROM_MAP.md 4.1): bit 0 = REL view (0 difference, v2.05; 1 percent), bit 3 = clock (0 24-hour,
@ v2.05; 1 12-hour), bit 4 = anti-hunting (0 off, default; 1 on).  Bits 2..1 are assigned to the logging trigger of
@ FEATURES.md 2.6 and kept as found, like the unused bits 7..5; an erased byte (0xFF) reads as 0 for every bit (set_relp_load
@ maps the whole byte to 0 before it decodes it, so an erased byte never switches the anti-hunting on).  The pages save
@ through set_b20_store, which changes only the bits of its page.
@
@ Page text (five characters, font of analysis/lcd_map.md 2: 'r' 0x24, 'E', 'L', '-' 0x04, 'd' 0xB5, 'P', 'C'):
@     "rEL-d"   difference          "rEL-P"   percent
@     "CL 24"   24-hour             "CL 12"   12-hour
@     "HUnt "   the name of the page HUnt (sub display); main display "   on" / "  oFF" (ui/hunt.s)
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


    .equ SET_RELP_EEPROM,     0x020         @ EEPROM offset of the byte holding the REL view in bit 0 (EEPROM_MAP.md 4.1)
    .equ set_relp_redraw,     v_20008062    @ sub display redraw request
    .equ set_relp_commit_req, v_2000805B    @ LCD commit request
    .equ set_hunt_value_req,  v_2000805F    @ main display value redraw request (the page HUnt shows its value there)

    .section .bss_port.set, "aw", %nobits
@ set_relp: REL view, 0 = difference, 1 = percent (owner SET; read by ui_relpct_view)
    .global set_relp
set_relp:       .space 1
@ set_clk12: clock, 0 = 24-hour, 1 = 12-hour (owner SET; read by fn_080188A0)
    .global set_clk12
set_clk12:      .space 1
@ set_hunt_on: capacitance anti-hunting, 0 = off (default), 1 = on (owner SET; read by mres/antihunt.s, ui/hunt.s)
    .global set_hunt_on
set_hunt_on:    .space 1
@ set_relp_byte: EEPROM byte 0x020 as loaded or last saved (0xFF read as 0); set_b20_store changes only its page's bits
set_relp_byte:  .space 1

    .section .rodata.set.relp, "a", %progbits
set_relp_texts:
    .ascii "rEL-d"
    .ascii "rEL-P"
    .size set_relp_texts, . - set_relp_texts
set_clk_texts:
    .ascii "CL 24"
    .ascii "CL 12"
    .size set_clk_texts, . - set_clk_texts
set_hunt_text:
    .ascii "HUnt "                          @ the name of the page HUnt, the same for both values (the value is on the main display)
    .size set_hunt_text, . - set_hunt_text

    .section .text.set.relp, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_relp_load - load EEPROM 0x020: the REL view (bit 0), the logging trigger (bits 2..1), the clock (bit 3) and the
@                 anti-hunting setting (bit 4)
@ Replaces : nothing in v2.05 (new: EEPROM 0x020 is not accessed by v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit of rEL, CL, tr or HUnt times out)
@ RAM      : writes set_relp, set_clk12, set_hunt_on, log_trig (bits 2..1, IMP-21), set_relp_byte; ah_reset when the
@            anti-hunting setting is off
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
    ubfx r2, r0, #3, #1
    ldr r1, =set_clk12
    strb r2, [r1]                           @ bit 3: clock
    ubfx r2, r0, #4, #1                     @ bit 4: anti-hunting (r0 is the cleaned byte: an erased 0xFF is off)
    ldr r1, =set_hunt_on
    strb r2, [r1]
    cbnz r2, 2f
    bl ah_reset                             @ off: no lock and no counted timeout may remain (keeps r0, r1)
2:
    ubfx r2, r0, #1, #2                     @ bits 2..1: logging trigger (IMP-21)
    cmp r2, #2
    it hi
    movhi r2, #0                            @ 3 is not a trigger: tr-In
    ldr r1, =log_trig
    strb r2, [r1]
    and r0, r0, #1
    ldr r1, =set_relp
    strb r0, [r1]                           @ bit 0: REL view
    pop {r4, pc}
ENDFUNC set_relp_load

@ -----------------------------------------------------------------------------
@ set_b20_store - write EEPROM 0x020 with the bits of one page changed
@ Replaces : nothing in v2.05 (new)
@ In       : r0 = mask of the page's bits, r1 = their new value (inside the mask)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_relp_edit, set_clk_edit: save)
@ RAM      : reads and writes set_relp_byte
@ Note     : byte = (set_relp_byte & ~mask) | value; the RAM copy follows the stored byte.  NVM_ARM SETTINGS and
@            nvm_write_setting through set_nvm_store; NVM skips a byte that does not change.
@ -----------------------------------------------------------------------------
FUNC set_b20_store
    push {r4, lr}
    ldr r2, =set_relp_byte
    ldrb r3, [r2]
    bic r3, r3, r0
    orr r1, r3, r1
    strb r1, [r2]
    movs r0, #SET_RELP_EEPROM               @ offset
    movs r2, #1                             @ width: one byte
    bl set_nvm_store                        @ SETTINGS class, armed inside
    pop {r4, pc}
ENDFUNC set_b20_store

@ -----------------------------------------------------------------------------
@ set_relp_edit - edit action of the page rEL (setup item 22)
@ Replaces : nothing in v2.05 (new; model: FUN_08015A22, the APO page, a two-value toggle)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads and writes set_relp; reads set_relp_byte; writes set_relp_redraw
@ Note     : up and down both switch the value.  Save writes bit 0 of EEPROM 0x020 (set_b20_store).
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
    mov r1, r0                              @ bit 0 = the view
    movs r0, #1                             @ mask: bit 0
    bl set_b20_store
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

@ -----------------------------------------------------------------------------
@ set_clk_edit - edit action of the page CL (setup item 25)
@ Replaces : nothing in v2.05 (new; model: FUN_08015A22, the APO page, a two-value toggle)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads and writes set_clk12; writes set_relp_redraw
@ Note     : up and down both switch between 24-hour and 12-hour; save writes bit 3 of EEPROM 0x020 (set_b20_store).
@ -----------------------------------------------------------------------------
FUNC set_clk_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =set_clk12
    ldrb r0, [r1]
    cmp r4, #100
    beq .Lce_save
    eor r0, r0, #1                          @ up or down: the other clock
    strb r0, [r1]
    b .Lce_redraw
.Lce_save:
    lsl r1, r0, #3                          @ bit 3 = the clock
    movs r0, #8                             @ mask: bit 3
    bl set_b20_store
.Lce_redraw:
    movs r0, #1
    ldr r1, =set_relp_redraw
    strb r0, [r1]                           @ redraw the page
    pop {r4, pc}
ENDFUNC set_clk_edit

@ -----------------------------------------------------------------------------
@ set_clk_draw - draw the page CL
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 25)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads set_clk12; writes lcd_shadow (sub minus and decimal points off, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_clk_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r0, =set_clk12
    ldrb r0, [r0]
    and r0, r0, #1
    add r0, r0, r0, lsl #2                  @ value * 5
    ldr r1, =set_clk_texts
    add r1, r1, r0
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_relp_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_clk_draw

@ -----------------------------------------------------------------------------
@ set_hunt_edit - edit action of the page HUnt (setup item 41)
@ Replaces : nothing in v2.05 (new; model: set_clk_edit, a two-value toggle)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ RAM      : reads and writes set_hunt_on; writes set_relp_redraw, 0x2000805F (main display redraw), the anti-hunting state
@            (ah_reset when the value goes off)
@ Note     : up and down both switch between off and on; switching off clears the lock and the count at once; save writes
@            bit 4 of EEPROM 0x020 (set_b20_store).  The main display shows the value, so a redraw of it is requested too.
@ -----------------------------------------------------------------------------
FUNC set_hunt_edit
    push {r4, lr}
    uxtb r4, r0                             @ action
    ldr r1, =set_hunt_on
    ldrb r0, [r1]
    cmp r4, #100
    beq .Lhe_save
    eor r0, r0, #1                          @ up or down: the other value
    strb r0, [r1]
    cbnz r0, .Lhe_redraw
    bl ah_reset                             @ off: no lock and no counted timeout may remain
    b .Lhe_redraw
.Lhe_save:
    lsl r1, r0, #4                          @ bit 4 = the setting
    movs r0, #0x10                          @ mask: bit 4
    bl set_b20_store
.Lhe_redraw:
    movs r0, #1
    ldr r1, =set_relp_redraw
    strb r0, [r1]                           @ redraw the sub display
    ldr r1, =set_hunt_value_req
    strb r0, [r1]                           @ and the value on the main display
    pop {r4, pc}
ENDFUNC set_hunt_edit

@ -----------------------------------------------------------------------------
@ set_hunt_draw - draw the page HUnt: the name on the sub display (the value is drawn on the main display by ui_hunt_draw)
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 41)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : writes lcd_shadow (sub minus and decimal points off, five characters), commit request, 0x2000805F
@ Note     : requests a redraw of the main display so that the value appears when the page is entered.
@ -----------------------------------------------------------------------------
FUNC set_hunt_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r1, =set_hunt_text
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_relp_commit_req
    strb r0, [r1]                           @ commit the shadow
    ldr r1, =set_hunt_value_req
    strb r0, [r1]                           @ the main display shows the value
    pop {r4, pc}
ENDFUNC set_hunt_draw

    .ltorg

