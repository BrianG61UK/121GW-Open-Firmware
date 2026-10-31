@ =============================================================================
@ rms.s - MAC module: HY3131 true-RMS event (OF-16)
@
@ v2.05 services the RMS event (RMSF) with FUN_08008208: FUN_0800827C assembles RMS<39:8> from the mirror
@ bytes 0x200077D9..0x200077DD and computes (int)sqrt(x) << 3 (RT double square root), FUN_080082D4 keeps a
@ 4-sample average (0x20007DE8, ready flag 0x20008082), and one of four per-mode hooks runs
@ (FUN_0800A5B2 mode 0, FUN_0800A5BA mode 2, FUN_0800A7F8 mode 4, FUN_0800A7FA modes 16/18/20); the hooks
@ are `bx lr` (FUN_0800A5B2 calls FUN_0800A5BA, which is `bx lr`).  Every result word has exactly one
@ literal-pool reference, inside this handler, and an emulator run with read watchpoints from the first
@ instruction (ACV range 0, PEAK on, 20 s, 375 RMS interrupts) found no reader (ORIGINAL_FIRMWARE_ISSUES.md
@ OF-16, DESIGN.md 6.27).
@
@ Default build (MAC_RMS_SERVICE = 0, deviation OF-16): fn_08008208 computes nothing; the event is cleared by
@ the INTF clear that hy3131_service_irq already performs.  The six other v2.05 routines are not part of the
@ image.  Build with MAC_RMS_SERVICE=1 (switch of config.inc) to assemble all seven routines exactly as v2.05 has them (for
@ differential tests of the RMS path); that variant writes 0x20007D78, 0x20007DD8..0x20007DE8, 0x20008082 and
@ 0x20008083, which nothing reads.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.mac, "ax", %progbits

    .if MAC_RMS_SERVICE == 0
@ -----------------------------------------------------------------------------
@ fn_08008208 (mac_rms_event) - service of the HY3131 RMS event
@ Replaces : 0x08008208 FUN_08008208 (v2.05); 0x0800827C, 0x080082D4, 0x0800A5B2, 0x0800A5BA, 0x0800A7F8,
@            0x0800A7FA are built only with MAC_RMS_SERVICE = 1 (file header)
@ In       : -
@ Out      : -
@ Clobbers : none
@ Context  : main only (hy3131_service_irq)
@ RAM      : none
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-16; DESIGN.md 6.27
@ Deviation: OF-16 (nothing is computed; v2.05 computed and discarded the RMS value)
@ -----------------------------------------------------------------------------
FUNC fn_08008208
    bx lr                                   @ the event needs no processing beyond the INTF clear done by the caller
ENDFUNC fn_08008208
    .global mac_rms_event
    .set mac_rms_event, fn_08008208
    .else

@ -----------------------------------------------------------------------------
@ fn_08008208 (mac_rms_event) - service of the HY3131 RMS event (MAC_RMS_SERVICE = 1 only): RMS value, 4-sample average, per-mode hook
@ Replaces : 0x08008208 FUN_08008208 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (hy3131_service_irq)
@ RAM      : reads  0x20007DE0, 0x2000803C meter_mode
@            writes 0x20007D78 rms_copy, 0x20007DE0, 0x20008082
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-16; analysis/hy3131_model.md 4.4
@ Deviation: OF-16 (this variant is built only with MAC_RMS_SERVICE = 1)
@ -----------------------------------------------------------------------------
FUNC fn_08008208
    push {r7, lr}                        @ 08008208
    @ RMS value (sqrt(RMS<39:8>) << 3); kept in rms_copy; the average decides the ready flag 0x20008082
    bl fn_0800827C                       @ 0800820A
    ldr r1, =v_20007DE0                  @ 0800820E
    str r0, [r1]                         @ 08008212  v_20007DE0 (u32) = r0
    ldr r0, =v_20007DE0                  @ 08008214
    ldr r0, [r0]                         @ 08008218  r0 = v_20007DE0 (u32)
    ldr r1, =v_20007D78                  @ 0800821A
    str r0, [r1]                         @ 0800821E  rms_copy (u32) = v_20007DE0
    ldr r0, =v_20007DE0                  @ 08008220
    ldr r0, [r0]                         @ 08008224  r0 = v_20007DE0 (u32)
    bl fn_080082D4                       @ 08008226
    cmp r0, #0                           @ 0800822A
    beq .Lmac_rms_event_08008238         @ 0800822C  if r0 == 0
    movs r0, #1                          @ 0800822E
    ldr r1, =v_20008082                  @ 08008230
    strb r0, [r1]                        @ 08008234  v_20008082 (u8) = 1
    b .Lmac_rms_event_08008240           @ 08008236
.Lmac_rms_event_08008238:   @ branch target from 0800822C
    movs r0, #0                          @ 08008238
    ldr r1, =v_20008082                  @ 0800823A
    strb r0, [r1]                        @ 0800823E  v_20008082 (u8) = 0
.Lmac_rms_event_08008240:   @ branch target from 08008236
    @ per-mode hook: mode 0 FUN_0800A5B2, mode 2 FUN_0800A5BA, mode 4 FUN_0800A7F8, modes 16, 18, 20 FUN_0800A7FA
    ldr r0, =meter_mode                  @ 08008240
    ldrb r0, [r0]                        @ 08008244  r0 = meter_mode (u8)
    cmp r0, #0                           @ 08008246
    beq .Lmac_rms_event_08008260         @ 08008248  if meter_mode == 0
    cmp r0, #2                           @ 0800824A
    beq .Lmac_rms_event_08008266         @ 0800824C  if meter_mode == 2
    cmp r0, #4                           @ 0800824E
    beq .Lmac_rms_event_0800826C         @ 08008250  if meter_mode == 4
    cmp r0, #0x10                        @ 08008252
    beq .Lmac_rms_event_08008272         @ 08008254  if meter_mode == 16
    cmp r0, #0x12                        @ 08008256
    beq .Lmac_rms_event_08008272         @ 08008258  if meter_mode == 18
    cmp r0, #0x14                        @ 0800825A
    beq .Lmac_rms_event_08008272         @ 0800825C  if meter_mode == 20
    b .Lmac_rms_event_08008276           @ 0800825E
.Lmac_rms_event_08008260:   @ branch target from 08008248
    bl fn_0800A5B2                       @ 08008260
    b .Lmac_rms_event_08008276           @ 08008264
.Lmac_rms_event_08008266:   @ branch target from 0800824C
    bl fn_0800A5BA                       @ 08008266
    b .Lmac_rms_event_08008276           @ 0800826A
.Lmac_rms_event_0800826C:   @ branch target from 08008250
    bl fn_0800A7F8                       @ 0800826C
    b .Lmac_rms_event_08008276           @ 08008270
.Lmac_rms_event_08008272:   @ branch target from 08008254, 08008258, 0800825C
    bl fn_0800A7FA                       @ 08008272
.Lmac_rms_event_08008276:   @ branch target from 0800825E, 08008264, 0800826A, 08008270
    pop {r0, pc}                         @ 08008276
    .ltorg
ENDFUNC fn_08008208
    .global mac_rms_event
    .set mac_rms_event, fn_08008208

@ -----------------------------------------------------------------------------
@ fn_0800827C (mac_rms_value) - RMS value from the register mirror: (int)sqrt(RMS<39:8>) << 3 (MAC_RMS_SERVICE = 1 only)
@ Replaces : 0x0800827C FUN_0800827c (v2.05)
@ In       : -
@ Out      : r0 = value; 0x20007DDC = RMS<39:8>, 0x20007DD8 = byte 0x200077D9
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_08008208)
@ RAM      : reads  0x200077D0+9, 0x200077D0+10, 0x200077D0+11, 0x200077D0+12, 0x200077D0+13, 0x20007DDC
@            writes 0x20007DD8, 0x20007DDC
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-16
@ Deviation: OF-16 (built only with MAC_RMS_SERVICE = 1)
@ -----------------------------------------------------------------------------
FUNC fn_0800827C
    push {r4, lr}                        @ 0800827C
    ldr r0, =adc_regs                    @ 0800827E
    ldrb r0, [r0, #0xd]                  @ 08008282  r0 = v_200077DD (u8)
    ldr r1, =adc_regs                    @ 08008284
    ldrb r1, [r1, #0xc]                  @ 08008288  r1 = v_200077DC (u8)
    lsls r1, r1, #0x10                   @ 0800828A  r1 = v_200077DC << 0x10
    adds r0, r1, r0, lsl #24             @ 0800828C  r0 = (v_200077DC << 0x10) + (v_200077DD << 24)
    ldr r1, =adc_regs                    @ 08008290
    ldrb r1, [r1, #0xb]                  @ 08008294  r1 = v_200077DB (u8)
    adds r0, r0, r1, lsl #8              @ 08008296
    ldr r1, =adc_regs                    @ 0800829A
    ldrb r1, [r1, #0xa]                  @ 0800829E  r1 = v_200077DA (u8)
    adds r0, r1, r0                      @ 080082A0  r0 = v_200077DA + r0
    ldr r1, =v_20007DDC                  @ 080082A2
    str r0, [r1]                         @ 080082A6  v_20007DDC (u32) = (v_200077DA + r0)
    ldr r0, =adc_regs                    @ 080082A8
    ldrb r0, [r0, #9]                    @ 080082AC  r0 = v_200077D9 (u8)
    ldr r1, =v_20007DD8                  @ 080082AE
    str r0, [r1]                         @ 080082B2  v_20007DD8 (u32) = v_200077D9
    ldr r0, =v_20007DDC                  @ 080082B4
    ldr r0, [r0]                         @ 080082B8  r0 = v_20007DDC (u32)
    bl fn_08013ED8                       @ 080082BA  RT: double r0:r1 = (double)(uint32)r0
    bl fn_08013EF4                       @ 080082BE  RT: double r0:r1 = sqrt(r0:r1)
    bl fn_080132A0                       @ 080082C2  RT: int32 r0 = (int)double r0:r1 (truncating)
    lsls r0, r0, #3                      @ 080082C6  r0 = r0 << 3
    movs r4, r0                          @ 080082C8
    movs r0, r4                          @ 080082CA
    pop {r4, pc}                         @ 080082CC
    .ltorg
ENDFUNC fn_0800827C
    .global mac_rms_value
    .set mac_rms_value, fn_0800827C

@ -----------------------------------------------------------------------------
@ fn_080082D4 (mac_rms_average) - 4-sample sum and average of the RMS value (MAC_RMS_SERVICE = 1 only)
@ Replaces : 0x080082D4 FUN_080082d4 (v2.05)
@ In       : r0 = RMS value
@ Out      : r0 = 1 when the fourth sample completed an average (0x20007DE8, ready flag 0x20008082), else 0
@ Clobbers : r0, r1, r2, r3, flags
@ Context  : main only (fn_08008208)
@ RAM      : reads  0x20007DE4, 0x20008083
@            writes 0x20007DE4, 0x20007DE8, 0x20008083
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-16
@ Deviation: OF-16 (built only with MAC_RMS_SERVICE = 1)
@ -----------------------------------------------------------------------------
FUNC fn_080082D4
    movs r1, r0                          @ 080082D4
    movs r0, #0                          @ 080082D6
    ldr r2, =v_20008083                  @ 080082D8
    ldrb r2, [r2]                        @ 080082DC  r2 = v_20008083 (u8)
    cmp r2, #0                           @ 080082DE
    bne .Lmac_rms_average_080082EA       @ 080082E0  if v_20008083 != 0
    ldr r2, =v_20007DE4                  @ 080082E2
    str r1, [r2]                         @ 080082E6  v_20007DE4 (u32) = r1
    b .Lmac_rms_average_080082F8         @ 080082E8
.Lmac_rms_average_080082EA:   @ branch target from 080082E0
    ldr r2, =v_20007DE4                  @ 080082EA
    ldr r2, [r2]                         @ 080082EE  r2 = v_20007DE4 (u32)
    adds r2, r1, r2                      @ 080082F0  r2 = r1 + v_20007DE4
    ldr r3, =v_20007DE4                  @ 080082F2
    str r2, [r3]                         @ 080082F6  v_20007DE4 (u32) = (r1 + v_20007DE4)
.Lmac_rms_average_080082F8:   @ branch target from 080082E8
    ldr r2, =v_20008083                  @ 080082F8
    ldrb r2, [r2]                        @ 080082FC  r2 = v_20008083 (u8)
    adds r2, r2, #1                      @ 080082FE  r2 = v_20008083 + 1
    ldr r3, =v_20008083                  @ 08008300
    strb r2, [r3]                        @ 08008304  v_20008083 (u8) = (v_20008083 + 1)
    ldr r2, =v_20008083                  @ 08008306
    ldrb r2, [r2]                        @ 0800830A  r2 = v_20008083 (u8)
    cmp r2, #4                           @ 0800830C
    blt .Lmac_rms_average_0800833A       @ 0800830E  if v_20008083 < (signed) 4
    ldr r2, =v_20007DE4                  @ 08008310
    ldr r2, [r2]                         @ 08008314  r2 = v_20007DE4 (u32)
    ldr r3, =v_20008083                  @ 08008316
    ldrb r3, [r3]                        @ 0800831A  r3 = v_20008083 (u8)
    udiv r2, r2, r3                      @ 0800831C  r2 = v_20007DE4 / v_20008083
    ldr r3, =v_20007DE8                  @ 08008320
    str r2, [r3]                         @ 08008324  v_20007DE8 (u32) = (v_20007DE4 / v_20008083)
    movs r2, #0                          @ 08008326
    ldr r3, =v_20008083                  @ 08008328
    strb r2, [r3]                        @ 0800832C  v_20008083 (u8) = 0
    movs r2, #0                          @ 0800832E
    ldr r3, =v_20007DE4                  @ 08008330
    str r2, [r3]                         @ 08008334  v_20007DE4 (u32) = 0
    movs r2, #1                          @ 08008336
    movs r0, r2                          @ 08008338
.Lmac_rms_average_0800833A:   @ branch target from 0800830E
    uxtb r0, r0                          @ 0800833A
    bx lr                                @ 0800833C
    .ltorg
ENDFUNC fn_080082D4
    .global mac_rms_average
    .set mac_rms_average, fn_080082D4

@ -----------------------------------------------------------------------------
@ fn_0800A5B2 (mac_rms_hook0) - RMS hook of mode 0: calls fn_0800A5BA (MAC_RMS_SERVICE = 1 only)
@ Replaces : 0x0800A5B2 FUN_0800a5b2 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_08008208)
@ RAM      : reads  -
@            writes -
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-16
@ Deviation: OF-16 (built only with MAC_RMS_SERVICE = 1)
@ -----------------------------------------------------------------------------
FUNC fn_0800A5B2
    push {r7, lr}                        @ 0800A5B2
    bl fn_0800A5BA                       @ 0800A5B4
    pop {r0, pc}                         @ 0800A5B8
    .ltorg
ENDFUNC fn_0800A5B2
    .global mac_rms_hook0
    .set mac_rms_hook0, fn_0800A5B2

@ -----------------------------------------------------------------------------
@ fn_0800A5BA (mac_rms_hook2) - RMS hook of mode 2: returns (MAC_RMS_SERVICE = 1 only)
@ Replaces : 0x0800A5BA FUN_0800a5ba (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : none, flags
@ Context  : main only (fn_08008208)
@ RAM      : reads  -
@            writes -
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-16
@ Deviation: OF-16 (built only with MAC_RMS_SERVICE = 1)
@ -----------------------------------------------------------------------------
FUNC fn_0800A5BA
    bx lr                                @ 0800A5BA
    .ltorg
ENDFUNC fn_0800A5BA
    .global mac_rms_hook2
    .set mac_rms_hook2, fn_0800A5BA

@ -----------------------------------------------------------------------------
@ fn_0800A7F8 (mac_rms_hook4) - RMS hook of mode 4: returns (MAC_RMS_SERVICE = 1 only)
@ Replaces : 0x0800A7F8 FUN_0800a7f8 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : none, flags
@ Context  : main only (fn_08008208)
@ RAM      : reads  -
@            writes -
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-16
@ Deviation: OF-16 (built only with MAC_RMS_SERVICE = 1)
@ -----------------------------------------------------------------------------
FUNC fn_0800A7F8
    bx lr                                @ 0800A7F8
    .ltorg
ENDFUNC fn_0800A7F8
    .global mac_rms_hook4
    .set mac_rms_hook4, fn_0800A7F8

@ -----------------------------------------------------------------------------
@ fn_0800A7FA (mac_rms_hook20) - RMS hook of modes 16, 18, 20: returns (MAC_RMS_SERVICE = 1 only)
@ Replaces : 0x0800A7FA FUN_0800a7fa (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : none, flags
@ Context  : main only (fn_08008208)
@ RAM      : reads  -
@            writes -
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-16
@ Deviation: OF-16 (built only with MAC_RMS_SERVICE = 1)
@ -----------------------------------------------------------------------------
FUNC fn_0800A7FA
    bx lr                                @ 0800A7FA
    .ltorg
ENDFUNC fn_0800A7FA
    .global mac_rms_hook20
    .set mac_rms_hook20, fn_0800A7FA

    .endif
