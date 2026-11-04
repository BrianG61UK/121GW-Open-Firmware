@ =============================================================================
@ counter.s - MFRQ: HY3131 counter results, frequency computation and the AC gate-time toggle
@
@ Replaces v2.05 FUN_0800AA00 0x0800AA00 (counter event handler), counter_parse_and_restart 0x0800AB48, counter_compute_frequency
@ 0x0800B610 and FUN_0800ED64 0x0800ED64.
@
@ The HY3131 counter (DS p36, analysis/hy3131_model.md 4.3) counts SYSCLK ticks CTA from a preset up to overflow, then to the end of the
@ running input cycle; CTB = whole input cycles, CTC = ticks while the input is high.  T = (0x1000000 - (preset << 8)) + CTA_final
@ is the gate in ticks (0x20007E48).  Frequency f = ref * CTB * 10 / (T / 10) in mHz (0x20007C40) with ref = 10 x SYSCLK (0x20007E18,
@ EEPROM 0x104 if 40 000 000 <= ref < 60 000 001, else 49 152 050).
@
@ Port: the registers read by FUN_0800AB48 are the mirror bytes 0x15..0x1D (CTC, CTB, CTA), read by HY before this handler runs.
@ Calibration (EEPROM) access: FUN_0800B6F0 (freq.s) writes the reference through cal_record_write with NVM armed (W7 request 1).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mfrq.counter, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800AA00 - counter result (CTF) handler
@ Replaces : 0x0800AA00 FUN_0800AA00 (v2.05)
@ In       : - (mirror bytes 0x14..0x1D read by HY)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x200080BA acdc_active, 0x2000803C meter_mode, 0x2000803D meter_range, 0x2000803E, 0x200080A5
@            writes 0x20007FC0, 0x20007FC2, 0x20008060, 0x20008062
@ Spec     : analysis/hy3131_model.md 4.3; hy3131_modes_misc.md 5.1
@ Deviation: none
@ Called by hy3131_service_irq when INTF & INTE has CTF (bit 0).  Returns at once in the VA modes 13, 14, 15.  Otherwise: counter_parse_and_restart; 0x20007FC2 = 0
@ (the AC-mode no-signal tick count, which fn_0800ED64 counts up); by mode: 6 FREQ -> frequency_select_range(0, range) (AR), 7 PULSE -> fn_0800B070, 8 DUTY ->
@ fn_0800B2D8, 12 CAP -> fn_0800B33C (MRES), 0 / 2 / 4 / 16 / 18 / 20 -> frequency_select_range(1, 0x2000803E); then 0x20007FC0 = 0 (FREQ / PULSE / DUTY
@ no-signal tick count of IRQ28); modes 6, 7, 8: 0x20008060 = 1 (unit annunciator refresh); modes 2 (AC+DC off), 4, 16, 18, 20: FUN_0801A440 (LCD unit
@ annunciators) and, when the setting byte 0x200080A5 is 0, 0x20008062 = 1 (sub-display redraw).
@ -----------------------------------------------------------------------------
FUNC fn_0800AA00
    push {r7, lr}                      @ 0x0800AA00
    ldr r0, =meter_mode                @ 0x0800AA02 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AA06
    cmp r0, #13                        @ 0x0800AA08
    beq .L0800AA20                     @ 0x0800AA0A
    ldr r0, =meter_mode                @ 0x0800AA0C pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AA10
    cmp r0, #14                        @ 0x0800AA12
    beq .L0800AA20                     @ 0x0800AA14
    ldr r0, =meter_mode                @ 0x0800AA16 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AA1A
    cmp r0, #15                        @ 0x0800AA1C
    bne .L0800AA22                     @ 0x0800AA1E
.L0800AA20:                              @ reached from 0x0800AA0A beq, 0x0800AA14 beq
    b .L0800AB46                       @ 0x0800AA20
.L0800AA22:                              @ reached from 0x0800AA1E bne
    @ ---- counter result: parse CTA / CTB / CTC, restart the counter, clear the AC no-signal count 0x20007FC2 ----
    bl counter_parse_and_restart       @ 0x0800AA22
    movs r0, #0                        @ 0x0800AA26
    ldr r1, =v_20007FC2                @ 0x0800AA28 pool 0x0800B534 = 0x20007FC2
    strh r0, [r1, #0]                  @ 0x0800AA2C
    ldr r0, =meter_mode                @ 0x0800AA2E pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AA32
    cmp r0, #0                         @ 0x0800AA34
    beq .L0800AA7E                     @ 0x0800AA36
    cmp r0, #2                         @ 0x0800AA38
    beq .L0800AA7E                     @ 0x0800AA3A
    cmp r0, #4                         @ 0x0800AA3C
    beq .L0800AA7E                     @ 0x0800AA3E
    cmp r0, #6                         @ 0x0800AA40
    beq .L0800AA5E                     @ 0x0800AA42
    cmp r0, #7                         @ 0x0800AA44
    beq .L0800AA6C                     @ 0x0800AA46
    cmp r0, #8                         @ 0x0800AA48
    beq .L0800AA72                     @ 0x0800AA4A
    cmp r0, #12                        @ 0x0800AA4C
    beq .L0800AA78                     @ 0x0800AA4E
    cmp r0, #16                        @ 0x0800AA50
    beq .L0800AA7E                     @ 0x0800AA52
    cmp r0, #18                        @ 0x0800AA54
    beq .L0800AA7E                     @ 0x0800AA56
    cmp r0, #20                        @ 0x0800AA58
    beq .L0800AA7E                     @ 0x0800AA5A
    b .L0800AA8A                       @ 0x0800AA5C
.L0800AA5E:                              @ reached from 0x0800AA42 beq
    ldr r0, =meter_range               @ 0x0800AA5E pool 0x0800B064 = 0x2000803D
    ldrb r1, [r0, #0]                  @ 0x0800AA62
    movs r0, #0                        @ 0x0800AA64
    bl frequency_select_range          @ 0x0800AA66
    b .L0800AA8A                       @ 0x0800AA6A
.L0800AA6C:                              @ reached from 0x0800AA46 beq
    bl fn_0800B070                     @ 0x0800AA6C
    b .L0800AA8A                       @ 0x0800AA70
.L0800AA72:                              @ reached from 0x0800AA4A beq
    bl fn_0800B2D8                     @ 0x0800AA72
    b .L0800AA8A                       @ 0x0800AA76
.L0800AA78:                              @ reached from 0x0800AA4E beq
    bl fn_0800B33C                     @ 0x0800AA78
    b .L0800AA8A                       @ 0x0800AA7C
.L0800AA7E:                              @ reached from 0x0800AA36 beq, 0x0800AA3A beq, 0x0800AA3E beq, 0x0800AA52 beq, 0x0800AA56 beq, 0x0800AA5A beq
    @ AC modes (0, 2, 4, 16, 18, 20): frequency_select_range(1, 0x2000803E)
    ldr r0, =v_2000803E                @ 0x0800AA7E pool 0x0800B604 = 0x2000803E
    ldrb r1, [r0, #0]                  @ 0x0800AA82
    movs r0, #1                        @ 0x0800AA84
    bl frequency_select_range          @ 0x0800AA86
.L0800AA8A:                              @ reached from 0x0800AA5C b, 0x0800AA6A b, 0x0800AA70 b, 0x0800AA76 b, 0x0800AA7C b
    @ ---- tail: 0x20007FC0 = 0; unit annunciators / sub-display redraw ----
    movs r0, #0                        @ 0x0800AA8A
    ldr r1, =v_20007FC0                @ 0x0800AA8C pool 0x0800B538 = 0x20007FC0
    strh r0, [r1, #0]                  @ 0x0800AA90
    ldr r0, =meter_mode                @ 0x0800AA92 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AA96
    cmp r0, #6                         @ 0x0800AA98
    beq .L0800AAB0                     @ 0x0800AA9A
    ldr r0, =meter_mode                @ 0x0800AA9C pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AAA0
    cmp r0, #7                         @ 0x0800AAA2
    beq .L0800AAB0                     @ 0x0800AAA4
    ldr r0, =meter_mode                @ 0x0800AAA6 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AAAA
    cmp r0, #8                         @ 0x0800AAAC
    bne .L0800AAB8                     @ 0x0800AAAE
.L0800AAB0:                              @ reached from 0x0800AA9A beq, 0x0800AAA4 beq
    movs r0, #1                        @ 0x0800AAB0
    ldr r1, =v_20008060                @ 0x0800AAB2 pool 0x0800B53C = 0x20008060
    strb r0, [r1, #0]                  @ 0x0800AAB6
.L0800AAB8:                              @ reached from 0x0800AAAE bne
    ldr r0, =meter_mode                @ 0x0800AAB8 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AABC
    cmp r0, #16                        @ 0x0800AABE
    beq .L0800AAF4                     @ 0x0800AAC0
    ldr r0, =meter_mode                @ 0x0800AAC2 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AAC6
    cmp r0, #18                        @ 0x0800AAC8
    beq .L0800AAF4                     @ 0x0800AACA
    ldr r0, =meter_mode                @ 0x0800AACC pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AAD0
    cmp r0, #20                        @ 0x0800AAD2
    beq .L0800AAF4                     @ 0x0800AAD4
    ldr r0, =meter_mode                @ 0x0800AAD6 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AADA
    cmp r0, #2                         @ 0x0800AADC
    bne .L0800AAEA                     @ 0x0800AADE
    @ mode 2 (AC+DC off), 4, 16, 18, 20: FUN_0801A440 (LCD unit annunciators)
    ldr r0, =acdc_active               @ 0x0800AAE0 pool 0x0800B608 = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x0800AAE4
    cmp r0, #0                         @ 0x0800AAE6
    beq .L0800AAF4                     @ 0x0800AAE8
.L0800AAEA:                              @ reached from 0x0800AADE bne
    ldr r0, =meter_mode                @ 0x0800AAEA pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AAEE
    cmp r0, #4                         @ 0x0800AAF0
    bne .L0800AB02                     @ 0x0800AAF2
.L0800AAF4:                              @ reached from 0x0800AAC0 beq, 0x0800AACA beq, 0x0800AAD4 beq, 0x0800AAE8 beq
    ldr r0, =meter_mode                @ 0x0800AAF4 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AAF8
    cmp r0, #0                         @ 0x0800AAFA
    beq .L0800AB02                     @ 0x0800AAFC
    bl fn_0801A440                     @ 0x0800AAFE
.L0800AB02:                              @ reached from 0x0800AAF2 bne, 0x0800AAFC beq
    ldr r0, =meter_mode                @ 0x0800AB02 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AB06
    cmp r0, #16                        @ 0x0800AB08
    beq .L0800AB34                     @ 0x0800AB0A
    ldr r0, =meter_mode                @ 0x0800AB0C pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AB10
    cmp r0, #18                        @ 0x0800AB12
    beq .L0800AB34                     @ 0x0800AB14
    ldr r0, =meter_mode                @ 0x0800AB16 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AB1A
    cmp r0, #20                        @ 0x0800AB1C
    beq .L0800AB34                     @ 0x0800AB1E
    ldr r0, =meter_mode                @ 0x0800AB20 pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AB24
    cmp r0, #2                         @ 0x0800AB26
    beq .L0800AB34                     @ 0x0800AB28
    ldr r0, =meter_mode                @ 0x0800AB2A pool 0x0800AEE0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800AB2E
    cmp r0, #4                         @ 0x0800AB30
    bne .L0800AB46                     @ 0x0800AB32
.L0800AB34:                              @ reached from 0x0800AB0A beq, 0x0800AB14 beq, 0x0800AB1E beq, 0x0800AB28 beq
    @ with 0x200080A5 = 0: request a sub-display redraw (0x20008062)
    ldr r0, =v_200080A5                @ 0x0800AB34 pool 0x0800B60C = 0x200080A5
    ldrb r0, [r0, #0]                  @ 0x0800AB38
    cmp r0, #0                         @ 0x0800AB3A
    bne .L0800AB46                     @ 0x0800AB3C
    movs r0, #1                        @ 0x0800AB3E
    ldr r1, =v_20008062                @ 0x0800AB40 pool 0x0800AED4 = 0x20008062
    strb r0, [r1, #0]                  @ 0x0800AB44
.L0800AB46:                              @ reached from 0x0800AA20 b, 0x0800AB32 bne, 0x0800AB3C bne
    pop {r0, pc}                       @ 0x0800AB46
    .ltorg
ENDFUNC fn_0800AA00

@ -----------------------------------------------------------------------------
@ counter_parse_and_restart - read CTA / CTB / CTC from the mirror, compute the gate T, restart the counter
@ Replaces : 0x0800AB48 counter_parse_and_restart (v2.05)
@ In       : - (mirror bytes 0x15..0x1D)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x200077D0 adc_regs, 0x2000001C, 0x20007E38, 0x20007E3C
@            writes 0x20007E38, 0x20007E3C, 0x20007E40, 0x20007E44, 0x20007E48
@ Spec     : analysis/hy3131_model.md 4.3
@ Deviation: none
@ CTA_final = rx[0x1B] + 256 rx[0x1C] + 65536 rx[0x1D]; CTB = rx[0x18..0x1A]; CTC = rx[0x15..0x17]; T = 0x1000000 - (word[0x2000001C] << 8) + CTA_final.
@ Then hy3131_counter_restart (HY).
@ -----------------------------------------------------------------------------
FUNC counter_parse_and_restart
    push {r7, lr}                      @ 0x0800AB48
    ldr r0, =adc_regs                  @ 0x0800AB4A pool 0x0800B300 = 0x200077D0
    ldrb r0, [r0, #29]                 @ 0x0800AB4E
    ldr r1, =adc_regs                  @ 0x0800AB50 pool 0x0800B300 = 0x200077D0
    ldrb r1, [r1, #28]                 @ 0x0800AB54
    lsls r1, r1, #8                    @ 0x0800AB56
    adds.w r0, r1, r0, lsl #16         @ 0x0800AB58
    ldr r1, =adc_regs                  @ 0x0800AB5C pool 0x0800B300 = 0x200077D0
    ldrb r1, [r1, #27]                 @ 0x0800AB60
    adds r0, r1, r0                    @ 0x0800AB62
    ldr r1, =v_20007E3C                @ 0x0800AB64 pool 0x0800B674 = 0x20007E3C
    str r0, [r1, #0]                   @ 0x0800AB68
    ldr r0, =adc_regs                  @ 0x0800AB6A pool 0x0800B300 = 0x200077D0
    ldrb r0, [r0, #26]                 @ 0x0800AB6E
    ldr r1, =adc_regs                  @ 0x0800AB70 pool 0x0800B300 = 0x200077D0
    ldrb r1, [r1, #25]                 @ 0x0800AB74
    lsls r1, r1, #8                    @ 0x0800AB76
    adds.w r0, r1, r0, lsl #16         @ 0x0800AB78
    ldr r1, =adc_regs                  @ 0x0800AB7C pool 0x0800B300 = 0x200077D0
    ldrb r1, [r1, #24]                 @ 0x0800AB80
    adds r0, r1, r0                    @ 0x0800AB82
    ldr r1, =v_20007E40                @ 0x0800AB84 pool 0x0800B678 = 0x20007E40
    str r0, [r1, #0]                   @ 0x0800AB88
    ldr r0, =adc_regs                  @ 0x0800AB8A pool 0x0800B300 = 0x200077D0
    ldrb r0, [r0, #23]                 @ 0x0800AB8E
    ldr r1, =adc_regs                  @ 0x0800AB90 pool 0x0800B300 = 0x200077D0
    ldrb r1, [r1, #22]                 @ 0x0800AB94
    lsls r1, r1, #8                    @ 0x0800AB96
    adds.w r0, r1, r0, lsl #16         @ 0x0800AB98
    ldr r1, =adc_regs                  @ 0x0800AB9C pool 0x0800B300 = 0x200077D0
    ldrb r1, [r1, #21]                 @ 0x0800ABA0
    adds r0, r1, r0                    @ 0x0800ABA2
    ldr r1, =v_20007E44                @ 0x0800ABA4 pool 0x0800B6C8 = 0x20007E44
    str r0, [r1, #0]                   @ 0x0800ABA8
    ldr r0, =v_2000001C                @ 0x0800ABAA pool 0x0800B6CC = 0x2000001C
    ldr r0, [r0, #0]                   @ 0x0800ABAE
    ldr r1, =v_20007E38                @ 0x0800ABB0 pool 0x0800B6D0 = 0x20007E38
    str r0, [r1, #0]                   @ 0x0800ABB4
    ldr r0, =v_20007E38                @ 0x0800ABB6 pool 0x0800B6D0 = 0x20007E38
    ldr r0, [r0, #0]                   @ 0x0800ABBA
    lsls r0, r0, #8                    @ 0x0800ABBC
    ldr r1, =v_20007E38                @ 0x0800ABBE pool 0x0800B6D0 = 0x20007E38
    str r0, [r1, #0]                   @ 0x0800ABC2
    ldr r0, =v_20007E38                @ 0x0800ABC4 pool 0x0800B6D0 = 0x20007E38
    ldr r0, [r0, #0]                   @ 0x0800ABC8
    rsbs r0, r0, #16777216             @ 0x0800ABCA
    ldr r1, =v_20007E38                @ 0x0800ABCE pool 0x0800B6D0 = 0x20007E38
    str r0, [r1, #0]                   @ 0x0800ABD2
    ldr r0, =v_20007E3C                @ 0x0800ABD4 pool 0x0800B674 = 0x20007E3C
    ldr r0, [r0, #0]                   @ 0x0800ABD8
    ldr r1, =v_20007E38                @ 0x0800ABDA pool 0x0800B6D0 = 0x20007E38
    ldr r1, [r1, #0]                   @ 0x0800ABDE
    adds r0, r1, r0                    @ 0x0800ABE0
    ldr r1, =v_20007E48                @ 0x0800ABE2 pool 0x0800B880 = 0x20007E48
    str r0, [r1, #0]                   @ 0x0800ABE6
    bl hy3131_counter_restart          @ 0x0800ABE8
    pop {r0, pc}                       @ 0x0800ABEC
    .ltorg
ENDFUNC counter_parse_and_restart

@ -----------------------------------------------------------------------------
@ counter_compute_frequency - frequency in mHz from the counter values
@ Replaces : 0x0800B610 counter_compute_frequency (v2.05)
@ In       : -
@ Out      : - (0x20007C40 = f, 64 bit)
@ Clobbers : r0-r3, r12, flags (r4-r7 preserved)
@ Context  : main only
@ RAM      : reads  0x20007E18 freq_reference, 0x2000803C meter_mode, 0x20007E40, 0x20007E48, 0x2000808E
@            writes 0x20007C40
@ Spec     : analysis/hy3131_model.md 4.3
@ Deviation: none
@ f = ref * CTB * 10 / (T / 10) with the 64-bit divide (fn_08014028).  With the calibration capture flag 0x2000808E set in
@ mode 6, FUN_0800B6F0 first replaces ref by the value derived from the current counter values (and clears the flag).
@ -----------------------------------------------------------------------------
FUNC counter_compute_frequency
    push {r3, r4, r5, r6, r7, lr}      @ 0x0800B610
    ldr r0, =v_2000808E                @ 0x0800B612 pool 0x0800BF80 = 0x2000808E
    ldrb r0, [r0, #0]                  @ 0x0800B616
    cmp r0, #0                         @ 0x0800B618
    beq .L0800B628                     @ 0x0800B61A
    ldr r0, =meter_mode                @ 0x0800B61C pool 0x0800B96C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800B61E
    cmp r0, #6                         @ 0x0800B620
    bne .L0800B628                     @ 0x0800B622
    bl fn_0800B6F0                     @ 0x0800B624
.L0800B628:                              @ reached from 0x0800B61A beq, 0x0800B622 bne
    ldr r0, =v_20007E40                @ 0x0800B628 pool 0x0800B678 = 0x20007E40
    ldr r2, [r0, #0]                   @ 0x0800B62A
    movs r3, #0                        @ 0x0800B62C
    ldr r0, =freq_reference            @ 0x0800B62E pool 0x0800C1E4 = 0x20007E18
    ldr r0, [r0, #0]                   @ 0x0800B632
    asrs r1, r0, #31                   @ 0x0800B634
    umull r6, r7, r0, r2               @ 0x0800B636
    mla r7, r0, r3, r7                 @ 0x0800B63A
    mla r7, r1, r2, r7                 @ 0x0800B63E
    movs r4, r6                        @ 0x0800B642
    movs r5, r7                        @ 0x0800B644
    ldr r0, =v_20007E48                @ 0x0800B646 pool 0x0800B880 = 0x20007E48
    ldr r0, [r0, #0]                   @ 0x0800B648
    movs r1, #10                       @ 0x0800B64A
    udiv r2, r0, r1                    @ 0x0800B64C
    movs r3, #0                        @ 0x0800B650
    movs r6, #10                       @ 0x0800B652
    movs r7, #0                        @ 0x0800B654
    umull r0, r1, r6, r4               @ 0x0800B656
    mla r1, r6, r5, r1                 @ 0x0800B65A
    mla r1, r7, r4, r1                 @ 0x0800B65E
    bl fn_08014028                     @ 0x0800B662
    movs r4, r0                        @ 0x0800B666
    movs r5, r1                        @ 0x0800B668
    ldr r0, =v_20007C40                @ 0x0800B66A pool 0x0800B740 = 0x20007C40
    strd r4, r5, [r0]                  @ 0x0800B66C
    pop {r0, r4, r5, r6, r7, pc}       @ 0x0800B670
    .ltorg
ENDFUNC counter_compute_frequency

@ -----------------------------------------------------------------------------
@ fn_0800ED64 - AC gate-time toggle: counter preset 0xE000 / 0x8000
@ Replaces : 0x0800ED64 FUN_0800ED64 (v2.05)
@ In       : - (called by the main loop on the 10 ms flag)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x200080BA acdc_active, 0x2000803C meter_mode, 0x2000803D meter_range, 0x20007FC2, 0x20008098,
@            0x2000809B, 0x200080A5
@            writes 0x2000001C, 0x20007FC2, 0x2000809B; production: mdc_first_mean (read and written back unchanged)
@ Spec     : analysis/hy3131_modes_misc.md 0 (counter preset)
@ Deviation: none
@ While the setting byte 0x200080A5 is 0 and the conditions hold (modes 2, 4, 16, 18, 20 with AC+DC off, or mode 0 with the LowZ AC state 0x20008098 set),
@ the tick count 0x20007FC2 counts the 10 ms flags; fn_0800AA00 zeroes it at every counter result, so it only runs on when no counter result arrives, i.e. for a
@ signal too slow to finish a cycle inside the gate.  After more than 2000 ticks (mode 0) or 100 ticks (other modes) it is zeroed, the state byte 0x2000809B
@ toggles and the preset 0x2000001C becomes 0xE000 (state 0, gate 0.4267 s) or 0x8000 (state 1, gate 1.707 s); the mode is then applied again (fn_0800B974) so
@ that HY writes the new preset.  Nothing restores the preset when the mode changes (hy3131_modes_misc.md 0).
@ -----------------------------------------------------------------------------
FUNC fn_0800ED64
    push {r4, lr}                      @ 0x0800ED64
    @ setting byte 0x200080A5 must be 0
    ldr r0, =v_200080A5                @ 0x0800ED66 pool 0x0800F7B0 = 0x200080A5
    ldrb r0, [r0, #0]                  @ 0x0800ED6A
    cmp r0, #0                         @ 0x0800ED6C
    bne .L0800EE48                     @ 0x0800ED6E
    @ modes 16, 18, 20, 2, 4 with AC+DC off, or mode 0 with the LowZ AC state set
    ldr r0, =meter_mode                @ 0x0800ED70 pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800ED74
    cmp r0, #16                        @ 0x0800ED76
    beq .L0800EDA2                     @ 0x0800ED78
    ldr r0, =meter_mode                @ 0x0800ED7A pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800ED7E
    cmp r0, #18                        @ 0x0800ED80
    beq .L0800EDA2                     @ 0x0800ED82
    ldr r0, =meter_mode                @ 0x0800ED84 pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800ED88
    cmp r0, #20                        @ 0x0800ED8A
    beq .L0800EDA2                     @ 0x0800ED8C
    ldr r0, =meter_mode                @ 0x0800ED8E pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800ED92
    cmp r0, #2                         @ 0x0800ED94
    beq .L0800EDA2                     @ 0x0800ED96
    ldr r0, =meter_mode                @ 0x0800ED98 pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800ED9C
    cmp r0, #4                         @ 0x0800ED9E
    bne .L0800EDAC                     @ 0x0800EDA0
.L0800EDA2:                              @ reached from 0x0800ED78 beq, 0x0800ED82 beq, 0x0800ED8C beq, 0x0800ED96 beq
    ldr r0, =acdc_active               @ 0x0800EDA2 pool 0x0800F7B4 = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x0800EDA6
    cmp r0, #0                         @ 0x0800EDA8
    beq .L0800EDC0                     @ 0x0800EDAA
.L0800EDAC:                              @ reached from 0x0800EDA0 bne
    ldr r0, =meter_mode                @ 0x0800EDAC pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800EDB0
    cmp r0, #0                         @ 0x0800EDB2
    bne .L0800EE48                     @ 0x0800EDB4
    ldr r0, =v_20008098                @ 0x0800EDB6 pool 0x0800F8C8 = 0x20008098
    ldrb r0, [r0, #0]                  @ 0x0800EDBA
    cmp r0, #0                         @ 0x0800EDBC
    beq .L0800EE48                     @ 0x0800EDBE
.L0800EDC0:                              @ reached from 0x0800EDAA beq
    ldr r0, =meter_mode                @ 0x0800EDC0 pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800EDC4
    cmp r0, #0                         @ 0x0800EDC6
    bne .L0800EDD2                     @ 0x0800EDC8
    mov.w r0, #2000                    @ 0x0800EDCA
    movs r4, r0                        @ 0x0800EDCE
    b .L0800EDD6                       @ 0x0800EDD0
.L0800EDD2:                              @ reached from 0x0800EDC8 bne
    movs r0, #100                      @ 0x0800EDD2
    movs r4, r0                        @ 0x0800EDD4
.L0800EDD6:                              @ reached from 0x0800EDD0 b
    @ count a 10 ms flag; the limit is 2000 in mode 0, 100 otherwise
    ldr r0, =v_20007FC2                @ 0x0800EDD6 pool 0x0800F8CC = 0x20007FC2
    ldrh r0, [r0, #0]                  @ 0x0800EDDA
    adds r0, r0, #1                    @ 0x0800EDDC
    ldr r1, =v_20007FC2                @ 0x0800EDDE pool 0x0800F8CC = 0x20007FC2
    strh r0, [r1, #0]                  @ 0x0800EDE2
    movs r0, r4                        @ 0x0800EDE4
    ldr r1, =v_20007FC2                @ 0x0800EDE6 pool 0x0800F8CC = 0x20007FC2
    ldrh r1, [r1, #0]                  @ 0x0800EDEA
    uxth r0, r0                        @ 0x0800EDEC
    cmp r0, r1                         @ 0x0800EDEE
    bcs .L0800EE48                     @ 0x0800EDF0
    movs r0, #0                        @ 0x0800EDF2
    ldr r1, =v_20007FC2                @ 0x0800EDF4 pool 0x0800F8CC = 0x20007FC2
    strh r0, [r1, #0]                  @ 0x0800EDF8
    @ limit exceeded: counter = 0, toggle the state byte 0x2000809B
    ldr r0, =v_2000809B                @ 0x0800EDFA pool 0x0800F8D0 = 0x2000809B
    ldrb r0, [r0, #0]                  @ 0x0800EDFE
    teq r0, #1                         @ 0x0800EE00
    beq .L0800EE10                     @ 0x0800EE04
    movs r0, #1                        @ 0x0800EE06
    ldr r1, =v_2000809B                @ 0x0800EE08 pool 0x0800F8D0 = 0x2000809B
    strb r0, [r1, #0]                  @ 0x0800EE0C
    b .L0800EE18                       @ 0x0800EE0E
.L0800EE10:                              @ reached from 0x0800EE04 beq
    movs r0, #0                        @ 0x0800EE10
    ldr r1, =v_2000809B                @ 0x0800EE12 pool 0x0800F8D0 = 0x2000809B
    strb r0, [r1, #0]                  @ 0x0800EE16
.L0800EE18:                              @ reached from 0x0800EE0E b
    ldr r0, =v_2000809B                @ 0x0800EE18 pool 0x0800F8D0 = 0x2000809B
    ldrb r0, [r0, #0]                  @ 0x0800EE1C
    cmp r0, #0                         @ 0x0800EE1E
    beq .L0800EE2E                     @ 0x0800EE20
    mov.w r0, #32768                   @ 0x0800EE22
    @ state 0: preset 0xE000 (gate 0.4267 s); state 1: preset 0x8000 (gate 1.707 s)
    ldr r1, =v_2000001C                @ 0x0800EE26 pool 0x0800F8D4 = 0x2000001C
    str r0, [r1, #0]                   @ 0x0800EE2A
    b .L0800EE38                       @ 0x0800EE2C
.L0800EE2E:                              @ reached from 0x0800EE20 beq
    mov.w r0, #57344                   @ 0x0800EE2E
    ldr r1, =v_2000001C                @ 0x0800EE32 pool 0x0800F8D4 = 0x2000001C
    str r0, [r1, #0]                   @ 0x0800EE36
.L0800EE38:                              @ reached from 0x0800EE2C b
    ldr r2, =mdc_first_mean
    ldrb r4, [r2]                           @ the same row is written again: not a configuration change, keep the P5 request as it is (r4 is free here)
    ldr r0, =meter_range               @ 0x0800EE38 pool 0x0800F6B8 = 0x2000803D
    ldrb r1, [r0, #0]                  @ 0x0800EE3C
    ldr r0, =meter_mode                @ 0x0800EE3E pool 0x0800F2F8 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800EE42
    @ apply the mode again so that HY writes the new preset
    bl fn_0800B974                     @ 0x0800EE44
    ldr r2, =mdc_first_mean
    strb r4, [r2]                           @ undo the arming by fn_0800B974 (IMP-01 P5)
.L0800EE48:                              @ reached from 0x0800ED6E bne, 0x0800EDB4 bne, 0x0800EDBE beq, 0x0800EDF0 bcs
    pop {r4, pc}                       @ 0x0800EE48
    .ltorg
ENDFUNC fn_0800ED64
