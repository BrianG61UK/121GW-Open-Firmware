@ fat.s - SD module: FAT file system core - the sector window, the FAT, cluster chains (DESIGN.md 6.23, W8)
@
@ The v2.05 image carries a FatFs-equivalent library (0x08020B84..0x08022942): the function set, the object layouts and the
@ behaviour are those of the public FatFs API (f_mount, f_open, f_read, f_write, f_sync, f_close, f_lseek, f_opendir,
@ f_readdir, f_stat, f_utime) with one drive, 8.3 names, no long file names, no relative paths and a one-sector window.  The
@ names below are the FatFs names of the functions, used for orientation; the code is the v2.05 code.
@
@ Objects (offsets from the code):
@   FATFS (work area, 0x230 bytes)  +0 fs_type (0 = not mounted, 1 = FAT12, 2 = FAT16, 3 = FAT32)  +1 drive  +2 sectors per
@      cluster  +3 number of FATs  +4 window dirty  +5 FSInfo dirty  +6 mount id (u16)  +8 root directory entries (u16)
@      +0xC last allocated cluster  +0x10 free cluster count  +0x14 FSInfo sector  +0x18 number of clusters + 2  +0x1C
@      sectors per FAT  +0x20 FAT start sector  +0x24 root directory start (FAT32: root cluster)  +0x28 data area start
@      sector  +0x2C sector held in the window  +0x30 window (512 bytes)
@   FIL (0x224 bytes)  +0 fs  +4 mount id  +6 flags (0x01 read, 0x02 write, 0x20 changed, 0x40 buffer dirty, 0x80 error)
@      +8 file pointer  +0xC file size  +0x10 first cluster  +0x14 current cluster  +0x18 sector in the buffer
@      +0x1C directory sector  +0x20 directory entry pointer  +0x24 sector buffer (512 bytes)
@   DIR (0x1C bytes)  +0 fs  +4 mount id  +6 index (u16)  +8 start cluster  +0xC current cluster  +0x10 current sector
@      +0x14 pointer to the entry in the window  +0x18 pointer to the 11-byte 8.3 name
@   FILINFO  +0 size  +4 date  +6 time  +8 attribute  +9 name (13 bytes)
@ Return codes are the FatFs FRESULT: 0 ok, 1 disk error, 2 internal error, 3 not ready, 4 no file, 5 no path, 6 invalid name,
@ 7 denied, 8 exists, 9 invalid object, 10 write protected, 11 invalid drive, 12 not enabled, 13 no file system.
@
@ No function of this file touches the EEPROM, the flash or any peripheral except through disk_read / disk_write.
@

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    @ FatFs R0.08a of v2.05: strict image only; the production image uses FatFs R0.16 (src/ff16/, DESIGN.md 7A, IMP-29)
    .if LOOP_V205 == 1

    .section .text.sd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fat_mem_cpy - copy r2 bytes from r1 to r0 (FatFs mem_cpy)
@ Replaces  : 0x08020B84 FUN_08020B84 (v2.05)
@ In        : r0 = destination, r1 = source, r2 = byte count
@ Out       : -
@ Clobbers  : r2-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08020B84..0x08020B9F; byte loop, no overlap handling
@ -----------------------------------------------------------------------------
FUNC fat_mem_cpy
    push    {r4, r5}                        @ 08020B84 push {r4, r5}
    movs    r3, r0                          @ 08020B86 r3 = r0
    movs    r4, r1                          @ 08020B88 r4 = r1
.Lfat_mem_cpy_0B8A:                     @ v2.05 0x08020B8A, reached from 0x08020B9A
    movs    r5, r2                          @ 08020B8A r5 = r2
    subs    r2, r5, #1                      @ 08020B8C r2 = r5 - 1
    cmp     r5, #0                          @ 08020B8E compare r5 with 0
    beq     .Lfat_mem_cpy_0B9C              @ 08020B90 if (r5 == 0) goto 0x8020B9C
    ldrb    r5, [r4]                        @ 08020B92 r5 = u8 [r4]
    strb    r5, [r3]                        @ 08020B94 u8 [r3] = r5
    adds    r4, r4, #1                      @ 08020B96 r4 = r4 + 1
    adds    r3, r3, #1                      @ 08020B98 r3 = r3 + 1
    b       .Lfat_mem_cpy_0B8A              @ 08020B9A goto 0x8020B8A
.Lfat_mem_cpy_0B9C:                     @ v2.05 0x08020B9C, reached from 0x08020B90
    pop     {r4, r5}                        @ 08020B9C pop {r4, r5}
    bx      lr                              @ 08020B9E return
ENDFUNC fat_mem_cpy
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_mem_set - fill r2 bytes at r0 with the byte r1 (FatFs mem_set)
@ Replaces  : 0x08020BA0 FUN_08020BA0 (v2.05)
@ In        : r0 = destination, r1 = value, r2 = byte count
@ Out       : -
@ Clobbers  : r2-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08020BA0..0x08020BB5
@ -----------------------------------------------------------------------------
FUNC fat_mem_set
    push    {r4}                            @ 08020BA0 push {r4}
    movs    r3, r0                          @ 08020BA2 r3 = r0
.Lfat_mem_set_0BA4:                     @ v2.05 0x08020BA4, reached from 0x08020BB0
    movs    r4, r2                          @ 08020BA4 r4 = r2
    subs    r2, r4, #1                      @ 08020BA6 r2 = r4 - 1
    cmp     r4, #0                          @ 08020BA8 compare r4 with 0
    beq     .Lfat_mem_set_0BB2              @ 08020BAA if (r4 == 0) goto 0x8020BB2
    strb    r1, [r3]                        @ 08020BAC u8 [r3] = r1
    adds    r3, r3, #1                      @ 08020BAE r3 = r3 + 1
    b       .Lfat_mem_set_0BA4              @ 08020BB0 goto 0x8020BA4
.Lfat_mem_set_0BB2:                     @ v2.05 0x08020BB2, reached from 0x08020BAA
    pop     {r4}                            @ 08020BB2 pop {r4}
    bx      lr                              @ 08020BB4 return
ENDFUNC fat_mem_set
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_mem_cmp - compare r2 bytes at r0 and r1 (FatFs mem_cmp)
@ Replaces  : 0x08020BB6 FUN_08020BB6 (v2.05), called by fat_dir_find
@ In        : r0, r1 = the two areas, r2 = byte count
@ Out       : r0 = 0 when equal, else the difference of the first different bytes (area 1 - area 2)
@ Clobbers  : r0, r2-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08020BB6..0x08020BD9
@ -----------------------------------------------------------------------------
FUNC fat_mem_cmp
    push    {r4, r5, r6}                    @ 08020BB6 push {r4, r5, r6}
    movs    r3, r0                          @ 08020BB8 r3 = r0
    movs    r4, r3                          @ 08020BBA r4 = r3
    movs    r5, r1                          @ 08020BBC r5 = r1
    movs    r0, #0                          @ 08020BBE r0 = 0
.Lfat_mem_cmp_0BC0:                     @ v2.05 0x08020BC0, reached from 0x08020BD4
    movs    r6, r2                          @ 08020BC0 r6 = r2
    subs    r2, r6, #1                      @ 08020BC2 r2 = r6 - 1
    cmp     r6, #0                          @ 08020BC4 compare r6 with 0
    beq     .Lfat_mem_cmp_0BD6              @ 08020BC6 if (r6 == 0) goto 0x8020BD6
    ldrb    r0, [r4]                        @ 08020BC8 r0 = u8 [r4]
    ldrb    r6, [r5]                        @ 08020BCA r6 = u8 [r5]
    subs    r0, r0, r6                      @ 08020BCC r0 = r0 - r6
    adds    r5, r5, #1                      @ 08020BCE r5 = r5 + 1
    adds    r4, r4, #1                      @ 08020BD0 r4 = r4 + 1
    cmp     r0, #0                          @ 08020BD2 compare r0 with 0
    beq     .Lfat_mem_cmp_0BC0              @ 08020BD4 if (r0 == 0) goto 0x8020BC0
.Lfat_mem_cmp_0BD6:                     @ v2.05 0x08020BD6, reached from 0x08020BC6
    pop     {r4, r5, r6}                    @ 08020BD6 pop {r4, r5, r6}
    bx      lr                              @ 08020BD8 return
ENDFUNC fat_mem_cmp
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_chk_chr - look for the character r1 in the zero-terminated string r0 (FatFs chk_chr)
@ Replaces  : 0x08020BDA FUN_08020BDA (v2.05), called by fat_create_name
@ In        : r0 = string, r1 = character
@ Out       : r0 = the character when found, else 0 (the terminating NUL)
@ Clobbers  : r0, r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08020BDA..0x08020BED (the compiled loop is a tail-recursive jump to its own start)
@ -----------------------------------------------------------------------------
FUNC fat_chk_chr
.Lfat_chk_chr_0BDA:                     @ v2.05 0x08020BDA, reached from 0x08020BE8
    ldrb    r2, [r0]                        @ 08020BDA r2 = u8 [r0]
    cmp     r2, #0                          @ 08020BDC compare r2 with 0
    beq     .Lfat_chk_chr_0BEA              @ 08020BDE if (r2 == 0) goto 0x8020BEA
    ldrb    r2, [r0]                        @ 08020BE0 r2 = u8 [r0]
    cmp     r2, r1                          @ 08020BE2 compare r2 with r1
    beq     .Lfat_chk_chr_0BEA              @ 08020BE4 if (r2 == r1) goto 0x8020BEA
    adds    r0, r0, #1                      @ 08020BE6 r0 = r0 + 1
    b       .Lfat_chk_chr_0BDA              @ 08020BE8 goto 0x8020BDA
.Lfat_chk_chr_0BEA:                     @ v2.05 0x08020BEA, reached from 0x08020BDE, 0x08020BE4
    ldrb    r0, [r0]                        @ 08020BEA r0 = u8 [r0]
    bx      lr                              @ 08020BEC return
ENDFUNC fat_chk_chr
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_move_window - load sector r1 into the window of the file system r0, writing the dirty window first (FatFs move_window)
@ Replaces  : 0x08020BEE FUN_08020BEE (v2.05), called by the FAT, directory and file code
@ In        : r0 = FATFS pointer, r1 = sector number (0 = only flush)
@ Out       : r0 = 0 ok, 1 disk error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : FATFS winsect +0x2C, wflag +4, window +0x30
@ Spec      : v2.05 listing 0x08020BEE..0x08020C65
@ Note      : a dirty window (wflag) is written with disk_write to its sector; when that sector lies in the first FAT, the same
@             sector is also written to the other FAT copies at distance fsize (FATFS +0x1C), n_fats - 1 times.  The new sector is read
@             with disk_read.  A sector equal to the one already in the window does nothing.
@ -----------------------------------------------------------------------------
FUNC fat_move_window
    push    {r3, r4, r5, r6, r7, lr}        @ 08020BEE push {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 08020BF0 r4 = r0
    movs    r5, r1                          @ 08020BF2 r5 = r1
    @ r6 = sector in the window; nothing to do when it already is the wanted sector r5 (0BF8)
    ldr     r0, [r4, #0x2c]                 @ 08020BF4 r0 = u32 [r4+0x2C]
    movs    r6, r0                          @ 08020BF6 r6 = r0
    cmp     r6, r5                          @ 08020BF8 compare r6 with r5
    beq     .Lfat_move_window_0C62          @ 08020BFA if (r6 == r5) goto 0x8020C62
    @ dirty window (FATFS +4): write it back with disk_write; 1 on a disk error
    ldrb    r0, [r4, #4]                    @ 08020BFC r0 = u8 [r4+0x4]
    cmp     r0, #0                          @ 08020BFE compare r0 with 0
    beq     .Lfat_move_window_0C46          @ 08020C00 if (r0 == 0) goto 0x8020C46
    movs    r3, #1                          @ 08020C02 r3 = 1
    movs    r2, r6                          @ 08020C04 r2 = r6
    adds.w  r1, r4, #0x30                   @ 08020C06 r1 = r4 + 0x30
    ldrb    r0, [r4, #1]                    @ 08020C0A r0 = u8 [r4+0x1]
    bl      disk_write                      @ 08020C0C call disk_write
    cmp     r0, #0                          @ 08020C10 compare r0 with 0
    beq     .Lfat_move_window_0C18          @ 08020C12 if (r0 == 0) goto 0x8020C18
    movs    r0, #1                          @ 08020C14 r0 = 1
    b       .Lfat_move_window_0C64          @ 08020C16 goto 0x8020C64
.Lfat_move_window_0C18:                 @ v2.05 0x08020C18, reached from 0x08020C12
    movs    r0, #0                          @ 08020C18 r0 = 0
    strb    r0, [r4, #4]                    @ 08020C1A u8 [r4+0x4] = r0
    @ a sector of the first FAT is also written to the other FAT copies at distance FATFS +0x1C (0C26..0C44)
    ldr     r0, [r4, #0x20]                 @ 08020C1C r0 = u32 [r4+0x20]
    ldr     r1, [r4, #0x1c]                 @ 08020C1E r1 = u32 [r4+0x1C]
    adds    r0, r1, r0                      @ 08020C20 r0 = r1 + r0
    cmp     r6, r0                          @ 08020C22 compare r6 with r0
    bhs     .Lfat_move_window_0C46          @ 08020C24 if (r6 >=u r0) goto 0x8020C46
    ldrb    r0, [r4, #3]                    @ 08020C26 r0 = u8 [r4+0x3]
    movs    r7, r0                          @ 08020C28 r7 = r0
.Lfat_move_window_0C2A:                 @ v2.05 0x08020C2A, reached from 0x08020C44
    uxtb    r7, r7                          @ 08020C2A r7 = u8(r7)
    cmp     r7, #2                          @ 08020C2C compare r7 with 2
    blt     .Lfat_move_window_0C46          @ 08020C2E if (r7 < 2) goto 0x8020C46
    ldr     r0, [r4, #0x1c]                 @ 08020C30 r0 = u32 [r4+0x1C]
    adds    r6, r0, r6                      @ 08020C32 r6 = r0 + r6
    movs    r3, #1                          @ 08020C34 r3 = 1
    movs    r2, r6                          @ 08020C36 r2 = r6
    adds.w  r1, r4, #0x30                   @ 08020C38 r1 = r4 + 0x30
    ldrb    r0, [r4, #1]                    @ 08020C3C r0 = u8 [r4+0x1]
    bl      disk_write                      @ 08020C3E call disk_write
    subs    r7, r7, #1                      @ 08020C42 r7 = r7 - 1
    b       .Lfat_move_window_0C2A          @ 08020C44 goto 0x8020C2A
    @ r5 != 0: read the wanted sector into the window (disk_read); remember it in FATFS +0x2C
.Lfat_move_window_0C46:                 @ v2.05 0x08020C46, reached from 0x08020C00, 0x08020C24, 0x08020C2E
    cmp     r5, #0                          @ 08020C46 compare r5 with 0
    beq     .Lfat_move_window_0C62          @ 08020C48 if (r5 == 0) goto 0x8020C62
    movs    r3, #1                          @ 08020C4A r3 = 1
    movs    r2, r5                          @ 08020C4C r2 = r5
    adds.w  r1, r4, #0x30                   @ 08020C4E r1 = r4 + 0x30
    ldrb    r0, [r4, #1]                    @ 08020C52 r0 = u8 [r4+0x1]
    bl      disk_read                       @ 08020C54 call disk_read
    cmp     r0, #0                          @ 08020C58 compare r0 with 0
    beq     .Lfat_move_window_0C60          @ 08020C5A if (r0 == 0) goto 0x8020C60
    movs    r0, #-1
    str     r0, [r4, #0x2c]                 @ OF-64: window invalid (0xFFFFFFFF, no sector of a FAT32 volume has that number):
                                            @ the read may have overwritten part of it, so the old sector number must not
                                            @ match again (FatFs R0.10c move_window; v2.05 keeps the old number, 0x08020C5C)
    movs    r0, #1                          @ 08020C5C r0 = 1
    b       .Lfat_move_window_0C64          @ 08020C5E goto 0x8020C64
.Lfat_move_window_0C60:                 @ v2.05 0x08020C60, reached from 0x08020C5A
    str     r5, [r4, #0x2c]                 @ 08020C60 u32 [r4+0x2C] = r5
.Lfat_move_window_0C62:                 @ v2.05 0x08020C62, reached from 0x08020BFA, 0x08020C48
    movs    r0, #0                          @ 08020C62 r0 = 0
.Lfat_move_window_0C64:                 @ v2.05 0x08020C64, reached from 0x08020C16, 0x08020C5E
    pop     {r1, r4, r5, r6, r7, pc}        @ 08020C64 pop {r1, r4, r5, r6, r7, pc}
ENDFUNC fat_move_window
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_sync_fs - flush the window and the FSInfo sector, then complete outstanding disk writes (FatFs sync)
@ Replaces  : 0x08020C66 FUN_08020C66 (v2.05), called by fat_f_sync and fat_f_utime
@ In        : r0 = FATFS pointer
@ Out       : r0 = 0 ok, 1 error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08020C66..0x08020D3D
@ Note      : for FAT32 with the FSInfo flag set, the FSInfo sector is rebuilt in the window (signatures 0x41615252 at offset 0
@             and 0x61417272 at 0x1E4, free cluster count at 0x1E8, last allocated cluster at 0x1EC, 0xAA55 at 0x1FE) and written;
@             afterwards disk_ioctl(CTRL_SYNC) is called (it always succeeds here).
@ -----------------------------------------------------------------------------
FUNC fat_sync_fs
    push    {r3, r4, r5, lr}                @ 08020C66 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 08020C68 r4 = r0
    @ flush the window (move_window(0))
    movs    r1, #0                          @ 08020C6A r1 = 0
    movs    r0, r4                          @ 08020C6C r0 = r4
    bl      fat_move_window                 @ 08020C6E call fat_move_window
    movs    r5, r0                          @ 08020C72 r5 = r0
    uxtb    r5, r5                          @ 08020C74 r5 = u8(r5)
    cmp     r5, #0                          @ 08020C76 compare r5 with 0
    bne     .Lfat_sync_fs_0D38              @ 08020C78 if (r5 != 0) goto 0x8020D38
    @ FAT32 with the FSInfo flag (FATFS +5): rebuild the FSInfo sector in the window
    ldrb    r0, [r4]                        @ 08020C7A r0 = u8 [r4]
    cmp     r0, #3                          @ 08020C7C compare r0 with 3
    bne     .Lfat_sync_fs_0D26              @ 08020C7E if (r0 != 3) goto 0x8020D26
    ldrb    r0, [r4, #5]                    @ 08020C80 r0 = u8 [r4+0x5]
    cmp     r0, #0                          @ 08020C82 compare r0 with 0
    beq     .Lfat_sync_fs_0D26              @ 08020C84 if (r0 == 0) goto 0x8020D26
    movs    r0, #0                          @ 08020C86 r0 = 0
    str     r0, [r4, #0x2c]                 @ 08020C88 u32 [r4+0x2C] = r0
    mov.w   r2, #0x200                      @ 08020C8A r2 = 0x200
    movs    r1, #0                          @ 08020C8E r1 = 0
    adds.w  r0, r4, #0x30                   @ 08020C90 r0 = r4 + 0x30
    bl      fat_mem_set                     @ 08020C94 call fat_mem_set
    @ signature 0xAA55 at window offset 0x1FE, "RRaA" at 0, "rrAa" at 0x1E4
    movs    r0, #0x55                       @ 08020C98 r0 = 0x55
    strb.w  r0, [r4, #0x22e]                @ 08020C9A u8 [r4+0x22E] = r0
    movs    r0, #0xaa                       @ 08020C9E r0 = 0xaa
    strb.w  r0, [r4, #0x22f]                @ 08020CA0 u8 [r4+0x22F] = r0
    movs    r0, #0x52                       @ 08020CA4 r0 = 0x52
    strb.w  r0, [r4, #0x30]                 @ 08020CA6 u8 [r4+0x30] = r0
    movs    r0, #0x52                       @ 08020CAA r0 = 0x52
    strb.w  r0, [r4, #0x31]                 @ 08020CAC u8 [r4+0x31] = r0
    movs    r0, #0x61                       @ 08020CB0 r0 = 0x61
    strb.w  r0, [r4, #0x32]                 @ 08020CB2 u8 [r4+0x32] = r0
    movs    r0, #0x41                       @ 08020CB6 r0 = 0x41
    strb.w  r0, [r4, #0x33]                 @ 08020CB8 u8 [r4+0x33] = r0
    movs    r0, #0x72                       @ 08020CBC r0 = 0x72
    strb.w  r0, [r4, #0x214]                @ 08020CBE u8 [r4+0x214] = r0
    movs    r0, #0x72                       @ 08020CC2 r0 = 0x72
    strb.w  r0, [r4, #0x215]                @ 08020CC4 u8 [r4+0x215] = r0
    movs    r0, #0x41                       @ 08020CC8 r0 = 0x41
    strb.w  r0, [r4, #0x216]                @ 08020CCA u8 [r4+0x216] = r0
    movs    r0, #0x61                       @ 08020CCE r0 = 0x61
    strb.w  r0, [r4, #0x217]                @ 08020CD0 u8 [r4+0x217] = r0
    @ free cluster count (FATFS +0x10) at 0x1E8, last allocated cluster (FATFS +0xC) at 0x1EC
    ldr     r0, [r4, #0x10]                 @ 08020CD4 r0 = u32 [r4+0x10]
    strb.w  r0, [r4, #0x218]                @ 08020CD6 u8 [r4+0x218] = r0
    ldr     r0, [r4, #0x10]                 @ 08020CDA r0 = u32 [r4+0x10]
    uxth    r0, r0                          @ 08020CDC r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 08020CDE r0 = r0 >> 8
    strb.w  r0, [r4, #0x219]                @ 08020CE0 u8 [r4+0x219] = r0
    ldr     r0, [r4, #0x10]                 @ 08020CE4 r0 = u32 [r4+0x10]
    lsrs    r0, r0, #0x10                   @ 08020CE6 r0 = r0 >> 0x10
    strb.w  r0, [r4, #0x21a]                @ 08020CE8 u8 [r4+0x21A] = r0
    ldr     r0, [r4, #0x10]                 @ 08020CEC r0 = u32 [r4+0x10]
    lsrs    r0, r0, #0x18                   @ 08020CEE r0 = r0 >> 0x18
    strb.w  r0, [r4, #0x21b]                @ 08020CF0 u8 [r4+0x21B] = r0
    ldr     r0, [r4, #0xc]                  @ 08020CF4 r0 = u32 [r4+0xC]
    strb.w  r0, [r4, #0x21c]                @ 08020CF6 u8 [r4+0x21C] = r0
    ldr     r0, [r4, #0xc]                  @ 08020CFA r0 = u32 [r4+0xC]
    uxth    r0, r0                          @ 08020CFC r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 08020CFE r0 = r0 >> 8
    strb.w  r0, [r4, #0x21d]                @ 08020D00 u8 [r4+0x21D] = r0
    ldr     r0, [r4, #0xc]                  @ 08020D04 r0 = u32 [r4+0xC]
    lsrs    r0, r0, #0x10                   @ 08020D06 r0 = r0 >> 0x10
    strb.w  r0, [r4, #0x21e]                @ 08020D08 u8 [r4+0x21E] = r0
    ldr     r0, [r4, #0xc]                  @ 08020D0C r0 = u32 [r4+0xC]
    lsrs    r0, r0, #0x18                   @ 08020D0E r0 = r0 >> 0x18
    strb.w  r0, [r4, #0x21f]                @ 08020D10 u8 [r4+0x21F] = r0
    @ write the FSInfo sector (FATFS +0x14) and clear the flag
    movs    r3, #1                          @ 08020D14 r3 = 1
    ldr     r2, [r4, #0x14]                 @ 08020D16 r2 = u32 [r4+0x14]
    adds.w  r1, r4, #0x30                   @ 08020D18 r1 = r4 + 0x30
    ldrb    r0, [r4, #1]                    @ 08020D1C r0 = u8 [r4+0x1]
    bl      disk_write                      @ 08020D1E call disk_write
    movs    r0, #0                          @ 08020D22 r0 = 0
    strb    r0, [r4, #5]                    @ 08020D24 u8 [r4+0x5] = r0
    @ disk_ioctl(CTRL_SYNC); a failure gives 1
.Lfat_sync_fs_0D26:                     @ v2.05 0x08020D26, reached from 0x08020C7E, 0x08020C84
    movs    r2, #0                          @ 08020D26 r2 = 0
    movs    r1, #0                          @ 08020D28 r1 = 0
    ldrb    r0, [r4, #1]                    @ 08020D2A r0 = u8 [r4+0x1]
    bl      disk_ioctl                      @ 08020D2C call disk_ioctl
    cmp     r0, #0                          @ 08020D30 compare r0 with 0
    beq     .Lfat_sync_fs_0D38              @ 08020D32 if (r0 == 0) goto 0x8020D38
    movs    r0, #1                          @ 08020D34 r0 = 1
    movs    r5, r0                          @ 08020D36 r5 = r0
.Lfat_sync_fs_0D38:                     @ v2.05 0x08020D38, reached from 0x08020C78, 0x08020D32
    movs    r0, r5                          @ 08020D38 r0 = r5
    uxtb    r0, r0                          @ 08020D3A r0 = u8(r0)
    pop     {r1, r4, r5, pc}                @ 08020D3C pop {r1, r4, r5, pc}
ENDFUNC fat_sync_fs
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_clust2sect - first sector of cluster r1 (FatFs clust2sect)
@ Replaces  : 0x08020D3E FUN_08020D3E (v2.05)
@ In        : r0 = FATFS pointer, r1 = cluster number
@ Out       : r0 = (cluster - 2) * sectors per cluster + data start, or 0 when the cluster number is below 2 or beyond the last cluster
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08020D3E..0x08020D57
@ -----------------------------------------------------------------------------
FUNC fat_clust2sect
    movs    r2, r0                          @ 08020D3E r2 = r0
    subs    r1, r1, #2                      @ 08020D40 r1 = r1 - 2
    ldr     r0, [r2, #0x18]                 @ 08020D42 r0 = u32 [r2+0x18]
    subs    r0, r0, #2                      @ 08020D44 r0 = r0 - 2
    cmp     r1, r0                          @ 08020D46 compare r1 with r0
    blo     .Lfat_clust2sect_0D4E           @ 08020D48 if (r1 <u r0) goto 0x8020D4E
    movs    r0, #0                          @ 08020D4A r0 = 0
    b       .Lfat_clust2sect_0D56           @ 08020D4C goto 0x8020D56
.Lfat_clust2sect_0D4E:                  @ v2.05 0x08020D4E, reached from 0x08020D48
    ldrb    r0, [r2, #2]                    @ 08020D4E r0 = u8 [r2+0x2]
    ldr     r2, [r2, #0x28]                 @ 08020D50 r2 = u32 [r2+0x28]
    mla     r0, r0, r1, r2                  @ 08020D52
.Lfat_clust2sect_0D56:                  @ v2.05 0x08020D56, reached from 0x08020D4C
    bx      lr                              @ 08020D56 return
ENDFUNC fat_clust2sect
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_get_fat - value of FAT entry r1 (FatFs get_fat)
@ Replaces  : 0x08020D58 FUN_08020D58 (v2.05)
@ In        : r0 = FATFS pointer, r1 = cluster number
@ Out       : r0 = the FAT entry (FAT12 12 bits, FAT16 16 bits, FAT32 28 bits), 1 for an invalid cluster number, 0xFFFFFFFF for a disk error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08020D58..0x08020E39
@ -----------------------------------------------------------------------------
FUNC fat_get_fat
    push.w  {r4, r5, r6, r7, r8, lr}        @ 08020D58 push {r4, r5, r6, r7, r8, lr}
    movs    r4, r0                          @ 08020D5C r4 = r0
    movs    r5, r1                          @ 08020D5E r5 = r1
    @ cluster below 2 or not below FATFS +0x18: result 1
    cmp     r5, #2                          @ 08020D60 compare r5 with 2
    blo     .Lfat_get_fat_0D6A              @ 08020D62 if (r5 <u 2) goto 0x8020D6A
    ldr     r0, [r4, #0x18]                 @ 08020D64 r0 = u32 [r4+0x18]
    cmp     r5, r0                          @ 08020D66 compare r5 with r0
    blo     .Lfat_get_fat_0D6E              @ 08020D68 if (r5 <u r0) goto 0x8020D6E
.Lfat_get_fat_0D6A:                     @ v2.05 0x08020D6A, reached from 0x08020D62
    movs    r0, #1                          @ 08020D6A r0 = 1
    b       .Lfat_get_fat_0E36              @ 08020D6C goto 0x8020E36
    @ FAT type: 1 = FAT12, 3 = FAT32, 2 = FAT16 (other values and 0 fall to the error exit 0E32)
.Lfat_get_fat_0D6E:                     @ v2.05 0x08020D6E, reached from 0x08020D68
    ldrb    r0, [r4]                        @ 08020D6E r0 = u8 [r4]
    cmp     r0, #1                          @ 08020D70 compare r0 with 1
    beq     .Lfat_get_fat_0D7E              @ 08020D72 if (r0 == 1) goto 0x8020D7E
    blo     .Lfat_get_fat_0E32              @ 08020D74 if (r0 <u 1) goto 0x8020E32
    cmp     r0, #3                          @ 08020D76 compare r0 with 3
    beq     .Lfat_get_fat_0DFC              @ 08020D78 if (r0 == 3) goto 0x8020DFC
    blo     .Lfat_get_fat_0DD4              @ 08020D7A if (r0 <u 3) goto 0x8020DD4
    b       .Lfat_get_fat_0E32              @ 08020D7C goto 0x8020E32
    @ FAT12: byte offset = cluster * 3 / 2; the 12-bit entry may straddle two sectors (two move_window calls); odd clusters use the upper 12 bits (0DC6..0DD0)
.Lfat_get_fat_0D7E:                     @ v2.05 0x08020D7E, reached from 0x08020D72
    mov     r8, r5                          @ 08020D7E r8 = r5
    adds.w  r8, r8, r8, lsr #1              @ 08020D80 r8 = r8 + r8, lsr #1
    ldr     r0, [r4, #0x20]                 @ 08020D84 r0 = u32 [r4+0x20]
    adds.w  r1, r0, r8, lsr #9              @ 08020D86 r1 = r0 + r8, lsr #9
    movs    r0, r4                          @ 08020D8A r0 = r4
    bl      fat_move_window                 @ 08020D8C call fat_move_window
    cmp     r0, #0                          @ 08020D90 compare r0 with 0
    bne     .Lfat_get_fat_0E32              @ 08020D92 if (r0 != 0) goto 0x8020E32
    lsls.w  r0, r8, #0x17                   @ 08020D94 r0 = r8 << 0x17
    lsrs    r0, r0, #0x17                   @ 08020D98 r0 = r0 >> 0x17
    add     r0, r4                          @ 08020D9A r0 += r4
    ldrb.w  r0, [r0, #0x30]                 @ 08020D9C r0 = u8 [r0+0x30]
    movs    r6, r0                          @ 08020DA0 r6 = r0
    adds.w  r8, r8, #1                      @ 08020DA2 r8 = r8 + 1
    ldr     r0, [r4, #0x20]                 @ 08020DA6 r0 = u32 [r4+0x20]
    adds.w  r1, r0, r8, lsr #9              @ 08020DA8 r1 = r0 + r8, lsr #9
    movs    r0, r4                          @ 08020DAC r0 = r4
    bl      fat_move_window                 @ 08020DAE call fat_move_window
    cmp     r0, #0                          @ 08020DB2 compare r0 with 0
    bne     .Lfat_get_fat_0E32              @ 08020DB4 if (r0 != 0) goto 0x8020E32
    lsls.w  r0, r8, #0x17                   @ 08020DB6 r0 = r8 << 0x17
    lsrs    r0, r0, #0x17                   @ 08020DBA r0 = r0 >> 0x17
    add     r0, r4                          @ 08020DBC r0 += r4
    ldrb.w  r0, [r0, #0x30]                 @ 08020DBE r0 = u8 [r0+0x30]
    orrs.w  r6, r6, r0, lsl #8              @ 08020DC2 r6 = r6 | r0, lsl #8
    lsls    r0, r5, #0x1f                   @ 08020DC6 r0 = r5 << 0x1f
    bpl     .Lfat_get_fat_0DCE              @ 08020DC8 if (r0 >=0 0) goto 0x8020DCE
    lsrs    r0, r6, #4                      @ 08020DCA r0 = r6 >> 4
    b       .Lfat_get_fat_0DD2              @ 08020DCC goto 0x8020DD2
.Lfat_get_fat_0DCE:                     @ v2.05 0x08020DCE, reached from 0x08020DC8
    lsls    r0, r6, #0x14                   @ 08020DCE r0 = r6 << 0x14
    lsrs    r0, r0, #0x14                   @ 08020DD0 r0 = r0 >> 0x14
.Lfat_get_fat_0DD2:                     @ v2.05 0x08020DD2, reached from 0x08020DCC
    b       .Lfat_get_fat_0E36              @ 08020DD2 goto 0x8020E36
    @ FAT16: little-endian halfword at 2 * cluster
.Lfat_get_fat_0DD4:                     @ v2.05 0x08020DD4, reached from 0x08020D7A
    ldr     r0, [r4, #0x20]                 @ 08020DD4 r0 = u32 [r4+0x20]
    adds.w  r1, r0, r5, lsr #8              @ 08020DD6 r1 = r0 + r5, lsr #8
    movs    r0, r4                          @ 08020DDA r0 = r4
    bl      fat_move_window                 @ 08020DDC call fat_move_window
    cmp     r0, #0                          @ 08020DE0 compare r0 with 0
    bne     .Lfat_get_fat_0E32              @ 08020DE2 if (r0 != 0) goto 0x8020E32
    lsls    r0, r5, #1                      @ 08020DE4 r0 = r5 << 1
    lsls    r0, r0, #0x17                   @ 08020DE6 r0 = r0 << 0x17
    lsrs    r0, r0, #0x17                   @ 08020DE8 r0 = r0 >> 0x17
    add     r0, r4                          @ 08020DEA r0 += r4
    adds    r0, #0x30                       @ 08020DEC r0 += 0x30
    movs    r7, r0                          @ 08020DEE r7 = r0
    ldrb    r0, [r7, #1]                    @ 08020DF0 r0 = u8 [r7+0x1]
    ldrb    r1, [r7]                        @ 08020DF2 r1 = u8 [r7]
    orrs.w  r0, r1, r0, lsl #8              @ 08020DF4 r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08020DF8 r0 = u16(r0)
    b       .Lfat_get_fat_0E36              @ 08020DFA goto 0x8020E36
    @ FAT32: little-endian word at 4 * cluster, upper 4 bits masked (0E2C)
.Lfat_get_fat_0DFC:                     @ v2.05 0x08020DFC, reached from 0x08020D78
    ldr     r0, [r4, #0x20]                 @ 08020DFC r0 = u32 [r4+0x20]
    adds.w  r1, r0, r5, lsr #7              @ 08020DFE r1 = r0 + r5, lsr #7
    movs    r0, r4                          @ 08020E02 r0 = r4
    bl      fat_move_window                 @ 08020E04 call fat_move_window
    cmp     r0, #0                          @ 08020E08 compare r0 with 0
    bne     .Lfat_get_fat_0E32              @ 08020E0A if (r0 != 0) goto 0x8020E32
    lsls    r0, r5, #2                      @ 08020E0C r0 = r5 << 2
    lsls    r0, r0, #0x17                   @ 08020E0E r0 = r0 << 0x17
    lsrs    r0, r0, #0x17                   @ 08020E10 r0 = r0 >> 0x17
    add     r0, r4                          @ 08020E12 r0 += r4
    adds    r0, #0x30                       @ 08020E14 r0 += 0x30
    movs    r7, r0                          @ 08020E16 r7 = r0
    ldrb    r0, [r7, #3]                    @ 08020E18 r0 = u8 [r7+0x3]
    ldrb    r1, [r7, #2]                    @ 08020E1A r1 = u8 [r7+0x2]
    lsls    r1, r1, #0x10                   @ 08020E1C r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 08020E1E r0 = r1 | r0, lsl #24
    ldrb    r1, [r7, #1]                    @ 08020E22 r1 = u8 [r7+0x1]
    orrs.w  r0, r0, r1, lsl #8              @ 08020E24 r0 = r0 | r1, lsl #8
    ldrb    r1, [r7]                        @ 08020E28 r1 = u8 [r7]
    orrs    r0, r1                          @ 08020E2A r0 |= r1
    bic     r0, r0, #0xf0000000             @ 08020E2C r0 = r0 & ~ 0xf0000000
    b       .Lfat_get_fat_0E36              @ 08020E30 goto 0x8020E36
    @ disk error: 0xFFFFFFFF
.Lfat_get_fat_0E32:                     @ v2.05 0x08020E32, reached from 0x08020D74, 0x08020D7C, 0x08020D92, 0x08020DB4, 0x08020DE2, 0x08020E0A
    movs.w  r0, #-1                         @ 08020E32 r0 = -1
.Lfat_get_fat_0E36:                     @ v2.05 0x08020E36, reached from 0x08020D6C, 0x08020DD2, 0x08020DFA, 0x08020E30
    pop.w   {r4, r5, r6, r7, r8, pc}        @ 08020E36 pop {r4, r5, r6, r7, r8, pc}
ENDFUNC fat_get_fat
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_put_fat - set FAT entry r1 to r2 (FatFs put_fat)
@ Replaces  : 0x08020E3A FUN_08020E3A (v2.05)
@ In        : r0 = FATFS pointer, r1 = cluster number, r2 = new value
@ Out       : r0 = 0 ok, 1 disk error, 2 invalid cluster number or unmounted
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08020E3A..0x08020F7B
@ Note      : the window is marked dirty (FATFS +4) when the entry was written (OF-64; v2.05: on every exit path).  FAT32 keeps the
@             upper 4 bits of the old entry.
@ -----------------------------------------------------------------------------
FUNC fat_put_fat
    push.w  {r3, r4, r5, r6, r7, r8, r9, lr}@ 08020E3A push {r3, r4, r5, r6, r7, r8, r9, lr}
    movs    r4, r0                          @ 08020E3E r4 = r0
    movs    r5, r1                          @ 08020E40 r5 = r1
    movs    r6, r2                          @ 08020E42 r6 = r2
    @ cluster below 2 or not below FATFS +0x18: result 2
    cmp     r5, #2                          @ 08020E44 compare r5 with 2
    blo     .Lfat_put_fat_0E4E              @ 08020E46 if (r5 <u 2) goto 0x8020E4E
    ldr     r0, [r4, #0x18]                 @ 08020E48 r0 = u32 [r4+0x18]
    cmp     r5, r0                          @ 08020E4A compare r5 with r0
    blo     .Lfat_put_fat_0E54              @ 08020E4C if (r5 <u r0) goto 0x8020E54
.Lfat_put_fat_0E4E:                     @ v2.05 0x08020E4E, reached from 0x08020E46
    movs    r0, #2                          @ 08020E4E r0 = 2
    mov     r9, r0                          @ 08020E50 r9 = r0
    b       .Lfat_put_fat_0F74              @ 08020E52 goto 0x8020F74
    @ FAT type: 1 = FAT12, 3 = FAT32, 2 = FAT16; others: result 2 (0F6C)
.Lfat_put_fat_0E54:                     @ v2.05 0x08020E54, reached from 0x08020E4C
    ldrb    r0, [r4]                        @ 08020E54 r0 = u8 [r4]
    cmp     r0, #1                          @ 08020E56 compare r0 with 1
    beq     .Lfat_put_fat_0E66              @ 08020E58 if (r0 == 1) goto 0x8020E66
    blo.w   .Lfat_put_fat_0F6C              @ 08020E5A if (r0 <u 1) goto 0x8020F6C
    cmp     r0, #3                          @ 08020E5E compare r0 with 3
    beq     .Lfat_put_fat_0F20              @ 08020E60 if (r0 == 3) goto 0x8020F20
    blo     .Lfat_put_fat_0EEC              @ 08020E62 if (r0 <u 3) goto 0x8020EEC
    b       .Lfat_put_fat_0F6C              @ 08020E64 goto 0x8020F6C
    @ FAT12 (entry straddles two bytes): odd cluster: first byte = old low nibble | value << 4, next byte = value >> 4; even cluster: first byte = value, next byte = old high nibble | (value >> 8) & 0xF
.Lfat_put_fat_0E66:                     @ v2.05 0x08020E66, reached from 0x08020E58
    movs    r7, r5                          @ 08020E66 r7 = r5
    adds.w  r7, r7, r7, lsr #1              @ 08020E68 r7 = r7 + r7, lsr #1
    ldr     r0, [r4, #0x20]                 @ 08020E6C r0 = u32 [r4+0x20]
    adds.w  r1, r0, r7, lsr #9              @ 08020E6E r1 = r0 + r7, lsr #9
    movs    r0, r4                          @ 08020E72 r0 = r4
    bl      fat_move_window                 @ 08020E74 call fat_move_window
    mov     r9, r0                          @ 08020E78 r9 = r0
    uxtb.w  r9, r9                          @ 08020E7A r9 = u8(r9)
    cmp.w   r9, #0                          @ 08020E7E compare r9 with 0
    bne     .Lfat_put_fat_0F70              @ 08020E82 if (r9 != 0) goto 0x8020F70
    lsls    r0, r7, #0x17                   @ 08020E84 r0 = r7 << 0x17
    lsrs    r0, r0, #0x17                   @ 08020E86 r0 = r0 >> 0x17
    add     r0, r4                          @ 08020E88 r0 += r4
    adds    r0, #0x30                       @ 08020E8A r0 += 0x30
    mov     r8, r0                          @ 08020E8C r8 = r0
    lsls    r0, r5, #0x1f                   @ 08020E8E r0 = r5 << 0x1f
    bpl     .Lfat_put_fat_0EA0              @ 08020E90 if (r0 >=0 0) goto 0x8020EA0
    ldrb.w  r0, [r8]                        @ 08020E92 r0 = u8 [r8]
    ands    r0, r0, #0xf                    @ 08020E96 r0 = r0 & 0xf
    orrs.w  r0, r0, r6, lsl #4              @ 08020E9A r0 = r0 | r6, lsl #4
    b       .Lfat_put_fat_0EA2              @ 08020E9E goto 0x8020EA2
.Lfat_put_fat_0EA0:                     @ v2.05 0x08020EA0, reached from 0x08020E90
    movs    r0, r6                          @ 08020EA0 r0 = r6
.Lfat_put_fat_0EA2:                     @ v2.05 0x08020EA2, reached from 0x08020E9E
    strb.w  r0, [r8]                        @ 08020EA2 u8 [r8] = r0
    adds    r7, r7, #1                      @ 08020EA6 r7 = r7 + 1
    movs    r0, #1                          @ 08020EA8 r0 = 1
    strb    r0, [r4, #4]                    @ 08020EAA u8 [r4+0x4] = r0
    ldr     r0, [r4, #0x20]                 @ 08020EAC r0 = u32 [r4+0x20]
    adds.w  r1, r0, r7, lsr #9              @ 08020EAE r1 = r0 + r7, lsr #9
    movs    r0, r4                          @ 08020EB2 r0 = r4
    bl      fat_move_window                 @ 08020EB4 call fat_move_window
    mov     r9, r0                          @ 08020EB8 r9 = r0
    uxtb.w  r9, r9                          @ 08020EBA r9 = u8(r9)
    cmp.w   r9, #0                          @ 08020EBE compare r9 with 0
    bne     .Lfat_put_fat_0F70              @ 08020EC2 if (r9 != 0) goto 0x8020F70
    lsls    r0, r7, #0x17                   @ 08020EC4 r0 = r7 << 0x17
    lsrs    r0, r0, #0x17                   @ 08020EC6 r0 = r0 >> 0x17
    add     r0, r4                          @ 08020EC8 r0 += r4
    adds    r0, #0x30                       @ 08020ECA r0 += 0x30
    mov     r8, r0                          @ 08020ECC r8 = r0
    lsls    r0, r5, #0x1f                   @ 08020ECE r0 = r5 << 0x1f
    bpl     .Lfat_put_fat_0ED6              @ 08020ED0 if (r0 >=0 0) goto 0x8020ED6
    lsrs    r0, r6, #4                      @ 08020ED2 r0 = r6 >> 4
    b       .Lfat_put_fat_0EE6              @ 08020ED4 goto 0x8020EE6
.Lfat_put_fat_0ED6:                     @ v2.05 0x08020ED6, reached from 0x08020ED0
    ldrb.w  r0, [r8]                        @ 08020ED6 r0 = u8 [r8]
    ands    r0, r0, #0xf0                   @ 08020EDA r0 = r0 & 0xf0
    lsrs    r1, r6, #8                      @ 08020EDE r1 = r6 >> 8
    ands    r1, r1, #0xf                    @ 08020EE0 r1 = r1 & 0xf
    orrs    r0, r1                          @ 08020EE4 r0 |= r1
.Lfat_put_fat_0EE6:                     @ v2.05 0x08020EE6, reached from 0x08020ED4
    strb.w  r0, [r8]                        @ 08020EE6 u8 [r8] = r0
    b       .Lfat_put_fat_0F70              @ 08020EEA goto 0x8020F70
    @ FAT16: halfword
.Lfat_put_fat_0EEC:                     @ v2.05 0x08020EEC, reached from 0x08020E62
    ldr     r0, [r4, #0x20]                 @ 08020EEC r0 = u32 [r4+0x20]
    adds.w  r1, r0, r5, lsr #8              @ 08020EEE r1 = r0 + r5, lsr #8
    movs    r0, r4                          @ 08020EF2 r0 = r4
    bl      fat_move_window                 @ 08020EF4 call fat_move_window
    mov     r9, r0                          @ 08020EF8 r9 = r0
    uxtb.w  r9, r9                          @ 08020EFA r9 = u8(r9)
    cmp.w   r9, #0                          @ 08020EFE compare r9 with 0
    bne     .Lfat_put_fat_0F70              @ 08020F02 if (r9 != 0) goto 0x8020F70
    lsls    r0, r5, #1                      @ 08020F04 r0 = r5 << 1
    lsls    r0, r0, #0x17                   @ 08020F06 r0 = r0 << 0x17
    lsrs    r0, r0, #0x17                   @ 08020F08 r0 = r0 >> 0x17
    add     r0, r4                          @ 08020F0A r0 += r4
    adds    r0, #0x30                       @ 08020F0C r0 += 0x30
    mov     r8, r0                          @ 08020F0E r8 = r0
    strb.w  r6, [r8]                        @ 08020F10 u8 [r8] = r6
    movs    r0, r6                          @ 08020F14 r0 = r6
    uxth    r0, r0                          @ 08020F16 r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 08020F18 r0 = r0 >> 8
    strb.w  r0, [r8, #1]                    @ 08020F1A u8 [r8+0x1] = r0
    b       .Lfat_put_fat_0F70              @ 08020F1E goto 0x8020F70
    @ FAT32: word, the reserved top nibble of the old entry is kept
.Lfat_put_fat_0F20:                     @ v2.05 0x08020F20, reached from 0x08020E60
    ldr     r0, [r4, #0x20]                 @ 08020F20 r0 = u32 [r4+0x20]
    adds.w  r1, r0, r5, lsr #7              @ 08020F22 r1 = r0 + r5, lsr #7
    movs    r0, r4                          @ 08020F26 r0 = r4
    bl      fat_move_window                 @ 08020F28 call fat_move_window
    mov     r9, r0                          @ 08020F2C r9 = r0
    uxtb.w  r9, r9                          @ 08020F2E r9 = u8(r9)
    cmp.w   r9, #0                          @ 08020F32 compare r9 with 0
    bne     .Lfat_put_fat_0F70              @ 08020F36 if (r9 != 0) goto 0x8020F70
    lsls    r0, r5, #2                      @ 08020F38 r0 = r5 << 2
    lsls    r0, r0, #0x17                   @ 08020F3A r0 = r0 << 0x17
    lsrs    r0, r0, #0x17                   @ 08020F3C r0 = r0 >> 0x17
    add     r0, r4                          @ 08020F3E r0 += r4
    adds    r0, #0x30                       @ 08020F40 r0 += 0x30
    mov     r8, r0                          @ 08020F42 r8 = r0
    ldrb.w  r0, [r8, #3]                    @ 08020F44 r0 = u8 [r8+0x3]
    lsls    r0, r0, #0x18                   @ 08020F48 r0 = r0 << 0x18
    ands    r0, r0, #0xf0000000             @ 08020F4A r0 = r0 & 0xf0000000
    orrs    r6, r0                          @ 08020F4E r6 |= r0
    strb.w  r6, [r8]                        @ 08020F50 u8 [r8] = r6
    movs    r0, r6                          @ 08020F54 r0 = r6
    uxth    r0, r0                          @ 08020F56 r0 = u16(r0)
    lsrs    r0, r0, #8                      @ 08020F58 r0 = r0 >> 8
    strb.w  r0, [r8, #1]                    @ 08020F5A u8 [r8+0x1] = r0
    lsrs    r0, r6, #0x10                   @ 08020F5E r0 = r6 >> 0x10
    strb.w  r0, [r8, #2]                    @ 08020F60 u8 [r8+0x2] = r0
    lsrs    r0, r6, #0x18                   @ 08020F64 r0 = r6 >> 0x18
    strb.w  r0, [r8, #3]                    @ 08020F66 u8 [r8+0x3] = r0
    b       .Lfat_put_fat_0F70              @ 08020F6A goto 0x8020F70
.Lfat_put_fat_0F6C:                     @ v2.05 0x08020F6C, reached from 0x08020E5A, 0x08020E64
    movs    r0, #2                          @ 08020F6C r0 = 2
    mov     r9, r0                          @ 08020F6E r9 = r0
    @ OF-64: the window is marked dirty only when the entry was written (FatFs R0.10c put_fat); v2.05 marks it on every exit
    @ (0x08020F70), also after fat_move_window failed, when the window holds a stale or (after a failed read) invalid sector
.Lfat_put_fat_0F70:                     @ v2.05 0x08020F70, reached from 0x08020E82, 0x08020EC2, 0x08020EEA, 0x08020F02, 0x08020F1E, 0x08020F36, 0x08020F6A
    cmp     r9, #0
    bne     .Lfat_put_fat_0F74              @ failed: the window is left as fat_move_window left it
    movs    r0, #1                          @ 08020F70 r0 = 1
    strb    r0, [r4, #4]                    @ 08020F72 u8 [r4+0x4] = r0
.Lfat_put_fat_0F74:                     @ v2.05 0x08020F74, reached from 0x08020E52
    mov     r0, r9                          @ 08020F74 r0 = r9
    uxtb    r0, r0                          @ 08020F76 r0 = u8(r0)
    pop.w   {r1, r4, r5, r6, r7, r8, r9, pc}@ 08020F78 pop {r1, r4, r5, r6, r7, r8, r9, pc}
ENDFUNC fat_put_fat
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_remove_chain - release the cluster chain that starts at r1 (FatFs remove_chain)
@ Replaces  : 0x08020F7C FUN_08020F7C (v2.05), called by fat_f_open
@ In        : r0 = FATFS pointer, r1 = first cluster
@ Out       : r0 = 0 ok, 1 disk error, 2 internal error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : updates FATFS free cluster count (+0x10) and the FSInfo flag (+5) when the count is known
@ Spec      : v2.05 listing 0x08020F7C..0x08020FED
@ Note      : each cluster is read with get_fat, set to 0 with put_fat, and counted as free; the loop ends at cluster value 0
@             (end of a free chain) or the first cluster beyond the volume; a cluster value of 1 is an internal error.
@ -----------------------------------------------------------------------------
FUNC fat_remove_chain
    push    {r3, r4, r5, r6, r7, lr}        @ 08020F7C push {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 08020F7E r4 = r0
    movs    r5, r1                          @ 08020F80 r5 = r1
    @ cluster below 2 or not below FATFS +0x18: result 2
    cmp     r5, #2                          @ 08020F82 compare r5 with 2
    blo     .Lfat_remove_chain_0F8C         @ 08020F84 if (r5 <u 2) goto 0x8020F8C
    ldr     r0, [r4, #0x18]                 @ 08020F86 r0 = u32 [r4+0x18]
    cmp     r5, r0                          @ 08020F88 compare r5 with r0
    blo     .Lfat_remove_chain_0F92         @ 08020F8A if (r5 <u r0) goto 0x8020F92
.Lfat_remove_chain_0F8C:                @ v2.05 0x08020F8C, reached from 0x08020F84
    movs    r0, #2                          @ 08020F8C r0 = 2
    movs    r6, r0                          @ 08020F8E r6 = r0
    b       .Lfat_remove_chain_0FE8         @ 08020F90 goto 0x8020FE8
.Lfat_remove_chain_0F92:                @ v2.05 0x08020F92, reached from 0x08020F8A
    movs    r0, #0                          @ 08020F92 r0 = 0
    movs    r6, r0                          @ 08020F94 r6 = r0
    @ loop over the chain: cluster r5 beyond the volume ends the walk with result 0
.Lfat_remove_chain_0F96:                @ v2.05 0x08020F96, reached from 0x08020FE6
    ldr     r0, [r4, #0x18]                 @ 08020F96 r0 = u32 [r4+0x18]
    cmp     r5, r0                          @ 08020F98 compare r5 with r0
    bhs     .Lfat_remove_chain_0FE8         @ 08020F9A if (r5 >=u r0) goto 0x8020FE8
    movs    r1, r5                          @ 08020F9C r1 = r5
    movs    r0, r4                          @ 08020F9E r0 = r4
    @ next = get_fat(r5): 0 = end (free), 1 = internal error (2), 0xFFFFFFFF = disk error (1)
    bl      fat_get_fat                     @ 08020FA0 call fat_get_fat
    movs    r7, r0                          @ 08020FA4 r7 = r0
    cmp     r7, #0                          @ 08020FA6 compare r7 with 0
    beq     .Lfat_remove_chain_0FE8         @ 08020FA8 if (r7 == 0) goto 0x8020FE8
    cmp     r7, #1                          @ 08020FAA compare r7 with 1
    bne     .Lfat_remove_chain_0FB4         @ 08020FAC if (r7 != 1) goto 0x8020FB4
    movs    r0, #2                          @ 08020FAE r0 = 2
    movs    r6, r0                          @ 08020FB0 r6 = r0
    b       .Lfat_remove_chain_0FE8         @ 08020FB2 goto 0x8020FE8
.Lfat_remove_chain_0FB4:                @ v2.05 0x08020FB4, reached from 0x08020FAC
    cmn.w   r7, #1                          @ 08020FB4 compare r7 with 1
    bne     .Lfat_remove_chain_0FC0         @ 08020FB8 if ((r7 + 1) != 0) goto 0x8020FC0
    movs    r0, #1                          @ 08020FBA r0 = 1
    movs    r6, r0                          @ 08020FBC r6 = r0
    b       .Lfat_remove_chain_0FE8         @ 08020FBE goto 0x8020FE8
.Lfat_remove_chain_0FC0:                @ v2.05 0x08020FC0, reached from 0x08020FB8
    movs    r2, #0                          @ 08020FC0 r2 = 0
    movs    r1, r5                          @ 08020FC2 r1 = r5
    movs    r0, r4                          @ 08020FC4 r0 = r4
    @ put_fat(r5, 0): release the cluster
    bl      fat_put_fat                     @ 08020FC6 call fat_put_fat
    movs    r6, r0                          @ 08020FCA r6 = r0
    uxtb    r6, r6                          @ 08020FCC r6 = u8(r6)
    cmp     r6, #0                          @ 08020FCE compare r6 with 0
    bne     .Lfat_remove_chain_0FE8         @ 08020FD0 if (r6 != 0) goto 0x8020FE8
    @ free cluster count (FATFS +0x10) + 1 when it is known (not 0xFFFFFFFF), FSInfo flag (FATFS +5) set
    ldr     r0, [r4, #0x10]                 @ 08020FD2 r0 = u32 [r4+0x10]
    cmn.w   r0, #1                          @ 08020FD4 compare r0 with 1
    beq     .Lfat_remove_chain_0FE4         @ 08020FD8 if ((r0 + 1) == 0) goto 0x8020FE4
    ldr     r0, [r4, #0x10]                 @ 08020FDA r0 = u32 [r4+0x10]
    adds    r0, r0, #1                      @ 08020FDC r0 = r0 + 1
    str     r0, [r4, #0x10]                 @ 08020FDE u32 [r4+0x10] = r0
    movs    r0, #1                          @ 08020FE0 r0 = 1
    strb    r0, [r4, #5]                    @ 08020FE2 u8 [r4+0x5] = r0
    @ continue with the next cluster
.Lfat_remove_chain_0FE4:                @ v2.05 0x08020FE4, reached from 0x08020FD8
    movs    r5, r7                          @ 08020FE4 r5 = r7
    b       .Lfat_remove_chain_0F96         @ 08020FE6 goto 0x8020F96
.Lfat_remove_chain_0FE8:                @ v2.05 0x08020FE8, reached from 0x08020F90, 0x08020F9A, 0x08020FA8, 0x08020FB2, 0x08020FBE, 0x08020FD0
    movs    r0, r6                          @ 08020FE8 r0 = r6
    uxtb    r0, r0                          @ 08020FEA r0 = u8(r0)
    pop     {r1, r4, r5, r6, r7, pc}        @ 08020FEC pop {r1, r4, r5, r6, r7, pc}
ENDFUNC fat_remove_chain
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_create_chain - append one cluster to the chain of cluster r1 (or start a chain when r1 = 0) (FatFs create_chain)
@ Replaces  : 0x08020FEE FUN_08020FEE (v2.05), called by fat_f_write and fat_f_lseek
@ In        : r0 = FATFS pointer, r1 = current last cluster of the chain, 0 for a new chain
@ Out       : r0 = the new cluster number, 0 when the volume is full, 1 on an internal error, 0xFFFFFFFF on a disk error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : updates FATFS last allocated cluster (+0xC), free cluster count (+0x10), FSInfo flag (+5)
@ Spec      : v2.05 listing 0x08020FEE..0x080210C9
@ Note      : the search for a free cluster starts after the last allocated one (or after r1) and wraps once.  The found cluster is
@             marked as the end of chain (0x0FFFFFFF), the previous cluster is linked to it, the free count is decremented.
@ -----------------------------------------------------------------------------
FUNC fat_create_chain
    push.w  {r3, r4, r5, r6, r7, r8, r9, lr}@ 08020FEE push {r3, r4, r5, r6, r7, r8, r9, lr}
    movs    r4, r0                          @ 08020FF2 r4 = r0
    movs    r5, r1                          @ 08020FF4 r5 = r1
    @ r1 = 0: new chain, start the search at the last allocated cluster (FATFS +0xC); 1 when that is invalid (100A)
    cmp     r5, #0                          @ 08020FF6 compare r5 with 0
    bne     .Lfat_create_chain_1010         @ 08020FF8 if (r5 != 0) goto 0x8021010
    ldr     r0, [r4, #0xc]                  @ 08020FFA r0 = u32 [r4+0xC]
    mov     r8, r0                          @ 08020FFC r8 = r0
    cmp.w   r8, #0                          @ 08020FFE compare r8 with 0
    beq     .Lfat_create_chain_100A         @ 08021002 if (r8 == 0) goto 0x802100A
    ldr     r0, [r4, #0x18]                 @ 08021004 r0 = u32 [r4+0x18]
    cmp     r8, r0                          @ 08021006 compare r8 with r0
    blo     .Lfat_create_chain_102E         @ 08021008 if (r8 <u r0) goto 0x802102E
.Lfat_create_chain_100A:                @ v2.05 0x0802100A, reached from 0x08021002
    movs    r0, #1                          @ 0802100A r0 = 1
    mov     r8, r0                          @ 0802100C r8 = r0
    b       .Lfat_create_chain_102E         @ 0802100E goto 0x802102E
    @ r1 != 0: get_fat(r1) - below 2 is an internal error (1020), a valid following cluster is returned as it is (102A)
.Lfat_create_chain_1010:                @ v2.05 0x08021010, reached from 0x08020FF8
    movs    r1, r5                          @ 08021010 r1 = r5
    movs    r0, r4                          @ 08021012 r0 = r4
    bl      fat_get_fat                     @ 08021014 call fat_get_fat
    movs    r6, r0                          @ 08021018 r6 = r0
    cmp     r6, #2                          @ 0802101A compare r6 with 2
    bhs     .Lfat_create_chain_1022         @ 0802101C if (r6 >=u 2) goto 0x8021022
    movs    r0, #1                          @ 0802101E r0 = 1
    b       .Lfat_create_chain_10C6         @ 08021020 goto 0x80210C6
.Lfat_create_chain_1022:                @ v2.05 0x08021022, reached from 0x0802101C
    cmp     r6, #-1                         @ OF-64: disk error while reading the entry of r1: return it (0xFFFFFFFF) instead of
    bne     1f                              @ taking it as the end of the chain and linking a new cluster behind an entry that
    movs    r0, r6                          @ could not be read (FatFs R0.10a create_chain; v2.05 0x08021022..0x08021026)
    b       .Lfat_create_chain_10C6
1:  ldr     r0, [r4, #0x18]                 @ 08021022 r0 = u32 [r4+0x18]
    cmp     r6, r0                          @ 08021024 compare r6 with r0
    bhs     .Lfat_create_chain_102C         @ 08021026 if (r6 >=u r0) goto 0x802102C
    movs    r0, r6                          @ 08021028 r0 = r6
    b       .Lfat_create_chain_10C6         @ 0802102A goto 0x80210C6
.Lfat_create_chain_102C:                @ v2.05 0x0802102C, reached from 0x08021026
    mov     r8, r5                          @ 0802102C r8 = r5
    @ search loop: r8 = start cluster, r7 = candidate; wraps from the end of the volume to cluster 2 and gives up after one full turn (107A..107E: result 0)
.Lfat_create_chain_102E:                @ v2.05 0x0802102E, reached from 0x08021008, 0x0802100E
    mov     r7, r8                          @ 0802102E r7 = r8
.Lfat_create_chain_1030:                @ v2.05 0x08021030, reached from 0x0802107C
    adds    r7, r7, #1                      @ 08021030 r7 = r7 + 1
    ldr     r0, [r4, #0x18]                 @ 08021032 r0 = u32 [r4+0x18]
    cmp     r7, r0                          @ 08021034 compare r7 with r0
    blo     .Lfat_create_chain_1044         @ 08021036 if (r7 <u r0) goto 0x8021044
    movs    r0, #2                          @ 08021038 r0 = 2
    movs    r7, r0                          @ 0802103A r7 = r0
    cmp     r8, r7                          @ 0802103C compare r8 with r7
    bhs     .Lfat_create_chain_1044         @ 0802103E if (r8 >=u r7) goto 0x8021044
    movs    r0, #0                          @ 08021040 r0 = 0
    b       .Lfat_create_chain_10C6         @ 08021042 goto 0x80210C6
    @ get_fat(r7) == 0: the cluster is free
.Lfat_create_chain_1044:                @ v2.05 0x08021044, reached from 0x08021036, 0x0802103E
    movs    r1, r7                          @ 08021044 r1 = r7
    movs    r0, r4                          @ 08021046 r0 = r4
    bl      fat_get_fat                     @ 08021048 call fat_get_fat
    movs    r6, r0                          @ 0802104C r6 = r0
    cmp     r6, #0                          @ 0802104E compare r6 with 0
    bne     .Lfat_create_chain_106C         @ 08021050 if (r6 != 0) goto 0x802106C
    @ mark the free cluster as end of chain (0x0FFFFFFF) with put_fat; for a new chain nothing is linked (1082..1084)
    mvns    r2, #0xf0000000                 @ 08021052 r2 = ~0xf0000000
    movs    r1, r7                          @ 08021056 r1 = r7
    movs    r0, r4                          @ 08021058 r0 = r4
    bl      fat_put_fat                     @ 0802105A call fat_put_fat
    mov     r9, r0                          @ 0802105E r9 = r0
    uxtb.w  r9, r9                          @ 08021060 r9 = u8(r9)
    cmp.w   r9, #0                          @ 08021064 compare r9 with 0
    bne     .Lfat_create_chain_1092         @ 08021068 if (r9 != 0) goto 0x8021092
    b       .Lfat_create_chain_1082         @ 0802106A goto 0x8021082
.Lfat_create_chain_106C:                @ v2.05 0x0802106C, reached from 0x08021050
    cmn.w   r6, #1                          @ 0802106C compare r6 with 1
    beq     .Lfat_create_chain_1076         @ 08021070 if ((r6 + 1) == 0) goto 0x8021076
    cmp     r6, #1                          @ 08021072 compare r6 with 1
    bne     .Lfat_create_chain_107A         @ 08021074 if (r6 != 1) goto 0x802107A
.Lfat_create_chain_1076:                @ v2.05 0x08021076, reached from 0x08021070
    movs    r0, r6                          @ 08021076 r0 = r6
    b       .Lfat_create_chain_10C6         @ 08021078 goto 0x80210C6
.Lfat_create_chain_107A:                @ v2.05 0x0802107A, reached from 0x08021074
    cmp     r7, r8                          @ 0802107A compare r7 with r8
    bne     .Lfat_create_chain_1030         @ 0802107C if (r7 != r8) goto 0x8021030
    movs    r0, #0                          @ 0802107E r0 = 0
    b       .Lfat_create_chain_10C6         @ 08021080 goto 0x80210C6
.Lfat_create_chain_1082:                @ v2.05 0x08021082, reached from 0x0802106A
    cmp     r5, #0                          @ 08021082 compare r5 with 0
    beq     .Lfat_create_chain_1092         @ 08021084 if (r5 == 0) goto 0x8021092
    @ link the previous cluster r5 to the new one r7
    movs    r2, r7                          @ 08021086 r2 = r7
    movs    r1, r5                          @ 08021088 r1 = r5
    movs    r0, r4                          @ 0802108A r0 = r4
    bl      fat_put_fat                     @ 0802108C call fat_put_fat
    mov     r9, r0                          @ 08021090 r9 = r0
    @ success: last allocated cluster (FATFS +0xC) = r7; free cluster count - 1 when known; FSInfo flag set
.Lfat_create_chain_1092:                @ v2.05 0x08021092, reached from 0x08021068, 0x08021084
    uxtb.w  r9, r9                          @ 08021092 r9 = u8(r9)
    cmp.w   r9, #0                          @ 08021096 compare r9 with 0
    bne     .Lfat_create_chain_10B2         @ 0802109A if (r9 != 0) goto 0x80210B2
    str     r7, [r4, #0xc]                  @ 0802109C u32 [r4+0xC] = r7
    ldr     r0, [r4, #0x10]                 @ 0802109E r0 = u32 [r4+0x10]
    cmn.w   r0, #1                          @ 080210A0 compare r0 with 1
    beq     .Lfat_create_chain_10C4         @ 080210A4 if ((r0 + 1) == 0) goto 0x80210C4
    ldr     r0, [r4, #0x10]                 @ 080210A6 r0 = u32 [r4+0x10]
    subs    r0, r0, #1                      @ 080210A8 r0 = r0 - 1
    str     r0, [r4, #0x10]                 @ 080210AA u32 [r4+0x10] = r0
    movs    r0, #1                          @ 080210AC r0 = 1
    strb    r0, [r4, #5]                    @ 080210AE u8 [r4+0x5] = r0
    b       .Lfat_create_chain_10C4         @ 080210B0 goto 0x80210C4
    @ a put_fat error: disk error (1) becomes 0xFFFFFFFF, any other becomes 1
.Lfat_create_chain_10B2:                @ v2.05 0x080210B2, reached from 0x0802109A
    uxtb.w  r9, r9                          @ 080210B2 r9 = u8(r9)
    cmp.w   r9, #1                          @ 080210B6 compare r9 with 1
    bne     .Lfat_create_chain_10C2         @ 080210BA if (r9 != 1) goto 0x80210C2
    movs.w  r7, #-1                         @ 080210BC r7 = -1
    b       .Lfat_create_chain_10C4         @ 080210C0 goto 0x80210C4
.Lfat_create_chain_10C2:                @ v2.05 0x080210C2, reached from 0x080210BA
    movs    r7, #1                          @ 080210C2 r7 = 1
.Lfat_create_chain_10C4:                @ v2.05 0x080210C4, reached from 0x080210A4, 0x080210B0, 0x080210C0
    movs    r0, r7                          @ 080210C4 r0 = r7
.Lfat_create_chain_10C6:                @ v2.05 0x080210C6, reached from 0x08021020, 0x0802102A, 0x08021042, 0x08021078, 0x08021080
    pop.w   {r1, r4, r5, r6, r7, r8, r9, pc}@ 080210C6 pop {r1, r4, r5, r6, r7, r8, r9, pc}
ENDFUNC fat_create_chain
    .ltorg

    .endif
