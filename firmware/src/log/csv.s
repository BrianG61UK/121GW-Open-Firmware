@ csv.s - LOG module: the CSV text of the log file: header lines, data rows, min/max rows and the token writer (DESIGN.md 6.22, W8)
@
@ The log file is a text file with CRLF line ends.  Everything is produced by log_write_csv_token, which appends the string
@ of one "token" to the buffer log_buf and writes it to the file (log_write_bytes).  The strings live in the RAM data image
@ (v2.05 initialised RAM, initial values analysis/decompile/ram_init.txt) and are listed by log_token_strings in this file.
@
@ File layout (header written once per run by log_write_header):
@     START,YYYY/MM/DD,hh:mm:ss,        token 5, 0x66, 0x67, 1       start time stamp of the log
@     ID,nnnnnnnnn,                     token 6, 0x68, 1             four digits of the date code (rtc_date_code), five digits of the setup ID
@     INTERVAL,nnn,sec,                 token 7, 0x65, 8, 1          logging interval
@     ,,,MAIN,,,SUB-1,,,SUB-2,,,Remark, tokens 0xB 0xC 0xD 0xE, 1    group titles
@     No. ,Date      ,Time    ,Func. ,Value,Unit,Func. ,Value,Unit,Func. ,Value,Unit,   column titles
@ Data row (log_write_row):
@     No.,date,time,main func,value,unit[,second func,value,unit[,third func,value,unit]],remark
@   the value of a reading is "Overflow" or "-Overflow" (flags bit 7, bit 6) or an optional "-" and six digits with a
@   decimal point (log_write_value).  Remark = PeakHold, 1KHz or ACDC from the flag bits 3, 2, 4 of the main reading (the tests
@   are made in that order, only the first that is set is written).
@ Closing rows (log_write_minmax_rows): the maximum and the minimum row of the file, written when logging stops.
@
@ Token numbers: 0x00 "," 0x01 CRLF 0x02 "-Overflow" 0x03 "Overflow" 0x04 "-" 0x05 "START," 0x06 "ID," 0x07 "INTERVAL,"
@ 0x08 "sec," 0x0B..0x0E group titles 0x0F..0x14 column titles 0x15..0x2E function names (0x15 + mode) 0x33..0x47 unit
@ strings 0x51..0x53 remarks, 0x5B "MAX," 0x5C "MIN,", dynamic: 0x64 decimal number (r1), 0x65 interval digits, 0x66/0x6E
@ date, 0x67/0x6F time, 0x68 ID digits, 0xC8 fixed point number (r1 magnitude, r2 decimal places).
@

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.log, "ax", %progbits

@ names of the v2.05 variables used in this file (addresses unchanged, DESIGN.md 5.1)
    .equ log_interval,            v_2000022C            @ 0x2000022C logging interval in seconds (u16; setup item 9, EEPROM 0x18); 0 = no timed records
    .equ log_fil,                 ff16_fil_a            @ production image: FatFs R0.16 objects (FIL 552 bytes, DIR 44: larger than the v2.05 areas) in .bss_port (ff16_api.s, IMP-29)
    .equ sys_id_number,           v_20007D14            @ 0x20007D14 setup ID number (u32) printed by the ID line of the CSV header
    .equ log_view_value1,         v_20007D1C            @ 0x20007D1C main value of the record loaded by log_slot_load (i32)
    .equ log_view_value2,         v_20007D20            @ 0x20007D20 second value of the loaded record
    .equ log_view_value3,         v_20007D24            @ 0x20007D24 third value of the loaded record
    .equ log_row_no,              v_20007D40            @ 0x20007D40 number of the last row written to the file (CSV column "No.")
    .equ log_max_value,           v_20007D4C            @ 0x20007D4C maximum main value of the file so far (complemented when negative)
    .equ log_min_value,           v_20007D50            @ 0x20007D50 minimum main value of the file so far
    .equ log_max_row,             v_20007D54            @ 0x20007D54 row number of the maximum
    .equ log_min_row,             v_20007D58            @ 0x20007D58 row number of the minimum
    .equ log_flush_start,         v_20007EDC            @ 0x20007EDC file size at the start of the running flush (position to go back to when the flush fails)
    .equ log_file_size,           v_20007EE0            @ 0x20007EE0 size of the log file after the last good flush
    .equ rtc_date_code,           v_20007F9A            @ 0x20007F9A date code shown by setup page 8 (u16)
    .equ log_view_flag0,          v_20007FE5            @ 0x20007FE5 flags bit 0 of the loaded record (source flag 0x20008098, LowZ AC variant: hy3131_modes_ac_current.md)
    .equ log_view_flag2,          v_20007FE7            @ 0x20007FE7 flags bit 2 of the loaded record (source 0x200080B9 filter_1khz; CSV remark 1KHz)
    .equ log_view_flag3,          v_20007FE8            @ 0x20007FE8 flags bit 3 of the loaded record (source 0x200080B7 peak_hold; CSV remark PeakHold)
    .equ log_view_flag4,          v_20007FE9            @ 0x20007FE9 flags bit 4 of the loaded record (source 0x200080BA AC+DC; CSV remark ACDC)
    .equ log_view_flag5,          v_20007FEA            @ 0x20007FEA flags bit 5 of the loaded record (source 0x200080AB, temperature unit Celsius: lcd_map.md)
    .equ log_view_flags1,         v_20007FF5            @ 0x20007FF5 main flags of the loaded record
    .equ log_view_flags2,         v_20007FF7            @ 0x20007FF7 second flags of the loaded record
    .equ log_view_flags3,         v_20007FF9            @ 0x20007FF9 third flags of the loaded record
    .equ log_start_year,          v_20007FFB            @ 0x20007FFB start time stamp of the log (years since 2000)
    .equ log_start_month,         v_20007FFC            @ 0x20007FFC start time stamp month
    .equ log_start_day,           v_20007FFD            @ 0x20007FFD start time stamp day
    .equ log_start_hour,          v_20007FFE            @ 0x20007FFE start time stamp hour
    .equ log_start_minute,        v_20007FFF            @ 0x20007FFF start time stamp minute
    .equ log_start_second,        v_20008000            @ 0x20008000 start time stamp second
    .equ log_view_year,           v_20008007            @ 0x20008007 date of the loaded record (years since 2000)
    .equ log_view_month,          v_20008008            @ 0x20008008 month of the loaded record
    .equ log_view_day,            v_20008009            @ 0x20008009 day of the loaded record
    .equ log_view_hour,           v_2000800A            @ 0x2000800A hour of the loaded record
    .equ log_view_minute,         v_2000800B            @ 0x2000800B minute of the loaded record
    .equ log_view_second,         v_2000800C            @ 0x2000800C second of the loaded record
    .equ log_view_mode1,          v_2000801E            @ 0x2000801E mode of the main reading of the loaded record
    .equ log_view_range1,         v_2000801F            @ 0x2000801F range of the main reading of the loaded record
    .equ log_view_mode2,          v_20008020            @ 0x20008020 mode of the second reading of the loaded record
    .equ log_view_range2,         v_20008021            @ 0x20008021 range of the second reading of the loaded record
    .equ log_view_mode3,          v_20008022            @ 0x20008022 mode of the third reading of the loaded record
    .equ log_view_range3,         v_20008023            @ 0x20008023 range of the third reading of the loaded record
    .equ log_max_func,            v_20008027            @ 0x20008027 function code of the maximum row
    .equ log_min_func,            v_20008028            @ 0x20008028 function code of the minimum row
    .equ log_max_flags,           v_20008029            @ 0x20008029 flags of the maximum row
    .equ log_min_flags,           v_2000802A            @ 0x2000802A flags of the minimum row

@ -----------------------------------------------------------------------------
@ log_write_row - write the data row of ring slot r0 (rows are written in ring order)
@ Replaces  : 0x0801DBF0 FUN_0801DBF0 (v2.05), called by log_flush_records
@ In        : r0 = slot index 0..59 (u16)
@ Out       : r0 = 0 ok, 1 a write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_row_no, the loaded record (log_view_* from log_slot_load) and the flag bytes log_view_flag2..4;
@             negates log_view_value2 and log_view_value3 when they are negative (v2.05 does so, the values are not used afterwards)
@ Spec      : v2.05 listing 0x0801DBF0..0x0801DFF7
@ -----------------------------------------------------------------------------
FUNC log_write_row
    push    {r3, r4, r5, lr}                @ 0801DBF0 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 0801DBF2 r4 = r0
    movs    r5, #0                          @ 0801DBF4 r5 = 0
    @ "No.," + row number (log_write_label)
    ldr.w   r0, =log_row_no                 @ 0801DBF6 r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801DBFA r0 = u32 [log_row_no]
    bl      log_write_label                 @ 0801DBFC call log_write_label
    cmp     r0, #0                          @ 0801DC00 compare r0 with 0
    beq     .Llog_write_row_DC08            @ 0801DC02 if (r0 == 0) goto 0x801DC08
    movs    r0, #1                          @ 0801DC04 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DC06 goto 0x801DFF6
    @ load the slot into the log_view_* variables
.Llog_write_row_DC08:                   @ v2.05 0x0801DC08, reached from 0x0801DC02
    movs    r0, r4                          @ 0801DC08 r0 = r4
    uxth    r0, r0                          @ 0801DC0A r0 = u16(r0)
    bl      log_slot_load                   @ 0801DC0C call log_slot_load
    @ date (token 0x6E) and time (token 0x6F) of the record
    movs    r2, #0                          @ 0801DC10 r2 = 0
    movs    r1, #0                          @ 0801DC12 r1 = 0
    movs    r0, #0x6e                       @ 0801DC14 r0 = 0x6e
    bl      log_write_csv_token             @ 0801DC16 call log_write_csv_token
    cmp     r0, #0                          @ 0801DC1A compare r0 with 0
    beq     .Llog_write_row_DC22            @ 0801DC1C if (r0 == 0) goto 0x801DC22
    movs    r0, #1                          @ 0801DC1E r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DC20 goto 0x801DFF6
.Llog_write_row_DC22:                   @ v2.05 0x0801DC22, reached from 0x0801DC1C
    movs    r2, #0                          @ 0801DC22 r2 = 0
    movs    r1, #0                          @ 0801DC24 r1 = 0
    movs    r0, #0x6f                       @ 0801DC26 r0 = 0x6f
    bl      log_write_csv_token             @ 0801DC28 call log_write_csv_token
    cmp     r0, #0                          @ 0801DC2C compare r0 with 0
    beq     .Llog_write_row_DC34            @ 0801DC2E if (r0 == 0) goto 0x801DC34
    movs    r0, #1                          @ 0801DC30 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DC32 goto 0x801DFF6
    @ function name of the main reading
.Llog_write_row_DC34:                   @ v2.05 0x0801DC34, reached from 0x0801DC2E
    ldr.w   r0, =log_view_mode1             @ 0801DC34 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DC38 r0 = u8 [log_view_mode1]
    bl      log_write_func_name             @ 0801DC3A call log_write_func_name
    cmp     r0, #0                          @ 0801DC3E compare r0 with 0
    beq     .Llog_write_row_DC46            @ 0801DC40 if (r0 == 0) goto 0x801DC46
    movs    r0, #1                          @ 0801DC42 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DC44 goto 0x801DFF6
.Llog_write_row_DC46:                   @ v2.05 0x0801DC46, reached from 0x0801DC40
    ldr.w   r0, =log_view_flags1            @ 0801DC46 r0 = &log_view_flags1
    @ main value: flags bit 7 = overflow (token 2 "-Overflow" when bit 6 else token 3 "Overflow"); otherwise an
    ldrb    r0, [r0]                        @ 0801DC4A r0 = u8 [log_view_flags1]
    lsls    r0, r0, #0x18                   @ 0801DC4C r0 = r0 << 0x18
    bpl     .Llog_write_row_DC7E            @ 0801DC4E if (r0 >=0 0) goto 0x801DC7E
    ldr.w   r0, =log_view_flags1            @ 0801DC50 r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DC54 r0 = u8 [log_view_flags1]
    lsls    r0, r0, #0x19                   @ 0801DC56 r0 = r0 << 0x19
    bpl     .Llog_write_row_DC6C            @ 0801DC58 if (r0 >=0 0) goto 0x801DC6C
    movs    r2, #0                          @ 0801DC5A r2 = 0
    movs    r1, #0                          @ 0801DC5C r1 = 0
    movs    r0, #2                          @ 0801DC5E r0 = 2
    bl      log_write_csv_token             @ 0801DC60 call log_write_csv_token
    cmp     r0, #0                          @ 0801DC64 compare r0 with 0
    beq     .Llog_write_row_DCB8            @ 0801DC66 if (r0 == 0) goto 0x801DCB8
    movs    r0, #1                          @ 0801DC68 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DC6A goto 0x801DFF6
.Llog_write_row_DC6C:                   @ v2.05 0x0801DC6C, reached from 0x0801DC58
    movs    r2, #0                          @ 0801DC6C r2 = 0
    movs    r1, #0                          @ 0801DC6E r1 = 0
    movs    r0, #3                          @ 0801DC70 r0 = 3
    bl      log_write_csv_token             @ 0801DC72 call log_write_csv_token
    cmp     r0, #0                          @ 0801DC76 compare r0 with 0
    beq     .Llog_write_row_DCB8            @ 0801DC78 if (r0 == 0) goto 0x801DCB8
    movs    r0, #1                          @ 0801DC7A r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DC7C goto 0x801DFF6
.Llog_write_row_DC7E:                   @ v2.05 0x0801DC7E, reached from 0x0801DC4E
    ldr.w   r0, =log_view_flags1            @ 0801DC7E r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DC82 r0 = u8 [log_view_flags1]
    lsls    r0, r0, #0x19                   @ 0801DC84 r0 = r0 << 0x19
    bpl     .Llog_write_row_DC9A            @ 0801DC86 if (r0 >=0 0) goto 0x801DC9A
    movs    r2, #0                          @ 0801DC88 r2 = 0
    movs    r1, #0                          @ 0801DC8A r1 = 0
    movs    r0, #4                          @ 0801DC8C r0 = 4
    bl      log_write_csv_token             @ 0801DC8E call log_write_csv_token
    cmp     r0, #0                          @ 0801DC92 compare r0 with 0
    beq     .Llog_write_row_DC9A            @ 0801DC94 if (r0 == 0) goto 0x801DC9A
    movs    r0, #1                          @ 0801DC96 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DC98 goto 0x801DFF6
.Llog_write_row_DC9A:                   @ v2.05 0x0801DC9A, reached from 0x0801DC86, 0x0801DC94
    ldr.w   r0, =log_view_value1            @ 0801DC9A r0 = &log_view_value1
    ldr     r2, [r0]                        @ 0801DC9E r2 = u32 [log_view_value1]
    ldr.w   r0, =log_view_range1            @ 0801DCA0 r0 = &log_view_range1
    ldrb    r1, [r0]                        @ 0801DCA4 r1 = u8 [log_view_range1]
    ldr.w   r0, =log_view_mode1             @ 0801DCA6 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DCAA r0 = u8 [log_view_mode1]
    bl      log_write_value                 @ 0801DCAC call log_write_value
    cmp     r0, #0                          @ 0801DCB0 compare r0 with 0
    beq     .Llog_write_row_DCB8            @ 0801DCB2 if (r0 == 0) goto 0x801DCB8
    movs    r0, #1                          @ 0801DCB4 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DCB6 goto 0x801DFF6
    @ "," and the unit of the main reading
.Llog_write_row_DCB8:                   @ v2.05 0x0801DCB8, reached from 0x0801DC66, 0x0801DC78, 0x0801DCB2
    movs    r2, #0                          @ 0801DCB8 r2 = 0
    movs    r1, #0                          @ 0801DCBA r1 = 0
    movs    r0, #0                          @ 0801DCBC r0 = 0
    bl      log_write_csv_token             @ 0801DCBE call log_write_csv_token
    cmp     r0, #0                          @ 0801DCC2 compare r0 with 0
    beq     .Llog_write_row_DCCA            @ 0801DCC4 if (r0 == 0) goto 0x801DCCA
    movs    r0, #1                          @ 0801DCC6 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DCC8 goto 0x801DFF6
.Llog_write_row_DCCA:                   @ v2.05 0x0801DCCA, reached from 0x0801DCC4
    ldr.w   r0, =log_view_range1            @ 0801DCCA r0 = &log_view_range1
    ldrb    r1, [r0]                        @ 0801DCCE r1 = u8 [log_view_range1]
    ldr.w   r0, =log_view_mode1             @ 0801DCD0 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DCD4 r0 = u8 [log_view_mode1]
    bl      log_write_unit                  @ 0801DCD6 call log_write_unit
    cmp     r0, #0                          @ 0801DCDA compare r0 with 0
    beq     .Llog_write_row_DCE2            @ 0801DCDC if (r0 == 0) goto 0x801DCE2
    movs    r0, #1                          @ 0801DCDE r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DCE0 goto 0x801DFF6
.Llog_write_row_DCE2:                   @ v2.05 0x0801DCE2, reached from 0x0801DCDC
    ldr.w   r0, =log_view_mode1             @ 0801DCE2 r0 = &log_view_mode1
    @ modes 16, 18, 20, 2 (without AC+DC), 4, 13, 14, 15, 22, 23, 24 carry a second reading
    ldrb    r0, [r0]                        @ 0801DCE6 r0 = u8 [log_view_mode1]
    cmp     r0, #0x10                       @ 0801DCE8 compare r0 with 0x10
    beq     .Llog_write_row_DD5C            @ 0801DCEA if (r0 == 0x10) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DCEC r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DCF0 r0 = u8 [log_view_mode1]
    cmp     r0, #0x12                       @ 0801DCF2 compare r0 with 0x12
    beq     .Llog_write_row_DD5C            @ 0801DCF4 if (r0 == 0x12) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DCF6 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DCFA r0 = u8 [log_view_mode1]
    cmp     r0, #0x14                       @ 0801DCFC compare r0 with 0x14
    beq     .Llog_write_row_DD5C            @ 0801DCFE if (r0 == 0x14) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DD00 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DD04 r0 = u8 [log_view_mode1]
    cmp     r0, #2                          @ 0801DD06 compare r0 with 2
    bne     .Llog_write_row_DD14            @ 0801DD08 if (r0 != 2) goto 0x801DD14
    ldr.w   r0, =log_view_flag4             @ 0801DD0A r0 = &log_view_flag4
    ldrb    r0, [r0]                        @ 0801DD0E r0 = u8 [log_view_flag4]
    cmp     r0, #0                          @ 0801DD10 compare r0 with 0
    beq     .Llog_write_row_DD5C            @ 0801DD12 if (r0 == 0) goto 0x801DD5C
.Llog_write_row_DD14:                   @ v2.05 0x0801DD14, reached from 0x0801DD08
    ldr.w   r0, =log_view_mode1             @ 0801DD14 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DD18 r0 = u8 [log_view_mode1]
    cmp     r0, #4                          @ 0801DD1A compare r0 with 4
    beq     .Llog_write_row_DD5C            @ 0801DD1C if (r0 == 4) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DD1E r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DD22 r0 = u8 [log_view_mode1]
    cmp     r0, #0xd                        @ 0801DD24 compare r0 with 0xd
    beq     .Llog_write_row_DD5C            @ 0801DD26 if (r0 == 0xd) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DD28 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DD2C r0 = u8 [log_view_mode1]
    cmp     r0, #0xe                        @ 0801DD2E compare r0 with 0xe
    beq     .Llog_write_row_DD5C            @ 0801DD30 if (r0 == 0xe) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DD32 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DD36 r0 = u8 [log_view_mode1]
    cmp     r0, #0xf                        @ 0801DD38 compare r0 with 0xf
    beq     .Llog_write_row_DD5C            @ 0801DD3A if (r0 == 0xf) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DD3C r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DD40 r0 = u8 [log_view_mode1]
    cmp     r0, #0x16                       @ 0801DD42 compare r0 with 0x16
    beq     .Llog_write_row_DD5C            @ 0801DD44 if (r0 == 0x16) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DD46 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DD4A r0 = u8 [log_view_mode1]
    cmp     r0, #0x17                       @ 0801DD4C compare r0 with 0x17
    beq     .Llog_write_row_DD5C            @ 0801DD4E if (r0 == 0x17) goto 0x801DD5C
    ldr.w   r0, =log_view_mode1             @ 0801DD50 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DD54 r0 = u8 [log_view_mode1]
    cmp     r0, #0x18                       @ 0801DD56 compare r0 with 0x18
    bne.w   .Llog_write_row_DF0E            @ 0801DD58 if (r0 != 0x18) goto 0x801DF0E
    @ second reading: function name, value (negative: "-" and the magnitude; overflow: "Overflow"), ",", unit
.Llog_write_row_DD5C:                   @ v2.05 0x0801DD5C, reached from 0x0801DCEA, 0x0801DCF4, 0x0801DCFE, 0x0801DD12, 0x0801DD1C, 0x0801DD26, 0x0801DD30, 0x0801DD3A, 0x0801DD44, 0x0801DD4E
    ldr.w   r0, =log_view_mode2             @ 0801DD5C r0 = &log_view_mode2
    ldrb    r0, [r0]                        @ 0801DD60 r0 = u8 [log_view_mode2]
    bl      log_write_func_name             @ 0801DD62 call log_write_func_name
    cmp     r0, #0                          @ 0801DD66 compare r0 with 0
    beq     .Llog_write_row_DD6E            @ 0801DD68 if (r0 == 0) goto 0x801DD6E
    movs    r0, #1                          @ 0801DD6A r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DD6C goto 0x801DFF6
.Llog_write_row_DD6E:                   @ v2.05 0x0801DD6E, reached from 0x0801DD68
    ldr.w   r0, =log_view_flags2            @ 0801DD6E r0 = &log_view_flags2
    ldrb    r0, [r0]                        @ 0801DD72 r0 = u8 [log_view_flags2]
    lsls    r0, r0, #0x18                   @ 0801DD74 r0 = r0 << 0x18
    bpl     .Llog_write_row_DD8A            @ 0801DD76 if (r0 >=0 0) goto 0x801DD8A
    movs    r2, #0                          @ 0801DD78 r2 = 0
    movs    r1, #0                          @ 0801DD7A r1 = 0
    movs    r0, #3                          @ 0801DD7C r0 = 3
    bl      log_write_csv_token             @ 0801DD7E call log_write_csv_token
    cmp     r0, #0                          @ 0801DD82 compare r0 with 0
    beq     .Llog_write_row_DDD2            @ 0801DD84 if (r0 == 0) goto 0x801DDD2
    movs    r0, #1                          @ 0801DD86 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DD88 goto 0x801DFF6
.Llog_write_row_DD8A:                   @ v2.05 0x0801DD8A, reached from 0x0801DD76
    ldr.w   r0, =log_view_value2            @ 0801DD8A r0 = &log_view_value2
    ldr     r0, [r0]                        @ 0801DD8E r0 = u32 [log_view_value2]
    cmp     r0, #0                          @ 0801DD90 compare r0 with 0
    bpl     .Llog_write_row_DDB4            @ 0801DD92 if (r0 >=0 0) goto 0x801DDB4
    movs    r2, #0                          @ 0801DD94 r2 = 0
    movs    r1, #0                          @ 0801DD96 r1 = 0
    movs    r0, #4                          @ 0801DD98 r0 = 4
    bl      log_write_csv_token             @ 0801DD9A call log_write_csv_token
    cmp     r0, #0                          @ 0801DD9E compare r0 with 0
    beq     .Llog_write_row_DDA6            @ 0801DDA0 if (r0 == 0) goto 0x801DDA6
    movs    r0, #1                          @ 0801DDA2 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DDA4 goto 0x801DFF6
.Llog_write_row_DDA6:                   @ v2.05 0x0801DDA6, reached from 0x0801DDA0
    ldr.w   r0, =log_view_value2            @ 0801DDA6 r0 = &log_view_value2
    ldr     r0, [r0]                        @ 0801DDAA r0 = u32 [log_view_value2]
    rsbs    r0, r0, #0                      @ 0801DDAC r0 = 0 - r0
    ldr.w   r1, =log_view_value2            @ 0801DDAE r1 = &log_view_value2
    str     r0, [r1]                        @ 0801DDB2 u32 [log_view_value2] = r0
.Llog_write_row_DDB4:                   @ v2.05 0x0801DDB4, reached from 0x0801DD92
    ldr.w   r0, =log_view_value2            @ 0801DDB4 r0 = &log_view_value2
    ldr     r2, [r0]                        @ 0801DDB8 r2 = u32 [log_view_value2]
    ldr.w   r0, =log_view_range2            @ 0801DDBA r0 = &log_view_range2
    ldrb    r1, [r0]                        @ 0801DDBE r1 = u8 [log_view_range2]
    ldr.w   r0, =log_view_mode2             @ 0801DDC0 r0 = &log_view_mode2
    ldrb    r0, [r0]                        @ 0801DDC4 r0 = u8 [log_view_mode2]
    bl      log_write_value                 @ 0801DDC6 call log_write_value
    cmp     r0, #0                          @ 0801DDCA compare r0 with 0
    beq     .Llog_write_row_DDD2            @ 0801DDCC if (r0 == 0) goto 0x801DDD2
    movs    r0, #1                          @ 0801DDCE r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DDD0 goto 0x801DFF6
.Llog_write_row_DDD2:                   @ v2.05 0x0801DDD2, reached from 0x0801DD84, 0x0801DDCC
    movs    r2, #0                          @ 0801DDD2 r2 = 0
    movs    r1, #0                          @ 0801DDD4 r1 = 0
    movs    r0, #0                          @ 0801DDD6 r0 = 0
    bl      log_write_csv_token             @ 0801DDD8 call log_write_csv_token
    cmp     r0, #0                          @ 0801DDDC compare r0 with 0
    beq     .Llog_write_row_DDE4            @ 0801DDDE if (r0 == 0) goto 0x801DDE4
    movs    r0, #1                          @ 0801DDE0 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DDE2 goto 0x801DFF6
.Llog_write_row_DDE4:                   @ v2.05 0x0801DDE4, reached from 0x0801DDDE
    ldr.w   r0, =log_view_range2            @ 0801DDE4 r0 = &log_view_range2
    ldrb    r1, [r0]                        @ 0801DDE8 r1 = u8 [log_view_range2]
    ldr.w   r0, =log_view_mode2             @ 0801DDEA r0 = &log_view_mode2
    ldrb    r0, [r0]                        @ 0801DDEE r0 = u8 [log_view_mode2]
    bl      log_write_unit                  @ 0801DDF0 call log_write_unit
    cmp     r0, #0                          @ 0801DDF4 compare r0 with 0
    beq     .Llog_write_row_DDFC            @ 0801DDF6 if (r0 == 0) goto 0x801DDFC
    movs    r0, #1                          @ 0801DDF8 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DDFA goto 0x801DFF6
.Llog_write_row_DDFC:                   @ v2.05 0x0801DDFC, reached from 0x0801DDF6
    ldr.w   r0, =log_view_mode1             @ 0801DDFC r0 = &log_view_mode1
    @ modes 13, 14, 15, 22, 23, 24 carry a third reading as well
    ldrb    r0, [r0]                        @ 0801DE00 r0 = u8 [log_view_mode1]
    cmp     r0, #0xd                        @ 0801DE02 compare r0 with 0xd
    beq     .Llog_write_row_DE38            @ 0801DE04 if (r0 == 0xd) goto 0x801DE38
    ldr.w   r0, =log_view_mode1             @ 0801DE06 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DE0A r0 = u8 [log_view_mode1]
    cmp     r0, #0xe                        @ 0801DE0C compare r0 with 0xe
    beq     .Llog_write_row_DE38            @ 0801DE0E if (r0 == 0xe) goto 0x801DE38
    ldr.w   r0, =log_view_mode1             @ 0801DE10 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DE14 r0 = u8 [log_view_mode1]
    cmp     r0, #0xf                        @ 0801DE16 compare r0 with 0xf
    beq     .Llog_write_row_DE38            @ 0801DE18 if (r0 == 0xf) goto 0x801DE38
    ldr.w   r0, =log_view_mode1             @ 0801DE1A r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DE1E r0 = u8 [log_view_mode1]
    cmp     r0, #0x16                       @ 0801DE20 compare r0 with 0x16
    beq     .Llog_write_row_DE38            @ 0801DE22 if (r0 == 0x16) goto 0x801DE38
    ldr.w   r0, =log_view_mode1             @ 0801DE24 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DE28 r0 = u8 [log_view_mode1]
    cmp     r0, #0x17                       @ 0801DE2A compare r0 with 0x17
    beq     .Llog_write_row_DE38            @ 0801DE2C if (r0 == 0x17) goto 0x801DE38
    ldr.w   r0, =log_view_mode1             @ 0801DE2E r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801DE32 r0 = u8 [log_view_mode1]
    cmp     r0, #0x18                       @ 0801DE34 compare r0 with 0x18
    bne     .Llog_write_row_DED8            @ 0801DE36 if (r0 != 0x18) goto 0x801DED8
    @ third reading: same layout as the second one
.Llog_write_row_DE38:                   @ v2.05 0x0801DE38, reached from 0x0801DE04, 0x0801DE0E, 0x0801DE18, 0x0801DE22, 0x0801DE2C
    ldr.w   r0, =log_view_mode3             @ 0801DE38 r0 = &log_view_mode3
    ldrb    r0, [r0]                        @ 0801DE3C r0 = u8 [log_view_mode3]
    bl      log_write_func_name             @ 0801DE3E call log_write_func_name
    cmp     r0, #0                          @ 0801DE42 compare r0 with 0
    beq     .Llog_write_row_DE4A            @ 0801DE44 if (r0 == 0) goto 0x801DE4A
    movs    r0, #1                          @ 0801DE46 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DE48 goto 0x801DFF6
.Llog_write_row_DE4A:                   @ v2.05 0x0801DE4A, reached from 0x0801DE44
    ldr.w   r0, =log_view_flags3            @ 0801DE4A r0 = &log_view_flags3
    ldrb    r0, [r0]                        @ 0801DE4E r0 = u8 [log_view_flags3]
    lsls    r0, r0, #0x18                   @ 0801DE50 r0 = r0 << 0x18
    bpl     .Llog_write_row_DE66            @ 0801DE52 if (r0 >=0 0) goto 0x801DE66
    movs    r2, #0                          @ 0801DE54 r2 = 0
    movs    r1, #0                          @ 0801DE56 r1 = 0
    movs    r0, #3                          @ 0801DE58 r0 = 3
    bl      log_write_csv_token             @ 0801DE5A call log_write_csv_token
    cmp     r0, #0                          @ 0801DE5E compare r0 with 0
    beq     .Llog_write_row_DEAE            @ 0801DE60 if (r0 == 0) goto 0x801DEAE
    movs    r0, #1                          @ 0801DE62 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DE64 goto 0x801DFF6
.Llog_write_row_DE66:                   @ v2.05 0x0801DE66, reached from 0x0801DE52
    ldr.w   r0, =log_view_value3            @ 0801DE66 r0 = &log_view_value3
    ldr     r0, [r0]                        @ 0801DE6A r0 = u32 [log_view_value3]
    cmp     r0, #0                          @ 0801DE6C compare r0 with 0
    bpl     .Llog_write_row_DE90            @ 0801DE6E if (r0 >=0 0) goto 0x801DE90
    movs    r2, #0                          @ 0801DE70 r2 = 0
    movs    r1, #0                          @ 0801DE72 r1 = 0
    movs    r0, #4                          @ 0801DE74 r0 = 4
    bl      log_write_csv_token             @ 0801DE76 call log_write_csv_token
    cmp     r0, #0                          @ 0801DE7A compare r0 with 0
    beq     .Llog_write_row_DE82            @ 0801DE7C if (r0 == 0) goto 0x801DE82
    movs    r0, #1                          @ 0801DE7E r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DE80 goto 0x801DFF6
.Llog_write_row_DE82:                   @ v2.05 0x0801DE82, reached from 0x0801DE7C
    ldr.w   r0, =log_view_value3            @ 0801DE82 r0 = &log_view_value3
    ldr     r0, [r0]                        @ 0801DE86 r0 = u32 [log_view_value3]
    rsbs    r0, r0, #0                      @ 0801DE88 r0 = 0 - r0
    ldr.w   r1, =log_view_value3            @ 0801DE8A r1 = &log_view_value3
    str     r0, [r1]                        @ 0801DE8E u32 [log_view_value3] = r0
.Llog_write_row_DE90:                   @ v2.05 0x0801DE90, reached from 0x0801DE6E
    ldr.w   r0, =log_view_value3            @ 0801DE90 r0 = &log_view_value3
    ldr     r2, [r0]                        @ 0801DE94 r2 = u32 [log_view_value3]
    ldr.w   r0, =log_view_range3            @ 0801DE96 r0 = &log_view_range3
    ldrb    r1, [r0]                        @ 0801DE9A r1 = u8 [log_view_range3]
    ldr.w   r0, =log_view_mode3             @ 0801DE9C r0 = &log_view_mode3
    ldrb    r0, [r0]                        @ 0801DEA0 r0 = u8 [log_view_mode3]
    bl      log_write_value                 @ 0801DEA2 call log_write_value
    cmp     r0, #0                          @ 0801DEA6 compare r0 with 0
    beq     .Llog_write_row_DEAE            @ 0801DEA8 if (r0 == 0) goto 0x801DEAE
    movs    r0, #1                          @ 0801DEAA r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DEAC goto 0x801DFF6
.Llog_write_row_DEAE:                   @ v2.05 0x0801DEAE, reached from 0x0801DE60, 0x0801DEA8
    movs    r2, #0                          @ 0801DEAE r2 = 0
    movs    r1, #0                          @ 0801DEB0 r1 = 0
    movs    r0, #0                          @ 0801DEB2 r0 = 0
    bl      log_write_csv_token             @ 0801DEB4 call log_write_csv_token
    cmp     r0, #0                          @ 0801DEB8 compare r0 with 0
    beq     .Llog_write_row_DEC0            @ 0801DEBA if (r0 == 0) goto 0x801DEC0
    movs    r0, #1                          @ 0801DEBC r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DEBE goto 0x801DFF6
.Llog_write_row_DEC0:                   @ v2.05 0x0801DEC0, reached from 0x0801DEBA
    ldr.w   r0, =log_view_range3            @ 0801DEC0 r0 = &log_view_range3
    ldrb    r1, [r0]                        @ 0801DEC4 r1 = u8 [log_view_range3]
    ldr.w   r0, =log_view_mode3             @ 0801DEC6 r0 = &log_view_mode3
    ldrb    r0, [r0]                        @ 0801DECA r0 = u8 [log_view_mode3]
    bl      log_write_unit                  @ 0801DECC call log_write_unit
    cmp     r0, #0                          @ 0801DED0 compare r0 with 0
    beq     .Llog_write_row_DF7A            @ 0801DED2 if (r0 == 0) goto 0x801DF7A
    movs    r0, #1                          @ 0801DED4 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DED6 goto 0x801DFF6
    @ modes with only a second reading: three empty fields for the third one
.Llog_write_row_DED8:                   @ v2.05 0x0801DED8, reached from 0x0801DE36
    movs    r2, #0                          @ 0801DED8 r2 = 0
    movs    r1, #0                          @ 0801DEDA r1 = 0
    movs    r0, #0                          @ 0801DEDC r0 = 0
    bl      log_write_csv_token             @ 0801DEDE call log_write_csv_token
    cmp     r0, #0                          @ 0801DEE2 compare r0 with 0
    beq     .Llog_write_row_DEEA            @ 0801DEE4 if (r0 == 0) goto 0x801DEEA
    movs    r0, #1                          @ 0801DEE6 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DEE8 goto 0x801DFF6
.Llog_write_row_DEEA:                   @ v2.05 0x0801DEEA, reached from 0x0801DEE4
    movs    r2, #0                          @ 0801DEEA r2 = 0
    movs    r1, #0                          @ 0801DEEC r1 = 0
    movs    r0, #0                          @ 0801DEEE r0 = 0
    bl      log_write_csv_token             @ 0801DEF0 call log_write_csv_token
    cmp     r0, #0                          @ 0801DEF4 compare r0 with 0
    beq     .Llog_write_row_DEFC            @ 0801DEF6 if (r0 == 0) goto 0x801DEFC
    movs    r0, #1                          @ 0801DEF8 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DEFA goto 0x801DFF6
.Llog_write_row_DEFC:                   @ v2.05 0x0801DEFC, reached from 0x0801DEF6
    movs    r2, #0                          @ 0801DEFC r2 = 0
    movs    r1, #0                          @ 0801DEFE r1 = 0
    movs    r0, #0                          @ 0801DF00 r0 = 0
    bl      log_write_csv_token             @ 0801DF02 call log_write_csv_token
    cmp     r0, #0                          @ 0801DF06 compare r0 with 0
    beq     .Llog_write_row_DF7A            @ 0801DF08 if (r0 == 0) goto 0x801DF7A
    movs    r0, #1                          @ 0801DF0A r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DF0C goto 0x801DFF6
    @ modes without a second reading: six empty fields
.Llog_write_row_DF0E:                   @ v2.05 0x0801DF0E, reached from 0x0801DD58
    movs    r2, #0                          @ 0801DF0E r2 = 0
    movs    r1, #0                          @ 0801DF10 r1 = 0
    movs    r0, #0                          @ 0801DF12 r0 = 0
    bl      log_write_csv_token             @ 0801DF14 call log_write_csv_token
    cmp     r0, #0                          @ 0801DF18 compare r0 with 0
    beq     .Llog_write_row_DF20            @ 0801DF1A if (r0 == 0) goto 0x801DF20
    movs    r0, #1                          @ 0801DF1C r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DF1E goto 0x801DFF6
.Llog_write_row_DF20:                   @ v2.05 0x0801DF20, reached from 0x0801DF1A
    movs    r2, #0                          @ 0801DF20 r2 = 0
    movs    r1, #0                          @ 0801DF22 r1 = 0
    movs    r0, #0                          @ 0801DF24 r0 = 0
    bl      log_write_csv_token             @ 0801DF26 call log_write_csv_token
    cmp     r0, #0                          @ 0801DF2A compare r0 with 0
    beq     .Llog_write_row_DF32            @ 0801DF2C if (r0 == 0) goto 0x801DF32
    movs    r0, #1                          @ 0801DF2E r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DF30 goto 0x801DFF6
.Llog_write_row_DF32:                   @ v2.05 0x0801DF32, reached from 0x0801DF2C
    movs    r2, #0                          @ 0801DF32 r2 = 0
    movs    r1, #0                          @ 0801DF34 r1 = 0
    movs    r0, #0                          @ 0801DF36 r0 = 0
    bl      log_write_csv_token             @ 0801DF38 call log_write_csv_token
    cmp     r0, #0                          @ 0801DF3C compare r0 with 0
    beq     .Llog_write_row_DF44            @ 0801DF3E if (r0 == 0) goto 0x801DF44
    movs    r0, #1                          @ 0801DF40 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DF42 goto 0x801DFF6
.Llog_write_row_DF44:                   @ v2.05 0x0801DF44, reached from 0x0801DF3E
    movs    r2, #0                          @ 0801DF44 r2 = 0
    movs    r1, #0                          @ 0801DF46 r1 = 0
    movs    r0, #0                          @ 0801DF48 r0 = 0
    bl      log_write_csv_token             @ 0801DF4A call log_write_csv_token
    cmp     r0, #0                          @ 0801DF4E compare r0 with 0
    beq     .Llog_write_row_DF56            @ 0801DF50 if (r0 == 0) goto 0x801DF56
    movs    r0, #1                          @ 0801DF52 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DF54 goto 0x801DFF6
.Llog_write_row_DF56:                   @ v2.05 0x0801DF56, reached from 0x0801DF50
    movs    r2, #0                          @ 0801DF56 r2 = 0
    movs    r1, #0                          @ 0801DF58 r1 = 0
    movs    r0, #0                          @ 0801DF5A r0 = 0
    bl      log_write_csv_token             @ 0801DF5C call log_write_csv_token
    cmp     r0, #0                          @ 0801DF60 compare r0 with 0
    beq     .Llog_write_row_DF68            @ 0801DF62 if (r0 == 0) goto 0x801DF68
    movs    r0, #1                          @ 0801DF64 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DF66 goto 0x801DFF6
.Llog_write_row_DF68:                   @ v2.05 0x0801DF68, reached from 0x0801DF62
    movs    r2, #0                          @ 0801DF68 r2 = 0
    movs    r1, #0                          @ 0801DF6A r1 = 0
    movs    r0, #0                          @ 0801DF6C r0 = 0
    bl      log_write_csv_token             @ 0801DF6E call log_write_csv_token
    cmp     r0, #0                          @ 0801DF72 compare r0 with 0
    beq     .Llog_write_row_DF7A            @ 0801DF74 if (r0 == 0) goto 0x801DF7A
    movs    r0, #1                          @ 0801DF76 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DF78 goto 0x801DFF6
    @ remark: PeakHold (flag 3), else 1KHz (flag 2), else ACDC (flag 4)
.Llog_write_row_DF7A:                   @ v2.05 0x0801DF7A, reached from 0x0801DED2, 0x0801DF08, 0x0801DF74
    ldr.w   r0, =log_view_flag3             @ 0801DF7A r0 = &log_view_flag3
    ldrb    r0, [r0]                        @ 0801DF7E r0 = u8 [log_view_flag3]
    cmp     r0, #0                          @ 0801DF80 compare r0 with 0
    beq     .Llog_write_row_DF96            @ 0801DF82 if (r0 == 0) goto 0x801DF96
    movs    r2, #0                          @ 0801DF84 r2 = 0
    movs    r1, #0                          @ 0801DF86 r1 = 0
    movs    r0, #0x51                       @ 0801DF88 r0 = 0x51
    bl      log_write_csv_token             @ 0801DF8A call log_write_csv_token
    cmp     r0, #0                          @ 0801DF8E compare r0 with 0
    beq     .Llog_write_row_DFCE            @ 0801DF90 if (r0 == 0) goto 0x801DFCE
    movs    r0, #1                          @ 0801DF92 r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DF94 goto 0x801DFF6
.Llog_write_row_DF96:                   @ v2.05 0x0801DF96, reached from 0x0801DF82
    ldr.w   r0, =log_view_flag2             @ 0801DF96 r0 = &log_view_flag2
    ldrb    r0, [r0]                        @ 0801DF9A r0 = u8 [log_view_flag2]
    cmp     r0, #0                          @ 0801DF9C compare r0 with 0
    beq     .Llog_write_row_DFB2            @ 0801DF9E if (r0 == 0) goto 0x801DFB2
    movs    r2, #0                          @ 0801DFA0 r2 = 0
    movs    r1, #0                          @ 0801DFA2 r1 = 0
    movs    r0, #0x52                       @ 0801DFA4 r0 = 0x52
    bl      log_write_csv_token             @ 0801DFA6 call log_write_csv_token
    cmp     r0, #0                          @ 0801DFAA compare r0 with 0
    beq     .Llog_write_row_DFCE            @ 0801DFAC if (r0 == 0) goto 0x801DFCE
    movs    r0, #1                          @ 0801DFAE r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DFB0 goto 0x801DFF6
.Llog_write_row_DFB2:                   @ v2.05 0x0801DFB2, reached from 0x0801DF9E
    ldr.w   r0, =log_view_flag4             @ 0801DFB2 r0 = &log_view_flag4
    ldrb    r0, [r0]                        @ 0801DFB6 r0 = u8 [log_view_flag4]
    cmp     r0, #0                          @ 0801DFB8 compare r0 with 0
    beq     .Llog_write_row_DFCE            @ 0801DFBA if (r0 == 0) goto 0x801DFCE
    movs    r2, #0                          @ 0801DFBC r2 = 0
    movs    r1, #0                          @ 0801DFBE r1 = 0
    movs    r0, #0x53                       @ 0801DFC0 r0 = 0x53
    bl      log_write_csv_token             @ 0801DFC2 call log_write_csv_token
    cmp     r0, #0                          @ 0801DFC6 compare r0 with 0
    beq     .Llog_write_row_DFCE            @ 0801DFC8 if (r0 == 0) goto 0x801DFCE
    movs    r0, #1                          @ 0801DFCA r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DFCC goto 0x801DFF6
    @ "," and the line end
.Llog_write_row_DFCE:                   @ v2.05 0x0801DFCE, reached from 0x0801DF90, 0x0801DFAC, 0x0801DFBA, 0x0801DFC8
    movs    r2, #0                          @ 0801DFCE r2 = 0
    movs    r1, #0                          @ 0801DFD0 r1 = 0
    movs    r0, #0                          @ 0801DFD2 r0 = 0
    bl      log_write_csv_token             @ 0801DFD4 call log_write_csv_token
    cmp     r0, #0                          @ 0801DFD8 compare r0 with 0
    beq     .Llog_write_row_DFE0            @ 0801DFDA if (r0 == 0) goto 0x801DFE0
    movs    r0, #1                          @ 0801DFDC r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DFDE goto 0x801DFF6
.Llog_write_row_DFE0:                   @ v2.05 0x0801DFE0, reached from 0x0801DFDA
    movs    r2, #0                          @ 0801DFE0 r2 = 0
    movs    r1, #0                          @ 0801DFE2 r1 = 0
    movs    r0, #1                          @ 0801DFE4 r0 = 1
    bl      log_write_csv_token             @ 0801DFE6 call log_write_csv_token
    cmp     r0, #0                          @ 0801DFEA compare r0 with 0
    beq     .Llog_write_row_DFF2            @ 0801DFEC if (r0 == 0) goto 0x801DFF2
    movs    r0, #1                          @ 0801DFEE r0 = 1
    b       .Llog_write_row_DFF6            @ 0801DFF0 goto 0x801DFF6
.Llog_write_row_DFF2:                   @ v2.05 0x0801DFF2, reached from 0x0801DFEC
    movs    r0, r5                          @ 0801DFF2 r0 = r5
    uxtb    r0, r0                          @ 0801DFF4 r0 = u8(r0)
.Llog_write_row_DFF6:                   @ v2.05 0x0801DFF6, reached from 0x0801DC06, 0x0801DC20, 0x0801DC32, 0x0801DC44, 0x0801DC6A, 0x0801DC7C, 0x0801DC98, 0x0801DCB6, 0x0801DCC8, 0x0801DCE0, 0x0801DD6C, 0x0801DD88, 0x0801DDA4, 0x0801DDD0, 0x0801DDE2, 0x0801DDFA, 0x0801DE48, 0x0801DE64, 0x0801DE80, 0x0801DEAC, 0x0801DEBE, 0x0801DED6, 0x0801DEE8, 0x0801DEFA, 0x0801DF0C, 0x0801DF1E, 0x0801DF30, 0x0801DF42, 0x0801DF54, 0x0801DF66, 0x0801DF78, 0x0801DF94, 0x0801DFB0, 0x0801DFCC, 0x0801DFDE, 0x0801DFF0
    pop     {r1, r4, r5, pc}                @ 0801DFF6 pop {r1, r4, r5, pc}
ENDFUNC log_write_row
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_label - write "number," (token 0x64 with the value, then ",")
@ Replaces  : 0x0801E018 FUN_0801E018 (v2.05), called by log_write_row and log_write_minmax_rows
@ In        : r0 = number (u32)
@ Out       : r0 = 0 ok, 1 write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E018..0x0801E047
@ -----------------------------------------------------------------------------
FUNC log_write_label
    push    {r3, r4, r5, lr}                @ 0801E018 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 0801E01A r4 = r0
    movs    r5, #0                          @ 0801E01C r5 = 0
    movs    r2, #0                          @ 0801E01E r2 = 0
    movs    r1, r4                          @ 0801E020 r1 = r4
    movs    r0, #0x64                       @ 0801E022 r0 = 0x64
    bl      log_write_csv_token             @ 0801E024 call log_write_csv_token
    cmp     r0, #0                          @ 0801E028 compare r0 with 0
    beq     .Llog_write_label_E030          @ 0801E02A if (r0 == 0) goto 0x801E030
    movs    r0, #1                          @ 0801E02C r0 = 1
    b       .Llog_write_label_E046          @ 0801E02E goto 0x801E046
.Llog_write_label_E030:                 @ v2.05 0x0801E030, reached from 0x0801E02A
    movs    r2, #0                          @ 0801E030 r2 = 0
    movs    r1, #0                          @ 0801E032 r1 = 0
    movs    r0, #0                          @ 0801E034 r0 = 0
    bl      log_write_csv_token             @ 0801E036 call log_write_csv_token
    cmp     r0, #0                          @ 0801E03A compare r0 with 0
    beq     .Llog_write_label_E042          @ 0801E03C if (r0 == 0) goto 0x801E042
    movs    r0, #1                          @ 0801E03E r0 = 1
    b       .Llog_write_label_E046          @ 0801E040 goto 0x801E046
.Llog_write_label_E042:                 @ v2.05 0x0801E042, reached from 0x0801E03C
    movs    r0, r5                          @ 0801E042 r0 = r5
    uxtb    r0, r0                          @ 0801E044 r0 = u8(r0)
.Llog_write_label_E046:                 @ v2.05 0x0801E046, reached from 0x0801E02E, 0x0801E040
    pop     {r1, r4, r5, pc}                @ 0801E046 pop {r1, r4, r5, pc}
ENDFUNC log_write_label
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_func_name - write the function name of mode r0 followed by ","
@ Replaces  : 0x0801E048 FUN_0801E048 (v2.05), called by log_write_row and log_write_minmax_rows
@ In        : r0 = mode (u8); a mode above 25 is written as mode 2
@ Out       : r0 = 0 ok, 1 write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E048..0x0801E075 (token = mode + 0x15)
@ -----------------------------------------------------------------------------
FUNC log_write_func_name
    push    {r3, r4, r5, lr}                @ 0801E048 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 0801E04A r4 = r0
    movs    r5, #0                          @ 0801E04C r5 = 0
    uxtb    r4, r4                          @ 0801E04E r4 = u8(r4)
    cmp     r4, #0x1a                       @ 0801E050 compare r4 with 0x1a
    blt     .Llog_write_func_name_E058      @ 0801E052 if (r4 < 0x1a) goto 0x801E058
    movs    r0, #2                          @ 0801E054 r0 = 2
    movs    r4, r0                          @ 0801E056 r4 = r0
.Llog_write_func_name_E058:             @ v2.05 0x0801E058, reached from 0x0801E052
    movs    r2, #0                          @ 0801E058 r2 = 0
    movs    r1, #0                          @ 0801E05A r1 = 0
    uxtb    r4, r4                          @ 0801E05C r4 = u8(r4)
    adds.w  r0, r4, #0x15                   @ 0801E05E r0 = r4 + 0x15
    uxth    r0, r0                          @ 0801E062 r0 = u16(r0)
    bl      log_write_csv_token             @ 0801E064 call log_write_csv_token
    cmp     r0, #0                          @ 0801E068 compare r0 with 0
    beq     .Llog_write_func_name_E070      @ 0801E06A if (r0 == 0) goto 0x801E070
    movs    r0, #1                          @ 0801E06C r0 = 1
    movs    r5, r0                          @ 0801E06E r5 = r0
.Llog_write_func_name_E070:             @ v2.05 0x0801E070, reached from 0x0801E06A
    movs    r0, r5                          @ 0801E070 r0 = r5
    uxtb    r0, r0                          @ 0801E072 r0 = u8(r0)
    pop     {r1, r4, r5, pc}                @ 0801E074 pop {r1, r4, r5, pc}
ENDFUNC log_write_func_name
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_unit - write the unit string of the reading (mode r0, range r1) followed by ","
@ Replaces  : 0x0801E076 FUN_0801E076 (v2.05), called by log_write_row and log_write_minmax_rows
@ In        : r0 = mode (u8), r1 = range (u8)
@ Out       : r0 = 0 ok, 1 write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_view_flag0 (LowZ AC variant) for mode 0 and log_view_flag5 (Celsius) for mode 5
@ Spec      : v2.05 listing 0x0801E076..0x0801E32B
@ Note      : unit tokens: 0x33 "ACV" and 0x34 "DCV" (mode 0, flag 0 set / clear), 0x35 "V", 0x36 "mV", 0x37 "'C", 0x38 "'F",
@             0x39 "Hz", 0x3A "KHz", 0x3B "mSec", 0x3C "%", 0x3D "ohm", 0x3E "Kohm", 0x3F "Mohm", 0x40 "nF", 0x41 "uF", 0x42 "uVA",
@             0x43 "mVA", 0x44 "VA", 0x45 "uA", 0x46 "mA", 0x47 "A".
@             By mode: 0 -> 0x33 or 0x34; 1, 2 and 11 -> V; 3, 4 and 25 -> mV; 5 -> 'C or 'F (flag 5); 6 -> Hz, KHz from range 2;
@             7 -> mSec; 8 -> %; 9 -> ohm (range 0, 1), Kohm (2..4), Mohm (5, 6); 10 -> ohm; 12 -> nF (range 0, 1) or uF;
@             13 -> uVA; 14 -> mVA; 15 -> mVA at range 0, else VA; 16 and 17 -> uA; 18 and 19 -> mA; 20 and 21 -> A; 22 -> uVA;
@             23 -> mVA; 24 -> mVA at range 0, else VA.  Other modes write nothing and report success.
@             The compiled code is a binary search over the mode (0x0801E084..0x0801E0F6), then one block per unit.
@ -----------------------------------------------------------------------------
FUNC log_write_unit
    @ r4 = mode, r5 = range; binary search of the mode
    push    {r4, r5, r6, lr}                @ 0801E076 push {r4, r5, r6, lr}
    movs    r4, r0                          @ 0801E078 r4 = r0
    movs    r5, r1                          @ 0801E07A r5 = r1
    movs    r6, #0                          @ 0801E07C r6 = 0
    uxtb    r4, r4                          @ 0801E07E r4 = u8(r4)
    cmp     r4, #0                          @ 0801E080 compare r4 with 0
    beq     .Llog_write_unit_E0F8           @ 0801E082 if (r4 == 0) goto 0x801E0F8
    cmp     r4, #2                          @ 0801E084 compare r4 with 2
    beq     .Llog_write_unit_E128           @ 0801E086 if (r4 == 2) goto 0x801E128
    blo     .Llog_write_unit_E128           @ 0801E088 if (r4 <u 2) goto 0x801E128
    cmp     r4, #4                          @ 0801E08A compare r4 with 4
    beq     .Llog_write_unit_E13C           @ 0801E08C if (r4 == 4) goto 0x801E13C
    blo     .Llog_write_unit_E13C           @ 0801E08E if (r4 <u 4) goto 0x801E13C
    cmp     r4, #6                          @ 0801E090 compare r4 with 6
    beq     .Llog_write_unit_E180           @ 0801E092 if (r4 == 6) goto 0x801E180
    blo     .Llog_write_unit_E150           @ 0801E094 if (r4 <u 6) goto 0x801E150
    cmp     r4, #8                          @ 0801E096 compare r4 with 8
    beq.w   .Llog_write_unit_E1C0           @ 0801E098 if (r4 == 8) goto 0x801E1C0
    blo.w   .Llog_write_unit_E1AC           @ 0801E09C if (r4 <u 8) goto 0x801E1AC
    cmp     r4, #0xa                        @ 0801E0A0 compare r4 with 0xa
    beq.w   .Llog_write_unit_E218           @ 0801E0A2 if (r4 == 0xa) goto 0x801E218
    blo.w   .Llog_write_unit_E1D4           @ 0801E0A6 if (r4 <u 0xa) goto 0x801E1D4
    cmp     r4, #0xc                        @ 0801E0AA compare r4 with 0xc
    beq.w   .Llog_write_unit_E240           @ 0801E0AC if (r4 == 0xc) goto 0x801E240
    blo.w   .Llog_write_unit_E22C           @ 0801E0B0 if (r4 <u 0xc) goto 0x801E22C
    cmp     r4, #0xe                        @ 0801E0B4 compare r4 with 0xe
    beq.w   .Llog_write_unit_E280           @ 0801E0B6 if (r4 == 0xe) goto 0x801E280
    blo.w   .Llog_write_unit_E26C           @ 0801E0BA if (r4 <u 0xe) goto 0x801E26C
    cmp     r4, #0x10                       @ 0801E0BE compare r4 with 0x10
    beq.w   .Llog_write_unit_E2C0           @ 0801E0C0 if (r4 == 0x10) goto 0x801E2C0
    blo.w   .Llog_write_unit_E294           @ 0801E0C4 if (r4 <u 0x10) goto 0x801E294
    cmp     r4, #0x12                       @ 0801E0C8 compare r4 with 0x12
    beq.w   .Llog_write_unit_E2D4           @ 0801E0CA if (r4 == 0x12) goto 0x801E2D4
    blo.w   .Llog_write_unit_E2C0           @ 0801E0CE if (r4 <u 0x12) goto 0x801E2C0
    cmp     r4, #0x14                       @ 0801E0D2 compare r4 with 0x14
    beq.w   .Llog_write_unit_E2E8           @ 0801E0D4 if (r4 == 0x14) goto 0x801E2E8
    blo.w   .Llog_write_unit_E2D4           @ 0801E0D8 if (r4 <u 0x14) goto 0x801E2D4
    cmp     r4, #0x16                       @ 0801E0DC compare r4 with 0x16
    beq.w   .Llog_write_unit_E26C           @ 0801E0DE if (r4 == 0x16) goto 0x801E26C
    blo.w   .Llog_write_unit_E2E8           @ 0801E0E2 if (r4 <u 0x16) goto 0x801E2E8
    cmp     r4, #0x18                       @ 0801E0E6 compare r4 with 0x18
    beq.w   .Llog_write_unit_E294           @ 0801E0E8 if (r4 == 0x18) goto 0x801E294
    blo.w   .Llog_write_unit_E280           @ 0801E0EC if (r4 <u 0x18) goto 0x801E280
    cmp     r4, #0x19                       @ 0801E0F0 compare r4 with 0x19
    beq.w   .Llog_write_unit_E314           @ 0801E0F2 if (r4 == 0x19) goto 0x801E314
    b       .Llog_write_unit_E326           @ 0801E0F6 goto 0x801E326
    @ mode 0 (LowZ): ACV or DCV by flag 0
.Llog_write_unit_E0F8:                  @ v2.05 0x0801E0F8, reached from 0x0801E082
    ldr.w   r0, =log_view_flag0             @ 0801E0F8 r0 = &log_view_flag0
    ldrb    r0, [r0]                        @ 0801E0FC r0 = u8 [log_view_flag0]
    cmp     r0, #0                          @ 0801E0FE compare r0 with 0
    beq     .Llog_write_unit_E114           @ 0801E100 if (r0 == 0) goto 0x801E114
    movs    r2, #0                          @ 0801E102 r2 = 0
    movs    r1, #0                          @ 0801E104 r1 = 0
    movs    r0, #0x33                       @ 0801E106 r0 = 0x33
    bl      log_write_csv_token             @ 0801E108 call log_write_csv_token
    cmp     r0, #0                          @ 0801E10C compare r0 with 0
    beq     .Llog_write_unit_E126           @ 0801E10E if (r0 == 0) goto 0x801E126
    movs    r0, #1                          @ 0801E110 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E112 goto 0x801E32A
.Llog_write_unit_E114:                  @ v2.05 0x0801E114, reached from 0x0801E100
    movs    r2, #0                          @ 0801E114 r2 = 0
    movs    r1, #0                          @ 0801E116 r1 = 0
    movs    r0, #0x34                       @ 0801E118 r0 = 0x34
    bl      log_write_csv_token             @ 0801E11A call log_write_csv_token
    cmp     r0, #0                          @ 0801E11E compare r0 with 0
    beq     .Llog_write_unit_E126           @ 0801E120 if (r0 == 0) goto 0x801E126
    movs    r0, #1                          @ 0801E122 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E124 goto 0x801E32A
.Llog_write_unit_E126:                  @ v2.05 0x0801E126, reached from 0x0801E10E, 0x0801E120
    b       .Llog_write_unit_E326           @ 0801E126 goto 0x801E326
    @ mode 1 and 2: V
.Llog_write_unit_E128:                  @ v2.05 0x0801E128, reached from 0x0801E086, 0x0801E088
    movs    r2, #0                          @ 0801E128 r2 = 0
    movs    r1, #0                          @ 0801E12A r1 = 0
    movs    r0, #0x35                       @ 0801E12C r0 = 0x35
    bl      log_write_csv_token             @ 0801E12E call log_write_csv_token
    cmp     r0, #0                          @ 0801E132 compare r0 with 0
    beq     .Llog_write_unit_E13A           @ 0801E134 if (r0 == 0) goto 0x801E13A
    movs    r0, #1                          @ 0801E136 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E138 goto 0x801E32A
.Llog_write_unit_E13A:                  @ v2.05 0x0801E13A, reached from 0x0801E134
    b       .Llog_write_unit_E326           @ 0801E13A goto 0x801E326
    @ modes 3 and 4: mV
.Llog_write_unit_E13C:                  @ v2.05 0x0801E13C, reached from 0x0801E08C, 0x0801E08E
    movs    r2, #0                          @ 0801E13C r2 = 0
    movs    r1, #0                          @ 0801E13E r1 = 0
    movs    r0, #0x36                       @ 0801E140 r0 = 0x36
    bl      log_write_csv_token             @ 0801E142 call log_write_csv_token
    cmp     r0, #0                          @ 0801E146 compare r0 with 0
    beq     .Llog_write_unit_E14E           @ 0801E148 if (r0 == 0) goto 0x801E14E
    movs    r0, #1                          @ 0801E14A r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E14C goto 0x801E32A
.Llog_write_unit_E14E:                  @ v2.05 0x0801E14E, reached from 0x0801E148
    b       .Llog_write_unit_E326           @ 0801E14E goto 0x801E326
    @ mode 5: 'C (flag 5 set) or 'F
.Llog_write_unit_E150:                  @ v2.05 0x0801E150, reached from 0x0801E094
    ldr.w   r0, =log_view_flag5             @ 0801E150 r0 = &log_view_flag5
    ldrb    r0, [r0]                        @ 0801E154 r0 = u8 [log_view_flag5]
    cmp     r0, #0                          @ 0801E156 compare r0 with 0
    beq     .Llog_write_unit_E16C           @ 0801E158 if (r0 == 0) goto 0x801E16C
    movs    r2, #0                          @ 0801E15A r2 = 0
    movs    r1, #0                          @ 0801E15C r1 = 0
    movs    r0, #0x37                       @ 0801E15E r0 = 0x37
    bl      log_write_csv_token             @ 0801E160 call log_write_csv_token
    cmp     r0, #0                          @ 0801E164 compare r0 with 0
    beq     .Llog_write_unit_E17E           @ 0801E166 if (r0 == 0) goto 0x801E17E
    movs    r0, #1                          @ 0801E168 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E16A goto 0x801E32A
.Llog_write_unit_E16C:                  @ v2.05 0x0801E16C, reached from 0x0801E158
    movs    r2, #0                          @ 0801E16C r2 = 0
    movs    r1, #0                          @ 0801E16E r1 = 0
    movs    r0, #0x38                       @ 0801E170 r0 = 0x38
    bl      log_write_csv_token             @ 0801E172 call log_write_csv_token
    cmp     r0, #0                          @ 0801E176 compare r0 with 0
    beq     .Llog_write_unit_E17E           @ 0801E178 if (r0 == 0) goto 0x801E17E
    movs    r0, #1                          @ 0801E17A r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E17C goto 0x801E32A
.Llog_write_unit_E17E:                  @ v2.05 0x0801E17E, reached from 0x0801E166, 0x0801E178
    b       .Llog_write_unit_E326           @ 0801E17E goto 0x801E326
    @ mode 6: KHz from range 2, else Hz
.Llog_write_unit_E180:                  @ v2.05 0x0801E180, reached from 0x0801E092
    uxtb    r5, r5                          @ 0801E180 r5 = u8(r5)
    cmp     r5, #2                          @ 0801E182 compare r5 with 2
    bge     .Llog_write_unit_E198           @ 0801E184 if (r5 >= 2) goto 0x801E198
    movs    r2, #0                          @ 0801E186 r2 = 0
    movs    r1, #0                          @ 0801E188 r1 = 0
    movs    r0, #0x39                       @ 0801E18A r0 = 0x39
    bl      log_write_csv_token             @ 0801E18C call log_write_csv_token
    cmp     r0, #0                          @ 0801E190 compare r0 with 0
    beq     .Llog_write_unit_E1AA           @ 0801E192 if (r0 == 0) goto 0x801E1AA
    movs    r0, #1                          @ 0801E194 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E196 goto 0x801E32A
.Llog_write_unit_E198:                  @ v2.05 0x0801E198, reached from 0x0801E184
    movs    r2, #0                          @ 0801E198 r2 = 0
    movs    r1, #0                          @ 0801E19A r1 = 0
    movs    r0, #0x3a                       @ 0801E19C r0 = 0x3a
    bl      log_write_csv_token             @ 0801E19E call log_write_csv_token
    cmp     r0, #0                          @ 0801E1A2 compare r0 with 0
    beq     .Llog_write_unit_E1AA           @ 0801E1A4 if (r0 == 0) goto 0x801E1AA
    movs    r0, #1                          @ 0801E1A6 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E1A8 goto 0x801E32A
.Llog_write_unit_E1AA:                  @ v2.05 0x0801E1AA, reached from 0x0801E192, 0x0801E1A4
    b       .Llog_write_unit_E326           @ 0801E1AA goto 0x801E326
    @ mode 7: mSec
.Llog_write_unit_E1AC:                  @ v2.05 0x0801E1AC, reached from 0x0801E09C
    movs    r2, #0                          @ 0801E1AC r2 = 0
    movs    r1, #0                          @ 0801E1AE r1 = 0
    movs    r0, #0x3b                       @ 0801E1B0 r0 = 0x3b
    bl      log_write_csv_token             @ 0801E1B2 call log_write_csv_token
    cmp     r0, #0                          @ 0801E1B6 compare r0 with 0
    beq     .Llog_write_unit_E1BE           @ 0801E1B8 if (r0 == 0) goto 0x801E1BE
    movs    r0, #1                          @ 0801E1BA r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E1BC goto 0x801E32A
.Llog_write_unit_E1BE:                  @ v2.05 0x0801E1BE, reached from 0x0801E1B8
    b       .Llog_write_unit_E326           @ 0801E1BE goto 0x801E326
    @ mode 8: %
.Llog_write_unit_E1C0:                  @ v2.05 0x0801E1C0, reached from 0x0801E098
    movs    r2, #0                          @ 0801E1C0 r2 = 0
    movs    r1, #0                          @ 0801E1C2 r1 = 0
    movs    r0, #0x3c                       @ 0801E1C4 r0 = 0x3c
    bl      log_write_csv_token             @ 0801E1C6 call log_write_csv_token
    cmp     r0, #0                          @ 0801E1CA compare r0 with 0
    beq     .Llog_write_unit_E1D2           @ 0801E1CC if (r0 == 0) goto 0x801E1D2
    movs    r0, #1                          @ 0801E1CE r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E1D0 goto 0x801E32A
.Llog_write_unit_E1D2:                  @ v2.05 0x0801E1D2, reached from 0x0801E1CC
    b       .Llog_write_unit_E326           @ 0801E1D2 goto 0x801E326
    @ mode 9: ohm / Kohm / Mohm by range
.Llog_write_unit_E1D4:                  @ v2.05 0x0801E1D4, reached from 0x0801E0A6
    uxtb    r5, r5                          @ 0801E1D4 r5 = u8(r5)
    cmp     r5, #2                          @ 0801E1D6 compare r5 with 2
    bge     .Llog_write_unit_E1EC           @ 0801E1D8 if (r5 >= 2) goto 0x801E1EC
    movs    r2, #0                          @ 0801E1DA r2 = 0
    movs    r1, #0                          @ 0801E1DC r1 = 0
    movs    r0, #0x3d                       @ 0801E1DE r0 = 0x3d
    bl      log_write_csv_token             @ 0801E1E0 call log_write_csv_token
    cmp     r0, #0                          @ 0801E1E4 compare r0 with 0
    beq     .Llog_write_unit_E216           @ 0801E1E6 if (r0 == 0) goto 0x801E216
    movs    r0, #1                          @ 0801E1E8 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E1EA goto 0x801E32A
.Llog_write_unit_E1EC:                  @ v2.05 0x0801E1EC, reached from 0x0801E1D8
    uxtb    r5, r5                          @ 0801E1EC r5 = u8(r5)
    cmp     r5, #5                          @ 0801E1EE compare r5 with 5
    bge     .Llog_write_unit_E204           @ 0801E1F0 if (r5 >= 5) goto 0x801E204
    movs    r2, #0                          @ 0801E1F2 r2 = 0
    movs    r1, #0                          @ 0801E1F4 r1 = 0
    movs    r0, #0x3e                       @ 0801E1F6 r0 = 0x3e
    bl      log_write_csv_token             @ 0801E1F8 call log_write_csv_token
    cmp     r0, #0                          @ 0801E1FC compare r0 with 0
    beq     .Llog_write_unit_E216           @ 0801E1FE if (r0 == 0) goto 0x801E216
    movs    r0, #1                          @ 0801E200 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E202 goto 0x801E32A
.Llog_write_unit_E204:                  @ v2.05 0x0801E204, reached from 0x0801E1F0
    movs    r2, #0                          @ 0801E204 r2 = 0
    movs    r1, #0                          @ 0801E206 r1 = 0
    movs    r0, #0x3f                       @ 0801E208 r0 = 0x3f
    bl      log_write_csv_token             @ 0801E20A call log_write_csv_token
    cmp     r0, #0                          @ 0801E20E compare r0 with 0
    beq     .Llog_write_unit_E216           @ 0801E210 if (r0 == 0) goto 0x801E216
    movs    r0, #1                          @ 0801E212 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E214 goto 0x801E32A
.Llog_write_unit_E216:                  @ v2.05 0x0801E216, reached from 0x0801E1E6, 0x0801E1FE, 0x0801E210
    b       .Llog_write_unit_E326           @ 0801E216 goto 0x801E326
    @ mode 10: ohm
.Llog_write_unit_E218:                  @ v2.05 0x0801E218, reached from 0x0801E0A2
    movs    r2, #0                          @ 0801E218 r2 = 0
    movs    r1, #0                          @ 0801E21A r1 = 0
    movs    r0, #0x3d                       @ 0801E21C r0 = 0x3d
    bl      log_write_csv_token             @ 0801E21E call log_write_csv_token
    cmp     r0, #0                          @ 0801E222 compare r0 with 0
    beq     .Llog_write_unit_E22A           @ 0801E224 if (r0 == 0) goto 0x801E22A
    movs    r0, #1                          @ 0801E226 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E228 goto 0x801E32A
.Llog_write_unit_E22A:                  @ v2.05 0x0801E22A, reached from 0x0801E224
    b       .Llog_write_unit_E326           @ 0801E22A goto 0x801E326
    @ mode 11: V
.Llog_write_unit_E22C:                  @ v2.05 0x0801E22C, reached from 0x0801E0B0
    movs    r2, #0                          @ 0801E22C r2 = 0
    movs    r1, #0                          @ 0801E22E r1 = 0
    movs    r0, #0x35                       @ 0801E230 r0 = 0x35
    bl      log_write_csv_token             @ 0801E232 call log_write_csv_token
    cmp     r0, #0                          @ 0801E236 compare r0 with 0
    beq     .Llog_write_unit_E23E           @ 0801E238 if (r0 == 0) goto 0x801E23E
    movs    r0, #1                          @ 0801E23A r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E23C goto 0x801E32A
.Llog_write_unit_E23E:                  @ v2.05 0x0801E23E, reached from 0x0801E238
    b       .Llog_write_unit_E326           @ 0801E23E goto 0x801E326
    @ mode 12: uF from range 2, else nF
.Llog_write_unit_E240:                  @ v2.05 0x0801E240, reached from 0x0801E0AC
    uxtb    r5, r5                          @ 0801E240 r5 = u8(r5)
    cmp     r5, #2                          @ 0801E242 compare r5 with 2
    bge     .Llog_write_unit_E258           @ 0801E244 if (r5 >= 2) goto 0x801E258
    movs    r2, #0                          @ 0801E246 r2 = 0
    movs    r1, #0                          @ 0801E248 r1 = 0
    movs    r0, #0x40                       @ 0801E24A r0 = 0x40
    bl      log_write_csv_token             @ 0801E24C call log_write_csv_token
    cmp     r0, #0                          @ 0801E250 compare r0 with 0
    beq     .Llog_write_unit_E26A           @ 0801E252 if (r0 == 0) goto 0x801E26A
    movs    r0, #1                          @ 0801E254 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E256 goto 0x801E32A
.Llog_write_unit_E258:                  @ v2.05 0x0801E258, reached from 0x0801E244
    movs    r2, #0                          @ 0801E258 r2 = 0
    movs    r1, #0                          @ 0801E25A r1 = 0
    movs    r0, #0x41                       @ 0801E25C r0 = 0x41
    bl      log_write_csv_token             @ 0801E25E call log_write_csv_token
    cmp     r0, #0                          @ 0801E262 compare r0 with 0
    beq     .Llog_write_unit_E26A           @ 0801E264 if (r0 == 0) goto 0x801E26A
    movs    r0, #1                          @ 0801E266 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E268 goto 0x801E32A
.Llog_write_unit_E26A:                  @ v2.05 0x0801E26A, reached from 0x0801E252, 0x0801E264
    b       .Llog_write_unit_E326           @ 0801E26A goto 0x801E326
    @ mode 13 and 22: uVA
.Llog_write_unit_E26C:                  @ v2.05 0x0801E26C, reached from 0x0801E0BA, 0x0801E0DE
    movs    r2, #0                          @ 0801E26C r2 = 0
    movs    r1, #0                          @ 0801E26E r1 = 0
    movs    r0, #0x42                       @ 0801E270 r0 = 0x42
    bl      log_write_csv_token             @ 0801E272 call log_write_csv_token
    cmp     r0, #0                          @ 0801E276 compare r0 with 0
    beq     .Llog_write_unit_E27E           @ 0801E278 if (r0 == 0) goto 0x801E27E
    movs    r0, #1                          @ 0801E27A r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E27C goto 0x801E32A
.Llog_write_unit_E27E:                  @ v2.05 0x0801E27E, reached from 0x0801E278
    b       .Llog_write_unit_E326           @ 0801E27E goto 0x801E326
    @ mode 14 and 23: mVA
.Llog_write_unit_E280:                  @ v2.05 0x0801E280, reached from 0x0801E0B6, 0x0801E0EC
    movs    r2, #0                          @ 0801E280 r2 = 0
    movs    r1, #0                          @ 0801E282 r1 = 0
    movs    r0, #0x43                       @ 0801E284 r0 = 0x43
    bl      log_write_csv_token             @ 0801E286 call log_write_csv_token
    cmp     r0, #0                          @ 0801E28A compare r0 with 0
    beq     .Llog_write_unit_E292           @ 0801E28C if (r0 == 0) goto 0x801E292
    movs    r0, #1                          @ 0801E28E r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E290 goto 0x801E32A
.Llog_write_unit_E292:                  @ v2.05 0x0801E292, reached from 0x0801E28C
    b       .Llog_write_unit_E326           @ 0801E292 goto 0x801E326
    @ mode 15 and 24: VA from range 1, else mVA
.Llog_write_unit_E294:                  @ v2.05 0x0801E294, reached from 0x0801E0C4, 0x0801E0E8
    uxtb    r5, r5                          @ 0801E294 r5 = u8(r5)
    cmp     r5, #0                          @ 0801E296 compare r5 with 0
    bne     .Llog_write_unit_E2AC           @ 0801E298 if (r5 != 0) goto 0x801E2AC
    movs    r2, #0                          @ 0801E29A r2 = 0
    movs    r1, #0                          @ 0801E29C r1 = 0
    movs    r0, #0x43                       @ 0801E29E r0 = 0x43
    bl      log_write_csv_token             @ 0801E2A0 call log_write_csv_token
    cmp     r0, #0                          @ 0801E2A4 compare r0 with 0
    beq     .Llog_write_unit_E2BE           @ 0801E2A6 if (r0 == 0) goto 0x801E2BE
    movs    r0, #1                          @ 0801E2A8 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E2AA goto 0x801E32A
.Llog_write_unit_E2AC:                  @ v2.05 0x0801E2AC, reached from 0x0801E298
    movs    r2, #0                          @ 0801E2AC r2 = 0
    movs    r1, #0                          @ 0801E2AE r1 = 0
    movs    r0, #0x44                       @ 0801E2B0 r0 = 0x44
    bl      log_write_csv_token             @ 0801E2B2 call log_write_csv_token
    cmp     r0, #0                          @ 0801E2B6 compare r0 with 0
    beq     .Llog_write_unit_E2BE           @ 0801E2B8 if (r0 == 0) goto 0x801E2BE
    movs    r0, #1                          @ 0801E2BA r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E2BC goto 0x801E32A
.Llog_write_unit_E2BE:                  @ v2.05 0x0801E2BE, reached from 0x0801E2A6, 0x0801E2B8
    b       .Llog_write_unit_E326           @ 0801E2BE goto 0x801E326
    @ modes 16 and 17: uA
.Llog_write_unit_E2C0:                  @ v2.05 0x0801E2C0, reached from 0x0801E0C0, 0x0801E0CE
    movs    r2, #0                          @ 0801E2C0 r2 = 0
    movs    r1, #0                          @ 0801E2C2 r1 = 0
    movs    r0, #0x45                       @ 0801E2C4 r0 = 0x45
    bl      log_write_csv_token             @ 0801E2C6 call log_write_csv_token
    cmp     r0, #0                          @ 0801E2CA compare r0 with 0
    beq     .Llog_write_unit_E2D2           @ 0801E2CC if (r0 == 0) goto 0x801E2D2
    movs    r0, #1                          @ 0801E2CE r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E2D0 goto 0x801E32A
.Llog_write_unit_E2D2:                  @ v2.05 0x0801E2D2, reached from 0x0801E2CC
    b       .Llog_write_unit_E326           @ 0801E2D2 goto 0x801E326
    @ modes 18 and 19: mA
.Llog_write_unit_E2D4:                  @ v2.05 0x0801E2D4, reached from 0x0801E0CA, 0x0801E0D8
    movs    r2, #0                          @ 0801E2D4 r2 = 0
    movs    r1, #0                          @ 0801E2D6 r1 = 0
    movs    r0, #0x46                       @ 0801E2D8 r0 = 0x46
    bl      log_write_csv_token             @ 0801E2DA call log_write_csv_token
    cmp     r0, #0                          @ 0801E2DE compare r0 with 0
    beq     .Llog_write_unit_E2E6           @ 0801E2E0 if (r0 == 0) goto 0x801E2E6
    movs    r0, #1                          @ 0801E2E2 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E2E4 goto 0x801E32A
.Llog_write_unit_E2E6:                  @ v2.05 0x0801E2E6, reached from 0x0801E2E0
    b       .Llog_write_unit_E326           @ 0801E2E6 goto 0x801E326
    @ modes 20 and 21: A
.Llog_write_unit_E2E8:                  @ v2.05 0x0801E2E8, reached from 0x0801E0D4, 0x0801E0E2
    uxtb    r5, r5                          @ 0801E2E8 r5 = u8(r5)
    cmp     r5, #0                          @ 0801E2EA compare r5 with 0
    bne     .Llog_write_unit_E300           @ 0801E2EC if (r5 != 0) goto 0x801E300
    movs    r2, #0                          @ 0801E2EE r2 = 0
    movs    r1, #0                          @ 0801E2F0 r1 = 0
    movs    r0, #0x46                       @ 0801E2F2 r0 = 0x46
    bl      log_write_csv_token             @ 0801E2F4 call log_write_csv_token
    cmp     r0, #0                          @ 0801E2F8 compare r0 with 0
    beq     .Llog_write_unit_E312           @ 0801E2FA if (r0 == 0) goto 0x801E312
    movs    r0, #1                          @ 0801E2FC r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E2FE goto 0x801E32A
.Llog_write_unit_E300:                  @ v2.05 0x0801E300, reached from 0x0801E2EC
    movs    r2, #0                          @ 0801E300 r2 = 0
    movs    r1, #0                          @ 0801E302 r1 = 0
    movs    r0, #0x47                       @ 0801E304 r0 = 0x47
    bl      log_write_csv_token             @ 0801E306 call log_write_csv_token
    cmp     r0, #0                          @ 0801E30A compare r0 with 0
    beq     .Llog_write_unit_E312           @ 0801E30C if (r0 == 0) goto 0x801E312
    movs    r0, #1                          @ 0801E30E r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E310 goto 0x801E32A
.Llog_write_unit_E312:                  @ v2.05 0x0801E312, reached from 0x0801E2FA, 0x0801E30C
    b       .Llog_write_unit_E326           @ 0801E312 goto 0x801E326
    @ mode 25 (burden voltage): mV
.Llog_write_unit_E314:                  @ v2.05 0x0801E314, reached from 0x0801E0F2
    movs    r2, #0                          @ 0801E314 r2 = 0
    movs    r1, #0                          @ 0801E316 r1 = 0
    movs    r0, #0x36                       @ 0801E318 r0 = 0x36
    bl      log_write_csv_token             @ 0801E31A call log_write_csv_token
    cmp     r0, #0                          @ 0801E31E compare r0 with 0
    beq     .Llog_write_unit_E326           @ 0801E320 if (r0 == 0) goto 0x801E326
    movs    r0, #1                          @ 0801E322 r0 = 1
    b       .Llog_write_unit_E32A           @ 0801E324 goto 0x801E32A
    @ other modes: nothing written
.Llog_write_unit_E326:                  @ v2.05 0x0801E326, reached from 0x0801E0F6, 0x0801E126, 0x0801E13A, 0x0801E14E, 0x0801E17E, 0x0801E1AA, 0x0801E1BE, 0x0801E1D2, 0x0801E216, 0x0801E22A, 0x0801E23E, 0x0801E26A, 0x0801E27E, 0x0801E292, 0x0801E2BE, 0x0801E2D2, 0x0801E2E6, 0x0801E312, 0x0801E320
    movs    r0, r6                          @ 0801E326 r0 = r6
    uxtb    r0, r0                          @ 0801E328 r0 = u8(r0)
.Llog_write_unit_E32A:                  @ v2.05 0x0801E32A, reached from 0x0801E112, 0x0801E124, 0x0801E138, 0x0801E14C, 0x0801E16A, 0x0801E17C, 0x0801E196, 0x0801E1A8, 0x0801E1BC, 0x0801E1D0, 0x0801E1EA, 0x0801E202, 0x0801E214, 0x0801E228, 0x0801E23C, 0x0801E256, 0x0801E268, 0x0801E27C, 0x0801E290, 0x0801E2AA, 0x0801E2BC, 0x0801E2D0, 0x0801E2E4, 0x0801E2FE, 0x0801E310, 0x0801E324
    pop     {r4, r5, r6, pc}                @ 0801E32A pop {r4, r5, r6, pc}
ENDFUNC log_write_unit
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_header - write the five header lines of the CSV file
@ Replaces  : 0x0801E330 FUN_0801E330 (v2.05), called by log_flush_records
@ In        : -
@ Out       : r0 = 0 ok, 1 a write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : log_file_size and log_flush_start = f_tell of the log file (the position before the header)
@ Spec      : v2.05 listing 0x0801E330..0x0801E3A7
@ -----------------------------------------------------------------------------
FUNC log_write_header
    push    {r4, lr}                        @ 0801E330 push {r4, lr}
    movs    r4, #0                          @ 0801E332 r4 = 0
    @ the file position before the header is the position to return to if the flush fails
    ldr.w   r0, =log_fil                    @ 0801E334 r0 = &log_fil
    bl      fat_f_tell                      @ 0801E338 call fat_f_tell
    ldr.w   r1, =log_file_size              @ 0801E33C r1 = &log_file_size
    str     r0, [r1]                        @ 0801E340 u32 [log_file_size] = r0
    ldr.w   r1, =log_flush_start            @ 0801E342 r1 = &log_flush_start
    str     r0, [r1]                        @ 0801E346 u32 [log_flush_start] = r0
    @ the lines in order: START, ID, INTERVAL, group titles, column titles; stop at the first failure
    bl      log_header_line_start           @ 0801E348 call log_header_line_start
    movs    r4, r0                          @ 0801E34C r4 = r0
    uxtb    r4, r4                          @ 0801E34E r4 = u8(r4)
    cmp     r4, #0                          @ 0801E350 compare r4 with 0
    beq     .Llog_write_header_E35A         @ 0801E352 if (r4 == 0) goto 0x801E35A
    movs    r0, r4                          @ 0801E354 r0 = r4
    uxtb    r0, r0                          @ 0801E356 r0 = u8(r0)
    b       .Llog_write_header_E3A6         @ 0801E358 goto 0x801E3A6
.Llog_write_header_E35A:                @ v2.05 0x0801E35A, reached from 0x0801E352
    bl      log_header_line_id              @ 0801E35A call log_header_line_id
    movs    r4, r0                          @ 0801E35E r4 = r0
    uxtb    r4, r4                          @ 0801E360 r4 = u8(r4)
    cmp     r4, #0                          @ 0801E362 compare r4 with 0
    beq     .Llog_write_header_E36C         @ 0801E364 if (r4 == 0) goto 0x801E36C
    movs    r0, r4                          @ 0801E366 r0 = r4
    uxtb    r0, r0                          @ 0801E368 r0 = u8(r0)
    b       .Llog_write_header_E3A6         @ 0801E36A goto 0x801E3A6
.Llog_write_header_E36C:                @ v2.05 0x0801E36C, reached from 0x0801E364
    bl      log_header_line_interval        @ 0801E36C call log_header_line_interval
    movs    r4, r0                          @ 0801E370 r4 = r0
    uxtb    r4, r4                          @ 0801E372 r4 = u8(r4)
    cmp     r4, #0                          @ 0801E374 compare r4 with 0
    beq     .Llog_write_header_E37E         @ 0801E376 if (r4 == 0) goto 0x801E37E
    movs    r0, r4                          @ 0801E378 r0 = r4
    uxtb    r0, r0                          @ 0801E37A r0 = u8(r0)
    b       .Llog_write_header_E3A6         @ 0801E37C goto 0x801E3A6
.Llog_write_header_E37E:                @ v2.05 0x0801E37E, reached from 0x0801E376
    bl      log_header_line_groups          @ 0801E37E call log_header_line_groups
    movs    r4, r0                          @ 0801E382 r4 = r0
    uxtb    r4, r4                          @ 0801E384 r4 = u8(r4)
    cmp     r4, #0                          @ 0801E386 compare r4 with 0
    beq     .Llog_write_header_E390         @ 0801E388 if (r4 == 0) goto 0x801E390
    movs    r0, r4                          @ 0801E38A r0 = r4
    uxtb    r0, r0                          @ 0801E38C r0 = u8(r0)
    b       .Llog_write_header_E3A6         @ 0801E38E goto 0x801E3A6
.Llog_write_header_E390:                @ v2.05 0x0801E390, reached from 0x0801E388
    bl      log_header_line_fields          @ 0801E390 call log_header_line_fields
    movs    r4, r0                          @ 0801E394 r4 = r0
    uxtb    r4, r4                          @ 0801E396 r4 = u8(r4)
    cmp     r4, #0                          @ 0801E398 compare r4 with 0
    beq     .Llog_write_header_E3A2         @ 0801E39A if (r4 == 0) goto 0x801E3A2
    movs    r0, r4                          @ 0801E39C r0 = r4
    uxtb    r0, r0                          @ 0801E39E r0 = u8(r0)
    b       .Llog_write_header_E3A6         @ 0801E3A0 goto 0x801E3A6
.Llog_write_header_E3A2:                @ v2.05 0x0801E3A2, reached from 0x0801E39A
    movs    r0, r4                          @ 0801E3A2 r0 = r4
    uxtb    r0, r0                          @ 0801E3A4 r0 = u8(r0)
.Llog_write_header_E3A6:                @ v2.05 0x0801E3A6, reached from 0x0801E358, 0x0801E36A, 0x0801E37C, 0x0801E38E, 0x0801E3A0
    pop     {r4, pc}                        @ 0801E3A6 pop {r4, pc}
ENDFUNC log_write_header
    .ltorg

@ -----------------------------------------------------------------------------
@ log_header_line_groups - write the line ",,,MAIN,,,SUB-1,,,SUB-2,,,Remark,"
@ Replaces  : 0x0801E3D8 FUN_0801E3D8 (v2.05), called by log_write_header
@ In        : -
@ Out       : r0 = 0 ok, 1 a write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E3D8..0x0801E43B (tokens 0x0B, 0x0C, 0x0D, 0x0E, 1)
@ -----------------------------------------------------------------------------
FUNC log_header_line_groups
    push    {r4, lr}                        @ 0801E3D8 push {r4, lr}
    movs    r4, #0                          @ 0801E3DA r4 = 0
    movs    r2, #0                          @ 0801E3DC r2 = 0
    movs    r1, #0                          @ 0801E3DE r1 = 0
    movs    r0, #0xb                        @ 0801E3E0 r0 = 0xb
    bl      log_write_csv_token             @ 0801E3E2 call log_write_csv_token
    cmp     r0, #0                          @ 0801E3E6 compare r0 with 0
    beq     .Llog_header_line_groups_E3EE   @ 0801E3E8 if (r0 == 0) goto 0x801E3EE
    movs    r0, #1                          @ 0801E3EA r0 = 1
    b       .Llog_header_line_groups_E43A   @ 0801E3EC goto 0x801E43A
.Llog_header_line_groups_E3EE:          @ v2.05 0x0801E3EE, reached from 0x0801E3E8
    movs    r2, #0                          @ 0801E3EE r2 = 0
    movs    r1, #0                          @ 0801E3F0 r1 = 0
    movs    r0, #0xc                        @ 0801E3F2 r0 = 0xc
    bl      log_write_csv_token             @ 0801E3F4 call log_write_csv_token
    cmp     r0, #0                          @ 0801E3F8 compare r0 with 0
    beq     .Llog_header_line_groups_E400   @ 0801E3FA if (r0 == 0) goto 0x801E400
    movs    r0, #1                          @ 0801E3FC r0 = 1
    b       .Llog_header_line_groups_E43A   @ 0801E3FE goto 0x801E43A
.Llog_header_line_groups_E400:          @ v2.05 0x0801E400, reached from 0x0801E3FA
    movs    r2, #0                          @ 0801E400 r2 = 0
    movs    r1, #0                          @ 0801E402 r1 = 0
    movs    r0, #0xd                        @ 0801E404 r0 = 0xd
    bl      log_write_csv_token             @ 0801E406 call log_write_csv_token
    cmp     r0, #0                          @ 0801E40A compare r0 with 0
    beq     .Llog_header_line_groups_E412   @ 0801E40C if (r0 == 0) goto 0x801E412
    movs    r0, #1                          @ 0801E40E r0 = 1
    b       .Llog_header_line_groups_E43A   @ 0801E410 goto 0x801E43A
.Llog_header_line_groups_E412:          @ v2.05 0x0801E412, reached from 0x0801E40C
    movs    r2, #0                          @ 0801E412 r2 = 0
    movs    r1, #0                          @ 0801E414 r1 = 0
    movs    r0, #0xe                        @ 0801E416 r0 = 0xe
    bl      log_write_csv_token             @ 0801E418 call log_write_csv_token
    cmp     r0, #0                          @ 0801E41C compare r0 with 0
    beq     .Llog_header_line_groups_E424   @ 0801E41E if (r0 == 0) goto 0x801E424
    movs    r0, #1                          @ 0801E420 r0 = 1
    b       .Llog_header_line_groups_E43A   @ 0801E422 goto 0x801E43A
.Llog_header_line_groups_E424:          @ v2.05 0x0801E424, reached from 0x0801E41E
    movs    r2, #0                          @ 0801E424 r2 = 0
    movs    r1, #0                          @ 0801E426 r1 = 0
    movs    r0, #1                          @ 0801E428 r0 = 1
    bl      log_write_csv_token             @ 0801E42A call log_write_csv_token
    cmp     r0, #0                          @ 0801E42E compare r0 with 0
    beq     .Llog_header_line_groups_E436   @ 0801E430 if (r0 == 0) goto 0x801E436
    movs    r0, #1                          @ 0801E432 r0 = 1
    b       .Llog_header_line_groups_E43A   @ 0801E434 goto 0x801E43A
.Llog_header_line_groups_E436:          @ v2.05 0x0801E436, reached from 0x0801E430
    movs    r0, r4                          @ 0801E436 r0 = r4
    uxtb    r0, r0                          @ 0801E438 r0 = u8(r0)
.Llog_header_line_groups_E43A:          @ v2.05 0x0801E43A, reached from 0x0801E3EC, 0x0801E3FE, 0x0801E410, 0x0801E422, 0x0801E434
    pop     {r4, pc}                        @ 0801E43A pop {r4, pc}
ENDFUNC log_header_line_groups
    .ltorg

@ -----------------------------------------------------------------------------
@ log_header_line_fields - write the line of column titles "No. ,Date      ,Time    ,Func. ,Value,Unit," three times for the three readings
@ Replaces  : 0x0801E43C FUN_0801E43C (v2.05), called by log_write_header
@ In        : -
@ Out       : r0 = 0 ok, 1 a write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E43C..0x0801E4D1 (tokens 0x0F, 0x13, 0x14, then 3 x (0x10, 0x11, 0x12), then 1)
@ -----------------------------------------------------------------------------
FUNC log_header_line_fields
    push    {r3, r4, r5, lr}                @ 0801E43C push {r3, r4, r5, lr}
    movs    r4, #0                          @ 0801E43E r4 = 0
    movs    r2, #0                          @ 0801E440 r2 = 0
    movs    r1, #0                          @ 0801E442 r1 = 0
    movs    r0, #0xf                        @ 0801E444 r0 = 0xf
    bl      log_write_csv_token             @ 0801E446 call log_write_csv_token
    cmp     r0, #0                          @ 0801E44A compare r0 with 0
    beq     .Llog_header_line_fields_E452   @ 0801E44C if (r0 == 0) goto 0x801E452
    movs    r0, #1                          @ 0801E44E r0 = 1
    b       .Llog_header_line_fields_E4D0   @ 0801E450 goto 0x801E4D0
.Llog_header_line_fields_E452:          @ v2.05 0x0801E452, reached from 0x0801E44C
    movs    r2, #0                          @ 0801E452 r2 = 0
    movs    r1, #0                          @ 0801E454 r1 = 0
    movs    r0, #0x13                       @ 0801E456 r0 = 0x13
    bl      log_write_csv_token             @ 0801E458 call log_write_csv_token
    cmp     r0, #0                          @ 0801E45C compare r0 with 0
    beq     .Llog_header_line_fields_E464   @ 0801E45E if (r0 == 0) goto 0x801E464
    movs    r0, #1                          @ 0801E460 r0 = 1
    b       .Llog_header_line_fields_E4D0   @ 0801E462 goto 0x801E4D0
.Llog_header_line_fields_E464:          @ v2.05 0x0801E464, reached from 0x0801E45E
    movs    r2, #0                          @ 0801E464 r2 = 0
    movs    r1, #0                          @ 0801E466 r1 = 0
    movs    r0, #0x14                       @ 0801E468 r0 = 0x14
    bl      log_write_csv_token             @ 0801E46A call log_write_csv_token
    cmp     r0, #0                          @ 0801E46E compare r0 with 0
    beq     .Llog_header_line_fields_E476   @ 0801E470 if (r0 == 0) goto 0x801E476
    movs    r0, #1                          @ 0801E472 r0 = 1
    b       .Llog_header_line_fields_E4D0   @ 0801E474 goto 0x801E4D0
.Llog_header_line_fields_E476:          @ v2.05 0x0801E476, reached from 0x0801E470
    movs    r0, #0                          @ 0801E476 r0 = 0
    movs    r5, r0                          @ 0801E478 r5 = r0
.Llog_header_line_fields_E47A:          @ v2.05 0x0801E47A, reached from 0x0801E4B8
    uxtb    r5, r5                          @ 0801E47A r5 = u8(r5)
    cmp     r5, #3                          @ 0801E47C compare r5 with 3
    bge     .Llog_header_line_fields_E4BA   @ 0801E47E if (r5 >= 3) goto 0x801E4BA
    movs    r2, #0                          @ 0801E480 r2 = 0
    movs    r1, #0                          @ 0801E482 r1 = 0
    movs    r0, #0x10                       @ 0801E484 r0 = 0x10
    bl      log_write_csv_token             @ 0801E486 call log_write_csv_token
    cmp     r0, #0                          @ 0801E48A compare r0 with 0
    beq     .Llog_header_line_fields_E492   @ 0801E48C if (r0 == 0) goto 0x801E492
    movs    r0, #1                          @ 0801E48E r0 = 1
    b       .Llog_header_line_fields_E4D0   @ 0801E490 goto 0x801E4D0
.Llog_header_line_fields_E492:          @ v2.05 0x0801E492, reached from 0x0801E48C
    movs    r2, #0                          @ 0801E492 r2 = 0
    movs    r1, #0                          @ 0801E494 r1 = 0
    movs    r0, #0x11                       @ 0801E496 r0 = 0x11
    bl      log_write_csv_token             @ 0801E498 call log_write_csv_token
    cmp     r0, #0                          @ 0801E49C compare r0 with 0
    beq     .Llog_header_line_fields_E4A4   @ 0801E49E if (r0 == 0) goto 0x801E4A4
    movs    r0, #1                          @ 0801E4A0 r0 = 1
    b       .Llog_header_line_fields_E4D0   @ 0801E4A2 goto 0x801E4D0
.Llog_header_line_fields_E4A4:          @ v2.05 0x0801E4A4, reached from 0x0801E49E
    movs    r2, #0                          @ 0801E4A4 r2 = 0
    movs    r1, #0                          @ 0801E4A6 r1 = 0
    movs    r0, #0x12                       @ 0801E4A8 r0 = 0x12
    bl      log_write_csv_token             @ 0801E4AA call log_write_csv_token
    cmp     r0, #0                          @ 0801E4AE compare r0 with 0
    beq     .Llog_header_line_fields_E4B6   @ 0801E4B0 if (r0 == 0) goto 0x801E4B6
    movs    r0, #1                          @ 0801E4B2 r0 = 1
    b       .Llog_header_line_fields_E4D0   @ 0801E4B4 goto 0x801E4D0
.Llog_header_line_fields_E4B6:          @ v2.05 0x0801E4B6, reached from 0x0801E4B0
    adds    r5, r5, #1                      @ 0801E4B6 r5 = r5 + 1
    b       .Llog_header_line_fields_E47A   @ 0801E4B8 goto 0x801E47A
.Llog_header_line_fields_E4BA:          @ v2.05 0x0801E4BA, reached from 0x0801E47E
    movs    r2, #0                          @ 0801E4BA r2 = 0
    movs    r1, #0                          @ 0801E4BC r1 = 0
    movs    r0, #1                          @ 0801E4BE r0 = 1
    bl      log_write_csv_token             @ 0801E4C0 call log_write_csv_token
    cmp     r0, #0                          @ 0801E4C4 compare r0 with 0
    beq     .Llog_header_line_fields_E4CC   @ 0801E4C6 if (r0 == 0) goto 0x801E4CC
    movs    r0, #1                          @ 0801E4C8 r0 = 1
    b       .Llog_header_line_fields_E4D0   @ 0801E4CA goto 0x801E4D0
.Llog_header_line_fields_E4CC:          @ v2.05 0x0801E4CC, reached from 0x0801E4C6
    movs    r0, r4                          @ 0801E4CC r0 = r4
    uxtb    r0, r0                          @ 0801E4CE r0 = u8(r0)
.Llog_header_line_fields_E4D0:          @ v2.05 0x0801E4D0, reached from 0x0801E450, 0x0801E462, 0x0801E474, 0x0801E490, 0x0801E4A2, 0x0801E4B4, 0x0801E4CA
    pop     {r1, r4, r5, pc}                @ 0801E4D0 pop {r1, r4, r5, pc}
ENDFUNC log_header_line_fields
    .ltorg

@ -----------------------------------------------------------------------------
@ log_header_line_id - write the line "ID,nnnnnnnnn,"
@ Replaces  : 0x0801E4D2 FUN_0801E4D2 (v2.05), called by log_write_header
@ In        : -
@ Out       : r0 = 0 ok, 1 a write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E4D2..0x0801E511 (tokens 6, 0x68, 1)
@ -----------------------------------------------------------------------------
FUNC log_header_line_id
    push    {r4, lr}                        @ 0801E4D2 push {r4, lr}
    movs    r4, #0                          @ 0801E4D4 r4 = 0
    movs    r2, #0                          @ 0801E4D6 r2 = 0
    movs    r1, #0                          @ 0801E4D8 r1 = 0
    movs    r0, #6                          @ 0801E4DA r0 = 6
    bl      log_write_csv_token             @ 0801E4DC call log_write_csv_token
    cmp     r0, #0                          @ 0801E4E0 compare r0 with 0
    beq     .Llog_header_line_id_E4E8       @ 0801E4E2 if (r0 == 0) goto 0x801E4E8
    movs    r0, #1                          @ 0801E4E4 r0 = 1
    b       .Llog_header_line_id_E510       @ 0801E4E6 goto 0x801E510
.Llog_header_line_id_E4E8:              @ v2.05 0x0801E4E8, reached from 0x0801E4E2
    movs    r2, #0                          @ 0801E4E8 r2 = 0
    movs    r1, #0                          @ 0801E4EA r1 = 0
    movs    r0, #0x68                       @ 0801E4EC r0 = 0x68
    bl      log_write_csv_token             @ 0801E4EE call log_write_csv_token
    cmp     r0, #0                          @ 0801E4F2 compare r0 with 0
    beq     .Llog_header_line_id_E4FA       @ 0801E4F4 if (r0 == 0) goto 0x801E4FA
    movs    r0, #1                          @ 0801E4F6 r0 = 1
    b       .Llog_header_line_id_E510       @ 0801E4F8 goto 0x801E510
.Llog_header_line_id_E4FA:              @ v2.05 0x0801E4FA, reached from 0x0801E4F4
    movs    r2, #0                          @ 0801E4FA r2 = 0
    movs    r1, #0                          @ 0801E4FC r1 = 0
    movs    r0, #1                          @ 0801E4FE r0 = 1
    bl      log_write_csv_token             @ 0801E500 call log_write_csv_token
    cmp     r0, #0                          @ 0801E504 compare r0 with 0
    beq     .Llog_header_line_id_E50C       @ 0801E506 if (r0 == 0) goto 0x801E50C
    movs    r0, #1                          @ 0801E508 r0 = 1
    b       .Llog_header_line_id_E510       @ 0801E50A goto 0x801E510
.Llog_header_line_id_E50C:              @ v2.05 0x0801E50C, reached from 0x0801E506
    movs    r0, r4                          @ 0801E50C r0 = r4
    uxtb    r0, r0                          @ 0801E50E r0 = u8(r0)
.Llog_header_line_id_E510:              @ v2.05 0x0801E510, reached from 0x0801E4E6, 0x0801E4F8, 0x0801E50A
    pop     {r4, pc}                        @ 0801E510 pop {r4, pc}
ENDFUNC log_header_line_id
    .ltorg

@ -----------------------------------------------------------------------------
@ log_header_line_start - write the line "START,YYYY/MM/DD,hh:mm:ss,"
@ Replaces  : 0x0801E512 FUN_0801E512 (v2.05), called by log_write_header
@ In        : -
@ Out       : r0 = 0 ok, 1 a write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E512..0x0801E563 (tokens 5, 0x66, 0x67, 1)
@ -----------------------------------------------------------------------------
FUNC log_header_line_start
    push    {r4, lr}                        @ 0801E512 push {r4, lr}
    movs    r4, #0                          @ 0801E514 r4 = 0
    movs    r2, #0                          @ 0801E516 r2 = 0
    movs    r1, #0                          @ 0801E518 r1 = 0
    movs    r0, #5                          @ 0801E51A r0 = 5
    bl      log_write_csv_token             @ 0801E51C call log_write_csv_token
    cmp     r0, #0                          @ 0801E520 compare r0 with 0
    beq     .Llog_header_line_start_E528    @ 0801E522 if (r0 == 0) goto 0x801E528
    movs    r0, #1                          @ 0801E524 r0 = 1
    b       .Llog_header_line_start_E562    @ 0801E526 goto 0x801E562
.Llog_header_line_start_E528:           @ v2.05 0x0801E528, reached from 0x0801E522
    movs    r2, #0                          @ 0801E528 r2 = 0
    movs    r1, #0                          @ 0801E52A r1 = 0
    movs    r0, #0x66                       @ 0801E52C r0 = 0x66
    bl      log_write_csv_token             @ 0801E52E call log_write_csv_token
    cmp     r0, #0                          @ 0801E532 compare r0 with 0
    beq     .Llog_header_line_start_E53A    @ 0801E534 if (r0 == 0) goto 0x801E53A
    movs    r0, #1                          @ 0801E536 r0 = 1
    b       .Llog_header_line_start_E562    @ 0801E538 goto 0x801E562
.Llog_header_line_start_E53A:           @ v2.05 0x0801E53A, reached from 0x0801E534
    movs    r2, #0                          @ 0801E53A r2 = 0
    movs    r1, #0                          @ 0801E53C r1 = 0
    movs    r0, #0x67                       @ 0801E53E r0 = 0x67
    bl      log_write_csv_token             @ 0801E540 call log_write_csv_token
    cmp     r0, #0                          @ 0801E544 compare r0 with 0
    beq     .Llog_header_line_start_E54C    @ 0801E546 if (r0 == 0) goto 0x801E54C
    movs    r0, #1                          @ 0801E548 r0 = 1
    b       .Llog_header_line_start_E562    @ 0801E54A goto 0x801E562
.Llog_header_line_start_E54C:           @ v2.05 0x0801E54C, reached from 0x0801E546
    movs    r2, #0                          @ 0801E54C r2 = 0
    movs    r1, #0                          @ 0801E54E r1 = 0
    movs    r0, #1                          @ 0801E550 r0 = 1
    bl      log_write_csv_token             @ 0801E552 call log_write_csv_token
    cmp     r0, #0                          @ 0801E556 compare r0 with 0
    beq     .Llog_header_line_start_E55E    @ 0801E558 if (r0 == 0) goto 0x801E55E
    movs    r0, #1                          @ 0801E55A r0 = 1
    b       .Llog_header_line_start_E562    @ 0801E55C goto 0x801E562
.Llog_header_line_start_E55E:           @ v2.05 0x0801E55E, reached from 0x0801E558
    movs    r0, r4                          @ 0801E55E r0 = r4
    uxtb    r0, r0                          @ 0801E560 r0 = u8(r0)
.Llog_header_line_start_E562:           @ v2.05 0x0801E562, reached from 0x0801E526, 0x0801E538, 0x0801E54A, 0x0801E55C
    pop     {r4, pc}                        @ 0801E562 pop {r4, pc}
ENDFUNC log_header_line_start
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_minmax_rows - write the MAX and MIN rows that close the file
@ Replaces  : 0x0801E564 FUN_0801E564 (v2.05), called by log_session_once
@ In        : -
@ Out       : r0 = 0 ok, 1 a write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_max_func/flags/value/row and log_min_*; sets log_view_mode1 and log_view_range1 from the function code
@ Spec      : v2.05 listing 0x0801E564..0x0801E73F
@ Note      : each row is "MAX," or "MIN,", the row number where it occurred, the function name, the value (Overflow, -Overflow
@             or the signed number) and the unit, then CRLF.  The production image writes the date and time of the row
@             before the CRLF (log/mmtime.s log_mm_write).
@ -----------------------------------------------------------------------------
FUNC log_write_minmax_rows
    push    {r3, r4, r5, lr}                @ 0801E564 push {r3, r4, r5, lr}
    movs    r4, #0                          @ 0801E566 r4 = 0
    movs    r5, #0                          @ 0801E568 r5 = 0
    @ maximum: mode = code & 0x1F, range = code >> 5
    ldr     r0, =log_max_func               @ 0801E56A r0 = &log_max_func
    ldrb    r0, [r0]                        @ 0801E56C r0 = u8 [log_max_func]
    ands    r0, r0, #0x1f                   @ 0801E56E r0 = r0 & 0x1f
    ldr     r1, =log_view_mode1             @ 0801E572 r1 = &log_view_mode1
    strb    r0, [r1]                        @ 0801E574 u8 [log_view_mode1] = r0
    ldr     r0, =log_max_func               @ 0801E576 r0 = &log_max_func
    ldrb    r0, [r0]                        @ 0801E578 r0 = u8 [log_max_func]
    uxtb    r0, r0                          @ 0801E57A r0 = u8(r0)
    lsrs    r0, r0, #5                      @ 0801E57C r0 = r0 >> 5
    ldr     r1, =log_view_range1            @ 0801E57E r1 = &log_view_range1
    strb    r0, [r1]                        @ 0801E580 u8 [log_view_range1] = r0
    movs    r2, #0                          @ 0801E582 r2 = 0
    movs    r1, #0                          @ 0801E584 r1 = 0
    movs    r0, #0x5b                       @ 0801E586 r0 = 0x5b
    @ token 0x5B "MAX,", row number, function name
    bl      log_write_csv_token             @ 0801E588 call log_write_csv_token
    cmp     r0, #0                          @ 0801E58C compare r0 with 0
    beq     .Llog_write_minmax_rows_E594    @ 0801E58E if (r0 == 0) goto 0x801E594
    movs    r0, #1                          @ 0801E590 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E592 goto 0x801E73E
.Llog_write_minmax_rows_E594:           @ v2.05 0x0801E594, reached from 0x0801E58E
    ldr     r0, =log_max_row                @ 0801E594 r0 = &log_max_row
    ldr     r0, [r0]                        @ 0801E596 r0 = u32 [log_max_row]
    bl      log_write_label                 @ 0801E598 call log_write_label
    cmp     r0, #0                          @ 0801E59C compare r0 with 0
    beq     .Llog_write_minmax_rows_E5A4    @ 0801E59E if (r0 == 0) goto 0x801E5A4
    movs    r0, #1                          @ 0801E5A0 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E5A2 goto 0x801E73E
.Llog_write_minmax_rows_E5A4:           @ v2.05 0x0801E5A4, reached from 0x0801E59E
    ldr     r0, =log_view_mode1             @ 0801E5A4 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801E5A6 r0 = u8 [log_view_mode1]
    bl      log_write_func_name             @ 0801E5A8 call log_write_func_name
    cmp     r0, #0                          @ 0801E5AC compare r0 with 0
    beq     .Llog_write_minmax_rows_E5B4    @ 0801E5AE if (r0 == 0) goto 0x801E5B4
    movs    r0, #1                          @ 0801E5B0 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E5B2 goto 0x801E73E
    @ value as in log_write_row; a complemented negative is written as "-" and the number
.Llog_write_minmax_rows_E5B4:           @ v2.05 0x0801E5B4, reached from 0x0801E5AE
    ldr     r0, =log_max_flags              @ 0801E5B4 r0 = &log_max_flags
    ldrb    r0, [r0]                        @ 0801E5B6 r0 = u8 [log_max_flags]
    lsls    r0, r0, #0x18                   @ 0801E5B8 r0 = r0 << 0x18
    bpl     .Llog_write_minmax_rows_E5E8    @ 0801E5BA if (r0 >=0 0) goto 0x801E5E8
    ldr     r0, =log_max_flags              @ 0801E5BC r0 = &log_max_flags
    ldrb    r0, [r0]                        @ 0801E5BE r0 = u8 [log_max_flags]
    lsls    r0, r0, #0x19                   @ 0801E5C0 r0 = r0 << 0x19
    bpl     .Llog_write_minmax_rows_E5D6    @ 0801E5C2 if (r0 >=0 0) goto 0x801E5D6
    movs    r2, #0                          @ 0801E5C4 r2 = 0
    movs    r1, #0                          @ 0801E5C6 r1 = 0
    movs    r0, #2                          @ 0801E5C8 r0 = 2
    bl      log_write_csv_token             @ 0801E5CA call log_write_csv_token
    cmp     r0, #0                          @ 0801E5CE compare r0 with 0
    beq     .Llog_write_minmax_rows_E61A    @ 0801E5D0 if (r0 == 0) goto 0x801E61A
    movs    r0, #1                          @ 0801E5D2 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E5D4 goto 0x801E73E
.Llog_write_minmax_rows_E5D6:           @ v2.05 0x0801E5D6, reached from 0x0801E5C2
    movs    r2, #0                          @ 0801E5D6 r2 = 0
    movs    r1, #0                          @ 0801E5D8 r1 = 0
    movs    r0, #3                          @ 0801E5DA r0 = 3
    bl      log_write_csv_token             @ 0801E5DC call log_write_csv_token
    cmp     r0, #0                          @ 0801E5E0 compare r0 with 0
    beq     .Llog_write_minmax_rows_E61A    @ 0801E5E2 if (r0 == 0) goto 0x801E61A
    movs    r0, #1                          @ 0801E5E4 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E5E6 goto 0x801E73E
.Llog_write_minmax_rows_E5E8:           @ v2.05 0x0801E5E8, reached from 0x0801E5BA
    ldr     r0, =log_max_flags              @ 0801E5E8 r0 = &log_max_flags
    ldrb    r0, [r0]                        @ 0801E5EA r0 = u8 [log_max_flags]
    lsls    r0, r0, #0x19                   @ 0801E5EC r0 = r0 << 0x19
    bpl     .Llog_write_minmax_rows_E602    @ 0801E5EE if (r0 >=0 0) goto 0x801E602
    movs    r2, #0                          @ 0801E5F0 r2 = 0
    movs    r1, #0                          @ 0801E5F2 r1 = 0
    movs    r0, #4                          @ 0801E5F4 r0 = 4
    bl      log_write_csv_token             @ 0801E5F6 call log_write_csv_token
    cmp     r0, #0                          @ 0801E5FA compare r0 with 0
    beq     .Llog_write_minmax_rows_E602    @ 0801E5FC if (r0 == 0) goto 0x801E602
    movs    r0, #1                          @ 0801E5FE r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E600 goto 0x801E73E
.Llog_write_minmax_rows_E602:           @ v2.05 0x0801E602, reached from 0x0801E5EE, 0x0801E5FC
    ldr     r0, =log_max_value              @ 0801E602 r0 = &log_max_value
    ldr     r2, [r0]                        @ 0801E604 r2 = u32 [log_max_value]
    ldr     r0, =log_view_range1            @ 0801E606 r0 = &log_view_range1
    ldrb    r1, [r0]                        @ 0801E608 r1 = u8 [log_view_range1]
    ldr     r0, =log_view_mode1             @ 0801E60A r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801E60C r0 = u8 [log_view_mode1]
    bl      log_write_value                 @ 0801E60E call log_write_value
    cmp     r0, #0                          @ 0801E612 compare r0 with 0
    beq     .Llog_write_minmax_rows_E61A    @ 0801E614 if (r0 == 0) goto 0x801E61A
    movs    r0, #1                          @ 0801E616 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E618 goto 0x801E73E
    @ "," and the unit, then the line end
.Llog_write_minmax_rows_E61A:           @ v2.05 0x0801E61A, reached from 0x0801E5D0, 0x0801E5E2, 0x0801E614
    movs    r2, #0                          @ 0801E61A r2 = 0
    movs    r1, #0                          @ 0801E61C r1 = 0
    movs    r0, #0                          @ 0801E61E r0 = 0
    bl      log_write_csv_token             @ 0801E620 call log_write_csv_token
    cmp     r0, #0                          @ 0801E624 compare r0 with 0
    beq     .Llog_write_minmax_rows_E62C    @ 0801E626 if (r0 == 0) goto 0x801E62C
    movs    r0, #1                          @ 0801E628 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E62A goto 0x801E73E
.Llog_write_minmax_rows_E62C:           @ v2.05 0x0801E62C, reached from 0x0801E626
    ldr     r0, =log_view_range1            @ 0801E62C r0 = &log_view_range1
    ldrb    r1, [r0]                        @ 0801E62E r1 = u8 [log_view_range1]
    ldr     r0, =log_view_mode1             @ 0801E630 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801E632 r0 = u8 [log_view_mode1]
    bl      log_write_unit                  @ 0801E634 call log_write_unit
    cmp     r0, #0                          @ 0801E638 compare r0 with 0
    beq     .Llog_write_minmax_rows_E640    @ 0801E63A if (r0 == 0) goto 0x801E640
    movs    r0, #1                          @ 0801E63C r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E63E goto 0x801E73E
.Llog_write_minmax_rows_E640:           @ v2.05 0x0801E640, reached from 0x0801E63A
    ldr     r0, =log_max_time                @ production: "YYYY/MM/DD,hh:mm:ss," of the maximum row (log/mmtime.s)
    bl      log_mm_write
    cmp     r0, #0
    bne     .Llog_write_minmax_rows_E73E    @ r0 = 1: a write failed
    movs    r2, #0                          @ 0801E640 r2 = 0
    movs    r1, #0                          @ 0801E642 r1 = 0
    movs    r0, #1                          @ 0801E644 r0 = 1
    bl      log_write_csv_token             @ 0801E646 call log_write_csv_token
    cmp     r0, #0                          @ 0801E64A compare r0 with 0
    beq     .Llog_write_minmax_rows_E652    @ 0801E64C if (r0 == 0) goto 0x801E652
    movs    r0, #1                          @ 0801E64E r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E650 goto 0x801E73E
    @ minimum: the same with token 0x5C "MIN,"
.Llog_write_minmax_rows_E652:           @ v2.05 0x0801E652, reached from 0x0801E64C
    ldr     r0, =log_min_func               @ 0801E652 r0 = &log_min_func
    ldrb    r0, [r0]                        @ 0801E654 r0 = u8 [log_min_func]
    ands    r0, r0, #0x1f                   @ 0801E656 r0 = r0 & 0x1f
    ldr     r1, =log_view_mode1             @ 0801E65A r1 = &log_view_mode1
    strb    r0, [r1]                        @ 0801E65C u8 [log_view_mode1] = r0
    ldr     r0, =log_min_func               @ 0801E65E r0 = &log_min_func
    ldrb    r0, [r0]                        @ 0801E660 r0 = u8 [log_min_func]
    uxtb    r0, r0                          @ 0801E662 r0 = u8(r0)
    lsrs    r0, r0, #5                      @ 0801E664 r0 = r0 >> 5
    ldr     r1, =log_view_range1            @ 0801E666 r1 = &log_view_range1
    strb    r0, [r1]                        @ 0801E668 u8 [log_view_range1] = r0
    movs    r2, #0                          @ 0801E66A r2 = 0
    movs    r1, #0                          @ 0801E66C r1 = 0
    movs    r0, #0x5c                       @ 0801E66E r0 = 0x5c
    bl      log_write_csv_token             @ 0801E670 call log_write_csv_token
    cmp     r0, #0                          @ 0801E674 compare r0 with 0
    beq     .Llog_write_minmax_rows_E67C    @ 0801E676 if (r0 == 0) goto 0x801E67C
    movs    r0, #1                          @ 0801E678 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E67A goto 0x801E73E
.Llog_write_minmax_rows_E67C:           @ v2.05 0x0801E67C, reached from 0x0801E676
    ldr     r0, =log_min_row                @ 0801E67C r0 = &log_min_row
    ldr     r0, [r0]                        @ 0801E67E r0 = u32 [log_min_row]
    bl      log_write_label                 @ 0801E680 call log_write_label
    cmp     r0, #0                          @ 0801E684 compare r0 with 0
    beq     .Llog_write_minmax_rows_E68C    @ 0801E686 if (r0 == 0) goto 0x801E68C
    movs    r0, #1                          @ 0801E688 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E68A goto 0x801E73E
.Llog_write_minmax_rows_E68C:           @ v2.05 0x0801E68C, reached from 0x0801E686
    ldr     r0, =log_view_mode1             @ 0801E68C r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801E68E r0 = u8 [log_view_mode1]
    bl      log_write_func_name             @ 0801E690 call log_write_func_name
    cmp     r0, #0                          @ 0801E694 compare r0 with 0
    beq     .Llog_write_minmax_rows_E69C    @ 0801E696 if (r0 == 0) goto 0x801E69C
    movs    r0, #1                          @ 0801E698 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E69A goto 0x801E73E
.Llog_write_minmax_rows_E69C:           @ v2.05 0x0801E69C, reached from 0x0801E696
    ldr     r0, =log_min_flags              @ 0801E69C r0 = &log_min_flags
    ldrb    r0, [r0]                        @ 0801E69E r0 = u8 [log_min_flags]
    lsls    r0, r0, #0x18                   @ 0801E6A0 r0 = r0 << 0x18
    bpl     .Llog_write_minmax_rows_E6D0    @ 0801E6A2 if (r0 >=0 0) goto 0x801E6D0
    ldr     r0, =log_min_flags              @ 0801E6A4 r0 = &log_min_flags
    ldrb    r0, [r0]                        @ 0801E6A6 r0 = u8 [log_min_flags]
    lsls    r0, r0, #0x19                   @ 0801E6A8 r0 = r0 << 0x19
    bpl     .Llog_write_minmax_rows_E6BE    @ 0801E6AA if (r0 >=0 0) goto 0x801E6BE
    movs    r2, #0                          @ 0801E6AC r2 = 0
    movs    r1, #0                          @ 0801E6AE r1 = 0
    movs    r0, #2                          @ 0801E6B0 r0 = 2
    bl      log_write_csv_token             @ 0801E6B2 call log_write_csv_token
    cmp     r0, #0                          @ 0801E6B6 compare r0 with 0
    beq     .Llog_write_minmax_rows_E702    @ 0801E6B8 if (r0 == 0) goto 0x801E702
    movs    r0, #1                          @ 0801E6BA r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E6BC goto 0x801E73E
.Llog_write_minmax_rows_E6BE:           @ v2.05 0x0801E6BE, reached from 0x0801E6AA
    movs    r2, #0                          @ 0801E6BE r2 = 0
    movs    r1, #0                          @ 0801E6C0 r1 = 0
    movs    r0, #3                          @ 0801E6C2 r0 = 3
    bl      log_write_csv_token             @ 0801E6C4 call log_write_csv_token
    cmp     r0, #0                          @ 0801E6C8 compare r0 with 0
    beq     .Llog_write_minmax_rows_E702    @ 0801E6CA if (r0 == 0) goto 0x801E702
    movs    r0, #1                          @ 0801E6CC r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E6CE goto 0x801E73E
.Llog_write_minmax_rows_E6D0:           @ v2.05 0x0801E6D0, reached from 0x0801E6A2
    ldr     r0, =log_min_flags              @ 0801E6D0 r0 = &log_min_flags
    ldrb    r0, [r0]                        @ 0801E6D2 r0 = u8 [log_min_flags]
    lsls    r0, r0, #0x19                   @ 0801E6D4 r0 = r0 << 0x19
    bpl     .Llog_write_minmax_rows_E6EA    @ 0801E6D6 if (r0 >=0 0) goto 0x801E6EA
    movs    r2, #0                          @ 0801E6D8 r2 = 0
    movs    r1, #0                          @ 0801E6DA r1 = 0
    movs    r0, #4                          @ 0801E6DC r0 = 4
    bl      log_write_csv_token             @ 0801E6DE call log_write_csv_token
    cmp     r0, #0                          @ 0801E6E2 compare r0 with 0
    beq     .Llog_write_minmax_rows_E6EA    @ 0801E6E4 if (r0 == 0) goto 0x801E6EA
    movs    r0, #1                          @ 0801E6E6 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E6E8 goto 0x801E73E
.Llog_write_minmax_rows_E6EA:           @ v2.05 0x0801E6EA, reached from 0x0801E6D6, 0x0801E6E4
    ldr     r0, =log_min_value              @ 0801E6EA r0 = &log_min_value
    ldr     r2, [r0]                        @ 0801E6EC r2 = u32 [log_min_value]
    ldr     r0, =log_view_range1            @ 0801E6EE r0 = &log_view_range1
    ldrb    r1, [r0]                        @ 0801E6F0 r1 = u8 [log_view_range1]
    ldr     r0, =log_view_mode1             @ 0801E6F2 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801E6F4 r0 = u8 [log_view_mode1]
    bl      log_write_value                 @ 0801E6F6 call log_write_value
    cmp     r0, #0                          @ 0801E6FA compare r0 with 0
    beq     .Llog_write_minmax_rows_E702    @ 0801E6FC if (r0 == 0) goto 0x801E702
    movs    r0, #1                          @ 0801E6FE r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E700 goto 0x801E73E
.Llog_write_minmax_rows_E702:           @ v2.05 0x0801E702, reached from 0x0801E6B8, 0x0801E6CA, 0x0801E6FC
    movs    r2, #0                          @ 0801E702 r2 = 0
    movs    r1, #0                          @ 0801E704 r1 = 0
    movs    r0, #0                          @ 0801E706 r0 = 0
    bl      log_write_csv_token             @ 0801E708 call log_write_csv_token
    cmp     r0, #0                          @ 0801E70C compare r0 with 0
    beq     .Llog_write_minmax_rows_E714    @ 0801E70E if (r0 == 0) goto 0x801E714
    movs    r0, #1                          @ 0801E710 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E712 goto 0x801E73E
.Llog_write_minmax_rows_E714:           @ v2.05 0x0801E714, reached from 0x0801E70E
    ldr     r0, =log_view_range1            @ 0801E714 r0 = &log_view_range1
    ldrb    r1, [r0]                        @ 0801E716 r1 = u8 [log_view_range1]
    ldr     r0, =log_view_mode1             @ 0801E718 r0 = &log_view_mode1
    ldrb    r0, [r0]                        @ 0801E71A r0 = u8 [log_view_mode1]
    bl      log_write_unit                  @ 0801E71C call log_write_unit
    cmp     r0, #0                          @ 0801E720 compare r0 with 0
    beq     .Llog_write_minmax_rows_E728    @ 0801E722 if (r0 == 0) goto 0x801E728
    movs    r0, #1                          @ 0801E724 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E726 goto 0x801E73E
.Llog_write_minmax_rows_E728:           @ v2.05 0x0801E728, reached from 0x0801E722
    ldr     r0, =log_min_time                @ production: "YYYY/MM/DD,hh:mm:ss," of the minimum row (log/mmtime.s)
    bl      log_mm_write
    cmp     r0, #0
    bne     .Llog_write_minmax_rows_E73E    @ r0 = 1: a write failed
    movs    r2, #0                          @ 0801E728 r2 = 0
    movs    r1, #0                          @ 0801E72A r1 = 0
    movs    r0, #1                          @ 0801E72C r0 = 1
    bl      log_write_csv_token             @ 0801E72E call log_write_csv_token
    cmp     r0, #0                          @ 0801E732 compare r0 with 0
    beq     .Llog_write_minmax_rows_E73A    @ 0801E734 if (r0 == 0) goto 0x801E73A
    movs    r0, #1                          @ 0801E736 r0 = 1
    b       .Llog_write_minmax_rows_E73E    @ 0801E738 goto 0x801E73E
.Llog_write_minmax_rows_E73A:           @ v2.05 0x0801E73A, reached from 0x0801E734
    movs    r0, r4                          @ 0801E73A r0 = r4
    uxtb    r0, r0                          @ 0801E73C r0 = u8(r0)
.Llog_write_minmax_rows_E73E:           @ v2.05 0x0801E73E, reached from 0x0801E592, 0x0801E5A2, 0x0801E5B2, 0x0801E5D4, 0x0801E5E6, 0x0801E600, 0x0801E618, 0x0801E62A, 0x0801E63E, 0x0801E650, 0x0801E67A, 0x0801E68A, 0x0801E69A, 0x0801E6BC, 0x0801E6CE, 0x0801E6E8, 0x0801E700, 0x0801E712, 0x0801E726, 0x0801E738
    pop     {r1, r4, r5, pc}                @ 0801E73E pop {r1, r4, r5, pc}
ENDFUNC log_write_minmax_rows
    .ltorg

@ -----------------------------------------------------------------------------
@ log_header_line_interval - write the line "INTERVAL,nnn,sec,"
@ Replaces  : 0x0801E7A8 FUN_0801E7A8 (v2.05), called by log_write_header
@ In        : -
@ Out       : r0 = 0 ok, 1 a write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E7A8..0x0801E7F9 (tokens 7, 0x65, 8, 1)
@ -----------------------------------------------------------------------------
FUNC log_header_line_interval
    push    {r4, lr}                        @ 0801E7A8 push {r4, lr}
    movs    r4, #0                          @ 0801E7AA r4 = 0
    movs    r2, #0                          @ 0801E7AC r2 = 0
    movs    r1, #0                          @ 0801E7AE r1 = 0
    movs    r0, #7                          @ 0801E7B0 r0 = 7
    bl      log_write_csv_token             @ 0801E7B2 call log_write_csv_token
    cmp     r0, #0                          @ 0801E7B6 compare r0 with 0
    beq     .Llog_header_line_interval_E7BE @ 0801E7B8 if (r0 == 0) goto 0x801E7BE
    movs    r0, #1                          @ 0801E7BA r0 = 1
    b       .Llog_header_line_interval_E7F8 @ 0801E7BC goto 0x801E7F8
.Llog_header_line_interval_E7BE:        @ v2.05 0x0801E7BE, reached from 0x0801E7B8
    movs    r2, #0                          @ 0801E7BE r2 = 0
    movs    r1, #0                          @ 0801E7C0 r1 = 0
    movs    r0, #0x65                       @ 0801E7C2 r0 = 0x65
    bl      log_write_csv_token             @ 0801E7C4 call log_write_csv_token
    cmp     r0, #0                          @ 0801E7C8 compare r0 with 0
    beq     .Llog_header_line_interval_E7D0 @ 0801E7CA if (r0 == 0) goto 0x801E7D0
    movs    r0, #1                          @ 0801E7CC r0 = 1
    b       .Llog_header_line_interval_E7F8 @ 0801E7CE goto 0x801E7F8
.Llog_header_line_interval_E7D0:        @ v2.05 0x0801E7D0, reached from 0x0801E7CA
    movs    r2, #0                          @ 0801E7D0 r2 = 0
    movs    r1, #0                          @ 0801E7D2 r1 = 0
    movs    r0, #8                          @ 0801E7D4 r0 = 8
    bl      log_write_csv_token             @ 0801E7D6 call log_write_csv_token
    cmp     r0, #0                          @ 0801E7DA compare r0 with 0
    beq     .Llog_header_line_interval_E7E2 @ 0801E7DC if (r0 == 0) goto 0x801E7E2
    movs    r0, #1                          @ 0801E7DE r0 = 1
    b       .Llog_header_line_interval_E7F8 @ 0801E7E0 goto 0x801E7F8
.Llog_header_line_interval_E7E2:        @ v2.05 0x0801E7E2, reached from 0x0801E7DC
    movs    r2, #0                          @ 0801E7E2 r2 = 0
    movs    r1, #0                          @ 0801E7E4 r1 = 0
    movs    r0, #1                          @ 0801E7E6 r0 = 1
    bl      log_write_csv_token             @ 0801E7E8 call log_write_csv_token
    cmp     r0, #0                          @ 0801E7EC compare r0 with 0
    beq     .Llog_header_line_interval_E7F4 @ 0801E7EE if (r0 == 0) goto 0x801E7F4
    movs    r0, #1                          @ 0801E7F0 r0 = 1
    b       .Llog_header_line_interval_E7F8 @ 0801E7F2 goto 0x801E7F8
.Llog_header_line_interval_E7F4:        @ v2.05 0x0801E7F4, reached from 0x0801E7EE
    movs    r0, r4                          @ 0801E7F4 r0 = r4
    uxtb    r0, r0                          @ 0801E7F6 r0 = u8(r0)
.Llog_header_line_interval_E7F8:        @ v2.05 0x0801E7F8, reached from 0x0801E7BC, 0x0801E7CE, 0x0801E7E0, 0x0801E7F2
    pop     {r4, pc}                        @ 0801E7F8 pop {r4, pc}
ENDFUNC log_header_line_interval
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_value - write a number with the decimal places of (mode r0, range r1)
@ Replaces  : 0x0801E7FA FUN_0801E7FA (v2.05), called by log_write_row and log_write_minmax_rows
@ In        : r0 = mode (u8), r1 = range (u8), r2 = magnitude (u32)
@ Out       : r0 = 0 ok, 1 write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E7FA..0x0801E82D (decimal_position_for_mode_range of MODE, then token 0xC8)
@ -----------------------------------------------------------------------------
FUNC log_write_value
    push.w  {r4, r5, r6, r7, r8, lr}        @ 0801E7FA push {r4, r5, r6, r7, r8, lr}
    movs    r4, r0                          @ 0801E7FE r4 = r0
    movs    r5, r1                          @ 0801E800 r5 = r1
    movs    r6, r2                          @ 0801E802 r6 = r2
    movs    r7, #0                          @ 0801E804 r7 = 0
    movs.w  r8, #0                          @ 0801E806 r8 = 0
    movs    r1, r5                          @ 0801E80A r1 = r5
    uxtb    r1, r1                          @ 0801E80C r1 = u8(r1)
    movs    r0, r4                          @ 0801E80E r0 = r4
    uxtb    r0, r0                          @ 0801E810 r0 = u8(r0)
    bl      decimal_position_for_mode_range @ 0801E812 call decimal_position_for_mode_range
    mov     r8, r0                          @ 0801E816 r8 = r0
    mov     r2, r8                          @ 0801E818 r2 = r8
    uxtb    r2, r2                          @ 0801E81A r2 = u8(r2)
    movs    r1, r6                          @ 0801E81C r1 = r6
    movs    r0, #0xc8                       @ 0801E81E r0 = 0xc8
    bl      log_write_csv_token             @ 0801E820 call log_write_csv_token
    movs    r7, r0                          @ 0801E824 r7 = r0
    movs    r0, r7                          @ 0801E826 r0 = r7
    uxtb    r0, r0                          @ 0801E828 r0 = u8(r0)
    pop.w   {r4, r5, r6, r7, r8, pc}        @ 0801E82A pop {r4, r5, r6, r7, r8, pc}
ENDFUNC log_write_value
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_csv_token - append one CSV token to the log file
@ Replaces : 0x0801E82E log_write_csv_token (v2.05)
@ In       : r0 = token (u16), r1 = value for tokens 0x64 and 0xC8, r2 = decimal places for token 0xC8
@ Out      : r0 = 0 written (or token unknown: nothing written), 1 write failed
@ Clobbers : r1-r3, r12, flags (AAPCS); r4-r10 preserved
@ Context  : main only
@ RAM      : reads the CSV strings of the RAM data image 0x20000020..0x20000234 (initial values, DESIGN.md 5.1)
@            and, for the dynamic tokens, the date/time variables named at each block
@ Spec     : v2.05 listing 0x0801E82E..0x0801F49D; the CSV format is the product of this file
@ Deviation: OPT-06 (DESIGN.md 11).  v2.05 tests the token against 78 constants one after the other and
@            repeats strlen + log_write_bytes in every case (3184 bytes).  Tokens 0x00..0x5C that name a string
@            (the ladder 0x0801E840..0x0801E9FA) are looked up in log_token_strings; the eight dynamic tokens
@            0x64 0x65 0x66 0x67 0x68 0x6E 0x6F 0xC8 keep their v2.05 code (0x0801F2B8..0x0801F49B).  Every
@            token value 0..0xFFFF gives the same bytes in the file as v2.05 (exhaustive routine test).
@ Token map: see the comments of log_token_strings
@ -----------------------------------------------------------------------------
FUNC log_write_csv_token
    push.w  {r4, r5, r6, r7, r8, r9, r10, lr}
    sub     sp, #0x18                       @ locals of the dynamic tokens (v2.05 0x0801E832)
    movs    r4, r0
    movs    r5, r1                          @ r5 = value (tokens 0x64, 0xC8)
    movs    r6, r2                          @ r6 = decimal places (token 0xC8)
    movs    r7, #0                          @ r7 = 0: result "written" (v2.05 0x0801E83A)
    uxth    r4, r4                          @ r4 = token as u16 (v2.05 0x0801E83C)
    cmp     r4, #93
    bhs     .Llcsv_dynamic                  @ above the string table: the dynamic tokens
    ldr     r1, =log_token_strings
    ldr.w   r8, [r1, r4, lsl #2]            @ r8 = pointer to the zero-terminated string, 0 = no such token
    cmp     r8, #0
    beq     .Llcsv_ok                       @ unknown token: nothing is written, result 0 (as v2.05)
    mov     r0, r8
    bl      fn_08023CA0                     @ strlen (RT)
    movs    r1, r0
    uxth    r1, r1                          @ length as u16
    mov     r0, r8
    bl      log_write_bytes                 @ append to the file buffer and f_write; r0 = 0 ok, 1 failed
    cmp     r0, #0
    beq     .Llcsv_ok
    movs    r0, #1                          @ write failed
    b       .Llcsv_ret
.Llcsv_dynamic:
    @ dynamic tokens (v2.05 ladder 0x0801E9FE..0x0801EA1A compares r0 with each of them)
    cmp     r4, #0x64
    beq     .Llog_write_csv_token_F2B8
    cmp     r4, #0x65
    beq     .Llog_write_csv_token_F2DA
    cmp     r4, #0x66
    beq     .Llog_write_csv_token_F34A
    cmp     r4, #0x67
    beq     .Llog_write_csv_token_F36A
    cmp     r4, #0x68
    beq     .Llog_write_csv_token_F38A
    cmp     r4, #0x6E
    beq     .Llog_write_csv_token_F430
    cmp     r4, #0x6F
    beq     .Llog_write_csv_token_F450
    cmp     r4, #0xC8
    beq     .Llog_write_csv_token_F470
    b       .Llcsv_ok                       @ any other token above the table: nothing written
.Llog_write_csv_token_F2B8:
    movs    r0, r5                          @ 0801F2B8 r0 = r5
    bl      log_format_decimal              @ 0801F2BA call log_format_decimal
    mov     r8, r0                          @ 0801F2BE r8 = r0
    mov     r0, r8                          @ 0801F2C0 r0 = r8
    bl      fn_08023CA0                     @ 0801F2C2 call fn_08023CA0
    movs    r1, r0                          @ 0801F2C6 r1 = r0
    uxth    r1, r1                          @ 0801F2C8 r1 = u16(r1)
    mov     r0, r8                          @ 0801F2CA r0 = r8
    bl      log_write_bytes                 @ 0801F2CC call log_write_bytes
    cmp     r0, #0                          @ 0801F2D0 compare r0 with 0
    beq     .Llog_write_csv_token_F2D8      @ 0801F2D2 if (r0 == 0) goto 0x801F2D8
    movs    r0, #1                          @ 0801F2D4 r0 = 1
    b       .Llcsv_ret                      @ 0801F2D6 goto 0x801F498
.Llog_write_csv_token_F2D8:             @ v2.05 0x0801F2D8, reached from 0x0801F2D2
    b       .Llcsv_ok                       @ 0801F2D8 goto 0x801F494
.Llog_write_csv_token_F2DA:
    ldr.w   r0, =log_interval               @ 0801F2DA r0 = &log_interval
    ldrh    r0, [r0]                        @ 0801F2DE r0 = u16 [log_interval]
    mov     r9, r0                          @ 0801F2E0 r9 = r0
    uxth.w  r9, r9                          @ 0801F2E2 r9 = u16(r9)
    movs    r0, #0x64                       @ 0801F2E6 r0 = 0x64
    sdiv    r0, r9, r0                      @ 0801F2E8
    adds    r0, #0x30                       @ 0801F2EC r0 += 0x30
    strb.w  r0, [sp, #0xc]                  @ 0801F2EE u8 [sp+0xC] = r0
    uxth.w  r9, r9                          @ 0801F2F2 r9 = u16(r9)
    movs    r0, #0x64                       @ 0801F2F6 r0 = 0x64
    sdiv    r1, r9, r0                      @ 0801F2F8
    mls     r9, r0, r1, r9                  @ 0801F2FC
    uxth.w  r9, r9                          @ 0801F300 r9 = u16(r9)
    movs    r0, #0xa                        @ 0801F304 r0 = 0xa
    sdiv    r0, r9, r0                      @ 0801F306
    adds    r0, #0x30                       @ 0801F30A r0 += 0x30
    strb.w  r0, [sp, #0xd]                  @ 0801F30C u8 [sp+0xD] = r0
    uxth.w  r9, r9                          @ 0801F310 r9 = u16(r9)
    movs    r0, #0xa                        @ 0801F314 r0 = 0xa
    sdiv    r1, r9, r0                      @ 0801F316
    mls     r0, r0, r1, r9                  @ 0801F31A
    adds    r0, #0x30                       @ 0801F31E r0 += 0x30
    strb.w  r0, [sp, #0xe]                  @ 0801F320 u8 [sp+0xE] = r0
    movs    r0, #0x2c                       @ 0801F324 r0 = 0x2c
    strb.w  r0, [sp, #0xf]                  @ 0801F326 u8 [sp+0xF] = r0
    movs    r0, #0                          @ 0801F32A r0 = 0
    strb.w  r0, [sp, #0x10]                 @ 0801F32C u8 [sp+0x10] = r0
    add     r0, sp, #0xc                    @ 0801F330 r0 = sp + 0xc
    bl      fn_08023CA0                     @ 0801F332 call fn_08023CA0
    movs    r1, r0                          @ 0801F336 r1 = r0
    uxth    r1, r1                          @ 0801F338 r1 = u16(r1)
    add     r0, sp, #0xc                    @ 0801F33A r0 = sp + 0xc
    bl      log_write_bytes                 @ 0801F33C call log_write_bytes
    cmp     r0, #0                          @ 0801F340 compare r0 with 0
    beq     .Llog_write_csv_token_F348      @ 0801F342 if (r0 == 0) goto 0x801F348
    movs    r0, #1                          @ 0801F344 r0 = 1
    b       .Llcsv_ret                      @ 0801F346 goto 0x801F498
.Llog_write_csv_token_F348:             @ v2.05 0x0801F348, reached from 0x0801F342
    b       .Llcsv_ok                       @ 0801F348 goto 0x801F494
.Llog_write_csv_token_F34A:
    ldr.w   r0, =log_start_day              @ 0801F34A r0 = &log_start_day
    ldrb    r2, [r0]                        @ 0801F34E r2 = u8 [log_start_day]
    ldr.w   r0, =log_start_month            @ 0801F350 r0 = &log_start_month
    ldrb    r1, [r0]                        @ 0801F354 r1 = u8 [log_start_month]
    ldr.w   r0, =log_start_year             @ 0801F356 r0 = &log_start_year
    ldrb    r0, [r0]                        @ 0801F35A r0 = u8 [log_start_year]
    bl      log_write_date                  @ 0801F35C call log_write_date
    cmp     r0, #0                          @ 0801F360 compare r0 with 0
    beq     .Llog_write_csv_token_F368      @ 0801F362 if (r0 == 0) goto 0x801F368
    movs    r0, #1                          @ 0801F364 r0 = 1
    b       .Llcsv_ret                      @ 0801F366 goto 0x801F498
.Llog_write_csv_token_F368:             @ v2.05 0x0801F368, reached from 0x0801F362
    b       .Llcsv_ok                       @ 0801F368 goto 0x801F494
.Llog_write_csv_token_F36A:
    ldr.w   r0, =log_start_second           @ 0801F36A r0 = &log_start_second
    ldrb    r2, [r0]                        @ 0801F36E r2 = u8 [log_start_second]
    ldr.w   r0, =log_start_minute           @ 0801F370 r0 = &log_start_minute
    ldrb    r1, [r0]                        @ 0801F374 r1 = u8 [log_start_minute]
    ldr.w   r0, =log_start_hour             @ 0801F376 r0 = &log_start_hour
    ldrb    r0, [r0]                        @ 0801F37A r0 = u8 [log_start_hour]
    bl      log_write_time                  @ 0801F37C call log_write_time
    cmp     r0, #0                          @ 0801F380 compare r0 with 0
    beq     .Llog_write_csv_token_F388      @ 0801F382 if (r0 == 0) goto 0x801F388
    movs    r0, #1                          @ 0801F384 r0 = 1
    b       .Llcsv_ret                      @ 0801F386 goto 0x801F498
.Llog_write_csv_token_F388:             @ v2.05 0x0801F388, reached from 0x0801F382
    b       .Llcsv_ok                       @ 0801F388 goto 0x801F494
.Llog_write_csv_token_F38A:
    ldr.w   r0, =rtc_date_code              @ 0801F38A r0 = &rtc_date_code
    ldrh    r0, [r0]                        @ 0801F38E r0 = u16 [rtc_date_code]
    bl      fn_0801B090                     @ 0801F390 call fn_0801B090
    ldr.w   r0, =v_20007DB4                 @ 0801F394 r0 = &v_20007DB4
    ldr     r0, [r0]                        @ 0801F398 r0 = u32 [v_20007DB4]
    adds    r0, #0x30                       @ 0801F39A r0 += 0x30
    strb.w  r0, [sp]                        @ 0801F39C u8 [sp] = r0
    ldr.w   r0, =v_20007DB8                 @ 0801F3A0 r0 = &v_20007DB8
    ldr     r0, [r0]                        @ 0801F3A4 r0 = u32 [v_20007DB8]
    adds    r0, #0x30                       @ 0801F3A6 r0 += 0x30
    strb.w  r0, [sp, #1]                    @ 0801F3A8 u8 [sp+0x1] = r0
    ldr.w   r0, =v_20007DBC                 @ 0801F3AC r0 = &v_20007DBC
    ldr     r0, [r0]                        @ 0801F3B0 r0 = u32 [v_20007DBC]
    adds    r0, #0x30                       @ 0801F3B2 r0 += 0x30
    strb.w  r0, [sp, #2]                    @ 0801F3B4 u8 [sp+0x2] = r0
    ldr.w   r0, =v_20007DC0                 @ 0801F3B8 r0 = &v_20007DC0
    ldr     r0, [r0]                        @ 0801F3BC r0 = u32 [v_20007DC0]
    adds    r0, #0x30                       @ 0801F3BE r0 += 0x30
    strb.w  r0, [sp, #3]                    @ 0801F3C0 u8 [sp+0x3] = r0
    ldr.w   r0, =sys_id_number              @ 0801F3C4 r0 = &sys_id_number
    ldr     r0, [r0]                        @ 0801F3C8 r0 = u32 [sys_id_number]
    bl      fn_0801B090                     @ 0801F3CA call fn_0801B090
    ldr.w   r0, =v_20007DB0                 @ 0801F3CE r0 = &v_20007DB0
    ldr     r0, [r0]                        @ 0801F3D2 r0 = u32 [v_20007DB0]
    adds    r0, #0x30                       @ 0801F3D4 r0 += 0x30
    strb.w  r0, [sp, #4]                    @ 0801F3D6 u8 [sp+0x4] = r0
    ldr.w   r0, =v_20007DB4                 @ 0801F3DA r0 = &v_20007DB4
    ldr     r0, [r0]                        @ 0801F3DE r0 = u32 [v_20007DB4]
    adds    r0, #0x30                       @ 0801F3E0 r0 += 0x30
    strb.w  r0, [sp, #5]                    @ 0801F3E2 u8 [sp+0x5] = r0
    ldr.w   r0, =v_20007DB8                 @ 0801F3E6 r0 = &v_20007DB8
    ldr     r0, [r0]                        @ 0801F3EA r0 = u32 [v_20007DB8]
    adds    r0, #0x30                       @ 0801F3EC r0 += 0x30
    strb.w  r0, [sp, #6]                    @ 0801F3EE u8 [sp+0x6] = r0
    ldr.w   r0, =v_20007DBC                 @ 0801F3F2 r0 = &v_20007DBC
    ldr     r0, [r0]                        @ 0801F3F6 r0 = u32 [v_20007DBC]
    adds    r0, #0x30                       @ 0801F3F8 r0 += 0x30
    strb.w  r0, [sp, #7]                    @ 0801F3FA u8 [sp+0x7] = r0
    ldr.w   r0, =v_20007DC0                 @ 0801F3FE r0 = &v_20007DC0
    ldr     r0, [r0]                        @ 0801F402 r0 = u32 [v_20007DC0]
    adds    r0, #0x30                       @ 0801F404 r0 += 0x30
    strb.w  r0, [sp, #8]                    @ 0801F406 u8 [sp+0x8] = r0
    movs    r0, #0x2c                       @ 0801F40A r0 = 0x2c
    strb.w  r0, [sp, #9]                    @ 0801F40C u8 [sp+0x9] = r0
    movs    r0, #0                          @ 0801F410 r0 = 0
    strb.w  r0, [sp, #0xa]                  @ 0801F412 u8 [sp+0xA] = r0
    mov     r0, sp                          @ 0801F416 r0 = sp
    bl      fn_08023CA0                     @ 0801F418 call fn_08023CA0
    movs    r1, r0                          @ 0801F41C r1 = r0
    uxth    r1, r1                          @ 0801F41E r1 = u16(r1)
    mov     r0, sp                          @ 0801F420 r0 = sp
    bl      log_write_bytes                 @ 0801F422 call log_write_bytes
    cmp     r0, #0                          @ 0801F426 compare r0 with 0
    beq     .Llog_write_csv_token_F42E      @ 0801F428 if (r0 == 0) goto 0x801F42E
    movs    r0, #1                          @ 0801F42A r0 = 1
    b       .Llcsv_ret                      @ 0801F42C goto 0x801F498
.Llog_write_csv_token_F42E:             @ v2.05 0x0801F42E, reached from 0x0801F428
    b       .Llcsv_ok                       @ 0801F42E goto 0x801F494
.Llog_write_csv_token_F430:
    ldr.w   r0, =log_view_day               @ 0801F430 r0 = &log_view_day
    ldrb    r2, [r0]                        @ 0801F434 r2 = u8 [log_view_day]
    ldr.w   r0, =log_view_month             @ 0801F436 r0 = &log_view_month
    ldrb    r1, [r0]                        @ 0801F43A r1 = u8 [log_view_month]
    ldr.w   r0, =log_view_year              @ 0801F43C r0 = &log_view_year
    ldrb    r0, [r0]                        @ 0801F440 r0 = u8 [log_view_year]
    bl      log_write_date                  @ 0801F442 call log_write_date
    cmp     r0, #0                          @ 0801F446 compare r0 with 0
    beq     .Llog_write_csv_token_F44E      @ 0801F448 if (r0 == 0) goto 0x801F44E
    movs    r0, #1                          @ 0801F44A r0 = 1
    b       .Llcsv_ret                      @ 0801F44C goto 0x801F498
.Llog_write_csv_token_F44E:             @ v2.05 0x0801F44E, reached from 0x0801F448
    b       .Llcsv_ok                       @ 0801F44E goto 0x801F494
.Llog_write_csv_token_F450:
    ldr.w   r0, =log_view_second            @ 0801F450 r0 = &log_view_second
    ldrb    r2, [r0]                        @ 0801F454 r2 = u8 [log_view_second]
    ldr.w   r0, =log_view_minute            @ 0801F456 r0 = &log_view_minute
    ldrb    r1, [r0]                        @ 0801F45A r1 = u8 [log_view_minute]
    ldr.w   r0, =log_view_hour              @ 0801F45C r0 = &log_view_hour
    ldrb    r0, [r0]                        @ 0801F460 r0 = u8 [log_view_hour]
    bl      log_write_time                  @ 0801F462 call log_write_time
    cmp     r0, #0                          @ 0801F466 compare r0 with 0
    beq     .Llog_write_csv_token_F46E      @ 0801F468 if (r0 == 0) goto 0x801F46E
    movs    r0, #1                          @ 0801F46A r0 = 1
    b       .Llcsv_ret                      @ 0801F46C goto 0x801F498
.Llog_write_csv_token_F46E:             @ v2.05 0x0801F46E, reached from 0x0801F468
    b       .Llcsv_ok                       @ 0801F46E goto 0x801F494
.Llog_write_csv_token_F470:
    movs    r1, r6                          @ 0801F470 r1 = r6
    uxtb    r1, r1                          @ 0801F472 r1 = u8(r1)
    movs    r0, r5                          @ 0801F474 r0 = r5
    bl      log_format_fixed                @ 0801F476 call log_format_fixed
    mov     r10, r0                         @ 0801F47A r10 = r0
    mov     r0, r10                         @ 0801F47C r0 = r10
    bl      fn_08023CA0                     @ 0801F47E call fn_08023CA0
    movs    r1, r0                          @ 0801F482 r1 = r0
    uxth    r1, r1                          @ 0801F484 r1 = u16(r1)
    mov     r0, r10                         @ 0801F486 r0 = r10
    bl      log_write_bytes                 @ 0801F488 call log_write_bytes
    cmp     r0, #0                          @ 0801F48C compare r0 with 0
    beq     .Llcsv_ok                       @ 0801F48E if (r0 == 0) goto 0x801F494
    movs    r0, #1                          @ 0801F490 r0 = 1
    b       .Llcsv_ret                      @ 0801F492 goto 0x801F498
.Llcsv_ok:
    movs    r0, r7
    uxtb    r0, r0                          @ result 0
.Llcsv_ret:
    add     sp, #0x18
    pop.w   {r4, r5, r6, r7, r8, r9, r10, pc}
    .ltorg
ENDFUNC log_write_csv_token

    .pushsection .rodata.log, "a", %progbits
    .balign 4
@ log_token_strings - pointer to the zero-terminated CSV string of each token 0x00..0x5C (0 = not a token).
@ The strings live in the RAM data image (initial values of ram_init.txt, DESIGN.md 5.1); the pointer values
@ are the literals of the v2.05 ladder 0x0801E840..0x0801E9FA.
log_token_strings:
    .word 0x20000232                      @ 0x00 ","
    .word 0x20000020                      @ 0x01 "\r\n"
    .word 0x20000050                      @ 0x02 "-Overflow"
    .word 0x20000044                      @ 0x03 "Overflow"
    .word 0x20000234                      @ 0x04 "-"
    .word 0x20000028                      @ 0x05 "START,"
    .word 0x20000024                      @ 0x06 "ID,"
    .word 0x20000030                      @ 0x07 "INTERVAL,"
    .word 0x2000003C                      @ 0x08 "sec,"
    .word 0                               @ 0x09 none
    .word 0                               @ 0x0A none
    .word 0x2000006C                      @ 0x0B ",,,MAIN,,,"
    .word 0x20000078                      @ 0x0C "SUB-1,,,"
    .word 0x20000084                      @ 0x0D "SUB-2,,,"
    .word 0x20000090                      @ 0x0E "Remark,"
    .word 0x20000098                      @ 0x0F "No. ,"
    .word 0x200000B8                      @ 0x10 "Func. ,"
    .word 0x200000C0                      @ 0x11 "Value,"
    .word 0x200000C8                      @ 0x12 "Unit,"
    .word 0x200000A0                      @ 0x13 "Date      ,"
    .word 0x200000AC                      @ 0x14 "Time    ,"
    .word 0x200000D0                      @ 0x15 "LowZ,"
    .word 0x200000E0                      @ 0x16 "DCV,"
    .word 0x200000D8                      @ 0x17 "ACV,"
    .word 0x200000E8                      @ 0x18 "DCmV,"
    .word 0x200000F0                      @ 0x19 "ACmV,"
    .word 0x200000F8                      @ 0x1A "TEMP.,"
    .word 0x20000100                      @ 0x1B "FREQ.,"
    .word 0x20000108                      @ 0x1C "PULSE,"
    .word 0x20000110                      @ 0x1D "DUTY,"
    .word 0x20000118                      @ 0x1E "OHM,"
    .word 0x20000120                      @ 0x1F "BEEP,"
    .word 0x20000128                      @ 0x20 "DIODE,"
    .word 0x20000130                      @ 0x21 "CAP.,"
    .word 0x20000138                      @ 0x22 "uVA,"
    .word 0x20000140                      @ 0x23 "mVA,"
    .word 0x20000148                      @ 0x24 "VA,"
    .word 0x2000014C                      @ 0x25 "ACuA,"
    .word 0x20000154                      @ 0x26 "DCuA,"
    .word 0x2000015C                      @ 0x27 "ACmA,"
    .word 0x20000164                      @ 0x28 "DCmA,"
    .word 0x2000016C                      @ 0x29 "ACA,"
    .word 0x20000174                      @ 0x2A "DCA,"
    .word 0x2000017C                      @ 0x2B "DCuVA,"
    .word 0x20000184                      @ 0x2C "DCmVA,"
    .word 0x2000018C                      @ 0x2D "DCVA,"
    .word 0x20000194                      @ 0x2E "Burden,"
    .word 0                               @ 0x2F none
    .word 0                               @ 0x30 none
    .word 0                               @ 0x31 none
    .word 0                               @ 0x32 none
    .word 0x200000D8                      @ 0x33 "ACV,"
    .word 0x200000E0                      @ 0x34 "DCV,"
    .word 0x200001A0                      @ 0x35 "V,"
    .word 0x2000019C                      @ 0x36 "mV,"
    .word 0x200001B0                      @ 0x37 "'C,"
    .word 0x200001B4                      @ 0x38 "'F,"
    .word 0x200001B8                      @ 0x39 "Hz,"
    .word 0x200001BC                      @ 0x3A "KHz,"
    .word 0x200001C4                      @ 0x3B "mSec,"
    .word 0x200001CC                      @ 0x3C "%,"
    .word 0x200001D0                      @ 0x3D "ohm,"
    .word 0x200001D8                      @ 0x3E "Kohm,"
    .word 0x200001E0                      @ 0x3F "Mohm,"
    .word 0x200001E8                      @ 0x40 "nF,"
    .word 0x200001EC                      @ 0x41 "uF,"
    .word 0x20000138                      @ 0x42 "uVA,"
    .word 0x20000140                      @ 0x43 "mVA,"
    .word 0x20000148                      @ 0x44 "VA,"
    .word 0x200001A4                      @ 0x45 "uA,"
    .word 0x200001A8                      @ 0x46 "mA,"
    .word 0x200001AC                      @ 0x47 "A,"
    .word 0                               @ 0x48 none
    .word 0                               @ 0x49 none
    .word 0                               @ 0x4A none
    .word 0                               @ 0x4B none
    .word 0                               @ 0x4C none
    .word 0                               @ 0x4D none
    .word 0                               @ 0x4E none
    .word 0                               @ 0x4F none
    .word 0                               @ 0x50 none
    .word 0x200001F8                      @ 0x51 "PeakHold"
    .word 0x200001F0                      @ 0x52 "1KHz"
    .word 0x20000204                      @ 0x53 "ACDC"
    .word 0                               @ 0x54 none
    .word 0                               @ 0x55 none
    .word 0                               @ 0x56 none
    .word 0                               @ 0x57 none
    .word 0                               @ 0x58 none
    .word 0                               @ 0x59 none
    .word 0                               @ 0x5A none
    .word 0x2000005C                      @ 0x5B "MAX,"
    .word 0x20000064                      @ 0x5C "MIN,"
    .size log_token_strings, . - log_token_strings
    .popsection

@ -----------------------------------------------------------------------------
@ log_write_time - write "hh:mm:ss," from three byte values
@ Replaces  : 0x0801F4B8 FUN_0801F4B8 (v2.05), called by log_write_csv_token (tokens 0x67 and 0x6F)
@ In        : r0 = hours, r1 = minutes, r2 = seconds (u8 each)
@ Out       : r0 = 0 ok, 1 write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801F4B8..0x0801F557
@ Note      : two digits per field by division with 10 (sdiv) and mls; the text is built on the stack and written with log_write_bytes.
@ -----------------------------------------------------------------------------
FUNC log_write_time
    push    {r1, r2, r3, r4, r5, r6, r7, lr}@ 0801F4B8 push {r1, r2, r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 0801F4BA r4 = r0
    movs    r5, r1                          @ 0801F4BC r5 = r1
    movs    r6, r2                          @ 0801F4BE r6 = r2
    movs    r7, #0                          @ 0801F4C0 r7 = 0
    uxtb    r4, r4                          @ 0801F4C2 r4 = u8(r4)
    movs    r0, #0xa                        @ 0801F4C4 r0 = 0xa
    sdiv    r0, r4, r0                      @ 0801F4C6
    adds    r0, #0x30                       @ 0801F4CA r0 += 0x30
    strb.w  r0, [sp]                        @ 0801F4CC u8 [sp] = r0
    uxtb    r4, r4                          @ 0801F4D0 r4 = u8(r4)
    movs    r0, #0xa                        @ 0801F4D2 r0 = 0xa
    sdiv    r1, r4, r0                      @ 0801F4D4
    mls     r0, r0, r1, r4                  @ 0801F4D8
    adds    r0, #0x30                       @ 0801F4DC r0 += 0x30
    strb.w  r0, [sp, #1]                    @ 0801F4DE u8 [sp+0x1] = r0
    movs    r0, #0x3a                       @ 0801F4E2 r0 = 0x3a
    strb.w  r0, [sp, #2]                    @ 0801F4E4 u8 [sp+0x2] = r0
    uxtb    r5, r5                          @ 0801F4E8 r5 = u8(r5)
    movs    r0, #0xa                        @ 0801F4EA r0 = 0xa
    sdiv    r0, r5, r0                      @ 0801F4EC
    adds    r0, #0x30                       @ 0801F4F0 r0 += 0x30
    strb.w  r0, [sp, #3]                    @ 0801F4F2 u8 [sp+0x3] = r0
    uxtb    r5, r5                          @ 0801F4F6 r5 = u8(r5)
    movs    r0, #0xa                        @ 0801F4F8 r0 = 0xa
    sdiv    r1, r5, r0                      @ 0801F4FA
    mls     r0, r0, r1, r5                  @ 0801F4FE
    adds    r0, #0x30                       @ 0801F502 r0 += 0x30
    strb.w  r0, [sp, #4]                    @ 0801F504 u8 [sp+0x4] = r0
    movs    r0, #0x3a                       @ 0801F508 r0 = 0x3a
    strb.w  r0, [sp, #5]                    @ 0801F50A u8 [sp+0x5] = r0
    uxtb    r6, r6                          @ 0801F50E r6 = u8(r6)
    movs    r0, #0xa                        @ 0801F510 r0 = 0xa
    sdiv    r0, r6, r0                      @ 0801F512
    adds    r0, #0x30                       @ 0801F516 r0 += 0x30
    strb.w  r0, [sp, #6]                    @ 0801F518 u8 [sp+0x6] = r0
    uxtb    r6, r6                          @ 0801F51C r6 = u8(r6)
    movs    r0, #0xa                        @ 0801F51E r0 = 0xa
    sdiv    r1, r6, r0                      @ 0801F520
    mls     r0, r0, r1, r6                  @ 0801F524
    adds    r0, #0x30                       @ 0801F528 r0 += 0x30
    strb.w  r0, [sp, #7]                    @ 0801F52A u8 [sp+0x7] = r0
    movs    r0, #0x2c                       @ 0801F52E r0 = 0x2c
    strb.w  r0, [sp, #8]                    @ 0801F530 u8 [sp+0x8] = r0
    movs    r0, #0                          @ 0801F534 r0 = 0
    strb.w  r0, [sp, #9]                    @ 0801F536 u8 [sp+0x9] = r0
    mov     r0, sp                          @ 0801F53A r0 = sp
    bl      fn_08023CA0                     @ 0801F53C call fn_08023CA0
    movs    r1, r0                          @ 0801F540 r1 = r0
    uxth    r1, r1                          @ 0801F542 r1 = u16(r1)
    mov     r0, sp                          @ 0801F544 r0 = sp
    bl      log_write_bytes                 @ 0801F546 call log_write_bytes
    cmp     r0, #0                          @ 0801F54A compare r0 with 0
    beq     .Llog_write_time_F552           @ 0801F54C if (r0 == 0) goto 0x801F552
    movs    r0, #1                          @ 0801F54E r0 = 1
    movs    r7, r0                          @ 0801F550 r7 = r0
.Llog_write_time_F552:                  @ v2.05 0x0801F552, reached from 0x0801F54C
    movs    r0, r7                          @ 0801F552 r0 = r7
    uxtb    r0, r0                          @ 0801F554 r0 = u8(r0)
    pop     {r1, r2, r3, r4, r5, r6, r7, pc}@ 0801F556 pop {r1, r2, r3, r4, r5, r6, r7, pc}
ENDFUNC log_write_time
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_date - write "20yy/mm/dd," from three byte values
@ Replaces  : 0x0801F558 FUN_0801F558 (v2.05), called by log_write_csv_token (tokens 0x66 and 0x6E)
@ In        : r0 = year (years since 2000), r1 = month, r2 = day (u8 each)
@ Out       : r0 = 0 ok, 1 write failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801F558..0x0801F603
@ -----------------------------------------------------------------------------
FUNC log_write_date
    push    {r1, r2, r3, r4, r5, r6, r7, lr}@ 0801F558 push {r1, r2, r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 0801F55A r4 = r0
    movs    r5, r1                          @ 0801F55C r5 = r1
    movs    r6, r2                          @ 0801F55E r6 = r2
    movs    r7, #0                          @ 0801F560 r7 = 0
    movs    r0, #0x32                       @ 0801F562 r0 = 0x32
    strb.w  r0, [sp]                        @ 0801F564 u8 [sp] = r0
    movs    r0, #0x30                       @ 0801F568 r0 = 0x30
    strb.w  r0, [sp, #1]                    @ 0801F56A u8 [sp+0x1] = r0
    uxtb    r4, r4                          @ 0801F56E r4 = u8(r4)
    movs    r0, #0xa                        @ 0801F570 r0 = 0xa
    sdiv    r0, r4, r0                      @ 0801F572
    adds    r0, #0x30                       @ 0801F576 r0 += 0x30
    strb.w  r0, [sp, #2]                    @ 0801F578 u8 [sp+0x2] = r0
    uxtb    r4, r4                          @ 0801F57C r4 = u8(r4)
    movs    r0, #0xa                        @ 0801F57E r0 = 0xa
    sdiv    r1, r4, r0                      @ 0801F580
    mls     r0, r0, r1, r4                  @ 0801F584
    adds    r0, #0x30                       @ 0801F588 r0 += 0x30
    strb.w  r0, [sp, #3]                    @ 0801F58A u8 [sp+0x3] = r0
    movs    r0, #0x2f                       @ 0801F58E r0 = 0x2f
    strb.w  r0, [sp, #4]                    @ 0801F590 u8 [sp+0x4] = r0
    uxtb    r5, r5                          @ 0801F594 r5 = u8(r5)
    movs    r0, #0xa                        @ 0801F596 r0 = 0xa
    sdiv    r0, r5, r0                      @ 0801F598
    adds    r0, #0x30                       @ 0801F59C r0 += 0x30
    strb.w  r0, [sp, #5]                    @ 0801F59E u8 [sp+0x5] = r0
    uxtb    r5, r5                          @ 0801F5A2 r5 = u8(r5)
    movs    r0, #0xa                        @ 0801F5A4 r0 = 0xa
    sdiv    r1, r5, r0                      @ 0801F5A6
    mls     r0, r0, r1, r5                  @ 0801F5AA
    adds    r0, #0x30                       @ 0801F5AE r0 += 0x30
    strb.w  r0, [sp, #6]                    @ 0801F5B0 u8 [sp+0x6] = r0
    movs    r0, #0x2f                       @ 0801F5B4 r0 = 0x2f
    strb.w  r0, [sp, #7]                    @ 0801F5B6 u8 [sp+0x7] = r0
    uxtb    r6, r6                          @ 0801F5BA r6 = u8(r6)
    movs    r0, #0xa                        @ 0801F5BC r0 = 0xa
    sdiv    r0, r6, r0                      @ 0801F5BE
    adds    r0, #0x30                       @ 0801F5C2 r0 += 0x30
    strb.w  r0, [sp, #8]                    @ 0801F5C4 u8 [sp+0x8] = r0
    uxtb    r6, r6                          @ 0801F5C8 r6 = u8(r6)
    movs    r0, #0xa                        @ 0801F5CA r0 = 0xa
    sdiv    r1, r6, r0                      @ 0801F5CC
    mls     r0, r0, r1, r6                  @ 0801F5D0
    adds    r0, #0x30                       @ 0801F5D4 r0 += 0x30
    strb.w  r0, [sp, #9]                    @ 0801F5D6 u8 [sp+0x9] = r0
    movs    r0, #0x2c                       @ 0801F5DA r0 = 0x2c
    strb.w  r0, [sp, #0xa]                  @ 0801F5DC u8 [sp+0xA] = r0
    movs    r0, #0                          @ 0801F5E0 r0 = 0
    strb.w  r0, [sp, #0xb]                  @ 0801F5E2 u8 [sp+0xB] = r0
    mov     r0, sp                          @ 0801F5E6 r0 = sp
    bl      fn_08023CA0                     @ 0801F5E8 call fn_08023CA0
    movs    r1, r0                          @ 0801F5EC r1 = r0
    uxth    r1, r1                          @ 0801F5EE r1 = u16(r1)
    mov     r0, sp                          @ 0801F5F0 r0 = sp
    bl      log_write_bytes                 @ 0801F5F2 call log_write_bytes
    cmp     r0, #0                          @ 0801F5F6 compare r0 with 0
    beq     .Llog_write_date_F5FE           @ 0801F5F8 if (r0 == 0) goto 0x801F5FE
    movs    r0, #1                          @ 0801F5FA r0 = 1
    movs    r7, r0                          @ 0801F5FC r7 = r0
.Llog_write_date_F5FE:                  @ v2.05 0x0801F5FE, reached from 0x0801F5F8
    movs    r0, r7                          @ 0801F5FE r0 = r7
    uxtb    r0, r0                          @ 0801F600 r0 = u8(r0)
    pop     {r1, r2, r3, r4, r5, r6, r7, pc}@ 0801F602 pop {r1, r2, r3, r4, r5, r6, r7, pc}
ENDFUNC log_write_date
    .ltorg

