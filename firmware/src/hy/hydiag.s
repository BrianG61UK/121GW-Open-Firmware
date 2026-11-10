@ =============================================================================
@ hydiag.s - HY: diagnostic build only (switch HY_DIAG = 1, never released): how the real meter reads the HY3131 AD1
@ result, and whether the chip holds the result during a serial read
@
@ Owner 2026-11-09: "check the meter first before we trust the emulator".  The emulator (emu/hy3131.py) has no hold
@ register: a conversion that completes between the byte loads of a read gives a torn value (+-2^16 raw).  The datasheet
@ (DS-HY3131 V1.0 7.2, 9, 10, 13.1) says nothing about a hold.  This module measures both questions on the meter; its
@ design is the reviewed plan of 2026-11-09, revised twice on 2026-11-10 (Q1 latch experiment, Q2 read timing).
@
@ Q2, read timing (key code 0xA5 clears the counters and starts them, 0xA6 freezes them; any mode):
@   hyd_mark_intf at the start of every HY event service (before the INTF read), hyd_ad1_begin / hyd_ad1_end around the
@   AD1 read of hy3131_service_irq.  Counted only while SYSCLK is MSI (a card session runs at 32 MHz, sys/clock.s):
@   AD1 reads, the time between them (sum and a histogram in BEEP result periods, HYD_PERIOD), the AD1 frame length (CS low
@   to CS high) and the time from the start of the service to the AD1 read (sum and max).  The bus frames are unchanged.
@ Q1, latch experiment (key code 0xA7, BEEP only; run by hyd_step from hy3131_poll in batches of HYD_BATCH steps; a
@   batch outside BEEP ends the run with status "aborted"):
@   Every trial is locked to a conversion: INTF is read (it clears the flags: the experiment consumes the events of the
@   time it holds the main loop; the normal service resumes after the batch), then the routine waits with CS high until
@   DO is high (the next event, timeout HYD_LOCK_TO), t_c = TIM7: conversion N has just completed.
@   A = fast read of 0x00..0x02 (conversion N); X = the same read with a pause inside one byte, after its 4th bit, that
@   ends at t_c + HYD_AFTER (conversion N + 1 completes at t_c + 3807 .. 4009 us, measured, so the bytes loaded after the
@   pause come about 190 us or more after it); B = fast read right after X (conversion N + 1, done before N + 2).  R = the configuration registers
@   0x21..0x23 read fast and with the same pause place: they must agree (a pause that broke the serial state shows
@   here; 0x21..0x23 are written only by the row frame, the restarts write R20 / R29; hy_row_r20 is no reference).
@   A pause BETWEEN bytes would test nothing: the chip loads byte n + 1 at the clock edge that ends byte n (emulator
@   emu/hy3131.py _ck_fall / _load, and any byte-wide output shift register), so the pauses are inside a byte.
@   Trial types (trial index & 3): 0 no pause (control: A == X == B), 1 inside the address byte (bytes 0..2 load after
@   the pause), 2 inside data byte 0 (bytes 1..2 after), 3 inside data byte 1 (byte 2 after).
@   Classified on the bytes the type tests (mask hyd_masks): not informative (A and B equal there), held (X equals A),
@   live (X equals B), other; for types 2 and 3 the paused byte also per 4-bit half (its first half from A, its second
@   from B: a chip that sends each bit live from the register file).  Also counted: trials without a lock, R wrong, the
@   longest time from t_c to the end of B.
@   A sensitivity sample comes first: HYD_SAMPLES locked pairs of fast reads one result apart, how often byte 0,
@   byte 1 and byte 2 change (with a steady input the upper bytes may never change: the types testing them then say
@   nothing, which the result shows).
@ Results: page Ld STATUS 56 .. 120 (ble/bft.s, diagnostic build only; 56 = 0x4844 "HD" marks this build).
@ Timer: TIM7 (unused by the firmware: only the generic timer routine and a fault-safe vector name it), free running,
@ PSC 15 at MSI 4.194304 MHz = 262144 counts a second (3.815 us), wrap after 250 ms, no interrupt.  RCC_APB1ENR TIM7EN =
@ bit 5 (RM0038 6.3.10, rm0038.txt:8264); TIM6/TIM7 registers CR1 0x00, EGR 0x14, CNT 0x24, PSC 0x28, ARR 0x2C (RM0038
@ Table 88), as the TIM_* offsets of hw.inc.  STOP switches its clock off (brd/stop.s fn_0801C9AE: APB1ENR = PWR only),
@ so after a wake the timing is not valid until 0xA5 (or 0xA7) starts TIM7 again; every wait here is also bounded by
@ a loop count for that case.
@ Bus: hyd_wbits / hyd_rbits / hyd_clk_extra clock single bits with the waveform of hy3131_spi_write_byte and
@ hy3131_spi_read_byte (hy/spi.s: DI set 3 instructions before the rising edge, CK high at least 6 instructions, DI
@ changed only while CK is low, the extra read clock with DI low, DI left high); DI stays high during data clocks, so a
@ misaligned command would still be a read.  tools/check_hy.py --switch HY_DIAG=1 admits these three as bus routines.
@ No EEPROM access, no NVM call: calibration, serial and options are untouched.
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

.if HY_DIAG

    .equ HYD_TIM,           TIM7_BASE
    .equ HYD_APB1_TIM7,     0x00000020      @ RCC_APB1ENR bit 5 TIM7EN (rm0038.txt:8264)
    .equ HYD_PSC,           15              @ 4 194 304 / 16 = 262 144 counts a second
    @ BEEP result period measured on the owner's meter 2026-11-10 (Q3): 966 periods, mean 1024.5 counts (3908 us),
    @ 998 .. 1051 counts (3807 .. 4009 us).  The first form assumed 640/s (410 counts) and so never paused across a
    @ new result (Q1 "not informative", sensitivity 0 changes).
    .equ HYD_PERIOD,        1024            @ counts in one BEEP result period (measured, above): Q2 histogram unit
    .equ HYD_PAUSE,         1049            @ counts in 4.0 ms (4000 / 3.815 = 1048.6): the pause of the R reads
    .equ HYD_LOCK_TO,       1311            @ counts in 5.0 ms: the longest wait for the next event (period <= 4009 us)
    .equ HYD_AFTER,         1100            @ counts in 4196 us: end of the X pause after t_c (N + 1 at 3807 .. 4009 us)
    .equ HYD_WAIT_LOOPS,    200000          @ bound of one wait loop if TIM7 does not count (about 0.4 s)
    .equ HYD_TRIALS,        600             @ 150 trials of each of the 4 types
    .equ HYD_SAMPLES,       100             @ locked sensitivity pairs before the trials
    .equ HYD_BATCH,         30              @ samples or trials per main-loop pass (a trial is at most 5.0 ms lock +
                                            @ 4.2 ms X + 4.0 ms R pause + reads: at most about 0.4 s held)
    .equ HYD_REC,           20              @ bytes of the result record of one trial type (10 u16)
    .equ HYD_ST_IDLE,       0
    .equ HYD_ST_RUN,        1
    .equ HYD_ST_DONE,       2
    .equ HYD_ST_REFUSED,    3               @ 0xA7 outside BEEP
    .equ HYD_ST_ABORTED,    4               @ BEEP left during the run
    .equ HYD_PIN_CK,        1               @ GPIOF pin masks as hy/spi.s:26-28
    .equ HYD_PIN_CS,        2
    .equ HYD_PIN_DI,        4
    .equ HYD_DO_BIT,        8               @ GPIOF IDR bit 3 = PF3 = DO (hy/spi.s:12-13)
    .equ hyd_delay,         fn_0800ECF6     @ the delay loop hy_read_frame uses (brd/delay.s)

    .section .rodata.hyd, "a", %progbits
    .balign 4
@ bytes each trial type tests: 0 control (all), 1 all three, 2 bytes 1..2, 3 byte 2
hyd_masks:      .word 0x00FFFFFF, 0x00FFFFFF, 0x00FFFF00, 0x00FF0000
    .global hyd_marker
hyd_marker:     .hword 0x4844               @ "HD": page Ld STATUS 56 of the diagnostic build

    .section .bss_port.hyd, "aw", %nobits
    .balign 4
@ Q2 counters (cleared by hyd_start); u32 values are read over STATUS as two halves
    .global hyd_reads, hyd_time, hyd_frame_sum, hyd_lat_sum, hyd_frame_max, hyd_lat_max, hyd_hist, hyd_notmsi
hyd_reads:      .space 4                    @ AD1 reads counted
hyd_time:       .space 4                    @ sum of the times between consecutive counted reads (counts)
hyd_frame_sum:  .space 4                    @ sum of the AD1 frame lengths (counts)
hyd_lat_sum:    .space 4                    @ sum of service start -> AD1 read start (counts)
hyd_frame_max:  .space 2
hyd_lat_max:    .space 2
hyd_hist:       .space 10                   @ 5 u16: time between reads < 1, < 2, < 3, < 4, >= 4 conversion periods
hyd_notmsi:     .space 2                    @ AD1 reads while SYSCLK was not MSI (not timed)
@ the per-sample values the continuity decision sees (BEEP; fn_080078D8 entry): lowest, highest (0.01 ohm), how many
    .global hyd_vmin, hyd_vmax, hyd_vcount
hyd_vmin:       .space 4
hyd_vmax:       .space 4
hyd_vcount:     .space 4
hyd_q2_end:
@ Q1 results: 4 records of 10 u16: +0 n, +2 no lock, +4 not informative, +6 held, +8 live, +10 other, +12 R wrong,
@ +14 paused byte: second half informative, +16 paused byte: half split, +18 longest t_c .. end of B
    .global hyd_res, hyd_sens
hyd_res:        .space 4 * HYD_REC
@ sensitivity: +0 pairs, +2 byte 0 changed, +4 byte 1 changed, +6 byte 2 changed
hyd_sens:       .space 8
hyd_res_end:
    .global hyd_left, hyd_status, hyd_mode, hyd_range
hyd_left:       .space 2                    @ Q1 trials still to run
hyd_samples:    .space 2                    @ sensitivity pairs still to take
hyd_trial:      .space 2                    @ Q1 trial index
hyd_t_intf:     .space 2                    @ TIM7 at the start of the current service
hyd_t_prev:     .space 2                    @ TIM7 at the start of the last counted AD1 read
hyd_t_ad1:      .space 2                    @ TIM7 at the start of the current AD1 read
hyd_on:         .space 1                    @ 1 = Q2 counting
hyd_have_prev:  .space 1                    @ 1 = hyd_t_prev is valid (a gap can be counted)
hyd_ad1_ok:     .space 1                    @ 1 = the current AD1 read was started on MSI (hyd_ad1_end counts it)
hyd_status:     .space 1                    @ HYD_ST_*
hyd_mode:       .space 1                    @ meter_mode when frozen (0xA6) or when Q1 started
hyd_range:      .space 1                    @ meter_range at the same moment

    .section .text.hyd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ hyd_timer_on - TIM7 free running at HYD_PSC (clock enabled, counter restarted)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ -----------------------------------------------------------------------------
LFUNC hyd_timer_on
    push {r4, lr}
    movs r0, #HYD_APB1_TIM7
    movs r1, #1
    bl fn_0801FFBC                          @ RCC_APB1ENR |= TIM7EN (the clock helper, sys/clock.s)
    ldr r4, =HYD_TIM
    movs r0, #0
    strh r0, [r4, #TIM_CR1]                 @ stopped
    movs r0, #HYD_PSC
    strh r0, [r4, #TIM_PSC]
    movw r0, #0xFFFF
    strh r0, [r4, #TIM_ARR]                 @ the full 16 bits
    movs r0, #TIM_EGR_UG
    strh r0, [r4, #TIM_EGR]                 @ load PSC, counter 0
    movs r0, #TIM_CR1_CEN
    strh r0, [r4, #TIM_CR1]                 @ count
    pop {r4, pc}
    .ltorg
ENDFUNC hyd_timer_on

@ -----------------------------------------------------------------------------
@ hyd_now - r0 = TIM7 counter (16 bits)
@ Clobbers : r0, r1
@ -----------------------------------------------------------------------------
LFUNC hyd_now
    ldr r1, =HYD_TIM
    ldrh r0, [r1, #TIM_CNT]
    bx lr
    .ltorg
ENDFUNC hyd_now

@ -----------------------------------------------------------------------------
@ hyd_msi - r0 = 1 when SYSCLK is MSI (RCC_CFGR SWS, RM0038 6.3.3), else 0
@ Clobbers : r0, r1, flags
@ -----------------------------------------------------------------------------
LFUNC hyd_msi
    ldr r1, =RCC_CFGR
    ldr r0, [r1]
    tst r0, #RCC_CFGR_SWS_MASK
    ite eq
    moveq r0, #1
    movne r0, #0
    bx lr
    .ltorg
ENDFUNC hyd_msi

@ -----------------------------------------------------------------------------
@ hyd_inc16 - saturating u16 increment
@ In       : r0 = address
@ Clobbers : r1, flags
@ -----------------------------------------------------------------------------
LFUNC hyd_inc16
    ldrh r1, [r0]
    adds r1, r1, #1
    lsrs r1, r1, #16
    bne 1f                                  @ 0xFFFF stays
    ldrh r1, [r0]
    adds r1, r1, #1
    strh r1, [r0]
1:  bx lr
ENDFUNC hyd_inc16

@ -----------------------------------------------------------------------------
@ hyd_start - key code 0xA5: Q2 counters cleared, TIM7 restarted, counting on
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (ble/commands.s fn_0800C332)
@ -----------------------------------------------------------------------------
FUNC hyd_start
    push {r4, lr}
    bl hyd_timer_on
    ldr r0, =hyd_reads
    ldr r1, =hyd_q2_end
    movs r2, #0
1:  strb r2, [r0], #1
    cmp r0, r1
    blo 1b
    ldr r0, =hyd_have_prev
    strb r2, [r0]
    ldr r0, =hyd_ad1_ok
    strb r2, [r0]
    movs r2, #1
    ldr r0, =hyd_on
    strb r2, [r0]
    pop {r4, pc}
    .ltorg
ENDFUNC hyd_start

@ -----------------------------------------------------------------------------
@ hyd_stop - key code 0xA6: Q2 counting off (the counters keep their values), mode and range noted
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (ble/commands.s fn_0800C332)
@ -----------------------------------------------------------------------------
FUNC hyd_stop
    movs r0, #0
    ldr r1, =hyd_on
    strb r0, [r1]
    b hyd_note_mode
    .ltorg
ENDFUNC hyd_stop

LFUNC hyd_note_mode
    ldr r0, =meter_mode
    ldrb r0, [r0]
    ldr r1, =hyd_mode
    strb r0, [r1]
    ldr r0, =meter_range
    ldrb r0, [r0]
    ldr r1, =hyd_range
    strb r0, [r1]
    bx lr
    .ltorg
ENDFUNC hyd_note_mode

@ -----------------------------------------------------------------------------
@ hyd_mark_intf - start of an HY event service: TIM7 noted (Q2)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (hy3131_service_irq, before the INTF read)
@ -----------------------------------------------------------------------------
FUNC hyd_mark_intf
    ldr r0, =hyd_on
    ldrb r0, [r0]
    cmp r0, #0
    beq 1f
    ldr r1, =HYD_TIM
    ldrh r0, [r1, #TIM_CNT]
    ldr r1, =hyd_t_intf
    strh r0, [r1]
1:  bx lr
    .ltorg
ENDFUNC hyd_mark_intf

@ -----------------------------------------------------------------------------
@ hyd_ad1_begin - just before the AD1 read: service-to-read time, the time since the last read (Q2)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (hy3131_service_irq)
@ -----------------------------------------------------------------------------
FUNC hyd_ad1_begin
    push {r4, r5, r6, lr}
    ldr r5, =hyd_ad1_ok
    movs r0, #0
    strb r0, [r5]                           @ not timed unless started below
    ldr r0, =hyd_on
    ldrb r0, [r0]
    cmp r0, #0
    beq .Lab_out
    bl hyd_msi
    cmp r0, #0
    bne 1f
    ldr r0, =hyd_notmsi
    bl hyd_inc16                            @ a read at 32 MHz: counted apart, not timed
    movs r0, #0
    ldr r1, =hyd_have_prev
    strb r0, [r1]                           @ the next gap would span the card session: not counted
    b .Lab_out
1:  bl hyd_now
    mov r4, r0                              @ r4 = TIM7 at the read start
    ldr r1, =hyd_t_ad1
    strh r4, [r1]
    movs r0, #1
    strb r0, [r5]
    @ service start -> AD1 read start
    ldr r1, =hyd_t_intf
    ldrh r1, [r1]
    sub r0, r4, r1
    uxth r0, r0
    ldr r1, =hyd_lat_sum
    ldr r2, [r1]
    add r2, r2, r0
    str r2, [r1]
    ldr r1, =hyd_lat_max
    ldrh r2, [r1]
    cmp r0, r2
    it hi
    strhhi r0, [r1]
    @ time since the last counted read: sum and histogram in conversion periods
    ldr r6, =hyd_have_prev
    ldrb r0, [r6]
    cmp r0, #0
    beq 2f
    ldr r1, =hyd_t_prev
    ldrh r1, [r1]
    sub r0, r4, r1
    uxth r0, r0                             @ r0 = gap (a gap longer than the 250 ms wrap is not expected: the longest
    ldr r1, =hyd_time                       @ main-loop pass in analysis/autorange_and_scheduler.md:518 is 20.2 ms)
    ldr r2, [r1]
    add r2, r2, r0
    str r2, [r1]
    movw r1, #HYD_PERIOD
    udiv r0, r0, r1                         @ whole periods
    cmp r0, #4
    it hi
    movhi r0, #4                            @ bin 4: 4 periods or more
    ldr r1, =hyd_hist
    add r0, r1, r0, lsl #1
    bl hyd_inc16
2:  ldr r1, =hyd_t_prev
    strh r4, [r1]
    movs r0, #1
    strb r0, [r6]
.Lab_out:
    pop {r4, r5, r6, pc}
    .ltorg
ENDFUNC hyd_ad1_begin

@ -----------------------------------------------------------------------------
@ hyd_ad1_end - just after the AD1 read: frame length, reads counted (Q2)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (hy3131_service_irq)
@ -----------------------------------------------------------------------------
FUNC hyd_ad1_end
    ldr r0, =hyd_ad1_ok
    ldrb r0, [r0]
    cmp r0, #0
    beq 1f
    ldr r1, =HYD_TIM
    ldrh r0, [r1, #TIM_CNT]
    ldr r1, =hyd_t_ad1
    ldrh r1, [r1]
    sub r0, r0, r1
    uxth r0, r0                             @ r0 = frame length
    ldr r1, =hyd_frame_sum
    ldr r2, [r1]
    add r2, r2, r0
    str r2, [r1]
    ldr r1, =hyd_frame_max
    ldrh r2, [r1]
    cmp r0, r2
    it hi
    strhhi r0, [r1]
    ldr r1, =hyd_reads
    ldr r2, [r1]
    adds r2, r2, #1
    str r2, [r1]
1:  bx lr
    .ltorg
ENDFUNC hyd_ad1_end

@ -----------------------------------------------------------------------------
@ hyd_v_note - one per-sample value of the continuity decision: lowest, highest, count (while 0xA5 counting is on)
@ In       : r0 = per-sample value (0.01 ohm, as fn_080078D8 compares it)
@ Out      : r0 unchanged
@ Clobbers : r1-r3, r12, flags (r0 kept)
@ Context  : main only (fn_080078D8 entry)
@ -----------------------------------------------------------------------------
FUNC hyd_v_note
    push {r0, r4, r5, lr}
    ldr r1, =hyd_on
    ldrb r1, [r1]
    cmp r1, #0
    beq 3f
    ldr r1, =hyd_vcount
    ldr r2, [r1]
    adds r3, r2, #1
    str r3, [r1]
    ldr r4, =hyd_vmin
    ldr r5, =hyd_vmax
    cmp r2, #0
    bne 1f
    str r0, [r4]                            @ the first value: lowest and highest
    str r0, [r5]
    b 3f
1:  ldr r1, [r4]
    cmp r0, r1
    it lo
    strlo r0, [r4]                          @ lower (compared unsigned, as the decision compares)
    ldr r1, [r5]
    cmp r0, r1
    it hi
    strhi r0, [r5]                          @ higher
3:  pop {r0, r4, r5, pc}
    .ltorg
ENDFUNC hyd_v_note

@ -----------------------------------------------------------------------------
@ hyd_request - key code 0xA7: start the latch experiment (BEEP only)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (ble/commands.s fn_0800C332)
@ -----------------------------------------------------------------------------
FUNC hyd_request
    push {r4, lr}
    bl hyd_note_mode
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #10
    beq 1f
    movs r0, #HYD_ST_REFUSED                @ the timing assumes the measured BEEP result period
    ldr r1, =hyd_status
    strb r0, [r1]
    pop {r4, pc}
1:  bl hyd_timer_on                         @ (a Q2 count that runs on loses only its next gap)
    movs r0, #0
    ldr r1, =hyd_have_prev
    strb r0, [r1]
    ldr r1, =hyd_res
    ldr r2, =hyd_res_end
2:  strb r0, [r1], #1
    cmp r1, r2
    blo 2b
    ldr r1, =hyd_trial
    strh r0, [r1]
    movw r0, #HYD_TRIALS
    ldr r1, =hyd_left
    strh r0, [r1]
    movs r0, #HYD_SAMPLES
    ldr r1, =hyd_samples
    strh r0, [r1]
    movs r0, #HYD_ST_RUN
    ldr r1, =hyd_status
    strb r0, [r1]
    pop {r4, pc}
    .ltorg
ENDFUNC hyd_request

@ -----------------------------------------------------------------------------
@ hyd_step - one batch of the latch experiment while it runs (the sensitivity pairs first, then the trials)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (hy3131_poll, every main-loop pass)
@ -----------------------------------------------------------------------------
FUNC hyd_step
    push {r4, lr}
    bl hyd_q3_step                          @ Q3, the event period, while it runs (key code 0xA9)
    ldr r0, =hyd_status
    ldrb r0, [r0]
    cmp r0, #HYD_ST_RUN
    bne .Lst_out
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #10
    beq 1f
    movs r0, #HYD_ST_ABORTED                @ BEEP left: the BEEP timing no longer holds
    ldr r1, =hyd_status
    strb r0, [r1]
    b .Lst_out
1:  movs r4, #HYD_BATCH
2:  ldr r1, =hyd_samples
    ldrh r0, [r1]
    cmp r0, #0
    beq 3f
    subs r0, r0, #1
    strh r0, [r1]
    bl hyd_sample
    b 4f
3:  ldr r1, =hyd_left
    ldrh r0, [r1]
    cmp r0, #0
    beq .Lst_done
    subs r0, r0, #1
    strh r0, [r1]
    ldr r1, =hyd_trial
    ldrh r0, [r1]
    adds r2, r0, #1
    strh r2, [r1]
    and r0, r0, #3                          @ trial type
    bl hyd_trial_run
4:  subs r4, r4, #1
    bne 2b
    b .Lst_out
.Lst_done:
    movs r0, #HYD_ST_DONE
    ldr r1, =hyd_status
    strb r0, [r1]
.Lst_out:
    pop {r4, pc}
    .ltorg
ENDFUNC hyd_step

@ -----------------------------------------------------------------------------
@ hyd_lock - wait for the next HY event: INTF read (cleared), then DO high with CS high (datasheet 7.2 (4))
@ Out      : r0 = TIM7 at the event (t_c), or -1 when none came within HYD_LOCK_TO
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
LFUNC hyd_lock
    push {r4, r5, r6, r7, lr}
    sub sp, sp, #4
    movs r0, #0x1E
    movs r1, #1
    movs r2, #0
    movs r3, #0
    bl hyd_read                             @ INTF: its read clears the flags (DS 10.2 (7))
    bl hyd_now
    mov r4, r0                              @ r4 = start of the wait
    ldr r5, =HYD_WAIT_LOOPS                 @ r5 = loop bound (TIM7 not counting)
    ldr r6, =(GPIOF_BASE + GPIO_IDR)
    movw r7, #HYD_LOCK_TO
1:  ldrh r0, [r6]
    tst r0, #HYD_DO_BIT
    bne 2f                                  @ DO high: an event
    bl hyd_now
    sub r0, r0, r4
    uxth r0, r0
    cmp r0, r7
    bhs 3f
    subs r5, r5, #1
    bne 1b
3:  mov r0, #-1                             @ no event in time
    b 4f
2:  bl hyd_now
4:  add sp, sp, #4
    pop {r4, r5, r6, r7, pc}
    .ltorg
ENDFUNC hyd_lock

@ -----------------------------------------------------------------------------
@ hyd_sample - one sensitivity pair: locked fast read, a second fast read one result later; changed bytes counted
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
LFUNC hyd_sample
    push {r4, r5, r6, r7, lr}
    sub sp, sp, #4
    bl hyd_lock
    cmp r0, #-1
    beq .Lsa_out                            @ no event: not counted
    mov r7, r0                              @ r7 = t_c
    movs r0, #0
    movs r1, #3
    movs r2, #0
    movs r3, #0
    bl hyd_read
    mov r4, r0                              @ r4 = conversion N
    movw r0, #HYD_AFTER
    add r0, r0, r7
    uxth r0, r0
    bl hyd_wait_until                       @ past conversion N + 1
    movs r0, #0
    movs r1, #3
    movs r2, #0
    movs r3, #0
    bl hyd_read
    eor r5, r4, r0                          @ r5 = bits changed N -> N + 1
    ldr r6, =hyd_sens
    mov r0, r6
    bl hyd_inc16                            @ pairs
    tst r5, #0xFF
    beq 1f
    add r0, r6, #2
    bl hyd_inc16                            @ byte 0 changed
1:  tst r5, #0xFF00
    beq 2f
    add r0, r6, #4
    bl hyd_inc16                            @ byte 1 changed
2:  tst r5, #0xFF0000
    beq .Lsa_out
    add r0, r6, #6
    bl hyd_inc16                            @ byte 2 changed
.Lsa_out:
    add sp, sp, #4
    pop {r4, r5, r6, r7, pc}
    .ltorg
ENDFUNC hyd_sample

@ -----------------------------------------------------------------------------
@ hyd_trial_run - one locked trial: A, X (pause by type), B, R; counted into the record of the type
@ In       : r0 = type 0..3 (0 no pause, 1 inside the address byte, 2 inside data byte 0, 3 inside data byte 1)
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ -----------------------------------------------------------------------------
LFUNC hyd_trial_run
    push {r4-r11, lr}
    sub sp, sp, #4
    mov r11, r0                             @ r11 = type
    ldr r10, =hyd_res
    movs r1, #HYD_REC
    mla r10, r0, r1, r10                    @ r10 = record of the type
    mov r0, r10
    bl hyd_inc16                            @ n
    bl hyd_lock
    cmp r0, #-1
    bne 1f
    add r0, r10, #2
    bl hyd_inc16                            @ no event within the timeout: the trial is skipped
    b .Ltr_out
1:  mov r7, r0                              @ r7 = t_c
    @ A: conversion N
    movs r0, #0
    movs r1, #3
    movs r2, #0
    movs r3, #0
    bl hyd_read
    mov r4, r0
    @ X: the pause ends at t_c + HYD_AFTER (after conversion N + 1); type 0: no pause
    movw r3, #HYD_AFTER
    add r3, r3, r7
    uxth r3, r3
    movs r0, #0
    movs r1, #3
    mov r2, r11
    bl hyd_read
    mov r5, r0
    @ B: right after X
    movs r0, #0
    movs r1, #3
    movs r2, #0
    movs r3, #0
    bl hyd_read
    mov r6, r0
    bl hyd_now
    sub r9, r0, r7
    uxth r9, r9                             @ r9 = t_c .. end of B
    @ R: 0x21..0x23 fast, then with the same pause place (a pause of HYD_PAUSE); they must agree
    movs r0, #0x21
    movs r1, #3
    movs r2, #0
    movs r3, #0
    bl hyd_read
    str r0, [sp]
    bl hyd_now
    movw r3, #HYD_PAUSE
    add r3, r3, r0
    uxth r3, r3
    movs r0, #0x21
    movs r1, #3
    mov r2, r11
    bl hyd_read
    ldr r1, [sp]
    cmp r0, r1
    beq 2f
    add r0, r10, #12
    bl hyd_inc16                            @ R wrong
2:  ldrh r1, [r10, #18]
    cmp r9, r1
    it hi
    strhhi r9, [r10, #18]                   @ longest t_c .. end of B
    @ classification on the bytes the type tests
    ldr r8, =hyd_masks
    ldr r8, [r8, r11, lsl #2]               @ r8 = mask
    eor r0, r4, r6
    tst r0, r8
    bne 3f
    add r0, r10, #4
    bl hyd_inc16                            @ A and B equal on the tested bytes: not informative
    b 6f
3:  eor r0, r5, r4
    tst r0, r8
    bne 4f
    add r0, r10, #6
    bl hyd_inc16                            @ held: X equals A
    b 6f
4:  eor r0, r5, r6
    tst r0, r8
    bne 5f
    add r0, r10, #8
    bl hyd_inc16                            @ live: X equals B
    b 6f
5:  add r0, r10, #10
    bl hyd_inc16                            @ other
6:  @ types 2 and 3: the paused byte (byte 0 / byte 1) per 4-bit half
    cmp r11, #2
    blo .Ltr_out
    ite eq
    moveq r0, #0                            @ type 2: byte 0
    movne r0, #8                            @ type 3: byte 1
    lsr r4, r4, r0                          @ (A, B, X are not needed after this)
    lsr r6, r6, r0
    lsr r5, r5, r0
    eor r0, r4, r6
    tst r0, #0x0F
    beq .Ltr_out                            @ A and B share the second half: nothing to tell
    add r0, r10, #14
    bl hyd_inc16                            @ second half informative
    eor r0, r5, r4
    tst r0, #0xF0
    bne .Ltr_out                            @ first half not A's
    eor r0, r5, r6
    tst r0, #0x0F
    bne .Ltr_out                            @ second half not B's
    add r0, r10, #16
    bl hyd_inc16                            @ half split: first half A, second half B
.Ltr_out:
    add sp, sp, #4
    pop {r4-r11, pc}
    .ltorg
ENDFUNC hyd_trial_run

@ -----------------------------------------------------------------------------
@ hyd_read - read 1..3 consecutive registers with the bus sequence of hy_read_frame, optionally with a pause inside
@ one byte (after its 4th bit)
@ In       : r0 = first register, r1 = count 1..3, r2 = pause place (0 none, 1 the address byte, 2 data byte 0, 3 data
@            byte 1), r3 = TIM7 count at which the pause ends
@ Out      : r0 = the bytes, first register in bits 7..0
@ Clobbers : r0-r3, r12, flags (r4-r8 saved)
@ Note     : the mirror adc_regs is not written (the measurement's own reads keep their values); CS ends high.
@ -----------------------------------------------------------------------------
LFUNC hyd_read
    push {r4, r5, r6, r7, r8, lr}
    mov r5, r1                              @ r5 = count
    mov r6, r2                              @ r6 = pause place
    mov r7, r3                              @ r7 = end of the pause
    movs r8, #0                             @ r8 = result
    lsls r4, r0, #1
    orr r4, r4, #1
    uxtb r4, r4                             @ r4 = address byte: register << 1 | 1 = read
    movs r0, #HYD_PIN_DI
    ldr r1, =(GPIOF_BASE + GPIO_BSRRL)
    strh r0, [r1]                           @ DI high
    movs r0, #HYD_PIN_CK
    ldr r1, =(GPIOF_BASE + GPIO_BSRRH)
    strh r0, [r1]                           @ CK low
    movs r0, #HYD_PIN_CS
    ldr r1, =(GPIOF_BASE + GPIO_BSRRH)
    strh r0, [r1]                           @ CS low: frame starts
    movs r0, #5
    bl hyd_delay
    cmp r6, #1
    bne 1f
    mov r0, r4
    movs r1, #4
    bl hyd_wbits                            @ address bits 7..4
    mov r0, r7
    bl hyd_wait_until                       @ the pause inside the address byte
    lsls r0, r4, #4
    movs r1, #4
    bl hyd_wbits                            @ address bits 3..0
    b 2f
1:  mov r0, r4
    movs r1, #8
    bl hyd_wbits
2:  bl hyd_clk_extra                        @ the blank clock of a read, DI left high
    movs r0, #5
    bl hyd_delay
    movs r4, #0                             @ r4 = byte index
3:  cmp r4, r5
    bhs 6f
    adds r0, r4, #2
    cmp r0, r6
    bne 4f
    movs r0, #4
    bl hyd_rbits
    mov r6, r0                              @ first half (the pause place is used once: r6 now holds bits)
    mov r0, r7
    bl hyd_wait_until                       @ the pause inside this data byte
    movs r0, #4
    bl hyd_rbits
    orr r0, r0, r6, lsl #4
    movs r6, #0                             @ no further pause (byte index + 2 is never 0)
    b 5f
4:  movs r0, #8
    bl hyd_rbits
5:  lsls r1, r4, #3
    lsls r0, r0, r1
    orr r8, r8, r0
    movs r0, #2
    bl hyd_delay
    adds r4, r4, #1
    b 3b
6:  movs r0, #HYD_PIN_CS
    ldr r1, =(GPIOF_BASE + GPIO_BSRRL)
    strh r0, [r1]                           @ CS high: frame ends
    mov r0, r8
    pop {r4, r5, r6, r7, r8, pc}
    .ltorg
ENDFUNC hyd_read

@ -----------------------------------------------------------------------------
@ hyd_wbits - send the top r1 bits of the byte r0, MSB first (waveform of hy3131_spi_write_byte, hy/spi.s:74-121)
@ In       : r0 = bits in 7..(8 - r1), r1 = 1..8
@ Clobbers : r0-r3, flags (r4, r5 saved)
@ -----------------------------------------------------------------------------
FUNC hyd_wbits
    push {r4, r5, r6, lr}
    mov r4, r0
    mov r5, r1
    ldr r2, =(GPIOF_BASE + GPIO_BSRRL)
    ldr r3, =(GPIOF_BASE + GPIO_BSRRH)
1:  movs r0, #HYD_PIN_DI
    tst r4, #0x80
    ite ne
    strhne r0, [r2]                         @ bit set: DI high
    strheq r0, [r3]                         @ bit clear: DI low
    nop                                     @ DI setup: 3 instructions to the rising edge
    movs r0, #HYD_PIN_CK
    strh r0, [r2]                           @ CK high: the chip latches DI
    nop
    nop
    nop
    nop
    nop                                     @ CK high for 6 instructions
    strh r0, [r3]                           @ CK low
    lsls r4, r4, #1
    subs r5, r5, #1
    bne 1b
    pop {r4, r5, r6, pc}
    .ltorg
ENDFUNC hyd_wbits

@ -----------------------------------------------------------------------------
@ hyd_clk_extra - the blank clock of a read header with DI low, then DI high (hy/spi.s:104-120)
@ Clobbers : r0, r2, r3
@ -----------------------------------------------------------------------------
FUNC hyd_clk_extra
    ldr r2, =(GPIOF_BASE + GPIO_BSRRL)
    ldr r3, =(GPIOF_BASE + GPIO_BSRRH)
    movs r0, #HYD_PIN_DI
    strh r0, [r3]                           @ DI low
    nop
    nop
    movs r0, #HYD_PIN_CK
    strh r0, [r2]                           @ CK high
    nop
    nop
    nop
    nop
    nop
    strh r0, [r3]                           @ CK low
    movs r0, #HYD_PIN_DI
    strh r0, [r2]                           @ DI left high (idle level)
    bx lr
    .ltorg
ENDFUNC hyd_clk_extra

@ -----------------------------------------------------------------------------
@ hyd_rbits - read r0 bits MSB first (waveform of hy3131_spi_read_byte, hy/spi.s:136-167: CK high, sample DO, CK low)
@ In       : r0 = 1..8
@ Out      : r0 = the bits, the last one in bit 0
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
FUNC hyd_rbits
    push {r4, r5, r6, lr}
    mov r1, r0                              @ r1 = bits left
    movs r0, #0
    ldr r2, =(GPIOF_BASE + GPIO_BSRRL)
    ldr r3, =(GPIOF_BASE + GPIO_BSRRH)
    ldr r4, =(GPIOF_BASE + GPIO_IDR)
    movs r5, #HYD_PIN_CK
1:  strh r5, [r2]                           @ CK high
    ldrh r6, [r4]                           @ sample GPIOF IDR (DO = bit 3)
    lsls r0, r0, #1
    nop
    lsls r6, r6, #28                        @ bit 3 to the sign flag
    it mi
    addmi r0, r0, #1
    strh r5, [r3]                           @ CK low (CK high for 6 instructions)
    subs r1, r1, #1
    bne 1b
    pop {r4, r5, r6, pc}
    .ltorg
ENDFUNC hyd_rbits

@ -----------------------------------------------------------------------------
@ hyd_wait_until - wait until TIM7 reaches r0 (16-bit, wrap-safe for waits below 125 ms), bounded by HYD_WAIT_LOOPS
@ Clobbers : r1-r3, flags
@ -----------------------------------------------------------------------------
LFUNC hyd_wait_until
    ldr r1, =HYD_TIM
    ldr r3, =HYD_WAIT_LOOPS
1:  ldrh r2, [r1, #TIM_CNT]
    sub r2, r2, r0
    sxth r2, r2
    cmp r2, #0
    bge 2f                                  @ reached
    subs r3, r3, #1
    bne 1b
2:  bx lr
    .ltorg
ENDFUNC hyd_wait_until

@ =============================================================================
@ Q3, event period (key code 0xA9; owner 2026-11-10 "ok"): Q1 on the owner's meter found no byte changing 3.1 ms after
@ an event and many 3.2 ms lock timeouts, which fits an event period longer than the 1.5625 ms of 640/s.  Q3 times the
@ events directly: HYD_Q3_N waits for DO high (each with HYD_Q3_TO), each event's INTF read (clears it, its value ORed
@ into hyd_q3_flags); the time between two events of one batch is counted (min, max, sum, how many below HYD_Q3_FAST).
@ Batches of HYD_BATCH events from hyd_step; the gap between batches is not counted.  Results: STATUS 127 .. 136.
@ =============================================================================
    .equ HYD_Q3_N,          1000            @ events waited for
    .equ HYD_Q3_TO,         26214           @ counts in 100 ms: the longest wait for one event (DCV rows are slow)
    .equ HYD_Q3_SEQ,        30              @ periods kept one by one (an alternation shows there)
    .equ HYD_Q3_FAST,       524             @ counts in 2 ms: periods below it fit 640/s (1562.5 us)
    .equ HYD_Q3_RUN,        1
    .equ HYD_Q3_DONE,       2

    .section .bss_port.hyd3, "aw", %nobits
    .balign 4
    .global hyd_q3_sum, hyd_q3_n, hyd_q3_min, hyd_q3_max, hyd_q3_fast, hyd_q3_to, hyd_q3_flags, hyd_q3_left
    .global hyd_q3_state
hyd_q3_sum:     .space 4                    @ sum of the counted periods (counts)
hyd_q3_n:       .space 2                    @ periods counted
hyd_q3_min:     .space 2
hyd_q3_max:     .space 2
hyd_q3_fast:    .space 2                    @ periods below HYD_Q3_FAST
hyd_q3_to:      .space 2                    @ waits without an event (HYD_Q3_TO)
hyd_q3_flags:   .space 2                    @ OR of the INTF values read at the events
hyd_q3_left:    .space 2                    @ events still to wait for
hyd_q3_notmsi:  .space 2                    @ batches run while SYSCLK was not MSI (their TIM7 counts are not 3.815 us)
hyd_q3_seqn:    .space 2                    @ periods stored in hyd_q3_seq
    .global hyd_q3_seq, hyd_q3_notmsi
hyd_q3_seq:     .space 2 * HYD_Q3_SEQ       @ the first HYD_Q3_SEQ periods counted, in order (29 from the first batch,
                                            @ then the second batch's first: the batch gap is not a period)
hyd_q3_state:   .space 1                    @ 0 idle, HYD_Q3_RUN, HYD_Q3_DONE
hyd_q3_end:

    .section .text.hyd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ hyd_q3_request - key code 0xA9: Q3 cleared and started (any mode; the meter's own HY service pauses during a batch)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0800C332)
@ -----------------------------------------------------------------------------
FUNC hyd_q3_request
    push {r4, lr}
    bl hyd_note_mode                        @ STATUS 74 / 75: the mode and range measured
    bl hyd_timer_on
    movs r0, #0
    ldr r1, =hyd_q3_sum
    ldr r2, =hyd_q3_end
1:  strb r0, [r1], #1
    cmp r1, r2
    blo 1b
    movw r0, #0xFFFF
    ldr r1, =hyd_q3_min
    strh r0, [r1]
    movw r0, #HYD_Q3_N
    ldr r1, =hyd_q3_left
    strh r0, [r1]
    movs r0, #HYD_Q3_RUN
    ldr r1, =hyd_q3_state
    strb r0, [r1]
    pop {r4, pc}
    .ltorg
ENDFUNC hyd_q3_request

@ -----------------------------------------------------------------------------
@ hyd_q3_step - one batch of Q3 while it runs: INTF read (cleared), then up to HYD_BATCH events
@ Clobbers : r0-r3, r12, flags (r4-r8 saved)
@ Context  : main only (hyd_step, every main-loop pass)
@ -----------------------------------------------------------------------------
FUNC hyd_q3_step
    push {r4, r5, r6, r7, r8, lr}
    ldr r0, =hyd_q3_state
    ldrb r0, [r0]
    cmp r0, #HYD_Q3_RUN
    bne .Lq3_out
    bl hyd_msi
    cmp r0, #0
    bne 5f
    ldr r1, =hyd_q3_notmsi                  @ the batch runs anyway; its periods are flagged by this count
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
5:  movs r0, #0x1E
    movs r1, #1
    movs r2, #0
    movs r3, #0
    bl hyd_read                             @ INTF: the flags of events before the batch are cleared
    movs r4, #HYD_BATCH                     @ r4 = events left in this batch
    movs r8, #0                             @ r8 = 1: r7 holds the time of the batch's previous event
.Lq3_event:
    ldr r1, =hyd_q3_left
    ldrh r0, [r1]
    cmp r0, #0
    beq .Lq3_done
    subs r0, r0, #1
    strh r0, [r1]
    bl hyd_now
    mov r5, r0                              @ r5 = start of the wait
    ldr r6, =HYD_WAIT_LOOPS                 @ r6 = loop bound (TIM7 not counting)
1:  ldr r1, =(GPIOF_BASE + GPIO_IDR)
    ldrh r0, [r1]
    tst r0, #HYD_DO_BIT
    bne 2f                                  @ DO high: an event
    bl hyd_now
    sub r0, r0, r5
    uxth r0, r0
    movw r1, #HYD_Q3_TO
    cmp r0, r1
    bhs 3f
    subs r6, r6, #1
    bne 1b
3:  ldr r1, =hyd_q3_to                      @ no event in time: counted, the next period is not
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    movs r8, #0
    b .Lq3_next
2:  bl hyd_now
    mov r5, r0                              @ r5 = time of this event
    movs r0, #0x1E
    movs r1, #1
    movs r2, #0
    movs r3, #0
    bl hyd_read                             @ INTF: which flags the event set (the read clears them, DO goes low)
    ldr r1, =hyd_q3_flags
    ldrh r2, [r1]
    uxtb r0, r0
    orrs r2, r2, r0
    strh r2, [r1]
    cmp r8, #0
    beq 4f                                  @ the first event of the batch: no period yet
    sub r0, r5, r7
    uxth r0, r0                             @ r0 = period (counts, TIM7 wraps at 65536)
    ldr r1, =hyd_q3_seqn
    ldrh r2, [r1]
    cmp r2, #HYD_Q3_SEQ
    bhs 6f                                  @ the first HYD_Q3_SEQ periods are kept one by one
    ldr r3, =hyd_q3_seq
    strh r0, [r3, r2, lsl #1]
    adds r2, r2, #1
    strh r2, [r1]
6:  ldr r1, =hyd_q3_n
    ldrh r2, [r1]
    adds r2, r2, #1
    strh r2, [r1]
    ldr r1, =hyd_q3_sum
    ldr r2, [r1]
    add r2, r2, r0
    str r2, [r1]
    ldr r1, =hyd_q3_min
    ldrh r2, [r1]
    cmp r0, r2
    it lo
    strhlo r0, [r1]
    ldr r1, =hyd_q3_max
    ldrh r2, [r1]
    cmp r0, r2
    it hi
    strhhi r0, [r1]
    movw r2, #HYD_Q3_FAST
    cmp r0, r2
    bhs 4f
    ldr r1, =hyd_q3_fast
    ldrh r2, [r1]
    adds r2, r2, #1
    strh r2, [r1]
4:  mov r7, r5
    movs r8, #1
.Lq3_next:
    subs r4, r4, #1
    bne .Lq3_event
    b .Lq3_out
.Lq3_done:
    movs r0, #HYD_Q3_DONE
    ldr r1, =hyd_q3_state
    strb r0, [r1]
.Lq3_out:
    pop {r4, r5, r6, r7, r8, pc}
    .ltorg
ENDFUNC hyd_q3_step

.endif
