@ =============================================================================
@ sample.s - MAC module: per-sample range detection of the AC modes (IMP-01, production build only)
@
@ IMP-01 (analysis/autorange_and_scheduler.md 5.2 P2..P4): ar_sample judges the calibrated per-sample value of
@ every conversion before the conversion is accumulated into the 16-sample mean, and tells the caller to discard
@ conversions that belong to the settling after a range change.  The auto-ranged DC modes do this in
@ mdc_sample_precheck (MDC); mac_sample_precheck is the same step for the AC modes 0 (LowZ AC), 2 (ACV), 4 (ACmV),
@ 16, 18, 20 (AC currents).  Its contract is the one of mdc_sample_precheck: no arguments, r0 = 1 when the
@ conversion must be discarded (neither accumulated nor handled), 0 when it is accepted.
@
@ The per-sample value is the one the AC handlers produce in their per-sample part (fn_08006AEC from
@ 0x08006BC4, fn_080069B4 from 0x08006A84, fn_080067D6 from 0x08006920): fn_08008468 on the latest sample
@ (0x20007D74), then fn_0800742C, then for ACV and (OF-44) ACmV with the 1 kHz filter on fn_08006D40 on ten times the value.
@ When the conversion is accepted this routine leaves that value in 0x20007D68 and sets mac_ps_done; the handler
@ of the same conversion then skips its own computation and clears the flag, so the float chain runs once per
@ conversion.
@
@ The cases in which a handler computes no per-sample value are skipped here as well, so ar_sample never sees a
@ value that v2.05 would not have produced: ACV in AC+DC (its phases combine their own value) and the
@ burden-voltage phase of the current modes (va_channel = 1 with the burden display on).
@
@ v2.05 has no per-sample ranging (IMP-01).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .section .text.mac, "ax", %progbits

@ -----------------------------------------------------------------------------
@ mac_sample_precheck - per-sample range detection of the AC modes for the conversion about to be accumulated
@ Replaces : new routine (IMP-01); the AC handlers' per-sample parts 0x08006BC4.., 0x08006A84.., 0x08006920..
@ In       : - (the decoded sample is in 0x20007DCC and 0x20007D74)
@ Out      : r0 = 1 the conversion must be discarded (ar_sample: settling after an apply, or an apply is pending),
@            0 accept (also for every mode this routine does not judge)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (ad1_ready_dispatch, after mdc_sample_precheck)
@ RAM      : reads  meter_mode (0x2000803C), cal_mode (0x2000808A), burden_on (0x200080A5), va_channel (0x200080C4),
@                   acdc_active (0x200080BA), filter_1khz (0x200080B9), sample_in (0x20007D74), ad1_sample (0x20007DCC)
@            writes sample_value (0x20007D68), bargraph_update (0x2000805E), mac_ps_done (cleared at entry, set for an
@                   accepted conversion)
@ Spec     : analysis/autorange_and_scheduler.md 5.2 P2, P3; DESIGN.md 6.12, 6.18 (IMP-01)
@ Deviation: IMP-01, OF-44 (ACmV filter correction)
@ -----------------------------------------------------------------------------
FUNC mac_sample_precheck
    movs r1, #0
    ldr r2, =mac_ps_done
    strb r1, [r2]                           @ a flag left by an earlier conversion never survives into this one
    ldr r0, =meter_mode
    ldrb r0, [r0]                           @ r0 = mode
    cmp r0, #2
    beq .Lmsp_acv                           @ mode 2
    cmp r0, #4
    beq .Lmsp_go                            @ mode 4: fn_080069B4 per-sample part
    cmp r0, #0x10
    beq .Lmsp_cur                           @ modes 16, 18, 20
    cmp r0, #0x12
    beq .Lmsp_cur
    cmp r0, #0x14
    bne .Lmsp_skip                          @ any other mode: not judged here
.Lmsp_cur:                                  @ AC currents: fn_0800664A runs fn_080067D6 unless cal_mode = 0 and burden_on = 1
    ldr r1, =v_2000808A
    ldrb r1, [r1]                           @ r1 = cal_mode
    ldr r2, =v_200080A5
    ldrb r2, [r2]
    eors r2, r2, #1                         @ r2 = burden_on ^ 1
    orrs r1, r1, r2
    bne .Lmsp_go                            @ plain chain: current conversion
    ldr r1, =va_channel
    ldrb r1, [r1]
    cbnz r1, .Lmsp_skip                     @ burden display, voltage phase (channel 1): fn_08006AEC makes no per-sample value
    b .Lmsp_go                              @ burden display, current phase
.Lmsp_acv:                                  @ ACV: fn_08006AEC makes no per-sample value in AC+DC
    ldr r1, =acdc_active
    ldrb r1, [r1]
    cbnz r1, .Lmsp_skip                     @ AC+DC: skipped; otherwise fall through
.Lmsp_go:
    push {r4, lr}
    ldr r0, =v_20007D74
    ldr r0, [r0]                            @ r0 = latest sample
    bl fn_08008468                          @ MAC: sample_value = (sample - offset) / gain, bargraph_update = 1
    ldr r0, =meter_mode
    ldrb r4, [r0]                           @ r4 = mode
    ldr r0, =v_20007D68
    ldr r1, [r0]                            @ r1 = sample_value
    mov r0, r4
    bl fn_0800742C                          @ MAC: frequency correction
    ldr r1, =v_20007D68
    str r0, [r1]                            @ sample_value
    cmp r4, #2
    beq 3f
    cmp r4, #4
    bne 1f                                  @ the 1 kHz filter correction belongs to the ACV and (OF-44) ACmV handlers only
3:
    ldr r0, =filter_1khz
    ldrb r0, [r0]
    cmp r0, #1
    bne 1f                                  @ filter off
    ldr r0, =v_20007D68
    ldr r0, [r0]
    movs r1, #10
    muls r0, r1, r0                         @ ten times the value (fn_08008468 divided by ten)
    bl fn_08006D40                          @ MAC: 1 kHz filter correction
    ldr r1, =v_20007D68
    str r0, [r1]                            @ sample_value
1:  ldr r0, =v_20007D68
    ldr r0, [r0]                            @ r0 = calibrated per-sample value
    ldr r1, =v_20007DCC
    ldr r1, [r1]                            @ r1 = decoded AD1 code of this conversion
    bl ar_sample                            @ AR: r0 = 1 discard, 0 accept
    cbnz r0, 2f                             @ discard: the handler does not run, no flag
    movs r1, #1
    ldr r2, =mac_ps_done
    strb r1, [r2]                           @ the handler's own per-sample part is covered (r0 = 0 for the caller)
2:  pop {r4, pc}
.Lmsp_skip:
    movs r0, #0
    bx lr
    .ltorg
ENDFUNC mac_sample_precheck

@ -----------------------------------------------------------------------------
@ Port RAM of module MAC
@ -----------------------------------------------------------------------------
    .section .bss_port.mac, "aw", %nobits
    .global mac_ps_done
mac_ps_done: .space 1                       @ 1 = sample_value of this conversion is in 0x20007D68 (consumed by the AC handlers)

