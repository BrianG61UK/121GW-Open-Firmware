@ =============================================================================
@ menu.s - SET: the page SEt between the two SETUP walks (production image only, DESIGN.md 10 IMP-52, FEATURES.md 2.26)
@
@ SET module.  GitHub issue 24: the SETUP walk had grown to about twenty pages.  It is split in two (set/setup.s
@ fn_08015410):
@   measurement walk (SETUP short): item 0, the function's pages 10..12, rEL, tc, dSP, the function page (bH, LP, Pt,
@     HUnt, CHIrP), the limit test Lt, Lo, HI (verdict), the logging pages tr (Ch) and In (item 9), the MIN/MAX pages
@     n, Sd, tHI, tLo, then the page SEt (item 43) and item 0 again;
@   meter walk: items 1..8 (battery trim, APO, buzzer, contrast, year, month and day, hour and minute, ID), bL, bt, Ld,
@     Fr, CL, then item 0.
@ The meter walk starts with a long SETUP on the page SEt (set_menu_enter, from key/long.s) and ends with the page bAcK
@ (IMP-57, GitHub issue 31: a visible way back): SETUP there, short or long, goes to item 0, the temperature page that
@ starts the measurement walk.  It is also left with a function or range change (fn_0800D718) or at power-off; no state
@ is kept beyond set_item.  Every page edits as before.
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

    .equ SET_MENU_FIRST,      1             @ the first page of the meter walk (battery trim)
    .equ set_item,            v_20008037    @ setup item shown on the secondary display (set/setup.s)
    .equ set_edit,            v_2000806E    @ setup edit mode active (toggled by long SETUP)
    .equ set_menu_commit_req, v_2000805B    @ LCD commit request

    .section .rodata.set.menu, "a", %progbits
set_menu_text:
    .ascii "SEt  "
    .size set_menu_text, . - set_menu_text
@ IMP-57: the page bAcK (the font's lowercase b and c, uppercase A and K: lcd/font.s)
set_back_text:
    .ascii "bAcK "
    .size set_back_text, . - set_back_text

    .section .text.set.menu, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_menu_enter - a long SETUP on the page SEt: the meter walk starts at item 1
@ Replaces : nothing in v2.05 (new; key/long.s calls it in place of the edit start while set_item is SET_ITEM_SET)
@ In/Out   : - / -
@ Clobbers : r0, r1
@ Context  : main only (key/long.s, the long SETUP)
@ RAM      : writes set_item = 1, set_edit = 0 (item 1 needs no edit buffer: fn_08015410 loads the buffers of items 5..9)
@ -----------------------------------------------------------------------------
FUNC set_menu_enter
    movs r0, #SET_MENU_FIRST
    ldr r1, =set_item
    strb r0, [r1]
    movs r0, #0
    ldr r1, =set_edit
    strb r0, [r1]
    bx lr
ENDFUNC set_menu_enter

@ -----------------------------------------------------------------------------
@ set_menu_draw - draw the page SEt: "SEt" on the sub display (the main display keeps the reading)
@ Replaces : nothing in v2.05 (new; fn_0801797C calls it for item 43)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : writes lcd_shadow (sub minus and decimal points off, five characters), the commit request
@ -----------------------------------------------------------------------------
FUNC set_menu_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r1, =set_menu_text
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_menu_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_menu_draw

@ -----------------------------------------------------------------------------
@ set_back_draw - draw the page bAcK: "bAcK" on the sub display (the main display keeps the reading)
@ Replaces : nothing in v2.05 (new, IMP-57; fn_0801797C calls it for item 44)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : writes lcd_shadow (sub minus and decimal points off, five characters), the commit request
@ -----------------------------------------------------------------------------
FUNC set_back_draw
    push {r4, lr}
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0                             @ decimal point code 0: none
    bl fn_08017FB4                          @ clear the sub display decimal points
    ldr r1, =set_back_text
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_menu_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC set_back_draw

    .ltorg
