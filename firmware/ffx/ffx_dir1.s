@ =============================================================================
@ ffx_dir1.s - FatFs R0.16 w/patch 2, exFAT configuration: directory index and walking, cluster fields of directory
@ entries, long file name entries, short name generation, directory checksums and exFAT directory-block load/store
@ (group B of the exFAT translation)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c) in the configuration of ff16x.inc (FF_FS_EXFAT 1, FF_USE_LFN 1,
@ FF_CODE_PAGE 437, FF_MAX_SS 512), from the preprocessed reference ff_x.c (read/write) and ff_xro.c (FF_FS_READONLY 1).
@ Routines: dir_sdi, dir_next, dir_alloc, ld_clust, st_clust, cmp_lfn, pick_lfn, put_lfn, gen_numname, sum_sfn, xdir_sum,
@ xname_sum, xsum32, load_xdir, init_alloc_info, load_obj_xdir, store_xdir, create_xdir.  Each routine names the C
@ function it translates; the code follows the C statements in order and the comments quote them.  Calling convention
@ AAPCS (r0-r3, r12 scratch, r4-r11 preserved, stack 8-byte aligned at calls), as the C functions.  Routines that exist
@ only in the read/write build (ff_x.c) are inside .if FF_FS_READONLY == 0; the bootloader assembles this file with
@ FF_FS_READONLY 1.
@
@ FatFs license (ChaN): "FatFs module is an open source software. Redistribution and use of FatFs in source and binary forms,
@ with or without modification, are permitted provided that the following condition is met: 1. Redistributions of source
@ code must retain the above copyright notice, this condition and the following disclaimer.  This software is provided by
@ the copyright holder and contributors "AS IS" and any warranties related to this software are DISCLAIMED.  The copyright
@ owner or contributors be NOT LIABLE for any damages caused by use of this software."  Copyright (C) 2025, ChaN, all right
@ reserved.
@
@ Notes on the translation:
@  - ld_16 / ld_32 / ld_64 / st_16 of ff.c are expanded inline as byte loads and stores (they are byte-wise in the C, so
@    the access is correct at any alignment and needs no call).
@  - dbc_1st of code page 437 (ff_x.c: "if (c != 0) return 0; return 0;") is always 0, so the double-byte branch of
@    gen_numname can never be taken and is not emitted.
@  - The C tests "fs->fs_type == 4" are FS_EXFAT, "fs->fs_type >= 3" is FS_FAT32 or above; sector size is the constant 512.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ff16x.inc"

@ ff.c: size of DirBuf = (FF_MAX_LFN + 44) / 15 * SZDIRE = (255 + 44U) / 15 * 32 = 608 bytes (largest exFAT entry block
@ that is kept in fs->dirbuf)
    .equ FFXB_DIRBUF_SZ, ((FF_MAX_LFN + 44) / 15 * 32)

    .section .text.ff16x.dir1, "ax", %progbits

@ -----------------------------------------------------------------------------
@ dir_sdi - set the directory index (ff.c dir_sdi)
@ In       : r0 = dp, r1 = ofs (byte offset in the directory, multiple of 32)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 ofs, r7 clst, r8 csz
@ -----------------------------------------------------------------------------
FUNC ff16_dir_sdi
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    mov r6, r1
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    ldrb r0, [r5, #FS_FS_TYPE]
    mov r1, #MAX_DIR                        @ limit = (1 && fs->fs_type == FS_EXFAT) ? MAX_DIR_EX : MAX_DIR
    cmp r0, #FS_EXFAT
    it eq
    moveq r1, #MAX_DIR_EX
    cmp r6, r1                              @ if (ofs >= (DWORD)limit || ofs % 32) return FR_INT_ERR;
    bhs .Lb_sdi_int
    tst r6, #(SZDIRE - 1)
    bne .Lb_sdi_int
    str r6, [r4, #DIR_DPTR]                 @ dp->dptr = ofs;
    ldr r7, [r4, #OBJ_SCLUST]               @ clst = dp->obj.sclust;
    cmp r7, #0                              @ if (clst == 0 && fs->fs_type >= FS_FAT32) {
    bne 1f
    cmp r0, #FS_FAT32                       @   (r0 still holds fs->fs_type)
    blo 1f
    ldr r7, [r5, #FS_DIRBASE]               @   clst = (DWORD)fs->dirbase;
    movs r1, #0
    strb r1, [r4, #OBJ_STAT]                @   if (1) dp->obj.stat = 0;   (exFAT: root is a plain, non-fragmented chain)
1:  cmp r7, #0                              @ } if (clst == 0) {
    bne 2f
    ldrh r0, [r5, #FS_N_ROOTDIR]            @   if (ofs / 32 >= fs->n_rootdir) return FR_INT_ERR;
    cmp r0, r6, lsr #5
    bls .Lb_sdi_int
    ldr r0, [r5, #FS_DIRBASE]
    str r0, [r4, #DIR_SECT]                 @   dp->sect = fs->dirbase;
    b 4f
2:  ldrh r8, [r5, #FS_CSIZE]                @ } else { csz = (DWORD)fs->csize * SS(fs);
    lsl r8, r8, #9
3:  cmp r6, r8                              @   while (ofs >= csz) {
    blo 31f
    mov r0, r4
    mov r1, r7
    bl ff16_get_fat                         @     clst = get_fat(&dp->obj, clst);
    mov r7, r0
    cmn r7, #1
    beq .Lb_sdi_disk                        @     if (clst == 0xFFFFFFFF) return FR_DISK_ERR;
    cmp r7, #2                              @     if (clst < 2 || clst >= fs->n_fatent) return FR_INT_ERR;
    blo .Lb_sdi_int
    ldr r0, [r5, #FS_N_FATENT]
    cmp r7, r0
    bhs .Lb_sdi_int
    sub r6, r6, r8                          @     ofs -= csz;
    b 3b                                    @   }
31: mov r0, r5
    mov r1, r7
    bl ff16_clst2sect
    str r0, [r4, #DIR_SECT]                 @   dp->sect = clst2sect(fs, clst);
4:  str r7, [r4, #DIR_CLUST]                @ }  dp->clust = clst;
    ldr r0, [r4, #DIR_SECT]                 @ if (dp->sect == 0) return FR_INT_ERR;
    cmp r0, #0
    beq .Lb_sdi_int
    add r0, r0, r6, lsr #9
    str r0, [r4, #DIR_SECT]                 @ dp->sect += ofs / SS(fs);
    ubfx r0, r6, #0, #9
    add r0, r0, r5
    adds r0, r0, #FS_WIN
    str r0, [r4, #DIR_DIR]                  @ dp->dir = fs->win + (ofs % SS(fs));
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lb_sdi_ret
.Lb_sdi_int:
    movs r0, #FR_INT_ERR
    b .Lb_sdi_ret
.Lb_sdi_disk:
    movs r0, #FR_DISK_ERR
.Lb_sdi_ret:
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_dir_sdi

@ -----------------------------------------------------------------------------
@ dir_next - move the directory index to the next entry (ff.c dir_next)
@ In       : r0 = dp, r1 = stretch (non-zero: extend the directory by a cleared cluster at its end; read/write build only)
@ Out      : r0 = FRESULT (FR_NO_FILE at the end of the directory)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 ofs, r7 clst, r8 stretch
@ Read-only build (ff_xro.c): no stretching, the end of the chain is always "sect = 0; return FR_NO_FILE".
@ -----------------------------------------------------------------------------
FUNC ff16_dir_next
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    mov r8, r1
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    ldr r6, [r4, #DIR_DPTR]
    adds r6, r6, #SZDIRE                    @ ofs = dp->dptr + SZDIRE;
    ldrb r0, [r5, #FS_FS_TYPE]
    mov r1, #MAX_DIR                        @ limit = (1 && fs->fs_type == FS_EXFAT) ? MAX_DIR_EX : MAX_DIR
    cmp r0, #FS_EXFAT
    it eq
    moveq r1, #MAX_DIR_EX
    cmp r6, r1                              @ if (ofs >= (DWORD)limit) dp->sect = 0;
    blo 1f
    movs r0, #0
    str r0, [r4, #DIR_SECT]
1:  ldr r0, [r4, #DIR_SECT]                 @ if (dp->sect == 0) return FR_NO_FILE;
    cmp r0, #0
    beq .Lb_next_nofile
    ubfx r0, r6, #0, #9                     @ if (ofs % SS(fs) == 0) {   (511 is not a Thumb-2 immediate)
    cmp r0, #0
    bne .Lb_next_set
    ldr r0, [r4, #DIR_SECT]
    adds r0, r0, #1
    str r0, [r4, #DIR_SECT]                 @   dp->sect++;
    ldr r1, [r4, #DIR_CLUST]                @   if (dp->clust == 0) {
    cmp r1, #0
    bne 2f
    ldrh r0, [r5, #FS_N_ROOTDIR]            @     if (ofs / SZDIRE >= fs->n_rootdir) {
    cmp r0, r6, lsr #5
    bhi .Lb_next_set
    b .Lb_next_nofile_sect0                 @       dp->sect = 0; return FR_NO_FILE; }
2:  ldrh r0, [r5, #FS_CSIZE]                @   } else {
    subs r0, r0, #1                         @     if ((ofs / SS(fs) & (fs->csize - 1)) == 0) {
    ands r0, r0, r6, lsr #9
    bne .Lb_next_set
    mov r0, r4
    bl ff16_get_fat                         @       clst = get_fat(&dp->obj, dp->clust);   (r1 = dp->clust, loaded above)
    mov r7, r0
    cmp r7, #1                              @       if (clst <= 1) return FR_INT_ERR;
    bls .Lb_next_int
    cmn r7, #1                              @       if (clst == 0xFFFFFFFF) return FR_DISK_ERR;
    beq .Lb_next_disk
    ldr r0, [r5, #FS_N_FATENT]              @       if (clst >= fs->n_fatent) {
    cmp r7, r0
    blo 3f
    .if FF_FS_READONLY == 0
    cmp r8, #0                              @         if (!stretch) { dp->sect = 0; return FR_NO_FILE; }
    beq .Lb_next_nofile_sect0
    mov r0, r4
    ldr r1, [r4, #DIR_CLUST]
    bl ff16_create_chain                    @         clst = create_chain(&dp->obj, dp->clust);
    mov r7, r0
    cmp r7, #0                              @         if (clst == 0) return FR_DENIED;
    beq .Lb_next_denied
    cmp r7, #1                              @         if (clst == 1) return FR_INT_ERR;
    beq .Lb_next_int
    cmn r7, #1                              @         if (clst == 0xFFFFFFFF) return FR_DISK_ERR;
    beq .Lb_next_disk
    mov r0, r5
    mov r1, r7
    bl ff16_dir_clear                       @         if (dir_clear(fs, clst) != FR_OK) return FR_DISK_ERR;
    cmp r0, #FR_OK
    bne .Lb_next_disk
    ldrb r0, [r4, #OBJ_STAT]                @         if (1) dp->obj.stat |= 4;   (directory grew: chain no longer "none-fragmented")
    orr r0, r0, #4
    strb r0, [r4, #OBJ_STAT]
    .else
    b .Lb_next_nofile_sect0                 @         (read-only: if (!stretch) dp->sect = 0;) dp->sect = 0; return FR_NO_FILE;
    .endif
3:  str r7, [r4, #DIR_CLUST]                @       }  dp->clust = clst;
    mov r0, r5
    mov r1, r7
    bl ff16_clst2sect
    str r0, [r4, #DIR_SECT]                 @       dp->sect = clst2sect(fs, clst);
.Lb_next_set:                               @ } } }
    str r6, [r4, #DIR_DPTR]                 @ dp->dptr = ofs;
    ubfx r0, r6, #0, #9
    add r0, r0, r5
    adds r0, r0, #FS_WIN
    str r0, [r4, #DIR_DIR]                  @ dp->dir = fs->win + ofs % SS(fs);
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lb_next_ret
.Lb_next_nofile_sect0:
    movs r0, #0
    str r0, [r4, #DIR_SECT]                 @ dp->sect = 0;
.Lb_next_nofile:
    movs r0, #FR_NO_FILE
    b .Lb_next_ret
.Lb_next_int:
    movs r0, #FR_INT_ERR
    b .Lb_next_ret
.Lb_next_disk:
    movs r0, #FR_DISK_ERR
    b .Lb_next_ret
    .if FF_FS_READONLY == 0
.Lb_next_denied:
    movs r0, #FR_DENIED
    .endif
.Lb_next_ret:
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_dir_next

    .if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ dir_alloc - allocate n_ent consecutive free directory entries (ff.c dir_alloc), read/write build only
@ In       : r0 = dp, r1 = n_ent
@ Out      : r0 = FRESULT (FR_DENIED when the directory has no room and cannot grow)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 n, r7 n_ent, r8 res
@ -----------------------------------------------------------------------------
FUNC ff16_dir_alloc
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    mov r7, r1
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    movs r1, #0
    mov r0, r4
    bl ff16_dir_sdi                         @ res = dir_sdi(dp, 0);
    mov r8, r0
    cmp r8, #FR_OK                          @ if (res == FR_OK) {
    bne 9f
    movs r6, #0                             @   n = 0;
1:  mov r0, r5                              @   do {
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @     res = move_window(fs, dp->sect);
    mov r8, r0
    cmp r8, #FR_OK                          @     if (res != FR_OK) break;
    bne 9f
    ldrb r0, [r5, #FS_FS_TYPE]              @     if ((fs->fs_type == FS_EXFAT) ? (int)((dp->dir[0] & 0x80) == 0)
    ldr r1, [r4, #DIR_DIR]                  @                                   : (int)(dp->dir[0] == DDEM || dp->dir[0] == 0)) {
    ldrb r1, [r1]
    cmp r0, #FS_EXFAT
    bne 2f
    tst r1, #0x80
    bne 4f                                  @       (exFAT: in-use bit set -> entry used)
    b 3f
2:  cmp r1, #DDEM
    beq 3f
    cmp r1, #0
    bne 4f
3:  adds r6, r6, #1                         @       if (++n == n_ent) break;
    cmp r6, r7
    beq 9f
    b 5f
4:  movs r6, #0                             @     } else { n = 0; }
5:  mov r0, r4
    movs r1, #1
    bl ff16_dir_next                        @     res = dir_next(dp, 1);
    mov r8, r0
    cmp r8, #FR_OK                          @   } while (res == FR_OK);
    beq 1b
9:  cmp r8, #FR_NO_FILE                     @ } if (res == FR_NO_FILE) res = FR_DENIED;
    bne 10f
    movs r8, #FR_DENIED
10: mov r0, r8                              @ return res;
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_dir_alloc
    .endif

@ -----------------------------------------------------------------------------
@ ld_clust - get the start cluster of an object from its directory entry (ff.c ld_clust)
@ In       : r0 = fs, r1 = dir (32-byte directory entry)
@ Out      : r0 = cluster number
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_ld_clust
    ldrb r2, [r1, #DIR_FstClusLO]           @ cl = ld_16(dir + DIR_FstClusLO);
    ldrb r3, [r1, #(DIR_FstClusLO + 1)]
    orr r2, r2, r3, lsl #8
    ldrb r3, [r0, #FS_FS_TYPE]              @ if (fs->fs_type == FS_FAT32) {
    cmp r3, #FS_FAT32
    bne 1f
    ldrb r3, [r1, #DIR_FstClusHI]           @   cl |= (DWORD)ld_16(dir + DIR_FstClusHI) << 16;
    ldrb r12, [r1, #(DIR_FstClusHI + 1)]
    orr r3, r3, r12, lsl #8
    orr r2, r2, r3, lsl #16
1:  mov r0, r2                              @ } return cl;
    bx lr
ENDFUNC ff16_ld_clust

    .if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ st_clust - set the start cluster of an object in its directory entry (ff.c st_clust), read/write build only
@ In       : r0 = fs, r1 = dir, r2 = cl
@ Out      : -
@ Clobbers : r2, r3, flags
@ -----------------------------------------------------------------------------
FUNC ff16_st_clust
    strb r2, [r1, #DIR_FstClusLO]           @ st_16(dir + DIR_FstClusLO, (WORD)cl);
    lsrs r3, r2, #8
    strb r3, [r1, #(DIR_FstClusLO + 1)]
    ldrb r3, [r0, #FS_FS_TYPE]              @ if (fs->fs_type == FS_FAT32) {
    cmp r3, #FS_FAT32
    bne 1f
    lsrs r3, r2, #16                        @   st_16(dir + DIR_FstClusHI, (WORD)(cl >> 16));
    strb r3, [r1, #DIR_FstClusHI]
    lsrs r3, r2, #24
    strb r3, [r1, #(DIR_FstClusHI + 1)]
1:  bx lr                                   @ }
ENDFUNC ff16_st_clust
    .endif

@ -----------------------------------------------------------------------------
@ cmp_lfn - compare one long-file-name entry with the name in the LFN buffer (ff.c cmp_lfn)
@ In       : r0 = lfnbuf (WCHAR[]), r1 = dir (LFN entry)
@ Out      : r0 = 1 on match, 0 otherwise
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 lfnbuf, r5 dir, r6 ni, r7 di, r8 pchr, r9 chr, r10 ff_wtoupper(chr)
@ -----------------------------------------------------------------------------
FUNC ff16_cmp_lfn
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    mov r4, r0
    mov r5, r1
    ldrb r0, [r5, #LDIR_FstClusLO]          @ if (ld_16(dir + LDIR_FstClusLO) != 0) return 0;
    ldrb r1, [r5, #(LDIR_FstClusLO + 1)]
    orrs r0, r0, r1, lsl #8
    bne .Lb_cmp_zero
    ldrb r6, [r5, #LDIR_Ord]                @ ni = (UINT)((dir[LDIR_Ord] & 0x3F) - 1) * 13;
    and r6, r6, #0x3F
    subs r6, r6, #1
    movs r0, #13
    mul r6, r6, r0
    movs r8, #1                             @ for (pchr = 1, di = 0; di < 13; di++) {
    movs r7, #0
1:  ldr r0, =ff16_LfnOfs                    @   chr = ld_16(dir + LfnOfs[di]);
    ldrb r0, [r0, r7]
    ldrb r1, [r5, r0]
    adds r0, r0, #1
    ldrb r2, [r5, r0]
    orr r9, r1, r2, lsl #8
    cmp r8, #0                              @   if (pchr != 0) {
    beq 3f
    cmp r6, #(FF_MAX_LFN + 1)               @     if (ni >= FF_MAX_LFN + 1 ||
    bhs .Lb_cmp_zero
    mov r0, r9
    bl ff16_ff_wtoupper                     @         ff_wtoupper(chr) != ff_wtoupper(lfnbuf[ni++])) return 0;
    mov r10, r0
    ldrh r0, [r4, r6, lsl #1]
    adds r6, r6, #1
    bl ff16_ff_wtoupper
    cmp r0, r10
    bne .Lb_cmp_zero
    mov r8, r9                              @     pchr = chr;
    b 4f
3:  movw r0, #0xFFFF                        @   } else { if (chr != 0xFFFF) return 0; }
    cmp r9, r0
    bne .Lb_cmp_zero
4:  adds r7, r7, #1                         @ }  (di++)
    cmp r7, #13
    blo 1b
    ldrb r0, [r5, #LDIR_Ord]                @ if ((dir[LDIR_Ord] & LLEF) && pchr && lfnbuf[ni]) return 0;
    tst r0, #LLEF
    beq 5f
    cmp r8, #0
    beq 5f
    ldrh r0, [r4, r6, lsl #1]
    cmp r0, #0
    bne .Lb_cmp_zero
5:  movs r0, #1                             @ return 1;
    b .Lb_cmp_ret
.Lb_cmp_zero:
    movs r0, #0
.Lb_cmp_ret:
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_cmp_lfn
    .ltorg

@ -----------------------------------------------------------------------------
@ pick_lfn - extract the characters of one long-file-name entry into the LFN buffer (ff.c pick_lfn)
@ In       : r0 = lfnbuf (WCHAR[]), r1 = dir (LFN entry)
@ Out      : r0 = 1 on success, 0 on a malformed entry
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 ni, r5 pchr, r6 di, r7 chr
@ -----------------------------------------------------------------------------
FUNC ff16_pick_lfn
    push {r4, r5, r6, r7}
    ldrb r2, [r1, #LDIR_FstClusLO]          @ if (ld_16(dir + LDIR_FstClusLO) != 0) return 0;
    ldrb r3, [r1, #(LDIR_FstClusLO + 1)]
    orrs r2, r2, r3, lsl #8
    bne .Lb_pick_zero
    ldrb r4, [r1, #LDIR_Ord]                @ ni = (UINT)((dir[LDIR_Ord] & ~LLEF) - 1) * 13;
    bic r4, r4, #LLEF
    subs r4, r4, #1
    movs r2, #13
    mul r4, r4, r2
    movs r5, #1                             @ for (pchr = 1, di = 0; di < 13; di++) {
    movs r6, #0
1:  ldr r2, =ff16_LfnOfs                    @   chr = ld_16(dir + LfnOfs[di]);
    ldrb r2, [r2, r6]
    ldrb r3, [r1, r2]
    adds r2, r2, #1
    ldrb r7, [r1, r2]
    orr r7, r3, r7, lsl #8
    cmp r5, #0                              @   if (pchr != 0) {
    beq 3f
    cmp r4, #(FF_MAX_LFN + 1)               @     if (ni >= FF_MAX_LFN + 1) return 0;
    bhs .Lb_pick_zero
    strh r7, [r0, r4, lsl #1]               @     lfnbuf[ni++] = pchr = chr;
    adds r4, r4, #1
    mov r5, r7
    b 4f
3:  movw r2, #0xFFFF                        @   } else { if (chr != 0xFFFF) return 0; }
    cmp r7, r2
    bne .Lb_pick_zero
4:  adds r6, r6, #1                         @ }  (di++)
    cmp r6, #13
    blo 1b
    ldrb r2, [r1, #LDIR_Ord]                @ if (dir[LDIR_Ord] & LLEF && pchr != 0) {
    tst r2, #LLEF
    beq 5f
    cmp r5, #0
    beq 5f
    cmp r4, #(FF_MAX_LFN + 1)               @   if (ni >= FF_MAX_LFN + 1) return 0;
    bhs .Lb_pick_zero
    movs r2, #0
    strh r2, [r0, r4, lsl #1]               @   lfnbuf[ni] = 0;
5:  movs r0, #1                             @ } return 1;
    b .Lb_pick_ret
.Lb_pick_zero:
    movs r0, #0
.Lb_pick_ret:
    pop {r4, r5, r6, r7}
    bx lr
ENDFUNC ff16_pick_lfn
    .ltorg

    .if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ put_lfn - store one long-file-name entry from the LFN buffer (ff.c put_lfn), read/write build only
@ In       : r0 = lfn (WCHAR[]), r1 = dir (LFN entry to fill), r2 = ord (BYTE), r3 = sum (BYTE)
@ Out      : -
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 scratch, r5 ni, r6 di, r7 chr
@ -----------------------------------------------------------------------------
FUNC ff16_put_lfn
    push {r4, r5, r6, r7}
    strb r3, [r1, #LDIR_Chksum]             @ dir[LDIR_Chksum] = sum;
    movs r4, #AM_LFN
    strb r4, [r1, #LDIR_Attr]               @ dir[LDIR_Attr] = AM_LFN;
    movs r4, #0
    strb r4, [r1, #LDIR_Type]               @ dir[LDIR_Type] = 0;
    strb r4, [r1, #LDIR_FstClusLO]          @ st_16(dir + LDIR_FstClusLO, 0);
    strb r4, [r1, #(LDIR_FstClusLO + 1)]
    uxtb r2, r2                             @ ni = (UINT)(ord - 1) * 13;
    subs r5, r2, #1
    movs r4, #13
    mul r5, r5, r4
    movs r6, #0                             @ di = chr = 0;
    movs r7, #0
1:  movw r4, #0xFFFF                        @ do {  if (chr != 0xFFFF) chr = lfn[ni++];
    cmp r7, r4
    beq 2f
    ldrh r7, [r0, r5, lsl #1]
    adds r5, r5, #1
2:  ldr r4, =ff16_LfnOfs                    @   st_16(dir + LfnOfs[di], chr);
    ldrb r4, [r4, r6]
    strb r7, [r1, r4]
    adds r4, r4, #1
    lsrs r3, r7, #8
    strb r3, [r1, r4]
    cmp r7, #0                              @   if (chr == 0) chr = 0xFFFF;
    bne 3f
    movw r7, #0xFFFF
3:  adds r6, r6, #1                         @ } while (++di < 13);
    cmp r6, #13
    blo 1b
    movw r4, #0xFFFF                        @ if (chr == 0xFFFF || !lfn[ni]) ord |= LLEF;
    cmp r7, r4
    beq 4f
    ldrh r3, [r0, r5, lsl #1]
    cmp r3, #0
    bne 5f
4:  orr r2, r2, #LLEF
5:  strb r2, [r1, #LDIR_Ord]                @ dir[LDIR_Ord] = ord;
    pop {r4, r5, r6, r7}
    bx lr
ENDFUNC ff16_put_lfn
    .ltorg

@ -----------------------------------------------------------------------------
@ gen_numname - generate a numbered short name "BASE~N" (ff.c gen_numname), read/write build only
@ In       : r0 = dst (11-byte SFN buffer), r1 = src (11-byte SFN), r2 = lfn (WCHAR[], used when seq > 5), r3 = seq (WORD)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Registers: r4 dst, r5 lfn, r6 seq / crc_sreg, r7 i, r8 j, r9 0x11021; ns[8] at [sp]
@ -----------------------------------------------------------------------------
FUNC ff16_gen_numname
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    sub sp, sp, #8                          @ BYTE ns[8];
    mov r4, r0
    mov r5, r2
    uxth r6, r3
    movs r2, #11
    bl ff16_mem_cpy                         @ memcpy(dst, src, 11);   (r0 = dst, r1 = src still as passed)
    cmp r6, #5                              @ if (seq > 5) {
    bls 4f
    movw r9, #0x1021                        @   (polynomial 0x11021)
    movt r9, #1
1:  ldrh r0, [r5]                           @   while (*lfn) {  wc = *lfn++;
    cmp r0, #0
    beq 3f
    adds r5, r5, #2
    movs r1, #16                            @     for (i = 0; i < 16; i++) {
2:  and r2, r0, #1                          @       crc_sreg = (crc_sreg << 1) + (wc & 1);
    add r6, r2, r6, lsl #1
    lsrs r0, r0, #1                         @       wc >>= 1;
    tst r6, #0x10000                        @       if (crc_sreg & 0x10000) crc_sreg ^= 0x11021;
    it ne
    eorne r6, r6, r9
    subs r1, r1, #1
    bne 2b                                  @     }
    b 1b                                    @   }
3:  uxth r6, r6                             @   seq = (WORD)crc_sreg;
4:  movs r7, #7                             @ } i = 7;
5:  and r0, r6, #15                         @ do {  c = (BYTE)((seq % 16) + '0');
    adds r0, r0, #'0'
    lsrs r6, r6, #4                         @   seq /= 16;
    cmp r0, #'9'                            @   if (c > '9') c += 7;
    it hi
    addhi r0, r0, #7
    strb r0, [sp, r7]                       @   ns[i--] = c;
    subs r7, r7, #1
    beq 6f                                  @ } while (i && seq);
    cmp r6, #0
    bne 5b
6:  movs r0, #'~'                           @ ns[i] = '~';
    strb r0, [sp, r7]
    movs r8, #0                             @ for (j = 0; j < i && dst[j] != ' '; j++) {
7:  cmp r8, r7                              @   (dbc_1st() of code page 437 is always 0: no double-byte step)
    bhs 8f
    ldrb r0, [r4, r8]
    cmp r0, #' '
    beq 8f
    add r8, r8, #1
    b 7b                                    @ }
8:  movs r0, #' '                           @ do {  dst[j++] = (i < 8) ? ns[i++] : ' ';
    cmp r7, #8
    bhs 9f
    ldrb r0, [sp, r7]
    adds r7, r7, #1
9:  strb r0, [r4, r8]
    add r8, r8, #1
    cmp r8, #8                              @ } while (j < 8);
    blo 8b
    add sp, sp, #8
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_gen_numname
    .endif

@ -----------------------------------------------------------------------------
@ sum_sfn - checksum of a short file name for the LFN entries (ff.c sum_sfn)
@ In       : r0 = dir (11-byte short name)
@ Out      : r0 = BYTE checksum
@ Clobbers : r1-r3, flags
@ -----------------------------------------------------------------------------
FUNC ff16_sum_sfn
    movs r1, #0                             @ BYTE sum = 0;
    movs r2, #11                            @ UINT n = 11;
1:  lsrs r3, r1, #1                         @ do {  sum = (sum >> 1) + (sum << 7) + *dir++;
    add r3, r3, r1, lsl #7
    ldrb r1, [r0], #1
    add r1, r1, r3
    uxtb r1, r1                             @   (sum is a BYTE)
    subs r2, r2, #1                         @ } while (--n);
    bne 1b
    mov r0, r1                              @ return sum;
    bx lr
ENDFUNC ff16_sum_sfn

@ -----------------------------------------------------------------------------
@ xdir_sum - checksum of an exFAT directory entry block (ff.c xdir_sum)
@ In       : r0 = dir (entry block; dir[1] = number of secondary entries)
@ Out      : r0 = WORD checksum
@ Clobbers : r1-r3, r12, flags
@ Registers: r1 szblk, r2 i, r3 sum
@ -----------------------------------------------------------------------------
FUNC ff16_xdir_sum
    ldrb r1, [r0, #XDIR_NumSec]             @ szblk = ((UINT)dir[XDIR_NumSec] + 1) * SZDIRE;
    adds r1, r1, #1
    lsls r1, r1, #5
    movs r2, #0                             @ for (i = sum = 0; i < szblk; i++) {
    movs r3, #0
1:  cmp r2, r1
    bhs 4f
    cmp r2, #XDIR_SetSum                    @   if (i == XDIR_SetSum) {
    bne 2f
    adds r2, r2, #2                         @     i++;   (skip the checksum field: this and the loop's i++ skip bytes 2 and 3)
    b 1b
2:  ldrb r12, [r0, r2]                      @   } else { sum = ((sum & 1) ? 0x8000 : 0) + (sum >> 1) + dir[i]; }
    add r12, r12, r3, lsr #1
    tst r3, #1
    it ne
    addne r12, r12, #0x8000
    uxth r3, r12                            @   (sum is a WORD)
    adds r2, r2, #1                         @ }
    b 1b
4:  mov r0, r3                              @ return sum;
    bx lr
ENDFUNC ff16_xdir_sum

@ -----------------------------------------------------------------------------
@ xname_sum - hash of an up-cased exFAT file name (ff.c xname_sum)
@ In       : r0 = name (WCHAR[], zero terminated)
@ Out      : r0 = WORD hash
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 name, r5 sum, r6 chr
@ -----------------------------------------------------------------------------
FUNC ff16_xname_sum
    push {r4, r5, r6, lr}
    mov r4, r0
    movs r5, #0                             @ WORD sum = 0;
1:  ldrh r6, [r4], #2                       @ while ((chr = *name++) != 0) {
    cmp r6, #0
    beq 3f
    mov r0, r6
    bl ff16_ff_wtoupper                     @   chr = (WCHAR)ff_wtoupper(chr);
    uxth r6, r0
    uxtb r0, r6                             @   sum = ((sum & 1) ? 0x8000 : 0) + (sum >> 1) + (chr & 0xFF);
    add r0, r0, r5, lsr #1
    tst r5, #1
    it ne
    addne r0, r0, #0x8000
    uxth r5, r0
    lsrs r0, r6, #8                         @   sum = ((sum & 1) ? 0x8000 : 0) + (sum >> 1) + (chr >> 8);
    add r0, r0, r5, lsr #1
    tst r5, #1
    it ne
    addne r0, r0, #0x8000
    uxth r5, r0
    b 1b                                    @ }
3:  mov r0, r5                              @ return sum;
    pop {r4, r5, r6, pc}
ENDFUNC ff16_xname_sum

    .if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ xsum32 - one step of the exFAT 32-bit checksum (ff.c xsum32), read/write build only
@ In       : r0 = dat (BYTE), r1 = sum
@ Out      : r0 = new sum
@ Clobbers : -
@ sum = ((sum & 1) ? 0x80000000 : 0) + (sum >> 1) + dat  is  ror(sum, 1) + dat  (the bit shifted out of bit 0 re-enters
@ at bit 31 and the two parts share no bit).
@ -----------------------------------------------------------------------------
FUNC ff16_xsum32
    uxtb r0, r0
    add r0, r0, r1, ror #1
    bx lr
ENDFUNC ff16_xsum32
    .endif

@ -----------------------------------------------------------------------------
@ load_xdir - load and verify an exFAT directory entry block (85, C0, C1...) into fs->dirbuf (ff.c load_xdir)
@ In       : r0 = dp (positioned at a File Directory entry, 0x85)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 dirb, r6 i, r7 sz_ent
@ -----------------------------------------------------------------------------
FUNC ff16_load_xdir
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    ldr r0, [r4, #OBJ_FS]
    ldr r5, [r0, #FS_DIRBUF]                @ BYTE *dirb = dp->obj.fs->dirbuf;
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @ res = move_window(dp->obj.fs, dp->sect);
    cmp r0, #FR_OK                          @ if (res != FR_OK) return res;
    bne .Lb_lx_ret
    ldr r1, [r4, #DIR_DIR]                  @ if (dp->dir[XDIR_Type] != ET_FILEDIR) return FR_INT_ERR;
    ldrb r0, [r1, #XDIR_Type]
    cmp r0, #ET_FILEDIR
    bne .Lb_lx_int
    mov r0, r5                              @ memcpy(dirb + 0 * SZDIRE, dp->dir, SZDIRE);
    movs r2, #SZDIRE
    bl ff16_mem_cpy
    ldrb r7, [r5, #XDIR_NumSec]             @ sz_ent = ((UINT)dirb[XDIR_NumSec] + 1) * SZDIRE;
    adds r7, r7, #1
    lsls r7, r7, #5
    cmp r7, #(3 * SZDIRE)                   @ if (sz_ent < 3 * SZDIRE || sz_ent > 19 * SZDIRE) return FR_INT_ERR;
    blo .Lb_lx_int
    cmp r7, #(19 * SZDIRE)
    bhi .Lb_lx_int
    mov r0, r4                              @ res = dir_next(dp, 0);
    movs r1, #0
    bl ff16_dir_next
    cmp r0, #FR_NO_FILE                     @ if (res == FR_NO_FILE) res = FR_INT_ERR;
    it eq
    moveq r0, #FR_INT_ERR
    cmp r0, #FR_OK                          @ if (res != FR_OK) return res;
    bne .Lb_lx_ret
    ldr r0, [r4, #OBJ_FS]
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @ res = move_window(dp->obj.fs, dp->sect);
    cmp r0, #FR_OK                          @ if (res != FR_OK) return res;
    bne .Lb_lx_ret
    ldr r1, [r4, #DIR_DIR]                  @ if (dp->dir[XDIR_Type] != ET_STREAM) return FR_INT_ERR;
    ldrb r0, [r1, #XDIR_Type]
    cmp r0, #ET_STREAM
    bne .Lb_lx_int
    adds r0, r5, #SZDIRE                    @ memcpy(dirb + 1 * SZDIRE, dp->dir, SZDIRE);
    movs r2, #SZDIRE
    bl ff16_mem_cpy
    ldrb r0, [r5, #XDIR_NumName]            @ if (((dirb[XDIR_NumName] + 44U) / 15 * SZDIRE) > sz_ent) return FR_INT_ERR;
    adds r0, r0, #44
    movs r1, #15
    udiv r0, r0, r1
    lsls r0, r0, #5
    cmp r0, r7
    bhi .Lb_lx_int
    movs r6, #(2 * SZDIRE)                  @ i = 2 * SZDIRE;
1:  mov r0, r4                              @ do {  res = dir_next(dp, 0);
    movs r1, #0
    bl ff16_dir_next
    cmp r0, #FR_NO_FILE                     @   if (res == FR_NO_FILE) res = FR_INT_ERR;
    it eq
    moveq r0, #FR_INT_ERR
    cmp r0, #FR_OK                          @   if (res != FR_OK) return res;
    bne .Lb_lx_ret
    ldr r0, [r4, #OBJ_FS]
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @   res = move_window(dp->obj.fs, dp->sect);
    cmp r0, #FR_OK                          @   if (res != FR_OK) return res;
    bne .Lb_lx_ret
    ldr r1, [r4, #DIR_DIR]                  @   if (dp->dir[XDIR_Type] != ET_FILENAME) return FR_INT_ERR;
    ldrb r0, [r1, #XDIR_Type]
    cmp r0, #ET_FILENAME
    bne .Lb_lx_int
    cmp r6, #FFXB_DIRBUF_SZ                 @   if (i < MAXDIRB(FF_MAX_LFN)) memcpy(dirb + i, dp->dir, SZDIRE);
    bhs 2f
    add r0, r5, r6
    movs r2, #SZDIRE
    bl ff16_mem_cpy
2:  adds r6, r6, #SZDIRE                    @ } while ((i += SZDIRE) < sz_ent);
    cmp r6, r7
    blo 1b
    cmp r6, #FFXB_DIRBUF_SZ                 @ if (i <= MAXDIRB(FF_MAX_LFN)) {
    bhi 3f
    mov r0, r5                              @   if (xdir_sum(dirb) != ld_16(dirb + XDIR_SetSum)) return FR_INT_ERR;
    bl ff16_xdir_sum
    ldrb r1, [r5, #XDIR_SetSum]
    ldrb r2, [r5, #(XDIR_SetSum + 1)]
    orr r1, r1, r2, lsl #8
    cmp r0, r1
    bne .Lb_lx_int
3:  movs r0, #FR_OK                         @ } return FR_OK;
    b .Lb_lx_ret
.Lb_lx_int:
    movs r0, #FR_INT_ERR
.Lb_lx_ret:
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_load_xdir

@ -----------------------------------------------------------------------------
@ init_alloc_info - set the allocation info of an exFAT object from the loaded entry block (ff.c init_alloc_info)
@ In       : r0 = dobj (FFOBJID to fill), r1 = sdir (DIR holding the object, or 0)
@ Out      : -
@ Clobbers : r1-r3, r12, flags
@ Registers: r2 fs->dirbuf (after the sdir part), r3, r12 scratch
@ -----------------------------------------------------------------------------
FUNC ff16_init_alloc_info
    ldr r2, [r0, #OBJ_FS]                   @ FATFS *fs = dobj->fs;
    cmp r1, #0                              @ if (sdir) {
    beq 1f
    ldr r3, [r1, #OBJ_SCLUST]               @   dobj->c_scl = sdir->obj.sclust;
    str r3, [r0, #OBJ_C_SCL]
    ldr r3, [r1, #OBJ_OBJSIZE]              @   dobj->c_size = ((DWORD)sdir->obj.objsize & 0xFFFFFF00) | sdir->obj.stat;
    bic r3, r3, #0xFF
    ldrb r12, [r1, #OBJ_STAT]
    orr r3, r3, r12
    str r3, [r0, #OBJ_C_SIZE]
    ldr r3, [r1, #DIR_BLK_OFS]              @   dobj->c_ofs = sdir->blk_ofs;
    str r3, [r0, #OBJ_C_OFS]
1:  ldr r2, [r2, #FS_DIRBUF]                @ }  r2 = fs->dirbuf
    ldrb r3, [r2, #(XDIR_FstClus + 3)]      @ dobj->sclust = ld_32(fs->dirbuf + XDIR_FstClus);
    ldrb r12, [r2, #(XDIR_FstClus + 2)]
    orr r3, r12, r3, lsl #8
    ldrb r12, [r2, #(XDIR_FstClus + 1)]
    orr r3, r12, r3, lsl #8
    ldrb r12, [r2, #(XDIR_FstClus + 0)]
    orr r3, r12, r3, lsl #8
    str r3, [r0, #OBJ_SCLUST]
    ldrb r3, [r2, #(XDIR_FileSize + 3)]     @ dobj->objsize = ld_64(fs->dirbuf + XDIR_FileSize);   low 32 bits (offset 16)
    ldrb r12, [r2, #(XDIR_FileSize + 2)]
    orr r3, r12, r3, lsl #8
    ldrb r12, [r2, #(XDIR_FileSize + 1)]
    orr r3, r12, r3, lsl #8
    ldrb r12, [r2, #(XDIR_FileSize + 0)]
    orr r3, r12, r3, lsl #8
    str r3, [r0, #OBJ_OBJSIZE]
    ldrb r3, [r2, #(XDIR_FileSize + 7)]     @                                                      high 32 bits (offset 20)
    ldrb r12, [r2, #(XDIR_FileSize + 6)]
    orr r3, r12, r3, lsl #8
    ldrb r12, [r2, #(XDIR_FileSize + 5)]
    orr r3, r12, r3, lsl #8
    ldrb r12, [r2, #(XDIR_FileSize + 4)]
    orr r3, r12, r3, lsl #8
    str r3, [r0, #(OBJ_OBJSIZE + 4)]
    ldrb r3, [r2, #XDIR_GenFlags]           @ dobj->stat = fs->dirbuf[XDIR_GenFlags] & 2;
    and r3, r3, #2
    strb r3, [r0, #OBJ_STAT]
    movs r3, #0                             @ dobj->n_frag = 0;
    str r3, [r0, #OBJ_N_FRAG]
    bx lr
ENDFUNC ff16_init_alloc_info

    .if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ load_obj_xdir - load the entry block of an object from its recorded directory position (ff.c load_obj_xdir),
@ read/write build only
@ In       : r0 = dp, r1 = obj (FFOBJID with c_scl / c_size / c_ofs set)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp
@ -----------------------------------------------------------------------------
FUNC ff16_load_obj_xdir
    push {r4, lr}
    mov r4, r0
    ldr r2, [r1, #OBJ_FS]                   @ dp->obj.fs = obj->fs;
    str r2, [r4, #OBJ_FS]
    ldr r2, [r1, #OBJ_C_SCL]                @ dp->obj.sclust = obj->c_scl;
    str r2, [r4, #OBJ_SCLUST]
    ldr r2, [r1, #OBJ_C_SIZE]               @ dp->obj.stat = (BYTE)obj->c_size;
    strb r2, [r4, #OBJ_STAT]
    bic r2, r2, #0xFF                       @ dp->obj.objsize = obj->c_size & 0xFFFFFF00;   (DWORD, zero-extended to 64 bits)
    str r2, [r4, #OBJ_OBJSIZE]
    movs r3, #0
    str r3, [r4, #(OBJ_OBJSIZE + 4)]
    str r3, [r4, #OBJ_N_FRAG]               @ dp->obj.n_frag = 0;
    ldr r2, [r1, #OBJ_C_OFS]                @ dp->blk_ofs = obj->c_ofs;
    str r2, [r4, #DIR_BLK_OFS]
    mov r0, r4
    mov r1, r2
    bl ff16_dir_sdi                         @ res = dir_sdi(dp, dp->blk_ofs);
    cmp r0, #FR_OK                          @ if (res == FR_OK) {
    bne 1f
    mov r0, r4
    bl ff16_load_xdir                       @   res = load_xdir(dp);
1:  pop {r4, pc}                            @ } return res;
ENDFUNC ff16_load_obj_xdir

@ -----------------------------------------------------------------------------
@ store_xdir - write the entry block in fs->dirbuf back to the directory (ff.c store_xdir), read/write build only
@ In       : r0 = dp (dp->blk_ofs = offset of the block in the directory)
@ Out      : r0 = FRESULT (FR_OK, FR_DISK_ERR or FR_INT_ERR)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 dirb, r6 nent, r7 res
@ -----------------------------------------------------------------------------
FUNC ff16_store_xdir
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    ldr r0, [r4, #OBJ_FS]
    ldr r5, [r0, #FS_DIRBUF]                @ BYTE *dirb = dp->obj.fs->dirbuf;
    mov r0, r5
    bl ff16_xdir_sum                        @ st_16(dirb + XDIR_SetSum, xdir_sum(dirb));
    strb r0, [r5, #XDIR_SetSum]
    lsrs r0, r0, #8
    strb r0, [r5, #(XDIR_SetSum + 1)]
    ldrb r6, [r5, #XDIR_NumSec]             @ nent = dirb[XDIR_NumSec] + 1;
    adds r6, r6, #1
    mov r0, r4
    ldr r1, [r4, #DIR_BLK_OFS]
    bl ff16_dir_sdi                         @ res = dir_sdi(dp, dp->blk_ofs);
    mov r7, r0
1:  cmp r7, #FR_OK                          @ while (res == FR_OK) {
    bne 2f
    ldr r0, [r4, #OBJ_FS]
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @   res = move_window(dp->obj.fs, dp->sect);
    mov r7, r0
    cmp r7, #FR_OK                          @   if (res != FR_OK) break;
    bne 2f
    ldr r0, [r4, #DIR_DIR]                  @   memcpy(dp->dir, dirb, SZDIRE);
    mov r1, r5
    movs r2, #SZDIRE
    bl ff16_mem_cpy
    ldr r0, [r4, #OBJ_FS]                   @   dp->obj.fs->wflag = 1;
    movs r1, #1
    strb r1, [r0, #FS_WFLAG]
    subs r6, r6, #1                         @   if (--nent == 0) break;
    beq 2f
    adds r5, r5, #SZDIRE                    @   dirb += SZDIRE;
    mov r0, r4
    movs r1, #0
    bl ff16_dir_next                        @   res = dir_next(dp, 0);
    mov r7, r0
    b 1b                                    @ }
2:  cmp r7, #FR_OK                          @ return (res == FR_OK || res == FR_DISK_ERR) ? res : FR_INT_ERR;
    beq 3f
    cmp r7, #FR_DISK_ERR
    beq 3f
    movs r7, #FR_INT_ERR
3:  mov r0, r7
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_store_xdir

@ -----------------------------------------------------------------------------
@ create_xdir - build a File, Stream and File Name entry block for a name in fs->dirbuf (ff.c create_xdir),
@ read/write build only
@ In       : r0 = dirb (entry block buffer), r1 = lfn (WCHAR[], zero terminated)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Registers: r4 dirb, r5 lfn, r6 i, r7 nlen (BYTE), r8 n_c1 (BYTE), r9 chr
@ -----------------------------------------------------------------------------
FUNC ff16_create_xdir
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    mov r4, r0
    mov r5, r1
    movs r1, #0                             @ memset(dirb, 0, 2 * SZDIRE);
    movs r2, #(2 * SZDIRE)
    bl ff16_mem_set
    movs r0, #ET_FILEDIR                    @ dirb[0 * SZDIRE + XDIR_Type] = ET_FILEDIR;
    strb r0, [r4, #(0 * SZDIRE + XDIR_Type)]
    movs r0, #ET_STREAM                     @ dirb[1 * SZDIRE + XDIR_Type] = ET_STREAM;
    strb r0, [r4, #(1 * SZDIRE + XDIR_Type)]
    movs r6, #(SZDIRE * 2)                  @ i = SZDIRE * 2;
    movs r7, #0                             @ nlen = n_c1 = 0; chr = 1;
    movs r8, #0
    movs r9, #1
1:  movs r0, #ET_FILENAME                   @ do {  dirb[i++] = ET_FILENAME;
    strb r0, [r4, r6]
    adds r6, r6, #1
    movs r0, #0                             @   dirb[i++] = 0;
    strb r0, [r4, r6]
    adds r6, r6, #1
2:  cmp r9, #0                              @   do {  if (chr != 0 && (chr = lfn[nlen]) != 0) nlen++;
    beq 3f
    ldrh r9, [r5, r7, lsl #1]
    cmp r9, #0
    beq 3f
    adds r7, r7, #1
    uxtb r7, r7                             @   (nlen is a BYTE)
3:  strb r9, [r4, r6]                       @     st_16(dirb + i, chr);
    adds r0, r6, #1
    lsrs r1, r9, #8
    strb r1, [r4, r0]
    adds r6, r6, #2                         @     i += 2;
    tst r6, #(SZDIRE - 1)                   @   } while (i % SZDIRE != 0);
    bne 2b
    adds r8, r8, #1                         @   n_c1++;   (BYTE)
    uxtb r8, r8
    ldrh r0, [r5, r7, lsl #1]               @ } while (lfn[nlen]);
    cmp r0, #0
    bne 1b
    strb r7, [r4, #XDIR_NumName]            @ dirb[XDIR_NumName] = nlen;
    adds r0, r8, #1                         @ dirb[XDIR_NumSec] = 1 + n_c1;
    strb r0, [r4, #XDIR_NumSec]
    mov r0, r5
    bl ff16_xname_sum                       @ st_16(dirb + XDIR_NameHash, xname_sum(lfn));
    strb r0, [r4, #XDIR_NameHash]
    lsrs r0, r0, #8
    strb r0, [r4, #(XDIR_NameHash + 1)]
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_create_xdir
    .endif
