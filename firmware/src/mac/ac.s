@ =============================================================================
@ ac.s - MAC module: AC measurement chains (ACV, ACmV, LowZ AC, AC currents, AC VA channels)
@
@ Every routine here is the v2.05 routine of the same address, instruction for instruction, with the
@ deviations of DESIGN.md section 10 that belong to MAC (OF-28 own smoothing states, IMP-01 precheck
@ flag).  The chain steps (AD1 mean -> offset -> gain -> filter/frequency correction -> smoothing ->
@ display flag) are specified in analysis/hy3131_modes_ac_current.md 4 and 7.  Calibration records come
@ from the RAM words loaded by CAL (cal_offset 0x20007E00, cal_gain 0x20007E10, AC words 0x20007E4C..);
@ nothing here writes the data EEPROM.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.mac, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800664A (mac_current_dispatch) - AD1 handler of the AC current modes 16, 18, 20: plain current chain, or the burden display
@   alternation (7 current means, then 7 burden-voltage means) when the burden display is on
@ Replaces : 0x0800664A FUN_0800664a (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (ad1_ready_dispatch 0x080062F2 for modes 16, 18, 20)
@ Registers: r4 = phase length (6)
@ RAM      : reads  0x20007D64 reading, 0x20007E6C burden_v, 0x20008037 setup_item, 0x2000805D new_reading,
@            0x2000805E bargraph_update, 0x20008081 mean_ready, 0x2000808A cal_mode, 0x200080A5 burden_on,
@            0x200080C4 va_channel, 0x200080C5 va_mean_count
@            writes 0x20007E6C burden_v, 0x2000805D new_reading, 0x2000805E bargraph_update, 0x20008062 sec_refresh,
@            0x200080A7 burden_over, 0x200080C4 va_channel, 0x200080C5 va_mean_count
@ Spec     : analysis/hy3131_modes_ac_current.md 7.5, 7.8
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800664A
    push {r4, lr}                        @ 0800664A
    @ r4 = phase length (set below)
    movs r4, #0                          @ 0800664C
    @ plain current chain unless calibration mode is off and the burden display is on:
    @ (cal_mode | (burden_on ^ 1)) != 0 -> fn_080067D6
    ldr r0, =v_2000808A                  @ 0800664E
    ldrb r0, [r0]                        @ 08006652  r0 = cal_mode (u8)
    ldr r1, =v_200080A5                  @ 08006654
    ldrb r1, [r1]                        @ 08006658  r1 = burden_on (u8)
    eors r1, r1, #1                      @ 0800665A  r1 = burden_on ^ 1
    orrs r0, r1                          @ 0800665E  r0 = cal_mode | (burden_on ^ 1)
    uxtb r0, r0                          @ 08006660
    cmp r0, #0                           @ 08006662
    beq .Lmac_current_dispatch_burden    @ 08006664  if r0 == 0
    bl fn_080067D6                       @ 08006666  MAC: AC current chain
    b .Lmac_current_dispatch_exit        @ 0800666A
.Lmac_current_dispatch_burden:   @ burden alternation: va_channel 0 = current phase, 1 = burden-voltage phase
    ldr r0, =va_channel                  @ 0800666C
    ldrb r0, [r0]                        @ 08006670  r0 = va_channel (u8)
    cmp r0, #0                           @ 08006672
    beq .Lmac_current_dispatch_cur_phase @ 08006674  if va_channel == 0
    bl fn_08006AEC                       @ 08006676  MAC: ACV chain
    ldr r0, =v_20008081                  @ 0800667A
    ldrb r0, [r0]                        @ 0800667E  r0 = mean_ready (u8)
    cmp r0, #0                           @ 08006680
    beq .Lmac_current_dispatch_after_chain @ 08006682  if mean_ready == 0
    ldr r0, =v_20007D64                  @ 08006684  burden voltage value of the 16-sample mean
    ldr r0, [r0]                         @ 08006688  r0 = reading (u32)
    ldr r1, =v_20007E6C                  @ 0800668A
    str r0, [r1]                         @ 0800668E  burden_v (u32) = reading
    b .Lmac_current_dispatch_after_chain @ 08006690
.Lmac_current_dispatch_cur_phase:   @ current phase: AC current chain
    bl fn_080067D6                       @ 08006692  MAC: AC current chain
.Lmac_current_dispatch_after_chain:   @ chain done: flags of the mean are examined
    @ a new mean was produced (new_reading set)?  Count it in the phase mean counter.
    ldr r0, =v_2000805D                  @ 08006696
    ldrb r0, [r0]                        @ 0800669A  r0 = new_reading (u8)
    cmp r0, #0                           @ 0800669C
    beq .Lmac_current_dispatch_exit      @ 0800669E  if new_reading == 0
    ldr r0, =va_channel                  @ 080066A0
    ldrb r0, [r0]                        @ 080066A4  r0 = va_channel (u8)
    cmp r0, #0                           @ 080066A6
    beq .Lmac_current_dispatch_len6      @ 080066A8  if va_channel == 0
    movs r0, #6                          @ 080066AA
    movs r4, r0                          @ 080066AC
    b .Lmac_current_dispatch_count       @ 080066AE
.Lmac_current_dispatch_len6:   @ phase length 6 (voltage phase)
    movs r0, #6                          @ 080066B0
    movs r4, r0                          @ 080066B2
.Lmac_current_dispatch_count:   @ increment the phase mean counter
    @ phase length 6 in both channels: the chain acts on the 7th mean (counter > 6)
    ldr r0, =v_200080C5                  @ 080066B4
    ldrb r0, [r0]                        @ 080066B8  r0 = va_mean_count (u8)
    adds r0, r0, #1                      @ 080066BA  r0 = va_mean_count + 1
    ldr r1, =v_200080C5                  @ 080066BC
    strb r0, [r1]                        @ 080066C0  va_mean_count (u8) = (va_mean_count + 1)
    movs r0, r4                          @ 080066C2
    ldr r1, =v_200080C5                  @ 080066C4
    ldrb r1, [r1]                        @ 080066C8  r1 = va_mean_count (u8)
    uxtb r0, r0                          @ 080066CA
    cmp r0, r1                           @ 080066CC
    blo .Lmac_current_dispatch_phase_end @ 080066CE  if r0 < (unsigned) va_mean_count
    movs r0, #0                          @ 080066D0
    ldr r1, =v_2000805E                  @ 080066D2
    strb r0, [r1]                        @ 080066D6  bargraph_update (u8) = 0
    ldr r0, =v_2000805E                  @ 080066D8
    ldrb r0, [r0]                        @ 080066DC  r0 = bargraph_update (u8)
    ldr r1, =v_2000805D                  @ 080066DE
    strb r0, [r1]                        @ 080066E2  new_reading (u8) = bargraph_update
    b .Lmac_current_dispatch_exit        @ 080066E4
.Lmac_current_dispatch_phase_end:   @ 7th mean of the phase reached
    ldr r0, =va_channel                  @ 080066E6
    ldrb r0, [r0]                        @ 080066EA  r0 = va_channel (u8)
    cmp r0, #0                           @ 080066EC
    beq .Lmac_current_dispatch_switch    @ 080066EE  if va_channel == 0
    ldr r0, =v_20007E6C                  @ 080066F0
    ldr r0, [r0]                         @ 080066F4  burden voltage of the phase, to the running mean of 3
    bl fn_0800B888                       @ 080066F6  FUNC: running mean of up to 3 values (restarts when a value differs by more than 10)
    ldr r1, =v_20007E6C                  @ 080066FA
    str r0, [r1]                         @ 080066FE  burden_v (u32) = r0
    movs r0, #0                          @ 08006700
    ldr r1, =v_200080A7                  @ 08006702
    strb r0, [r1]                        @ 08006706  burden_over (u8) = 0
    ldr r0, =v_20007E6C                  @ 08006708
    ldr r0, [r0]                         @ 0800670C  r0 = burden_v (u32)
    movw r1, #0x1389                     @ 0800670E  0x1389 = 5001: burden_over = (burden_v > 5000)
    cmp r0, r1                           @ 08006712
    blt .Lmac_current_dispatch_v_done    @ 08006714  if burden_v < (signed) 5001
    movs r0, #1                          @ 08006716
    ldr r1, =v_200080A7                  @ 08006718
    strb r0, [r1]                        @ 0800671C  burden_over (u8) = 1
.Lmac_current_dispatch_v_done:   @ burden-voltage phase finished: clear the display flags
    movs r0, #0                          @ 0800671E
    ldr r1, =v_2000805E                  @ 08006720
    strb r0, [r1]                        @ 08006724  bargraph_update (u8) = 0
    ldr r0, =v_2000805E                  @ 08006726
    ldrb r0, [r0]                        @ 0800672A  r0 = bargraph_update (u8)
    ldr r1, =v_2000805D                  @ 0800672C
    strb r0, [r1]                        @ 08006730  new_reading (u8) = bargraph_update
    ldr r0, =v_20008037                  @ 08006732
    ldrb r0, [r0]                        @ 08006736  r0 = setup_item (u8)
    cmp r0, #0xb                         @ 08006738
    bne .Lmac_current_dispatch_switch    @ 0800673A  if setup_item != 11
    movs r0, #1                          @ 0800673C
    ldr r1, =v_20008062                  @ 0800673E
    strb r0, [r1]                        @ 08006742  sec_refresh (u8) = 1
.Lmac_current_dispatch_switch:   @ switch to the other channel: counter = 0, va_channel ^= 1, re-apply its row and record
    movs r0, #0                          @ 08006744
    ldr r1, =v_200080C5                  @ 08006746
    strb r0, [r1]                        @ 0800674A  va_mean_count (u8) = 0
    ldr r0, =va_channel                  @ 0800674C
    ldrb r0, [r0]                        @ 08006750  r0 = va_channel (u8)
    eors r0, r0, #1                      @ 08006752  r0 = va_channel ^ 1
    ldr r1, =va_channel                  @ 08006756
    strb r0, [r1]                        @ 0800675A  va_channel (u8) = (va_channel ^ 1)
    ldr r0, =va_channel                  @ 0800675C
    ldrb r0, [r0]                        @ 08006760  r0 = va_channel (u8)
    cmp r0, #0                           @ 08006762
    beq .Lmac_current_dispatch_0800676A  @ 08006764  if va_channel == 0
    movs r0, #1                          @ 08006766
    b .Lmac_current_dispatch_0800676C    @ 08006768
.Lmac_current_dispatch_0800676A:   @ branch target from 08006764
    movs r0, #0                          @ 0800676A
.Lmac_current_dispatch_0800676C:   @ branch target from 08006768
    uxtb r0, r0                          @ 0800676C
    bl fn_08006774                       @ 0800676E  new channel: 0 = current -> argument 0, 1 = voltage -> argument 1
.Lmac_current_dispatch_exit:   @ return
    pop {r4, pc}                         @ 08006772
    .ltorg
ENDFUNC fn_0800664A
    .global mac_current_dispatch
    .set mac_current_dispatch, fn_0800664A

@ -----------------------------------------------------------------------------
@ fn_080067D6 (mac_ac_current) - AC current chain (ACuA, ACmA, ACA) and the AC VA current channel: mean -> user zero -> smoothing,
@   plus the per-sample value of the bargraph
@ Replaces : 0x080067D6 FUN_080067d6 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (ad1_ready_dispatch via fn_0800664A; fn_08008B8C for the AC VA current channel)
@ RAM      : reads  0x20007D64 reading, 0x20007D68 sample_value, 0x20007D74 sample_in, 0x20007DD4 ad1_mean,
@            0x20007E08 cal_zero_capture, 0x20007E0C user_zero, 0x20008037 setup_item, 0x2000803C meter_mode,
@            0x2000803D meter_range, 0x20008081 mean_ready, 0x2000808C cal_req_offset, 0x2000808E cal_req_gain
@            writes 0x20007D64 reading, 0x20007D68 sample_value, 0x20007E08 cal_zero_capture, 0x2000805D new_reading,
@            0x20008062 sec_refresh
@ Spec     : analysis/hy3131_modes_ac_current.md 4, 7.5, 12 (VA.4)
@ Deviation: OF-28 (own smoothing history for the VA current and the burden current), IMP-01 (production build: the per-sample value may already have been made by mac_sample_precheck)
@ -----------------------------------------------------------------------------
FUNC fn_080067D6
    push {r7, lr}                        @ 080067D6
    @ no complete 16-sample mean yet -> only the per-sample value
    ldr r0, =v_20008081                  @ 080067D8
    ldrb r0, [r0]                        @ 080067DC  r0 = mean_ready (u8)
    cmp r0, #0                           @ 080067DE
    beq .Lmac_ac_current_sample          @ 080067E0  if mean_ready == 0
    @ modes 13, 14, 15 (VA): current channel chain fn_0800699A, then join the smoothing step
    ldr r0, =meter_mode                  @ 080067E4
    ldrb r0, [r0]                        @ 080067E6  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 080067E8
    beq .Lmac_ac_current_080067FC        @ 080067EA  if meter_mode == 13
    ldr r0, =meter_mode                  @ 080067EC
    ldrb r0, [r0]                        @ 080067EE  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 080067F0
    beq .Lmac_ac_current_080067FC        @ 080067F2  if meter_mode == 14
    ldr r0, =meter_mode                  @ 080067F4
    ldrb r0, [r0]                        @ 080067F6  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 080067F8
    bne .Lmac_ac_current_08006802        @ 080067FA  if meter_mode != 15
.Lmac_ac_current_080067FC:   @ branch target from 080067EA, 080067F2
    bl fn_0800699A                       @ 080067FC  MAC: AC VA current channel
    b .Lmac_ac_current_smooth            @ 08006800
.Lmac_ac_current_08006802:   @ branch target from 080067FA
    @ calibration offset request (cal_req_offset): capture the offset, no display value
    ldr r0, =v_2000808C                  @ 08006802
    ldrb r0, [r0]                        @ 08006806  r0 = cal_req_offset (u8)
    cmp r0, #0                           @ 08006808
    beq .Lmac_ac_current_0800681E        @ 0800680A  if cal_req_offset == 0
    ldr r0, =v_20007DD4                  @ 0800680C
    ldr r0, [r0]                         @ 08006810  r0 = ad1_mean (u32)
    bl fn_0800F0AC                       @ 08006812  CAL: offset capture step (r0 = mean), returns the captured value
    ldr r1, =v_20007E08                  @ 08006816
    str r0, [r1]                         @ 0800681A  cal_zero_capture (u32) = r0
    b .Lmac_ac_current_zero              @ 0800681C
.Lmac_ac_current_0800681E:   @ branch target from 0800680A
    @ calibration gain request (cal_req_gain), not in VA modes: complete the gain step with the captured offset
    ldr r0, =v_2000808E                  @ 0800681E
    ldrb r0, [r0]                        @ 08006822  r0 = cal_req_gain (u8)
    cmp r0, #0                           @ 08006824
    beq .Lmac_ac_current_08006852        @ 08006826  if cal_req_gain == 0
    ldr r0, =meter_mode                  @ 08006828
    ldrb r0, [r0]                        @ 0800682A  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 0800682C
    beq .Lmac_ac_current_08006852        @ 0800682E  if meter_mode == 13
    ldr r0, =meter_mode                  @ 08006830
    ldrb r0, [r0]                        @ 08006832  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 08006834
    beq .Lmac_ac_current_08006852        @ 08006836  if meter_mode == 14
    ldr r0, =meter_mode                  @ 08006838
    ldrb r0, [r0]                        @ 0800683A  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 0800683C
    beq .Lmac_ac_current_08006852        @ 0800683E  if meter_mode == 15
    ldr r0, =v_20007E08                  @ 08006840
    ldr r1, [r0]                         @ 08006844  r1 = cal_zero_capture (u32)
    ldr r0, =v_20007DD4                  @ 08006846
    ldr r0, [r0]                         @ 0800684A  r0 = ad1_mean (u32)
    bl fn_0800F7B8                       @ 0800684C  CAL: gain completion step (r0 = mean, r1 = captured offset)
    b .Lmac_ac_current_zero              @ 08006850
.Lmac_ac_current_08006852:   @ branch target from 08006826, 0800682E, 08006836, 0800683E
    @ normal chain: x = mean - offset (clamped), D = x / gain, frequency correction
    ldr r0, =v_20007DD4                  @ 08006852
    ldr r0, [r0]                         @ 08006856  r0 = ad1_mean (u32)
    bl cal_subtract_offset_clamp         @ 08006858  MDC: r0 = mean - offset, 0 if the result is below 1
    ldr r1, =v_20007D64                  @ 0800685C
    str r0, [r1]                         @ 08006860  reading (u32) = r0
    ldr r0, =v_20007D64                  @ 08006862
    ldr r0, [r0]                         @ 08006866  r0 = reading (u32)
    cmp r0, #0                           @ 08006868
    bpl .Lmac_ac_current_08006874        @ 0800686A  if reading >= 0
    movs r0, #0                          @ 0800686C
    ldr r1, =v_20007D64                  @ 0800686E
    str r0, [r1]                         @ 08006872  reading (u32) = 0
.Lmac_ac_current_08006874:   @ branch target from 0800686A
    ldr r0, =v_20007D64                  @ 08006874
    ldr r0, [r0]                         @ 08006878  r0 = reading (u32)
    bl cal_divide_by_gain                @ 0800687A  MDC: r0 = (int)((float)r0 / gain + 0.5), gain from the active record
    ldr r1, =v_20007D64                  @ 0800687E
    str r0, [r1]                         @ 08006882  reading (u32) = r0
    ldr r0, =v_20007D64                  @ 08006884
    ldr r1, [r0]                         @ 08006888  r1 = reading (u32)
    ldr r0, =meter_mode                  @ 0800688A
    ldrb r0, [r0]                        @ 0800688C  r0 = meter_mode (u8)
    bl fn_0800742C                       @ 0800688E  MAC: AC frequency correction (r0 = mode, r1 = value)
    ldr r1, =v_20007D64                  @ 08006892
    str r0, [r1]                         @ 08006896  reading (u32) = r0
.Lmac_ac_current_zero:   @ range 0 user-zero subtraction
    @ range 0 only: subtract the user zero (EEPROM 0x4D0..0x4FF record, RAM user_zero), clamp at 0
    ldr r0, =meter_range                 @ 08006898
    ldrb r0, [r0]                        @ 0800689C  r0 = meter_range (u8)
    cmp r0, #0                           @ 0800689E
    bne .Lmac_ac_current_smooth          @ 080068A0  if meter_range != 0
    ldr r0, =v_20007D64                  @ 080068A2
    ldr r0, [r0]                         @ 080068A6  r0 = reading (u32)
    ldr r1, =v_20007E0C                  @ 080068A8
    ldr r1, [r1]                         @ 080068AC  r1 = user_zero (u32)
    subs r0, r0, r1                      @ 080068AE  D = D - user_zero
    ldr r1, =v_20007D64                  @ 080068B0
    str r0, [r1]                         @ 080068B4  reading (u32) = (reading - user_zero)
    ldr r0, =v_20007D64                  @ 080068B6
    ldr r0, [r0]                         @ 080068BA  r0 = reading (u32)
    cmp r0, #0                           @ 080068BC
    bpl .Lmac_ac_current_smooth          @ 080068BE  if reading >= 0
    movs r0, #0                          @ 080068C0
    ldr r1, =v_20007D64                  @ 080068C2
    str r0, [r1]                         @ 080068C6  reading (u32) = 0
.Lmac_ac_current_smooth:   @ smoothing step (also reached from the VA current channel)
    @ smoothing of the current: thr 20, depth 10
    movs r2, #0xa                        @ 080068C8
    movs r1, #0x14                       @ 080068CA  = 20
    ldr r0, =v_20007D64                  @ 080068CC
    ldr r0, [r0]                         @ 080068D0  r0 = reading (u32)
    @ ---- v2.05 0x080068D2 replaced (see Deviation in the header) ----
    @ OF-28: three quantities pass through this call site; each gets its own history.
    @ r0 = D, r1 = 20 (threshold), r2 = 10 (depth) are set by the preceding instructions.
    ldr r3, =meter_mode
    ldrb r3, [r3]
    subs r3, r3, #13                        @ 13, 14, 15 -> 0, 1, 2
    cmp r3, #2
    bhi 1f                                  @ not a VA mode (also below 13: unsigned wrap)
    ldr r3, =func_st_va_curr_ac                @ AC VA current channel
    bl func_smooth_avg
    b 3f
1:  ldr r3, =v_200080A5
    ldrb r3, [r3]
    cbz r3, 2f                              @ burden display off: the plain current
    ldr r3, =func_st_burden_curr_ac            @ burden display: the current phase
    bl func_smooth_avg
    b 3f
2:  bl fn_08008344                          @ ACuA/ACmA/ACA: v2.05 history, shared with no concurrent quantity
3:
    ldr r1, =v_20007D64                  @ 080068D6
    str r0, [r1]                         @ 080068DA  reading (u32) = r0
    bl fn_08007532                       @ 080068DC  CAL: AC-band calibration word capture (acts only in calibration mode)
    @ modes 16, 18, 20 at range 0: readings below 31 counts are shown as 0
    ldr r0, =meter_mode                  @ 080068E0
    ldrb r0, [r0]                        @ 080068E2  r0 = meter_mode (u8)
    cmp r0, #0x10                        @ 080068E4
    beq .Lmac_ac_current_080068F8        @ 080068E6  if meter_mode == 16
    ldr r0, =meter_mode                  @ 080068E8
    ldrb r0, [r0]                        @ 080068EA  r0 = meter_mode (u8)
    cmp r0, #0x12                        @ 080068EC
    beq .Lmac_ac_current_080068F8        @ 080068EE  if meter_mode == 18
    ldr r0, =meter_mode                  @ 080068F0
    ldrb r0, [r0]                        @ 080068F2  r0 = meter_mode (u8)
    cmp r0, #0x14                        @ 080068F4
    bne .Lmac_ac_current_done            @ 080068F6  if meter_mode != 20
.Lmac_ac_current_080068F8:   @ branch target from 080068E6, 080068EE
    ldr r0, =meter_range                 @ 080068F8
    ldrb r0, [r0]                        @ 080068FC  r0 = meter_range (u8)
    cmp r0, #0                           @ 080068FE
    bne .Lmac_ac_current_done            @ 08006900  if meter_range != 0
    ldr r0, =v_20007D64                  @ 08006902
    ldr r0, [r0]                         @ 08006906  r0 = reading (u32)
    cmp r0, #0x1f                        @ 08006908  cmp D, 31
    bge .Lmac_ac_current_done            @ 0800690A  if reading >= (signed) 31
    movs r0, #0                          @ 0800690C
    ldr r1, =v_20007D64                  @ 0800690E
    str r0, [r1]                         @ 08006912  reading (u32) = 0
.Lmac_ac_current_done:   @ mean processed: publish
    @ a new reading is available
    movs r0, #1                          @ 08006914
    ldr r1, =v_2000805D                  @ 08006916
    strb r0, [r1]                        @ 0800691A  new_reading (u8) = 1
    bl fn_08006C7A                       @ 0800691C  MAC: forced frequency expiry for small readings
.Lmac_ac_current_sample:   @ per-sample part
    @ per-sample value (bargraph, log): not in VA modes
    ldr r1, =mac_ps_done                    @ IMP-01: the per-sample value was made by mac_sample_precheck
    ldrb r0, [r1]
    cbz r0, 1f
    movs r0, #0
    strb r0, [r1]                           @ consumed
    b .Lmac_ac_current_page                 @ skip the second computation
1:
    ldr r0, =meter_mode                  @ 08006920
    ldrb r0, [r0]                        @ 08006922  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 08006924
    beq .Lmac_ac_current_page            @ 08006926  if meter_mode == 13
    ldr r0, =meter_mode                  @ 08006928
    ldrb r0, [r0]                        @ 0800692A  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 0800692C
    beq .Lmac_ac_current_page            @ 0800692E  if meter_mode == 14
    ldr r0, =meter_mode                  @ 08006930
    ldrb r0, [r0]                        @ 08006932  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08006934
    beq .Lmac_ac_current_page            @ 08006936  if meter_mode == 15
    ldr r0, =v_20007D74                  @ 08006938
    ldr r0, [r0]                         @ 0800693C  r0 = sample_in (u32)
    bl fn_08008468                       @ 0800693E  MAC: per-sample value from the latest sample (r0)
    ldr r0, =v_20007D68                  @ 08006942
    ldr r1, [r0]                         @ 08006946  r1 = sample_value (u32)
    ldr r0, =meter_mode                  @ 08006948
    ldrb r0, [r0]                        @ 0800694A  r0 = meter_mode (u8)
    bl fn_0800742C                       @ 0800694C  MAC: AC frequency correction (r0 = mode, r1 = value)
    ldr r1, =v_20007D68                  @ 08006950
    str r0, [r1]                         @ 08006954  sample_value (u32) = r0
.Lmac_ac_current_page:   @ secondary-display refresh for the current modes in setup page 10
    ldr r0, =meter_mode                  @ 08006956
    ldrb r0, [r0]                        @ 08006958  r0 = meter_mode (u8)
    cmp r0, #0x10                        @ 0800695A
    beq .Lmac_ac_current_08006986        @ 0800695C  if meter_mode == 16
    ldr r0, =meter_mode                  @ 0800695E
    ldrb r0, [r0]                        @ 08006960  r0 = meter_mode (u8)
    cmp r0, #0x12                        @ 08006962
    beq .Lmac_ac_current_08006986        @ 08006964  if meter_mode == 18
    ldr r0, =meter_mode                  @ 08006966
    ldrb r0, [r0]                        @ 08006968  r0 = meter_mode (u8)
    cmp r0, #0x14                        @ 0800696A
    beq .Lmac_ac_current_08006986        @ 0800696C  if meter_mode == 20
    ldr r0, =meter_mode                  @ 0800696E
    ldrb r0, [r0]                        @ 08006970  r0 = meter_mode (u8)
    cmp r0, #0x11                        @ 08006972
    beq .Lmac_ac_current_08006986        @ 08006974  if meter_mode == 17
    ldr r0, =meter_mode                  @ 08006976
    ldrb r0, [r0]                        @ 08006978  r0 = meter_mode (u8)
    cmp r0, #0x13                        @ 0800697A
    beq .Lmac_ac_current_08006986        @ 0800697C  if meter_mode == 19
    ldr r0, =meter_mode                  @ 0800697E
    ldrb r0, [r0]                        @ 08006980  r0 = meter_mode (u8)
    cmp r0, #0x15                        @ 08006982
    bne .Lmac_ac_current_exit            @ 08006984  if meter_mode != 21
.Lmac_ac_current_08006986:   @ branch target from 0800695C, 08006964, 0800696C, 08006974, 0800697C
    ldr r0, =v_20008037                  @ 08006986
    ldrb r0, [r0]                        @ 0800698A  r0 = setup_item (u8)
    cmp r0, #0xa                         @ 0800698C
    bne .Lmac_ac_current_exit            @ 0800698E  if setup_item != 10
    movs r0, #1                          @ 08006990
    ldr r1, =v_20008062                  @ 08006992
    strb r0, [r1]                        @ 08006996  sec_refresh (u8) = 1
.Lmac_ac_current_exit:   @ return
    pop {r0, pc}                         @ 08006998
    .ltorg
ENDFUNC fn_080067D6
    .global mac_ac_current
    .set mac_ac_current, fn_080067D6

@ -----------------------------------------------------------------------------
@ fn_0800699A (mac_va_current_ac) - AC VA current channel (modes 13, 14, 15): current count of the 16-sample mean, clamped at 0
@ Replaces : 0x0800699A FUN_0800699a (v2.05)
@ In       : -
@ Out      : reading (0x20007D64) = max(0, (mean - offset_I) / gain_I); smoothing follows in fn_080067D6
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080067D6)
@ RAM      : reads  0x20007D64 reading
@            writes 0x20007D64 reading
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.4)
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800699A
    push {r7, lr}                        @ 0800699A
    bl fn_08006418                       @ 0800699C  MDC: reading = (mean - offset) / gain of the active VA channel
    ldr r0, =v_20007D64                  @ 080069A0
    ldr r0, [r0]                         @ 080069A4  r0 = reading (u32)
    cmp r0, #0                           @ 080069A6
    bpl .Lmac_va_current_ac_080069B2     @ 080069A8  if reading >= 0
    movs r0, #0                          @ 080069AA
    ldr r1, =v_20007D64                  @ 080069AC
    str r0, [r1]                         @ 080069B0  reading (u32) = 0
.Lmac_va_current_ac_080069B2:   @ branch target from 080069A8
    pop {r0, pc}                         @ 080069B2
    .ltorg
ENDFUNC fn_0800699A
    .global mac_va_current_ac
    .set mac_va_current_ac, fn_0800699A

@ -----------------------------------------------------------------------------
@ fn_080069B4 (mac_acmv) - ACmV chain (mode 4): AD1 mean -> offset -> gain -> 1 kHz filter correction -> frequency correction ->
@   smoothing, and the per-sample value
@ Replaces : 0x080069B4 FUN_080069b4 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (ad1_ready_dispatch 0x0800629E)
@ RAM      : reads  0x20007D64 reading, 0x20007D68 sample_value, 0x20007D74 sample_in, 0x20007DD4 ad1_mean,
@            0x20007E08 cal_zero_capture, 0x2000803C meter_mode, 0x20008081 mean_ready, 0x2000808C cal_req_offset,
@            0x2000808E cal_req_gain, 0x200080B7 peak_hold
@            writes 0x20007D64 reading, 0x20007D68 sample_value, 0x20007E08 cal_zero_capture, 0x2000805D new_reading
@ Spec     : analysis/hy3131_modes_ac_current.md 4, 7.2
@ Deviation: IMP-01 (production build: the per-sample value may already have been made by mac_sample_precheck);
@            OF-44 (both builds: the per-sample value gets the 1 kHz filter correction, which v2.05 applies to the mean only)
@ -----------------------------------------------------------------------------
FUNC fn_080069B4
    push {r7, lr}                        @ 080069B4
    @ no complete mean yet, or PEAK on (the peak routine delivers the reading): per-sample part only
    ldr r0, =v_20008081                  @ 080069B6
    ldrb r0, [r0]                        @ 080069BA  r0 = mean_ready (u8)
    cmp r0, #0                           @ 080069BC
    beq .Lmac_acmv_sample                @ 080069BE  if mean_ready == 0
    ldr r0, =peak_hold                   @ 080069C0
    ldrb r0, [r0]                        @ 080069C4  r0 = peak_hold (u8)
    cmp r0, #0                           @ 080069C6
    bne .Lmac_acmv_sample                @ 080069C8  if peak_hold != 0
    @ VA modes: AC VA voltage channel (unreachable for mode 4, kept as v2.05)
    ldr r0, =meter_mode                  @ 080069CA
    ldrb r0, [r0]                        @ 080069CE  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 080069D0
    beq .Lmac_acmv_080069E8              @ 080069D2  if meter_mode == 13
    ldr r0, =meter_mode                  @ 080069D4
    ldrb r0, [r0]                        @ 080069D8  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 080069DA
    beq .Lmac_acmv_080069E8              @ 080069DC  if meter_mode == 14
    ldr r0, =meter_mode                  @ 080069DE
    ldrb r0, [r0]                        @ 080069E2  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 080069E4
    bne .Lmac_acmv_080069EE              @ 080069E6  if meter_mode != 15
.Lmac_acmv_080069E8:   @ branch target from 080069D2, 080069DC
    bl fn_08006A9E                       @ 080069E8  MAC: AC VA voltage channel
    b .Lmac_acmv_sample                  @ 080069EC
.Lmac_acmv_080069EE:   @ branch target from 080069E6
    @ calibration offset request: capture the offset
    ldr r0, =v_2000808C                  @ 080069EE
    ldrb r0, [r0]                        @ 080069F2  r0 = cal_req_offset (u8)
    cmp r0, #0                           @ 080069F4
    beq .Lmac_acmv_08006A0A              @ 080069F6  if cal_req_offset == 0
    ldr r0, =v_20007DD4                  @ 080069F8
    ldr r0, [r0]                         @ 080069FC  r0 = ad1_mean (u32)
    bl fn_0800F0AC                       @ 080069FE  CAL: offset capture step (r0 = mean), returns the captured value
    ldr r1, =v_20007E08                  @ 08006A02
    str r0, [r1]                         @ 08006A06  cal_zero_capture (u32) = r0
    b .Lmac_acmv_sample                  @ 08006A08
.Lmac_acmv_08006A0A:   @ branch target from 080069F6
    @ calibration gain request: complete the gain step
    ldr r0, =v_2000808E                  @ 08006A0A
    ldrb r0, [r0]                        @ 08006A0E  r0 = cal_req_gain (u8)
    cmp r0, #0                           @ 08006A10
    beq .Lmac_acmv_08006A26              @ 08006A12  if cal_req_gain == 0
    ldr r0, =v_20007E08                  @ 08006A14
    ldr r1, [r0]                         @ 08006A18  r1 = cal_zero_capture (u32)
    ldr r0, =v_20007DD4                  @ 08006A1A
    ldr r0, [r0]                         @ 08006A1E  r0 = ad1_mean (u32)
    bl fn_0800F7B8                       @ 08006A20  CAL: gain completion step (r0 = mean, r1 = captured offset)
    b .Lmac_acmv_sample                  @ 08006A24
.Lmac_acmv_08006A26:   @ branch target from 08006A12
    @ normal chain
    ldr r0, =v_20007DD4                  @ 08006A26
    ldr r0, [r0]                         @ 08006A28  r0 = ad1_mean (u32)
    bl cal_subtract_offset_clamp         @ 08006A2A  MDC: r0 = mean - offset, 0 if the result is below 1
    ldr r1, =v_20007D64                  @ 08006A2E
    str r0, [r1]                         @ 08006A30  reading (u32) = r0
    ldr r0, =v_20007D64                  @ 08006A32
    ldr r0, [r0]                         @ 08006A34  r0 = reading (u32)
    cmp r0, #0                           @ 08006A36
    bpl .Lmac_acmv_08006A40              @ 08006A38  if reading >= 0
    movs r0, #0                          @ 08006A3A
    ldr r1, =v_20007D64                  @ 08006A3C
    str r0, [r1]                         @ 08006A3E  reading (u32) = 0
.Lmac_acmv_08006A40:   @ branch target from 08006A38
    ldr r0, =v_20007D64                  @ 08006A40
    ldr r0, [r0]                         @ 08006A42  r0 = reading (u32)
    bl cal_divide_by_gain                @ 08006A44  MDC: r0 = (int)((float)r0 / gain + 0.5), gain from the active record
    ldr r1, =v_20007D64                  @ 08006A48
    str r0, [r1]                         @ 08006A4A  reading (u32) = r0
    ldr r0, =v_20007D64                  @ 08006A4C
    ldr r0, [r0]                         @ 08006A4E  r0 = reading (u32)
    bl fn_08006D40                       @ 08006A50  MAC: 1 kHz filter correction
    ldr r1, =v_20007D64                  @ 08006A54
    str r0, [r1]                         @ 08006A56  reading (u32) = r0
    ldr r0, =v_20007D64                  @ 08006A58
    ldr r1, [r0]                         @ 08006A5A  r1 = reading (u32)
    ldr r0, =meter_mode                  @ 08006A5C
    ldrb r0, [r0]                        @ 08006A5E  r0 = meter_mode (u8)
    bl fn_0800742C                       @ 08006A60  MAC: AC frequency correction (r0 = mode, r1 = value)
    ldr r1, =v_20007D64                  @ 08006A64
    str r0, [r1]                         @ 08006A66  reading (u32) = r0
    movs r2, #0xa                        @ 08006A68
    movs r1, #0x14                       @ 08006A6A  = 20
    ldr r0, =v_20007D64                  @ 08006A6C
    ldr r0, [r0]                         @ 08006A6E  r0 = reading (u32)
    bl fn_08008344                       @ 08006A70  FUNC: smoothing history, v2.05 shared state (r0 = value, r1 = threshold, r2 = depth)
    ldr r1, =v_20007D64                  @ 08006A74
    str r0, [r1]                         @ 08006A76  reading (u32) = r0
    bl fn_08007532                       @ 08006A78  CAL: AC-band calibration word capture (acts only in calibration mode)
    movs r0, #1                          @ 08006A7C
    ldr r1, =v_2000805D                  @ 08006A7E
    strb r0, [r1]                        @ 08006A82  new_reading (u8) = 1
.Lmac_acmv_sample:   @ per-sample part
    @ per-sample value from the latest sample: gain and frequency correction, then (OF-44) the 1 kHz filter correction
    ldr r1, =mac_ps_done                    @ IMP-01: the per-sample value was made by mac_sample_precheck
    ldrb r0, [r1]
    cbz r0, 1f
    movs r0, #0
    strb r0, [r1]                           @ consumed
    b 9f                                    @ skip the second computation
1:
    ldr r0, =v_20007D74                  @ 08006A84
    ldr r0, [r0]                         @ 08006A86  r0 = sample_in (u32)
    bl fn_08008468                       @ 08006A88  MAC: per-sample value from the latest sample (r0)
    ldr r0, =v_20007D68                  @ 08006A8C
    ldr r1, [r0]                         @ 08006A8E  r1 = sample_value (u32)
    ldr r0, =meter_mode                  @ 08006A90
    ldrb r0, [r0]                        @ 08006A92  r0 = meter_mode (u8)
    bl fn_0800742C                       @ 08006A94  MAC: AC frequency correction (r0 = mode, r1 = value)
    ldr r1, =v_20007D68                  @ 08006A98
    str r0, [r1]                         @ 08006A9A  sample_value (u32) = r0
    @ OF-44: 1 kHz filter correction of the x10-scaled per-sample value, as the ACV handler does at 0x08006C50..0x08006C76
    @ (v2.05 has no such block here: the bargraph and the log record followed the unfiltered sample).  The handler runs in
    @ mode 4 only (ad1_ready_dispatch 0x0800629E), so the mode test of the ACV block is not repeated.
    ldr r0, =filter_1khz
    ldrb r0, [r0]
    cmp r0, #1
    bne 9f                               @ filter off: sample_value stays as it is
    ldr r0, =v_20007D68
    ldr r0, [r0]                         @ r0 = sample_value
    movs r1, #0xa
    muls r0, r1, r0                      @ ten times the value (fn_08008468 divided by ten)
    bl fn_08006D40                       @ MAC: 1 kHz filter correction
    ldr r1, =v_20007D68
    str r0, [r1]                         @ sample_value (u32) = r0
9:
    pop {r0, pc}                         @ 08006A9C
    .ltorg
ENDFUNC fn_080069B4
    .global mac_acmv
    .set mac_acmv, fn_080069B4

@ -----------------------------------------------------------------------------
@ fn_08006A9E (mac_va_voltage_ac) - AC VA voltage channel (modes 13, 14, 15): voltage count of the 16-sample mean, clamped at 0,
@   smoothed, then finished by fn_080076BC
@ Replaces : 0x08006A9E FUN_08006a9e (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_08006AEC, fn_080069B4)
@ RAM      : reads  0x20007D64 reading
@            writes 0x20007D64 reading
@ Spec     : analysis/hy3131_modes_ac_current.md 12 (VA.4)
@ Deviation: OF-28 (own smoothing history for the VA voltage)
@ -----------------------------------------------------------------------------
FUNC fn_08006A9E
    push {r7, lr}                        @ 08006A9E
    bl fn_08006418                       @ 08006AA0  MDC: reading = (mean - offset) / gain of the active VA channel
    ldr r0, =v_20007D64                  @ 08006AA4
    ldr r0, [r0]                         @ 08006AA6  r0 = reading (u32)
    cmp r0, #0                           @ 08006AA8
    bpl .Lmac_va_voltage_ac_08006AB2     @ 08006AAA  if reading >= 0
    movs r0, #0                          @ 08006AAC
    ldr r1, =v_20007D64                  @ 08006AAE
    str r0, [r1]                         @ 08006AB0  reading (u32) = 0
.Lmac_va_voltage_ac_08006AB2:   @ branch target from 08006AAA
    movs r2, #0xa                        @ 08006AB2
    movs r1, #0x14                       @ 08006AB4  = 20
    ldr r0, =v_20007D64                  @ 08006AB6
    ldr r0, [r0]                         @ 08006AB8  r0 = reading (u32)
    @ ---- v2.05 0x08006ABA replaced (see Deviation in the header) ----
    ldr r3, =func_st_va_volt_ac                @ OF-28: VA voltage has its own history (r0 = D, r1 = 20, r2 = 10)
    bl func_smooth_avg
    ldr r1, =v_20007D64                  @ 08006ABE
    str r0, [r1]                         @ 08006AC0  reading (u32) = r0
    bl fn_080076BC                       @ 08006AC2  MAC: finish an AC value (new_reading, dBm)
    pop {r0, pc}                         @ 08006AC6
    .ltorg
ENDFUNC fn_08006A9E
    .global mac_va_voltage_ac
    .set mac_va_voltage_ac, fn_08006A9E

@ -----------------------------------------------------------------------------
@ fn_08006AEC (mac_acv) - ACV chain (mode 2, LowZ AC mode 0, burden-voltage phase of the AC current modes): AD1 mean -> offset ->
@   gain -> 1 kHz filter correction -> frequency correction -> smoothing, and the per-sample value
@ Replaces : 0x08006AEC FUN_08006aec (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (ad1_ready_dispatch 0x080062C2, fn_08006558, fn_0800664A, fn_08008B8C)
@ RAM      : reads  0x20000239 lowz_countdown, 0x20007D64 reading, 0x20007D68 sample_value, 0x20007D74 sample_in,
@            0x20007DD4 ad1_mean, 0x20007E08 cal_zero_capture, 0x2000803C meter_mode, 0x20008081 mean_ready,
@            0x2000808C cal_req_offset, 0x2000808E cal_req_gain, 0x200080B7 peak_hold, 0x200080B9 filter_1khz,
@            0x200080BA acdc_active
@            writes 0x20007D64 reading, 0x20007D68 sample_value, 0x20007E08 cal_zero_capture
@ Spec     : analysis/hy3131_modes_ac_current.md 4, 7.1, 7.3, 7.8
@ Deviation: OF-28 (own smoothing history for the burden voltage), IMP-01 (production build: the per-sample value may already have been made by mac_sample_precheck)
@ -----------------------------------------------------------------------------
FUNC fn_08006AEC
    push {r7, lr}                        @ 08006AEC
    @ no complete mean yet, or PEAK on (the peak routine delivers the reading): per-sample part only
    ldr r0, =v_20008081                  @ 08006AEE
    ldrb r0, [r0]                        @ 08006AF0  r0 = mean_ready (u8)
    cmp r0, #0                           @ 08006AF2
    beq .Lmac_acv_sample                 @ 08006AF4  if mean_ready == 0
    ldr r0, =peak_hold                   @ 08006AF6
    ldrb r0, [r0]                        @ 08006AFA  r0 = peak_hold (u8)
    cmp r0, #0                           @ 08006AFC
    bne .Lmac_acv_sample                 @ 08006AFE  if peak_hold != 0
    @ VA modes: AC VA voltage channel
    ldr r0, =meter_mode                  @ 08006B00
    ldrb r0, [r0]                        @ 08006B02  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 08006B04
    beq .Lmac_acv_08006B18               @ 08006B06  if meter_mode == 13
    ldr r0, =meter_mode                  @ 08006B08
    ldrb r0, [r0]                        @ 08006B0A  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 08006B0C
    beq .Lmac_acv_08006B18               @ 08006B0E  if meter_mode == 14
    ldr r0, =meter_mode                  @ 08006B10
    ldrb r0, [r0]                        @ 08006B12  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08006B14
    bne .Lmac_acv_08006B1E               @ 08006B16  if meter_mode != 15
.Lmac_acv_08006B18:   @ branch target from 08006B06, 08006B0E
    bl fn_08006A9E                       @ 08006B18  MAC: AC VA voltage channel
    b .Lmac_acv_expiry                   @ 08006B1C
.Lmac_acv_08006B1E:   @ branch target from 08006B16
    @ calibration offset request: capture the offset
    ldr r0, =v_2000808C                  @ 08006B1E
    ldrb r0, [r0]                        @ 08006B20  r0 = cal_req_offset (u8)
    cmp r0, #0                           @ 08006B22
    beq .Lmac_acv_08006B36               @ 08006B24  if cal_req_offset == 0
    ldr r0, =v_20007DD4                  @ 08006B26
    ldr r0, [r0]                         @ 08006B28  r0 = ad1_mean (u32)
    bl fn_0800F0AC                       @ 08006B2A  CAL: offset capture step (r0 = mean), returns the captured value
    ldr r1, =v_20007E08                  @ 08006B2E
    str r0, [r1]                         @ 08006B32  cal_zero_capture (u32) = r0
    b .Lmac_acv_expiry                   @ 08006B34
.Lmac_acv_08006B36:   @ branch target from 08006B24
    @ calibration gain request, not in VA modes: complete the gain step
    ldr r0, =v_2000808E                  @ 08006B36
    ldrb r0, [r0]                        @ 08006B38  r0 = cal_req_gain (u8)
    cmp r0, #0                           @ 08006B3A
    beq .Lmac_acv_08006B66               @ 08006B3C  if cal_req_gain == 0
    ldr r0, =meter_mode                  @ 08006B3E
    ldrb r0, [r0]                        @ 08006B40  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 08006B42
    beq .Lmac_acv_08006B66               @ 08006B44  if meter_mode == 13
    ldr r0, =meter_mode                  @ 08006B46
    ldrb r0, [r0]                        @ 08006B48  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 08006B4A
    beq .Lmac_acv_08006B66               @ 08006B4C  if meter_mode == 14
    ldr r0, =meter_mode                  @ 08006B4E
    ldrb r0, [r0]                        @ 08006B50  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08006B52
    beq .Lmac_acv_08006B66               @ 08006B54  if meter_mode == 15
    ldr r0, =v_20007E08                  @ 08006B56
    ldr r1, [r0]                         @ 08006B5A  r1 = cal_zero_capture (u32)
    ldr r0, =v_20007DD4                  @ 08006B5C
    ldr r0, [r0]                         @ 08006B5E  r0 = ad1_mean (u32)
    bl fn_0800F7B8                       @ 08006B60  CAL: gain completion step (r0 = mean, r1 = captured offset)
    b .Lmac_acv_expiry                   @ 08006B64
.Lmac_acv_08006B66:   @ branch target from 08006B3C, 08006B44, 08006B4C, 08006B54
    @ normal chain: x = mean - offset (clamped at 0), D = x / gain
    ldr r0, =v_20007DD4                  @ 08006B66
    ldr r0, [r0]                         @ 08006B68  r0 = ad1_mean (u32)
    bl cal_subtract_offset_clamp         @ 08006B6A  MDC: r0 = mean - offset, 0 if the result is below 1
    ldr r1, =v_20007D64                  @ 08006B6E
    str r0, [r1]                         @ 08006B70  reading (u32) = r0
    ldr r0, =v_20007D64                  @ 08006B72
    ldr r0, [r0]                         @ 08006B74  r0 = reading (u32)
    cmp r0, #0                           @ 08006B76
    bpl .Lmac_acv_08006B80               @ 08006B78  if reading >= 0
    movs r0, #0                          @ 08006B7A
    ldr r1, =v_20007D64                  @ 08006B7C
    str r0, [r1]                         @ 08006B7E  reading (u32) = 0
.Lmac_acv_08006B80:   @ branch target from 08006B78
    ldr r0, =v_20007D64                  @ 08006B80
    ldr r0, [r0]                         @ 08006B82  r0 = reading (u32)
    bl cal_divide_by_gain                @ 08006B84  MDC: r0 = (int)((float)r0 / gain + 0.5), gain from the active record
    ldr r1, =v_20007D64                  @ 08006B88
    str r0, [r1]                         @ 08006B8A  reading (u32) = r0
    @ 1 kHz filter correction (modes 2, 4 with the filter on), then the frequency correction
    ldr r0, =v_20007D64                  @ 08006B8C
    ldr r0, [r0]                         @ 08006B8E  r0 = reading (u32)
    bl fn_08006D40                       @ 08006B90  MAC: 1 kHz filter correction
    ldr r1, =v_20007D64                  @ 08006B94
    str r0, [r1]                         @ 08006B96  reading (u32) = r0
    ldr r0, =v_20007D64                  @ 08006B98
    ldr r1, [r0]                         @ 08006B9A  r1 = reading (u32)
    ldr r0, =meter_mode                  @ 08006B9C
    ldrb r0, [r0]                        @ 08006B9E  r0 = meter_mode (u8)
    bl fn_0800742C                       @ 08006BA0  MAC: AC frequency correction (r0 = mode, r1 = value)
    ldr r1, =v_20007D64                  @ 08006BA4
    str r0, [r1]                         @ 08006BA6  reading (u32) = r0
    @ smoothing: thr 20, depth 10
    movs r2, #0xa                        @ 08006BA8
    movs r1, #0x14                       @ 08006BAA  = 20
    ldr r0, =v_20007D64                  @ 08006BAC
    ldr r0, [r0]                         @ 08006BAE  r0 = reading (u32)
    @ ---- v2.05 0x08006BB0 replaced (see Deviation in the header) ----
    @ OF-28: the burden-voltage phase of the current modes has its own history; ACV and LowZ keep the v2.05 one.
    ldr r3, =meter_mode
    ldrb r3, [r3]
    cmp r3, #0x10
    beq 1f
    cmp r3, #0x12
    beq 1f
    cmp r3, #0x14
    beq 1f
    bl fn_08008344                          @ modes 0, 2: v2.05 history
    b 2f
1:  ldr r3, =func_st_burden_volt_ac            @ modes 16, 18, 20: burden voltage (r0 = D, r1 = 20, r2 = 10)
    bl func_smooth_avg
2:
    ldr r1, =v_20007D64                  @ 08006BB4
    str r0, [r1]                         @ 08006BB6  reading (u32) = r0
    bl fn_08007532                       @ 08006BB8  CAL: AC-band calibration word capture (acts only in calibration mode)
    @ publish: new_reading, dBm
    bl fn_080076BC                       @ 08006BBC  MAC: finish an AC value (new_reading, dBm)
.Lmac_acv_expiry:   @ mean processed
    @ forced frequency expiry for small readings
    bl fn_08006C7A                       @ 08006BC0  MAC: forced frequency expiry for small readings
.Lmac_acv_sample:   @ per-sample part
    @ per-sample value: not in the VA and current modes, not in AC+DC (its own phases), LowZ only while a signal is confirmed (countdown == 5)
    ldr r0, =meter_mode                  @ 08006BC4
    ldrb r0, [r0]                        @ 08006BC6  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 08006BC8
    beq .Lmac_acv_exit                   @ 08006BCA  if meter_mode == 13
    ldr r0, =meter_mode                  @ 08006BCC
    ldrb r0, [r0]                        @ 08006BCE  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 08006BD0
    beq .Lmac_acv_exit                   @ 08006BD2  if meter_mode == 14
    ldr r0, =meter_mode                  @ 08006BD4
    ldrb r0, [r0]                        @ 08006BD6  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 08006BD8
    beq .Lmac_acv_exit                   @ 08006BDA  if meter_mode == 15
    ldr r0, =meter_mode                  @ 08006BDC
    ldrb r0, [r0]                        @ 08006BDE  r0 = meter_mode (u8)
    cmp r0, #0x10                        @ 08006BE0
    beq .Lmac_acv_exit                   @ 08006BE2  if meter_mode == 16
    ldr r0, =meter_mode                  @ 08006BE4
    ldrb r0, [r0]                        @ 08006BE6  r0 = meter_mode (u8)
    cmp r0, #0x12                        @ 08006BE8
    beq .Lmac_acv_exit                   @ 08006BEA  if meter_mode == 18
    ldr r0, =meter_mode                  @ 08006BEC
    ldrb r0, [r0]                        @ 08006BEE  r0 = meter_mode (u8)
    cmp r0, #0x14                        @ 08006BF0
    beq .Lmac_acv_exit                   @ 08006BF2  if meter_mode == 20
    ldr r0, =meter_mode                  @ 08006BF4
    ldrb r0, [r0]                        @ 08006BF6  r0 = meter_mode (u8)
    cmp r0, #0x11                        @ 08006BF8
    beq .Lmac_acv_exit                   @ 08006BFA  if meter_mode == 17
    ldr r0, =meter_mode                  @ 08006BFC
    ldrb r0, [r0]                        @ 08006BFE  r0 = meter_mode (u8)
    cmp r0, #0x13                        @ 08006C00
    beq .Lmac_acv_exit                   @ 08006C02  if meter_mode == 19
    ldr r0, =meter_mode                  @ 08006C04
    ldrb r0, [r0]                        @ 08006C06  r0 = meter_mode (u8)
    cmp r0, #0x15                        @ 08006C08
    beq .Lmac_acv_exit                   @ 08006C0A  if meter_mode == 21
    ldr r0, =meter_mode                  @ 08006C0C
    ldrb r0, [r0]                        @ 08006C0E  r0 = meter_mode (u8)
    cmp r0, #2                           @ 08006C10
    bne .Lmac_acv_lowz                   @ 08006C12  if meter_mode != 2
    ldr r0, =acdc_active                 @ 08006C14
    ldrb r0, [r0]                        @ 08006C16  r0 = acdc_active (u8)
    cmp r0, #0                           @ 08006C18
    bne .Lmac_acv_exit                   @ 08006C1A  if acdc_active != 0
.Lmac_acv_lowz:   @ LowZ check
    ldr r0, =meter_mode                  @ 08006C1C
    ldrb r0, [r0]                        @ 08006C1E  r0 = meter_mode (u8)
    cmp r0, #0                           @ 08006C20
    bne .Lmac_acv_sample_value           @ 08006C22  if meter_mode != 0
    ldr r0, =meter_mode                  @ 08006C24
    ldrb r0, [r0]                        @ 08006C26  r0 = meter_mode (u8)
    cmp r0, #0                           @ 08006C28
    bne .Lmac_acv_exit                   @ 08006C2A  if meter_mode != 0
    ldr r0, =v_20000239                  @ 08006C2C
    ldrb r0, [r0]                        @ 08006C30  r0 = lowz_countdown (u8)
    cmp r0, #5                           @ 08006C32
    bne .Lmac_acv_exit                   @ 08006C34  if lowz_countdown != 5
.Lmac_acv_sample_value:   @ compute the per-sample value
    @ per-sample value from the latest sample
    ldr r1, =mac_ps_done                    @ IMP-01: the per-sample value was made by mac_sample_precheck
    ldrb r0, [r1]
    cbz r0, 1f
    movs r0, #0
    strb r0, [r1]                           @ consumed
    b .Lmac_acv_exit                        @ skip the second computation
1:
    ldr r0, =v_20007D74                  @ 08006C36
    ldr r0, [r0]                         @ 08006C38  r0 = sample_in (u32)
    bl fn_08008468                       @ 08006C3A  MAC: per-sample value from the latest sample (r0)
    ldr r0, =v_20007D68                  @ 08006C3E
    ldr r1, [r0]                         @ 08006C40  r1 = sample_value (u32)
    ldr r0, =meter_mode                  @ 08006C42
    ldrb r0, [r0]                        @ 08006C44  r0 = meter_mode (u8)
    bl fn_0800742C                       @ 08006C46  MAC: AC frequency correction (r0 = mode, r1 = value)
    ldr r1, =v_20007D68                  @ 08006C4A
    str r0, [r1]                         @ 08006C4C  sample_value (u32) = r0
    @ modes 2, 4 with the 1 kHz filter: filter correction of the x10-scaled value
    ldr r0, =meter_mode                  @ 08006C4E
    ldrb r0, [r0]                        @ 08006C50  r0 = meter_mode (u8)
    cmp r0, #2                           @ 08006C52
    beq .Lmac_acv_08006C5E               @ 08006C54  if meter_mode == 2
    ldr r0, =meter_mode                  @ 08006C56
    ldrb r0, [r0]                        @ 08006C58  r0 = meter_mode (u8)
    cmp r0, #4                           @ 08006C5A
    bne .Lmac_acv_exit                   @ 08006C5C  if meter_mode != 4
.Lmac_acv_08006C5E:   @ branch target from 08006C54
    ldr r0, =filter_1khz                 @ 08006C5E
    ldrb r0, [r0]                        @ 08006C62  r0 = filter_1khz (u8)
    cmp r0, #1                           @ 08006C64
    bne .Lmac_acv_exit                   @ 08006C66  if filter_1khz != 1
    ldr r0, =v_20007D68                  @ 08006C68
    ldr r0, [r0]                         @ 08006C6A  r0 = sample_value (u32)
    movs r1, #0xa                        @ 08006C6C
    muls r0, r1, r0                      @ 08006C6E  r0 = 10 * sample_value
    bl fn_08006D40                       @ 08006C70  MAC: 1 kHz filter correction
    ldr r1, =v_20007D68                  @ 08006C74
    str r0, [r1]                         @ 08006C76  sample_value (u32) = r0
.Lmac_acv_exit:   @ return
    pop {r0, pc}                         @ 08006C78
    .ltorg
ENDFUNC fn_08006AEC
    .global mac_acv
    .set mac_acv, fn_08006AEC

@ -----------------------------------------------------------------------------
@ fn_08006C7A (mac_freq_expiry) - forced expiry of the measured frequency for small AC readings: sets the age counter above its limit so
@   the next timer tick discards the frequency (reading < 1000 counts, < 100 in ACV range 3)
@ Replaces : 0x08006C7A FUN_08006c7a (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, flags
@ Context  : main only (fn_080067D6, fn_08006AEC)
@ RAM      : reads  0x20007D64 reading, 0x20007FC0 freq_age, 0x2000803C meter_mode, 0x2000803D meter_range,
@            0x2000805D new_reading, 0x200080B9 filter_1khz
@            writes 0x20007FC0 freq_age
@ Spec     : analysis/hy3131_modes_ac_current.md 3 ("Forced expiry for small readings")
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_08006C7A
    @ r0 = limit, 0 = none
    movs r0, #0                          @ 08006C7A
    @ only when a new reading exists
    ldr r1, =v_2000805D                  @ 08006C7C
    ldrb r1, [r1]                        @ 08006C80  r1 = new_reading (u8)
    cmp r1, #0                           @ 08006C82
    beq .Lmac_freq_expiry_08006CF6       @ 08006C84  if new_reading == 0
    @ skipped for modes 2, 4 with the 1 kHz filter on
    ldr r1, =meter_mode                  @ 08006C86
    ldrb r1, [r1]                        @ 08006C88  r1 = meter_mode (u8)
    cmp r1, #2                           @ 08006C8A
    beq .Lmac_freq_expiry_08006C96       @ 08006C8C  if meter_mode == 2
    ldr r1, =meter_mode                  @ 08006C8E
    ldrb r1, [r1]                        @ 08006C90  r1 = meter_mode (u8)
    cmp r1, #4                           @ 08006C92
    bne .Lmac_freq_expiry_08006CA0       @ 08006C94  if meter_mode != 4
.Lmac_freq_expiry_08006C96:   @ branch target from 08006C8C
    ldr r1, =filter_1khz                 @ 08006C96
    ldrb r1, [r1]                        @ 08006C9A  r1 = filter_1khz (u8)
    cmp r1, #1                           @ 08006C9C
    beq .Lmac_freq_expiry_08006CF6       @ 08006C9E  if filter_1khz == 1
.Lmac_freq_expiry_08006CA0:   @ branch target from 08006C94
    @ only when the age counter is above 2
    ldr r1, =v_20007FC0                  @ 08006CA0
    ldrh r1, [r1]                        @ 08006CA4  r1 = freq_age (u16)
    cmp r1, #3                           @ 08006CA6
    blt .Lmac_freq_expiry_08006CF6       @ 08006CA8  if freq_age < (signed) 3
    @ limit by mode: ACV 1000 (100 in range 3), ACmV and the AC currents 1000
    ldr r1, =meter_mode                  @ 08006CAA
    ldrb r1, [r1]                        @ 08006CAC  r1 = meter_mode (u8)
    cmp r1, #2                           @ 08006CAE
    beq .Lmac_freq_expiry_08006CC4       @ 08006CB0  if meter_mode == 2
    cmp r1, #4                           @ 08006CB2
    beq .Lmac_freq_expiry_08006CDA       @ 08006CB4  if meter_mode == 4
    cmp r1, #0x10                        @ 08006CB6
    beq .Lmac_freq_expiry_08006CDA       @ 08006CB8  if meter_mode == 16
    cmp r1, #0x12                        @ 08006CBA
    beq .Lmac_freq_expiry_08006CDA       @ 08006CBC  if meter_mode == 18
    cmp r1, #0x14                        @ 08006CBE
    beq .Lmac_freq_expiry_08006CDA       @ 08006CC0  if meter_mode == 20
    b .Lmac_freq_expiry_08006CE0         @ 08006CC2
.Lmac_freq_expiry_08006CC4:   @ branch target from 08006CB0
    ldr r1, =meter_range                 @ 08006CC4
    ldrb r1, [r1]                        @ 08006CC6  r1 = meter_range (u8)
    cmp r1, #3                           @ 08006CC8
    bne .Lmac_freq_expiry_08006CD2       @ 08006CCA  if meter_range != 3
    movs r1, #0x64                       @ 08006CCC  = 100
    movs r0, r1                          @ 08006CCE
    b .Lmac_freq_expiry_08006CD8         @ 08006CD0
.Lmac_freq_expiry_08006CD2:   @ branch target from 08006CCA
    mov r1, #0x3e8                       @ 08006CD2  = 1000
    movs r0, r1                          @ 08006CD6
.Lmac_freq_expiry_08006CD8:   @ branch target from 08006CD0
    b .Lmac_freq_expiry_08006CE0         @ 08006CD8
.Lmac_freq_expiry_08006CDA:   @ branch target from 08006CB4, 08006CB8, 08006CBC, 08006CC0
    mov r1, #0x3e8                       @ 08006CDA  = 1000
    movs r0, r1                          @ 08006CDE
.Lmac_freq_expiry_08006CE0:   @ branch target from 08006CC2, 08006CD8
    cmp r0, #0                           @ 08006CE0
    @ limit 0: nothing; reading below the limit: age counter = 2000 (the timer tick compares against 2000)
    beq .Lmac_freq_expiry_08006CF6       @ 08006CE2  if r0 == 0
    ldr r1, =v_20007D64                  @ 08006CE4
    ldr r1, [r1]                         @ 08006CE6  r1 = reading (u32)
    cmp r1, r0                           @ 08006CE8
    bge .Lmac_freq_expiry_08006CF6       @ 08006CEA  if reading >= (signed) r0
    mov r1, #0x7d0                       @ 08006CEC  = 2000
    ldr r2, =v_20007FC0                  @ 08006CF0
    strh r1, [r2]                        @ 08006CF4  freq_age = 2000
.Lmac_freq_expiry_08006CF6:   @ branch target from 08006C84, 08006C9E, 08006CA8, 08006CE2, 08006CEA
    bx lr                                @ 08006CF6
    .ltorg
ENDFUNC fn_08006C7A
    .global mac_freq_expiry
    .set mac_freq_expiry, fn_08006C7A

@ -----------------------------------------------------------------------------
@ fn_08008468 (mac_sample_value) - per-sample value of the AC modes: D68 = (sample - offset) / gain, divided by 10 again when the
@   1 kHz filter is on (cal_divide_by_gain divides by g/10 then)
@ Replaces : 0x08008468 FUN_08008468 (v2.05)
@ In       : r0 = latest decoded AD1 sample (0x20007D74)
@ Out      : sample_value (0x20007D68), bargraph_update (0x2000805E) = 1
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080067D6, fn_080069B4, fn_08006AEC)
@ RAM      : reads  0x20007D68 sample_value, 0x2000803C meter_mode, 0x200080B9 filter_1khz
@            writes 0x20007D68 sample_value, 0x2000805E bargraph_update
@ Spec     : analysis/hy3131_modes_ac_current.md 4 (per-sample value), 15 D4
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_08008468
    push {r4, lr}                        @ 08008468
    movs r4, r0                          @ 0800846A
    movs r0, r4                          @ 0800846C
    bl cal_subtract_offset_clamp         @ 0800846E  MDC: r0 = mean - offset, 0 if the result is below 1
    ldr r1, =v_20007D68                  @ 08008472
    str r0, [r1]                         @ 08008476  sample_value (u32) = r0
    ldr r0, =v_20007D68                  @ 08008478
    ldr r0, [r0]                         @ 0800847C  r0 = sample_value (u32)
    bl cal_divide_by_gain                @ 0800847E  MDC: r0 = (int)((float)r0 / gain + 0.5), gain from the active record
    ldr r1, =v_20007D68                  @ 08008482
    str r0, [r1]                         @ 08008486  sample_value (u32) = r0
    @ modes 2, 4 with the filter on: undo the x10 scale
    ldr r0, =meter_mode                  @ 08008488
    ldrb r0, [r0]                        @ 0800848C  r0 = meter_mode (u8)
    cmp r0, #2                           @ 0800848E
    beq .Lmac_sample_value_0800849C      @ 08008490  if meter_mode == 2
    ldr r0, =meter_mode                  @ 08008492
    ldrb r0, [r0]                        @ 08008496  r0 = meter_mode (u8)
    cmp r0, #4                           @ 08008498
    bne .Lmac_sample_value_080084B8      @ 0800849A  if meter_mode != 4
.Lmac_sample_value_0800849C:   @ branch target from 08008490
    ldr r0, =filter_1khz                 @ 0800849C
    ldrb r0, [r0]                        @ 080084A0  r0 = filter_1khz (u8)
    cmp r0, #1                           @ 080084A2
    bne .Lmac_sample_value_080084B8      @ 080084A4  if filter_1khz != 1
    ldr r0, =v_20007D68                  @ 080084A6
    ldr r0, [r0]                         @ 080084AA  r0 = sample_value (u32)
    movs r1, #0xa                        @ 080084AC  divisor 10
    sdiv r0, r0, r1                      @ 080084AE  r0 = sample_value / 10
    ldr r1, =v_20007D68                  @ 080084B2
    str r0, [r1]                         @ 080084B6  sample_value (u32) = (sample_value / 10)
.Lmac_sample_value_080084B8:   @ branch target from 0800849A, 080084A4
    movs r0, #1                          @ 080084B8
    ldr r1, =v_2000805E                  @ 080084BA
    strb r0, [r1]                        @ 080084BE  bargraph_update (u8) = 1
    pop {r4, pc}                         @ 080084C0
    .ltorg
ENDFUNC fn_08008468
    .global mac_sample_value
    .set mac_sample_value, fn_08008468

@ -----------------------------------------------------------------------------
@ fn_080076BC (mac_ac_finish) - finish an AC value: raise new_reading (or count an AC+DC phase mean), compute the dBm value,
@   and request a secondary-display refresh in ACV page 11
@ Replaces : 0x080076BC FUN_080076bc (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_08006A9E, fn_08006AEC)
@ RAM      : reads  0x20008037 setup_item, 0x2000803C meter_mode, 0x200080BA acdc_active, 0x200080BD acdc_dc_phase
@            writes 0x2000805D new_reading, 0x20008062 sec_refresh
@ Spec     : analysis/hy3131_modes_ac_current.md 7.4
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_080076BC
    push {r7, lr}                        @ 080076BC
    @ AC+DC in the AC phase: the phase mean counter decides when the phase ends; no display flag
    ldr r0, =meter_mode                  @ 080076BE
    ldrb r0, [r0]                        @ 080076C0  r0 = meter_mode (u8)
    cmp r0, #2                           @ 080076C2
    bne .Lmac_ac_finish_plain            @ 080076C4  if meter_mode != 2
    ldr r0, =acdc_active                 @ 080076C6
    ldrb r0, [r0]                        @ 080076CA  r0 = acdc_active (u8)
    cmp r0, #0                           @ 080076CC
    beq .Lmac_ac_finish_plain            @ 080076CE  if acdc_active == 0
    ldr r0, =acdc_use_dcv_cal            @ 080076D0
    ldrb r0, [r0]                        @ 080076D4  r0 = acdc_dc_phase (u8)
    cmp r0, #0                           @ 080076D6
    bne .Lmac_ac_finish_dbm              @ 080076D8  if acdc_dc_phase != 0
    ldr r0, =acdc_use_dcv_cal            @ 080076DA
    ldrb r0, [r0]                        @ 080076DE  r0 = acdc_dc_phase (u8)
    bl fn_0800A5BC                       @ 080076E0  MAC: AC+DC phase mean counter
    b .Lmac_ac_finish_dbm                @ 080076E4
.Lmac_ac_finish_plain:   @ not AC+DC: new_reading = 1
    @ all other cases: new reading
    movs r0, #1                          @ 080076E6
    ldr r1, =v_2000805D                  @ 080076E8
    strb r0, [r1]                        @ 080076EC  new_reading (u8) = 1
.Lmac_ac_finish_dbm:   @ dBm value
    @ dBm of the reading
    bl fn_0800A74C                       @ 080076EE  MAC: dBm value
    @ ACV: page 11 of the secondary display is redrawn
    ldr r0, =meter_mode                  @ 080076F2
    ldrb r0, [r0]                        @ 080076F4  r0 = meter_mode (u8)
    cmp r0, #2                           @ 080076F6
    bne .Lmac_ac_finish_exit             @ 080076F8  if meter_mode != 2
    ldr r0, =v_20008037                  @ 080076FA
    ldrb r0, [r0]                        @ 080076FE  r0 = setup_item (u8)
    cmp r0, #0xb                         @ 08007700
    bne .Lmac_ac_finish_exit             @ 08007702  if setup_item != 11
    movs r0, #1                          @ 08007704
    ldr r1, =v_20008062                  @ 08007706
    strb r0, [r1]                        @ 0800770A  sec_refresh (u8) = 1
.Lmac_ac_finish_exit:   @ return
    pop {r0, pc}                         @ 0800770C
    .ltorg
ENDFUNC fn_080076BC
    .global mac_ac_finish
    .set mac_ac_finish, fn_080076BC

