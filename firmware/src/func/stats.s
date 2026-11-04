@ =============================================================================
@ stats.s - FUNC: statistics of the MIN/MAX readings, count and standard deviation (production image only,
@ DESIGN.md 10 IMP-14, FEATURES.md 2.7)
@
@ While MIN/MAX is on, every reading that v2.05 puts into its running mean (fn_0800E604: MIN/MAX on, HOLD off, no
@ overload) is also given to func_stats_add.  The statistics are Welford's running mean and sum of squared deviations
@ in binary64:
@     n = n + 1;  delta = x - mean;  mean = mean + delta / n;  m2 = m2 + delta * (x - mean)
@ and the sample standard deviation is sqrt(m2 / (n - 1)) for n >= 2.  Each added term delta * (x - mean_new) equals
@ delta^2 (n - 1) / n >= 0 and keeps that sign when rounded, so m2 never becomes negative and no difference of two
@ large sums is formed (no cancellation).  The reading x and the count n are converted exactly: |x| < 2^24 counts and
@ n <= 1 000 000, so the conversion through single precision (fn_08012F60, fn_08013168) loses nothing.
@ The count stops at 1 000 000 as v2.05's own count (func_mm_count): from there the statistics are frozen, they are not
@ approximated.  func_stats_clear runs where v2.05 clears its registers (fn_08015974, MIN/MAX switched on).
@ The runtime helpers used are those of OF-51 (production image: dsqrt answers a negative operand with NaN, 64-bit
@ division by zero has a defined result); m2 >= 0 and n - 1 >= 1 keep both cases away from these calls.
@
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ FUNC_STATS_NMAX,     1000000       @ count limit, as func_mm_count (fn_0800E604 0x0800E6C6)

    .section .bss_port.stats, "aw", %nobits
    .balign 8
@ func_stats_mean, func_stats_m2: binary64 (low word first); func_stats_n: number of readings (owner FUNC)
    .global func_stats_mean, func_stats_m2, func_stats_n
func_stats_mean: .space 8
func_stats_m2:   .space 8
func_stats_n:    .space 4

    .section .text.func.stats, "ax", %progbits

@ -----------------------------------------------------------------------------
@ func_stats_clear - empty the statistics
@ In/Out   : - / -
@ Clobbers : r0, r1
@ Context  : main only (fn_08015974)
@ -----------------------------------------------------------------------------
FUNC func_stats_clear
    movs r0, #0
    ldr r1, =func_stats_mean
    str r0, [r1, #0]
    str r0, [r1, #4]                        @ mean = +0.0
    ldr r1, =func_stats_m2
    str r0, [r1, #0]
    str r0, [r1, #4]                        @ m2 = +0.0
    ldr r1, =func_stats_n
    str r0, [r1]                            @ n = 0
    bx lr
ENDFUNC func_stats_clear

@ -----------------------------------------------------------------------------
@ i2d - a signed 32-bit integer of magnitude below 2^24 as binary64 (exact)
@ In       : r0
@ Out      : r0:r1
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC func_stats_i2d
    push {r4, lr}
    bl fn_08012F60                          @ int32 -> binary32 (exact below 2^24)
    bl fn_08013168                          @ binary32 -> binary64 (exact)
    pop {r4, pc}
ENDFUNC func_stats_i2d

@ -----------------------------------------------------------------------------
@ func_stats_add - add one reading
@ In       : r0 = reading x (counts)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ Context  : main only (fn_0800E604)
@ RAM      : reads and writes func_stats_n, func_stats_mean, func_stats_m2
@ Note     : stack frame: [sp, #0] x, [sp, #8] delta (binary64 each)
@ -----------------------------------------------------------------------------
FUNC func_stats_add
    push {r4-r7, lr}
    sub sp, #20                             @ two binary64 temporaries (+4 keeps sp 8-byte aligned with the 5 pushes)
    mov r4, r0                              @ r4 = x
    ldr r1, =func_stats_n
    ldr r5, [r1]
    ldr r2, =FUNC_STATS_NMAX
    cmp r5, r2
    bhs .Lsa_ret                            @ count limit reached: frozen
    adds r5, r5, #1
    str r5, [r1]                            @ n = n + 1
    mov r0, r4
    bl func_stats_i2d
    strd r0, r1, [sp, #0]                   @ x as binary64
    ldr r2, =func_stats_mean
    ldrd r2, r3, [r2]
    bl fn_0801FB9C                          @ delta = x - mean
    strd r0, r1, [sp, #8]
    mov r0, r5
    bl func_stats_i2d                       @ n as binary64
    mov r2, r0
    mov r3, r1
    ldrd r0, r1, [sp, #8]
    bl fn_0801B874                          @ delta / n
    ldr r2, =func_stats_mean
    ldrd r2, r3, [r2]
    bl fn_080131B8                          @ mean + delta / n
    ldr r2, =func_stats_mean
    strd r0, r1, [r2]                       @ mean = new mean
    mov r2, r0
    mov r3, r1
    ldrd r0, r1, [sp, #0]
    bl fn_0801FB9C                          @ x - new mean
    ldrd r2, r3, [sp, #8]
    bl fn_0801BB64                          @ delta * (x - new mean), >= 0
    ldr r2, =func_stats_m2
    ldrd r2, r3, [r2]
    bl fn_080131B8                          @ m2 + term
    ldr r2, =func_stats_m2
    strd r0, r1, [r2]                       @ m2 = new m2
.Lsa_ret:
    add sp, #20
    pop {r4-r7, pc}
ENDFUNC func_stats_add

@ -----------------------------------------------------------------------------
@ func_stats_sd_float - the sample standard deviation as binary32
@ In       : -
@ Out      : r0 = 0 (fewer than two readings, r1 undefined) or 1 with r1 = sqrt(m2 / (n - 1)) as binary32
@ Clobbers : r0-r3, r12, flags (r4-r11 saved)
@ Context  : main only (ui_stats_draw)
@ RAM      : reads func_stats_n, func_stats_m2
@ -----------------------------------------------------------------------------
FUNC func_stats_sd_float
    push {r4, lr}
    ldr r0, =func_stats_n
    ldr r0, [r0]
    cmp r0, #2
    blo .Lsd_none                           @ fewer than two readings: no standard deviation
    subs r0, r0, #1
    bl func_stats_i2d                       @ n - 1 (>= 1) as binary64
    mov r2, r0
    mov r3, r1
    ldr r0, =func_stats_m2
    ldrd r0, r1, [r0]
    bl fn_0801B874                          @ m2 / (n - 1), >= 0
    bl fn_08013EF4                          @ square root
    bl fn_0801BACC                          @ binary64 -> binary32
    mov r1, r0
    movs r0, #1
    pop {r4, pc}
.Lsd_none:
    movs r0, #0
    pop {r4, pc}
ENDFUNC func_stats_sd_float

    .ltorg

