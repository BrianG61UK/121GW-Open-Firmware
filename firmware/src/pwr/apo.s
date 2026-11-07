@ =============================================================================
@ apo.s - PWR: automatic power-off (APO) counter
@
@ Replaces FUN_0800ED26 (APO reload) and the APO block 0x08024CAE..0x08024D1A of the v2.05 main loop, which
@ becomes pwr_apo_second, called by sys_main at the same place of loop step 9 (DESIGN.md 3.5, 3.6).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    @ the times (v2.05: 1800 s, 3600 s in MIN/MAX, 0x0800ED3C / 0x0800ED30) and the warning start (v2.05 60 s left,
    @ 0x08024CE4) come from the page APO (IMP-49, set/apot.s)
    .equ PWR_APO_WARN_BEEPS,     5          @ number of warning beeps (0x08024CFC)
    .equ PWR_APO_BEEP_TICKS,     500        @ 0.5 s beep in TIM3 ticks (0x08024D0A)

    .section .text.pwr.apo, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800ED26 - reload the APO counter and clear the APO warning state
@ Replaces : 0x0800ED26 FUN_0800ED26 (v2.05)
@ In/Out   : - / -
@ Clobbers : r0, r1 (r2 saved: set_apot_seconds uses it)
@ Context  : main
@ RAM      : reads 0x2000804E (MIN/MAX state), pwr_apo_code (IMP-49); writes 0x20000230 (APO counter, u16), 0x200080E8, 0x200080E9,
@            0x200080E6
@ -----------------------------------------------------------------------------
FUNC fn_0800ED26
    push {r2, lr}
    bl set_apot_seconds                     @ IMP-49: the time of the page APO, doubled in MIN/MAX (v2.05: 1800 s, 3600 s)
    ldr r1, =apo_countdown
    strh r0, [r1]                           @ 0x0800ED38 / 0x0800ED44
    movs r0, #0
    ldr r1, =v_200080E8
    strb r0, [r1]                           @ 0x0800ED4C
    ldr r1, =v_200080E9
    strb r0, [r1]                           @ 0x0800ED54
    ldr r1, =v_200080E6
    strb r0, [r1]                           @ 0x0800ED5C
    pop {r2, pc}
ENDFUNC fn_0800ED26

@ -----------------------------------------------------------------------------
@ pwr_apo_second - APO work of each 1 s flag: count down, request power-off, warning beeps
@ Replaces : 0x08024CAE..0x08024D1A of main (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (loop step 9)
@ RAM      : reads 0x20008039 (APO disabled setting), 0x2000804E, 0x20007FE1 (logging on); writes 0x20000230,
@            0x2000803A (power-off request), 0x200080E8, 0x200080E9
@ Spec     : DESIGN.md 3.6
@ -----------------------------------------------------------------------------
FUNC pwr_apo_second
    push {r3, lr}
    @ count down only with APO enabled, MIN/MAX off and logging off (0x08024CAE..0x08024CC4)
    ldr r0, =v_20008039
    ldrb r0, [r0]
    cbnz r0, .Lpas_warn
    ldr r0, =minmax_state
    ldrb r0, [r0]
    cbnz r0, .Lpas_warn
    ldr r0, =v_20007FE1
    ldrb r0, [r0]
    cbnz r0, .Lpas_warn
    ldr r1, =apo_countdown
    ldrh r0, [r1]
    subs r0, r0, #1
    strh r0, [r1]                           @ 0x08024CCE
    uxth r0, r0
    cbnz r0, .Lpas_at60
    movs r0, #1
    ldr r1, =v_2000803A
    strb r0, [r1]                           @ counter reached 0: power-off request (0x08024CDC)
    b .Lpas_warn
.Lpas_at60:
    mov r2, r0
    bl set_apot_warn_at                     @ IMP-49: 15 s with the 1-minute time, else 60 s (v2.05 0x08024CE4)
    cmp r2, r0
    bne .Lpas_warn
    movs r0, #1
    ldr r1, =v_200080E8
    strb r0, [r1]                           @ 60 s left: start the warning (0x08024CEC)
.Lpas_warn:
    ldr r1, =v_200080E8                     @ 0x08024CEE..0x08024D00
    ldrb r0, [r1]
    cbz r0, .Lpas_beep
    movs r0, #0
    strb r0, [r1]
    movs r0, #PWR_APO_WARN_BEEPS
    ldr r1, =v_200080E9
    strb r0, [r1]
.Lpas_beep:
    ldr r0, =v_200080E9                     @ 0x08024D02..0x08024D1A
    ldrb r0, [r0]
    cbz r0, .Lpas_done
    mov r0, #PWR_APO_BEEP_TICKS
    bl fn_0800EEA8                          @ 0x08024D0E; OF-63: gated by the buzzer setting (v2.05 pe7_on_with_timeout)
    ldr r1, =v_200080E9
    ldrb r0, [r1]
    subs r0, r0, #1
    strb r0, [r1]                           @ 0x08024D1A
.Lpas_done:
    pop {r3, pc}
ENDFUNC pwr_apo_second

    .ltorg
