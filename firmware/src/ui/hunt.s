@ =============================================================================
@ hunt.s - UI: the value of the SETUP page HUnt on the main display (production image only, DESIGN.md 10 IMP-45,
@ FEATURES.md 2.19)
@
@ The page HUnt (setup item 41, CAP only, set/relp.s) switches the capacitance anti-hunting rule (mres/antihunt.s).  Its
@ name needs four of the five characters of the sub display, so the sub display shows "HUnt " (set_hunt_draw) and, as the
@ pages Sd, tHI and tLo do with their values, the main display shows the value: "   on" or "  oFF".  While the page is
@ selected fn_08016E08 calls ui_hunt_draw in place of the reading draw (before its blank rule: the CAP range jumps of a
@ hunting capacitor would otherwise blank the digits that the page shows); ui_relpct_mask applies no REL percent view
@ to it.  The unit signs of the range stay as the reading has them.  The BLE value 0x20007D70 is not changed.
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


    .equ UI_HUNT_ITEM,        41            @ setup item of the page HUnt (set/setup.s SET_ITEM_HUNT)
    .equ ui_hunt_item,        v_20008037    @ setup item (set_item)
    .equ ui_hunt_ol,          v_20008046    @ overload flag
    .equ ui_hunt_commit_req,  v_2000805B    @ LCD commit request

    .section .rodata.ui.hunt, "a", %progbits
ui_hunt_texts:
    .ascii "  oFF"                          @ value 0
    .ascii "   on"                          @ value 1
    .size ui_hunt_texts, . - ui_hunt_texts

    .section .text.ui.hunt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ui_hunt_view - is the value of the page HUnt shown on the main display?
@ Replaces : nothing in v2.05 (new)
@ In       : -
@ Out      : r0 = 1 while the page HUnt (item 41) is selected, else 0
@ Clobbers : r1, flags
@ Context  : main only (fn_08016E08, ui_relpct_mask)
@ RAM      : reads set_item (0x20008037)
@ -----------------------------------------------------------------------------
FUNC ui_hunt_view
    ldr r0, =ui_hunt_item
    ldrb r0, [r0]
    cmp r0, #UI_HUNT_ITEM
    ite eq
    moveq r0, #1
    movne r0, #0
    bx lr
ENDFUNC ui_hunt_view

@ -----------------------------------------------------------------------------
@ ui_hunt_draw - draw "   on" or "  oFF" on the main display
@ Replaces : nothing in v2.05 (new; takes the place of the reading draw of fn_08016E08 while ui_hunt_view = 1)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main only (fn_08016E08)
@ RAM      : reads set_hunt_on; writes lcd_shadow (main decimal point and minus sign off, five characters), the overload flag
@            0x20008046 (cleared, as the blank and "OFL" paths of fn_08016E08 do), the commit request
@ -----------------------------------------------------------------------------
FUNC ui_hunt_draw
    push {r4, lr}
    bl ui_stats_text_prep                   @ main decimal point and minus sign off
    ldr r0, =set_hunt_on
    ldrb r0, [r0]
    and r0, r0, #1
    add r0, r0, r0, lsl #2                  @ value * 5
    ldr r1, =ui_hunt_texts
    add r1, r1, r0
    movs r0, #0                             @ main display
    bl lcd_draw_5char
    movs r0, #0
    ldr r1, =ui_hunt_ol
    strb r0, [r1]                           @ no overload text under the page
    movs r0, #1
    ldr r1, =ui_hunt_commit_req
    strb r0, [r1]                           @ commit the shadow
    pop {r4, pc}
ENDFUNC ui_hunt_draw

    .ltorg
