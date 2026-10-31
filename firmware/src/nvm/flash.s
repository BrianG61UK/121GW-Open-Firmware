@ =============================================================================
@ flash.s - NVM module: FLASH interface driver and the single data-EEPROM byte program path
@
@ This file holds the only instructions of the image that write the FLASH interface registers FLASH_PECR,
@ FLASH_PEKEYR and FLASH_SR and the only store to the data EEPROM (DESIGN.md 4.6, 6.21; EEPROM_MAP.md 9.1-9.3).
@ It replaces the v2.05 FLASH driver functions 0x0801F9FC (DATA_EEPROM_Unlock), 0x0801FA1C (DATA_EEPROM_Lock),
@ 0x0801FA2E (DATA_EEPROM_ProgramByte), 0x0801FAFA (FLASH_ClearFlag), 0x0801FB00 (FLASH_GetStatus), 0x0801FB60
@ (FLASH_WaitForLastOperation) and the byte layer 0x080120F0 (eeprom_program_byte) and 0x08012148
@ (eeprom_write_byte_retry).
@
@ Rules kept here (EEPROM_MAP.md 9.1 item 3, 9.3):
@   - every FLASH register is addressed through its own literal with offset 0 (DESIGN.md 8.2);
@   - FLASH_PECR is only ever written with PELOCK set (lock) or FTDW cleared (byte write mode); ERASE, PROG,
@     DATA, FPRG and OBL_LAUNCH are never set;
@   - FLASH_PEKEYR receives exactly the two PEKEY words, once, and only when PELOCK reads 1 (v2.05
@     0x0801FA02..0x0801FA18; a key write while unlocked or a wrong key is a bus error, RM0038 3.9.2/3.9.4);
@   - PELOCK is set again on every exit of an attempt, including timeouts and refusals;
@   - immediately before the `strb` the offset is recomputed from the address register used by the store and
@     checked against 0x4FC and the class bitmap nvm_allow, and a writer session of that class must be open
@     (EEPROM_MAP.md 9.3 items 1-2), so a stray call of the byte program cannot store;
@   - FLASH_SR error flags are cleared before every attempt and every written byte is read back (NVM-1);
@   - option bytes, FLASH_PRGKEYR, FLASH_OPTKEYR, FLASH_WRPRx and program flash are never addressed (NF-03).
@ Context: main only (DESIGN.md 6.21).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "nvm_allow.inc"

@ Data-EEPROM base and the PEKEYR key words exist only in the NVM objects (DESIGN.md 6.21, 9.3 item 2).
    .equ NVM_EE_BASE,       0x08080000      @ data EEPROM, RM0038 Table 10 (v2.05 literal pool 0x0801240C)
    .equ NVM_EE_LAST,       0x4FC           @ highest offset v2.05 accesses (EEPROM_MAP.md 4)
    .equ NVM_PEKEY1,        0x89ABCDEF      @ RM0038 3.9.4 (v2.05 0x0801FA06)
    .equ NVM_PEKEY2,        0x02030405      @ RM0038 3.9.4 (v2.05 0x0801FA10)
    .equ NVM_SR_ERRORS,     0x00001F00      @ FLASH_SR bits 8..12: WRPERR, PGAERR, SIZERR, OPTVERR, OPTVERRUSR
    .equ NVM_SR_ERR_OTHER,  0x00001E00      @ bits 9..12, v2.05 FLASH_GetStatus status 3 (0x0801FB22)
    .equ NVM_WAIT_POLLS,    0x8000          @ v2.05 FLASH_WaitForLastOperation argument (0x0801FA36, 0x0801FA58)
    .equ NVM_ATTEMPTS,      10              @ v2.05 eeprom_write_byte_retry bound (0x08012158 cmp r8,#0xa)
    .equ NVM_SESSION_TAG,   0xC0            @ nvm_session = NVM_SESSION_TAG | class while a writer runs (nvm.s)

@ FLASH status codes of v2.05 (FLASH_GetStatus 0x0801FB00, FLASH_WaitForLastOperation 0x0801FB60)
    .equ FST_BUSY,          1
    .equ FST_WRPERR,        2
    .equ FST_ERROR,         3
    .equ FST_COMPLETE,      4
    .equ FST_TIMEOUT,       5
    .equ FST_REFUSED,       6               @ port only: refused by the store-time re-check, nothing stored
    .equ FST_NOUNLOCK,      7               @ port only: PELOCK still set after the key sequence, nothing stored

    .section .text.nvm, "ax", %progbits

@ -----------------------------------------------------------------------------
@ nvm_reset_lock - lock the data EEPROM, program flash and option bytes at reset
@ Replaces : nothing in v2.05 (v2.05 locks only at the end of its first byte program, 0x0801FA1C; the
@            bootloader leaves FLASH_PECR = 0x00000004, EEPROM_MAP.md 2.5)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : reset (sys_reset, before any other work), any
@ Spec     : DESIGN.md 3.2 step 1, 6.21; EEPROM_MAP.md 9.3 item 3; RM0038 3.9.2 (PRGLOCK and OPTLOCK are set
@            when PELOCK is set)
@ Deviation: NF-13
@ -----------------------------------------------------------------------------
FUNC nvm_reset_lock
    ldr r1, =FLASH_PECR                     @ FLASH_PECR, own literal, offset 0
    ldr r0, [r1]
    tst r0, #FLASH_PECR_PELOCK              @ already locked: no write to the locked register
    bne 1f
    orr r0, r0, #FLASH_PECR_PELOCK          @ set PELOCK only; every other bit as read
    str r0, [r1]
1:  bx lr
ENDFUNC nvm_reset_lock

@ -----------------------------------------------------------------------------
@ nvm_clear_errors - clear FLASH_SR end-of-operation and error flags at start-up
@ Replaces : the FLASH_SR <- 0x1F02 store of FUN_0801BE76 (0x0801BEA4..0x0801BEA8)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main (sys_system_init)
@ Spec     : DESIGN.md 3.2 step 5, 6.21; EEPROM_MAP.md 2.3
@ -----------------------------------------------------------------------------
FUNC nvm_clear_errors
    ldr r1, =FLASH_SR                       @ FLASH_SR, own literal, offset 0
    movw r0, #FLASH_SR_CLEAR_ALL            @ 0x1F02: EOP and bits 8..12 (write 1 to clear, RM0038 3.9.7)
    str r0, [r1]
    bx lr
ENDFUNC nvm_clear_errors

@ -----------------------------------------------------------------------------
@ nvm_flash_status - status of the FLASH interface
@ Replaces : 0x0801FB00 FLASH_GetStatus (v2.05 reads FLASH_SR up to three times; one read gives the same
@            result because reading FLASH_SR has no side effect, RM0038 3.9.7)
@ In       : -
@ Out      : r0 = 1 busy (BSY), 2 WRPERR, 3 any of bits 9..12, 4 complete (v2.05 order of tests)
@ Clobbers : r1, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_flash_status
    ldr r1, =FLASH_SR                       @ FLASH_SR, own literal, offset 0
    ldr r1, [r1]
    movs r0, #FST_BUSY
    tst r1, #1                              @ BSY (bit 0), first test as 0x0801FB06
    bne 1f
    movs r0, #FST_WRPERR
    tst r1, #0x100                          @ WRPERR (bit 8), as 0x0801FB14
    bne 1f
    movs r0, #FST_ERROR
    tst r1, #NVM_SR_ERR_OTHER               @ bits 9..12, as 0x0801FB22
    bne 1f
    movs r0, #FST_COMPLETE
1:  bx lr
ENDFUNC nvm_flash_status

@ -----------------------------------------------------------------------------
@ nvm_flash_wait - wait while the FLASH interface is busy, bounded
@ Replaces : 0x0801FB60 FLASH_WaitForLastOperation
@ In       : r0 = poll bound (v2.05 always passes 0x8000)
@ Out      : r0 = last status (1..4), or 5 when the bound ran out (v2.05: status 5 whenever the counter is 0
@            after the loop, 0x0801FB8C..0x0801FB92, also when the last poll was not busy)
@ Clobbers : r1, r2, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_flash_wait
    push {r4, lr}
    mov r4, r0                              @ r4 = remaining polls
    bl nvm_flash_status                     @ first status, as 0x0801FB6C
1:  cmp r0, #FST_BUSY                       @ loop while busy and polls remain (0x0801FB78..0x0801FB8A)
    bne 2f
    cbz r4, 2f
    bl nvm_flash_status
    subs r4, r4, #1
    b 1b
2:  cbnz r4, 3f                             @ counter exhausted: timeout status (0x0801FB8C..0x0801FB92)
    movs r0, #FST_TIMEOUT
3:  pop {r4, pc}
ENDFUNC nvm_flash_wait

@ -----------------------------------------------------------------------------
@ nvm_flash_unlock - write the PEKEYR sequence if the data EEPROM is locked
@ Replaces : 0x0801F9FC DATA_EEPROM_Unlock
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : main; called only from nvm_program_attempt
@ -----------------------------------------------------------------------------
LFUNC nvm_flash_unlock
    ldr r1, =FLASH_PECR                     @ FLASH_PECR, own literal, offset 0
    ldr r0, [r1]
    tst r0, #FLASH_PECR_PELOCK              @ keys only while PELOCK reads 1 (0x0801FA02): a key write while
    beq 1f                                  @ unlocked would be a bus error (RM0038 3.9.4)
    ldr r1, =FLASH_PEKEYR                   @ FLASH_PEKEYR, own literal, offset 0
    ldr r0, =NVM_PEKEY1
    str r0, [r1]                            @ first key (0x0801FA0E)
    ldr r0, =NVM_PEKEY2
    str r0, [r1]                            @ second key (0x0801FA18); never a third write
1:  bx lr
ENDFUNC nvm_flash_unlock

@ -----------------------------------------------------------------------------
@ nvm_flash_lock - set PELOCK
@ Replaces : 0x0801FA1C DATA_EEPROM_Lock
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_flash_lock
    ldr r1, =FLASH_PECR                     @ FLASH_PECR, own literal, offset 0
    ldr r0, [r1]
    orr r0, r0, #FLASH_PECR_PELOCK          @ set PELOCK (also sets PRGLOCK/OPTLOCK, RM0038 3.9.2)
    str r0, [r1]
    bx lr
ENDFUNC nvm_flash_lock

@ -----------------------------------------------------------------------------
@ nvm_flash_clear_flags - write-1-to-clear FLASH_SR flags
@ Replaces : 0x0801FAFA FLASH_ClearFlag
@ In       : r0 = flag mask (only the error bits 8..12 are ever passed by this module)
@ Out      : -
@ Clobbers : r1
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_flash_clear_flags
    ldr r1, =FLASH_SR                       @ FLASH_SR, own literal, offset 0
    str r0, [r1]
    bx lr
ENDFUNC nvm_flash_clear_flags

@ -----------------------------------------------------------------------------
@ nvm_program_attempt - one byte program attempt with the store-time re-check
@ Replaces : 0x080120F0 eeprom_program_byte (unlock, 0x0801FA2E program, lock) and 0x0801FA2E
@            DATA_EEPROM_ProgramByte (wait, FTDW = 0, strb, wait)
@ In       : r0 = EEPROM offset, r1 = value (low byte used), r2 = write class (NVM_CLASS_*)
@ Out      : r0 = 4 complete, 1/2/3/5 FLASH status as v2.05 (nothing stored for a status other than 4 after
@            the first wait), 6 refused before the store (offset above 0x4FC, byte not allowed for the class,
@            or no writer session of that class open), 7 PELOCK still set after the key sequence (nothing
@            stored)
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ Spec     : EEPROM_MAP.md 9.1 item 3, 9.3 items 2-4; RM0038 3.4.2 (data EEPROM byte write, FTDW = 0)
@ Deviation: NVM-1 (error flags cleared before every attempt)
@ -----------------------------------------------------------------------------
LFUNC nvm_program_attempt
    push {r4-r6, lr}
    mov r4, r0                              @ r4 = offset
    uxtb r5, r1                             @ r5 = byte value
    mov r6, r2                              @ r6 = class
    movw r0, #NVM_SR_ERRORS                 @ clear sticky error flags of an earlier attempt (NVM-1); v2.05
    bl nvm_flash_clear_flags                @ clears them only at reset (0x0801BEA4)
    bl nvm_flash_unlock                     @ as eeprom_program_byte 0x080120FE
    ldr r1, =FLASH_PECR                     @ FLASH_PECR, own literal, offset 0
    ldr r0, [r1]
    tst r0, #FLASH_PECR_PELOCK              @ still locked: the key sequence did not unlock (keys are locked
    bne .Lnpa_nounlock                      @ out until reset after a wrong sequence, RM0038 3.9.2)
    mov r0, #NVM_WAIT_POLLS
    bl nvm_flash_wait                       @ wait for a previous operation (0x0801FA3A)
    cmp r0, #FST_COMPLETE                   @ v2.05 programs only when the status is complete (0x0801FA42)
    bne .Lnpa_lock
    ldr r1, =FLASH_PECR                     @ FLASH_PECR, own literal, offset 0
    ldr r0, [r1]
    bic r0, r0, #FLASH_PECR_FTDW            @ FTDW = 0: erase-then-write byte mode (0x0801FA4C..0x0801FA54);
    str r0, [r1]                            @ the only bit this firmware ever clears in FLASH_PECR
    @ store-time re-check (EEPROM_MAP.md 9.3 item 2): r3 holds the store address from here to the strb
    ldr r3, =NVM_EE_BASE
    add r3, r3, r4                          @ r3 = 0x08080000 + offset = store address
    ldr r2, =NVM_EE_BASE
    subs r2, r3, r2                         @ r2 = offset recomputed from the store address
    movw r12, #NVM_EE_LAST
    cmp r2, r12                             @ above 0x4FC (unsigned compare) -> refuse
    bhi .Lnpa_refuse
    cmp r6, #NVM_CLASS_COUNT                @ class outside the table -> refuse
    bhs .Lnpa_refuse
    ldr r1, =nvm_allow
    movs r0, #NVM_ALLOW_STRIDE
    mla r1, r6, r0, r1                      @ r1 = bitmap of the class
    lsrs r0, r2, #3
    ldrb r0, [r1, r0]                       @ bitmap byte holding this offset
    and r1, r2, #7
    lsrs r0, r0, r1                         @ bit (offset & 7) to bit 0
    lsls r0, r0, #31                        @ keep only bit 0 (in bit 31); Z = 1 when it is 0
    beq .Lnpa_refuse                        @ byte not allowed for the class -> refuse
    ldr r1, =nvm_session
    ldrb r1, [r1]                           @ a writer session of this class must be open (nvm.s): a stray
    orr r0, r6, #NVM_SESSION_TAG            @ call that reaches this point finds none
    cmp r1, r0
    bne .Lnpa_refuse
    strb r5, [r3]                           @ the only data-EEPROM store of the image (v2.05 0x0801FA56)
    mov r0, #NVM_WAIT_POLLS
    bl nvm_flash_wait                       @ wait for the end of the byte program (0x0801FA5C)
.Lnpa_lock:
    mov r4, r0                              @ keep the status across the lock
    bl nvm_flash_lock                       @ PELOCK on every exit (0x0801210E)
    mov r0, r4
    pop {r4-r6, pc}
.Lnpa_refuse:
    movs r0, #FST_REFUSED
    b .Lnpa_lock
.Lnpa_nounlock:
    movs r0, #FST_NOUNLOCK
    b .Lnpa_lock
ENDFUNC nvm_program_attempt

@ -----------------------------------------------------------------------------
@ nvm_program_byte - program one data-EEPROM byte with retries and read-back
@ Replaces : 0x08012148 eeprom_write_byte_retry (up to 10 attempts; v2.05 stops when an attempt reports
@            status 4 and never reads back)
@ In       : r0 = EEPROM offset, r1 = value, r2 = write class (NVM_CLASS_*)
@ Out      : r0 = 0 the byte holds the value (written and read back, or already equal: OPT-03),
@            1 refused by the store-time re-check (nothing stored), 2 not confirmed after 10 attempts or the
@            interface did not unlock (no further key write is made then)
@ Clobbers : r1-r3, r12, flags
@ Context  : main; called only from nvm_write_bytes (nvm.s)
@ RAM      : writes cal_cache[offset] (CAL) after a confirmed byte; after status 2 it clears cal_cache_valid,
@            because the byte may have been erased or may still change after the bounded wait, so every reader
@            uses the EEPROM itself until the next cal_cache_load (the cache never holds a stale byte)
@ Spec     : EEPROM_MAP.md 9.3 item 4; DESIGN.md 6.20 (cache), 11 OPT-03
@ Deviation: NVM-1 (read-back), OPT-03 (unchanged byte not programmed)
@ -----------------------------------------------------------------------------
FUNC nvm_program_byte
    push {r4-r8, lr}
    mov r4, r0                              @ r4 = offset
    uxtb r5, r1                             @ r5 = value
    mov r6, r2                              @ r6 = class
    movw r12, #NVM_EE_LAST
    cmp r4, r12                             @ an offset above 0x4FC never reaches the EEPROM (re-checked
    bhi .Lnpb_refused                       @ again at the store)
    ldr r7, =NVM_EE_BASE                    @ r7 = EEPROM base for the read-backs
    ldrb r0, [r7, r4]                       @ current content
    cmp r0, r5
    beq .Lnpb_ok                            @ OPT-03: already holds the value, no erase/write cycle
    movs r0, #0
    mov r8, r0                              @ r8 = attempt counter (0x08012150)
.Lnpb_loop:
    cmp r8, #NVM_ATTEMPTS                   @ at most 10 attempts (0x08012158)
    bhs .Lnpb_fail
    mov r0, r4
    mov r1, r5
    mov r2, r6
    bl nvm_program_attempt
    cmp r0, #FST_REFUSED
    beq .Lnpb_refused                       @ refused at the store: stop, nothing was stored
    cmp r0, #FST_NOUNLOCK
    beq .Lnpb_fail                          @ no unlock: stop, a repeated key sequence could not help
    cmp r0, #FST_COMPLETE
    bne .Lnpb_next
    ldrb r0, [r7, r4]                       @ read back from the EEPROM itself
    cmp r0, r5
    beq .Lnpb_ok                            @ confirmed
.Lnpb_next:
    add r8, r8, #1
    b .Lnpb_loop
.Lnpb_ok:
    ldr r0, =cal_cache
    strb r5, [r0, r4]                       @ cache = EEPROM image (offset <= 0x4FC, cache size 0x500)
    movs r0, #0
    pop {r4-r8, pc}
.Lnpb_refused:
    movs r0, #1
    pop {r4-r8, pc}
.Lnpb_fail:
    ldr r0, =cal_cache_valid
    movs r1, #0
    strb r1, [r0]                           @ readers back to the EEPROM (DESIGN.md 6.20: cache = EEPROM)
    movs r0, #2
    pop {r4-r8, pc}
ENDFUNC nvm_program_byte

@ -----------------------------------------------------------------------------
@ nvm_ee_read - read one data-EEPROM byte directly (not through the cache)
@ Replaces : the load of 0x0801204C eeprom_read_byte (v2.05 loads a word at 0x08080000 + offset and keeps the
@            low byte, 0x08012058..0x0801205C, which is the byte at that address)
@ In       : r0 = offset
@ Out      : r0 = byte, 0 for an offset above 0x4FF (DESIGN.md 6.21: v2.05 never passes one)
@ Clobbers : r1, flags
@ Context  : any
@ -----------------------------------------------------------------------------
FUNC nvm_ee_read
    cmp r0, #0x500                          @ outside the image of the cache: defined result 0
    bhs 1f
    ldr r1, =NVM_EE_BASE
    ldrb r0, [r1, r0]
    bx lr
1:  movs r0, #0
    bx lr
ENDFUNC nvm_ee_read

    .ltorg
