@ =============================================================================
@ ff16_api.s - FatFs R0.16 (production image): the R0.08a-named entry points used by the rest of the firmware
@ (DESIGN.md 7A, IMP-29)
@
@ log, cal.bin, the Bluetooth file transfer and sd_probe_mount call fat_f_* (and the v2.05 fn_ aliases of cal.bin) with the
@ R0.08a arguments.  R0.16 keeps those arguments for every function used, except f_mount (R0.08a: f_mount(vol, fs);
@ R0.16: f_mount(fs, path, opt)) and f_tell (R0.16: a macro reading fp->fptr, which moved from FIL +8 to FIL +20).
@ (The like-v2.05 build on its branch keeps the R0.08a routines under the same names.)
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "config.inc"

    .include "ff16x.inc"

    .section .bss_port.ff16obj, "aw", %nobits
    .balign 4
@ The FatFs objects of the callers (owner LOG / CAL / BLE, one user at a time): R0.16's exFAT/LFN FIL (592 bytes), DIR
@ (80), FATFS (572) and FILINFO (288) do not fit the v2.05 areas 0x20006A60 / 0x20006C84 (548 each), 0x20007B1C (28),
@ 0x20006830 (fat_fs_obj) and 0x20007B38 (22) (IMP-29, IMP-32).
    .global ff16_fil_a, ff16_fil_b, ff16_dir_a, ff16_fatfs, ff16_finfo
ff16_fatfs:     .space FATFS_SIZE           @ fat_fs_obj, CALBIN_FS, bft_fatfs
ff16_fil_a:     .space FIL_SIZE             @ log_fil, CALBIN_FIL, bft_fil_a
ff16_fil_b:     .space FIL_SIZE             @ log_fil_new, bft_fil_b
ff16_dir_a:     .space DIR_SIZE             @ log_dir
ff16_finfo:     .space FILINFO_SIZE         @ log_finfo

    .section .rodata.ff16.api, "a", %progbits
ff16_empty_path: .byte 0

    .section .text.ff16.api, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fat_f_mount - register (or unregister) the work area of drive 0, R0.08a form
@ In       : r0 = volume (only 0 exists), r1 = fs (0: unregister)
@ Out      : r0 = FRESULT
@ Note     : f_mount(fs, "", 0): registration only, the volume is mounted on the first access, as R0.08a did.  A volume
@            number other than 0 is passed as "n:" would be in R0.16: FR_INVALID_DRIVE.
@ -----------------------------------------------------------------------------
FUNC fat_f_mount
    cbnz r0, 1f
    mov r0, r1
    ldr r1, =ff16_empty_path
    movs r2, #0
    b ff16_f_mount
1:  movs r0, #FR_INVALID_DRIVE
    bx lr
    .ltorg
ENDFUNC fat_f_mount

@ -----------------------------------------------------------------------------
@ fat_f_tell - file pointer (R0.16 f_tell(fp) = fp->fptr)
@ In       : r0 = fp
@ Out      : r0 = fp->fptr
@ -----------------------------------------------------------------------------
FUNC fat_f_tell
    ldr r0, [r0, #FIL_FPTR]
    bx lr
ENDFUNC fat_f_tell

@ the other entry points take the same arguments in both versions: direct branches
FUNC fat_f_open
    b ff16_f_open
ENDFUNC fat_f_open
FUNC fat_f_read
    b ff16_f_read
ENDFUNC fat_f_read
FUNC fat_f_write
    b ff16_f_write
ENDFUNC fat_f_write
FUNC fat_f_sync
    b ff16_f_sync
ENDFUNC fat_f_sync
FUNC fat_f_close
    b ff16_f_close
ENDFUNC fat_f_close
@ fat_f_lseek - R0.08a form f_lseek(fp, DWORD ofs): r1 = offset; R0.16 with exFAT takes FSIZE_t = QWORD in r2:r3
FUNC fat_f_lseek
    mov r2, r1                              @ offset, low word
    movs r3, #0                             @ high word (the callers' offsets are below 4 GiB)
    b ff16_f_lseek
ENDFUNC fat_f_lseek
FUNC fat_f_opendir
    b ff16_f_opendir
ENDFUNC fat_f_opendir
FUNC fat_f_readdir
    b ff16_f_readdir
ENDFUNC fat_f_readdir
FUNC fat_f_stat
    b ff16_f_stat
ENDFUNC fat_f_stat
FUNC fat_f_utime
    b ff16_f_utime
ENDFUNC fat_f_utime
@ new in the production image: not in R0.08a's configuration of v2.05
FUNC fat_f_unlink
    b ff16_f_unlink
ENDFUNC fat_f_unlink
FUNC fat_f_rename
    b ff16_f_rename
ENDFUNC fat_f_rename
FUNC fat_f_getfree
    b ff16_f_getfree
ENDFUNC fat_f_getfree
FUNC fat_f_mkfs
    b ff16_f_mkfs
ENDFUNC fat_f_mkfs

@ v2.05 addresses used as names by cal.bin (cal/calbin.s) and the log (as in src/sd/fat_file.s)
    .global fn_0801E010, fn_08021B80, fn_08021BCC, fn_08021D72, fn_08021F60, fn_0802224C, fn_08022268
    .global fn_0802242C, fn_080224B6, fn_08022526, fn_0802256E
    .thumb_set fn_0801E010, fat_f_tell
    .thumb_set fn_08021B80, fat_f_mount
    .thumb_set fn_08021BCC, fat_f_open
    .thumb_set fn_08021D72, fat_f_read
    .thumb_set fn_08021F60, fat_f_write
    .thumb_set fn_0802224C, fat_f_close
    .thumb_set fn_08022268, fat_f_lseek
    .thumb_set fn_0802242C, fat_f_opendir
    .thumb_set fn_080224B6, fat_f_readdir
    .thumb_set fn_08022526, fat_f_stat
    .thumb_set fn_0802256E, fat_f_utime

