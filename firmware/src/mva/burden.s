@ =============================================================================
@ burden.s - MVA module: burden-voltage correction of the VA modes
@
@ The current measurement of a VA mode adds a burden voltage (shunt drop) to the voltage seen by the meter.
@ At the end of every voltage phase fn_08008ED0 corrects va_voltage (0x20007D7C) by D04, a double
@ interpolation in a table of 8 columns (voltage points T2 = 0, 10, 1000, 5000, 10000, 30000, 50000, 60000) by 9
@ rows (current points T1, 8 words per range row at 0x08028968) selected by mode, range and pf8_flag.
@ fn_08009364 fetches the four table words around the interpolation point.
@ Spec: analysis/hy3131_modes_ac_current.md 12 (VA.5), ORIGINAL_FIRMWARE_ISSUES.md OF-27, OF-29.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.mva, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08008ED0 (mva_burden_correct) - burden correction of va_voltage: va_voltage = va_voltage + D04(V, I, mode, range)
@ Replaces : 0x08008ED0 FUN_08008ed0 (v2.05)
@ In       : -  (reads va_voltage 0x20007D7C and va_current 0x20007D80)
@ Out      : va_voltage corrected; nothing changes in calibration mode, in modes 22 and 23, with the current in overload, or for V >= 60001
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080084E0, fn_08008B8C)
@ Registers: r4 = flag, r5 = b2, r6 = b3, r7 = b4, r8 = current row, sb = I, sl = V
@ RAM      : reads  0x20007CDC, 0x20007CE0, 0x20007CE4, 0x20007CE8, 0x20007CEC, 0x20007CF0, 0x20007CF4, 0x20007CF8,
@            0x20007CFC, 0x20007D00, 0x20007D7C va_voltage, 0x20007D80 va_current, 0x20007EB8 bt_a, 0x20007EBC bt_b,
@            0x20007EC0 bt_c, 0x20007EC4 bt_d, 0x2000803C meter_mode, 0x2000803D meter_range, 0x2000808A cal_mode,
@            0x200080CB va_i_over, 0x200080CC jack_code
@            writes 0x20007CDC, 0x20007CE0, 0x20007CE4, 0x20007CE8, 0x20007CEC, 0x20007CF0, 0x20007CF4, 0x20007CF8,
@            0x20007CFC, 0x20007D00, 0x20007D04
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.5); ORIGINAL_FIRMWARE_ISSUES.md OF-29
@ Deviation: OF-29 (mode 24: correction computed on the magnitudes and applied to the magnitude, for every range and both pf8_flag values); D00 is not computed when the current is ignored (flag set), so T1[8], the word after the threshold row, is not read (v2.05 read it and discarded the result)
@ -----------------------------------------------------------------------------
FUNC fn_08008ED0
    push {r4, r5, r6, r7, r8, sb, sl, lr} @ 08008ED0
    @ r4 = flag (current row not used), r5 = b2 (V and I have opposite signs), r8 = current row, sl = V, sb = I
    movs r4, #0                          @ 08008ED4
    movs r5, #0                          @ 08008ED6
    movs r8, #1                          @ 08008ED8
    ldr r0, =v_20007D7C                  @ 08008EDC
    ldr sl, [r0]                         @ 08008EE0  sl = va_voltage (u32)
    ldr r0, =v_20007D80                  @ 08008EE4
    ldr sb, [r0]                         @ 08008EE6  sb = va_current (u32)
    @ gate: calibration mode off, mode not 22 or 23, no current overload (va_i_over), V < 60001
    ldr r0, =v_2000808A                  @ 08008EEA
    ldrb r0, [r0]                        @ 08008EEE  r0 = cal_mode (u8)
    cmp r0, #0                           @ 08008EF0
    bne .Lmva_burden_correct_exit        @ 08008EF2  if cal_mode != 0
    ldr r0, =meter_mode                  @ 08008EF6
    ldrb r0, [r0]                        @ 08008EFA  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 08008EFC
    beq .Lmva_burden_correct_exit        @ 08008EFE  if meter_mode == 22
    ldr r0, =meter_mode                  @ 08008F02
    ldrb r0, [r0]                        @ 08008F06  r0 = meter_mode (u8)
    cmp r0, #0x17                        @ 08008F08
    beq .Lmva_burden_correct_exit        @ 08008F0A  if meter_mode == 23
    ldr r0, =v_200080CB                  @ 08008F0E
    ldrsb r0, [r0]                       @ 08008F12  r0 = va_i_over (s8)
    cmp r0, #0                           @ 08008F16
    bne .Lmva_burden_correct_exit        @ 08008F18  if va_i_over != 0
    movw r0, #0xea61                     @ 08008F1C  60001
    cmp sl, r0                           @ 08008F20
    bge .Lmva_burden_correct_exit        @ 08008F22  if va_voltage >= (signed) 60001
    @ mode 24: work on |V| and |I|; b2 = 1 when V and I have opposite signs (only the range 2 tables use b2). OF-29: v2.05 did this in range 2 only and skipped the correction for a negative V or I in the other ranges
    ldr r0, =meter_mode                  @ 08008F26
    ldrb r0, [r0]                        @ 08008F2A  r0 = meter_mode (u8)
    cmp r0, #0x18                        @ 08008F2C
    bne .Lmva_burden_correct_pos         @ 08008F2E  if meter_mode != 24
    @ ---- v2.05 0x08008F30..0x08008F38 replaced (see Deviation in the header) ----
    @ OF-29: v2.05 branched to the plain handling here unless meter_range == 2.  Mode 24 now takes the
    @ magnitude path in every range: the correction is computed on |V| and |I| and added to |V|.
    cmp sb, #0                           @ 08008F3A
    bpl .Lmva_burden_correct_b2b         @ 08008F3E  if sb >= 0
    cmp sl, #0                           @ 08008F40
    bmi .Lmva_burden_correct_b2b         @ 08008F44  if sl < 0
    movs r0, #1                          @ 08008F46
    movs r5, r0                          @ 08008F48
.Lmva_burden_correct_b2b:   @ second sign test of b2
    cmp sl, #0                           @ 08008F4A
    bpl .Lmva_burden_correct_abs         @ 08008F4E  if sl >= 0
    cmp sb, #0                           @ 08008F50
    bmi .Lmva_burden_correct_abs         @ 08008F54  if sb < 0
    movs r0, #1                          @ 08008F56
    movs r5, r0                          @ 08008F58
.Lmva_burden_correct_abs:   @ absolute values
    cmp sb, #0                           @ 08008F5A
    bpl .Lmva_burden_correct_absv        @ 08008F5E  if sb >= 0
    rsbs sb, sb, #0                      @ 08008F60  sb = -sb
.Lmva_burden_correct_absv:   @ |V|
    cmp sl, #0                           @ 08008F64
    bpl .Lmva_burden_correct_row         @ 08008F68  if sl >= 0
    rsbs sl, sl, #0                      @ 08008F6A  sl = -sl
    b .Lmva_burden_correct_row           @ 08008F6E
.Lmva_burden_correct_pos:   @ modes 13..15
    @ modes 13, 14, 15: a negative V or I gets no correction (they are non-negative in AC modes)
    cmp sb, #0                           @ 08008F70
    bmi .Lmva_burden_correct_exit        @ 08008F74  if sb < 0
    cmp sl, #0                           @ 08008F78
    bmi .Lmva_burden_correct_exit        @ 08008F7C  if sl < 0
.Lmva_burden_correct_row:   @ sign handling done
    @ current row r8 of the table at 0x08028968 (32 bytes per row): 0 for modes 13, 22 below range 2; 2 for modes 15, 24 from range 2; else 1
    ldr r0, =meter_mode                  @ 08008F80
    ldrb r0, [r0]                        @ 08008F84  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 08008F86
    beq .Lmva_burden_correct_08008F94    @ 08008F88  if meter_mode == 13
    ldr r0, =meter_mode                  @ 08008F8A
    ldrb r0, [r0]                        @ 08008F8E  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 08008F90
    bne .Lmva_burden_correct_08008FA4    @ 08008F92  if meter_mode != 22
.Lmva_burden_correct_08008F94:   @ branch target from 08008F88
    ldr r0, =meter_range                 @ 08008F94
    ldrb r0, [r0]                        @ 08008F98  r0 = meter_range (u8)
    cmp r0, #2                           @ 08008F9A
    bge .Lmva_burden_correct_08008FA4    @ 08008F9C  if meter_range >= (signed) 2
    movs r0, #0                          @ 08008F9E
    mov r8, r0                           @ 08008FA0
    b .Lmva_burden_correct_jack          @ 08008FA2
.Lmva_burden_correct_08008FA4:   @ branch target from 08008F92, 08008F9C
    ldr r0, =meter_mode                  @ 08008FA4
    ldrb r0, [r0]                        @ 08008FA8  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08008FAA
    beq .Lmva_burden_correct_08008FB8    @ 08008FAC  if meter_mode == 15
    ldr r0, =meter_mode                  @ 08008FAE
    ldrb r0, [r0]                        @ 08008FB2  r0 = meter_mode (u8)
    cmp r0, #0x18                        @ 08008FB4
    bne .Lmva_burden_correct_jack        @ 08008FB6  if meter_mode != 24
.Lmva_burden_correct_08008FB8:   @ branch target from 08008FAC
    ldr r0, =meter_range                 @ 08008FB8
    ldrb r0, [r0]                        @ 08008FBC  r0 = meter_range (u8)
    cmp r0, #2                           @ 08008FBE
    blt .Lmva_burden_correct_jack        @ 08008FC0  if meter_range < (signed) 2
    movs r0, #2                          @ 08008FC2
    mov r8, r0                           @ 08008FC4
.Lmva_burden_correct_jack:   @ row chosen
    @ flag = 1 and b3 = 8 when the jack code does not match the mode (13, 22: jack_code != 1; 15, 24: jack_code != 2); then the current is ignored
    ldr r0, =meter_mode                  @ 08008FC6
    ldrb r0, [r0]                        @ 08008FCA  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 08008FCC
    beq .Lmva_burden_correct_08008FDA    @ 08008FCE  if meter_mode == 13
    ldr r0, =meter_mode                  @ 08008FD0
    ldrb r0, [r0]                        @ 08008FD4  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 08008FD6
    bne .Lmva_burden_correct_08008FE4    @ 08008FD8  if meter_mode != 22
.Lmva_burden_correct_08008FDA:   @ branch target from 08008FCE
    ldr r0, =v_200080CC                  @ 08008FDA
    ldrb r0, [r0]                        @ 08008FDE  r0 = jack_code (u8)
    cmp r0, #1                           @ 08008FE0
    bne .Lmva_burden_correct_flagset     @ 08008FE2  if jack_code != 1
.Lmva_burden_correct_08008FE4:   @ branch target from 08008FD8
    ldr r0, =meter_mode                  @ 08008FE4
    ldrb r0, [r0]                        @ 08008FE8  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08008FEA
    beq .Lmva_burden_correct_08008FF8    @ 08008FEC  if meter_mode == 15
    ldr r0, =meter_mode                  @ 08008FEE
    ldrb r0, [r0]                        @ 08008FF2  r0 = meter_mode (u8)
    cmp r0, #0x18                        @ 08008FF4
    bne .Lmva_burden_correct_search      @ 08008FF6  if meter_mode != 24
.Lmva_burden_correct_08008FF8:   @ branch target from 08008FEC
    ldr r0, =v_200080CC                  @ 08008FF8
    ldrb r0, [r0]                        @ 08008FFC  r0 = jack_code (u8)
    cmp r0, #2                           @ 08008FFE
    beq .Lmva_burden_correct_search      @ 08009000  if jack_code == 2
.Lmva_burden_correct_flagset:   @ flag = 1, b3 = 8
    movs r0, #1                          @ 08009002
    movs r4, r0                          @ 08009004
    movs r0, #8                          @ 08009006
    movs r6, r0                          @ 08009008
    b .Lmva_burden_correct_d00           @ 0800900A
.Lmva_burden_correct_search:   @ search b3
    @ b3 = first k in 1..6 with I <= T1[k] (T1 = current thresholds of the row), else 7
    ldr r0, =v205_tab_08028968           @ 0800900C
    uxtb r8, r8                          @ 0800900E
    lsls r1, r8, #5                      @ 08009012  r1 = r8 << 5
    add r0, r1                           @ 08009016  r0 = r0 + (r8 << 5)
    ldr r0, [r0, #4]                     @ 08009018
    cmp r0, sb                           @ 0800901A
    blt .Lmva_burden_correct_08009024    @ 0800901C  if r0 < (signed) sb
    movs r0, #1                          @ 0800901E
    movs r6, r0                          @ 08009020
    b .Lmva_burden_correct_d00           @ 08009022
.Lmva_burden_correct_08009024:   @ branch target from 0800901C
    ldr r0, =v205_tab_08028968           @ 08009024
    uxtb r8, r8                          @ 08009026
    lsls r1, r8, #5                      @ 0800902A  r1 = r8 << 5
    add r0, r1                           @ 0800902E  r0 = r0 + (r8 << 5)
    ldr r0, [r0, #8]                     @ 08009030
    cmp r0, sb                           @ 08009032
    blt .Lmva_burden_correct_0800903C    @ 08009034  if r0 < (signed) sb
    movs r0, #2                          @ 08009036
    movs r6, r0                          @ 08009038
    b .Lmva_burden_correct_d00           @ 0800903A
.Lmva_burden_correct_0800903C:   @ branch target from 08009034
    ldr r0, =v205_tab_08028968           @ 0800903C
    uxtb r8, r8                          @ 0800903E
    lsls r1, r8, #5                      @ 08009042  r1 = r8 << 5
    add r0, r1                           @ 08009046  r0 = r0 + (r8 << 5)
    ldr r0, [r0, #0xc]                   @ 08009048
    cmp r0, sb                           @ 0800904A
    blt .Lmva_burden_correct_08009054    @ 0800904C  if r0 < (signed) sb
    movs r0, #3                          @ 0800904E
    movs r6, r0                          @ 08009050
    b .Lmva_burden_correct_d00           @ 08009052
.Lmva_burden_correct_08009054:   @ branch target from 0800904C
    ldr r0, =v205_tab_08028968           @ 08009054
    uxtb r8, r8                          @ 08009056
    lsls r1, r8, #5                      @ 0800905A  r1 = r8 << 5
    add r0, r1                           @ 0800905E  r0 = r0 + (r8 << 5)
    ldr r0, [r0, #0x10]                  @ 08009060
    cmp r0, sb                           @ 08009062
    blt .Lmva_burden_correct_0800906C    @ 08009064  if r0 < (signed) sb
    movs r0, #4                          @ 08009066
    movs r6, r0                          @ 08009068
    b .Lmva_burden_correct_d00           @ 0800906A
.Lmva_burden_correct_0800906C:   @ branch target from 08009064
    ldr r0, =v205_tab_08028968           @ 0800906C
    uxtb r8, r8                          @ 0800906E
    lsls r1, r8, #5                      @ 08009072  r1 = r8 << 5
    add r0, r1                           @ 08009076  r0 = r0 + (r8 << 5)
    ldr r0, [r0, #0x14]                  @ 08009078
    cmp r0, sb                           @ 0800907A
    blt .Lmva_burden_correct_08009084    @ 0800907C  if r0 < (signed) sb
    movs r0, #5                          @ 0800907E
    movs r6, r0                          @ 08009080
    b .Lmva_burden_correct_d00           @ 08009082
.Lmva_burden_correct_08009084:   @ branch target from 0800907C
    ldr r0, =v205_tab_08028968           @ 08009084
    uxtb r8, r8                          @ 08009086
    lsls r1, r8, #5                      @ 0800908A  r1 = r8 << 5
    add r0, r1                           @ 0800908E  r0 = r0 + (r8 << 5)
    ldr r0, [r0, #0x18]                  @ 08009090
    cmp r0, sb                           @ 08009092
    blt .Lmva_burden_correct_080090A0    @ 08009094  if r0 < (signed) sb
    movs r0, #6                          @ 08009096
    movs r6, r0                          @ 08009098
    b .Lmva_burden_correct_d00           @ 0800909A
.Lmva_burden_correct_080090A0:   @ branch target from 08009094
    movs r0, #7                          @ 080090A0
    movs r6, r0                          @ 080090A2
.Lmva_burden_correct_d00:   @ b3 known
    @ D00 = clamp((I - T1[b3-1]) * 100 / (T1[b3] - T1[b3-1]), -100, 100); with flag set T1[8] is the word after the row and D00 is not used
    cmp r4, #0                              @ flag set: D00 is not used (D04 = CF4); v2.05 computed it from T1[8], the word after
    bne .Lmva_burden_correct_08009124       @ the current row, which is not a threshold (spec VA.5 note), so the read is skipped
    ldr r0, =v205_tab_08028968           @ 080090A4
    uxtb r8, r8                          @ 080090A6
    lsls r1, r8, #5                      @ 080090AA  r1 = r8 << 5
    add r0, r1                           @ 080090AE  r0 = r0 + (r8 << 5)
    uxtb r6, r6                          @ 080090B0
    add r0, r0, r6, lsl #2               @ 080090B2  r0 = (r0 + (r8 << 5)) + (r6 << 2)
    ldr r0, [r0, #-0x4]                  @ 080090B6
    subs r0, sb, r0                      @ 080090BA  r0 = sb - r0
    ldr r1, =v_20007CF8                  @ 080090BE
    str r0, [r1]                         @ 080090C0  v_20007CF8 (u32) = (sb - r0)
    ldr r0, =v205_tab_08028968           @ 080090C2
    uxtb r8, r8                          @ 080090C4
    lsls r1, r8, #5                      @ 080090C8  r1 = r8 << 5
    add r0, r1                           @ 080090CC  r0 = r0 + (r8 << 5)
    uxtb r6, r6                          @ 080090CE
    ldr r0, [r0, r6, lsl #2]             @ 080090D0
    ldr r1, =v205_tab_08028968           @ 080090D4
    uxtb r8, r8                          @ 080090D6
    lsls r2, r8, #5                      @ 080090DA  r2 = r8 << 5
    add r1, r2                           @ 080090DE  r1 = r1 + (r8 << 5)
    uxtb r6, r6                          @ 080090E0
    add r1, r1, r6, lsl #2               @ 080090E2  r1 = (r1 + (r8 << 5)) + (r6 << 2)
    ldr r1, [r1, #-0x4]                  @ 080090E6
    subs r0, r0, r1                      @ 080090EA  r0 = r0 - r1
    ldr r1, =v_20007CFC                  @ 080090EC
    str r0, [r1]                         @ 080090EE  v_20007CFC (u32) = (r0 - r1)
    ldr r0, =v_20007CF8                  @ 080090F0
    ldr r0, [r0]                         @ 080090F2  r0 = v_20007CF8 (u32)
    movs r1, #0x64                       @ 080090F4  = 100
    muls r0, r1, r0                      @ 080090F6  r0 = 100 * v_20007CF8
    ldr r1, =v_20007CFC                  @ 080090F8
    ldr r1, [r1]                         @ 080090FA  r1 = v_20007CFC (u32)
    sdiv r0, r0, r1                      @ 080090FC  r0 = (100 * v_20007CF8) / v_20007CFC
    ldr r1, =v_20007D00                  @ 08009100
    str r0, [r1]                         @ 08009102  v_20007D00 (u32) = ((100 * v_20007CF8) / v_20007CFC)
    ldr r0, =v_20007D00                  @ 08009104
    ldr r0, [r0]                         @ 08009106  r0 = v_20007D00 (u32)
    cmp r0, #0x65                        @ 08009108
    blt .Lmva_burden_correct_08009112    @ 0800910A  if v_20007D00 < (signed) 101
    movs r0, #0x64                       @ 0800910C  = 100
    ldr r1, =v_20007D00                  @ 0800910E
    str r0, [r1]                         @ 08009110  v_20007D00 (u32) = 100
.Lmva_burden_correct_08009112:   @ branch target from 0800910A
    ldr r0, =v_20007D00                  @ 08009112
    ldr r0, [r0]                         @ 08009114  r0 = v_20007D00 (u32)
    cmn r0, #0x64                        @ 08009116  = 100
    bge .Lmva_burden_correct_08009124    @ 0800911A  if flags >= (signed)
    @ (clamp to +-100 continues)
    mvns r0, #0x63                       @ 0800911C
    ldr r1, =v_20007D00                  @ 08009120
    str r0, [r1]                         @ 08009122  v_20007D00 (u32) = r0
.Lmva_burden_correct_08009124:   @ branch target from 0800911A
    cmp sl, #0xb                         @ 08009124
    @ voltage column b4: 1 if V < 11 and mode != 15; 2 if V < 1001; 3 if V < 5001; 4 if V < 10001; 5 if V < 30001; 6 if V < 50001; else 7
    bge .Lmva_burden_correct_0800913A    @ 08009128  if sl >= (signed) 11
    ldr r0, =meter_mode                  @ 0800912A  11
    ldrb r0, [r0]                        @ 0800912E  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08009130
    beq .Lmva_burden_correct_0800913A    @ 08009132  if meter_mode == 15
    movs r0, #1                          @ 08009134
    movs r7, r0                          @ 08009136
    b .Lmva_burden_correct_ce4           @ 08009138
    .ltorg
.Lmva_burden_correct_0800913A:   @ branch target from 08009128, 08009132
    cmp sl, #0x3e8                       @ 0800913A
    bgt .Lmva_burden_correct_08009146    @ 0800913E  if sl > (signed) 1000
    movs r0, #2                          @ 08009140
    movs r7, r0                          @ 08009142
    b .Lmva_burden_correct_ce4           @ 08009144
.Lmva_burden_correct_08009146:   @ branch target from 0800913E
    movw r0, #0x1389                     @ 08009146  0x1389 = 5001
    cmp sl, r0                           @ 0800914A
    bge .Lmva_burden_correct_08009154    @ 0800914C  if sl >= (signed) 5001
    movs r0, #3                          @ 0800914E
    movs r7, r0                          @ 08009150
    b .Lmva_burden_correct_ce4           @ 08009152
.Lmva_burden_correct_08009154:   @ branch target from 0800914C
    movw r0, #0x2711                     @ 08009154  0x2711 = 10001
    cmp sl, r0                           @ 08009158
    bge .Lmva_burden_correct_08009162    @ 0800915A  if sl >= (signed) 10001
    movs r0, #4                          @ 0800915C
    movs r7, r0                          @ 0800915E
    b .Lmva_burden_correct_ce4           @ 08009160
.Lmva_burden_correct_08009162:   @ branch target from 0800915A
    movw r0, #0x7531                     @ 08009162  0x7531 = 30001
    cmp sl, r0                           @ 08009166
    bge .Lmva_burden_correct_08009170    @ 08009168  if sl >= (signed) 30001
    movs r0, #5                          @ 0800916A
    movs r7, r0                          @ 0800916C
    b .Lmva_burden_correct_ce4           @ 0800916E
.Lmva_burden_correct_08009170:   @ branch target from 08009168
    movw r0, #0xc351                     @ 08009170  0xC351 = 50001
    cmp sl, r0                           @ 08009174
    bge .Lmva_burden_correct_0800917E    @ 08009176  if sl >= (signed) 50001
    movs r0, #6                          @ 08009178
    movs r7, r0                          @ 0800917A
    b .Lmva_burden_correct_ce4           @ 0800917C
.Lmva_burden_correct_0800917E:   @ branch target from 08009176
    movs r0, #7                          @ 0800917E
    movs r7, r0                          @ 08009180
.Lmva_burden_correct_ce4:   @ b4 known
    @ CE4 = clamp((V - T2[b4-1]) * 100 / (T2[b4] - T2[b4-1]), -100, 100), T2 = 0x08029098
    ldr r0, =v205_tab_08029098           @ 08009182
    uxtb r7, r7                          @ 08009184
    add r0, r0, r7, lsl #2               @ 08009186  r0 = r0 + (r7 << 2)
    ldr r0, [r0, #-0x4]                  @ 0800918A
    subs r0, sl, r0                      @ 0800918E  r0 = sl - r0
    ldr r1, =v_20007CDC                  @ 08009192
    str r0, [r1]                         @ 08009194  v_20007CDC (u32) = (sl - r0)
    ldr r0, =v205_tab_08029098           @ 08009196
    uxtb r7, r7                          @ 08009198
    ldr r0, [r0, r7, lsl #2]             @ 0800919A
    ldr r1, =v205_tab_08029098           @ 0800919E
    uxtb r7, r7                          @ 080091A0
    add r1, r1, r7, lsl #2               @ 080091A2  r1 = r1 + (r7 << 2)
    ldr r1, [r1, #-0x4]                  @ 080091A6
    subs r0, r0, r1                      @ 080091AA  r0 = r0 - r1
    ldr r1, =v_20007CE0                  @ 080091AC
    str r0, [r1]                         @ 080091AE  v_20007CE0 (u32) = (r0 - r1)
    ldr r0, =v_20007CDC                  @ 080091B0
    ldr r0, [r0]                         @ 080091B2  r0 = v_20007CDC (u32)
    movs r1, #0x64                       @ 080091B4  = 100
    muls r0, r1, r0                      @ 080091B6  r0 = 100 * v_20007CDC
    ldr r1, =v_20007CE0                  @ 080091B8
    ldr r1, [r1]                         @ 080091BA  r1 = v_20007CE0 (u32)
    sdiv r0, r0, r1                      @ 080091BC  r0 = (100 * v_20007CDC) / v_20007CE0
    ldr r1, =v_20007CE4                  @ 080091C0
    str r0, [r1]                         @ 080091C2  v_20007CE4 (u32) = ((100 * v_20007CDC) / v_20007CE0)
    ldr r0, =v_20007CE4                  @ 080091C4
    ldr r0, [r0]                         @ 080091C6  r0 = v_20007CE4 (u32)
    cmp r0, #0x65                        @ 080091C8
    blt .Lmva_burden_correct_080091D2    @ 080091CA  if v_20007CE4 < (signed) 101
    movs r0, #0x64                       @ 080091CC  = 100
    ldr r1, =v_20007CE4                  @ 080091CE
    str r0, [r1]                         @ 080091D0  v_20007CE4 (u32) = 100
.Lmva_burden_correct_080091D2:   @ branch target from 080091CA
    ldr r0, =v_20007CE4                  @ 080091D2
    ldr r0, [r0]                         @ 080091D4  r0 = v_20007CE4 (u32)
    cmn r0, #0x64                        @ 080091D6  = 100
    bge .Lmva_burden_correct_080091E4    @ 080091DA  if flags >= (signed)
    mvns r0, #0x63                       @ 080091DC
    ldr r1, =v_20007CE4                  @ 080091E0
    str r0, [r1]                         @ 080091E2  v_20007CE4 (u32) = r0
.Lmva_burden_correct_080091E4:   @ branch target from 080091DA
    @ fn_08009364(b3, b4, b2) loads EB8, EBC (row b3-1) and EC0, EC4 (row b3) at columns b4-1 and b4
    movs r2, r5                          @ 080091E4
    uxtb r2, r2                          @ 080091E6
    movs r1, r7                          @ 080091E8
    uxtb r1, r1                          @ 080091EA
    movs r0, r6                          @ 080091EC
    uxtb r0, r0                          @ 080091EE
    bl fn_08009364                       @ 080091F0  MVA: burden table fetch into 0x20007EB8..0x20007EC4
    @ CF0 = EB8 + CE4 * (EBC - EB8) / 100, CF4 = EC0 + CE4 * (EC4 - EC0) / 100
    ldr r0, =v_20007EBC                  @ 080091F4
    ldr r0, [r0]                         @ 080091F8  r0 = bt_b (u32)
    ldr r1, =v_20007EB8                  @ 080091FA
    ldr r1, [r1]                         @ 080091FE  r1 = bt_a (u32)
    subs r0, r0, r1                      @ 08009200  r0 = bt_b - bt_a
    ldr r1, =v_20007CE8                  @ 08009202
    str r0, [r1]                         @ 08009204  v_20007CE8 (u32) = (bt_b - bt_a)
    ldr r0, =v_20007EB8                  @ 08009206
    ldr r0, [r0]                         @ 0800920A  r0 = bt_a (u32)
    ldr r1, =v_20007CE8                  @ 0800920C
    ldr r1, [r1]                         @ 0800920E  r1 = v_20007CE8 (u32)
    ldr r2, =v_20007CE4                  @ 08009210
    ldr r2, [r2]                         @ 08009212  r2 = v_20007CE4 (u32)
    muls r1, r2, r1                      @ 08009214  r1 = v_20007CE4 * v_20007CE8
    movs r2, #0x64                       @ 08009216  = 100
    sdiv r1, r1, r2                      @ 08009218  r1 = (v_20007CE4 * v_20007CE8) / 100
    adds r0, r1, r0                      @ 0800921C  r0 = ((v_20007CE4 * v_20007CE8) / 100) + bt_a
    ldr r1, =v_20007CF0                  @ 0800921E
    str r0, [r1]                         @ 08009220  v_20007CF0 (u32) = (((v_20007CE4 * v_20007CE8) / 100) + bt_a)
    ldr r0, =v_20007EC4                  @ 08009222
    ldr r0, [r0]                         @ 08009226  r0 = bt_d (u32)
    ldr r1, =v_20007EC0                  @ 08009228
    ldr r1, [r1]                         @ 0800922C  r1 = bt_c (u32)
    subs r0, r0, r1                      @ 0800922E  r0 = bt_d - bt_c
    ldr r1, =v_20007CEC                  @ 08009230
    str r0, [r1]                         @ 08009232  v_20007CEC (u32) = (bt_d - bt_c)
    ldr r0, =v_20007EC0                  @ 08009234
    ldr r0, [r0]                         @ 08009238  r0 = bt_c (u32)
    ldr r1, =v_20007CEC                  @ 0800923A
    ldr r1, [r1]                         @ 0800923C  r1 = v_20007CEC (u32)
    ldr r2, =v_20007CE4                  @ 0800923E
    ldr r2, [r2]                         @ 08009240  r2 = v_20007CE4 (u32)
    muls r1, r2, r1                      @ 08009242  r1 = v_20007CE4 * v_20007CEC
    movs r2, #0x64                       @ 08009244  = 100
    sdiv r1, r1, r2                      @ 08009246  r1 = (v_20007CE4 * v_20007CEC) / 100
    adds r0, r1, r0                      @ 0800924A  r0 = ((v_20007CE4 * v_20007CEC) / 100) + bt_c
    ldr r1, =v_20007CF4                  @ 0800924C
    str r0, [r1]                         @ 0800924E  v_20007CF4 (u32) = (((v_20007CE4 * v_20007CEC) / 100) + bt_c)
    @ D04 = CF4 with flag set, else CF0 + D00 * (CF4 - CF0) / 100
    uxtb r4, r4                          @ 08009250
    cmp r4, #0                           @ 08009252
    beq .Lmva_burden_correct_08009260    @ 08009254  if r4 == 0
    ldr r0, =v_20007CF4                  @ 08009256
    ldr r0, [r0]                         @ 08009258  r0 = v_20007CF4 (u32)
    ldr r1, =v_20007D04                  @ 0800925A
    str r0, [r1]                         @ 0800925C  v_20007D04 (u32) = v_20007CF4
    b .Lmva_burden_correct_apply         @ 0800925E
.Lmva_burden_correct_08009260:   @ branch target from 08009254
    ldr r0, =v_20007CF0                  @ 08009260
    ldr r0, [r0]                         @ 08009262  r0 = v_20007CF0 (u32)
    ldr r1, =v_20007CF4                  @ 08009264
    ldr r1, [r1]                         @ 08009266  r1 = v_20007CF4 (u32)
    ldr r2, =v_20007CF0                  @ 08009268
    ldr r2, [r2]                         @ 0800926A  r2 = v_20007CF0 (u32)
    subs r1, r1, r2                      @ 0800926C  r1 = v_20007CF4 - v_20007CF0
    ldr r2, =v_20007D00                  @ 0800926E
    ldr r2, [r2]                         @ 08009270  r2 = v_20007D00 (u32)
    muls r1, r2, r1                      @ 08009272  r1 = v_20007D00 * (v_20007CF4 - v_20007CF0)
    movs r2, #0x64                       @ 08009274  = 100
    sdiv r1, r1, r2                      @ 08009276  r1 = (v_20007D00 * (v_20007CF4 - v_20007CF0)) / 100
    adds r0, r1, r0                      @ 0800927A
    ldr r1, =v_20007D04                  @ 0800927C
    str r0, [r1]                         @ 0800927E  v_20007D04 (u32) = r0
.Lmva_burden_correct_apply:   @ D04 known
    @ apply D04
    @ ---- v2.05 0x08009280..0x080092CE replaced (see Deviation in the header) ----
    ldr r0, =meter_mode                     @ OF-29: the correction lengthens the magnitude of V
    ldrb r0, [r0]
    cmp r0, #24
    bne 1f                                  @ modes 13, 14, 15: V >= 0, V = V + D04
    ldr r0, =v_20007D7C
    ldr r0, [r0]
    cmp r0, #0
    bpl 1f                                  @ mode 24, V >= 0: V = V + D04
    ldr r1, =v_20007D04
    ldr r1, [r1]
    subs r0, r0, r1                         @ mode 24, V < 0: V = V - D04
    ldr r1, =v_20007D7C
    str r0, [r1]
    b .Lmva_burden_correct_exit
1:  ldr r0, =v_20007D7C
    ldr r0, [r0]
    ldr r1, =v_20007D04
    ldr r1, [r1]
    adds r0, r1, r0
    ldr r1, =v_20007D7C
    str r0, [r1]
.Lmva_burden_correct_exit:   @ return
    pop {r4, r5, r6, r7, r8, sb, sl, pc} @ 080092D0
    .ltorg
ENDFUNC fn_08008ED0
    .global mva_burden_correct
    .set mva_burden_correct, fn_08008ED0

@ -----------------------------------------------------------------------------
@ fn_08009364 (mva_burden_fetch) - fetch the four burden table words around the interpolation point into 0x20007EB8..0x20007EC4
@ Replaces : 0x08009364 FUN_08009364 (v2.05)
@ In       : r0 = b3 (row index 1..8)
@            r1 = b4 (column index 1..7)
@            r2 = b2 (1 when V and I have opposite signs; used by mode 24 range 2 with pf8_flag = 1)
@ Out      : bt_a (0x20007EB8) = T[b3-1][b4-1], bt_b (0x20007EBC) = T[b3-1][b4], bt_c (0x20007EC0) = T[b3][b4-1], bt_d (0x20007EC4) = T[b3][b4];
@            zeros for modes 22 and 23
@ Clobbers : r0, r1, r3, flags (r2 is preserved, r4 is saved)
@ Context  : main only (fn_08008ED0)
@ Registers: r0 = b3, r1 = b4, r2 = b2 (preserved), r3 and r4 scratch (r4 saved)
@ RAM      : reads  meter_mode, meter_range, pf8_flag (0x20007FDF); writes 0x20007EB8..0x20007EC4
@            Tables (v2.05 0x080260E4..0x080284C0, 33 tables of 9 rows): modes 13, 14, 15, 24 by range and pf8_flag; row stride 32 bytes (8 columns), except mode 15 ranges 2 and 3 with pf8_flag = 0 (0x080283C4, 0x080284C0): 28 bytes (7 columns)
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.5 table B); ORIGINAL_FIRMWARE_ISSUES.md OF-27
@ Deviation: OF-27 (row index clamped to the last row 8; column index of the tables with 7 columns clamped to 6)
@ -----------------------------------------------------------------------------
FUNC fn_08009364
    push {r4}                            @ 08009364
    uxtb r0, r0                             @ OF-27: b3 above the last row (8) is clamped; v2.05 callers pass 1..8
    cmp r0, #8
    it hi                                   @ one conditional instruction
    movhi r0, #8                            @ b3 > 8: last row
    uxtb r1, r1                             @ b4 above the last column (7) is clamped likewise
    cmp r1, #7
    it hi                                   @ one conditional instruction
    movhi r1, #7                            @ b4 > 7: last column
    @ dispatch on mode: 13, 14, 15, 24 have tables; 22, 23 get zeros (not reached, 8ED0 returns for them)
    ldr r3, =meter_mode                  @ 08009366
    ldrb r3, [r3]                        @ 0800936A  r3 = meter_mode (u8)
    cmp r3, #0xd                         @ 0800936C
    beq .Lmva_burden_fetch_08009796      @ 0800936E  if meter_mode == 13
    cmp r3, #0xe                         @ 08009372
    beq .Lmva_burden_fetch_08009B08      @ 08009374  if meter_mode == 14
    cmp r3, #0xf                         @ 08009378
    beq .Lmva_burden_fetch_08009E3A      @ 0800937A  if meter_mode == 15
    cmp r3, #0x16                        @ 0800937E
    beq .Lmva_burden_fetch_0800938E      @ 08009380  if meter_mode == 22
    cmp r3, #0x17                        @ 08009382
    beq .Lmva_burden_fetch_0800938E      @ 08009384  if meter_mode == 23
    cmp r3, #0x18                        @ 08009386
    beq .Lmva_burden_fetch_080093B2      @ 08009388  if meter_mode == 24
    b .Lmva_burden_fetch_0800A1D2        @ 0800938A
.Lmva_burden_fetch_0800938E:   @ branch target from 08009380, 08009384
    @ modes 22, 23: four zeros
    movs r3, #0                          @ 0800938E
    ldr r4, =v_20007EB8                  @ 08009390
    str r3, [r4]                         @ 08009394  bt_a (u32) = 0
    movs r3, #0                          @ 08009396
    ldr r4, =v_20007EBC                  @ 08009398
    str r3, [r4]                         @ 0800939C  bt_b (u32) = 0
    movs r3, #0                          @ 0800939E
    ldr r4, =v_20007EC0                  @ 080093A0
    str r3, [r4]                         @ 080093A4  bt_c (u32) = 0
    movs r3, #0                          @ 080093A6
    ldr r4, =v_20007EC4                  @ 080093A8
    str r3, [r4]                         @ 080093AC  bt_d (u32) = 0
    b .Lmva_burden_fetch_0800A1D2        @ 080093AE
.Lmva_burden_fetch_080093B2:   @ branch target from 08009388
    ldr r3, =meter_range                 @ 080093B2
    ldrb r3, [r3]                        @ 080093B6  r3 = meter_range (u8)
    cmp r3, #0                           @ 080093B8
    beq .Lmva_burden_fetch_080093CC      @ 080093BA  if meter_range == 0
    cmp r3, #2                           @ 080093BC
    beq .Lmva_burden_fetch_08009578      @ 080093BE  if meter_range == 2
    blo .Lmva_burden_fetch_080094A2      @ 080093C2  if meter_range < (unsigned) 2
    cmp r3, #3                           @ 080093C4
    beq .Lmva_burden_fetch_080096BE      @ 080093C6  if meter_range == 3
    b .Lmva_burden_fetch_08009792        @ 080093CA
.Lmva_burden_fetch_080093CC:   @ branch target from 080093BA
    ldr r3, =v_20007FDF                  @ 080093CC
    ldrb r3, [r3]                        @ 080093D0  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 080093D2
    beq .Lmva_burden_fetch_0800943C      @ 080093D4  if pf8_flag == 0
    ldr r3, =v205_tab_08027AC4           @ 080093D6
    uxtb r0, r0                          @ 080093DA
    lsls r4, r0, #5                      @ 080093DC  r4 = r0 << 5
    add r3, r4                           @ 080093DE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080093E0
    add r3, r3, r1, lsl #2               @ 080093E2  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 080093E6
    ldr r4, =v_20007EB8                  @ 080093EA
    str r3, [r4]                         @ 080093EE  bt_a (u32) = r3
    ldr r3, =v205_tab_08027AC4           @ 080093F0
    uxtb r0, r0                          @ 080093F4
    lsls r4, r0, #5                      @ 080093F6  r4 = r0 << 5
    add r3, r4                           @ 080093F8  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080093FA
    add r3, r3, r1, lsl #2               @ 080093FC  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009400
    ldr r4, =v_20007EBC                  @ 08009404
    str r3, [r4]                         @ 08009408  bt_b (u32) = r3
    ldr r3, =v205_tab_08027AC4           @ 0800940A
    uxtb r0, r0                          @ 0800940E
    lsls r4, r0, #5                      @ 08009410  r4 = r0 << 5
    add r3, r4                           @ 08009412  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009414
    add r3, r3, r1, lsl #2               @ 08009416  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 0800941A
    ldr r4, =v_20007EC0                  @ 0800941E
    str r3, [r4]                         @ 08009422  bt_c (u32) = r3
    ldr r3, =v205_tab_08027AC4           @ 08009424
    uxtb r0, r0                          @ 08009428
    lsls r4, r0, #5                      @ 0800942A  r4 = r0 << 5
    add r3, r4                           @ 0800942C  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800942E
    ldr r3, [r3, r1, lsl #2]             @ 08009430
    ldr r4, =v_20007EC4                  @ 08009434
    str r3, [r4]                         @ 08009438  bt_d (u32) = r3
    b .Lmva_burden_fetch_080094A0        @ 0800943A
.Lmva_burden_fetch_0800943C:   @ branch target from 080093D4
    ldr r3, =v205_tab_080279A4           @ 0800943C
    uxtb r0, r0                          @ 08009440
    lsls r4, r0, #5                      @ 08009442  r4 = r0 << 5
    add r3, r4                           @ 08009444  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009446
    add r3, r3, r1, lsl #2               @ 08009448  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 0800944C
    ldr r4, =v_20007EB8                  @ 08009450
    str r3, [r4]                         @ 08009454  bt_a (u32) = r3
    ldr r3, =v205_tab_080279A4           @ 08009456
    uxtb r0, r0                          @ 0800945A
    lsls r4, r0, #5                      @ 0800945C  r4 = r0 << 5
    add r3, r4                           @ 0800945E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009460
    add r3, r3, r1, lsl #2               @ 08009462  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009466
    ldr r4, =v_20007EBC                  @ 0800946A
    str r3, [r4]                         @ 0800946E  bt_b (u32) = r3
    ldr r3, =v205_tab_080279A4           @ 08009470
    uxtb r0, r0                          @ 08009474
    lsls r4, r0, #5                      @ 08009476  r4 = r0 << 5
    add r3, r4                           @ 08009478  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800947A
    add r3, r3, r1, lsl #2               @ 0800947C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009480
    ldr r4, =v_20007EC0                  @ 08009484
    str r3, [r4]                         @ 08009488  bt_c (u32) = r3
    ldr r3, =v205_tab_080279A4           @ 0800948A
    uxtb r0, r0                          @ 0800948E
    lsls r4, r0, #5                      @ 08009490  r4 = r0 << 5
    add r3, r4                           @ 08009492  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009494
    ldr r3, [r3, r1, lsl #2]             @ 08009496
    ldr r4, =v_20007EC4                  @ 0800949A
    str r3, [r4]                         @ 0800949E  bt_d (u32) = r3
.Lmva_burden_fetch_080094A0:   @ branch target from 0800943A
    b .Lmva_burden_fetch_08009792        @ 080094A0
.Lmva_burden_fetch_080094A2:   @ branch target from 080093C2
    ldr r3, =v_20007FDF                  @ 080094A2
    ldrb r3, [r3]                        @ 080094A6  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 080094A8
    beq .Lmva_burden_fetch_08009512      @ 080094AA  if pf8_flag == 0
    ldr r3, =v205_tab_08027D04           @ 080094AC
    uxtb r0, r0                          @ 080094B0
    lsls r4, r0, #5                      @ 080094B2  r4 = r0 << 5
    add r3, r4                           @ 080094B4  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080094B6
    add r3, r3, r1, lsl #2               @ 080094B8  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 080094BC
    ldr r4, =v_20007EB8                  @ 080094C0
    str r3, [r4]                         @ 080094C4  bt_a (u32) = r3
    ldr r3, =v205_tab_08027D04           @ 080094C6
    uxtb r0, r0                          @ 080094CA
    lsls r4, r0, #5                      @ 080094CC  r4 = r0 << 5
    add r3, r4                           @ 080094CE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080094D0
    add r3, r3, r1, lsl #2               @ 080094D2  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 080094D6
    ldr r4, =v_20007EBC                  @ 080094DA
    str r3, [r4]                         @ 080094DE  bt_b (u32) = r3
    ldr r3, =v205_tab_08027D04           @ 080094E0
    uxtb r0, r0                          @ 080094E4
    lsls r4, r0, #5                      @ 080094E6  r4 = r0 << 5
    add r3, r4                           @ 080094E8  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080094EA
    add r3, r3, r1, lsl #2               @ 080094EC  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 080094F0
    ldr r4, =v_20007EC0                  @ 080094F4
    str r3, [r4]                         @ 080094F8  bt_c (u32) = r3
    ldr r3, =v205_tab_08027D04           @ 080094FA
    uxtb r0, r0                          @ 080094FE
    lsls r4, r0, #5                      @ 08009500  r4 = r0 << 5
    add r3, r4                           @ 08009502  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009504
    ldr r3, [r3, r1, lsl #2]             @ 08009506
    ldr r4, =v_20007EC4                  @ 0800950A
    str r3, [r4]                         @ 0800950E  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009576        @ 08009510
.Lmva_burden_fetch_08009512:   @ branch target from 080094AA
    ldr r3, =v205_tab_08027BE4           @ 08009512
    uxtb r0, r0                          @ 08009516
    lsls r4, r0, #5                      @ 08009518  r4 = r0 << 5
    add r3, r4                           @ 0800951A  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800951C
    add r3, r3, r1, lsl #2               @ 0800951E  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009522
    ldr r4, =v_20007EB8                  @ 08009526
    str r3, [r4]                         @ 0800952A  bt_a (u32) = r3
    ldr r3, =v205_tab_08027BE4           @ 0800952C
    uxtb r0, r0                          @ 08009530
    lsls r4, r0, #5                      @ 08009532  r4 = r0 << 5
    add r3, r4                           @ 08009534  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009536
    add r3, r3, r1, lsl #2               @ 08009538  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 0800953C
    ldr r4, =v_20007EBC                  @ 08009540
    str r3, [r4]                         @ 08009544  bt_b (u32) = r3
    ldr r3, =v205_tab_08027BE4           @ 08009546
    uxtb r0, r0                          @ 0800954A
    lsls r4, r0, #5                      @ 0800954C  r4 = r0 << 5
    add r3, r4                           @ 0800954E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009550
    add r3, r3, r1, lsl #2               @ 08009552  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009556
    ldr r4, =v_20007EC0                  @ 0800955A
    str r3, [r4]                         @ 0800955E  bt_c (u32) = r3
    ldr r3, =v205_tab_08027BE4           @ 08009560
    uxtb r0, r0                          @ 08009564
    lsls r4, r0, #5                      @ 08009566  r4 = r0 << 5
    add r3, r4                           @ 08009568  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800956A
    ldr r3, [r3, r1, lsl #2]             @ 0800956C
    ldr r4, =v_20007EC4                  @ 08009570
    str r3, [r4]                         @ 08009574  bt_d (u32) = r3
.Lmva_burden_fetch_08009576:   @ branch target from 08009510
    b .Lmva_burden_fetch_08009792        @ 08009576
.Lmva_burden_fetch_08009578:   @ branch target from 080093BE
    ldr r3, =v_20007FDF                  @ 08009578
    ldrb r3, [r3]                        @ 0800957C  r3 = pf8_flag (u8)
    tst r3, r2                           @ 0800957E
    beq .Lmva_burden_fetch_080095E8      @ 08009580  if (pf8_flag & r2) == 0
    ldr r3, =v205_tab_08028064           @ 08009582
    uxtb r0, r0                          @ 08009586
    lsls r4, r0, #5                      @ 08009588  r4 = r0 << 5
    add r3, r4                           @ 0800958A  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800958C
    add r3, r3, r1, lsl #2               @ 0800958E  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009592
    ldr r4, =v_20007EB8                  @ 08009596
    str r3, [r4]                         @ 0800959A  bt_a (u32) = r3
    ldr r3, =v205_tab_08028064           @ 0800959C
    uxtb r0, r0                          @ 080095A0
    lsls r4, r0, #5                      @ 080095A2  r4 = r0 << 5
    add r3, r4                           @ 080095A4  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080095A6
    add r3, r3, r1, lsl #2               @ 080095A8  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 080095AC
    ldr r4, =v_20007EBC                  @ 080095B0
    str r3, [r4]                         @ 080095B4  bt_b (u32) = r3
    ldr r3, =v205_tab_08028064           @ 080095B6
    uxtb r0, r0                          @ 080095BA
    lsls r4, r0, #5                      @ 080095BC  r4 = r0 << 5
    add r3, r4                           @ 080095BE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080095C0
    add r3, r3, r1, lsl #2               @ 080095C2  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 080095C6
    ldr r4, =v_20007EC0                  @ 080095CA
    str r3, [r4]                         @ 080095CE  bt_c (u32) = r3
    ldr r3, =v205_tab_08028064           @ 080095D0
    uxtb r0, r0                          @ 080095D4
    lsls r4, r0, #5                      @ 080095D6  r4 = r0 << 5
    add r3, r4                           @ 080095D8  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080095DA
    ldr r3, [r3, r1, lsl #2]             @ 080095DC
    ldr r4, =v_20007EC4                  @ 080095E0
    str r3, [r4]                         @ 080095E4  bt_d (u32) = r3
    b .Lmva_burden_fetch_080096BC        @ 080095E6
    .ltorg
.Lmva_burden_fetch_080095E8:   @ branch target from 08009580
    ldr r3, =v_20007FDF                  @ 080095E8
    ldrb r3, [r3]                        @ 080095EC  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 080095EE
    beq .Lmva_burden_fetch_08009658      @ 080095F0  if pf8_flag == 0
    ldr r3, =v205_tab_08027F44           @ 080095F2
    uxtb r0, r0                          @ 080095F6
    lsls r4, r0, #5                      @ 080095F8  r4 = r0 << 5
    add r3, r4                           @ 080095FA  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080095FC
    add r3, r3, r1, lsl #2               @ 080095FE  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009602
    ldr r4, =v_20007EB8                  @ 08009606
    str r3, [r4]                         @ 0800960A  bt_a (u32) = r3
    ldr r3, =v205_tab_08027F44           @ 0800960C
    uxtb r0, r0                          @ 08009610
    lsls r4, r0, #5                      @ 08009612  r4 = r0 << 5
    add r3, r4                           @ 08009614  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009616
    add r3, r3, r1, lsl #2               @ 08009618  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 0800961C
    ldr r4, =v_20007EBC                  @ 08009620
    str r3, [r4]                         @ 08009624  bt_b (u32) = r3
    ldr r3, =v205_tab_08027F44           @ 08009626
    uxtb r0, r0                          @ 0800962A
    lsls r4, r0, #5                      @ 0800962C  r4 = r0 << 5
    add r3, r4                           @ 0800962E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009630
    add r3, r3, r1, lsl #2               @ 08009632  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009636
    ldr r4, =v_20007EC0                  @ 0800963A
    str r3, [r4]                         @ 0800963E  bt_c (u32) = r3
    ldr r3, =v205_tab_08027F44           @ 08009640
    uxtb r0, r0                          @ 08009644
    lsls r4, r0, #5                      @ 08009646  r4 = r0 << 5
    add r3, r4                           @ 08009648  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800964A
    ldr r3, [r3, r1, lsl #2]             @ 0800964C
    ldr r4, =v_20007EC4                  @ 08009650
    str r3, [r4]                         @ 08009654  bt_d (u32) = r3
    b .Lmva_burden_fetch_080096BC        @ 08009656
.Lmva_burden_fetch_08009658:   @ branch target from 080095F0
    ldr r3, =v205_tab_08027E24           @ 08009658
    uxtb r0, r0                          @ 0800965C
    lsls r4, r0, #5                      @ 0800965E  r4 = r0 << 5
    add r3, r4                           @ 08009660  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009662
    add r3, r3, r1, lsl #2               @ 08009664  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009668
    ldr r4, =v_20007EB8                  @ 0800966C
    str r3, [r4]                         @ 08009670  bt_a (u32) = r3
    ldr r3, =v205_tab_08027E24           @ 08009672
    uxtb r0, r0                          @ 08009676
    lsls r4, r0, #5                      @ 08009678  r4 = r0 << 5
    add r3, r4                           @ 0800967A  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800967C
    add r3, r3, r1, lsl #2               @ 0800967E  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009682
    ldr r4, =v_20007EBC                  @ 08009686
    str r3, [r4]                         @ 0800968A  bt_b (u32) = r3
    ldr r3, =v205_tab_08027E24           @ 0800968C
    uxtb r0, r0                          @ 08009690
    lsls r4, r0, #5                      @ 08009692  r4 = r0 << 5
    add r3, r4                           @ 08009694  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009696
    add r3, r3, r1, lsl #2               @ 08009698  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 0800969C
    ldr r4, =v_20007EC0                  @ 080096A0
    str r3, [r4]                         @ 080096A4  bt_c (u32) = r3
    ldr r3, =v205_tab_08027E24           @ 080096A6
    uxtb r0, r0                          @ 080096AA
    lsls r4, r0, #5                      @ 080096AC  r4 = r0 << 5
    add r3, r4                           @ 080096AE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080096B0
    ldr r3, [r3, r1, lsl #2]             @ 080096B2
    ldr r4, =v_20007EC4                  @ 080096B6
    str r3, [r4]                         @ 080096BA  bt_d (u32) = r3
.Lmva_burden_fetch_080096BC:   @ branch target from 080095E6, 08009656
    b .Lmva_burden_fetch_08009792        @ 080096BC
.Lmva_burden_fetch_080096BE:   @ branch target from 080093C6
    ldr r3, =v_20007FDF                  @ 080096BE
    ldrb r3, [r3]                        @ 080096C2  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 080096C4
    beq .Lmva_burden_fetch_0800972E      @ 080096C6  if pf8_flag == 0
    ldr r3, =v205_tab_080282A4           @ 080096C8
    uxtb r0, r0                          @ 080096CC
    lsls r4, r0, #5                      @ 080096CE  r4 = r0 << 5
    add r3, r4                           @ 080096D0  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080096D2
    add r3, r3, r1, lsl #2               @ 080096D4  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 080096D8
    ldr r4, =v_20007EB8                  @ 080096DC
    str r3, [r4]                         @ 080096E0  bt_a (u32) = r3
    ldr r3, =v205_tab_080282A4           @ 080096E2
    uxtb r0, r0                          @ 080096E6
    lsls r4, r0, #5                      @ 080096E8  r4 = r0 << 5
    add r3, r4                           @ 080096EA  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080096EC
    add r3, r3, r1, lsl #2               @ 080096EE  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 080096F2
    ldr r4, =v_20007EBC                  @ 080096F6
    str r3, [r4]                         @ 080096FA  bt_b (u32) = r3
    ldr r3, =v205_tab_080282A4           @ 080096FC
    uxtb r0, r0                          @ 08009700
    lsls r4, r0, #5                      @ 08009702  r4 = r0 << 5
    add r3, r4                           @ 08009704  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009706
    add r3, r3, r1, lsl #2               @ 08009708  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 0800970C
    ldr r4, =v_20007EC0                  @ 08009710
    str r3, [r4]                         @ 08009714  bt_c (u32) = r3
    ldr r3, =v205_tab_080282A4           @ 08009716
    uxtb r0, r0                          @ 0800971A
    lsls r4, r0, #5                      @ 0800971C  r4 = r0 << 5
    add r3, r4                           @ 0800971E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009720
    ldr r3, [r3, r1, lsl #2]             @ 08009722
    ldr r4, =v_20007EC4                  @ 08009726
    str r3, [r4]                         @ 0800972A  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009792        @ 0800972C
.Lmva_burden_fetch_0800972E:   @ branch target from 080096C6
    ldr r3, =v205_tab_08028184           @ 0800972E
    uxtb r0, r0                          @ 08009732
    lsls r4, r0, #5                      @ 08009734  r4 = r0 << 5
    add r3, r4                           @ 08009736  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009738
    add r3, r3, r1, lsl #2               @ 0800973A  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 0800973E
    ldr r4, =v_20007EB8                  @ 08009742
    str r3, [r4]                         @ 08009746  bt_a (u32) = r3
    ldr r3, =v205_tab_08028184           @ 08009748
    uxtb r0, r0                          @ 0800974C
    lsls r4, r0, #5                      @ 0800974E  r4 = r0 << 5
    add r3, r4                           @ 08009750  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009752
    add r3, r3, r1, lsl #2               @ 08009754  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009758
    ldr r4, =v_20007EBC                  @ 0800975C
    str r3, [r4]                         @ 08009760  bt_b (u32) = r3
    ldr r3, =v205_tab_08028184           @ 08009762
    uxtb r0, r0                          @ 08009766
    lsls r4, r0, #5                      @ 08009768  r4 = r0 << 5
    add r3, r4                           @ 0800976A  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800976C
    add r3, r3, r1, lsl #2               @ 0800976E  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009772
    ldr r4, =v_20007EC0                  @ 08009776
    str r3, [r4]                         @ 0800977A  bt_c (u32) = r3
    ldr r3, =v205_tab_08028184           @ 0800977C
    uxtb r0, r0                          @ 08009780
    lsls r4, r0, #5                      @ 08009782  r4 = r0 << 5
    add r3, r4                           @ 08009784  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009786
    ldr r3, [r3, r1, lsl #2]             @ 08009788
    ldr r4, =v_20007EC4                  @ 0800978C
    str r3, [r4]                         @ 08009790  bt_d (u32) = r3
.Lmva_burden_fetch_08009792:   @ branch target from 080093CA, 080094A0, 08009576, 080096BC, 0800972C
    b .Lmva_burden_fetch_0800A1D2        @ 08009792
.Lmva_burden_fetch_08009796:   @ branch target from 0800936E
    ldr r3, =meter_range                 @ 08009796
    ldrb r3, [r3]                        @ 0800979A  r3 = meter_range (u8)
    cmp r3, #0                           @ 0800979C
    beq .Lmva_burden_fetch_080097B0      @ 0800979E  if meter_range == 0
    cmp r3, #2                           @ 080097A0
    beq .Lmva_burden_fetch_0800995C      @ 080097A2  if meter_range == 2
    blo .Lmva_burden_fetch_08009886      @ 080097A6  if meter_range < (unsigned) 2
    cmp r3, #3                           @ 080097A8
    beq .Lmva_burden_fetch_08009A32      @ 080097AA  if meter_range == 3
    b .Lmva_burden_fetch_08009B02        @ 080097AE
.Lmva_burden_fetch_080097B0:   @ branch target from 0800979E
    ldr r3, =v_20007FDF                  @ 080097B0
    ldrb r3, [r3]                        @ 080097B4  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 080097B6
    beq .Lmva_burden_fetch_08009820      @ 080097B8  if pf8_flag == 0
    ldr r3, =v205_tab_08026204           @ 080097BA
    uxtb r0, r0                          @ 080097BE
    lsls r4, r0, #5                      @ 080097C0  r4 = r0 << 5
    add r3, r4                           @ 080097C2  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080097C4
    add r3, r3, r1, lsl #2               @ 080097C6  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 080097CA
    ldr r4, =v_20007EB8                  @ 080097CE
    str r3, [r4]                         @ 080097D2  bt_a (u32) = r3
    ldr r3, =v205_tab_08026204           @ 080097D4
    uxtb r0, r0                          @ 080097D8
    lsls r4, r0, #5                      @ 080097DA  r4 = r0 << 5
    add r3, r4                           @ 080097DC  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080097DE
    add r3, r3, r1, lsl #2               @ 080097E0  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 080097E4
    ldr r4, =v_20007EBC                  @ 080097E8
    str r3, [r4]                         @ 080097EC  bt_b (u32) = r3
    ldr r3, =v205_tab_08026204           @ 080097EE
    uxtb r0, r0                          @ 080097F2
    lsls r4, r0, #5                      @ 080097F4  r4 = r0 << 5
    add r3, r4                           @ 080097F6  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080097F8
    add r3, r3, r1, lsl #2               @ 080097FA  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 080097FE
    ldr r4, =v_20007EC0                  @ 08009802
    str r3, [r4]                         @ 08009806  bt_c (u32) = r3
    ldr r3, =v205_tab_08026204           @ 08009808
    uxtb r0, r0                          @ 0800980C
    lsls r4, r0, #5                      @ 0800980E  r4 = r0 << 5
    add r3, r4                           @ 08009810  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009812
    ldr r3, [r3, r1, lsl #2]             @ 08009814
    ldr r4, =v_20007EC4                  @ 08009818
    str r3, [r4]                         @ 0800981C  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009884        @ 0800981E
.Lmva_burden_fetch_08009820:   @ branch target from 080097B8
    ldr r3, =v205_tab_080260E4           @ 08009820
    uxtb r0, r0                          @ 08009824
    lsls r4, r0, #5                      @ 08009826  r4 = r0 << 5
    add r3, r4                           @ 08009828  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800982A
    add r3, r3, r1, lsl #2               @ 0800982C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009830
    ldr r4, =v_20007EB8                  @ 08009834
    str r3, [r4]                         @ 08009838  bt_a (u32) = r3
    ldr r3, =v205_tab_080260E4           @ 0800983A
    uxtb r0, r0                          @ 0800983E
    lsls r4, r0, #5                      @ 08009840  r4 = r0 << 5
    add r3, r4                           @ 08009842  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009844
    add r3, r3, r1, lsl #2               @ 08009846  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 0800984A
    ldr r4, =v_20007EBC                  @ 0800984E
    str r3, [r4]                         @ 08009852  bt_b (u32) = r3
    ldr r3, =v205_tab_080260E4           @ 08009854
    uxtb r0, r0                          @ 08009858
    lsls r4, r0, #5                      @ 0800985A  r4 = r0 << 5
    add r3, r4                           @ 0800985C  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800985E
    add r3, r3, r1, lsl #2               @ 08009860  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009864
    ldr r4, =v_20007EC0                  @ 08009868
    str r3, [r4]                         @ 0800986C  bt_c (u32) = r3
    ldr r3, =v205_tab_080260E4           @ 0800986E
    uxtb r0, r0                          @ 08009872
    lsls r4, r0, #5                      @ 08009874  r4 = r0 << 5
    add r3, r4                           @ 08009876  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009878
    ldr r3, [r3, r1, lsl #2]             @ 0800987A
    ldr r4, =v_20007EC4                  @ 0800987E
    str r3, [r4]                         @ 08009882  bt_d (u32) = r3
.Lmva_burden_fetch_08009884:   @ branch target from 0800981E
    b .Lmva_burden_fetch_08009B02        @ 08009884
    .ltorg
.Lmva_burden_fetch_08009886:   @ branch target from 080097A6
    ldr r3, =v_20007FDF                  @ 08009886
    ldrb r3, [r3]                        @ 0800988A  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 0800988C
    beq .Lmva_burden_fetch_080098F6      @ 0800988E  if pf8_flag == 0
    ldr r3, =v205_tab_08026444           @ 08009890
    uxtb r0, r0                          @ 08009894
    lsls r4, r0, #5                      @ 08009896  r4 = r0 << 5
    add r3, r4                           @ 08009898  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800989A
    add r3, r3, r1, lsl #2               @ 0800989C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 080098A0
    ldr r4, =v_20007EB8                  @ 080098A4
    str r3, [r4]                         @ 080098A8  bt_a (u32) = r3
    ldr r3, =v205_tab_08026444           @ 080098AA
    uxtb r0, r0                          @ 080098AE
    lsls r4, r0, #5                      @ 080098B0  r4 = r0 << 5
    add r3, r4                           @ 080098B2  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080098B4
    add r3, r3, r1, lsl #2               @ 080098B6  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 080098BA
    ldr r4, =v_20007EBC                  @ 080098BE
    str r3, [r4]                         @ 080098C2  bt_b (u32) = r3
    ldr r3, =v205_tab_08026444           @ 080098C4
    uxtb r0, r0                          @ 080098C8
    lsls r4, r0, #5                      @ 080098CA  r4 = r0 << 5
    add r3, r4                           @ 080098CC  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080098CE
    add r3, r3, r1, lsl #2               @ 080098D0  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 080098D4
    ldr r4, =v_20007EC0                  @ 080098D8
    str r3, [r4]                         @ 080098DC  bt_c (u32) = r3
    ldr r3, =v205_tab_08026444           @ 080098DE
    uxtb r0, r0                          @ 080098E2
    lsls r4, r0, #5                      @ 080098E4  r4 = r0 << 5
    add r3, r4                           @ 080098E6  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080098E8
    ldr r3, [r3, r1, lsl #2]             @ 080098EA
    ldr r4, =v_20007EC4                  @ 080098EE
    str r3, [r4]                         @ 080098F2  bt_d (u32) = r3
    b .Lmva_burden_fetch_0800995A        @ 080098F4
.Lmva_burden_fetch_080098F6:   @ branch target from 0800988E
    ldr r3, =v205_tab_08026324           @ 080098F6
    uxtb r0, r0                          @ 080098FA
    lsls r4, r0, #5                      @ 080098FC  r4 = r0 << 5
    add r3, r4                           @ 080098FE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009900
    add r3, r3, r1, lsl #2               @ 08009902  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009906
    ldr r4, =v_20007EB8                  @ 0800990A
    str r3, [r4]                         @ 0800990E  bt_a (u32) = r3
    ldr r3, =v205_tab_08026324           @ 08009910
    uxtb r0, r0                          @ 08009914
    lsls r4, r0, #5                      @ 08009916  r4 = r0 << 5
    add r3, r4                           @ 08009918  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800991A
    add r3, r3, r1, lsl #2               @ 0800991C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009920
    ldr r4, =v_20007EBC                  @ 08009924
    str r3, [r4]                         @ 08009928  bt_b (u32) = r3
    ldr r3, =v205_tab_08026324           @ 0800992A
    uxtb r0, r0                          @ 0800992E
    lsls r4, r0, #5                      @ 08009930  r4 = r0 << 5
    add r3, r4                           @ 08009932  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009934
    add r3, r3, r1, lsl #2               @ 08009936  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 0800993A
    ldr r4, =v_20007EC0                  @ 0800993E
    str r3, [r4]                         @ 08009942  bt_c (u32) = r3
    ldr r3, =v205_tab_08026324           @ 08009944
    uxtb r0, r0                          @ 08009948
    lsls r4, r0, #5                      @ 0800994A  r4 = r0 << 5
    add r3, r4                           @ 0800994C  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800994E
    ldr r3, [r3, r1, lsl #2]             @ 08009950
    ldr r4, =v_20007EC4                  @ 08009954
    str r3, [r4]                         @ 08009958  bt_d (u32) = r3
.Lmva_burden_fetch_0800995A:   @ branch target from 080098F4
    b .Lmva_burden_fetch_08009B02        @ 0800995A
.Lmva_burden_fetch_0800995C:   @ branch target from 080097A2
    ldr r3, =v_20007FDF                  @ 0800995C
    ldrb r3, [r3]                        @ 08009960  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 08009962
    beq .Lmva_burden_fetch_080099CC      @ 08009964  if pf8_flag == 0
    ldr r3, =v205_tab_08026684           @ 08009966
    uxtb r0, r0                          @ 0800996A
    lsls r4, r0, #5                      @ 0800996C  r4 = r0 << 5
    add r3, r4                           @ 0800996E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009970
    add r3, r3, r1, lsl #2               @ 08009972  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009976
    ldr r4, =v_20007EB8                  @ 0800997A
    str r3, [r4]                         @ 0800997E  bt_a (u32) = r3
    ldr r3, =v205_tab_08026684           @ 08009980
    uxtb r0, r0                          @ 08009984
    lsls r4, r0, #5                      @ 08009986  r4 = r0 << 5
    add r3, r4                           @ 08009988  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800998A
    add r3, r3, r1, lsl #2               @ 0800998C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009990
    ldr r4, =v_20007EBC                  @ 08009994
    str r3, [r4]                         @ 08009998  bt_b (u32) = r3
    ldr r3, =v205_tab_08026684           @ 0800999A
    uxtb r0, r0                          @ 0800999E
    lsls r4, r0, #5                      @ 080099A0  r4 = r0 << 5
    add r3, r4                           @ 080099A2  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080099A4
    add r3, r3, r1, lsl #2               @ 080099A6  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 080099AA
    ldr r4, =v_20007EC0                  @ 080099AE
    str r3, [r4]                         @ 080099B2  bt_c (u32) = r3
    ldr r3, =v205_tab_08026684           @ 080099B4
    uxtb r0, r0                          @ 080099B8
    lsls r4, r0, #5                      @ 080099BA  r4 = r0 << 5
    add r3, r4                           @ 080099BC  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080099BE
    ldr r3, [r3, r1, lsl #2]             @ 080099C0
    ldr r4, =v_20007EC4                  @ 080099C4
    str r3, [r4]                         @ 080099C8  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009A30        @ 080099CA
.Lmva_burden_fetch_080099CC:   @ branch target from 08009964
    ldr r3, =v205_tab_08026564           @ 080099CC
    uxtb r0, r0                          @ 080099D0
    lsls r4, r0, #5                      @ 080099D2  r4 = r0 << 5
    add r3, r4                           @ 080099D4  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080099D6
    add r3, r3, r1, lsl #2               @ 080099D8  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 080099DC
    ldr r4, =v_20007EB8                  @ 080099E0
    str r3, [r4]                         @ 080099E4  bt_a (u32) = r3
    ldr r3, =v205_tab_08026564           @ 080099E6
    uxtb r0, r0                          @ 080099EA
    lsls r4, r0, #5                      @ 080099EC  r4 = r0 << 5
    add r3, r4                           @ 080099EE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 080099F0
    add r3, r3, r1, lsl #2               @ 080099F2  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 080099F6
    ldr r4, =v_20007EBC                  @ 080099FA
    str r3, [r4]                         @ 080099FE  bt_b (u32) = r3
    ldr r3, =v205_tab_08026564           @ 08009A00
    uxtb r0, r0                          @ 08009A04
    lsls r4, r0, #5                      @ 08009A06  r4 = r0 << 5
    add r3, r4                           @ 08009A08  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009A0A
    add r3, r3, r1, lsl #2               @ 08009A0C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009A10
    ldr r4, =v_20007EC0                  @ 08009A14
    str r3, [r4]                         @ 08009A18  bt_c (u32) = r3
    ldr r3, =v205_tab_08026564           @ 08009A1A
    uxtb r0, r0                          @ 08009A1E
    lsls r4, r0, #5                      @ 08009A20  r4 = r0 << 5
    add r3, r4                           @ 08009A22  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009A24
    ldr r3, [r3, r1, lsl #2]             @ 08009A26
    ldr r4, =v_20007EC4                  @ 08009A2A
    str r3, [r4]                         @ 08009A2E  bt_d (u32) = r3
.Lmva_burden_fetch_08009A30:   @ branch target from 080099CA
    b .Lmva_burden_fetch_08009B02        @ 08009A30
.Lmva_burden_fetch_08009A32:   @ branch target from 080097AA
    ldr r3, =v_20007FDF                  @ 08009A32
    ldrb r3, [r3]                        @ 08009A36  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 08009A38
    beq .Lmva_burden_fetch_08009AA2      @ 08009A3A  if pf8_flag == 0
    ldr r3, =v205_tab_080268C4           @ 08009A3C
    uxtb r0, r0                          @ 08009A40
    lsls r4, r0, #5                      @ 08009A42  r4 = r0 << 5
    add r3, r4                           @ 08009A44  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009A46
    add r3, r3, r1, lsl #2               @ 08009A48  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009A4C
    ldr r4, =v_20007EB8                  @ 08009A50
    str r3, [r4]                         @ 08009A54  bt_a (u32) = r3
    ldr r3, =v205_tab_080268C4           @ 08009A56
    uxtb r0, r0                          @ 08009A5A
    lsls r4, r0, #5                      @ 08009A5C  r4 = r0 << 5
    add r3, r4                           @ 08009A5E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009A60
    add r3, r3, r1, lsl #2               @ 08009A62  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009A66
    ldr r4, =v_20007EBC                  @ 08009A6A
    str r3, [r4]                         @ 08009A6E  bt_b (u32) = r3
    ldr r3, =v205_tab_080268C4           @ 08009A70
    uxtb r0, r0                          @ 08009A74
    lsls r4, r0, #5                      @ 08009A76  r4 = r0 << 5
    add r3, r4                           @ 08009A78  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009A7A
    add r3, r3, r1, lsl #2               @ 08009A7C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009A80
    ldr r4, =v_20007EC0                  @ 08009A84
    str r3, [r4]                         @ 08009A88  bt_c (u32) = r3
    ldr r3, =v205_tab_080268C4           @ 08009A8A
    uxtb r0, r0                          @ 08009A8E
    lsls r4, r0, #5                      @ 08009A90  r4 = r0 << 5
    add r3, r4                           @ 08009A92  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009A94
    ldr r3, [r3, r1, lsl #2]             @ 08009A96
    ldr r4, =v_20007EC4                  @ 08009A9A
    str r3, [r4]                         @ 08009A9E  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009B02        @ 08009AA0
.Lmva_burden_fetch_08009AA2:   @ branch target from 08009A3A
    ldr r3, =v205_tab_080267A4           @ 08009AA2
    uxtb r0, r0                          @ 08009AA6
    lsls r4, r0, #5                      @ 08009AA8  r4 = r0 << 5
    add r3, r4                           @ 08009AAA  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009AAC
    add r3, r3, r1, lsl #2               @ 08009AAE  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009AB2
    ldr r4, =v_20007EB8                  @ 08009AB6
    str r3, [r4]                         @ 08009ABA  bt_a (u32) = r3
    ldr r3, =v205_tab_080267A4           @ 08009ABC
    uxtb r0, r0                          @ 08009AC0
    lsls r4, r0, #5                      @ 08009AC2  r4 = r0 << 5
    add r3, r4                           @ 08009AC4  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009AC6
    add r3, r3, r1, lsl #2               @ 08009AC8  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009ACC
    ldr r4, =v_20007EBC                  @ 08009AD0
    str r3, [r4]                         @ 08009AD4  bt_b (u32) = r3
    ldr r3, =v205_tab_080267A4           @ 08009AD6
    uxtb r0, r0                          @ 08009ADA
    lsls r4, r0, #5                      @ 08009ADC  r4 = r0 << 5
    add r3, r4                           @ 08009ADE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009AE0
    add r3, r3, r1, lsl #2               @ 08009AE2  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009AE6
    ldr r4, =v_20007EC0                  @ 08009AEA
    str r3, [r4]                         @ 08009AEC  bt_c (u32) = r3
    ldr r3, =v205_tab_080267A4           @ 08009AEE
    uxtb r0, r0                          @ 08009AF2
    lsls r4, r0, #5                      @ 08009AF4  r4 = r0 << 5
    add r3, r4                           @ 08009AF6  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009AF8
    ldr r3, [r3, r1, lsl #2]             @ 08009AFA
    ldr r4, =v_20007EC4                  @ 08009AFE
    str r3, [r4]                         @ 08009B00  bt_d (u32) = r3
.Lmva_burden_fetch_08009B02:   @ branch target from 080097AE, 08009884, 0800995A, 08009A30, 08009AA0
    b .Lmva_burden_fetch_0800A1D2        @ 08009B02
    .ltorg
.Lmva_burden_fetch_08009B08:   @ branch target from 08009374
    ldr r3, =meter_range                 @ 08009B08
    ldrb r3, [r3]                        @ 08009B0C  r3 = meter_range (u8)
    cmp r3, #0                           @ 08009B0E
    beq .Lmva_burden_fetch_08009B22      @ 08009B10  if meter_range == 0
    cmp r3, #2                           @ 08009B12
    beq .Lmva_burden_fetch_08009CAE      @ 08009B14  if meter_range == 2
    blo .Lmva_burden_fetch_08009BE8      @ 08009B18  if meter_range < (unsigned) 2
    cmp r3, #3                           @ 08009B1A
    beq .Lmva_burden_fetch_08009D74      @ 08009B1C  if meter_range == 3
    b .Lmva_burden_fetch_08009E38        @ 08009B20
.Lmva_burden_fetch_08009B22:   @ branch target from 08009B10
    ldr r3, =v_20007FDF                  @ 08009B22
    ldrb r3, [r3]                        @ 08009B26  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 08009B28
    beq .Lmva_burden_fetch_08009B8A      @ 08009B2A  if pf8_flag == 0
    ldr r3, =v205_tab_08026B04           @ 08009B2C
    uxtb r0, r0                          @ 08009B30
    lsls r4, r0, #5                      @ 08009B32  r4 = r0 << 5
    add r3, r4                           @ 08009B34  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009B36
    add r3, r3, r1, lsl #2               @ 08009B38  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009B3C
    ldr r4, =v_20007EB8                  @ 08009B40
    str r3, [r4]                         @ 08009B42  bt_a (u32) = r3
    ldr r3, =v205_tab_08026B04           @ 08009B44
    uxtb r0, r0                          @ 08009B48
    lsls r4, r0, #5                      @ 08009B4A  r4 = r0 << 5
    add r3, r4                           @ 08009B4C  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009B4E
    add r3, r3, r1, lsl #2               @ 08009B50  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009B54
    ldr r4, =v_20007EBC                  @ 08009B58
    str r3, [r4]                         @ 08009B5A  bt_b (u32) = r3
    ldr r3, =v205_tab_08026B04           @ 08009B5C
    uxtb r0, r0                          @ 08009B60
    lsls r4, r0, #5                      @ 08009B62  r4 = r0 << 5
    add r3, r4                           @ 08009B64  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009B66
    add r3, r3, r1, lsl #2               @ 08009B68  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009B6C
    ldr r4, =v_20007EC0                  @ 08009B70
    str r3, [r4]                         @ 08009B72  bt_c (u32) = r3
    ldr r3, =v205_tab_08026B04           @ 08009B74
    uxtb r0, r0                          @ 08009B78
    lsls r4, r0, #5                      @ 08009B7A  r4 = r0 << 5
    add r3, r4                           @ 08009B7C  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009B7E
    ldr r3, [r3, r1, lsl #2]             @ 08009B80
    ldr r4, =v_20007EC4                  @ 08009B84
    str r3, [r4]                         @ 08009B86  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009BE6        @ 08009B88
.Lmva_burden_fetch_08009B8A:   @ branch target from 08009B2A
    ldr r3, =v205_tab_080269E4           @ 08009B8A
    uxtb r0, r0                          @ 08009B8E
    lsls r4, r0, #5                      @ 08009B90  r4 = r0 << 5
    add r3, r4                           @ 08009B92  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009B94
    add r3, r3, r1, lsl #2               @ 08009B96  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009B9A
    ldr r4, =v_20007EB8                  @ 08009B9E
    str r3, [r4]                         @ 08009BA0  bt_a (u32) = r3
    ldr r3, =v205_tab_080269E4           @ 08009BA2
    uxtb r0, r0                          @ 08009BA6
    lsls r4, r0, #5                      @ 08009BA8  r4 = r0 << 5
    add r3, r4                           @ 08009BAA  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009BAC
    add r3, r3, r1, lsl #2               @ 08009BAE  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009BB2
    ldr r4, =v_20007EBC                  @ 08009BB6
    str r3, [r4]                         @ 08009BB8  bt_b (u32) = r3
    ldr r3, =v205_tab_080269E4           @ 08009BBA
    uxtb r0, r0                          @ 08009BBE
    lsls r4, r0, #5                      @ 08009BC0  r4 = r0 << 5
    add r3, r4                           @ 08009BC2  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009BC4
    add r3, r3, r1, lsl #2               @ 08009BC6  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009BCA
    ldr r4, =v_20007EC0                  @ 08009BCE
    str r3, [r4]                         @ 08009BD0  bt_c (u32) = r3
    ldr r3, =v205_tab_080269E4           @ 08009BD2
    uxtb r0, r0                          @ 08009BD6
    lsls r4, r0, #5                      @ 08009BD8  r4 = r0 << 5
    add r3, r4                           @ 08009BDA  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009BDC
    ldr r3, [r3, r1, lsl #2]             @ 08009BDE
    ldr r4, =v_20007EC4                  @ 08009BE2
    str r3, [r4]                         @ 08009BE4  bt_d (u32) = r3
.Lmva_burden_fetch_08009BE6:   @ branch target from 08009B88
    b .Lmva_burden_fetch_08009E38        @ 08009BE6
.Lmva_burden_fetch_08009BE8:   @ branch target from 08009B18
    ldr r3, =v_20007FDF                  @ 08009BE8
    ldrb r3, [r3]                        @ 08009BEC  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 08009BEE
    beq .Lmva_burden_fetch_08009C50      @ 08009BF0  if pf8_flag == 0
    ldr r3, =v205_tab_08026D44           @ 08009BF2
    uxtb r0, r0                          @ 08009BF6
    lsls r4, r0, #5                      @ 08009BF8  r4 = r0 << 5
    add r3, r4                           @ 08009BFA  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009BFC
    add r3, r3, r1, lsl #2               @ 08009BFE  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009C02
    ldr r4, =v_20007EB8                  @ 08009C06
    str r3, [r4]                         @ 08009C08  bt_a (u32) = r3
    ldr r3, =v205_tab_08026D44           @ 08009C0A
    uxtb r0, r0                          @ 08009C0E
    lsls r4, r0, #5                      @ 08009C10  r4 = r0 << 5
    add r3, r4                           @ 08009C12  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009C14
    add r3, r3, r1, lsl #2               @ 08009C16  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009C1A
    ldr r4, =v_20007EBC                  @ 08009C1E
    str r3, [r4]                         @ 08009C20  bt_b (u32) = r3
    ldr r3, =v205_tab_08026D44           @ 08009C22
    uxtb r0, r0                          @ 08009C26
    lsls r4, r0, #5                      @ 08009C28  r4 = r0 << 5
    add r3, r4                           @ 08009C2A  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009C2C
    add r3, r3, r1, lsl #2               @ 08009C2E  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009C32
    ldr r4, =v_20007EC0                  @ 08009C36
    str r3, [r4]                         @ 08009C38  bt_c (u32) = r3
    ldr r3, =v205_tab_08026D44           @ 08009C3A
    uxtb r0, r0                          @ 08009C3E
    lsls r4, r0, #5                      @ 08009C40  r4 = r0 << 5
    add r3, r4                           @ 08009C42  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009C44
    ldr r3, [r3, r1, lsl #2]             @ 08009C46
    ldr r4, =v_20007EC4                  @ 08009C4A
    str r3, [r4]                         @ 08009C4C  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009CAC        @ 08009C4E
.Lmva_burden_fetch_08009C50:   @ branch target from 08009BF0
    ldr r3, =v205_tab_08026C24           @ 08009C50
    uxtb r0, r0                          @ 08009C54
    lsls r4, r0, #5                      @ 08009C56  r4 = r0 << 5
    add r3, r4                           @ 08009C58  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009C5A
    add r3, r3, r1, lsl #2               @ 08009C5C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009C60
    ldr r4, =v_20007EB8                  @ 08009C64
    str r3, [r4]                         @ 08009C66  bt_a (u32) = r3
    ldr r3, =v205_tab_08026C24           @ 08009C68
    uxtb r0, r0                          @ 08009C6C
    lsls r4, r0, #5                      @ 08009C6E  r4 = r0 << 5
    add r3, r4                           @ 08009C70  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009C72
    add r3, r3, r1, lsl #2               @ 08009C74  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009C78
    ldr r4, =v_20007EBC                  @ 08009C7C
    str r3, [r4]                         @ 08009C7E  bt_b (u32) = r3
    ldr r3, =v205_tab_08026C24           @ 08009C80
    uxtb r0, r0                          @ 08009C84
    lsls r4, r0, #5                      @ 08009C86  r4 = r0 << 5
    add r3, r4                           @ 08009C88  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009C8A
    add r3, r3, r1, lsl #2               @ 08009C8C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009C90
    ldr r4, =v_20007EC0                  @ 08009C94
    str r3, [r4]                         @ 08009C96  bt_c (u32) = r3
    ldr r3, =v205_tab_08026C24           @ 08009C98
    uxtb r0, r0                          @ 08009C9C
    lsls r4, r0, #5                      @ 08009C9E  r4 = r0 << 5
    add r3, r4                           @ 08009CA0  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009CA2
    ldr r3, [r3, r1, lsl #2]             @ 08009CA4
    ldr r4, =v_20007EC4                  @ 08009CA8
    str r3, [r4]                         @ 08009CAA  bt_d (u32) = r3
.Lmva_burden_fetch_08009CAC:   @ branch target from 08009C4E
    b .Lmva_burden_fetch_08009E38        @ 08009CAC
.Lmva_burden_fetch_08009CAE:   @ branch target from 08009B14
    ldr r3, =v_20007FDF                  @ 08009CAE
    ldrb r3, [r3]                        @ 08009CB2  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 08009CB4
    beq .Lmva_burden_fetch_08009D16      @ 08009CB6  if pf8_flag == 0
    ldr r3, =v205_tab_08026F84           @ 08009CB8
    uxtb r0, r0                          @ 08009CBC
    lsls r4, r0, #5                      @ 08009CBE  r4 = r0 << 5
    add r3, r4                           @ 08009CC0  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009CC2
    add r3, r3, r1, lsl #2               @ 08009CC4  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009CC8
    ldr r4, =v_20007EB8                  @ 08009CCC
    str r3, [r4]                         @ 08009CCE  bt_a (u32) = r3
    ldr r3, =v205_tab_08026F84           @ 08009CD0
    uxtb r0, r0                          @ 08009CD4
    lsls r4, r0, #5                      @ 08009CD6  r4 = r0 << 5
    add r3, r4                           @ 08009CD8  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009CDA
    add r3, r3, r1, lsl #2               @ 08009CDC  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009CE0
    ldr r4, =v_20007EBC                  @ 08009CE4
    str r3, [r4]                         @ 08009CE6  bt_b (u32) = r3
    ldr r3, =v205_tab_08026F84           @ 08009CE8
    uxtb r0, r0                          @ 08009CEC
    lsls r4, r0, #5                      @ 08009CEE  r4 = r0 << 5
    add r3, r4                           @ 08009CF0  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009CF2
    add r3, r3, r1, lsl #2               @ 08009CF4  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009CF8
    ldr r4, =v_20007EC0                  @ 08009CFC
    str r3, [r4]                         @ 08009CFE  bt_c (u32) = r3
    ldr r3, =v205_tab_08026F84           @ 08009D00
    uxtb r0, r0                          @ 08009D04
    lsls r4, r0, #5                      @ 08009D06  r4 = r0 << 5
    add r3, r4                           @ 08009D08  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009D0A
    ldr r3, [r3, r1, lsl #2]             @ 08009D0C
    ldr r4, =v_20007EC4                  @ 08009D10
    str r3, [r4]                         @ 08009D12  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009D72        @ 08009D14
.Lmva_burden_fetch_08009D16:   @ branch target from 08009CB6
    ldr r3, =v205_tab_08026E64           @ 08009D16
    uxtb r0, r0                          @ 08009D1A
    lsls r4, r0, #5                      @ 08009D1C  r4 = r0 << 5
    add r3, r4                           @ 08009D1E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009D20
    add r3, r3, r1, lsl #2               @ 08009D22  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009D26
    ldr r4, =v_20007EB8                  @ 08009D2A
    str r3, [r4]                         @ 08009D2C  bt_a (u32) = r3
    ldr r3, =v205_tab_08026E64           @ 08009D2E
    uxtb r0, r0                          @ 08009D32
    lsls r4, r0, #5                      @ 08009D34  r4 = r0 << 5
    add r3, r4                           @ 08009D36  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009D38
    add r3, r3, r1, lsl #2               @ 08009D3A  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009D3E
    ldr r4, =v_20007EBC                  @ 08009D42
    str r3, [r4]                         @ 08009D44  bt_b (u32) = r3
    ldr r3, =v205_tab_08026E64           @ 08009D46
    uxtb r0, r0                          @ 08009D4A
    lsls r4, r0, #5                      @ 08009D4C  r4 = r0 << 5
    add r3, r4                           @ 08009D4E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009D50
    add r3, r3, r1, lsl #2               @ 08009D52  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009D56
    ldr r4, =v_20007EC0                  @ 08009D5A
    str r3, [r4]                         @ 08009D5C  bt_c (u32) = r3
    ldr r3, =v205_tab_08026E64           @ 08009D5E
    uxtb r0, r0                          @ 08009D62
    lsls r4, r0, #5                      @ 08009D64  r4 = r0 << 5
    add r3, r4                           @ 08009D66  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009D68
    ldr r3, [r3, r1, lsl #2]             @ 08009D6A
    ldr r4, =v_20007EC4                  @ 08009D6E
    str r3, [r4]                         @ 08009D70  bt_d (u32) = r3
.Lmva_burden_fetch_08009D72:   @ branch target from 08009D14
    b .Lmva_burden_fetch_08009E38        @ 08009D72
    .ltorg
.Lmva_burden_fetch_08009D74:   @ branch target from 08009B1C
    ldr r3, =v_20007FDF                  @ 08009D74
    ldrb r3, [r3]                        @ 08009D78  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 08009D7A
    beq .Lmva_burden_fetch_08009DDC      @ 08009D7C  if pf8_flag == 0
    ldr r3, =v205_tab_080271C4           @ 08009D7E
    uxtb r0, r0                          @ 08009D82
    lsls r4, r0, #5                      @ 08009D84  r4 = r0 << 5
    add r3, r4                           @ 08009D86  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009D88
    add r3, r3, r1, lsl #2               @ 08009D8A  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009D8E
    ldr r4, =v_20007EB8                  @ 08009D92
    str r3, [r4]                         @ 08009D94  bt_a (u32) = r3
    ldr r3, =v205_tab_080271C4           @ 08009D96
    uxtb r0, r0                          @ 08009D9A
    lsls r4, r0, #5                      @ 08009D9C  r4 = r0 << 5
    add r3, r4                           @ 08009D9E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009DA0
    add r3, r3, r1, lsl #2               @ 08009DA2  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009DA6
    ldr r4, =v_20007EBC                  @ 08009DAA
    str r3, [r4]                         @ 08009DAC  bt_b (u32) = r3
    ldr r3, =v205_tab_080271C4           @ 08009DAE
    uxtb r0, r0                          @ 08009DB2
    lsls r4, r0, #5                      @ 08009DB4  r4 = r0 << 5
    add r3, r4                           @ 08009DB6  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009DB8
    add r3, r3, r1, lsl #2               @ 08009DBA  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009DBE
    ldr r4, =v_20007EC0                  @ 08009DC2
    str r3, [r4]                         @ 08009DC4  bt_c (u32) = r3
    ldr r3, =v205_tab_080271C4           @ 08009DC6
    uxtb r0, r0                          @ 08009DCA
    lsls r4, r0, #5                      @ 08009DCC  r4 = r0 << 5
    add r3, r4                           @ 08009DCE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009DD0
    ldr r3, [r3, r1, lsl #2]             @ 08009DD2
    ldr r4, =v_20007EC4                  @ 08009DD6
    str r3, [r4]                         @ 08009DD8  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009E38        @ 08009DDA
.Lmva_burden_fetch_08009DDC:   @ branch target from 08009D7C
    ldr r3, =v205_tab_080270A4           @ 08009DDC
    uxtb r0, r0                          @ 08009DE0
    lsls r4, r0, #5                      @ 08009DE2  r4 = r0 << 5
    add r3, r4                           @ 08009DE4  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009DE6
    add r3, r3, r1, lsl #2               @ 08009DE8  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009DEC
    ldr r4, =v_20007EB8                  @ 08009DF0
    str r3, [r4]                         @ 08009DF2  bt_a (u32) = r3
    ldr r3, =v205_tab_080270A4           @ 08009DF4
    uxtb r0, r0                          @ 08009DF8
    lsls r4, r0, #5                      @ 08009DFA  r4 = r0 << 5
    add r3, r4                           @ 08009DFC  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009DFE
    add r3, r3, r1, lsl #2               @ 08009E00  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009E04
    ldr r4, =v_20007EBC                  @ 08009E08
    str r3, [r4]                         @ 08009E0A  bt_b (u32) = r3
    ldr r3, =v205_tab_080270A4           @ 08009E0C
    uxtb r0, r0                          @ 08009E10
    lsls r4, r0, #5                      @ 08009E12  r4 = r0 << 5
    add r3, r4                           @ 08009E14  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009E16
    add r3, r3, r1, lsl #2               @ 08009E18  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009E1C
    ldr r4, =v_20007EC0                  @ 08009E20
    str r3, [r4]                         @ 08009E22  bt_c (u32) = r3
    ldr r3, =v205_tab_080270A4           @ 08009E24
    uxtb r0, r0                          @ 08009E28
    lsls r4, r0, #5                      @ 08009E2A  r4 = r0 << 5
    add r3, r4                           @ 08009E2C  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009E2E
    ldr r3, [r3, r1, lsl #2]             @ 08009E30
    ldr r4, =v_20007EC4                  @ 08009E34
    str r3, [r4]                         @ 08009E36  bt_d (u32) = r3
.Lmva_burden_fetch_08009E38:   @ branch target from 08009B20, 08009BE6, 08009CAC, 08009D72, 08009DDA
    b .Lmva_burden_fetch_0800A1D2        @ 08009E38
.Lmva_burden_fetch_08009E3A:   @ branch target from 0800937A
    ldr r3, =meter_range                 @ 08009E3A
    ldrb r3, [r3]                        @ 08009E3C  r3 = meter_range (u8)
    cmp r3, #0                           @ 08009E3E
    beq .Lmva_burden_fetch_08009E64      @ 08009E40  if meter_range == 0
    cmp r3, #2                           @ 08009E42
    beq .Lmva_burden_fetch_0800A00C      @ 08009E44  if meter_range == 2
    blo .Lmva_burden_fetch_08009F38      @ 08009E48  if meter_range < (unsigned) 2
    cmp r3, #3                           @ 08009E4A
    beq .Lmva_burden_fetch_0800A0F0      @ 08009E4C  if meter_range == 3
    b .Lmva_burden_fetch_0800A1D2        @ 08009E50
.Lmva_burden_fetch_08009E64:   @ branch target from 08009E40
    ldr r3, =v_20007FDF                  @ 08009E64
    ldrb r3, [r3]                        @ 08009E66  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 08009E68
    beq .Lmva_burden_fetch_08009ED2      @ 08009E6A  if pf8_flag == 0
    ldr r3, =v205_tab_08027404           @ 08009E6C
    uxtb r0, r0                          @ 08009E70
    lsls r4, r0, #5                      @ 08009E72  r4 = r0 << 5
    add r3, r4                           @ 08009E74  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009E76
    add r3, r3, r1, lsl #2               @ 08009E78  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009E7C
    ldr r4, =v_20007EB8                  @ 08009E80
    str r3, [r4]                         @ 08009E84  bt_a (u32) = r3
    ldr r3, =v205_tab_08027404           @ 08009E86
    uxtb r0, r0                          @ 08009E8A
    lsls r4, r0, #5                      @ 08009E8C  r4 = r0 << 5
    add r3, r4                           @ 08009E8E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009E90
    add r3, r3, r1, lsl #2               @ 08009E92  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009E96
    ldr r4, =v_20007EBC                  @ 08009E9A
    str r3, [r4]                         @ 08009E9E  bt_b (u32) = r3
    ldr r3, =v205_tab_08027404           @ 08009EA0
    uxtb r0, r0                          @ 08009EA4
    lsls r4, r0, #5                      @ 08009EA6  r4 = r0 << 5
    add r3, r4                           @ 08009EA8  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009EAA
    add r3, r3, r1, lsl #2               @ 08009EAC  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009EB0
    ldr r4, =v_20007EC0                  @ 08009EB4
    str r3, [r4]                         @ 08009EB8  bt_c (u32) = r3
    ldr r3, =v205_tab_08027404           @ 08009EBA
    uxtb r0, r0                          @ 08009EBE
    lsls r4, r0, #5                      @ 08009EC0  r4 = r0 << 5
    add r3, r4                           @ 08009EC2  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009EC4
    ldr r3, [r3, r1, lsl #2]             @ 08009EC6
    ldr r4, =v_20007EC4                  @ 08009ECA
    str r3, [r4]                         @ 08009ECE  bt_d (u32) = r3
    b .Lmva_burden_fetch_08009F36        @ 08009ED0
.Lmva_burden_fetch_08009ED2:   @ branch target from 08009E6A
    ldr r3, =v205_tab_080272E4           @ 08009ED2
    uxtb r0, r0                          @ 08009ED6
    lsls r4, r0, #5                      @ 08009ED8  r4 = r0 << 5
    add r3, r4                           @ 08009EDA  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009EDC
    add r3, r3, r1, lsl #2               @ 08009EDE  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009EE2
    ldr r4, =v_20007EB8                  @ 08009EE6
    str r3, [r4]                         @ 08009EEA  bt_a (u32) = r3
    ldr r3, =v205_tab_080272E4           @ 08009EEC
    uxtb r0, r0                          @ 08009EF0
    lsls r4, r0, #5                      @ 08009EF2  r4 = r0 << 5
    add r3, r4                           @ 08009EF4  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009EF6
    add r3, r3, r1, lsl #2               @ 08009EF8  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009EFC
    ldr r4, =v_20007EBC                  @ 08009F00
    str r3, [r4]                         @ 08009F04  bt_b (u32) = r3
    ldr r3, =v205_tab_080272E4           @ 08009F06
    uxtb r0, r0                          @ 08009F0A
    lsls r4, r0, #5                      @ 08009F0C  r4 = r0 << 5
    add r3, r4                           @ 08009F0E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009F10
    add r3, r3, r1, lsl #2               @ 08009F12  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009F16
    ldr r4, =v_20007EC0                  @ 08009F1A
    str r3, [r4]                         @ 08009F1E  bt_c (u32) = r3
    ldr r3, =v205_tab_080272E4           @ 08009F20
    uxtb r0, r0                          @ 08009F24
    lsls r4, r0, #5                      @ 08009F26  r4 = r0 << 5
    add r3, r4                           @ 08009F28  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009F2A
    ldr r3, [r3, r1, lsl #2]             @ 08009F2C
    ldr r4, =v_20007EC4                  @ 08009F30
    str r3, [r4]                         @ 08009F34  bt_d (u32) = r3
.Lmva_burden_fetch_08009F36:   @ branch target from 08009ED0
    b .Lmva_burden_fetch_0800A1D2        @ 08009F36
.Lmva_burden_fetch_08009F38:   @ branch target from 08009E48
    ldr r3, =v_20007FDF                  @ 08009F38
    ldrb r3, [r3]                        @ 08009F3A  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 08009F3C
    beq .Lmva_burden_fetch_08009FA6      @ 08009F3E  if pf8_flag == 0
    ldr r3, =v205_tab_08027644           @ 08009F40
    uxtb r0, r0                          @ 08009F44
    lsls r4, r0, #5                      @ 08009F46  r4 = r0 << 5
    add r3, r4                           @ 08009F48  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009F4A
    add r3, r3, r1, lsl #2               @ 08009F4C  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009F50
    ldr r4, =v_20007EB8                  @ 08009F54
    str r3, [r4]                         @ 08009F58  bt_a (u32) = r3
    ldr r3, =v205_tab_08027644           @ 08009F5A
    uxtb r0, r0                          @ 08009F5E
    lsls r4, r0, #5                      @ 08009F60  r4 = r0 << 5
    add r3, r4                           @ 08009F62  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009F64
    add r3, r3, r1, lsl #2               @ 08009F66  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009F6A
    ldr r4, =v_20007EBC                  @ 08009F6E
    str r3, [r4]                         @ 08009F72  bt_b (u32) = r3
    ldr r3, =v205_tab_08027644           @ 08009F74
    uxtb r0, r0                          @ 08009F78
    lsls r4, r0, #5                      @ 08009F7A  r4 = r0 << 5
    add r3, r4                           @ 08009F7C  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009F7E
    add r3, r3, r1, lsl #2               @ 08009F80  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009F84
    ldr r4, =v_20007EC0                  @ 08009F88
    str r3, [r4]                         @ 08009F8C  bt_c (u32) = r3
    ldr r3, =v205_tab_08027644           @ 08009F8E
    uxtb r0, r0                          @ 08009F92
    lsls r4, r0, #5                      @ 08009F94  r4 = r0 << 5
    add r3, r4                           @ 08009F96  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009F98
    ldr r3, [r3, r1, lsl #2]             @ 08009F9A
    ldr r4, =v_20007EC4                  @ 08009F9E
    str r3, [r4]                         @ 08009FA2  bt_d (u32) = r3
    b .Lmva_burden_fetch_0800A00A        @ 08009FA4
.Lmva_burden_fetch_08009FA6:   @ branch target from 08009F3E
    ldr r3, =v205_tab_08027524           @ 08009FA6
    uxtb r0, r0                          @ 08009FAA
    lsls r4, r0, #5                      @ 08009FAC  r4 = r0 << 5
    add r3, r4                           @ 08009FAE  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009FB0
    add r3, r3, r1, lsl #2               @ 08009FB2  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 08009FB6
    ldr r4, =v_20007EB8                  @ 08009FBA
    str r3, [r4]                         @ 08009FBE  bt_a (u32) = r3
    ldr r3, =v205_tab_08027524           @ 08009FC0
    uxtb r0, r0                          @ 08009FC4
    lsls r4, r0, #5                      @ 08009FC6  r4 = r0 << 5
    add r3, r4                           @ 08009FC8  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009FCA
    add r3, r3, r1, lsl #2               @ 08009FCC  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 08009FD0
    ldr r4, =v_20007EBC                  @ 08009FD4
    str r3, [r4]                         @ 08009FD8  bt_b (u32) = r3
    ldr r3, =v205_tab_08027524           @ 08009FDA
    uxtb r0, r0                          @ 08009FDE
    lsls r4, r0, #5                      @ 08009FE0  r4 = r0 << 5
    add r3, r4                           @ 08009FE2  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009FE4
    add r3, r3, r1, lsl #2               @ 08009FE6  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 08009FEA
    ldr r4, =v_20007EC0                  @ 08009FEE
    str r3, [r4]                         @ 08009FF2  bt_c (u32) = r3
    ldr r3, =v205_tab_08027524           @ 08009FF4
    uxtb r0, r0                          @ 08009FF8
    lsls r4, r0, #5                      @ 08009FFA  r4 = r0 << 5
    add r3, r4                           @ 08009FFC  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 08009FFE
    ldr r3, [r3, r1, lsl #2]             @ 0800A000
    ldr r4, =v_20007EC4                  @ 0800A004
    str r3, [r4]                         @ 0800A008  bt_d (u32) = r3
.Lmva_burden_fetch_0800A00A:   @ branch target from 08009FA4
    b .Lmva_burden_fetch_0800A1D2        @ 0800A00A
    .ltorg
.Lmva_burden_fetch_0800A00C:   @ branch target from 08009E44
    ldr r3, =v_20007FDF                  @ 0800A00C
    ldrb r3, [r3]                        @ 0800A00E  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 0800A010
    beq .Lmva_burden_fetch_0800A07A      @ 0800A012  if pf8_flag == 0
    ldr r3, =v205_tab_08027764           @ 0800A014
    uxtb r0, r0                          @ 0800A018
    lsls r4, r0, #5                      @ 0800A01A  r4 = r0 << 5
    add r3, r4                           @ 0800A01C  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800A01E
    add r3, r3, r1, lsl #2               @ 0800A020  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 0800A024
    ldr r4, =v_20007EB8                  @ 0800A028
    str r3, [r4]                         @ 0800A02C  bt_a (u32) = r3
    ldr r3, =v205_tab_08027764           @ 0800A02E
    uxtb r0, r0                          @ 0800A032
    lsls r4, r0, #5                      @ 0800A034  r4 = r0 << 5
    add r3, r4                           @ 0800A036  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800A038
    add r3, r3, r1, lsl #2               @ 0800A03A  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 0800A03E
    ldr r4, =v_20007EBC                  @ 0800A042
    str r3, [r4]                         @ 0800A046  bt_b (u32) = r3
    ldr r3, =v205_tab_08027764           @ 0800A048
    uxtb r0, r0                          @ 0800A04C
    lsls r4, r0, #5                      @ 0800A04E  r4 = r0 << 5
    add r3, r4                           @ 0800A050  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800A052
    add r3, r3, r1, lsl #2               @ 0800A054  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 0800A058
    ldr r4, =v_20007EC0                  @ 0800A05C
    str r3, [r4]                         @ 0800A060  bt_c (u32) = r3
    ldr r3, =v205_tab_08027764           @ 0800A062
    uxtb r0, r0                          @ 0800A066
    lsls r4, r0, #5                      @ 0800A068  r4 = r0 << 5
    add r3, r4                           @ 0800A06A  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800A06C
    ldr r3, [r3, r1, lsl #2]             @ 0800A06E
    ldr r4, =v_20007EC4                  @ 0800A072
    str r3, [r4]                         @ 0800A076  bt_d (u32) = r3
    b .Lmva_burden_fetch_0800A0EE        @ 0800A078
.Lmva_burden_fetch_0800A07A:   @ branch target from 0800A012
    @ ---- v2.05 0x0800A07A..0x0800A0EC replaced (see Deviation in the header) ----
    @ mode 15, range 2, pf8_flag = 0: table 0x080283C4, 7 columns per row (stride 0x1C).  OF-27: the words for
    @ column b4 = 7 do not exist; EBC and EC4 use column min(b4, 6), which holds the value of the 50000 point
    @ for every V above it (EB8 and EC0 already use column b4 - 1 <= 6).
    ldr r3, =v205_tab_080283C4
    movs r4, #0x1c
    mul r4, r4, r0
    add r3, r4                              @ r3 = &table[b3][0]
    add r3, r3, r1, lsl #2                  @ r3 = &table[b3][b4]
    subs r0, r1, #6
    it mi                                   @ one conditional instruction
    movmi r0, #0                            @ b4 < 6: no clamp
    lsls r0, r0, #2                         @ bytes to step back for column min(b4, 6)
    subs r1, r3, r0                         @ r1 = &table[b3][min(b4, 6)]
    ldr r4, =v_20007EB8
    ldr r0, [r3, #-0x20]
    str r0, [r4]                            @ EB8 = table[b3-1][b4-1]
    ldr r0, [r1, #-0x1c]
    str r0, [r4, #4]                        @ EBC = table[b3-1][min(b4, 6)]
    ldr r0, [r3, #-4]
    str r0, [r4, #8]                        @ EC0 = table[b3][b4-1]
    ldr r0, [r1]
    str r0, [r4, #12]                       @ EC4 = table[b3][min(b4, 6)]
.Lmva_burden_fetch_0800A0EE:   @ branch target from 0800A078
    b .Lmva_burden_fetch_0800A1D2        @ 0800A0EE
.Lmva_burden_fetch_0800A0F0:   @ branch target from 08009E4C
    ldr r3, =v_20007FDF                  @ 0800A0F0
    ldrb r3, [r3]                        @ 0800A0F2  r3 = pf8_flag (u8)
    cmp r3, #0                           @ 0800A0F4
    beq .Lmva_burden_fetch_0800A15E      @ 0800A0F6  if pf8_flag == 0
    ldr r3, =v205_tab_08027884           @ 0800A0F8
    uxtb r0, r0                          @ 0800A0FC
    lsls r4, r0, #5                      @ 0800A0FE  r4 = r0 << 5
    add r3, r4                           @ 0800A100  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800A102
    add r3, r3, r1, lsl #2               @ 0800A104  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x24]                 @ 0800A108
    ldr r4, =v_20007EB8                  @ 0800A10C
    str r3, [r4]                         @ 0800A110  bt_a (u32) = r3
    ldr r3, =v205_tab_08027884           @ 0800A112
    uxtb r0, r0                          @ 0800A116
    lsls r4, r0, #5                      @ 0800A118  r4 = r0 << 5
    add r3, r4                           @ 0800A11A  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800A11C
    add r3, r3, r1, lsl #2               @ 0800A11E  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x20]                 @ 0800A122
    ldr r4, =v_20007EBC                  @ 0800A126
    str r3, [r4]                         @ 0800A12A  bt_b (u32) = r3
    ldr r3, =v205_tab_08027884           @ 0800A12C
    uxtb r0, r0                          @ 0800A130
    lsls r4, r0, #5                      @ 0800A132  r4 = r0 << 5
    add r3, r4                           @ 0800A134  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800A136
    add r3, r3, r1, lsl #2               @ 0800A138  r3 = (r3 + (r0 << 5)) + (r1 << 2)
    ldr r3, [r3, #-0x4]                  @ 0800A13C
    ldr r4, =v_20007EC0                  @ 0800A140
    str r3, [r4]                         @ 0800A144  bt_c (u32) = r3
    ldr r3, =v205_tab_08027884           @ 0800A146
    uxtb r0, r0                          @ 0800A14A
    lsls r4, r0, #5                      @ 0800A14C  r4 = r0 << 5
    add r3, r4                           @ 0800A14E  r3 = r3 + (r0 << 5)
    uxtb r1, r1                          @ 0800A150
    ldr r3, [r3, r1, lsl #2]             @ 0800A152
    ldr r4, =v_20007EC4                  @ 0800A156
    str r3, [r4]                         @ 0800A15A  bt_d (u32) = r3
    b .Lmva_burden_fetch_0800A1D2        @ 0800A15C
.Lmva_burden_fetch_0800A15E:   @ branch target from 0800A0F6
    @ ---- v2.05 0x0800A15E..0x0800A1D0 replaced (see Deviation in the header) ----
    @ mode 15, range 3, pf8_flag = 0: table 0x080284C0, 7 columns per row (stride 0x1C), clamp as above (OF-27).
    ldr r3, =v205_tab_080284C0
    movs r4, #0x1c
    mul r4, r4, r0
    add r3, r4                              @ r3 = &table[b3][0]
    add r3, r3, r1, lsl #2                  @ r3 = &table[b3][b4]
    subs r0, r1, #6
    it mi                                   @ one conditional instruction
    movmi r0, #0                            @ b4 < 6: no clamp
    lsls r0, r0, #2                         @ bytes to step back for column min(b4, 6)
    subs r1, r3, r0                         @ r1 = &table[b3][min(b4, 6)]
    ldr r4, =v_20007EB8
    ldr r0, [r3, #-0x20]
    str r0, [r4]                            @ EB8 = table[b3-1][b4-1]
    ldr r0, [r1, #-0x1c]
    str r0, [r4, #4]                        @ EBC = table[b3-1][min(b4, 6)]
    ldr r0, [r3, #-4]
    str r0, [r4, #8]                        @ EC0 = table[b3][b4-1]
    ldr r0, [r1]
    str r0, [r4, #12]                       @ EC4 = table[b3][min(b4, 6)]
.Lmva_burden_fetch_0800A1D2:   @ branch target from 0800938A, 080093AE, 08009792, 08009B02, 08009E38, 08009E50, 08009F36, 0800A00A, 0800A0EE, 0800A15C
    pop {r4}                             @ 0800A1D2
    bx lr                                @ 0800A1D4
    .ltorg
ENDFUNC fn_08009364
    .global mva_burden_fetch
    .set mva_burden_fetch, fn_08009364

