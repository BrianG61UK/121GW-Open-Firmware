@ =============================================================================
@ jack.s - DIAL: current-input jack sense (PE10, PE11)
@
@ Replaces the v2.05 functions sense_pe10_pe11 0x0801417C and FUN_080143E4 (DESIGN.md 6.10).
@ PE10 and PE11 are comparator outputs of the mA and A fuse circuits and stay inputs (DESIGN.md 4.2).  A debounced
@ jack code swaps the mA and A forms of the mVA / VA and A / mA modes and raises the wrong-jack warning
@ (analysis/rotary.md 5).  Nothing here writes the EEPROM or the rotary memory.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "dial.inc"

    .section .text.dial.jack, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sense_pe10_pe11 - read the current-input jack sense lines and swap the mA / A and mVA / VA modes
@ Replaces : 0x0801417C sense_pe10_pe11 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main, once per 10 ms tick (loop step 4)
@ RAM      : writes jack_code 0x200080EA, jack_count 0x2000023B, 0x200080CC, jack_ma_selected 0x20008075,
@            jack_warning 0x20008076, meter_mode, dial_mode_req 0x2000804A; reads GPIOE_IDR 0x40021010 (halfword)
@ Spec     : analysis/rotary.md 5
@ -----------------------------------------------------------------------------
FUNC sense_pe10_pe11

@ r4 = jack code (PE10 low = 1, PE11 low = 2; both low = 3), r5 = "debounced change" event, r6 = "mode swapped"
    push {r4, r5, r6, lr}               @ 0801417C
    movs r4, #0                         @ 0801417E
    movs r5, #0                         @ 08014180
    movs r6, #0                         @ 08014182

@ PE10 (comparator output of the mA fuse circuit): low = bit 0 of the code
    ldr r0, =GPIOE_BASE + GPIO_IDR      @ 08014184
    ldrh r0, [r0]                       @ 08014188
    lsls r0, r0, #0x15                  @ 0801418A
    bmi .Ljs_08014192                   @ 0801418C
    movs r0, #1                         @ 0801418E
    movs r4, r0                         @ 08014190

@ PE11: low = bit 1 of the code
@ reached from 0801418C bmi (negative) after lsls r0, r0, #0x15
.Ljs_08014192:
    ldr r0, =GPIOE_BASE + GPIO_IDR      @ 08014192
    ldrh r0, [r0]                       @ 08014196
    lsls r0, r0, #0x14                  @ 08014198
    bmi .Ljs_0801419E                   @ 0801419A
    adds r4, r4, #2                     @ 0801419C

@ same code as at the last call?  No: remember it, restart the 10-call debounce counter
@ reached from 0801419A bmi (negative) after lsls r0, r0, #0x14
.Ljs_0801419E:
    ldr r0, =jack_code                  @ 0801419E
    ldrb r0, [r0]                       @ 080141A2
    movs r1, r4                         @ 080141A4
    uxtb r1, r1                         @ 080141A6
    cmp r0, r1                          @ 080141A8
    beq .Ljs_jack_same                  @ 080141AA
    ldr r0, =jack_code                  @ 080141AC
    strb r4, [r0]                       @ 080141B0
    movs r0, #0xA                       @ 080141B2
    ldr r1, =jack_count                 @ 080141B4
    strb r0, [r1]                       @ 080141B8
    ldr r0, =jack_changed               @ 080141BA
    strb r4, [r0]                       @ 080141BE
    b .Ljs_swap                         @ 080141C0

@ same code: count one call; at zero the code is accepted: counter back to 10, the mA flag is set only for code 1
@ reached from 080141AA beq (equal / zero) after cmp r0, r1
.Ljs_jack_same:
    ldr r0, =jack_count                 @ 080141C2
    ldrb r0, [r0]                       @ 080141C6
    subs r0, r0, #1                     @ 080141C8
    ldr r1, =jack_count                 @ 080141CA
    strb r0, [r1]                       @ 080141CE
    ldr r0, =jack_count                 @ 080141D0
    ldrb r0, [r0]                       @ 080141D4
    cmp r0, #0                          @ 080141D6
    bne .Ljs_swap                       @ 080141D8
    movs r0, #0xA                       @ 080141DA
    ldr r1, =jack_count                 @ 080141DC
    strb r0, [r1]                       @ 080141E0
    uxtb r4, r4                         @ 080141E2
    cmp r4, #1                          @ 080141E4
    bne .Ljs_080141F2                   @ 080141E6
    movs r0, #1                         @ 080141E8
    ldr r1, =jack_ma_selected           @ 080141EA
    strb r0, [r1]                       @ 080141EE
    b .Ljs_jack_event                   @ 080141F0
@ reached from 080141E6 bne (not equal / non-zero) after cmp r4, #1
.Ljs_080141F2:
    movs r0, #0                         @ 080141F2
    ldr r1, =jack_ma_selected           @ 080141F4
    strb r0, [r1]                       @ 080141F8

@ the accepted code is an event for the warning logic below
@ reached from 080141F0 b (jump)
.Ljs_jack_event:
    movs r0, #1                         @ 080141FA
    movs r5, r0                         @ 080141FC

@ swap the mode pairs: with the mA flag set (PE10 low only) ACA -> ACmA, DCA -> DCmA, VA -> mVA, DCVA -> DCmVA;
@ without it the reverse (the rotary memory is not changed)
@ reached from 080141C0 b (jump)
@              and from 080141D8 bne (not equal / non-zero) after cmp r0, #0
.Ljs_swap:
    ldr r0, =meter_mode                 @ 080141FE
    ldrb r0, [r0]                       @ 08014202

@ ACA (20) with the mA flag -> ACmA (18)
    cmp r0, #0x14                       @ 08014204
    bne .Ljs_swap_dca                   @ 08014206
    ldr r0, =jack_ma_selected           @ 08014208
    ldrb r0, [r0]                       @ 0801420C
    cmp r0, #0                          @ 0801420E
    beq .Ljs_swap_dca                   @ 08014210
    movs r0, #0x12                      @ 08014212
    ldr r1, =meter_mode                 @ 08014214
    strb r0, [r1]                       @ 08014218
    movs r0, #1                         @ 0801421A
    movs r6, r0                         @ 0801421C
    b .Ljs_swap_done                    @ 0801421E

@ DCA (21) with the mA flag -> DCmA (19)
@ reached from 08014206 bne (not equal / non-zero) after cmp r0, #0x14
@              and from 08014210 beq (equal / zero) after cmp r0, #0
.Ljs_swap_dca:
    ldr r0, =meter_mode                 @ 08014220
    ldrb r0, [r0]                       @ 08014224
    cmp r0, #0x15                       @ 08014226 mode 21 DCA
    bne .Ljs_swap_va                    @ 08014228
    ldr r0, =jack_ma_selected           @ 0801422A
    ldrb r0, [r0]                       @ 0801422E
    cmp r0, #0                          @ 08014230
    beq .Ljs_swap_va                    @ 08014232
    movs r0, #0x13                      @ 08014234
    ldr r1, =meter_mode                 @ 08014236
    strb r0, [r1]                       @ 0801423A
    movs r0, #1                         @ 0801423C
    movs r6, r0                         @ 0801423E
    b .Ljs_swap_done                    @ 08014240

@ VA (15) with the mA flag -> mVA (14)
@ reached from 08014228 bne (not equal / non-zero) after cmp r0, #0x15
@              and from 08014232 beq (equal / zero) after cmp r0, #0
.Ljs_swap_va:
    ldr r0, =meter_mode                 @ 08014242
    ldrb r0, [r0]                       @ 08014246
    cmp r0, #0xF                        @ 08014248 mode 15 VA
    bne .Ljs_swap_dcva                  @ 0801424A
    ldr r0, =jack_ma_selected           @ 0801424C
    ldrb r0, [r0]                       @ 08014250
    cmp r0, #0                          @ 08014252
    beq .Ljs_swap_dcva                  @ 08014254
    movs r0, #0xE                       @ 08014256
    ldr r1, =meter_mode                 @ 08014258
    strb r0, [r1]                       @ 0801425C
    movs r0, #1                         @ 0801425E
    movs r6, r0                         @ 08014260
    b .Ljs_swap_done                    @ 08014262

@ DCVA (24) with the mA flag -> DCmVA (23)
@ reached from 0801424A bne (not equal / non-zero) after cmp r0, #0xF
@              and from 08014254 beq (equal / zero) after cmp r0, #0
.Ljs_swap_dcva:
    ldr r0, =meter_mode                 @ 08014264
    ldrb r0, [r0]                       @ 08014268
    cmp r0, #0x18                       @ 0801426A mode 24 DCVA
    bne .Ljs_swap_acma                  @ 0801426C
    ldr r0, =jack_ma_selected           @ 0801426E
    ldrb r0, [r0]                       @ 08014272
    cmp r0, #0                          @ 08014274
    beq .Ljs_swap_acma                  @ 08014276
    movs r0, #0x17                      @ 08014278
    ldr r1, =meter_mode                 @ 0801427A
    strb r0, [r1]                       @ 0801427E
    movs r0, #1                         @ 08014280
    movs r6, r0                         @ 08014282
    b .Ljs_swap_done                    @ 08014284

@ ACmA (18) without the mA flag -> ACA (20)
@ reached from 0801426C bne (not equal / non-zero) after cmp r0, #0x18
@              and from 08014276 beq (equal / zero) after cmp r0, #0
.Ljs_swap_acma:
    ldr r0, =meter_mode                 @ 08014286
    ldrb r0, [r0]                       @ 0801428A
    cmp r0, #0x12                       @ 0801428C mode 18 ACmA
    bne .Ljs_swap_dcma                  @ 0801428E
    ldr r0, =jack_ma_selected           @ 08014290
    ldrb r0, [r0]                       @ 08014294
    cmp r0, #0                          @ 08014296
    bne .Ljs_swap_dcma                  @ 08014298
    movs r0, #0x14                      @ 0801429A
    ldr r1, =meter_mode                 @ 0801429C
    strb r0, [r1]                       @ 080142A0
    movs r0, #1                         @ 080142A2
    movs r6, r0                         @ 080142A4
    b .Ljs_swap_done                    @ 080142A6

@ DCmA (19) without the mA flag -> DCA (21)
@ reached from 0801428E bne (not equal / non-zero) after cmp r0, #0x12
@              and from 08014298 bne (not equal / non-zero) after cmp r0, #0
.Ljs_swap_dcma:
    ldr r0, =meter_mode                 @ 080142A8
    ldrb r0, [r0]                       @ 080142AC
    cmp r0, #0x13                       @ 080142AE mode 19 DCmA
    bne .Ljs_swap_mva                   @ 080142B0
    ldr r0, =jack_ma_selected           @ 080142B2
    ldrb r0, [r0]                       @ 080142B6
    cmp r0, #0                          @ 080142B8
    bne .Ljs_swap_mva                   @ 080142BA
    movs r0, #0x15                      @ 080142BC
    ldr r1, =meter_mode                 @ 080142BE
    strb r0, [r1]                       @ 080142C2
    movs r0, #1                         @ 080142C4
    movs r6, r0                         @ 080142C6
    b .Ljs_swap_done                    @ 080142C8

@ mVA (14) without the mA flag -> VA (15)
@ reached from 080142B0 bne (not equal / non-zero) after cmp r0, #0x13
@              and from 080142BA bne (not equal / non-zero) after cmp r0, #0
.Ljs_swap_mva:
    ldr r0, =meter_mode                 @ 080142CA
    ldrb r0, [r0]                       @ 080142CE
    cmp r0, #0xE                        @ 080142D0 mode 14 mVA
    bne .Ljs_swap_dcmva                 @ 080142D2
    ldr r0, =jack_ma_selected           @ 080142D4
    ldrb r0, [r0]                       @ 080142D8
    cmp r0, #0                          @ 080142DA
    bne .Ljs_swap_dcmva                 @ 080142DC
    movs r0, #0xF                       @ 080142DE
    ldr r1, =meter_mode                 @ 080142E0
    strb r0, [r1]                       @ 080142E4
    movs r0, #1                         @ 080142E6
    movs r6, r0                         @ 080142E8
    b .Ljs_swap_done                    @ 080142EA

@ DCmVA (23) without the mA flag -> DCVA (24)
@ reached from 080142D2 bne (not equal / non-zero) after cmp r0, #0xE
@              and from 080142DC bne (not equal / non-zero) after cmp r0, #0
.Ljs_swap_dcmva:
    ldr r0, =meter_mode                 @ 080142EC
    ldrb r0, [r0]                       @ 080142F0
    cmp r0, #0x17                       @ 080142F2 mode 23 DCmVA
    bne .Ljs_swap_done                  @ 080142F4
    ldr r0, =jack_ma_selected           @ 080142F6
    ldrb r0, [r0]                       @ 080142FA
    cmp r0, #0                          @ 080142FC
    bne .Ljs_swap_done                  @ 080142FE
    movs r0, #0x18                      @ 08014300
    ldr r1, =meter_mode                 @ 08014302
    strb r0, [r1]                       @ 08014306
    movs r0, #1                         @ 08014308
    movs r6, r0                         @ 0801430A

@ a swap happened: request a mode apply and apply it at once (meter_apply_mode_range(1))
@ reached from 0801421E b (jump)
@              and from 08014240 b (jump)
@              and from 08014262 b (jump)
@              ... and 6 more
.Ljs_swap_done:
    uxtb r6, r6                         @ 0801430C
    cmp r6, #0                          @ 0801430E
    beq .Ljs_warning                    @ 08014310
    movs r0, #1                         @ 08014312
    ldr r1, =dial_mode_req              @ 08014314
    strb r0, [r1]                       @ 08014318
    movs r0, #1                         @ 0801431A
    bl meter_apply_mode_range           @ 0801431C

@ on a debounced change set the lead-in-wrong-jack warning: none for codes 0 and 3 and for the mA / A positions,
@ for the uA / uVA positions only when PE11 is low, for every other mode with any lead
@ reached from 08014310 beq (equal / zero) after cmp r6, #0
.Ljs_warning:
    uxtb r5, r5                         @ 08014320
    cmp r5, #0                          @ 08014322
    beq .Ljs_end                        @ 08014324
    uxtb r4, r4                         @ 08014326
    cmp r4, #1                          @ 08014328
    beq .Ljs_warn_code12                @ 0801432A
    uxtb r4, r4                         @ 0801432C
    cmp r4, #2                          @ 0801432E
    bne .Ljs_warn_clear                 @ 08014330
@ reached from 0801432A beq (equal / zero) after cmp r4, #1
.Ljs_warn_code12:
    ldr r0, =meter_mode                 @ 08014332
    ldrb r0, [r0]                       @ 08014336
    cmp r0, #0x12                       @ 08014338 mode 18 ACmA
    beq .Ljs_0801435A                   @ 0801433A
    ldr r0, =meter_mode                 @ 0801433C
    ldrb r0, [r0]                       @ 08014340
    cmp r0, #0x14                       @ 08014342 mode 20 ACA
    beq .Ljs_0801435A                   @ 08014344
    ldr r0, =meter_mode                 @ 08014346
    ldrb r0, [r0]                       @ 0801434A
    cmp r0, #0x13                       @ 0801434C mode 19 DCmA
    beq .Ljs_0801435A                   @ 0801434E
    ldr r0, =meter_mode                 @ 08014350
    ldrb r0, [r0]                       @ 08014354
    cmp r0, #0x15                       @ 08014356 mode 21 DCA
    bne .Ljs_08014364                   @ 08014358
@ reached from 0801433A beq (equal / zero) after cmp r0, #0x12
@              and from 08014344 beq (equal / zero) after cmp r0, #0x14
@              and from 0801434E beq (equal / zero) after cmp r0, #0x13
.Ljs_0801435A:
    movs r0, #0                         @ 0801435A
    ldr r1, =jack_warning               @ 0801435C
    strb r0, [r1]                       @ 08014360
    b .Ljs_end                          @ 08014362
    .ltorg
@ reached from 08014358 bne (not equal / non-zero) after cmp r0, #0x15
.Ljs_08014364:
    ldr r0, =meter_mode                 @ 08014364
    ldrb r0, [r0]                       @ 08014368
    cmp r0, #0xE                        @ 0801436A mode 14 mVA
    beq .Ljs_0801438C                   @ 0801436C
    ldr r0, =meter_mode                 @ 0801436E
    ldrb r0, [r0]                       @ 08014372
    cmp r0, #0xF                        @ 08014374 mode 15 VA
    beq .Ljs_0801438C                   @ 08014376
    ldr r0, =meter_mode                 @ 08014378
    ldrb r0, [r0]                       @ 0801437C
    cmp r0, #0x17                       @ 0801437E mode 23 DCmVA
    beq .Ljs_0801438C                   @ 08014380
    ldr r0, =meter_mode                 @ 08014382
    ldrb r0, [r0]                       @ 08014386
    cmp r0, #0x18                       @ 08014388 mode 24 DCVA
    bne .Ljs_08014396                   @ 0801438A
@ reached from 0801436C beq (equal / zero) after cmp r0, #0xE
@              and from 08014376 beq (equal / zero) after cmp r0, #0xF
@              and from 08014380 beq (equal / zero) after cmp r0, #0x17
.Ljs_0801438C:
    movs r0, #0                         @ 0801438C
    ldr r1, =jack_warning               @ 0801438E
    strb r0, [r1]                       @ 08014392
    b .Ljs_end                          @ 08014394
@ reached from 0801438A bne (not equal / non-zero) after cmp r0, #0x18
.Ljs_08014396:
    ldr r0, =meter_mode                 @ 08014396
    ldrb r0, [r0]                       @ 0801439A
    cmp r0, #0x10                       @ 0801439C mode 16 ACuA
    beq .Ljs_080143BE                   @ 0801439E
    ldr r0, =meter_mode                 @ 080143A0
    ldrb r0, [r0]                       @ 080143A4
    cmp r0, #0x11                       @ 080143A6 mode 17 DCuA
    beq .Ljs_080143BE                   @ 080143A8
    ldr r0, =meter_mode                 @ 080143AA
    ldrb r0, [r0]                       @ 080143AE
    cmp r0, #0xD                        @ 080143B0 mode 13 uVA
    beq .Ljs_080143BE                   @ 080143B2
    ldr r0, =meter_mode                 @ 080143B4
    ldrb r0, [r0]                       @ 080143B8
    cmp r0, #0x16                       @ 080143BA mode 22 DCuVA
    bne .Ljs_080143D4                   @ 080143BC
@ reached from 0801439E beq (equal / zero) after cmp r0, #0x10
@              and from 080143A8 beq (equal / zero) after cmp r0, #0x11
@              and from 080143B2 beq (equal / zero) after cmp r0, #0xD
.Ljs_080143BE:
    uxtb r4, r4                         @ 080143BE
    cmp r4, #2                          @ 080143C0
    bne .Ljs_080143CA                   @ 080143C2
    bl fn_080143E4                      @ 080143C4
    b .Ljs_end                          @ 080143C8
@ reached from 080143C2 bne (not equal / non-zero) after cmp r4, #2
.Ljs_080143CA:
    movs r0, #0                         @ 080143CA
    ldr r1, =jack_warning               @ 080143CC
    strb r0, [r1]                       @ 080143D0
    b .Ljs_end                          @ 080143D2
@ reached from 080143BC bne (not equal / non-zero) after cmp r0, #0x16
.Ljs_080143D4:
    bl fn_080143E4                      @ 080143D4
    b .Ljs_end                          @ 080143D8
@ reached from 08014330 bne (not equal / non-zero) after cmp r4, #2
.Ljs_warn_clear:
    movs r0, #0                         @ 080143DA
    ldr r1, =jack_warning               @ 080143DC
    strb r0, [r1]                       @ 080143E0
@ reached from 08014324 beq (equal / zero) after cmp r5, #0
@              and from 08014362 b (jump)
@              and from 08014394 b (jump)
@              ... and 3 more
.Ljs_end:
    pop {r4, r5, r6, pc}                @ 080143E2
ENDFUNC sense_pe10_pe11
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080143E4 - set the wrong-jack warning
@ Replaces : 0x080143E4 FUN_080143E4 (v2.05)
@ In       : -
@ Out      : jack_warning (0x20008076) = 1
@ Clobbers : r0, r1
@ Context  : main (sense_pe10_pe11)
@ Spec     : analysis/rotary.md 5 (warning flag)
@ -----------------------------------------------------------------------------
FUNC fn_080143E4
    movs r0, #1                         @ 080143E4
    ldr r1, =jack_warning               @ 080143E6
    strb r0, [r1]                       @ 080143EA
    bx lr                               @ 080143EC
ENDFUNC fn_080143E4
    .ltorg
