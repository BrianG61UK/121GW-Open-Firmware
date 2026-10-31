@ =============================================================================
@ pulse.s - MFRQ: PULSE (mode 7) and DUTY (mode 8) chains and their helpers
@
@ Replaces v2.05 FUN_0800B070 0x0800B070 (PULSE), FUN_0800B244 0x0800B244 (PULSE range apply), FUN_0800B2D8 0x0800B2D8 (DUTY),
@ FUN_0800B67C 0x0800B67C (period) and FUN_0800B6D4 0x0800B6D4 (duty).
@
@ OF-18: v2.05 computed the pulse width as P * duty / 1000 with duty = CTC / (T / 1000) truncated to 0.1 % and P the period truncated to
@ 0.1 us, so widths moved in steps of 0.1 % of the period and were always rounded down.  The port uses the counts directly:
@   W = CTC * 10^8 / (ref * CTB)  in 0.1 us, rounded to nearest (the gate T cancels: W = P * CTC / T with P = 10^8 * T / (ref * CTB)).
@ FUN_0800B6D4 still computes the duty (0x20007E34, 0.1 %) because DUTY mode shows it; FUN_0800B67C (the period P) is no longer
@ called by FUN_0800B070 and is kept as the v2.05 period routine.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mfrq.pulse, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800B070 - PULSE chain: pulse width and range
@ Replaces : 0x0800B070 FUN_0800B070 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4, r5 preserved)
@ Context  : main only
@ RAM      : reads  0x20007E18 freq_reference, 0x2000803C meter_mode, 0x2000803D meter_range,
@            0x20008042 range_manual, 0x20007C48, 0x20007E40, 0x20007E44, 0x2000808A
@            writes 0x20007C48, 0x2000803F, 0x20008045, 0x20008046, 0x2000805D
@ Spec     : analysis/hy3131_modes_misc.md 5.3; ORIGINAL_FIRMWARE_ISSUES.md OF-18
@ Deviation: OF-18
@ After the width W (0.1 us, 64 bit) the range logic is v2.05's: manual (range_manual = 1, not in calibration mode): range 0 shows W if W < 100 000,
@ range 1 W/10 if W < 1 000 000, range 2 W/100 if W < 10 000 000, otherwise overload (0x20008046); auto: W >= 10^7 overload and range 2; W >= 10^6 range 2;
@ range 2 stays down to 800 000; W >= 100 000 range 1; range 1 stays down to 80 000; else range 0.  The range byte changes without a configuration
@ rewrite (the PULSE rows are identical).  0x2000805D = 1 and 0x2000803F = decimal_position(7, range).
@ -----------------------------------------------------------------------------
FUNC fn_0800B070
    push {r3, r4, r5, lr}              @ 0x0800B070
    movs r0, #0                        @ 0x0800B072
    ldr r1, =v_20008045                @ 0x0800B074 pool 0x0800B324 = 0x20008045
    strb r0, [r1, #0]                  @ 0x0800B076
    bl fn_0800B6D4                          @ duty (0.1 %), 0x20007E34 (v2.05 0x0800B07C; read by DUTY and the sub-display)
    @ ---- OF-18: W = CTC * 10^8 / (ref * CTB), rounded to nearest, in 0.1 us (v2.05: P * duty / 1000, 0x0800B078..0x0800B0AA) ----
    ldr r0, =v_20007E44
    ldr r0, [r0]                            @ CTC (ticks with the input high)
    ldr r1, =100000000
    umull r2, r3, r0, r1                    @ r3:r2 = CTC * 10^8 (< 2^51)
    ldr r0, =freq_reference
    ldr r0, [r0]                            @ ref = 10 x SYSCLK
    ldr r1, =v_20007E40
    ldr r1, [r1]                            @ CTB (whole input cycles)
    umull r4, r5, r0, r1                    @ r5:r4 = ref * CTB = the divisor (< 2^50)
    lsrs r0, r4, #1
    orr r0, r0, r5, lsl #31
    lsrs r1, r5, #1                         @ r1:r0 = divisor / 2
    adds r2, r2, r0
    adcs r3, r1                             @ r3:r2 = CTC * 10^8 + divisor / 2: rounds to nearest
    movs r0, r2
    movs r1, r3                             @ dividend in r1:r0
    movs r2, r4
    movs r3, r5                             @ divisor in r3:r2 (0 gives the dividend back: overload below)
    bl fn_08014028                          @ 64-bit unsigned divide, quotient in r1:r0
    ldr r2, =v_20007C48
    strd r0, r1, [r2]                       @ W (0.1 us) replaces the period in 0x20007C48 (v2.05 0x0800B0AA)
    @ ---- range selection from W (0.1 us, 64 bit); manual: range_manual = 1 outside calibration mode ----
    ldr r0, =v_2000808A                @ 0x0800B0AE pool 0x0800B334 = 0x2000808A
    ldrb r0, [r0, #0]                  @ 0x0800B0B0
    ldr r1, =range_manual              @ 0x0800B0B2 pool 0x0800B73C = 0x20008042
    ldrb r1, [r1, #0]                  @ 0x0800B0B6
    eors.w r1, r1, #1                  @ 0x0800B0B8
    orrs r0, r1                        @ 0x0800B0BC
    uxtb r0, r0                        @ 0x0800B0BE
    cmp r0, #0                         @ 0x0800B0C0
    bne .L0800B154                     @ 0x0800B0C2
    ldr r0, =meter_range               @ 0x0800B0C4 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B0C8
    cmp r0, #0                         @ 0x0800B0CA
    beq .L0800B12A                     @ 0x0800B0CC
    cmp r0, #2                         @ 0x0800B0CE
    beq .L0800B0D6                     @ 0x0800B0D0
    bcc .L0800B100                     @ 0x0800B0D2
    b .L0800B20E                       @ 0x0800B0D4
.L0800B0D6:                              @ reached from 0x0800B0D0 beq
    @ manual range 2: W < 10 000 000 shows W/100, else overload
    ldr r0, =v_20007C48                @ 0x0800B0D6 pool 0x0800B958 = 0x20007C48
    ldrd r2, r3, [r0]                  @ 0x0800B0DA
    ldr r0, =0x00989680                @ 0x0800B0DE pool 0x0800B74C = 0x00989680
    movs r1, #0                        @ 0x0800B0E2
    cmp r3, r1                         @ 0x0800B0E4
    bcc .L0800B0F8                     @ 0x0800B0E6
    bhi .L0800B0EE                     @ 0x0800B0E8
    cmp r2, r0                         @ 0x0800B0EA
    bcc .L0800B0F8                     @ 0x0800B0EC
.L0800B0EE:                              @ reached from 0x0800B0E8 bhi
    movs r0, #1                        @ 0x0800B0EE
    ldr r1, =v_20008046                @ 0x0800B0F0 pool 0x0800B738 = 0x20008046
    strb r0, [r1, #0]                  @ 0x0800B0F4
    b .L0800B0FE                       @ 0x0800B0F6
.L0800B0F8:                              @ reached from 0x0800B0E6 bcc, 0x0800B0EC bcc
    movs r0, #2                        @ 0x0800B0F8
    bl fn_0800B244                     @ 0x0800B0FA
.L0800B0FE:                              @ reached from 0x0800B0F6 b
    b .L0800B20E                       @ 0x0800B0FE
.L0800B100:                              @ reached from 0x0800B0D2 bcc
    @ manual range 1: W < 1 000 000 shows W/10, else overload
    ldr r0, =v_20007C48                @ 0x0800B100 pool 0x0800B958 = 0x20007C48
    ldrd r2, r3, [r0]                  @ 0x0800B104
    ldr r0, =0x000F4240                @ 0x0800B108 pool 0x0800B750 = 0x000F4240
    movs r1, #0                        @ 0x0800B10C
    cmp r3, r1                         @ 0x0800B10E
    bcc .L0800B122                     @ 0x0800B110
    bhi .L0800B118                     @ 0x0800B112
    cmp r2, r0                         @ 0x0800B114
    bcc .L0800B122                     @ 0x0800B116
.L0800B118:                              @ reached from 0x0800B112 bhi
    movs r0, #1                        @ 0x0800B118
    ldr r1, =v_20008046                @ 0x0800B11A pool 0x0800B738 = 0x20008046
    strb r0, [r1, #0]                  @ 0x0800B11E
    b .L0800B128                       @ 0x0800B120
.L0800B122:                              @ reached from 0x0800B110 bcc, 0x0800B116 bcc
    movs r0, #1                        @ 0x0800B122
    bl fn_0800B244                     @ 0x0800B124
.L0800B128:                              @ reached from 0x0800B120 b
    b .L0800B20E                       @ 0x0800B128
.L0800B12A:                              @ reached from 0x0800B0CC beq
    @ manual range 0: W < 100 000 shows W, else overload
    ldr r0, =v_20007C48                @ 0x0800B12A pool 0x0800B958 = 0x20007C48
    ldrd r2, r3, [r0]                  @ 0x0800B12E
    ldr r0, =0x000186A0                @ 0x0800B132 pool 0x0800B964 = 0x000186A0
    movs r1, #0                        @ 0x0800B136
    cmp r3, r1                         @ 0x0800B138
    bcc .L0800B14C                     @ 0x0800B13A
    bhi .L0800B142                     @ 0x0800B13C
    cmp r2, r0                         @ 0x0800B13E
    bcc .L0800B14C                     @ 0x0800B140
.L0800B142:                              @ reached from 0x0800B13C bhi
    movs r0, #1                        @ 0x0800B142
    ldr r1, =v_20008046                @ 0x0800B144 pool 0x0800B738 = 0x20008046
    strb r0, [r1, #0]                  @ 0x0800B148
    b .L0800B152                       @ 0x0800B14A
.L0800B14C:                              @ reached from 0x0800B13A bcc, 0x0800B140 bcc
    movs r0, #0                        @ 0x0800B14C
    bl fn_0800B244                     @ 0x0800B14E
.L0800B152:                              @ reached from 0x0800B14A b
    b .L0800B20E                       @ 0x0800B152
.L0800B154:                              @ reached from 0x0800B0C2 bne
    @ ---- auto range: first match wins ----
    ldr r0, =v_20007C48                @ 0x0800B154 pool 0x0800B958 = 0x20007C48
    ldrd r2, r3, [r0]                  @ 0x0800B158
    ldr r0, =0x00989680                @ 0x0800B15C pool 0x0800B74C = 0x00989680
    movs r1, #0                        @ 0x0800B160
    cmp r3, r1                         @ 0x0800B162
    bcc .L0800B174                     @ 0x0800B164
    bhi .L0800B16C                     @ 0x0800B166
    cmp r2, r0                         @ 0x0800B168
    bcc .L0800B174                     @ 0x0800B16A
.L0800B16C:                              @ reached from 0x0800B166 bhi
    @ W >= 10 000 000: overload (fn_0800B244(9))
    movs r0, #9                        @ 0x0800B16C
    bl fn_0800B244                     @ 0x0800B16E
    b .L0800B20E                       @ 0x0800B172
.L0800B174:                              @ reached from 0x0800B164 bcc, 0x0800B16A bcc
    @ W >= 1 000 000: range 2
    ldr r0, =v_20007C48                @ 0x0800B174 pool 0x0800B958 = 0x20007C48
    ldrd r2, r3, [r0]                  @ 0x0800B178
    ldr r0, =0x000F4240                @ 0x0800B17C pool 0x0800B750 = 0x000F4240
    movs r1, #0                        @ 0x0800B180
    cmp r3, r1                         @ 0x0800B182
    bcc .L0800B194                     @ 0x0800B184
    bhi .L0800B18C                     @ 0x0800B186
    cmp r2, r0                         @ 0x0800B188
    bcc .L0800B194                     @ 0x0800B18A
.L0800B18C:                              @ reached from 0x0800B186 bhi
    movs r0, #2                        @ 0x0800B18C
    bl fn_0800B244                     @ 0x0800B18E
    b .L0800B20E                       @ 0x0800B192
.L0800B194:                              @ reached from 0x0800B184 bcc, 0x0800B18A bcc
    @ range 2 stays while W >= 800 000
    ldr r0, =meter_range               @ 0x0800B194 pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B198
    cmp r0, #2                         @ 0x0800B19A
    bne .L0800B1BE                     @ 0x0800B19C
    ldr r0, =v_20007C48                @ 0x0800B19E pool 0x0800B958 = 0x20007C48
    ldrd r2, r3, [r0]                  @ 0x0800B1A2
    ldr r0, =0x000C3500                @ 0x0800B1A6 pool 0x0800B934 = 0x000C3500
    movs r1, #0                        @ 0x0800B1AA
    cmp r3, r1                         @ 0x0800B1AC
    bcc .L0800B1BE                     @ 0x0800B1AE
    bhi .L0800B1B6                     @ 0x0800B1B0
    cmp r2, r0                         @ 0x0800B1B2
    bcc .L0800B1BE                     @ 0x0800B1B4
.L0800B1B6:                              @ reached from 0x0800B1B0 bhi
    movs r0, #2                        @ 0x0800B1B6
    bl fn_0800B244                     @ 0x0800B1B8
    b .L0800B20E                       @ 0x0800B1BC
.L0800B1BE:                              @ reached from 0x0800B19C bne, 0x0800B1AE bcc, 0x0800B1B4 bcc
    ldr r0, =v_20007C48                @ 0x0800B1BE pool 0x0800B958 = 0x20007C48
    ldrd r2, r3, [r0]                  @ 0x0800B1C2
    ldr r0, =0x000186A0                @ 0x0800B1C6 pool 0x0800B964 = 0x000186A0
    movs r1, #0                        @ 0x0800B1CA
    cmp r3, r1                         @ 0x0800B1CC
    bcc .L0800B1DE                     @ 0x0800B1CE
    bhi .L0800B1D6                     @ 0x0800B1D0
    cmp r2, r0                         @ 0x0800B1D2
    bcc .L0800B1DE                     @ 0x0800B1D4
.L0800B1D6:                              @ reached from 0x0800B1D0 bhi
    movs r0, #1                        @ 0x0800B1D6
    bl fn_0800B244                     @ 0x0800B1D8
    b .L0800B20E                       @ 0x0800B1DC
.L0800B1DE:                              @ reached from 0x0800B1CE bcc, 0x0800B1D4 bcc
    ldr r0, =meter_range               @ 0x0800B1DE pool 0x0800B960 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x0800B1E2
    cmp r0, #1                         @ 0x0800B1E4
    bne .L0800B208                     @ 0x0800B1E6
    ldr r0, =v_20007C48                @ 0x0800B1E8 pool 0x0800B958 = 0x20007C48
    ldrd r2, r3, [r0]                  @ 0x0800B1EC
    ldr r0, =0x00013880                @ 0x0800B1F0 pool 0x0800B938 = 0x00013880
    movs r1, #0                        @ 0x0800B1F4
    cmp r3, r1                         @ 0x0800B1F6
    bcc .L0800B208                     @ 0x0800B1F8
    bhi .L0800B200                     @ 0x0800B1FA
    cmp r2, r0                         @ 0x0800B1FC
    bcc .L0800B208                     @ 0x0800B1FE
.L0800B200:                              @ reached from 0x0800B1FA bhi
    movs r0, #1                        @ 0x0800B200
    bl fn_0800B244                     @ 0x0800B202
    b .L0800B20E                       @ 0x0800B206
.L0800B208:                              @ reached from 0x0800B1E6 bne, 0x0800B1F8 bcc, 0x0800B1FE bcc
    movs r0, #0                        @ 0x0800B208
    bl fn_0800B244                     @ 0x0800B20A
.L0800B20E:                              @ reached from 0x0800B0D4 b, 0x0800B0FE b, 0x0800B128 b, 0x0800B152 b, 0x0800B172 b, 0x0800B192 b, 0x0800B1BC b, 0x0800B1DC b, 0x0800B206 b
    @ ---- 0x2000805D = 1 and 0x2000803F = decimal_position(7, range) ----
    movs r0, #1                        @ 0x0800B20E
    ldr r1, =v_2000805D                @ 0x0800B210 pool 0x0800B968 = 0x2000805D
    strb r0, [r1, #0]                  @ 0x0800B214
    ldr r0, =meter_range               @ 0x0800B216 pool 0x0800B960 = 0x2000803D
    ldrb r1, [r0, #0]                  @ 0x0800B21A
    ldr r0, =meter_mode                @ 0x0800B21C pool 0x0800B96C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800B220
    bl decimal_position_for_mode_range @ 0x0800B222
    ldr r1, =v_2000803F                @ 0x0800B226 pool 0x0800B93C = 0x2000803F
    strb r0, [r1, #0]                  @ 0x0800B22A
    pop {r0, r4, r5, pc}               @ 0x0800B22C
    .ltorg
ENDFUNC fn_0800B070

@ -----------------------------------------------------------------------------
@ fn_0800B244 - PULSE: apply a range to the width
@ Replaces : 0x0800B244 FUN_0800B244 (v2.05)
@ In       : r0 = range 0, 1, 2 or 9 (overload, range 2)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x20007C48
@            writes 0x2000803D meter_range, 0x20007D64, 0x20008046
@ Spec     : analysis/hy3131_modes_misc.md 5.3
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800B244
    @ range r0: 0 -> W, 1 -> W/10, 2 -> W/100 (D = 0x20007D64); 9 -> range 2 and the overload flag
    push {r4, lr}                      @ 0x0800B244
    movs r4, r0                        @ 0x0800B246
    uxtb r4, r4                        @ 0x0800B248
    movs r0, r4                        @ 0x0800B24A
    cmp r0, #0                         @ 0x0800B24C
    beq .L0800B25E                     @ 0x0800B24E
    cmp r0, #1                         @ 0x0800B250
    beq .L0800B27E                     @ 0x0800B252
    cmp r0, #2                         @ 0x0800B254
    beq .L0800B29E                     @ 0x0800B256
    cmp r0, #9                         @ 0x0800B258
    beq .L0800B2BE                     @ 0x0800B25A
    b .L0800B2CE                       @ 0x0800B25C
.L0800B25E:                              @ reached from 0x0800B24E beq
    movs r0, #0                        @ 0x0800B25E
    ldr r1, =meter_range               @ 0x0800B260 pool 0x0800B960 = 0x2000803D
    strb r0, [r1, #0]                  @ 0x0800B264
    ldr r2, =v_20007C48                @ 0x0800B266 pool 0x0800B958 = 0x20007C48
    ldrd r0, r1, [r2]                  @ 0x0800B26A
    movs r2, #1                        @ 0x0800B26E
    movs r3, #0                        @ 0x0800B270
    bl fn_08014028                     @ 0x0800B272
    ldr r1, =v_20007D64                @ 0x0800B276 pool 0x0800B970 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800B27A
    b .L0800B2CE                       @ 0x0800B27C
.L0800B27E:                              @ reached from 0x0800B252 beq
    movs r0, #1                        @ 0x0800B27E
    ldr r1, =meter_range               @ 0x0800B280 pool 0x0800B960 = 0x2000803D
    strb r0, [r1, #0]                  @ 0x0800B284
    ldr r2, =v_20007C48                @ 0x0800B286 pool 0x0800B958 = 0x20007C48
    ldrd r0, r1, [r2]                  @ 0x0800B28A
    movs r2, #10                       @ 0x0800B28E
    movs r3, #0                        @ 0x0800B290
    bl fn_08014028                     @ 0x0800B292
    ldr r1, =v_20007D64                @ 0x0800B296 pool 0x0800B970 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800B29A
    b .L0800B2CE                       @ 0x0800B29C
.L0800B29E:                              @ reached from 0x0800B256 beq
    movs r0, #2                        @ 0x0800B29E
    ldr r1, =meter_range               @ 0x0800B2A0 pool 0x0800B960 = 0x2000803D
    strb r0, [r1, #0]                  @ 0x0800B2A4
    ldr r2, =v_20007C48                @ 0x0800B2A6 pool 0x0800B958 = 0x20007C48
    ldrd r0, r1, [r2]                  @ 0x0800B2AA
    movs r2, #100                      @ 0x0800B2AE
    movs r3, #0                        @ 0x0800B2B0
    bl fn_08014028                     @ 0x0800B2B2
    ldr r1, =v_20007D64                @ 0x0800B2B6 pool 0x0800B970 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800B2BA
    b .L0800B2CE                       @ 0x0800B2BC
.L0800B2BE:                              @ reached from 0x0800B25A beq
    movs r0, #2                        @ 0x0800B2BE
    ldr r1, =meter_range               @ 0x0800B2C0 pool 0x0800B960 = 0x2000803D
    strb r0, [r1, #0]                  @ 0x0800B2C4
    movs r0, #1                        @ 0x0800B2C6
    ldr r1, =v_20008046                @ 0x0800B2C8 pool 0x0800B738 = 0x20008046
    strb r0, [r1, #0]                  @ 0x0800B2CC
.L0800B2CE:                              @ reached from 0x0800B25C b, 0x0800B27C b, 0x0800B29C b, 0x0800B2BC b
    pop {r4, pc}                       @ 0x0800B2CE
    .ltorg
ENDFUNC fn_0800B244

@ -----------------------------------------------------------------------------
@ fn_0800B2D8 - DUTY chain
@ Replaces : 0x0800B2D8 FUN_0800B2D8 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x20007E34
@            writes 0x20007D64, 0x20008045, 0x2000805D
@ Spec     : analysis/hy3131_modes_misc.md 5.4
@ Deviation: none
@ D = CTC / (T / 1000), truncated, in 0.1 %; no smoothing and no range logic.
@ -----------------------------------------------------------------------------
FUNC fn_0800B2D8
    push {r7, lr}                      @ 0x0800B2D8
    movs r0, #0                        @ 0x0800B2DA
    ldr r1, =v_20008045                @ 0x0800B2DC pool 0x0800B324 = 0x20008045
    strb r0, [r1, #0]                  @ 0x0800B2DE
    bl fn_0800B6D4                     @ 0x0800B2E0
    ldr r0, =v_20007E34                @ 0x0800B2E4 pool 0x0800B95C = 0x20007E34
    ldr r0, [r0, #0]                   @ 0x0800B2E8
    ldr r1, =v_20007D64                @ 0x0800B2EA pool 0x0800B970 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800B2EE
    movs r0, #1                        @ 0x0800B2F0
    ldr r1, =v_2000805D                @ 0x0800B2F2 pool 0x0800B968 = 0x2000805D
    strb r0, [r1, #0]                  @ 0x0800B2F6
    pop {r0, pc}                       @ 0x0800B2F8
    .ltorg
ENDFUNC fn_0800B2D8

@ -----------------------------------------------------------------------------
@ fn_0800B67C - input period in 0.1 us (64 bit)
@ Replaces : 0x0800B67C FUN_0800B67C (v2.05)
@ In       : -
@ Out      : - (0x20007C48 = P)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x20007E18 freq_reference, 0x20007E40, 0x20007E48
@            writes 0x20007C48
@ Spec     : analysis/hy3131_modes_misc.md 5.3 step 1; ORIGINAL_FIRMWARE_ISSUES.md OF-18
@ Deviation: OF-18 (no longer called by FUN_0800B070)
@ P = 100 000 * T / ((ref / 1000) * CTB) with the 64-bit divide (ref / 1000 truncated, 49152 for the default reference).  Kept as the v2.05 routine.
@ -----------------------------------------------------------------------------
FUNC fn_0800B67C
    push {r4, r5, r6, r7, lr}          @ 0x0800B67C
    ldr r0, =v_20007E48                @ 0x0800B67E pool 0x0800B880 = 0x20007E48
    ldr r0, [r0, #0]                   @ 0x0800B680
    ldr r1, =0x000186A0                @ 0x0800B682 pool 0x0800B964 = 0x000186A0
    umull r0, r1, r1, r0               @ 0x0800B684
    movs r6, r0                        @ 0x0800B688
    movs r7, r1                        @ 0x0800B68A
    ldr r0, =v_20007E40                @ 0x0800B68C pool 0x0800C1E8 = 0x20007E40
    ldr r4, [r0, #0]                   @ 0x0800B690
    movs r5, #0                        @ 0x0800B692
    ldr r0, =freq_reference            @ 0x0800B694 pool 0x0800C1E4 = 0x20007E18
    ldr r0, [r0, #0]                   @ 0x0800B698
    asrs r1, r0, #31                   @ 0x0800B69A
    mov.w r2, #1000                    @ 0x0800B69C
    movs r3, #0                        @ 0x0800B6A0
    bl fn_08014028                     @ 0x0800B6A2
    umull r2, r3, r0, r4               @ 0x0800B6A6
    mla r3, r0, r5, r3                 @ 0x0800B6AA
    mla r3, r1, r4, r3                 @ 0x0800B6AE
    movs r0, r6                        @ 0x0800B6B2
    movs r1, r7                        @ 0x0800B6B4
    bl fn_08014028                     @ 0x0800B6B6
    movs r6, r0                        @ 0x0800B6BA
    movs r7, r1                        @ 0x0800B6BC
    ldr r0, =v_20007C48                @ 0x0800B6BE pool 0x0800B958 = 0x20007C48
    strd r6, r7, [r0]                  @ 0x0800B6C0
    pop {r4, r5, r6, r7, pc}           @ 0x0800B6C4
    .ltorg
ENDFUNC fn_0800B67C

@ -----------------------------------------------------------------------------
@ fn_0800B6D4 - duty in 0.1 %
@ Replaces : 0x0800B6D4 FUN_0800B6D4 (v2.05)
@ In       : -
@ Out      : - (0x20007E34 = CTC / (T / 1000))
@ Clobbers : r0, r1, flags
@ Context  : main only
@ RAM      : reads  0x20007E44, 0x20007E48
@            writes 0x20007E34
@ Spec     : analysis/hy3131_modes_misc.md 5.3 step 2, 5.4
@ Deviation: none
@ Unsigned 32-bit divide, truncated; T / 1000 is 0 for a gate below 1000 ticks (not reachable: the gate is at least 0x200000 ticks).
@ -----------------------------------------------------------------------------
FUNC fn_0800B6D4
    ldr r0, =v_20007E48                @ 0x0800B6D4 pool 0x0800B880 = 0x20007E48
    ldr r0, [r0, #0]                   @ 0x0800B6D6
    mov.w r1, #1000                    @ 0x0800B6D8
    udiv r0, r0, r1                    @ 0x0800B6DC
    ldr r1, =v_20007E44                @ 0x0800B6E0 pool 0x0800C1EC = 0x20007E44
    ldr r1, [r1, #0]                   @ 0x0800B6E4
    udiv r0, r1, r0                    @ 0x0800B6E6
    ldr r1, =v_20007E34                @ 0x0800B6EA pool 0x0800B95C = 0x20007E34
    str r0, [r1, #0]                   @ 0x0800B6EC
    bx lr                              @ 0x0800B6EE
    .ltorg
ENDFUNC fn_0800B6D4
