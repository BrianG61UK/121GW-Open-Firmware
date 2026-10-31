@ =============================================================================
@ calmode.s - CAL module: calibration request check, request start, countdown length, capture cancel
@
@ In calibration mode (0x2000808A = 1) the key handler (KEY) asks fn_08015728 whether a SETUP short (kind 0,
@ offset) or MEM short (kind 1, gain) may start, then starts it with fn_08015768 (EEPROM_MAP.md 7.3,
@ analysis/keys_setup.md 5.2).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .bss_port.cal, "aw", %nobits
    .global cal_req_mode, cal_req_range
cal_req_mode:   .space 1                    @ meter_mode when fn_08015768 started the pending capture (OF-36)
cal_req_range:  .space 1                    @ meter_range at that moment

    .section .text.cal, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08015728 - is a calibration request refused in the current mode
@ Replaces : 0x08015728
@ In       : r0 = kind (0 offset, 1 gain)
@ Out      : r0 = 1 refused, 0 allowed.  v2.05: refused in modes 0, 7, 8, and kind 0 in modes 6, 11, 12 at
@            range >= 2 (0x08015728..0x0801575E); the port also refuses mode 10 (OF-07)
@ Clobbers : r1, r2, flags
@ Context  : main (KEY: SETUP short 0x08014DBE, MEM short 0x08014E44)
@ RAM      : reads 0x2000803C, 0x2000803D
@ Spec     : DESIGN.md 7.2 (OF-07); EEPROM_MAP.md 7.3, 10
@ Deviation: OF-07 (BEEP refused, decision Q1)
@ -----------------------------------------------------------------------------
FUNC fn_08015728
    uxtb r1, r0                             @ r1 = kind
    movs r0, #1                             @ result if refused
    ldr r2, =meter_mode
    ldrb r2, [r2]
    cmp r2, #0                              @ LowZ (0x08015730)
    beq 9f
    cmp r2, #10                             @ BEEP (OF-07)
    beq 9f
    sub r2, r2, #7                          @ PULSE, DUTY (0x08015738..0x0801573C)
    cmp r2, #1
    bls 9f
    adds r2, r2, #7                         @ mode again
    cmp r2, #6                              @ FREQ (0x08015736)
    beq 1f
    sub r2, r2, #11                         @ DIODE, CAP (0x0801573E..0x08015742)
    cmp r2, #1
    bls 1f
    movs r0, #0                             @ every other mode: allowed
    bx lr
1:  movs r0, #0
    cbnz r1, 9f                             @ gain request: allowed (0x0801574E)
    ldr r2, =meter_range
    ldrb r2, [r2]
    cmp r2, #2                              @ offset at range >= 2: refused (0x08015758)
    it ge                                   @ signed byte compare as 0x0801575A
    movge r0, #1
9:  bx lr
ENDFUNC fn_08015728

@ -----------------------------------------------------------------------------
@ fn_08015768 - start a calibration request
@ Replaces : 0x08015768
@ In       : r0 = kind (0 offset: flag 0x2000808C, 1 gain: flag 0x2000808E)
@ Out      : r0 = result of fn_0800F13C (0 request started, 1 AC band word requested, 2 refused band)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (KEY)
@ RAM      : writes 0x2000808C..0x2000808F, 0x20008095, 0x20007C38 (64-bit), 0x20007E1C; port RAM
@            cal_req_mode, cal_req_range (OF-36)
@ Spec     : listing 0x08015768..0x080157DC
@ -----------------------------------------------------------------------------
FUNC fn_08015768
    push {r4, r5, r6, lr}
    uxtb r4, r0                             @ r4 = kind
    movs r0, #0
    ldr r1, =v_2000808C
    strb r0, [r1]                           @ 0x2000808C..0x2000808F = 0 (0x0801576E..0x08015788)
    strb r0, [r1, #1]
    strb r0, [r1, #2]
    strb r0, [r1, #3]
    mov r0, r4
    bl fn_0800F13C                          @ AC band classification (0x0801578E)
    uxtb r5, r0
    cbnz r5, 9f                             @ band word or refusal: return it (0x08015798)
    ldr r1, =v_2000808C
    movs r0, #1
    cmp r4, #0
    it eq                                   @ kind 0: offset request flag
    strbeq r0, [r1]
    cmp r4, #1
    it eq                                   @ kind 1: gain request flag
    strbeq r0, [r1, #2]
    ldr r1, =meter_mode
    ldrb r0, [r1]
    ldrb r2, [r1, #1]                       @ meter_range follows meter_mode (0x2000803D)
    ldr r1, =cal_req_mode
    strb r0, [r1]                           @ mode and range of this capture, checked at its completion
    strb r2, [r1, #1]                       @ (cal_completion_refused, OF-36)
    bl fn_080157E8                          @ countdown length (0x080157BA)
    ldr r1, =v_20008095
    strb r0, [r1]
    movs r0, #0
    movs r1, #0
    ldr r2, =v_20007C38
    strd r0, r1, [r2]                       @ 64-bit sum = 0 (0x080157CC)
    ldr r1, =v_20007E1C
    str r0, [r1]                            @ accumulator = 0 (0x080157D6)
9:  mov r0, r5
    pop {r4, r5, r6, pc}
ENDFUNC fn_08015768

@ -----------------------------------------------------------------------------
@ fn_080157E8 - countdown length of a capture
@ Replaces : 0x080157E8
@ In       : -
@ Out      : r0 = 4 in modes 13, 14, 15, 22, 23, 24 and in mode 9 range 6, else 16
@ Clobbers : r1, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_080157E8
    ldr r1, =meter_mode
    ldrb r1, [r1]
    movs r0, #4
    sub r1, r1, #13                         @ modes 13..15
    cmp r1, #2
    bls 9f
    sub r1, r1, #9                          @ modes 22..24
    cmp r1, #2
    bls 9f
    adds r1, r1, #22                        @ mode again
    cmp r1, #9
    bne 1f
    ldr r1, =meter_range
    ldrb r1, [r1]
    cmp r1, #6
    beq 9f                                  @ OHM range 6: 4
1:  movs r0, #16
9:  bx lr
ENDFUNC fn_080157E8

@ -----------------------------------------------------------------------------
@ cal_capture_cancel - cancel a pending mode-dependent capture at a mode or range application
@ Replaces : nothing in v2.05 (new; v2.05 never clears the request flags on a mode or range change, so a
@            pending request completes in whatever mode is active, EEPROM_MAP.md 7.3)
@ In       : -
@ Out      : r0 = 1 a capture was cancelled (refusal beep sounded), 0 nothing was pending
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (MODE, meter_apply_mode_range, where v2.05 sets the settle count 0x20000238)
@ RAM      : clears 0x2000808C (offset), 0x2000808E (gain), 0x20008090 (OHM range-6 weight) and the AC word
@            flags 0x2000809C..0x2000809F; the board-offset capture 0x20008096 does not depend on the mode and
@            is kept (DESIGN.md 7.2 OF-07 bullet)
@ Spec     : DESIGN.md 7.2, 10, 12.2 (NF-08 = OF-36); ORIGINAL_FIRMWARE_ISSUES.md OF-36
@ Deviation: OF-36 (switch CAL_CANCEL_ON_MODE_CHANGE; with 0 the routine does nothing and returns 0)
@ -----------------------------------------------------------------------------
FUNC cal_capture_cancel
    .if CAL_CANCEL_ON_MODE_CHANGE
    push {r4, lr}
    movs r4, #0                             @ r4 = something was pending
    movs r2, #0
    ldr r1, =v_2000808C
    ldrb r0, [r1]
    orr r4, r4, r0
    strb r2, [r1]                           @ offset request
    ldrb r0, [r1, #2]
    orr r4, r4, r0
    strb r2, [r1, #2]                       @ 0x2000808E gain request
    ldr r1, =v_20008090
    ldrb r0, [r1]
    orr r4, r4, r0
    strb r2, [r1]                           @ OHM range-6 weight request
    ldr r1, =v_2000809C
    ldr r0, [r1]                            @ the four AC word flags 0x2000809C..0x2000809F (word aligned)
    orr r4, r4, r0
    str r2, [r1]
    cbz r4, 9f
    bl fn_0800EE6C                          @ refusal beep
    movs r4, #1
9:  mov r0, r4
    pop {r4, pc}
    .else
    movs r0, #0
    bx lr
    .endif
ENDFUNC cal_capture_cancel

    .ltorg
