@ =============================================================================
@ userzero.s - MVA module: user current zero (EEPROM 0x4D0..0x4FF)
@
@ A long REL press in a current mode (16..21) at range 0 stores the reading as the user zero: six records of
@ 8 bytes at 0x4D0 ACuA, 0x4D8 DCuA, 0x4E0 ACmA, 0x4E8 DCmA, 0x4F0 ACA, 0x4F8 DCA, each marker 0xA5 + a
@ big-endian int32 (EEPROM_MAP.md 5.5).  fn_08011448 loads the record of the active mode into RAM user_zero
@ (0x20007E0C) at every mode / range application and sets it to 0 first.  All EEPROM writes go through the NVM
@ writer nvm_write_userzero (class USERZERO, armed by nvm_arm immediately before the call); readers use the
@ NVM readers (RAM cache after cal_cache_load).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.mva, "ax", %progbits

@ -----------------------------------------------------------------------------
@ current_extra_load - load the user zero of the mode: user_zero = record value when the marker is 0xA5 (modes 16..21, range 0), else 0
@ Replaces : 0x08011448 current_extra_load (v2.05)
@ In       : r0 = mode
@            r1 = range
@ Out      : user_zero (0x20007E0C)
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (meter_apply_mode_range)
@ Registers: r4 = mode, r5 = range, r6 = marker byte, r7 = record offset
@ RAM      : reads  -
@            writes 0x20007E0C user_zero
@ Spec     : analysis/hy3131_modes_ac_current.md 7.7; EEPROM_MAP.md 5.5
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC current_extra_load
    push {r3, r4, r5, r6, r7, lr}        @ 08011448
    movs r4, r0                          @ 0801144A
    movs r5, r1                          @ 0801144C
    @ user_zero = 0
    movs r0, #0                          @ 0801144E
    ldr r1, =v_20007E0C                  @ 08011450
    str r0, [r1]                         @ 08011454  user_zero (u32) = 0
    @ only the current modes 16..21
    uxtb r4, r4                          @ 08011456
    cmp r4, #0x10                        @ 08011458
    beq .Lcurrent_extra_load_0801147A    @ 0801145A  if mode == 16
    uxtb r4, r4                          @ 0801145C
    cmp r4, #0x12                        @ 0801145E
    beq .Lcurrent_extra_load_0801147A    @ 08011460  if mode == 18
    uxtb r4, r4                          @ 08011462
    cmp r4, #0x14                        @ 08011464
    beq .Lcurrent_extra_load_0801147A    @ 08011466  if mode == 20
    uxtb r4, r4                          @ 08011468
    cmp r4, #0x11                        @ 0801146A
    beq .Lcurrent_extra_load_0801147A    @ 0801146C  if mode == 17
    uxtb r4, r4                          @ 0801146E
    cmp r4, #0x13                        @ 08011470
    beq .Lcurrent_extra_load_0801147A    @ 08011472  if mode == 19
    uxtb r4, r4                          @ 08011474
    cmp r4, #0x15                        @ 08011476
    bne .Lcurrent_extra_load_exit        @ 08011478  if mode != 21
.Lcurrent_extra_load_0801147A:   @ branch target from 0801145A, 08011460, 08011466, 0801146C, 08011472
    @ only range 0
    uxtb r5, r5                          @ 0801147A
    cmp r5, #0                           @ 0801147C
    bne .Lcurrent_extra_load_exit        @ 0801147E  if range != 0
    @ record offset of the mode; marker byte 0xA5 means a stored zero; then the int32 after it
    movs r0, r4                          @ 08011480
    uxtb r0, r0                          @ 08011482
    bl current_extra_offset              @ 08011484  MVA: EEPROM record offset of the user zero of a mode
    movs r7, r0                          @ 08011488
    uxth r7, r7                          @ 0801148A
    movs r0, r7                          @ 0801148C
    bl eeprom_read_u8                    @ 0801148E
    movs r6, r0                          @ 08011492
    uxtb r6, r6                          @ 08011494
    cmp r6, #0xa5                        @ 08011496
    bne .Lcurrent_extra_load_exit        @ 08011498  if r6 != 165
    uxth r7, r7                          @ 0801149A
    adds r0, r7, #1                      @ 0801149C  r0 = r7 + 1
    bl eeprom_read_u32_be                @ 0801149E
    ldr r1, =v_20007E0C                  @ 080114A2
    str r0, [r1]                         @ 080114A6  user_zero (u32) = r0
.Lcurrent_extra_load_exit:   @ return
    pop {r0, r4, r5, r6, r7, pc}         @ 080114A8
    .ltorg
ENDFUNC current_extra_load

@ -----------------------------------------------------------------------------
@ current_extra_store - store the user zero of the mode in its EEPROM record (marker 0xA5 + int32 big endian)
@ Replaces : 0x080114BC current_extra_store (v2.05)
@ In       : r0 = mode (16..21 only, else nothing happens)
@            r1 = range (0 only, else nothing happens)
@            r2 = value (int32)
@ Out      : -  (the NVM status is not returned; v2.05 callers ignore it)
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (long REL in KEY)
@ Registers: r4 = mode, r5 = range, r6 = value, r7 = record offset
@ RAM      : reads  -
@            writes -
@ Spec     : analysis/hy3131_modes_ac_current.md 7.7; EEPROM_MAP.md 5.5, 9.2
@ Deviation: OF-09 (KEY passes the accumulated user zero as r2; this routine stores what it is given), NVM class USERZERO
@ -----------------------------------------------------------------------------
FUNC current_extra_store
    push {r3, r4, r5, r6, r7, lr}        @ 080114BC
    movs r4, r0                          @ 080114BE
    movs r5, r1                          @ 080114C0
    movs r6, r2                          @ 080114C2
    @ only the current modes 16..21 at range 0
    uxtb r4, r4                          @ 080114C4
    cmp r4, #0x10                        @ 080114C6
    beq .Lcurrent_extra_store_080114E8   @ 080114C8  if mode == 16
    uxtb r4, r4                          @ 080114CA
    cmp r4, #0x12                        @ 080114CC
    beq .Lcurrent_extra_store_080114E8   @ 080114CE  if mode == 18
    uxtb r4, r4                          @ 080114D0
    cmp r4, #0x14                        @ 080114D2
    beq .Lcurrent_extra_store_080114E8   @ 080114D4  if mode == 20
    uxtb r4, r4                          @ 080114D6
    cmp r4, #0x11                        @ 080114D8
    beq .Lcurrent_extra_store_080114E8   @ 080114DA  if mode == 17
    uxtb r4, r4                          @ 080114DC
    cmp r4, #0x13                        @ 080114DE
    beq .Lcurrent_extra_store_080114E8   @ 080114E0  if mode == 19
    uxtb r4, r4                          @ 080114E2
    cmp r4, #0x15                        @ 080114E4
    bne .Lcurrent_extra_store_exit       @ 080114E6  if mode != 21
.Lcurrent_extra_store_080114E8:   @ branch target from 080114C8, 080114CE, 080114D4, 080114DA, 080114E0
    uxtb r5, r5                          @ 080114E8
    cmp r5, #0                           @ 080114EA
    bne .Lcurrent_extra_store_exit       @ 080114EC  if range != 0
    @ ---- v2.05 0x080114EE..0x08011508 replaced (see Deviation in the header) ----
    NVM_ARM USERZERO                        @ arm the USERZERO class for exactly one writer call
    movs r0, r4                             @ mode 16..21
    movs r1, r6                             @ value
    bl nvm_write_userzero                   @ NVM: writes marker 0xA5 and the value big endian into the record of the mode
.Lcurrent_extra_store_exit:   @ return
    pop {r0, r4, r5, r6, r7, pc}         @ 0801150C
    .ltorg
ENDFUNC current_extra_store

@ -----------------------------------------------------------------------------
@ current_extra_erase_all - write a zero user-zero record (marker 0xA5, value 0) for all six current modes
@ Replaces : 0x0801150E current_extra_erase_all (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only; NOT CALLED by the port (OF-08): calibration mode entry no longer clears the records
@ RAM      : reads  -
@            writes -
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-08; EEPROM_MAP.md 5.5
@ Deviation: OF-08 (kept as code, no caller; the calibration saves use current_extra_clear)
@ -----------------------------------------------------------------------------
FUNC current_extra_erase_all
    push {r7, lr}                        @ 0801150E
    movs r2, #0                          @ 08011510
    movs r1, #0                          @ 08011512
    movs r0, #0x10                       @ 08011514  = 16
    bl current_extra_store               @ 08011516  MVA: store the user zero
    movs r2, #0                          @ 0801151A
    movs r1, #0                          @ 0801151C
    movs r0, #0x11                       @ 0801151E  = 17
    bl current_extra_store               @ 08011520  MVA: store the user zero
    movs r2, #0                          @ 08011524
    movs r1, #0                          @ 08011526
    movs r0, #0x12                       @ 08011528  = 18
    bl current_extra_store               @ 0801152A  MVA: store the user zero
    movs r2, #0                          @ 0801152E
    movs r1, #0                          @ 08011530
    movs r0, #0x13                       @ 08011532  = 19
    bl current_extra_store               @ 08011534  MVA: store the user zero
    movs r2, #0                          @ 08011538
    movs r1, #0                          @ 0801153A
    movs r0, #0x14                       @ 0801153C  = 20
    bl current_extra_store               @ 0801153E  MVA: store the user zero
    movs r2, #0                          @ 08011542
    movs r1, #0                          @ 08011544
    movs r0, #0x15                       @ 08011546  = 21
    bl current_extra_store               @ 08011548  MVA: store the user zero
    pop {r0, pc}                         @ 0801154C
    .ltorg
ENDFUNC current_extra_erase_all

@ -----------------------------------------------------------------------------
@ current_extra_offset - EEPROM offset of the user-zero record of a current mode: 16 -> 0x4D0, 17 -> 0x4D8, 18 -> 0x4E0, 19 -> 0x4E8, 20 -> 0x4F0, 21 -> 0x4F8
@ Replaces : 0x0801154E current_extra_offset (v2.05)
@ In       : r0 = mode
@ Out      : r0 = offset (the mode itself for other modes; callers test the mode first)
@ Clobbers : r0, r1, r2, flags
@ Context  : main only; ISR-safe in effect (pure)
@ RAM      : reads  -
@            writes -
@ Spec     : EEPROM_MAP.md 5.5
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC current_extra_offset
    movs r1, r0                          @ 0801154E
    uxtb r1, r1                          @ 08011550
    cmp r1, #0x10                        @ 08011552
    beq .Lcurrent_extra_offset_0801156A  @ 08011554  if r1 == 16
    blo .Lcurrent_extra_offset_08011598  @ 08011556  if r1 < (unsigned) 16
    cmp r1, #0x12                        @ 08011558
    beq .Lcurrent_extra_offset_0801157A  @ 0801155A  if r1 == 18
    blo .Lcurrent_extra_offset_08011572  @ 0801155C  if r1 < (unsigned) 18
    cmp r1, #0x14                        @ 0801155E
    beq .Lcurrent_extra_offset_0801158A  @ 08011560  if r1 == 20
    blo .Lcurrent_extra_offset_08011582  @ 08011562  if r1 < (unsigned) 20
    cmp r1, #0x15                        @ 08011564
    beq .Lcurrent_extra_offset_08011592  @ 08011566  if r1 == 21
    b .Lcurrent_extra_offset_08011598    @ 08011568
.Lcurrent_extra_offset_0801156A:   @ branch target from 08011554
    mov r2, #0x4d0                       @ 0801156A  0x4D0: ACuA record
    movs r0, r2                          @ 0801156E
    b .Lcurrent_extra_offset_08011598    @ 08011570
.Lcurrent_extra_offset_08011572:   @ branch target from 0801155C
    mov r2, #0x4d8                       @ 08011572  0x4D8: DCuA record
    movs r0, r2                          @ 08011576
    b .Lcurrent_extra_offset_08011598    @ 08011578
.Lcurrent_extra_offset_0801157A:   @ branch target from 0801155A
    mov r2, #0x4e0                       @ 0801157A  0x4E0: ACmA record
    movs r0, r2                          @ 0801157E
    b .Lcurrent_extra_offset_08011598    @ 08011580
.Lcurrent_extra_offset_08011582:   @ branch target from 08011562
    mov r2, #0x4e8                       @ 08011582  0x4E8: DCmA record
    movs r0, r2                          @ 08011586
    b .Lcurrent_extra_offset_08011598    @ 08011588
.Lcurrent_extra_offset_0801158A:   @ branch target from 08011560
    mov r2, #0x4f0                       @ 0801158A  0x4F0: ACA record
    movs r0, r2                          @ 0801158E
    b .Lcurrent_extra_offset_08011598    @ 08011590
.Lcurrent_extra_offset_08011592:   @ branch target from 08011566
    mov r2, #0x4f8                       @ 08011592  0x4F8: DCA record
    movs r0, r2                          @ 08011596
.Lcurrent_extra_offset_08011598:   @ branch target from 08011556, 08011568, 08011570, 08011578, 08011580, 08011588, 08011590
    uxth r0, r0                          @ 08011598
    bx lr                                @ 0801159A
    .ltorg
ENDFUNC current_extra_offset


@ -----------------------------------------------------------------------------
@ current_extra_clear - clear the user zero of one mode (record A5 00 00 00 00) and the RAM copy
@ Replaces : new routine (DESIGN.md Appendix C.2, OF-08); the v2.05 calibration-mode entry cleared all six
@            records through current_extra_erase_all (0x0801150E, 0x0800EAF6)
@ In       : r0 = mode (16..21)
@ Out      : r0 = NVM status (0 written and verified, 1 refused or mode outside 16..21, 2 programming failed)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (CAL: range-0 offset save of a current mode)
@ RAM      : reads meter_mode, meter_range; writes user_zero (0x20007E0C) = 0 when the status is 0 and the mode is
@            active at range 0
@ Spec     : DESIGN.md 7.2 (OF-08), Appendix C.2; EEPROM_MAP.md 5.5
@ Deviation: OF-08
@ -----------------------------------------------------------------------------
FUNC current_extra_clear
    push {r4, lr}
    movs r4, r0                             @ r4 = mode
    subs r0, r4, #16
    cmp r0, #5
    bhi 3f                                  @ not a current mode 16..21 (unsigned compare covers below 16)
    NVM_ARM USERZERO                        @ arm the USERZERO class for exactly one writer call
    movs r0, r4
    movs r1, #0
    bl nvm_write_userzero                   @ record = A5 00 00 00 00; r0 = status
    cbnz r0, 2f                             @ not written: leave RAM as it is (it still equals the EEPROM)
    ldr r1, =meter_mode
    ldrb r1, [r1]
    cmp r1, r4
    bne 2f                                  @ the cleared record is not the active mode's
    ldr r1, =meter_range
    ldrb r1, [r1]
    cbnz r1, 2f                             @ the user zero applies at range 0 only
    movs r1, #0
    ldr r2, =v_20007E0C
    str r1, [r2]                            @ user_zero = 0
2:  pop {r4, pc}
3:  movs r0, #1                             @ refused: nothing written
    pop {r4, pc}
ENDFUNC current_extra_clear
    .ltorg
