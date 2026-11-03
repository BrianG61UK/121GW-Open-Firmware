@ =============================================================================
@ dcvavg.s - MDC: DCV averaging with a sliding window and a restart on a step (production image only, DESIGN.md 10 IMP-23)
@
@ v2.05 shows DCV as the mean of non-overlapping blocks of 16 AD1 samples (ad1_accumulate_average): one value per 16
@ samples (200 ms at the 80 sps DCV rows, hy3131_model.md 3), and a block that a step falls into mixes the old and the new
@ level (a 0 -> 9 V step can show 4.5 V once).  In DCV, outside calibration mode, the production image instead:
@   - publishes a mean every 8 samples, the mean of the last 16 (this half block and the previous one): the same 16-sample
@     window, so the same noise as v2.05, at twice the update rate;
@   - restarts the window on a step: a sample more than MDC_DCV_STEP raw codes away from the mean of the running half block,
@     followed by a second one within MDC_DCV_STEP of the first, starts a new block with those two samples and arms the
@     4-sample first mean of IMP-01 (mdc_first_mean), so the first value after a step is the mean of 4 new samples and no
@     straddled mean is shown.  A single deviating sample (a spike) is left out of the window and changes nothing.  The first
@     sample of a half block is compared with the previous half block.
@   - a mean published while the v2.05 settle count still runs (it is discarded) is not kept as the previous half block, so
@     no displayed window contains a sample of the settling time: after a range change the first value is the 4-sample mean
@     of IMP-01, then an 8-sample mean, then the 16-sample window, all from samples v2.05 also takes as settled.
@ MDC_DCV_STEP = 8192 codes: every DCV range spans 50000 counts with about 83.9 codes per count (the AD1 full scale of
@ the row; emulator, synthetic calibration: 83.89 in ranges 0, 1 and 2), so the threshold is about 98 counts, far above
@ the sample noise and far below the steps it is meant for.  A configuration change (fn_0800B974) empties the window.
@ Calibration mode keeps v2.05's blocks of 16 (the captures of CAL average the published means).
@
@ Not present in the strict image (LOOP_V205 = 1): this file assembles to nothing there.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .if LOOP_V205 == 0

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
mdc_dcv_pend:       .space 4                @ a deviating sample waiting for its confirmation
mdc_dcv_prev_n:     .space 1                @ samples of the previous half block, 0 = none (window just restarted)
mdc_dcv_dev:        .space 1                @ 1 = mdc_dcv_pend holds a deviating sample

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
    ldr r5, =mdc_count
    ldr r6, =mdc_sum
    movw r12, #MDC_DCV_STEP
    ldrb r1, [r5]
    cbz r1, .Ldcv_first                     @ empty half block: compare with the previous one
    ldr r2, [r6]
    sdiv r2, r2, r1                         @ mean of the running half block
.Ldcv_test:
    subs r3, r4, r2
    it mi
    negmi r3, r3
    cmp r3, r12
    bls .Ldcv_nodev
    @ deviating sample
    ldr r7, =mdc_dcv_dev
    ldrb r0, [r7]
    cbz r0, .Ldcv_pend                      @ the first one: wait for a second
    ldr r1, =mdc_dcv_pend
    ldr r1, [r1]
    subs r3, r4, r1
    it mi
    negmi r3, r3
    cmp r3, r12
    bhi .Ldcv_pend                          @ not at the level of the pending one: it becomes the pending one
    @ confirmed step: a new window with the two samples, the 4-sample first mean armed
    adds r1, r1, r4
    str r1, [r6]
    movs r0, #2
    strb r0, [r5]
    movs r0, #0
    strb r0, [r7]
    ldr r1, =mdc_dcv_prev_n
    strb r0, [r1]
    movs r0, #1
    ldr r1, =mdc_first_mean
    strb r0, [r1]
    movs r0, #0
    pop {r4-r7, pc}
.Ldcv_pend:
    movs r0, #1
    strb r0, [r7]
    ldr r1, =mdc_dcv_pend
    str r4, [r1]
    movs r0, #0                             @ the sample stays out of the window
    pop {r4-r7, pc}
    @ first sample of a half block: compared with the mean of the previous half block, so that a step on this sample is
    @ seen as well; nothing to compare with after a restart or a change (prev_n = 0)
.Ldcv_first:
    ldr r3, =mdc_dcv_prev_n
    ldrb r1, [r3]
    cbz r1, .Ldcv_nodev
    ldr r2, =mdc_dcv_prev_sum
    ldr r2, [r2]
    sdiv r2, r2, r1
    b .Ldcv_test
.Ldcv_nodev:
    movs r0, #0
    ldr r7, =mdc_dcv_dev
    strb r0, [r7]                           @ a pending deviating sample was a spike: forgotten
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
ENDFUNC mdc_dcv_accumulate

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
    bx lr
ENDFUNC mdc_dcv_reset

    .ltorg

    .endif
