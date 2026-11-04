@ =============================================================================
@ ff16_vol.s - FatFs R0.16 (production image): drive number, boot sector check, volume search, mount, object validation
@ (DESIGN.md 7A, IMP-29)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c): get_ldnumber (FF_STR_VOLUME_ID 0, FF_VOLUMES 1), check_fs
@ (patch 1: MIN_VOLUME 64), find_volume (FF_MULTI_PARTITION 0, no GPT: FF_LBA64 0), mount_volume (patch 1: MIN_FAT12 32;
@ patch 2: CVE-2026-6682, fasize >= 0x200000), validate.  License and conventions: ff16_low.s.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "config.inc"

    .include "ff16.inc"

    .section .bss_port.ff16, "aw", %nobits
    .balign 4
@ FatFs[FF_VOLUMES]: pointer to the registered work area of drive 0 (owner FF16)
    .global ff16_fatfs_ptr
ff16_fatfs_ptr: .space 4
@ Fsid: mount ID counter
    .global ff16_fsid
ff16_fsid:      .space 2

    .section .rodata.ff16.vol, "a", %progbits
ff16_str_fat32: .ascii "FAT32   "

    .section .text.ff16.vol, "ax", %progbits

@ -----------------------------------------------------------------------------
@ get_ldnumber - logical drive number from the head of a path (ff.c get_ldnumber, FF_STR_VOLUME_ID 0, FF_VOLUMES 1)
@ In       : r0 = pointer to the path pointer
@ Out      : r0 = 0 drive 0, -1 invalid drive; the path pointer advanced past "n:" when a drive prefix is present
@ Clobbers : r1-r3, flags
@ -----------------------------------------------------------------------------
FUNC ff16_get_ldnumber
    ldr r1, [r0]                            @ tt = tp = *path;
    cbz r1, 9f                              @ if (!tp) return -1;
    mov r2, r1                              @ r2 = tt
1:  ldrb r3, [r2], #1                       @ do { chr = *tt++; } while (!IsTerminator(chr) && chr != ':');
    cmp r3, #'!'                            @   IsTerminator(c): (UINT)c < '!' (FF_USE_LFN 0)
    blo 2f
    cmp r3, #':'
    bne 1b
    @ chr == ':'
    movs r3, #1                             @ i = 1;
    ldrb r12, [r1]                          @ if (IsDigit(*tp) && tp + 2 == tt) i = (int)*tp - '0';
    sub r12, r12, #'0'
    cmp r12, #9
    bhi 3f
    adds r1, r1, #2
    cmp r1, r2
    it eq
    moveq r3, r12
3:  cmp r3, #1                              @ if (i >= FF_VOLUMES) return -1;
    bge 9f
    str r2, [r0]                            @ *path = tt;
    mov r0, r3                              @ return i;
    bx lr
2:  movs r0, #0                             @ return 0 (no drive prefix: the default drive)
    bx lr
9:  mov r0, #-1
    bx lr
ENDFUNC ff16_get_ldnumber

@ -----------------------------------------------------------------------------
@ check_fs - is the sector a FAT VBR? (ff.c check_fs)
@ In       : r0 = fs, r1 = sect
@ Out      : r0 = 0 FAT VBR, 2 valid BS but not FAT, 3 not a BS, 4 disk error
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 sign, r6 win, r7 w / b
@ -----------------------------------------------------------------------------
FUNC ff16_check_fs
    push {r4, r5, r6, r7, lr}
    mov r4, r0
    movs r0, #0
    strb r0, [r4, #FS_WFLAG]                @ fs->wflag = 0;
    mov r0, #0xFFFFFFFF
    str r0, [r4, #FS_WINSECT]               @ fs->winsect = (LBA_t)0 - 1;
    mov r0, r4
    bl ff16_move_window                     @ if (move_window(fs, sect) != FR_OK) return 4;
    cbz r0, 1f
    movs r0, #4
    pop {r4, r5, r6, r7, pc}
1:  add r6, r4, #FS_WIN
    add r0, r6, #BS_55AA
    bl ff16_ld_16
    mov r5, r0                              @ sign = ld_16(fs->win + BS_55AA);
    ldrb r0, [r6, #BS_JmpBoot]              @ b = fs->win[BS_JmpBoot];
    cmp r0, #0xEB                           @ if (b == 0xEB || b == 0xE9 || b == 0xE8) {
    beq 2f
    cmp r0, #0xE9
    beq 2f
    cmp r0, #0xE8
    bne .Lcf_out
2:  movw r1, #0xAA55                        @   if (sign == 0xAA55 && !memcmp(fs->win + BS_FilSysType32, "FAT32   ", 8)) return 0;
    cmp r5, r1
    bne 3f
    add r0, r6, #BS_FilSysType32
    ldr r1, =ff16_str_fat32
    movs r2, #8
    bl ff16_memcmp
    cbz r0, .Lcf_fat
3:  add r0, r6, #BPB_BytsPerSec
    bl ff16_ld_16                           @   w = ld_16(fs->win + BPB_BytsPerSec);
    @ (w & (w - 1)) == 0 && w >= FF_MIN_SS && w <= FF_MAX_SS: with both 512, w == 512
    cmp r0, #512
    bne .Lcf_out
    ldrb r7, [r6, #BPB_SecPerClus]          @   b = fs->win[BPB_SecPerClus];
    cbz r7, .Lcf_out                        @   b != 0 && (b & (b - 1)) == 0
    subs r0, r7, #1
    tst r7, r0
    bne .Lcf_out
    add r0, r6, #BPB_RsvdSecCnt
    bl ff16_ld_16                           @   ld_16(fs->win + BPB_RsvdSecCnt) != 0
    cbz r0, .Lcf_out
    ldrb r0, [r6, #BPB_NumFATs]             @   (UINT)fs->win[BPB_NumFATs] - 1 <= 1
    subs r0, r0, #1
    cmp r0, #1
    bhi .Lcf_out
    add r0, r6, #BPB_RootEntCnt
    bl ff16_ld_16                           @   ld_16(fs->win + BPB_RootEntCnt) != 0
    cbz r0, .Lcf_out
    add r0, r6, #BPB_TotSec16               @   (ld_16(fs->win + BPB_TotSec16) >= MIN_VOLUME || ld_32(fs->win + BPB_TotSec32) >= 0x10000)
    bl ff16_ld_16
    cmp r0, #MIN_VOLUME
    bhs 4f
    add r0, r6, #BPB_TotSec32
    bl ff16_ld_32
    cmp r0, #0x10000
    blo .Lcf_out
4:  add r0, r6, #BPB_FATSz16
    bl ff16_ld_16                           @   ld_16(fs->win + BPB_FATSz16) != 0
    cbz r0, .Lcf_out
.Lcf_fat:
    movs r0, #0                             @   return 0;
    pop {r4, r5, r6, r7, pc}
.Lcf_out:
    movw r1, #0xAA55                        @ return sign == 0xAA55 ? 2 : 3;
    cmp r5, r1
    ite eq
    moveq r0, #2
    movne r0, #3
    pop {r4, r5, r6, r7, pc}
    .ltorg
ENDFUNC ff16_check_fs

@ -----------------------------------------------------------------------------
@ find_volume - find the FAT volume: sector 0, else the MBR partitions (ff.c find_volume, part = 0 only)
@ In       : r0 = fs, r1 = part (0: auto)
@ Out      : r0 = check_fs result of the volume found (0 found)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 part, r6 i, r7 fmt; mbr_pt[4] on the stack
@ -----------------------------------------------------------------------------
FUNC ff16_find_volume
    push {r4, r5, r6, r7, lr}
    sub sp, sp, #20                         @ DWORD mbr_pt[4] at [sp] (16 bytes, + 4 for 8-byte alignment)
    mov r4, r0
    mov r5, r1
    movs r1, #0
    bl ff16_check_fs                        @ fmt = check_fs(fs, 0);
    mov r7, r0
    cmp r7, #2                              @ if (fmt != 2 && (fmt >= 3 || part == 0)) return fmt;
    beq 1f
    cmp r7, #3
    bhs .Lfv_ret
    cmp r5, #0
    beq .Lfv_ret
1:  movs r6, #0                             @ for (i = 0; i < 4; i++) mbr_pt[i] = ld_32(fs->win + MBR_Table + i * SZ_PTE + PTE_StLba);
2:  add r0, r4, #(FS_WIN + MBR_Table + PTE_StLba)
    add r0, r0, r6, lsl #4
    bl ff16_ld_32
    str r0, [sp, r6, lsl #2]
    adds r6, r6, #1
    cmp r6, #4
    blo 2b
    subs r6, r5, #1                         @ i = part ? part - 1 : 0;
    cmp r5, #0
    it eq
    moveq r6, #0
3:  ldr r1, [sp, r6, lsl #2]                @ do { fmt = mbr_pt[i] ? check_fs(fs, mbr_pt[i]) : 3;
    cbz r1, 4f
    mov r0, r4
    bl ff16_check_fs
    mov r7, r0
    b 5f
4:  movs r7, #3
5:  cmp r5, #0                              @ } while (part == 0 && fmt >= 2 && ++i < 4);
    bne .Lfv_ret
    cmp r7, #2
    blo .Lfv_ret
    adds r6, r6, #1
    cmp r6, #4
    blo 3b
.Lfv_ret:
    mov r0, r7                              @ return fmt;
    add sp, sp, #20
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_find_volume

@ -----------------------------------------------------------------------------
@ mount_volume - determine the logical drive and mount the volume if needed (ff.c mount_volume)
@ In       : r0 = pointer to the path pointer, r1 = rfs (FATFS** out), r2 = mode (FA_* bits)
@ Out      : r0 = FRESULT; *rfs = the work area (also on failure after the drive is known, as ff.c)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 mode, r6 bsect, r7 fasize, r8 tsect / nclst, r9 sysect, r10 nrsv / fmt, r11 win
@ -----------------------------------------------------------------------------
FUNC ff16_mount_volume
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #4                          @ [sp] = rfs
    str r1, [sp]
    movs r3, #0
    str r3, [r1]                            @ *rfs = 0;
    mov r5, r2
    bl ff16_get_ldnumber                    @ vol = get_ldnumber(path);
    cmp r0, #0                              @ if (vol < 0) return FR_INVALID_DRIVE;
    bge 1f
    movs r0, #FR_INVALID_DRIVE
    b .Lmv_ret
1:  ldr r1, =ff16_fatfs_ptr
    ldr r4, [r1, r0, lsl #2]                @ fs = FatFs[vol];
    cbnz r4, 2f                             @ if (!fs) return FR_NOT_ENABLED;
    movs r0, #FR_NOT_ENABLED
    b .Lmv_ret
2:  ldr r1, [sp]
    str r4, [r1]                            @ *rfs = fs;
    bic r5, r5, #FA_READ                    @ mode &= (BYTE)~FA_READ;
    uxtb r5, r5
    ldrb r0, [r4, #FS_FS_TYPE]              @ if (fs->fs_type != 0) {
    cbz r0, 3f
    ldrb r0, [r4, #FS_PDRV]
    bl disk_status                          @   stat = disk_status(fs->pdrv);
    tst r0, #0x01                           @   if (!(stat & STA_NOINIT)) {
    bne 3f
    cbz r5, 21f                             @     if (!FF_FS_READONLY && mode && (stat & STA_PROTECT)) return FR_WRITE_PROTECTED;
    tst r0, #0x04
    bne .Lmv_wp
21: movs r0, #FR_OK                         @     return FR_OK;
    b .Lmv_ret
3:  movs r0, #0
    strb r0, [r4, #FS_FS_TYPE]              @ fs->fs_type = 0;
    ldrb r0, [r4, #FS_PDRV]
    bl disk_initialize                      @ stat = disk_initialize(fs->pdrv);
    tst r0, #0x01                           @ if (stat & STA_NOINIT) return FR_NOT_READY;
    beq 4f
    movs r0, #FR_NOT_READY
    b .Lmv_ret
4:  cbz r5, 5f                              @ if (!FF_FS_READONLY && mode && (stat & STA_PROTECT)) return FR_WRITE_PROTECTED;
    tst r0, #0x04
    bne .Lmv_wp
5:  mov r0, r4
    movs r1, #0
    bl ff16_find_volume                     @ fmt = find_volume(fs, LD2PT(vol));
    cmp r0, #4                              @ if (fmt == 4) return FR_DISK_ERR;
    bne 6f
    movs r0, #FR_DISK_ERR
    b .Lmv_ret
6:  cmp r0, #2                              @ if (fmt >= 2) return FR_NO_FILESYSTEM;
    bhs .Lmv_nofs
    ldr r6, [r4, #FS_WINSECT]               @ bsect = fs->winsect;
    add r11, r4, #FS_WIN
    add r0, r11, #BPB_BytsPerSec            @ if (ld_16(fs->win + BPB_BytsPerSec) != SS(fs)) return FR_NO_FILESYSTEM;
    bl ff16_ld_16
    cmp r0, #512
    bne .Lmv_nofs
    add r0, r11, #BPB_FATSz16
    bl ff16_ld_16
    mov r7, r0                              @ fasize = ld_16(fs->win + BPB_FATSz16);
    cbnz r7, 7f                             @ if (fasize == 0) fasize = ld_32(fs->win + BPB_FATSz32);
    add r0, r11, #BPB_FATSz32
    bl ff16_ld_32
    mov r7, r0
7:  cmp r7, #0x200000                       @ if (fasize >= 0x200000) return FR_NO_FILESYSTEM;  (patch 2, CVE-2026-6682)
    bhs .Lmv_nofs
    str r7, [r4, #FS_FSIZE]                 @ fs->fsize = fasize;
    ldrb r0, [r11, #BPB_NumFATs]
    strb r0, [r4, #FS_N_FATS]               @ fs->n_fats = fs->win[BPB_NumFATs];
    cmp r0, #1                              @ if (fs->n_fats != 1 && fs->n_fats != 2) return FR_NO_FILESYSTEM;
    beq 8f
    cmp r0, #2
    bne .Lmv_nofs
8:  mul r7, r7, r0                          @ fasize *= fs->n_fats;
    ldrb r0, [r11, #BPB_SecPerClus]
    strh r0, [r4, #FS_CSIZE]                @ fs->csize = fs->win[BPB_SecPerClus];
    cmp r0, #0                       @ if (fs->csize == 0 || (fs->csize & (fs->csize - 1))) return FR_NO_FILESYSTEM;
    beq .Lmv_nofs
    subs r1, r0, #1
    tst r0, r1
    bne .Lmv_nofs
    add r0, r11, #BPB_RootEntCnt
    bl ff16_ld_16
    strh r0, [r4, #FS_N_ROOTDIR]            @ fs->n_rootdir = ld_16(fs->win + BPB_RootEntCnt);
    tst r0, #((512 / SZDIRE) - 1)           @ if (fs->n_rootdir % (SS(fs) / SZDIRE)) return FR_NO_FILESYSTEM;
    bne .Lmv_nofs
    add r0, r11, #BPB_TotSec16
    bl ff16_ld_16
    mov r8, r0                              @ tsect = ld_16(fs->win + BPB_TotSec16);
    cmp r8, #0                             @ if (tsect == 0) tsect = ld_32(fs->win + BPB_TotSec32);
    bne 9f
    add r0, r11, #BPB_TotSec32
    bl ff16_ld_32
    mov r8, r0
9:  add r0, r11, #BPB_RsvdSecCnt
    bl ff16_ld_16
    mov r10, r0                             @ nrsv = ld_16(fs->win + BPB_RsvdSecCnt);
    cmp r10, #0                             @ if (nrsv == 0) return FR_NO_FILESYSTEM;
    beq .Lmv_nofs
    ldrh r0, [r4, #FS_N_ROOTDIR]            @ sysect = nrsv + fasize + fs->n_rootdir / (SS(fs) / SZDIRE);
    add r9, r10, r7
    add r9, r9, r0, lsr #4
    cmp r8, r9                              @ if (tsect < sysect) return FR_NO_FILESYSTEM;
    blo .Lmv_nofs
    sub r8, r8, r9                          @ nclst = (tsect - sysect) / fs->csize;
    ldrh r0, [r4, #FS_CSIZE]
    udiv r8, r8, r0
    cmp r8, #0                              @ if (nclst == 0) return FR_NO_FILESYSTEM;
    beq .Lmv_nofs
    movs r0, #0                             @ fmt = 0;
    ldr r1, =MAX_FAT32
    cmp r8, r1
    it ls
    movls r0, #FS_FAT32                     @ if (nclst <= MAX_FAT32) fmt = FS_FAT32;
    movw r1, #MAX_FAT16
    cmp r8, r1
    it ls
    movls r0, #FS_FAT16                     @ if (nclst <= MAX_FAT16) fmt = FS_FAT16;
    movw r1, #MAX_FAT12
    cmp r8, r1
    it ls
    movls r0, #FS_FAT12                     @ if (nclst <= MAX_FAT12) fmt = FS_FAT12;
    cmp r8, #MIN_FAT12
    it ls
    movls r0, #0                            @ if (nclst <= MIN_FAT12) fmt = 0;  (patch 1)
    cmp r0, #0                              @ if (fmt == 0) return FR_NO_FILESYSTEM;
    beq .Lmv_nofs
    str r0, [sp]                            @ (rfs is no longer needed: [sp] = fmt)
    adds r1, r8, #2
    str r1, [r4, #FS_N_FATENT]              @ fs->n_fatent = nclst + 2;
    str r6, [r4, #FS_VOLBASE]               @ fs->volbase = bsect;
    add r1, r6, r10
    str r1, [r4, #FS_FATBASE]               @ fs->fatbase = bsect + nrsv;
    add r1, r6, r9
    str r1, [r4, #FS_DATABASE]              @ fs->database = bsect + sysect;
    cmp r0, #FS_FAT32                       @ if (fmt == FS_FAT32) {
    bne 10f
    add r0, r11, #BPB_FSVer32
    bl ff16_ld_16                           @   if (ld_16(fs->win + BPB_FSVer32) != 0) return FR_NO_FILESYSTEM;
    cmp r0, #0
    bne .Lmv_nofs
    ldrh r0, [r4, #FS_N_ROOTDIR]            @   if (fs->n_rootdir != 0) return FR_NO_FILESYSTEM;
    cmp r0, #0
    bne .Lmv_nofs
    add r0, r11, #BPB_RootClus32
    bl ff16_ld_32
    str r0, [r4, #FS_DIRBASE]               @   fs->dirbase = ld_32(fs->win + BPB_RootClus32);
    ldr r0, [r4, #FS_N_FATENT]
    lsls r1, r0, #2                         @   szbfat = fs->n_fatent * 4;
    b 11f
10: ldrh r0, [r4, #FS_N_ROOTDIR]            @ } else { if (fs->n_rootdir == 0) return FR_NO_FILESYSTEM;
    cmp r0, #0
    beq .Lmv_nofs
    ldr r0, [r4, #FS_FATBASE]
    add r0, r0, r7
    str r0, [r4, #FS_DIRBASE]               @   fs->dirbase = fs->fatbase + fasize;
    ldr r0, [r4, #FS_N_FATENT]              @   szbfat = (fmt == FS_FAT16) ? fs->n_fatent * 2 : fs->n_fatent * 3 / 2 + (fs->n_fatent & 1);
    ldr r2, [sp]
    cmp r2, #FS_FAT16
    bne 101f
    lsls r1, r0, #1
    b 11f
101: add r1, r0, r0, lsl #1
    lsrs r1, r1, #1
    and r2, r0, #1
    add r1, r1, r2
11: ldr r0, [r4, #FS_FSIZE]                 @ if (fs->fsize < (szbfat + (SS(fs) - 1)) / SS(fs)) return FR_NO_FILESYSTEM;
    add r1, r1, #511
    cmp r0, r1, lsr #9
    blo .Lmv_nofs
    mov r0, #0xFFFFFFFF
    str r0, [r4, #FS_FREE_CLST]             @ fs->last_clst = fs->free_clst = 0xFFFFFFFF;
    str r0, [r4, #FS_LAST_CLST]
    movs r0, #0x80
    strb r0, [r4, #FS_FSI_FLAG]             @ fs->fsi_flag = 0x80;
    ldr r0, [sp]                            @ if (fmt == FS_FAT32 && ld_16(fs->win + BPB_FSInfo32) == 1 && move_window(fs, bsect + 1) == FR_OK) {
    cmp r0, #FS_FAT32
    bne 12f
    add r0, r11, #BPB_FSInfo32
    bl ff16_ld_16
    cmp r0, #1
    bne 12f
    mov r0, r4
    adds r1, r6, #1
    bl ff16_move_window
    cbnz r0, 12f
    movs r0, #0
    strb r0, [r4, #FS_FSI_FLAG]             @   fs->fsi_flag = 0;
    mov r0, r11                             @   if (ld_32(fs->win + FSI_LeadSig) == 0x41615252
    bl ff16_ld_32
    ldr r1, =0x41615252
    cmp r0, r1
    bne 12f
    add r0, r11, #FSI_StrucSig              @     && ld_32(fs->win + FSI_StrucSig) == 0x61417272
    bl ff16_ld_32
    ldr r1, =0x61417272
    cmp r0, r1
    bne 12f
    add r0, r11, #BS_55AA - 2               @     && ld_32(fs->win + FSI_TrailSig) == 0xAA550000) {   (FSI_TrailSig = 508)
    bl ff16_ld_32
    ldr r1, =0xAA550000
    cmp r0, r1
    bne 12f
    add r0, r11, #FSI_Free_Count
    bl ff16_ld_32
    str r0, [r4, #FS_FREE_CLST]             @     fs->free_clst = ld_32(fs->win + FSI_Free_Count);
    add r0, r11, #FSI_Nxt_Free
    bl ff16_ld_32
    str r0, [r4, #FS_LAST_CLST]             @     fs->last_clst = ld_32(fs->win + FSI_Nxt_Free);
12: ldr r0, [sp]
    strb r0, [r4, #FS_FS_TYPE]              @ fs->fs_type = (BYTE)fmt;
    ldr r1, =ff16_fsid
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]                           @ fs->id = ++Fsid;
    strh r0, [r4, #FS_ID]
    movs r0, #FR_OK
    b .Lmv_ret
.Lmv_wp:
    movs r0, #FR_WRITE_PROTECTED
    b .Lmv_ret
.Lmv_nofs:
    movs r0, #FR_NO_FILESYSTEM
.Lmv_ret:
    add sp, sp, #4
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .ltorg
ENDFUNC ff16_mount_volume

@ -----------------------------------------------------------------------------
@ validate - check that a file/directory object is valid (ff.c validate)
@ In       : r0 = obj, r1 = rfs (FATFS** out)
@ Out      : r0 = FR_OK / FR_INVALID_OBJECT; *rfs = obj->fs or 0
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_validate
    push {r4, r5, r6, lr}
    mov r4, r0
    mov r5, r1
    movs r6, #FR_INVALID_OBJECT             @ FRESULT res = FR_INVALID_OBJECT;
    cbz r4, 1f                              @ if (obj && obj->fs && obj->fs->fs_type && obj->id == obj->fs->id) {
    ldr r0, [r4, #OBJ_FS]
    cbz r0, 1f
    ldrb r1, [r0, #FS_FS_TYPE]
    cbz r1, 1f
    ldrh r1, [r4, #OBJ_ID]
    ldrh r2, [r0, #FS_ID]
    cmp r1, r2
    bne 1f
    ldrb r0, [r0, #FS_PDRV]
    bl disk_status                          @   if (!(disk_status(obj->fs->pdrv) & STA_NOINIT)) res = FR_OK;
    tst r0, #0x01
    it eq
    moveq r6, #FR_OK
1:  movs r0, #0                             @ *rfs = (res == FR_OK) ? obj->fs : 0;
    cbnz r6, 2f
    ldr r0, [r4, #OBJ_FS]
2:  str r0, [r5]
    mov r0, r6
    pop {r4, r5, r6, pc}
ENDFUNC ff16_validate

