@ =============================================================================
@ filter.s - MAC module: 1 kHz filter correction of ACV and ACmV
@
@ With the 1 kHz filter on (filter_1khz = 1, modes 2 and 4) cal_divide_by_gain divides by g/10, so the count
@ it returns is ten times the unfiltered count; fn_08006D40 multiplies it by a frequency-dependent
@ coefficient C60/10000 (C60 about 1015 at 20 Hz), which includes the factor 1/10 that scales the value back.
@ Spec: analysis/hy3131_modes_ac_current.md 5.5.  Tables: 0x0802501C (frequencies 20..6000 Hz, 216 words),
@ 0x080256DC and 0x0802537C (216 coefficients each, below / above 100000 counts).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    @ The words that precede the three tables in the v2.05 image.  A frequency of exactly 20 Hz stops the
    @ table search at index 0 and v2.05 then reads the word before each table (spec 5.5 "Note, no visible
    @ effect").  The port does not read outside its tables; it substitutes the v2.05 values, so the result is
    @ the same for every input: FT[-1] only enters as the ratio (F - FT[-1]) / (FT[0] - FT[-1]) = 1.0 for any
    @ value other than 20 (v2.05 word 0x4002101A at 0x08025018, replaced by 0), Y1[-1] = 0 (0x080256D8) and
    @ Y2[-1] = 5500 (0x157C at 0x08025374).
    .equ FILT_PREV_FT, 0
    .equ FILT_PREV_Y1, 0
    .equ FILT_PREV_Y2, 5500

    .section .text.mac, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08006D40 (mac_filter_corr) - 1 kHz filter correction: returns D0 * C60(F, D0) / 10000, with C60 interpolated over the measured frequency
@ Replaces : 0x08006D40 FUN_08006d40 (v2.05)
@ In       : r0 = D0 (count from cal_divide_by_gain, ten times the unfiltered count)
@ Out      : r0 = corrected count; D0 unchanged outside modes 2 and 4 with the filter on; 0 for F >= 6001 Hz
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080069B4, fn_08006AEC)
@ Registers: r4 = D0 (argument, kept), r5 = table index k, r6 = result, r7 = search index, r8 = base value of the interpolation
@ RAM      : reads  0x20007C5C f_hz, 0x20007C60 c60, 0x20007C64 c64, 0x20007C68 c68, 0x20007C6C span,
@            0x20007C70 delta, 0x20007C74 x_k, 0x20007C78 x_km1, 0x20007C7C y_k, 0x20007C80 y_km1,
@            0x20007C84 t_weight, 0x20007C88 q_float, 0x20007D84 freq_stored, 0x2000803C meter_mode,
@            0x2000803E freq_range, 0x200080B9 filter_1khz
@            writes 0x20007C5C f_hz, 0x20007C60 c60, 0x20007C64 c64, 0x20007C68 c68, 0x20007C6C span,
@            0x20007C70 delta, 0x20007C74 x_k, 0x20007C78 x_km1, 0x20007C7C y_k, 0x20007C80 y_km1,
@            0x20007C84 t_weight, 0x20007C88 q_float
@ Spec     : analysis/hy3131_modes_ac_current.md 5.5
@ Deviation: OF-26 (F < 20 Hz returns D0 / 10), tables are not read before their first word (20 Hz case)
@ -----------------------------------------------------------------------------
FUNC fn_08006D40
    push {r4, r5, r6, r7, r8, lr}        @ 08006D40
    movs r4, r0                          @ 08006D44
    movs r6, r4                          @ 08006D46
    @ applies only in modes 2 and 4 with the filter on, otherwise D0 is returned unchanged
    ldr r0, =meter_mode                  @ 08006D48
    ldrb r0, [r0]                        @ 08006D4C  r0 = meter_mode (u8)
    cmp r0, #2                           @ 08006D4E
    beq .Lmac_filter_corr_08006D5C       @ 08006D50  if meter_mode == 2
    ldr r0, =meter_mode                  @ 08006D52
    ldrb r0, [r0]                        @ 08006D56  r0 = meter_mode (u8)
    cmp r0, #4                           @ 08006D58
    bne .Lmac_filter_corr_08006D66       @ 08006D5A  if meter_mode != 4
.Lmac_filter_corr_08006D5C:   @ branch target from 08006D50
    ldr r0, =filter_1khz                 @ 08006D5C
    ldrb r0, [r0]                        @ 08006D60  r0 = filter_1khz (u8)
    cmp r0, #1                           @ 08006D62
    beq .Lmac_filter_corr_on             @ 08006D64  if filter_1khz == 1
.Lmac_filter_corr_08006D66:   @ branch target from 08006D5A
    movs r0, r6                          @ 08006D66
    b .Lmac_filter_corr_exit             @ 08006D68
.Lmac_filter_corr_on:   @ filter correction active
    @ F = frequency in Hz from the stored value (fn_08012F28); 20 <= F <= 6000 Hz is corrected
    ldr r0, =v_20007D84                  @ 08006D6A
    ldr r1, [r0]                         @ 08006D6E  r1 = freq_stored (u32)
    ldr r0, =v_2000803E                  @ 08006D70
    ldrb r0, [r0]                        @ 08006D74  r0 = freq_range (u8)
    bl fn_08012F28                       @ 08006D76  MFRQ: frequency in Hz from the stored value (r1) and its range (r0)
    ldr r1, =v_20007C5C                  @ 08006D7A
    str r0, [r1]                         @ 08006D7E  f_hz (u32) = r0
    ldr r0, =v_20007C5C                  @ 08006D80
    ldr r0, [r0]                         @ 08006D84  r0 = f_hz (u32)
    cmp r0, #0x14                        @ 08006D86
    bge .Lmac_filter_corr_f_ok           @ 08006D88  if f_hz >= (signed) 20
    @ ---- v2.05 0x08006D8A..0x08006D8C replaced (see Deviation in the header) ----
    movs r1, #10                            @ OF-26: below 20 Hz, and before the first frequency, the x10 count is
    sdiv r0, r4, r1                         @ scaled back by 1/10 (the per-sample path 0x080084AC divides by 10 too)
    b .Lmac_filter_corr_exit
.Lmac_filter_corr_f_ok:   @ F >= 20
    ldr r0, =v_20007C5C                  @ 08006D8E
    ldr r0, [r0]                         @ 08006D92  r0 = f_hz (u32)
    movw r1, #0x1771                     @ 08006D94  = 6001
    cmp r0, r1                           @ 08006D98
    blt .Lmac_filter_corr_search         @ 08006D9A  if f_hz < (signed) 6001
    movs r0, #0                          @ 08006D9C
    b .Lmac_filter_corr_exit             @ 08006D9E
.Lmac_filter_corr_search:   @ frequency table search
    @ k = first index i in 0..215 with F <= FT[i], else 215
    movs r0, #0xd7                       @ 08006DA0  = 215
    movs r5, r0                          @ 08006DA2
    movs r0, #0                          @ 08006DA4
    movs r7, r0                          @ 08006DA6
.Lmac_filter_corr_08006DA8:   @ branch target from 08006DC4
    cmp r7, #0xd8                        @ 08006DA8
    bge .Lmac_filter_corr_found          @ 08006DAA  if r7 >= (signed) 216
    ldr r0, =v205_tab_0802501C           @ 08006DAC
    ldr r0, [r0, r7, lsl #2]             @ 08006DB0
    ldr r1, =v_20007C5C                  @ 08006DB4
    ldr r1, [r1]                         @ 08006DB8  r1 = f_hz (u32)
    cmp r0, r1                           @ 08006DBA
    blt .Lmac_filter_corr_08006DC2       @ 08006DBC  if r0 < (signed) f_hz
    movs r5, r7                          @ 08006DBE
    b .Lmac_filter_corr_found            @ 08006DC0
.Lmac_filter_corr_08006DC2:   @ branch target from 08006DBC
    adds r7, r7, #1                      @ 08006DC2  r7 = r7 + 1
    b .Lmac_filter_corr_08006DA8         @ 08006DC4
.Lmac_filter_corr_found:   @ table index k found
    @ t = (F - FT[k-1]) / (FT[k] - FT[k-1]) as float32; interpolation weight
    ldr r0, =v205_tab_0802501C           @ 08006DC6
    ldr r0, [r0, r5, lsl #2]             @ 08006DCA
    ldr r1, =v_20007C74                  @ 08006DCE
    str r0, [r1]                         @ 08006DD2  x_k (u32) = r0
    @ ---- v2.05 0x08006DD4..0x08006DDC replaced (see Deviation in the header) ----
    ldr r0, =v205_tab_0802501C
    add r0, r0, r5, lsl #2                  @ &table[k]
    cmp r5, #0
    ite eq                                  @ two conditional instructions: k = 0 / k > 0
    movweq r0, #FILT_PREV_FT                          @ k = 0 (F = 20 Hz): the v2.05 word before the table
    ldrne r0, [r0, #-4]                     @ k > 0: table[k-1]
    ldr r1, =v_20007C78                  @ 08006DE0
    str r0, [r1]                         @ 08006DE4  x_km1 (u32) = r0
    ldr r0, =v_20007C74                  @ 08006DE6
    ldr r0, [r0]                         @ 08006DEA  r0 = x_k (u32)
    ldr r1, =v_20007C78                  @ 08006DEC
    ldr r1, [r1]                         @ 08006DF0  r1 = x_km1 (u32)
    subs r0, r0, r1                      @ 08006DF2  r0 = x_k - x_km1
    ldr r1, =v_20007C6C                  @ 08006DF4
    str r0, [r1]                         @ 08006DF8  span (u32) = (x_k - x_km1)
    ldr r0, =v_20007C5C                  @ 08006DFA
    ldr r0, [r0]                         @ 08006DFE  r0 = f_hz (u32)
    ldr r1, =v_20007C78                  @ 08006E00
    ldr r1, [r1]                         @ 08006E04  r1 = x_km1 (u32)
    subs r0, r0, r1                      @ 08006E06  r0 = f_hz - x_km1
    ldr r1, =v_20007C70                  @ 08006E08
    str r0, [r1]                         @ 08006E0C  delta (u32) = (f_hz - x_km1)
    ldr r0, =v_20007C70                  @ 08006E0E
    ldr r0, [r0]                         @ 08006E12  r0 = delta (u32)
    bl fn_08012F60                       @ 08006E14  RT: float32 = (int32)r0
    mov r8, r0                           @ 08006E18
    ldr r0, =v_20007C6C                  @ 08006E1A
    ldr r0, [r0]                         @ 08006E1E  r0 = span (u32)
    bl fn_08012F60                       @ 08006E20  RT: float32 = (int32)r0
    movs r1, r0                          @ 08006E24
    mov r0, r8                           @ 08006E26
    bl fn_08012F94                       @ 08006E28  RT: float32 r0 = r0 / r1
    ldr r1, =v_20007C84                  @ 08006E2C
    str r0, [r1]                         @ 08006E30  t_weight (u32) = r0
    @ D0 < 100000: C60 = Y1[k-1] + RND(t * (Y1[k] - Y1[k-1]))
    ldr r0, =0x000186A0                  @ 08006E32  0x186A0 = 100000
    cmp r4, r0                           @ 08006E36
    bge .Lmac_filter_corr_big            @ 08006E38  if D0 >= (signed) 100000
    ldr r0, =v205_tab_080256DC           @ 08006E3A
    ldr r0, [r0, r5, lsl #2]             @ 08006E3E
    ldr r1, =v_20007C74                  @ 08006E42
    str r0, [r1]                         @ 08006E46  x_k (u32) = r0
    @ ---- v2.05 0x08006E48..0x08006E50 replaced (see Deviation in the header) ----
    ldr r0, =v205_tab_080256DC
    add r0, r0, r5, lsl #2                  @ &table[k]
    cmp r5, #0
    ite eq                                  @ two conditional instructions: k = 0 / k > 0
    movweq r0, #FILT_PREV_Y1                          @ k = 0 (F = 20 Hz): the v2.05 word before the table
    ldrne r0, [r0, #-4]                     @ k > 0: table[k-1]
    ldr r1, =v_20007C78                  @ 08006E54
    str r0, [r1]                         @ 08006E58  x_km1 (u32) = r0
    ldr r0, =v_20007C78                  @ 08006E5A
    ldr r0, [r0]                         @ 08006E5E  r0 = x_km1 (u32)
    ldr r1, =v_20007C6C                  @ 08006E60
    str r0, [r1]                         @ 08006E64  span (u32) = x_km1
    ldr r0, =v_20007C74                  @ 08006E66
    ldr r0, [r0]                         @ 08006E6A  r0 = x_k (u32)
    ldr r1, =v_20007C78                  @ 08006E6C
    ldr r1, [r1]                         @ 08006E70  r1 = x_km1 (u32)
    subs r0, r0, r1                      @ 08006E72  r0 = x_k - x_km1
    ldr r1, =v_20007C70                  @ 08006E74
    str r0, [r1]                         @ 08006E78  delta (u32) = (x_k - x_km1)
    ldr r0, =v_20007C6C                  @ 08006E7A
    ldr r8, [r0]                         @ 08006E7E  r8 = span (u32)
    ldr r0, =v_20007C70                  @ 08006E82
    ldr r0, [r0]                         @ 08006E86  r0 = delta (u32)
    bl fn_08012F60                       @ 08006E88  RT: float32 = (int32)r0
    ldr r1, =v_20007C84                  @ 08006E8C
    ldr r1, [r1]                         @ 08006E90  r1 = t_weight (u32)
    bl fn_08013090                       @ 08006E92  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 08006E96  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 08006E9A
    ldr r3, =0x3FE00000                  @ 08006E9C  0x3FE00000:0 = 0.5 (double), the rounding term of the RND() sequence
    bl fn_080131B8                       @ 08006EA0  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 08006EA4  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, r8                      @ 08006EA8  r0 = r0 + span
    ldr r1, =v_20007C60                  @ 08006EAC
    str r0, [r1]                         @ 08006EB0  c60 (u32) = (r0 + span)
    b .Lmac_filter_corr_tail             @ 08006EB2
.Lmac_filter_corr_big:   @ D0 >= 100000
    @ D0 >= 100000: D0 >= 500001 gives C60 = INTERP(Y2, k) (fall through); below 500001 the blend at .Lmac_filter_corr_mid follows
    ldr r0, =0x0007A121                  @ 08006EB4  0x7A121 = 500001
    cmp r4, r0                           @ 08006EB8
    blt .Lmac_filter_corr_mid            @ 08006EBA  if D0 < (signed) 500001
    ldr r0, =v205_tab_0802537C           @ 08006EBC
    ldr r0, [r0, r5, lsl #2]             @ 08006EC0
    ldr r1, =v_20007C74                  @ 08006EC4
    str r0, [r1]                         @ 08006EC8  x_k (u32) = r0
    @ ---- v2.05 0x08006ECA..0x08006ED2 replaced (see Deviation in the header) ----
    ldr r0, =v205_tab_0802537C
    add r0, r0, r5, lsl #2                  @ &table[k]
    cmp r5, #0
    ite eq                                  @ two conditional instructions: k = 0 / k > 0
    movweq r0, #FILT_PREV_Y2                          @ k = 0 (F = 20 Hz): the v2.05 word before the table
    ldrne r0, [r0, #-4]                     @ k > 0: table[k-1]
    ldr r1, =v_20007C78                  @ 08006ED6
    str r0, [r1]                         @ 08006EDA  x_km1 (u32) = r0
    ldr r0, =v_20007C78                  @ 08006EDC
    ldr r0, [r0]                         @ 08006EE0  r0 = x_km1 (u32)
    ldr r1, =v_20007C6C                  @ 08006EE2
    str r0, [r1]                         @ 08006EE6  span (u32) = x_km1
    ldr r0, =v_20007C74                  @ 08006EE8
    ldr r0, [r0]                         @ 08006EEC  r0 = x_k (u32)
    ldr r1, =v_20007C78                  @ 08006EEE
    ldr r1, [r1]                         @ 08006EF2  r1 = x_km1 (u32)
    subs r0, r0, r1                      @ 08006EF4  r0 = x_k - x_km1
    ldr r1, =v_20007C70                  @ 08006EF6
    str r0, [r1]                         @ 08006EFA  delta (u32) = (x_k - x_km1)
    ldr r0, =v_20007C6C                  @ 08006EFC
    ldr r8, [r0]                         @ 08006F00  r8 = span (u32)
    ldr r0, =v_20007C70                  @ 08006F04
    ldr r0, [r0]                         @ 08006F08  r0 = delta (u32)
    bl fn_08012F60                       @ 08006F0A  RT: float32 = (int32)r0
    ldr r1, =v_20007C84                  @ 08006F0E
    ldr r1, [r1]                         @ 08006F12  r1 = t_weight (u32)
    bl fn_08013090                       @ 08006F14  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 08006F18  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 08006F1C
    ldr r3, =0x3FE00000                  @ 08006F1E  0x3FE00000:0 = 0.5 (double), the rounding term of the RND() sequence
    bl fn_080131B8                       @ 08006F22  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 08006F26  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, r8                      @ 08006F2A  r0 = r0 + span
    ldr r1, =v_20007C60                  @ 08006F2E
    str r0, [r1]                         @ 08006F32  c60 (u32) = (r0 + span)
    b .Lmac_filter_corr_tail             @ 08006F34
.Lmac_filter_corr_mid:   @ 100000 <= D0 < 500001
    @ 100000 <= D0 < 500001: C64 = INTERP(Y1, k), C68 = INTERP(Y2, k), blend with (D0 - 100000) / 400000
    ldr r0, =v205_tab_080256DC           @ 08006F36
    ldr r0, [r0, r5, lsl #2]             @ 08006F3A
    ldr r1, =v_20007C74                  @ 08006F3E
    str r0, [r1]                         @ 08006F42  x_k (u32) = r0
    @ ---- v2.05 0x08006F44..0x08006F4C replaced (see Deviation in the header) ----
    ldr r0, =v205_tab_080256DC
    add r0, r0, r5, lsl #2                  @ &table[k]
    cmp r5, #0
    ite eq                                  @ two conditional instructions: k = 0 / k > 0
    movweq r0, #FILT_PREV_Y1                          @ k = 0 (F = 20 Hz): the v2.05 word before the table
    ldrne r0, [r0, #-4]                     @ k > 0: table[k-1]
    ldr r1, =v_20007C78                  @ 08006F50
    str r0, [r1]                         @ 08006F54  x_km1 (u32) = r0
    ldr r0, =v205_tab_0802537C           @ 08006F56
    ldr r0, [r0, r5, lsl #2]             @ 08006F5A
    ldr r1, =v_20007C7C                  @ 08006F5E
    str r0, [r1]                         @ 08006F62  y_k (u32) = r0
    @ ---- v2.05 0x08006F64..0x08006F6C replaced (see Deviation in the header) ----
    ldr r0, =v205_tab_0802537C
    add r0, r0, r5, lsl #2                  @ &table[k]
    cmp r5, #0
    ite eq                                  @ two conditional instructions: k = 0 / k > 0
    movweq r0, #FILT_PREV_Y2                          @ k = 0 (F = 20 Hz): the v2.05 word before the table
    ldrne r0, [r0, #-4]                     @ k > 0: table[k-1]
    ldr r1, =v_20007C80                  @ 08006F70
    str r0, [r1]                         @ 08006F74  y_km1 (u32) = r0
    ldr r0, =v_20007C78                  @ 08006F76
    ldr r0, [r0]                         @ 08006F7A  r0 = x_km1 (u32)
    ldr r1, =v_20007C6C                  @ 08006F7C
    str r0, [r1]                         @ 08006F80  span (u32) = x_km1
    ldr r0, =v_20007C74                  @ 08006F82
    ldr r0, [r0]                         @ 08006F86  r0 = x_k (u32)
    ldr r1, =v_20007C78                  @ 08006F88
    ldr r1, [r1]                         @ 08006F8C  r1 = x_km1 (u32)
    subs r0, r0, r1                      @ 08006F8E  r0 = x_k - x_km1
    ldr r1, =v_20007C70                  @ 08006F90
    str r0, [r1]                         @ 08006F94  delta (u32) = (x_k - x_km1)
    ldr r0, =v_20007C6C                  @ 08006F96
    ldr r8, [r0]                         @ 08006F9A  r8 = span (u32)
    ldr r0, =v_20007C70                  @ 08006F9E
    ldr r0, [r0]                         @ 08006FA2  r0 = delta (u32)
    bl fn_08012F60                       @ 08006FA4  RT: float32 = (int32)r0
    ldr r1, =v_20007C84                  @ 08006FA8
    ldr r1, [r1]                         @ 08006FAC  r1 = t_weight (u32)
    bl fn_08013090                       @ 08006FAE  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 08006FB2  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 08006FB6
    ldr r3, =0x3FE00000                  @ 08006FB8  0x3FE00000:0 = 0.5 (double), the rounding term of the RND() sequence
    bl fn_080131B8                       @ 08006FBC  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 08006FC0  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, r8                      @ 08006FC4  r0 = r0 + span
    ldr r1, =v_20007C64                  @ 08006FC8
    str r0, [r1]                         @ 08006FCC  c64 (u32) = (r0 + span)
    ldr r0, =v_20007C80                  @ 08006FCE
    ldr r0, [r0]                         @ 08006FD2  r0 = y_km1 (u32)
    ldr r1, =v_20007C6C                  @ 08006FD4
    str r0, [r1]                         @ 08006FD8  span (u32) = y_km1
    ldr r0, =v_20007C7C                  @ 08006FDA
    ldr r0, [r0]                         @ 08006FDE  r0 = y_k (u32)
    ldr r1, =v_20007C80                  @ 08006FE0
    ldr r1, [r1]                         @ 08006FE4  r1 = y_km1 (u32)
    subs r0, r0, r1                      @ 08006FE6  r0 = y_k - y_km1
    ldr r1, =v_20007C70                  @ 08006FE8
    str r0, [r1]                         @ 08006FEC  delta (u32) = (y_k - y_km1)
    ldr r0, =v_20007C6C                  @ 08006FEE
    ldr r8, [r0]                         @ 08006FF2  r8 = span (u32)
    ldr r0, =v_20007C70                  @ 08006FF6
    ldr r0, [r0]                         @ 08006FFA  r0 = delta (u32)
    bl fn_08012F60                       @ 08006FFC  RT: float32 = (int32)r0
    ldr r1, =v_20007C84                  @ 08007000
    ldr r1, [r1]                         @ 08007004  r1 = t_weight (u32)
    bl fn_08013090                       @ 08007006  RT: float32 r0 = r0 * r1
    bl fn_08013168                       @ 0800700A  RT: double r0:r1 = (double)float32 r0
    movs r2, #0                          @ 0800700E
    ldr r3, =0x3FE00000                  @ 08007010  0x3FE00000:0 = 0.5 (double), the rounding term of the RND() sequence
    bl fn_080131B8                       @ 08007014  RT: double r0:r1 = r0:r1 + r2:r3
    bl fn_080132A0                       @ 08007018  RT: int32 r0 = (int)double r0:r1 (truncating)
    adds r0, r0, r8                      @ 0800701C  r0 = r0 + span
    ldr r1, =v_20007C68                  @ 08007020
    str r0, [r1]                         @ 08007024  c68 (u32) = (r0 + span)
    movs r0, r4                          @ 08007026
    bl fn_08012F60                       @ 08007028  RT: float32 = (int32)r0
    ldr r1, =0xC7C35000                  @ 0800702C  0xC7C35000 = -100000.0f
    bl fn_080132EC                       @ 08007030  RT: float32 r0 = r0 + r1
    ldr r1, =0x48C35000                  @ 08007034  0x48C35000 = 400000.0f
    bl fn_08012F94                       @ 08007038  RT: float32 r0 = r0 / r1
    mov r8, r0                           @ 0800703C
    ldr r0, =v_20007C68                  @ 0800703E
    ldr r0, [r0]                         @ 08007042  r0 = c68 (u32)
    ldr r1, =v_20007C64                  @ 08007044
    ldr r1, [r1]                         @ 08007048  r1 = c64 (u32)
    subs r0, r0, r1                      @ 0800704A  r0 = c68 - c64
    bl fn_08012F60                       @ 0800704C  RT: float32 = (int32)r0
    mov r1, r8                           @ 08007050
    bl fn_08013090                       @ 08007052  RT: float32 r0 = r0 * r1
    ldr r1, =v_20007C88                  @ 08007056
    str r0, [r1]                         @ 0800705A  q_float (u32) = r0
    ldr r0, =v_20007C64                  @ 0800705C
    ldr r8, [r0]                         @ 08007060  r8 = c64 (u32)
    ldr r0, =v_20007C88                  @ 08007064
    ldr r0, [r0]                         @ 08007068  r0 = q_float (u32)
    bl fn_08013370                       @ 0800706A  RT: int32 r0 = (int)float32 r0 (truncating)
    adds r0, r0, r8                      @ 0800706E  r0 = r0 + c64
    ldr r1, =v_20007C60                  @ 08007072
    str r0, [r1]                         @ 08007076  c60 (u32) = (r0 + c64)
.Lmac_filter_corr_tail:   @ C60 known
    @ result = (C60 * D0) / 1000 / 10  (truncating divisions, equal to / 10000)
    ldr r0, =v_20007C60                  @ 08007078
    ldr r0, [r0]                         @ 0800707C  r0 = c60 (u32)
    mul r0, r0, r4                       @ 0800707E  r0 = c60 * D0
    mov r1, #0x3e8                       @ 08007082  = 1000
    sdiv r0, r0, r1                      @ 08007086  r0 = (c60 * D0) / 1000
    movs r6, r0                          @ 0800708A
    movs r0, #0xa                        @ 0800708C
    sdiv r6, r6, r0                      @ 0800708E  r6 = ((c60 * D0) / 1000) / 10
    movs r0, r6                          @ 08007092
.Lmac_filter_corr_exit:   @ return
    pop {r4, r5, r6, r7, r8, pc}         @ 08007094
    .ltorg
    .ltorg
ENDFUNC fn_08006D40
    .global mac_filter_corr
    .set mac_filter_corr, fn_08006D40

