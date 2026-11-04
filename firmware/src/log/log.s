@ log.s - LOG module: the record ring of the data logger and its bookkeeping (DESIGN.md 6.22, W8)
@
@ v2.05 logging in outline.  A long press of MEM toggles logging (log_toggle).  While it is on, the main loop counts
@ seconds (step 9) and sets log_take_request once per logging interval; step 10 then calls log_take_record, which copies
@ the current reading into the next of 60 ring slots (log_slot_store).  Every 100 milliseconds (loop step 5)
@ log_compose_mode_range keeps the "current record" variables (function code, flags, values) up to date.  When the ring
@ is full, or when logging stops, log_write_request is set and loop step 12 runs the SD write (files.s: log_write_session).
@ The stored records can be viewed with MEM (log_set_view_window, log_view_index, log_slot_load).
@
@ A record is one reading of the meter, kept as three parallel readings:
@   main    function code (mode + 32 * range), flags byte, signed value
@   second  function code, flags byte, value (frequency, burden voltage, or the voltage of a VA mode)
@   third   function code, flags byte, value (the current of a VA mode)
@ plus the time stamp (years since 2000, month, day, hour, minute, second).  The flags byte holds bits 0-5 status flags of
@ the meter (see log_compose_mode_range), bit 6 = value is negative (stored as its complement) and bit 7 = overflow.
@
@ All variables keep their v2.05 addresses (DESIGN.md 5.1).  Names are defined by the .equ lines below; the address of every
@ name is the v2.05 address in its comment.
@
@ Deviation of this file: OF-35 (log_store_value logs the displayed value).
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
    .equ log_slot_value1,         v_200073C8            @ 0x200073C8 ring of 60 main values (i32 each)
    .equ log_slot_value2,         v_200074B8            @ 0x200074B8 ring of 60 second values (i32 each)
    .equ log_slot_value3,         v_200075A8            @ 0x200075A8 ring of 60 third values (i32 each)
    .equ log_slot_year,           v_20007810            @ 0x20007810 ring of 60 years (u8 each, years since 2000)
    .equ log_slot_month,          v_2000784C            @ 0x2000784C ring of 60 months
    .equ log_slot_day,            v_20007888            @ 0x20007888 ring of 60 days
    .equ log_slot_hour,           v_200078C4            @ 0x200078C4 ring of 60 hours
    .equ log_slot_minute,         v_20007900            @ 0x20007900 ring of 60 minutes
    .equ log_slot_second,         v_2000793C            @ 0x2000793C ring of 60 seconds
    .equ log_slot_func1,          v_20007978            @ 0x20007978 ring of 60 main function codes (mode + 32 * range)
    .equ log_slot_flags1,         v_200079B4            @ 0x200079B4 ring of 60 main flag bytes
    .equ log_slot_func2,          v_200079F0            @ 0x200079F0 ring of 60 second function codes
    .equ log_slot_flags2,         v_20007A2C            @ 0x20007A2C ring of 60 second flag bytes
    .equ log_slot_func3,          v_20007A68            @ 0x20007A68 ring of 60 third function codes
    .equ log_slot_flags3,         v_20007AA4            @ 0x20007AA4 ring of 60 third flag bytes
    .equ log_view_value1,         v_20007D1C            @ 0x20007D1C main value of the record loaded by log_slot_load (i32)
    .equ log_view_value2,         v_20007D20            @ 0x20007D20 second value of the loaded record
    .equ log_view_value3,         v_20007D24            @ 0x20007D24 third value of the loaded record
    .equ log_rec_value1,          v_20007D28            @ 0x20007D28 current record: main value (signed; a negative value is stored complemented, flags bit 6)
    .equ log_rec_value2,          v_20007D2C            @ 0x20007D2C current record: second value
    .equ log_rec_value3,          v_20007D30            @ 0x20007D30 current record: third value
    .equ log_blocks,              v_20007D34            @ 0x20007D34 number of complete 60-record blocks already written to the file
    .equ log_total,               v_20007D38            @ 0x20007D38 records taken since logging started (u32)
    .equ log_total_saved,         v_20007D3C            @ 0x20007D3C log_total as it was when logging stopped
    .equ log_row_no,              v_20007D40            @ 0x20007D40 number of the last row written to the file (CSV column "No.")
    .equ log_pending,             v_20007D44            @ 0x20007D44 records in the ring that are not written to the file yet
    .equ log_row_no_start,        v_20007D48            @ 0x20007D48 log_row_no at the start of the running flush (restored when the flush fails)
    .equ display_reading,         v_20007D64            @ 0x20007D64 averaged reading shown on the main display (ARS 5)
    .equ sample_reading,          v_20007D68            @ 0x20007D68 latest single-sample reading
    .equ log_view_valid,          v_20007F9C            @ 0x20007F9C 1 once log_set_view_window has set the window of stored records, 0 after log_start
    .equ log_view_len,            v_20007F9E            @ 0x20007F9E number of records in the window of stored records (60 once the ring has wrapped)
    .equ log_view_first,          v_20007FA0            @ 0x20007FA0 position of the oldest record of the window (1 or log_count + 1)
    .equ log_view_newest,         v_20007FA2            @ 0x20007FA2 position of the newest record of the window (= log_count)
    .equ log_count,               v_20007FA4            @ 0x20007FA4 records in the ring (0..60); next slot to be written
    .equ log_tick_count,          v_20007FA8            @ 0x20007FA8 seconds counted towards log_interval (main loop step 9)
    .equ log_count_saved,         v_20007FAC            @ 0x20007FAC log_count as it was when logging stopped
    .equ log_file_seq,            v_20007FAE            @ 0x20007FAE number of files forced since logging started (0 = first file of the run)
    .equ log_active,              v_20007FE1            @ 0x20007FE1 logging in progress (toggled by long MEM)
    .equ log_take_request,        v_20007FE2            @ 0x20007FE2 a record is due (set by the main loop at every interval)
    .equ log_start_flag3,         v_20007FE3            @ 0x20007FE3 set to 1 by log_start; no reader in LOG, meaning UNPROVEN
    .equ mem_view_active,         v_20007FE4            @ 0x20007FE4 stored-data (MEM) view active
    .equ log_view_flag0,          v_20007FE5            @ 0x20007FE5 flags bit 0 of the loaded record (source flag 0x20008098, LowZ AC variant: hy3131_modes_ac_current.md)
    .equ log_view_flag1,          v_20007FE6            @ 0x20007FE6 flags bit 1 of the loaded record (source flag 0x20008099, LowZ state: lcd_map.md 4.1)
    .equ log_view_flag2,          v_20007FE7            @ 0x20007FE7 flags bit 2 of the loaded record (source 0x200080B9 filter_1khz; CSV remark 1KHz)
    .equ log_view_flag3,          v_20007FE8            @ 0x20007FE8 flags bit 3 of the loaded record (source 0x200080B7 peak_hold; CSV remark PeakHold)
    .equ log_view_flag4,          v_20007FE9            @ 0x20007FE9 flags bit 4 of the loaded record (source 0x200080BA AC+DC; CSV remark ACDC)
    .equ log_view_flag5,          v_20007FEA            @ 0x20007FEA flags bit 5 of the loaded record (source 0x200080AB, temperature unit Celsius: lcd_map.md)
    .equ log_mode_shown,          v_20007FEB            @ 0x20007FEB mode copied back from log_mode_saved by log_restore_mode_range (reader outside LOG)
    .equ log_range_shown,         v_20007FEC            @ 0x20007FEC range copied back from log_range_saved by log_restore_mode_range (reader outside LOG)
    .equ log_rec_func1,           v_20007FEE            @ 0x20007FEE current record: main function code (mode + 32 * range)
    .equ log_rec_flags1,          v_20007FEF            @ 0x20007FEF current record: main flags (bits 0-5 meter status, bit 6 negative value, bit 7 overflow)
    .equ log_rec_func2,           v_20007FF0            @ 0x20007FF0 current record: second function code
    .equ log_rec_flags2,          v_20007FF1            @ 0x20007FF1 current record: second flags
    .equ log_rec_func3,           v_20007FF2            @ 0x20007FF2 current record: third function code
    .equ log_rec_flags3,          v_20007FF3            @ 0x20007FF3 current record: third flags
    .equ log_view_func1,          v_20007FF4            @ 0x20007FF4 main function code of the loaded record
    .equ log_view_flags1,         v_20007FF5            @ 0x20007FF5 main flags of the loaded record
    .equ log_view_func2,          v_20007FF6            @ 0x20007FF6 second function code of the loaded record
    .equ log_view_flags2,         v_20007FF7            @ 0x20007FF7 second flags of the loaded record
    .equ log_view_func3,          v_20007FF8            @ 0x20007FF8 third function code of the loaded record
    .equ log_view_flags3,         v_20007FF9            @ 0x20007FF9 third flags of the loaded record
    .equ log_second_flag,         v_20007FFA            @ 0x20007FFA cleared by the main loop at every second, set to 0 by log_start
    .equ log_start_year,          v_20007FFB            @ 0x20007FFB start time stamp of the log (years since 2000)
    .equ log_start_month,         v_20007FFC            @ 0x20007FFC start time stamp month
    .equ log_start_day,           v_20007FFD            @ 0x20007FFD start time stamp day
    .equ log_start_hour,          v_20007FFE            @ 0x20007FFE start time stamp hour
    .equ log_start_minute,        v_20007FFF            @ 0x20007FFF start time stamp minute
    .equ log_start_second,        v_20008000            @ 0x20008000 start time stamp second
    .equ log_stop_year,           v_20008001            @ 0x20008001 stop time stamp of the log
    .equ log_stop_month,          v_20008002            @ 0x20008002 stop time stamp month
    .equ log_stop_day,            v_20008003            @ 0x20008003 stop time stamp day
    .equ log_stop_hour,           v_20008004            @ 0x20008004 stop time stamp hour
    .equ log_stop_minute,         v_20008005            @ 0x20008005 stop time stamp minute
    .equ log_stop_second,         v_20008006            @ 0x20008006 stop time stamp second
    .equ log_view_year,           v_20008007            @ 0x20008007 date of the loaded record (years since 2000)
    .equ log_view_month,          v_20008008            @ 0x20008008 month of the loaded record
    .equ log_view_day,            v_20008009            @ 0x20008009 day of the loaded record
    .equ log_view_hour,           v_2000800A            @ 0x2000800A hour of the loaded record
    .equ log_view_minute,         v_2000800B            @ 0x2000800B minute of the loaded record
    .equ log_view_second,         v_2000800C            @ 0x2000800C second of the loaded record
    .equ log_mode_saved,          v_2000800D            @ 0x2000800D meter mode saved by log_save_mode_range
    .equ log_range_saved,         v_2000800E            @ 0x2000800E meter range saved by log_save_mode_range
    .equ log_start_year_bak,      v_2000800F            @ 0x2000800F backup of the start time stamp (log_save_stat_a)
    .equ log_start_month_bak,     v_20008010            @ 0x20008010 backup, month
    .equ log_start_day_bak,       v_20008011            @ 0x20008011 backup, day
    .equ log_start_hour_bak,      v_20008012            @ 0x20008012 backup, hour
    .equ log_start_minute_bak,    v_20008013            @ 0x20008013 backup, minute
    .equ log_start_second_bak,    v_20008014            @ 0x20008014 backup, second
    .equ log_stop_year_bak,       v_20008015            @ 0x20008015 backup of the stop time stamp (log_save_stat_b)
    .equ log_stop_month_bak,      v_20008016            @ 0x20008016 backup, month
    .equ log_stop_day_bak,        v_20008017            @ 0x20008017 backup, day
    .equ log_stop_hour_bak,       v_20008018            @ 0x20008018 backup, hour
    .equ log_stop_minute_bak,     v_20008019            @ 0x20008019 backup, minute
    .equ log_stop_second_bak,     v_2000801A            @ 0x2000801A backup, second
    .equ log_error_code,          v_2000801B            @ 0x2000801B error code of the last log write (shown as SdExx)
    .equ log_write_request,       v_2000801C            @ 0x2000801C a flush to the SD card is due (main loop step 12)
    .equ log_limit_hit,           v_2000801D            @ 0x2000801D logging stopped because the file reached 600000 rows
    .equ log_view_mode1,          v_2000801E            @ 0x2000801E mode of the main reading of the loaded record
    .equ log_view_range1,         v_2000801F            @ 0x2000801F range of the main reading of the loaded record
    .equ log_view_mode2,          v_20008020            @ 0x20008020 mode of the second reading of the loaded record
    .equ log_view_range2,         v_20008021            @ 0x20008021 range of the second reading of the loaded record
    .equ log_view_mode3,          v_20008022            @ 0x20008022 mode of the third reading of the loaded record
    .equ log_view_range3,         v_20008023            @ 0x20008023 range of the third reading of the loaded record
    .equ log_new_file,            v_20008024            @ 0x20008024 1 = the next session starts a new file (log_start, log_force_new_file)
    .equ log_closing,             v_20008025            @ 0x20008025 1 = logging is stopping; the next session writes the min/max rows (log_stop)
    .equ log_header_due,          v_20008026            @ 0x20008026 1 = the next flush writes the CSV header first
    .equ setup_item,              v_20008037            @ 0x20008037 setup page / item number
    .equ bat_low,                 v_2000803B            @ 0x2000803B debounced low-battery flag (adc_ch5_process)
    .equ range_manual_saved,      v_20008043            @ 0x20008043 range_manual as it was before logging
    .equ disp_overflow_neg,       v_20008045            @ 0x20008045 the overflow shown is negative
    .equ disp_overflow,           v_20008049            @ 0x20008049 the display shows OL
    .equ ui_refresh_request,      v_20008062            @ 0x20008062 display refresh / message request
    .equ rtc_year,                v_200080D7            @ 0x200080D7 years since 2000 (calendar copy of the NJU6350)
    .equ rtc_month,               v_200080D8            @ 0x200080D8 month
    .equ rtc_day,                 v_200080D9            @ 0x200080D9 day of the month
    .equ rtc_hour,                v_200080DA            @ 0x200080DA hour
    .equ rtc_minute,              v_200080DB            @ 0x200080DB minute
    .equ rtc_second,              v_200080DC            @ 0x200080DC second

@ -----------------------------------------------------------------------------
@ log_compose_mode_range - build the "current record" (function codes, flags and the values of the second and third reading)
@ Replaces  : 0x08010516 log_compose_mode_range (v2.05)
@ In        : -
@ Out       : -
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt: r0-r1; the port also changes r2, r3 and r12 through log_store_value (OF-35);
@             the only caller, loop step 5 (0x08024BDA), keeps nothing in them; r4-r11 preserved)
@ Context   : main only (loop step 5 every 100 ms: DESIGN.md 3.5)
@ RAM       : reads meter_mode 0x2000803C, meter_range 0x2000803D, 0x2000803E (frequency range index), the status flags 0x20008098
@             0x20008099 0x200080B9 0x200080B7 0x200080BA 0x200080AB, 0x20008047, 0x200080A5, 0x200080A7, 0x200080CA, 0x200080CB,
@             values 0x20007D84 (frequency), 0x20007E6C (burden voltage), 0x20007EAC, 0x20007EB0, 0x20007EB4 (VA voltage and
@             current); writes log_rec_func1..3, log_rec_flags1..3, log_rec_value2, log_rec_value3 and, through log_store_value,
@             log_rec_value1
@ Spec      : v2.05 listing 0x08010516..0x08010907 (the function only packs variables that other modules own)
@ Note      : second reading by mode: modes 2 (ACV without AC+DC), 4 (ACmV), 16, 18, 20 (AC currents): the frequency 0x20007D84
@             with function code 6 + 32 * 0x2000803E, or for the AC currents with 0x200080A5 set the burden voltage 0x20007E6C with
@             function code 0x19.  VA modes 13, 14, 15 (AC) and 22, 23, 24 (DC): second = voltage, third = current.  All other
@             modes have no second and third reading (function codes and values 0).
@ -----------------------------------------------------------------------------
FUNC log_compose_mode_range
    @ main function code = mode + 32 * range (the same packing is undone by log_slot_load_body)
    push    {r4, lr}                        @ 08010516 push {r4, lr}
    ldr.w   r0, =meter_mode                 @ 08010518 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 0801051C r0 = u8 [meter_mode]
    ldr.w   r1, =meter_range                @ 0801051E r1 = &meter_range
    ldrb    r1, [r1]                        @ 08010522 r1 = u8 [meter_range]
    adds.w  r0, r0, r1, lsl #5              @ 08010524 r0 = r0 + r1, lsl #5
    ldr.w   r1, =log_rec_func1              @ 08010528 r1 = &log_rec_func1
    strb    r0, [r1]                        @ 0801052C u8 [log_rec_func1] = r0
    movs    r0, #0                          @ 0801052E r0 = 0
    ldr.w   r1, =log_rec_flags1             @ 08010530 r1 = &log_rec_flags1
    strb    r0, [r1]                        @ 08010534 u8 [log_rec_flags1] = r0
    @ flags byte of the main reading: bit 0 0x20008098, bit 1 0x20008099, bit 2 0x200080B9, bit 3 0x200080B7,
    ldr.w   r0, =v_20008098                 @ 08010536 r0 = &v_20008098
    ldrb    r0, [r0]                        @ 0801053A r0 = u8 [v_20008098]
    cmp     r0, #0                          @ 0801053C compare r0 with 0
    beq     .Llog_compose_mode_range_0550   @ 0801053E if (r0 == 0) goto 0x8010550
    ldr.w   r0, =log_rec_flags1             @ 08010540 r0 = &log_rec_flags1
    ldrb    r0, [r0]                        @ 08010544 r0 = u8 [log_rec_flags1]
    orrs    r0, r0, #1                      @ 08010546 r0 = r0 | 1
    ldr.w   r1, =log_rec_flags1             @ 0801054A r1 = &log_rec_flags1
    strb    r0, [r1]                        @ 0801054E u8 [log_rec_flags1] = r0
.Llog_compose_mode_range_0550:          @ v2.05 0x08010550, reached from 0x0801053E
    ldr.w   r0, =v_20008099                 @ 08010550 r0 = &v_20008099
    ldrb    r0, [r0]                        @ 08010554 r0 = u8 [v_20008099]
    cmp     r0, #0                          @ 08010556 compare r0 with 0
    beq     .Llog_compose_mode_range_056A   @ 08010558 if (r0 == 0) goto 0x801056A
    ldr.w   r0, =log_rec_flags1             @ 0801055A r0 = &log_rec_flags1
    ldrb    r0, [r0]                        @ 0801055E r0 = u8 [log_rec_flags1]
    orrs    r0, r0, #2                      @ 08010560 r0 = r0 | 2
    ldr.w   r1, =log_rec_flags1             @ 08010564 r1 = &log_rec_flags1
    strb    r0, [r1]                        @ 08010568 u8 [log_rec_flags1] = r0
.Llog_compose_mode_range_056A:          @ v2.05 0x0801056A, reached from 0x08010558
    ldr.w   r0, =filter_1khz                @ 0801056A r0 = &filter_1khz
    ldrb    r0, [r0]                        @ 0801056E r0 = u8 [filter_1khz]
    cmp     r0, #0                          @ 08010570 compare r0 with 0
    beq     .Llog_compose_mode_range_0584   @ 08010572 if (r0 == 0) goto 0x8010584
    ldr.w   r0, =log_rec_flags1             @ 08010574 r0 = &log_rec_flags1
    ldrb    r0, [r0]                        @ 08010578 r0 = u8 [log_rec_flags1]
    orrs    r0, r0, #4                      @ 0801057A r0 = r0 | 4
    ldr.w   r1, =log_rec_flags1             @ 0801057E r1 = &log_rec_flags1
    strb    r0, [r1]                        @ 08010582 u8 [log_rec_flags1] = r0
.Llog_compose_mode_range_0584:          @ v2.05 0x08010584, reached from 0x08010572
    ldr.w   r0, =peak_hold                  @ 08010584 r0 = &peak_hold
    ldrb    r0, [r0]                        @ 08010588 r0 = u8 [peak_hold]
    cmp     r0, #0                          @ 0801058A compare r0 with 0
    beq     .Llog_compose_mode_range_059E   @ 0801058C if (r0 == 0) goto 0x801059E
    ldr.w   r0, =log_rec_flags1             @ 0801058E r0 = &log_rec_flags1
    ldrb    r0, [r0]                        @ 08010592 r0 = u8 [log_rec_flags1]
    orrs    r0, r0, #8                      @ 08010594 r0 = r0 | 8
    ldr.w   r1, =log_rec_flags1             @ 08010598 r1 = &log_rec_flags1
    strb    r0, [r1]                        @ 0801059C u8 [log_rec_flags1] = r0
.Llog_compose_mode_range_059E:          @ v2.05 0x0801059E, reached from 0x0801058C
    ldr.w   r0, =acdc_active                @ 0801059E r0 = &acdc_active
    ldrb    r0, [r0]                        @ 080105A2 r0 = u8 [acdc_active]
    cmp     r0, #0                          @ 080105A4 compare r0 with 0
    beq     .Llog_compose_mode_range_05B8   @ 080105A6 if (r0 == 0) goto 0x80105B8
    ldr.w   r0, =log_rec_flags1             @ 080105A8 r0 = &log_rec_flags1
    ldrb    r0, [r0]                        @ 080105AC r0 = u8 [log_rec_flags1]
    orrs    r0, r0, #0x10                   @ 080105AE r0 = r0 | 0x10
    ldr.w   r1, =log_rec_flags1             @ 080105B2 r1 = &log_rec_flags1
    strb    r0, [r1]                        @ 080105B6 u8 [log_rec_flags1] = r0
.Llog_compose_mode_range_05B8:          @ v2.05 0x080105B8, reached from 0x080105A6
    ldr.w   r0, =v_200080AB                 @ 080105B8 r0 = &v_200080AB
    ldrb    r0, [r0]                        @ 080105BC r0 = u8 [v_200080AB]
    cmp     r0, #0                          @ 080105BE compare r0 with 0
    beq     .Llog_compose_mode_range_05D2   @ 080105C0 if (r0 == 0) goto 0x80105D2
    ldr.w   r0, =log_rec_flags1             @ 080105C2 r0 = &log_rec_flags1
    ldrb    r0, [r0]                        @ 080105C6 r0 = u8 [log_rec_flags1]
    orrs    r0, r0, #0x20                   @ 080105C8 r0 = r0 | 0x20
    ldr.w   r1, =log_rec_flags1             @ 080105CC r1 = &log_rec_flags1
    strb    r0, [r1]                        @ 080105D0 u8 [log_rec_flags1] = r0
    @ value and bits 6 and 7 of the flags (overflow, sign) are added by log_store_value
.Llog_compose_mode_range_05D2:          @ v2.05 0x080105D2, reached from 0x080105C0
    bl      log_store_value                 @ 080105D2 call log_store_value
    @ second reading cleared: function code 0, flags 0, value 0
    movs    r0, #0                          @ 080105D6 r0 = 0
    ldr.w   r1, =log_rec_flags2             @ 080105D8 r1 = &log_rec_flags2
    strb    r0, [r1]                        @ 080105DC u8 [log_rec_flags2] = r0
    ldr.w   r0, =log_rec_flags2             @ 080105DE r0 = &log_rec_flags2
    ldrb    r0, [r0]                        @ 080105E2 r0 = u8 [log_rec_flags2]
    ldr.w   r1, =log_rec_func2              @ 080105E4 r1 = &log_rec_func2
    strb    r0, [r1]                        @ 080105E8 u8 [log_rec_func2] = r0
    movs    r0, #0                          @ 080105EA r0 = 0
    ldr.w   r1, =log_rec_value2             @ 080105EC r1 = &log_rec_value2
    str     r0, [r1]                        @ 080105F0 u32 [log_rec_value2] = r0
    @ modes 16, 18, 20, 2 (AC+DC off) and 4 have a frequency or burden reading as second reading
    ldr.w   r0, =meter_mode                 @ 080105F2 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080105F6 r0 = u8 [meter_mode]
    cmp     r0, #0x10                       @ 080105F8 compare r0 with 0x10
    beq     .Llog_compose_mode_range_062E   @ 080105FA if (r0 == 0x10) goto 0x801062E
    ldr.w   r0, =meter_mode                 @ 080105FC r0 = &meter_mode
    ldrb    r0, [r0]                        @ 08010600 r0 = u8 [meter_mode]
    cmp     r0, #0x12                       @ 08010602 compare r0 with 0x12
    beq     .Llog_compose_mode_range_062E   @ 08010604 if (r0 == 0x12) goto 0x801062E
    ldr.w   r0, =meter_mode                 @ 08010606 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 0801060A r0 = u8 [meter_mode]
    cmp     r0, #0x14                       @ 0801060C compare r0 with 0x14
    beq     .Llog_compose_mode_range_062E   @ 0801060E if (r0 == 0x14) goto 0x801062E
    ldr.w   r0, =meter_mode                 @ 08010610 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 08010614 r0 = u8 [meter_mode]
    cmp     r0, #2                          @ 08010616 compare r0 with 2
    bne     .Llog_compose_mode_range_0624   @ 08010618 if (r0 != 2) goto 0x8010624
    ldr.w   r0, =acdc_active                @ 0801061A r0 = &acdc_active
    ldrb    r0, [r0]                        @ 0801061E r0 = u8 [acdc_active]
    cmp     r0, #0                          @ 08010620 compare r0 with 0
    beq     .Llog_compose_mode_range_062E   @ 08010622 if (r0 == 0) goto 0x801062E
.Llog_compose_mode_range_0624:          @ v2.05 0x08010624, reached from 0x08010618
    ldr.w   r0, =meter_mode                 @ 08010624 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 08010628 r0 = u8 [meter_mode]
    cmp     r0, #4                          @ 0801062A compare r0 with 4
    bne     .Llog_compose_mode_range_06BE   @ 0801062C if (r0 != 4) goto 0x80106BE
    @ AC current modes with the burden display on (0x200080A5): second reading = burden voltage
.Llog_compose_mode_range_062E:          @ v2.05 0x0801062E, reached from 0x080105FA, 0x08010604, 0x0801060E, 0x08010622
    ldr.w   r0, =meter_mode                 @ 0801062E r0 = &meter_mode
    ldrb    r0, [r0]                        @ 08010632 r0 = u8 [meter_mode]
    cmp     r0, #0x10                       @ 08010634 compare r0 with 0x10
    beq     .Llog_compose_mode_range_064C   @ 08010636 if (r0 == 0x10) goto 0x801064C
    ldr.w   r0, =meter_mode                 @ 08010638 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 0801063C r0 = u8 [meter_mode]
    cmp     r0, #0x12                       @ 0801063E compare r0 with 0x12
    beq     .Llog_compose_mode_range_064C   @ 08010640 if (r0 == 0x12) goto 0x801064C
    ldr.w   r0, =meter_mode                 @ 08010642 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 08010646 r0 = u8 [meter_mode]
    cmp     r0, #0x14                       @ 08010648 compare r0 with 0x14
    bne     .Llog_compose_mode_range_0686   @ 0801064A if (r0 != 0x14) goto 0x8010686
    @ burden voltage: function code 0x19, flags bit 7 when 0x200080A7, value 0x20007E6C
.Llog_compose_mode_range_064C:          @ v2.05 0x0801064C, reached from 0x08010636, 0x08010640
    ldr.w   r0, =v_200080A5                 @ 0801064C r0 = &v_200080A5
    ldrb    r0, [r0]                        @ 08010650 r0 = u8 [v_200080A5]
    cmp     r0, #0                          @ 08010652 compare r0 with 0
    beq     .Llog_compose_mode_range_0686   @ 08010654 if (r0 == 0) goto 0x8010686
    movs    r0, #0x19                       @ 08010656 r0 = 0x19
    ldr.w   r1, =log_rec_func2              @ 08010658 r1 = &log_rec_func2
    strb    r0, [r1]                        @ 0801065C u8 [log_rec_func2] = r0
    ldr.w   r0, =v_200080A7                 @ 0801065E r0 = &v_200080A7
    ldrb    r0, [r0]                        @ 08010662 r0 = u8 [v_200080A7]
    cmp     r0, #0                          @ 08010664 compare r0 with 0
    beq     .Llog_compose_mode_range_0678   @ 08010666 if (r0 == 0) goto 0x8010678
    ldr.w   r0, =log_rec_flags2             @ 08010668 r0 = &log_rec_flags2
    ldrb    r0, [r0]                        @ 0801066C r0 = u8 [log_rec_flags2]
    orrs    r0, r0, #0x80                   @ 0801066E r0 = r0 | 0x80
    ldr.w   r1, =log_rec_flags2             @ 08010672 r1 = &log_rec_flags2
    strb    r0, [r1]                        @ 08010676 u8 [log_rec_flags2] = r0
.Llog_compose_mode_range_0678:          @ v2.05 0x08010678, reached from 0x08010666
    ldr.w   r0, =v_20007E6C                 @ 08010678 r0 = &v_20007E6C
    ldr     r0, [r0]                        @ 0801067C r0 = u32 [v_20007E6C]
    ldr.w   r1, =log_rec_value2             @ 0801067E r1 = &log_rec_value2
    str     r0, [r1]                        @ 08010682 u32 [log_rec_value2] = r0
    b       .Llog_compose_mode_range_0780   @ 08010684 goto 0x8010780
    @ frequency: function code 6 + 32 * 0x2000803E, flags bit 7 when 0x20008047, value 0x20007D84
.Llog_compose_mode_range_0686:          @ v2.05 0x08010686, reached from 0x0801064A, 0x08010654
    ldr.w   r0, =v_2000803E                 @ 08010686 r0 = &v_2000803E
    ldrb    r0, [r0]                        @ 0801068A r0 = u8 [v_2000803E]
    lsls    r0, r0, #5                      @ 0801068C r0 = r0 << 5
    adds    r0, r0, #6                      @ 0801068E r0 = r0 + 6
    ldr.w   r1, =log_rec_func2              @ 08010690 r1 = &log_rec_func2
    strb    r0, [r1]                        @ 08010694 u8 [log_rec_func2] = r0
    ldr.w   r0, =v_20008047                 @ 08010696 r0 = &v_20008047
    ldrb    r0, [r0]                        @ 0801069A r0 = u8 [v_20008047]
    cmp     r0, #0                          @ 0801069C compare r0 with 0
    beq     .Llog_compose_mode_range_06B0   @ 0801069E if (r0 == 0) goto 0x80106B0
    ldr.w   r0, =log_rec_flags2             @ 080106A0 r0 = &log_rec_flags2
    ldrb    r0, [r0]                        @ 080106A4 r0 = u8 [log_rec_flags2]
    orrs    r0, r0, #0x80                   @ 080106A6 r0 = r0 | 0x80
    ldr.w   r1, =log_rec_flags2             @ 080106AA r1 = &log_rec_flags2
    strb    r0, [r1]                        @ 080106AE u8 [log_rec_flags2] = r0
.Llog_compose_mode_range_06B0:          @ v2.05 0x080106B0, reached from 0x0801069E
    ldr.w   r0, =v_20007D84                 @ 080106B0 r0 = &v_20007D84
    ldr     r0, [r0]                        @ 080106B4 r0 = u32 [v_20007D84]
    ldr.w   r1, =log_rec_value2             @ 080106B6 r1 = &log_rec_value2
    str     r0, [r1]                        @ 080106BA u32 [log_rec_value2] = r0
    b       .Llog_compose_mode_range_0780   @ 080106BC goto 0x8010780
    @ VA modes 13, 14, 15, 22, 23, 24: second reading = voltage 0x20007EAC
.Llog_compose_mode_range_06BE:          @ v2.05 0x080106BE, reached from 0x0801062C
    ldr.w   r0, =meter_mode                 @ 080106BE r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080106C2 r0 = u8 [meter_mode]
    cmp     r0, #0xd                        @ 080106C4 compare r0 with 0xd
    beq     .Llog_compose_mode_range_06FA   @ 080106C6 if (r0 == 0xd) goto 0x80106FA
    ldr.w   r0, =meter_mode                 @ 080106C8 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080106CC r0 = u8 [meter_mode]
    cmp     r0, #0xe                        @ 080106CE compare r0 with 0xe
    beq     .Llog_compose_mode_range_06FA   @ 080106D0 if (r0 == 0xe) goto 0x80106FA
    ldr.w   r0, =meter_mode                 @ 080106D2 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080106D6 r0 = u8 [meter_mode]
    cmp     r0, #0xf                        @ 080106D8 compare r0 with 0xf
    beq     .Llog_compose_mode_range_06FA   @ 080106DA if (r0 == 0xf) goto 0x80106FA
    ldr.w   r0, =meter_mode                 @ 080106DC r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080106E0 r0 = u8 [meter_mode]
    cmp     r0, #0x16                       @ 080106E2 compare r0 with 0x16
    beq     .Llog_compose_mode_range_06FA   @ 080106E4 if (r0 == 0x16) goto 0x80106FA
    ldr.w   r0, =meter_mode                 @ 080106E6 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080106EA r0 = u8 [meter_mode]
    cmp     r0, #0x17                       @ 080106EC compare r0 with 0x17
    beq     .Llog_compose_mode_range_06FA   @ 080106EE if (r0 == 0x17) goto 0x80106FA
    ldr.w   r0, =meter_mode                 @ 080106F0 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080106F4 r0 = u8 [meter_mode]
    cmp     r0, #0x18                       @ 080106F6 compare r0 with 0x18
    bne     .Llog_compose_mode_range_0780   @ 080106F8 if (r0 != 0x18) goto 0x8010780
    @ function code 2 (ACV) for 13, 14, 15 and 1 (DCV) for 22, 23, 24; ranges 1 and 3 add 32
.Llog_compose_mode_range_06FA:          @ v2.05 0x080106FA, reached from 0x080106C6, 0x080106D0, 0x080106DA, 0x080106E4, 0x080106EE
    ldr.w   r0, =meter_mode                 @ 080106FA r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080106FE r0 = u8 [meter_mode]
    cmp     r0, #0xd                        @ 08010700 compare r0 with 0xd
    beq     .Llog_compose_mode_range_0718   @ 08010702 if (r0 == 0xd) goto 0x8010718
    ldr.w   r0, =meter_mode                 @ 08010704 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 08010708 r0 = u8 [meter_mode]
    cmp     r0, #0xe                        @ 0801070A compare r0 with 0xe
    beq     .Llog_compose_mode_range_0718   @ 0801070C if (r0 == 0xe) goto 0x8010718
    ldr.w   r0, =meter_mode                 @ 0801070E r0 = &meter_mode
    ldrb    r0, [r0]                        @ 08010712 r0 = u8 [meter_mode]
    cmp     r0, #0xf                        @ 08010714 compare r0 with 0xf
    bne     .Llog_compose_mode_range_0722   @ 08010716 if (r0 != 0xf) goto 0x8010722
.Llog_compose_mode_range_0718:          @ v2.05 0x08010718, reached from 0x08010702, 0x0801070C
    movs    r0, #2                          @ 08010718 r0 = 2
    ldr.w   r1, =log_rec_func2              @ 0801071A r1 = &log_rec_func2
    strb    r0, [r1]                        @ 0801071E u8 [log_rec_func2] = r0
    b       .Llog_compose_mode_range_072A   @ 08010720 goto 0x801072A
.Llog_compose_mode_range_0722:          @ v2.05 0x08010722, reached from 0x08010716
    movs    r0, #1                          @ 08010722 r0 = 1
    ldr.w   r1, =log_rec_func2              @ 08010724 r1 = &log_rec_func2
    strb    r0, [r1]                        @ 08010728 u8 [log_rec_func2] = r0
.Llog_compose_mode_range_072A:          @ v2.05 0x0801072A, reached from 0x08010720
    ldr.w   r0, =meter_range                @ 0801072A r0 = &meter_range
    ldrb    r0, [r0]                        @ 0801072E r0 = u8 [meter_range]
    cmp     r0, #1                          @ 08010730 compare r0 with 1
    beq     .Llog_compose_mode_range_073E   @ 08010732 if (r0 == 1) goto 0x801073E
    ldr.w   r0, =meter_range                @ 08010734 r0 = &meter_range
    ldrb    r0, [r0]                        @ 08010738 r0 = u8 [meter_range]
    cmp     r0, #3                          @ 0801073A compare r0 with 3
    bne     .Llog_compose_mode_range_074C   @ 0801073C if (r0 != 3) goto 0x801074C
.Llog_compose_mode_range_073E:          @ v2.05 0x0801073E, reached from 0x08010732
    ldr.w   r0, =log_rec_func2              @ 0801073E r0 = &log_rec_func2
    ldrb    r0, [r0]                        @ 08010742 r0 = u8 [log_rec_func2]
    adds    r0, #0x20                       @ 08010744 r0 += 0x20
    ldr.w   r1, =log_rec_func2              @ 08010746 r1 = &log_rec_func2
    strb    r0, [r1]                        @ 0801074A u8 [log_rec_func2] = r0
    @ overload of the voltage or of the current (0x200080CA, 0x200080CB) sets flags bit 7
.Llog_compose_mode_range_074C:          @ v2.05 0x0801074C, reached from 0x0801073C
    ldr.w   r0, =v_200080CA                 @ 0801074C r0 = &v_200080CA
    ldrsb.w r0, [r0]                        @ 08010750 r0 = s8 [v_200080CA]
    cmp     r0, #0                          @ 08010754 compare r0 with 0
    bne     .Llog_compose_mode_range_0764   @ 08010756 if (r0 != 0) goto 0x8010764
    ldr.w   r0, =v_200080CB                 @ 08010758 r0 = &v_200080CB
    ldrsb.w r0, [r0]                        @ 0801075C r0 = s8 [v_200080CB]
    cmp     r0, #0                          @ 08010760 compare r0 with 0
    beq     .Llog_compose_mode_range_0774   @ 08010762 if (r0 == 0) goto 0x8010774
.Llog_compose_mode_range_0764:          @ v2.05 0x08010764, reached from 0x08010756
    ldr.w   r0, =log_rec_flags2             @ 08010764 r0 = &log_rec_flags2
    ldrb    r0, [r0]                        @ 08010768 r0 = u8 [log_rec_flags2]
    orrs    r0, r0, #0x80                   @ 0801076A r0 = r0 | 0x80
    ldr.w   r1, =log_rec_flags2             @ 0801076E r1 = &log_rec_flags2
    strb    r0, [r1]                        @ 08010772 u8 [log_rec_flags2] = r0
.Llog_compose_mode_range_0774:          @ v2.05 0x08010774, reached from 0x08010762
    ldr.w   r0, =v_20007EAC                 @ 08010774 r0 = &v_20007EAC
    ldr     r0, [r0]                        @ 08010778 r0 = u32 [v_20007EAC]
    ldr.w   r1, =log_rec_value2             @ 0801077A r1 = &log_rec_value2
    str     r0, [r1]                        @ 0801077E u32 [log_rec_value2] = r0
    @ third reading cleared
.Llog_compose_mode_range_0780:          @ v2.05 0x08010780, reached from 0x08010684, 0x080106BC, 0x080106F8
    movs    r0, #0                          @ 08010780 r0 = 0
    ldr.w   r1, =log_rec_flags3             @ 08010782 r1 = &log_rec_flags3
    strb    r0, [r1]                        @ 08010786 u8 [log_rec_flags3] = r0
    ldr.w   r0, =log_rec_flags3             @ 08010788 r0 = &log_rec_flags3
    ldrb    r0, [r0]                        @ 0801078C r0 = u8 [log_rec_flags3]
    ldr.w   r1, =log_rec_func3              @ 0801078E r1 = &log_rec_func3
    strb    r0, [r1]                        @ 08010792 u8 [log_rec_func3] = r0
    movs    r0, #0                          @ 08010794 r0 = 0
    ldr.w   r1, =log_rec_value3             @ 08010796 r1 = &log_rec_value3
    str     r0, [r1]                        @ 0801079A u32 [log_rec_value3] = r0
    @ VA modes: third reading = current
    ldr.w   r0, =meter_mode                 @ 0801079C r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080107A0 r0 = u8 [meter_mode]
    cmp     r0, #0xd                        @ 080107A2 compare r0 with 0xd
    beq     .Llog_compose_mode_range_07DA   @ 080107A4 if (r0 == 0xd) goto 0x80107DA
    ldr.w   r0, =meter_mode                 @ 080107A6 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080107AA r0 = u8 [meter_mode]
    cmp     r0, #0xe                        @ 080107AC compare r0 with 0xe
    beq     .Llog_compose_mode_range_07DA   @ 080107AE if (r0 == 0xe) goto 0x80107DA
    ldr.w   r0, =meter_mode                 @ 080107B0 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080107B4 r0 = u8 [meter_mode]
    cmp     r0, #0xf                        @ 080107B6 compare r0 with 0xf
    beq     .Llog_compose_mode_range_07DA   @ 080107B8 if (r0 == 0xf) goto 0x80107DA
    ldr.w   r0, =meter_mode                 @ 080107BA r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080107BE r0 = u8 [meter_mode]
    cmp     r0, #0x16                       @ 080107C0 compare r0 with 0x16
    beq     .Llog_compose_mode_range_07DA   @ 080107C2 if (r0 == 0x16) goto 0x80107DA
    ldr.w   r0, =meter_mode                 @ 080107C4 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080107C8 r0 = u8 [meter_mode]
    cmp     r0, #0x17                       @ 080107CA compare r0 with 0x17
    beq     .Llog_compose_mode_range_07DA   @ 080107CC if (r0 == 0x17) goto 0x80107DA
    ldr.w   r0, =meter_mode                 @ 080107CE r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080107D2 r0 = u8 [meter_mode]
    cmp     r0, #0x18                       @ 080107D4 compare r0 with 0x18
    bne.w   .Llog_compose_mode_range_0906   @ 080107D6 if (r0 != 0x18) goto 0x8010906
    @ function code of the current: ACuA 16 / ACmA 18 / ACA 20 for 13, 14, 15 and DCuA 17 / DCmA 19 / DCA 21 for 22, 23, 24
.Llog_compose_mode_range_07DA:          @ v2.05 0x080107DA, reached from 0x080107A4, 0x080107AE, 0x080107B8, 0x080107C2, 0x080107CC
    ldr.w   r0, =meter_mode                 @ 080107DA r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080107DE r0 = u8 [meter_mode]
    cmp     r0, #0xd                        @ 080107E0 compare r0 with 0xd
    beq     .Llog_compose_mode_range_07FA   @ 080107E2 if (r0 == 0xd) goto 0x80107FA
    cmp     r0, #0xe                        @ 080107E4 compare r0 with 0xe
    beq     .Llog_compose_mode_range_0804   @ 080107E6 if (r0 == 0xe) goto 0x8010804
    cmp     r0, #0xf                        @ 080107E8 compare r0 with 0xf
    beq     .Llog_compose_mode_range_080E   @ 080107EA if (r0 == 0xf) goto 0x801080E
    cmp     r0, #0x16                       @ 080107EC compare r0 with 0x16
    beq     .Llog_compose_mode_range_0818   @ 080107EE if (r0 == 0x16) goto 0x8010818
    cmp     r0, #0x17                       @ 080107F0 compare r0 with 0x17
    beq     .Llog_compose_mode_range_0822   @ 080107F2 if (r0 == 0x17) goto 0x8010822
    cmp     r0, #0x18                       @ 080107F4 compare r0 with 0x18
    beq     .Llog_compose_mode_range_082C   @ 080107F6 if (r0 == 0x18) goto 0x801082C
    b       .Llog_compose_mode_range_0834   @ 080107F8 goto 0x8010834
.Llog_compose_mode_range_07FA:          @ v2.05 0x080107FA, reached from 0x080107E2
    movs    r0, #0x10                       @ 080107FA r0 = 0x10
    ldr.w   r1, =log_rec_func3              @ 080107FC r1 = &log_rec_func3
    strb    r0, [r1]                        @ 08010800 u8 [log_rec_func3] = r0
    b       .Llog_compose_mode_range_0834   @ 08010802 goto 0x8010834
.Llog_compose_mode_range_0804:          @ v2.05 0x08010804, reached from 0x080107E6
    movs    r0, #0x12                       @ 08010804 r0 = 0x12
    ldr.w   r1, =log_rec_func3              @ 08010806 r1 = &log_rec_func3
    strb    r0, [r1]                        @ 0801080A u8 [log_rec_func3] = r0
    b       .Llog_compose_mode_range_0834   @ 0801080C goto 0x8010834
.Llog_compose_mode_range_080E:          @ v2.05 0x0801080E, reached from 0x080107EA
    movs    r0, #0x14                       @ 0801080E r0 = 0x14
    ldr.w   r1, =log_rec_func3              @ 08010810 r1 = &log_rec_func3
    strb    r0, [r1]                        @ 08010814 u8 [log_rec_func3] = r0
    b       .Llog_compose_mode_range_0834   @ 08010816 goto 0x8010834
.Llog_compose_mode_range_0818:          @ v2.05 0x08010818, reached from 0x080107EE
    movs    r0, #0x11                       @ 08010818 r0 = 0x11
    ldr.w   r1, =log_rec_func3              @ 0801081A r1 = &log_rec_func3
    strb    r0, [r1]                        @ 0801081E u8 [log_rec_func3] = r0
    b       .Llog_compose_mode_range_0834   @ 08010820 goto 0x8010834
.Llog_compose_mode_range_0822:          @ v2.05 0x08010822, reached from 0x080107F2
    movs    r0, #0x13                       @ 08010822 r0 = 0x13
    ldr.w   r1, =log_rec_func3              @ 08010824 r1 = &log_rec_func3
    strb    r0, [r1]                        @ 08010828 u8 [log_rec_func3] = r0
    b       .Llog_compose_mode_range_0834   @ 0801082A goto 0x8010834
.Llog_compose_mode_range_082C:          @ v2.05 0x0801082C, reached from 0x080107F6
    movs    r0, #0x15                       @ 0801082C r0 = 0x15
    ldr.w   r1, =log_rec_func3              @ 0801082E r1 = &log_rec_func3
    strb    r0, [r1]                        @ 08010832 u8 [log_rec_func3] = r0
    @ r4 = 2: first range index that adds to the current function code
.Llog_compose_mode_range_0834:          @ v2.05 0x08010834, reached from 0x080107F8, 0x08010802, 0x0801080C, 0x08010816, 0x08010820, 0x0801082A
    movs    r0, #2                          @ 08010834 r0 = 2
    movs    r4, r0                          @ 08010836 r4 = r0
    ldr.w   r0, =meter_mode                 @ 08010838 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 0801083C r0 = u8 [meter_mode]
    cmp     r0, #0xd                        @ 0801083E compare r0 with 0xd
    beq     .Llog_compose_mode_range_0858   @ 08010840 if (r0 == 0xd) goto 0x8010858
    cmp     r0, #0xe                        @ 08010842 compare r0 with 0xe
    beq     .Llog_compose_mode_range_0876   @ 08010844 if (r0 == 0xe) goto 0x8010876
    cmp     r0, #0xf                        @ 08010846 compare r0 with 0xf
    beq     .Llog_compose_mode_range_0894   @ 08010848 if (r0 == 0xf) goto 0x8010894
    cmp     r0, #0x16                       @ 0801084A compare r0 with 0x16
    beq     .Llog_compose_mode_range_0858   @ 0801084C if (r0 == 0x16) goto 0x8010858
    cmp     r0, #0x17                       @ 0801084E compare r0 with 0x17
    beq     .Llog_compose_mode_range_0876   @ 08010850 if (r0 == 0x17) goto 0x8010876
    cmp     r0, #0x18                       @ 08010852 compare r0 with 0x18
    beq     .Llog_compose_mode_range_0894   @ 08010854 if (r0 == 0x18) goto 0x8010894
    b       .Llog_compose_mode_range_08B0   @ 08010856 goto 0x80108B0
    @ modes 13 and 22: range >= 2 adds 32 to the function code; 14 and 23 likewise; 15 and 24 add 64
.Llog_compose_mode_range_0858:          @ v2.05 0x08010858, reached from 0x08010840, 0x0801084C
    ldr.w   r0, =meter_range                @ 08010858 r0 = &meter_range
    ldrb    r0, [r0]                        @ 0801085C r0 = u8 [meter_range]
    movs    r1, r4                          @ 0801085E r1 = r4
    uxtb    r1, r1                          @ 08010860 r1 = u8(r1)
    cmp     r0, r1                          @ 08010862 compare r0 with r1
    blo     .Llog_compose_mode_range_0874   @ 08010864 if (r0 <u r1) goto 0x8010874
    ldr.w   r0, =log_rec_func3              @ 08010866 r0 = &log_rec_func3
    ldrb    r0, [r0]                        @ 0801086A r0 = u8 [log_rec_func3]
    adds    r0, #0x20                       @ 0801086C r0 += 0x20
    ldr.w   r1, =log_rec_func3              @ 0801086E r1 = &log_rec_func3
    strb    r0, [r1]                        @ 08010872 u8 [log_rec_func3] = r0
.Llog_compose_mode_range_0874:          @ v2.05 0x08010874, reached from 0x08010864
    b       .Llog_compose_mode_range_08B0   @ 08010874 goto 0x80108B0
.Llog_compose_mode_range_0876:          @ v2.05 0x08010876, reached from 0x08010844, 0x08010850
    ldr.w   r0, =meter_range                @ 08010876 r0 = &meter_range
    ldrb    r0, [r0]                        @ 0801087A r0 = u8 [meter_range]
    movs    r1, r4                          @ 0801087C r1 = r4
    uxtb    r1, r1                          @ 0801087E r1 = u8(r1)
    cmp     r0, r1                          @ 08010880 compare r0 with r1
    blo     .Llog_compose_mode_range_0892   @ 08010882 if (r0 <u r1) goto 0x8010892
    ldr.w   r0, =log_rec_func3              @ 08010884 r0 = &log_rec_func3
    ldrb    r0, [r0]                        @ 08010888 r0 = u8 [log_rec_func3]
    adds    r0, #0x20                       @ 0801088A r0 += 0x20
    ldr.w   r1, =log_rec_func3              @ 0801088C r1 = &log_rec_func3
    strb    r0, [r1]                        @ 08010890 u8 [log_rec_func3] = r0
.Llog_compose_mode_range_0892:          @ v2.05 0x08010892, reached from 0x08010882
    b       .Llog_compose_mode_range_08B0   @ 08010892 goto 0x80108B0
.Llog_compose_mode_range_0894:          @ v2.05 0x08010894, reached from 0x08010848, 0x08010854
    ldr.w   r0, =meter_range                @ 08010894 r0 = &meter_range
    ldrb    r0, [r0]                        @ 08010898 r0 = u8 [meter_range]
    movs    r1, r4                          @ 0801089A r1 = r4
    uxtb    r1, r1                          @ 0801089C r1 = u8(r1)
    cmp     r0, r1                          @ 0801089E compare r0 with r1
    blo     .Llog_compose_mode_range_08B0   @ 080108A0 if (r0 <u r1) goto 0x80108B0
    ldr.w   r0, =log_rec_func3              @ 080108A2 r0 = &log_rec_func3
    ldrb    r0, [r0]                        @ 080108A6 r0 = u8 [log_rec_func3]
    adds    r0, #0x40                       @ 080108A8 r0 += 0x40
    ldr.w   r1, =log_rec_func3              @ 080108AA r1 = &log_rec_func3
    strb    r0, [r1]                        @ 080108AE u8 [log_rec_func3] = r0
    @ overload flag of the current sets flags bit 7
.Llog_compose_mode_range_08B0:          @ v2.05 0x080108B0, reached from 0x08010856, 0x08010874, 0x08010892, 0x080108A0
    ldr.w   r0, =v_200080CB                 @ 080108B0 r0 = &v_200080CB
    ldrsb.w r0, [r0]                        @ 080108B4 r0 = s8 [v_200080CB]
    cmp     r0, #0                          @ 080108B8 compare r0 with 0
    bne     .Llog_compose_mode_range_08C8   @ 080108BA if (r0 != 0) goto 0x80108C8
    ldr.w   r0, =v_200080CA                 @ 080108BC r0 = &v_200080CA
    ldrsb.w r0, [r0]                        @ 080108C0 r0 = s8 [v_200080CA]
    cmp     r0, #0                          @ 080108C4 compare r0 with 0
    beq     .Llog_compose_mode_range_08D8   @ 080108C6 if (r0 == 0) goto 0x80108D8
.Llog_compose_mode_range_08C8:          @ v2.05 0x080108C8, reached from 0x080108BA
    ldr.w   r0, =log_rec_flags3             @ 080108C8 r0 = &log_rec_flags3
    ldrb    r0, [r0]                        @ 080108CC r0 = u8 [log_rec_flags3]
    orrs    r0, r0, #0x80                   @ 080108CE r0 = r0 | 0x80
    ldr.w   r1, =log_rec_flags3             @ 080108D2 r1 = &log_rec_flags3
    strb    r0, [r1]                        @ 080108D6 u8 [log_rec_flags3] = r0
    @ value: 0x20007EB4 for modes 13 and 22, else 0x20007EB0
.Llog_compose_mode_range_08D8:          @ v2.05 0x080108D8, reached from 0x080108C6
    ldr.w   r0, =meter_mode                 @ 080108D8 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080108DC r0 = u8 [meter_mode]
    cmp     r0, #0xd                        @ 080108DE compare r0 with 0xd
    beq     .Llog_compose_mode_range_08EC   @ 080108E0 if (r0 == 0xd) goto 0x80108EC
    ldr.w   r0, =meter_mode                 @ 080108E2 r0 = &meter_mode
    ldrb    r0, [r0]                        @ 080108E6 r0 = u8 [meter_mode]
    cmp     r0, #0x16                       @ 080108E8 compare r0 with 0x16
    bne     .Llog_compose_mode_range_08FA   @ 080108EA if (r0 != 0x16) goto 0x80108FA
.Llog_compose_mode_range_08EC:          @ v2.05 0x080108EC, reached from 0x080108E0
    ldr.w   r0, =v_20007EB4                 @ 080108EC r0 = &v_20007EB4
    ldr     r0, [r0]                        @ 080108F0 r0 = u32 [v_20007EB4]
    ldr.w   r1, =log_rec_value3             @ 080108F2 r1 = &log_rec_value3
    str     r0, [r1]                        @ 080108F6 u32 [log_rec_value3] = r0
    b       .Llog_compose_mode_range_0906   @ 080108F8 goto 0x8010906
.Llog_compose_mode_range_08FA:          @ v2.05 0x080108FA, reached from 0x080108EA
    ldr.w   r0, =v_20007EB0                 @ 080108FA r0 = &v_20007EB0
    ldr     r0, [r0]                        @ 080108FE r0 = u32 [v_20007EB0]
    ldr.w   r1, =log_rec_value3             @ 08010900 r1 = &log_rec_value3
    str     r0, [r1]                        @ 08010904 u32 [log_rec_value3] = r0
.Llog_compose_mode_range_0906:          @ v2.05 0x08010906, reached from 0x080107D6, 0x080108F8
    pop     {r4, pc}                        @ 08010906 pop {r4, pc}
ENDFUNC log_compose_mode_range
    .ltorg

@ -----------------------------------------------------------------------------
@ log_store_value - build the main value and flags of the record that is being taken
@ Replaces : 0x08010908 FUN_08010908 (v2.05), called by log_compose_mode_range at 0x080105D2
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS; v2.05 changed r0 and r1 only, 0x08010908..0x080109E9)
@ Context  : main only
@ RAM      : reads disp_overflow 0x20008049, disp_overflow_neg 0x20008045, display_reading 0x20007D64;
@            read-modify-writes log_rec_flags1 0x20007FEF; writes log_rec_value1 0x20007D28
@ Result   : overflow (disp_overflow != 0): flags |= 0x80, value = 0x7FFFFFFF, and flags |= 0x40 when
@            disp_overflow_neg != 0 ("-Overflow" row).  Otherwise value = display_reading; a negative reading sets
@            flags |= 0x40 and is stored as its bitwise complement ~x = -x - 1 (v2.05 0x0801099A, 0x080109D2)
@ Spec     : v2.05 listing 0x08010908..0x080109E9; ORIGINAL_FIRMWARE_ISSUES.md OF-35
@ Deviation: OF-35.  v2.05 copies the per-sample value 0x20007D68 (sample_reading) into the record in every mode
@            except 5, 6, 7, 8, 9 and 12 (0x08010948..0x08010978 choose the source from meter_mode, 0x080109B2..0x080109E6
@            copy 0x20007D68), which use the displayed mean 0x20007D64.  The port copies the displayed mean in every mode,
@            so a log row shows what the display showed.
@ -----------------------------------------------------------------------------
FUNC log_store_value
    ldr     r1, =log_rec_flags1             @ r1 = &flags byte of the main reading
    ldr     r2, =log_rec_value1             @ r2 = &main value of the record
    ldrb    r3, [r1]                        @ r3 = flags so far
    ldr     r0, =disp_overflow
    ldrb    r0, [r0]                        @ display shows OL?
    cmp     r0, #0
    beq     .Llsv_normal                    @ no overflow: take the displayed reading
    orr     r3, r3, #0x80                   @ flags bit 7 = overflow (0x08010918)
    mvn     r0, #0x80000000                 @ value = 0x7FFFFFFF (0x08010922)
    ldr     r12, =disp_overflow_neg
    ldrb    r12, [r12]
    cmp     r12, #0
    beq     .Llsv_store                     @ positive overflow
    orr     r3, r3, #0x40                   @ flags bit 6 = negative (-Overflow, 0x0801093C)
    b       .Llsv_store
.Llsv_normal:
    ldr     r0, =display_reading
    ldr     r0, [r0]                        @ OF-35: the displayed mean in every mode
    cmp     r0, #0
    bpl     .Llsv_store                     @ non-negative: stored as it is
    orr     r3, r3, #0x40                   @ flags bit 6 = negative
    mvn     r0, r0                          @ stored as the complement (0x0801099A)
.Llsv_store:
    strb    r3, [r1]                        @ flags back
    str     r0, [r2]                        @ value
    bx      lr
    .ltorg
ENDFUNC log_store_value

@ -----------------------------------------------------------------------------
@ log_start - start logging (long MEM, first press)
@ Replaces  : 0x080109EA FUN_080109EA (v2.05), called by log_toggle at 0x080165C4
@ In        : -
@ Out       : -
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads bat_low 0x2000803B, hold_stage2 0x20008050, range_manual 0x20008042, log_interval 0x2000022C; writes the
@             logging state (log_view_valid, log_count, log_total, log_blocks, log_row_no, log_row_no_start, log_file_seq,
@             log_new_file, log_write_request, log_limit_hit, log_closing, log_header_due, log_tick_count, log_second_flag,
@             log_take_request, setup_item, range_manual, range_manual_saved, rel_active, minmax_state, hold_active)
@ Spec      : v2.05 listing 0x080109EA..0x08010AF7; analysis/keys_setup.md (MEM long press)
@ Note      : with the low-battery flag set the start is refused: error code 20 (SdE20) and a display refresh.
@             Otherwise the meter is put in a fixed state: setup page 100, the range is frozen (range_manual saved in
@             range_manual_saved and set to 1, unless auto-hold stage 2 is on), REL, MIN/MAX and HOLD are cleared, and every
@             counter of the log is reset.  log_new_file = 1 makes the first session create a new file; because it is set
@             log_write_request is set as well, so the header is written at once.  The tick counter starts at interval - 1 so that
@             the first record is taken one second later.
@ -----------------------------------------------------------------------------
FUNC log_start
    push    {r7, lr}                        @ 080109EA push {r7, lr}
    @ low battery: refuse (error code 0x14 = 20)
    ldr.w   r0, =bat_low                    @ 080109EC r0 = &bat_low
    ldrb    r0, [r0]                        @ 080109F0 r0 = u8 [bat_low]
    cmp     r0, #0                          @ 080109F2 compare r0 with 0
    beq     .Llog_start_0A08                @ 080109F4 if (r0 == 0) goto 0x8010A08
    movs    r0, #0x14                       @ 080109F6 r0 = 0x14
    ldr.w   r1, =log_error_code             @ 080109F8 r1 = &log_error_code
    strb    r0, [r1]                        @ 080109FC u8 [log_error_code] = r0
    movs    r0, #1                          @ 080109FE r0 = 1
    ldr.w   r1, =ui_refresh_request         @ 08010A00 r1 = &ui_refresh_request
    strb    r0, [r1]                        @ 08010A04 u8 [ui_refresh_request] = r0
    b       .Llog_start_0AF6                @ 08010A06 goto 0x8010AF6
    @ setup item = 100 (0x64); the setup page code (SET module) reads it, its meaning is not examined here
.Llog_start_0A08:                       @ v2.05 0x08010A08, reached from 0x080109F4
    movs    r0, #0x64                       @ 08010A08 r0 = 0x64
    ldr.w   r1, =setup_item                 @ 08010A0A r1 = &setup_item
    strb    r0, [r1]                        @ 08010A0E u8 [setup_item] = r0
    @ unless auto-hold stage 2 is on: range_manual_saved = range_manual, range_manual = 1 (range frozen while logging)
    ldr.w   r0, =hold_stage2                @ 08010A10 r0 = &hold_stage2
    ldrb    r0, [r0]                        @ 08010A14 r0 = u8 [hold_stage2]
    cmp     r0, #0                          @ 08010A16 compare r0 with 0
    bne     .Llog_start_0A34                @ 08010A18 if (r0 != 0) goto 0x8010A34
    ldr.w   r0, =range_manual               @ 08010A1A r0 = &range_manual
    ldrb    r0, [r0]                        @ 08010A1E r0 = u8 [range_manual]
    ldr.w   r1, =range_manual_saved         @ 08010A20 r1 = &range_manual_saved
    strb    r0, [r1]                        @ 08010A24 u8 [range_manual_saved] = r0
    movs    r0, #1                          @ 08010A26 r0 = 1
    ldr.w   r1, =range_manual               @ 08010A28 r1 = &range_manual
    strb    r0, [r1]                        @ 08010A2C u8 [range_manual] = r0
    movs    r0, #1                          @ 08010A2E r0 = 1
    bl      fn_08019D68                     @ 08010A30 call fn_08019D68
    @ REL, MIN/MAX and HOLD off
.Llog_start_0A34:                       @ v2.05 0x08010A34, reached from 0x08010A18
    movs    r0, #0                          @ 08010A34 r0 = 0
    ldr.w   r1, =rel_active                 @ 08010A36 r1 = &rel_active
    strb    r0, [r1]                        @ 08010A3A u8 [rel_active] = r0
    movs    r0, #0                          @ 08010A3C r0 = 0
    ldr.w   r1, =minmax_state               @ 08010A3E r1 = &minmax_state
    strb    r0, [r1]                        @ 08010A42 u8 [minmax_state] = r0
    movs    r0, #0                          @ 08010A44 r0 = 0
    ldr.w   r1, =hold_active                @ 08010A46 r1 = &hold_active
    strb    r0, [r1]                        @ 08010A4A u8 [hold_active] = r0
    @ log_start_flag3 = 1 (no reader in LOG, meaning UNPROVEN), log_take_request = 0, mem_view_active = 0
    movs    r0, #1                          @ 08010A4C r0 = 1
    ldr.w   r1, =log_start_flag3            @ 08010A4E r1 = &log_start_flag3
    strb    r0, [r1]                        @ 08010A52 u8 [log_start_flag3] = r0
    movs    r0, #0                          @ 08010A54 r0 = 0
    ldr.w   r1, =log_take_request           @ 08010A56 r1 = &log_take_request
    strb    r0, [r1]                        @ 08010A5A u8 [log_take_request] = r0
    movs    r0, #0                          @ 08010A5C r0 = 0
    ldr.w   r1, =mem_view_active            @ 08010A5E r1 = &mem_view_active
    strb    r0, [r1]                        @ 08010A62 u8 [mem_view_active] = r0
    movs    r0, #0                          @ 08010A64 r0 = 0
    @ view window invalid, ring empty, counters zero
    ldr.w   r1, =log_view_valid             @ 08010A66 r1 = &log_view_valid
    strh    r0, [r1]                        @ 08010A6A u16 [log_view_valid] = r0
    movs    r0, #0                          @ 08010A6C r0 = 0
    ldr.w   r1, =log_count                  @ 08010A6E r1 = &log_count
    strh    r0, [r1]                        @ 08010A72 u16 [log_count] = r0
    movs    r0, #0                          @ 08010A74 r0 = 0
    ldr.w   r1, =log_total                  @ 08010A76 r1 = &log_total
    str     r0, [r1]                        @ 08010A7A u32 [log_total] = r0
    movs    r0, #0                          @ 08010A7C r0 = 0
    ldr.w   r1, =log_blocks                 @ 08010A7E r1 = &log_blocks
    str     r0, [r1]                        @ 08010A82 u32 [log_blocks] = r0
    @ a new file will be created; the first session must run, so log_write_request = log_new_file
    movs    r0, #1                          @ 08010A84 r0 = 1
    ldr.w   r1, =log_new_file               @ 08010A86 r1 = &log_new_file
    strb    r0, [r1]                        @ 08010A8A u8 [log_new_file] = r0
    ldr.w   r0, =log_new_file               @ 08010A8C r0 = &log_new_file
    ldrb    r0, [r0]                        @ 08010A90 r0 = u8 [log_new_file]
    cmp     r0, #0                          @ 08010A92 compare r0 with 0
    beq     .Llog_start_0AA0                @ 08010A94 if (r0 == 0) goto 0x8010AA0
    movs    r0, #1                          @ 08010A96 r0 = 1
    ldr.w   r1, =log_write_request          @ 08010A98 r1 = &log_write_request
    strb    r0, [r1]                        @ 08010A9C u8 [log_write_request] = r0
    b       .Llog_start_0AA8                @ 08010A9E goto 0x8010AA8
.Llog_start_0AA0:                       @ v2.05 0x08010AA0, reached from 0x08010A94
    movs    r0, #0                          @ 08010AA0 r0 = 0
    ldr.w   r1, =log_write_request          @ 08010AA2 r1 = &log_write_request
    strb    r0, [r1]                        @ 08010AA6 u8 [log_write_request] = r0
    @ log_limit_hit = 0, row counters zero, header due = 0, closing = 0, file sequence 0
.Llog_start_0AA8:                       @ v2.05 0x08010AA8, reached from 0x08010A9E
    movs    r0, #0                          @ 08010AA8 r0 = 0
    ldr.w   r1, =log_limit_hit              @ 08010AAA r1 = &log_limit_hit
    strb    r0, [r1]                        @ 08010AAE u8 [log_limit_hit] = r0
    movs    r0, #0                          @ 08010AB0 r0 = 0
    ldr.w   r1, =log_row_no_start           @ 08010AB2 r1 = &log_row_no_start
    str     r0, [r1]                        @ 08010AB6 u32 [log_row_no_start] = r0
    ldr.w   r1, =log_row_no                 @ 08010AB8 r1 = &log_row_no
    str     r0, [r1]                        @ 08010ABC u32 [log_row_no] = r0
    ldr.w   r1, =log_header_due             @ 08010ABE r1 = &log_header_due
    strb    r0, [r1]                        @ 08010AC2 u8 [log_header_due] = r0
    ldr.w   r0, =log_header_due             @ 08010AC4 r0 = &log_header_due
    ldrb    r0, [r0]                        @ 08010AC8 r0 = u8 [log_header_due]
    ldr.w   r1, =log_closing                @ 08010ACA r1 = &log_closing
    strb    r0, [r1]                        @ 08010ACE u8 [log_closing] = r0
    movs    r0, #0                          @ 08010AD0 r0 = 0
    ldr.w   r1, =log_file_seq               @ 08010AD2 r1 = &log_file_seq
    strh    r0, [r1]                        @ 08010AD6 u16 [log_file_seq] = r0
    bl      log_trig_reset                  @ IMP-21: a new session has no last record (r0, r1 only)
    @ log_tick_count = interval - 1 (u16, wraps when the interval is 0; the main loop treats interval 0 separately)
    ldr.w   r0, =log_interval               @ 08010AD8 r0 = &log_interval
    ldrh    r0, [r0]                        @ 08010ADC r0 = u16 [log_interval]
    subs    r0, r0, #1                      @ 08010ADE r0 = r0 - 1
    ldr.w   r1, =log_tick_count             @ 08010AE0 r1 = &log_tick_count
    strh    r0, [r1]                        @ 08010AE4 u16 [log_tick_count] = r0
    movs    r0, #0                          @ 08010AE6 r0 = 0
    ldr.w   r1, =log_second_flag            @ 08010AE8 r1 = &log_second_flag
    strb    r0, [r1]                        @ 08010AEC u8 [log_second_flag] = r0
    @ start time stamp: log_save_mode_range saves mode and range, log_save_stat_a the date and time
    bl      log_save_mode_range             @ 08010AEE call log_save_mode_range
    bl      log_save_stat_a                 @ 08010AF2 call log_save_stat_a
.Llog_start_0AF6:                       @ v2.05 0x08010AF6, reached from 0x08010A06
    pop     {r0, pc}                        @ 08010AF6 pop {r0, pc}
ENDFUNC log_start
    .ltorg

@ -----------------------------------------------------------------------------
@ log_stop - stop logging, write the pending records and restore the meter state
@ Replaces  : 0x08010AF8 FUN_08010AF8 (v2.05), called by log_toggle (0x080165CC), meter_apply_mode_range (0x0800D47C) and log_session_once
@ In        : r0 = 1 write the pending records now (log_write_session), 0 do not write
@ Out       : -
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads hold_stage2 0x20008050, range_manual_saved 0x20008043; writes log_pending, log_closing, log_new_file,
@             range_manual 0x20008042; calls fn_0800D718 (default setup item), the save and view routines of this file and, with
@             r0 = 1, log_write_session
@ Spec      : v2.05 listing 0x08010AF8..0x08010B63
@ Note      : pending = ring count when the ring holds 1..59 unwritten records; a full ring has set log_pending to 60 already.
@             log_closing = 1 makes the next session append the minimum and maximum rows.  The range freeze of log_start is undone
@             (range_manual = range_manual_saved) unless auto-hold stage 2 is on.
@ -----------------------------------------------------------------------------
FUNC log_stop
    push    {r4, lr}                        @ 08010AF8 push {r4, lr}
    movs    r4, r0                          @ 08010AFA r4 = r0
    @ setup page back to its default item (SET module), then save counters and the stop time stamp
    bl      fn_0800D718                     @ 08010AFC call fn_0800D718
    bl      log_save_counters               @ 08010B00 call log_save_counters
    bl      log_save_stat_b                 @ 08010B04 call log_save_stat_b
    @ 1..59 records in the ring are all pending
    ldr.w   r0, =log_count                  @ 08010B08 r0 = &log_count
    ldrh    r0, [r0]                        @ 08010B0C r0 = u16 [log_count]
    cmp     r0, #0                          @ 08010B0E compare r0 with 0
    beq     .Llog_stop_0B28                 @ 08010B10 if (r0 == 0) goto 0x8010B28
    ldr.w   r0, =log_count                  @ 08010B12 r0 = &log_count
    ldrh    r0, [r0]                        @ 08010B16 r0 = u16 [log_count]
    cmp     r0, #0x3c                       @ 08010B18 compare r0 with 0x3c
    bge     .Llog_stop_0B28                 @ 08010B1A if (r0 >= 0x3c) goto 0x8010B28
    ldr.w   r0, =log_count                  @ 08010B1C r0 = &log_count
    ldrh    r0, [r0]                        @ 08010B20 r0 = u16 [log_count]
    ldr.w   r1, =log_pending                @ 08010B22 r1 = &log_pending
    str     r0, [r1]                        @ 08010B26 u32 [log_pending] = r0
    @ closing = 1, new file = 0
.Llog_stop_0B28:                        @ v2.05 0x08010B28, reached from 0x08010B10, 0x08010B1A
    movs    r0, #1                          @ 08010B28 r0 = 1
    ldr.w   r1, =log_closing                @ 08010B2A r1 = &log_closing
    strb    r0, [r1]                        @ 08010B2E u8 [log_closing] = r0
    movs    r0, #0                          @ 08010B30 r0 = 0
    ldr.w   r1, =log_new_file               @ 08010B32 r1 = &log_new_file
    strb    r0, [r1]                        @ 08010B36 u8 [log_new_file] = r0
    @ r0 = 1: write now (the session retries the SD card up to 40 times, files.s)
    uxtb    r4, r4                          @ 08010B38 r4 = u8(r4)
    cmp     r4, #1                          @ 08010B3A compare r4 with 1
    bne     .Llog_stop_0B42                 @ 08010B3C if (r4 != 1) goto 0x8010B42
    bl      log_write_session               @ 08010B3E call log_write_session
    @ rebuild the window used by the MEM view
.Llog_stop_0B42:                        @ v2.05 0x08010B42, reached from 0x08010B3C
    bl      log_set_view_window             @ 08010B42 call log_set_view_window
    @ undo the range freeze
    ldr.w   r0, =hold_stage2                @ 08010B46 r0 = &hold_stage2
    ldrb    r0, [r0]                        @ 08010B4A r0 = u8 [hold_stage2]
    cmp     r0, #0                          @ 08010B4C compare r0 with 0
    bne     .Llog_stop_0B62                 @ 08010B4E if (r0 != 0) goto 0x8010B62
    ldr.w   r0, =range_manual_saved         @ 08010B50 r0 = &range_manual_saved
    ldrb    r0, [r0]                        @ 08010B54 r0 = u8 [range_manual_saved]
    ldr.w   r1, =range_manual               @ 08010B56 r1 = &range_manual
    strb    r0, [r1]                        @ 08010B5A u8 [range_manual] = r0
    movs    r0, #1                          @ 08010B5C r0 = 1
    bl      fn_08019D68                     @ 08010B5E call fn_08019D68
.Llog_stop_0B62:                        @ v2.05 0x08010B62, reached from 0x08010B4E
    pop     {r4, pc}                        @ 08010B62 pop {r4, pc}
ENDFUNC log_stop
    .global fn_08010AF8
    .thumb_set fn_08010AF8, log_stop
    .ltorg

@ -----------------------------------------------------------------------------
@ log_take_record - copy the current record into the next ring slot
@ Replaces  : 0x08010B64 FUN_08010B64 (v2.05), called by the main loop at 0x08024D4A (step 10)
@ In        : -
@ Out       : -
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads/writes log_count 0x20007FA4, log_total 0x20007D38; writes log_take_request, log_write_request,
@             log_pending, ui_refresh_request
@ Spec      : v2.05 listing 0x08010B64..0x08010BC9
@ Note      : the slot index wraps at 60.  When the 60th slot is filled the ring is complete: a write is requested and all 60
@             records are pending.
@ -----------------------------------------------------------------------------
FUNC log_take_record
    push    {r7, lr}                        @ 08010B64 push {r7, lr}
    bl      log_trig_taken                  @ IMP-21: the level of this record for the tr-Ch change test
    movs    r0, #0                          @ 08010B66 r0 = 0
    ldr.w   r1, =log_take_request           @ 08010B68 r1 = &log_take_request
    @ request flag cleared; the ring index restarts at 0 when it has reached 60
    strb    r0, [r1]                        @ 08010B6C u8 [log_take_request] = r0
    ldr.w   r0, =log_count                  @ 08010B6E r0 = &log_count
    ldrh    r0, [r0]                        @ 08010B72 r0 = u16 [log_count]
    cmp     r0, #0x3c                       @ 08010B74 compare r0 with 0x3c
    blt     .Llog_take_record_0B80          @ 08010B76 if (r0 < 0x3c) goto 0x8010B80
    movs    r0, #0                          @ 08010B78 r0 = 0
    ldr.w   r1, =log_count                  @ 08010B7A r1 = &log_count
    strh    r0, [r1]                        @ 08010B7E u16 [log_count] = r0
.Llog_take_record_0B80:                 @ v2.05 0x08010B80, reached from 0x08010B76
    ldr.w   r0, =log_count                  @ 08010B80 r0 = &log_count
    ldrh    r0, [r0]                        @ 08010B84 r0 = u16 [log_count]
    @ store the current record in slot log_count, then advance
    bl      log_slot_store                  @ 08010B86 call log_slot_store
    ldr.w   r0, =log_count                  @ 08010B8A r0 = &log_count
    ldrh    r0, [r0]                        @ 08010B8E r0 = u16 [log_count]
    adds    r0, r0, #1                      @ 08010B90 r0 = r0 + 1
    ldr.w   r1, =log_count                  @ 08010B92 r1 = &log_count
    strh    r0, [r1]                        @ 08010B96 u16 [log_count] = r0
    ldr.w   r0, =log_count                  @ 08010B98 r0 = &log_count
    ldrh    r0, [r0]                        @ 08010B9C r0 = u16 [log_count]
    cmp     r0, #0x3c                       @ 08010B9E compare r0 with 0x3c
    @ ring full: ask for the SD write and mark 60 records pending
    blt     .Llog_take_record_0BB2          @ 08010BA0 if (r0 < 0x3c) goto 0x8010BB2
    movs    r0, #1                          @ 08010BA2 r0 = 1
    ldr.w   r1, =log_write_request          @ 08010BA4 r1 = &log_write_request
    strb    r0, [r1]                        @ 08010BA8 u8 [log_write_request] = r0
    movs    r0, #0x3c                       @ 08010BAA r0 = 0x3c
    ldr.w   r1, =log_pending                @ 08010BAC r1 = &log_pending
    str     r0, [r1]                        @ 08010BB0 u32 [log_pending] = r0
    @ one more record in total; the display is refreshed
.Llog_take_record_0BB2:                 @ v2.05 0x08010BB2, reached from 0x08010BA0
    ldr.w   r0, =log_total                  @ 08010BB2 r0 = &log_total
    ldr     r0, [r0]                        @ 08010BB6 r0 = u32 [log_total]
    adds    r0, r0, #1                      @ 08010BB8 r0 = r0 + 1
    ldr.w   r1, =log_total                  @ 08010BBA r1 = &log_total
    str     r0, [r1]                        @ 08010BBE u32 [log_total] = r0
    movs    r0, #1                          @ 08010BC0 r0 = 1
    ldr.w   r1, =ui_refresh_request         @ 08010BC2 r1 = &ui_refresh_request
    strb    r0, [r1]                        @ 08010BC6 u8 [ui_refresh_request] = r0
    pop     {r0, pc}                        @ 08010BC8 pop {r0, pc}
ENDFUNC log_take_record
    .global fn_08010B64
    .thumb_set fn_08010B64, log_take_record
    .ltorg

@ -----------------------------------------------------------------------------
@ log_save_counters - remember the ring count and the total record count at the end of a log
@ Replaces  : 0x08010BCA FUN_08010BCA (v2.05), called by log_stop
@ In        : -
@ Out       : -
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_count, log_total; writes log_count_saved 0x20007FAC, log_total_saved 0x20007D3C
@ Spec      : v2.05 listing 0x08010BCA..0x08010BE7 (the constant 0x4B0 loaded into r0 at 0x08010BCA is not used)
@ Note      : the first instruction loads a constant that nothing uses; it is kept so that the routine is the v2.05 routine.
@ -----------------------------------------------------------------------------
FUNC log_save_counters
    mov.w   r0, #0x4b0                      @ 08010BCA r0 = 0x4b0
    ldr.w   r1, =log_count                  @ 08010BCE r1 = &log_count
    ldrh    r1, [r1]                        @ 08010BD2 r1 = u16 [log_count]
    ldr.w   r2, =log_count_saved            @ 08010BD4 r2 = &log_count_saved
    strh    r1, [r2]                        @ 08010BD8 u16 [log_count_saved] = r1
    ldr.w   r1, =log_total                  @ 08010BDA r1 = &log_total
    ldr     r1, [r1]                        @ 08010BDE r1 = u32 [log_total]
    ldr.w   r2, =log_total_saved            @ 08010BE0 r2 = &log_total_saved
    str     r1, [r2]                        @ 08010BE4 u32 [log_total_saved] = r1
    bx      lr                              @ 08010BE6 return
ENDFUNC log_save_counters
    .ltorg

@ -----------------------------------------------------------------------------
@ log_restore_counters - restore the ring count and the total after a power cycle, drop them when implausible
@ Replaces  : 0x08010BE8 FUN_08010BE8 (v2.05), called by set_state_reset (0x08024E26)
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only (start-up and wake-up)
@ RAM       : reads log_count_saved, log_total_saved; writes log_count, log_total; then log_set_view_window
@ Spec      : v2.05 listing 0x08010BE8..0x08010C33
@ Note      : a count above 60 or a total of 600000 or more is taken as invalid RAM content and both are set to 0.
@ -----------------------------------------------------------------------------
FUNC log_restore_counters
    push    {r4, lr}                        @ 08010BE8 push {r4, lr}
    mov.w   r4, #0x4b0                      @ 08010BEA r4 = 0x4b0
    ldr.w   r0, =log_count_saved            @ 08010BEE r0 = &log_count_saved
    ldrh    r0, [r0]                        @ 08010BF2 r0 = u16 [log_count_saved]
    ldr.w   r1, =log_count                  @ 08010BF4 r1 = &log_count
    strh    r0, [r1]                        @ 08010BF8 u16 [log_count] = r0
    ldr.w   r0, =log_total_saved            @ 08010BFA r0 = &log_total_saved
    ldr     r0, [r0]                        @ 08010BFE r0 = u32 [log_total_saved]
    ldr.w   r1, =log_total                  @ 08010C00 r1 = &log_total
    str     r0, [r1]                        @ 08010C04 u32 [log_total] = r0
    ldr.w   r0, =log_count                  @ 08010C06 r0 = &log_count
    @ the saved values are only kept when 0 <= count <= 60 and total < 0x927C0 = 600000
    ldrh    r0, [r0]                        @ 08010C0A r0 = u16 [log_count]
    cmp     r0, #0x3d                       @ 08010C0C compare r0 with 0x3d
    bge     .Llog_restore_counters_0C1E     @ 08010C0E if (r0 >= 0x3d) goto 0x8010C1E
    ldr.w   r0, =log_total                  @ 08010C10 r0 = &log_total
    ldr     r0, [r0]                        @ 08010C14 r0 = u32 [log_total]
    ldr.w   r1, =0x000927C0                 @ 08010C16 r1 = 0x927C0
    cmp     r0, r1                          @ 08010C1A compare r0 with r1
    blo     .Llog_restore_counters_0C2E     @ 08010C1C if (r0 <u r1) goto 0x8010C2E
.Llog_restore_counters_0C1E:            @ v2.05 0x08010C1E, reached from 0x08010C0E
    movs    r0, #0                          @ 08010C1E r0 = 0
    ldr.w   r1, =log_count                  @ 08010C20 r1 = &log_count
    strh    r0, [r1]                        @ 08010C24 u16 [log_count] = r0
    movs    r0, #0                          @ 08010C26 r0 = 0
    ldr.w   r1, =log_total                  @ 08010C28 r1 = &log_total
    str     r0, [r1]                        @ 08010C2C u32 [log_total] = r0
.Llog_restore_counters_0C2E:            @ v2.05 0x08010C2E, reached from 0x08010C1C
    bl      log_set_view_window             @ 08010C2E call log_set_view_window
    pop     {r4, pc}                        @ 08010C32 pop {r4, pc}
ENDFUNC log_restore_counters
    .global fn_08010BE8
    .thumb_set fn_08010BE8, log_restore_counters
    .ltorg

@ -----------------------------------------------------------------------------
@ log_set_view_window - describe the window of stored records that the MEM view can step through
@ Replaces  : 0x08010C34 FUN_08010C34 (v2.05), called by log_stop and log_restore_counters
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_total 0x20007D38, log_count 0x20007FA4; writes log_view_first 0x20007FA0, log_view_newest 0x20007FA2,
@             log_view_len 0x20007F9E, log_view_valid 0x20007F9C
@ Spec      : v2.05 listing 0x08010C34..0x08010C8B
@ Note      : while fewer than 61 records were taken the window is the first log_count slots (positions 1..count).  After the ring
@             has wrapped (total >= 61) it holds 60 records, the oldest at position log_count + 1.
@ -----------------------------------------------------------------------------
FUNC log_set_view_window
    ldr.w   r0, =log_total                  @ 08010C34 r0 = &log_total
    ldr     r0, [r0]                        @ 08010C38 r0 = u32 [log_total]
    cmp     r0, #0x3d                       @ 08010C3A compare r0 with 0x3d
    @ total >= 61: the ring has wrapped; oldest = count + 1, newest = count, length 60
    blo     .Llog_set_view_window_0C62      @ 08010C3C if (r0 <u 0x3d) goto 0x8010C62
    ldr.w   r0, =log_count                  @ 08010C3E r0 = &log_count
    ldrh    r0, [r0]                        @ 08010C42 r0 = u16 [log_count]
    adds    r0, r0, #1                      @ 08010C44 r0 = r0 + 1
    ldr.w   r1, =log_view_first             @ 08010C46 r1 = &log_view_first
    strh    r0, [r1]                        @ 08010C4A u16 [log_view_first] = r0
    ldr.w   r0, =log_count                  @ 08010C4C r0 = &log_count
    ldrh    r0, [r0]                        @ 08010C50 r0 = u16 [log_count]
    ldr.w   r1, =log_view_newest            @ 08010C52 r1 = &log_view_newest
    strh    r0, [r1]                        @ 08010C56 u16 [log_view_newest] = r0
    movs    r0, #0x3c                       @ 08010C58 r0 = 0x3c
    ldr.w   r1, =log_view_len               @ 08010C5A r1 = &log_view_len
    strh    r0, [r1]                        @ 08010C5E u16 [log_view_len] = r0
    b       .Llog_set_view_window_0C82      @ 08010C60 goto 0x8010C82
    @ total <= 60: oldest = 1, newest = count, length = count
.Llog_set_view_window_0C62:             @ v2.05 0x08010C62, reached from 0x08010C3C
    movs    r0, #1                          @ 08010C62 r0 = 1
    ldr.w   r1, =log_view_first             @ 08010C64 r1 = &log_view_first
    strh    r0, [r1]                        @ 08010C68 u16 [log_view_first] = r0
    ldr.w   r0, =log_count                  @ 08010C6A r0 = &log_count
    ldrh    r0, [r0]                        @ 08010C6E r0 = u16 [log_count]
    ldr.w   r1, =log_view_newest            @ 08010C70 r1 = &log_view_newest
    strh    r0, [r1]                        @ 08010C74 u16 [log_view_newest] = r0
    ldr.w   r0, =log_count                  @ 08010C76 r0 = &log_count
    ldrh    r0, [r0]                        @ 08010C7A r0 = u16 [log_count]
    ldr.w   r1, =log_view_len               @ 08010C7C r1 = &log_view_len
    strh    r0, [r1]                        @ 08010C80 u16 [log_view_len] = r0
    @ the window is valid
.Llog_set_view_window_0C82:             @ v2.05 0x08010C82, reached from 0x08010C60
    movs    r0, #1                          @ 08010C82 r0 = 1
    ldr.w   r1, =log_view_valid             @ 08010C84 r1 = &log_view_valid
    strh    r0, [r1]                        @ 08010C88 u16 [log_view_valid] = r0
    bx      lr                              @ 08010C8A return
ENDFUNC log_set_view_window
    .ltorg

@ -----------------------------------------------------------------------------
@ log_view_index - map a position of the MEM view to a ring position
@ Replaces  : 0x08010C8C FUN_08010C8C (v2.05), called by the MEM view (0x080170C0)
@ In        : r0 = position n in the window (u16, 1 = oldest)
@ Out       : r0 = first + n - 1, minus the window length when that exceeds it (u16): the 1-based ring position of the n-th record
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_view_len 0x20007F9E, log_view_first 0x20007FA0
@ Spec      : v2.05 listing 0x08010C8C..0x08010CCB; the comparison is signed (blt/bge on halfword values)
@ Note      : the caller subtracts one where it needs a 0-based slot index (log_slot_load takes a 0-based index; not examined here).
@ -----------------------------------------------------------------------------
FUNC log_view_index
    movs    r1, r0                          @ 08010C8C r1 = r0
    movs    r0, #0                          @ 08010C8E r0 = 0
    ldr.w   r2, =log_view_len               @ 08010C90 r2 = &log_view_len
    ldrh    r2, [r2]                        @ 08010C94 r2 = u16 [log_view_len]
    uxth    r1, r1                          @ 08010C96 r1 = u16(r1)
    ldr.w   r3, =log_view_first             @ 08010C98 r3 = &log_view_first
    ldrh    r3, [r3]                        @ 08010C9C r3 = u16 [log_view_first]
    adds    r3, r3, r1                      @ 08010C9E r3 = r3 + r1
    subs    r3, r3, #1                      @ 08010CA0 r3 = r3 - 1
    cmp     r2, r3                          @ 08010CA2 compare r2 with r3
    bge     .Llog_view_index_0CBC           @ 08010CA4 if (r2 >= r3) goto 0x8010CBC
    ldr.w   r2, =log_view_first             @ 08010CA6 r2 = &log_view_first
    ldrh    r2, [r2]                        @ 08010CAA r2 = u16 [log_view_first]
    adds    r2, r2, r1                      @ 08010CAC r2 = r2 + r1
    subs    r2, r2, #1                      @ 08010CAE r2 = r2 - 1
    ldr.w   r3, =log_view_len               @ 08010CB0 r3 = &log_view_len
    ldrh    r3, [r3]                        @ 08010CB4 r3 = u16 [log_view_len]
    subs    r2, r2, r3                      @ 08010CB6 r2 = r2 - r3
    movs    r0, r2                          @ 08010CB8 r0 = r2
    b       .Llog_view_index_0CC8           @ 08010CBA goto 0x8010CC8
.Llog_view_index_0CBC:                  @ v2.05 0x08010CBC, reached from 0x08010CA4
    ldr.w   r2, =log_view_first             @ 08010CBC r2 = &log_view_first
    ldrh    r2, [r2]                        @ 08010CC0 r2 = u16 [log_view_first]
    adds    r2, r2, r1                      @ 08010CC2 r2 = r2 + r1
    subs    r2, r2, #1                      @ 08010CC4 r2 = r2 - 1
    movs    r0, r2                          @ 08010CC6 r0 = r2
.Llog_view_index_0CC8:                  @ v2.05 0x08010CC8, reached from 0x08010CBA
    uxth    r0, r0                          @ 08010CC8 r0 = u16(r0)
    bx      lr                              @ 08010CCA return
ENDFUNC log_view_index
    .global fn_08010C8C
    .thumb_set fn_08010C8C, log_view_index
    .ltorg

@ -----------------------------------------------------------------------------
@ log_save_mode_range - remember the meter mode and range of the log
@ Replaces  : 0x08010CCC FUN_08010CCC (v2.05), called by log_start
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads meter_mode 0x2000803C, meter_range 0x2000803D; writes log_mode_saved 0x2000800D, log_range_saved 0x2000800E
@ Spec      : v2.05 listing 0x08010CCC..0x08010CE1
@ -----------------------------------------------------------------------------
FUNC log_save_mode_range
    ldr     r0, =meter_mode                 @ 08010CCC r0 = &meter_mode
    ldrb    r0, [r0]                        @ 08010CCE r0 = u8 [meter_mode]
    ldr.w   r1, =log_mode_saved             @ 08010CD0 r1 = &log_mode_saved
    strb    r0, [r1]                        @ 08010CD4 u8 [log_mode_saved] = r0
    ldr     r0, =meter_range                @ 08010CD6 r0 = &meter_range
    ldrb    r0, [r0]                        @ 08010CD8 r0 = u8 [meter_range]
    ldr.w   r1, =log_range_saved            @ 08010CDA r1 = &log_range_saved
    strb    r0, [r1]                        @ 08010CDE u8 [log_range_saved] = r0
    bx      lr                              @ 08010CE0 return
ENDFUNC log_save_mode_range
    .ltorg

@ -----------------------------------------------------------------------------
@ log_restore_mode_range - copy the saved mode and range to the variables the MEM view reads
@ Replaces  : 0x08010CE2 FUN_08010CE2 (v2.05), called by the MEM key handler (0x08014ED8)
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_mode_saved 0x2000800D, log_range_saved 0x2000800E; writes log_mode_shown 0x20007FEB, log_range_shown 0x20007FEC
@ Spec      : v2.05 listing 0x08010CE2..0x08010CFB
@ -----------------------------------------------------------------------------
FUNC log_restore_mode_range
    ldr.w   r0, =log_mode_saved             @ 08010CE2 r0 = &log_mode_saved
    ldrb    r0, [r0]                        @ 08010CE6 r0 = u8 [log_mode_saved]
    ldr.w   r1, =log_mode_shown             @ 08010CE8 r1 = &log_mode_shown
    strb    r0, [r1]                        @ 08010CEC u8 [log_mode_shown] = r0
    ldr.w   r0, =log_range_saved            @ 08010CEE r0 = &log_range_saved
    ldrb    r0, [r0]                        @ 08010CF2 r0 = u8 [log_range_saved]
    ldr.w   r1, =log_range_shown            @ 08010CF4 r1 = &log_range_shown
    strb    r0, [r1]                        @ 08010CF8 u8 [log_range_shown] = r0
    bx      lr                              @ 08010CFA return
ENDFUNC log_restore_mode_range
    .global fn_08010CE2
    .thumb_set fn_08010CE2, log_restore_mode_range
    .ltorg

@ -----------------------------------------------------------------------------
@ log_save_stat_a - take the start time stamp of the log (and a backup copy)
@ Replaces  : 0x08010CFC FUN_08010CFC (v2.05), called by log_start
@ In        : -
@ Out       : -
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads rtc_year..rtc_second 0x200080D7..0x200080DC; writes log_start_year..second 0x20007FFB..0x20008000 and the
@             backup log_start_year_bak..second_bak 0x2000800F..0x20008014
@ Spec      : v2.05 listing 0x08010CFC..0x08010D91 (the constant 0x4C0 loaded into r0 at 0x08010CFC is not used)
@ Note      : the START line of the CSV header prints 0x20007FFB..0x20008000 (log_write_csv_token tokens 0x66 and 0x67).
@ -----------------------------------------------------------------------------
FUNC log_save_stat_a
    mov.w   r0, #0x4c0                      @ 08010CFC r0 = 0x4c0
    ldr.w   r1, =rtc_year                   @ 08010D00 r1 = &rtc_year
    ldrb    r1, [r1]                        @ 08010D04 r1 = u8 [rtc_year]
    ldr.w   r2, =log_start_year             @ 08010D06 r2 = &log_start_year
    strb    r1, [r2]                        @ 08010D0A u8 [log_start_year] = r1
    ldr.w   r1, =rtc_month                  @ 08010D0C r1 = &rtc_month
    ldrb    r1, [r1]                        @ 08010D10 r1 = u8 [rtc_month]
    ldr.w   r2, =log_start_month            @ 08010D12 r2 = &log_start_month
    strb    r1, [r2]                        @ 08010D16 u8 [log_start_month] = r1
    ldr.w   r1, =rtc_day                    @ 08010D18 r1 = &rtc_day
    ldrb    r1, [r1]                        @ 08010D1C r1 = u8 [rtc_day]
    ldr.w   r2, =log_start_day              @ 08010D1E r2 = &log_start_day
    strb    r1, [r2]                        @ 08010D22 u8 [log_start_day] = r1
    ldr.w   r1, =rtc_hour                   @ 08010D24 r1 = &rtc_hour
    ldrb    r1, [r1]                        @ 08010D28 r1 = u8 [rtc_hour]
    ldr.w   r2, =log_start_hour             @ 08010D2A r2 = &log_start_hour
    strb    r1, [r2]                        @ 08010D2E u8 [log_start_hour] = r1
    ldr.w   r1, =rtc_minute                 @ 08010D30 r1 = &rtc_minute
    ldrb    r1, [r1]                        @ 08010D34 r1 = u8 [rtc_minute]
    ldr.w   r2, =log_start_minute           @ 08010D36 r2 = &log_start_minute
    strb    r1, [r2]                        @ 08010D3A u8 [log_start_minute] = r1
    ldr.w   r1, =rtc_second                 @ 08010D3C r1 = &rtc_second
    ldrb    r1, [r1]                        @ 08010D40 r1 = u8 [rtc_second]
    ldr.w   r2, =log_start_second           @ 08010D42 r2 = &log_start_second
    strb    r1, [r2]                        @ 08010D46 u8 [log_start_second] = r1
    ldr.w   r1, =rtc_year                   @ 08010D48 r1 = &rtc_year
    ldrb    r1, [r1]                        @ 08010D4C r1 = u8 [rtc_year]
    ldr.w   r2, =log_start_year_bak         @ 08010D4E r2 = &log_start_year_bak
    strb    r1, [r2]                        @ 08010D52 u8 [log_start_year_bak] = r1
    ldr.w   r1, =rtc_month                  @ 08010D54 r1 = &rtc_month
    ldrb    r1, [r1]                        @ 08010D58 r1 = u8 [rtc_month]
    ldr.w   r2, =log_start_month_bak        @ 08010D5A r2 = &log_start_month_bak
    strb    r1, [r2]                        @ 08010D5E u8 [log_start_month_bak] = r1
    ldr.w   r1, =rtc_day                    @ 08010D60 r1 = &rtc_day
    ldrb    r1, [r1]                        @ 08010D64 r1 = u8 [rtc_day]
    ldr.w   r2, =log_start_day_bak          @ 08010D66 r2 = &log_start_day_bak
    strb    r1, [r2]                        @ 08010D6A u8 [log_start_day_bak] = r1
    ldr.w   r1, =rtc_hour                   @ 08010D6C r1 = &rtc_hour
    ldrb    r1, [r1]                        @ 08010D70 r1 = u8 [rtc_hour]
    ldr.w   r2, =log_start_hour_bak         @ 08010D72 r2 = &log_start_hour_bak
    strb    r1, [r2]                        @ 08010D76 u8 [log_start_hour_bak] = r1
    ldr.w   r1, =rtc_minute                 @ 08010D78 r1 = &rtc_minute
    ldrb    r1, [r1]                        @ 08010D7C r1 = u8 [rtc_minute]
    ldr.w   r2, =log_start_minute_bak       @ 08010D7E r2 = &log_start_minute_bak
    strb    r1, [r2]                        @ 08010D82 u8 [log_start_minute_bak] = r1
    ldr.w   r1, =rtc_second                 @ 08010D84 r1 = &rtc_second
    ldrb    r1, [r1]                        @ 08010D88 r1 = u8 [rtc_second]
    ldr.w   r2, =log_start_second_bak       @ 08010D8A r2 = &log_start_second_bak
    strb    r1, [r2]                        @ 08010D8E u8 [log_start_second_bak] = r1
    bx      lr                              @ 08010D90 return
ENDFUNC log_save_stat_a
    .ltorg

@ -----------------------------------------------------------------------------
@ log_restore_stat_a - copy the start time stamp back from its backup
@ Replaces  : 0x08010D92 FUN_08010D92 (v2.05), called by the MEM key handler (0x08014EEA)
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_start_*_bak 0x2000800F..0x20008014; writes log_start_* 0x20007FFB..0x20008000
@ Spec      : v2.05 listing 0x08010D92..0x08010DDB
@ -----------------------------------------------------------------------------
FUNC log_restore_stat_a
    ldr.w   r0, =log_start_year_bak         @ 08010D92 r0 = &log_start_year_bak
    ldrb    r0, [r0]                        @ 08010D96 r0 = u8 [log_start_year_bak]
    ldr.w   r1, =log_start_year             @ 08010D98 r1 = &log_start_year
    strb    r0, [r1]                        @ 08010D9C u8 [log_start_year] = r0
    ldr.w   r0, =log_start_month_bak        @ 08010D9E r0 = &log_start_month_bak
    ldrb    r0, [r0]                        @ 08010DA2 r0 = u8 [log_start_month_bak]
    ldr.w   r1, =log_start_month            @ 08010DA4 r1 = &log_start_month
    strb    r0, [r1]                        @ 08010DA8 u8 [log_start_month] = r0
    ldr.w   r0, =log_start_day_bak          @ 08010DAA r0 = &log_start_day_bak
    ldrb    r0, [r0]                        @ 08010DAE r0 = u8 [log_start_day_bak]
    ldr.w   r1, =log_start_day              @ 08010DB0 r1 = &log_start_day
    strb    r0, [r1]                        @ 08010DB4 u8 [log_start_day] = r0
    ldr.w   r0, =log_start_hour_bak         @ 08010DB6 r0 = &log_start_hour_bak
    ldrb    r0, [r0]                        @ 08010DBA r0 = u8 [log_start_hour_bak]
    ldr.w   r1, =log_start_hour             @ 08010DBC r1 = &log_start_hour
    strb    r0, [r1]                        @ 08010DC0 u8 [log_start_hour] = r0
    ldr.w   r0, =log_start_minute_bak       @ 08010DC2 r0 = &log_start_minute_bak
    ldrb    r0, [r0]                        @ 08010DC6 r0 = u8 [log_start_minute_bak]
    ldr.w   r1, =log_start_minute           @ 08010DC8 r1 = &log_start_minute
    strb    r0, [r1]                        @ 08010DCC u8 [log_start_minute] = r0
    ldr.w   r0, =log_start_second_bak       @ 08010DCE r0 = &log_start_second_bak
    ldrb    r0, [r0]                        @ 08010DD2 r0 = u8 [log_start_second_bak]
    ldr.w   r1, =log_start_second           @ 08010DD4 r1 = &log_start_second
    strb    r0, [r1]                        @ 08010DD8 u8 [log_start_second] = r0
    bx      lr                              @ 08010DDA return
ENDFUNC log_restore_stat_a
    .global fn_08010D92
    .thumb_set fn_08010D92, log_restore_stat_a
    .ltorg

@ -----------------------------------------------------------------------------
@ log_save_stat_b - take the stop time stamp of the log (and a backup copy)
@ Replaces  : 0x08010DE0 FUN_08010DE0 (v2.05), called by log_stop
@ In        : -
@ Out       : -
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads rtc_year..rtc_second; writes log_stop_year..second 0x20008001..0x20008006 and the backup 0x20008015..0x2000801A
@ Spec      : v2.05 listing 0x08010DE0..0x08010E75
@ -----------------------------------------------------------------------------
FUNC log_save_stat_b
    movw    r0, #0x4c6                      @ 08010DE0
    ldr.w   r1, =rtc_year                   @ 08010DE4 r1 = &rtc_year
    ldrb    r1, [r1]                        @ 08010DE8 r1 = u8 [rtc_year]
    ldr.w   r2, =log_stop_year              @ 08010DEA r2 = &log_stop_year
    strb    r1, [r2]                        @ 08010DEE u8 [log_stop_year] = r1
    ldr.w   r1, =rtc_month                  @ 08010DF0 r1 = &rtc_month
    ldrb    r1, [r1]                        @ 08010DF4 r1 = u8 [rtc_month]
    ldr.w   r2, =log_stop_month             @ 08010DF6 r2 = &log_stop_month
    strb    r1, [r2]                        @ 08010DFA u8 [log_stop_month] = r1
    ldr.w   r1, =rtc_day                    @ 08010DFC r1 = &rtc_day
    ldrb    r1, [r1]                        @ 08010E00 r1 = u8 [rtc_day]
    ldr.w   r2, =log_stop_day               @ 08010E02 r2 = &log_stop_day
    strb    r1, [r2]                        @ 08010E06 u8 [log_stop_day] = r1
    ldr.w   r1, =rtc_hour                   @ 08010E08 r1 = &rtc_hour
    ldrb    r1, [r1]                        @ 08010E0C r1 = u8 [rtc_hour]
    ldr.w   r2, =log_stop_hour              @ 08010E0E r2 = &log_stop_hour
    strb    r1, [r2]                        @ 08010E12 u8 [log_stop_hour] = r1
    ldr.w   r1, =rtc_minute                 @ 08010E14 r1 = &rtc_minute
    ldrb    r1, [r1]                        @ 08010E18 r1 = u8 [rtc_minute]
    ldr.w   r2, =log_stop_minute            @ 08010E1A r2 = &log_stop_minute
    strb    r1, [r2]                        @ 08010E1E u8 [log_stop_minute] = r1
    ldr.w   r1, =rtc_second                 @ 08010E20 r1 = &rtc_second
    ldrb    r1, [r1]                        @ 08010E24 r1 = u8 [rtc_second]
    ldr.w   r2, =log_stop_second            @ 08010E26 r2 = &log_stop_second
    strb    r1, [r2]                        @ 08010E2A u8 [log_stop_second] = r1
    ldr.w   r1, =log_stop_year              @ 08010E2C r1 = &log_stop_year
    ldrb    r1, [r1]                        @ 08010E30 r1 = u8 [log_stop_year]
    ldr.w   r2, =log_stop_year_bak          @ 08010E32 r2 = &log_stop_year_bak
    strb    r1, [r2]                        @ 08010E36 u8 [log_stop_year_bak] = r1
    ldr.w   r1, =log_stop_month             @ 08010E38 r1 = &log_stop_month
    ldrb    r1, [r1]                        @ 08010E3C r1 = u8 [log_stop_month]
    ldr.w   r2, =log_stop_month_bak         @ 08010E3E r2 = &log_stop_month_bak
    strb    r1, [r2]                        @ 08010E42 u8 [log_stop_month_bak] = r1
    ldr.w   r1, =log_stop_day               @ 08010E44 r1 = &log_stop_day
    ldrb    r1, [r1]                        @ 08010E48 r1 = u8 [log_stop_day]
    ldr.w   r2, =log_stop_day_bak           @ 08010E4A r2 = &log_stop_day_bak
    strb    r1, [r2]                        @ 08010E4E u8 [log_stop_day_bak] = r1
    ldr.w   r1, =log_stop_hour              @ 08010E50 r1 = &log_stop_hour
    ldrb    r1, [r1]                        @ 08010E54 r1 = u8 [log_stop_hour]
    ldr.w   r2, =log_stop_hour_bak          @ 08010E56 r2 = &log_stop_hour_bak
    strb    r1, [r2]                        @ 08010E5A u8 [log_stop_hour_bak] = r1
    ldr.w   r1, =log_stop_minute            @ 08010E5C r1 = &log_stop_minute
    ldrb    r1, [r1]                        @ 08010E60 r1 = u8 [log_stop_minute]
    ldr.w   r2, =log_stop_minute_bak        @ 08010E62 r2 = &log_stop_minute_bak
    strb    r1, [r2]                        @ 08010E66 u8 [log_stop_minute_bak] = r1
    ldr.w   r1, =log_stop_second            @ 08010E68 r1 = &log_stop_second
    ldrb    r1, [r1]                        @ 08010E6C r1 = u8 [log_stop_second]
    ldr.w   r2, =log_stop_second_bak        @ 08010E6E r2 = &log_stop_second_bak
    strb    r1, [r2]                        @ 08010E72 u8 [log_stop_second_bak] = r1
    bx      lr                              @ 08010E74 return
ENDFUNC log_save_stat_b
    .ltorg

@ -----------------------------------------------------------------------------
@ log_restore_stat_b - copy the stop time stamp back from its backup
@ Replaces  : 0x08010E98 FUN_08010E98 (v2.05), called by the MEM key handler (0x08014EEE)
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_stop_*_bak 0x20008015..0x2000801A; writes log_stop_* 0x20008001..0x20008006
@ Spec      : v2.05 listing 0x08010E98..0x08010EE1
@ -----------------------------------------------------------------------------
FUNC log_restore_stat_b
    ldr.w   r0, =log_stop_year_bak          @ 08010E98 r0 = &log_stop_year_bak
    ldrb    r0, [r0]                        @ 08010E9C r0 = u8 [log_stop_year_bak]
    ldr.w   r1, =log_stop_year              @ 08010E9E r1 = &log_stop_year
    strb    r0, [r1]                        @ 08010EA2 u8 [log_stop_year] = r0
    ldr.w   r0, =log_stop_month_bak         @ 08010EA4 r0 = &log_stop_month_bak
    ldrb    r0, [r0]                        @ 08010EA8 r0 = u8 [log_stop_month_bak]
    ldr.w   r1, =log_stop_month             @ 08010EAA r1 = &log_stop_month
    strb    r0, [r1]                        @ 08010EAE u8 [log_stop_month] = r0
    ldr.w   r0, =log_stop_day_bak           @ 08010EB0 r0 = &log_stop_day_bak
    ldrb    r0, [r0]                        @ 08010EB4 r0 = u8 [log_stop_day_bak]
    ldr.w   r1, =log_stop_day               @ 08010EB6 r1 = &log_stop_day
    strb    r0, [r1]                        @ 08010EBA u8 [log_stop_day] = r0
    ldr.w   r0, =log_stop_hour_bak          @ 08010EBC r0 = &log_stop_hour_bak
    ldrb    r0, [r0]                        @ 08010EC0 r0 = u8 [log_stop_hour_bak]
    ldr.w   r1, =log_stop_hour              @ 08010EC2 r1 = &log_stop_hour
    strb    r0, [r1]                        @ 08010EC6 u8 [log_stop_hour] = r0
    ldr.w   r0, =log_stop_minute_bak        @ 08010EC8 r0 = &log_stop_minute_bak
    ldrb    r0, [r0]                        @ 08010ECC r0 = u8 [log_stop_minute_bak]
    ldr.w   r1, =log_stop_minute            @ 08010ECE r1 = &log_stop_minute
    strb    r0, [r1]                        @ 08010ED2 u8 [log_stop_minute] = r0
    ldr.w   r0, =log_stop_second_bak        @ 08010ED4 r0 = &log_stop_second_bak
    ldrb    r0, [r0]                        @ 08010ED8 r0 = u8 [log_stop_second_bak]
    ldr.w   r1, =log_stop_second            @ 08010EDA r1 = &log_stop_second
    strb    r0, [r1]                        @ 08010EDE u8 [log_stop_second] = r0
    bx      lr                              @ 08010EE0 return
ENDFUNC log_restore_stat_b
    .global fn_08010E98
    .thumb_set fn_08010E98, log_restore_stat_b
    .ltorg

@ -----------------------------------------------------------------------------
@ log_slot_store - store the current record in ring slot r0
@ Replaces  : 0x08010EF4 FUN_08010EF4 (v2.05), called by log_take_record
@ In        : r0 = slot index 0..59 (u16)
@ Out       : -
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08010EF4..0x08010F01; passes the halfword to log_slot_store_body
@ -----------------------------------------------------------------------------
FUNC log_slot_store
    push    {r4, lr}                        @ 08010EF4 push {r4, lr}
    movs    r4, r0                          @ 08010EF6 r4 = r0
    movs    r0, r4                          @ 08010EF8 r0 = r4
    uxth    r0, r0                          @ 08010EFA r0 = u16(r0)
    bl      log_slot_store_body             @ 08010EFC call log_slot_store_body
    pop     {r4, pc}                        @ 08010F00 pop {r4, pc}
ENDFUNC log_slot_store
    .ltorg

@ -----------------------------------------------------------------------------
@ log_slot_load - load ring slot r0 into the "loaded record" variables
@ Replaces  : 0x08010F02 FUN_08010F02 (v2.05), called by the MEM view (0x080170CA) and log_write_row
@ In        : r0 = slot index 0..59 (u16)
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08010F02..0x08010F0F; passes the halfword to log_slot_load_body
@ -----------------------------------------------------------------------------
FUNC log_slot_load
    push    {r4, lr}                        @ 08010F02 push {r4, lr}
    movs    r4, r0                          @ 08010F04 r4 = r0
    movs    r0, r4                          @ 08010F06 r0 = r4
    uxth    r0, r0                          @ 08010F08 r0 = u16(r0)
    bl      log_slot_load_body              @ 08010F0A call log_slot_load_body
    pop     {r4, pc}                        @ 08010F0E pop {r4, pc}
ENDFUNC log_slot_load
    .global fn_08010F02
    .thumb_set fn_08010F02, log_slot_load
    .ltorg

@ -----------------------------------------------------------------------------
@ log_slot_store_body - copy the 15 variables of the current record into slot r0 of the 15 ring arrays
@ Replaces  : 0x0801217C FUN_0801217C (v2.05)
@ In        : r0 = slot index (u16; v2.05 does not check it, the callers keep it below 60)
@ Out       : -
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads rtc_year..rtc_second 0x200080D7..0x200080DC, log_rec_func1/flags1/value1, func2/flags2/value2, func3/flags3/value3;
@             writes the 15 ring arrays log_slot_year ... log_slot_value3 at index r0 (u8 arrays, u32 arrays for the values)
@ Spec      : v2.05 listing 0x0801217C..0x08012219
@ -----------------------------------------------------------------------------
FUNC log_slot_store_body
    @ time stamp: year, month, day, hour, minute, second into six byte arrays
    ldr     r1, =rtc_year                   @ 0801217C r1 = &rtc_year
    ldrb    r1, [r1]                        @ 0801217E r1 = u8 [rtc_year]
    ldr     r2, =log_slot_year              @ 08012180 r2 = &log_slot_year
    uxth    r0, r0                          @ 08012182 r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 08012184 u8 [log_slot_year+r0] = r1
    ldr     r1, =rtc_month                  @ 08012186 r1 = &rtc_month
    ldrb    r1, [r1]                        @ 08012188 r1 = u8 [rtc_month]
    ldr     r2, =log_slot_month             @ 0801218A r2 = &log_slot_month
    uxth    r0, r0                          @ 0801218C r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 0801218E u8 [log_slot_month+r0] = r1
    ldr     r1, =rtc_day                    @ 08012190 r1 = &rtc_day
    ldrb    r1, [r1]                        @ 08012192 r1 = u8 [rtc_day]
    ldr     r2, =log_slot_day               @ 08012194 r2 = &log_slot_day
    uxth    r0, r0                          @ 08012196 r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 08012198 u8 [log_slot_day+r0] = r1
    ldr     r1, =rtc_hour                   @ 0801219A r1 = &rtc_hour
    ldrb    r1, [r1]                        @ 0801219C r1 = u8 [rtc_hour]
    ldr     r2, =log_slot_hour              @ 0801219E r2 = &log_slot_hour
    uxth    r0, r0                          @ 080121A0 r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 080121A2 u8 [log_slot_hour+r0] = r1
    ldr     r1, =rtc_minute                 @ 080121A4 r1 = &rtc_minute
    ldrb    r1, [r1]                        @ 080121A6 r1 = u8 [rtc_minute]
    ldr     r2, =log_slot_minute            @ 080121A8 r2 = &log_slot_minute
    uxth    r0, r0                          @ 080121AA r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 080121AC u8 [log_slot_minute+r0] = r1
    ldr     r1, =rtc_second                 @ 080121AE r1 = &rtc_second
    ldrb    r1, [r1]                        @ 080121B0 r1 = u8 [rtc_second]
    ldr     r2, =log_slot_second            @ 080121B2 r2 = &log_slot_second
    uxth    r0, r0                          @ 080121B4 r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 080121B6 u8 [log_slot_second+r0] = r1
    @ main reading: function code and flags (byte arrays), value (word array)
    ldr     r1, =log_rec_func1              @ 080121B8 r1 = &log_rec_func1
    ldrb    r1, [r1]                        @ 080121BA r1 = u8 [log_rec_func1]
    ldr     r2, =log_slot_func1             @ 080121BC r2 = &log_slot_func1
    uxth    r0, r0                          @ 080121BE r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 080121C0 u8 [log_slot_func1+r0] = r1
    ldr     r1, =log_rec_flags1             @ 080121C2 r1 = &log_rec_flags1
    ldrb    r1, [r1]                        @ 080121C4 r1 = u8 [log_rec_flags1]
    ldr     r2, =log_slot_flags1            @ 080121C6 r2 = &log_slot_flags1
    uxth    r0, r0                          @ 080121C8 r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 080121CA u8 [log_slot_flags1+r0] = r1
    ldr     r1, =log_rec_value1             @ 080121CC r1 = &log_rec_value1
    ldr     r1, [r1]                        @ 080121CE r1 = u32 [log_rec_value1]
    ldr     r2, =log_slot_value1            @ 080121D0 r2 = &log_slot_value1
    uxth    r0, r0                          @ 080121D2 r0 = u16(r0)
    str.w   r1, [r2, r0, lsl #2]            @ 080121D4 u32 [log_slot_value1+r0*4] = r1
    ldr     r1, =log_rec_func2              @ 080121D8 r1 = &log_rec_func2
    ldrb    r1, [r1]                        @ 080121DA r1 = u8 [log_rec_func2]
    ldr     r2, =log_slot_func2             @ 080121DC r2 = &log_slot_func2
    uxth    r0, r0                          @ 080121DE r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 080121E0 u8 [log_slot_func2+r0] = r1
    ldr     r1, =log_rec_flags2             @ 080121E2 r1 = &log_rec_flags2
    ldrb    r1, [r1]                        @ 080121E4 r1 = u8 [log_rec_flags2]
    ldr     r2, =log_slot_flags2            @ 080121E6 r2 = &log_slot_flags2
    uxth    r0, r0                          @ 080121E8 r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 080121EA u8 [log_slot_flags2+r0] = r1
    ldr     r1, =log_rec_value2             @ 080121EC r1 = &log_rec_value2
    ldr     r1, [r1]                        @ 080121EE r1 = u32 [log_rec_value2]
    ldr     r2, =log_slot_value2            @ 080121F0 r2 = &log_slot_value2
    uxth    r0, r0                          @ 080121F2 r0 = u16(r0)
    str.w   r1, [r2, r0, lsl #2]            @ 080121F4 u32 [log_slot_value2+r0*4] = r1
    @ second reading, then third reading, in the same order
    ldr     r1, =log_rec_func3              @ 080121F8 r1 = &log_rec_func3
    ldrb    r1, [r1]                        @ 080121FA r1 = u8 [log_rec_func3]
    ldr     r2, =log_slot_func3             @ 080121FC r2 = &log_slot_func3
    uxth    r0, r0                          @ 080121FE r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 08012200 u8 [log_slot_func3+r0] = r1
    ldr     r1, =log_rec_flags3             @ 08012202 r1 = &log_rec_flags3
    ldrb    r1, [r1]                        @ 08012204 r1 = u8 [log_rec_flags3]
    ldr     r2, =log_slot_flags3            @ 08012206 r2 = &log_slot_flags3
    uxth    r0, r0                          @ 08012208 r0 = u16(r0)
    strb    r1, [r2, r0]                    @ 0801220A u8 [log_slot_flags3+r0] = r1
    ldr     r1, =log_rec_value3             @ 0801220C r1 = &log_rec_value3
    ldr     r1, [r1]                        @ 0801220E r1 = u32 [log_rec_value3]
    ldr     r2, =log_slot_value3            @ 08012210 r2 = &log_slot_value3
    uxth    r0, r0                          @ 08012212 r0 = u16(r0)
    str.w   r1, [r2, r0, lsl #2]            @ 08012214 u32 [log_slot_value3+r0*4] = r1
    bx      lr                              @ 08012218 return
ENDFUNC log_slot_store_body
    .ltorg

@ -----------------------------------------------------------------------------
@ log_slot_load_body - copy slot r0 of the ring arrays into the "loaded record" variables and split function codes and flag bits
@ Replaces  : 0x08012260 FUN_08012260 (v2.05)
@ In        : r0 = slot index (u16)
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads the 15 ring arrays at index r0; writes log_view_year..second 0x20008007..0x2000800C, log_view_func1/flags1/value1,
@             log_view_mode1/range1, log_view_flag0..5 (0x20007FE5..0x20007FEA), the same for readings 2 and 3
@ Spec      : v2.05 listing 0x08012260..0x080123ED
@ Note      : a function code packs mode + 32 * range, so mode = code & 0x1F and range = code >> 5.  The six flag bits of the
@             main reading become one byte each (0 or 1) in log_view_flag0..5.
@ -----------------------------------------------------------------------------
FUNC log_slot_load_body
    @ time stamp
    ldr     r2, =log_slot_year              @ 08012260 r2 = &log_slot_year
    uxth    r0, r0                          @ 08012262 r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 08012264 r2 = u8 [log_slot_year+r0]
    ldr     r3, =log_view_year              @ 08012266 r3 = &log_view_year
    strb    r2, [r3]                        @ 08012268 u8 [log_view_year] = r2
    ldr     r2, =log_slot_month             @ 0801226A r2 = &log_slot_month
    uxth    r0, r0                          @ 0801226C r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 0801226E r2 = u8 [log_slot_month+r0]
    ldr     r3, =log_view_month             @ 08012270 r3 = &log_view_month
    strb    r2, [r3]                        @ 08012272 u8 [log_view_month] = r2
    ldr     r2, =log_slot_day               @ 08012274 r2 = &log_slot_day
    uxth    r0, r0                          @ 08012276 r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 08012278 r2 = u8 [log_slot_day+r0]
    ldr     r3, =log_view_day               @ 0801227A r3 = &log_view_day
    strb    r2, [r3]                        @ 0801227C u8 [log_view_day] = r2
    ldr     r2, =log_slot_hour              @ 0801227E r2 = &log_slot_hour
    uxth    r0, r0                          @ 08012280 r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 08012282 r2 = u8 [log_slot_hour+r0]
    ldr     r3, =log_view_hour              @ 08012284 r3 = &log_view_hour
    strb    r2, [r3]                        @ 08012286 u8 [log_view_hour] = r2
    ldr     r2, =log_slot_minute            @ 08012288 r2 = &log_slot_minute
    uxth    r0, r0                          @ 0801228A r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 0801228C r2 = u8 [log_slot_minute+r0]
    ldr     r3, =log_view_minute            @ 0801228E r3 = &log_view_minute
    strb    r2, [r3]                        @ 08012290 u8 [log_view_minute] = r2
    ldr     r2, =log_slot_second            @ 08012292 r2 = &log_slot_second
    uxth    r0, r0                          @ 08012294 r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 08012296 r2 = u8 [log_slot_second+r0]
    ldr     r3, =log_view_second            @ 08012298 r3 = &log_view_second
    strb    r2, [r3]                        @ 0801229A u8 [log_view_second] = r2
    @ main reading: function code, mode and range, flags, flag bits
    ldr     r2, =log_slot_func1             @ 0801229C r2 = &log_slot_func1
    uxth    r0, r0                          @ 0801229E r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 080122A0 r2 = u8 [log_slot_func1+r0]
    ldr     r3, =log_view_func1             @ 080122A2 r3 = &log_view_func1
    strb    r2, [r3]                        @ 080122A4 u8 [log_view_func1] = r2
    ldr     r2, =log_view_func1             @ 080122A6 r2 = &log_view_func1
    ldrb    r2, [r2]                        @ 080122A8 r2 = u8 [log_view_func1]
    ands    r2, r2, #0x1f                   @ 080122AA r2 = r2 & 0x1f
    ldr     r3, =log_view_mode1             @ 080122AE r3 = &log_view_mode1
    strb    r2, [r3]                        @ 080122B0 u8 [log_view_mode1] = r2
    ldr     r2, =log_view_func1             @ 080122B2 r2 = &log_view_func1
    ldrb    r2, [r2]                        @ 080122B4 r2 = u8 [log_view_func1]
    uxtb    r2, r2                          @ 080122B6 r2 = u8(r2)
    lsrs    r2, r2, #5                      @ 080122B8 r2 = r2 >> 5
    ldr     r3, =log_view_range1            @ 080122BA r3 = &log_view_range1
    strb    r2, [r3]                        @ 080122BC u8 [log_view_range1] = r2
    ldr     r2, =log_slot_flags1            @ 080122BE r2 = &log_slot_flags1
    uxth    r0, r0                          @ 080122C0 r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 080122C2 r2 = u8 [log_slot_flags1+r0]
    ldr     r3, =log_view_flags1            @ 080122C4 r3 = &log_view_flags1
    strb    r2, [r3]                        @ 080122C6 u8 [log_view_flags1] = r2
    movs    r2, #0                          @ 080122C8 r2 = 0
    ldr     r3, =log_view_flag0             @ 080122CA r3 = &log_view_flag0
    strb    r2, [r3]                        @ 080122CC u8 [log_view_flag0] = r2
    ldr     r2, =log_view_flags1            @ 080122CE r2 = &log_view_flags1
    ldrb    r2, [r2]                        @ 080122D0 r2 = u8 [log_view_flags1]
    ands    r2, r2, #1                      @ 080122D2 r2 = r2 & 1
    movs    r1, r2                          @ 080122D6 r1 = r2
    uxtb    r1, r1                          @ 080122D8 r1 = u8(r1)
    cmp     r1, #0                          @ 080122DA compare r1 with 0
    beq     .Llog_slot_load_body_22E4       @ 080122DC if (r1 == 0) goto 0x80122E4
    movs    r2, #1                          @ 080122DE r2 = 1
    ldr     r3, =log_view_flag0             @ 080122E0 r3 = &log_view_flag0
    strb    r2, [r3]                        @ 080122E2 u8 [log_view_flag0] = r2
.Llog_slot_load_body_22E4:              @ v2.05 0x080122E4, reached from 0x080122DC
    movs    r2, #0                          @ 080122E4 r2 = 0
    ldr     r3, =log_view_flag1             @ 080122E6 r3 = &log_view_flag1
    strb    r2, [r3]                        @ 080122E8 u8 [log_view_flag1] = r2
    ldr     r2, =log_view_flags1            @ 080122EA r2 = &log_view_flags1
    ldrb    r2, [r2]                        @ 080122EC r2 = u8 [log_view_flags1]
    ands    r2, r2, #2                      @ 080122EE r2 = r2 & 2
    movs    r1, r2                          @ 080122F2 r1 = r2
    uxtb    r1, r1                          @ 080122F4 r1 = u8(r1)
    cmp     r1, #0                          @ 080122F6 compare r1 with 0
    beq     .Llog_slot_load_body_2300       @ 080122F8 if (r1 == 0) goto 0x8012300
    movs    r2, #1                          @ 080122FA r2 = 1
    ldr     r3, =log_view_flag1             @ 080122FC r3 = &log_view_flag1
    strb    r2, [r3]                        @ 080122FE u8 [log_view_flag1] = r2
.Llog_slot_load_body_2300:              @ v2.05 0x08012300, reached from 0x080122F8
    movs    r2, #0                          @ 08012300 r2 = 0
    ldr     r3, =log_view_flag2             @ 08012302 r3 = &log_view_flag2
    strb    r2, [r3]                        @ 08012304 u8 [log_view_flag2] = r2
    ldr     r2, =log_view_flags1            @ 08012306 r2 = &log_view_flags1
    ldrb    r2, [r2]                        @ 08012308 r2 = u8 [log_view_flags1]
    ands    r2, r2, #4                      @ 0801230A r2 = r2 & 4
    movs    r1, r2                          @ 0801230E r1 = r2
    uxtb    r1, r1                          @ 08012310 r1 = u8(r1)
    cmp     r1, #0                          @ 08012312 compare r1 with 0
    beq     .Llog_slot_load_body_231C       @ 08012314 if (r1 == 0) goto 0x801231C
    movs    r2, #1                          @ 08012316 r2 = 1
    ldr     r3, =log_view_flag2             @ 08012318 r3 = &log_view_flag2
    strb    r2, [r3]                        @ 0801231A u8 [log_view_flag2] = r2
.Llog_slot_load_body_231C:              @ v2.05 0x0801231C, reached from 0x08012314
    movs    r2, #0                          @ 0801231C r2 = 0
    ldr     r3, =log_view_flag3             @ 0801231E r3 = &log_view_flag3
    strb    r2, [r3]                        @ 08012320 u8 [log_view_flag3] = r2
    ldr     r2, =log_view_flags1            @ 08012322 r2 = &log_view_flags1
    ldrb    r2, [r2]                        @ 08012324 r2 = u8 [log_view_flags1]
    ands    r2, r2, #8                      @ 08012326 r2 = r2 & 8
    movs    r1, r2                          @ 0801232A r1 = r2
    uxtb    r1, r1                          @ 0801232C r1 = u8(r1)
    cmp     r1, #0                          @ 0801232E compare r1 with 0
    beq     .Llog_slot_load_body_2338       @ 08012330 if (r1 == 0) goto 0x8012338
    movs    r2, #1                          @ 08012332 r2 = 1
    ldr     r3, =log_view_flag3             @ 08012334 r3 = &log_view_flag3
    strb    r2, [r3]                        @ 08012336 u8 [log_view_flag3] = r2
.Llog_slot_load_body_2338:              @ v2.05 0x08012338, reached from 0x08012330
    movs    r2, #0                          @ 08012338 r2 = 0
    ldr     r3, =log_view_flag4             @ 0801233A r3 = &log_view_flag4
    strb    r2, [r3]                        @ 0801233C u8 [log_view_flag4] = r2
    ldr     r2, =log_view_flags1            @ 0801233E r2 = &log_view_flags1
    ldrb    r2, [r2]                        @ 08012340 r2 = u8 [log_view_flags1]
    ands    r2, r2, #0x10                   @ 08012342 r2 = r2 & 0x10
    movs    r1, r2                          @ 08012346 r1 = r2
    uxtb    r1, r1                          @ 08012348 r1 = u8(r1)
    cmp     r1, #0                          @ 0801234A compare r1 with 0
    beq     .Llog_slot_load_body_2354       @ 0801234C if (r1 == 0) goto 0x8012354
    movs    r2, #1                          @ 0801234E r2 = 1
    ldr     r3, =log_view_flag4             @ 08012350 r3 = &log_view_flag4
    strb    r2, [r3]                        @ 08012352 u8 [log_view_flag4] = r2
.Llog_slot_load_body_2354:              @ v2.05 0x08012354, reached from 0x0801234C
    movs    r2, #0                          @ 08012354 r2 = 0
    ldr     r3, =log_view_flag5             @ 08012356 r3 = &log_view_flag5
    strb    r2, [r3]                        @ 08012358 u8 [log_view_flag5] = r2
    ldr     r2, =log_view_flags1            @ 0801235A r2 = &log_view_flags1
    ldrb    r2, [r2]                        @ 0801235C r2 = u8 [log_view_flags1]
    ands    r2, r2, #0x20                   @ 0801235E r2 = r2 & 0x20
    movs    r1, r2                          @ 08012362 r1 = r2
    uxtb    r1, r1                          @ 08012364 r1 = u8(r1)
    cmp     r1, #0                          @ 08012366 compare r1 with 0
    beq     .Llog_slot_load_body_2370       @ 08012368 if (r1 == 0) goto 0x8012370
    movs    r2, #1                          @ 0801236A r2 = 1
    ldr     r3, =log_view_flag5             @ 0801236C r3 = &log_view_flag5
    strb    r2, [r3]                        @ 0801236E u8 [log_view_flag5] = r2
    @ main value
.Llog_slot_load_body_2370:              @ v2.05 0x08012370, reached from 0x08012368
    ldr     r2, =log_slot_value1            @ 08012370 r2 = &log_slot_value1
    uxth    r0, r0                          @ 08012372 r0 = u16(r0)
    ldr.w   r2, [r2, r0, lsl #2]            @ 08012374 r2 = u32 [log_slot_value1+r0*4]
    ldr     r3, =log_view_value1            @ 08012378 r3 = &log_view_value1
    str     r2, [r3]                        @ 0801237A u32 [log_view_value1] = r2
    @ second reading: function code, mode, range, flags, value
    ldr     r2, =log_slot_func2             @ 0801237C r2 = &log_slot_func2
    uxth    r0, r0                          @ 0801237E r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 08012380 r2 = u8 [log_slot_func2+r0]
    ldr     r3, =log_view_func2             @ 08012382 r3 = &log_view_func2
    strb    r2, [r3]                        @ 08012384 u8 [log_view_func2] = r2
    ldr     r2, =log_view_func2             @ 08012386 r2 = &log_view_func2
    ldrb    r2, [r2]                        @ 08012388 r2 = u8 [log_view_func2]
    ands    r2, r2, #0x1f                   @ 0801238A r2 = r2 & 0x1f
    ldr     r3, =log_view_mode2             @ 0801238E r3 = &log_view_mode2
    strb    r2, [r3]                        @ 08012390 u8 [log_view_mode2] = r2
    ldr     r2, =log_view_func2             @ 08012392 r2 = &log_view_func2
    ldrb    r2, [r2]                        @ 08012394 r2 = u8 [log_view_func2]
    uxtb    r2, r2                          @ 08012396 r2 = u8(r2)
    lsrs    r2, r2, #5                      @ 08012398 r2 = r2 >> 5
    ldr     r3, =log_view_range2            @ 0801239A r3 = &log_view_range2
    strb    r2, [r3]                        @ 0801239C u8 [log_view_range2] = r2
    ldr     r2, =log_slot_flags2            @ 0801239E r2 = &log_slot_flags2
    uxth    r0, r0                          @ 080123A0 r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 080123A2 r2 = u8 [log_slot_flags2+r0]
    ldr     r3, =log_view_flags2            @ 080123A4 r3 = &log_view_flags2
    strb    r2, [r3]                        @ 080123A6 u8 [log_view_flags2] = r2
    ldr     r2, =log_slot_value2            @ 080123A8 r2 = &log_slot_value2
    uxth    r0, r0                          @ 080123AA r0 = u16(r0)
    ldr.w   r2, [r2, r0, lsl #2]            @ 080123AC r2 = u32 [log_slot_value2+r0*4]
    ldr     r3, =log_view_value2            @ 080123B0 r3 = &log_view_value2
    str     r2, [r3]                        @ 080123B2 u32 [log_view_value2] = r2
    @ third reading: function code, mode, range, flags, value
    ldr     r2, =log_slot_func3             @ 080123B4 r2 = &log_slot_func3
    uxth    r0, r0                          @ 080123B6 r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 080123B8 r2 = u8 [log_slot_func3+r0]
    ldr     r3, =log_view_func3             @ 080123BA r3 = &log_view_func3
    strb    r2, [r3]                        @ 080123BC u8 [log_view_func3] = r2
    ldr     r2, =log_view_func3             @ 080123BE r2 = &log_view_func3
    ldrb    r2, [r2]                        @ 080123C0 r2 = u8 [log_view_func3]
    ands    r2, r2, #0x1f                   @ 080123C2 r2 = r2 & 0x1f
    ldr     r3, =log_view_mode3             @ 080123C6 r3 = &log_view_mode3
    strb    r2, [r3]                        @ 080123C8 u8 [log_view_mode3] = r2
    ldr     r2, =log_view_func3             @ 080123CA r2 = &log_view_func3
    ldrb    r2, [r2]                        @ 080123CC r2 = u8 [log_view_func3]
    uxtb    r2, r2                          @ 080123CE r2 = u8(r2)
    lsrs    r2, r2, #5                      @ 080123D0 r2 = r2 >> 5
    ldr     r3, =log_view_range3            @ 080123D2 r3 = &log_view_range3
    strb    r2, [r3]                        @ 080123D4 u8 [log_view_range3] = r2
    ldr     r2, =log_slot_flags3            @ 080123D6 r2 = &log_slot_flags3
    uxth    r0, r0                          @ 080123D8 r0 = u16(r0)
    ldrb    r2, [r2, r0]                    @ 080123DA r2 = u8 [log_slot_flags3+r0]
    ldr     r3, =log_view_flags3            @ 080123DC r3 = &log_view_flags3
    strb    r2, [r3]                        @ 080123DE u8 [log_view_flags3] = r2
    ldr     r2, =log_slot_value3            @ 080123E0 r2 = &log_slot_value3
    uxth    r0, r0                          @ 080123E2 r0 = u16(r0)
    ldr.w   r2, [r2, r0, lsl #2]            @ 080123E4 r2 = u32 [log_slot_value3+r0*4]
    ldr     r3, =log_view_value3            @ 080123E8 r3 = &log_view_value3
    str     r2, [r3]                        @ 080123EA u32 [log_view_value3] = r2
    bx      lr                              @ 080123EC return
ENDFUNC log_slot_load_body
    .ltorg

@ -----------------------------------------------------------------------------
@ log_toggle - toggle logging (long press of MEM)
@ Replaces  : 0x0801657C FUN_0801657C (v2.05), called by the long-press handler at 0x08016270 and 0x0801650E
@ In        : r0 = 1 clear HOLD/MIN-MAX/REL state as well when logging starts (the MEM+HOLD combination), 0 for MEM alone
@ Out       : -
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads/writes log_active 0x20007FE1; reads hold_stage2 0x20008050
@ Spec      : v2.05 listing 0x0801657C..0x080165E1; analysis/keys_setup.md (MEM long press, MEM+HOLD)
@ Note      : calls fn_0801584C(log_active, 1) when r0 != 0 or auto-hold stage 2 is on (HOLD state and MIN/MAX/REL cleared,
@             FUNC module), then log_start or log_stop(1), the display routines fn_08019C5C(0) and fn_0801A32A(1) and the long
@             beep fn_0800EE5E.
@ -----------------------------------------------------------------------------
FUNC log_toggle
    push    {r4, lr}                        @ 0801657C push {r4, lr}
    @ r4 = argument; log_active = 1 - log_active
    movs    r4, r0                          @ 0801657E r4 = r0
    ldr.w   r0, =log_active                 @ 08016580 r0 = &log_active
    ldrb    r0, [r0]                        @ 08016584 r0 = u8 [log_active]
    teq.w   r0, #1                          @ 08016586 compare r0 with 1
    beq     .Llog_toggle_6596               @ 0801658A if ((r0 ^ 1) == 0) goto 0x8016596
    movs    r0, #1                          @ 0801658C r0 = 1
    ldr.w   r1, =log_active                 @ 0801658E r1 = &log_active
    strb    r0, [r1]                        @ 08016592 u8 [log_active] = r0
    b       .Llog_toggle_659E               @ 08016594 goto 0x801659E
.Llog_toggle_6596:                      @ v2.05 0x08016596, reached from 0x0801658A
    movs    r0, #0                          @ 08016596 r0 = 0
    ldr.w   r1, =log_active                 @ 08016598 r1 = &log_active
    strb    r0, [r1]                        @ 0801659C u8 [log_active] = r0
    @ clear the measurement state when asked to, or when auto-hold stage 2 is on
.Llog_toggle_659E:                      @ v2.05 0x0801659E, reached from 0x08016594
    uxtb    r4, r4                          @ 0801659E r4 = u8(r4)
    cmp     r4, #0                          @ 080165A0 compare r4 with 0
    bne     .Llog_toggle_65AE               @ 080165A2 if (r4 != 0) goto 0x80165AE
    ldr.w   r0, =hold_stage2                @ 080165A4 r0 = &hold_stage2
    ldrb    r0, [r0]                        @ 080165A8 r0 = u8 [hold_stage2]
    cmp     r0, #0                          @ 080165AA compare r0 with 0
    beq     .Llog_toggle_65BA               @ 080165AC if (r0 == 0) goto 0x80165BA
.Llog_toggle_65AE:                      @ v2.05 0x080165AE, reached from 0x080165A2
    movs    r1, #1                          @ 080165AE r1 = 1
    ldr.w   r0, =log_active                 @ 080165B0 r0 = &log_active
    ldrb    r0, [r0]                        @ 080165B4 r0 = u8 [log_active]
    bl      fn_0801584C                     @ 080165B6 call fn_0801584C
    @ start or stop the log
.Llog_toggle_65BA:                      @ v2.05 0x080165BA, reached from 0x080165AC
    ldr.w   r0, =log_active                 @ 080165BA r0 = &log_active
    ldrb    r0, [r0]                        @ 080165BE r0 = u8 [log_active]
    cmp     r0, #0                          @ 080165C0 compare r0 with 0
    beq     .Llog_toggle_65CA               @ 080165C2 if (r0 == 0) goto 0x80165CA
    bl      log_start                       @ 080165C4 call log_start
    b       .Llog_toggle_65D0               @ 080165C8 goto 0x80165D0
.Llog_toggle_65CA:                      @ v2.05 0x080165CA, reached from 0x080165C2
    movs    r0, #1                          @ 080165CA r0 = 1
    bl      log_stop                        @ 080165CC call log_stop
    @ refresh the display and give the long-press beep
.Llog_toggle_65D0:                      @ v2.05 0x080165D0, reached from 0x080165C8
    movs    r0, #0                          @ 080165D0 r0 = 0
    bl      fn_08019C5C                     @ 080165D2 call fn_08019C5C
    movs    r0, #1                          @ 080165D6 r0 = 1
    bl      fn_0801A32A                     @ 080165D8 call fn_0801A32A
    bl      fn_0800EE5E                     @ 080165DC call fn_0800EE5E
    pop     {r4, pc}                        @ 080165E0 pop {r4, pc}
ENDFUNC log_toggle
    .global fn_0801657C
    .thumb_set fn_0801657C, log_toggle
    .ltorg

