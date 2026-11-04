@ =============================================================================
@ long.s - KEY: the long-press action of every key (v2.05 handle_pg8_15_long_press 0x0801622C)
@
@ A long press fires after the key has been down for 50 ticks (0.50 s).  Backlight on MODE, edit on SETUP,
@ auto-range on RANGE, filter / user zero on REL, leave MIN/MAX, logging on MEM, serial transfer on PEAK.
@ HOLD alone has no long press.
@
@ Deviations: OF-17 (the 1 kHz filter cannot be switched on while PEAK is on), OF-09 (REL long stores the
@ accumulated user zero).
@ Source of truth: analysis/keys_setup.md 2.2, checked against the v2.05 listing.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "key.inc"

    .section .text.key.long, "ax", %progbits

@ -----------------------------------------------------------------------------
@ handle_pg8_15_long_press - action of a long key press (key held 0.5 s)
@ Replaces : 0x0801622C handle_pg8_15_long_press (v2.05)
@ In       : r0 = key code: 0x01 MODE, 0x02 SETUP, 0x04 MIN/MAX, 0x08 MEM, 0x10 RANGE, 0x28 MEM + HOLD, 0x40 REL, 0x80 PEAK
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main (fn_0801682C, fn_08014AE6)
@ RAM      : see the blocks below; writes the backlight state 0x2000807B and PE8 (GPIOE BSRR bit 8) for MODE
@ Spec     : analysis/keys_setup.md 2.2 (long press column)
@ Deviation: OF-17 (the 1 kHz filter cannot be switched on while PEAK is on), OF-09 (REL long stores the accumulated
@            user zero)
@ -----------------------------------------------------------------------------
FUNC handle_pg8_15_long_press
    push {r4, lr}                       @ 0801622C

@ r4 = key code.  Dispatch; HOLD alone has no long press, an unknown code gets the refusal beep
    movs r4, r0                         @ 0801622E
    uxtb r4, r4                         @ 08016230
    movs r0, r4                         @ 08016232
    cmp r0, #1                          @ 08016234
    beq .Llp_key_mode                   @ 08016236
    cmp r0, #2                          @ 08016238
    beq .Llp_key_setup                  @ 0801623A
    cmp r0, #4                          @ 0801623C
    beq .Llp_key_minmax                 @ 0801623E
    cmp r0, #8                          @ 08016242
    beq .Llp_key_mem                    @ 08016244
    cmp r0, #0x10                       @ 08016248
    beq .Llp_key_range                  @ 0801624A
    cmp r0, #0x28                       @ 0801624C
    beq .Llp_key_mem_hold               @ 0801624E
    cmp r0, #0x40                       @ 08016250
    beq .Llp_key_rel                    @ 08016252
    cmp r0, #0x80                       @ 08016256
    beq .Llp_key_peak                   @ 08016258
    b .Llp_key_other                    @ 0801625C

@ ---- MEM + HOLD ----  refused in calibration mode, else toggle logging with the HOLD-state clearing variant
@ (fn_0801657C(1))
@ reached from 0801624E beq (equal / zero) after cmp r0, #0x28
.Llp_key_mem_hold:
    ldr r0, =key_cal_mode               @ 0801625E
    ldrb r0, [r0]                       @ 08016262
    cmp r0, #0                          @ 08016264
    beq .Llp_0801626E                   @ 08016266
    bl fn_0800EE6C                      @ 08016268
    b .Llp_08016274                     @ 0801626C
@ reached from 08016266 beq (equal / zero) after cmp r0, #0
.Llp_0801626E:
    movs r0, #1                         @ 0801626E
    bl fn_0801657C                      @ 08016270
@ reached from 0801626C b (jump)
.Llp_08016274:
    b .Llp_end                          @ 08016274

@ ---- SETUP ----  refused while logging or MEM view.  fn_080165F4(0) tells whether the setup item can be edited
@ (0 = no: refusal beep).  Toggle the edit flag, reset the edit blink state and the ID digit cursor (4), long beep;
@ when the edit has just ended save the item (fn_080165F4(100))
@ reached from 0801623A beq (equal / zero) after cmp r0, #2
.Llp_key_setup:
    ldr r0, =key_logging                @ 08016276
    ldrb r0, [r0]                       @ 0801627A
    ldr r1, =key_mem_view               @ 0801627C
    ldrb r1, [r1]                       @ 08016280
    orrs r0, r1                         @ 08016282
    uxtb r0, r0                         @ 08016284
    cmp r0, #0                          @ 08016286
    beq .Llp_08016290                   @ 08016288
    bl fn_0800EE6C                      @ 0801628A
    b .Llp_end                          @ 0801628E
@ reached from 08016288 beq (equal / zero) after cmp r0, #0
.Llp_08016290:
    movs r0, #0                         @ 08016290
    bl fn_080165F4                      @ 08016292
    cmp r0, #0                          @ 08016296
    beq .Llp_edit_refuse                @ 08016298
    ldr r0, =key_setup_edit             @ 0801629A
    ldrb r0, [r0]                       @ 0801629E
    teq r0, #1                          @ 080162A0
    beq .Llp_080162B0                   @ 080162A4
    movs r0, #1                         @ 080162A6
    ldr r1, =key_setup_edit             @ 080162A8
    strb r0, [r1]                       @ 080162AC
    b .Llp_080162B8                     @ 080162AE
@ reached from 080162A4 beq (equal / zero) after teq r0, #1
.Llp_080162B0:
    movs r0, #0                         @ 080162B0
    ldr r1, =key_setup_edit             @ 080162B2
    strb r0, [r1]                       @ 080162B6
@ reached from 080162AE b (jump)
.Llp_080162B8:
    movs r0, #0                         @ 080162B8
    ldr r1, =key_setup_blink            @ 080162BA
    strb r0, [r1]                       @ 080162BE
    movs r0, #4                         @ 080162C0
    ldr r1, =key_setup_digit            @ 080162C2
    strb r0, [r1]                       @ 080162C6
    bl fn_0800EE5E                      @ 080162C8
    ldr r0, =key_setup_edit             @ 080162CC
    ldrb r0, [r0]                       @ 080162D0
    cmp r0, #0                          @ 080162D2
    bne .Llp_080162E2                   @ 080162D4
    movs r0, #0x64                      @ 080162D6
    bl fn_080165F4                      @ 080162D8
    b .Llp_080162E2                     @ 080162DC
@ reached from 08016298 beq (equal / zero) after cmp r0, #0
.Llp_edit_refuse:
    bl fn_0800EE6C                      @ 080162DE
@ reached from 080162D4 bne (not equal / non-zero) after cmp r0, #0
@              and from 080162DC b (jump)
.Llp_080162E2:
    b .Llp_end                          @ 080162E2

@ ---- MODE ----  toggle the backlight: on = state 1, timer 0x78, PE8 high (BSRR bit 8); off = state 0, PE8 low.
@ Long beep
@ reached from 08016236 beq (equal / zero) after cmp r0, #1
.Llp_key_mode:
    movs r0, #0
    ldr r1, =pwr_bl_auto
    strb r0, [r1]                       @ IMP-07: a manual switch (on or off) ends any pending wake of the auto-off timer
    ldr r0, =key_backlight_on           @ 080162E4
    ldrb r0, [r0]                       @ 080162E8
    cmp r0, #0                          @ 080162EA
    bne .Llp_0801630A                   @ 080162EC
    movs r0, #1                         @ 080162EE
    ldr r1, =key_backlight_on           @ 080162F0
    strb r0, [r1]                       @ 080162F4
    movs r0, #0x78                      @ 080162F6
    ldr r1, =key_backlight_tmr          @ 080162F8
    strh r0, [r1]                       @ 080162FC
    mov.w r0, #0x100                    @ 080162FE
    ldr r1, =GPIOE_BASE + GPIO_BSRRL    @ 08016302
    strh r0, [r1]                       @ 08016306
    bl pwr_bl_restart                   @ IMP-07: the backlight is on: start the auto-off countdown
    b .Llp_mode_beep                    @ 08016308
@ reached from 080162EC bne (not equal / non-zero) after cmp r0, #0
.Llp_0801630A:
    movs r0, #0                         @ 0801630A
    ldr r1, =key_backlight_on           @ 0801630C
    strb r0, [r1]                       @ 08016310
    mov.w r0, #0x100                    @ 08016312
    ldr r1, =GPIOE_BASE + GPIO_BSRRH    @ 08016316
    strh r0, [r1]                       @ 0801631A
@ reached from 08016308 b (jump)
.Llp_mode_beep:
    bl pwr_bl_remember                  @ owner PWR: remember the new state in EEPROM 0x017 bit 7 for the next power-on
    bl fn_0800EE5E                      @ 0801631C
    b .Llp_end                          @ 08016320

@ ---- RANGE ----  refused while logging or MEM view.  Not in calibration mode: back to auto-range (range_manual 0,
@ range 0, VA sub-range flags of range 0 by fn_0801485A, range request).  AUTO annunciator, long beep
@ reached from 0801624A beq (equal / zero) after cmp r0, #0x10
.Llp_key_range:
    ldr r0, =key_logging                @ 08016322
    ldrb r0, [r0]                       @ 08016326
    ldr r1, =key_mem_view               @ 08016328
    ldrb r1, [r1]                       @ 0801632C
    orrs r0, r1                         @ 0801632E
    ldr r1, =lt_on
    ldrb r1, [r1]
    orrs r0, r1                         @ IMP-20: no return to auto range while the limit test is on
    uxtb r0, r0                         @ 08016330
    cmp r0, #0                          @ 08016332
    beq .Llp_0801633C                   @ 08016334
    bl fn_0800EE6C                      @ 08016336
    b .Llp_end                          @ 0801633A
@ reached from 08016334 beq (equal / zero) after cmp r0, #0
.Llp_0801633C:
    ldr r0, =key_cal_mode               @ 0801633C
    ldrb r0, [r0]                       @ 08016340
    cmp r0, #0                          @ 08016342
    bne .Llp_0801634E                   @ 08016344
    movs r0, #0                         @ 08016346
    ldr r1, =range_manual               @ 08016348
    strb r0, [r1]                       @ 0801634C
@ reached from 08016344 bne (not equal / non-zero) after cmp r0, #0
.Llp_0801634E:
    ldr r0, =key_cal_mode               @ 0801634E
    ldrb r0, [r0]                       @ 08016352
    cmp r0, #0                          @ 08016354
    bne .Llp_range_done                 @ 08016356
    movs r0, #0                         @ 08016358
    ldr r1, =meter_range                @ 0801635A
    strb r0, [r1]                       @ 0801635E
    ldr r0, =meter_range                @ 08016360
    ldrb r1, [r0]                       @ 08016364
    ldr r0, =meter_mode                 @ 08016366
    ldrb r0, [r0]                       @ 0801636A
    bl fn_0801485A                      @ 0801636C
    movs r0, #1                         @ 08016370
    ldr r1, =key_range_req              @ 08016372
    strb r0, [r1]                       @ 08016376
@ reached from 08016356 bne (not equal / non-zero) after cmp r0, #0
.Llp_range_done:
    movs r0, #1                         @ 08016378
    bl fn_08019D68                      @ 0801637A
    bl fn_0800EE5E                      @ 0801637E
    b .Llp_end                          @ 08016382

@ ---- REL ----  refused while logging, MEM view or setup edit.  ACV / ACmV: toggle the 1 kHz filter (refused with
@ AC+DC, and - OF-17 - while PEAK is on).  Current modes at range 0: add the reading to the user zero and store it
@ reached from 08016252 beq (equal / zero) after cmp r0, #0x40
.Llp_key_rel:
    ldr r0, =key_logging                @ 08016384
    ldrb r0, [r0]                       @ 08016388
    ldr r1, =key_mem_view               @ 0801638A
    ldrb r1, [r1]                       @ 0801638E
    orrs r0, r1                         @ 08016390
    ldr r1, =key_setup_edit             @ 08016392
    ldrb r1, [r1]                       @ 08016396
    orrs r0, r1                         @ 08016398
    uxtb r0, r0                         @ 0801639A
    cmp r0, #0                          @ 0801639C
    beq .Llp_080163A6                   @ 0801639E
    bl fn_0800EE6C                      @ 080163A0
    b .Llp_end                          @ 080163A4
@ reached from 0801639E beq (equal / zero) after cmp r0, #0
.Llp_080163A6:
    ldr r0, =meter_mode                 @ 080163A6
    ldrb r0, [r0]                       @ 080163AA
    cmp r0, #2                          @ 080163AC mode 2 ACV
    beq .Llp_rel_filter                 @ 080163AE
    ldr r0, =meter_mode                 @ 080163B0
    ldrb r0, [r0]                       @ 080163B4
    cmp r0, #4                          @ 080163B6 mode 4 ACmV
    bne .Llp_rel_current                @ 080163B8

@ ACV or ACmV: with AC+DC on the filter cannot be used
@ reached from 080163AE beq (equal / zero) after cmp r0, #2
.Llp_rel_filter:
    ldr r0, =acdc_active                @ 080163BA
    ldrb r0, [r0]                       @ 080163BE
    cmp r0, #0                          @ 080163C0
    bne .Llp_filter_refuse              @ 080163C2

@ filter on or off: toggle, clear AC+DC, request a mode apply, accept beep
    ldr r0, =peak_hold
    ldrb r0, [r0]
    cbnz r0, .Llp_filter_refuse                 @ OF-17: PEAK on, so the filter must stay off
    ldr r0, =filter_1khz                @ 080163C4
    ldrb r0, [r0]                       @ 080163C8
    eors r0, r0, #1                     @ 080163CA
    ldr r1, =filter_1khz                @ 080163CE
    strb r0, [r1]                       @ 080163D2
    movs r0, #0                         @ 080163D4
    ldr r1, =acdc_active                @ 080163D6
    strb r0, [r1]                       @ 080163DA
    movs r0, #1                         @ 080163DC
    ldr r1, =key_mode_req               @ 080163DE
    strb r0, [r1]                       @ 080163E2
    bl fn_0800EE50                      @ 080163E4
    b .Llp_rel_end                      @ 080163E8
    .ltorg
@ reached from 080163C2 bne (not equal / non-zero) after cmp r0, #0
.Llp_filter_refuse:
    bl fn_0800EE6C                      @ 080163EA
    b .Llp_rel_end                      @ 080163EE

@ current modes ACuA, DCuA, ACmA, DCmA, ACA, DCA (0x10..0x15): only at range 0
@ reached from 080163B8 bne (not equal / non-zero) after cmp r0, #4
.Llp_rel_current:
    ldr r0, =meter_mode                 @ 080163F0
    ldrb r0, [r0]                       @ 080163F4
    cmp r0, #0x10                       @ 080163F6 mode 16 ACuA
    beq .Llp_rel_zero                   @ 080163F8
    ldr r0, =meter_mode                 @ 080163FA
    ldrb r0, [r0]                       @ 080163FE
    cmp r0, #0x12                       @ 08016400 mode 18 ACmA
    beq .Llp_rel_zero                   @ 08016402
    ldr r0, =meter_mode                 @ 08016404
    ldrb r0, [r0]                       @ 08016408
    cmp r0, #0x14                       @ 0801640A mode 20 ACA
    beq .Llp_rel_zero                   @ 0801640C
    ldr r0, =meter_mode                 @ 0801640E
    ldrb r0, [r0]                       @ 08016412
    cmp r0, #0x11                       @ 08016414 mode 17 DCuA
    beq .Llp_rel_zero                   @ 08016416
    ldr r0, =meter_mode                 @ 08016418
    ldrb r0, [r0]                       @ 0801641C
    cmp r0, #0x13                       @ 0801641E mode 19 DCmA
    beq .Llp_rel_zero                   @ 08016420
    ldr r0, =meter_mode                 @ 08016422
    ldrb r0, [r0]                       @ 08016426
    cmp r0, #0x15                       @ 08016428 mode 21 DCA
    bne .Llp_rel_refuse                 @ 0801642A

@ user zero += reading (RAM 0x20007E0C), then store the new user zero in the EEPROM record of this mode
@ (current_extra_store: marker 0xA5 + 32-bit big endian value, EEPROM 0x4D0..0x4FC)
@ reached from 080163F8 beq (equal / zero) after cmp r0, #0x10
@              and from 08016402 beq (equal / zero) after cmp r0, #0x12
@              and from 0801640C beq (equal / zero) after cmp r0, #0x14
@              ... and 2 more
.Llp_rel_zero:
    ldr r0, =meter_range                @ 0801642C
    ldrb r0, [r0]                       @ 08016430
    cmp r0, #0                          @ 08016432
    bne .Llp_rel_refuse                 @ 08016434
    ldr r0, =key_user_zero              @ 08016436
    ldr r0, [r0]                        @ 0801643A
    ldr r1, =key_reading                @ 0801643C
    ldr r1, [r1]                        @ 08016440
    adds r0, r1, r0                     @ 08016442
    ldr r1, =key_user_zero              @ 08016444
    str r0, [r1]                        @ 08016448
    ldr r0, =key_user_zero                      @ OF-09: store the accumulated zero (v2.05 stored only the reading) [replaces v2.05 ldr.w r0,[0x08016cb0] at 0801644A]
    ldr r2, [r0]                        @ 0801644E
    ldr r0, =meter_range                @ 08016450
    ldrb r1, [r0]                       @ 08016454
    ldr r0, =meter_mode                 @ 08016456
    ldrb r0, [r0]                       @ 0801645A
    bl current_extra_store              @ 0801645C
    bl fn_0800EE5E                      @ 08016460
    b .Llp_rel_end                      @ 08016464
@ reached from 0801642A bne (not equal / non-zero) after cmp r0, #0x15
@              and from 08016434 bne (not equal / non-zero) after cmp r0, #0
.Llp_rel_refuse:
    bl fn_0800EE6C                      @ 08016466
@ reached from 080163E8 b (jump)
@              and from 080163EE b (jump)
@              and from 08016464 b (jump)
.Llp_rel_end:
    b .Llp_end                          @ 0801646A

@ ---- MIN/MAX ----  refused in calibration mode and while MIN/MAX is off.  Else leave MIN/MAX: show all icons
@ once (state 4, fn_08015934), restore range_manual unless HOLD is on, state 0
@ reached from 0801623E beq (equal / zero) after cmp r0, #4
.Llp_key_minmax:
    ldr r0, =key_cal_mode               @ 0801646C
    ldrb r0, [r0]                       @ 08016470
    cmp r0, #0                          @ 08016472
    beq .Llp_0801647C                   @ 08016474
    bl fn_0800EE6C                      @ 08016476
    b .Llp_end                          @ 0801647A
@ reached from 08016474 beq (equal / zero) after cmp r0, #0
.Llp_0801647C:
    ldr r0, =minmax_state               @ 0801647C
    ldrb r0, [r0]                       @ 08016480
    cmp r0, #0                          @ 08016482
    beq .Llp_minmax_refuse              @ 08016484
    movs r0, #4                         @ 08016486
    ldr r1, =minmax_state               @ 08016488
    strb r0, [r1]                       @ 0801648C
    bl fn_08015934                      @ 0801648E
    ldr r0, =hold_active                @ 08016492
    ldrb r0, [r0]                       @ 08016496
    cmp r0, #0                          @ 08016498
    bne .Llp_080164AE                   @ 0801649A
    ldr r0, =key_range_saved            @ 0801649C
    ldrb r0, [r0]                       @ 080164A0
    ldr r1, =range_manual               @ 080164A2
    strb r0, [r1]                       @ 080164A6
    movs r0, #0                         @ 080164A8
    bl fn_08019D68                      @ 080164AA
@ reached from 0801649A bne (not equal / non-zero) after cmp r0, #0
.Llp_080164AE:
    movs r0, #0                         @ 080164AE
    ldr r1, =minmax_state               @ 080164B0
    strb r0, [r1]                       @ 080164B4
    movs r0, #0                         @ 080164B6
    bl fn_08019E24                      @ 080164B8
    movs r0, #0                         @ 080164BC
    bl fn_08019C5C                      @ 080164BE
    bl fn_0800EE5E                      @ 080164C2
    b .Llp_080164CC                     @ 080164C6
@ reached from 08016484 beq (equal / zero) after cmp r0, #0
.Llp_minmax_refuse:
    bl fn_0800EE6C                      @ 080164C8
@ reached from 080164C6 b (jump)
.Llp_080164CC:
    b .Llp_end                          @ 080164CC

@ ---- MEM ----  not in calibration mode: toggle logging (fn_0801657C(0)).  In calibration mode: request a gain
@ weight capture: OHM range 6 = flag 0x20008090 with countdown 16, any other mode = board-temperature offset
@ capture flag 0x20008096
@ reached from 08016244 beq (equal / zero) after cmp r0, #8
.Llp_key_mem:
    ldr r0, =key_cal_mode               @ 080164CE
    ldrb r0, [r0]                       @ 080164D2
    cmp r0, #0                          @ 080164D4
    beq .Llp_0801650C                   @ 080164D6
    ldr r0, =meter_mode                 @ 080164D8
    ldrb r0, [r0]                       @ 080164DC
    cmp r0, #9                          @ 080164DE mode 9 OHM
    bne .Llp_080164FE                   @ 080164E0
    ldr r0, =meter_range                @ 080164E2
    ldrb r0, [r0]                       @ 080164E6
    cmp r0, #6                          @ 080164E8
    bne .Llp_080164FE                   @ 080164EA
    movs r0, #1                         @ 080164EC
    ldr r1, =key_cal_ohm6_req           @ 080164EE
    strb r0, [r1]                       @ 080164F2
    movs r0, #0x10                      @ 080164F4
    ldr r1, =key_cal_count              @ 080164F6
    strb r0, [r1]                       @ 080164FA
    b .Llp_08016506                     @ 080164FC
@ reached from 080164E0 bne (not equal / non-zero) after cmp r0, #9
@              and from 080164EA bne (not equal / non-zero) after cmp r0, #6
.Llp_080164FE:
    movs r0, #1                         @ 080164FE
    ldr r1, =key_cal_board_req          @ 08016500
    strb r0, [r1]                       @ 08016504
@ reached from 080164FC b (jump)
.Llp_08016506:
    bl fn_0800EE5E                      @ 08016506
    b .Llp_08016512                     @ 0801650A
@ reached from 080164D6 beq (equal / zero) after cmp r0, #0
.Llp_0801650C:
    movs r0, #0                         @ 0801650C
    bl fn_0801657C                      @ 0801650E
@ reached from 0801650A b (jump)
.Llp_08016512:
    b .Llp_end                          @ 08016512

@ ---- PEAK ----  refused while a setup item is edited.  Toggle the serial / BLE status transfer (0x2000802B),
@ drop the pending remote key, tell the BLE module (fn_0800C51A), long beep
@ reached from 08016258 beq (equal / zero) after cmp r0, #0x80
.Llp_key_peak:
    ldr r0, =key_setup_edit             @ 08016514
    ldrb r0, [r0]                       @ 08016518
    cmp r0, #0                          @ 0801651A
    beq .Llp_08016524                   @ 0801651C
    bl fn_0800EE6C                      @ 0801651E
    b .Llp_peak_end                     @ 08016522
@ reached from 0801651C beq (equal / zero) after cmp r0, #0
.Llp_08016524:
    ldr r0, =key_ble_on                 @ 08016524
    ldrb r0, [r0]                       @ 08016528
    teq r0, #1                          @ 0801652A
    beq .Llp_0801653A                   @ 0801652E
    movs r0, #1                         @ 08016530
    ldr r1, =key_ble_on                 @ 08016532
    strb r0, [r1]                       @ 08016536
    b .Llp_08016542                     @ 08016538
@ reached from 0801652E beq (equal / zero) after teq r0, #1
.Llp_0801653A:
    movs r0, #0                         @ 0801653A
    ldr r1, =key_ble_on                 @ 0801653C
    strb r0, [r1]                       @ 08016540
@ reached from 08016538 b (jump)
.Llp_08016542:
    movs r0, #0                         @ 08016542
    ldr r1, =v_20008033                 @ 08016544
    strb r0, [r1]                       @ 08016548
    movs r0, #0                         @ 0801654A
    ldr r1, =key_remote_ev              @ 0801654C
    strb r0, [r1]                       @ 08016550
    movs r0, #0                         @ 08016552
    ldr r1, =key_remote_code            @ 08016554
    strb r0, [r1]                       @ 08016558
    ldr r0, =key_ble_on                 @ 0801655A
    ldrb r0, [r0]                       @ 0801655E
    bl fn_0800C51A                      @ 08016560
    movs r0, #0                         @ 08016564
    ldr r1, =v_20007FB0                 @ 08016566
    strh r0, [r1]                       @ 0801656A
    bl fn_0800EE5E                      @ 0801656C
@ reached from 08016522 b (jump)
.Llp_peak_end:
    b .Llp_end                          @ 08016570
@ reached from 0801625C b (jump)
.Llp_key_other:
    bl fn_0800EE6C                      @ 08016572
@ reached from 08016274 b (jump)
@              and from 0801628E b (jump)
@              and from 080162E2 b (jump)
@              ... and 9 more
.Llp_end:
    pop {r4, pc}                        @ 08016576
ENDFUNC handle_pg8_15_long_press
    .ltorg
