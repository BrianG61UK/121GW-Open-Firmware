@ =============================================================================
@ ffx_low.s - FatFs R0.16 w/patch 2, exFAT configuration, group A: memory helpers, byte-order loads and stores,
@ DBCS tests, TCHAR/Unicode conversion, the sector window, FSINFO / exFAT PercInUse, cluster to sector, FAT access,
@ the exFAT allocation bitmap, cluster chains, directory clearing, the code page 437 tables (ffunicode.c) and the
@ module's static data (DESIGN.md 7A, IMP-32)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2, configuration of ff16x.inc (FF_FS_EXFAT 1, FF_USE_LFN 1 with a
@ static working buffer, FF_LFN_UNICODE 0, FF_CODE_PAGE 437, FF_FS_TINY 0, FF_MIN_SS = FF_MAX_SS = 512).  The reference
@ C is ff_x.c (application configuration, FF_FS_READONLY 0) and ffunicode_x.c (ffunicode.c preprocessed for code page
@ 437).  ff_xro.c (FF_FS_READONLY 1) differs in this file only by missing routines and by move_window not calling
@ sync_window; every part that exists only with FF_FS_READONLY 0 is inside ".if FF_FS_READONLY == 0".  Each routine
@ names the C function it translates; the code follows the C statements in order, the comments quote or paraphrase
@ them.  Calling convention AAPCS (r0-r3 arguments, 64-bit arguments in an even register pair, 64-bit results in
@ r0:r1, r4-r11 preserved, stack 8-byte aligned at calls).  Routines are named ff16_<C name>; ff.c's memcpy, memset
@ and memcmp calls are served by ff16_mem_cpy, ff16_mem_set and ff16_mem_cmp.
@
@ FatFs license (ChaN): "FatFs module is an open source software. Redistribution and use of FatFs in source and binary forms,
@ with or without modification, are permitted provided that the following condition is met: 1. Redistributions of source
@ code must retain the above copyright notice, this condition and the following disclaimer.  This software is provided by
@ the copyright holder and contributors "AS IS" and any warranties related to this software are DISCLAIMED.  The copyright
@ owner or contributors be NOT LIABLE for any damages caused by use of this software."  Copyright (C) 2025, ChaN, all right
@ reserved.
@
@ Structure offsets and constants: ff16x.inc (FATFS, FFOBJID, FIL, DIR, FILINFO as measured for this configuration).
@ Data defined here (global): ff16_FatFs, ff16_Fsid, ff16_LfnBuf, ff16_DirBuf (zero initialised RAM, cleared with
@ the rest of .bss_port at start), ff16_LfnOfs, ff16_ExCvt (constant tables), ff16_uc437 (code page 437 table).
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ff16x.inc"

@ Disk ioctl command used below (diskio.h).  The disk_read / disk_write results are compared with RES_OK = 0 (diskio.h
@ DRESULT), written as cbz / cbnz on r0.
    .equ CTRL_SYNC, 0                       @ diskio.h CTRL_SYNC (disk_ioctl command 0)

    .section .text.ff16x.low, "ax", %progbits

@ -----------------------------------------------------------------------------
@ mem_cpy - memcpy(dst, src, n) as called by ff.c (forward byte copy; ff.c never overlaps the regions)
@ In       : r0 = dst, r1 = src, r2 = n
@ Out      : r0 = dst
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_mem_cpy
    mov r12, r0                             @ r12 = write pointer, r0 stays dst for the return value
1:  cbz r2, 2f                              @ while (n--) {
    ldrb r3, [r1], #1                       @   byte = *src++;
    strb r3, [r12], #1                      @   *dst++ = byte;
    subs r2, r2, #1                         @ }
    b 1b
2:  bx lr                                   @ return dst
ENDFUNC ff16_mem_cpy

@ -----------------------------------------------------------------------------
@ mem_set - memset(dst, val, n) as called by ff.c
@ In       : r0 = dst, r1 = val (low byte stored), r2 = n
@ Out      : r0 = dst
@ Clobbers : r2, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_mem_set
    mov r12, r0                             @ r12 = write pointer, r0 stays dst for the return value
1:  cbz r2, 2f                              @ while (n--) {
    strb r1, [r12], #1                      @   *dst++ = (BYTE)val;
    subs r2, r2, #1                         @ }
    b 1b
2:  bx lr                                   @ return dst
ENDFUNC ff16_mem_set

@ -----------------------------------------------------------------------------
@ mem_cmp - memcmp(a, b, n) as called by ff.c (ff.c tests the result only against zero)
@ In       : r0 = a, r1 = b, r2 = n
@ Out      : r0 = 0 if the n bytes are equal, else a[i] - b[i] of the first differing pair (unsigned bytes)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_mem_cmp
    mov r12, r0                             @ r12 = read pointer of a
1:  cbz r2, 3f                              @ while (n--) {
    ldrb r0, [r12], #1                      @   d = *a++ - *b++;
    ldrb r3, [r1], #1
    subs r0, r0, r3
    bne 2f                                  @   if (d != 0) return d;
    subs r2, r2, #1                         @ }
    b 1b
2:  bx lr
3:  movs r0, #0                             @ return 0
    bx lr
ENDFUNC ff16_mem_cmp

@ -----------------------------------------------------------------------------
@ ld_16 - WORD ld_16(const BYTE* ptr): little-endian 16-bit load at any alignment
@ In       : r0 = ptr
@ Out      : r0 = value
@ Clobbers : r1
@ -----------------------------------------------------------------------------
FUNC ff16_ld_16
    ldrb r1, [r0, #1]                       @ rv = ptr[1];
    ldrb r0, [r0, #0]
    orr r0, r0, r1, lsl #8                  @ rv = rv << 8 | ptr[0];
    bx lr                                   @ return rv
ENDFUNC ff16_ld_16

@ -----------------------------------------------------------------------------
@ ld_32 - DWORD ld_32(const BYTE* ptr): little-endian 32-bit load at any alignment
@ In       : r0 = ptr
@ Out      : r0 = value
@ Clobbers : r1, r2
@ -----------------------------------------------------------------------------
FUNC ff16_ld_32
    ldrb r1, [r0, #3]                       @ rv = ptr[3];
    ldrb r2, [r0, #2]
    orr r1, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[2];
    ldrb r2, [r0, #1]
    orr r1, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[1];
    ldrb r2, [r0, #0]
    orr r0, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[0];
    bx lr                                   @ return rv
ENDFUNC ff16_ld_32

@ -----------------------------------------------------------------------------
@ ld_64 - QWORD ld_64(const BYTE* ptr): little-endian 64-bit load at any alignment
@ In       : r0 = ptr
@ Out      : r0 = low word, r1 = high word
@ Clobbers : r2, r3
@ -----------------------------------------------------------------------------
FUNC ff16_ld_64
    ldrb r1, [r0, #7]                       @ rv = ptr[7];
    ldrb r2, [r0, #6]
    orr r1, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[6];   (bytes 7..4 build the high word)
    ldrb r2, [r0, #5]
    orr r1, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[5];
    ldrb r2, [r0, #4]
    orr r1, r2, r1, lsl #8                  @ rv = rv << 8 | ptr[4];   r1 = high word of rv
    ldrb r2, [r0, #3]
    ldrb r3, [r0, #2]
    orr r2, r3, r2, lsl #8                  @ rv = rv << 8 | ptr[3]; rv = rv << 8 | ptr[2];   (bytes 3..0 build the low word)
    ldrb r3, [r0, #1]
    orr r2, r3, r2, lsl #8                  @ rv = rv << 8 | ptr[1];
    ldrb r3, [r0, #0]
    orr r0, r3, r2, lsl #8                  @ rv = rv << 8 | ptr[0];   r0 = low word of rv
    bx lr                                   @ return rv (r1:r0)
ENDFUNC ff16_ld_64

.if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ st_16 - void st_16(BYTE* ptr, WORD val): little-endian 16-bit store at any alignment (exists only when writing)
@ In       : r0 = ptr, r1 = val (low 16 bits stored)
@ Out      : -
@ Clobbers : r1, flags
@ -----------------------------------------------------------------------------
FUNC ff16_st_16
    strb r1, [r0, #0]                       @ *ptr++ = (BYTE)val;
    lsrs r1, r1, #8                         @ val >>= 8;
    strb r1, [r0, #1]                       @ *ptr++ = (BYTE)val;
    bx lr
ENDFUNC ff16_st_16

@ -----------------------------------------------------------------------------
@ st_32 - void st_32(BYTE* ptr, DWORD val): little-endian 32-bit store at any alignment (exists only when writing)
@ In       : r0 = ptr, r1 = val
@ Out      : -
@ Clobbers : r1, flags
@ -----------------------------------------------------------------------------
FUNC ff16_st_32
    strb r1, [r0, #0]                       @ *ptr++ = (BYTE)val;
    lsrs r1, r1, #8                         @ val >>= 8;
    strb r1, [r0, #1]                       @ *ptr++ = (BYTE)val;
    lsrs r1, r1, #8                         @ val >>= 8;
    strb r1, [r0, #2]                       @ *ptr++ = (BYTE)val;
    lsrs r1, r1, #8                         @ val >>= 8;
    strb r1, [r0, #3]                       @ *ptr++ = (BYTE)val;
    bx lr
ENDFUNC ff16_st_32

@ -----------------------------------------------------------------------------
@ st_64 - void st_64(BYTE* ptr, QWORD val): little-endian 64-bit store at any alignment (exists only when writing)
@ In       : r0 = ptr, r2 = val low word, r3 = val high word (QWORD argument in the even pair r2:r3, r1 unused)
@ Out      : -
@ Clobbers : r2, r3, flags
@ -----------------------------------------------------------------------------
FUNC ff16_st_64
    strb r2, [r0, #0]                       @ *ptr++ = (BYTE)val; val >>= 8;   (bytes 0..3 from the low word)
    lsrs r2, r2, #8
    strb r2, [r0, #1]                       @ *ptr++ = (BYTE)val; val >>= 8;
    lsrs r2, r2, #8
    strb r2, [r0, #2]                       @ *ptr++ = (BYTE)val; val >>= 8;
    lsrs r2, r2, #8
    strb r2, [r0, #3]                       @ *ptr++ = (BYTE)val; val >>= 8;
    strb r3, [r0, #4]                       @ *ptr++ = (BYTE)val; val >>= 8;   (bytes 4..7 from the high word)
    lsrs r3, r3, #8
    strb r3, [r0, #5]                       @ *ptr++ = (BYTE)val; val >>= 8;
    lsrs r3, r3, #8
    strb r3, [r0, #6]                       @ *ptr++ = (BYTE)val; val >>= 8;
    lsrs r3, r3, #8
    strb r3, [r0, #7]                       @ *ptr++ = (BYTE)val;
    bx lr
ENDFUNC ff16_st_64
.endif

@ -----------------------------------------------------------------------------
@ dbc_1st - int dbc_1st(BYTE c): DBCS lead byte test.  Code page 437 is single byte, so ff_x.c is
@     if (c != 0) return 0; return 0;     (both paths return 0: no byte is a DBCS lead byte)
@ In       : r0 = c
@ Out      : r0 = 0
@ Clobbers : -
@ -----------------------------------------------------------------------------
FUNC ff16_dbc_1st
    movs r0, #0                             @ if (c != 0) return 0; return 0;
    bx lr
ENDFUNC ff16_dbc_1st

@ -----------------------------------------------------------------------------
@ dbc_2nd - int dbc_2nd(BYTE c): DBCS trail byte test; single byte code page 437 as dbc_1st (always 0)
@ In       : r0 = c
@ Out      : r0 = 0
@ Clobbers : -
@ -----------------------------------------------------------------------------
FUNC ff16_dbc_2nd
    movs r0, #0                             @ if (c != 0) return 0; return 0;
    bx lr
ENDFUNC ff16_dbc_2nd

@ -----------------------------------------------------------------------------
@ tchar2uni - DWORD tchar2uni(const TCHAR** str): next OEM character of the string to Unicode (ANSI/OEM input)
@ In       : r0 = str (pointer to the string pointer)
@ Out      : r0 = Unicode character (0 at the end of the string), 0xFFFFFFFF if invalid; *str advanced on success only
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_tchar2uni
    push {r3, r4, r5, r6, r7, lr}           @ r3 only keeps the stack 8-byte aligned; r4 str, r5 p, r6 wc, r7 sb
    mov r4, r0
    ldr r5, [r4]                            @ const TCHAR *p = *str;
    ldrb r6, [r5], #1                       @ wc = (BYTE)*p++;
    mov r0, r6
    bl ff16_dbc_1st                         @ if (dbc_1st((BYTE)wc)) {
    cbz r0, 1f
    ldrb r7, [r5], #1                       @   sb = (BYTE)*p++;
    mov r0, r7
    bl ff16_dbc_2nd                         @   if (!dbc_2nd(sb)) return 0xFFFFFFFF;
    cbnz r0, 2f
    mvn r0, #0
    pop {r3, r4, r5, r6, r7, pc}
2:  lsls r6, r6, #8                         @   wc = (wc << 8) + sb;   (WCHAR: 16 bits)
    adds r6, r6, r7
    uxth r6, r6                             @ }
1:  cbz r6, 3f                              @ if (wc != 0) {
    mov r0, r6
    movw r1, #CODEPAGE
    bl ff16_ff_oem2uni                      @   wc = ff_oem2uni(wc, 437);
    uxth r6, r0
    cbnz r6, 3f                             @   if (wc == 0) return 0xFFFFFFFF;
    mvn r0, #0
    pop {r3, r4, r5, r6, r7, pc}
3:  str r5, [r4]                            @ uc = wc; *str = p;
    mov r0, r6                              @ return uc;
    pop {r3, r4, r5, r6, r7, pc}
ENDFUNC ff16_tchar2uni

@ -----------------------------------------------------------------------------
@ put_utf - UINT put_utf(DWORD chr, TCHAR* buf, UINT szb): one Unicode character to OEM bytes (ANSI/OEM output)
@ In       : r0 = chr, r1 = buf, r2 = szb (bytes available)
@ Out      : r0 = bytes written (1 or 2), 0 if the character has no code page 437 form or does not fit
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_put_utf
    push {r4, r5, r6, lr}                   @ r4 buf, r5 szb, r6 wc
    mov r4, r1
    mov r5, r2
    movw r1, #CODEPAGE
    bl ff16_ff_uni2oem                      @ wc = ff_uni2oem(chr, 437);
    uxth r6, r0
    cmp r6, #0x100                          @ if (wc >= 0x100) {
    blo 1f
    cmp r5, #2                              @   if (szb < 2) return 0;
    blo 9f
    lsrs r0, r6, #8
    strb r0, [r4], #1                       @   *buf++ = (char)(wc >> 8);
    strb r6, [r4]                           @   *buf++ = (TCHAR)wc;
    movs r0, #2                             @   return 2;
    pop {r4, r5, r6, pc}
1:  cbz r6, 9f                              @ if (wc == 0 || szb < 1) return 0;
    cbz r5, 9f
    strb r6, [r4]                           @ *buf++ = (TCHAR)wc;
    movs r0, #1                             @ return 1;
    pop {r4, r5, r6, pc}
9:  movs r0, #0
    pop {r4, r5, r6, pc}
ENDFUNC ff16_put_utf

.if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ sync_window - FRESULT sync_window(FATFS* fs): write the window back if dirty (exists only when writing)
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
    strb r0, [r4, #FS_WFLAG]                @     fs->wflag = 0;   (r0 is 0 = RES_OK here)
    ldr r2, [r4, #FS_WINSECT]               @     if (fs->winsect - fs->fatbase < fs->fsize) {
    ldr r1, [r4, #FS_FATBASE]
    subs r1, r2, r1
    ldr r3, [r4, #FS_FSIZE]
    cmp r1, r3
    bhs 2f
    ldrb r0, [r4, #FS_N_FATS]               @       if (fs->n_fats == 2)
    cmp r0, #2
    bne 2f
    add r2, r2, r3                          @         disk_write(fs->pdrv, fs->win, fs->winsect + fs->fsize, 1);
    ldrb r0, [r4, #FS_PDRV]                 @         (second FAT copy; result not used, as in ff.c)
    add r1, r4, #FS_WIN
    movs r3, #1
    bl disk_write
2:  movs r0, #FR_OK                         @ return res;  (FR_OK on every path that reaches here)
    pop {r4, pc}
3:  movs r0, #FR_DISK_ERR                   @   } else { res = FR_DISK_ERR; }
    pop {r4, pc}
ENDFUNC ff16_sync_window
.endif

@ -----------------------------------------------------------------------------
@ move_window - FRESULT move_window(FATFS* fs, LBA_t sect): load a sector into the window
@ (with FF_FS_READONLY 0 a dirty window is written back first)
@ In       : r0 = fs, r1 = sect
@ Out      : r0 = FR_OK / FR_DISK_ERR (or the error of sync_window)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_move_window
    push {r4, r5, r6, lr}                   @ r4 fs, r5 sect, r6 res
    mov r4, r0
    mov r5, r1
    movs r6, #FR_OK                         @ FRESULT res = FR_OK;
    ldr r0, [r4, #FS_WINSECT]               @ if (sect != fs->winsect) {
    cmp r5, r0
    beq 3f
.if FF_FS_READONLY == 0
    mov r0, r4
    bl ff16_sync_window                     @   res = sync_window(fs);
    mov r6, r0
.endif
    cbnz r6, 3f                             @   if (res == FR_OK) {
    ldrb r0, [r4, #FS_PDRV]                 @     if (disk_read(fs->pdrv, fs->win, sect, 1) != RES_OK) {
    add r1, r4, #FS_WIN
    mov r2, r5
    movs r3, #1
    bl disk_read
    cbz r0, 1f
    mvn r5, #0                              @       sect = (LBA_t)0 - 1;
    movs r6, #FR_DISK_ERR                   @       res = FR_DISK_ERR;
1:  str r5, [r4, #FS_WINSECT]               @     }  fs->winsect = sect;
3:  mov r0, r6                              @ return res;
    pop {r4, r5, r6, pc}
ENDFUNC ff16_move_window

.if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ sfs_perc (local helper of sync_fs) - (BYTE)((QWORD)x * 100 / n) as a 64 by 32 bit restoring division
@ In       : r0 = x, r1 = n (divisor)
@ Out      : r0 = low 32 bits of the quotient floor(x * 100 / n)  (sync_fs casts it to BYTE)
@ Clobbers : r1-r3, r12, flags
@ The remainder is kept as a 33-bit value (register plus carry) so a divisor above 2^31 is also handled.
@ A zero divisor does not trap and gives an all-ones quotient.
@ -----------------------------------------------------------------------------
LFUNC ff16_sfs_perc
    push {r4, r5}                           @ r4 bit counter, r5 quotient
    mov r12, #100
    umull r2, r3, r0, r12                   @ r3:r2 = (QWORD)x * 100  (numerator, at most 39 bits)
    movs r0, #0                             @ remainder = 0
    movs r5, #0                             @ quotient = 0
    movs r4, #64                            @ 64 numerator bits, most significant first
1:  lsls r2, r2, #1                         @ numerator <<= 1; the bit shifted out goes to carry ...
    adcs r3, r3, r3
    adcs r0, r0, r0                         @ remainder = remainder << 1 | that bit; carry = remainder overflow
    bcs 2f                                  @ remainder >= 2^32 > n: subtract
    cmp r0, r1
    blo 3f                                  @ remainder < n: quotient bit 0
2:  subs r0, r0, r1                         @ remainder -= n (modulo 2^32 is exact, the result is below n)
    lsls r5, r5, #1                         @ quotient = quotient << 1 | 1
    orr r5, r5, #1
    b 4f
3:  lsls r5, r5, #1                         @ quotient = quotient << 1
4:  subs r4, r4, #1
    bne 1b
    mov r0, r5
    pop {r4, r5}
    bx lr
ENDFUNC ff16_sfs_perc

@ -----------------------------------------------------------------------------
@ sync_fs - FRESULT sync_fs(FATFS* fs): flush the window, update the FAT32 FSINFO sector or the exFAT PercInUse field
@ if the allocation changed, then flush the device (exists only when writing)
@ In       : r0 = fs
@ Out      : r0 = FR_OK / FR_DISK_ERR
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_sync_fs
    push {r4, r5, r6, lr}                   @ r4 fs, r5 res, r6 fs->win
    mov r4, r0
    bl ff16_sync_window                     @ res = sync_window(fs);
    mov r5, r0
    cmp r5, #0                              @ if (res == FR_OK) {
    bne 9f
    add r6, r4, #FS_WIN
    ldrb r0, [r4, #FS_FSI_FLAG]             @   if (fs->fsi_flag == 1) {
    cmp r0, #1
    bne 8f
    movs r0, #0
    strb r0, [r4, #FS_FSI_FLAG]             @     fs->fsi_flag = 0;
    ldrb r0, [r4, #FS_FS_TYPE]
    cmp r0, #FS_FAT32                       @     if (fs->fs_type == FS_FAT32) {
    bne 5f
    mov r0, r6
    movs r1, #0
    mov r2, #512
    bl ff16_mem_set                         @       memset(fs->win, 0, sizeof fs->win);
    mov r0, r6
    ldr r1, =0x41615252
    bl ff16_st_32                           @       st_32(fs->win + FSI_LeadSig, 0x41615252);
    add r0, r6, #FSI_StrucSig
    ldr r1, =0x61417272
    bl ff16_st_32                           @       st_32(fs->win + FSI_StrucSig, 0x61417272);
    add r0, r6, #FSI_Free_Count
    ldr r1, [r4, #FS_FREE_CLST]
    bl ff16_st_32                           @       st_32(fs->win + FSI_Free_Count, fs->free_clst);
    add r0, r6, #FSI_Nxt_Free
    ldr r1, [r4, #FS_LAST_CLST]
    bl ff16_st_32                           @       st_32(fs->win + FSI_Nxt_Free, fs->last_clst);
    add r0, r6, #FSI_TrailSig
    ldr r1, =0xAA550000
    bl ff16_st_32                           @       st_32(fs->win + FSI_TrailSig, 0xAA550000);
    ldr r2, [r4, #FS_VOLBASE]
    adds r2, r2, #1
    str r2, [r4, #FS_WINSECT]               @       disk_write(fs->pdrv, fs->win, fs->winsect = fs->volbase + 1, 1);
    ldrb r0, [r4, #FS_PDRV]
    mov r1, r6
    movs r3, #1
    bl disk_write
    b 8f
5:  cmp r0, #FS_EXFAT                       @     } else if (fs->fs_type == FS_EXFAT) {
    bne 8f
    ldr r2, [r4, #FS_VOLBASE]
    str r2, [r4, #FS_WINSECT]               @       if (disk_read(fs->pdrv, fs->win, fs->winsect = fs->volbase, 1) == RES_OK) {
    ldrb r0, [r4, #FS_PDRV]
    mov r1, r6
    movs r3, #1
    bl disk_read
    cbnz r0, 8f
    ldr r1, [r4, #FS_N_FATENT]              @         BYTE perc_inuse = (fs->free_clst <= fs->n_fatent - 2) ?
    subs r1, r1, #2                         @           (BYTE)((QWORD)(fs->n_fatent - 2 - fs->free_clst) * 100 / (fs->n_fatent - 2))
    ldr r0, [r4, #FS_FREE_CLST]             @           : 0xFF;
    cmp r0, r1
    bhi 6f
    subs r0, r1, r0                         @         r0 = n_fatent - 2 - free_clst, r1 = n_fatent - 2
    bl ff16_sfs_perc
    uxtb r0, r0
    b 7f
6:  movs r0, #0xFF                          @         free_clst above the cluster count: unknown
7:  ldrb r1, [r6, #BPB_PercInUseEx]         @         if (fs->win[BPB_PercInUseEx] != perc_inuse) {
    cmp r1, r0
    beq 8f
    strb r0, [r6, #BPB_PercInUseEx]         @           fs->win[BPB_PercInUseEx] = perc_inuse;
    ldrb r0, [r4, #FS_PDRV]                 @           disk_write(fs->pdrv, fs->win, fs->winsect, 1);
    mov r1, r6
    ldr r2, [r4, #FS_WINSECT]
    movs r3, #1
    bl disk_write
8:  ldrb r0, [r4, #FS_PDRV]                 @   if (disk_ioctl(fs->pdrv, CTRL_SYNC, 0) != RES_OK) res = FR_DISK_ERR;
    movs r1, #CTRL_SYNC
    movs r2, #0
    bl disk_ioctl
    cbz r0, 9f
    movs r5, #FR_DISK_ERR
9:  mov r0, r5                              @ return res;
    pop {r4, r5, r6, pc}
    .ltorg
ENDFUNC ff16_sync_fs
.endif

@ -----------------------------------------------------------------------------
@ clst2sect - LBA_t clst2sect(FATFS* fs, DWORD clst): first sector of a cluster
@ In       : r0 = fs, r1 = clst
@ Out      : r0 = sector, 0 for a cluster number out of range
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
@ get_fat - DWORD get_fat(FFOBJID* obj, DWORD clst): read the FAT entry of a cluster (FAT12/16/32 and exFAT)
@ In       : r0 = obj, r1 = clst
@ Out      : r0 = next cluster / 0xFFFFFFFF end of chain (exFAT: 0x7FFFFFFF) / 1 internal error (cluster out of range or
@            invalid fs_type) / 0xFFFFFFFF disk error
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_get_fat
    push {r4, r5, r6, r7, r8, lr}           @ r4 obj, r5 fs, r6 clst, r7 bc / cofs, r8 wc / clen
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = obj->fs;
    mov r6, r1
    cmp r6, #2                              @ if (clst < 2 || clst >= fs->n_fatent) {
    blo .Lgf_one
    ldr r0, [r5, #FS_N_FATENT]
    cmp r6, r0
    bhs .Lgf_one                            @   val = 1;
    ldrb r0, [r5, #FS_FS_TYPE]              @ } else { val = 0xFFFFFFFF;  (set at .Lgf_err)  switch (fs->fs_type) {
    cmp r0, #FS_FAT12
    beq .Lgf_fat12
    cmp r0, #FS_FAT16
    beq .Lgf_fat16
    cmp r0, #FS_FAT32
    beq .Lgf_fat32
    cmp r0, #FS_EXFAT
    beq .Lgf_exfat
    b .Lgf_one                              @   default: val = 1;
.Lgf_fat12:                                 @   case FS_FAT12:
    add r7, r6, r6, lsr #1                  @     bc = (UINT)clst; bc += bc / 2;
    lsrs r1, r7, #9
    ldr r2, [r5, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r5
    bl ff16_move_window                     @     if (move_window(fs, fs->fatbase + (bc / SS)) != FR_OK) break;
    cmp r0, #0
    bne .Lgf_err
    ubfx r1, r7, #0, #9                        @     wc = fs->win[bc++ % SS];
    add r2, r5, #FS_WIN
    ldrb r8, [r2, r1]
    adds r7, r7, #1
    lsrs r1, r7, #9
    ldr r2, [r5, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r5
    bl ff16_move_window                     @     if (move_window(fs, fs->fatbase + (bc / SS)) != FR_OK) break;
    cmp r0, #0
    bne .Lgf_err
    ubfx r1, r7, #0, #9                        @     wc |= fs->win[bc % SS] << 8;
    add r2, r5, #FS_WIN
    ldrb r1, [r2, r1]
    orr r8, r8, r1, lsl #8
    tst r6, #1                              @     val = (clst & 1) ? (wc >> 4) : (wc & 0xFFF);
    beq 1f
    lsrs r0, r8, #4
    b .Lgf_ret
1:  ubfx r0, r8, #0, #12
    b .Lgf_ret
.Lgf_fat16:                                 @   case FS_FAT16:
    lsrs r1, r6, #8                         @     clst / (SS / 2)
    ldr r2, [r5, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r5
    bl ff16_move_window                     @     if (move_window(fs, fs->fatbase + (clst / (SS / 2))) != FR_OK) break;
    cmp r0, #0
    bne .Lgf_err
    lsls r0, r6, #1                         @     val = ld_16(fs->win + clst * 2 % SS);
    ubfx r0, r0, #0, #9
    add r0, r0, r5
    add r0, r0, #FS_WIN
    bl ff16_ld_16
    b .Lgf_ret
.Lgf_fat32:                                 @   case FS_FAT32:
    lsrs r1, r6, #7                         @     clst / (SS / 4)
    ldr r2, [r5, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r5
    bl ff16_move_window                     @     if (move_window(fs, fs->fatbase + (clst / (SS / 4))) != FR_OK) break;
    cmp r0, #0
    bne .Lgf_err
    lsls r0, r6, #2                         @     val = ld_32(fs->win + clst * 4 % SS) & 0x0FFFFFFF;
    ubfx r0, r0, #0, #9
    add r0, r0, r5
    add r0, r0, #FS_WIN
    bl ff16_ld_32
    bic r0, r0, #0xF0000000
    b .Lgf_ret
.Lgf_exfat:                                 @   case FS_EXFAT:
    ldrd r0, r1, [r4, #OBJ_OBJSIZE]         @     if ((obj->objsize != 0 && obj->sclust != 0) || obj->stat == 0) {
    orrs r0, r0, r1
    beq 2f
    ldr r0, [r4, #OBJ_SCLUST]
    cbnz r0, 3f
2:  ldrb r0, [r4, #OBJ_STAT]
    cbnz r0, .Lgf_one                       @       (neither: val = 1)
3:  ldr r0, [r4, #OBJ_SCLUST]
    subs r7, r6, r0                         @       DWORD cofs = clst - obj->sclust;
    ldrd r0, r1, [r4, #OBJ_OBJSIZE]         @       DWORD clen = (DWORD)((LBA_t)((obj->objsize - 1) / SS) / fs->csize);
    subs r0, r0, #1                         @         objsize - 1 (64 bit)
    sbc r1, r1, #0
    lsrs r0, r0, #9                         @         / 512, keeping the low 32 bits: (hi:lo) >> 9
    orr r0, r0, r1, lsl #23
    ldrh r1, [r5, #FS_CSIZE]
    udiv r8, r0, r1                         @         / fs->csize
    ldrb r0, [r4, #OBJ_STAT]                @       if (obj->stat == 2 && cofs <= clen) {
    cmp r0, #2
    bne 4f
    cmp r7, r8
    bhi 4f
    beq 5f                                  @         val = (cofs == clen) ? 0x7FFFFFFF : clst + 1;  break;
    adds r0, r6, #1
    b .Lgf_ret
5:  mvn r0, #0x80000000
    b .Lgf_ret
4:  cmp r0, #3                              @       if (obj->stat == 3 && cofs < obj->n_cont) {
    bne 6f
    ldr r1, [r4, #OBJ_N_CONT]
    cmp r7, r1
    bhs 6f
    adds r0, r6, #1                         @         val = clst + 1;  break;
    b .Lgf_ret
6:  cmp r0, #2                              @       if (obj->stat != 2) {
    beq .Lgf_one                            @       (stat == 2 beyond the object: val = 1)
    ldr r0, [r4, #OBJ_N_FRAG]               @         if (obj->n_frag != 0) {
    cbz r0, 7f
    mvn r0, #0x80000000                     @           val = 0x7FFFFFFF;
    b .Lgf_ret
7:  lsrs r1, r6, #7                         @         } else { clst / (SS / 4)
    ldr r2, [r5, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r5
    bl ff16_move_window                     @           if (move_window(fs, fs->fatbase + (clst / (SS / 4))) != FR_OK) break;
    cmp r0, #0
    bne .Lgf_err
    lsls r0, r6, #2                         @           val = ld_32(fs->win + clst * 4 % SS) & 0x7FFFFFFF;
    ubfx r0, r0, #0, #9
    add r0, r0, r5
    add r0, r0, #FS_WIN
    bl ff16_ld_32
    bic r0, r0, #0x80000000
    b .Lgf_ret
.Lgf_err:
    mvn r0, #0                              @ val = 0xFFFFFFFF  (a break after a failed move_window)
    b .Lgf_ret
.Lgf_one:
    movs r0, #1                             @ val = 1
.Lgf_ret:
    pop {r4, r5, r6, r7, r8, pc}            @ return val;
    .ltorg
ENDFUNC ff16_get_fat

.if FF_FS_READONLY == 0
@ -----------------------------------------------------------------------------
@ put_fat - FRESULT put_fat(FATFS* fs, DWORD clst, DWORD val): write a FAT entry (exists only when writing)
@ In       : r0 = fs, r1 = clst, r2 = val
@ Out      : r0 = FR_OK / FR_DISK_ERR / FR_INT_ERR (cluster out of range or invalid fs_type)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_put_fat
    push {r4, r5, r6, r7, r8, lr}           @ r4 fs, r5 clst, r6 val, r7 bc, r8 p
    mov r4, r0
    mov r5, r1
    mov r6, r2
    cmp r5, #2                              @ FRESULT res = FR_INT_ERR;
    blo .Lpf_interr                         @ if (clst >= 2 && clst < fs->n_fatent) {
    ldr r0, [r4, #FS_N_FATENT]
    cmp r5, r0
    bhs .Lpf_interr
    ldrb r0, [r4, #FS_FS_TYPE]              @   switch (fs->fs_type) {
    cmp r0, #FS_FAT12
    beq .Lpf_fat12
    cmp r0, #FS_FAT16
    beq .Lpf_fat16
    cmp r0, #FS_FAT32
    beq .Lpf_fat32
    cmp r0, #FS_EXFAT
    beq .Lpf_fat32
.Lpf_interr:
    movs r0, #FR_INT_ERR                    @   (no case: res stays FR_INT_ERR)
    b .Lpf_ret
.Lpf_fat12:                                 @   case FS_FAT12:
    add r7, r5, r5, lsr #1                  @     bc = (UINT)clst; bc += bc / 2;
    lsrs r1, r7, #9
    ldr r2, [r4, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r4
    bl ff16_move_window                     @     res = move_window(fs, fs->fatbase + (bc / SS));
    cmp r0, #0                              @     if (res != FR_OK) break;
    bne .Lpf_ret
    ubfx r1, r7, #0, #9                        @     p = fs->win + bc++ % SS;
    add r8, r4, #FS_WIN
    add r8, r8, r1
    adds r7, r7, #1
    tst r5, #1                              @     *p = (clst & 1) ? ((*p & 0x0F) | ((BYTE)val << 4)) : (BYTE)val;
    beq 1f
    ldrb r0, [r8]
    and r0, r0, #0x0F
    orr r0, r0, r6, lsl #4                  @     (only the low 8 bits are stored)
    strb r0, [r8]
    b 2f
1:  strb r6, [r8]
2:  movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @     fs->wflag = 1;
    lsrs r1, r7, #9
    ldr r2, [r4, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r4
    bl ff16_move_window                     @     res = move_window(fs, fs->fatbase + (bc / SS));
    cmp r0, #0                              @     if (res != FR_OK) break;
    bne .Lpf_ret
    ubfx r1, r7, #0, #9                        @     p = fs->win + bc % SS;
    add r8, r4, #FS_WIN
    add r8, r8, r1
    tst r5, #1                              @     *p = (clst & 1) ? (BYTE)(val >> 4) : ((*p & 0xF0) | ((BYTE)(val >> 8) & 0x0F));
    beq 3f
    lsrs r0, r6, #4
    strb r0, [r8]
    b 4f
3:  ldrb r0, [r8]
    and r0, r0, #0xF0
    lsrs r1, r6, #8
    and r1, r1, #0x0F
    orrs r0, r0, r1
    strb r0, [r8]
4:  movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @     fs->wflag = 1;
    movs r0, #FR_OK                         @     (res is FR_OK here)
    b .Lpf_ret
.Lpf_fat16:                                 @   case FS_FAT16:
    lsrs r1, r5, #8                         @     clst / (SS / 2)
    ldr r2, [r4, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r4
    bl ff16_move_window                     @     res = move_window(fs, fs->fatbase + (clst / (SS / 2)));
    cmp r0, #0                              @     if (res != FR_OK) break;
    bne .Lpf_ret
    lsls r0, r5, #1                         @     st_16(fs->win + clst * 2 % SS, (WORD)val);
    ubfx r0, r0, #0, #9
    add r0, r0, r4
    add r0, r0, #FS_WIN
    uxth r1, r6
    bl ff16_st_16
    movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @     fs->wflag = 1;
    movs r0, #FR_OK
    b .Lpf_ret
.Lpf_fat32:                                 @   case FS_FAT32: case FS_EXFAT:
    lsrs r1, r5, #7                         @     clst / (SS / 4)
    ldr r2, [r4, #FS_FATBASE]
    add r1, r1, r2
    mov r0, r4
    bl ff16_move_window                     @     res = move_window(fs, fs->fatbase + (clst / (SS / 4)));
    cmp r0, #0                              @     if (res != FR_OK) break;
    bne .Lpf_ret
    lsls r7, r5, #2                         @     r7 = &fs->win[clst * 4 % SS]
    ubfx r7, r7, #0, #9
    add r7, r7, r4
    add r7, r7, #FS_WIN
    ldrb r0, [r4, #FS_FS_TYPE]              @     if (!FF_FS_EXFAT || fs->fs_type != FS_EXFAT) {
    cmp r0, #FS_EXFAT
    beq 5f
    mov r0, r7                              @       val = (val & 0x0FFFFFFF) | (ld_32(fs->win + clst * 4 % SS) & 0xF0000000);
    bl ff16_ld_32
    and r0, r0, #0xF0000000                 @       (FAT32 keeps the top 4 bits of the entry)
    bic r6, r6, #0xF0000000
    orr r6, r6, r0                          @     }
5:  mov r0, r7                              @     st_32(fs->win + clst * 4 % SS, val);
    mov r1, r6
    bl ff16_st_32
    movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @     fs->wflag = 1;
    movs r0, #FR_OK
.Lpf_ret:
    pop {r4, r5, r6, r7, r8, pc}            @ return res;
ENDFUNC ff16_put_fat

@ -----------------------------------------------------------------------------
@ find_bitmap - DWORD find_bitmap(FATFS* fs, DWORD clst, DWORD ncl): find ncl contiguous free clusters in the exFAT
@ allocation bitmap, searching from clst and wrapping round (exists only when writing)
@ In       : r0 = fs, r1 = clst (start), r2 = ncl
@ Out      : r0 = first cluster of the free run / 0 no free run / 0xFFFFFFFF disk error
@ Clobbers : r1-r3, r12, flags
@ r10 caches fs->n_fatent - 2 (not changed by the loop).  i, bm and bv live in r2, r3, r1: they are rebuilt after each
@ move_window, which is the only call.
@ -----------------------------------------------------------------------------
FUNC ff16_find_bitmap
    push {r4, r5, r6, r7, r8, r9, r10, lr}  @ r4 fs, r5 clst, r6 ncl, r7 val, r8 scl, r9 ctr, r10 n_fatent - 2
    mov r4, r0
    subs r5, r1, #2                         @ clst -= 2;
    mov r6, r2
    ldr r10, [r4, #FS_N_FATENT]
    subs r10, r10, #2
    cmp r5, r10                             @ if (clst >= fs->n_fatent - 2) clst = 0;
    blo 1f
    movs r5, #0
1:  mov r7, r5                              @ scl = val = clst; ctr = 0;
    mov r8, r5
    movs r9, #0
.Lfb_outer:                                 @ for (;;) {
    lsrs r1, r7, #12                        @   val / 8 / SS
    ldr r0, [r4, #FS_BITBASE]
    add r1, r1, r0
    mov r0, r4
    bl ff16_move_window                     @   if (move_window(fs, fs->bitbase + val / 8 / SS) != FR_OK)
    cbz r0, 2f
    mvn r0, #0                              @     return 0xFFFFFFFF;
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
2:  ubfx r2, r7, #3, #9                     @   i = val / 8 % SS;
    and r1, r7, #7                          @   bm = 1 << (val % 8);
    movs r3, #1
    lsls r3, r3, r1
.Lfb_bit:                                   @   do { do {
    add r0, r4, #FS_WIN
    ldrb r0, [r0, r2]                       @     bv = fs->win[i] & bm;
    and r1, r0, r3
    lsls r3, r3, #1                         @     bm <<= 1;   (BYTE)
    uxtb r3, r3
    adds r7, r7, #1                         @     if (++val >= fs->n_fatent - 2) {
    cmp r7, r10
    blo 3f
    movs r7, #0                             @       val = 0; bm = 0; i = SS;
    movs r3, #0
    mov r2, #512
3:  cbnz r1, 4f                             @     }  if (bv == 0) {
    adds r9, r9, #1                         @       if (++ctr == ncl) return scl + 2;
    cmp r9, r6
    bne 5f
    adds r0, r8, #2
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
4:  mov r8, r7                              @     } else { scl = val; ctr = 0; }
    movs r9, #0
5:  cmp r7, r5                              @     if (val == clst) return 0;
    bne 6f
    movs r0, #0
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
6:  cmp r3, #0                              @     } while (bm != 0);
    bne .Lfb_bit
    movs r3, #1                             @     bm = 1;
    adds r2, r2, #1                         @   } while (++i < SS);
    cmp r2, #512
    blo .Lfb_bit
    b .Lfb_outer                            @ }
ENDFUNC ff16_find_bitmap

@ -----------------------------------------------------------------------------
@ change_bitmap - FRESULT change_bitmap(FATFS* fs, DWORD clst, DWORD ncl, int bv): set (bv=1) or clear (bv=0) ncl bits
@ of the exFAT allocation bitmap from cluster clst on (exists only when writing)
@ In       : r0 = fs, r1 = clst, r2 = ncl, r3 = bv
@ Out      : r0 = FR_OK / FR_DISK_ERR / FR_INT_ERR (a bit already had the new value)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_change_bitmap
    push {r4, r5, r6, r7, r8, r9, r10, lr}  @ r4 fs, r5 ncl, r6 bv, r7 sect, r8 i, r9 bm, r10 fs->win
    mov r4, r0
    mov r5, r2
    mov r6, r3
    subs r1, r1, #2                         @ clst -= 2;
    lsrs r7, r1, #12                        @ sect = fs->bitbase + clst / 8 / SS;
    ldr r0, [r4, #FS_BITBASE]
    add r7, r7, r0
    ubfx r8, r1, #3, #9                     @ i = clst / 8 % SS;
    and r2, r1, #7                          @ bm = 1 << (clst % 8);
    movs r0, #1
    lsls r9, r0, r2
    add r10, r4, #FS_WIN
.Lcb_outer:                                 @ for (;;) {
    mov r0, r4
    mov r1, r7
    adds r7, r7, #1
    bl ff16_move_window                     @   if (move_window(fs, sect++) != FR_OK) return FR_DISK_ERR;
    cbz r0, .Lcb_bit
    movs r0, #FR_DISK_ERR
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
.Lcb_bit:                                   @   do { do {
    ldrb r0, [r10, r8]                      @     if (bv == (int)((fs->win[i] & bm) != 0)) return FR_INT_ERR;
    tst r0, r9
    beq 1f
    cmp r6, #1                              @       (bit set: error if bv == 1)
    beq .Lcb_interr
    b 2f
1:  cbz r6, .Lcb_interr                     @       (bit clear: error if bv == 0)
2:  eor r0, r0, r9                          @     fs->win[i] ^= bm;
    strb r0, [r10, r8]
    movs r0, #1
    strb r0, [r4, #FS_WFLAG]                @     fs->wflag = 1;
    subs r5, r5, #1                         @     if (--ncl == 0) return FR_OK;
    bne 3f
    movs r0, #FR_OK
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
3:  lsls r9, r9, #1                         @     } while (bm <<= 1);   (BYTE: 0x80 << 1 gives 0)
    ands r9, r9, #0xFF
    bne .Lcb_bit
    movs r9, #1                             @     bm = 1;
    adds r8, r8, #1                         @   } while (++i < SS);
    cmp r8, #512
    blo .Lcb_bit
    movs r8, #0                             @   i = 0;
    b .Lcb_outer                            @ }
.Lcb_interr:
    movs r0, #FR_INT_ERR
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_change_bitmap

@ -----------------------------------------------------------------------------
@ fill_first_frag - FRESULT fill_first_frag(FFOBJID* obj): write the FAT chain of the first fragment if it was
@ contiguous (stat == 3) (exists only when writing)
@ In       : r0 = obj
@ Out      : r0 = FR_OK or the error of put_fat
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_fill_first_frag
    push {r4, r5, r6, lr}                   @ r4 obj, r5 cl, r6 n
    mov r4, r0
    ldrb r0, [r4, #OBJ_STAT]                @ if (obj->stat == 3) {
    cmp r0, #3
    bne 3f
    ldr r5, [r4, #OBJ_SCLUST]               @   for (cl = obj->sclust, n = obj->n_cont; n; cl++, n--) {
    ldr r6, [r4, #OBJ_N_CONT]
1:  cbz r6, 2f
    ldr r0, [r4, #OBJ_FS]                   @     res = put_fat(obj->fs, cl, cl + 1);
    mov r1, r5
    adds r2, r5, #1
    bl ff16_put_fat
    cbnz r0, 4f                             @     if (res != FR_OK) return res;
    adds r5, r5, #1
    subs r6, r6, #1
    b 1b                                    @   }
2:  movs r0, #0
    strb r0, [r4, #OBJ_STAT]                @   obj->stat = 0;
3:  movs r0, #FR_OK                         @ } return FR_OK;
4:  pop {r4, r5, r6, pc}
ENDFUNC ff16_fill_first_frag

@ -----------------------------------------------------------------------------
@ fill_last_frag - FRESULT fill_last_frag(FFOBJID* obj, DWORD lcl, DWORD term): write the FAT chain of the last
@ (fragmented) part, ending with term (exists only when writing)
@ In       : r0 = obj, r1 = lcl (last cluster), r2 = term
@ Out      : r0 = FR_OK or the error of put_fat
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_fill_last_frag
    push {r4, r5, r6, lr}                   @ r4 obj, r5 lcl, r6 term
    mov r4, r0
    mov r5, r1
    mov r6, r2
1:  ldr r3, [r4, #OBJ_N_FRAG]               @ while (obj->n_frag > 0) {
    cbz r3, 3f
    subs r1, r5, r3                         @   put_fat(obj->fs, lcl - obj->n_frag + 1,
    adds r1, r1, #1
    cmp r3, #1                              @       (obj->n_frag > 1) ? lcl - obj->n_frag + 2 : term);
    bhi 2f
    mov r2, r6
    b 5f
2:  adds r2, r1, #1
5:  ldr r0, [r4, #OBJ_FS]
    bl ff16_put_fat                         @   res = put_fat(...);
    cbnz r0, 4f                             @   if (res != FR_OK) return res;
    ldr r3, [r4, #OBJ_N_FRAG]
    subs r3, r3, #1
    str r3, [r4, #OBJ_N_FRAG]               @   obj->n_frag--;
    b 1b                                    @ }
3:  movs r0, #FR_OK                         @ return FR_OK;
4:  pop {r4, r5, r6, pc}
ENDFUNC ff16_fill_last_frag

@ -----------------------------------------------------------------------------
@ remove_chain - FRESULT remove_chain(FFOBJID* obj, DWORD clst, DWORD pclst): free a cluster chain from clst on;
@ pclst is the preceding cluster that becomes the chain end (0 = remove the whole chain) (exists only when writing)
@ In       : r0 = obj, r1 = clst, r2 = pclst
@ Out      : r0 = FR_OK / FR_DISK_ERR / FR_INT_ERR (or the error of put_fat / change_bitmap)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_remove_chain
    push {r4, r5, r6, r7, r8, r9, r10, lr}  @ r4 obj, r5 clst, r6 pclst, r7 fs, r8 scl, r9 ecl, r10 nxt
    mov r4, r0
    mov r5, r1
    mov r6, r2
    ldr r7, [r4, #OBJ_FS]                   @ FATFS *fs = obj->fs;
    mov r8, r5                              @ DWORD scl = clst, ecl = clst;
    mov r9, r5
    cmp r5, #2                              @ if (clst < 2 || clst >= fs->n_fatent) return FR_INT_ERR;
    blo .Lrc_interr
    ldr r0, [r7, #FS_N_FATENT]
    cmp r5, r0
    bhs .Lrc_interr
    cmp r6, #0                              @ if (pclst != 0 && (!FF_FS_EXFAT || fs->fs_type != FS_EXFAT || obj->stat != 2)) {
    beq .Lrc_loop
    ldrb r0, [r7, #FS_FS_TYPE]
    cmp r0, #FS_EXFAT
    bne 1f
    ldrb r0, [r4, #OBJ_STAT]
    cmp r0, #2
    beq .Lrc_loop
1:  mov r0, r7                              @   res = put_fat(fs, pclst, 0xFFFFFFFF);  (terminate the chain at pclst)
    mov r1, r6
    mvn r2, #0
    bl ff16_put_fat
    cmp r0, #FR_OK                          @   if (res != FR_OK) return res;
    bne .Lrc_ret                            @ }
.Lrc_loop:                                  @ do {
    mov r0, r4
    mov r1, r5
    bl ff16_get_fat                         @   nxt = get_fat(obj, clst);
    mov r10, r0
    cmp r10, #0                             @   if (nxt == 0) break;
    beq .Lrc_done
    cmp r10, #1                             @   if (nxt == 1) return FR_INT_ERR;
    beq .Lrc_interr
    cmp r10, #0xFFFFFFFF                    @   if (nxt == 0xFFFFFFFF) return FR_DISK_ERR;
    beq .Lrc_diskerr
    ldrb r0, [r7, #FS_FS_TYPE]              @   if (!FF_FS_EXFAT || fs->fs_type != FS_EXFAT) {
    cmp r0, #FS_EXFAT
    beq 2f
    mov r0, r7                              @     res = put_fat(fs, clst, 0);
    mov r1, r5
    movs r2, #0
    bl ff16_put_fat
    cmp r0, #FR_OK                          @     if (res != FR_OK) return res;
    bne .Lrc_ret                            @   }
2:  ldr r0, [r7, #FS_FREE_CLST]             @   if (fs->free_clst < fs->n_fatent - 2) {
    ldr r1, [r7, #FS_N_FATENT]
    subs r1, r1, #2
    cmp r0, r1
    bhs 3f
    adds r0, r0, #1                         @     fs->free_clst++;
    str r0, [r7, #FS_FREE_CLST]
    ldrb r0, [r7, #FS_FSI_FLAG]             @     fs->fsi_flag |= 1;
    orr r0, r0, #1
    strb r0, [r7, #FS_FSI_FLAG]             @   }
3:  adds r0, r9, #1                         @   if (ecl + 1 == nxt) {
    cmp r0, r10
    bne 4f
    mov r9, r10                             @     ecl = nxt;
    b 6f                                    @   } else {
4:  ldrb r0, [r7, #FS_FS_TYPE]              @     if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne 5f
    mov r0, r7                              @       res = change_bitmap(fs, scl, ecl - scl + 1, 0);
    mov r1, r8
    sub r2, r9, r8
    adds r2, r2, #1
    movs r3, #0
    bl ff16_change_bitmap
    cmp r0, #FR_OK                          @       if (res != FR_OK) return res;
    bne .Lrc_ret                            @     }
5:  mov r8, r10                             @     scl = ecl = nxt;
    mov r9, r10                             @   }
6:  mov r5, r10                             @   clst = nxt;
    ldr r0, [r7, #FS_N_FATENT]              @ } while (clst < fs->n_fatent);
    cmp r5, r0
    blo .Lrc_loop
.Lrc_done:
    ldrb r0, [r7, #FS_FS_TYPE]              @ if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lrc_ok
    cmp r6, #0                              @   if (pclst == 0) {
    bne 7f
    movs r0, #0
    strb r0, [r4, #OBJ_STAT]                @     obj->stat = 0;   (the object has no cluster any more)
    b .Lrc_ok
7:  ldrb r0, [r4, #OBJ_STAT]                @   } else { if (obj->stat == 0) {
    cmp r0, #0
    bne 12f
    ldr r5, [r4, #OBJ_SCLUST]               @     clst = obj->sclust;
8:  cmp r5, r6                              @     while (clst != pclst) {
    beq 10f
    mov r0, r4
    mov r1, r5
    bl ff16_get_fat                         @       nxt = get_fat(obj, clst);
    mov r10, r0
    cmp r10, #2                             @       if (nxt < 2) return FR_INT_ERR;
    blo .Lrc_interr
    cmp r10, #0xFFFFFFFF                    @       if (nxt == 0xFFFFFFFF) return FR_DISK_ERR;
    beq .Lrc_diskerr
    adds r0, r5, #1                         @       if (nxt != clst + 1) break;
    cmp r10, r0
    bne 10f
    mov r5, r0                              @       clst++;
    b 8b                                    @     }
10: cmp r5, r6                              @     if (clst == pclst) {
    bne .Lrc_ok
    movs r0, #2
    strb r0, [r4, #OBJ_STAT]                @       obj->stat = 2;   (the remaining chain is contiguous)
    b .Lrc_ok                               @     }
12: cmp r0, #3                              @   } else { if (obj->stat == 3 && pclst >= obj->sclust
    bne .Lrc_ok
    ldr r1, [r4, #OBJ_SCLUST]
    cmp r6, r1
    blo .Lrc_ok
    ldr r2, [r4, #OBJ_N_CONT]               @        && pclst <= obj->sclust + obj->n_cont)
    adds r1, r1, r2
    cmp r6, r1
    bhi .Lrc_ok
    movs r0, #2
    strb r0, [r4, #OBJ_STAT]                @     obj->stat = 2;
.Lrc_ok:
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lrc_ret
.Lrc_interr:
    movs r0, #FR_INT_ERR
    b .Lrc_ret
.Lrc_diskerr:
    movs r0, #FR_DISK_ERR
.Lrc_ret:
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_remove_chain

@ -----------------------------------------------------------------------------
@ create_chain - DWORD create_chain(FFOBJID* obj, DWORD clst): extend a chain by one cluster (clst = 0: start a new
@ chain), searching free clusters from the chain end / last allocated cluster (exists only when writing)
@ In       : r0 = obj, r1 = clst (last cluster of the chain, 0 for a new chain)
@ Out      : r0 = new cluster (>= 2) / 0 no free cluster / 1 internal error / 0xFFFFFFFF disk error, or the existing
@            next cluster number if the chain already continues
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_create_chain
    push {r4, r5, r6, r7, r8, r9, r10, lr}  @ r4 obj, r5 clst, r6 fs, r7 scl, r8 ncl, r9 res, r10 cs
    mov r4, r0
    mov r5, r1
    ldr r6, [r4, #OBJ_FS]                   @ FATFS *fs = obj->fs;
    cmp r5, #0                              @ if (clst == 0) {
    bne 2f
    ldr r7, [r6, #FS_LAST_CLST]             @   scl = fs->last_clst;
    cmp r7, #0                              @   if (scl == 0 || scl >= fs->n_fatent) scl = 1;
    beq 1f
    ldr r0, [r6, #FS_N_FATENT]
    cmp r7, r0
    blo 5f
1:  movs r7, #1
    b 5f
2:  mov r0, r4                              @ } else {
    mov r1, r5
    bl ff16_get_fat                         @   cs = get_fat(obj, clst);
    mov r10, r0
    cmp r10, #2                             @   if (cs < 2) return 1;
    bhs 3f
    movs r0, #1
    b .Lcc_ret
3:  cmp r10, #0xFFFFFFFF                    @   if (cs == 0xFFFFFFFF) return cs;
    beq .Lcc_retcs
    ldr r0, [r6, #FS_N_FATENT]              @   if (cs < fs->n_fatent) return cs;
    cmp r10, r0
    blo .Lcc_retcs
    mov r7, r5                              @   scl = clst;
5:  ldr r0, [r6, #FS_FREE_CLST]             @ }  if (fs->free_clst == 0) return 0;
    cmp r0, #0
    bne 6f
    movs r0, #0
    b .Lcc_ret
6:  ldrb r0, [r6, #FS_FS_TYPE]              @ if (fs->fs_type == FS_EXFAT) {
    cmp r0, #FS_EXFAT
    bne .Lcc_fat
    mov r0, r6                              @   ncl = find_bitmap(fs, scl, 1);
    mov r1, r7
    movs r2, #1
    bl ff16_find_bitmap
    mov r8, r0
    cmp r8, #0                              @   if (ncl == 0 || ncl == 0xFFFFFFFF) return ncl;
    beq .Lcc_retncl
    cmp r8, #0xFFFFFFFF
    beq .Lcc_retncl
    mov r0, r6                              @   res = change_bitmap(fs, ncl, 1, 1);
    mov r1, r8
    movs r2, #1
    movs r3, #1
    bl ff16_change_bitmap
    mov r9, r0
    cmp r9, #FR_INT_ERR                     @   if (res == FR_INT_ERR) return 1;
    beq .Lcc_one
    cmp r9, #FR_DISK_ERR                    @   if (res == FR_DISK_ERR) return 0xFFFFFFFF;
    beq .Lcc_ffff
    cmp r5, #0                              @   if (clst == 0) {
    bne 7f
    movs r0, #2
    strb r0, [r4, #OBJ_STAT]                @     obj->stat = 2;   (a new object starts as one contiguous chain)
    b 9f
7:  ldrb r0, [r4, #OBJ_STAT]                @   } else { if (obj->stat == 2 && ncl != scl + 1) {
    cmp r0, #2
    bne 9f
    adds r0, r7, #1
    cmp r8, r0
    beq 9f
    ldr r0, [r4, #OBJ_SCLUST]               @     obj->n_cont = scl - obj->sclust;
    subs r0, r7, r0
    str r0, [r4, #OBJ_N_CONT]
    movs r0, #3
    strb r0, [r4, #OBJ_STAT]                @     obj->stat = 3;   (first fragment ends at scl, not yet in the FAT)
9:  ldrb r0, [r4, #OBJ_STAT]                @   } }  if (obj->stat != 2) {
    cmp r0, #2
    beq .Lcc_fin
    adds r0, r5, #1                         @     if (ncl == clst + 1) {
    cmp r8, r0
    bne 10f
    ldr r0, [r4, #OBJ_N_FRAG]               @       obj->n_frag = obj->n_frag ? obj->n_frag + 1 : 2;
    cmp r0, #0
    beq 11f
    adds r0, r0, #1
    b 12f
11: movs r0, #2
12: str r0, [r4, #OBJ_N_FRAG]
    b .Lcc_fin                              @     } else {
10: ldr r0, [r4, #OBJ_N_FRAG]               @       if (obj->n_frag == 0) obj->n_frag = 1;
    cmp r0, #0
    bne 13f
    movs r0, #1
    str r0, [r4, #OBJ_N_FRAG]
13: mov r0, r4                              @       res = fill_last_frag(obj, clst, ncl);
    mov r1, r5
    mov r2, r8
    bl ff16_fill_last_frag
    mov r9, r0
    cmp r9, #FR_OK                          @       if (res == FR_OK) obj->n_frag = 1;
    bne .Lcc_fin
    movs r0, #1
    str r0, [r4, #OBJ_N_FRAG]
    b .Lcc_fin                              @     } }
.Lcc_fat:                                   @ } else {   (FAT12/16/32)
    movs r8, #0                             @   ncl = 0;
    cmp r7, r5                              @   if (scl == clst) {
    bne 20f
    adds r8, r7, #1                         @     ncl = scl + 1;
    ldr r0, [r6, #FS_N_FATENT]              @     if (ncl >= fs->n_fatent) ncl = 2;
    cmp r8, r0
    blo 14f
    movs r8, #2
14: mov r0, r4                              @     cs = get_fat(obj, ncl);
    mov r1, r8
    bl ff16_get_fat
    mov r10, r0
    cmp r10, #1                             @     if (cs == 1 || cs == 0xFFFFFFFF) return cs;
    beq .Lcc_retcs
    cmp r10, #0xFFFFFFFF
    beq .Lcc_retcs
    cmp r10, #0                             @     if (cs != 0) {
    beq 20f
    ldr r10, [r6, #FS_LAST_CLST]            @       cs = fs->last_clst;
    cmp r10, #2                             @       if (cs >= 2 && cs < fs->n_fatent) scl = cs;
    blo 15f
    ldr r0, [r6, #FS_N_FATENT]
    cmp r10, r0
    bhs 15f
    mov r7, r10
15: movs r8, #0                             @       ncl = 0;
20: cmp r8, #0                              @   } }  if (ncl == 0) {
    bne 30f
    mov r8, r7                              @     ncl = scl;
16: adds r8, r8, #1                         @     for (;;) { ncl++;
    ldr r0, [r6, #FS_N_FATENT]              @       if (ncl >= fs->n_fatent) {
    cmp r8, r0
    blo 17f
    movs r8, #2                             @         ncl = 2;
    cmp r8, r7                              @         if (ncl > scl) return 0;
    bls 17f
    movs r0, #0
    b .Lcc_ret
17: mov r0, r4                              @       }  cs = get_fat(obj, ncl);
    mov r1, r8
    bl ff16_get_fat
    mov r10, r0
    cmp r10, #0                             @       if (cs == 0) break;
    beq 30f
    cmp r10, #1                             @       if (cs == 1 || cs == 0xFFFFFFFF) return cs;
    beq .Lcc_retcs
    cmp r10, #0xFFFFFFFF
    beq .Lcc_retcs
    cmp r8, r7                              @       if (ncl == scl) return 0;
    bne 16b
    movs r0, #0
    b .Lcc_ret                              @     }
30: mov r0, r6                              @   }  res = put_fat(fs, ncl, 0xFFFFFFFF);
    mov r1, r8
    mvn r2, #0
    bl ff16_put_fat
    mov r9, r0
    cmp r9, #FR_OK                          @   if (res == FR_OK && clst != 0) {
    bne .Lcc_fin
    cmp r5, #0
    beq .Lcc_fin
    mov r0, r6                              @     res = put_fat(fs, clst, ncl);
    mov r1, r5
    mov r2, r8
    bl ff16_put_fat
    mov r9, r0                              @   }
.Lcc_fin:                                   @ }
    cmp r9, #FR_OK                          @ if (res == FR_OK) {
    bne 40f
    str r8, [r6, #FS_LAST_CLST]             @   fs->last_clst = ncl;
    ldr r0, [r6, #FS_FREE_CLST]             @   if (fs->free_clst > 0 && fs->free_clst <= fs->n_fatent - 2) {
    cmp r0, #0
    beq .Lcc_retncl
    ldr r1, [r6, #FS_N_FATENT]
    subs r1, r1, #2
    cmp r0, r1
    bhi .Lcc_retncl
    subs r0, r0, #1                         @     fs->free_clst--;
    str r0, [r6, #FS_FREE_CLST]
    ldrb r0, [r6, #FS_FSI_FLAG]             @     fs->fsi_flag |= 1;
    orr r0, r0, #1
    strb r0, [r6, #FS_FSI_FLAG]             @   }
    b .Lcc_retncl                           @ } else {
40: cmp r9, #FR_DISK_ERR                    @   ncl = (res == FR_DISK_ERR) ? 0xFFFFFFFF : 1;
    beq .Lcc_ffff
.Lcc_one:
    movs r0, #1
    b .Lcc_ret
.Lcc_ffff:
    mvn r0, #0
    b .Lcc_ret
.Lcc_retcs:
    mov r0, r10
    b .Lcc_ret
.Lcc_retncl:
    mov r0, r8                              @ return ncl;
.Lcc_ret:
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_create_chain

@ -----------------------------------------------------------------------------
@ dir_clear - FRESULT dir_clear(FATFS* fs, DWORD clst): fill a cluster with zero (a new directory table)
@ (exists only when writing)
@ In       : r0 = fs, r1 = clst
@ Out      : r0 = FR_OK / FR_DISK_ERR
@ Clobbers : r1-r3, r12, flags
@ The window is cleared and written sector by sector (the non-FF_USE_LFN buffer variant of ff.c is not compiled).
@ -----------------------------------------------------------------------------
FUNC ff16_dir_clear
    push {r4, r5, r6, lr}                   @ r4 fs, r5 clst / sect, r6 n
    mov r4, r0
    mov r5, r1
    bl ff16_sync_window                     @ if (sync_window(fs) != FR_OK) return FR_DISK_ERR;
    cbz r0, 1f
    movs r0, #FR_DISK_ERR
    pop {r4, r5, r6, pc}
1:  mov r0, r4                              @ sect = clst2sect(fs, clst);
    mov r1, r5
    bl ff16_clst2sect
    mov r5, r0
    str r5, [r4, #FS_WINSECT]               @ fs->winsect = sect;
    add r0, r4, #FS_WIN
    movs r1, #0
    mov r2, #512
    bl ff16_mem_set                         @ memset(fs->win, 0, sizeof fs->win);
    movs r6, #0                             @ ibuf = fs->win; szb = 1; for (n = 0; ...
2:  ldrh r0, [r4, #FS_CSIZE]                @   n < fs->csize
    cmp r6, r0
    bhs 3f
    ldrb r0, [r4, #FS_PDRV]                 @   && disk_write(fs->pdrv, ibuf, sect + n, szb) == RES_OK
    add r1, r4, #FS_WIN
    add r2, r5, r6
    movs r3, #1
    bl disk_write
    cbnz r0, 3f
    adds r6, r6, #1                         @   ; n += szb) ;
    b 2b
3:  ldrh r0, [r4, #FS_CSIZE]                @ return (n == fs->csize) ? FR_OK : FR_DISK_ERR;
    cmp r6, r0
    bne 4f
    movs r0, #FR_OK
    pop {r4, r5, r6, pc}
4:  movs r0, #FR_DISK_ERR
    pop {r4, r5, r6, pc}
ENDFUNC ff16_dir_clear
.endif

@ -----------------------------------------------------------------------------
@ oem2uni_sbcs (ffunicode.c) - WCHAR oem2uni_sbcs(WCHAR oem, WORD cp): single byte OEM code to Unicode, code page 437
@ In       : r0 = oem, r1 = cp
@ Out      : r0 = Unicode, 0 if cp is not 437 or oem - 0x80 >= 0x80
@ Clobbers : r1, r2, flags
@ -----------------------------------------------------------------------------
FUNC ff16_oem2uni_sbcs
    uxth r0, r0                             @ (WCHAR oem)
    uxth r1, r1                             @ (WORD cp)
    movw r2, #CODEPAGE
    cmp r1, r2                              @ const WCHAR* tbl = 0; if (cp == 437) tbl = uc437;
    bne 1f
    subs r0, r0, #0x80                      @ oem -= 0x80;   (WCHAR arithmetic: wraps at 16 bits)
    uxth r0, r0
    cmp r0, #0x80                           @ if (tbl && oem < 0x80) uni = tbl[oem];
    bhs 1f
    ldr r2, =ff16_uc437
    ldrh r0, [r2, r0, lsl #1]
    bx lr                                   @ return uni;
1:  movs r0, #0                             @ uni = 0
    bx lr
    .ltorg
ENDFUNC ff16_oem2uni_sbcs

@ -----------------------------------------------------------------------------
@ uni2oem_sbcs (ffunicode.c) - WCHAR uni2oem_sbcs(DWORD uni, WORD cp): Unicode to single byte OEM code, code page 437
@ In       : r0 = uni, r1 = cp
@ Out      : r0 = OEM code 0x80..0xFF, 0 if cp is not 437 or the character is not in the upper half of the table
@ Clobbers : r1-r3, flags
@ -----------------------------------------------------------------------------
FUNC ff16_uni2oem_sbcs
    uxth r1, r1                             @ (WORD cp)
    movw r2, #CODEPAGE
    cmp r1, r2                              @ const WCHAR* tbl = 0; if (cp == 437) tbl = uc437;
    bne 3f                                  @ oem = 0 when there is no table
    ldr r2, =ff16_uc437
    movs r1, #0                             @ if (tbl) { for (i = 0; i < 0x80 && uni != tbl[i]; i++) ;
1:  cmp r1, #0x80
    bhs 2f
    ldrh r3, [r2, r1, lsl #1]
    cmp r0, r3
    beq 2f
    adds r1, r1, #1
    b 1b
2:  add r0, r1, #0x80                       @   oem = (i + 0x80) & 0xFF; }
    uxtb r0, r0
    bx lr                                   @ return oem;
3:  movs r0, #0
    bx lr
    .ltorg
ENDFUNC ff16_uni2oem_sbcs

@ -----------------------------------------------------------------------------
@ ff_uni2oem (ffunicode.c) - WCHAR ff_uni2oem(DWORD uni, WORD cp): Unicode to OEM code
@ In       : r0 = uni, r1 = cp
@ Out      : r0 = OEM code, 0 if there is none
@ Clobbers : r1-r3, flags
@ -----------------------------------------------------------------------------
FUNC ff16_ff_uni2oem
    cmp r0, #0x80                           @ if (uni < 0x80) return (WCHAR)uni;
    blo 1f
    cmp r0, #0x10000                        @ if (uni >= 0x10000) return 0;
    bhs 2f
    b ff16_uni2oem_sbcs                     @ return uni2oem_sbcs(uni, cp);   (tail call)
2:  movs r0, #0
1:  bx lr
ENDFUNC ff16_ff_uni2oem

@ -----------------------------------------------------------------------------
@ ff_oem2uni (ffunicode.c) - WCHAR ff_oem2uni(WCHAR oem, WORD cp): OEM code to Unicode
@ In       : r0 = oem, r1 = cp
@ Out      : r0 = Unicode, 0 if there is none
@ Clobbers : r1, r2, flags
@ -----------------------------------------------------------------------------
FUNC ff16_ff_oem2uni
    uxth r0, r0                             @ (WCHAR oem)
    cmp r0, #0x80                           @ if (oem < 0x80) return oem;
    blo 1f
    b ff16_oem2uni_sbcs                     @ return oem2uni_sbcs(oem, cp);   (tail call)
1:  bx lr
ENDFUNC ff16_ff_oem2uni

@ -----------------------------------------------------------------------------
@ ff_wtoupper (ffunicode.c) - DWORD ff_wtoupper(DWORD uni): Unicode upper case conversion (exFAT up-case table)
@ The two tables below (cvt1 for uni < 0x1000, cvt2 above) are runs: bc (first character), then nc (low byte: length
@ of the run, high byte: command cmd), and for cmd 0 nc translation values.  Commands: 0 = table lookup p[uc - bc],
@ 1 = uc -= (uc - bc) & 1 (even/odd pairs), 2..5 = uc -= 16 / 32 / 48 / 26, 6 = uc += 8, 7 = uc -= 80,
@ 8 = uc -= 0x1C60.  The tables end with bc = 0.
@ In       : r0 = uni
@ Out      : r0 = upper case character (uni unchanged if >= 0x10000 or not in a run)
@ Clobbers : r1-r3, r12, flags
@ Register use: r0 uc, r1 p, r2 bc then (uc - bc), r3 nc, r12 cmd.  "uc < bc + nc" is tested as (uc - bc) < nc, valid
@ because uc >= bc is known at that point.
@ -----------------------------------------------------------------------------
FUNC ff16_ff_wtoupper
    cmp r0, #0x10000                        @ if (uni < 0x10000) {
    bhs 9f
    cmp r0, #0x1000                         @   uc = (WORD)uni;  p = uc < 0x1000 ? cvt1 : cvt2;
    bhs 1f
    ldr r1, =.Lwtoupper_cvt1
    b 2f
1:  ldr r1, =.Lwtoupper_cvt2
2:  ldrh r2, [r1], #2                       @   for (;;) { bc = *p++;
    cmp r2, #0                              @     if (bc == 0 || uc < bc) break;
    beq 8f
    cmp r0, r2
    blo 8f
    ldrh r3, [r1], #2                       @     nc = *p++; cmd = nc >> 8; nc &= 0xFF;
    lsrs r12, r3, #8
    uxtb r3, r3
    subs r2, r0, r2                         @     r2 = uc - bc
    cmp r2, r3                              @     if (uc < bc + nc) { switch (cmd) {
    bhs 7f
    cmp r12, #0                             @       case 0: uc = p[uc - bc]; break;
    bne 3f
    ldrh r0, [r1, r2, lsl #1]
    b 8f
3:  cmp r12, #1                             @       case 1: uc -= (uc - bc) & 1; break;
    bne 4f
    and r2, r2, #1
    subs r0, r0, r2
    b 8f
4:  cmp r12, #2                             @       case 2: uc -= 16; break;
    bne 5f
    subs r0, r0, #16
    b 8f
5:  cmp r12, #3                             @       case 3: uc -= 32; break;
    bne 6f
    subs r0, r0, #32
    b 8f
6:  cmp r12, #4                             @       case 4: uc -= 48; break;
    bne 10f
    subs r0, r0, #48
    b 8f
10: cmp r12, #5                             @       case 5: uc -= 26; break;
    bne 11f
    subs r0, r0, #26
    b 8f
11: cmp r12, #6                             @       case 6: uc += 8; break;
    bne 12f
    adds r0, r0, #8
    b 8f
12: cmp r12, #7                             @       case 7: uc -= 80; break;
    bne 13f
    subs r0, r0, #80
    b 8f
13: cmp r12, #8                             @       case 8: uc -= 0x1C60; break;
    bne 8f                                  @       (any other cmd: no change)
    movw r2, #0x1C60
    subs r0, r0, r2
    b 8f                                    @     } break; }
7:  cmp r12, #0                             @     if (cmd == 0) p += nc;
    bne 2b
    add r1, r1, r3, lsl #1                  @     (p is a WORD pointer)
    b 2b                                    @   }
8:  uxth r0, r0                             @   uni = uc;   (WORD)
9:  bx lr                                   @ } return uni;
    .ltorg
ENDFUNC ff16_ff_wtoupper

@ =============================================================================
@ Constant tables
@ =============================================================================
    .section .rodata.ff16x.low, "a", %progbits

@ ff.c LfnOfs[]: byte offsets of the 13 name characters inside one 32-byte LFN directory entry (ff_x.c line 194)
    .global ff16_LfnOfs
    .type ff16_LfnOfs, %object
ff16_LfnOfs:
    .byte 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30
    .size ff16_LfnOfs, . - ff16_LfnOfs

@ ff.c ExCvt[]: code page 437 upper case conversion of the OEM characters 0x80..0xFF for SFN names (ff_x.c line 197)
    .global ff16_ExCvt
    .type ff16_ExCvt, %object
ff16_ExCvt:
    .byte 0x80, 0x9A, 0x45, 0x41, 0x8E, 0x41, 0x8F, 0x80, 0x45, 0x45, 0x45, 0x49, 0x49, 0x49, 0x8E, 0x8F
    .byte 0x90, 0x92, 0x92, 0x4F, 0x99, 0x4F, 0x55, 0x55, 0x59, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F
    .byte 0x41, 0x49, 0x4F, 0x55, 0xA5, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF
    .byte 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF
    .byte 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF
    .byte 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF
    .byte 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF
    .byte 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF
    .size ff16_ExCvt, . - ff16_ExCvt

@ ffunicode.c uc437[]: code page 437 characters 0x80..0xFF to Unicode (ffunicode_x.c line 327 ff.)
    .balign 2
    .global ff16_uc437
    .type ff16_uc437, %object
ff16_uc437:
    .hword 0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7, 0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5
    .hword 0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9, 0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192
    .hword 0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA, 0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB
    .hword 0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556, 0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510
    .hword 0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567
    .hword 0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B, 0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580
    .hword 0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4, 0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229
    .hword 0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248, 0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0
    .size ff16_uc437, . - ff16_uc437

@ ffunicode.c ff_wtoupper() cvt1[] (uni < 0x1000) and cvt2[]: up-case run tables, format in the ff_wtoupper header
    .balign 2
.Lwtoupper_cvt1:
    .hword 0x0061, 0x031A
    .hword 0x00E0, 0x0317
    .hword 0x00F8, 0x0307
    .hword 0x00FF, 0x0001, 0x0178
    .hword 0x0100, 0x0130
    .hword 0x0132, 0x0106
    .hword 0x0139, 0x0110
    .hword 0x014A, 0x012E
    .hword 0x0179, 0x0106
    .hword 0x0180, 0x004D, 0x0243, 0x0181, 0x0182, 0x0182, 0x0184, 0x0184, 0x0186, 0x0187, 0x0187, 0x0189, 0x018A
    .hword 0x018B, 0x018B, 0x018D, 0x018E, 0x018F, 0x0190, 0x0191, 0x0191, 0x0193, 0x0194, 0x01F6, 0x0196, 0x0197
    .hword 0x0198, 0x0198, 0x023D, 0x019B, 0x019C, 0x019D, 0x0220, 0x019F, 0x01A0, 0x01A0, 0x01A2, 0x01A2, 0x01A4
    .hword 0x01A4, 0x01A6, 0x01A7, 0x01A7, 0x01A9, 0x01AA, 0x01AB, 0x01AC, 0x01AC, 0x01AE, 0x01AF, 0x01AF, 0x01B1
    .hword 0x01B2, 0x01B3, 0x01B3, 0x01B5, 0x01B5, 0x01B7, 0x01B8, 0x01B8, 0x01BA, 0x01BB, 0x01BC, 0x01BC, 0x01BE
    .hword 0x01F7, 0x01C0, 0x01C1, 0x01C2, 0x01C3, 0x01C4, 0x01C5, 0x01C4, 0x01C7, 0x01C8, 0x01C7, 0x01CA, 0x01CB
    .hword 0x01CA
    .hword 0x01CD, 0x0110
    .hword 0x01DD, 0x0001, 0x018E
    .hword 0x01DE, 0x0112
    .hword 0x01F3, 0x0003, 0x01F1, 0x01F4, 0x01F4
    .hword 0x01F8, 0x0128
    .hword 0x0222, 0x0112
    .hword 0x023A, 0x0009, 0x2C65, 0x023B, 0x023B, 0x023D, 0x2C66, 0x023F, 0x0240, 0x0241, 0x0241
    .hword 0x0246, 0x010A
    .hword 0x0253, 0x0040, 0x0181, 0x0186, 0x0255, 0x0189, 0x018A, 0x0258, 0x018F, 0x025A, 0x0190, 0x025C, 0x025D
    .hword 0x025E, 0x025F, 0x0193, 0x0261, 0x0262, 0x0194, 0x0264, 0x0265, 0x0266, 0x0267, 0x0197, 0x0196, 0x026A
    .hword 0x2C62, 0x026C, 0x026D, 0x026E, 0x019C, 0x0270, 0x0271, 0x019D, 0x0273, 0x0274, 0x019F, 0x0276, 0x0277
    .hword 0x0278, 0x0279, 0x027A, 0x027B, 0x027C, 0x2C64, 0x027E, 0x027F, 0x01A6, 0x0281, 0x0282, 0x01A9, 0x0284
    .hword 0x0285, 0x0286, 0x0287, 0x01AE, 0x0244, 0x01B1, 0x01B2, 0x0245, 0x028D, 0x028E, 0x028F, 0x0290, 0x0291
    .hword 0x01B7
    .hword 0x037B, 0x0003, 0x03FD, 0x03FE, 0x03FF
    .hword 0x03AC, 0x0004, 0x0386, 0x0388, 0x0389, 0x038A
    .hword 0x03B1, 0x0311
    .hword 0x03C2, 0x0002, 0x03A3, 0x03A3
    .hword 0x03C4, 0x0308
    .hword 0x03CC, 0x0003, 0x038C, 0x038E, 0x038F
    .hword 0x03D8, 0x0118
    .hword 0x03F2, 0x000A, 0x03F9, 0x03F3, 0x03F4, 0x03F5, 0x03F6, 0x03F7, 0x03F7, 0x03F9, 0x03FA, 0x03FA
    .hword 0x0430, 0x0320
    .hword 0x0450, 0x0710
    .hword 0x0460, 0x0122
    .hword 0x048A, 0x0136
    .hword 0x04C1, 0x010E
    .hword 0x04CF, 0x0001, 0x04C0
    .hword 0x04D0, 0x0144
    .hword 0x0561, 0x0426
    .hword 0x0000
.Lwtoupper_cvt1_end:
.Lwtoupper_cvt2:
    .hword 0x1D7D, 0x0001, 0x2C63
    .hword 0x1E00, 0x0196
    .hword 0x1EA0, 0x015A
    .hword 0x1F00, 0x0608
    .hword 0x1F10, 0x0606
    .hword 0x1F20, 0x0608
    .hword 0x1F30, 0x0608
    .hword 0x1F40, 0x0606
    .hword 0x1F51, 0x0007, 0x1F59, 0x1F52, 0x1F5B, 0x1F54, 0x1F5D, 0x1F56, 0x1F5F
    .hword 0x1F60, 0x0608
    .hword 0x1F70, 0x000E, 0x1FBA, 0x1FBB, 0x1FC8, 0x1FC9, 0x1FCA, 0x1FCB, 0x1FDA, 0x1FDB, 0x1FF8, 0x1FF9, 0x1FEA
    .hword 0x1FEB, 0x1FFA, 0x1FFB
    .hword 0x1F80, 0x0608
    .hword 0x1F90, 0x0608
    .hword 0x1FA0, 0x0608
    .hword 0x1FB0, 0x0004, 0x1FB8, 0x1FB9, 0x1FB2, 0x1FBC
    .hword 0x1FCC, 0x0001, 0x1FC3
    .hword 0x1FD0, 0x0602
    .hword 0x1FE0, 0x0602
    .hword 0x1FE5, 0x0001, 0x1FEC
    .hword 0x1FF3, 0x0001, 0x1FFC
    .hword 0x214E, 0x0001, 0x2132
    .hword 0x2170, 0x0210
    .hword 0x2184, 0x0001, 0x2183
    .hword 0x24D0, 0x051A
    .hword 0x2C30, 0x042F
    .hword 0x2C60, 0x0102
    .hword 0x2C67, 0x0106, 0x2C75, 0x0102
    .hword 0x2C80, 0x0164
    .hword 0x2D00, 0x0826
    .hword 0xFF41, 0x031A
    .hword 0x0000
.Lwtoupper_cvt2_end:

@ =============================================================================
@ RAM: the module's static data, zero initialised as in ff.c
@ =============================================================================
    .section .bss_port.ff16x.low, "aw", %nobits
    .balign 4

@ static FATFS *FatFs[FF_VOLUMES]: the mounted file system of the single volume (ff_x.c line 192)
    .global ff16_FatFs
    .type ff16_FatFs, %object
ff16_FatFs:     .space 4
    .size ff16_FatFs, . - ff16_FatFs

@ static WORD Fsid: mount id counter, incremented by mount_volume (ff_x.c line 193)
    .global ff16_Fsid
    .type ff16_Fsid, %object
ff16_Fsid:      .space 2
    .size ff16_Fsid, . - ff16_Fsid

@ static WCHAR LfnBuf[FF_MAX_LFN + 1]: the long file name working buffer, 256 WCHAR (ff_x.c line 196)
    .balign 2
    .global ff16_LfnBuf
    .type ff16_LfnBuf, %object
ff16_LfnBuf:    .space 512
    .size ff16_LfnBuf, . - ff16_LfnBuf

@ static BYTE DirBuf[MAXDIRB(FF_MAX_LFN)]: the exFAT directory entry set buffer, (255 + 44) / 15 * 32 = 608 bytes
@ (ff_x.c line 195)
    .global ff16_DirBuf
    .type ff16_DirBuf, %object
ff16_DirBuf:    .space 608
    .size ff16_DirBuf, . - ff16_DirBuf
