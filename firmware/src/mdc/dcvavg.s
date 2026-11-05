@ =============================================================================
@ dcvavg.s - MDC: DCV averaging with a sliding window and a restart on a step (production image only, DESIGN.md 10 IMP-23)
@
@ v2.05 shows DCV as the mean of non-overlapping blocks of 16 AD1 samples (ad1_accumulate_average): one value per 16
@ samples (200 ms at the 80 sps DCV rows, hy3131_model.md 3), and a block that a step falls into mixes the old and the new
@ level (a 0 -> 9 V step can show 4.5 V once).  In DCV, outside calibration mode, the production image instead:
@   - publishes a mean every 8 samples, the mean of the last 16 (this half block and the previous one): the same 16-sample
@     window, so the same noise as v2.05, at twice the update rate;
@   - restarts the window on a step (second form, GitHub issue 3): a sample more than MDC_DCV_STEP raw codes away from the last sample
@     taken into the window is held back, and the next sample decides: within MDC_DCV_STEP of the held one = a step, a new
@     block starts with those two samples and arms the 4-sample first mean of IMP-01 (mdc_first_mean), so the first value
@     after a step is the mean of 4 new samples and no straddled mean is shown; back within MDC_DCV_STEP of the last taken
@     sample = the held one was a spike, it is left out and changes nothing; far from both = the input moves faster than
@     MDC_DCV_STEP per sample (a steep ramp, no level to restart on), both samples are taken into the window as v2.05
@     takes every sample.  So every sample is decided within one sample and the published mean never stalls.
@     (The first form compared a sample with the mean of the running half block, which lags a ramp by up to 4 samples of
@     its slope: on a ramp steeper than about MDC_DCV_STEP / 2 per sample every block restarted before it published, and the
@     display and the log held one value for seconds, GitHub issue 3, 0-4 V sine of 40 s period.)
@   - a mean published while the v2.05 settle count still runs (it is discarded) is not kept as the previous half block, so
@     no displayed window contains a sample of the settling time: after a range change the first value is the 4-sample mean
@     of IMP-01, then an 8-sample mean, then the 16-sample window, all from samples v2.05 also takes as settled.
@ MDC_DCV_STEP = 8192 codes: every DCV range spans 50000 counts with about 83.9 codes per count (the AD1 full scale of
@ the row; emulator, synthetic calibration: 83.89 in ranges 0, 1 and 2), so the threshold is about 98 counts, far above
@ the sample noise and far below the steps it is meant for.  A configuration change (fn_0800B974) empties the window.
@ Calibration mode keeps v2.05's blocks of 16 (the captures of CAL average the published means).
@
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ MDC_DCV_HALF, 8                    @ samples per published mean (half of the 16-sample window)
    .equ MDC_DCV_FIRST, 4                   @ samples of the first mean after a step (IMP-01 N_first)
    .equ MDC_DCV_STEP, 8192                 @ step threshold in AD1 codes (about 98 counts)
    .equ mdc_count, v_20008080              @ samples in the running half block (u8, v2.05 block counter)
    .equ mdc_sum, v_20007DD0                @ sum of the running half block (s32, v2.05 block sum)
    .equ mdc_mean, v_20007DD4               @ published mean (s32)
    .equ mdc_settle, v_20000238             @ v2.05 settle count (means still discarded after a change)

    .section .bss_port.mdc, "aw", %nobits
    .balign 4
mdc_dcv_prev_sum:   .space 4                @ sum of the previous half block
mdc_dcv_pend:       .space 4                @ a deviating sample held back for one sample
mdc_dcv_last:       .space 4                @ the last sample taken into the window (the step reference)
mdc_dcv_prev_n:     .space 1                @ samples of the previous half block, 0 = none (window just restarted)
mdc_dcv_dev:        .space 1                @ 1 = mdc_dcv_pend holds a deviating sample
mdc_dcv_lastv:      .space 1                @ 1 = mdc_dcv_last is valid (0 after a configuration change)

    .section .text.mdc.dcvavg, "ax", %progbits

@ -----------------------------------------------------------------------------
@ mdc_dcv_accumulate - DCV form of ad1_accumulate_average (same interface)
@ In       : r0 = decoded sample (fn_080062F8)
@ Out      : r0 = 1 a mean was published in 0x20007DD4, 0 otherwise
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Context  : main only (ad1_accumulate_average, DCV outside calibration mode)
@ -----------------------------------------------------------------------------
FUNC mdc_dcv_accumulate
    push {r4-r7, lr}
    mov r4, r0                              @ r4 = sample
    movw r12, #MDC_DCV_STEP
    ldr r7, =mdc_dcv_dev
    ldr r0, =mdc_dcv_lastv
    ldrb r0, [r0]
    cbz r0, .Ldcv_take                      @ no reference yet (after a configuration change): take it
    ldr r1, =mdc_dcv_last
    ldr r1, [r1]
    subs r3, r4, r1
    it mi
    negmi r3, r3                            @ r3 = |sample - last taken|
    ldrb r0, [r7]                           @ r0 = 1 a sample is held back (ldrb leaves the flags alone)
    cmp r3, r12
    bhi .Ldcv_far
    @ at the level of the last taken sample: a held-back sample was a spike, it is forgotten
    cbz r0, .Ldcv_take
    movs r0, #0
    strb r0, [r7]
    b .Ldcv_take
.Ldcv_far:
    cbz r0, .Ldcv_pend                      @ the first far sample: hold it back for one sample
    ldr r1, =mdc_dcv_pend
    ldr r1, [r1]                            @ r1 = the held-back sample
    subs r3, r4, r1
    it mi
    negmi r3, r3
    cmp r3, r12
    bls .Ldcv_step                          @ at the held one's level: a step
    @ far from both: the input moves faster than MDC_DCV_STEP per sample; no level to restart on, both are taken
    movs r0, #0
    strb r0, [r7]
    mov r0, r1
    bl mdc_dcv_add                          @ the held-back sample first (in its order)
    mov r5, r0                              @ r5 = 1 it published a mean
    mov r0, r4
    bl mdc_dcv_add
    orrs r0, r0, r5
    pop {r4-r7, pc}
.Ldcv_step:
    @ confirmed step: a new window with the two samples, the 4-sample first mean armed
    adds r1, r1, r4
    ldr r2, =mdc_sum
    str r1, [r2]
    movs r0, #2
    ldr r2, =mdc_count
    strb r0, [r2]
    movs r0, #0
    strb r0, [r7]                           @ nothing held back
    ldr r2, =mdc_dcv_prev_n
    strb r0, [r2]                           @ no previous half block
    ldr r2, =mdc_dcv_last
    str r4, [r2]                            @ the reference is the new level
    movs r0, #1
    ldr r2, =mdc_first_mean
    strb r0, [r2]
    movs r0, #0
    pop {r4-r7, pc}
.Ldcv_pend:
    movs r0, #1
    strb r0, [r7]
    ldr r1, =mdc_dcv_pend
    str r4, [r1]
    movs r0, #0                             @ the sample stays out of the window for now
    pop {r4-r7, pc}
.Ldcv_take:
    mov r0, r4
    bl mdc_dcv_add
    pop {r4-r7, pc}
ENDFUNC mdc_dcv_accumulate

@ -----------------------------------------------------------------------------
@ mdc_dcv_add - take one sample into the window: the running half block, the 4-sample first mean of IMP-01 and the
@               published mean of the 16-sample window every 8 samples
@ In       : r0 = sample
@ Out      : r0 = 1 a mean was published in 0x20007DD4, 0 otherwise
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Context  : main only (mdc_dcv_accumulate)
@ -----------------------------------------------------------------------------
LFUNC mdc_dcv_add
    push {r4-r7, lr}
    mov r4, r0
    ldr r5, =mdc_count
    ldr r6, =mdc_sum
    ldr r1, =mdc_dcv_last
    str r4, [r1]                            @ the step reference is the last taken sample
    movs r0, #1
    ldr r1, =mdc_dcv_lastv
    strb r0, [r1]
    ldrb r1, [r5]
    ldr r2, [r6]
    cbnz r1, 1f
    movs r2, #0                             @ empty half block: the sum starts at this sample
1:  adds r2, r2, r4
    str r2, [r6]
    adds r1, r1, #1
    strb r1, [r5]
    cmp r1, #MDC_DCV_HALF
    bhs .Ldcv_half
    @ IMP-01 first mean: 4 samples after a change or a step, once v2.05 no longer discards means of this change
    cmp r1, #MDC_DCV_FIRST
    bne .Ldcv_none
    ldr r0, =mdc_first_mean
    ldrb r3, [r0]
    cbz r3, .Ldcv_none
    ldr r3, =mdc_settle
    ldrb r3, [r3]
    cbnz r3, .Ldcv_none
    sdiv r2, r2, r1
    ldr r3, =mdc_mean
    str r2, [r3]
    movs r3, #0
    strb r3, [r0]                           @ the first value is out
    movs r0, #1
    pop {r4-r7, pc}
.Ldcv_none:
    movs r0, #0
    pop {r4-r7, pc}
    @ half block complete: publish the mean of this half block and the previous one (or of this one alone after a restart)
.Ldcv_half:
    ldr r7, =mdc_dcv_prev_sum
    ldr r3, =mdc_dcv_prev_n
    ldrb r0, [r3]
    ldr r12, [r7]
    str r2, [r7]                            @ this half block becomes the previous one
    strb r1, [r3]
    cbz r0, 2f
    add r2, r2, r12                         @ sum of the 16-sample window (at most 16 x 2^23: no overflow)
    add r1, r1, r0
2:  sdiv r2, r2, r1
    ldr r3, =mdc_mean
    str r2, [r3]
    movs r0, #0
    strb r0, [r5]
    str r0, [r6]
    ldr r3, =mdc_settle                     @ as ad1_accumulate_average: a mean published while v2.05 still discards
    ldrb r3, [r3]                           @ means is not the first displayed value, so the request stays
    cbnz r3, 3f
    ldr r3, =mdc_first_mean
    strb r0, [r3]
    movs r0, #1
    pop {r4-r7, pc}
    @ the settle count runs: this mean will be discarded (autorange_step 0x0800DEB4), so its samples are still settling and
    @ must not reach a displayed window either: the next published mean starts without a previous half block
3:  ldr r3, =mdc_dcv_prev_n
    strb r0, [r3]                           @ r0 = 0
    movs r0, #1
    pop {r4-r7, pc}
ENDFUNC mdc_dcv_add

@ -----------------------------------------------------------------------------
@ mdc_dcv_reset - empty the DCV window (a configuration change: fn_0800B974)
@ Clobbers : r0, r1
@ -----------------------------------------------------------------------------
FUNC mdc_dcv_reset
    movs r0, #0
    ldr r1, =mdc_dcv_prev_n
    strb r0, [r1]
    ldr r1, =mdc_dcv_dev
    strb r0, [r1]
    ldr r1, =mdc_dcv_lastv
    strb r0, [r1]                           @ no step reference: the first sample of the new configuration is taken
    bx lr
ENDFUNC mdc_dcv_reset

    .ltorg

