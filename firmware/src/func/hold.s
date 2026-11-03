@ =============================================================================
@ hold.s - FUNC: HOLD and auto-hold
@
@ Port of the v2.05 functions
@   fn_0800E30C  auto-hold evaluation, called for every new result while HOLD or auto-hold is on (v2.05 FUN_0800E30C)
@   fn_0801584C  enter or leave auto-hold (HOLD stage 2) and clear the related state (v2.05 FUN_0801584C)
@   fn_0801A028  hold state code for the display and the BLE packet (v2.05 FUN_0801a028)
@
@ HOLD in v2.05 (analysis/keys_setup.md section 2): the first HOLD press sets hold_active (0x2000804F); the second press
@ clears it and sets hold_stage2 (0x20008050, "auto-hold", through fn_0801584C(1, 0)) except in modes 6, 7, 8, 12 or
@ with MIN/MAX on, where it clears HOLD; the third press clears both.  In auto-hold the reading is captured by
@ fn_0800E30C: it waits until a signal above 1000 counts has been present for 0.5 s (the TIM2 handler counts
@ 0x20007FB2 to 0x32 and sets 0x20008051), then captures a value that is stable within +-20 counts in two evaluations,
@ 0.5 s apart, beeps (pe7_on_with_timeout(0x32)) and stores the value; a new capture needs the reading to move at
@ least 400 counts away from the last captured value (or a range change).
@
@ The names of the RAM variables used here are file-local aliases of the v2.05 addresses; their roles are derived from
@ the v2.05 code of this file (cited at the uses), the TIM2 handler 0x080244AC..0x080245BC and the main loop step 13
@ (0x08024D7E..0x08024DD0).
@
@ Calling convention (AAPCS, DESIGN.md 6): r0-r3, r12 and the flags are scratch.  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.func, "ax", %progbits


    .equ func_full_scale,   v_20007D60   @ full scale of the current range in counts (s32)
    .equ func_reading,      v_20007D64   @ displayed value in counts (s32); written by the measurement chains, post-processed in fn_0800DCFC
    .equ func_ahold_ref,    v_20007DA0   @ s32, reference value: the last captured value (or the reading while the signal is absent)
    .equ func_ahold_cand,   v_20007DA4   @ s32, candidate value of the stability test
    .equ func_ahold_value,  v_20007DAC   @ s32, the captured value
    .equ func_ahold_ticks,  v_20007FB2   @ u16 tick counter of the TIM2 handler (0.01 s steps) while auto-hold waits for a signal
    .equ func_log_active,   v_20007FE1   @ u8, logging on
    .equ func_log_hold_req, v_20007FE2   @ u8, set to request a log record at a capture
    .equ func_memview,      v_20007FE4   @ u8, stored-data view on
    .equ func_ol_flag,      v_20008046   @ overload flag (u8): the display shows OFL
    .equ func_ahold_timeout, v_20008051   @ u8, set by the TIM2 handler when ahold_ticks reaches 0x32 (0.5 s with a signal present)
    .equ func_ahold_nosignal, v_20008052   @ u8, set when the signal is below 1000 counts, cleared when it is above
    .equ func_ahold_captured, v_20008053   @ u8, 1 when a value has been captured (the LCD uses it to select the partial commit)
    .equ func_ahold_reapplied, v_20008054   @ u8, set by the main loop (step 13) after a range re-apply in auto-hold, cleared here
    .equ func_ahold_ol_jump, v_20008055   @ u8, OHM auto-hold jump pending (set by the auto-ranging), cleared at a capture
    .equ func_ahold_range,  v_20008056   @ u8, range number at the capture (read by the auto-ranging for the OHM jump)
    .equ func_ahold_cand_valid, v_20008057   @ u8, 1 when ahold_cand holds a candidate value
    .equ func_ohm_skip,     v_2000805A   @ OHM display skip counter (u8), 2 after an OHM range 1..5 is applied
    .equ func_disp_blank,   v_2000805C   @ display blank flag set while a range change settles (u8)
    .equ func_new_result,   v_2000805D   @ new-result flag (u8): set by the mode handlers, cleared by the evaluations

@ -----------------------------------------------------------------------------
@ fn_0800E30C - auto-hold evaluation of a new result
@ Replaces : 0x0800E30C (v2.05 FUN_0800e30c)
@ In       : none (state in RAM)
@ Out      : none (clears new_result when the result is not to be used further)
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : reads hold_active, hold_stage2, func_disp_blank, meter_mode, range_manual, meter_range, func_ohm_skip, func_reading,
@            full_scale, ol_flag, func_ahold_*; writes func_ahold_*, new_result, log_hold_req
@ Spec     : analysis/keys_setup.md section 2 (HOLD), analysis/autorange_and_scheduler.md (OHM jump)
@ Deviation: production: IMP-22 (OHM and DIODE: any reading without overload is a signal); otherwise the v2.05 sequence
@ -----------------------------------------------------------------------------
FUNC fn_0800E30C
    push {r3, r4, r5, lr}                  @ save r3 (stack alignment), r4, r5, the return address
    movs r4, #0                            @ r4 = 0
    ldr r0, =hold_active
    ldrb r0, [r0, #0]                      @ r0 = hold_active
    ldr r1, =hold_stage2                   @ r1 = hold_stage2
    ldrb r1, [r1, #0]                      @ r1 = hold_stage2
    orrs r0, r1                            @ r0 = hold_active | hold_stage2
    uxtb r0, r0
    cmp r0, #0
    beq .Lahold_0800E592                   @ neither HOLD nor auto-hold: nothing to do
    ldr r0, =func_disp_blank
    ldrb r0, [r0, #0]                      @ r0 = func_disp_blank
    cmp r0, #0
    bne .Lahold_0800E592                   @ display blanked by a range change: nothing to do
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #9                             @ mode 9 (OHM)?
    bne .Lahold_0800E366
    ldr r0, =range_manual
    ldrb r0, [r0, #0]                      @ r0 = range_manual
    cmp r0, #0
    bne .Lahold_0800E366                   @ manual range: the OHM rule below does not apply
    ldr r0, =meter_range
    ldrb r0, [r0, #0]                      @ r0 = meter_range
    cmp r0, #0
    beq .Lahold_0800E366                   @ range 0: the OHM rule does not apply
    ldr r0, =meter_range
    ldrb r0, [r0, #0]                      @ r0 = meter_range
    cmp r0, #6
    bge .Lahold_0800E366                   @ range 6 or above: the OHM rule does not apply
    ldr r0, =func_ohm_skip
    ldrb r0, [r0, #0]                      @ r0 = func_ohm_skip
    cmp r0, #0
    bne .Lahold_0800E592                   @ OHM range 1..5, auto range, OHM skip counter still running: wait
    @ Signal test.  r4 = 1000 counts, the signal threshold.
.Lahold_0800E366:
    .if LOOP_V205 == 0
    @ IMP-22 (owner decision 2026-11-03): in OHM (mode 9) and DIODE (mode 11) open probes read OL, so there "no signal" is the
    @ overload, and readings below 1000 counts, 0 included (a short, a good fuse, a shorted junction), are signals once the
    @ auto-ranging has nowhere lower to go.  v2.05 requires 1000 counts there too (0x0800E366..0x0800E3BE), so 0 ohm and 0 V
    @ were never captured.  The other modes keep the threshold: their open probes read about 0.
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]
    cmp r0, #9
    beq 1f
    cmp r0, #11
    bne 2f
1:  ldr r0, =func_ol_flag
    ldrb r0, [r0, #0]
    cmp r0, #0
    bne 3f                                 @ overload (probes open): no signal
    @ no overload.  A reading of at least 1000 counts (either sign) is a signal at once; a smaller one only where the
    @ auto-ranging cannot go lower (range 0, or manual range): while it still steps down towards a short the value would be
    @ captured in a higher range (0.000 kohm instead of 0.00 ohm)
    ldr r0, =func_reading
    ldr r0, [r0, #0]
    cmp r0, #0
    it mi
    negmi r0, r0                           @ |reading|
    cmp r0, #0x3e8
    bhs .Lahold_0800E3BE                   @ |reading| >= 1000: signal
    ldr r0, =meter_range
    ldrb r0, [r0, #0]
    cbz r0, .Lahold_0800E3BE_far           @ range 0: signal, 0 included
    ldr r0, =range_manual
    ldrb r0, [r0, #0]
    cmp r0, #0
    bne .Lahold_0800E3BE                   @ manual range: signal, 0 included
3:  @ overload, or a small reading while the auto-ranging steps down: no signal.  As the "no signal" path below, but the
    @ reference becomes 1000000 (an impossible reading, as v2.05 sets it for an OHM overload at 0x0800E47A) instead of the reading: the reading can already be the next
    @ value (0 while the overload flag of a range change is still set), and a reference equal to it would make the first
    @ real value "not new" (the 400-count change test) and block its capture
    movs r0, #1
    ldr r1, =func_ahold_nosignal
    strb r0, [r1, #0]
    movs r0, #0
    ldr r1, =func_ahold_timeout
    strb r0, [r1, #0]
    ldr r1, =func_ahold_ticks
    strh r0, [r1, #0]
    ldr r1, =func_new_result
    strb r0, [r1, #0]
    ldr r0, =0x000F4240
    ldr r1, =func_ahold_ref
    str r0, [r1, #0]
    b .Lahold_0800E592
.Lahold_0800E3BE_far:
    b .Lahold_0800E3BE
2:
    .endif
    mov r0, #0x3e8
    movs r4, r0                            @ r4 = 1000
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #9
    beq .Lahold_0800E380                   @ mode 9 (OHM) or mode 10 (BEEP): the value is a resistance, only positive values count
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #0xa
    bne .Lahold_0800E394
    @ OHM / BEEP: a signal is a reading of at least 1000 counts without overload.
.Lahold_0800E380:
    ldr r0, =func_reading
    ldr r0, [r0, #0]                       @ r0 = func_reading
    cmp r0, r4
    blt .Lahold_0800E394                   @ reading below 1000: no signal
    ldr r0, =func_ol_flag
    ldrb r0, [r0, #0]                      @ r0 = func_ol_flag
    cmp r0, #0
    beq .Lahold_0800E3BE                   @ reading at least 1000 and no overload: signal present
    @ Other modes (and OHM/BEEP without a signal): |reading| >= 1000 counts means a signal.
.Lahold_0800E394:
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #9
    beq .Lahold_0800E3F6                   @ OHM: no signal
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #0xa
    beq .Lahold_0800E3F6                   @ BEEP: no signal
    ldr r0, =func_reading
    ldr r0, [r0, #0]                       @ r0 = func_reading
    cmp r0, r4
    bge .Lahold_0800E3BE                   @ reading >= 1000: signal present
    negs r0, r4
    ldr r1, =func_reading
    ldr r1, [r1, #0]                       @ r1 = func_reading
    cmp r0, r1
    blt .Lahold_0800E3F6                   @ reading > -1000 (and < 1000): no signal; otherwise (reading <= -1000) a signal is present
    @ Signal present.
.Lahold_0800E3BE:
    ldr r0, =func_ahold_nosignal
    ldrb r0, [r0, #0]                      @ r0 = func_ahold_nosignal
    cmp r0, #0
    beq .Lahold_0800E3E0                   @ the "no signal" flag was not set: continue
    movs r0, #0                            @ the signal has just come back: clear the "no signal" flag ...
    ldr r1, =func_ahold_nosignal
    strb r0, [r1, #0]                      @ func_ahold_nosignal = r0
    movs r0, #0                            @ ... clear the 0.5 s flag ...
    ldr r1, =func_ahold_timeout
    strb r0, [r1, #0]                      @ func_ahold_timeout = r0
    movs r0, #0                            @ ... restart the tick counter
    ldr r1, =func_ahold_ticks
    strh r0, [r1, #0]                      @ func_ahold_ticks = r0
    @ Wait for the 0.5 s flag or an overload.
.Lahold_0800E3E0:
    ldr r0, =func_ahold_timeout
    ldrb r0, [r0, #0]                      @ r0 = func_ahold_timeout
    ldr r1, =func_ol_flag                  @ r1 = overload flag
    ldrb r1, [r1, #0]                      @ r1 = func_ol_flag
    orrs r0, r1
    uxtb r0, r0
    cmp r0, #0
    bne .Lahold_0800E42E                   @ 0.5 s elapsed or overload: evaluate
    b .Lahold_0800E424                     @ not yet: discard this result
    @ No signal.
.Lahold_0800E3F6:
    movs r0, #1                            @ set the "no signal" flag ...
    ldr r1, =func_ahold_nosignal
    strb r0, [r1, #0]                      @ func_ahold_nosignal = r0
    movs r0, #0                            @ ... clear the 0.5 s flag ...
    ldr r1, =func_ahold_timeout
    strb r0, [r1, #0]                      @ func_ahold_timeout = r0
    movs r0, #0                            @ ... restart the tick counter ...
    ldr r1, =func_ahold_ticks
    strh r0, [r1, #0]                      @ func_ahold_ticks = r0
    ldr r0, =func_reading                  @ ... the reference value becomes the current reading ...
    ldr r0, [r0, #0]                       @ r0 = func_reading
    ldr r1, =func_ahold_ref
    str r0, [r1, #0]                       @ func_ahold_ref = r0
    movs r0, #0                            @ ... and the result is discarded
    ldr r1, =func_new_result
    strb r0, [r1, #0]                      @ func_new_result = r0
    b .Lahold_0800E592
    @ Not yet: discard the result.
.Lahold_0800E424:
    movs r0, #0
    ldr r1, =func_new_result
    strb r0, [r1, #0]                      @ func_new_result = r0
    b .Lahold_0800E592
    @ Evaluate (the 0.5 s flag or an overload is set).
.Lahold_0800E42E:
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #9                             @ mode 9: evaluate even with an overload
    beq .Lahold_0800E44E
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #0xa                           @ mode 10: evaluate even with an overload
    beq .Lahold_0800E44E
    ldr r0, =func_ol_flag
    ldrb r0, [r0, #0]                      @ r0 = func_ol_flag
    cmp r0, #0                             @ other modes: an overload ends the evaluation
    bne .Lahold_0800E592
    @ r4 = reading.
.Lahold_0800E44E:
    ldr r0, =func_reading
    ldr r0, [r0, #0]                       @ r0 = func_reading
    movs r4, r0                            @ r4 = the reading to evaluate
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #9                             @ mode 9?
    beq .Lahold_0800E46A
    ldr r0, =meter_mode
    ldrb r0, [r0, #0]                      @ r0 = meter_mode
    cmp r0, #0xa                           @ mode 10?
    bne .Lahold_0800E490
    @ OHM / BEEP: test the overload flag.
.Lahold_0800E46A:
    ldr r0, =func_ol_flag
    ldrb r0, [r0, #0]                      @ r0 = func_ol_flag
    cmp r0, #0                             @ OHM or BEEP with overload (open circuit): ...
    beq .Lahold_0800E490
    movs r0, #0                            @ ... discard the result, clear the candidate flag ...
    ldr r1, =func_new_result
    strb r0, [r1, #0]                      @ func_new_result = r0
    ldr r0, =0x000F4240                    @ ... the reference value becomes 1000000 (an impossible reading, so the next real reading is a new value) ...
    ldr r1, =func_ahold_ref
    str r0, [r1, #0]                       @ func_ahold_ref = r0
    movs r0, #0
    ldr r1, =func_ahold_cand_valid
    strb r0, [r1, #0]                      @ func_ahold_cand_valid = r0
    b .Lahold_0800E582                     @ ... and restart the timers
    @ Change test.
.Lahold_0800E490:
    ldr r0, =func_ahold_reapplied
    ldrb r0, [r0, #0]                      @ r0 = "re-applied" flag
    ldr r1, =func_ol_flag
    ldrb r1, [r1, #0]                      @ r1 = func_ol_flag
    eors r1, r1, #1                        @ r1 = NOT overload flag
    tst r0, r1                             @ re-applied and no overload: treat the value as new
    bne .Lahold_0800E4C0
    ldr r0, =func_ahold_ref
    ldr r0, [r0, #0]                       @ r0 = func_ahold_ref
    adds r0, r0, #0x190                    @ reference + 400
    cmp r4, r0
    bge .Lahold_0800E4C0                   @ reading at least 400 above the reference: new value
    ldr r0, =func_ahold_ref
    ldr r0, [r0, #0]                       @ r0 = func_ahold_ref
    subs r0, r0, #0x190                    @ reference - 400
    cmp r0, r4
    blt .Lahold_0800E572                   @ reading less than 400 away from the reference: no new value, discard
    @ New value.
.Lahold_0800E4C0:
    movs r0, #0                            @ clear the "re-applied" flag
    ldr r1, =func_ahold_reapplied
    strb r0, [r1, #0]                      @ func_ahold_reapplied = r0
    cmp r4, #0                             @ r5 = |reading|
    bpl .Lahold_0800E4D2
    negs r0, r4
    movs r5, r0
    b .Lahold_0800E4D4
    @ r5 = reading (non-negative reading).
.Lahold_0800E4D2:
    movs r5, r4
    @ Compare |reading| with the overload limit.
.Lahold_0800E4D4:
    ldr r0, =func_full_scale               @ full scale
    ldr r0, [r0, #0]                       @ r0 = func_full_scale
    ldr r1, =func_full_scale               @ full scale / 10
    ldr r1, [r1, #0]                       @ r1 = func_full_scale
    movs r2, #0xa
    udiv r1, r1, r2
    adds r0, r1, r0                        @ r0 = full scale + full scale / 10 (the overload limit)
    cmp r0, r5
    bcc .Lahold_0800E582                   @ the reading exceeds the overload limit: no capture
    ldr r0, =func_ahold_cand_valid
    ldrb r0, [r0, #0]                      @ r0 = func_ahold_cand_valid
    cmp r0, #0                             @ candidate present?
    bne .Lahold_0800E506                   @ yes: compare with it
    movs r0, #1                            @ first candidate: remember it ...
    ldr r1, =func_ahold_cand_valid
    strb r0, [r1, #0]                      @ func_ahold_cand_valid = r0
    ldr r0, =func_ahold_cand
    str r4, [r0, #0]                       @ func_ahold_cand = r4
    b .Lahold_0800E582
    @ Stability test: the reading must stay within 20 counts of the candidate.
.Lahold_0800E506:
    ldr r0, =func_ahold_cand
    ldr r0, [r0, #0]                       @ r0 = func_ahold_cand
    subs r0, #0x14                         @ candidate - 20
    cmp r4, r0
    blt .Lahold_0800E568                   @ reading below the window: not stable
    ldr r0, =func_ahold_cand
    ldr r0, [r0, #0]                       @ r0 = func_ahold_cand
    adds r0, #0x14                         @ candidate + 20
    cmp r0, r4
    blt .Lahold_0800E568                   @ reading above the window: not stable
    movs r0, #0                            @ stable: clear the candidate flag ...
    ldr r1, =func_ahold_cand_valid
    strb r0, [r1, #0]                      @ func_ahold_cand_valid = r0
    ldr r0, =func_ahold_value              @ ... store the captured value ...
    str r4, [r0, #0]                       @ func_ahold_value = r4
    movs r0, #1                            @ ... mark it captured ...
    ldr r1, =func_ahold_captured
    strb r0, [r1, #0]                      @ func_ahold_captured = r0
    ldr r0, =func_ahold_ref                @ ... it becomes the reference ...
    str r4, [r0, #0]                       @ func_ahold_ref = r4
    ldr r0, =meter_range                   @ ... remember the range of the capture ...
    ldrb r0, [r0, #0]                      @ r0 = meter_range
    ldr r1, =func_ahold_range
    strb r0, [r1, #0]                      @ func_ahold_range = r0
    movs r0, #0                            @ ... clear the OHM jump request ...
    ldr r1, =func_ahold_ol_jump
    strb r0, [r1, #0]                      @ func_ahold_ol_jump = r0
    ldr r0, =func_log_active               @ ... when logging is on ...
    ldrb r0, [r0, #0]                      @ r0 = func_log_active
    cmp r0, #0
    beq .Lahold_0800E560
    movs r0, #1
    ldr r1, =func_log_hold_req             @ ... request a log record
    strb r0, [r1, #0]                      @ func_log_hold_req = r0
    @ Beep.
.Lahold_0800E560:
    movs r0, #0x32                         @ beep: 50 ticks; OF-63: gated by the buzzer setting (fn_0800EEA8; v2.05
    bl fn_0800EEA8                         @ pe7_on_with_timeout sounds with the setting off)
    b .Lahold_0800E582
    @ Not stable: forget the candidate.
.Lahold_0800E568:
    movs r0, #0
    ldr r1, =func_ahold_cand_valid
    strb r0, [r1, #0]                      @ func_ahold_cand_valid = r0
    b .Lahold_0800E582
    @ No new value: discard the result and forget the candidate.
.Lahold_0800E572:
    movs r0, #0
    ldr r1, =func_new_result
    strb r0, [r1, #0]                      @ func_new_result = r0
    movs r0, #0
    ldr r1, =func_ahold_cand_valid
    strb r0, [r1, #0]                      @ func_ahold_cand_valid = r0
    @ End of an evaluation: restart the 0.5 s timer.
.Lahold_0800E582:
    movs r0, #0                            @ clear the 0.5 s flag ...
    ldr r1, =func_ahold_timeout
    strb r0, [r1, #0]                      @ func_ahold_timeout = r0
    movs r0, #0                            @ ... and the tick counter
    ldr r1, =func_ahold_ticks
    strh r0, [r1, #0]                      @ func_ahold_ticks = r0
    @ Return.
.Lahold_0800E592:
    pop {r0, r4, r5, pc}
ENDFUNC fn_0800E30C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801584C - enter or leave auto-hold and clear the related state
@ Replaces : 0x0801584C (v2.05 FUN_0801584c)
@ In       : r0 = 1 enter auto-hold (HOLD stage 2), 0 leave it; r1 = 1 also clear MIN/MAX and REL and redraw the annunciators
@ Out      : none
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : writes hold_active, hold_stage2, func_ahold_*, minmax_state, rel_active
@ Spec     : analysis/keys_setup.md section 2 (HOLD, MEM+HOLD)
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801584C
    push {r3, r4, r5, lr}                  @ save r3 (stack alignment), r4, r5, the return address
    movs r4, r0                            @ r4 = enter flag
    movs r5, r1                            @ r5 = clear flag
    movs r0, #0                            @ hold_active = 0 ...
    ldr r1, =hold_active
    strb r0, [r1, #0]                      @ hold_active = r0
    uxtb r4, r4                            @ enter flag
    cmp r4, #0
    beq .Lhset_08015886                    @ 0: leave
    movs r0, #1                            @ enter: captured = 1 ...
    ldr r1, =func_ahold_captured
    strb r0, [r1, #0]                      @ func_ahold_captured = r0
    ldr r1, =func_ahold_timeout
    strb r0, [r1, #0]                      @ ... 0.5 s flag = 1 (evaluate with the first result) ...
    ldr r1, =hold_stage2                   @ ... hold_stage2 = 1 ...
    strb r0, [r1, #0]                      @ hold_stage2 = r0
    ldr r0, =meter_range                   @ ... remember the current range ...
    ldrb r0, [r0, #0]                      @ r0 = meter_range
    ldr r1, =func_ahold_range
    strb r0, [r1, #0]                      @ func_ahold_range = r0
    movs r0, #0                            @ ... clear the OHM jump request
    ldr r1, =func_ahold_ol_jump
    strb r0, [r1, #0]                      @ func_ahold_ol_jump = r0
    b .Lhset_08015898
    @ Leave auto-hold: captured = 0, 0.5 s flag = 0, hold_stage2 = 0.
.Lhset_08015886:
    movs r0, #0
    ldr r1, =func_ahold_captured
    strb r0, [r1, #0]                      @ func_ahold_captured = r0
    ldr r1, =func_ahold_timeout
    strb r0, [r1, #0]                      @ func_ahold_timeout = r0
    ldr r1, =hold_stage2
    strb r0, [r1, #0]                      @ hold_stage2 = r0
    @ Common: no-signal flag and tick counter cleared.
.Lhset_08015898:
    movs r0, #0                            @ no-signal flag = 0
    ldr r1, =func_ahold_nosignal
    strb r0, [r1, #0]                      @ func_ahold_nosignal = r0
    movs r0, #0                            @ tick counter = 0
    ldr r1, =func_ahold_ticks
    strh r0, [r1, #0]                      @ func_ahold_ticks = r0
    uxtb r5, r5                            @ r5 = clear flag
    cmp r5, #1                             @ clear flag set?
    bne .Lhset_080158C8                    @ no: done
    movs r0, #0                            @ yes: update the AUTO annunciator (LCD fn_08019D68(0)) ...
    bl fn_08019D68
    movs r0, #0                            @ ... MIN/MAX off ...
    ldr r1, =minmax_state
    strb r0, [r1, #0]                      @ minmax_state = r0
    movs r0, #0                            @ ... REL off ...
    ldr r1, =rel_active
    strb r0, [r1, #0]                      @ rel_active = r0
    movs r0, #1                            @ ... and the auto-hold annunciator (LCD fn_08019FA2(1))
    bl fn_08019FA2
    @ Return.
.Lhset_080158C8:
    pop {r0, r4, r5, pc}
ENDFUNC fn_0801584C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A028 - hold state code
@ Replaces : 0x0801A028 (v2.05 FUN_0801a028; called by the LCD annunciator code and the BLE packet builder)
@ In       : none
@ Out      : r0 = 0 when logging is on without auto-hold, or when the stored-data view is on, or when neither HOLD nor
@            auto-hold is on; 2 when HOLD is on; 1 when auto-hold is on (analysis/ble_packet.md byte 17)
@ Clobbers : r0-r2, flags
@ Context  : main
@ RAM      : reads func_log_active, hold_stage2, func_memview, hold_active
@ Spec     : analysis/ble_packet.md byte 17; analysis/lcd_map.md
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0801A028
    movs r0, #0                            @ r0 = 0
    ldr r1, =func_log_active
    ldrb r1, [r1, #0]                      @ r1 = logging flag
    ldr r2, =hold_stage2
    ldrb r2, [r2, #0]                      @ r2 = hold_stage2
    eors r2, r2, #1                        @ r2 = NOT hold_stage2
    tst r1, r2                             @ logging on and no auto-hold?
    beq .Lhcode_0801A044                   @ no: next test
    movs r1, #0                            @ yes: code 0
    movs r0, r1
    b .Lhcode_0801A078
    @ Stored-data view?
.Lhcode_0801A044:
    ldr r1, =func_memview
    ldrb r1, [r1, #0]                      @ r1 = func_memview
    cmp r1, #0
    beq .Lhcode_0801A054                   @ no: next test
    movs r1, #0                            @ yes: code 0
    movs r0, r1
    b .Lhcode_0801A078
    @ HOLD?
.Lhcode_0801A054:
    ldr r1, =hold_active
    ldrb r1, [r1, #0]                      @ r1 = hold_active
    cmp r1, #0
    beq .Lhcode_0801A064                   @ no: next test
    movs r1, #2                            @ yes: code 2
    movs r0, r1
    b .Lhcode_0801A078
    @ Auto-hold?
.Lhcode_0801A064:
    ldr r1, =hold_stage2
    ldrb r1, [r1, #0]                      @ r1 = hold_stage2
    cmp r1, #0
    beq .Lhcode_0801A074                   @ no: code 0
    movs r1, #1                            @ yes: code 1
    movs r0, r1
    b .Lhcode_0801A078
    @ Neither: code 0.
.Lhcode_0801A074:
    movs r1, #0
    movs r0, r1
    @ Return the code (low byte).
.Lhcode_0801A078:
    uxtb r0, r0                            @ r0 = code as a byte
    bx lr
ENDFUNC fn_0801A028
    .ltorg

