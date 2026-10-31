@ =============================================================================
@ nju6350.s - RTC: NJU6350 bit-bang driver and time registers
@
@ RTC module, part 1: the NJU6350 serial real-time-clock driver (PB6 = CLK, PB7 = DATA, PC13 = CE).
@
@ Replaces the v2.05 routines 0x0800FF18, 0x080100C4, 0x08010118, 0x0801013E, 0x0801016C, 0x080101AC..0x080103D8.
@ Protocol (NJU6350 datasheet, inputs/docs): CE high starts a transaction, a 4-bit command C2 C1 C0 RW is
@ clocked in LSB first on the rising CLK edge, then 8 data bits follow (written by the MCU, or driven by the
@ chip after the falling edge of the 4th command clock when RW = 0, until CE falls).  Bit timing is the v2.05
@ timing: 5 passes of fn_0800ECF6 around every edge.
@
@ HW-01 (DESIGN.md 4.2, 10): PB7 is an open-drain output with the internal pull-up for the whole transaction;
@ for a read it is released (written 1) from the rising edge of command bit 4 until CE is low, so the MCU
@ never drives against the chip.  v2.05 used a push-pull PB7 that was driven for most of the read.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

@ Module-local names of v2.05 RAM variables (address = the v_XXXXXXXX symbol of ram_v205.inc)
    .equ rtc_sec_last,          v_2000023D   @ last seconds register value read from the NJU6350
    .equ rtc_sec_flag,          v_200080D4   @ 1 s flag, set when the seconds register changed
    .equ rtc_year,              v_200080D7   @ year 0..99 (BCD-converted NJU6350 register 2)
    .equ rtc_month,             v_200080D8   @ month 1..12 (register 4)
    .equ rtc_day,               v_200080D9   @ day 1..31 (register 6)
    .equ rtc_hour,              v_200080DA   @ hour 0..23 (register 10)
    .equ rtc_minute,            v_200080DB   @ minute 0..59 (register 12)
    .equ rtc_second,            v_200080DC   @ second 0..59 (register 14)
    .equ rtc_colon,             v_200080E7   @ colon blink phase, toggled each second

    .section .text.rtc, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800FF18 - read the NJU6350 time registers into RAM with range checks
@ Replaces : 0x0800FF18 FUN_0800FF18 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (boot via set_state_reset, loop steps 5 and 9, setup edit)
@ RAM      : writes rtc_day, rtc_hour, rtc_minute, rtc_month, rtc_second, rtc_year
@ Spec     : analysis/keys_setup.md 4 (items 5..7); NJU6350 datasheet, register table (year 2, month 4, date 6, hour
@            10, minute 12, second 14)
@ Note     : Each register is read through rtc_read_reg (raw BCD).  A raw value of 0 (year, month, day only) or one
@            beyond the BCD limit (year 0x9A, month 0x13, day 0x32, hour 0x24, minute and second 0x5A) selects the
@            default; otherwise the value is converted to binary and, if it is 0 (year, month, day) or at or beyond
@            the binary limit (100, 13, 32, 24, 60, 60), the default is used.  Defaults: year 16, month 7, day 1, hour
@            12, minute 0, second 0.  A delay of 5 passes separates the register reads (v2.05 0x0800FF62 and similar).
@ -----------------------------------------------------------------------------
FUNC fn_0800FF18
    push {r4, lr}                           @ 0800FF18
    movs r0, #0x2                           @ 0800FF1A
    bl rtc_read_reg                         @ 0800FF1C  read NJU6350 register r0 [r0=2]
    movs r4, r0                             @ 0800FF20
    uxtb r4, r4                             @ 0800FF22
    cmp r4, #0x0                            @ 0800FF24  compare r4 with 0
    beq .L0800FF5A                          @ 0800FF26  if r4 == 0
    uxtb r4, r4                             @ 0800FF28
    cmp r4, #0x9a                           @ 0800FF2A  compare r4 with 154 (0x9A)
    bge .L0800FF5A                          @ 0800FF2C  if r4 >=s 154 (0x9A)
    movs r0, r4                             @ 0800FF2E
    uxtb r0, r0                             @ 0800FF30
    bl fn_08010118                          @ 0800FF32  BCD byte to binary
    ldr.w r1, =rtc_year                     @ 0800FF36
    strb r0, [r1, #0x0]                     @ 0800FF3A  rtc_year = r0
    ldr.w r0, =rtc_year                     @ 0800FF3C
    ldrb r0, [r0, #0x0]                     @ 0800FF40  r0 = rtc_year
    cmp r0, #0x0                            @ 0800FF42  compare rtc_year with 0
    beq .L0800FF50                          @ 0800FF44  if rtc_year == 0
    ldr.w r0, =rtc_year                     @ 0800FF46
    ldrb r0, [r0, #0x0]                     @ 0800FF4A  r0 = rtc_year
    cmp r0, #0x64                           @ 0800FF4C  compare rtc_year with 100 (0x64)
    blt .L0800FF62                          @ 0800FF4E  if rtc_year <s 100 (0x64)
.L0800FF50:  @ reached from 0800FF44 beq (rtc_year == 0)
    movs r0, #0x10                          @ 0800FF50
    ldr.w r1, =rtc_year                     @ 0800FF52
    strb r0, [r1, #0x0]                     @ 0800FF56  rtc_year = 16 (0x10)
    b .L0800FF62                            @ 0800FF58
.L0800FF5A:  @ reached from 0800FF26 beq (r4 == 0), 0800FF2C bge (r4 >=s 154 (0x9A))
    movs r0, #0x10                          @ 0800FF5A
    ldr.w r1, =rtc_year                     @ 0800FF5C
    strb r0, [r1, #0x0]                     @ 0800FF60  rtc_year = 16 (0x10)
.L0800FF62:  @ reached from 0800FF4E blt (rtc_year <s 100 (0x64)), 0800FF58 b
    movs r0, #0x5                           @ 0800FF62
    bl fn_0800ECF6                          @ 0800FF64  busy delay of r0 loop passes [r0=5]
    movs r0, #0x4                           @ 0800FF68
    bl rtc_read_reg                         @ 0800FF6A  read NJU6350 register r0 [r0=4]
    movs r4, r0                             @ 0800FF6E
    uxtb r4, r4                             @ 0800FF70
    cmp r4, #0x0                            @ 0800FF72  compare r4 with 0
    beq .L0800FFA8                          @ 0800FF74  if r4 == 0
    uxtb r4, r4                             @ 0800FF76
    cmp r4, #0x13                           @ 0800FF78  compare r4 with 19 (0x13)
    bge .L0800FFA8                          @ 0800FF7A  if r4 >=s 19 (0x13)
    movs r0, r4                             @ 0800FF7C
    uxtb r0, r0                             @ 0800FF7E
    bl fn_08010118                          @ 0800FF80  BCD byte to binary
    ldr.w r1, =rtc_month                    @ 0800FF84
    strb r0, [r1, #0x0]                     @ 0800FF88  rtc_month = r0
    ldr.w r0, =rtc_month                    @ 0800FF8A
    ldrb r0, [r0, #0x0]                     @ 0800FF8E  r0 = rtc_month
    cmp r0, #0x0                            @ 0800FF90  compare rtc_month with 0
    beq .L0800FF9E                          @ 0800FF92  if rtc_month == 0
    ldr.w r0, =rtc_month                    @ 0800FF94
    ldrb r0, [r0, #0x0]                     @ 0800FF98  r0 = rtc_month
    cmp r0, #0xd                            @ 0800FF9A  compare rtc_month with 13 (0xD)
    blt .L0800FFB0                          @ 0800FF9C  if rtc_month <s 13 (0xD)
.L0800FF9E:  @ reached from 0800FF92 beq (rtc_month == 0)
    movs r0, #0x7                           @ 0800FF9E
    ldr.w r1, =rtc_month                    @ 0800FFA0
    strb r0, [r1, #0x0]                     @ 0800FFA4  rtc_month = 7
    b .L0800FFB0                            @ 0800FFA6
.L0800FFA8:  @ reached from 0800FF74 beq (r4 == 0), 0800FF7A bge (r4 >=s 19 (0x13))
    movs r0, #0x7                           @ 0800FFA8
    ldr.w r1, =rtc_month                    @ 0800FFAA
    strb r0, [r1, #0x0]                     @ 0800FFAE  rtc_month = 7
.L0800FFB0:  @ reached from 0800FF9C blt (rtc_month <s 13 (0xD)), 0800FFA6 b
    movs r0, #0x5                           @ 0800FFB0
    bl fn_0800ECF6                          @ 0800FFB2  busy delay of r0 loop passes [r0=5]
    movs r0, #0x6                           @ 0800FFB6
    bl rtc_read_reg                         @ 0800FFB8  read NJU6350 register r0 [r0=6]
    movs r4, r0                             @ 0800FFBC
    uxtb r4, r4                             @ 0800FFBE
    cmp r4, #0x0                            @ 0800FFC0  compare r4 with 0
    beq .L0800FFF6                          @ 0800FFC2  if r4 == 0
    uxtb r4, r4                             @ 0800FFC4
    cmp r4, #0x32                           @ 0800FFC6  compare r4 with 50 (0x32)
    bge .L0800FFF6                          @ 0800FFC8  if r4 >=s 50 (0x32)
    movs r0, r4                             @ 0800FFCA
    uxtb r0, r0                             @ 0800FFCC
    bl fn_08010118                          @ 0800FFCE  BCD byte to binary
    ldr.w r1, =rtc_day                      @ 0800FFD2
    strb r0, [r1, #0x0]                     @ 0800FFD6  rtc_day = r0
    ldr.w r0, =rtc_day                      @ 0800FFD8
    ldrb r0, [r0, #0x0]                     @ 0800FFDC  r0 = rtc_day
    cmp r0, #0x0                            @ 0800FFDE  compare rtc_day with 0
    beq .L0800FFEC                          @ 0800FFE0  if rtc_day == 0
    ldr.w r0, =rtc_day                      @ 0800FFE2
    ldrb r0, [r0, #0x0]                     @ 0800FFE6  r0 = rtc_day
    cmp r0, #0x20                           @ 0800FFE8  compare rtc_day with 32 (0x20)
    blt .L0800FFFE                          @ 0800FFEA  if rtc_day <s 32 (0x20)
.L0800FFEC:  @ reached from 0800FFE0 beq (rtc_day == 0)
    movs r0, #0x1                           @ 0800FFEC
    ldr.w r1, =rtc_day                      @ 0800FFEE
    strb r0, [r1, #0x0]                     @ 0800FFF2  rtc_day = 1
    b .L0800FFFE                            @ 0800FFF4
.L0800FFF6:  @ reached from 0800FFC2 beq (r4 == 0), 0800FFC8 bge (r4 >=s 50 (0x32))
    movs r0, #0x1                           @ 0800FFF6
    ldr.w r1, =rtc_day                      @ 0800FFF8
    strb r0, [r1, #0x0]                     @ 0800FFFC  rtc_day = 1
.L0800FFFE:  @ reached from 0800FFEA blt (rtc_day <s 32 (0x20)), 0800FFF4 b
    movs r0, #0x5                           @ 0800FFFE
    bl fn_0800ECF6                          @ 08010000  busy delay of r0 loop passes [r0=5]
    movs r0, #0xa                           @ 08010004
    bl rtc_read_reg                         @ 08010006  read NJU6350 register r0 [r0=10 (0xA)]
    movs r4, r0                             @ 0801000A
    uxtb r4, r4                             @ 0801000C
    cmp r4, #0x24                           @ 0801000E  compare r4 with 36 (0x24)
    bge .L08010034                          @ 08010010  if r4 >=s 36 (0x24)
    movs r0, r4                             @ 08010012
    uxtb r0, r0                             @ 08010014
    bl fn_08010118                          @ 08010016  BCD byte to binary
    ldr.w r1, =rtc_hour                     @ 0801001A
    strb r0, [r1, #0x0]                     @ 0801001E  rtc_hour = r0
    ldr.w r0, =rtc_hour                     @ 08010020
    ldrb r0, [r0, #0x0]                     @ 08010024  r0 = rtc_hour
    cmp r0, #0x18                           @ 08010026  compare rtc_hour with 24 (0x18)
    blt .L0801003C                          @ 08010028  if rtc_hour <s 24 (0x18)
    movs r0, #0xc                           @ 0801002A
    ldr.w r1, =rtc_hour                     @ 0801002C
    strb r0, [r1, #0x0]                     @ 08010030  rtc_hour = 12 (0xC)
    b .L0801003C                            @ 08010032
.L08010034:  @ reached from 08010010 bge (r4 >=s 36 (0x24))
    movs r0, #0xc                           @ 08010034
    ldr.w r1, =rtc_hour                     @ 08010036
    strb r0, [r1, #0x0]                     @ 0801003A  rtc_hour = 12 (0xC)
.L0801003C:  @ reached from 08010028 blt (rtc_hour <s 24 (0x18)), 08010032 b
    movs r0, #0x5                           @ 0801003C
    bl fn_0800ECF6                          @ 0801003E  busy delay of r0 loop passes [r0=5]
    movs r0, #0xc                           @ 08010042
    bl rtc_read_reg                         @ 08010044  read NJU6350 register r0 [r0=12 (0xC)]
    movs r4, r0                             @ 08010048
    uxtb r4, r4                             @ 0801004A
    cmp r4, #0x5a                           @ 0801004C  compare r4 with 90 (0x5A)
    bge .L08010072                          @ 0801004E  if r4 >=s 90 (0x5A)
    movs r0, r4                             @ 08010050
    uxtb r0, r0                             @ 08010052
    bl fn_08010118                          @ 08010054  BCD byte to binary
    ldr.w r1, =rtc_minute                   @ 08010058
    strb r0, [r1, #0x0]                     @ 0801005C  rtc_minute = r0
    ldr.w r0, =rtc_minute                   @ 0801005E
    ldrb r0, [r0, #0x0]                     @ 08010062  r0 = rtc_minute
    cmp r0, #0x3c                           @ 08010064  compare rtc_minute with 60 (0x3C)
    blt .L0801007A                          @ 08010066  if rtc_minute <s 60 (0x3C)
    movs r0, #0x0                           @ 08010068
    ldr.w r1, =rtc_minute                   @ 0801006A
    strb r0, [r1, #0x0]                     @ 0801006E  rtc_minute = 0
    b .L0801007A                            @ 08010070
.L08010072:  @ reached from 0801004E bge (r4 >=s 90 (0x5A))
    movs r0, #0x0                           @ 08010072
    ldr.w r1, =rtc_minute                   @ 08010074
    strb r0, [r1, #0x0]                     @ 08010078  rtc_minute = 0
.L0801007A:  @ reached from 08010066 blt (rtc_minute <s 60 (0x3C)), 08010070 b
    movs r0, #0x5                           @ 0801007A
    bl fn_0800ECF6                          @ 0801007C  busy delay of r0 loop passes [r0=5]
    movs r0, #0xe                           @ 08010080
    bl rtc_read_reg                         @ 08010082  read NJU6350 register r0 [r0=14 (0xE)]
    movs r4, r0                             @ 08010086
    uxtb r4, r4                             @ 08010088
    cmp r4, #0x5a                           @ 0801008A  compare r4 with 90 (0x5A)
    bge .L080100B0                          @ 0801008C  if r4 >=s 90 (0x5A)
    movs r0, r4                             @ 0801008E
    uxtb r0, r0                             @ 08010090
    bl fn_08010118                          @ 08010092  BCD byte to binary
    ldr.w r1, =rtc_second                   @ 08010096
    strb r0, [r1, #0x0]                     @ 0801009A  rtc_second = r0
    ldr.w r0, =rtc_second                   @ 0801009C
    ldrb r0, [r0, #0x0]                     @ 080100A0  r0 = rtc_second
    cmp r0, #0x3c                           @ 080100A2  compare rtc_second with 60 (0x3C)
    blt .L080100B8                          @ 080100A4  if rtc_second <s 60 (0x3C)
    movs r0, #0x0                           @ 080100A6
    ldr.w r1, =rtc_second                   @ 080100A8
    strb r0, [r1, #0x0]                     @ 080100AC  rtc_second = 0
    b .L080100B8                            @ 080100AE
.L080100B0:  @ reached from 0801008C bge (r4 >=s 90 (0x5A))
    movs r0, #0x0                           @ 080100B0
    ldr.w r1, =rtc_second                   @ 080100B2
    strb r0, [r1, #0x0]                     @ 080100B6  rtc_second = 0
.L080100B8:  @ reached from 080100A4 blt (rtc_second <s 60 (0x3C)), 080100AE b
    pop {r4, pc}                            @ 080100B8
ENDFUNC fn_0800FF18
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080100C4 - poll the NJU6350 seconds register and flag a change
@ Replaces : 0x080100C4 FUN_080100C4 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (loop step 4, every 10 ms)
@ RAM      : writes rtc_colon, rtc_sec_flag, rtc_sec_last
@ Spec     : analysis/keys_setup.md; DESIGN.md 3.5 step 4
@ Note     : Reads register 14 (seconds).  When it differs from rtc_sec_last the value is stored, the 1 s flag
@            rtc_sec_flag is set and the colon phase rtc_colon is toggled.  The raw BCD value is compared, not
@            converted.
@ -----------------------------------------------------------------------------
FUNC fn_080100C4
    push {r4, lr}                           @ 080100C4
    movs r0, #0xe                           @ 080100C6
    bl rtc_read_reg                         @ 080100C8  read NJU6350 register r0 [r0=14 (0xE)]
    movs r4, r0                             @ 080100CC
    ldr.w r0, =rtc_sec_last                 @ 080100CE
    ldrb r0, [r0, #0x0]                     @ 080100D2  r0 = rtc_sec_last
    movs r1, r4                             @ 080100D4
    uxtb r1, r1                             @ 080100D6
    cmp r0, r1                              @ 080100D8  compare rtc_sec_last with r1
    beq .L08010108                          @ 080100DA  if rtc_sec_last == r1
    ldr.w r0, =rtc_sec_last                 @ 080100DC
    strb r4, [r0, #0x0]                     @ 080100E0  rtc_sec_last = r4
    movs r0, #0x1                           @ 080100E2
    ldr.w r1, =rtc_sec_flag                 @ 080100E4
    strb r0, [r1, #0x0]                     @ 080100E8  rtc_sec_flag = 1
    ldr.w r0, =rtc_colon                    @ 080100EA
    ldrb r0, [r0, #0x0]                     @ 080100EE  r0 = rtc_colon
    teq r0, #0x1                            @ 080100F0  test rtc_colon ^ 1
    beq .L08010100                          @ 080100F4  if rtc_colon == 1
    movs r0, #0x1                           @ 080100F6
    ldr.w r1, =rtc_colon                    @ 080100F8
    strb r0, [r1, #0x0]                     @ 080100FC  rtc_colon = 1
    b .L08010108                            @ 080100FE
.L08010100:  @ reached from 080100F4 beq (rtc_colon == 1)
    movs r0, #0x0                           @ 08010100
    ldr.w r1, =rtc_colon                    @ 08010102
    strb r0, [r1, #0x0]                     @ 08010106  rtc_colon = 0
.L08010108:  @ reached from 080100DA beq (rtc_sec_last == r1), 080100FE b
    pop {r4, pc}                            @ 08010108
ENDFUNC fn_080100C4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08010118 - BCD byte to binary
@ Replaces : 0x08010118 FUN_08010118 (v2.05)
@ In       : r0 = BCD byte (high nibble tens, low nibble units)
@ Out      : r0 = binary value (tens * 10 + units, 8 bits)
@ Clobbers : r1-r3, flags (r4 saved)
@ Context  : ISR-safe (pure function)
@ Note     : The high nibble is taken from the byte after a zero-extend, so the result of 0xFF is 15 * 10 + 15 = 165.
@ -----------------------------------------------------------------------------
FUNC fn_08010118
    push {r4}                               @ 08010118
    movs r2, r0                             @ 0801011A
    movs r0, #0x0                           @ 0801011C
    movs r1, r2                             @ 0801011E
    uxtb r1, r1                             @ 08010120
    lsrs r1, r1, #0x4                       @ 08010122  r1 = r1 >> 4
    movs r3, r1                             @ 08010124
    ands r1, r2, #0xf                       @ 08010126  r1 = r2 & 15 (0xF)
    movs r4, r1                             @ 0801012A
    uxtb r3, r3                             @ 0801012C
    movs r1, #0xa                           @ 0801012E
    uxtb r4, r4                             @ 08010130
    mla r1, r1, r3, r4                      @ 08010132  r1 = 10 (0xA) * (r1 >> 4) + (r2 & 15 (0xF))
    movs r0, r1                             @ 08010136
    uxtb r0, r0                             @ 08010138
    pop {r4}                                @ 0801013A
    bx lr                                   @ 0801013C
ENDFUNC fn_08010118
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801013E - binary to BCD byte
@ Replaces : 0x0801013E FUN_0801013E (v2.05)
@ In       : r0 = value 0..99 (8 bits)
@ Out      : r0 = BCD byte (tens << 4 | units)
@ Clobbers : r1-r3, flags (r4, r5 saved)
@ Context  : ISR-safe (pure function)
@ Note     : Signed division by 10 as in v2.05 (sdiv); values above 99 give a tens nibble above 9.
@ -----------------------------------------------------------------------------
FUNC fn_0801013E
    push {r4, r5}                           @ 0801013E
    movs r1, r0                             @ 08010140
    movs r0, #0x0                           @ 08010142
    uxtb r1, r1                             @ 08010144
    movs r4, #0xa                           @ 08010146
    sdiv r4, r1, r4                         @ 08010148  r4 = r1 / 10 (0xA)
    movs r2, r4                             @ 0801014C
    uxtb r1, r1                             @ 0801014E
    movs r4, #0xa                           @ 08010150
    sdiv r5, r1, r4                         @ 08010152  r5 = r1 / 10 (0xA)
    mls r4, r4, r5, r1                      @ 08010156  r4 = r1 - 10 (0xA) * (r1 / 10 (0xA))
    movs r3, r4                             @ 0801015A
    uxtb r2, r2                             @ 0801015C
    uxtb r3, r3                             @ 0801015E
    adds r4, r3, r2, lsl #0x4               @ 08010160  r4 = (r1 - 10 (0xA) * (r1 / 10 (0xA))) + ((r1 / 10 (0xA)) << 0x4)
    movs r0, r4                             @ 08010164
    uxtb r0, r0                             @ 08010166
    pop {r4, r5}                            @ 08010168
    bx lr                                   @ 0801016A
ENDFUNC fn_0801013E
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801016C - write year, month, day, hour, minute and second from RAM to the NJU6350
@ Replaces : 0x0801016C FUN_0801016C (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (setup editors, set-clock frame)
@ RAM      : reads rtc_day, rtc_hour, rtc_minute, rtc_month, rtc_second, rtc_year
@ Spec     : analysis/ble_packet.md 6 (F8 set-clock frame); NJU6350 datasheet data writing
@ Note     : Writes registers 2, 4, 6, 10, 12, 14 with rtc_year, rtc_month, rtc_day, rtc_hour, rtc_minute, rtc_second
@            (binary values; rtc_write_reg converts each to BCD).  The day of week (register 8) is never written or
@            read by v2.05.
@ -----------------------------------------------------------------------------
FUNC fn_0801016C
    push {r7, lr}                           @ 0801016C
    ldr.w r0, =rtc_year                     @ 0801016E
    ldrb r1, [r0, #0x0]                     @ 08010170  r1 = rtc_year
    movs r0, #0x2                           @ 08010172
    bl rtc_write_reg                        @ 08010174  write NJU6350 register r0 = value r1 [r0=2, r1=rtc_year]
    ldr.w r0, =rtc_month                    @ 08010178
    ldrb r1, [r0, #0x0]                     @ 0801017A  r1 = rtc_month
    movs r0, #0x4                           @ 0801017C
    bl rtc_write_reg                        @ 0801017E  write NJU6350 register r0 = value r1 [r0=4, r1=rtc_month]
    ldr.w r0, =rtc_day                      @ 08010182
    ldrb r1, [r0, #0x0]                     @ 08010184  r1 = rtc_day
    movs r0, #0x6                           @ 08010186
    bl rtc_write_reg                        @ 08010188  write NJU6350 register r0 = value r1 [r0=6, r1=rtc_day]
    ldr.w r0, =rtc_hour                     @ 0801018C
    ldrb r1, [r0, #0x0]                     @ 0801018E  r1 = rtc_hour
    movs r0, #0xa                           @ 08010190
    bl rtc_write_reg                        @ 08010192  write NJU6350 register r0 = value r1 [r0=10 (0xA), r1=rtc_hour]
    ldr.w r0, =rtc_minute                   @ 08010196
    ldrb r1, [r0, #0x0]                     @ 08010198  r1 = rtc_minute
    movs r0, #0xc                           @ 0801019A
    bl rtc_write_reg                        @ 0801019C  write NJU6350 register r0 = value r1 [r0=12 (0xC), r1=rtc_minute]
    ldr.w r0, =rtc_second                   @ 080101A0
    ldrb r1, [r0, #0x0]                     @ 080101A2  r1 = rtc_second
    movs r0, #0xe                           @ 080101A4
    bl rtc_write_reg                        @ 080101A6  write NJU6350 register r0 = value r1 [r0=14 (0xE), r1=rtc_second]
    pop {r0, pc}                            @ 080101AA
ENDFUNC fn_0801016C
    .ltorg

@ -----------------------------------------------------------------------------
@ rtc_write_reg - write one NJU6350 register
@ Replaces : 0x080101AC rtc_write_reg (v2.05)
@ In       : r0 = register number (2, 4, 6, 10, 12, 14), r1 = value (8 bits)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : NJU6350 datasheet 2. Data writing: command nibble C2 C1 C0 RW with RW = 1, then 8 data bits, LSB first
@ Note     : The data byte is first converted to BCD (fn_0801013E).  CE is raised (rtc_ce_high), the command nibble
@            (register + 1, so RW = 1) and the data byte are clocked out, then CE is lowered.  Delays of 5 passes
@            follow the CE rise and precede the CE fall.
@ -----------------------------------------------------------------------------
FUNC rtc_write_reg
    push {r4, r5, r6, lr}                   @ 080101AC
    movs r4, r0                             @ 080101AE
    movs r5, r1                             @ 080101B0
    movs r0, r5                             @ 080101B2
    uxtb r0, r0                             @ 080101B4
    bl fn_0801013E                          @ 080101B6  binary to BCD byte
    movs r6, r0                             @ 080101BA
    bl rtc_ce_high                          @ 080101BC  start an NJU6350 transaction (CLK low, DATA low, CE high)
    movs r0, #0x5                           @ 080101C0
    bl fn_0800ECF6                          @ 080101C2  busy delay of r0 loop passes [r0=5]
    adds r0, r4, #0x1                       @ 080101C6  r0 = r4 + 1
    uxtb r0, r0                             @ 080101C8
    bl fn_08010204                          @ 080101CA  clock out the 4-bit command nibble r0, LSB first [r0=(r4 + 1)]
    movs r0, r6                             @ 080101CE
    uxtb r0, r0                             @ 080101D0
    bl fn_080102B8                          @ 080101D2  clock out the data byte r0, LSB first
    movs r0, #0x5                           @ 080101D6
    bl fn_0800ECF6                          @ 080101D8  busy delay of r0 loop passes [r0=5]
    bl rtc_ce_low                           @ 080101DC  end an NJU6350 transaction
    pop {r4, r5, r6, pc}                    @ 080101E0
ENDFUNC rtc_write_reg
    .ltorg

@ -----------------------------------------------------------------------------
@ rtc_read_reg - read one NJU6350 register
@ Replaces : 0x080101E2 rtc_read_reg (v2.05)
@ In       : r0 = register number (2, 4, 6, 10, 12, 14)
@ Out      : r0 = raw BCD byte
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : NJU6350 datasheet 3. Data reading: command nibble with RW = 0, then 8 data bits, LSB first, driven by the
@            chip
@ Deviation: HW-01 (CE and DATA handling in rtc_ce_high / rtc_ce_low / fn_08010204)
@ Note     : The register number has bit 0 clear, so RW = 0 (read).
@ -----------------------------------------------------------------------------
FUNC rtc_read_reg
    push {r3, r4, r5, lr}                   @ 080101E2
    movs r4, r0                             @ 080101E4
    movs r5, #0x0                           @ 080101E6
    bl rtc_ce_high                          @ 080101E8  start an NJU6350 transaction (CLK low, DATA low, CE high)
    movs r0, r4                             @ 080101EC
    uxtb r0, r0                             @ 080101EE
    bl fn_08010204                          @ 080101F0  clock out the 4-bit command nibble r0, LSB first
    bl rtc_read_byte                        @ 080101F4  clock in 8 data bits from the NJU6350
    movs r5, r0                             @ 080101F8
    bl rtc_ce_low                           @ 080101FA  end an NJU6350 transaction
    movs r0, r5                             @ 080101FE
    uxtb r0, r0                             @ 08010200
    pop {r1, r4, r5, pc}                    @ 08010202
ENDFUNC rtc_read_reg
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08010204 - clock out the 4-bit NJU6350 command nibble
@ Replaces : 0x08010204 FUN_08010204 (v2.05)
@ In       : r0 = command nibble C2 C1 C0 RW (bit 0 = RW)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : NJU6350 datasheet: data is taken on the rising CLK edge, LSB first; for RW = 0 the chip drives DATA after
@            the falling CLK edge that follows the 4th command bit
@ Deviation: HW-01: for a read command (RW = 0) PB7 is released (written 1) right after the rising edge of command bit
@            4, so the open-drain pin never fights the chip that starts driving DATA at the next falling edge; one
@            delay pass is added between the DATA store and the rising CLK edge (pull-up rise time of the open-drain
@            pin)
@ Note     : Per bit: DATA = bit (BSRR PB7), CLK high, delay 5, CLK low, delay 5 (v2.05 0x08010222..0x08010246).
@            v2.05 left PB7 push-pull and driven for the whole transaction (DESIGN.md 4.2).
@ -----------------------------------------------------------------------------
FUNC fn_08010204
    push {r4, r5, r6, lr}                   @ 08010204
    movs r4, r0                             @ 08010206
    movs r0, #0x0                           @ 08010208
    movs r5, r0                             @ 0801020A
.L0801020C:  @ reached from 0801024C b
    uxtb r5, r5                             @ 0801020C
    cmp r5, #0x4                            @ 0801020E  compare r5 with 4
    bge .L0801024E                          @ 08010210  if r5 >=s 4
    uxtb r4, r4                             @ 08010212
    movs r0, r4                             @ 08010214
    asrs r0, r5                             @ 08010216  r0 = r0 >> r5
    ands r0, r0, #0x1                       @ 08010218  r0 = (r0 >> r5) & 1
    movs r6, r0                             @ 0801021C
    uxtb r6, r6                             @ 0801021E
    cmp r6, #0x1                            @ 08010220  compare ((r0 >> r5) & 1) with 1
    bne .L0801022C                          @ 08010222  if ((r0 >> r5) & 1) != 1
    movs r0, #0x80                          @ 08010224
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRL)    @ 08010226
    strh r0, [r1, #0x0]                     @ 08010228  [(GPIOB_BASE + GPIO_BSRRL)] = 128 (0x80)
    b .L08010232                            @ 0801022A
.L0801022C:  @ reached from 08010222 bne (((r0 >> r5) & 1) != 1)
    movs r0, #0x80                          @ 0801022C
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRH)    @ 0801022E
    strh r0, [r1, #0x0]                     @ 08010230  [(GPIOB_BASE + GPIO_BSRRH)] = 128 (0x80)
.L08010232:  @ reached from 0801022A b
    @ HW-01: data setup time.  The open-drain pin rises through the internal pull-up (RPU 30..60 kohm, STM32L152
    @ datasheet) in up to about 2 us; the 6 cycles (1.4 us at 4.19 MHz) between the data store and the CLK
    @ rising edge of v2.05 are not enough.  One delay pass (about 5 us) is added before the clock rises.
    movs r0, #1
    bl fn_0800ECF6                       @ delay(1) before CLK high
    movs r0, #0x40                          @ 08010232
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRL)    @ 08010234
    strh r0, [r1, #0x0]                     @ 08010236  [(GPIOB_BASE + GPIO_BSRRL)] = 64 (0x40)
    @ HW-01: release DATA after the rising edge of command bit 4 when RW = 0 (read)
    uxtb r0, r5                          @ bit index 0..3
    cmp r0, #3                           @ only the 4th bit
    bne .Lrcn_done                       @ not the 4th bit: nothing to release
    tst r4, #1                           @ RW bit of the command
    bne .Lrcn_done                       @ RW = 1 (write): DATA stays under MCU control
    GPIO_SET GPIOB_BASE, 0x0080          @ PB7 = 1: open-drain output released, the chip may drive DATA
.Lrcn_done:
    movs r0, #0x5                           @ 08010238
    bl fn_0800ECF6                          @ 0801023A  busy delay of r0 loop passes [r0=5]
    movs r0, #0x40                          @ 0801023E
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRH)    @ 08010240
    strh r0, [r1, #0x0]                     @ 08010242  [(GPIOB_BASE + GPIO_BSRRH)] = 64 (0x40)
    movs r0, #0x5                           @ 08010244
    bl fn_0800ECF6                          @ 08010246  busy delay of r0 loop passes [r0=5]
    adds r5, r5, #0x1                       @ 0801024A  r5 = r5 + 1
    b .L0801020C                            @ 0801024C
.L0801024E:  @ reached from 08010210 bge (r5 >=s 4)
    pop {r4, r5, r6, pc}                    @ 0801024E
ENDFUNC fn_08010204
    .ltorg

@ -----------------------------------------------------------------------------
@ rtc_read_byte - clock in the 8 data bits of a register read
@ Replaces : 0x08010254 rtc_read_byte (v2.05)
@ In       : -
@ Out      : r0 = byte (first bit received = bit 0)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : NJU6350 datasheet 3. Data reading: the chip changes DATA on the falling CLK edge; read after the rising
@            edge
@ Deviation: HW-01 (PB7 switched with brd_gpio_init, open-drain with pull-up, never push-pull)
@ Note     : DATA (PB7) is released before the call; here it is switched to input with pull-up
@            (rtc_data_pin_input_pullup, v2.05 0x0801025E), 8 bits are sampled from GPIOB_IDR bit 7 after each CLK
@            rising edge (LSB first, shifted right), and the pin is returned to the open-drain output
@            (rtc_data_pin_output, v2.05 0x080102A4) while CE is still high.  Because the output is released (ODR = 1)
@            the chip is never driven against.
@ -----------------------------------------------------------------------------
FUNC rtc_read_byte
    push {r3, r4, r5, lr}                   @ 08010254
    movs r5, #0x0                           @ 08010256
    movs r0, #0x5                           @ 08010258
    bl fn_0800ECF6                          @ 0801025A  busy delay of r0 loop passes [r0=5]
    bl rtc_data_pin_input_pullup            @ 0801025E  PB7 input with pull-up
    movs r0, #0x5                           @ 08010262
    bl fn_0800ECF6                          @ 08010264  busy delay of r0 loop passes [r0=5]
    movs r0, #0x0                           @ 08010268
    movs r4, r0                             @ 0801026A
.L0801026C:  @ reached from 080102A2 b
    uxtb r4, r4                             @ 0801026C
    cmp r4, #0x8                            @ 0801026E  compare r4 with 8
    bge .L080102A4                          @ 08010270  if r4 >=s 8
    movs r0, #0x40                          @ 08010272
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRL)    @ 08010274
    strh r0, [r1, #0x0]                     @ 08010276  [(GPIOB_BASE + GPIO_BSRRL)] = 64 (0x40)
    movs r0, #0x5                           @ 08010278
    bl fn_0800ECF6                          @ 0801027A  busy delay of r0 loop passes [r0=5]
    ldr.w r0, =(GPIOB_BASE + GPIO_IDR)      @ 0801027E
    ldrh r0, [r0, #0x0]                     @ 08010280  r0 = [(GPIOB_BASE + GPIO_IDR)]
    lsls r0, r0, #0x18                      @ 08010282  r0 = [(GPIOB_BASE + GPIO_IDR)] << 24 (0x18)
    bpl .L0801028A                          @ 08010284  if bit 7 of [(GPIOB_BASE + GPIO_IDR)] is clear
    orrs r5, r5, #0x80                      @ 08010286  r5 = r5 | 128 (0x80)
.L0801028A:  @ reached from 08010284 bpl (bit 7 of [(GPIOB_BASE + GPIO_IDR)] is clear)
    movs r0, #0x40                          @ 0801028A
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRH)    @ 0801028C
    strh r0, [r1, #0x0]                     @ 0801028E  [(GPIOB_BASE + GPIO_BSRRH)] = 64 (0x40)
    movs r0, #0x5                           @ 08010290
    bl fn_0800ECF6                          @ 08010292  busy delay of r0 loop passes [r0=5]
    uxtb r4, r4                             @ 08010296
    cmp r4, #0x7                            @ 08010298  compare r4 with 7
    bge .L080102A0                          @ 0801029A  if r4 >=s 7
    uxtb r5, r5                             @ 0801029C
    lsrs r5, r5, #0x1                       @ 0801029E  r5 = r5 >> 1
.L080102A0:  @ reached from 0801029A bge (r4 >=s 7)
    adds r4, r4, #0x1                       @ 080102A0  r4 = r4 + 1
    b .L0801026C                            @ 080102A2
.L080102A4:  @ reached from 08010270 bge (r4 >=s 8)
    bl rtc_data_pin_output                  @ 080102A4  PB7 open-drain output with pull-up
    movs r0, #0x5                           @ 080102A8
    bl fn_0800ECF6                          @ 080102AA  busy delay of r0 loop passes [r0=5]
    movs r0, r5                             @ 080102AE
    uxtb r0, r0                             @ 080102B0
    pop {r1, r4, r5, pc}                    @ 080102B2
ENDFUNC rtc_read_byte
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080102B8 - clock out one NJU6350 data byte
@ Replaces : 0x080102B8 FUN_080102B8 (v2.05)
@ In       : r0 = byte
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : NJU6350 datasheet 2. Data writing: LSB first, data taken on the rising CLK edge
@ Deviation: HW-01: one delay pass between the data store and the rising CLK edge (setup time for the pull-up rise of
@            the open-drain pin, see fn_08010204)
@ Note     : Per bit: CLK low, delay 5, DATA = bit, CLK high, delay 5 (v2.05 0x080102C6..0x080102FA); the clock is
@            left high.
@ -----------------------------------------------------------------------------
FUNC fn_080102B8
    push {r4, r5, r6, lr}                   @ 080102B8
    movs r4, r0                             @ 080102BA
    movs r0, #0x0                           @ 080102BC
    movs r5, r0                             @ 080102BE
.L080102C0:  @ reached from 08010300 b
    uxtb r5, r5                             @ 080102C0
    cmp r5, #0x8                            @ 080102C2  compare r5 with 8
    bge .L08010302                          @ 080102C4  if r5 >=s 8
    movs r0, #0x40                          @ 080102C6
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRH)    @ 080102C8
    strh r0, [r1, #0x0]                     @ 080102CA  [(GPIOB_BASE + GPIO_BSRRH)] = 64 (0x40)
    movs r0, #0x5                           @ 080102CC
    bl fn_0800ECF6                          @ 080102CE  busy delay of r0 loop passes [r0=5]
    uxtb r4, r4                             @ 080102D2
    movs r0, r4                             @ 080102D4
    asrs r0, r5                             @ 080102D6  r0 = r0 >> r5
    ands r0, r0, #0x1                       @ 080102D8  r0 = (r0 >> r5) & 1
    movs r6, r0                             @ 080102DC
    uxtb r6, r6                             @ 080102DE
    cmp r6, #0x1                            @ 080102E0  compare ((r0 >> r5) & 1) with 1
    bne .L080102EC                          @ 080102E2  if ((r0 >> r5) & 1) != 1
    movs r0, #0x80                          @ 080102E4
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRL)    @ 080102E6
    strh r0, [r1, #0x0]                     @ 080102E8  [(GPIOB_BASE + GPIO_BSRRL)] = 128 (0x80)
    b .L080102F2                            @ 080102EA
.L080102EC:  @ reached from 080102E2 bne (((r0 >> r5) & 1) != 1)
    movs r0, #0x80                          @ 080102EC
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRH)    @ 080102EE
    strh r0, [r1, #0x0]                     @ 080102F0  [(GPIOB_BASE + GPIO_BSRRH)] = 128 (0x80)
.L080102F2:  @ reached from 080102EA b
    movs r0, #1
    bl fn_0800ECF6                       @ HW-01: delay(1) between the DATA store and CLK high (pull-up rise time)
    movs r0, #0x40                          @ 080102F2
    ldr.w r1, =(GPIOB_BASE + GPIO_BSRRL)    @ 080102F4
    strh r0, [r1, #0x0]                     @ 080102F6  [(GPIOB_BASE + GPIO_BSRRL)] = 64 (0x40)
    movs r0, #0x5                           @ 080102F8
    bl fn_0800ECF6                          @ 080102FA  busy delay of r0 loop passes [r0=5]
    adds r5, r5, #0x1                       @ 080102FE  r5 = r5 + 1
    b .L080102C0                            @ 08010300
.L08010302:  @ reached from 080102C4 bge (r5 >=s 8)
    pop {r4, r5, r6, pc}                    @ 08010302
ENDFUNC fn_080102B8
    .ltorg

@ -----------------------------------------------------------------------------
@ rtc_ce_high - start an NJU6350 transaction: CLK low, DATA low, CE high
@ Replaces : 0x08010308 rtc_ce_high (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : NJU6350 datasheet: CLK must be low when CE rises or falls; PB6 = CLK, PB7 = DATA, PC13 = CE
@ Deviation: HW-01: PB7 is made an open-drain output with pull-up before the first edge, so the pin configuration does
@            not depend on what an earlier read left behind
@ -----------------------------------------------------------------------------
FUNC rtc_ce_high
    push {lr}
    bl rtc_data_pin_output               @ HW-01: PB7 open-drain with pull-up (ODR unchanged, idle low)
    GPIO_CLR GPIOB_BASE, 0x0040          @ PB6 CLK low (v2.05 0x08010308)
    GPIO_CLR GPIOB_BASE, 0x0080          @ PB7 DATA low (v2.05 0x0801030E)
    GPIO_SET GPIOC_BASE, 0x2000          @ PC13 CE high (v2.05 0x08010314)
    pop {pc}
ENDFUNC rtc_ce_high
    .ltorg

@ -----------------------------------------------------------------------------
@ rtc_ce_low - end an NJU6350 transaction: CLK low, CE low, then DATA low
@ Replaces : 0x0801031E rtc_ce_low (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : main only
@ Spec     : NJU6350 datasheet: the chip drives DATA until CE falls (3. Data reading); CLK must be low at the CE edge
@ Deviation: HW-01: v2.05 drove DATA low (push-pull) before CE fell, i.e. while the chip could still be driving it;
@            the port releases CE first and only then pulls DATA low (idle level of v2.05)
@ -----------------------------------------------------------------------------
FUNC rtc_ce_low
    GPIO_CLR GPIOB_BASE, 0x0040          @ PB6 CLK low (v2.05 0x0801031E)
    GPIO_CLR GPIOC_BASE, 0x2000          @ PC13 CE low: the chip releases DATA here (v2.05 0x0801032A, now before DATA)
    GPIO_CLR GPIOB_BASE, 0x0080          @ PB7 DATA low, idle level (v2.05 0x08010324, now after CE)
    bx lr
ENDFUNC rtc_ce_low
    .ltorg

@ -----------------------------------------------------------------------------
@ rtc_data_pin_output - PB7 (NJU6350 DATA) as open-drain output with internal pull-up
@ Replaces : 0x0801033C rtc_data_pin_output (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : DESIGN.md 4.2 (PB7 row), HW-01; RM0038 7.4 (OTYPER, PUPDR)
@ Deviation: HW-01: v2.05 configured push-pull (struct otype 0 at 0x08010346..0x0801034C); the port uses open-drain
@            with the internal pull-up, so writing 1 releases the line.  The output level (ODR) is left as it is.
@ -----------------------------------------------------------------------------
FUNC rtc_data_pin_output
    push {lr}
    ldr r0, =GPIOB_BASE                  @ port B
    ldr r1, =rtc_desc_data_od            @ descriptor: PB7, output, 2 MHz, open-drain, pull-up, ODR kept
    bl brd_gpio_init                     @ policy-checked write (PB7 may only be open-drain or input)
    pop {pc}
ENDFUNC rtc_data_pin_output
    .ltorg

@ -----------------------------------------------------------------------------
@ rtc_data_pin_input_pullup - PB7 (NJU6350 DATA) as input with internal pull-up
@ Replaces : 0x08010378 rtc_data_pin_input_pullup (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : DESIGN.md 4.2 (PB7 row); RM0038 7.4
@ Deviation: written through brd_gpio_init (v2.05 gpio_init with a stack structure, 0x0801037C..0x08010396; its otype
@            byte at [sp+6] was never set)
@ -----------------------------------------------------------------------------
FUNC rtc_data_pin_input_pullup
    push {lr}
    ldr r0, =GPIOB_BASE                  @ port B
    ldr r1, =rtc_desc_data_in            @ descriptor: PB7, input, pull-up
    bl brd_gpio_init                     @ policy-checked write
    pop {pc}
ENDFUNC rtc_data_pin_input_pullup
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080103A8 - limit the day to the days of the month
@ Replaces : 0x080103A8 FUN_080103A8 (v2.05)
@ In       : r0 = year 0..99, r1 = month 1..12, r2 = day
@ Out      : r0 = min(day, days in month)
@ Clobbers : r1-r3, flags (r4-r8 saved)
@ Context  : main only
@ Note     : Called by the year and month editors after the month or the year changed.
@ -----------------------------------------------------------------------------
FUNC fn_080103A8
    push {r4, r5, r6, r7, r8, lr}           @ 080103A8
    movs r4, r0                             @ 080103AC
    movs r5, r1                             @ 080103AE
    movs r6, r2                             @ 080103B0
    movs r7, r6                             @ 080103B2
    movs r1, r5                             @ 080103B4
    uxtb r1, r1                             @ 080103B6
    movs r0, r4                             @ 080103B8
    uxtb r0, r0                             @ 080103BA
    bl fn_080103D8                          @ 080103BC  days in month (year r0, month r1)
    mov r8, r0                              @ 080103C0
    mov r0, r8                              @ 080103C2
    movs r1, r7                             @ 080103C4
    uxtb r0, r0                             @ 080103C6
    uxtb r1, r1                             @ 080103C8
    cmp r0, r1                              @ 080103CA  compare r0 with r1
    bcs .L080103D0                          @ 080103CC  if r0 >=u r1
    mov r7, r8                              @ 080103CE
.L080103D0:  @ reached from 080103CC bcs (r0 >=u r1)
    movs r0, r7                             @ 080103D0
    uxtb r0, r0                             @ 080103D2
    pop {r4, r5, r6, r7, r8, pc}            @ 080103D4
ENDFUNC fn_080103A8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080103D8 - days in a month
@ Replaces : 0x080103D8 FUN_080103D8 (v2.05)
@ In       : r0 = year 0..99 (2000 + r0), r1 = month 1..12
@ Out      : r0 = days (28..31)
@ Clobbers : r1-r3, flags (r4-r6 saved)
@ Context  : ISR-safe (pure function)
@ Note     : The table of 12 month lengths (31 28 31 30 31 30 31 31 30 31 30 31) is copied from v205_tab_08029190 to
@            the stack; February is set to 29 in a leap year (divisible by 4 and not by 100, or by 400).  A month
@            outside 1..12 indexes outside the 12-byte copy (month 0: the byte below the stack pointer, month 13: the
@            low byte of the saved r4), as in v2.05; every caller passes 1..12 (the clock reader and the month editor
@            limit it).
@ -----------------------------------------------------------------------------
FUNC fn_080103D8
    push {r1, r2, r3, r4, r5, r6}           @ 080103D8
    movs r2, r0                             @ 080103DA
    mov r0, sp                              @ 080103DC
    ldr.w r3, =v205_tab_08029190            @ 080103DE
    ldmia r3!, {r4, r5, r6}                 @ 080103E0
    stmia r0!, {r4, r5, r6}                 @ 080103E2
    subs r3, #0xc                           @ 080103E4  r3 = r3 - 12 (0xC)
    subs r0, #0xc                           @ 080103E6  r0 = r0 - 12 (0xC)
    uxtb r2, r2                             @ 080103E8
    adds r3, r2, #0x7d0                     @ 080103EA  r3 = r2 + 2000 (0x7D0)
    tst r3, #0x3                            @ 080103EE  test (r2 + 2000 (0x7D0)) & 3
    bne .L08010402                          @ 080103F2  if ((r2 + 2000 (0x7D0)) & 3) != 0
    movs r0, #0x64                          @ 080103F4
    udiv r4, r3, r0                         @ 080103F6  r4 = (r2 + 2000 (0x7D0)) / 100 (0x64)
    mls r0, r0, r4, r3                      @ 080103FA  r0 = (r2 + 2000 (0x7D0)) - 100 (0x64) * ((r2 + 2000 (0x7D0)) / 100 (0x64))
    cmp r0, #0x0                            @ 080103FE  compare ((r2 + 2000 (0x7D0)) - 100 (0x64) * ((r2 + 2000 (0x7D0)) / 100 (0x64))) with 0
    bne .L08010412                          @ 08010400  if ((r2 + 2000 (0x7D0)) - 100 (0x64) * ((r2 + 2000 (0x7D0)) / 100 (0x64))) != 0
.L08010402:  @ reached from 080103F2 bne (((r2 + 2000 (0x7D0)) & 3) != 0)
    mov r0, #0x190                          @ 08010402
    udiv r4, r3, r0                         @ 08010406  r4 = r3 / 400 (0x190)
    mls r0, r0, r4, r3                      @ 0801040A  r0 = r3 - 400 (0x190) * (r3 / 400 (0x190))
    cmp r0, #0x0                            @ 0801040E  compare (r3 - 400 (0x190) * (r3 / 400 (0x190))) with 0
    bne .L08010418                          @ 08010410  if (r3 - 400 (0x190) * (r3 / 400 (0x190))) != 0
.L08010412:  @ reached from 08010400 bne (((r2 + 2000 (0x7D0)) - 100 (0x64) * ((r2 + 2000 (0x7D0)) / 100 (0x64))) != 0)
    movs r0, #0x1d                          @ 08010412
    strb r0, [sp, #0x1]                     @ 08010414  local [sp+1] = 29 (0x1D)
.L08010418:  @ reached from 08010410 bne ((r3 - 400 (0x190) * (r3 / 400 (0x190))) != 0)
    mov r0, sp                              @ 08010418
    uxtb r1, r1                             @ 0801041A
    add r0, r1                              @ 0801041C  r0 = r0 + r1
    ldrb r0, [r0, #-0x1]                    @ 0801041E  r0 = [r0+-1]
    pop {r1, r2, r3, r4, r5, r6}            @ 08010422
    bx lr                                   @ 08010424
ENDFUNC fn_080103D8
    .ltorg

    .section .rodata.rtc, "a", %progbits
    .balign 4
@ PB7 as open-drain output with pull-up, ODR kept (GPIO_DESC of macros.inc: mask, mode, speed, otype, pupd, af, level)
rtc_desc_data_od:
    GPIO_DESC 0x0080, GPIO_MODE_OUT, GPIO_SPEED_2M, GPIO_OT_OD, GPIO_PUPD_UP, 0, BRD_LEVEL_KEEP
@ PB7 as input with pull-up
rtc_desc_data_in:
    GPIO_DESC 0x0080, GPIO_MODE_IN, GPIO_SPEED_2M, GPIO_OT_PP, GPIO_PUPD_UP, 0, BRD_LEVEL_KEEP
