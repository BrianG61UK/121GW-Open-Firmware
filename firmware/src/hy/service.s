@ =============================================================================
@ service.s - HY: HY3131 event polling, interrupt service and AD1 dispatch
@
@ Replaces v2.05 hy3131_poll 0x08006124, hy3131_service_irq 0x0800614E and ad1_ready_dispatch 0x080061E4.
@
@ IMP-06 (DESIGN.md 6.13): v2.05 hy3131_service_irq reads the whole 0x34-byte register block per event (0x08006158); the port
@ services the same event but reads only the registers a consumer of that event reads, so that the 640 sps rows (BEEP, ACV r3, DCmV r1, LowZ AC; period 1.5625 ms) can be serviced every conversion.
@
@ OF-16: the RMS event (INTF bit 4) is serviced by the INTF clear alone; v2.05 FUN_08008208 (square root, 4-sample average and
@ four hooks that are bx lr) is not called, its results have no reader.  INTE values are unchanged (the peak rows use RMSIE as
@ their periodic trigger for the peak routine).
@
@ OF-53 (both builds): the INTF write after the read acknowledges only the flags that were read as set (0 for those, 1 for
@ the others; INTF bits clear only on a written 0, DS p19 10.2 (7)); v2.05 writes 0 and loses a flag raised in between.
@ OF-54 (both builds): counter data and CTF belong to the same completed count (baseline: the counter block is read again
@ after CTF is seen; production: INTF is read first and the counter block after it).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    @ INTF bits that carry a flag (DS p19 10.2): BORF 7, RMSF 4, LPFF 3, AD1F 2, AD2F 1, CTF 0; bits 6:5 are "-"
    .equ HY_INTF_ACK_MASK, 0x9F

    .section .text.hy.service, "ax", %progbits

@ -----------------------------------------------------------------------------
@ hy3131_poll - poll the HY3131 event line once per main-loop pass
@ Replaces : 0x08006124 hy3131_poll (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x2000803D meter_range, hy_restart_pend (production)
@ Spec     : analysis/hy3131_model.md 2.1; DESIGN.md 3.5 step 1, 4.1 item 8
@ Deviation: IMP-06 (counter restart finished by hy_counter_restart_step; no event service while a restart is pending)
@ PF3 (HY_DO) is the HY3131 interrupt output while CS is high: GPIOF IDR bit 3 set = an enabled event is pending (DS p15).
@ -----------------------------------------------------------------------------
FUNC hy3131_poll
    push {r7, lr}                      @ 0x08006124
    @ production: while a counter restart is pending (counter off, R20 = row & 0xFD / 0xF9) no event is serviced, so neither the
    @ INTF clear nor the peak restart (R29 writes, FUN_0800A7FC) nor a new restart can be sent between restart phase 1 and 3.
    @ v2.05 services nothing during its blocking delay(10000) (0x0800BFCE), so registers 0x20..0x33 only ever hold v2.05
    @ states (DESIGN.md 4.1 item 8); the pending event keeps PF3 high and is serviced in the pass after phase 3.
    ldr r0, =hy_restart_pend
    ldrb r0, [r0]
    cmp r0, #0
    bne .L08006134                          @ restart pending: skip the event service this pass
    ldr r0, =(GPIOF_BASE + GPIO_IDR)   @ 0x08006126 pool 0x08006ACC = 0x40021810  GPIOF IDR
    ldrh r0, [r0, #0]                  @ 0x0800612A  IDR (halfword)
    lsls r0, r0, #28                   @ 0x0800612C  move bit 3 (PF3) to the sign flag
    bpl .L08006134                     @ 0x0800612E  PF3 low: no event
    bl hy3131_service_irq              @ 0x08006130  event pending: service it
.L08006134:                              @ reached from 0x0800612E bpl
    bl hy_counter_restart_step              @ production: finish a pending counter restart once its TIM3 wait ran out
    @ ---- CAP: no counter result within the timeout in mode 12, ranges 0..4 -> FUN_0800B540 (v2.05 0x08006134..0x08006148) ----
    ldr r0, =meter_mode                @ 0x08006134 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006138
    cmp r0, #12                        @ 0x0800613A  mode 12 = CAP?
    bne .L0800614C                     @ 0x0800613C  not CAP
    ldr r0, =meter_range               @ 0x0800613E pool 0x08006CF8 = 0x2000803D
    ldrb r0, [r0, #0]                  @ 0x08006142
    cmp r0, #5                         @ 0x08006144  range < 5 (CAP range 5 has no timeout handling)
    bge .L0800614C                     @ 0x08006146
    bl fn_0800B540                     @ 0x08006148  CAP timeout check (MRES)
.L0800614C:                              @ reached from 0x0800613C bne, 0x08006146 bge
    pop {r0, pc}                       @ 0x0800614C
    .ltorg
ENDFUNC hy3131_poll

@ -----------------------------------------------------------------------------
@ hy3131_service_irq - service one HY3131 event (baseline: full register burst)
@ Replaces : 0x0800614E hy3131_service_irq (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x200080BA acdc_active, 0x200077D0 adc_regs, 0x2000807E, 0x2000807F
@            writes 0x20007DC4, 0x2000807D, 0x2000807E, 0x2000807F
@ Spec     : analysis/hy3131_model.md 2.1
@ Deviation: OF-16 (no call of FUN_08008208), OF-53 (INTF acknowledge value), OF-54 (counter block read again on CTF)
@ Steps (v2.05): read registers 0x00..0x33; write INTF = 0 (register 0x1E, byte 0x20007DC4 = 0); event mask 0x2000807F =
@ INTF & INTE; copies of R20 (0x2000807D) and R29 (0x2000807E); AD1F -> ad1_ready_dispatch; RMSF -> (v2.05 FUN_08008208, dropped,
@ OF-16); peak gate: R29 bit 2 (ENPKH) and AC+DC off -> FUN_0800A7FC; CTF -> FUN_0800AA00.
@ Port: the INTF write clears only the flags read (OF-53) and CTF reads the counter block 0x14..0x1D again before
@ FUN_0800AA00 (OF-54).
@ -----------------------------------------------------------------------------

@ -----------------------------------------------------------------------------
@ hy3131_service_irq (production) - service one HY3131 event with per-event register reads
@ Replaces : 0x0800614E hy3131_service_irq (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 preserved)
@ Context  : main only
@ RAM      : reads  0x200080BA acdc_active, 0x200077D0 adc_regs, 0x2000807E, 0x2000807F
@            writes 0x20007DC4, 0x2000807E, 0x2000807F; reads hy_row_r29
@ Spec     : DESIGN.md 6.13 (read sets); analysis/hy3131_modes_misc.md 8 (mirror readers); hy3131_model.md 2.1
@ Deviation: IMP-06, IMP-18 (no R20 read; R29 read only for a row with ENPKH), OF-16, OF-53 (INTF acknowledge value); OF-54 needs no extra read here: INTF is read first and the
@            counter block only after CTF has been seen, so data and flag always belong to the same completed count
@ Read sets (all with the v2.05 read command format and bit timing, hy_read_frame):
@   every event  registers 0x1E..0x1F (INTF, INTE; reading INTF clears it, DS p19); 0x29 (R29, ENPKH test) only when
@                the loaded row sets ENPKH (IMP-18)
@   AD1F         registers 0x00..0x02 (AD1 data, read by FUN_080062F8)
@   peak gate    registers 0x0E..0x13 (PKHMIN, PKHMAX, read by FUN_0800A7FC)
@   CTF          registers 0x14..0x1D (CTSTA, whose read clears CTBOV, DS p36, then CTC, CTB, CTA read by FUN_0800AB48)
@ The RMS block 0x09..0x0D is not read (OF-16; only with MAC_RMS_SERVICE = 1 the block is read and fn_08008208 called); AD2 0x03..0x05, LPF 0x06..0x08 and 0x21..0x28, 0x2A..0x33 have no reader.
@ -----------------------------------------------------------------------------
FUNC hy3131_service_irq
    push {r4, lr}
    movs r0, #0x1E
    movs r1, #2
    bl hy_read_frame                        @ mirror[0x1E..0x1F] = INTF, INTE (IMP-18: R20 is not read back, its copy
                                            @ 0x2000807D has no reader; hy_row_r20 holds the R20 written)
    ldr r0, =adc_regs
    ldrb r0, [r0, #30]                      @ INTF as read
    mvns r0, r0                             @ OF-53: 0 for the flags seen set, 1 for the others (a written 1 has no effect,
    and r0, r0, #HY_INTF_ACK_MASK           @ DS p19 10.2 (7)); bits 6:5 ("-") 0 as v2.05 writes them
    ldr r1, =v_20007DC4
    strb r0, [r1]                           @ write buffer (v2.05 0x08006162 stores 0)
    movs r2, #1
    movs r1, #30                            @ register 0x1E = INTF
    ldr r0, =v_20007DC4
    bl hy3131_write_regs                    @ INTF <- acknowledge value (v2.05 0x0800616C writes 0; OF-53)
    @ IMP-18: R29 is read back only when the loaded row sets ENPKH (bit 2, the peak rows).  Every R29 write leaves the chip
    @ at hy_row_r29: the row write sets both or neither (whitelist refusal), hy_peak_restart clears ENPKH and writes
    @ hy_row_r29 back inside one call.  With ENPKH clear in hy_row_r29 the read returns hy_row_r29, so it is not made (only
    @ after a chip brown-out reset, whose R29 value the datasheet does not state, could the read differ).
    ldr r0, =hy_row_r29
    ldrb r1, [r0]
    tst r1, #4
    beq .Lps_r29_known                      @ ENPKH clear in the loaded row: R29 = hy_row_r29
    movs r0, #0x29
    movs r1, #1
    bl hy_read_frame                        @ mirror[0x29] = R29
    ldr r0, =adc_regs
    ldrb r1, [r0, #41]                      @ R29 as read
.Lps_r29_known:
    ldr r3, =v_2000807E
    strb r1, [r3]                           @ copy of R29 (ENPKH test below)
    ldr r0, =adc_regs
    ldrb r1, [r0, #30]                      @ INTF
    ldrb r2, [r0, #31]                      @ INTE
    ands r1, r2                             @ enabled events
    ldr r3, =v_2000807F
    strb r1, [r3]                           @ event mask (v2.05 0x08006182)
    ldr r0, =v_2000807F
    ldrb r0, [r0]
    lsls r0, r0, #29                        @ mask bit 2 = AD1F
    bpl .Lps_nad1
    movs r0, #0
    movs r1, #3
    bl hy_read_frame                        @ mirror[0..2] = AD1 result
    bl ad1_ready_dispatch
.Lps_nad1:
.if MAC_RMS_SERVICE
    ldr r0, =v_2000807F
    ldrb r0, [r0]
    lsls r0, r0, #27                        @ mask bit 4 = RMSF
    bpl .Lps_normsf
    movs r0, #0x09
    movs r1, #5
    bl hy_read_frame                        @ mirror[0x09..0x0D] = RMS (read by fn_0800827C), MAC_RMS_SERVICE = 1 only
    bl fn_08008208                          @ v2.05 0x080061B8
.Lps_normsf:
.else
    @ RMSF (mask bit 4): nothing to do beyond the INTF clear, OF-16
.endif
    ldr r0, =v_2000807E
    ldrb r0, [r0]
    lsls r0, r0, #29                        @ R29 bit 2 = ENPKH
    bpl .Lps_nopk
    ldr r0, =acdc_active
    ldrb r0, [r0]
    cbnz r0, .Lps_nopk                      @ AC+DC active: no peak routine
    movs r0, #0x0E
    movs r1, #6
    bl hy_read_frame                        @ mirror[0x0E..0x13] = PKHMIN, PKHMAX
    bl fn_0800A7FC                          @ MAC: peak value (calls hy_peak_restart)
.Lps_nopk:
    ldr r0, =v_2000807F
    ldrb r0, [r0]
    lsls r0, r0, #31                        @ mask bit 0 = CTF
    bpl .Lps_done
    movs r0, #0x14
    movs r1, #10
    bl hy_read_frame                        @ mirror[0x14..0x1D] = CTSTA, CTC, CTB, CTA
    bl fn_0800AA00                          @ MFRQ: counter result
.Lps_done:
    pop {r4, pc}
    .ltorg
ENDFUNC hy3131_service_irq

@ -----------------------------------------------------------------------------
@ ad1_ready_dispatch - AD1 conversion ready: decode, accumulate and call the mode handler
@ Replaces : 0x080061E4 ad1_ready_dispatch (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x200080BA acdc_active, 0x200080BD acdc_use_dcv_cal, 0x2000803C meter_mode, 0x20007DCC
@            writes 0x20007D74, 0x20007DCC, 0x20008081
@ Spec     : analysis/hy3131_model.md 4.1, 4.2
@ Deviation: IMP-01 (production pre-step)
@ Called once per AD1 conversion (every conversion in production mode, every serviced conversion in baseline mode).  Production only: for the auto-ranged DC
@ modes mdc_sample_precheck runs first and may discard the conversion (ar_sample, IMP-01).  The mode
@ handlers do the per-sample and, when 0x20008081 = 1, the per-mean work.  Modes 6, 7, 8, 12 (counter modes) have no AD1 handler.
@ -----------------------------------------------------------------------------
FUNC ad1_ready_dispatch
    push {r7, lr}                      @ 0x080061E4
    bl fn_080062F8                     @ 0x080061E6  FUN_080062F8: decode rx[0..2] to a signed 24-bit value (MDC; OF-14)
    ldr r1, =v_20007DCC                @ 0x080061EA pool 0x08006AE8 = 0x20007DCC
    str r0, [r1, #0]                   @ 0x080061EE  0x20007DCC = decoded sample
    ldr r0, =v_20007DCC                @ 0x080061F0 pool 0x08006AE8 = 0x20007DCC
    ldr r0, [r0, #0]                   @ 0x080061F4
    ldr r1, =v_20007D74                @ 0x080061F6 pool 0x08006D08 = 0x20007D74
    str r0, [r1, #0]                   @ 0x080061FA  0x20007D74 = latest sample (all modes)
    @ IMP-01 (production): before the conversion is accumulated, the auto-ranged DC modes judge the calibrated per-sample value (ar_sample, AR); r0 = 1: this
    @ conversion belongs to the settling after an apply (or an apply is pending) and is discarded - neither accumulated nor handled (MDC mdc_sample_precheck
    @ for the DC modes, MAC mac_sample_precheck for the AC modes; each returns 0 at once for a mode it does not judge)
    bl mdc_sample_precheck                  @ auto-ranged DC modes 1, 3, 9, 17, 19, 21: r0 = 1 discard
    cbnz r0, 2f
    bl mac_sample_precheck                  @ AC modes 2, 4, 16, 18, 20 (W6, src/mac/sample.s; the mode sets are disjoint): r0 = 1 discard
    cbz r0, 1f
2:  movs r0, #0
    ldr r1, =v_20008081
    strb r0, [r1]                           @ no mean completed by a discarded conversion
    pop {r0, pc}
1:
    ldr r0, =v_20007DCC                @ 0x080061FC pool 0x08006AE8 = 0x20007DCC
    ldr r0, [r0, #0]                   @ 0x08006200
    bl ad1_accumulate_average          @ 0x08006202  ad1_accumulate_average: sum, count; r0 = 1 when a mean is complete
    ldr r1, =v_20008081                @ 0x08006206 pool 0x08006D0C = 0x20008081
    strb r0, [r1, #0]                  @ 0x0800620A  0x20008081 = mean-ready flag
    @ ---- modes 22, 23, 24 DC VA -> FUN_080084E0 ----
    ldr r0, =meter_mode                @ 0x0800620C pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006210
    cmp r0, #22                        @ 0x08006212
    beq .L0800622A                     @ 0x08006214
    ldr r0, =meter_mode                @ 0x08006216 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800621A
    cmp r0, #23                        @ 0x0800621C
    beq .L0800622A                     @ 0x0800621E
    ldr r0, =meter_mode                @ 0x08006220 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006224
    cmp r0, #24                        @ 0x08006226
    bne .L08006230                     @ 0x08006228
.L0800622A:                              @ reached from 0x08006214 beq, 0x0800621E beq
    bl fn_080084E0                     @ 0x0800622A
    b .L080062F6                       @ 0x0800622E
.L08006230:                              @ reached from 0x08006228 bne
    @ ---- modes 13, 14, 15 VA -> FUN_08008B8C ----
    ldr r0, =meter_mode                @ 0x08006230 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006234
    cmp r0, #13                        @ 0x08006236
    beq .L0800624E                     @ 0x08006238
    ldr r0, =meter_mode                @ 0x0800623A pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800623E
    cmp r0, #14                        @ 0x08006240
    beq .L0800624E                     @ 0x08006242
    ldr r0, =meter_mode                @ 0x08006244 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006248
    cmp r0, #15                        @ 0x0800624A
    bne .L08006254                     @ 0x0800624C
.L0800624E:                              @ reached from 0x08006238 beq, 0x08006242 beq
    bl fn_08008B8C                     @ 0x0800624E
    b .L080062F6                       @ 0x08006252
.L08006254:                              @ reached from 0x0800624C bne
    @ ---- dispatch by mode (hy3131_model.md 4.2): 0 -> FUN_08006540 (LowZ), 1 DCV / 2 ACV with AC+DC and 0x200080BD -> FUN_08007714,
    @      2 ACV -> FUN_08006AEC, 3 DCmV -> FUN_080077F0, 4 ACmV -> FUN_080069B4, 5 TEMP -> FUN_08007840, 9 OHM -> FUN_080079C4,
    @      10 BEEP -> FUN_080078B8, 11 DIODE -> FUN_08007E84, 17/19/21 DC currents -> FUN_08007FA8, 16/18/20 AC currents -> FUN_0800664A ----
    ldr r0, =meter_mode                @ 0x08006254 pool 0x08006AD0 = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08006258
    cmp r0, #0                         @ 0x0800625A
    beq .L08006298                     @ 0x0800625C
    cmp r0, #1                         @ 0x0800625E
    beq .L080062C8                     @ 0x08006260
    cmp r0, #2                         @ 0x08006262
    beq .L080062A4                     @ 0x08006264
    cmp r0, #3                         @ 0x08006266
    beq .L080062CE                     @ 0x08006268
    cmp r0, #4                         @ 0x0800626A
    beq .L0800629E                     @ 0x0800626C
    cmp r0, #5                         @ 0x0800626E
    beq .L080062D4                     @ 0x08006270
    cmp r0, #9                         @ 0x08006272
    beq .L080062E0                     @ 0x08006274
    cmp r0, #10                        @ 0x08006276
    beq .L080062DA                     @ 0x08006278
    cmp r0, #11                        @ 0x0800627A
    beq .L080062E6                     @ 0x0800627C
    cmp r0, #16                        @ 0x0800627E
    beq .L080062F2                     @ 0x08006280
    cmp r0, #17                        @ 0x08006282
    beq .L080062EC                     @ 0x08006284
    cmp r0, #18                        @ 0x08006286
    beq .L080062F2                     @ 0x08006288
    cmp r0, #19                        @ 0x0800628A
    beq .L080062EC                     @ 0x0800628C
    cmp r0, #20                        @ 0x0800628E
    beq .L080062F2                     @ 0x08006290
    cmp r0, #21                        @ 0x08006292
    beq .L080062EC                     @ 0x08006294
    b .L080062F6                       @ 0x08006296
.L08006298:                              @ reached from 0x0800625C beq
    bl fn_08006540                     @ 0x08006298
    b .L080062F6                       @ 0x0800629C
.L0800629E:                              @ reached from 0x0800626C beq
    bl fn_080069B4                     @ 0x0800629E
    b .L080062F6                       @ 0x080062A2
.L080062A4:                              @ reached from 0x08006264 beq
    ldr r0, =acdc_active               @ 0x080062A4 pool 0x08006D00 = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x080062A8
    cmp r0, #0                         @ 0x080062AA
    beq .L080062C2                     @ 0x080062AC
    ldr r0, =acdc_active               @ 0x080062AE pool 0x08006D00 = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x080062B2
    cmp r0, #0                         @ 0x080062B4
    beq .L080062C8                     @ 0x080062B6
    ldr r0, =acdc_use_dcv_cal          @ 0x080062B8 pool 0x08006D10 = 0x200080BD
    ldrb r0, [r0, #0]                  @ 0x080062BC
    cmp r0, #0                         @ 0x080062BE
    bne .L080062C8                     @ 0x080062C0
.L080062C2:                              @ reached from 0x080062AC beq
    bl fn_08006AEC                     @ 0x080062C2
    b .L080062F6                       @ 0x080062C6
.L080062C8:                              @ reached from 0x08006260 beq, 0x080062B6 beq, 0x080062C0 bne
    bl fn_08007714                     @ 0x080062C8
    b .L080062F6                       @ 0x080062CC
.L080062CE:                              @ reached from 0x08006268 beq
    bl fn_080077F0                     @ 0x080062CE
    b .L080062F6                       @ 0x080062D2
.L080062D4:                              @ reached from 0x08006270 beq
    bl fn_08007840                     @ 0x080062D4
    b .L080062F6                       @ 0x080062D8
.L080062DA:                              @ reached from 0x08006278 beq
    bl fn_080078B8                     @ 0x080062DA
    b .L080062F6                       @ 0x080062DE
.L080062E0:                              @ reached from 0x08006274 beq
    bl fn_080079C4                     @ 0x080062E0
    b .L080062F6                       @ 0x080062E4
.L080062E6:                              @ reached from 0x0800627C beq
    bl fn_08007E84                     @ 0x080062E6
    b .L080062F6                       @ 0x080062EA
.L080062EC:                              @ reached from 0x08006284 beq, 0x0800628C beq, 0x08006294 beq
    bl fn_08007FA8                     @ 0x080062EC
    b .L080062F6                       @ 0x080062F0
.L080062F2:                              @ reached from 0x08006280 beq, 0x08006288 beq, 0x08006290 beq
    bl fn_0800664A                     @ 0x080062F2
.L080062F6:                              @ reached from 0x0800622E b, 0x08006252 b, 0x08006296 b, 0x0800629C b, 0x080062A2 b, 0x080062C6 b, 0x080062CC b, 0x080062D2 b, 0x080062D8 b, 0x080062DE b, 0x080062E4 b, 0x080062EA b, 0x080062F0 b
    pop {r0, pc}                       @ 0x080062F6
    .ltorg
ENDFUNC ad1_ready_dispatch

