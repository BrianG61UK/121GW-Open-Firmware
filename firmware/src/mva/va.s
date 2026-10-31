@ =============================================================================
@ va.s - MVA module: VA modes (13 uVA, 14 mVA, 15 VA = AC; 22 DCuVA, 23 DCmVA, 24 DCVA = DC)
@
@ A VA mode measures voltage and current with the one AD1 in time multiplex.  va_channel (0x200080C4) says
@ which: 0 = voltage, 1 = current.  Each channel is measured for 4 (voltage) or 7 (current) completed
@ 16-sample means (va_mean_count 0x200080C5), the last smoothed value is kept (va_voltage 0x20007D7C,
@ va_current 0x20007D80), the burden correction and the autorange of the channel run, and the channel switches
@ (HY3131 row, INTE).  After a complete cycle the power is |V| * |I| / d.  Spec:
@ analysis/hy3131_modes_ac_current.md 12 (VA.1..VA.9).  Sub-ranges: va_vsub (0x200080C6) and va_isub
@ (0x200080C7); meter_range is derived from them by fn_080148F6 and back by fn_0801485A.
@ In calibration mode (cal_mode != 0, channel 1) the handlers accumulate voltage and current for the
@ offset / gain capture in 64-bit sums and write the record through cal_record_write (CAL / NVM).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.mva, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_080084E0 (mva_va_dc) - AD1 handler of the DC VA modes 22, 23, 24: channel chain, 64-bit calibration sums, burden correction,
@   autorange of the channel, channel switch and power
@ Replaces : 0x080084E0 FUN_080084e0 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (ad1_ready_dispatch 0x0800622A)
@ Registers: r4 = phase length
@ RAM      : reads  0x20007C10 va_sum_v_dc, 0x20007C18 va_sum_i_dc, 0x20007D64 reading, 0x20007D7C va_voltage,
@            0x20007D80 va_current, 0x20007E10 cal_gain, 0x2000803C meter_mode, 0x2000805D new_reading,
@            0x20008081 mean_ready, 0x2000808A cal_mode, 0x2000808C cal_req_offset, 0x2000808E cal_req_gain,
@            0x20008095 cal_countdown, 0x200080C3 va_range_changed, 0x200080C4 va_channel, 0x200080C5 va_mean_count,
@            0x200080C7 va_isub, 0x200080CA va_v_over, 0x200080CB va_i_over
@            writes 0x20007C10 va_sum_v_dc, 0x20007C18 va_sum_i_dc, 0x20007D68 sample_value, 0x20007D7C va_voltage,
@            0x20007D80 va_current, 0x20007E20 cal_gain_in, 0x20007E24 va_off_v, 0x20007E28 va_off_i,
@            0x20007E2C va_gain_v, 0x20007E30 va_gain_i, 0x20008046 overload, 0x2000804C annun_request,
@            0x2000805D new_reading, 0x2000805E bargraph_update, 0x20008060, 0x20008062 sec_refresh,
@            0x2000808C cal_req_offset, 0x2000808D cal_offset_done, 0x2000808E cal_req_gain, 0x2000808F cal_gain_done,
@            0x20008095 cal_countdown, 0x200080BF va_dashes, 0x200080C3 va_range_changed, 0x200080C4 va_channel,
@            0x200080C5 va_mean_count
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.1, VA.4, VA.7), keys_setup.md 5.3 (VA calibration)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_080084E0
    push {r4, lr}                        @ 080084E0
    @ r4 = phase length (3 or 6, set below); va_range_changed = 0
    movs r4, #0                          @ 080084E2
    movs r0, #0                          @ 080084E4
    ldr r1, =v_200080C3                  @ 080084E6
    strb r0, [r1]                        @ 080084EA  va_range_changed (u8) = 0
    @ the chain of the active channel: 0 = voltage fn_08007714, 1 = current fn_08008138; a completed mean is kept in va_voltage / va_current
    ldr r0, =va_channel                  @ 080084EC
    ldrb r0, [r0]                        @ 080084F0  r0 = va_channel (u8)
    cmp r0, #0                           @ 080084F2
    beq .Lmva_va_dc_volt                 @ 080084F4  if va_channel == 0
    cmp r0, #1                           @ 080084F6
    beq .Lmva_va_dc_cur                  @ 080084F8  if va_channel == 1
    b .Lmva_va_dc_after                  @ 080084FA
.Lmva_va_dc_volt:   @ voltage channel
    bl fn_08007714                       @ 080084FC  MDC: DC voltage channel value into reading
    ldr r0, =v_20008081                  @ 08008500
    ldrb r0, [r0]                        @ 08008502  r0 = mean_ready (u8)
    cmp r0, #0                           @ 08008504
    beq .Lmva_va_dc_08008512             @ 08008506  if mean_ready == 0
    ldr r0, =v_20007D64                  @ 08008508
    ldr r0, [r0]                         @ 0800850A  r0 = reading (u32)
    ldr r1, =v_20007D7C                  @ 0800850C
    str r0, [r1]                         @ 08008510  va_voltage (u32) = reading
.Lmva_va_dc_08008512:   @ branch target from 08008506
    b .Lmva_va_dc_after                  @ 08008512
.Lmva_va_dc_cur:   @ current channel
    bl fn_08008138                       @ 08008514  MDC: DC current channel value into reading
    ldr r0, =v_20008081                  @ 08008518
    ldrb r0, [r0]                        @ 0800851A  r0 = mean_ready (u8)
    cmp r0, #0                           @ 0800851C
    beq .Lmva_va_dc_after                @ 0800851E  if mean_ready == 0
    ldr r0, =v_20007D64                  @ 08008520
    ldr r0, [r0]                         @ 08008522  r0 = reading (u32)
    ldr r1, =v_20007D80                  @ 08008524
    str r0, [r1]                         @ 08008528  va_current (u32) = reading
.Lmva_va_dc_after:   @ chain done
    @ no new reading: only clear the bargraph request
    ldr r0, =v_2000805D                  @ 0800852A
    ldrb r0, [r0]                        @ 0800852C  r0 = new_reading (u8)
    cmp r0, #0                           @ 0800852E
    bne .Lmva_va_dc_flags                @ 08008530  if new_reading != 0
    movs r0, #0                          @ 08008532
    ldr r1, =v_2000805E                  @ 08008534
    strb r0, [r1]                        @ 08008538  bargraph_update (u8) = 0
    b .Lmva_va_dc_exit                   @ 0800853A
.Lmva_va_dc_flags:   @ a new reading exists
    @ phase length: voltage 3, current 6; the phase acts on the mean after the counter exceeds it (voltage 4th, current 7th)
    ldr r0, =va_channel                  @ 0800853C
    ldrb r0, [r0]                        @ 08008540  r0 = va_channel (u8)
    cmp r0, #0                           @ 08008542
    bne .Lmva_va_dc_len6                 @ 08008544  if va_channel != 0
    movs r0, #3                          @ 08008546
    movs r4, r0                          @ 08008548
    b .Lmva_va_dc_count                  @ 0800854A
.Lmva_va_dc_len6:   @ current channel: phase length 6
    movs r0, #6                          @ 0800854C
    movs r4, r0                          @ 0800854E
.Lmva_va_dc_count:   @ count the mean
    ldr r0, =v_200080C5                  @ 08008550
    ldrb r0, [r0]                        @ 08008552  r0 = va_mean_count (u8)
    adds r0, r0, #1                      @ 08008554  r0 = va_mean_count + 1
    ldr r1, =v_200080C5                  @ 08008556
    strb r0, [r1]                        @ 08008558  va_mean_count (u8) = (va_mean_count + 1)
    movs r0, r4                          @ 0800855A
    ldr r1, =v_200080C5                  @ 0800855C
    ldrb r1, [r1]                        @ 0800855E  r1 = va_mean_count (u8)
    uxtb r0, r0                          @ 08008560
    cmp r0, r1                           @ 08008562
    blo .Lmva_va_dc_phase                @ 08008564  if r0 < (unsigned) va_mean_count
    movs r0, #0                          @ 08008566
    ldr r1, =v_2000805D                  @ 08008568
    strb r0, [r1]                        @ 0800856A  new_reading (u8) = 0
    movs r0, #0                          @ 0800856C
    ldr r1, =v_2000805E                  @ 0800856E
    strb r0, [r1]                        @ 08008572  bargraph_update (u8) = 0
    b .Lmva_va_dc_exit                   @ 08008574
.Lmva_va_dc_phase:   @ phase complete
    @ phase end: counter = 0
    movs r0, #0                          @ 08008576
    ldr r1, =v_200080C5                  @ 08008578
    strb r0, [r1]                        @ 0800857A  va_mean_count (u8) = 0
    @ calibration capture (cal_mode, current channel, offset or gain request): sums of voltage and current over the cal_countdown means
    ldr r0, =v_2000808A                  @ 0800857C
    ldrb r0, [r0]                        @ 0800857E  r0 = cal_mode (u8)
    cmp r0, #0                           @ 08008580
    beq .Lmva_va_dc_autorange            @ 08008582  if cal_mode == 0
    ldr r0, =va_channel                  @ 08008586
    ldrb r0, [r0]                        @ 0800858A  r0 = va_channel (u8)
    cmp r0, #0                           @ 0800858C
    beq .Lmva_va_dc_autorange            @ 0800858E  if va_channel == 0
    ldr r0, =v_2000808C                  @ 08008592
    ldrb r0, [r0]                        @ 08008596  r0 = cal_req_offset (u8)
    ldr r1, =v_2000808E                  @ 08008598
    ldrb r1, [r1]                        @ 0800859C  r1 = cal_req_gain (u8)
    orrs r0, r1                          @ 0800859E  r0 = cal_req_offset | cal_req_gain
    uxtb r0, r0                          @ 080085A0
    cmp r0, #0                           @ 080085A2
    beq .Lmva_va_dc_autorange            @ 080085A4  if r0 == 0
    @ cal_countdown >= 3: sums = the current voltage and current (restart); below 3: sums += them (64 bit); the countdown starts at 4 in the VA modes, so the sums hold the last three means (divisor 3 below)
    ldr r0, =v_20008095                  @ 080085A8
    ldrb r0, [r0]                        @ 080085AC  r0 = cal_countdown (u8)
    cmp r0, #3                           @ 080085AE
    blt .Lmva_va_dc_accum                @ 080085B0  if cal_countdown < (signed) 3
    ldr r0, =v_20007D7C                  @ 080085B2
    ldr r0, [r0]                         @ 080085B6  r0 = va_voltage (u32)
    asrs r1, r0, #0x1f                   @ 080085B8  r1 = va_voltage >> 0x1F
    ldr r2, =v_20007C10                  @ 080085BA
    strd r0, r1, [r2]                    @ 080085BE  va_sum_v_dc (u64) = va_voltage
    ldr r0, =v_20007D80                  @ 080085C2
    ldr r0, [r0]                         @ 080085C6  r0 = va_current (u32)
    asrs r1, r0, #0x1f                   @ 080085C8  r1 = va_current >> 0x1F
    ldr r2, =v_20007C18                  @ 080085CA
    strd r0, r1, [r2]                    @ 080085CE  va_sum_i_dc (u64) = va_current
    b .Lmva_va_dc_cnt                    @ 080085D2
.Lmva_va_dc_accum:   @ add to the sums
    ldr r0, =v_20007C10                  @ 080085D4
    ldrd r2, r3, [r0]                    @ 080085D8  r2 = va_sum_v_dc (u64)
    ldr r0, =v_20007D7C                  @ 080085DC
    ldr r0, [r0]                         @ 080085E0  r0 = va_voltage (u32)
    asrs r1, r0, #0x1f                   @ 080085E2  r1 = va_voltage >> 0x1F
    adds r0, r2, r0                      @ 080085E4  r0 = va_sum_v_dc + va_voltage
    adcs r1, r3                          @ 080085E6
    ldr r2, =v_20007C10                  @ 080085E8
    strd r0, r1, [r2]                    @ 080085EC  va_sum_v_dc (u64) = (va_sum_v_dc + va_voltage)
    ldr r0, =v_20007C18                  @ 080085F0
    ldrd r2, r3, [r0]                    @ 080085F4  r2 = va_sum_i_dc (u64)
    ldr r0, =v_20007D80                  @ 080085F8
    ldr r0, [r0]                         @ 080085FC  r0 = va_current (u32)
    asrs r1, r0, #0x1f                   @ 080085FE  r1 = va_current >> 0x1F
    adds r0, r2, r0                      @ 08008600  r0 = va_sum_i_dc + va_current
    adcs r1, r3                          @ 08008602
    ldr r2, =v_20007C18                  @ 08008604
    strd r0, r1, [r2]                    @ 08008608  va_sum_i_dc (u64) = (va_sum_i_dc + va_current)
.Lmva_va_dc_cnt:   @ sums updated
    @ cal_countdown -= 1; at 0 the capture is complete
    ldr r0, =v_20008095                  @ 0800860C
    ldrb r0, [r0]                        @ 08008610  r0 = cal_countdown (u8)
    subs r0, r0, #1                      @ 08008612  r0 = cal_countdown - 1
    ldr r1, =v_20008095                  @ 08008614
    strb r0, [r1]                        @ 08008618  cal_countdown (u8) = (cal_countdown - 1)
    ldr r0, =v_20008095                  @ 0800861A
    ldrb r0, [r0]                        @ 0800861E  r0 = cal_countdown (u8)
    cmp r0, #0                           @ 08008620
    bne .Lmva_va_dc_autorange            @ 08008622  if cal_countdown != 0
    @ offset request: offsets = sum / 3 for voltage (va_off_v) and current (va_off_i), written as record words R+0 and R+8
    ldr r0, =v_2000808C                  @ 08008624
    ldrb r0, [r0]                        @ 08008628  r0 = cal_req_offset (u8)
    cmp r0, #0                           @ 0800862A
    beq .Lmva_va_dc_gain                 @ 0800862C  if cal_req_offset == 0
    movs r0, #0                          @ 0800862E
    ldr r1, =v_2000808C                  @ 08008630
    strb r0, [r1]                        @ 08008634  cal_req_offset (u8) = 0
    movs r0, #1                          @ 08008636
    ldr r1, =v_2000808D                  @ 08008638
    strb r0, [r1]                        @ 0800863C  cal_offset_done (u8) = 1
    ldr r2, =v_20007C10                  @ 0800863E
    ldrd r0, r1, [r2]                    @ 08008642  r0 = va_sum_v_dc (u64)
    movs r2, #3                          @ 08008646
    movs r3, #0                          @ 08008648  divisor 3: three means per capture
    bl fn_08013FE4                       @ 0800864A  RT: int64 r0:r1 = r0:r1 / r2:r3 (signed, truncating)
    ldr r1, =v_20007E24                  @ 0800864E
    str r0, [r1]                         @ 08008652  va_off_v (u32) = r0
    ldr r2, =v_20007C18                  @ 08008654
    ldrd r0, r1, [r2]                    @ 08008658  r0 = va_sum_i_dc (u64)
    movs r2, #3                          @ 0800865C
    movs r3, #0                          @ 0800865E
    bl fn_08013FE4                       @ 08008660  RT: int64 r0:r1 / 3
    ldr r1, =v_20007E28                  @ 08008664
    str r0, [r1]                         @ 08008668  va_off_i (u32) = r0
    NVM_ARM CAL                             @ NVM requires the CAL class armed immediately before cal_record_write (DESIGN.md 6.21)
    movs r1, #0                          @ 0800866A
    movs r0, #0                          @ 0800866C
    bl cal_record_write                  @ 0800866E  record word kind 0 (offset), mode record R and R+8
    b .Lmva_va_dc_autorange              @ 08008672
.Lmva_va_dc_gain:   @ no offset request
    @ gain request: gains from the captured means via fn_0800F9F0 for voltage (va_gain_v) and current (va_gain_i), record words R+4 and R+0xC
    ldr r0, =v_2000808E                  @ 08008674
    ldrb r0, [r0]                        @ 08008678  r0 = cal_req_gain (u8)
    cmp r0, #0                           @ 0800867A
    beq .Lmva_va_dc_autorange            @ 0800867C  if cal_req_gain == 0
    movs r0, #0                          @ 0800867E
    ldr r1, =v_2000808E                  @ 08008680
    strb r0, [r1]                        @ 08008684  cal_req_gain (u8) = 0
    movs r0, #1                          @ 08008686
    ldr r1, =v_2000808F                  @ 08008688
    strb r0, [r1]                        @ 0800868C  cal_gain_done (u8) = 1
    ldr r2, =v_20007C10                  @ 0800868E
    ldrd r0, r1, [r2]                    @ 08008692  r0 = va_sum_v_dc (u64)
    movs r2, #3                          @ 08008696
    movs r3, #0                          @ 08008698
    bl fn_08013FE4                       @ 0800869A  RT: int64 r0:r1 = r0:r1 / r2:r3 (signed, truncating)
    bl fn_08014118                       @ 0800869E  RT: float32 r0 = (float)int64 r0:r1
    ldr r1, =v_20007E20                  @ 080086A2
    str r0, [r1]                         @ 080086A6  cal_gain_in (u32) = r0
    movs r0, #0                          @ 080086A8
    bl fn_0800F9F0                       @ 080086AA  CAL: gain from the captured value (r0 = 0 voltage, 1 current channel) into cal_gain
    ldr r0, =cal_gain                    @ 080086AE
    ldr r0, [r0]                         @ 080086B2  r0 = cal_gain (u32)
    ldr r1, =v_20007E2C                  @ 080086B4
    str r0, [r1]                         @ 080086B8  va_gain_v (u32) = cal_gain
    ldr r2, =v_20007C18                  @ 080086BA
    ldrd r0, r1, [r2]                    @ 080086BE  r0 = va_sum_i_dc (u64)
    movs r2, #3                          @ 080086C2
    movs r3, #0                          @ 080086C4
    bl fn_08013FE4                       @ 080086C6  RT: int64 r0:r1 = r0:r1 / r2:r3 (signed, truncating)
    bl fn_08014118                       @ 080086CA  RT: float32 r0 = (float)int64 r0:r1
    ldr r1, =v_20007E20                  @ 080086CE
    str r0, [r1]                         @ 080086D2  cal_gain_in (u32) = r0
    movs r0, #1                          @ 080086D4
    bl fn_0800F9F0                       @ 080086D6  CAL: gain from the captured value (r0 = 0 voltage, 1 current channel) into cal_gain
    ldr r0, =cal_gain                    @ 080086DA
    ldr r0, [r0]                         @ 080086DE  r0 = cal_gain (u32)
    ldr r1, =v_20007E30                  @ 080086E0
    str r0, [r1]                         @ 080086E4  va_gain_i (u32) = cal_gain
    NVM_ARM CAL                             @ NVM requires the CAL class armed immediately before cal_record_write (DESIGN.md 6.21)
    movs r1, #0                          @ 080086E6
    movs r0, #1                          @ 080086E8
    bl cal_record_write                  @ 080086EA  record word kind 1 (gain), R+4 and R+0xC
.Lmva_va_dc_autorange:   @ capture done or not requested
    @ voltage channel: burden correction of va_voltage then voltage autorange; current channel: current autorange
    ldr r0, =va_channel                  @ 080086EE
    ldrb r0, [r0]                        @ 080086F2  r0 = va_channel (u8)
    cmp r0, #0                           @ 080086F4
    bne .Lmva_va_dc_curauto              @ 080086F6  if va_channel != 0
    bl fn_08008ED0                       @ 080086F8  MVA: burden correction of va_voltage
    ldr r0, =v_20007D7C                  @ 080086FC
    ldr r0, [r0]                         @ 08008700  r0 = va_voltage (u32)
    bl fn_0800A260                       @ 08008702  MVA: voltage autorange of the VA modes (r0 = voltage count)
    b .Lmva_va_dc_over                   @ 08008706
.Lmva_va_dc_curauto:   @ current channel autorange
    ldr r0, =v_20007D80                  @ 08008708
    ldr r0, [r0]                         @ 0800870C  r0 = va_current (u32)
    bl fn_0800A358                       @ 0800870E  MVA: current autorange of the VA modes (r0 = current count)
.Lmva_va_dc_over:   @ autorange done
    @ voltage or current overload: overload (0x20008046) = 1
    ldr r0, =v_200080CA                  @ 08008712
    ldrsb r0, [r0]                       @ 08008716  r0 = va_v_over (s8)
    cmp r0, #0                           @ 0800871A
    bne .Lmva_va_dc_0800872A             @ 0800871C  if va_v_over != 0
    ldr r0, =v_200080CB                  @ 0800871E
    ldrsb r0, [r0]                       @ 08008722  r0 = va_i_over (s8)
    cmp r0, #0                           @ 08008726
    beq .Lmva_va_dc_sw                   @ 08008728  if va_i_over == 0
.Lmva_va_dc_0800872A:   @ branch target from 0800871C
    movs r0, #1                          @ 0800872A
    ldr r1, =v_20008046                  @ 0800872C
    strb r0, [r1]                        @ 08008730  overload (u8) = 1
.Lmva_va_dc_sw:   @ check whether the range changed
    @ no range change in this pass: switch channel, re-apply the HY3131 row, compute the power from the two values
    ldr r0, =v_200080C3                  @ 08008732
    ldrb r0, [r0]                        @ 08008736  r0 = va_range_changed (u8)
    cmp r0, #0                           @ 08008738
    bne .Lmva_va_dc_pub                  @ 0800873A  if va_range_changed != 0
    ldr r0, =va_channel                  @ 0800873C
    ldrb r0, [r0]                        @ 08008740  r0 = va_channel (u8)
    eors r0, r0, #1                      @ 08008742  r0 = va_channel ^ 1
    ldr r1, =va_channel                  @ 08008746
    strb r0, [r1]                        @ 0800874A  va_channel (u8) = (va_channel ^ 1)
    movs r0, #0                          @ 0800874C
    bl fn_0800D80C                       @ 0800874E  MODE: re-apply HY row (r0 = 1: also reload the calibration record)
    ldr r0, =v_20007D80                  @ 08008752
    ldr r1, [r0]                         @ 08008756  r1 = va_current (u32)
    ldr r0, =v_20007D7C                  @ 08008758
    ldr r0, [r0]                         @ 0800875C  r0 = va_voltage (u32)
    bl fn_0800A4AC                       @ 0800875E  MVA: power = |V| * |I| / d (r0 = voltage, r1 = current)
    movs r0, #0                          @ 08008762
    ldr r1, =v_200080BF                  @ 08008764
    strb r0, [r1]                        @ 08008768  va_dashes (u8) = 0
.Lmva_va_dc_pub:   @ publish
    @ publish: new_reading, redraw requests, bargraph, annunciators, sample value = reading
    movs r0, #1                          @ 0800876A
    ldr r1, =v_2000805D                  @ 0800876C
    strb r0, [r1]                        @ 0800876E  new_reading (u8) = 1
    movs r0, #0                          @ 08008770
    ldr r1, =v_20008060                  @ 08008772
    strb r0, [r1]                        @ 08008776  v_20008060 (u8) = 0
    movs r0, #0                          @ 08008778
    ldr r1, =v_20008062                  @ 0800877A
    strb r0, [r1]                        @ 0800877E  sec_refresh (u8) = 0
    movs r0, #1                          @ 08008780
    ldr r1, =v_2000805E                  @ 08008782
    strb r0, [r1]                        @ 08008786  bargraph_update (u8) = 1
    movs r0, #1                          @ 08008788
    ldr r1, =v_2000804C                  @ 0800878A
    strb r0, [r1]                        @ 0800878E  annun_request (u8) = 1
    ldr r0, =meter_mode                  @ 08008790
    ldrb r0, [r0]                        @ 08008794  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08008796
    bne .Lmva_va_dc_plain                @ 08008798  if meter_mode != 15
    ldr r0, =v_200080C7                  @ 0800879A
    ldrb r0, [r0]                        @ 0800879E  r0 = va_isub (u8)
    cmp r0, #0                           @ 080087A0
    beq .Lmva_va_dc_plain                @ 080087A2  if va_isub == 0
    ldr r0, =v_20007D64                  @ 080087A4
    ldr r0, [r0]                         @ 080087A6  r0 = reading (u32)
    ldr r1, =v_20007D68                  @ 080087A8
    str r0, [r1]                         @ 080087AC  sample_value (u32) = reading
    b .Lmva_va_dc_exit                   @ 080087AE
    .ltorg
.Lmva_va_dc_plain:   @ not mode 15 with the high current sub-range
    ldr r0, =v_20007D64                  @ 080087B0
    ldr r0, [r0]                         @ 080087B2  r0 = reading (u32)
    ldr r1, =v_20007D68                  @ 080087B4
    str r0, [r1]                         @ 080087B8  sample_value (u32) = reading
.Lmva_va_dc_exit:   @ return
    pop {r4, pc}                         @ 080087BA
    .ltorg
ENDFUNC fn_080084E0
    .global mva_va_dc
    .set mva_va_dc, fn_080084E0

@ -----------------------------------------------------------------------------
@ fn_08008B8C (mva_va_ac) - AD1 handler of the AC VA modes 13, 14, 15: as the DC handler, with the AC voltage / current chains and the
@   absolute value of the corrected voltage and of the current before the autorange
@ Replaces : 0x08008B8C FUN_08008b8c (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (ad1_ready_dispatch 0x0800624E)
@ Registers: r4 = phase length
@ RAM      : reads  0x20007C20 va_sum_v_ac, 0x20007C28 va_sum_i_ac, 0x20007D64 reading, 0x20007D7C va_voltage,
@            0x20007D80 va_current, 0x20007E10 cal_gain, 0x2000803C meter_mode, 0x2000805D new_reading,
@            0x20008081 mean_ready, 0x2000808A cal_mode, 0x2000808C cal_req_offset, 0x2000808E cal_req_gain,
@            0x20008095 cal_countdown, 0x200080C3 va_range_changed, 0x200080C4 va_channel, 0x200080C5 va_mean_count,
@            0x200080C7 va_isub, 0x200080CA va_v_over, 0x200080CB va_i_over
@            writes 0x20007C20 va_sum_v_ac, 0x20007C28 va_sum_i_ac, 0x20007D68 sample_value, 0x20007D7C va_voltage,
@            0x20007D80 va_current, 0x20007E20 cal_gain_in, 0x20007E24 va_off_v, 0x20007E28 va_off_i,
@            0x20007E2C va_gain_v, 0x20007E30 va_gain_i, 0x20008046 overload, 0x2000804C annun_request,
@            0x2000805D new_reading, 0x2000805E bargraph_update, 0x20008060, 0x20008062 sec_refresh,
@            0x2000808C cal_req_offset, 0x2000808D cal_offset_done, 0x2000808E cal_req_gain, 0x2000808F cal_gain_done,
@            0x20008095 cal_countdown, 0x200080BF va_dashes, 0x200080C3 va_range_changed, 0x200080C4 va_channel,
@            0x200080C5 va_mean_count
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.1, VA.4, VA.7), keys_setup.md 5.3 (VA calibration)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_08008B8C
    push {r4, lr}                        @ 08008B8C
    @ r4 = phase length (3 or 6, set below); va_range_changed = 0
    movs r4, #0                          @ 08008B8E
    movs r0, #0                          @ 08008B90
    ldr r1, =v_200080C3                  @ 08008B92
    strb r0, [r1]                        @ 08008B94  va_range_changed (u8) = 0
    @ the chain of the active channel: 0 = voltage fn_08006AEC, 1 = current fn_080067D6
    ldr r0, =va_channel                  @ 08008B96
    ldrb r0, [r0]                        @ 08008B98  r0 = va_channel (u8)
    cmp r0, #0                           @ 08008B9A
    beq .Lmva_va_ac_volt                 @ 08008B9C  if va_channel == 0
    cmp r0, #1                           @ 08008B9E
    beq .Lmva_va_ac_cur                  @ 08008BA0  if va_channel == 1
    b .Lmva_va_ac_after                  @ 08008BA2
.Lmva_va_ac_volt:   @ voltage channel
    bl fn_08006AEC                       @ 08008BA4  MAC: ACV chain
    ldr r0, =v_20008081                  @ 08008BA8
    ldrb r0, [r0]                        @ 08008BAC  r0 = mean_ready (u8)
    cmp r0, #0                           @ 08008BAE
    beq .Lmva_va_ac_08008BBE             @ 08008BB0  if mean_ready == 0
    ldr r0, =v_20007D64                  @ 08008BB2
    ldr r0, [r0]                         @ 08008BB6  r0 = reading (u32)
    ldr r1, =v_20007D7C                  @ 08008BB8
    str r0, [r1]                         @ 08008BBC  va_voltage (u32) = reading
.Lmva_va_ac_08008BBE:   @ branch target from 08008BB0
    b .Lmva_va_ac_after                  @ 08008BBE
.Lmva_va_ac_cur:   @ current channel
    bl fn_080067D6                       @ 08008BC0  MAC: AC current chain
    ldr r0, =v_20008081                  @ 08008BC4
    ldrb r0, [r0]                        @ 08008BC8  r0 = mean_ready (u8)
    cmp r0, #0                           @ 08008BCA
    beq .Lmva_va_ac_after                @ 08008BCC  if mean_ready == 0
    ldr r0, =v_20007D64                  @ 08008BCE
    ldr r0, [r0]                         @ 08008BD2  r0 = reading (u32)
    ldr r1, =v_20007D80                  @ 08008BD4
    str r0, [r1]                         @ 08008BD8  va_current (u32) = reading
.Lmva_va_ac_after:   @ chain done
    @ no new reading: only clear the bargraph request
    ldr r0, =v_2000805D                  @ 08008BDA
    ldrb r0, [r0]                        @ 08008BDE  r0 = new_reading (u8)
    cmp r0, #0                           @ 08008BE0
    bne .Lmva_va_ac_flags                @ 08008BE2  if new_reading != 0
    movs r0, #0                          @ 08008BE4
    ldr r1, =v_2000805E                  @ 08008BE6
    strb r0, [r1]                        @ 08008BE8  bargraph_update (u8) = 0
    b .Lmva_va_ac_exit                   @ 08008BEA
.Lmva_va_ac_flags:   @ a new reading exists
    @ phase length: voltage 3, current 6
    ldr r0, =va_channel                  @ 08008BEC
    ldrb r0, [r0]                        @ 08008BEE  r0 = va_channel (u8)
    cmp r0, #0                           @ 08008BF0
    bne .Lmva_va_ac_08008BFA             @ 08008BF2  if va_channel != 0
    movs r0, #3                          @ 08008BF4
    movs r4, r0                          @ 08008BF6
    b .Lmva_va_ac_08008BFE               @ 08008BF8
.Lmva_va_ac_08008BFA:   @ branch target from 08008BF2
    movs r0, #6                          @ 08008BFA
    movs r4, r0                          @ 08008BFC
.Lmva_va_ac_08008BFE:   @ branch target from 08008BF8
    ldr r0, =v_200080C5                  @ 08008BFE
    ldrb r0, [r0]                        @ 08008C02  r0 = va_mean_count (u8)
    adds r0, r0, #1                      @ 08008C04  r0 = va_mean_count + 1
    ldr r1, =v_200080C5                  @ 08008C06
    strb r0, [r1]                        @ 08008C0A  va_mean_count (u8) = (va_mean_count + 1)
    movs r0, r4                          @ 08008C0C
    ldr r1, =v_200080C5                  @ 08008C0E
    ldrb r1, [r1]                        @ 08008C12  r1 = va_mean_count (u8)
    uxtb r0, r0                          @ 08008C14
    cmp r0, r1                           @ 08008C16
    blo .Lmva_va_ac_phase                @ 08008C18  if r0 < (unsigned) va_mean_count
    movs r0, #0                          @ 08008C1A
    ldr r1, =v_2000805D                  @ 08008C1C
    strb r0, [r1]                        @ 08008C20  new_reading (u8) = 0
    movs r0, #0                          @ 08008C22
    ldr r1, =v_2000805E                  @ 08008C24
    strb r0, [r1]                        @ 08008C26  bargraph_update (u8) = 0
    b .Lmva_va_ac_exit                   @ 08008C28
.Lmva_va_ac_phase:   @ phase complete
    @ phase end: counter = 0
    movs r0, #0                          @ 08008C2A
    ldr r1, =v_200080C5                  @ 08008C2C
    strb r0, [r1]                        @ 08008C30  va_mean_count (u8) = 0
    @ calibration capture (cal_mode, current channel, offset or gain request)
    ldr r0, =v_2000808A                  @ 08008C32
    ldrb r0, [r0]                        @ 08008C36  r0 = cal_mode (u8)
    cmp r0, #0                           @ 08008C38
    beq .Lmva_va_ac_autorange            @ 08008C3A  if cal_mode == 0
    ldr r0, =va_channel                  @ 08008C3E
    ldrb r0, [r0]                        @ 08008C40  r0 = va_channel (u8)
    cmp r0, #0                           @ 08008C42
    beq .Lmva_va_ac_autorange            @ 08008C44  if va_channel == 0
    ldr r0, =v_2000808C                  @ 08008C48
    ldrb r0, [r0]                        @ 08008C4A  r0 = cal_req_offset (u8)
    ldr r1, =v_2000808E                  @ 08008C4C
    ldrb r1, [r1]                        @ 08008C4E  r1 = cal_req_gain (u8)
    orrs r0, r1                          @ 08008C50  r0 = cal_req_offset | cal_req_gain
    uxtb r0, r0                          @ 08008C52
    cmp r0, #0                           @ 08008C54
    beq .Lmva_va_ac_autorange            @ 08008C56  if r0 == 0
    ldr r0, =v_20008095                  @ 08008C5A
    ldrb r0, [r0]                        @ 08008C5C  r0 = cal_countdown (u8)
    cmp r0, #3                           @ 08008C5E
    blt .Lmva_va_ac_accum                @ 08008C60  if cal_countdown < (signed) 3
    ldr r0, =v_20007D7C                  @ 08008C62
    ldr r0, [r0]                         @ 08008C66  r0 = va_voltage (u32)
    asrs r1, r0, #0x1f                   @ 08008C68  r1 = va_voltage >> 0x1F
    ldr r2, =v_20007C20                  @ 08008C6A
    strd r0, r1, [r2]                    @ 08008C6E  va_sum_v_ac (u64) = va_voltage
    ldr r0, =v_20007D80                  @ 08008C72
    ldr r0, [r0]                         @ 08008C76  r0 = va_current (u32)
    asrs r1, r0, #0x1f                   @ 08008C78  r1 = va_current >> 0x1F
    ldr r2, =v_20007C28                  @ 08008C7A
    strd r0, r1, [r2]                    @ 08008C7E  va_sum_i_ac (u64) = va_current
    b .Lmva_va_ac_cnt                    @ 08008C82
.Lmva_va_ac_accum:   @ add to the sums
    ldr r0, =v_20007C20                  @ 08008C84
    ldrd r2, r3, [r0]                    @ 08008C88  r2 = va_sum_v_ac (u64)
    ldr r0, =v_20007D7C                  @ 08008C8C
    ldr r0, [r0]                         @ 08008C90  r0 = va_voltage (u32)
    asrs r1, r0, #0x1f                   @ 08008C92  r1 = va_voltage >> 0x1F
    adds r0, r2, r0                      @ 08008C94  r0 = va_sum_v_ac + va_voltage
    adcs r1, r3                          @ 08008C96
    ldr r2, =v_20007C20                  @ 08008C98
    strd r0, r1, [r2]                    @ 08008C9C  va_sum_v_ac (u64) = (va_sum_v_ac + va_voltage)
    ldr r0, =v_20007C28                  @ 08008CA0
    ldrd r2, r3, [r0]                    @ 08008CA4  r2 = va_sum_i_ac (u64)
    ldr r0, =v_20007D80                  @ 08008CA8
    ldr r0, [r0]                         @ 08008CAC  r0 = va_current (u32)
    asrs r1, r0, #0x1f                   @ 08008CAE  r1 = va_current >> 0x1F
    adds r0, r2, r0                      @ 08008CB0  r0 = va_sum_i_ac + va_current
    adcs r1, r3                          @ 08008CB2
    ldr r2, =v_20007C28                  @ 08008CB4
    strd r0, r1, [r2]                    @ 08008CB8  va_sum_i_ac (u64) = (va_sum_i_ac + va_current)
.Lmva_va_ac_cnt:   @ sums updated
    ldr r0, =v_20008095                  @ 08008CBC
    ldrb r0, [r0]                        @ 08008CBE  r0 = cal_countdown (u8)
    subs r0, r0, #1                      @ 08008CC0  r0 = cal_countdown - 1
    ldr r1, =v_20008095                  @ 08008CC2
    strb r0, [r1]                        @ 08008CC4  cal_countdown (u8) = (cal_countdown - 1)
    ldr r0, =v_20008095                  @ 08008CC6
    ldrb r0, [r0]                        @ 08008CC8  r0 = cal_countdown (u8)
    cmp r0, #0                           @ 08008CCA
    bne .Lmva_va_ac_autorange            @ 08008CCC  if cal_countdown != 0
    ldr r0, =v_2000808C                  @ 08008CCE
    ldrb r0, [r0]                        @ 08008CD0  r0 = cal_req_offset (u8)
    cmp r0, #0                           @ 08008CD2
    beq .Lmva_va_ac_gain                 @ 08008CD4  if cal_req_offset == 0
    movs r0, #0                          @ 08008CD6
    ldr r1, =v_2000808C                  @ 08008CD8
    strb r0, [r1]                        @ 08008CDA  cal_req_offset (u8) = 0
    movs r0, #1                          @ 08008CDC
    ldr r1, =v_2000808D                  @ 08008CDE
    strb r0, [r1]                        @ 08008CE0  cal_offset_done (u8) = 1
    ldr r2, =v_20007C20                  @ 08008CE2
    ldrd r0, r1, [r2]                    @ 08008CE6  r0 = va_sum_v_ac (u64)
    movs r2, #3                          @ 08008CEA
    movs r3, #0                          @ 08008CEC
    bl fn_08013FE4                       @ 08008CEE  RT: int64 r0:r1 = r0:r1 / r2:r3 (signed, truncating)
    ldr r1, =v_20007E24                  @ 08008CF2
    str r0, [r1]                         @ 08008CF4  va_off_v (u32) = r0
    ldr r2, =v_20007C28                  @ 08008CF6
    ldrd r0, r1, [r2]                    @ 08008CFA  r0 = va_sum_i_ac (u64)
    movs r2, #3                          @ 08008CFE
    movs r3, #0                          @ 08008D00
    bl fn_08013FE4                       @ 08008D02  RT: int64 r0:r1 = r0:r1 / r2:r3 (signed, truncating)
    ldr r1, =v_20007E28                  @ 08008D06
    str r0, [r1]                         @ 08008D08  va_off_i (u32) = r0
    NVM_ARM CAL                             @ NVM requires the CAL class armed immediately before cal_record_write (DESIGN.md 6.21)
    movs r1, #0                          @ 08008D0A
    movs r0, #0                          @ 08008D0C
    bl cal_record_write                  @ 08008D0E  CAL/NVM: write the calibration record words (r0 = 0 offset, 1 gain; r1 = 0)
    b .Lmva_va_ac_autorange              @ 08008D12
.Lmva_va_ac_gain:   @ no offset request
    ldr r0, =v_2000808E                  @ 08008D14
    ldrb r0, [r0]                        @ 08008D16  r0 = cal_req_gain (u8)
    cmp r0, #0                           @ 08008D18
    beq .Lmva_va_ac_autorange            @ 08008D1A  if cal_req_gain == 0
    movs r0, #0                          @ 08008D1C
    ldr r1, =v_2000808E                  @ 08008D1E
    strb r0, [r1]                        @ 08008D20  cal_req_gain (u8) = 0
    movs r0, #1                          @ 08008D22
    ldr r1, =v_2000808F                  @ 08008D24
    strb r0, [r1]                        @ 08008D26  cal_gain_done (u8) = 1
    ldr r2, =v_20007C20                  @ 08008D28
    ldrd r0, r1, [r2]                    @ 08008D2C  r0 = va_sum_v_ac (u64)
    movs r2, #3                          @ 08008D30
    movs r3, #0                          @ 08008D32
    bl fn_08013FE4                       @ 08008D34  RT: int64 r0:r1 = r0:r1 / r2:r3 (signed, truncating)
    bl fn_08014118                       @ 08008D38  RT: float32 r0 = (float)int64 r0:r1
    ldr r1, =v_20007E20                  @ 08008D3C
    str r0, [r1]                         @ 08008D3E  cal_gain_in (u32) = r0
    movs r0, #0                          @ 08008D40
    bl fn_0800F9F0                       @ 08008D42  CAL: gain from the captured value (r0 = 0 voltage, 1 current channel) into cal_gain
    ldr r0, =cal_gain                    @ 08008D46
    ldr r0, [r0]                         @ 08008D48  r0 = cal_gain (u32)
    ldr r1, =v_20007E2C                  @ 08008D4A
    str r0, [r1]                         @ 08008D4C  va_gain_v (u32) = cal_gain
    ldr r2, =v_20007C28                  @ 08008D4E
    ldrd r0, r1, [r2]                    @ 08008D52  r0 = va_sum_i_ac (u64)
    movs r2, #3                          @ 08008D56
    movs r3, #0                          @ 08008D58
    bl fn_08013FE4                       @ 08008D5A  RT: int64 r0:r1 = r0:r1 / r2:r3 (signed, truncating)
    bl fn_08014118                       @ 08008D5E  RT: float32 r0 = (float)int64 r0:r1
    ldr r1, =v_20007E20                  @ 08008D62
    str r0, [r1]                         @ 08008D64  cal_gain_in (u32) = r0
    movs r0, #1                          @ 08008D66
    bl fn_0800F9F0                       @ 08008D68  CAL: gain from the captured value (r0 = 0 voltage, 1 current channel) into cal_gain
    ldr r0, =cal_gain                    @ 08008D6C
    ldr r0, [r0]                         @ 08008D6E  r0 = cal_gain (u32)
    ldr r1, =v_20007E30                  @ 08008D70
    str r0, [r1]                         @ 08008D72  va_gain_i (u32) = cal_gain
    NVM_ARM CAL                             @ NVM requires the CAL class armed immediately before cal_record_write (DESIGN.md 6.21)
    movs r1, #0                          @ 08008D74
    movs r0, #1                          @ 08008D76
    bl cal_record_write                  @ 08008D78  CAL/NVM: write the calibration record words (r0 = 0 offset, 1 gain; r1 = 0)
.Lmva_va_ac_autorange:   @ capture done or not requested
    @ voltage channel: burden correction, absolute value, voltage autorange; current channel: absolute value, current autorange
    ldr r0, =va_channel                  @ 08008D7C
    ldrb r0, [r0]                        @ 08008D7E  r0 = va_channel (u8)
    cmp r0, #0                           @ 08008D80
    bne .Lmva_va_ac_curauto              @ 08008D82  if va_channel != 0
    bl fn_08008ED0                       @ 08008D84  MVA: burden correction of va_voltage
    ldr r0, =v_20007D7C                  @ 08008D88
    ldr r0, [r0]                         @ 08008D8C  r0 = va_voltage (u32)
    cmp r0, #0                           @ 08008D8E
    bpl .Lmva_va_ac_08008DA0             @ 08008D90  if va_voltage >= 0
    ldr r0, =v_20007D7C                  @ 08008D92
    ldr r0, [r0]                         @ 08008D96  r0 = va_voltage (u32)
    rsbs r0, r0, #0                      @ 08008D98  r0 = -va_voltage
    ldr r1, =v_20007D7C                  @ 08008D9A
    str r0, [r1]                         @ 08008D9E  va_voltage (u32) = -va_voltage
.Lmva_va_ac_08008DA0:   @ branch target from 08008D90
    ldr r0, =v_20007D7C                  @ 08008DA0
    ldr r0, [r0]                         @ 08008DA4  r0 = va_voltage (u32)
    bl fn_0800A260                       @ 08008DA6  MVA: voltage autorange of the VA modes (r0 = voltage count)
    b .Lmva_va_ac_over                   @ 08008DAA
.Lmva_va_ac_curauto:   @ current channel autorange
    ldr r0, =v_20007D80                  @ 08008DAC
    ldr r0, [r0]                         @ 08008DAE  r0 = va_current (u32)
    cmp r0, #0                           @ 08008DB0
    bpl .Lmva_va_ac_08008DBE             @ 08008DB2  if va_current >= 0
    ldr r0, =v_20007D80                  @ 08008DB4
    ldr r0, [r0]                         @ 08008DB6  r0 = va_current (u32)
    rsbs r0, r0, #0                      @ 08008DB8  r0 = -va_current
    ldr r1, =v_20007D80                  @ 08008DBA
    str r0, [r1]                         @ 08008DBC  va_current (u32) = -va_current
.Lmva_va_ac_08008DBE:   @ branch target from 08008DB2
    ldr r0, =v_20007D80                  @ 08008DBE
    ldr r0, [r0]                         @ 08008DC0  r0 = va_current (u32)
    bl fn_0800A358                       @ 08008DC2  MVA: current autorange of the VA modes (r0 = current count)
.Lmva_va_ac_over:   @ autorange done
    @ voltage or current overload: overload (0x20008046) = 1
    ldr r0, =v_200080CA                  @ 08008DC6
    ldrsb r0, [r0]                       @ 08008DC8  r0 = va_v_over (s8)
    cmp r0, #0                           @ 08008DCC
    bne .Lmva_va_ac_08008DDC             @ 08008DCE  if va_v_over != 0
    ldr r0, =v_200080CB                  @ 08008DD0
    ldrsb r0, [r0]                       @ 08008DD4  r0 = va_i_over (s8)
    cmp r0, #0                           @ 08008DD8
    beq .Lmva_va_ac_sw                   @ 08008DDA  if va_i_over == 0
.Lmva_va_ac_08008DDC:   @ branch target from 08008DCE
    movs r0, #1                          @ 08008DDC
    ldr r1, =v_20008046                  @ 08008DDE
    strb r0, [r1]                        @ 08008DE0  overload (u8) = 1
.Lmva_va_ac_sw:   @ check whether the range changed
    @ no range change in this pass: switch channel, re-apply the HY3131 row, compute the power
    ldr r0, =v_200080C3                  @ 08008DE2
    ldrb r0, [r0]                        @ 08008DE4  r0 = va_range_changed (u8)
    cmp r0, #0                           @ 08008DE6
    bne .Lmva_va_ac_pub                  @ 08008DE8  if va_range_changed != 0
    ldr r0, =va_channel                  @ 08008DEA
    ldrb r0, [r0]                        @ 08008DEC  r0 = va_channel (u8)
    eors r0, r0, #1                      @ 08008DEE  r0 = va_channel ^ 1
    ldr r1, =va_channel                  @ 08008DF2
    strb r0, [r1]                        @ 08008DF4  va_channel (u8) = (va_channel ^ 1)
    movs r0, #0                          @ 08008DF6
    bl fn_0800D80C                       @ 08008DF8  MODE: re-apply HY row (r0 = 1: also reload the calibration record)
    ldr r0, =v_20007D80                  @ 08008DFC
    ldr r1, [r0]                         @ 08008DFE  r1 = va_current (u32)
    ldr r0, =v_20007D7C                  @ 08008E00
    ldr r0, [r0]                         @ 08008E04  r0 = va_voltage (u32)
    bl fn_0800A4AC                       @ 08008E06  MVA: power = |V| * |I| / d (r0 = voltage, r1 = current)
    movs r0, #0                          @ 08008E0A
    ldr r1, =v_200080BF                  @ 08008E0C
    strb r0, [r1]                        @ 08008E0E  va_dashes (u8) = 0
.Lmva_va_ac_pub:   @ publish
    @ publish: new_reading, redraw requests, bargraph, annunciators, sample value = reading
    movs r0, #1                          @ 08008E10
    ldr r1, =v_2000805D                  @ 08008E12
    strb r0, [r1]                        @ 08008E16  new_reading (u8) = 1
    movs r0, #0                          @ 08008E18
    ldr r1, =v_20008060                  @ 08008E1A
    strb r0, [r1]                        @ 08008E1C  v_20008060 (u8) = 0
    movs r0, #0                          @ 08008E1E
    ldr r1, =v_20008062                  @ 08008E20
    strb r0, [r1]                        @ 08008E22  sec_refresh (u8) = 0
    movs r0, #1                          @ 08008E24
    ldr r1, =v_2000805E                  @ 08008E26
    strb r0, [r1]                        @ 08008E28  bargraph_update (u8) = 1
    movs r0, #1                          @ 08008E2A
    ldr r1, =v_2000804C                  @ 08008E2C
    strb r0, [r1]                        @ 08008E2E  annun_request (u8) = 1
    ldr r0, =meter_mode                  @ 08008E30
    ldrb r0, [r0]                        @ 08008E32  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08008E34
    bne .Lmva_va_ac_plain                @ 08008E36  if meter_mode != 15
    ldr r0, =v_200080C7                  @ 08008E38
    ldrb r0, [r0]                        @ 08008E3A  r0 = va_isub (u8)
    cmp r0, #0                           @ 08008E3C
    beq .Lmva_va_ac_plain                @ 08008E3E  if va_isub == 0
    ldr r0, =v_20007D64                  @ 08008E40
    ldr r0, [r0]                         @ 08008E44  r0 = reading (u32)
    ldr r1, =v_20007D68                  @ 08008E46
    str r0, [r1]                         @ 08008E48  sample_value (u32) = reading
    b .Lmva_va_ac_exit                   @ 08008E4A
    .ltorg
.Lmva_va_ac_plain:   @ not mode 15 with the high current sub-range
    ldr r0, =v_20007D64                  @ 08008E4C
    ldr r0, [r0]                         @ 08008E50  r0 = reading (u32)
    ldr r1, =v_20007D68                  @ 08008E52
    str r0, [r1]                         @ 08008E54  sample_value (u32) = reading
.Lmva_va_ac_exit:   @ return
    pop {r4, pc}                         @ 08008E56
    .ltorg
ENDFUNC fn_08008B8C
    .global mva_va_ac
    .set mva_va_ac, fn_08008B8C

@ -----------------------------------------------------------------------------
@ fn_0800A260 (mva_voltage_autorange) - voltage autorange of the VA modes: overload flag, step the voltage sub-range up at 55001 counts and down
@   below 3200, remember the voltage for the secondary display
@ Replaces : 0x0800A260 FUN_0800a260 (v2.05)
@ In       : r0 = voltage count (signed in the DC modes, non-negative in the AC modes)
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080084E0, fn_08008B8C)
@ Registers: r4 = V (argument), r5 = |V|
@ RAM      : reads  0x20008037 setup_item, 0x2000803C meter_mode, 0x20008042 range_manual, 0x2000804E minmax_state,
@            0x2000808A cal_mode, 0x200080C6 va_vsub
@            writes 0x20007EAC va_v_sec, 0x2000803D meter_range, 0x20008062 sec_refresh, 0x200080C0 va_dashes_v,
@            0x200080C6 va_vsub, 0x200080C8 va_vup_flag, 0x200080CA va_v_over
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.7)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800A260
    push {r3, r4, r5, lr}                @ 0800A260
    movs r4, r0                          @ 0800A262
    movs r0, #0                          @ 0800A264
    @ va_v_over = 0, va_dashes_v = 0; r5 = |V| in the DC modes 22, 23, 24, else V
    ldr r1, =v_200080CA                  @ 0800A266
    strb r0, [r1]                        @ 0800A26A  va_v_over (u8) = 0
    movs r0, #0                          @ 0800A26C
    ldr r1, =v_200080C0                  @ 0800A26E
    strb r0, [r1]                        @ 0800A272  va_dashes_v (u8) = 0
    movs r5, r4                          @ 0800A274
    ldr r0, =meter_mode                  @ 0800A276
    ldrb r0, [r0]                        @ 0800A278  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 0800A27A
    beq .Lmva_voltage_autorange_abs      @ 0800A27C  if meter_mode == 22
    ldr r0, =meter_mode                  @ 0800A27E
    ldrb r0, [r0]                        @ 0800A280  r0 = meter_mode (u8)
    cmp r0, #0x17                        @ 0800A282
    beq .Lmva_voltage_autorange_abs      @ 0800A284  if meter_mode == 23
    ldr r0, =meter_mode                  @ 0800A286
    ldrb r0, [r0]                        @ 0800A288  r0 = meter_mode (u8)
    cmp r0, #0x18                        @ 0800A28A
    bne .Lmva_voltage_autorange_lim      @ 0800A28C  if meter_mode != 24
.Lmva_voltage_autorange_abs:   @ DC VA modes: absolute value
    cmp r4, #0                           @ 0800A28E
    bpl .Lmva_voltage_autorange_lim      @ 0800A290  if V >= 0
    rsbs r0, r4, #0                      @ 0800A292  r0 = -V
    movs r5, r0                          @ 0800A294
.Lmva_voltage_autorange_lim:   @ limit test
    @ |V| >= 55001 (0xD6D9): voltage overload
    movw r0, #0xd6d9                     @ 0800A296  = 55001
    cmp r5, r0                           @ 0800A29A
    blt .Lmva_voltage_autorange_low      @ 0800A29C  if r5 < (signed) 55001
    movs r0, #1                          @ 0800A29E
    ldr r1, =v_200080CA                  @ 0800A2A0
    strb r0, [r1]                        @ 0800A2A4  va_v_over (u8) = 1
    @ autorange allowed only when calibration mode is off, the range is not manual, MIN/MAX is off and the voltage sub-range is 0
    ldr r0, =v_2000808A                  @ 0800A2A6
    ldrb r0, [r0]                        @ 0800A2A8  r0 = cal_mode (u8)
    ldr r1, =range_manual                @ 0800A2AA
    ldrb r1, [r1]                        @ 0800A2AE  r1 = range_manual (u8)
    orrs r0, r1                          @ 0800A2B0  r0 = cal_mode | range_manual
    uxtb r0, r0                          @ 0800A2B2
    cmp r0, #0                           @ 0800A2B4
    bne .Lmva_voltage_autorange_store    @ 0800A2B6  if r0 != 0
    ldr r0, =minmax_state                @ 0800A2B8
    ldrb r0, [r0]                        @ 0800A2BC  r0 = minmax_state (u8)
    cmp r0, #0                           @ 0800A2BE
    bne .Lmva_voltage_autorange_store    @ 0800A2C0  if minmax_state != 0
    ldr r0, =v_200080C6                  @ 0800A2C2
    ldrb r0, [r0]                        @ 0800A2C6  r0 = va_vsub (u8)
    cmp r0, #0                           @ 0800A2C8
    bne .Lmva_voltage_autorange_store    @ 0800A2CA  if va_vsub != 0
    movs r0, #1                          @ 0800A2CC
    ldr r1, =v_200080C6                  @ 0800A2CE
    strb r0, [r1]                        @ 0800A2D2  va_vsub (u8) = 1
    movs r0, #1                          @ 0800A2D4
    ldr r1, =v_200080C8                  @ 0800A2D6
    strb r0, [r1]                        @ 0800A2DA  va_vup_flag (u8) = 1
    bl fn_080148F6                       @ 0800A2DC  meter_range from (va_vsub, va_isub)
    ldr r1, =meter_range                 @ 0800A2E0
    strb r0, [r1]                        @ 0800A2E2  meter_range (u8) = r0
    bl fn_0800D8C2                       @ 0800A2E4  apply the range change
    b .Lmva_voltage_autorange_store      @ 0800A2E8
.Lmva_voltage_autorange_low:   @ below the over-range limit
    @ |V| < 3200 with the high voltage sub-range: step down (same gating)
    cmp r5, #0xc80                       @ 0800A2EA
    bge .Lmva_voltage_autorange_store    @ 0800A2EE  if r5 >= (signed) 3200
    ldr r0, =v_2000808A                  @ 0800A2F0
    ldrb r0, [r0]                        @ 0800A2F2  r0 = cal_mode (u8)
    ldr r1, =range_manual                @ 0800A2F4
    ldrb r1, [r1]                        @ 0800A2F8  r1 = range_manual (u8)
    orrs r0, r1                          @ 0800A2FA  r0 = cal_mode | range_manual
    uxtb r0, r0                          @ 0800A2FC
    cmp r0, #0                           @ 0800A2FE
    bne .Lmva_voltage_autorange_store    @ 0800A300  if r0 != 0
    ldr r0, =minmax_state                @ 0800A302
    ldrb r0, [r0]                        @ 0800A306  r0 = minmax_state (u8)
    cmp r0, #0                           @ 0800A308
    bne .Lmva_voltage_autorange_store    @ 0800A30A  if minmax_state != 0
    ldr r0, =v_200080C6                  @ 0800A30C
    ldrb r0, [r0]                        @ 0800A310  r0 = va_vsub (u8)
    cmp r0, #0                           @ 0800A312
    beq .Lmva_voltage_autorange_store    @ 0800A314  if va_vsub == 0
    movs r0, #0                          @ 0800A316
    ldr r1, =v_200080C6                  @ 0800A318
    strb r0, [r1]                        @ 0800A31C  va_vsub (u8) = 0
    bl fn_080148F6                       @ 0800A31E  MVA: meter_range from the sub-range flags
    ldr r1, =meter_range                 @ 0800A322
    strb r0, [r1]                        @ 0800A324  meter_range (u8) = r0
    bl fn_0800D8C2                       @ 0800A326  MVA: apply a VA range change
.Lmva_voltage_autorange_store:   @ store the voltage
    @ secondary display voltage = V; redraw in setup page 10
    ldr r0, =v_20007EAC                  @ 0800A32A
    str r4, [r0]                         @ 0800A32E  va_v_sec (u32) = V
    ldr r0, =v_20008037                  @ 0800A330
    ldrb r0, [r0]                        @ 0800A334  r0 = setup_item (u8)
    cmp r0, #0xa                         @ 0800A336
    bne .Lmva_voltage_autorange_exit     @ 0800A338  if setup_item != 10
    movs r0, #1                          @ 0800A33A
    ldr r1, =v_20008062                  @ 0800A33C
    strb r0, [r1]                        @ 0800A340  sec_refresh (u8) = 1
.Lmva_voltage_autorange_exit:   @ return
    pop {r0, r4, r5, pc}                 @ 0800A342
    .ltorg
ENDFUNC fn_0800A260
    .global mva_voltage_autorange
    .set mva_voltage_autorange, fn_0800A260

@ -----------------------------------------------------------------------------
@ fn_0800A358 (mva_current_autorange) - current autorange of the VA modes: overload flag, step the current sub-range up / down, remember the
@   current for the secondary display (scaled for the display)
@ Replaces : 0x0800A358 FUN_0800a358 (v2.05)
@ In       : r0 = current count (signed in the DC modes, non-negative in the AC modes)
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080084E0, fn_08008B8C)
@ Registers: r4 = I (argument), r5 = up limit, r6 = down limit, r7 = |I|
@ RAM      : reads  0x20008037 setup_item, 0x2000803C meter_mode, 0x20008042 range_manual, 0x2000804E minmax_state,
@            0x2000808A cal_mode, 0x200080C7 va_isub
@            writes 0x20007EB0 va_i_sec, 0x20007EB4 va_i_full, 0x2000803D meter_range, 0x20008062 sec_refresh,
@            0x200080C1 va_dashes_i, 0x200080C7 va_isub, 0x200080CB va_i_over
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.7)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800A358
    push {r3, r4, r5, r6, r7, lr}        @ 0800A358
    movs r4, r0                          @ 0800A35A
    @ limits (up, down) = (11000, 400) for modes 15, 24 with the high current sub-range, else (55000, 4000)
    ldr r0, =meter_mode                  @ 0800A35C
    ldrb r0, [r0]                        @ 0800A35E  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 0800A360
    beq .Lmva_current_autorange_0800A36C @ 0800A362  if meter_mode == 15
    ldr r0, =meter_mode                  @ 0800A364
    ldrb r0, [r0]                        @ 0800A366  r0 = meter_mode (u8)
    cmp r0, #0x18                        @ 0800A368
    bne .Lmva_current_autorange_lim55    @ 0800A36A  if meter_mode != 24
.Lmva_current_autorange_0800A36C:   @ branch target from 0800A362
    ldr r0, =v_200080C7                  @ 0800A36C
    ldrb r0, [r0]                        @ 0800A370  r0 = va_isub (u8)
    cmp r0, #0                           @ 0800A372
    beq .Lmva_current_autorange_lim55    @ 0800A374  if va_isub == 0
    movw r0, #0x2af8                     @ 0800A376  0x2AF8 = 11000
    movs r5, r0                          @ 0800A37A
    mov r0, #0x190                       @ 0800A37C  400
    movs r6, r0                          @ 0800A380
    b .Lmva_current_autorange_abs        @ 0800A382
.Lmva_current_autorange_lim55:   @ limits 55000 / 4000
    movw r0, #0xd6d8                     @ 0800A384  0xD6D8 = 55000
    movs r5, r0                          @ 0800A388
    mov r0, #0xfa0                       @ 0800A38A  0xFA0 = 4000
    movs r6, r0                          @ 0800A38E
.Lmva_current_autorange_abs:   @ absolute value
    @ r7 = |I| in the DC modes 22, 23, 24, else I; va_i_over = 0, va_dashes_i = 0
    movs r7, r4                          @ 0800A390
    ldr r0, =meter_mode                  @ 0800A392
    ldrb r0, [r0]                        @ 0800A394  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 0800A396
    beq .Lmva_current_autorange_absval   @ 0800A398  if meter_mode == 22
    ldr r0, =meter_mode                  @ 0800A39A
    ldrb r0, [r0]                        @ 0800A39C  r0 = meter_mode (u8)
    cmp r0, #0x17                        @ 0800A39E
    beq .Lmva_current_autorange_absval   @ 0800A3A0  if meter_mode == 23
    ldr r0, =meter_mode                  @ 0800A3A2
    ldrb r0, [r0]                        @ 0800A3A4  r0 = meter_mode (u8)
    cmp r0, #0x18                        @ 0800A3A6
    bne .Lmva_current_autorange_test     @ 0800A3A8  if meter_mode != 24
.Lmva_current_autorange_absval:   @ DC VA modes
    cmp r4, #0                           @ 0800A3AA
    bpl .Lmva_current_autorange_test     @ 0800A3AC  if I >= 0
    rsbs r0, r4, #0                      @ 0800A3AE  r0 = -I
    movs r7, r0                          @ 0800A3B0
.Lmva_current_autorange_test:   @ limit tests
    movs r0, #0                          @ 0800A3B2
    ldr r1, =v_200080CB                  @ 0800A3B4
    strb r0, [r1]                        @ 0800A3B8  va_i_over (u8) = 0
    movs r0, #0                          @ 0800A3BA
    ldr r1, =v_200080C1                  @ 0800A3BC
    strb r0, [r1]                        @ 0800A3C0  va_dashes_i (u8) = 0
    cmp r5, r7                           @ 0800A3C2
    @ |I| > up: current overload; step the sub-range up when autorange is allowed (calibration mode off, range not manual, MIN/MAX off, sub-range 0)
    bge .Lmva_current_autorange_low      @ 0800A3C4  if r5 >= (signed) r7
    movs r0, #1                          @ 0800A3C6
    ldr r1, =v_200080CB                  @ 0800A3C8
    strb r0, [r1]                        @ 0800A3CC  va_i_over (u8) = 1
    ldr r0, =v_2000808A                  @ 0800A3CE
    ldrb r0, [r0]                        @ 0800A3D0  r0 = cal_mode (u8)
    ldr r1, =range_manual                @ 0800A3D2
    ldrb r1, [r1]                        @ 0800A3D6  r1 = range_manual (u8)
    orrs r0, r1                          @ 0800A3D8  r0 = cal_mode | range_manual
    uxtb r0, r0                          @ 0800A3DA
    cmp r0, #0                           @ 0800A3DC
    bne .Lmva_current_autorange_store    @ 0800A3DE  if r0 != 0
    ldr r0, =minmax_state                @ 0800A3E0
    ldrb r0, [r0]                        @ 0800A3E4  r0 = minmax_state (u8)
    cmp r0, #0                           @ 0800A3E6
    bne .Lmva_current_autorange_store    @ 0800A3E8  if minmax_state != 0
    ldr r0, =v_200080C7                  @ 0800A3EA
    ldrb r0, [r0]                        @ 0800A3EE  r0 = va_isub (u8)
    cmp r0, #0                           @ 0800A3F0
    bne .Lmva_current_autorange_store    @ 0800A3F2  if va_isub != 0
    movs r0, #1                          @ 0800A3F4
    ldr r1, =v_200080C7                  @ 0800A3F6
    strb r0, [r1]                        @ 0800A3FA  va_isub (u8) = 1
    bl fn_080148F6                       @ 0800A3FC  MVA: meter_range from the sub-range flags
    ldr r1, =meter_range                 @ 0800A400
    strb r0, [r1]                        @ 0800A402  meter_range (u8) = r0
    bl fn_0800D8C2                       @ 0800A404  MVA: apply a VA range change
    b .Lmva_current_autorange_store      @ 0800A408
.Lmva_current_autorange_low:   @ within the upper limit
    @ |I| < down with the high sub-range: step down (same gating)
    cmp r7, r6                           @ 0800A40A
    bge .Lmva_current_autorange_store    @ 0800A40C  if r7 >= (signed) r6
    ldr r0, =v_2000808A                  @ 0800A40E
    ldrb r0, [r0]                        @ 0800A410  r0 = cal_mode (u8)
    ldr r1, =range_manual                @ 0800A412
    ldrb r1, [r1]                        @ 0800A416  r1 = range_manual (u8)
    orrs r0, r1                          @ 0800A418  r0 = cal_mode | range_manual
    uxtb r0, r0                          @ 0800A41A
    cmp r0, #0                           @ 0800A41C
    bne .Lmva_current_autorange_store    @ 0800A41E  if r0 != 0
    ldr r0, =minmax_state                @ 0800A420
    ldrb r0, [r0]                        @ 0800A424  r0 = minmax_state (u8)
    cmp r0, #0                           @ 0800A426
    bne .Lmva_current_autorange_store    @ 0800A428  if minmax_state != 0
    ldr r0, =v_200080C7                  @ 0800A42A
    ldrb r0, [r0]                        @ 0800A42E  r0 = va_isub (u8)
    cmp r0, #0                           @ 0800A430
    beq .Lmva_current_autorange_store    @ 0800A432  if va_isub == 0
    movs r0, #0                          @ 0800A434
    ldr r1, =v_200080C7                  @ 0800A436
    strb r0, [r1]                        @ 0800A43A  va_isub (u8) = 0
    bl fn_080148F6                       @ 0800A43C  MVA: meter_range from the sub-range flags
    ldr r1, =meter_range                 @ 0800A440
    strb r0, [r1]                        @ 0800A442  meter_range (u8) = r0
    bl fn_0800D8C2                       @ 0800A444  MVA: apply a VA range change
.Lmva_current_autorange_store:   @ store for the display
    @ secondary display current: modes 13, 22: I / 100 (sub-range 0) or I / 10 (sub-range 1) and the full count; other modes: I
    ldr r0, =meter_mode                  @ 0800A448
    ldrb r0, [r0]                        @ 0800A44A  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 0800A44C
    beq .Lmva_current_autorange_scale    @ 0800A44E  if meter_mode == 13
    ldr r0, =meter_mode                  @ 0800A450
    ldrb r0, [r0]                        @ 0800A452  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 0800A454
    bne .Lmva_current_autorange_plain    @ 0800A456  if meter_mode != 22
.Lmva_current_autorange_scale:   @ modes 13, 22
    ldr r0, =v_200080C7                  @ 0800A458
    ldrb r0, [r0]                        @ 0800A45C  r0 = va_isub (u8)
    cmp r0, #0                           @ 0800A45E
    beq .Lmva_current_autorange_div100   @ 0800A460  if va_isub == 0
    cmp r0, #1                           @ 0800A462
    beq .Lmva_current_autorange_div10    @ 0800A464  if va_isub == 1
    b .Lmva_current_autorange_full       @ 0800A466
.Lmva_current_autorange_div100:   @ sub-range 0
    movs r0, #0x64                       @ 0800A468  = 100
    sdiv r0, r4, r0                      @ 0800A46A  r0 = I / 100
    ldr r1, =v_20007EB0                  @ 0800A46E
    str r0, [r1]                         @ 0800A472  va_i_sec (u32) = (I / 100)
    b .Lmva_current_autorange_full       @ 0800A474
.Lmva_current_autorange_div10:   @ sub-range 1
    movs r0, #0xa                        @ 0800A476
    sdiv r0, r4, r0                      @ 0800A478  r0 = I / 10
    ldr r1, =v_20007EB0                  @ 0800A47C
    str r0, [r1]                         @ 0800A480  va_i_sec (u32) = (I / 10)
.Lmva_current_autorange_full:   @ full count
    ldr r0, =v_20007EB4                  @ 0800A482
    str r4, [r0]                         @ 0800A486  va_i_full (u32) = I
    b .Lmva_current_autorange_page       @ 0800A488
.Lmva_current_autorange_plain:   @ other modes
    ldr r0, =v_20007EB0                  @ 0800A48A
    str r4, [r0]                         @ 0800A48E  va_i_sec (u32) = I
.Lmva_current_autorange_page:   @ page check
    @ redraw in setup page 11
    ldr r0, =v_20008037                  @ 0800A490
    ldrb r0, [r0]                        @ 0800A494  r0 = setup_item (u8)
    cmp r0, #0xb                         @ 0800A496
    bne .Lmva_current_autorange_exit     @ 0800A498  if setup_item != 11
    movs r0, #1                          @ 0800A49A
    ldr r1, =v_20008062                  @ 0800A49C
    strb r0, [r1]                        @ 0800A4A0  sec_refresh (u8) = 1
.Lmva_current_autorange_exit:   @ return
    pop {r0, r4, r5, r6, r7, pc}         @ 0800A4A2
    .ltorg
ENDFUNC fn_0800A358
    .global mva_current_autorange
    .set mva_current_autorange, fn_0800A358

@ -----------------------------------------------------------------------------
@ fn_0800A4AC (mva_power) - power of the VA modes: reading = |V| * |I| / d with a 64-bit product and quotient
@ Replaces : 0x0800A4AC FUN_0800a4ac (v2.05)
@ In       : r0 = voltage count
@            r1 = current count
@ Out      : reading (0x20007D64); divisor d = 100000 (modes 13, 14, 22, 23 and modes 15, 24 below range 2), 10000 (modes 15, 24 from range 2)
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080084E0, fn_08008B8C)
@ Registers: r4 = V, r5 = I, r9:r8 = |V|, fp:sl = |I|, r7:r6 = divisor d
@ RAM      : reads  0x2000803C meter_mode, 0x2000803D meter_range
@            writes 0x20007D64 reading
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.7)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800A4AC
    push {r4, r5, r6, r7, r8, sb, sl, fp, lr} @ 0800A4AC
    movs r4, r0                          @ 0800A4B0
    @ r9:r8 = |V| as 64 bit, r11:r10 = |I| as 64 bit
    movs r5, r1                          @ 0800A4B2
    cmp r4, #0                           @ 0800A4B4
    bpl .Lmva_power_0800A4C2             @ 0800A4B6  if V >= 0
    rsbs r0, r4, #0                      @ 0800A4B8  r0 = -V
    asrs r1, r0, #0x1f                   @ 0800A4BA  r1 = -V >> 0x1F
    mov r8, r0                           @ 0800A4BC
    mov sb, r1                           @ 0800A4BE
    b .Lmva_power_0800A4CA               @ 0800A4C0
.Lmva_power_0800A4C2:   @ branch target from 0800A4B6
    movs r0, r4                          @ 0800A4C2
    asrs r1, r4, #0x1f                   @ 0800A4C4  r1 = V >> 0x1F
    mov r8, r0                           @ 0800A4C6
    mov sb, r1                           @ 0800A4C8
.Lmva_power_0800A4CA:   @ branch target from 0800A4C0
    cmp r5, #0                           @ 0800A4CA
    bpl .Lmva_power_0800A4D8             @ 0800A4CC  if I >= 0
    rsbs r0, r5, #0                      @ 0800A4CE  r0 = -I
    asrs r1, r0, #0x1f                   @ 0800A4D0  r1 = -I >> 0x1F
    mov sl, r0                           @ 0800A4D2
    mov fp, r1                           @ 0800A4D4
    b .Lmva_power_0800A4E0               @ 0800A4D6
.Lmva_power_0800A4D8:   @ branch target from 0800A4CC
    movs r0, r5                          @ 0800A4D8
    asrs r1, r5, #0x1f                   @ 0800A4DA  r1 = I >> 0x1F
    mov sl, r0                           @ 0800A4DC
    mov fp, r1                           @ 0800A4DE
.Lmva_power_0800A4E0:   @ branch target from 0800A4D6
    @ divisor d in r7:r6
    ldr r0, =meter_mode                  @ 0800A4E0
    ldrb r0, [r0]                        @ 0800A4E4  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 0800A4E6
    beq .Lmva_power_d100k                @ 0800A4E8  if meter_mode == 14
    ldr r0, =meter_mode                  @ 0800A4EA
    ldrb r0, [r0]                        @ 0800A4EE  r0 = meter_mode (u8)
    cmp r0, #0x17                        @ 0800A4F0
    bne .Lmva_power_0800A500             @ 0800A4F2  if meter_mode != 23
.Lmva_power_d100k:   @ d = 100000
    ldr r0, =0x000186A0                  @ 0800A4F4
    movs r1, #0                          @ 0800A4F8
    movs r6, r0                          @ 0800A4FA
    movs r7, r1                          @ 0800A4FC
    b .Lmva_power_div                    @ 0800A4FE
.Lmva_power_0800A500:   @ branch target from 0800A4F2
    ldr r0, =meter_mode                  @ 0800A500
    ldrb r0, [r0]                        @ 0800A504  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 0800A506
    beq .Lmva_power_0800A514             @ 0800A508  if meter_mode == 13
    ldr r0, =meter_mode                  @ 0800A50A
    ldrb r0, [r0]                        @ 0800A50E  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 0800A510
    bne .Lmva_power_0800A520             @ 0800A512  if meter_mode != 22
.Lmva_power_0800A514:   @ branch target from 0800A508
    ldr r0, =0x000186A0                  @ 0800A514
    movs r1, #0                          @ 0800A518
    movs r6, r0                          @ 0800A51A
    movs r7, r1                          @ 0800A51C
    b .Lmva_power_div                    @ 0800A51E
.Lmva_power_0800A520:   @ branch target from 0800A512
    ldr r0, =meter_range                 @ 0800A520
    ldrb r0, [r0]                        @ 0800A522  r0 = meter_range (u8)
    cmp r0, #2                           @ 0800A524
    blt .Lmva_power_d100k2               @ 0800A526  if meter_range < (signed) 2
    movw r0, #0x2710                     @ 0800A528  = 10000
    movs r1, #0                          @ 0800A52C
    movs r6, r0                          @ 0800A52E
    movs r7, r1                          @ 0800A530
    b .Lmva_power_div                    @ 0800A532
.Lmva_power_d100k2:   @ range 0, 1: d = 100000
    ldr r0, =0x000186A0                  @ 0800A534
    movs r1, #0                          @ 0800A538
    movs r6, r0                          @ 0800A53A
    movs r7, r1                          @ 0800A53C
.Lmva_power_div:   @ product and divide
    @ 64-bit product, divided by d (RT int64 division); the low word is the reading
    umull r0, r1, r8, sl                 @ 0800A53E
    mla r1, r8, fp, r1                   @ 0800A542  r1 = r8 * fp + r1
    mla r1, sb, sl, r1                   @ 0800A546  r1 = sb * sl + (r8 * fp + r1)
    movs r2, r6                          @ 0800A54A
    movs r3, r7                          @ 0800A54C
    bl fn_08013FE4                       @ 0800A54E  RT: int64 r0:r1 = r0:r1 / r2:r3 (signed, truncating)
    ldr r1, =v_20007D64                  @ 0800A552
    str r0, [r1]                         @ 0800A556  reading (u32) = r0
    pop {r4, r5, r6, r7, r8, sb, sl, fp, pc} @ 0800A558
    .ltorg
ENDFUNC fn_0800A4AC
    .global mva_power
    .set mva_power, fn_0800A4AC

@ -----------------------------------------------------------------------------
@ fn_0800A560 (mva_blank) - blank the VA displays after a mode entry or range change: secondary values 0, overload flags cleared,
@   dashes requested on the main and both secondary values
@ Replaces : 0x0800A560 FUN_0800a560 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_0800D8C2, meter_apply_mode_range)
@ RAM      : reads  -
@            writes 0x20007EAC va_v_sec, 0x20007EB0 va_i_sec, 0x2000805D new_reading, 0x20008062 sec_refresh,
@            0x200080BF va_dashes, 0x200080C0 va_dashes_v, 0x200080C1 va_dashes_i, 0x200080CA va_v_over,
@            0x200080CB va_i_over
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.7 "Main display")
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800A560
    push {r7, lr}                        @ 0800A560
    movs r0, #0                          @ 0800A562
    ldr r1, =v_20007EAC                  @ 0800A564
    str r0, [r1]                         @ 0800A568  va_v_sec (u32) = 0
    movs r0, #0                          @ 0800A56A
    ldr r1, =v_20007EB0                  @ 0800A56C
    str r0, [r1]                         @ 0800A570  va_i_sec (u32) = 0
    movs r0, #0                          @ 0800A572
    ldr r1, =v_200080CA                  @ 0800A574
    strb r0, [r1]                        @ 0800A578  va_v_over (u8) = 0
    movs r0, #0                          @ 0800A57A
    ldr r1, =v_200080CB                  @ 0800A57C
    strb r0, [r1]                        @ 0800A580  va_i_over (u8) = 0
    movs r0, #1                          @ 0800A582
    ldr r1, =v_200080BF                  @ 0800A584
    strb r0, [r1]                        @ 0800A588  va_dashes (u8) = 1
    movs r0, #1                          @ 0800A58A
    ldr r1, =v_200080C0                  @ 0800A58C
    strb r0, [r1]                        @ 0800A590  va_dashes_v (u8) = 1
    movs r0, #1                          @ 0800A592
    ldr r1, =v_200080C1                  @ 0800A594
    strb r0, [r1]                        @ 0800A598  va_dashes_i (u8) = 1
    movs r0, #1                          @ 0800A59A
    ldr r1, =v_2000805D                  @ 0800A59C
    strb r0, [r1]                        @ 0800A5A0  new_reading (u8) = 1
    movs r0, #1                          @ 0800A5A2
    ldr r1, =v_20008062                  @ 0800A5A4
    strb r0, [r1]                        @ 0800A5A8  sec_refresh (u8) = 1
    movs r0, #0                          @ 0800A5AA
    bl fn_08017FB4                       @ 0800A5AC  LCD: secondary-display redraw (r0)
    pop {r0, pc}                         @ 0800A5B0
    .ltorg
ENDFUNC fn_0800A560
    .global mva_blank
    .set mva_blank, fn_0800A560

@ -----------------------------------------------------------------------------
@ fn_0800D8C2 (mva_range_applied) - apply a VA range change made by the autorange: restart the channel cycle on the voltage channel,
@   re-apply the HY3131 row and calibration record, blank the displays, set the front end and decimals
@ Replaces : 0x0800D8C2 FUN_0800d8c2 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_0800A260, fn_0800A358)
@ RAM      : reads  0x2000803C meter_mode, 0x2000803D meter_range
@            writes 0x200080C3 va_range_changed, 0x200080C4 va_channel, 0x200080C5 va_mean_count
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.7 "Range change")
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800D8C2
    push {r7, lr}                        @ 0800D8C2
    @ no channel toggle and no power in this pass (va_range_changed); mean counter 0; channel 0 (voltage)
    movs r0, #1                          @ 0800D8C4
    ldr r1, =v_200080C3                  @ 0800D8C6
    strb r0, [r1]                        @ 0800D8CA  va_range_changed (u8) = 1
    movs r0, #0                          @ 0800D8CC
    ldr r1, =v_200080C5                  @ 0800D8CE
    strb r0, [r1]                        @ 0800D8D2  va_mean_count (u8) = 0
    movs r0, #0                          @ 0800D8D4
    ldr r1, =va_channel                  @ 0800D8D6
    strb r0, [r1]                        @ 0800D8DA  va_channel (u8) = 0
    @ row, record and both calibration pairs of the new range (fn_0800D80C(1))
    movs r0, #1                          @ 0800D8DC
    bl fn_0800D80C                       @ 0800D8DE  MODE: re-apply HY row (r0 = 1: also reload the calibration record)
    @ blank the displays
    bl fn_0800A560                       @ 0800D8E2  MVA: blank the VA displays after a range change
    @ front-end shunt select, settle count, annunciator and decimal point of the new range
    ldr r0, =meter_range                 @ 0800D8E6
    ldrb r1, [r0]                        @ 0800D8EA  r1 = meter_range (u8)
    ldr r0, =meter_mode                  @ 0800D8EC
    ldrb r0, [r0]                        @ 0800D8F0  r0 = meter_mode (u8)
    bl fn_0800FE74                       @ 0800D8F2  BRD: front-end shunt select PE5 for (mode r0, range r1)
    bl fn_0800DB48                       @ 0800D8F6  MODE: set the settle count 0x20000238 for the active mode and range
    ldr r0, =meter_range                 @ 0800D8FA
    ldrb r1, [r0]                        @ 0800D8FE  r1 = meter_range (u8)
    ldr r0, =meter_mode                  @ 0800D900
    ldrb r0, [r0]                        @ 0800D904  r0 = meter_mode (u8)
    bl fn_08017700                       @ 0800D906  LCD: mode 15/24 annunciator bit for the range (mode r0, range r1)
    bl fn_080171FA                       @ 0800D90A  UI: refresh the decimal point for the active mode and range
    pop {r0, pc}                         @ 0800D90E
    .ltorg
ENDFUNC fn_0800D8C2
    .global mva_range_applied
    .set mva_range_applied, fn_0800D8C2

@ -----------------------------------------------------------------------------
@ fn_0801485A (mva_range_to_sub) - VA modes: sub-range flags from a range number (RANGE key): 0 -> (0,0), 1 -> (1,0), 2 -> (0,1), 3 -> (1,1);
@   the high current sub-range of modes 15 and 24 is stored as 2
@ Replaces : 0x0801485A FUN_0801485a (v2.05)
@ In       : r0 = mode (the function acts on 13, 14, 15, 22, 23, 24 only)
@            r1 = range 0..3
@ Out      : va_vsub (0x200080C6), va_isub (0x200080C7)
@ Clobbers : r0, r1, r2, r3, flags
@ Context  : main only (KEY, MODE)
@ RAM      : reads  0x200080C7 va_isub
@            writes 0x200080C6 va_vsub, 0x200080C7 va_isub
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.2)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0801485A
    uxtb r0, r0                          @ 0801485A
    cmp r0, #0xd                         @ 0801485C
    beq .Lmva_range_to_sub_0801487E      @ 0801485E  if r0 == 13
    uxtb r0, r0                          @ 08014860
    cmp r0, #0xe                         @ 08014862
    beq .Lmva_range_to_sub_0801487E      @ 08014864  if r0 == 14
    uxtb r0, r0                          @ 08014866
    cmp r0, #0xf                         @ 08014868
    beq .Lmva_range_to_sub_0801487E      @ 0801486A  if r0 == 15
    uxtb r0, r0                          @ 0801486C
    cmp r0, #0x16                        @ 0801486E
    beq .Lmva_range_to_sub_0801487E      @ 08014870  if r0 == 22
    uxtb r0, r0                          @ 08014872
    cmp r0, #0x17                        @ 08014874
    beq .Lmva_range_to_sub_0801487E      @ 08014876  if r0 == 23
    uxtb r0, r0                          @ 08014878
    cmp r0, #0x18                        @ 0801487A
    bne .Lmva_range_to_sub_080148F4      @ 0801487C  if r0 != 24
.Lmva_range_to_sub_0801487E:   @ branch target from 0801485E, 08014864, 0801486A, 08014870, 08014876
    @ va_vsub, va_isub by range
    uxtb r1, r1                          @ 0801487E
    cmp r1, #0                           @ 08014880
    beq .Lmva_range_to_sub_08014890      @ 08014882  if r1 == 0
    cmp r1, #2                           @ 08014884
    beq .Lmva_range_to_sub_080148B4      @ 08014886  if r1 == 2
    blo .Lmva_range_to_sub_080148A2      @ 08014888  if r1 < (unsigned) 2
    cmp r1, #3                           @ 0801488A
    beq .Lmva_range_to_sub_080148C6      @ 0801488C  if r1 == 3
    b .Lmva_range_to_sub_080148D6        @ 0801488E
.Lmva_range_to_sub_08014890:   @ branch target from 08014882
    movs r2, #0                          @ 08014890
    ldr r3, =v_200080C6                  @ 08014892
    strb r2, [r3]                        @ 08014896  va_vsub (u8) = 0
    movs r2, #0                          @ 08014898
    ldr r3, =v_200080C7                  @ 0801489A
    strb r2, [r3]                        @ 0801489E  va_isub (u8) = 0
    b .Lmva_range_to_sub_080148D6        @ 080148A0
.Lmva_range_to_sub_080148A2:   @ branch target from 08014888
    movs r2, #1                          @ 080148A2
    ldr r3, =v_200080C6                  @ 080148A4
    strb r2, [r3]                        @ 080148A8  va_vsub (u8) = 1
    movs r2, #0                          @ 080148AA
    ldr r3, =v_200080C7                  @ 080148AC
    strb r2, [r3]                        @ 080148B0  va_isub (u8) = 0
    b .Lmva_range_to_sub_080148D6        @ 080148B2
.Lmva_range_to_sub_080148B4:   @ branch target from 08014886
    movs r2, #0                          @ 080148B4
    ldr r3, =v_200080C6                  @ 080148B6
    strb r2, [r3]                        @ 080148BA  va_vsub (u8) = 0
    movs r2, #1                          @ 080148BC
    ldr r3, =v_200080C7                  @ 080148BE
    strb r2, [r3]                        @ 080148C2  va_isub (u8) = 1
    b .Lmva_range_to_sub_080148D6        @ 080148C4
.Lmva_range_to_sub_080148C6:   @ branch target from 0801488C
    movs r2, #1                          @ 080148C6
    ldr r3, =v_200080C6                  @ 080148C8
    strb r2, [r3]                        @ 080148CC  va_vsub (u8) = 1
    movs r2, #1                          @ 080148CE
    ldr r3, =v_200080C7                  @ 080148D0
    strb r2, [r3]                        @ 080148D4  va_isub (u8) = 1
.Lmva_range_to_sub_080148D6:   @ branch target from 0801488E, 080148A0, 080148B2, 080148C4
    @ modes 15 and 24: a high current sub-range of 1 is stored as 2
    uxtb r0, r0                          @ 080148D6
    cmp r0, #0xf                         @ 080148D8
    beq .Lmva_range_to_sub_080148E2      @ 080148DA  if r0 == 15
    uxtb r0, r0                          @ 080148DC
    cmp r0, #0x18                        @ 080148DE
    bne .Lmva_range_to_sub_080148F4      @ 080148E0  if r0 != 24
.Lmva_range_to_sub_080148E2:   @ branch target from 080148DA
    ldr r2, =v_200080C7                  @ 080148E2
    ldrb r2, [r2]                        @ 080148E6  r2 = va_isub (u8)
    cmp r2, #1                           @ 080148E8
    bne .Lmva_range_to_sub_080148F4      @ 080148EA  if va_isub != 1
    movs r2, #2                          @ 080148EC
    ldr r3, =v_200080C7                  @ 080148EE
    strb r2, [r3]                        @ 080148F2  va_isub (u8) = 2
.Lmva_range_to_sub_080148F4:   @ branch target from 0801487C, 080148E0, 080148EA
    bx lr                                @ 080148F4
    .ltorg
ENDFUNC fn_0801485A
    .global mva_range_to_sub
    .set mva_range_to_sub, fn_0801485A

@ -----------------------------------------------------------------------------
@ fn_080148F6 (mva_sub_to_range) - VA modes: meter_range from the sub-range flags: (0,0) -> 0, (1,0) -> 1, (0,!=0) -> 2, (1,!=0) -> 3
@ Replaces : 0x080148F6 FUN_080148f6 (v2.05)
@ In       : -
@ Out      : r0 = range 0..3
@ Clobbers : r0, r1, flags
@ Context  : main only (fn_0800A260, fn_0800A358)
@ RAM      : reads  0x200080C6 va_vsub, 0x200080C7 va_isub
@            writes -
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.2)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_080148F6
    movs r0, #0                          @ 080148F6
    ldr r1, =v_200080C6                  @ 080148F8
    ldrb r1, [r1]                        @ 080148FC  r1 = va_vsub (u8)
    cmp r1, #0                           @ 080148FE
    beq .Lmva_sub_to_range_08014912      @ 08014900  if va_vsub == 0
    ldr r1, =v_200080C7                  @ 08014902
    ldrb r1, [r1]                        @ 08014906  r1 = va_isub (u8)
    cmp r1, #0                           @ 08014908
    bne .Lmva_sub_to_range_08014912      @ 0801490A  if va_isub != 0
    movs r1, #1                          @ 0801490C
    movs r0, r1                          @ 0801490E
    b .Lmva_sub_to_range_08014944        @ 08014910
.Lmva_sub_to_range_08014912:   @ branch target from 08014900, 0801490A
    ldr r1, =v_200080C6                  @ 08014912
    ldrb r1, [r1]                        @ 08014916  r1 = va_vsub (u8)
    cmp r1, #0                           @ 08014918
    bne .Lmva_sub_to_range_0801492C      @ 0801491A  if va_vsub != 0
    ldr r1, =v_200080C7                  @ 0801491C
    ldrb r1, [r1]                        @ 08014920  r1 = va_isub (u8)
    cmp r1, #0                           @ 08014922
    beq .Lmva_sub_to_range_0801492C      @ 08014924  if va_isub == 0
    movs r1, #2                          @ 08014926
    movs r0, r1                          @ 08014928
    b .Lmva_sub_to_range_08014944        @ 0801492A
.Lmva_sub_to_range_0801492C:   @ branch target from 0801491A, 08014924
    ldr r1, =v_200080C6                  @ 0801492C
    ldrb r1, [r1]                        @ 08014930  r1 = va_vsub (u8)
    cmp r1, #0                           @ 08014932
    beq .Lmva_sub_to_range_08014944      @ 08014934  if va_vsub == 0
    ldr r1, =v_200080C7                  @ 08014936
    ldrb r1, [r1]                        @ 0801493A  r1 = va_isub (u8)
    cmp r1, #0                           @ 0801493C
    beq .Lmva_sub_to_range_08014944      @ 0801493E  if va_isub == 0
    movs r1, #3                          @ 08014940
    movs r0, r1                          @ 08014942
.Lmva_sub_to_range_08014944:   @ branch target from 08014910, 0801492A, 08014934, 0801493E
    uxtb r0, r0                          @ 08014944
    bx lr                                @ 08014946
    .ltorg
ENDFUNC fn_080148F6
    .global mva_sub_to_range
    .set mva_sub_to_range, fn_080148F6

@ -----------------------------------------------------------------------------
@ fn_080087F8 (mva_dc_current_offset) - DC VA current offset K added to the smoothed current count: a constant by mode, range and the signs of the
@   voltage and the current when the current is outside -2500..2500
@ Replaces : 0x080087F8 FUN_080087f8 (v2.05)
@ In       : r0 = voltage count V (va_voltage)
@            r1 = smoothed current count Ds
@ Out      : r0 = K (0 unless cal_mode = 0, mode 22..24, pf8_flag = 0 and ohm6_marker = 1, and |Ds| > 2500)
@ Clobbers : r0, r2, r3, flags
@ Context  : main only (fn_08008138)
@ Registers: r2 = V (argument), r1 = Ds (argument), r3 = K (result), r4 = scratch
@ RAM      : reads  0x20007FDF pf8_flag, 0x20007FE0 ohm6_marker, 0x2000803C meter_mode, 0x2000803D meter_range,
@            0x2000808A cal_mode
@            writes -
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.6)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_080087F8
    push {r4}                            @ 080087F8
    movs r2, r0                          @ 080087FA
    movs r3, #0                          @ 080087FC
    @ gate: calibration mode off, mode 22, 23 or 24, pf8_flag = 0, ohm6_marker = 1
    ldr r0, =v_2000808A                  @ 080087FE
    ldrb r0, [r0]                        @ 08008802  r0 = cal_mode (u8)
    cmp r0, #0                           @ 08008804
    bne .Lmva_dc_current_offset_out      @ 08008806  if cal_mode != 0
    ldr r0, =meter_mode                  @ 0800880A
    ldrb r0, [r0]                        @ 0800880E  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 08008810
    beq .Lmva_dc_current_offset_0800882A @ 08008812  if meter_mode == 22
    ldr r0, =meter_mode                  @ 08008814
    ldrb r0, [r0]                        @ 08008818  r0 = meter_mode (u8)
    cmp r0, #0x17                        @ 0800881A
    beq .Lmva_dc_current_offset_0800882A @ 0800881C  if meter_mode == 23
    ldr r0, =meter_mode                  @ 0800881E
    ldrb r0, [r0]                        @ 08008822  r0 = meter_mode (u8)
    cmp r0, #0x18                        @ 08008824
    bne .Lmva_dc_current_offset_out      @ 08008826  if meter_mode != 24
.Lmva_dc_current_offset_0800882A:   @ branch target from 08008812, 0800881C
    ldr r0, =v_20007FDF                  @ 0800882A
    ldrb r0, [r0]                        @ 0800882E  r0 = pf8_flag (u8)
    ldr r4, =v_20007FE0                  @ 08008830
    ldrb r4, [r4]                        @ 08008834  r4 = ohm6_marker (u8)
    eors r4, r4, #1                      @ 08008836  r4 = ohm6_marker ^ 1
    orrs r0, r4                          @ 0800883A  r0 = pf8_flag | (ohm6_marker ^ 1)
    uxtb r0, r0                          @ 0800883C
    cmp r0, #0                           @ 0800883E
    bne .Lmva_dc_current_offset_out      @ 08008840  if r0 != 0
    @ -2500 <= Ds <= 2500 (0x9C5 = 2501): K = 0
    movw r0, #0x9c5                      @ 08008844  = 2501
    cmp r1, r0                           @ 08008848
    bge .Lmva_dc_current_offset_08008858 @ 0800884A  if r1 >= (signed) 2501
    ldr r0, =0xFFFFF63C                  @ 0800884C  = -2500
    cmp r1, r0                           @ 08008850
    blt .Lmva_dc_current_offset_08008858 @ 08008852  if r1 < (signed) 4294964796
    movs r0, #0                          @ 08008854
    b .Lmva_dc_current_offset_exit       @ 08008856
.Lmva_dc_current_offset_08008858:   @ branch target from 0800884A, 08008852
    @ dispatch on mode, then range; each case lists K for the four sign pairs in the order (V >= 0, Ds > 0), (V < 0, Ds > 0), (V >= 0, Ds < 0), (V < 0, Ds < 0)
    ldr r0, =meter_mode                  @ 08008858
    ldrb r0, [r0]                        @ 0800885C  r0 = meter_mode (u8)
    cmp r0, #0x16                        @ 0800885E
    beq .Lmva_dc_current_offset_08008870 @ 08008860  if meter_mode == 22
    blo .Lmva_dc_current_offset_out      @ 08008862  if meter_mode < (unsigned) 22
    cmp r0, #0x18                        @ 08008866
    beq .Lmva_dc_current_offset_08008A5C @ 08008868  if meter_mode == 24
    blo .Lmva_dc_current_offset_08008966 @ 0800886C  if meter_mode < (unsigned) 24
    b .Lmva_dc_current_offset_out        @ 0800886E
.Lmva_dc_current_offset_08008870:   @ branch target from 08008860
    ldr r0, =meter_range                 @ 08008870
    ldrb r0, [r0]                        @ 08008874  r0 = meter_range (u8)
    cmp r0, #0                           @ 08008876
    beq .Lmva_dc_current_offset_08008886 @ 08008878  if meter_range == 0
    cmp r0, #2                           @ 0800887A
    beq .Lmva_dc_current_offset_080088F6 @ 0800887C  if meter_range == 2
    blo .Lmva_dc_current_offset_080088BC @ 0800887E  if meter_range < (unsigned) 2
    cmp r0, #3                           @ 08008880
    beq .Lmva_dc_current_offset_0800892C @ 08008882  if meter_range == 3
    b .Lmva_dc_current_offset_08008964   @ 08008884
.Lmva_dc_current_offset_08008886:   @ branch target from 08008878
    @ mode 22 range 0: +200, +200, -200, -300
    cmp r2, #0                           @ 08008886
    bmi .Lmva_dc_current_offset_08008892 @ 08008888  if r2 < 0
    cmp r1, #0                           @ 0800888A
    bmi .Lmva_dc_current_offset_08008892 @ 0800888C  if r1 < 0
    movs r0, #0xc8                       @ 0800888E  = 200
    movs r3, r0                          @ 08008890
.Lmva_dc_current_offset_08008892:   @ branch target from 08008888, 0800888C
    cmp r2, #0                           @ 08008892
    bpl .Lmva_dc_current_offset_0800889E @ 08008894  if r2 >= 0
    cmp r1, #0                           @ 08008896
    bmi .Lmva_dc_current_offset_0800889E @ 08008898  if r1 < 0
    movs r0, #0xc8                       @ 0800889A  = 200
    movs r3, r0                          @ 0800889C
.Lmva_dc_current_offset_0800889E:   @ branch target from 08008894, 08008898
    cmp r2, #0                           @ 0800889E
    bmi .Lmva_dc_current_offset_080088AC @ 080088A0  if r2 < 0
    cmp r1, #0                           @ 080088A2
    bpl .Lmva_dc_current_offset_080088AC @ 080088A4  if r1 >= 0
    mvns r0, #0xc7                       @ 080088A6
    movs r3, r0                          @ 080088AA
.Lmva_dc_current_offset_080088AC:   @ branch target from 080088A0, 080088A4
    cmp r2, #0                           @ 080088AC
    bpl .Lmva_dc_current_offset_080088BA @ 080088AE  if r2 >= 0
    cmp r1, #0                           @ 080088B0
    bpl .Lmva_dc_current_offset_080088BA @ 080088B2  if r1 >= 0
    ldr r0, =0xFFFFFED4                  @ 080088B4  = -300
    movs r3, r0                          @ 080088B8
.Lmva_dc_current_offset_080088BA:   @ branch target from 080088AE, 080088B2
    b .Lmva_dc_current_offset_08008964   @ 080088BA
.Lmva_dc_current_offset_080088BC:   @ branch target from 0800887E
    @ mode 22 range 1: +2100, +2100, -2100, -2100
    cmp r2, #0                           @ 080088BC
    bmi .Lmva_dc_current_offset_080088CA @ 080088BE  if r2 < 0
    cmp r1, #0                           @ 080088C0
    bmi .Lmva_dc_current_offset_080088CA @ 080088C2  if r1 < 0
    movw r0, #0x834                      @ 080088C4  = 2100
    movs r3, r0                          @ 080088C8
.Lmva_dc_current_offset_080088CA:   @ branch target from 080088BE, 080088C2
    cmp r2, #0                           @ 080088CA
    bpl .Lmva_dc_current_offset_080088D8 @ 080088CC  if r2 >= 0
    cmp r1, #0                           @ 080088CE
    bmi .Lmva_dc_current_offset_080088D8 @ 080088D0  if r1 < 0
    movw r0, #0x834                      @ 080088D2  = 2100
    movs r3, r0                          @ 080088D6
.Lmva_dc_current_offset_080088D8:   @ branch target from 080088CC, 080088D0
    cmp r2, #0                           @ 080088D8
    bmi .Lmva_dc_current_offset_080088E6 @ 080088DA  if r2 < 0
    cmp r1, #0                           @ 080088DC
    bpl .Lmva_dc_current_offset_080088E6 @ 080088DE  if r1 >= 0
    ldr r0, =0xFFFFF7CC                  @ 080088E0  = -2100
    movs r3, r0                          @ 080088E4
.Lmva_dc_current_offset_080088E6:   @ branch target from 080088DA, 080088DE
    cmp r2, #0                           @ 080088E6
    bpl .Lmva_dc_current_offset_080088F4 @ 080088E8  if r2 >= 0
    cmp r1, #0                           @ 080088EA
    bpl .Lmva_dc_current_offset_080088F4 @ 080088EC  if r1 >= 0
    ldr r0, =0xFFFFF7CC                  @ 080088EE  = -2100
    movs r3, r0                          @ 080088F2
.Lmva_dc_current_offset_080088F4:   @ branch target from 080088E8, 080088EC
    b .Lmva_dc_current_offset_08008964   @ 080088F4
.Lmva_dc_current_offset_080088F6:   @ branch target from 0800887C
    @ mode 22 range 2: +130, +130, -170, -170
    cmp r2, #0                           @ 080088F6
    bmi .Lmva_dc_current_offset_08008902 @ 080088F8  if r2 < 0
    cmp r1, #0                           @ 080088FA
    bmi .Lmva_dc_current_offset_08008902 @ 080088FC  if r1 < 0
    movs r0, #0x82                       @ 080088FE  = 130
    movs r3, r0                          @ 08008900
.Lmva_dc_current_offset_08008902:   @ branch target from 080088F8, 080088FC
    cmp r2, #0                           @ 08008902
    bpl .Lmva_dc_current_offset_0800890E @ 08008904  if r2 >= 0
    cmp r1, #0                           @ 08008906
    bmi .Lmva_dc_current_offset_0800890E @ 08008908  if r1 < 0
    movs r0, #0x82                       @ 0800890A  = 130
    movs r3, r0                          @ 0800890C
.Lmva_dc_current_offset_0800890E:   @ branch target from 08008904, 08008908
    cmp r2, #0                           @ 0800890E
    bmi .Lmva_dc_current_offset_0800891C @ 08008910  if r2 < 0
    cmp r1, #0                           @ 08008912
    bpl .Lmva_dc_current_offset_0800891C @ 08008914  if r1 >= 0
    mvns r0, #0xa9                       @ 08008916
    movs r3, r0                          @ 0800891A
.Lmva_dc_current_offset_0800891C:   @ branch target from 08008910, 08008914
    cmp r2, #0                           @ 0800891C
    bpl .Lmva_dc_current_offset_0800892A @ 0800891E  if r2 >= 0
    cmp r1, #0                           @ 08008920
    bpl .Lmva_dc_current_offset_0800892A @ 08008922  if r1 >= 0
    mvns r0, #0xa9                       @ 08008924
    movs r3, r0                          @ 08008928
.Lmva_dc_current_offset_0800892A:   @ branch target from 0800891E, 08008922
    b .Lmva_dc_current_offset_08008964   @ 0800892A
.Lmva_dc_current_offset_0800892C:   @ branch target from 08008882
    @ mode 22 range 3: +2110, +2110, -2130, -2140
    cmp r2, #0                           @ 0800892C
    bmi .Lmva_dc_current_offset_0800893A @ 0800892E  if r2 < 0
    cmp r1, #0                           @ 08008930
    bmi .Lmva_dc_current_offset_0800893A @ 08008932  if r1 < 0
    movw r0, #0x83e                      @ 08008934  = 2110
    movs r3, r0                          @ 08008938
.Lmva_dc_current_offset_0800893A:   @ branch target from 0800892E, 08008932
    cmp r2, #0                           @ 0800893A
    bpl .Lmva_dc_current_offset_08008948 @ 0800893C  if r2 >= 0
    cmp r1, #0                           @ 0800893E
    bmi .Lmva_dc_current_offset_08008948 @ 08008940  if r1 < 0
    movw r0, #0x83e                      @ 08008942  = 2110
    movs r3, r0                          @ 08008946
.Lmva_dc_current_offset_08008948:   @ branch target from 0800893C, 08008940
    cmp r2, #0                           @ 08008948
    bmi .Lmva_dc_current_offset_08008956 @ 0800894A  if r2 < 0
    cmp r1, #0                           @ 0800894C
    bpl .Lmva_dc_current_offset_08008956 @ 0800894E  if r1 >= 0
    ldr r0, =0xFFFFF7AE                  @ 08008950  = -2130
    movs r3, r0                          @ 08008954
.Lmva_dc_current_offset_08008956:   @ branch target from 0800894A, 0800894E
    cmp r2, #0                           @ 08008956
    bpl .Lmva_dc_current_offset_08008964 @ 08008958  if r2 >= 0
    cmp r1, #0                           @ 0800895A
    bpl .Lmva_dc_current_offset_08008964 @ 0800895C  if r1 >= 0
    ldr r0, =0xFFFFF7A4                  @ 0800895E  = -2140
    movs r3, r0                          @ 08008962
.Lmva_dc_current_offset_08008964:   @ branch target from 08008884, 080088BA, 080088F4, 0800892A, 08008958, 0800895C
    b .Lmva_dc_current_offset_out        @ 08008964
.Lmva_dc_current_offset_08008966:   @ branch target from 0800886C
    ldr r0, =meter_range                 @ 08008966
    ldrb r0, [r0]                        @ 0800896A  r0 = meter_range (u8)
    cmp r0, #0                           @ 0800896C
    beq .Lmva_dc_current_offset_0800897C @ 0800896E  if meter_range == 0
    cmp r0, #2                           @ 08008970
    beq .Lmva_dc_current_offset_080089EC @ 08008972  if meter_range == 2
    blo .Lmva_dc_current_offset_080089B2 @ 08008974  if meter_range < (unsigned) 2
    cmp r0, #3                           @ 08008976
    beq .Lmva_dc_current_offset_08008A22 @ 08008978  if meter_range == 3
    b .Lmva_dc_current_offset_08008A5A   @ 0800897A
.Lmva_dc_current_offset_0800897C:   @ branch target from 0800896E
    @ mode 23 range 0: +130, +132, -71, -70
    cmp r2, #0                           @ 0800897C
    bmi .Lmva_dc_current_offset_08008988 @ 0800897E  if r2 < 0
    cmp r1, #0                           @ 08008980
    bmi .Lmva_dc_current_offset_08008988 @ 08008982  if r1 < 0
    movs r0, #0x82                       @ 08008984  = 130
    movs r3, r0                          @ 08008986
.Lmva_dc_current_offset_08008988:   @ branch target from 0800897E, 08008982
    cmp r2, #0                           @ 08008988
    bpl .Lmva_dc_current_offset_08008994 @ 0800898A  if r2 >= 0
    cmp r1, #0                           @ 0800898C
    bmi .Lmva_dc_current_offset_08008994 @ 0800898E  if r1 < 0
    movs r0, #0x84                       @ 08008990  = 132
    movs r3, r0                          @ 08008992
.Lmva_dc_current_offset_08008994:   @ branch target from 0800898A, 0800898E
    cmp r2, #0                           @ 08008994
    bmi .Lmva_dc_current_offset_080089A2 @ 08008996  if r2 < 0
    cmp r1, #0                           @ 08008998
    bpl .Lmva_dc_current_offset_080089A2 @ 0800899A  if r1 >= 0
    mvns r0, #0x46                       @ 0800899C
    movs r3, r0                          @ 080089A0
.Lmva_dc_current_offset_080089A2:   @ branch target from 08008996, 0800899A
    cmp r2, #0                           @ 080089A2
    bpl .Lmva_dc_current_offset_080089B0 @ 080089A4  if r2 >= 0
    cmp r1, #0                           @ 080089A6
    bpl .Lmva_dc_current_offset_080089B0 @ 080089A8  if r1 >= 0
    mvns r0, #0x45                       @ 080089AA
    movs r3, r0                          @ 080089AE
.Lmva_dc_current_offset_080089B0:   @ branch target from 080089A4, 080089A8
    b .Lmva_dc_current_offset_08008A5A   @ 080089B0
.Lmva_dc_current_offset_080089B2:   @ branch target from 08008974
    @ mode 23 range 1: +1583, +1605, -1548, -1529
    cmp r2, #0                           @ 080089B2
    bmi .Lmva_dc_current_offset_080089C0 @ 080089B4  if r2 < 0
    cmp r1, #0                           @ 080089B6
    bmi .Lmva_dc_current_offset_080089C0 @ 080089B8  if r1 < 0
    movw r0, #0x62f                      @ 080089BA  = 1583
    movs r3, r0                          @ 080089BE
.Lmva_dc_current_offset_080089C0:   @ branch target from 080089B4, 080089B8
    cmp r2, #0                           @ 080089C0
    bpl .Lmva_dc_current_offset_080089CE @ 080089C2  if r2 >= 0
    cmp r1, #0                           @ 080089C4
    bmi .Lmva_dc_current_offset_080089CE @ 080089C6  if r1 < 0
    movw r0, #0x645                      @ 080089C8  = 1605
    movs r3, r0                          @ 080089CC
.Lmva_dc_current_offset_080089CE:   @ branch target from 080089C2, 080089C6
    cmp r2, #0                           @ 080089CE
    bmi .Lmva_dc_current_offset_080089DC @ 080089D0  if r2 < 0
    cmp r1, #0                           @ 080089D2
    bpl .Lmva_dc_current_offset_080089DC @ 080089D4  if r1 >= 0
    ldr r0, =0xFFFFF9F4                  @ 080089D6  = -1548
    movs r3, r0                          @ 080089DA
.Lmva_dc_current_offset_080089DC:   @ branch target from 080089D0, 080089D4
    cmp r2, #0                           @ 080089DC
    bpl .Lmva_dc_current_offset_080089EA @ 080089DE  if r2 >= 0
    cmp r1, #0                           @ 080089E0
    bpl .Lmva_dc_current_offset_080089EA @ 080089E2  if r1 >= 0
    mvns r0, #0x5f8                      @ 080089E4
    movs r3, r0                          @ 080089E8
.Lmva_dc_current_offset_080089EA:   @ branch target from 080089DE, 080089E2
    b .Lmva_dc_current_offset_08008A5A   @ 080089EA
.Lmva_dc_current_offset_080089EC:   @ branch target from 08008972
    @ mode 23 range 2: +82, +83, -120, -120
    cmp r2, #0                           @ 080089EC
    bmi .Lmva_dc_current_offset_080089F8 @ 080089EE  if r2 < 0
    cmp r1, #0                           @ 080089F0
    bmi .Lmva_dc_current_offset_080089F8 @ 080089F2  if r1 < 0
    movs r0, #0x52                       @ 080089F4  = 82
    movs r3, r0                          @ 080089F6
.Lmva_dc_current_offset_080089F8:   @ branch target from 080089EE, 080089F2
    cmp r2, #0                           @ 080089F8
    bpl .Lmva_dc_current_offset_08008A04 @ 080089FA  if r2 >= 0
    cmp r1, #0                           @ 080089FC
    bmi .Lmva_dc_current_offset_08008A04 @ 080089FE  if r1 < 0
    movs r0, #0x53                       @ 08008A00  = 83
    movs r3, r0                          @ 08008A02
.Lmva_dc_current_offset_08008A04:   @ branch target from 080089FA, 080089FE
    cmp r2, #0                           @ 08008A04
    bmi .Lmva_dc_current_offset_08008A12 @ 08008A06  if r2 < 0
    cmp r1, #0                           @ 08008A08
    bpl .Lmva_dc_current_offset_08008A12 @ 08008A0A  if r1 >= 0
    mvns r0, #0x77                       @ 08008A0C
    movs r3, r0                          @ 08008A10
.Lmva_dc_current_offset_08008A12:   @ branch target from 08008A06, 08008A0A
    cmp r2, #0                           @ 08008A12
    bpl .Lmva_dc_current_offset_08008A20 @ 08008A14  if r2 >= 0
    cmp r1, #0                           @ 08008A16
    bpl .Lmva_dc_current_offset_08008A20 @ 08008A18  if r1 >= 0
    mvns r0, #0x77                       @ 08008A1A
    movs r3, r0                          @ 08008A1E
.Lmva_dc_current_offset_08008A20:   @ branch target from 08008A14, 08008A18
    b .Lmva_dc_current_offset_08008A5A   @ 08008A20
.Lmva_dc_current_offset_08008A22:   @ branch target from 08008978
    @ mode 23 range 3: +1537, +1566, -1606, -1578
    cmp r2, #0                           @ 08008A22
    bmi .Lmva_dc_current_offset_08008A30 @ 08008A24  if r2 < 0
    cmp r1, #0                           @ 08008A26
    bmi .Lmva_dc_current_offset_08008A30 @ 08008A28  if r1 < 0
    movw r0, #0x601                      @ 08008A2A  = 1537
    movs r3, r0                          @ 08008A2E
.Lmva_dc_current_offset_08008A30:   @ branch target from 08008A24, 08008A28
    cmp r2, #0                           @ 08008A30
    bpl .Lmva_dc_current_offset_08008A3E @ 08008A32  if r2 >= 0
    cmp r1, #0                           @ 08008A34
    bmi .Lmva_dc_current_offset_08008A3E @ 08008A36  if r1 < 0
    movw r0, #0x61e                      @ 08008A38  = 1566
    movs r3, r0                          @ 08008A3C
.Lmva_dc_current_offset_08008A3E:   @ branch target from 08008A32, 08008A36
    cmp r2, #0                           @ 08008A3E
    bmi .Lmva_dc_current_offset_08008A4C @ 08008A40  if r2 < 0
    cmp r1, #0                           @ 08008A42
    bpl .Lmva_dc_current_offset_08008A4C @ 08008A44  if r1 >= 0
    ldr r0, =0xFFFFF9BA                  @ 08008A46  = -1606
    movs r3, r0                          @ 08008A4A
.Lmva_dc_current_offset_08008A4C:   @ branch target from 08008A40, 08008A44
    cmp r2, #0                           @ 08008A4C
    bpl .Lmva_dc_current_offset_08008A5A @ 08008A4E  if r2 >= 0
    cmp r1, #0                           @ 08008A50
    bpl .Lmva_dc_current_offset_08008A5A @ 08008A52  if r1 >= 0
    ldr r0, =0xFFFFF9D6                  @ 08008A54  = -1578
    movs r3, r0                          @ 08008A58
.Lmva_dc_current_offset_08008A5A:   @ branch target from 0800897A, 080089B0, 080089EA, 08008A20, 08008A4E, 08008A52
    b .Lmva_dc_current_offset_out        @ 08008A5A
    .ltorg
.Lmva_dc_current_offset_08008A5C:   @ branch target from 08008868
    ldr r0, =meter_range                 @ 08008A5C
    ldrb r0, [r0]                        @ 08008A60  r0 = meter_range (u8)
    cmp r0, #0                           @ 08008A62
    beq .Lmva_dc_current_offset_08008A72 @ 08008A64  if meter_range == 0
    cmp r0, #2                           @ 08008A66
    beq .Lmva_dc_current_offset_08008AE2 @ 08008A68  if meter_range == 2
    blo .Lmva_dc_current_offset_08008AA8 @ 08008A6A  if meter_range < (unsigned) 2
    cmp r0, #3                           @ 08008A6C
    beq .Lmva_dc_current_offset_08008B18 @ 08008A6E  if meter_range == 3
    b .Lmva_dc_current_offset_out        @ 08008A70
.Lmva_dc_current_offset_08008A72:   @ branch target from 08008A64
    @ mode 24 range 0: +128, +131, -65, -65
    cmp r2, #0                           @ 08008A72
    bmi .Lmva_dc_current_offset_08008A7E @ 08008A74  if r2 < 0
    cmp r1, #0                           @ 08008A76
    bmi .Lmva_dc_current_offset_08008A7E @ 08008A78  if r1 < 0
    movs r0, #0x80                       @ 08008A7A  = 128
    movs r3, r0                          @ 08008A7C
.Lmva_dc_current_offset_08008A7E:   @ branch target from 08008A74, 08008A78
    cmp r2, #0                           @ 08008A7E
    bpl .Lmva_dc_current_offset_08008A8A @ 08008A80  if r2 >= 0
    cmp r1, #0                           @ 08008A82
    bmi .Lmva_dc_current_offset_08008A8A @ 08008A84  if r1 < 0
    movs r0, #0x83                       @ 08008A86  = 131
    movs r3, r0                          @ 08008A88
.Lmva_dc_current_offset_08008A8A:   @ branch target from 08008A80, 08008A84
    cmp r2, #0                           @ 08008A8A
    bmi .Lmva_dc_current_offset_08008A98 @ 08008A8C  if r2 < 0
    cmp r1, #0                           @ 08008A8E
    bpl .Lmva_dc_current_offset_08008A98 @ 08008A90  if r1 >= 0
    mvns r0, #0x40                       @ 08008A92
    movs r3, r0                          @ 08008A96
.Lmva_dc_current_offset_08008A98:   @ branch target from 08008A8C, 08008A90
    cmp r2, #0                           @ 08008A98
    bpl .Lmva_dc_current_offset_08008AA6 @ 08008A9A  if r2 >= 0
    cmp r1, #0                           @ 08008A9C
    bpl .Lmva_dc_current_offset_08008AA6 @ 08008A9E  if r1 >= 0
    mvns r0, #0x40                       @ 08008AA0
    movs r3, r0                          @ 08008AA4
.Lmva_dc_current_offset_08008AA6:   @ branch target from 08008A9A, 08008A9E
    b .Lmva_dc_current_offset_out        @ 08008AA6
.Lmva_dc_current_offset_08008AA8:   @ branch target from 08008A6A
    @ mode 24 range 1: +1559, +1581, -1517, -1499
    cmp r2, #0                           @ 08008AA8
    bmi .Lmva_dc_current_offset_08008AB6 @ 08008AAA  if r2 < 0
    cmp r1, #0                           @ 08008AAC
    bmi .Lmva_dc_current_offset_08008AB6 @ 08008AAE  if r1 < 0
    movw r0, #0x617                      @ 08008AB0  = 1559
    movs r3, r0                          @ 08008AB4
.Lmva_dc_current_offset_08008AB6:   @ branch target from 08008AAA, 08008AAE
    cmp r2, #0                           @ 08008AB6
    bpl .Lmva_dc_current_offset_08008AC4 @ 08008AB8  if r2 >= 0
    cmp r1, #0                           @ 08008ABA
    bmi .Lmva_dc_current_offset_08008AC4 @ 08008ABC  if r1 < 0
    movw r0, #0x62d                      @ 08008ABE  = 1581
    movs r3, r0                          @ 08008AC2
.Lmva_dc_current_offset_08008AC4:   @ branch target from 08008AB8, 08008ABC
    cmp r2, #0                           @ 08008AC4
    bmi .Lmva_dc_current_offset_08008AD2 @ 08008AC6  if r2 < 0
    cmp r1, #0                           @ 08008AC8
    bpl .Lmva_dc_current_offset_08008AD2 @ 08008ACA  if r1 >= 0
    ldr r0, =0xFFFFFA13                  @ 08008ACC  = -1517
    movs r3, r0                          @ 08008AD0
.Lmva_dc_current_offset_08008AD2:   @ branch target from 08008AC6, 08008ACA
    cmp r2, #0                           @ 08008AD2
    bpl .Lmva_dc_current_offset_08008AE0 @ 08008AD4  if r2 >= 0
    cmp r1, #0                           @ 08008AD6
    bpl .Lmva_dc_current_offset_08008AE0 @ 08008AD8  if r1 >= 0
    ldr r0, =0xFFFFFA25                  @ 08008ADA  = -1499
    movs r3, r0                          @ 08008ADE
.Lmva_dc_current_offset_08008AE0:   @ branch target from 08008AD4, 08008AD8
    b .Lmva_dc_current_offset_out        @ 08008AE0
.Lmva_dc_current_offset_08008AE2:   @ branch target from 08008A68
    @ mode 24 range 2: +5, +12, -16, -18
    cmp r2, #0                           @ 08008AE2
    bmi .Lmva_dc_current_offset_08008AEE @ 08008AE4  if r2 < 0
    cmp r1, #0                           @ 08008AE6
    bmi .Lmva_dc_current_offset_08008AEE @ 08008AE8  if r1 < 0
    movs r0, #5                          @ 08008AEA
    movs r3, r0                          @ 08008AEC
.Lmva_dc_current_offset_08008AEE:   @ branch target from 08008AE4, 08008AE8
    cmp r2, #0                           @ 08008AEE
    bpl .Lmva_dc_current_offset_08008AFA @ 08008AF0  if r2 >= 0
    cmp r1, #0                           @ 08008AF2
    bmi .Lmva_dc_current_offset_08008AFA @ 08008AF4  if r1 < 0
    movs r0, #0xc                        @ 08008AF6
    movs r3, r0                          @ 08008AF8
.Lmva_dc_current_offset_08008AFA:   @ branch target from 08008AF0, 08008AF4
    cmp r2, #0                           @ 08008AFA
    bmi .Lmva_dc_current_offset_08008B08 @ 08008AFC  if r2 < 0
    cmp r1, #0                           @ 08008AFE
    bpl .Lmva_dc_current_offset_08008B08 @ 08008B00  if r1 >= 0
    mvns r0, #0xf                        @ 08008B02
    movs r3, r0                          @ 08008B06
.Lmva_dc_current_offset_08008B08:   @ branch target from 08008AFC, 08008B00
    cmp r2, #0                           @ 08008B08
    bpl .Lmva_dc_current_offset_08008B16 @ 08008B0A  if r2 >= 0
    cmp r1, #0                           @ 08008B0C
    bpl .Lmva_dc_current_offset_08008B16 @ 08008B0E  if r1 >= 0
    mvns r0, #0x11                       @ 08008B10
    movs r3, r0                          @ 08008B14
.Lmva_dc_current_offset_08008B16:   @ branch target from 08008B0A, 08008B0E
    b .Lmva_dc_current_offset_out        @ 08008B16
.Lmva_dc_current_offset_08008B18:   @ branch target from 08008A6E
    @ mode 24 range 3: +156, +160, -161, -159
    cmp r2, #0                           @ 08008B18
    bmi .Lmva_dc_current_offset_08008B24 @ 08008B1A  if r2 < 0
    cmp r1, #0                           @ 08008B1C
    bmi .Lmva_dc_current_offset_08008B24 @ 08008B1E  if r1 < 0
    movs r0, #0x9c                       @ 08008B20  = 156
    movs r3, r0                          @ 08008B22
.Lmva_dc_current_offset_08008B24:   @ branch target from 08008B1A, 08008B1E
    cmp r2, #0                           @ 08008B24
    bpl .Lmva_dc_current_offset_08008B30 @ 08008B26  if r2 >= 0
    cmp r1, #0                           @ 08008B28
    bmi .Lmva_dc_current_offset_08008B30 @ 08008B2A  if r1 < 0
    movs r0, #0xa0                       @ 08008B2C  = 160
    movs r3, r0                          @ 08008B2E
.Lmva_dc_current_offset_08008B30:   @ branch target from 08008B26, 08008B2A
    cmp r2, #0                           @ 08008B30
    bmi .Lmva_dc_current_offset_08008B3E @ 08008B32  if r2 < 0
    cmp r1, #0                           @ 08008B34
    bpl .Lmva_dc_current_offset_08008B3E @ 08008B36  if r1 >= 0
    mvns r0, #0xa0                       @ 08008B38
    movs r3, r0                          @ 08008B3C
.Lmva_dc_current_offset_08008B3E:   @ branch target from 08008B32, 08008B36
    cmp r2, #0                           @ 08008B3E
    bpl .Lmva_dc_current_offset_out      @ 08008B40  if r2 >= 0
    cmp r1, #0                           @ 08008B42
    bpl .Lmva_dc_current_offset_out      @ 08008B44  if r1 >= 0
    mvns r0, #0x9e                       @ 08008B46
    movs r3, r0                          @ 08008B4A
.Lmva_dc_current_offset_out:   @ K in r3 -> r0
    movs r0, r3                          @ 08008B4C
.Lmva_dc_current_offset_exit:   @ return
    pop {r4}                             @ 08008B4E
    bx lr                                @ 08008B50
    .ltorg
ENDFUNC fn_080087F8
    .global mva_dc_current_offset
    .set mva_dc_current_offset, fn_080087F8

