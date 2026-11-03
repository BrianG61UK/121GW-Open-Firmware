@ =============================================================================
@ capture.s - CAL module: calibration captures (offset, gain, AC words) and gain computation
@
@ A capture is started by fn_08015768 (calmode.s) from a SETUP short (offset, request flag 0x2000808C) or a
@ MEM short (gain, 0x2000808E) in calibration mode, by the MEM long in OHM range 6 (0x20008090) or in another
@ mode (board offset 0x20008096, completed in MTMP).  The measurement chains call the routines below with each
@ new 16-sample mean; the countdown 0x20008095 steps once per call and the record is written when it reaches 0
@ (EEPROM_MAP.md 7.3).
@ Port changes (DESIGN.md 7.2, 10, 12.2):
@   OF-07  a capture whose countdown ends while meter_mode is 0 (LowZ) or 10 (BEEP) is discarded: its request
@          flag is cleared, nothing is computed or written, the refusal beep sounds (cal_discard);
@   OF-36  a capture whose countdown ends in another mode or range than the one it was started in is discarded
@          the same way (cal_completion_refused); normally cal_capture_cancel has cancelled it at the change;
@   OF-08  the range-0 offset save of a current mode 16..21 clears that mode's user-zero record
@          (current_extra_clear, MVA) after the offset record was written.
@ Every EEPROM write: NVM_ARM CAL immediately before the NVM writer (DESIGN.md 6.21).
@ Context: main (measurement path through hy3131_poll).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ F_1E4,     0x461C4000              @ 10000.0f
    .equ F_6000,    0x45BB8000              @ 6000.0f
    .equ F_1000,    0x447A0000              @ 1000.0f
    .equ F_30000,   0x46EA6000              @ 30000.0f
    .equ F_50000,   0x47435000              @ 50000.0f
    .equ D_F470_LO, 0x4302B40F              @ double 0x404E67564302B40F (60.806...) used by 0x0800F62C
    .equ D_F470_HI, 0x404E6756
    .equ D_FBB8_LO, 0x04816F01              @ double 0x40E4B74D04816F01 (42426.406...) used by 0x0800FBC4
    .equ D_FBB8_HI, 0x40E4B74D

    .section .text.cal, "ax", %progbits

@ -----------------------------------------------------------------------------
@ cal_completion_refused - may the capture that has just counted down write its record
@ Replaces : nothing in v2.05 (v2.05 completes in whatever mode and range are active, OF-07, OF-36)
@ In       : r0 = 0 offset or gain capture started by fn_08015768, 1 OHM range-6 weight capture (0x20008090)
@ Out      : r0 = 1 refused (the caller discards the capture), 0 allowed: refused in meter_mode 0 (LowZ) and
@            10 (BEEP) (OF-07); for r0 = 0 also when meter_mode / meter_range differ from the mode and range
@            recorded by fn_08015768 at the start; for r0 = 1 also outside mode 9 range 6 (the only place where
@            the MEM long sets 0x20008090, 0x080164EE) (OF-36: the capture belongs to the mode and range it was
@            started in; cal_capture_cancel normally cancels it at the change already)
@ Clobbers : r1, r2, flags
@ Context  : main
@ Deviation: OF-07, OF-36
@ -----------------------------------------------------------------------------
LFUNC cal_completion_refused
    ldr r1, =meter_mode
    ldrb r1, [r1]                           @ r1 = mode
    cmp r1, #0                              @ OF-07: LowZ
    beq 8f
    cmp r1, #10                             @ OF-07: BEEP
    beq 8f
    ldr r2, =meter_range
    ldrb r2, [r2]                           @ r2 = range
    cbnz r0, 1f
    ldr r0, =cal_req_mode
    ldrb r0, [r0]
    cmp r0, r1
    bne 8f                                  @ mode changed since the start
    ldr r0, =cal_req_range
    ldrb r0, [r0]
    cmp r0, r2
    bne 8f                                  @ range changed since the start
    movs r0, #0
    bx lr
1:  cmp r1, #9                              @ weight capture: OHM range 6 only
    bne 8f
    cmp r2, #6
    bne 8f
    movs r0, #0
    bx lr
8:  movs r0, #1
    bx lr
ENDFUNC cal_completion_refused

@ -----------------------------------------------------------------------------
@ cal_discard - discard a completed capture (OF-07)
@ Replaces : nothing in v2.05 (OF-07)
@ In       : r0 = address of the request flag byte to clear
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ Deviation: OF-07, OF-36
@ -----------------------------------------------------------------------------
LFUNC cal_discard
    push {r4, lr}
    movs r1, #0
    strb r1, [r0]                           @ request flag cleared, the done flag is not set
    bl fn_0800EE6C                          @ refusal beep
    pop {r4, pc}
ENDFUNC cal_discard

@ -----------------------------------------------------------------------------
@ cal_set_805d - set the new-mean flag 0x2000805D
@ Replaces : the 0x2000805D = 1 stores of the capture routines (e.g. 0x0800EFCC..0x0800EFD2)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC cal_set_805d
    ldr r1, =v_2000805D
    movs r0, #1
    strb r0, [r1]
    bx lr
ENDFUNC cal_set_805d

@ -----------------------------------------------------------------------------
@ cal_countdown - decrement the capture countdown 0x20008095
@ Replaces : the countdown steps of the capture routines (e.g. 0x0800EFA4..0x0800EFBA)
@ In       : -
@ Out      : r0 = new count (u8); Z set when it reached 0
@ Clobbers : r1, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC cal_countdown
    ldr r1, =v_20008095
    ldrb r0, [r1]
    subs r0, r0, #1
    uxtb r0, r0                             @ u8 counter (strb wraps as 0x0800EFAA..0x0800EFB0)
    strb r0, [r1]
    cmp r0, #0
    bx lr
ENDFUNC cal_countdown

@ -----------------------------------------------------------------------------
@ cal_sum64_add - add a 32-bit value to the 64-bit capture sum 0x20007C38
@ Replaces : the 64-bit additions 0x0800F03C..0x0800F04C (zero-extended) and 0x0800F49E..0x0800F4AE
@            (sign-extended)
@ In       : r0 = value, r1 = 0 zero-extend, 1 sign-extend
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC cal_sum64_add
    cmp r1, #0
    ite ne                                  @ high word of the addend: sign or zero
    asrne r1, r0, #31
    moveq r1, #0
    ldr r3, =v_20007C38
    ldrd r2, r12, [r3]                      @ sum low, high
    adds r2, r2, r0
    adc r12, r12, r1
    strd r2, r12, [r3]
    bx lr
ENDFUNC cal_sum64_add

@ -----------------------------------------------------------------------------
@ cal_sum64_clear - clear the 64-bit capture sum 0x20007C38
@ Replaces : the 64-bit clears 0x0800F48C..0x0800F494, 0x0800F53A..0x0800F542, 0x080157C4..0x080157CC
@ In       : -
@ Out      : -
@ Clobbers : r0-r2
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC cal_sum64_clear
    movs r0, #0
    movs r1, #0
    ldr r2, =v_20007C38
    strd r0, r1, [r2]
    bx lr
ENDFUNC cal_sum64_clear

@ -----------------------------------------------------------------------------
@ cal_sum64_div - signed 64-bit capture sum divided by a positive divisor
@ Replaces : the ldivmod calls 0x0800F088..0x0800F08C, 0x0800F4DA..0x0800F4DE, 0x0800F5D8..0x0800F5E4,
@            0x0800F710..0x0800F714
@ In       : r0 = divisor
@ Out      : r0 = quotient (low word, ldivmod 0x08013FE4)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC cal_sum64_div
    push {r4, lr}
    mov r2, r0                              @ divisor low
    asrs r3, r0, #31                        @ divisor high (sign of the divisor as 0x0800F5E2)
    ldr r4, =v_20007C38
    ldrd r0, r1, [r4]
    bl fn_08013FE4                          @ ldivmod
    pop {r4, pc}
ENDFUNC cal_sum64_div

@ -----------------------------------------------------------------------------
@ cal_r9_divisor - divisor of OHM ranges 5 and 6
@ Replaces : the divisor choices 0x0800EFD4..0x0800F000 and 0x0800F5AA..0x0800F5D6
@ In       : r0 = default divisor (16)
@ Out      : r0 = 8 in mode 9 range 5, 4 in mode 9 range 6, else the default
@ Clobbers : r1, r2, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC cal_r9_divisor
    ldr r1, =meter_mode
    ldrb r1, [r1]
    cmp r1, #9
    bne 1f
    ldr r2, =meter_range
    ldrb r2, [r2]
    cmp r2, #5
    it eq                                   @ OHM range 5: last 8 means
    moveq r0, #8
    cmp r2, #6
    it eq                                   @ OHM range 6: 4 means
    moveq r0, #4
1:  bx lr
ENDFUNC cal_r9_divisor

@ -----------------------------------------------------------------------------
@ cal_userzero_after_offset - OF-08: clear the user-zero record of a current mode at its range-0 offset save
@ Replaces : nothing in v2.05 (OF-08)
@ In       : r0 = status of the offset record write (the record is cleared only after a confirmed write),
@            r1 = 0 for the DC modes 17, 19, 21 (FUN_0800EF44), 1 for the AC modes 16, 18, 20 (FUN_0800F7B8)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ Spec     : DESIGN.md 7.2 (OF-08), 12.2 Q2; EEPROM_MAP.md 10
@ Deviation: OF-08
@ -----------------------------------------------------------------------------
LFUNC cal_userzero_after_offset
    push {r4, lr}
    cbnz r0, 9f                             @ offset not written: user zero kept
    ldr r2, =meter_range
    ldrb r2, [r2]
    cbnz r2, 9f                             @ only the range-0 offset
    ldr r2, =meter_mode
    ldrb r0, [r2]
    sub r2, r0, #16                         @ 0..5 for modes 16..21
    cmp r2, #5
    bhi 9f
    and r2, r2, #1                          @ 1 for the DC modes 17, 19, 21, 0 for the AC modes 16, 18, 20
    eor r2, r2, #1                          @ 0 for DC, 1 for AC
    cmp r2, r1
    bne 9f                                  @ not the kind of mode this save belongs to
    bl current_extra_clear                  @ MVA: arms USERZERO, A5 00000000, zeroes 0x20007E0C if active
9:  pop {r4, pc}
ENDFUNC cal_userzero_after_offset

@ -----------------------------------------------------------------------------
@ fn_0800EF44 - DC offset capture
@ Replaces : 0x0800EF44
@ In       : r0 = new mean
@ Out      : r0 = 0 (as v2.05)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (FUN_0800EEF0, MDC)
@ RAM      : 0x20008095, 0x20007E1C, 0x2000808C, 0x2000808D, 0x2000805D, 0x20007E00
@ Spec     : EEPROM_MAP.md 7.3; listing 0x0800EF44..0x0800F020
@ Deviation: OF-07, OF-08, OF-36
@ -----------------------------------------------------------------------------
FUNC fn_0800EF44
    push {r4, r5, r6, lr}
    mov r4, r0                              @ r4 = mean
    ldr r5, =v_20007E1C                     @ r5 = accumulator address
    ldr r0, =v_20008095
    ldrb r0, [r0]                           @ countdown
    cmp r0, #16
    bne 1f
    str r4, [r5]                            @ first mean: accumulator = mean (0x0800EF5A)
    b 3f
1:  ldr r1, =meter_mode
    ldrb r1, [r1]
    cmp r1, #9
    bne 2f
    ldr r1, =meter_range
    ldrb r1, [r1]
    cmp r1, #5
    bne 2f
    cmp r0, #9                              @ OHM range 5: means before the last 8 are dropped (0x0800EF78)
    blt 2f
    movs r0, #0
    str r0, [r5]
    b 3f
2:  ldr r0, [r5]
    add r0, r0, r4
    str r0, [r5]                            @ accumulate (0x0800EF8C, 0x0800EF9C)
3:  bl cal_countdown
    bne .Lef44_ret
    @ completion (0x0800EFBC)
    movs r0, #0                             @ capture started by fn_08015768
    bl cal_completion_refused
    cbz r0, 4f
    ldr r0, =v_2000808C
    bl cal_discard                          @ OF-07, OF-36
    bl cal_set_805d
    b .Lef44_ret
4:  ldr r1, =v_2000808C
    movs r0, #0
    strb r0, [r1]                           @ request done
    movs r0, #1
    strb r0, [r1, #1]                       @ 0x2000808D = 1
    bl cal_set_805d
    movs r0, #16
    bl cal_r9_divisor
    ldr r1, [r5]
    sdiv r1, r1, r0                         @ offset = accumulator / n (0x0800F008)
    ldr r2, =cal_offset
    str r1, [r2]
    NVM_ARM CAL
    ldr r1, =cal_offset
    ldr r1, [r1]
    movs r0, #0
    bl cal_record_write                     @ (0x0800F01A)
    movs r1, #0                             @ DC current modes 17, 19, 21
    bl cal_userzero_after_offset            @ OF-08
.Lef44_ret:
    movs r0, #0
    pop {r4, r5, r6, pc}
ENDFUNC fn_0800EF44

@ -----------------------------------------------------------------------------
@ fn_0800F034 - 64-bit offset capture (capacitance chain)
@ Replaces : 0x0800F034
@ In       : r0 = new value (zero-extended into the 64-bit sum, 0x0800F040..0x0800F044)
@ Out      : r0 = sum / 16 (also stored in 0x20007DFC) at completion, else 0
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (FUN_0800B33C, MRES)
@ RAM      : 0x20007C38 (64-bit), 0x20008095, 0x2000808C, 0x2000808D, 0x2000805D, 0x20007DFC
@ Deviation: OF-07, OF-36
@ -----------------------------------------------------------------------------
FUNC fn_0800F034
    push {r4, lr}
    movs r1, #0                             @ zero-extend
    bl cal_sum64_add
    bl cal_countdown
    bne 2f
    movs r0, #0                             @ capture started by fn_08015768
    bl cal_completion_refused
    cbz r0, 1f
    ldr r0, =v_2000808C
    bl cal_discard                          @ OF-07, OF-36
    bl cal_set_805d
    b 2f
1:  ldr r1, =v_2000808C
    movs r0, #0
    strb r0, [r1]
    movs r0, #1
    strb r0, [r1, #1]                       @ 0x2000808D = 1
    bl cal_set_805d
    movs r0, #16
    bl cal_sum64_div                        @ (0x0800F08C)
    ldr r1, =v_20007DFC
    str r0, [r1]
    pop {r4, pc}
2:  movs r0, #0
    pop {r4, pc}
ENDFUNC fn_0800F034

@ -----------------------------------------------------------------------------
@ fn_0800F0AC - AC offset capture (RAM only)
@ Replaces : 0x0800F0AC
@ In       : r0 = new mean
@ Out      : r0 = accumulator / 16 at completion (also 0x20007E04), else 0
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (FUN_080067D6, FUN_080069B4, FUN_08006AEC, FUN_0800A7FC; MAC)
@ RAM      : 0x20008095, 0x20007E1C, 0x2000808C, 0x2000808D, 0x20007E04, 0x2000805D (set on every call)
@ Deviation: OF-07, OF-36
@ -----------------------------------------------------------------------------
FUNC fn_0800F0AC
    push {r4, r5, r6, lr}
    ldr r5, =v_20007E1C
    ldr r1, =v_20008095
    ldrb r1, [r1]
    cmp r1, #16
    ite eq                                  @ first mean replaces, later ones add (0x0800F0B6..0x0800F0CE)
    moveq r2, r0
    ldrne r2, [r5]
    it ne                                   @ add the mean to the old accumulator
    addne r2, r2, r0
    str r2, [r5]
    movs r4, #0                             @ r4 = result
    bl cal_countdown
    bne 2f
    movs r0, #0                             @ capture started by fn_08015768
    bl cal_completion_refused
    cbz r0, 1f
    ldr r0, =v_2000808C
    bl cal_discard                          @ OF-07, OF-36
    b 2f
1:  ldr r1, =v_2000808C
    movs r0, #0
    strb r0, [r1]
    movs r0, #1
    strb r0, [r1, #1]                       @ 0x2000808D = 1
    ldr r0, [r5]
    movs r1, #16
    sdiv r4, r0, r1                         @ (0x0800F100)
    ldr r1, =v_20007E04
    str r4, [r1]
2:  bl cal_set_805d                         @ every call (0x0800F10C)
    mov r0, r4
    pop {r4, r5, r6, pc}
ENDFUNC fn_0800F0AC

@ -----------------------------------------------------------------------------
@ fn_0800F470 - DC gain capture and OHM range-6 weight capture
@ Replaces : 0x0800F470
@ In       : r0 = new value (signed)
@ Out      : r0 = value for the display: during a gain capture d2iz(i2f(value) / 60.806...), at its
@            completion f2iz(i2f(value) / new gain), 0 in the weight capture
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (FUN_0800B33C MRES, FUN_0800F37E MDC)
@ RAM      : 0x20008090, 0x20008095, 0x20007C38, 0x20007E10, 0x20007E14, 0x20000238, 0x2000808E, 0x2000808F,
@            0x2000805D, 0x20007E20
@ Spec     : EEPROM_MAP.md 7.3 (kinds 0x96 and 1); listing 0x0800F470..0x0800F640
@ Deviation: OF-07, OF-36
@ -----------------------------------------------------------------------------
FUNC fn_0800F470
    push {r4, r5, r6, lr}
    mov r6, r0                              @ r6 = value
    ldr r0, =v_20008090
    ldrb r0, [r0]
    cmp r0, #0
    beq .Lf470_gain
    @ OHM range-6 weight (0x0800F482..0x0800F51C)
    ldr r0, =v_20008095
    ldrb r0, [r0]
    cmp r0, #9
    blt 1f
    bl cal_sum64_clear                      @ means before the last 8 are dropped (0x0800F48C)
    b 2f
1:  mov r0, r6
    movs r1, #1                             @ sign-extend (0x0800F4A2)
    bl cal_sum64_add
2:  bl cal_countdown
    bne .Lf470_zero
    movs r0, #1                             @ weight capture
    bl cal_completion_refused
    cbz r0, 3f
    ldr r0, =v_20008090
    bl cal_discard                          @ OF-07, OF-36
    b .Lf470_zero
3:  ldr r1, =v_20008090
    movs r0, #0
    strb r0, [r1]
    movs r0, #8
    bl cal_sum64_div                        @ sum / 8 (0x0800F4DE)
    bl fn_08012F60                          @ i2f
    ldr r1, =cal_gain
    ldr r1, [r1]
    bl fn_08012F94                          @ / gain
    bl fn_08013370                          @ f2iz
    ldr r1, =0xFFFF8AD0                     @ -30000
    add r0, r0, r1
    ldr r1, =v_20007E14
    str r0, [r1]                            @ weight (0x0800F504)
    NVM_ARM CAL
    ldr r1, =v_20007E14
    ldr r1, [r1]
    movs r0, #0x96
    bl cal_record_write                     @ (0x0800F50E)
    ldr r1, =v_20000238
    movs r0, #5
    strb r0, [r1]                           @ settle count 5 (0x0800F518)
.Lf470_zero:
    movs r0, #0
    pop {r4, r5, r6, pc}
.Lf470_gain:
    @ gain capture (0x0800F51E..0x0800F63E)
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #9
    bne 4f
    ldr r0, =meter_range
    ldrb r0, [r0]
    cmp r0, #5
    blt 4f
    ldr r0, =v_20008095                     @ OHM ranges >= 5: means before the last 8 are dropped
    ldrb r0, [r0]
    cmp r0, #9
    blt 4f
    bl cal_sum64_clear
    b 5f
4:  mov r0, r6
    movs r1, #1
    bl cal_sum64_add
5:  bl cal_countdown
    bne .Lf470_counting
    movs r0, #0                             @ capture started by fn_08015768
    bl cal_completion_refused
    cbz r0, 6f
    ldr r0, =v_2000808E
    bl cal_discard                          @ OF-07, OF-36
    bl cal_set_805d
    b .Lf470_counting
6:  ldr r1, =v_2000808E
    movs r0, #0
    strb r0, [r1]
    movs r0, #1
    strb r0, [r1, #1]                       @ 0x2000808F = 1
    bl cal_set_805d
    movs r0, #16
    bl cal_r9_divisor
    bl cal_sum64_div                        @ (0x0800F5E4)
    bl fn_08012F60                          @ i2f
    ldr r1, =v_20007E20
    str r0, [r1]
    movs r0, #0
    bl fn_0800F9F0                          @ gain from 0x20007E20
    ldr r0, =cal_gain
    ldr r0, [r0]
    bl fn_08013370                          @ f2iz(gain): v2.05 passes it as the (unused) value (0x0800F5FE)
    mov r4, r0
    NVM_ARM CAL
    mov r1, r4
    movs r0, #1
    bl cal_record_write                     @ (0x0800F606)
    mov r0, r6
    bl fn_08012F60
    ldr r1, =cal_gain
    ldr r1, [r1]
    bl fn_08012F94
    bl fn_08013370                          @ value / new gain (0x0800F60A..0x0800F61A)
    pop {r4, r5, r6, pc}
.Lf470_counting:
    mov r0, r6                              @ provisional value (0x0800F622..0x0800F638)
    bl fn_08012F60                          @ i2f
    bl fn_08013168                          @ f2d
    ldr r2, =D_F470_LO
    ldr r3, =D_F470_HI
    bl fn_0801B874                          @ ddiv
    bl fn_080132A0                          @ d2iz
    pop {r4, r5, r6, pc}
ENDFUNC fn_0800F470

@ -----------------------------------------------------------------------------
@ fn_0800F6C0 - capacitance offset and gain capture
@ Replaces : 0x0800F6C0
@ In       : r0 = new value (zero-extended into the sum), r1 = reference
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main (FUN_0800B33C, MRES)
@ RAM      : 0x20007C38, 0x20008095, 0x2000808E, 0x2000808F, 0x2000805D, 0x20007E00, 0x20007E10, 0x20007E20
@ Spec     : listing 0x0800F6C0..0x0800F796
@ Deviation: OF-07, OF-36
@ -----------------------------------------------------------------------------
FUNC fn_0800F6C0
    push {r4-r8, lr}
    mov r5, r1                              @ r5 = reference
    movs r1, #0                             @ zero-extend (0x0800F6D2)
    bl cal_sum64_add
    bl cal_countdown
    bne 9f
    movs r0, #0                             @ capture started by fn_08015768
    bl cal_completion_refused
    cbz r0, 1f
    ldr r0, =v_2000808E
    bl cal_discard                          @ OF-07, OF-36
    bl cal_set_805d
    b 9f
1:  ldr r1, =v_2000808E
    movs r0, #0
    strb r0, [r1]
    movs r0, #1
    strb r0, [r1, #1]                       @ 0x2000808F = 1
    bl cal_set_805d
    movs r0, #16
    bl cal_sum64_div                        @ r6 = sum / 16 (0x0800F714)
    mov r6, r0
    subs r0, r6, r5
    movs r1, #9
    udiv r7, r0, r1                         @ (mean - ref) / 9, unsigned as 0x0800F71E
    subs r0, r5, r7                         @ offset = ref - that (0x0800F724)
    ldr r1, =cal_offset
    str r0, [r1]
    NVM_ARM CAL
    ldr r1, =cal_offset
    ldr r1, [r1]
    movs r0, #0
    bl cal_record_write                     @ (0x0800F738)
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #12
    bne 2f
    ldr r0, =v_20007E68                     @ mode 12: gain = ui2f(0x20007E68 - offset) / 1e4
    ldr r0, [r0]
    ldr r1, =cal_offset
    ldr r1, [r1]
    subs r0, r0, r1
    bl fn_08012F74                          @ ui2f
    ldr r1, =F_1E4
    bl fn_08012F94
    ldr r1, =cal_gain
    str r0, [r1]
    b 3f
2:  ldr r0, =cal_offset                     @ else 0x20007E20 = ui2f(mean - offset), gain by mode
    ldr r0, [r0]
    subs r0, r6, r0
    bl fn_08012F74
    ldr r1, =v_20007E20
    str r0, [r1]
    movs r0, #0
    bl fn_0800F9F0
3:  ldr r0, =cal_gain
    ldr r0, [r0]
    bl fn_08013370                          @ f2iz(gain), unused value argument (0x0800F78A)
    mov r4, r0
    NVM_ARM CAL
    mov r1, r4
    movs r0, #1
    bl cal_record_write                     @ (0x0800F792)
9:  pop {r4-r8, pc}
ENDFUNC fn_0800F6C0

@ -----------------------------------------------------------------------------
@ fn_0800F7B8 - AC gain capture (writes offset and gain)
@ Replaces : 0x0800F7B8
@ In       : r0 = new mean, r1 = reference (AC offset from fn_0800F0AC)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main (FUN_080067D6, FUN_080069B4, FUN_08006AEC, FUN_0800A7FC; MAC)
@ RAM      : 0x20008095, 0x20007E1C, 0x2000808E, 0x2000808F, 0x20007E00, 0x20007E10, 0x20007E20, 0x20007FE0,
@            0x2000805D (set on every call)
@ Spec     : EEPROM_MAP.md 7.3; listing 0x0800F7B8..0x0800F8C0
@ Deviation: OF-07, OF-08, OF-36
@ -----------------------------------------------------------------------------
FUNC fn_0800F7B8
    push {r4-r8, lr}
    mov r4, r0                              @ r4 = mean
    mov r5, r1                              @ r5 = reference
    ldr r6, =v_20007E1C
    ldr r1, =v_20008095
    ldrb r1, [r1]
    cmp r1, #16
    ite eq                                  @ first mean replaces, later ones add (0x0800F7C4..0x0800F7D6)
    moveq r2, r4
    ldrne r2, [r6]
    it ne                                   @ add the mean to the old accumulator
    addne r2, r2, r4
    str r2, [r6]
    bl cal_countdown
    bne .Lf7b8_end
    movs r0, #0                             @ capture started by fn_08015768
    bl cal_completion_refused
    cbz r0, 1f
    ldr r0, =v_2000808E
    bl cal_discard                          @ OF-07, OF-36
    b .Lf7b8_end
1:  ldr r1, =v_2000808E
    movs r0, #0
    strb r0, [r1]
    movs r0, #1
    strb r0, [r1, #1]                       @ 0x2000808F = 1
    ldr r0, [r6]
    movs r1, #16
    sdiv r7, r0, r1                         @ r7 = accumulator / 16 (0x0800F800)
    subs r0, r7, r5
    movs r1, #9
    sdiv r0, r0, r1                         @ (mean - ref) / 9, signed (0x0800F80A)
    subs r0, r5, r0                         @ offset = ref - that (0x0800F810)
    ldr r1, =cal_offset
    str r0, [r1]
    NVM_ARM CAL
    ldr r1, =cal_offset
    ldr r1, [r1]
    movs r0, #0
    bl cal_record_write                     @ (0x0800F824)
    movs r1, #1                             @ AC current modes 16, 18, 20
    bl cal_userzero_after_offset            @ OF-08
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #12
    bne 2f
    ldr r0, =v_20007E68                     @ mode 12: gain = i2f(0x20007E68 - offset) / 1e4 (signed i2f)
    ldr r0, [r0]
    ldr r1, =cal_offset
    ldr r1, [r1]
    subs r0, r0, r1
    bl fn_08012F60
    ldr r1, =F_1E4
    bl fn_08012F94
    ldr r1, =cal_gain
    str r0, [r1]
    b 3f
2:  ldr r0, =cal_offset
    ldr r0, [r0]
    subs r0, r7, r0
    bl fn_08012F60                          @ 0x20007E20 = i2f(mean - offset) (0x0800F860)
    ldr r1, =v_20007E20
    str r0, [r1]
    movs r0, #0
    bl fn_0800F9F0
3:  ldr r0, =cal_gain
    ldr r0, [r0]
    bl fn_08013370                          @ f2iz(gain), unused value argument (0x0800F876)
    mov r4, r0
    NVM_ARM CAL
    mov r1, r4
    movs r0, #1
    bl cal_record_write                     @ (0x0800F87E)
    ldr r0, =meter_mode
    ldrb r4, [r0]                           @ r4 = mode
    ldr r0, =meter_range
    ldrb r5, [r0]                           @ r5 = range
    cmp r4, #2
    bne 4f
    cmp r5, #0
    bne 4f
    bl fn_080104D4                          @ ACV range 0: marker 0x1F (0x0800F896)
    bl fn_080104BC                          @ OF-62: the RAM flag follows the marker as the boot sets it (0 if 0xA5,
    ldr r1, =v_20008087                     @ 0x08024DEE); v2.05 leaves the boot value until the next boot or wake, so the
    strb r0, [r1]                           @ CORR70 correction of ACV range 0 stayed on after the calibration
4:  cmp r4, #9
    bne .Lf7b8_end
    cmp r5, #6
    bne .Lf7b8_end
    bl fn_08010F28                          @ OHM range 6: marker 0x26 (0x0800F8AE)
    bl fn_08010F10                          @ OF-62: the RAM flag as the boot sets it (0 if 0xA5, 0x08024DE6); v2.05 stores 1
    ldr r1, =v_20007FE0                     @ (0x0800F8B2..0x0800F8B8), the opposite of what the next boot reads.  The path
    strb r0, [r1]                           @ is not reached: FUN_0800F7B8 does not run in mode 9 (DESIGN 12.2)
.Lf7b8_end:
    bl cal_set_805d                         @ every call (0x0800F8BA)
    pop {r4-r8, pc}
ENDFUNC fn_0800F7B8

@ -----------------------------------------------------------------------------
@ fn_0800F8E4 - store one AC calibration word from a band reading
@ Replaces : 0x0800F8E4
@ In       : r0 = word selector 1..4, r1 = reading (0x20007D64)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main (fn_08007532)
@ RAM      : writes 0x20007E4C + 4 * (selector - 1)
@ Spec     : listing 0x0800F8E4..0x0800F9CC (references: ACV range 3: 600 / 6000, other: 5000 / 50000)
@ -----------------------------------------------------------------------------
FUNC fn_0800F8E4
    push {r4, r5, r6, lr}
    uxtb r4, r0                             @ r4 = selector
    mov r5, r1                              @ r5 = reading
    sub r0, r4, #1
    cmp r0, #3
    bhi 3f                                  @ selector outside 1..4: no RAM change (0x0800F8FC)
    ldr r1, =meter_mode
    ldrb r1, [r1]
    ldr r2, =meter_range
    ldrb r2, [r2]
    cmp r1, #2
    bne 1f
    cmp r2, #3
    bne 1f
    ldr r1, =cal_acw_ref_r3                 @ ACV range 3
    b 2f
1:  ldr r1, =cal_acw_ref
2:  ldr r1, [r1, r0, lsl #2]                @ reference of this word
    subs r1, r5, r1                         @ word = reading - reference
    ldr r2, =v_20007E4C
    str r1, [r2, r0, lsl #2]
3:  NVM_ARM CAL
    ldr r0, =meter_mode
    ldrb r0, [r0]
    ldr r1, =meter_range
    ldrb r1, [r1]
    mov r2, r4
    bl fn_08011E88                          @ (0x0800F9C8)
    pop {r4, r5, r6, pc}
ENDFUNC fn_0800F8E4

@ -----------------------------------------------------------------------------
@ fn_0800F9F0 - gain from 0x20007E20 by mode and range
@ Replaces : 0x0800F9F0 (compare ladder; OPT-06: table of the ladder's cases, modes outside the cases do
@            nothing as v2.05's default branch 0x0800FA42)
@ In       : r0 = argument (only mode 15 and 24 test it: 0 always uses 50000)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007E10 through fn_0800FB1E..fn_0800FBB8; reads 0x2000803C, 0x2000803D, 0x200080B7
@ -----------------------------------------------------------------------------
FUNC fn_0800F9F0
    push {r4, lr}
    mov r4, r0                              @ r4 = argument
    ldr r0, =meter_mode
    ldrb r0, [r0]
    ldr r1, =meter_range
    ldrb r1, [r1]                           @ r1 = range
    cmp r0, #24
    bhi .Lf9f0_none                         @ beyond the ladder: nothing
    ldr r2, =cal_f9f0_case
    ldrb r2, [r2, r0]                       @ case of the mode
    cmp r2, #0
    beq .Lf9f0_none                         @ modes 0, 6, 7, 8
    cmp r2, #1
    beq .Lf9f0_50k                          @ 5, 9, 10, 13, 14, 16..19, 22, 23
    cmp r2, #2
    beq .Lf9f0_dcv                          @ 1
    cmp r2, #3
    beq .Lf9f0_acv                          @ 2, 4
    cmp r2, #4
    beq .Lf9f0_dcmv                         @ 3
    cmp r2, #5
    beq .Lf9f0_30k                          @ 11
    cmp r2, #6
    beq .Lf9f0_cap                          @ 12
    cmp r2, #7
    beq .Lf9f0_va                           @ 15, 24
    b .Lf9f0_amp                            @ 8: modes 20, 21
.Lf9f0_acv:
    ldr r0, =v_200080B7                     @ peak hold: double divide (0x0800FA7C..0x0800FA86)
    ldrb r0, [r0]
    cbz r0, .Lf9f0_dcv
    bl fn_0800FBB8
    b .Lf9f0_none
.Lf9f0_dcv:
    cmp r1, #2                              @ DCV range 2: 30000 (0x0800FA8C..0x0800FA98)
    beq .Lf9f0_30k
.Lf9f0_dcmv:
    cmp r1, #3                              @ range 3: 6000 (0x0800FA9E..0x0800FAAA)
    bne .Lf9f0_50k
    movs r0, #0
    bl fn_0800FB98
    b .Lf9f0_none
.Lf9f0_va:
    cbz r4, .Lf9f0_50k                      @ argument 0: 50000 (0x0800FA54..0x0800FA5C)
    cmp r1, #2
    blt .Lf9f0_50k                          @ range < 2: 50000
    b .Lf9f0_10k                            @ else 10000 (0x0800FA74)
.Lf9f0_amp:
    cmp r1, #2                              @ modes 20, 21 range 2: 10000 (0x0800FAE2..0x0800FAEE)
    bne .Lf9f0_50k
.Lf9f0_10k:
    movs r0, #0
    bl fn_0800FB78
    b .Lf9f0_none
.Lf9f0_cap:
    ldr r1, =F_1E4                          @ CAP: 1000 at range 5, else 10000 (0x0800FAFC..0x0800FB18)
    ldr r0, =meter_range
    ldrb r0, [r0]
    cmp r0, #5
    it eq                                   @ range 5: 1000
    ldreq r1, =F_1000
    movs r0, #0
    bl fn_0800FB1E
    b .Lf9f0_none
.Lf9f0_30k:
    movs r0, #0
    bl fn_0800FB58
    b .Lf9f0_none
.Lf9f0_50k:
    movs r0, #0
    bl fn_0800FB38
.Lf9f0_none:
    pop {r4, pc}
ENDFUNC fn_0800F9F0

@ -----------------------------------------------------------------------------
@ fn_0800FB1E - gain = 0x20007E20 / divisor
@ Replaces : 0x0800FB1E
@ In       : r0 = unused (v2.05 passes 0), r1 = divisor (float)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007E10
@ -----------------------------------------------------------------------------
FUNC fn_0800FB1E
    push {r4, lr}
    ldr r0, =v_20007E20
    ldr r0, [r0]
    bl fn_08012F94                          @ fdiv
    ldr r1, =cal_gain
    str r0, [r1]
    pop {r4, pc}
ENDFUNC fn_0800FB1E

@ -----------------------------------------------------------------------------
@ fn_0800FB38 - gain = 0x20007E20 / 50000
@ Replaces : 0x0800FB38 (divisor 0x47435000)
@ In       : r0 = unused (v2.05 passes 0)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007E10
@ -----------------------------------------------------------------------------
FUNC fn_0800FB38
    ldr r1, =F_50000
    b fn_0800FB1E
ENDFUNC fn_0800FB38

@ -----------------------------------------------------------------------------
@ fn_0800FB58 - gain = 0x20007E20 / 30000
@ Replaces : 0x0800FB58 (divisor 0x46EA6000)
@ In       : r0 = unused (v2.05 passes 0)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007E10
@ -----------------------------------------------------------------------------
FUNC fn_0800FB58
    ldr r1, =F_30000
    b fn_0800FB1E
ENDFUNC fn_0800FB58

@ -----------------------------------------------------------------------------
@ fn_0800FB78 - gain = 0x20007E20 / 10000
@ Replaces : 0x0800FB78 (divisor 0x461C4000)
@ In       : r0 = unused (v2.05 passes 0)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007E10
@ -----------------------------------------------------------------------------
FUNC fn_0800FB78
    ldr r1, =F_1E4
    b fn_0800FB1E
ENDFUNC fn_0800FB78

@ -----------------------------------------------------------------------------
@ fn_0800FB98 - gain = 0x20007E20 / 6000
@ Replaces : 0x0800FB98 (divisor 0x45BB8000)
@ In       : r0 = unused (v2.05 passes 0)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007E10
@ -----------------------------------------------------------------------------
FUNC fn_0800FB98
    ldr r1, =F_6000
    b fn_0800FB1E
ENDFUNC fn_0800FB98

@ -----------------------------------------------------------------------------
@ fn_0800FBB8 - gain for ACV/ACmV with peak hold: d2f(f2d(0x20007E20) / 42426.406...)
@ Replaces : 0x0800FBB8
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007E10
@ -----------------------------------------------------------------------------
FUNC fn_0800FBB8
    push {r4, lr}
    ldr r0, =v_20007E20
    ldr r0, [r0]
    bl fn_08013168                          @ f2d
    ldr r2, =D_FBB8_LO
    ldr r3, =D_FBB8_HI
    bl fn_0801B874                          @ ddiv
    bl fn_0801BACC                          @ d2f
    ldr r1, =cal_gain
    str r0, [r1]
    pop {r4, pc}
ENDFUNC fn_0800FBB8

@ -----------------------------------------------------------------------------
@ fn_08007532 - store pending AC calibration words
@ Replaces : 0x08007532
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main (FUN_080067D6, FUN_080069B4, FUN_08006AEC; MAC)
@ RAM      : reads 0x200080A5, 0x2000808A, 0x2000803C, 0x20007D64; clears 0x2000809C..0x2000809F
@ Spec     : EEPROM_MAP.md 7.3 (AC words); listing 0x08007532..0x080075F8
@ -----------------------------------------------------------------------------
FUNC fn_08007532
    push {r4, r5, r6, lr}
    ldr r0, =v_200080A5
    ldrb r0, [r0]
    cbnz r0, 9f                             @ 0x200080A5 set: nothing (0x0800753C)
    ldr r0, =v_2000808A
    ldrb r0, [r0]
    cbz r0, 9f                              @ not in calibration mode
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #2                              @ modes 16, 18, 20, 2, 4 only (0x08007548..0x0800756E)
    beq 1f
    cmp r0, #4
    beq 1f
    cmp r0, #16
    beq 1f
    cmp r0, #18
    beq 1f
    cmp r0, #20
    bne 9f
1:  movs r4, #0                             @ r4 = word index 0..3 (flags 0x2000809C..0x2000809F)
    ldr r5, =v_2000809C
2:  ldrb r0, [r5, r4]
    cbz r0, 3f
    movs r0, #0
    strb r0, [r5, r4]                       @ flag cleared before the store (0x0800757C)
    ldr r1, =v_20007D64
    ldr r1, [r1]
    adds r0, r4, #1                         @ selector 1..4
    bl fn_0800F8E4
    bl fn_0800EE50                          @ accept beep (0x0800758E)
3:  adds r4, r4, #1
    cmp r4, #4
    blo 2b
9:  pop {r4, r5, r6, pc}
ENDFUNC fn_08007532

@ -----------------------------------------------------------------------------
@ fn_0800F13C - classify a calibration request in the AC modes by frequency band
@ Replaces : 0x0800F13C
@ In       : r0 = request kind (0 offset, 1 gain)
@ Out      : r0 = 0 no band (a kind-0 request then clears the AC words, fn_08011F38), 1 band word requested
@            (flag 0x2000809C..0x2000809F set, settle count 5), 2 refused band
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (fn_08015768)
@ RAM      : reads 0x2000803C, 0x2000803D, 0x2000803E, 0x20007D84; writes 0x2000809C..0x2000809F, 0x20000238
@ Spec     : listing 0x0800F13C..0x0800F2EC (bands 8000..12000, >= 90000, 18000..22000 of fn_08012F28)
@ -----------------------------------------------------------------------------
FUNC fn_0800F13C
    push {r4, r5, r6, lr}
    uxtb r4, r0                             @ r4 = kind
    movs r5, #0                             @ r5 = result
    ldr r0, =meter_mode
    ldrb r6, [r0]                           @ r6 = mode
    cmp r6, #16
    beq 1f
    cmp r6, #18
    beq 1f
    cmp r6, #20
    beq 1f
    cmp r6, #2
    beq 1f
    cmp r6, #4
    bne .Lf13c_ret                          @ other modes: 0 (0x0800F16C)
1:  ldr r0, =v_2000803E
    ldrb r0, [r0]
    ldr r1, =v_20007D84
    ldr r1, [r1]
    bl fn_08012F28                          @ band value (0x0800F17E)
    mov r3, r0                              @ r3 = band value
    ldr r0, =meter_range
    ldrb r2, [r0]                           @ r2 = range
    @ ACV range >= 2, 8000 <= v < 12001: word 1/2 (0x0800F184..0x0800F1C8)
    cmp r6, #2
    bne 2f
    cmp r2, #2
    blt 2f
    cmp r3, #8000
    blt 2f
    movw r0, #12001
    cmp r3, r0
    bge 2f
    b .Lf13c_w12
2:  @ ACV/ACmV, v >= 90000: word 1/2 (0x0800F1CA..0x0800F206)
    cmp r6, #2
    beq 3f
    cmp r6, #4
    bne 5f
3:  ldr r0, =90000
    cmp r3, r0
    bge .Lf13c_w12
    @ ACV/ACmV, 18000 <= v < 22001: ACmV refused, ACV word 3/4 (0x0800F208..0x0800F258)
    movw r0, #18000
    cmp r3, r0
    blt 5f
    movw r0, #22001
    cmp r3, r0
    bge 5f
    cmp r6, #4
    beq .Lf13c_refused
    ldr r1, =v_2000809E                     @ kind 0: 0x2000809E, kind 1: 0x2000809F
    b .Lf13c_set
5:  @ AC current modes, 8000 <= v < 12001 (0x0800F25A..0x0800F2DC)
    cmp r6, #16
    beq 6f
    cmp r6, #18
    beq 6f
    cmp r6, #20
    bne .Lf13c_none
6:  cmp r3, #8000
    blt .Lf13c_none
    movw r0, #12001
    cmp r3, r0
    bge .Lf13c_none
    cmp r6, #20
    beq .Lf13c_refused                      @ ACA refused (0x0800F288)
    cmp r2, #0
    beq .Lf13c_refused                      @ ACuA/ACmA range 0 refused (0x0800F29E, 0x0800F2B4)
.Lf13c_w12:
    ldr r1, =v_2000809C                     @ kind 0: 0x2000809C, kind 1: 0x2000809D
.Lf13c_set:
    cmp r4, #0
    ite eq                                  @ kind 0: first flag of the pair, any other kind: second
    moveq r2, #0
    movne r2, #1
    movs r0, #1
    strb r0, [r1, r2]
    movs r5, #1
    ldr r1, =v_20000238
    movs r0, #5
    strb r0, [r1]                           @ settle count 5
    b .Lf13c_ret
.Lf13c_none:
    cbnz r4, .Lf13c_ret                     @ kind 0 without a band: clear the AC words (0x0800F2E4)
    NVM_ARM CAL
    bl fn_08011F38
.Lf13c_ret:
    mov r0, r5
    pop {r4, r5, r6, pc}
.Lf13c_refused:
    movs r0, #2
    pop {r4, r5, r6, pc}
ENDFUNC fn_0800F13C

    .section .rodata.cal, "a", %progbits
    .align 2
@ AC word references of fn_0800F8E4 (word = reading - reference), v2.05 0x0800F912..0x0800F9B0
cal_acw_ref_r3:
    .word 600, 6000, 600, 6000              @ ACV range 3 (subs #0x258, 0xFFFFE890)
cal_acw_ref:
    .word 5000, 50000, 5000, 50000          @ other modes (0xFFFFEC78, 0xFFFF3CB0)
@ Case of each mode in the ladder of fn_0800F9F0 (0x0800F9F4..0x0800FA42):
@ 0 nothing, 1 /50000, 2 DCV (range 2 /30000, range 3 /6000, else /50000), 3 ACV/ACmV (peak: double divide,
@ else as DCV), 4 DCmV (range 3 /6000, else /50000), 5 /30000, 6 CAP (range 5 /1000, else /10000),
@ 7 VA ranges (argument 0 or range < 2 /50000, else /10000), 8 A ranges (range 2 /10000, else /50000)
cal_f9f0_case:
    .byte 0, 2, 3, 4, 3, 1, 0, 0, 0, 1, 1, 5, 6, 1, 1, 7, 1, 1, 1, 1, 8, 8, 1, 1, 7

    .section .text.cal, "ax", %progbits
    .ltorg
