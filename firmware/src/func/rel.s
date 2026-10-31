@ =============================================================================
@ rel.s - FUNC: relative (REL) mode
@
@ Port of the v2.05 function fn_0800E594 (v2.05 FUN_0800e594): while REL is on, the reading is replaced by the reading
@ minus a base value that is taken from the first result after REL was switched on.
@
@ REL in v2.05 (analysis/keys_setup.md section 2): the REL short press toggles rel_active (0x20008058) and sets the
@ "base pending" flag 0x20008059 (written by KEY); fn_0800DCFC calls this function for every result.
@
@ Calling convention (AAPCS, DESIGN.md 6): r0-r2 and the flags are scratch.  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"

    .section .text.func, "ax", %progbits


    .equ func_reading,      v_20007D64   @ displayed value in counts (s32)
    .equ func_mm_last,      v_20007D9C   @ last recorded MIN/MAX reading (s32)
    .equ func_rel_base,     v_20007DA8   @ s32, the REL base value
    .equ func_ol_flag,      v_20008046   @ overload flag (u8)
    .equ func_rel_pending,  v_20008059   @ u8, set by KEY when REL is switched on: the next result becomes the base

@ -----------------------------------------------------------------------------
@ fn_0800E594 - apply REL to the reading
@ Replaces : 0x0800E594 (v2.05 FUN_0800e594)
@ In       : none (state in RAM)
@ Out      : none (reading := reading - rel_base while REL is on, HOLD is off and there is no overload)
@ Clobbers : r0-r2, flags
@ Context  : main
@ RAM      : reads hold_active, rel_active, func_ol_flag, func_rel_pending, minmax_state, func_reading, func_mm_last; writes func_rel_pending, func_rel_base, func_reading
@ Spec     : analysis/keys_setup.md section 2 (REL)
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0800E594
    ldr r1, =hold_active                   @ hold_active
    ldrb r1, [r1, #0]                      @ r1 = hold_active
    cmp r1, #0
    bne .Lrel_0800E5FC                     @ HOLD on: leave the reading alone
    ldr r1, =rel_active                    @ rel_active
    ldrb r1, [r1, #0]                      @ r1 = rel_active
    cmp r1, #0
    beq .Lrel_0800E5FC                     @ REL off: nothing to do
    ldr r1, =func_ol_flag                  @ ol_flag
    ldrb r1, [r1, #0]                      @ r1 = func_ol_flag
    cmp r1, #0
    bne .Lrel_0800E5FC                     @ overload: leave the reading alone
    ldr r1, =func_rel_pending              @ rel_pending
    ldrb r1, [r1, #0]                      @ r1 = func_rel_pending
    cmp r1, #0
    beq .Lrel_0800E5E6                     @ no base pending: subtract the base
    movs r1, #0                            @ clear the pending flag ...
    ldr r2, =func_rel_pending
    strb r1, [r2, #0]                      @ func_rel_pending = r1
    ldr r1, =minmax_state                  @ minmax_state
    ldrb r1, [r1, #0]                      @ r1 = minmax_state
    cmp r1, #0
    beq .Lrel_0800E5DA                     @ MIN/MAX off: the base is the current reading
    ldr r1, =func_mm_last                  @ MIN/MAX on: the base is the last recorded MIN/MAX reading ...
    ldr r1, [r1, #0]                       @ r1 = func_mm_last
    ldr r2, =func_rel_base                 @ ... store it
    str r1, [r2, #0]                       @ func_rel_base = r1
    b .Lrel_0800E5E6
    @ MIN/MAX off: base = reading.
.Lrel_0800E5DA:
    ldr r1, =func_reading
    ldr r1, [r1, #0]                       @ r1 = func_reading
    ldr r2, =func_rel_base
    str r1, [r2, #0]                       @ func_rel_base = r1
    @ Subtract the base.
.Lrel_0800E5E6:
    ldr r1, =func_reading                  @ reading
    ldr r1, [r1, #0]                       @ r1 = func_reading
    ldr r2, =func_rel_base                 @ base
    ldr r2, [r2, #0]                       @ r2 = func_rel_base
    subs r1, r1, r2                        @ reading - base
    movs r0, r1
    ldr r1, =func_reading                  @ store
    str r0, [r1, #0]                       @ func_reading = r0
    @ Return.
.Lrel_0800E5FC:
    bx lr
ENDFUNC fn_0800E594
    .ltorg

