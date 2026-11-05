@ =============================================================================
@ ffx_file.s - FatFs R0.16 w/patch 2, exFAT configuration (group D): drive number, boot sector check, volume search,
@ mount, object validation, f_mount, f_open, f_read, f_write, f_sync, f_close, f_lseek
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c) as preprocessed for the exFAT configuration
@ (fatfs16/exfat/ff_x.c, application: read/write; fatfs16/exfat/ff_xro.c, bootloader: FF_FS_READONLY 1).  Each routine
@ names the C function it translates; the code follows the C statements in order and the comments quote them.  Calling
@ convention AAPCS (r0-r3, r12 scratch, r4-r11 preserved, stack 8-byte aligned at calls), as the C functions.
@ Parts that exist only with FF_FS_READONLY 0 are inside `.if FF_FS_READONLY == 0` (ff_xro.c differs from ff_x.c there);
@ f_write and f_sync do not exist at all with FF_FS_READONLY 1.
@
@ FatFs license (ChaN): "FatFs module is an open source software. Redistribution and use of FatFs in source and binary forms,
@ with or without modification, are permitted provided that the following condition is met: 1. Redistributions of source
@ code must retain the above copyright notice, this condition and the following disclaimer.  This software is provided by
@ the copyright holder and contributors "AS IS" and any warranties related to this software are DISCLAIMED.  The copyright
@ owner or contributors be NOT LIABLE for any damages caused by use of this software."  Copyright (C) 2025, ChaN, all right
@ reserved.
@
@ Structure offsets and constants: ff16x.inc (FATFS, FFOBJID, FIL, DIR).  FSIZE_t (objsize, fptr, fsize, ofs) is 64 bit,
@ LBA_t and cluster numbers are 32 bit (FF_LBA64 0).  The sector size is the constant 512 (FF_MIN_SS = FF_MAX_SS).
@ Byte-order helpers (ff.c ld_16 ld_32 ld_64 st_16 st_32 st_64) are called as routines ff16_ld_16 etc. (they read and
@ write at any alignment, byte by byte); no unaligned halfword/word access is used here.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ff16x.inc"

@ ld_16 / ld_32 / ld_64 of the bytes at (base + off): r0 = result (ld_64: r0:r1).  Clobbers r0-r3, r12.
    .macro FFD_LD16 base, off
    add r0, \base, #(\off)
    bl ff16_ld_16
    .endm
    .macro FFD_LD32 base, off
    add r0, \base, #(\off)
    bl ff16_ld_32
    .endm
    .macro FFD_LD64 base, off
    add r0, \base, #(\off)
    bl ff16_ld_64
    .endm

    .section .rodata.ff16x.file, "a", %progbits
@ "\xEB\x76\x90" "EXFAT   " (check_fs, 11 bytes): jump boot code and OEM name of an exFAT boot sector
ffd_str_exfat:  .byte 0xEB, 0x76, 0x90
                .ascii "EXFAT   "
@ "FAT32   " (check_fs, 8 bytes): file system type string of a FAT32 boot sector at offset 82
ffd_str_fat32:  .ascii "FAT32   "

    .section .text.ff16x.file, "ax", %progbits

@ -----------------------------------------------------------------------------
@ get_ldnumber - logical drive number from the head of a path (ff.c get_ldnumber, FF_STR_VOLUME_ID 0, FF_VOLUMES 1,
@ FF_USE_LFN 1: a path ends at a character below ' ')
@ In       : r0 = pointer to the path pointer
@ Out      : r0 = 0 drive 0, -1 invalid drive; the path pointer advanced past "n:" when a drive prefix is present
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_get_ldnumber
    ldr r1, [r0]                            @ tt = tp = *path;   (r1 = tp, r2 = tt)
    cbz r1, .Lgl_inval                      @ if (!tp) return -1;
    mov r2, r1
.Lgl_scan:
    ldrb r3, [r2], #1                       @ do { chr = *tt++; }
    cmp r3, #' '                            @ while (!((UINT)chr < ' ') && chr != ':');
    blo .Lgl_none                           @   chr < ' ': end of path, chr != ':'  -> return 0
    cmp r3, #':'
    bne .Lgl_scan
    @ chr == ':'
    movs r3, #1                             @ i = 1;
    ldrb r12, [r1]                          @ if (IsDigit(*tp) && tp + 2 == tt) i = (int)*tp - '0';
    sub r12, r12, #'0'                      @   IsDigit: (*tp >= '0' && *tp <= '9') as an unsigned range test
    cmp r12, #9
    bhi .Lgl_i
    adds r1, r1, #2                         @   tp + 2
    cmp r1, r2                              @   == tt ?
    it eq
    moveq r3, r12                           @   i = *tp - '0'
.Lgl_i:
    cmp r3, #1                              @ if (i >= FF_VOLUMES) return -1;   (FF_VOLUMES 1; i is signed)
    bge .Lgl_inval
    str r2, [r0]                            @ *path = tt;
    mov r0, r3                              @ return i;
    bx lr
.Lgl_none:
    movs r0, #0                             @ return 0;   (no drive prefix: drive 0)
    bx lr
.Lgl_inval:
    mvn r0, #0                              @ return -1;
    bx lr
ENDFUNC ff16_get_ldnumber

@ -----------------------------------------------------------------------------
@ check_fs - boot sector type of a sector (ff.c check_fs, exFAT, FF_MAX_SS = 512)
@ In       : r0 = fs, r1 = sector (LBA_t)
@ Out      : r0 = 0 FAT boot sector, 1 exFAT boot sector, 2 valid boot signature but not FAT/exFAT, 3 not a boot sector,
@            4 disk error
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_check_fs
    push {r4, r5, r6, lr}
    mov r4, r0                              @ r4 = fs
    movs r2, #0
    strb r2, [r4, #FS_WFLAG]                @ fs->wflag = 0;
    mvn r2, #0
    str r2, [r4, #FS_WINSECT]               @ fs->winsect = (LBA_t)0 - 1;   (invalidate the window)
    mov r0, r4                              @ if (move_window(fs, sect) != FR_OK) return 4;   (r1 = sect)
    bl ff16_move_window
    cbz r0, .Lcf_win
    movs r0, #4
    pop {r4, r5, r6, pc}
.Lcf_win:
    add r4, r4, #FS_WIN                     @ r4 = fs->win
    ldr r6, =0xAA55                         @ r6 = 0xAA55
    ldrb r5, [r4, #(BS_55AA + 1)]           @ sign = ld_16(fs->win + 510);   (r5)
    ldrb r0, [r4, #BS_55AA]
    orr r5, r0, r5, lsl #8
    cmp r5, r6                              @ if (sign == 0xAA55 && !memcmp(fs->win + 0, "\xEB\x76\x90" "EXFAT   ", 11))
    bne .Lcf_b
    mov r0, r4
    ldr r1, =ffd_str_exfat
    movs r2, #11
    bl ff16_mem_cmp
    cbnz r0, .Lcf_b
    movs r0, #1                             @   return 1;
    pop {r4, r5, r6, pc}
.Lcf_b:
    ldrb r0, [r4]                           @ b = fs->win[0];
    cmp r0, #0xEB                           @ if (b == 0xEB || b == 0xE9 || b == 0xE8) {
    beq .Lcf_jmp
    cmp r0, #0xE9
    beq .Lcf_jmp
    cmp r0, #0xE8
    bne .Lcf_ret
.Lcf_jmp:
    cmp r5, r6                              @   if (sign == 0xAA55 && !memcmp(fs->win + 82, "FAT32   ", 8)) {
    bne .Lcf_bpb
    add r0, r4, #BS_FilSysType32
    ldr r1, =ffd_str_fat32
    movs r2, #8
    bl ff16_mem_cmp
    cbnz r0, .Lcf_bpb
    movs r0, #0                             @     return 0;   (FAT32)
    pop {r4, r5, r6, pc}
.Lcf_bpb:
    FFD_LD16 r4, BPB_BytsPerSec             @   w = ld_16(fs->win + 11);
    subs r1, r0, #1                         @   if ((w & (w - 1)) == 0 && w >= 512 && w <= 512 ...
    tst r0, r1                              @     (w & (w - 1)) == 0
    bne .Lcf_ret
    cmp r0, #512                            @     w >= 512 && w <= 512  (i.e. w == 512)
    bne .Lcf_ret
    ldrb r0, [r4, #BPB_SecPerClus]          @   b = fs->win[13];  ... && b != 0 && (b & (b - 1)) == 0
    cbz r0, .Lcf_ret
    subs r1, r0, #1
    tst r0, r1
    bne .Lcf_ret
    FFD_LD16 r4, BPB_RsvdSecCnt             @   && ld_16(fs->win + 14) != 0
    cbz r0, .Lcf_ret
    ldrb r0, [r4, #BPB_NumFATs]             @   && (UINT)fs->win[16] - 1 <= 1
    subs r0, r0, #1
    cmp r0, #1
    bhi .Lcf_ret
    FFD_LD16 r4, BPB_RootEntCnt             @   && ld_16(fs->win + 17) != 0
    cbz r0, .Lcf_ret
    FFD_LD16 r4, BPB_TotSec16               @   && (ld_16(fs->win + 19) >= 128
    cmp r0, #128
    bhs .Lcf_fatsz
    FFD_LD32 r4, BPB_TotSec32               @       || ld_32(fs->win + 32) >= 0x10000)
    cmp r0, #0x10000
    blo .Lcf_ret
.Lcf_fatsz:
    FFD_LD16 r4, BPB_FATSz16                @   && ld_16(fs->win + 22) != 0) {
    cbz r0, .Lcf_ret
    movs r0, #0                             @     return 0;   (FAT12/16 boot sector)
    pop {r4, r5, r6, pc}
.Lcf_ret:
    cmp r5, r6                              @ return sign == 0xAA55 ? 2 : 3;
    ite eq
    moveq r0, #2
    movne r0, #3
    pop {r4, r5, r6, pc}
    .ltorg
ENDFUNC ff16_check_fs

@ -----------------------------------------------------------------------------
@ find_volume - find the FAT/exFAT volume: boot sector of the drive or of the first partition (ff.c find_volume,
@ FF_MULTI_PARTITION 0 so part is 0, FF_LBA64 0 so no GPT)
@ In       : r0 = fs, r1 = part (0: auto detect)
@ Out      : r0 = check_fs result of the volume boot sector (0 FAT, 1 exFAT, 2.. no file system, 4 disk error)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_find_volume
    push {r4, r5, r6, lr}
    sub sp, sp, #16                         @ DWORD mbr_pt[4];   at [sp]
    mov r4, r0                              @ r4 = fs
    mov r5, r1                              @ r5 = part
    movs r1, #0
    bl ff16_check_fs                        @ fmt = check_fs(fs, 0);
    cmp r0, #2                              @ if (fmt != 2 && (fmt >= 3 || part == 0)) return fmt;
    beq .Lfv_mbr
    cmp r0, #3
    bhs .Lfv_ret
    cbz r5, .Lfv_ret
.Lfv_mbr:
                                            @ if (0 && part > 4) return 3;   (FF_MULTI_PARTITION 0: compiled out)
    movs r6, #0                             @ for (i = 0; i < 4; i++)
.Lfv_ptl:
    add r0, r4, r6, lsl #4                  @   mbr_pt[i] = ld_32(fs->win + 446 + i * 16 + 8);
    add r0, r0, #(FS_WIN + MBR_Table + PTE_StLba)
    bl ff16_ld_32
    str r0, [sp, r6, lsl #2]
    adds r6, r6, #1
    cmp r6, #4
    blo .Lfv_ptl
    movs r6, #0                             @ i = part ? part - 1 : 0;
    cbz r5, .Lfv_try
    subs r6, r5, #1
.Lfv_try:
    ldr r1, [sp, r6, lsl #2]                @ do { fmt = mbr_pt[i] ? check_fs(fs, mbr_pt[i]) : 3;
    cbz r1, .Lfv_nopt
    mov r0, r4
    bl ff16_check_fs
    b .Lfv_test
.Lfv_nopt:
    movs r0, #3
.Lfv_test:
    cbnz r5, .Lfv_ret                       @ } while (part == 0 && fmt >= 2 && ++i < 4);
    cmp r0, #2
    blo .Lfv_ret
    adds r6, r6, #1
    cmp r6, #4
    blo .Lfv_try
.Lfv_ret:
    add sp, sp, #16                         @ return fmt;
    pop {r4, r5, r6, pc}
ENDFUNC ff16_find_volume

@ -----------------------------------------------------------------------------
@ mount_volume - mount (or confirm) the volume of a path (ff.c mount_volume, exFAT, FF_VOLUMES 1, FF_MAX_SS = 512,
@ FF_LBA64 0).  With FF_FS_READONLY 1 the write protect test and the FSINFO / free cluster initialisation are absent.
@ In       : r0 = pointer to the path pointer, r1 = pointer to the FATFS pointer to set, r2 = mode (BYTE)
@ Out      : r0 = FRESULT; *rfs = work area (0 when the drive number is invalid)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 = fs, r5 = bsect, r6 = fmt, r7 = fs->win; exFAT: r8:r9 maxlba, r10 ncl then so, r11 i, r8 bcl then;
@            FAT: r8 fasize, r9 tsect / nclst / szbfat, r10 nrsv, r11 sysect
@ -----------------------------------------------------------------------------
FUNC ff16_mount_volume
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #4                          @ keep the stack 8-byte aligned
    mov r5, r1                              @ r5 = rfs (until bsect is known)
    and r6, r2, #0xFE                       @ r6 = mode & (BYTE)~0x01   (mode &= (BYTE)~FA_READ;)
    movs r1, #0
    str r1, [r5]                            @ *rfs = 0;
    bl ff16_get_ldnumber                    @ vol = get_ldnumber(path);   (r0 = path)
    cmp r0, #0
    bge .Lmv_vol
    movs r0, #FR_INVALID_DRIVE              @ if (vol < 0) return FR_INVALID_DRIVE;
    b .Lmv_ret
.Lmv_vol:
    ldr r1, =ff16_FatFs                     @ fs = FatFs[vol];
    ldr r4, [r1, r0, lsl #2]
    cbnz r4, .Lmv_fs
    movs r0, #FR_NOT_ENABLED                @ if (!fs) return FR_NOT_ENABLED;
    b .Lmv_ret
.Lmv_fs:
    str r4, [r5]                            @ *rfs = fs;
    ldrb r1, [r4, #FS_FS_TYPE]              @ if (fs->fs_type != 0) {
    cbz r1, .Lmv_init
    ldrb r0, [r4, #FS_PDRV]                 @   stat = disk_status(fs->pdrv);
    bl disk_status
    tst r0, #1                              @   if (!(stat & STA_NOINIT)) {
    bne .Lmv_init
    .if FF_FS_READONLY == 0
    cbz r6, .Lmv_ok                         @     if (!FF_FS_READONLY && mode && (stat & STA_PROTECT))
    tst r0, #4
    beq .Lmv_ok
    movs r0, #FR_WRITE_PROTECTED            @       return FR_WRITE_PROTECTED;
    b .Lmv_ret
    .endif
.Lmv_ok:
    movs r0, #FR_OK                         @     return FR_OK;   (already mounted)
    b .Lmv_ret
.Lmv_init:
    movs r1, #0
    strb r1, [r4, #FS_FS_TYPE]              @ fs->fs_type = 0;
    ldrb r0, [r4, #FS_PDRV]                 @ stat = disk_initialize(fs->pdrv);
    bl disk_initialize
    tst r0, #1                              @ if (stat & STA_NOINIT) return FR_NOT_READY;
    beq .Lmv_inited
    movs r0, #FR_NOT_READY
    b .Lmv_ret
.Lmv_inited:
    .if FF_FS_READONLY == 0
    cbz r6, .Lmv_wp                         @ if (!FF_FS_READONLY && mode && (stat & STA_PROTECT))
    tst r0, #4
    beq .Lmv_wp
    movs r0, #FR_WRITE_PROTECTED            @   return FR_WRITE_PROTECTED;
    b .Lmv_ret
    .endif
.Lmv_wp:
    mov r0, r4                              @ fmt = find_volume(fs, 0);
    movs r1, #0
    bl ff16_find_volume
    cmp r0, #4                              @ if (fmt == 4) return FR_DISK_ERR;
    bne .Lmv_f4
    movs r0, #FR_DISK_ERR
    b .Lmv_ret
.Lmv_f4:
    cmp r0, #2                              @ if (fmt >= 2) return FR_NO_FILESYSTEM;
    bhs .Lmv_nofs
    mov r6, r0                              @ r6 = fmt   (mode is not needed any more)
    ldr r5, [r4, #FS_WINSECT]               @ bsect = fs->winsect;
    add r7, r4, #FS_WIN                     @ r7 = fs->win
    cmp r6, #1                              @ if (fmt == 1) {   exFAT
    bne .Lmv_fat

    @ ---- exFAT: QWORD maxlba; DWORD so, cv, bcl, ncl, i;
    movs r0, #11                            @ for (i = 11; i < 11 + 53 && fs->win[i] == 0; i++) ;
.Lmv_mbz:
    ldrb r1, [r7, r0]
    cmp r1, #0
    bne .Lmv_nofs                       @ if (i < 11 + 53) return FR_NO_FILESYSTEM;   (non-zero byte in MustBeZero)
    adds r0, r0, #1
    cmp r0, #(11 + 53)
    blo .Lmv_mbz
    FFD_LD16 r7, BPB_FSVerEx                @ if (ld_16(fs->win + 104) != 0x100) return FR_NO_FILESYSTEM;
    cmp r0, #0x100
    bne .Lmv_nofs
    ldrb r1, [r7, #BPB_BytsPerSecEx]        @ if (1 << fs->win[108] != 512) return FR_NO_FILESYSTEM;
    movs r0, #1
    lsl r0, r0, r1                          @   (register shift: amounts of 32 and more give 0, never 512)
    cmp r0, #512
    bne .Lmv_nofs
    FFD_LD64 r7, BPB_TotSecEx               @ maxlba = ld_64(fs->win + 72) + bsect;   (r8:r9)
    adds r8, r0, r5
    adc r9, r1, #0
    cmp r9, #0
    bne .Lmv_nofs                       @ if (!FF_LBA64 && maxlba >= 0x100000000) return FR_NO_FILESYSTEM;
    FFD_LD32 r7, BPB_FatSzEx                @ fs->fsize = ld_32(fs->win + 84);
    str r0, [r4, #FS_FSIZE]
    ldrb r0, [r7, #BPB_NumFATsEx]           @ fs->n_fats = fs->win[110];
    strb r0, [r4, #FS_N_FATS]
    cmp r0, #1                              @ if (fs->n_fats != 1) return FR_NO_FILESYSTEM;
    bne .Lmv_nofs
    ldrb r1, [r7, #BPB_SecPerClusEx]        @ fs->csize = 1 << fs->win[109];   (csize is a WORD: stored truncated)
    movs r0, #1
    lsl r0, r0, r1
    uxth r0, r0
    strh r0, [r4, #FS_CSIZE]
    cmp r0, #0
    beq .Lmv_nofs                       @ if (fs->csize == 0) return FR_NO_FILESYSTEM;
    FFD_LD32 r7, BPB_NumClusEx              @ ncl = ld_32(fs->win + 92);   (r10)
    mov r10, r0
    ldr r1, =0x7FFFFFFD                     @ if (ncl > MAX_EXFAT) return FR_NO_FILESYSTEM;
    cmp r0, r1
    bhi .Lmv_nofs
    adds r0, r0, #2                         @ fs->n_fatent = ncl + 2;
    str r0, [r4, #FS_N_FATENT]
    str r5, [r4, #FS_VOLBASE]               @ fs->volbase = bsect;
    FFD_LD32 r7, BPB_DataOfsEx              @ fs->database = bsect + ld_32(fs->win + 88);
    add r0, r0, r5
    str r0, [r4, #FS_DATABASE]
    FFD_LD32 r7, BPB_FatOfsEx               @ fs->fatbase = bsect + ld_32(fs->win + 80);
    add r0, r0, r5
    str r0, [r4, #FS_FATBASE]
    @ if (maxlba < (QWORD)fs->database + ncl * fs->csize) return FR_NO_FILESYSTEM;
    @   ncl * fs->csize is a 32-bit unsigned product (DWORD * WORD) added to the 64-bit database
    ldrh r1, [r4, #FS_CSIZE]
    mul r1, r10, r1
    ldr r2, [r4, #FS_DATABASE]
    movs r3, #0
    adds r2, r2, r1
    adc r3, r3, #0                          @ r3:r2 = (QWORD)database + ncl * csize
    cmp r8, r2                              @ maxlba (r9:r8) < r3:r2 ?  (unsigned 64 bit compare)
    sbcs r12, r9, r3
    blo .Lmv_nofs
    FFD_LD32 r7, BPB_RootClusEx             @ fs->dirbase = ld_32(fs->win + 96);
    str r0, [r4, #FS_DIRBASE]
    movs r10, #0                            @ so = i = 0;   (r10 = so, r11 = i)
    movs r11, #0
.Lmv_bmloop:                                @ for (;;) {
    cmp r11, #0
    bne .Lmv_bmtest                       @   if (i == 0) {
    ldrh r1, [r4, #FS_CSIZE]                @     if (so >= fs->csize) return FR_NO_FILESYSTEM;
    cmp r10, r1
    bhs .Lmv_nofs
    mov r0, r4                              @     if (move_window(fs, clst2sect(fs, (DWORD)fs->dirbase) + so) != FR_OK)
    ldr r1, [r4, #FS_DIRBASE]
    bl ff16_clst2sect
    add r1, r0, r10
    mov r0, r4
    bl ff16_move_window
    cmp r0, #FR_OK
    bne .Lmv_diskerr                        @       return FR_DISK_ERR;
    adds r10, r10, #1                       @     so++;
.Lmv_bmtest:                                @   }
    ldrb r0, [r7, r11]                      @   if (fs->win[i] == ET_BITMAP) break;
    cmp r0, #ET_BITMAP
    beq .Lmv_bmfound
    add r11, r11, #32                       @   i = (i + 32) % 512;
    ubfx r11, r11, #0, #9
    b .Lmv_bmloop                           @ }
.Lmv_bmfound:
    add r0, r7, r11                         @ bcl = ld_32(fs->win + i + 20);   (r8)
    adds r0, r0, #20
    bl ff16_ld_32
    mov r8, r0
    cmp r8, #2                              @ if (bcl < 2 || bcl >= fs->n_fatent) return FR_NO_FILESYSTEM;
    blo .Lmv_nofs
    ldr r1, [r4, #FS_N_FATENT]
    cmp r8, r1
    bhs .Lmv_nofs
    ldr r0, [r4, #FS_DATABASE]              @ fs->bitbase = fs->database + fs->csize * (bcl - 2);
    ldrh r1, [r4, #FS_CSIZE]
    sub r2, r8, #2
    mla r0, r1, r2, r0
    str r0, [r4, #FS_BITBASE]
.Lmv_fatloop:                               @ for (;;) {   follow the bitmap cluster chain in the FAT
    ldr r0, [r4, #FS_FATBASE]               @   if (move_window(fs, fs->fatbase + bcl / (512 / 4)) != FR_OK)
    add r1, r0, r8, lsr #7
    mov r0, r4
    bl ff16_move_window
    cmp r0, #FR_OK
    bne .Lmv_diskerr                        @     return FR_DISK_ERR;
    and r1, r8, #127                        @   cv = ld_32(fs->win + bcl % (512 / 4) * 4);
    add r0, r7, r1, lsl #2
    bl ff16_ld_32
    cmn r0, #1                              @   if (cv == 0xFFFFFFFF) break;
    beq .Lmv_chainok
    adds r8, r8, #1                         @   if (cv != ++bcl) return FR_NO_FILESYSTEM;
    cmp r0, r8
    bne .Lmv_nofs
    b .Lmv_fatloop                          @ }
.Lmv_chainok:
    .if FF_FS_READONLY == 0
    mvn r0, #0                              @ fs->last_clst = fs->free_clst = 0xFFFFFFFF;
    str r0, [r4, #FS_LAST_CLST]
    str r0, [r4, #FS_FREE_CLST]
    movs r0, #0                             @ fs->fsi_flag = 0;
    strb r0, [r4, #FS_FSI_FLAG]
    .endif
    movs r6, #4                             @ fmt = FS_EXFAT;
    b .Lmv_fin                              @ }

    @ ---- FAT12/16/32: DWORD tsect, sysect, fasize, nclst, szbfat; WORD nrsv;
.Lmv_fat:
    FFD_LD16 r7, BPB_BytsPerSec             @ if (ld_16(fs->win + 11) != 512) return FR_NO_FILESYSTEM;
    cmp r0, #512
    bne .Lmv_nofs
    FFD_LD16 r7, BPB_FATSz16                @ fasize = ld_16(fs->win + 22);   (r8)
    mov r8, r0
    cmp r8, #0
    bne .Lmv_fasz
    FFD_LD32 r7, BPB_FATSz32                @ if (fasize == 0) fasize = ld_32(fs->win + 36);
    mov r8, r0
.Lmv_fasz:
    str r8, [r4, #FS_FSIZE]                 @ fs->fsize = fasize;
    ldrb r0, [r7, #BPB_NumFATs]             @ fs->n_fats = fs->win[16];
    strb r0, [r4, #FS_N_FATS]
    cmp r0, #1                              @ if (fs->n_fats != 1 && fs->n_fats != 2) return FR_NO_FILESYSTEM;
    beq .Lmv_nfats
    cmp r0, #2
    bne .Lmv_nofs
.Lmv_nfats:
    mul r8, r8, r0                          @ fasize *= fs->n_fats;
    ldrb r0, [r7, #BPB_SecPerClus]          @ fs->csize = fs->win[13];
    strh r0, [r4, #FS_CSIZE]
    cmp r0, #0
    beq .Lmv_nofs                       @ if (fs->csize == 0 || (fs->csize & (fs->csize - 1))) return FR_NO_FILESYSTEM;
    subs r1, r0, #1
    tst r0, r1
    bne .Lmv_nofs
    FFD_LD16 r7, BPB_RootEntCnt             @ fs->n_rootdir = ld_16(fs->win + 17);
    strh r0, [r4, #FS_N_ROOTDIR]
    tst r0, #((512 / 32) - 1)               @ if (fs->n_rootdir % (512 / 32)) return FR_NO_FILESYSTEM;
    bne .Lmv_nofs
    FFD_LD16 r7, BPB_TotSec16               @ tsect = ld_16(fs->win + 19);   (r9)
    mov r9, r0
    cmp r9, #0
    bne .Lmv_tsect
    FFD_LD32 r7, BPB_TotSec32               @ if (tsect == 0) tsect = ld_32(fs->win + 32);
    mov r9, r0
.Lmv_tsect:
    FFD_LD16 r7, BPB_RsvdSecCnt             @ nrsv = ld_16(fs->win + 14);   (r10)
    mov r10, r0
    cmp r10, #0
    beq .Lmv_nofs                       @ if (nrsv == 0) return FR_NO_FILESYSTEM;
    ldrh r1, [r4, #FS_N_ROOTDIR]            @ sysect = nrsv + fasize + fs->n_rootdir / (512 / 32);   (r11)
    lsrs r1, r1, #4
    add r11, r10, r8
    add r11, r11, r1
    cmp r9, r11                             @ if (tsect < sysect) return FR_NO_FILESYSTEM;
    blo .Lmv_nofs
    sub r9, r9, r11                         @ nclst = (tsect - sysect) / fs->csize;   (r9; csize is not 0)
    ldrh r1, [r4, #FS_CSIZE]
    udiv r9, r9, r1
    cmp r9, #0
    beq .Lmv_nofs                       @ if (nclst == 0) return FR_NO_FILESYSTEM;
    movs r6, #0                             @ fmt = 0;
    ldr r1, =MAX_FAT32                      @ if (nclst <= MAX_FAT32) fmt = FS_FAT32;
    cmp r9, r1
    it ls
    movls r6, #FS_FAT32
    movw r1, #MAX_FAT16                     @ if (nclst <= MAX_FAT16) fmt = FS_FAT16;
    cmp r9, r1
    it ls
    movls r6, #FS_FAT16
    movw r1, #MAX_FAT12                     @ if (nclst <= MAX_FAT12) fmt = FS_FAT12;
    cmp r9, r1
    it ls
    movls r6, #FS_FAT12
    cmp r6, #0
    beq .Lmv_nofs                       @ if (fmt == 0) return FR_NO_FILESYSTEM;
    adds r0, r9, #2                         @ fs->n_fatent = nclst + 2;
    str r0, [r4, #FS_N_FATENT]
    str r5, [r4, #FS_VOLBASE]               @ fs->volbase = bsect;
    add r0, r5, r10                         @ fs->fatbase = bsect + nrsv;
    str r0, [r4, #FS_FATBASE]
    add r0, r5, r11                         @ fs->database = bsect + sysect;
    str r0, [r4, #FS_DATABASE]
    cmp r6, #FS_FAT32                       @ if (fmt == FS_FAT32) {
    bne .Lmv_f16
    FFD_LD16 r7, BPB_FSVer32                @   if (ld_16(fs->win + 42) != 0) return FR_NO_FILESYSTEM;
    cmp r0, #0
    bne .Lmv_nofs
    ldrh r0, [r4, #FS_N_ROOTDIR]            @   if (fs->n_rootdir != 0) return FR_NO_FILESYSTEM;
    cmp r0, #0
    bne .Lmv_nofs
    FFD_LD32 r7, BPB_RootClus32             @   fs->dirbase = ld_32(fs->win + 44);
    str r0, [r4, #FS_DIRBASE]
    ldr r1, [r4, #FS_N_FATENT]              @   szbfat = fs->n_fatent * 4;   (r9)
    lsl r9, r1, #2
    b .Lmv_szchk                            @ } else {
.Lmv_f16:
    ldrh r0, [r4, #FS_N_ROOTDIR]            @   if (fs->n_rootdir == 0) return FR_NO_FILESYSTEM;
    cmp r0, #0
    beq .Lmv_nofs
    ldr r0, [r4, #FS_FATBASE]               @   fs->dirbase = fs->fatbase + fasize;
    add r0, r0, r8
    str r0, [r4, #FS_DIRBASE]
    ldr r1, [r4, #FS_N_FATENT]              @   szbfat = (fmt == FS_FAT16) ?
    cmp r6, #FS_FAT16
    bne .Lmv_f12
    lsl r9, r1, #1                          @     fs->n_fatent * 2 :
    b .Lmv_szchk
.Lmv_f12:
    add r2, r1, r1, lsl #1                  @     fs->n_fatent * 3 / 2 + (fs->n_fatent & 1);
    lsrs r2, r2, #1
    and r3, r1, #1
    add r9, r2, r3
.Lmv_szchk:                                 @ }
    add r0, r9, #(512 - 1)                  @ if (fs->fsize < (szbfat + (512 - 1)) / 512) return FR_NO_FILESYSTEM;
    lsrs r0, r0, #9
    ldr r1, [r4, #FS_FSIZE]
    cmp r1, r0
    blo .Lmv_nofs
    .if FF_FS_READONLY == 0
    mvn r0, #0                              @ fs->last_clst = fs->free_clst = 0xFFFFFFFF;
    str r0, [r4, #FS_LAST_CLST]
    str r0, [r4, #FS_FREE_CLST]
    movs r0, #0x80                          @ fs->fsi_flag = 0x80;   (FSINFO not loaded yet)
    strb r0, [r4, #FS_FSI_FLAG]
    cmp r6, #FS_FAT32                       @ if (fmt == FS_FAT32
    bne .Lmv_fin
    FFD_LD16 r7, BPB_FSInfo32               @   && ld_16(fs->win + 48) == 1
    cmp r0, #1
    bne .Lmv_fin
    adds r1, r5, #1                         @   && move_window(fs, bsect + 1) == FR_OK)
    mov r0, r4
    bl ff16_move_window
    cmp r0, #FR_OK
    bne .Lmv_fin
    movs r0, #0                             @ { fs->fsi_flag = 0;
    strb r0, [r4, #FS_FSI_FLAG]
    FFD_LD32 r7, FSI_LeadSig                @   if (ld_32(fs->win + 0) == 0x41615252
    ldr r1, =0x41615252
    cmp r0, r1
    bne .Lmv_fin
    FFD_LD32 r7, FSI_StrucSig               @    && ld_32(fs->win + 484) == 0x61417272
    ldr r1, =0x61417272
    cmp r0, r1
    bne .Lmv_fin
    FFD_LD32 r7, FSI_TrailSig               @    && ld_32(fs->win + 508) == 0xAA550000)
    ldr r1, =0xAA550000
    cmp r0, r1
    bne .Lmv_fin
    FFD_LD32 r7, FSI_Free_Count             @   { fs->free_clst = ld_32(fs->win + 488);
    str r0, [r4, #FS_FREE_CLST]
    FFD_LD32 r7, FSI_Nxt_Free               @     fs->last_clst = ld_32(fs->win + 492); } }
    str r0, [r4, #FS_LAST_CLST]
    .endif
.Lmv_fin:
    strb r6, [r4, #FS_FS_TYPE]              @ fs->fs_type = (BYTE)fmt;
    ldr r1, =ff16_Fsid                      @ fs->id = ++Fsid;   (Fsid and fs->id are WORDs)
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]
    strh r0, [r4, #FS_ID]
    ldr r1, =ff16_LfnBuf                    @ fs->lfnbuf = LfnBuf;
    str r1, [r4, #FS_LFNBUF]
    ldr r1, =ff16_DirBuf                    @ fs->dirbuf = DirBuf;
    str r1, [r4, #FS_DIRBUF]
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lmv_ret
.Lmv_diskerr:
    movs r0, #FR_DISK_ERR                   @ return FR_DISK_ERR;
    b .Lmv_ret
.Lmv_nofs:
    movs r0, #FR_NO_FILESYSTEM              @ return FR_NO_FILESYSTEM;
.Lmv_ret:
    add sp, sp, #4
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .ltorg
ENDFUNC ff16_mount_volume

@ -----------------------------------------------------------------------------
@ validate - check a file / directory object (ff.c validate)
@ In       : r0 = object (FFOBJID*, may be 0), r1 = pointer to the FATFS pointer to set
@ Out      : r0 = FR_OK or FR_INVALID_OBJECT; *rfs = obj->fs on FR_OK, otherwise 0
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_validate
    push {r4, r5, r6, lr}
    mov r4, r0                              @ r4 = obj
    mov r5, r1                              @ r5 = rfs
    movs r6, #FR_INVALID_OBJECT             @ FRESULT res = FR_INVALID_OBJECT;
    cbz r4, .Lva_out                        @ if (obj && obj->fs && obj->fs->fs_type && obj->id == obj->fs->id) {
    ldr r0, [r4, #OBJ_FS]
    cbz r0, .Lva_out
    ldrb r1, [r0, #FS_FS_TYPE]
    cbz r1, .Lva_out
    ldrh r1, [r4, #OBJ_ID]
    ldrh r2, [r0, #FS_ID]
    cmp r1, r2
    bne .Lva_out
    ldrb r0, [r0, #FS_PDRV]                 @   if (!(disk_status(obj->fs->pdrv) & STA_NOINIT)) {
    bl disk_status
    tst r0, #1
    bne .Lva_out
    movs r6, #FR_OK                         @     res = FR_OK;
.Lva_out:
    cbnz r6, .Lva_null                      @ *rfs = (res == FR_OK) ? obj->fs : 0;
    ldr r1, [r4, #OBJ_FS]
    b .Lva_set
.Lva_null:
    movs r1, #0
.Lva_set:
    str r1, [r5]
    mov r0, r6                              @ return res;
    pop {r4, r5, r6, pc}
ENDFUNC ff16_validate

@ -----------------------------------------------------------------------------
@ f_mount - register (or unregister) a work area and optionally mount it (ff.c f_mount, FF_VOLUMES 1)
@ In       : r0 = fs (0: unregister the drive), r1 = path ("" or "n:"), r2 = opt (0: lazy mount, 1: mount now)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Locals   : [sp+0] rp (path pointer for get_ldnumber), [sp+4] path (for mount_volume), [sp+8] fs (for mount_volume)
@ -----------------------------------------------------------------------------
FUNC ff16_f_mount
    push {r4, r5, r6, r7, lr}
    sub sp, sp, #12
    mov r4, r0                              @ r4 = fs
    uxtb r6, r2                             @ r6 = opt (BYTE)
    str r1, [sp, #4]                        @ path (parameter, passed to mount_volume below)
    str r1, [sp, #0]                        @ const TCHAR *rp = path;
    mov r0, sp                              @ vol = get_ldnumber(&rp);
    bl ff16_get_ldnumber
    cmp r0, #0
    bge .Lfm_vol
    movs r0, #FR_INVALID_DRIVE              @ if (vol < 0) return FR_INVALID_DRIVE;
    b .Lfm_ret
.Lfm_vol:
    mov r7, r0                              @ r7 = vol
    ldr r1, =ff16_FatFs
    ldr r2, [r1, r7, lsl #2]                @ cfs = FatFs[vol];
    cbz r2, .Lfm_nocfs                      @ if (cfs) {
    movs r3, #0
    str r3, [r1, r7, lsl #2]                @   FatFs[vol] = 0;
    strb r3, [r2, #FS_FS_TYPE]              @   cfs->fs_type = 0;   (clear the old work area)
.Lfm_nocfs:                                 @ }
    cbz r4, .Lfm_reg                        @ if (fs) {
    strb r7, [r4, #FS_PDRV]                 @   fs->pdrv = (BYTE)vol;
    movs r3, #0
    strb r3, [r4, #FS_FS_TYPE]              @   fs->fs_type = 0;   (not mounted yet)
    str r4, [r1, r7, lsl #2]                @   FatFs[vol] = fs;
.Lfm_reg:                                   @ }
    movs r0, #FR_OK
    cbz r6, .Lfm_ret                        @ if (opt == 0) return FR_OK;
    str r4, [sp, #8]                        @ fs (parameter variable, written by mount_volume)
    add r0, sp, #4                          @ res = mount_volume(&path, &fs, 0);
    add r1, sp, #8
    movs r2, #0
    bl ff16_mount_volume
.Lfm_ret:
    add sp, sp, #12                         @ return res;
    pop {r4, r5, r6, r7, pc}
    .ltorg
ENDFUNC ff16_f_mount

@ -----------------------------------------------------------------------------
@ f_open - open or create a file (ff.c f_open, FF_FS_LOCK 0, FF_FS_RPATH 0, FF_FS_TINY 0, FF_MAX_SS = 512).
@ With FF_FS_READONLY 1 only FA_READ is kept in the mode and no create / truncate / append code exists.
@ In       : r0 = fp, r1 = path, r2 = mode (FA_*)
@ Out      : r0 = FRESULT; fp->obj.fs = 0 on any error after fp is known to be valid
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 = fp, r5 = fs, r6 = res, r7 = mode, r8 = tm (DWORD tm / ofs low), r9 = cl (DWORD cl) / ofs high,
@            r10 = sc (LBA_t sc) / bcs, r11 = clst
@ Locals   : [sp+0] DIR dj (80 bytes), [sp+80] path (for mount_volume), [sp+84] fs (for mount_volume)
@ -----------------------------------------------------------------------------
FUNC ff16_f_open
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #92                         @ DIR dj (80) + path (4) + fs (4) + 4 for the alignment
    mov r4, r0                              @ r4 = fp
    cbnz r4, .Lfo_fp                        @ if (!fp) return FR_INVALID_OBJECT;
    movs r0, #FR_INVALID_OBJECT
    b .Lfo_ret
.Lfo_fp:
    str r1, [sp, #80]                       @ path
    .if FF_FS_READONLY == 0
    and r7, r2, #(FA_READ | FA_WRITE | FA_CREATE_ALWAYS | FA_CREATE_NEW | FA_OPEN_ALWAYS | FA_OPEN_APPEND)
    .else
    and r7, r2, #FA_READ                    @ mode &= FF_FS_READONLY ? FA_READ : FA_READ | FA_WRITE | FA_CREATE_ALWAYS | ...;
    .endif
    add r0, sp, #80                         @ res = mount_volume(&path, &fs, mode);
    add r1, sp, #84
    mov r2, r7
    bl ff16_mount_volume
    mov r6, r0
    cmp r6, #FR_OK                          @ if (res == FR_OK) {
    bne .Lfo_end
    ldr r5, [sp, #84]                       @   r5 = fs
    str r5, [r4, #OBJ_FS]                   @   fp->obj.fs = fs;
    str r5, [sp, #OBJ_FS]                   @   dj.obj.fs = fs;
    mov r0, sp                              @   res = follow_path(&dj, path);
    ldr r1, [sp, #80]
    bl ff16_follow_path
    mov r6, r0
    cmp r6, #FR_OK                          @   if (res == FR_OK) {
    bne .Lfo_chk
    ldrb r0, [sp, #(DIR_FN + NSFLAG)]       @     if (dj.fn[NSFLAG] & NS_NONAME) {
    tst r0, #NS_NONAME
    beq .Lfo_nname
    movs r6, #FR_INVALID_NAME               @       res = FR_INVALID_NAME;
    b .Lfo_chk
.Lfo_nname:
    .if FF_FS_READONLY != 0
    ldrb r0, [sp, #OBJ_ATTR]                @     } else { if (dj.obj.attr & AM_DIR) res = FR_NO_FILE; }
    tst r0, #AM_DIR
    beq .Lfo_chk
    movs r6, #FR_NO_FILE
    .endif
.Lfo_chk:                                   @   }

    .if FF_FS_READONLY == 0
    tst r7, #(FA_CREATE_ALWAYS | FA_OPEN_ALWAYS | FA_CREATE_NEW)
    beq .Lfo_nocreate                       @   if (mode & (FA_CREATE_ALWAYS | FA_OPEN_ALWAYS | FA_CREATE_NEW)) {
    cmp r6, #FR_OK                          @     if (res != FR_OK) {
    beq .Lfo_exists
    cmp r6, #FR_NO_FILE                     @       if (res == FR_NO_FILE)
    bne .Lfo_setcreate
    mov r0, sp                              @         res = dir_register(&dj);
    bl ff16_dir_register
    mov r6, r0
.Lfo_setcreate:
    orr r7, r7, #FA_CREATE_ALWAYS           @       mode |= FA_CREATE_ALWAYS;
    b .Lfo_created                          @     }
.Lfo_exists:                                @     else {   (the file exists)
    tst r7, #FA_CREATE_NEW                  @       if (mode & FA_CREATE_NEW) {
    beq .Lfo_attr
    movs r6, #FR_EXIST                      @         res = FR_EXIST;
    b .Lfo_created
.Lfo_attr:                                  @       } else {
    ldrb r0, [sp, #OBJ_ATTR]                @         if (dj.obj.attr & (AM_RDO | AM_DIR)) res = FR_DENIED;
    tst r0, #(AM_RDO | AM_DIR)
    beq .Lfo_created
    movs r6, #FR_DENIED
.Lfo_created:
    cmp r6, #FR_OK                          @     if (res == FR_OK && (mode & FA_CREATE_ALWAYS)) {   truncate / initialise
    bne .Lfo_trunc_done
    tst r7, #FA_CREATE_ALWAYS
    beq .Lfo_trunc_done
    bl get_fattime                          @       DWORD tm = get_fattime();
    mov r8, r0
    ldrb r0, [r5, #FS_FS_TYPE]              @       if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lfo_trfat
    mov r0, r4                              @         init_alloc_info(&fp->obj, 0);
    movs r1, #0
    bl ff16_init_alloc_info
    ldr r0, [r5, #FS_DIRBUF]                @         memset(fs->dirbuf + 2, 0, 30);
    adds r0, r0, #2
    movs r1, #0
    movs r2, #30
    bl ff16_mem_set
    ldr r0, [r5, #FS_DIRBUF]                @         memset(fs->dirbuf + 38, 0, 26);
    adds r0, r0, #38
    movs r1, #0
    movs r2, #26
    bl ff16_mem_set
    ldr r0, [r5, #FS_DIRBUF]                @         fs->dirbuf[XDIR_Attr] = AM_ARC;
    movs r1, #AM_ARC
    strb r1, [r0, #XDIR_Attr]
    adds r0, r0, #XDIR_CrtTime              @         st_32(fs->dirbuf + XDIR_CrtTime, tm);
    mov r1, r8
    bl ff16_st_32
    ldr r0, [r5, #FS_DIRBUF]                @         st_32(fs->dirbuf + XDIR_ModTime, tm);
    adds r0, r0, #XDIR_ModTime
    mov r1, r8
    bl ff16_st_32
    ldr r0, [r5, #FS_DIRBUF]                @         fs->dirbuf[XDIR_GenFlags] = 1;
    movs r1, #1
    strb r1, [r0, #XDIR_GenFlags]
    mov r0, sp                              @         res = store_xdir(&dj);
    bl ff16_store_xdir
    mov r6, r0
    cmp r6, #FR_OK                          @         if (res == FR_OK && fp->obj.sclust != 0) {
    bne .Lfo_trunc_done
    ldr r1, [r4, #OBJ_SCLUST]
    cmp r1, #0
    beq .Lfo_trunc_done
    mov r0, r4                              @           res = remove_chain(&fp->obj, fp->obj.sclust, 0);
    movs r2, #0
    bl ff16_remove_chain
    mov r6, r0
    ldr r1, [r4, #OBJ_SCLUST]               @           fs->last_clst = fp->obj.sclust - 1;
    subs r1, r1, #1
    str r1, [r5, #FS_LAST_CLST]
    b .Lfo_trunc_done                       @         }
.Lfo_trfat:                                 @       } else {   (FAT)
    ldr r0, [sp, #DIR_DIR]                  @         st_32(dj.dir + DIR_CrtTime, tm);
    adds r0, r0, #DIR_CrtTime
    mov r1, r8
    bl ff16_st_32
    ldr r0, [sp, #DIR_DIR]                  @         st_32(dj.dir + DIR_ModTime, tm);
    adds r0, r0, #DIR_ModTime
    mov r1, r8
    bl ff16_st_32
    mov r0, r5                              @         cl = ld_clust(fs, dj.dir);
    ldr r1, [sp, #DIR_DIR]
    bl ff16_ld_clust
    mov r9, r0
    ldr r0, [sp, #DIR_DIR]                  @         dj.dir[DIR_Attr] = AM_ARC;
    movs r1, #AM_ARC
    strb r1, [r0, #DIR_Attr]
    mov r0, r5                              @         st_clust(fs, dj.dir, 0);
    ldr r1, [sp, #DIR_DIR]
    movs r2, #0
    bl ff16_st_clust
    ldr r0, [sp, #DIR_DIR]                  @         st_32(dj.dir + DIR_FileSize, 0);
    adds r0, r0, #DIR_FileSize
    movs r1, #0
    bl ff16_st_32
    movs r0, #1                             @         fs->wflag = 1;
    strb r0, [r5, #FS_WFLAG]
    cmp r9, #0                              @         if (cl != 0) {
    beq .Lfo_trunc_done
    ldr r10, [r5, #FS_WINSECT]              @           LBA_t sc = fs->winsect;
    mov r0, sp                              @           res = remove_chain(&dj.obj, cl, 0);
    mov r1, r9
    movs r2, #0
    bl ff16_remove_chain
    mov r6, r0
    cmp r6, #FR_OK                          @           if (res == FR_OK) {
    bne .Lfo_trunc_done
    mov r0, r5                              @             res = move_window(fs, sc);
    mov r1, r10
    bl ff16_move_window
    mov r6, r0
    sub r1, r9, #1                          @             fs->last_clst = cl - 1;
    str r1, [r5, #FS_LAST_CLST]
    b .Lfo_trunc_done                       @           } } } } }
.Lfo_nocreate:                              @   } else {   (FA_OPEN_EXISTING)
    cmp r6, #FR_OK                          @     if (res == FR_OK) {
    bne .Lfo_trunc_done
    ldrb r0, [sp, #OBJ_ATTR]                @       if (dj.obj.attr & AM_DIR) {
    tst r0, #AM_DIR
    beq .Lfo_wrchk
    movs r6, #FR_NO_FILE                    @         res = FR_NO_FILE;
    b .Lfo_trunc_done
.Lfo_wrchk:                                 @       } else {
    tst r7, #FA_WRITE                       @         if ((mode & FA_WRITE) && (dj.obj.attr & AM_RDO)) {
    beq .Lfo_trunc_done
    tst r0, #AM_RDO
    beq .Lfo_trunc_done
    movs r6, #FR_DENIED                     @           res = FR_DENIED;
.Lfo_trunc_done:                            @   } } } }
    cmp r6, #FR_OK                          @   if (res == FR_OK) {
    bne .Lfo_fill
    tst r7, #FA_CREATE_ALWAYS               @     if (mode & FA_CREATE_ALWAYS) mode |= FA_MODIFIED;
    beq .Lfo_dirp
    orr r7, r7, #FA_MODIFIED
.Lfo_dirp:
    ldr r0, [r5, #FS_WINSECT]               @     fp->dir_sect = fs->winsect;
    str r0, [r4, #FIL_DIR_SECT]
    ldr r0, [sp, #DIR_DIR]                  @     fp->dir_ptr = dj.dir;
    str r0, [r4, #FIL_DIR_PTR]
    .endif
.Lfo_fill:                                  @   }
    cmp r6, #FR_OK                          @   if (res == FR_OK) {
    bne .Lfo_end
    ldrb r0, [r5, #FS_FS_TYPE]              @     if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lfo_fatinfo
    mov r0, r4                              @       init_alloc_info(&fp->obj, &dj);
    mov r1, sp
    bl ff16_init_alloc_info
    b .Lfo_common                           @     } else {
.Lfo_fatinfo:
    mov r0, r5                              @       fp->obj.sclust = ld_clust(fs, dj.dir);
    ldr r1, [sp, #DIR_DIR]
    bl ff16_ld_clust
    str r0, [r4, #OBJ_SCLUST]
    ldr r0, [sp, #DIR_DIR]                  @       fp->obj.objsize = ld_32(dj.dir + DIR_FileSize);   (64 bit, high word 0)
    adds r0, r0, #DIR_FileSize
    bl ff16_ld_32
    str r0, [r4, #OBJ_OBJSIZE]
    movs r0, #0
    str r0, [r4, #(OBJ_OBJSIZE + 4)]
.Lfo_common:                                @     }
    ldrh r0, [r5, #FS_ID]                   @     fp->obj.id = fs->id;
    strh r0, [r4, #OBJ_ID]
    strb r7, [r4, #FIL_FLAG]                @     fp->flag = mode;
    movs r0, #0
    strb r0, [r4, #FIL_ERR]                 @     fp->err = 0;
    str r0, [r4, #FIL_SECT]                 @     fp->sect = 0;
    str r0, [r4, #FIL_FPTR]                 @     fp->fptr = 0;
    str r0, [r4, #(FIL_FPTR + 4)]
    .if FF_FS_READONLY == 0
    add r0, r4, #FIL_BUF                    @     memset(fp->buf, 0, sizeof fp->buf);
    movs r1, #0
    mov r2, #512
    bl ff16_mem_set
    tst r7, #FA_SEEKEND                     @     if ((mode & FA_SEEKEND) && fp->obj.objsize > 0) {   (FA_OPEN_APPEND)
    beq .Lfo_end
    ldr r0, [r4, #OBJ_OBJSIZE]
    ldr r1, [r4, #(OBJ_OBJSIZE + 4)]
    orrs r2, r0, r1
    beq .Lfo_end
    str r0, [r4, #FIL_FPTR]                 @       fp->fptr = fp->obj.objsize;
    str r1, [r4, #(FIL_FPTR + 4)]
    mov r8, r0                              @       ofs = fp->obj.objsize;   (r9:r8)
    mov r9, r1
    ldrh r0, [r5, #FS_CSIZE]                @       bcs = (DWORD)fs->csize * 512;   (r10)
    lsl r10, r0, #9
    ldr r11, [r4, #OBJ_SCLUST]              @       clst = fp->obj.sclust;
.Lfo_apploop:                               @       for (ofs = fp->obj.objsize; res == FR_OK && ofs > bcs; ofs -= bcs) {
    cmp r6, #FR_OK
    bne .Lfo_appdone
    cmp r9, #0                              @         ofs > bcs  (64 bit against 32 bit)
    bne .Lfo_appbody
    cmp r8, r10
    bls .Lfo_appdone
.Lfo_appbody:
    mov r0, r4                              @         clst = get_fat(&fp->obj, clst);
    mov r1, r11
    bl ff16_get_fat
    mov r11, r0
    cmp r11, #1                             @         if (clst <= 1) res = FR_INT_ERR;
    bhi .Lfo_appc1
    movs r6, #FR_INT_ERR
.Lfo_appc1:
    cmn r11, #1                             @         if (clst == 0xFFFFFFFF) res = FR_DISK_ERR;
    bne .Lfo_appc2
    movs r6, #FR_DISK_ERR
.Lfo_appc2:
    subs r8, r8, r10                        @         ofs -= bcs
    sbc r9, r9, #0
    b .Lfo_apploop
.Lfo_appdone:
    str r11, [r4, #FIL_CLUST]               @       fp->clust = clst;
    cmp r6, #FR_OK                          @       if (res == FR_OK && ofs % 512) {
    bne .Lfo_end
    lsls r12, r8, #23                            @ [Z = 1 when the low 9 bits of r8 are 0: % 512 == 0; 0x1FF is no Arm immediate]
    beq .Lfo_end
    mov r0, r5                              @         LBA_t sec = clst2sect(fs, clst);
    mov r1, r11
    bl ff16_clst2sect
    cbnz r0, .Lfo_sec                       @         if (sec == 0) {
    movs r6, #FR_INT_ERR                    @           res = FR_INT_ERR;
    b .Lfo_end
.Lfo_sec:                                   @         } else {
    lsr r1, r8, #9                          @           fp->sect = sec + (DWORD)(ofs / 512);
    orr r1, r1, r9, lsl #23
    add r0, r0, r1
    str r0, [r4, #FIL_SECT]
    ldrb r0, [r5, #FS_PDRV]                 @           if (disk_read(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK)
    add r1, r4, #FIL_BUF
    ldr r2, [r4, #FIL_SECT]
    movs r3, #1
    bl disk_read
    cbz r0, .Lfo_end
    movs r6, #FR_DISK_ERR                   @             res = FR_DISK_ERR;
    .endif                                  @ } } } }
.Lfo_end:
    cmp r6, #FR_OK                          @ if (res != FR_OK) fp->obj.fs = 0;
    beq .Lfo_done
    movs r0, #0
    str r0, [r4, #OBJ_FS]
.Lfo_done:
    mov r0, r6                              @ return res;
.Lfo_ret:
    add sp, sp, #92
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .ltorg
ENDFUNC ff16_f_open

@ -----------------------------------------------------------------------------
@ f_read - read from a file (ff.c f_read, FF_FS_TINY 0, FF_MAX_SS = 512).  With FF_FS_READONLY 1 the file has no dirty
@ sector buffer (no FA_DIRTY handling).
@ In       : r0 = fp, r1 = buff, r2 = btr (bytes to read), r3 = br (UINT* bytes read)
@ Out      : r0 = FRESULT; *br = bytes read
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 = fp, r5 = fs, r6 = rbuff, r7 = btr, r8 = br, r9 = csect, r10 = cc / rcnt, r11 = sect
@ Locals   : [sp+0] fs (for validate)
@ -----------------------------------------------------------------------------
FUNC ff16_f_read
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #4                          @ FATFS *fs; (4 bytes keep the stack 8-byte aligned)
    mov r4, r0                              @ r4 = fp
    mov r6, r1                              @ BYTE *rbuff = (BYTE*)buff;
    mov r7, r2                              @ r7 = btr
    mov r8, r3                              @ r8 = br
    movs r0, #0
    str r0, [r8]                            @ *br = 0;
    mov r0, r4                              @ res = validate(&fp->obj, &fs);
    mov r1, sp
    bl ff16_validate
    cmp r0, #0
    bne .Lfr_ret                       @ if (res != FR_OK ...) return res;
    ldr r5, [sp]                            @ r5 = fs
    ldrb r0, [r4, #FIL_ERR]                 @ || (res = (FRESULT)fp->err) != FR_OK) return res;
    cmp r0, #0
    bne .Lfr_ret
    ldrb r0, [r4, #FIL_FLAG]                @ if (!(fp->flag & FA_READ)) return FR_DENIED;
    tst r0, #FA_READ
    bne .Lfr_ok
    movs r0, #FR_DENIED
    b .Lfr_ret
.Lfr_ok:
    ldr r0, [r4, #OBJ_OBJSIZE]              @ remain = fp->obj.objsize - fp->fptr;   (64 bit: r1:r0)
    ldr r1, [r4, #(OBJ_OBJSIZE + 4)]
    ldr r2, [r4, #FIL_FPTR]
    ldr r3, [r4, #(FIL_FPTR + 4)]
    subs r0, r0, r2
    sbc r1, r1, r3
    cbnz r1, .Lfr_loop                      @ if (btr > remain) btr = (UINT)remain;   (remain >= 2^32: btr is smaller)
    cmp r7, r0
    it hi
    movhi r7, r0
.Lfr_loop:                                  @ for ( ; btr > 0; btr -= rcnt, *br += rcnt, rbuff += rcnt, fp->fptr += rcnt) {
    cmp r7, #0
    beq .Lfr_done
    ldr r0, [r4, #FIL_FPTR]                 @   if (fp->fptr % 512 == 0) {
    lsls r12, r0, #23                            @ [Z = 1 when the low 9 bits of r0 are 0: % 512 == 0; 0x1FF is no Arm immediate]
    bne .Lfr_part
    ldr r1, [r4, #(FIL_FPTR + 4)]           @     csect = (UINT)(fp->fptr / 512 & (fs->csize - 1));
    lsrs r0, r0, #9
    orr r0, r0, r1, lsl #23                 @       (low 32 bits of fptr / 512)
    ldrh r2, [r5, #FS_CSIZE]
    subs r2, r2, #1
    and r9, r0, r2
    cmp r9, #0                              @     if (csect == 0) {
    bne .Lfr_sect
    ldr r0, [r4, #FIL_FPTR]                 @       if (fp->fptr == 0) clst = fp->obj.sclust;
    ldr r1, [r4, #(FIL_FPTR + 4)]
    orrs r0, r0, r1
    bne .Lfr_next
    ldr r0, [r4, #OBJ_SCLUST]
    b .Lfr_clst
.Lfr_next:
    mov r0, r4                              @       else clst = get_fat(&fp->obj, fp->clust);
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_get_fat
.Lfr_clst:
    cmp r0, #2                              @       if (clst < 2) ABORT(fs, FR_INT_ERR);
    blo .Lfr_eint
    cmn r0, #1                              @       if (clst == 0xFFFFFFFF) ABORT(fs, FR_DISK_ERR);
    beq .Lfr_edisk
    str r0, [r4, #FIL_CLUST]                @       fp->clust = clst;
                                            @     }
.Lfr_sect:
    mov r0, r5                              @     sect = clst2sect(fs, fp->clust);
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_clst2sect
    cmp r0, #0
    beq .Lfr_eint                       @     if (sect == 0) ABORT(fs, FR_INT_ERR);
    add r11, r0, r9                         @     sect += csect;
    lsrs r10, r7, #9                        @     cc = btr / 512;
    beq .Lfr_one                            @     if (cc > 0) {
    ldrh r1, [r5, #FS_CSIZE]                @       if (csect + cc > fs->csize) cc = fs->csize - csect;
    add r0, r9, r10
    cmp r0, r1
    bls .Lfr_rd
    sub r10, r1, r9
.Lfr_rd:
    ldrb r0, [r5, #FS_PDRV]                 @       if (disk_read(fs->pdrv, rbuff, sect, cc) != RES_OK) ABORT(fs, FR_DISK_ERR);
    mov r1, r6
    mov r2, r11
    mov r3, r10
    bl disk_read
    cmp r0, #0
    bne .Lfr_edisk
    .if FF_FS_READONLY == 0
    ldrb r0, [r4, #FIL_FLAG]                @       if ((fp->flag & FA_DIRTY) && fp->sect - sect < cc) {
    tst r0, #FA_DIRTY
    beq .Lfr_rdone
    ldr r0, [r4, #FIL_SECT]
    sub r0, r0, r11
    cmp r0, r10
    bhs .Lfr_rdone
    add r0, r6, r0, lsl #9                  @         memcpy(rbuff + ((fp->sect - sect) * 512), fp->buf, 512);
    add r1, r4, #FIL_BUF
    mov r2, #512
    bl ff16_mem_cpy                         @       }   (the dirty buffer is newer than the sector just read)
.Lfr_rdone:
    .endif
    lsl r10, r10, #9                        @       rcnt = 512 * cc;
    b .Lfr_incr                             @       continue;
                                            @     }
.Lfr_one:
    ldr r0, [r4, #FIL_SECT]                 @     if (fp->sect != sect) {
    cmp r0, r11
    beq .Lfr_setsect
    .if FF_FS_READONLY == 0
    ldrb r0, [r4, #FIL_FLAG]                @       if (fp->flag & FA_DIRTY) {   write back the dirty buffer first
    tst r0, #FA_DIRTY
    beq .Lfr_nodirty
    ldrb r0, [r5, #FS_PDRV]                 @         if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    ldr r2, [r4, #FIL_SECT]
    movs r3, #1
    bl disk_write
    cmp r0, #0
    bne .Lfr_edisk
    ldrb r0, [r4, #FIL_FLAG]                @         fp->flag &= (BYTE)~FA_DIRTY;
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]
.Lfr_nodirty:                               @       }
    .endif
    ldrb r0, [r5, #FS_PDRV]                 @       if (disk_read(fs->pdrv, fp->buf, sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    mov r2, r11
    movs r3, #1
    bl disk_read
    cmp r0, #0
    bne .Lfr_edisk
.Lfr_setsect:                               @     }
    str r11, [r4, #FIL_SECT]                @     fp->sect = sect;
                                            @   }
.Lfr_part:
    ldr r0, [r4, #FIL_FPTR]                 @   rcnt = 512 - (UINT)fp->fptr % 512;
    ubfx r0, r0, #0, #9
    rsb r10, r0, #512
    cmp r10, r7                             @   if (rcnt > btr) rcnt = btr;
    it hi
    movhi r10, r7
    add r1, r4, r0                          @   memcpy(rbuff, fp->buf + fp->fptr % 512, rcnt);
    add r1, r1, #FIL_BUF
    mov r0, r6
    mov r2, r10
    bl ff16_mem_cpy
.Lfr_incr:
    subs r7, r7, r10                        @   btr -= rcnt;
    ldr r0, [r8]                            @   *br += rcnt;
    add r0, r0, r10
    str r0, [r8]
    add r6, r6, r10                         @   rbuff += rcnt;
    ldr r0, [r4, #FIL_FPTR]                 @   fp->fptr += rcnt;   (64 bit)
    ldr r1, [r4, #(FIL_FPTR + 4)]
    adds r0, r0, r10
    adc r1, r1, #0
    str r0, [r4, #FIL_FPTR]
    str r1, [r4, #(FIL_FPTR + 4)]
    b .Lfr_loop                             @ }
.Lfr_done:
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lfr_ret
.Lfr_eint:
    movs r0, #FR_INT_ERR                    @ ABORT(fs, FR_INT_ERR): fp->err = (BYTE)FR_INT_ERR; return FR_INT_ERR;
    b .Lfr_err
.Lfr_edisk:
    movs r0, #FR_DISK_ERR                   @ ABORT(fs, FR_DISK_ERR)
.Lfr_err:
    strb r0, [r4, #FIL_ERR]
.Lfr_ret:
    add sp, sp, #4
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .ltorg
ENDFUNC ff16_f_read

    .if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ f_write - write to a file (ff.c f_write, FF_FS_TINY 0, FF_MAX_SS = 512, FF_FS_EXFAT 1)
@ In       : r0 = fp, r1 = buff, r2 = btw (bytes to write), r3 = bw (UINT* bytes written)
@ Out      : r0 = FRESULT; *bw = bytes written
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 = fp, r5 = fs, r6 = wbuff, r7 = btw, r8 = bw, r9 = csect, r10 = cc / wcnt, r11 = clst / sect
@ Locals   : [sp+0] fs (for validate)
@ -----------------------------------------------------------------------------
FUNC ff16_f_write
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #4
    mov r4, r0                              @ r4 = fp
    mov r6, r1                              @ const BYTE *wbuff = (const BYTE*)buff;
    mov r7, r2                              @ r7 = btw
    mov r8, r3                              @ r8 = bw
    movs r0, #0
    str r0, [r8]                            @ *bw = 0;
    mov r0, r4                              @ res = validate(&fp->obj, &fs);
    mov r1, sp
    bl ff16_validate
    cmp r0, #0
    bne .Lfw_ret                       @ if (res != FR_OK ...) return res;
    ldr r5, [sp]                            @ r5 = fs
    ldrb r0, [r4, #FIL_ERR]                 @ || (res = (FRESULT)fp->err) != FR_OK) return res;
    cmp r0, #0
    bne .Lfw_ret
    ldrb r0, [r4, #FIL_FLAG]                @ if (!(fp->flag & FA_WRITE)) return FR_DENIED;
    tst r0, #FA_WRITE
    bne .Lfw_ok
    movs r0, #FR_DENIED
    b .Lfw_ret
.Lfw_ok:
    ldrb r0, [r5, #FS_FS_TYPE]              @ if ((!FF_FS_EXFAT || fs->fs_type != FS_EXFAT) && (DWORD)(fp->fptr + btw) < (DWORD)fp->fptr) {
    cmp r0, #FS_EXFAT                       @   (FF_FS_EXFAT is 1: only the fs_type test remains)
    beq .Lfw_loop
    ldr r0, [r4, #FIL_FPTR]
    adds r1, r0, r7                         @   (DWORD)(fp->fptr + btw) < (DWORD)fp->fptr  (32 bit wrap)
    cmp r1, r0
    bhs .Lfw_loop
    mvn r7, r0                              @   btw = (UINT)(0xFFFFFFFF - (DWORD)fp->fptr);
.Lfw_loop:                                  @ }
                                            @ for ( ; btw > 0; btw -= wcnt, *bw += wcnt, wbuff += wcnt, fp->fptr += wcnt,
                                            @       fp->obj.objsize = (fp->fptr > fp->obj.objsize) ? fp->fptr : fp->obj.objsize) {
    cmp r7, #0
    beq .Lfw_end
    ldr r0, [r4, #FIL_FPTR]                 @   if (fp->fptr % 512 == 0) {
    lsls r12, r0, #23                            @ [Z = 1 when the low 9 bits of r0 are 0: % 512 == 0; 0x1FF is no Arm immediate]
    bne .Lfw_part
    ldr r1, [r4, #(FIL_FPTR + 4)]           @     csect = (UINT)(fp->fptr / 512) & (fs->csize - 1);
    lsrs r0, r0, #9
    orr r0, r0, r1, lsl #23
    ldrh r2, [r5, #FS_CSIZE]
    subs r2, r2, #1
    and r9, r0, r2
    cmp r9, #0                              @     if (csect == 0) {
    bne .Lfw_flush
    ldr r0, [r4, #FIL_FPTR]                 @       if (fp->fptr == 0) {
    ldr r1, [r4, #(FIL_FPTR + 4)]
    orrs r0, r0, r1
    bne .Lfw_cont
    ldr r11, [r4, #OBJ_SCLUST]              @         clst = fp->obj.sclust;
    cmp r11, #0                             @         if (clst == 0) clst = create_chain(&fp->obj, 0);
    bne .Lfw_gotclst
    mov r0, r4
    movs r1, #0
    bl ff16_create_chain
    mov r11, r0
    b .Lfw_gotclst
.Lfw_cont:                                  @       } else {
    mov r0, r4                              @         clst = create_chain(&fp->obj, fp->clust);
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_create_chain
    mov r11, r0
.Lfw_gotclst:                               @       }
    cmp r11, #0                             @       if (clst == 0) break;   (disk full: stop writing)
    beq .Lfw_end
    cmp r11, #1                             @       if (clst == 1) ABORT(fs, FR_INT_ERR);
    beq .Lfw_eint
    cmn r11, #1                             @       if (clst == 0xFFFFFFFF) ABORT(fs, FR_DISK_ERR);
    beq .Lfw_edisk
    str r11, [r4, #FIL_CLUST]               @       fp->clust = clst;
    ldr r0, [r4, #OBJ_SCLUST]               @       if (fp->obj.sclust == 0) fp->obj.sclust = clst;
    cbnz r0, .Lfw_flush
    str r11, [r4, #OBJ_SCLUST]
.Lfw_flush:                                 @     }
    ldrb r0, [r4, #FIL_FLAG]                @     if (fp->flag & FA_DIRTY) {
    tst r0, #FA_DIRTY
    beq .Lfw_nodirty
    ldrb r0, [r5, #FS_PDRV]                 @       if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    ldr r2, [r4, #FIL_SECT]
    movs r3, #1
    bl disk_write
    cmp r0, #0
    bne .Lfw_edisk
    ldrb r0, [r4, #FIL_FLAG]                @       fp->flag &= (BYTE)~FA_DIRTY;
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]
.Lfw_nodirty:                               @     }
    mov r0, r5                              @     sect = clst2sect(fs, fp->clust);
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_clst2sect
    cmp r0, #0
    beq .Lfw_eint                       @     if (sect == 0) ABORT(fs, FR_INT_ERR);
    add r11, r0, r9                         @     sect += csect;
    lsrs r10, r7, #9                        @     cc = btw / 512;
    beq .Lfw_one                            @     if (cc > 0) {
    ldrh r1, [r5, #FS_CSIZE]                @       if (csect + cc > fs->csize) cc = fs->csize - csect;
    add r0, r9, r10
    cmp r0, r1
    bls .Lfw_wr
    sub r10, r1, r9
.Lfw_wr:
    ldrb r0, [r5, #FS_PDRV]                 @       if (disk_write(fs->pdrv, wbuff, sect, cc) != RES_OK) ABORT(fs, FR_DISK_ERR);
    mov r1, r6
    mov r2, r11
    mov r3, r10
    bl disk_write
    cmp r0, #0
    bne .Lfw_edisk
    ldr r0, [r4, #FIL_SECT]                 @       if (fp->sect - sect < cc) {
    sub r0, r0, r11
    cmp r0, r10
    bhs .Lfw_wdone
    add r1, r6, r0, lsl #9                  @         memcpy(fp->buf, wbuff + ((fp->sect - sect) * 512), 512);
    add r0, r4, #FIL_BUF
    mov r2, #512
    bl ff16_mem_cpy
    ldrb r0, [r4, #FIL_FLAG]                @         fp->flag &= (BYTE)~FA_DIRTY;
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]
.Lfw_wdone:                                 @       }
    lsl r10, r10, #9                        @       wcnt = 512 * cc;
    b .Lfw_incr                             @       continue;
                                            @     }
.Lfw_one:
    ldr r0, [r4, #FIL_SECT]                 @     if (fp->sect != sect &&
    cmp r0, r11
    beq .Lfw_setsect
    ldr r0, [r4, #FIL_FPTR]                 @         fp->fptr < fp->obj.objsize &&   (64 bit compare)
    ldr r1, [r4, #(FIL_FPTR + 4)]
    ldr r2, [r4, #OBJ_OBJSIZE]
    ldr r3, [r4, #(OBJ_OBJSIZE + 4)]
    cmp r0, r2
    sbcs r12, r1, r3
    bhs .Lfw_setsect
    ldrb r0, [r5, #FS_PDRV]                 @         disk_read(fs->pdrv, fp->buf, sect, 1) != RES_OK)
    add r1, r4, #FIL_BUF
    mov r2, r11
    movs r3, #1
    bl disk_read
    cmp r0, #0
    bne .Lfw_edisk                          @       ABORT(fs, FR_DISK_ERR);
.Lfw_setsect:
    str r11, [r4, #FIL_SECT]                @     fp->sect = sect;
                                            @   }
.Lfw_part:
    ldr r0, [r4, #FIL_FPTR]                 @   wcnt = 512 - (UINT)fp->fptr % 512;
    ubfx r0, r0, #0, #9
    rsb r10, r0, #512
    cmp r10, r7                             @   if (wcnt > btw) wcnt = btw;
    it hi
    movhi r10, r7
    add r0, r4, r0                          @   memcpy(fp->buf + fp->fptr % 512, wbuff, wcnt);
    add r0, r0, #FIL_BUF
    mov r1, r6
    mov r2, r10
    bl ff16_mem_cpy
    ldrb r0, [r4, #FIL_FLAG]                @   fp->flag |= FA_DIRTY;
    orr r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]
.Lfw_incr:
    subs r7, r7, r10                        @   btw -= wcnt;
    ldr r0, [r8]                            @   *bw += wcnt;
    add r0, r0, r10
    str r0, [r8]
    add r6, r6, r10                         @   wbuff += wcnt;
    ldr r0, [r4, #FIL_FPTR]                 @   fp->fptr += wcnt;   (64 bit)
    ldr r1, [r4, #(FIL_FPTR + 4)]
    adds r0, r0, r10
    adc r1, r1, #0
    str r0, [r4, #FIL_FPTR]
    str r1, [r4, #(FIL_FPTR + 4)]
    ldr r2, [r4, #OBJ_OBJSIZE]              @   fp->obj.objsize = (fp->fptr > fp->obj.objsize) ? fp->fptr : fp->obj.objsize;
    ldr r3, [r4, #(OBJ_OBJSIZE + 4)]
    cmp r2, r0                              @     objsize < fptr ?  (64 bit)
    sbcs r12, r3, r1
    bhs .Lfw_loop                           @     objsize >= fptr: unchanged
    str r0, [r4, #OBJ_OBJSIZE]
    str r1, [r4, #(OBJ_OBJSIZE + 4)]
    b .Lfw_loop                             @ }
.Lfw_end:
    ldrb r0, [r4, #FIL_FLAG]                @ fp->flag |= FA_MODIFIED;
    orr r0, r0, #FA_MODIFIED
    strb r0, [r4, #FIL_FLAG]
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lfw_ret
.Lfw_eint:
    movs r0, #FR_INT_ERR                    @ ABORT(fs, FR_INT_ERR): fp->err = (BYTE)FR_INT_ERR; return FR_INT_ERR;
    b .Lfw_err
.Lfw_edisk:
    movs r0, #FR_DISK_ERR                   @ ABORT(fs, FR_DISK_ERR)
.Lfw_err:
    strb r0, [r4, #FIL_ERR]
.Lfw_ret:
    add sp, sp, #4
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .ltorg
ENDFUNC ff16_f_write

@ -----------------------------------------------------------------------------
@ f_sync - flush the cached data and the directory entry of a file (ff.c f_sync, FF_FS_EXFAT 1, FF_FS_REENTRANT 0)
@ In       : r0 = fp
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 = fp, r5 = fs, r6 = res, r7 = fs->dirbuf / dir
@ Locals   : [sp+0] DIR dj (80 bytes, exFAT), [sp+80] fs (for validate)
@ -----------------------------------------------------------------------------
FUNC ff16_f_sync
    push {r4, r5, r6, r7, lr}
    sub sp, sp, #84                         @ DIR dj (80) + FATFS *fs (4)
    mov r4, r0                              @ r4 = fp
    add r1, sp, #80                         @ res = validate(&fp->obj, &fs);
    bl ff16_validate
    mov r6, r0
    cmp r6, #FR_OK                          @ if (res == FR_OK) {
    bne .Lfs_ret
    ldr r5, [sp, #80]                       @   r5 = fs
    ldrb r0, [r4, #FIL_FLAG]                @   if (fp->flag & FA_MODIFIED) {
    tst r0, #FA_MODIFIED
    beq .Lfs_ret
    tst r0, #FA_DIRTY                       @     if (fp->flag & FA_DIRTY) {
    beq .Lfs_nodirty
    ldrb r0, [r5, #FS_PDRV]                 @       if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) return FR_DISK_ERR;
    add r1, r4, #FIL_BUF
    ldr r2, [r4, #FIL_SECT]
    movs r3, #1
    bl disk_write
    cmp r0, #0
    beq .Lfs_wrote
    movs r6, #FR_DISK_ERR
    b .Lfs_ret
.Lfs_wrote:
    ldrb r0, [r4, #FIL_FLAG]                @       fp->flag &= (BYTE)~FA_DIRTY;
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]
.Lfs_nodirty:                               @     }
    ldrb r0, [r5, #FS_FS_TYPE]              @     if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lfs_fat
    mov r0, r4                              @       res = fill_first_frag(&fp->obj);
    bl ff16_fill_first_frag
    mov r6, r0
    cmp r6, #FR_OK                          @       if (res == FR_OK) {
    bne .Lfs_xfrag
    mov r0, r4                              @         res = fill_last_frag(&fp->obj, fp->clust, 0xFFFFFFFF);
    ldr r1, [r4, #FIL_CLUST]
    mvn r2, #0
    bl ff16_fill_last_frag
    mov r6, r0
.Lfs_xfrag:
    cmp r6, #FR_OK                          @       if (res == FR_OK) {
    bne .Lfs_ret
    mov r0, sp                              @         res = load_obj_xdir(&dj, &fp->obj);
    mov r1, r4
    bl ff16_load_obj_xdir
    mov r6, r0
    cmp r6, #FR_OK                          @         if (res == FR_OK) {
    bne .Lfs_ret
    ldr r7, [r5, #FS_DIRBUF]                @           r7 = fs->dirbuf
    ldrb r0, [r7, #XDIR_Attr]               @           fs->dirbuf[XDIR_Attr] |= AM_ARC;
    orr r0, r0, #AM_ARC
    strb r0, [r7, #XDIR_Attr]
    ldrb r0, [r4, #OBJ_STAT]                @           fs->dirbuf[XDIR_GenFlags] = fp->obj.stat | 1;
    orr r0, r0, #1
    strb r0, [r7, #XDIR_GenFlags]
    add r0, r7, #XDIR_FstClus               @           st_32(fs->dirbuf + XDIR_FstClus, fp->obj.sclust);
    ldr r1, [r4, #OBJ_SCLUST]
    bl ff16_st_32
    add r0, r7, #XDIR_FileSize              @           st_64(fs->dirbuf + XDIR_FileSize, fp->obj.objsize);
    ldr r2, [r4, #OBJ_OBJSIZE]
    ldr r3, [r4, #(OBJ_OBJSIZE + 4)]
    bl ff16_st_64
    add r0, r7, #XDIR_ValidFileSize         @           st_64(fs->dirbuf + XDIR_ValidFileSize, fp->obj.objsize);
    ldr r2, [r4, #OBJ_OBJSIZE]
    ldr r3, [r4, #(OBJ_OBJSIZE + 4)]
    bl ff16_st_64
    bl get_fattime                          @           st_32(fs->dirbuf + XDIR_ModTime, get_fattime());
    mov r1, r0
    add r0, r7, #XDIR_ModTime
    bl ff16_st_32
    movs r0, #0                             @           fs->dirbuf[XDIR_ModTime10] = 0;
    strb r0, [r7, #XDIR_ModTime10]
    strb r0, [r7, #XDIR_ModTZ]              @           fs->dirbuf[XDIR_ModTZ] = 0;
    add r0, r7, #XDIR_AccTime               @           st_32(fs->dirbuf + XDIR_AccTime, 0);
    movs r1, #0
    bl ff16_st_32
    movs r0, #0                             @           fs->dirbuf[XDIR_AccTZ] = 0;
    strb r0, [r7, #XDIR_AccTZ]
    mov r0, sp                              @           res = store_xdir(&dj);
    bl ff16_store_xdir
    mov r6, r0
    cmp r6, #FR_OK                          @           if (res == FR_OK) {
    bne .Lfs_ret
    mov r0, r5                              @             res = sync_fs(fs);
    bl ff16_sync_fs
    mov r6, r0
    ldrb r0, [r4, #FIL_FLAG]                @             fp->flag &= (BYTE)~FA_MODIFIED;
    bic r0, r0, #FA_MODIFIED
    strb r0, [r4, #FIL_FLAG]
    b .Lfs_ret                              @           } } } }
.Lfs_fat:                                   @     } else {   (FAT)
    mov r0, r5                              @       res = move_window(fs, fp->dir_sect);
    ldr r1, [r4, #FIL_DIR_SECT]
    bl ff16_move_window
    mov r6, r0
    cmp r6, #FR_OK                          @       if (res == FR_OK) {
    bne .Lfs_ret
    ldr r7, [r4, #FIL_DIR_PTR]              @         BYTE *dir = fp->dir_ptr;
    ldrb r0, [r7, #DIR_Attr]                @         dir[DIR_Attr] |= AM_ARC;
    orr r0, r0, #AM_ARC
    strb r0, [r7, #DIR_Attr]
    ldr r0, [r4, #OBJ_FS]                   @         st_clust(fp->obj.fs, dir, fp->obj.sclust);
    mov r1, r7
    ldr r2, [r4, #OBJ_SCLUST]
    bl ff16_st_clust
    add r0, r7, #DIR_FileSize               @         st_32(dir + DIR_FileSize, (DWORD)fp->obj.objsize);
    ldr r1, [r4, #OBJ_OBJSIZE]
    bl ff16_st_32
    bl get_fattime                          @         st_32(dir + DIR_ModTime, get_fattime());
    mov r1, r0
    add r0, r7, #DIR_ModTime
    bl ff16_st_32
    add r0, r7, #DIR_LstAccDate             @         st_16(dir + DIR_LstAccDate, 0);
    movs r1, #0
    bl ff16_st_16
    movs r0, #1                             @         fs->wflag = 1;
    strb r0, [r5, #FS_WFLAG]
    mov r0, r5                              @         res = sync_fs(fs);
    bl ff16_sync_fs
    mov r6, r0
    ldrb r0, [r4, #FIL_FLAG]                @         fp->flag &= (BYTE)~FA_MODIFIED;
    bic r0, r0, #FA_MODIFIED
    strb r0, [r4, #FIL_FLAG]
.Lfs_ret:                                   @ } } } }
    mov r0, r6                              @ return res;
    add sp, sp, #84
    pop {r4, r5, r6, r7, pc}
    .ltorg
ENDFUNC ff16_f_sync
    .endif

@ -----------------------------------------------------------------------------
@ f_close - close a file (ff.c f_close, FF_FS_LOCK 0): sync (read/write build), then invalidate the object
@ In       : r0 = fp
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Locals   : [sp+0] fs (for validate)
@ -----------------------------------------------------------------------------
FUNC ff16_f_close
    push {r4, lr}
    sub sp, sp, #8                          @ FATFS *fs;   (8 bytes keep the stack 8-byte aligned)
    mov r4, r0                              @ r4 = fp
    .if FF_FS_READONLY == 0
    bl ff16_f_sync                          @ res = f_sync(fp);
    cbnz r0, .Lfc_ret                       @ if (res == FR_OK) {
    .endif
    mov r0, r4                              @   res = validate(&fp->obj, &fs);
    mov r1, sp
    bl ff16_validate
    cbnz r0, .Lfc_ret                       @   if (res == FR_OK) {
    movs r1, #0
    str r1, [r4, #OBJ_FS]                   @     fp->obj.fs = 0;   (invalidate the file object)
.Lfc_ret:                                   @   } }
    add sp, sp, #8                          @ return res;
    pop {r4, pc}
ENDFUNC ff16_f_close

@ -----------------------------------------------------------------------------
@ f_lseek - move the file pointer (ff.c f_lseek, FF_USE_FASTSEEK 0, FF_MAX_SS = 512, FF_FS_EXFAT 1).  With
@ FF_FS_READONLY 1 the pointer is always limited to the file size and no cluster chain is created.
@ In       : r0 = fp, r2:r3 = ofs (FSIZE_t, 64 bit; r1 unused)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 = fp, r5 = fs, r6:r7 = ofs, r8:r9 = ifptr, r10 = clst (and the chain mask while it is computed),
@            r11 = bcs
@ Locals   : [sp+0] fs (for validate), [sp+4] nsect (LBA_t)
@ Note     : bcs = fs->csize * 512 is a power of two (mount_volume accepts only a power of two csize), so a quotient
@            a / bcs is compared as a & ~(bcs - 1) (same order of the quotients); the next statement of the C code,
@            fp->fptr = (ifptr - 1) & ~(FSIZE_t)(bcs - 1), uses that same mask.
@ -----------------------------------------------------------------------------
FUNC ff16_f_lseek
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #12                         @ FATFS *fs (4), LBA_t nsect (4), 4 for the alignment
    mov r4, r0                              @ r4 = fp
    mov r6, r2                              @ r7:r6 = ofs
    mov r7, r3
    mov r1, sp                              @ res = validate(&fp->obj, &fs);
    bl ff16_validate
    cmp r0, #0
    bne .Lls_ret                       @ if (res == FR_OK) res = (FRESULT)fp->err;   ... if (res != FR_OK) return res;
    ldr r5, [sp]                            @ r5 = fs
    ldrb r0, [r4, #FIL_ERR]
    cmp r0, #0
    bne .Lls_ret
    .if FF_FS_READONLY == 0
    ldrb r0, [r5, #FS_FS_TYPE]              @ if (res == FR_OK && fs->fs_type == FS_EXFAT)
    cmp r0, #FS_EXFAT
    bne .Lls_body
    mov r0, r4                              @   res = fill_last_frag(&fp->obj, fp->clust, 0xFFFFFFFF);
    ldr r1, [r4, #FIL_CLUST]
    mvn r2, #0
    bl ff16_fill_last_frag
    cmp r0, #0
    bne .Lls_ret                       @ if (res != FR_OK) return res;
    .endif
.Lls_body:
    ldrb r0, [r5, #FS_FS_TYPE]              @ if (fs->fs_type != FS_EXFAT && ofs >= 0x100000000) ofs = 0xFFFFFFFF;
    cmp r0, #FS_EXFAT
    beq .Lls_lim
    cbz r7, .Lls_lim
    mvn r6, #0
    movs r7, #0
.Lls_lim:
    ldr r0, [r4, #OBJ_OBJSIZE]              @ if (ofs > fp->obj.objsize && (FF_FS_READONLY || !(fp->flag & FA_WRITE)))
    ldr r1, [r4, #(OBJ_OBJSIZE + 4)]
    cmp r0, r6                              @   objsize < ofs ?  (64 bit)
    sbcs r12, r1, r7
    bhs .Lls_nolim
    .if FF_FS_READONLY == 0
    ldrb r2, [r4, #FIL_FLAG]                @   (!(fp->flag & FA_WRITE): a writable file may seek beyond the end)
    tst r2, #FA_WRITE
    bne .Lls_nolim
    .endif
    mov r6, r0                              @   ofs = fp->obj.objsize;
    mov r7, r1
.Lls_nolim:
    ldr r8, [r4, #FIL_FPTR]                 @ ifptr = fp->fptr;   (r9:r8)
    ldr r9, [r4, #(FIL_FPTR + 4)]
    movs r0, #0                             @ fp->fptr = nsect = 0;
    str r0, [r4, #FIL_FPTR]
    str r0, [r4, #(FIL_FPTR + 4)]
    str r0, [sp, #4]
    orrs r0, r6, r7                         @ if (ofs > 0) {
    beq .Lls_post
    ldrh r0, [r5, #FS_CSIZE]                @   bcs = (DWORD)fs->csize * 512;   (r11)
    lsl r11, r0, #9
    orrs r0, r8, r9                         @   if (ifptr > 0 &&
    beq .Lls_start
    sub r10, r11, #1                        @       (ofs - 1) / bcs >= (ifptr - 1) / bcs) {
    mvn r10, r10                            @     r10 = ~(bcs - 1)   (low word of the mask; the high word is all ones)
    subs r0, r6, #1                         @     r1:r0 = ofs - 1
    sbc r1, r7, #0
    subs r2, r8, #1                         @     r3:r2 = ifptr - 1
    sbc r3, r9, #0
    and r2, r2, r10                         @     r3:r2 = (ifptr - 1) & ~(FSIZE_t)(bcs - 1)
    and r0, r0, r10                         @     r1:r0 = (ofs - 1) & ~(FSIZE_t)(bcs - 1)
    cmp r0, r2                              @     (ofs - 1) / bcs >= (ifptr - 1) / bcs ?
    sbcs r12, r1, r3
    blo .Lls_start
    str r2, [r4, #FIL_FPTR]                 @     fp->fptr = (ifptr - 1) & ~(FSIZE_t)(bcs - 1);
    str r3, [r4, #(FIL_FPTR + 4)]
    subs r6, r6, r2                         @     ofs -= fp->fptr;
    sbc r7, r7, r3
    ldr r10, [r4, #FIL_CLUST]               @     clst = fp->clust;
    b .Lls_have                             @   } else {
.Lls_start:
    ldr r10, [r4, #OBJ_SCLUST]              @     clst = fp->obj.sclust;
    .if FF_FS_READONLY == 0
    cmp r10, #0                             @     if (clst == 0) {   (no cluster chain yet: create it)
    bne .Lls_setclust
    mov r0, r4                              @       clst = create_chain(&fp->obj, 0);
    movs r1, #0
    bl ff16_create_chain
    mov r10, r0
    cmp r10, #1                             @       if (clst == 1) ABORT(fs, FR_INT_ERR);
    beq .Lls_eint
    cmn r10, #1                             @       if (clst == 0xFFFFFFFF) ABORT(fs, FR_DISK_ERR);
    beq .Lls_edisk
    str r10, [r4, #OBJ_SCLUST]              @       fp->obj.sclust = clst;
.Lls_setclust:                              @     }
    .endif
    str r10, [r4, #FIL_CLUST]               @     fp->clust = clst;
                                            @   }
.Lls_have:
    cmp r10, #0                             @   if (clst != 0) {
    beq .Lls_post
.Lls_while:                                 @     while (ofs > bcs) {   (64 bit ofs against 32 bit bcs)
    cmp r7, #0
    bne .Lls_wbody
    cmp r6, r11
    bls .Lls_wend
.Lls_wbody:
    subs r6, r6, r11                        @       ofs -= bcs;
    sbc r7, r7, #0
    ldr r0, [r4, #FIL_FPTR]                 @       fp->fptr += bcs;
    ldr r1, [r4, #(FIL_FPTR + 4)]
    adds r0, r0, r11
    adc r1, r1, #0
    str r0, [r4, #FIL_FPTR]
    str r1, [r4, #(FIL_FPTR + 4)]
    .if FF_FS_READONLY == 0
    ldrb r2, [r4, #FIL_FLAG]                @       if (fp->flag & FA_WRITE) {
    tst r2, #FA_WRITE
    beq .Lls_getfat
    ldr r2, [r4, #OBJ_OBJSIZE]              @         if (FF_FS_EXFAT... 1 && fp->fptr > fp->obj.objsize) {   (r1:r0 = fptr)
    ldr r3, [r4, #(OBJ_OBJSIZE + 4)]
    cmp r2, r0                              @           objsize < fptr ?  (64 bit)
    sbcs r12, r3, r1
    bhs .Lls_chain
    str r0, [r4, #OBJ_OBJSIZE]              @           fp->obj.objsize = fp->fptr;
    str r1, [r4, #(OBJ_OBJSIZE + 4)]
    ldrb r0, [r4, #FIL_FLAG]                @           fp->flag |= FA_MODIFIED;
    orr r0, r0, #FA_MODIFIED
    strb r0, [r4, #FIL_FLAG]
.Lls_chain:                                 @         }
    mov r0, r4                              @         clst = create_chain(&fp->obj, clst);
    mov r1, r10
    bl ff16_create_chain
    mov r10, r0
    cmp r10, #0                             @         if (clst == 0) {
    bne .Lls_clstchk
    movs r6, #0                             @           ofs = 0; break;
    movs r7, #0
    b .Lls_wend
.Lls_getfat:                                @       } else {
    .endif
    mov r0, r4                              @         clst = get_fat(&fp->obj, clst);
    mov r1, r10
    bl ff16_get_fat
    mov r10, r0
.Lls_clstchk:                               @       }
    cmn r10, #1                             @       if (clst == 0xFFFFFFFF) ABORT(fs, FR_DISK_ERR);
    beq .Lls_edisk
    cmp r10, #1                             @       if (clst <= 1 || clst >= fs->n_fatent) ABORT(fs, FR_INT_ERR);
    bls .Lls_eint
    ldr r0, [r5, #FS_N_FATENT]
    cmp r10, r0
    bhs .Lls_eint
    str r10, [r4, #FIL_CLUST]               @       fp->clust = clst;
    b .Lls_while                            @     }
.Lls_wend:
    ldr r0, [r4, #FIL_FPTR]                 @     fp->fptr += ofs;
    ldr r1, [r4, #(FIL_FPTR + 4)]
    adds r0, r0, r6
    adc r1, r1, r7
    str r0, [r4, #FIL_FPTR]
    str r1, [r4, #(FIL_FPTR + 4)]
    lsls r12, r6, #23                            @     if (ofs % 512) {   [Z = 1 when the low 9 bits of r6 are 0: % 512 == 0; 0x1FF is no Arm immediate]
    beq .Lls_post
    mov r0, r5                              @       nsect = clst2sect(fs, clst);
    mov r1, r10
    bl ff16_clst2sect
    cbz r0, .Lls_eint                       @       if (nsect == 0) ABORT(fs, FR_INT_ERR);
    lsr r1, r6, #9                          @       nsect += (DWORD)(ofs / 512);
    orr r1, r1, r7, lsl #23
    add r0, r0, r1
    str r0, [sp, #4]
                                            @     }
                                            @   }
.Lls_post:                                  @ }
    .if FF_FS_READONLY == 0
    ldr r0, [r4, #FIL_FPTR]                 @ if (!FF_FS_READONLY && fp->fptr > fp->obj.objsize) {
    ldr r1, [r4, #(FIL_FPTR + 4)]
    ldr r2, [r4, #OBJ_OBJSIZE]
    ldr r3, [r4, #(OBJ_OBJSIZE + 4)]
    cmp r2, r0                              @   objsize < fptr ?  (64 bit)
    sbcs r12, r3, r1
    bhs .Lls_sect
    str r0, [r4, #OBJ_OBJSIZE]              @   fp->obj.objsize = fp->fptr;
    str r1, [r4, #(OBJ_OBJSIZE + 4)]
    ldrb r0, [r4, #FIL_FLAG]                @   fp->flag |= FA_MODIFIED;
    orr r0, r0, #FA_MODIFIED
    strb r0, [r4, #FIL_FLAG]
    .endif
.Lls_sect:                                  @ }
    ldr r0, [r4, #FIL_FPTR]                 @ if (fp->fptr % 512 && nsect != fp->sect) {
    lsls r12, r0, #23                            @ [Z = 1 when the low 9 bits of r0 are 0: % 512 == 0; 0x1FF is no Arm immediate]
    beq .Lls_ok
    ldr r1, [sp, #4]
    ldr r2, [r4, #FIL_SECT]
    cmp r1, r2
    beq .Lls_ok
    .if FF_FS_READONLY == 0
    ldrb r0, [r4, #FIL_FLAG]                @   if (fp->flag & FA_DIRTY) {   write back the old sector first
    tst r0, #FA_DIRTY
    beq .Lls_nodirty
    ldrb r0, [r5, #FS_PDRV]                 @     if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    ldr r2, [r4, #FIL_SECT]
    movs r3, #1
    bl disk_write
    cmp r0, #0
    bne .Lls_edisk
    ldrb r0, [r4, #FIL_FLAG]                @     fp->flag &= (BYTE)~FA_DIRTY;
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]
.Lls_nodirty:                               @   }
    .endif
    ldrb r0, [r5, #FS_PDRV]                 @   if (disk_read(fs->pdrv, fp->buf, nsect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    ldr r2, [sp, #4]
    movs r3, #1
    bl disk_read
    cmp r0, #0
    bne .Lls_edisk
    ldr r0, [sp, #4]                        @   fp->sect = nsect;
    str r0, [r4, #FIL_SECT]
.Lls_ok:                                    @ }
    movs r0, #FR_OK                         @ return res;   (FR_OK)
    b .Lls_ret
.Lls_eint:
    movs r0, #FR_INT_ERR                    @ ABORT(fs, FR_INT_ERR): fp->err = (BYTE)FR_INT_ERR; return FR_INT_ERR;
    b .Lls_err
.Lls_edisk:
    movs r0, #FR_DISK_ERR                   @ ABORT(fs, FR_DISK_ERR)
.Lls_err:
    strb r0, [r4, #FIL_ERR]
.Lls_ret:
    add sp, sp, #12
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .ltorg
ENDFUNC ff16_f_lseek
