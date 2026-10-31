@ =============================================================================
@ cycle.s - MODE: MODE and RANGE key helpers, AC+DC entry, burden re-apply variants, auto-range predicate
@
@ Replaces the v2.05 functions cycle_mode_on_bit0 0x08014500, FUN_08014708, FUN_0801472C, FUN_08014796,
@ FUN_08006774, FUN_080080C8 and FUN_08019DA2 (DESIGN.md 6.11, Appendix A MODE).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "mode.inc"

    .section .text.mode.cycle, "ax", %progbits

@ -----------------------------------------------------------------------------
@ cycle_mode_on_bit0 - MODE key: step to the next mode of the dial position
@ Replaces : 0x08014500 cycle_mode_on_bit0 (v2.05)
@ In       : -
@ Out      : meter_mode changed (r4 = 1) unless the mode has no cycle
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main (handle_pg8_15_short_press, MODE key)
@ RAM      : writes meter_mode, mode_freq_flag 0x20008074, hold_active, hold_stage2, mode_mode_req 0x2000804A;
@            reads acdc_active through fn_08014708
@ Spec     : analysis/rotary.md 2 (MODE-key cycle) and 3 (rotary memory), keys_setup.md 2.2
@ -----------------------------------------------------------------------------
FUNC cycle_mode_on_bit0

@ r4 = 0 (no change yet); fn_0801A760 first clears the annunciators of the old mode
    push {r4, lr}                       @ 08014500
    movs r4, #0                         @ 08014502
    bl fn_0801A760                      @ 08014504

@ cycle: 1 DCV -> 2 ACV; 2 ACV -> AC+DC variant -> 1 (fn_08014708); 3 -> 4 -> 5 -> 3; 6 -> 7 -> 8 -> 6;
@ 9 -> 10 -> 11 -> 12 -> 9; 13 -> 17 -> 16 -> 22 -> 13; 14 <-> 23; 15 <-> 24; 18 <-> 19; 20 <-> 21;
@ LowZ (0) has no cycle and TEMP/BEEP/... follow the ladder below
    ldr r0, =meter_mode                 @ 08014508
    ldrb r0, [r0]                       @ 0801450C
    cmp r0, #1                          @ 0801450E mode 1 DCV
    beq .L8014500_08014576              @ 08014510
    bcc .L8014500_after                 @ 08014512
    cmp r0, #3                          @ 08014516
    beq .L8014500_08014584              @ 08014518
    bcc .L8014500_from_acv              @ 0801451A
    cmp r0, #5                          @ 0801451C
    beq .L8014500_080145A0              @ 0801451E
    bcc .L8014500_08014592              @ 08014520
    cmp r0, #7                          @ 08014522
    beq .L8014500_0801469C              @ 08014524
    bcc .L8014500_0801468E              @ 08014528
    cmp r0, #9                          @ 0801452C
    beq .L8014500_080145AE              @ 0801452E
    bcc .L8014500_080146AA              @ 08014530
    cmp r0, #0xB                        @ 08014534
    beq .L8014500_080145CA              @ 08014536
    bcc .L8014500_080145BC              @ 08014538
    cmp r0, #0xD                        @ 0801453A
    beq .L8014500_0801462C              @ 0801453C
    bcc .L8014500_080145D8              @ 0801453E
    cmp r0, #0xF                        @ 08014540
    beq .L8014500_080145F4              @ 08014542
    bcc .L8014500_08014610              @ 08014544
    cmp r0, #0x11                       @ 08014546
    beq .L8014500_0801463A              @ 08014548
    bcc .L8014500_08014648              @ 0801454A
    cmp r0, #0x13                       @ 0801454C
    beq .L8014500_08014664              @ 0801454E
    bcc .L8014500_08014656              @ 08014552
    cmp r0, #0x15                       @ 08014556
    beq .L8014500_08014680              @ 08014558
    bcc .L8014500_08014672              @ 0801455C
    cmp r0, #0x17                       @ 08014560
    beq .L8014500_08014602              @ 08014562
    bcc .L8014500_0801461E              @ 08014564
    cmp r0, #0x18                       @ 08014566
    beq .L8014500_080145E6              @ 08014568
    b .L8014500_after                   @ 0801456A

@ mode 2 ACV: AC+DC variant or DCV (fn_08014708), mode changed
@ reached from 0801451A bcc (unsigned <) after cmp r0, #3
.L8014500_from_acv:
    bl fn_08014708                      @ 0801456C
    movs r0, #1                         @ 08014570
    movs r4, r0                         @ 08014572
    b .L8014500_after                   @ 08014574

@ mode 1 DCV -> 2 ACV
@ reached from 08014510 beq (equal / zero) after cmp r0, #1
.L8014500_08014576:
    movs r0, #2                         @ 08014576
    ldr r1, =meter_mode                 @ 08014578
    strb r0, [r1]                       @ 0801457C
    movs r0, #1                         @ 0801457E
    movs r4, r0                         @ 08014580
    b .L8014500_after                   @ 08014582

@ mode 3 DCmV -> 4 ACmV
@ reached from 08014518 beq (equal / zero) after cmp r0, #3
.L8014500_08014584:
    movs r0, #4                         @ 08014584
    ldr r1, =meter_mode                 @ 08014586
    strb r0, [r1]                       @ 0801458A
    movs r0, #1                         @ 0801458C
    movs r4, r0                         @ 0801458E
    b .L8014500_after                   @ 08014590

@ mode 4 ACmV -> 5 TEMP
@ reached from 08014520 bcc (unsigned <) after cmp r0, #5
.L8014500_08014592:
    movs r0, #5                         @ 08014592
    ldr r1, =meter_mode                 @ 08014594
    strb r0, [r1]                       @ 08014598
    movs r0, #1                         @ 0801459A
    movs r4, r0                         @ 0801459C
    b .L8014500_after                   @ 0801459E

@ mode 5 TEMP -> 3 DCmV
@ reached from 0801451E beq (equal / zero) after cmp r0, #5
.L8014500_080145A0:
    movs r0, #3                         @ 080145A0
    ldr r1, =meter_mode                 @ 080145A2
    strb r0, [r1]                       @ 080145A6
    movs r0, #1                         @ 080145A8
    movs r4, r0                         @ 080145AA
    b .L8014500_after                   @ 080145AC

@ mode 9 OHM -> 10 BEEP
@ reached from 0801452E beq (equal / zero) after cmp r0, #9
.L8014500_080145AE:
    movs r0, #0xA                       @ 080145AE
    ldr r1, =meter_mode                 @ 080145B0
    strb r0, [r1]                       @ 080145B4
    movs r0, #1                         @ 080145B6
    movs r4, r0                         @ 080145B8
    b .L8014500_after                   @ 080145BA

@ mode 10 BEEP -> 11 DIODE
@ reached from 08014538 bcc (unsigned <) after cmp r0, #0xB
.L8014500_080145BC:
    movs r0, #0xB                       @ 080145BC
    ldr r1, =meter_mode                 @ 080145BE
    strb r0, [r1]                       @ 080145C2
    movs r0, #1                         @ 080145C4
    movs r4, r0                         @ 080145C6
    b .L8014500_after                   @ 080145C8

@ mode 11 DIODE -> 12 CAP
@ reached from 08014536 beq (equal / zero) after cmp r0, #0xB
.L8014500_080145CA:
    movs r0, #0xC                       @ 080145CA
    ldr r1, =meter_mode                 @ 080145CC
    strb r0, [r1]                       @ 080145D0
    movs r0, #1                         @ 080145D2
    movs r4, r0                         @ 080145D4
    b .L8014500_after                   @ 080145D6

@ mode 12 CAP -> 9 OHM
@ reached from 0801453E bcc (unsigned <) after cmp r0, #0xD
.L8014500_080145D8:
    movs r0, #9                         @ 080145D8
    ldr r1, =meter_mode                 @ 080145DA
    strb r0, [r1]                       @ 080145DE
    movs r0, #1                         @ 080145E0
    movs r4, r0                         @ 080145E2
    b .L8014500_after                   @ 080145E4

@ mode 24 DCVA -> 15 VA
@ reached from 08014568 beq (equal / zero) after cmp r0, #0x18
.L8014500_080145E6:
    movs r0, #0xF                       @ 080145E6
    ldr r1, =meter_mode                 @ 080145E8
    strb r0, [r1]                       @ 080145EC
    movs r0, #1                         @ 080145EE
    movs r4, r0                         @ 080145F0
    b .L8014500_after                   @ 080145F2

@ mode 15 VA -> 24 DCVA
@ reached from 08014542 beq (equal / zero) after cmp r0, #0xF
.L8014500_080145F4:
    movs r0, #0x18                      @ 080145F4
    ldr r1, =meter_mode                 @ 080145F6
    strb r0, [r1]                       @ 080145FA
    movs r0, #1                         @ 080145FC
    movs r4, r0                         @ 080145FE
    b .L8014500_after                   @ 08014600

@ mode 23 DCmVA -> 14 mVA
@ reached from 08014562 beq (equal / zero) after cmp r0, #0x17
.L8014500_08014602:
    movs r0, #0xE                       @ 08014602
    ldr r1, =meter_mode                 @ 08014604
    strb r0, [r1]                       @ 08014608
    movs r0, #1                         @ 0801460A
    movs r4, r0                         @ 0801460C
    b .L8014500_after                   @ 0801460E

@ mode 14 mVA -> 23 DCmVA
@ reached from 08014544 bcc (unsigned <) after cmp r0, #0xF
.L8014500_08014610:
    movs r0, #0x17                      @ 08014610
    ldr r1, =meter_mode                 @ 08014612
    strb r0, [r1]                       @ 08014616
    movs r0, #1                         @ 08014618
    movs r4, r0                         @ 0801461A
    b .L8014500_after                   @ 0801461C

@ mode 22 DCuVA -> 13 uVA
@ reached from 08014564 bcc (unsigned <) after cmp r0, #0x17
.L8014500_0801461E:
    movs r0, #0xD                       @ 0801461E
    ldr r1, =meter_mode                 @ 08014620
    strb r0, [r1]                       @ 08014624
    movs r0, #1                         @ 08014626
    movs r4, r0                         @ 08014628
    b .L8014500_after                   @ 0801462A

@ mode 13 uVA -> 17 DCuA
@ reached from 0801453C beq (equal / zero) after cmp r0, #0xD
.L8014500_0801462C:
    movs r0, #0x11                      @ 0801462C
    ldr r1, =meter_mode                 @ 0801462E
    strb r0, [r1]                       @ 08014632
    movs r0, #1                         @ 08014634
    movs r4, r0                         @ 08014636
    b .L8014500_after                   @ 08014638

@ mode 17 DCuA -> 16 ACuA
@ reached from 08014548 beq (equal / zero) after cmp r0, #0x11
.L8014500_0801463A:
    movs r0, #0x10                      @ 0801463A
    ldr r1, =meter_mode                 @ 0801463C
    strb r0, [r1]                       @ 08014640
    movs r0, #1                         @ 08014642
    movs r4, r0                         @ 08014644
    b .L8014500_after                   @ 08014646

@ mode 16 ACuA -> 22 DCuVA
@ reached from 0801454A bcc (unsigned <) after cmp r0, #0x11
.L8014500_08014648:
    movs r0, #0x16                      @ 08014648
    ldr r1, =meter_mode                 @ 0801464A
    strb r0, [r1]                       @ 0801464E
    movs r0, #1                         @ 08014650
    movs r4, r0                         @ 08014652
    b .L8014500_after                   @ 08014654

@ mode 19 DCmA -> 18 ACmA
@ reached from 08014552 bcc (unsigned <) after cmp r0, #0x13
.L8014500_08014656:
    movs r0, #0x13                      @ 08014656
    ldr r1, =meter_mode                 @ 08014658
    strb r0, [r1]                       @ 0801465C
    movs r0, #1                         @ 0801465E
    movs r4, r0                         @ 08014660
    b .L8014500_after                   @ 08014662

@ mode 18 ACmA -> 19 DCmA
@ reached from 0801454E beq (equal / zero) after cmp r0, #0x13
.L8014500_08014664:
    movs r0, #0x12                      @ 08014664
    ldr r1, =meter_mode                 @ 08014666
    strb r0, [r1]                       @ 0801466A
    movs r0, #1                         @ 0801466C
    movs r4, r0                         @ 0801466E
    b .L8014500_after                   @ 08014670

@ mode 21 DCA -> 20 ACA
@ reached from 0801455C bcc (unsigned <) after cmp r0, #0x15
.L8014500_08014672:
    movs r0, #0x15                      @ 08014672
    ldr r1, =meter_mode                 @ 08014674
    strb r0, [r1]                       @ 08014678
    movs r0, #1                         @ 0801467A
    movs r4, r0                         @ 0801467C
    b .L8014500_after                   @ 0801467E

@ mode 20 ACA -> 21 DCA
@ reached from 08014558 beq (equal / zero) after cmp r0, #0x15
.L8014500_08014680:
    movs r0, #0x14                      @ 08014680
    ldr r1, =meter_mode                 @ 08014682
    strb r0, [r1]                       @ 08014686
    movs r0, #1                         @ 08014688
    movs r4, r0                         @ 0801468A
    b .L8014500_after                   @ 0801468C

@ mode 6 FREQ -> 7 PULSE
@ reached from 08014528 bcc (unsigned <) after cmp r0, #7
.L8014500_0801468E:
    movs r0, #7                         @ 0801468E
    ldr r1, =meter_mode                 @ 08014690
    strb r0, [r1]                       @ 08014694
    movs r0, #1                         @ 08014696
    movs r4, r0                         @ 08014698
    b .L8014500_after                   @ 0801469A
    .ltorg

@ mode 7 PULSE -> 8 DUTY
@ reached from 08014524 beq (equal / zero) after cmp r0, #7
.L8014500_0801469C:
    movs r0, #8                         @ 0801469C
    ldr r1, =meter_mode                 @ 0801469E
    strb r0, [r1]                       @ 080146A2
    movs r0, #1                         @ 080146A4
    movs r4, r0                         @ 080146A6
    b .L8014500_after                   @ 080146A8

@ mode 8 DUTY -> 6 FREQ
@ reached from 08014530 bcc (unsigned <) after cmp r0, #9
.L8014500_080146AA:
    movs r0, #6                         @ 080146AA
    ldr r1, =meter_mode                 @ 080146AC
    strb r0, [r1]                       @ 080146B0
    movs r0, #1                         @ 080146B2
    movs r4, r0                         @ 080146B4

@ mode_freq_flag = 1 in FREQ, PULSE and DUTY, else 0
@ reached from 08014512 bcc (unsigned <) after cmp r0, #1
@              and from 0801456A b (jump)
@              and from 08014574 b (jump)
@              ... and 22 more
.L8014500_after:
    movs r0, #0                         @ 080146B6
    ldr r1, =mode_freq_flag             @ 080146B8
    strb r0, [r1]                       @ 080146BC
    ldr r0, =meter_mode                 @ 080146BE
    ldrb r0, [r0]                       @ 080146C2
    cmp r0, #6                          @ 080146C4 mode 6 FREQ
    beq .L8014500_080146DC              @ 080146C6
    ldr r0, =meter_mode                 @ 080146C8
    ldrb r0, [r0]                       @ 080146CC
    cmp r0, #7                          @ 080146CE mode 7 PULSE
    beq .L8014500_080146DC              @ 080146D0
    ldr r0, =meter_mode                 @ 080146D2
    ldrb r0, [r0]                       @ 080146D6
    cmp r0, #8                          @ 080146D8 mode 8 DUTY
    bne .L8014500_080146E4              @ 080146DA
@ reached from 080146C6 beq (equal / zero) after cmp r0, #6
@              and from 080146D0 beq (equal / zero) after cmp r0, #7
.L8014500_080146DC:
    movs r0, #1                         @ 080146DC
    ldr r1, =mode_freq_flag             @ 080146DE
    strb r0, [r1]                       @ 080146E2

@ a new mode was set: HOLD off, mode apply requested, remember the mode in the rotary memory (EEPROM, SET)
@ reached from 080146DA bne (not equal / non-zero) after cmp r0, #8
.L8014500_080146E4:
    uxtb r4, r4                         @ 080146E4
    cmp r4, #0                          @ 080146E6
    beq .L8014500_08014706              @ 080146E8
    movs r0, #0                         @ 080146EA
    ldr r1, =hold_active                @ 080146EC
    strb r0, [r1]                       @ 080146F0
    movs r0, #0                         @ 080146F2
    ldr r1, =hold_stage2                @ 080146F4
    strb r0, [r1]                       @ 080146F8
    movs r0, #1                         @ 080146FA
    ldr r1, =mode_mode_req              @ 080146FC
    strb r0, [r1]                       @ 08014700
    bl rotary_memory_store              @ 08014702
@ reached from 080146E8 beq (equal / zero) after cmp r4, #0
.L8014500_08014706:
    pop {r4, pc}                        @ 08014706
ENDFUNC cycle_mode_on_bit0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08014708 - MODE key in ACV: switch AC+DC on, or off again and go to DCV
@ Replaces : 0x08014708 FUN_08014708 (v2.05)
@ In       : -
@ Out      : acdc_active toggled; meter_mode = 1 when AC+DC was on
@ Clobbers : r0-r3, r12, flags (r4 saved: replaces the unused r7 of v2.05)
@ Context  : main (cycle_mode_on_bit0)
@ Spec     : analysis/rotary.md 2
@ -----------------------------------------------------------------------------
FUNC fn_08014708

@ AC+DC on: switch it off and go to DCV; otherwise enter AC+DC (fn_0801472C)
    push {r4, lr}                       @ 08014708
    ldr r0, =acdc_active                @ 0801470A
    ldrb r0, [r0]                       @ 0801470E
    cmp r0, #0                          @ 08014710
    beq .L8014708_08014726              @ 08014712
    movs r0, #0                         @ 08014714
    ldr r1, =acdc_active                @ 08014716
    strb r0, [r1]                       @ 0801471A
    movs r0, #1                         @ 0801471C
    ldr r1, =meter_mode                 @ 0801471E
    strb r0, [r1]                       @ 08014722
    b .L8014708_0801472A                @ 08014724
@ reached from 08014712 beq (equal / zero) after cmp r0, #0
.L8014708_08014726:
    bl fn_0801472C                      @ 08014726
@ reached from 08014724 b (jump)
.L8014708_0801472A:
    pop {r4, pc}                        @ 0801472A
ENDFUNC fn_08014708
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801472C - enter the AC+DC measurement
@ Replaces : 0x0801472C FUN_0801472C (v2.05)
@ In       : -
@ Out      : acdc_active = 1 and its helper state initialised
@ Clobbers : r0, r1, flags
@ Context  : main (fn_08014708, and SET when the rotary memory says "ACV with AC+DC")
@ RAM      : writes acdc_active, filter_1khz (0), 0x20007E60, 0x200080A0, acdc_use_dcv_cal (0x200080BD),
@            0x200080BC, 0x200080BB, 0x200080BE, 0x20007E9C, 0x20007EA0
@ Spec     : analysis/rotary.md 2
@ -----------------------------------------------------------------------------
FUNC fn_0801472C

@ AC+DC on, 1 kHz filter off, the AC+DC accumulators cleared; 0x200080BC / 0x200080BB follow 0x200080BD (= 0 here)
    movs r0, #1                         @ 0801472C
    ldr r1, =acdc_active                @ 0801472E
    strb r0, [r1]                       @ 08014732
    movs r0, #0                         @ 08014734
    ldr r1, =filter_1khz                @ 08014736
    strb r0, [r1]                       @ 0801473A
    movs r0, #0                         @ 0801473C
    ldr r1, =v_20007E60                 @ 0801473E
    str r0, [r1]                        @ 08014742
    movs r0, #0                         @ 08014744
    ldr r1, =v_200080A0                 @ 08014746
    strb r0, [r1]                       @ 0801474A
    movs r0, #0                         @ 0801474C
    ldr r1, =acdc_use_dcv_cal           @ 0801474E
    strb r0, [r1]                       @ 08014752
    ldr r0, =acdc_use_dcv_cal           @ 08014754
    ldrb r0, [r0]                       @ 08014758
    cmp r0, #0                          @ 0801475A
    beq .L801472c_08014768              @ 0801475C
    movs r0, #1                         @ 0801475E
    ldr r1, =v_200080BC                 @ 08014760
    strb r0, [r1]                       @ 08014764
    b .L801472c_08014770                @ 08014766
@ reached from 0801475C beq (equal / zero) after cmp r0, #0
.L801472c_08014768:
    movs r0, #0                         @ 08014768
    ldr r1, =v_200080BC                 @ 0801476A
    strb r0, [r1]                       @ 0801476E
@ reached from 08014766 b (jump)
.L801472c_08014770:
    ldr r0, =v_200080BC                 @ 08014770
    ldrb r0, [r0]                       @ 08014774
    ldr r1, =v_200080BB                 @ 08014776
    strb r0, [r1]                       @ 0801477A
    movs r0, #0                         @ 0801477C
    ldr r1, =v_200080BE                 @ 0801477E
    strb r0, [r1]                       @ 08014782
    movs r0, #0                         @ 08014784
    ldr r1, =v_20007E9C                 @ 08014786
    str r0, [r1]                        @ 0801478A
    movs r0, #0                         @ 0801478C
    ldr r1, =v_20007EA0                 @ 0801478E
    str r0, [r1]                        @ 08014792
    bx lr                               @ 08014794
ENDFUNC fn_0801472C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08014796 - RANGE key (outside DIODE)
@ Replaces : 0x08014796 FUN_08014796 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved: replaces the unused r7 of v2.05)
@ Context  : main (handle_pg8_15_short_press)
@ RAM      : writes meter_range, range_manual, mode_range_req 0x2000804B; reads hold_active, hold_stage2,
@            0x2000808A (calibration mode), range_count
@ Spec     : analysis/keys_setup.md 2.2 (RANGE row)
@ -----------------------------------------------------------------------------
FUNC fn_08014796

@ refused while HOLD is on (either stage)
    push {r4, lr}                       @ 08014796
    ldr r0, =hold_active                @ 08014798
    ldrb r0, [r0]                       @ 0801479C
    ldr r1, =hold_stage2                @ 0801479E
    ldrb r1, [r1]                       @ 080147A2
    orrs r0, r1                         @ 080147A4
    uxtb r0, r0                         @ 080147A6
    cmp r0, #0                          @ 080147A8
    beq .L8014796_080147B2              @ 080147AA
    bl fn_0800EE6C                      @ 080147AC
    b .L8014796_end                     @ 080147B0

@ calibration mode or manual range: step to the next range (wrapping), request the apply, update the VA sub-range
@ flags of the new range (fn_0801485A, MVA); a mode with only one range is refused
@ reached from 080147AA beq (equal / zero) after cmp r0, #0
.L8014796_080147B2:
    ldr r0, =mode_cal_mode              @ 080147B2
    ldrb r0, [r0]                       @ 080147B6
    ldr r1, =range_manual               @ 080147B8
    ldrb r1, [r1]                       @ 080147BC
    orrs r0, r1                         @ 080147BE
    uxtb r0, r0                         @ 080147C0
    cmp r0, #0                          @ 080147C2
    beq .L8014796_auto                  @ 080147C4
    ldr r0, =range_count                @ 080147C6
    ldr r1, =meter_mode                 @ 080147CA
    ldrb r1, [r1]                       @ 080147CE
    ldrb r0, [r0, r1]                   @ 080147D0
    cmp r0, #2                          @ 080147D2
    blt .L8014796_refuse                @ 080147D4
    ldr r0, =meter_range                @ 080147D6
    ldrb r0, [r0]                       @ 080147DA
    adds r0, r0, #1                     @ 080147DC
    ldr r1, =meter_range                @ 080147DE
    strb r0, [r1]                       @ 080147E2
    ldr r0, =meter_range                @ 080147E4
    ldrb r0, [r0]                       @ 080147E8
    ldr r1, =range_count                @ 080147EA
    ldr r2, =meter_mode                 @ 080147EE
    ldrb r2, [r2]                       @ 080147F2
    ldrb r1, [r1, r2]                   @ 080147F4
    cmp r0, r1                          @ 080147F6
    bcc .L8014796_08014802              @ 080147F8
    movs r0, #0                         @ 080147FA
    ldr r1, =meter_range                @ 080147FC
    strb r0, [r1]                       @ 08014800
@ reached from 080147F8 bcc (unsigned <) after cmp r0, r1
.L8014796_08014802:
    movs r0, #1                         @ 08014802
    ldr r1, =mode_range_req             @ 08014804
    strb r0, [r1]                       @ 08014808
    ldr r0, =meter_range                @ 0801480A
    ldrb r1, [r0]                       @ 0801480E
    ldr r0, =meter_mode                 @ 08014810
    ldrb r0, [r0]                       @ 08014814
    bl fn_0801485A                      @ 08014816
    bl fn_0800EE50                      @ 0801481A
    b .L8014796_end                     @ 0801481E
@ reached from 080147D4 blt (signed <) after cmp r0, #2
.L8014796_refuse:
    bl fn_0800EE6C                      @ 08014820
    b .L8014796_end                     @ 08014824

@ automatic range, not calibration mode: freeze the present range (range_manual = 1); a single-range mode is refused
@ reached from 080147C4 beq (equal / zero) after cmp r0, #0
.L8014796_auto:
    ldr r0, =range_count                @ 08014826
    ldr r1, =meter_mode                 @ 0801482A
    ldrb r1, [r1]                       @ 0801482E
    ldrb r0, [r0, r1]                   @ 08014830
    cmp r0, #2                          @ 08014832
    blt .L8014796_08014854              @ 08014834
    ldr r0, =range_manual               @ 08014836
    ldrb r0, [r0]                       @ 0801483A
    cmp r0, #0                          @ 0801483C
    bne .L8014796_0801484E              @ 0801483E
    movs r0, #1                         @ 08014840
    ldr r1, =range_manual               @ 08014842
    strb r0, [r1]                       @ 08014846
    movs r0, #1                         @ 08014848
    bl fn_08019D68                      @ 0801484A
@ reached from 0801483E bne (not equal / non-zero) after cmp r0, #0
.L8014796_0801484E:
    bl fn_0800EE50                      @ 0801484E
    b .L8014796_end                     @ 08014852
@ reached from 08014834 blt (signed <) after cmp r0, #2
.L8014796_08014854:
    bl fn_0800EE6C                      @ 08014854
@ reached from 080147B0 b (jump)
@              and from 0801481E b (jump)
@              and from 08014824 b (jump)
@              and from 08014852 b (jump)
.L8014796_end:
    pop {r4, pc}                        @ 08014858
ENDFUNC fn_08014796
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08006774 - re-apply the HY3131 row, calibration and pins for ACV range 0 (arg 1) or for the present mode
@ Replaces : 0x08006774 FUN_08006774 (v2.05)
@ In       : r0 = 0 present mode and range, else ACV range 0
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main (MAC burden alternation, SET)
@ Spec     : analysis/hy3131_modes_ac_current.md (burden alternation)
@ -----------------------------------------------------------------------------
FUNC fn_08006774

@ argument non-zero: the ACV range-0 configuration, calibration record and pins; zero: those of the present mode
    push {r4, lr}                       @ 08006774
    movs r4, r0                         @ 08006776
    uxtb r4, r4                         @ 08006778
    cmp r4, #0                          @ 0800677A
    beq .L8006774_08006798              @ 0800677C
    movs r1, #0                         @ 0800677E
    movs r0, #2                         @ 08006780
    bl fn_0800B974                      @ 08006782
    movs r1, #0                         @ 08006786
    movs r0, #2                         @ 08006788
    bl load_cal_record_from_eeprom      @ 0800678A
    movs r1, #0                         @ 0800678E
    movs r0, #2                         @ 08006790
    bl fn_0800FBE8                      @ 08006792
    b .L8006774_080067C8                @ 08006796
@ reached from 0800677C beq (equal / zero) after cmp r4, #0
.L8006774_08006798:
    ldr r0, =meter_range                @ 08006798
    ldrb r1, [r0]                       @ 0800679C
    ldr r0, =meter_mode                 @ 0800679E
    ldrb r0, [r0]                       @ 080067A2
    bl fn_0800B974                      @ 080067A4
    ldr r0, =meter_range                @ 080067A8
    ldrb r1, [r0]                       @ 080067AC
    ldr r0, =meter_mode                 @ 080067AE
    ldrb r0, [r0]                       @ 080067B2
    bl load_cal_record_from_eeprom      @ 080067B4
    ldr r0, =meter_range                @ 080067B8
    ldrb r1, [r0]                       @ 080067BC
    ldr r0, =meter_mode                 @ 080067BE
    ldrb r0, [r0]                       @ 080067C2
    bl fn_0800FBE8                      @ 080067C4

@ the settle count of the new configuration (fn_0800DB48, which also resets AR), then 0x20007FC2 = 0
@ reached from 08006796 b (jump)
.L8006774_080067C8:
    bl fn_0800DB48                      @ 080067C8
    movs r0, #0                         @ 080067CC
    ldr r1, =v_20007FC2                 @ 080067CE
    strh r0, [r1]                       @ 080067D2
    pop {r4, pc}                        @ 080067D4
ENDFUNC fn_08006774
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080080C8 - re-apply the HY3131 row, calibration and pins for DCV range 0 (arg non-zero) or for the present mode
@ Replaces : 0x080080C8 FUN_080080C8 (v2.05)
@ In       : r0 = 0 present mode and range, else DCV range 0
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4, r5 saved; r3 is stack padding)
@ Context  : main (MDC, SET: burden-voltage re-apply)
@ Spec     : analysis/hy3131_modes_ac_current.md (burden alternation)
@ -----------------------------------------------------------------------------
FUNC fn_080080C8

@ r5 = 0 (range 0).  Argument non-zero: DCV range 0 configuration, calibration record and pins; zero: the present ones
    push {r3, r4, r5, lr}               @ 080080C8
    movs r4, r0                         @ 080080CA
    movs r5, #0                         @ 080080CC
    uxtb r4, r4                         @ 080080CE
    cmp r4, #0                          @ 080080D0
    beq .L80080c8_080080F4              @ 080080D2
    movs r1, r5                         @ 080080D4
    uxtb r1, r1                         @ 080080D6
    movs r0, #1                         @ 080080D8
    bl fn_0800B974                      @ 080080DA
    movs r1, r5                         @ 080080DE
    uxtb r1, r1                         @ 080080E0
    movs r0, #1                         @ 080080E2
    bl load_cal_record_from_eeprom      @ 080080E4
    movs r1, r5                         @ 080080E8
    uxtb r1, r1                         @ 080080EA
    movs r0, #1                         @ 080080EC
    bl fn_0800FBE8                      @ 080080EE
    b .L80080c8_08008124                @ 080080F2
@ reached from 080080D2 beq (equal / zero) after cmp r4, #0
.L80080c8_080080F4:
    ldr r0, =meter_range                @ 080080F4
    ldrb r1, [r0]                       @ 080080F8
    ldr r0, =meter_mode                 @ 080080FA
    ldrb r0, [r0]                       @ 080080FE
    bl fn_0800B974                      @ 08008100
    ldr r0, =meter_range                @ 08008104
    ldrb r1, [r0]                       @ 08008108
    ldr r0, =meter_mode                 @ 0800810A
    ldrb r0, [r0]                       @ 0800810E
    bl load_cal_record_from_eeprom      @ 08008110
    ldr r0, =meter_range                @ 08008114
    ldrb r1, [r0]                       @ 08008118
    ldr r0, =meter_mode                 @ 0800811A
    ldrb r0, [r0]                       @ 0800811E
    bl fn_0800FBE8                      @ 08008120

@ the settle count of the new configuration (fn_0800DB48, which also resets AR)
@ reached from 080080F2 b (jump)
.L80080c8_08008124:
    bl fn_0800DB48                      @ 08008124
    pop {r3, r4, r5, pc}                @ 08008128
ENDFUNC fn_080080C8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019DA2 - is the meter auto-ranging
@ Replaces : 0x08019DA2 FUN_08019DA2 (v2.05)
@ In       : -
@ Out      : r0 = 1 auto-range active (AUTO annunciator lit by fn_08019D68), 0 otherwise
@ Clobbers : r1, r2, flags
@ Context  : main (LCD annunciators, BLE status packet)
@ RAM      : reads 0x2000808A, 0x20007FE1, hold_stage2, meter_mode, range_manual
@ Spec     : analysis/lcd_map.md 4.2 (AUTO annunciator)
@ -----------------------------------------------------------------------------
FUNC fn_08019DA2

@ r0 = 0.  Calibration mode: not auto.  Logging active and HOLD stage 2 off: not auto
    movs r0, #0                         @ 08019DA2
    ldr r1, =mode_cal_mode              @ 08019DA4
    ldrb r1, [r1]                       @ 08019DA8
    cmp r1, #0                          @ 08019DAA
    beq .L8019da2_08019DB4              @ 08019DAC
    movs r1, #0                         @ 08019DAE
    movs r0, r1                         @ 08019DB0
    b .L8019da2_08019E1A                @ 08019DB2
@ reached from 08019DAC beq (equal / zero) after cmp r1, #0
.L8019da2_08019DB4:
    ldr r1, =mode_logging               @ 08019DB4
    ldrb r1, [r1]                       @ 08019DB8
    ldr r2, =hold_stage2                @ 08019DBA
    ldrb r2, [r2]                       @ 08019DBE
    eors r2, r2, #1                     @ 08019DC0
    tst r1, r2                          @ 08019DC4
    beq .L8019da2_08019DCE              @ 08019DC6
    movs r1, #0                         @ 08019DC8
    movs r0, r1                         @ 08019DCA
    b .L8019da2_08019E1A                @ 08019DCC

@ modes without ranges (DIODE, BEEP, TEMP, LowZ, DUTY) are not auto; otherwise auto unless the range is manual
@ reached from 08019DC6 beq (equal / zero) after tst r1, r2
.L8019da2_08019DCE:
    ldr r1, =meter_mode                 @ 08019DCE
    ldrb r1, [r1]                       @ 08019DD2
    cmp r1, #0xB                        @ 08019DD4 mode 11 DIODE
    beq .L8019da2_08019E00              @ 08019DD6
    ldr r1, =meter_mode                 @ 08019DD8
    ldrb r1, [r1]                       @ 08019DDC
    cmp r1, #0xA                        @ 08019DDE mode 10 BEEP
    beq .L8019da2_08019E00              @ 08019DE0
    ldr r1, =meter_mode                 @ 08019DE2
    ldrb r1, [r1]                       @ 08019DE6
    cmp r1, #5                          @ 08019DE8 mode 5 TEMP
    beq .L8019da2_08019E00              @ 08019DEA
    ldr r1, =meter_mode                 @ 08019DEC
    ldrb r1, [r1]                       @ 08019DF0
    cmp r1, #0                          @ 08019DF2 mode 0 LowZ
    beq .L8019da2_08019E00              @ 08019DF4
    ldr r1, =meter_mode                 @ 08019DF6
    ldrb r1, [r1]                       @ 08019DFA
    cmp r1, #8                          @ 08019DFC mode 8 DUTY
    bne .L8019da2_08019E06              @ 08019DFE
@ reached from 08019DD6 beq (equal / zero) after cmp r1, #0xB
@              and from 08019DE0 beq (equal / zero) after cmp r1, #0xA
@              and from 08019DEA beq (equal / zero) after cmp r1, #5
@              and from 08019DF4 beq (equal / zero) after cmp r1, #0
.L8019da2_08019E00:
    movs r1, #0                         @ 08019E00
    movs r0, r1                         @ 08019E02
    b .L8019da2_08019E1A                @ 08019E04
@ reached from 08019DFE bne (not equal / non-zero) after cmp r1, #8
.L8019da2_08019E06:
    ldr r1, =range_manual               @ 08019E06
    ldrb r1, [r1]                       @ 08019E0A
    cmp r1, #0                          @ 08019E0C
    beq .L8019da2_08019E16              @ 08019E0E
    movs r1, #0                         @ 08019E10
    movs r0, r1                         @ 08019E12
    b .L8019da2_08019E1A                @ 08019E14
@ reached from 08019E0E beq (equal / zero) after cmp r1, #0
.L8019da2_08019E16:
    movs r1, #1                         @ 08019E16
    movs r0, r1                         @ 08019E18
@ reached from 08019DB2 b (jump)
@              and from 08019DCC b (jump)
@              and from 08019E04 b (jump)
@              and from 08019E14 b (jump)
.L8019da2_08019E1A:
    uxtb r0, r0                         @ 08019E1A
    bx lr                               @ 08019E1C
ENDFUNC fn_08019DA2
    .ltorg
