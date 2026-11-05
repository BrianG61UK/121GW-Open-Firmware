@ =============================================================================
@ bootwin.s - CAL module: the power-on window (BOOTWIN)
@
@ v2.05 FUN_0800EA3A (called by main 0x08024B66 and after STOP 0x08024F00; analysis/keys_setup.md 3): front-end
@ pins as mode 0, splash "V-205", window counter 0x2000022E = 2000 TIM3 ticks (decremented by IRQ29), first
@ HY3131 transaction (TEMP row, mode 5 range 0), then on each 10 ms flag the key processing FUN_0801680C, whose
@ window branches set the sequence states A = 0x200080CD and B = 0x200080CE; the loop acts on them:
@   A = 1  screen " CAL1"/" CAL ";  A = 2  calibration mode (MODE then REL);  A = 3  date-code editing (SETUP)
@   B = 1  "SdCAL";  B = 2  "SdSAv" / "SdSEt";  B = 3  cal.bin save or load, then "SAvEd" or "-Err-" and B = 4
@ It leaves when the counter is 0 and B != 4 (B = 4 is terminal) or on A = 2 / A = 3.
@ Port (DESIGN.md 7.1):
@   fn_0800EA3A   the v2.05 loop, blocking: no caller in this build (the v2.05-structured build is on the branch
@                 like-v2.05); left in place so that this image stays byte-identical to the one verified on a meter
@   bootwin_start the prologue (same pins, counter, HY3131 row; the version on the sub display instead of the splash, IMP-35)
@   bootwin_step  one non-blocking pass for the production loop (IMP-02): the main loop runs
@                 the key processing in its step 4 and calls bootwin_step once per pass until it returns 1;
@                 cal.bin runs as the calbin state machine, one step per pass
@ OF-08: the MODE-then-REL path sets calibration mode (0x2000808A = 1, 0x20008062 = 1) and writes nothing to
@ the EEPROM (v2.05 called current_extra_erase_all at 0x0800EAF6).
@ Context: main.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    @ Safety margin before the first HY3131 write (DESIGN.md 7.1: never earlier than v2.05).  Measured in the emulator with
    @ the Cortex-M3 cycle costs (emulator/emu/cycles.py, 2026-11-01; scenario boot_v, end of the 20-byte TEMP row frame):
    @ v2.05 82.27 ms after reset; the port without the margin 83.16 ms (baseline) / 82.83 ms (production), with it 84.86 ms /
    @ 84.53 ms.  The 1000 iterations of fn_0800ECF6 take 1.70 ms (about 7 cycles each at 4.194 MHz: cmp, bcs not taken, nop,
    @ adds, taken b with its refill and flash wait state, plus the timer interrupts that fall into them).  The port's start-up
    @ (OPT-01: copy instead of lz77 unpack) is not slower than v2.05's on the device, where every path only gets longer, so
    @ the margin is kept: the first write comes 2.26..2.59 ms after v2.05's in the emulator and never before it.
    .equ BW_HY_MARGIN_LOOPS, 1000
    .equ BW_A,  v_200080CD                  @ window sequence state A (MODE / SETUP path)
    .equ BW_B,  v_200080CE                  @ window sequence state B (MEM path)

    .section .bss_port.cal, "aw", %nobits
    .global bootwin_active
bootwin_active: .space 1                    @ 1 from bootwin_start until the window closes (for UI, IMP-02)
bootwin_cb:     .space 1                    @ 1 while a stepped cal.bin operation runs (bootwin_step)

    .section .text.cal, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800EA3A - power-on window, blocking (v2.05 form)
@ Replaces : 0x0800EA3A
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main (sys_main in the baseline build, enter_stop_and_reinit)
@ RAM      : 0x2000022E, 0x200080CD, 0x200080CE, 0x200080D0, 0x20008088, 0x20008089, 0x2000808A, 0x2000808B,
@            0x20008062, 0x200080DD, 0x200080B3, bootwin_active
@ Spec     : analysis/keys_setup.md 3; DESIGN.md 7.1
@ Deviation: OF-08
@ -----------------------------------------------------------------------------
FUNC fn_0800EA3A
    push {r4, lr}
    bl bootwin_start
1:  bl bootwin_exit_due                     @ counter 0 and B != 4 (0x0800EA8E..0x0800EAA0)
    cbnz r0, 3f
    bl lcd_commit_retry                     @ IMP-06: this loop stays blocking and never reaches fn_08016D34, so it repeats a
                                            @ commit deferred while UDR was set (the splash right after lcd_init); production
                                            @ calls this routine from no caller (sys_bootwin_begin uses bootwin_start), W3_to_W7.md 4
    ldr r1, =v_200080D0
    ldrb r0, [r1]
    cmp r0, #0
    beq 1b                                  @ wait for the 10 ms flag (0x0800EAA4..0x0800EAAC)
    movs r0, #0
    strb r0, [r1]                           @ clear it (0x0800EAB4)
    bl fn_0801680C                          @ key processing (0x0800EAB6)
    movs r0, #1                             @ cal.bin blocking
    bl bootwin_dispatch
    cmp r0, #0
    beq 1b
3:  bl bootwin_exit
    pop {r4, pc}
ENDFUNC fn_0800EA3A

@ -----------------------------------------------------------------------------
@ bootwin_start - open the power-on window
@ Replaces : 0x0800EA3A..0x0800EA8A (prologue of FUN_0800EA3A)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main (sys_main, enter_stop_and_reinit)
@ RAM      : writes 0x200080B3 = 0, 0x2000022E = BOOTWIN_TICKS, bootwin_active = 1, bootwin_cb = 0, cal_cache, cal_cache_valid
@            (cal_cache_load, OPT-08)
@ -----------------------------------------------------------------------------
FUNC bootwin_start
    push {r4, lr}
    movs r1, #0
    movs r0, #0
    bl fn_0800FE00                          @ front-end pins as mode 0 without FUN_0800FC60 (0x0800EA40)
    ldr r1, =v_200080B3
    movs r0, #0
    strb r0, [r1]                           @ DIODE 15 V flag = 0 (0x0800EA4A)
    movs r0, #0
    bl fn_0800FD30
    movs r0, #0
    bl fn_0800FD80
    movs r0, #0
    bl fn_0800FDB0
    movs r0, #0
    bl fn_0800FDD0
    movs r1, #0
    movs r0, #0
    bl fn_0800FE14
    movs r1, #0
    movs r0, #0
    bl fn_0800FE74                          @ (0x0800EA70)
    bl cal_cache_load                       @ OPT-08: EEPROM 0x000..0x4FF into the cache.  Loaded here, before the splash: the
                                            @ splash routine waits for the end of lcd_init's display update (boot_v, v2.05:
                                            @ 66.23 -> 80.17 ms), which takes far longer than the copy (1.78 ms), so the copy
                                            @ adds no time to the start-up (before lcd_init it delayed the LCD start and every
                                            @ later event; DESIGN.md 3.2 step 5).  Every reader before this point
                                            @ (set_state_reset, lcd_init) reads the EEPROM itself (cal_cache_valid = 0).
    @ IMP-35: v2.05 calls the splash FUN_0801A854 here (0x0800EA74, "V-2.05" on the main display); the port shows the
    @ version on the sub display only, as during the rest of the window (IMP-02)
    bl fn_0801A81C                          @ clear the shadow (as the splash did first)
    bl ui_version_sub                       @ the version on the sub display, commit request
    bl lcd_commit_shadow
    bl lcd_commit_flush                     @ production: wait as v2.05's commit does until the splash is written, so the
                                            @ first HY3131 write below is not earlier than in v2.05 (DESIGN.md 7.1)
    ldr r1, =v_2000022E
    movw r0, #BOOTWIN_TICKS
    strh r0, [r1]                           @ window counter (0x0800EA84; halfword store is atomic for IRQ29)
    ldr r1, =bootwin_active
    movs r0, #1
    strb r0, [r1]
    movs r0, #0
    strb r0, [r1, #1]                       @ bootwin_cb = 0
    movw r0, #BW_HY_MARGIN_LOOPS
    bl fn_0800ECF6                          @ safety margin: the first HY3131 write never comes earlier than in v2.05 (7.1)
    movs r1, #0
    movs r0, #5
    bl fn_0800B974                          @ TEMP row, first HY3131 transaction (0x0800EA8A)
    pop {r4, pc}
ENDFUNC bootwin_start

@ -----------------------------------------------------------------------------
@ bootwin_step - one pass of the power-on window for the production loop
@ Replaces : one pass of the loop 0x0800EA8E..0x0800EBDE without the 10 ms wait and the key processing,
@            which the main loop runs in its step 4 (IMP-02)
@ In       : -
@ Out      : r0 = 0 window open, 1 closed (also for every call after it closed: no further action)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (sys_main, once per pass while it returned 0)
@ Deviation: IMP-02, IMP-06 (cal.bin as state machine)
@ -----------------------------------------------------------------------------
FUNC bootwin_step
    push {r4, lr}
    ldr r4, =bootwin_active
    ldrb r0, [r4]
    cbz r0, 2f                              @ already closed
    ldrb r0, [r4, #1]                       @ bootwin_cb: a stepped cal.bin operation is running; v2.05 runs it
    cbnz r0, 4f                             @ inside one loop pass, so the window cannot end before it is done
    bl bootwin_exit_due
    cbnz r0, 1f
4:  movs r0, #0                             @ cal.bin stepped
    bl bootwin_dispatch
    cbz r0, 3f
1:  bl bootwin_exit
2:  movs r0, #1
    pop {r4, pc}
3:  movs r0, #0
    pop {r4, pc}
ENDFUNC bootwin_step

@ -----------------------------------------------------------------------------
@ bootwin_exit_due - is the window over
@ Replaces : the test 0x0800EA8E..0x0800EAA0
@ In       : -
@ Out      : r0 = 1 when the counter 0x2000022E is 0 and B != 4, else 0
@ Clobbers : r1, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC bootwin_exit_due
    ldr r1, =v_2000022E
    ldrh r0, [r1]
    cbnz r0, 1f                             @ counter running: open
    ldr r1, =BW_B
    ldrb r0, [r1]
    cmp r0, #4                              @ B = 4 (result shown) keeps the window
    beq 1f
    movs r0, #1
    bx lr
1:  movs r0, #0
    bx lr
ENDFUNC bootwin_exit_due

@ -----------------------------------------------------------------------------
@ bootwin_dispatch - act on the sequence states after the key processing
@ Replaces : 0x0800EABA..0x0800EBDE
@ In       : r0 = 1 run cal.bin to completion (v2.05), 0 step it (production)
@ Out      : r0 = 1 the window must close now (A = 2 or A = 3), else 0
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ Deviation: OF-08 (no EEPROM write on A = 2)
@ -----------------------------------------------------------------------------
LFUNC bootwin_dispatch
    push {r4, r5, r6, lr}
    mov r6, r0                              @ r6 = blocking cal.bin
    ldr r1, =BW_A
    ldrb r0, [r1]
    cbz r0, .Lbwd_b                         @ A = 0: MEM path (0x0800EAC2)
    cmp r0, #1
    bne 1f
    bl fn_08019854                          @ " CAL1" (0x0800EACE)
    bl fn_08019880                          @ " CAL "
    bl lcd_commit_shadow
    b .Lbwd_open
1:  cmp r0, #2
    bne 2f
    ldr r1, =v_2000808A
    movs r0, #1
    strb r0, [r1]                           @ calibration mode (0x0800EAEC, its only store of 1)
    ldr r1, =v_20008062
    strb r0, [r1]                           @ 0x20008062 = 1 (0x0800EAF4)
    @ OF-08: v2.05 calls current_extra_erase_all here (0x0800EAF6); the port writes nothing
    b .Lbwd_close
2:  cmp r0, #3
    bne .Lbwd_open
    ldr r1, =v_2000808B
    movs r0, #1
    strb r0, [r1]                           @ date-code editing enabled (0x0800EB14)
    ldr r1, =v_20008062
    strb r0, [r1]
    ldr r1, =v_200080D7
    ldrb r0, [r1]
    ldr r1, =v_200080DD
    strb r0, [r1]                           @ 0x200080DD = 0x200080D7 (0x0800EB28)
    b .Lbwd_close
.Lbwd_b:
    ldr r1, =BW_B
    ldrb r0, [r1]
    cmp r0, #1
    bne 3f
    bl fn_08019792                          @ "SdCAL" (0x0800EB48)
    b .Lbwd_open
3:  cmp r0, #2
    bne 5f
    ldr r1, =v_20008088
    ldrb r0, [r1]
    cbz r0, 4f
    bl fn_080197B6                          @ save chosen: "SdSAv" (0x0800EB62)
    b .Lbwd_open
4:  ldrb r0, [r1, #1]                       @ 0x20008089: load chosen
    cmp r0, #0
    beq .Lbwd_open
    bl fn_080197E0                          @ "SdSEt" (0x0800EB72)
    b .Lbwd_open
5:  cmp r0, #3
    bne .Lbwd_open
    ldr r1, =v_20008088
    ldrb r0, [r1]
    movs r4, #0                             @ r4 = operation: 0 save
    cbnz r0, 6f
    ldrb r0, [r1, #1]
    cmp r0, #0
    beq .Lbwd_open                          @ neither chosen: nothing (0x0800EBB8)
    movs r4, #1                             @ load
6:  cbz r6, 7f
    cbnz r4, 61f                            @ blocking: v2.05 calls (0x0800EB8C, 0x0800EBBC)
    bl calbin_save
    b 8f
61: bl calbin_load
    b 8f
7:  ldr r5, =bootwin_cb                     @ stepped: start once, one step per pass
    ldrb r0, [r5]
    cbnz r0, 71f
    mov r0, r4
    bl calbin_start
    movs r0, #1
    strb r0, [r5]
71: bl calbin_step
    cmp r0, #0
    beq .Lbwd_open                          @ still running
    movs r0, #0
    strb r0, [r5]
    ldr r0, =calbin_result
    ldrb r0, [r0]
8:  cbz r0, 9f
    bl fn_0801982C                          @ error: "-Err-" (0x0800EB94, 0x0800EBC4)
    b 10f
9:  bl fn_08019808                          @ done: "SAvEd" (0x0800EBA2, 0x0800EBD2)
10: ldr r1, =BW_B
    movs r0, #4
    strb r0, [r1]                           @ B = 4, terminal
.Lbwd_open:
    movs r0, #0
    pop {r4, r5, r6, pc}
.Lbwd_close:
    ldr r1, =v_2000022E
    movs r0, #0
    strh r0, [r1]                           @ counter 0 (0x0800EB00, 0x0800EB30)
    movs r0, #1
    pop {r4, r5, r6, pc}
ENDFUNC bootwin_dispatch

@ -----------------------------------------------------------------------------
@ bootwin_exit - close the window
@ Replaces : 0x0800EBE0..0x0800EC12
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes A = B = 0, 0x2000022E = 0, 0x20008089 = 0, 0x20008088 = 0, bootwin_active = 0
@ -----------------------------------------------------------------------------
LFUNC bootwin_exit
    push {r4, lr}
    movs r0, #0
    ldr r1, =BW_B
    strb r0, [r1]                           @ B = 0 (0x0800EBE6)
    ldr r1, =BW_A
    strb r0, [r1]                           @ A = 0 (0x0800EBEC)
    ldr r1, =v_2000022E
    strh r0, [r1]                           @ counter 0 (0x0800EBF4)
    ldr r1, =v_20008088
    strb r0, [r1, #1]                       @ 0x20008089 = 0 (0x0800EBFC)
    strb r0, [r1]                           @ 0x20008088 = 0x20008089 = 0 (0x0800EC08)
    ldr r1, =bootwin_active
    strb r0, [r1]
    bl fn_0801A81C                          @ LCD blank (0x0800EC0A)
    bl lcd_commit_shadow
    pop {r4, pc}
ENDFUNC bootwin_exit

    .ltorg
