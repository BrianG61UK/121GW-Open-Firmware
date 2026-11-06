@ =============================================================================
@ arfast.s - AR: the production auto-range primitives (IMP-01): ar_apply and ar_sample
@
@ New routines (no v2.05 function).  autorange_step (autorange.s) keeps the v2.05 decision once per mean in both
@ loop modes; the routines here add what analysis/autorange_and_scheduler.md 5 specifies for the production image:
@
@   ar_apply(mode, range)   called at the end of every apply (fn_0800DB48): clears the overload latch 0x200080F8
@                           (OF-20) and, in the production image, resets the per-sample state and computes the
@                           number of conversions to discard after the change (settle profile CP, or TP for the
@                           families enabled in config.inc: ARS 5.2 P4)
@   ar_sample(value, raw)   called by MDC / MAC / MRES after each conversion: per-sample over- and under-range
@                           detection with K = 2 confirmation and saturation test (ARS 5.2 P2), direct target range
@                           (ARS 5.2 P3), and the conversion discard of P4 (v2.05 has none of it: the like-v2.05 build keeps
@                           the v2.05 algorithm alone)
@
@ Why the final range equals the one v2.05 reaches (ARS 5.1 invariant 1): v2.05 moves one range per decision and
@ re-measures; every range is ten times the previous one in counts (the table 0x08025A3C: 50 000 counts per range
@ except DCV range 3 = 6 000, ACA / DCA range 2 = 10 000, CAP = 10 000), so the reading of range j is the reading of
@ the present range c scaled by 10^(c - j).  The one exception is CAP range 5 against range 4 (hundred times: range 5
@ shows 9999 uF without decimals, range 4 100.00 uF, hy3131_modes_misc.md 5.5), handled in the down search.  Going up v2.05 stops at the lowest j > c with |v_j| <= U_j, going down
@ at the highest j < c with |v_j| >= L_j (or 0); the routines compute exactly that j from one confirmed sample.  The
@ sample is an estimate with an uncertainty of one count, so a candidate that the uncertainty leaves undecided is
@ resolved towards the present range (lower j going up, higher j going down): never an overshoot, and the normal rule
@ continues from there as v2.05 would.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "ar.inc"

    .section .text.ar.arfast, "ax", %progbits

    .equ AR_ST_OVER,    0               @ ar_state byte 0: samples in a row above U
    .equ AR_ST_UNDER,   1               @ ar_state byte 1: samples in a row below L
    .equ AR_ST_DISCARD, 2               @ ar_state byte 2: conversions still to discard after an apply
    .equ AR_ST_PEND,    4               @ ar_state byte 4: 1 = ar_sample changed the range and the apply has not run yet
    .equ AR_ST_FIRST,   3               @ ar_state byte 3: blank request of FREQ / PULSE / DUTY / BEEP: 1 waiting for the
                                        @ spurious autorange_step of the apply, 2 waiting for the first real result
    .equ AR_ST_TMO_SEEN, 5              @ ar_state byte 5: value of ar_freq_tmo_count at the last look (OF-32 decision)
    .equ AR_ST_TMO_HOLD, 6              @ ar_state byte 6: 1 = the zero of a no-signal timeout is shown; the apply that the
                                        @ timeout requests (same mode) keeps the digits instead of blanking them
    .equ AR_ST_LAST_MODE, 7             @ ar_state byte 7: mode of the last apply
    .equ AR_K,          2               @ K = 2 consecutive samples confirm a decision (ARS 5.2 P2)
    .equ AR_SAT_LO,     0x7FFFFE        @ a 24-bit AD1 code from 0x7FFFFE to 0x800001 is "within one count of full scale" of
    .equ AR_SAT_SPAN,   3               @ 0x7FFFFF or 0x800000 (ARS 5.2 P2): four codes
    .equ MODE_CAP,      12              @ CAP: one counter result per conversion, so K = 1 and no sample-based up step
    .equ MODE_OHM,      9

    @ Modes with automatic ranging by AD1 samples or CAP results: DCV 1, ACV 2, DCmV 3, ACmV 4, OHM 9, CAP 12 and the
    @ six current modes 16..21.  Single-range modes (LowZ, TEMP, BEEP, DIODE), FREQ / PULSE / DUTY (own range
    @ selection) and the VA modes (own rules) are not ranged here (autorange_step 0x0800DEE6..0x0800DF5A).
    .equ AR_FAST_MASK,  (1<<1)|(1<<2)|(1<<3)|(1<<4)|(1<<9)|(1<<12)|(0x3F<<16)
    @ Modes whose settle count is 0 in v2.05 (FREQ 6, PULSE 7, DUTY 8, BEEP 10): v2.05 draws the zeroed value at mode
    @ entry (OF-32); the main digits are blanked until the first real result
    .equ AR_BLANK_MASK, (1<<6)|(1<<7)|(1<<8)|(1<<10)
    @ DC current modes: 17 DCuA, 19 DCmA, 21 DCA
    .equ AR_DCCUR_MASK, (1<<17)|(1<<19)|(1<<21)
    @ Modes whose family has the target settle profile TP enabled in config.inc (all 0 by default: ARS 12 not done)
    .equ AR_TP_MASK,    (AR_PROFILE_TP_DCV*((1<<1)|(1<<3)))|(AR_PROFILE_TP_OHM*(1<<9))|(AR_PROFILE_TP_CURRENT*((1<<17)|(1<<19)|(1<<21)))|(AR_PROFILE_TP_AC*((1<<2)|(1<<4)|(1<<16)|(1<<18)|(1<<20)))

    .section .bss_port.ar, "aw", %nobits
    .balign 4
@ ar_state (owner AR): byte 0 samples above U in a row, byte 1 samples below L in a row, byte 2 conversions to
@ discard, byte 3 progress of the blank request (AR_ST_FIRST), byte 4 range change awaiting its apply (AR_ST_PEND),
@ byte 5 timeout count seen (AR_ST_TMO_SEEN), byte 6 timeout zero shown (AR_ST_TMO_HOLD), byte 7 mode of the last apply
ar_state:
    .space 8
@ ar_freq_tmo_count: number of FREQ / PULSE / DUTY no-signal timeouts that published a zero result (production image).
@ Written only by sys_tim2_isr (incremented at 0x080244B2's step, SYS); read by ar_result_seen and ar_apply, so the
@ main loop never writes it and no update can be lost.
    .global ar_freq_tmo_count
ar_freq_tmo_count:
    .space 1
@ ar_ohm_jump (owner AR): 0, or 1 + the top range when ar_sample has just jumped there from a saturated OHM sample.
@ The first step down from that range is the measured correction of the jump: it is not refused by the OHM direction
@ guard (fn_0800E2A0), which would otherwise hold the low-resolution top-range reading for 1 s.  Cleared by that
@ step, by any other range change of ar_sample, by a reading that belongs to the top range, and by every apply that
@ ar_sample did not request (dial, MODE, RANGE, autorange_step).
ar_ohm_jump:
    .space 1

    .section .rodata.ar, "a", %progbits
    .balign 4
@ Samples per mean of OHM ranges 0..6 in the production image (MDC ad1_accumulate_average, IMP-03; v2.05: 8, 8, 8, 8, 8, 1, 8)
ar_ohm_mean:
    .byte 8, 8, 32, 16, 16, 1, 8
    .balign 4
@ 10^0 .. 10^6: the ratio between ranges j and c is 10^|j - c| (10^(c - j + 1) for CAP range 5 to a lower range), at most
@ 10^6 (seven OHM ranges; CAP range 5 to range 0 is 10^6 as well)
ar_pow10:
    .word 1, 10, 100, 1000, 10000, 100000, 1000000

    .section .text.ar.arfast, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ar_thr_up - upper threshold U of a range
@ Replaces : nothing (the arithmetic of autorange_step 0x0800DF6A..0x0800DFA0 for a chosen range)
@ In       : r0 = mode, r1 = range, r2 = 1 to honour the overload latch (the present range), 0 to ignore it (a candidate
@            range above the present one: v2.05 clears the latch with the range change, 0x0800E256..0x0800E270, and
@            fn_0800DB48 clears it at the apply)
@ Out      : r0 = U = FS + FS/12 while r2 = 1 and the overload latch is set, else FS + FS/10 (FS = table 0x08025A3C entry)
@ Clobbers : r2, r3, r12, flags
@ Context  : main
@ RAM      : reads 0x200080F8 (mode_ol_latch)
@ Note     : DIODE (U = FS) is not ranged here
@ -----------------------------------------------------------------------------
LFUNC ar_thr_up
    mov r12, r2                             @ r12 = latch selector
    ldr r2, =full_scale_table
    movs r3, #28
    muls r3, r0, r3                         @ mode * 28: seven words per mode
    adds r2, r2, r3
    ldr r0, [r2, r1, lsl #2]                @ r0 = FS of this range
    movs r3, #10                            @ divisor 10 ...
    cmp r12, #0
    beq 1f                                  @ candidate range: no latch
    ldr r2, =ar_ol_latch
    ldrb r2, [r2]
    cbz r2, 1f
    movs r3, #12                            @ ... 12 while the latch is set (0x0800DF72..0x0800DF8C)
1:  udiv r2, r0, r3
    adds r0, r0, r2                         @ U = FS + FS/10 (or /12)
    bx lr
ENDFUNC ar_thr_up

@ -----------------------------------------------------------------------------
@ ar_thr_low - lower threshold L of a range
@ Replaces : nothing (the arithmetic of autorange_step 0x0800DF9C..0x0800DFEE for a chosen range)
@ In       : r0 = mode, r1 = range
@ Out      : r0 = L = FS/10; FS/100 in CAP range 5; 5 * FS/10 in modes 20 and 21 (ACA, DCA) range 2
@ Clobbers : r2, r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC ar_thr_low
    ldr r2, =full_scale_table
    movs r3, #28
    muls r3, r0, r3
    adds r2, r2, r3
    ldr r2, [r2, r1, lsl #2]                @ r2 = FS of this range
    cmp r0, #MODE_CAP
    bne 1f
    cmp r1, #5
    bne 1f
    movs r3, #100                           @ CAP range 5: FS/100 (0x0800DFB6)
    udiv r0, r2, r3
    bx lr
1:  movs r3, #10
    udiv r2, r2, r3                         @ FS/10 (0x0800DFC4)
    cmp r1, #2
    bne 2f
    subs r3, r0, #20
    cmp r3, #1
    bhi 2f                                  @ only modes 20 and 21
    movs r3, #5
    muls r2, r3, r2                         @ ACA / DCA range 2: 5 * FS/10 (0x0800DFEE)
2:  mov r0, r2
    bx lr
ENDFUNC ar_thr_low


@ -----------------------------------------------------------------------------
@ ar_result_seen - a post-processed result exists: end the blank request of FREQ, PULSE, DUTY and BEEP
@ Replaces : nothing (new; OF-32, analysis/autorange_and_scheduler.md 5.2 P5)
@ In       : -
@ Out      : -
@ Clobbers : r0-r2, flags
@ Context  : main (first instruction block of autorange_step, once per new result)
@ RAM      : ar_state bytes 3, 5, 6; reads ar_freq_tmo_count; writes ui_blank_req (W3, port RAM) = 0
@ Spec     : firmware/requests/W3_to_W4.md 1
@ Deviation: OF-32
@ Every apply sets 0x2000805D itself (FUN_0800A560, 0x0800A5A0), so the first autorange_step after it runs without a
@ result; it only moves the state from 1 to 2.  The next call comes with a real result and releases the main digits.
@ No-signal timeout (owner decision, OF-32 scope): FREQ / PULSE / DUTY are blank only until the first counter result or
@ the first counter timeout.  The timeout of sys_tim2_isr (v2.05 0x0802442E..0x080244C4) sets the reading to 0 and a new
@ result and counts itself in ar_freq_tmo_count; a call that finds the count changed releases the main digits at once, so
@ 0.000 is shown as v2.05 shows it, and marks the zero as shown (AR_ST_TMO_HOLD) for the apply that the timeout requests
@ in auto range.  Any other result clears that mark.
@ -----------------------------------------------------------------------------
FUNC ar_result_seen
    ldr r2, =ar_state
    ldr r1, =ar_freq_tmo_count
    ldrb r1, [r1]                           @ timeouts counted by the TIM2 handler
    ldrb r0, [r2, #AR_ST_TMO_SEEN]
    cmp r0, r1
    beq 5f
    strb r1, [r2, #AR_ST_TMO_SEEN]          @ a no-signal timeout since the last call: its zero result is this result
    movs r0, #1
    strb r0, [r2, #AR_ST_TMO_HOLD]          @ the apply it requests keeps the digits
    movs r0, #0
    strb r0, [r2, #AR_ST_FIRST]             @ no blank request in progress any more
    ldr r1, =ui_blank_req
    strb r0, [r1]                           @ release the main digits: 0.000 as in v2.05
    bx lr
5:  movs r0, #0
    strb r0, [r2, #AR_ST_TMO_HOLD]          @ not a timeout result: the next apply blanks as usual
    ldrb r0, [r2, #AR_ST_FIRST]
    cbz r0, 9f                              @ nothing pending
    cmp r0, #1
    bne 1f
    movs r0, #2                             @ the apply's own pass: wait for a real result
    strb r0, [r2, #AR_ST_FIRST]
    bx lr
1:  movs r0, #0                             @ a real result: release the main digits
    strb r0, [r2, #AR_ST_FIRST]
    ldr r1, =ui_blank_req
    strb r0, [r1]
9:  bx lr
ENDFUNC ar_result_seen

@ -----------------------------------------------------------------------------
@ ar_decision_pending - has ar_sample changed the range without the apply having run
@ Replaces : nothing (new, IMP-01)
@ In       : -
@ Out      : r0 = 1 a range change of ar_sample waits for its apply (autorange_step must not decide on the reading of the
@            old range), else 0
@ Clobbers : r0
@ Context  : main (first block of autorange_step); production image only
@ RAM      : ar_state byte 4: set by ar_sample when it changes the range, cleared by ar_apply
@ Why      : ar_sample runs in loop step 1 and the apply in step 13, while autorange_step runs in step 2 of the same pass; in
@            v2.05 a request is always served in the pass that sets it, so this state is new
@ -----------------------------------------------------------------------------
FUNC ar_decision_pending
    ldr r0, =ar_state
    ldrb r0, [r0, #AR_ST_PEND]
    bx lr
ENDFUNC ar_decision_pending
    .ltorg

@ -----------------------------------------------------------------------------
@ ar_apply - end of an apply, production image
@ Replaces : nothing (new)
@ In       : r0 = mode, r1 = range
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main (tail call of fn_0800DB48, which has just stored the v2.05 settle count in 0x20000238)
@ RAM      : writes 0x200080F8 (ar_ol_latch) = 0, ar_state (counts 0, discard n, blank progress, timeout mark, last mode),
@            ui_blank_req (W3), 0x20000238 (TP only); reads 0x20000238, ar_freq_tmo_count; the anti-hunting state (ah_apply_note)
@ Spec     : analysis/autorange_and_scheduler.md 5.2 P4 (settle after a change)
@ Deviation: OF-20 (latch), OF-32 (blank request), IMP-01 (settle profiles), IMP-45 (anti-hunting: ah_apply_note first)
@
@ ui_blank_req (firmware/requests/W3_to_W4.md 1): set to 1 in FREQ, PULSE, DUTY and BEEP, cleared in every mode but
@ LowZ (mode 0, owned by MRES: there only a request of 1 left by the previous mode is withdrawn); ar_result_seen
@ clears it at the first real result.
@
@ Conversions to discard after the change, n (the first n conversions are refused by ar_sample, so the caller must
@ not accumulate them into the mean):
@   N = 2 conversions (the sinc^2 comb of AD1 needs the third conversion after a change; none for CAP, whose counter
@       results do not pass the comb: ARS 5.3 expects one CAP conversion per change), 26 for DCV range 0 (the
@       AD1 pre-filter R 100 kohm with C 27 nF: 10.8 tau = 321 ms, 26 conversions of 12.5 ms), 5 for the DC current
@       modes under TP (30 ms at 6.25 ms)
@   CP (default): v2.05 keeps discarding (count - 1) means of M samples (M = 16, OHM per range 8, 8, 32, 16, 16, 1, 8), so
@       n = max(0, N - (count - 1) * M): the discard is the larger of the two, never less than v2.05 discards
@   TP (family switch in config.inc): the mean-based discard is dropped (count := min(count, 1)) and n = N
@ -----------------------------------------------------------------------------
FUNC ar_apply
    push {r4, r5, r6, lr}
    bl ah_apply_note                        @ IMP-45: an apply that leaves CAP range 1 / 2 ends the anti-hunting lock (r0, r1 kept)
    movs r3, #0
    ldr r2, =ar_ol_latch
    strb r3, [r2]                           @ the overload hysteresis starts clear at every apply (OF-20)
    ldr r4, =ar_state
    ldrb r2, [r4, #AR_ST_PEND]
    cbnz r2, 9f
    ldr r2, =ar_ohm_jump
    strb r3, [r2]                           @ an apply ar_sample did not request: no jump correction pending
9:  strb r3, [r4, #AR_ST_OVER]              @ no confirmation under way
    strb r3, [r4, #AR_ST_UNDER]
    strb r3, [r4, #AR_ST_DISCARD]
    strb r3, [r4, #AR_ST_FIRST]             @ no blank request in progress
    strb r3, [r4, #AR_ST_PEND]              @ the apply that was pending has run
    uxtb r0, r0                             @ r0 = mode
    uxtb r1, r1                             @ r1 = range
    @ OF-32 timeout decision: r12 = 1 when this apply follows a no-signal timeout of the same mode whose zero is shown (the
    @ apply requested by the timeout in auto range): the digits are not blanked again.  Another mode: timeouts counted
    @ so far belong to the previous mode and are taken as seen.
    ldrb r2, [r4, #AR_ST_LAST_MODE]
    strb r0, [r4, #AR_ST_LAST_MODE]
    ldrb r12, [r4, #AR_ST_TMO_HOLD]
    strb r3, [r4, #AR_ST_TMO_HOLD]          @ the mark is used by this apply only
    cmp r2, r0
    beq 5f
    mov r12, r3                             @ another mode: blank as usual
    ldr r2, =ar_freq_tmo_count
    ldrb r2, [r2]
    strb r2, [r4, #AR_ST_TMO_SEEN]          @ timeouts of the previous mode are not results of this one
5:
    movs r2, #1
    lsls r2, r2, r0                         @ r2 = 1 << mode (zero for a mode above 31)
    ldr r6, =ui_blank_req                   @ r6 = address of the blank request byte (W3)
    cbz r0, 8f                              @ LowZ: MRES owns the byte
    movs r5, #0
    ldr r3, =AR_BLANK_MASK
    tst r2, r3
    beq 6f
    cmp r12, #0
    bne 6f                                  @ apply of a timeout whose zero is shown: keep the digits (OF-32 decision)
    movs r5, #1                             @ FREQ, PULSE, DUTY, BEEP: the main digits stay blank until the first result
6:  strb r5, [r6]
    strb r5, [r4, #AR_ST_FIRST]             @ 1 = still waiting for the spurious autorange_step of this apply
    b 7f
@ LowZ: a request of AR (1) left by the previous mode is withdrawn; the dashes of MRES (2) stay
8:  ldrb r3, [r6]
    cmp r3, #1
    bne 7f
    movs r3, #0
    strb r3, [r6]
7:  ldr r3, =AR_FAST_MASK
    tst r2, r3
    beq .Laa_done                           @ no ranging by samples in this mode: nothing to discard
    movs r5, #2                             @ r5 = N: the comb needs two conversions
    cmp r0, #MODE_CAP
    bne .Laa_notcap
    movs r5, #0                             @ CAP: counter results, AD1 is not consumed (hy3131_modes_misc.md 3.1), so no
    b .Laa_store                            @ comb to wait for; v2.05 trusts the first result after the apply (count 1)
.Laa_notcap:
    cmp r0, #1
    bne 1f
    cmp r1, #0
    bne 1f
    movs r5, #26                            @ DCV range 0: the AD1 pre-filter settles in 321 ms
1:  ldr r3, =AR_TP_MASK
    tst r2, r3
    beq .Laa_cp                             @ family without the target profile: conservative profile
    ldr r3, =AR_DCCUR_MASK                  @ TP: DC current rows (SFT1 = 00, pre-filter) need 30 ms
    tst r2, r3
    beq 2f
    movs r5, #5
2:  ldr r6, =ar_settle
    ldrb r3, [r6]
    cmp r3, #1
    bls .Laa_store                          @ the v2.05 count already discards at most 0 means
    movs r3, #1
    strb r3, [r6]                           @ TP: no mean is discarded, the conversions n do it
    b .Laa_store
@ the family has no target profile: conservative profile CP
.Laa_cp:
    movs r3, #16                            @ M = samples per mean: 16 ...
    cmp r0, #1
    bne 5f
    ldr r6, =v_2000808A
    ldrb r6, [r6]
    cbnz r6, 5f                             @ calibration mode: v2.05 blocks of 16
    @ IMP-23: DCV publishes a mean every 8 samples (mdc_dcv_accumulate), so the v2.05 count of discarded means is doubled,
    @ (count - 1) * 2 + 1, and M = 8: the discarded time stays v2.05's, (count - 1) x 16 samples
    movs r3, #8
    ldr r6, =ar_settle
    ldrb r12, [r6]
    cmp r12, #1
    bls 3f                                  @ 0 or 1: nothing discarded by v2.05, nothing to double
    lsl r12, r12, #1
    sub r12, r12, #1
    strb r12, [r6]
    b 3f
5:  cmp r0, #MODE_OHM
    bne 3f
    cmp r1, #6
    bhi 3f
    ldr r3, =ar_ohm_mean
    ldrb r3, [r3, r1]                       @ ... OHM: per range, production values of MDC (IMP-03)
3:  ldr r6, =ar_settle
    ldrb r6, [r6]                           @ r6 = v2.05 settle count
    cbz r6, .Laa_store                      @ nothing discarded by v2.05: n = N
    subs r6, r6, #1
    muls r3, r6, r3                         @ r3 = conversions that v2.05 discards
    cmp r5, r3
    bhi 4f
    movs r5, #0                             @ v2.05 discards at least N
    b .Laa_store
4:  subs r5, r5, r3                         @ n = N - discarded by v2.05
@ n is in r5: remember it for ar_sample
.Laa_store:
    strb r5, [r4, #AR_ST_DISCARD]
@ mode without sample-based ranging, or settle bookkeeping finished
.Laa_done:
    pop {r4, r5, r6, pc}
ENDFUNC ar_apply
    .ltorg

@ -----------------------------------------------------------------------------
@ ar_sample - per-sample over- and under-range detection and direct range change (production image)
@ Replaces : nothing (new, IMP-01)
@ In       : r0 = calibrated per-sample value in display counts (signed, the value that fills 0x20007D68),
@            r1 = raw AD1 code (24-bit register value 0..0xFFFFFF, upper bits ignored; 0 for conversions without an
@            AD1 code, e.g. CAP).  Codes 0x7FFFFE, 0x7FFFFF, 0x800000, 0x800001 are saturated
@ Out      : r0 = 1 the caller must discard this conversion (n conversions after an apply, or an apply is pending),
@            r0 = 0 the conversion is accepted
@ Clobbers : r0-r3, r12, flags (r4-r10 saved)
@ Context  : main (called by MDC, MAC and MRES after each conversion and before it is accumulated)
@ RAM      : reads 0x200080F8, 0x20000238, 0x2000803C, 0x2000803D, 0x2000808A, range_manual, minmax_state,
@            hold_active, hold_stage2, 0x2000804A, 0x2000804B, range_count, full_scale_table; writes
@            meter_range, 0x2000804B, 0x2000805C (blank), 0x200080A2 (CAP) and ar_state; ah_block_down reads the
@            anti-hunting state and may take the lock (ah_lock)
@ Spec     : analysis/autorange_and_scheduler.md 5.2 P2, P3 (thresholds U and L of autorange_step)
@ Deviation: IMP-01, IMP-45
@
@ The sample is judged only when v2.05's autorange_step would also be allowed to range: ranging by samples needs
@ automatic range, no MIN/MAX, no HOLD, no calibration mode, two or more ranges, a settled range (mode_settle = 0)
@ and no apply pending.  Anything else is left to autorange_step, which still runs once per mean.
@   over:  |value| > U or the raw code is saturated     under: |value| < L and range > 0
@ K = 2 samples in a row confirm either (CAP: one conversion; CAP has no sample-based step up).  Target range:
@   up    saturated: OHM the top range, other modes one range up (the true value is unknown); otherwise the lowest j > c
@         with (|v| - 1) / 10^(j-c) <= U_j, else the top range (overload stays with autorange_step)
@   down  the highest j in 1..c-1 with (|v| + 1) * 10^(c-j) >= L_j, else 0 (CAP range 5 to a lower range: 10^(c-j+1),
@         range 5 is 9999 uF with no decimals and range 4 is 100.00 uF: the readings differ by 100, which is why v2.05
@         uses L = FS/100 in CAP range 5, 0x0800DFB6)
@ The OHM direction guard (fn_0800E2A0) may refuse the step; the confirmation is then kept and tried again with the
@ next sample.
@ IMP-45: a step down from CAP range 2 is refused whatever its target while the anti-hunting lock is set (ah_block_down at
@ .Las_do_down, before the OHM guard and before 0x200080A2 is stored); the confirmation count is kept.
@ -----------------------------------------------------------------------------
FUNC ar_sample
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    ldr r10, =ar_state                      @ r10 = state
    ldrb r2, [r10, #AR_ST_DISCARD]
    cbz r2, 1f
    subs r2, r2, #1
    strb r2, [r10, #AR_ST_DISCARD]
    b .Las_discard                          @ conversion refused: settling after the apply
1:  ldr r2, =ar_mode_req
    ldrb r2, [r2]
    ldr r3, =ar_range_req
    ldrb r3, [r3]
    orrs r2, r2, r3
    bne .Las_discard                        @ an apply is pending: this sample belongs to the old configuration
    ldr r5, =meter_mode
    ldrb r5, [r5]                           @ r5 = mode
    movs r2, #1
    lsls r2, r2, r5
    ldr r3, =AR_FAST_MASK
    tst r2, r3
    beq .Las_accept                         @ mode without sample-based ranging
    ldr r2, =ar_cal_mode                    @ same gate as autorange_step 0x0800E020, plus HOLD (stage 1 and 2)
    ldrb r2, [r2]
    ldr r3, =ar_range_manual
    ldrb r3, [r3]
    orrs r2, r2, r3
    ldr r3, =ar_minmax
    ldrb r3, [r3]
    orrs r2, r2, r3
    ldr r3, =ar_hold_active
    ldrb r3, [r3]
    orrs r2, r2, r3
    ldr r3, =ar_hold_stage2
    ldrb r3, [r3]
    orrs r2, r2, r3
    bne .Las_accept                         @ ranging frozen or not allowed
    ldr r2, =ar_settle
    ldrb r2, [r2]
    cmp r2, #0
    bne .Las_accept                         @ the old range's settle count is still running
    ldr r2, =range_count
    ldrb r7, [r2, r5]                       @ r7 = number of ranges of this mode
    cmp r7, #2
    blo .Las_accept                         @ single range: only the overload flag matters (autorange_step)
    ldr r6, =meter_range
    ldrb r6, [r6]                           @ r6 = present range c
    cmp r6, r7
    bhs .Las_accept                         @ range outside the table: leave it to v2.05 code
    asrs r2, r0, #31                        @ r4 = |value| (branch-free absolute value)
    eors r0, r0, r2
    subs r4, r0, r2
    ubfx r1, r1, #0, #24                    @ r1 = the 24-bit code (a sign-extended 32-bit code gives the same bits)
    ldr r2, =AR_SAT_LO
    subs r1, r1, r2
    movs r8, #0                             @ r8 = 1 when the code is 0x7FFFFE .. 0x800001
    cmp r1, #AR_SAT_SPAN
    bhi 2f
    movs r8, #1
2:  cmp r5, #MODE_CAP
    beq .Las_chk_under                      @ CAP: no sample-based step up (the counter timeout and autorange_step do that)
    mov r0, r5
    mov r1, r6
    movs r2, #1                             @ the present range honours the overload latch
    bl ar_thr_up
    cmp r8, #0
    bne .Las_over                           @ saturated: over whatever the value says
    cmp r4, r0
    bhi .Las_over                           @ |value| > U
@ not over (or CAP, which has no sample-based step up): test for under-range
.Las_chk_under:
    cbz r6, .Las_inband                     @ range 0 cannot go down
    mov r0, r5
    mov r1, r6
    bl ar_thr_low
    cmp r4, r0
    blo .Las_under                          @ |value| < L
@ range 0 (cannot go down) or |value| >= L: between the thresholds
.Las_inband:
    movs r2, #0                             @ between L and U: the confirmation starts again
    ldr r3, =ar_ohm_jump
    strb r2, [r3]                           @ the reading belongs here: a jump needs no correction
    strb r2, [r10, #AR_ST_OVER]
    strb r2, [r10, #AR_ST_UNDER]
    b .Las_accept

@ the sample is above U or saturated: one more sample towards a step up
.Las_over:
    movs r2, #0
    strb r2, [r10, #AR_ST_UNDER]
    ldrb r2, [r10, #AR_ST_OVER]
    cmp r2, #AR_K
    bhs 3f
    adds r2, r2, #1
    strb r2, [r10, #AR_ST_OVER]             @ one more sample above U
3:  cmp r2, #AR_K
    blo .Las_accept                         @ not confirmed yet
    subs r2, r7, #1                         @ r2 = top range
    cmp r6, r2
    bhs .Las_accept                         @ at the top range already: the overload is autorange_step's
    cmp r8, #0
    beq .Las_search_up
    adds r9, r6, #1                         @ saturated: one range up ...
    cmp r5, #MODE_OHM
    bne .Las_do_up
    mov r9, r2                              @ ... but OHM jumps to the top range, whose reading then gives the target
    movs r0, #1
    bl fn_0800E2A0                          @ OHM direction guard for an up step (1 = refused)
    cmp r0, #0
    bne .Las_accept
    bl .Las_commit_sub                      @ commit the jump (clears ar_ohm_jump) ...
    adds r2, r9, #1
    ldr r3, =ar_ohm_jump
    strb r2, [r3]                           @ ... and mark it: the next step down is its correction
    b .Las_accept
@ confirmed and not saturated: find the lowest range that holds the value
.Las_search_up:
    subs r4, r4, #1                         @ r4 = |value| - 1: lower bound of the true value
    adds r9, r6, #1                         @ r9 = candidate j = c + 1
@ candidate range j in r9: reading of range j = (|value| - 1) / 10^(j - c)
.Las_up_loop:
    subs r0, r9, r6                         @ m = j - c
    ldr r1, =ar_pow10
    ldr r1, [r1, r0, lsl #2]                @ 10^m
    udiv r8, r4, r1                         @ r8 = (|value| - 1) / 10^m, the reading in range j
    mov r0, r5
    mov r1, r9
    movs r2, #0                             @ a range above the present one starts without the latch
    bl ar_thr_up                            @ r0 = U_j
    cmp r8, r0
    bls .Las_do_up                          @ fits range j: the lowest range that does
    adds r9, r9, #1
    cmp r9, r7
    blo .Las_up_loop
    subs r9, r7, #1                         @ fits none: the top range
@ target range in r9: ask the OHM direction guard, then commit
.Las_do_up:
    movs r0, #1
    bl fn_0800E2A0                          @ OHM direction guard for an up step (1 = refused)
    cmp r0, #0
    bne .Las_accept
    b .Las_commit

@ the sample is below L: one more sample towards a step down
.Las_under:
    movs r2, #0
    strb r2, [r10, #AR_ST_OVER]
    ldrb r2, [r10, #AR_ST_UNDER]
    cmp r2, #AR_K
    bhs 4f
    adds r2, r2, #1
    strb r2, [r10, #AR_ST_UNDER]            @ one more sample below L
4:  movs r3, #AR_K
    cmp r5, #MODE_CAP
    bne 5f
    movs r3, #1                             @ CAP: one conversion is a result
5:  cmp r2, r3
    blo .Las_accept                         @ not confirmed yet
    subs r9, r6, #1                         @ r9 = candidate k = c - 1
@ candidate range k in r9: it holds the value when (|value| + 1) * 10^(c - k) >= L_k
.Las_dn_loop:
    cmp r9, #0
    beq .Las_do_down                        @ range 0: nothing lower
    subs r0, r6, r9                         @ m = c - k
    cmp r5, #MODE_CAP
    bne 6f
    cmp r6, #5
    bne 6f
    adds r0, r0, #1                         @ CAP range 5 counts whole uF (0 decimals), range 4 hundredths: ratio 100, not 10
6:  ldr r1, =ar_pow10
    ldr r8, [r1, r0, lsl #2]                @ r8 = 10^m
    mov r0, r5
    mov r1, r9
    bl ar_thr_low                           @ r0 = L_k
    adds r0, r0, r8
    subs r0, r0, #1
    udiv r0, r0, r8                         @ r0 = ceil(L_k / 10^m)
    adds r2, r4, #1                         @ |value| + 1: upper bound of the true value
    cmp r2, r0
    bhs .Las_do_down                        @ (|value| + 1) * 10^m >= L_k: the highest range that keeps the reading
    subs r9, r9, #1
    b .Las_dn_loop
@ target range in r9 (0 when none higher holds the value): ask the OHM direction guard, then commit
.Las_do_down:
    @ IMP-45: CAP range 2 locked by the anti-hunting rule (SETUP page HUnt): no step down, whatever the target (this
    @ includes a jump from range 2 to range 0), before the OHM guard and before ar_cap_small is stored below.  r4 = |X|
    mov r0, r4
    bl ah_block_down                        @ r0 = 1 refuse; the lock is taken here when two range-1 timeouts were counted
    cmp r0, #0
    bne .Las_accept
    ldr r3, =ar_ohm_jump
    ldrb r2, [r3]
    subs r2, r2, #1
    cmp r2, r6
    bne 7f                                  @ not the first step down after an OHM jump to this range
    movs r2, #0
    ldr r3, =ar_ohm_dir
    strb r2, [r3]                           @ the correction of the jump is measured, not a reversal: the guard allows it
7:  movs r0, #0
    bl fn_0800E2A0                          @ OHM direction guard for a down step (1 = refused)
    cmp r0, #0
    bne .Las_accept
    cmp r5, #MODE_CAP
    bne .Las_commit
    cmp r6, #2
    bne .Las_commit
    cmp r4, #11
    bhs .Las_commit
    movs r2, #1                             @ leaving CAP range 2 with a reading below 11 (0x0800E20C..0x0800E21A)
    ldr r3, =ar_cap_small
    strb r2, [r3]
@ change the range: new range, apply request for the main loop, blank request, restart the confirmation
.Las_commit:
    bl .Las_commit_sub
    b .Las_accept
@ the commit itself, a local subroutine (r9 = new range, r5 = mode, r10 = ar_state; clobbers r0-r3, lr)
.Las_commit_sub:
    push {lr}
    movs r2, #0
    ldr r3, =ar_ohm_jump
    strb r2, [r3]                           @ a new range: any jump correction is done or void
    cmp r5, #MODE_OHM
    bne 1f
    ldr r2, =hold_stage2
    ldrb r2, [r2]
    cbnz r2, 1f                             @ auto-hold stage 2 keeps its digits, as the v2.05 blank rule (0x08016FEC)
    movs r0, #0
    bl fn_08019A98                          @ OHM: blank the main digits now (v2.05 decides and blanks in the same pass);
1:                                          @ the apply draws the new decimal point and its skip counter (2 updates for
                                            @ r1..r5) holds the display stage, which would leave the old digits standing
    ldr r2, =meter_range
    strb r9, [r2]                           @ new range
    movs r2, #1
    ldr r3, =ar_range_req
    strb r2, [r3]                           @ the main loop applies it (loop step 13)
    ldr r3, =ar_blank
    strb r2, [r3]                           @ blank digits with the new decimal point until the first valid result
    strb r2, [r10, #AR_ST_PEND]             @ autorange_step takes no decision until the apply has run
    movs r2, #0
    strb r2, [r10, #AR_ST_OVER]
    strb r2, [r10, #AR_ST_UNDER]
    pop {pc}
@ the sample is accepted into the mean
.Las_accept:
    movs r0, #0
    b .Las_exit
@ the sample is refused: the caller must not accumulate it
.Las_discard:
    movs r0, #1
@ common return
.Las_exit:
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ar_sample
    .ltorg

