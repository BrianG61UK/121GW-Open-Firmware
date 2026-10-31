@ =============================================================================
@ records.s - CAL module: calibration record loaders, markers, date code and serial number
@
@ Readers go through the NVM readers (cache after cal_cache_load); writers arm NVM and call the NVM writers
@ (DESIGN.md 6.20, 6.21).  Formats, validation and defaults are v2.05's (EEPROM_MAP.md 4, 5, 6).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ F_1E4, 0x461C4000                  @ 10000.0f
    .equ F_1E5, 0x47C35000                  @ 100000.0f
    .equ F_1E6, 0x49742400                  @ 1000000.0f
    .equ T_PEAK_ENTRY, 0x32                 @ byte offset of T[25] in the record base table

    .section .text.cal, "ax", %progbits

@ -----------------------------------------------------------------------------
@ load_cal_record_from_eeprom - load the calibration words of a mode and range
@ Replaces : 0x0801167C load_cal_record_from_eeprom
@ In       : r0 = mode argument (0xC8 = board temperature offset), r1 = range argument
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007D5C (record offset), 0x20007FBE (0xC8), 0x20007E14 (OHM range 6, not in cal mode),
@            0x20007E18 (mode 6), 0x20007E00 and 0x20007E10 (other modes), VA words through
@            cal_record_load_va; reads 0x2000808A, 0x2000803C, 0x2000803D, 0x200080B7, 0x20008098, 0x200080BA,
@            0x200080BD, 0x20007FDF
@ Spec     : EEPROM_MAP.md 5.2 (branches in code order)
@ -----------------------------------------------------------------------------
FUNC load_cal_record_from_eeprom
    push {r4, r5, r6, lr}
    uxtb r4, r0                             @ r4 = mode argument
    uxtb r5, r1                             @ r5 = range argument (used as a byte, 0x08011816)
    ldr r6, =v205_tab_08028EE8              @ r6 = record base table T
    cmp r4, #0xC8
    bne .Llcr_not_c8
    @ 1. board temperature offset (0x08011688..0x080116C6)
    mov r0, #0x2E0
    ldr r1, =v_20007D5C
    str r0, [r1]
    bl eeprom_read_u16_be
    ldr r1, =v_20007FBE
    strh r0, [r1]
    ldrsh r0, [r1]                          @ signed value (0x080116A6)
    cmp r0, #1000
    bgt 1f                                  @ > 1000 -> 0
    cmn r0, #1000
    bge 2f                                  @ >= -1000 kept
1:  movs r0, #0
    strh r0, [r1]
2:  pop {r4, r5, r6, pc}                    @ no delay on this path (0x080116C6 -> 0x08011912)
.Llcr_not_c8:
    @ 2. OHM range-6 weight outside calibration mode (0x080116C8..0x080116F0); continues afterwards
    ldr r0, =v_2000808A
    ldrb r0, [r0]
    cbnz r0, 3f
    cmp r4, #9
    bne 3f
    ldr r0, =meter_range
    ldrb r0, [r0]
    cmp r0, #6
    bne 3f
    mov r0, #0x178
    bl eeprom_read_u32_be
    ldr r1, =v_20007E14
    str r0, [r1]
    bl fn_08011924                          @ keep -3000..3000, else 0
3:  @ 3. VA modes by the global meter_mode (0x080116F4..0x0801173A)
    ldr r0, =meter_mode
    ldrb r0, [r0]
    sub r1, r0, #13
    cmp r1, #2
    bls 4f
    sub r1, r0, #22
    cmp r1, #2
    bhi 5f
4:  bl cal_record_load_va
    pop {r4, r5, r6, pc}
5:  @ 4. FREQ: frequency reference (0x0801173C..0x08011788)
    cmp r4, #6
    bne 7f
    ldrh r0, [r6, #12]                      @ T[6]
    ldr r1, =v_20007D5C
    str r0, [r1]
    adds r0, r0, #4
    bl eeprom_read_u32_be
    ldr r1, =freq_reference
    str r0, [r1]
    ldr r2, =0x03938701                     @ 60 000 001 (exclusive upper bound, pool 0x08012134)
    cmp r0, r2
    bge 6f                                  @ signed compare as 0x08011770
    ldr r2, =0x02625A00                     @ 40 000 000
    cmp r0, r2
    bge 61f                                 @ inside: keep (0x0801177E)
6:  ldr r0, =0x02EE0032                     @ default 49 152 050 (0x08011780)
    str r0, [r1]
61: pop {r4, r5, r6, pc}
7:  @ 5. ACV/ACmV with peak hold: peak record T[25] (0x0801178C..0x080117AE)
    cmp r4, #2
    beq 8f
    cmp r4, #4
    bne 9f
8:  ldr r0, =v_200080B7
    ldrb r0, [r0]
    cmp r0, #1
    bne 9f
    ldrh r0, [r6, #T_PEAK_ENTRY]            @ 0x2D0
    b .Llcr_read
9:  @ 6. LowZ: ACV range 3 or DCV range 3 record (0x080117B0..0x080117E8)
    cmp r4, #0
    bne 11f
    ldr r0, =v_20008098
    ldrb r0, [r0]
    cmp r0, #0
    ite ne                                  @ LowZ AC selected: T[2], else T[1]
    ldrhne r0, [r6, #4]
    ldrheq r0, [r6, #2]
    adds r0, r0, #0x30                      @ + 0x30 = range 3
    b .Llcr_read
11: @ 7. ACV: DCV record with AC+DC and 0x200080BD, else ACV (0x080117EA..0x08011846)
    cmp r4, #2
    bne 13f
    ldr r0, =v_200080BA
    ldrb r0, [r0]
    cbz r0, 12f
    ldr r0, =v_200080BD
    ldrb r0, [r0]
    cbz r0, 12f
    ldrh r0, [r6, #2]                       @ T[1]
    add r0, r0, r5, lsl #4
    b .Llcr_read
12: ldrh r0, [r6, r4, lsl #1]               @ T[2]
    add r0, r0, r5, lsl #4
    b .Llcr_read
13: @ 8. BEEP: OHM range-1 record T[9] + 0x10 = 0x120 (0x08011848..0x08011868)
    cmp r4, #10
    bne 14f
    ldrh r0, [r6, #18]                      @ T[9]
    adds r0, r0, #0x10
    b .Llcr_read
14: @ 9. every other mode: T[mode] + 16 * range (0x0801186A..0x0801188A)
    ldrh r0, [r6, r4, lsl #1]
    add r0, r0, r5, lsl #4
.Llcr_read:
    @ offset word, gain word / D, delay (0x0801188C..0x0801190E)
    ldr r1, =v_20007D5C
    str r0, [r1]
    bl eeprom_read_u32_be                   @ i32 BE offset
    ldr r1, =cal_offset
    str r0, [r1]
    ldr r0, =v_20007D5C
    ldr r0, [r0]
    adds r0, r0, #4
    bl eeprom_read_u32_be                   @ gain word
    bl fn_08012F74                          @ ui2f (unsigned, 0x080118A8)
    ldr r1, =cal_gain
    str r0, [r1]
    ldr r1, =F_1E6                          @ D = 1e6 except mode 12
    cmp r4, #12
    bne 15f
    ldr r1, =F_1E5                          @ mode 12: 1e5
    ldr r2, =meter_range
    ldrb r2, [r2]
    cmp r2, #4
    bne 15f
    ldr r2, =v_20007FDF
    ldrb r2, [r2]
    cbz r2, 15f
    ldr r1, =F_1E4                          @ mode 12 range 4 with 0x20007FDF != 0: 1e4
15: bl fn_08012F94                          @ gain / D
    ldr r1, =cal_gain
    str r0, [r1]
    movs r0, #1
    bl fn_0800ECF6                          @ busy delay(1) (0x0801190E)
    pop {r4, r5, r6, pc}
ENDFUNC load_cal_record_from_eeprom

@ -----------------------------------------------------------------------------
@ fn_08011924 - clamp the OHM range-6 weight
@ Replaces : 0x08011924 (0x20007E14 kept if -3000..3000, else 0)
@ In       : -
@ Out      : -
@ Clobbers : r0-r2, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_08011924
    ldr r1, =v_20007E14
    ldr r0, [r1]
    movw r2, #3001
    cmp r0, r2
    bge 1f                                  @ >= 3001 (signed, 0x08011930)
    ldr r2, =0xFFFFF448                     @ -3000
    cmp r0, r2
    bge 2f                                  @ >= -3000 kept
1:  movs r0, #0
    str r0, [r1]
2:  bx lr
ENDFUNC fn_08011924

@ -----------------------------------------------------------------------------
@ cal_record_load_va - load the four VA calibration words
@ Replaces : 0x08011950 cal_record_load_va
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007D5C, 0x20007E24, 0x20007E2C, 0x20007E28, 0x20007E30 (in v2.05 order, the gain
@            words first as ui2f, then divided by 1e6)
@ Spec     : EEPROM_MAP.md 3
@ -----------------------------------------------------------------------------
FUNC cal_record_load_va
    push {r4, lr}
    movs r0, #0
    bl fn_0801159C                          @ R
    ldr r1, =v_20007D5C
    str r0, [r1]
    bl eeprom_read_u32_be                   @ offset 1
    ldr r1, =v_20007E24
    str r0, [r1]
    ldr r0, =v_20007D5C
    ldr r0, [r0]
    adds r0, r0, #4
    bl eeprom_read_u32_be                   @ gain 1 word
    bl fn_08012F74                          @ ui2f
    ldr r4, =v_20007E2C
    str r0, [r4]
    ldr r1, =F_1E6
    bl fn_08012F94                          @ / 1e6
    str r0, [r4]
    movs r0, #1
    bl fn_0801159C                          @ R (argument ignored)
    ldr r1, =v_20007D5C
    str r0, [r1]
    adds r0, r0, #8                         @ R + 8 (0x080119AA)
    str r0, [r1]
    bl eeprom_read_u32_be                   @ offset 2
    ldr r1, =v_20007E28
    str r0, [r1]
    ldr r0, =v_20007D5C
    ldr r0, [r0]
    adds r0, r0, #4
    bl eeprom_read_u32_be                   @ gain 2 word at R + 0xC
    bl fn_08012F74
    ldr r4, =v_20007E30
    str r0, [r4]
    ldr r1, =F_1E6
    bl fn_08012F94
    str r0, [r4]
    pop {r4, pc}
ENDFUNC cal_record_load_va

@ -----------------------------------------------------------------------------
@ fn_080119F4 - clamp one AC calibration word in RAM
@ Replaces : 0x080119F4 (word 0, 1: -20000..20000; word 2, 3: -10000..10000; outside -> 0)
@ In       : r0 = word index 0..3 (other values: nothing)
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main
@ RAM      : 0x20007E4C + 4 * index
@ -----------------------------------------------------------------------------
FUNC fn_080119F4
    uxtb r0, r0
    cmp r0, #3
    bhi 3f                                  @ index > 3: nothing (0x08011A04)
    ldr r1, =v_20007E4C
    add r1, r1, r0, lsl #2                  @ r1 = address of the word
    movw r2, #20001                         @ words 0, 1: upper bound 20001 (0x08011A0C)
    cmp r0, #2
    blo 1f
    movw r2, #10001                         @ words 2, 3: upper bound 10001 (0x08011A58)
1:  ldr r3, [r1]
    cmp r3, r2
    bge 2f                                  @ >= bound (signed)
    rsb r2, r2, #1                          @ lower bound = 1 - upper = -20000 / -10000
    cmp r3, r2
    bge 3f                                  @ >= lower bound: kept
2:  movs r3, #0
    str r3, [r1]
3:  bx lr
ENDFUNC fn_080119F4

@ -----------------------------------------------------------------------------
@ fn_08011AA4 - load the AC calibration words of the current mode and range
@ Replaces : 0x08011AA4 (ac_words_load)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007D5C, 0x20007E4C..0x20007E58 (each clamped by fn_080119F4)
@ Spec     : EEPROM_MAP.md 3 (LowZ uses ac_words_base(2, 3))
@ -----------------------------------------------------------------------------
FUNC fn_08011AA4
    push {r4, r5, r6, lr}
    ldr r0, =meter_mode
    ldrb r0, [r0]
    movs r1, #3                             @ LowZ: ac_words_base(2, 3) (0x08011AB0..0x08011AB4)
    cbz r0, 1f
    ldr r1, =meter_range
    ldrb r1, [r1]                           @ else ac_words_base(mode, range)
    b 2f
1:  movs r0, #2
2:  bl fn_080115CC
    ldr r1, =v_20007D5C
    str r0, [r1]
    movs r4, #0                             @ r4 = word index
    ldr r5, =v_20007E4C
3:  ldr r0, =v_20007D5C
    ldr r0, [r0]
    add r0, r0, r4, lsl #1                  @ R' + 2 * index
    bl fn_08011FD4                          @ s16 BE
    str r0, [r5, r4, lsl #2]
    mov r0, r4
    bl fn_080119F4                          @ clamp
    adds r4, r4, #1
    cmp r4, #4
    blo 3b
    pop {r4, r5, r6, pc}
ENDFUNC fn_08011AA4

@ -----------------------------------------------------------------------------
@ fn_080104BC - read the ACV range-0 calibration marker
@ Replaces : 0x080104BC (marker_1F_read)
@ In       : -
@ Out      : r0 = 0 if EEPROM[0x1F] == 0xA5, else 1
@ Clobbers : r1-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_080104BC
    push {r4, lr}
    movs r0, #0x1F
    bl eeprom_read_u8
    subs r0, r0, #0xA5
    it ne                                   @ not the marker: 1
    movne r0, #1
    pop {r4, pc}
ENDFUNC fn_080104BC

@ -----------------------------------------------------------------------------
@ fn_080104D4 - write the ACV range-0 calibration marker
@ Replaces : 0x080104D4 (marker_1F_write; the 10 rounds of write and read-back are inside nvm_marker_write)
@ In       : -
@ Out      : r0 = NVM status (v2.05 returns nothing)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_080104D4
    push {r4, lr}
    NVM_ARM CAL
    movs r0, #0x1F
    bl nvm_marker_write
    pop {r4, pc}
ENDFUNC fn_080104D4

@ -----------------------------------------------------------------------------
@ fn_08010F10 - read the OHM range-6 calibration marker
@ Replaces : 0x08010F10 (marker_26_read)
@ In       : -
@ Out      : r0 = 0 if EEPROM[0x26] == 0xA5, else 1
@ Clobbers : r1-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_08010F10
    push {r4, lr}
    movs r0, #0x26
    bl eeprom_read_u8
    subs r0, r0, #0xA5
    it ne                                   @ not the marker: 1
    movne r0, #1
    pop {r4, pc}
ENDFUNC fn_08010F10

@ -----------------------------------------------------------------------------
@ fn_08010F28 - write the OHM range-6 calibration marker
@ Replaces : 0x08010F28 (marker_26_write)
@ In       : -
@ Out      : r0 = NVM status (v2.05 returns nothing)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_08010F28
    push {r4, lr}
    NVM_ARM CAL
    movs r0, #0x26
    bl nvm_marker_write
    pop {r4, pc}
ENDFUNC fn_08010F28

@ -----------------------------------------------------------------------------
@ fn_08010F4C - load the date code
@ Replaces : 0x08010F4C (u16 BE at 0x001 -> 0x20007F9A; 0 -> 1708)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main (boot, set_state_reset 0x08024E1E)
@ -----------------------------------------------------------------------------
FUNC fn_08010F4C
    push {r4, lr}
    movs r0, #1
    bl eeprom_read_u16_be
    ldr r1, =v_20007F9A
    strh r0, [r1]
    cbnz r0, 1f
    movw r0, #1708                          @ default year*100+month 17/08 (0x08010F64)
    strh r0, [r1]
1:  pop {r4, pc}
ENDFUNC fn_08010F4C

@ -----------------------------------------------------------------------------
@ fn_08010F74 - store the date code (class IDENT)
@ Replaces : 0x08010F74 (eeprom_write_u16_be(1, 0x20007F9A))
@ In       : -
@ Out      : r0 = NVM status (v2.05 returns nothing); NVM refuses unless 0x2000808B != 0
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (SET, FUN_08015F44)
@ -----------------------------------------------------------------------------
FUNC fn_08010F74
    push {r4, lr}
    NVM_ARM IDENT
    ldr r1, =v_20007F9A
    ldrh r1, [r1]
    movs r0, #1
    bl nvm_write_ident
    pop {r4, pc}
ENDFUNC fn_08010F74

@ -----------------------------------------------------------------------------
@ fn_08010F8C - load the serial number
@ Replaces : 0x08010F8C (u32 BE at 0x003 -> 0x20007D14; >= 100000 -> 0, unsigned compare 0x08010FA6)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main (boot, set_state_reset 0x08024E22)
@ -----------------------------------------------------------------------------
FUNC fn_08010F8C
    push {r4, lr}
    movs r0, #3
    bl eeprom_read_u32_be
    ldr r1, =v_20007D14
    str r0, [r1]
    ldr r2, =100000
    cmp r0, r2
    blo 1f
    movs r0, #0
    str r0, [r1]
1:  pop {r4, pc}
ENDFUNC fn_08010F8C

@ -----------------------------------------------------------------------------
@ fn_08010FB8 - store the serial number (class IDENT)
@ Replaces : 0x08010FB8 (eeprom_write_u32_be(3, 0x20007D14))
@ In       : -
@ Out      : r0 = NVM status (v2.05 returns nothing)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (SET, FUN_08015F7C)
@ -----------------------------------------------------------------------------
FUNC fn_08010FB8
    push {r4, lr}
    NVM_ARM IDENT
    ldr r1, =v_20007D14
    ldr r1, [r1]
    movs r0, #3
    bl nvm_write_ident
    pop {r4, pc}
ENDFUNC fn_08010FB8

    .ltorg
