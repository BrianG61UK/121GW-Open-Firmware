@ =============================================================================
@ cache.s - CAL module: RAM image of the calibration EEPROM area (OPT-08)
@
@ cal_cache holds EEPROM offsets 0x000..0x4FF.  cal_cache_load fills it at boot and after every wake from STOP
@ (after set_state_reset, which still reads the EEPROM itself); from then on the NVM readers return cache bytes
@ and the NVM byte program writes every confirmed byte into the cache as well (src/nvm/flash.s,
@ nvm_program_byte); a byte program that is not confirmed clears cal_cache_valid, so the readers fall back to the
@ EEPROM until the next cal_cache_load.  The readers therefore always return the EEPROM content and readings are
@ identical to v2.05, which reads the EEPROM at every mode/range application (DESIGN.md 6.20, 11 OPT-08;
@ analysis/autorange_and_scheduler.md 5.2 P6).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .equ CAL_CACHE_SIZE, 0x500              @ EEPROM 0x000..0x4FF (highest v2.05 offset 0x4FC, EEPROM_MAP.md 4)

    .section .bss_port.cal, "aw", %nobits
    .align 2
    .global cal_cache, cal_cache_valid
cal_cache:       .space CAL_CACHE_SIZE      @ EEPROM image 0x000..0x4FF
cal_cache_valid: .space 1                   @ 1 after cal_cache_load; the readers use the cache only then
    .align 2

    .section .text.cal, "ax", %progbits

@ -----------------------------------------------------------------------------
@ cal_cache_load - copy EEPROM 0x000..0x4FF into cal_cache and enable the cached readers
@ Replaces : nothing in v2.05 (new, OPT-08)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main (sys_main after set_state_reset; enter_stop_and_reinit after set_state_reset)
@ RAM      : writes cal_cache, cal_cache_valid
@ Spec     : DESIGN.md 3.2 step 5, 6.20, Appendix C.2
@ -----------------------------------------------------------------------------
FUNC cal_cache_load
    push {r4, lr}
    ldr r4, =cal_cache_valid
    movs r0, #0
    strb r0, [r4]                           @ readers use the EEPROM while the copy is in progress
    movs r0, #0                             @ first offset
    ldr r1, =cal_cache                      @ destination
    mov r2, #CAL_CACHE_SIZE                 @ count
    bl nvm_read_block                       @ direct EEPROM reads (NVM holds the EEPROM base)
    cbnz r0, 1f                             @ refused (cannot happen for 0x000..0x4FF): stay uncached
    movs r0, #1
    strb r0, [r4]                           @ cache valid
1:  pop {r4, pc}
ENDFUNC cal_cache_load

    .ltorg
