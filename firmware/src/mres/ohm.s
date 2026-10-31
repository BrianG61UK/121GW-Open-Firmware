@ =============================================================================
@ ohm.s - MRES: resistance (OHM, mode 9) chain, range 5 / 6 corrections
@
@ Replaces v2.05 FUN_080079C4 0x080079C4 (OHM chain, also the BEEP chain), FUN_08007B70 0x08007B70 (range 5 correction) and
@ FUN_08007D1E 0x08007D1E (range 6 correction).
@
@ Mean branch (0x20008081 = 1): D = fn_08006418(mean); a negative D is clamped to 0 in every range except 0; display smoothing
@ fn_0800B754(D, thr, depth) with (thr, depth) per range 0..6 = (100,10) (20,10) (10,10) (20,10) (20,10) (10,5) (100,20); in OHM
@ (mode 9) with 0x20007FE0 = 0 and not in calibration mode, range 5 subtracts c5(D) and range 6 subtracts c6(D, w); 0x2000805D = 1.
@ Per sample: fn_080064D6, then a negative per-sample value is clamped to 0 (0x20007D68).
@
@ IMP-01 (production): in mode 9 mdc_sample_precheck (MDC, called from ad1_ready_dispatch) hands the clamped per-sample value to ar_sample before the
@ conversion is accumulated; BEEP (mode 10) has one range and is not ranged.
@ IMP-03: the block size per range is set in ad1_accumulate_average (MDC).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mres.ohm, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_080079C4 - OHM / BEEP chain per AD1 conversion
@ Replaces : 0x080079C4 FUN_080079C4 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r6 preserved)
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x2000803D meter_range, 0x20007D64, 0x20007D68, 0x20007E14, 0x20007FE0,
@            0x20008081, 0x2000808A
@            writes 0x20007D64, 0x20007D68, 0x2000805D
@ Spec     : analysis/hy3131_modes_misc.md 6.3 (OHM r5/r6)
@ Deviation: none
@ Correction weight 0x20007E14 (EEPROM 0x178) is the w of c6.  The corrections are skipped in calibration mode (0x2000808A) and when 0x20007FE0
@ is non-zero (set at start-up when EEPROM byte 0x26 is not 0xA5, i.e. no OHM range 6 calibration, and by such a calibration; hy3131_modes_misc.md DEF-13).
@ -----------------------------------------------------------------------------
FUNC fn_080079C4
    push {r4, r5, r6, lr}              @ 0x080079C4  
    @ ---- mean branch: only for the conversion that completed a mean (0x20008081 = 1) ----
    ldr r0, =v_20008081                @ 0x080079C6 pool 0x08007FA4 = 0x20008081
    ldrb r0, [r0, #0]                  @ 0x080079CA
    cmp r0, #0                         @ 0x080079CC  0x20008081: a mean was completed
    beq .L08007B14                     @ 0x080079CE
    @ D = fn_08006418(mean): offset subtracted, divided by the gain (0x20007D64)
    bl fn_08006418                     @ 0x080079D2
    @ a negative D becomes 0 in every range except 0 (BEEP uses range 0 and keeps negative values)
    ldr r0, =v_20007D64                @ 0x080079D6 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x080079DA
    cmp r0, #0                         @ 0x080079DC
    bpl .L080079F2                     @ 0x080079DE
    ldr r0, =meter_range               @ 0x080079E0 pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x080079E4
    cmp r0, #0                         @ 0x080079E6
    beq .L080079F2                     @ 0x080079E8
    movs r0, #0                        @ 0x080079EA
    ldr r1, =v_20007D64                @ 0x080079EC pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x080079F0
.L080079F2:                              @ reached from 0x080079DE bpl, 0x080079E8 beq
    @ display smoothing parameters by range: r4 = threshold, r5 = depth: 0 (100, 10), 1 (20, 10), 2 (10, 10), 3 (20, 10), 4 (20, 10), 5 (10, 5), 6 (100, 20)
    ldr r0, =meter_range               @ 0x080079F2 pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x080079F6
    cmp r0, #6                         @ 0x080079F8
    bne .L08007A06                     @ 0x080079FA
    movs r0, #100                      @ 0x080079FC
    movs r4, r0                        @ 0x080079FE
    movs r0, #20                       @ 0x08007A00
    movs r5, r0                        @ 0x08007A02
    b .L08007A7C                       @ 0x08007A04
.L08007A06:                              @ reached from 0x080079FA bne
    ldr r0, =meter_range               @ 0x08007A06 pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08007A0A
    cmp r0, #5                         @ 0x08007A0C
    bne .L08007A1A                     @ 0x08007A0E
    movs r0, #10                       @ 0x08007A10
    movs r4, r0                        @ 0x08007A12
    movs r0, #5                        @ 0x08007A14
    movs r5, r0                        @ 0x08007A16
    b .L08007A7C                       @ 0x08007A18
.L08007A1A:                              @ reached from 0x08007A0E bne
    ldr r0, =meter_range               @ 0x08007A1A pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08007A1E
    cmp r0, #0                         @ 0x08007A20
    bne .L08007A2E                     @ 0x08007A22
    movs r0, #100                      @ 0x08007A24
    movs r4, r0                        @ 0x08007A26
    movs r0, #10                       @ 0x08007A28
    movs r5, r0                        @ 0x08007A2A
    b .L08007A7C                       @ 0x08007A2C
.L08007A2E:                              @ reached from 0x08007A22 bne
    ldr r0, =meter_range               @ 0x08007A2E pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08007A32
    cmp r0, #2                         @ 0x08007A34
    blt .L08007A42                     @ 0x08007A36
    ldr r0, =meter_range               @ 0x08007A38 pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08007A3C
    cmp r0, #4                         @ 0x08007A3E
    blt .L08007A4C                     @ 0x08007A40
.L08007A42:                              @ reached from 0x08007A36 blt
    movs r0, #20                       @ 0x08007A42
    movs r4, r0                        @ 0x08007A44
    movs r0, #10                       @ 0x08007A46
    movs r5, r0                        @ 0x08007A48
    b .L08007A7C                       @ 0x08007A4A
.L08007A4C:                              @ reached from 0x08007A40 blt
    ldr r0, =meter_range               @ 0x08007A4C pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08007A50
    cmp r0, #2                         @ 0x08007A52
    bne .L08007A60                     @ 0x08007A54
    movs r0, #10                       @ 0x08007A56
    movs r4, r0                        @ 0x08007A58
    movs r0, #10                       @ 0x08007A5A
    movs r5, r0                        @ 0x08007A5C
    b .L08007A7C                       @ 0x08007A5E
.L08007A60:                              @ reached from 0x08007A54 bne
    ldr r0, =meter_range               @ 0x08007A60 pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08007A64
    cmp r0, #3                         @ 0x08007A66
    bne .L08007A74                     @ 0x08007A68
    movs r0, #20                       @ 0x08007A6A
    movs r4, r0                        @ 0x08007A6C
    movs r0, #10                       @ 0x08007A6E
    movs r5, r0                        @ 0x08007A70
    b .L08007A7C                       @ 0x08007A72
.L08007A74:                              @ reached from 0x08007A68 bne
    movs r0, #10                       @ 0x08007A74
    movs r4, r0                        @ 0x08007A76
    movs r0, #5                        @ 0x08007A78
    movs r5, r0                        @ 0x08007A7A
.L08007A7C:                              @ reached from 0x08007A04 b, 0x08007A18 b, 0x08007A2C b, 0x08007A4A b, 0x08007A5E b, 0x08007A72 b
    @ D = fn_0800B754(D, threshold, depth)
    movs r2, r5                        @ 0x08007A7C
    uxth r2, r2                        @ 0x08007A7E
    movs r1, r4                        @ 0x08007A80
    ldr r0, =v_20007D64                @ 0x08007A82 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007A86
    bl fn_0800B754                     @ 0x08007A88
    ldr r1, =v_20007D64                @ 0x08007A8C pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08007A90
    @ corrections only when 0x20007FE0 = 0 and not in calibration mode (0x2000808A = 0): OHM range 5 subtracts c5(D), OHM range 6 subtracts c6(D, w)
    ldr r0, =v_20007FE0                @ 0x08007A92 pool 0x08008464 = 0x20007FE0
    ldrb r0, [r0, #0]                  @ 0x08007A96
    cmp r0, #0                         @ 0x08007A98
    bne .L08007B0C                     @ 0x08007A9A
    ldr r0, =v_2000808A                @ 0x08007A9C pool 0x08007E44 = 0x2000808A
    ldrb r0, [r0, #0]                  @ 0x08007AA0
    cmp r0, #0                         @ 0x08007AA2
    bne .L08007AD2                     @ 0x08007AA4
    ldr r0, =meter_mode                @ 0x08007AA6 pool 0x08008134 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08007AAA
    cmp r0, #9                         @ 0x08007AAC
    bne .L08007AD2                     @ 0x08007AAE
    ldr r0, =meter_range               @ 0x08007AB0 pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08007AB4
    cmp r0, #5                         @ 0x08007AB6
    bne .L08007AD2                     @ 0x08007AB8
    ldr r0, =v_20007D64                @ 0x08007ABA pool 0x08007F94 = 0x20007D64
    ldr r6, [r0, #0]                   @ 0x08007ABE
    ldr r0, =v_20007D64                @ 0x08007AC0 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007AC4
    bl fn_08007B70                     @ 0x08007AC6
    subs r0, r6, r0                    @ 0x08007ACA
    ldr r1, =v_20007D64                @ 0x08007ACC pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08007AD0
.L08007AD2:                              @ reached from 0x08007AA4 bne, 0x08007AAE bne, 0x08007AB8 bne
    @ range 6: D = D - c6(D, w) with w = 0x20007E14 (same gates)
    ldr r0, =v_2000808A                @ 0x08007AD2 pool 0x08007E44 = 0x2000808A
    ldrb r0, [r0, #0]                  @ 0x08007AD6
    cmp r0, #0                         @ 0x08007AD8
    bne .L08007B0C                     @ 0x08007ADA
    ldr r0, =meter_mode                @ 0x08007ADC pool 0x08008134 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08007AE0
    cmp r0, #9                         @ 0x08007AE2
    bne .L08007B0C                     @ 0x08007AE4
    ldr r0, =meter_range               @ 0x08007AE6 pool 0x08007E48 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08007AE8
    cmp r0, #6                         @ 0x08007AEA
    bne .L08007B0C                     @ 0x08007AEC
    ldr r0, =v_20007D64                @ 0x08007AEE pool 0x08007F94 = 0x20007D64
    ldr r6, [r0, #0]                   @ 0x08007AF2
    ldr r0, =v_20007E14                @ 0x08007AF4 pool 0x080084C4 = 0x20007E14
    ldr r1, [r0, #0]                   @ 0x08007AF8
    ldr r0, =v_20007D64                @ 0x08007AFA pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007AFE
    bl fn_08007D1E                     @ 0x08007B00
    subs r0, r6, r0                    @ 0x08007B04
    ldr r1, =v_20007D64                @ 0x08007B06 pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08007B0A
.L08007B0C:                              @ reached from 0x08007A9A bne, 0x08007ADA bne, 0x08007AE4 bne, 0x08007AEC bne
    movs r0, #1                        @ 0x08007B0C
    ldr r1, =v_2000805D                @ 0x08007B0E pool 0x08007F9C = 0x2000805D
    strb r0, [r1, #0]                  @ 0x08007B12
.L08007B14:                              @ reached from 0x080079CE beq
    @ ---- per-sample value, every conversion: 0x20007D68 = divide_by_gain(sample - offset); a negative value is 0 ----
    bl fn_080064D6                     @ 0x08007B14
    ldr r0, =v_20007D68                @ 0x08007B18 pool 0x08008340 = 0x20007D68
    ldr r0, [r0, #0]                   @ 0x08007B1C
    cmp r0, #0                         @ 0x08007B1E
    bpl .L08007B2A                     @ 0x08007B20
    movs r0, #0                        @ 0x08007B22
    ldr r1, =v_20007D68                @ 0x08007B24 pool 0x08008340 = 0x20007D68
    str r0, [r1, #0]                   @ 0x08007B28
.L08007B2A:                              @ reached from 0x08007B20 bpl
    pop {r4, r5, r6, pc}               @ 0x08007B2A
    .ltorg
ENDFUNC fn_080079C4

@ -----------------------------------------------------------------------------
@ fn_08007B70 - OHM range 5 correction c5(v)
@ Replaces : 0x08007B70 FUN_08007B70 (v2.05)
@ In       : r0 = smoothed value v (counts of 100 ohm)
@ Out      : r0 = correction subtracted from v
@ Clobbers : r0-r2, flags
@ Context  : main only
@ RAM      : none directly
@ Spec     : analysis/hy3131_modes_misc.md 6.3 (c5 table)
@ Deviation: none
@ Step function: 0 below 1000 and from 50000; floor(v/1000) for 1000..14999; 15 for 15000..35999; 15 - floor((v - 35000)/1000) for 36000..49999.
@ -----------------------------------------------------------------------------
FUNC fn_08007B70
    movs r1, r0                        @ 0x08007B70
    movs r0, #0                        @ 0x08007B72
    movw r2, #50000                    @ 0x08007B74
    cmp r1, r2                         @ 0x08007B78
    blt .L08007B82                     @ 0x08007B7A
    movs r2, #0                        @ 0x08007B7C
    movs r0, r2                        @ 0x08007B7E
    b .L08007D1C                       @ 0x08007B80
.L08007B82:                              @ reached from 0x08007B7A blt
    cmp.w r1, #1000                    @ 0x08007B82
    bge .L08007B8E                     @ 0x08007B86
    movs r2, #0                        @ 0x08007B88
    movs r0, r2                        @ 0x08007B8A
    b .L08007D1C                       @ 0x08007B8C
.L08007B8E:                              @ reached from 0x08007B86 bge
    cmp.w r1, #2000                    @ 0x08007B8E
    bge .L08007B9A                     @ 0x08007B92
    movs r2, #1                        @ 0x08007B94
    movs r0, r2                        @ 0x08007B96
    b .L08007D1C                       @ 0x08007B98
.L08007B9A:                              @ reached from 0x08007B92 bge
    movw r2, #3000                     @ 0x08007B9A
    cmp r1, r2                         @ 0x08007B9E
    bge .L08007BA8                     @ 0x08007BA0
    movs r2, #2                        @ 0x08007BA2
    movs r0, r2                        @ 0x08007BA4
    b .L08007D1C                       @ 0x08007BA6
.L08007BA8:                              @ reached from 0x08007BA0 bge
    cmp.w r1, #4000                    @ 0x08007BA8
    bge .L08007BB4                     @ 0x08007BAC
    movs r2, #3                        @ 0x08007BAE
    movs r0, r2                        @ 0x08007BB0
    b .L08007D1C                       @ 0x08007BB2
.L08007BB4:                              @ reached from 0x08007BAC bge
    movw r2, #5000                     @ 0x08007BB4
    cmp r1, r2                         @ 0x08007BB8
    bge .L08007BC2                     @ 0x08007BBA
    movs r2, #4                        @ 0x08007BBC
    movs r0, r2                        @ 0x08007BBE
    b .L08007D1C                       @ 0x08007BC0
.L08007BC2:                              @ reached from 0x08007BBA bge
    movw r2, #6000                     @ 0x08007BC2
    cmp r1, r2                         @ 0x08007BC6
    bge .L08007BD0                     @ 0x08007BC8
    movs r2, #5                        @ 0x08007BCA
    movs r0, r2                        @ 0x08007BCC
    b .L08007D1C                       @ 0x08007BCE
.L08007BD0:                              @ reached from 0x08007BC8 bge
    movw r2, #7000                     @ 0x08007BD0
    cmp r1, r2                         @ 0x08007BD4
    bge .L08007BDE                     @ 0x08007BD6
    movs r2, #6                        @ 0x08007BD8
    movs r0, r2                        @ 0x08007BDA
    b .L08007D1C                       @ 0x08007BDC
.L08007BDE:                              @ reached from 0x08007BD6 bge
    cmp.w r1, #8000                    @ 0x08007BDE
    bge .L08007BEA                     @ 0x08007BE2
    movs r2, #7                        @ 0x08007BE4
    movs r0, r2                        @ 0x08007BE6
    b .L08007D1C                       @ 0x08007BE8
.L08007BEA:                              @ reached from 0x08007BE2 bge
    movw r2, #9000                     @ 0x08007BEA
    cmp r1, r2                         @ 0x08007BEE
    bge .L08007BF8                     @ 0x08007BF0
    movs r2, #8                        @ 0x08007BF2
    movs r0, r2                        @ 0x08007BF4
    b .L08007D1C                       @ 0x08007BF6
.L08007BF8:                              @ reached from 0x08007BF0 bge
    movw r2, #10000                    @ 0x08007BF8
    cmp r1, r2                         @ 0x08007BFC
    bge .L08007C06                     @ 0x08007BFE
    movs r2, #9                        @ 0x08007C00
    movs r0, r2                        @ 0x08007C02
    b .L08007D1C                       @ 0x08007C04
.L08007C06:                              @ reached from 0x08007BFE bge
    movw r2, #11000                    @ 0x08007C06
    cmp r1, r2                         @ 0x08007C0A
    bge .L08007C14                     @ 0x08007C0C
    movs r2, #10                       @ 0x08007C0E
    movs r0, r2                        @ 0x08007C10
    b .L08007D1C                       @ 0x08007C12
.L08007C14:                              @ reached from 0x08007C0C bge
    movw r2, #12000                    @ 0x08007C14
    cmp r1, r2                         @ 0x08007C18
    bge .L08007C22                     @ 0x08007C1A
    movs r2, #11                       @ 0x08007C1C
    movs r0, r2                        @ 0x08007C1E
    b .L08007D1C                       @ 0x08007C20
.L08007C22:                              @ reached from 0x08007C1A bge
    movw r2, #13000                    @ 0x08007C22
    cmp r1, r2                         @ 0x08007C26
    bge .L08007C30                     @ 0x08007C28
    movs r2, #12                       @ 0x08007C2A
    movs r0, r2                        @ 0x08007C2C
    b .L08007D1C                       @ 0x08007C2E
.L08007C30:                              @ reached from 0x08007C28 bge
    movw r2, #14000                    @ 0x08007C30
    cmp r1, r2                         @ 0x08007C34
    bge .L08007C3E                     @ 0x08007C36
    movs r2, #13                       @ 0x08007C38
    movs r0, r2                        @ 0x08007C3A
    b .L08007D1C                       @ 0x08007C3C
.L08007C3E:                              @ reached from 0x08007C36 bge
    movw r2, #15000                    @ 0x08007C3E
    cmp r1, r2                         @ 0x08007C42
    bge .L08007C4C                     @ 0x08007C44
    movs r2, #14                       @ 0x08007C46
    movs r0, r2                        @ 0x08007C48
    b .L08007D1C                       @ 0x08007C4A
.L08007C4C:                              @ reached from 0x08007C44 bge
    movw r2, #36000                    @ 0x08007C4C
    cmp r1, r2                         @ 0x08007C50
    bge .L08007C5A                     @ 0x08007C52
    movs r2, #15                       @ 0x08007C54
    movs r0, r2                        @ 0x08007C56
    b .L08007D1C                       @ 0x08007C58
.L08007C5A:                              @ reached from 0x08007C52 bge
    movw r2, #37000                    @ 0x08007C5A
    cmp r1, r2                         @ 0x08007C5E
    bge .L08007C68                     @ 0x08007C60
    movs r2, #14                       @ 0x08007C62
    movs r0, r2                        @ 0x08007C64
    b .L08007D1C                       @ 0x08007C66
.L08007C68:                              @ reached from 0x08007C60 bge
    movw r2, #38000                    @ 0x08007C68
    cmp r1, r2                         @ 0x08007C6C
    bge .L08007C76                     @ 0x08007C6E
    movs r2, #13                       @ 0x08007C70
    movs r0, r2                        @ 0x08007C72
    b .L08007D1C                       @ 0x08007C74
.L08007C76:                              @ reached from 0x08007C6E bge
    movw r2, #39000                    @ 0x08007C76
    cmp r1, r2                         @ 0x08007C7A
    bge .L08007C84                     @ 0x08007C7C
    movs r2, #12                       @ 0x08007C7E
    movs r0, r2                        @ 0x08007C80
    b .L08007D1C                       @ 0x08007C82
.L08007C84:                              @ reached from 0x08007C7C bge
    movw r2, #40000                    @ 0x08007C84
    cmp r1, r2                         @ 0x08007C88
    bge .L08007C92                     @ 0x08007C8A
    movs r2, #11                       @ 0x08007C8C
    movs r0, r2                        @ 0x08007C8E
    b .L08007D1C                       @ 0x08007C90
.L08007C92:                              @ reached from 0x08007C8A bge
    movw r2, #41000                    @ 0x08007C92
    cmp r1, r2                         @ 0x08007C96
    bge .L08007CA0                     @ 0x08007C98
    movs r2, #10                       @ 0x08007C9A
    movs r0, r2                        @ 0x08007C9C
    b .L08007D1C                       @ 0x08007C9E
.L08007CA0:                              @ reached from 0x08007C98 bge
    movw r2, #42000                    @ 0x08007CA0
    cmp r1, r2                         @ 0x08007CA4
    bge .L08007CAE                     @ 0x08007CA6
    movs r2, #9                        @ 0x08007CA8
    movs r0, r2                        @ 0x08007CAA
    b .L08007D1C                       @ 0x08007CAC
.L08007CAE:                              @ reached from 0x08007CA6 bge
    movw r2, #43000                    @ 0x08007CAE
    cmp r1, r2                         @ 0x08007CB2
    bge .L08007CBC                     @ 0x08007CB4
    movs r2, #8                        @ 0x08007CB6
    movs r0, r2                        @ 0x08007CB8
    b .L08007D1C                       @ 0x08007CBA
.L08007CBC:                              @ reached from 0x08007CB4 bge
    movw r2, #44000                    @ 0x08007CBC
    cmp r1, r2                         @ 0x08007CC0
    bge .L08007CCA                     @ 0x08007CC2
    movs r2, #7                        @ 0x08007CC4
    movs r0, r2                        @ 0x08007CC6
    b .L08007D1C                       @ 0x08007CC8
.L08007CCA:                              @ reached from 0x08007CC2 bge
    movw r2, #45000                    @ 0x08007CCA
    cmp r1, r2                         @ 0x08007CCE
    bge .L08007CD8                     @ 0x08007CD0
    movs r2, #6                        @ 0x08007CD2
    movs r0, r2                        @ 0x08007CD4
    b .L08007D1C                       @ 0x08007CD6
.L08007CD8:                              @ reached from 0x08007CD0 bge
    movw r2, #46000                    @ 0x08007CD8
    cmp r1, r2                         @ 0x08007CDC
    bge .L08007CE6                     @ 0x08007CDE
    movs r2, #5                        @ 0x08007CE0
    movs r0, r2                        @ 0x08007CE2
    b .L08007D1C                       @ 0x08007CE4
.L08007CE6:                              @ reached from 0x08007CDE bge
    movw r2, #47000                    @ 0x08007CE6
    cmp r1, r2                         @ 0x08007CEA
    bge .L08007CF4                     @ 0x08007CEC
    movs r2, #4                        @ 0x08007CEE
    movs r0, r2                        @ 0x08007CF0
    b .L08007D1C                       @ 0x08007CF2
.L08007CF4:                              @ reached from 0x08007CEC bge
    movw r2, #48000                    @ 0x08007CF4
    cmp r1, r2                         @ 0x08007CF8
    bge .L08007D02                     @ 0x08007CFA
    movs r2, #3                        @ 0x08007CFC
    movs r0, r2                        @ 0x08007CFE
    b .L08007D1C                       @ 0x08007D00
.L08007D02:                              @ reached from 0x08007CFA bge
    movw r2, #49000                    @ 0x08007D02
    cmp r1, r2                         @ 0x08007D06
    bge .L08007D10                     @ 0x08007D08
    movs r2, #2                        @ 0x08007D0A
    movs r0, r2                        @ 0x08007D0C
    b .L08007D1C                       @ 0x08007D0E
.L08007D10:                              @ reached from 0x08007D08 bge
    movw r2, #50000                    @ 0x08007D10
    cmp r1, r2                         @ 0x08007D14
    bge .L08007D1C                     @ 0x08007D16
    movs r2, #1                        @ 0x08007D18
    movs r0, r2                        @ 0x08007D1A
.L08007D1C:                              @ reached from 0x08007B80 b, 0x08007B8C b, 0x08007B98 b, 0x08007BA6 b, 0x08007BB2 b, 0x08007BC0 b, 0x08007BCE b, 0x08007BDC b, 0x08007BE8 b, 0x08007BF6 b, 0x08007C04 b, 0x08007C12 b, 0x08007C20 b, 0x08007C2E b, 0x08007C3C b, 0x08007C4A b, 0x08007C58 b, 0x08007C66 b, 0x08007C74 b, 0x08007C82 b, 0x08007C90 b, 0x08007C9E b, 0x08007CAC b, 0x08007CBA b, 0x08007CC8 b, 0x08007CD6 b, 0x08007CE4 b, 0x08007CF2 b, 0x08007D00 b, 0x08007D0E b, 0x08007D16 bge
    bx lr                              @ 0x08007D1C
    .ltorg
ENDFUNC fn_08007B70

@ -----------------------------------------------------------------------------
@ fn_08007D1E - OHM range 6 correction c6(v, w)
@ Replaces : 0x08007D1E FUN_08007D1E (v2.05)
@ In       : r0 = smoothed value v
@            r1 = weight w (0x20007E14)
@ Out      : r0 = correction subtracted from v (also in 0x20007CC0)
@ Clobbers : r0-r3, r12, flags (r4-r8 preserved)
@ Context  : main only
@ RAM      : reads  v205_tab_08028838, 0x20007CC0, 0x20007CC4, 0x20007CC8, 0x20007CCC, 0x20007CD0
@            writes 0x20007CC0, 0x20007CC4, 0x20007CC8, 0x20007CCC, 0x20007CD0
@ Spec     : analysis/hy3131_modes_misc.md 6.3 (c6); ORIGINAL_FIRMWARE_ISSUES.md OF-01
@ Deviation: OF-01
@ 0 for v >= 56000.  Otherwise with i the first index where T[i] * 1000 >= v: frac = (v - 1000 * T[i-1]) / (1000 * (T[i] - T[i-1])),
@ interp = W[i-1] + frac * (W[i] - W[i-1]) (float32), result = (int)(w * interp / 100.0f), truncated toward zero.
@ OF-01: v2.05 used the stale register r7 as index when the search ran out of the table (0x08007D48 -> 0x08007D6A); the port returns
@ 0 (uncorrected) for a failed search and for i = 0 (v <= 0), where v2.05 read T[-1].  c6(0) = 0 in v2.05 as well.
@ -----------------------------------------------------------------------------
FUNC fn_08007D1E
    @ r4 = v, r5 = w; 0x20007CC0 = result (also returned)
    stmdb sp!, {r4, r5, r6, r7, r8, lr} @ 0x08007D1E
    movs r4, r0                        @ 0x08007D22
    movs r5, r1                        @ 0x08007D24
    movs r0, #0                        @ 0x08007D26
    ldr r1, =v_20007CC0                @ 0x08007D28 pool 0x080087BC = 0x20007CC0
    str r0, [r1, #0]                   @ 0x08007D2C
    movw r0, #56000                    @ 0x08007D2E
    cmp r4, r0                         @ 0x08007D32
    blt .L08007D40                     @ 0x08007D34
    movs r0, #0                        @ 0x08007D36
    ldr r1, =v_20007CC0                @ 0x08007D38 pool 0x080087BC = 0x20007CC0
    str r0, [r1, #0]                   @ 0x08007D3C
    b .L08007E38                       @ 0x08007D3E
.L08007D40:                              @ reached from 0x08007D34 blt
    @ ---- search the breakpoint table T[i] = 5 * i (i = 0..12, 0x08028838) for the first T[i] * 1000 >= v ----
    movs r0, #0                        @ 0x08007D40
    movs r6, r0                        @ 0x08007D42
.L08007D44:                              @ reached from 0x08007D64 b
    uxtb r6, r6                        @ 0x08007D44
    cmp r6, #13                        @ 0x08007D46
    bge .Lc6_none                           @ OF-01: the search ran out of table: v2.05 continued with the stale r7 (0x08007D66)
    ldr r0, =v205_tab_08028838         @ 0x08007D4A pool 0x080084C8 = 0x08028838
    uxtb r6, r6                        @ 0x08007D4E
    ldr.w r0, [r0, r6, lsl #2]         @ 0x08007D50
    mov.w r1, #1000                    @ 0x08007D54
    muls r0, r1                        @ 0x08007D58
    cmp r0, r4                         @ 0x08007D5A
    blt .L08007D62                     @ 0x08007D5C
    movs r7, r6                        @ 0x08007D5E
    b .L08007D66                       @ 0x08007D60
.L08007D62:                              @ reached from 0x08007D5C blt
    adds r6, r6, #1                    @ 0x08007D62
    b .L08007D44                       @ 0x08007D64
.L08007D66:                              @ reached from 0x08007D48 bge, 0x08007D60 b
    @ ---- index of the first breakpoint at or above v; OF-01: index 0 has no breakpoint below it (v <= 0: table[-1] would be read, in
    @      v2.05 the neighbouring table's last word) and a failed search leaves r7 undefined: both return no correction ----
    uxtb r0, r7
    cmp r0, #0
    beq .Lc6_none
    ldr r0, =v205_tab_08028838         @ 0x08007D66 pool 0x080084C8 = 0x08028838
    uxtb r7, r7                        @ 0x08007D6A
    add.w r0, r0, r7, lsl #2           @ 0x08007D6C
    ldr.w r0, [r0, #-4]                @ 0x08007D70
    ldr r1, =v_20007CCC                @ 0x08007D74 pool 0x080084CC = 0x20007CCC
    str r0, [r1, #0]                   @ 0x08007D78
    ldr r0, =v205_tab_08028838         @ 0x08007D7A pool 0x080084C8 = 0x08028838
    uxtb r7, r7                        @ 0x08007D7E
    ldr.w r0, [r0, r7, lsl #2]         @ 0x08007D80
    ldr r1, =v_20007CD0                @ 0x08007D84 pool 0x080084D0 = 0x20007CD0
    str r0, [r1, #0]                   @ 0x08007D88
    ldr r0, =v_20007CCC                @ 0x08007D8A pool 0x080084CC = 0x20007CCC
    ldr r0, [r0, #0]                   @ 0x08007D8E
    mov.w r1, #1000                    @ 0x08007D90
    mls r0, r1, r0, r4                 @ 0x08007D94
    bl fn_08012F60                     @ 0x08007D98
    mov r8, r0                         @ 0x08007D9C
    ldr r0, =v_20007CD0                @ 0x08007D9E pool 0x080084D0 = 0x20007CD0
    ldr r0, [r0, #0]                   @ 0x08007DA2
    ldr r1, =v_20007CCC                @ 0x08007DA4 pool 0x080084CC = 0x20007CCC
    ldr r1, [r1, #0]                   @ 0x08007DA8
    subs r0, r0, r1                    @ 0x08007DAA
    mov.w r1, #1000                    @ 0x08007DAC
    muls r0, r1                        @ 0x08007DB0
    bl fn_08012F60                     @ 0x08007DB2
    movs r1, r0                        @ 0x08007DB6
    mov r0, r8                         @ 0x08007DB8
    bl fn_08012F94                     @ 0x08007DBA
    ldr r1, =v_20007CC4                @ 0x08007DBE pool 0x080084D4 = 0x20007CC4
    str r0, [r1, #0]                   @ 0x08007DC2
    ldr r0, =v205_tab_08028838         @ 0x08007DC4 pool 0x080084C8 = 0x08028838
    uxtb r7, r7                        @ 0x08007DC8
    add.w r0, r0, r7, lsl #2           @ 0x08007DCA
    ldr r0, [r0, #52]                  @ 0x08007DCE
    ldr r1, =v205_tab_08028838         @ 0x08007DD0 pool 0x080084C8 = 0x08028838
    uxtb r7, r7                        @ 0x08007DD4
    add.w r1, r1, r7, lsl #2           @ 0x08007DD6
    ldr r1, [r1, #48]                  @ 0x08007DDA
    subs r0, r0, r1                    @ 0x08007DDC
    bl fn_08012F60                     @ 0x08007DDE
    ldr r1, =v_20007CC8                @ 0x08007DE2 pool 0x080084D8 = 0x20007CC8
    str r0, [r1, #0]                   @ 0x08007DE6
    ldr r0, =v_20007CC8                @ 0x08007DE8 pool 0x080084D8 = 0x20007CC8
    ldr r1, [r0, #0]                   @ 0x08007DEC
    ldr r0, =v_20007CC4                @ 0x08007DEE pool 0x080084D4 = 0x20007CC4
    ldr r0, [r0, #0]                   @ 0x08007DF2
    bl fn_08013090                     @ 0x08007DF4
    mov r8, r0                         @ 0x08007DF8
    ldr r0, =v205_tab_08028838         @ 0x08007DFA pool 0x080084C8 = 0x08028838
    uxtb r7, r7                        @ 0x08007DFE
    add.w r0, r0, r7, lsl #2           @ 0x08007E00
    ldr r0, [r0, #48]                  @ 0x08007E04
    bl fn_08012F60                     @ 0x08007E06
    mov r1, r8                         @ 0x08007E0A
    bl fn_080132EC                     @ 0x08007E0C
    ldr r1, =v_20007CC8                @ 0x08007E10 pool 0x080084D8 = 0x20007CC8
    str r0, [r1, #0]                   @ 0x08007E14
    movs r0, r5                        @ 0x08007E16
    bl fn_08012F60                     @ 0x08007E18
    ldr r1, =v_20007CC8                @ 0x08007E1C pool 0x080084D8 = 0x20007CC8
    ldr r1, [r1, #0]                   @ 0x08007E20
    bl fn_08013090                     @ 0x08007E22
    ldr r1, =0x42C80000                @ 0x08007E26 pool 0x080084DC = 0x42C80000
    bl fn_08012F94                     @ 0x08007E2A
    bl fn_08013370                     @ 0x08007E2E
    ldr r1, =v_20007CC0                @ 0x08007E32 pool 0x080087BC = 0x20007CC0
    str r0, [r1, #0]                   @ 0x08007E36
.L08007E38:                              @ reached from 0x08007D3E b
    ldr r0, =v_20007CC0                @ 0x08007E38 pool 0x080087BC = 0x20007CC0
    ldr r0, [r0, #0]                   @ 0x08007E3C
    ldmia.w sp!, {r4, r5, r6, r7, r8, pc}
.Lc6_none:
    movs r0, #0
    ldr r1, =v_20007CC0
    str r0, [r1]                            @ no correction (OF-01)
    b .L08007E38
    .ltorg
ENDFUNC fn_08007D1E
