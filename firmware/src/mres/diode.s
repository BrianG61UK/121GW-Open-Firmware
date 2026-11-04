@ =============================================================================
@ diode.s - MRES: DIODE (mode 11) chain and the 3 V / 15 V range key
@
@ Replaces v2.05 FUN_08007E84 0x08007E84 and FUN_080159C8 0x080159C8.
@
@ DIODE: one range, 3 V (full scale 30000, dp 4) or 15 V (15000, dp 3; the HY3131 row is the same, the displayed count is divided by 10).
@ Short-circuit tone: a smoothed reading in -999..999 counts re-arms the buzzer for 500 TIM3 updates; a jump of more than 1000 counts
@ outside that window gives the "refused" chirp (FUN_0800EE6C), at most once per 100 TIM2 ticks (0x200080B4).
@
@ IMP-04 (production, ARS 8.2): the tone decision is made on the calibrated per-sample value, which must be inside the window for two
@ consecutive conversions (K = 2, port RAM mres_diode_k); the mean-based tone call is dropped.  The chirp is unchanged.
@ OF-23: the RANGE key no longer writes the 3 V / 15 V choice to EEPROM 0x12 (it was never restored, Q6).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mres.diode, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08007E84 - DIODE chain per AD1 conversion
@ Replaces : 0x08007E84 FUN_08007E84 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  mres_diode_k, 0x20007CD4, 0x20007D64, 0x20007D68, 0x20007FDF, 0x20008081, 0x2000808A, 0x200080B3,
@            0x200080B4
@            writes mres_diode_k, 0x20007CD4, 0x20007D64, 0x20007D68, 0x2000805D, 0x200080B4
@ Spec     : analysis/hy3131_modes_misc.md 6.3 (DIODE); autorange_and_scheduler.md 8.2
@ Deviation: IMP-04
@ Mean branch: D = fn_08006418(mean), divided by 10 in 15 V (0x200080B3 = 1), smoothed (2, 2); 15 V on units with 0x20007FDF = 1 (PF8 strap):
@ D > 14000 gets +500 (not in calibration mode); window -999..999: 0x20007CD4 = D (tone in baseline); else the chirp rule; 0x2000805D = 1.
@ Per sample: fn_080064D6, divided by 10 in 15 V.
@ -----------------------------------------------------------------------------
FUNC fn_08007E84
    push {r7, lr}                      @ 0x08007E84
    @ ---- mean branch (0x20008081 = 1) ----
    ldr r0, =v_20008081                @ 0x08007E86 pool 0x08007FA4 = 0x20008081
    ldrb r0, [r0, #0]                  @ 0x08007E88
    cmp r0, #0                         @ 0x08007E8A
    beq .L08007F6A                     @ 0x08007E8C
    bl fn_08006418                     @ 0x08007E8E
    @ 15 V (0x200080B3 = 1): the displayed count is the reading divided by 10
    ldr r0, =v_200080B3                @ 0x08007E92 pool 0x080087CC = 0x200080B3
    ldrb r0, [r0, #0]                  @ 0x08007E96
    cmp r0, #0                         @ 0x08007E98
    beq .L08007EAA                     @ 0x08007E9A
    ldr r0, =v_20007D64                @ 0x08007E9C pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007E9E
    movs r1, #10                       @ 0x08007EA0
    sdiv r0, r0, r1                    @ 0x08007EA2
    ldr r1, =v_20007D64                @ 0x08007EA6 pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08007EA8
.L08007EAA:                              @ reached from 0x08007E9A beq
    @ display smoothing (threshold 2, depth 2)
    movs r2, #2                        @ 0x08007EAA
    movs r1, #2                        @ 0x08007EAC
    ldr r0, =v_20007D64                @ 0x08007EAE pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007EB0
    bl fn_0800B754                     @ 0x08007EB2
    ldr r1, =v_20007D64                @ 0x08007EB6 pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08007EB8
    @ 15 V on a unit with the PF8 strap (0x20007FDF = 1), not in calibration mode: readings above 14000 get +500 (v2.05 0x08007EBA..0x08007EF4)
    ldr r0, =v_2000808A                @ 0x08007EBA pool 0x080087C0 = 0x2000808A
    ldrb r0, [r0, #0]                  @ 0x08007EBE
    ldr r1, =v_20007FDF                @ 0x08007EC0 pool 0x080087D0 = 0x20007FDF
    ldrb r1, [r1, #0]                  @ 0x08007EC4
    eors.w r1, r1, #1                  @ 0x08007EC6
    orrs r0, r1                        @ 0x08007ECA
    ldr r1, =v_200080B3                @ 0x08007ECC pool 0x080087CC = 0x200080B3
    ldrb r1, [r1, #0]                  @ 0x08007ED0
    eors.w r1, r1, #1                  @ 0x08007ED2
    orrs r0, r1                        @ 0x08007ED6
    uxtb r0, r0                        @ 0x08007ED8
    cmp r0, #0                         @ 0x08007EDA
    bne .L08007EF6                     @ 0x08007EDC
    ldr r0, =v_20007D64                @ 0x08007EDE pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007EE0
    movw r1, #14001                    @ 0x08007EE2
    cmp r0, r1                         @ 0x08007EE6
    blt .L08007EF6                     @ 0x08007EE8
    ldr r0, =v_20007D64                @ 0x08007EEA pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007EEC
    adds.w r0, r0, #500                @ 0x08007EEE
    ldr r1, =v_20007D64                @ 0x08007EF2 pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08007EF4
.L08007EF6:                              @ reached from 0x08007EDC bne, 0x08007EE8 blt
    @ short-circuit window -999 .. 999: tone (baseline) and the reference 0x20007CD4 = D
    ldr r0, =v_20007D64                @ 0x08007EF6 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007EF8
    cmp.w r0, #1000                    @ 0x08007EFA
    bge .L08007F20                     @ 0x08007EFE
    ldr r0, =v_20007D64                @ 0x08007F00 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007F02
    ldr r1, =0xFFFFFC19                @ 0x08007F04 pool 0x080087D4 = 0xFFFFFC19
    cmp r0, r1                         @ 0x08007F08
    blt .L08007F20                     @ 0x08007F0A
    ldr r0, =v_20007D64                @ 0x08007F14 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007F16
    ldr r1, =v_20007CD4                @ 0x08007F18 pool 0x080087D8 = 0x20007CD4
    str r0, [r1, #0]                   @ 0x08007F1C
    b .L08007F64                       @ 0x08007F1E
.L08007F20:                              @ reached from 0x08007EFE bge, 0x08007F0A blt
    @ ---- outside the window: chirp if D differs from the last short reading 0x20007CD4 by more than 1000 and 0x200080B4 = 0 ----
    ldr r0, =v_20007CD4                @ 0x08007F20 pool 0x080087D8 = 0x20007CD4
    ldr r0, [r0, #0]                   @ 0x08007F24
    adds.w r0, r0, #1000               @ 0x08007F26
    ldr r1, =v_20007D64                @ 0x08007F2A pool 0x08007F94 = 0x20007D64
    ldr r1, [r1, #0]                   @ 0x08007F2C
    cmp r0, r1                         @ 0x08007F2E
    blt .L08007F44                     @ 0x08007F30
    ldr r0, =v_20007D64                @ 0x08007F32 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007F34
    ldr r1, =v_20007CD4                @ 0x08007F36 pool 0x080087D8 = 0x20007CD4
    ldr r1, [r1, #0]                   @ 0x08007F3A
    subs.w r1, r1, #1000               @ 0x08007F3C
    cmp r0, r1                         @ 0x08007F40
    bge .L08007F64                     @ 0x08007F42
.L08007F44:                              @ reached from 0x08007F30 blt
    ldr r0, =v_200080B4                @ 0x08007F44 pool 0x080087DC = 0x200080B4
    ldrb r0, [r0, #0]                  @ 0x08007F48
    cmp r0, #0                         @ 0x08007F4A
    bne .L08007F64                     @ 0x08007F4C
    ldr r0, =v_20007D64                @ 0x08007F4E pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007F50
    ldr r1, =v_20007CD4                @ 0x08007F52 pool 0x080087D8 = 0x20007CD4
    str r0, [r1, #0]                   @ 0x08007F56
    movs r0, #100                      @ 0x08007F58
    ldr r1, =v_200080B4                @ 0x08007F5A pool 0x080087DC = 0x200080B4
    strb r0, [r1, #0]                  @ 0x08007F5E
    bl fn_0800EE6C                     @ 0x08007F60
.L08007F64:                              @ reached from 0x08007F1E b, 0x08007F42 bge, 0x08007F4C bne
    @ 0x2000805D = 1: new value
    movs r0, #1                        @ 0x08007F64
    ldr r1, =v_2000805D                @ 0x08007F66 pool 0x08007F9C = 0x2000805D
    strb r0, [r1, #0]                  @ 0x08007F68
.L08007F6A:                              @ reached from 0x08007E8C beq
    @ ---- per-sample value: 0x20007D68 = divide_by_gain(sample - offset), divided by 10 in 15 V ----
    bl fn_080064D6                     @ 0x08007F6A
    ldr r0, =v_200080B3                @ 0x08007F6E pool 0x080087CC = 0x200080B3
    ldrb r0, [r0, #0]                  @ 0x08007F72
    cmp r0, #0                         @ 0x08007F74
    beq .L08007F8A                     @ 0x08007F76
    ldr r0, =v_20007D68                @ 0x08007F78 pool 0x08008340 = 0x20007D68
    ldr r0, [r0, #0]                   @ 0x08007F7C
    movs r1, #10                       @ 0x08007F7E
    sdiv r0, r0, r1                    @ 0x08007F80
    ldr r1, =v_20007D68                @ 0x08007F84 pool 0x08008340 = 0x20007D68
    str r0, [r1, #0]                   @ 0x08007F88
.L08007F8A:                              @ reached from 0x08007F76 beq
    @ ---- IMP-04: tone decision on confirmed per-sample values.  v = 0x20007D68 (15 V: already divided by 10 above) ----
    ldr r0, =v_20007D68
    ldr r0, [r0]
    ldr r1, =0xFFFFFC19                     @ -999
    cmp r0, r1
    blt .Ldi_out                            @ below the window
    cmp.w r0, #1000
    bge .Ldi_out                            @ above the window
    ldr r1, =mres_diode_k
    ldrb r0, [r1]
    adds r0, #1                             @ one more sample inside the window
    cmp r0, #2
    it hi
    movhi r0, #2                            @ saturate at 2
    strb r0, [r1]
    cmp r0, #2
    blo .Ldi_done                           @ not yet confirmed
    mov.w r0, #500
    bl fn_0800EEA8                          @ K = 2 confirmed: short-circuit tone, 500 TIM3 updates (v2.05 0x08007F0C);
                                            @ OF-63: gated by the buzzer setting (v2.05 pe7_on_with_timeout)
    b .Ldi_done
.Ldi_out:
    movs r0, #0
    ldr r1, =mres_diode_k
    strb r0, [r1]                           @ outside the window: restart the confirmation
.Ldi_done:
    pop {r0, pc}                       @ 0x08007F8A
    .ltorg
ENDFUNC fn_08007E84

@ -----------------------------------------------------------------------------
@ fn_080159C8 - RANGE key in DIODE: toggle 3 V / 15 V
@ Replaces : 0x080159C8 FUN_080159C8 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x2000803D meter_range, 0x200080B3
@            writes 0x20008037, 0x2000803F, 0x20008062, 0x200080B3
@ Spec     : analysis/hy3131_modes_misc.md 6.2, 9; ORIGINAL_FIRMWARE_ISSUES.md OF-23
@ Deviation: OF-23
@ v2.05 saved the new 0x200080B3 to EEPROM byte 0x12 here (FUN_08011384, 0x080159EE); the value was reloaded at boot and then forced
@ back to 0 (0x08024E78), so the write had no effect (OF-23, decision Q6: a remembered 15 V source must not be applied without a key
@ press).  The port does not call FUN_08011384; EEPROM byte 0x12 is left as found.
@ -----------------------------------------------------------------------------
FUNC fn_080159C8
    push {r7, lr}                      @ 0x080159C8
    ldr r0, =v_200080B3                @ 0x080159CA pool 0x08016224 = 0x200080B3
    ldrb r0, [r0, #0]                  @ 0x080159CE
    teq r0, #1                         @ 0x080159D0
    beq .L080159E0                     @ 0x080159D4
    movs r0, #1                        @ 0x080159D6
    ldr r1, =v_200080B3                @ 0x080159D8 pool 0x08016224 = 0x200080B3
    strb r0, [r1, #0]                  @ 0x080159DC
    b .L080159E8                       @ 0x080159DE
.L080159E0:                              @ reached from 0x080159D4 beq
    movs r0, #0                        @ 0x080159E0
    ldr r1, =v_200080B3                @ 0x080159E2 pool 0x08016224 = 0x200080B3
    strb r0, [r1, #0]                  @ 0x080159E6
.L080159E8:                              @ reached from 0x080159DE b
    @ OF-23: no EEPROM write of 0x200080B3 (v2.05 called FUN_08011384(0x200080B3) here)
    ldr r0, =meter_range               @ 0x080159F2 pool 0x080161E0 = 0x2000803D
    ldrb r1, [r0, #0]                  @ 0x080159F6
    ldr r0, =meter_mode                @ 0x080159F8 pool 0x08015E70 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080159FC
    bl decimal_position_for_mode_range @ 0x080159FE
    ldr r1, =v_2000803F                @ 0x08015A02 pool 0x08015D28 = 0x2000803F
    strb r0, [r1, #0]                  @ 0x08015A04
    ldr r0, =meter_mode                @ 0x08015A06 pool 0x08015E70 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08015A0A
    bl fn_0800FD30                     @ 0x08015A0C
    bl load_full_scale                 @ 0x08015A10
    movs r0, #10                       @ 0x08015A14
    ldr r1, =v_20008037                @ 0x08015A16 pool 0x08015A70 = 0x20008037
    strb r0, [r1, #0]                  @ 0x08015A18
    movs r0, #1                        @ 0x08015A1A
    ldr r1, =v_20008062                @ 0x08015A1C pool 0x08015AB8 = 0x20008062
    strb r0, [r1, #0]                  @ 0x08015A1E
    pop {r0, pc}                       @ 0x08015A20
    .ltorg
ENDFUNC fn_080159C8


    .section .bss_port.mres, "aw", %nobits
    .global mres_diode_k
mres_diode_k: .space 1                      @ IMP-04: consecutive per-sample readings inside the short-circuit window (0..2)
