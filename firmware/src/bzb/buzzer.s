@ =============================================================================
@ buzzer.s - BZB: beeps on PE7 (plain GPIO level, timed by the TIM3 handler)
@
@ Replaces FUN_0800EE50 (accept beep), FUN_0800EE5E (long-press beep), FUN_0800EE6C (refusal pattern),
@ FUN_0800EE7A (common beep start), FUN_0800EEA8 (beep gated by the buzzer setting), pe7_on_with_timeout
@ 0x0800EED0 (beep not gated) and pe7_on_blocking_100_ticks 0x08024F06 (v2.05); new: bzb_off_beep_start /
@ bzb_off_beep_step (IMP-06 form of the 1 s power-off beep), bzb_silence (HW-08), and the measurement beeps of
@ IMP-54 (bzb_func_pulse, bzb_func_accept, bzb_func_double).
@ IMP-54 (GitHub issue 28): the buzzer setting 0x20008078 has a third value.  1 b-On: every beep; 0 b-OFF: the gated
@ beeps silent (OF-63); 2 qUiEt: the key beeps silent, the measurement beeps sound (diode double beep and contact
@ chirp, diode short tone, auto-hold capture, auto power-off warning and power-off beep, limit test verdict).  Each
@ pulse is started with its class (0 key, 1 measurement): bzb_pulse decides its own pulse from setting and class; a
@ pattern (bzb_pattern) also leaves its class in bzb_class for its later phases, which bzb_tim3_isr decides.  A single
@ pulse that starts in the gap of a pattern does not change the pattern's class.
@ State (v2.05 RAM): 0x20007FB4 u16 remaining TIM3 ticks of the present pulse, 0x20007FB6 u16 pulse length,
@ 0x2000807A u8 remaining pulse/gap phases, 0x20008079 u8 buzzer on, 0x20008078 u8 buzzer enabled (setting).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ BZB_PE7, 0x0080                    @ PE7 = buzzer (DESIGN.md 4.5)
    .equ BZB_OFF_BEEP_TICKS, 100            @ 100 TIM2 ticks = 1 s (v2.05 0x08024F28 cmp #0x64)

    .section .bss_port.bzb, "aw", %nobits
@ bzb_off_beep_count: TIM2 ticks counted by bzb_off_beep_step (owner BZB)
bzb_off_beep_count:
    .space 1
@ bzb_class: class of the beep pattern started last (IMP-54): 0 key beep, 1 measurement beep; written with the pattern
@ (interrupts masked) by bzb_pattern, read by bzb_tim3_isr for the pattern's later phases (owner BZB)
    .global bzb_class
bzb_class:
    .space 1
    .equ BZB_KEY, 0                         @ class: key and menu beeps (silent with qUiEt)
    .equ BZB_FUNC, 1                        @ class: measurement beeps (sound with qUiEt)
    .equ BZB_SET_ON, 1                      @ setting b-On
    .equ BZB_SET_QUIET, 2                   @ setting qUiEt

    .section .text.bzb.buzzer, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800EE50 - accept beep: one 100-tick pulse, APO reloaded
@ Replaces : 0x0800EE50 FUN_0800EE50 (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0800EE50
    movs r2, #100                           @ pulse 100 TIM3 ticks (0x0800EE52)
    movs r1, #1                             @ one phase
    movs r0, #1                             @ reload APO
    b fn_0800EE7A
ENDFUNC fn_0800EE50

@ -----------------------------------------------------------------------------
@ fn_0800EE5E - long-press beep: one 200-tick pulse, APO reloaded
@ Replaces : 0x0800EE5E FUN_0800EE5E (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0800EE5E
    movs r2, #200                           @ 0x0800EE60
    movs r1, #1
    movs r0, #1
    b fn_0800EE7A
ENDFUNC fn_0800EE5E

@ -----------------------------------------------------------------------------
@ fn_0800EE6C - refusal pattern: 50-tick pulse, gap, pulse (3 phases), APO reloaded
@ Replaces : 0x0800EE6C FUN_0800EE6C (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0800EE6C
    movs r2, #50                            @ 0x0800EE6E
    movs r1, #3
    movs r0, #1
    b fn_0800EE7A
ENDFUNC fn_0800EE6C

@ -----------------------------------------------------------------------------
@ fn_0800EE7A - start a beep pattern
@ Replaces : 0x0800EE7A FUN_0800EE7A (v2.05)
@ In       : r0 = 1 reload the APO counter first; r1 = phase count; r2 = pulse length in TIM3 ticks
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : writes 0x2000807A, 0x20007FB6, then 0x20008079, 0x20007FB4 (fn_0800EEA8)
@ Note     : the four stores are made with interrupts masked, so bzb_tim3_isr never sees a half-written pattern
@            (DESIGN.md 3.4 ISR rules); the stored values and their order are those of v2.05
@ -----------------------------------------------------------------------------
LFUNC fn_0800EE7A
    movs r3, #BZB_KEY                       @ IMP-54: the patterns of v2.05's entries are key beeps
    b bzb_pattern
ENDFUNC fn_0800EE7A

@ -----------------------------------------------------------------------------
@ bzb_pattern - start a beep pattern of a class (fn_0800EE7A's work with the class of IMP-54)
@ In       : r0 = 1 reload the APO counter first; r1 = phase count; r2 = pulse length in TIM3 ticks;
@            r3 = class (BZB_KEY or BZB_FUNC)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : writes 0x2000807A, 0x20007FB6, bzb_class, then 0x20008079, 0x20007FB4 (bzb_pulse)
@ -----------------------------------------------------------------------------
LFUNC bzb_pattern
    push {r3, r4, r5, r6, r7, lr}
    uxtb r4, r0                             @ r4 = reload flag (v2.05 uxtb r4 at 0x0800EE82)
    mov r5, r1                              @ r5 = phases
    mov r6, r2                              @ r6 = pulse length
    mov r7, r3                              @ r7 = class (fn_0800ED26 clobbers r0-r3)
    cmp r4, #1
    bne .Lee7a_start
    bl fn_0800ED26                          @ APO reload (PWR) (0x0800EE88)
.Lee7a_start:
    CRIT_ENTER r4
    ldr r0, =v_2000807A
    strb r5, [r0]                           @ phases (0x0800EE90)
    ldr r0, =v_20007FB6
    strh r6, [r0]                           @ pulse length (0x0800EE96)
    ldr r0, =bzb_class
    strb r7, [r0]                           @ IMP-54: the class of this pattern's later phases (bzb_tim3_isr)
    uxth r0, r6
    mov r1, r7
    bl bzb_pulse                            @ 0x0800EE9C (fn_0800EEA8 with the class)
    CRIT_EXIT r4
    pop {r3, r4, r5, r6, r7, pc}
ENDFUNC bzb_pattern

@ -----------------------------------------------------------------------------
@ bzb_func_accept / bzb_func_double - fn_0800EE50's single beep and fn_0800EE6C's double beep as measurement beeps
@ (IMP-54: they sound with the setting qUiEt); APO reloaded as by v2.05's entries
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC bzb_func_accept
    movs r2, #100                           @ pulse 100 TIM3 ticks, as fn_0800EE50
    movs r1, #1
    movs r0, #1
    movs r3, #BZB_FUNC
    b bzb_pattern
ENDFUNC bzb_func_accept

FUNC bzb_func_double
    movs r2, #50                            @ 50-tick pulse, gap, pulse, as fn_0800EE6C
    movs r1, #3
    movs r0, #1
    movs r3, #BZB_FUNC
    b bzb_pattern
ENDFUNC bzb_func_double

@ -----------------------------------------------------------------------------
@ fn_0800EEA8 - start a pulse of r0 TIM3 ticks; PE7 high only if the buzzer setting is on
@ Replaces : 0x0800EEA8 FUN_0800EEA8 (v2.05), also called by MODE (0x0800D5AA)
@ In       : r0 = pulse length in TIM3 ticks
@ Out      : -
@ Clobbers : r1-r3
@ Context  : main
@ RAM      : writes 0x20008079 = 1, 0x20007FB4 = r0; reads 0x20008078
@ Note     : the stores are made with interrupts masked (DESIGN.md 3.4: 0x20007FB4 is also written by
@            bzb_tim3_isr); values and order as v2.05
@ -----------------------------------------------------------------------------
FUNC fn_0800EEA8
    movs r1, #BZB_KEY                       @ IMP-54: v2.05's entry is a key beep (also MODE 0x0800D5AA)
    b bzb_pulse
ENDFUNC fn_0800EEA8

@ -----------------------------------------------------------------------------
@ bzb_func_pulse - start a measurement pulse of r0 TIM3 ticks (IMP-54: sounds with the setting qUiEt)
@ In       : r0 = pulse length in TIM3 ticks
@ Out      : -
@ Clobbers : r1-r3
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC bzb_func_pulse
    movs r1, #BZB_FUNC
    b bzb_pulse
ENDFUNC bzb_func_pulse

@ -----------------------------------------------------------------------------
@ bzb_pulse - start a pulse of r0 TIM3 ticks of class r1; PE7 high when the setting lets the class sound
@ (fn_0800EEA8's work with the class of IMP-54)
@ In       : r0 = pulse length in TIM3 ticks; r1 = class (BZB_KEY or BZB_FUNC)
@ Out      : -
@ Clobbers : r1-r3
@ Context  : main
@ RAM      : writes 0x20008079 = 1, 0x20007FB4 = r0; reads 0x20008078 (bzb_class is left to bzb_pattern: a single pulse in
@            the gap of a pattern does not change the class of the pattern's later phases)
@ Note     : the stores are made with interrupts masked (DESIGN.md 3.4: 0x20007FB4 is also written by bzb_tim3_isr,
@            which reads bzb_class for the phases that follow); values and order of v2.05's stores kept.
@            Setting 1 b-On: PE7 high; 2 qUiEt: PE7 high for a measurement pulse only; 0 b-OFF (or any other value):
@            silent pulse
@ -----------------------------------------------------------------------------
LFUNC bzb_pulse
    push {r4, lr}
    mov r4, r1                              @ r4 = class of this pulse
    CRIT_ENTER r3                           @ the stores form one update for bzb_tim3_isr
    movs r1, #1
    ldr r2, =v_20008079
    strb r1, [r2]                           @ 0x0800EEAE
    ldr r1, =v_20007FB4
    strh r0, [r1]                           @ 0x0800EEB4
    ldr r1, =v_20008078
    ldrb r1, [r1]                           @ r1 = buzzer setting
    cmp r1, #BZB_SET_ON
    beq .Leea8_sound                        @ b-On: every beep
    cmp r1, #BZB_SET_QUIET
    bne .Leea8_done                         @ b-OFF: silent pulse
    cbz r4, .Leea8_done                     @ qUiEt: a key pulse stays silent
.Leea8_sound:
    movs r1, #BZB_PE7
    ldr r2, =(GPIOE_BASE + GPIO_BSRRL)
    strh r1, [r2]                           @ PE7 high (0x0800EEC6)
.Leea8_done:
    CRIT_EXIT r3
    pop {r4, pc}
ENDFUNC bzb_pulse

@ -----------------------------------------------------------------------------
@ pe7_on_with_timeout - start a pulse of r0 TIM3 ticks with PE7 high regardless of the buzzer setting
@ Replaces : 0x0800EED0 pe7_on_with_timeout (v2.05)
@ Note     : OF-63: kept for the beeps that sound with the buzzer setting off: continuity (mres/beep.s) and the jack and
@            high-voltage warnings (sys_tim2_isr); the diode, auto-hold capture and auto power-off warning beeps use the
@            gated fn_0800EEA8 since OF-63
@ In       : r0 = pulse length in TIM3 ticks
@ Out      : -
@ Clobbers : r1-r3
@ Context  : ISR-safe (called by sys_tim2_isr and by main); the stores are made with interrupts masked, so
@            bzb_tim3_isr never sees half of them (DESIGN.md 3.4)
@ RAM      : writes 0x20008079 = 1, 0x20007FB4 = r0
@ -----------------------------------------------------------------------------
FUNC pe7_on_with_timeout
    CRIT_ENTER r3                           @ the three stores form one update for bzb_tim3_isr
    movs r1, #1
    ldr r2, =v_20008079
    strb r1, [r2]                           @ 0x0800EED6
    ldr r1, =v_20007FB4
    strh r0, [r1]                           @ 0x0800EEDC
    movs r1, #BZB_PE7
    ldr r2, =(GPIOE_BASE + GPIO_BSRRL)
    strh r1, [r2]                           @ PE7 high (0x0800EEE4)
    CRIT_EXIT r3
    bx lr
ENDFUNC pe7_on_with_timeout

@ -----------------------------------------------------------------------------
@ bzb_off_beep_start - "-oFF-" on the display and PE7 high (start of the 1 s power-off beep)
@ Replaces : 0x08024F06..0x08024F14 of pe7_on_blocking_100_ticks (v2.05)
@ Note     : OF-63: PE7 only while the buzzer setting (0x20008078) is on; v2.05 sets it regardless (0x08024F14)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Deviation: IMP-06 (state-machine form)
@ -----------------------------------------------------------------------------
FUNC bzb_off_beep_start
    push {r3, lr}
    bl fn_08017092                          @ "-oFF-" (UI) (0x08024F0C)
    ldr r0, =v_20008078
    ldrb r0, [r0]
    cbz r0, 1f                              @ OF-63: b-OFF: the 1 s of "-oFF-" stays, silent; b-On and qUiEt sound
                                            @ (a measurement beep, IMP-54)
    GPIO_SET GPIOE_BASE, BZB_PE7            @ PE7 high (0x08024F14)
1:
    movs r0, #0
    ldr r1, =bzb_off_beep_count
    strb r0, [r1]                           @ tick counter r5 of v2.05 (0x08024F08)
    pop {r3, pc}
ENDFUNC bzb_off_beep_start

@ -----------------------------------------------------------------------------
@ bzb_off_beep_step - consume one 10 ms flag; after 100 of them PE7 low
@ Replaces : 0x08024F16..0x08024F34 of pe7_on_blocking_100_ticks (v2.05)
@ In       : -
@ Out      : r0 = 0 busy, 1 done (PE7 low)
@ Clobbers : r0-r3, flags
@ Context  : main
@ RAM      : 0x200080D0 (10 ms flag of sys_tim2_isr, cleared when consumed), bzb_off_beep_count
@ Deviation: IMP-06 (state-machine form)
@ -----------------------------------------------------------------------------
FUNC bzb_off_beep_step
    ldr r1, =v_200080D0
    ldrb r0, [r1]
    cbz r0, .Lobs_busy                      @ no new tick yet
    movs r0, #0
    strb r0, [r1]                           @ consume the flag (0x08024F22)
    ldr r1, =bzb_off_beep_count
    ldrb r0, [r1]
    adds r0, r0, #1
    strb r0, [r1]                           @ 0x08024F24
    uxtb r0, r0
    cmp r0, #BZB_OFF_BEEP_TICKS
    blt .Lobs_busy                          @ 0x08024F2A
    GPIO_CLR GPIOE_BASE, BZB_PE7            @ PE7 low (0x08024F34)
    movs r0, #1
    bx lr
.Lobs_busy:
    movs r0, #0
    bx lr
ENDFUNC bzb_off_beep_step

@ -----------------------------------------------------------------------------
@ pe7_on_blocking_100_ticks - "-oFF-" and PE7 high for 100 TIM2 ticks (1 s), blocking
@ Replaces : 0x08024F06 pe7_on_blocking_100_ticks (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (enter_stop_and_reinit, baseline builds)
@ Note     : waits on the 10 ms flag set by sys_tim2_isr, as v2.05 (0x08024F16); TIM2 runs at this point
@ -----------------------------------------------------------------------------
FUNC pe7_on_blocking_100_ticks
    push {r3, lr}
    bl bzb_off_beep_start
.Lpob_wait:
    bl bzb_off_beep_step
    cmp r0, #0
    beq .Lpob_wait
    pop {r3, pc}
ENDFUNC pe7_on_blocking_100_ticks

@ -----------------------------------------------------------------------------
@ bzb_silence - stop every beep: pattern state cleared and PE7 low
@ Replaces : - (new, HW-08)
@ In/Out   : - / -
@ Clobbers : r0-r2
@ Context  : main, sys_fault_safe
@ RAM      : 0x20007FB4 = 0, 0x2000807A = 0, 0x20008079 = 0
@ Spec     : DESIGN.md 3.6 HW-08, 4.5, 4.7
@ Deviation: HW-08
@ -----------------------------------------------------------------------------
FUNC bzb_silence
    CRIT_ENTER r2
    movs r0, #0
    ldr r1, =v_20007FB4
    strh r0, [r1]                           @ no pulse in progress
    ldr r1, =v_2000807A
    strb r0, [r1]                           @ no further phases
    ldr r1, =v_20008079
    strb r0, [r1]                           @ buzzer off
    movs r0, #BZB_PE7
    ldr r1, =(GPIOE_BASE + GPIO_BSRRH)
    strh r0, [r1]                           @ PE7 low
    CRIT_EXIT r2
    bx lr
ENDFUNC bzb_silence

    .ltorg
