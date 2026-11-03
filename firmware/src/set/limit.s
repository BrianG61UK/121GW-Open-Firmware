@ =============================================================================
@ limit.s - SET: limit test (pass / fail) with the SETUP pages Lt, Lo, HI and the verdict page (production image only,
@ DESIGN.md 10 IMP-20, FEATURES.md 2.1)
@
@ Pages (SETUP short after CL: Lt -> Lo -> HI -> verdict (while the test is on) -> the statistics (while MIN/MAX is on) ->
@ item 0):
@   item 27  Lt       "LtOn " / "LtOFF".  Long SETUP starts the edit, REL or PEAK switches the test, long SETUP ends the edit
@                     (and shows the verdict page when the test is on).  Switching on is refused (refusal beep) unless both
@                     limits were captured in the present mode and range; Lo above HI is swapped first.
@   item 28  Lo       the low limit, item 29 HI the high limit: "Lo---" / "HI---" before a capture; after it the label
@                     ("Lo   " / "HI   ") and the value (digits and decimal point of the range it was captured in) alternate
@                     with the 500 ms phase 0x20008077.  Long SETUP starts the edit, REL or PEAK captures the displayed
@                     value 0x20007D64, long SETUP ends the edit.  A capture in another mode or range than the other limit
@                     binds both limits to the present one (the other must be captured again).
@   item 36  verdict  "PASS " while Lo <= D <= HI, "HI   " above, "Lo   " below (D = 0x20007D64, the value the main digits
@                     show; an overload counts by its sign 0x20008045: HI, or Lo when negative); "-----" before the first
@                     verdict.  Only while the test is on (else the dispatcher shows item 0).
@ While the test is on the range is frozen as MIN/MAX freezes it (range_manual = 1, the previous value restored at the end)
@ and RANGE short and long are refused (key/short.s, key/long.s).  The verdict is evaluated for every new displayed result
@ (lt_tick, from fn_08016E08); a change from PASS to HI / Lo gives the refusal pattern (fn_0800EE6C) and a change back to
@ PASS the accept beep (fn_0800EE50), both through the buzzer setting.  The test ends when the mode or range differs from
@ the limits' (a mode change), and at power-on and STOP wake (set_state_reset); the limits are RAM only (owner, 2026-11-02).
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

    .equ LT_ITEM_ON,          27
    .equ LT_ITEM_LO,          28
    .equ LT_ITEM_HI,          29
    .equ LT_ITEM_VERDICT,     36
    .equ LT_V_NONE,           0
    .equ LT_V_PASS,           1
    .equ LT_V_HI,             2
    .equ LT_V_LO,             3
    .equ lt_reading,          v_20007D64    @ displayed value D (counts)
    .equ lt_ol,               v_20008046    @ overload flag
    .equ lt_neg,              v_20008045    @ sign of the displayed overload (1 = negative)
    .equ lt_dp_now,           v_2000803F    @ decimal point code of the reading
    .equ lt_phase,            v_20008077    @ 500 ms phase (TIM2, always toggling)
    .equ lt_text5,            v_20007C30
    .equ lt_redraw,           v_20008062
    .equ lt_commit_req,       v_2000805B

    .section .bss_port.lt, "aw", %nobits
    .balign 4
lt_lo:          .space 4                    @ low limit (counts)
lt_hi:          .space 4                    @ high limit (counts)
    .global lt_on
lt_on:          .space 1                    @ 1 = test on
lt_valid:       .space 1                    @ bit 0 Lo captured, bit 1 HI captured (for lt_tag)
lt_tag:         .space 1                    @ mode * 8 + range + 1 of the limits, 0 = none
lt_dp:          .space 1                    @ decimal point code at the capture
    .global lt_verdict
lt_verdict:     .space 1                    @ LT_V_*
lt_range_saved: .space 1                    @ range_manual before the test
lt_show:        .space 1                    @ 1 = show the verdict page at the end of the Lt edit

    .section .rodata.set.lt, "a", %progbits
lt_texts:
    .ascii "LtOn "                          @ 0
    .ascii "LtOFF"                          @ 5
    .ascii "Lo---"                          @ 10
    .ascii "HI---"                          @ 15
    .ascii "Lo   "                          @ 20
    .ascii "HI   "                          @ 25
    .ascii "-----"                          @ 30 verdict none
    .ascii "PASS "                          @ 35
    .ascii "HI   "                          @ 40
    .ascii "Lo   "                          @ 45

    .section .text.set.lt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ lt_tag_now - tag of the present mode and range: mode * 8 + range + 1
@ Out      : r0
@ Clobbers : r1, flags
@ -----------------------------------------------------------------------------
LFUNC lt_tag_now
    ldr r0, =meter_mode
    ldrb r0, [r0]
    ldr r1, =meter_range
    ldrb r1, [r1]
    add r0, r1, r0, lsl #3
    adds r0, r0, #1
    uxtb r0, r0
    bx lr
ENDFUNC lt_tag_now

@ -----------------------------------------------------------------------------
@ lt_reset - test off, no limits (set_state_reset: power-on and STOP wake)
@ Clobbers : r0, r1
@ -----------------------------------------------------------------------------
FUNC lt_reset
    movs r0, #0
    ldr r1, =lt_on
    strb r0, [r1]
    ldr r1, =lt_valid
    strb r0, [r1]
    ldr r1, =lt_tag
    strb r0, [r1]
    ldr r1, =lt_verdict
    strb r0, [r1]
    ldr r1, =lt_show
    strb r0, [r1]
    bx lr
ENDFUNC lt_reset

@ -----------------------------------------------------------------------------
@ lt_off - end the test: range_manual restored (as the end of MIN/MAX restores it), verdict cleared
@ Clobbers : r0, r1
@ -----------------------------------------------------------------------------
LFUNC lt_off
    ldr r1, =lt_on
    ldrb r0, [r1]
    cbz r0, 1f
    movs r0, #0
    strb r0, [r1]
    ldr r1, =lt_verdict
    strb r0, [r1]
    ldr r0, =lt_range_saved
    ldrb r0, [r0]
    ldr r1, =range_manual
    strb r0, [r1]
1:  bx lr
ENDFUNC lt_off

@ -----------------------------------------------------------------------------
@ set_lt_edit - edit action of the pages Lt (27), Lo (28), HI (29)
@ In       : r0 = action: 1 up, 2 down, 100 end of the edit; r1 = item
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ -----------------------------------------------------------------------------
FUNC set_lt_edit
    push {r4-r6, lr}
    uxtb r4, r0                             @ action
    uxtb r5, r1                             @ item
    cmp r4, #100
    beq .Lle_end
    cmp r5, #LT_ITEM_ON
    beq .Lle_toggle
    @ ---- Lo / HI: capture the displayed value ----
    bl lt_tag_now
    mov r6, r0                              @ r6 = tag now
    ldr r1, =lt_tag
    ldrb r2, [r1]
    cmp r2, r6
    beq 1f
    strb r6, [r1]                           @ another mode or range: both limits bound to the present one ...
    movs r0, #0
    ldr r1, =lt_valid
    strb r0, [r1]                           @ ... the other limit must be captured again
    bl lt_off                               @ (a test bound to the old tag cannot stay on)
1:  ldr r0, =lt_reading
    ldr r0, [r0]
    cmp r5, #LT_ITEM_LO
    ite eq
    ldreq r1, =lt_lo
    ldrne r1, =lt_hi
    str r0, [r1]                            @ the captured value
    ldr r1, =lt_dp_now
    ldrb r0, [r1]
    ldr r1, =lt_dp
    strb r0, [r1]
    ldr r1, =lt_valid
    ldrb r0, [r1]
    cmp r5, #LT_ITEM_LO
    ite eq
    orreq r0, r0, #1
    orrne r0, r0, #2
    strb r0, [r1]
    b .Lle_redraw
.Lle_toggle:
    ldr r1, =lt_on
    ldrb r0, [r1]
    cbz r0, .Lle_on
    bl lt_off                               @ on -> off
    b .Lle_redraw
.Lle_on:
    ldr r0, =lt_valid
    ldrb r0, [r0]
    cmp r0, #3
    bne .Lle_refuse                         @ a limit missing
    bl lt_tag_now
    ldr r1, =lt_tag
    ldrb r1, [r1]
    cmp r0, r1
    bne .Lle_refuse                         @ limits of another mode or range
    ldr r0, =lt_lo
    ldr r1, [r0]
    ldr r2, [r0, #4]                        @ lt_hi follows lt_lo
    cmp r1, r2
    ble 2f
    str r2, [r0]                            @ Lo above HI: swapped
    str r1, [r0, #4]
2:  ldr r0, =range_manual
    ldrb r1, [r0]
    ldr r2, =lt_range_saved
    strb r1, [r2]                           @ range_manual saved ...
    movs r1, #1
    strb r1, [r0]                           @ ... and the range frozen (as MIN/MAX, fn_080158D4)
    ldr r0, =lt_on
    strb r1, [r0]
    ldr r0, =lt_verdict
    movs r1, #LT_V_NONE
    strb r1, [r0]
    ldr r0, =lt_show
    movs r1, #1
    strb r1, [r0]                           @ the verdict page at the end of the edit
    movs r0, #0
    bl fn_08019D68                          @ AUTO annunciator off (range frozen)
    b .Lle_redraw
.Lle_refuse:
    bl fn_0800EE6C                          @ refusal pattern
    b .Lle_redraw
.Lle_end:
    cmp r5, #LT_ITEM_ON
    bne .Lle_redraw
    ldr r1, =lt_show
    ldrb r0, [r1]
    cbz r0, .Lle_redraw
    movs r0, #0
    strb r0, [r1]
    ldr r1, =lt_on
    ldrb r0, [r1]
    cbz r0, .Lle_redraw
    movs r0, #LT_ITEM_VERDICT
    ldr r1, =v_20008037
    strb r0, [r1]                           @ the verdict page
.Lle_redraw:
    movs r0, #1
    ldr r1, =lt_redraw
    strb r0, [r1]
    pop {r4-r6, pc}
ENDFUNC set_lt_edit

@ -----------------------------------------------------------------------------
@ lt_tick - once per new displayed result (fn_08016E08 entry): end the test on a mode or range change, evaluate the
@ verdict with its beeps, and keep the pages Lo, HI and verdict current
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ Context  : main only
@ -----------------------------------------------------------------------------
FUNC lt_tick
    push {r4, r5, r6, lr}
    ldr r0, =v_20008037
    ldrb r0, [r0]
    sub r0, r0, #LT_ITEM_LO
    cmp r0, #1
    bhi 1f
    movs r0, #1                             @ page Lo or HI: the label / value alternation needs a redraw
    ldr r1, =lt_redraw
    strb r0, [r1]
1:  ldr r0, =lt_on
    ldrb r0, [r0]
    cbz r0, .Ltk_ret
    bl lt_tag_now
    ldr r1, =lt_tag
    ldrb r1, [r1]
    cmp r0, r1
    beq 2f
    bl lt_off                               @ the mode or range changed: the test ends
    b .Ltk_ret
2:  ldr r0, =lt_ol
    ldrb r0, [r0]
    cbz r0, 3f
    ldr r0, =lt_neg
    ldrb r0, [r0]
    cmp r0, #0
    ite eq
    moveq r4, #LT_V_HI                      @ positive overload: above the high limit
    movne r4, #LT_V_LO                      @ negative overload: below the low limit
    b 4f
3:  ldr r0, =lt_reading
    ldr r0, [r0]
    ldr r1, =lt_lo
    ldr r2, [r1]
    ldr r3, [r1, #4]
    movs r4, #LT_V_PASS
    cmp r0, r2
    it lt
    movlt r4, #LT_V_LO
    cmp r0, r3
    it gt
    movgt r4, #LT_V_HI
4:  ldr r1, =lt_verdict
    ldrb r5, [r1]                           @ r5 = previous verdict
    cmp r4, r5
    beq .Ltk_ret
    strb r4, [r1]
    bl log_trig_verdict                     @ IMP-21: a record at the change with tr-Lt
    ldr r0, =v_20008037
    ldrb r0, [r0]
    cmp r0, #LT_ITEM_VERDICT
    bne 5f
    movs r0, #1
    ldr r1, =lt_redraw
    strb r0, [r1]                           @ the verdict page shows the change
5:  cmp r5, #LT_V_NONE
    beq .Ltk_ret                            @ the first verdict: no beep
    cmp r4, #LT_V_PASS
    bne 6f
    bl fn_0800EE50                          @ back within the limits: accept beep
    b .Ltk_ret
6:  cmp r5, #LT_V_PASS
    bne .Ltk_ret                            @ HI <-> Lo: no new beep
    bl fn_0800EE6C                          @ out of the limits: refusal pattern
.Ltk_ret:
    pop {r4, r5, r6, pc}
ENDFUNC lt_tick

@ -----------------------------------------------------------------------------
@ lt_text - draw five characters of lt_texts on the sub display (sign and decimal points off)
@ In       : r0 = offset in lt_texts
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC lt_text
    push {r4, lr}
    mov r4, r0
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    str r1, [r0, #0x10]
    movs r0, #0
    bl fn_08017FB4                          @ sub decimal points off
    ldr r1, =lt_texts
    add r1, r1, r4
    movs r0, #1
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =lt_commit_req
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC lt_text

@ -----------------------------------------------------------------------------
@ set_lt_draw - draw the page Lt (27), Lo (28), HI (29) or verdict (36)
@ In       : r0 = item
@ Out      : r0 = 1 drawn, 0 = the verdict page without a test (the caller shows item 0)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ -----------------------------------------------------------------------------
FUNC set_lt_draw
    push {r4, lr}
    mov r4, r0
    cmp r4, #LT_ITEM_ON
    bne 1f
    ldr r0, =lt_on
    ldrb r0, [r0]
    cmp r0, #0
    ite ne
    movne r0, #0                            @ "LtOn "
    moveq r0, #5                            @ "LtOFF"
    bl lt_text
    b .Lld_done
1:  cmp r4, #LT_ITEM_VERDICT
    bne 2f
    ldr r0, =lt_on
    ldrb r0, [r0]
    cbz r0, .Lld_none                       @ no test: not drawn
    ldr r0, =lt_verdict
    ldrb r0, [r0]
    add r0, r0, r0, lsl #2                  @ verdict * 5
    adds r0, r0, #30
    bl lt_text
    b .Lld_done
2:  @ ---- Lo / HI ----
    ldr r0, =lt_valid
    ldrb r0, [r0]
    cmp r4, #LT_ITEM_LO
    ite eq
    andeq r0, r0, #1
    andne r0, r0, #2
    cbnz r0, 3f
    cmp r4, #LT_ITEM_LO
    ite eq
    moveq r0, #10                           @ "Lo---"
    movne r0, #15                           @ "HI---"
    bl lt_text
    b .Lld_done
3:  ldr r0, =lt_phase
    ldrb r0, [r0]
    cbnz r0, 4f
    cmp r4, #LT_ITEM_LO
    ite eq
    moveq r0, #20                           @ "Lo   "
    movne r0, #25                           @ "HI   "
    bl lt_text
    b .Lld_done
4:  cmp r4, #LT_ITEM_LO
    ite eq
    ldreq r0, =lt_lo
    ldrne r0, =lt_hi
    ldr r0, [r0]                            @ the limit (counts)
    ldr r1, =lt_dp
    ldrb r1, [r1]                           @ its decimal point code
    movs r2, #0                             @ deferred commit
    bl lcd_show_value_pos0_4
.Lld_done:
    movs r0, #1
    pop {r4, pc}
.Lld_none:
    movs r0, #0
    pop {r4, pc}
ENDFUNC set_lt_draw

    .ltorg

    .endif
