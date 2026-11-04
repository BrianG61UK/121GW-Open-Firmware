@ =============================================================================
@ annun.s - LCD: annunciator setters and clearers, sub-display units, shadow clear (DESIGN.md 6.7)
@
@ Replaces lcd_set_mode_annunciators 0x080172A8 with its helpers, the status-icon setters 0x08019B48 .. 0x0801A3A4,
@ the sub-display unit setters 0x0801A440 / 0x0801A6D8 / 0x0801A760 and the shadow clear / all-segments routines
@ 0x0801A81C / 0x0801A89C (analysis/lcd_map.md section 4).  The setters named fn_08019xxx(r0 = commit) draw into the
@ shadow and call lcd_commit_shadow when r0 = 1.  The instruction streams are v2.05's except fn_0801A81C (HW-07, IMP-06).
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

    .section .text.lcd.annun, "ax", %progbits

@ -----------------------------------------------------------------------------
@ lcd_set_mode_annunciators - light the unit, AC/DC and mode annunciators of one mode
@ Replaces : 0x080172A8 lcd_set_mode_annunciators (v2.05, 1112 bytes)
@ In       : r0 = mode 0..24, r1 = range, r2 = LowZ AC/DC state (0x20008098 in the live call), r3 = LowZ decided flag
@            (0x20008099 in the live call); modes 5 and above 24 light nothing here
@ Out      : -   (clears 0x2000804C, the annunciator refresh request)
@ Context  : main only
@ RAM      : writes 0x2000804C = 0; read-modify-writes lcd_shadow words 0, 1, 2, 4, 5, 6 (unit and mode elements)
@ Spec     : analysis/lcd_map.md 4.1 (element per mode); the caller clears the group first with fn_08019B48
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC lcd_set_mode_annunciators
    push {r3, r4, r5, r6, r7, lr}            @ 080172A8
    movs r4, r0                              @ 080172AA
    movs r5, r1                              @ 080172AC
    movs r6, r2                              @ 080172AE
    movs r7, r3                              @ 080172B0
    @ r4 = mode, r5 = range, r6 = LowZ AC/DC state, r7 = LowZ decided flag
    movs r0, #0                              @ 080172B2
    ldr r1, =v_2000804C                      @ 080172B4 &annunciator refresh request (VA modes)
    strb r0, [r1, #0]                        @ 080172B8
    uxtb r4, r4                              @ 080172BA
    movs r0, r4                              @ 080172BC
    @ dispatch on the mode (cases 0..4, 6..24 in ascending order of the compares; targets as listed in lcd_map.md 4.1)
    cmp r0, #0                               @ 080172BE
    beq .L0801734E                           @ 080172C0
    cmp r0, #1                               @ 080172C2
    beq .L08017426                           @ 080172C4
    cmp r0, #2                               @ 080172C8
    beq .L080173D0                           @ 080172CA
    cmp r0, #3                               @ 080172CE
    beq .L08017438                           @ 080172D0
    cmp r0, #4                               @ 080172D4
    beq .L080173E2                           @ 080172D6
    cmp r0, #6                               @ 080172DA
    beq .L0801745A                           @ 080172DC
    cmp r0, #7                               @ 080172E0
    beq .L08017464                           @ 080172E2
    cmp r0, #8                               @ 080172E6
    beq .L08017476                           @ 080172E8
    cmp r0, #9                               @ 080172EC
    beq .L080174B4                           @ 080172EE
    cmp r0, #10                              @ 080172F2
    beq .L08017492                           @ 080172F4
    cmp r0, #11                              @ 080172F8
    beq .L08017404                           @ 080172FA
    cmp r0, #12                              @ 080172FE
    beq .L08017488                           @ 08017300
    cmp r0, #13                              @ 08017304
    beq .L080174BE                           @ 08017306
    cmp r0, #14                              @ 0801730A
    beq .L08017500                           @ 0801730C
    cmp r0, #15                              @ 08017310
    beq .L08017542                           @ 08017312
    cmp r0, #16                              @ 08017316
    beq .L08017656                           @ 08017318
    cmp r0, #17                              @ 0801731C
    beq .L080176AC                           @ 0801731E
    cmp r0, #18                              @ 08017322
    beq .L08017672                           @ 08017324
    cmp r0, #19                              @ 08017328
    beq .L080176C6                           @ 0801732A
    cmp r0, #20                              @ 0801732E
    beq .L0801768C                           @ 08017330
    cmp r0, #21                              @ 08017334
    beq .L080176E0                           @ 08017336
    cmp r0, #22                              @ 0801733A
    beq .L0801758A                           @ 0801733C
    cmp r0, #23                              @ 08017340
    beq .L080175CC                           @ 08017342
    cmp r0, #24                              @ 08017346
    beq .L0801760E                           @ 08017348
    b .L080176FE                             @ 0801734C
.L0801734E:                                @ reached from 080172C0 beq (equal / zero)
    @ mode 0 (LowZ): AC/DC indication from r6 / r7, then LowZ and V
    ldr r0, =lcd_shadow                      @ 0801734E &LCD shadow
    ldr r0, [r0, #12]                        @ 08017352
    lsrs r0, r0, #1                          @ 08017354
    lsls r0, r0, #1                          @ 08017356
    ldr r1, =lcd_shadow                      @ 08017358 &LCD shadow
    str r0, [r1, #12]                        @ 0801735C w3 &= ~0x1: clears AC_DC+
    uxtb r7, r7                              @ 0801735E
    cmp r7, #0                               @ 08017360
    bne .L08017386                           @ 08017362
    ldr r0, =lcd_shadow                      @ 08017364 &LCD shadow
    ldr r0, [r0, #20]                        @ 08017368
    lsrs r0, r0, #1                          @ 0801736A
    lsls r0, r0, #1                          @ 0801736C
    ldr r1, =lcd_shadow                      @ 0801736E &LCD shadow
    str r0, [r1, #20]                        @ 08017372 w5 &= ~0x1: clears DC
    ldr r0, =lcd_shadow                      @ 08017374 &LCD shadow
    ldr r0, [r0, #4]                         @ 08017378
    lsrs r0, r0, #1                          @ 0801737A
    lsls r0, r0, #1                          @ 0801737C
    ldr r1, =lcd_shadow                      @ 0801737E &LCD shadow
    str r0, [r1, #4]                         @ 08017382 w1 &= ~0x1: clears AC
    b .L080173AE                             @ 08017384
.L08017386:                                @ reached from 08017362 bne (not equal / non-zero)
    uxtb r6, r6                              @ 08017386
    cmp r6, #0                               @ 08017388
    beq .L0801739E                           @ 0801738A
    ldr r0, =lcd_shadow                      @ 0801738C &LCD shadow
    ldr r0, [r0, #4]                         @ 08017390
    orrs.w r0, r0, #1                        @ 08017392
    ldr r1, =lcd_shadow                      @ 08017396 &LCD shadow
    str r0, [r1, #4]                         @ 0801739A w1 |= 0x1: AC
    b .L080173AE                             @ 0801739C
.L0801739E:                                @ reached from 0801738A beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801739E &LCD shadow
    ldr r0, [r0, #20]                        @ 080173A2
    orrs.w r0, r0, #1                        @ 080173A4
    ldr r1, =lcd_shadow                      @ 080173A8 &LCD shadow
    str r0, [r1, #20]                        @ 080173AC w5 |= 0x1: DC
.L080173AE:                                @ reached from 08017384 b; 0801739C b; falls in
    ldr r0, =lcd_shadow                      @ 080173AE &LCD shadow
    ldr r0, [r0, #0]                         @ 080173B2
    orrs.w r0, r0, #1073741824               @ 080173B4
    ldr r1, =lcd_shadow                      @ 080173B8 &LCD shadow
    str r0, [r1, #0]                         @ 080173BC w0 |= 0x40000000: LowZ
    ldr r0, =lcd_shadow                      @ 080173BE &LCD shadow
    ldr r0, [r0, #16]                        @ 080173C2
    orrs.w r0, r0, #1024                     @ 080173C4
    ldr r1, =lcd_shadow                      @ 080173C8 &LCD shadow
    str r0, [r1, #16]                        @ 080173CC w4 |= 0x400: V
    b .L080176FE                             @ 080173CE
.L080173D0:                                @ reached from 080172CA beq (equal / zero)
    @ mode 2 (ACV): V
    ldr r0, =lcd_shadow                      @ 080173D0 &LCD shadow
    ldr r0, [r0, #16]                        @ 080173D4
    orrs.w r0, r0, #1024                     @ 080173D6
    ldr r1, =lcd_shadow                      @ 080173DA &LCD shadow
    str r0, [r1, #16]                        @ 080173DE w4 |= 0x400: V
    b .L080176FE                             @ 080173E0
.L080173E2:                                @ reached from 080172D6 beq (equal / zero)
    @ mode 4 (ACmV): m prefix and V
    ldr r0, =lcd_shadow                      @ 080173E2 &LCD shadow
    ldr r0, [r0, #8]                         @ 080173E6
    orrs.w r0, r0, #1024                     @ 080173E8
    ldr r1, =lcd_shadow                      @ 080173EC &LCD shadow
    str r0, [r1, #8]                         @ 080173F0 w2 |= 0x400: m prefix
    ldr r0, =lcd_shadow                      @ 080173F2 &LCD shadow
    ldr r0, [r0, #16]                        @ 080173F6
    orrs.w r0, r0, #1024                     @ 080173F8
    ldr r1, =lcd_shadow                      @ 080173FC &LCD shadow
    str r0, [r1, #16]                        @ 08017400 w4 |= 0x400: V
    b .L080176FE                             @ 08017402
.L08017404:                                @ reached from 080172FA beq (equal / zero)
    @ mode 11 (DIODE): V and the Diode symbol
    ldr r0, =lcd_shadow                      @ 08017404 &LCD shadow
    ldr r0, [r0, #24]                        @ 08017408
    orrs.w r0, r0, #2147483648               @ 0801740A
    ldr r1, =lcd_shadow                      @ 0801740E &LCD shadow
    str r0, [r1, #24]                        @ 08017412 w6 |= 0x80000000: Diode
    ldr r0, =lcd_shadow                      @ 08017414 &LCD shadow
    ldr r0, [r0, #16]                        @ 08017418
    orrs.w r0, r0, #1024                     @ 0801741A
    ldr r1, =lcd_shadow                      @ 0801741E &LCD shadow
    str r0, [r1, #16]                        @ 08017422 w4 |= 0x400: V
    b .L080176FE                             @ 08017424
.L08017426:                                @ reached from 080172C4 beq (equal / zero)
    @ mode 1 (DCV): V
    ldr r0, =lcd_shadow                      @ 08017426 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801742A
    orrs.w r0, r0, #1024                     @ 0801742C
    ldr r1, =lcd_shadow                      @ 08017430 &LCD shadow
    str r0, [r1, #16]                        @ 08017434 w4 |= 0x400: V
    b .L080176FE                             @ 08017436
.L08017438:                                @ reached from 080172D0 beq (equal / zero)
    @ mode 3 (DCmV): m prefix and V
    ldr r0, =lcd_shadow                      @ 08017438 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801743C
    orrs.w r0, r0, #1024                     @ 0801743E
    ldr r1, =lcd_shadow                      @ 08017442 &LCD shadow
    str r0, [r1, #8]                         @ 08017446 w2 |= 0x400: m prefix
    ldr r0, =lcd_shadow                      @ 08017448 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801744C
    orrs.w r0, r0, #1024                     @ 0801744E
    ldr r1, =lcd_shadow                      @ 08017452 &LCD shadow
    str r0, [r1, #16]                        @ 08017456 w4 |= 0x400: V
    b .L080176FE                             @ 08017458
.L0801745A:                                @ reached from 080172DC beq (equal / zero)
    @ mode 6 (FREQ): Hz and the k / M prefix by range (fn_08017858)
    movs r0, r5                              @ 0801745A
    uxtb r0, r0                              @ 0801745C
    bl fn_08017858                           @ 0801745E
    b .L080176FE                             @ 08017462
.L08017464:                                @ reached from 080172E2 beq (equal / zero)
    @ mode 7 (PULSE): ms
    ldr r0, =lcd_shadow                      @ 08017464 &LCD shadow
    ldr r0, [r0, #24]                        @ 08017468
    orrs.w r0, r0, #1                        @ 0801746A
    ldr r1, =lcd_shadow                      @ 0801746E &LCD shadow
    str r0, [r1, #24]                        @ 08017472 w6 |= 0x1: ms
    b .L080176FE                             @ 08017474
.L08017476:                                @ reached from 080172E8 beq (equal / zero)
    @ mode 8 (DUTY): %
    ldr r0, =lcd_shadow                      @ 08017476 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801747A
    orrs.w r0, r0, #131072                   @ 0801747C
    ldr r1, =lcd_shadow                      @ 08017480 &LCD shadow
    str r0, [r1, #0]                         @ 08017484 w0 |= 0x20000: % (duty)
    b .L080176FE                             @ 08017486
.L08017488:                                @ reached from 08017300 beq (equal / zero)
    @ mode 12 (CAP): n or u prefix by range and F (fn_080177AC)
    movs r0, r5                              @ 08017488
    uxtb r0, r0                              @ 0801748A
    bl fn_080177AC                           @ 0801748C
    b .L080176FE                             @ 08017490
.L08017492:                                @ reached from 080172F4 beq (equal / zero)
    @ mode 10 (BEEP): Ohm and the Beep symbol
    ldr r0, =lcd_shadow                      @ 08017492 &LCD shadow
    ldr r0, [r0, #16]                        @ 08017496
    orrs.w r0, r0, #2147483648               @ 08017498
    ldr r1, =lcd_shadow                      @ 0801749C &LCD shadow
    str r0, [r1, #16]                        @ 080174A0 w4 |= 0x80000000: Beep
    ldr r0, =lcd_shadow                      @ 080174A2 &LCD shadow
    ldr r0, [r0, #8]                         @ 080174A6
    orrs.w r0, r0, #256                      @ 080174A8
    ldr r1, =lcd_shadow                      @ 080174AC &LCD shadow
    str r0, [r1, #8]                         @ 080174B0 w2 |= 0x100: Ohm
    b .L080176FE                             @ 080174B2
.L080174B4:                                @ reached from 080172EE beq (equal / zero)
    @ mode 9 (OHM): Ohm and the k / M prefix by range (fn_080177F2)
    movs r0, r5                              @ 080174B4
    uxtb r0, r0                              @ 080174B6
    bl fn_080177F2                           @ 080174B8
    b .L080176FE                             @ 080174BC
.L080174BE:                                @ reached from 08017306 beq (equal / zero)
    @ mode 13 (uVA): u, AC, V and A
    ldr r0, =lcd_shadow                      @ 080174BE &LCD shadow
    ldr r0, [r0, #0]                         @ 080174C2
    orrs.w r0, r0, #512                      @ 080174C4
    ldr r1, =lcd_shadow                      @ 080174C8 &LCD shadow
    str r0, [r1, #0]                         @ 080174CC w0 |= 0x200: u (micro)
    ldr r0, =lcd_shadow                      @ 080174CE &LCD shadow
    ldr r0, [r0, #16]                        @ 080174D2
    orrs.w r0, r0, #1024                     @ 080174D4
    ldr r1, =lcd_shadow                      @ 080174D8 &LCD shadow
    str r0, [r1, #16]                        @ 080174DC w4 |= 0x400: V
    ldr r0, =lcd_shadow                      @ 080174DE &LCD shadow
    ldr r0, [r0, #24]                        @ 080174E2
    orrs.w r0, r0, #1024                     @ 080174E4
    ldr r1, =lcd_shadow                      @ 080174E8 &LCD shadow
    str r0, [r1, #24]                        @ 080174EC w6 |= 0x400: A
    ldr r0, =lcd_shadow                      @ 080174EE &LCD shadow
    ldr r0, [r0, #4]                         @ 080174F2
    orrs.w r0, r0, #1                        @ 080174F4
    ldr r1, =lcd_shadow                      @ 080174F8 &LCD shadow
    str r0, [r1, #4]                         @ 080174FC w1 |= 0x1: AC
    b .L080176FE                             @ 080174FE
.L08017500:                                @ reached from 0801730C beq (equal / zero)
    @ mode 14 (mVA): AC, m prefix, V and A
    ldr r0, =lcd_shadow                      @ 08017500 &LCD shadow
    ldr r0, [r0, #8]                         @ 08017504
    orrs.w r0, r0, #1024                     @ 08017506
    ldr r1, =lcd_shadow                      @ 0801750A &LCD shadow
    str r0, [r1, #8]                         @ 0801750E w2 |= 0x400: m prefix
    ldr r0, =lcd_shadow                      @ 08017510 &LCD shadow
    ldr r0, [r0, #16]                        @ 08017514
    orrs.w r0, r0, #1024                     @ 08017516
    ldr r1, =lcd_shadow                      @ 0801751A &LCD shadow
    str r0, [r1, #16]                        @ 0801751E w4 |= 0x400: V
    ldr r0, =lcd_shadow                      @ 08017520 &LCD shadow
    ldr r0, [r0, #24]                        @ 08017524
    orrs.w r0, r0, #1024                     @ 08017526
    ldr r1, =lcd_shadow                      @ 0801752A &LCD shadow
    str r0, [r1, #24]                        @ 0801752E w6 |= 0x400: A
    ldr r0, =lcd_shadow                      @ 08017530 &LCD shadow
    ldr r0, [r0, #4]                         @ 08017534
    orrs.w r0, r0, #1                        @ 08017536
    ldr r1, =lcd_shadow                      @ 0801753A &LCD shadow
    str r0, [r1, #4]                         @ 0801753E w1 |= 0x1: AC
    b .L080176FE                             @ 08017540
.L08017542:                                @ reached from 08017312 beq (equal / zero)
    @ mode 15 (VA): AC, V and A; m prefix inline for ranges below 2
    uxtb r5, r5                              @ 08017542
    cmp r5, #2                               @ 08017544
    bge .L08017558                           @ 08017546
    ldr r0, =lcd_shadow                      @ 08017548 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801754C
    orrs.w r0, r0, #1024                     @ 0801754E
    ldr r1, =lcd_shadow                      @ 08017552 &LCD shadow
    str r0, [r1, #8]                         @ 08017556 w2 |= 0x400: m prefix
.L08017558:                                @ reached from 08017546 bge (signed >=); falls in
    ldr r0, =lcd_shadow                      @ 08017558 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801755C
    orrs.w r0, r0, #1024                     @ 0801755E
    ldr r1, =lcd_shadow                      @ 08017562 &LCD shadow
    str r0, [r1, #16]                        @ 08017566 w4 |= 0x400: V
    ldr r0, =lcd_shadow                      @ 08017568 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801756C
    orrs.w r0, r0, #1024                     @ 0801756E
    ldr r1, =lcd_shadow                      @ 08017572 &LCD shadow
    str r0, [r1, #24]                        @ 08017576 w6 |= 0x400: A
    ldr r0, =lcd_shadow                      @ 08017578 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801757C
    orrs.w r0, r0, #1                        @ 0801757E
    ldr r1, =lcd_shadow                      @ 08017582 &LCD shadow
    str r0, [r1, #4]                         @ 08017586 w1 |= 0x1: AC
    b .L080176FE                             @ 08017588
.L0801758A:                                @ reached from 0801733C beq (equal / zero)
    @ mode 22 (DCuVA): u, DC, V and A
    ldr r0, =lcd_shadow                      @ 0801758A &LCD shadow
    ldr r0, [r0, #0]                         @ 0801758E
    orrs.w r0, r0, #512                      @ 08017590
    ldr r1, =lcd_shadow                      @ 08017594 &LCD shadow
    str r0, [r1, #0]                         @ 08017598 w0 |= 0x200: u (micro)
    ldr r0, =lcd_shadow                      @ 0801759A &LCD shadow
    ldr r0, [r0, #16]                        @ 0801759E
    orrs.w r0, r0, #1024                     @ 080175A0
    ldr r1, =lcd_shadow                      @ 080175A4 &LCD shadow
    str r0, [r1, #16]                        @ 080175A8 w4 |= 0x400: V
    ldr r0, =lcd_shadow                      @ 080175AA &LCD shadow
    ldr r0, [r0, #24]                        @ 080175AE
    orrs.w r0, r0, #1024                     @ 080175B0
    ldr r1, =lcd_shadow                      @ 080175B4 &LCD shadow
    str r0, [r1, #24]                        @ 080175B8 w6 |= 0x400: A
    ldr r0, =lcd_shadow                      @ 080175BA &LCD shadow
    ldr r0, [r0, #20]                        @ 080175BE
    orrs.w r0, r0, #1                        @ 080175C0
    ldr r1, =lcd_shadow                      @ 080175C4 &LCD shadow
    str r0, [r1, #20]                        @ 080175C8 w5 |= 0x1: DC
    b .L080176FE                             @ 080175CA
.L080175CC:                                @ reached from 08017342 beq (equal / zero)
    @ mode 23 (DCmVA): m prefix, DC, V and A
    ldr r0, =lcd_shadow                      @ 080175CC &LCD shadow
    ldr r0, [r0, #8]                         @ 080175D0
    orrs.w r0, r0, #1024                     @ 080175D2
    ldr r1, =lcd_shadow                      @ 080175D6 &LCD shadow
    str r0, [r1, #8]                         @ 080175DA w2 |= 0x400: m prefix
    ldr r0, =lcd_shadow                      @ 080175DC &LCD shadow
    ldr r0, [r0, #16]                        @ 080175E0
    orrs.w r0, r0, #1024                     @ 080175E2
    ldr r1, =lcd_shadow                      @ 080175E6 &LCD shadow
    str r0, [r1, #16]                        @ 080175EA w4 |= 0x400: V
    ldr r0, =lcd_shadow                      @ 080175EC &LCD shadow
    ldr r0, [r0, #24]                        @ 080175F0
    orrs.w r0, r0, #1024                     @ 080175F2
    ldr r1, =lcd_shadow                      @ 080175F6 &LCD shadow
    str r0, [r1, #24]                        @ 080175FA w6 |= 0x400: A
    ldr r0, =lcd_shadow                      @ 080175FC &LCD shadow
    ldr r0, [r0, #20]                        @ 08017600
    orrs.w r0, r0, #1                        @ 08017602
    ldr r1, =lcd_shadow                      @ 08017606 &LCD shadow
    str r0, [r1, #20]                        @ 0801760A w5 |= 0x1: DC
    b .L080176FE                             @ 0801760C
.L0801760E:                                @ reached from 08017348 beq (equal / zero)
    @ mode 24 (DCVA): DC, V and A; m prefix inline for ranges below 2
    uxtb r5, r5                              @ 0801760E
    cmp r5, #2                               @ 08017610
    bge .L08017624                           @ 08017612
    ldr r0, =lcd_shadow                      @ 08017614 &LCD shadow
    ldr r0, [r0, #8]                         @ 08017618
    orrs.w r0, r0, #1024                     @ 0801761A
    ldr r1, =lcd_shadow                      @ 0801761E &LCD shadow
    str r0, [r1, #8]                         @ 08017622 w2 |= 0x400: m prefix
.L08017624:                                @ reached from 08017612 bge (signed >=); falls in
    ldr r0, =lcd_shadow                      @ 08017624 &LCD shadow
    ldr r0, [r0, #16]                        @ 08017628
    orrs.w r0, r0, #1024                     @ 0801762A
    ldr r1, =lcd_shadow                      @ 0801762E &LCD shadow
    str r0, [r1, #16]                        @ 08017632 w4 |= 0x400: V
    ldr r0, =lcd_shadow                      @ 08017634 &LCD shadow
    ldr r0, [r0, #24]                        @ 08017638
    orrs.w r0, r0, #1024                     @ 0801763A
    ldr r1, =lcd_shadow                      @ 0801763E &LCD shadow
    str r0, [r1, #24]                        @ 08017642 w6 |= 0x400: A
    ldr r0, =lcd_shadow                      @ 08017644 &LCD shadow
    ldr r0, [r0, #20]                        @ 08017648
    orrs.w r0, r0, #1                        @ 0801764A
    ldr r1, =lcd_shadow                      @ 0801764E &LCD shadow
    str r0, [r1, #20]                        @ 08017652 w5 |= 0x1: DC
    b .L080176FE                             @ 08017654
.L08017656:                                @ reached from 08017318 beq (equal / zero)
    @ mode 16 (ACuA): u, AC, A
    ldr r0, =lcd_shadow                      @ 08017656 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801765A
    orrs.w r0, r0, #512                      @ 0801765C
    ldr r1, =lcd_shadow                      @ 08017660 &LCD shadow
    str r0, [r1, #0]                         @ 08017662 w0 |= 0x200: u (micro)
    ldr r0, =lcd_shadow                      @ 08017664 &LCD shadow
    ldr r0, [r0, #24]                        @ 08017666
    orrs.w r0, r0, #1024                     @ 08017668
    ldr r1, =lcd_shadow                      @ 0801766C &LCD shadow
    str r0, [r1, #24]                        @ 0801766E w6 |= 0x400: A
    b .L080176FE                             @ 08017670
.L08017672:                                @ reached from 08017324 beq (equal / zero)
    @ mode 18 (ACmA): m prefix, AC, A
    ldr r0, =lcd_shadow                      @ 08017672 &LCD shadow
    ldr r0, [r0, #8]                         @ 08017674
    orrs.w r0, r0, #1024                     @ 08017676
    ldr r1, =lcd_shadow                      @ 0801767A &LCD shadow
    str r0, [r1, #8]                         @ 0801767C w2 |= 0x400: m prefix
    ldr r0, =lcd_shadow                      @ 0801767E &LCD shadow
    ldr r0, [r0, #24]                        @ 08017680
    orrs.w r0, r0, #1024                     @ 08017682
    ldr r1, =lcd_shadow                      @ 08017686 &LCD shadow
    str r0, [r1, #24]                        @ 08017688 w6 |= 0x400: A
    b .L080176FE                             @ 0801768A
.L0801768C:                                @ reached from 08017330 beq (equal / zero)
    @ mode 20 (ACA): AC, A; m prefix at range 0
    uxtb r5, r5                              @ 0801768C
    cmp r5, #0                               @ 0801768E
    bne .L0801769E                           @ 08017690
    ldr r0, =lcd_shadow                      @ 08017692 &LCD shadow
    ldr r0, [r0, #8]                         @ 08017694
    orrs.w r0, r0, #1024                     @ 08017696
    ldr r1, =lcd_shadow                      @ 0801769A &LCD shadow
    str r0, [r1, #8]                         @ 0801769C w2 |= 0x400: m prefix
.L0801769E:                                @ reached from 08017690 bne (not equal / non-zero); falls in
    ldr r0, =lcd_shadow                      @ 0801769E &LCD shadow
    ldr r0, [r0, #24]                        @ 080176A0
    orrs.w r0, r0, #1024                     @ 080176A2
    ldr r1, =lcd_shadow                      @ 080176A6 &LCD shadow
    str r0, [r1, #24]                        @ 080176A8 w6 |= 0x400: A
    b .L080176FE                             @ 080176AA
.L080176AC:                                @ reached from 0801731E beq (equal / zero)
    @ mode 17 (DCuA): u, DC, A
    ldr r0, =lcd_shadow                      @ 080176AC &LCD shadow
    ldr r0, [r0, #0]                         @ 080176AE
    orrs.w r0, r0, #512                      @ 080176B0
    ldr r1, =lcd_shadow                      @ 080176B4 &LCD shadow
    str r0, [r1, #0]                         @ 080176B6 w0 |= 0x200: u (micro)
    ldr r0, =lcd_shadow                      @ 080176B8 &LCD shadow
    ldr r0, [r0, #24]                        @ 080176BA
    orrs.w r0, r0, #1024                     @ 080176BC
    ldr r1, =lcd_shadow                      @ 080176C0 &LCD shadow
    str r0, [r1, #24]                        @ 080176C2 w6 |= 0x400: A
    b .L080176FE                             @ 080176C4
.L080176C6:                                @ reached from 0801732A beq (equal / zero)
    @ mode 19 (DCmA): m prefix, DC, A
    ldr r0, =lcd_shadow                      @ 080176C6 &LCD shadow
    ldr r0, [r0, #8]                         @ 080176C8
    orrs.w r0, r0, #1024                     @ 080176CA
    ldr r1, =lcd_shadow                      @ 080176CE &LCD shadow
    str r0, [r1, #8]                         @ 080176D0 w2 |= 0x400: m prefix
    ldr r0, =lcd_shadow                      @ 080176D2 &LCD shadow
    ldr r0, [r0, #24]                        @ 080176D4
    orrs.w r0, r0, #1024                     @ 080176D6
    ldr r1, =lcd_shadow                      @ 080176DA &LCD shadow
    str r0, [r1, #24]                        @ 080176DC w6 |= 0x400: A
    b .L080176FE                             @ 080176DE
.L080176E0:                                @ reached from 08017336 beq (equal / zero)
    @ mode 21 (DCA): DC, A; m prefix at range 0

    uxtb r5, r5                              @ 080176E0
    cmp r5, #0                               @ 080176E2
    bne .L080176F2                           @ 080176E4
    ldr r0, =lcd_shadow                      @ 080176E6 &LCD shadow
    ldr r0, [r0, #8]                         @ 080176E8
    orrs.w r0, r0, #1024                     @ 080176EA
    ldr r1, =lcd_shadow                      @ 080176EE &LCD shadow
    str r0, [r1, #8]                         @ 080176F0 w2 |= 0x400: m prefix
.L080176F2:                                @ reached from 080176E4 bne (not equal / non-zero); falls in
    ldr r0, =lcd_shadow                      @ 080176F2 &LCD shadow
    ldr r0, [r0, #24]                        @ 080176F4
    orrs.w r0, r0, #1024                     @ 080176F6
    ldr r1, =lcd_shadow                      @ 080176FA &LCD shadow
    str r0, [r1, #24]                        @ 080176FC w6 |= 0x400: A
.L080176FE:                                @ reached from 0801734C b; 080173CE b; 080173E0 b; 08017402 b; 08017424 b; 08017436 b; 08017458 b; 08017462 b; 08017474 b; 08017486 b; 08017490 b; 080174B2 b; 080174BC b; 080174FE b; 08017540 b; 08017588 b; 080175CA b; 0801760C b; 08017654 b; 08017670 b; 0801768A b; 080176AA b; 080176C4 b; 080176DE b; falls in
    pop {r0, r4, r5, r6, r7, pc}             @ 080176FE
ENDFUNC lcd_set_mode_annunciators
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08017700 - milli prefix for the VA modes 15 and 24 (same rule as the inline code of lcd_set_mode_annunciators)
@ Replaces : 0x08017700 FUN_08017700 (v2.05, 46 bytes)
@ In       : r0 = mode, r1 = range
@ Out      : -
@ Context  : main only; called by MVA (DESIGN.md Appendix C.1)
@ RAM      : lcd_shadow word 2 (bit 10, the "m" prefix)
@ Spec     : analysis/lcd_map.md 4.1: for mode 15 or 24 the prefix is set when range < 2 and cleared otherwise; other modes untouched
@
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08017700
    uxtb r0, r0                              @ 08017700
    cmp r0, #24                              @ 08017702
    beq .L0801770C                           @ 08017704
    uxtb r0, r0                              @ 08017706
    cmp r0, #15                              @ 08017708
    bne .L0801772C                           @ 0801770A
.L0801770C:                                @ reached from 08017704 beq (equal / zero); falls in
    uxtb r1, r1                              @ 0801770C
    cmp r1, #2                               @ 0801770E
    blt .L08017720                           @ 08017710
    ldr r2, =lcd_shadow                      @ 08017712 &LCD shadow
    ldr r2, [r2, #8]                         @ 08017714
    bics.w r2, r2, #1024                     @ 08017716
    ldr r3, =lcd_shadow                      @ 0801771A &LCD shadow
    str r2, [r3, #8]                         @ 0801771C w2 &= ~0x400: clears m prefix
    b .L0801772C                             @ 0801771E
.L08017720:                                @ reached from 08017710 blt (signed <)
    ldr r2, =lcd_shadow                      @ 08017720 &LCD shadow
    ldr r2, [r2, #8]                         @ 08017722
    orrs.w r2, r2, #1024                     @ 08017724
    ldr r3, =lcd_shadow                      @ 08017728 &LCD shadow
    str r2, [r3, #8]                         @ 0801772A w2 |= 0x400: m prefix
.L0801772C:                                @ reached from 0801770A bne (not equal / non-zero); 0801771E b; falls in
    bx lr                                    @ 0801772C
ENDFUNC fn_08017700
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080177AC - capacitance prefix and unit
@ Replaces : 0x080177AC FUN_080177AC (v2.05, 70 bytes)
@ In       : r0 = range
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow words 0 (u, bit 9), 2 (n, bit 9), 4 (F, bit 9)
@ Spec     : analysis/lcd_map.md 4.1: range < 2 -> n, otherwise u; F always
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080177AC
    uxtb r0, r0                              @ 080177AC
    cmp r0, #2                               @ 080177AE
    bge .L080177CC                           @ 080177B0
    ldr r1, =lcd_shadow                      @ 080177B2 &LCD shadow
    ldr r1, [r1, #0]                         @ 080177B4
    bics.w r1, r1, #512                      @ 080177B6
    ldr r2, =lcd_shadow                      @ 080177BA &LCD shadow
    str r1, [r2, #0]                         @ 080177BC w0 &= ~0x200: clears u (micro)
    ldr r1, =lcd_shadow                      @ 080177BE &LCD shadow
    ldr r1, [r1, #8]                         @ 080177C0
    orrs.w r1, r1, #512                      @ 080177C2
    ldr r2, =lcd_shadow                      @ 080177C6 &LCD shadow
    str r1, [r2, #8]                         @ 080177C8 w2 |= 0x200: n
    b .L080177E4                             @ 080177CA
.L080177CC:                                @ reached from 080177B0 bge (signed >=)
    ldr r1, =lcd_shadow                      @ 080177CC &LCD shadow
    ldr r1, [r1, #0]                         @ 080177CE
    orrs.w r1, r1, #512                      @ 080177D0
    ldr r2, =lcd_shadow                      @ 080177D4 &LCD shadow
    str r1, [r2, #0]                         @ 080177D6 w0 |= 0x200: u (micro)
    ldr r1, =lcd_shadow                      @ 080177D8 &LCD shadow
    ldr r1, [r1, #8]                         @ 080177DA
    bics.w r1, r1, #512                      @ 080177DC
    ldr r2, =lcd_shadow                      @ 080177E0 &LCD shadow
    str r1, [r2, #8]                         @ 080177E2 w2 &= ~0x200: clears n
.L080177E4:                                @ reached from 080177CA b; falls in
    ldr r1, =lcd_shadow                      @ 080177E4 &LCD shadow
    ldr r1, [r1, #16]                        @ 080177E6
    orrs.w r1, r1, #512                      @ 080177E8
    ldr r2, =lcd_shadow                      @ 080177EC &LCD shadow
    str r1, [r2, #16]                        @ 080177EE w4 |= 0x200: F (capacitance)
    bx lr                                    @ 080177F0
ENDFUNC fn_080177AC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080177F2 - resistance prefix and unit
@ Replaces : 0x080177F2 FUN_080177F2 (v2.05, 102 bytes)
@ In       : r0 = range
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow words 0 (k bit 8, M bit 11), 2 (Ohm bit 8)
@ Spec     : analysis/lcd_map.md 4.1: range >= 5 -> M, 2..4 -> k, below 2 none; Ohm always
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080177F2
    uxtb r0, r0                              @ 080177F2
    cmp r0, #5                               @ 080177F4
    blt .L08017812                           @ 080177F6
    ldr r1, =lcd_shadow                      @ 080177F8 &LCD shadow
    ldr r1, [r1, #0]                         @ 080177FA
    bics.w r1, r1, #256                      @ 080177FC
    ldr r2, =lcd_shadow                      @ 08017800 &LCD shadow
    str r1, [r2, #0]                         @ 08017802 w0 &= ~0x100: clears k prefix
    ldr r1, =lcd_shadow                      @ 08017804 &LCD shadow
    ldr r1, [r1, #0]                         @ 08017806
    orrs.w r1, r1, #2048                     @ 08017808
    ldr r2, =lcd_shadow                      @ 0801780C &LCD shadow
    str r1, [r2, #0]                         @ 0801780E w0 |= 0x800: M prefix
    b .L0801784A                             @ 08017810
.L08017812:                                @ reached from 080177F6 blt (signed <)
    uxtb r0, r0                              @ 08017812
    cmp r0, #2                               @ 08017814
    blt .L08017832                           @ 08017816
    ldr r1, =lcd_shadow                      @ 08017818 &LCD shadow
    ldr r1, [r1, #0]                         @ 0801781A
    orrs.w r1, r1, #256                      @ 0801781C
    ldr r2, =lcd_shadow                      @ 08017820 &LCD shadow
    str r1, [r2, #0]                         @ 08017822 w0 |= 0x100: k prefix
    ldr r1, =lcd_shadow                      @ 08017824 &LCD shadow
    ldr r1, [r1, #0]                         @ 08017826
    bics.w r1, r1, #2048                     @ 08017828
    ldr r2, =lcd_shadow                      @ 0801782C &LCD shadow
    str r1, [r2, #0]                         @ 0801782E w0 &= ~0x800: clears M prefix
    b .L0801784A                             @ 08017830
.L08017832:                                @ reached from 08017816 blt (signed <)
    ldr r1, =lcd_shadow                      @ 08017832 &LCD shadow
    ldr r1, [r1, #0]                         @ 08017834
    bics.w r1, r1, #256                      @ 08017836
    ldr r2, =lcd_shadow                      @ 0801783A &LCD shadow
    str r1, [r2, #0]                         @ 0801783C w0 &= ~0x100: clears k prefix
    ldr r1, =lcd_shadow                      @ 0801783E &LCD shadow
    ldr r1, [r1, #0]                         @ 08017840
    bics.w r1, r1, #2048                     @ 08017842
    ldr r2, =lcd_shadow                      @ 08017846 &LCD shadow
    str r1, [r2, #0]                         @ 08017848 w0 &= ~0x800: clears M prefix
.L0801784A:                                @ reached from 08017810 b; 08017830 b; falls in
    ldr r1, =lcd_shadow                      @ 0801784A &LCD shadow
    ldr r1, [r1, #8]                         @ 0801784C
    orrs.w r1, r1, #256                      @ 0801784E
    ldr r2, =lcd_shadow                      @ 08017852 &LCD shadow
    str r1, [r2, #8]                         @ 08017854 w2 |= 0x100: Ohm
    bx lr                                    @ 08017856
ENDFUNC fn_080177F2
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08017858 - frequency prefix and unit
@ Replaces : 0x08017858 FUN_08017858 (v2.05, 102 bytes)
@ In       : r0 = range
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow words 0 (k bit 8, M bit 11), 4 (Hz bit 8)
@ Spec     : analysis/lcd_map.md 4.1: range >= 5 -> M, 2..4 -> k, below 2 none; Hz always
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08017858
    uxtb r0, r0                              @ 08017858
    cmp r0, #5                               @ 0801785A
    blt .L08017878                           @ 0801785C
    ldr r1, =lcd_shadow                      @ 0801785E &LCD shadow
    ldr r1, [r1, #0]                         @ 08017860
    bics.w r1, r1, #256                      @ 08017862
    ldr r2, =lcd_shadow                      @ 08017866 &LCD shadow
    str r1, [r2, #0]                         @ 08017868 w0 &= ~0x100: clears k prefix
    ldr r1, =lcd_shadow                      @ 0801786A &LCD shadow
    ldr r1, [r1, #0]                         @ 0801786C
    orrs.w r1, r1, #2048                     @ 0801786E
    ldr r2, =lcd_shadow                      @ 08017872 &LCD shadow
    str r1, [r2, #0]                         @ 08017874 w0 |= 0x800: M prefix
    b .L080178B0                             @ 08017876
.L08017878:                                @ reached from 0801785C blt (signed <)
    uxtb r0, r0                              @ 08017878
    cmp r0, #2                               @ 0801787A
    blt .L08017898                           @ 0801787C
    ldr r1, =lcd_shadow                      @ 0801787E &LCD shadow
    ldr r1, [r1, #0]                         @ 08017880
    orrs.w r1, r1, #256                      @ 08017882
    ldr r2, =lcd_shadow                      @ 08017886 &LCD shadow
    str r1, [r2, #0]                         @ 08017888 w0 |= 0x100: k prefix
    ldr r1, =lcd_shadow                      @ 0801788A &LCD shadow
    ldr r1, [r1, #0]                         @ 0801788C
    bics.w r1, r1, #2048                     @ 0801788E
    ldr r2, =lcd_shadow                      @ 08017892 &LCD shadow
    str r1, [r2, #0]                         @ 08017894 w0 &= ~0x800: clears M prefix
    b .L080178B0                             @ 08017896
.L08017898:                                @ reached from 0801787C blt (signed <)
    ldr r1, =lcd_shadow                      @ 08017898 &LCD shadow
    ldr r1, [r1, #0]                         @ 0801789A
    bics.w r1, r1, #256                      @ 0801789C
    ldr r2, =lcd_shadow                      @ 080178A0 &LCD shadow
    str r1, [r2, #0]                         @ 080178A2 w0 &= ~0x100: clears k prefix
    ldr r1, =lcd_shadow                      @ 080178A4 &LCD shadow
    ldr r1, [r1, #0]                         @ 080178A6
    bics.w r1, r1, #2048                     @ 080178A8
    ldr r2, =lcd_shadow                      @ 080178AC &LCD shadow
    str r1, [r2, #0]                         @ 080178AE w0 &= ~0x800: clears M prefix
.L080178B0:                                @ reached from 08017876 b; 08017896 b; falls in
    ldr r1, =lcd_shadow                      @ 080178B0 &LCD shadow
    ldr r1, [r1, #16]                        @ 080178B2
    orrs.w r1, r1, #256                      @ 080178B4
    ldr r2, =lcd_shadow                      @ 080178B8 &LCD shadow
    str r1, [r2, #16]                        @ 080178BA w4 |= 0x100: Hz
    bx lr                                    @ 080178BC
ENDFUNC fn_08017858
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019B48 - clear the unit and mode annunciator group
@ Replaces : 0x08019B48 FUN_08019B48 (v2.05, 268 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow words 0, 2, 4, 6 (LowZ, Hz, Beep, Diode, k, Ohm, M, A, m, V, n, u, F, % and, unless peak hold is
@            active, the "ms" element) and reads peak_hold (0x200080B7)
@ Spec     : analysis/lcd_map.md 4.1
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019B48
    ldr r0, =lcd_shadow                      @ 08019B48 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019B4C
    bics.w r0, r0, #536870912                @ 08019B4E
    ldr r1, =lcd_shadow                      @ 08019B52 &LCD shadow
    str r0, [r1, #0]                         @ 08019B56 w0 &= ~0x20000000: clears unmapped (only ever cleared)
    ldr r0, =lcd_shadow                      @ 08019B58 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019B5C
    bics.w r0, r0, #1073741824               @ 08019B5E
    ldr r1, =lcd_shadow                      @ 08019B62 &LCD shadow
    str r0, [r1, #0]                         @ 08019B66 w0 &= ~0x40000000: clears LowZ
    ldr r0, =lcd_shadow                      @ 08019B68 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019B6C
    bics.w r0, r0, #256                      @ 08019B6E
    ldr r1, =lcd_shadow                      @ 08019B72 &LCD shadow
    str r0, [r1, #16]                        @ 08019B76 w4 &= ~0x100: clears Hz
    ldr r0, =lcd_shadow                      @ 08019B78 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019B7C
    bic.w r0, r0, #2147483648                @ 08019B7E
    ldr r1, =lcd_shadow                      @ 08019B82 &LCD shadow
    str r0, [r1, #16]                        @ 08019B86 w4 &= ~0x80000000: clears Beep
    ldr r0, =lcd_shadow                      @ 08019B88 &LCD shadow
    ldr r0, [r0, #24]                        @ 08019B8C
    bic.w r0, r0, #2147483648                @ 08019B8E
    ldr r1, =lcd_shadow                      @ 08019B92 &LCD shadow
    str r0, [r1, #24]                        @ 08019B96 w6 &= ~0x80000000: clears Diode
    ldr r0, =lcd_shadow                      @ 08019B98 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019B9C
    bics.w r0, r0, #256                      @ 08019B9E
    ldr r1, =lcd_shadow                      @ 08019BA2 &LCD shadow
    str r0, [r1, #0]                         @ 08019BA6 w0 &= ~0x100: clears k prefix
    ldr r0, =lcd_shadow                      @ 08019BA8 &LCD shadow
    ldr r0, [r0, #8]                         @ 08019BAC
    bics.w r0, r0, #256                      @ 08019BAE
    ldr r1, =lcd_shadow                      @ 08019BB2 &LCD shadow
    str r0, [r1, #8]                         @ 08019BB6 w2 &= ~0x100: clears Ohm
    ldr r0, =lcd_shadow                      @ 08019BB8 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019BBC
    bics.w r0, r0, #2048                     @ 08019BBE
    ldr r1, =lcd_shadow                      @ 08019BC2 &LCD shadow
    str r0, [r1, #0]                         @ 08019BC6 w0 &= ~0x800: clears M prefix
    ldr r0, =lcd_shadow                      @ 08019BC8 &LCD shadow
    ldr r0, [r0, #24]                        @ 08019BCC
    bics.w r0, r0, #1024                     @ 08019BCE
    ldr r1, =lcd_shadow                      @ 08019BD2 &LCD shadow
    str r0, [r1, #24]                        @ 08019BD6 w6 &= ~0x400: clears A
    ldr r0, =lcd_shadow                      @ 08019BD8 &LCD shadow
    ldr r0, [r0, #8]                         @ 08019BDC
    bics.w r0, r0, #1024                     @ 08019BDE
    ldr r1, =lcd_shadow                      @ 08019BE2 &LCD shadow
    str r0, [r1, #8]                         @ 08019BE6 w2 &= ~0x400: clears m prefix
    ldr r0, =lcd_shadow                      @ 08019BE8 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019BEC
    bics.w r0, r0, #1024                     @ 08019BEE
    ldr r1, =lcd_shadow                      @ 08019BF2 &LCD shadow
    str r0, [r1, #16]                        @ 08019BF6 w4 &= ~0x400: clears V
    ldr r0, =lcd_shadow                      @ 08019BF8 &LCD shadow
    ldr r0, [r0, #8]                         @ 08019BFC
    bics.w r0, r0, #512                      @ 08019BFE
    ldr r1, =lcd_shadow                      @ 08019C02 &LCD shadow
    str r0, [r1, #8]                         @ 08019C06 w2 &= ~0x200: clears n
    ldr r0, =lcd_shadow                      @ 08019C08 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019C0C
    bics.w r0, r0, #512                      @ 08019C0E
    ldr r1, =lcd_shadow                      @ 08019C12 &LCD shadow
    str r0, [r1, #0]                         @ 08019C16 w0 &= ~0x200: clears u (micro)
    ldr r0, =lcd_shadow                      @ 08019C18 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019C1C
    bics.w r0, r0, #512                      @ 08019C1E
    ldr r1, =lcd_shadow                      @ 08019C22 &LCD shadow
    str r0, [r1, #16]                        @ 08019C26 w4 &= ~0x200: clears F (capacitance)
    @ "ms" is also the peak-hold element, so it is cleared only while peak hold is off

    ldr r0, =peak_hold                       @ 08019C28 &peak_hold
    ldrb r0, [r0, #0]                        @ 08019C2C
    cmp r0, #0                               @ 08019C2E branch if peak_hold != 0
    bne .L08019C42                           @ 08019C30
    ldr r0, =lcd_shadow                      @ 08019C32 &LCD shadow
    ldr r0, [r0, #24]                        @ 08019C36
    lsrs r0, r0, #1                          @ 08019C38
    lsls r0, r0, #1                          @ 08019C3A
    ldr r1, =lcd_shadow                      @ 08019C3C &LCD shadow
    str r0, [r1, #24]                        @ 08019C40 w6 &= ~0x1: clears ms
.L08019C42:                                @ reached from 08019C30 bne (not equal / non-zero); falls in
    ldr r0, =lcd_shadow                      @ 08019C42 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019C46
    bics.w r0, r0, #131072                   @ 08019C48
    ldr r1, =lcd_shadow                      @ 08019C4C &LCD shadow
    str r0, [r1, #0]                         @ 08019C50 w0 &= ~0x20000: clears % (duty)
    bx lr                                    @ 08019C52
ENDFUNC fn_08019B48
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019C5C - Apo (auto power off) annunciator
@ Replaces : 0x08019C5C FUN_08019C5C (v2.05, 88 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x200080E6, 0x20008039 (APO disabled), 0x20007FE1, minmax_state; lcd_shadow word 5 bit 7
@ Spec     : analysis/lcd_map.md 4.2: Apo is lit when 0x200080E6 = 0, 0x20008039 = 0, 0x20007FE1 = 0 and minmax_state = 0;
@            with 0x200080E6 != 0 the element is left as it is
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019C5C
    push {r4, lr}                            @ 08019C5C
    movs r4, r0                              @ 08019C5E
    ldr r0, =v_200080E6                      @ 08019C60 &APO icon condition flag
    ldrb r0, [r0, #0]                        @ 08019C64
    cmp r0, #0                               @ 08019C66 branch if APO icon condition flag != 0
    bne .L08019CB2                           @ 08019C68
    ldr r0, =v_20008039                      @ 08019C6A &APO disabled setting
    ldrb r0, [r0, #0]                        @ 08019C6E
    ldr r1, =v_20007FE1                      @ 08019C70 &flag FE1 (lcd_map.md 4)
    ldrb r1, [r1, #0]                        @ 08019C74
    orrs r0, r1                              @ 08019C76
    uxtb r0, r0                              @ 08019C78
    cmp r0, #0                               @ 08019C7A
    bne .L08019C86                           @ 08019C7C
    ldr r0, =minmax_state                    @ 08019C7E &minmax_state
    ldrb r0, [r0, #0]                        @ 08019C80
    cmp r0, #0                               @ 08019C82 branch if minmax_state == 0
    beq .L08019C98                           @ 08019C84
.L08019C86:                                @ reached from 08019C7C bne (not equal / non-zero); falls in
    ldr r0, =lcd_shadow                      @ 08019C86 &LCD shadow
    ldr r0, [r0, #20]                        @ 08019C8A
    bics.w r0, r0, #128                      @ 08019C8C
    ldr r1, =lcd_shadow                      @ 08019C90 &LCD shadow
    str r0, [r1, #20]                        @ 08019C94 w5 &= ~0x80: clears Apo
    b .L08019CA8                             @ 08019C96
.L08019C98:                                @ reached from 08019C84 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019C98 &LCD shadow
    ldr r0, [r0, #20]                        @ 08019C9C
    orrs.w r0, r0, #128                      @ 08019C9E
    ldr r1, =lcd_shadow                      @ 08019CA2 &LCD shadow
    str r0, [r1, #20]                        @ 08019CA6 w5 |= 0x80: Apo
.L08019CA8:                                @ reached from 08019C96 b; falls in
    uxtb r4, r4                              @ 08019CA8
    cmp r4, #1                               @ 08019CAA
    bne .L08019CB2                           @ 08019CAC
    bl lcd_commit_shadow                     @ 08019CAE
.L08019CB2:                                @ reached from 08019C68 bne (not equal / non-zero); 08019CAC bne (not equal / non-zero); falls in
    pop {r4, pc}                             @ 08019CB2
ENDFUNC fn_08019C5C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019CBC - Apo annunciator from the boot flag, committed at once
@ Replaces : 0x08019CBC FUN_08019CBC (v2.05, 52 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; called once per second from the main loop (loop step 9)
@ RAM      : reads 0x200080E7; lcd_shadow word 5 bit 7
@ Spec     : analysis/lcd_map.md 4.2 (boot: Apo lit when 0x200080E7 != 0)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019CBC
    push {r7, lr}                            @ 08019CBC
    ldr r0, =v_200080E7                      @ 08019CBE &APO icon boot flag
    ldrb r0, [r0, #0]                        @ 08019CC2
    cmp r0, #0                               @ 08019CC4 branch if APO icon boot flag == 0
    beq .L08019CDA                           @ 08019CC6
    ldr r0, =lcd_shadow                      @ 08019CC8 &LCD shadow
    ldr r0, [r0, #20]                        @ 08019CCC
    orrs.w r0, r0, #128                      @ 08019CCE
    ldr r1, =lcd_shadow                      @ 08019CD2 &LCD shadow
    str r0, [r1, #20]                        @ 08019CD6 w5 |= 0x80: Apo
    b .L08019CEA                             @ 08019CD8
.L08019CDA:                                @ reached from 08019CC6 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019CDA &LCD shadow
    ldr r0, [r0, #20]                        @ 08019CDE
    bics.w r0, r0, #128                      @ 08019CE0
    ldr r1, =lcd_shadow                      @ 08019CE4 &LCD shadow
    str r0, [r1, #20]                        @ 08019CE8 w5 &= ~0x80: clears Apo
.L08019CEA:                                @ reached from 08019CD8 b; falls in
    bl lcd_commit_shadow                     @ 08019CEA
    pop {r0, pc}                             @ 08019CEE
ENDFUNC fn_08019CBC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019CF0 - battery annunciator
@ Replaces : 0x08019CF0 FUN_08019CF0 (v2.05, 60 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x2000803B; lcd_shadow word 7 bit 7
@ Spec     : analysis/lcd_map.md 4.2 (lit when 0x2000803B != 0)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019CF0
    push {r4, lr}                            @ 08019CF0
    movs r4, r0                              @ 08019CF2
    ldr r0, =v_2000803B                      @ 08019CF4 &battery flag
    ldrb r0, [r0, #0]                        @ 08019CF8
    cmp r0, #0                               @ 08019CFA branch if battery flag == 0
    beq .L08019D10                           @ 08019CFC
    ldr r0, =lcd_shadow                      @ 08019CFE &LCD shadow
    ldr r0, [r0, #28]                        @ 08019D02
    orrs.w r0, r0, #128                      @ 08019D04
    ldr r1, =lcd_shadow                      @ 08019D08 &LCD shadow
    str r0, [r1, #28]                        @ 08019D0C w7 |= 0x80: Battery
    b .L08019D20                             @ 08019D0E
.L08019D10:                                @ reached from 08019CFC beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019D10 &LCD shadow
    ldr r0, [r0, #28]                        @ 08019D14
    bics.w r0, r0, #128                      @ 08019D16
    ldr r1, =lcd_shadow                      @ 08019D1A &LCD shadow
    str r0, [r1, #28]                        @ 08019D1E w7 &= ~0x80: clears Battery
.L08019D20:                                @ reached from 08019D0E b; falls in
    uxtb r4, r4                              @ 08019D20
    cmp r4, #1                               @ 08019D22
    bne .L08019D2A                           @ 08019D24
    bl lcd_commit_shadow                     @ 08019D26
.L08019D2A:                                @ reached from 08019D24 bne (not equal / non-zero); falls in
    pop {r4, pc}                             @ 08019D2A
ENDFUNC fn_08019CF0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019D2C - BT (Bluetooth) annunciator
@ Replaces : 0x08019D2C FUN_08019D2C (v2.05, 60 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x2000802B (BT enable); lcd_shadow word 0 bit 31
@ Spec     : analysis/lcd_map.md 4.2
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019D2C
    push {r4, lr}                            @ 08019D2C
    movs r4, r0                              @ 08019D2E
    ldr r0, =v_2000802B                      @ 08019D30 &BT enable
    ldrb r0, [r0, #0]                        @ 08019D34
    cmp r0, #0                               @ 08019D36 branch if BT enable == 0
    beq .L08019D4C                           @ 08019D38
    ldr r0, =lcd_shadow                      @ 08019D3A &LCD shadow
    ldr r0, [r0, #0]                         @ 08019D3E
    orrs.w r0, r0, #2147483648               @ 08019D40
    ldr r1, =lcd_shadow                      @ 08019D44 &LCD shadow
    str r0, [r1, #0]                         @ 08019D48 w0 |= 0x80000000: BT
    b .L08019D5C                             @ 08019D4A
.L08019D4C:                                @ reached from 08019D38 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019D4C &LCD shadow
    ldr r0, [r0, #0]                         @ 08019D50
    bic.w r0, r0, #2147483648                @ 08019D52
    ldr r1, =lcd_shadow                      @ 08019D56 &LCD shadow
    str r0, [r1, #0]                         @ 08019D5A w0 &= ~0x80000000: clears BT
.L08019D5C:                                @ reached from 08019D4A b; falls in
    uxtb r4, r4                              @ 08019D5C
    cmp r4, #1                               @ 08019D5E
    bne .L08019D66                           @ 08019D60
    bl lcd_commit_shadow                     @ 08019D62
.L08019D66:                                @ reached from 08019D60 bne (not equal / non-zero); falls in
    pop {r4, pc}                             @ 08019D66
ENDFUNC fn_08019D2C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019D68 - AUTO (auto-range) annunciator
@ Replaces : 0x08019D68 FUN_08019D68 (v2.05, 58 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow word 7 bit 0; the condition is the result of fn_08019DA2 (MODE)
@ Spec     : analysis/lcd_map.md 4.2 (AUTO when fn_08019DA2 returns 1)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019D68
    push {r4, lr}                            @ 08019D68
    movs r4, r0                              @ 08019D6A
    bl fn_08019DA2                           @ 08019D6C
    cmp r0, #0                               @ 08019D70
    beq .L08019D86                           @ 08019D72
    ldr r0, =lcd_shadow                      @ 08019D74 &LCD shadow
    ldr r0, [r0, #28]                        @ 08019D78
    orrs.w r0, r0, #1                        @ 08019D7A
    ldr r1, =lcd_shadow                      @ 08019D7E &LCD shadow
    str r0, [r1, #28]                        @ 08019D82 w7 |= 0x1: AUTO
    b .L08019D96                             @ 08019D84
.L08019D86:                                @ reached from 08019D72 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019D86 &LCD shadow
    ldr r0, [r0, #28]                        @ 08019D8A
    lsrs r0, r0, #1                          @ 08019D8C
    lsls r0, r0, #1                          @ 08019D8E
    ldr r1, =lcd_shadow                      @ 08019D90 &LCD shadow
    str r0, [r1, #28]                        @ 08019D94 w7 &= ~0x1: clears AUTO
.L08019D96:                                @ reached from 08019D84 b; falls in
    uxtb r4, r4                              @ 08019D96
    cmp r4, #1                               @ 08019D98
    bne .L08019DA0                           @ 08019D9A
    bl lcd_commit_shadow                     @ 08019D9C
.L08019DA0:                                @ reached from 08019D9A bne (not equal / non-zero); falls in
    pop {r4, pc}                             @ 08019DA0
ENDFUNC fn_08019D68
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019E24 - MIN, MAX and AVG annunciators
@ Replaces : 0x08019E24 FUN_08019E24 (v2.05, 266 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x20007FE1, 0x20007FE4, peak_hold (0x200080B7), peak_show_min (0x200080B8), minmax_state (0x2000804E);
@            lcd_shadow words 2 (AVG), 4 (MAX), 6 (MIN), bit 30
@ Spec     : analysis/lcd_map.md 4.2: all three are cleared first; nothing is set while 0x20007FE1 or 0x20007FE4 is non-zero;
@            peak hold shows MIN (peak_show_min != 0) or MAX; otherwise minmax_state 1 = MAX, 2 = MIN, 3 = AVG, 4 = all three
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019E24
    push {r4, lr}                            @ 08019E24
    movs r4, r0                              @ 08019E26
    ldr r0, =lcd_shadow                      @ 08019E28 &LCD shadow
    ldr r0, [r0, #24]                        @ 08019E2C
    bics.w r0, r0, #1073741824               @ 08019E2E
    ldr r1, =lcd_shadow                      @ 08019E32 &LCD shadow
    str r0, [r1, #24]                        @ 08019E36 w6 &= ~0x40000000: clears MIN
    ldr r0, =lcd_shadow                      @ 08019E38 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019E3C
    bics.w r0, r0, #1073741824               @ 08019E3E
    ldr r1, =lcd_shadow                      @ 08019E42 &LCD shadow
    str r0, [r1, #16]                        @ 08019E46 w4 &= ~0x40000000: clears MAX
    ldr r0, =lcd_shadow                      @ 08019E48 &LCD shadow
    ldr r0, [r0, #8]                         @ 08019E4C
    bics.w r0, r0, #1073741824               @ 08019E4E
    ldr r1, =lcd_shadow                      @ 08019E52 &LCD shadow
    str r0, [r1, #8]                         @ 08019E56 w2 &= ~0x40000000: clears AVG
    ldr r0, =v_20007FE1                      @ 08019E58 &flag FE1 (lcd_map.md 4)
    ldrb r0, [r0, #0]                        @ 08019E5C
    ldr r1, =v_20007FE4                      @ 08019E5E &MEM view active (recalled-record view)
    ldrb r1, [r1, #0]                        @ 08019E62
    orrs r0, r1                              @ 08019E64
    uxtb r0, r0                              @ 08019E66
    cmp r0, #0                               @ 08019E68
    bne .L08019F22                           @ 08019E6A
    ldr r0, =peak_hold                       @ 08019E6C &peak_hold
    ldrb r0, [r0, #0]                        @ 08019E70
    cmp r0, #0                               @ 08019E72 branch if peak_hold == 0
    beq .L08019EA4                           @ 08019E74
    ldr r0, =peak_show_min                   @ 08019E76 &peak_show_min
    ldrb r0, [r0, #0]                        @ 08019E7A
    cmp r0, #0                               @ 08019E7C branch if peak_show_min == 0
    beq .L08019E92                           @ 08019E7E
    ldr r0, =lcd_shadow                      @ 08019E80 &LCD shadow
    ldr r0, [r0, #24]                        @ 08019E84
    orrs.w r0, r0, #1073741824               @ 08019E86
    ldr r1, =lcd_shadow                      @ 08019E8A &LCD shadow
    str r0, [r1, #24]                        @ 08019E8E w6 |= 0x40000000: MIN
    b .L08019F22                             @ 08019E90
.L08019E92:                                @ reached from 08019E7E beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019E92 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019E96
    orrs.w r0, r0, #1073741824               @ 08019E98
    ldr r1, =lcd_shadow                      @ 08019E9C &LCD shadow
    str r0, [r1, #16]                        @ 08019EA0 w4 |= 0x40000000: MAX
    b .L08019F22                             @ 08019EA2
.L08019EA4:                                @ reached from 08019E74 beq (equal / zero)
    ldr r0, =minmax_state                    @ 08019EA4 &minmax_state
    ldrb r0, [r0, #0]                        @ 08019EA8
    cmp r0, #1                               @ 08019EAA branch if minmax_state == 1
    beq .L08019EBC                           @ 08019EAC
    bcc .L08019F22                           @ 08019EAE
    cmp r0, #3                               @ 08019EB0 branch if minmax_state == 3
    beq .L08019EE0                           @ 08019EB2
    bcc .L08019ECE                           @ 08019EB4
    cmp r0, #4                               @ 08019EB6 branch if minmax_state == 4
    beq .L08019EF2                           @ 08019EB8
    b .L08019F22                             @ 08019EBA
.L08019EBC:                                @ reached from 08019EAC beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019EBC &LCD shadow
    ldr r0, [r0, #16]                        @ 08019EC0
    orrs.w r0, r0, #1073741824               @ 08019EC2
    ldr r1, =lcd_shadow                      @ 08019EC6 &LCD shadow
    str r0, [r1, #16]                        @ 08019ECA w4 |= 0x40000000: MAX
    b .L08019F22                             @ 08019ECC
.L08019ECE:                                @ reached from 08019EB4 bcc (unsigned <)
    ldr r0, =lcd_shadow                      @ 08019ECE &LCD shadow
    ldr r0, [r0, #24]                        @ 08019ED2
    orrs.w r0, r0, #1073741824               @ 08019ED4
    ldr r1, =lcd_shadow                      @ 08019ED8 &LCD shadow
    str r0, [r1, #24]                        @ 08019EDC w6 |= 0x40000000: MIN
    b .L08019F22                             @ 08019EDE
.L08019EE0:                                @ reached from 08019EB2 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019EE0 &LCD shadow
    ldr r0, [r0, #8]                         @ 08019EE4
    orrs.w r0, r0, #1073741824               @ 08019EE6
    ldr r1, =lcd_shadow                      @ 08019EEA &LCD shadow
    str r0, [r1, #8]                         @ 08019EEE w2 |= 0x40000000: AVG
    b .L08019F22                             @ 08019EF0
.L08019EF2:                                @ reached from 08019EB8 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019EF2 &LCD shadow
    ldr r0, [r0, #24]                        @ 08019EF6
    orrs.w r0, r0, #1073741824               @ 08019EF8
    ldr r1, =lcd_shadow                      @ 08019EFC &LCD shadow
    str r0, [r1, #24]                        @ 08019F00 w6 |= 0x40000000: MIN
    ldr r0, =lcd_shadow                      @ 08019F02 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019F06
    orrs.w r0, r0, #1073741824               @ 08019F08
    ldr r1, =lcd_shadow                      @ 08019F0C &LCD shadow
    str r0, [r1, #16]                        @ 08019F10 w4 |= 0x40000000: MAX
    ldr r0, =lcd_shadow                      @ 08019F12 &LCD shadow
    ldr r0, [r0, #8]                         @ 08019F16
    orrs.w r0, r0, #1073741824               @ 08019F18
    ldr r1, =lcd_shadow                      @ 08019F1C &LCD shadow
    str r0, [r1, #8]                         @ 08019F20 w2 |= 0x40000000: AVG
.L08019F22:                                @ reached from 08019E6A bne (not equal / non-zero); 08019E90 b; 08019EA2 b; 08019EAE bcc (unsigned <); 08019EBA b; 08019ECC b; 08019EDE b; 08019EF0 b; falls in
    uxtb r4, r4                              @ 08019F22
    cmp r4, #1                               @ 08019F24
    bne .L08019F2C                           @ 08019F26
    bl lcd_commit_shadow                     @ 08019F28
.L08019F2C:                                @ reached from 08019F26 bne (not equal / non-zero); falls in
    pop {r4, pc}                             @ 08019F2C
ENDFUNC fn_08019E24
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019F2E - REL annunciator
@ Replaces : 0x08019F2E FUN_08019F2E (v2.05, 116 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x20007FE1, 0x20007FE4, rel_active (0x20008058); lcd_shadow word 0 bit 0
@ Spec     : analysis/lcd_map.md 4.2: lit only when 0x20007FE1 = 0, 0x20007FE4 = 0 and rel_active != 0
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019F2E
    push {r4, lr}                            @ 08019F2E
    movs r4, r0                              @ 08019F30
    ldr r0, =v_20007FE1                      @ 08019F32 &flag FE1 (lcd_map.md 4)
    ldrb r0, [r0, #0]                        @ 08019F36
    cmp r0, #0                               @ 08019F38 branch if flag FE1 (lcd_map.md 4) == 0
    beq .L08019F4E                           @ 08019F3A
    ldr r0, =lcd_shadow                      @ 08019F3C &LCD shadow
    ldr r0, [r0, #0]                         @ 08019F40
    lsrs r0, r0, #1                          @ 08019F42
    lsls r0, r0, #1                          @ 08019F44
    ldr r1, =lcd_shadow                      @ 08019F46 &LCD shadow
    str r0, [r1, #0]                         @ 08019F4A w0 &= ~0x1: clears REL
    b .L08019F96                             @ 08019F4C
.L08019F4E:                                @ reached from 08019F3A beq (equal / zero)
    ldr r0, =v_20007FE4                      @ 08019F4E &MEM view active (recalled-record view)
    ldrb r0, [r0, #0]                        @ 08019F52
    cmp r0, #0                               @ 08019F54 branch if MEM view active (recalled-record view) == 0
    beq .L08019F6A                           @ 08019F56
    ldr r0, =lcd_shadow                      @ 08019F58 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019F5C
    lsrs r0, r0, #1                          @ 08019F5E
    lsls r0, r0, #1                          @ 08019F60
    ldr r1, =lcd_shadow                      @ 08019F62 &LCD shadow
    str r0, [r1, #0]                         @ 08019F66 w0 &= ~0x1: clears REL
    b .L08019F96                             @ 08019F68
.L08019F6A:                                @ reached from 08019F56 beq (equal / zero)
    ldr r0, =rel_active                      @ 08019F6A &rel_active
    ldrb r0, [r0, #0]                        @ 08019F6E
    cmp r0, #0                               @ 08019F70 branch if rel_active == 0
    beq .L08019F86                           @ 08019F72
    ldr r0, =lcd_shadow                      @ 08019F74 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019F78
    orrs.w r0, r0, #1                        @ 08019F7A
    ldr r1, =lcd_shadow                      @ 08019F7E &LCD shadow
    str r0, [r1, #0]                         @ 08019F82 w0 |= 0x1: REL
    b .L08019F96                             @ 08019F84
.L08019F86:                                @ reached from 08019F72 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019F86 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019F8A
    lsrs r0, r0, #1                          @ 08019F8C
    lsls r0, r0, #1                          @ 08019F8E
    ldr r1, =lcd_shadow                      @ 08019F90 &LCD shadow
    str r0, [r1, #0]                         @ 08019F94 w0 &= ~0x1: clears REL
.L08019F96:                                @ reached from 08019F4C b; 08019F68 b; 08019F84 b; falls in
    uxtb r4, r4                              @ 08019F96
    cmp r4, #1                               @ 08019F98
    bne .L08019FA0                           @ 08019F9A
    bl lcd_commit_shadow                     @ 08019F9C
.L08019FA0:                                @ reached from 08019F9A bne (not equal / non-zero); falls in
    pop {r4, pc}                             @ 08019FA0
ENDFUNC fn_08019F2E
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019FA2 - HOLD and A- (auto-hold) annunciators
@ Replaces : 0x08019FA2 FUN_08019FA2 (v2.05, 134 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow word 2 bit 16 (A-) and word 4 bit 16 (HOLD); the state comes from fn_0801A028 (FUNC)
@ Spec     : analysis/lcd_map.md 4.2: state 1 (auto-hold stage 2 waiting) lights A- and HOLD, state 2 (hold active) HOLD only, otherwise both off
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019FA2
    push {r3, r4, r5, lr}                    @ 08019FA2
    movs r4, r0                              @ 08019FA4
    bl fn_0801A028                           @ 08019FA6
    movs r5, r0                              @ 08019FAA
    uxtb r5, r5                              @ 08019FAC
    cmp r5, #1                               @ 08019FAE
    bne .L08019FD4                           @ 08019FB0
    ldr r0, =lcd_shadow                      @ 08019FB2 &LCD shadow
    ldr r0, [r0, #8]                         @ 08019FB6
    orrs.w r0, r0, #65536                    @ 08019FB8
    ldr r1, =lcd_shadow                      @ 08019FBC &LCD shadow
    str r0, [r1, #8]                         @ 08019FC0 w2 |= 0x10000: A-
    ldr r0, =lcd_shadow                      @ 08019FC2 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019FC6
    orrs.w r0, r0, #65536                    @ 08019FC8
    ldr r1, =lcd_shadow                      @ 08019FCC &LCD shadow
    str r0, [r1, #16]                        @ 08019FD0 w4 |= 0x10000: HOLD
    b .L0801A01C                             @ 08019FD2
.L08019FD4:                                @ reached from 08019FB0 bne (not equal / non-zero)
    uxtb r5, r5                              @ 08019FD4
    cmp r5, #2                               @ 08019FD6
    bne .L08019FFC                           @ 08019FD8
    ldr r0, =lcd_shadow                      @ 08019FDA &LCD shadow
    ldr r0, [r0, #8]                         @ 08019FDE
    bics.w r0, r0, #65536                    @ 08019FE0
    ldr r1, =lcd_shadow                      @ 08019FE4 &LCD shadow
    str r0, [r1, #8]                         @ 08019FE8 w2 &= ~0x10000: clears A-
    ldr r0, =lcd_shadow                      @ 08019FEA &LCD shadow
    ldr r0, [r0, #16]                        @ 08019FEE
    orrs.w r0, r0, #65536                    @ 08019FF0
    ldr r1, =lcd_shadow                      @ 08019FF4 &LCD shadow
    str r0, [r1, #16]                        @ 08019FF8 w4 |= 0x10000: HOLD
    b .L0801A01C                             @ 08019FFA
.L08019FFC:                                @ reached from 08019FD8 bne (not equal / non-zero)
    ldr r0, =lcd_shadow                      @ 08019FFC &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A000
    bics.w r0, r0, #65536                    @ 0801A002
    ldr r1, =lcd_shadow                      @ 0801A006 &LCD shadow
    str r0, [r1, #8]                         @ 0801A00A w2 &= ~0x10000: clears A-
    ldr r0, =lcd_shadow                      @ 0801A00C &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A010
    bics.w r0, r0, #65536                    @ 0801A012
    ldr r1, =lcd_shadow                      @ 0801A016 &LCD shadow
    str r0, [r1, #16]                        @ 0801A01A w4 &= ~0x10000: clears HOLD
.L0801A01C:                                @ reached from 08019FD2 b; 08019FFA b; falls in
    uxtb r4, r4                              @ 0801A01C
    cmp r4, #1                               @ 0801A01E
    bne .L0801A026                           @ 0801A020
    bl lcd_commit_shadow                     @ 0801A022
.L0801A026:                                @ reached from 0801A020 bne (not equal / non-zero); falls in
    pop {r0, r4, r5, pc}                     @ 0801A026
ENDFUNC fn_08019FA2
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A07C - peak-hold annunciators ("1" of 1ms and "ms")
@ Replaces : 0x0801A07C FUN_0801A07C (v2.05, 148 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x20007FE4, 0x20007FE8 (recalled peak-hold flag), peak_hold (0x200080B7); lcd_shadow word 6 bits 16 and 0
@ Spec     : analysis/lcd_map.md 4.2: with 0x20007FE4 = 0 the live peak_hold decides, otherwise the recalled copy 0x20007FE8
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A07C
    push {r4, lr}                            @ 0801A07C
    movs r4, r0                              @ 0801A07E
    ldr r0, =v_20007FE4                      @ 0801A080 &MEM view active (recalled-record view)
    ldrb r0, [r0, #0]                        @ 0801A084
    cmp r0, #0                               @ 0801A086 branch if MEM view active (recalled-record view) == 0
    beq .L0801A0C8                           @ 0801A088
    ldr r0, =v_20007FE8                      @ 0801A08A &recalled copy of the peak-hold flag
    ldrb r0, [r0, #0]                        @ 0801A08E
    cmp r0, #0                               @ 0801A090 branch if recalled copy of the peak-hold flag == 0
    beq .L0801A0AE                           @ 0801A092
    ldr r0, =lcd_shadow                      @ 0801A094 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A096
    orrs.w r0, r0, #65536                    @ 0801A098
    ldr r1, =lcd_shadow                      @ 0801A09C &LCD shadow
    str r0, [r1, #24]                        @ 0801A09E w6 |= 0x10000: "1" of 1ms
    ldr r0, =lcd_shadow                      @ 0801A0A0 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A0A2
    orrs.w r0, r0, #1                        @ 0801A0A4
    ldr r1, =lcd_shadow                      @ 0801A0A8 &LCD shadow
    str r0, [r1, #24]                        @ 0801A0AA w6 |= 0x1: ms
    b .L0801A104                             @ 0801A0AC
.L0801A0AE:                                @ reached from 0801A092 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A0AE &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A0B0
    bics.w r0, r0, #65536                    @ 0801A0B2
    ldr r1, =lcd_shadow                      @ 0801A0B6 &LCD shadow
    str r0, [r1, #24]                        @ 0801A0B8 w6 &= ~0x10000: clears "1" of 1ms
    ldr r0, =lcd_shadow                      @ 0801A0BA &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A0BC
    lsrs r0, r0, #1                          @ 0801A0BE
    lsls r0, r0, #1                          @ 0801A0C0
    ldr r1, =lcd_shadow                      @ 0801A0C2 &LCD shadow
    str r0, [r1, #24]                        @ 0801A0C4 w6 &= ~0x1: clears ms
    b .L0801A104                             @ 0801A0C6
.L0801A0C8:                                @ reached from 0801A088 beq (equal / zero)
    ldr r0, =peak_hold                       @ 0801A0C8 &peak_hold
    ldrb r0, [r0, #0]                        @ 0801A0CC
    cmp r0, #0                               @ 0801A0CE branch if peak_hold == 0
    beq .L0801A0EC                           @ 0801A0D0
    ldr r0, =lcd_shadow                      @ 0801A0D2 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A0D4
    orrs.w r0, r0, #65536                    @ 0801A0D6
    ldr r1, =lcd_shadow                      @ 0801A0DA &LCD shadow
    str r0, [r1, #24]                        @ 0801A0DC w6 |= 0x10000: "1" of 1ms
    ldr r0, =lcd_shadow                      @ 0801A0DE &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A0E0
    orrs.w r0, r0, #1                        @ 0801A0E2
    ldr r1, =lcd_shadow                      @ 0801A0E6 &LCD shadow
    str r0, [r1, #24]                        @ 0801A0E8 w6 |= 0x1: ms
    b .L0801A104                             @ 0801A0EA
.L0801A0EC:                                @ reached from 0801A0D0 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A0EC &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A0EE
    bics.w r0, r0, #65536                    @ 0801A0F0
    ldr r1, =lcd_shadow                      @ 0801A0F4 &LCD shadow
    str r0, [r1, #24]                        @ 0801A0F6 w6 &= ~0x10000: clears "1" of 1ms
    ldr r0, =lcd_shadow                      @ 0801A0F8 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A0FA
    lsrs r0, r0, #1                          @ 0801A0FC
    lsls r0, r0, #1                          @ 0801A0FE
    ldr r1, =lcd_shadow                      @ 0801A100 &LCD shadow
    str r0, [r1, #24]                        @ 0801A102 w6 &= ~0x1: clears ms
.L0801A104:                                @ reached from 0801A0AC b; 0801A0C6 b; 0801A0EA b; falls in
    uxtb r4, r4                              @ 0801A104
    cmp r4, #1                               @ 0801A106
    bne .L0801A10E                           @ 0801A108
    bl lcd_commit_shadow                     @ 0801A10A
.L0801A10E:                                @ reached from 0801A108 bne (not equal / non-zero); falls in
    pop {r4, pc}                             @ 0801A10E
ENDFUNC fn_0801A07C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A110 - 1 kHz filter annunciator (draw only)
@ Replaces : 0x0801A110 FUN_0801A110 (v2.05, 86 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x20007FE4, 0x20007FE7 (recalled copy), filter_1khz (0x200080B9); lcd_shadow word 2 bit 31
@ Spec     : analysis/lcd_map.md 4.2
@
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A110
    ldr r0, =v_20007FE4                      @ 0801A110 &MEM view active (recalled-record view)
    ldrb r0, [r0, #0]                        @ 0801A114
    cmp r0, #0                               @ 0801A116 branch if MEM view active (recalled-record view) == 0
    beq .L0801A140                           @ 0801A118
    ldr r0, =v_20007FE7                      @ 0801A11A &recalled copy of the 1 kHz filter flag
    ldrb r0, [r0, #0]                        @ 0801A11E
    cmp r0, #0                               @ 0801A120 branch if recalled copy of the 1 kHz filter flag == 0
    beq .L0801A132                           @ 0801A122
    ldr r0, =lcd_shadow                      @ 0801A124 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A126
    orrs.w r0, r0, #2147483648               @ 0801A128
    ldr r1, =lcd_shadow                      @ 0801A12C &LCD shadow
    str r0, [r1, #8]                         @ 0801A12E w2 |= 0x80000000: 1 kHz
    b .L0801A164                             @ 0801A130
.L0801A132:                                @ reached from 0801A122 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A132 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A134
    bic.w r0, r0, #2147483648                @ 0801A136
    ldr r1, =lcd_shadow                      @ 0801A13A &LCD shadow
    str r0, [r1, #8]                         @ 0801A13C w2 &= ~0x80000000: clears 1 kHz
    b .L0801A164                             @ 0801A13E
.L0801A140:                                @ reached from 0801A118 beq (equal / zero)
    ldr r0, =filter_1khz                     @ 0801A140 &filter_1khz
    ldrb r0, [r0, #0]                        @ 0801A144
    cmp r0, #0                               @ 0801A146 branch if filter_1khz == 0
    beq .L0801A158                           @ 0801A148
    ldr r0, =lcd_shadow                      @ 0801A14A &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A14C
    orrs.w r0, r0, #2147483648               @ 0801A14E
    ldr r1, =lcd_shadow                      @ 0801A152 &LCD shadow
    str r0, [r1, #8]                         @ 0801A154 w2 |= 0x80000000: 1 kHz
    b .L0801A164                             @ 0801A156
.L0801A158:                                @ reached from 0801A148 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A158 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A15A
    bic.w r0, r0, #2147483648                @ 0801A15C
    ldr r1, =lcd_shadow                      @ 0801A160 &LCD shadow
    str r0, [r1, #8]                         @ 0801A162 w2 &= ~0x80000000: clears 1 kHz
.L0801A164:                                @ reached from 0801A130 b; 0801A13E b; 0801A156 b; falls in
    bx lr                                    @ 0801A164
ENDFUNC fn_0801A110
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A17C - AC, DC and DC+AC annunciators for the current (or recalled) mode
@ Replaces : 0x0801A17C FUN_0801A17C (v2.05, 430 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x20007FE4, 0x20007FE9 (recalled acdc_active), 0x20007FEB (recalled mode), acdc_active (0x200080BA),
@            meter_mode; lcd_shadow words 1 (AC), 3 (AC_DC+), 5 (DC), bit 0
@ Spec     : analysis/lcd_map.md 4.2: AC in modes 2, 4, 16, 18, 20; DC in modes 1, 3, 17, 19, 21; with acdc_active (AC+DC) all
@            three are lit; while 0x20007FE4 is non-zero the recalled copies replace the live state
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A17C
    @ branch on MEM view: recalled-record state (0x0801A186..0x0801A256) or live state (0x0801A258..0x0801A328)

    ldr r0, =v_20007FE4                      @ 0801A17C &MEM view active (recalled-record view)
    ldrb r0, [r0, #0]                        @ 0801A180
    cmp r0, #0                               @ 0801A182 branch if MEM view active (recalled-record view) == 0
    beq .L0801A258                           @ 0801A184
    ldr r0, =v_20007FE9                      @ 0801A186 &recalled copy of acdc_active
    ldrb r0, [r0, #0]                        @ 0801A18A
    cmp r0, #0                               @ 0801A18C branch if recalled copy of acdc_active == 0
    beq .L0801A1B6                           @ 0801A18E
    ldr r0, =lcd_shadow                      @ 0801A190 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801A192
    orrs.w r0, r0, #1                        @ 0801A194
    ldr r1, =lcd_shadow                      @ 0801A198 &LCD shadow
    str r0, [r1, #20]                        @ 0801A19A w5 |= 0x1: DC
    ldr r0, =lcd_shadow                      @ 0801A19C &LCD shadow
    ldr r0, [r0, #12]                        @ 0801A19E
    orrs.w r0, r0, #1                        @ 0801A1A0
    ldr r1, =lcd_shadow                      @ 0801A1A4 &LCD shadow
    str r0, [r1, #12]                        @ 0801A1A6 w3 |= 0x1: AC_DC+
    ldr r0, =lcd_shadow                      @ 0801A1A8 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A1AA
    orrs.w r0, r0, #1                        @ 0801A1AC
    ldr r1, =lcd_shadow                      @ 0801A1B0 &LCD shadow
    str r0, [r1, #4]                         @ 0801A1B2 w1 |= 0x1: AC
    b .L0801A328                             @ 0801A1B4
.L0801A1B6:                                @ reached from 0801A18E beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A1B6 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801A1B8
    lsrs r0, r0, #1                          @ 0801A1BA
    lsls r0, r0, #1                          @ 0801A1BC
    ldr r1, =lcd_shadow                      @ 0801A1BE &LCD shadow
    str r0, [r1, #20]                        @ 0801A1C0 w5 &= ~0x1: clears DC
    ldr r0, =lcd_shadow                      @ 0801A1C2 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801A1C4
    lsrs r0, r0, #1                          @ 0801A1C6
    lsls r0, r0, #1                          @ 0801A1C8
    ldr r1, =lcd_shadow                      @ 0801A1CA &LCD shadow
    str r0, [r1, #12]                        @ 0801A1CC w3 &= ~0x1: clears AC_DC+
    ldr r0, =lcd_shadow                      @ 0801A1CE &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A1D0
    lsrs r0, r0, #1                          @ 0801A1D2
    lsls r0, r0, #1                          @ 0801A1D4
    ldr r1, =lcd_shadow                      @ 0801A1D6 &LCD shadow
    str r0, [r1, #4]                         @ 0801A1D8 w1 &= ~0x1: clears AC
    ldr r0, =v_20007FEB                      @ 0801A1DA &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A1DE
    cmp r0, #16                              @ 0801A1E0 branch if recalled mode == 16
    beq .L0801A20C                           @ 0801A1E2
    ldr r0, =v_20007FEB                      @ 0801A1E4 &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A1E8
    cmp r0, #18                              @ 0801A1EA branch if recalled mode == 18
    beq .L0801A20C                           @ 0801A1EC
    ldr r0, =v_20007FEB                      @ 0801A1EE &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A1F2
    cmp r0, #20                              @ 0801A1F4 branch if recalled mode == 20
    beq .L0801A20C                           @ 0801A1F6
    ldr r0, =v_20007FEB                      @ 0801A1F8 &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A1FC
    cmp r0, #2                               @ 0801A1FE branch if recalled mode == 2
    beq .L0801A20C                           @ 0801A200
    ldr r0, =v_20007FEB                      @ 0801A202 &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A206
    cmp r0, #4                               @ 0801A208 branch if recalled mode != 4
    bne .L0801A218                           @ 0801A20A
.L0801A20C:                                @ reached from 0801A1E2 beq (equal / zero); 0801A1EC beq (equal / zero); 0801A1F6 beq (equal / zero); 0801A200 beq (equal / zero); falls in
    ldr r0, =lcd_shadow                      @ 0801A20C &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A20E
    orrs.w r0, r0, #1                        @ 0801A210
    ldr r1, =lcd_shadow                      @ 0801A214 &LCD shadow
    str r0, [r1, #4]                         @ 0801A216 w1 |= 0x1: AC
.L0801A218:                                @ reached from 0801A20A bne (not equal / non-zero); falls in
    ldr r0, =v_20007FEB                      @ 0801A218 &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A21C
    cmp r0, #17                              @ 0801A21E branch if recalled mode == 17
    beq .L0801A24A                           @ 0801A220
    ldr r0, =v_20007FEB                      @ 0801A222 &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A226
    cmp r0, #19                              @ 0801A228 branch if recalled mode == 19
    beq .L0801A24A                           @ 0801A22A
    ldr r0, =v_20007FEB                      @ 0801A22C &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A230
    cmp r0, #21                              @ 0801A232 branch if recalled mode == 21
    beq .L0801A24A                           @ 0801A234
    ldr r0, =v_20007FEB                      @ 0801A236 &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A23A
    cmp r0, #1                               @ 0801A23C branch if recalled mode == 1
    beq .L0801A24A                           @ 0801A23E
    ldr r0, =v_20007FEB                      @ 0801A240 &recalled mode
    ldrb r0, [r0, #0]                        @ 0801A244
    cmp r0, #3                               @ 0801A246 branch if recalled mode != 3
    bne .L0801A328                           @ 0801A248
.L0801A24A:                                @ reached from 0801A220 beq (equal / zero); 0801A22A beq (equal / zero); 0801A234 beq (equal / zero); 0801A23E beq (equal / zero); falls in
    ldr r0, =lcd_shadow                      @ 0801A24A &LCD shadow
    ldr r0, [r0, #20]                        @ 0801A24C
    orrs.w r0, r0, #1                        @ 0801A24E
    ldr r1, =lcd_shadow                      @ 0801A252 &LCD shadow
    str r0, [r1, #20]                        @ 0801A254 w5 |= 0x1: DC
    b .L0801A328                             @ 0801A256
.L0801A258:                                @ reached from 0801A184 beq (equal / zero)
    ldr r0, =acdc_active                     @ 0801A258 &acdc_active
    ldrb r0, [r0, #0]                        @ 0801A25C
    cmp r0, #0                               @ 0801A25E branch if acdc_active == 0
    beq .L0801A288                           @ 0801A260
    ldr r0, =lcd_shadow                      @ 0801A262 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801A264
    orrs.w r0, r0, #1                        @ 0801A266
    ldr r1, =lcd_shadow                      @ 0801A26A &LCD shadow
    str r0, [r1, #20]                        @ 0801A26C w5 |= 0x1: DC
    ldr r0, =lcd_shadow                      @ 0801A26E &LCD shadow
    ldr r0, [r0, #12]                        @ 0801A270
    orrs.w r0, r0, #1                        @ 0801A272
    ldr r1, =lcd_shadow                      @ 0801A276 &LCD shadow
    str r0, [r1, #12]                        @ 0801A278 w3 |= 0x1: AC_DC+
    ldr r0, =lcd_shadow                      @ 0801A27A &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A27C
    orrs.w r0, r0, #1                        @ 0801A27E
    ldr r1, =lcd_shadow                      @ 0801A282 &LCD shadow
    str r0, [r1, #4]                         @ 0801A284 w1 |= 0x1: AC
    b .L0801A328                             @ 0801A286
.L0801A288:                                @ reached from 0801A260 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A288 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801A28A
    lsrs r0, r0, #1                          @ 0801A28C
    lsls r0, r0, #1                          @ 0801A28E
    ldr r1, =lcd_shadow                      @ 0801A290 &LCD shadow
    str r0, [r1, #20]                        @ 0801A292 w5 &= ~0x1: clears DC
    ldr r0, =lcd_shadow                      @ 0801A294 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801A296
    lsrs r0, r0, #1                          @ 0801A298
    lsls r0, r0, #1                          @ 0801A29A
    ldr r1, =lcd_shadow                      @ 0801A29C &LCD shadow
    str r0, [r1, #12]                        @ 0801A29E w3 &= ~0x1: clears AC_DC+
    ldr r0, =lcd_shadow                      @ 0801A2A0 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A2A2
    lsrs r0, r0, #1                          @ 0801A2A4
    lsls r0, r0, #1                          @ 0801A2A6
    ldr r1, =lcd_shadow                      @ 0801A2A8 &LCD shadow
    str r0, [r1, #4]                         @ 0801A2AA w1 &= ~0x1: clears AC
    ldr r0, =meter_mode                      @ 0801A2AC &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A2B0
    cmp r0, #16                              @ 0801A2B2 branch if mode == 16 (16 = ACuA)
    beq .L0801A2DE                           @ 0801A2B4
    ldr r0, =meter_mode                      @ 0801A2B6 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A2BA
    cmp r0, #18                              @ 0801A2BC branch if mode == 18 (18 = ACmA)
    beq .L0801A2DE                           @ 0801A2BE
    ldr r0, =meter_mode                      @ 0801A2C0 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A2C4
    cmp r0, #20                              @ 0801A2C6 branch if mode == 20 (20 = ACA)
    beq .L0801A2DE                           @ 0801A2C8
    ldr r0, =meter_mode                      @ 0801A2CA &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A2CE
    cmp r0, #2                               @ 0801A2D0 branch if mode == 2 (2 = ACV)
    beq .L0801A2DE                           @ 0801A2D2
    ldr r0, =meter_mode                      @ 0801A2D4 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A2D8
    cmp r0, #4                               @ 0801A2DA branch if mode != 4 (4 = ACmV)
    bne .L0801A2EA                           @ 0801A2DC
.L0801A2DE:                                @ reached from 0801A2B4 beq (equal / zero); 0801A2BE beq (equal / zero); 0801A2C8 beq (equal / zero); 0801A2D2 beq (equal / zero); falls in
    ldr r0, =lcd_shadow                      @ 0801A2DE &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A2E0
    orrs.w r0, r0, #1                        @ 0801A2E2
    ldr r1, =lcd_shadow                      @ 0801A2E6 &LCD shadow
    str r0, [r1, #4]                         @ 0801A2E8 w1 |= 0x1: AC
.L0801A2EA:                                @ reached from 0801A2DC bne (not equal / non-zero); falls in
    ldr r0, =meter_mode                      @ 0801A2EA &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A2EE
    cmp r0, #17                              @ 0801A2F0 branch if mode == 17 (17 = DCuA)
    beq .L0801A31C                           @ 0801A2F2
    ldr r0, =meter_mode                      @ 0801A2F4 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A2F8
    cmp r0, #19                              @ 0801A2FA branch if mode == 19 (19 = DCmA)
    beq .L0801A31C                           @ 0801A2FC
    ldr r0, =meter_mode                      @ 0801A2FE &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A302
    cmp r0, #21                              @ 0801A304 branch if mode == 21 (21 = DCA)
    beq .L0801A31C                           @ 0801A306
    ldr r0, =meter_mode                      @ 0801A308 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A30C
    cmp r0, #1                               @ 0801A30E branch if mode == 1 (1 = DCV)
    beq .L0801A31C                           @ 0801A310
    ldr r0, =meter_mode                      @ 0801A312 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A316
    cmp r0, #3                               @ 0801A318 branch if mode != 3 (3 = DCmV)
    bne .L0801A328                           @ 0801A31A
.L0801A31C:                                @ reached from 0801A2F2 beq (equal / zero); 0801A2FC beq (equal / zero); 0801A306 beq (equal / zero); 0801A310 beq (equal / zero); falls in
    ldr r0, =lcd_shadow                      @ 0801A31C &LCD shadow
    ldr r0, [r0, #20]                        @ 0801A31E
    orrs.w r0, r0, #1                        @ 0801A320
    ldr r1, =lcd_shadow                      @ 0801A324 &LCD shadow
    str r0, [r1, #20]                        @ 0801A326 w5 |= 0x1: DC
.L0801A328:                                @ reached from 0801A1B4 b; 0801A248 bne (not equal / non-zero); 0801A256 b; 0801A286 b; 0801A31A bne (not equal / non-zero); falls in
    bx lr                                    @ 0801A328
ENDFUNC fn_0801A17C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A32A - MEM annunciator
@ Replaces : 0x0801A32A FUN_0801A32A (v2.05, 70 bytes)
@ In       : r0 = 1 commit afterwards, 0 only draw
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x20007FE1, 0x20007FE3, 0x20007FE4; lcd_shadow word 0 bit 16
@ Spec     : analysis/lcd_map.md 4.2: lit when (0x20007FE1 AND 0x20007FE3) OR 0x20007FE4 is non-zero
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A32A
    push {r4, lr}                            @ 0801A32A
    movs r4, r0                              @ 0801A32C
    ldr r0, =v_20007FE1                      @ 0801A32E &flag FE1 (lcd_map.md 4)
    ldrb r0, [r0, #0]                        @ 0801A332
    ldr r1, =v_20007FE3                      @ 0801A334 &flag FE3 (lcd_map.md 4)
    ldrb r1, [r1, #0]                        @ 0801A338
    ands r0, r1                              @ 0801A33A
    ldr r1, =v_20007FE4                      @ 0801A33C &MEM view active (recalled-record view)
    ldrb r1, [r1, #0]                        @ 0801A340
    orrs r0, r1                              @ 0801A342
    uxtb r0, r0                              @ 0801A344
    cmp r0, #0                               @ 0801A346
    beq .L0801A358                           @ 0801A348
    ldr r0, =lcd_shadow                      @ 0801A34A &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A34C
    orrs.w r0, r0, #65536                    @ 0801A34E
    ldr r1, =lcd_shadow                      @ 0801A352 &LCD shadow
    str r0, [r1, #0]                         @ 0801A354 w0 |= 0x10000: MEM
    b .L0801A364                             @ 0801A356
.L0801A358:                                @ reached from 0801A348 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A358 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A35A
    bics.w r0, r0, #65536                    @ 0801A35C
    ldr r1, =lcd_shadow                      @ 0801A360 &LCD shadow
    str r0, [r1, #0]                         @ 0801A362 w0 &= ~0x10000: clears MEM
.L0801A364:                                @ reached from 0801A356 b; falls in
    uxtb r4, r4                              @ 0801A364
    cmp r4, #1                               @ 0801A366
    bne .L0801A36E                           @ 0801A368
    bl lcd_commit_shadow                     @ 0801A36A
.L0801A36E:                                @ reached from 0801A368 bne (not equal / non-zero); falls in
    pop {r4, pc}                             @ 0801A36E
ENDFUNC fn_0801A32A
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A370 - high-voltage warning icon
@ Replaces : 0x0801A370 FUN_0801A370 (v2.05, 38 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x200080B1; lcd_shadow word 1 bit 7
@ Spec     : analysis/lcd_map.md 4.2 (lightning icon; set by fn_0800E848)
@
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A370
    ldr r0, =v_200080B1                      @ 0801A370 &high-voltage warning flag
    ldrb r0, [r0, #0]                        @ 0801A374
    cmp r0, #0                               @ 0801A376 branch if high-voltage warning flag == 0
    beq .L0801A388                           @ 0801A378
    ldr r0, =lcd_shadow                      @ 0801A37A &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A37C
    orrs.w r0, r0, #128                      @ 0801A37E
    ldr r1, =lcd_shadow                      @ 0801A382 &LCD shadow
    str r0, [r1, #4]                         @ 0801A384 w1 |= 0x80: high-voltage warning icon
    b .L0801A394                             @ 0801A386
.L0801A388:                                @ reached from 0801A378 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A388 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A38A
    bics.w r0, r0, #128                      @ 0801A38C
    ldr r1, =lcd_shadow                      @ 0801A390 &LCD shadow
    str r0, [r1, #4]                         @ 0801A392 w1 &= ~0x80: clears high-voltage warning icon
.L0801A394:                                @ reached from 0801A386 b; falls in
    bx lr                                    @ 0801A394
ENDFUNC fn_0801A370
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A3A4 - temperature unit annunciators (degree C / degree F)
@ Replaces : 0x0801A3A4 FUN_0801A3A4 (v2.05, 122 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : reads meter_mode, 0x200080AB; lcd_shadow words 4 and 6 bit 11
@ Spec     : analysis/lcd_map.md 4.1: in mode 5 degree C when 0x200080AB != 0, degree F when it is 0; both off in other modes
@
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A3A4
    ldr r0, =meter_mode                      @ 0801A3A4 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A3A8
    cmp r0, #5                               @ 0801A3AA branch if mode != 5 (5 = TEMP)
    bne .L0801A3FC                           @ 0801A3AC
    ldr r0, =v_200080AB                      @ 0801A3AE &temperature unit flag (non-zero = degC, 0 = degF)
    ldrb r0, [r0, #0]                        @ 0801A3B2
    cmp r0, #0                               @ 0801A3B4 branch if temperature unit flag (non-zero = degC, 0 = degF) == 0
    beq .L0801A3DA                           @ 0801A3B6
    ldr r0, =lcd_shadow                      @ 0801A3B8 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A3BC
    orrs.w r0, r0, #2048                     @ 0801A3BE
    ldr r1, =lcd_shadow                      @ 0801A3C2 &LCD shadow
    str r0, [r1, #16]                        @ 0801A3C6 w4 |= 0x800: degree C
    ldr r0, =lcd_shadow                      @ 0801A3C8 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A3CC
    bics.w r0, r0, #2048                     @ 0801A3CE
    ldr r1, =lcd_shadow                      @ 0801A3D2 &LCD shadow
    str r0, [r1, #24]                        @ 0801A3D6 w6 &= ~0x800: clears degree F
    b .L0801A41C                             @ 0801A3D8
.L0801A3DA:                                @ reached from 0801A3B6 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 0801A3DA &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A3DE
    bics.w r0, r0, #2048                     @ 0801A3E0
    ldr r1, =lcd_shadow                      @ 0801A3E4 &LCD shadow
    str r0, [r1, #16]                        @ 0801A3E8 w4 &= ~0x800: clears degree C
    ldr r0, =lcd_shadow                      @ 0801A3EA &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A3EE
    orrs.w r0, r0, #2048                     @ 0801A3F0
    ldr r1, =lcd_shadow                      @ 0801A3F4 &LCD shadow
    str r0, [r1, #24]                        @ 0801A3F8 w6 |= 0x800: degree F
    b .L0801A41C                             @ 0801A3FA
.L0801A3FC:                                @ reached from 0801A3AC bne (not equal / non-zero)
    ldr r0, =lcd_shadow                      @ 0801A3FC &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A400
    bics.w r0, r0, #2048                     @ 0801A402
    ldr r1, =lcd_shadow                      @ 0801A406 &LCD shadow
    str r0, [r1, #16]                        @ 0801A40A w4 &= ~0x800: clears degree C
    ldr r0, =lcd_shadow                      @ 0801A40C &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A410
    bics.w r0, r0, #2048                     @ 0801A412
    ldr r1, =lcd_shadow                      @ 0801A416 &LCD shadow
    str r0, [r1, #24]                        @ 0801A41A w6 &= ~0x800: clears degree F
.L0801A41C:                                @ reached from 0801A3D8 b; 0801A3FA b; falls in
    bx lr                                    @ 0801A41C
ENDFUNC fn_0801A3A4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A440 - sub-display unit annunciators for the current setup page
@ Replaces : 0x0801A440 FUN_0801A440 (v2.05, 660 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; called by fn_08016D34 when the page code 0x20008037 changed or 0x20008063 is set
@ RAM      : reads 0x2000808A, page code 0x20008037, meter_mode, 0x200080A5, 0x2000803E, 0x200080C2, acdc_active;
@            lcd_shadow word 2 (V bit 17, A bit 18), word 0 (m bit 18, dB bit 19), word 4 (k bit 17), word 6 (Hz bit 17,
@            Ohm bit 18); 0x2000805B = 1 at the end
@ Spec     : analysis/lcd_map.md 4.3: nothing in calibration mode (0x2000808A); the group is cleared first (fn_0801A760);
@            page 'd' (100) draws no unit; SubV for the battery page and for burden / diode / VA pages, Subm and SubdB for
@            the dBm page and the burden page, Subk and SubHz for the frequency pages when 0x2000803E > 1, SubR for the
@            BEEP threshold page, SubA / Subm for the VA modes through fn_0801A6D8, degree C / F in mode 5 through fn_0801A3A4
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A440
    push {r7, lr}                            @ 0801A440
    @ no unit change while the meter is in calibration mode
    ldr r0, =v_2000808A                      @ 0801A442 &calibration mode flag
    ldrb r0, [r0, #0]                        @ 0801A446
    cmp r0, #0                               @ 0801A448 branch if calibration mode flag != 0
    bne .L0801A6D2                           @ 0801A44A
    @ clear the sub-display unit group
    bl fn_0801A760                           @ 0801A44E
    @ page 'd' (0x64): leave the units cleared

    ldr r0, =v_20008037                      @ 0801A452 &setup / sub-display page code
    ldrb r0, [r0, #0]                        @ 0801A456
    cmp r0, #100                             @ 0801A458 branch if setup / sub-display page code == 100
    beq .L0801A6D2                           @ 0801A45A
    ldr r0, =meter_mode                      @ 0801A45E &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A462
    cmp r0, #16                              @ 0801A464 branch if mode == 16 (16 = ACuA)
    beq .L0801A49A                           @ 0801A466
    ldr r0, =meter_mode                      @ 0801A468 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A46C
    cmp r0, #18                              @ 0801A46E branch if mode == 18 (18 = ACmA)
    beq .L0801A49A                           @ 0801A470
    ldr r0, =meter_mode                      @ 0801A472 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A476
    cmp r0, #20                              @ 0801A478 branch if mode == 20 (20 = ACA)
    beq .L0801A49A                           @ 0801A47A
    ldr r0, =meter_mode                      @ 0801A47C &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A480
    cmp r0, #17                              @ 0801A482 branch if mode == 17 (17 = DCuA)
    beq .L0801A49A                           @ 0801A484
    ldr r0, =meter_mode                      @ 0801A486 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A48A
    cmp r0, #19                              @ 0801A48C branch if mode == 19 (19 = DCmA)
    beq .L0801A49A                           @ 0801A48E
    ldr r0, =meter_mode                      @ 0801A490 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A494
    cmp r0, #21                              @ 0801A496 branch if mode != 21 (21 = DCA)
    bne .L0801A4D0                           @ 0801A498
.L0801A49A:                                @ reached from 0801A466 beq (equal / zero); 0801A470 beq (equal / zero); 0801A47A beq (equal / zero); 0801A484 beq (equal / zero); 0801A48E beq (equal / zero); falls in
    ldr r0, =v_20008037                      @ 0801A49A &setup / sub-display page code
    ldrb r0, [r0, #0]                        @ 0801A49E
    cmp r0, #11                              @ 0801A4A0 branch if setup / sub-display page code != 11
    bne .L0801A4D0                           @ 0801A4A2
    ldr r0, =v_200080A5                      @ 0801A4A4 &burden option
    ldrb r0, [r0, #0]                        @ 0801A4A8
    cmp r0, #0                               @ 0801A4AA branch if burden option == 0
    beq .L0801A4D0                           @ 0801A4AC
    ldr r0, =lcd_shadow                      @ 0801A4AE &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A4B2
    orrs.w r0, r0, #262144                   @ 0801A4B4
    ldr r1, =lcd_shadow                      @ 0801A4B8 &LCD shadow
    str r0, [r1, #0]                         @ 0801A4BC w0 |= 0x40000: m (sub)
    ldr r0, =lcd_shadow                      @ 0801A4BE &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A4C2
    orrs.w r0, r0, #131072                   @ 0801A4C4
    ldr r1, =lcd_shadow                      @ 0801A4C8 &LCD shadow
    str r0, [r1, #8]                         @ 0801A4CC w2 |= 0x20000: V (sub)
    b .L0801A6CA                             @ 0801A4CE
.L0801A4D0:                                @ reached from 0801A498 bne (not equal / non-zero); 0801A4A2 bne (not equal / non-zero); 0801A4AC beq (equal / zero)
    ldr r0, =v_20008037                      @ 0801A4D0 &setup / sub-display page code
    ldrb r0, [r0, #0]                        @ 0801A4D4
    cmp r0, #12                              @ 0801A4D6 branch if setup / sub-display page code != 12
    bne .L0801A532                           @ 0801A4D8
    ldr r0, =meter_mode                      @ 0801A4DA &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A4DE
    cmp r0, #16                              @ 0801A4E0 branch if mode == 16 (16 = ACuA)
    beq .L0801A4FA                           @ 0801A4E2
    ldr r0, =meter_mode                      @ 0801A4E4 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A4E8
    cmp r0, #18                              @ 0801A4EA branch if mode == 18 (18 = ACmA)
    beq .L0801A4FA                           @ 0801A4EC
    ldr r0, =meter_mode                      @ 0801A4EE &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A4F2
    cmp r0, #20                              @ 0801A4F4 branch if mode != 20 (20 = ACA)
    bne .L0801A6CA                           @ 0801A4F6
.L0801A4FA:                                @ reached from 0801A4E2 beq (equal / zero); 0801A4EC beq (equal / zero); falls in
    ldr r0, =v_200080A5                      @ 0801A4FA &burden option
    ldrb r0, [r0, #0]                        @ 0801A4FE
    cmp r0, #0                               @ 0801A500 branch if burden option == 0
    beq .L0801A6CA                           @ 0801A502
    ldr r0, =v_2000803E                      @ 0801A506 &frequency range index
    ldrb r0, [r0, #0]                        @ 0801A50A
    cmp r0, #2                               @ 0801A50C branch if frequency range index < 2
    blt .L0801A520                           @ 0801A50E
    ldr r0, =lcd_shadow                      @ 0801A510 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A514
    orrs.w r0, r0, #131072                   @ 0801A516
    ldr r1, =lcd_shadow                      @ 0801A51A &LCD shadow
    str r0, [r1, #16]                        @ 0801A51E w4 |= 0x20000: k (sub)
.L0801A520:                                @ reached from 0801A50E blt (signed <); falls in
    ldr r0, =lcd_shadow                      @ 0801A520 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A524
    orrs.w r0, r0, #131072                   @ 0801A526
    ldr r1, =lcd_shadow                      @ 0801A52A &LCD shadow
    str r0, [r1, #24]                        @ 0801A52E w6 |= 0x20000: Hz (sub)
    b .L0801A6CA                             @ 0801A530
.L0801A532:                                @ reached from 0801A4D8 bne (not equal / non-zero)
    ldr r0, =v_20008037                      @ 0801A532 &setup / sub-display page code
    ldrb r0, [r0, #0]                        @ 0801A536
    cmp r0, #11                              @ 0801A538 branch if setup / sub-display page code != 11
    bne .L0801A5C0                           @ 0801A53A
    ldr r0, =meter_mode                      @ 0801A53C &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A540
    cmp r0, #2                               @ 0801A542 branch if mode != 2 (2 = ACV)
    bne .L0801A568                           @ 0801A544
    ldr r0, =lcd_shadow                      @ 0801A546 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A54A
    orrs.w r0, r0, #524288                   @ 0801A54C
    ldr r1, =lcd_shadow                      @ 0801A550 &LCD shadow
    str r0, [r1, #0]                         @ 0801A554 w0 |= 0x80000: sub dB (SubdB; the digit-4 x slot)
    ldr r0, =set_dbm_ref                     @ IMP-08: reference code
    ldrb r0, [r0, #0]
    cmp r0, #3
    beq .L0801A6CA                           @ IMP-08: dBV: dB alone, no m
    ldr r0, =lcd_shadow                      @ 0801A556 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A55A
    orrs.w r0, r0, #262144                   @ 0801A55C
    ldr r1, =lcd_shadow                      @ 0801A560 &LCD shadow
    str r0, [r1, #0]                         @ 0801A564 w0 |= 0x40000: m (sub)
    b .L0801A6CA                             @ 0801A566
.L0801A568:                                @ reached from 0801A544 bne (not equal / non-zero)
    ldr r0, =meter_mode                      @ 0801A568 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A56C
    cmp r0, #16                              @ 0801A56E branch if mode == 16 (16 = ACuA)
    beq .L0801A588                           @ 0801A570
    ldr r0, =meter_mode                      @ 0801A572 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A576
    cmp r0, #18                              @ 0801A578 branch if mode == 18 (18 = ACmA)
    beq .L0801A588                           @ 0801A57A
    ldr r0, =meter_mode                      @ 0801A57C &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A580
    cmp r0, #20                              @ 0801A582 branch if mode != 20 (20 = ACA)
    bne .L0801A6CA                           @ 0801A584
.L0801A588:                                @ reached from 0801A570 beq (equal / zero); 0801A57A beq (equal / zero); falls in
    ldr r0, =v_200080A5                      @ 0801A588 &burden option
    ldrb r0, [r0, #0]                        @ 0801A58C
    cmp r0, #0                               @ 0801A58E branch if burden option != 0
    bne .L0801A6CA                           @ 0801A590
    ldr r0, =v_2000803E                      @ 0801A594 &frequency range index
    ldrb r0, [r0, #0]                        @ 0801A598
    cmp r0, #2                               @ 0801A59A branch if frequency range index < 2
    blt .L0801A5AE                           @ 0801A59C
    ldr r0, =lcd_shadow                      @ 0801A59E &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A5A2
    orrs.w r0, r0, #131072                   @ 0801A5A4
    ldr r1, =lcd_shadow                      @ 0801A5A8 &LCD shadow
    str r0, [r1, #16]                        @ 0801A5AC w4 |= 0x20000: k (sub)
.L0801A5AE:                                @ reached from 0801A59C blt (signed <); falls in
    ldr r0, =lcd_shadow                      @ 0801A5AE &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A5B2
    orrs.w r0, r0, #131072                   @ 0801A5B4
    ldr r1, =lcd_shadow                      @ 0801A5B8 &LCD shadow
    str r0, [r1, #24]                        @ 0801A5BC w6 |= 0x20000: Hz (sub)
    b .L0801A6CA                             @ 0801A5BE
.L0801A5C0:                                @ reached from 0801A53A bne (not equal / non-zero)
    ldr r0, =v_20008037                      @ 0801A5C0 &setup / sub-display page code
    ldrb r0, [r0, #0]                        @ 0801A5C4
    cmp r0, #10                              @ 0801A5C6 branch if setup / sub-display page code != 10
    bne .L0801A6A0                           @ 0801A5C8
    ldr r0, =meter_mode                      @ 0801A5CA &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A5CC
    cmp r0, #11                              @ 0801A5CE branch if mode != 11 (11 = DIODE)
    bne .L0801A5E8                           @ 0801A5D0
    ldr r0, =lcd_shadow                      @ 0801A5D2 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A5D6
    orrs.w r0, r0, #131072                   @ 0801A5D8
    ldr r1, =lcd_shadow                      @ 0801A5DC &LCD shadow
    str r0, [r1, #8]                         @ 0801A5E0 w2 |= 0x20000: V (sub)
    bl fn_0801A3A4                           @ 0801A5E2
    b .L0801A6CA                             @ 0801A5E6
.L0801A5E8:                                @ reached from 0801A5D0 bne (not equal / non-zero)
    ldr r0, =meter_mode                      @ 0801A5E8 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A5EA
    cmp r0, #13                              @ 0801A5EC branch if mode == 13 (13 = uVA)
    beq .L0801A618                           @ 0801A5EE
    ldr r0, =meter_mode                      @ 0801A5F0 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A5F2
    cmp r0, #14                              @ 0801A5F4 branch if mode == 14 (14 = mVA)
    beq .L0801A618                           @ 0801A5F6
    ldr r0, =meter_mode                      @ 0801A5F8 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A5FA
    cmp r0, #15                              @ 0801A5FC branch if mode == 15 (15 = VA)
    beq .L0801A618                           @ 0801A5FE
    ldr r0, =meter_mode                      @ 0801A600 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A602
    cmp r0, #22                              @ 0801A604 branch if mode == 22 (22 = DCuVA)
    beq .L0801A618                           @ 0801A606
    ldr r0, =meter_mode                      @ 0801A608 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A60A
    cmp r0, #23                              @ 0801A60C branch if mode == 23 (23 = DCmVA)
    beq .L0801A618                           @ 0801A60E
    ldr r0, =meter_mode                      @ 0801A610 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A612
    cmp r0, #24                              @ 0801A614 branch if mode != 24 (24 = DCVA)
    bne .L0801A63A                           @ 0801A616
.L0801A618:                                @ reached from 0801A5EE beq (equal / zero); 0801A5F6 beq (equal / zero); 0801A5FE beq (equal / zero); 0801A606 beq (equal / zero); 0801A60E beq (equal / zero); falls in
    ldr r0, =v_200080C2                      @ 0801A618 &VA sub-display selector (0 = V, 1 = A)
    ldrb r0, [r0, #0]                        @ 0801A61C
    cmp r0, #0                               @ 0801A61E branch if VA sub-display selector (0 = V, 1 = A) != 0
    bne .L0801A634                           @ 0801A620
    ldr r0, =lcd_shadow                      @ 0801A622 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A626
    orrs.w r0, r0, #131072                   @ 0801A628
    ldr r1, =lcd_shadow                      @ 0801A62C &LCD shadow
    str r0, [r1, #8]                         @ 0801A630 w2 |= 0x20000: V (sub)
    b .L0801A6CA                             @ 0801A632
.L0801A634:                                @ reached from 0801A620 bne (not equal / non-zero)
    bl fn_0801A6D8                           @ 0801A634
    b .L0801A6CA                             @ 0801A638
.L0801A63A:                                @ reached from 0801A616 bne (not equal / non-zero)
    ldr r0, =meter_mode                      @ 0801A63A &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A63C
    cmp r0, #10                              @ 0801A63E branch if mode != 10 (10 = BEEP)
    bne .L0801A654                           @ 0801A640
    ldr r0, =lcd_shadow                      @ 0801A642 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A646
    orrs.w r0, r0, #262144                   @ 0801A648
    ldr r1, =lcd_shadow                      @ 0801A64C &LCD shadow
    str r0, [r1, #24]                        @ 0801A650 w6 |= 0x40000: Ohm (sub) (probable)
    b .L0801A6CA                             @ 0801A652
.L0801A654:                                @ reached from 0801A640 bne (not equal / non-zero)
    ldr r0, =meter_mode                      @ 0801A654 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A656
    cmp r0, #4                               @ 0801A658 branch if mode == 4 (4 = ACmV)
    beq .L0801A66E                           @ 0801A65A
    ldr r0, =meter_mode                      @ 0801A65C &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A65E
    cmp r0, #2                               @ 0801A660 branch if mode != 2 (2 = ACV)
    bne .L0801A69A                           @ 0801A662
    ldr r0, =acdc_active                     @ 0801A664 &acdc_active
    ldrb r0, [r0, #0]                        @ 0801A668
    cmp r0, #0                               @ 0801A66A branch if acdc_active != 0
    bne .L0801A69A                           @ 0801A66C
.L0801A66E:                                @ reached from 0801A65A beq (equal / zero); falls in
    ldr r0, =v_2000803E                      @ 0801A66E &frequency range index
    ldrb r0, [r0, #0]                        @ 0801A672
    cmp r0, #2                               @ 0801A674 branch if frequency range index < 2
    blt .L0801A688                           @ 0801A676
    ldr r0, =lcd_shadow                      @ 0801A678 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A67C
    orrs.w r0, r0, #131072                   @ 0801A67E
    ldr r1, =lcd_shadow                      @ 0801A682 &LCD shadow
    str r0, [r1, #16]                        @ 0801A686 w4 |= 0x20000: k (sub)
.L0801A688:                                @ reached from 0801A676 blt (signed <); falls in
    ldr r0, =lcd_shadow                      @ 0801A688 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A68C
    orrs.w r0, r0, #131072                   @ 0801A68E
    ldr r1, =lcd_shadow                      @ 0801A692 &LCD shadow
    str r0, [r1, #24]                        @ 0801A696 w6 |= 0x20000: Hz (sub)
    b .L0801A6CA                             @ 0801A698
.L0801A69A:                                @ reached from 0801A662 bne (not equal / non-zero); 0801A66C bne (not equal / non-zero)
    bl fn_0801A3A4                           @ 0801A69A
    b .L0801A6CA                             @ 0801A69E
.L0801A6A0:                                @ reached from 0801A5C8 bne (not equal / non-zero)
    ldr r0, =v_20008037                      @ 0801A6A0 &setup / sub-display page code
    ldrb r0, [r0, #0]                        @ 0801A6A4
    cmp r0, #1                               @ 0801A6A6 branch if setup / sub-display page code != 1
    bne .L0801A6BC                           @ 0801A6A8
    ldr r0, =lcd_shadow                      @ 0801A6AA &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A6AE
    orrs.w r0, r0, #131072                   @ 0801A6B0
    ldr r1, =lcd_shadow                      @ 0801A6B4 &LCD shadow
    str r0, [r1, #8]                         @ 0801A6B8 w2 |= 0x20000: V (sub)
    b .L0801A6CA                             @ 0801A6BA
.L0801A6BC:                                @ reached from 0801A6A8 bne (not equal / non-zero)
    ldr r0, =v_20008037                      @ 0801A6BC &setup / sub-display page code
    ldrb r0, [r0, #0]                        @ 0801A6C0
    cmp r0, #2                               @ 0801A6C2 branch if setup / sub-display page code == 2
    beq .L0801A6CA                           @ 0801A6C4
    bl fn_0801A3A4                           @ 0801A6C6
.L0801A6CA:                                @ reached from 0801A4CE b; 0801A4F6 bne (not equal / non-zero); 0801A502 beq (equal / zero); 0801A530 b; 0801A566 b; 0801A584 bne (not equal / non-zero); 0801A590 bne (not equal / non-zero); 0801A5BE b; 0801A5E6 b; 0801A632 b; 0801A638 b; 0801A652 b; 0801A698 b; 0801A69E b; 0801A6BA b; 0801A6C4 beq (equal / zero); falls in
    movs r0, #1                              @ 0801A6CA
    ldr r1, =v_2000805B                      @ 0801A6CC &LCD commit request
    strb r0, [r1, #0]                        @ 0801A6D0
.L0801A6D2:                                @ reached from 0801A44A bne (not equal / non-zero); 0801A45A beq (equal / zero); falls in
    pop {r0, pc}                             @ 0801A6D2
ENDFUNC fn_0801A440
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A6D8 - sub-display A and m units for the VA modes
@ Replaces : 0x0801A6D8 FUN_0801A6D8 (v2.05, 110 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : reads meter_mode, 0x200080C7; lcd_shadow word 0 (m, bit 18) and word 2 (A, bit 18)
@ Spec     : analysis/lcd_map.md 4.3: A for all VA modes; m for modes 13, 14, 22, 23 and for modes 15, 24 when 0x200080C7 = 0
@
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A6D8
    ldr r0, =meter_mode                      @ 0801A6D8 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A6DA
    cmp r0, #14                              @ 0801A6DC branch if mode == 14 (14 = mVA)
    beq .L0801A6F8                           @ 0801A6DE
    ldr r0, =meter_mode                      @ 0801A6E0 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A6E2
    cmp r0, #13                              @ 0801A6E4 branch if mode == 13 (13 = uVA)
    beq .L0801A6F8                           @ 0801A6E6
    ldr r0, =meter_mode                      @ 0801A6E8 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A6EA
    cmp r0, #23                              @ 0801A6EC branch if mode == 23 (23 = DCmVA)
    beq .L0801A6F8                           @ 0801A6EE
    ldr r0, =meter_mode                      @ 0801A6F0 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A6F2
    cmp r0, #22                              @ 0801A6F4 branch if mode != 22 (22 = DCuVA)
    bne .L0801A70A                           @ 0801A6F6
.L0801A6F8:                                @ reached from 0801A6DE beq (equal / zero); 0801A6E6 beq (equal / zero); 0801A6EE beq (equal / zero); falls in
    ldr r0, =lcd_shadow                      @ 0801A6F8 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A6FC
    orrs.w r0, r0, #262144                   @ 0801A6FE
    ldr r1, =lcd_shadow                      @ 0801A702 &LCD shadow
    str r0, [r1, #0]                         @ 0801A706 w0 |= 0x40000: m (sub)
    b .L0801A734                             @ 0801A708
.L0801A70A:                                @ reached from 0801A6F6 bne (not equal / non-zero)
    ldr r0, =meter_mode                      @ 0801A70A &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A70C
    cmp r0, #15                              @ 0801A70E branch if mode == 15 (15 = VA)
    beq .L0801A71A                           @ 0801A710
    ldr r0, =meter_mode                      @ 0801A712 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801A714
    cmp r0, #24                              @ 0801A716 branch if mode != 24 (24 = DCVA)
    bne .L0801A734                           @ 0801A718
.L0801A71A:                                @ reached from 0801A710 beq (equal / zero); falls in
    ldr r0, =v_200080C7                      @ 0801A71A &VA sub-range flag
    ldrb r0, [r0, #0]                        @ 0801A71E
    cmp r0, #0                               @ 0801A720 branch if VA sub-range flag != 0
    bne .L0801A734                           @ 0801A722
    ldr r0, =lcd_shadow                      @ 0801A724 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A728
    orrs.w r0, r0, #262144                   @ 0801A72A
    ldr r1, =lcd_shadow                      @ 0801A72E &LCD shadow
    str r0, [r1, #0]                         @ 0801A732 w0 |= 0x40000: m (sub)
.L0801A734:                                @ reached from 0801A708 b; 0801A718 bne (not equal / non-zero); 0801A722 bne (not equal / non-zero); falls in
    ldr r0, =lcd_shadow                      @ 0801A734 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A738
    orrs.w r0, r0, #262144                   @ 0801A73A
    ldr r1, =lcd_shadow                      @ 0801A73E &LCD shadow
    str r0, [r1, #8]                         @ 0801A742 w2 |= 0x40000: A (sub)
    bx lr                                    @ 0801A744
ENDFUNC fn_0801A6D8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A760 - clear the sub-display unit group
@ Replaces : 0x0801A760 FUN_0801A760 (v2.05, 178 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow words 0, 2, 4, 6 (sub minus, SubV, SubA, Subm, SubdB, Subk, SubHz, SubR and the unmapped bits of the group)
@ Spec     : analysis/lcd_map.md 4.3 and 5
@
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A760
    ldr r0, =lcd_shadow                      @ 0801A760 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A764
    bics.w r0, r0, #262144                   @ 0801A766
    ldr r1, =lcd_shadow                      @ 0801A76A &LCD shadow
    str r0, [r1, #16]                        @ 0801A76E w4 &= ~0x40000: clears unmapped (only ever cleared)
    ldr r0, =lcd_shadow                      @ 0801A770 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A774
    bics.w r0, r0, #536870912                @ 0801A776
    ldr r1, =lcd_shadow                      @ 0801A77A &LCD shadow
    str r0, [r1, #16]                        @ 0801A77E w4 &= ~0x20000000: clears sub minus
    ldr r0, =lcd_shadow                      @ 0801A780 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A784
    bics.w r0, r0, #536870912                @ 0801A786
    ldr r1, =lcd_shadow                      @ 0801A78A &LCD shadow
    str r0, [r1, #8]                         @ 0801A78E w2 &= ~0x20000000: clears unmapped (only ever cleared)
    ldr r0, =lcd_shadow                      @ 0801A790 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A794
    bics.w r0, r0, #536870912                @ 0801A796
    ldr r1, =lcd_shadow                      @ 0801A79A &LCD shadow
    str r0, [r1, #24]                        @ 0801A79E w6 &= ~0x20000000: clears unmapped (only ever cleared)
    ldr r0, =lcd_shadow                      @ 0801A7A0 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A7A4
    bics.w r0, r0, #262144                   @ 0801A7A6
    ldr r1, =lcd_shadow                      @ 0801A7AA &LCD shadow
    str r0, [r1, #24]                        @ 0801A7AE w6 &= ~0x40000: clears Ohm (sub) (probable)
    ldr r0, =lcd_shadow                      @ 0801A7B0 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A7B4
    bics.w r0, r0, #524288                   @ 0801A7B6
    ldr r1, =lcd_shadow                      @ 0801A7BA &LCD shadow
    str r0, [r1, #0]                         @ 0801A7BE w0 &= ~0x80000: clears sub dB (SubdB; the digit-4 x slot)
    ldr r0, =lcd_shadow                      @ 0801A7C0 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A7C4
    bics.w r0, r0, #262144                   @ 0801A7C6
    ldr r1, =lcd_shadow                      @ 0801A7CA &LCD shadow
    str r0, [r1, #0]                         @ 0801A7CE w0 &= ~0x40000: clears m (sub)
    ldr r0, =lcd_shadow                      @ 0801A7D0 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A7D4
    bics.w r0, r0, #262144                   @ 0801A7D6
    ldr r1, =lcd_shadow                      @ 0801A7DA &LCD shadow
    str r0, [r1, #8]                         @ 0801A7DE w2 &= ~0x40000: clears A (sub)
    ldr r0, =lcd_shadow                      @ 0801A7E0 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A7E4
    bics.w r0, r0, #131072                   @ 0801A7E6
    ldr r1, =lcd_shadow                      @ 0801A7EA &LCD shadow
    str r0, [r1, #8]                         @ 0801A7EE w2 &= ~0x20000: clears V (sub)
    ldr r0, =lcd_shadow                      @ 0801A7F0 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A7F4
    bics.w r0, r0, #131072                   @ 0801A7F6
    ldr r1, =lcd_shadow                      @ 0801A7FA &LCD shadow
    str r0, [r1, #16]                        @ 0801A7FE w4 &= ~0x20000: clears k (sub)
    ldr r0, =lcd_shadow                      @ 0801A800 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A804
    bics.w r0, r0, #131072                   @ 0801A806
    ldr r1, =lcd_shadow                      @ 0801A80A &LCD shadow
    str r0, [r1, #24]                        @ 0801A80E w6 &= ~0x20000: clears Hz (sub)
    bx lr                                    @ 0801A810
ENDFUNC fn_0801A760
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A81C - clear the 16 shadow words
@ Replaces : 0x0801A81C FUN_0801A81C (v2.05, 50 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Clobbers : r0-r2, flags
@ Context  : main only
@ RAM      : lcd_shadow (0x20007790..0x200077CF), 0x2000805B
@ Spec     : analysis/lcd_map.md 1 (16 words)
@ Deviation: HW-07 / OF-31 / IMP-06.  v2.05 first waits, without a bound, until LCD_SR.UDR is clear (0x0801A820..0x0801A828),
@            although only the RAM shadow is written.  Baseline: the wait is kept with the LCD_WAIT_POLLS bound.  Production:
@            the wait is dropped (the shadow is plain RAM; the commit has its own UDR handling).
@ -----------------------------------------------------------------------------
FUNC fn_0801A81C
    push {r4, lr}                            @ 0801A81C
    @ clear the 16 words, index r4 = 0..15

    movs r0, #0                              @ 0801A82A
    movs r4, r0                              @ 0801A82C
.L0801A82E:                                @ reached from 0801A842 b; falls in
    uxtb r4, r4                              @ 0801A82E
    cmp r4, #16                              @ 0801A830
    bcs .L0801A844                           @ 0801A832
    movs r0, #0                              @ 0801A834
    ldr r1, =lcd_shadow                      @ 0801A836 &LCD shadow
    uxtb r4, r4                              @ 0801A83A
    str.w r0, [r1, r4, lsl #2]               @ 0801A83C
    adds r4, r4, #1                          @ 0801A840
    b .L0801A82E                             @ 0801A842
.L0801A844:                                @ reached from 0801A832 bcs (unsigned >=)
    movs r0, #1                              @ 0801A844
    ldr r1, =v_2000805B                      @ 0801A846 &LCD commit request
    strb r0, [r1, #0]                        @ 0801A84A
    pop {r4, pc}                             @ 0801A84C
ENDFUNC fn_0801A81C
    .ltorg
    .global lcd_clear_shadow
    .set lcd_clear_shadow, fn_0801A81C

@ -----------------------------------------------------------------------------
@ fn_0801A89C - light every segment (all-segments test)
@ Replaces : 0x0801A89C FUN_0801A89C (v2.05, 122 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only; called by the short-press handler (RANGE key in the power-on window, DESIGN.md 7.1)
@ RAM      : lcd_shadow words 0, 2, 4, 6 = 0xFFFFFFFF; words 1, 3, 5, 7 |= 0xFFF; ui_lamp_test = 1 (production)
@ Spec     : analysis/lcd_map.md 5 (the only code that lights the unmapped glass elements)
@ Deviation: IMP-02 (production: ui_lamp_test keeps the display refresh from overwriting the lamp test while the window is open)
@
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A89C
    movs.w r0, #4294967295                   @ 0801A89C
    ldr r1, =lcd_shadow                      @ 0801A8A0 &LCD shadow
    str r0, [r1, #0]                         @ 0801A8A4 shadow word 0
    ldr r0, =lcd_shadow                      @ 0801A8A6 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801A8AA
    movw r1, #4095                           @ 0801A8AC
    orrs r0, r1                              @ 0801A8B0
    ldr r1, =lcd_shadow                      @ 0801A8B2 &LCD shadow
    str r0, [r1, #4]                         @ 0801A8B6
    movs.w r0, #4294967295                   @ 0801A8B8
    ldr r1, =lcd_shadow                      @ 0801A8BC &LCD shadow
    str r0, [r1, #8]                         @ 0801A8C0 shadow word 2
    ldr r0, =lcd_shadow                      @ 0801A8C2 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801A8C6
    movw r1, #4095                           @ 0801A8C8
    orrs r0, r1                              @ 0801A8CC
    ldr r1, =lcd_shadow                      @ 0801A8CE &LCD shadow
    str r0, [r1, #12]                        @ 0801A8D2
    movs.w r0, #4294967295                   @ 0801A8D4
    ldr r1, =lcd_shadow                      @ 0801A8D8 &LCD shadow
    str r0, [r1, #16]                        @ 0801A8DC shadow word 4
    ldr r0, =lcd_shadow                      @ 0801A8DE &LCD shadow
    ldr r0, [r0, #20]                        @ 0801A8E2
    movw r1, #4095                           @ 0801A8E4
    orrs r0, r1                              @ 0801A8E8
    ldr r1, =lcd_shadow                      @ 0801A8EA &LCD shadow
    str r0, [r1, #20]                        @ 0801A8EE
    movs.w r0, #4294967295                   @ 0801A8F0
    ldr r1, =lcd_shadow                      @ 0801A8F4 &LCD shadow
    str r0, [r1, #24]                        @ 0801A8F8 shadow word 6
    ldr r0, =lcd_shadow                      @ 0801A8FA &LCD shadow
    ldr r0, [r0, #28]                        @ 0801A8FE
    movw r1, #4095                           @ 0801A900
    orrs r0, r1                              @ 0801A904
    ldr r1, =lcd_shadow                      @ 0801A906 &LCD shadow
    str r0, [r1, #28]                        @ 0801A90A
    movs r0, #1                              @ 0801A90C
    ldr r1, =v_2000805B                      @ 0801A90E &LCD commit request
    strb r0, [r1, #0]                        @ 0801A912
    ldr r1, =ui_lamp_test
    strb r0, [r1]                            @ production (IMP-02): the refresh must not draw over the lamp test until the power-on
                                             @ window closes (ui_bootwin_gate); the baseline loop does not refresh during the window
    bx lr                                    @ 0801A914
ENDFUNC fn_0801A89C
    .ltorg
    .global lcd_all_segments
    .set lcd_all_segments, fn_0801A89C
