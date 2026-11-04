@ =============================================================================
@ temp.s - MTMP: TEMP (mode 5): thermocouple conversion, degC to degF and the displayed temperature
@
@ Replaces v2.05 FUN_08007840 0x08007840 (TEMP handler), FUN_08013C40 0x08013C40 (thermocouple EMF -> temperature), FUN_08013B76
@ 0x08013B76 (degC -> degF) and FUN_08018AD8 0x08018AD8 (board temperature for the sub-display).
@
@ Chain (analysis/hy3131_modes_misc.md 4): AD1 mean -> FUN_080077F0 (MDC) gives the thermocouple EMF in uV (0x20007D64, 1 count = 1 uV);
@ x = EMF + cold junction CJ (0x20007E7C, uV, from thermistor.s) -> FUN_08013C40 -> T in 0.01 degC (0x20007E80) -> degF if 0x200080AB = 0 ->
@ rounded to 0.1 and stored as the displayed value 0x20007D64 and the per-sample value 0x20007D68.
@
@ OF-19: the conversion runs only for the sample that completed a mean (0x20008081 = 1), not whenever the new-value flag 0x2000805D is set:
@ v2.05 re-converted its own result (0x20007D64 holding degrees) on every sample while the display routine was not clearing 0x2000805D
@ (MEM view), which showed a wrong temperature afterwards.  mtmp_temp_result (port RAM) holds the last converted temperature (0.1 degree).
@ OF-21: rounding to 0.1 degree is half away from zero on the hundredths (v2.05 tested the tenths digit of the divided value).
@ OF-22: degC -> degF uses the signed 32-bit value (v2.05 took the sign from bit 15 and negated with one's complement).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mtmp.temp, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08007840 - TEMP handler: thermocouple temperature per mean
@ Replaces : 0x08007840 FUN_08007840 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 preserved)
@ Context  : main only
@ RAM      : reads  0x20007D64, 0x20007E7C, 0x20007E80, 0x2000805D, 0x20008081, 0x200080AB
@            writes mtmp_temp_result, 0x20007D64, 0x20007D68, 0x2000805E
@ Spec     : analysis/hy3131_modes_misc.md 4.1; ORIGINAL_FIRMWARE_ISSUES.md OF-19, OF-21
@ Deviation: OF-19, OF-21
@ First FUN_080077F0 (the DCmV chain; MDC).  Without a completed mean: 0x2000805E = 0.  With a mean: x = D + CJ, FUN_08013C40(x) gives T,
@ degF if 0x200080AB = 0, rounded to 0.1 degree, stored as D (when 0x2000805D = 1), as the per-sample value 0x20007D68 and in mtmp_temp_result.
@ -----------------------------------------------------------------------------
FUNC fn_08007840
    push {r4, lr}                      @ 0x08007840
    bl fn_080077F0                     @ 0x08007842
    @ OF-19: only the sample that completed a mean (0x20008081 = 1) is converted; v2.05 tested 0x2000805D here (0x08007846..0x0800784E)
    ldr r0, =v_20008081
    ldrb r0, [r0]                           @ a mean was completed by the AD1 sample just handled
    cmp r0, #0
    bne .L0800785A
    movs r0, #0                        @ 0x08007850
    ldr r1, =v_2000805E                @ 0x08007852 pool 0x080081F8 = 0x2000805E
    strb r0, [r1, #0]                  @ 0x08007856
    b .L080078B6                       @ 0x08007858
.L0800785A:                              @ reached from 0x0800784E bne
    @ ---- x = EMF (0x20007D64, uV) + cold junction CJ (0x20007E7C, uV); T = FUN_08013C40(x) in 0.01 degC at 0x20007E80 ----
    ldr r0, =v_20007D64                @ 0x0800785A pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x0800785E
    ldr r1, =v_20007E7C                @ 0x08007860 pool 0x080081FC = 0x20007E7C
    ldr r1, [r1, #0]                   @ 0x08007864
    adds r0, r1, r0                    @ 0x08007866
    movs r4, r0                        @ 0x08007868
    movs r0, r4                        @ 0x0800786A
    bl fn_08013C40                     @ 0x0800786C
    ldr r0, =v_20007E80                @ 0x08007870 pool 0x08008200 = 0x20007E80
    ldr r0, [r0, #0]                   @ 0x08007874
    movs r4, r0                        @ 0x08007876
    ldr r0, =v_200080AB                @ 0x08007878 pool 0x08008204 = 0x200080AB
    ldrb r0, [r0, #0]                  @ 0x0800787C
    cmp r0, #0                         @ 0x0800787E
    bne .L0800788A                     @ 0x08007880
    movs r0, r4                        @ 0x08007882
    bl fn_08013B76                     @ 0x08007884
    movs r4, r0                        @ 0x08007888
.L0800788A:                              @ reached from 0x08007880 bne
    @ OF-21: T (0.01 degree, degC or degF) to 0.1 degree, rounded half away from zero on the hundredths
    cmp r4, #0
    ite ge
    addge r4, r4, #5                        @ T >= 0: +5 before the truncating divide
    sublt r4, r4, #5                        @ T < 0: -5
    movs r0, #10
    sdiv r4, r4, r0                         @ 0.1 degree units (v2.05 divided first and rounded on the tenths, 0x0800788A..0x0800789E)
.L080078A0:                              @ reached from 0x0800789C blt
    ldr r0, =v_2000805D                @ 0x080078A0 pool 0x08007F9C = 0x2000805D
    ldrb r0, [r0, #0]                  @ 0x080078A4
    cmp r0, #0                         @ 0x080078A6
    beq .L080078B0                     @ 0x080078A8
    ldr r0, =v_20007D64                @ 0x080078AA pool 0x08007F94 = 0x20007D64
    str r4, [r0, #0]                   @ 0x080078AE
.L080078B0:                              @ reached from 0x080078A8 beq
    ldr r0, =mtmp_temp_result
    str r4, [r0]                            @ OF-19: the converted temperature (0.1 degree) in its own variable
    ldr r0, =v_20007D68                @ 0x080078B0 pool 0x08008340 = 0x20007D68
    str r4, [r0, #0]                   @ 0x080078B4
.L080078B6:                              @ reached from 0x08007858 b
    pop {r4, pc}                       @ 0x080078B6
    .ltorg
ENDFUNC fn_08007840

@ -----------------------------------------------------------------------------
@ fn_08013B76 - degC to degF in 0.01 degree
@ Replaces : 0x08013B76 FUN_08013B76 (v2.05)
@ In       : r0 = temperature in 0.01 degC (signed 32 bit)
@ Out      : r0 = temperature in 0.01 degF
@ Clobbers : r0, r1, flags
@ Context  : main only
@ RAM      : none directly
@ Spec     : analysis/hy3131_modes_misc.md 4.3; ORIGINAL_FIRMWARE_ISSUES.md OF-22
@ Deviation: OF-22
@ v2.05 took the sign from bit 15 of the 32-bit value (so 327.68 .. 655.35 degC and 983.04 .. 1310.71 degC were treated as negative) and
@ negated with one's complement (|x| - 1 for negative inputs): up to 0.02 degF error, -40.00 degC gave -39.99 degF.  Its float sequence gave the
@ exact rounding of 1.8 x + 3200 for 0 <= x <= 32767; the port computes that rounding in integers for every signed 32-bit x.
@ -----------------------------------------------------------------------------
FUNC fn_08013B76
    @ x in r0 (0.01 degC, signed 32 bit).  F = 1.8 x + 3200 (0.01 degF) = (9 x + 16000) / 5, rounded to nearest (no ties exist: the
    @ fraction is a multiple of 0.2), half away from zero for negative N: r = (N + 2) / 5 for N >= 0, (N - 2) / 5 for N < 0, truncating.
    movs r1, #9
    muls r0, r1, r0                         @ 9 x (|x| < 2^31 / 9: thermocouple range 0.01 degC <= 135 000, board +-32 767)
    mov.w r1, #16000
    adds r0, r0, r1                         @ N = 9 x + 16000
    cmp r0, #0
    ite ge
    addge r0, r0, #2                        @ round: +2 for N >= 0
    sublt r0, r0, #2                        @ -2 for N < 0
    movs r1, #5
    sdiv r0, r0, r1                         @ truncating divide by 5
    bx lr
    .ltorg
ENDFUNC fn_08013B76

@ -----------------------------------------------------------------------------
@ fn_08013C40 - thermocouple EMF to temperature (table 0x08025CF8)
@ Replaces : 0x08013C40 FUN_08013C40 (v2.05)
@ In       : r0 = EMF x in uV (including the cold junction)
@ Out      : - (0x20007E80 = T in 0.01 degC, 0x200080AD = range flag)
@ Clobbers : r0-r3, r12, flags (r4-r6 preserved)
@ Context  : main only
@ RAM      : reads  mtmp_tc_tab_k (the NIST K table, OF-56; v2.05 0x08025CF8), 0x20007E84, 0x20007E88
@            writes 0x20007E80, 0x20007E84, 0x20007E88, 0x200080AD
@ Spec     : analysis/hy3131_modes_misc.md 4.1 step 4
@ Deviation: IMP-10 (production: table and window from the descriptor of the selected type, mtmp/tctype.s)
@ The table holds 158 EMF values in uV at 10 k - 210 degC (t[0] = -6035, t[21] = 0, t[157] = 54479; these are the type K reference values, e.g. -5891 uV at -200 degC and
@ 54138 uV at 1350 degC).  x < -5891: T = 0 and 0x200080AD = 2 ("-OFL"); x >= 54139: T = 0 and 0x200080AD = 1 (" OFL "); otherwise with i the first index where t[i] >= x:
@ T = 1000 i - 22000 + (t[i-1] - x) * 1000 / (t[i-1] - t[i]) (integer, truncating; the i2f / f2iz pair after it does not change an integer).
@ -----------------------------------------------------------------------------
FUNC fn_08013C40
    push {r4, r5, r6, lr}              @ 0x08013C40
    movs r4, r0                        @ 0x08013C42
    ldr r12, =mtmp_tc_descp            @ IMP-10: r12 = descriptor {table, low, high} of the selected type, kept until the
    ldr r12, [r12]                     @ last table read (no call before it)
    movs r6, #1                        @ 0x08013C44
    movs r0, #0                        @ 0x08013C46
    ldr r1, =v_200080AD                @ 0x08013C48 pool 0x08013EAC = 0x200080AD
    strb r0, [r1, #0]                  @ 0x08013C4A
    @ x < -5891 uV: T = 0, 0x200080AD = 2
    ldr r0, [r12, #4]                  @ IMP-10: low limit of the type (K: -5891)
    cmp r4, r0                         @ 0x08013C4E
    bge .L08013C60                     @ 0x08013C50
    movs r0, #0                        @ 0x08013C52
    ldr r1, =v_20007E80                @ 0x08013C54 pool 0x08013EB4 = 0x20007E80
    str r0, [r1, #0]                   @ 0x08013C56
    movs r0, #2                        @ 0x08013C58
    ldr r1, =v_200080AD                @ 0x08013C5A pool 0x08013EAC = 0x200080AD
    strb r0, [r1, #0]                  @ 0x08013C5C
    b .L08013CF6                       @ 0x08013C5E
.L08013C60:                              @ reached from 0x08013C50 bge
    @ x >= 54139 uV: T = 0, 0x200080AD = 1
    ldr r0, [r12, #8]                  @ IMP-10: high limit of the type (K: 54139)
    cmp r4, r0                         @ 0x08013C64
    blt .L08013C76                     @ 0x08013C66
    movs r0, #0                        @ 0x08013C68
    ldr r1, =v_20007E80                @ 0x08013C6A pool 0x08013EB4 = 0x20007E80
    str r0, [r1, #0]                   @ 0x08013C6C
    movs r0, #1                        @ 0x08013C6E
    ldr r1, =v_200080AD                @ 0x08013C70 pool 0x08013EAC = 0x200080AD
    strb r0, [r1, #0]                  @ 0x08013C72
    b .L08013CF6                       @ 0x08013C74
.L08013C76:                              @ reached from 0x08013C66 blt
    @ search the first table index with t[i] >= x
    movs r0, #0                        @ 0x08013C76
    movs r5, r0                        @ 0x08013C78
.L08013C7A:                              @ reached from 0x08013C8E b, 0x08013C94 b
    uxtb r6, r6                        @ 0x08013C7A
    cmp r6, #0                         @ 0x08013C7C
    beq .L08013C96                     @ 0x08013C7E
    ldr r0, [r12]                      @ IMP-10: table of the type (K: 0x08025CF8)
    uxtb r5, r5                        @ 0x08013C82
    ldr.w r0, [r0, r5, lsl #2]         @ 0x08013C84
    cmp r0, r4                         @ 0x08013C88
    bge .L08013C90                     @ 0x08013C8A
    adds r5, r5, #1                    @ 0x08013C8C
    b .L08013C7A                       @ 0x08013C8E
.L08013C90:                              @ reached from 0x08013C8A bge
    movs r0, #0                        @ 0x08013C90
    movs r6, r0                        @ 0x08013C92
    b .L08013C7A                       @ 0x08013C94
.L08013C96:                              @ reached from 0x08013C7E beq
    @ T = 1000 i - 22000 + (t[i-1] - x) * 1000 / (t[i-1] - t[i]) (0.01 degC)
    uxtb r5, r5                        @ 0x08013C96
    mov.w r0, #1000                    @ 0x08013C98
    ldr r1, =0xFFFFAA10                @ 0x08013C9C pool 0x08013EBC = 0xFFFFAA10
    mla r0, r0, r5, r1                 @ 0x08013C9E
    ldr r1, =v_20007E84                @ 0x08013CA2 pool 0x08013EC0 = 0x20007E84
    str r0, [r1, #0]                   @ 0x08013CA4
    ldr r0, [r12]                      @ IMP-10: table of the type (K: 0x08025CF8)
    uxtb r5, r5                        @ 0x08013CA8
    add.w r0, r0, r5, lsl #2           @ 0x08013CAA
    ldr.w r0, [r0, #-4]                @ 0x08013CAE
    subs r0, r0, r4                    @ 0x08013CB2
    mov.w r1, #1000                    @ 0x08013CB4
    muls r0, r1                        @ 0x08013CB8
    ldr r1, [r12]                      @ IMP-10: table of the type (K: 0x08025CF8)
    uxtb r5, r5                        @ 0x08013CBC
    add.w r1, r1, r5, lsl #2           @ 0x08013CBE
    ldr.w r1, [r1, #-4]                @ 0x08013CC2
    ldr r2, [r12]                      @ IMP-10: table of the type (K: 0x08025CF8)
    uxtb r5, r5                        @ 0x08013CC8
    ldr.w r2, [r2, r5, lsl #2]         @ 0x08013CCA
    subs r1, r1, r2                    @ 0x08013CCE
    sdiv r0, r0, r1                    @ 0x08013CD0
    bl fn_08012F60                     @ 0x08013CD4
    bl fn_08013370                     @ 0x08013CD8
    ldr r1, =v_20007E88                @ 0x08013CDC pool 0x08013E94 = 0x20007E88
    str r0, [r1, #0]                   @ 0x08013CDE
    ldr r0, =v_20007E88                @ 0x08013CE0 pool 0x08013E94 = 0x20007E88
    ldr r0, [r0, #0]                   @ 0x08013CE2
    ldr r1, =v_20007E84                @ 0x08013CE4 pool 0x08013EC0 = 0x20007E84
    ldr r1, [r1, #0]                   @ 0x08013CE6
    adds r0, r1, r0                    @ 0x08013CE8
    ldr r1, =v_20007E88                @ 0x08013CEA pool 0x08013E94 = 0x20007E88
    str r0, [r1, #0]                   @ 0x08013CEC
    ldr r0, =v_20007E88                @ 0x08013CEE pool 0x08013E94 = 0x20007E88
    ldr r0, [r0, #0]                   @ 0x08013CF0
    ldr r1, =v_20007E80                @ 0x08013CF2 pool 0x08013EB4 = 0x20007E80
    str r0, [r1, #0]                   @ 0x08013CF4
.L08013CF6:                              @ reached from 0x08013C5E b, 0x08013C74 b
    pop {r4, r5, r6, pc}               @ 0x08013CF6
    .ltorg
ENDFUNC fn_08013C40

@ -----------------------------------------------------------------------------
@ fn_08018AD8 - board (cold-junction) temperature for the sub-display, 0.1 degree
@ Replaces : 0x08018AD8 FUN_08018AD8 (v2.05)
@ In       : r0 = temperature in 0.01 degC (16 bit signed, 0x20007FCC)
@ Out      : r0 = 0.1 degree (degF if 0x200080AB = 0), signed
@ Clobbers : r0-r3, r12, flags (r4, r5 preserved)
@ Context  : main only
@ RAM      : reads  0x200080AB
@ Spec     : analysis/hy3131_modes_misc.md 9 (page 0); ORIGINAL_FIRMWARE_ISSUES.md OF-21, OF-22
@ Deviation: OF-21, OF-22
@ Converts to degF with FUN_08013B76 when 0x200080AB = 0, then rounds to 0.1 degree half away from zero on the hundredths (OF-21).
@ -----------------------------------------------------------------------------
FUNC fn_08018AD8
    push {r3, r4, r5, lr}              @ 0x08018AD8
    movs r4, r0                        @ 0x08018ADA
    ldr r0, =v_200080AB                @ 0x08018ADC pool 0x08019804 = 0x200080AB
    ldrb r0, [r0, #0]                  @ 0x08018AE0
    cmp r0, #0                         @ 0x08018AE2
    bne .L08018AF2                     @ 0x08018AE4
    sxth r4, r4                        @ 0x08018AE6
    movs r0, r4                        @ 0x08018AE8
    bl fn_08013B76                     @ 0x08018AEA
    movs r5, r0                        @ 0x08018AEE
    b .L08018AF4                       @ 0x08018AF0
.L08018AF2:                              @ reached from 0x08018AE4 bne
    movs r5, r4                        @ 0x08018AF2
.L08018AF4:                              @ reached from 0x08018AF0 b
    sxth r5, r5                        @ 0x08018AF4
    @ OF-21: 0.01 degree to 0.1 degree, half away from zero (v2.05 0x08018AF6..0x08018B0C rounded on the tenths of the divided value)
    cmp r5, #0
    ite ge
    addge r5, r5, #5
    sublt r5, r5, #5
    movs r0, #10
    sdiv r5, r5, r0
    sxth r5, r5
.L08018B0E:                              @ reached from 0x08018B0A blt
    movs r0, r5                        @ 0x08018B0E
    sxth r0, r0                        @ 0x08018B10
    pop {r1, r4, r5, pc}               @ 0x08018B12
    .ltorg
ENDFUNC fn_08018AD8


    .section .bss_port.mtmp, "aw", %nobits
    .balign 4
    .global mtmp_temp_result
mtmp_temp_result: .space 4                  @ OF-19: last converted TEMP value in 0.1 degree (degC or degF per 0x200080AB), s32
