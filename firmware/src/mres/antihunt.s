@ =============================================================================
@ antihunt.s - MRES: capacitance anti-hunting (CAP, mode 12, auto range; SETUP page HUnt; production image only,
@ DESIGN.md 10 IMP-45, FEATURES.md 2.19)
@
@ The problem.  With some ceramic capacitors of about 100 nF the CAP auto range never settles: on range 1 (100 nF) no
@ counter result arrives within the no-signal timeout (cap.s fn_0800B540: v2.05 2.0 s, F-1.13 and later 2.5 s), so the
@ timeout jumps to range 2 (1 uF).  There the capacitor reads below 1000 counts (below 0.1000 uF), so the decision of
@ ar_sample / autorange_step (reading below L = FS / 10) steps down to range 1, where the timeout comes again, and so on.
@ Every range change blanks the display (OF-33), so the digits stay blank and only the decimal point moves.  Whether the
@ cause is the measuring time of range 1 for such a capacitor is not proven (no capacitor of this kind has been measured
@ on a meter; the emulator models it as a setting, emulator/emu/frontend.py cap_slow_ranges).
@
@ The rule (SETUP page HUnt on, EEPROM 0x020 bit 4; default off).  RAM state only, lost at power-off and cleared in the
@ state reset after a STOP wake:
@   ah_timeouts  number of range-1 timeouts counted since the state was last cleared (0..2).  A timeout is counted only
@                when it leaves range 1 in auto range and 0x200080A2 is clear, i.e. the last reading of range 2 before
@                range 1 was 11 counts or more (ar_timeout_note).  Open leads cycle 0 -> 2 -> 1 -> 0 and leave range 2
@                with a reading below 11 counts, which sets 0x200080A2 (arfast.s, autorange.s), so they never count.
@   ah_lock      0 free, 1 locked (reference not yet taken), 2 locked with the reference ah_ref.  While locked, the step
@                down from range 2 is refused (ah_block_down, called from ar_sample and autorange_step), so range 2 stays
@                and its value is shown.
@   ah_ref       the range-2 reading (display counts D) of the first settled result after the lock.
@ The lock is taken by ah_block_down when ah_timeouts >= 2 and a step down from range 2 is about to be made with a
@ reading of 100..999 counts (10.0 .. 99.9 nF): a capacitor that really hunts reads below 1000 counts on range 2 (that is
@ why the step down is made) and not below 100 counts (a capacitor that small is measured on range 0 or 1 without a
@ timeout).  The lock ends (ah_reset) when
@   - a result arrives on range 1 (ah_result: the timeouts were not consecutive),
@   - the settled range-2 reading differs from ah_ref by more than max(20 % of ah_ref, 50 counts) (ah_result: another
@     capacitor, or open leads),
@   - an apply leaves mode 12 or range 2 (ah_apply_note, called by ar_apply): MODE, dial, manual range, a range-2 timeout
@     that jumps to range 5, an up step; an apply to range 1 while the lock is set also ends it, an apply to range 1 without
@     the lock is the hunt's own step down and keeps ah_timeouts,
@   - manual range (this includes REL, which freezes the range) is on at a result of range 2 (ah_result),
@   - the setting is switched off (set_relp_load, set_hunt_edit, ble/bftset.s) or power is removed.
@ HOLD, MIN/MAX and manual range already stop the ranging (arfast.s .Las_do_down is not reached), so the lock only matters
@ in auto range.  Everything else (the up step, the other ranges, other modes) is unchanged.
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
    .include "ar.inc"


    .equ AH_MODE_CAP,      12               @ CAP (meter_mode)
    .equ AH_R_HUNT_LO,     1                @ the range whose timeouts are counted (100 nF)
    .equ AH_R_HUNT_HI,     2                @ the range that is kept (1 uF)
    .equ AH_TMO_LOCK,      2                @ counted timeouts that allow the lock
    .equ AH_READ_MIN,      100              @ lowest range-2 reading (counts) that is a plausible hunting capacitor: 10.0 nF
    .equ AH_READ_SPAN,     899              @ 999 - 100: the plausible window is 100..999 counts (below L = 1000 of range 2)
    .equ AH_UNLOCK_PCT_DIV, 5               @ unlock when the reading differs by more than ref / 5 (20 %) ...
    .equ AH_UNLOCK_MIN,    50               @ ... and by more than 50 counts

    .section .bss_port.mres, "aw", %nobits
    .balign 4
@ ah_ref: the range-2 reading D (display counts) of the first settled result after the lock (owner MRES)
    .global ah_ref
ah_ref:         .space 4
@ ah_timeouts: range-1 timeouts counted, 0..AH_TMO_LOCK (owner MRES; written by ah_timeout_note, ah_result, ah_apply_note, ah_reset)
    .global ah_timeouts
ah_timeouts:    .space 1
@ ah_lock: 0 free, 1 locked, reference not taken, 2 locked with the reference (owner MRES)
    .global ah_lock
ah_lock:        .space 1

    .section .text.mres.antihunt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ah_reset - clear the anti-hunting state (no lock, no counted timeout)
@ Replaces : nothing in v2.05 (new)
@ In       : -
@ Out      : -
@ Clobbers : r2, r3 (r0, r1 are kept, so the callers in ar_apply and the setup pages need not save them)
@ Context  : main only (set_relp_load, set_hunt_edit, bfs_put, set_state_reset, ah_apply_note, ah_result)
@ RAM      : writes ah_timeouts, ah_lock, ah_ref
@ -----------------------------------------------------------------------------
FUNC ah_reset
    movs r2, #0
    ldr r3, =ah_timeouts
    strb r2, [r3]
    ldr r3, =ah_lock
    strb r2, [r3]
    ldr r3, =ah_ref
    str r2, [r3]
    bx lr
    .ltorg
ENDFUNC ah_reset

@ -----------------------------------------------------------------------------
@ ah_timeout_note - count a CAP no-signal timeout that leaves range 1 in auto range
@ Replaces : nothing in v2.05 (new; called by cap.s fn_0800B540 before it overwrites meter_range)
@ In       : r0 = the range the timeout leaves (meter_range before the jump)
@ Out      : r0 = unchanged
@ Clobbers : r1-r3, flags
@ Context  : main only (fn_0800B540, auto range branch)
@ RAM      : reads set_hunt_on, 0x200080A2 (ar_cap_small), ah_timeouts; writes ah_timeouts
@ Note     : counted only when the setting is on, the range is 1 and 0x200080A2 is clear (the last range-2 reading
@            before this range 1 was 11 counts or more); the count stops at AH_TMO_LOCK.
@ -----------------------------------------------------------------------------
FUNC ah_timeout_note
    cmp r0, #AH_R_HUNT_LO
    bne 9f                                  @ a timeout of another range is not part of the hunt
    ldr r1, =set_hunt_on
    ldrb r1, [r1]
    cbz r1, 9f                              @ setting off
    ldr r1, =ar_cap_small
    ldrb r1, [r1]
    cbnz r1, 9f                             @ range 2 was left with a reading below 11 counts (open leads): not counted
    ldr r1, =ah_timeouts
    ldrb r2, [r1]
    cmp r2, #AH_TMO_LOCK
    it lo
    addlo r2, r2, #1
    strb r2, [r1]
9:  bx lr
    .ltorg
ENDFUNC ah_timeout_note

@ -----------------------------------------------------------------------------
@ ah_block_down - refuse a step down from CAP range 2 while the anti-hunting lock is set (and take the lock when due)
@ Replaces : nothing in v2.05 (new; called by arfast.s ar_sample at .Las_do_down and by autorange.s autorange_step at
@            .Lar_under, before the step down is made)
@ In       : r0 = reading in display counts (|X| in ar_sample, |D| in autorange_step)
@ Out      : r0 = 1 refuse the step down (the caller leaves the range alone), 0 allow it
@ Clobbers : r1-r3, flags
@ Context  : main only
@ RAM      : reads set_hunt_on, meter_mode, meter_range, ah_timeouts; reads and writes ah_lock
@ Note     : refuses nothing unless the setting is on and the mode is CAP and the range is 2.  Locked: refuse.  Not locked,
@            AH_TMO_LOCK timeouts counted and the reading in 100..999: take the lock (ah_lock = 1, the reference follows at
@            the first settled result, ah_result) and refuse.  The step is refused whatever its target (ar_sample can jump
@            from range 2 to range 0).
@ -----------------------------------------------------------------------------
FUNC ah_block_down
    ldr r1, =set_hunt_on
    ldrb r1, [r1]
    cbz r1, .Lbd_allow                      @ setting off
    ldr r1, =meter_mode
    ldrb r1, [r1]
    cmp r1, #AH_MODE_CAP
    bne .Lbd_allow
    ldr r1, =meter_range
    ldrb r1, [r1]
    cmp r1, #AH_R_HUNT_HI
    bne .Lbd_allow                          @ only range 2 is kept
    ldr r2, =ah_lock
    ldrb r3, [r2]
    cbnz r3, .Lbd_refuse                    @ locked: stay on range 2
    ldr r1, =ah_timeouts
    ldrb r1, [r1]
    cmp r1, #AH_TMO_LOCK
    blo .Lbd_allow                          @ fewer than two counted timeouts: the normal rule
    subs r0, r0, #AH_READ_MIN
    movw r1, #AH_READ_SPAN
    cmp r0, r1
    bhi .Lbd_allow                          @ not 100..999 counts: no plausible capacitor of the hunt
    movs r3, #1
    strb r3, [r2]                           @ lock; the reference is taken at the first settled result
.Lbd_refuse:
    movs r0, #1
    bx lr
.Lbd_allow:
    movs r0, #0
    bx lr
    .ltorg
ENDFUNC ah_block_down

@ -----------------------------------------------------------------------------
@ ah_apply_note - an apply has run: end the lock or the count when the apply leaves the hunt
@ Replaces : nothing in v2.05 (new; called at the entry of arfast.s ar_apply, which every apply of a mode and range calls)
@ In       : r0 = mode, r1 = range of the apply
@ Out      : r0, r1 = unchanged
@ Clobbers : r2, r3, flags
@ Context  : main only (ar_apply, called by fn_0800DB48)
@ RAM      : reads set_hunt_on, ah_lock; writes the state (ah_reset)
@ Note     : the state is kept for an apply of mode 12 to range 2 (the timeout's own jump from range 1, or the lock's range)
@            and, without a lock, for an apply of mode 12 to range 1 (the hunt's own step down: the timeout count must
@            survive it).  Any other apply clears the state: another mode, range 0, 3, 4, 5 (including the range-2 timeout
@            to range 5 and every manual change), and an apply to range 1 while the lock is set.  Setting off: cleared.
@ -----------------------------------------------------------------------------
FUNC ah_apply_note
    ldr r2, =set_hunt_on
    ldrb r2, [r2]
    cbz r2, .Lan_clear                      @ setting off
    uxtb r2, r0
    cmp r2, #AH_MODE_CAP
    bne .Lan_clear                          @ another mode
    cmp r1, #AH_R_HUNT_HI
    beq .Lan_keep                           @ range 2: the lock and the count stay
    cmp r1, #AH_R_HUNT_LO
    bne .Lan_clear                          @ range 0, 3, 4, 5, or anything else
    ldr r2, =ah_lock
    ldrb r2, [r2]
    cbz r2, .Lan_keep                       @ range 1 without a lock: the hunt's own step down keeps its count
.Lan_clear:
    b ah_reset                              @ (tail call) range 1 with the lock set, other range, other mode, setting off
.Lan_keep:
    bx lr
    .ltorg
ENDFUNC ah_apply_note

@ -----------------------------------------------------------------------------
@ ah_result - a CAP result has been accepted (not discarded by ar_sample) and its displayed reading D is stored
@ Replaces : nothing in v2.05 (new; called by cap.s fn_0800B33C right before the timeout reload of an accepted result)
@ In       : - (reads D, 0x20007D64)
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main only (fn_0800B33C)
@ RAM      : reads set_hunt_on, ar_state (ar_decision_pending), meter_range, range_manual, ar_blank (0x2000805C), ar_reading
@            (D, 0x20007D64), ah_lock, ah_ref; writes the state
@ Note     : nothing while ar_sample has changed the range for this result (ar_decision_pending: meter_range is already the
@            new range, and the apply that follows decides about the state, ah_apply_note).  Range 1: a result arrived, so the counted timeouts were not consecutive: clear the state.  Range 2 with the
@            lock set: manual range (REL included) clears it; while the blank flag 0x2000805C is set the result is not a
@            settled one (the spurious pass after each apply and the first result are drawn blank,
@            analysis/autorange_and_scheduler.md 2.3) and nothing is done; the first settled result stores D in ah_ref
@            (ah_lock 2); later settled results clear the state when |D - ah_ref| > max(ah_ref / 5, 50) counts.  Other
@            ranges: nothing (an apply to them has cleared the state).
@ -----------------------------------------------------------------------------
FUNC ah_result
    push {r4, lr}
    ldr r0, =set_hunt_on
    ldrb r0, [r0]
    cbz r0, .Lr_ret                         @ setting off (the state is clear)
    bl ar_decision_pending                  @ r0 = 1: ar_sample has just changed the range for this very result (a step down
    cbnz r0, .Lr_ret                        @ from range 2 to 1); meter_range is then already the new range, the result is not
    ldr r0, =meter_range                    @ one of it, and ah_apply_note decides about the state at the apply
    ldrb r0, [r0]
    cmp r0, #AH_R_HUNT_LO
    beq .Lr_clear                           @ a result on range 1: the timeouts were not consecutive
    cmp r0, #AH_R_HUNT_HI
    bne .Lr_ret
    ldr r4, =ah_lock
    ldrb r3, [r4]
    cbz r3, .Lr_ret                         @ range 2, not locked
    ldr r0, =range_manual
    ldrb r0, [r0]
    cbnz r0, .Lr_clear                      @ manual range or REL: the lock ends
    ldr r0, =ar_blank
    ldrb r0, [r0]
    cbnz r0, .Lr_ret                        @ the display is still blank: not a settled result
    ldr r0, =ar_reading
    ldr r0, [r0]                            @ r0 = D
    ldr r1, =ah_ref
    cmp r3, #1
    bne 1f
    str r0, [r1]                            @ first settled result after the lock: the reference
    movs r3, #2
    strb r3, [r4]
    b .Lr_ret
1:  ldr r1, [r1]                            @ r1 = reference
    subs r0, r0, r1
    it mi
    rsbmi r0, r0, #0                        @ r0 = |D - ref|
    movs r3, #AH_UNLOCK_PCT_DIV
    udiv r3, r1, r3                         @ r3 = 20 % of the reference
    cmp r3, #AH_UNLOCK_MIN
    it lo
    movlo r3, #AH_UNLOCK_MIN                @ at least 50 counts
    cmp r0, r3
    bls .Lr_ret                             @ within the band: the same capacitor
.Lr_clear:
    bl ah_reset
.Lr_ret:
    pop {r4, pc}
    .ltorg
ENDFUNC ah_result
