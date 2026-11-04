@ =============================================================================
@ smooth.s - FUNC: smoothing filters (moving average, thresholded mean, mean of three)
@
@ Port of the v2.05 value smoothing helpers
@   fn_08008344  moving average of up to N values with a restart threshold      (v2.05 FUN_08008344)
@   fn_0800B754  thresholded mean of up to N values                              (v2.05 FUN_0800B754)
@   fn_0800B888  running mean of three values                                    (v2.05 FUN_0800B888)
@ and the OF-28 fix: func_smooth_avg and func_smooth_hist run the same two algorithms on a caller-owned state block,
@ so that two quantities no longer share one history (ORIGINAL_FIRMWARE_ISSUES.md OF-28, DESIGN.md 6.6 and C.2).
@
@ Algorithms (read from the v2.05 code):
@   fn_08008344(D, T, N):  diff = D - last; if |diff| > T the history is emptied; with an empty history the history
@       is {D}, last = D and D is returned; otherwise count = min(count + 1, N), the history is shifted by one place,
@       history[0] = D, last = (sum of the history entries as a 64-bit number) / count (signed 64-bit division by
@       fn_08013FE4, quotient truncated toward zero) and last is returned.
@   fn_0800B754(D, T, N): as above, with one more rule at the entry: T = 0 or N = 0 returns D at once and leaves the
@       state alone.
@   fn_0800B888(D): diff = D - last; the state is restarted when diff >= 11 or diff < -10; first value: last = sum = D;
@       otherwise count = count + 1, when count reaches 4 it becomes 3 and sum = D + (sum - last), else sum = D + sum;
@       last = sum / count (signed 32-bit division); last is returned.
@ The state of fn_0800B888 is 0x20007E70 (last), 0x20007E74 (sum), 0x20007E78 (count): v2.05 has one such state, used
@ by two call sites (0x080066F6 in FUN_0800664A and 0x08008050 in FUN_08007FA8); OF-28 does not list it and it is kept
@ as in v2.05.
@
@ Calling convention (AAPCS, DESIGN.md 6): D in r0, T in r1, N in r2, r3 = state block (func_smooth_* only), result in
@ r0; r0-r3, r12 and the flags are scratch; r4-r11 are preserved.
@ Context: main only (the filters are called from the measurement chains in the main loop).
@ IMP-12 (production image only): with the display level 2 of the SETUP page dSP (func_dsp_level = 1) both cores use a
@ quarter of the depth argument, at least 1 (10 -> 2, 20 -> 5, 5 -> 1, 2 -> 1); the threshold is unchanged, so a jump
@ larger than it still restarts the filter at once.  A depth change at run time needs no state reset: the cores average
@ the newest min(count + 1, N) history entries, and a growing count fills its new slot by the shift of a valid entry.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ func_mean3_last,   v_20007E70   @ last output of fn_0800B888 (s32)
    .equ func_mean3_sum,    v_20007E74   @ running sum of fn_0800B888 (s32)
    .equ func_mean3_count,  v_20007E78   @ number of values in the sum, 0..3 (s32)

@ -----------------------------------------------------------------------------
@ Smoothing state (DESIGN.md 6.6, OF-28)
@
@ v2.05 keeps one smoothing state per algorithm, shared by every caller (OF-28):
@   fn_08008344 (moving average)   last output 0x20007CD8 (s32), count 0x20008084 (u8), history 0x200070A8 (s32[100])
@   fn_0800B754 (thresholded mean) last output 0x20007DF8 (s32), count 0x20008085 (u8), history 0x20007238 (s32[100])
@ The port runs both algorithms through one core each (func_avg_core, func_hist_core) that reaches its state through
@ a descriptor of four words: the address of the last output, the address of the count byte, the address of the history
@ array and the capacity of the history in entries.  There are two kinds of descriptors:
@   - the two fixed descriptors func_desc_avg_v205 and func_desc_hist_v205 point at the v2.05 variables; they serve the
@     v2.05 entries fn_08008344 and fn_0800B754, which therefore behave exactly as in v2.05 for the callers that share
@     the v2.05 state with nobody (capacity 100 = size of the v2.05 arrays);
@   - func_smooth_avg and func_smooth_hist build a descriptor on the stack from a caller-owned state block, so every
@     quantity that passes through the filter gets a history of its own (OF-28).
@
@ State block (FUNC_ST_SIZE = 72 bytes, word aligned, in .bss_port):
@   +0   s32  last output (the filter's previous result)
@   +4   u8   number of valid history entries (0 = the history is empty; the other three bytes are padding)
@   +8   s32  history[FUNC_ST_DEPTH]; entry 0 is the newest value
@ A depth argument larger than the capacity of the state is clamped to the capacity (v2.05 arguments are 2, 5 and 10,
@ so the clamp never acts for them; it only protects the RAM next to a state from a wrong argument).
@
@ The six blocks named in DESIGN.md 6.6 and four more for the AC users of the same quantities are provided; the caller
@ module passes the block of its quantity in r3:
@   func_st_acdc_dc         AC+DC, DC phase value                (v2.05 caller 0x0800772E, fn_0800B754 shape)
@   func_st_acdc_sum        AC+DC, combined value                (v2.05 caller 0x0800A65E, fn_0800B754 shape)
@   func_st_va_volt         VA voltage, DC modes                 (fn_0800B754 shape)
@   func_st_va_curr         VA current, DC modes                 (fn_0800B754 shape)
@   func_st_burden_curr     burden display current, DC modes    (fn_0800B754 shape)
@   func_st_burden_volt     burden display voltage, DC modes    (fn_0800B754 shape)
@   func_st_va_volt_ac      VA voltage, AC modes                 (v2.05 callers of fn_08008344, e.g. 0x08006ABA)
@   func_st_va_curr_ac      VA current, AC modes                 (e.g. 0x080068D2)
@   func_st_burden_curr_ac  burden display current, AC modes     (e.g. 0x080068D2 with the burden display on)
@   func_st_burden_volt_ac  burden display voltage, AC modes     (e.g. 0x08006BB0 in the AC current modes)
@ The two cores keep the same state layout and differ only in the T = 0 / N = 0 early return of the thresholded mean,
@ so a block works with either func_smooth_* routine; one block belongs to one quantity.
@ -----------------------------------------------------------------------------

    .equ FUNC_DESC_LAST,    0               @ descriptor word 0: address of the last output (s32)
    .equ FUNC_DESC_COUNT,   4               @ descriptor word 1: address of the count byte (u8)
    .equ FUNC_DESC_HIST,    8               @ descriptor word 2: address of the history array (s32[])
    .equ FUNC_DESC_CAP,     12              @ descriptor word 3: capacity of the history in entries
    .equ FUNC_DESC_SIZE,    16

    .equ FUNC_ST_LAST,      0               @ state block: last output
    .equ FUNC_ST_COUNT,     4               @ state block: count byte
    .equ FUNC_ST_HIST,      8               @ state block: history array
    .equ FUNC_ST_DEPTH,     16              @ history entries of a state block (the v2.05 depths are 2, 5 and 10)
    .equ FUNC_ST_SIZE,      FUNC_ST_HIST + 4 * FUNC_ST_DEPTH
    .equ FUNC_V205_CAP,     100             @ history entries of the v2.05 arrays (0x190 bytes each)

    .section .bss_port.func, "aw", %nobits
    .balign 4
    .global func_st_acdc_dc, func_st_acdc_sum, func_st_va_volt, func_st_va_curr, func_st_burden_curr, func_st_burden_volt
    .global func_st_va_volt_ac, func_st_va_curr_ac, func_st_burden_curr_ac, func_st_burden_volt_ac
func_st_acdc_dc:         .space FUNC_ST_SIZE    @ AC+DC DC-phase value
func_st_acdc_sum:        .space FUNC_ST_SIZE    @ AC+DC combined value
func_st_va_volt:         .space FUNC_ST_SIZE    @ VA voltage, DC modes
func_st_va_curr:         .space FUNC_ST_SIZE    @ VA current, DC modes
func_st_burden_curr:     .space FUNC_ST_SIZE    @ burden display current, DC modes
func_st_burden_volt:     .space FUNC_ST_SIZE    @ burden voltage, DC modes
func_st_va_volt_ac:      .space FUNC_ST_SIZE    @ VA voltage, AC modes
func_st_va_curr_ac:      .space FUNC_ST_SIZE    @ VA current, AC modes
func_st_burden_curr_ac:  .space FUNC_ST_SIZE    @ burden display current, AC modes
func_st_burden_volt_ac:  .space FUNC_ST_SIZE    @ burden voltage, AC modes

    .section .rodata.func, "a", %progbits
    .balign 4
func_desc_avg_v205:                         @ the v2.05 state of fn_08008344 (0x08008344 pool 0x08008E68, 0x08008B84, 0x08008B88)
    .word v_20007CD8                        @ last output
    .word v_20008084                        @ count byte
    .word v_200070A8                        @ history
    .word FUNC_V205_CAP
func_desc_hist_v205:                        @ the v2.05 state of fn_0800B754 (pool 0x0800C1F4, 0x0800C1F8, 0x0800C1FC)
    .word v_20007DF8                        @ last output
    .word v_20008085                        @ count byte
    .word v_20007238                        @ history
    .word FUNC_V205_CAP

    .section .text.func, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08008344 - moving average with the v2.05 state
@ Replaces : 0x08008344 (v2.05 FUN_08008344)
@ In       : r0 = new value D, r1 = threshold T, r2 = depth N
@ Out      : r0 = smoothed value (also stored as the last output 0x20007CD8)
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : reads/writes 0x20007CD8, 0x20008084, 0x200070A8..
@ Spec     : DESIGN.md 6.6; ORIGINAL_FIRMWARE_ISSUES.md OF-28
@ Deviation: none for the callers that share the v2.05 state (the algorithm is func_avg_core); the callers named in
@            OF-28 call func_smooth_avg with a state block of their own
@ -----------------------------------------------------------------------------
FUNC fn_08008344
    ldr r3, =func_desc_avg_v205             @ r3 = descriptor of the v2.05 state
    b func_avg_core                         @ tail call; returns to the caller of fn_08008344
ENDFUNC fn_08008344
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800B754 - thresholded mean with the v2.05 state
@ Replaces : 0x0800B754 (v2.05 FUN_0800b754)
@ In       : r0 = new value D, r1 = threshold T, r2 = depth N
@ Out      : r0 = smoothed value (D itself when T = 0 or N = 0, without touching the state)
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : reads/writes 0x20007DF8, 0x20008085, 0x20007238..
@ Spec     : DESIGN.md 6.6; ORIGINAL_FIRMWARE_ISSUES.md OF-28
@ Deviation: none for the callers that share the v2.05 state; the callers named in OF-28 call func_smooth_hist with a
@            state block of their own
@ -----------------------------------------------------------------------------
FUNC fn_0800B754
    ldr r3, =func_desc_hist_v205            @ r3 = descriptor of the v2.05 state
    b func_hist_core                        @ tail call; returns to the caller of fn_0800B754
ENDFUNC fn_0800B754
    .ltorg

@ -----------------------------------------------------------------------------
@ func_smooth_avg - moving average on a caller-owned state block (OF-28)
@ Replaces : 0x08008344 for the callers that need a state of their own
@ In       : r0 = new value D, r1 = threshold T, r2 = depth N (at most FUNC_ST_DEPTH), r3 = state block (FUNC_ST_SIZE bytes)
@ Out      : r0 = smoothed value (also stored in the block as the last output)
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : reads/writes the state block only
@ Spec     : DESIGN.md 6.6 and Appendix C.2; OF-28
@ Deviation: OF-28
@ -----------------------------------------------------------------------------
FUNC func_smooth_avg
    push {r3, lr}                           @ r3 is saved only to keep the stack 8-byte aligned
    sub sp, #FUNC_DESC_SIZE                 @ descriptor on the stack
    str r3, [sp, #FUNC_DESC_LAST]           @ last output at state + FUNC_ST_LAST
    adds r12, r3, #FUNC_ST_COUNT            @ address of the count byte
    str r12, [sp, #FUNC_DESC_COUNT]
    adds r12, r3, #FUNC_ST_HIST             @ address of the history array
    str r12, [sp, #FUNC_DESC_HIST]
    movs r12, #FUNC_ST_DEPTH                @ capacity of a state block
    str r12, [sp, #FUNC_DESC_CAP]
    mov r3, sp                              @ r3 = descriptor
    bl func_avg_core
    add sp, #FUNC_DESC_SIZE
    pop {r3, pc}
ENDFUNC func_smooth_avg

@ -----------------------------------------------------------------------------
@ func_smooth_hist - thresholded mean on a caller-owned state block (OF-28)
@ Replaces : 0x0800B754 for the callers that need a state of their own
@ In       : r0 = new value D, r1 = threshold T, r2 = depth N (at most FUNC_ST_DEPTH), r3 = state block (FUNC_ST_SIZE bytes)
@ Out      : r0 = smoothed value (D itself when T = 0 or N = 0, without touching the state)
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : reads/writes the state block only
@ Spec     : DESIGN.md 6.6 and Appendix C.2; OF-28
@ Deviation: OF-28
@ -----------------------------------------------------------------------------
FUNC func_smooth_hist
    push {r3, lr}                           @ r3 is saved only to keep the stack 8-byte aligned
    sub sp, #FUNC_DESC_SIZE                 @ descriptor on the stack
    str r3, [sp, #FUNC_DESC_LAST]           @ last output at state + FUNC_ST_LAST
    adds r12, r3, #FUNC_ST_COUNT            @ address of the count byte
    str r12, [sp, #FUNC_DESC_COUNT]
    adds r12, r3, #FUNC_ST_HIST             @ address of the history array
    str r12, [sp, #FUNC_DESC_HIST]
    movs r12, #FUNC_ST_DEPTH                @ capacity of a state block
    str r12, [sp, #FUNC_DESC_CAP]
    mov r3, sp                              @ r3 = descriptor
    bl func_hist_core
    add sp, #FUNC_DESC_SIZE
    pop {r3, pc}
ENDFUNC func_smooth_hist

@ -----------------------------------------------------------------------------
@ func_avg_core - moving average with a restart threshold, state reached through a descriptor
@ Replaces : 0x08008344 (v2.05 FUN_08008344); the instruction sequence is the v2.05 one with the three state pool
@            loads replaced by loads from the descriptor (r11) and the depth clamp added
@ In       : r0 = new value D, r1 = threshold T, r2 = depth N, r3 = descriptor (FUNC_DESC_*)
@ Out      : r0 = smoothed value
@ Clobbers : r0-r3, r12, flags (r4-r11 saved and restored)
@ Context  : main
@ RAM      : the state named by the descriptor (last output, count byte, history array)
@ Spec     : DESIGN.md 6.6, OF-28
@ Deviation: OF-28 (state through a descriptor); the depth is clamped to the capacity of the state; IMP-12 (production:
@            a quarter of the depth at display level 2)
@ -----------------------------------------------------------------------------
LFUNC func_avg_core
    push {r3-r11, lr}                  @ save r4-r11 and the return address (r3 only keeps the stack 8-byte aligned)
    mov r11, r3                        @ r11 = descriptor of the state
    movs r5, r0                            @ r5 = D
    mov r10, r1                            @ r10 = threshold T
    movs r4, r2                            @ r4 = depth N
    uxth r4, r4                        @ depth as an unsigned halfword (v2.05 compares it as one)
    ldr r0, [r11, #FUNC_DESC_CAP]      @ capacity of the state
    cmp r4, r0
    it hi
    movhi r4, r0                       @ depth above the capacity: use the capacity (never acts for the v2.05 depths 2, 5, 10)
    @ IMP-12: display level 2 (SETUP page dSP) keeps a quarter of the depth, at least 1; a depth of 0 keeps its meaning
    ldr r0, =func_dsp_level
    ldrb r0, [r0]
    cbz r0, 1f                         @ level 1: the depth of the caller, as v2.05
    cbz r4, 1f                         @ depth 0: unchanged
    lsrs r4, r4, #2                    @ depth / 4
    it eq
    moveq r4, #1                       @ at least 1 (depth 1 = the newest value)
1:
    movs r6, #0                            @ r7:r6 = sum = 0 (low word)
    movs r7, #0                            @ sum, high word
    ldr r0, [r11, #FUNC_DESC_LAST]         @ r0 = address of the last output
    ldr r0, [r0, #0]                       @ r0 = last output
    subs r0, r5, r0                        @ r0 = diff = D - last
    mov r8, r0                             @ r8 = diff
    cmp r10, r8                            @ T < diff?
    blt .Lavg_08008366
    cmn r8, r10                            @ diff + T
    bge .Lavg_0800836E                     @ diff >= -T: the value is inside the window, keep the history
    @ |diff| > T: empty the history.
.Lavg_08008366:
    movs r0, #0                            @ r0 = 0
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    strb r0, [r1, #0]                      @ count = 0
    @ History empty?
.Lavg_0800836E:
    ldr r0, [r11, #FUNC_DESC_COUNT]        @ r0 = address of the count byte
    ldrb r0, [r0, #0]                      @ r0 = count
    cmp r0, #0                             @ count = 0?
    bne .Lavg_080083A2                     @ history not empty: shift and average
    ldr r0, [r11, #FUNC_DESC_HIST]         @ r0 = address of the history array
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count (0)
    str r5, [r0, r1, lsl #2]               @ history[count] = D
    ldr r0, [r11, #FUNC_DESC_COUNT]        @ r0 = address of the count byte
    ldrb r0, [r0, #0]                      @ r0 = count
    adds r0, r0, #1                        @ count + 1
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    strb r0, [r1, #0]                      @ count = count + 1 (= 1)
    ldr r0, [r11, #FUNC_DESC_LAST]         @ r0 = address of the last output
    str r5, [r0, #0]                       @ last = D
    ldr r0, [r11, #FUNC_DESC_LAST]         @ r0 = address of the last output
    ldr r0, [r0, #0]                       @ r0 = last (= D), the result
    b .Lavg_0800845C                       @ return
    @ History not empty: count = min(count + 1, N).
.Lavg_080083A2:
    ldr r0, [r11, #FUNC_DESC_COUNT]        @ r0 = address of the count byte
    ldrb r0, [r0, #0]                      @ r0 = count
    adds r0, r0, #1                        @ count + 1
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    strb r0, [r1, #0]                      @ store count + 1
    movs r0, r4                            @ r0 = N
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count
    uxth r0, r0                            @ N as a halfword
    uxth r1, r1                            @ count as a halfword
    cmp r0, r1                             @ N >= count: keep count
    bcs .Lavg_080083C6
    ldr r0, [r11, #FUNC_DESC_COUNT]        @ r0 = address of the count byte
    strb r4, [r0, #0]                      @ count = N (low byte)
    @ Shift the history by one place: i = 1; while i < count: history[count - i] = history[count - 1 - i].
.Lavg_080083C6:
    movs r0, #1                            @ r9 = i = 1
    mov r9, r0
    @ Loop head of the shift: test i < count.
.Lavg_080083CA:
    mov r0, r9                             @ r0 = i
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count
    sxth r0, r0                            @ i as a signed halfword
    sxth r1, r1                            @ count as a signed halfword
    cmp r0, r1                             @ i < count?
    bge .Lavg_0800840E                     @ no: the shift is done
    ldr r0, [r11, #FUNC_DESC_HIST]         @ r0 = address of the history array
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count
    sxth r9, r9                            @ i as a signed halfword
    subs r1, r1, r9                        @ r1 = count - i: destination index
    ldr r2, [r11, #FUNC_DESC_HIST]         @ r2 = address of the history array
    ldr r3, [r11, #FUNC_DESC_COUNT]        @ r3 = address of the count byte
    ldrb r3, [r3, #0]                      @ r3 = count
    subs r3, r3, #1                        @ count - 1
    sxth r9, r9                            @ i as a signed halfword
    subs r3, r3, r9                        @ r3 = count - 1 - i: source index
    ldr r2, [r2, r3, lsl #2]               @ r2 = history[count - 1 - i]
    str r2, [r0, r1, lsl #2]               @ history[count - i] = r2
    adds r9, r9, #1                        @ i + 1
    b .Lavg_080083CA                       @ next i
    @ Store the new value at the front and sum the history.
.Lavg_0800840E:
    ldr r0, [r11, #FUNC_DESC_HIST]         @ r0 = address of the history array
    str r5, [r0, #0]                       @ history[0] = D
    movs r0, #0                            @ r0 = 0
    mov r9, r0                             @ r9 = i = 0
    @ Loop head of the sum: test i < count.
.Lavg_08008418:
    mov r0, r9                             @ r0 = i
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count
    sxth r0, r0                            @ i as a signed halfword
    sxth r1, r1                            @ count as a signed halfword
    cmp r0, r1                             @ i < count?
    bge .Lavg_08008440                     @ no: the sum is complete
    ldr r0, [r11, #FUNC_DESC_HIST]         @ r0 = address of the history array
    sxth r9, r9                            @ i as a signed halfword
    ldr r0, [r0, r9, lsl #2]               @ r0 = history[i]
    asrs r1, r0, #0x1f                     @ r1 = sign extension of r0 (high word)
    adds r6, r6, r0                        @ r7:r6 += r1:r0 (64-bit sum), low word
    adcs r7, r1                            @ high word
    adds r9, r9, #1                        @ i + 1
    b .Lavg_08008418                       @ next i
    @ Divide the sum by the count and store the result.
.Lavg_08008440:
    movs r0, r6                            @ r0 = sum, low word
    movs r1, r7                            @ r1 = sum, high word
    ldr r2, [r11, #FUNC_DESC_COUNT]        @ r2 = address of the count byte
    ldrb r2, [r2, #0]                      @ r2 = count (low word of the divisor)
    movs r3, #0                            @ r3 = 0 (high word of the divisor)
    bl fn_08013FE4                         @ signed 64-bit division: r0 = sum / count
    mov r8, r0                             @ r8 = quotient (low word)
    ldr r0, [r11, #FUNC_DESC_LAST]         @ r0 = address of the last output
    str r8, [r0]                           @ last = quotient
    mov r0, r8                             @ r0 = result
    @ Return.
.Lavg_0800845C:
    pop {r3-r11, pc}                   @ restore r4-r11, return
ENDFUNC func_avg_core

@ -----------------------------------------------------------------------------
@ func_hist_core - thresholded mean of the last N values, state reached through a descriptor
@ Replaces : 0x0800B754 (v2.05 FUN_0800b754); the instruction sequence is the v2.05 one with the three state pool
@            loads replaced by loads from the descriptor (r11) and the depth clamp added
@ In       : r0 = new value D, r1 = threshold T, r2 = depth N, r3 = descriptor (FUNC_DESC_*)
@ Out      : r0 = smoothed value; D itself when T = 0 or N = 0 (the state is not touched)
@ Clobbers : r0-r3, r12, flags (r4-r11 saved and restored)
@ Context  : main
@ RAM      : the state named by the descriptor (last output, count byte, history array)
@ Spec     : DESIGN.md 6.6, OF-28
@ Deviation: OF-28 (state through a descriptor); the depth is clamped to the capacity of the state; IMP-12 (production:
@            a quarter of the depth at display level 2)
@ -----------------------------------------------------------------------------
LFUNC func_hist_core
    push {r3-r11, lr}                  @ save r4-r11 and the return address (r3 only keeps the stack 8-byte aligned)
    mov r11, r3                        @ r11 = descriptor of the state
    movs r5, r0                            @ r5 = D
    mov r10, r1                            @ r10 = threshold T
    movs r4, r2                            @ r4 = depth N
    cmp r10, #0                            @ T = 0?
    beq .Lhist_0800B76A                    @ yes: return D
    uxth r4, r4                            @ N as an unsigned halfword
    cmp r4, #0                             @ N = 0?
    bne .Lhist_0800B76E                    @ no: smooth
    @ T = 0 or N = 0: the result is D itself.
.Lhist_0800B76A:
    movs r0, r5                            @ r0 = D
    b .Lhist_0800B87C                      @ return
    @ Smooth.
.Lhist_0800B76E:
    ldr r0, [r11, #FUNC_DESC_CAP]      @ capacity of the state
    cmp r4, r0
    it hi
    movhi r4, r0                       @ depth above the capacity: use the capacity (never acts for the v2.05 depths 2, 5, 10)
    @ IMP-12: display level 2 (SETUP page dSP) keeps a quarter of the depth, at least 1; a depth of 0 keeps its meaning
    ldr r0, =func_dsp_level
    ldrb r0, [r0]
    cbz r0, 1f                         @ level 1: the depth of the caller, as v2.05
    cbz r4, 1f                         @ depth 0: unchanged
    lsrs r4, r4, #2                    @ depth / 4
    it eq
    moveq r4, #1                       @ at least 1 (depth 1 = the newest value)
1:
    movs r6, #0                            @ r7:r6 = sum = 0 (low word)
    movs r7, #0                            @ sum, high word
    ldr r0, [r11, #FUNC_DESC_LAST]         @ r0 = address of the last output
    ldr r0, [r0, #0]                       @ r0 = last output
    subs r0, r5, r0                        @ r0 = diff = D - last
    mov r8, r0                             @ r8 = diff
    cmp r10, r8                            @ T < diff?
    blt .Lhist_0800B786
    cmn r8, r10                            @ diff + T
    bge .Lhist_0800B78E                    @ diff >= -T: the value is inside the window, keep the history
    @ |diff| > T: empty the history.
.Lhist_0800B786:
    movs r0, #0                            @ r0 = 0
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    strb r0, [r1, #0]                      @ count = 0
    @ History empty?
.Lhist_0800B78E:
    ldr r0, [r11, #FUNC_DESC_COUNT]        @ r0 = address of the count byte
    ldrb r0, [r0, #0]                      @ r0 = count
    cmp r0, #0                             @ count = 0?
    bne .Lhist_0800B7C2                    @ history not empty: shift and average
    ldr r0, [r11, #FUNC_DESC_HIST]         @ r0 = address of the history array
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count (0)
    str r5, [r0, r1, lsl #2]               @ history[count] = D
    ldr r0, [r11, #FUNC_DESC_COUNT]        @ r0 = address of the count byte
    ldrb r0, [r0, #0]                      @ r0 = count
    adds r0, r0, #1                        @ count + 1
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    strb r0, [r1, #0]                      @ count = count + 1 (= 1)
    ldr r0, [r11, #FUNC_DESC_LAST]         @ r0 = address of the last output
    str r5, [r0, #0]                       @ last = D
    ldr r0, [r11, #FUNC_DESC_LAST]         @ r0 = address of the last output
    ldr r0, [r0, #0]                       @ r0 = last (= D), the result
    b .Lhist_0800B87C                      @ return
    @ History not empty: count = min(count + 1, N).
.Lhist_0800B7C2:
    ldr r0, [r11, #FUNC_DESC_COUNT]        @ r0 = address of the count byte
    ldrb r0, [r0, #0]                      @ r0 = count
    adds r0, r0, #1                        @ count + 1
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    strb r0, [r1, #0]                      @ store count + 1
    movs r0, r4                            @ r0 = N
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count
    uxth r0, r0                            @ N as a halfword
    uxth r1, r1                            @ count as a halfword
    cmp r0, r1                             @ N >= count: keep count
    bcs .Lhist_0800B7E6
    ldr r0, [r11, #FUNC_DESC_COUNT]        @ r0 = address of the count byte
    strb r4, [r0, #0]                      @ count = N (low byte)
    @ Shift the history by one place: i = 1; while i < count: history[count - i] = history[count - 1 - i].
.Lhist_0800B7E6:
    movs r0, #1                            @ r9 = i = 1
    mov r9, r0
    @ Loop head of the shift: test i < count.
.Lhist_0800B7EA:
    mov r0, r9                             @ r0 = i
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count
    sxth r0, r0                            @ i as a signed halfword
    sxth r1, r1                            @ count as a signed halfword
    cmp r0, r1                             @ i < count?
    bge .Lhist_0800B82E                    @ no: the shift is done
    ldr r0, [r11, #FUNC_DESC_HIST]         @ r0 = address of the history array
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count
    sxth r9, r9                            @ i as a signed halfword
    subs r1, r1, r9                        @ r1 = count - i: destination index
    ldr r2, [r11, #FUNC_DESC_HIST]         @ r2 = address of the history array
    ldr r3, [r11, #FUNC_DESC_COUNT]        @ r3 = address of the count byte
    ldrb r3, [r3, #0]                      @ r3 = count
    subs r3, r3, #1                        @ count - 1
    sxth r9, r9                            @ i as a signed halfword
    subs r3, r3, r9                        @ r3 = count - 1 - i: source index
    ldr r2, [r2, r3, lsl #2]               @ r2 = history[count - 1 - i]
    str r2, [r0, r1, lsl #2]               @ history[count - i] = r2
    adds r9, r9, #1                        @ i + 1
    b .Lhist_0800B7EA                      @ next i
    @ Store the new value at the front and sum the history.
.Lhist_0800B82E:
    ldr r0, [r11, #FUNC_DESC_HIST]         @ r0 = address of the history array
    str r5, [r0, #0]                       @ history[0] = D
    movs r0, #0                            @ r0 = 0
    mov r9, r0                             @ r9 = i = 0
    @ Loop head of the sum: test i < count.
.Lhist_0800B838:
    mov r0, r9                             @ r0 = i
    ldr r1, [r11, #FUNC_DESC_COUNT]        @ r1 = address of the count byte
    ldrb r1, [r1, #0]                      @ r1 = count
    sxth r0, r0                            @ i as a signed halfword
    sxth r1, r1                            @ count as a signed halfword
    cmp r0, r1                             @ i < count?
    bge .Lhist_0800B860                    @ no: the sum is complete
    ldr r0, [r11, #FUNC_DESC_HIST]         @ r0 = address of the history array
    sxth r9, r9                            @ i as a signed halfword
    ldr r0, [r0, r9, lsl #2]               @ r0 = history[i]
    asrs r1, r0, #0x1f                     @ r1 = sign extension of r0 (high word)
    adds r6, r6, r0                        @ r7:r6 += r1:r0 (64-bit sum), low word
    adcs r7, r1                            @ high word
    adds r9, r9, #1                        @ i + 1
    b .Lhist_0800B838                      @ next i
    @ Divide the sum by the count and store the result.
.Lhist_0800B860:
    movs r0, r6                            @ r0 = sum, low word
    movs r1, r7                            @ r1 = sum, high word
    ldr r2, [r11, #FUNC_DESC_COUNT]        @ r2 = address of the count byte
    ldrb r2, [r2, #0]                      @ r2 = count (low word of the divisor)
    movs r3, #0                            @ r3 = 0 (high word of the divisor)
    bl fn_08013FE4                         @ signed 64-bit division: r0 = sum / count
    mov r8, r0                             @ r8 = quotient (low word)
    ldr r0, [r11, #FUNC_DESC_LAST]         @ r0 = address of the last output
    str r8, [r0]                           @ last = quotient
    mov r0, r8                             @ r0 = result
    @ Return.
.Lhist_0800B87C:
    pop {r3-r11, pc}                   @ restore r4-r11, return
ENDFUNC func_hist_core

@ -----------------------------------------------------------------------------
@ fn_0800B888 - running mean of three values
@ Replaces : 0x0800B888 (v2.05 FUN_0800b888)
@ In       : r0 = new value D
@ Out      : r0 = mean (also stored as the last output 0x20007E70)
@ Clobbers : r0-r3, flags
@ Context  : main
@ RAM      : reads/writes 0x20007E70, 0x20007E74, 0x20007E78
@ Spec     : DESIGN.md 6.6; the algorithm is in the file header
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0800B888
    movs r1, r0                            @ r1 = D
    ldr r0, =func_mean3_last               @ r0 = address of the last output
    ldr r0, [r0, #0]                       @ r0 = last
    subs r0, r1, r0                        @ r0 = diff = D - last
    movs r2, r0                            @ r2 = diff
    cmp r2, #0xb                           @ diff >= 11?
    bge .Lmean3_0800B89E                   @ yes: restart
    cmn r2, #0xa                           @ diff + 10
    bge .Lmean3_0800B8A6                   @ diff >= -10: inside the window, keep the state
    @ diff >= 11 or diff < -10: restart the mean.
.Lmean3_0800B89E:
    movs r0, #0                            @ r0 = 0
    ldr r3, =func_mean3_count              @ r3 = address of the count
    str r0, [r3, #0]                       @ count = 0
    @ First value?
.Lmean3_0800B8A6:
    ldr r0, =func_mean3_count              @ r0 = address of the count
    ldr r0, [r0, #0]                       @ r0 = count
    cmp r0, #0                             @ count = 0?
    bne .Lmean3_0800B8CA                   @ no: accumulate
    movs r0, #1                            @ r0 = 1
    ldr r3, =func_mean3_count              @ r3 = address of the count
    str r0, [r3, #0]                       @ count = 1
    ldr r0, =func_mean3_sum                @ r0 = address of the sum
    str r1, [r0, #0]                       @ sum = D
    ldr r0, =func_mean3_last               @ r0 = address of the last output
    str r1, [r0, #0]                       @ last = D
    movs r2, r1                            @ r2 = D
    movs r0, r2                            @ result = D
    b .Lmean3_0800B92C                     @ return
    @ Accumulate.
.Lmean3_0800B8CA:
    ldr r0, =func_mean3_count              @ r0 = address of the count
    ldr r0, [r0, #0]                       @ r0 = count
    adds r0, r0, #1                        @ count + 1
    ldr r3, =func_mean3_count              @ r3 = address of the count
    str r0, [r3, #0]                       @ store count + 1
    ldr r0, =func_mean3_count              @ r0 = address of the count
    ldr r0, [r0, #0]                       @ r0 = count
    cmp r0, #4                             @ count >= 4?
    blt .Lmean3_0800B902                   @ no: add the value to the sum
    movs r0, #3                            @ r0 = 3
    ldr r3, =func_mean3_count              @ r3 = address of the count
    str r0, [r3, #0]                       @ count = 3
    ldr r0, =func_mean3_sum                @ r0 = address of the sum
    ldr r0, [r0, #0]                       @ r0 = sum
    ldr r3, =func_mean3_last               @ r3 = address of the last output
    ldr r3, [r3, #0]                       @ r3 = last
    subs r0, r0, r3                        @ r0 = sum - last (the oldest value is approximated by the previous mean)
    adds r0, r1, r0                        @ r0 = D + (sum - last)
    ldr r3, =func_mean3_sum                @ r3 = address of the sum
    str r0, [r3, #0]                       @ sum = D + (sum - last)
    b .Lmean3_0800B910                     @ divide
    @ count < 4: sum = D + sum.
.Lmean3_0800B902:
    ldr r0, =func_mean3_sum                @ r0 = address of the sum
    ldr r0, [r0, #0]                       @ r0 = sum
    adds r0, r1, r0                        @ r0 = D + sum
    ldr r3, =func_mean3_sum                @ r3 = address of the sum
    str r0, [r3, #0]                       @ store the sum
    @ Mean = sum / count.
.Lmean3_0800B910:
    ldr r0, =func_mean3_sum                @ r0 = address of the sum
    ldr r0, [r0, #0]                       @ r0 = sum
    ldr r3, =func_mean3_count              @ r3 = address of the count
    ldr r3, [r3, #0]                       @ r3 = count
    sdiv r0, r0, r3                        @ r0 = sum / count (signed)
    ldr r3, =func_mean3_last               @ r3 = address of the last output
    str r0, [r3, #0]                       @ last = mean
    ldr r0, =func_mean3_last               @ r0 = address of the last output
    ldr r0, [r0, #0]                       @ r0 = mean, the result
    @ Return.
.Lmean3_0800B92C:
    bx lr
ENDFUNC fn_0800B888
    .ltorg

