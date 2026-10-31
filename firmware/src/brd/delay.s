@ =============================================================================
@ delay.s - BRD: the v2.05 busy delay loop
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"

    .section .text.brd.delay, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800ECF6 - busy delay of r0 loop iterations
@ Replaces : 0x0800ECF6 FUN_0800ECF6 (v2.05), instruction for instruction (the HY3131 and NJU6350 bit timing
@            and the counter restart delay depend on it: DESIGN.md 4.1 item 9)
@ In       : r0 = iteration count (unsigned; 0 = return at once)
@ Out      : -
@ Clobbers : r1, r2, flags
@ Context  : ISR-safe (pure loop)
@ -----------------------------------------------------------------------------
FUNC fn_0800ECF6
    movs r2, #0                             @ v2.05 0x0800ECF6
    movs r1, r2                             @ counter = 0
.Lecf6_loop:
    cmp r1, r0
    bcs .Lecf6_done                         @ counter >= count (unsigned)
    nop                                     @ v2.05 0x0800ECFE
    adds r1, r1, #1
    b .Lecf6_loop
.Lecf6_done:
    bx lr
ENDFUNC fn_0800ECF6
