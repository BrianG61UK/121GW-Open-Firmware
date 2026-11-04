@ =============================================================================
@ ff16_low.s - FatFs R0.16 (production image): memory helpers, byte-order loads and stores, DBCS tests, the sector
@ window, FSINFO, cluster to sector, FAT access and cluster chains (DESIGN.md 7A, IMP-29)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c), configuration of DESIGN.md 7A.  Each routine names the C function
@ it translates; the code follows the C statements in order, the comments quote them.  Calling convention AAPCS (r0-r3,
@ r12 scratch, r4-r11 preserved), as the C functions.  (The FatFs R0.08a port of v2.05 is on the branch like-v2.05.)
@
@ FatFs license (ChaN): "FatFs module is an open source software. Redistribution and use of FatFs in source and binary forms,
@ with or without modification, are permitted provided that the following condition is met: 1. Redistributions of source
@ code must retain the above copyright notice, this condition and the following disclaimer.  This software is provided by
@ the copyright holder and contributors "AS IS" and any warranties related to this software are DISCLAIMED.  The copyright
@ owner or contributors be NOT LIABLE for any damages caused by use of this software."  Copyright (C) 2025, ChaN, all right
@ reserved.
@
@ Structure offsets (ff16.inc): FATFS, FFOBJID, FIL, DIR, FILINFO as measured for this configuration.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "config.inc"

    .include "ff16.inc"

    .section .text.ff16.low, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ff16_memcpy - memcpy(dst, src, n) as used by ff.c (byte copy, regions do not overlap)
@ In       : r0 = dst, r1 = src, r2 = n
@ Out      : r0 = dst
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_memcpy
    mov r12, r0
1:  cbz r2, 2f
    ldrb r3, [r1], #1
    strb r3, [r12], #1
    subs r2, r2, #1
    b 1b
2:  bx lr
ENDFUNC ff16_memcpy

@ -----------------------------------------------------------------------------
@ ff16_memset - memset(dst, val, n)
@ In       : r0 = dst, r1 = val (low byte), r2 = n
@ Out      : r0 = dst
@ Clobbers : r2, r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_memset
    mov r12, r0
1:  cbz r2, 2f
    strb r1, [r12], #1
    subs r2, r2, #1
    b 1b
2:  bx lr
ENDFUNC ff16_memset

@ -----------------------------------------------------------------------------
@ ff16_memcmp - memcmp(a, b, n): ff.c uses only "== 0" / "!= 0"
@ In       : r0 = a, r1 = b, r2 = n
@ Out      : r0 = 0 equal, else the difference of the first different bytes (a[i] - b[i])
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_memcmp
    mov r12, r0
1:  cbz r2, 3f
    ldrb r0, [r12], #1
    ldrb r3, [r1], #1
    subs r0, r0, r3
    bne 2f
    subs r2, r2, #1
    b 1b
2:  bx lr
3:  movs r0, #0
    bx lr
ENDFUNC ff16_memcmp

@ -----------------------------------------------------------------------------
@ ld_16 / ld_32 / st_16 / st_32 - little-endian loads and stores at any alignment (ff.c ld_16, ld_32, st_16, st_32)
@ ld_*: In r0 = ptr; Out r0 = value; Clobbers r1, r2.   st_*: In r0 = ptr, r1 = value; Clobbers r1, r2.
@ -----------------------------------------------------------------------------
FUNC ff16_ld_16
    ldrb r1, [r0, #1]                       @ rv = ptr[1]
    ldrb r0, [r0, #0]
    orr r0, r0, r1, lsl #8                  @ rv = rv << 8 | ptr[0]
    bx lr
ENDFUNC ff16_ld_16

FUNC ff16_ld_32
    ldrb r1, [r0, #3]                       @ rv = ptr[3]
    ldrb r2, [r0, #2]
    orr r1, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[2]
    ldrb r2, [r0, #1]
    orr r1, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[1]
    ldrb r2, [r0, #0]
    orr r0, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[0]
    bx lr
ENDFUNC ff16_ld_32

FUNC ff16_st_16
    strb r1, [r0, #0]                       @ *ptr++ = (BYTE)val; val >>= 8
    lsrs r1, r1, #8
    strb r1, [r0, #1]                       @ *ptr++ = (BYTE)val
    bx lr
ENDFUNC ff16_st_16

FUNC ff16_st_32
    strb r1, [r0, #0]
    lsrs r1, r1, #8
    strb r1, [r0, #1]
    lsrs r1, r1, #8
    strb r1, [r0, #2]
    lsrs r1, r1, #8
    strb r1, [r0, #3]
    bx lr
ENDFUNC ff16_st_32

@ -----------------------------------------------------------------------------
@ dbc_1st / dbc_2nd - DBCS lead / trail byte tests of code page 932 (ff.c dbc_1st, dbc_2nd with DbcTbl of CP932:
@ {0x81, 0x9F, 0xE0, 0xFC, 0x40, 0x7E, 0x80, 0xFC, 0x00, 0x00})
@ In       : r0 = byte
@ Out      : r0 = 1 / 0
@ Clobbers : flags
@ -----------------------------------------------------------------------------
FUNC ff16_dbc_1st
    cmp r0, #0x81                           @ if (c >= DbcTbl[0]) {
    blo 1f
    cmp r0, #0x9F                           @   if (c <= DbcTbl[1]) return 1;
    bls 2f
    cmp r0, #0xE0                           @   if (c >= DbcTbl[2] && c <= DbcTbl[3]) return 1;
    blo 1f
    cmp r0, #0xFC
    bls 2f
1:  movs r0, #0                             @ return 0
    bx lr
2:  movs r0, #1
    bx lr
ENDFUNC ff16_dbc_1st

FUNC ff16_dbc_2nd
    cmp r0, #0x40                           @ if (c >= DbcTbl[4]) {
    blo 1f
    cmp r0, #0x7E                           @   if (c <= DbcTbl[5]) return 1;
    bls 2f
    cmp r0, #0x80                           @   if (c >= DbcTbl[6] && c <= DbcTbl[7]) return 1;
    blo 1f
    cmp r0, #0xFC
    bls 2f
    @ if (c >= DbcTbl[8] && c <= DbcTbl[9]) return 1;  DbcTbl[8..9] = 0x00, 0x00: only c == 0, below DbcTbl[4]
1:  movs r0, #0
    bx lr
2:  movs r0, #1
    bx lr
ENDFUNC ff16_dbc_2nd

@ -----------------------------------------------------------------------------
@ sync_window - write back the window if dirty (ff.c sync_window)
@ In       : r0 = fs
@ Out      : r0 = FR_OK / FR_DISK_ERR
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_sync_window
    push {r4, lr}
    mov r4, r0
    ldrb r0, [r4, #FS_WFLAG]                @ if (fs->wflag) {
    cbz r0, 2f
    ldrb r0, [r4, #FS_PDRV]                 @   if (disk_write(fs->pdrv, fs->win, fs->winsect, 1) == RES_OK) {
    add r1, r4, #FS_WIN
    ldr r2, [r4, #FS_WINSECT]
    movs r3, #1
    bl disk_write
    cbnz r0, 3f
    movs r0, #0
    strb r0, [r4, #FS_WFLAG]                @     fs->wflag = 0;
    ldr r2, [r4, #FS_WINSECT]               @     if (fs->winsect - fs->fatbase < fs->fsize) {
    ldr r1, [r4, #FS_FATBASE]
    subs r1, r2, r1
    ldr r3, [r4, #FS_FSIZE]
    cmp r1, r3
    bhs 2f
    ldrb r0, [r4, #FS_N_FATS]               @       if (fs->n_fats == 2) disk_write(fs->pdrv, fs->win, fs->winsect + fs->fsize, 1);
    cmp r0, #2
    bne 2f
    add r2, r2, r3
    ldrb r0, [r4, #FS_PDRV]
    add r1, r4, #FS_WIN
    movs r3, #1
    bl disk_write                           @       (result not used, as in ff.c)
2:  movs r0, #FR_OK                         @ return res (FR_OK)
    pop {r4, pc}
3:  movs r0, #FR_DISK_ERR                   @   } else { res = FR_DISK_ERR; }
    pop {r4, pc}
ENDFUNC ff16_sync_window

@ -----------------------------------------------------------------------------
@ move_window - load a sector into the window (ff.c move_window)
@ In       : r0 = fs, r1 = sect
@ Out      : r0 = FR_OK / FR_DISK_ERR
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_move_window
    push {r4, r5, r6, lr}
    mov r4, r0
    mov r5, r1
    ldr r0, [r4, #FS_WINSECT]               @ if (sect != fs->winsect) {
    cmp r5, r0
    beq 2f
    mov r0, r4
    bl ff16_sync_window                     @   res = sync_window(fs);
    mov r6, r0
    cbnz r6, 3f                             @   if (res == FR_OK) {
    ldrb r0, [r4, #FS_PDRV]                 @     if (disk_read(fs->pdrv, fs->win, sect, 1) != RES_OK) {
    add r1, r4, #FS_WIN
    mov r2, r5
    movs r3, #1
    bl disk_read
    cbz r0, 1f
    mov r5, #0xFFFFFFFF                     @       sect = (LBA_t)0 - 1;
    movs r6, #FR_DISK_ERR                   @       res = FR_DISK_ERR;
1:  str r5, [r4, #FS_WINSECT]               @     fs->winsect = sect;
3:  mov r0, r6                              @ return res
    pop {r4, r5, r6, pc}
2:  movs r0, #FR_OK
    pop {r4, r5, r6, pc}
ENDFUNC ff16_move_window

@ -----------------------------------------------------------------------------
@ sync_fs - synchronise the file system: window, FSINFO (FAT32), device (ff.c sync_fs)
@ In       : r0 = fs
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_sync_fs
    push {r4, r5, r6, lr}
    mov r4, r0
    bl ff16_sync_window                     @ res = sync_window(fs);
    mov r5, r0
    cbnz r5, 9f                             @ if (res == FR_OK) {
    ldrb r0, [r4, #FS_FSI_FLAG]             @   if (fs->fsi_flag == 1) {
    cmp r0, #1
    bne 5f
    movs r0, #0
    strb r0, [r4, #FS_FSI_FLAG]             @     fs->fsi_flag = 0;
    ldrb r0, [r4, #FS_FS_TYPE]              @     if (fs->fs_type == FS_FAT32) {
    cmp r0, #FS_FAT32
    bne 5f
    add r6, r4, #FS_WIN
    mov r0, r6
    movs r1, #0
    mov r2, #512
    bl ff16_memset                          @       memset(fs->win, 0, sizeof fs->win);
    mov r0, r6
    ldr r1, =0x41615252
    bl ff16_st_32                           @       st_32(fs->win + FSI_LeadSig, 0x41615252);
    add r0, r6, #484
    ldr r1, =0x61417272
    bl ff16_st_32                           @       st_32(fs->win + FSI_StrucSig, 0x61417272);
    add r0, r6, #488
    ldr r1, [r4, #FS_FREE_CLST]
    bl ff16_st_32                           @       st_32(fs->win + FSI_Free_Count, fs->free_clst);
    add r0, r6, #492
    ldr r1, [r4, #FS_LAST_CLST]
    bl ff16_st_32                           @       st_32(fs->win + FSI_Nxt_Free, fs->last_clst);
    add r0, r6, #508
    ldr r1, =0xAA550000
    bl ff16_st_32                           @       st_32(fs->win + BS_55AA, 0xAA550000);
    ldr r2, [r4, #FS_VOLBASE]
    adds r2, r2, #1
    str r2, [r4, #FS_WINSECT]               @       disk_write(fs->pdrv, fs->win, fs->winsect = fs->volbase + 1, 1);
    ldrb r0, [r4, #FS_PDRV]
    mov r1, r6
    movs r3, #1
    bl disk_write
5:  ldrb r0, [r4, #FS_PDRV]                 @   if (disk_ioctl(fs->pdrv, CTRL_SYNC, 0) != RES_OK) res = FR_DISK_ERR;
    movs r1, #0
    movs r2, #0
    bl disk_ioctl
    cbz r0, 9f
    movs r5, #FR_DISK_ERR
9:  mov r0, r5
    pop {r4, r5, r6, pc}
    .ltorg
ENDFUNC ff16_sync_fs

@ -----------------------------------------------------------------------------
@ clst2sect - first sector of a cluster (ff.c clst2sect)
@ In       : r0 = fs, r1 = clst
@ Out      : r0 = sector, 0 for an invalid cluster
@ Clobbers : r1, r2, flags
@ -----------------------------------------------------------------------------
FUNC ff16_clst2sect
    subs r1, r1, #2                         @ clst -= 2;
    ldr r2, [r0, #FS_N_FATENT]
    subs r2, r2, #2
    cmp r1, r2                              @ if (clst >= fs->n_fatent - 2) return 0;
    bhs 1f
    ldrh r2, [r0, #FS_CSIZE]
    ldr r0, [r0, #FS_DATABASE]
    mla r0, r2, r1, r0                      @ return fs->database + (LBA_t)fs->csize * clst;
    bx lr
1:  movs r0, #0
    bx lr
ENDFUNC ff16_clst2sect

@ -----------------------------------------------------------------------------
@ get_fat - read a FAT entry (ff.c get_fat)
@ In       : r0 = obj (FFOBJID*), r1 = clst
@ Out      : r0 = entry, 1 internal error (cluster out of range), 0xFFFFFFFF disk error
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_get_fat
    push {r4, r5, r6, r7, lr}
    ldr r4, [r0, #OBJ_FS]                   @ FATFS *fs = obj->fs;
    mov r5, r1
    cmp r5, #2                              @ if (clst < 2 || clst >= fs->n_fatent) { val = 1; }
    blo .Lgf_one
    ldr r0, [r4, #FS_N_FATENT]
    cmp r5, r0
    bhs .Lgf_one
    ldrb r0, [r4, #FS_FS_TYPE]              @ switch (fs->fs_type) {
    cmp r0, #FS_FAT12
    beq .Lgf_fat12
    cmp r0, #FS_FAT16
    beq .Lgf_fat16
    cmp r0, #FS_FAT32
    beq .Lgf_fat32
.Lgf_one:
    movs r0, #1                             @ default: val = 1;
    pop {r4, r5, r6, r7, pc}
.Lgf_fat12:
    add r6, r5, r5, lsr #1                  @ bc = (UINT)clst; bc += bc / 2;
    ldr r1, [r4, #FS_FATBASE]
    add r1, r1, r6, lsr #9                  @ if (move_window(fs, fs->fatbase + (bc / SS(fs))) != FR_OK) break;
    mov r0, r4
    bl ff16_move_window
    cbnz r0, .Lgf_err
    ubfx r0, r6, #0, #9
    add r0, r0, r4
    ldrb r7, [r0, #FS_WIN]                  @ wc = fs->win[bc++ % SS(fs)];
    adds r6, r6, #1
    ldr r1, [r4, #FS_FATBASE]
    add r1, r1, r6, lsr #9                  @ if (move_window(fs, fs->fatbase + (bc / SS(fs))) != FR_OK) break;
    mov r0, r4
    bl ff16_move_window
    cbnz r0, .Lgf_err
    ubfx r0, r6, #0, #9
    add r0, r0, r4
    ldrb r0, [r0, #FS_WIN]
    orr r7, r7, r0, lsl #8                  @ wc |= fs->win[bc % SS(fs)] << 8;
    tst r5, #1                              @ val = (clst & 1) ? (wc >> 4) : (wc & 0xFFF);
    ite ne
    lsrne r0, r7, #4
    ubfxeq r0, r7, #0, #12
    pop {r4, r5, r6, r7, pc}
.Lgf_fat16:
    ldr r1, [r4, #FS_FATBASE]
    add r1, r1, r5, lsr #8                  @ if (move_window(fs, fs->fatbase + (clst / (SS(fs) / 2))) != FR_OK) break;
    mov r0, r4
    bl ff16_move_window
    cbnz r0, .Lgf_err
    lsls r0, r5, #1
    ubfx r0, r0, #0, #9
    add r0, r0, r4
    adds r0, r0, #FS_WIN
    bl ff16_ld_16                           @ val = ld_16(fs->win + clst * 2 % SS(fs));
    pop {r4, r5, r6, r7, pc}
.Lgf_fat32:
    ldr r1, [r4, #FS_FATBASE]
    add r1, r1, r5, lsr #7                  @ if (move_window(fs, fs->fatbase + (clst / (SS(fs) / 4))) != FR_OK) break;
    mov r0, r4
    bl ff16_move_window
    cbnz r0, .Lgf_err
    lsls r0, r5, #2
    ubfx r0, r0, #0, #9
    add r0, r0, r4
    adds r0, r0, #FS_WIN
    bl ff16_ld_32
    bic r0, r0, #0xF0000000                 @ val = ld_32(fs->win + clst * 4 % SS(fs)) & 0x0FFFFFFF;
    pop {r4, r5, r6, r7, pc}
.Lgf_err:
    mov r0, #0xFFFFFFFF                     @ val = 0xFFFFFFFF (disk error: the break of the switch)
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_get_fat

@ -----------------------------------------------------------------------------
@ put_fat - write a FAT entry (ff.c put_fat)
@ In       : r0 = fs, r1 = clst, r2 = val
@ Out      : r0 = FRESULT (FR_INT_ERR for a cluster out of range or an unknown FAT type)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_put_fat
    push {r4, r5, r6, r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    cmp r5, #2                              @ if (clst >= 2 && clst < fs->n_fatent) {
    blo .Lpf_int
    ldr r0, [r4, #FS_N_FATENT]
    cmp r5, r0
    bhs .Lpf_int
    ldrb r0, [r4, #FS_FS_TYPE]              @ switch (fs->fs_type) {
    cmp r0, #FS_FAT12
    beq .Lpf_fat12
    cmp r0, #FS_FAT16
    beq .Lpf_fat16
    cmp r0, #FS_FAT32
    beq .Lpf_fat32
.Lpf_int:
    movs r0, #FR_INT_ERR                    @ res = FR_INT_ERR (initial value)
    pop {r4, r5, r6, r7, pc}
.Lpf_fat12:
    add r7, r5, r5, lsr #1                  @ bc = (UINT)clst; bc += bc / 2;
    ldr r1, [r4, #FS_FATBASE]
    add r1, r1, r7, lsr #9                  @ res = move_window(fs, fs->fatbase + (bc / SS(fs)));
    mov r0, r4
    bl ff16_move_window
    cmp r0, #0                       @ if (res != FR_OK) break;
    bne .Lpf_ret
    ubfx r1, r7, #0, #9
    add r1, r1, r4
    adds r1, r1, #FS_WIN                    @ p = fs->win + bc++ % SS(fs);
    adds r7, r7, #1
    tst r5, #1                              @ *p = (clst & 1) ? ((*p & 0x0F) | ((BYTE)val << 4)) : (BYTE)val;
    beq 1f
    ldrb r0, [r1]
    and r0, r0, #0x0F
    lsls r2, r6, #4
    uxtb r2, r2
    orrs r0, r0, r2
    b 2f
1:  uxtb r0, r6
2:  strb r0, [r1]
    movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @ fs->wflag = 1;
    ldr r1, [r4, #FS_FATBASE]
    add r1, r1, r7, lsr #9                  @ res = move_window(fs, fs->fatbase + (bc / SS(fs)));
    mov r0, r4
    bl ff16_move_window
    cmp r0, #0                       @ if (res != FR_OK) break;
    bne .Lpf_ret
    ubfx r1, r7, #0, #9
    add r1, r1, r4
    adds r1, r1, #FS_WIN                    @ p = fs->win + bc % SS(fs);
    tst r5, #1                              @ *p = (clst & 1) ? (BYTE)(val >> 4) : ((*p & 0xF0) | ((BYTE)(val >> 8) & 0x0F));
    beq 3f
    ubfx r0, r6, #4, #8
    b 4f
3:  ldrb r0, [r1]
    and r0, r0, #0xF0
    ubfx r2, r6, #8, #4
    orrs r0, r0, r2
4:  strb r0, [r1]
    movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @ fs->wflag = 1;
    movs r0, #FR_OK
    pop {r4, r5, r6, r7, pc}
.Lpf_fat16:
    ldr r1, [r4, #FS_FATBASE]
    add r1, r1, r5, lsr #8                  @ res = move_window(fs, fs->fatbase + (clst / (SS(fs) / 2)));
    mov r0, r4
    bl ff16_move_window
    cbnz r0, .Lpf_ret
    lsls r0, r5, #1
    ubfx r0, r0, #0, #9
    add r0, r0, r4
    adds r0, r0, #FS_WIN
    uxth r1, r6
    bl ff16_st_16                           @ st_16(fs->win + clst * 2 % SS(fs), (WORD)val);
    movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @ fs->wflag = 1;
    movs r0, #FR_OK
    pop {r4, r5, r6, r7, pc}
.Lpf_fat32:
    ldr r1, [r4, #FS_FATBASE]
    add r1, r1, r5, lsr #7                  @ res = move_window(fs, fs->fatbase + (clst / (SS(fs) / 4)));
    mov r0, r4
    bl ff16_move_window
    cbnz r0, .Lpf_ret
    lsls r7, r5, #2
    ubfx r7, r7, #0, #9
    add r7, r7, r4
    adds r7, r7, #FS_WIN                    @ r7 = fs->win + clst * 4 % SS(fs)
    mov r0, r7
    bl ff16_ld_32
    and r0, r0, #0xF0000000
    bic r1, r6, #0xF0000000
    orrs r1, r1, r0                         @ val = (val & 0x0FFFFFFF) | (ld_32(...) & 0xF0000000);
    mov r0, r7
    bl ff16_st_32                           @ st_32(fs->win + clst * 4 % SS(fs), val);
    movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @ fs->wflag = 1;
    movs r0, #FR_OK
.Lpf_ret:
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_put_fat

@ -----------------------------------------------------------------------------
@ remove_chain - free a cluster chain (ff.c remove_chain, FAT only)
@ In       : r0 = obj, r1 = clst (first cluster to free), r2 = pclst (previous cluster, 0 = the whole chain)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_remove_chain
    push {r4, r5, r6, r7, lr}
    mov r7, r0                              @ r7 = obj
    ldr r4, [r7, #OBJ_FS]                   @ FATFS *fs = obj->fs;
    mov r5, r1
    cmp r5, #2                              @ if (clst < 2 || clst >= fs->n_fatent) return FR_INT_ERR;
    blo .Lrc_int
    ldr r0, [r4, #FS_N_FATENT]
    cmp r5, r0
    bhs .Lrc_int
    cbz r2, 1f                              @ if (pclst != 0 && ...) {
    mov r1, r2
    mov r0, r4
    mov r2, #0xFFFFFFFF
    bl ff16_put_fat                         @   res = put_fat(fs, pclst, 0xFFFFFFFF);
    cbnz r0, .Lrc_ret                       @   if (res != FR_OK) return res;
1:                                          @ do {
    mov r0, r7
    mov r1, r5
    bl ff16_get_fat                         @   nxt = get_fat(obj, clst);
    mov r6, r0
    cbz r6, .Lrc_ok                         @   if (nxt == 0) break;
    cmp r6, #1
    beq .Lrc_int                            @   if (nxt == 1) return FR_INT_ERR;
    cmn r6, #1
    beq .Lrc_disk                           @   if (nxt == 0xFFFFFFFF) return FR_DISK_ERR;
    mov r0, r4
    mov r1, r5
    movs r2, #0
    bl ff16_put_fat                         @   res = put_fat(fs, clst, 0);
    cbnz r0, .Lrc_ret                       @   if (res != FR_OK) return res;
    ldr r0, [r4, #FS_FREE_CLST]             @   if (fs->free_clst < fs->n_fatent - 2) {
    ldr r1, [r4, #FS_N_FATENT]
    subs r1, r1, #2
    cmp r0, r1
    bhs 2f
    adds r0, r0, #1
    str r0, [r4, #FS_FREE_CLST]             @     fs->free_clst++;
    ldrb r0, [r4, #FS_FSI_FLAG]
    orr r0, r0, #1
    strb r0, [r4, #FS_FSI_FLAG]             @     fs->fsi_flag |= 1;
2:  mov r5, r6                              @   clst = nxt;
    ldr r0, [r4, #FS_N_FATENT]
    cmp r5, r0
    blo 1b                                  @ } while (clst < fs->n_fatent);
.Lrc_ok:
    movs r0, #FR_OK
.Lrc_ret:
    pop {r4, r5, r6, r7, pc}
.Lrc_int:
    movs r0, #FR_INT_ERR
    pop {r4, r5, r6, r7, pc}
.Lrc_disk:
    movs r0, #FR_DISK_ERR
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_remove_chain

@ -----------------------------------------------------------------------------
@ create_chain - stretch or create a cluster chain (ff.c create_chain, FAT only)
@ In       : r0 = obj, r1 = clst (0 = create a new chain, else the cluster to stretch)
@ Out      : r0 = 0 no free cluster, 1 internal error, 0xFFFFFFFF disk error, else the new cluster
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fs, r5 clst, r6 scl, r7 ncl, r8 obj, r9 cs, r10 res
@ -----------------------------------------------------------------------------
FUNC ff16_create_chain
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    mov r8, r0
    ldr r4, [r8, #OBJ_FS]                   @ FATFS *fs = obj->fs;
    mov r5, r1
    cbnz r5, 1f                             @ if (clst == 0) {
    ldr r6, [r4, #FS_LAST_CLST]             @   scl = fs->last_clst;
    cbz r6, 0f                              @   if (scl == 0 || scl >= fs->n_fatent) scl = 1;
    ldr r0, [r4, #FS_N_FATENT]
    cmp r6, r0
    blo 2f
0:  movs r6, #1
    b 2f
1:  mov r0, r8                              @ } else {
    mov r1, r5
    bl ff16_get_fat                         @   cs = get_fat(obj, clst);
    cmp r0, #2
    blo .Lcc_ret1                           @   if (cs < 2) return 1;
    cmn r0, #1
    beq .Lcc_ret                            @   if (cs == 0xFFFFFFFF) return cs;
    ldr r1, [r4, #FS_N_FATENT]
    cmp r0, r1
    blo .Lcc_ret                            @   if (cs < fs->n_fatent) return cs;
    mov r6, r5                              @   scl = clst;
2:  ldr r0, [r4, #FS_FREE_CLST]             @ if (fs->free_clst == 0) return 0;
    cmp r0, #0
    beq .Lcc_ret0
    movs r7, #0                             @ ncl = 0;
    cmp r6, r5                              @ if (scl == clst) {
    bne 4f
    adds r7, r6, #1                         @   ncl = scl + 1;
    ldr r0, [r4, #FS_N_FATENT]
    cmp r7, r0
    it hs
    movhs r7, #2                            @   if (ncl >= fs->n_fatent) ncl = 2;
    mov r0, r8
    mov r1, r7
    bl ff16_get_fat                         @   cs = get_fat(obj, ncl);
    cmp r0, #1
    beq .Lcc_ret                            @   if (cs == 1 || cs == 0xFFFFFFFF) return cs;
    cmn r0, #1
    beq .Lcc_ret
    cbz r0, 4f                              @   if (cs != 0) {
    ldr r0, [r4, #FS_LAST_CLST]             @     cs = fs->last_clst;
    cmp r0, #2                              @     if (cs >= 2 && cs < fs->n_fatent) scl = cs;
    blo 3f
    ldr r1, [r4, #FS_N_FATENT]
    cmp r0, r1
    it lo
    movlo r6, r0
3:  movs r7, #0                             @     ncl = 0;
4:  cbnz r7, 6f                             @ if (ncl == 0) {
    mov r7, r6                              @   ncl = scl;
5:  adds r7, r7, #1                         @   for (;;) { ncl++;
    ldr r0, [r4, #FS_N_FATENT]
    cmp r7, r0                              @     if (ncl >= fs->n_fatent) {
    blo 51f
    movs r7, #2                             @       ncl = 2;
    cmp r7, r6
    bhi .Lcc_ret0                           @       if (ncl > scl) return 0;
51: mov r0, r8
    mov r1, r7
    bl ff16_get_fat                         @     cs = get_fat(obj, ncl);
    cbz r0, 6f                              @     if (cs == 0) break;
    cmp r0, #1
    beq .Lcc_ret                            @     if (cs == 1 || cs == 0xFFFFFFFF) return cs;
    cmn r0, #1
    beq .Lcc_ret
    cmp r7, r6
    beq .Lcc_ret0                           @     if (ncl == scl) return 0;
    b 5b
6:  mov r0, r4
    mov r1, r7
    mov r2, #0xFFFFFFFF
    bl ff16_put_fat                         @ res = put_fat(fs, ncl, 0xFFFFFFFF);
    mov r10, r0
    cmp r10, #0                            @ if (res == FR_OK && clst != 0) {
    bne 7f
    cbz r5, 7f
    mov r0, r4
    mov r1, r5
    mov r2, r7
    bl ff16_put_fat                         @   res = put_fat(fs, clst, ncl);
    mov r10, r0
7:  cmp r10, #FR_OK                         @ if (res == FR_OK) {
    bne 9f
    str r7, [r4, #FS_LAST_CLST]             @   fs->last_clst = ncl;
    ldr r0, [r4, #FS_FREE_CLST]             @   if (fs->free_clst > 0 && fs->free_clst <= fs->n_fatent - 2) {
    cbz r0, 8f
    ldr r1, [r4, #FS_N_FATENT]
    subs r1, r1, #2
    cmp r0, r1
    bhi 8f
    subs r0, r0, #1
    str r0, [r4, #FS_FREE_CLST]             @     fs->free_clst--;
    ldrb r0, [r4, #FS_FSI_FLAG]
    orr r0, r0, #1
    strb r0, [r4, #FS_FSI_FLAG]             @     fs->fsi_flag |= 1;
8:  mov r0, r7                              @ return ncl
    b .Lcc_ret
9:  cmp r10, #FR_DISK_ERR                   @ } else { ncl = (res == FR_DISK_ERR) ? 0xFFFFFFFF : 1; }
    ite eq
    moveq r0, #0xFFFFFFFF
    movne r0, #1
    b .Lcc_ret
.Lcc_ret0:
    movs r0, #0
    b .Lcc_ret
.Lcc_ret1:
    movs r0, #1
.Lcc_ret:
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_create_chain

@ -----------------------------------------------------------------------------
@ dir_clear - fill a cluster with zeros (ff.c dir_clear, without the work-buffer branch: FF_USE_LFN 0)
@ In       : r0 = fs, r1 = clst
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_dir_clear
    push {r4, r5, r6, r7, lr}
    mov r4, r0
    mov r5, r1
    bl ff16_sync_window                     @ if (sync_window(fs) != FR_OK) return FR_DISK_ERR;
    cbnz r0, 9f
    mov r0, r4
    mov r1, r5
    bl ff16_clst2sect                       @ sect = clst2sect(fs, clst);
    mov r6, r0
    str r6, [r4, #FS_WINSECT]               @ fs->winsect = sect;
    add r0, r4, #FS_WIN
    movs r1, #0
    mov r2, #512
    bl ff16_memset                          @ memset(fs->win, 0, sizeof fs->win);
    movs r7, #0                             @ ibuf = fs->win; szb = 1; n = 0
1:  ldrh r0, [r4, #FS_CSIZE]                @ for (n = 0; n < fs->csize && disk_write(fs->pdrv, ibuf, sect + n, szb) == RES_OK; n += szb) ;
    cmp r7, r0
    bhs 2f
    ldrb r0, [r4, #FS_PDRV]
    add r1, r4, #FS_WIN
    add r2, r6, r7
    movs r3, #1
    bl disk_write
    cbnz r0, 2f
    adds r7, r7, #1
    b 1b
2:  ldrh r0, [r4, #FS_CSIZE]                @ return (n == fs->csize) ? FR_OK : FR_DISK_ERR;
    cmp r7, r0
    bne 9f
    movs r0, #FR_OK
    pop {r4, r5, r6, r7, pc}
9:  movs r0, #FR_DISK_ERR
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_dir_clear

    .ltorg

