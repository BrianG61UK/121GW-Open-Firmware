@ =============================================================================
@ tctype.s - MTMP: selectable thermocouple type K, J or T (production image only, DESIGN.md 10 IMP-10, FEATURES.md 2.8)
@
@ v2.05 converts the thermocouple EMF with the type K table 0x08025CF8 (fn_08013C40) and turns the board temperature into
@ the cold-junction EMF with the same table (fn_08013CF8).  The port selects the table with mtmp_tc_type; both routines take
@ the table and the input window from the descriptor of the type.  Every table has the shape of the K table (s32 uV at
@ (10 k - 210) degC, entry 21 = 0 degC), so the index arithmetic of both routines is unchanged.
@
@ Input window (x = EMF + cold junction, in uV; outside it the reading is " OFL " / "-OFL" through 0x200080AD):
@     type  table                 x >= (low)   x < (high)   temperature span
@     K     v205_tab_08025CF8     -5891        54139        -200 .. 1350 degC   (v2.05: 0x08013C4C, 0x08013C60)
@     J     mtmp_tc_tab_j         -7890        54139        -200 .. 936 degC
@     T     mtmp_tc_tab_t         -5603        20873        -200 .. 400 degC
@ The low limit is entry 1 (-200 degC) for every type, as for K.  The high limit of J is the K limit 54139 uV: TEMP measures
@ on the DCmV 50 mV input (analysis/frontend_models.md 3.6), and v2.05 accepts no EMF above 54138 uV, so no larger input
@ voltage is taken as measurable (J reaches 54138 uV at 936 degC and 69553 uV at 1200 degC).  T ends at its last entry,
@ 400 degC (20872 uV), the end of the NIST T range.  The table search (fn_08013C40) finds an entry >= x for every x below
@ the high limit: J 940 degC = 54347 uV, T 400 degC = 20872 uV.
@ The cold-junction routine reads entries 18..32 (-30..110 degC), present in every table.
@
@ Not present in the strict image (LOOP_V205 = 1): this file assembles to nothing there.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .if LOOP_V205 == 0

    .section .bss_port.mtmp, "aw", %nobits
    .balign 4
@ mtmp_tc_descp: address of the descriptor of the selected type (written only by mtmp_tc_select; read by fn_08013C40 and
@ fn_08013CF8, which run in the main loop, after set_state_reset has selected the type at boot and wake)
    .global mtmp_tc_descp
mtmp_tc_descp:  .space 4
@ mtmp_tc_type: thermocouple type 0 = K, 1 = J, 2 = T; loaded from EEPROM 0x00F at boot and wake, edited on the SETUP page
@ tc (written only by mtmp_tc_select)
    .global mtmp_tc_type
mtmp_tc_type:   .space 1

    .section .rodata.mtmp.tctype, "a", %progbits
    .balign 4
@ mtmp_tc_descs: per type the table address, the low limit (x >= low) and the high limit (x < high), 12 bytes each
mtmp_tc_descs:
    .word v205_tab_08025CF8, -5891, 54139   @ 0: K (v2.05)
    .word mtmp_tc_tab_j,     -7890, 54139   @ 1: J
    .word mtmp_tc_tab_t,     -5603, 20873   @ 2: T
    .size mtmp_tc_descs, . - mtmp_tc_descs

    .section .text.mtmp.tctype, "ax", %progbits

@ -----------------------------------------------------------------------------
@ mtmp_tc_select - select the thermocouple type
@ Replaces : nothing in v2.05 (new)
@ In       : r0 = type (0 K, 1 J, 2 T; any other value selects K)
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : main only (set_tc_load, set_tc_edit)
@ RAM      : writes mtmp_tc_type, mtmp_tc_descp
@ Note     : Writer and readers all run in the main context, so the two variables are never seen half updated.
@ -----------------------------------------------------------------------------
FUNC mtmp_tc_select
    cmp r0, #2
    bls 1f
    movs r0, #0                             @ out of range: K
1:  ldr r1, =mtmp_tc_type
    strb r0, [r1]
    add r0, r0, r0, lsl #1                  @ type * 3
    ldr r1, =mtmp_tc_descs
    add r0, r1, r0, lsl #2                  @ descriptor = table base + type * 12
    ldr r1, =mtmp_tc_descp
    str r0, [r1]
    bx lr
ENDFUNC mtmp_tc_select

    .ltorg

    .endif
