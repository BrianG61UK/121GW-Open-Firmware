@ =============================================================================
@ fmt.s - SET: SETUP page For, format the SD card as exFAT (production image only, DESIGN.md 10 IMP-32)
@
@ SET module.  A setup page in the style of the page dSP (dsp.s), item 40, between the pages Ld and rEL, shown only
@ while the two-part bootloader is installed (its mark is valid, ble/blcmd.s): EEVblog's bootloader cannot read an
@ exFAT card, so on a meter with it the card update would stop working (owner decision 2026-11-04,
@ bootloader/DESIGN.md 5 item 7).  Long SETUP starts the edit ("Fr no" blinks), REL or PEAK switches between no and
@ yes, long SETUP again confirms: with yes the card is formatted (FatFs f_mkfs, FM_EXFAT, default cluster size) and
@ everything on it is gone.  Refused while logging runs or in calibration mode (the card belongs to them then).
@
@ Page texts (sub display): "Fr no", "Fr yE" (choice), "Fr --" (formatting), "Fr oK" (done), "FrE n" (failed: n = the
@ FatFs result of f_mkfs, 1..9, or 9 for a result above 9; or "FrE L" refused: logging or calibration mode).
@
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "ff16x.inc"

    .equ set_fmt_redraw,      v_20008062    @ sub display redraw request
    .equ set_fmt_commit_req,  v_2000805B    @ LCD commit request
    .equ fmt_logging,         v_20007FE1    @ logging active (as ble/bft.s)
    .equ fmt_cal_mode,        v_2000808A    @ calibration mode (as ble/bft.s)
    .equ fmt_work,            v_20001240    @ log_buf (log/files.s): f_mkfs working buffer while logging is off
    .equ FMT_WORK_LEN,        8192          @ of its 10000 bytes
    .equ ST_CHOICE,           0
    .equ ST_BUSY,             1
    .equ ST_DONE,             2
    .equ ST_FAIL,             3
    .equ ST_REFUSED,          4

    .section .bss_port.set, "aw", %nobits
fmt_yes:        .space 1                    @ choice: 0 no, 1 yes
fmt_state:      .space 1                    @ ST_*
fmt_result:     .space 1                    @ FatFs result of a failed f_mkfs
    .balign 4
fmt_parm:       .space 16                   @ MKFS_PARM {fmt u8, n_fat u8, align u32 at +4, n_root u32 at +8, au_size u32 at +12}

    .section .rodata.set.fmt, "a", %progbits
fmt_texts:
    .ascii "Fr no"
    .ascii "Fr yE"
    .ascii "Fr --"
    .ascii "Fr oK"
fmt_path:
    .asciz "0:"

    .section .text.set.fmt, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_fmt_available - is the page shown? (the two-part bootloader is installed)
@ Out      : r0 = 1 yes, 0 no
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC set_fmt_available
    push {r4, lr}
    bl blcmd_mark_version                   @ -1 when no valid bootloader mark
    adds r0, r0, #1
    it ne
    movne r0, #1
    pop {r4, pc}
ENDFUNC set_fmt_available

@ -----------------------------------------------------------------------------
@ set_fmt_enter - the page is entered: choice no, nothing done yet
@ Clobbers : r0, r1
@ -----------------------------------------------------------------------------
FUNC set_fmt_enter
    movs r0, #0
    ldr r1, =fmt_yes
    strb r0, [r1]
    ldr r1, =fmt_state
    strb r0, [r1]
    bx lr
ENDFUNC set_fmt_enter

@ -----------------------------------------------------------------------------
@ set_fmt_edit - edit action of the page For (setup item 40)
@ In       : r0 = action: 1 up, 2 down, 100 save (= confirm)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Note     : with "yes" confirmed, the format runs here (a few seconds: the main loop waits, as the Bluetooth file
@            transfer's card work does)
@ -----------------------------------------------------------------------------
FUNC set_fmt_edit
    push {r4, lr}
    uxtb r4, r0
    cmp r4, #100
    beq 2f
    ldr r1, =fmt_yes                        @ up or down: the other choice
    ldrb r0, [r1]
    eor r0, r0, #1
    strb r0, [r1]
    movs r0, #ST_CHOICE
    ldr r1, =fmt_state
    strb r0, [r1]
    b 9f
2:  ldr r0, =fmt_yes
    ldrb r0, [r0]
    cbz r0, 9f                              @ "no" confirmed: nothing
    movs r0, #0
    ldr r1, =fmt_yes
    strb r0, [r1]                           @ the next confirmation needs a new "yes"
    ldr r0, =fmt_logging
    ldrb r0, [r0]
    ldr r1, =fmt_cal_mode
    ldrb r1, [r1]
    orrs r0, r0, r1
    beq 3f
    movs r0, #ST_REFUSED
    ldr r1, =fmt_state
    strb r0, [r1]
    b 9f
3:  movs r0, #ST_BUSY                       @ "Fr --" now, before the card work
    ldr r1, =fmt_state
    strb r0, [r1]
    bl set_fmt_draw
    bl lcd_commit_shadow
    bl fmt_run                              @ r0 = FatFs result
    cbz r0, 4f
    ldr r1, =fmt_result
    strb r0, [r1]
    movs r0, #ST_FAIL
    b 5f
4:  movs r0, #ST_DONE
5:  ldr r1, =fmt_state
    strb r0, [r1]
9:  movs r0, #1
    ldr r1, =set_fmt_redraw
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_fmt_edit

@ -----------------------------------------------------------------------------
@ fmt_run - one card session: HSE clock, card bring-up, fmt_mkfs, card off, run clock
@ Out      : r0 = FatFs result
@ Clobbers : r1-r3, r12, flags (r4 saved)
@ -----------------------------------------------------------------------------
LFUNC fmt_run
    push {r4, lr}
    movs r0, #1
    bl sys_clock_select                     @ the card-session clock, PLL 32 MHz (as bft_card_begin)
    movs r0, #10
    bl sd_bringup_retry
    bl fmt_mkfs
    mov r4, r0
    bl sd_power_off
    movs r0, #0
    bl sys_clock_select                     @ run clock again
    mov r0, r4
    pop {r4, pc}
ENDFUNC fmt_run

@ -----------------------------------------------------------------------------
@ fmt_mkfs - format the card as exFAT: f_mkfs("0:", {FM_EXFAT, defaults}, log_buf, 8192); the card session is the
@            caller's (fmt_run here, bft_card_begin / end for the Bluetooth request 0x15 of ble/bftsd.s)
@ Out      : r0 = FatFs result
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Note     : the working buffer is log_buf (logging is off whenever this runs: the page refuses, the Bluetooth gate
@            requires it); f_mkfs invalidates a mounted volume of the drive itself (ffx/ffx_mkfs.s)
@ -----------------------------------------------------------------------------
FUNC fmt_mkfs
    push {r4, lr}
    ldr r3, =fmt_parm
    movs r0, #FM_EXFAT
    strb r0, [r3, #0]                       @ fmt
    movs r0, #0
    strb r0, [r3, #1]                       @ n_fat: default
    str r0, [r3, #4]                        @ align: default (the card's erase block, disk_ioctl)
    str r0, [r3, #8]                        @ n_root: default
    str r0, [r3, #12]                       @ au_size: default for the volume size
    ldr r0, =fmt_path
    mov r1, r3
    ldr r2, =fmt_work
    mov r3, #FMT_WORK_LEN
    bl fat_f_mkfs
    pop {r4, pc}
ENDFUNC fmt_mkfs

@ -----------------------------------------------------------------------------
@ set_fmt_draw - draw the page For
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ -----------------------------------------------------------------------------
FUNC set_fmt_draw
    push {r4, lr}
    sub sp, sp, #8
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus sign off
    str r1, [r0, #0x10]
    movs r0, #0
    bl fn_08017FB4                          @ sub display decimal points off
    ldr r0, =fmt_state
    ldrb r0, [r0]
    cmp r0, #ST_CHOICE
    bne 1f
    ldr r0, =fmt_yes
    ldrb r0, [r0]                           @ text 0 "Fr no" or 1 "Fr yE"
    b 3f
1:  cmp r0, #ST_BUSY
    bne 2f
    movs r0, #2                             @ "Fr --"
    b 3f
2:  cmp r0, #ST_DONE
    bne 4f
    movs r0, #3                             @ "Fr oK"
3:  add r0, r0, r0, lsl #2
    ldr r1, =fmt_texts
    add r1, r1, r0
    b 8f
4:  movs r1, #'F'                           @ "FrE n" / "FrE L"
    strb r1, [sp, #0]
    movs r1, #'r'
    strb r1, [sp, #1]
    movs r1, #'E'
    strb r1, [sp, #2]
    movs r1, #' '
    strb r1, [sp, #3]
    cmp r0, #ST_REFUSED
    ite eq
    moveq r1, #'L'
    movne r1, #0
    bne 5f
    strb r1, [sp, #4]
    b 6f
5:  ldr r1, =fmt_result
    ldrb r1, [r1]
    cmp r1, #9
    it hi
    movhi r1, #9
    adds r1, r1, #'0'
    strb r1, [sp, #4]
6:  mov r1, sp
8:  movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_fmt_commit_req
    strb r0, [r1]
    add sp, sp, #8
    pop {r4, pc}
ENDFUNC set_fmt_draw

    .ltorg
