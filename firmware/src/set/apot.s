@ =============================================================================
@ apot.s - SET/PWR: the auto power-off time (SETUP page APO, IMP-49, FEATURES.md 2.23)
@
@ v2.05's page APO (setup item 2, fn_08015A22 / fn_08018460) switches the auto power-off on or off (EEPROM 0x016,
@ set_apo_disable); the time is fixed at 30 min (60 min while MIN/MAX is on).  Here the page offers five values, stepped
@ with REL / PEAK as before: APO.oF (off), APO. 1, APO.15, APO.30, APO.60 (minutes).  0x016 keeps the on / off state as
@ v2.05 stores it (a meter flashed back to v2.05 keeps it); the time is the code in EEPROM 0x02B (EEPROM_MAP.md 4.1):
@ 0 = 30 min (also the value of an erased-to-zero or v2.05 backup byte), 1 = 1 min, 2 = 15 min, 3 = 60 min; any other
@ value reads as 30 min and the byte is left as found.  While MIN/MAX is on the time is doubled, as v2.05 doubles 30 to
@ 60 min.  The warning beeps start 60 s before the power-off, with the 1-minute time 15 s before (60 s would start them at
@ every key press).
@
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ APOT_EEPROM,    0x02B              @ EEPROM byte of the time code (EEPROM_MAP.md 4.1)
    .equ APOT_CODE_MAX,  3

    .section .bss_port.apot, "aw", %nobits
@ pwr_apo_code: the time code 0..3 (0 = 30 min, 1 = 1 min, 2 = 15 min, 3 = 60 min; owner SET, read by PWR)
    .global pwr_apo_code
pwr_apo_code:   .space 1

    .section .rodata.apot, "a", %progbits
    .balign 2
@ seconds of each code, before the MIN/MAX doubling
apot_seconds:   .hword 1800, 60, 900, 3600
@ the page text of each code (the decimal point after "APO" is set by fn_08017FB4(2), as v2.05 shows APO.oN)
apot_texts:     .ascii "APO30", "APO 1", "APO15", "APO60"
@ the page order of the values: index 0 is off, then 1, 15, 30, 60 minutes as codes
apot_order:     .byte 1, 2, 0, 3

    .section .text.set.apot, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_apot_load - read the time code from EEPROM 0x02B into pwr_apo_code
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (set_state_reset, the edit timeout fn_0800D190)
@ -----------------------------------------------------------------------------
FUNC set_apot_load
    push {r4, lr}
    movs r0, #APOT_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x02B (cache or EEPROM, NVM reader)
    cmp r0, #APOT_CODE_MAX
    bls 1f
    movs r0, #0                             @ anything else: 30 min, the v2.05 time
1:  ldr r1, =pwr_apo_code
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_apot_load

@ -----------------------------------------------------------------------------
@ set_apot_seconds - the auto power-off time in seconds for the current code and MIN/MAX state
@ In       : -
@ Out      : r0 = seconds (60 .. 7200)
@ Clobbers : r1, r2, flags
@ Context  : main (fn_0800ED26 reload)
@ -----------------------------------------------------------------------------
FUNC set_apot_seconds
    ldr r1, =pwr_apo_code
    ldrb r1, [r1]
    and r1, r1, #APOT_CODE_MAX              @ keeps the index inside the table
    ldr r2, =apot_seconds
    ldrh r0, [r2, r1, lsl #1]
    ldr r1, =minmax_state
    ldrb r1, [r1]
    cmp r1, #0
    it ne
    lslne r0, r0, #1                        @ MIN/MAX on: twice the time (v2.05: 30 -> 60 min)
    bx lr
ENDFUNC set_apot_seconds

@ -----------------------------------------------------------------------------
@ set_apot_warn_at - seconds left at which the warning beeps start
@ In       : -
@ Out      : r0 = 15 for the 1-minute time, else 60 (v2.05)
@ Clobbers : r1, flags
@ Context  : main (pwr_apo_second)
@ -----------------------------------------------------------------------------
FUNC set_apot_warn_at
    ldr r1, =pwr_apo_code
    ldrb r1, [r1]
    cmp r1, #1
    ite eq
    moveq r0, #15
    movne r0, #60
    bx lr
ENDFUNC set_apot_warn_at

@ -----------------------------------------------------------------------------
@ set_apot_step - REL / PEAK on the page APO: the next or the previous of APO.oF, APO. 1, APO.15, APO.30, APO.60
@ In       : r0 = 1 next, 2 previous
@ Out      : - (set_apo_disable and pwr_apo_code changed in RAM; nothing stored)
@ Clobbers : r0-r3, flags
@ Context  : main (fn_08015A22)
@ -----------------------------------------------------------------------------
FUNC set_apot_step
    ldr r2, =v_20008039                     @ set_apo_disable (v2.05 RAM, EEPROM 0x016)
    ldrb r1, [r2]
    movs r3, #0                             @ r3 = index of the current value
    cbnz r1, 2f                             @ off: index 0
    ldr r1, =pwr_apo_code
    ldrb r1, [r1]
    ldr r12, =apot_order
1:  ldrb r3, [r12], #1                      @ find the code in the order (always found: codes 0..3)
    cmp r3, r1
    bne 1b
    ldr r3, =apot_order
    sub r3, r12, r3                         @ index 1..4
2:  cmp r0, #1
    ite eq
    addeq r3, r3, #1
    addne r3, r3, #4                        @ previous = + 4 modulo 5
    cmp r3, #5
    it hs
    subhs r3, r3, #5
    cbnz r3, 3f
    movs r1, #1
    strb r1, [r2]                           @ index 0: off
    bx lr
3:  movs r1, #0
    strb r1, [r2]                           @ on
    ldr r1, =apot_order - 1
    ldrb r1, [r1, r3]
    ldr r2, =pwr_apo_code
    strb r1, [r2]
    bx lr
ENDFUNC set_apot_step
    .ltorg

@ -----------------------------------------------------------------------------
@ set_apot_store - save the time code to EEPROM 0x02B
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (fn_08015A22 save)
@ -----------------------------------------------------------------------------
FUNC set_apot_store
    push {r4, lr}
    ldr r1, =pwr_apo_code
    ldrb r1, [r1]
    movs r0, #APOT_EEPROM
    movs r2, #1
    bl set_nvm_store                        @ SETTINGS class, armed inside
    pop {r4, pc}
ENDFUNC set_apot_store

@ -----------------------------------------------------------------------------
@ set_apot_text - the 5-character text of the page APO while the auto power-off is on
@ In       : -
@ Out      : r0 = address of "APO30", "APO 1", "APO15" or "APO60"
@ Clobbers : r1, flags
@ Context  : main (fn_08018460)
@ -----------------------------------------------------------------------------
FUNC set_apot_text
    ldr r1, =pwr_apo_code
    ldrb r1, [r1]
    and r1, r1, #APOT_CODE_MAX
    add r1, r1, r1, lsl #2                  @ code * 5
    ldr r0, =apot_texts
    add r0, r0, r1
    bx lr
ENDFUNC set_apot_text
    .ltorg
