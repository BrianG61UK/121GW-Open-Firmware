@ =============================================================================
@ dial.s - DIAL: the rotary mode switch (contacts PG0..PG7)
@
@ Replaces the v2.05 functions sample_pg0_7 0x08014A14, debounce_pg0_7_onehot 0x0801496E, FUN_08014948,
@ FUN_08014954 and the position handler FUN_080143EE (DESIGN.md 6.10, Appendix A DIAL).  The jack sense
@ sense_pe10_pe11 is in jack.s.
@
@ How a dial move travels (analysis/rotary.md 1 and 2): every 10 ms the main loop calls fn_08014948, which samples
@ the eight contacts (active low), accepts a code after five equal samples when exactly one contact is low,
@ latches it (lockout 15 calls) and flags the change; fn_08014954 then runs the position handler, which loads the
@ mode remembered for that position (rotary memory in the EEPROM, read by the SET routines fn_08010FF0..fn_080110E4)
@ and requests the mode apply.  The dial never writes the EEPROM.
@ Position codes (bit k = contact PG(7-k)): 0x01 LowZ, 0x02 V, 0x04 mV / TEMP, 0x08 Hz, 0x10 ohm / beep / diode / cap,
@ 0x20 mVA / VA, 0x40 uA / uVA, 0x80 A / mA.  The drawing of the schematic lists the contacts in the mirrored order;
@ the firmware is the truth (rotary.md 6).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "dial.inc"

    .section .text.dial.dial, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sample_pg0_7 - read the eight dial contacts PG0..PG7 into one byte
@ Replaces : 0x08014A14 sample_pg0_7 (v2.05)
@ In       : -
@ Out      : dial_sample (0x20008066): bit k set = contact PG(7-k) low (contacts are active low)
@ Clobbers : r0, r1, flags
@ Context  : main (debounce_pg0_7_onehot, every 10 ms)
@ RAM      : writes 0x20008066 (dial_sample); reads GPIOG_IDR 0x40021C10 (halfword)
@ Spec     : analysis/rotary.md 1 (bit k = PG(7-k)): the dial position codes are 0x01 = PG7 (LowZ) ... 0x80 = PG0 (A/mA)
@ -----------------------------------------------------------------------------
FUNC sample_pg0_7

@ dial_sample = 0, then test PG7 first (shift 0x18) down to PG0 (shift 0x1F): pin low (N clear) sets its bit
    movs r0, #0                         @ 08014A14
    ldr r1, =dial_sample                @ 08014A16
    strb r0, [r1]                       @ 08014A1A

@ PG7 = bit 0 (LowZ position)
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08014A1C
    ldrh r0, [r0]                       @ 08014A20
    lsls r0, r0, #0x18                  @ 08014A22
    bmi .L8014a14_08014A2E              @ 08014A24
    movs r0, #1                         @ 08014A26
    ldr r1, =dial_sample                @ 08014A28
    strb r0, [r1]                       @ 08014A2C

@ PG6 = bit 1 (V position)
@ reached from 08014A24 bmi (negative) after lsls r0, r0, #0x18
.L8014a14_08014A2E:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08014A2E
    ldrh r0, [r0]                       @ 08014A32
    lsls r0, r0, #0x19                  @ 08014A34
    bmi .L8014a14_08014A48              @ 08014A36
    ldr r0, =dial_sample                @ 08014A38
    ldrb r0, [r0]                       @ 08014A3C
    orrs r0, r0, #2                     @ 08014A3E
    ldr r1, =dial_sample                @ 08014A42
    strb r0, [r1]                       @ 08014A46

@ PG5 = bit 2 (mV / TEMP position)
@ reached from 08014A36 bmi (negative) after lsls r0, r0, #0x19
.L8014a14_08014A48:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08014A48
    ldrh r0, [r0]                       @ 08014A4C
    lsls r0, r0, #0x1A                  @ 08014A4E
    bmi .L8014a14_08014A62              @ 08014A50
    ldr r0, =dial_sample                @ 08014A52
    ldrb r0, [r0]                       @ 08014A56
    orrs r0, r0, #4                     @ 08014A58
    ldr r1, =dial_sample                @ 08014A5C
    strb r0, [r1]                       @ 08014A60

@ PG4 = bit 3 (Hz position)
@ reached from 08014A50 bmi (negative) after lsls r0, r0, #0x1A
.L8014a14_08014A62:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08014A62
    ldrh r0, [r0]                       @ 08014A66
    lsls r0, r0, #0x1B                  @ 08014A68
    bmi .L8014a14_08014A7C              @ 08014A6A
    ldr r0, =dial_sample                @ 08014A6C
    ldrb r0, [r0]                       @ 08014A70
    orrs r0, r0, #8                     @ 08014A72
    ldr r1, =dial_sample                @ 08014A76
    strb r0, [r1]                       @ 08014A7A

@ PG3 = bit 4 (ohm / beep / diode / cap position)
@ reached from 08014A6A bmi (negative) after lsls r0, r0, #0x1B
.L8014a14_08014A7C:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08014A7C
    ldrh r0, [r0]                       @ 08014A80
    lsls r0, r0, #0x1C                  @ 08014A82
    bmi .L8014a14_08014A96              @ 08014A84
    ldr r0, =dial_sample                @ 08014A86
    ldrb r0, [r0]                       @ 08014A8A
    orrs r0, r0, #0x10                  @ 08014A8C
    ldr r1, =dial_sample                @ 08014A90
    strb r0, [r1]                       @ 08014A94

@ PG2 = bit 5 (mVA / VA position)
@ reached from 08014A84 bmi (negative) after lsls r0, r0, #0x1C
.L8014a14_08014A96:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08014A96
    ldrh r0, [r0]                       @ 08014A9A
    lsls r0, r0, #0x1D                  @ 08014A9C
    bmi .L8014a14_08014AB0              @ 08014A9E
    ldr r0, =dial_sample                @ 08014AA0
    ldrb r0, [r0]                       @ 08014AA4
    orrs r0, r0, #0x20                  @ 08014AA6
    ldr r1, =dial_sample                @ 08014AAA
    strb r0, [r1]                       @ 08014AAE

@ PG1 = bit 6 (uA / uVA position)
@ reached from 08014A9E bmi (negative) after lsls r0, r0, #0x1D
.L8014a14_08014AB0:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08014AB0
    ldrh r0, [r0]                       @ 08014AB4
    lsls r0, r0, #0x1E                  @ 08014AB6
    bmi .L8014a14_08014ACA              @ 08014AB8
    ldr r0, =dial_sample                @ 08014ABA
    ldrb r0, [r0]                       @ 08014ABE
    orrs r0, r0, #0x40                  @ 08014AC0
    ldr r1, =dial_sample                @ 08014AC4
    strb r0, [r1]                       @ 08014AC8

@ PG0 = bit 7 (A / mA position)
@ reached from 08014AB8 bmi (negative) after lsls r0, r0, #0x1E
.L8014a14_08014ACA:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08014ACA
    ldrh r0, [r0]                       @ 08014ACE
    lsls r0, r0, #0x1F                  @ 08014AD0
    bmi .L8014a14_08014AE4              @ 08014AD2
    ldr r0, =dial_sample                @ 08014AD4
    ldrb r0, [r0]                       @ 08014AD8
    orrs r0, r0, #0x80                  @ 08014ADA
    ldr r1, =dial_sample                @ 08014ADE
    strb r0, [r1]                       @ 08014AE2
@ reached from 08014AD2 bmi (negative) after lsls r0, r0, #0x1F
.L8014a14_08014AE4:
    bx lr                               @ 08014AE4
ENDFUNC sample_pg0_7
    .ltorg

@ -----------------------------------------------------------------------------
@ debounce_pg0_7_onehot - sample the dial and latch a new position after five equal one-hot samples
@ Replaces : 0x0801496E debounce_pg0_7_onehot (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved: replaces the unused r7 of v2.05)
@ Context  : main, once per 10 ms tick (fn_08014948, loop step 4)
@ RAM      : writes dial_sample, dial_prev (0x2000023C), dial_stable (0x200080EC), dial_lockout (0x200080EB),
@            dial_latched (0x20008065), dial_changed (0x20008064)
@ Spec     : analysis/rotary.md 1 (Debounce, One-hot check, Latch)
@ -----------------------------------------------------------------------------
FUNC debounce_pg0_7_onehot

@ lockout: dial_lockout (reload 15 at every latch) counts down one per call
    push {r4, lr}                       @ 0801496E
    ldr r0, =dial_lockout               @ 08014970
    ldrb r0, [r0]                       @ 08014974
    cmp r0, #0                          @ 08014976
    beq .Ldb_08014988                   @ 08014978
    ldr r0, =dial_lockout               @ 0801497A
    ldrb r0, [r0]                       @ 0801497E
    subs r0, r0, #1                     @ 08014980
    ldr r1, =dial_lockout               @ 08014982
    strb r0, [r1]                       @ 08014986

@ sample the contacts.  A changed sample restarts the equal count
@ reached from 08014978 beq (equal / zero) after cmp r0, #0
.Ldb_08014988:
    bl sample_pg0_7                     @ 08014988
    ldr r0, =dial_sample                @ 0801498C
    ldrb r0, [r0]                       @ 08014990
    ldr r1, =dial_prev                  @ 08014992
    ldrb r1, [r1]                       @ 08014996
    cmp r0, r1                          @ 08014998
    beq .Ldb_same                       @ 0801499A
    ldr r0, =dial_sample                @ 0801499C
    ldrb r0, [r0]                       @ 080149A0
    ldr r1, =dial_prev                  @ 080149A2
    strb r0, [r1]                       @ 080149A6
    movs r0, #0                         @ 080149A8
    ldr r1, =dial_stable                @ 080149AA
    strb r0, [r1]                       @ 080149AE
    b .Ldb_done                         @ 080149B0

@ same sample: count it; evaluate only on the fifth equal sample, then start counting again
@ reached from 0801499A beq (equal / zero) after cmp r0, r1
.Ldb_same:
    ldr r0, =dial_stable                @ 080149B2
    ldrb r0, [r0]                       @ 080149B6
    adds r0, r0, #1                     @ 080149B8
    ldr r1, =dial_stable                @ 080149BA
    strb r0, [r1]                       @ 080149BE
    ldr r0, =dial_stable                @ 080149C0
    ldrb r0, [r0]                       @ 080149C4
    cmp r0, #5                          @ 080149C6
    blt .Ldb_done                       @ 080149C8
    movs r0, #0                         @ 080149CA
    ldr r1, =dial_stable                @ 080149CC
    strb r0, [r1]                       @ 080149D0

@ the position code must be exactly one contact low (fn_08016B7C), differ from the latched one and the lockout
@ must have run out; then latch it, reload the lockout with 15 and flag the change for fn_08014954
    ldr r0, =dial_sample                @ 080149D2
    ldrb r0, [r0]                       @ 080149D6
    bl fn_08016B7C                      @ 080149D8
    cmp r0, #0                          @ 080149DC
    beq .Ldb_done                       @ 080149DE
    ldr r0, =dial_latched               @ 080149E0
    ldrb r0, [r0]                       @ 080149E2
    ldr r1, =dial_sample                @ 080149E4
    ldrb r1, [r1]                       @ 080149E8
    cmp r0, r1                          @ 080149EA
    beq .Ldb_done                       @ 080149EC
    ldr r0, =dial_lockout               @ 080149EE
    ldrb r0, [r0]                       @ 080149F2
    cmp r0, #0                          @ 080149F4
    bne .Ldb_done                       @ 080149F6
    ldr r0, =dial_sample                @ 080149F8
    ldrb r0, [r0]                       @ 080149FC
    ldr r1, =dial_latched               @ 080149FE
    strb r0, [r1]                       @ 08014A00
    movs r0, #0xF                       @ 08014A02
    ldr r1, =dial_lockout               @ 08014A04
    strb r0, [r1]                       @ 08014A08
    movs r0, #1                         @ 08014A0A
    ldr r1, =dial_changed               @ 08014A0C
    strb r0, [r1]                       @ 08014A10
    bl pwr_bl_wake                      @ IMP-07: a backlight switched off by the timer comes on again (the dial acts normally)
    bl pwr_bl_restart                   @ IMP-07: a new dial position restarts the backlight auto-off countdown
@ reached from 080149B0 b (jump)
@              and from 080149C8 blt (signed <) after cmp r0, #5
@              and from 080149DE beq (equal / zero) after cmp r0, #0
@              ... and 2 more
.Ldb_done:
    pop {r4, pc}                        @ 08014A12
ENDFUNC debounce_pg0_7_onehot
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08014948 - dial service of one 10 ms tick
@ Replaces : 0x08014948 FUN_08014948 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved: replaces the unused r7 of v2.05)
@ Context  : main (loop step 4)
@ Spec     : analysis/rotary.md 1 (Dispatch)
@ -----------------------------------------------------------------------------
FUNC fn_08014948

@ sample and debounce, then act on a newly latched position
    push {r4, lr}                       @ 08014948
    bl debounce_pg0_7_onehot            @ 0801494A
    bl fn_08014954                      @ 0801494E
    pop {r4, pc}                        @ 08014952
ENDFUNC fn_08014948
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08014954 - act on a newly latched dial position
@ Replaces : 0x08014954 FUN_08014954 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved: replaces the unused r7 of v2.05)
@ Context  : main (fn_08014948)
@ RAM      : clears dial_changed 0x20008064
@ Spec     : analysis/rotary.md 1 (Dispatch)
@ -----------------------------------------------------------------------------
FUNC fn_08014954

@ dial_changed set: clear it and run the position handler
    push {r4, lr}                       @ 08014954
    ldr r0, =dial_changed               @ 08014956
    ldrb r0, [r0]                       @ 0801495A
    cmp r0, #0                          @ 0801495C
    beq .L8014954_0801496C              @ 0801495E
    movs r0, #0                         @ 08014960
    ldr r1, =dial_changed               @ 08014962
    strb r0, [r1]                       @ 08014966
    bl fn_080143EE                      @ 08014968
@ reached from 0801495E beq (equal / zero) after cmp r0, #0
.L8014954_0801496C:
    pop {r4, pc}                        @ 0801496C
ENDFUNC fn_08014954
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080143EE - load the mode that belongs to the dial position
@ Replaces : 0x080143EE FUN_080143EE (v2.05)
@ In       : dial_latched (0x20008065): 0x01 LowZ, 0x02 V, 0x04 mV/TEMP, 0x08 Hz, 0x10 ohm group, 0x20 mVA/VA,
@            0x40 uA/uVA, 0x80 A/mA
@ Out      : meter_mode set, state of the previous mode cleared, mode apply requested (0x2000804A)
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main (fn_08014954)
@ RAM      : writes meter_mode, 0x2000801B, 0x2000801D, filter_1khz, hold_active, hold_stage2, 0x20008051,
@            0x20008052, 0x20008053, halfword 0x20007FB2, dial_mode_req 0x2000804A
@ Spec     : analysis/rotary.md 2 (position table and common work after a valid position change)
@            The remembered mode of a position comes from the rotary memory (EEPROM 0x08..0x0E) through the
@            reader routines of SET (fn_08010FF0 .. fn_080110E4)
@ -----------------------------------------------------------------------------
FUNC fn_080143EE

@ r4 = 0: no valid position yet.  Compare ladder on the latched code
    push {r4, lr}                       @ 080143EE
    movs r4, #0                         @ 080143F0
    ldr r0, =dial_latched               @ 080143F2
    ldrb r0, [r0]                       @ 080143F6
    cmp r0, #1                          @ 080143F8
    beq .L80143ee_lowz                  @ 080143FA
    cmp r0, #2                          @ 080143FC
    beq .L80143ee_pos_v                 @ 080143FE
    cmp r0, #4                          @ 08014400
    beq .L80143ee_pos_mv                @ 08014402
    cmp r0, #8                          @ 08014404
    beq .L80143ee_pos_hz                @ 08014406
    cmp r0, #0x10                       @ 08014408
    beq .L80143ee_pos_ohm               @ 0801440A
    cmp r0, #0x20                       @ 0801440C
    beq .L80143ee_pos_va                @ 0801440E
    cmp r0, #0x40                       @ 08014410
    beq .L80143ee_pos_ua                @ 08014412
    cmp r0, #0x80                       @ 08014414
    beq .L80143ee_pos_a                 @ 08014416
    b .L80143ee_common                  @ 08014418

@ 0x01 LowZ: mode 0, fixed (no rotary memory)
@ reached from 080143FA beq (equal / zero) after cmp r0, #1
.L80143ee_lowz:
    movs r0, #0                         @ 0801441A
    ldr r1, =meter_mode                 @ 0801441C
    strb r0, [r1]                       @ 08014420
    movs r0, #1                         @ 08014422
    movs r4, r0                         @ 08014424
    b .L80143ee_common                  @ 08014426

@ 0x02 V: mode from EEPROM 0x08 (DCV, ACV or ACV + AC+DC)
@ reached from 080143FE beq (equal / zero) after cmp r0, #2
.L80143ee_pos_v:
    bl fn_08010FF0                      @ 08014428
    ldr r1, =meter_mode                 @ 0801442C
    strb r0, [r1]                       @ 08014430
    movs r0, #1                         @ 08014432
    movs r4, r0                         @ 08014434
    b .L80143ee_common                  @ 08014436

@ 0x04 mV / TEMP: EEPROM 0x09
@ reached from 08014402 beq (equal / zero) after cmp r0, #4
.L80143ee_pos_mv:
    bl fn_08011020                      @ 08014438
    ldr r1, =meter_mode                 @ 0801443C
    strb r0, [r1]                       @ 08014440
    movs r0, #1                         @ 08014442
    movs r4, r0                         @ 08014444
    b .L80143ee_common                  @ 08014446

@ 0x08 Hz: EEPROM 0x0A
@ reached from 08014406 beq (equal / zero) after cmp r0, #8
.L80143ee_pos_hz:
    bl fn_08011046                      @ 08014448
    ldr r1, =meter_mode                 @ 0801444C
    strb r0, [r1]                       @ 08014450
    movs r0, #1                         @ 08014452
    movs r4, r0                         @ 08014454
    b .L80143ee_common                  @ 08014456

@ 0x10 ohm / beep / diode / cap: EEPROM 0x0B
@ reached from 0801440A beq (equal / zero) after cmp r0, #0x10
.L80143ee_pos_ohm:
    bl fn_0801106C                      @ 08014458
    ldr r1, =meter_mode                 @ 0801445C
    strb r0, [r1]                       @ 08014460
    movs r0, #1                         @ 08014462
    movs r4, r0                         @ 08014464
    b .L80143ee_common                  @ 08014466

@ 0x20 mVA / VA: EEPROM 0x0C
@ reached from 0801440E beq (equal / zero) after cmp r0, #0x20
.L80143ee_pos_va:
    bl fn_08011098                      @ 08014468
    ldr r1, =meter_mode                 @ 0801446C
    strb r0, [r1]                       @ 08014470
    movs r0, #1                         @ 08014472
    movs r4, r0                         @ 08014474
    b .L80143ee_common                  @ 08014476

@ 0x40 uA / uVA: EEPROM 0x0D
@ reached from 08014412 beq (equal / zero) after cmp r0, #0x40
.L80143ee_pos_ua:
    bl fn_080110B8                      @ 08014478
    ldr r1, =meter_mode                 @ 0801447C
    strb r0, [r1]                       @ 08014480
    movs r0, #1                         @ 08014482
    movs r4, r0                         @ 08014484
    b .L80143ee_common                  @ 08014486

@ 0x80 A / mA: EEPROM 0x0E
@ reached from 08014416 beq (equal / zero) after cmp r0, #0x80
.L80143ee_pos_a:
    bl fn_080110E4                      @ 08014488
    ldr r1, =meter_mode                 @ 0801448C
    strb r0, [r1]                       @ 08014490
    movs r0, #1                         @ 08014492
    movs r4, r0                         @ 08014494

@ a valid position: end the log-record composition (0x2000801B, 0x2000801D), request the mode apply, switch the
@ 1 kHz filter and both HOLD stages off, clear the HOLD and REL helper state
@ reached from 08014418 b (jump)
@              and from 08014426 b (jump)
@              and from 08014436 b (jump)
@              ... and 5 more
.L80143ee_common:
    uxtb r4, r4                         @ 08014496
    cmp r4, #0                          @ 08014498
    beq .L80143ee_080144FE              @ 0801449A
    movs r0, #0                         @ 0801449C
    ldr r1, =dial_log_flag1             @ 0801449E
    strb r0, [r1]                       @ 080144A2
    movs r0, #0                         @ 080144A4
    ldr r1, =dial_log_flag2             @ 080144A6
    strb r0, [r1]                       @ 080144AA
    movs r0, #1                         @ 080144AC
    ldr r1, =dial_mode_req              @ 080144AE
    strb r0, [r1]                       @ 080144B2
    movs r0, #0                         @ 080144B4
    ldr r1, =filter_1khz                @ 080144B6
    strb r0, [r1]                       @ 080144BA
    movs r0, #0                         @ 080144BC
    ldr r1, =hold_active                @ 080144BE
    strb r0, [r1]                       @ 080144C2
    movs r0, #0                         @ 080144C4
    ldr r1, =hold_stage2                @ 080144C6
    strb r0, [r1]                       @ 080144CA
    movs r0, #0                         @ 080144CC
    ldr r1, =dial_post_flag53           @ 080144CE
    strb r0, [r1]                       @ 080144D2
    ldr r1, =dial_post_flag51           @ 080144D4
    strb r0, [r1]                       @ 080144D8
    uxtb r0, r0                         @ 080144DA
    ldr r1, =dial_func_hw               @ 080144DC
    strh r0, [r1]                       @ 080144E0
    ldr r0, =dial_func_hw               @ 080144E2
    ldrh r0, [r0]                       @ 080144E6
    cmp r0, #0                          @ 080144E8
    beq .L80143ee_080144F6              @ 080144EA
    movs r0, #1                         @ 080144EC
    ldr r1, =dial_post_flag52           @ 080144EE
    strb r0, [r1]                       @ 080144F2
    b .L80143ee_080144FE                @ 080144F4
@ reached from 080144EA beq (equal / zero) after cmp r0, #0
.L80143ee_080144F6:
    movs r0, #0                         @ 080144F6
    ldr r1, =dial_post_flag52           @ 080144F8
    strb r0, [r1]                       @ 080144FC
@ reached from 0801449A beq (equal / zero) after cmp r4, #0
@              and from 080144F4 b (jump)
.L80143ee_080144FE:
    pop {r4, pc}                        @ 080144FE
ENDFUNC fn_080143EE
    .ltorg
