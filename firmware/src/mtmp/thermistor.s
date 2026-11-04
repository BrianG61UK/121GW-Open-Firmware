@ =============================================================================
@ thermistor.s - MTMP: board thermistor (ADC channel 4), cold junction and board offset
@
@ Replaces v2.05 adc_ch4_process 0x0801385A, FUN_08013AAC 0x08013AAC (thermistor table) and FUN_08013CF8 0x08013CF8 (cold junction).
@
@ adc_ch4_process (called by BRD every 20th TIM2 tick with the 12-bit code of PA4): codes below 51 count as open / short (11 in a row set
@ 0x200080AC); otherwise a moving average of up to 10 codes (0x20007FD0, history 0x20007BA8) goes through the thermistor table to a board
@ temperature in 0.01 degC; the board offset 0x20007FBE (EEPROM 0x2E0, calibrated against 23.00 degC in calibration mode) is added into
@ 0x20007FCC; FUN_08013CF8 turns it into the cold-junction EMF 0x20007E7C (uV).
@
@ OF-24: a board temperature outside the conversion range of FUN_08013CF8 (below -20.0 degC or above 100.0 degC) left the cold junction
@ unchanged and set no flag in v2.05; the port takes the existing fault path (0x200080AF and 0x200080AC set, CJ = 0).
@ W7 request: the calibration write cal_record_write(0xC8, ...) is preceded by NVM_ARM CAL.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mtmp.thermistor, "ax", %progbits

@ -----------------------------------------------------------------------------
@ adc_ch4_process - process one thermistor ADC code: average, board temperature, cold junction
@ Replaces : 0x0801385A adc_ch4_process (v2.05)
@ In       : r0 = 12-bit ADC code of channel 4 (PA4)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r9 preserved)
@ Context  : main only
@ RAM      : reads  0x20007BA8, 0x20007FBE, 0x20007FCC, 0x20007FCE, 0x20007FD0, 0x20007FD4, 0x20007FD6, 0x2000808A,
@            0x20008096, 0x200080AC, 0x200080AF, 0x200080B0
@            writes 0x20007BA8, 0x20007E7C, 0x20007FBE, 0x20007FCC, 0x20007FCE, 0x20007FD0, 0x20007FD4, 0x20007FD6,
@            0x20008062, 0x20008096, 0x20008097, 0x200080AC, 0x200080B0
@ Spec     : analysis/hy3131_modes_misc.md 4.2; requests/W7_to_W5.md 1
@ Deviation: none (W7 NVM_ARM)
@ Writes 0x20007FCE (code), 0x20007FD0 (average), 0x20007FD4 (count), 0x20007FD6 (low-code count), 0x20007BA8 (history), 0x200080AC, 0x200080AF,
@ 0x200080B0, 0x20007FCC (board temperature), 0x20007E7C (CJ), 0x20008062 (sub-display redraw).  In calibration mode with the request 0x20008096 set the offset
@ 0x20007FBE = 2300 - T is computed and stored in EEPROM record 0xC8 (0x2E0) by cal_record_write, after NVM_ARM CAL.
@ -----------------------------------------------------------------------------
FUNC adc_ch4_process
    stmdb sp!, {r3, r4, r5, r6, r7, r8, r9, lr} @ 0x0801385A
    movs r4, r0                        @ 0x0801385E
    movs r6, #0                        @ 0x08013860
    movs r7, #0                        @ 0x08013862
    ldr r0, =v_20007FCE                @ 0x08013864 pool 0x08013E54 = 0x20007FCE
    strh r4, [r0, #0]                  @ 0x08013868
    ldr r0, =v_20007FCE                @ 0x0801386A pool 0x08013E54 = 0x20007FCE
    ldrh r0, [r0, #0]                  @ 0x0801386E
    @ ADC code below 51: open or short, no average update
    cmp r0, #51                        @ 0x08013870
    bge .L080138AA                     @ 0x08013872
    movs r0, #0                        @ 0x08013874
    ldr r1, =v_20007FD4                @ 0x08013876 pool 0x08013E58 = 0x20007FD4
    strh r0, [r1, #0]                  @ 0x0801387A
    ldr r0, =v_20007FD6                @ 0x0801387C pool 0x08013E5C = 0x20007FD6
    ldrh r0, [r0, #0]                  @ 0x08013880
    adds r0, r0, #1                    @ 0x08013882
    ldr r1, =v_20007FD6                @ 0x08013884 pool 0x08013E5C = 0x20007FD6
    strh r0, [r1, #0]                  @ 0x08013888
    ldr r0, =v_20007FD6                @ 0x0801388A pool 0x08013E5C = 0x20007FD6
    ldrh r0, [r0, #0]                  @ 0x0801388E
    cmp r0, #11                        @ 0x08013890
    blt .L080138A4                     @ 0x08013892
    movs r0, #10                       @ 0x08013894
    ldr r1, =v_20007FD6                @ 0x08013896 pool 0x08013E5C = 0x20007FD6
    strh r0, [r1, #0]                  @ 0x0801389A
    movs r0, #1                        @ 0x0801389C
    ldr r1, =v_200080AC                @ 0x0801389E pool 0x08013E60 = 0x200080AC
    strb r0, [r1, #0]                  @ 0x080138A2
.L080138A4:                              @ reached from 0x08013892 blt
    movs r0, #1                        @ 0x080138A4
    movs r6, r0                        @ 0x080138A6
    b .L080139AC                       @ 0x080138A8
.L080138AA:                              @ reached from 0x08013872 bge
    @ ---- good code: moving average of up to 10 codes in 0x20007BA8 (0x20007FD4 = count) ----
    movs r0, #0                        @ 0x080138AA
    ldr r1, =v_20007FD6                @ 0x080138AC pool 0x08013E5C = 0x20007FD6
    strh r0, [r1, #0]                  @ 0x080138B0
    movs r0, #0                        @ 0x080138B2
    ldr r1, =v_200080AC                @ 0x080138B4 pool 0x08013E60 = 0x200080AC
    strb r0, [r1, #0]                  @ 0x080138B8
    ldr r0, =v_20007FD4                @ 0x080138BA pool 0x08013E58 = 0x20007FD4
    ldrh r0, [r0, #0]                  @ 0x080138BE
    cmp r0, #10                        @ 0x080138C0
    bne .L08013942                     @ 0x080138C2
    movs r0, #1                        @ 0x080138C4
    movs r5, r0                        @ 0x080138C6
.L080138C8:                              @ reached from 0x080138FE b
    movs r0, r5                        @ 0x080138C8
    ldr r1, =v_20007FD4                @ 0x080138CA pool 0x08013E58 = 0x20007FD4
    ldrh r1, [r1, #0]                  @ 0x080138CE
    uxth r0, r0                        @ 0x080138D0
    cmp r0, r1                         @ 0x080138D2
    bcs .L08013900                     @ 0x080138D4
    ldr r0, =v_20007BA8                @ 0x080138D6 pool 0x08013E64 = 0x20007BA8
    ldr r1, =v_20007FD4                @ 0x080138DA pool 0x08013E58 = 0x20007FD4
    ldrh r1, [r1, #0]                  @ 0x080138DE
    uxth r5, r5                        @ 0x080138E0
    subs r1, r1, r5                    @ 0x080138E2
    ldr r2, =v_20007BA8                @ 0x080138E4 pool 0x08013E64 = 0x20007BA8
    ldr r3, =v_20007FD4                @ 0x080138E8 pool 0x08013E58 = 0x20007FD4
    ldrh r3, [r3, #0]                  @ 0x080138EC
    subs r3, r3, #1                    @ 0x080138EE
    uxth r5, r5                        @ 0x080138F0
    subs r3, r3, r5                    @ 0x080138F2
    ldrh.w r2, [r2, r3, lsl #1]        @ 0x080138F4
    strh.w r2, [r0, r1, lsl #1]        @ 0x080138F8
    adds r5, r5, #1                    @ 0x080138FC
    b .L080138C8                       @ 0x080138FE
.L08013900:                              @ reached from 0x080138D4 bcs
    ldr r0, =v_20007FCE                @ 0x08013900 pool 0x08013E54 = 0x20007FCE
    ldrh r0, [r0, #0]                  @ 0x08013904
    ldr r1, =v_20007BA8                @ 0x08013906 pool 0x08013E64 = 0x20007BA8
    strh r0, [r1, #0]                  @ 0x0801390A
    movs r0, #0                        @ 0x0801390C
    movs r5, r0                        @ 0x0801390E
.L08013910:                              @ reached from 0x0801392C b
    movs r0, r5                        @ 0x08013910
    ldr r1, =v_20007FD4                @ 0x08013912 pool 0x08013E58 = 0x20007FD4
    ldrh r1, [r1, #0]                  @ 0x08013916
    uxth r0, r0                        @ 0x08013918
    cmp r0, r1                         @ 0x0801391A
    bcs .L0801392E                     @ 0x0801391C
    ldr r0, =v_20007BA8                @ 0x0801391E pool 0x08013E64 = 0x20007BA8
    uxth r5, r5                        @ 0x08013922
    ldrh.w r0, [r0, r5, lsl #1]        @ 0x08013924
    adds r7, r0, r7                    @ 0x08013928
    adds r5, r5, #1                    @ 0x0801392A
    b .L08013910                       @ 0x0801392C
.L0801392E:                              @ reached from 0x0801391C bcs
    uxth r7, r7                        @ 0x0801392E
    ldr r0, =v_20007FD4                @ 0x08013930 pool 0x08013E58 = 0x20007FD4
    ldrh r0, [r0, #0]                  @ 0x08013934
    sdiv r0, r7, r0                    @ 0x08013936
    ldr r1, =v_20007FD0                @ 0x0801393A pool 0x08013E68 = 0x20007FD0
    strh r0, [r1, #0]                  @ 0x0801393E
    b .L0801398C                       @ 0x08013940
.L08013942:                              @ reached from 0x080138C2 bne
    ldr r0, =v_20007FCE                @ 0x08013942 pool 0x08013E54 = 0x20007FCE
    ldrh r0, [r0, #0]                  @ 0x08013946
    ldr r1, =v_20007BA8                @ 0x08013948 pool 0x08013E64 = 0x20007BA8
    ldr r2, =v_20007FD4                @ 0x0801394C pool 0x08013E58 = 0x20007FD4
    ldrh r2, [r2, #0]                  @ 0x08013950
    strh.w r0, [r1, r2, lsl #1]        @ 0x08013952
    movs r0, #0                        @ 0x08013956
    movs r5, r0                        @ 0x08013958
.L0801395A:                              @ reached from 0x08013976 b
    ldr r0, =v_20007FD4                @ 0x0801395A pool 0x08013E58 = 0x20007FD4
    ldrh r0, [r0, #0]                  @ 0x0801395E
    movs r1, r5                        @ 0x08013960
    uxth r1, r1                        @ 0x08013962
    cmp r0, r1                         @ 0x08013964
    bcc .L08013978                     @ 0x08013966
    ldr r0, =v_20007BA8                @ 0x08013968 pool 0x08013E64 = 0x20007BA8
    uxth r5, r5                        @ 0x0801396C
    ldrh.w r0, [r0, r5, lsl #1]        @ 0x0801396E
    adds r7, r0, r7                    @ 0x08013972
    adds r5, r5, #1                    @ 0x08013974
    b .L0801395A                       @ 0x08013976
.L08013978:                              @ reached from 0x08013966 bcc
    uxth r7, r7                        @ 0x08013978
    ldr r0, =v_20007FD4                @ 0x0801397A pool 0x08013E58 = 0x20007FD4
    ldrh r0, [r0, #0]                  @ 0x0801397E
    adds r0, r0, #1                    @ 0x08013980
    sdiv r0, r7, r0                    @ 0x08013982
    ldr r1, =v_20007FD0                @ 0x08013986 pool 0x08013E68 = 0x20007FD0
    strh r0, [r1, #0]                  @ 0x0801398A
.L0801398C:                              @ reached from 0x08013940 b
    ldr r0, =v_20007FD4                @ 0x0801398C pool 0x08013E58 = 0x20007FD4
    ldrh r0, [r0, #0]                  @ 0x08013990
    adds r0, r0, #1                    @ 0x08013992
    ldr r1, =v_20007FD4                @ 0x08013994 pool 0x08013E58 = 0x20007FD4
    strh r0, [r1, #0]                  @ 0x08013998
    ldr r0, =v_20007FD4                @ 0x0801399A pool 0x08013E58 = 0x20007FD4
    ldrh r0, [r0, #0]                  @ 0x0801399E
    cmp r0, #11                        @ 0x080139A0
    blt .L080139AC                     @ 0x080139A2
    movs r0, #10                       @ 0x080139A4
    ldr r1, =v_20007FD4                @ 0x080139A6 pool 0x08013E58 = 0x20007FD4
    strh r0, [r1, #0]                  @ 0x080139AA
.L080139AC:                              @ reached from 0x080138A8 b, 0x080139A2 blt
    uxth r6, r6                        @ 0x080139AC
    cmp r6, #0                         @ 0x080139AE
    bne .L08013A8E                     @ 0x080139B0
    @ ---- board temperature: thermistor table (fn_08013AAC) of the average, 0.01 degC ----
    ldr r0, =v_20007FD0                @ 0x080139B2 pool 0x08013E68 = 0x20007FD0
    ldrh r0, [r0, #0]                  @ 0x080139B6
    bl fn_08013AAC                     @ 0x080139B8
    ldr r1, =v_20007FCC                @ 0x080139BC pool 0x08013E6C = 0x20007FCC
    strh r0, [r1, #0]                  @ 0x080139C0
    @ calibration mode with the request 0x20008096: offset 0x20007FBE = 2300 - T, stored in EEPROM record 0xC8
    ldr r0, =v_2000808A                @ 0x080139C2 pool 0x08013E70 = 0x2000808A
    ldrb r0, [r0, #0]                  @ 0x080139C6
    cmp r0, #0                         @ 0x080139C8
    beq .L08013A06                     @ 0x080139CA
    ldr r0, =v_20008096                @ 0x080139CC pool 0x08013E74 = 0x20008096
    ldrb r0, [r0, #0]                  @ 0x080139D0
    cmp r0, #0                         @ 0x080139D2
    beq .L08013A06                     @ 0x080139D4
    movs r0, #0                        @ 0x080139D6
    ldr r1, =v_20008096                @ 0x080139D8 pool 0x08013E74 = 0x20008096
    strb r0, [r1, #0]                  @ 0x080139DC
    movs r0, #3                        @ 0x080139DE
    ldr r1, =v_20008097                @ 0x080139E0 pool 0x08013E78 = 0x20008097
    strb r0, [r1, #0]                  @ 0x080139E4
    movw r0, #2300                     @ 0x080139E6
    ldr r1, =v_20007FCC                @ 0x080139EA pool 0x08013E6C = 0x20007FCC
    ldrh r1, [r1, #0]                  @ 0x080139EE
    subs r0, r0, r1                    @ 0x080139F0
    ldr r1, =v_20007FBE                @ 0x080139F2 pool 0x08013E7C = 0x20007FBE
    strh r0, [r1, #0]                  @ 0x080139F6
    NVM_ARM CAL                             @ W7: cal_record_write is a CAL-class EEPROM write; arm NVM for exactly this call
    ldr r0, =v_20007FBE                @ 0x080139F8 pool 0x08013E7C = 0x20007FBE
    ldrsh.w r1, [r0]                   @ 0x080139FC
    movs r0, #200                      @ 0x08013A00
    bl cal_record_write                @ 0x08013A02
.L08013A06:                              @ reached from 0x080139CA beq, 0x080139D4 beq
    @ add the board offset 0x20007FBE
    ldr r0, =v_20007FCC                @ 0x08013A06 pool 0x08013E6C = 0x20007FCC
    ldrh r0, [r0, #0]                  @ 0x08013A0A
    ldr r1, =v_20007FBE                @ 0x08013A0C pool 0x08013E7C = 0x20007FBE
    ldrh r1, [r1, #0]                  @ 0x08013A10
    adds r0, r1, r0                    @ 0x08013A12
    ldr r1, =v_20007FCC                @ 0x08013A14 pool 0x08013E6C = 0x20007FCC
    strh r0, [r1, #0]                  @ 0x08013A18
    @ no thermistor fault (0x200080AF = 0): cold junction from the board temperature (fn_08013CF8); sign and |T|/10 as v2.05 (one's complement for negative values)
    ldr r0, =v_200080AF                @ 0x08013A1A pool 0x08013E80 = 0x200080AF
    ldrb r0, [r0, #0]                  @ 0x08013A1E
    cmp r0, #0                         @ 0x08013A20
    bne .L08013A66                     @ 0x08013A22
    movs r0, #0                        @ 0x08013A24
    ldr r1, =v_200080B0                @ 0x08013A26 pool 0x08013E84 = 0x200080B0
    strb r0, [r1, #0]                  @ 0x08013A2A
    ldr r0, =v_20007FCC                @ 0x08013A2C pool 0x08013E6C = 0x20007FCC
    ldrh r0, [r0, #0]                  @ 0x08013A30
    lsls r0, r0, #16                   @ 0x08013A32
    bpl .L08013A48                     @ 0x08013A34
    movs r0, #1                        @ 0x08013A36
    mov r8, r0                         @ 0x08013A38
    ldr r0, =v_20007FCC                @ 0x08013A3A pool 0x08013E6C = 0x20007FCC
    ldrsh.w r0, [r0]                   @ 0x08013A3E
    mvns r0, r0                        @ 0x08013A42
    mov r9, r0                         @ 0x08013A44
    b .L08013A56                       @ 0x08013A46
.L08013A48:                              @ reached from 0x08013A34 bpl
    movs r0, #0                        @ 0x08013A48
    mov r8, r0                         @ 0x08013A4A
    ldr r0, =v_20007FCC                @ 0x08013A4C pool 0x08013E6C = 0x20007FCC
    ldrsh.w r0, [r0]                   @ 0x08013A50
    mov r9, r0                         @ 0x08013A54
.L08013A56:                              @ reached from 0x08013A46 b
    movs r0, #10                       @ 0x08013A56
    sdiv r1, r9, r0                    @ 0x08013A58
    mov r0, r8                         @ 0x08013A5C
    uxtb r0, r0                        @ 0x08013A5E
    bl fn_08013CF8                     @ 0x08013A60
    b .L08013A8E                       @ 0x08013A64
.L08013A66:                              @ reached from 0x08013A22 bne
    @ fault: count 10 more samples (0x200080B0), then 0x200080AC = 1
    ldr r0, =v_200080B0                @ 0x08013A66 pool 0x08013E84 = 0x200080B0
    ldrb r0, [r0, #0]                  @ 0x08013A6A
    adds r0, r0, #1                    @ 0x08013A6C
    ldr r1, =v_200080B0                @ 0x08013A6E pool 0x08013E84 = 0x200080B0
    strb r0, [r1, #0]                  @ 0x08013A72
    ldr r0, =v_200080B0                @ 0x08013A74 pool 0x08013E84 = 0x200080B0
    ldrb r0, [r0, #0]                  @ 0x08013A78
    cmp r0, #11                        @ 0x08013A7A
    blt .L08013A8E                     @ 0x08013A7C
    movs r0, #10                       @ 0x08013A7E
    ldr r1, =v_200080B0                @ 0x08013A80 pool 0x08013E84 = 0x200080B0
    strb r0, [r1, #0]                  @ 0x08013A84
    movs r0, #1                        @ 0x08013A86
    ldr r1, =v_200080AC                @ 0x08013A88 pool 0x08013E60 = 0x200080AC
    strb r0, [r1, #0]                  @ 0x08013A8C
.L08013A8E:                              @ reached from 0x080139B0 bne, 0x08013A64 b, 0x08013A7C blt
    @ cold-junction fault: sub-display redraw request and CJ = 0
    ldr r0, =v_200080AC                @ 0x08013A8E pool 0x08013E60 = 0x200080AC
    ldrb r0, [r0, #0]                  @ 0x08013A92
    cmp r0, #1                         @ 0x08013A94
    bne .L08013AA8                     @ 0x08013A96
    movs r0, #1                        @ 0x08013A98
    ldr r1, =v_20008062                @ 0x08013A9A pool 0x08013E34 = 0x20008062
    strb r0, [r1, #0]                  @ 0x08013A9E
    movs r0, #0                        @ 0x08013AA0
    ldr r1, =v_20007E7C                @ 0x08013AA2 pool 0x08013E88 = 0x20007E7C
    str r0, [r1, #0]                   @ 0x08013AA6
.L08013AA8:                              @ reached from 0x08013A96 bne
    ldmia.w sp!, {r0, r4, r5, r6, r7, r8, r9, pc} @ 0x08013AA8
    .ltorg
ENDFUNC adc_ch4_process

@ -----------------------------------------------------------------------------
@ fn_08013AAC - thermistor table: ADC average to board temperature
@ Replaces : 0x08013AAC FUN_08013AAC (v2.05)
@ In       : r0 = average ADC code (518 .. 3672 valid)
@ Out      : r0 = temperature in 0.01 degC (signed 16 bit), 0 and 0x200080AF = 1 outside the range
@ Clobbers : r0-r3, r12, flags (r4-r9 preserved)
@ Context  : main only
@ RAM      : reads  v205_tab_08028DD0
@            writes 0x200080AE, 0x200080AF
@ Spec     : analysis/hy3131_modes_misc.md 4.2
@ Deviation: none
@ With i the first table index where code >= TH[i]: T = 500 i - 3500 + f2iz(f32((TH[i-1] - code) * 500) / f32(TH[i-1] - TH[i])).
@ -----------------------------------------------------------------------------
FUNC fn_08013AAC
    stmdb sp!, {r3, r4, r5, r6, r7, r8, r9, lr} @ 0x08013AAC
    movs r4, r0                        @ 0x08013AB0
    movs r6, #1                        @ 0x08013AB2
    movs.w r8, #0                      @ 0x08013AB4
    movs r0, #0                        @ 0x08013AB8
    ldr r1, =v_200080AE                @ 0x08013ABA pool 0x08013E8C = 0x200080AE
    strb r0, [r1, #0]                  @ 0x08013ABE
    uxth r4, r4                        @ 0x08013AC0
    @ valid for 518 <= code <= 3672 (table 0x08028DD0, descending); otherwise T = 0 and 0x200080AF = 1
    movw r0, #518                      @ 0x08013AC2
    cmp r4, r0                         @ 0x08013AC6
    blt .L08013B62                     @ 0x08013AC8
    uxth r4, r4                        @ 0x08013ACA
    movw r0, #3673                     @ 0x08013ACC
    cmp r4, r0                         @ 0x08013AD0
    bge .L08013B62                     @ 0x08013AD2
    @ search the first table index with code >= TH[i]
    movs r0, #0                        @ 0x08013AD4
    movs r5, r0                        @ 0x08013AD6
.L08013AD8:                              @ reached from 0x08013AF2 b, 0x08013AF8 b
    uxtb r6, r6                        @ 0x08013AD8
    cmp r6, #0                         @ 0x08013ADA
    beq .L08013AFA                     @ 0x08013ADC
    movs r0, r4                        @ 0x08013ADE
    ldr r1, =v205_tab_08028DD0         @ 0x08013AE0 pool 0x08013E90 = 0x08028DD0
    uxtb r5, r5                        @ 0x08013AE4
    ldrh.w r1, [r1, r5, lsl #1]        @ 0x08013AE6
    uxth r0, r0                        @ 0x08013AEA
    cmp r0, r1                         @ 0x08013AEC
    bcs .L08013AF4                     @ 0x08013AEE
    adds r5, r5, #1                    @ 0x08013AF0
    b .L08013AD8                       @ 0x08013AF2
.L08013AF4:                              @ reached from 0x08013AEE bcs
    movs r0, #0                        @ 0x08013AF4
    movs r6, r0                        @ 0x08013AF6
    b .L08013AD8                       @ 0x08013AF8
.L08013AFA:                              @ reached from 0x08013ADC beq
    @ T = 500 i - 3500 + f2iz(f32((TH[i-1] - code) * 500) / f32(TH[i-1] - TH[i]))
    uxtb r5, r5                        @ 0x08013AFA
    mov.w r0, #500                     @ 0x08013AFC
    mul.w r0, r0, r5                   @ 0x08013B00
    subw r0, r0, #3500                 @ 0x08013B04
    movs r7, r0                        @ 0x08013B08
    ldr r0, =v205_tab_08028DD0         @ 0x08013B0A pool 0x08013E90 = 0x08028DD0
    uxtb r5, r5                        @ 0x08013B0E
    add.w r0, r0, r5, lsl #1           @ 0x08013B10
    ldrh.w r0, [r0, #-2]               @ 0x08013B14
    uxth r4, r4                        @ 0x08013B18
    subs r0, r0, r4                    @ 0x08013B1A
    mov.w r1, #500                     @ 0x08013B1C
    muls r0, r1                        @ 0x08013B20
    bl fn_08012F60                     @ 0x08013B22
    mov r9, r0                         @ 0x08013B26
    ldr r0, =v205_tab_08028DD0         @ 0x08013B28 pool 0x08013E90 = 0x08028DD0
    uxtb r5, r5                        @ 0x08013B2C
    add.w r0, r0, r5, lsl #1           @ 0x08013B2E
    ldrh.w r0, [r0, #-2]               @ 0x08013B32
    ldr r1, =v205_tab_08028DD0         @ 0x08013B36 pool 0x08013E90 = 0x08028DD0
    uxtb r5, r5                        @ 0x08013B3A
    ldrh.w r1, [r1, r5, lsl #1]        @ 0x08013B3C
    subs r0, r0, r1                    @ 0x08013B40
    bl fn_08012F60                     @ 0x08013B42
    movs r1, r0                        @ 0x08013B46
    mov r0, r9                         @ 0x08013B48
    bl fn_08012F94                     @ 0x08013B4A
    bl fn_08013370                     @ 0x08013B4E
    mov r8, r0                         @ 0x08013B52
    adds.w r8, r7, r8                  @ 0x08013B54
    movs r0, #0                        @ 0x08013B58
    ldr r1, =v_200080AF                @ 0x08013B5A pool 0x08013E80 = 0x200080AF
    strb r0, [r1, #0]                  @ 0x08013B5E
    b .L08013B6E                       @ 0x08013B60
.L08013B62:                              @ reached from 0x08013AC8 blt, 0x08013AD2 bge
    @ out of range: T = 0, fault flag 0x200080AF = 1
    movs r0, #0                        @ 0x08013B62
    mov r8, r0                         @ 0x08013B64
    movs r0, #1                        @ 0x08013B66
    ldr r1, =v_200080AF                @ 0x08013B68 pool 0x08013E80 = 0x200080AF
    strb r0, [r1, #0]                  @ 0x08013B6C
.L08013B6E:                              @ reached from 0x08013B60 b
    mov r0, r8                         @ 0x08013B6E
    sxth r0, r0                        @ 0x08013B70
    ldmia.w sp!, {r1, r4, r5, r6, r7, r8, r9, pc} @ 0x08013B72
    .ltorg
ENDFUNC fn_08013AAC

@ -----------------------------------------------------------------------------
@ fn_08013CF8 - cold-junction EMF from the board temperature
@ Replaces : 0x08013CF8 FUN_08013CF8 (v2.05)
@ In       : r0 = 1 if the board temperature is negative
@            r1 = a: |T| in 0.1 degC (for negative T the one's complement value |T| - 1 divided by 10)
@ Out      : - (0x20007E7C = CJ in uV)
@ Clobbers : r0-r3, r12, flags (r4-r7 preserved)
@ Context  : main only
@ RAM      : reads  mtmp_tc_tab_k (the NIST K table, OF-56; v2.05 0x08025CF8)
@            writes 0x20007E7C, 0x200080AC, 0x200080AF
@ Spec     : analysis/hy3131_modes_misc.md 4.2; ORIGINAL_FIRMWARE_ISSUES.md OF-24
@ Deviation: OF-24; IMP-10 (production: the table of the selected type, mtmp/tctype.s)
@ Positive, a <= 1000: k = a / 100 + 21, CJ = t[k] + (a % 100) * ((t[k+1] - t[k]) * 10 / 100) / 10.  Negative, a < 201: k = 21 - a / 100,
@ CJ = t[k] - (a % 100) * ((t[k] - t[k-1]) * 10 / 100) / 10 (t = thermocouple table 0x08025CF8, t[21] = 0).  Otherwise (OF-24) the fault path:
@ 0x200080AF = 1, 0x200080AC = 1, CJ = 0.
@ -----------------------------------------------------------------------------
FUNC fn_08013CF8
    push {r4, r5, r6, r7, lr}          @ 0x08013CF8
    @ r7 = 21 (index of t = 0 uV, 0 degC); r0 = negative flag, r1 = a (0.1 degC)
    movs r7, #21                       @ 0x08013CFA
    uxtb r0, r0                        @ 0x08013CFC
    cmp r0, #0                         @ 0x08013CFE
    beq .L08013D06                     @ 0x08013D00
    cmp r1, #201                       @ 0x08013D02
    bge .Lcj_fault                          @ OF-24: negative and a >= 201 (below -20.0 degC): fault path (v2.05 left CJ unchanged, 0x08013D04)
.L08013D06:                              @ reached from 0x08013D00 beq
    cmp.w r1, #1000                    @ 0x08013D06
    bgt .Lcj_fault                        @ OF-24: a > 1000 (above 100.0 degC) (v2.05 0x08013D0A)
    @ r2 = a / 100 (whole tens of degrees), r3 = a % 100
    movs.w ip, #100                    @ 0x08013D0C
    sdiv ip, r1, ip                    @ 0x08013D10
    mov r2, ip                         @ 0x08013D14
    movs.w ip, #100                    @ 0x08013D16
    sdiv lr, r1, ip                    @ 0x08013D1A
    mls ip, ip, lr, r1                 @ 0x08013D1E
    mov r3, ip                         @ 0x08013D22
    uxtb r0, r0                        @ 0x08013D24
    cmp r0, #0                         @ 0x08013D26
    beq .L08013D80                     @ 0x08013D28
    @ negative: k = 21 - a / 100, CJ = t[k] - (a % 100) * ((t[k] - t[k-1]) * 10 / 100) / 10
    subs r7, r7, r2                    @ 0x08013D2A
    ldr ip, =mtmp_tc_descp             @ IMP-10: descriptor of the selected type ...
    ldr ip, [ip]
    ldr ip, [ip]                       @ ... its table (K: 0x08025CF8)
    uxtb r7, r7                        @ 0x08013D30
    ldr.w ip, [ip, r7, lsl #2]         @ 0x08013D32
    mov r4, ip                         @ 0x08013D36
    ldr ip, =mtmp_tc_descp             @ IMP-10: descriptor of the selected type ...
    ldr ip, [ip]
    ldr ip, [ip]                       @ ... its table (K: 0x08025CF8)
    uxtb r7, r7                        @ 0x08013D3C
    add.w ip, ip, r7, lsl #2           @ 0x08013D3E
    ldr.w ip, [ip, #-4]                @ 0x08013D42
    mov r5, ip                         @ 0x08013D46
    mvns.w ip, r5                      @ 0x08013D48
    mvns.w lr, r4                      @ 0x08013D4C
    subs.w ip, ip, lr                  @ 0x08013D50
    movs.w lr, #10                     @ 0x08013D54
    mul.w ip, lr, ip                   @ 0x08013D58
    movs.w lr, #100                    @ 0x08013D5C
    sdiv ip, ip, lr                    @ 0x08013D60
    mul.w ip, r3, ip                   @ 0x08013D64
    movs.w lr, #10                     @ 0x08013D68
    sdiv ip, ip, lr                    @ 0x08013D6C
    mov r6, ip                         @ 0x08013D70
    subs.w ip, r4, r6                  @ 0x08013D72
    ldr lr, =v_20007E7C                @ 0x08013D76 pool 0x08013E88 = 0x20007E7C
    str.w ip, [lr]                     @ 0x08013D7A
    b .L08013DCC                       @ 0x08013D7E
.L08013D80:                              @ reached from 0x08013D28 beq
    @ positive: k = a / 100 + 21, CJ = t[k] + (a % 100) * ((t[k+1] - t[k]) * 10 / 100) / 10
    adds r7, r2, r7                    @ 0x08013D80
    ldr ip, =mtmp_tc_descp             @ IMP-10: descriptor of the selected type ...
    ldr ip, [ip]
    ldr ip, [ip]                       @ ... its table (K: 0x08025CF8)
    uxtb r7, r7                        @ 0x08013D86
    ldr.w ip, [ip, r7, lsl #2]         @ 0x08013D88
    mov r4, ip                         @ 0x08013D8C
    ldr ip, =mtmp_tc_descp             @ IMP-10: descriptor of the selected type ...
    ldr ip, [ip]
    ldr ip, [ip]                       @ ... its table (K: 0x08025CF8)
    uxtb r7, r7                        @ 0x08013D92
    add.w ip, ip, r7, lsl #2           @ 0x08013D94
    ldr.w ip, [ip, #4]                 @ 0x08013D98
    mov r5, ip                         @ 0x08013D9C
    subs.w ip, r5, r4                  @ 0x08013D9E
    movs.w lr, #10                     @ 0x08013DA2
    mul.w ip, lr, ip                   @ 0x08013DA6
    movs.w lr, #100                    @ 0x08013DAA
    sdiv ip, ip, lr                    @ 0x08013DAE
    mul.w ip, r3, ip                   @ 0x08013DB2
    movs.w lr, #10                     @ 0x08013DB6
    sdiv ip, ip, lr                    @ 0x08013DBA
    mov r6, ip                         @ 0x08013DBE
    adds.w ip, r6, r4                  @ 0x08013DC0
    ldr lr, =v_20007E7C                @ 0x08013DC4 pool 0x08013E88 = 0x20007E7C
    str.w ip, [lr]                     @ 0x08013DC8
.L08013DCC:                              @ reached from 0x08013D7E b
    movs.w ip, #0                      @ 0x08013DCC
    mov r3, ip                         @ 0x08013DD0
.L08013DD2:                              @ reached from 0x08013D04 bge, 0x08013D0A bgt
    pop {r4, r5, r6, r7, pc}
.Lcj_fault:
    movs r0, #1
    ldr r1, =v_200080AF
    strb r0, [r1]                           @ board temperature outside the conversion range: thermistor fault flag
    ldr r1, =v_200080AC
    strb r0, [r1]                           @ cold-junction fault: adc_ch4_process zeroes CJ and requests a redraw (0x08013A8E)
    movs r0, #0
    ldr r1, =v_20007E7C
    str r0, [r1]                            @ CJ = 0 now
    pop {r4, r5, r6, r7, pc}
    .ltorg
ENDFUNC fn_08013CF8
