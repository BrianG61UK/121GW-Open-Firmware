@ files.s - LOG module: the SD session, log file names, directory scan, record flush and read-back verification (DESIGN.md 6.22, W8)
@
@ v2.05 behaviour in outline (listing 0x0801D126..0x0801DB93 and 0x0801F604..0x0801F82F).  One session (log_session_once)
@ = switch SYSCLK to HSE, bring the card up, mount, then either open the existing log file and seek to its end
@ (log_open_and_seek) or choose a name and create a new file (log_select_file), flush the pending rows
@ (log_flush_records), close the file or set its time stamp (log_set_file_time), read the file back and compare it with
@ the bytes that were written (log_verify_file), handle the end of the log (600000 rows or low battery), write the
@ minimum and maximum rows when the log is closing, power the card off and return to the run clock.
@ A failed session is repeated by log_write_step (below, 20 + 20 attempts).
@
@ File names are YYMMDDnn.csv: year, month, day of the RTC and a two-digit number nn (log_build_dated_name).  The number
@ is the highest nn found for today in the root directory plus one (log_scan_directory), 0 when 100 or more exist.  After a
@ failed series of attempts a "forced" file is started whose name is derived from the previous name and log_file_seq
@ (log_build_suffix_name).
@
@ Everything is as in v2.05, including the CSV bytes written; the only change in this file is the form of
@ log_write_session (state machine, IMP-06).
@

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "ff16x.inc"

    .section .text.log, "ax", %progbits

@ names of the v2.05 variables used in this file (addresses unchanged, DESIGN.md 5.1)
    .equ log_buf,                 v_20001240            @ 0x20001240 byte buffer in which one flush of rows is assembled before f_write (also the cal.bin buffer)
    .equ fat_fs_obj,              ff16_fatfs            @ FATFS work area of drive 0 (production: R0.16 exFAT FATFS, 572 bytes, in .bss_port, IMP-32; v2.05: 0x20006830)
    .equ log_fil,                 ff16_fil_a            @ production image: FatFs R0.16 objects (FIL 552 bytes, DIR 44: larger than the v2.05 areas) in .bss_port (ff16_api.s, IMP-29)
    .equ log_fil_new,             ff16_fil_b
    .equ log_verify_buf,          v_20006EA8            @ 0x20006EA8 0x200-byte read-back buffer of log_verify_file (also cal.bin read-back)
    .equ log_dir,                 ff16_dir_a            @ DIR object of the root scan (production: R0.16 DIR, 44 bytes, in .bss_port, IMP-29)
    .equ log_finfo,               ff16_finfo            @ FILINFO of the scan and of f_utime/f_stat (production: R0.16 exFAT/LFN FILINFO, 288 bytes, in .bss_port, ff16_api.s, IMP-32; v2.05: 0x20007B38, 22 bytes)
    .equ log_name_buf,            v_20007BD0            @ 0x20007BD0 file name buffer "YYMMDDnn.csv" (12 characters + NUL)
    .equ sd_csd,                  v_20007BF0            @ 0x20007BF0 CSD register of the card (4 words, word 0 = bits 127..96)
    .equ log_fixbuf_end,          v_20007C57            @ 0x20007C57 end of the buffer log_format_fixed writes backwards
    .equ log_view_value1,         v_20007D1C            @ 0x20007D1C main value of the record loaded by log_slot_load (i32)
    .equ log_blocks,              v_20007D34            @ 0x20007D34 number of complete 60-record blocks already written to the file
    .equ log_row_no,              v_20007D40            @ 0x20007D40 number of the last row written to the file (CSV column "No.")
    .equ log_pending,             v_20007D44            @ 0x20007D44 records in the ring that are not written to the file yet
    .equ log_row_no_start,        v_20007D48            @ 0x20007D48 log_row_no at the start of the running flush (restored when the flush fails)
    .equ log_max_value,           v_20007D4C            @ 0x20007D4C maximum main value of the file so far (complemented when negative)
    .equ log_min_value,           v_20007D50            @ 0x20007D50 minimum main value of the file so far
    .equ log_max_row,             v_20007D54            @ 0x20007D54 row number of the maximum
    .equ log_min_row,             v_20007D58            @ 0x20007D58 row number of the minimum
    .equ log_name_ptr,            v_20007EC8            @ 0x20007EC8 pointer to the name of the log file
    .equ log_name_prev_ptr,       v_20007ECC            @ 0x20007ECC pointer to the name of the previous file (only the unreachable branch of log_create_file uses it)
    .equ log_next_index,          v_20007ED0            @ 0x20007ED0 number nn of the next file of today (highest existing nn + 1)
    .equ log_read_count,          v_20007ED4            @ 0x20007ED4 bytes returned by the f_read of log_verify_file
    .equ log_write_count,         v_20007ED8            @ 0x20007ED8 bytes accepted by the f_write of log_write_bytes
    .equ log_flush_start,         v_20007EDC            @ 0x20007EDC file size at the start of the running flush (position to go back to when the flush fails)
    .equ log_file_size,           v_20007EE0            @ 0x20007EE0 size of the log file after the last good flush
    .equ log_bytes_total,         v_20007EE4            @ 0x20007EE4 bytes written to the log file since logging started
    .equ log_file_seq,            v_20007FAE            @ 0x20007FAE number of files forced since logging started (0 = first file of the run)
    .equ log_buf_len,             v_20007FDA            @ 0x20007FDA bytes in log_buf
    .equ log_active,              v_20007FE1            @ 0x20007FE1 logging in progress (toggled by long MEM)
    .equ log_view_func1,          v_20007FF4            @ 0x20007FF4 main function code of the loaded record
    .equ log_view_flags1,         v_20007FF5            @ 0x20007FF5 main flags of the loaded record
    .equ log_error_code,          v_2000801B            @ 0x2000801B error code of the last log write (shown as SdExx)
    .equ log_write_request,       v_2000801C            @ 0x2000801C a flush to the SD card is due (main loop step 12)
    .equ log_limit_hit,           v_2000801D            @ 0x2000801D logging stopped because the file reached 600000 rows
    .equ log_new_file,            v_20008024            @ 0x20008024 1 = the next session starts a new file (log_start, log_force_new_file)
    .equ log_closing,             v_20008025            @ 0x20008025 1 = logging is stopping; the next session writes the min/max rows (log_stop)
    .equ log_header_due,          v_20008026            @ 0x20008026 1 = the next flush writes the CSV header first
    .equ log_max_func,            v_20008027            @ 0x20008027 function code of the maximum row
    .equ log_min_func,            v_20008028            @ 0x20008028 function code of the minimum row
    .equ log_max_flags,           v_20008029            @ 0x20008029 flags of the maximum row
    .equ log_min_flags,           v_2000802A            @ 0x2000802A flags of the minimum row
    .equ bat_low,                 v_2000803B            @ 0x2000803B debounced low-battery flag (adc_ch5_process)
    .equ ui_refresh_request,      v_20008062            @ 0x20008062 display refresh / message request
    .equ rtc_year,                v_200080D7            @ 0x200080D7 years since 2000 (calendar copy of the NJU6350)
    .equ rtc_month,               v_200080D8            @ 0x200080D8 month
    .equ rtc_day,                 v_200080D9            @ 0x200080D9 day of the month
    .equ rtc_hour,                v_200080DA            @ 0x200080DA hour
    .equ rtc_minute,              v_200080DB            @ 0x200080DB minute
    .equ rtc_second,              v_200080DC            @ 0x200080DC second
    .equ log_scan_year,           v_200080E2            @ 0x200080E2 year parsed from a file name by log_scan_directory
    .equ log_scan_month,          v_200080E3            @ 0x200080E3 month parsed from a file name
    .equ log_scan_day,            v_200080E4            @ 0x200080E4 day parsed from a file name
    .equ log_attempts,            v_200080E5            @ 0x200080E5 attempt counter of log_write_step
    .equ log_fresult,             v_200080F4            @ 0x200080F4 FRESULT of the last file system call of the log code
    .equ log_root_path,           v_200080F5            @ 0x200080F5 "0:" path string for the root directory (3 bytes)
    .equ log_flush_failed,        v_200080F6            @ 0x200080F6 a flush or its verification failed

@ -----------------------------------------------------------------------------
@ log_write_start / log_write_step / log_write_session - the retrying SD log write (state machine, IMP-06): overview
@ Replaces : 0x0801D126 FUN_0801D126 (v2.05; canonical symbol fn_0801D126 = log_write_session)
@ Called by: main loop step 12 (DESIGN.md 3.5, flag 0x2000801C), log_stop (0x08010B3E, with its argument = 1)
@
@ v2.05 control flow (0x0801D126..0x0801D1A7):
@   attempts = 20; repeat { r = log_session_once(); if r == 0 -> success } while (--attempts != 0)
@   all 20 failed: log_force_new_file() (start a new numbered file: 0x0801D51A), attempts = 20, repeat the same
@   loop testing only the low byte of r; when all 20 fail again: log_error_code = r, ui_refresh_request = 1, fail.
@ The port keeps this order and splits it into steps of one log_session_once each, so a failing card no longer
@ blocks the loop for the whole retry sequence (DESIGN.md 3.5 table, row "Blocking routines"):
@   log_write_start()  : arm the machine (phase 1, attempts = 20)
@   log_write_step()   : r0 = 0 busy (call again on the next pass), 1 done; the result is in log_write_result
@   log_write_session(): start + step until done, return the result (the v2.05 form used by the baseline loop and
@                        by log_stop); v2.05 signature: no input, r0 = 0 written, 1 failed
@ A step runs one log_session_once, which holds the card-session clock (PLL 32 MHz, IMP-41; v2.05 HSE) only for its own duration (sys_clock_select(1) at its
@ start, (0) at its end, 0x0801D1B2 / 0x0801D372), exactly the SD command sequence of one v2.05 attempt.
@ The three routines below each carry their own header.
@ -----------------------------------------------------------------------------
    .equ LOGW_IDLE,   0                     @ log_write_state: no write in progress
    .equ LOGW_PHASE1, 1                     @ first series of 20 attempts
    .equ LOGW_PHASE2, 2                     @ second series after the new file was forced

    .pushsection .bss_port.log, "aw", %nobits
    .global log_write_state, log_write_result
log_write_state:  .space 1                  @ LOGW_*
log_write_result: .space 1                  @ result of the last completed write: 0 written, 1 failed
    .popsection

@ -----------------------------------------------------------------------------
@ log_write_start - arm the retrying log write
@ Replaces : first half of 0x0801D126 FUN_0801D126 (v2.05, 0x0801D12A..0x0801D130: attempts = 20)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, flags (AAPCS)
@ Context  : main only
@ RAM      : writes log_write_state (port RAM, = LOGW_PHASE1) and log_attempts 0x200080E5 (= 20)
@ Spec     : v2.05 listing 0x0801D126..0x0801D1A7; W8_to_W1.md item 3
@ Deviation: IMP-06
@ -----------------------------------------------------------------------------
FUNC log_write_start
    movs    r0, #LOGW_PHASE1
    ldr     r1, =log_write_state
    strb    r0, [r1]                        @ phase 1
    movs    r0, #20                         @ v2.05 0x0801D12A: 20 attempts
    ldr     r1, =log_attempts
    strb    r0, [r1]
    bx      lr
    .ltorg
ENDFUNC log_write_start

@ -----------------------------------------------------------------------------
@ log_write_step - run one attempt of the armed log write
@ Replaces : the loop body of 0x0801D126 FUN_0801D126 (v2.05, 0x0801D132..0x0801D1A6), one log_session_once per call
@ In       : -  (log_write_state selects the series: LOGW_PHASE1, LOGW_PHASE2; LOGW_IDLE = nothing armed)
@ Out      : r0 = 0 busy (call again on a later pass), 1 done (the result is in log_write_result: 0 written, 1 failed);
@            idle machine: 1
@ Clobbers : r1-r3, r12, flags (AAPCS); r4 preserved
@ Context  : main only
@ RAM      : reads/writes log_write_state, log_write_result (port RAM), log_attempts 0x200080E5; on the final failure
@            writes log_error_code 0x2000801B and ui_refresh_request 0x20008062
@ Spec     : v2.05 listing 0x0801D126..0x0801D1A7
@ Deviation: IMP-06
@ -----------------------------------------------------------------------------
FUNC log_write_step
    push    {r4, lr}
    ldr     r4, =log_write_state
    ldrb    r0, [r4]
    cmp     r0, #LOGW_PHASE1
    beq     .Llws_phase1
    cmp     r0, #LOGW_PHASE2
    beq     .Llws_phase2
    movs    r0, #1                          @ idle: nothing to do, report done
    pop     {r4, pc}
.Llws_phase1:
    bl      log_session_once                @ one attempt (0x0801D132)
    cmp     r0, #0
    beq     .Llws_success                   @ 0x0801D136: the whole word is tested in the first series
    ldr     r1, =log_attempts
    ldrb    r0, [r1]
    subs    r0, r0, #1                      @ 0x0801D140
    strb    r0, [r1]
    bne     .Llws_busy                      @ attempts left
    bl      log_force_new_file              @ 0x0801D160: all 20 failed, force a new file
    movs    r0, #20
    ldr     r1, =log_attempts
    strb    r0, [r1]                        @ 0x0801D164: 20 more attempts
    movs    r0, #LOGW_PHASE2
    strb    r0, [r4]
.Llws_busy:
    movs    r0, #0
    pop     {r4, pc}
.Llws_phase2:
    bl      log_session_once                @ 0x0801D16C
    uxtb    r3, r0                          @ only the low byte counts in the second series (0x0801D170)
    cmp     r3, #0
    beq     .Llws_success
    ldr     r1, =log_attempts
    ldrb    r0, [r1]
    subs    r0, r0, #1                      @ 0x0801D17E
    strb    r0, [r1]
    bne     .Llws_busy
    ldr     r0, =log_error_code
    strb    r3, [r0]                        @ 0x0801D190: error code of the last attempt (SdExx)
    movs    r0, #1
    ldr     r1, =ui_refresh_request
    strb    r0, [r1]                        @ 0x0801D198
    ldr     r1, =log_write_result
    strb    r0, [r1]                        @ result 1 = failed (0x0801D19E)
    b       .Llws_done
.Llws_success:
    movs    r0, #0
    ldr     r1, =log_write_result
    strb    r0, [r1]                        @ result 0 = written
.Llws_done:
    movs    r0, #LOGW_IDLE
    strb    r0, [r4]
    movs    r0, #1                          @ done
    pop     {r4, pc}
    .ltorg
ENDFUNC log_write_step

@ -----------------------------------------------------------------------------
@ log_write_session - the v2.05 blocking form: start and step until done
@ Replaces : 0x0801D126 FUN_0801D126 (v2.05), canonical symbol fn_0801D126; called by log_stop (0x08010B3E); v2.05 also calls
@            it from the main loop step 12 (0x08024D62), which here runs log_write_start / log_write_step
@ In       : -
@ Out      : r0 = 0 written, 1 failed (log_error_code and ui_refresh_request set on failure, as v2.05)
@ Clobbers : r1-r3, r12, flags (AAPCS); r4 preserved
@ Context  : main only
@ RAM      : as log_write_start and log_write_step
@ Spec     : v2.05 listing 0x0801D126..0x0801D1A7
@ Deviation: IMP-06 (same attempt order and retry counts as v2.05, split into steps)
@ -----------------------------------------------------------------------------
FUNC log_write_session
    push    {r4, lr}
    bl      log_write_start
.Llwss_loop:
    bl      log_write_step
    cmp     r0, #0
    beq     .Llwss_loop                     @ run to completion (v2.05 order)
    ldr     r0, =log_write_result
    ldrb    r0, [r0]
    pop     {r4, pc}
    .ltorg
ENDFUNC log_write_session
    .global fn_0801D126
    .thumb_set fn_0801D126, log_write_session

@ -----------------------------------------------------------------------------
@ log_session_once - one SD session: bring the card up, write the pending rows, verify, clean up
@ Replaces  : 0x0801D1A8 FUN_0801D1A8 (v2.05), called by log_write_step
@ In        : -
@ Out       : r0 = 0 the session wrote and verified its rows, 1 no card (bring-up failed), 3 file could not be created, 4 file could
@             not be opened, 5 seek failed, 7 flush failed, 8 verification failed (error codes shown as SdExx)
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only; holds the card-session clock (PLL 32 MHz, IMP-41) from its first to its last instruction (sys_clock_select(1) .. (0), v2.05 0x0801D1B2 / 0x0801D372)
@ RAM       : reads/writes log_new_file, log_header_due, log_closing, log_file_seq, log_row_no, log_blocks, log_file_size,
@             log_flush_start, log_bytes_total, log_limit_hit, log_active, log_error_code, ui_refresh_request, bat_low
@ Spec      : v2.05 listing 0x0801D1A8..0x0801D37B
@ Note      : a session never touches the EEPROM; a missing, full or removed card only changes the returned code.
@ -----------------------------------------------------------------------------
FUNC log_session_once
    push    {r4, r5, r6, lr}                @ 0801D1A8 push {r4, r5, r6, lr}
    movs    r4, #0                          @ 0801D1AA r4 = 0
    movs    r5, #0                          @ 0801D1AC r5 = 0
    movs    r6, #0                          @ 0801D1AE r6 = 0
    @ the card-session clock for the SD access (PLL 32 MHz, IMP-41)
    movs    r0, #1                          @ 0801D1B0 r0 = 1
    bl      sys_clock_select                @ 0801D1B2 call sys_clock_select
    @ bring the card up (up to 10 tries, SD module); non-zero: no card, return 1
    movs    r0, #0xa                        @ 0801D1B6 r0 = 0xa
    bl      sd_bringup_retry                @ 0801D1B8 call sd_bringup_retry
    cmp     r0, #0                          @ 0801D1BC compare r0 with 0
    beq     .Llog_session_once_D1C4         @ 0801D1BE if (r0 == 0) goto 0x801D1C4
    movs    r0, #1                          @ 0801D1C0 r0 = 1
    b       .Llog_session_once_D37A         @ 0801D1C2 goto 0x801D37A
    @ register the file system work area of drive 0 (no I/O yet)
.Llog_session_once_D1C4:                @ v2.05 0x0801D1C4, reached from 0x0801D1BE
    ldr.w   r1, =fat_fs_obj                 @ 0801D1C4 r1 = &fat_fs_obj
    movs    r0, #0                          @ 0801D1C8 r0 = 0
    bl      fat_f_mount                     @ 0801D1CA call fat_f_mount
    @ log_new_file set: choose a name and create the file; clear: reopen the existing file and seek to its end
    ldr.w   r0, =log_new_file               @ 0801D1CE r0 = &log_new_file
    ldrb    r0, [r0]                        @ 0801D1D2 r0 = u8 [log_new_file]
    cmp     r0, #0                          @ 0801D1D4 compare r0 with 0
    beq     .Llog_session_once_D21C         @ 0801D1D6 if (r0 == 0) goto 0x801D21C
    movs    r0, #0                          @ 0801D1D8 r0 = 0
    @ new file: no bytes written yet; log_select_file(10) tries up to 10 numbers
    ldr.w   r1, =log_bytes_total            @ 0801D1DA r1 = &log_bytes_total
    str     r0, [r1]                        @ 0801D1DE u32 [log_bytes_total] = r0
    movs    r0, #0xa                        @ 0801D1E0 r0 = 0xa
    bl      log_select_file                 @ 0801D1E2 call log_select_file
    ldr.w   r1, =log_fresult                @ 0801D1E6 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D1EA u8 [log_fresult] = r0
    @ created: log_new_file = 0, r4 = 1 (set the time stamp at the end); the CSV header is due for every new file (OF-60)
    ldr.w   r0, =log_fresult                @ 0801D1EC r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D1F0 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D1F2 compare r0 with 0
    bne     .Llog_session_once_D216         @ 0801D1F4 if (r0 != 0) goto 0x801D216
    movs    r0, #0                          @ 0801D1F6 r0 = 0
    ldr.w   r1, =log_new_file               @ 0801D1F8 r1 = &log_new_file
    strb    r0, [r1]                        @ 0801D1FC u8 [log_new_file] = r0
    movs    r0, #1                          @ 0801D1FE r0 = 1
    movs    r4, r0                          @ 0801D200 r4 = r0
    @ OF-60: every new file gets the CSV header; v2.05 sets it due only while log_file_seq is 0 (0x0801D202..0x0801D20A), so the
    @ file that log_force_new_file opens after 20 failed attempts (log_file_seq + 1) started with data rows and no header
    movs    r0, #1                          @ 0801D20C r0 = 1
    ldr.w   r1, =log_header_due             @ 0801D20E r1 = &log_header_due
    strb    r0, [r1]                        @ 0801D212 u8 [log_header_due] = r0
    b       .Llog_session_once_D224         @ 0801D214 goto 0x801D224
    @ could not create the file: error 3
.Llog_session_once_D216:                @ v2.05 0x0801D216, reached from 0x0801D1F4
    movs    r0, #3                          @ 0801D216 r0 = 3
    movs    r5, r0                          @ 0801D218 r5 = r0
    b       .Llog_session_once_D224         @ 0801D21A goto 0x801D224
    @ existing file: reopen it for writing and seek to log_file_size (20 tries)
.Llog_session_once_D21C:                @ v2.05 0x0801D21C, reached from 0x0801D1D6
    movs    r0, #0x14                       @ 0801D21C r0 = 0x14
    bl      log_open_and_seek               @ 0801D21E call log_open_and_seek
    movs    r5, r0                          @ 0801D222 r5 = r0
    @ flush the pending rows (or the header); a failure is error 7
.Llog_session_once_D224:                @ v2.05 0x0801D224, reached from 0x0801D214, 0x0801D21A (0x0801D20A removed, OF-60)
    uxtb    r5, r5                          @ 0801D224 r5 = u8(r5)
    cmp     r5, #0                          @ 0801D226 compare r5 with 0
    bne     .Llog_session_once_D236         @ 0801D228 if (r5 != 0) goto 0x801D236
    bl      log_flush_records               @ 0801D22A call log_flush_records
    cmp     r0, #0                          @ 0801D22E compare r0 with 0
    beq     .Llog_session_once_D236         @ 0801D230 if (r0 == 0) goto 0x801D236
    movs    r0, #7                          @ 0801D232 r0 = 7
    movs    r5, r0                          @ 0801D234 r5 = r0
    @ new file: set its time stamp now (closes the file); existing file: f_close
.Llog_session_once_D236:                @ v2.05 0x0801D236, reached from 0x0801D228, 0x0801D230
    uxtb    r4, r4                          @ 0801D236 r4 = u8(r4)
    cmp     r4, #0                          @ 0801D238 compare r4 with 0
    beq     .Llog_session_once_D244         @ 0801D23A if (r4 == 0) goto 0x801D244
    movs    r0, #0                          @ 0801D23C r0 = 0
    bl      log_set_file_time               @ 0801D23E call log_set_file_time
    b       .Llog_session_once_D24C         @ 0801D242 goto 0x801D24C
.Llog_session_once_D244:                @ v2.05 0x0801D244, reached from 0x0801D23A
    ldr.w   r0, =log_fil                    @ 0801D244 r0 = &log_fil
    bl      fat_f_close                     @ 0801D248 call fat_f_close
    @ read the file back and compare it with log_buf (log_verify_file)
.Llog_session_once_D24C:                @ v2.05 0x0801D24C, reached from 0x0801D242
    uxtb    r5, r5                          @ 0801D24C r5 = u8(r5)
    cmp     r5, #0                          @ 0801D24E compare r5 with 0
    bne     .Llog_session_once_D2BE         @ 0801D250 if (r5 != 0) goto 0x801D2BE
    ldr.w   r0, =log_fil                    @ 0801D252 r0 = &log_fil
    bl      fat_f_tell                      @ 0801D256 call fat_f_tell
    @ log_file_size = size reported by f_close/f_tell
    ldr.w   r1, =log_file_size              @ 0801D25A r1 = &log_file_size
    str     r0, [r1]                        @ 0801D25E u32 [log_file_size] = r0
    bl      log_verify_file                 @ 0801D260 call log_verify_file
    movs    r5, r0                          @ 0801D264 r5 = r0
    uxtb    r5, r5                          @ 0801D266 r5 = u8(r5)
    cmp     r5, #0                          @ 0801D268 compare r5 with 0
    beq     .Llog_session_once_D2A6         @ 0801D26A if (r5 == 0) goto 0x801D2A6
    @ verification failed: go back to the size before this flush, mark the flush failed; a whole block of 60 rows is taken back
    ldr.w   r0, =log_flush_start            @ 0801D26C r0 = &log_flush_start
    ldr     r0, [r0]                        @ 0801D270 r0 = u32 [log_flush_start]
    ldr.w   r1, =log_file_size              @ 0801D272 r1 = &log_file_size
    str     r0, [r1]                        @ 0801D276 u32 [log_file_size] = r0
    movs    r0, #1                          @ 0801D278 r0 = 1
    ldr.w   r1, =log_flush_failed           @ 0801D27A r1 = &log_flush_failed
    strb    r0, [r1]                        @ 0801D27E u8 [log_flush_failed] = r0
    ldr.w   r0, =log_row_no                 @ 0801D280 r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801D284 r0 = u32 [log_row_no]
    cmp     r0, #0x3c                       @ 0801D286 compare r0 with 0x3c
    blo     .Llog_session_once_D2A6         @ 0801D288 if (r0 <u 0x3c) goto 0x801D2A6
    ldr.w   r0, =log_row_no                 @ 0801D28A r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801D28E r0 = u32 [log_row_no]
    subs    r0, #0x3c                       @ 0801D290 r0 -= 0x3c
    ldr.w   r1, =log_row_no                 @ 0801D292 r1 = &log_row_no
    str     r0, [r1]                        @ 0801D296 u32 [log_row_no] = r0
    ldr.w   r0, =log_blocks                 @ 0801D298 r0 = &log_blocks
    ldr     r0, [r0]                        @ 0801D29C r0 = u32 [log_blocks]
    subs    r0, r0, #1                      @ 0801D29E r0 = r0 - 1
    ldr.w   r1, =log_blocks                 @ 0801D2A0 r1 = &log_blocks
    str     r0, [r1]                        @ 0801D2A4 u32 [log_blocks] = r0
.Llog_session_once_D2A6:                @ v2.05 0x0801D2A6, reached from 0x0801D26A, 0x0801D288
    uxtb    r5, r5                          @ 0801D2A6 r5 = u8(r5)
    cmp     r5, #0                          @ 0801D2A8 compare r5 with 0
    bne     .Llog_session_once_D2BE         @ 0801D2AA if (r5 != 0) goto 0x801D2BE
    @ verified: the header is no longer due
    ldr.w   r0, =log_header_due             @ 0801D2AC r0 = &log_header_due
    ldrb    r0, [r0]                        @ 0801D2B0 r0 = u8 [log_header_due]
    cmp     r0, #0                          @ 0801D2B2 compare r0 with 0
    beq     .Llog_session_once_D2BE         @ 0801D2B4 if (r0 == 0) goto 0x801D2BE
    movs    r0, #0                          @ 0801D2B6 r0 = 0
    ldr.w   r1, =log_header_due             @ 0801D2B8 r1 = &log_header_due
    strb    r0, [r1]                        @ 0801D2BC u8 [log_header_due] = r0
    @ end of the log: 600000 rows written (0x927C0): stop, switch logging off, set log_limit_hit
.Llog_session_once_D2BE:                @ v2.05 0x0801D2BE, reached from 0x0801D250, 0x0801D2AA, 0x0801D2B4
    uxtb    r5, r5                          @ 0801D2BE r5 = u8(r5)
    cmp     r5, #0                          @ 0801D2C0 compare r5 with 0
    bne     .Llog_session_once_D2F8         @ 0801D2C2 if (r5 != 0) goto 0x801D2F8
    ldr.w   r0, =log_row_no                 @ 0801D2C4 r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801D2C8 r0 = u32 [log_row_no]
    ldr.w   r1, =0x000927C0                 @ 0801D2CA r1 = 0x927C0
    cmp     r0, r1                          @ 0801D2CE compare r0 with r1
    blo     .Llog_session_once_D2F8         @ 0801D2D0 if (r0 <u r1) goto 0x801D2F8
    movs    r0, #0                          @ 0801D2D2 r0 = 0
    bl      log_stop                        @ 0801D2D4 call log_stop
    movs    r0, #0                          @ 0801D2D8 r0 = 0
    ldr.w   r1, =log_active                 @ 0801D2DA r1 = &log_active
    strb    r0, [r1]                        @ 0801D2DE u8 [log_active] = r0
    movs    r0, #1                          @ 0801D2E0 r0 = 1
    bl      fn_0801A32A                     @ 0801D2E2 call fn_0801A32A
    movs    r0, #1                          @ 0801D2E6 r0 = 1
    ldr.w   r1, =log_limit_hit              @ 0801D2E8 r1 = &log_limit_hit
    strb    r0, [r1]                        @ 0801D2EC u8 [log_limit_hit] = r0
    movs    r0, #1                          @ 0801D2EE r0 = 1
    ldr.w   r1, =ui_refresh_request         @ 0801D2F0 r1 = &ui_refresh_request
    strb    r0, [r1]                        @ 0801D2F4 u8 [ui_refresh_request] = r0
    b       .Llog_session_once_D326         @ 0801D2F6 goto 0x801D326
    @ low battery: stop, switch logging off, error code 100 (0x64)
.Llog_session_once_D2F8:                @ v2.05 0x0801D2F8, reached from 0x0801D2C2, 0x0801D2D0
    ldr.w   r0, =bat_low                    @ 0801D2F8 r0 = &bat_low
    ldrb    r0, [r0]                        @ 0801D2FC r0 = u8 [bat_low]
    cmp     r0, #0                          @ 0801D2FE compare r0 with 0
    beq     .Llog_session_once_D326         @ 0801D300 if (r0 == 0) goto 0x801D326
    movs    r0, #0                          @ 0801D302 r0 = 0
    bl      log_stop                        @ 0801D304 call log_stop
    movs    r0, #0                          @ 0801D308 r0 = 0
    ldr.w   r1, =log_active                 @ 0801D30A r1 = &log_active
    strb    r0, [r1]                        @ 0801D30E u8 [log_active] = r0
    movs    r0, #1                          @ 0801D310 r0 = 1
    bl      fn_0801A32A                     @ 0801D312 call fn_0801A32A
    movs    r0, #0x64                       @ 0801D316 r0 = 0x64
    ldr.w   r1, =log_error_code             @ 0801D318 r1 = &log_error_code
    strb    r0, [r1]                        @ 0801D31C u8 [log_error_code] = r0
    movs    r0, #1                          @ 0801D31E r0 = 1
    ldr.w   r1, =ui_refresh_request         @ 0801D320 r1 = &ui_refresh_request
    strb    r0, [r1]                        @ 0801D324 u8 [ui_refresh_request] = r0
    @ the log is closing: append the minimum and maximum rows (up to 20 tries), then set the file time stamp
.Llog_session_once_D326:                @ v2.05 0x0801D326, reached from 0x0801D2F6, 0x0801D300
    uxtb    r5, r5                          @ 0801D326 r5 = u8(r5)
    cmp     r5, #0                          @ 0801D328 compare r5 with 0
    bne     .Llog_session_once_D36C         @ 0801D32A if (r5 != 0) goto 0x801D36C
    ldr.w   r0, =log_closing                @ 0801D32C r0 = &log_closing
    ldrb    r0, [r0]                        @ 0801D330 r0 = u8 [log_closing]
    cmp     r0, #0                          @ 0801D332 compare r0 with 0
    beq     .Llog_session_once_D36C         @ 0801D334 if (r0 == 0) goto 0x801D36C
    movs    r0, #0                          @ 0801D336 r0 = 0
    ldr.w   r1, =log_closing                @ 0801D338 r1 = &log_closing
    strb    r0, [r1]                        @ 0801D33C u8 [log_closing] = r0
    movs    r0, #0                          @ 0801D33E r0 = 0
    movs    r6, r0                          @ 0801D340 r6 = r0
.Llog_session_once_D342:                @ v2.05 0x0801D342, reached from 0x0801D360
    uxtb    r6, r6                          @ 0801D342 r6 = u8(r6)
    cmp     r6, #0x14                       @ 0801D344 compare r6 with 0x14
    bge     .Llog_session_once_D362         @ 0801D346 if (r6 >= 0x14) goto 0x801D362
    movs    r0, #0x14                       @ 0801D348 r0 = 0x14
    bl      log_open_and_seek               @ 0801D34A call log_open_and_seek
    movs    r5, r0                          @ 0801D34E r5 = r0
    uxtb    r5, r5                          @ 0801D350 r5 = u8(r5)
    cmp     r5, #0                          @ 0801D352 compare r5 with 0
    bne     .Llog_session_once_D35E         @ 0801D354 if (r5 != 0) goto 0x801D35E
    bl      log_write_minmax_rows           @ 0801D356 call log_write_minmax_rows
    cmp     r0, #0                          @ 0801D35A compare r0 with 0
    beq     .Llog_session_once_D362         @ 0801D35C if (r0 == 0) goto 0x801D362
.Llog_session_once_D35E:                @ v2.05 0x0801D35E, reached from 0x0801D354
    adds    r6, r6, #1                      @ 0801D35E r6 = r6 + 1
    b       .Llog_session_once_D342         @ 0801D360 goto 0x801D342
.Llog_session_once_D362:                @ v2.05 0x0801D362, reached from 0x0801D346, 0x0801D35C
    movs    r0, #0                          @ 0801D362 r0 = 0
    movs    r5, r0                          @ 0801D364 r5 = r0
    movs    r0, #0                          @ 0801D366 r0 = 0
    bl      log_set_file_time               @ 0801D368 call log_set_file_time
    @ power the card off and return to the run clock
.Llog_session_once_D36C:                @ v2.05 0x0801D36C, reached from 0x0801D32A, 0x0801D334
    bl      sd_power_off                    @ 0801D36C call sd_power_off
    movs    r0, #0                          @ 0801D370 r0 = 0
    bl      sys_clock_select                @ 0801D372 call sys_clock_select
    movs    r0, r5                          @ 0801D376 r0 = r5
    uxtb    r0, r0                          @ 0801D378 r0 = u8(r0)
.Llog_session_once_D37A:                @ v2.05 0x0801D37A, reached from 0x0801D1C2
    pop     {r4, r5, r6, pc}                @ 0801D37A pop {r4, r5, r6, pc}
ENDFUNC log_session_once
    .ltorg

@ -----------------------------------------------------------------------------
@ log_set_file_time - write the RTC time into the directory entry of the log file (or of cal.bin) and check it
@ Replaces  : 0x0801D37C FUN_0801D37C (v2.05), called by log_session_once and by calbin_save (0x0801CEF2)
@ In        : r0 = 0 the log file named by log_name_ptr, non-zero the file "cal.bin" (v205_tab_08029290)
@ Out       : -
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads rtc_year..rtc_second; uses log_finfo (fdate at +4, ftime at +6), log_name_ptr, log_fresult
@ Spec      : v2.05 listing 0x0801D37C..0x0801D48B; FAT directory entry date/time format (FatFs f_utime)
@ Note      : FAT date = (year + 20) << 9 | month << 5 | day (year counted from 1980; the RTC year is counted from 2000);
@             FAT time = hour << 11 | minute << 5 | second / 2.  The file is closed first, then f_utime sets the stamp and f_stat reads it
@             back; the sequence is repeated up to 10 times until the read-back date and time equal the written ones.
@ -----------------------------------------------------------------------------
FUNC log_set_file_time
    @ close the log file
    push    {r3, r4, r5, r6, r7, lr}        @ 0801D37C push {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 0801D37E r4 = r0
    ldr.w   r0, =log_fil                    @ 0801D380 r0 = &log_fil
    bl      fat_f_close                     @ 0801D384 call fat_f_close
    movs    r0, #0                          @ 0801D388 r0 = 0
    movs    r5, r0                          @ 0801D38A r5 = r0
    @ attempt counter r5 (0..9)
.Llog_set_file_time_D38C:               @ v2.05 0x0801D38C, reached from 0x0801D486
    uxtb    r5, r5                          @ 0801D38C r5 = u8(r5)
    cmp     r5, #0xa                        @ 0801D38E compare r5 with 0xa
    bge     .Llog_set_file_time_D488        @ 0801D390 if (r5 >= 0xa) goto 0x801D488
    @ FAT date from the RTC date, then FAT time
    ldr.w   r0, =rtc_year                   @ 0801D392 r0 = &rtc_year
    ldrb    r0, [r0]                        @ 0801D396 r0 = u8 [rtc_year]
    adds    r0, #0x14                       @ 0801D398 r0 += 0x14
    mov.w   r1, #0x200                      @ 0801D39A r1 = 0x200
    muls    r0, r1, r0                      @ 0801D39E r0 = r1 * r0
    ldr.w   r1, =rtc_month                  @ 0801D3A0 r1 = &rtc_month
    ldrb    r1, [r1]                        @ 0801D3A4 r1 = u8 [rtc_month]
    uxth    r1, r1                          @ 0801D3A6 r1 = u16(r1)
    orrs.w  r0, r0, r1, lsl #5              @ 0801D3A8 r0 = r0 | r1, lsl #5
    ldr.w   r1, =rtc_day                    @ 0801D3AC r1 = &rtc_day
    ldrb    r1, [r1]                        @ 0801D3B0 r1 = u8 [rtc_day]
    orrs    r0, r1                          @ 0801D3B2 r0 |= r1
    ldr.w   r1, =log_finfo                  @ 0801D3B4 r1 = &log_finfo
    strh    r0, [r1, #(FNO_FDATE)]                    @ 0801D3B8 u16 [log_finfo+0x4] = r0
    ldr.w   r0, =log_finfo                  @ 0801D3BA r0 = &log_finfo
    ldrh    r0, [r0, #(FNO_FDATE)]                    @ 0801D3BE r0 = u16 [log_finfo+0x4]
    movs    r6, r0                          @ 0801D3C0 r6 = r0
    ldr.w   r0, =rtc_hour                   @ 0801D3C2 r0 = &rtc_hour
    ldrb    r0, [r0]                        @ 0801D3C6 r0 = u8 [rtc_hour]
    mov.w   r1, #0x800                      @ 0801D3C8 r1 = 0x800
    muls    r0, r1, r0                      @ 0801D3CC r0 = r1 * r0
    ldr.w   r1, =rtc_minute                 @ 0801D3CE r1 = &rtc_minute
    ldrb    r1, [r1]                        @ 0801D3D2 r1 = u8 [rtc_minute]
    uxth    r1, r1                          @ 0801D3D4 r1 = u16(r1)
    orrs.w  r0, r0, r1, lsl #5              @ 0801D3D6 r0 = r0 | r1, lsl #5
    ldr.w   r1, =rtc_second                 @ 0801D3DA r1 = &rtc_second
    ldrb    r1, [r1]                        @ 0801D3DE r1 = u8 [rtc_second]
    uxth    r1, r1                          @ 0801D3E0 r1 = u16(r1)
    orrs.w  r0, r0, r1, lsr #1              @ 0801D3E2 r0 = r0 | r1, lsr #1
    ldr.w   r1, =log_finfo                  @ 0801D3E6 r1 = &log_finfo
    strh    r0, [r1, #(FNO_FTIME)]                    @ 0801D3EA u16 [log_finfo+0x6] = r0
    ldr.w   r0, =log_finfo                  @ 0801D3EC r0 = &log_finfo
    ldrh    r0, [r0, #(FNO_FTIME)]                    @ 0801D3F0 r0 = u16 [log_finfo+0x6]
    movs    r7, r0                          @ 0801D3F2 r7 = r0
    @ f_utime with the name of the log file or "cal.bin"
    uxtb    r4, r4                          @ 0801D3F4 r4 = u8(r4)
    cmp     r4, #0                          @ 0801D3F6 compare r4 with 0
    beq     .Llog_set_file_time_D40E        @ 0801D3F8 if (r4 == 0) goto 0x801D40E
    ldr.w   r1, =log_finfo                  @ 0801D3FA r1 = &log_finfo
    ldr.w   r0, =v205_tab_08029290          @ 0801D3FE r0 = &v205_tab_08029290
    bl      fat_f_utime                     @ 0801D402 call fat_f_utime
    ldr.w   r1, =log_fresult                @ 0801D406 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D40A u8 [log_fresult] = r0
    b       .Llog_set_file_time_D422        @ 0801D40C goto 0x801D422
.Llog_set_file_time_D40E:               @ v2.05 0x0801D40E, reached from 0x0801D3F8
    ldr.w   r1, =log_finfo                  @ 0801D40E r1 = &log_finfo
    ldr.w   r0, =log_name_ptr               @ 0801D412 r0 = &log_name_ptr
    ldr     r0, [r0]                        @ 0801D416 r0 = u32 [log_name_ptr]
    bl      fat_f_utime                     @ 0801D418 call fat_f_utime
    ldr.w   r1, =log_fresult                @ 0801D41C r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D420 u8 [log_fresult] = r0
    @ f_stat reads the stamp back
.Llog_set_file_time_D422:               @ v2.05 0x0801D422, reached from 0x0801D40C
    ldr.w   r0, =log_fresult                @ 0801D422 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D426 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D428 compare r0 with 0
    bne     .Llog_set_file_time_D484        @ 0801D42A if (r0 != 0) goto 0x801D484
    uxtb    r4, r4                          @ 0801D42C r4 = u8(r4)
    cmp     r4, #0                          @ 0801D42E compare r4 with 0
    beq     .Llog_set_file_time_D446        @ 0801D430 if (r4 == 0) goto 0x801D446
    ldr.w   r1, =log_finfo                  @ 0801D432 r1 = &log_finfo
    ldr.w   r0, =v205_tab_08029290          @ 0801D436 r0 = &v205_tab_08029290
    bl      fat_f_stat                      @ 0801D43A call fat_f_stat
    ldr.w   r1, =log_fresult                @ 0801D43E r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D442 u8 [log_fresult] = r0
    b       .Llog_set_file_time_D45A        @ 0801D444 goto 0x801D45A
.Llog_set_file_time_D446:               @ v2.05 0x0801D446, reached from 0x0801D430
    ldr.w   r1, =log_finfo                  @ 0801D446 r1 = &log_finfo
    ldr.w   r0, =log_name_ptr               @ 0801D44A r0 = &log_name_ptr
    ldr     r0, [r0]                        @ 0801D44E r0 = u32 [log_name_ptr]
    bl      fat_f_stat                      @ 0801D450 call fat_f_stat
    ldr.w   r1, =log_fresult                @ 0801D454 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D458 u8 [log_fresult] = r0
.Llog_set_file_time_D45A:               @ v2.05 0x0801D45A, reached from 0x0801D444
    ldr.w   r0, =log_fresult                @ 0801D45A r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D45E r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D460 compare r0 with 0
    bne     .Llog_set_file_time_D484        @ 0801D462 if (r0 != 0) goto 0x801D484
    @ equal: done (return)
    movs    r0, r6                          @ 0801D464 r0 = r6
    ldr.w   r1, =log_finfo                  @ 0801D466 r1 = &log_finfo
    ldrh    r1, [r1, #(FNO_FDATE)]                    @ 0801D46A r1 = u16 [log_finfo+0x4]
    uxth    r0, r0                          @ 0801D46C r0 = u16(r0)
    cmp     r0, r1                          @ 0801D46E compare r0 with r1
    bne     .Llog_set_file_time_D484        @ 0801D470 if (r0 != r1) goto 0x801D484
    movs    r0, r7                          @ 0801D472 r0 = r7
    ldr.w   r1, =log_finfo                  @ 0801D474 r1 = &log_finfo
    ldrh    r1, [r1, #(FNO_FTIME)]                    @ 0801D478 r1 = u16 [log_finfo+0x6]
    uxth    r0, r0                          @ 0801D47A r0 = u16(r0)
    cmp     r0, r1                          @ 0801D47C compare r0 with r1
    bne     .Llog_set_file_time_D484        @ 0801D47E if (r0 != r1) goto 0x801D484
    movs    r0, #1                          @ 0801D480 r0 = 1
    b       .Llog_set_file_time_D48A        @ 0801D482 goto 0x801D48A
    @ not equal or an error: next attempt
.Llog_set_file_time_D484:               @ v2.05 0x0801D484, reached from 0x0801D42A, 0x0801D462, 0x0801D470, 0x0801D47E
    adds    r5, r5, #1                      @ 0801D484 r5 = r5 + 1
    b       .Llog_set_file_time_D38C        @ 0801D486 goto 0x801D38C
.Llog_set_file_time_D488:               @ v2.05 0x0801D488, reached from 0x0801D390
    movs    r0, #0                          @ 0801D488 r0 = 0
.Llog_set_file_time_D48A:               @ v2.05 0x0801D48A, reached from 0x0801D482
    pop     {r1, r4, r5, r6, r7, pc}        @ 0801D48A pop {r1, r4, r5, r6, r7, pc}
ENDFUNC log_set_file_time
    .global fn_0801D37C
    .thumb_set fn_0801D37C, log_set_file_time
    .ltorg

@ -----------------------------------------------------------------------------
@ log_open_and_seek - open the existing log file for writing and seek to the end of the good data
@ Replaces  : 0x0801D48C FUN_0801D48C (v2.05), called by log_session_once
@ In        : r0 = tries (the callers pass 20; v2.05 loops 0x15 = 21 times, see Note)
@ Out       : r0 = 0 ok, 4 f_open failed, 5 f_lseek failed
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_name_ptr, log_file_size; writes log_fresult, log_flush_failed, log_flush_start
@ Spec      : v2.05 listing 0x0801D48C..0x0801D519
@ Note      : the argument is not used; both retry loops end after 21 attempts (cmp r6, #0x15).  Open mode 2 = FA_WRITE.
@             After the seek, log_flush_start = f_tell and log_flush_failed is cleared.
@ -----------------------------------------------------------------------------
FUNC log_open_and_seek
    push    {r4, r5, r6, lr}                @ 0801D48C push {r4, r5, r6, lr}
    movs    r4, r0                          @ 0801D48E r4 = r0
    movs    r5, #0                          @ 0801D490 r5 = 0
    movs    r6, #0                          @ 0801D492 r6 = 0
    movs    r0, #0                          @ 0801D494 r0 = 0
    movs    r6, r0                          @ 0801D496 r6 = r0
    @ f_open(log_fil, name, FA_WRITE) up to 21 times; r5 = 4 when all fail
.Llog_open_and_seek_D498:               @ v2.05 0x0801D498, reached from 0x0801D4BE
    movs    r2, #2                          @ 0801D498 r2 = 2
    ldr.w   r0, =log_name_ptr               @ 0801D49A r0 = &log_name_ptr
    ldr     r1, [r0]                        @ 0801D49E r1 = u32 [log_name_ptr]
    ldr.w   r0, =log_fil                    @ 0801D4A0 r0 = &log_fil
    bl      fat_f_open                      @ 0801D4A4 call fat_f_open
    ldr.w   r1, =log_fresult                @ 0801D4A8 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D4AC u8 [log_fresult] = r0
    ldr.w   r0, =log_fresult                @ 0801D4AE r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D4B2 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D4B4 compare r0 with 0
    beq     .Llog_open_and_seek_D4C4        @ 0801D4B6 if (r0 == 0) goto 0x801D4C4
    adds    r6, r6, #1                      @ 0801D4B8 r6 = r6 + 1
    uxtb    r6, r6                          @ 0801D4BA r6 = u8(r6)
    cmp     r6, #0x15                       @ 0801D4BC compare r6 with 0x15
    blt     .Llog_open_and_seek_D498        @ 0801D4BE if (r6 < 0x15) goto 0x801D498
    movs    r0, #4                          @ 0801D4C0 r0 = 4
    movs    r5, r0                          @ 0801D4C2 r5 = r0
.Llog_open_and_seek_D4C4:               @ v2.05 0x0801D4C4, reached from 0x0801D4B6
    ldr.w   r0, =log_fresult                @ 0801D4C4 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D4C8 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D4CA compare r0 with 0
    bne     .Llog_open_and_seek_D514        @ 0801D4CC if (r0 != 0) goto 0x801D514
    movs    r0, #0                          @ 0801D4CE r0 = 0
    movs    r6, r0                          @ 0801D4D0 r6 = r0
    @ f_lseek(log_fil, log_file_size) up to 21 times; r5 = 5 when all fail
.Llog_open_and_seek_D4D2:               @ v2.05 0x0801D4D2, reached from 0x0801D50E
    ldr.w   r0, =log_file_size              @ 0801D4D2 r0 = &log_file_size
    ldr     r1, [r0]                        @ 0801D4D6 r1 = u32 [log_file_size]
    ldr.w   r0, =log_fil                    @ 0801D4D8 r0 = &log_fil
    bl      fat_f_lseek                     @ 0801D4DC call fat_f_lseek
    ldr.w   r1, =log_fresult                @ 0801D4E0 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D4E4 u8 [log_fresult] = r0
    ldr.w   r0, =log_fresult                @ 0801D4E6 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D4EA r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D4EC compare r0 with 0
    bne     .Llog_open_and_seek_D508        @ 0801D4EE if (r0 != 0) goto 0x801D508
    movs    r0, #0                          @ 0801D4F0 r0 = 0
    ldr.w   r1, =log_flush_failed           @ 0801D4F2 r1 = &log_flush_failed
    strb    r0, [r1]                        @ 0801D4F6 u8 [log_flush_failed] = r0
    ldr.w   r0, =log_fil                    @ 0801D4F8 r0 = &log_fil
    bl      fat_f_tell                      @ 0801D4FC call fat_f_tell
    ldr.w   r1, =log_flush_start            @ 0801D500 r1 = &log_flush_start
    str     r0, [r1]                        @ 0801D504 u32 [log_flush_start] = r0
    b       .Llog_open_and_seek_D514        @ 0801D506 goto 0x801D514
.Llog_open_and_seek_D508:               @ v2.05 0x0801D508, reached from 0x0801D4EE
    adds    r6, r6, #1                      @ 0801D508 r6 = r6 + 1
    uxtb    r6, r6                          @ 0801D50A r6 = u8(r6)
    cmp     r6, #0x15                       @ 0801D50C compare r6 with 0x15
    blt     .Llog_open_and_seek_D4D2        @ 0801D50E if (r6 < 0x15) goto 0x801D4D2
    movs    r0, #5                          @ 0801D510 r0 = 5
    movs    r5, r0                          @ 0801D512 r5 = r0
.Llog_open_and_seek_D514:               @ v2.05 0x0801D514, reached from 0x0801D4CC, 0x0801D506
    movs    r0, r5                          @ 0801D514 r0 = r5
    uxtb    r0, r0                          @ 0801D516 r0 = u8(r0)
    pop     {r4, r5, r6, pc}                @ 0801D518 pop {r4, r5, r6, pc}
ENDFUNC log_open_and_seek
    .ltorg

@ -----------------------------------------------------------------------------
@ log_force_new_file - make the next session start a new file with a derived name
@ Replaces  : 0x0801D51A FUN_0801D51A (v2.05), called by log_write_step
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : writes log_write_request, log_new_file; increments log_file_seq
@ Spec      : v2.05 listing 0x0801D51A..0x0801D539
@ -----------------------------------------------------------------------------
FUNC log_force_new_file
    movs    r0, #1                          @ 0801D51A r0 = 1
    ldr.w   r1, =log_write_request          @ 0801D51C r1 = &log_write_request
    strb    r0, [r1]                        @ 0801D520 u8 [log_write_request] = r0
    movs    r0, #1                          @ 0801D522 r0 = 1
    ldr.w   r1, =log_new_file               @ 0801D524 r1 = &log_new_file
    strb    r0, [r1]                        @ 0801D528 u8 [log_new_file] = r0
    ldr.w   r0, =log_file_seq               @ 0801D52A r0 = &log_file_seq
    ldrh    r0, [r0]                        @ 0801D52E r0 = u16 [log_file_seq]
    adds    r0, r0, #1                      @ 0801D530 r0 = r0 + 1
    ldr.w   r1, =log_file_seq               @ 0801D532 r1 = &log_file_seq
    strh    r0, [r1]                        @ 0801D536 u16 [log_file_seq] = r0
    bx      lr                              @ 0801D538 return
ENDFUNC log_force_new_file
    .ltorg

@ -----------------------------------------------------------------------------
@ log_create_file - create the log file, trying up to r1 times
@ Replaces  : 0x0801D53A FUN_0801D53A (v2.05), called by log_select_file
@ In        : r0 = 0 create log_name_ptr; non-zero also create it in log_fil_new and reopen log_name_prev_ptr for reading (never used by v2.05), r1 = tries
@ Out       : r0 = FRESULT of the last attempt (0 = file created)
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_name_ptr, log_name_prev_ptr; writes log_fresult
@ Spec      : v2.05 listing 0x0801D53A..0x0801D5AF
@ Note      : the only caller passes r0 = 0, so v2.05 only runs the second branch (mode 0xA = FA_CREATE_ALWAYS | FA_WRITE on log_fil);
@             the other branch (mode 0xB on log_fil_new, then mode 1 on log_fil) is ported unchanged.
@ -----------------------------------------------------------------------------
FUNC log_create_file
    push    {r4, r5, r6, lr}                @ 0801D53A push {r4, r5, r6, lr}
    movs    r4, r0                          @ 0801D53C r4 = r0
    movs    r5, r1                          @ 0801D53E r5 = r1
    movs    r0, #0                          @ 0801D540 r0 = 0
    movs    r6, r0                          @ 0801D542 r6 = r0
    @ up to r1 attempts
.Llog_create_file_D544:                 @ v2.05 0x0801D544, reached from 0x0801D5A8
    movs    r0, r6                          @ 0801D544 r0 = r6
    movs    r1, r5                          @ 0801D546 r1 = r5
    uxtb    r0, r0                          @ 0801D548 r0 = u8(r0)
    uxtb    r1, r1                          @ 0801D54A r1 = u8(r1)
    cmp     r0, r1                          @ 0801D54C compare r0 with r1
    bhs     .Llog_create_file_D5AA          @ 0801D54E if (r0 >=u r1) goto 0x801D5AA
    uxtb    r4, r4                          @ 0801D550 r4 = u8(r4)
    cmp     r4, #0                          @ 0801D552 compare r4 with 0
    beq     .Llog_create_file_D586          @ 0801D554 if (r4 == 0) goto 0x801D586
    @ r0 != 0: f_open(log_fil_new, name, 0xB), then f_open(log_fil, previous name, FA_READ)
    movs    r2, #0xb                        @ 0801D556 r2 = 0xb
    ldr.w   r0, =log_name_ptr               @ 0801D558 r0 = &log_name_ptr
    ldr     r1, [r0]                        @ 0801D55C r1 = u32 [log_name_ptr]
    ldr.w   r0, =log_fil_new                @ 0801D55E r0 = &log_fil_new
    bl      fat_f_open                      @ 0801D562 call fat_f_open
    ldr     r1, =log_fresult                @ 0801D566 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D568 u8 [log_fresult] = r0
    ldr     r0, =log_fresult                @ 0801D56A r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D56C r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D56E compare r0 with 0
    bne     .Llog_create_file_D598          @ 0801D570 if (r0 != 0) goto 0x801D598
    movs    r2, #1                          @ 0801D572 r2 = 1
    ldr.w   r0, =log_name_prev_ptr          @ 0801D574 r0 = &log_name_prev_ptr
    ldr     r1, [r0]                        @ 0801D578 r1 = u32 [log_name_prev_ptr]
    ldr     r0, =log_fil                    @ 0801D57A r0 = &log_fil
    bl      fat_f_open                      @ 0801D57C call fat_f_open
    ldr     r1, =log_fresult                @ 0801D580 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D582 u8 [log_fresult] = r0
    b       .Llog_create_file_D598          @ 0801D584 goto 0x801D598
    @ r0 == 0: f_open(log_fil, name, 0xA)
.Llog_create_file_D586:                 @ v2.05 0x0801D586, reached from 0x0801D554
    movs    r2, #0xa                        @ 0801D586 r2 = 0xa
    ldr.w   r0, =log_name_ptr               @ 0801D588 r0 = &log_name_ptr
    ldr     r1, [r0]                        @ 0801D58C r1 = u32 [log_name_ptr]
    ldr     r0, =log_fil                    @ 0801D58E r0 = &log_fil
    bl      fat_f_open                      @ 0801D590 call fat_f_open
    ldr     r1, =log_fresult                @ 0801D594 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D596 u8 [log_fresult] = r0
    @ success ends the loop
.Llog_create_file_D598:                 @ v2.05 0x0801D598, reached from 0x0801D570, 0x0801D584
    ldr     r0, =log_fresult                @ 0801D598 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D59A r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D59C compare r0 with 0
    bne     .Llog_create_file_D5A6          @ 0801D59E if (r0 != 0) goto 0x801D5A6
    ldr     r0, =log_fresult                @ 0801D5A0 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D5A2 r0 = u8 [log_fresult]
    b       .Llog_create_file_D5AE          @ 0801D5A4 goto 0x801D5AE
.Llog_create_file_D5A6:                 @ v2.05 0x0801D5A6, reached from 0x0801D59E
    adds    r6, r6, #1                      @ 0801D5A6 r6 = r6 + 1
    b       .Llog_create_file_D544          @ 0801D5A8 goto 0x801D544
.Llog_create_file_D5AA:                 @ v2.05 0x0801D5AA, reached from 0x0801D54E
    ldr     r0, =log_fresult                @ 0801D5AA r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D5AC r0 = u8 [log_fresult]
.Llog_create_file_D5AE:                 @ v2.05 0x0801D5AE, reached from 0x0801D5A4
    pop     {r4, r5, r6, pc}                @ 0801D5AE pop {r4, r5, r6, pc}
ENDFUNC log_create_file
    .ltorg

@ -----------------------------------------------------------------------------
@ log_select_file - find a free file number for today and create the file
@ Replaces  : 0x0801D5B0 FUN_0801D5B0 (v2.05), called by log_session_once
@ In        : r0 = tries (10)
@ Out       : r0 = 0 file created, else the FRESULT of the last failure
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : writes log_root_path "0:", log_fresult; reads log_file_seq, log_next_index
@ Spec      : v2.05 listing 0x0801D5B0..0x0801D62D
@ -----------------------------------------------------------------------------
FUNC log_select_file
    push    {r3, r4, r5, lr}                @ 0801D5B0 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 0801D5B2 r4 = r0
    @ path "0:" for the directory scan
    movs    r0, #0x30                       @ 0801D5B4 r0 = 0x30
    ldr.w   r1, =log_root_path              @ 0801D5B6 r1 = &log_root_path
    strb    r0, [r1]                        @ 0801D5BA u8 [log_root_path] = r0
    movs    r0, #0x3a                       @ 0801D5BC r0 = 0x3a
    ldr.w   r1, =log_root_path              @ 0801D5BE r1 = &log_root_path
    strb    r0, [r1, #1]                    @ 0801D5C2 u8 [log_root_path+0x1] = r0
    movs    r0, #0                          @ 0801D5C4 r0 = 0
    ldr.w   r1, =log_root_path              @ 0801D5C6 r1 = &log_root_path
    strb    r0, [r1, #2]                    @ 0801D5CA u8 [log_root_path+0x2] = r0
    movs    r0, #0                          @ 0801D5CC r0 = 0
    movs    r5, r0                          @ 0801D5CE r5 = r0
.Llog_select_file_D5D0:                 @ v2.05 0x0801D5D0, reached from 0x0801D626
    movs    r0, r5                          @ 0801D5D0 r0 = r5
    movs    r1, r4                          @ 0801D5D2 r1 = r4
    uxtb    r0, r0                          @ 0801D5D4 r0 = u8(r0)
    uxtb    r1, r1                          @ 0801D5D6 r1 = u8(r1)
    cmp     r0, r1                          @ 0801D5D8 compare r0 with r1
    bhs     .Llog_select_file_D628          @ 0801D5DA if (r0 >=u r1) goto 0x801D628
    @ scan the root directory: log_next_index = highest number of today's files + 1
    ldr.w   r0, =log_root_path              @ 0801D5DC r0 = &log_root_path
    bl      log_scan_directory              @ 0801D5E0 call log_scan_directory
    ldr     r1, =log_fresult                @ 0801D5E4 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D5E6 u8 [log_fresult] = r0
    ldr     r0, =log_fresult                @ 0801D5E8 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D5EA r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D5EC compare r0 with 0
    bne     .Llog_select_file_D624          @ 0801D5EE if (r0 != 0) goto 0x801D624
    @ first file of the run: name YYMMDDnn.csv; after a forced file: name derived from the previous one
    ldr.w   r0, =log_file_seq               @ 0801D5F0 r0 = &log_file_seq
    ldrh    r0, [r0]                        @ 0801D5F4 r0 = u16 [log_file_seq]
    cmp     r0, #0                          @ 0801D5F6 compare r0 with 0
    beq     .Llog_select_file_D600          @ 0801D5F8 if (r0 == 0) goto 0x801D600
    bl      log_build_suffix_name           @ 0801D5FA call log_build_suffix_name
    b       .Llog_select_file_D60A          @ 0801D5FE goto 0x801D60A
.Llog_select_file_D600:                 @ v2.05 0x0801D600, reached from 0x0801D5F8
    ldr.w   r0, =log_next_index             @ 0801D600 r0 = &log_next_index
    ldr     r0, [r0]                        @ 0801D604 r0 = u32 [log_next_index]
    bl      log_build_dated_name            @ 0801D606 call log_build_dated_name
    @ create the file (up to 10 tries)
.Llog_select_file_D60A:                 @ v2.05 0x0801D60A, reached from 0x0801D5FE
    movs    r1, #0xa                        @ 0801D60A r1 = 0xa
    movs    r0, #0                          @ 0801D60C r0 = 0
    bl      log_create_file                 @ 0801D60E call log_create_file
    ldr     r1, =log_fresult                @ 0801D612 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D614 u8 [log_fresult] = r0
    ldr     r0, =log_fresult                @ 0801D616 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D618 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D61A compare r0 with 0
    bne     .Llog_select_file_D624          @ 0801D61C if (r0 != 0) goto 0x801D624
    ldr     r0, =log_fresult                @ 0801D61E r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D620 r0 = u8 [log_fresult]
    b       .Llog_select_file_D62C          @ 0801D622 goto 0x801D62C
.Llog_select_file_D624:                 @ v2.05 0x0801D624, reached from 0x0801D5EE, 0x0801D61C
    adds    r5, r5, #1                      @ 0801D624 r5 = r5 + 1
    b       .Llog_select_file_D5D0          @ 0801D626 goto 0x801D5D0
.Llog_select_file_D628:                 @ v2.05 0x0801D628, reached from 0x0801D5DA
    ldr     r0, =log_fresult                @ 0801D628 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D62A r0 = u8 [log_fresult]
.Llog_select_file_D62C:                 @ v2.05 0x0801D62C, reached from 0x0801D622
    pop     {r1, r4, r5, pc}                @ 0801D62C pop {r1, r4, r5, pc}
ENDFUNC log_select_file
    .ltorg

@ -----------------------------------------------------------------------------
@ log_scan_directory - find the highest number nn among the files YYMMDDnn.csv of today
@ Replaces  : 0x0801D640 FUN_0801D640 (v2.05), called by log_select_file
@ In        : r0 = path of the directory ("0:")
@ Out       : r0 = FRESULT (0 ok)
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : uses log_dir, log_finfo; reads rtc_year, rtc_month, rtc_day, log_file_seq; writes log_scan_year/month/day,
@             log_next_index, log_fresult
@ Spec      : v2.05 listing 0x0801D640..0x0801D797
@ Note      : only when log_file_seq is 0.  Every entry named xxxxxxxx.csv or .CSV whose first six digits equal today's
@             YYMMDD counts; its last two digits nn give the candidate nn + 1.  The result is 0 when it would be 100 or more.
@ -----------------------------------------------------------------------------
FUNC log_scan_directory
    push    {r4, r5, r6, lr}                @ 0801D640 push {r4, r5, r6, lr}
    movs    r4, r0                          @ 0801D642 r4 = r0
    movs    r5, #0                          @ 0801D644 r5 = 0
    movs    r6, #0                          @ 0801D646 r6 = 0
    @ open the root directory
    movs    r1, r4                          @ 0801D648 r1 = r4
    ldr.w   r0, =log_dir                    @ 0801D64A r0 = &log_dir
    bl      fat_f_opendir                   @ 0801D64E call fat_f_opendir
    ldr     r1, =log_fresult                @ 0801D652 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D654 u8 [log_fresult] = r0
    ldr     r0, =log_fresult                @ 0801D656 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D658 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D65A compare r0 with 0
    beq     .Llog_scan_directory_D664       @ 0801D65C if (r0 == 0) goto 0x801D664
    ldr     r0, =log_fresult                @ 0801D65E r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D660 r0 = u8 [log_fresult]
    b       .Llog_scan_directory_D796       @ 0801D662 goto 0x801D796
    @ the scan is skipped for a forced file (log_file_seq != 0)
.Llog_scan_directory_D664:              @ v2.05 0x0801D664, reached from 0x0801D65C
    ldr.w   r0, =log_file_seq               @ 0801D664 r0 = &log_file_seq
    ldrh    r0, [r0]                        @ 0801D668 r0 = u16 [log_file_seq]
    cmp     r0, #0                          @ 0801D66A compare r0 with 0
    bne.w   .Llog_scan_directory_D792       @ 0801D66C if (r0 != 0) goto 0x801D792
    @ f_readdir until the end or an error; the end sets log_next_index
.Llog_scan_directory_D670:              @ v2.05 0x0801D670, reached from 0x0801D6AC, 0x0801D6D4, 0x0801D6DE, 0x0801D6E8, 0x0801D746, 0x0801D756, 0x0801D766, 0x0801D782, 0x0801D788
    ldr.w   r1, =log_finfo                  @ 0801D670 r1 = &log_finfo
    ldr.w   r0, =log_dir                    @ 0801D674 r0 = &log_dir
    bl      fat_f_readdir                   @ 0801D678 call fat_f_readdir
    ldr     r1, =log_fresult                @ 0801D67C r1 = &log_fresult
    strb    r0, [r1]                        @ 0801D67E u8 [log_fresult] = r0
    ldr     r0, =log_fresult                @ 0801D680 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D682 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801D684 compare r0 with 0
    bne     .Llog_scan_directory_D692       @ 0801D686 if (r0 != 0) goto 0x801D692
    ldr.w   r0, =log_finfo                  @ 0801D688 r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 0)]                    @ 0801D68C r0 = u8 [log_finfo+0x9]
    cmp     r0, #0                          @ 0801D68E compare r0 with 0
    bne     .Llog_scan_directory_D6A4       @ 0801D690 if (r0 != 0) goto 0x801D6A4
.Llog_scan_directory_D692:              @ v2.05 0x0801D692, reached from 0x0801D686
    ldr.w   r0, =log_next_index             @ 0801D692 r0 = &log_next_index
    str     r6, [r0]                        @ 0801D696 u32 [log_next_index] = r6
    ldr.w   r0, =log_next_index             @ 0801D698 r0 = &log_next_index
    ldr     r0, [r0]                        @ 0801D69C r0 = u32 [log_next_index]
    cmp     r0, #0x64                       @ 0801D69E compare r0 with 0x64
    blt     .Llog_scan_directory_D792       @ 0801D6A0 if (r0 < 0x64) goto 0x801D792
    b       .Llog_scan_directory_D78A       @ 0801D6A2 goto 0x801D78A
    @ skip "." entries; accept extensions csv and CSV
.Llog_scan_directory_D6A4:              @ v2.05 0x0801D6A4, reached from 0x0801D690
    ldr.w   r0, =log_finfo                  @ 0801D6A4 r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 0)]                    @ 0801D6A8 r0 = u8 [log_finfo+0x9]
    cmp     r0, #0x2e                       @ 0801D6AA compare r0 with 0x2e
    beq     .Llog_scan_directory_D670       @ 0801D6AC if (r0 == 0x2e) goto 0x801D670
    ldr.w   r0, =log_finfo                  @ 0801D6AE r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 9)]                 @ 0801D6B2 r0 = u8 [log_finfo+0x12]
    cmp     r0, #0x63                       @ 0801D6B4 compare r0 with 0x63
    bne     .Llog_scan_directory_D6CC       @ 0801D6B6 if (r0 != 0x63) goto 0x801D6CC
    ldr.w   r0, =log_finfo                  @ 0801D6B8 r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 10)]                 @ 0801D6BC r0 = u8 [log_finfo+0x13]
    cmp     r0, #0x73                       @ 0801D6BE compare r0 with 0x73
    bne     .Llog_scan_directory_D6CC       @ 0801D6C0 if (r0 != 0x73) goto 0x801D6CC
    ldr.w   r0, =log_finfo                  @ 0801D6C2 r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 11)]                 @ 0801D6C6 r0 = u8 [log_finfo+0x14]
    cmp     r0, #0x76                       @ 0801D6C8 compare r0 with 0x76
    beq     .Llog_scan_directory_D6EA       @ 0801D6CA if (r0 == 0x76) goto 0x801D6EA
.Llog_scan_directory_D6CC:              @ v2.05 0x0801D6CC, reached from 0x0801D6B6, 0x0801D6C0
    ldr.w   r0, =log_finfo                  @ 0801D6CC r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 9)]                 @ 0801D6D0 r0 = u8 [log_finfo+0x12]
    cmp     r0, #0x43                       @ 0801D6D2 compare r0 with 0x43
    bne     .Llog_scan_directory_D670       @ 0801D6D4 if (r0 != 0x43) goto 0x801D670
    ldr.w   r0, =log_finfo                  @ 0801D6D6 r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 10)]                 @ 0801D6DA r0 = u8 [log_finfo+0x13]
    cmp     r0, #0x53                       @ 0801D6DC compare r0 with 0x53
    bne     .Llog_scan_directory_D670       @ 0801D6DE if (r0 != 0x53) goto 0x801D670
    ldr.w   r0, =log_finfo                  @ 0801D6E0 r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 11)]                 @ 0801D6E4 r0 = u8 [log_finfo+0x14]
    cmp     r0, #0x56                       @ 0801D6E6 compare r0 with 0x56
    bne     .Llog_scan_directory_D670       @ 0801D6E8 if (r0 != 0x56) goto 0x801D670
    @ digits 1-2 year, 3-4 month, 5-6 day: character * 10 + next character - 0x10 (= two ASCII digits)
.Llog_scan_directory_D6EA:              @ v2.05 0x0801D6EA, reached from 0x0801D6CA
    @ IMP-32: with long names (exFAT, or LFN entries on FAT) fname can be longer than 8.3: only a 12-character name
    @ "YYMMDDnn.csv" is one of the meter's files (v2.05's 8.3 names had no character after position 11)
    ldr.w   r0, =log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 12)]
    cmp     r0, #0
    bne     .Llog_scan_directory_D670
    ldr.w   r0, =log_finfo                  @ 0801D6EA r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 0)]                    @ 0801D6EE r0 = u8 [log_finfo+0x9]
    movs    r1, #0xa                        @ 0801D6F0 r1 = 0xa
    ldr.w   r2, =log_finfo                  @ 0801D6F2 r2 = &log_finfo
    ldrb    r2, [r2, #(FNO_FNAME + 1)]                  @ 0801D6F6 r2 = u8 [log_finfo+0xA]
    mla     r0, r1, r0, r2                  @ 0801D6F8
    subs    r0, #0x10                       @ 0801D6FC r0 -= 0x10
    ldr.w   r1, =log_scan_year              @ 0801D6FE r1 = &log_scan_year
    strb    r0, [r1]                        @ 0801D702 u8 [log_scan_year] = r0
    ldr.w   r0, =log_finfo                  @ 0801D704 r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 2)]                  @ 0801D708 r0 = u8 [log_finfo+0xB]
    movs    r1, #0xa                        @ 0801D70A r1 = 0xa
    ldr.w   r2, =log_finfo                  @ 0801D70C r2 = &log_finfo
    ldrb    r2, [r2, #(FNO_FNAME + 3)]                  @ 0801D710 r2 = u8 [log_finfo+0xC]
    mla     r0, r1, r0, r2                  @ 0801D712
    subs    r0, #0x10                       @ 0801D716 r0 -= 0x10
    ldr.w   r1, =log_scan_month             @ 0801D718 r1 = &log_scan_month
    strb    r0, [r1]                        @ 0801D71C u8 [log_scan_month] = r0
    ldr.w   r0, =log_finfo                  @ 0801D71E r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 4)]                  @ 0801D722 r0 = u8 [log_finfo+0xD]
    movs    r1, #0xa                        @ 0801D724 r1 = 0xa
    ldr.w   r2, =log_finfo                  @ 0801D726 r2 = &log_finfo
    ldrb    r2, [r2, #(FNO_FNAME + 5)]                  @ 0801D72A r2 = u8 [log_finfo+0xE]
    mla     r0, r1, r0, r2                  @ 0801D72C
    subs    r0, #0x10                       @ 0801D730 r0 -= 0x10
    ldr.w   r1, =log_scan_day               @ 0801D732 r1 = &log_scan_day
    strb    r0, [r1]                        @ 0801D736 u8 [log_scan_day] = r0
    @ same day as today?
    ldr.w   r0, =log_scan_year              @ 0801D738 r0 = &log_scan_year
    ldrb    r0, [r0]                        @ 0801D73C r0 = u8 [log_scan_year]
    ldr.w   r1, =rtc_year                   @ 0801D73E r1 = &rtc_year
    ldrb    r1, [r1]                        @ 0801D742 r1 = u8 [rtc_year]
    cmp     r0, r1                          @ 0801D744 compare r0 with r1
    bne     .Llog_scan_directory_D670       @ 0801D746 if (r0 != r1) goto 0x801D670
    ldr.w   r0, =log_scan_month             @ 0801D748 r0 = &log_scan_month
    ldrb    r0, [r0]                        @ 0801D74C r0 = u8 [log_scan_month]
    ldr.w   r1, =rtc_month                  @ 0801D74E r1 = &rtc_month
    ldrb    r1, [r1]                        @ 0801D752 r1 = u8 [rtc_month]
    cmp     r0, r1                          @ 0801D754 compare r0 with r1
    bne     .Llog_scan_directory_D670       @ 0801D756 if (r0 != r1) goto 0x801D670
    ldr.w   r0, =log_scan_day               @ 0801D758 r0 = &log_scan_day
    ldrb    r0, [r0]                        @ 0801D75C r0 = u8 [log_scan_day]
    ldr.w   r1, =rtc_day                    @ 0801D75E r1 = &rtc_day
    ldrb    r1, [r1]                        @ 0801D762 r1 = u8 [rtc_day]
    cmp     r0, r1                          @ 0801D764 compare r0 with r1
    bne     .Llog_scan_directory_D670       @ 0801D766 if (r0 != r1) goto 0x801D670
    @ digits 7-8 give nn; keep the largest, +1
    ldr.w   r0, =log_finfo                  @ 0801D768 r0 = &log_finfo
    ldrb    r0, [r0, #(FNO_FNAME + 6)]                  @ 0801D76C r0 = u8 [log_finfo+0xF]
    movs    r1, #0xa                        @ 0801D76E r1 = 0xa
    ldr.w   r2, =log_finfo                  @ 0801D770 r2 = &log_finfo
    ldrb    r2, [r2, #(FNO_FNAME + 7)]                 @ 0801D774 r2 = u8 [log_finfo+0x10]
    mla     r0, r1, r0, r2                  @ 0801D776
    subw    r0, r0, #0x20f                  @ 0801D77A
    movs    r5, r0                          @ 0801D77E r5 = r0
    cmp     r6, r5                          @ 0801D780 compare r6 with r5
    bge.w   .Llog_scan_directory_D670       @ 0801D782 if (r6 >= r5) goto 0x801D670
    movs    r6, r5                          @ 0801D786 r6 = r5
    b       .Llog_scan_directory_D670       @ 0801D788 goto 0x801D670
    @ 100 or more files today: start again at 0
.Llog_scan_directory_D78A:              @ v2.05 0x0801D78A, reached from 0x0801D6A2
    movs    r0, #0                          @ 0801D78A r0 = 0
    ldr.w   r1, =log_next_index             @ 0801D78C r1 = &log_next_index
    str     r0, [r1]                        @ 0801D790 u32 [log_next_index] = r0
.Llog_scan_directory_D792:              @ v2.05 0x0801D792, reached from 0x0801D66C, 0x0801D6A0
    ldr     r0, =log_fresult                @ 0801D792 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801D794 r0 = u8 [log_fresult]
.Llog_scan_directory_D796:              @ v2.05 0x0801D796, reached from 0x0801D662
    pop     {r4, r5, r6, pc}                @ 0801D796 pop {r4, r5, r6, pc}
ENDFUNC log_scan_directory
    .ltorg

@ -----------------------------------------------------------------------------
@ log_build_suffix_name - derive the name of a forced file from the previous name and log_file_seq
@ Replaces  : 0x0801D79C FUN_0801D79C (v2.05), called by log_select_file
@ In        : -
@ Out       : -
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : modifies log_name_buf; writes log_name_ptr
@ Spec      : v2.05 listing 0x0801D79C..0x0801D825
@ Note      : for the first forced file (log_file_seq = 1) characters 2..7 of the name move to positions 0..5; the last two
@             characters become the two decimal digits of log_file_seq.  The extension is already in the buffer.
@ -----------------------------------------------------------------------------
FUNC log_build_suffix_name
    ldr.w   r0, =log_file_seq               @ 0801D79C r0 = &log_file_seq
    ldrh    r0, [r0]                        @ 0801D7A0 r0 = u16 [log_file_seq]
    @ first forced file: shift the name left by two characters
    cmp     r0, #1                          @ 0801D7A2 compare r0 with 1
    bne     .Llog_build_suffix_name_D7EE    @ 0801D7A4 if (r0 != 1) goto 0x801D7EE
    ldr.w   r0, =log_name_buf               @ 0801D7A6 r0 = &log_name_buf
    ldrb    r0, [r0, #2]                    @ 0801D7AA r0 = u8 [log_name_buf+0x2]
    ldr.w   r1, =log_name_buf               @ 0801D7AC r1 = &log_name_buf
    strb    r0, [r1]                        @ 0801D7B0 u8 [log_name_buf] = r0
    ldr.w   r0, =log_name_buf               @ 0801D7B2 r0 = &log_name_buf
    ldrb    r0, [r0, #3]                    @ 0801D7B6 r0 = u8 [log_name_buf+0x3]
    ldr.w   r1, =log_name_buf               @ 0801D7B8 r1 = &log_name_buf
    strb    r0, [r1, #1]                    @ 0801D7BC u8 [log_name_buf+0x1] = r0
    ldr.w   r0, =log_name_buf               @ 0801D7BE r0 = &log_name_buf
    ldrb    r0, [r0, #4]                    @ 0801D7C2 r0 = u8 [log_name_buf+0x4]
    ldr.w   r1, =log_name_buf               @ 0801D7C4 r1 = &log_name_buf
    strb    r0, [r1, #2]                    @ 0801D7C8 u8 [log_name_buf+0x2] = r0
    ldr.w   r0, =log_name_buf               @ 0801D7CA r0 = &log_name_buf
    ldrb    r0, [r0, #5]                    @ 0801D7CE r0 = u8 [log_name_buf+0x5]
    ldr.w   r1, =log_name_buf               @ 0801D7D0 r1 = &log_name_buf
    strb    r0, [r1, #3]                    @ 0801D7D4 u8 [log_name_buf+0x3] = r0
    ldr.w   r0, =log_name_buf               @ 0801D7D6 r0 = &log_name_buf
    ldrb    r0, [r0, #6]                    @ 0801D7DA r0 = u8 [log_name_buf+0x6]
    ldr.w   r1, =log_name_buf               @ 0801D7DC r1 = &log_name_buf
    strb    r0, [r1, #4]                    @ 0801D7E0 u8 [log_name_buf+0x4] = r0
    ldr.w   r0, =log_name_buf               @ 0801D7E2 r0 = &log_name_buf
    ldrb    r0, [r0, #7]                    @ 0801D7E6 r0 = u8 [log_name_buf+0x7]
    ldr.w   r1, =log_name_buf               @ 0801D7E8 r1 = &log_name_buf
    strb    r0, [r1, #5]                    @ 0801D7EC u8 [log_name_buf+0x5] = r0
    @ characters 6 and 7 = log_file_seq / 10 and log_file_seq % 10 as ASCII
.Llog_build_suffix_name_D7EE:           @ v2.05 0x0801D7EE, reached from 0x0801D7A4
    ldr.w   r0, =log_file_seq               @ 0801D7EE r0 = &log_file_seq
    ldrh    r0, [r0]                        @ 0801D7F2 r0 = u16 [log_file_seq]
    movs    r1, #0xa                        @ 0801D7F4 r1 = 0xa
    sdiv    r0, r0, r1                      @ 0801D7F6
    adds    r0, #0x30                       @ 0801D7FA r0 += 0x30
    ldr.w   r1, =log_name_buf               @ 0801D7FC r1 = &log_name_buf
    strb    r0, [r1, #6]                    @ 0801D800 u8 [log_name_buf+0x6] = r0
    ldr.w   r0, =log_file_seq               @ 0801D802 r0 = &log_file_seq
    ldrh    r0, [r0]                        @ 0801D806 r0 = u16 [log_file_seq]
    movs    r1, #0xa                        @ 0801D808 r1 = 0xa
    sdiv    r2, r0, r1                      @ 0801D80A
    mls     r0, r1, r2, r0                  @ 0801D80E
    adds    r0, #0x30                       @ 0801D812 r0 += 0x30
    ldr.w   r1, =log_name_buf               @ 0801D814 r1 = &log_name_buf
    strb    r0, [r1, #7]                    @ 0801D818 u8 [log_name_buf+0x7] = r0
    ldr.w   r0, =log_name_buf               @ 0801D81A r0 = &log_name_buf
    ldr.w   r1, =log_name_ptr               @ 0801D81E r1 = &log_name_ptr
    str     r0, [r1]                        @ 0801D822 u32 [log_name_ptr] = r0
    bx      lr                              @ 0801D824 return
ENDFUNC log_build_suffix_name
    .ltorg

@ -----------------------------------------------------------------------------
@ log_build_dated_name - build the name YYMMDDnn.csv from the RTC date and the number r0
@ Replaces  : 0x0801D838 FUN_0801D838 (v2.05), called by log_select_file
@ In        : r0 = nn (0..99)
@ Out       : -
@ Clobbers  : r1-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads rtc_year, rtc_month, rtc_day; writes log_name_buf, log_name_ptr
@ Spec      : v2.05 listing 0x0801D838..0x0801D8FB
@ -----------------------------------------------------------------------------
FUNC log_build_dated_name
    @ year, month, day as two digits each (divide by 10 for the tens, modulus for the units)
    ldr.w   r1, =rtc_year                   @ 0801D838 r1 = &rtc_year
    ldrb    r1, [r1]                        @ 0801D83C r1 = u8 [rtc_year]
    movs    r2, #0xa                        @ 0801D83E r2 = 0xa
    sdiv    r1, r1, r2                      @ 0801D840
    adds    r1, #0x30                       @ 0801D844 r1 += 0x30
    ldr.w   r2, =log_name_buf               @ 0801D846 r2 = &log_name_buf
    strb    r1, [r2]                        @ 0801D84A u8 [log_name_buf] = r1
    ldr     r1, =rtc_year                   @ 0801D84C r1 = &rtc_year
    ldrb    r1, [r1]                        @ 0801D84E r1 = u8 [rtc_year]
    movs    r2, #0xa                        @ 0801D850 r2 = 0xa
    sdiv    r3, r1, r2                      @ 0801D852
    mls     r1, r2, r3, r1                  @ 0801D856
    adds    r1, #0x30                       @ 0801D85A r1 += 0x30
    ldr.w   r2, =log_name_buf               @ 0801D85C r2 = &log_name_buf
    strb    r1, [r2, #1]                    @ 0801D860 u8 [log_name_buf+0x1] = r1
    ldr     r1, =rtc_month                  @ 0801D862 r1 = &rtc_month
    ldrb    r1, [r1]                        @ 0801D864 r1 = u8 [rtc_month]
    movs    r2, #0xa                        @ 0801D866 r2 = 0xa
    sdiv    r1, r1, r2                      @ 0801D868
    adds    r1, #0x30                       @ 0801D86C r1 += 0x30
    ldr.w   r2, =log_name_buf               @ 0801D86E r2 = &log_name_buf
    strb    r1, [r2, #2]                    @ 0801D872 u8 [log_name_buf+0x2] = r1
    ldr     r1, =rtc_month                  @ 0801D874 r1 = &rtc_month
    ldrb    r1, [r1]                        @ 0801D876 r1 = u8 [rtc_month]
    movs    r2, #0xa                        @ 0801D878 r2 = 0xa
    sdiv    r3, r1, r2                      @ 0801D87A
    mls     r1, r2, r3, r1                  @ 0801D87E
    adds    r1, #0x30                       @ 0801D882 r1 += 0x30
    ldr.w   r2, =log_name_buf               @ 0801D884 r2 = &log_name_buf
    strb    r1, [r2, #3]                    @ 0801D888 u8 [log_name_buf+0x3] = r1
    ldr     r1, =rtc_day                    @ 0801D88A r1 = &rtc_day
    ldrb    r1, [r1]                        @ 0801D88C r1 = u8 [rtc_day]
    movs    r2, #0xa                        @ 0801D88E r2 = 0xa
    sdiv    r1, r1, r2                      @ 0801D890
    adds    r1, #0x30                       @ 0801D894 r1 += 0x30
    ldr.w   r2, =log_name_buf               @ 0801D896 r2 = &log_name_buf
    strb    r1, [r2, #4]                    @ 0801D89A u8 [log_name_buf+0x4] = r1
    ldr     r1, =rtc_day                    @ 0801D89C r1 = &rtc_day
    ldrb    r1, [r1]                        @ 0801D89E r1 = u8 [rtc_day]
    movs    r2, #0xa                        @ 0801D8A0 r2 = 0xa
    sdiv    r3, r1, r2                      @ 0801D8A2
    mls     r1, r2, r3, r1                  @ 0801D8A6
    adds    r1, #0x30                       @ 0801D8AA r1 += 0x30
    ldr.w   r2, =log_name_buf               @ 0801D8AC r2 = &log_name_buf
    strb    r1, [r2, #5]                    @ 0801D8B0 u8 [log_name_buf+0x5] = r1
    @ nn
    movs    r1, #0xa                        @ 0801D8B2 r1 = 0xa
    sdiv    r1, r0, r1                      @ 0801D8B4
    adds    r1, #0x30                       @ 0801D8B8 r1 += 0x30
    ldr.w   r2, =log_name_buf               @ 0801D8BA r2 = &log_name_buf
    strb    r1, [r2, #6]                    @ 0801D8BE u8 [log_name_buf+0x6] = r1
    movs    r1, #0xa                        @ 0801D8C0 r1 = 0xa
    sdiv    r2, r0, r1                      @ 0801D8C2
    mls     r1, r1, r2, r0                  @ 0801D8C6
    adds    r1, #0x30                       @ 0801D8CA r1 += 0x30
    ldr.w   r2, =log_name_buf               @ 0801D8CC r2 = &log_name_buf
    strb    r1, [r2, #7]                    @ 0801D8D0 u8 [log_name_buf+0x7] = r1
    @ ".csv" and the terminating NUL come from the buffer; log_name_ptr = log_name_buf
    movs    r1, #0x2e                       @ 0801D8D2 r1 = 0x2e
    ldr.w   r2, =log_name_buf               @ 0801D8D4 r2 = &log_name_buf
    strb    r1, [r2, #8]                    @ 0801D8D8 u8 [log_name_buf+0x8] = r1
    movs    r1, #0x63                       @ 0801D8DA r1 = 0x63
    ldr.w   r2, =log_name_buf               @ 0801D8DC r2 = &log_name_buf
    strb    r1, [r2, #9]                    @ 0801D8E0 u8 [log_name_buf+0x9] = r1
    movs    r1, #0x73                       @ 0801D8E2 r1 = 0x73
    ldr.w   r2, =log_name_buf               @ 0801D8E4 r2 = &log_name_buf
    strb    r1, [r2, #0xa]                  @ 0801D8E8 u8 [log_name_buf+0xA] = r1
    movs    r1, #0x76                       @ 0801D8EA r1 = 0x76
    ldr.w   r2, =log_name_buf               @ 0801D8EC r2 = &log_name_buf
    strb    r1, [r2, #0xb]                  @ 0801D8F0 u8 [log_name_buf+0xB] = r1
    ldr.w   r1, =log_name_buf               @ 0801D8F2 r1 = &log_name_buf
    ldr     r2, =log_name_ptr               @ 0801D8F6 r2 = &log_name_ptr
    str     r1, [r2]                        @ 0801D8F8 u32 [log_name_ptr] = r1
    bx      lr                              @ 0801D8FA return
ENDFUNC log_build_dated_name
    .ltorg

@ -----------------------------------------------------------------------------
@ log_flush_records - write the CSV header (first flush) or the pending rows
@ Replaces  : 0x0801D8FC FUN_0801D8FC (v2.05), called by log_session_once
@ In        : -
@ Out       : r0 = 0 ok, else the error of log_write_header / log_write_row (1)
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads/writes log_buf_len, log_row_no, log_row_no_start, log_pending, log_blocks, log_flush_failed, log_header_due
@ Spec      : v2.05 listing 0x0801D8FC..0x0801D9A5
@ Note      : with log_header_due set only the header is written.  Otherwise the rows of ring slots 0..log_pending-1 are written
@             in order, each followed by the min/max bookkeeping; a failing row restores log_row_no and sets log_flush_failed.
@             A flush of a whole ring (pending = 60) counts one more block.  log_pending is cleared at the end.
@ -----------------------------------------------------------------------------
FUNC log_flush_records
    push    {r3, r4, r5, lr}                @ 0801D8FC push {r3, r4, r5, lr}
    @ r5 = result; the byte count of the buffer starts at 0
    movs    r5, #0                          @ 0801D8FE r5 = 0
    movs    r0, #0                          @ 0801D900 r0 = 0
    ldr.w   r1, =log_buf_len                @ 0801D902 r1 = &log_buf_len
    strh    r0, [r1]                        @ 0801D906 u16 [log_buf_len] = r0
    @ header due: write the header
    ldr     r0, =log_header_due             @ 0801D908 r0 = &log_header_due
    ldrb    r0, [r0]                        @ 0801D90A r0 = u8 [log_header_due]
    cmp     r0, #0                          @ 0801D90C compare r0 with 0
    beq     .Llog_flush_records_D922        @ 0801D90E if (r0 == 0) goto 0x801D922
    bl      log_write_header                @ 0801D910 call log_write_header
    movs    r5, r0                          @ 0801D914 r5 = r0
    uxtb    r5, r5                          @ 0801D916 r5 = u8(r5)
    cmp     r5, #0                          @ 0801D918 compare r5 with 0
    beq     .Llog_flush_records_D9A0        @ 0801D91A if (r5 == 0) goto 0x801D9A0
    movs    r0, r5                          @ 0801D91C r0 = r5
    uxtb    r0, r0                          @ 0801D91E r0 = u8(r0)
    b       .Llog_flush_records_D9A4        @ 0801D920 goto 0x801D9A4
    @ remember the row number to go back to when the flush fails
.Llog_flush_records_D922:               @ v2.05 0x0801D922, reached from 0x0801D90E
    ldr.w   r0, =log_row_no                 @ 0801D922 r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801D926 r0 = u32 [log_row_no]
    ldr.w   r1, =log_row_no_start           @ 0801D928 r1 = &log_row_no_start
    str     r0, [r1]                        @ 0801D92C u32 [log_row_no_start] = r0
    movs    r0, #0                          @ 0801D92E r0 = 0
    movs    r4, r0                          @ 0801D930 r4 = r0
    @ row loop over the pending slots: log_row_no + 1, then the row of slot r4
.Llog_flush_records_D932:               @ v2.05 0x0801D932, reached from 0x0801D97A
    uxth    r4, r4                          @ 0801D932 r4 = u16(r4)
    ldr.w   r0, =log_pending                @ 0801D934 r0 = &log_pending
    ldr     r0, [r0]                        @ 0801D938 r0 = u32 [log_pending]
    cmp     r4, r0                          @ 0801D93A compare r4 with r0
    bhs     .Llog_flush_records_D97C        @ 0801D93C if (r4 >=u r0) goto 0x801D97C
    ldr.w   r0, =log_row_no                 @ 0801D93E r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801D942 r0 = u32 [log_row_no]
    adds    r0, r0, #1                      @ 0801D944 r0 = r0 + 1
    ldr.w   r1, =log_row_no                 @ 0801D946 r1 = &log_row_no
    str     r0, [r1]                        @ 0801D94A u32 [log_row_no] = r0
    movs    r0, r4                          @ 0801D94C r0 = r4
    uxth    r0, r0                          @ 0801D94E r0 = u16(r0)
    bl      log_write_row                   @ 0801D950 call log_write_row
    movs    r5, r0                          @ 0801D954 r5 = r0
    uxtb    r5, r5                          @ 0801D956 r5 = u8(r5)
    cmp     r5, #0                          @ 0801D958 compare r5 with 0
    beq     .Llog_flush_records_D974        @ 0801D95A if (r5 == 0) goto 0x801D974
    @ a failed row: flush marked failed, row number restored, return the error
    movs    r0, #1                          @ 0801D95C r0 = 1
    ldr     r1, =log_flush_failed           @ 0801D95E r1 = &log_flush_failed
    strb    r0, [r1]                        @ 0801D960 u8 [log_flush_failed] = r0
    ldr.w   r0, =log_row_no_start           @ 0801D962 r0 = &log_row_no_start
    ldr     r0, [r0]                        @ 0801D966 r0 = u32 [log_row_no_start]
    ldr.w   r1, =log_row_no                 @ 0801D968 r1 = &log_row_no
    str     r0, [r1]                        @ 0801D96C u32 [log_row_no] = r0
    movs    r0, r5                          @ 0801D96E r0 = r5
    uxtb    r0, r0                          @ 0801D970 r0 = u8(r0)
    b       .Llog_flush_records_D9A4        @ 0801D972 goto 0x801D9A4
    @ update the minimum and maximum
.Llog_flush_records_D974:               @ v2.05 0x0801D974, reached from 0x0801D95A
    bl      log_track_extremes              @ 0801D974 call log_track_extremes
    adds    r4, r4, #1                      @ 0801D978 r4 = r4 + 1
    b       .Llog_flush_records_D932        @ 0801D97A goto 0x801D932
    @ all rows written: a full ring counts as one block; nothing is pending any more
.Llog_flush_records_D97C:               @ v2.05 0x0801D97C, reached from 0x0801D93C
    movs    r0, #0                          @ 0801D97C r0 = 0
    ldr.w   r1, =log_row_no_start           @ 0801D97E r1 = &log_row_no_start
    str     r0, [r1]                        @ 0801D982 u32 [log_row_no_start] = r0
    ldr.w   r0, =log_pending                @ 0801D984 r0 = &log_pending
    ldr     r0, [r0]                        @ 0801D988 r0 = u32 [log_pending]
    cmp     r0, #0x3c                       @ 0801D98A compare r0 with 0x3c
    bne     .Llog_flush_records_D998        @ 0801D98C if (r0 != 0x3c) goto 0x801D998
    ldr     r0, =log_blocks                 @ 0801D98E r0 = &log_blocks
    ldr     r0, [r0]                        @ 0801D990 r0 = u32 [log_blocks]
    adds    r0, r0, #1                      @ 0801D992 r0 = r0 + 1
    ldr     r1, =log_blocks                 @ 0801D994 r1 = &log_blocks
    str     r0, [r1]                        @ 0801D996 u32 [log_blocks] = r0
.Llog_flush_records_D998:               @ v2.05 0x0801D998, reached from 0x0801D98C
    movs    r0, #0                          @ 0801D998 r0 = 0
    ldr.w   r1, =log_pending                @ 0801D99A r1 = &log_pending
    str     r0, [r1]                        @ 0801D99E u32 [log_pending] = r0
.Llog_flush_records_D9A0:               @ v2.05 0x0801D9A0, reached from 0x0801D91A
    movs    r0, r5                          @ 0801D9A0 r0 = r5
    uxtb    r0, r0                          @ 0801D9A2 r0 = u8(r0)
.Llog_flush_records_D9A4:               @ v2.05 0x0801D9A4, reached from 0x0801D920, 0x0801D972
    pop     {r1, r4, r5, pc}                @ 0801D9A4 pop {r1, r4, r5, pc}
ENDFUNC log_flush_records
    .ltorg

@ -----------------------------------------------------------------------------
@ log_track_extremes - update the maximum and minimum of the file with the row that was just written
@ Replaces  : 0x0801D9AC FUN_0801D9AC (v2.05), called by log_flush_records
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_row_no, log_max_flags, log_min_flags; calls log_track_max_main, log_track_min_main, log_take_max_main, log_take_min_main
@ Spec      : v2.05 listing 0x0801D9AC..0x0801DA39
@ Note      : row 1 starts both extremes.  For later rows the comparison is skipped when the stored maximum is a positive overflow
@             (flags bit 7 set, bit 6 clear: nothing can exceed it) or when the stored minimum is a negative overflow (bits 7 and 6
@             set: nothing can be below it); otherwise log_track_max_main / log_track_min_main compare the loaded record.
@ -----------------------------------------------------------------------------
FUNC log_track_extremes
    @ row 1: both extremes start with it
    push    {r3, r4, r5, lr}                @ 0801D9AC push {r3, r4, r5, lr}
    ldr     r0, =log_row_no                 @ 0801D9AE r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801D9B0 r0 = u32 [log_row_no]
    cmp     r0, #1                          @ 0801D9B2 compare r0 with 1
    bne     .Llog_track_extremes_D9BC       @ 0801D9B4 if (r0 != 1) goto 0x801D9BC
    bl      log_take_max_main               @ 0801D9B6 call log_take_max_main
    b       .Llog_track_extremes_D9F0       @ 0801D9BA goto 0x801D9F0
    @ maximum: r4 = stored flags & 0x80 (overflow), r5 = stored flags & 0x40 (negative); skip when overflow and not negative
.Llog_track_extremes_D9BC:              @ v2.05 0x0801D9BC, reached from 0x0801D9B4
    ldr.w   r0, =log_max_flags              @ 0801D9BC r0 = &log_max_flags
    ldrb    r0, [r0]                        @ 0801D9C0 r0 = u8 [log_max_flags]
    ands    r0, r0, #0x80                   @ 0801D9C2 r0 = r0 & 0x80
    movs    r4, r0                          @ 0801D9C6 r4 = r0
    ldr.w   r0, =log_max_flags              @ 0801D9C8 r0 = &log_max_flags
    ldrb    r0, [r0]                        @ 0801D9CC r0 = u8 [log_max_flags]
    ands    r0, r0, #0x40                   @ 0801D9CE r0 = r0 & 0x40
    movs    r5, r0                          @ 0801D9D2 r5 = r0
    uxtb    r4, r4                          @ 0801D9D4 r4 = u8(r4)
    cmp     r4, #0                          @ 0801D9D6 compare r4 with 0
    beq     .Llog_track_extremes_D9E6       @ 0801D9D8 if (r4 == 0) goto 0x801D9E6
    uxtb    r5, r5                          @ 0801D9DA r5 = u8(r5)
    cmp     r5, #0                          @ 0801D9DC compare r5 with 0
    beq     .Llog_track_extremes_D9E6       @ 0801D9DE if (r5 == 0) goto 0x801D9E6
    bl      log_track_max_main              @ 0801D9E0 call log_track_max_main
    b       .Llog_track_extremes_D9F0       @ 0801D9E4 goto 0x801D9F0
.Llog_track_extremes_D9E6:              @ v2.05 0x0801D9E6, reached from 0x0801D9D8, 0x0801D9DE
    uxtb    r4, r4                          @ 0801D9E6 r4 = u8(r4)
    cmp     r4, #0                          @ 0801D9E8 compare r4 with 0
    bne     .Llog_track_extremes_D9F0       @ 0801D9EA if (r4 != 0) goto 0x801D9F0
    bl      log_track_max_main              @ 0801D9EC call log_track_max_main
    @ minimum: skip when overflow and negative
.Llog_track_extremes_D9F0:              @ v2.05 0x0801D9F0, reached from 0x0801D9BA, 0x0801D9E4, 0x0801D9EA
    ldr     r0, =log_row_no                 @ 0801D9F0 r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801D9F2 r0 = u32 [log_row_no]
    cmp     r0, #1                          @ 0801D9F4 compare r0 with 1
    bne     .Llog_track_extremes_D9FE       @ 0801D9F6 if (r0 != 1) goto 0x801D9FE
    bl      log_take_min_main               @ 0801D9F8 call log_take_min_main
    b       .Llog_track_extremes_DA38       @ 0801D9FC goto 0x801DA38
.Llog_track_extremes_D9FE:              @ v2.05 0x0801D9FE, reached from 0x0801D9F6
    ldr.w   r0, =log_min_flags              @ 0801D9FE r0 = &log_min_flags
    ldrb    r0, [r0]                        @ 0801DA02 r0 = u8 [log_min_flags]
    ands    r0, r0, #0x80                   @ 0801DA04 r0 = r0 & 0x80
    movs    r4, r0                          @ 0801DA08 r4 = r0
    ldr.w   r0, =log_min_flags              @ 0801DA0A r0 = &log_min_flags
    ldrb    r0, [r0]                        @ 0801DA0E r0 = u8 [log_min_flags]
    ands    r0, r0, #0x40                   @ 0801DA10 r0 = r0 & 0x40
    movs    r5, r0                          @ 0801DA14 r5 = r0
    uxtb    r4, r4                          @ 0801DA16 r4 = u8(r4)
    cmp     r4, #0                          @ 0801DA18 compare r4 with 0
    beq     .Llog_track_extremes_DA28       @ 0801DA1A if (r4 == 0) goto 0x801DA28
    uxtb    r5, r5                          @ 0801DA1C r5 = u8(r5)
    cmp     r5, #0                          @ 0801DA1E compare r5 with 0
    bne     .Llog_track_extremes_DA28       @ 0801DA20 if (r5 != 0) goto 0x801DA28
    bl      log_track_min_main              @ 0801DA22 call log_track_min_main
    b       .Llog_track_extremes_DA38       @ 0801DA26 goto 0x801DA38
.Llog_track_extremes_DA28:              @ v2.05 0x0801DA28, reached from 0x0801DA1A, 0x0801DA20
    uxtb    r4, r4                          @ 0801DA28 r4 = u8(r4)
    cmp     r4, #0                          @ 0801DA2A compare r4 with 0
    beq     .Llog_track_extremes_DA34       @ 0801DA2C if (r4 == 0) goto 0x801DA34
    uxtb    r5, r5                          @ 0801DA2E r5 = u8(r5)
    cmp     r5, #0                          @ 0801DA30 compare r5 with 0
    bne     .Llog_track_extremes_DA38       @ 0801DA32 if (r5 != 0) goto 0x801DA38
.Llog_track_extremes_DA34:              @ v2.05 0x0801DA34, reached from 0x0801DA2C
    bl      log_track_min_main              @ 0801DA34 call log_track_min_main
.Llog_track_extremes_DA38:              @ v2.05 0x0801DA38, reached from 0x0801D9FC, 0x0801DA26, 0x0801DA32
    pop     {r0, r4, r5, pc}                @ 0801DA38 pop {r0, r4, r5, pc}
ENDFUNC log_track_extremes
    .ltorg

@ -----------------------------------------------------------------------------
@ log_track_max_main - take the loaded record as new maximum if it is larger than the stored maximum
@ Replaces  : 0x0801DA40 FUN_0801DA40 (v2.05), called by log_track_extremes
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_view_flags1, log_view_value1, log_max_flags, log_max_value; may call log_take_max_main
@ Spec      : v2.05 listing 0x0801DA40..0x0801DAB1
@ Note      : an overflow row (flags bit 7) is never a candidate.  A negative value is stored complemented (flags bit 6), so both
@             values are turned back into signed numbers (complement when bit 6 is set) before the signed comparison.
@ -----------------------------------------------------------------------------
FUNC log_track_max_main
    push    {r3, r4, r5, r6, r7, lr}        @ 0801DA40 push {r3, r4, r5, r6, r7, lr}
    @ flags of the loaded record: r6 = bit 7 (overflow), r7 = bit 6 (negative)
    ldr.w   r0, =log_view_flags1            @ 0801DA42 r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DA46 r0 = u8 [log_view_flags1]
    ands    r0, r0, #0x80                   @ 0801DA48 r0 = r0 & 0x80
    movs    r6, r0                          @ 0801DA4C r6 = r0
    ldr.w   r0, =log_view_flags1            @ 0801DA4E r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DA52 r0 = u8 [log_view_flags1]
    ands    r0, r0, #0x40                   @ 0801DA54 r0 = r0 & 0x40
    movs    r7, r0                          @ 0801DA58 r7 = r0
    @ an overflow row is skipped
    uxtb    r6, r6                          @ 0801DA5A r6 = u8(r6)
    cmp     r6, #0                          @ 0801DA5C compare r6 with 0
    beq     .Llog_track_max_main_DA66       @ 0801DA5E if (r6 == 0) goto 0x801DA66
    uxtb    r7, r7                          @ 0801DA60 r7 = u8(r7)
    cmp     r7, #0                          @ 0801DA62 compare r7 with 0
    bne     .Llog_track_max_main_DAB0       @ 0801DA64 if (r7 != 0) goto 0x801DAB0
.Llog_track_max_main_DA66:              @ v2.05 0x0801DA66, reached from 0x0801DA5E
    uxtb    r6, r6                          @ 0801DA66 r6 = u8(r6)
    cmp     r6, #0                          @ 0801DA68 compare r6 with 0
    bne     .Llog_track_max_main_DAB0       @ 0801DA6A if (r6 != 0) goto 0x801DAB0
    @ stored maximum as signed number
    ldr.w   r0, =log_max_flags              @ 0801DA6C r0 = &log_max_flags
    ldrb    r0, [r0]                        @ 0801DA70 r0 = u8 [log_max_flags]
    lsls    r0, r0, #0x19                   @ 0801DA72 r0 = r0 << 0x19
    bpl     .Llog_track_max_main_DA82       @ 0801DA74 if (r0 >=0 0) goto 0x801DA82
    ldr.w   r0, =log_max_value              @ 0801DA76 r0 = &log_max_value
    ldr     r0, [r0]                        @ 0801DA7A r0 = u32 [log_max_value]
    mvns    r0, r0                          @ 0801DA7C r0 = ~r0
    movs    r5, r0                          @ 0801DA7E r5 = r0
    b       .Llog_track_max_main_DA8A       @ 0801DA80 goto 0x801DA8A
.Llog_track_max_main_DA82:              @ v2.05 0x0801DA82, reached from 0x0801DA74
    ldr.w   r0, =log_max_value              @ 0801DA82 r0 = &log_max_value
    ldr     r0, [r0]                        @ 0801DA86 r0 = u32 [log_max_value]
    movs    r5, r0                          @ 0801DA88 r5 = r0
    @ loaded value as signed number
.Llog_track_max_main_DA8A:              @ v2.05 0x0801DA8A, reached from 0x0801DA80
    ldr.w   r0, =log_view_flags1            @ 0801DA8A r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DA8E r0 = u8 [log_view_flags1]
    lsls    r0, r0, #0x19                   @ 0801DA90 r0 = r0 << 0x19
    bpl     .Llog_track_max_main_DAA0       @ 0801DA92 if (r0 >=0 0) goto 0x801DAA0
    ldr.w   r0, =log_view_value1            @ 0801DA94 r0 = &log_view_value1
    ldr     r0, [r0]                        @ 0801DA98 r0 = u32 [log_view_value1]
    mvns    r0, r0                          @ 0801DA9A r0 = ~r0
    movs    r4, r0                          @ 0801DA9C r4 = r0
    b       .Llog_track_max_main_DAA8       @ 0801DA9E goto 0x801DAA8
.Llog_track_max_main_DAA0:              @ v2.05 0x0801DAA0, reached from 0x0801DA92
    ldr.w   r0, =log_view_value1            @ 0801DAA0 r0 = &log_view_value1
    ldr     r0, [r0]                        @ 0801DAA4 r0 = u32 [log_view_value1]
    movs    r4, r0                          @ 0801DAA6 r4 = r0
    @ stored < loaded: the loaded record becomes the maximum
.Llog_track_max_main_DAA8:              @ v2.05 0x0801DAA8, reached from 0x0801DA9E
    cmp     r5, r4                          @ 0801DAA8 compare r5 with r4
    bge     .Llog_track_max_main_DAB0       @ 0801DAAA if (r5 >= r4) goto 0x801DAB0
    bl      log_take_max_main               @ 0801DAAC call log_take_max_main
.Llog_track_max_main_DAB0:              @ v2.05 0x0801DAB0, reached from 0x0801DA64, 0x0801DA6A, 0x0801DAAA
    pop     {r0, r4, r5, r6, r7, pc}        @ 0801DAB0 pop {r0, r4, r5, r6, r7, pc}
ENDFUNC log_track_max_main
    .ltorg

@ -----------------------------------------------------------------------------
@ log_track_min_main - take the loaded record as new minimum if it is smaller than the stored minimum
@ Replaces  : 0x0801DAB2 FUN_0801DAB2 (v2.05), called by log_track_extremes
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_view_flags1, log_view_value1, log_min_flags, log_min_value; may call log_take_min_main
@ Spec      : v2.05 listing 0x0801DAB2..0x0801DB25
@ Note      : a positive overflow row (bit 7 set, bit 6 clear) is skipped.  A negative overflow row is compared like any other:
@             its stored value 0x7FFFFFFF complemented is the smallest signed number.  The test at 0x0801DADC (r6 and r7 are the masks
@             0x80 and 0x40, so their AND is always 0) never skips a row.
@ -----------------------------------------------------------------------------
FUNC log_track_min_main
    push    {r3, r4, r5, r6, r7, lr}        @ 0801DAB2 push {r3, r4, r5, r6, r7, lr}
    @ flags of the loaded record: r6 = bit 7 (overflow), r7 = bit 6 (negative)
    ldr.w   r0, =log_view_flags1            @ 0801DAB4 r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DAB8 r0 = u8 [log_view_flags1]
    ands    r0, r0, #0x80                   @ 0801DABA r0 = r0 & 0x80
    movs    r6, r0                          @ 0801DABE r6 = r0
    ldr.w   r0, =log_view_flags1            @ 0801DAC0 r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DAC4 r0 = u8 [log_view_flags1]
    ands    r0, r0, #0x40                   @ 0801DAC6 r0 = r0 & 0x40
    movs    r7, r0                          @ 0801DACA r7 = r0
    uxtb    r6, r6                          @ 0801DACC r6 = u8(r6)
    cmp     r6, #0                          @ 0801DACE compare r6 with 0
    @ positive overflow: skip
    beq     .Llog_track_min_main_DAD8       @ 0801DAD0 if (r6 == 0) goto 0x801DAD8
    uxtb    r7, r7                          @ 0801DAD2 r7 = u8(r7)
    cmp     r7, #0                          @ 0801DAD4 compare r7 with 0
    beq     .Llog_track_min_main_DB24       @ 0801DAD6 if (r7 == 0) goto 0x801DB24
.Llog_track_min_main_DAD8:              @ v2.05 0x0801DAD8, reached from 0x0801DAD0
    movs    r0, r6                          @ 0801DAD8 r0 = r6
    uxtb    r0, r0                          @ 0801DADA r0 = u8(r0)
    tst     r0, r7                          @ 0801DADC compare r0 with r7
    bne     .Llog_track_min_main_DB24       @ 0801DADE if ((r0 & r7) != 0) goto 0x801DB24
    @ stored minimum as signed number
    ldr.w   r0, =log_min_flags              @ 0801DAE0 r0 = &log_min_flags
    ldrb    r0, [r0]                        @ 0801DAE4 r0 = u8 [log_min_flags]
    lsls    r0, r0, #0x19                   @ 0801DAE6 r0 = r0 << 0x19
    bpl     .Llog_track_min_main_DAF6       @ 0801DAE8 if (r0 >=0 0) goto 0x801DAF6
    ldr.w   r0, =log_min_value              @ 0801DAEA r0 = &log_min_value
    ldr     r0, [r0]                        @ 0801DAEE r0 = u32 [log_min_value]
    mvns    r0, r0                          @ 0801DAF0 r0 = ~r0
    movs    r5, r0                          @ 0801DAF2 r5 = r0
    b       .Llog_track_min_main_DAFE       @ 0801DAF4 goto 0x801DAFE
.Llog_track_min_main_DAF6:              @ v2.05 0x0801DAF6, reached from 0x0801DAE8
    ldr.w   r0, =log_min_value              @ 0801DAF6 r0 = &log_min_value
    ldr     r0, [r0]                        @ 0801DAFA r0 = u32 [log_min_value]
    movs    r5, r0                          @ 0801DAFC r5 = r0
    @ loaded value as signed number
.Llog_track_min_main_DAFE:              @ v2.05 0x0801DAFE, reached from 0x0801DAF4
    ldr.w   r0, =log_view_flags1            @ 0801DAFE r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DB02 r0 = u8 [log_view_flags1]
    lsls    r0, r0, #0x19                   @ 0801DB04 r0 = r0 << 0x19
    bpl     .Llog_track_min_main_DB14       @ 0801DB06 if (r0 >=0 0) goto 0x801DB14
    ldr.w   r0, =log_view_value1            @ 0801DB08 r0 = &log_view_value1
    ldr     r0, [r0]                        @ 0801DB0C r0 = u32 [log_view_value1]
    mvns    r0, r0                          @ 0801DB0E r0 = ~r0
    movs    r4, r0                          @ 0801DB10 r4 = r0
    b       .Llog_track_min_main_DB1C       @ 0801DB12 goto 0x801DB1C
.Llog_track_min_main_DB14:              @ v2.05 0x0801DB14, reached from 0x0801DB06
    ldr.w   r0, =log_view_value1            @ 0801DB14 r0 = &log_view_value1
    ldr     r0, [r0]                        @ 0801DB18 r0 = u32 [log_view_value1]
    movs    r4, r0                          @ 0801DB1A r4 = r0
    @ loaded < stored: the loaded record becomes the minimum
.Llog_track_min_main_DB1C:              @ v2.05 0x0801DB1C, reached from 0x0801DB12
    cmp     r4, r5                          @ 0801DB1C compare r4 with r5
    bge     .Llog_track_min_main_DB24       @ 0801DB1E if (r4 >= r5) goto 0x801DB24
    bl      log_take_min_main               @ 0801DB20 call log_take_min_main
.Llog_track_min_main_DB24:              @ v2.05 0x0801DB24, reached from 0x0801DAD6, 0x0801DADE, 0x0801DB1E
    pop     {r0, r4, r5, r6, r7, pc}        @ 0801DB24 pop {r0, r4, r5, r6, r7, pc}
ENDFUNC log_track_min_main
    .ltorg

@ -----------------------------------------------------------------------------
@ log_take_max_main - store the loaded record as the maximum of the file
@ Replaces  : 0x0801DB34 FUN_0801DB34 (v2.05), called by log_track_extremes and log_track_max_main
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_row_no, log_view_func1, log_view_flags1, log_view_value1; writes log_max_row, log_max_func, log_max_flags, log_max_value;
@             production also log_max_time (tail call log_mm_save, log/mmtime.s)
@ Spec      : v2.05 listing 0x0801DB34..0x0801DB63
@ -----------------------------------------------------------------------------
FUNC log_take_max_main
    ldr     r0, =log_row_no                 @ 0801DB34 r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801DB36 r0 = u32 [log_row_no]
    ldr.w   r1, =log_max_row                @ 0801DB38 r1 = &log_max_row
    str     r0, [r1]                        @ 0801DB3C u32 [log_max_row] = r0
    ldr.w   r0, =log_view_func1             @ 0801DB3E r0 = &log_view_func1
    ldrb    r0, [r0]                        @ 0801DB42 r0 = u8 [log_view_func1]
    ldr.w   r1, =log_max_func               @ 0801DB44 r1 = &log_max_func
    strb    r0, [r1]                        @ 0801DB48 u8 [log_max_func] = r0
    ldr.w   r0, =log_view_flags1            @ 0801DB4A r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DB4E r0 = u8 [log_view_flags1]
    ldr.w   r1, =log_max_flags              @ 0801DB50 r1 = &log_max_flags
    strb    r0, [r1]                        @ 0801DB54 u8 [log_max_flags] = r0
    ldr.w   r0, =log_view_value1            @ 0801DB56 r0 = &log_view_value1
    ldr     r0, [r0]                        @ 0801DB5A r0 = u32 [log_view_value1]
    ldr.w   r1, =log_max_value              @ 0801DB5C r1 = &log_max_value
    str     r0, [r1]                        @ 0801DB60 u32 [log_max_value] = r0
    ldr     r0, =log_max_time                @ production: keep the date and time of the row (log/mmtime.s)
    b       log_mm_save                     @ tail call, returns to the caller
ENDFUNC log_take_max_main
    .ltorg

@ -----------------------------------------------------------------------------
@ log_take_min_main - store the loaded record as the minimum of the file
@ Replaces  : 0x0801DB64 FUN_0801DB64 (v2.05), called by log_track_extremes and log_track_min_main
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_row_no, log_view_func1, log_view_flags1, log_view_value1; writes log_min_row, log_min_func, log_min_flags, log_min_value;
@             production also log_min_time (tail call log_mm_save, log/mmtime.s)
@ Spec      : v2.05 listing 0x0801DB64..0x0801DB93
@ -----------------------------------------------------------------------------
FUNC log_take_min_main
    ldr     r0, =log_row_no                 @ 0801DB64 r0 = &log_row_no
    ldr     r0, [r0]                        @ 0801DB66 r0 = u32 [log_row_no]
    ldr.w   r1, =log_min_row                @ 0801DB68 r1 = &log_min_row
    str     r0, [r1]                        @ 0801DB6C u32 [log_min_row] = r0
    ldr.w   r0, =log_view_func1             @ 0801DB6E r0 = &log_view_func1
    ldrb    r0, [r0]                        @ 0801DB72 r0 = u8 [log_view_func1]
    ldr.w   r1, =log_min_func               @ 0801DB74 r1 = &log_min_func
    strb    r0, [r1]                        @ 0801DB78 u8 [log_min_func] = r0
    ldr.w   r0, =log_view_flags1            @ 0801DB7A r0 = &log_view_flags1
    ldrb    r0, [r0]                        @ 0801DB7E r0 = u8 [log_view_flags1]
    ldr.w   r1, =log_min_flags              @ 0801DB80 r1 = &log_min_flags
    strb    r0, [r1]                        @ 0801DB84 u8 [log_min_flags] = r0
    ldr.w   r0, =log_view_value1            @ 0801DB86 r0 = &log_view_value1
    ldr     r0, [r0]                        @ 0801DB8A r0 = u32 [log_view_value1]
    ldr.w   r1, =log_min_value              @ 0801DB8C r1 = &log_min_value
    str     r0, [r1]                        @ 0801DB90 u32 [log_min_value] = r0
    ldr     r0, =log_min_time                @ production: keep the date and time of the row (log/mmtime.s)
    b       log_mm_save                     @ tail call, returns to the caller
ENDFUNC log_take_min_main
    .ltorg

@ -----------------------------------------------------------------------------
@ log_write_bytes - append r1 bytes at r0 to the log buffer and write them to the log file
@ Replaces  : 0x0801F604 FUN_0801F604 (v2.05), called by log_write_csv_token and the date and time writers
@ In        : r0 = pointer to the bytes, r1 = byte count (u16)
@ Out       : r0 = 0 written, 1 f_write failed or wrote fewer bytes
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : appends to log_buf and log_buf_len; reads/writes log_write_count, log_bytes_total, log_fresult
@ Spec      : v2.05 listing 0x0801F604..0x0801F68F
@ Note      : log_buf keeps the whole flush so that log_verify_file can compare it with the file afterwards.
@ -----------------------------------------------------------------------------
FUNC log_write_bytes
    push.w  {r4, r5, r6, r7, r8, lr}        @ 0801F604 push {r4, r5, r6, r7, r8, lr}
    movs    r4, r0                          @ 0801F608 r4 = r0
    movs    r5, r1                          @ 0801F60A r5 = r1
    movs    r7, #0                          @ 0801F60C r7 = 0
    mov     r8, r4                          @ 0801F60E r8 = r4
    movs    r0, #0                          @ 0801F610 r0 = 0
    movs    r6, r0                          @ 0801F612 r6 = r0
    @ copy the bytes into log_buf
.Llog_write_bytes_F614:                 @ v2.05 0x0801F614, reached from 0x0801F644
    movs    r0, r6                          @ 0801F614 r0 = r6
    uxtb    r0, r0                          @ 0801F616 r0 = u8(r0)
    movs    r1, r5                          @ 0801F618 r1 = r5
    uxth    r0, r0                          @ 0801F61A r0 = u16(r0)
    uxth    r1, r1                          @ 0801F61C r1 = u16(r1)
    cmp     r0, r1                          @ 0801F61E compare r0 with r1
    bhs     .Llog_write_bytes_F646          @ 0801F620 if (r0 >=u r1) goto 0x801F646
    uxtb    r6, r6                          @ 0801F622 r6 = u8(r6)
    ldrb.w  r0, [r8, r6]                    @ 0801F624 r0 = u8 [r8+r6]
    ldr.w   r1, =log_buf                    @ 0801F628 r1 = &log_buf
    ldr.w   r2, =log_buf_len                @ 0801F62C r2 = &log_buf_len
    ldrh    r2, [r2]                        @ 0801F630 r2 = u16 [log_buf_len]
    strb    r0, [r1, r2]                    @ 0801F632 u8 [log_buf+r2] = r0
    ldr.w   r0, =log_buf_len                @ 0801F634 r0 = &log_buf_len
    ldrh    r0, [r0]                        @ 0801F638 r0 = u16 [log_buf_len]
    adds    r0, r0, #1                      @ 0801F63A r0 = r0 + 1
    ldr.w   r1, =log_buf_len                @ 0801F63C r1 = &log_buf_len
    strh    r0, [r1]                        @ 0801F640 u16 [log_buf_len] = r0
    adds    r6, r6, #1                      @ 0801F642 r6 = r6 + 1
    b       .Llog_write_bytes_F614          @ 0801F644 goto 0x801F614
    @ f_write(log_fil, bytes, count, &log_write_count)
.Llog_write_bytes_F646:                 @ v2.05 0x0801F646, reached from 0x0801F620
    ldr.w   r3, =log_write_count            @ 0801F646 r3 = &log_write_count
    uxth    r5, r5                          @ 0801F64A r5 = u16(r5)
    movs    r2, r5                          @ 0801F64C r2 = r5
    mov     r1, r8                          @ 0801F64E r1 = r8
    ldr.w   r0, =log_fil                    @ 0801F650 r0 = &log_fil
    bl      fat_f_write                     @ 0801F654 call fat_f_write
    ldr.w   r1, =log_fresult                @ 0801F658 r1 = &log_fresult
    strb    r0, [r1]                        @ 0801F65C u8 [log_fresult] = r0
    ldr.w   r0, =log_fresult                @ 0801F65E r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801F662 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801F664 compare r0 with 0
    bne     .Llog_write_bytes_F674          @ 0801F666 if (r0 != 0) goto 0x801F674
    ldr.w   r0, =log_write_count            @ 0801F668 r0 = &log_write_count
    @ success only if all bytes were accepted; log_bytes_total counts them
    ldr     r0, [r0]                        @ 0801F66C r0 = u32 [log_write_count]
    uxth    r5, r5                          @ 0801F66E r5 = u16(r5)
    cmp     r0, r5                          @ 0801F670 compare r0 with r5
    beq     .Llog_write_bytes_F678          @ 0801F672 if (r0 == r5) goto 0x801F678
.Llog_write_bytes_F674:                 @ v2.05 0x0801F674, reached from 0x0801F666
    movs    r0, #1                          @ 0801F674 r0 = 1
    b       .Llog_write_bytes_F68C          @ 0801F676 goto 0x801F68C
.Llog_write_bytes_F678:                 @ v2.05 0x0801F678, reached from 0x0801F672
    ldr.w   r0, =log_bytes_total            @ 0801F678 r0 = &log_bytes_total
    ldr     r0, [r0]                        @ 0801F67C r0 = u32 [log_bytes_total]
    uxth    r5, r5                          @ 0801F67E r5 = u16(r5)
    adds    r0, r5, r0                      @ 0801F680 r0 = r5 + r0
    ldr.w   r1, =log_bytes_total            @ 0801F682 r1 = &log_bytes_total
    str     r0, [r1]                        @ 0801F686 u32 [log_bytes_total] = r0
    movs    r0, r7                          @ 0801F688 r0 = r7
    uxtb    r0, r0                          @ 0801F68A r0 = u8(r0)
.Llog_write_bytes_F68C:                 @ v2.05 0x0801F68C, reached from 0x0801F676
    pop.w   {r4, r5, r6, r7, r8, pc}        @ 0801F68C pop {r4, r5, r6, r7, r8, pc}
ENDFUNC log_write_bytes
    .ltorg

@ -----------------------------------------------------------------------------
@ log_verify_file - read the log file back and compare it with the bytes of the last flush
@ Replaces  : 0x0801F6B4 FUN_0801F6B4 (v2.05), called by log_session_once
@ In        : -
@ Out       : r0 = 0 identical, 8 open/seek/read failed or a byte differs
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads log_name_ptr, log_flush_start, log_buf_len, log_buf; uses log_verify_buf, log_read_count; writes log_fresult
@ Spec      : v2.05 listing 0x0801F6B4..0x0801F7A7
@ Note      : the file is reopened read-only (mode 1), seeked to log_flush_start and read in blocks of 0x200 bytes into
@             log_verify_buf; each block is compared with log_buf + offset.  The file is closed on every path.  This pass is the
@             protection against a silent write error of the card (the SDIO driver does not report a failed block transfer).
@ -----------------------------------------------------------------------------
FUNC log_verify_file
    push.w  {r4, r5, r6, r7, r8, lr}        @ 0801F6B4 push {r4, r5, r6, r7, r8, lr}
    @ r4 = result, preset 8
    movs    r4, #8                          @ 0801F6B8 r4 = 8
    movs.w  r8, #0                          @ 0801F6BA r8 = 0
    @ open for reading, seek to the start of this flush's data
    movs    r2, #1                          @ 0801F6BE r2 = 1
    ldr.w   r0, =log_name_ptr               @ 0801F6C0 r0 = &log_name_ptr
    ldr     r1, [r0]                        @ 0801F6C4 r1 = u32 [log_name_ptr]
    ldr.w   r0, =log_fil                    @ 0801F6C6 r0 = &log_fil
    bl      fat_f_open                      @ 0801F6CA call fat_f_open
    ldr.w   r1, =log_fresult                @ 0801F6CE r1 = &log_fresult
    strb    r0, [r1]                        @ 0801F6D2 u8 [log_fresult] = r0
    ldr.w   r0, =log_fresult                @ 0801F6D4 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801F6D8 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801F6DA compare r0 with 0
    bne     .Llog_verify_file_F798          @ 0801F6DC if (r0 != 0) goto 0x801F798
    ldr.w   r0, =log_flush_start            @ 0801F6DE r0 = &log_flush_start
    ldr     r1, [r0]                        @ 0801F6E2 r1 = u32 [log_flush_start]
    ldr.w   r0, =log_fil                    @ 0801F6E4 r0 = &log_fil
    bl      fat_f_lseek                     @ 0801F6E8 call fat_f_lseek
    ldr.w   r1, =log_fresult                @ 0801F6EC r1 = &log_fresult
    strb    r0, [r1]                        @ 0801F6F0 u8 [log_fresult] = r0
    ldr.w   r0, =log_fresult                @ 0801F6F2 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801F6F6 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801F6F8 compare r0 with 0
    bne     .Llog_verify_file_F798          @ 0801F6FA if (r0 != 0) goto 0x801F798
    @ remaining bytes = log_buf_len
    ldr.w   r0, =log_buf_len                @ 0801F6FC r0 = &log_buf_len
    ldrh    r0, [r0]                        @ 0801F700 r0 = u16 [log_buf_len]
    movs    r6, r0                          @ 0801F702 r6 = r0
    @ block of at most 0x200 bytes
.Llog_verify_file_F704:                 @ v2.05 0x0801F704, reached from 0x0801F786, 0x0801F792
    uxth    r6, r6                          @ 0801F704 r6 = u16(r6)
    cmp.w   r6, #0x200                      @ 0801F706 compare r6 with 0x200
    ble     .Llog_verify_file_F714          @ 0801F70A if (r6 <= 0x200) goto 0x801F714
    mov.w   r0, #0x200                      @ 0801F70C r0 = 0x200
    movs    r7, r0                          @ 0801F710 r7 = r0
    b       .Llog_verify_file_F716          @ 0801F712 goto 0x801F716
.Llog_verify_file_F714:                 @ v2.05 0x0801F714, reached from 0x0801F70A
    movs    r7, r6                          @ 0801F714 r7 = r6
.Llog_verify_file_F716:                 @ v2.05 0x0801F716, reached from 0x0801F712
    subs    r6, r6, r7                      @ 0801F716 r6 = r6 - r7
    ldr.w   r3, =log_read_count             @ 0801F718 r3 = &log_read_count
    uxth    r7, r7                          @ 0801F71C r7 = u16(r7)
    movs    r2, r7                          @ 0801F71E r2 = r7
    ldr.w   r1, =log_verify_buf             @ 0801F720 r1 = &log_verify_buf
    ldr.w   r0, =log_fil                    @ 0801F724 r0 = &log_fil
    @ f_read; a short read or an error is a failure
    bl      fat_f_read                      @ 0801F728 call fat_f_read
    ldr.w   r1, =log_fresult                @ 0801F72C r1 = &log_fresult
    strb    r0, [r1]                        @ 0801F730 u8 [log_fresult] = r0
    ldr.w   r0, =log_fresult                @ 0801F732 r0 = &log_fresult
    ldrb    r0, [r0]                        @ 0801F736 r0 = u8 [log_fresult]
    cmp     r0, #0                          @ 0801F738 compare r0 with 0
    bne     .Llog_verify_file_F794          @ 0801F73A if (r0 != 0) goto 0x801F794
    ldr.w   r0, =log_read_count             @ 0801F73C r0 = &log_read_count
    ldr     r0, [r0]                        @ 0801F740 r0 = u32 [log_read_count]
    uxth    r7, r7                          @ 0801F742 r7 = u16(r7)
    cmp     r0, r7                          @ 0801F744 compare r0 with r7
    bne     .Llog_verify_file_F794          @ 0801F746 if (r0 != r7) goto 0x801F794
    @ compare the block byte by byte
    movs    r0, #0                          @ 0801F748 r0 = 0
    movs    r4, r0                          @ 0801F74A r4 = r0
    movs    r0, #0                          @ 0801F74C r0 = 0
    movs    r5, r0                          @ 0801F74E r5 = r0
.Llog_verify_file_F750:                 @ v2.05 0x0801F750, reached from 0x0801F780
    movs    r0, r5                          @ 0801F750 r0 = r5
    movs    r1, r7                          @ 0801F752 r1 = r7
    uxth    r0, r0                          @ 0801F754 r0 = u16(r0)
    uxth    r1, r1                          @ 0801F756 r1 = u16(r1)
    cmp     r0, r1                          @ 0801F758 compare r0 with r1
    bhs     .Llog_verify_file_F782          @ 0801F75A if (r0 >=u r1) goto 0x801F782
    ldr.w   r0, =log_buf                    @ 0801F75C r0 = &log_buf
    uxth.w  r8, r8                          @ 0801F760 r8 = u16(r8)
    uxth    r5, r5                          @ 0801F764 r5 = u16(r5)
    adds.w  r1, r5, r8                      @ 0801F766 r1 = r5 + r8
    ldrb    r0, [r0, r1]                    @ 0801F76A r0 = u8 [log_buf+r1]
    ldr.w   r1, =log_verify_buf             @ 0801F76C r1 = &log_verify_buf
    uxth    r5, r5                          @ 0801F770 r5 = u16(r5)
    ldrb    r1, [r1, r5]                    @ 0801F772 r1 = u8 [log_verify_buf+r5]
    cmp     r0, r1                          @ 0801F774 compare r0 with r1
    beq     .Llog_verify_file_F77E          @ 0801F776 if (r0 == r1) goto 0x801F77E
    movs    r0, #8                          @ 0801F778 r0 = 8
    movs    r4, r0                          @ 0801F77A r4 = r0
    b       .Llog_verify_file_F782          @ 0801F77C goto 0x801F782
.Llog_verify_file_F77E:                 @ v2.05 0x0801F77E, reached from 0x0801F776
    adds    r5, r5, #1                      @ 0801F77E r5 = r5 + 1
    b       .Llog_verify_file_F750          @ 0801F780 goto 0x801F750
.Llog_verify_file_F782:                 @ v2.05 0x0801F782, reached from 0x0801F75A, 0x0801F77C
    uxtb    r4, r4                          @ 0801F782 r4 = u8(r4)
    cmp     r4, #0                          @ 0801F784 compare r4 with 0
    bne     .Llog_verify_file_F704          @ 0801F786 if (r4 != 0) goto 0x801F704
    @ more data: next block
    uxth    r6, r6                          @ 0801F788 r6 = u16(r6)
    cmp     r6, #0                          @ 0801F78A compare r6 with 0
    beq     .Llog_verify_file_F798          @ 0801F78C if (r6 == 0) goto 0x801F798
    adds.w  r8, r7, r8                      @ 0801F78E r8 = r7 + r8
    b       .Llog_verify_file_F704          @ 0801F792 goto 0x801F704
.Llog_verify_file_F794:                 @ v2.05 0x0801F794, reached from 0x0801F73A, 0x0801F746
    movs    r0, #8                          @ 0801F794 r0 = 8
    movs    r4, r0                          @ 0801F796 r4 = r0
    @ close the file; r0 = result
.Llog_verify_file_F798:                 @ v2.05 0x0801F798, reached from 0x0801F6DC, 0x0801F6FA, 0x0801F78C
    ldr.w   r0, =log_fil                    @ 0801F798 r0 = &log_fil
    bl      fat_f_close                     @ 0801F79C call fat_f_close
    movs    r0, r4                          @ 0801F7A0 r0 = r4
    uxtb    r0, r0                          @ 0801F7A2 r0 = u8(r0)
    pop.w   {r4, r5, r6, r7, r8, pc}        @ 0801F7A4 pop {r4, r5, r6, r7, r8, pc}
ENDFUNC log_verify_file
    .ltorg

@ -----------------------------------------------------------------------------
@ log_format_decimal - write the decimal digits of r0 backwards into a 16-byte buffer, return the start
@ Replaces  : 0x0801F7AC FUN_0801F7AC (v2.05), called by log_write_csv_token (token 0x64)
@ In        : r0 = unsigned number
@ Out       : r0 = pointer to the first digit of a NUL-terminated string at the end of log_numbuf (0x20007BF0)
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : writes the bytes below 0x20007BF0
@ Spec      : v2.05 listing 0x0801F7AC..0x0801F7D3
@ Note      : the buffer 0x20007BF0 is also the SD card CSD storage (sd_get_card_info); the digits are written below that address,
@             at most 10 digits plus the NUL.
@ -----------------------------------------------------------------------------
FUNC log_format_decimal
    movs    r1, r0                          @ 0801F7AC r1 = r0
    ldr.w   r0, =sd_csd                     @ 0801F7AE r0 = &sd_csd
    subs    r0, r0, #1                      @ 0801F7B2 r0 = r0 - 1
    movs    r2, #0                          @ 0801F7B4 r2 = 0
    strb    r2, [r0]                        @ 0801F7B6 u8 [r0] = r2
.Llog_format_decimal_F7B8:              @ v2.05 0x0801F7B8, reached from 0x0801F7D0
    subs    r0, r0, #1                      @ 0801F7B8 r0 = r0 - 1
    movs    r2, #0xa                        @ 0801F7BA r2 = 0xa
    udiv    r3, r1, r2                      @ 0801F7BC
    mls     r2, r2, r3, r1                  @ 0801F7C0
    adds    r2, #0x30                       @ 0801F7C4 r2 += 0x30
    strb    r2, [r0]                        @ 0801F7C6 u8 [r0] = r2
    movs    r2, #0xa                        @ 0801F7C8 r2 = 0xa
    udiv    r1, r1, r2                      @ 0801F7CA
    cmp     r1, #0                          @ 0801F7CE compare r1 with 0
    bne     .Llog_format_decimal_F7B8       @ 0801F7D0 if (r1 != 0) goto 0x801F7B8
    bx      lr                              @ 0801F7D2 return
ENDFUNC log_format_decimal
    .ltorg

@ -----------------------------------------------------------------------------
@ log_format_fixed - format r0 as decimal digits with a decimal point after r1 digits
@ Replaces  : 0x0801F7E0 FUN_0801F7E0 (v2.05), called by log_write_csv_token (token 0xC8)
@ In        : r0 = unsigned magnitude, r1 = number of digits after the decimal point (0 = no decimal point)
@ Out       : r0 = pointer to a NUL-terminated string of six digit characters with the point, ending at 0x20007C57
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : writes the bytes below 0x20007C57
@ Spec      : v2.05 listing 0x0801F7E0..0x0801F82F
@ Note      : exactly six digit characters are produced (the loop runs until six digits are written); the decimal point is
@             inserted after r1 digits counted from the right.  The CSV value field is therefore "0000.00" for r1 = 2.
@ -----------------------------------------------------------------------------
FUNC log_format_fixed
    push    {r4, r5, r6}                    @ 0801F7E0 push {r4, r5, r6}
    movs    r2, r0                          @ 0801F7E2 r2 = r0
    ldr.w   r0, =log_fixbuf_end             @ 0801F7E4 r0 = &log_fixbuf_end
    movs    r3, #0                          @ 0801F7E8 r3 = 0
    movs    r4, #0                          @ 0801F7EA r4 = 0
    subs    r0, r0, #1                      @ 0801F7EC r0 = r0 - 1
    movs    r5, #0                          @ 0801F7EE r5 = 0
    strb    r5, [r0]                        @ 0801F7F0 u8 [r0] = r5
.Llog_format_fixed_F7F2:                @ v2.05 0x0801F7F2, reached from 0x0801F82A
    uxtb    r1, r1                          @ 0801F7F2 r1 = u8(r1)
    cmp     r1, #0                          @ 0801F7F4 compare r1 with 0
    beq     .Llog_format_fixed_F80C         @ 0801F7F6 if (r1 == 0) goto 0x801F80C
    movs    r5, r1                          @ 0801F7F8 r5 = r1
    movs    r6, r3                          @ 0801F7FA r6 = r3
    uxtb    r5, r5                          @ 0801F7FC r5 = u8(r5)
    uxtb    r6, r6                          @ 0801F7FE r6 = u8(r6)
    cmp     r5, r6                          @ 0801F800 compare r5 with r6
    bne     .Llog_format_fixed_F80C         @ 0801F802 if (r5 != r6) goto 0x801F80C
    subs    r0, r0, #1                      @ 0801F804 r0 = r0 - 1
    movs    r5, #0x2e                       @ 0801F806 r5 = 0x2e
    strb    r5, [r0]                        @ 0801F808 u8 [r0] = r5
    b       .Llog_format_fixed_F824         @ 0801F80A goto 0x801F824
.Llog_format_fixed_F80C:                @ v2.05 0x0801F80C, reached from 0x0801F7F6, 0x0801F802
    subs    r0, r0, #1                      @ 0801F80C r0 = r0 - 1
    movs    r5, #0xa                        @ 0801F80E r5 = 0xa
    udiv    r6, r2, r5                      @ 0801F810
    mls     r5, r5, r6, r2                  @ 0801F814
    adds    r5, #0x30                       @ 0801F818 r5 += 0x30
    strb    r5, [r0]                        @ 0801F81A u8 [r0] = r5
    movs    r5, #0xa                        @ 0801F81C r5 = 0xa
    udiv    r2, r2, r5                      @ 0801F81E
    adds    r4, r4, #1                      @ 0801F822 r4 = r4 + 1
.Llog_format_fixed_F824:                @ v2.05 0x0801F824, reached from 0x0801F80A
    adds    r3, r3, #1                      @ 0801F824 r3 = r3 + 1
    uxtb    r4, r4                          @ 0801F826 r4 = u8(r4)
    cmp     r4, #6                          @ 0801F828 compare r4 with 6
    blt     .Llog_format_fixed_F7F2         @ 0801F82A if (r4 < 6) goto 0x801F7F2
    pop     {r4, r5, r6}                    @ 0801F82C pop {r4, r5, r6}
    bx      lr                              @ 0801F82E return
ENDFUNC log_format_fixed
    .ltorg

