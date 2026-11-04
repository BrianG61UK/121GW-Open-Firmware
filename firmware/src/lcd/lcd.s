@ =============================================================================
@ lcd.s - LCD: controller set-up, StdPeriph helpers, shadow-to-LCD_RAM commit (DESIGN.md 6.7)
@
@ Replaces the v2.05 LCD controller code: the LCD StdPeriph helpers 0x080203B4..0x08020492, lcd_init 0x0801B450 with its
@ pin set-up 0x0801B4D6 and contrast helpers 0x0801B708 / 0x0801B77A, and the two commit routines lcd_commit_shadow
@ 0x0801B304 and lcd_commit_shadow_partial 0x0801B396.
@ Every routine is the v2.05 instruction stream (one line per v2.05 instruction, v2.05 address in the comment column)
@ except where the "Deviation" line of its header says otherwise:
@   HW-07  every wait on an LCD status flag is bounded by LCD_WAIT_POLLS (config.inc); lcd_init gives up with the
@          controller disabled (lcd_init_fault = 1) instead of hanging;
@   OF-05  fn_0801B77A leaves LCD_FCR alone for a contrast setting outside 10..17;
@   OF-50  fn_0801B77A passes the contrast mask to fn_08020472, not LCD_FCR AND mask;
@   IMP-06 the commit never waits for UDR: a commit that finds the previous update request still
@          pending is deferred (lcd_commit_pending) and repeated by lcd_commit_retry, which fn_08016D34 calls on every
@          pass; the eight words are written only when they differ from the last committed copy (lcd_last).
@ Context: drawing into the shadow and committing are main-only (DESIGN.md 3.4, NF-11).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .bss_port.lcd, "aw", %nobits

@ lcd_last: the eight shadow words written to LCD_RAM0..7 by the last full commit (production commit-on-change)
    .balign 4
lcd_last:
    .space 32
@ lcd_last_valid: 1 while lcd_last equals LCD_RAM0..7; cleared by lcd_init and by a partial commit
lcd_last_valid:
    .space 1
@ lcd_commit_pending: nonzero while a commit was deferred because UDR was still set (production); 1 = a partial commit is
@ owed (the retry decides again), 2 = a full commit is owed (the retry stays full); cleared by a commit
lcd_commit_pending:
    .space 1
@ lcd_init_fault: 1 if lcd_init gave up waiting for ENS or RDY (HW-07); 0 otherwise.  Read by the tests.
    .global lcd_init_fault
lcd_init_fault:
    .space 1
    .balign 4

    .section .text.lcd.lcd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ lcd_commit_shadow - copy the shadow words 0..7 to LCD_RAM and request the display update
@ Replaces : 0x0801B304 lcd_commit_shadow (v2.05, 146 bytes)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, flags (v2.05: r0-r2; r3 is used by lcd_commit_words in production)
@ Context  : main only
@ RAM      : reads lcd_shadow (0x20007790), hold_stage2 (0x20008050), 0x20007FE1, 0x20008053; writes LCD_RAM0..7,
@            0x20008053 (cleared by a full commit), lcd_last, lcd_last_valid, lcd_commit_pending (production)
@ Spec     : analysis/lcd_map.md 1 (word i -> LCD_RAM 0x40002414 + 4i, partial commit rule); RM0038 16.5.3 (UDR)
@ Deviation: IMP-11 (production: ui_relpct_mask first applies the REL percent view to the shadow)
@ Deviation: HW-07 (the UDR wait is bounded by LCD_WAIT_POLLS; on a timeout nothing is written), IMP-06 / OF-31
@            (production: no wait; a commit that finds UDR set is deferred and repeated by lcd_commit_retry, a deferred full
@            commit stays a full commit; the words are written only if they differ from the last committed copy)
@ -----------------------------------------------------------------------------
FUNC lcd_commit_shadow
    push {r4, lr}                            @ 0801B304 r4 = HW-07 poll budget in the baseline build (v2.05: push {r7, lr})
    bl ui_relpct_mask                        @ IMP-11: unit signs off and % on while REL is shown in percent (ui/relpct.s)
    @ production: a full commit that was deferred (lcd_commit_pending = 2) stays a full commit at the retry.  The partial
    @ rule below reads state that can change between the deferral and the retry (logging flag 0x20007FE1 cleared); a switch
    @ to the partial commit would drop the non-bargraph shadow changes of the deferred commit, which v2.05 commits at once.
    ldr r0, =lcd_commit_pending
    ldrb r0, [r0]
    cmp r0, #2
    beq .L0801B32E                           @ full commit owed: skip the partial rule
    @ partial rule (analysis/lcd_map.md 1): r0 = hold_stage2 AND NOT 0x20007FE1; r1 = NOT 0x20008053; partial commit when both are non-zero
    ldr r0, =hold_stage2                     @ 0801B306 &hold_stage2
    ldrb r0, [r0, #0]                        @ 0801B30A
    ldr r1, =v_20007FE1                      @ 0801B30C &flag FE1 (lcd_map.md 4)
    ldrb r1, [r1, #0]                        @ 0801B310
    eors.w r1, r1, #1                        @ 0801B312
    ands r0, r1                              @ 0801B316
    ldr r1, =v_20008053                      @ 0801B318 &force-full-commit flag
    ldrb r1, [r1, #0]                        @ 0801B31C
    eors.w r1, r1, #1                        @ 0801B31E
    uxtb r0, r0                              @ 0801B322
    tst r0, r1                               @ 0801B324
    beq .L0801B32E                           @ 0801B326
    @ auto-hold stage 2 and no forced full redraw: only the bargraph bits are committed (lcd_commit_shadow_partial)
    bl lcd_commit_shadow_partial             @ 0801B328
    b .L0801B394                             @ 0801B32C
.L0801B32E:
    @ IMP-06: never wait
    movs r0, #LCD_SR_UDR
    bl fn_08020492                          @ r0 = 1 while the previous update request is still pending
    cmp r0, #0
    bne .Lcs_defer                          @ pending: do not wait; lcd_commit_retry repeats this commit
    movs r0, #0
    ldr r1, =v_20008053
    strb r0, [r1]                           @ forced-full-redraw flag consumed (v2.05 0x0801B32E..0x0801B334; a deferred call keeps it)
    bl lcd_commit_words                     @ write the words if they changed, request the update
    b .L0801B394
.Lcs_defer:
    movs r0, #2
    ldr r1, =lcd_commit_pending
    strb r0, [r1]                           @ a full commit is owed (2): the retry does not apply the partial rule again

.L0801B394:                                @ reached from 0801B32C b; falls in
    pop {r4, pc}                             @ 0801B394 restores r4 (v2.05: pop {r0, pc})
ENDFUNC lcd_commit_shadow
    .ltorg

@ -----------------------------------------------------------------------------
@ lcd_commit_shadow_partial - commit only the bargraph bits of words 0, 2, 4, 6
@ Replaces : 0x0801B396 lcd_commit_shadow_partial (v2.05, 168 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; called by lcd_commit_shadow in auto-hold stage 2
@ RAM      : reads lcd_shadow words 0, 2, 4, 6; read-modify-writes LCD_RAM0, LCD_RAM2, LCD_RAM4, LCD_RAM6;
@            writes lcd_last_valid, lcd_commit_pending (production)
@ Spec     : analysis/lcd_map.md 1 (masks w0 0x14FE, w2 0x08FF, w4 0x00FF, w6 0x01FE = the bargraph group)
@ Deviation: IMP-06 (production: if UDR is still set nothing is written and the commit is deferred; after a partial
@            commit the last-committed copy is marked invalid); v2.05 writes without looking at UDR
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC lcd_commit_shadow_partial
    push {r7, lr}                            @ 0801B396
    movs r0, #LCD_SR_UDR
    bl fn_08020492                          @ r0 = 1 while the previous update request is pending (LCD_RAM write-protected)
    cmp r0, #0
    beq .Lcp_go                             @ UDR clear: write now
    movs r0, #1
    ldr r1, =lcd_commit_pending
    strb r0, [r1]                           @ a commit is owed; lcd_commit_shadow decides partial or full again at the retry
    pop {r0, pc}                            @ return without writing (same exit form as the end of this routine)
.Lcp_go:
    @ word 0: LCD_RAM0 = (LCD_RAM0 AND 0xFFFFEB01) OR (shadow0 AND 0x14FE): keeps bits 0, 8, 9, 11, 13..31, replaces bits 1..7, 10, 12
    ldr r0, =LCD_RAM                         @ 0801B398
    ldr r0, [r0, #0]                         @ 0801B39C
    ldr r1, =0xFFFFEB01                      @ 0801B39E
    ands r0, r1                              @ 0801B3A2
    ldr r1, =LCD_RAM                         @ 0801B3A4
    str r0, [r1, #0]                         @ 0801B3A8
    ldr r0, =LCD_RAM                         @ 0801B3AA
    ldr r0, [r0, #0]                         @ 0801B3AE
    ldr r1, =lcd_shadow                      @ 0801B3B0 &LCD shadow
    ldr r1, [r1, #0]                         @ 0801B3B2
    movw r2, #5374                           @ 0801B3B4
    ands r1, r2                              @ 0801B3B8
    orrs r0, r1                              @ 0801B3BA
    ldr r1, =LCD_RAM                         @ 0801B3BC
    str r0, [r1, #0]                         @ 0801B3C0
    @ word 2: LCD_RAM2 = (LCD_RAM2 AND 0xFFFFF700) OR (shadow2 AND 0x08FF): replaces bits 0..7 and 11
    ldr r0, =0x4000241C                      @ 0801B3C2
    ldr r0, [r0, #0]                         @ 0801B3C6
    ldr r1, =0xFFFFF700                      @ 0801B3C8
    ands r0, r1                              @ 0801B3CC
    ldr r1, =0x4000241C                      @ 0801B3CE
    str r0, [r1, #0]                         @ 0801B3D2
    ldr r0, =0x4000241C                      @ 0801B3D4
    ldr r0, [r0, #0]                         @ 0801B3D8
    ldr r1, =lcd_shadow                      @ 0801B3DA &LCD shadow
    ldr r1, [r1, #8]                         @ 0801B3DC
    movw r2, #2303                           @ 0801B3DE
    ands r1, r2                              @ 0801B3E2
    orrs r0, r1                              @ 0801B3E4
    ldr r1, =0x4000241C                      @ 0801B3E6
    str r0, [r1, #0]                         @ 0801B3EA
    @ word 4: LCD_RAM4 = (LCD_RAM4 AND NOT 0xFF) OR (shadow4 byte 0): replaces bits 0..7
    ldr r0, =0x40002424                      @ 0801B3EC
    ldr r0, [r0, #0]                         @ 0801B3F0
    lsrs r0, r0, #8                          @ 0801B3F2
    lsls r0, r0, #8                          @ 0801B3F4
    ldr r1, =0x40002424                      @ 0801B3F6
    str r0, [r1, #0]                         @ 0801B3FA
    ldr r0, =0x40002424                      @ 0801B3FC
    ldr r0, [r0, #0]                         @ 0801B400
    ldr r1, =lcd_shadow                      @ 0801B402 &LCD shadow
    ldrb r1, [r1, #16]                       @ 0801B404 shadow byte at +16
    and.w r1, r1, #255                       @ 0801B406
    orrs r0, r1                              @ 0801B40A
    ldr r1, =0x40002424                      @ 0801B40C
    str r0, [r1, #0]                         @ 0801B410
    @ word 6: LCD_RAM6 = (LCD_RAM6 AND NOT 0x1FE) OR (shadow6 AND 0x1FE): replaces bits 1..8
    ldr r0, =0x4000242C                      @ 0801B412
    ldr r0, [r0, #0]                         @ 0801B416
    bics.w r0, r0, #510                      @ 0801B418
    ldr r1, =0x4000242C                      @ 0801B41C
    str r0, [r1, #0]                         @ 0801B420
    ldr r0, =0x4000242C                      @ 0801B422
    ldr r0, [r0, #0]                         @ 0801B426
    ldr r1, =lcd_shadow                      @ 0801B428 &LCD shadow
    ldr r1, [r1, #24]                        @ 0801B42A
    ands.w r1, r1, #510                      @ 0801B42C
    orrs r0, r1                              @ 0801B430
    ldr r1, =0x4000242C                      @ 0801B432
    str r0, [r1, #0]                         @ 0801B436
    @ LCD_UpdateDisplayRequest
    bl fn_0802048A                           @ 0801B438
    movs r0, #0
    ldr r1, =lcd_last_valid
    strb r0, [r1]                           @ LCD_RAM no longer equals the last full copy (IMP-06 bookkeeping)
    ldr r1, =lcd_commit_pending
    strb r0, [r1]                           @ the owed commit has now been made

    pop {r0, pc}                             @ 0801B43C
ENDFUNC lcd_commit_shadow_partial
    .ltorg

@ -----------------------------------------------------------------------------
@ lcd_init - initialise the LCD controller, enable it and optionally clear the display
@ Replaces : 0x0801B450 lcd_init (v2.05, 134 bytes)
@ In       : r0 = contrast setting (low byte used; 10..17 select LCD_FCR.CC 0..7, other values leave CC unchanged),
@            r1 = 1 clear the shadow RAM before the first commit, 0 keep the shadow (the setup contrast editor passes 0)
@ Out      : -   (lcd_init_fault = 1 if the controller did not become ready, HW-07)
@ Clobbers : r0-r3, r12, flags (v2.05: r0-r3, r12)
@ Context  : main only
@ RAM      : writes lcd_init_fault, lcd_commit_pending, lcd_last_valid (production); stack frame 0x14 bytes for the
@            LCD_Init parameter block
@ Spec     : RM0038 16.5; analysis/lcd_map.md 1 (PS = 3, DIV = 0, 1/4 duty, 1/3 bias, internal step-up, PON = 4)
@ Deviation: HW-07 (the ENS and RDY waits are bounded by LCD_WAIT_POLLS; on a timeout the controller is switched off and
@            lcd_init returns), IMP-06 (production: the committed-copy bookkeeping restarts, so the first commit writes)
@ -----------------------------------------------------------------------------
FUNC lcd_init
    push {r4, r5, lr}                        @ 0801B450
    sub sp, #20                              @ 0801B452
    movs r4, r0                              @ 0801B454
    @ r4 = contrast setting, r5 = clear-shadow flag (both kept across the calls below)
    movs r5, r1                              @ 0801B456
    @ AF11 pins (fn_0801B4D6)
    bl fn_0801B4D6                           @ 0801B458
    @ fn_0801FFBC(0x200, 1) (SYS) sets RCC_APB1ENR bit 9: clock of the LCD controller
    movs r1, #1                              @ 0801B45C
    mov.w r0, #512                           @ 0801B45E
    bl fn_0801FFBC                           @ 0801B462
    @ build the LCD_Init parameter block on the stack: [sp+0] prescaler 0x00C00000 (PS = 3), [sp+4] divider 0 (DIV = 0),
    @ [sp+8] duty 0x0C (DUTY = 011, 1/4), [sp+12] bias 0x40 (BIAS = 10, 1/3), [sp+16] voltage source 0 (internal step-up)
    movs.w r0, #12582912                     @ 0801B466
    str r0, [sp, #0]                         @ 0801B46A
    movs r0, #0                              @ 0801B46C
    str r0, [sp, #4]                         @ 0801B46E
    movs r0, #12                             @ 0801B470
    str r0, [sp, #8]                         @ 0801B472
    movs r0, #64                             @ 0801B474
    str r0, [sp, #12]                        @ 0801B476
    movs r0, #0                              @ 0801B478
    str r0, [sp, #16]                        @ 0801B47A
    @ LCD_Init(&block)
    mov r0, sp                               @ 0801B47C
    bl fn_080203B4                           @ 0801B47E
    @ LCD_MuxSegmentCmd(DISABLE): MUX_SEG = 0
    movs r0, #0                              @ 0801B482
    bl fn_0802041E                           @ 0801B484
    @ apply the contrast setting (fn_0801B708): CC := setting - 10
    movs r0, r4                              @ 0801B488
    uxtb r0, r0                              @ 0801B48A
    bl fn_0801B708                           @ 0801B48C
    @ LCD_DeadTimeConfig(0): no dead time
    movs r0, #0                              @ 0801B490
    bl fn_0802043E                           @ 0801B492
    @ LCD_PulseOnDurationConfig(0x40): PON = 4
    movs r0, #64                             @ 0801B496
    bl fn_08020426                           @ 0801B498
    @ LCD_WaitForSynchro (fn_08020402, bounded 0x8000 polls)
    bl fn_08020402                           @ 0801B49C
    @ LCD_Cmd(ENABLE): LCDEN = 1
    movs r0, #1                              @ 0801B4A0
    bl fn_080203FA                           @ 0801B4A2
    @ HW-07: v2.05 loops here without a bound (0x0801B4A6..0x0801B4AE on ENS, 0x0801B4B0..0x0801B4B8 on RDY).
    @ Each wait now has a budget of LCD_WAIT_POLLS polls; r3 keeps the budget (fn_08020492 touches r0-r2 only).
    movs r0, #0
    ldr r1, =lcd_init_fault
    strb r0, [r1]                           @ no fault so far
    ldr r1, =lcd_last_valid
    strb r0, [r1]                           @ LCD_RAM content unknown after (re-)initialisation: the next commit must write (IMP-06)
    ldr r1, =lcd_commit_pending
    strb r0, [r1]                           @ a commit owed from before the (re-)initialisation is void
    ldr r3, =LCD_WAIT_POLLS                 @ ENS wait budget
.Lli_ens:
    movs r0, #LCD_SR_ENS                    @ v2.05 0x0801B4A6: wait for LCD_SR.ENS (controller enabled)
    bl fn_08020492                          @ r0 = 1 once ENS is set
    cmp r0, #0
    bne .Lli_ens_ok                         @ ENS set: go on to the RDY wait
    subs r3, r3, #1
    bne .Lli_ens                            @ budget left: poll again
    b .Lli_fail                             @ budget exhausted
.Lli_ens_ok:
    ldr r3, =LCD_WAIT_POLLS                 @ RDY wait budget
.Lli_rdy:
    movs r0, #LCD_SR_RDY                    @ v2.05 0x0801B4B0: wait for LCD_SR.RDY (step-up converter ready)
    bl fn_08020492
    cmp r0, #0
    bne .Lli_rdy_ok                         @ RDY set: initialisation continues as in v2.05
    subs r3, r3, #1
    bne .Lli_rdy                            @ budget left: poll again
.Lli_fail:                                  @ ENS or RDY did not appear in time (HW-07)
    movs r0, #0
    bl fn_080203FA                          @ LCD_Cmd(DISABLE): leave the controller off; the meter runs without a display
    movs r0, #1
    ldr r1, =lcd_init_fault
    strb r0, [r1]                           @ record the failure
    b .Lli_end
.Lli_rdy_ok:
    @ LCD_BlinkConfig(0, 0x4000): blink off, BLINKF field 010
    mov.w r1, #16384                         @ 0801B4BA
    movs r0, #0                              @ 0801B4BE
    bl fn_08020456                           @ 0801B4C0
    @ r5 = clear-shadow flag: 0 keeps the shadow, non-zero clears it
    uxtb r5, r5                              @ 0801B4C4
    cmp r5, #0                               @ 0801B4C6
    beq .L0801B4CE                           @ 0801B4C8
    @ fn_0801A81C: clear the 16 shadow words
    bl fn_0801A81C                           @ 0801B4CA
.L0801B4CE:                                @ reached from 0801B4C8 beq (equal / zero); falls in
    @ first commit of the shadow
    bl lcd_commit_shadow                     @ 0801B4CE
.Lli_end:
    add sp, sp, #0x14                       @ release the LCD_Init parameter block (v2.05 0x0801B4D2)
    pop {r4, r5, pc}                        @ v2.05 0x0801B4D4

ENDFUNC lcd_init
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801B4D6 - configure the LCD pins as alternate function 11
@ Replaces : 0x0801B4D6 FUN_0801B4D6 (v2.05, 562 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : 8-byte pin block on the stack (mask u32, mode u8, speed u8, otype u8, pupd u8)
@ Spec     : analysis/lcd_map.md 1 (pin list); schematic: PA1,2,3,6,7,8,9,10,15, PB0,1,3,4,5,8..15, PC0..7,9,10,
@            PD8..15, PE0..3 are the LCD segment and common pins
@ Clobbers : r0, r1, r2, r3, r12 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801B4D6
    push {lr}                                @ 0801B4D6
    sub sp, #12                              @ 0801B4D8
    @ fn_0801BFC6 calls fn_0801FF80(0xFF, 1), which sets RCC_AHBENR bits 0..7 (clocks of the GPIO ports A..H)
    bl fn_0801BFC6                           @ 0801B4DA
    @ fn_0801BDEC(sp) fills the 8-byte pin block with mask 0xFFFF and mode, speed, otype, pupd = 0
    mov r0, sp                               @ 0801B4DE
    bl fn_0801BDEC                           @ 0801B4E0
    @ PA: pin mask 0x87CE = PA1,2,3,6,7,8,9,10,15, mode 2 (alternate function)
    movw r0, #34766                          @ 0801B4E4
    str r0, [sp, #0]                         @ 0801B4E8
    movs r0, #2                              @ 0801B4EA
    strb.w r0, [sp, #4]                      @ 0801B4EC
    mov r1, sp                               @ 0801B4F0
    ldr r0, =GPIOA_BASE                      @ 0801B4F2
    @ gpio_init(GPIOA, &struct): pin policy checked by BRD (DESIGN.md 4.2)
    bl gpio_init                             @ 0801B4F6
    @ for each pin of the mask: gpio_set_alternate_function(port, pin, AF11)
    movs r2, #11                             @ 0801B4FA
    movs r1, #1                              @ 0801B4FC
    ldr r0, =GPIOA_BASE                      @ 0801B4FE
    bl gpio_set_alternate_function           @ 0801B502
    movs r2, #11                             @ 0801B506
    movs r1, #2                              @ 0801B508
    ldr r0, =GPIOA_BASE                      @ 0801B50A
    bl gpio_set_alternate_function           @ 0801B50E
    movs r2, #11                             @ 0801B512
    movs r1, #3                              @ 0801B514
    ldr r0, =GPIOA_BASE                      @ 0801B516
    bl gpio_set_alternate_function           @ 0801B51A
    movs r2, #11                             @ 0801B51E
    movs r1, #6                              @ 0801B520
    ldr r0, =GPIOA_BASE                      @ 0801B522
    bl gpio_set_alternate_function           @ 0801B524
    movs r2, #11                             @ 0801B528
    movs r1, #7                              @ 0801B52A
    ldr r0, =GPIOA_BASE                      @ 0801B52C
    bl gpio_set_alternate_function           @ 0801B52E
    movs r2, #11                             @ 0801B532
    movs r1, #8                              @ 0801B534
    ldr r0, =GPIOA_BASE                      @ 0801B536
    bl gpio_set_alternate_function           @ 0801B538
    movs r2, #11                             @ 0801B53C
    movs r1, #9                              @ 0801B53E
    ldr r0, =GPIOA_BASE                      @ 0801B540
    bl gpio_set_alternate_function           @ 0801B542
    movs r2, #11                             @ 0801B546
    movs r1, #10                             @ 0801B548
    ldr r0, =GPIOA_BASE                      @ 0801B54A
    bl gpio_set_alternate_function           @ 0801B54C
    movs r2, #11                             @ 0801B550
    movs r1, #15                             @ 0801B552
    ldr r0, =GPIOA_BASE                      @ 0801B554
    bl gpio_set_alternate_function           @ 0801B556
    @ PB: pin mask 0xFF3B = PB0,1,3,4,5,8..15
    movw r0, #65339                          @ 0801B55A
    str r0, [sp, #0]                         @ 0801B55E
    movs r0, #2                              @ 0801B560
    strb.w r0, [sp, #4]                      @ 0801B562
    mov r1, sp                               @ 0801B566
    ldr r0, =GPIOB_BASE                      @ 0801B568
    bl gpio_init                             @ 0801B56A
    movs r2, #11                             @ 0801B56E
    movs r1, #0                              @ 0801B570
    ldr r0, =GPIOB_BASE                      @ 0801B572
    bl gpio_set_alternate_function           @ 0801B574
    movs r2, #11                             @ 0801B578
    movs r1, #1                              @ 0801B57A
    ldr r0, =GPIOB_BASE                      @ 0801B57C
    bl gpio_set_alternate_function           @ 0801B57E
    movs r2, #11                             @ 0801B582
    movs r1, #3                              @ 0801B584
    ldr r0, =GPIOB_BASE                      @ 0801B586
    bl gpio_set_alternate_function           @ 0801B588
    movs r2, #11                             @ 0801B58C
    movs r1, #4                              @ 0801B58E
    ldr r0, =GPIOB_BASE                      @ 0801B590
    bl gpio_set_alternate_function           @ 0801B592
    movs r2, #11                             @ 0801B596
    movs r1, #5                              @ 0801B598
    ldr r0, =GPIOB_BASE                      @ 0801B59A
    bl gpio_set_alternate_function           @ 0801B59C
    movs r2, #11                             @ 0801B5A0
    movs r1, #8                              @ 0801B5A2
    ldr r0, =GPIOB_BASE                      @ 0801B5A4
    bl gpio_set_alternate_function           @ 0801B5A6
    movs r2, #11                             @ 0801B5AA
    movs r1, #9                              @ 0801B5AC
    ldr r0, =GPIOB_BASE                      @ 0801B5AE
    bl gpio_set_alternate_function           @ 0801B5B0
    movs r2, #11                             @ 0801B5B4
    movs r1, #10                             @ 0801B5B6
    ldr r0, =GPIOB_BASE                      @ 0801B5B8
    bl gpio_set_alternate_function           @ 0801B5BA
    movs r2, #11                             @ 0801B5BE
    movs r1, #11                             @ 0801B5C0
    ldr r0, =GPIOB_BASE                      @ 0801B5C2
    bl gpio_set_alternate_function           @ 0801B5C4
    movs r2, #11                             @ 0801B5C8
    movs r1, #12                             @ 0801B5CA
    ldr r0, =GPIOB_BASE                      @ 0801B5CC
    bl gpio_set_alternate_function           @ 0801B5CE
    movs r2, #11                             @ 0801B5D2
    movs r1, #13                             @ 0801B5D4
    ldr r0, =GPIOB_BASE                      @ 0801B5D6
    bl gpio_set_alternate_function           @ 0801B5D8
    movs r2, #11                             @ 0801B5DC
    movs r1, #14                             @ 0801B5DE
    ldr r0, =GPIOB_BASE                      @ 0801B5E0
    bl gpio_set_alternate_function           @ 0801B5E2
    movs r2, #11                             @ 0801B5E6
    movs r1, #15                             @ 0801B5E8
    ldr r0, =GPIOB_BASE                      @ 0801B5EA
    bl gpio_set_alternate_function           @ 0801B5EC
    @ PC: pin mask 0x06FF = PC0..7,9,10
    movw r0, #1791                           @ 0801B5F0
    str r0, [sp, #0]                         @ 0801B5F4
    movs r0, #2                              @ 0801B5F6
    strb.w r0, [sp, #4]                      @ 0801B5F8
    mov r1, sp                               @ 0801B5FC
    ldr r0, =GPIOC_BASE                      @ 0801B5FE
    bl gpio_init                             @ 0801B600
    movs r2, #11                             @ 0801B604
    movs r1, #0                              @ 0801B606
    ldr r0, =GPIOC_BASE                      @ 0801B608
    bl gpio_set_alternate_function           @ 0801B60A
    movs r2, #11                             @ 0801B60E
    movs r1, #1                              @ 0801B610
    ldr r0, =GPIOC_BASE                      @ 0801B612
    bl gpio_set_alternate_function           @ 0801B614
    movs r2, #11                             @ 0801B618
    movs r1, #2                              @ 0801B61A
    ldr r0, =GPIOC_BASE                      @ 0801B61C
    bl gpio_set_alternate_function           @ 0801B61E
    movs r2, #11                             @ 0801B622
    movs r1, #3                              @ 0801B624
    ldr r0, =GPIOC_BASE                      @ 0801B626
    bl gpio_set_alternate_function           @ 0801B628
    movs r2, #11                             @ 0801B62C
    movs r1, #4                              @ 0801B62E
    ldr r0, =GPIOC_BASE                      @ 0801B630
    bl gpio_set_alternate_function           @ 0801B632
    movs r2, #11                             @ 0801B636
    movs r1, #5                              @ 0801B638
    ldr r0, =GPIOC_BASE                      @ 0801B63A
    bl gpio_set_alternate_function           @ 0801B63C
    movs r2, #11                             @ 0801B640
    movs r1, #6                              @ 0801B642
    ldr r0, =GPIOC_BASE                      @ 0801B644
    bl gpio_set_alternate_function           @ 0801B646
    movs r2, #11                             @ 0801B64A
    movs r1, #7                              @ 0801B64C
    ldr r0, =GPIOC_BASE                      @ 0801B64E
    bl gpio_set_alternate_function           @ 0801B650
    movs r2, #11                             @ 0801B654
    movs r1, #9                              @ 0801B656
    ldr r0, =GPIOC_BASE                      @ 0801B658
    bl gpio_set_alternate_function           @ 0801B65A
    movs r2, #11                             @ 0801B65E
    movs r1, #10                             @ 0801B660
    ldr r0, =GPIOC_BASE                      @ 0801B662
    bl gpio_set_alternate_function           @ 0801B664
    @ PD: pin mask 0xFF00 = PD8..15
    mov.w r0, #65280                         @ 0801B668
    str r0, [sp, #0]                         @ 0801B66C
    movs r0, #2                              @ 0801B66E
    strb.w r0, [sp, #4]                      @ 0801B670
    mov r1, sp                               @ 0801B674
    ldr r0, =GPIOD_BASE                      @ 0801B676
    bl gpio_init                             @ 0801B678
    movs r2, #11                             @ 0801B67C
    movs r1, #8                              @ 0801B67E
    ldr r0, =GPIOD_BASE                      @ 0801B680
    bl gpio_set_alternate_function           @ 0801B682
    movs r2, #11                             @ 0801B686
    movs r1, #9                              @ 0801B688
    ldr r0, =GPIOD_BASE                      @ 0801B68A
    bl gpio_set_alternate_function           @ 0801B68C
    movs r2, #11                             @ 0801B690
    movs r1, #10                             @ 0801B692
    ldr r0, =GPIOD_BASE                      @ 0801B694
    bl gpio_set_alternate_function           @ 0801B696
    movs r2, #11                             @ 0801B69A
    movs r1, #11                             @ 0801B69C
    ldr r0, =GPIOD_BASE                      @ 0801B69E
    bl gpio_set_alternate_function           @ 0801B6A0
    movs r2, #11                             @ 0801B6A4
    movs r1, #12                             @ 0801B6A6
    ldr r0, =GPIOD_BASE                      @ 0801B6A8
    bl gpio_set_alternate_function           @ 0801B6AA
    movs r2, #11                             @ 0801B6AE
    movs r1, #13                             @ 0801B6B0
    ldr r0, =GPIOD_BASE                      @ 0801B6B2
    bl gpio_set_alternate_function           @ 0801B6B4
    movs r2, #11                             @ 0801B6B8
    movs r1, #14                             @ 0801B6BA
    ldr r0, =GPIOD_BASE                      @ 0801B6BC
    bl gpio_set_alternate_function           @ 0801B6BE
    movs r2, #11                             @ 0801B6C2
    movs r1, #15                             @ 0801B6C4
    ldr r0, =GPIOD_BASE                      @ 0801B6C6
    bl gpio_set_alternate_function           @ 0801B6C8
    @ PE: pin mask 0x000F = PE0..3

    movs r0, #15                             @ 0801B6CC
    str r0, [sp, #0]                         @ 0801B6CE
    movs r0, #2                              @ 0801B6D0
    strb.w r0, [sp, #4]                      @ 0801B6D2
    mov r1, sp                               @ 0801B6D6
    ldr r0, =GPIOE_BASE                      @ 0801B6D8
    bl gpio_init                             @ 0801B6DA
    movs r2, #11                             @ 0801B6DE
    movs r1, #0                              @ 0801B6E0
    ldr r0, =GPIOE_BASE                      @ 0801B6E2
    bl gpio_set_alternate_function           @ 0801B6E4
    movs r2, #11                             @ 0801B6E8
    movs r1, #1                              @ 0801B6EA
    ldr r0, =GPIOE_BASE                      @ 0801B6EC
    bl gpio_set_alternate_function           @ 0801B6EE
    movs r2, #11                             @ 0801B6F2
    movs r1, #2                              @ 0801B6F4
    ldr r0, =GPIOE_BASE                      @ 0801B6F6
    bl gpio_set_alternate_function           @ 0801B6F8
    movs r2, #11                             @ 0801B6FC
    movs r1, #3                              @ 0801B6FE
    ldr r0, =GPIOE_BASE                      @ 0801B700
    bl gpio_set_alternate_function           @ 0801B702
    pop {r0, r1, r2, pc}                     @ 0801B706
ENDFUNC fn_0801B4D6
    .ltorg
    .global lcd_pins_init
    .set lcd_pins_init, fn_0801B4D6

@ -----------------------------------------------------------------------------
@ fn_0801B708 - apply a contrast setting 10..17 to LCD_FCR.CC
@ Replaces : 0x0801B708 FUN_0801B708 (v2.05, 114 bytes)
@ In       : r0 = contrast setting (low byte); 10 -> CC 0, 11 -> 1, ... 17 -> 7; any other value changes nothing
@ Out      : -
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.2 CC bits 12:10; analysis/lcd_map.md 1 (lcd_init contrast settings 10..17)
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801B708
    push {r4, lr}                            @ 0801B708
    movs r4, r0                              @ 0801B70A
    uxtb r4, r4                              @ 0801B70C
    @ setting 10: CC = 0 (value 0x0000); the other settings load (setting - 10) << 10 into r0 and call fn_08020472

    cmp r4, #10                              @ 0801B70E
    beq .L0801B72C                           @ 0801B710
    bcc .L0801B778                           @ 0801B712
    cmp r4, #12                              @ 0801B714
    beq .L0801B73E                           @ 0801B716
    bcc .L0801B734                           @ 0801B718
    cmp r4, #14                              @ 0801B71A
    beq .L0801B752                           @ 0801B71C
    bcc .L0801B748                           @ 0801B71E
    cmp r4, #16                              @ 0801B720
    beq .L0801B766                           @ 0801B722
    bcc .L0801B75C                           @ 0801B724
    cmp r4, #17                              @ 0801B726
    beq .L0801B770                           @ 0801B728
    b .L0801B778                             @ 0801B72A
.L0801B72C:                                @ reached from 0801B710 beq (equal / zero)
    movs r0, #0                              @ 0801B72C
    bl fn_08020472                           @ 0801B72E
    b .L0801B778                             @ 0801B732
.L0801B734:                                @ reached from 0801B718 bcc (unsigned <)
    mov.w r0, #1024                          @ 0801B734
    bl fn_08020472                           @ 0801B738
    b .L0801B778                             @ 0801B73C
.L0801B73E:                                @ reached from 0801B716 beq (equal / zero)
    mov.w r0, #2048                          @ 0801B73E
    bl fn_08020472                           @ 0801B742
    b .L0801B778                             @ 0801B746
.L0801B748:                                @ reached from 0801B71E bcc (unsigned <)
    mov.w r0, #3072                          @ 0801B748
    bl fn_08020472                           @ 0801B74C
    b .L0801B778                             @ 0801B750
.L0801B752:                                @ reached from 0801B71C beq (equal / zero)
    mov.w r0, #4096                          @ 0801B752
    bl fn_08020472                           @ 0801B756
    b .L0801B778                             @ 0801B75A
.L0801B75C:                                @ reached from 0801B724 bcc (unsigned <)
    mov.w r0, #5120                          @ 0801B75C
    bl fn_08020472                           @ 0801B760
    b .L0801B778                             @ 0801B764
.L0801B766:                                @ reached from 0801B722 beq (equal / zero)
    mov.w r0, #6144                          @ 0801B766
    bl fn_08020472                           @ 0801B76A
    b .L0801B778                             @ 0801B76E
.L0801B770:                                @ reached from 0801B728 beq (equal / zero)
    mov.w r0, #7168                          @ 0801B770
    bl fn_08020472                           @ 0801B774
.L0801B778:                                @ reached from 0801B712 bcc (unsigned <); 0801B72A b; 0801B732 b; 0801B73C b; 0801B746 b; 0801B750 b; 0801B75A b; 0801B764 b; 0801B76E b; falls in
    pop {r4, pc}                             @ 0801B778
ENDFUNC fn_0801B708
    .ltorg
    .global lcd_contrast_apply
    .set lcd_contrast_apply, fn_0801B708

@ -----------------------------------------------------------------------------
@ fn_0801B77A - re-apply the contrast setting 0x20000237 (called by set_state_reset)
@ Replaces : 0x0801B77A FUN_0801B77A (v2.05, 136 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : reads lcd_contrast (0x20000237); writes LCD_FCR (CC field, through fn_08020472)
@ Spec     : analysis/lcd_map.md 1
@ Deviation: OF-05 (a setting outside 10..17 no longer reaches fn_08020472 with an unset r4: LCD_FCR is left unchanged,
@            as fn_0801B708 does); OF-50 (fn_08020472 gets the mask (setting - 10) << 10, as fn_0801B708 passes it; v2.05
@            passed LCD_FCR AND mask, so CC could only lose bits)
@ Note     : both calls of set_state_reset (from main 0x08024B56 and enter_stop_and_reinit 0x08024EF2) are followed by lcd_init
@            (0x08024B62, 0x08024EFC), whose fn_0801B708 writes CC again with the same setting.
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801B77A
    push {r4, lr}                            @ 0801B77A
    ldr r0, =lcd_contrast                    @ 0801B77C &lcd_contrast
    ldrb r0, [r0, #0]                        @ 0801B77E
    cmp r0, #10                              @ 0801B780 branch if lcd_contrast == 10
    beq .L0801B79E                           @ 0801B782
    bcc .L0801B800                           @ 0801B784 setting < 10: leave LCD_FCR alone (OF-05; v2.05 branched to 0x0801B7FA with r4 unset)
    cmp r0, #12                              @ 0801B786 branch if lcd_contrast == 12
    beq .L0801B7B4                           @ 0801B788
    bcc .L0801B7A8                           @ 0801B78A
    cmp r0, #14                              @ 0801B78C branch if lcd_contrast == 14
    beq .L0801B7CC                           @ 0801B78E
    bcc .L0801B7C0                           @ 0801B790
    cmp r0, #16                              @ 0801B792 branch if lcd_contrast == 16
    beq .L0801B7E4                           @ 0801B794
    bcc .L0801B7D8                           @ 0801B796
    cmp r0, #17                              @ 0801B798 branch if lcd_contrast == 17
    beq .L0801B7F0                           @ 0801B79A
    b .L0801B800                             @ 0801B79C setting > 17: leave LCD_FCR alone (OF-05)
.L0801B79E:                                @ reached from 0801B782 beq (equal / zero)
    movs r4, #0                              @ 0801B7A2 setting 10: mask 0 (v2.05 read LCD_FCR first and discarded the value)
    b .L0801B7FA                             @ 0801B7A6
.L0801B7A8:                                @ reached from 0801B78A bcc (unsigned <)
    mov.w r4, #1024                       @ OF-50 0801B7A8: the mask itself (v2.05 passed LCD_FCR AND mask)
    b .L0801B7FA                             @ 0801B7B2
.L0801B7B4:                                @ reached from 0801B788 beq (equal / zero)
    mov.w r4, #2048                       @ OF-50 0801B7B4: the mask itself (v2.05 passed LCD_FCR AND mask)
    b .L0801B7FA                             @ 0801B7BE
.L0801B7C0:                                @ reached from 0801B790 bcc (unsigned <)
    mov.w r4, #3072                       @ OF-50 0801B7C0: the mask itself (v2.05 passed LCD_FCR AND mask)
    b .L0801B7FA                             @ 0801B7CA
.L0801B7CC:                                @ reached from 0801B78E beq (equal / zero)
    mov.w r4, #4096                       @ OF-50 0801B7CC: the mask itself (v2.05 passed LCD_FCR AND mask)
    b .L0801B7FA                             @ 0801B7D6
.L0801B7D8:                                @ reached from 0801B796 bcc (unsigned <)
    mov.w r4, #5120                       @ OF-50 0801B7D8: the mask itself (v2.05 passed LCD_FCR AND mask)
    b .L0801B7FA                             @ 0801B7E2
.L0801B7E4:                                @ reached from 0801B794 beq (equal / zero)
    mov.w r4, #6144                       @ OF-50 0801B7E4: the mask itself (v2.05 passed LCD_FCR AND mask)
    b .L0801B7FA                             @ 0801B7EE
.L0801B7F0:                                @ reached from 0801B79A beq (equal / zero)
    mov.w r4, #7168                       @ OF-50 0801B7F0: the mask itself (v2.05 passed LCD_FCR AND mask)
.L0801B7FA:                                @ reached from 0801B7A6 b; 0801B7B2 b; 0801B7BE b; 0801B7CA b; 0801B7D6 b; 0801B7E2 b; 0801B7EE b; falls in
    @ r4 = new CC field value (setting - 10) << 10 (OF-50: the mask; v2.05 used LCD_FCR AND mask); apply it

    movs r0, r4                              @ 0801B7FA
    bl fn_08020472                           @ 0801B7FC
.L0801B800:                                @ reached from 0801B784 bcc (unsigned <); 0801B79C b; falls in
    pop {r4, pc}                             @ 0801B800
ENDFUNC fn_0801B77A
    .ltorg
    .global lcd_contrast_refresh
    .set lcd_contrast_refresh, fn_0801B77A

@ -----------------------------------------------------------------------------
@ fn_080203B4 - LCD_Init: prescaler, divider, duty, bias and voltage source
@ Replaces : 0x080203B4 FUN_080203B4 (v2.05, 70 bytes)
@ In       : r0 = pointer to five words {prescaler, divider, duty, bias, voltage source}, each already in its register
@            field position (lcd_init passes 0x00C00000, 0, 0x0C, 0x40, 0)
@ Out      : -
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.1 LCD_CR (VSEL bit 1, DUTY bits 4:2, BIAS bits 6:5), 16.5.2 LCD_FCR (PS bits 25:22, DIV bits 21:18)
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080203B4
    push {r4, lr}                            @ 080203B4
    movs r4, r0                              @ 080203B6
    @ r0 = &LCD_FCR; the register is read-modify-written in three steps as in the StdPeriph library
    ldr r0, =LCD_FCR                         @ 080203B8
    ldr r0, [r0, #0]                         @ 080203BA
    @ clear PS[25:22] and DIV[21:18] (mask 0x03FC0000)
    bics.w r0, r0, #66846720                 @ 080203BC
    ldr r1, =LCD_FCR                         @ 080203C0
    str r0, [r1, #0]                         @ 080203C2
    ldr r0, =LCD_FCR                         @ 080203C4
    ldr r0, [r0, #0]                         @ 080203C6
    @ r1 = prescaler | divider (struct words 0 and 1)
    ldr r1, [r4, #0]                         @ 080203C8
    ldr r2, [r4, #4]                         @ 080203CA
    orrs r1, r2                              @ 080203CC
    orrs r0, r1                              @ 080203CE
    ldr r1, =LCD_FCR                         @ 080203D0
    str r0, [r1, #0]                         @ 080203D2
    @ LCD_WaitForSynchro: wait until FCRSF reports that the new LCD_FCR value reached the LCD clock domain
    bl fn_08020402                           @ 080203D4
    @ LCD_CR: clear VSEL, DUTY and BIAS (bits 1..6, mask 0x7E; write-protected while ENS = 1, so lcd_init calls this before LCD_Cmd)
    ldr r0, =LCD_CR                          @ 080203D8
    ldr r0, [r0, #0]                         @ 080203DA
    bics.w r0, r0, #126                      @ 080203DC
    ldr r1, =LCD_CR                          @ 080203E0
    str r0, [r1, #0]                         @ 080203E2
    ldr r0, =LCD_CR                          @ 080203E4
    ldr r0, [r0, #0]                         @ 080203E6
    @ r1 = duty | bias | voltage source (struct words 2, 3 and 4)

    ldr r1, [r4, #8]                         @ 080203E8
    ldr r2, [r4, #12]                        @ 080203EA
    orrs r1, r2                              @ 080203EC
    ldr r2, [r4, #16]                        @ 080203EE
    orrs r1, r2                              @ 080203F0
    orrs r0, r1                              @ 080203F2
    ldr r1, =LCD_CR                          @ 080203F4
    str r0, [r1, #0]                         @ 080203F6
    pop {r4, pc}                             @ 080203F8
ENDFUNC fn_080203B4
    .ltorg
    .global lcd_std_init
    .set lcd_std_init, fn_080203B4

@ -----------------------------------------------------------------------------
@ fn_080203FA - LCD_Cmd: enable or disable the LCD controller
@ Replaces : 0x080203FA FUN_080203FA (v2.05, 8 bytes)
@ In       : r0 = 1 enable, 0 disable (low byte used)
@ Out      : -
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.1 LCD_CR bit 0 LCDEN, written through its bit-band alias 0x42048000 (LCD_CR_LCDEN_BB)
@
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080203FA
    uxtb r0, r0                              @ 080203FA
    ldr r1, =LCD_CR_LCDEN_BB                 @ 080203FC
    str r0, [r1, #0]                         @ 080203FE
    bx lr                                    @ 08020400
ENDFUNC fn_080203FA
    .ltorg
    .global lcd_std_cmd
    .set lcd_std_cmd, fn_080203FA

@ -----------------------------------------------------------------------------
@ fn_08020402 - LCD_WaitForSynchro: wait for LCD_SR.FCRSF, at most 0x8000 polls
@ Replaces : 0x08020402 FUN_08020402 (v2.05, 28 bytes)
@ In       : -
@ Out      : -   (no result: a timeout falls through silently, as in v2.05)
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.3 LCD_SR bit 5 FCRSF; the 0x8000 poll bound is v2.05's (compare at 0x08020412)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08020402
    movs r0, #0                              @ 08020402
    movs r1, #0                              @ 08020404
.L08020406:                                @ reached from 0802041A beq (equal / zero); falls in
    ldr r2, =LCD_SR                          @ 08020406
    ldr r2, [r2, #0]                         @ 08020408
    ands.w r2, r2, #32                       @ 0802040A
    movs r1, r2                              @ 0802040E
    adds r0, r0, #1                          @ 08020410
    cmp.w r0, #32768                         @ 08020412
    beq .L0802041C                           @ 08020416
    cmp r1, #0                               @ 08020418
    beq .L08020406                           @ 0802041A
.L0802041C:                                @ reached from 08020416 beq (equal / zero); falls in
    bx lr                                    @ 0802041C
ENDFUNC fn_08020402
    .ltorg
    .global lcd_std_wait_sync
    .set lcd_std_wait_sync, fn_08020402

@ -----------------------------------------------------------------------------
@ fn_0802041E - LCD_MuxSegmentCmd: set or clear LCD_CR.MUX_SEG
@ Replaces : 0x0802041E FUN_0802041E (v2.05, 8 bytes)
@ In       : r0 = 1 enable segment multiplexing SEG[31:28]/SEG[43:40], 0 disable (lcd_init passes 0)
@ Out      : -
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.1 LCD_CR bit 7, bit-band alias 0x4204801C (LCD_CR_MUX_SEG_BB)
@
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0802041E
    uxtb r0, r0                              @ 0802041E
    ldr r1, =LCD_CR_MUX_SEG_BB               @ 08020420
    str r0, [r1, #0]                         @ 08020422
    bx lr                                    @ 08020424
ENDFUNC fn_0802041E
    .ltorg
    .global lcd_std_mux_seg_cmd
    .set lcd_std_mux_seg_cmd, fn_0802041E

@ -----------------------------------------------------------------------------
@ fn_08020426 - LCD_PulseOnDurationConfig: set LCD_FCR.PON
@ Replaces : 0x08020426 FUN_08020426 (v2.05, 24 bytes)
@ In       : r0 = PON field value already shifted to bits 6:4 (lcd_init passes 0x40 = 4/ck_ps)
@ Out      : -
@ Clobbers : r1, r2, flags
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.2 LCD_FCR bits 6:4
@ -----------------------------------------------------------------------------
FUNC fn_08020426
    ldr r1, =LCD_FCR                         @ 08020426
    ldr r1, [r1, #0]                         @ 08020428
    @ clear PON[6:4] (mask 0x70)

    bics.w r1, r1, #112                      @ 0802042A
    ldr r2, =LCD_FCR                         @ 0802042E
    str r1, [r2, #0]                         @ 08020430
    ldr r1, =LCD_FCR                         @ 08020432
    ldr r1, [r1, #0]                         @ 08020434
    orrs r1, r0                              @ 08020436
    ldr r2, =LCD_FCR                         @ 08020438
    str r1, [r2, #0]                         @ 0802043A
    bx lr                                    @ 0802043C
ENDFUNC fn_08020426
    .ltorg
    .global lcd_std_pulse_on
    .set lcd_std_pulse_on, fn_08020426

@ -----------------------------------------------------------------------------
@ fn_0802043E - LCD_DeadTimeConfig: set LCD_FCR.DEAD
@ Replaces : 0x0802043E FUN_0802043E (v2.05, 24 bytes)
@ In       : r0 = DEAD field value already shifted to bits 9:7 (lcd_init passes 0 = no dead time)
@ Out      : -
@ Clobbers : r1, r2, flags
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.2 LCD_FCR bits 9:7
@ -----------------------------------------------------------------------------
FUNC fn_0802043E
    ldr r1, =LCD_FCR                         @ 0802043E
    ldr r1, [r1, #0]                         @ 08020440
    @ clear DEAD[9:7] (mask 0x380)

    bics.w r1, r1, #896                      @ 08020442
    ldr r2, =LCD_FCR                         @ 08020446
    str r1, [r2, #0]                         @ 08020448
    ldr r1, =LCD_FCR                         @ 0802044A
    ldr r1, [r1, #0]                         @ 0802044C
    orrs r1, r0                              @ 0802044E
    ldr r2, =LCD_FCR                         @ 08020450
    str r1, [r2, #0]                         @ 08020452
    bx lr                                    @ 08020454
ENDFUNC fn_0802043E
    .ltorg
    .global lcd_std_dead_time
    .set lcd_std_dead_time, fn_0802043E

@ -----------------------------------------------------------------------------
@ fn_08020456 - LCD_BlinkConfig: set LCD_FCR.BLINK and BLINKF
@ Replaces : 0x08020456 FUN_08020456 (v2.05, 28 bytes)
@ In       : r0 = blink mode (bits 17:16), r1 = blink frequency (bits 15:13); lcd_init passes 0 (no blink) and 0x4000
@ Out      : -
@ Clobbers : r2, r3, flags
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.2 LCD_FCR bits 17:13
@ -----------------------------------------------------------------------------
FUNC fn_08020456
    ldr r2, =LCD_FCR                         @ 08020456
    ldr r2, [r2, #0]                         @ 08020458
    @ clear BLINK and BLINKF (mask 0x3E000)

    bics.w r2, r2, #253952                   @ 0802045A
    ldr r3, =LCD_FCR                         @ 0802045E
    str r2, [r3, #0]                         @ 08020460
    ldr r2, =LCD_FCR                         @ 08020462
    ldr r2, [r2, #0]                         @ 08020464
    orrs.w r3, r1, r0                        @ 08020466
    orrs r2, r3                              @ 0802046A
    ldr r3, =LCD_FCR                         @ 0802046C
    str r2, [r3, #0]                         @ 0802046E
    bx lr                                    @ 08020470
ENDFUNC fn_08020456
    .ltorg
    .global lcd_std_blink
    .set lcd_std_blink, fn_08020456

@ -----------------------------------------------------------------------------
@ fn_08020472 - LCD_ContrastConfig: set LCD_FCR.CC
@ Replaces : 0x08020472 FUN_08020472 (v2.05, 24 bytes)
@ In       : r0 = CC field value already shifted to bits 12:10 (0x0000 .. 0x1C00)
@ Out      : -
@ Clobbers : r1, r2, flags
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.2 LCD_FCR bits 12:10 (VLCD0 .. VLCD7)
@ -----------------------------------------------------------------------------
FUNC fn_08020472
    ldr r1, =LCD_FCR                         @ 08020472
    ldr r1, [r1, #0]                         @ 08020474
    @ clear CC[12:10] (mask 0x1C00)

    bics.w r1, r1, #7168                     @ 08020476
    ldr r2, =LCD_FCR                         @ 0802047A
    str r1, [r2, #0]                         @ 0802047C
    ldr r1, =LCD_FCR                         @ 0802047E
    ldr r1, [r1, #0]                         @ 08020480
    orrs r1, r0                              @ 08020482
    ldr r2, =LCD_FCR                         @ 08020484
    str r1, [r2, #0]                         @ 08020486
    bx lr                                    @ 08020488
ENDFUNC fn_08020472
    .ltorg
    .global lcd_std_contrast
    .set lcd_std_contrast, fn_08020472

@ -----------------------------------------------------------------------------
@ fn_0802048A - LCD_UpdateDisplayRequest: set LCD_SR.UDR
@ Replaces : 0x0802048A FUN_0802048A (v2.05, 8 bytes)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main only
@ RAM      : -
@ Spec     : RM0038 16.5.3 LCD_SR bit 2 UDR (set by software, cleared by hardware at the end of the update; LCD_RAM is
@            write-protected meanwhile), bit-band alias 0x42048108 (LCD_SR_UDR_BB)
@
@ -----------------------------------------------------------------------------
FUNC fn_0802048A
    movs r0, #1                              @ 0802048A
    ldr r1, =LCD_SR_UDR_BB                   @ 0802048C
    str r0, [r1, #0]                         @ 0802048E
    bx lr                                    @ 08020490
ENDFUNC fn_0802048A
    .ltorg
    .global lcd_std_update_request
    .set lcd_std_update_request, fn_0802048A

@ -----------------------------------------------------------------------------
@ fn_08020492 - LCD_GetFlagStatus: test a bit mask in LCD_SR
@ Replaces : 0x08020492 FUN_08020492 (v2.05, 26 bytes)
@ In       : r0 = flag mask (LCD_SR_ENS 1, SOF 2, UDR 4, UDD 8, RDY 0x10, FCRSF 0x20)
@ Out      : r0 = 1 if any selected bit is set, else 0
@ Context  : ISR-safe (one register read), but LCD commit is main-only by rule
@ RAM      : -
@ Spec     : RM0038 16.5.3 LCD_SR
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08020492
    movs r1, r0                              @ 08020492
    movs r0, #0                              @ 08020494
    ldr r2, =LCD_SR                          @ 08020496
    ldr r2, [r2, #0]                         @ 08020498
    tst r2, r1                               @ 0802049A
    beq .L080204A4                           @ 0802049C
    movs r2, #1                              @ 0802049E
    movs r0, r2                              @ 080204A0
    b .L080204A8                             @ 080204A2
.L080204A4:                                @ reached from 0802049C beq (equal / zero)
    movs r2, #0                              @ 080204A4
    movs r0, r2                              @ 080204A6
.L080204A8:                                @ reached from 080204A2 b; falls in
    uxtb r0, r0                              @ 080204A8
    bx lr                                    @ 080204AA
ENDFUNC fn_08020492
    .ltorg
    .global lcd_std_get_flag
    .set lcd_std_get_flag, fn_08020492

@ -----------------------------------------------------------------------------
@ lcd_commit_words - write the eight shadow words to LCD_RAM0..7 if they differ from the last committed copy
@ Replaces : the copy loop 0x0801B340..0x0801B390 of lcd_commit_shadow (production mode, IMP-06)
@ In       : -
@ Out      : r0 = 1 the words were written and the update requested, 0 nothing to do
@ Clobbers : r0-r3, flags
@ Context  : main only; called with UDR clear
@ RAM      : reads lcd_shadow (0x20007790), lcd_last, lcd_last_valid; writes LCD_RAM0..7, lcd_last, lcd_last_valid,
@            lcd_commit_pending
@ Spec     : RM0038 16.5.5 (LCD_RAM is write-protected while UDR = 1; the caller has just seen UDR clear)
@ Deviation: IMP-06 (v2.05 writes unconditionally)
@ -----------------------------------------------------------------------------
LFUNC lcd_commit_words
    push {r4, r5, r6, lr}
    ldr r4, =lcd_shadow                     @ r4 = &shadow word 0
    ldr r5, =lcd_last                       @ r5 = &last committed copy
    ldr r0, =lcd_last_valid
    ldrb r0, [r0]
    cbz r0, .Lcw_write                      @ copy not valid (after lcd_init or a partial commit): always write
    movs r1, #0                             @ r1 = word index
.Lcw_cmp:
    ldr r2, [r4, r1, lsl #2]                @ shadow word
    ldr r3, [r5, r1, lsl #2]                @ last committed word
    cmp r2, r3
    bne .Lcw_write                          @ first difference: write everything
    adds r1, r1, #1
    cmp r1, #8
    bcc .Lcw_cmp                            @ next word
    movs r0, #0                             @ identical: nothing to write
    ldr r1, =lcd_commit_pending
    strb r0, [r1]                           @ nothing owed any more
    pop {r4, r5, r6, pc}                    @ r0 = 0
.Lcw_write:
    ldr r6, =LCD_RAM                        @ r6 = &LCD_RAM0 (v2.05 0x40002414, words 0..7 at +4*i)
    movs r1, #0
.Lcw_copy:
    ldr r2, [r4, r1, lsl #2]
    str r2, [r6, r1, lsl #2]                @ LCD_RAM[i] = shadow[i]
    str r2, [r5, r1, lsl #2]                @ remember what the LCD now holds
    adds r1, r1, #1
    cmp r1, #8
    bcc .Lcw_copy
    bl fn_0802048A                          @ LCD_UpdateDisplayRequest: UDR = 1
    movs r0, #1
    ldr r1, =lcd_last_valid
    strb r0, [r1]                           @ lcd_last now equals LCD_RAM0..7
    movs r0, #0
    ldr r1, =lcd_commit_pending
    strb r0, [r1]                           @ nothing owed any more
    movs r0, #1                             @ written
    pop {r4, r5, r6, pc}
    .ltorg
ENDFUNC lcd_commit_words

@ -----------------------------------------------------------------------------
@ lcd_commit_retry - repeat a commit that was deferred because UDR was still set
@ Replaces : nothing (new, production mode, IMP-06); v2.05 waited inside lcd_commit_shadow instead
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (tail call of lcd_commit_shadow)
@ Context  : main only; called in every display refresh (fn_08016D34) and in the "-oFF-" beep loop of enter_stop_and_reinit.  A loop that stays blocking in production
@            mode and does not pass through fn_08016D34 must call it in its polling loop, otherwise a deferred commit waits
@            until that loop ends (requests W3_to_W7.md item 4, W3_to_W1.md item 8)
@ RAM      : reads lcd_commit_pending
@ Spec     : DESIGN.md 3.5 (production loop: commit deferred while UDR is set, never waits); RM0038 16.5.3 (UDR)
@ Deviation: IMP-06
@ -----------------------------------------------------------------------------
FUNC lcd_commit_retry
    ldr r0, =lcd_commit_pending
    ldrb r0, [r0]
    cbz r0, .Lcr_none                       @ nothing owed
    b lcd_commit_shadow                     @ tail call: repeats the owed kind (a full commit stays full), defers again if UDR is still set
.Lcr_none:
    bx lr
    .ltorg
ENDFUNC lcd_commit_retry

@ -----------------------------------------------------------------------------
@ lcd_commit_flush - wait until a deferred commit has been written (bounded)
@ Replaces : the UDR busy-wait of lcd_commit_shadow 0x0801B336 (v2.05) for the one production caller that needs v2.05's timing
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only; production start-up (bootwin_start, after the splash commit)
@ RAM      : reads lcd_commit_pending
@ Spec     : DESIGN.md 7.1 (first HY3131 write of the power-on window no earlier than in v2.05); RM0038 16.5.3 (UDR)
@ Deviation: HW-07 (the wait is bounded by LCD_WAIT_POLLS retries; on a timeout the commit stays owed to lcd_commit_retry)
@ v2.05 commits the splash with a UDR busy-wait that lasts until lcd_init's commit has been displayed (boot_v: splash commit
@ 79.96 ms, first HY3131 write 82.70 ms); the production commit only defers, so without this wait the window's first HY3131
@ write came at 70.2 ms.
@ -----------------------------------------------------------------------------
FUNC lcd_commit_flush
    push {r4, lr}
    ldr r4, =LCD_WAIT_POLLS                 @ retry budget (HW-07)
.Lcf_loop:
    ldr r0, =lcd_commit_pending
    ldrb r0, [r0]
    cbz r0, .Lcf_done                       @ nothing owed: the commit has been written
    bl lcd_commit_retry                     @ writes it once UDR is clear, else defers again
    subs r4, r4, #1
    bne .Lcf_loop
.Lcf_done:
    pop {r4, pc}
    .ltorg
ENDFUNC lcd_commit_flush
