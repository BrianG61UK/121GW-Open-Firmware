@ =============================================================================
@ ffx_api.s - FatFs R0.16 w/patch 2, exFAT configuration: directory access and the file-system level API (group E)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c, FF_FS_EXFAT 1, FF_USE_LFN 1, FF_FS_RPATH 0, FF_VOLUMES 1,
@ FF_CODE_PAGE 437) from its preprocessed form ff_x.c (application configuration; ff_xro.c is the bootloader
@ configuration with FF_FS_READONLY 1):
@   f_opendir, f_closedir, f_readdir, f_stat                       (also in the read-only configuration)
@   f_getfree, f_truncate, f_unlink, f_mkdir, f_rename, f_chmod, f_utime    (FF_FS_READONLY == 0 only)
@ Each routine is named ff16_<C name>; it follows the C statements in order and the comments quote them.  Calling
@ convention AAPCS (r0-r3, r12 scratch, r4-r11 preserved, 8-byte aligned stack at calls); the C locals that must have
@ an address (the path pointers, fs, DIR dj, FFOBJID obj) live in the stack frame, offsets named per routine.
@ Routines of other groups are called by their ff16_ names (arguments exactly as the C static functions):
@   ff16_mount_volume(&path, &fs, mode)   ff16_validate(obj, &fs)       ff16_follow_path(dp, path)
@   ff16_get_ldnumber(&path)              ff16_dir_sdi(dp, ofs)         ff16_dir_read(dp, vol)
@   ff16_dir_next(dp, stretch)            ff16_dir_register(dp)         ff16_dir_remove(dp)
@   ff16_dir_clear(fs, clst)              ff16_get_fileinfo(dp, fno)    ff16_init_alloc_info(dobj, sdir)
@   ff16_ld_clust(fs, dir)                ff16_st_clust(fs, dir, cl)    ff16_get_fat(obj, clst)
@   ff16_create_chain(obj, clst)          ff16_remove_chain(obj, clst, pclst)
@   ff16_move_window(fs, sect)            ff16_sync_fs(fs)              ff16_clst2sect(fs, clst)
@   ff16_store_xdir(dp)                   ff16_ld_16(ptr)  ff16_ld_32(ptr)  ff16_st_16(ptr, v)  ff16_st_32(ptr, v)
@   ff16_mem_cpy(dst, src, n)             ff16_mem_set(dst, val, n)
@   disk_write(pdrv, buff, sector, count) get_fattime()
@
@ FatFs license (ChaN): "FatFs module is an open source software. Redistribution and use of FatFs in source and binary forms,
@ with or without modification, are permitted provided that the following condition is met: 1. Redistributions of source
@ code must retain the above copyright notice, this condition and the following disclaimer.  This software is provided by
@ the copyright holder and contributors "AS IS" and any warranties related to this software are DISCLAIMED.  The copyright
@ owner or contributors be NOT LIABLE for any damages caused by use of this software."  Copyright (C) 2025, ChaN, all right
@ reserved.
@
@ Structure offsets and constants: ff16x.inc (FATFS FS_*, FFOBJID OBJ_*, FIL FIL_*, DIR DIR_*, FILINFO FNO_*).
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ff16x.inc"

    .section .text.ff16x.api, "ax", %progbits

@ -----------------------------------------------------------------------------
@ f_opendir - open a directory (ff_x.c f_opendir)
@ In       : r0 = dp (DIR*), r1 = path
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 res.   Frame: [sp] fs, [sp+4] path
@ -----------------------------------------------------------------------------
    .equ OD_FS,   0
    .equ OD_PATH, 4
    .equ OD_FRAME, 8
FUNC ff16_f_opendir
    push {r4, r5, r6, lr}
    sub sp, sp, #OD_FRAME
    mov r4, r0                              @ r4 = dp
    str r1, [sp, #OD_PATH]                  @ path (mount_volume advances it)
    cbnz r4, 1f                             @ if (!dp) return FR_INVALID_OBJECT;
    movs r0, #FR_INVALID_OBJECT
    b .Lod_ret
1:  add r0, sp, #OD_PATH                    @ res = mount_volume(&path, &fs, 0);
    add r1, sp, #OD_FS
    movs r2, #0
    bl ff16_mount_volume
    mov r6, r0
    cmp r6, #FR_OK                          @ if (res == FR_OK) {
    bne .Lod_end                            @   (else: fall to "if (res != FR_OK) dp->obj.fs = 0;")
    ldr r5, [sp, #OD_FS]
    str r5, [r4, #OBJ_FS]                   @   dp->obj.fs = fs;
    mov r0, r4
    ldr r1, [sp, #OD_PATH]
    bl ff16_follow_path                     @   res = follow_path(dp, path);
    mov r6, r0
    cmp r6, #FR_OK                          @   if (res == FR_OK) {
    bne .Lod_nofile
    ldrb r0, [r4, #(DIR_FN + NSFLAG)]       @     if (!(dp->fn[NSFLAG] & NS_NONAME)) {   (not the origin directory)
    tst r0, #NS_NONAME
    bne .Lod_setid
    ldrb r0, [r4, #OBJ_ATTR]                @       if (dp->obj.attr & AM_DIR) {
    tst r0, #AM_DIR
    beq .Lod_nopath
    ldrb r0, [r5, #FS_FS_TYPE]              @         if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lod_ldclust
    mov r0, r4                              @           init_alloc_info(&dp->obj, dp);
    mov r1, r4
    bl ff16_init_alloc_info
    b .Lod_setid
.Lod_ldclust:                               @         } else {
    mov r0, r5                              @           dp->obj.sclust = ld_clust(fs, dp->dir);
    ldr r1, [r4, #DIR_DIR]
    bl ff16_ld_clust
    str r0, [r4, #OBJ_SCLUST]
    b .Lod_setid                            @         }
.Lod_nopath:                                @       } else {
    movs r6, #FR_NO_PATH                    @         res = FR_NO_PATH;   (not a directory)
.Lod_setid:                                 @     }
    cmp r6, #FR_OK                          @     if (res == FR_OK) {
    bne .Lod_nofile
    ldrh r0, [r5, #FS_ID]                   @       dp->obj.id = fs->id;
    strh r0, [r4, #OBJ_ID]
    mov r0, r4                              @       res = dir_sdi(dp, 0);
    movs r1, #0
    bl ff16_dir_sdi
    mov r6, r0
.Lod_nofile:                                @   }
    cmp r6, #FR_NO_FILE                     @   if (res == FR_NO_FILE) res = FR_NO_PATH;
    bne .Lod_end
    movs r6, #FR_NO_PATH
.Lod_end:                                   @ }
    cbz r6, 2f                              @ if (res != FR_OK) dp->obj.fs = 0;
    movs r0, #0
    str r0, [r4, #OBJ_FS]
2:  mov r0, r6                              @ return res;
.Lod_ret:
    add sp, sp, #OD_FRAME
    pop {r4, r5, r6, pc}
ENDFUNC ff16_f_opendir

@ -----------------------------------------------------------------------------
@ f_closedir - close a directory object (ff_x.c f_closedir)
@ In       : r0 = dp
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp.   Frame: [sp] fs
@ -----------------------------------------------------------------------------
FUNC ff16_f_closedir
    push {r4, lr}
    sub sp, sp, #8
    mov r4, r0
    mov r1, sp                              @ res = validate(&dp->obj, &fs);   (&dp->obj == dp)
    bl ff16_validate
    cbnz r0, 1f                             @ if (res == FR_OK) {
    movs r1, #0                             @   dp->obj.fs = 0;
    str r1, [r4, #OBJ_FS]
1:  add sp, sp, #8                          @ return res;
    pop {r4, pc}
ENDFUNC ff16_f_closedir

@ -----------------------------------------------------------------------------
@ f_readdir - read the next directory item (fno == 0: rewind) (ff_x.c f_readdir)
@ In       : r0 = dp, r1 = fno (FILINFO* or 0)
@ Out      : r0 = FRESULT (fno->fname[0] == 0 at the end of the directory)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fno, r6 res.   Frame: [sp] fs
@ -----------------------------------------------------------------------------
FUNC ff16_f_readdir
    push {r4, r5, r6, lr}
    sub sp, sp, #8
    mov r4, r0
    mov r5, r1
    mov r1, sp                              @ res = validate(&dp->obj, &fs);
    bl ff16_validate
    mov r6, r0
    cmp r6, #FR_OK                          @ if (res == FR_OK) {
    bne .Lrd_end
    cbnz r5, .Lrd_item                      @   if (!fno) {
    mov r0, r4                              @     res = dir_sdi(dp, 0);
    movs r1, #0
    bl ff16_dir_sdi
    mov r6, r0
    b .Lrd_end
.Lrd_item:                                  @   } else {
    movs r0, #0                             @     fno->fname[0] = 0;
    strb r0, [r5, #FNO_FNAME]
    mov r0, r4                              @     res = dir_read(dp, 0);
    movs r1, #0
    bl ff16_dir_read
    mov r6, r0
    cmp r6, #FR_NO_FILE                     @     if (res == FR_NO_FILE) res = FR_OK;
    bne 1f
    movs r6, #FR_OK
1:  cmp r6, #FR_OK                          @     if (res == FR_OK) {
    bne .Lrd_end
    mov r0, r4                              @       get_fileinfo(dp, fno);
    mov r1, r5
    bl ff16_get_fileinfo
    mov r0, r4                              @       res = dir_next(dp, 0);
    movs r1, #0
    bl ff16_dir_next
    mov r6, r0
    cmp r6, #FR_NO_FILE                     @       if (res == FR_NO_FILE) res = FR_OK;
    bne .Lrd_end
    movs r6, #FR_OK
.Lrd_end:                                   @ }
    cbz r5, 2f                              @ if (fno && res != FR_OK) fno->fname[0] = 0;
    cbz r6, 2f
    movs r0, #0
    strb r0, [r5, #FNO_FNAME]
2:  mov r0, r6                              @ return res;
    add sp, sp, #8
    pop {r4, r5, r6, pc}
ENDFUNC ff16_f_readdir

@ -----------------------------------------------------------------------------
@ f_stat - get the information of a file or directory (ff_x.c f_stat)
@ In       : r0 = path, r1 = fno (FILINFO* or 0)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r5 fno, r6 res.   Frame: [sp] DIR dj (80), [sp+80] path
@ -----------------------------------------------------------------------------
    .equ ST_DJ,   0
    .equ ST_PATH, DIR_SIZE
    .equ ST_FRAME, DIR_SIZE + 8
FUNC ff16_f_stat
    push {r4, r5, r6, lr}
    sub sp, sp, #ST_FRAME
    mov r5, r1                              @ r5 = fno
    str r0, [sp, #ST_PATH]
    add r0, sp, #ST_PATH                    @ res = mount_volume(&path, &dj.obj.fs, 0);
    add r1, sp, #(ST_DJ + OBJ_FS)
    movs r2, #0
    bl ff16_mount_volume
    mov r6, r0
    cmp r6, #FR_OK                          @ if (res == FR_OK) {
    bne .Lst_end
    add r0, sp, #ST_DJ                      @   res = follow_path(&dj, path);
    ldr r1, [sp, #ST_PATH]
    bl ff16_follow_path
    mov r6, r0
    cmp r6, #FR_OK                          @   if (res == FR_OK) {
    bne .Lst_end
    ldrb r0, [sp, #(ST_DJ + DIR_FN + NSFLAG)]
    tst r0, #NS_NONAME                      @     if (dj.fn[NSFLAG] & NS_NONAME) {
    beq 1f
    movs r6, #FR_INVALID_NAME               @       res = FR_INVALID_NAME;   (the origin directory has no information)
    b .Lst_end
1:  cbz r5, .Lst_end                        @     } else { if (fno) get_fileinfo(&dj, fno); }
    add r0, sp, #ST_DJ
    mov r1, r5
    bl ff16_get_fileinfo
.Lst_end:
    cbz r5, 2f                              @ if (fno && res != FR_OK) fno->fname[0] = 0;
    cbz r6, 2f
    movs r0, #0
    strb r0, [r5, #FNO_FNAME]
2:  mov r0, r6                              @ return res;
    add sp, sp, #ST_FRAME
    pop {r4, r5, r6, pc}
ENDFUNC ff16_f_stat

    .if FF_FS_READONLY == 0

@ -----------------------------------------------------------------------------
@ f_getfree - get the number of free clusters (ff_x.c f_getfree)
@ In       : r0 = path, r1 = nclst (DWORD*), r2 = fatfs (FATFS**)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 nclst, r5 fatfs, r6 fs, r7 nfree, r8 clst, r9 sect, r10 i, r11 res
@ Frame    : [sp] FFOBJID obj (48; only obj.fs is set, as the C), [sp+48] path, [sp+52] fs
@ -----------------------------------------------------------------------------
    .equ GF_OBJ,  0
    .equ GF_PATH, FFOBJID_SIZE
    .equ GF_FS,   FFOBJID_SIZE + 4
    .equ GF_FRAME, FFOBJID_SIZE + 12
FUNC ff16_f_getfree
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #GF_FRAME
    mov r4, r1
    mov r5, r2
    str r0, [sp, #GF_PATH]
    add r0, sp, #GF_PATH                    @ res = mount_volume(&path, &fs, 0);
    add r1, sp, #GF_FS
    movs r2, #0
    bl ff16_mount_volume
    mov r11, r0
    cmp r11, #FR_OK                         @ if (res == FR_OK) {
    bne .Lgf_ret
    ldr r6, [sp, #GF_FS]
    str r6, [r5]                            @   *fatfs = fs;
    ldr r0, [r6, #FS_FREE_CLST]             @   if (fs->free_clst <= fs->n_fatent - 2) {
    ldr r1, [r6, #FS_N_FATENT]
    subs r1, r1, #2
    cmp r0, r1
    bhi .Lgf_count
    str r0, [r4]                            @     *nclst = fs->free_clst;
    b .Lgf_ret
.Lgf_count:                                 @   } else {
    movs r7, #0                             @     nfree = 0;
    ldrb r0, [r6, #FS_FS_TYPE]
    cmp r0, #FS_FAT12                       @     if (fs->fs_type == FS_FAT12) {   (the C tests the literal 1)
    bne .Lgf_nofat12
    movs r8, #2                             @       clst = 2; obj.fs = fs;
    str r6, [sp, #(GF_OBJ + OBJ_FS)]
.Lgf_f12:                                   @       do {
    mov r0, sp                              @         stat = get_fat(&obj, clst);
    mov r1, r8
    bl ff16_get_fat
    cmn r0, #1                              @         if (stat == 0xFFFFFFFF) { res = FR_DISK_ERR; break; }
    bne 1f
    movs r11, #FR_DISK_ERR
    b .Lgf_done
1:  cmp r0, #1                              @         if (stat == 1) { res = FR_INT_ERR; break; }
    bne 2f
    movs r11, #FR_INT_ERR
    b .Lgf_done
2:  cbnz r0, 3f                             @         if (stat == 0) nfree++;
    adds r7, r7, #1
3:  adds r8, r8, #1                         @       } while (++clst < fs->n_fatent);
    ldr r1, [r6, #FS_N_FATENT]
    cmp r8, r1
    blo .Lgf_f12
    b .Lgf_done
.Lgf_nofat12:                               @     } else {
    cmp r0, #FS_EXFAT                       @       if (fs->fs_type == FS_EXFAT) {
    bne .Lgf_fat
    ldr r8, [r6, #FS_N_FATENT]              @         clst = fs->n_fatent - 2;   (bitmap bits to count)
    subs r8, r8, #2
    ldr r9, [r6, #FS_BITBASE]               @         sect = fs->bitbase;
    movs r10, #0                            @         i = 0;
.Lgf_bm:                                    @         do {
    cmp r10, #0                             @           if (i == 0) {
    bne .Lgf_bmscan
    mov r0, r6                              @             res = move_window(fs, sect++);
    mov r1, r9
    adds r9, r9, #1
    bl ff16_move_window
    mov r11, r0
    cmp r11, #FR_OK                         @             if (res != FR_OK) break;
    bne .Lgf_done
.Lgf_bmscan:                                @           }
    add r0, r6, #FS_WIN                     @           bm = ~fs->win[i];   (BYTE)
    ldrb r0, [r0, r10]
    mvns r0, r0
    uxtb r0, r0
    movs r1, #8                             @           for (b = 8; b && clst; b--, clst--) {
.Lgf_bit:
    cbz r1, .Lgf_bitend
    cmp r8, #0
    beq .Lgf_bitend
    and r2, r0, #1                          @             nfree += bm & 1;
    add r7, r7, r2
    lsrs r0, r0, #1                         @             bm >>= 1;
    subs r1, r1, #1                         @           }   (b--, clst--)
    subs r8, r8, #1
    b .Lgf_bit
.Lgf_bitend:
    adds r10, r10, #1                       @           i = (i + 1) % 512;   (512 = 2^9: low nine bits)
    ubfx r10, r10, #0, #9
    cmp r8, #0                              @         } while (clst);
    bne .Lgf_bm
    b .Lgf_done
.Lgf_fat:                                   @       } else {   (FAT16 / FAT32)
    ldr r8, [r6, #FS_N_FATENT]              @         clst = fs->n_fatent;
    ldr r9, [r6, #FS_FATBASE]               @         sect = fs->fatbase;
    movs r10, #0                            @         i = 0;
.Lgf_fl:                                    @         do {
    cmp r10, #0                             @           if (i == 0) {
    bne .Lgf_fscan
    mov r0, r6                              @             res = move_window(fs, sect++);
    mov r1, r9
    adds r9, r9, #1
    bl ff16_move_window
    mov r11, r0
    cmp r11, #FR_OK                         @             if (res != FR_OK) break;
    bne .Lgf_done
.Lgf_fscan:                                 @           }
    add r0, r6, #FS_WIN
    add r0, r0, r10                         @           (fs->win + i)
    ldrb r1, [r6, #FS_FS_TYPE]
    cmp r1, #FS_FAT16                       @           if (fs->fs_type == FS_FAT16) {
    bne .Lgf_f32
    bl ff16_ld_16                           @             if (ld_16(fs->win + i) == 0) nfree++;
    cbnz r0, 4f
    adds r7, r7, #1
4:  adds r10, r10, #2                       @             i += 2;
    b .Lgf_fnext
.Lgf_f32:                                   @           } else {
    bl ff16_ld_32                           @             if ((ld_32(fs->win + i) & 0x0FFFFFFF) == 0) nfree++;
    bic r0, r0, #0xF0000000
    cbnz r0, 5f
    adds r7, r7, #1
5:  adds r10, r10, #4                       @             i += 4;   }
.Lgf_fnext:
    ubfx r10, r10, #0, #9                   @           i %= 512;
    subs r8, r8, #1                         @         } while (--clst);
    bne .Lgf_fl
.Lgf_done:                                  @     }  }
    cmp r11, #FR_OK                         @     if (res == FR_OK) {
    bne .Lgf_ret
    str r7, [r4]                            @       *nclst = nfree;
    str r7, [r6, #FS_FREE_CLST]             @       fs->free_clst = nfree;
    ldrb r0, [r6, #FS_FSI_FLAG]             @       fs->fsi_flag |= 1;
    orr r0, r0, #1
    strb r0, [r6, #FS_FSI_FLAG]
.Lgf_ret:
    mov r0, r11                             @ return res;
    add sp, sp, #GF_FRAME
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC ff16_f_getfree

@ -----------------------------------------------------------------------------
@ f_truncate - truncate the file at the file pointer (ff_x.c f_truncate)
@ In       : r0 = fp
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fp, r5 fs, r6 res, r7 ncl.   Frame: [sp] fs
@ -----------------------------------------------------------------------------
FUNC ff16_f_truncate
    push {r4, r5, r6, r7, lr}
    sub sp, sp, #4
    mov r4, r0
    mov r1, sp                              @ res = validate(&fp->obj, &fs);
    bl ff16_validate
    cmp r0, #FR_OK                          @ if (res != FR_OK ...) return res;
    bne .Lft_retr0
    ldrb r0, [r4, #FIL_ERR]                 @ || (res = (FRESULT)fp->err) != FR_OK) return res;
    cmp r0, #FR_OK
    bne .Lft_retr0
    ldr r5, [sp]
    ldrb r1, [r4, #FIL_FLAG]                @ if (!(fp->flag & FA_WRITE)) return FR_DENIED;
    tst r1, #FA_WRITE
    bne 1f
    movs r0, #FR_DENIED
    b .Lft_retr0
1:  movs r6, #FR_OK                         @ (res == FR_OK here)
    ldrd r0, r1, [r4, #FIL_FPTR]            @ if (fp->fptr < fp->obj.objsize) {   (64-bit unsigned)
    ldrd r2, r3, [r4, #OBJ_OBJSIZE]
    cmp r0, r2
    sbcs r12, r1, r3
    bhs .Lft_ret                            @   (fptr >= objsize: nothing to cut)
    orrs r2, r0, r1                         @   if (fp->fptr == 0) {
    bne .Lft_mid
    mov r0, r4                              @     res = remove_chain(&fp->obj, fp->obj.sclust, 0);
    ldr r1, [r4, #OBJ_SCLUST]
    movs r2, #0
    bl ff16_remove_chain
    mov r6, r0
    movs r0, #0                             @     fp->obj.sclust = 0;
    str r0, [r4, #OBJ_SCLUST]
    b .Lft_size
.Lft_mid:                                   @   } else {
    mov r0, r4                              @     ncl = get_fat(&fp->obj, fp->clust);
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_get_fat
    mov r7, r0
    movs r6, #FR_OK                         @     res = FR_OK;
    cmn r7, #1                              @     if (ncl == 0xFFFFFFFF) res = FR_DISK_ERR;
    bne 2f
    movs r6, #FR_DISK_ERR
2:  cmp r7, #1                              @     if (ncl == 1) res = FR_INT_ERR;
    bne 3f
    movs r6, #FR_INT_ERR
3:  cmp r6, #FR_OK                          @     if (res == FR_OK && ncl < fs->n_fatent) {
    bne .Lft_size
    ldr r0, [r5, #FS_N_FATENT]
    cmp r7, r0
    bhs .Lft_size
    mov r0, r4                              @       res = remove_chain(&fp->obj, ncl, fp->clust);
    mov r1, r7
    ldr r2, [r4, #FIL_CLUST]
    bl ff16_remove_chain
    mov r6, r0
.Lft_size:                                  @   }
    ldrd r0, r1, [r4, #FIL_FPTR]            @   fp->obj.objsize = fp->fptr;
    strd r0, r1, [r4, #OBJ_OBJSIZE]
    ldrb r0, [r4, #FIL_FLAG]                @   fp->flag |= FA_MODIFIED;
    orr r0, r0, #FA_MODIFIED
    strb r0, [r4, #FIL_FLAG]
    cmp r6, #FR_OK                          @   if (res == FR_OK && (fp->flag & FA_DIRTY)) {
    bne .Lft_chk
    tst r0, #FA_DIRTY
    beq .Lft_chk
    ldrb r0, [r5, #FS_PDRV]                 @     if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) {
    add r1, r4, #FIL_BUF
    ldr r2, [r4, #FIL_SECT]
    movs r3, #1
    bl disk_write
    cbz r0, 4f
    movs r6, #FR_DISK_ERR                   @       res = FR_DISK_ERR;
    b .Lft_chk
4:  ldrb r0, [r4, #FIL_FLAG]                @     } else { fp->flag &= (BYTE)~FA_DIRTY; }
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]
.Lft_chk:                                   @   }
    cbz r6, .Lft_ret                        @   if (res != FR_OK) { fp->err = (BYTE)res; return res; }
    strb r6, [r4, #FIL_ERR]
.Lft_ret:                                   @ }
    mov r0, r6                              @ return res;
.Lft_retr0:
    add sp, sp, #4
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_f_truncate

@ -----------------------------------------------------------------------------
@ f_unlink - delete a file or an empty directory (ff_x.c f_unlink)
@ In       : r0 = path
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 res, r6 dclst
@ Frame    : [sp] DIR dj (80), [sp+80] DIR sdj (80), [sp+160] FFOBJID obj (48), [sp+208] path, [sp+212] fs
@ -----------------------------------------------------------------------------
    .equ UL_DJ,   0
    .equ UL_SDJ,  DIR_SIZE
    .equ UL_OBJ,  2 * DIR_SIZE
    .equ UL_PATH, 2 * DIR_SIZE + FFOBJID_SIZE
    .equ UL_FS,   UL_PATH + 4
    .equ UL_FRAME, UL_PATH + 8
FUNC ff16_f_unlink
    push {r4, r5, r6, r7, r8, lr}
    sub sp, sp, #UL_FRAME
    str r0, [sp, #UL_PATH]
    movs r6, #0                             @ DWORD dclst = 0;
    add r0, sp, #UL_PATH                    @ res = mount_volume(&path, &fs, FA_WRITE);
    add r1, sp, #UL_FS
    movs r2, #FA_WRITE
    bl ff16_mount_volume
    mov r5, r0
    cmp r5, #FR_OK                          @ if (res == FR_OK) {
    bne .Lul_ret
    ldr r4, [sp, #UL_FS]
    str r4, [sp, #(UL_DJ + OBJ_FS)]         @   dj.obj.fs = fs;
    add r0, sp, #UL_DJ                      @   res = follow_path(&dj, path);
    ldr r1, [sp, #UL_PATH]
    bl ff16_follow_path
    mov r5, r0
    cmp r5, #FR_OK                          @   if (res == FR_OK) {
    bne .Lul_c2
    ldrb r0, [sp, #(UL_DJ + DIR_FN + NSFLAG)]
    tst r0, #(NS_DOT | NS_NONAME)           @     if (dj.fn[NSFLAG] & (NS_DOT | NS_NONAME)) {
    beq 1f
    movs r5, #FR_INVALID_NAME               @       res = FR_INVALID_NAME;
    b .Lul_c2
1:  ldrb r0, [sp, #(UL_DJ + OBJ_ATTR)]      @     } else if (dj.obj.attr & AM_RDO) {
    tst r0, #AM_RDO
    beq .Lul_c2
    movs r5, #FR_DENIED                     @       res = FR_DENIED;
.Lul_c2:                                    @   }
    cmp r5, #FR_OK                          @   if (res == FR_OK) {
    bne .Lul_ret
    str r4, [sp, #(UL_OBJ + OBJ_FS)]        @     obj.fs = fs;
    ldrb r0, [r4, #FS_FS_TYPE]              @     if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lul_fat
    add r0, sp, #UL_OBJ                     @       init_alloc_info(&obj, 0);
    movs r1, #0
    bl ff16_init_alloc_info
    ldr r6, [sp, #(UL_OBJ + OBJ_SCLUST)]    @       dclst = obj.sclust;
    b .Lul_isdir
.Lul_fat:                                   @     } else {
    mov r0, r4                              @       dclst = ld_clust(fs, dj.dir);
    ldr r1, [sp, #(UL_DJ + DIR_DIR)]
    bl ff16_ld_clust
    mov r6, r0
.Lul_isdir:                                 @     }
    ldrb r0, [sp, #(UL_DJ + OBJ_ATTR)]      @     if (dj.obj.attr & AM_DIR) {   (a directory must be empty)
    tst r0, #AM_DIR
    beq .Lul_remove
    str r4, [sp, #(UL_SDJ + OBJ_FS)]        @       sdj.obj.fs = fs;
    str r6, [sp, #(UL_SDJ + OBJ_SCLUST)]    @       sdj.obj.sclust = dclst;
    ldrb r0, [r4, #FS_FS_TYPE]              @       if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne 2f
    ldrd r0, r1, [sp, #(UL_OBJ + OBJ_OBJSIZE)]   @     sdj.obj.objsize = obj.objsize;
    strd r0, r1, [sp, #(UL_SDJ + OBJ_OBJSIZE)]
    ldrb r0, [sp, #(UL_OBJ + OBJ_STAT)]     @         sdj.obj.stat = obj.stat;
    strb r0, [sp, #(UL_SDJ + OBJ_STAT)]
2:  add r0, sp, #UL_SDJ                     @       res = dir_sdi(&sdj, 0);
    movs r1, #0
    bl ff16_dir_sdi
    mov r5, r0
    cmp r5, #FR_OK                          @       if (res == FR_OK) {
    bne .Lul_c3
    add r0, sp, #UL_SDJ                     @         res = dir_read(&sdj, 0);
    movs r1, #0
    bl ff16_dir_read
    mov r5, r0
    cmp r5, #FR_OK                          @         if (res == FR_OK) res = FR_DENIED;   (not empty)
    bne 3f
    movs r5, #FR_DENIED
3:  cmp r5, #FR_NO_FILE                     @         if (res == FR_NO_FILE) res = FR_OK;   (empty)
    bne .Lul_c3
    movs r5, #FR_OK
.Lul_c3:                                    @     }
    cmp r5, #FR_OK                          @   }  if (res == FR_OK) {
    bne .Lul_ret
.Lul_remove:
    add r0, sp, #UL_DJ                      @     res = dir_remove(&dj);
    bl ff16_dir_remove
    mov r5, r0
    cmp r5, #FR_OK                          @     if (res == FR_OK && dclst != 0) {
    bne .Lul_c4
    cbz r6, .Lul_c4
    add r0, sp, #UL_OBJ                     @       res = remove_chain(&obj, dclst, 0);
    mov r1, r6
    movs r2, #0
    bl ff16_remove_chain
    mov r5, r0
.Lul_c4:                                    @     }
    cmp r5, #FR_OK                          @     if (res == FR_OK) res = sync_fs(fs);
    bne .Lul_ret
    mov r0, r4
    bl ff16_sync_fs
    mov r5, r0
.Lul_ret:
    mov r0, r5                              @ return res;
    add sp, sp, #UL_FRAME
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_f_unlink

@ -----------------------------------------------------------------------------
@ f_mkdir - create a directory (ff_x.c f_mkdir)
@ In       : r0 = path
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 res, r6 dcl, r7 tm, r8 pcl / dirbuf / dj.dir
@ Frame    : [sp] DIR dj (80), [sp+80] FFOBJID sobj (48), [sp+128] path, [sp+132] fs
@ -----------------------------------------------------------------------------
    .equ MK_DJ,   0
    .equ MK_SOBJ, DIR_SIZE
    .equ MK_PATH, DIR_SIZE + FFOBJID_SIZE
    .equ MK_FS,   MK_PATH + 4
    .equ MK_FRAME, MK_PATH + 8
FUNC ff16_f_mkdir
    push {r4, r5, r6, r7, r8, lr}
    sub sp, sp, #MK_FRAME
    str r0, [sp, #MK_PATH]
    add r0, sp, #MK_PATH                    @ res = mount_volume(&path, &fs, FA_WRITE);
    add r1, sp, #MK_FS
    movs r2, #FA_WRITE
    bl ff16_mount_volume
    mov r5, r0
    cmp r5, #FR_OK                          @ if (res == FR_OK) {
    bne .Lmk_ret
    ldr r4, [sp, #MK_FS]
    str r4, [sp, #(MK_DJ + OBJ_FS)]         @   dj.obj.fs = fs;
    add r0, sp, #MK_DJ                      @   res = follow_path(&dj, path);
    ldr r1, [sp, #MK_PATH]
    bl ff16_follow_path
    mov r5, r0
    cmp r5, #FR_OK                          @   if (res == FR_OK) {
    bne .Lmk_nofile
    ldrb r0, [sp, #(MK_DJ + DIR_FN + NSFLAG)]   @ res = (dj.fn[NSFLAG] & (NS_DOT | NS_NONAME)) ? FR_INVALID_NAME : FR_EXIST;
    tst r0, #(NS_DOT | NS_NONAME)
    bne 1f
    movs r5, #FR_EXIST
    b .Lmk_nofile
1:  movs r5, #FR_INVALID_NAME
.Lmk_nofile:                                @   }
    cmp r5, #FR_NO_FILE                     @   if (res == FR_NO_FILE) {   (the name is free: create)
    bne .Lmk_ret
    str r4, [sp, #(MK_SOBJ + OBJ_FS)]       @     sobj.fs = fs;
    add r0, sp, #MK_SOBJ                    @     dcl = create_chain(&sobj, 0);   (the new directory's cluster)
    movs r1, #0
    bl ff16_create_chain
    mov r6, r0
    movs r5, #FR_OK                         @     res = FR_OK;
    cbnz r6, 2f                             @     if (dcl == 0) res = FR_DENIED;
    movs r5, #FR_DENIED
2:  cmp r6, #1                              @     if (dcl == 1) res = FR_INT_ERR;
    bne 3f
    movs r5, #FR_INT_ERR
3:  cmn r6, #1                              @     if (dcl == 0xFFFFFFFF) res = FR_DISK_ERR;
    bne 4f
    movs r5, #FR_DISK_ERR
4:  bl get_fattime                          @     tm = get_fattime();
    mov r7, r0
    cmp r5, #FR_OK                          @     if (res == FR_OK) {
    bne .Lmk_c2
    mov r0, r4                              @       res = dir_clear(fs, dcl);   (zero the new cluster)
    mov r1, r6
    bl ff16_dir_clear
    mov r5, r0
    cmp r5, #FR_OK                          @       if (res == FR_OK) {
    bne .Lmk_c2
    ldrb r0, [r4, #FS_FS_TYPE]              @         if (!1 || fs->fs_type != FS_EXFAT) {   (FAT: "." and ".." entries)
    cmp r0, #FS_EXFAT
    beq .Lmk_reg
    add r0, r4, #FS_WIN                     @           memset(fs->win + 0, ' ', 11);
    movs r1, #0x20
    movs r2, #11
    bl ff16_mem_set
    movs r0, #0x2E                          @           fs->win[0] = '.';
    strb r0, [r4, #FS_WIN]
    movs r0, #AM_DIR                        @           fs->win[DIR_Attr] = AM_DIR;
    strb r0, [r4, #(FS_WIN + DIR_Attr)]
    add r0, r4, #(FS_WIN + DIR_ModTime)     @           st_32(fs->win + DIR_ModTime, tm);
    mov r1, r7
    bl ff16_st_32
    mov r0, r4                              @           st_clust(fs, fs->win, dcl);
    add r1, r4, #FS_WIN
    mov r2, r6
    bl ff16_st_clust
    add r0, r4, #(FS_WIN + SZDIRE)          @           memcpy(fs->win + SZDIRE, fs->win, SZDIRE);
    add r1, r4, #FS_WIN
    movs r2, #SZDIRE
    bl ff16_mem_cpy
    movs r0, #0x2E                          @           fs->win[SZDIRE + 1] = '.';   (".." entry)
    strb r0, [r4, #(FS_WIN + SZDIRE + 1)]
    ldr r8, [sp, #(MK_DJ + OBJ_SCLUST)]     @           pcl = dj.obj.sclust;
    mov r0, r4                              @           st_clust(fs, fs->win + SZDIRE, pcl);
    add r1, r4, #(FS_WIN + SZDIRE)
    mov r2, r8
    bl ff16_st_clust
    movs r0, #1                             @           fs->wflag = 1;
    strb r0, [r4, #FS_WFLAG]
.Lmk_reg:                                   @         }
    add r0, sp, #MK_DJ                      @         res = dir_register(&dj);
    bl ff16_dir_register
    mov r5, r0
.Lmk_c2:                                    @       }  }
    cmp r5, #FR_OK                          @     if (res == FR_OK) {
    bne .Lmk_fail
    ldrb r0, [r4, #FS_FS_TYPE]              @       if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lmk_dirfat
    ldr r8, [r4, #FS_DIRBUF]                @         (fs->dirbuf)
    add r0, r8, #XDIR_CrtTime               @         st_32(fs->dirbuf + XDIR_CrtTime, tm);
    mov r1, r7
    bl ff16_st_32
    add r0, r8, #XDIR_ModTime               @         st_32(fs->dirbuf + XDIR_ModTime, tm);
    mov r1, r7
    bl ff16_st_32
    add r0, r8, #XDIR_FstClus               @         st_32(fs->dirbuf + XDIR_FstClus, dcl);
    mov r1, r6
    bl ff16_st_32
    ldrh r1, [r4, #FS_CSIZE]                @         st_32(fs->dirbuf + XDIR_FileSize, (DWORD)fs->csize * 512);
    lsls r1, r1, #9
    add r0, r8, #XDIR_FileSize
    bl ff16_st_32
    ldrh r1, [r4, #FS_CSIZE]                @         st_32(fs->dirbuf + XDIR_ValidFileSize, (DWORD)fs->csize * 512);
    lsls r1, r1, #9
    add r0, r8, #XDIR_ValidFileSize
    bl ff16_st_32
    movs r0, #3                             @         fs->dirbuf[XDIR_GenFlags] = 3;   (allocation possible + no FAT chain)
    strb r0, [r8, #XDIR_GenFlags]
    movs r0, #AM_DIR                        @         fs->dirbuf[XDIR_Attr] = AM_DIR;
    strb r0, [r8, #XDIR_Attr]
    add r0, sp, #MK_DJ                      @         res = store_xdir(&dj);
    bl ff16_store_xdir
    mov r5, r0
    b .Lmk_sync
.Lmk_dirfat:                                @       } else {
    ldr r8, [sp, #(MK_DJ + DIR_DIR)]        @         (dj.dir)
    add r0, r8, #DIR_CrtTime                @         st_32(dj.dir + DIR_CrtTime, tm);
    mov r1, r7
    bl ff16_st_32
    add r0, r8, #DIR_ModTime                @         st_32(dj.dir + DIR_ModTime, tm);
    mov r1, r7
    bl ff16_st_32
    mov r0, r4                              @         st_clust(fs, dj.dir, dcl);
    mov r1, r8
    mov r2, r6
    bl ff16_st_clust
    movs r0, #AM_DIR                        @         dj.dir[DIR_Attr] = AM_DIR;
    strb r0, [r8, #DIR_Attr]
    movs r0, #1                             @         fs->wflag = 1;
    strb r0, [r4, #FS_WFLAG]
.Lmk_sync:                                  @       }
    cmp r5, #FR_OK                          @       if (res == FR_OK) res = sync_fs(fs);
    bne .Lmk_ret
    mov r0, r4
    bl ff16_sync_fs
    mov r5, r0
    b .Lmk_ret
.Lmk_fail:                                  @     } else {
    add r0, sp, #MK_SOBJ                    @       remove_chain(&sobj, dcl, 0);   (give the cluster back; res is kept)
    mov r1, r6
    movs r2, #0
    bl ff16_remove_chain
.Lmk_ret:
    mov r0, r5                              @ return res;
    add sp, sp, #MK_FRAME
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_f_mkdir

@ -----------------------------------------------------------------------------
@ f_rename - rename / move a file or directory (ff_x.c f_rename)
@ In       : r0 = path_old, r1 = path_new
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 res, r6 dir / dirbuf, r7 nf / sect, r8 nn
@ Frame    : [sp] DIR djo (80), [sp+80] DIR djn (80), [sp+160] BYTE buf[64], [sp+224] path_old, [sp+228] path_new,
@            [sp+232] fs, [sp+236] nh (WORD)
@ -----------------------------------------------------------------------------
    .equ RN_DJO,  0
    .equ RN_DJN,  DIR_SIZE
    .equ RN_BUF,  2 * DIR_SIZE
    .equ RN_OLD,  2 * DIR_SIZE + 2 * SZDIRE
    .equ RN_NEW,  RN_OLD + 4
    .equ RN_FS,   RN_OLD + 8
    .equ RN_NH,   RN_OLD + 12
    .equ RN_FRAME, RN_OLD + 16
FUNC ff16_f_rename
    push {r4, r5, r6, r7, r8, lr}
    sub sp, sp, #RN_FRAME
    str r0, [sp, #RN_OLD]
    str r1, [sp, #RN_NEW]
    add r0, sp, #RN_NEW                     @ get_ldnumber(&path_new);   (skip a drive prefix of the new path)
    bl ff16_get_ldnumber
    add r0, sp, #RN_OLD                     @ res = mount_volume(&path_old, &fs, FA_WRITE);
    add r1, sp, #RN_FS
    movs r2, #FA_WRITE
    bl ff16_mount_volume
    mov r5, r0
    cmp r5, #FR_OK                          @ if (res == FR_OK) {
    bne .Lrn_ret
    ldr r4, [sp, #RN_FS]
    str r4, [sp, #(RN_DJO + OBJ_FS)]        @   djo.obj.fs = fs;
    add r0, sp, #RN_DJO                     @   res = follow_path(&djo, path_old);
    ldr r1, [sp, #RN_OLD]
    bl ff16_follow_path
    mov r5, r0
    cmp r5, #FR_OK                          @   if (res == FR_OK) {
    bne .Lrn_c2
    ldrb r0, [sp, #(RN_DJO + DIR_FN + NSFLAG)]
    tst r0, #(NS_DOT | NS_NONAME)           @     if (djo.fn[NSFLAG] & (NS_DOT | NS_NONAME)) res = FR_INVALID_NAME;
    beq .Lrn_c2
    movs r5, #FR_INVALID_NAME
.Lrn_c2:                                    @   }
    cmp r5, #FR_OK                          @   if (res == FR_OK) {
    bne .Lrn_ret
    ldrb r0, [r4, #FS_FS_TYPE]              @     if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    beq 1f
    b .Lrn_fat
1:  add r0, sp, #RN_BUF                     @       memcpy(buf, fs->dirbuf, SZDIRE * 2);   (save the 2 object entries)
    ldr r1, [r4, #FS_DIRBUF]
    movs r2, #(SZDIRE * 2)
    bl ff16_mem_cpy
    add r0, sp, #RN_DJN                     @       memcpy(&djn, &djo, sizeof djn);
    add r1, sp, #RN_DJO
    movs r2, #DIR_SIZE
    bl ff16_mem_cpy
    add r0, sp, #RN_DJN                     @       res = follow_path(&djn, path_new);
    ldr r1, [sp, #RN_NEW]
    bl ff16_follow_path
    mov r5, r0
    cmp r5, #FR_OK                          @       if (res == FR_OK) {
    bne .Lrn_x2
    ldr r0, [sp, #(RN_DJN + OBJ_SCLUST)]    @         res = (djn.obj.sclust == djo.obj.sclust && djn.dptr == djo.dptr) ? FR_NO_FILE : FR_EXIST;
    ldr r1, [sp, #(RN_DJO + OBJ_SCLUST)]
    cmp r0, r1
    bne 2f
    ldr r0, [sp, #(RN_DJN + DIR_DPTR)]
    ldr r1, [sp, #(RN_DJO + DIR_DPTR)]
    cmp r0, r1
    bne 2f
    movs r5, #FR_NO_FILE                    @         (same object: renaming onto itself is "name free")
    b .Lrn_x2
2:  movs r5, #FR_EXIST
.Lrn_x2:                                    @       }
    cmp r5, #FR_NO_FILE                     @       if (res == FR_NO_FILE) {
    bne .Lrn_post
    add r0, sp, #RN_DJN                     @         res = dir_register(&djn);
    bl ff16_dir_register
    mov r5, r0
    cmp r5, #FR_OK                          @         if (res == FR_OK) {
    bne .Lrn_post
    ldr r6, [r4, #FS_DIRBUF]                @           nf = fs->dirbuf[XDIR_NumSec]; nn = fs->dirbuf[XDIR_NumName];
    ldrb r7, [r6, #XDIR_NumSec]
    ldrb r8, [r6, #XDIR_NumName]
    add r0, r6, #XDIR_NameHash              @           nh = ld_16(fs->dirbuf + XDIR_NameHash);
    bl ff16_ld_16
    strh r0, [sp, #RN_NH]
    mov r0, r6                              @           memcpy(fs->dirbuf, buf, SZDIRE * 2);   (old entries ...
    add r1, sp, #RN_BUF
    movs r2, #(SZDIRE * 2)
    bl ff16_mem_cpy
    strb r7, [r6, #XDIR_NumSec]             @           fs->dirbuf[XDIR_NumSec] = nf; fs->dirbuf[XDIR_NumName] = nn;
    strb r8, [r6, #XDIR_NumName]            @           ... with the new name's counts and hash)
    add r0, r6, #XDIR_NameHash              @           st_16(fs->dirbuf + XDIR_NameHash, nh);
    ldrh r1, [sp, #RN_NH]
    bl ff16_st_16
    ldrb r0, [r6, #XDIR_Attr]               @           if (!(fs->dirbuf[XDIR_Attr] & AM_DIR)) fs->dirbuf[XDIR_Attr] |= AM_ARC;
    tst r0, #AM_DIR
    bne 3f
    orr r0, r0, #AM_ARC
    strb r0, [r6, #XDIR_Attr]
3:  add r0, sp, #RN_DJN                     @           res = store_xdir(&djn);
    bl ff16_store_xdir
    mov r5, r0
    b .Lrn_post                             @         }  }  }
.Lrn_fat:                                   @     } else {
    add r0, sp, #RN_BUF                     @       memcpy(buf, djo.dir, SZDIRE);   (save the old entry)
    ldr r1, [sp, #(RN_DJO + DIR_DIR)]
    movs r2, #SZDIRE
    bl ff16_mem_cpy
    add r0, sp, #RN_DJN                     @       memcpy(&djn, &djo, sizeof djn);
    add r1, sp, #RN_DJO
    movs r2, #DIR_SIZE
    bl ff16_mem_cpy
    add r0, sp, #RN_DJN                     @       res = follow_path(&djn, path_new);
    ldr r1, [sp, #RN_NEW]
    bl ff16_follow_path
    mov r5, r0
    cmp r5, #FR_OK                          @       if (res == FR_OK) {
    bne .Lrn_f2
    ldr r0, [sp, #(RN_DJN + OBJ_SCLUST)]    @         res = (djn.obj.sclust == djo.obj.sclust && djn.dptr == djo.dptr) ? FR_NO_FILE : FR_EXIST;
    ldr r1, [sp, #(RN_DJO + OBJ_SCLUST)]
    cmp r0, r1
    bne 4f
    ldr r0, [sp, #(RN_DJN + DIR_DPTR)]
    ldr r1, [sp, #(RN_DJO + DIR_DPTR)]
    cmp r0, r1
    bne 4f
    movs r5, #FR_NO_FILE
    b .Lrn_f2
4:  movs r5, #FR_EXIST
.Lrn_f2:                                    @       }
    cmp r5, #FR_NO_FILE                     @       if (res == FR_NO_FILE) {
    bne .Lrn_post
    add r0, sp, #RN_DJN                     @         res = dir_register(&djn);
    bl ff16_dir_register
    mov r5, r0
    cmp r5, #FR_OK                          @         if (res == FR_OK) {
    bne .Lrn_post
    ldr r6, [sp, #(RN_DJN + DIR_DIR)]       @           dir = djn.dir;
    add r0, r6, #13                         @           memcpy(dir + 13, buf + 13, SZDIRE - 13);   (all but the name and NT byte)
    add r1, sp, #(RN_BUF + 13)
    movs r2, #(SZDIRE - 13)
    bl ff16_mem_cpy
    ldrb r0, [sp, #(RN_BUF + DIR_Attr)]     @           dir[DIR_Attr] = buf[DIR_Attr];
    tst r0, #AM_DIR                         @           if (!(dir[DIR_Attr] & AM_DIR)) dir[DIR_Attr] |= AM_ARC;
    bne 5f
    orr r0, r0, #AM_ARC
5:  strb r0, [r6, #DIR_Attr]
    movs r1, #1                             @           fs->wflag = 1;
    strb r1, [r4, #FS_WFLAG]
    tst r0, #AM_DIR                         @           if ((dir[DIR_Attr] & AM_DIR) && djo.obj.sclust != djn.obj.sclust) {
    beq .Lrn_post
    ldr r0, [sp, #(RN_DJO + OBJ_SCLUST)]
    ldr r1, [sp, #(RN_DJN + OBJ_SCLUST)]
    cmp r0, r1
    beq .Lrn_post
    mov r0, r4                              @             LBA_t sect = clst2sect(fs, ld_clust(fs, dir));
    mov r1, r6
    bl ff16_ld_clust
    mov r1, r0
    mov r0, r4
    bl ff16_clst2sect
    mov r7, r0
    cbnz r7, 6f                             @             if (sect == 0) {
    movs r5, #FR_INT_ERR                    @               res = FR_INT_ERR;
    b .Lrn_post
6:  mov r0, r4                              @             } else { res = move_window(fs, sect);
    mov r1, r7
    bl ff16_move_window
    mov r5, r0
    add r6, r4, #(FS_WIN + SZDIRE * 1)      @               dir = fs->win + SZDIRE * 1;   (the ".." entry)
    cmp r5, #FR_OK                          @               if (res == FR_OK && dir[1] == '.') {
    bne .Lrn_post
    ldrb r0, [r6, #1]
    cmp r0, #0x2E
    bne .Lrn_post
    mov r0, r4                              @                 st_clust(fs, dir, djn.obj.sclust);
    mov r1, r6
    ldr r2, [sp, #(RN_DJN + OBJ_SCLUST)]
    bl ff16_st_clust
    movs r0, #1                             @                 fs->wflag = 1;
    strb r0, [r4, #FS_WFLAG]
.Lrn_post:                                  @     }  (all variants)
    cmp r5, #FR_OK                          @     if (res == FR_OK) {
    bne .Lrn_ret
    add r0, sp, #RN_DJO                     @       res = dir_remove(&djo);   (drop the old entry)
    bl ff16_dir_remove
    mov r5, r0
    cmp r5, #FR_OK                          @       if (res == FR_OK) res = sync_fs(fs);
    bne .Lrn_ret
    mov r0, r4
    bl ff16_sync_fs
    mov r5, r0
.Lrn_ret:
    mov r0, r5                              @ return res;
    add sp, sp, #RN_FRAME
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_f_rename

@ -----------------------------------------------------------------------------
@ f_chmod - change the attribute of a file or directory (ff_x.c f_chmod)
@ In       : r0 = path, r1 = attr, r2 = mask
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 res, r6 attr, r7 mask, r8 dirbuf / dj.dir.   Frame: [sp] DIR dj (80), [sp+80] path, [sp+84] fs
@ -----------------------------------------------------------------------------
    .equ CM_DJ,   0
    .equ CM_PATH, DIR_SIZE
    .equ CM_FS,   DIR_SIZE + 4
    .equ CM_FRAME, DIR_SIZE + 8
FUNC ff16_f_chmod
    push {r4, r5, r6, r7, r8, lr}
    sub sp, sp, #CM_FRAME
    str r0, [sp, #CM_PATH]
    mov r6, r1                              @ r6 = attr
    mov r7, r2                              @ r7 = mask
    add r0, sp, #CM_PATH                    @ res = mount_volume(&path, &fs, FA_WRITE);
    add r1, sp, #CM_FS
    movs r2, #FA_WRITE
    bl ff16_mount_volume
    mov r5, r0
    cmp r5, #FR_OK                          @ if (res == FR_OK) {
    bne .Lcm_ret
    ldr r4, [sp, #CM_FS]
    str r4, [sp, #(CM_DJ + OBJ_FS)]         @   dj.obj.fs = fs;
    add r0, sp, #CM_DJ                      @   res = follow_path(&dj, path);
    ldr r1, [sp, #CM_PATH]
    bl ff16_follow_path
    mov r5, r0
    cmp r5, #FR_OK                          @   if (res == FR_OK && (dj.fn[NSFLAG] & (NS_DOT | NS_NONAME))) res = FR_INVALID_NAME;
    bne .Lcm_c2
    ldrb r0, [sp, #(CM_DJ + DIR_FN + NSFLAG)]
    tst r0, #(NS_DOT | NS_NONAME)
    beq .Lcm_c2
    movs r5, #FR_INVALID_NAME
.Lcm_c2:
    cmp r5, #FR_OK                          @   if (res == FR_OK) {
    bne .Lcm_ret
    and r7, r7, #(AM_RDO | AM_HID | AM_SYS | AM_ARC)   @     mask &= AM_RDO | AM_HID | AM_SYS | AM_ARC;
    ldrb r0, [r4, #FS_FS_TYPE]              @     if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lcm_fat
    ldr r8, [r4, #FS_DIRBUF]                @       fs->dirbuf[XDIR_Attr] = (attr & mask) | (fs->dirbuf[XDIR_Attr] & (BYTE)~mask);
    and r0, r6, r7
    ldrb r1, [r8, #XDIR_Attr]
    bic r1, r1, r7
    orr r0, r0, r1
    strb r0, [r8, #XDIR_Attr]
    add r0, sp, #CM_DJ                      @       res = store_xdir(&dj);
    bl ff16_store_xdir
    mov r5, r0
    b .Lcm_sync
.Lcm_fat:                                   @     } else {
    ldr r8, [sp, #(CM_DJ + DIR_DIR)]        @       dj.dir[DIR_Attr] = (attr & mask) | (dj.dir[DIR_Attr] & (BYTE)~mask);
    and r0, r6, r7
    ldrb r1, [r8, #DIR_Attr]
    bic r1, r1, r7
    orr r0, r0, r1
    strb r0, [r8, #DIR_Attr]
    movs r0, #1                             @       fs->wflag = 1;
    strb r0, [r4, #FS_WFLAG]
.Lcm_sync:                                  @     }
    cmp r5, #FR_OK                          @     if (res == FR_OK) res = sync_fs(fs);
    bne .Lcm_ret
    mov r0, r4
    bl ff16_sync_fs
    mov r5, r0
.Lcm_ret:
    mov r0, r5                              @ return res;
    add sp, sp, #CM_FRAME
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_f_chmod

@ -----------------------------------------------------------------------------
@ f_utime - change the timestamp of a file or directory (ff_x.c f_utime)
@ In       : r0 = path, r1 = fno (const FILINFO*; fdate / ftime are used)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 res, r6 fno, r7 dirbuf / dj.dir.   Frame: [sp] DIR dj (80), [sp+80] path, [sp+84] fs
@ -----------------------------------------------------------------------------
    .equ UT_DJ,   0
    .equ UT_PATH, DIR_SIZE
    .equ UT_FS,   DIR_SIZE + 4
    .equ UT_FRAME, DIR_SIZE + 8
FUNC ff16_f_utime
    push {r4, r5, r6, r7, r8, lr}
    sub sp, sp, #UT_FRAME
    str r0, [sp, #UT_PATH]
    mov r6, r1                              @ r6 = fno
    add r0, sp, #UT_PATH                    @ res = mount_volume(&path, &fs, FA_WRITE);
    add r1, sp, #UT_FS
    movs r2, #FA_WRITE
    bl ff16_mount_volume
    mov r5, r0
    cmp r5, #FR_OK                          @ if (res == FR_OK) {
    bne .Lut_ret
    ldr r4, [sp, #UT_FS]
    str r4, [sp, #(UT_DJ + OBJ_FS)]         @   dj.obj.fs = fs;
    add r0, sp, #UT_DJ                      @   res = follow_path(&dj, path);
    ldr r1, [sp, #UT_PATH]
    bl ff16_follow_path
    mov r5, r0
    cmp r5, #FR_OK                          @   if (res == FR_OK && (dj.fn[NSFLAG] & (NS_DOT | NS_NONAME))) res = FR_INVALID_NAME;
    bne .Lut_c2
    ldrb r0, [sp, #(UT_DJ + DIR_FN + NSFLAG)]
    tst r0, #(NS_DOT | NS_NONAME)
    beq .Lut_c2
    movs r5, #FR_INVALID_NAME
.Lut_c2:
    cmp r5, #FR_OK                          @   if (res == FR_OK) {
    bne .Lut_ret
    ldrb r0, [r4, #FS_FS_TYPE]              @     if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lut_fat
    ldrh r0, [r6, #FNO_FDATE]               @       if (fno->fdate) {
    cbz r0, .Lut_xstore
    ldrh r1, [r6, #FNO_FTIME]               @         st_32(fs->dirbuf + XDIR_ModTime, (DWORD)fno->fdate << 16 | fno->ftime);
    orr r1, r1, r0, lsl #16
    ldr r7, [r4, #FS_DIRBUF]
    add r0, r7, #XDIR_ModTime
    bl ff16_st_32
    movs r0, #0                             @         fs->dirbuf[XDIR_ModTime10] = 0; fs->dirbuf[XDIR_ModTZ] = 0;
    strb r0, [r7, #XDIR_ModTime10]
    strb r0, [r7, #XDIR_ModTZ]
.Lut_xstore:                                @       }
    add r0, sp, #UT_DJ                      @       res = store_xdir(&dj);
    bl ff16_store_xdir
    mov r5, r0
    b .Lut_sync
.Lut_fat:                                   @     } else {
    ldrh r0, [r6, #FNO_FDATE]               @       if (fno->fdate) {
    cbz r0, .Lut_wf
    ldrh r1, [r6, #FNO_FTIME]               @         st_32(dj.dir + DIR_ModTime, (DWORD)fno->fdate << 16 | fno->ftime);
    orr r1, r1, r0, lsl #16
    ldr r7, [sp, #(UT_DJ + DIR_DIR)]
    add r0, r7, #DIR_ModTime
    bl ff16_st_32
.Lut_wf:                                    @       }
    movs r0, #1                             @       fs->wflag = 1;
    strb r0, [r4, #FS_WFLAG]
.Lut_sync:                                  @     }
    cmp r5, #FR_OK                          @     if (res == FR_OK) res = sync_fs(fs);
    bne .Lut_ret
    mov r0, r4
    bl ff16_sync_fs
    mov r5, r0
.Lut_ret:
    mov r0, r5                              @ return res;
    add sp, sp, #UT_FRAME
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_f_utime

    .endif                                  @ FF_FS_READONLY == 0
