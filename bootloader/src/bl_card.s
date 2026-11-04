@ =============================================================================
@ bl_card.s - firmware update from the SD card file EEVBlog.bin (bootloader/DESIGN.md 2 G1, G2)
@
@ As the old bootloader, the file is "EEVBlog.bin" in the card root; unlike it, nothing is erased before the whole file
@ has been read without error and checked (size 0x124..0x4C000, initial SP in the RAM, reset vector Thumb inside the
@ firmware area), the firmware mark is erased first and written last, and the programmed flash is checked against the
@ CRC-32 of the file (old bootloader: inventory section 1 items 3 and 4).  The card is read with the firmware's SD
@ driver and FatFs R0.16 (firmware/src/sd, firmware/src/ff16) on the HSE clock, as the firmware's card sessions
@ (firmware/src/ble/bft.s bft_card_begin).  Flash operations run with interrupts masked (the SD driver's handlers are
@ in flash, bl_flash.s); no card transfer is running then.
@ Display: main "douun" with the bargraph while programming, " Good" or " FAIL" at the end (old bootloader texts).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ff16x.inc"
    .include "bl.inc"

    .equ FA_READ,           0x01
    .equ CHUNK,             512

    .section .bss.bl_card, "aw", %nobits
    .balign 4
    .global ff16_fatfs
ff16_fatfs:                                 @ the drive's FATFS (also the name the firmware's SD driver refers to)
bl_fatfs:       .space FATFS_SIZE
bl_fil:         .space FIL_SIZE
bl_buf:         .space CHUNK
bl_card_size:   .space 4
bl_card_crc:    .space 4

    .section .text.bl_card, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bl_card_update - the update from the card
@ Out      : r0 = 0 programmed and checked (firmware mark written), 1 no card or no file (nothing erased), 2 the file
@            is not a firmware image or could not be read (nothing erased), 3 programming or the check failed (the
@            firmware mark stays erased: the bootloader stays in update mode)
@ Clobbers : r0-r3, r12, flags (r4-r8 saved)
@ -----------------------------------------------------------------------------
FUNC bl_card_update
    push {r4-r8, lr}
    movs r0, #5
    ldr r1, =bl_txt_down
    bl bl_lcd_text
    movs r0, #0
    bl bl_lcd_bar
    bl bl_lcd_commit
    movs r0, #1
    bl sys_clock_select                     @ HSE for the card (firmware bft_card_begin)
    movs r0, #10
    bl sd_bringup_retry
    movs r0, #0
    ldr r1, =bl_fatfs
    bl fat_f_mount
    movs r7, #1
    ldr r0, =bl_fil
    ldr r1, =bl_name
    movs r2, #FA_READ
    bl ff16_f_open
    cmp r0, #0
    bne .Lc_end
    @ pass 1: read the whole file, CRC-32, size, image check
    movs r7, #2
    ldr r0, =bl_fil
    ldr r0, [r0, #OBJ_OBJSIZE]              @ file size (FIL.obj.objsize, ff16.inc)
    ldr r1, =bl_card_size
    str r0, [r1]
    cmp r0, #0x124
    blo .Lc_close
    ldr r1, =APP_MAX
    cmp r0, r1
    bhi .Lc_close
    bl bl_card_pass                         @ r0 = 0 and the CRC in bl_card_crc, or non-zero
    cmp r0, #0
    bne .Lc_close
    ldr r0, =bl_fil                     @ back to the start: the first two words for the image check
    movs r2, #0                             @ offset 0 (FSIZE_t, 64-bit: r2:r3)
    movs r3, #0
    bl ff16_f_lseek
    cmp r0, #0
    bne .Lc_close
    ldr r0, =bl_fil
    ldr r1, =bl_buf
    movs r2, #8
    sub sp, sp, #8
    mov r3, sp
    bl ff16_f_read
    ldr r1, [sp]
    add sp, sp, #8
    cmp r0, #0
    bne .Lc_close
    cmp r1, #8
    bne .Lc_close
    ldr r3, =bl_buf
    ldr r0, [r3, #0]                        @ initial SP in the RAM
    ldr r1, =0x20000001
    cmp r0, r1
    blo .Lc_close
    ldr r1, =0x2000C000
    cmp r0, r1
    bhi .Lc_close
    ldr r0, [r3, #4]                        @ reset vector Thumb inside the firmware area
    tst r0, #1
    beq .Lc_close
    ldr r1, =APP_BASE
    cmp r0, r1
    blo .Lc_close
    ldr r1, =APP_LIMIT
    cmp r0, r1
    bhs .Lc_close
    @ erase: firmware mark first, then the pages of the image
    movs r7, #3
    cpsid i
    ldr r0, =FW_MARK
    add r1, r0, #0x100
    bl bl_erase
    cbnz r0, 1f
    ldr r1, =bl_card_size
    ldr r1, [r1]
    add r1, r1, #0xFF
    bic r1, r1, #0xFF
    ldr r0, =APP_BASE
    add r1, r1, r0
    bl bl_erase
1:  cpsie i
    cmp r0, #0
    bne .Lc_close
    @ pass 2: read again and program, 4 half-pages per chunk
    ldr r0, =bl_fil
    movs r2, #0                             @ offset 0 (FSIZE_t, 64-bit: r2:r3)
    movs r3, #0
    bl ff16_f_lseek
    cmp r0, #0
    bne .Lc_close
    ldr r4, =APP_BASE                       @ r4 = destination
    ldr r5, =bl_card_size
    ldr r5, [r5]                            @ r5 = bytes left
2:  cbz r5, 4f
    cmp r5, #CHUNK
    ite hs
    movhs r6, #CHUNK
    movlo r6, r5                            @ r6 = bytes of this chunk
    ldr r0, =bl_fil
    ldr r1, =bl_buf
    mov r2, r6
    sub sp, sp, #8
    mov r3, sp
    bl ff16_f_read
    ldr r1, [sp]
    add sp, sp, #8
    cmp r0, #0
    bne .Lc_close
    cmp r1, r6
    bne .Lc_close
    add r8, r6, #127                        @ pad the last half-page with zeros
    bic r8, r8, #127
    ldr r0, =bl_buf
    mov r1, r6
3:  cmp r1, r8
    bhs 31f
    movs r2, #0
    strb r2, [r0, r1]
    adds r1, r1, #1
    b 3b
31: cpsid i
    mov r0, r4
    ldr r1, =bl_buf
    lsr r2, r8, #7
    bl bl_write_hp
    cpsie i
    cmp r0, #0
    bne .Lc_close
    add r4, r4, r8
    subs r5, r5, r6
    ldr r0, =bl_card_size                   @ bargraph: 25 x done / size
    ldr r1, [r0]
    subs r0, r1, r5
    movs r2, #25
    muls r0, r2, r0
    udiv r0, r0, r1
    bl bl_lcd_bar
    bl bl_lcd_commit
    b 2b
4:  ldr r1, =APP_BASE                       @ the flash against the file
    ldr r2, =bl_card_size
    ldr r2, [r2]
    bl bl_crc_final
    ldr r1, =bl_card_crc
    ldr r1, [r1]
    cmp r0, r1
    bne .Lc_close
    mov r3, r0
    movs r0, #0
    ldr r1, =bl_hdr_ver
    str r0, [r1]
    ldr r0, =FW_MARK
    ldr r1, =FW_MAGIC
    ldr r2, =bl_card_size
    ldr r2, [r2]
    cpsid i
    bl bl_write_header
    cpsie i
    cmp r0, #0
    bne .Lc_close
    movs r7, #0
.Lc_close:
    ldr r0, =bl_fil
    bl ff16_f_close
.Lc_end:
    bl sd_power_off
    movs r0, #0
    bl sys_clock_select                     @ run clock again
    movs r0, #5
    cmp r7, #0
    ite eq
    ldreq r1, =bl_txt_good
    ldrne r1, =bl_txt_fail
    bl bl_lcd_text
    bl bl_lcd_commit
    mov r0, r7
    pop {r4-r8, pc}
ENDFUNC bl_card_update

@ -----------------------------------------------------------------------------
@ bl_card_pass - read the open file from its start to the end, CRC-32 into bl_card_crc
@ Out      : r0 = 0, else non-zero (read error, or the length differs from bl_card_size)
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
LFUNC bl_card_pass
    push {r4-r6, lr}
    sub sp, sp, #8
    mov r4, #0xFFFFFFFF                     @ running CRC
    movs r5, #0                             @ bytes read
1:  ldr r0, =bl_fil
    ldr r1, =bl_buf
    mov r2, #CHUNK
    mov r3, sp
    bl ff16_f_read
    cbnz r0, 9f
    ldr r6, [sp]
    cbz r6, 2f
    mov r0, r4
    ldr r1, =bl_buf
    mov r2, r6
    bl bl_crc32
    mov r4, r0
    add r5, r5, r6
    cmp r6, #CHUNK
    beq 1b
2:  mvns r4, r4
    ldr r0, =bl_card_crc
    str r4, [r0]
    ldr r0, =bl_card_size
    ldr r0, [r0]
    subs r0, r0, r5                         @ 0 when the whole file was read
9:  add sp, sp, #8
    pop {r4-r6, pc}
ENDFUNC bl_card_pass

@ -----------------------------------------------------------------------------
@ fat_f_mount - R0.08a form of f_mount (vol, fs), as the firmware's ff16_api.s: f_mount(fs, "", 0); here because the
@ firmware's SD driver (sd_probe_mount, not used by the bootloader) refers to it
@ In       : r0 = volume (0), r1 = fs    Out: r0 = FRESULT
@ -----------------------------------------------------------------------------
FUNC fat_f_mount
    cbnz r0, 1f
    mov r0, r1
    ldr r1, =bl_empty_path
    movs r2, #0
    b ff16_f_mount
1:  movs r0, #FR_INVALID_DRIVE
    bx lr
ENDFUNC fat_f_mount

    .ltorg

    .section .rodata.bl_card, "a", %progbits
bl_name:        .asciz "0:EEVBlog.bin"
bl_empty_path:  .byte 0
    .global bl_txt_down, bl_txt_good, bl_txt_fail, bl_txt_iap
bl_txt_down:    .ascii "douun"
bl_txt_good:    .ascii " Good"
bl_txt_fail:    .ascii " FAIL"
bl_txt_iap:     .ascii "-IAP-"
