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
@
@ Steps of bl_card_update, in order (r7 holds the result code throughout, see its Out list):
@   1. text "douun", clock to HSE, card bring-up (10 tries), mount, open "0:EEVBlog.bin" (read only);
@   2. pass 1 (bl_card_pass): read the whole file once for the CRC-32; refuse a size outside 0x124..APP_MAX;
@   3. read the first 8 bytes again and check the initial SP and the reset vector; every refusal up to here leaves the
@      flash untouched (result 2);
@   4. erase the firmware mark page, then the pages the image needs (interrupts masked);
@   5. pass 2: read the file in 512-byte chunks and program each as 4 half-pages (zero padded at the end), with the
@      bargraph advancing;
@   6. CRC-32 over the programmed flash against the pass 1 value, then write the firmware mark (length, CRC-32) last.
@ Because the mark is erased in step 4 and written in step 6 only, a power cut or error in between leaves no valid mark
@ and the bootloader stays in update mode (DESIGN.md G2).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ff16x.inc"
    .include "bl.inc"

    .equ FA_READ,           0x01            @ FatFs mode flag: open for reading only (the bootloader never writes the card)
    .equ CHUNK,             512             @ bytes per f_read: 4 half-pages of 128 bytes

@ RAM of this file: the FatFs volume, the open file, one chunk buffer and the two results of pass 1.
    .section .bss.bl_card, "aw", %nobits
    .balign 4
    .global ff16_fatfs
ff16_fatfs:                                 @ the drive's FATFS (also the name the firmware's SD driver refers to)
bl_fatfs:       .space FATFS_SIZE           @ FATFS work area of drive 0 (size from ff16x.inc)
bl_fil:         .space FIL_SIZE             @ FIL object of the open update file (size from ff16x.inc)
bl_buf:         .space CHUNK                @ one chunk of the file; also holds the 8 header bytes read for the image check
bl_card_size:   .space 4                    @ file size in bytes, taken from FIL.obj.objsize
bl_card_crc:    .space 4                    @ CRC-32 of the whole file, final value (pass 1)

    .section .text.bl_card, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bl_card_update - the update from the card
@ In       : -
@ Out      : r0 = 0 programmed and checked (firmware mark written), 1 no card or no file (nothing erased), 2 the file
@            is not a firmware image or could not be read (nothing erased), 3 programming or the check failed (the
@            firmware mark stays erased: the bootloader stays in update mode)
@ Clobbers : r0-r3, r12, flags (r4-r8 saved)
@ Context  : main, from the update mode (bl_main.s) after SETUP was pressed, with the BLE link already off
@ Note     : r7 = result code, kept in r7 across the calls and set ahead of each stage (1 start, 2 file open, 3 erase,
@            0 only when the mark is written).  r4 = flash destination, r5 = bytes left, r6 = bytes of this chunk, r8 =
@            chunk length rounded up to a half-page.  Every failure after the open branches to .Lc_close with r7 as it
@            stands.
@ -----------------------------------------------------------------------------
FUNC bl_card_update
    push {r4-r8, lr}
    movs r0, #5                             @ r0 = 5: first position of the main display
    ldr r1, =bl_txt_down                    @ text "douun" (old bootloader text for the update running)
    bl bl_lcd_text
    movs r0, #0                             @ bargraph empty
    bl bl_lcd_bar
    bl bl_lcd_commit                        @ shadow to the display
    movs r0, #1
    bl sys_clock_select                     @ the card-session clock, PLL 32 MHz (firmware IMP-41, bft_card_begin)
    @ card start: up to 10 tries; its result is not used here, a missing card shows as the f_open failure below
    movs r0, #10
    bl sd_bringup_retry
    movs r0, #0                             @ volume 0
    ldr r1, =bl_fatfs
    bl fat_f_mount
    movs r7, #1                             @ result 1 until the file is open: no card or no file
    ldr r0, =bl_fil
    ldr r1, =bl_name                        @ "0:EEVBlog.bin": drive 0, file in the root (old bootloader name)
    movs r2, #FA_READ
    bl ff16_f_open
    cmp r0, #0
    bne .Lc_end                             @ any FRESULT but OK: result 1, nothing was erased, no f_close needed
    @ pass 1: read the whole file, CRC-32, size, image check
    movs r7, #2
    ldr r0, =bl_fil
    ldr r0, [r0, #OBJ_OBJSIZE]              @ file size (FIL.obj.objsize, ff16.inc)
    ldr r1, =bl_card_size
    str r0, [r1]
    @ size window: below 0x124 bytes (73 vector words, the length of a vector table) or above APP_MAX (0x4C000) is refused
    cmp r0, #0x124
    blo .Lc_close                           @ too small: result 2
    ldr r1, =APP_MAX
    cmp r0, r1
    bhi .Lc_close                           @ too large: result 2
    bl bl_card_pass                         @ r0 = 0 and the CRC in bl_card_crc, or non-zero
    cmp r0, #0
    bne .Lc_close
    ldr r0, =bl_fil                         @ back to the start: the first two words for the image check
    movs r2, #0                             @ offset 0 (FSIZE_t, 64-bit: r2:r3)
    movs r3, #0
    bl ff16_f_lseek
    cmp r0, #0
    bne .Lc_close
    @ read the first 8 bytes of the file into bl_buf: the initial stack pointer and the reset vector
    ldr r0, =bl_fil
    ldr r1, =bl_buf
    movs r2, #8                             @ r2 = 8 bytes to read
    sub sp, sp, #8                          @ 8 bytes on the stack for the count read (SP stays doubleword aligned)
    mov r3, sp                              @ r3 = pointer to the count (UINT *br)
    bl ff16_f_read
    ldr r1, [sp]                            @ r1 = bytes actually read
    add sp, sp, #8
    cmp r0, #0
    bne .Lc_close
    cmp r1, #8                              @ fewer than 8 bytes read: not an image
    bne .Lc_close
    ldr r3, =bl_buf
    ldr r0, [r3, #0]                        @ initial SP in the RAM
    ldr r1, =0x20000001                     @ initial SP must lie in RAM: 0x20000001..0x2000C000 (BL_STACK_TOP)
    cmp r0, r1
    blo .Lc_close
    ldr r1, =0x2000C000
    cmp r0, r1
    bhi .Lc_close
    ldr r0, [r3, #4]                        @ reset vector Thumb inside the firmware area
    tst r0, #1                              @ bit 0 set: Thumb state, required of a Cortex-M reset vector
    beq .Lc_close
    ldr r1, =APP_BASE
    cmp r0, r1
    blo .Lc_close
    ldr r1, =APP_LIMIT
    cmp r0, r1
    bhs .Lc_close
    @ erase: firmware mark first, then the pages of the image
    movs r7, #3
    @ interrupts are masked around every flash operation because the SD driver's handlers are in flash
    cpsid i
    ldr r0, =FW_MARK
    add r1, r0, #0x100                      @ r1 = end of the mark page (one 256-byte page)
    bl bl_erase
    cbnz r0, 1f                             @ mark erase failed: skip the image erase, result 3 below
    ldr r1, =bl_card_size
    ldr r1, [r1]
    add r1, r1, #0xFF                       @ file size rounded up to whole 256-byte pages (the erase unit)
    bic r1, r1, #0xFF
    ldr r0, =APP_BASE
    add r1, r1, r0                          @ r1 = end address of the area to erase
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
2:  cbz r5, 4f                              @ no bytes left: all programmed
    cmp r5, #CHUNK
    ite hs
    movhs r6, #CHUNK
    movlo r6, r5                            @ r6 = bytes of this chunk
    ldr r0, =bl_fil
    ldr r1, =bl_buf
    mov r2, r6
    sub sp, sp, #8                          @ UINT for the count read, on the stack
    mov r3, sp
    bl ff16_f_read
    ldr r1, [sp]
    add sp, sp, #8
    cmp r0, #0
    bne .Lc_close
    cmp r1, r6                              @ a short read before the end of the size recorded in pass 1: result 3
    bne .Lc_close
    add r8, r6, #127                        @ pad the last half-page with zeros
    bic r8, r8, #127
    ldr r0, =bl_buf
    mov r1, r6
3:  cmp r1, r8
    bhs 31f
    movs r2, #0
    strb r2, [r0, r1]                       @ pad byte 0 (erased flash reads 0)
    adds r1, r1, #1
    b 3b
31: cpsid i
    mov r0, r4
    ldr r1, =bl_buf
    lsr r2, r8, #7                          @ r2 = number of half-pages (bytes / 128)
    bl bl_write_hp                          @ program and read back (bl_flash.s); r0 = 0 ok
    cpsie i
    cmp r0, #0
    bne .Lc_close
    add r4, r4, r8                          @ advance by whole half-pages; only the last chunk can be short
    subs r5, r5, r6                         @ bytes left (real bytes, without the pad)
    ldr r0, =bl_card_size                   @ bargraph: 25 x done / size
    ldr r1, [r0]
    subs r0, r1, r5
    movs r2, #25
    muls r0, r2, r0
    udiv r0, r0, r1
    bl bl_lcd_bar
    bl bl_lcd_commit
    b 2b
    @ all bytes written: the flash is checked against the file once more, over the file size only (the pad is not in the CRC)
4:  ldr r1, =APP_BASE                       @ the flash against the file
    ldr r2, =bl_card_size
    ldr r2, [r2]
    bl bl_crc_final                         @ r0 = CRC-32 of the programmed flash
    ldr r1, =bl_card_crc
    ldr r1, [r1]
    cmp r0, r1
    bne .Lc_close                           @ CRC of the flash differs from the CRC of the file: result 3, mark stays erased
    @ last step: the firmware mark (magic, length, CRC-32, version, header CRC) is written, version word 0 for a card update
    mov r3, r0                              @ r3 = CRC-32 of the image, for bl_write_header
    movs r0, #0
    ldr r1, =bl_hdr_ver
    str r0, [r1]
    ldr r0, =FW_MARK
    ldr r1, =FW_MAGIC
    ldr r2, =bl_card_size
    ldr r2, [r2]
    cpsid i
    bl bl_write_header                      @ interrupts masked while the word writes run
    cpsie i
    cmp r0, #0
    bne .Lc_close
    movs r7, #0                             @ result 0: the image is complete and marked valid
@ common exit of the open file: close, then the shared end (power the card off, restore the clock, show the result)
.Lc_close:
    ldr r0, =bl_fil
    bl ff16_f_close
@ r7 still holds the stage the failure happened in (1 when f_open failed, 0 on success)
.Lc_end:
    bl sd_power_off                         @ card power off
    movs r0, #0
    bl sys_clock_select                     @ run clock again
    movs r0, #5
    cmp r7, #0
    ite eq
    ldreq r1, =bl_txt_good                  @ result 0: " Good"
    ldrne r1, =bl_txt_fail                  @ else " FAIL"
    bl bl_lcd_text
    bl bl_lcd_commit
    mov r0, r7                              @ return the result code
    pop {r4-r8, pc}
ENDFUNC bl_card_update

@ -----------------------------------------------------------------------------
@ bl_card_pass - read the open file from its start to the end, CRC-32 into bl_card_crc
@ In       : the file open at offset 0, bl_card_size = its size
@ Out      : r0 = 0, else non-zero (read error, or the length differs from bl_card_size)
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ Context  : main, called once by bl_card_update (pass 1)
@ Note     : the CRC is the zlib CRC-32: bl_crc32 keeps the running value, the start value 0xFFFFFFFF is set here and the
@            final inversion done by mvns.  A read shorter than 512 bytes ends the loop (end of file).
@ -----------------------------------------------------------------------------
LFUNC bl_card_pass
    push {r4-r6, lr}
    sub sp, sp, #8                          @ 8 bytes on the stack for the count read by f_read
    mov r4, #0xFFFFFFFF                     @ running CRC
    movs r5, #0                             @ bytes read
1:  ldr r0, =bl_fil
    ldr r1, =bl_buf
    mov r2, #CHUNK
    mov r3, sp
    bl ff16_f_read
    cbnz r0, 9f                             @ read error: r0 is the non-zero FRESULT
    ldr r6, [sp]                            @ r6 = bytes read in this call
    cbz r6, 2f                              @ 0 bytes: end of file
    mov r0, r4
    ldr r1, =bl_buf
    mov r2, r6
    bl bl_crc32                             @ update the running CRC with the r6 bytes just read
    mov r4, r0
    add r5, r5, r6
    cmp r6, #CHUNK                          @ a full chunk: more may follow
    beq 1b
2:  mvns r4, r4
    ldr r0, =bl_card_crc
    str r4, [r0]
    ldr r0, =bl_card_size
    ldr r0, [r0]
    subs r0, r0, r5                         @ 0 when the whole file was read
@ r0 here is 0 only if exactly bl_card_size bytes were read; also the error exit with the FRESULT in r0
9:  add sp, sp, #8
    pop {r4-r6, pc}
ENDFUNC bl_card_pass

@ -----------------------------------------------------------------------------
@ fat_f_mount - R0.08a form of f_mount (vol, fs), as the firmware's ff16_api.s: f_mount(fs, "", 0); here because the
@ firmware's SD driver (sd_probe_mount, not used by the bootloader) refers to it
@ In       : r0 = volume (0), r1 = fs
@ Out      : r0 = FRESULT
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ Note     : the bootloader calls it with volume 0 and bl_fatfs.  The R0.16 f_mount takes (fs, path, opt); opt 0 is "do
@            not mount now", so the volume is mounted by the first access (f_open).  Any volume other than 0 is refused
@            with FR_INVALID_DRIVE.
@ -----------------------------------------------------------------------------
FUNC fat_f_mount
    cbnz r0, 1f
    mov r0, r1
    ldr r1, =bl_empty_path                  @ path "" (drive 0)
    movs r2, #0                             @ opt = 0
    b ff16_f_mount                          @ tail call to the R0.16 f_mount
1:  movs r0, #FR_INVALID_DRIVE
    bx lr
ENDFUNC fat_f_mount

    .ltorg

@ constants: the update file name, an empty path, and the display texts (5 characters each, old bootloader texts)
    .section .rodata.bl_card, "a", %progbits
bl_name:        .asciz "0:EEVBlog.bin"
bl_empty_path:  .byte 0
    .global bl_txt_down, bl_txt_good, bl_txt_fail, bl_txt_iap
bl_txt_down:    .ascii "douun"              @ update running (main display)
bl_txt_good:    .ascii " Good"              @ success
bl_txt_fail:    .ascii " FAIL"              @ failure
bl_txt_iap:     .ascii "-IAP-"              @ update mode, shown by bl_main.s
