@ =============================================================================
@ minmax.s - FUNC: MIN/MAX/AVG recording
@
@ Port of the v2.05 functions
@   fn_0800E604  record the new reading in the MIN/MAX/AVG registers and select the value to show   (v2.05 FUN_0800E604)
@   fn_0800E758  value to show for the current MIN/MAX state and its overload and sign flags        (v2.05 FUN_0800E758)
@   fn_080158D4  MIN/MAX key: switch on, or step the state                                          (v2.05 FUN_080158D4)
@   fn_08015974  clear the MIN/MAX/AVG registers and switch MIN/MAX on                              (v2.05 FUN_08015974)
@
@ MIN/MAX in v2.05 (analysis/keys_setup.md section 2): minmax_state (0x2000804E) is 0 = off, 1 = maximum, 2 = minimum,
@ 3 = average, 4 = live value with all MIN/MAX/AVG annunciators; the MIN/MAX key goes 0 -> 1 and then 1 -> 2 -> 3 -> 4 -> 1.
@ The registers (file-local aliases of the v2.05 addresses, roles read from the code below):
@   func_mm_max   0x20007D88  maximum so far (s32); +100000 after an overload with a positive sign
@   func_mm_min   0x20007D8C  minimum so far (s32); -100000 after an overload with a negative sign
@   func_mm_mean  0x20007D90  integer part of the running mean (s32)
@   func_mm_rem   0x20007D94  remainder part of the running mean, mean = mm_mean + mm_rem / mm_count (s32)
@   func_mm_count 0x20007D98  number of readings in the mean, at most 1000000 (s32)
@   func_mm_last  0x20007D9C  last recorded reading (s32)
@ Running mean (fn_0800E604): count = count + 1 (capped at 1000000); d = x - mean; rem = rem + d; mean = mean + rem / count;
@ rem = rem - (rem / count) * count (signed divisions, quotient truncated toward zero): the mean is kept as an integer
@ and a remainder, so no sum of readings can overflow.
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


    .equ func_reading,      v_20007D64   @ displayed value in counts (s32)
    .equ func_hold_value,   v_20007D6C   @ value held by the HOLD key (s32), written by KEY at the first HOLD press
    .equ func_mm_max,       v_20007D88   @ maximum so far (s32)
    .equ func_mm_min,       v_20007D8C   @ minimum so far (s32)
    .equ func_mm_mean,      v_20007D90   @ integer part of the running mean (s32)
    .equ func_mm_rem,       v_20007D94   @ remainder part of the running mean (s32)
    .equ func_mm_count,     v_20007D98   @ number of readings in the mean (s32)
    .equ func_mm_last,      v_20007D9C   @ last recorded reading (s32)
    .equ func_range_manual_saved, v_20008044   @ range_manual before MIN/MAX was switched on (u8), written here
    .equ func_neg_flag,     v_20008045   @ sign flag of the displayed overload (u8): 1 = negative
    .equ func_ol_flag,      v_20008046   @ overload flag (u8)

@ -----------------------------------------------------------------------------
@ fn_0800E604 - record the reading in the MIN/MAX/AVG registers
@ Replaces : 0x0800E604 (v2.05 FUN_0800e604)
@ In       : none (state in RAM)
@ Out      : none (replaces the displayed reading by the value to show unless minmax_state is 4)
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : reads minmax_state, hold_active, func_ol_flag, func_neg_flag, func_reading; writes func_mm_*, func_reading, (via fn_0800E758) func_ol_flag, func_neg_flag
@ Spec     : analysis/keys_setup.md section 2 (MIN/MAX)
@ Deviation: none (copy of the v2.05 sequence); production: IMP-14 statistics, IMP-21 time of a new extreme (ui_mmt_mark)
@ -----------------------------------------------------------------------------
FUNC fn_0800E604
    push {r4, lr}                          @ save r4 and the return address
    ldr r0, =minmax_state
    ldrb r0, [r0, #0]                      @ minmax_state
    cmp r0, #0                             @ MIN/MAX off: nothing to do
    beq .Lmmrec_0800E74C
    ldr r0, =hold_active
    ldrb r0, [r0, #0]                      @ hold_active
    cmp r0, #0
    bne .Lmmrec_0800E74C                   @ HOLD on: the registers are frozen
    ldr r0, =func_ol_flag
    ldrb r0, [r0, #0]                      @ overload flag
    cmp r0, #0
    beq .Lmmrec_0800E65E                   @ no overload: record the reading
    ldr r0, =func_neg_flag
    ldrb r0, [r0, #0]                      @ sign flag of the overload
    cmp r0, #0
    beq .Lmmrec_0800E648                   @ positive overload: separate case
    ldr r0, =func_mm_min                   @ IMP-21: the minimum changes to -100000 (not that already): keep the time
    ldr r0, [r0, #0]                       @ (ui/mmtime.s)
    ldr r1, =0xFFFE7960
    cmp r0, r1
    beq 1f
    movs r0, #1
    bl ui_mmt_mark
1:
    ldr r0, =0xFFFE7960                    @ negative overload: r0 = -100000 ...
    ldr r1, =func_mm_min                   @ ... minimum = -100000 ...
    str r0, [r1, #0]                       @ func_mm_min = r0
    ldr r0, =0xFFFE7960                    @ ... last reading = -100000 ...
    ldr r1, =func_mm_last
    str r0, [r1, #0]                       @ func_mm_last = r0
    b .Lmmrec_0800E738                     @ ... and show the value
    @ Positive overload: maximum = last reading = +100000.
.Lmmrec_0800E648:
    ldr r0, =func_mm_max                   @ IMP-21: the maximum changes to 100000 (not that already): keep the time
    ldr r0, [r0, #0]                       @ (ui/mmtime.s)
    ldr r1, =0x000186A0
    cmp r0, r1
    beq 1f
    movs r0, #0
    bl ui_mmt_mark
1:
    ldr r0, =0x000186A0                    @ r0 = 100000 ...
    ldr r1, =func_mm_max                   @ ... maximum = 100000 ...
    str r0, [r1, #0]                       @ func_mm_max = r0
    ldr r0, =0x000186A0                    @ ... last reading = 100000 ...
    ldr r1, =func_mm_last
    str r0, [r1, #0]                       @ func_mm_last = r0
    b .Lmmrec_0800E738                     @ ... and show the value
    @ Record the reading.
.Lmmrec_0800E65E:
    ldr r0, =func_reading
    ldr r0, [r0, #0]                       @ r4 = reading
    movs r4, r0
    mov r0, r4
    bl func_stats_add                      @ IMP-14: the same reading into the statistics (r4 preserved)
    ldr r0, =func_reading
    ldr r0, [r0, #0]                       @ reading
    ldr r1, =func_mm_last
    str r0, [r1, #0]                       @ last reading = reading
    ldr r0, =func_mm_max
    ldr r0, [r0, #0]                       @ maximum
    cmp r0, r4                             @ maximum below the reading?
    bge .Lmmrec_0800E682                   @ no: keep it
    ldr r0, =func_mm_max
    str r4, [r0, #0]                       @ maximum = reading
    movs r0, #0
    bl ui_mmt_mark                         @ IMP-21: the time of the new maximum (r4 preserved)
    @ Minimum.
.Lmmrec_0800E682:
    ldr r0, =func_mm_min
    ldr r0, [r0, #0]                       @ minimum
    cmp r4, r0                             @ reading below the minimum?
    bge .Lmmrec_0800E692                   @ no: keep it
    ldr r0, =func_mm_min
    str r4, [r0, #0]                       @ minimum = reading
    movs r0, #1
    bl ui_mmt_mark                         @ IMP-21: the time of the new minimum (r4 preserved)
    @ Running mean.
.Lmmrec_0800E692:
    ldr r0, =func_mm_count
    ldr r0, [r0, #0]                       @ count
    cmp r0, #0                             @ first reading?
    bne .Lmmrec_0800E6B4                   @ no: update the mean
    movs r0, #1                            @ first reading: count = 1 ...
    ldr r1, =func_mm_count
    str r0, [r1, #0]                       @ func_mm_count = r0
    ldr r0, =func_mm_mean
    str r4, [r0, #0]                       @ ... mean = reading ...
    movs r0, #0                            @ ... remainder = 0 ...
    ldr r1, =func_mm_rem
    str r0, [r1, #0]                       @ func_mm_rem = r0
    b .Lmmrec_0800E738                     @ ... and show the value
    @ Update the mean with the reading in r4.
.Lmmrec_0800E6B4:
    ldr r0, =func_mm_count
    ldr r0, [r0, #0]                       @ count
    adds r0, r0, #1                        @ count + 1
    ldr r1, =func_mm_count
    str r0, [r1, #0]                       @ store
    ldr r0, =func_mm_count
    ldr r0, [r0, #0]                       @ count
    ldr r1, =0x000F4241                    @ r1 = 1000001
    cmp r0, r1                             @ count < 1000001?
    blt .Lmmrec_0800E6DA                   @ yes: keep it
    ldr r0, =0x000F4240                    @ no: count = 1000000 ...
    ldr r1, =func_mm_count
    str r0, [r1, #0]                       @ func_mm_count = r0
    @ d = reading - mean; remainder += d; mean += remainder / count; remainder = remainder mod count.
.Lmmrec_0800E6DA:
    ldr r0, =func_mm_mean
    ldr r0, [r0, #0]                       @ mean
    subs r4, r4, r0                        @ r4 = d = reading - mean
    ldr r0, =func_mm_rem
    ldr r0, [r0, #0]                       @ remainder
    adds r0, r4, r0                        @ remainder + d
    ldr r1, =func_mm_rem
    str r0, [r1, #0]                       @ store the remainder
    ldr r0, =func_mm_rem
    ldr r0, [r0, #0]                       @ remainder
    ldr r1, =func_mm_count
    ldr r1, [r1, #0]                       @ count
    sdiv r0, r0, r1                        @ r0 = remainder / count (signed)
    movs r4, r0                            @ r4 = quotient
    ldr r0, =func_mm_mean
    ldr r0, [r0, #0]                       @ mean
    adds r0, r4, r0                        @ mean + quotient
    ldr r1, =func_mm_mean
    str r0, [r1, #0]                       @ store the mean
    ldr r0, =func_mm_rem
    ldr r0, [r0, #0]                       @ remainder
    ldr r1, =func_mm_rem
    ldr r1, [r1, #0]                       @ remainder again
    ldr r2, =func_mm_count
    ldr r2, [r2, #0]                       @ count
    sdiv r1, r1, r2                        @ r1 = remainder / count
    ldr r2, =func_mm_count
    ldr r2, [r2, #0]                       @ count
    mls r0, r2, r1, r0                     @ r0 = remainder - count * (remainder / count)
    movs r4, r0                            @ r4 = new remainder
    ldr r0, =func_mm_rem
    str r4, [r0, #0]                       @ store the remainder
    @ Show the value selected by minmax_state.
.Lmmrec_0800E738:
    movs r0, #0                            @ argument 0
    bl fn_0800E758                         @ r0 = value to show (sets the overload and sign flags)
    movs r4, r0                            @ r4 = value
    ldr r0, =minmax_state
    ldrb r0, [r0, #0]                      @ minmax_state
    cmp r0, #4                             @ state 4 (all annunciators) shows the live reading
    bge .Lmmrec_0800E74C                   @ state 4: leave the reading alone
    ldr r0, =func_reading
    str r4, [r0, #0]                       @ reading = value to show
    @ Return.
.Lmmrec_0800E74C:
    pop {r4, pc}
ENDFUNC fn_0800E604
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800E758 - value to show for the MIN/MAX state, with its overload and sign flags
@ Replaces : 0x0800E758 (v2.05 FUN_0800e758)
@ In       : r0 = 0 normally; 1 from the display refresh (fn_08015934), which makes state 4 return the value held by HOLD
@ Out      : r0 = value to show: state 1 the maximum, state 2 the minimum, state 3 the integer part of the mean, state 4 the
@            HOLD value (only when r0 = 1 at entry); otherwise the argument; the overload flag is set when the value is at
@            least 100000 or below -99999 (state 3: cleared once a reading is in the mean), the sign flag follows
@ Clobbers : r0-r3, flags
@ Context  : main
@ RAM      : reads minmax_state, func_mm_max, func_mm_min, func_mm_mean, func_mm_count, func_hold_value; writes func_ol_flag, func_neg_flag
@ Spec     : analysis/keys_setup.md section 2 (MIN/MAX); analysis/hy3131_modes_misc.md section 2 (display limits)
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0800E758
    movs r1, r0                            @ r1 = argument
    ldr r2, =minmax_state                  @ r2 = minmax_state
    ldrb r2, [r2, #0]                      @ r2 = minmax_state
    cmp r2, #1                             @ state 1 (maximum)
    beq .Lmmsel_0800E770
    bcc .Lmmsel_0800E836                   @ state 0: nothing to select
    cmp r2, #3                             @ state 3 (average)
    beq .Lmmsel_0800E7D4
    bcc .Lmmsel_0800E7A2                   @ state 2 (minimum)
    cmp r2, #4                             @ state 4
    beq .Lmmsel_0800E7F0
    b .Lmmsel_0800E836                     @ any other state: nothing to select
    @ State 1: maximum.
.Lmmsel_0800E770:
    ldr r2, =func_mm_max                   @ r2 = address of the maximum
    ldr r2, [r2, #0]                       @ maximum
    movs r0, r2                            @ r0 = maximum
    ldr r2, =0x000186A0                    @ r2 = 100000
    cmp r0, r2                             @ maximum below 100000?
    blt .Lmmsel_0800E790                   @ yes: clear the overload
    movs r2, #0                            @ maximum at least 100000: sign flag = 0 ...
    ldr r3, =func_neg_flag
    strb r2, [r3, #0]                      @ func_neg_flag = r2
    movs r2, #1
    ldr r3, =func_ol_flag                  @ ... overload flag = 1
    strb r2, [r3, #0]                      @ func_ol_flag = r2
    b .Lmmsel_0800E7A0                     @ return
    @ Maximum below 100000.
.Lmmsel_0800E790:
    ldr r2, =0x000186A0                    @ r2 = 100000
    cmp r0, r2                             @ maximum at least 100000?
    bge .Lmmsel_0800E7A0
    movs r2, #0                            @ overload flag = 0
    ldr r3, =func_ol_flag
    strb r2, [r3, #0]                      @ func_ol_flag = r2
    @ State 1 done.
.Lmmsel_0800E7A0:
    b .Lmmsel_0800E836
    @ State 2: minimum.
.Lmmsel_0800E7A2:
    ldr r2, =func_mm_min                   @ r2 = address of the minimum
    ldr r2, [r2, #0]                       @ minimum
    movs r0, r2                            @ r0 = minimum
    ldr r2, =0xFFFE7961                    @ r2 = -99999
    cmp r0, r2                             @ minimum at least -99999?
    bge .Lmmsel_0800E7C2                   @ yes: test the upper limit
    movs r2, #1                            @ minimum below -99999: sign flag = 1 ...
    ldr r3, =func_neg_flag
    strb r2, [r3, #0]                      @ func_neg_flag = r2
    movs r2, #1
    ldr r3, =func_ol_flag                  @ ... overload flag = 1
    strb r2, [r3, #0]                      @ func_ol_flag = r2
    b .Lmmsel_0800E7D2                     @ return
    @ Minimum at least -99999.
.Lmmsel_0800E7C2:
    ldr r2, =0x000186A0                    @ r2 = 100000
    cmp r0, r2                             @ minimum below 100000?
    bge .Lmmsel_0800E7D2                   @ no: leave the flags
    movs r2, #0                            @ yes: overload flag = 0
    ldr r3, =func_ol_flag
    strb r2, [r3, #0]                      @ func_ol_flag = r2
    @ State 2 done.
.Lmmsel_0800E7D2:
    b .Lmmsel_0800E836
    @ State 3: average.
.Lmmsel_0800E7D4:
    ldr r2, =func_mm_mean                  @ r2 = address of the mean
    ldr r2, [r2, #0]                       @ mean
    movs r0, r2                            @ r0 = mean
    ldr r2, =func_mm_count                 @ r2 = address of the count
    ldr r2, [r2, #0]                       @ count
    cmp r2, #0                             @ count = 0?
    beq .Lmmsel_0800E7EE                   @ yes: leave the flags
    movs r2, #0                            @ a reading is in the mean: overload flag = 0
    ldr r3, =func_ol_flag
    strb r2, [r3, #0]                      @ func_ol_flag = r2
    @ State 3 done.
.Lmmsel_0800E7EE:
    b .Lmmsel_0800E836
    @ State 4: the HOLD value, only for the display refresh.
.Lmmsel_0800E7F0:
    uxtb r1, r1                            @ r1 = argument as a byte
    cmp r1, #0                             @ argument 0?
    beq .Lmmsel_0800E836                   @ yes: nothing to select
    ldr r2, =func_hold_value               @ r2 = address of the HOLD value
    ldr r2, [r2, #0]                       @ HOLD value
    movs r0, r2                            @ r0 = HOLD value
    ldr r2, =0xFFFE7961                    @ r2 = -99999
    cmp r0, r2                             @ value at least -99999?
    bge .Lmmsel_0800E816                   @ yes: test the upper limit
    movs r2, #1                            @ value below -99999: sign flag = 1 ...
    ldr r3, =func_neg_flag
    strb r2, [r3, #0]                      @ func_neg_flag = r2
    movs r2, #1
    ldr r3, =func_ol_flag                  @ ... overload flag = 1
    strb r2, [r3, #0]                      @ func_ol_flag = r2
    b .Lmmsel_0800E836                     @ return
    @ HOLD value at least -99999.
.Lmmsel_0800E816:
    ldr r2, =0x000186A0                    @ r2 = 100000
    cmp r0, r2                             @ value below 100000?
    blt .Lmmsel_0800E82E                   @ yes: no overload
    movs r2, #0                            @ at least 100000: sign flag = 0 ...
    ldr r3, =func_neg_flag
    strb r2, [r3, #0]                      @ func_neg_flag = r2
    movs r2, #1
    ldr r3, =func_ol_flag                  @ ... overload flag = 1
    strb r2, [r3, #0]                      @ func_ol_flag = r2
    b .Lmmsel_0800E836                     @ return
    @ No overload.
.Lmmsel_0800E82E:
    movs r2, #0                            @ overload flag = 0
    ldr r3, =func_ol_flag
    strb r2, [r3, #0]                      @ func_ol_flag = r2
    @ Return.
.Lmmsel_0800E836:
    bx lr
ENDFUNC fn_0800E758
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080158D4 - MIN/MAX key action
@ Replaces : 0x080158D4 (v2.05 FUN_080158d4, called from the short-press branch of the MIN/MAX key, 0x0801539C)
@ In       : none
@ Out      : none (MIN/MAX state 0 -> 1 with cleared registers and a forced manual range; otherwise state + 1, 5 wraps to 1)
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : reads/writes minmax_state, range_manual, func_range_manual_saved (and the func_mm_* registers through fn_08015974)
@ Spec     : analysis/keys_setup.md section 2 (MIN/MAX)
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_080158D4
    push {r7, lr}                          @ save r7 (stack alignment) and the return address
    ldr r0, =minmax_state
    ldrb r0, [r0, #0]                      @ minmax_state
    cmp r0, #0                             @ MIN/MAX already on: step the state
    bne .Lmmkey_080158FA
    bl fn_08015974                         @ first press: clear the registers and set the state to 1
    ldr r0, =range_manual                  @ range_manual ...
    ldrb r0, [r0, #0]                      @ r0 = range_manual
    ldr r1, =func_range_manual_saved       @ ... saved for the moment MIN/MAX is left
    strb r0, [r1, #0]                      @ func_range_manual_saved = r0
    movs r0, #1                            @ range_manual = 1 ...
    ldr r1, =range_manual
    strb r0, [r1, #0]                      @ range_manual = r0
    movs r0, #0                            @ ... (the range is frozen while MIN/MAX is on)
    bl fn_08019D68                         @ update the AUTO annunciator (LCD fn_08019D68(0))
    b .Lmmkey_0801591A                     @ continue with the display refresh
    @ State + 1, 5 wraps to 1.
.Lmmkey_080158FA:
    ldr r0, =minmax_state                  @ state
    ldrb r0, [r0, #0]                      @ r0 = minmax_state
    adds r0, r0, #1                        @ state + 1
    ldr r1, =minmax_state
    strb r0, [r1, #0]                      @ store
    ldr r0, =minmax_state
    ldrb r0, [r0, #0]                      @ state
    cmp r0, #5                             @ state 5?
    blt .Lmmkey_0801591A                   @ no: done
    movs r0, #1                            @ state = 1
    ldr r1, =minmax_state
    strb r0, [r1, #0]                      @ minmax_state = r0
    @ Refresh the display.
.Lmmkey_0801591A:
    bl fn_08015934                         @ redraw the value (fn_08015934, UI)
    movs r0, #0                            @ update the APO annunciator (LCD fn_08019C5C(0))
    bl fn_08019C5C
    movs r0, #1                            @ update the AVG/MAX/MIN annunciators (LCD fn_08019E24(1))
    bl fn_08019E24
    pop {r0, pc}                           @ return
ENDFUNC fn_080158D4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015974 - clear the MIN/MAX/AVG registers and switch MIN/MAX on
@ Replaces : 0x08015974 (v2.05 FUN_08015974)
@ In       : none
@ Out      : none
@ Clobbers : r0, r1 (production: r0-r3, r12, through func_stats_clear and the page switch)
@ Context  : main
@ RAM      : writes minmax_state, func_mm_max, func_mm_min, func_mm_mean, func_mm_count, func_mm_rem; production: the
@            statistics (IMP-14), set_item 32 (unless 100), set_edit, sub display redraw
@ Spec     : analysis/keys_setup.md section 2 (MIN/MAX)
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_08015974
    movs r0, #1                            @ r0 = 1
    ldr r1, =minmax_state
    strb r0, [r1, #0]                      @ minmax_state = 1
    movs r0, #0x80000000                   @ r0 = 0x80000000, the smallest s32
    ldr r1, =func_mm_max
    str r0, [r1, #0]                       @ maximum = the smallest s32
    mvns r0, #0x80000000                   @ r0 = 0x7FFFFFFF, the largest s32
    ldr r1, =func_mm_min
    str r0, [r1, #0]                       @ minimum = the largest s32
    movs r0, #0                            @ r0 = 0
    ldr r1, =func_mm_mean
    str r0, [r1, #0]                       @ mean = 0
    movs r0, #0                            @ r0 = 0
    ldr r1, =func_mm_count
    str r0, [r1, #0]                       @ count = 0
    movs r0, #0                            @ r0 = 0
    ldr r1, =func_mm_rem
    str r0, [r1, #0]                       @ remainder = 0
    @ IMP-14: empty the statistics and show their page n (item 32), unless the MEM view / logging page (100) is shown
    push {r4, lr}
    bl func_stats_clear
    ldr r1, =v_20008037
    ldrb r0, [r1]
    cmp r0, #100
    beq 1f
    movs r0, #32
    strb r0, [r1]                          @ set_item = 32
    movs r0, #0
    ldr r1, =v_2000806E
    strb r0, [r1]                          @ an edit of the page left is ended, as SETUP short does (0x08015422)
    movs r0, #1
    ldr r1, =v_20008062
    strb r0, [r1]                          @ sub display redraw
1:  pop {r4, pc}
ENDFUNC fn_08015974
    .ltorg

