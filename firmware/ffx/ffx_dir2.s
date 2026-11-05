@ =============================================================================
@ ffx_dir2.s - FatFs R0.16 w/patch 2, exFAT configuration: directory read, find, register, remove, FILINFO, names, path
@ (group C)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c), configuration of ff_x.c (FF_FS_EXFAT 1, FF_USE_LFN 1 with a
@ static working buffer, FF_LFN_UNICODE 0, FF_CODE_PAGE 437, FF_FS_RPATH 0, FF_FS_CRTIME 0):
@   dir_read, dir_find, dir_register, dir_remove, get_fileinfo, create_name, follow_path.
@ There is no get_xfileinfo in ff_x.c (exFAT file information is built inside get_fileinfo); these seven are all.
@ Each routine names the C function it translates; the code follows the C statements in order, the comments quote them.
@ Calling convention AAPCS (r0-r3, r12 scratch, r4-r11 preserved, stack 8-byte aligned at calls); 64-bit values in a
@ register pair (ld_64 result r0:r1, st_64 value r2:r3).  Routines of other groups are called by their ff16_ names.
@
@ FF_FS_READONLY: dir_register and dir_remove do not exist in ff_xro.c and are assembled only when FF_FS_READONLY == 0.
@ The other five routines are identical in ff_x.c and ff_xro.c.
@
@ FatFs license (ChaN): "FatFs module is an open source software. Redistribution and use of FatFs in source and binary forms,
@ with or without modification, are permitted provided that the following condition is met: 1. Redistributions of source
@ code must retain the above copyright notice, this condition and the following disclaimer.  This software is provided by
@ the copyright holder and contributors "AS IS" and any warranties related to this software are DISCLAIMED.  The copyright
@ owner or contributors be NOT LIABLE for any damages caused by use of this software."  Copyright (C) 2025, ChaN, all right
@ reserved.
@
@ Structure offsets and constants: ff16x.inc.  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ff16x.inc"

@ constants not in ff16x.inc
    .equ DIRBUF_SIZE, 608                   @ sizeof DirBuf: MAXDIRB(FF_MAX_LFN) = (255 + 44) / 15 * SZDIRE (ff.c line 522)
    .equ OBJ_STAT_STRETCH, 4                @ FFOBJID.stat bit 2: exFAT sub-directory stretched (ff.h line 199, ff.c line 1798)
    .equ CN_BAD1_LEN, 8                     @ bytes in .Lcn_bad1 (create_name table below)
    .equ CN_BAD2_LEN, 6                     @ bytes in .Lcn_bad2

    .section .text.ff16x.dir2, "ax", %progbits

@ -----------------------------------------------------------------------------
@ dir_read - read the next valid entry of the directory (ff.c dir_read)
@ In       : r0 = dp, r1 = vol (0: a file or directory entry, 1: the volume label; ignored for exFAT: "0 && vol")
@ Out      : r0 = FRESULT (FR_NO_FILE at the end of the table; dp->sect = 0 on any failure)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 vol, r7 res, r8 ord, r9 sum, r10 et
@ -----------------------------------------------------------------------------
FUNC ff16_dir_read
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    mov r6, r1
    movs r7, #FR_NO_FILE                    @ FRESULT res = FR_NO_FILE;
    movs r8, #0xFF                          @ BYTE ord = 0xFF,
    movs r9, #0xFF                          @      sum = 0xFF;
.Ldr_loop:
    ldr r1, [r4, #DIR_SECT]                 @ while (dp->sect) {
    cmp r1, #0
    beq .Ldr_end
    mov r0, r5
    bl ff16_move_window                     @   res = move_window(fs, dp->sect);
    mov r7, r0
    cmp r7, #FR_OK                          @   if (res != FR_OK) break;
    bne .Ldr_end
    ldr r3, [r4, #DIR_DIR]
    ldrb r10, [r3, #DIR_Name]               @   et = dp->dir[XDIR_Type];
    cmp r10, #0                             @   if (et == 0) { res = FR_NO_FILE; break; }
    bne 1f
    movs r7, #FR_NO_FILE
    b .Ldr_end
1:  ldrb r0, [r5, #FS_FS_TYPE]              @   if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Ldr_fat
    cmp r10, #ET_FILEDIR                    @     (if (0 && vol) is compiled out) if (et == ET_FILEDIR) {
    bne .Ldr_next
    ldr r0, [r4, #DIR_DPTR]
    str r0, [r4, #DIR_BLK_OFS]              @       dp->blk_ofs = dp->dptr;
    mov r0, r4
    bl ff16_load_xdir                       @       res = load_xdir(dp);
    mov r7, r0
    cmp r7, #FR_OK                          @       if (res == FR_OK) {
    bne .Ldr_end
    ldr r1, [r5, #FS_DIRBUF]
    ldrb r1, [r1, #XDIR_Attr]
    and r1, r1, #AM_MASK
    strb r1, [r4, #OBJ_ATTR]                @         dp->obj.attr = fs->dirbuf[XDIR_Attr] & AM_MASK; }
    b .Ldr_end                              @       break; }
.Ldr_fat:                                   @   } else {
    ldrb r0, [r3, #DIR_Attr]
    and r0, r0, #AM_MASK                    @     attr = dp->dir[DIR_Attr] & AM_MASK;
    strb r0, [r4, #OBJ_ATTR]                @     dp->obj.attr = attr;
    cmp r10, #DDEM                          @     if (et == DDEM || et == '.' || (int)((attr & ~AM_ARC) == AM_VOL) != vol) {
    beq .Ldr_ordff
    cmp r10, #'.'
    beq .Ldr_ordff
    bic r1, r0, #AM_ARC
    cmp r1, #AM_VOL
    ite eq
    moveq r1, #1
    movne r1, #0
    cmp r1, r6
    bne .Ldr_ordff                          @       ord = 0xFF;
    cmp r0, #AM_LFN                         @     } else { if (attr == AM_LFN) {
    bne .Ldr_sfn
    tst r10, #LLEF                          @       if (et & LLEF) {
    beq 2f
    ldrb r9, [r3, #LDIR_Chksum]             @         sum = dp->dir[LDIR_Chksum];
    bic r10, r10, #LLEF                     @         et &= (BYTE)~LLEF;
    mov r8, r10                             @         ord = et;
    ldr r1, [r4, #DIR_DPTR]
    str r1, [r4, #DIR_BLK_OFS]              @         dp->blk_ofs = dp->dptr; }
2:  cmp r10, r8                             @       ord = (et == ord && sum == dp->dir[LDIR_Chksum]
    bne .Ldr_ordff
    ldrb r0, [r3, #LDIR_Chksum]
    cmp r9, r0
    bne .Ldr_ordff
    ldr r0, [r5, #FS_LFNBUF]                @             && pick_lfn(fs->lfnbuf, dp->dir)) ? ord - 1 : 0xFF;
    mov r1, r3
    bl ff16_pick_lfn
    cmp r0, #0
    beq .Ldr_ordff
    subs r8, r8, #1                         @       (BYTE) ord - 1
    uxtb r8, r8
    b .Ldr_next
.Ldr_sfn:                                   @     } else {
    cmp r8, #0                              @       if (ord != 0 || sum != sum_sfn(dp->dir)) dp->blk_ofs = 0xFFFFFFFF;
    bne 3f
    mov r0, r3
    bl ff16_sum_sfn
    uxtb r0, r0
    cmp r0, r9
    beq .Ldr_end                            @       break; (sum matches: blk_ofs kept)
3:  mvn r0, #0
    str r0, [r4, #DIR_BLK_OFS]
    b .Ldr_end                              @       break; } } }
.Ldr_ordff:
    movs r8, #0xFF                          @ ord = 0xFF;
.Ldr_next:
    mov r0, r4
    movs r1, #0
    bl ff16_dir_next                        @   res = dir_next(dp, 0);
    mov r7, r0
    cmp r7, #FR_OK                          @   if (res != FR_OK) break; }
    beq .Ldr_loop
.Ldr_end:
    cmp r7, #FR_OK                          @ if (res != FR_OK) dp->sect = 0;
    beq 4f
    movs r0, #0
    str r0, [r4, #DIR_SECT]
4:  mov r0, r7                              @ return res;
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_dir_read

@ -----------------------------------------------------------------------------
@ dir_find - find the entry named by the name in dp->fn / the long name in fs->lfnbuf (ff.c dir_find)
@ In       : r0 = dp
@ Out      : r0 = FRESULT (FR_OK: dp points at the entry; FR_NO_FILE: not found)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 hash (exFAT) / et (FAT), r7 nc (exFAT) / ord (FAT), r8 di (exFAT) / sum (FAT),
@            r9 ni, r10 scratch (exFAT) / dp->dir (FAT)
@ -----------------------------------------------------------------------------
FUNC ff16_dir_find
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    movs r1, #0
    bl ff16_dir_sdi                         @ res = dir_sdi(dp, 0);
    cmp r0, #FR_OK                          @ if (res != FR_OK) return res;
    bne .Ldf_ret
    ldrb r0, [r5, #FS_FS_TYPE]              @ if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Ldf_fat
    ldr r0, [r5, #FS_LFNBUF]
    bl ff16_xname_sum                       @   hash = xname_sum(fs->lfnbuf);
    uxth r6, r0
.Ldf_xread:
    mov r0, r4                              @   while ((res = dir_read(dp, 0)) == FR_OK) {
    movs r1, #0
    bl ff16_dir_read
    cmp r0, #FR_OK
    bne .Ldf_ret                            @   (loop ends; return res)
    ldr r0, [r5, #FS_DIRBUF]
    adds r0, r0, #XDIR_NameHash
    bl ff16_ld_16
    uxth r0, r0
    cmp r0, r6                              @     if (ld_16(fs->dirbuf + XDIR_NameHash) != hash) continue;
    bne .Ldf_xread
    ldr r1, [r5, #FS_DIRBUF]
    ldrb r7, [r1, #XDIR_NumName]            @     for (nc = fs->dirbuf[XDIR_NumName],
    movs r8, #(SZDIRE * 2)                  @          di = SZDIRE * 2,
    movs r9, #0                             @          ni = 0; nc; nc--, di += 2, ni++) {
.Ldf_xcmp:
    cmp r7, #0
    beq .Ldf_xdone
    tst r8, #(SZDIRE - 1)                   @       if ((di % SZDIRE) == 0) di += 2;
    bne 1f
    adds r8, r8, #2
1:  ldr r0, [r5, #FS_DIRBUF]                @       if (ff_wtoupper(ld_16(fs->dirbuf + di))
    add r0, r0, r8
    bl ff16_ld_16
    uxth r0, r0
    bl ff16_ff_wtoupper
    mov r10, r0
    ldr r1, [r5, #FS_LFNBUF]                @           != ff_wtoupper(fs->lfnbuf[ni])) break;
    ldrh r0, [r1, r9, lsl #1]
    bl ff16_ff_wtoupper
    cmp r0, r10
    bne .Ldf_xdone
    subs r7, r7, #1                         @       } (nc--, di += 2, ni++)
    adds r8, r8, #2
    adds r9, r9, #1
    b .Ldf_xcmp
.Ldf_xdone:
    cmp r7, #0                              @     if (nc == 0 && !fs->lfnbuf[ni]) break; }
    bne .Ldf_xread
    ldr r1, [r5, #FS_LFNBUF]
    ldrh r0, [r1, r9, lsl #1]
    cmp r0, #0
    bne .Ldf_xread
    movs r0, #FR_OK                         @   return res;   (res == FR_OK)
    b .Ldf_ret
.Ldf_fat:                                   @ }
    movs r7, #0xFF                          @ ord = sum = 0xFF;
    movs r8, #0xFF
    mvn r0, #0
    str r0, [r4, #DIR_BLK_OFS]              @ dp->blk_ofs = 0xFFFFFFFF;
.Ldf_loop:                                  @ do {
    mov r0, r5
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @   res = move_window(fs, dp->sect);
    cmp r0, #FR_OK                          @   if (res != FR_OK) break;
    bne .Ldf_ret
    ldr r10, [r4, #DIR_DIR]
    ldrb r6, [r10, #DIR_Name]               @   et = dp->dir[DIR_Name];
    cmp r6, #0                              @   if (et == 0) { res = FR_NO_FILE; break; }
    bne 2f
    movs r0, #FR_NO_FILE
    b .Ldf_ret
2:  ldrb r0, [r10, #DIR_Attr]
    and r0, r0, #AM_MASK                    @   attr = dp->dir[DIR_Attr] & AM_MASK;
    strb r0, [r4, #OBJ_ATTR]                @   dp->obj.attr = attr;
    cmp r6, #DDEM                           @   if (et == DDEM || ((attr & AM_VOL) && attr != AM_LFN)) {
    beq .Ldf_inv                            @     ord = 0xFF; dp->blk_ofs = 0xFFFFFFFF;
    tst r0, #AM_VOL
    beq 3f
    cmp r0, #AM_LFN
    bne .Ldf_inv
3:  cmp r0, #AM_LFN                         @   } else { if (attr == AM_LFN) {
    bne .Ldf_sfn
    ldrb r1, [r4, #(DIR_FN + NSFLAG)]       @     if (!(dp->fn[NSFLAG] & NS_NOLFN)) {
    tst r1, #NS_NOLFN
    bne .Ldf_next
    tst r6, #LLEF                           @       if (et & LLEF) {
    beq 4f
    bic r6, r6, #LLEF                       @         et &= (BYTE)~LLEF;
    mov r7, r6                              @         ord = et;
    ldr r1, [r4, #DIR_DPTR]
    str r1, [r4, #DIR_BLK_OFS]              @         dp->blk_ofs = dp->dptr;
    ldrb r8, [r10, #LDIR_Chksum]            @         sum = dp->dir[LDIR_Chksum]; }
4:  cmp r6, r7                              @       ord = (et == ord && sum == dp->dir[LDIR_Chksum]
    bne .Ldf_ordff
    ldrb r0, [r10, #LDIR_Chksum]
    cmp r8, r0
    bne .Ldf_ordff
    ldr r0, [r5, #FS_LFNBUF]                @             && cmp_lfn(fs->lfnbuf, dp->dir)) ? ord - 1 : 0xFF; } }
    mov r1, r10
    bl ff16_cmp_lfn
    cmp r0, #0
    beq .Ldf_ordff
    subs r7, r7, #1                         @       (BYTE) ord - 1
    uxtb r7, r7
    b .Ldf_next
.Ldf_sfn:                                   @   } else {
    cmp r7, #0                              @     if (ord == 0 && sum == sum_sfn(dp->dir)) break;
    bne 5f
    mov r0, r10
    bl ff16_sum_sfn
    uxtb r0, r0
    cmp r0, r8
    beq .Ldf_found
5:  ldrb r1, [r4, #(DIR_FN + NSFLAG)]       @     if (!(dp->fn[NSFLAG] & NS_LOSS)
    tst r1, #NS_LOSS
    bne .Ldf_inv
    mov r0, r10                             @         && !memcmp(dp->dir, dp->fn, 11)) break;
    add r1, r4, #DIR_FN
    movs r2, #11
    bl ff16_mem_cmp
    cmp r0, #0
    beq .Ldf_found
.Ldf_inv:
    movs r7, #0xFF                          @     ord = 0xFF;
    mvn r0, #0
    str r0, [r4, #DIR_BLK_OFS]              @     dp->blk_ofs = 0xFFFFFFFF; } }
    b .Ldf_next
.Ldf_ordff:
    movs r7, #0xFF                          @ ord = 0xFF (LFN entry did not match)
.Ldf_next:
    mov r0, r4
    movs r1, #0
    bl ff16_dir_next                        @   res = dir_next(dp, 0);
    cmp r0, #FR_OK
    beq .Ldf_loop                           @ } while (res == FR_OK);
    b .Ldf_ret                              @ return res;
.Ldf_found:
    movs r0, #FR_OK
.Ldf_ret:
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_dir_find

.if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ dir_register - register an object in the directory (ff.c dir_register)
@ In       : r0 = dp (dp->fn and fs->lfnbuf hold the name made by create_name)
@ Out      : r0 = FRESULT (FR_INVALID_NAME, FR_DENIED, FR_DISK_ERR, ...)
@ Clobbers : r1-r3, r12, flags
@ Frame    : [sp+0..79] DIR dj (exFAT), [sp+80..91] BYTE sn[12], [sp+92..95] pad
@ Registers: r4 dp, r5 fs, r6 len, r7 n_ent, r8 res, r9 n, r10 sum
@ -----------------------------------------------------------------------------
FUNC ff16_dir_register
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    sub sp, sp, #96
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    ldrb r0, [r4, #(DIR_FN + NSFLAG)]       @ if (dp->fn[NSFLAG] & (NS_DOT | NS_NONAME)) return FR_INVALID_NAME;
    tst r0, #(NS_DOT | NS_NONAME)
    beq 1f
    movs r0, #FR_INVALID_NAME
    b .Lreg_ret
1:  ldr r1, [r5, #FS_LFNBUF]
    movs r6, #0                             @ for (len = 0; fs->lfnbuf[len]; len++) ;
2:  ldrh r0, [r1, r6, lsl #1]
    cmp r0, #0
    beq 3f
    adds r6, r6, #1
    b 2b
3:  ldrb r0, [r5, #FS_FS_TYPE]              @ if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lreg_fat
    adds r0, r6, #14                        @   n_ent = (len + 14) / 15 + 2;
    movs r1, #15
    udiv r0, r0, r1
    adds r7, r0, #2
    mov r0, r4
    mov r1, r7
    bl ff16_dir_alloc                       @   res = dir_alloc(dp, n_ent);
    cmp r0, #FR_OK                          @   if (res != FR_OK) return res;
    bne .Lreg_ret
    subs r0, r7, #1                         @   dp->blk_ofs = dp->dptr - SZDIRE * (n_ent - 1);
    lsls r0, r0, #5
    ldr r1, [r4, #DIR_DPTR]
    subs r1, r1, r0
    str r1, [r4, #DIR_BLK_OFS]
    ldrb r0, [r4, #OBJ_STAT]                @   if (dp->obj.stat & 4) {
    tst r0, #OBJ_STAT_STRETCH
    beq .Lreg_xcreate
    bic r0, r0, #OBJ_STAT_STRETCH           @     dp->obj.stat &= ~4;
    strb r0, [r4, #OBJ_STAT]
    mov r0, r4
    bl ff16_fill_first_frag                 @     res = fill_first_frag(&dp->obj);
    cmp r0, #FR_OK                          @     if (res != FR_OK) return res;
    bne .Lreg_ret
    mov r0, r4
    ldr r1, [r4, #DIR_CLUST]
    mvn r2, #0
    bl ff16_fill_last_frag                  @     res = fill_last_frag(&dp->obj, dp->clust, 0xFFFFFFFF);
    cmp r0, #FR_OK                          @     if (res != FR_OK) return res;
    bne .Lreg_ret
    ldr r0, [r4, #OBJ_SCLUST]               @     if (dp->obj.sclust != 0) {
    cmp r0, #0
    beq .Lreg_xcreate
    mov r0, sp                              @       DIR dj;  res = load_obj_xdir(&dj, &dp->obj);
    mov r1, r4
    bl ff16_load_obj_xdir
    cmp r0, #FR_OK                          @       if (res != FR_OK) return res;
    bne .Lreg_ret
    ldrh r0, [r5, #FS_CSIZE]                @       dp->obj.objsize += (DWORD)fs->csize * SS(fs);   (SS = 512)
    lsls r0, r0, #9
    ldrd r2, r3, [r4, #OBJ_OBJSIZE]
    adds r2, r2, r0
    adc r3, r3, #0
    strd r2, r3, [r4, #OBJ_OBJSIZE]
    ldr r0, [r5, #FS_DIRBUF]                @       st_64(fs->dirbuf + XDIR_FileSize, dp->obj.objsize);
    adds r0, r0, #XDIR_FileSize
    bl ff16_st_64                           @       (value in r2:r3, still the new objsize)
    ldrd r2, r3, [r4, #OBJ_OBJSIZE]
    ldr r0, [r5, #FS_DIRBUF]                @       st_64(fs->dirbuf + XDIR_ValidFileSize, dp->obj.objsize);
    adds r0, r0, #XDIR_ValidFileSize
    bl ff16_st_64
    ldrb r0, [r4, #OBJ_STAT]                @       fs->dirbuf[XDIR_GenFlags] = dp->obj.stat | 1;
    orr r0, r0, #1
    ldr r1, [r5, #FS_DIRBUF]
    strb r0, [r1, #XDIR_GenFlags]
    mov r0, sp
    bl ff16_store_xdir                      @       res = store_xdir(&dj);
    cmp r0, #FR_OK                          @       if (res != FR_OK) return res; } }
    bne .Lreg_ret
.Lreg_xcreate:
    ldr r0, [r5, #FS_DIRBUF]
    ldr r1, [r5, #FS_LFNBUF]
    bl ff16_create_xdir                     @   create_xdir(fs->dirbuf, fs->lfnbuf);
    movs r0, #FR_OK                         @   return FR_OK; }
    b .Lreg_ret
.Lreg_fat:
    add r0, sp, #80                         @ memcpy(sn, dp->fn, 12);
    add r1, r4, #DIR_FN
    movs r2, #12
    bl ff16_mem_cpy
    ldrb r0, [sp, #(80 + NSFLAG)]           @ if (sn[NSFLAG] & NS_LOSS) {
    tst r0, #NS_LOSS
    beq .Lreg_nol
    movs r0, #NS_NOLFN                      @   dp->fn[NSFLAG] = NS_NOLFN;
    strb r0, [r4, #(DIR_FN + NSFLAG)]
    movs r9, #1                             @   for (n = 1; n < 100; n++) {
.Lreg_gen:
    add r0, r4, #DIR_FN                     @     gen_numname(dp->fn, sn, fs->lfnbuf, (WORD)n);
    add r1, sp, #80
    ldr r2, [r5, #FS_LFNBUF]
    uxth r3, r9
    bl ff16_gen_numname
    mov r0, r4
    bl ff16_dir_find                        @     res = dir_find(dp);
    mov r8, r0
    cmp r8, #FR_OK                          @     if (res != FR_OK) break; }
    bne .Lreg_genx
    adds r9, r9, #1
    cmp r9, #100
    blo .Lreg_gen
.Lreg_genx:
    cmp r9, #100                            @   if (n == 100) return FR_DENIED;
    bne 4f
    movs r0, #FR_DENIED
    b .Lreg_ret
4:  cmp r8, #FR_NO_FILE                     @   if (res != FR_NO_FILE) return res;
    beq 5f
    mov r0, r8
    b .Lreg_ret
5:  ldrb r0, [sp, #(80 + NSFLAG)]           @   dp->fn[NSFLAG] = sn[NSFLAG]; }
    strb r0, [r4, #(DIR_FN + NSFLAG)]
.Lreg_nol:
    ldrb r0, [sp, #(80 + NSFLAG)]           @ n_ent = (sn[NSFLAG] & NS_LFN) ? (len + 12) / 13 + 1 : 1;
    tst r0, #NS_LFN
    beq 6f
    adds r0, r6, #12
    movs r1, #13
    udiv r0, r0, r1
    adds r7, r0, #1
    b 7f
6:  movs r7, #1
7:  mov r0, r4
    mov r1, r7
    bl ff16_dir_alloc                       @ res = dir_alloc(dp, n_ent);
    mov r8, r0
    cmp r8, #FR_OK                          @ if (res == FR_OK && --n_ent) {
    bne .Lreg_chk
    subs r7, r7, #1
    beq .Lreg_chk
    ldr r1, [r4, #DIR_DPTR]                 @   res = dir_sdi(dp, dp->dptr - n_ent * SZDIRE);
    sub r1, r1, r7, lsl #5
    mov r0, r4
    bl ff16_dir_sdi
    mov r8, r0
    cmp r8, #FR_OK                          @   if (res == FR_OK) {
    bne .Lreg_chk
    add r0, r4, #DIR_FN                     @     BYTE sum = sum_sfn(dp->fn);
    bl ff16_sum_sfn
    uxtb r10, r0
.Lreg_lfn:                                  @     do {
    mov r0, r5
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @       res = move_window(fs, dp->sect);
    mov r8, r0
    cmp r8, #FR_OK                          @       if (res != FR_OK) break;
    bne .Lreg_chk
    ldr r0, [r5, #FS_LFNBUF]                @       put_lfn(fs->lfnbuf, dp->dir, (BYTE)n_ent, sum);
    ldr r1, [r4, #DIR_DIR]
    uxtb r2, r7
    mov r3, r10
    bl ff16_put_lfn
    movs r0, #1                             @       fs->wflag = 1;
    strb r0, [r5, #FS_WFLAG]
    mov r0, r4
    movs r1, #0
    bl ff16_dir_next                        @       res = dir_next(dp, 0);
    mov r8, r0
    cmp r8, #FR_OK                          @     } while (res == FR_OK && --n_ent); } }
    bne .Lreg_chk
    subs r7, r7, #1
    bne .Lreg_lfn
.Lreg_chk:
    cmp r8, #FR_OK                          @ if (res == FR_OK) {
    bne .Lreg_res
    mov r0, r5
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @   res = move_window(fs, dp->sect);
    mov r8, r0
    cmp r8, #FR_OK                          @   if (res == FR_OK) {
    bne .Lreg_res
    ldr r6, [r4, #DIR_DIR]
    mov r0, r6                              @     memset(dp->dir, 0, SZDIRE);
    movs r1, #0
    movs r2, #SZDIRE
    bl ff16_mem_set
    mov r0, r6                              @     memcpy(dp->dir + DIR_Name, dp->fn, 11);
    add r1, r4, #DIR_FN
    movs r2, #11
    bl ff16_mem_cpy
    ldrb r0, [r4, #(DIR_FN + NSFLAG)]       @     dp->dir[DIR_NTres] = dp->fn[NSFLAG] & (NS_BODY | NS_EXT);
    and r0, r0, #(NS_BODY | NS_EXT)
    strb r0, [r6, #DIR_NTres]
    movs r0, #1                             @     fs->wflag = 1; } }
    strb r0, [r5, #FS_WFLAG]
.Lreg_res:
    mov r0, r8                              @ return res;
.Lreg_ret:
    add sp, sp, #96
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_dir_register

@ -----------------------------------------------------------------------------
@ dir_remove - remove an object from the directory (ff.c dir_remove)
@ In       : r0 = dp (dp->blk_ofs is the start of the entry block, dp->dptr the SFN / file entry)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 last, r7 res
@ -----------------------------------------------------------------------------
FUNC ff16_dir_remove
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    ldr r6, [r4, #DIR_DPTR]                 @ DWORD last = dp->dptr;
    ldr r1, [r4, #DIR_BLK_OFS]              @ res = (dp->blk_ofs == 0xFFFFFFFF) ? FR_OK : dir_sdi(dp, dp->blk_ofs);
    cmn r1, #1
    bne 1f
    movs r7, #FR_OK
    b 2f
1:  mov r0, r4
    bl ff16_dir_sdi
    mov r7, r0
2:  cmp r7, #FR_OK                          @ if (res == FR_OK) {
    bne .Lrm_end
.Lrm_loop:                                  @   do {
    mov r0, r5
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @     res = move_window(fs, dp->sect);
    mov r7, r0
    cmp r7, #FR_OK                          @     if (res != FR_OK) break;
    bne .Lrm_after
    ldr r1, [r4, #DIR_DIR]
    ldrb r0, [r5, #FS_FS_TYPE]              @     if (1 && fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne 3f
    ldrb r2, [r1, #0]                       @       dp->dir[XDIR_Type] &= 0x7F;   (clear the "in use" bit)
    and r2, r2, #0x7F
    b 4f
3:  movs r2, #DDEM                          @     } else { dp->dir[DIR_Name] = DDEM; }
4:  strb r2, [r1, #0]
    movs r0, #1                             @     fs->wflag = 1;
    strb r0, [r5, #FS_WFLAG]
    ldr r0, [r4, #DIR_DPTR]                 @     if (dp->dptr >= last) break;
    cmp r0, r6
    bhs .Lrm_after
    mov r0, r4
    movs r1, #0
    bl ff16_dir_next                        @     res = dir_next(dp, 0);
    mov r7, r0
    cmp r7, #FR_OK                          @   } while (res == FR_OK);
    beq .Lrm_loop
.Lrm_after:
    cmp r7, #FR_NO_FILE                     @   if (res == FR_NO_FILE) res = FR_INT_ERR; }
    bne .Lrm_end
    movs r7, #FR_INT_ERR
.Lrm_end:
    mov r0, r7                              @ return res;
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_dir_remove
.endif

@ -----------------------------------------------------------------------------
@ get_fileinfo - fill a FILINFO from the current directory entry (ff.c get_fileinfo)
@ In       : r0 = dp, r1 = fno
@ Out      : none (fno->fname[0] = 0 when dp->sect == 0)
@ Clobbers : r0-r3, r12, flags
@ Registers: r4 dp, r5 fno, r6 fs, r7 si, r8 di, r9 hs (exFAT/LFN) / dp->dir (SFN), r10 nc (exFAT) / lcflg
@ -----------------------------------------------------------------------------
FUNC ff16_get_fileinfo
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    mov r4, r0
    mov r5, r1
    ldr r6, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    movs r0, #0
    strb r0, [r5, #FNO_FNAME]               @ fno->fname[0] = 0;
    ldr r0, [r4, #DIR_SECT]                 @ if (dp->sect == 0) return;
    cmp r0, #0
    beq .Lgf_ret
    ldrb r0, [r6, #FS_FS_TYPE]              @ if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lgf_fat
    movs r10, #0                            @   UINT nc = 0;
    movs r7, #(SZDIRE * 2)                  @   si = SZDIRE * 2;
    movs r8, #0                             @   di = 0;
    movs r9, #0                             @   hs = 0;
.Lgf_xl:
    ldr r1, [r6, #FS_DIRBUF]                @   while (nc < fs->dirbuf[XDIR_NumName]) {
    ldrb r0, [r1, #XDIR_NumName]
    cmp r10, r0
    bhs .Lgf_xend
    cmp r7, #DIRBUF_SIZE                    @     if (si >= MAXDIRB(FF_MAX_LFN)) { di = 0; break; }
    blo 1f
    movs r8, #0
    b .Lgf_xend
1:  tst r7, #(SZDIRE - 1)                   @     if ((si % SZDIRE) == 0) si += 2;
    bne 2f
    adds r7, r7, #2
2:  ldr r0, [r6, #FS_DIRBUF]                @     wc = ld_16(fs->dirbuf + si); si += 2; nc++;
    add r0, r0, r7
    bl ff16_ld_16
    uxth r3, r0
    adds r7, r7, #2
    adds r10, r10, #1
    cmp r9, #0                              @     if (hs == 0 && IsSurrogate(wc)) { hs = wc; continue; }
    bne 3f
    sub r0, r3, #0xD800
    cmp r0, #0x800
    bhs 3f
    mov r9, r3
    b .Lgf_xl
3:  orr r0, r3, r9, lsl #16                 @     nw = put_utf((DWORD)hs << 16 | wc, &fno->fname[di], FF_LFN_BUF - di);
    add r1, r5, #FNO_FNAME
    add r1, r1, r8
    rsb r2, r8, #255
    bl ff16_put_utf
    cmp r0, #0                              @     if (nw == 0) { di = 0; break; }
    bne 4f
    movs r8, #0
    b .Lgf_xend
4:  add r8, r8, r0                          @     di += nw; hs = 0; }
    movs r9, #0
    b .Lgf_xl
.Lgf_xend:
    cmp r9, #0                              @   if (hs != 0) di = 0;
    it ne
    movne r8, #0
    cmp r8, #0                              @   if (di == 0) fno->fname[di++] = '?';
    bne 5f
    add r1, r5, r8
    movs r0, #'?'
    strb r0, [r1, #FNO_FNAME]
    adds r8, r8, #1
5:  add r1, r5, r8                          @   fno->fname[di] = 0;
    movs r0, #0
    strb r0, [r1, #FNO_FNAME]
    strb r0, [r5, #FNO_ALTNAME]             @   fno->altname[0] = 0;
    ldr r7, [r6, #FS_DIRBUF]
    ldrb r0, [r7, #XDIR_Attr]               @   fno->fattrib = fs->dirbuf[XDIR_Attr] & AM_MASKX;
    and r0, r0, #AM_MASKX
    strb r0, [r5, #FNO_FATTRIB]
    tst r0, #AM_DIR                         @   fno->fsize = (fno->fattrib & AM_DIR) ? 0 : ld_64(fs->dirbuf + XDIR_FileSize);
    beq 6f
    movs r0, #0
    movs r1, #0
    b 7f
6:  add r0, r7, #XDIR_FileSize
    bl ff16_ld_64
7:  strd r0, r1, [r5, #FNO_FSIZE]
    add r0, r7, #XDIR_ModTime               @   fno->ftime = ld_16(fs->dirbuf + XDIR_ModTime + 0);
    bl ff16_ld_16
    strh r0, [r5, #FNO_FTIME]
    add r0, r7, #(XDIR_ModTime + 2)         @   fno->fdate = ld_16(fs->dirbuf + XDIR_ModTime + 2);
    bl ff16_ld_16
    strh r0, [r5, #FNO_FDATE]
    b .Lgf_ret                              @   return; }
.Lgf_fat:                                   @ else {
    ldr r0, [r4, #DIR_BLK_OFS]              @   if (dp->blk_ofs != 0xFFFFFFFF) {   (a long name was found)
    cmn r0, #1
    beq .Lgf_sfn
    movs r7, #0                             @     si = di = 0;
    movs r8, #0
    movs r9, #0                             @     hs = 0;
.Lgf_ll:
    ldr r1, [r6, #FS_LFNBUF]                @     while (fs->lfnbuf[si] != 0) {
    ldrh r3, [r1, r7, lsl #1]               @       wc = fs->lfnbuf[si++];
    cmp r3, #0
    beq .Lgf_lend
    adds r7, r7, #1
    cmp r9, #0                              @       if (hs == 0 && IsSurrogate(wc)) { hs = wc; continue; }
    bne 8f
    sub r0, r3, #0xD800
    cmp r0, #0x800
    bhs 8f
    mov r9, r3
    b .Lgf_ll
8:  orr r0, r3, r9, lsl #16                 @       nw = put_utf((DWORD)hs << 16 | wc, &fno->fname[di], FF_LFN_BUF - di);
    add r1, r5, #FNO_FNAME
    add r1, r1, r8
    rsb r2, r8, #255
    bl ff16_put_utf
    cmp r0, #0                              @       if (nw == 0) { di = 0; break; }
    bne 9f
    movs r8, #0
    b .Lgf_lend
9:  add r8, r8, r0                          @       di += nw; hs = 0; }
    movs r9, #0
    b .Lgf_ll
.Lgf_lend:
    cmp r9, #0                              @     if (hs != 0) di = 0;
    it ne
    movne r8, #0
    add r1, r5, r8                          @     fno->fname[di] = 0; }
    movs r0, #0
    strb r0, [r1, #FNO_FNAME]
.Lgf_sfn:                                   @ }
    movs r7, #0                             @ si = di = 0;
    movs r8, #0
    ldr r9, [r4, #DIR_DIR]                  @ (r9 = dp->dir from here on)
.Lgf_al:
    cmp r7, #11                             @ while (si < 11) {
    bhs .Lgf_aend
    ldrb r3, [r9, r7]                       @   wc = dp->dir[si++];
    adds r7, r7, #1
    cmp r3, #' '                            @   if (wc == ' ') continue;
    beq .Lgf_al
    cmp r3, #RDDEM                          @   if (wc == RDDEM) wc = DDEM;
    it eq
    moveq r3, #DDEM
    cmp r7, #9                              @   if (si == 9 && di < 12) fno->altname[di++] = '.';
    bne 10f
    cmp r8, #12
    bhs 10f
    add r1, r5, r8
    movs r0, #'.'
    strb r0, [r1, #FNO_ALTNAME]
    adds r8, r8, #1
10: add r1, r5, r8                          @   fno->altname[di++] = (TCHAR)wc; }
    strb r3, [r1, #FNO_ALTNAME]
    adds r8, r8, #1
    b .Lgf_al
.Lgf_aend:
    add r1, r5, r8                          @ fno->altname[di] = 0;
    movs r0, #0
    strb r0, [r1, #FNO_ALTNAME]
    ldrb r0, [r5, #FNO_FNAME]               @ if (!fno->fname[0]) {
    cmp r0, #0
    bne .Lgf_fin
    cmp r8, #0                              @   if (di == 0) { fno->fname[di++] = '?'; }
    bne 11f
    add r1, r5, r8
    movs r0, #'?'
    strb r0, [r1, #FNO_FNAME]
    adds r8, r8, #1
    b 14f
11: movs r10, #NS_BODY                      @   else { BYTE lcflg = NS_BODY;
    movs r7, #0                             @     for (si = di = 0; fno->altname[si]; si++, di++) {
    movs r8, #0
12: add r1, r5, r7
    ldrb r3, [r1, #FNO_ALTNAME]             @       wc = (WCHAR)fno->altname[si];
    cmp r3, #0
    beq 14f
    cmp r3, #'.'                            @       if (wc == '.') lcflg = NS_EXT;
    it eq
    moveq r10, #NS_EXT
    sub r0, r3, #'A'                        @       if (IsUpper(wc) && (dp->dir[DIR_NTres] & lcflg)) wc += 0x20;
    cmp r0, #('Z' - 'A')
    bhi 13f
    ldrb r0, [r9, #DIR_NTres]
    tst r0, r10
    it ne
    addne r3, r3, #0x20
13: add r1, r5, r8                          @       fno->fname[di] = (TCHAR)wc; }
    strb r3, [r1, #FNO_FNAME]
    adds r7, r7, #1
    adds r8, r8, #1
    b 12b
14: add r1, r5, r8                          @   } fno->fname[di] = 0;
    movs r0, #0
    strb r0, [r1, #FNO_FNAME]
    ldrb r0, [r9, #DIR_NTres]               @   if (!dp->dir[DIR_NTres]) fno->altname[0] = 0; }
    cmp r0, #0
    bne .Lgf_fin
    strb r0, [r5, #FNO_ALTNAME]
.Lgf_fin:
    ldrb r0, [r9, #DIR_Attr]                @ fno->fattrib = dp->dir[DIR_Attr] & AM_MASK;
    and r0, r0, #AM_MASK
    strb r0, [r5, #FNO_FATTRIB]
    add r0, r9, #DIR_FileSize               @ fno->fsize = ld_32(dp->dir + DIR_FileSize);   (zero-extended to 64 bits)
    bl ff16_ld_32
    movs r1, #0
    strd r0, r1, [r5, #FNO_FSIZE]
    add r0, r9, #DIR_ModTime                @ fno->ftime = ld_16(dp->dir + DIR_ModTime + 0);
    bl ff16_ld_16
    strh r0, [r5, #FNO_FTIME]
    add r0, r9, #(DIR_ModTime + 2)          @ fno->fdate = ld_16(dp->dir + DIR_ModTime + 2);
    bl ff16_ld_16
    strh r0, [r5, #FNO_FDATE]
.Lgf_ret:
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_get_fileinfo

@ -----------------------------------------------------------------------------
@ create_name - get the next path segment as an LFN in fs->lfnbuf and an SFN in dp->fn (ff.c create_name)
@ In       : r0 = dp, r1 = path (const TCHAR** : pointer to the path pointer)
@ Out      : r0 = FRESULT (FR_OK, FR_INVALID_NAME); *path advanced past the segment and following separators;
@            dp->fn[0..10] = the 8.3 name, dp->fn[NSFLAG] = the NS_ flags
@ Clobbers : r1-r3, r12, flags
@ Frame    : [sp+0] p (the path pointer; its address is passed to tchar2uni), [sp+4] path, [sp+8] pad
@ Registers: r4 dp->fn, r5 b, r6 lfn, r7 di, r8 si, r9 i, r10 ni, r11 cf, r3 wc (between calls)
@ -----------------------------------------------------------------------------
FUNC ff16_create_name
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #12
    str r1, [sp, #4]                        @ (keep the path argument for the final *path = p)
    ldr r2, [r1]                            @ p = *path;
    str r2, [sp, #0]
    ldr r6, [r0, #OBJ_FS]
    ldr r6, [r6, #FS_LFNBUF]                @ lfn = dp->obj.fs->lfnbuf;
    add r4, r0, #DIR_FN                     @ (r4 = dp->fn)
    movs r7, #0                             @ di = 0;
.Lcn_l1:                                    @ for (;;) {
    mov r0, sp
    bl ff16_tchar2uni                       @   uc = tchar2uni(&p);
    cmn r0, #1                              @   if (uc == 0xFFFFFFFF) return FR_INVALID_NAME;
    beq .Lcn_inv
    lsrs r1, r0, #16                        @   if (uc >= 0x10000) lfn[di++] = (WCHAR)(uc >> 16);
    beq 1f
    strh r1, [r6, r7, lsl #1]
    adds r7, r7, #1
1:  uxth r3, r0                             @   wc = (WCHAR)uc;
    cmp r3, #' '                            @   if (wc < ' ' || IsSeparator(wc)) break;
    blo .Lcn_brk
    cmp r3, #'/'
    beq .Lcn_brk
    cmp r3, #'\\'
    beq .Lcn_brk
    cmp r3, #0x80                           @   if (wc < 0x80 && strchr("*:<>|\"\?\x7F", (int)wc)) return FR_INVALID_NAME;
    bhs 3f                                  @   (wc >= ' ' here, so the terminating 0 of strchr cannot match)
    ldr r1, =.Lcn_bad1
    movs r2, #CN_BAD1_LEN
2:  ldrb r12, [r1], #1
    cmp r12, r3
    beq .Lcn_inv
    subs r2, r2, #1
    bne 2b
3:  cmp r7, #255                            @   if (di >= FF_MAX_LFN) return FR_INVALID_NAME;
    bhs .Lcn_inv
    strh r3, [r6, r7, lsl #1]               @   lfn[di++] = wc; }
    adds r7, r7, #1
    b .Lcn_l1
.Lcn_brk:
    cmp r3, #' '                            @ if (wc < ' ') {
    bhs 4f
    movs r11, #NS_LAST                      @   cf = NS_LAST;
    b 7f
4:  ldr r1, [sp, #0]                        @ } else { while (IsSeparator(*p)) p++;
5:  ldrb r0, [r1]
    cmp r0, #'/'
    beq 6f
    cmp r0, #'\\'
    bne 61f
6:  adds r1, r1, #1
    b 5b
61: str r1, [sp, #0]
    movs r11, #0                            @   cf = 0;
    cmp r0, #' '                            @   if ((UINT)*p < ' ') cf = NS_LAST; }   (r0 = *p)
    it lo
    movlo r11, #NS_LAST
7:  ldr r0, [sp, #0]                        @ *path = p;
    ldr r1, [sp, #4]
    str r0, [r1]
.Lcn_trim:
    cmp r7, #0                              @ while (di) {
    beq 8f
    add r1, r6, r7, lsl #1                  @   wc = lfn[di - 1];
    ldrh r0, [r1, #-2]
    cmp r0, #' '                            @   if (wc != ' ' && wc != '.') break;
    beq 71f
    cmp r0, #'.'
    bne 8f
71: subs r7, r7, #1                         @   di--; }
    b .Lcn_trim
8:  movs r0, #0                             @ lfn[di] = 0;
    strh r0, [r6, r7, lsl #1]
    cmp r7, #0                              @ if (di == 0) return FR_INVALID_NAME;
    beq .Lcn_inv
    movs r8, #0                             @ for (si = 0; lfn[si] == ' '; si++) ;
9:  ldrh r0, [r6, r8, lsl #1]
    cmp r0, #' '
    bne 10f
    adds r8, r8, #1
    b 9b
10: cmp r8, #0                              @ if (si > 0 || lfn[si] == '.') cf |= NS_LOSS | NS_LFN;   (r0 = lfn[si])
    bne 11f
    cmp r0, #'.'
    bne 12f
11: orr r11, r11, #(NS_LOSS | NS_LFN)
12: cmp r7, #0                              @ while (di > 0 && lfn[di - 1] != '.') di--;
    beq 13f
    add r1, r6, r7, lsl #1
    ldrh r0, [r1, #-2]
    cmp r0, #'.'
    beq 13f
    subs r7, r7, #1
    b 12b
13: mov r0, r4                              @ memset(dp->fn, ' ', 11);
    movs r1, #' '
    movs r2, #11
    bl ff16_mem_set
    movs r9, #0                             @ i = b = 0;
    movs r5, #0
    movs r10, #8                            @ ni = 8;
.Lcn_main:                                  @ for (;;) {
    ldrh r3, [r6, r8, lsl #1]               @   wc = lfn[si++];
    adds r8, r8, #1
    cmp r3, #0                              @   if (wc == 0) break;
    beq .Lcn_done
    cmp r3, #' '                            @   if (wc == ' ' || (wc == '.' && si != di)) {
    beq .Lcn_loss
    cmp r3, #'.'
    bne 14f
    cmp r8, r7
    bne .Lcn_loss                           @     cf |= NS_LOSS | NS_LFN; continue; }
14: cmp r9, r10                             @   if (i >= ni || si == di) {
    bhs 15f
    cmp r8, r7
    bne 19f
15: cmp r10, #11                            @     if (ni == 11) { cf |= NS_LOSS | NS_LFN; break; }
    bne 16f
    orr r11, r11, #(NS_LOSS | NS_LFN)
    b .Lcn_done
16: cmp r8, r7                              @     if (si != di) cf |= NS_LOSS | NS_LFN;
    beq 17f
    orr r11, r11, #(NS_LOSS | NS_LFN)
17: cmp r8, r7                              @     if (si > di) break;
    bhi .Lcn_done
    mov r8, r7                              @     si = di; i = 8; ni = 11; b <<= 2;
    movs r9, #8
    movs r10, #11
    lsls r5, r5, #2
    b .Lcn_main                             @     continue; }
19: cmp r3, #0x80                           @   if (wc >= 0x80) {
    blo 22f
    orr r11, r11, #NS_LFN                   @     cf |= NS_LFN;
    mov r0, r3                              @     wc = ff_uni2oem(wc, CODEPAGE);
    movw r1, #CODEPAGE
    bl ff16_ff_uni2oem
    uxth r3, r0
    tst r3, #0x80                           @     if (wc & 0x80) wc = ExCvt[wc & 0x7F]; }
    beq 22f
    and r1, r3, #0x7F
    ldr r2, =ff16_ExCvt
    ldrb r3, [r2, r1]
22: cmp r3, #0x100                          @   if (wc >= 0x100) {   (double byte character)
    blo 24f
    sub r0, r10, #1                         @     if (i >= ni - 1) { cf |= NS_LOSS | NS_LFN; i = ni; continue; }
    cmp r9, r0
    blo 23f
    orr r11, r11, #(NS_LOSS | NS_LFN)
    mov r9, r10
    b .Lcn_main
23: lsr r0, r3, #8                          @     dp->fn[i++] = (BYTE)(wc >> 8);
    strb r0, [r4, r9]
    adds r9, r9, #1
    b .Lcn_store
24: cmp r3, #0                              @   } else { if (wc == 0 || strchr("+,;=[]", (int)wc)) {
    beq 27f
    ldr r1, =.Lcn_bad2
    movs r2, #CN_BAD2_LEN
25: ldrb r12, [r1], #1
    cmp r12, r3
    beq 27f
    subs r2, r2, #1
    bne 25b
    sub r0, r3, #'A'                        @     else { if (IsUpper(wc)) b |= 2;
    cmp r0, #('Z' - 'A')
    bhi 26f
    orr r5, r5, #2
26: sub r0, r3, #'a'                        @       if (IsLower(wc)) { b |= 1; wc -= 0x20; } } }
    cmp r0, #('z' - 'a')
    bhi .Lcn_store
    orr r5, r5, #1
    sub r3, r3, #0x20
    b .Lcn_store
27: movs r3, #'_'                           @     wc = '_'; cf |= NS_LOSS | NS_LFN;
    orr r11, r11, #(NS_LOSS | NS_LFN)
.Lcn_store:
    strb r3, [r4, r9]                       @   dp->fn[i++] = (BYTE)wc; }
    adds r9, r9, #1
    b .Lcn_main
.Lcn_loss:
    orr r11, r11, #(NS_LOSS | NS_LFN)       @ cf |= NS_LOSS | NS_LFN; continue;
    b .Lcn_main
.Lcn_done:
    ldrb r0, [r4, #0]                       @ if (dp->fn[0] == DDEM) dp->fn[0] = RDDEM;
    cmp r0, #DDEM
    bne 28f
    movs r0, #RDDEM
    strb r0, [r4, #0]
28: cmp r10, #8                             @ if (ni == 8) b <<= 2;
    bne 29f
    lsls r5, r5, #2
29: and r0, r5, #0x0C                       @ if ((b & 0x0C) == 0x0C || (b & 0x03) == 0x03) cf |= NS_LFN;
    cmp r0, #0x0C
    beq 30f
    and r0, r5, #0x03
    cmp r0, #0x03
    bne 31f
30: orr r11, r11, #NS_LFN
31: tst r11, #NS_LFN                        @ if (!(cf & NS_LFN)) {
    bne 33f
    tst r5, #0x01                           @   if (b & 0x01) cf |= NS_EXT;
    beq 32f
    orr r11, r11, #NS_EXT
32: tst r5, #0x04                           @   if (b & 0x04) cf |= NS_BODY; }
    beq 33f
    orr r11, r11, #NS_BODY
33: strb r11, [r4, #NSFLAG]                 @ dp->fn[NSFLAG] = cf;
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lcn_ret
.Lcn_inv:
    movs r0, #FR_INVALID_NAME
.Lcn_ret:
    add sp, sp, #12
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .ltorg
ENDFUNC ff16_create_name

@ -----------------------------------------------------------------------------
@ follow_path - follow a path to the object (ff.c follow_path, FF_FS_RPATH 0)
@ In       : r0 = dp (dp->obj.fs set up), r1 = path
@ Out      : r0 = FRESULT (FR_OK: dp points at the object; FR_NO_FILE: last segment not found, dp ready for
@            dir_register; FR_NO_PATH; FR_INVALID_NAME; ...); for an empty path dp->fn[NSFLAG] = NS_NONAME and dp
@            is at the start of the root directory
@ Clobbers : r1-r3, r12, flags
@ Frame    : [sp+0] path (create_name advances it), [sp+4] pad
@ Registers: r4 dp, r5 fs, r6 ns
@ -----------------------------------------------------------------------------
FUNC ff16_follow_path
    push {r4, r5, r6, lr}
    sub sp, sp, #8
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
1:  ldrb r2, [r1]                           @ while (IsSeparator(*path)) path++;
    cmp r2, #'/'
    beq 2f
    cmp r2, #'\\'
    bne 3f
2:  adds r1, r1, #1
    b 1b
3:  str r1, [sp, #0]
    movs r0, #0
    str r0, [r4, #OBJ_SCLUST]               @ dp->obj.sclust = 0;
    str r0, [r4, #OBJ_N_FRAG]               @ dp->obj.n_frag = 0;
    cmp r2, #' '                            @ if ((UINT)*path < ' ') {   (r2 = *path)
    bhs .Lfp_loop
    movs r0, #NS_NONAME                     @   dp->fn[NSFLAG] = NS_NONAME;
    strb r0, [r4, #(DIR_FN + NSFLAG)]
    mov r0, r4
    movs r1, #0
    bl ff16_dir_sdi                         @   res = dir_sdi(dp, 0);
    b .Lfp_ret
.Lfp_loop:                                  @ } else { for (;;) {
    mov r0, r4
    mov r1, sp
    bl ff16_create_name                     @   res = create_name(dp, &path);
    cmp r0, #FR_OK                          @   if (res != FR_OK) break;
    bne .Lfp_ret
    ldrb r6, [r4, #(DIR_FN + NSFLAG)]       @   ns = dp->fn[NSFLAG];
    mov r0, r4
    bl ff16_dir_find                        @   res = dir_find(dp);
    cmp r0, #FR_OK                          @   if (res != FR_OK) {
    beq 4f
    cmp r0, #FR_NO_FILE                     @     if (res == FR_NO_FILE) {   (the "0 && (ns & NS_DOT)" branch is compiled out)
    bne .Lfp_ret
    tst r6, #NS_LAST                        @       if (!(ns & NS_LAST)) res = FR_NO_PATH; }
    it eq
    moveq r0, #FR_NO_PATH
    b .Lfp_ret                              @     break; }
4:  tst r6, #NS_LAST                        @   if (ns & NS_LAST) break;   (res == FR_OK)
    bne .Lfp_ret
    ldrb r1, [r4, #OBJ_ATTR]                @   if (!(dp->obj.attr & AM_DIR)) { res = FR_NO_PATH; break; }
    tst r1, #AM_DIR
    bne 5f
    movs r0, #FR_NO_PATH
    b .Lfp_ret
5:  ldrb r0, [r5, #FS_FS_TYPE]              @   if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne 6f
    mov r0, r4                              @     init_alloc_info(&dp->obj, dp);
    mov r1, r4
    bl ff16_init_alloc_info
    b .Lfp_loop
6:  ldr r1, [r4, #DIR_DPTR]                 @   } else { dp->obj.sclust = ld_clust(fs, fs->win + dp->dptr % SS(fs)); }
    ubfx r1, r1, #0, #9
    add r1, r1, r5
    adds r1, r1, #FS_WIN
    mov r0, r5
    bl ff16_ld_clust
    str r0, [r4, #OBJ_SCLUST]
    b .Lfp_loop                             @ } }
.Lfp_ret:
    add sp, sp, #8                          @ return res;
    pop {r4, r5, r6, pc}
ENDFUNC ff16_follow_path

    .section .rodata.ff16x.dir2, "a", %progbits
@ characters not allowed in a long file name segment (ff.c create_name: "*:<>|\"\?\x7F" = * : < > | " ? DEL)
.Lcn_bad1:
    .byte 0x2A, 0x3A, 0x3C, 0x3E, 0x7C, 0x22, 0x3F, 0x7F
@ characters replaced by '_' in the 8.3 name (ff.c create_name: "+,;=[]")
.Lcn_bad2:
    .byte 0x2B, 0x2C, 0x3B, 0x3D, 0x5B, 0x5D
