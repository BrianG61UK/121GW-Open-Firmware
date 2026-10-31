@ =============================================================================
@ post.s - FUNC: per-result post-processing
@
@ Port of the v2.05 functions
@   fn_0800DCFC  post-processing of a new result: auto-range, HV flags, HOLD, MIN/MAX, REL, overload latches (v2.05 FUN_0800DCFC)
@   fn_0800E278  latch the overload flag for the log (v2.05 FUN_0800E278)
@
@ The main loop (DESIGN.md 3.5 step 2) calls fn_0800DCFC when the new-result flag 0x2000805D is set.  The order of the
@ calls is the v2.05 order.  autorange_step belongs to AR (DESIGN.md 6.12); fn_0800E848 belongs to UI.
@
@ Calling convention (AAPCS, DESIGN.md 6): r0-r3, r12 and the flags are scratch.  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"

    .section .text.func, "ax", %progbits


    .equ func_settle_count, v_20000238   @ settle count set at every mode/range apply (u8); non-zero while the range settles
    .equ func_ol_flag,      v_20008046   @ overload flag (u8)
    .equ func_ol_ble,       v_20008048   @ u8, copy of the overload flag for the BLE packet (ble_packet.md byte 6)
    .equ func_ol_log,       v_20008049   @ u8, copy of the overload flag for the log record (autorange_and_scheduler.md, log record)

@ -----------------------------------------------------------------------------
@ fn_0800DCFC - post-process a new result
@ Replaces : 0x0800DCFC (v2.05 FUN_0800dcfc)
@ In       : none (state in RAM)
@ Out      : none
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : reads func_settle_count, func_ol_flag; writes func_ol_ble, func_ol_log (through fn_0800E278)
@ Spec     : DESIGN.md 3.5 step 2, 6.6
@ Deviation: none (copy of the v2.05 sequence); the loop modes of DESIGN.md 3.5 do not change it
@ -----------------------------------------------------------------------------
FUNC fn_0800DCFC
    push {r7, lr}                          @ save r7 (stack alignment) and the return address
    bl autorange_step                      @ auto-range decision (AR)
    ldr r0, =func_settle_count             @ settle count
    ldrb r0, [r0, #0]                      @ r0 = func_settle_count
    cmp r0, #0                             @ count = 0?
    bne .Lpost_0800DD10                    @ not zero: skip the high-voltage test
    bl fn_0800E848                         @ settle count zero: UI test that sets the HV/overload flag of the VA modes (fn_0800E848)
    @ HOLD, MIN/MAX and REL in the v2.05 order.
.Lpost_0800DD10:
    bl fn_0800E30C                         @ auto-hold evaluation
    bl fn_0800E604                         @ MIN/MAX/AVG recording
    bl fn_0800E594                         @ REL
    ldr r0, =func_ol_flag                  @ overload flag
    ldrb r0, [r0, #0]                      @ r0 = func_ol_flag
    cmp r0, #0                             @ overload?
    beq .Lpost_0800DD30                    @ no: clear the BLE copy
    movs r0, #1                            @ yes: BLE copy = 1
    ldr r1, =func_ol_ble
    strb r0, [r1, #0]                      @ func_ol_ble = r0
    b .Lpost_0800DD38                      @ common exit
    @ No overload: BLE copy = 0.
.Lpost_0800DD30:
    movs r0, #0
    ldr r1, =func_ol_ble
    strb r0, [r1, #0]                      @ func_ol_ble = r0
    @ Log latch.
.Lpost_0800DD38:
    bl fn_0800E278                         @ latch the overload flag for the log (fn_0800E278)
    pop {r0, pc}                           @ restore r7 (not used) and return
ENDFUNC fn_0800DCFC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800E278 - latch the overload flag for the log
@ Replaces : 0x0800E278 (v2.05 FUN_0800e278)
@ In       : none
@ Out      : none (ol_log := (ol_flag != 0))
@ Clobbers : r0, r1, flags
@ Context  : main
@ RAM      : reads func_ol_flag; writes func_ol_log
@ Spec     : analysis/autorange_and_scheduler.md (log record)
@ Deviation: none (copy of the v2.05 sequence)
@ -----------------------------------------------------------------------------
FUNC fn_0800E278
    ldr r0, =func_ol_flag                  @ overload flag
    ldrb r0, [r0, #0]                      @ r0 = func_ol_flag
    cmp r0, #0                             @ overload?
    beq .Lolatch_0800E28C                  @ no: clear the log copy
    movs r0, #1                            @ yes: log copy = 1
    ldr r1, =func_ol_log
    strb r0, [r1, #0]                      @ func_ol_log = r0
    b .Lolatch_0800E294
    @ No overload: log copy = 0.
.Lolatch_0800E28C:
    movs r0, #0
    ldr r1, =func_ol_log
    strb r0, [r1, #0]                      @ func_ol_log = r0
    @ Return.
.Lolatch_0800E294:
    bx lr
ENDFUNC fn_0800E278
    .ltorg

