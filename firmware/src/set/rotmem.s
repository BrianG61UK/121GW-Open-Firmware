@ =============================================================================
@ rotmem.s - SET: rotary memory
@
@ SET module, part 2: rotary memory (EEPROM 0x008..0x00E).
@
@ Replaces the v2.05 routines 0x08010FF0..0x08011154 (analysis/rotary.md, EEPROM_MAP.md 3).  The readers
@ map the stored byte to the mode of the dial group, with a fixed default for any unknown value, so
@ meter_mode is always 0..24 whatever the EEPROM holds (EEPROM_MAP.md 6).  The writer stores through
@ set_nvm_store (NVM class SETTINGS).  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.set, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08010FF0 - read the rotary memory V position (EEPROM 0x008)
@ Replaces : 0x08010FF0 FUN_08010FF0 (v2.05)
@ In       : -
@ Out      : r0 = mode to select for that dial position
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (dial latch, analysis/rotary.md)
@ Spec     : EEPROM_MAP.md 4; analysis/rotary.md. Stored value: 0x82 = ACV with AC+DC (selects mode 2 and calls
@            fn_0801472C), 1 DCV or 2 ACV kept, else 1
@ -----------------------------------------------------------------------------
FUNC fn_08010FF0
    push {r3, r4, r5, lr}                   @ 08010FF0
    movs r5, #0x1                           @ 08010FF2
    movs r0, #0x8                           @ 08010FF4
    bl eeprom_read_u8                       @ 08010FF6  read EEPROM byte at offset r0 [r0=8]
    movs r4, r0                             @ 08010FFA
    uxtb r4, r4                             @ 08010FFC
    cmp r4, #0x82                           @ 08010FFE  compare r4 with 130 (0x82)
    bne .L0801100C                          @ 08011000  if r4 != 130 (0x82)
    movs r0, #0x2                           @ 08011002
    movs r5, r0                             @ 08011004
    bl fn_0801472C                          @ 08011006  select the AC+DC variant of ACV [r0=2]
    b .L0801101A                            @ 0801100A
.L0801100C:  @ reached from 08011000 bne (r4 != 130 (0x82))
    uxtb r4, r4                             @ 0801100C
    cmp r4, #0x1                            @ 0801100E  compare r4 with 1
    beq .L08011018                          @ 08011010  if r4 == 1
    uxtb r4, r4                             @ 08011012
    cmp r4, #0x2                            @ 08011014  compare r4 with 2
    bne .L0801101A                          @ 08011016  if r4 != 2
.L08011018:  @ reached from 08011010 beq (r4 == 1)
    movs r5, r4                             @ 08011018
.L0801101A:  @ reached from 0801100A b, 08011016 bne (r4 != 2)
    movs r0, r5                             @ 0801101A
    uxtb r0, r0                             @ 0801101C
    pop {r1, r4, r5, pc}                    @ 0801101E
ENDFUNC fn_08010FF0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011020 - read the rotary memory mV position (EEPROM 0x009)
@ Replaces : 0x08011020 FUN_08011020 (v2.05)
@ In       : -
@ Out      : r0 = mode to select for that dial position
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (dial latch, analysis/rotary.md)
@ Spec     : EEPROM_MAP.md 4; analysis/rotary.md. Stored value: 3, 4 or 5 kept, else 3
@ -----------------------------------------------------------------------------
FUNC fn_08011020
    push {r3, r4, r5, lr}                   @ 08011020
    movs r5, #0x3                           @ 08011022
    movs r0, #0x9                           @ 08011024
    bl eeprom_read_u8                       @ 08011026  read EEPROM byte at offset r0 [r0=9]
    movs r4, r0                             @ 0801102A
    uxtb r4, r4                             @ 0801102C
    cmp r4, #0x3                            @ 0801102E  compare r4 with 3
    beq .L0801103E                          @ 08011030  if r4 == 3
    uxtb r4, r4                             @ 08011032
    cmp r4, #0x4                            @ 08011034  compare r4 with 4
    beq .L0801103E                          @ 08011036  if r4 == 4
    uxtb r4, r4                             @ 08011038
    cmp r4, #0x5                            @ 0801103A  compare r4 with 5
    bne .L08011040                          @ 0801103C  if r4 != 5
.L0801103E:  @ reached from 08011030 beq (r4 == 3), 08011036 beq (r4 == 4)
    movs r5, r4                             @ 0801103E
.L08011040:  @ reached from 0801103C bne (r4 != 5)
    movs r0, r5                             @ 08011040
    uxtb r0, r0                             @ 08011042
    pop {r1, r4, r5, pc}                    @ 08011044
ENDFUNC fn_08011020
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011046 - read the rotary memory Hz position (EEPROM 0x00A)
@ Replaces : 0x08011046 FUN_08011046 (v2.05)
@ In       : -
@ Out      : r0 = mode to select for that dial position
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (dial latch, analysis/rotary.md)
@ Spec     : EEPROM_MAP.md 4; analysis/rotary.md. Stored value: 6, 7 or 8 kept, else 6
@ -----------------------------------------------------------------------------
FUNC fn_08011046
    push {r3, r4, r5, lr}                   @ 08011046
    movs r5, #0x6                           @ 08011048
    movs r0, #0xa                           @ 0801104A
    bl eeprom_read_u8                       @ 0801104C  read EEPROM byte at offset r0 [r0=10 (0xA)]
    movs r4, r0                             @ 08011050
    uxtb r4, r4                             @ 08011052
    cmp r4, #0x6                            @ 08011054  compare r4 with 6
    beq .L08011064                          @ 08011056  if r4 == 6
    uxtb r4, r4                             @ 08011058
    cmp r4, #0x7                            @ 0801105A  compare r4 with 7
    beq .L08011064                          @ 0801105C  if r4 == 7
    uxtb r4, r4                             @ 0801105E
    cmp r4, #0x8                            @ 08011060  compare r4 with 8
    bne .L08011066                          @ 08011062  if r4 != 8
.L08011064:  @ reached from 08011056 beq (r4 == 6), 0801105C beq (r4 == 7)
    movs r5, r4                             @ 08011064
.L08011066:  @ reached from 08011062 bne (r4 != 8)
    movs r0, r5                             @ 08011066
    uxtb r0, r0                             @ 08011068
    pop {r1, r4, r5, pc}                    @ 0801106A
ENDFUNC fn_08011046
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801106C - read the rotary memory ohm position (EEPROM 0x00B)
@ Replaces : 0x0801106C FUN_0801106C (v2.05)
@ In       : -
@ Out      : r0 = mode to select for that dial position
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (dial latch, analysis/rotary.md)
@ Spec     : EEPROM_MAP.md 4; analysis/rotary.md. Stored value: 9..12 kept, else 9
@ -----------------------------------------------------------------------------
FUNC fn_0801106C
    push {r3, r4, r5, lr}                   @ 0801106C
    movs r5, #0x9                           @ 0801106E
    movs r0, #0xb                           @ 08011070
    bl eeprom_read_u8                       @ 08011072  read EEPROM byte at offset r0 [r0=11 (0xB)]
    movs r4, r0                             @ 08011076
    uxtb r4, r4                             @ 08011078
    cmp r4, #0x9                            @ 0801107A  compare r4 with 9
    beq .L08011090                          @ 0801107C  if r4 == 9
    uxtb r4, r4                             @ 0801107E
    cmp r4, #0xa                            @ 08011080  compare r4 with 10 (0xA)
    beq .L08011090                          @ 08011082  if r4 == 10 (0xA)
    uxtb r4, r4                             @ 08011084
    cmp r4, #0xb                            @ 08011086  compare r4 with 11 (0xB)
    beq .L08011090                          @ 08011088  if r4 == 11 (0xB)
    uxtb r4, r4                             @ 0801108A
    cmp r4, #0xc                            @ 0801108C  compare r4 with 12 (0xC)
    bne .L08011092                          @ 0801108E  if r4 != 12 (0xC)
.L08011090:  @ reached from 0801107C beq (r4 == 9), 08011082 beq (r4 == 10 (0xA)), 08011088 beq (r4 == 11 (0xB))
    movs r5, r4                             @ 08011090
.L08011092:  @ reached from 0801108E bne (r4 != 12 (0xC))
    movs r0, r5                             @ 08011092
    uxtb r0, r0                             @ 08011094
    pop {r1, r4, r5, pc}                    @ 08011096
ENDFUNC fn_0801106C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011098 - read the rotary memory VA position (EEPROM 0x00C)
@ Replaces : 0x08011098 FUN_08011098 (v2.05)
@ In       : -
@ Out      : r0 = mode to select for that dial position
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (dial latch, analysis/rotary.md)
@ Spec     : EEPROM_MAP.md 4; analysis/rotary.md. Stored value: 0x18 or 0x0F kept, else 0x18
@ -----------------------------------------------------------------------------
FUNC fn_08011098
    push {r3, r4, r5, lr}                   @ 08011098
    movs r5, #0x18                          @ 0801109A
    movs r0, #0xc                           @ 0801109C
    bl eeprom_read_u8                       @ 0801109E  read EEPROM byte at offset r0 [r0=12 (0xC)]
    movs r4, r0                             @ 080110A2
    uxtb r4, r4                             @ 080110A4
    cmp r4, #0x18                           @ 080110A6  compare r4 with 24 (0x18)
    beq .L080110B0                          @ 080110A8  if r4 == 24 (0x18)
    uxtb r4, r4                             @ 080110AA
    cmp r4, #0xf                            @ 080110AC  compare r4 with 15 (0xF)
    bne .L080110B2                          @ 080110AE  if r4 != 15 (0xF)
.L080110B0:  @ reached from 080110A8 beq (r4 == 24 (0x18))
    movs r5, r4                             @ 080110B0
.L080110B2:  @ reached from 080110AE bne (r4 != 15 (0xF))
    movs r0, r5                             @ 080110B2
    uxtb r0, r0                             @ 080110B4
    pop {r1, r4, r5, pc}                    @ 080110B6
ENDFUNC fn_08011098
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080110B8 - read the rotary memory uA position (EEPROM 0x00D)
@ Replaces : 0x080110B8 FUN_080110B8 (v2.05)
@ In       : -
@ Out      : r0 = mode to select for that dial position
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (dial latch, analysis/rotary.md)
@ Spec     : EEPROM_MAP.md 4; analysis/rotary.md. Stored value: 0x11, 0x10, 0x0D or 0x16 kept, else 0x11
@ -----------------------------------------------------------------------------
FUNC fn_080110B8
    push {r3, r4, r5, lr}                   @ 080110B8
    movs r5, #0x11                          @ 080110BA
    movs r0, #0xd                           @ 080110BC
    bl eeprom_read_u8                       @ 080110BE  read EEPROM byte at offset r0 [r0=13 (0xD)]
    movs r4, r0                             @ 080110C2
    uxtb r4, r4                             @ 080110C4
    cmp r4, #0x11                           @ 080110C6  compare r4 with 17 (0x11)
    beq .L080110DC                          @ 080110C8  if r4 == 17 (0x11)
    uxtb r4, r4                             @ 080110CA
    cmp r4, #0x10                           @ 080110CC  compare r4 with 16 (0x10)
    beq .L080110DC                          @ 080110CE  if r4 == 16 (0x10)
    uxtb r4, r4                             @ 080110D0
    cmp r4, #0xd                            @ 080110D2  compare r4 with 13 (0xD)
    beq .L080110DC                          @ 080110D4  if r4 == 13 (0xD)
    uxtb r4, r4                             @ 080110D6
    cmp r4, #0x16                           @ 080110D8  compare r4 with 22 (0x16)
    bne .L080110DE                          @ 080110DA  if r4 != 22 (0x16)
.L080110DC:  @ reached from 080110C8 beq (r4 == 17 (0x11)), 080110CE beq (r4 == 16 (0x10)), 080110D4 beq (r4 == 13 (0xD))
    movs r5, r4                             @ 080110DC
.L080110DE:  @ reached from 080110DA bne (r4 != 22 (0x16))
    movs r0, r5                             @ 080110DE
    uxtb r0, r0                             @ 080110E0
    pop {r1, r4, r5, pc}                    @ 080110E2
ENDFUNC fn_080110B8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080110E4 - read the rotary memory A/mA position (EEPROM 0x00E)
@ Replaces : 0x080110E4 FUN_080110E4 (v2.05)
@ In       : -
@ Out      : r0 = mode to select for that dial position
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (dial latch, analysis/rotary.md)
@ Spec     : EEPROM_MAP.md 4; analysis/rotary.md. Stored value: 0x13 or 0x15 give 0x13, 0x12 or 0x14 give 0x12, else
@            0x13
@ -----------------------------------------------------------------------------
FUNC fn_080110E4
    push {r3, r4, r5, lr}                   @ 080110E4
    movs r5, #0x13                          @ 080110E6
    movs r0, #0xe                           @ 080110E8
    bl eeprom_read_u8                       @ 080110EA  read EEPROM byte at offset r0 [r0=14 (0xE)]
    movs r4, r0                             @ 080110EE
    uxtb r4, r4                             @ 080110F0
    cmp r4, #0x13                           @ 080110F2  compare r4 with 19 (0x13)
    beq .L080110FC                          @ 080110F4  if r4 == 19 (0x13)
    uxtb r4, r4                             @ 080110F6
    cmp r4, #0x15                           @ 080110F8  compare r4 with 21 (0x15)
    bne .L08011102                          @ 080110FA  if r4 != 21 (0x15)
.L080110FC:  @ reached from 080110F4 beq (r4 == 19 (0x13))
    movs r0, #0x13                          @ 080110FC
    movs r5, r0                             @ 080110FE
    b .L08011112                            @ 08011100
.L08011102:  @ reached from 080110FA bne (r4 != 21 (0x15))
    uxtb r4, r4                             @ 08011102
    cmp r4, #0x12                           @ 08011104  compare r4 with 18 (0x12)
    beq .L0801110E                          @ 08011106  if r4 == 18 (0x12)
    uxtb r4, r4                             @ 08011108
    cmp r4, #0x14                           @ 0801110A  compare r4 with 20 (0x14)
    bne .L08011112                          @ 0801110C  if r4 != 20 (0x14)
.L0801110E:  @ reached from 08011106 beq (r4 == 18 (0x12))
    movs r0, #0x12                          @ 0801110E
    movs r5, r0                             @ 08011110
.L08011112:  @ reached from 08011100 b, 0801110C bne (r4 != 20 (0x14))
    movs r0, r5                             @ 08011112
    uxtb r0, r0                             @ 08011114
    pop {r1, r4, r5, pc}                    @ 08011116
ENDFUNC fn_080110E4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08011118 - store one rotary memory byte
@ Replaces : 0x08011118 FUN_08011118 (v2.05)
@ In       : r0 = EEPROM offset 0x008..0x00E, r1 = value
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ Context  : main only (rotary_memory_store)
@ RAM      : reads acdc_active
@ Spec     : EEPROM_MAP.md 3, 7.1
@ Deviation: the write goes through set_nvm_store (NVM class SETTINGS) instead of eeprom_write_u8
@ Note     : Offset 8 with value 2 (ACV) stores 0x82 when the AC+DC flag acdc_active (0x200080BA) is set (v2.05
@            0x08011120..0x08011134).
@ -----------------------------------------------------------------------------
FUNC fn_08011118
    push {r3, r4, r5, lr}                   @ 08011118
    movs r4, r0                             @ 0801111A
    movs r5, r1                             @ 0801111C
    uxtb r4, r4                             @ 0801111E
    cmp r4, #0x8                            @ 08011120  compare r4 with 8
    bne .L08011138                          @ 08011122  if r4 != 8
    uxtb r5, r5                             @ 08011124
    cmp r5, #0x2                            @ 08011126  compare r5 with 2
    bne .L08011138                          @ 08011128  if r5 != 2
    ldr.w r0, =acdc_active                  @ 0801112A
    ldrb r0, [r0, #0x0]                     @ 0801112E  r0 = acdc_active
    cmp r0, #0x0                            @ 08011130  compare acdc_active with 0
    beq .L08011138                          @ 08011132  if acdc_active == 0
    orrs r5, r5, #0x80                      @ 08011134  r5 = r5 | 128 (0x80)
.L08011138:  @ reached from 08011122 bne (r4 != 8), 08011128 bne (r5 != 2), 08011132 beq (acdc_active == 0)
    movs r1, r5                             @ 08011138
    uxtb r1, r1                             @ 0801113A
    uxtb r4, r4                             @ 0801113C
    movs r0, r4                             @ 0801113E
    movs r2, #1                          @ width 1 byte @ 08011140
    bl set_nvm_store                        @         
    pop {r0, r4, r5, pc}                    @ 08011144
ENDFUNC fn_08011118
    .ltorg

@ -----------------------------------------------------------------------------
@ rotary_memory_store - remember the selected mode in the rotary memory byte of its dial group
@ Replaces : 0x08011154 rotary_memory_store (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main only (MODE, after a MODE short that changed the mode)
@ RAM      : reads meter_mode
@ Spec     : EEPROM_MAP.md 3 and 7.1 (offsets 0x08..0x0E); analysis/keys_setup.md 5.1
@ Note     : Dispatch on meter_mode: 1, 2 -> 0x08; 3..5 -> 0x09; 6..8 -> 0x0A; 9..12 -> 0x0B; 14, 15, 23, 24 -> 0x0C
@            (0x18 for 23 and 24, else 0x0F); 13, 16, 17, 22 -> 0x0D; 18..21 -> 0x0E; all through fn_08011118.  The
@            compare ladder of v2.05 (0x08011156..0x08011194) is kept.
@ -----------------------------------------------------------------------------
FUNC rotary_memory_store
    push {r4, lr}                           @ 08011154
    ldr.w r0, =meter_mode                   @ 08011156
    ldrb r0, [r0, #0x0]                     @ 0801115A  r0 = meter_mode
    subs r0, r0, #0x1                       @ 0801115C  r0 = meter_mode - 1
    cmp r0, #0x1                            @ 0801115E  compare (meter_mode - 1) with 1
    bls .L08011196                          @ 08011160  if (meter_mode - 1) <=u 1
    subs r0, r0, #0x2                       @ 08011162  r0 = (meter_mode - 1) - 2
    cmp r0, #0x2                            @ 08011164  compare ((meter_mode - 1) - 2) with 2
    bls .L080111A4                          @ 08011166  if ((meter_mode - 1) - 2) <=u 2
    subs r0, r0, #0x3                       @ 08011168  r0 = ((meter_mode - 1) - 2) - 3
    cmp r0, #0x2                            @ 0801116A  compare (((meter_mode - 1) - 2) - 3) with 2
    bls .L080111B2                          @ 0801116C  if (((meter_mode - 1) - 2) - 3) <=u 2
    subs r0, r0, #0x3                       @ 0801116E  r0 = (((meter_mode - 1) - 2) - 3) - 3
    cmp r0, #0x3                            @ 08011170  compare ((((meter_mode - 1) - 2) - 3) - 3) with 3
    bls .L080111C0                          @ 08011172  if ((((meter_mode - 1) - 2) - 3) - 3) <=u 3
    subs r0, r0, #0x4                       @ 08011174  r0 = ((((meter_mode - 1) - 2) - 3) - 3) - 4
    beq .L080111F8                          @ 08011176  if (((((meter_mode - 1) - 2) - 3) - 3) - 4) == 0
    subs r0, r0, #0x1                       @ 08011178  r0 = (((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1
    cmp r0, #0x1                            @ 0801117A  compare ((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) with 1
    bls .L080111CE                          @ 0801117C  if ((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) <=u 1
    subs r0, r0, #0x2                       @ 0801117E  r0 = ((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2
    cmp r0, #0x1                            @ 08011180  compare (((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) with 1
    bls .L080111F8                          @ 08011182  if (((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) <=u 1
    subs r0, r0, #0x2                       @ 08011184  r0 = (((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2
    cmp r0, #0x3                            @ 08011186  compare ((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) with 3
    bls .L08011206                          @ 08011188  if ((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) <=u 3
    subs r0, r0, #0x4                       @ 0801118A  r0 = ((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) - 4
    beq .L080111F8                          @ 0801118C  if (((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) - 4) == 0
    subs r0, r0, #0x1                       @ 0801118E  r0 = (((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) - 4) - 1
    cmp r0, #0x1                            @ 08011190  compare ((((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) - 4) - 1) with 1
    bls .L080111CE                          @ 08011192  if ((((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) - 4) - 1) <=u 1
    b .L08011212                            @ 08011194
.L08011196:  @ reached from 08011160 bls ((meter_mode - 1) <=u 1)
    ldr.w r0, =meter_mode                   @ 08011196
    ldrb r1, [r0, #0x0]                     @ 0801119A  r1 = meter_mode
    movs r0, #0x8                           @ 0801119C
    bl fn_08011118                          @ 0801119E  store a rotary memory byte (offset r0, value r1) [r0=8, r1=meter_mode]
    b .L08011212                            @ 080111A2
.L080111A4:  @ reached from 08011166 bls (((meter_mode - 1) - 2) <=u 2)
    ldr.w r0, =meter_mode                   @ 080111A4
    ldrb r1, [r0, #0x0]                     @ 080111A8  r1 = meter_mode
    movs r0, #0x9                           @ 080111AA
    bl fn_08011118                          @ 080111AC  store a rotary memory byte (offset r0, value r1) [r0=9, r1=meter_mode]
    b .L08011212                            @ 080111B0
.L080111B2:  @ reached from 0801116C bls ((((meter_mode - 1) - 2) - 3) <=u 2)
    ldr.w r0, =meter_mode                   @ 080111B2
    ldrb r1, [r0, #0x0]                     @ 080111B6  r1 = meter_mode
    movs r0, #0xa                           @ 080111B8
    bl fn_08011118                          @ 080111BA  store a rotary memory byte (offset r0, value r1) [r0=10 (0xA), r1=meter_mode]
    b .L08011212                            @ 080111BE
.L080111C0:  @ reached from 08011172 bls (((((meter_mode - 1) - 2) - 3) - 3) <=u 3)
    ldr.w r0, =meter_mode                   @ 080111C0
    ldrb r1, [r0, #0x0]                     @ 080111C4  r1 = meter_mode
    movs r0, #0xb                           @ 080111C6
    bl fn_08011118                          @ 080111C8  store a rotary memory byte (offset r0, value r1) [r0=11 (0xB), r1=meter_mode]
    b .L08011212                            @ 080111CC
.L080111CE:  @ reached from 0801117C bls (((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) <=u 1), 08011192 bls (((((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) - 4) - 1) <=u 1)
    ldr.w r0, =meter_mode                   @ 080111CE
    ldrb r0, [r0, #0x0]                     @ 080111D2  r0 = meter_mode
    cmp r0, #0x18                           @ 080111D4  compare meter_mode with 24 (0x18)
    beq .L080111E2                          @ 080111D6  if meter_mode == 24 (0x18)
    ldr.w r0, =meter_mode                   @ 080111D8
    ldrb r0, [r0, #0x0]                     @ 080111DC  r0 = meter_mode
    cmp r0, #0x17                           @ 080111DE  compare meter_mode with 23 (0x17)
    bne .L080111E8                          @ 080111E0  if meter_mode != 23 (0x17)
.L080111E2:  @ reached from 080111D6 beq (meter_mode == 24 (0x18))
    movs r0, #0x18                          @ 080111E2
    movs r4, r0                             @ 080111E4
    b .L080111EC                            @ 080111E6
.L080111E8:  @ reached from 080111E0 bne (meter_mode != 23 (0x17))
    movs r0, #0xf                           @ 080111E8
    movs r4, r0                             @ 080111EA
.L080111EC:  @ reached from 080111E6 b
    movs r1, r4                             @ 080111EC
    uxtb r1, r1                             @ 080111EE
    movs r0, #0xc                           @ 080111F0
    bl fn_08011118                          @ 080111F2  store a rotary memory byte (offset r0, value r1) [r0=12 (0xC)]
    b .L08011212                            @ 080111F6
.L080111F8:  @ reached from 08011176 beq ((((((meter_mode - 1) - 2) - 3) - 3) - 4) == 0), 08011182 bls ((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) <=u 1), 0801118C beq ((((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) - 4) == 0)
    ldr.w r0, =meter_mode                   @ 080111F8
    ldrb r1, [r0, #0x0]                     @ 080111FC  r1 = meter_mode
    movs r0, #0xd                           @ 080111FE
    bl fn_08011118                          @ 08011200  store a rotary memory byte (offset r0, value r1) [r0=13 (0xD), r1=meter_mode]
    b .L08011212                            @ 08011204
.L08011206:  @ reached from 08011188 bls (((((((((meter_mode - 1) - 2) - 3) - 3) - 4) - 1) - 2) - 2) <=u 3)
    ldr.w r0, =meter_mode                   @ 08011206
    ldrb r1, [r0, #0x0]                     @ 0801120A  r1 = meter_mode
    movs r0, #0xe                           @ 0801120C
    bl fn_08011118                          @ 0801120E  store a rotary memory byte (offset r0, value r1) [r0=14 (0xE), r1=meter_mode]
.L08011212:  @ reached from 08011194 b, 080111A2 b, 080111B0 b, 080111BE b, 080111CC b, 080111F6 b, 08011204 b
    pop {r4, pc}                            @ 08011212
ENDFUNC rotary_memory_store
    .ltorg
