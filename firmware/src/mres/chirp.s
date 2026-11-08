@ =============================================================================
@ chirp.s - MRES: the DIODE contact chirp (production image only, DESIGN.md 10 IMP-51, FEATURES.md 2.25)
@
@ v2.05's DIODE chirp (mres/diode.s, 0x08007F20..0x08007F60) reports a jump: a double beep whenever a mean differs by
@ more than 1000 counts from the last reference, at most once per lockout.  Touching a diode therefore beeps, lifting the
@ probes beeps, and a settling or drifting reading can beep again.  With the page CHIrP on (set_chirp_on = 1, set/chirp.s)
@ diode.s calls mres_chirp_mean in place of that rule, and the double beep reports a contact instead: one beep per
@ diode connected, nothing while it stays connected, nothing at the open leads or a reverse diode (overload) and nothing
@ when the probes are lifted.  Off (default) leaves v2.05's rule and its RAM (0x20007CD4, 0x200080B4) untouched.  The
@ short-circuit tone (IMP-04) is unchanged either way.  Idea: GitHub PR 22.
@
@ Each mean D (0x20007D64, display counts, divided by 10 on 15 V) falls in one region:
@   short   -999 .. 999 (v2.05's short-circuit window)
@   open    |D| >= the full scale 0x20007D60 (30000 on 3 V, 15000 on 15 V; the reading shows OL)
@   diode   everything else
@ CHIRP_CONFIRM means in a row in the diode region confirm a contact: one double beep (fn_0800EE6C, which the buzzer
@ setting gates, OF-63), then silence ("latched") until CHIRP_REARM means in a row in the short or open region have
@ ended the contact.  A mean takes about 0.1 s in DIODE, so both are about 0.2 s: a brief bounce of the probe neither
@ ends the contact nor gives a second beep.  The RANGE key (3 V / 15 V) keeps the state: a diode still connected after it
@ beeps again only if its reading on the new range passed through the short or open region for CHIRP_REARM means.
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

    .equ CHIRP_CONFIRM, 2                   @ means in the diode region that confirm a contact
    .equ CHIRP_REARM,   2                   @ means in the short or open region that end it
    .equ CHIRP_WINDOW,  999                 @ the short-circuit window -999 .. 999 (v2.05 0x08007EFA, 0x08007F04)
    .equ chirp_mean,    v_20007D64          @ the smoothed mean D (display counts)
    .equ chirp_fs,      v_20007D60          @ the full scale of the range (load_full_scale)

    .section .bss_port.mres, "aw", %nobits
@ chirp_state, zero at reset and after mres_chirp_reset (no contact yet, the next confirmed contact beeps):
@   +0 latched  1 = this contact has beeped
@   +1 in       means in a row in the diode region (0 .. CHIRP_CONFIRM)
@   +2 away     means in a row in the short or open region (0 .. CHIRP_REARM)
    .equ CS_LATCHED, 0
    .equ CS_IN,      1
    .equ CS_AWAY,    2
chirp_state:    .space 3

    .section .text.mres.chirp, "ax", %progbits

@ -----------------------------------------------------------------------------
@ mres_chirp_mean - one mean of the contact chirp
@ Replaces : nothing in v2.05 (new; takes the place of the jump rule 0x08007EF6..0x08007F60 while set_chirp_on = 1)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_08007E84, the mean branch of DIODE)
@ RAM      : reads 0x20007D64, 0x20007D60; reads and writes chirp_state
@ -----------------------------------------------------------------------------
FUNC mres_chirp_mean
    push {r4, lr}
    ldr r0, =chirp_mean
    ldr r0, [r0]                            @ D
    cmp r0, #0
    it lt
    neglt r0, r0                            @ |D|
    movw r1, #CHIRP_WINDOW
    cmp r0, r1
    bls .Lcm_away                           @ |D| <= 999: short
    ldr r1, =chirp_fs
    ldr r1, [r1]
    cmp r0, r1
    bge .Lcm_away                           @ |D| >= full scale: open leads or a reverse diode
    @ diode region
    ldr r4, =chirp_state
    movs r0, #0
    strb r0, [r4, #CS_AWAY]                 @ away = 0: the contact goes on
    ldrb r0, [r4, #CS_LATCHED]
    cbnz r0, .Lcm_done                      @ latched: this contact has beeped
    ldrb r0, [r4, #CS_IN]
    adds r0, r0, #1
    strb r0, [r4, #CS_IN]                   @ in + 1
    cmp r0, #CHIRP_CONFIRM
    blo .Lcm_done
    movs r0, #1
    strb r0, [r4, #CS_LATCHED]              @ latched
    movs r0, #0
    strb r0, [r4, #CS_IN]
    bl bzb_func_double                      @ the double beep (v2.05's chirp; OF-63 gated, IMP-54: sounds with qUiEt)
    b .Lcm_done
.Lcm_away:
    ldr r4, =chirp_state
    movs r0, #0
    strb r0, [r4, #CS_IN]                   @ in = 0: no contact being confirmed
    ldrb r0, [r4, #CS_AWAY]
    cmp r0, #CHIRP_REARM
    bhs .Lcm_rearm
    adds r0, r0, #1
    strb r0, [r4, #CS_AWAY]                 @ away + 1 (stops at CHIRP_REARM)
    cmp r0, #CHIRP_REARM
    blo .Lcm_done
.Lcm_rearm:
    movs r0, #0
    strb r0, [r4, #CS_LATCHED]              @ the contact has ended: the next one beeps
.Lcm_done:
    pop {r4, pc}
ENDFUNC mres_chirp_mean

@ -----------------------------------------------------------------------------
@ mres_chirp_reset - no contact yet: the next confirmed contact beeps
@ Replaces : nothing in v2.05 (new)
@ In/Out   : - / -
@ Clobbers : r0, r1
@ Context  : main only (meter_apply_mode_range when DIODE is entered; set_chirp_load, set_chirp_edit; bftset.s after a
@            Bluetooth PUT of the setting)
@ RAM      : writes chirp_state (v2.05's jump-chirp RAM is not touched)
@ -----------------------------------------------------------------------------
FUNC mres_chirp_reset
    ldr r1, =chirp_state
    movs r0, #0
    strb r0, [r1, #CS_LATCHED]
    strb r0, [r1, #CS_IN]
    strb r0, [r1, #CS_AWAY]
    bx lr
ENDFUNC mres_chirp_reset

    .ltorg
