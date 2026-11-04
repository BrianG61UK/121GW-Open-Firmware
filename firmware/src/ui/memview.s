@ =============================================================================
@ memview.s - UI: MEM-view drawing and annunciator redraws (DESIGN.md 6.8)
@
@ Replaces fn_080170AC (one recalled record), fn_080171FA (decimal point for the live range), fn_08017222 (full live
@ annunciator redraw), fn_0801725E (status-icon redraw), fn_0801772E (annunciator redraw for the recalled record) and
@ fn_0801776E (unit prefix redraw).  The instruction streams are v2.05's.
@ Context: main only.
@
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.ui.memview, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_080170AC - show one recalled (MEM view) record
@ Replaces : 0x080170AC FUN_080170AC (v2.05, 84 bytes)
@ In       : r0 = record number (low 16 bits)
@ Out      : -
@ Context  : main only; called by the key handler (handle_pg8_15_short_press)
@ RAM      : reads 0x20007D1C (recalled value, 0x7FFFFFFF = overload), 0x20007FEB, 0x20007FED; writes the display through
@            lcd_show_value_pos0_4; calls fn_08010C8C and fn_08010F02 (LOG)
@ Spec     : analysis/lcd_map.md 4 (recalled copies 0x20007FE5..0x20007FED)
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080170AC
    @ sub display shows the record number (decimal point 0, deferred commit)
    push {r4, r5, r6, lr}                    @ 080170AC
    movs r4, r0                              @ 080170AE
    movs r2, #0                              @ 080170B0
    movs r1, #0                              @ 080170B2
    uxth r4, r4                              @ 080170B4
    movs r0, r4                              @ 080170B6
    bl lcd_show_value_pos0_4                 @ 080170B8
    @ r6 = fn_08010C8C(record); fn_08010F02(r6 - 1) (both LOG); the recalled value 0x20007D1C is read afterwards
    movs r0, r4                              @ 080170BC
    uxth r0, r0                              @ 080170BE
    bl fn_08010C8C                           @ 080170C0
    movs r6, r0                              @ 080170C4
    subs r0, r6, #1                          @ 080170C6
    uxth r0, r0                              @ 080170C8
    bl fn_08010F02                           @ 080170CA
    @ r5 = recalled value; 0x7FFFFFFF means overload: draw " OFL " (fn_080199B4(0)), otherwise draw the value with the recalled decimal point (0x20007FED) and mode (0x20007FEB)
    ldr r0, =v_20007D1C                      @ 080170CE &recalled record value
    ldr r0, [r0, #0]                         @ 080170D2
    movs r5, r0                              @ 080170D4
    mvns.w r0, #2147483648                   @ 080170D6
    cmp r5, r0                               @ 080170DA
    bne .L080170E6                           @ 080170DC
    movs r0, #0                              @ 080170DE
    bl fn_080199B4                           @ 080170E0
    b .L080170FA                             @ 080170E4
.L080170E6:                                @ reached from 080170DC bne (not equal / non-zero)
    movs r3, #1                              @ 080170E6
    movs r2, r5                              @ 080170E8
    ldr r0, =v_20007FED                      @ 080170EA &recalled decimal-point position
    ldrb r1, [r0, #0]                        @ 080170EE
    ldr r0, =v_20007FEB                      @ 080170F0 &recalled mode
    ldrb r0, [r0, #0]                        @ 080170F4
    bl lcd_show_value_pos5_9                 @ 080170F6
.L080170FA:                                @ reached from 080170E4 b; falls in
    @ commit the finished screen

    bl lcd_commit_shadow                     @ 080170FA
    pop {r4, r5, r6, pc}                     @ 080170FE
ENDFUNC fn_080170AC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080171FA - recompute the decimal point of the live range and draw it
@ Replaces : 0x080171FA FUN_080171FA (v2.05, 40 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : writes 0x2000803F; reads meter_mode, meter_range
@ Spec     : DESIGN.md Appendix C (decimal_position_for_mode_range, MODE)
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ Deviation: IMP-02 (production only): while the power-on window shows its own screen on the main display (the splash
@            before the version has moved to the sub display, a key-combination screen or the all-segments test), the
@            position is stored but neither drawn nor committed: v2.05 applies no mode inside the window, and drawing the
@            point would show it inside that screen ("U.-205", "5.DCAL").  ui_bootwin_gate draws it when the main digits
@            are handed to the reading, and every later value draw sets it from 0x2000803F.
@ -----------------------------------------------------------------------------
FUNC fn_080171FA
    @ d = decimal_position_for_mode_range(mode, range) -> 0x2000803F, then set the main decimal point (fn_0801717E) and commit

    push {r7, lr}                            @ 080171FA
    ldr r0, =meter_range                     @ 080171FC &meter_range
    ldrb r1, [r0, #0]                        @ 08017200
    ldr r0, =meter_mode                      @ 08017202 &meter_mode
    ldrb r0, [r0, #0]                        @ 08017206
    bl decimal_position_for_mode_range       @ 08017208
    ldr r1, =v_2000803F                      @ 0801720C &main decimal-point position
    strb r0, [r1, #0]                        @ 08017210
    bl ui_bootwin_main_busy                  @ IMP-02: r0 = 1 while a window screen owns the main display
    cbnz r0, 1f                              @ position stored, not drawn (see Deviation)
    ldr r0, =v_2000803F                      @ 08017212 &main decimal-point position
    ldrb r0, [r0, #0]                        @ 08017216
    bl fn_0801717E                           @ 08017218
    bl lcd_commit_shadow                     @ 0801721C
1:  pop {r0, pc}                             @ 08017220
ENDFUNC fn_080171FA
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08017222 - redraw every live annunciator
@ Replaces : 0x08017222 FUN_08017222 (v2.05, 60 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only; called by fn_08016D34 when 0x20008060 is set
@ RAM      : clears 0x20008060; reads meter_mode, meter_range, 0x20008098, 0x20008099
@ Spec     : analysis/lcd_map.md 4
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08017222
    @ clear the request, redraw the status icons (fn_0801725E), clear the unit group (fn_08019B48), light the units of the current mode, reset the bargraph (fn_080192FC)

    push {r7, lr}                            @ 08017222
    movs r0, #0                              @ 08017224
    ldr r1, =v_20008060                      @ 08017226 &annunciator redraw request
    strb r0, [r1, #0]                        @ 0801722A
    bl fn_0801725E                           @ 0801722C
    bl fn_08019B48                           @ 08017230
    ldr r0, =v_20008099                      @ 08017234 &LowZ AC/DC decided flag
    ldrb r3, [r0, #0]                        @ 08017238
    ldr r0, =v_20008098                      @ 0801723A &LowZ AC/DC state (0 = DC)
    ldrb r2, [r0, #0]                        @ 0801723E
    ldr r0, =meter_range                     @ 08017240 &meter_range
    ldrb r1, [r0, #0]                        @ 08017244
    ldr r0, =meter_mode                      @ 08017246 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801724A
    bl lcd_set_mode_annunciators             @ 0801724C
    bl fn_080192FC                           @ 08017250
    movs r0, #1                              @ 08017254
    ldr r1, =v_2000805B                      @ 08017256 &LCD commit request
    strb r0, [r1, #0]                        @ 0801725A
    pop {r0, pc}                             @ 0801725C
ENDFUNC fn_08017222
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801725E - redraw the status icons
@ Replaces : 0x0801725E FUN_0801725E (v2.05, 74 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow (through the setters; each is called with r0 = 0, so none commits)
@ Spec     : analysis/lcd_map.md 4.2: Apo, battery, BT, AUTO, HOLD / A-, MIN / MAX / AVG, REL, peak hold, 1 kHz, AC / DC, high voltage, temperature unit, MEM
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801725E
    @ fn_08019C5C Apo, fn_08019CF0 battery, fn_08019D2C BT, fn_08019D68 AUTO, fn_08019FA2 HOLD / A-, fn_08019E24 MIN / MAX / AVG,
    @ fn_08019F2E REL, fn_0801A07C peak hold, fn_0801A110 1 kHz, fn_0801A17C AC / DC, fn_0801A370 high voltage, fn_0801A3A4 degC / degF, fn_0801A32A MEM

    push {r7, lr}                            @ 0801725E
    movs r0, #0                              @ 08017260
    bl fn_08019C5C                           @ 08017262
    movs r0, #0                              @ 08017266
    bl fn_08019CF0                           @ 08017268
    movs r0, #0                              @ 0801726C
    bl fn_08019D2C                           @ 0801726E
    movs r0, #0                              @ 08017272
    bl fn_08019D68                           @ 08017274
    movs r0, #0                              @ 08017278
    bl fn_08019FA2                           @ 0801727A
    movs r0, #0                              @ 0801727E
    bl fn_08019E24                           @ 08017280
    movs r0, #0                              @ 08017284
    bl fn_08019F2E                           @ 08017286
    movs r0, #0                              @ 0801728A
    bl fn_0801A07C                           @ 0801728C
    bl fn_0801A110                           @ 08017290
    bl fn_0801A17C                           @ 08017294
    bl fn_0801A370                           @ 08017298
    bl fn_0801A3A4                           @ 0801729C
    movs r0, #0                              @ 080172A0
    bl fn_0801A32A                           @ 080172A2
    pop {r0, pc}                             @ 080172A6
ENDFUNC fn_0801725E
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801772E - redraw the annunciators for the recalled (MEM view) record
@ Replaces : 0x0801772E FUN_0801772E (v2.05, 64 bytes)
@ In       : -
@ Out      : -   (commits at the end)
@ Context  : main only
@ RAM      : writes 0x20007FED = decimal position of the recalled mode / range; reads 0x20007FEB (mode), 0x20007FEC (range), 0x20007FE5, 0x20007FE6
@ Spec     : analysis/lcd_map.md 4 (recalled copies replace the live state while 0x20007FE4 is set)
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801772E
    @ 0x20007FED = decimal_position_for_mode_range(recalled mode, recalled range); status icons (fn_0801725E, whose setters use the recalled copies while 0x20007FE4 is set); unit group cleared; units of the recalled mode; bargraph off (fn_08019364); commit

    push {r7, lr}                            @ 0801772E
    ldr r0, =v_20007FEC                      @ 08017730 &recalled range
    ldrb r1, [r0, #0]                        @ 08017734
    ldr r0, =v_20007FEB                      @ 08017736 &recalled mode
    ldrb r0, [r0, #0]                        @ 08017738
    bl decimal_position_for_mode_range       @ 0801773A
    ldr r1, =v_20007FED                      @ 0801773E &recalled decimal-point position
    strb r0, [r1, #0]                        @ 08017740
    bl fn_0801725E                           @ 08017742
    bl fn_08019B48                           @ 08017746
    ldr r0, =v_20007FE6                      @ 0801774A &recalled-view copy passed as r3 (live: 0x20008099)
    ldrb r3, [r0, #0]                        @ 0801774E
    ldr r0, =v_20007FE5                      @ 08017750 &recalled-view copy passed as r2 (live: 0x20008098)
    ldrb r2, [r0, #0]                        @ 08017754
    ldr r0, =v_20007FEC                      @ 08017756 &recalled range
    ldrb r1, [r0, #0]                        @ 0801775A
    ldr r0, =v_20007FEB                      @ 0801775C &recalled mode
    ldrb r0, [r0, #0]                        @ 0801775E
    bl lcd_set_mode_annunciators             @ 08017760
    bl fn_08019364                           @ 08017764
    bl lcd_commit_shadow                     @ 08017768
    pop {r0, pc}                             @ 0801776C
ENDFUNC fn_0801772E
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801776E - redraw the unit prefix of modes 6, 9 and 12
@ Replaces : 0x0801776E FUN_0801776E (v2.05, 62 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only; called by fn_08016D34 when 0x20008061 is set
@ RAM      : clears 0x20008061; reads meter_mode, meter_range
@ Spec     : analysis/lcd_map.md 4.1 (FREQ fn_08017858, OHM fn_080177F2, CAP fn_080177AC)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801776E
    push {r7, lr}                            @ 0801776E
    movs r0, #0                              @ 08017770
    ldr r1, =v_20008061                      @ 08017772 &unit-prefix redraw request
    strb r0, [r1, #0]                        @ 08017774
    ldr r0, =meter_mode                      @ 08017776 &meter_mode
    ldrb r0, [r0, #0]                        @ 08017778
    cmp r0, #6                               @ 0801777A branch if mode == 6 (6 = FREQ)
    beq .L08017788                           @ 0801777C
    cmp r0, #9                               @ 0801777E branch if mode == 9 (9 = OHM)
    beq .L08017792                           @ 08017780
    cmp r0, #12                              @ 08017782 branch if mode == 12 (12 = CAP)
    beq .L0801779C                           @ 08017784
    b .L080177A4                             @ 08017786
.L08017788:                                @ reached from 0801777C beq (equal / zero)
    ldr r0, =meter_range                     @ 08017788 &meter_range
    ldrb r0, [r0, #0]                        @ 0801778A
    bl fn_08017858                           @ 0801778C
    b .L080177A4                             @ 08017790
.L08017792:                                @ reached from 08017780 beq (equal / zero)
    ldr r0, =meter_range                     @ 08017792 &meter_range
    ldrb r0, [r0, #0]                        @ 08017794
    bl fn_080177F2                           @ 08017796
    b .L080177A4                             @ 0801779A
.L0801779C:                                @ reached from 08017784 beq (equal / zero)
    ldr r0, =meter_range                     @ 0801779C &meter_range
    ldrb r0, [r0, #0]                        @ 0801779E
    bl fn_080177AC                           @ 080177A0
.L080177A4:                                @ reached from 08017786 b; 08017790 b; 0801779A b; falls in
    movs r0, #1                              @ 080177A4
    ldr r1, =v_2000805B                      @ 080177A6 &LCD commit request
    strb r0, [r1, #0]                        @ 080177A8
    pop {r0, pc}                             @ 080177AA
ENDFUNC fn_0801776E
    .ltorg
