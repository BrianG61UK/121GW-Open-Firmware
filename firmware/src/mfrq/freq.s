@ =============================================================================
@ freq.s - MFRQ: frequency range apply, reference calibration and unit conversion
@
@ Replaces v2.05 FUN_0800AEE8 0x0800AEE8, FUN_0800B6F0 0x0800B6F0 and FUN_08012F28 0x08012F28.  The range decision itself
@ (frequency_select_range 0x0800AC1C) is ported by AR (DESIGN.md 6.12, 13.1); it calls fn_0800AEE8 below.
@
@ OF-02: v2.05 left r6 / r7 unset on two paths of FUN_0800AEE8 and stored them (0x0800B00C, 0x0800B010, 0x0800B014..0x0800B036).
@ Port: an unknown range index changes nothing; index 9 (frequency of 1 MHz or more) uses the same decade as index 4 (range 4).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mfrq.freq, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800AEE8 - apply a decade to the frequency: scaled value and range
@ Replaces : 0x0800AEE8 FUN_0800AEE8 (v2.05)
@ In       : r0 = 0: FREQ mode (result to the displayed value), 1: AC modes (result to the frequency sub-display variables)
@            r1 = decade index 0..4, or 9 for 1 MHz and above
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r7 preserved)
@ Context  : main only
@ RAM      : reads  0x20007C40
@            writes 0x2000803D meter_range, 0x20007C40, 0x20007D64, 0x20007D84, 0x20007E60, 0x20007E64, 0x2000803E,
@            0x20008046, 0x20008047, 0x200080A0, 0x200080A1
@ Spec     : analysis/hy3131_model.md 4.3; hy3131_modes_misc.md; ORIGINAL_FIRMWARE_ISSUES.md OF-02
@ Deviation: OF-02
@ Index n = 0..4: range r6 = n; f (0x20007C40, mHz, 64 bit) is first rounded in place by adding 0, 5, 50, 500, 5000 (n = 0 adds nothing), then r7 = f / 1, f / 10,
@ f / 100, f / 1000, f / 10000 (64-bit divide, low word).  r0 = 0: 0x20007D64 = r7 and meter_range = r6; r0 = 1: 0x20007D84, 0x20007E60 and 0x20007E64 = r7 and
@ 0x2000803E, 0x200080A0, 0x200080A1 = r6.  Index 9 (1 MHz and above): r6 = 4 and the overload flag 0x20008047 (r0 = 1) or 0x20008046 (r0 = 0) is set;
@ v2.05 stored an undefined r7, the port stores (f + 5000) / 10000 as for index 4 without changing 0x20007C40 (OF-02).  Any other index: nothing is stored (v2.05
@ stored undefined r6 and r7).
@ -----------------------------------------------------------------------------
FUNC fn_0800AEE8
    push {r4, r5, r6, r7, lr}          @ 0x0800AEE8
    movs r5, r0                        @ 0x0800AEEA
    movs r4, r1                        @ 0x0800AEEC
    uxtb r4, r4                        @ 0x0800AEEE
    movs r0, r4                        @ 0x0800AEF0
    cmp r0, #0                         @ 0x0800AEF2
    beq .L0800AF0C                     @ 0x0800AEF4
    cmp r0, #1                         @ 0x0800AEF6
    beq .L0800AF24                     @ 0x0800AEF8
    cmp r0, #2                         @ 0x0800AEFA
    beq .L0800AF52                     @ 0x0800AEFC
    cmp r0, #3                         @ 0x0800AEFE
    beq .L0800AF82                     @ 0x0800AF00
    cmp r0, #4                         @ 0x0800AF02
    beq .L0800AFB4                     @ 0x0800AF04
    cmp r0, #9                         @ 0x0800AF06
    beq .L0800AFE8                     @ 0x0800AF08
    b .L0800B038                            @ OF-02: unknown index: store nothing (v2.05 0x0800AF0A continued with unset r6 / r7)
.L0800AF0C:                              @ reached from 0x0800AEF4 beq
    @ ---- index 0: range 0, r7 = f / 1 ----
    movs r0, #0                        @ 0x0800AF0C
    movs r6, r0                        @ 0x0800AF0E
    ldr r2, =v_20007C40                @ 0x0800AF10 pool 0x0800B740 = 0x20007C40
    ldrd r0, r1, [r2]                  @ 0x0800AF14
    movs r2, #1                        @ 0x0800AF18
    movs r3, #0                        @ 0x0800AF1A
    bl fn_08014028                     @ 0x0800AF1C
    movs r7, r0                        @ 0x0800AF20
    b .L0800B004                       @ 0x0800AF22
.L0800AF24:                              @ reached from 0x0800AEF8 beq
    @ ---- index 1: range 1, f += 5 (rounding), r7 = f / 10 ----
    movs r0, #1                        @ 0x0800AF24
    movs r6, r0                        @ 0x0800AF26
    ldr r0, =v_20007C40                @ 0x0800AF28 pool 0x0800B740 = 0x20007C40
    ldrd r2, r3, [r0]                  @ 0x0800AF2C
    adds r0, r2, #5                    @ 0x0800AF30
    adcs.w r1, r3, #0                  @ 0x0800AF32
    ldr r2, =v_20007C40                @ 0x0800AF36 pool 0x0800B740 = 0x20007C40
    strd r0, r1, [r2]                  @ 0x0800AF3A
    ldr r2, =v_20007C40                @ 0x0800AF3E pool 0x0800B740 = 0x20007C40
    ldrd r0, r1, [r2]                  @ 0x0800AF42
    movs r2, #10                       @ 0x0800AF46
    movs r3, #0                        @ 0x0800AF48
    bl fn_08014028                     @ 0x0800AF4A
    movs r7, r0                        @ 0x0800AF4E
    b .L0800B004                       @ 0x0800AF50
.L0800AF52:                              @ reached from 0x0800AEFC beq
    @ ---- index 2: range 2, f += 50, r7 = f / 100 ----
    movs r0, #2                        @ 0x0800AF52
    movs r6, r0                        @ 0x0800AF54
    ldr r0, =v_20007C40                @ 0x0800AF56 pool 0x0800B740 = 0x20007C40
    ldrd r2, r3, [r0]                  @ 0x0800AF5A
    adds.w r0, r2, #50                 @ 0x0800AF5E
    adcs.w r1, r3, #0                  @ 0x0800AF62
    ldr r2, =v_20007C40                @ 0x0800AF66 pool 0x0800B740 = 0x20007C40
    strd r0, r1, [r2]                  @ 0x0800AF6A
    ldr r2, =v_20007C40                @ 0x0800AF6E pool 0x0800B740 = 0x20007C40
    ldrd r0, r1, [r2]                  @ 0x0800AF72
    movs r2, #100                      @ 0x0800AF76
    movs r3, #0                        @ 0x0800AF78
    bl fn_08014028                     @ 0x0800AF7A
    movs r7, r0                        @ 0x0800AF7E
    b .L0800B004                       @ 0x0800AF80
.L0800AF82:                              @ reached from 0x0800AF00 beq
    @ ---- index 3: range 3, f += 500, r7 = f / 1000 ----
    movs r0, #3                        @ 0x0800AF82
    movs r6, r0                        @ 0x0800AF84
    ldr r0, =v_20007C40                @ 0x0800AF86 pool 0x0800B740 = 0x20007C40
    ldrd r2, r3, [r0]                  @ 0x0800AF8A
    adds.w r0, r2, #500                @ 0x0800AF8E
    adcs.w r1, r3, #0                  @ 0x0800AF92
    ldr r2, =v_20007C40                @ 0x0800AF96 pool 0x0800B740 = 0x20007C40
    strd r0, r1, [r2]                  @ 0x0800AF9A
    ldr r2, =v_20007C40                @ 0x0800AF9E pool 0x0800B740 = 0x20007C40
    ldrd r0, r1, [r2]                  @ 0x0800AFA2
    mov.w r2, #1000                    @ 0x0800AFA6
    movs r3, #0                        @ 0x0800AFAA
    bl fn_08014028                     @ 0x0800AFAC
    movs r7, r0                        @ 0x0800AFB0
    b .L0800B004                       @ 0x0800AFB2
.L0800AFB4:                              @ reached from 0x0800AF04 beq
    @ ---- index 4: range 4, f += 5000, r7 = f / 10000 ----
    movs r0, #4                        @ 0x0800AFB4
    movs r6, r0                        @ 0x0800AFB6
    ldr r2, =v_20007C40                @ 0x0800AFB8 pool 0x0800B740 = 0x20007C40
    ldrd r0, r1, [r2]                  @ 0x0800AFBC
    movw r2, #5000                     @ 0x0800AFC0
    movs r3, #0                        @ 0x0800AFC4
    adds r0, r0, r2                    @ 0x0800AFC6
    adcs r1, r3                        @ 0x0800AFC8
    ldr r2, =v_20007C40                @ 0x0800AFCA pool 0x0800B740 = 0x20007C40
    strd r0, r1, [r2]                  @ 0x0800AFCE
    ldr r2, =v_20007C40                @ 0x0800AFD2 pool 0x0800B740 = 0x20007C40
    ldrd r0, r1, [r2]                  @ 0x0800AFD6
    movw r2, #10000                    @ 0x0800AFDA
    movs r3, #0                        @ 0x0800AFDE
    bl fn_08014028                     @ 0x0800AFE0
    movs r7, r0                        @ 0x0800AFE4
    b .L0800B004                       @ 0x0800AFE6
.L0800AFE8:                              @ reached from 0x0800AF08 beq
    @ ---- index 9 (f of 1 MHz or more): range 4, overload ----
    movs r0, #4                        @ 0x0800AFE8
    movs r6, r0                        @ 0x0800AFEA
    @ OF-02: index 9 (f >= 1 MHz) is range 4 as in v2.05 (r6 = 4); r7 = the frequency scaled as for index 4 ((f + 5000) / 10000), not undefined
    ldr r2, =v_20007C40
    ldrd r0, r1, [r2]
    movw r2, #5000
    movs r3, #0
    adds r0, r0, r2
    adcs r1, r3
    movw r2, #10000
    movs r3, #0
    bl fn_08014028                          @ r0 = (f + 5000) / 10000
    movs r7, r0
    uxtb r5, r5                        @ 0x0800AFEC
    cmp r5, #1                         @ 0x0800AFEE
    bne .L0800AFFC                     @ 0x0800AFF0
    movs r0, #1                        @ 0x0800AFF2
    ldr r1, =v_20008047                @ 0x0800AFF4 pool 0x0800B940 = 0x20008047
    strb r0, [r1, #0]                  @ 0x0800AFF8
    b .L0800B004                       @ 0x0800AFFA
.L0800AFFC:                              @ reached from 0x0800AFF0 bne
    movs r0, #1                        @ 0x0800AFFC
    ldr r1, =v_20008046                @ 0x0800AFFE pool 0x0800B738 = 0x20008046
    strb r0, [r1, #0]                  @ 0x0800B002
.L0800B004:                              @ reached from 0x0800AF0A b, 0x0800AF22 b, 0x0800AF50 b, 0x0800AF80 b, 0x0800AFB2 b, 0x0800AFE6 b, 0x0800AFFA b
    @ ---- store: FREQ (r5 = 0): displayed value 0x20007D64 = r7, meter_range = r6 ----
    uxtb r5, r5                        @ 0x0800B004
    cmp r5, #0                         @ 0x0800B006
    bne .L0800B014                     @ 0x0800B008
    ldr r0, =v_20007D64                @ 0x0800B00A pool 0x0800B230 = 0x20007D64
    str r7, [r0, #0]                   @ 0x0800B00C
    ldr r0, =meter_range               @ 0x0800B00E pool 0x0800B064 = 0x2000803D
    strb r6, [r0, #0]                  @ 0x0800B010
    b .L0800B038                       @ 0x0800B012
.L0800B014:                              @ reached from 0x0800B008 bne
    @ ---- AC modes (r5 = 1): sub-display frequency 0x20007D84, 0x20007E60, 0x20007E64 = r7 and the range bytes 0x2000803E, 0x200080A0, 0x200080A1 = r6 ----
    ldr r0, =v_20007D84                @ 0x0800B014 pool 0x0800B944 = 0x20007D84
    str r7, [r0, #0]                   @ 0x0800B018
    ldr r0, =v_20007E60                @ 0x0800B01A pool 0x0800B948 = 0x20007E60
    str r7, [r0, #0]                   @ 0x0800B01E
    ldr r0, =v_20007E64                @ 0x0800B020 pool 0x0800B94C = 0x20007E64
    str r7, [r0, #0]                   @ 0x0800B024
    ldr r0, =v_2000803E                @ 0x0800B026 pool 0x0800B604 = 0x2000803E
    strb r6, [r0, #0]                  @ 0x0800B02A
    ldr r0, =v_200080A0                @ 0x0800B02C pool 0x0800B950 = 0x200080A0
    strb r6, [r0, #0]                  @ 0x0800B030
    ldr r0, =v_200080A1                @ 0x0800B032 pool 0x0800B954 = 0x200080A1
    strb r6, [r0, #0]                  @ 0x0800B036
.L0800B038:                              @ reached from 0x0800B012 b
    pop {r4, r5, r6, r7, pc}           @ 0x0800B038
    .ltorg
ENDFUNC fn_0800AEE8

@ -----------------------------------------------------------------------------
@ fn_0800B6F0 - calibration: measure the frequency reference and store it
@ Replaces : 0x0800B6F0 FUN_0800B6F0 (v2.05)
@ In       : - (calibration mode, mode 6, capture flag 0x2000808E set)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4, r5 preserved)
@ Context  : main only
@ RAM      : reads  0x20007E18 freq_reference, 0x20007E40, 0x20007E48
@            writes 0x20007E18 freq_reference, 0x2000808E
@ Spec     : analysis/hy3131_model.md 4.3; EEPROM_MAP.md (record 0x104); requests/W7_to_W5.md 1
@ Deviation: none
@ ref = 150 000 000 * T / (CTB * 100) (64-bit multiply and divide; the constant is the literal 0x08F0D180 at v2.05 0x0800B6FE), stored in 0x20007E18.
@ cal_record_write(1, ref) needs NVM armed with the CAL key immediately before (NVM refuses an unarmed call); its status is ignored as in v2.05.
@ -----------------------------------------------------------------------------
FUNC fn_0800B6F0
    push {r3, r4, r5, lr}              @ 0x0800B6F0
    movs r0, #0                        @ 0x0800B6F2
    ldr r1, =v_2000808E                @ 0x0800B6F4 pool 0x0800BF80 = 0x2000808E
    strb r0, [r1, #0]                  @ 0x0800B6F8
    ldr r0, =v_20007E48                @ 0x0800B6FA pool 0x0800B880 = 0x20007E48
    ldr r0, [r0, #0]                   @ 0x0800B6FC
    ldr r1, =0x08F0D180                @ 0x0800B6FE pool 0x0800C1F0 = 0x08F0D180
    umull r0, r1, r1, r0               @ 0x0800B702
    movs r4, r0                        @ 0x0800B706
    movs r5, r1                        @ 0x0800B708
    movs r0, r4                        @ 0x0800B70A
    movs r1, r5                        @ 0x0800B70C
    ldr r2, =v_20007E40                @ 0x0800B70E pool 0x0800C1E8 = 0x20007E40
    ldr r2, [r2, #0]                   @ 0x0800B712
    movs r3, #100                      @ 0x0800B714
    muls r2, r3                        @ 0x0800B716
    movs r3, #0                        @ 0x0800B718
    bl fn_08014028                     @ 0x0800B71A
    movs r4, r0                        @ 0x0800B71E
    movs r5, r1                        @ 0x0800B720
    ldr r0, =freq_reference            @ 0x0800B722 pool 0x0800C1E4 = 0x20007E18
    str r4, [r0, #0]                   @ 0x0800B726
    NVM_ARM CAL                             @ W7: cal_record_write is a CAL-class EEPROM write; arm NVM for exactly this call
    ldr r0, =freq_reference            @ 0x0800B728 pool 0x0800C1E4 = 0x20007E18
    ldr r1, [r0, #0]                   @ 0x0800B72C
    movs r0, #1                        @ 0x0800B72E
    bl cal_record_write                @ 0x0800B730
    pop {r0, r4, r5, pc}               @ 0x0800B734
    .ltorg
ENDFUNC fn_0800B6F0

@ -----------------------------------------------------------------------------
@ fn_08012F28 - scale a value by the frequency decade
@ Replaces : 0x08012F28 FUN_08012F28 (v2.05)
@ In       : r0 = decade 0..4
@            r1 = value
@ Out      : r0 = value / 1000 (decade 0), / 100 (1), / 10 (2), unchanged (3), * 10 (4); other decades: value unchanged
@ Clobbers : r0-r1, flags
@ Context  : main only
@ RAM      : none directly
@ Spec     : v2.05 listing 0x08012F28 (callers CAL, MAC)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_08012F28
    uxtb r0, r0                        @ 0x08012F28
    cmp r0, #0                         @ 0x08012F2A
    beq .L08012F3C                     @ 0x08012F2C
    cmp r0, #2                         @ 0x08012F2E
    beq .L08012F4E                     @ 0x08012F30
    bcc .L08012F46                     @ 0x08012F32
    cmp r0, #4                         @ 0x08012F34
    beq .L08012F58                     @ 0x08012F36
    bcc .L08012F56                     @ 0x08012F38
    b .L08012F5C                       @ 0x08012F3A
.L08012F3C:                              @ reached from 0x08012F2C beq
    mov.w r0, #1000                    @ 0x08012F3C
    sdiv r1, r1, r0                    @ 0x08012F40
    b .L08012F5C                       @ 0x08012F44
.L08012F46:                              @ reached from 0x08012F32 bcc
    movs r0, #100                      @ 0x08012F46
    sdiv r1, r1, r0                    @ 0x08012F48
    b .L08012F5C                       @ 0x08012F4C
.L08012F4E:                              @ reached from 0x08012F30 beq
    movs r0, #10                       @ 0x08012F4E
    sdiv r1, r1, r0                    @ 0x08012F50
    b .L08012F5C                       @ 0x08012F54
.L08012F56:                              @ reached from 0x08012F38 bcc
    b .L08012F5C                       @ 0x08012F56
.L08012F58:                              @ reached from 0x08012F36 beq
    movs r0, #10                       @ 0x08012F58
    muls r1, r0                        @ 0x08012F5A
.L08012F5C:                              @ reached from 0x08012F3A b, 0x08012F44 b, 0x08012F4C b, 0x08012F54 b, 0x08012F56 b
    movs r0, r1                        @ 0x08012F5C
    bx lr                              @ 0x08012F5E
    .ltorg
ENDFUNC fn_08012F28
