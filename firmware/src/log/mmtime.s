@ =============================================================================
@ mmtime.s - LOG: date and time of the MAX and MIN rows that close the log file (production image only, FEATURES.md 2.6,
@ DESIGN.md 10 IMP-21)
@
@ v2.05 closes the file with "MAX,row,func,value,unit," and "MIN,row,func,value,unit," (log_write_minmax_rows) and keeps
@ only the row number of each extreme.  This file keeps the date and time of the row that set the extreme (log_take_max_main
@ and log_take_min_main call log_mm_save while log_view_year..second still hold that row, loaded by log_write_row) and
@ log_write_minmax_rows appends them before the CRLF of each closing row:
@     MAX,row,func,value,unit,YYYY/MM/DD,hh:mm:ss,
@ The first five columns keep the v2.05 text, so a reader of v2.05 files still finds them in place.
@
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ log_view_year,       v_20008007    @ date and time of the loaded record, six bytes year (since 2000), month, day,
                                            @ hour, minute, second at 0x20008007..0x2000800C (log_slot_load)

    .section .bss_port.log, "aw", %nobits
    .global log_max_time, log_min_time
log_max_time:   .space 6                    @ year, month, day, hour, minute, second of the maximum row
log_min_time:   .space 6                    @ the same for the minimum row

    .section .text.log.mmtime, "ax", %progbits

@ -----------------------------------------------------------------------------
@ log_mm_save - copy the date and time of the loaded record to an extreme
@ In       : r0 = log_max_time or log_min_time
@ Out      : -
@ Clobbers : r0, r1, flags (the registers v2.05 log_take_max_main / log_take_min_main clobber; it is their tail call)
@ Context  : main only
@ -----------------------------------------------------------------------------
FUNC log_mm_save
    push {r2, r3}
    ldr r1, =log_view_year
    movs r2, #6
1:  ldrb r3, [r1], #1
    strb r3, [r0], #1
    subs r2, r2, #1
    bne 1b
    pop {r2, r3}
    bx lr
ENDFUNC log_mm_save

@ -----------------------------------------------------------------------------
@ log_mm_write - write "YYYY/MM/DD," and "hh:mm:ss," of an extreme to the log file
@ In       : r0 = log_max_time or log_min_time
@ Out      : r0 = 0 ok, 1 a write failed
@ Clobbers : r0-r3, flags (as log_write_csv_token)
@ Context  : main only (log_write_minmax_rows)
@ -----------------------------------------------------------------------------
FUNC log_mm_write
    push {r4, lr}
    mov r4, r0
    ldrb r2, [r4, #2]                       @ day
    ldrb r1, [r4, #1]                       @ month
    ldrb r0, [r4, #0]                       @ year
    bl log_write_date
    cbnz r0, 1f
    ldrb r2, [r4, #5]                       @ second
    ldrb r1, [r4, #4]                       @ minute
    ldrb r0, [r4, #3]                       @ hour
    bl log_write_time
    cbz r0, 2f
1:  movs r0, #1
2:  pop {r4, pc}
ENDFUNC log_mm_write

    .ltorg

