@ =============================================================================
@ packet.s - BLE: status frame builder
@
@ BLE module, part 3: the 19-byte status frame (analysis/ble_packet.md 3, 4, 5).
@
@ Replaces the v2.05 routines 0x0800C53A .. 0x0800D127.  The builder writes ble_frame_b (OF-10); all
@ frame byte stores of v2.05 that went to 0x20007AE0 go to ble_frame_b here.  The transmit side copies the
@ complete buffer (usart.s).  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

@ Module-local names of v2.05 RAM variables (address = the v_XXXXXXXX symbol of ram_v205.inc)
    .equ ble_ring_main,         v_20003950   @ ring of 1000 s32: main values
    .equ ble_ring_va1,          v_200048F0   @ ring of 1000 s32: VA voltage (written only when the ring flag is passed, never in v2.05)
    .equ ble_ring_va2,          v_20005890   @ ring of 1000 s32: VA current (same)
    .equ ble_id,                v_20007D14   @ serial/ID number, u32, EEPROM 0x003..0x006 (< 100000)
    .equ ble_bar_value,         v_20007D68   @ per-sample value (bar value), s32
    .equ ble_main_value,        v_20007D70   @ last drawn main value, s32 (zeroed at every apply)
    .equ ble_sub_value,         v_20007D84   @ value shown by setup item 10 in modes 2 and 4, scaled by 1/10
    .equ ble_lcd_digit4,        v_20007DB0   @ digit word d4 (ten-thousands) written by fn_0801B090
    .equ ble_lcd_digit3,        v_20007DB4   @ digit word d3 (thousands)
    .equ ble_lcd_digit2,        v_20007DB8   @ digit word d2 (hundreds)
    .equ ble_lcd_digit1,        v_20007DBC   @ digit word d1 (tens)
    .equ ble_lcd_digit0,        v_20007DC0   @ digit word d0 (units)
    .equ ble_acv_scaled,        v_20007E98   @ signed result of setup item 11 in ACV (also BLE sub display case 11)
    .equ ble_va_volt,           v_20007EAC   @ VA voltage s32 (sub display page 10/11 helpers)
    .equ ble_va_cur,            v_20007EB0   @ VA current s32
    .equ ble_date_code,         v_20007F9A   @ date code YYMM, u16, EEPROM 0x001 (default 1708)
    .equ ble_ring_idx,          v_20007FB0   @ ring index 0..999, u16
    .equ ble_bat_value,         v_20007FBA   @ processed battery value u16
    .equ ble_item12_value,      v_20007FCA   @ s16 value of setup item 12 of the VA modes (also BLE sub display case 12)
    .equ ble_temp_value,        v_20007FCC   @ s16 temperature value (PA4 thermistor)
    .equ ble_enable,            v_2000802B   @ BLE / serial transfer enabled (long PEAK)
    .equ ble_xor,               v_20008032   @ checksum accumulator
    .equ ble_item,              v_20008037   @ setup item shown on the secondary display (0..12, 100 = MEM view)
    .equ ble_apo_disable,       v_20008039   @ auto-power-off disable, 0 = APO on, EEPROM 0x016
    .equ ble_bat_low,           v_2000803B   @ debounced low-battery flag
    .equ ble_freq_range,        v_2000803E   @ frequency range 0..? (>= 2 sets the sub "k" in the BLE helper 0x0800CE78)
    .equ ble_sub_dp,            v_20008040   @ decimal-point code of the secondary display (lcd_show_value_pos0_4 argument)
    .equ ble_bar_count,         v_20008041   @ bar segment count (above 25 on an overload; the frame carries at most 25, OF-65)
    .equ ble_ovl,               v_20008046   @ overload flag (drawn once)
    .equ ble_sub_ovl,           v_20008047   @ sub display overload flag (BLE helper 0x0800CE78)
    .equ ble_ovl_latch,         v_20008048   @ latched overload flag
    .equ ble_bar_scale,         v_2000804D   @ bar scale 0..3
    .equ ble_cur_opt,           v_200080A5   @ current-mode setup option flag (setup items 10/11 of the six current modes); meaning UNPROVEN beyond the code
    .equ ble_va_bd,             v_200080A8   @ VA burden option "bd", EEPROM 0x01B
    .equ ble_temp_celsius,      v_200080AB   @ temperature unit, 1 = degC, 0 = degF, EEPROM 0x010
    .equ ble_temp_flag,         v_200080AE   @ temperature flag (BLE sub flag bit 7)
    .equ ble_diode_15v,         v_200080B3   @ DIODE source 0 = 3 V, 1 = 15 V (EEPROM 0x012 read at boot, forced 0, OF-23)
    .equ ble_cont_code,         v_200080B6   @ continuity threshold code, EEPROM 0x014 (v2.05 0..3, port 0..15, IMP-05)
    .equ ble_va_sub,            v_200080C2   @ VA sub-range flag 0 / non-zero (BLE helper selector)
    .equ ble_va_ovl1,           v_200080CA   @ VA overload flag (s8)
    .equ ble_va_ovl2,           v_200080CB   @ VA overload flag (s8)
    .equ ble_year,              v_200080D7   @ year 0..99 (BCD-converted NJU6350 register 2)
    .equ ble_month,             v_200080D8   @ month 1..12 (register 4)
    .equ ble_day,               v_200080D9   @ day 1..31 (register 6)
    .equ ble_hour,              v_200080DA   @ hour 0..23 (register 10)
    .equ ble_minute,            v_200080DB   @ minute 0..59 (register 12)

    .section .text.ble, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ble_value_valid - is the main value fit to be sent?
@ Replaces : nothing in v2.05 (new, OF-34)
@ In       : -
@ Out      : r0 = 1 the main digits show a reading, 0 they are blank or show dashes (frame is held back)
@ Clobbers : r0 (ui_value_valid clobbers r0 only)
@ Context  : main only
@ RAM      : none directly (ui_value_valid reads ui_blank_req, meter_mode, the settle counter 0x20000238 and the
@            blank flag 0x2000805C)
@ Spec     : analysis/autorange_and_scheduler.md 2.4 and 5.2 P7; ORIGINAL_FIRMWARE_ISSUES.md OF-34; reply
@            firmware/requests/W3_to_W9.md item 1
@ Note     : Tail branch to ui_value_valid (UI, src/ui/refresh.s), so the frame follows exactly what the main digits
@            show: v2.05 blanking rule of FUN_08016E08 (0x08016FCE..0x08016FF4: settle counter or blank flag non-zero,
@            except in mode 0) plus the blanking of OF-30, OF-32 and OF-33 (LowZ dashes, BEEP and FREQ before the
@            first result, CAP range jump) that only UI knows.  A frame built while the value is blank would report
@            the zeroed value 0x20007D70.
@ -----------------------------------------------------------------------------
FUNC ble_value_valid
    b ui_value_valid                        @ tail call: r0 = 1 reading, 0 blank (returns to the caller of this routine)
ENDFUNC ble_value_valid

@ -----------------------------------------------------------------------------
@ fn_0800C53A - frame bytes 1..4: date code YYMM and the ID number digits
@ Replaces : 0x0800C53A FUN_0800C53A (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_date_code, ble_id, ble_lcd_digit0, ble_lcd_digit1, ble_lcd_digit2, ble_lcd_digit3,
@            ble_lcd_digit4; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 3 (bytes 1..4)
@ Note     : Splits date_code with fn_0801B090 and packs byte 1 = d3 << 4 | d2, byte 2 = (10 * d1 + d0) << 4, then
@            splits the ID number and ORs its digit 4 into byte 2, byte 3 = d3 << 4 | d2 of the ID, byte 4 = d1 << 4 |
@            d0.  The month is therefore one hex nibble (10 = A, 11 = B, 12 = C), see ble_packet.md 8 item 2.
@ -----------------------------------------------------------------------------
FUNC fn_0800C53A
    push {r7, lr}                           @ 0800C53A
    ldr.w r0, =ble_date_code                @ 0800C53C
    ldrh r0, [r0, #0x0]                     @ 0800C540  r0 = ble_date_code
    bl fn_0801B090                          @ 0800C542  split r0 into the five digit words lcd_digit4..0 [r0=ble_date_code]
    ldr.w r0, =ble_lcd_digit3               @ 0800C546
    ldr r0, [r0, #0x0]                      @ 0800C54A  r0 = ble_lcd_digit3
    ldr.w r1, =ble_lcd_digit2               @ 0800C54C
    ldrb r1, [r1, #0x0]                     @ 0800C550  r1 = ble_lcd_digit2
    ands r1, r1, #0xf                       @ 0800C552  r1 = ble_lcd_digit2 & 15 (0xF)
    adds r0, r1, r0, lsl #0x4               @ 0800C556  r0 = (ble_lcd_digit2 & 15 (0xF)) + (ble_lcd_digit3 << 0x4)
    ldr.w r1, =ble_frame_b                  @ 0800C55A
    strb r0, [r1, #0x1]                     @ 0800C55E  ble_frame_b+1 = ((ble_lcd_digit2 & 15 (0xF)) + (ble_lcd_digit3 << 0x4))
    ldr.w r0, =ble_lcd_digit1               @ 0800C560
    ldr r0, [r0, #0x0]                      @ 0800C564  r0 = ble_lcd_digit1
    movs r1, #0xa                           @ 0800C566
    ldr.w r2, =ble_lcd_digit0               @ 0800C568
    ldr r2, [r2, #0x0]                      @ 0800C56C  r2 = ble_lcd_digit0
    mla r0, r1, r0, r2                      @ 0800C56E  r0 = 10 (0xA) * ble_lcd_digit1 + ble_lcd_digit0
    lsls r0, r0, #0x4                       @ 0800C572  r0 = (10 (0xA) * ble_lcd_digit1 + ble_lcd_digit0) << 4
    ldr.w r1, =ble_frame_b                  @ 0800C574
    strb r0, [r1, #0x2]                     @ 0800C578  ble_frame_b+2 = ((10 (0xA) * ble_lcd_digit1 + ble_lcd_digit0) << 4)
    ldr.w r0, =ble_id                       @ 0800C57A
    ldr r0, [r0, #0x0]                      @ 0800C57E  r0 = ble_id
    bl fn_0801B090                          @ 0800C580  split r0 into the five digit words lcd_digit4..0 [r0=ble_id, r1=&ble_frame_b, r2=ble_lcd_digit0]
    ldr.w r0, =ble_frame_b                  @ 0800C584
    ldrb r0, [r0, #0x2]                     @ 0800C588  r0 = ble_frame_b+2
    ldr.w r1, =ble_lcd_digit4               @ 0800C58A
    ldrb r1, [r1, #0x0]                     @ 0800C58E  r1 = ble_lcd_digit4
    ands r1, r1, #0xf                       @ 0800C590  r1 = ble_lcd_digit4 & 15 (0xF)
    adds r0, r1, r0                         @ 0800C594  r0 = (ble_lcd_digit4 & 15 (0xF)) + ble_frame_b+2
    ldr.w r1, =ble_frame_b                  @ 0800C596
    strb r0, [r1, #0x2]                     @ 0800C59A  ble_frame_b+2 = ((ble_lcd_digit4 & 15 (0xF)) + ble_frame_b+2)
    ldr.w r0, =ble_lcd_digit3               @ 0800C59C
    ldr r0, [r0, #0x0]                      @ 0800C5A0  r0 = ble_lcd_digit3
    ldr.w r1, =ble_lcd_digit2               @ 0800C5A2
    ldrb r1, [r1, #0x0]                     @ 0800C5A6  r1 = ble_lcd_digit2
    ands r1, r1, #0xf                       @ 0800C5A8  r1 = ble_lcd_digit2 & 15 (0xF)
    adds r0, r1, r0, lsl #0x4               @ 0800C5AC  r0 = (ble_lcd_digit2 & 15 (0xF)) + (ble_lcd_digit3 << 0x4)
    ldr.w r1, =ble_frame_b                  @ 0800C5B0
    strb r0, [r1, #0x3]                     @ 0800C5B4  ble_frame_b+3 = ((ble_lcd_digit2 & 15 (0xF)) + (ble_lcd_digit3 << 0x4))
    ldr.w r0, =ble_lcd_digit1               @ 0800C5B6
    ldr r0, [r0, #0x0]                      @ 0800C5BA  r0 = ble_lcd_digit1
    ldr.w r1, =ble_lcd_digit0               @ 0800C5BC
    ldrb r1, [r1, #0x0]                     @ 0800C5C0  r1 = ble_lcd_digit0
    ands r1, r1, #0xf                       @ 0800C5C2  r1 = ble_lcd_digit0 & 15 (0xF)
    adds r0, r1, r0, lsl #0x4               @ 0800C5C6  r0 = (ble_lcd_digit0 & 15 (0xF)) + (ble_lcd_digit1 << 0x4)
    ldr.w r1, =ble_frame_b                  @ 0800C5CA
    strb r0, [r1, #0x4]                     @ 0800C5CE  ble_frame_b+4 = ((ble_lcd_digit0 & 15 (0xF)) + (ble_lcd_digit1 << 0x4))
    pop {r0, pc}                            @ 0800C5D0
ENDFUNC fn_0800C53A
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800C5D2 - build the status frame (wrapper)
@ Replaces : 0x0800C5D2 FUN_0800C5D2 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (loop step 7, fn_0800C51A)
@ Note     : Calls build_status_packet_19b; the only call sites are the main loop (TIM2 count 40) and, new,
@            fn_0800C51A.
@ -----------------------------------------------------------------------------
FUNC fn_0800C5D2
    push {r7, lr}                           @ 0800C5D2
    bl build_status_packet_19b              @ 0800C5D4  build the 19-byte status frame
    pop {r0, pc}                            @ 0800C5D8
ENDFUNC fn_0800C5D2
    .ltorg

@ -----------------------------------------------------------------------------
@ build_status_packet_19b - build the 19-byte status frame in ble_frame_b
@ Replaces : 0x0800C5DA build_status_packet_19b (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads acdc_active, ble_apo_disable, ble_bar_count, ble_bar_scale, ble_bar_value, ble_bat_low,
@            ble_diode_15v, ble_enable, ble_item, ble_main_value, ble_ovl_latch, ble_temp_celsius, filter_1khz,
@            meter_mode, meter_range, minmax_state, peak_hold, peak_show_min, rel_active, v_20007FE1, v_20007FE3,
@            v_20007FE4, v_200080B1; writes ble_frame_b, ble_ring_idx, ble_ring_main, ble_xor
@ Spec     : analysis/ble_packet.md 3, 4, 5 (byte table, sub display, checksum)
@ Deviation: OF-10: the frame is built in ble_frame_b, not in the transmit buffer, and marked complete
@            (ble_frame_ready) only at the end; OF-34: marked complete only when ble_value_valid (the previous frame
@            stays the last one sent)
@ Note     : Byte 0 = 0xF2; bytes 1..4 date code and ID (fn_0800C53A); byte 5 mode and the top two magnitude bits;
@            byte 6 range, overload, sign, temperature unit; bytes 7, 8 |value|; byte 9..12 sub display (switch on the
@            setup item); byte 13 bar scale, sign; byte 14 bar segments; byte 15 status 1; byte 16 status 2; byte 17
@            status 3; byte 18 = XOR of bytes 0..17 (accumulator ble_xor).  The main value is also stored in the ring
@            ble_ring_main (index ble_ring_idx, wraps at 1000).
@ -----------------------------------------------------------------------------
FUNC build_status_packet_19b
    push {r4, r5, r6, lr}                   @ 0800C5DA
    movs r0, #0
    ldr r1, =ble_frame_ready
    strb r0, [r1]                        @ OF-10: the buffer is being rewritten, no complete frame
    movs r0, #0xf2                          @ 0800C5DC
    ldr.w r1, =ble_frame_b                  @ 0800C5DE
    strb r0, [r1, #0x0]                     @ 0800C5E2  ble_frame_b = 242 (0xF2)
    bl fn_0800C53A                          @ 0800C5E4  frame bytes 1..4: date code and ID digits [r0=242 (0xF2), r1=&ble_frame_b]
    ldr.w r0, =meter_mode                   @ 0800C5E8
    ldrb r0, [r0, #0x0]                     @ 0800C5EC  r0 = meter_mode
    movs r5, r0                             @ 0800C5EE
    ldr.w r0, =ble_main_value               @ 0800C5F0
    ldr r0, [r0, #0x0]                      @ 0800C5F4  r0 = ble_main_value
    cmp r0, #0x0                            @ 0800C5F6  compare ble_main_value with 0
    bpl .L0800C606                          @ 0800C5F8  if ble_main_value >=0 0
    ldr.w r0, =ble_main_value               @ 0800C5FA
    ldr r0, [r0, #0x0]                      @ 0800C5FE  r0 = ble_main_value
    rsbs r0, r0, #0                         @ 0800C600  r0 = -ble_main_value
    movs r6, r0                             @ 0800C602
    b .L0800C60E                            @ 0800C604
.L0800C606:  @ reached from 0800C5F8 bpl (ble_main_value >=0 0)
    ldr.w r0, =ble_main_value               @ 0800C606
    ldr r0, [r0, #0x0]                      @ 0800C60A  r0 = ble_main_value
    movs r6, r0                             @ 0800C60C
.L0800C60E:  @ reached from 0800C604 b
    lsls r0, r6, #0xe                       @ 0800C60E  r0 = r6 << 14 (0xE)
    bpl .L0800C614                          @ 0800C610  if bit 17 of r6 is clear
    subs r5, #0x80                          @ 0800C612  r5 = r5 - 128 (0x80)
.L0800C614:  @ reached from 0800C610 bpl (bit 17 of r6 is clear)
    lsls r0, r6, #0xf                       @ 0800C614  r0 = r6 << 15 (0xF)
    bpl .L0800C61A                          @ 0800C616  if bit 16 of r6 is clear
    adds r5, #0x40                          @ 0800C618  r5 = r5 + 64 (0x40)
.L0800C61A:  @ reached from 0800C616 bpl (bit 16 of r6 is clear)
    ldr.w r0, =ble_frame_b                  @ 0800C61A
    strb r5, [r0, #0x5]                     @ 0800C61E  ble_frame_b+5 = r5
    ldr.w r0, =meter_range                  @ 0800C620
    ldrb r0, [r0, #0x0]                     @ 0800C624  r0 = meter_range
    movs r5, r0                             @ 0800C626
    ldr.w r0, =meter_mode                   @ 0800C628
    ldrb r0, [r0, #0x0]                     @ 0800C62C  r0 = meter_mode
    cmp r0, #0xb                            @ 0800C62E  compare meter_mode with 11 (0xB)
    bne .L0800C640                          @ 0800C630  if meter_mode != 11 (0xB)
    ldr.w r0, =ble_diode_15v                @ 0800C632
    ldrb r0, [r0, #0x0]                     @ 0800C636  r0 = ble_diode_15v
    cmp r0, #0x0                            @ 0800C638  compare ble_diode_15v with 0
    beq .L0800C640                          @ 0800C63A  if ble_diode_15v == 0
    movs r0, #0x1                           @ 0800C63C
    movs r5, r0                             @ 0800C63E
.L0800C640:  @ reached from 0800C630 bne (meter_mode != 11 (0xB)), 0800C63A beq (ble_diode_15v == 0)
    ldr.w r0, =ble_ovl_latch                @ 0800C640
    ldrb r0, [r0, #0x0]                     @ 0800C644  r0 = ble_ovl_latch
    cmp r0, #0x0                            @ 0800C646  compare ble_ovl_latch with 0
    beq .L0800C64C                          @ 0800C648  if ble_ovl_latch == 0
    subs r5, #0x80                          @ 0800C64A  r5 = r5 - 128 (0x80)
.L0800C64C:  @ reached from 0800C648 beq (ble_ovl_latch == 0)
    ldr.w r0, =ble_main_value               @ 0800C64C
    ldr r0, [r0, #0x0]                      @ 0800C650  r0 = ble_main_value
    cmp r0, #0x0                            @ 0800C652  compare ble_main_value with 0
    bpl .L0800C658                          @ 0800C654  if ble_main_value >=0 0
    adds r5, #0x40                          @ 0800C656  r5 = r5 + 64 (0x40)
.L0800C658:  @ reached from 0800C654 bpl (ble_main_value >=0 0)
    ldr.w r0, =meter_mode                   @ 0800C658
    ldrb r0, [r0, #0x0]                     @ 0800C65C  r0 = meter_mode
    cmp r0, #0x5                            @ 0800C65E  compare meter_mode with 5
    bne .L0800C672                          @ 0800C660  if meter_mode != 5
    ldr.w r0, =ble_temp_celsius             @ 0800C662
    ldrb r0, [r0, #0x0]                     @ 0800C666  r0 = ble_temp_celsius
    cmp r0, #0x0                            @ 0800C668  compare ble_temp_celsius with 0
    beq .L0800C670                          @ 0800C66A  if ble_temp_celsius == 0
    adds r5, #0x20                          @ 0800C66C  r5 = r5 + 32 (0x20)
    b .L0800C672                            @ 0800C66E
.L0800C670:  @ reached from 0800C66A beq (ble_temp_celsius == 0)
    adds r5, #0x10                          @ 0800C670  r5 = r5 + 16 (0x10)
.L0800C672:  @ reached from 0800C660 bne (meter_mode != 5), 0800C66E b
    ldr.w r0, =ble_frame_b                  @ 0800C672
    strb r5, [r0, #0x6]                     @ 0800C676  ble_frame_b+6 = r5
    ldr.w r0, =ble_main_value               @ 0800C678
    ldr r0, [r0, #0x0]                      @ 0800C67C  r0 = ble_main_value
    cmp r0, #0x0                            @ 0800C67E  compare ble_main_value with 0
    bpl .L0800C68E                          @ 0800C680  if ble_main_value >=0 0
    ldr.w r0, =ble_main_value               @ 0800C682
    ldr r0, [r0, #0x0]                      @ 0800C686  r0 = ble_main_value
    rsbs r0, r0, #0                         @ 0800C688  r0 = -ble_main_value
    movs r6, r0                             @ 0800C68A
    b .L0800C696                            @ 0800C68C
.L0800C68E:  @ reached from 0800C680 bpl (ble_main_value >=0 0)
    ldr.w r0, =ble_main_value               @ 0800C68E
    ldr r0, [r0, #0x0]                      @ 0800C692  r0 = ble_main_value
    movs r6, r0                             @ 0800C694
.L0800C696:  @ reached from 0800C68C b
    asrs r0, r6, #0x8                       @ 0800C696  r0 = r6 >> 8
    movs r5, r0                             @ 0800C698
    ldr.w r0, =ble_frame_b                  @ 0800C69A
    strb r5, [r0, #0x7]                     @ 0800C69E  ble_frame_b+7 = (r6 >> 8)
    movs r0, r6                             @ 0800C6A0
    movs r5, r0                             @ 0800C6A2
    ldr.w r0, =ble_frame_b                  @ 0800C6A4
    strb r5, [r0, #0x8]                     @ 0800C6A8  ble_frame_b+8 = r5
    ldr.w r0, =ble_ring_idx                 @ 0800C6AA
    ldrh r0, [r0, #0x0]                     @ 0800C6AE  r0 = ble_ring_idx
    adds r0, r0, #0x1                       @ 0800C6B0  r0 = ble_ring_idx + 1
    ldr.w r1, =ble_ring_idx                 @ 0800C6B2
    strh r0, [r1, #0x0]                     @ 0800C6B6  ble_ring_idx = (ble_ring_idx + 1)
    ldr.w r0, =ble_ring_idx                 @ 0800C6B8
    ldrh r0, [r0, #0x0]                     @ 0800C6BC  r0 = ble_ring_idx
    cmp r0, #0x3e8                          @ 0800C6BE  compare ble_ring_idx with 1000 (0x3E8)
    blt .L0800C6CC                          @ 0800C6C2  if ble_ring_idx <s 1000 (0x3E8)
    movs r0, #0x0                           @ 0800C6C4
    ldr.w r1, =ble_ring_idx                 @ 0800C6C6
    strh r0, [r1, #0x0]                     @ 0800C6CA  ble_ring_idx = 0
.L0800C6CC:  @ reached from 0800C6C2 blt (ble_ring_idx <s 1000 (0x3E8))
    ldr.w r0, =ble_main_value               @ 0800C6CC
    ldr r0, [r0, #0x0]                      @ 0800C6D0  r0 = ble_main_value
    ldr.w r1, =ble_ring_main                @ 0800C6D2
    ldr.w r2, =ble_ring_idx                 @ 0800C6D6
    ldrh r2, [r2, #0x0]                     @ 0800C6DA  r2 = ble_ring_idx
    str r0, [r1, r2, lsl #0x2]              @ 0800C6DC  ble_ring_main[r2 << 0x2] = ble_main_value
    ldr.w r0, =ble_item                     @ 0800C6E0
    ldrb r0, [r0, #0x0]                     @ 0800C6E4  r0 = ble_item
    cmp r0, #0x0                            @ 0800C6E6  compare ble_item with 0
    beq .L0800C710                          @ 0800C6E8  if ble_item == 0
    cmp r0, #0x1                            @ 0800C6EA  compare ble_item with 1
    beq .L0800C718                          @ 0800C6EC  if ble_item == 1
    cmp r0, #0x2                            @ 0800C6EE  compare ble_item with 2
    beq .L0800C720                          @ 0800C6F0  if ble_item == 2
    cmp r0, #0x4                            @ 0800C6F2  compare ble_item with 4
    beq .L0800C728                          @ 0800C6F4  if ble_item == 4
    cmp r0, #0x5                            @ 0800C6F6  compare ble_item with 5
    beq .L0800C730                          @ 0800C6F8  if ble_item == 5
    cmp r0, #0x6                            @ 0800C6FA  compare ble_item with 6
    beq .L0800C738                          @ 0800C6FC  if ble_item == 6
    cmp r0, #0x7                            @ 0800C6FE  compare ble_item with 7
    beq .L0800C740                          @ 0800C700  if ble_item == 7
    cmp r0, #0xa                            @ 0800C702  compare ble_item with 10 (0xA)
    beq .L0800C748                          @ 0800C704  if ble_item == 10 (0xA)
    cmp r0, #0xb                            @ 0800C706  compare ble_item with 11 (0xB)
    beq .L0800C750                          @ 0800C708  if ble_item == 11 (0xB)
    cmp r0, #0xc                            @ 0800C70A  compare ble_item with 12 (0xC)
    beq .L0800C758                          @ 0800C70C  if ble_item == 12 (0xC)
    b .L0800C760                            @ 0800C70E
.L0800C710:  @ reached from 0800C6E8 beq (ble_item == 0)
    movs r0, #0x9                           @ 0800C710
    bl fn_0800C99E                          @ 0800C712  sub display case 0 (temperature) [r0=9]
    b .L0800C766                            @ 0800C716
.L0800C718:  @ reached from 0800C6EC beq (ble_item == 1)
    movs r0, #0x9                           @ 0800C718
    bl fn_0800C9FC                          @ 0800C71A  sub display case 1 (battery) [r0=9]
    b .L0800C766                            @ 0800C71E
.L0800C720:  @ reached from 0800C6F0 beq (ble_item == 2)
    movs r0, #0x9                           @ 0800C720
    bl fn_0800CA2A                          @ 0800C722  sub display case 2 (APO) [r0=9]
    b .L0800C766                            @ 0800C726
.L0800C728:  @ reached from 0800C6F4 beq (ble_item == 4)
    movs r0, #0x9                           @ 0800C728
    bl fn_0800CA64                          @ 0800C72A  sub display case 4 (contrast) [r0=9]
    b .L0800C766                            @ 0800C72E
.L0800C730:  @ reached from 0800C6F8 beq (ble_item == 5)
    movs r0, #0x9                           @ 0800C730
    bl fn_0800CA96                          @ 0800C732  sub display case 5 (year) [r0=9]
    b .L0800C766                            @ 0800C736
.L0800C738:  @ reached from 0800C6FC beq (ble_item == 6)
    movs r0, #0x9                           @ 0800C738
    bl fn_0800CAC4                          @ 0800C73A  sub display case 6 (month, day) [r0=9]
    b .L0800C766                            @ 0800C73E
.L0800C740:  @ reached from 0800C700 beq (ble_item == 7)
    movs r0, #0x9                           @ 0800C740
    bl fn_0800CB04                          @ 0800C742  sub display case 7 (hour, minute) [r0=9]
    b .L0800C766                            @ 0800C746
.L0800C748:  @ reached from 0800C704 beq (ble_item == 10 (0xA))
    movs r0, #0x9                           @ 0800C748
    bl fn_0800CB44                          @ 0800C74A  sub display case 10 [r0=9]
    b .L0800C766                            @ 0800C74E
.L0800C750:  @ reached from 0800C708 beq (ble_item == 11 (0xB))
    movs r0, #0x9                           @ 0800C750
    bl fn_0800CCC8                          @ 0800C752  sub display case 11 [r0=9]
    b .L0800C766                            @ 0800C756
.L0800C758:  @ reached from 0800C70C beq (ble_item == 12 (0xC))
    movs r0, #0x9                           @ 0800C758
    bl fn_0800CE28                          @ 0800C75A  sub display case 12 [r0=9]
    b .L0800C766                            @ 0800C75E
.L0800C760:  @ reached from 0800C70E b
    movs r0, #0x9                           @ 0800C760
    bl fn_0800D0C8                          @ 0800C762  sub display empty (zeros) [r0=9]
.L0800C766:  @ reached from 0800C716 b, 0800C71E b, 0800C726 b, 0800C72E b, 0800C736 b, 0800C73E b, 0800C746 b, 0800C74E b, 0800C756 b, 0800C75E b
    ldr.w r0, =ble_bar_scale                @ 0800C766
    ldrb r0, [r0, #0x0]                     @ 0800C76A  r0 = ble_bar_scale
    movs r5, r0                             @ 0800C76C
    ldr.w r0, =meter_mode                   @ 0800C76E
    ldrb r0, [r0, #0x0]                     @ 0800C772  r0 = meter_mode
    cmp r0, #0x6                            @ 0800C774  compare meter_mode with 6
    blt .L0800C782                          @ 0800C776  if meter_mode <s 6
    ldr.w r0, =meter_mode                   @ 0800C778
    ldrb r0, [r0, #0x0]                     @ 0800C77C  r0 = meter_mode
    cmp r0, #0x9                            @ 0800C77E  compare meter_mode with 9
    blt .L0800C796                          @ 0800C780  if meter_mode <s 9
.L0800C782:  @ reached from 0800C776 blt (meter_mode <s 6)
    ldr.w r0, =meter_mode                   @ 0800C782
    ldrb r0, [r0, #0x0]                     @ 0800C786  r0 = meter_mode
    cmp r0, #0xc                            @ 0800C788  compare meter_mode with 12 (0xC)
    beq .L0800C796                          @ 0800C78A  if meter_mode == 12 (0xC)
    ldr.w r0, =meter_mode                   @ 0800C78C
    ldrb r0, [r0, #0x0]                     @ 0800C790  r0 = meter_mode
    cmp r0, #0x5                            @ 0800C792  compare meter_mode with 5
    bne .L0800C798                          @ 0800C794  if meter_mode != 5
.L0800C796:  @ reached from 0800C780 blt (meter_mode <s 9), 0800C78A beq (meter_mode == 12 (0xC))
    adds r5, #0x10                          @ 0800C796  r5 = r5 + 16 (0x10)
.L0800C798:  @ reached from 0800C794 bne (meter_mode != 5)
    bl lcd_bar_negative                     @ IMP-15: the bar sign of the LCD (no bar lit: the sign of the digits)
    cbz r0, .L0800C7A4
    adds r5, r5, #0x4                       @ 0800C7A2  r5 = r5 + 4
.L0800C7A4:  @ reached from 0800C7A0 bpl (ble_bar_value >=0 0)
    ldr.w r0, =ble_bar_scale                @ 0800C7A4
    ldrb r0, [r0, #0x0]                     @ 0800C7A8  r0 = ble_bar_scale
    cmp r0, #0x3                            @ 0800C7AA  compare ble_bar_scale with 3
    bne .L0800C7B0                          @ 0800C7AC  if ble_bar_scale != 3
    adds r5, #0x8                           @ 0800C7AE  r5 = r5 + 8
.L0800C7B0:  @ reached from 0800C7AC bne (ble_bar_scale != 3)
    ldr.w r0, =ble_frame_b                  @ 0800C7B0
    strb r5, [r0, #0xd]                     @ 0800C7B4  ble_frame_b+13 = r5
    ldr.w r0, =ble_bar_count                @ 0800C7B6
    ldrb r0, [r0, #0x0]                     @ 0800C7BA  r0 = ble_bar_count
    cmp r0, #25
    it hi
    movhi r0, #25                           @ OF-65: the segments the display shows (1..25 lit from 25 up); v2.05 sends the raw
                                            @ count, 26..55 on an overload, which an app masking the byte reads as a short bar
    ldr.w r1, =ble_frame_b                  @ 0800C7BC
    strb r0, [r1, #0xe]                     @ 0800C7C0  ble_frame_b+14 = ble_bar_count
    ldr.w r0, =filter_1khz                  @ 0800C7C2
    ldrb r0, [r0, #0x0]                     @ 0800C7C6  r0 = filter_1khz
    cmp r0, #0x0                            @ 0800C7C8  compare filter_1khz with 0
    beq .L0800C7D2                          @ 0800C7CA  if filter_1khz == 0
    movs r0, #0x40                          @ 0800C7CC
    movs r5, r0                             @ 0800C7CE
    b .L0800C7D6                            @ 0800C7D0
.L0800C7D2:  @ reached from 0800C7CA beq (filter_1khz == 0)
    movs r0, #0x0                           @ 0800C7D2
    movs r5, r0                             @ 0800C7D4
.L0800C7D6:  @ reached from 0800C7D0 b
    ldr.w r0, =peak_hold                    @ 0800C7D6
    ldrb r0, [r0, #0x0]                     @ 0800C7DA  r0 = peak_hold
    cmp r0, #0x0                            @ 0800C7DC  compare peak_hold with 0
    beq .L0800C7E2                          @ 0800C7DE  if peak_hold == 0
    adds r5, #0x20                          @ 0800C7E0  r5 = r5 + 32 (0x20)
.L0800C7E2:  @ reached from 0800C7DE beq (peak_hold == 0)
    ldr.w r0, =acdc_active                  @ 0800C7E2
    ldrb r0, [r0, #0x0]                     @ 0800C7E6  r0 = acdc_active
    cmp r0, #0x0                            @ 0800C7E8  compare acdc_active with 0
    beq .L0800C7F0                          @ 0800C7EA  if acdc_active == 0
    adds r5, #0x18                          @ 0800C7EC  r5 = r5 + 24 (0x18)
    b .L0800C896                            @ 0800C7EE
.L0800C7F0:  @ reached from 0800C7EA beq (acdc_active == 0)
    ldr.w r0, =meter_mode                   @ 0800C7F0
    ldrb r0, [r0, #0x0]                     @ 0800C7F4  r0 = meter_mode
    cmp r0, #0x10                           @ 0800C7F6  compare meter_mode with 16 (0x10)
    beq .L0800C840                          @ 0800C7F8  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 0800C7FA
    ldrb r0, [r0, #0x0]                     @ 0800C7FE  r0 = meter_mode
    cmp r0, #0x12                           @ 0800C800  compare meter_mode with 18 (0x12)
    beq .L0800C840                          @ 0800C802  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 0800C804
    ldrb r0, [r0, #0x0]                     @ 0800C808  r0 = meter_mode
    cmp r0, #0x14                           @ 0800C80A  compare meter_mode with 20 (0x14)
    beq .L0800C840                          @ 0800C80C  if meter_mode == 20 (0x14)
    ldr.w r0, =meter_mode                   @ 0800C80E
    ldrb r0, [r0, #0x0]                     @ 0800C812  r0 = meter_mode
    cmp r0, #0x2                            @ 0800C814  compare meter_mode with 2
    beq .L0800C840                          @ 0800C816  if meter_mode == 2
    ldr.w r0, =meter_mode                   @ 0800C818
    ldrb r0, [r0, #0x0]                     @ 0800C81C  r0 = meter_mode
    cmp r0, #0x4                            @ 0800C81E  compare meter_mode with 4
    beq .L0800C840                          @ 0800C820  if meter_mode == 4
    ldr.w r0, =meter_mode                   @ 0800C822
    ldrb r0, [r0, #0x0]                     @ 0800C826  r0 = meter_mode
    cmp r0, #0xd                            @ 0800C828  compare meter_mode with 13 (0xD)
    beq .L0800C840                          @ 0800C82A  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 0800C82C
    ldrb r0, [r0, #0x0]                     @ 0800C830  r0 = meter_mode
    cmp r0, #0xe                            @ 0800C832  compare meter_mode with 14 (0xE)
    beq .L0800C840                          @ 0800C834  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 0800C836
    ldrb r0, [r0, #0x0]                     @ 0800C83A  r0 = meter_mode
    cmp r0, #0xf                            @ 0800C83C  compare meter_mode with 15 (0xF)
    bne .L0800C844                          @ 0800C83E  if meter_mode != 15 (0xF)
.L0800C840:  @ reached from 0800C7F8 beq (meter_mode == 16 (0x10)), 0800C802 beq (meter_mode == 18 (0x12)), 0800C80C beq (meter_mode == 20 (0x14)), 0800C816 beq (meter_mode == 2), 0800C820 beq (meter_mode == 4), 0800C82A beq (meter_mode == 13 (0xD)), 0800C834 beq (meter_mode == 14 (0xE))
    adds r5, #0x10                          @ 0800C840  r5 = r5 + 16 (0x10)
    b .L0800C896                            @ 0800C842
.L0800C844:  @ reached from 0800C83E bne (meter_mode != 15 (0xF))
    ldr.w r0, =meter_mode                   @ 0800C844
    ldrb r0, [r0, #0x0]                     @ 0800C848  r0 = meter_mode
    cmp r0, #0x11                           @ 0800C84A  compare meter_mode with 17 (0x11)
    beq .L0800C894                          @ 0800C84C  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 0800C84E
    ldrb r0, [r0, #0x0]                     @ 0800C852  r0 = meter_mode
    cmp r0, #0x13                           @ 0800C854  compare meter_mode with 19 (0x13)
    beq .L0800C894                          @ 0800C856  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 0800C858
    ldrb r0, [r0, #0x0]                     @ 0800C85C  r0 = meter_mode
    cmp r0, #0x15                           @ 0800C85E  compare meter_mode with 21 (0x15)
    beq .L0800C894                          @ 0800C860  if meter_mode == 21 (0x15)
    ldr.w r0, =meter_mode                   @ 0800C862
    ldrb r0, [r0, #0x0]                     @ 0800C866  r0 = meter_mode
    cmp r0, #0x1                            @ 0800C868  compare meter_mode with 1
    beq .L0800C894                          @ 0800C86A  if meter_mode == 1
    ldr.w r0, =meter_mode                   @ 0800C86C
    ldrb r0, [r0, #0x0]                     @ 0800C870  r0 = meter_mode
    cmp r0, #0x3                            @ 0800C872  compare meter_mode with 3
    beq .L0800C894                          @ 0800C874  if meter_mode == 3
    ldr.w r0, =meter_mode                   @ 0800C876
    ldrb r0, [r0, #0x0]                     @ 0800C87A  r0 = meter_mode
    cmp r0, #0x16                           @ 0800C87C  compare meter_mode with 22 (0x16)
    beq .L0800C894                          @ 0800C87E  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 0800C880
    ldrb r0, [r0, #0x0]                     @ 0800C884  r0 = meter_mode
    cmp r0, #0x17                           @ 0800C886  compare meter_mode with 23 (0x17)
    beq .L0800C894                          @ 0800C888  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 0800C88A
    ldrb r0, [r0, #0x0]                     @ 0800C88E  r0 = meter_mode
    cmp r0, #0x18                           @ 0800C890  compare meter_mode with 24 (0x18)
    bne .L0800C896                          @ 0800C892  if meter_mode != 24 (0x18)
.L0800C894:  @ reached from 0800C84C beq (meter_mode == 17 (0x11)), 0800C856 beq (meter_mode == 19 (0x13)), 0800C860 beq (meter_mode == 21 (0x15)), 0800C86A beq (meter_mode == 1), 0800C874 beq (meter_mode == 3), 0800C87E beq (meter_mode == 22 (0x16)), 0800C888 beq (meter_mode == 23 (0x17))
    adds r5, #0x8                           @ 0800C894  r5 = r5 + 8
.L0800C896:  @ reached from 0800C7EE b, 0800C842 b, 0800C892 bne (meter_mode != 24 (0x18))
    bl fn_08019DA2                          @ 0800C896  auto-range active predicate (1 = AUTO lit)
    cmp r0, #0x0                            @ 0800C89A  compare r0 with 0
    beq .L0800C8A0                          @ 0800C89C  if r0 == 0
    adds r5, r5, #0x4                       @ 0800C89E  r5 = r5 + 4
.L0800C8A0:  @ reached from 0800C89C beq (r0 == 0)
    ldr.w r0, =ble_apo_disable              @ 0800C8A0
    ldrb r0, [r0, #0x0]                     @ 0800C8A4  r0 = ble_apo_disable
    cmp r0, #0x0                            @ 0800C8A6  compare ble_apo_disable with 0
    bne .L0800C8AC                          @ 0800C8A8  if ble_apo_disable != 0
    adds r5, r5, #0x2                       @ 0800C8AA  r5 = r5 + 2
.L0800C8AC:  @ reached from 0800C8A8 bne (ble_apo_disable != 0)
    ldr.w r0, =ble_bat_low                  @ 0800C8AC
    ldrb r0, [r0, #0x0]                     @ 0800C8B0  r0 = ble_bat_low
    cmp r0, #0x0                            @ 0800C8B2  compare ble_bat_low with 0
    beq .L0800C8B8                          @ 0800C8B4  if ble_bat_low == 0
    adds r5, r5, #0x1                       @ 0800C8B6  r5 = r5 + 1
.L0800C8B8:  @ reached from 0800C8B4 beq (ble_bat_low == 0)
    ldr.w r0, =ble_frame_b                  @ 0800C8B8
    strb r5, [r0, #0xf]                     @ 0800C8BC  ble_frame_b+15 = r5
    ldr.w r0, =ble_enable                   @ 0800C8BE
    ldrb r0, [r0, #0x0]                     @ 0800C8C2  r0 = ble_enable
    cmp r0, #0x0                            @ 0800C8C4  compare ble_enable with 0
    beq .L0800C8CE                          @ 0800C8C6  if ble_enable == 0
    movs r0, #0x40                          @ 0800C8C8
    movs r5, r0                             @ 0800C8CA
    b .L0800C8D2                            @ 0800C8CC
.L0800C8CE:  @ reached from 0800C8C6 beq (ble_enable == 0)
    movs r0, #0x0                           @ 0800C8CE
    movs r5, r0                             @ 0800C8D0
.L0800C8D2:  @ reached from 0800C8CC b
    ldr.w r0, =v_200080B1                   @ 0800C8D2
    ldrb r0, [r0, #0x0]                     @ 0800C8D6  r0 = v_200080B1
    cmp r0, #0x0                            @ 0800C8D8  compare v_200080B1 with 0
    beq .L0800C8DE                          @ 0800C8DA  if v_200080B1 == 0
    adds r5, #0x20                          @ 0800C8DC  r5 = r5 + 32 (0x20)
.L0800C8DE:  @ reached from 0800C8DA beq (v_200080B1 == 0)
    ldr.w r0, =rel_active                   @ 0800C8DE
    ldrb r0, [r0, #0x0]                     @ 0800C8E2  r0 = rel_active
    cmp r0, #0x0                            @ 0800C8E4  compare rel_active with 0
    beq .L0800C8EA                          @ 0800C8E6  if rel_active == 0
    adds r5, #0x10                          @ 0800C8E8  r5 = r5 + 16 (0x10)
.L0800C8EA:  @ reached from 0800C8E6 beq (rel_active == 0)
    ldr.w r0, =meter_mode                   @ 0800C8EA
    ldrb r0, [r0, #0x0]                     @ 0800C8EE  r0 = meter_mode
    cmp r0, #0x2                            @ 0800C8F0  compare meter_mode with 2
    bne .L0800C900                          @ 0800C8F2  if meter_mode != 2
    ldr.w r0, =ble_item                     @ 0800C8F4
    ldrb r0, [r0, #0x0]                     @ 0800C8F8  r0 = ble_item
    cmp r0, #0xb                            @ 0800C8FA  compare ble_item with 11 (0xB)
    bne .L0800C900                          @ 0800C8FC  if ble_item != 11 (0xB)
    adds r5, #0x8                           @ 0800C8FE  r5 = r5 + 8
.L0800C900:  @ reached from 0800C8F2 bne (meter_mode != 2), 0800C8FC bne (ble_item != 11 (0xB))
    ldr.w r0, =peak_hold                    @ 0800C900
    ldrb r0, [r0, #0x0]                     @ 0800C904  r0 = peak_hold
    cmp r0, #0x0                            @ 0800C906  compare peak_hold with 0
    beq .L0800C91C                          @ 0800C908  if peak_hold == 0
    ldr.w r0, =peak_show_min                @ 0800C90A
    ldrb r0, [r0, #0x0]                     @ 0800C90E  r0 = peak_show_min
    cmp r0, #0x0                            @ 0800C910  compare peak_show_min with 0
    beq .L0800C918                          @ 0800C912  if peak_show_min == 0
    adds r5, r5, #0x2                       @ 0800C914  r5 = r5 + 2
    b .L0800C92E                            @ 0800C916
.L0800C918:  @ reached from 0800C912 beq (peak_show_min == 0)
    adds r5, r5, #0x1                       @ 0800C918  r5 = r5 + 1
    b .L0800C92E                            @ 0800C91A
.L0800C91C:  @ reached from 0800C908 beq (peak_hold == 0)
    ldr.w r0, =minmax_state                 @ 0800C91C
    ldrb r0, [r0, #0x0]                     @ 0800C920  r0 = minmax_state
    cmp r0, #0x0                            @ 0800C922  compare minmax_state with 0
    beq .L0800C92E                          @ 0800C924  if minmax_state == 0
    ldr.w r0, =minmax_state                 @ 0800C926
    ldrb r0, [r0, #0x0]                     @ 0800C92A  r0 = minmax_state
    adds r5, r0, r5                         @ 0800C92C  r5 = minmax_state + r5
.L0800C92E:  @ reached from 0800C916 b, 0800C91A b, 0800C924 beq (minmax_state == 0)
    ldr.w r0, =ble_frame_b                  @ 0800C92E
    strb r5, [r0, #0x10]                    @ 0800C932  ble_frame_b+16 = r5
    bl fn_0801A028                          @ 0800C934  hold state 0..2 [r0=&ble_frame_b]
    movs r5, r0                             @ 0800C938
    lsls r5, r5, #0x2                       @ 0800C93A  r5 = r5 << 2
    ldr.w r0, =v_20007FE1                   @ 0800C93C
    ldrb r0, [r0, #0x0]                     @ 0800C940  r0 = v_20007FE1
    ldr.w r1, =v_20007FE3                   @ 0800C942
    ldrb r1, [r1, #0x0]                     @ 0800C946  r1 = v_20007FE3
    ands r0, r1                             @ 0800C948  r0 = v_20007FE1 & v_20007FE3
    ldr.w r1, =v_20007FE4                   @ 0800C94A
    ldrb r1, [r1, #0x0]                     @ 0800C94E  r1 = v_20007FE4
    orrs r0, r1                             @ 0800C950  r0 = (v_20007FE1 & v_20007FE3) | v_20007FE4
    uxtb r0, r0                             @ 0800C952
    cmp r0, #0x0                            @ 0800C954  compare ((v_20007FE1 & v_20007FE3) | v_20007FE4) with 0
    beq .L0800C95A                          @ 0800C956  if ((v_20007FE1 & v_20007FE3) | v_20007FE4) == 0
    adds r5, #0x10                          @ 0800C958  r5 = (r5 << 2) + 16 (0x10)
.L0800C95A:  @ reached from 0800C956 beq (((v_20007FE1 & v_20007FE3) | v_20007FE4) == 0)
    ldr.w r0, =ble_frame_b                  @ 0800C95A
    strb r5, [r0, #0x11]                    @ 0800C95E  ble_frame_b+17 = r5
    ldr.w r0, =ble_frame_b                  @ 0800C960
    ldrb r0, [r0, #0x0]                     @ 0800C964  r0 = ble_frame_b
    ldr.w r1, =ble_xor                      @ 0800C966
    strb r0, [r1, #0x0]                     @ 0800C96A  ble_xor = ble_frame_b
    movs r0, #0x1                           @ 0800C96C
    movs r4, r0                             @ 0800C96E
.L0800C970:  @ reached from 0800C98E b
    uxtb r4, r4                             @ 0800C970
    cmp r4, #0x12                           @ 0800C972  compare r4 with 18 (0x12)
    bge .L0800C990                          @ 0800C974  if r4 >=s 18 (0x12)
    ldr.w r0, =ble_xor                      @ 0800C976
    ldrb r0, [r0, #0x0]                     @ 0800C97A  r0 = ble_xor
    ldr.w r1, =ble_frame_b                  @ 0800C97C
    uxtb r4, r4                             @ 0800C980
    ldrb r1, [r1, r4]                       @ 0800C982  r1 = ble_frame_b[r4]
    eors r0, r1                             @ 0800C984  r0 = ble_xor ^ r1
    ldr.w r1, =ble_xor                      @ 0800C986
    strb r0, [r1, #0x0]                     @ 0800C98A  ble_xor = (ble_xor ^ r1)
    adds r4, r4, #0x1                       @ 0800C98C  r4 = r4 + 1
    b .L0800C970                            @ 0800C98E
.L0800C990:  @ reached from 0800C974 bge (r4 >=s 18 (0x12))
    ldr.w r0, =ble_xor                      @ 0800C990
    ldrb r0, [r0, #0x0]                     @ 0800C994  r0 = ble_xor
    ldr.w r1, =ble_frame_b                  @ 0800C996
    strb r0, [r1, #0x12]                    @ 0800C99A  ble_frame_b+18 = ble_xor
        bl ble_value_valid                   @ OF-34: r0 = 1 if the value is a reading @ 0800C99C
        cbz r0, .Lbsp_invalid                @ blank phase: keep the frame back @         
        movs r0, #1                         @         
        ldr r1, =ble_frame_ready            @         
        strb r0, [r1]                        @ OF-10: frame complete @         
    .Lbsp_invalid:                          @         
        pop {r4, r5, r6, pc}                @         
ENDFUNC build_status_packet_19b
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800C99E - sub display case 0: temperature
@ Replaces : 0x0800C99E FUN_0800C99E (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_temp_celsius, ble_temp_flag, ble_temp_value; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800C99E
    push {r4, r5, r6, lr}                   @ 0800C99E
    movs r4, r0                             @ 0800C9A0
    ldr.w r0, =ble_temp_celsius             @ 0800C9A2
    ldrb r0, [r0, #0x0]                     @ 0800C9A6  r0 = ble_temp_celsius
    cmp r0, #0x0                            @ 0800C9A8  compare ble_temp_celsius with 0
    beq .L0800C9B2                          @ 0800C9AA  if ble_temp_celsius == 0
    movs r0, #0x64                          @ 0800C9AC
    movs r5, r0                             @ 0800C9AE
    b .L0800C9B6                            @ 0800C9B0
.L0800C9B2:  @ reached from 0800C9AA beq (ble_temp_celsius == 0)
    movs r0, #0x69                          @ 0800C9B2
    movs r5, r0                             @ 0800C9B4
.L0800C9B6:  @ reached from 0800C9B0 b
    ldr.w r0, =ble_frame_b                  @ 0800C9B6
    uxtb r4, r4                             @ 0800C9BA
    strb r5, [r0, r4]                       @ 0800C9BC  ble_frame_b[r4] = r5
    ldr.w r0, =ble_temp_value               @ 0800C9BE
    ldrsh r0, [r0, #0x0]                    @ 0800C9C2  r0 = ble_temp_value
    bl fn_08018AD8                          @ 0800C9C6  temperature for display (C or F, rounded to 0.1) [r0=ble_temp_value]
    movs r6, r0                             @ 0800C9CA
    movs r0, #0x1                           @ 0800C9CC
    movs r5, r0                             @ 0800C9CE
    ldr.w r0, =ble_temp_flag                @ 0800C9D0
    ldrb r0, [r0, #0x0]                     @ 0800C9D4  r0 = ble_temp_flag
    cmp r0, #0x0                            @ 0800C9D6  compare ble_temp_flag with 0
    beq .L0800C9DC                          @ 0800C9D8  if ble_temp_flag == 0
    subs r5, #0x80                          @ 0800C9DA  r5 = 1 - 128 (0x80)
.L0800C9DC:  @ reached from 0800C9D8 beq (ble_temp_flag == 0)
    sxth r6, r6                             @ 0800C9DC
    cmp r6, #0x0                            @ 0800C9DE  compare r6 with 0
    bpl .L0800C9E4                          @ 0800C9E0  if r6 >=0 0
    adds r5, #0x40                          @ 0800C9E2  r5 = r5 + 64 (0x40)
.L0800C9E4:  @ reached from 0800C9E0 bpl (r6 >=0 0)
    ldr.w r0, =ble_frame_b                  @ 0800C9E4
    uxtb r4, r4                             @ 0800C9E8
    add r0, r4                              @ 0800C9EA  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800C9EC  [r0+1] = r5
    sxth r6, r6                             @ 0800C9EE
    movs r1, r6                             @ 0800C9F0
    adds r0, r4, #0x2                       @ 0800C9F2  r0 = r4 + 2
    uxtb r0, r0                             @ 0800C9F4
    bl fn_0800D100                          @ 0800C9F6  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2)]
    pop {r4, r5, r6, pc}                    @ 0800C9FA
ENDFUNC fn_0800C99E
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800C9FC - sub display case 1: battery value
@ Replaces : 0x0800C9FC FUN_0800C9FC (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_bat_value; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800C9FC
    push {r3, r4, r5, lr}                   @ 0800C9FC
    movs r4, r0                             @ 0800C9FE
    movs r0, #0x6e                          @ 0800CA00
    movs r5, r0                             @ 0800CA02
    ldr.w r0, =ble_frame_b                  @ 0800CA04
    uxtb r4, r4                             @ 0800CA08
    strb r5, [r0, r4]                       @ 0800CA0A  ble_frame_b[r4] = 110 (0x6E)
    movs r0, #0x1                           @ 0800CA0C
    movs r5, r0                             @ 0800CA0E
    ldr.w r0, =ble_frame_b                  @ 0800CA10
    uxtb r4, r4                             @ 0800CA14
    add r0, r4                              @ 0800CA16  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800CA18  [r0+1] = 1
    ldr.w r0, =ble_bat_value                @ 0800CA1A
    ldrh r1, [r0, #0x0]                     @ 0800CA1E  r1 = ble_bat_value
    adds r0, r4, #0x2                       @ 0800CA20  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CA22
    bl fn_0800D100                          @ 0800CA24  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=ble_bat_value]
    pop {r0, r4, r5, pc}                    @ 0800CA28
ENDFUNC fn_0800C9FC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CA2A - sub display case 2: APO state
@ Replaces : 0x0800CA2A FUN_0800CA2A (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_apo_disable; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CA2A
    push {r3, r4, r5, lr}                   @ 0800CA2A
    movs r4, r0                             @ 0800CA2C
    ldr.w r0, =ble_apo_disable              @ 0800CA2E
    ldrb r0, [r0, #0x0]                     @ 0800CA32  r0 = ble_apo_disable
    cmp r0, #0x0                            @ 0800CA34  compare ble_apo_disable with 0
    beq .L0800CA3E                          @ 0800CA36  if ble_apo_disable == 0
    movs r0, #0x7d                          @ 0800CA38
    movs r5, r0                             @ 0800CA3A
    b .L0800CA42                            @ 0800CA3C
.L0800CA3E:  @ reached from 0800CA36 beq (ble_apo_disable == 0)
    movs r0, #0x78                          @ 0800CA3E
    movs r5, r0                             @ 0800CA40
.L0800CA42:  @ reached from 0800CA3C b
    ldr.w r0, =ble_frame_b                  @ 0800CA42
    uxtb r4, r4                             @ 0800CA46
    strb r5, [r0, r4]                       @ 0800CA48  ble_frame_b[r4] = r5
    movs r0, #0x2                           @ 0800CA4A
    movs r5, r0                             @ 0800CA4C
    ldr.w r0, =ble_frame_b                  @ 0800CA4E
    uxtb r4, r4                             @ 0800CA52
    add r0, r4                              @ 0800CA54  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800CA56  [r0+1] = 2
    movs r1, #0x0                           @ 0800CA58
    adds r0, r4, #0x2                       @ 0800CA5A  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CA5C
    bl fn_0800D100                          @ 0800CA5E  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=0]
    pop {r0, r4, r5, pc}                    @ 0800CA62
ENDFUNC fn_0800CA2A
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CA64 - sub display case 4: contrast
@ Replaces : 0x0800CA64 FUN_0800CA64 (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads lcd_contrast; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CA64
    push {r3, r4, r5, lr}                   @ 0800CA64
    movs r4, r0                             @ 0800CA66
    movs r0, #0xa0                          @ 0800CA68
    movs r5, r0                             @ 0800CA6A
    ldr.w r0, =ble_frame_b                  @ 0800CA6C
    uxtb r4, r4                             @ 0800CA70
    strb r5, [r0, r4]                       @ 0800CA72  ble_frame_b[r4] = 160 (0xA0)
    movs r0, #0x0                           @ 0800CA74
    movs r5, r0                             @ 0800CA76
    ldr.w r0, =ble_frame_b                  @ 0800CA78
    uxtb r4, r4                             @ 0800CA7C
    add r0, r4                              @ 0800CA7E  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800CA80  [r0+1] = 0
    ldr.w r0, =lcd_contrast                 @ 0800CA82
    ldrb r0, [r0, #0x0]                     @ 0800CA86  r0 = lcd_contrast
    subs r1, r0, #0xa                       @ 0800CA88  r1 = lcd_contrast - 10 (0xA)
    adds r0, r4, #0x2                       @ 0800CA8C  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CA8E
    bl fn_0800D100                          @ 0800CA90  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=(lcd_contrast - 10 (0xA))]
    pop {r0, r4, r5, pc}                    @ 0800CA94
ENDFUNC fn_0800CA64
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CA96 - sub display case 5: year
@ Replaces : 0x0800CA96 FUN_0800CA96 (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_year; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CA96
    push {r3, r4, r5, lr}                   @ 0800CA96
    movs r4, r0                             @ 0800CA98
    movs r0, #0x82                          @ 0800CA9A
    movs r5, r0                             @ 0800CA9C
    ldr.w r0, =ble_frame_b                  @ 0800CA9E
    uxtb r4, r4                             @ 0800CAA2
    strb r5, [r0, r4]                       @ 0800CAA4  ble_frame_b[r4] = 130 (0x82)
    movs r0, #0x0                           @ 0800CAA6
    movs r5, r0                             @ 0800CAA8
    ldr.w r0, =ble_frame_b                  @ 0800CAAA
    uxtb r4, r4                             @ 0800CAAE
    add r0, r4                              @ 0800CAB0  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800CAB2  [r0+1] = 0
    ldr.w r0, =ble_year                     @ 0800CAB4
    ldrb r1, [r0, #0x0]                     @ 0800CAB8  r1 = ble_year
    adds r0, r4, #0x2                       @ 0800CABA  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CABC
    bl fn_0800D100                          @ 0800CABE  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=ble_year]
    pop {r0, r4, r5, pc}                    @ 0800CAC2
ENDFUNC fn_0800CA96
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CAC4 - sub display case 6: month and day
@ Replaces : 0x0800CAC4 FUN_0800CAC4 (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_day, ble_month; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CAC4
    movs r2, #0x87                          @ 0800CAC4
    movs r1, r2                             @ 0800CAC6
    ldr.w r2, =ble_frame_b                  @ 0800CAC8
    uxtb r0, r0                             @ 0800CACC
    strb r1, [r2, r0]                       @ 0800CACE  ble_frame_b[r0] = 135 (0x87)
    movs r2, #0x0                           @ 0800CAD0
    movs r1, r2                             @ 0800CAD2
    ldr.w r2, =ble_frame_b                  @ 0800CAD4
    uxtb r0, r0                             @ 0800CAD8
    add r2, r0                              @ 0800CADA  r2 = &ble_frame_b + r0
    strb r1, [r2, #0x1]                     @ 0800CADC  [r2+1] = 0
    ldr.w r2, =ble_month                    @ 0800CADE
    ldrb r2, [r2, #0x0]                     @ 0800CAE2  r2 = ble_month
    movs r1, r2                             @ 0800CAE4
    ldr.w r2, =ble_frame_b                  @ 0800CAE6
    uxtb r0, r0                             @ 0800CAEA
    add r2, r0                              @ 0800CAEC  r2 = &ble_frame_b + r0
    strb r1, [r2, #0x2]                     @ 0800CAEE  [r2+2] = ble_month
    ldr.w r2, =ble_day                      @ 0800CAF0
    ldrb r2, [r2, #0x0]                     @ 0800CAF4  r2 = ble_day
    movs r1, r2                             @ 0800CAF6
    ldr.w r2, =ble_frame_b                  @ 0800CAF8
    uxtb r0, r0                             @ 0800CAFC
    add r2, r0                              @ 0800CAFE  r2 = &ble_frame_b + r0
    strb r1, [r2, #0x3]                     @ 0800CB00  [r2+3] = ble_day
    bx lr                                   @ 0800CB02
ENDFUNC fn_0800CAC4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CB04 - sub display case 7: hour and minute
@ Replaces : 0x0800CB04 FUN_0800CB04 (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_hour, ble_minute; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CB04
    movs r2, #0x8c                          @ 0800CB04
    movs r1, r2                             @ 0800CB06
    ldr.w r2, =ble_frame_b                  @ 0800CB08
    uxtb r0, r0                             @ 0800CB0C
    strb r1, [r2, r0]                       @ 0800CB0E  ble_frame_b[r0] = 140 (0x8C)
    movs r2, #0x0                           @ 0800CB10
    movs r1, r2                             @ 0800CB12
    ldr.w r2, =ble_frame_b                  @ 0800CB14
    uxtb r0, r0                             @ 0800CB18
    add r2, r0                              @ 0800CB1A  r2 = &ble_frame_b + r0
    strb r1, [r2, #0x1]                     @ 0800CB1C  [r2+1] = 0
    ldr.w r2, =ble_hour                     @ 0800CB1E
    ldrb r2, [r2, #0x0]                     @ 0800CB22  r2 = ble_hour
    movs r1, r2                             @ 0800CB24
    ldr.w r2, =ble_frame_b                  @ 0800CB26
    uxtb r0, r0                             @ 0800CB2A
    add r2, r0                              @ 0800CB2C  r2 = &ble_frame_b + r0
    strb r1, [r2, #0x2]                     @ 0800CB2E  [r2+2] = ble_hour
    ldr.w r2, =ble_minute                   @ 0800CB30
    ldrb r2, [r2, #0x0]                     @ 0800CB34  r2 = ble_minute
    movs r1, r2                             @ 0800CB36
    ldr.w r2, =ble_frame_b                  @ 0800CB38
    uxtb r0, r0                             @ 0800CB3C
    add r2, r0                              @ 0800CB3E  r2 = &ble_frame_b + r0
    strb r1, [r2, #0x3]                     @ 0800CB40  [r2+3] = ble_minute
    bx lr                                   @ 0800CB42
ENDFUNC fn_0800CB04
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CB44 - sub display case 10: mode dependent value or option
@ Replaces : 0x0800CB44 FUN_0800CB44 (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads acdc_active, ble_cont_code, ble_cur_opt, ble_diode_15v, ble_sub_dp, ble_sub_ovl, ble_sub_value,
@            ble_va_sub, meter_mode; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CB44
    push {r3, r4, r5, lr}                   @ 0800CB44
    movs r4, r0                             @ 0800CB46
    ldr.w r0, =meter_mode                   @ 0800CB48
    ldrb r0, [r0, #0x0]                     @ 0800CB4C  r0 = meter_mode
    cmp r0, #0x4                            @ 0800CB4E  compare meter_mode with 4
    beq .L0800CB66                          @ 0800CB50  if meter_mode == 4
    ldr.w r0, =meter_mode                   @ 0800CB52
    ldrb r0, [r0, #0x0]                     @ 0800CB56  r0 = meter_mode
    cmp r0, #0x2                            @ 0800CB58  compare meter_mode with 2
    bne .L0800CB88                          @ 0800CB5A  if meter_mode != 2
    ldr.w r0, =acdc_active                  @ 0800CB5C
    ldrb r0, [r0, #0x0]                     @ 0800CB60  r0 = acdc_active
    cmp r0, #0x0                            @ 0800CB62  compare acdc_active with 0
    bne .L0800CB88                          @ 0800CB64  if acdc_active != 0
.L0800CB66:  @ reached from 0800CB50 beq (meter_mode == 4)
    ldr.w r0, =ble_sub_value                @ 0800CB66
    ldr r0, [r0, #0x0]                      @ 0800CB6A  r0 = ble_sub_value
    movs r1, #0xa                           @ 0800CB6C
    sdiv r3, r0, r1                         @ 0800CB6E  r3 = ble_sub_value / 10 (0xA)
    ldr.w r0, =ble_sub_ovl                  @ 0800CB72
    ldrb r2, [r0, #0x0]                     @ 0800CB76  r2 = ble_sub_ovl
    ldr.w r0, =ble_sub_dp                   @ 0800CB78
    ldrb r1, [r0, #0x0]                     @ 0800CB7C  r1 = ble_sub_dp
    movs r0, r4                             @ 0800CB7E
    uxtb r0, r0                             @ 0800CB80
    bl fn_0800CE78                          @ 0800CB82  sub display helper for the value of modes 2 and 4 [r1=ble_sub_dp, r2=ble_sub_ovl, r3=(ble_sub_value / 10 (0xA))]
    b .L0800CCC2                            @ 0800CB86
.L0800CB88:  @ reached from 0800CB5A bne (meter_mode != 2), 0800CB64 bne (acdc_active != 0)
    ldr.w r0, =meter_mode                   @ 0800CB88
    ldrb r0, [r0, #0x0]                     @ 0800CB8C  r0 = meter_mode
    cmp r0, #0xa                            @ 0800CB8E  compare meter_mode with 10 (0xA)
    bne .L0800CBBE                          @ 0800CB90  if meter_mode != 10 (0xA)
    ldr.w r0, =ble_cont_code                @ 0800CB92
    ldrb r0, [r0, #0x0]                     @ 0800CB96  r0 = ble_cont_code
    subs r0, #0x56                          @ 0800CB98  r0 = ble_cont_code - 86 (0x56)
    movs r5, r0                             @ 0800CB9A
    ldr.w r0, =ble_frame_b                  @ 0800CB9C
    uxtb r4, r4                             @ 0800CBA0
    strb r5, [r0, r4]                       @ 0800CBA2  ble_frame_b[r4] = (ble_cont_code - 86 (0x56))
    movs r0, #0x0                           @ 0800CBA4
    movs r5, r0                             @ 0800CBA6
    ldr.w r0, =ble_frame_b                  @ 0800CBA8
    uxtb r4, r4                             @ 0800CBAC
    add r0, r4                              @ 0800CBAE  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800CBB0  [r0+1] = 0
    movs r1, #0x0                           @ 0800CBB2
    adds r0, r4, #0x2                       @ 0800CBB4  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CBB6
    bl fn_0800D100                          @ 0800CBB8  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=0]
    b .L0800CCC2                            @ 0800CBBC
.L0800CBBE:  @ reached from 0800CB90 bne (meter_mode != 10 (0xA))
    ldr.w r0, =meter_mode                   @ 0800CBBE
    ldrb r0, [r0, #0x0]                     @ 0800CBC2  r0 = meter_mode
    cmp r0, #0xb                            @ 0800CBC4  compare meter_mode with 11 (0xB)
    bne .L0800CC04                          @ 0800CBC6  if meter_mode != 11 (0xB)
    movs r0, #0xb                           @ 0800CBC8
    movs r5, r0                             @ 0800CBCA
    ldr.w r0, =ble_frame_b                  @ 0800CBCC
    uxtb r4, r4                             @ 0800CBD0
    strb r5, [r0, r4]                       @ 0800CBD2  ble_frame_b[r4] = 11 (0xB)
    movs r0, #0x0                           @ 0800CBD4
    movs r5, r0                             @ 0800CBD6
    ldr.w r0, =ble_frame_b                  @ 0800CBD8
    uxtb r4, r4                             @ 0800CBDC
    add r0, r4                              @ 0800CBDE  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800CBE0  [r0+1] = 0
    ldr.w r0, =ble_diode_15v                @ 0800CBE2
    ldrb r0, [r0, #0x0]                     @ 0800CBE6  r0 = ble_diode_15v
    cmp r0, #0x0                            @ 0800CBE8  compare ble_diode_15v with 0
    beq .L0800CBF8                          @ 0800CBEA  if ble_diode_15v == 0
    movs r1, #0xf                           @ 0800CBEC
    adds r0, r4, #0x2                       @ 0800CBEE  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CBF0
    bl fn_0800D100                          @ 0800CBF2  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=15 (0xF)]
    b .L0800CCC2                            @ 0800CBF6
.L0800CBF8:  @ reached from 0800CBEA beq (ble_diode_15v == 0)
    movs r1, #0x3                           @ 0800CBF8
    adds r0, r4, #0x2                       @ 0800CBFA  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CBFC
    bl fn_0800D100                          @ 0800CBFE  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=3]
    b .L0800CCC2                            @ 0800CC02
.L0800CC04:  @ reached from 0800CBC6 bne (meter_mode != 11 (0xB))
    ldr.w r0, =meter_mode                   @ 0800CC04
    ldrb r0, [r0, #0x0]                     @ 0800CC08  r0 = meter_mode
    cmp r0, #0xd                            @ 0800CC0A  compare meter_mode with 13 (0xD)
    beq .L0800CC40                          @ 0800CC0C  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 0800CC0E
    ldrb r0, [r0, #0x0]                     @ 0800CC12  r0 = meter_mode
    cmp r0, #0xe                            @ 0800CC14  compare meter_mode with 14 (0xE)
    beq .L0800CC40                          @ 0800CC16  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 0800CC18
    ldrb r0, [r0, #0x0]                     @ 0800CC1C  r0 = meter_mode
    cmp r0, #0xf                            @ 0800CC1E  compare meter_mode with 15 (0xF)
    beq .L0800CC40                          @ 0800CC20  if meter_mode == 15 (0xF)
    ldr.w r0, =meter_mode                   @ 0800CC22
    ldrb r0, [r0, #0x0]                     @ 0800CC26  r0 = meter_mode
    cmp r0, #0x16                           @ 0800CC28  compare meter_mode with 22 (0x16)
    beq .L0800CC40                          @ 0800CC2A  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 0800CC2C
    ldrb r0, [r0, #0x0]                     @ 0800CC30  r0 = meter_mode
    cmp r0, #0x17                           @ 0800CC32  compare meter_mode with 23 (0x17)
    beq .L0800CC40                          @ 0800CC34  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 0800CC36
    ldrb r0, [r0, #0x0]                     @ 0800CC3A  r0 = meter_mode
    cmp r0, #0x18                           @ 0800CC3C  compare meter_mode with 24 (0x18)
    bne .L0800CC6E                          @ 0800CC3E  if meter_mode != 24 (0x18)
.L0800CC40:  @ reached from 0800CC0C beq (meter_mode == 13 (0xD)), 0800CC16 beq (meter_mode == 14 (0xE)), 0800CC20 beq (meter_mode == 15 (0xF)), 0800CC2A beq (meter_mode == 22 (0x16)), 0800CC34 beq (meter_mode == 23 (0x17))
    ldr.w r0, =ble_va_sub                   @ 0800CC40
    ldrb r0, [r0, #0x0]                     @ 0800CC44  r0 = ble_va_sub
    cmp r0, #0x0                            @ 0800CC46  compare ble_va_sub with 0
    bne .L0800CC5C                          @ 0800CC48  if ble_va_sub != 0
    movs r2, #0x0                           @ 0800CC4A
    ldr.w r0, =ble_sub_dp                   @ 0800CC4C
    ldrb r1, [r0, #0x0]                     @ 0800CC50  r1 = ble_sub_dp
    movs r0, r4                             @ 0800CC52
    uxtb r0, r0                             @ 0800CC54
    bl fn_0800CEFC                          @ 0800CC56  sub display VA helper (voltage) [r1=ble_sub_dp, r2=0]
    b .L0800CCC2                            @ 0800CC5A
.L0800CC5C:  @ reached from 0800CC48 bne (ble_va_sub != 0)
    movs r2, #0x0                           @ 0800CC5C
    ldr.w r0, =ble_sub_dp                   @ 0800CC5E
    ldrb r1, [r0, #0x0]                     @ 0800CC62  r1 = ble_sub_dp
    movs r0, r4                             @ 0800CC64
    uxtb r0, r0                             @ 0800CC66
    bl fn_0800CFB0                          @ 0800CC68  sub display VA helper (current) [r1=ble_sub_dp, r2=0]
    b .L0800CCC2                            @ 0800CC6C
.L0800CC6E:  @ reached from 0800CC3E bne (meter_mode != 24 (0x18))
    ldr.w r0, =meter_mode                   @ 0800CC6E
    ldrb r0, [r0, #0x0]                     @ 0800CC72  r0 = meter_mode
    cmp r0, #0x10                           @ 0800CC74  compare meter_mode with 16 (0x10)
    beq .L0800CCAA                          @ 0800CC76  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 0800CC78
    ldrb r0, [r0, #0x0]                     @ 0800CC7C  r0 = meter_mode
    cmp r0, #0x12                           @ 0800CC7E  compare meter_mode with 18 (0x12)
    beq .L0800CCAA                          @ 0800CC80  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 0800CC82
    ldrb r0, [r0, #0x0]                     @ 0800CC86  r0 = meter_mode
    cmp r0, #0x14                           @ 0800CC88  compare meter_mode with 20 (0x14)
    beq .L0800CCAA                          @ 0800CC8A  if meter_mode == 20 (0x14)
    ldr.w r0, =meter_mode                   @ 0800CC8C
    ldrb r0, [r0, #0x0]                     @ 0800CC90  r0 = meter_mode
    cmp r0, #0x11                           @ 0800CC92  compare meter_mode with 17 (0x11)
    beq .L0800CCAA                          @ 0800CC94  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 0800CC96
    ldrb r0, [r0, #0x0]                     @ 0800CC9A  r0 = meter_mode
    cmp r0, #0x13                           @ 0800CC9C  compare meter_mode with 19 (0x13)
    beq .L0800CCAA                          @ 0800CC9E  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 0800CCA0
    ldrb r0, [r0, #0x0]                     @ 0800CCA4  r0 = meter_mode
    cmp r0, #0x15                           @ 0800CCA6  compare meter_mode with 21 (0x15)
    bne .L0800CCBA                          @ 0800CCA8  if meter_mode != 21 (0x15)
.L0800CCAA:  @ reached from 0800CC76 beq (meter_mode == 16 (0x10)), 0800CC80 beq (meter_mode == 18 (0x12)), 0800CC8A beq (meter_mode == 20 (0x14)), 0800CC94 beq (meter_mode == 17 (0x11)), 0800CC9E beq (meter_mode == 19 (0x13))
    ldr.w r0, =ble_cur_opt                  @ 0800CCAA
    ldrb r1, [r0, #0x0]                     @ 0800CCAE  r1 = ble_cur_opt
    movs r0, r4                             @ 0800CCB0
    uxtb r0, r0                             @ 0800CCB2
    bl fn_0800CE32                          @ 0800CCB4  sub display code 0x9B / 0x9C helper [r1=ble_cur_opt]
    b .L0800CCC2                            @ 0800CCB8
.L0800CCBA:  @ reached from 0800CCA8 bne (meter_mode != 21 (0x15))
    movs r0, r4                             @ 0800CCBA
    uxtb r0, r0                             @ 0800CCBC
    bl fn_0800D0C8                          @ 0800CCBE  sub display empty (zeros)
.L0800CCC2:  @ reached from 0800CB86 b, 0800CBBC b, 0800CBF6 b, 0800CC02 b, 0800CC5A b, 0800CC6C b, 0800CCB8 b
    pop {r0, r4, r5, pc}                    @ 0800CCC2
ENDFUNC fn_0800CB44
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CCC8 - sub display case 11: mode dependent value or option
@ Replaces : 0x0800CCC8 FUN_0800CCC8 (v2.05)
@ In       : r0 = first frame index (9)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_acv_scaled, ble_cur_opt, ble_ovl, ble_sub_dp, ble_sub_ovl, ble_sub_value, ble_va_bd,
@            meter_mode; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CCC8
    push {r4, r5, r6, lr}                   @ 0800CCC8
    movs r4, r0                             @ 0800CCCA
    ldr.w r0, =meter_mode                   @ 0800CCCC
    ldrb r0, [r0, #0x0]                     @ 0800CCD0  r0 = meter_mode
    cmp r0, #0x2                            @ 0800CCD2  compare meter_mode with 2
    bne .L0800CD36                          @ 0800CCD4  if meter_mode != 2
    movs r0, #0xb4                          @ 0800CCD6
    movs r5, r0                             @ 0800CCD8
    ldr.w r0, =ble_frame_b                  @ 0800CCDA
    uxtb r4, r4                             @ 0800CCDE
    strb r5, [r0, r4]                       @ 0800CCE0  ble_frame_b[r4] = 180 (0xB4)
    ldr.w r0, =ble_sub_dp                   @ 0800CCE2
    ldrb r0, [r0, #0x0]                     @ 0800CCE6  r0 = ble_sub_dp
    movs r5, r0                             @ 0800CCE8
    ldr.w r0, =ble_ovl                      @ 0800CCEA
    ldrb r0, [r0, #0x0]                     @ 0800CCEE  r0 = ble_ovl
    cmp r0, #0x0                            @ 0800CCF0  compare ble_ovl with 0
    beq .L0800CCF6                          @ 0800CCF2  if ble_ovl == 0
    subs r5, #0x80                          @ 0800CCF4  r5 = ble_sub_dp - 128 (0x80)
.L0800CCF6:  @ reached from 0800CCF2 beq (ble_ovl == 0)
    ldr.w r0, =ble_acv_scaled               @ 0800CCF6
    ldr r0, [r0, #0x0]                      @ 0800CCFA  r0 = ble_acv_scaled
    cmp r0, #0x0                            @ 0800CCFC  compare ble_acv_scaled with 0
    bpl .L0800CD02                          @ 0800CCFE  if ble_acv_scaled >=0 0
    adds r5, #0x40                          @ 0800CD00  r5 = r5 + 64 (0x40)
.L0800CD02:  @ reached from 0800CCFE bpl (ble_acv_scaled >=0 0)
    ldr.w r0, =ble_frame_b                  @ 0800CD02
    uxtb r4, r4                             @ 0800CD06
    add r0, r4                              @ 0800CD08  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800CD0A  [r0+1] = r5
    ldr.w r0, =ble_acv_scaled               @ 0800CD0C
    ldr r0, [r0, #0x0]                      @ 0800CD10  r0 = ble_acv_scaled
    cmp r0, #0x0                            @ 0800CD12  compare ble_acv_scaled with 0
    bpl .L0800CD22                          @ 0800CD14  if ble_acv_scaled >=0 0
    ldr.w r0, =ble_acv_scaled               @ 0800CD16
    ldr r0, [r0, #0x0]                      @ 0800CD1A  r0 = ble_acv_scaled
    rsbs r0, r0, #0                         @ 0800CD1C  r0 = -ble_acv_scaled
    movs r6, r0                             @ 0800CD1E
    b .L0800CD2A                            @ 0800CD20
.L0800CD22:  @ reached from 0800CD14 bpl (ble_acv_scaled >=0 0)
    ldr.w r0, =ble_acv_scaled               @ 0800CD22
    ldr r0, [r0, #0x0]                      @ 0800CD26  r0 = ble_acv_scaled
    movs r6, r0                             @ 0800CD28
.L0800CD2A:  @ reached from 0800CD20 b
    movs r1, r6                             @ 0800CD2A
    adds r0, r4, #0x2                       @ 0800CD2C  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CD2E
    bl fn_0800D100                          @ 0800CD30  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2)]
    b .L0800CE20                            @ 0800CD34
.L0800CD36:  @ reached from 0800CCD4 bne (meter_mode != 2)
    ldr.w r0, =meter_mode                   @ 0800CD36
    ldrb r0, [r0, #0x0]                     @ 0800CD3A  r0 = meter_mode
    cmp r0, #0x10                           @ 0800CD3C  compare meter_mode with 16 (0x10)
    beq .L0800CD54                          @ 0800CD3E  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 0800CD40
    ldrb r0, [r0, #0x0]                     @ 0800CD44  r0 = meter_mode
    cmp r0, #0x12                           @ 0800CD46  compare meter_mode with 18 (0x12)
    beq .L0800CD54                          @ 0800CD48  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 0800CD4A
    ldrb r0, [r0, #0x0]                     @ 0800CD4E  r0 = meter_mode
    cmp r0, #0x14                           @ 0800CD50  compare meter_mode with 20 (0x14)
    bne .L0800CD80                          @ 0800CD52  if meter_mode != 20 (0x14)
.L0800CD54:  @ reached from 0800CD3E beq (meter_mode == 16 (0x10)), 0800CD48 beq (meter_mode == 18 (0x12))
    ldr.w r0, =ble_cur_opt                  @ 0800CD54
    ldrb r0, [r0, #0x0]                     @ 0800CD58  r0 = ble_cur_opt
    cmp r0, #0x0                            @ 0800CD5A  compare ble_cur_opt with 0
    bne .L0800CD80                          @ 0800CD5C  if ble_cur_opt != 0
    ldr.w r0, =ble_sub_value                @ 0800CD5E
    ldr r0, [r0, #0x0]                      @ 0800CD62  r0 = ble_sub_value
    movs r1, #0xa                           @ 0800CD64
    sdiv r3, r0, r1                         @ 0800CD66  r3 = ble_sub_value / 10 (0xA)
    ldr.w r0, =ble_sub_ovl                  @ 0800CD6A
    ldrb r2, [r0, #0x0]                     @ 0800CD6E  r2 = ble_sub_ovl
    ldr.w r0, =ble_sub_dp                   @ 0800CD70
    ldrb r1, [r0, #0x0]                     @ 0800CD74  r1 = ble_sub_dp
    movs r0, r4                             @ 0800CD76
    uxtb r0, r0                             @ 0800CD78
    bl fn_0800CE78                          @ 0800CD7A  sub display helper for the value of modes 2 and 4 [r1=ble_sub_dp, r2=ble_sub_ovl, r3=(ble_sub_value / 10 (0xA))]
    b .L0800CE20                            @ 0800CD7E
.L0800CD80:  @ reached from 0800CD52 bne (meter_mode != 20 (0x14)), 0800CD5C bne (ble_cur_opt != 0)
    ldr.w r0, =meter_mode                   @ 0800CD80
    ldrb r0, [r0, #0x0]                     @ 0800CD84  r0 = meter_mode
    cmp r0, #0x10                           @ 0800CD86  compare meter_mode with 16 (0x10)
    beq .L0800CDBC                          @ 0800CD88  if meter_mode == 16 (0x10)
    ldr.w r0, =meter_mode                   @ 0800CD8A
    ldrb r0, [r0, #0x0]                     @ 0800CD8E  r0 = meter_mode
    cmp r0, #0x12                           @ 0800CD90  compare meter_mode with 18 (0x12)
    beq .L0800CDBC                          @ 0800CD92  if meter_mode == 18 (0x12)
    ldr.w r0, =meter_mode                   @ 0800CD94
    ldrb r0, [r0, #0x0]                     @ 0800CD98  r0 = meter_mode
    cmp r0, #0x14                           @ 0800CD9A  compare meter_mode with 20 (0x14)
    beq .L0800CDBC                          @ 0800CD9C  if meter_mode == 20 (0x14)
    ldr.w r0, =meter_mode                   @ 0800CD9E
    ldrb r0, [r0, #0x0]                     @ 0800CDA2  r0 = meter_mode
    cmp r0, #0x11                           @ 0800CDA4  compare meter_mode with 17 (0x11)
    beq .L0800CDBC                          @ 0800CDA6  if meter_mode == 17 (0x11)
    ldr.w r0, =meter_mode                   @ 0800CDA8
    ldrb r0, [r0, #0x0]                     @ 0800CDAC  r0 = meter_mode
    cmp r0, #0x13                           @ 0800CDAE  compare meter_mode with 19 (0x13)
    beq .L0800CDBC                          @ 0800CDB0  if meter_mode == 19 (0x13)
    ldr.w r0, =meter_mode                   @ 0800CDB2
    ldrb r0, [r0, #0x0]                     @ 0800CDB6  r0 = meter_mode
    cmp r0, #0x15                           @ 0800CDB8  compare meter_mode with 21 (0x15)
    bne .L0800CDCC                          @ 0800CDBA  if meter_mode != 21 (0x15)
.L0800CDBC:  @ reached from 0800CD88 beq (meter_mode == 16 (0x10)), 0800CD92 beq (meter_mode == 18 (0x12)), 0800CD9C beq (meter_mode == 20 (0x14)), 0800CDA6 beq (meter_mode == 17 (0x11)), 0800CDB0 beq (meter_mode == 19 (0x13))
    ldr.w r0, =ble_cur_opt                  @ 0800CDBC
    ldrb r0, [r0, #0x0]                     @ 0800CDC0  r0 = ble_cur_opt
    cmp r0, #0x0                            @ 0800CDC2  compare ble_cur_opt with 0
    beq .L0800CDCC                          @ 0800CDC4  if ble_cur_opt == 0
    bl fn_0800D07C                          @ 0800CDC6  sub display item 12 value [r0=ble_cur_opt]
    b .L0800CE20                            @ 0800CDCA
.L0800CDCC:  @ reached from 0800CDBA bne (meter_mode != 21 (0x15)), 0800CDC4 beq (ble_cur_opt == 0)
    ldr.w r0, =meter_mode                   @ 0800CDCC
    ldrb r0, [r0, #0x0]                     @ 0800CDD0  r0 = meter_mode
    cmp r0, #0xd                            @ 0800CDD2  compare meter_mode with 13 (0xD)
    beq .L0800CE08                          @ 0800CDD4  if meter_mode == 13 (0xD)
    ldr.w r0, =meter_mode                   @ 0800CDD6
    ldrb r0, [r0, #0x0]                     @ 0800CDDA  r0 = meter_mode
    cmp r0, #0xe                            @ 0800CDDC  compare meter_mode with 14 (0xE)
    beq .L0800CE08                          @ 0800CDDE  if meter_mode == 14 (0xE)
    ldr.w r0, =meter_mode                   @ 0800CDE0
    ldrb r0, [r0, #0x0]                     @ 0800CDE4  r0 = meter_mode
    cmp r0, #0xf                            @ 0800CDE6  compare meter_mode with 15 (0xF)
    beq .L0800CE08                          @ 0800CDE8  if meter_mode == 15 (0xF)
    ldr.w r0, =meter_mode                   @ 0800CDEA
    ldrb r0, [r0, #0x0]                     @ 0800CDEE  r0 = meter_mode
    cmp r0, #0x16                           @ 0800CDF0  compare meter_mode with 22 (0x16)
    beq .L0800CE08                          @ 0800CDF2  if meter_mode == 22 (0x16)
    ldr.w r0, =meter_mode                   @ 0800CDF4
    ldrb r0, [r0, #0x0]                     @ 0800CDF8  r0 = meter_mode
    cmp r0, #0x17                           @ 0800CDFA  compare meter_mode with 23 (0x17)
    beq .L0800CE08                          @ 0800CDFC  if meter_mode == 23 (0x17)
    ldr.w r0, =meter_mode                   @ 0800CDFE
    ldrb r0, [r0, #0x0]                     @ 0800CE02  r0 = meter_mode
    cmp r0, #0x18                           @ 0800CE04  compare meter_mode with 24 (0x18)
    bne .L0800CE18                          @ 0800CE06  if meter_mode != 24 (0x18)
.L0800CE08:  @ reached from 0800CDD4 beq (meter_mode == 13 (0xD)), 0800CDDE beq (meter_mode == 14 (0xE)), 0800CDE8 beq (meter_mode == 15 (0xF)), 0800CDF2 beq (meter_mode == 22 (0x16)), 0800CDFC beq (meter_mode == 23 (0x17))
    ldr.w r0, =ble_va_bd                    @ 0800CE08
    ldrb r1, [r0, #0x0]                     @ 0800CE0C  r1 = ble_va_bd
    movs r0, r4                             @ 0800CE0E
    uxtb r0, r0                             @ 0800CE10
    bl fn_0800CE32                          @ 0800CE12  sub display code 0x9B / 0x9C helper [r1=ble_va_bd]
    b .L0800CE20                            @ 0800CE16
.L0800CE18:  @ reached from 0800CE06 bne (meter_mode != 24 (0x18))
    movs r0, r4                             @ 0800CE18
    uxtb r0, r0                             @ 0800CE1A
    bl fn_0800D0C8                          @ 0800CE1C  sub display empty (zeros)
.L0800CE20:  @ reached from 0800CD34 b, 0800CD7E b, 0800CDCA b, 0800CE16 b
    pop {r4, r5, r6, pc}                    @ 0800CE20
ENDFUNC fn_0800CCC8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CE28 - sub display case 12: item 12 value
@ Replaces : 0x0800CE28 FUN_0800CE28 (v2.05)
@ In       : r0 = first frame index (9, ignored)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CE28
    push {r4, lr}                           @ 0800CE28
    movs r4, r0                             @ 0800CE2A
    bl fn_0800D07C                          @ 0800CE2C  sub display item 12 value
    pop {r4, pc}                            @ 0800CE30
ENDFUNC fn_0800CE28
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CE32 - sub display code 0x9B / 0x9C (current option)
@ Replaces : 0x0800CE32 FUN_0800CE32 (v2.05)
@ In       : r0 = first frame index, r1 = option flag
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CE32
    push {r4, r5, r6, lr}                   @ 0800CE32
    movs r4, r0                             @ 0800CE34
    movs r5, r1                             @ 0800CE36
    uxtb r5, r5                             @ 0800CE38
    cmp r5, #0x0                            @ 0800CE3A  compare r5 with 0
    beq .L0800CE44                          @ 0800CE3C  if r5 == 0
    movs r0, #0x9b                          @ 0800CE3E
    movs r6, r0                             @ 0800CE40
    b .L0800CE48                            @ 0800CE42
.L0800CE44:  @ reached from 0800CE3C beq (r5 == 0)
    movs r0, #0x9c                          @ 0800CE44
    movs r6, r0                             @ 0800CE46
.L0800CE48:  @ reached from 0800CE42 b
    ldr.w r0, =ble_frame_b                  @ 0800CE48
    uxtb r4, r4                             @ 0800CE4C
    strb r6, [r0, r4]                       @ 0800CE4E  ble_frame_b[r4] = r6
    movs r0, #0x3                           @ 0800CE50
    movs r6, r0                             @ 0800CE52
    ldr.w r0, =ble_frame_b                  @ 0800CE54
    uxtb r4, r4                             @ 0800CE58
    add r0, r4                              @ 0800CE5A  r0 = &ble_frame_b + r4
    strb r6, [r0, #0x1]                     @ 0800CE5C  [r0+1] = 3
    movs r1, #0x0                           @ 0800CE5E
    adds r0, r4, #0x2                       @ 0800CE60  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CE62
    bl fn_0800D100                          @ 0800CE64  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=0]
    pop {r4, r5, r6, pc}                    @ 0800CE68
ENDFUNC fn_0800CE32
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CE78 - sub display helper: scaled value of modes 2 and 4
@ Replaces : 0x0800CE78 FUN_0800CE78 (v2.05)
@ In       : r0 = frame index, r1 = decimal point code, r2 = overflow, r3 = value
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_freq_range; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800CE78
    push {r3, r4, r5, r6, r7, r8, r9, lr}   @ 0800CE78
    movs r4, r0                             @ 0800CE7C
    movs r5, r1                             @ 0800CE7E
    movs r6, r2                             @ 0800CE80
    movs r7, r3                             @ 0800CE82
    movs r0, #0x6                           @ 0800CE84
    mov r9, r0                              @ 0800CE86
    ldr.w r0, =ble_frame_b                  @ 0800CE88
    uxtb r4, r4                             @ 0800CE8C
    strb r9, [r0, r4]                       @ 0800CE8E  ble_frame_b[r4] = 6
    mov r9, r5                              @ 0800CE92
    uxtb r6, r6                             @ 0800CE94
    cmp r6, #0x0                            @ 0800CE96  compare r6 with 0
    beq .L0800CE9E                          @ 0800CE98  if r6 == 0
    subs r9, r9, #0x80                      @ 0800CE9A  r9 = r9 - 128 (0x80)
.L0800CE9E:  @ reached from 0800CE98 beq (r6 == 0)
    cmp r7, #0x0                            @ 0800CE9E  compare r7 with 0
    bpl .L0800CEA6                          @ 0800CEA0  if r7 >=0 0
    adds r9, r9, #0x40                      @ 0800CEA2  r9 = r9 + 64 (0x40)
.L0800CEA6:  @ reached from 0800CEA0 bpl (r7 >=0 0)
    adds r9, r9, #0x10                      @ 0800CEA6  r9 = r9 + 16 (0x10)
    ldr.w r0, =ble_freq_range               @ 0800CEAA
    ldrb r0, [r0, #0x0]                     @ 0800CEAE  r0 = ble_freq_range
    cmp r0, #0x2                            @ 0800CEB0  compare ble_freq_range with 2
    blt .L0800CEB8                          @ 0800CEB2  if ble_freq_range <s 2
    adds r9, r9, #0x20                      @ 0800CEB4  r9 = (r9 + 16 (0x10)) + 32 (0x20)
.L0800CEB8:  @ reached from 0800CEB2 blt (ble_freq_range <s 2)
    ldr.w r0, =ble_frame_b                  @ 0800CEB8
    uxtb r4, r4                             @ 0800CEBC
    add r0, r4                              @ 0800CEBE  r0 = &ble_frame_b + r4
    strb r9, [r0, #0x1]                     @ 0800CEC0  [r0+1] = r9
    cmp r7, #0x0                            @ 0800CEC4  compare r7 with 0
    bpl .L0800CECE                          @ 0800CEC6  if r7 >=0 0
    rsbs r0, r7, #0                         @ 0800CEC8  r0 = -r7
    mov r8, r0                              @ 0800CECA
    b .L0800CED0                            @ 0800CECC
.L0800CECE:  @ reached from 0800CEC6 bpl (r7 >=0 0)
    mov r8, r7                              @ 0800CECE
.L0800CED0:  @ reached from 0800CECC b
    mov r1, r8                              @ 0800CED0
    adds r0, r4, #0x2                       @ 0800CED2  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CED4
    bl fn_0800D100                          @ 0800CED6  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2)]
    pop {r0, r4, r5, r6, r7, r8, r9, pc}    @ 0800CEDA
ENDFUNC fn_0800CE78
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CEFC - sub display VA helper: voltage
@ Replaces : 0x0800CEFC FUN_0800CEFC (v2.05)
@ In       : r0 = frame index, r1 = decimal point code, r2 = ring flag
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_ring_idx, ble_va_ovl1, ble_va_ovl2, ble_va_volt, meter_mode; writes ble_frame_b, ble_ring_va1
@ Spec     : analysis/ble_packet.md 4
@ Deviation: OF-03: byte [index] = 0 for modes outside 13..15 and 22..24 (v2.05 stores the unset register r7)
@ -----------------------------------------------------------------------------
FUNC fn_0800CEFC
    push {r4, r5, r6, r7, r8, lr}           @ 0800CEFC
    movs r4, r0                             @ 0800CF00
    movs r5, r1                             @ 0800CF02
    movs r6, r2                             @ 0800CF04
    movs r7, #0                          @ OF-03: defined value 0 when the mode is outside both ranges
    ldr.w r0, =meter_mode                   @ 0800CF06
    ldrb r0, [r0, #0x0]                     @ 0800CF0A  r0 = meter_mode
    subs r0, #0xd                           @ 0800CF0C  r0 = meter_mode - 13 (0xD)
    cmp r0, #0x2                            @ 0800CF0E  compare (meter_mode - 13 (0xD)) with 2
    bls .L0800CF1E                          @ 0800CF10  if (meter_mode - 13 (0xD)) <=u 2
    subs r0, #0x9                           @ 0800CF12  r0 = (meter_mode - 13 (0xD)) - 9
    cmp r0, #0x2                            @ 0800CF14  compare ((meter_mode - 13 (0xD)) - 9) with 2
    bhi .L0800CF22                          @ 0800CF16  if ((meter_mode - 13 (0xD)) - 9) >u 2
    movs r0, #0x1                           @ 0800CF18
    movs r7, r0                             @ 0800CF1A
    b .L0800CF22                            @ 0800CF1C
.L0800CF1E:  @ reached from 0800CF10 bls ((meter_mode - 13 (0xD)) <=u 2)
    movs r0, #0x2                           @ 0800CF1E
    movs r7, r0                             @ 0800CF20
.L0800CF22:  @ reached from 0800CF16 bhi (((meter_mode - 13 (0xD)) - 9) >u 2), 0800CF1C b
    ldr.w r0, =ble_frame_b                  @ 0800CF22
    uxtb r4, r4                             @ 0800CF26
    strb r7, [r0, r4]                       @ 0800CF28  ble_frame_b[r4] = r7
    movs r7, r5                             @ 0800CF2A
    ldr.w r0, =ble_va_ovl1                  @ 0800CF2C
    ldrsb r0, [r0, #0x0]                    @ 0800CF30  r0 = ble_va_ovl1
    cmp r0, #0x0                            @ 0800CF34  compare ble_va_ovl1 with 0
    bne .L0800CF44                          @ 0800CF36  if ble_va_ovl1 != 0
    ldr.w r0, =ble_va_ovl2                  @ 0800CF38
    ldrsb r0, [r0, #0x0]                    @ 0800CF3C  r0 = ble_va_ovl2
    cmp r0, #0x0                            @ 0800CF40  compare ble_va_ovl2 with 0
    beq .L0800CF46                          @ 0800CF42  if ble_va_ovl2 == 0
.L0800CF44:  @ reached from 0800CF36 bne (ble_va_ovl1 != 0)
    subs r7, #0x80                          @ 0800CF44  r7 = r7 - 128 (0x80)
.L0800CF46:  @ reached from 0800CF42 beq (ble_va_ovl2 == 0)
    ldr.w r0, =ble_va_volt                  @ 0800CF46
    ldr r0, [r0, #0x0]                      @ 0800CF4A  r0 = ble_va_volt
    cmp r0, #0x0                            @ 0800CF4C  compare ble_va_volt with 0
    bpl .L0800CF52                          @ 0800CF4E  if ble_va_volt >=0 0
    adds r7, #0x40                          @ 0800CF50  r7 = r7 + 64 (0x40)
.L0800CF52:  @ reached from 0800CF4E bpl (ble_va_volt >=0 0)
    ldr.w r0, =ble_frame_b                  @ 0800CF52
    uxtb r4, r4                             @ 0800CF54
    add r0, r4                              @ 0800CF56  r0 = &ble_frame_b + r4
    strb r7, [r0, #0x1]                     @ 0800CF58  [r0+1] = r7
    ldr.w r0, =ble_va_volt                  @ 0800CF5A
    ldr r0, [r0, #0x0]                      @ 0800CF5E  r0 = ble_va_volt
    cmp r0, #0x0                            @ 0800CF60  compare ble_va_volt with 0
    bpl .L0800CF70                          @ 0800CF62  if ble_va_volt >=0 0
    ldr.w r0, =ble_va_volt                  @ 0800CF64
    ldr r0, [r0, #0x0]                      @ 0800CF68  r0 = ble_va_volt
    rsbs r0, r0, #0                         @ 0800CF6A  r0 = -ble_va_volt
    mov r8, r0                              @ 0800CF6C
    b .L0800CF78                            @ 0800CF6E
.L0800CF70:  @ reached from 0800CF62 bpl (ble_va_volt >=0 0)
    ldr.w r0, =ble_va_volt                  @ 0800CF70
    ldr r0, [r0, #0x0]                      @ 0800CF74  r0 = ble_va_volt
    mov r8, r0                              @ 0800CF76
.L0800CF78:  @ reached from 0800CF6E b
    mov r1, r8                              @ 0800CF78
    adds r0, r4, #0x2                       @ 0800CF7A  r0 = r4 + 2
    uxtb r0, r0                             @ 0800CF7C
    bl fn_0800D100                          @ 0800CF7E  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2)]
    uxtb r6, r6                             @ 0800CF82
    cmp r6, #0x0                            @ 0800CF84  compare r6 with 0
    beq .L0800CF9A                          @ 0800CF86  if r6 == 0
    ldr.w r0, =ble_va_volt                  @ 0800CF88
    ldr r0, [r0, #0x0]                      @ 0800CF8C  r0 = ble_va_volt
    ldr.w r1, =ble_ring_va1                 @ 0800CF8E
    ldr.w r2, =ble_ring_idx                 @ 0800CF92
    ldrh r2, [r2, #0x0]                     @ 0800CF94  r2 = ble_ring_idx
    str r0, [r1, r2, lsl #0x2]              @ 0800CF96  ble_ring_va1[r2 << 0x2] = ble_va_volt
.L0800CF9A:  @ reached from 0800CF86 beq (r6 == 0)
    pop {r4, r5, r6, r7, r8, pc}            @ 0800CF9A
ENDFUNC fn_0800CEFC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800CFB0 - sub display VA helper: current
@ Replaces : 0x0800CFB0 FUN_0800CFB0 (v2.05)
@ In       : r0 = frame index, r1 = decimal point code, r2 = ring flag
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_ring_idx, ble_va_cur, ble_va_ovl1, ble_va_ovl2, meter_mode; writes ble_frame_b, ble_ring_va2
@ Spec     : analysis/ble_packet.md 4
@ Deviation: OF-03: byte [index] = 0 for modes outside 13..15 and 22..24 (v2.05 stores the unset register r7)
@ -----------------------------------------------------------------------------
FUNC fn_0800CFB0
    push {r4, r5, r6, r7, r8, lr}           @ 0800CFB0
    movs r4, r0                             @ 0800CFB4
    movs r5, r1                             @ 0800CFB6
    movs r6, r2                             @ 0800CFB8
    movs r7, #0                          @ OF-03: defined value 0 when the mode is outside both ranges
    ldr.w r0, =meter_mode                   @ 0800CFBA
    ldrb r0, [r0, #0x0]                     @ 0800CFBC  r0 = meter_mode
    cmp r0, #0xd                            @ 0800CFBE  compare meter_mode with 13 (0xD)
    beq .L0800CFEA                          @ 0800CFC0  if meter_mode == 13 (0xD)
    cmp r0, #0xe                            @ 0800CFC2  compare meter_mode with 14 (0xE)
    beq .L0800CFF0                          @ 0800CFC4  if meter_mode == 14 (0xE)
    cmp r0, #0xf                            @ 0800CFC6  compare meter_mode with 15 (0xF)
    beq .L0800CFF6                          @ 0800CFC8  if meter_mode == 15 (0xF)
    cmp r0, #0x16                           @ 0800CFCA  compare meter_mode with 22 (0x16)
    beq .L0800CFD8                          @ 0800CFCC  if meter_mode == 22 (0x16)
    cmp r0, #0x17                           @ 0800CFCE  compare meter_mode with 23 (0x17)
    beq .L0800CFDE                          @ 0800CFD0  if meter_mode == 23 (0x17)
    cmp r0, #0x18                           @ 0800CFD2  compare meter_mode with 24 (0x18)
    beq .L0800CFE4                          @ 0800CFD4  if meter_mode == 24 (0x18)
    b .L0800CFFA                            @ 0800CFD6
.L0800CFD8:  @ reached from 0800CFCC beq (meter_mode == 22 (0x16))
    movs r0, #0x11                          @ 0800CFD8
    movs r7, r0                             @ 0800CFDA
    b .L0800CFFA                            @ 0800CFDC
.L0800CFDE:  @ reached from 0800CFD0 beq (meter_mode == 23 (0x17))
    movs r0, #0x13                          @ 0800CFDE
    movs r7, r0                             @ 0800CFE0
    b .L0800CFFA                            @ 0800CFE2
.L0800CFE4:  @ reached from 0800CFD4 beq (meter_mode == 24 (0x18))
    movs r0, #0x15                          @ 0800CFE4
    movs r7, r0                             @ 0800CFE6
    b .L0800CFFA                            @ 0800CFE8
.L0800CFEA:  @ reached from 0800CFC0 beq (meter_mode == 13 (0xD))
    movs r0, #0x10                          @ 0800CFEA
    movs r7, r0                             @ 0800CFEC
    b .L0800CFFA                            @ 0800CFEE
.L0800CFF0:  @ reached from 0800CFC4 beq (meter_mode == 14 (0xE))
    movs r0, #0x12                          @ 0800CFF0
    movs r7, r0                             @ 0800CFF2
    b .L0800CFFA                            @ 0800CFF4
.L0800CFF6:  @ reached from 0800CFC8 beq (meter_mode == 15 (0xF))
    movs r0, #0x14                          @ 0800CFF6
    movs r7, r0                             @ 0800CFF8
.L0800CFFA:  @ reached from 0800CFD6 b, 0800CFDC b, 0800CFE2 b, 0800CFE8 b, 0800CFEE b, 0800CFF4 b
    ldr.w r0, =ble_frame_b                  @ 0800CFFA
    uxtb r4, r4                             @ 0800CFFC
    strb r7, [r0, r4]                       @ 0800CFFE  ble_frame_b[r4] = r7
    movs r7, r5                             @ 0800D000
    ldr.w r0, =ble_va_ovl2                  @ 0800D002
    ldrsb r0, [r0, #0x0]                    @ 0800D006  r0 = ble_va_ovl2
    cmp r0, #0x0                            @ 0800D00A  compare ble_va_ovl2 with 0
    bne .L0800D01A                          @ 0800D00C  if ble_va_ovl2 != 0
    ldr.w r0, =ble_va_ovl1                  @ 0800D00E
    ldrsb r0, [r0, #0x0]                    @ 0800D012  r0 = ble_va_ovl1
    cmp r0, #0x0                            @ 0800D016  compare ble_va_ovl1 with 0
    beq .L0800D01C                          @ 0800D018  if ble_va_ovl1 == 0
.L0800D01A:  @ reached from 0800D00C bne (ble_va_ovl2 != 0)
    subs r7, #0x80                          @ 0800D01A  r7 = r7 - 128 (0x80)
.L0800D01C:  @ reached from 0800D018 beq (ble_va_ovl1 == 0)
    ldr.w r0, =ble_va_cur                   @ 0800D01C
    ldr r0, [r0, #0x0]                      @ 0800D020  r0 = ble_va_cur
    cmp r0, #0x0                            @ 0800D022  compare ble_va_cur with 0
    bpl .L0800D028                          @ 0800D024  if ble_va_cur >=0 0
    adds r7, #0x40                          @ 0800D026  r7 = r7 + 64 (0x40)
.L0800D028:  @ reached from 0800D024 bpl (ble_va_cur >=0 0)
    ldr.w r0, =ble_frame_b                  @ 0800D028
    uxtb r4, r4                             @ 0800D02A
    add r0, r4                              @ 0800D02C  r0 = &ble_frame_b + r4
    strb r7, [r0, #0x1]                     @ 0800D02E  [r0+1] = r7
    ldr.w r0, =ble_va_cur                   @ 0800D030
    ldr r0, [r0, #0x0]                      @ 0800D034  r0 = ble_va_cur
    cmp r0, #0x0                            @ 0800D036  compare ble_va_cur with 0
    bpl .L0800D046                          @ 0800D038  if ble_va_cur >=0 0
    ldr.w r0, =ble_va_cur                   @ 0800D03A
    ldr r0, [r0, #0x0]                      @ 0800D03E  r0 = ble_va_cur
    rsbs r0, r0, #0                         @ 0800D040  r0 = -ble_va_cur
    mov r8, r0                              @ 0800D042
    b .L0800D04E                            @ 0800D044
.L0800D046:  @ reached from 0800D038 bpl (ble_va_cur >=0 0)
    ldr.w r0, =ble_va_cur                   @ 0800D046
    ldr r0, [r0, #0x0]                      @ 0800D04A  r0 = ble_va_cur
    mov r8, r0                              @ 0800D04C
.L0800D04E:  @ reached from 0800D044 b
    mov r1, r8                              @ 0800D04E
    adds r0, r4, #0x2                       @ 0800D050  r0 = r4 + 2
    uxtb r0, r0                             @ 0800D052
    bl fn_0800D100                          @ 0800D054  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2)]
    uxtb r6, r6                             @ 0800D058
    cmp r6, #0x0                            @ 0800D05A  compare r6 with 0
    beq .L0800D070                          @ 0800D05C  if r6 == 0
    ldr.w r0, =ble_va_cur                   @ 0800D05E
    ldr r0, [r0, #0x0]                      @ 0800D062  r0 = ble_va_cur
    ldr.w r1, =ble_ring_va2                 @ 0800D064
    ldr.w r2, =ble_ring_idx                 @ 0800D068
    ldrh r2, [r2, #0x0]                     @ 0800D06A  r2 = ble_ring_idx
    str r0, [r1, r2, lsl #0x2]              @ 0800D06C  ble_ring_va2[r2 << 0x2] = ble_va_cur
.L0800D070:  @ reached from 0800D05C beq (r6 == 0)
    pop {r4, r5, r6, r7, r8, pc}            @ 0800D070
ENDFUNC fn_0800CFB0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800D07C - sub display item 12 value (code 150)
@ Replaces : 0x0800D07C FUN_0800D07C (v2.05)
@ In       : r0 = frame index (ignored)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : reads ble_item12_value; writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800D07C
    push {r3, r4, r5, lr}                   @ 0800D07C
    movs r0, #0x96                          @ 0800D07E
    movs r5, r0                             @ 0800D080
    ldr.w r0, =ble_frame_b                  @ 0800D082
    strb r5, [r0, #0x9]                     @ 0800D084  ble_frame_b+9 = 150 (0x96)
    movs r0, #0x1                           @ 0800D086
    movs r5, r0                             @ 0800D088
    ldr.w r0, =ble_item12_value             @ 0800D08A
    ldrsh r0, [r0, #0x0]                    @ 0800D08E  r0 = ble_item12_value
    cmp r0, #0x0                            @ 0800D092  compare ble_item12_value with 0
    bpl .L0800D0A6                          @ 0800D094  if ble_item12_value >=0 0
    adds r5, #0x40                          @ 0800D096  r5 = 1 + 64 (0x40)
    ldr.w r0, =ble_item12_value             @ 0800D098
    ldrsh r0, [r0, #0x0]                    @ 0800D09C  r0 = ble_item12_value
    rsbs r0, r0, #0                         @ 0800D0A0  r0 = -ble_item12_value
    movs r4, r0                             @ 0800D0A2
    b .L0800D0B0                            @ 0800D0A4
.L0800D0A6:  @ reached from 0800D094 bpl (ble_item12_value >=0 0)
    ldr.w r0, =ble_item12_value             @ 0800D0A6
    ldrsh r0, [r0, #0x0]                    @ 0800D0AA  r0 = ble_item12_value
    movs r4, r0                             @ 0800D0AE
.L0800D0B0:  @ reached from 0800D0A4 b
    ldr.w r0, =ble_frame_b                  @ 0800D0B0
    strb r5, [r0, #0xa]                     @ 0800D0B2  ble_frame_b+10 = r5
    movs r1, r4                             @ 0800D0B4
    movs r0, #0xb                           @ 0800D0B6
    bl fn_0800D100                          @ 0800D0B8  store |r1| big endian at frame bytes r0, r0+1 [r0=11 (0xB)]
    pop {r0, r4, r5, pc}                    @ 0800D0BC
ENDFUNC fn_0800D07C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800D0C8 - sub display empty (code 0, zeros)
@ Replaces : 0x0800D0C8 FUN_0800D0C8 (v2.05)
@ In       : r0 = frame index
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800D0C8
    push {r3, r4, r5, lr}                   @ 0800D0C8
    movs r4, r0                             @ 0800D0CA
    movs r0, #0x0                           @ 0800D0CC
    movs r5, r0                             @ 0800D0CE
    ldr.w r0, =ble_frame_b                  @ 0800D0D0
    uxtb r4, r4                             @ 0800D0D2
    strb r5, [r0, r4]                       @ 0800D0D4  ble_frame_b[r4] = 0
    movs r0, #0x0                           @ 0800D0D6
    movs r5, r0                             @ 0800D0D8
    ldr.w r0, =ble_frame_b                  @ 0800D0DA
    uxtb r4, r4                             @ 0800D0DC
    add r0, r4                              @ 0800D0DE  r0 = &ble_frame_b + r4
    strb r5, [r0, #0x1]                     @ 0800D0E0  [r0+1] = 0
    movs r1, #0x0                           @ 0800D0E2
    adds r0, r4, #0x2                       @ 0800D0E4  r0 = r4 + 2
    uxtb r0, r0                             @ 0800D0E6
    bl fn_0800D100                          @ 0800D0E8  store |r1| big endian at frame bytes r0, r0+1 [r0=(r4 + 2), r1=0]
    pop {r0, r4, r5, pc}                    @ 0800D0EC
ENDFUNC fn_0800D0C8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800D100 - store |value| big endian
@ Replaces : 0x0800D100 FUN_0800D100 (v2.05)
@ In       : r0 = frame index, r1 = signed value
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (builder)
@ RAM      : writes ble_frame_b
@ Spec     : analysis/ble_packet.md 4
@ -----------------------------------------------------------------------------
FUNC fn_0800D100
    push {r4}                               @ 0800D100
    cmp r1, #0x0                            @ 0800D102  compare r1 with 0
    bpl .L0800D10C                          @ 0800D104  if r1 >=0 0
    rsbs r4, r1, #0                         @ 0800D106  r4 = -r1
    movs r3, r4                             @ 0800D108
    b .L0800D10E                            @ 0800D10A
.L0800D10C:  @ reached from 0800D104 bpl (r1 >=0 0)
    movs r3, r1                             @ 0800D10C
.L0800D10E:  @ reached from 0800D10A b
    asrs r4, r3, #0x8                       @ 0800D10E  r4 = r3 >> 8
    movs r2, r4                             @ 0800D110
    ldr.w r4, =ble_frame_b                  @ 0800D112
    uxtb r0, r0                             @ 0800D114
    strb r2, [r4, r0]                       @ 0800D116  ble_frame_b[r0] = (r3 >> 8)
    movs r4, r3                             @ 0800D118
    movs r2, r4                             @ 0800D11A
    ldr.w r4, =ble_frame_b                  @ 0800D11C
    uxtb r0, r0                             @ 0800D11E
    add r4, r0                              @ 0800D120  r4 = &ble_frame_b + r0
    strb r2, [r4, #0x1]                     @ 0800D122  [r4+1] = r2
    pop {r4}                                @ 0800D124
    bx lr                                   @ 0800D126
ENDFUNC fn_0800D100
    .ltorg
