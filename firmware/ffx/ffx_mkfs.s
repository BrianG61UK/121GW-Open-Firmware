@ =============================================================================
@ ffx_mkfs.s - FatFs R0.16 w/patch 2, exFAT configuration: partitioning (create_partition) and volume creation (f_mkfs)
@ (DESIGN.md 7A, IMP-32)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c, as preprocessed to ff_x.c for the exFAT configuration of
@ ff16x.inc): create_partition and f_mkfs, both inside FF_USE_MKFS (so absent from the bootloader image, which assembles
@ this file with FF_USE_MKFS 0).  Each routine names the C function it translates; the code follows the C statements in
@ order and the comments quote or paraphrase them.  Calling convention AAPCS (r0-r3, r12 scratch, r4-r11 preserved).
@
@ FatFs license (ChaN): "FatFs module is an open source software. Redistribution and use of FatFs in source and binary forms,
@ with or without modification, are permitted provided that the following condition is met: 1. Redistributions of source
@ code must retain the above copyright notice, this condition and the following disclaimer.  This software is provided by
@ the copyright holder and contributors "AS IS" and any warranties related to this software are DISCLAIMED.  The copyright
@ owner or contributors be NOT LIABLE for any damages caused by use of this software."  Copyright (C) 2025, ChaN, all right
@ reserved.
@
@ Notes on the translation of the preprocessed C:
@  - ss (sector size) is the local "WORD ss = 512" of f_mkfs, never modified: it is the constant 512 here (ss/32 = 16,
@    "/ ss" = ">> 9", "* ss" = "<< 9").
@  - Code that the preprocessor left as constant-false (FF_MULTI_PARTITION 0: "if (0 && ipart != 0) {...}", ipart is
@    always 0) is not translated; constant-true conditions ("1 &&") are folded.
@  - Types: LBA_t and DWORD are 32-bit (FF_LBA64 0), so all LBA arithmetic is 32-bit unsigned (udiv, wrap-around kept).
@  - Calls to other groups: ff16_get_ldnumber, ff16_mem_set, ff16_mem_cpy, ff16_st_16/32/64, ff16_xsum32,
@    ff16_ff_wtoupper, the global ff16_FatFs, and the disk layer (disk_initialize, disk_write, disk_ioctl, get_fattime).
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ff16x.inc"

    .if FF_USE_MKFS

@ MKFS_PARM layout (ff.h lines 281-287, ARM EABI): BYTE fmt; BYTE n_fat; UINT align; UINT n_root; DWORD au_size;
    .equ MKFS_FMT, 0
    .equ MKFS_N_FAT, 1
    .equ MKFS_ALIGN, 4
    .equ MKFS_N_ROOT, 8
    .equ MKFS_AU_SIZE, 12
@ disk_ioctl command codes as they appear in ff_x.c (diskio.h CTRL_SYNC / GET_SECTOR_COUNT / GET_BLOCK_SIZE; ff.c 1145,
@ 5914, 6082)
    .equ CTRL_SYNC, 0
    .equ GET_SECTOR_COUNT, 1
    .equ GET_BLOCK_SIZE, 3

@ f_mkfs stack frame (bytes from sp after the prologue); every local that is not kept in a register
    .equ L_path, 0                          @ const TCHAR* path (its address goes to get_ldnumber)
    .equ L_opt, 4                           @ const MKFS_PARM* opt
    .equ L_fsopt, 8                         @ BYTE fsopt
    .equ L_fsty, 12                         @ BYTE fsty
    .equ L_sys, 16                          @ BYTE sys
    .equ L_sz_blk, 20                       @ DWORD sz_blk
    .equ L_n_clst, 24                       @ DWORD n_clst
    .equ L_pau, 28                          @ DWORD pau
    .equ L_nsect, 32                        @ DWORD nsect
    .equ L_n, 36                            @ DWORD n
    .equ L_vsn, 40                          @ DWORD vsn
    .equ L_b_fat, 44                        @ LBA_t b_fat
    .equ L_b_data, 48                       @ LBA_t b_data
    .equ L_lba, 52                          @ LBA_t lba[2] (8 bytes)
    .equ L_sz_rsv, 60                       @ DWORD sz_rsv
    .equ L_sz_fat, 64                       @ DWORD sz_fat
    .equ L_sz_dir, 68                       @ DWORD sz_dir
    .equ L_n_fat, 72                        @ UINT n_fat
    .equ L_n_root, 76                       @ UINT n_root
    .equ L_szb_bit, 80                      @ DWORD szb_bit
    .equ L_szb_case, 84                     @ DWORD szb_case
    .equ L_sum, 88                          @ DWORD sum
    .equ L_nbit, 92                         @ DWORD nbit
    .equ L_clu, 96                          @ DWORD clu
    .equ L_clen, 100                        @ DWORD clen[3] (12 bytes)
    .equ L_si, 112                          @ WCHAR si (kept zero-extended)
    .equ L_j, 116                           @ UINT j
    .equ L_st, 120                          @ UINT st
    .equ L_ch, 124                          @ WCHAR ch (kept zero-extended)
    .equ L_szvol, 128                       @ LBA_t receiving disk_ioctl(GET_SECTOR_COUNT) (sz_vol)
    .equ MK_FRAME, 132                      @ 132 + 9 pushed words = 168, a multiple of 8
@ Registers held through f_mkfs: r4 = buf, r5 = sz_buf, r6 = sz_vol, r7 = pdrv, r8 = sect, r9 = sz_au, r10 = b_vol,
@ r11 = i (loop index of the buffer loops)

@ -----------------------------------------------------------------------------
@ Local macros
@ -----------------------------------------------------------------------------
    .macro LA reg, sym                      @ reg = address of sym (no literal pool)
    movw \reg, #:lower16:\sym
    movt \reg, #:upper16:\sym
    .endm

    .macro MOV32 reg, val                   @ reg = 32-bit constant val
    movw \reg, #(\val) & 0xFFFF
    movt \reg, #((\val) >> 16) & 0xFFFF
    .endm

    .macro PST16 off                        @ st_16(buf + off, r1)
    add r0, r4, #\off
    bl ff16_st_16
    .endm

    .macro PST32 off                        @ st_32(buf + off, r1)
    add r0, r4, #\off
    bl ff16_st_32
    .endm

    .macro PBYTE off, imm                   @ buf[off] = imm
    movs r0, #\imm
    strb r0, [r4, #\off]
    .endm

    .macro MEMSET_SS                        @ memset(buf, 0, ss)
    mov r0, r4
    movs r1, #0
    mov r2, #512
    bl ff16_mem_set
    .endm

    .macro MEMSET_BUF                       @ memset(buf, 0, sz_buf * ss)
    mov r0, r4
    movs r1, #0
    lsls r2, r5, #9
    bl ff16_mem_set
    .endm

    .macro CALC_N                           @ n = (nsect > sz_buf) ? sz_buf : nsect;
    ldr r1, [sp, #L_nsect]
    cmp r1, r5
    it hi
    movhi r1, r5
    str r1, [sp, #L_n]
    .endm

    .macro WRITE_N                          @ if (disk_write(pdrv, buf, sect, n) != RES_OK) return FR_DISK_ERR;
    mov r0, r7
    mov r1, r4
    mov r2, r8
    ldr r3, [sp, #L_n]
    bl disk_write
    cmp r0, #0
    bne.w .Lmk_diskerr
    .endm

    .macro ADV_N                            @ sect += n; nsect -= n;   (flags left by the final subs: Z = nsect == 0)
    ldr r1, [sp, #L_n]
    add r8, r8, r1
    ldr r2, [sp, #L_nsect]
    subs r2, r2, r1
    str r2, [sp, #L_nsect]
    .endm

    .macro WR1                              @ if (disk_write(pdrv, buf, sect++, 1) != RES_OK) return FR_DISK_ERR;
    mov r0, r7
    mov r1, r4
    mov r2, r8
    movs r3, #1
    adds r8, r8, #1
    bl disk_write
    cmp r0, #0
    bne.w .Lmk_diskerr
    .endm

    .macro DW1 sectreg                      @ disk_write(pdrv, buf, sectreg, 1) with the result left in r0
    mov r0, r7
    mov r1, r4
    mov r2, \sectreg
    movs r3, #1
    bl disk_write
    .endm

    .section .rodata.ff16x.mkfs, "a", %progbits
    .balign 4
@ static const WORD cst[] = {1, 4, 16, 64, 256, 512, 0};      cluster size candidates (sectors) for FAT12/16
ff16x_mkfs_cst:
    .hword 1, 4, 16, 64, 256, 512, 0
@ static const WORD cst32[] = {1, 2, 4, 8, 16, 32, 0};         cluster size candidates (x 0x20000 sectors) for FAT32
ff16x_mkfs_cst32:
    .hword 1, 2, 4, 8, 16, 32, 0
    .balign 4
@ static const MKFS_PARM defopt = {FM_ANY (0x07), 0, 0, 0, 0};
ff16x_mkfs_defopt:
    .byte 0x07, 0, 0, 0                     @ fmt, n_fat, padding
    .word 0, 0, 0                           @ align, n_root, au_size
@ "\xEB\x76\x90" "EXFAT   " (11 bytes): exFAT boot sector jump and OEM name
ff16x_mkfs_exfat_oem:
    .byte 0xEB, 0x76, 0x90
    .ascii "EXFAT   "
@ "\xEB\xFE\x90" "MSDOS5.0" (11 bytes): FAT boot sector jump and OEM name
ff16x_mkfs_fat_oem:
    .byte 0xEB, 0xFE, 0x90
    .ascii "MSDOS5.0"
@ "NO NAME    " "FAT32   " (19 bytes): FAT32 volume label and file system type string
ff16x_mkfs_fat32_lbl:
    .ascii "NO NAME    FAT32   "
@ "NO NAME    " "FAT     " (19 bytes): FAT12/16 volume label and file system type string
ff16x_mkfs_fat_lbl:
    .ascii "NO NAME    FAT     "

    .section .text.ff16x.mkfs, "ax", %progbits

@ -----------------------------------------------------------------------------
@ create_partition - write an MBR with up to four partitions (ff.c create_partition; FF_LBA64 0)
@ In       : r0 = drv (BYTE), r1 = plst (const LBA_t[]: sizes, <= 100 = percent of the drive), r2 = sys (BYTE system ID),
@            r3 = buf (BYTE*, working buffer of at least 512 bytes)
@ Out      : r0 = FRESULT (FR_OK, or FR_DISK_ERR when disk_ioctl / disk_write fail)
@ Clobbers : r1-r3, r12, flags (r4-r11 preserved)
@ Registers: r4 = drv, r5 = plst, r6 = sys, r7 = buf, r8 = sz_drv32, r9 = n_hd (n_sc is the constant 63),
@            r10 = nxt_alloc32, r11 = pte; stack: [sp+0] sz_drv, [sp+4] i, [sp+8] sz_part32
@ -----------------------------------------------------------------------------
    .equ CP_SZ_DRV, 0
    .equ CP_I, 4
    .equ CP_SZ_PART, 8

@ CP_CHS src, o_hd, o_sc, o_cy: store the CHS address of the LBA in src (not r1-r3, r12) at pte[o_hd], pte[o_sc], pte[o_cy]
@   cy = (UINT)(lba / n_sc / n_hd);  hd = (BYTE)(lba / n_sc % n_hd);  sc = (BYTE)(lba % n_sc + 1);
@   pte[o_hd] = hd;  pte[o_sc] = (BYTE)((cy >> 2 & 0xC0) | sc);  pte[o_cy] = (BYTE)cy;
    .macro CP_CHS src, o_hd, o_sc, o_cy
    movs r1, #63                            @ n_sc
    udiv r2, \src, r1                       @ lba / n_sc
    mls r3, r2, r1, \src                    @ lba % n_sc
    adds r3, r3, #1                         @ sc = lba % n_sc + 1
    udiv r12, r2, r9                        @ cy = lba / n_sc / n_hd
    mls r2, r12, r9, r2                     @ hd = lba / n_sc % n_hd
    strb r2, [r11, #\o_hd]                  @ pte[o_hd] = hd
    lsrs r2, r12, #2                        @ cy >> 2
    and r2, r2, #0xC0                       @ & 0xC0
    orrs r2, r2, r3                         @ | sc
    strb r2, [r11, #\o_sc]                  @ pte[o_sc] = (BYTE)((cy >> 2 & 0xC0) | sc)
    strb r12, [r11, #\o_cy]                 @ pte[o_cy] = (BYTE)cy
    .endm

FUNC ff16_create_partition
    push {r4-r11, lr}
    sub sp, sp, #12                         @ sz_drv, i, sz_part32 (36 + 12 = 48: stack stays 8-byte aligned)
    mov r4, r0                              @ drv
    mov r5, r1                              @ plst
    mov r6, r2                              @ sys
    mov r7, r3                              @ buf
    mov r0, r4                              @ if (disk_ioctl(drv, GET_SECTOR_COUNT, &sz_drv) != RES_OK) return FR_DISK_ERR;
    movs r1, #GET_SECTOR_COUNT
    add r2, sp, #CP_SZ_DRV
    bl disk_ioctl
    cmp r0, #0
    bne.w .Lcp_diskerr
    ldr r8, [sp, #CP_SZ_DRV]                @ sz_drv32 = (DWORD)sz_drv;
                                            @ n_sc = 63;   (constant in the code below)
    movs r9, #8                             @ for (n_hd = 8; ...
.Lcp_hd:
    cmp r9, #0                              @   n_hd != 0 &&
    beq .Lcp_hd_end
    udiv r0, r8, r9                         @   sz_drv32 / n_hd
    movs r1, #63
    udiv r0, r0, r1                         @   / n_sc
    cmp r0, #1024                           @   > 1024;
    bls .Lcp_hd_end
    lsls r9, r9, #1                         @   n_hd *= 2   (n_hd is a BYTE: 256 wraps to 0)
    uxtb r9, r9
    b .Lcp_hd
.Lcp_hd_end:
    cmp r9, #0                              @ if (n_hd == 0) n_hd = 255;
    bne 1f
    movs r9, #255
1:  mov r0, r7                              @ memset(buf, 0, 512);
    movs r1, #0
    mov r2, #512
    bl ff16_mem_set
    add r11, r7, #MBR_Table                 @ pte = buf + 446;
    movs r0, #0                             @ for (i = 0, nxt_alloc32 = n_sc; ...
    str r0, [sp, #CP_I]
    movs r10, #63
.Lcp_loop:
    ldr r0, [sp, #CP_I]                     @   i < 4 &&
    cmp r0, #4
    bhs .Lcp_done
    cmp r10, #0                             @   nxt_alloc32 != 0 &&
    beq .Lcp_done
    cmp r10, r8                             @   nxt_alloc32 < sz_drv32;
    bhs .Lcp_done
    ldr r0, [r5, r0, lsl #2]                @   sz_part32 = (DWORD)plst[i];
    cmp r0, #100                            @   if (sz_part32 <= 100)
    bhi 3f
    bne 2f
    mov r0, r8                              @     sz_part32 == 100: sz_part32 = sz_drv32
    b 3f
2:  movs r1, #100                           @     else sz_part32 = sz_drv32 / 100 * sz_part32;
    udiv r1, r8, r1
    mul r0, r1, r0
3:  add r1, r10, r0                         @   if (nxt_alloc32 + sz_part32 > sz_drv32 ||
    cmp r1, r8
    bhi 4f
    cmp r1, r10                             @       nxt_alloc32 + sz_part32 < nxt_alloc32)
    bhs 5f
4:  sub r0, r8, r10                         @     sz_part32 = sz_drv32 - nxt_alloc32;
5:  str r0, [sp, #CP_SZ_PART]
    cmp r0, #0                              @   if (sz_part32 == 0) break;
    beq .Lcp_done
    add r0, r11, #PTE_StLba                 @   st_32(pte + 8, nxt_alloc32);
    mov r1, r10
    bl ff16_st_32
    add r0, r11, #PTE_SizLba                @   st_32(pte + 12, sz_part32);
    ldr r1, [sp, #CP_SZ_PART]
    bl ff16_st_32
    strb r6, [r11, #PTE_System]             @   pte[4] = sys;
    CP_CHS r10, PTE_StHead, PTE_StSec, PTE_StCyl    @ start CHS of nxt_alloc32 into pte[1..3]
    ldr r0, [sp, #CP_SZ_PART]               @   end CHS of nxt_alloc32 + sz_part32 - 1 into pte[5..7]
    add r0, r0, r10
    subs r0, r0, #1
    CP_CHS r0, PTE_EdHead, PTE_EdSec, PTE_EdCyl
    add r11, r11, #SZ_PTE                   @   pte += 16;
    ldr r0, [sp, #CP_I]                     @   i++,
    adds r0, r0, #1
    str r0, [sp, #CP_I]
    ldr r0, [sp, #CP_SZ_PART]               @   nxt_alloc32 += sz_part32
    add r10, r10, r0
    b .Lcp_loop
.Lcp_done:
    add r0, r7, #BS_55AA                    @ st_16(buf + 510, 0xAA55);
    movw r1, #0xAA55
    bl ff16_st_16
    mov r0, r4                              @ if (disk_write(drv, buf, 0, 1) != RES_OK) return FR_DISK_ERR;
    mov r1, r7
    movs r2, #0
    movs r3, #1
    bl disk_write
    cmp r0, #0
    bne .Lcp_diskerr
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lcp_ret
.Lcp_diskerr:
    movs r0, #FR_DISK_ERR
.Lcp_ret:
    add sp, sp, #12
    pop {r4-r11, pc}
ENDFUNC ff16_create_partition

@ -----------------------------------------------------------------------------
@ mkfs_xsum_sector - local helper for f_mkfs: "for (i = 0; i < ss; sum = xsum32(buf[i++], sum)) ;"
@ In       : r0 = buf, r1 = sum
@ Out      : r0 = sum after the 512 bytes of buf have been folded in
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC ff16x_mkfs_xsum_sector
    push {r4-r6, lr}
    mov r4, r0                              @ buf
    mov r6, r1                              @ sum
    movs r5, #0                             @ i = 0
1:  ldrb r0, [r4, r5]                       @ sum = xsum32(buf[i++], sum);
    mov r1, r6
    bl ff16_xsum32
    mov r6, r0
    adds r5, r5, #1
    cmp r5, #512                            @ while (i < ss)
    blo 1b
    mov r0, r6
    pop {r4-r6, pc}
ENDFUNC ff16x_mkfs_xsum_sector

@ -----------------------------------------------------------------------------
@ f_mkfs - create an FAT/exFAT volume on drive 0 (ff.c f_mkfs; FF_MULTI_PARTITION 0, FF_LBA64 0, FF_USE_LFN 1 static)
@ In       : r0 = path (const TCHAR*, drive prefix), r1 = opt (const MKFS_PARM* or 0 for the defaults), r2 = work (working
@            buffer), r3 = len (size of the working buffer in bytes)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags (r4-r11 preserved)
@ -----------------------------------------------------------------------------
FUNC ff16_f_mkfs
    push {r4-r11, lr}
    sub sp, sp, #MK_FRAME
    str r0, [sp, #L_path]
    str r1, [sp, #L_opt]
    mov r4, r2                              @ buf = (BYTE*)work   (tested below, after the earlier checks as in C)
    mov r5, r3                              @ len                  (becomes sz_buf below)
    add r0, sp, #L_path                     @ vol = get_ldnumber(&path);
    bl ff16_get_ldnumber
    cmp r0, #0                              @ if (vol < 0) return FR_INVALID_DRIVE;
    bge 1f
    movs r0, #FR_INVALID_DRIVE
    b .Lmk_ret
1:  mov r7, r0                              @ r7 = vol
    LA r1, ff16_FatFs                       @ if (FatFs[vol]) FatFs[vol]->fs_type = 0;
    ldr r1, [r1, r7, lsl #2]
    cbz r1, 2f
    movs r2, #0
    strb r2, [r1, #FS_FS_TYPE]
2:  uxtb r7, r7                             @ pdrv = (BYTE)(vol);      (ipart = 0: constant)
    mov r0, r7                              @ ds = disk_initialize(pdrv);
    bl disk_initialize
    uxtb r0, r0
    tst r0, #0x01                           @ if (ds & STA_NOINIT) return FR_NOT_READY;
    beq 3f
    movs r0, #FR_NOT_READY
    b .Lmk_ret
3:  tst r0, #0x04                           @ if (ds & STA_PROTECT) return FR_WRITE_PROTECTED;
    beq 4f
    movs r0, #FR_WRITE_PROTECTED
    b .Lmk_ret
4:  ldr r0, [sp, #L_opt]                    @ if (!opt) opt = &defopt;
    cmp r0, #0
    bne 5f
    LA r0, ff16x_mkfs_defopt
    str r0, [sp, #L_opt]
5:  ldr r1, [r0, #MKFS_ALIGN]               @ sz_blk = opt->align;
    str r1, [sp, #L_sz_blk]
    cbnz r1, 6f                             @ if (sz_blk == 0) disk_ioctl(pdrv, GET_BLOCK_SIZE, &sz_blk);
    mov r0, r7
    movs r1, #GET_BLOCK_SIZE
    add r2, sp, #L_sz_blk
    bl disk_ioctl                           @ (result ignored, as in C)
6:  ldr r1, [sp, #L_sz_blk]                 @ if (sz_blk == 0 || sz_blk > 0x8000 || (sz_blk & (sz_blk - 1))) sz_blk = 1;
    cbz r1, 7f
    cmp r1, #0x8000
    bhi 7f
    subs r2, r1, #1
    tst r2, r1
    beq 8f
7:  movs r1, #1
    str r1, [sp, #L_sz_blk]
                                            @ ss = 512;   (constant)
8:  ldr r0, [sp, #L_opt]                    @ fsopt = opt->fmt & (FM_ANY | FM_SFD);
    ldrb r1, [r0, #MKFS_FMT]
    and r1, r1, #(FM_ANY | FM_SFD)
    str r1, [sp, #L_fsopt]
    ldrb r1, [r0, #MKFS_N_FAT]              @ n_fat = (opt->n_fat >= 1 && opt->n_fat <= 2) ? opt->n_fat : 1;
    subs r2, r1, #1
    cmp r2, #1
    bls 9f
    movs r1, #1
9:  str r1, [sp, #L_n_fat]
    ldr r1, [r0, #MKFS_N_ROOT]              @ n_root = (opt->n_root >= 1 && opt->n_root <= 32768 &&
    subs r2, r1, #1                         @            (opt->n_root % (ss / 32)) == 0) ? opt->n_root : 512;
    movw r3, #32768 - 1                     @   (n_root - 1 > 32767 also catches n_root == 0)
    cmp r2, r3
    bhi 10f
    tst r1, #15                             @ ss / 32 = 16
    beq 11f
10: mov r1, #512
11: str r1, [sp, #L_n_root]
    ldr r9, [r0, #MKFS_AU_SIZE]             @ sz_au = (opt->au_size <= 0x1000000 &&
    cmp r9, #0x1000000                      @           (opt->au_size & (opt->au_size - 1)) == 0) ? opt->au_size : 0;
    bhi 12f
    subs r2, r9, #1
    tst r2, r9
    beq 13f
12: movs r9, #0
13: lsrs r9, r9, #9                         @ sz_au /= ss;
    lsrs r5, r5, #9                         @ sz_buf = len / ss;
    bne 14f                                 @ if (sz_buf == 0) return FR_NOT_ENOUGH_CORE;
    movs r0, #FR_NOT_ENOUGH_CORE
    b .Lmk_ret
14: cmp r4, #0                              @ if (!buf) return FR_NOT_ENOUGH_CORE;
    bne 15f
    movs r0, #FR_NOT_ENOUGH_CORE
    b .Lmk_ret
15: movs r10, #0                            @ b_vol = sz_vol = 0;
    movs r0, #0
    str r0, [sp, #L_szvol]
                                            @ (if (0 && ipart != 0) {...} not translated: ipart is always 0)
    mov r0, r7                              @ if (disk_ioctl(pdrv, GET_SECTOR_COUNT, &sz_vol) != RES_OK) return FR_DISK_ERR;
    movs r1, #GET_SECTOR_COUNT
    add r2, sp, #L_szvol
    bl disk_ioctl
    cmp r0, #0
    bne.w .Lmk_diskerr
    ldr r6, [sp, #L_szvol]                  @ r6 = sz_vol
    ldr r0, [sp, #L_fsopt]                  @ if (!(fsopt & FM_SFD)) {
    tst r0, #FM_SFD
    bne 16f
    cmp r6, #63                             @   if (sz_vol > 63) {
    bls 16f
    movs r10, #63                           @     b_vol = 63; sz_vol -= b_vol;
    subs r6, r6, #63
16: cmp r6, #128                            @ if (sz_vol < 128) return FR_MKFS_ABORTED;
    blo.w .Lmk_abort
    @ do { ... } while (0): choose the file system type fsty
    ldr r0, [sp, #L_fsopt]
    tst r0, #FM_EXFAT                       @ if (1 && (fsopt & FM_EXFAT)) {
    beq 18f
    and r1, r0, #FM_ANY                     @   if ((fsopt & FM_ANY) == FM_EXFAT ||
    cmp r1, #FM_EXFAT
    beq 17f
    cmp r6, #0x4000000                      @       sz_vol >= 0x4000000 ||
    bhs 17f
    cmp r9, #128                            @       sz_au > 128) {
    bls 18f
17: movs r1, #FS_EXFAT                      @     fsty = FS_EXFAT; break;
    str r1, [sp, #L_fsty]
    b 22f
18: cmp r9, #128                            @ if (sz_au > 128) sz_au = 128;
    bls 19f
    movs r9, #128
19: tst r0, #FM_FAT32                       @ if (fsopt & FM_FAT32) {
    beq 20f
    tst r0, #FM_FAT                         @   if (!(fsopt & FM_FAT)) {
    bne 20f
    movs r1, #FS_FAT32                      @     fsty = FS_FAT32; break;
    str r1, [sp, #L_fsty]
    b 22f
20: tst r0, #FM_FAT                         @ if (!(fsopt & FM_FAT)) return FR_INVALID_PARAMETER;
    bne 21f
    movs r0, #FR_INVALID_PARAMETER
    b .Lmk_ret
21: movs r1, #FS_FAT16                      @ fsty = FS_FAT16;
    str r1, [sp, #L_fsty]
22: bl get_fattime                          @ vsn = (DWORD)sz_vol + get_fattime();
    add r0, r0, r6
    str r0, [sp, #L_vsn]
    ldr r0, [sp, #L_fsty]
    cmp r0, #FS_EXFAT                       @ if (fsty == FS_EXFAT) {
    bne.w .Lmk_fat

    @ ---------------------------------------------------------------- exFAT
    cmp r6, #0x1000                         @ if (sz_vol < 0x1000) return FR_MKFS_ABORTED;
    blo.w .Lmk_abort
    cmp r9, #0                              @ if (sz_au == 0) {
    bne 1f
    movs r9, #8                             @   sz_au = 8;
    cmp r6, #0x80000                        @   if (sz_vol >= 0x80000) sz_au = 64;
    blo 1f
    movs r9, #64
    cmp r6, #0x4000000                      @   if (sz_vol >= 0x4000000) sz_au = 256;
    blo 1f
    mov r9, #256
1:  add r0, r10, #32                        @ b_fat = b_vol + 32;
    str r0, [sp, #L_b_fat]
    udiv r0, r6, r9                         @ sz_fat = (DWORD)((sz_vol / sz_au + 2) * 4 + ss - 1) / ss;
    adds r0, r0, #2
    lsls r0, r0, #2
    add r0, r0, #511
    lsrs r0, r0, #9
    str r0, [sp, #L_sz_fat]
    ldr r1, [sp, #L_b_fat]                  @ b_data = (b_fat + sz_fat + sz_blk - 1) & ~((LBA_t)sz_blk - 1);
    add r1, r1, r0
    ldr r2, [sp, #L_sz_blk]
    add r1, r1, r2
    subs r1, r1, #1
    subs r2, r2, #1
    bic r1, r1, r2
    str r1, [sp, #L_b_data]
    sub r1, r1, r10                         @ if (b_data - b_vol >= sz_vol / 2) return FR_MKFS_ABORTED;
    lsrs r2, r6, #1
    cmp r1, r2
    bhs.w .Lmk_abort
    sub r0, r6, r1                          @ n_clst = (DWORD)((sz_vol - (b_data - b_vol)) / sz_au);
    udiv r0, r0, r9
    str r0, [sp, #L_n_clst]
    cmp r0, #16                             @ if (n_clst < 16) return FR_MKFS_ABORTED;
    blo.w .Lmk_abort
    MOV32 r1, 0x7FFFFFFD                    @ if (n_clst > 0x7FFFFFFD) return FR_MKFS_ABORTED;
    cmp r0, r1
    bhi.w .Lmk_abort
    adds r1, r0, #7                         @ szb_bit = (n_clst + 7) / 8;
    lsrs r1, r1, #3
    str r1, [sp, #L_szb_bit]
    lsls r2, r9, #9                         @ clen[0] = (szb_bit + sz_au * ss - 1) / (sz_au * ss);
    add r0, r1, r2
    subs r0, r0, #1
    udiv r0, r0, r2
    str r0, [sp, #L_clen]
    mul r1, r9, r0                          @ sect = b_data + sz_au * clen[0];
    ldr r2, [sp, #L_b_data]
    add r8, r1, r2
    movs r0, #0
    str r0, [sp, #L_sum]                    @ sum = 0;
    str r0, [sp, #L_st]                     @ st = 0;
    str r0, [sp, #L_si]                     @ si = 0;
    mov r11, #0                             @ i = 0;
    str r0, [sp, #L_j]                      @ j = 0;
    str r0, [sp, #L_szb_case]               @ szb_case = 0;

    @ up-case table generation: do { switch (st) {...} ... } while (si);
.Lmk_up:
    ldr r0, [sp, #L_st]
    cmp r0, #0                              @ switch (st)
    beq .Lmk_up_c0
    cmp r0, #1
    beq .Lmk_up_c1
    @ default:
    ldr r1, [sp, #L_j]                      @ ch = (WCHAR)j;
    uxth r1, r1
    str r1, [sp, #L_ch]
    ldr r2, [sp, #L_si]                     @ si += (WCHAR)j;
    add r2, r2, r1
    uxth r2, r2
    str r2, [sp, #L_si]
    movs r0, #0                             @ st = 0;
    str r0, [sp, #L_st]
    b .Lmk_up_store
.Lmk_up_c0:                                 @ case 0:
    ldr r0, [sp, #L_si]                     @ ch = (WCHAR)ff_wtoupper(si);
    bl ff16_ff_wtoupper
    uxth r0, r0
    str r0, [sp, #L_ch]
    ldr r1, [sp, #L_si]
    cmp r0, r1                              @ if (ch != si) { si++; break; }
    beq 2f
    adds r1, r1, #1
    uxth r1, r1
    str r1, [sp, #L_si]
    b .Lmk_up_store
2:  movs r0, #1                             @ for (j = 1; (WCHAR)(si + j) &&
    str r0, [sp, #L_j]
3:  ldr r0, [sp, #L_si]
    ldr r1, [sp, #L_j]
    add r0, r0, r1
    uxth r0, r0
    cbz r0, 4f
    bl ff16_ff_wtoupper                     @      (WCHAR)(si + j) == ff_wtoupper((WCHAR)(si + j)); j++) ;
    mov r2, r0                              @ r2 = ff_wtoupper(...)
    ldr r0, [sp, #L_si]
    ldr r1, [sp, #L_j]
    add r0, r0, r1
    uxth r0, r0
    cmp r0, r2
    bne 4f
    adds r1, r1, #1                         @ j++
    str r1, [sp, #L_j]
    b 3b
4:  ldr r1, [sp, #L_j]                      @ if (j >= 128) { ch = 0xFFFF; st = 2; break; }
    cmp r1, #128
    blo 5f
    movw r0, #0xFFFF
    str r0, [sp, #L_ch]
    movs r0, #2
    str r0, [sp, #L_st]
    b .Lmk_up_store
5:  movs r0, #1                             @ st = 1;   and fall through to case 1
    str r0, [sp, #L_st]
.Lmk_up_c1:                                 @ case 1:
    ldr r0, [sp, #L_si]                     @ ch = si++;
    str r0, [sp, #L_ch]
    adds r0, r0, #1
    uxth r0, r0
    str r0, [sp, #L_si]
    ldr r1, [sp, #L_j]                      @ if (--j == 0) st = 0;
    subs r1, r1, #1
    str r1, [sp, #L_j]
    bne.w .Lmk_up_store
    movs r0, #0
    str r0, [sp, #L_st]
.Lmk_up_store:
    ldr r0, [sp, #L_ch]                     @ sum = xsum32(buf[i + 0] = (BYTE)ch, sum);
    strb r0, [r4, r11]
    uxtb r0, r0
    ldr r1, [sp, #L_sum]
    bl ff16_xsum32
    str r0, [sp, #L_sum]
    ldr r0, [sp, #L_ch]                     @ sum = xsum32(buf[i + 1] = (BYTE)(ch >> 8), sum);
    lsrs r0, r0, #8
    add r2, r4, r11
    strb r0, [r2, #1]
    uxtb r0, r0
    ldr r1, [sp, #L_sum]
    bl ff16_xsum32
    str r0, [sp, #L_sum]
    add r11, r11, #2                        @ i += 2;
    ldr r0, [sp, #L_szb_case]               @ szb_case += 2;
    adds r0, r0, #2
    str r0, [sp, #L_szb_case]
    ldr r0, [sp, #L_si]                     @ if (si == 0 || i == sz_buf * ss) {
    cbz r0, 6f
    lsls r0, r5, #9
    cmp r11, r0
    bne 7f
6:  add r0, r11, #511                       @   n = (i + ss - 1) / ss;
    lsrs r0, r0, #9
    str r0, [sp, #L_n]
    WRITE_N                                 @   if (disk_write(pdrv, buf, sect, n) != RES_OK) return FR_DISK_ERR;
    ldr r1, [sp, #L_n]                      @   sect += n; i = 0;
    add r8, r8, r1
    mov r11, #0
7:  ldr r0, [sp, #L_si]                     @ } while (si);
    cmp r0, #0
    bne.w .Lmk_up

    ldr r0, [sp, #L_szb_case]               @ clen[1] = (szb_case + sz_au * ss - 1) / (sz_au * ss);
    lsls r2, r9, #9
    add r0, r0, r2
    subs r0, r0, #1
    udiv r0, r0, r2
    str r0, [sp, #L_clen + 4]
    movs r1, #1                             @ clen[2] = 1;
    str r1, [sp, #L_clen + 8]
    ldr r2, [sp, #L_b_data]                 @ sect = b_data;
    mov r8, r2
    ldr r1, [sp, #L_szb_bit]                @ nsect = (szb_bit + ss - 1) / ss;
    add r1, r1, #511
    lsrs r1, r1, #9
    str r1, [sp, #L_nsect]
    ldr r1, [sp, #L_clen]                   @ nbit = clen[0] + clen[1] + clen[2];
    add r1, r1, r0
    adds r1, r1, #1
    str r1, [sp, #L_nbit]

    @ allocation bitmap: do { ... } while (nsect);
.Lmk_bm:
    MEMSET_BUF                              @ memset(buf, 0, sz_buf * ss);
    mov r11, #0                             @ for (i = 0; nbit != 0 && i / 8 < sz_buf * ss;
    ldr r12, [sp, #L_nbit]
1:  cmp r12, #0
    beq 2f
    lsrs r0, r11, #3
    lsls r1, r5, #9
    cmp r0, r1
    bhs 2f
    ldrb r2, [r4, r0]                       @      buf[i / 8] |= 1 << (i % 8),
    and r3, r11, #7
    movs r1, #1
    lsls r1, r1, r3
    orrs r2, r2, r1
    strb r2, [r4, r0]
    add r11, r11, #1                        @      i++,
    subs r12, r12, #1                       @      nbit--) ;
    b 1b
2:  str r12, [sp, #L_nbit]
    CALC_N                                  @ n = (nsect > sz_buf) ? sz_buf : nsect;
    WRITE_N                                 @ if (disk_write(pdrv, buf, sect, n) != RES_OK) return FR_DISK_ERR;
    ADV_N                                   @ sect += n; nsect -= n;
    bne.w .Lmk_bm                           @ } while (nsect);

    @ FAT: sect = b_fat; nsect = sz_fat; j = nbit = clu = 0;
    ldr r8, [sp, #L_b_fat]
    ldr r0, [sp, #L_sz_fat]
    str r0, [sp, #L_nsect]
    movs r0, #0
    str r0, [sp, #L_j]
    str r0, [sp, #L_nbit]
    str r0, [sp, #L_clu]
.Lmk_fatx:                                  @ do {
    MEMSET_BUF                              @   memset(buf, 0, sz_buf * ss);
    mov r11, #0                             @   i = 0;
    ldr r0, [sp, #L_clu]                    @   if (clu == 0) {
    cbnz r0, 2f
    mvn r1, #7                              @     st_32(buf + i, 0xFFFFFFF8); i += 4; clu++;
    add r0, r4, r11
    bl ff16_st_32
    add r11, r11, #4
    mvn r1, #0                              @     st_32(buf + i, 0xFFFFFFFF); i += 4; clu++;
    add r0, r4, r11
    bl ff16_st_32
    add r11, r11, #4
    movs r0, #2                             @     (clu is 0 here, so clu++ twice = 2)
    str r0, [sp, #L_clu]
2:                                          @   do {
3:  ldr r12, [sp, #L_nbit]                  @     while (nbit != 0 && i < sz_buf * ss) {
    cmp r12, #0
    beq 5f
    lsls r0, r5, #9
    cmp r11, r0
    bhs 5f
    ldr r2, [sp, #L_clu]                    @       st_32(buf + i, (nbit > 1) ? clu + 1 : 0xFFFFFFFF);
    mvn r1, #0
    cmp r12, #1
    bls 4f
    adds r1, r2, #1
4:  add r0, r4, r11
    bl ff16_st_32
    add r11, r11, #4                        @       i += 4;
    ldr r2, [sp, #L_clu]                    @       clu++;
    adds r2, r2, #1
    str r2, [sp, #L_clu]
    ldr r12, [sp, #L_nbit]                  @       nbit--;
    subs r12, r12, #1
    str r12, [sp, #L_nbit]
    b 3b                                    @     }
5:  cmp r12, #0                             @     if (nbit == 0 && j < 3) nbit = clen[j++];
    bne 6f
    ldr r2, [sp, #L_j]
    cmp r2, #3
    bhs 6f
    add r1, sp, #L_clen
    ldr r0, [r1, r2, lsl #2]
    str r0, [sp, #L_nbit]
    adds r2, r2, #1
    str r2, [sp, #L_j]
6:  ldr r0, [sp, #L_nbit]                   @   } while (nbit != 0 && i < sz_buf * ss);
    cbz r0, 7f
    lsls r1, r5, #9
    cmp r11, r1
    blo 3b
7:  CALC_N                                  @   n = (nsect > sz_buf) ? sz_buf : nsect;
    WRITE_N                                 @   if (disk_write(pdrv, buf, sect, n) != RES_OK) return FR_DISK_ERR;
    ADV_N                                   @   sect += n; nsect -= n;
    bne.w .Lmk_fatx                         @ } while (nsect);

    @ root directory cluster: bitmap, up-case table and volume label entries
    MEMSET_BUF                              @ memset(buf, 0, sz_buf * ss);
    PBYTE 32*0+0, 0x83                    @ buf[32 * 0 + 0] = 0x83;     volume label entry
    PBYTE 32*1+0, 0x81                    @ buf[32 * 1 + 0] = 0x81;     allocation bitmap entry
    movs r1, #2                             @ st_32(buf + 32 * 1 + 20, 2);
    PST32 32*1+20
    ldr r1, [sp, #L_szb_bit]                @ st_32(buf + 32 * 1 + 24, szb_bit);
    PST32 32*1+24
    PBYTE 32*2+0, 0x82                    @ buf[32 * 2 + 0] = 0x82;     up-case table entry
    ldr r1, [sp, #L_sum]                    @ st_32(buf + 32 * 2 + 4, sum);
    PST32 32*2+4
    ldr r1, [sp, #L_clen]                   @ st_32(buf + 32 * 2 + 20, 2 + clen[0]);
    adds r1, r1, #2
    PST32 32*2+20
    ldr r1, [sp, #L_szb_case]               @ st_32(buf + 32 * 2 + 24, szb_case);
    PST32 32*2+24
    ldr r0, [sp, #L_clen]                   @ sect = b_data + sz_au * (clen[0] + clen[1]);
    ldr r1, [sp, #L_clen + 4]
    add r0, r0, r1
    mul r0, r9, r0
    ldr r1, [sp, #L_b_data]
    add r8, r0, r1
    str r9, [sp, #L_nsect]                  @ nsect = sz_au;
.Lmk_rdir:                                  @ do {
    CALC_N                                  @   n = (nsect > sz_buf) ? sz_buf : nsect;
    WRITE_N                                 @   if (disk_write(pdrv, buf, sect, n) != RES_OK) return FR_DISK_ERR;
    MEMSET_SS                               @   memset(buf, 0, ss);
    ADV_N                                   @   sect += n; nsect -= n;
    bne.w .Lmk_rdir                         @ } while (nsect);

    @ main and backup boot regions: for (n = 0; n < 2; n++)
    mov r8, r10                             @ sect = b_vol;
    movs r0, #0
    str r0, [sp, #L_n]
.Lmk_bs:
    MEMSET_SS                               @ memset(buf, 0, ss);
    mov r0, r4                              @ memcpy(buf + 0, "\xEB\x76\x90" "EXFAT   ", 11);
    LA r1, ff16x_mkfs_exfat_oem
    movs r2, #11
    bl ff16_mem_cpy
    add r0, r4, #BPB_VolOfsEx               @ st_64(buf + 64, b_vol);
    mov r2, r10
    movs r3, #0
    bl ff16_st_64
    add r0, r4, #BPB_TotSecEx               @ st_64(buf + 72, sz_vol);
    mov r2, r6
    movs r3, #0
    bl ff16_st_64
    ldr r1, [sp, #L_b_fat]                  @ st_32(buf + 80, (DWORD)(b_fat - b_vol));
    sub r1, r1, r10
    PST32 BPB_FatOfsEx
    ldr r1, [sp, #L_sz_fat]                 @ st_32(buf + 84, sz_fat);
    PST32 BPB_FatSzEx
    ldr r1, [sp, #L_b_data]                 @ st_32(buf + 88, (DWORD)(b_data - b_vol));
    sub r1, r1, r10
    PST32 BPB_DataOfsEx
    ldr r1, [sp, #L_n_clst]                 @ st_32(buf + 92, n_clst);
    PST32 BPB_NumClusEx
    ldr r1, [sp, #L_clen]                   @ st_32(buf + 96, 2 + clen[0] + clen[1]);
    ldr r2, [sp, #L_clen + 4]
    add r1, r1, r2
    adds r1, r1, #2
    PST32 BPB_RootClusEx
    ldr r1, [sp, #L_vsn]                    @ st_32(buf + 100, vsn);
    PST32 BPB_VolIDEx
    mov r1, #0x100                          @ st_16(buf + 104, 0x100);
    PST16 BPB_FSVerEx
    movs r0, #0                             @ for (buf[108] = 0, i = ss; i >>= 1; buf[108]++) ;
    strb r0, [r4, #BPB_BytsPerSecEx]
    mov r0, #512
1:  lsrs r0, r0, #1
    beq 2f
    ldrb r1, [r4, #BPB_BytsPerSecEx]
    adds r1, r1, #1
    strb r1, [r4, #BPB_BytsPerSecEx]
    b 1b
2:  movs r0, #0                             @ for (buf[109] = 0, i = sz_au; i >>= 1; buf[109]++) ;
    strb r0, [r4, #BPB_SecPerClusEx]
    mov r0, r9
3:  lsrs r0, r0, #1
    beq 4f
    ldrb r1, [r4, #BPB_SecPerClusEx]
    adds r1, r1, #1
    strb r1, [r4, #BPB_SecPerClusEx]
    b 3b
4:  PBYTE BPB_NumFATsEx, 1                  @ buf[110] = 1;
    PBYTE BPB_DrvNumEx, 0x80                @ buf[111] = 0x80;
    movw r1, #0xFEEB                        @ st_16(buf + 120, 0xFEEB);
    PST16 BS_BootCodeEx
    movw r1, #0xAA55                        @ st_16(buf + 510, 0xAA55);
    PST16 BS_55AA
    movs r0, #0                             @ for (i = sum = 0; i < ss; i++) {
    str r0, [sp, #L_sum]
    mov r11, #0
5:  cmp r11, #512
    bhs 7f
    cmp r11, #BPB_VolFlagEx                 @   if (i != 106 && i != 106 + 1 && i != 112)
    beq 6f
    cmp r11, #BPB_VolFlagEx + 1
    beq 6f
    cmp r11, #BPB_PercInUseEx
    beq 6f
    ldrb r0, [r4, r11]                      @     sum = xsum32(buf[i], sum);
    ldr r1, [sp, #L_sum]
    bl ff16_xsum32
    str r0, [sp, #L_sum]
6:  add r11, r11, #1
    b 5b                                    @ }
7:  WR1                                     @ if (disk_write(pdrv, buf, sect++, 1) != RES_OK) return FR_DISK_ERR;
    MEMSET_SS                               @ memset(buf, 0, ss);
    movw r1, #0xAA55                        @ st_16(buf + ss - 2, 0xAA55);
    PST16 BS_55AA
    movs r0, #1                             @ for (j = 1; j < 9; j++) {
    str r0, [sp, #L_j]
8:  ldr r0, [sp, #L_j]
    cmp r0, #9
    bhs 9f
    mov r0, r4                              @   for (i = 0; i < ss; sum = xsum32(buf[i++], sum)) ;
    ldr r1, [sp, #L_sum]
    bl ff16x_mkfs_xsum_sector
    str r0, [sp, #L_sum]
    WR1                                     @   if (disk_write(pdrv, buf, sect++, 1) != RES_OK) return FR_DISK_ERR;
    ldr r0, [sp, #L_j]
    adds r0, r0, #1
    str r0, [sp, #L_j]
    b 8b                                    @ }
9:  MEMSET_SS                               @ memset(buf, 0, ss);
10: ldr r0, [sp, #L_j]                      @ for ( ; j < 11; j++) {
    cmp r0, #11
    bhs 11f
    mov r0, r4                              @   for (i = 0; i < ss; sum = xsum32(buf[i++], sum)) ;
    ldr r1, [sp, #L_sum]
    bl ff16x_mkfs_xsum_sector
    str r0, [sp, #L_sum]
    WR1                                     @   if (disk_write(pdrv, buf, sect++, 1) != RES_OK) return FR_DISK_ERR;
    ldr r0, [sp, #L_j]
    adds r0, r0, #1
    str r0, [sp, #L_j]
    b 10b                                   @ }
11: mov r11, #0                             @ for (i = 0; i < ss; i += 4) st_32(buf + i, sum);
12: cmp r11, #512
    bhs 13f
    add r0, r4, r11
    ldr r1, [sp, #L_sum]
    bl ff16_st_32
    add r11, r11, #4
    b 12b
13: WR1                                     @ if (disk_write(pdrv, buf, sect++, 1) != RES_OK) return FR_DISK_ERR;
    ldr r0, [sp, #L_n]                      @ n++ ... while (n < 2)
    adds r0, r0, #1
    str r0, [sp, #L_n]
    cmp r0, #2
    blo.w .Lmk_bs
    b.w .Lmk_post                           @ } else { (FAT12/16/32 below)

    @ ------------------------------------------------------- FAT12 / FAT16 / FAT32
.Lmk_fat:
.Lmk_fatloop:                               @ do {
    str r9, [sp, #L_pau]                    @   pau = sz_au;
    ldr r0, [sp, #L_fsty]
    cmp r0, #FS_FAT32                       @   if (fsty == FS_FAT32) {
    bne .Lmk_fat1216
    cmp r9, #0                              @     if (pau == 0) {
    bne 3f
    lsrs r12, r6, #17                       @       n = (DWORD)sz_vol / 0x20000;
    str r12, [sp, #L_n]
    LA r0, ff16x_mkfs_cst32                 @       for (i = 0, pau = 1; cst32[i] && cst32[i] <= n; i++, pau <<= 1) ;
    movs r1, #1
    movs r2, #0
1:  ldrh r3, [r0, r2, lsl #1]
    cbz r3, 2f
    cmp r3, r12
    bhi 2f
    adds r2, r2, #1
    lsls r1, r1, #1
    b 1b
2:  str r1, [sp, #L_pau]
3:  ldr r1, [sp, #L_pau]                    @     n_clst = (DWORD)sz_vol / pau;
    udiv r0, r6, r1
    str r0, [sp, #L_n_clst]
    lsls r1, r0, #2                         @     sz_fat = (n_clst * 4 + 8 + ss - 1) / ss;
    add r1, r1, #8 + 511
    lsrs r1, r1, #9
    str r1, [sp, #L_sz_fat]
    movs r1, #32                            @     sz_rsv = 32;
    str r1, [sp, #L_sz_rsv]
    movs r1, #0                             @     sz_dir = 0;
    str r1, [sp, #L_sz_dir]
    movw r1, #0xFFF5                        @     if (n_clst <= 0xFFF5 ||
    cmp r0, r1
    bls.w .Lmk_abort
    MOV32 r1, 0x0FFFFFF5                    @         n_clst > 0x0FFFFFF5) return FR_MKFS_ABORTED;
    cmp r0, r1
    bhi.w .Lmk_abort
    b .Lmk_fatsz_done
.Lmk_fat1216:                               @   } else {
    cmp r9, #0                              @     if (pau == 0) {
    bne 3f
    lsrs r12, r6, #12                       @       n = (DWORD)sz_vol / 0x1000;
    str r12, [sp, #L_n]
    LA r0, ff16x_mkfs_cst                   @       for (i = 0, pau = 1; cst[i] && cst[i] <= n; i++, pau <<= 1) ;
    movs r1, #1
    movs r2, #0
1:  ldrh r3, [r0, r2, lsl #1]
    cbz r3, 2f
    cmp r3, r12
    bhi 2f
    adds r2, r2, #1
    lsls r1, r1, #1
    b 1b
2:  str r1, [sp, #L_pau]
3:  ldr r1, [sp, #L_pau]                    @     n_clst = (DWORD)sz_vol / pau;
    udiv r0, r6, r1
    str r0, [sp, #L_n_clst]
    movw r1, #0xFF5                         @     if (n_clst > 0xFF5) {
    cmp r0, r1
    bls 4f
    lsls r2, r0, #1                         @       n = n_clst * 2 + 4;
    adds r2, r2, #4
    b 5f
4:  movs r1, #FS_FAT12                      @     } else { fsty = FS_FAT12;
    str r1, [sp, #L_fsty]
    add r2, r0, r0, lsl #1                  @       n = (n_clst * 3 + 1) / 2 + 3;
    adds r2, r2, #1
    lsrs r2, r2, #1
    adds r2, r2, #3
5:  str r2, [sp, #L_n]                      @     }
    add r1, r2, #511                        @     sz_fat = (n + ss - 1) / ss;
    lsrs r1, r1, #9
    str r1, [sp, #L_sz_fat]
    movs r1, #1                             @     sz_rsv = 1;
    str r1, [sp, #L_sz_rsv]
    ldr r1, [sp, #L_n_root]                 @     sz_dir = (DWORD)n_root * 32 / ss;
    lsls r1, r1, #5
    lsrs r1, r1, #9
    str r1, [sp, #L_sz_dir]
.Lmk_fatsz_done:                            @   }
    ldr r0, [sp, #L_sz_rsv]                 @   b_fat = b_vol + sz_rsv;
    add r0, r0, r10
    str r0, [sp, #L_b_fat]
    ldr r1, [sp, #L_sz_fat]                 @   b_data = b_fat + sz_fat * n_fat + sz_dir;
    ldr r2, [sp, #L_n_fat]
    mla r0, r1, r2, r0
    ldr r1, [sp, #L_sz_dir]
    add r0, r0, r1
    str r0, [sp, #L_b_data]
    ldr r1, [sp, #L_sz_blk]                 @   n = (DWORD)(((b_data + sz_blk - 1) & ~(sz_blk - 1)) - b_data);
    subs r1, r1, #1
    add r2, r0, r1
    bic r2, r2, r1
    sub r2, r2, r0
    str r2, [sp, #L_n]
    ldr r0, [sp, #L_fsty]
    cmp r0, #FS_FAT32                       @   if (fsty == FS_FAT32) {
    bne 6f
    ldr r0, [sp, #L_sz_rsv]                 @     sz_rsv += n; b_fat += n;
    add r0, r0, r2
    str r0, [sp, #L_sz_rsv]
    ldr r0, [sp, #L_b_fat]
    add r0, r0, r2
    str r0, [sp, #L_b_fat]
    b 8f
6:  ldr r3, [sp, #L_n_fat]                  @   } else {
    udiv r12, r2, r3                        @     n / n_fat
    mls r1, r12, r3, r2                     @     n % n_fat
    cbz r1, 7f                              @     if (n % n_fat) {
    subs r2, r2, #1                         @       n--;
    str r2, [sp, #L_n]
    udiv r12, r2, r3                        @       (n / n_fat of the decremented n)
    ldr r0, [sp, #L_sz_rsv]                 @       sz_rsv++;
    adds r0, r0, #1
    str r0, [sp, #L_sz_rsv]
    ldr r0, [sp, #L_b_fat]                  @       b_fat++;
    adds r0, r0, #1
    str r0, [sp, #L_b_fat]
7:  ldr r0, [sp, #L_sz_fat]                 @     sz_fat += n / n_fat;
    add r0, r0, r12
    str r0, [sp, #L_sz_fat]
8:  ldr r0, [sp, #L_pau]                    @   }
    lsls r0, r0, #4                         @   if (sz_vol < b_data + pau * 16 - b_vol) return FR_MKFS_ABORTED;
    ldr r1, [sp, #L_b_data]
    add r0, r0, r1
    sub r0, r0, r10
    cmp r6, r0
    blo.w .Lmk_abort
    ldr r1, [sp, #L_sz_rsv]                 @   n_clst = ((DWORD)sz_vol - sz_rsv - sz_fat * n_fat - sz_dir) / pau;
    subs r0, r6, r1
    ldr r1, [sp, #L_sz_fat]
    ldr r2, [sp, #L_n_fat]
    mul r1, r1, r2
    subs r0, r0, r1
    ldr r1, [sp, #L_sz_dir]
    subs r0, r0, r1
    ldr r1, [sp, #L_pau]
    udiv r0, r0, r1
    str r0, [sp, #L_n_clst]
    ldr r2, [sp, #L_fsty]
    cmp r2, #FS_FAT32                       @   if (fsty == FS_FAT32) {
    bne 10f
    movw r1, #0xFFF5                        @     if (n_clst <= 0xFFF5) {
    cmp r0, r1
    bhi 10f
    cmp r9, #0                              @       if (sz_au == 0 && (sz_au = pau / 2) != 0) continue;
    bne.w .Lmk_abort
    ldr r1, [sp, #L_pau]
    lsrs r9, r1, #1
    beq.w .Lmk_abort
    b.w .Lmk_fatloop                        @       continue;   (otherwise return FR_MKFS_ABORTED)
10: cmp r2, #FS_FAT16                       @   if (fsty == FS_FAT16) {
    bne 20f
    movw r1, #0xFFF5                        @     if (n_clst > 0xFFF5) {
    cmp r0, r1
    bls 14f
    cmp r9, #0                              @       if (sz_au == 0 && (pau * 2) <= 64) {
    bne 11f
    ldr r1, [sp, #L_pau]
    lsls r1, r1, #1
    cmp r1, #64
    bhi 11f
    mov r9, r1                              @         sz_au = pau * 2; continue;
    b.w .Lmk_fatloop
11: ldr r1, [sp, #L_fsopt]                  @       if ((fsopt & FM_FAT32)) { fsty = FS_FAT32; continue; }
    tst r1, #FM_FAT32
    beq 12f
    movs r1, #FS_FAT32
    str r1, [sp, #L_fsty]
    b.w .Lmk_fatloop
12: cmp r9, #0                              @       if (sz_au == 0 && (sz_au = pau * 2) <= 128) continue;
    bne.w .Lmk_abort
    ldr r1, [sp, #L_pau]
    lsls r9, r1, #1
    cmp r9, #128
    bls.w .Lmk_fatloop
    b.w .Lmk_abort                          @       return FR_MKFS_ABORTED;
14: movw r1, #0xFF5                         @     if (n_clst <= 0xFF5) {
    cmp r0, r1
    bhi 20f
    cmp r9, #0                              @       if (sz_au == 0 && (sz_au = pau * 2) <= 128) continue;
    bne.w .Lmk_abort
    ldr r1, [sp, #L_pau]
    lsls r9, r1, #1
    cmp r9, #128
    bls.w .Lmk_fatloop
    b.w .Lmk_abort                          @       return FR_MKFS_ABORTED;
20: cmp r2, #FS_FAT12                       @   if (fsty == FS_FAT12 && n_clst > 0xFF5) return FR_MKFS_ABORTED;
    bne 21f
    movw r1, #0xFF5
    cmp r0, r1
    bhi.w .Lmk_abort
21:                                         @   break; } while (1);

    @ boot sector
    MEMSET_SS                               @ memset(buf, 0, ss);
    mov r0, r4                              @ memcpy(buf + 0, "\xEB\xFE\x90" "MSDOS5.0", 11);
    LA r1, ff16x_mkfs_fat_oem
    movs r2, #11
    bl ff16_mem_cpy
    mov r1, #512                            @ st_16(buf + 11, ss);
    PST16 BPB_BytsPerSec
    ldr r0, [sp, #L_pau]                    @ buf[13] = (BYTE)pau;
    strb r0, [r4, #BPB_SecPerClus]
    ldr r1, [sp, #L_sz_rsv]                 @ st_16(buf + 14, (WORD)sz_rsv);
    uxth r1, r1
    PST16 BPB_RsvdSecCnt
    ldr r0, [sp, #L_n_fat]                  @ buf[16] = (BYTE)n_fat;
    strb r0, [r4, #BPB_NumFATs]
    ldr r0, [sp, #L_fsty]                   @ st_16(buf + 17, (WORD)((fsty == FS_FAT32) ? 0 : n_root));
    movs r1, #0
    cmp r0, #FS_FAT32
    beq 1f
    ldr r1, [sp, #L_n_root]
    uxth r1, r1
1:  PST16 BPB_RootEntCnt
    cmp r6, #0x10000                        @ if (sz_vol < 0x10000) {
    bhs 2f
    uxth r1, r6                             @   st_16(buf + 19, (WORD)sz_vol);
    PST16 BPB_TotSec16
    b 3f
2:  mov r1, r6                              @ } else { st_32(buf + 32, (DWORD)sz_vol); }
    PST32 BPB_TotSec32
3:  PBYTE BPB_Media, 0xF8                   @ buf[21] = 0xF8;
    movs r1, #63                            @ st_16(buf + 24, 63);
    PST16 BPB_SecPerTrk
    movs r1, #255                           @ st_16(buf + 26, 255);
    PST16 BPB_NumHeads
    mov r1, r10                             @ st_32(buf + 28, (DWORD)b_vol);
    PST32 BPB_HiddSec
    ldr r0, [sp, #L_fsty]
    cmp r0, #FS_FAT32                       @ if (fsty == FS_FAT32) {
    bne 4f
    ldr r1, [sp, #L_vsn]                    @   st_32(buf + 67, vsn);
    PST32 BS_VolID32
    ldr r1, [sp, #L_sz_fat]                 @   st_32(buf + 36, sz_fat);
    PST32 BPB_FATSz32
    movs r1, #2                             @   st_32(buf + 44, 2);
    PST32 BPB_RootClus32
    movs r1, #1                             @   st_16(buf + 48, 1);
    PST16 BPB_FSInfo32
    movs r1, #6                             @   st_16(buf + 50, 6);
    PST16 BPB_BkBootSec32
    PBYTE BS_DrvNum32, 0x80                 @   buf[64] = 0x80;
    PBYTE BS_BootSig32, 0x29                @   buf[66] = 0x29;
    add r0, r4, #BS_VolLab32                @   memcpy(buf + 71, "NO NAME    " "FAT32   ", 19);
    LA r1, ff16x_mkfs_fat32_lbl
    movs r2, #19
    bl ff16_mem_cpy
    b 5f
4:  ldr r1, [sp, #L_vsn]                    @ } else { st_32(buf + 39, vsn);
    PST32 BS_VolID
    ldr r1, [sp, #L_sz_fat]                 @   st_16(buf + 22, (WORD)sz_fat);
    uxth r1, r1
    PST16 BPB_FATSz16
    PBYTE BS_DrvNum, 0x80                   @   buf[36] = 0x80;
    PBYTE BS_BootSig, 0x29                  @   buf[38] = 0x29;
    add r0, r4, #BS_VolLab                  @   memcpy(buf + 43, "NO NAME    " "FAT     ", 19);
    LA r1, ff16x_mkfs_fat_lbl
    movs r2, #19
    bl ff16_mem_cpy
5:  movw r1, #0xAA55                        @ } st_16(buf + 510, 0xAA55);
    PST16 BS_55AA
    DW1 r10                                 @ if (disk_write(pdrv, buf, b_vol, 1) != RES_OK) return FR_DISK_ERR;
    cmp r0, #0
    bne.w .Lmk_diskerr
    ldr r0, [sp, #L_fsty]
    cmp r0, #FS_FAT32                       @ if (fsty == FS_FAT32) {
    bne.w .Lmk_fatinit
    add r2, r10, #6                         @   disk_write(pdrv, buf, b_vol + 6, 1);      (backup boot sector; result ignored)
    DW1 r2
    MEMSET_SS                               @   memset(buf, 0, ss);
    MOV32 r1, 0x41615252                    @   st_32(buf + 0, 0x41615252);
    PST32 FSI_LeadSig
    MOV32 r1, 0x61417272                    @   st_32(buf + 484, 0x61417272);
    PST32 FSI_StrucSig
    ldr r1, [sp, #L_n_clst]                 @   st_32(buf + 488, n_clst - 1);
    subs r1, r1, #1
    PST32 FSI_Free_Count
    movs r1, #2                             @   st_32(buf + 492, 2);
    PST32 FSI_Nxt_Free
    movw r1, #0xAA55                        @   st_16(buf + 510, 0xAA55);
    PST16 BS_55AA
    add r2, r10, #7                         @   disk_write(pdrv, buf, b_vol + 7, 1);      (backup FSINFO; result ignored)
    DW1 r2
    add r2, r10, #1                         @   disk_write(pdrv, buf, b_vol + 1, 1);      (FSINFO; result ignored)
    DW1 r2
.Lmk_fatinit:                               @ }
    MEMSET_BUF                              @ memset(buf, 0, sz_buf * ss);
    ldr r8, [sp, #L_b_fat]                  @ sect = b_fat;
    mov r11, #0                             @ for (i = 0; i < n_fat; i++) {
.Lmk_fatcp:
    ldr r0, [sp, #L_n_fat]
    cmp r11, r0
    bhs .Lmk_fatcp_end
    ldr r0, [sp, #L_fsty]
    cmp r0, #FS_FAT32                       @   if (fsty == FS_FAT32) {
    bne 1f
    mvn r1, #7                              @     st_32(buf + 0, 0xFFFFFFF8);
    mov r0, r4
    bl ff16_st_32
    mvn r1, #0                              @     st_32(buf + 4, 0xFFFFFFFF);
    PST32 4
    mvn r1, #0xF0000000                     @     st_32(buf + 8, 0x0FFFFFFF);
    PST32 8
    b 3f
1:  mvn r1, #7                              @   } else { st_32(buf + 0, (fsty == FS_FAT12) ? 0xFFFFF8 : 0xFFFFFFF8);
    cmp r0, #FS_FAT12
    bne 2f
    MOV32 r1, 0xFFFFF8
2:  mov r0, r4
    bl ff16_st_32
3:  ldr r0, [sp, #L_sz_fat]                 @   }
    str r0, [sp, #L_nsect]                  @   nsect = sz_fat;
.Lmk_fatwr:                                 @   do {
    CALC_N                                  @     n = (nsect > sz_buf) ? sz_buf : nsect;
    WRITE_N                                 @     if (disk_write(pdrv, buf, sect, (UINT)n) != RES_OK) return FR_DISK_ERR;
    MEMSET_SS                               @     memset(buf, 0, ss);
    ADV_N                                   @     sect += n; nsect -= n;
    bne.w .Lmk_fatwr                        @   } while (nsect);
    add r11, r11, #1                        @ i++ }
    b .Lmk_fatcp
.Lmk_fatcp_end:
    ldr r0, [sp, #L_fsty]                   @ nsect = (fsty == FS_FAT32) ? pau : sz_dir;
    cmp r0, #FS_FAT32
    bne 1f
    ldr r0, [sp, #L_pau]
    b 2f
1:  ldr r0, [sp, #L_sz_dir]
2:  str r0, [sp, #L_nsect]
.Lmk_dirwr:                                 @ do {
    CALC_N                                  @   n = (nsect > sz_buf) ? sz_buf : nsect;
    WRITE_N                                 @   if (disk_write(pdrv, buf, sect, (UINT)n) != RES_OK) return FR_DISK_ERR;
    ADV_N                                   @   sect += n; nsect -= n;
    bne.w .Lmk_dirwr                        @ } while (nsect);

    @ ----------------------------------------------------------- partition table
.Lmk_post:
    ldr r0, [sp, #L_fsty]                   @ if (1 && fsty == FS_EXFAT) sys = 0x07;
    cmp r0, #FS_EXFAT
    bne 1f
    movs r1, #0x07
    b 5f
1:  cmp r0, #FS_FAT32                       @ else if (fsty == FS_FAT32) sys = 0x0C;
    bne 2f
    movs r1, #0x0C
    b 5f
2:  cmp r6, #0x10000                        @ else if (sz_vol >= 0x10000) sys = 0x06;
    blo 3f
    movs r1, #0x06
    b 5f
3:  cmp r0, #FS_FAT16                       @ else if (fsty == FS_FAT16) sys = 0x04;
    bne 4f
    movs r1, #0x04
    b 5f
4:  movs r1, #0x01                          @ else sys = 0x01;
5:  str r1, [sp, #L_sys]
                                            @ (if (0 && ipart != 0) {...} not translated)
    ldr r0, [sp, #L_fsopt]                  @ if (!(fsopt & FM_SFD)) {
    tst r0, #FM_SFD
    bne 6f
    str r6, [sp, #L_lba]                    @   lba[0] = sz_vol;
    movs r0, #0                             @   lba[1] = 0;
    str r0, [sp, #L_lba + 4]
    mov r0, r7                              @   res = create_partition(pdrv, lba, sys, buf);
    add r1, sp, #L_lba
    ldr r2, [sp, #L_sys]
    mov r3, r4
    bl ff16_create_partition
    cmp r0, #FR_OK                          @   if (res != FR_OK) return res;
    bne .Lmk_ret
6:  mov r0, r7                              @ if (disk_ioctl(pdrv, CTRL_SYNC, 0) != RES_OK) return FR_DISK_ERR;
    movs r1, #CTRL_SYNC
    movs r2, #0
    bl disk_ioctl
    cmp r0, #0
    bne .Lmk_diskerr
    movs r0, #FR_OK                         @ return FR_OK;
    b .Lmk_ret
.Lmk_diskerr:
    movs r0, #FR_DISK_ERR
    b .Lmk_ret
.Lmk_abort:
    movs r0, #FR_MKFS_ABORTED
.Lmk_ret:
    add sp, sp, #MK_FRAME
    pop {r4-r11, pc}
ENDFUNC ff16_f_mkfs

    .endif                                  @ FF_USE_MKFS
