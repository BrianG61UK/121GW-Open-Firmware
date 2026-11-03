@ fat_file.s - SD module: the file API - mount, open, read, write, sync, close, seek, directory listing, stat, utime (DESIGN.md 6.23, W8)
@
@ Callers outside the module: log_* (files.s, csv.s) and calbin_save / calbin_load (CAL), through the canonical symbols
@ fn_08021B80 (f_mount), fn_08021BCC (f_open), fn_08021D72 (f_read), fn_08021F60 (f_write), fn_0802224C (f_close),
@ fn_08022268 (f_lseek), fn_0802242C (f_opendir), fn_080224B6 (f_readdir), fn_08022526 (f_stat), fn_0802256E (f_utime),
@ fn_0801E010 (f_tell).  The cal.bin size check of CAL reads the file size at FIL +0xC, which this code sets when a file is
@ opened (fat_f_open stores the size of the directory entry there, 0x08021D40..0x08021D54).
@
@ Open mode bits: 0x01 read, 0x02 write, 0x04 create new (fails when the file exists), 0x08 create always (truncates),
@ 0x10 open always (creates when missing).  FIL flag bits (+6): 0x01 read, 0x02 write, 0x20 directory entry must be updated,
@ 0x40 sector buffer dirty, 0x80 error.
@

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.sd, "ax", %progbits

@ names of the v2.05 variables used in this file (addresses unchanged, DESIGN.md 5.1)
    .equ fat_fs_table,            v_20007C58            @ 0x20007C58 FatFs[0]: pointer to the work area of drive 0 (set by f_mount)

@ -----------------------------------------------------------------------------
@ fat_f_tell - current file pointer (FatFs f_tell)
@ Replaces  : 0x0801E010 FUN_0801E010 (v2.05), called by log_session_once, log_open_and_seek, log_write_header
@ In        : r0 = FIL pointer
@ Out       : r0 = FIL +8 (file pointer)
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801E010..0x0801E017
@ -----------------------------------------------------------------------------
FUNC fat_f_tell
    movs    r1, r0                          @ 0801E010 r1 = r0
    ldr     r2, [r1, #8]                    @ 0801E012 r2 = u32 [r1+0x8]
    movs    r0, r2                          @ 0801E014 r0 = r2
    bx      lr                              @ 0801E016 return
ENDFUNC fat_f_tell
    .global fn_0801E010
    .thumb_set fn_0801E010, fat_f_tell
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_validate - check that a FIL or DIR belongs to the mounted file system (FatFs validate)
@ Replaces  : 0x08021B50 FUN_08021B50 (v2.05), called by f_read, f_write, f_sync, f_lseek, f_readdir
@ In        : r0 = FATFS pointer from the object, r1 = mount id stored in the object (u16)
@ Out       : r0 = 0 valid, 9 invalid object (no file system, not mounted, or a different mount id), 3 disk not ready
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08021B50..0x08021B7F
@ -----------------------------------------------------------------------------
FUNC fat_validate
    push    {r3, r4, r5, lr}                @ 08021B50 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 08021B52 r4 = r0
    movs    r5, r1                          @ 08021B54 r5 = r1
    cmp     r4, #0                          @ 08021B56 compare r4 with 0
    beq     .Lfat_validate_1B6A             @ 08021B58 if (r4 == 0) goto 0x8021B6A
    ldrb    r0, [r4]                        @ 08021B5A r0 = u8 [r4]
    cmp     r0, #0                          @ 08021B5C compare r0 with 0
    beq     .Lfat_validate_1B6A             @ 08021B5E if (r0 == 0) goto 0x8021B6A
    ldrh    r0, [r4, #6]                    @ 08021B60 r0 = u16 [r4+0x6]
    movs    r1, r5                          @ 08021B62 r1 = r5
    uxth    r1, r1                          @ 08021B64 r1 = u16(r1)
    cmp     r0, r1                          @ 08021B66 compare r0 with r1
    beq     .Lfat_validate_1B6E             @ 08021B68 if (r0 == r1) goto 0x8021B6E
.Lfat_validate_1B6A:                    @ v2.05 0x08021B6A, reached from 0x08021B58, 0x08021B5E
    movs    r0, #9                          @ 08021B6A r0 = 9
    b       .Lfat_validate_1B7E             @ 08021B6C goto 0x8021B7E
.Lfat_validate_1B6E:                    @ v2.05 0x08021B6E, reached from 0x08021B68
    ldrb    r0, [r4, #1]                    @ 08021B6E r0 = u8 [r4+0x1]
    bl      disk_status                     @ 08021B70 call disk_status
    lsls    r0, r0, #0x1f                   @ 08021B74 r0 = r0 << 0x1f
    bpl     .Lfat_validate_1B7C             @ 08021B76 if (r0 >=0 0) goto 0x8021B7C
    movs    r0, #3                          @ 08021B78 r0 = 3
    b       .Lfat_validate_1B7E             @ 08021B7A goto 0x8021B7E
.Lfat_validate_1B7C:                    @ v2.05 0x08021B7C, reached from 0x08021B76
    movs    r0, #0                          @ 08021B7C r0 = 0
.Lfat_validate_1B7E:                    @ v2.05 0x08021B7E, reached from 0x08021B6C, 0x08021B7A
    pop     {r1, r4, r5, pc}                @ 08021B7E pop {r1, r4, r5, pc}
ENDFUNC fat_validate
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_mount - register or remove the work area of drive 0 (FatFs f_mount)
@ Replaces  : 0x08021B80 FUN_08021B80 (v2.05), canonical symbol fn_08021B80
@ In        : r0 = drive number (must be 0), r1 = FATFS pointer or 0
@ Out       : r0 = 0 ok, 11 invalid drive
@ Clobbers  : r0, r2-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : writes the work area pointer table 0x20007C58 (one entry)
@ Spec      : v2.05 listing 0x08021B80..0x08021BB1
@ Note      : no disk access happens here; the volume is mounted by the first file call (fat_chk_mounted).  An old work area is
@             marked unmounted (fs_type 0) as is the new one.
@ -----------------------------------------------------------------------------
FUNC fat_f_mount
    movs    r2, r0                          @ 08021B80 r2 = r0
    uxtb    r2, r2                          @ 08021B82 r2 = u8(r2)
    cmp     r2, #0                          @ 08021B84 compare r2 with 0
    beq     .Lfat_f_mount_1B8C              @ 08021B86 if (r2 == 0) goto 0x8021B8C
    movs    r0, #0xb                        @ 08021B88 r0 = 0xb
    b       .Lfat_f_mount_1BB0              @ 08021B8A goto 0x8021BB0
.Lfat_f_mount_1B8C:                     @ v2.05 0x08021B8C, reached from 0x08021B86
    ldr     r0, =fat_fs_table               @ 08021B8C r0 = &fat_fs_table
    uxtb    r2, r2                          @ 08021B8E r2 = u8(r2)
    ldr.w   r0, [r0, r2, lsl #2]            @ 08021B90 r0 = u32 [fat_fs_table+r2*4]
    movs    r3, r0                          @ 08021B94 r3 = r0
    cmp     r3, #0                          @ 08021B96 compare r3 with 0
    beq     .Lfat_f_mount_1B9E              @ 08021B98 if (r3 == 0) goto 0x8021B9E
    movs    r0, #0                          @ 08021B9A r0 = 0
    strb    r0, [r3]                        @ 08021B9C u8 [r3] = r0
.Lfat_f_mount_1B9E:                     @ v2.05 0x08021B9E, reached from 0x08021B98
    cmp     r1, #0                          @ 08021B9E compare r1 with 0
    beq     .Lfat_f_mount_1BA6              @ 08021BA0 if (r1 == 0) goto 0x8021BA6
    movs    r0, #0                          @ 08021BA2 r0 = 0
    strb    r0, [r1]                        @ 08021BA4 u8 [r1] = r0
.Lfat_f_mount_1BA6:                     @ v2.05 0x08021BA6, reached from 0x08021BA0
    ldr     r0, =fat_fs_table               @ 08021BA6 r0 = &fat_fs_table
    uxtb    r2, r2                          @ 08021BA8 r2 = u8(r2)
    str.w   r1, [r0, r2, lsl #2]            @ 08021BAA u32 [fat_fs_table+r2*4] = r1
    movs    r0, #0                          @ 08021BAE r0 = 0
.Lfat_f_mount_1BB0:                     @ v2.05 0x08021BB0, reached from 0x08021B8A
    bx      lr                              @ 08021BB0 return
ENDFUNC fat_f_mount
    .global fn_08021B80
    .thumb_set fn_08021B80, fat_f_mount
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_open - open or create a file (FatFs f_open)
@ Replaces  : 0x08021BCC FUN_08021BCC (v2.05), canonical symbol fn_08021BCC
@ In        : r0 = FIL pointer, r1 = path (e.g. "0:YYMMDDnn.csv"), r2 = open mode
@ Out       : r0 = FRESULT (0 ok, 3 not ready, 4 no file, 5 no path, 6 invalid name, 7 denied, 8 exists, 10 write protected, 11..13)
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : FIL fields +0 fs, +4 id, +6 flags, +8 file pointer (0), +0xC size, +0x10 first cluster, +0x14 current cluster, +0x18 sector (0),
@             +0x1C directory sector, +0x20 directory entry pointer
@ Spec      : v2.05 listing 0x08021BCC..0x08021D71
@ Note      : write modes need a writable mount (fat_chk_mounted r2 = 1).  An existing file is refused when it is read-only or a
@             directory (7) or when create-new was asked (8).  Creating a file (also truncating one with create-always) writes the
@             creation time (get_fattime, a constant), sets attribute and size to 0, clears the first cluster and frees the old
@             cluster chain (remove_chain), then makes sure the window holding the directory entry is written.  A missing file in a
@             create mode is registered with dir_register.
@ -----------------------------------------------------------------------------
FUNC fat_f_open
    push.w  {r1, r4, r5, r6, r7, r8, r9, lr}@ 08021BCC push {r1, r4, r5, r6, r7, r8, r9, lr}
    sub     sp, #0x28                       @ 08021BD0 sp -= 0x28
    movs    r4, r0                          @ 08021BD2 r4 = r0
    movs    r7, r2                          @ 08021BD4 r7 = r2
    @ FIL +0 (fs) = 0: not open until the end of the routine succeeds; r7 = mode & 0x1F
    movs    r0, #0                          @ 08021BD6 r0 = 0
    str     r0, [r4]                        @ 08021BD8 u32 [r4] = r0
    ands    r7, r7, #0x1f                   @ 08021BDA r7 = r7 & 0x1f
    ands    r2, r7, #0xfe                   @ 08021BDE r2 = r7 & 0xfe
    mov     r1, sp                          @ 08021BE2 r1 = sp
    add     r0, sp, #0x28                   @ 08021BE4 r0 = sp + 0x28
    @ chk_mounted(path, &fs, write access when any bit but FA_READ is set); path pointer from [sp+0x28]
    bl      fat_chk_mounted                 @ 08021BE6 call fat_chk_mounted
    movs    r5, r0                          @ 08021BEA r5 = r0
    add     r0, sp, #0x1c                   @ 08021BEC r0 = sp + 0x1c
    str     r0, [sp, #0x18]                 @ 08021BEE u32 [sp+0x18] = r0
    uxtb    r5, r5                          @ 08021BF0 r5 = u8(r5)
    cmp     r5, #0                          @ 08021BF2 compare r5 with 0
    bne     .Lfat_f_open_1C00               @ 08021BF4 if (r5 != 0) goto 0x8021C00
    @ follow_path(dj, path) when the volume is mounted; r6 = dir entry pointer of the result (0 for the root)
    ldr     r1, [sp, #0x28]                 @ 08021BF6 r1 = u32 [sp+0x28]
    mov     r0, sp                          @ 08021BF8 r0 = sp
    bl      fat_follow_path                 @ 08021BFA call fat_follow_path
    movs    r5, r0                          @ 08021BFE r5 = r0
.Lfat_f_open_1C00:                      @ v2.05 0x08021C00, reached from 0x08021BF4
    ldr     r0, [sp, #0x14]                 @ 08021C00 r0 = u32 [sp+0x14]
    movs    r6, r0                          @ 08021C02 r6 = r0
    uxtb    r5, r5                          @ 08021C04 r5 = u8(r5)
    @ no error but no directory entry (the path names the root): invalid name (6)
    cmp     r5, #0                          @ 08021C06 compare r5 with 0
    bne     .Lfat_f_open_1C12               @ 08021C08 if (r5 != 0) goto 0x8021C12
    cmp     r6, #0                          @ 08021C0A compare r6 with 0
    bne     .Lfat_f_open_1C12               @ 08021C0C if (r6 != 0) goto 0x8021C12
    movs    r0, #6                          @ 08021C0E r0 = 6
    movs    r5, r0                          @ 08021C10 r5 = r0
    @ mode bits 2..4 (create new, create always, open always) clear: open an existing file (1CE8); otherwise the create branch
.Lfat_f_open_1C12:                      @ v2.05 0x08021C12, reached from 0x08021C08, 0x08021C0C
    movs    r0, #0x1c                       @ 08021C12 r0 = 0x1c
    tst     r7, r0                          @ 08021C14 compare r7 with r0
    beq     .Lfat_f_open_1CE8               @ 08021C16 if ((r7 & r0) == 0) goto 0x8021CE8
    @ create branch, entry not found (error 4): dir_register adds an entry, mode |= 8 so the new entry is initialised below; r6 = the new entry
    uxtb    r5, r5                          @ 08021C18 r5 = u8(r5)
    cmp     r5, #0                          @ 08021C1A compare r5 with 0
    beq     .Lfat_f_open_1C36               @ 08021C1C if (r5 == 0) goto 0x8021C36
    uxtb    r5, r5                          @ 08021C1E r5 = u8(r5)
    cmp     r5, #4                          @ 08021C20 compare r5 with 4
    bne     .Lfat_f_open_1C2C               @ 08021C22 if (r5 != 4) goto 0x8021C2C
    mov     r0, sp                          @ 08021C24 r0 = sp
    bl      fat_dir_register                @ 08021C26 call fat_dir_register
    movs    r5, r0                          @ 08021C2A r5 = r0
.Lfat_f_open_1C2C:                      @ v2.05 0x08021C2C, reached from 0x08021C22
    orrs    r7, r7, #8                      @ 08021C2C r7 = r7 | 8
    ldr     r0, [sp, #0x14]                 @ 08021C30 r0 = u32 [sp+0x14]
    movs    r6, r0                          @ 08021C32 r6 = r0
    b       .Lfat_f_open_1C4C               @ 08021C34 goto 0x8021C4C
    @ create branch, file found: create-new (bit 2) gives exists (8); an entry with read-only or directory attribute (0x11) gives denied (7)
.Lfat_f_open_1C36:                      @ v2.05 0x08021C36, reached from 0x08021C1C
    lsls    r0, r7, #0x1d                   @ 08021C36 r0 = r7 << 0x1d
    bpl     .Lfat_f_open_1C40               @ 08021C38 if (r0 >=0 0) goto 0x8021C40
    movs    r0, #8                          @ 08021C3A r0 = 8
    movs    r5, r0                          @ 08021C3C r5 = r0
    b       .Lfat_f_open_1C4C               @ 08021C3E goto 0x8021C4C
.Lfat_f_open_1C40:                      @ v2.05 0x08021C40, reached from 0x08021C38
    ldrb    r0, [r6, #0xb]                  @ 08021C40 r0 = u8 [r6+0xB]
    movs    r1, #0x11                       @ 08021C42 r1 = 0x11
    tst     r0, r1                          @ 08021C44 compare r0 with r1
    beq     .Lfat_f_open_1C4C               @ 08021C46 if ((r0 & r1) == 0) goto 0x8021C4C
    movs    r0, #7                          @ 08021C48 r0 = 7
    movs    r5, r0                          @ 08021C4A r5 = r0
    @ mode bit 3 set and no error: initialise or truncate the entry
.Lfat_f_open_1C4C:                      @ v2.05 0x08021C4C, reached from 0x08021C34, 0x08021C3E, 0x08021C46
    uxtb    r5, r5                          @ 08021C4C r5 = u8(r5)
    cmp     r5, #0                          @ 08021C4E compare r5 with 0
    bne     .Lfat_f_open_1D08               @ 08021C50 if (r5 != 0) goto 0x8021D08
    lsls    r0, r7, #0x1c                   @ 08021C52 r0 = r7 << 0x1c
    bpl     .Lfat_f_open_1D08               @ 08021C54 if (r0 >=0 0) goto 0x8021D08
    @ creation time and date (get_fattime) into entry bytes 0x0E..0x11; attribute (0x0B) = 0; size (0x1C..0x1F) = 0
    bl      get_fattime                     @ 08021C56 call get_fattime
    mov     r8, r0                          @ 08021C5A r8 = r0
    strb.w  r8, [r6, #0xe]                  @ 08021C5C u8 [r6+0xE] = r8
    mov     r0, r8                          @ 08021C60 r0 = r8
    uxth    r0, r0                          @ 08021C62 r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 08021C64 r0 = r0 >> 8
    strb    r0, [r6, #0xf]                  @ 08021C66 u8 [r6+0xF] = r0
    lsrs.w  r0, r8, #0x10                   @ 08021C68 r0 = r8 >> 0x10
    strb    r0, [r6, #0x10]                 @ 08021C6C u8 [r6+0x10] = r0
    lsrs.w  r0, r8, #0x18                   @ 08021C6E r0 = r8 >> 0x18
    strb    r0, [r6, #0x11]                 @ 08021C72 u8 [r6+0x11] = r0
    movs    r0, #0                          @ 08021C74 r0 = 0
    strb    r0, [r6, #0xb]                  @ 08021C76 u8 [r6+0xB] = r0
    movs    r0, #0                          @ 08021C78 r0 = 0
    strb    r0, [r6, #0x1c]                 @ 08021C7A u8 [r6+0x1C] = r0
    movs    r0, #0                          @ 08021C7C r0 = 0
    strb    r0, [r6, #0x1d]                 @ 08021C7E u8 [r6+0x1D] = r0
    movs    r0, #0                          @ 08021C80 r0 = 0
    strb    r0, [r6, #0x1e]                 @ 08021C82 u8 [r6+0x1E] = r0
    movs    r0, #0                          @ 08021C84 r0 = 0
    strb    r0, [r6, #0x1f]                 @ 08021C86 u8 [r6+0x1F] = r0
    @ r9 = old first cluster (bytes 0x14/0x15 high, 0x1A/0x1B low); the cluster fields of the entry are set to 0
    ldrb    r0, [r6, #0x15]                 @ 08021C88 r0 = u8 [r6+0x15]
    ldrb    r1, [r6, #0x14]                 @ 08021C8A r1 = u8 [r6+0x14]
    orrs.w  r0, r1, r0, lsl #8              @ 08021C8C r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08021C90 r0 = u16(r0)
    ldrb    r1, [r6, #0x1b]                 @ 08021C92 r1 = u8 [r6+0x1B]
    ldrb    r2, [r6, #0x1a]                 @ 08021C94 r2 = u8 [r6+0x1A]
    orrs.w  r1, r2, r1, lsl #8              @ 08021C96 r1 = r2 | r1, lsl #8
    uxth    r1, r1                          @ 08021C9A r1 = u16(r1)
    orrs.w  r0, r1, r0, lsl #16             @ 08021C9C r0 = r1 | r0, lsl #16
    mov     r9, r0                          @ 08021CA0 r9 = r0
    movs    r0, #0                          @ 08021CA2 r0 = 0
    strb    r0, [r6, #0x1a]                 @ 08021CA4 u8 [r6+0x1A] = r0
    movs    r0, #0                          @ 08021CA6 r0 = 0
    strb    r0, [r6, #0x1b]                 @ 08021CA8 u8 [r6+0x1B] = r0
    movs    r0, #0                          @ 08021CAA r0 = 0
    strb    r0, [r6, #0x14]                 @ 08021CAC u8 [r6+0x14] = r0
    movs    r0, #0                          @ 08021CAE r0 = 0
    strb    r0, [r6, #0x15]                 @ 08021CB0 u8 [r6+0x15] = r0
    @ window dirty (wflag = 1); an old chain (r9 != 0) is released with remove_chain and the last allocated cluster hint is set to r9 - 1; the window sector of the entry is reloaded (1CE0)
    movs    r0, #1                          @ 08021CB2 r0 = 1
    ldr     r1, [sp]                        @ 08021CB4 r1 = u32 [sp]
    strb    r0, [r1, #4]                    @ 08021CB6 u8 [r1+0x4] = r0
    cmp.w   r9, #0                          @ 08021CB8 compare r9 with 0
    beq     .Lfat_f_open_1D08               @ 08021CBC if (r9 == 0) goto 0x8021D08
    ldr     r0, [sp]                        @ 08021CBE r0 = u32 [sp]
    ldr     r0, [r0, #0x2c]                 @ 08021CC0 r0 = u32 [r0+0x2C]
    mov     r8, r0                          @ 08021CC2 r8 = r0
    mov     r1, r9                          @ 08021CC4 r1 = r9
    ldr     r0, [sp]                        @ 08021CC6 r0 = u32 [sp]
    bl      fat_remove_chain                @ 08021CC8 call fat_remove_chain
    movs    r5, r0                          @ 08021CCC r5 = r0
    uxtb    r5, r5                          @ 08021CCE r5 = u8(r5)
    cmp     r5, #0                          @ 08021CD0 compare r5 with 0
    bne     .Lfat_f_open_1D08               @ 08021CD2 if (r5 != 0) goto 0x8021D08
    subs.w  r0, r9, #1                      @ 08021CD4 r0 = r9 - 1
    ldr     r1, [sp]                        @ 08021CD8 r1 = u32 [sp]
    str     r0, [r1, #0xc]                  @ 08021CDA u32 [r1+0xC] = r0
    mov     r1, r8                          @ 08021CDC r1 = r8
    ldr     r0, [sp]                        @ 08021CDE r0 = u32 [sp]
    bl      fat_move_window                 @ 08021CE0 call fat_move_window
    movs    r5, r0                          @ 08021CE4 r5 = r0
    b       .Lfat_f_open_1D08               @ 08021CE6 goto 0x8021D08
    @ open an existing file: a directory (attribute bit 4) gives 4; write access to a read-only file (attribute bit 0) gives 7
.Lfat_f_open_1CE8:                      @ v2.05 0x08021CE8, reached from 0x08021C16
    uxtb    r5, r5                          @ 08021CE8 r5 = u8(r5)
    cmp     r5, #0                          @ 08021CEA compare r5 with 0
    bne     .Lfat_f_open_1D08               @ 08021CEC if (r5 != 0) goto 0x8021D08
    ldrb    r0, [r6, #0xb]                  @ 08021CEE r0 = u8 [r6+0xB]
    lsls    r0, r0, #0x1b                   @ 08021CF0 r0 = r0 << 0x1b
    bpl     .Lfat_f_open_1CFA               @ 08021CF2 if (r0 >=0 0) goto 0x8021CFA
    movs    r0, #4                          @ 08021CF4 r0 = 4
    movs    r5, r0                          @ 08021CF6 r5 = r0
    b       .Lfat_f_open_1D08               @ 08021CF8 goto 0x8021D08
.Lfat_f_open_1CFA:                      @ v2.05 0x08021CFA, reached from 0x08021CF2
    lsls    r0, r7, #0x1e                   @ 08021CFA r0 = r7 << 0x1e
    bpl     .Lfat_f_open_1D08               @ 08021CFC if (r0 >=0 0) goto 0x8021D08
    ldrb    r0, [r6, #0xb]                  @ 08021CFE r0 = u8 [r6+0xB]
    lsls    r0, r0, #0x1f                   @ 08021D00 r0 = r0 << 0x1f
    bpl     .Lfat_f_open_1D08               @ 08021D02 if (r0 >=0 0) goto 0x8021D08
    movs    r0, #7                          @ 08021D04 r0 = 7
    movs    r5, r0                          @ 08021D06 r5 = r0
    @ no error: a created file starts with flag 0x20 (entry must be written); FIL +0x1C = sector of the directory entry, FIL +0x20 = entry pointer
.Lfat_f_open_1D08:                      @ v2.05 0x08021D08, reached from 0x08021C50, 0x08021C54, 0x08021CBC, 0x08021CD2, 0x08021CE6, 0x08021CEC, 0x08021CF8, 0x08021CFC, 0x08021D02
    uxtb    r5, r5                          @ 08021D08 r5 = u8(r5)
    cmp     r5, #0                          @ 08021D0A compare r5 with 0
    bne     .Lfat_f_open_1D1E               @ 08021D0C if (r5 != 0) goto 0x8021D1E
    lsls    r0, r7, #0x1c                   @ 08021D0E r0 = r7 << 0x1c
    bpl     .Lfat_f_open_1D16               @ 08021D10 if (r0 >=0 0) goto 0x8021D16
    orrs    r7, r7, #0x20                   @ 08021D12 r7 = r7 | 0x20
.Lfat_f_open_1D16:                      @ v2.05 0x08021D16, reached from 0x08021D10
    ldr     r0, [sp]                        @ 08021D16 r0 = u32 [sp]
    ldr     r0, [r0, #0x2c]                 @ 08021D18 r0 = u32 [r0+0x2C]
    str     r0, [r4, #0x1c]                 @ 08021D1A u32 [r4+0x1C] = r0
    str     r6, [r4, #0x20]                 @ 08021D1C u32 [r4+0x20] = r6
    @ FIL +6 = mode flags, +0x10 = first cluster, +0xC = size from the entry, +8 = 0, +0x18 = 0, +0 = fs, +4 = mount id
.Lfat_f_open_1D1E:                      @ v2.05 0x08021D1E, reached from 0x08021D0C
    uxtb    r5, r5                          @ 08021D1E r5 = u8(r5)
    cmp     r5, #0                          @ 08021D20 compare r5 with 0
    bne     .Lfat_f_open_1D68               @ 08021D22 if (r5 != 0) goto 0x8021D68
    strb    r7, [r4, #6]                    @ 08021D24 u8 [r4+0x6] = r7
    ldrb    r0, [r6, #0x15]                 @ 08021D26 r0 = u8 [r6+0x15]
    ldrb    r1, [r6, #0x14]                 @ 08021D28 r1 = u8 [r6+0x14]
    orrs.w  r0, r1, r0, lsl #8              @ 08021D2A r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08021D2E r0 = u16(r0)
    ldrb    r1, [r6, #0x1b]                 @ 08021D30 r1 = u8 [r6+0x1B]
    ldrb    r2, [r6, #0x1a]                 @ 08021D32 r2 = u8 [r6+0x1A]
    orrs.w  r1, r2, r1, lsl #8              @ 08021D34 r1 = r2 | r1, lsl #8
    uxth    r1, r1                          @ 08021D38 r1 = u16(r1)
    orrs.w  r0, r1, r0, lsl #16             @ 08021D3A r0 = r1 | r0, lsl #16
    str     r0, [r4, #0x10]                 @ 08021D3E u32 [r4+0x10] = r0
    ldrb    r0, [r6, #0x1f]                 @ 08021D40 r0 = u8 [r6+0x1F]
    ldrb    r1, [r6, #0x1e]                 @ 08021D42 r1 = u8 [r6+0x1E]
    lsls    r1, r1, #0x10                   @ 08021D44 r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 08021D46 r0 = r1 | r0, lsl #24
    ldrb    r1, [r6, #0x1d]                 @ 08021D4A r1 = u8 [r6+0x1D]
    orrs.w  r0, r0, r1, lsl #8              @ 08021D4C r0 = r0 | r1, lsl #8
    ldrb    r1, [r6, #0x1c]                 @ 08021D50 r1 = u8 [r6+0x1C]
    orrs    r0, r1                          @ 08021D52 r0 |= r1
    str     r0, [r4, #0xc]                  @ 08021D54 u32 [r4+0xC] = r0
    movs    r0, #0                          @ 08021D56 r0 = 0
    str     r0, [r4, #8]                    @ 08021D58 u32 [r4+0x8] = r0
    movs    r0, #0                          @ 08021D5A r0 = 0
    str     r0, [r4, #0x18]                 @ 08021D5C u32 [r4+0x18] = r0
    ldr     r0, [sp]                        @ 08021D5E r0 = u32 [sp]
    str     r0, [r4]                        @ 08021D60 u32 [r4] = r0
    ldr     r0, [sp]                        @ 08021D62 r0 = u32 [sp]
    ldrh    r0, [r0, #6]                    @ 08021D64 r0 = u16 [r0+0x6]
    strh    r0, [r4, #4]                    @ 08021D66 u16 [r4+0x4] = r0
.Lfat_f_open_1D68:                      @ v2.05 0x08021D68, reached from 0x08021D22
    movs    r0, r5                          @ 08021D68 r0 = r5
    uxtb    r0, r0                          @ 08021D6A r0 = u8(r0)
    add     sp, #0x2c                       @ 08021D6C sp += 0x2c
    pop.w   {r4, r5, r6, r7, r8, r9, pc}    @ 08021D6E pop {r4, r5, r6, r7, r8, r9, pc}
ENDFUNC fat_f_open
    .global fn_08021BCC
    .thumb_set fn_08021BCC, fat_f_open
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_read - read up to r2 bytes (FatFs f_read)
@ Replaces  : 0x08021D72 FUN_08021D72 (v2.05), canonical symbol fn_08021D72
@ In        : r0 = FIL pointer, r1 = buffer, r2 = byte count, r3 = pointer that receives the number of bytes read
@ Out       : r0 = FRESULT (0 ok, 2 internal error, 7 denied - not opened for reading, 9 invalid object, 1 disk error)
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08021D72..0x08021F5F
@ Note      : reads are limited to the bytes left in the file.  Whole sectors that are aligned to the sector size are read directly
@             into the caller's buffer (up to the end of the cluster); the partial head and tail go through the sector buffer of
@             the FIL.  The next cluster is looked up whenever the file pointer crosses a cluster boundary.  A dirty sector buffer that
@             overlaps the destination is copied over the data read.  Any failure sets the error flag (0x80) of the FIL.
@ -----------------------------------------------------------------------------
FUNC fat_f_read
    push.w  {r1, r4, r5, r6, r7, r8, r9, r10, r11, lr}@ 08021D72 push {r1, r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub     sp, #8                          @ 08021D76 sp -= 8
    movs    r4, r0                          @ 08021D78 r4 = r0
    movs    r5, r2                          @ 08021D7A r5 = r2
    movs    r6, r3                          @ 08021D7C r6 = r3
    ldr.w   r9, [sp, #8]                    @ 08021D7E r9 = u32 [sp+0x8]
    movs    r0, #0                          @ 08021D82 r0 = 0
    @ *br = 0
    str     r0, [r6]                        @ 08021D84 u32 [r6] = r0
    ldrh    r1, [r4, #4]                    @ 08021D86 r1 = u16 [r4+0x4]
    ldr     r0, [r4]                        @ 08021D88 r0 = u32 [r4]
    @ validate the object (mount id, disk status)
    bl      fat_validate                    @ 08021D8A call fat_validate
    strb.w  r0, [sp, #1]                    @ 08021D8E u8 [sp+0x1] = r0
    ldrb.w  r0, [sp, #1]                    @ 08021D92 r0 = u8 [sp+0x1]
    cmp     r0, #0                          @ 08021D96 compare r0 with 0
    beq     .Lfat_f_read_1DA0               @ 08021D98 if (r0 == 0) goto 0x8021DA0
    ldrb.w  r0, [sp, #1]                    @ 08021D9A r0 = u8 [sp+0x1]
    b       .Lfat_f_read_1F5C               @ 08021D9E goto 0x8021F5C
    @ error flag (0x80): internal error (2); read permission (flag bit 0) missing: denied (7)
.Lfat_f_read_1DA0:                      @ v2.05 0x08021DA0, reached from 0x08021D98
    ldrb    r0, [r4, #6]                    @ 08021DA0 r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x18                   @ 08021DA2 r0 = r0 << 0x18
    bpl     .Lfat_f_read_1DAA               @ 08021DA4 if (r0 >=0 0) goto 0x8021DAA
    movs    r0, #2                          @ 08021DA6 r0 = 2
    b       .Lfat_f_read_1F5C               @ 08021DA8 goto 0x8021F5C
.Lfat_f_read_1DAA:                      @ v2.05 0x08021DAA, reached from 0x08021DA4
    ldrb    r0, [r4, #6]                    @ 08021DAA r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x1f                   @ 08021DAC r0 = r0 << 0x1f
    bmi     .Lfat_f_read_1DB4               @ 08021DAE if (r0 <0 0) goto 0x8021DB4
    movs    r0, #7                          @ 08021DB0 r0 = 7
    b       .Lfat_f_read_1F5C               @ 08021DB2 goto 0x8021F5C
    @ bytes to read = min(request, size - file pointer)
.Lfat_f_read_1DB4:                      @ v2.05 0x08021DB4, reached from 0x08021DAE
    ldr     r0, [r4, #0xc]                  @ 08021DB4 r0 = u32 [r4+0xC]
    ldr     r1, [r4, #8]                    @ 08021DB6 r1 = u32 [r4+0x8]
    subs    r0, r0, r1                      @ 08021DB8 r0 = r0 - r1
    str     r0, [sp, #4]                    @ 08021DBA u32 [sp+0x4] = r0
    ldr     r0, [sp, #4]                    @ 08021DBC r0 = u32 [sp+0x4]
    cmp     r0, r5                          @ 08021DBE compare r0 with r5
    bhs     .Lfat_f_read_1DC6               @ 08021DC0 if (r0 >=u r5) goto 0x8021DC6
    ldr     r0, [sp, #4]                    @ 08021DC2 r0 = u32 [sp+0x4]
    movs    r5, r0                          @ 08021DC4 r5 = r0
    @ loop: nothing left (r5 = 0) ends it
.Lfat_f_read_1DC6:                      @ v2.05 0x08021DC6, reached from 0x08021DC0, 0x08021F58
    cmp     r5, #0                          @ 08021DC6 compare r5 with 0
    beq.w   .Lfat_f_read_1F5A               @ 08021DC8 if (r5 == 0) goto 0x8021F5A
    @ file pointer on a sector boundary: find the sector, otherwise copy from the buffer (1F22)
    ldr     r0, [r4, #8]                    @ 08021DCC r0 = u32 [r4+0x8]
    lsls    r0, r0, #0x17                   @ 08021DCE r0 = r0 << 0x17
    bne.w   .Lfat_f_read_1F22               @ 08021DD0 if (r0 != 0) goto 0x8021F22
    @ sector within the cluster = (pointer >> 9) & (sectors per cluster - 1); 0 means a new cluster
    ldr     r0, [r4, #8]                    @ 08021DD4 r0 = u32 [r4+0x8]
    lsrs    r0, r0, #9                      @ 08021DD6 r0 = r0 >> 9
    ldr     r1, [r4]                        @ 08021DD8 r1 = u32 [r4]
    ldrb    r1, [r1, #2]                    @ 08021DDA r1 = u8 [r1+0x2]
    subs    r1, r1, #1                      @ 08021DDC r1 = r1 - 1
    ands    r0, r1                          @ 08021DDE r0 &= r1
    strb.w  r0, [sp]                        @ 08021DE0 u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 08021DE4 r0 = u8 [sp]
    cmp     r0, #0                          @ 08021DE8 compare r0 with 0
    bne     .Lfat_f_read_1E2A               @ 08021DEA if (r0 != 0) goto 0x8021E2A
    @ new cluster: first cluster of the file at pointer 0, otherwise get_fat(current cluster); below 2 internal error (2), 0xFFFFFFFF disk error (1); both set flag 0x80
    ldr     r0, [r4, #8]                    @ 08021DEC r0 = u32 [r4+0x8]
    cmp     r0, #0                          @ 08021DEE compare r0 with 0
    bne     .Lfat_f_read_1DF8               @ 08021DF0 if (r0 != 0) goto 0x8021DF8
    ldr.w   r10, [r4, #0x10]                @ 08021DF2 r10 = u32 [r4+0x10]
    b       .Lfat_f_read_1E02               @ 08021DF6 goto 0x8021E02
.Lfat_f_read_1DF8:                      @ v2.05 0x08021DF8, reached from 0x08021DF0
    ldr     r1, [r4, #0x14]                 @ 08021DF8 r1 = u32 [r4+0x14]
    ldr     r0, [r4]                        @ 08021DFA r0 = u32 [r4]
    bl      fat_get_fat                     @ 08021DFC call fat_get_fat
    mov     r10, r0                         @ 08021E00 r10 = r0
.Lfat_f_read_1E02:                      @ v2.05 0x08021E02, reached from 0x08021DF6
    cmp.w   r10, #2                         @ 08021E02 compare r10 with 2
    bhs     .Lfat_f_read_1E14               @ 08021E06 if (r10 >=u 2) goto 0x8021E14
    ldrb    r0, [r4, #6]                    @ 08021E08 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08021E0A r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08021E0E u8 [r4+0x6] = r0
    movs    r0, #2                          @ 08021E10 r0 = 2
    b       .Lfat_f_read_1F5C               @ 08021E12 goto 0x8021F5C
.Lfat_f_read_1E14:                      @ v2.05 0x08021E14, reached from 0x08021E06
    cmn.w   r10, #1                         @ 08021E14 compare r10 with 1
    bne     .Lfat_f_read_1E26               @ 08021E18 if ((r10 + 1) != 0) goto 0x8021E26
    ldrb    r0, [r4, #6]                    @ 08021E1A r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08021E1C r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08021E20 u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08021E22 r0 = 1
    b       .Lfat_f_read_1F5C               @ 08021E24 goto 0x8021F5C
.Lfat_f_read_1E26:                      @ v2.05 0x08021E26, reached from 0x08021E18
    str.w   r10, [r4, #0x14]                @ 08021E26 u32 [r4+0x14] = r10
    @ sector = first sector of the cluster + sector within the cluster; an invalid cluster gives 2
.Lfat_f_read_1E2A:                      @ v2.05 0x08021E2A, reached from 0x08021DEA
    ldr     r1, [r4, #0x14]                 @ 08021E2A r1 = u32 [r4+0x14]
    ldr     r0, [r4]                        @ 08021E2C r0 = u32 [r4]
    bl      fat_clust2sect                  @ 08021E2E call fat_clust2sect
    mov     r11, r0                         @ 08021E32 r11 = r0
    cmp.w   r11, #0                         @ 08021E34 compare r11 with 0
    bne     .Lfat_f_read_1E46               @ 08021E38 if (r11 != 0) goto 0x8021E46
    ldrb    r0, [r4, #6]                    @ 08021E3A r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08021E3C r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08021E40 u8 [r4+0x6] = r0
    movs    r0, #2                          @ 08021E42 r0 = 2
    b       .Lfat_f_read_1F5C               @ 08021E44 goto 0x8021F5C
.Lfat_f_read_1E46:                      @ v2.05 0x08021E46, reached from 0x08021E38
    ldrb.w  r0, [sp]                        @ 08021E46 r0 = u8 [sp]
    adds.w  r11, r0, r11                    @ 08021E4A r11 = r0 + r11
    @ r8 = whole sectors left (bytes >> 9): non-zero reads them directly into the caller buffer (limited to the end of the cluster, 1E58..1E72), then disk_read (1E80)
    lsrs    r0, r5, #9                      @ 08021E4E r0 = r5 >> 9
    mov     r8, r0                          @ 08021E50 r8 = r0
    cmp.w   r8, #0                          @ 08021E52 compare r8 with 0
    beq     .Lfat_f_read_1ECA               @ 08021E56 if (r8 == 0) goto 0x8021ECA
    ldr     r0, [r4]                        @ 08021E58 r0 = u32 [r4]
    ldrb    r0, [r0, #2]                    @ 08021E5A r0 = u8 [r0+0x2]
    ldrb.w  r1, [sp]                        @ 08021E5C r1 = u8 [sp]
    adds.w  r1, r8, r1                      @ 08021E60 r1 = r8 + r1
    cmp     r0, r1                          @ 08021E64 compare r0 with r1
    bhs     .Lfat_f_read_1E74               @ 08021E66 if (r0 >=u r1) goto 0x8021E74
    ldr     r0, [r4]                        @ 08021E68 r0 = u32 [r4]
    ldrb    r0, [r0, #2]                    @ 08021E6A r0 = u8 [r0+0x2]
    ldrb.w  r1, [sp]                        @ 08021E6C r1 = u8 [sp]
    subs    r0, r0, r1                      @ 08021E70 r0 = r0 - r1
    mov     r8, r0                          @ 08021E72 r8 = r0
.Lfat_f_read_1E74:                      @ v2.05 0x08021E74, reached from 0x08021E66
    mov     r3, r8                          @ 08021E74 r3 = r8
    uxtb    r3, r3                          @ 08021E76 r3 = u8(r3)
    mov     r2, r11                         @ 08021E78 r2 = r11
    mov     r1, r9                          @ 08021E7A r1 = r9
    ldr     r0, [r4]                        @ 08021E7C r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 08021E7E r0 = u8 [r0+0x1]
    bl      disk_read                       @ 08021E80 call disk_read
    cmp     r0, #0                          @ 08021E84 compare r0 with 0
    beq     .Lfat_f_read_1E94               @ 08021E86 if (r0 == 0) goto 0x8021E94
    ldrb    r0, [r4, #6]                    @ 08021E88 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08021E8A r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08021E8E u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08021E90 r0 = 1
    b       .Lfat_f_read_1F5C               @ 08021E92 goto 0x8021F5C
    @ a dirty FIL buffer inside the range just read is copied over the data (1EA4..1EBA)
.Lfat_f_read_1E94:                      @ v2.05 0x08021E94, reached from 0x08021E86
    ldrb    r0, [r4, #6]                    @ 08021E94 r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x19                   @ 08021E96 r0 = r0 << 0x19
    bpl     .Lfat_f_read_1EBE               @ 08021E98 if (r0 >=0 0) goto 0x8021EBE
    ldr     r0, [r4, #0x18]                 @ 08021E9A r0 = u32 [r4+0x18]
    subs.w  r0, r0, r11                     @ 08021E9C r0 = r0 - r11
    cmp     r0, r8                          @ 08021EA0 compare r0 with r8
    bhs     .Lfat_f_read_1EBE               @ 08021EA2 if (r0 >=u r8) goto 0x8021EBE
    mov.w   r2, #0x200                      @ 08021EA4 r2 = 0x200
    adds.w  r1, r4, #0x24                   @ 08021EA8 r1 = r4 + 0x24
    ldr     r0, [r4, #0x18]                 @ 08021EAC r0 = u32 [r4+0x18]
    subs.w  r0, r0, r11                     @ 08021EAE r0 = r0 - r11
    mov.w   r3, #0x200                      @ 08021EB2 r3 = 0x200
    muls    r0, r3, r0                      @ 08021EB6 r0 = r3 * r0
    add     r0, r9                          @ 08021EB8 r0 += r9
    bl      fat_mem_cpy                     @ 08021EBA call fat_mem_cpy
    @ bytes done = 512 * sectors (1EC2)
.Lfat_f_read_1EBE:                      @ v2.05 0x08021EBE, reached from 0x08021E98, 0x08021EA2
    mov.w   r0, #0x200                      @ 08021EBE r0 = 0x200
    mul     r0, r0, r8                      @ 08021EC2 r0 = r0 * r8
    movs    r7, r0                          @ 08021EC6 r7 = r0
    b       .Lfat_f_read_1F48               @ 08021EC8 goto 0x8021F48
    @ less than a sector left: write a dirty FIL buffer first (disk_write at 1EDC), clear flag 0x40
.Lfat_f_read_1ECA:                      @ v2.05 0x08021ECA, reached from 0x08021E56
    ldrb    r0, [r4, #6]                    @ 08021ECA r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x19                   @ 08021ECC r0 = r0 << 0x19
    bpl     .Lfat_f_read_1EF8               @ 08021ECE if (r0 >=0 0) goto 0x8021EF8
    movs    r3, #1                          @ 08021ED0 r3 = 1
    ldr     r2, [r4, #0x18]                 @ 08021ED2 r2 = u32 [r4+0x18]
    adds.w  r1, r4, #0x24                   @ 08021ED4 r1 = r4 + 0x24
    ldr     r0, [r4]                        @ 08021ED8 r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 08021EDA r0 = u8 [r0+0x1]
    bl      disk_write                      @ 08021EDC call disk_write
    cmp     r0, #0                          @ 08021EE0 compare r0 with 0
    beq     .Lfat_f_read_1EF0               @ 08021EE2 if (r0 == 0) goto 0x8021EF0
    ldrb    r0, [r4, #6]                    @ 08021EE4 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08021EE6 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08021EEA u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08021EEC r0 = 1
    b       .Lfat_f_read_1F5C               @ 08021EEE goto 0x8021F5C
.Lfat_f_read_1EF0:                      @ v2.05 0x08021EF0, reached from 0x08021EE2
    ldrb    r0, [r4, #6]                    @ 08021EF0 r0 = u8 [r4+0x6]
    ands    r0, r0, #0xbf                   @ 08021EF2 r0 = r0 & 0xbf
    strb    r0, [r4, #6]                    @ 08021EF6 u8 [r4+0x6] = r0
    @ read the wanted sector into the FIL buffer unless it is there already (disk_read at 1F0A); FIL +0x18 = sector
.Lfat_f_read_1EF8:                      @ v2.05 0x08021EF8, reached from 0x08021ECE
    ldr     r0, [r4, #0x18]                 @ 08021EF8 r0 = u32 [r4+0x18]
    cmp     r0, r11                         @ 08021EFA compare r0 with r11
    beq     .Lfat_f_read_1F1E               @ 08021EFC if (r0 == r11) goto 0x8021F1E
    movs    r3, #1                          @ 08021EFE r3 = 1
    mov     r2, r11                         @ 08021F00 r2 = r11
    adds.w  r1, r4, #0x24                   @ 08021F02 r1 = r4 + 0x24
    ldr     r0, [r4]                        @ 08021F06 r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 08021F08 r0 = u8 [r0+0x1]
    bl      disk_read                       @ 08021F0A call disk_read
    cmp     r0, #0                          @ 08021F0E compare r0 with 0
    beq     .Lfat_f_read_1F1E               @ 08021F10 if (r0 == 0) goto 0x8021F1E
    ldrb    r0, [r4, #6]                    @ 08021F12 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08021F14 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08021F18 u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08021F1A r0 = 1
    b       .Lfat_f_read_1F5C               @ 08021F1C goto 0x8021F5C
.Lfat_f_read_1F1E:                      @ v2.05 0x08021F1E, reached from 0x08021EFC, 0x08021F10
    str.w   r11, [r4, #0x18]                @ 08021F1E u32 [r4+0x18] = r11
    @ bytes from the buffer = min(512 - (pointer & 0x1FF), bytes left)
.Lfat_f_read_1F22:                      @ v2.05 0x08021F22, reached from 0x08021DD0
    ldr     r0, [r4, #8]                    @ 08021F22 r0 = u32 [r4+0x8]
    lsls    r0, r0, #0x17                   @ 08021F24 r0 = r0 << 0x17
    lsrs    r0, r0, #0x17                   @ 08021F26 r0 = r0 >> 0x17
    rsbs.w  r0, r0, #0x200                  @ 08021F28 r0 = 0x200 - r0
    movs    r7, r0                          @ 08021F2C r7 = r0
    cmp     r5, r7                          @ 08021F2E compare r5 with r7
    bhs     .Lfat_f_read_1F34               @ 08021F30 if (r5 >=u r7) goto 0x8021F34
    movs    r7, r5                          @ 08021F32 r7 = r5
.Lfat_f_read_1F34:                      @ v2.05 0x08021F34, reached from 0x08021F30
    movs    r2, r7                          @ 08021F34 r2 = r7
    ldr     r0, [r4, #8]                    @ 08021F36 r0 = u32 [r4+0x8]
    lsls    r0, r0, #0x17                   @ 08021F38 r0 = r0 << 0x17
    lsrs    r0, r0, #0x17                   @ 08021F3A r0 = r0 >> 0x17
    add     r0, r4                          @ 08021F3C r0 += r4
    adds.w  r1, r0, #0x24                   @ 08021F3E r1 = r0 + 0x24
    mov     r0, r9                          @ 08021F42 r0 = r9
    bl      fat_mem_cpy                     @ 08021F44 call fat_mem_cpy
.Lfat_f_read_1F48:                      @ v2.05 0x08021F48, reached from 0x08021EC8
    add     r9, r7                          @ 08021F48 r9 += r7
    ldr     r0, [r4, #8]                    @ 08021F4A r0 = u32 [r4+0x8]
    adds    r0, r7, r0                      @ 08021F4C r0 = r7 + r0
    str     r0, [r4, #8]                    @ 08021F4E u32 [r4+0x8] = r0
    ldr     r0, [r6]                        @ 08021F50 r0 = u32 [r6]
    adds    r0, r7, r0                      @ 08021F52 r0 = r7 + r0
    str     r0, [r6]                        @ 08021F54 u32 [r6] = r0
    subs    r5, r5, r7                      @ 08021F56 r5 = r5 - r7
    b       .Lfat_f_read_1DC6               @ 08021F58 goto 0x8021DC6
.Lfat_f_read_1F5A:                      @ v2.05 0x08021F5A, reached from 0x08021DC8
    movs    r0, #0                          @ 08021F5A r0 = 0
.Lfat_f_read_1F5C:                      @ v2.05 0x08021F5C, reached from 0x08021D9E, 0x08021DA8, 0x08021DB2, 0x08021E12, 0x08021E24, 0x08021E44, 0x08021E92, 0x08021EEE, 0x08021F1C
    pop.w   {r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}@ 08021F5C pop {r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC fat_f_read
    .global fn_08021D72
    .thumb_set fn_08021D72, fat_f_read
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_write - write r2 bytes (FatFs f_write)
@ Replaces  : 0x08021F60 FUN_08021F60 (v2.05), canonical symbol fn_08021F60
@ In        : r0 = FIL pointer, r1 = data, r2 = byte count, r3 = pointer that receives the number of bytes written
@ Out       : r0 = FRESULT (0 ok, 2 internal error, 7 denied - not opened for writing, 9 invalid object, 1 disk error)
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08021F60..0x08022187
@ Note      : like f_read, with the cluster chain extended by fat_create_chain at a cluster boundary (the first cluster is stored
@             in FIL +0x10).  A full volume ends the loop without error and *bw is smaller than the request; the caller compares.
@             A byte count that would wrap the 32-bit size is cut to 0.  The size grows with the file pointer; the flags 0x20 (directory
@             entry must be updated) and, for sector buffer writes, 0x40 (buffer dirty) are set.  An error sets flag 0x80.
@ -----------------------------------------------------------------------------
FUNC fat_f_write
    push.w  {r1, r4, r5, r6, r7, r8, r9, r10, r11, lr}@ 08021F60 push {r1, r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub     sp, #8                          @ 08021F64 sp -= 8
    movs    r4, r0                          @ 08021F66 r4 = r0
    movs    r5, r2                          @ 08021F68 r5 = r2
    movs    r6, r3                          @ 08021F6A r6 = r3
    ldr.w   r11, [sp, #8]                   @ 08021F6C r11 = u32 [sp+0x8]
    movs    r0, #0                          @ 08021F70 r0 = 0
    str     r0, [r6]                        @ 08021F72 u32 [r6] = r0
    ldrh    r1, [r4, #4]                    @ 08021F74 r1 = u16 [r4+0x4]
    ldr     r0, [r4]                        @ 08021F76 r0 = u32 [r4]
    @ validate the object
    bl      fat_validate                    @ 08021F78 call fat_validate
    strb.w  r0, [sp, #1]                    @ 08021F7C u8 [sp+0x1] = r0
    ldrb.w  r0, [sp, #1]                    @ 08021F80 r0 = u8 [sp+0x1]
    cmp     r0, #0                          @ 08021F84 compare r0 with 0
    beq     .Lfat_f_write_1F8E              @ 08021F86 if (r0 == 0) goto 0x8021F8E
    ldrb.w  r0, [sp, #1]                    @ 08021F88 r0 = u8 [sp+0x1]
    b       .Lfat_f_write_2184              @ 08021F8C goto 0x8022184
    @ error flag (0x80): 2; write permission (flag bit 1) missing: denied (7)
.Lfat_f_write_1F8E:                     @ v2.05 0x08021F8E, reached from 0x08021F86
    ldrb    r0, [r4, #6]                    @ 08021F8E r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x18                   @ 08021F90 r0 = r0 << 0x18
    bpl     .Lfat_f_write_1F98              @ 08021F92 if (r0 >=0 0) goto 0x8021F98
    movs    r0, #2                          @ 08021F94 r0 = 2
    b       .Lfat_f_write_2184              @ 08021F96 goto 0x8022184
.Lfat_f_write_1F98:                     @ v2.05 0x08021F98, reached from 0x08021F92
    ldrb    r0, [r4, #6]                    @ 08021F98 r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x1e                   @ 08021F9A r0 = r0 << 0x1e
    bmi     .Lfat_f_write_1FA2              @ 08021F9C if (r0 <0 0) goto 0x8021FA2
    movs    r0, #7                          @ 08021F9E r0 = 7
    b       .Lfat_f_write_2184              @ 08021FA0 goto 0x8022184
    @ a request that would wrap the 32-bit size is cut to 0
.Lfat_f_write_1FA2:                     @ v2.05 0x08021FA2, reached from 0x08021F9C
    ldr     r0, [r4, #0xc]                  @ 08021FA2 r0 = u32 [r4+0xC]
    adds    r0, r5, r0                      @ 08021FA4 r0 = r5 + r0
    ldr     r1, [r4, #0xc]                  @ 08021FA6 r1 = u32 [r4+0xC]
    cmp     r0, r1                          @ 08021FA8 compare r0 with r1
    bhs     .Lfat_f_write_1FB0              @ 08021FAA if (r0 >=u r1) goto 0x8021FB0
    movs    r0, #0                          @ 08021FAC r0 = 0
    movs    r5, r0                          @ 08021FAE r5 = r0
    @ loop: nothing left (r5 = 0) ends it (216E)
.Lfat_f_write_1FB0:                     @ v2.05 0x08021FB0, reached from 0x08021FAA, 0x0802216C
    cmp     r5, #0                          @ 08021FB0 compare r5 with 0
    beq.w   .Lfat_f_write_216E              @ 08021FB2 if (r5 == 0) goto 0x802216E
    ldr     r0, [r4, #8]                    @ 08021FB6 r0 = u32 [r4+0x8]
    lsls    r0, r0, #0x17                   @ 08021FB8 r0 = r0 << 0x17
    @ pointer not on a sector boundary: go on in the buffer (212A)
    bne.w   .Lfat_f_write_212A              @ 08021FBA if (r0 != 0) goto 0x802212A
    ldr     r0, [r4, #8]                    @ 08021FBE r0 = u32 [r4+0x8]
    lsrs    r0, r0, #9                      @ 08021FC0 r0 = r0 >> 9
    ldr     r1, [r4]                        @ 08021FC2 r1 = u32 [r4]
    ldrb    r1, [r1, #2]                    @ 08021FC4 r1 = u8 [r1+0x2]
    subs    r1, r1, #1                      @ 08021FC6 r1 = r1 - 1
    ands    r0, r1                          @ 08021FC8 r0 &= r1
    strb.w  r0, [sp]                        @ 08021FCA u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 08021FCE r0 = u8 [sp]
    @ sector within the cluster 0: a new cluster is needed
    cmp     r0, #0                          @ 08021FD2 compare r0 with 0
    bne     .Lfat_f_write_2026              @ 08021FD4 if (r0 != 0) goto 0x8022026
    ldr     r0, [r4, #8]                    @ 08021FD6 r0 = u32 [r4+0x8]
    cmp     r0, #0                          @ 08021FD8 compare r0 with 0
    bne     .Lfat_f_write_1FF2              @ 08021FDA if (r0 != 0) goto 0x8021FF2
    ldr     r0, [r4, #0x10]                 @ 08021FDC r0 = u32 [r4+0x10]
    movs    r7, r0                          @ 08021FDE r7 = r0
    cmp     r7, #0                          @ 08021FE0 compare r7 with 0
    bne     .Lfat_f_write_1FFC              @ 08021FE2 if (r7 != 0) goto 0x8021FFC
    movs    r1, #0                          @ 08021FE4 r1 = 0
    ldr     r0, [r4]                        @ 08021FE6 r0 = u32 [r4]
    @ pointer 0 and no first cluster yet: create_chain(0); it becomes the first cluster only after the checks below (OF-64)
    bl      fat_create_chain                @ 08021FE8 call fat_create_chain
    movs    r7, r0                          @ 08021FEC r7 = r0
    b       .Lfat_f_write_1FFC              @ 08021FF0 goto 0x8021FFC
.Lfat_f_write_1FF2:                     @ v2.05 0x08021FF2, reached from 0x08021FDA
    ldr     r1, [r4, #0x14]                 @ 08021FF2 r1 = u32 [r4+0x14]
    ldr     r0, [r4]                        @ 08021FF4 r0 = u32 [r4]
    @ otherwise extend the chain: create_chain(current cluster)
    bl      fat_create_chain                @ 08021FF6 call fat_create_chain
    movs    r7, r0                          @ 08021FFA r7 = r0
    @ 0 = volume full: stop without error (the caller sees the short count); 1 = internal error (2); 0xFFFFFFFF = disk error (1); both set flag 0x80
.Lfat_f_write_1FFC:                     @ v2.05 0x08021FFC, reached from 0x08021FE2, 0x08021FF0
    cmp     r7, #0                          @ 08021FFC compare r7 with 0
    beq.w   .Lfat_f_write_216E              @ 08021FFE if (r7 == 0) goto 0x802216E
    cmp     r7, #1                          @ 08022002 compare r7 with 1
    bne     .Lfat_f_write_2012              @ 08022004 if (r7 != 1) goto 0x8022012
    ldrb    r0, [r4, #6]                    @ 08022006 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08022008 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 0802200C u8 [r4+0x6] = r0
    movs    r0, #2                          @ 0802200E r0 = 2
    b       .Lfat_f_write_2184              @ 08022010 goto 0x8022184
.Lfat_f_write_2012:                     @ v2.05 0x08022012, reached from 0x08022004
    cmn.w   r7, #1                          @ 08022012 compare r7 with 1
    bne     .Lfat_f_write_2024              @ 08022016 if ((r7 + 1) != 0) goto 0x8022024
    ldrb    r0, [r4, #6]                    @ 08022018 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 0802201A r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 0802201E u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08022020 r0 = 1
    b       .Lfat_f_write_2184              @ 08022022 goto 0x8022184
.Lfat_f_write_2024:                     @ v2.05 0x08022024, reached from 0x08022016
    @ OF-64: the first cluster of the file (FIL +0x10) is set here, after the result of create_chain was checked (FatFs R0.10b
    @ f_write).  v2.05 stores the result at once (0x08021FEE), so a failed first allocation left 1 or 0xFFFFFFFF in it and
    @ f_sync / f_close wrote that value into the directory entry: a file whose start cluster points nowhere
    ldr     r0, [r4, #0x10]
    cbnz    r0, 1f
    str     r7, [r4, #0x10]                 @ first write: the new chain is the file's first cluster
1:  str     r7, [r4, #0x14]                 @ 08022024 u32 [r4+0x14] = r7
    @ the cluster is the current cluster; a dirty FIL buffer is written first (disk_write at 2038), flag 0x40 cleared
.Lfat_f_write_2026:                     @ v2.05 0x08022026, reached from 0x08021FD4
    ldrb    r0, [r4, #6]                    @ 08022026 r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x19                   @ 08022028 r0 = r0 << 0x19
    bpl     .Lfat_f_write_2054              @ 0802202A if (r0 >=0 0) goto 0x8022054
    movs    r3, #1                          @ 0802202C r3 = 1
    ldr     r2, [r4, #0x18]                 @ 0802202E r2 = u32 [r4+0x18]
    adds.w  r1, r4, #0x24                   @ 08022030 r1 = r4 + 0x24
    ldr     r0, [r4]                        @ 08022034 r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 08022036 r0 = u8 [r0+0x1]
    bl      disk_write                      @ 08022038 call disk_write
    cmp     r0, #0                          @ 0802203C compare r0 with 0
    beq     .Lfat_f_write_204C              @ 0802203E if (r0 == 0) goto 0x802204C
    ldrb    r0, [r4, #6]                    @ 08022040 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08022042 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08022046 u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08022048 r0 = 1
    b       .Lfat_f_write_2184              @ 0802204A goto 0x8022184
.Lfat_f_write_204C:                     @ v2.05 0x0802204C, reached from 0x0802203E
    ldrb    r0, [r4, #6]                    @ 0802204C r0 = u8 [r4+0x6]
    ands    r0, r0, #0xbf                   @ 0802204E r0 = r0 & 0xbf
    strb    r0, [r4, #6]                    @ 08022052 u8 [r4+0x6] = r0
.Lfat_f_write_2054:                     @ v2.05 0x08022054, reached from 0x0802202A
    ldr     r1, [r4, #0x14]                 @ 08022054 r1 = u32 [r4+0x14]
    ldr     r0, [r4]                        @ 08022056 r0 = u32 [r4]
    @ sector = first sector of the cluster + sector within the cluster (0 = internal error)
    bl      fat_clust2sect                  @ 08022058 call fat_clust2sect
    mov     r8, r0                          @ 0802205C r8 = r0
    cmp.w   r8, #0                          @ 0802205E compare r8 with 0
    bne     .Lfat_f_write_2070              @ 08022062 if (r8 != 0) goto 0x8022070
    ldrb    r0, [r4, #6]                    @ 08022064 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08022066 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 0802206A u8 [r4+0x6] = r0
    movs    r0, #2                          @ 0802206C r0 = 2
    b       .Lfat_f_write_2184              @ 0802206E goto 0x8022184
    @ whole sectors left (r10 = bytes >> 9) and more than 0: write them directly, limited to the end of the cluster
.Lfat_f_write_2070:                     @ v2.05 0x08022070, reached from 0x08022062
    ldrb.w  r0, [sp]                        @ 08022070 r0 = u8 [sp]
    adds.w  r8, r0, r8                      @ 08022074 r8 = r0 + r8
    lsrs    r0, r5, #9                      @ 08022078 r0 = r5 >> 9
    mov     r10, r0                         @ 0802207A r10 = r0
    cmp.w   r10, #0                         @ 0802207C compare r10 with 0
    beq     .Lfat_f_write_20F8              @ 08022080 if (r10 == 0) goto 0x80220F8
    ldr     r0, [r4]                        @ 08022082 r0 = u32 [r4]
    ldrb    r0, [r0, #2]                    @ 08022084 r0 = u8 [r0+0x2]
    ldrb.w  r1, [sp]                        @ 08022086 r1 = u8 [sp]
    adds.w  r1, r10, r1                     @ 0802208A r1 = r10 + r1
    cmp     r0, r1                          @ 0802208E compare r0 with r1
    bhs     .Lfat_f_write_209E              @ 08022090 if (r0 >=u r1) goto 0x802209E
    ldr     r0, [r4]                        @ 08022092 r0 = u32 [r4]
    ldrb    r0, [r0, #2]                    @ 08022094 r0 = u8 [r0+0x2]
    ldrb.w  r1, [sp]                        @ 08022096 r1 = u8 [sp]
    subs    r0, r0, r1                      @ 0802209A r0 = r0 - r1
    mov     r10, r0                         @ 0802209C r10 = r0
.Lfat_f_write_209E:                     @ v2.05 0x0802209E, reached from 0x08022090
    mov     r3, r10                         @ 0802209E r3 = r10
    uxtb    r3, r3                          @ 080220A0 r3 = u8(r3)
    mov     r2, r8                          @ 080220A2 r2 = r8
    mov     r1, r11                         @ 080220A4 r1 = r11
    ldr     r0, [r4]                        @ 080220A6 r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 080220A8 r0 = u8 [r0+0x1]
    @ disk_write of the sectors
    bl      disk_write                      @ 080220AA call disk_write
    cmp     r0, #0                          @ 080220AE compare r0 with 0
    beq     .Lfat_f_write_20BE              @ 080220B0 if (r0 == 0) goto 0x80220BE
    ldrb    r0, [r4, #6]                    @ 080220B2 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 080220B4 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 080220B8 u8 [r4+0x6] = r0
    movs    r0, #1                          @ 080220BA r0 = 1
    b       .Lfat_f_write_2184              @ 080220BC goto 0x8022184
.Lfat_f_write_20BE:                     @ v2.05 0x080220BE, reached from 0x080220B0
    ldr     r0, [r4, #0x18]                 @ 080220BE r0 = u32 [r4+0x18]
    subs.w  r0, r0, r8                      @ 080220C0 r0 = r0 - r8
    @ a FIL buffer lying inside the written range is refreshed from the data (mem_cpy at 20E0) and marked clean
    cmp     r0, r10                         @ 080220C4 compare r0 with r10
    bhs     .Lfat_f_write_20EC              @ 080220C6 if (r0 >=u r10) goto 0x80220EC
    mov.w   r2, #0x200                      @ 080220C8 r2 = 0x200
    ldr     r0, [r4, #0x18]                 @ 080220CC r0 = u32 [r4+0x18]
    subs.w  r0, r0, r8                      @ 080220CE r0 = r0 - r8
    mov.w   r1, #0x200                      @ 080220D2 r1 = 0x200
    muls    r0, r1, r0                      @ 080220D6 r0 = r1 * r0
    add.w   r1, r11, r0                     @ 080220D8 r1 = r11 + r0
    adds.w  r0, r4, #0x24                   @ 080220DC r0 = r4 + 0x24
    bl      fat_mem_cpy                     @ 080220E0 call fat_mem_cpy
    ldrb    r0, [r4, #6]                    @ 080220E4 r0 = u8 [r4+0x6]
    ands    r0, r0, #0xbf                   @ 080220E6 r0 = r0 & 0xbf
    strb    r0, [r4, #6]                    @ 080220EA u8 [r4+0x6] = r0
.Lfat_f_write_20EC:                     @ v2.05 0x080220EC, reached from 0x080220C6
    mov.w   r0, #0x200                      @ 080220EC r0 = 0x200
    mul     r0, r0, r10                     @ 080220F0 r0 = r0 * r10
    mov     r9, r0                          @ 080220F4 r9 = r0
    b       .Lfat_f_write_2156              @ 080220F6 goto 0x8022156
    @ less than a sector: when the buffer holds another sector and the pointer is inside the file, load the sector (disk_read at 2112)
.Lfat_f_write_20F8:                     @ v2.05 0x080220F8, reached from 0x08022080
    ldr     r0, [r4, #0x18]                 @ 080220F8 r0 = u32 [r4+0x18]
    cmp     r0, r8                          @ 080220FA compare r0 with r8
    beq     .Lfat_f_write_2126              @ 080220FC if (r0 == r8) goto 0x8022126
    ldr     r0, [r4, #8]                    @ 080220FE r0 = u32 [r4+0x8]
    ldr     r1, [r4, #0xc]                  @ 08022100 r1 = u32 [r4+0xC]
    cmp     r0, r1                          @ 08022102 compare r0 with r1
    bhs     .Lfat_f_write_2126              @ 08022104 if (r0 >=u r1) goto 0x8022126
    movs    r3, #1                          @ 08022106 r3 = 1
    mov     r2, r8                          @ 08022108 r2 = r8
    adds.w  r1, r4, #0x24                   @ 0802210A r1 = r4 + 0x24
    ldr     r0, [r4]                        @ 0802210E r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 08022110 r0 = u8 [r0+0x1]
    bl      disk_read                       @ 08022112 call disk_read
    cmp     r0, #0                          @ 08022116 compare r0 with 0
    beq     .Lfat_f_write_2126              @ 08022118 if (r0 == 0) goto 0x8022126
    ldrb    r0, [r4, #6]                    @ 0802211A r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 0802211C r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08022120 u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08022122 r0 = 1
    b       .Lfat_f_write_2184              @ 08022124 goto 0x8022184
.Lfat_f_write_2126:                     @ v2.05 0x08022126, reached from 0x080220FC, 0x08022104, 0x08022118
    str.w   r8, [r4, #0x18]                 @ 08022126 u32 [r4+0x18] = r8
    @ copy the bytes into the FIL buffer at pointer & 0x1FF (mem_cpy at 214A) and set flag 0x40 (buffer dirty)
.Lfat_f_write_212A:                     @ v2.05 0x0802212A, reached from 0x08021FBA
    ldr     r0, [r4, #8]                    @ 0802212A r0 = u32 [r4+0x8]
    lsls    r0, r0, #0x17                   @ 0802212C r0 = r0 << 0x17
    lsrs    r0, r0, #0x17                   @ 0802212E r0 = r0 >> 0x17
    rsbs.w  r0, r0, #0x200                  @ 08022130 r0 = 0x200 - r0
    mov     r9, r0                          @ 08022134 r9 = r0
    cmp     r5, r9                          @ 08022136 compare r5 with r9
    bhs     .Lfat_f_write_213C              @ 08022138 if (r5 >=u r9) goto 0x802213C
    mov     r9, r5                          @ 0802213A r9 = r5
.Lfat_f_write_213C:                     @ v2.05 0x0802213C, reached from 0x08022138
    mov     r2, r9                          @ 0802213C r2 = r9
    mov     r1, r11                         @ 0802213E r1 = r11
    ldr     r0, [r4, #8]                    @ 08022140 r0 = u32 [r4+0x8]
    lsls    r0, r0, #0x17                   @ 08022142 r0 = r0 << 0x17
    lsrs    r0, r0, #0x17                   @ 08022144 r0 = r0 >> 0x17
    add     r0, r4                          @ 08022146 r0 += r4
    adds    r0, #0x24                       @ 08022148 r0 += 0x24
    bl      fat_mem_cpy                     @ 0802214A call fat_mem_cpy
    ldrb    r0, [r4, #6]                    @ 0802214E r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x40                   @ 08022150 r0 = r0 | 0x40
    strb    r0, [r4, #6]                    @ 08022154 u8 [r4+0x6] = r0
    @ advance the data pointer, the file pointer and the count
.Lfat_f_write_2156:                     @ v2.05 0x08022156, reached from 0x080220F6
    add     r11, r9                         @ 08022156 r11 += r9
    ldr     r0, [r4, #8]                    @ 08022158 r0 = u32 [r4+0x8]
    adds.w  r0, r9, r0                      @ 0802215A r0 = r9 + r0
    str     r0, [r4, #8]                    @ 0802215E u32 [r4+0x8] = r0
    ldr     r0, [r6]                        @ 08022160 r0 = u32 [r6]
    adds.w  r0, r9, r0                      @ 08022162 r0 = r9 + r0
    str     r0, [r6]                        @ 08022166 u32 [r6] = r0
    subs.w  r5, r5, r9                      @ 08022168 r5 = r5 - r9
    b       .Lfat_f_write_1FB0              @ 0802216C goto 0x8021FB0
    @ size = max(size, pointer); flag 0x20 (directory entry must be updated)
.Lfat_f_write_216E:                     @ v2.05 0x0802216E, reached from 0x08021FB2, 0x08021FFE
    ldr     r0, [r4, #0xc]                  @ 0802216E r0 = u32 [r4+0xC]
    ldr     r1, [r4, #8]                    @ 08022170 r1 = u32 [r4+0x8]
    cmp     r0, r1                          @ 08022172 compare r0 with r1
    bhs     .Lfat_f_write_217A              @ 08022174 if (r0 >=u r1) goto 0x802217A
    ldr     r0, [r4, #8]                    @ 08022176 r0 = u32 [r4+0x8]
    str     r0, [r4, #0xc]                  @ 08022178 u32 [r4+0xC] = r0
.Lfat_f_write_217A:                     @ v2.05 0x0802217A, reached from 0x08022174
    ldrb    r0, [r4, #6]                    @ 0802217A r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x20                   @ 0802217C r0 = r0 | 0x20
    strb    r0, [r4, #6]                    @ 08022180 u8 [r4+0x6] = r0
    movs    r0, #0                          @ 08022182 r0 = 0
.Lfat_f_write_2184:                     @ v2.05 0x08022184, reached from 0x08021F8C, 0x08021F96, 0x08021FA0, 0x08022010, 0x08022022, 0x0802204A, 0x0802206E, 0x080220BC, 0x08022124
    pop.w   {r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}@ 08022184 pop {r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC fat_f_write
    .global fn_08021F60
    .thumb_set fn_08021F60, fat_f_write
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_sync - write all pending data and update the directory entry (FatFs f_sync)
@ Replaces  : 0x08022188 FUN_08022188 (v2.05), called by f_close
@ In        : r0 = FIL pointer
@ Out       : r0 = FRESULT
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08022188..0x0802224B
@ Note      : if the file was written (flag 0x20): a dirty sector buffer is written, the window is loaded with the directory sector,
@             the entry gets the archive attribute (0x20), the size, the first cluster (high and low halves) and the modification time
@             (get_fattime), the flag is cleared and the file system is synchronised (fat_sync_fs).
@ -----------------------------------------------------------------------------
FUNC fat_f_sync
    push    {r3, r4, r5, r6, r7, lr}        @ 08022188 push {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 0802218A r4 = r0
    ldrh    r1, [r4, #4]                    @ 0802218C r1 = u16 [r4+0x4]
    ldr     r0, [r4]                        @ 0802218E r0 = u32 [r4]
    @ validate the object
    bl      fat_validate                    @ 08022190 call fat_validate
    movs    r5, r0                          @ 08022194 r5 = r0
    uxtb    r5, r5                          @ 08022196 r5 = u8(r5)
    cmp     r5, #0                          @ 08022198 compare r5 with 0
    bne     .Lfat_f_sync_2246               @ 0802219A if (r5 != 0) goto 0x8022246
    ldrb    r0, [r4, #6]                    @ 0802219C r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x1a                   @ 0802219E r0 = r0 << 0x1a
    @ only when flag 0x20 is set (the file was written)
    bpl     .Lfat_f_sync_2246               @ 080221A0 if (r0 >=0 0) goto 0x8022246
    ldrb    r0, [r4, #6]                    @ 080221A2 r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x19                   @ 080221A4 r0 = r0 << 0x19
    @ a dirty FIL buffer (flag 0x40) is written first (disk_write at 21B4)
    bpl     .Lfat_f_sync_21C8               @ 080221A6 if (r0 >=0 0) goto 0x80221C8
    movs    r3, #1                          @ 080221A8 r3 = 1
    ldr     r2, [r4, #0x18]                 @ 080221AA r2 = u32 [r4+0x18]
    adds.w  r1, r4, #0x24                   @ 080221AC r1 = r4 + 0x24
    ldr     r0, [r4]                        @ 080221B0 r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 080221B2 r0 = u8 [r0+0x1]
    bl      disk_write                      @ 080221B4 call disk_write
    cmp     r0, #0                          @ 080221B8 compare r0 with 0
    beq     .Lfat_f_sync_21C0               @ 080221BA if (r0 == 0) goto 0x80221C0
    movs    r0, #1                          @ 080221BC r0 = 1
    b       .Lfat_f_sync_224A               @ 080221BE goto 0x802224A
.Lfat_f_sync_21C0:                      @ v2.05 0x080221C0, reached from 0x080221BA
    ldrb    r0, [r4, #6]                    @ 080221C0 r0 = u8 [r4+0x6]
    ands    r0, r0, #0xbf                   @ 080221C2 r0 = r0 & 0xbf
    strb    r0, [r4, #6]                    @ 080221C6 u8 [r4+0x6] = r0
.Lfat_f_sync_21C8:                      @ v2.05 0x080221C8, reached from 0x080221A6
    ldr     r1, [r4, #0x1c]                 @ 080221C8 r1 = u32 [r4+0x1C]
    ldr     r0, [r4]                        @ 080221CA r0 = u32 [r4]
    @ load the sector of the directory entry (FIL +0x1C) into the window
    bl      fat_move_window                 @ 080221CC call fat_move_window
    movs    r5, r0                          @ 080221D0 r5 = r0
    uxtb    r5, r5                          @ 080221D2 r5 = u8(r5)
    cmp     r5, #0                          @ 080221D4 compare r5 with 0
    bne     .Lfat_f_sync_2246               @ 080221D6 if (r5 != 0) goto 0x8022246
    @ entry: attribute |= 0x20 (archive), size, first cluster (bytes 0x1A/0x1B low, 0x14/0x15 high), modification time and date from get_fattime (2218)
    ldr     r0, [r4, #0x20]                 @ 080221D8 r0 = u32 [r4+0x20]
    movs    r7, r0                          @ 080221DA r7 = r0
    ldrb    r0, [r7, #0xb]                  @ 080221DC r0 = u8 [r7+0xB]
    orrs    r0, r0, #0x20                   @ 080221DE r0 = r0 | 0x20
    strb    r0, [r7, #0xb]                  @ 080221E2 u8 [r7+0xB] = r0
    ldr     r0, [r4, #0xc]                  @ 080221E4 r0 = u32 [r4+0xC]
    strb    r0, [r7, #0x1c]                 @ 080221E6 u8 [r7+0x1C] = r0
    ldr     r0, [r4, #0xc]                  @ 080221E8 r0 = u32 [r4+0xC]
    uxth    r0, r0                          @ 080221EA r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 080221EC r0 = r0 >> 8
    strb    r0, [r7, #0x1d]                 @ 080221EE u8 [r7+0x1D] = r0
    ldr     r0, [r4, #0xc]                  @ 080221F0 r0 = u32 [r4+0xC]
    lsrs    r0, r0, #0x10                   @ 080221F2 r0 = r0 >> 0x10
    strb    r0, [r7, #0x1e]                 @ 080221F4 u8 [r7+0x1E] = r0
    ldr     r0, [r4, #0xc]                  @ 080221F6 r0 = u32 [r4+0xC]
    lsrs    r0, r0, #0x18                   @ 080221F8 r0 = r0 >> 0x18
    strb    r0, [r7, #0x1f]                 @ 080221FA u8 [r7+0x1F] = r0
    ldr     r0, [r4, #0x10]                 @ 080221FC r0 = u32 [r4+0x10]
    strb    r0, [r7, #0x1a]                 @ 080221FE u8 [r7+0x1A] = r0
    ldr     r0, [r4, #0x10]                 @ 08022200 r0 = u32 [r4+0x10]
    uxth    r0, r0                          @ 08022202 r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 08022204 r0 = r0 >> 8
    strb    r0, [r7, #0x1b]                 @ 08022206 u8 [r7+0x1B] = r0
    ldr     r0, [r4, #0x10]                 @ 08022208 r0 = u32 [r4+0x10]
    lsrs    r0, r0, #0x10                   @ 0802220A r0 = r0 >> 0x10
    strb    r0, [r7, #0x14]                 @ 0802220C u8 [r7+0x14] = r0
    ldr     r0, [r4, #0x10]                 @ 0802220E r0 = u32 [r4+0x10]
    lsrs    r0, r0, #0x10                   @ 08022210 r0 = r0 >> 0x10
    uxth    r0, r0                          @ 08022212 r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 08022214 r0 = r0 >> 8
    strb    r0, [r7, #0x15]                 @ 08022216 u8 [r7+0x15] = r0
    bl      get_fattime                     @ 08022218 call get_fattime
    movs    r6, r0                          @ 0802221C r6 = r0
    strb    r6, [r7, #0x16]                 @ 0802221E u8 [r7+0x16] = r6
    movs    r0, r6                          @ 08022220 r0 = r6
    uxth    r0, r0                          @ 08022222 r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 08022224 r0 = r0 >> 8
    strb    r0, [r7, #0x17]                 @ 08022226 u8 [r7+0x17] = r0
    lsrs    r0, r6, #0x10                   @ 08022228 r0 = r6 >> 0x10
    strb    r0, [r7, #0x18]                 @ 0802222A u8 [r7+0x18] = r0
    lsrs    r0, r6, #0x18                   @ 0802222C r0 = r6 >> 0x18
    strb    r0, [r7, #0x19]                 @ 0802222E u8 [r7+0x19] = r0
    ldrb    r0, [r4, #6]                    @ 08022230 r0 = u8 [r4+0x6]
    ands    r0, r0, #0xdf                   @ 08022232 r0 = r0 & 0xdf
    strb    r0, [r4, #6]                    @ 08022236 u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08022238 r0 = 1
    ldr     r1, [r4]                        @ 0802223A r1 = u32 [r4]
    strb    r0, [r1, #4]                    @ 0802223C u8 [r1+0x4] = r0
    ldr     r0, [r4]                        @ 0802223E r0 = u32 [r4]
    @ flag 0x20 cleared, window dirty, then sync_fs
    bl      fat_sync_fs                     @ 08022240 call fat_sync_fs
    movs    r5, r0                          @ 08022244 r5 = r0
.Lfat_f_sync_2246:                      @ v2.05 0x08022246, reached from 0x0802219A, 0x080221A0, 0x080221D6
    movs    r0, r5                          @ 08022246 r0 = r5
    uxtb    r0, r0                          @ 08022248 r0 = u8(r0)
.Lfat_f_sync_224A:                      @ v2.05 0x0802224A, reached from 0x080221BE
    pop     {r1, r4, r5, r6, r7, pc}        @ 0802224A pop {r1, r4, r5, r6, r7, pc}
ENDFUNC fat_f_sync
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_close - close a file (FatFs f_close)
@ Replaces  : 0x0802224C FUN_0802224C (v2.05), canonical symbol fn_0802224C
@ In        : r0 = FIL pointer
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802224C..0x08022267
@ Note      : f_sync; when it succeeds FIL +0 (fs) is cleared.  The file pointer (FIL +8) and size (FIL +0xC) stay readable, which
@             log_session_once uses (f_tell after the close).
@ -----------------------------------------------------------------------------
FUNC fat_f_close
    push    {r3, r4, r5, lr}                @ 0802224C push {r3, r4, r5, lr}
    movs    r4, r0                          @ 0802224E r4 = r0
    movs    r0, r4                          @ 08022250 r0 = r4
    bl      fat_f_sync                      @ 08022252 call fat_f_sync
    movs    r5, r0                          @ 08022256 r5 = r0
    uxtb    r5, r5                          @ 08022258 r5 = u8(r5)
    cmp     r5, #0                          @ 0802225A compare r5 with 0
    bne     .Lfat_f_close_2262              @ 0802225C if (r5 != 0) goto 0x8022262
    movs    r0, #0                          @ 0802225E r0 = 0
    str     r0, [r4]                        @ 08022260 u32 [r4] = r0
.Lfat_f_close_2262:                     @ v2.05 0x08022262, reached from 0x0802225C
    movs    r0, r5                          @ 08022262 r0 = r5
    uxtb    r0, r0                          @ 08022264 r0 = u8(r0)
    pop     {r1, r4, r5, pc}                @ 08022266 pop {r1, r4, r5, pc}
ENDFUNC fat_f_close
    .global fn_0802224C
    .thumb_set fn_0802224C, fat_f_close
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_lseek - set the file pointer (FatFs f_lseek)
@ Replaces  : 0x08022268 FUN_08022268 (v2.05), canonical symbol fn_08022268
@ In        : r0 = FIL pointer, r1 = new file pointer
@ Out       : r0 = FRESULT (0 ok)
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08022268..0x0802242B
@ Note      : a pointer beyond the size is cut to the size unless the file was opened for writing; in write mode the chain is
@             extended with create_chain.  The cluster is found by walking the chain from the start (or from the current cluster when
@             the target is in the same or a later cluster).  If the target is not on a sector boundary the sector is loaded into the
@             buffer (a dirty buffer is written first).  A pointer beyond the size sets the size and flag 0x20.
@ -----------------------------------------------------------------------------
FUNC fat_f_lseek
    push.w  {r4, r5, r6, r7, r8, r9, r10, lr}@ 08022268 push {r4, r5, r6, r7, r8, r9, r10, lr}
    movs    r4, r0                          @ 0802226C r4 = r0
    movs    r5, r1                          @ 0802226E r5 = r1
    ldrh    r1, [r4, #4]                    @ 08022270 r1 = u16 [r4+0x4]
    ldr     r0, [r4]                        @ 08022272 r0 = u32 [r4]
    @ validate the object
    bl      fat_validate                    @ 08022274 call fat_validate
    movs    r6, r0                          @ 08022278 r6 = r0
    uxtb    r6, r6                          @ 0802227A r6 = u8(r6)
    @ error flag (0x80): 2
    cmp     r6, #0                          @ 0802227C compare r6 with 0
    beq     .Lfat_f_lseek_2286              @ 0802227E if (r6 == 0) goto 0x8022286
    movs    r0, r6                          @ 08022280 r0 = r6
    uxtb    r0, r0                          @ 08022282 r0 = u8(r0)
    b       .Lfat_f_lseek_2428              @ 08022284 goto 0x8022428
.Lfat_f_lseek_2286:                     @ v2.05 0x08022286, reached from 0x0802227E
    ldrb    r0, [r4, #6]                    @ 08022286 r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x18                   @ 08022288 r0 = r0 << 0x18
    bpl     .Lfat_f_lseek_2290              @ 0802228A if (r0 >=0 0) goto 0x8022290
    movs    r0, #2                          @ 0802228C r0 = 2
    b       .Lfat_f_lseek_2428              @ 0802228E goto 0x8022428
.Lfat_f_lseek_2290:                     @ v2.05 0x08022290, reached from 0x0802228A
    ldr     r0, [r4, #0xc]                  @ 08022290 r0 = u32 [r4+0xC]
    @ limit r1: beyond the size only allowed when the file was opened for writing
    cmp     r0, r5                          @ 08022292 compare r0 with r5
    bhs     .Lfat_f_lseek_22A0              @ 08022294 if (r0 >=u r5) goto 0x80222A0
    ldrb    r0, [r4, #6]                    @ 08022296 r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x1e                   @ 08022298 r0 = r0 << 0x1e
    bmi     .Lfat_f_lseek_22A0              @ 0802229A if (r0 <0 0) goto 0x80222A0
    ldr     r0, [r4, #0xc]                  @ 0802229C r0 = u32 [r4+0xC]
    movs    r5, r0                          @ 0802229E r5 = r0
.Lfat_f_lseek_22A0:                     @ v2.05 0x080222A0, reached from 0x08022294, 0x0802229A
    ldr     r0, [r4, #8]                    @ 080222A0 r0 = u32 [r4+0x8]
    mov     r10, r0                         @ 080222A2 r10 = r0
    movs    r0, #0                          @ 080222A4 r0 = 0
    mov     r9, r0                          @ 080222A6 r9 = r0
    str.w   r9, [r4, #8]                    @ 080222A8 u32 [r4+0x8] = r9
    @ new pointer 0: no cluster walk (23B2)
    cmp     r5, #0                          @ 080222AC compare r5 with 0
    beq.w   .Lfat_f_lseek_23B2              @ 080222AE if (r5 == 0) goto 0x80223B2
    ldr     r0, [r4]                        @ 080222B2 r0 = u32 [r4]
    ldrb    r0, [r0, #2]                    @ 080222B4 r0 = u8 [r0+0x2]
    mov.w   r1, #0x200                      @ 080222B6 r1 = 0x200
    muls    r0, r1, r0                      @ 080222BA r0 = r1 * r0
    mov     r8, r0                          @ 080222BC r8 = r0
    @ old pointer non-zero: if the target lies in the current or a later cluster (compare of cluster numbers at 22D2) the walk continues from the current cluster, otherwise it restarts from the first cluster
    cmp.w   r10, #0                         @ 080222BE compare r10 with 0
    beq     .Lfat_f_lseek_22EC              @ 080222C2 if (r10 == 0) goto 0x80222EC
    subs.w  r0, r10, #1                     @ 080222C4 r0 = r10 - 1
    udiv    r0, r0, r8                      @ 080222C8
    subs    r1, r5, #1                      @ 080222CC r1 = r5 - 1
    udiv    r1, r1, r8                      @ 080222CE
    cmp     r1, r0                          @ 080222D2 compare r1 with r0
    blo     .Lfat_f_lseek_22EC              @ 080222D4 if (r1 <u r0) goto 0x80222EC
    subs.w  r0, r10, #1                     @ 080222D6 r0 = r10 - 1
    subs.w  r1, r8, #1                      @ 080222DA r1 = r8 - 1
    bics    r0, r1                          @ 080222DE r0 & ~= r1
    str     r0, [r4, #8]                    @ 080222E0 u32 [r4+0x8] = r0
    ldr     r0, [r4, #8]                    @ 080222E2 r0 = u32 [r4+0x8]
    subs    r5, r5, r0                      @ 080222E4 r5 = r5 - r0
    ldr     r0, [r4, #0x14]                 @ 080222E6 r0 = u32 [r4+0x14]
    movs    r7, r0                          @ 080222E8 r7 = r0
    b       .Lfat_f_lseek_2324              @ 080222EA goto 0x8022324
    @ restart at the first cluster; an empty file in write mode gets its first cluster with create_chain(0) (22F8)
.Lfat_f_lseek_22EC:                     @ v2.05 0x080222EC, reached from 0x080222C2, 0x080222D4
    ldr     r0, [r4, #0x10]                 @ 080222EC r0 = u32 [r4+0x10]
    movs    r7, r0                          @ 080222EE r7 = r0
    cmp     r7, #0                          @ 080222F0 compare r7 with 0
    bne     .Lfat_f_lseek_2322              @ 080222F2 if (r7 != 0) goto 0x8022322
    movs    r1, #0                          @ 080222F4 r1 = 0
    ldr     r0, [r4]                        @ 080222F6 r0 = u32 [r4]
    bl      fat_create_chain                @ 080222F8 call fat_create_chain
    movs    r7, r0                          @ 080222FC r7 = r0
    cmp     r7, #1                          @ 080222FE compare r7 with 1
    bne     .Lfat_f_lseek_230E              @ 08022300 if (r7 != 1) goto 0x802230E
    ldrb    r0, [r4, #6]                    @ 08022302 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08022304 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08022308 u8 [r4+0x6] = r0
    movs    r0, #2                          @ 0802230A r0 = 2
    b       .Lfat_f_lseek_2428              @ 0802230C goto 0x8022428
.Lfat_f_lseek_230E:                     @ v2.05 0x0802230E, reached from 0x08022300
    cmn.w   r7, #1                          @ 0802230E compare r7 with 1
    bne     .Lfat_f_lseek_2320              @ 08022312 if ((r7 + 1) != 0) goto 0x8022320
    ldrb    r0, [r4, #6]                    @ 08022314 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08022316 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 0802231A u8 [r4+0x6] = r0
    movs    r0, #1                          @ 0802231C r0 = 1
    b       .Lfat_f_lseek_2428              @ 0802231E goto 0x8022428
.Lfat_f_lseek_2320:                     @ v2.05 0x08022320, reached from 0x08022312
    str     r7, [r4, #0x10]                 @ 08022320 u32 [r4+0x10] = r7
.Lfat_f_lseek_2322:                     @ v2.05 0x08022322, reached from 0x080222F2
    str     r7, [r4, #0x14]                 @ 08022322 u32 [r4+0x14] = r7
.Lfat_f_lseek_2324:                     @ v2.05 0x08022324, reached from 0x080222EA
    cmp     r7, #0                          @ 08022324 compare r7 with 0
    beq     .Lfat_f_lseek_23B2              @ 08022326 if (r7 == 0) goto 0x80223B2
    @ walk loop: whole clusters left in the offset (r8 >= cluster size)
.Lfat_f_lseek_2328:                     @ v2.05 0x08022328, reached from 0x08022386
    cmp     r8, r5                          @ 08022328 compare r8 with r5
    bhs     .Lfat_f_lseek_2388              @ 0802232A if (r8 >=u r5) goto 0x8022388
    ldrb    r0, [r4, #6]                    @ 0802232C r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x1e                   @ 0802232E r0 = r0 << 0x1e
    @ write mode: create_chain extends the chain when the end is reached (2336); read mode: get_fat (2348); below 2 or beyond the volume: error (2), 0xFFFFFFFF: disk error (1)
    bpl     .Lfat_f_lseek_2344              @ 08022330 if (r0 >=0 0) goto 0x8022344
    movs    r1, r7                          @ 08022332 r1 = r7
    ldr     r0, [r4]                        @ 08022334 r0 = u32 [r4]
    bl      fat_create_chain                @ 08022336 call fat_create_chain
    movs    r7, r0                          @ 0802233A r7 = r0
    cmp     r7, #0                          @ 0802233C compare r7 with 0
    bne     .Lfat_f_lseek_234E              @ 0802233E if (r7 != 0) goto 0x802234E
    mov     r5, r8                          @ 08022340 r5 = r8
    b       .Lfat_f_lseek_2388              @ 08022342 goto 0x8022388
.Lfat_f_lseek_2344:                     @ v2.05 0x08022344, reached from 0x08022330
    movs    r1, r7                          @ 08022344 r1 = r7
    ldr     r0, [r4]                        @ 08022346 r0 = u32 [r4]
    bl      fat_get_fat                     @ 08022348 call fat_get_fat
    movs    r7, r0                          @ 0802234C r7 = r0
.Lfat_f_lseek_234E:                     @ v2.05 0x0802234E, reached from 0x0802233E
    cmn.w   r7, #1                          @ 0802234E compare r7 with 1
    bne     .Lfat_f_lseek_2360              @ 08022352 if ((r7 + 1) != 0) goto 0x8022360
    ldrb    r0, [r4, #6]                    @ 08022354 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08022356 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 0802235A u8 [r4+0x6] = r0
    movs    r0, #1                          @ 0802235C r0 = 1
    b       .Lfat_f_lseek_2428              @ 0802235E goto 0x8022428
.Lfat_f_lseek_2360:                     @ v2.05 0x08022360, reached from 0x08022352
    cmp     r7, #2                          @ 08022360 compare r7 with 2
    blo     .Lfat_f_lseek_236C              @ 08022362 if (r7 <u 2) goto 0x802236C
    ldr     r0, [r4]                        @ 08022364 r0 = u32 [r4]
    ldr     r0, [r0, #0x18]                 @ 08022366 r0 = u32 [r0+0x18]
    cmp     r7, r0                          @ 08022368 compare r7 with r0
    blo     .Lfat_f_lseek_2378              @ 0802236A if (r7 <u r0) goto 0x8022378
.Lfat_f_lseek_236C:                     @ v2.05 0x0802236C, reached from 0x08022362
    ldrb    r0, [r4, #6]                    @ 0802236C r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 0802236E r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08022372 u8 [r4+0x6] = r0
    movs    r0, #2                          @ 08022374 r0 = 2
    b       .Lfat_f_lseek_2428              @ 08022376 goto 0x8022428
.Lfat_f_lseek_2378:                     @ v2.05 0x08022378, reached from 0x0802236A
    str     r7, [r4, #0x14]                 @ 08022378 u32 [r4+0x14] = r7
    ldr     r0, [r4, #8]                    @ 0802237A r0 = u32 [r4+0x8]
    adds.w  r0, r8, r0                      @ 0802237C r0 = r8 + r0
    str     r0, [r4, #8]                    @ 08022380 u32 [r4+0x8] = r0
    subs.w  r5, r5, r8                      @ 08022382 r5 = r5 - r8
    b       .Lfat_f_lseek_2328              @ 08022386 goto 0x8022328
    @ cluster found: its first sector (clust2sect); 0 = internal error
.Lfat_f_lseek_2388:                     @ v2.05 0x08022388, reached from 0x0802232A, 0x08022342
    ldr     r0, [r4, #8]                    @ 08022388 r0 = u32 [r4+0x8]
    adds    r0, r5, r0                      @ 0802238A r0 = r5 + r0
    str     r0, [r4, #8]                    @ 0802238C u32 [r4+0x8] = r0
    lsls    r0, r5, #0x17                   @ 0802238E r0 = r5 << 0x17
    beq     .Lfat_f_lseek_23B2              @ 08022390 if (r0 == 0) goto 0x80223B2
    movs    r1, r7                          @ 08022392 r1 = r7
    ldr     r0, [r4]                        @ 08022394 r0 = u32 [r4]
    bl      fat_clust2sect                  @ 08022396 call fat_clust2sect
    mov     r9, r0                          @ 0802239A r9 = r0
    cmp.w   r9, #0                          @ 0802239C compare r9 with 0
    bne     .Lfat_f_lseek_23AE              @ 080223A0 if (r9 != 0) goto 0x80223AE
    ldrb    r0, [r4, #6]                    @ 080223A2 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 080223A4 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 080223A8 u8 [r4+0x6] = r0
    movs    r0, #2                          @ 080223AA r0 = 2
    b       .Lfat_f_lseek_2428              @ 080223AC goto 0x8022428
.Lfat_f_lseek_23AE:                     @ v2.05 0x080223AE, reached from 0x080223A0
    adds.w  r9, r9, r5, lsr #9              @ 080223AE r9 = r9 + r5, lsr #9
    @ the target is inside a sector: write a dirty buffer (disk_write at 23D0) and read the target sector (disk_read at 23F8); skipped when it is the buffer sector already
.Lfat_f_lseek_23B2:                     @ v2.05 0x080223B2, reached from 0x080222AE, 0x08022326, 0x08022390
    ldr     r0, [r4, #8]                    @ 080223B2 r0 = u32 [r4+0x8]
    lsls    r0, r0, #0x17                   @ 080223B4 r0 = r0 << 0x17
    beq     .Lfat_f_lseek_2410              @ 080223B6 if (r0 == 0) goto 0x8022410
    ldr     r0, [r4, #0x18]                 @ 080223B8 r0 = u32 [r4+0x18]
    cmp     r9, r0                          @ 080223BA compare r9 with r0
    beq     .Lfat_f_lseek_2410              @ 080223BC if (r9 == r0) goto 0x8022410
    ldrb    r0, [r4, #6]                    @ 080223BE r0 = u8 [r4+0x6]
    lsls    r0, r0, #0x19                   @ 080223C0 r0 = r0 << 0x19
    bpl     .Lfat_f_lseek_23EC              @ 080223C2 if (r0 >=0 0) goto 0x80223EC
    movs    r3, #1                          @ 080223C4 r3 = 1
    ldr     r2, [r4, #0x18]                 @ 080223C6 r2 = u32 [r4+0x18]
    adds.w  r1, r4, #0x24                   @ 080223C8 r1 = r4 + 0x24
    ldr     r0, [r4]                        @ 080223CC r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 080223CE r0 = u8 [r0+0x1]
    bl      disk_write                      @ 080223D0 call disk_write
    cmp     r0, #0                          @ 080223D4 compare r0 with 0
    beq     .Lfat_f_lseek_23E4              @ 080223D6 if (r0 == 0) goto 0x80223E4
    ldrb    r0, [r4, #6]                    @ 080223D8 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 080223DA r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 080223DE u8 [r4+0x6] = r0
    movs    r0, #1                          @ 080223E0 r0 = 1
    b       .Lfat_f_lseek_2428              @ 080223E2 goto 0x8022428
.Lfat_f_lseek_23E4:                     @ v2.05 0x080223E4, reached from 0x080223D6
    ldrb    r0, [r4, #6]                    @ 080223E4 r0 = u8 [r4+0x6]
    ands    r0, r0, #0xbf                   @ 080223E6 r0 = r0 & 0xbf
    strb    r0, [r4, #6]                    @ 080223EA u8 [r4+0x6] = r0
.Lfat_f_lseek_23EC:                     @ v2.05 0x080223EC, reached from 0x080223C2
    movs    r3, #1                          @ 080223EC r3 = 1
    mov     r2, r9                          @ 080223EE r2 = r9
    adds.w  r1, r4, #0x24                   @ 080223F0 r1 = r4 + 0x24
    ldr     r0, [r4]                        @ 080223F4 r0 = u32 [r4]
    ldrb    r0, [r0, #1]                    @ 080223F6 r0 = u8 [r0+0x1]
    bl      disk_read                       @ 080223F8 call disk_read
    cmp     r0, #0                          @ 080223FC compare r0 with 0
    beq     .Lfat_f_lseek_240C              @ 080223FE if (r0 == 0) goto 0x802240C
    ldrb    r0, [r4, #6]                    @ 08022400 r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x80                   @ 08022402 r0 = r0 | 0x80
    strb    r0, [r4, #6]                    @ 08022406 u8 [r4+0x6] = r0
    movs    r0, #1                          @ 08022408 r0 = 1
    b       .Lfat_f_lseek_2428              @ 0802240A goto 0x8022428
.Lfat_f_lseek_240C:                     @ v2.05 0x0802240C, reached from 0x080223FE
    str.w   r9, [r4, #0x18]                 @ 0802240C u32 [r4+0x18] = r9
.Lfat_f_lseek_2410:                     @ v2.05 0x08022410, reached from 0x080223B6, 0x080223BC
    ldr     r0, [r4, #0xc]                  @ 08022410 r0 = u32 [r4+0xC]
    ldr     r1, [r4, #8]                    @ 08022412 r1 = u32 [r4+0x8]
    @ pointer beyond the size: size = pointer, flag 0x20
    cmp     r0, r1                          @ 08022414 compare r0 with r1
    bhs     .Lfat_f_lseek_2424              @ 08022416 if (r0 >=u r1) goto 0x8022424
    ldr     r0, [r4, #8]                    @ 08022418 r0 = u32 [r4+0x8]
    str     r0, [r4, #0xc]                  @ 0802241A u32 [r4+0xC] = r0
    ldrb    r0, [r4, #6]                    @ 0802241C r0 = u8 [r4+0x6]
    orrs    r0, r0, #0x20                   @ 0802241E r0 = r0 | 0x20
    strb    r0, [r4, #6]                    @ 08022422 u8 [r4+0x6] = r0
.Lfat_f_lseek_2424:                     @ v2.05 0x08022424, reached from 0x08022416
    movs    r0, r6                          @ 08022424 r0 = r6
    uxtb    r0, r0                          @ 08022426 r0 = u8(r0)
.Lfat_f_lseek_2428:                     @ v2.05 0x08022428, reached from 0x08022284, 0x0802228E, 0x0802230C, 0x0802231E, 0x0802235E, 0x08022376, 0x080223AC, 0x080223E2, 0x0802240A
    pop.w   {r4, r5, r6, r7, r8, r9, r10, pc}@ 08022428 pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC fat_f_lseek
    .global fn_08022268
    .thumb_set fn_08022268, fat_f_lseek
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_opendir - open a directory (FatFs f_opendir)
@ Replaces  : 0x0802242C FUN_0802242C (v2.05), canonical symbol fn_0802242C
@ In        : r0 = DIR pointer, r1 = path
@ Out       : r0 = FRESULT (0 ok, 5 no path when the name is not a directory)
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802242C..0x080224B5
@ -----------------------------------------------------------------------------
FUNC fat_f_opendir
    push    {r1, r4, r5, lr}                @ 0802242C push {r1, r4, r5, lr}
    sub     sp, #0x10                       @ 0802242E sp -= 0x10
    movs    r4, r0                          @ 08022430 r4 = r0
    movs    r2, #0                          @ 08022432 r2 = 0
    movs    r1, r4                          @ 08022434 r1 = r4
    add     r0, sp, #0x10                   @ 08022436 r0 = sp + 0x10
    @ chk_mounted(path, &fs, read access)
    bl      fat_chk_mounted                 @ 08022438 call fat_chk_mounted
    movs    r5, r0                          @ 0802243C r5 = r0
    uxtb    r5, r5                          @ 0802243E r5 = u8(r5)
    cmp     r5, #0                          @ 08022440 compare r5 with 0
    bne     .Lfat_f_opendir_24AE            @ 08022442 if (r5 != 0) goto 0x80224AE
    mov     r0, sp                          @ 08022444 r0 = sp
    str     r0, [r4, #0x18]                 @ 08022446 u32 [r4+0x18] = r0
    ldr     r1, [sp, #0x10]                 @ 08022448 r1 = u32 [sp+0x10]
    movs    r0, r4                          @ 0802244A r0 = r4
    @ follow_path; a non-NULL entry must be a directory (attribute bit 4), else error 5; its start cluster becomes DIR +8
    bl      fat_follow_path                 @ 0802244C call fat_follow_path
    movs    r5, r0                          @ 08022450 r5 = r0
    uxtb    r5, r5                          @ 08022452 r5 = u8(r5)
    cmp     r5, #0                          @ 08022454 compare r5 with 0
    bne     .Lfat_f_opendir_24A4            @ 08022456 if (r5 != 0) goto 0x80224A4
    ldr     r0, [r4, #0x14]                 @ 08022458 r0 = u32 [r4+0x14]
    cmp     r0, #0                          @ 0802245A compare r0 with 0
    beq     .Lfat_f_opendir_248E            @ 0802245C if (r0 == 0) goto 0x802248E
    ldr     r0, [r4, #0x14]                 @ 0802245E r0 = u32 [r4+0x14]
    ldrb    r0, [r0, #0xb]                  @ 08022460 r0 = u8 [r0+0xB]
    lsls    r0, r0, #0x1b                   @ 08022462 r0 = r0 << 0x1b
    bpl     .Lfat_f_opendir_248A            @ 08022464 if (r0 >=0 0) goto 0x802248A
    ldr     r0, [r4, #0x14]                 @ 08022466 r0 = u32 [r4+0x14]
    ldrb    r0, [r0, #0x15]                 @ 08022468 r0 = u8 [r0+0x15]
    ldr     r1, [r4, #0x14]                 @ 0802246A r1 = u32 [r4+0x14]
    ldrb    r1, [r1, #0x14]                 @ 0802246C r1 = u8 [r1+0x14]
    orrs.w  r0, r1, r0, lsl #8              @ 0802246E r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08022472 r0 = u16(r0)
    ldr     r1, [r4, #0x14]                 @ 08022474 r1 = u32 [r4+0x14]
    ldrb    r1, [r1, #0x1b]                 @ 08022476 r1 = u8 [r1+0x1B]
    ldr     r2, [r4, #0x14]                 @ 08022478 r2 = u32 [r4+0x14]
    ldrb    r2, [r2, #0x1a]                 @ 0802247A r2 = u8 [r2+0x1A]
    orrs.w  r1, r2, r1, lsl #8              @ 0802247C r1 = r2 | r1, lsl #8
    uxth    r1, r1                          @ 08022480 r1 = u16(r1)
    orrs.w  r0, r1, r0, lsl #16             @ 08022482 r0 = r1 | r0, lsl #16
    str     r0, [r4, #8]                    @ 08022486 u32 [r4+0x8] = r0
    b       .Lfat_f_opendir_248E            @ 08022488 goto 0x802248E
.Lfat_f_opendir_248A:                   @ v2.05 0x0802248A, reached from 0x08022464
    movs    r0, #5                          @ 0802248A r0 = 5
    movs    r5, r0                          @ 0802248C r5 = r0
.Lfat_f_opendir_248E:                   @ v2.05 0x0802248E, reached from 0x0802245C, 0x08022488
    uxtb    r5, r5                          @ 0802248E r5 = u8(r5)
    @ no error: DIR +4 = mount id and dir_sdi(dj, 0)
    cmp     r5, #0                          @ 08022490 compare r5 with 0
    bne     .Lfat_f_opendir_24A4            @ 08022492 if (r5 != 0) goto 0x80224A4
    ldr     r0, [r4]                        @ 08022494 r0 = u32 [r4]
    ldrh    r0, [r0, #6]                    @ 08022496 r0 = u16 [r0+0x6]
    strh    r0, [r4, #4]                    @ 08022498 u16 [r4+0x4] = r0
    movs    r1, #0                          @ 0802249A r1 = 0
    movs    r0, r4                          @ 0802249C r0 = r4
    bl      fat_dir_sdi                     @ 0802249E call fat_dir_sdi
    movs    r5, r0                          @ 080224A2 r5 = r0
.Lfat_f_opendir_24A4:                   @ v2.05 0x080224A4, reached from 0x08022456, 0x08022492
    uxtb    r5, r5                          @ 080224A4 r5 = u8(r5)
    @ error 4 (no file) is reported as 5 (no path)
    cmp     r5, #4                          @ 080224A6 compare r5 with 4
    bne     .Lfat_f_opendir_24AE            @ 080224A8 if (r5 != 4) goto 0x80224AE
    movs    r0, #5                          @ 080224AA r0 = 5
    movs    r5, r0                          @ 080224AC r5 = r0
.Lfat_f_opendir_24AE:                   @ v2.05 0x080224AE, reached from 0x08022442, 0x080224A8
    movs    r0, r5                          @ 080224AE r0 = r5
    uxtb    r0, r0                          @ 080224B0 r0 = u8(r0)
    add     sp, #0x14                       @ 080224B2 sp += 0x14
    pop     {r4, r5, pc}                    @ 080224B4 pop {r4, r5, pc}
ENDFUNC fat_f_opendir
    .global fn_0802242C
    .thumb_set fn_0802242C, fat_f_opendir
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_readdir - read the next entry of a directory (FatFs f_readdir)
@ Replaces  : 0x080224B6 FUN_080224B6 (v2.05), canonical symbol fn_080224B6
@ In        : r0 = DIR pointer (opened with f_opendir), r1 = FILINFO pointer, or 0 to rewind the directory
@ Out       : r0 = FRESULT; at the end of the directory the call succeeds and the first byte of the FILINFO name is 0
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080224B6..0x08022525
@ -----------------------------------------------------------------------------
FUNC fat_f_readdir
    push    {r4, r5, r6, lr}                @ 080224B6 push {r4, r5, r6, lr}
    sub     sp, #0x10                       @ 080224B8 sp -= 0x10
    movs    r4, r0                          @ 080224BA r4 = r0
    movs    r5, r1                          @ 080224BC r5 = r1
    ldrh    r1, [r4, #4]                    @ 080224BE r1 = u16 [r4+0x4]
    ldr     r0, [r4]                        @ 080224C0 r0 = u32 [r4]
    @ validate the object
    bl      fat_validate                    @ 080224C2 call fat_validate
    movs    r6, r0                          @ 080224C6 r6 = r0
    uxtb    r6, r6                          @ 080224C8 r6 = u8(r6)
    cmp     r6, #0                          @ 080224CA compare r6 with 0
    bne     .Lfat_f_readdir_251E            @ 080224CC if (r6 != 0) goto 0x802251E
    @ FILINFO pointer NULL: rewind (dir_sdi(0)); otherwise read the next entry
    cmp     r5, #0                          @ 080224CE compare r5 with 0
    bne     .Lfat_f_readdir_24DE            @ 080224D0 if (r5 != 0) goto 0x80224DE
    movs    r1, #0                          @ 080224D2 r1 = 0
    movs    r0, r4                          @ 080224D4 r0 = r4
    bl      fat_dir_sdi                     @ 080224D6 call fat_dir_sdi
    movs    r6, r0                          @ 080224DA r6 = r0
    b       .Lfat_f_readdir_251E            @ 080224DC goto 0x802251E
.Lfat_f_readdir_24DE:                   @ v2.05 0x080224DE, reached from 0x080224D0
    mov     r0, sp                          @ 080224DE r0 = sp
    str     r0, [r4, #0x18]                 @ 080224E0 u32 [r4+0x18] = r0
    movs    r0, r4                          @ 080224E2 r0 = r4
    @ dir_read; the end of the directory (4) is not an error: DIR +0x10 = 0, FILINFO name empty
    bl      fat_dir_read                    @ 080224E4 call fat_dir_read
    movs    r6, r0                          @ 080224E8 r6 = r0
    uxtb    r6, r6                          @ 080224EA r6 = u8(r6)
    cmp     r6, #4                          @ 080224EC compare r6 with 4
    bne     .Lfat_f_readdir_24F8            @ 080224EE if (r6 != 4) goto 0x80224F8
    movs    r0, #0                          @ 080224F0 r0 = 0
    str     r0, [r4, #0x10]                 @ 080224F2 u32 [r4+0x10] = r0
    movs    r0, #0                          @ 080224F4 r0 = 0
    movs    r6, r0                          @ 080224F6 r6 = r0
.Lfat_f_readdir_24F8:                   @ v2.05 0x080224F8, reached from 0x080224EE
    uxtb    r6, r6                          @ 080224F8 r6 = u8(r6)
    @ entry read: fill the FILINFO (get_fileinfo), advance with dir_next(0); 4 again is the end, not an error
    cmp     r6, #0                          @ 080224FA compare r6 with 0
    bne     .Lfat_f_readdir_251E            @ 080224FC if (r6 != 0) goto 0x802251E
    movs    r1, r5                          @ 080224FE r1 = r5
    movs    r0, r4                          @ 08022500 r0 = r4
    bl      fat_get_fileinfo                @ 08022502 call fat_get_fileinfo
    movs    r1, #0                          @ 08022506 r1 = 0
    movs    r0, r4                          @ 08022508 r0 = r4
    bl      fat_dir_next                    @ 0802250A call fat_dir_next
    movs    r6, r0                          @ 0802250E r6 = r0
    uxtb    r6, r6                          @ 08022510 r6 = u8(r6)
    cmp     r6, #4                          @ 08022512 compare r6 with 4
    bne     .Lfat_f_readdir_251E            @ 08022514 if (r6 != 4) goto 0x802251E
    movs    r0, #0                          @ 08022516 r0 = 0
    str     r0, [r4, #0x10]                 @ 08022518 u32 [r4+0x10] = r0
    movs    r0, #0                          @ 0802251A r0 = 0
    movs    r6, r0                          @ 0802251C r6 = r0
.Lfat_f_readdir_251E:                   @ v2.05 0x0802251E, reached from 0x080224CC, 0x080224DC, 0x080224FC, 0x08022514
    movs    r0, r6                          @ 0802251E r0 = r6
    uxtb    r0, r0                          @ 08022520 r0 = u8(r0)
    add     sp, #0x10                       @ 08022522 sp += 0x10
    pop     {r4, r5, r6, pc}                @ 08022524 pop {r4, r5, r6, pc}
ENDFUNC fat_f_readdir
    .global fn_080224B6
    .thumb_set fn_080224B6, fat_f_readdir
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_stat - get the information of a file or directory by its path (FatFs f_stat)
@ Replaces  : 0x08022526 FUN_08022526 (v2.05), canonical symbol fn_08022526
@ In        : r0 = path, r1 = FILINFO pointer
@ Out       : r0 = FRESULT (4 no file, 5 no path, 6 invalid name, e.g. for the root)
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08022526..0x0802256D
@ -----------------------------------------------------------------------------
FUNC fat_f_stat
    push    {r0, r4, r5, lr}                @ 08022526 push {r0, r4, r5, lr}
    sub     sp, #0x28                       @ 08022528 sp -= 0x28
    movs    r4, r1                          @ 0802252A r4 = r1
    movs    r2, #0                          @ 0802252C r2 = 0
    add     r1, sp, #0xc                    @ 0802252E r1 = sp + 0xc
    add     r0, sp, #0x28                   @ 08022530 r0 = sp + 0x28
    @ chk_mounted(path, &fs, read access)
    bl      fat_chk_mounted                 @ 08022532 call fat_chk_mounted
    movs    r5, r0                          @ 08022536 r5 = r0
    uxtb    r5, r5                          @ 08022538 r5 = u8(r5)
    cmp     r5, #0                          @ 0802253A compare r5 with 0
    bne     .Lfat_f_stat_2566               @ 0802253C if (r5 != 0) goto 0x8022566
    mov     r0, sp                          @ 0802253E r0 = sp
    str     r0, [sp, #0x24]                 @ 08022540 u32 [sp+0x24] = r0
    ldr     r1, [sp, #0x28]                 @ 08022542 r1 = u32 [sp+0x28]
    add     r0, sp, #0xc                    @ 08022544 r0 = sp + 0xc
    @ follow_path; a path without an entry (the root) gives invalid name (6)
    bl      fat_follow_path                 @ 08022546 call fat_follow_path
    movs    r5, r0                          @ 0802254A r5 = r0
    uxtb    r5, r5                          @ 0802254C r5 = u8(r5)
    cmp     r5, #0                          @ 0802254E compare r5 with 0
    bne     .Lfat_f_stat_2566               @ 08022550 if (r5 != 0) goto 0x8022566
    ldr     r0, [sp, #0x20]                 @ 08022552 r0 = u32 [sp+0x20]
    cmp     r0, #0                          @ 08022554 compare r0 with 0
    beq     .Lfat_f_stat_2562               @ 08022556 if (r0 == 0) goto 0x8022562
    movs    r1, r4                          @ 08022558 r1 = r4
    add     r0, sp, #0xc                    @ 0802255A r0 = sp + 0xc
    @ get_fileinfo fills the FILINFO
    bl      fat_get_fileinfo                @ 0802255C call fat_get_fileinfo
    b       .Lfat_f_stat_2566               @ 08022560 goto 0x8022566
.Lfat_f_stat_2562:                      @ v2.05 0x08022562, reached from 0x08022556
    movs    r0, #6                          @ 08022562 r0 = 6
    movs    r5, r0                          @ 08022564 r5 = r0
.Lfat_f_stat_2566:                      @ v2.05 0x08022566, reached from 0x0802253C, 0x08022550, 0x08022560
    movs    r0, r5                          @ 08022566 r0 = r5
    uxtb    r0, r0                          @ 08022568 r0 = u8(r0)
    add     sp, #0x2c                       @ 0802256A sp += 0x2c
    pop     {r4, r5, pc}                    @ 0802256C pop {r4, r5, pc}
ENDFUNC fat_f_stat
    .global fn_08022526
    .thumb_set fn_08022526, fat_f_stat
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_f_utime - set the modification date and time of a file or directory (FatFs f_utime)
@ Replaces  : 0x0802256E FUN_0802256E (v2.05), canonical symbol fn_0802256E
@ In        : r0 = path, r1 = FILINFO pointer whose date (+4) and time (+6) are written
@ Out       : r0 = FRESULT (4 no file, 5 no path, 6 invalid name, 10 write protected, ...)
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802256E..0x080225D5
@ Note      : log_set_file_time calls this with the RTC date and time and then f_stat to read them back.
@ -----------------------------------------------------------------------------
FUNC fat_f_utime
    push    {r0, r4, r5, r6, lr}            @ 0802256E push {r0, r4, r5, r6, lr}
    sub     sp, #0x2c                       @ 08022570 sp -= 0x2c
    movs    r4, r1                          @ 08022572 r4 = r1
    movs    r2, #1                          @ 08022574 r2 = 1
    mov     r1, sp                          @ 08022576 r1 = sp
    add     r0, sp, #0x2c                   @ 08022578 r0 = sp + 0x2c
    @ chk_mounted(path, &fs, write access)
    bl      fat_chk_mounted                 @ 0802257A call fat_chk_mounted
    movs    r5, r0                          @ 0802257E r5 = r0
    uxtb    r5, r5                          @ 08022580 r5 = u8(r5)
    cmp     r5, #0                          @ 08022582 compare r5 with 0
    bne     .Lfat_f_utime_25CE              @ 08022584 if (r5 != 0) goto 0x80225CE
    add     r0, sp, #0x1c                   @ 08022586 r0 = sp + 0x1c
    str     r0, [sp, #0x18]                 @ 08022588 u32 [sp+0x18] = r0
    ldr     r1, [sp, #0x2c]                 @ 0802258A r1 = u32 [sp+0x2C]
    mov     r0, sp                          @ 0802258C r0 = sp
    @ follow_path; no entry (the root): invalid name (6)
    bl      fat_follow_path                 @ 0802258E call fat_follow_path
    movs    r5, r0                          @ 08022592 r5 = r0
    uxtb    r5, r5                          @ 08022594 r5 = u8(r5)
    cmp     r5, #0                          @ 08022596 compare r5 with 0
    bne     .Lfat_f_utime_25CE              @ 08022598 if (r5 != 0) goto 0x80225CE
    ldr     r0, [sp, #0x14]                 @ 0802259A r0 = u32 [sp+0x14]
    movs    r6, r0                          @ 0802259C r6 = r0
    cmp     r6, #0                          @ 0802259E compare r6 with 0
    bne     .Lfat_f_utime_25A8              @ 080225A0 if (r6 != 0) goto 0x80225A8
    movs    r0, #6                          @ 080225A2 r0 = 6
    movs    r5, r0                          @ 080225A4 r5 = r0
    b       .Lfat_f_utime_25CE              @ 080225A6 goto 0x80225CE
    @ entry bytes 0x16/0x17 (time) and 0x18/0x19 (date) from FILINFO +6 and +4; window dirty; sync_fs (25C8)
.Lfat_f_utime_25A8:                     @ v2.05 0x080225A8, reached from 0x080225A0
    ldrh    r0, [r4, #6]                    @ 080225A8 r0 = u16 [r4+0x6]
    strb    r0, [r6, #0x16]                 @ 080225AA u8 [r6+0x16] = r0
    ldrh    r0, [r4, #6]                    @ 080225AC r0 = u16 [r4+0x6]
    uxth    r0, r0                          @ 080225AE r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 080225B0 r0 = r0 >> 8
    strb    r0, [r6, #0x17]                 @ 080225B2 u8 [r6+0x17] = r0
    ldrh    r0, [r4, #4]                    @ 080225B4 r0 = u16 [r4+0x4]
    strb    r0, [r6, #0x18]                 @ 080225B6 u8 [r6+0x18] = r0
    ldrh    r0, [r4, #4]                    @ 080225B8 r0 = u16 [r4+0x4]
    uxth    r0, r0                          @ 080225BA r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 080225BC r0 = r0 >> 8
    strb    r0, [r6, #0x19]                 @ 080225BE u8 [r6+0x19] = r0
    movs    r0, #1                          @ 080225C0 r0 = 1
    ldr     r1, [sp]                        @ 080225C2 r1 = u32 [sp]
    strb    r0, [r1, #4]                    @ 080225C4 u8 [r1+0x4] = r0
    ldr     r0, [sp]                        @ 080225C6 r0 = u32 [sp]
    bl      fat_sync_fs                     @ 080225C8 call fat_sync_fs
    movs    r5, r0                          @ 080225CC r5 = r0
.Lfat_f_utime_25CE:                     @ v2.05 0x080225CE, reached from 0x08022584, 0x08022598, 0x080225A6
    movs    r0, r5                          @ 080225CE r0 = r5
    uxtb    r0, r0                          @ 080225D0 r0 = u8(r0)
    add     sp, #0x30                       @ 080225D2 sp += 0x30
    pop     {r4, r5, r6, pc}                @ 080225D4 pop {r4, r5, r6, pc}
ENDFUNC fat_f_utime
    .global fn_0802256E
    .thumb_set fn_0802256E, fat_f_utime
    .ltorg

