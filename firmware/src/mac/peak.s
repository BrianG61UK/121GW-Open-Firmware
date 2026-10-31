@ =============================================================================
@ peak.s - MAC module: PEAK hold (ACV and ACmV with the PEAK key)
@
@ With peak_hold = 1 the HY3131 row enables the peak detector (ENPKH) and its interrupt; fn_0800A7FC services
@ the peak event: it assembles the 18-bit peak registers from the register mirror, restarts the detector and
@ delivers the reading.  Spec: analysis/hy3131_modes_ac_current.md 1 (peak rows), hy3131_model.md 4.4.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.mac, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800A7FC (mac_peak) - service the HY3131 peak event: read the peak registers from the mirror, restart the detector, show the
@   maximum (PEAK) or minimum (PEAK MIN) hold value
@ Replaces : 0x0800A7FC FUN_0800a7fc (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (hy3131_service_irq)
@ RAM      : reads  0x20000238 settle_count, 0x200077D0+14, 0x200077D0+15, 0x200077D0+16, 0x200077D0+17,
@            0x200077D0+18, 0x200077D0+19, 0x20007D64 reading, 0x20007DEC peak_lo_raw, 0x20007DF0 peak_hi_raw,
@            0x20007E08 cal_zero_capture, 0x20007E8C peak_max_hi, 0x20007E90 peak_max_lo, 0x2000803C meter_mode,
@            0x2000808A cal_mode, 0x2000808C cal_req_offset, 0x2000808E cal_req_gain, 0x200080B7 peak_hold,
@            0x200080B8 peak_show_min
@            writes 0x20007D64 reading, 0x20007D68 sample_value, 0x20007DEC peak_lo_raw, 0x20007DF0 peak_hi_raw,
@            0x20007DF4 peak_lo_at_max, 0x20007E08 cal_zero_capture, 0x20007E8C peak_max_hi, 0x20007E90 peak_max_lo,
@            0x20008045 sign_flag, 0x2000805D new_reading, 0x2000805E bargraph_update
@ Spec     : analysis/hy3131_modes_ac_current.md 2; hy3131_model.md 4.4; DESIGN.md 4.1 (peak restart)
@ Deviation: HW-05 (the two register 0x29 writes of the restart are made by hy_peak_restart from the row table)
@ -----------------------------------------------------------------------------
FUNC fn_0800A7FC
    push {r7, lr}                        @ 0800A7FC
    @ not in the VA modes 13, 14, 15
    ldr r0, =meter_mode                  @ 0800A7FE
    ldrb r0, [r0]                        @ 0800A802  r0 = meter_mode (u8)
    cmp r0, #0xd                         @ 0800A804
    beq .Lmac_peak_0800A81C              @ 0800A806  if meter_mode == 13
    ldr r0, =meter_mode                  @ 0800A808
    ldrb r0, [r0]                        @ 0800A80C  r0 = meter_mode (u8)
    cmp r0, #0xe                         @ 0800A80E
    beq .Lmac_peak_0800A81C              @ 0800A810  if meter_mode == 14
    ldr r0, =meter_mode                  @ 0800A812
    ldrb r0, [r0]                        @ 0800A816  r0 = meter_mode (u8)
    cmp r0, #0xf                         @ 0800A818
    bne .Lmac_peak_regs                  @ 0800A81A  if meter_mode != 15
.Lmac_peak_0800A81C:   @ branch target from 0800A806, 0800A810
    b .Lmac_peak_exit                    @ 0800A81C
.Lmac_peak_regs:   @ not a VA mode
    @ peak registers from the mirror 0x200077D0: PKH = regs 0x11..0x13 (peak_hi_raw), PKL = regs 0x0E..0x10 (peak_lo_raw), 24 bit little endian
    ldr r0, =adc_regs                    @ 0800A81E
    ldrb r0, [r0, #0x13]                 @ 0800A822  r0 = v_200077E3 (u8)
    ldr r1, =adc_regs                    @ 0800A824
    ldrb r1, [r1, #0x12]                 @ 0800A828  r1 = v_200077E2 (u8)
    lsls r1, r1, #8                      @ 0800A82A  r1 = v_200077E2 << 8
    adds r0, r1, r0, lsl #16             @ 0800A82C  r0 = (v_200077E2 << 8) + (v_200077E3 << 16)
    ldr r1, =adc_regs                    @ 0800A830
    ldrb r1, [r1, #0x11]                 @ 0800A834  r1 = v_200077E1 (u8)
    adds r0, r1, r0                      @ 0800A836  r0 = v_200077E1 + ((v_200077E2 << 8) + (v_200077E3 << 16))
    ldr r1, =v_20007DF0                  @ 0800A838
    str r0, [r1]                         @ 0800A83C  peak_hi_raw (u32) = (v_200077E1 + ((v_200077E2 << 8) + (v_200077E3 << 16)))
    ldr r0, =adc_regs                    @ 0800A83E
    ldrb r0, [r0, #0x10]                 @ 0800A842  r0 = v_200077E0 (u8)
    ldr r1, =adc_regs                    @ 0800A844
    ldrb r1, [r1, #0xf]                  @ 0800A848  r1 = v_200077DF (u8)
    lsls r1, r1, #8                      @ 0800A84A  r1 = v_200077DF << 8
    adds r0, r1, r0, lsl #16             @ 0800A84C  r0 = (v_200077DF << 8) + (v_200077E0 << 16)
    ldr r1, =adc_regs                    @ 0800A850
    ldrb r1, [r1, #0xe]                  @ 0800A854  r1 = v_200077DE (u8)
    adds r0, r1, r0                      @ 0800A856  r0 = v_200077DE + ((v_200077DF << 8) + (v_200077E0 << 16))
    ldr r1, =v_20007DEC                  @ 0800A858
    str r0, [r1]                         @ 0800A85C  peak_lo_raw (u32) = (v_200077DE + ((v_200077DF << 8) + (v_200077E0 << 16)))
    @ ---- v2.05 0x0800A85E..0x0800A88C replaced (see Deviation in the header) ----
    bl hy_peak_restart                      @ HW-05: HY writes register 0x29 <- row byte & 0xFB, delay(10), then the row byte (v2.05 0x0800A85E..0x0800A88C
                                            @ used the read-back copy 0x2000807E and hy3131_write_regs)
    @ only modes 2 and 4 with peak_hold = 1
    ldr r0, =meter_mode                  @ 0800A890
    ldrb r0, [r0]                        @ 0800A894  r0 = meter_mode (u8)
    cmp r0, #2                           @ 0800A896
    beq .Lmac_peak_0800A8A6              @ 0800A898  if meter_mode == 2
    ldr r0, =meter_mode                  @ 0800A89A
    ldrb r0, [r0]                        @ 0800A89E  r0 = meter_mode (u8)
    cmp r0, #4                           @ 0800A8A0
    bne .Lmac_peak_exit                  @ 0800A8A2  if meter_mode != 4
.Lmac_peak_0800A8A6:   @ branch target from 0800A898
    ldr r0, =peak_hold                   @ 0800A8A6
    ldrb r0, [r0]                        @ 0800A8AA  r0 = peak_hold (u8)
    cmp r0, #1                           @ 0800A8AC
    bne .Lmac_peak_exit                  @ 0800A8AE  if peak_hold != 1
    @ peak_show_min = 1: minimum hold: reading = ~PKL & 0x3FFFF (18 bit)
    ldr r0, =peak_show_min               @ 0800A8B2
    ldrb r0, [r0]                        @ 0800A8B6  r0 = peak_show_min (u8)
    cmp r0, #0                           @ 0800A8B8
    beq .Lmac_peak_max                   @ 0800A8BA  if peak_show_min == 0
    ldr r0, =v_20007DEC                  @ 0800A8BC
    ldr r0, [r0]                         @ 0800A8C0  r0 = peak_lo_raw (u32)
    mvns r0, r0                          @ 0800A8C2  r0 = ~peak_lo_raw
    lsls r0, r0, #0xe                    @ 0800A8C4  r0 = ~peak_lo_raw << 0xE
    lsrs r0, r0, #0xe                    @ 0800A8C6  18 bit mask (0x3FFFF) by shifts
    ldr r1, =v_20007D64                  @ 0800A8C8
    str r0, [r1]                         @ 0800A8CC  reading (u32) = ((~peak_lo_raw << 0xE) >> 0xE)
    ldr r0, =v_20000238                  @ 0800A8CE
    ldrb r0, [r0]                        @ 0800A8D2  r0 = settle_count (u8)
    cmp r0, #0                           @ 0800A8D4
    bne .Lmac_peak_minflag               @ 0800A8D6  if settle_count != 0
    ldr r0, =v_20007E90                  @ 0800A8D8
    ldr r0, [r0]                         @ 0800A8DC  r0 = peak_max_lo (u32)
    ldr r1, =v_20007D64                  @ 0800A8DE
    ldr r1, [r1]                         @ 0800A8E2  r1 = reading (u32)
    cmp r0, r1                           @ 0800A8E4
    bhs .Lmac_peak_keep                  @ 0800A8E6  if peak_max_lo >= (unsigned) reading
    ldr r0, =v_20007D64                  @ 0800A8E8
    ldr r0, [r0]                         @ 0800A8EC  r0 = reading (u32)
    ldr r1, =v_20007E90                  @ 0800A8EE
    str r0, [r1]                         @ 0800A8F2  peak_max_lo (u32) = reading
    ldr r0, =v_20007DEC                  @ 0800A8F4
    ldr r0, [r0]                         @ 0800A8F8  r0 = peak_lo_raw (u32)
    ldr r1, =v_20007DF4                  @ 0800A8FA
    str r0, [r1]                         @ 0800A8FE  peak_lo_at_max (u32) = peak_lo_raw
    b .Lmac_peak_minflag                 @ 0800A900
.Lmac_peak_keep:   @ minimum not exceeded: keep the stored minimum
    ldr r0, =v_20007E90                  @ 0800A902
    ldr r0, [r0]                         @ 0800A906  r0 = peak_max_lo (u32)
    ldr r1, =v_20007D64                  @ 0800A908
    str r0, [r1]                         @ 0800A90C  reading (u32) = peak_max_lo
.Lmac_peak_minflag:   @ sign flag = 1 (minimum hold shows a negative sign)
    movs r0, #1                          @ 0800A90E
    ldr r1, =v_20008045                  @ 0800A910
    strb r0, [r1]                        @ 0800A914  sign_flag (u8) = 1
    b .Lmac_peak_exit                    @ 0800A916
.Lmac_peak_max:   @ maximum hold branch
    @ maximum hold: PKH below 0x40000
    ldr r0, =v_20007DF0                  @ 0800A918
    ldr r0, [r0]                         @ 0800A91C  r0 = peak_hi_raw (u32)
    cmp r0, #0x40000                     @ 0800A91E
    bhs .Lmac_peak_exit                  @ 0800A922  0x40000 = 262144
    ldr r0, =v_20007DF0                  @ 0800A924
    ldr r0, [r0]                         @ 0800A928  r0 = peak_hi_raw (u32)
    ldr r1, =v_20007D64                  @ 0800A92A
    str r0, [r1]                         @ 0800A92E  reading (u32) = peak_hi_raw
    @ calibration offset request
    ldr r0, =v_2000808C                  @ 0800A930
    ldrb r0, [r0]                        @ 0800A934  r0 = cal_req_offset (u8)
    cmp r0, #0                           @ 0800A936
    beq .Lmac_peak_gaincal               @ 0800A938  if cal_req_offset == 0
    ldr r0, =v_20007D64                  @ 0800A93A
    ldr r0, [r0]                         @ 0800A93E  r0 = reading (u32)
    bl fn_0800F0AC                       @ 0800A940  CAL: offset capture step (r0 = mean), returns the captured value
    ldr r1, =v_20007E08                  @ 0800A944
    str r0, [r1]                         @ 0800A948  cal_zero_capture (u32) = r0
    b .Lmac_peak_publish                 @ 0800A94A
.Lmac_peak_gaincal:   @ no offset request
    @ calibration gain request
    ldr r0, =v_2000808E                  @ 0800A94C
    ldrb r0, [r0]                        @ 0800A950  r0 = cal_req_gain (u8)
    cmp r0, #0                           @ 0800A952
    beq .Lmac_peak_norm                  @ 0800A954  if cal_req_gain == 0
    ldr r0, =v_20007E08                  @ 0800A956
    ldr r1, [r0]                         @ 0800A95A  r1 = cal_zero_capture (u32)
    ldr r0, =v_20007D64                  @ 0800A95C
    ldr r0, [r0]                         @ 0800A960  r0 = reading (u32)
    bl fn_0800F7B8                       @ 0800A962  CAL: gain completion step (r0 = mean, r1 = captured offset)
    b .Lmac_peak_publish                 @ 0800A966
.Lmac_peak_norm:   @ no calibration request
    @ normal: offset, gain (only after the settle count), running maximum
    ldr r0, =v_20000238                  @ 0800A968
    ldrb r0, [r0]                        @ 0800A96C  r0 = settle_count (u8)
    cmp r0, #0                           @ 0800A96E
    bne .Lmac_peak_nomax                 @ 0800A970  if settle_count != 0
    ldr r0, =v_20007D64                  @ 0800A972
    ldr r0, [r0]                         @ 0800A976  r0 = reading (u32)
    bl cal_subtract_offset_clamp         @ 0800A978  MDC: r0 = mean - offset, 0 if the result is below 1
    ldr r1, =v_20007D64                  @ 0800A97C
    str r0, [r1]                         @ 0800A980  reading (u32) = r0
    ldr r0, =v_20007D64                  @ 0800A982
    ldr r0, [r0]                         @ 0800A986  r0 = reading (u32)
    cmp r0, #0                           @ 0800A988
    bpl .Lmac_peak_0800A994              @ 0800A98A  if reading >= 0
    movs r0, #0                          @ 0800A98C
    ldr r1, =v_20007D64                  @ 0800A98E
    str r0, [r1]                         @ 0800A992  reading (u32) = 0
.Lmac_peak_0800A994:   @ branch target from 0800A98A
    ldr r0, =v_20007D64                  @ 0800A994
    ldr r0, [r0]                         @ 0800A998  r0 = reading (u32)
    bl cal_divide_by_gain                @ 0800A99A  MDC: r0 = (int)((float)r0 / gain + 0.5), gain from the active record
    ldr r1, =v_20007D64                  @ 0800A99E
    str r0, [r1]                         @ 0800A9A2  reading (u32) = r0
    ldr r0, =v_2000808A                  @ 0800A9A4
    ldrb r0, [r0]                        @ 0800A9A8  r0 = cal_mode (u8)
    cmp r0, #0                           @ 0800A9AA
    bne .Lmac_peak_nomax                 @ 0800A9AC  if cal_mode != 0
    ldr r0, =v_20007E8C                  @ 0800A9AE
    ldr r0, [r0]                         @ 0800A9B2  r0 = peak_max_hi (u32)
    ldr r1, =v_20007D64                  @ 0800A9B4
    ldr r1, [r1]                         @ 0800A9B8  r1 = reading (u32)
    cmp r0, r1                           @ 0800A9BA
    bhs .Lmac_peak_keepmax               @ 0800A9BC  if peak_max_hi >= (unsigned) reading
    ldr r0, =v_20007D64                  @ 0800A9BE
    ldr r0, [r0]                         @ 0800A9C2  r0 = reading (u32)
    ldr r1, =v_20007E8C                  @ 0800A9C4
    str r0, [r1]                         @ 0800A9C8  peak_max_hi (u32) = reading
    b .Lmac_peak_nomax                   @ 0800A9CA
.Lmac_peak_keepmax:   @ keep the stored maximum
    ldr r0, =v_20007E8C                  @ 0800A9CC
    ldr r0, [r0]                         @ 0800A9D0  r0 = peak_max_hi (u32)
    ldr r1, =v_20007D64                  @ 0800A9D2
    str r0, [r1]                         @ 0800A9D6  reading (u32) = peak_max_hi
.Lmac_peak_nomax:   @ settle count not zero or calibration mode
    movs r0, #0                          @ 0800A9D8
    ldr r1, =v_20008045                  @ 0800A9DA
    strb r0, [r1]                        @ 0800A9DE  sign_flag (u8) = 0
.Lmac_peak_publish:   @ reading ready
    @ publish: new_reading, bargraph, sample value
    movs r0, #1                          @ 0800A9E0
    ldr r1, =v_2000805D                  @ 0800A9E2
    strb r0, [r1]                        @ 0800A9E6  new_reading (u8) = 1
    movs r0, #1                          @ 0800A9E8
    ldr r1, =v_2000805E                  @ 0800A9EA
    strb r0, [r1]                        @ 0800A9EE  bargraph_update (u8) = 1
    ldr r0, =v_20007D64                  @ 0800A9F0
    ldr r0, [r0]                         @ 0800A9F4  r0 = reading (u32)
    ldr r1, =v_20007D68                  @ 0800A9F6
    str r0, [r1]                         @ 0800A9FA  sample_value (u32) = reading
.Lmac_peak_exit:   @ return
    pop {r0, pc}                         @ 0800A9FC
    .ltorg
ENDFUNC fn_0800A7FC
    .global mac_peak
    .set mac_peak, fn_0800A7FC

