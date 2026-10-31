@ =============================================================================
@ freqrange.s - AR: range selection for FREQ, PULSE and DUTY
@
@ Replaces the v2.05 function frequency_select_range 0x0800AC1C (DESIGN.md 6.12; Appendix A lists it under MFRQ).
@ MFRQ (fn_0800AA00) calls it after every counter result; it calls back into MFRQ for the conversion
@ (counter_compute_frequency 0x0800B610) and for the range store (fn_0800AEE8).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "ar.inc"

    .section .text.ar.freqrange, "ax", %progbits

@ -----------------------------------------------------------------------------
@ frequency_select_range - choose the FREQ / PULSE / DUTY range from the measured frequency
@ Replaces : 0x0800AC1C frequency_select_range (v2.05)
@ In       : r0 = 0 for FREQ, PULSE and DUTY (r1 = meter_range), 1 for the frequency measurement of the AC current modes
@            ACuA, ACmA, ACA (r1 = the byte at 0x2000803E, owner MAC)
@            r1 = range
@ Out      : the range is applied by fn_0800AEE8 (MFRQ); ar_negative = 0, ar_overload = 1 when the frequency does not
@            fit the manual range; for r0 = 0 also ar_new_result (0x2000805D) = 1 and the decimal point 0x2000803F
@ Clobbers : r0-r3, r12, flags (r4, r5 saved; r3 is stack padding)
@ Context  : main (MFRQ fn_0800AA00, once per counter result)
@ RAM      : reads ar_freq64 (0x20007C40, 64-bit frequency in mHz), range_manual, ar_cal_mode; writes ar_negative,
@            ar_overload, ar_new_result, ar_dec_digits
@ Spec     : analysis/autorange_and_scheduler.md 2.5 (FREQ / PULSE / DUTY row); hy3131_modes_misc.md section 0.  Range edges
@            in mHz: 100 000 (100 Hz), 1 000 000, 10 000 000, 100 000 000, 1 000 000 000 (1 MHz); in automatic
@            selection the present range is kept down to 80 % of its lower edge (80 000, 800 000, 8 000 000, 80 000 000)
@            Call chain: counter_compute_frequency (MFRQ) first converts the counter to ar_freq64
@ -----------------------------------------------------------------------------
FUNC frequency_select_range
    .global ar_freq_select
    .thumb_set ar_freq_select, frequency_select_range

@ r4 = which, r5 = range.  Convert the counter value, then clear the sign and overload flags
    push {r3, r4, r5, lr}               @ 0800AC1C
    movs r4, r0                         @ 0800AC1E
    movs r5, r1                         @ 0800AC20
    bl counter_compute_frequency        @ 0800AC22
    movs r0, #0                         @ 0800AC26
    ldr r1, =ar_negative                @ 0800AC28
    strb r0, [r1]                       @ 0800AC2C
    movs r0, #0                         @ 0800AC2E
    ldr r1, =ar_overload                @ 0800AC30
    strb r0, [r1]                       @ 0800AC34

@ the AC current modes (which != 0), calibration mode and automatic range select the range by magnitude (0x0800AD4E)
    uxtb r4, r4                         @ 0800AC36
    cmp r4, #0                          @ 0800AC38
    bne .L800ac1c_auto                  @ 0800AC3A

@ FREQ / PULSE / DUTY with a manual range outside calibration mode: the frequency must fit the manual range
@ (below its upper edge), else overload
    ldr r0, =ar_cal_mode                @ 0800AC3E
    ldrb r0, [r0]                       @ 0800AC42
    ldr r1, =range_manual               @ 0800AC44
    ldrb r1, [r1]                       @ 0800AC48
    eors r1, r1, #1                     @ 0800AC4A
    orrs r0, r1                         @ 0800AC4E
    uxtb r0, r0                         @ 0800AC50
    cmp r0, #0                          @ 0800AC52
    bne .L800ac1c_auto                  @ 0800AC54
    uxtb r5, r5                         @ 0800AC56
    cmp r5, #0                          @ 0800AC58
    beq .L800ac1c_0800AD22              @ 0800AC5A
    cmp r5, #2                          @ 0800AC5C
    beq .L800ac1c_0800ACC6              @ 0800AC5E
    bcc .L800ac1c_0800ACF4              @ 0800AC60
    cmp r5, #4                          @ 0800AC62
    beq .L800ac1c_manual4               @ 0800AC64
    bcc .L800ac1c_0800AC98              @ 0800AC66
    b .L800ac1c_end                     @ 0800AC68

@ manual range 4 (up to 1 MHz), 3 (100 kHz), 2 (10 kHz), 1 (1 kHz), 0 (100 Hz); a frequency at or above the edge
@ of the manual range sets the overload flag instead of calling fn_0800AEE8
@ reached from 0800AC64 beq (equal / zero) after cmp r5, #4
.L800ac1c_manual4:
    ldr r0, =ar_freq64                  @ 0800AC6A
    ldrd r2, r3, [r0]                   @ 0800AC6E
    ldr r0, =0x3B9ACA00                 @ 0800AC72: 1 000 000 000 mHz = 1 MHz
    movs r1, #0                         @ 0800AC76
    cmp r3, r1                          @ 0800AC78
    bcc .L800ac1c_0800AC8C              @ 0800AC7A
    bhi .L800ac1c_0800AC82              @ 0800AC7C
    cmp r2, r0                          @ 0800AC7E
    bcc .L800ac1c_0800AC8C              @ 0800AC80
@ reached from 0800AC7C bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AC82:
    movs r0, #1                         @ 0800AC82
    ldr r1, =ar_overload                @ 0800AC84
    strb r0, [r1]                       @ 0800AC88
    b .L800ac1c_0800AC96                @ 0800AC8A
@ reached from 0800AC7A bcc (unsigned <) after cmp r3, r1
@              and from 0800AC80 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AC8C:
    movs r1, #4                         @ 0800AC8C
    movs r0, r4                         @ 0800AC8E
    uxtb r0, r0                         @ 0800AC90
    bl fn_0800AEE8                      @ 0800AC92
@ reached from 0800AC8A b (jump)
.L800ac1c_0800AC96:
    b .L800ac1c_end                     @ 0800AC96
@ reached from 0800AC66 bcc (unsigned <) after cmp r5, #4
.L800ac1c_0800AC98:
    ldr r0, =ar_freq64                  @ 0800AC98
    ldrd r2, r3, [r0]                   @ 0800AC9C
    ldr r0, =0x05F5E100                 @ 0800ACA0: 100 000 000 mHz = 100 kHz
    movs r1, #0                         @ 0800ACA4
    cmp r3, r1                          @ 0800ACA6
    bcc .L800ac1c_0800ACBA              @ 0800ACA8
    bhi .L800ac1c_0800ACB0              @ 0800ACAA
    cmp r2, r0                          @ 0800ACAC
    bcc .L800ac1c_0800ACBA              @ 0800ACAE
@ reached from 0800ACAA bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800ACB0:
    movs r0, #1                         @ 0800ACB0
    ldr r1, =ar_overload                @ 0800ACB2
    strb r0, [r1]                       @ 0800ACB6
    b .L800ac1c_0800ACC4                @ 0800ACB8
@ reached from 0800ACA8 bcc (unsigned <) after cmp r3, r1
@              and from 0800ACAE bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800ACBA:
    movs r1, #3                         @ 0800ACBA
    movs r0, r4                         @ 0800ACBC
    uxtb r0, r0                         @ 0800ACBE
    bl fn_0800AEE8                      @ 0800ACC0
@ reached from 0800ACB8 b (jump)
.L800ac1c_0800ACC4:
    b .L800ac1c_end                     @ 0800ACC4
@ reached from 0800AC5E beq (equal / zero) after cmp r5, #2
.L800ac1c_0800ACC6:
    ldr r0, =ar_freq64                  @ 0800ACC6
    ldrd r2, r3, [r0]                   @ 0800ACCA
    ldr r0, =0x00989680                 @ 0800ACCE: 10 000 000 mHz = 10 kHz
    movs r1, #0                         @ 0800ACD2
    cmp r3, r1                          @ 0800ACD4
    bcc .L800ac1c_0800ACE8              @ 0800ACD6
    bhi .L800ac1c_0800ACDE              @ 0800ACD8
    cmp r2, r0                          @ 0800ACDA
    bcc .L800ac1c_0800ACE8              @ 0800ACDC
@ reached from 0800ACD8 bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800ACDE:
    movs r0, #1                         @ 0800ACDE
    ldr r1, =ar_overload                @ 0800ACE0
    strb r0, [r1]                       @ 0800ACE4
    b .L800ac1c_0800ACF2                @ 0800ACE6
@ reached from 0800ACD6 bcc (unsigned <) after cmp r3, r1
@              and from 0800ACDC bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800ACE8:
    movs r1, #2                         @ 0800ACE8
    movs r0, r4                         @ 0800ACEA
    uxtb r0, r0                         @ 0800ACEC
    bl fn_0800AEE8                      @ 0800ACEE
@ reached from 0800ACE6 b (jump)
.L800ac1c_0800ACF2:
    b .L800ac1c_end                     @ 0800ACF2
@ reached from 0800AC60 bcc (unsigned <) after cmp r5, #2
.L800ac1c_0800ACF4:
    ldr r0, =ar_freq64                  @ 0800ACF4
    ldrd r2, r3, [r0]                   @ 0800ACF8
    ldr r0, =0x000F4240                 @ 0800ACFC: 1 000 000 mHz = 1 kHz
    movs r1, #0                         @ 0800AD00
    cmp r3, r1                          @ 0800AD02
    bcc .L800ac1c_0800AD16              @ 0800AD04
    bhi .L800ac1c_0800AD0C              @ 0800AD06
    cmp r2, r0                          @ 0800AD08
    bcc .L800ac1c_0800AD16              @ 0800AD0A
@ reached from 0800AD06 bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AD0C:
    movs r0, #1                         @ 0800AD0C
    ldr r1, =ar_overload                @ 0800AD0E
    strb r0, [r1]                       @ 0800AD12
    b .L800ac1c_0800AD20                @ 0800AD14
@ reached from 0800AD04 bcc (unsigned <) after cmp r3, r1
@              and from 0800AD0A bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AD16:
    movs r1, #1                         @ 0800AD16
    movs r0, r4                         @ 0800AD18
    uxtb r0, r0                         @ 0800AD1A
    bl fn_0800AEE8                      @ 0800AD1C
@ reached from 0800AD14 b (jump)
.L800ac1c_0800AD20:
    b .L800ac1c_end                     @ 0800AD20
@ reached from 0800AC5A beq (equal / zero) after cmp r5, #0
.L800ac1c_0800AD22:
    ldr r0, =ar_freq64                  @ 0800AD22
    ldrd r2, r3, [r0]                   @ 0800AD26
    ldr r0, =0x000186A0                 @ 0800AD2A: 100 000 mHz = 100 Hz
    movs r1, #0                         @ 0800AD2C
    cmp r3, r1                          @ 0800AD2E
    bcc .L800ac1c_0800AD42              @ 0800AD30
    bhi .L800ac1c_0800AD38              @ 0800AD32
    cmp r2, r0                          @ 0800AD34
    bcc .L800ac1c_0800AD42              @ 0800AD36
@ reached from 0800AD32 bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AD38:
    movs r0, #1                         @ 0800AD38
    ldr r1, =ar_overload                @ 0800AD3A
    strb r0, [r1]                       @ 0800AD3E
    b .L800ac1c_0800AD4C                @ 0800AD40
@ reached from 0800AD30 bcc (unsigned <) after cmp r3, r1
@              and from 0800AD36 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AD42:
    movs r1, #0                         @ 0800AD42
    movs r0, r4                         @ 0800AD44
    uxtb r0, r0                         @ 0800AD46
    bl fn_0800AEE8                      @ 0800AD48
@ reached from 0800AD40 b (jump)
.L800ac1c_0800AD4C:
    b .L800ac1c_end                     @ 0800AD4C

@ automatic: 1 MHz and above = case 9 of fn_0800AEE8, 100 kHz and above = range 4 (also from 80 kHz when range 4
@ is already selected), 10 kHz = 3 (8 kHz), 1 kHz = 2 (800 Hz), 100 Hz = 1 (80 Hz), else 0
@ reached from 0800AC3A bne (not equal / non-zero) after cmp r4, #0
@              and from 0800AC54 bne (not equal / non-zero) after cmp r0, #0
.L800ac1c_auto:
    ldr r0, =ar_freq64                  @ 0800AD4E
    ldrd r2, r3, [r0]                   @ 0800AD52
    ldr r0, =0x3B9ACA00                 @ 0800AD56: 1 000 000 000 mHz = 1 MHz
    movs r1, #0                         @ 0800AD5A
    cmp r3, r1                          @ 0800AD5C
    bcc .L800ac1c_0800AD72              @ 0800AD5E
    bhi .L800ac1c_0800AD66              @ 0800AD60
    cmp r2, r0                          @ 0800AD62
    bcc .L800ac1c_0800AD72              @ 0800AD64
@ reached from 0800AD60 bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AD66:
    movs r1, #9                         @ 0800AD66
    movs r0, r4                         @ 0800AD68
    uxtb r0, r0                         @ 0800AD6A
    bl fn_0800AEE8                      @ 0800AD6C
    b .L800ac1c_end                     @ 0800AD70
@ reached from 0800AD5E bcc (unsigned <) after cmp r3, r1
@              and from 0800AD64 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AD72:
    ldr r0, =ar_freq64                  @ 0800AD72
    ldrd r2, r3, [r0]                   @ 0800AD76
    ldr r0, =0x05F5E100                 @ 0800AD7A: 100 000 000 mHz = 100 kHz
    movs r1, #0                         @ 0800AD7E
    cmp r3, r1                          @ 0800AD80
    bcc .L800ac1c_0800AD96              @ 0800AD82
    bhi .L800ac1c_0800AD8A              @ 0800AD84
    cmp r2, r0                          @ 0800AD86
    bcc .L800ac1c_0800AD96              @ 0800AD88
@ reached from 0800AD84 bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AD8A:
    movs r1, #4                         @ 0800AD8A
    movs r0, r4                         @ 0800AD8C
    uxtb r0, r0                         @ 0800AD8E
    bl fn_0800AEE8                      @ 0800AD90
    b .L800ac1c_end                     @ 0800AD94
@ reached from 0800AD82 bcc (unsigned <) after cmp r3, r1
@              and from 0800AD88 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AD96:
    uxtb r5, r5                         @ 0800AD96
    cmp r5, #4                          @ 0800AD98
    bne .L800ac1c_0800ADC0              @ 0800AD9A
    ldr r0, =ar_freq64                  @ 0800AD9C
    ldrd r2, r3, [r0]                   @ 0800ADA0
    ldr r0, =0x04C4B400                 @ 0800ADA4: 80 000 000 mHz = 80 kHz (80 % of 100 kHz)
    movs r1, #0                         @ 0800ADA8
    cmp r3, r1                          @ 0800ADAA
    bcc .L800ac1c_0800ADC0              @ 0800ADAC
    bhi .L800ac1c_0800ADB4              @ 0800ADAE
    cmp r2, r0                          @ 0800ADB0
    bcc .L800ac1c_0800ADC0              @ 0800ADB2
@ reached from 0800ADAE bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800ADB4:
    movs r1, #4                         @ 0800ADB4
    movs r0, r4                         @ 0800ADB6
    uxtb r0, r0                         @ 0800ADB8
    bl fn_0800AEE8                      @ 0800ADBA
    b .L800ac1c_end                     @ 0800ADBE
    .ltorg
@ reached from 0800AD9A bne (not equal / non-zero) after cmp r5, #4
@              and from 0800ADAC bcc (unsigned <) after cmp r3, r1
@              and from 0800ADB2 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800ADC0:
    ldr r0, =ar_freq64                  @ 0800ADC0
    ldrd r2, r3, [r0]                   @ 0800ADC4
    ldr r0, =0x00989680                 @ 0800ADC8: 10 000 000 mHz = 10 kHz
    movs r1, #0                         @ 0800ADCC
    cmp r3, r1                          @ 0800ADCE
    bcc .L800ac1c_0800ADE4              @ 0800ADD0
    bhi .L800ac1c_0800ADD8              @ 0800ADD2
    cmp r2, r0                          @ 0800ADD4
    bcc .L800ac1c_0800ADE4              @ 0800ADD6
@ reached from 0800ADD2 bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800ADD8:
    movs r1, #3                         @ 0800ADD8
    movs r0, r4                         @ 0800ADDA
    uxtb r0, r0                         @ 0800ADDC
    bl fn_0800AEE8                      @ 0800ADDE
    b .L800ac1c_end                     @ 0800ADE2
@ reached from 0800ADD0 bcc (unsigned <) after cmp r3, r1
@              and from 0800ADD6 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800ADE4:
    uxtb r5, r5                         @ 0800ADE4
    cmp r5, #3                          @ 0800ADE6
    bne .L800ac1c_0800AE0E              @ 0800ADE8
    ldr r0, =ar_freq64                  @ 0800ADEA
    ldrd r2, r3, [r0]                   @ 0800ADEE
    ldr r0, =0x007A1200                 @ 0800ADF2: 8 000 000 mHz = 8 kHz (80 % of 10 kHz)
    movs r1, #0                         @ 0800ADF6
    cmp r3, r1                          @ 0800ADF8
    bcc .L800ac1c_0800AE0E              @ 0800ADFA
    bhi .L800ac1c_0800AE02              @ 0800ADFC
    cmp r2, r0                          @ 0800ADFE
    bcc .L800ac1c_0800AE0E              @ 0800AE00
@ reached from 0800ADFC bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AE02:
    movs r1, #3                         @ 0800AE02
    movs r0, r4                         @ 0800AE04
    uxtb r0, r0                         @ 0800AE06
    bl fn_0800AEE8                      @ 0800AE08
    b .L800ac1c_end                     @ 0800AE0C
@ reached from 0800ADE8 bne (not equal / non-zero) after cmp r5, #3
@              and from 0800ADFA bcc (unsigned <) after cmp r3, r1
@              and from 0800AE00 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AE0E:
    ldr r0, =ar_freq64                  @ 0800AE0E
    ldrd r2, r3, [r0]                   @ 0800AE12
    ldr r0, =0x000F4240                 @ 0800AE16: 1 000 000 mHz = 1 kHz
    movs r1, #0                         @ 0800AE1A
    cmp r3, r1                          @ 0800AE1C
    bcc .L800ac1c_0800AE32              @ 0800AE1E
    bhi .L800ac1c_0800AE26              @ 0800AE20
    cmp r2, r0                          @ 0800AE22
    bcc .L800ac1c_0800AE32              @ 0800AE24
@ reached from 0800AE20 bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AE26:
    movs r1, #2                         @ 0800AE26
    movs r0, r4                         @ 0800AE28
    uxtb r0, r0                         @ 0800AE2A
    bl fn_0800AEE8                      @ 0800AE2C
    b .L800ac1c_end                     @ 0800AE30
@ reached from 0800AE1E bcc (unsigned <) after cmp r3, r1
@              and from 0800AE24 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AE32:
    uxtb r5, r5                         @ 0800AE32
    cmp r5, #2                          @ 0800AE34
    bne .L800ac1c_0800AE5C              @ 0800AE36
    ldr r0, =ar_freq64                  @ 0800AE38
    ldrd r2, r3, [r0]                   @ 0800AE3C
    ldr r0, =0x000C3500                 @ 0800AE40: 800 000 mHz = 800 Hz (80 % of 1 kHz)
    movs r1, #0                         @ 0800AE44
    cmp r3, r1                          @ 0800AE46
    bcc .L800ac1c_0800AE5C              @ 0800AE48
    bhi .L800ac1c_0800AE50              @ 0800AE4A
    cmp r2, r0                          @ 0800AE4C
    bcc .L800ac1c_0800AE5C              @ 0800AE4E
@ reached from 0800AE4A bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AE50:
    movs r1, #2                         @ 0800AE50
    movs r0, r4                         @ 0800AE52
    uxtb r0, r0                         @ 0800AE54
    bl fn_0800AEE8                      @ 0800AE56
    b .L800ac1c_end                     @ 0800AE5A
@ reached from 0800AE36 bne (not equal / non-zero) after cmp r5, #2
@              and from 0800AE48 bcc (unsigned <) after cmp r3, r1
@              and from 0800AE4E bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AE5C:
    ldr r0, =ar_freq64                  @ 0800AE5C
    ldrd r2, r3, [r0]                   @ 0800AE60
    ldr r0, =0x000186A0                 @ 0800AE64: 100 000 mHz = 100 Hz
    movs r1, #0                         @ 0800AE66
    cmp r3, r1                          @ 0800AE68
    bcc .L800ac1c_0800AE7E              @ 0800AE6A
    bhi .L800ac1c_0800AE72              @ 0800AE6C
    cmp r2, r0                          @ 0800AE6E
    bcc .L800ac1c_0800AE7E              @ 0800AE70
@ reached from 0800AE6C bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AE72:
    movs r1, #1                         @ 0800AE72
    movs r0, r4                         @ 0800AE74
    uxtb r0, r0                         @ 0800AE76
    bl fn_0800AEE8                      @ 0800AE78
    b .L800ac1c_end                     @ 0800AE7C
@ reached from 0800AE6A bcc (unsigned <) after cmp r3, r1
@              and from 0800AE70 bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AE7E:
    uxtb r5, r5                         @ 0800AE7E
    cmp r5, #1                          @ 0800AE80
    bne .L800ac1c_0800AEA8              @ 0800AE82
    ldr r0, =ar_freq64                  @ 0800AE84
    ldrd r2, r3, [r0]                   @ 0800AE88
    ldr r0, =0x00013880                 @ 0800AE8C: 80 000 mHz = 80 Hz (80 % of 100 Hz)
    movs r1, #0                         @ 0800AE90
    cmp r3, r1                          @ 0800AE92
    bcc .L800ac1c_0800AEA8              @ 0800AE94
    bhi .L800ac1c_0800AE9C              @ 0800AE96
    cmp r2, r0                          @ 0800AE98
    bcc .L800ac1c_0800AEA8              @ 0800AE9A
@ reached from 0800AE96 bhi (unsigned >) after cmp r3, r1
.L800ac1c_0800AE9C:
    movs r1, #1                         @ 0800AE9C
    movs r0, r4                         @ 0800AE9E
    uxtb r0, r0                         @ 0800AEA0
    bl fn_0800AEE8                      @ 0800AEA2
    b .L800ac1c_end                     @ 0800AEA6
@ reached from 0800AE82 bne (not equal / non-zero) after cmp r5, #1
@              and from 0800AE94 bcc (unsigned <) after cmp r3, r1
@              and from 0800AE9A bcc (unsigned <) after cmp r2, r0
.L800ac1c_0800AEA8:
    movs r1, #0                         @ 0800AEA8
    movs r0, r4                         @ 0800AEAA
    uxtb r0, r0                         @ 0800AEAC
    bl fn_0800AEE8                      @ 0800AEAE

@ FREQ, PULSE, DUTY (which = 0): a new result is ready; remember the decimal point of this range
@ reached from 0800AC68 b (jump)
@              and from 0800AC96 b (jump)
@              and from 0800ACC4 b (jump)
@              ... and 12 more
.L800ac1c_end:
    uxtb r4, r4                         @ 0800AEB2
    cmp r4, #0                          @ 0800AEB4
    bne .L800ac1c_0800AED0              @ 0800AEB6
    movs r0, #1                         @ 0800AEB8
    ldr r1, =ar_new_result              @ 0800AEBA
    strb r0, [r1]                       @ 0800AEBC
    ldr r0, =meter_range                @ 0800AEBE
    ldrb r1, [r0]                       @ 0800AEC0
    ldr r0, =meter_mode                 @ 0800AEC2
    ldrb r0, [r0]                       @ 0800AEC4
    bl decimal_position_for_mode_range  @ 0800AEC6
    ldr r1, =ar_dec_digits              @ 0800AECA
    strb r0, [r1]                       @ 0800AECE
@ reached from 0800AEB6 bne (not equal / non-zero) after cmp r4, #0
.L800ac1c_0800AED0:
    pop {r3, r4, r5, pc}                @ 0800AED0
ENDFUNC frequency_select_range
    .ltorg
