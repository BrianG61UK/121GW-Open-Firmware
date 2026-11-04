@ =============================================================================
@ trigger.s - LOG: record trigger of the SD logging (production image only, DESIGN.md 10 IMP-21, FEATURES.md 2.6)
@
@ v2.05 requests a record (0x20007FE2) when the interval counter reaches the interval (seconds, sys_main step 9), or with
@ interval 0 up to 5 times per second (sys_tim2_isr).  The trigger of the SETUP page tr (log_trig, EEPROM 0x020 bits 2..1):
@   0  tr-In  as v2.05
@   1  tr-Ch  a record when the reading has moved by at least log_ch_thr counts (page Ch, EEPROM 0x022) since the last
@             record, tested on the 1 s flag (at most one record per second); with an interval above 0 also every interval
@   2  tr-Lt  a record at every change of the limit-test verdict (set/limit.s lt_tick); with an interval above 0 also every
@             interval while the verdict is not PASS (or the test is off)
@ With tr-Ch and tr-Lt the 5-per-second path of interval 0 is off: interval 0 means "the trigger only".  Every request goes
@ through the v2.05 flag, so the record content, the ring and the file format are v2.05's.  "The reading" is the displayed
@ value 0x20007D64 that the record stores (OF-35); an overload counts as +1 000 000 or -1 000 000 by its sign, so entering
@ and leaving an overload are changes.  The value of the last record is taken in log_take_record.
@
@ Context: main only, except log_trig_fast_ok (TIM2 interrupt; reads one byte).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ LOG_OL_LEVEL,        1000000       @ value given to an overload for the change test
    .equ log_req,             v_20007FE2    @ record request (v2.05)
    .equ log_on,              v_20007FE1    @ logging active (v2.05)

    .section .bss_port.log, "aw", %nobits
    .balign 4
    .global log_last
log_last:       .space 4                    @ level of the last record
    .global log_trig, log_ch_thr
log_trig:       .space 1                    @ 0 tr-In, 1 tr-Ch, 2 tr-Lt (owner SET, set_relp_load / set_tr_edit)
log_ch_thr:     .space 1                    @ change threshold 1..255 counts (owner SET)
log_last_valid: .space 1                    @ 1 = log_last holds the level of a record of this session

    .section .text.log.trigger, "ax", %progbits

@ -----------------------------------------------------------------------------
@ log_level - the displayed value as a level for the change test
@ Out      : r0 = 0x20007D64, or +-LOG_OL_LEVEL while an overload is shown
@ Clobbers : r1, flags
@ -----------------------------------------------------------------------------
LFUNC log_level
    ldr r0, =v_20008046
    ldrb r0, [r0]                           @ overload flag
    cbz r0, 1f
    ldr r0, =v_20008045
    ldrb r0, [r0]                           @ sign of the overload
    ldr r1, =LOG_OL_LEVEL
    cmp r0, #0
    ite eq
    moveq r0, r1
    rsbne r0, r1, #0
    bx lr
1:  ldr r0, =v_20007D64
    ldr r0, [r0]
    bx lr
ENDFUNC log_level

@ -----------------------------------------------------------------------------
@ log_trig_reset - forget the last record (log_start: a new session)
@ Clobbers : r0, r1
@ -----------------------------------------------------------------------------
FUNC log_trig_reset
    movs r0, #0
    ldr r1, =log_last_valid
    strb r0, [r1]
    bx lr
ENDFUNC log_trig_reset

@ -----------------------------------------------------------------------------
@ log_trig_taken - a record is being taken: remember its level (log_take_record)
@ Clobbers : r0, r1, flags
@ -----------------------------------------------------------------------------
FUNC log_trig_taken
    push {r4, lr}
    bl log_level
    ldr r1, =log_last
    str r0, [r1]
    movs r0, #1
    ldr r1, =log_last_valid
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC log_trig_taken

@ -----------------------------------------------------------------------------
@ log_trig_interval - the interval counter has reached the interval: request a record if the trigger wants it
@ Clobbers : r0, r1, flags
@ Context  : main only (sys_main step 9, logging on, not in auto-hold stage 2)
@ -----------------------------------------------------------------------------
FUNC log_trig_interval
    ldr r0, =log_trig
    ldrb r0, [r0]
    cmp r0, #2
    bne 1f                                  @ tr-In, tr-Ch: every interval
    ldr r0, =lt_on
    ldrb r0, [r0]
    cbz r0, 1f                              @ tr-Lt without a test: every interval
    ldr r0, =lt_verdict
    ldrb r0, [r0]
    cmp r0, #1                              @ LT_V_PASS
    beq 2f                                  @ within the limits: no interval record
1:  movs r0, #1
    ldr r1, =log_req
    strb r0, [r1]                           @ record request
2:  bx lr
ENDFUNC log_trig_interval

@ -----------------------------------------------------------------------------
@ log_trig_second - the change test on the 1 s flag (tr-Ch)
@ Clobbers : r0-r3, flags
@ Context  : main only (sys_main step 9, logging on, not in auto-hold stage 2)
@ -----------------------------------------------------------------------------
FUNC log_trig_second
    push {r4, lr}
    ldr r0, =log_trig
    ldrb r0, [r0]
    cmp r0, #1
    bne 2f                                  @ not tr-Ch
    ldr r0, =log_last_valid
    ldrb r0, [r0]
    cbz r0, 1f                              @ no record in this session yet: take the first one now
    bl log_level
    ldr r1, =log_last
    ldr r1, [r1]
    subs r0, r0, r1
    it mi
    negmi r0, r0                            @ |level - last|
    ldr r1, =log_ch_thr
    ldrb r1, [r1]
    cmp r0, r1
    blo 2f                                  @ below the threshold
1:  movs r0, #1
    ldr r1, =log_req
    strb r0, [r1]                           @ record request
2:  pop {r4, pc}
ENDFUNC log_trig_second

@ -----------------------------------------------------------------------------
@ log_trig_verdict - the limit verdict has changed (set/limit.s lt_tick): request a record with tr-Lt
@ Clobbers : r0, r1, flags
@ Context  : main only
@ -----------------------------------------------------------------------------
FUNC log_trig_verdict
    ldr r0, =log_trig
    ldrb r0, [r0]
    cmp r0, #2
    bne 1f
    ldr r0, =log_on
    ldrb r0, [r0]
    cbz r0, 1f                              @ not logging
    ldr r0, =v_20008050
    ldrb r0, [r0]
    cbnz r0, 1f                             @ auto-hold stage 2 (no timed records there either)
    movs r0, #1
    ldr r1, =log_req
    strb r0, [r1]
1:  bx lr
ENDFUNC log_trig_verdict

    .ltorg

