@ fat_dir.s - SD module: FAT directories and path handling, volume mounting (DESIGN.md 6.23, W8)
@
@ Directory entries are the 32-byte FAT entries (name 0..10, attribute 11, cluster high 20, time 22, date 24, cluster low 26,
@ size 28).  Names are 8.3 only; a long-name entry is skipped (attribute 0x0F).  The directory walker keeps the entry in
@ the window of the file system (DIR +0x14 points into it).  The names of the routines are the FatFs names (dir_sdi,
@ dir_next, dir_find, dir_read, dir_register, create_name, get_fileinfo, follow_path, check_fs, chk_mounted).
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
    .equ fat_mount_id,            v_20007F98            @ 0x20007F98 mount id counter, copied into FATFS +6 at every mount (u16)

@ -----------------------------------------------------------------------------
@ fat_dir_sdi - set the directory index to r1 (FatFs dir_sdi)
@ Replaces  : 0x080210CA FUN_080210CA (v2.05), called by dir_find, dir_read, dir_register, follow_path, f_opendir, f_readdir
@ In        : r0 = DIR pointer, r1 = entry index (u16)
@ Out       : r0 = 0 ok, 1 disk error, 2 internal error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : DIR +6 index, +0xC current cluster, +0x10 current sector, +0x14 entry pointer
@ Spec      : v2.05 listing 0x080210CA..0x0802117F
@ Note      : a start cluster of 1 or beyond the volume is an internal error.  A FAT12/16 root directory (start cluster 0) is a fixed area: the index
@             must stay below the root entry count; FAT32 starts at the root cluster.  Otherwise the cluster chain is followed one
@             cluster (16 * sectors per cluster entries) at a time.
@ -----------------------------------------------------------------------------
FUNC fat_dir_sdi
    push    {r3, r4, r5, r6, r7, lr}        @ 080210CA push {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 080210CC r4 = r0
    movs    r5, r1                          @ 080210CE r5 = r1
    @ index stored in the DIR; r6 = start cluster
    strh    r5, [r4, #6]                    @ 080210D0 u16 [r4+0x6] = r5
    ldr     r0, [r4, #8]                    @ 080210D2 r0 = u32 [r4+0x8]
    movs    r6, r0                          @ 080210D4 r6 = r0
    @ start cluster 1 or not below FATFS +0x18: internal error (2)
    cmp     r6, #1                          @ 080210D6 compare r6 with 1
    beq     .Lfat_dir_sdi_10E2              @ 080210D8 if (r6 == 1) goto 0x80210E2
    ldr     r0, [r4]                        @ 080210DA r0 = u32 [r4]
    ldr     r0, [r0, #0x18]                 @ 080210DC r0 = u32 [r0+0x18]
    cmp     r6, r0                          @ 080210DE compare r6 with r0
    blo     .Lfat_dir_sdi_10E6              @ 080210E0 if (r6 <u r0) goto 0x80210E6
.Lfat_dir_sdi_10E2:                     @ v2.05 0x080210E2, reached from 0x080210D8
    movs    r0, #2                          @ 080210E2 r0 = 2
    b       .Lfat_dir_sdi_117E              @ 080210E4 goto 0x802117E
    @ start cluster 0 with a FAT32 volume: the root directory is the cluster in FATFS +0x24
.Lfat_dir_sdi_10E6:                     @ v2.05 0x080210E6, reached from 0x080210E0
    cmp     r6, #0                          @ 080210E6 compare r6 with 0
    bne     .Lfat_dir_sdi_10F8              @ 080210E8 if (r6 != 0) goto 0x80210F8
    ldr     r0, [r4]                        @ 080210EA r0 = u32 [r4]
    ldrb    r0, [r0]                        @ 080210EC r0 = u8 [r0]
    cmp     r0, #3                          @ 080210EE compare r0 with 3
    bne     .Lfat_dir_sdi_10F8              @ 080210F0 if (r0 != 3) goto 0x80210F8
    ldr     r0, [r4]                        @ 080210F2 r0 = u32 [r4]
    ldr     r0, [r0, #0x24]                 @ 080210F4 r0 = u32 [r0+0x24]
    movs    r6, r0                          @ 080210F6 r6 = r0
    @ start cluster 0 left: fixed root area of FAT12/16; the index must be below the root entry count (FATFS +8), sector = FATFS +0x24 + index / 16
.Lfat_dir_sdi_10F8:                     @ v2.05 0x080210F8, reached from 0x080210E8, 0x080210F0
    cmp     r6, #0                          @ 080210F8 compare r6 with 0
    bne     .Lfat_dir_sdi_111C              @ 080210FA if (r6 != 0) goto 0x802111C
    str     r6, [r4, #0xc]                  @ 080210FC u32 [r4+0xC] = r6
    movs    r0, r5                          @ 080210FE r0 = r5
    ldr     r1, [r4]                        @ 08021100 r1 = u32 [r4]
    ldrh    r1, [r1, #8]                    @ 08021102 r1 = u16 [r1+0x8]
    uxth    r0, r0                          @ 08021104 r0 = u16(r0)
    cmp     r0, r1                          @ 08021106 compare r0 with r1
    blo     .Lfat_dir_sdi_110E              @ 08021108 if (r0 <u r1) goto 0x802110E
    movs    r0, #2                          @ 0802110A r0 = 2
    b       .Lfat_dir_sdi_117E              @ 0802110C goto 0x802117E
.Lfat_dir_sdi_110E:                     @ v2.05 0x0802110E, reached from 0x08021108
    ldr     r0, [r4]                        @ 0802110E r0 = u32 [r4]
    ldr     r0, [r0, #0x24]                 @ 08021110 r0 = u32 [r0+0x24]
    uxth    r5, r5                          @ 08021112 r5 = u16(r5)
    adds.w  r0, r0, r5, lsr #4              @ 08021114 r0 = r0 + r5, lsr #4
    str     r0, [r4, #0x10]                 @ 08021118 u32 [r4+0x10] = r0
    b       .Lfat_dir_sdi_116C              @ 0802111A goto 0x802116C
    @ directory in a cluster chain: r7 = entries per cluster = 16 * sectors per cluster
.Lfat_dir_sdi_111C:                     @ v2.05 0x0802111C, reached from 0x080210FA
    ldr     r0, [r4]                        @ 0802111C r0 = u32 [r4]
    ldrb    r0, [r0, #2]                    @ 0802111E r0 = u8 [r0+0x2]
    uxth    r0, r0                          @ 08021120 r0 = u16(r0)
    lsls    r0, r0, #4                      @ 08021122 r0 = r0 << 4
    movs    r7, r0                          @ 08021124 r7 = r0
    @ skip whole clusters while the index reaches the next cluster: get_fat; 0xFFFFFFFF = disk error (1), below 2 or beyond the volume = 2
.Lfat_dir_sdi_1126:                     @ v2.05 0x08021126, reached from 0x08021158
    movs    r0, r5                          @ 08021126 r0 = r5
    movs    r1, r7                          @ 08021128 r1 = r7
    uxth    r0, r0                          @ 0802112A r0 = u16(r0)
    uxth    r1, r1                          @ 0802112C r1 = u16(r1)
    cmp     r0, r1                          @ 0802112E compare r0 with r1
    blo     .Lfat_dir_sdi_115A              @ 08021130 if (r0 <u r1) goto 0x802115A
    movs    r1, r6                          @ 08021132 r1 = r6
    ldr     r0, [r4]                        @ 08021134 r0 = u32 [r4]
    bl      fat_get_fat                     @ 08021136 call fat_get_fat
    movs    r6, r0                          @ 0802113A r6 = r0
    cmn.w   r6, #1                          @ 0802113C compare r6 with 1
    bne     .Lfat_dir_sdi_1146              @ 08021140 if ((r6 + 1) != 0) goto 0x8021146
    movs    r0, #1                          @ 08021142 r0 = 1
    b       .Lfat_dir_sdi_117E              @ 08021144 goto 0x802117E
.Lfat_dir_sdi_1146:                     @ v2.05 0x08021146, reached from 0x08021140
    cmp     r6, #2                          @ 08021146 compare r6 with 2
    blo     .Lfat_dir_sdi_1152              @ 08021148 if (r6 <u 2) goto 0x8021152
    ldr     r0, [r4]                        @ 0802114A r0 = u32 [r4]
    ldr     r0, [r0, #0x18]                 @ 0802114C r0 = u32 [r0+0x18]
    cmp     r6, r0                          @ 0802114E compare r6 with r0
    blo     .Lfat_dir_sdi_1156              @ 08021150 if (r6 <u r0) goto 0x8021156
.Lfat_dir_sdi_1152:                     @ v2.05 0x08021152, reached from 0x08021148
    movs    r0, #2                          @ 08021152 r0 = 2
    b       .Lfat_dir_sdi_117E              @ 08021154 goto 0x802117E
.Lfat_dir_sdi_1156:                     @ v2.05 0x08021156, reached from 0x08021150
    subs    r5, r5, r7                      @ 08021156 r5 = r5 - r7
    b       .Lfat_dir_sdi_1126              @ 08021158 goto 0x8021126
    @ cluster found: sector = first sector of the cluster + index / 16
.Lfat_dir_sdi_115A:                     @ v2.05 0x0802115A, reached from 0x08021130
    str     r6, [r4, #0xc]                  @ 0802115A u32 [r4+0xC] = r6
    movs    r1, r6                          @ 0802115C r1 = r6
    ldr     r0, [r4]                        @ 0802115E r0 = u32 [r4]
    bl      fat_clust2sect                  @ 08021160 call fat_clust2sect
    uxth    r5, r5                          @ 08021164 r5 = u16(r5)
    adds.w  r0, r0, r5, lsr #4              @ 08021166 r0 = r0 + r5, lsr #4
    str     r0, [r4, #0x10]                 @ 0802116A u32 [r4+0x10] = r0
    @ entry pointer = window + 0x30 + (index & 15) * 32
.Lfat_dir_sdi_116C:                     @ v2.05 0x0802116C, reached from 0x0802111A
    ldr     r0, [r4]                        @ 0802116C r0 = u32 [r4]
    uxth    r5, r5                          @ 0802116E r5 = u16(r5)
    ands    r1, r5, #0xf                    @ 08021170 r1 = r5 & 0xf
    lsls    r1, r1, #5                      @ 08021174 r1 = r1 << 5
    add     r0, r1                          @ 08021176 r0 += r1
    adds    r0, #0x30                       @ 08021178 r0 += 0x30
    str     r0, [r4, #0x14]                 @ 0802117A u32 [r4+0x14] = r0
    movs    r0, #0                          @ 0802117C r0 = 0
.Lfat_dir_sdi_117E:                     @ v2.05 0x0802117E, reached from 0x080210E4, 0x0802110C, 0x08021144, 0x08021154
    pop     {r1, r4, r5, r6, r7, pc}        @ 0802117E pop {r1, r4, r5, r6, r7, pc}
ENDFUNC fat_dir_sdi
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_dir_next - advance the directory index by one, optionally extending the directory (FatFs dir_next)
@ Replaces  : 0x08021180 FUN_08021180 (v2.05), called by dir_find, dir_read, dir_register
@ In        : r0 = DIR pointer, r1 = 1 stretch the directory when its end is reached, 0 do not
@ Out       : r0 = 0 ok, 4 end of the directory (or index overflow), 7 denied (disk full), 2 internal error, 1 disk error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08021180..0x080212B1
@ Note      : when the next entry is in a new sector the sector number is incremented; at a cluster boundary the next cluster is
@             taken from the FAT, and with r1 = 1 a new cluster is allocated (fat_create_chain), cleared (a whole cluster of zero
@             sectors written through the window) and linked.  The FAT12/16 root directory has no clusters and ends at its entry count.
@ -----------------------------------------------------------------------------
FUNC fat_dir_next
    push.w  {r4, r5, r6, r7, r8, lr}        @ 08021180 push {r4, r5, r6, r7, r8, lr}
    movs    r4, r0                          @ 08021184 r4 = r0
    movs    r5, r1                          @ 08021186 r5 = r1
    @ new index = index + 1 (u16); 0 (wrap) or no sector (DIR +0x10 = 0): end of directory (4)
    ldrh    r0, [r4, #6]                    @ 08021188 r0 = u16 [r4+0x6]
    adds    r0, r0, #1                      @ 0802118A r0 = r0 + 1
    movs    r7, r0                          @ 0802118C r7 = r0
    uxth    r7, r7                          @ 0802118E r7 = u16(r7)
    cmp     r7, #0                          @ 08021190 compare r7 with 0
    beq     .Lfat_dir_next_119A             @ 08021192 if (r7 == 0) goto 0x802119A
    ldr     r0, [r4, #0x10]                 @ 08021194 r0 = u32 [r4+0x10]
    cmp     r0, #0                          @ 08021196 compare r0 with 0
    bne     .Lfat_dir_next_119E             @ 08021198 if (r0 != 0) goto 0x802119E
.Lfat_dir_next_119A:                    @ v2.05 0x0802119A, reached from 0x08021192
    movs    r0, #4                          @ 0802119A r0 = 4
    b       .Lfat_dir_next_12AE             @ 0802119C goto 0x80212AE
    @ only every 16th entry starts a new sector: sector + 1 (11A4)
.Lfat_dir_next_119E:                    @ v2.05 0x0802119E, reached from 0x08021198
    movs    r0, #0xf                        @ 0802119E r0 = 0xf
    tst     r7, r0                          @ 080211A0 compare r7 with r0
    bne     .Lfat_dir_next_129A             @ 080211A2 if ((r7 & r0) != 0) goto 0x802129A
    ldr     r0, [r4, #0x10]                 @ 080211A4 r0 = u32 [r4+0x10]
    adds    r0, r0, #1                      @ 080211A6 r0 = r0 + 1
    str     r0, [r4, #0x10]                 @ 080211A8 u32 [r4+0x10] = r0
    @ fixed root area (cluster 0): the index must stay below the root entry count, else 4
    ldr     r0, [r4, #0xc]                  @ 080211AA r0 = u32 [r4+0xC]
    cmp     r0, #0                          @ 080211AC compare r0 with 0
    bne     .Lfat_dir_next_11C0             @ 080211AE if (r0 != 0) goto 0x80211C0
    movs    r0, r7                          @ 080211B0 r0 = r7
    ldr     r1, [r4]                        @ 080211B2 r1 = u32 [r4]
    ldrh    r1, [r1, #8]                    @ 080211B4 r1 = u16 [r1+0x8]
    uxth    r0, r0                          @ 080211B6 r0 = u16(r0)
    cmp     r0, r1                          @ 080211B8 compare r0 with r1
    blo     .Lfat_dir_next_129A             @ 080211BA if (r0 <u r1) goto 0x802129A
    movs    r0, #4                          @ 080211BC r0 = 4
    b       .Lfat_dir_next_12AE             @ 080211BE goto 0x80212AE
    @ cluster boundary every sectors-per-cluster * 16 entries (11C4..11CC)
.Lfat_dir_next_11C0:                    @ v2.05 0x080211C0, reached from 0x080211AE
    uxth    r7, r7                          @ 080211C0 r7 = u16(r7)
    ldr     r0, [r4]                        @ 080211C2 r0 = u32 [r4]
    ldrb    r0, [r0, #2]                    @ 080211C4 r0 = u8 [r0+0x2]
    subs    r0, r0, #1                      @ 080211C6 r0 = r0 - 1
    tst.w   r0, r7, lsr #4                  @ 080211C8 compare r0 with r7
    bne     .Lfat_dir_next_129A             @ 080211CC if ((r0 & r7) != 0) goto 0x802129A
    @ next cluster from the FAT: below 2 = internal error (2), 0xFFFFFFFF = disk error (1)
    ldr     r1, [r4, #0xc]                  @ 080211CE r1 = u32 [r4+0xC]
    ldr     r0, [r4]                        @ 080211D0 r0 = u32 [r4]
    bl      fat_get_fat                     @ 080211D2 call fat_get_fat
    movs    r6, r0                          @ 080211D6 r6 = r0
    cmp     r6, #2                          @ 080211D8 compare r6 with 2
    bhs     .Lfat_dir_next_11E0             @ 080211DA if (r6 >=u 2) goto 0x80211E0
    movs    r0, #2                          @ 080211DC r0 = 2
    b       .Lfat_dir_next_12AE             @ 080211DE goto 0x80212AE
.Lfat_dir_next_11E0:                    @ v2.05 0x080211E0, reached from 0x080211DA
    cmn.w   r6, #1                          @ 080211E0 compare r6 with 1
    bne     .Lfat_dir_next_11EA             @ 080211E4 if ((r6 + 1) != 0) goto 0x80211EA
    movs    r0, #1                          @ 080211E6 r0 = 1
    b       .Lfat_dir_next_12AE             @ 080211E8 goto 0x80212AE
    @ end of the chain: without stretch the end of the directory (4); with stretch allocate a cluster (create_chain): 0 = disk full (7), 1 = internal error (2)
.Lfat_dir_next_11EA:                    @ v2.05 0x080211EA, reached from 0x080211E4
    ldr     r0, [r4]                        @ 080211EA r0 = u32 [r4]
    ldr     r0, [r0, #0x18]                 @ 080211EC r0 = u32 [r0+0x18]
    cmp     r6, r0                          @ 080211EE compare r6 with r0
    blo     .Lfat_dir_next_128E             @ 080211F0 if (r6 <u r0) goto 0x802128E
    cmp     r5, #0                          @ 080211F2 compare r5 with 0
    bne     .Lfat_dir_next_11FA             @ 080211F4 if (r5 != 0) goto 0x80211FA
    movs    r0, #4                          @ 080211F6 r0 = 4
    b       .Lfat_dir_next_12AE             @ 080211F8 goto 0x80212AE
.Lfat_dir_next_11FA:                    @ v2.05 0x080211FA, reached from 0x080211F4
    ldr     r1, [r4, #0xc]                  @ 080211FA r1 = u32 [r4+0xC]
    ldr     r0, [r4]                        @ 080211FC r0 = u32 [r4]
    bl      fat_create_chain                @ 080211FE call fat_create_chain
    movs    r6, r0                          @ 08021202 r6 = r0
    cmp     r6, #0                          @ 08021204 compare r6 with 0
    bne     .Lfat_dir_next_120C             @ 08021206 if (r6 != 0) goto 0x802120C
    movs    r0, #7                          @ 08021208 r0 = 7
    b       .Lfat_dir_next_12AE             @ 0802120A goto 0x80212AE
.Lfat_dir_next_120C:                    @ v2.05 0x0802120C, reached from 0x08021206
    cmp     r6, #1                          @ 0802120C compare r6 with 1
    bne     .Lfat_dir_next_1214             @ 0802120E if (r6 != 1) goto 0x8021214
    movs    r0, #2                          @ 08021210 r0 = 2
    b       .Lfat_dir_next_12AE             @ 08021212 goto 0x80212AE
.Lfat_dir_next_1214:                    @ v2.05 0x08021214, reached from 0x0802120E
    cmn.w   r6, #1                          @ 08021214 compare r6 with 1
    bne     .Lfat_dir_next_121E             @ 08021218 if ((r6 + 1) != 0) goto 0x802121E
    movs    r0, #1                          @ 0802121A r0 = 1
    b       .Lfat_dir_next_12AE             @ 0802121C goto 0x80212AE
    @ new cluster: flush the window, clear the window and every sector of the cluster through it (1232..127C)
.Lfat_dir_next_121E:                    @ v2.05 0x0802121E, reached from 0x08021218
    movs    r1, #0                          @ 0802121E r1 = 0
    ldr     r0, [r4]                        @ 08021220 r0 = u32 [r4]
    bl      fat_move_window                 @ 08021222 call fat_move_window
    cmp     r0, #0                          @ 08021226 compare r0 with 0
    beq     .Lfat_dir_next_122E             @ 08021228 if (r0 == 0) goto 0x802122E
    movs    r0, #1                          @ 0802122A r0 = 1
    b       .Lfat_dir_next_12AE             @ 0802122C goto 0x80212AE
.Lfat_dir_next_122E:                    @ v2.05 0x0802122E, reached from 0x08021228
    mov.w   r2, #0x200                      @ 0802122E r2 = 0x200
    movs    r1, #0                          @ 08021232 r1 = 0
    ldr     r0, [r4]                        @ 08021234 r0 = u32 [r4]
    adds    r0, #0x30                       @ 08021236 r0 += 0x30
    bl      fat_mem_set                     @ 08021238 call fat_mem_set
    movs    r1, r6                          @ 0802123C r1 = r6
    ldr     r0, [r4]                        @ 0802123E r0 = u32 [r4]
    bl      fat_clust2sect                  @ 08021240 call fat_clust2sect
    ldr     r1, [r4]                        @ 08021244 r1 = u32 [r4]
    str     r0, [r1, #0x2c]                 @ 08021246 u32 [r1+0x2C] = r0
    movs    r0, #0                          @ 08021248 r0 = 0
    mov     r8, r0                          @ 0802124A r8 = r0
.Lfat_dir_next_124C:                    @ v2.05 0x0802124C, reached from 0x0802127C
    mov     r0, r8                          @ 0802124C r0 = r8
    ldr     r1, [r4]                        @ 0802124E r1 = u32 [r4]
    ldrb    r1, [r1, #2]                    @ 08021250 r1 = u8 [r1+0x2]
    uxtb    r0, r0                          @ 08021252 r0 = u8(r0)
    cmp     r0, r1                          @ 08021254 compare r0 with r1
    bhs     .Lfat_dir_next_127E             @ 08021256 if (r0 >=u r1) goto 0x802127E
    movs    r0, #1                          @ 08021258 r0 = 1
    ldr     r1, [r4]                        @ 0802125A r1 = u32 [r4]
    strb    r0, [r1, #4]                    @ 0802125C u8 [r1+0x4] = r0
    movs    r1, #0                          @ 0802125E r1 = 0
    ldr     r0, [r4]                        @ 08021260 r0 = u32 [r4]
    bl      fat_move_window                 @ 08021262 call fat_move_window
    cmp     r0, #0                          @ 08021266 compare r0 with 0
    beq     .Lfat_dir_next_126E             @ 08021268 if (r0 == 0) goto 0x802126E
    movs    r0, #1                          @ 0802126A r0 = 1
    b       .Lfat_dir_next_12AE             @ 0802126C goto 0x80212AE
.Lfat_dir_next_126E:                    @ v2.05 0x0802126E, reached from 0x08021268
    ldr     r0, [r4]                        @ 0802126E r0 = u32 [r4]
    ldr     r0, [r0, #0x2c]                 @ 08021270 r0 = u32 [r0+0x2C]
    adds    r0, r0, #1                      @ 08021272 r0 = r0 + 1
    ldr     r1, [r4]                        @ 08021274 r1 = u32 [r4]
    str     r0, [r1, #0x2c]                 @ 08021276 u32 [r1+0x2C] = r0
    adds.w  r8, r8, #1                      @ 08021278 r8 = r8 + 1
    b       .Lfat_dir_next_124C             @ 0802127C goto 0x802124C
.Lfat_dir_next_127E:                    @ v2.05 0x0802127E, reached from 0x08021256
    ldr     r0, [r4]                        @ 0802127E r0 = u32 [r4]
    ldr     r0, [r0, #0x2c]                 @ 08021280 r0 = u32 [r0+0x2C]
    uxtb.w  r8, r8                          @ 08021282 r8 = u8(r8)
    subs.w  r0, r0, r8                      @ 08021286 r0 = r0 - r8
    ldr     r1, [r4]                        @ 0802128A r1 = u32 [r4]
    str     r0, [r1, #0x2c]                 @ 0802128C u32 [r1+0x2C] = r0
    @ current cluster and its first sector
.Lfat_dir_next_128E:                    @ v2.05 0x0802128E, reached from 0x080211F0
    str     r6, [r4, #0xc]                  @ 0802128E u32 [r4+0xC] = r6
    movs    r1, r6                          @ 08021290 r1 = r6
    ldr     r0, [r4]                        @ 08021292 r0 = u32 [r4]
    bl      fat_clust2sect                  @ 08021294 call fat_clust2sect
    str     r0, [r4, #0x10]                 @ 08021298 u32 [r4+0x10] = r0
    @ index stored; entry pointer = window + 0x30 + (index & 15) * 32
.Lfat_dir_next_129A:                    @ v2.05 0x0802129A, reached from 0x080211A2, 0x080211BA, 0x080211CC
    strh    r7, [r4, #6]                    @ 0802129A u16 [r4+0x6] = r7
    ldr     r0, [r4]                        @ 0802129C r0 = u32 [r4]
    uxth    r7, r7                          @ 0802129E r7 = u16(r7)
    ands    r1, r7, #0xf                    @ 080212A0 r1 = r7 & 0xf
    lsls    r1, r1, #5                      @ 080212A4 r1 = r1 << 5
    add     r0, r1                          @ 080212A6 r0 += r1
    adds    r0, #0x30                       @ 080212A8 r0 += 0x30
    str     r0, [r4, #0x14]                 @ 080212AA u32 [r4+0x14] = r0
    movs    r0, #0                          @ 080212AC r0 = 0
.Lfat_dir_next_12AE:                    @ v2.05 0x080212AE, reached from 0x0802119C, 0x080211BE, 0x080211DE, 0x080211E8, 0x080211F8, 0x0802120A, 0x08021212, 0x0802121C, 0x0802122C, 0x0802126C
    pop.w   {r4, r5, r6, r7, r8, pc}        @ 080212AE pop {r4, r5, r6, r7, r8, pc}
ENDFUNC fat_dir_next
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_dir_find - find the directory entry whose name equals the 11 bytes at DIR +0x18 (FatFs dir_find)
@ Replaces  : 0x080212B2 FUN_080212B2 (v2.05), called by follow_path
@ In        : r0 = DIR pointer
@ Out       : r0 = 0 found (DIR +0x14 points to it), 4 not found, other = error of the walk
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080212B2..0x08021319
@ Note      : starts at index 0; entries with a first byte 0 end the search; long-name entries (attribute bit 3 set) are skipped.
@ -----------------------------------------------------------------------------
FUNC fat_dir_find
    push    {r3, r4, r5, r6, r7, lr}        @ 080212B2 push {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 080212B4 r4 = r0
    movs    r1, #0                          @ 080212B6 r1 = 0
    movs    r0, r4                          @ 080212B8 r0 = r4
    @ start at index 0
    bl      fat_dir_sdi                     @ 080212BA call fat_dir_sdi
    movs    r7, r0                          @ 080212BE r7 = r0
    uxtb    r7, r7                          @ 080212C0 r7 = u8(r7)
    cmp     r7, #0                          @ 080212C2 compare r7 with 0
    beq     .Lfat_dir_find_12CC             @ 080212C4 if (r7 == 0) goto 0x80212CC
    movs    r0, r7                          @ 080212C6 r0 = r7
    uxtb    r0, r0                          @ 080212C8 r0 = u8(r0)
    b       .Lfat_dir_find_1318             @ 080212CA goto 0x8021318
    @ loop: load the directory sector into the window (move_window)
.Lfat_dir_find_12CC:                    @ v2.05 0x080212CC, reached from 0x080212C4, 0x08021312
    ldr     r1, [r4, #0x10]                 @ 080212CC r1 = u32 [r4+0x10]
    ldr     r0, [r4]                        @ 080212CE r0 = u32 [r4]
    bl      fat_move_window                 @ 080212D0 call fat_move_window
    movs    r7, r0                          @ 080212D4 r7 = r0
    uxtb    r7, r7                          @ 080212D6 r7 = u8(r7)
    cmp     r7, #0                          @ 080212D8 compare r7 with 0
    bne     .Lfat_dir_find_1314             @ 080212DA if (r7 != 0) goto 0x8021314
    ldr     r0, [r4, #0x14]                 @ 080212DC r0 = u32 [r4+0x14]
    movs    r6, r0                          @ 080212DE r6 = r0
    ldrb    r0, [r6]                        @ 080212E0 r0 = u8 [r6]
    movs    r5, r0                          @ 080212E2 r5 = r0
    uxtb    r5, r5                          @ 080212E4 r5 = u8(r5)
    @ first byte 0: end of the directory (4)
    cmp     r5, #0                          @ 080212E6 compare r5 with 0
    bne     .Lfat_dir_find_12F0             @ 080212E8 if (r5 != 0) goto 0x80212F0
    movs    r0, #4                          @ 080212EA r0 = 4
    movs    r7, r0                          @ 080212EC r7 = r0
    b       .Lfat_dir_find_1314             @ 080212EE goto 0x8021314
.Lfat_dir_find_12F0:                    @ v2.05 0x080212F0, reached from 0x080212E8
    ldrb    r0, [r6, #0xb]                  @ 080212F0 r0 = u8 [r6+0xB]
    lsls    r0, r0, #0x1c                   @ 080212F2 r0 = r0 << 0x1c
    @ entries with attribute bit 3 (volume label, long name) are skipped; the others are compared with the 11-byte name (fat_mem_cmp), equal = found
    bmi     .Lfat_dir_find_1304             @ 080212F4 if (r0 <0 0) goto 0x8021304
    movs    r2, #0xb                        @ 080212F6 r2 = 0xb
    ldr     r1, [r4, #0x18]                 @ 080212F8 r1 = u32 [r4+0x18]
    movs    r0, r6                          @ 080212FA r0 = r6
    bl      fat_mem_cmp                     @ 080212FC call fat_mem_cmp
    cmp     r0, #0                          @ 08021300 compare r0 with 0
    beq     .Lfat_dir_find_1314             @ 08021302 if (r0 == 0) goto 0x8021314
.Lfat_dir_find_1304:                    @ v2.05 0x08021304, reached from 0x080212F4
    movs    r1, #0                          @ 08021304 r1 = 0
    movs    r0, r4                          @ 08021306 r0 = r4
    @ next entry (dir_next without stretching)
    bl      fat_dir_next                    @ 08021308 call fat_dir_next
    movs    r7, r0                          @ 0802130C r7 = r0
    uxtb    r7, r7                          @ 0802130E r7 = u8(r7)
    cmp     r7, #0                          @ 08021310 compare r7 with 0
    beq     .Lfat_dir_find_12CC             @ 08021312 if (r7 == 0) goto 0x80212CC
.Lfat_dir_find_1314:                    @ v2.05 0x08021314, reached from 0x080212DA, 0x080212EE, 0x08021302
    movs    r0, r7                          @ 08021314 r0 = r7
    uxtb    r0, r0                          @ 08021316 r0 = u8(r0)
.Lfat_dir_find_1318:                    @ v2.05 0x08021318, reached from 0x080212CA
    pop     {r1, r4, r5, r6, r7, pc}        @ 08021318 pop {r1, r4, r5, r6, r7, pc}
ENDFUNC fat_dir_find
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_dir_read - read the next valid directory entry (FatFs dir_read)
@ Replaces  : 0x0802131A FUN_0802131A (v2.05), called by f_readdir
@ In        : r0 = DIR pointer
@ Out       : r0 = 0 an entry is at DIR +0x14, 4 end of the directory (DIR +0x10 is set to 0), other = error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802131A..0x0802137D
@ Note      : skips deleted entries (first byte 0xE5), the "." entry and volume labels / long-name entries (attribute bit 3).
@ -----------------------------------------------------------------------------
FUNC fat_dir_read
    push    {r3, r4, r5, r6, r7, lr}        @ 0802131A push {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 0802131C r4 = r0
    movs    r0, #4                          @ 0802131E r0 = 4
    movs    r5, r0                          @ 08021320 r5 = r0
    @ loop over the entries of the directory (index 0 at the start of f_opendir/f_readdir)
.Lfat_dir_read_1322:                    @ v2.05 0x08021322, reached from 0x0802136C
    ldr     r0, [r4, #0x10]                 @ 08021322 r0 = u32 [r4+0x10]
    cmp     r0, #0                          @ 08021324 compare r0 with 0
    beq     .Lfat_dir_read_136E             @ 08021326 if (r0 == 0) goto 0x802136E
    ldr     r1, [r4, #0x10]                 @ 08021328 r1 = u32 [r4+0x10]
    ldr     r0, [r4]                        @ 0802132A r0 = u32 [r4]
    bl      fat_move_window                 @ 0802132C call fat_move_window
    movs    r5, r0                          @ 08021330 r5 = r0
    uxtb    r5, r5                          @ 08021332 r5 = u8(r5)
    cmp     r5, #0                          @ 08021334 compare r5 with 0
    bne     .Lfat_dir_read_136E             @ 08021336 if (r5 != 0) goto 0x802136E
    ldr     r0, [r4, #0x14]                 @ 08021338 r0 = u32 [r4+0x14]
    movs    r7, r0                          @ 0802133A r7 = r0
    ldrb    r0, [r7]                        @ 0802133C r0 = u8 [r7]
    movs    r6, r0                          @ 0802133E r6 = r0
    uxtb    r6, r6                          @ 08021340 r6 = u8(r6)
    @ first byte 0: end of the directory (4)
    cmp     r6, #0                          @ 08021342 compare r6 with 0
    bne     .Lfat_dir_read_134C             @ 08021344 if (r6 != 0) goto 0x802134C
    movs    r0, #4                          @ 08021346 r0 = 4
    movs    r5, r0                          @ 08021348 r5 = r0
    b       .Lfat_dir_read_136E             @ 0802134A goto 0x802136E
.Lfat_dir_read_134C:                    @ v2.05 0x0802134C, reached from 0x08021344
    uxtb    r6, r6                          @ 0802134C r6 = u8(r6)
    @ skip deleted entries (0xE5), "." and entries with attribute bit 3; anything else is the entry wanted
    cmp     r6, #0xe5                       @ 0802134E compare r6 with 0xe5
    beq     .Lfat_dir_read_135E             @ 08021350 if (r6 == 0xe5) goto 0x802135E
    uxtb    r6, r6                          @ 08021352 r6 = u8(r6)
    cmp     r6, #0x2e                       @ 08021354 compare r6 with 0x2e
    beq     .Lfat_dir_read_135E             @ 08021356 if (r6 == 0x2e) goto 0x802135E
    ldrb    r0, [r7, #0xb]                  @ 08021358 r0 = u8 [r7+0xB]
    lsls    r0, r0, #0x1c                   @ 0802135A r0 = r0 << 0x1c
    bpl     .Lfat_dir_read_136E             @ 0802135C if (r0 >=0 0) goto 0x802136E
.Lfat_dir_read_135E:                    @ v2.05 0x0802135E, reached from 0x08021350, 0x08021356
    movs    r1, #0                          @ 0802135E r1 = 0
    movs    r0, r4                          @ 08021360 r0 = r4
    @ next entry (dir_next without stretching)
    bl      fat_dir_next                    @ 08021362 call fat_dir_next
    movs    r5, r0                          @ 08021366 r5 = r0
    uxtb    r5, r5                          @ 08021368 r5 = u8(r5)
    cmp     r5, #0                          @ 0802136A compare r5 with 0
    beq     .Lfat_dir_read_1322             @ 0802136C if (r5 == 0) goto 0x8021322
.Lfat_dir_read_136E:                    @ v2.05 0x0802136E, reached from 0x08021326, 0x08021336, 0x0802134A, 0x0802135C
    uxtb    r5, r5                          @ 0802136E r5 = u8(r5)
    @ any error or the end of the directory: DIR +0x10 (sector) = 0
    cmp     r5, #0                          @ 08021370 compare r5 with 0
    beq     .Lfat_dir_read_1378             @ 08021372 if (r5 == 0) goto 0x8021378
    movs    r0, #0                          @ 08021374 r0 = 0
    str     r0, [r4, #0x10]                 @ 08021376 u32 [r4+0x10] = r0
.Lfat_dir_read_1378:                    @ v2.05 0x08021378, reached from 0x08021372
    movs    r0, r5                          @ 08021378 r0 = r5
    uxtb    r0, r0                          @ 0802137A r0 = u8(r0)
    pop     {r1, r4, r5, r6, r7, pc}        @ 0802137C pop {r1, r4, r5, r6, r7, pc}
ENDFUNC fat_dir_read
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_dir_register - reserve a free entry for the new name at DIR +0x18 (FatFs dir_register)
@ Replaces  : 0x0802137E FUN_0802137E (v2.05), called by f_open
@ In        : r0 = DIR pointer
@ Out       : r0 = 0 the entry is cleared and holds the name, 7 directory full, other = error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802137E..0x080213FF
@ Note      : finds the first deleted (0xE5) or end (0x00) entry, extending the directory with dir_next(1) as needed, then clears
@             the 32 bytes, copies the 11-character name into them and marks the window dirty.
@ -----------------------------------------------------------------------------
FUNC fat_dir_register
    push    {r3, r4, r5, r6, r7, lr}        @ 0802137E push {r3, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 08021380 r4 = r0
    movs    r1, #0                          @ 08021382 r1 = 0
    movs    r0, r4                          @ 08021384 r0 = r4
    @ search from index 0 for a free entry
    bl      fat_dir_sdi                     @ 08021386 call fat_dir_sdi
    movs    r5, r0                          @ 0802138A r5 = r0
    uxtb    r5, r5                          @ 0802138C r5 = u8(r5)
    cmp     r5, #0                          @ 0802138E compare r5 with 0
    bne     .Lfat_dir_register_13C6         @ 08021390 if (r5 != 0) goto 0x80213C6
    @ loop: load the sector; first byte 0xE5 (deleted) or 0 (never used) = free
.Lfat_dir_register_1392:                @ v2.05 0x08021392, reached from 0x080213C4
    ldr     r1, [r4, #0x10]                 @ 08021392 r1 = u32 [r4+0x10]
    ldr     r0, [r4]                        @ 08021394 r0 = u32 [r4]
    bl      fat_move_window                 @ 08021396 call fat_move_window
    movs    r5, r0                          @ 0802139A r5 = r0
    uxtb    r5, r5                          @ 0802139C r5 = u8(r5)
    cmp     r5, #0                          @ 0802139E compare r5 with 0
    bne     .Lfat_dir_register_13C6         @ 080213A0 if (r5 != 0) goto 0x80213C6
    ldr     r0, [r4, #0x14]                 @ 080213A2 r0 = u32 [r4+0x14]
    ldrb    r0, [r0]                        @ 080213A4 r0 = u8 [r0]
    movs    r6, r0                          @ 080213A6 r6 = r0
    uxtb    r6, r6                          @ 080213A8 r6 = u8(r6)
    cmp     r6, #0xe5                       @ 080213AA compare r6 with 0xe5
    beq     .Lfat_dir_register_13B4         @ 080213AC if (r6 == 0xe5) goto 0x80213B4
    uxtb    r6, r6                          @ 080213AE r6 = u8(r6)
    cmp     r6, #0                          @ 080213B0 compare r6 with 0
    bne     .Lfat_dir_register_13B6         @ 080213B2 if (r6 != 0) goto 0x80213B6
.Lfat_dir_register_13B4:                @ v2.05 0x080213B4, reached from 0x080213AC
    b       .Lfat_dir_register_13C6         @ 080213B4 goto 0x80213C6
.Lfat_dir_register_13B6:                @ v2.05 0x080213B6, reached from 0x080213B2
    movs    r1, #1                          @ 080213B6 r1 = 1
    movs    r0, r4                          @ 080213B8 r0 = r4
    @ next entry; dir_next(1) extends the directory when its end is reached
    bl      fat_dir_next                    @ 080213BA call fat_dir_next
    movs    r5, r0                          @ 080213BE r5 = r0
    uxtb    r5, r5                          @ 080213C0 r5 = u8(r5)
    cmp     r5, #0                          @ 080213C2 compare r5 with 0
    beq     .Lfat_dir_register_1392         @ 080213C4 if (r5 == 0) goto 0x8021392
.Lfat_dir_register_13C6:                @ v2.05 0x080213C6, reached from 0x08021390, 0x080213A0, 0x080213B4
    uxtb    r5, r5                          @ 080213C6 r5 = u8(r5)
    @ free entry found: load its sector, clear 32 bytes, copy the 11-byte name, mark the window dirty
    cmp     r5, #0                          @ 080213C8 compare r5 with 0
    bne     .Lfat_dir_register_13FA         @ 080213CA if (r5 != 0) goto 0x80213FA
    ldr     r1, [r4, #0x10]                 @ 080213CC r1 = u32 [r4+0x10]
    ldr     r0, [r4]                        @ 080213CE r0 = u32 [r4]
    bl      fat_move_window                 @ 080213D0 call fat_move_window
    movs    r5, r0                          @ 080213D4 r5 = r0
    uxtb    r5, r5                          @ 080213D6 r5 = u8(r5)
    cmp     r5, #0                          @ 080213D8 compare r5 with 0
    bne     .Lfat_dir_register_13FA         @ 080213DA if (r5 != 0) goto 0x80213FA
    ldr     r0, [r4, #0x14]                 @ 080213DC r0 = u32 [r4+0x14]
    movs    r7, r0                          @ 080213DE r7 = r0
    movs    r2, #0x20                       @ 080213E0 r2 = 0x20
    movs    r1, #0                          @ 080213E2 r1 = 0
    movs    r0, r7                          @ 080213E4 r0 = r7
    bl      fat_mem_set                     @ 080213E6 call fat_mem_set
    movs    r2, #0xb                        @ 080213EA r2 = 0xb
    ldr     r1, [r4, #0x18]                 @ 080213EC r1 = u32 [r4+0x18]
    movs    r0, r7                          @ 080213EE r0 = r7
    bl      fat_mem_cpy                     @ 080213F0 call fat_mem_cpy
    movs    r0, #1                          @ 080213F4 r0 = 1
    ldr     r1, [r4]                        @ 080213F6 r1 = u32 [r4]
    strb    r0, [r1, #4]                    @ 080213F8 u8 [r1+0x4] = r0
.Lfat_dir_register_13FA:                @ v2.05 0x080213FA, reached from 0x080213CA, 0x080213DA
    movs    r0, r5                          @ 080213FA r0 = r5
    uxtb    r0, r0                          @ 080213FC r0 = u8(r0)
    pop     {r1, r4, r5, r6, r7, pc}        @ 080213FE pop {r1, r4, r5, r6, r7, pc}
ENDFUNC fat_dir_register
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_create_name - convert the next path element into the 11-byte 8.3 name at DIR +0x18 (FatFs create_name)
@ Replaces  : 0x08021400 FUN_08021400 (v2.05), called by follow_path
@ In        : r0 = DIR pointer, r1 = pointer to the path pointer
@ Out       : r0 = 0 ok, 6 invalid name; the path pointer is moved behind the element
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads the table of forbidden characters v205_tab_08029164 (" * + , : ; < = > ? [ ] | 0x7F")
@ Spec      : v2.05 listing 0x08021400..0x0802156D
@ Note      : the name field is first filled with 11 blanks.  Upper case is applied to a-z; a dot starts the extension (at most
@             one, name part at most 8, extension at most 3 characters); a character below 0x21, "/" or "\" ends the element; double
@             byte characters (0x81..0x9F, 0xE0..0xFC lead bytes) are copied as pairs.  A first byte 0xE5 is stored as 0x05.  The
@             case information is collected in a flag byte that is stored in byte 11 of the name field: 0x04 the element is the
@             last of the path, 0x10 the base name was entered in lower case only, 0x08 the extension was entered in lower case only
@             (the FatFs NT case bits; v2.05 stores them in the name field only).  An empty name is invalid.
@ -----------------------------------------------------------------------------
FUNC fat_create_name
    push.w  {r0, r4, r5, r6, r7, r8, r9, r10, r11, lr}@ 08021400 push {r0, r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub     sp, #8                          @ 08021404 sp -= 8
    movs    r4, r1                          @ 08021406 r4 = r1
    ldr     r0, [sp, #8]                    @ 08021408 r0 = u32 [sp+0x8]
    ldr     r0, [r0, #0x18]                 @ 0802140A r0 = u32 [r0+0x18]
    mov     r8, r0                          @ 0802140C r8 = r0
    movs    r2, #0xb                        @ 0802140E r2 = 0xb
    movs    r1, #0x20                       @ 08021410 r1 = 0x20
    mov     r0, r8                          @ 08021412 r0 = r8
    @ name field (DIR +0x18 points to it) filled with 11 blanks
    bl      fat_mem_set                     @ 08021414 call fat_mem_set
    movs    r0, #0                          @ 08021418 r0 = 0
    movs    r5, r0                          @ 0802141A r5 = r0
    uxtb    r5, r5                          @ 0802141C r5 = u8(r5)
    mov     r11, r5                         @ 0802141E r11 = r5
    mov     r10, r11                        @ 08021420 r10 = r11
    movs    r0, #8                          @ 08021422 r0 = 8
    mov     r9, r0                          @ 08021424 r9 = r0
    ldr     r0, [r4]                        @ 08021426 r0 = u32 [r4]
    str     r0, [sp]                        @ 08021428 u32 [sp] = r0
    @ next character c of the path (r10 = index); r9 = limit of the part (8 for the name, 11 for the extension), r11 = write index
.Lfat_create_name_142A:                 @ v2.05 0x0802142A, reached from 0x0802147A, 0x080214DE, 0x08021520
    ldr     r0, [sp]                        @ 0802142A r0 = u32 [sp]
    ldrb.w  r0, [r0, r10]                   @ 0802142C r0 = u8 [r0+r10]
    movs    r6, r0                          @ 08021430 r6 = r0
    adds.w  r10, r10, #1                    @ 08021432 r10 = r10 + 1
    uxtb    r6, r6                          @ 08021436 r6 = u8(r6)
    @ c below 0x21, "/" or "\": end of the element
    cmp     r6, #0x21                       @ 08021438 compare r6 with 0x21
    blt     .Lfat_create_name_1448          @ 0802143A if (r6 < 0x21) goto 0x8021448
    uxtb    r6, r6                          @ 0802143C r6 = u8(r6)
    cmp     r6, #0x2f                       @ 0802143E compare r6 with 0x2f
    beq     .Lfat_create_name_1448          @ 08021440 if (r6 == 0x2f) goto 0x8021448
    uxtb    r6, r6                          @ 08021442 r6 = u8(r6)
    cmp     r6, #0x5c                       @ 08021444 compare r6 with 0x5c
    bne     .Lfat_create_name_1456          @ 08021446 if (r6 != 0x5c) goto 0x8021456
.Lfat_create_name_1448:                 @ v2.05 0x08021448, reached from 0x0802143A, 0x08021440
    ldr     r0, [sp]                        @ 08021448 r0 = u32 [sp]
    add     r0, r10                         @ 0802144A r0 += r10
    str     r0, [r4]                        @ 0802144C u32 [r4] = r0
    uxtb    r6, r6                          @ 0802144E r6 = u8(r6)
    cmp     r6, #0x21                       @ 08021450 compare r6 with 0x21
    bge     .Lfat_create_name_1526          @ 08021452 if (r6 >= 0x21) goto 0x8021526
    b       .Lfat_create_name_1522          @ 08021454 goto 0x8021522
    @ c is "." or the part is full: a dot is only valid in the name part (limit 8), it switches to the extension part; anything else is invalid (6)
.Lfat_create_name_1456:                 @ v2.05 0x08021456, reached from 0x08021446
    uxtb    r6, r6                          @ 08021456 r6 = u8(r6)
    cmp     r6, #0x2e                       @ 08021458 compare r6 with 0x2e
    beq     .Lfat_create_name_1460          @ 0802145A if (r6 == 0x2e) goto 0x8021460
    cmp     r11, r9                         @ 0802145C compare r11 with r9
    blo     .Lfat_create_name_147C          @ 0802145E if (r11 <u r9) goto 0x802147C
.Lfat_create_name_1460:                 @ v2.05 0x08021460, reached from 0x0802145A
    cmp.w   r9, #8                          @ 08021460 compare r9 with 8
    bne     .Lfat_create_name_146C          @ 08021464 if (r9 != 8) goto 0x802146C
    uxtb    r6, r6                          @ 08021466 r6 = u8(r6)
    cmp     r6, #0x2e                       @ 08021468 compare r6 with 0x2e
    beq     .Lfat_create_name_1470          @ 0802146A if (r6 == 0x2e) goto 0x8021470
.Lfat_create_name_146C:                 @ v2.05 0x0802146C, reached from 0x08021464
    movs    r0, #6                          @ 0802146C r0 = 6
    b       .Lfat_create_name_156A          @ 0802146E goto 0x802156A
.Lfat_create_name_1470:                 @ v2.05 0x08021470, reached from 0x0802146A
    movs    r0, #8                          @ 08021470 r0 = 8
    mov     r11, r0                         @ 08021472 r11 = r0
    movs    r0, #0xb                        @ 08021474 r0 = 0xb
    mov     r9, r0                          @ 08021476 r9 = r0
    lsls    r5, r5, #2                      @ 08021478 r5 = r5 << 2
    b       .Lfat_create_name_142A          @ 0802147A goto 0x802142A
.Lfat_create_name_147C:                 @ v2.05 0x0802147C, reached from 0x0802145E
    uxtb    r6, r6                          @ 0802147C r6 = u8(r6)
    @ ordinary character: c >= 0x80 sets both case flag bits (r8 |= 3)
    cmp     r6, #0x80                       @ 0802147E compare r6 with 0x80
    blt     .Lfat_create_name_1486          @ 08021480 if (r6 < 0x80) goto 0x8021486
    orrs    r5, r5, #3                      @ 08021482 r5 = r5 | 3
.Lfat_create_name_1486:                 @ v2.05 0x08021486, reached from 0x08021480
    uxtb    r6, r6                          @ 08021486 r6 = u8(r6)
    @ lead byte of a double byte character (0x81..0x9F or 0xE0..0xFC): the second byte (0x40..0x7E or 0x80..0xFC) must fit in the part, both are copied
    cmp     r6, #0x81                       @ 08021488 compare r6 with 0x81
    blt     .Lfat_create_name_1492          @ 0802148A if (r6 < 0x81) goto 0x8021492
    uxtb    r6, r6                          @ 0802148C r6 = u8(r6)
    cmp     r6, #0xa0                       @ 0802148E compare r6 with 0xa0
    blt     .Lfat_create_name_149E          @ 08021490 if (r6 < 0xa0) goto 0x802149E
.Lfat_create_name_1492:                 @ v2.05 0x08021492, reached from 0x0802148A
    uxtb    r6, r6                          @ 08021492 r6 = u8(r6)
    cmp     r6, #0xe0                       @ 08021494 compare r6 with 0xe0
    blt     .Lfat_create_name_14E0          @ 08021496 if (r6 < 0xe0) goto 0x80214E0
    uxtb    r6, r6                          @ 08021498 r6 = u8(r6)
    cmp     r6, #0xfd                       @ 0802149A compare r6 with 0xfd
    bge     .Lfat_create_name_14E0          @ 0802149C if (r6 >= 0xfd) goto 0x80214E0
.Lfat_create_name_149E:                 @ v2.05 0x0802149E, reached from 0x08021490
    ldr     r0, [sp]                        @ 0802149E r0 = u32 [sp]
    ldrb.w  r0, [r0, r10]                   @ 080214A0 r0 = u8 [r0+r10]
    movs    r7, r0                          @ 080214A4 r7 = r0
    adds.w  r10, r10, #1                    @ 080214A6 r10 = r10 + 1
    uxtb    r7, r7                          @ 080214AA r7 = u8(r7)
    cmp     r7, #0x40                       @ 080214AC compare r7 with 0x40
    blt     .Lfat_create_name_14B6          @ 080214AE if (r7 < 0x40) goto 0x80214B6
    uxtb    r7, r7                          @ 080214B0 r7 = u8(r7)
    cmp     r7, #0x7f                       @ 080214B2 compare r7 with 0x7f
    blt     .Lfat_create_name_14C2          @ 080214B4 if (r7 < 0x7f) goto 0x80214C2
.Lfat_create_name_14B6:                 @ v2.05 0x080214B6, reached from 0x080214AE
    uxtb    r7, r7                          @ 080214B6 r7 = u8(r7)
    cmp     r7, #0x80                       @ 080214B8 compare r7 with 0x80
    blt     .Lfat_create_name_14CA          @ 080214BA if (r7 < 0x80) goto 0x80214CA
    uxtb    r7, r7                          @ 080214BC r7 = u8(r7)
    cmp     r7, #0xfd                       @ 080214BE compare r7 with 0xfd
    bge     .Lfat_create_name_14CA          @ 080214C0 if (r7 >= 0xfd) goto 0x80214CA
.Lfat_create_name_14C2:                 @ v2.05 0x080214C2, reached from 0x080214B4
    subs.w  r0, r9, #1                      @ 080214C2 r0 = r9 - 1
    cmp     r11, r0                         @ 080214C6 compare r11 with r0
    blo     .Lfat_create_name_14CE          @ 080214C8 if (r11 <u r0) goto 0x80214CE
.Lfat_create_name_14CA:                 @ v2.05 0x080214CA, reached from 0x080214BA, 0x080214C0
    movs    r0, #6                          @ 080214CA r0 = 6
    b       .Lfat_create_name_156A          @ 080214CC goto 0x802156A
.Lfat_create_name_14CE:                 @ v2.05 0x080214CE, reached from 0x080214C8
    strb.w  r6, [r8, r11]                   @ 080214CE u8 [r8+r11] = r6
    adds.w  r11, r11, #1                    @ 080214D2 r11 = r11 + 1
    strb.w  r7, [r8, r11]                   @ 080214D6 u8 [r8+r11] = r7
    adds.w  r11, r11, #1                    @ 080214DA r11 = r11 + 1
    b       .Lfat_create_name_142A          @ 080214DE goto 0x802142A
    @ single byte character: a character of the forbidden list v205_tab_08029164 makes the name invalid (6)
.Lfat_create_name_14E0:                 @ v2.05 0x080214E0, reached from 0x08021496, 0x0802149C
    uxtb    r6, r6                          @ 080214E0 r6 = u8(r6)
    movs    r1, r6                          @ 080214E2 r1 = r6
    ldr.w   r0, =v205_tab_08029164          @ 080214E4 r0 = &v205_tab_08029164
    bl      fat_chk_chr                     @ 080214E8 call fat_chk_chr
    cmp     r0, #0                          @ 080214EC compare r0 with 0
    beq     .Lfat_create_name_14F4          @ 080214EE if (r0 == 0) goto 0x80214F4
    movs    r0, #6                          @ 080214F0 r0 = 6
    b       .Lfat_create_name_156A          @ 080214F2 goto 0x802156A
.Lfat_create_name_14F4:                 @ v2.05 0x080214F4, reached from 0x080214EE
    uxtb    r6, r6                          @ 080214F4 r6 = u8(r6)
    @ "A".."Z" sets flag bit 2, "a".."z" sets flag bit 1 and is converted to upper case
    cmp     r6, #0x41                       @ 080214F6 compare r6 with 0x41
    blt     .Lfat_create_name_1506          @ 080214F8 if (r6 < 0x41) goto 0x8021506
    uxtb    r6, r6                          @ 080214FA r6 = u8(r6)
    cmp     r6, #0x5b                       @ 080214FC compare r6 with 0x5b
    bge     .Lfat_create_name_1506          @ 080214FE if (r6 >= 0x5b) goto 0x8021506
    orrs    r5, r5, #2                      @ 08021500 r5 = r5 | 2
    b       .Lfat_create_name_1518          @ 08021504 goto 0x8021518
.Lfat_create_name_1506:                 @ v2.05 0x08021506, reached from 0x080214F8, 0x080214FE
    uxtb    r6, r6                          @ 08021506 r6 = u8(r6)
    cmp     r6, #0x61                       @ 08021508 compare r6 with 0x61
    blt     .Lfat_create_name_1518          @ 0802150A if (r6 < 0x61) goto 0x8021518
    uxtb    r6, r6                          @ 0802150C r6 = u8(r6)
    cmp     r6, #0x7b                       @ 0802150E compare r6 with 0x7b
    bge     .Lfat_create_name_1518          @ 08021510 if (r6 >= 0x7b) goto 0x8021518
    orrs    r5, r5, #1                      @ 08021512 r5 = r5 | 1
    subs    r6, #0x20                       @ 08021516 r6 -= 0x20
.Lfat_create_name_1518:                 @ v2.05 0x08021518, reached from 0x08021504, 0x0802150A, 0x08021510
    strb.w  r6, [r8, r11]                   @ 08021518 u8 [r8+r11] = r6
    adds.w  r11, r11, #1                    @ 0802151C r11 = r11 + 1
    b       .Lfat_create_name_142A          @ 08021520 goto 0x802142A
    @ end of the element: the path pointer is moved behind the separator; flag 0x04 (last element) when c < 0x21
.Lfat_create_name_1522:                 @ v2.05 0x08021522, reached from 0x08021454
    movs    r6, #4                          @ 08021522 r6 = 4
    b       .Lfat_create_name_1528          @ 08021524 goto 0x8021528
.Lfat_create_name_1526:                 @ v2.05 0x08021526, reached from 0x08021452
    movs    r6, #0                          @ 08021526 r6 = 0
    @ nothing written (empty name): invalid (6)
.Lfat_create_name_1528:                 @ v2.05 0x08021528, reached from 0x08021524
    cmp.w   r11, #0                         @ 08021528 compare r11 with 0
    bne     .Lfat_create_name_1532          @ 0802152C if (r11 != 0) goto 0x8021532
    movs    r0, #6                          @ 0802152E r0 = 6
    b       .Lfat_create_name_156A          @ 08021530 goto 0x802156A
.Lfat_create_name_1532:                 @ v2.05 0x08021532, reached from 0x0802152C
    ldrb.w  r0, [r8]                        @ 08021532 r0 = u8 [r8]
    @ a first byte 0xE5 is stored as 0x05
    cmp     r0, #0xe5                       @ 08021536 compare r0 with 0xe5
    bne     .Lfat_create_name_1540          @ 08021538 if (r0 != 0xe5) goto 0x8021540
    movs    r0, #5                          @ 0802153A r0 = 5
    strb.w  r0, [r8]                        @ 0802153C u8 [r8] = r0
    @ no extension seen: the case flags are shifted to the extension position; body in lower case only -> flag 0x10, extension in lower case only -> flag 0x08 (1554, 1562)
.Lfat_create_name_1540:                 @ v2.05 0x08021540, reached from 0x08021538
    cmp.w   r9, #8                          @ 08021540 compare r9 with 8
    bne     .Lfat_create_name_1548          @ 08021544 if (r9 != 8) goto 0x8021548
    lsls    r5, r5, #2                      @ 08021546 r5 = r5 << 2
.Lfat_create_name_1548:                 @ v2.05 0x08021548, reached from 0x08021544
    uxtb    r5, r5                          @ 08021548 r5 = u8(r5)
    ands    r0, r5, #3                      @ 0802154A r0 = r5 & 3
    cmp     r0, #1                          @ 0802154E compare r0 with 1
    bne     .Lfat_create_name_1556          @ 08021550 if (r0 != 1) goto 0x8021556
    orrs    r6, r6, #0x10                   @ 08021552 r6 = r6 | 0x10
.Lfat_create_name_1556:                 @ v2.05 0x08021556, reached from 0x08021550
    uxtb    r5, r5                          @ 08021556 r5 = u8(r5)
    ands    r0, r5, #0xc                    @ 08021558 r0 = r5 & 0xc
    cmp     r0, #4                          @ 0802155C compare r0 with 4
    bne     .Lfat_create_name_1564          @ 0802155E if (r0 != 4) goto 0x8021564
    orrs    r6, r6, #8                      @ 08021560 r6 = r6 | 8
.Lfat_create_name_1564:                 @ v2.05 0x08021564, reached from 0x0802155E
    strb.w  r6, [r8, #0xb]                  @ 08021564 u8 [r8+0xB] = r6
    movs    r0, #0                          @ 08021568 r0 = 0
    @ return: r0 = 0 ok, 6 invalid name
.Lfat_create_name_156A:                 @ v2.05 0x0802156A, reached from 0x0802146E, 0x080214CC, 0x080214F2, 0x08021530
    pop.w   {r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}@ 0802156A pop {r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC fat_create_name
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_get_fileinfo - fill a FILINFO from the directory entry at DIR +0x14 (FatFs get_fileinfo)
@ Replaces  : 0x0802156E FUN_0802156E (v2.05), called by f_readdir and f_stat
@ In        : r0 = DIR pointer, r1 = FILINFO pointer
@ Out       : -
@ Clobbers  : r2-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802156E..0x08021611
@ Note      : if the DIR has an entry (DIR +0x10 != 0) the name is converted to "NAME.EXT" (blanks removed, 0x05 -> 0xE5, a dot when
@             the extension is not blank), the attribute, size (bytes 28..31), date (24, 25) and time (22, 23) are copied; the name is
@             NUL-terminated in every case (the first byte is 0 for an invalid entry).
@ -----------------------------------------------------------------------------
FUNC fat_get_fileinfo
    push    {r4, r5, r6, r7}                @ 0802156E push {r4, r5, r6, r7}
    adds.w  r7, r1, #9                      @ 08021570 r7 = r1 + 9
    movs    r5, r7                          @ 08021574 r5 = r7
    ldr     r7, [r0, #0x10]                 @ 08021576 r7 = u32 [r0+0x10]
    @ DIR +0x10 (sector) = 0 means no entry: only the terminating NUL is written
    cmp     r7, #0                          @ 08021578 compare r7 with 0
    beq     .Lfat_get_fileinfo_160A         @ 0802157A if (r7 == 0) goto 0x802160A
    ldr     r7, [r0, #0x14]                 @ 0802157C r7 = u32 [r0+0x14]
    movs    r3, r7                          @ 0802157E r3 = r7
    ldrb    r7, [r3, #0xc]                  @ 08021580 r7 = u8 [r3+0xC]
    movs    r2, r7                          @ 08021582 r2 = r7
    movs    r7, #0                          @ 08021584 r7 = 0
    movs    r6, r7                          @ 08021586 r6 = r7
    @ base name: up to 8 characters, stopping at a blank; 0x05 becomes 0xE5
.Lfat_get_fileinfo_1588:                @ v2.05 0x08021588, reached from 0x080215A6
    cmp     r6, #8                          @ 08021588 compare r6 with 8
    bhs     .Lfat_get_fileinfo_15A8         @ 0802158A if (r6 >=u 8) goto 0x80215A8
    ldrb    r7, [r3, r6]                    @ 0802158C r7 = u8 [r3+r6]
    movs    r4, r7                          @ 0802158E r4 = r7
    uxtb    r4, r4                          @ 08021590 r4 = u8(r4)
    cmp     r4, #0x20                       @ 08021592 compare r4 with 0x20
    beq     .Lfat_get_fileinfo_15A8         @ 08021594 if (r4 == 0x20) goto 0x80215A8
    uxtb    r4, r4                          @ 08021596 r4 = u8(r4)
    cmp     r4, #5                          @ 08021598 compare r4 with 5
    bne     .Lfat_get_fileinfo_15A0         @ 0802159A if (r4 != 5) goto 0x80215A0
    movs    r7, #0xe5                       @ 0802159C r7 = 0xe5
    movs    r4, r7                          @ 0802159E r4 = r7
.Lfat_get_fileinfo_15A0:                @ v2.05 0x080215A0, reached from 0x0802159A
    strb    r4, [r5]                        @ 080215A0 u8 [r5] = r4
    adds    r5, r5, #1                      @ 080215A2 r5 = r5 + 1
    adds    r6, r6, #1                      @ 080215A4 r6 = r6 + 1
    b       .Lfat_get_fileinfo_1588         @ 080215A6 goto 0x8021588
.Lfat_get_fileinfo_15A8:                @ v2.05 0x080215A8, reached from 0x0802158A, 0x08021594
    ldrb    r7, [r3, #8]                    @ 080215A8 r7 = u8 [r3+0x8]
    @ extension: a "." and up to 3 characters, stopping at a blank, when the extension is not blank
    cmp     r7, #0x20                       @ 080215AA compare r7 with 0x20
    beq     .Lfat_get_fileinfo_15CE         @ 080215AC if (r7 == 0x20) goto 0x80215CE
    movs    r7, #0x2e                       @ 080215AE r7 = 0x2e
    strb    r7, [r5]                        @ 080215B0 u8 [r5] = r7
    adds    r5, r5, #1                      @ 080215B2 r5 = r5 + 1
    movs    r7, #8                          @ 080215B4 r7 = 8
    movs    r6, r7                          @ 080215B6 r6 = r7
.Lfat_get_fileinfo_15B8:                @ v2.05 0x080215B8, reached from 0x080215CC
    cmp     r6, #0xb                        @ 080215B8 compare r6 with 0xb
    bhs     .Lfat_get_fileinfo_15CE         @ 080215BA if (r6 >=u 0xb) goto 0x80215CE
    ldrb    r7, [r3, r6]                    @ 080215BC r7 = u8 [r3+r6]
    movs    r4, r7                          @ 080215BE r4 = r7
    uxtb    r4, r4                          @ 080215C0 r4 = u8(r4)
    cmp     r4, #0x20                       @ 080215C2 compare r4 with 0x20
    beq     .Lfat_get_fileinfo_15CE         @ 080215C4 if (r4 == 0x20) goto 0x80215CE
    strb    r4, [r5]                        @ 080215C6 u8 [r5] = r4
    adds    r5, r5, #1                      @ 080215C8 r5 = r5 + 1
    adds    r6, r6, #1                      @ 080215CA r6 = r6 + 1
    b       .Lfat_get_fileinfo_15B8         @ 080215CC goto 0x80215B8
.Lfat_get_fileinfo_15CE:                @ v2.05 0x080215CE, reached from 0x080215AC, 0x080215BA, 0x080215C4
    ldrb    r7, [r3, #0xb]                  @ 080215CE r7 = u8 [r3+0xB]
    strb    r7, [r1, #8]                    @ 080215D0 u8 [r1+0x8] = r7
    ldrb    r7, [r3, #0x1f]                 @ 080215D2 r7 = u8 [r3+0x1F]
    ldrb.w  r12, [r3, #0x1e]                @ 080215D4 r12 = u8 [r3+0x1E]
    lsls.w  r12, r12, #0x10                 @ 080215D8 r12 = r12 << 0x10
    orrs.w  r7, r12, r7, lsl #24            @ 080215DC r7 = r12 | r7, lsl #24
    ldrb.w  r12, [r3, #0x1d]                @ 080215E0 r12 = u8 [r3+0x1D]
    orrs.w  r7, r7, r12, lsl #8             @ 080215E4 r7 = r7 | r12, lsl #8
    ldrb.w  r12, [r3, #0x1c]                @ 080215E8 r12 = u8 [r3+0x1C]
    orrs.w  r7, r12, r7                     @ 080215EC r7 = r12 | r7
    str     r7, [r1]                        @ 080215F0 u32 [r1] = r7
    ldrb    r7, [r3, #0x19]                 @ 080215F2 r7 = u8 [r3+0x19]
    ldrb.w  r12, [r3, #0x18]                @ 080215F4 r12 = u8 [r3+0x18]
    orrs.w  r7, r12, r7, lsl #8             @ 080215F8 r7 = r12 | r7, lsl #8
    strh    r7, [r1, #4]                    @ 080215FC u16 [r1+0x4] = r7
    ldrb    r7, [r3, #0x17]                 @ 080215FE r7 = u8 [r3+0x17]
    ldrb.w  r12, [r3, #0x16]                @ 08021600 r12 = u8 [r3+0x16]
    orrs.w  r7, r12, r7, lsl #8             @ 08021604 r7 = r12 | r7, lsl #8
    strh    r7, [r1, #6]                    @ 08021608 u16 [r1+0x6] = r7
    @ NUL terminator of the name
.Lfat_get_fileinfo_160A:                @ v2.05 0x0802160A, reached from 0x0802157A
    movs    r7, #0                          @ 0802160A r7 = 0
    strb    r7, [r5]                        @ 0802160C u8 [r5] = r7
    pop     {r4, r5, r6, r7}                @ 0802160E pop {r4, r5, r6, r7}
    bx      lr                              @ 08021610 return
ENDFUNC fat_get_fileinfo
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_follow_path - walk the path r1 from the root directory to the last element (FatFs follow_path)
@ Replaces  : 0x08021612 FUN_08021612 (v2.05), called by f_open, f_opendir, f_stat, f_utime
@ In        : r0 = DIR pointer (DIR +0x18 must point to a 12-byte name buffer), r1 = path (after the drive prefix)
@ Out       : r0 = 0 found (DIR +0x14 = entry, or 0 for the root), 4 the last element does not exist, 5 an element before the last
@             does not exist or is not a directory, 6 invalid name, other = error of the walk
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08021612..0x080216B1
@ Note      : a leading "/" or "\" is skipped; DIR +8 (start cluster) is 0 for the root.  Each element is converted with
@             create_name and searched with dir_find.  A path that is empty after the prefix leads to the root (dir_sdi(0), entry = 0).
@             A missing element gives 4 when it is the last one (flag 0x04 in byte 11 of the name field) and 5 otherwise.  A found
@             element that is not the last one must have the directory attribute (0x10), else 5; its start cluster (bytes 20/21 and
@             26/27) becomes the start cluster of the next search.
@ -----------------------------------------------------------------------------
FUNC fat_follow_path
    push    {r1, r4, r5, r6, r7, lr}        @ 08021612 push {r1, r4, r5, r6, r7, lr}
    movs    r4, r0                          @ 08021614 r4 = r0
    ldr     r0, [sp]                        @ 08021616 r0 = u32 [sp]
    ldrb    r0, [r0]                        @ 08021618 r0 = u8 [r0]
    @ skip one leading "/" or "\"
    cmp     r0, #0x2f                       @ 0802161A compare r0 with 0x2f
    beq     .Lfat_follow_path_1626          @ 0802161C if (r0 == 0x2f) goto 0x8021626
    ldr     r0, [sp]                        @ 0802161E r0 = u32 [sp]
    ldrb    r0, [r0]                        @ 08021620 r0 = u8 [r0]
    cmp     r0, #0x5c                       @ 08021622 compare r0 with 0x5c
    bne     .Lfat_follow_path_162C          @ 08021624 if (r0 != 0x5c) goto 0x802162C
.Lfat_follow_path_1626:                 @ v2.05 0x08021626, reached from 0x0802161C
    ldr     r0, [sp]                        @ 08021626 r0 = u32 [sp]
    adds    r0, r0, #1                      @ 08021628 r0 = r0 + 1
    str     r0, [sp]                        @ 0802162A u32 [sp] = r0
    @ DIR start cluster = 0 (root)
.Lfat_follow_path_162C:                 @ v2.05 0x0802162C, reached from 0x08021624
    movs    r0, #0                          @ 0802162C r0 = 0
    str     r0, [r4, #8]                    @ 0802162E u32 [r4+0x8] = r0
    ldr     r0, [sp]                        @ 08021630 r0 = u32 [sp]
    ldrb    r0, [r0]                        @ 08021632 r0 = u8 [r0]
    @ path now empty (first character below 0x20): the root directory itself, entry pointer 0
    cmp     r0, #0x20                       @ 08021634 compare r0 with 0x20
    bhs     .Lfat_follow_path_1648          @ 08021636 if (r0 >=u 0x20) goto 0x8021648
    movs    r1, #0                          @ 08021638 r1 = 0
    movs    r0, r4                          @ 0802163A r0 = r4
    bl      fat_dir_sdi                     @ 0802163C call fat_dir_sdi
    movs    r5, r0                          @ 08021640 r5 = r0
    movs    r0, #0                          @ 08021642 r0 = 0
    str     r0, [r4, #0x14]                 @ 08021644 u32 [r4+0x14] = r0
    b       .Lfat_follow_path_16AC          @ 08021646 goto 0x80216AC
.Lfat_follow_path_1648:                 @ v2.05 0x08021648, reached from 0x08021636, 0x080216AA
    mov     r1, sp                          @ 08021648 r1 = sp
    movs    r0, r4                          @ 0802164A r0 = r4
    @ create_name: next element into the name field
    bl      fat_create_name                 @ 0802164C call fat_create_name
    movs    r5, r0                          @ 08021650 r5 = r0
    uxtb    r5, r5                          @ 08021652 r5 = u8(r5)
    cmp     r5, #0                          @ 08021654 compare r5 with 0
    bne     .Lfat_follow_path_16AC          @ 08021656 if (r5 != 0) goto 0x80216AC
    movs    r0, r4                          @ 08021658 r0 = r4
    @ dir_find in the current directory
    bl      fat_dir_find                    @ 0802165A call fat_dir_find
    movs    r5, r0                          @ 0802165E r5 = r0
    ldr     r0, [r4, #0x18]                 @ 08021660 r0 = u32 [r4+0x18]
    ldrb    r0, [r0, #0xb]                  @ 08021662 r0 = u8 [r0+0xB]
    movs    r7, r0                          @ 08021664 r7 = r0
    uxtb    r5, r5                          @ 08021666 r5 = u8(r5)
    @ not found: error 4 becomes 5 unless the element was the last one (name flag 0x04)
    cmp     r5, #0                          @ 08021668 compare r5 with 0
    beq     .Lfat_follow_path_167C          @ 0802166A if (r5 == 0) goto 0x802167C
    uxtb    r5, r5                          @ 0802166C r5 = u8(r5)
    cmp     r5, #4                          @ 0802166E compare r5 with 4
    bne     .Lfat_follow_path_16AC          @ 08021670 if (r5 != 4) goto 0x80216AC
    lsls    r0, r7, #0x1d                   @ 08021672 r0 = r7 << 0x1d
    bmi     .Lfat_follow_path_167A          @ 08021674 if (r0 <0 0) goto 0x802167A
    movs    r0, #5                          @ 08021676 r0 = 5
    movs    r5, r0                          @ 08021678 r5 = r0
.Lfat_follow_path_167A:                 @ v2.05 0x0802167A, reached from 0x08021674
    b       .Lfat_follow_path_16AC          @ 0802167A goto 0x80216AC
    @ found: the last element ends the walk successfully
.Lfat_follow_path_167C:                 @ v2.05 0x0802167C, reached from 0x0802166A
    lsls    r0, r7, #0x1d                   @ 0802167C r0 = r7 << 0x1d
    bmi     .Lfat_follow_path_16AC          @ 0802167E if (r0 <0 0) goto 0x80216AC
    ldr     r0, [r4, #0x14]                 @ 08021680 r0 = u32 [r4+0x14]
    movs    r6, r0                          @ 08021682 r6 = r0
    ldrb    r0, [r6, #0xb]                  @ 08021684 r0 = u8 [r6+0xB]
    lsls    r0, r0, #0x1b                   @ 08021686 r0 = r0 << 0x1b
    @ an element before the last must be a directory (attribute bit 4), else 5
    bmi     .Lfat_follow_path_1690          @ 08021688 if (r0 <0 0) goto 0x8021690
    movs    r0, #5                          @ 0802168A r0 = 5
    movs    r5, r0                          @ 0802168C r5 = r0
    b       .Lfat_follow_path_16AC          @ 0802168E goto 0x80216AC
.Lfat_follow_path_1690:                 @ v2.05 0x08021690, reached from 0x08021688
    ldrb    r0, [r6, #0x15]                 @ 08021690 r0 = u8 [r6+0x15]
    @ its start cluster (bytes 20/21 high, 26/27 low) becomes the start cluster of the next search; repeat from 1648
    ldrb    r1, [r6, #0x14]                 @ 08021692 r1 = u8 [r6+0x14]
    orrs.w  r0, r1, r0, lsl #8              @ 08021694 r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08021698 r0 = u16(r0)
    ldrb    r1, [r6, #0x1b]                 @ 0802169A r1 = u8 [r6+0x1B]
    ldrb    r2, [r6, #0x1a]                 @ 0802169C r2 = u8 [r6+0x1A]
    orrs.w  r1, r2, r1, lsl #8              @ 0802169E r1 = r2 | r1, lsl #8
    uxth    r1, r1                          @ 080216A2 r1 = u16(r1)
    orrs.w  r0, r1, r0, lsl #16             @ 080216A4 r0 = r1 | r0, lsl #16
    str     r0, [r4, #8]                    @ 080216A8 u32 [r4+0x8] = r0
    b       .Lfat_follow_path_1648          @ 080216AA goto 0x8021648
.Lfat_follow_path_16AC:                 @ v2.05 0x080216AC, reached from 0x08021646, 0x08021656, 0x08021670, 0x0802167A, 0x0802167E, 0x0802168E
    movs    r0, r5                          @ 080216AC r0 = r5
    uxtb    r0, r0                          @ 080216AE r0 = u8(r0)
    pop     {r1, r4, r5, r6, r7, pc}        @ 080216B0 pop {r1, r4, r5, r6, r7, pc}
ENDFUNC fat_follow_path
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_check_fs - check whether the sector r1 is a FAT boot sector (FatFs check_fs)
@ Replaces  : 0x080216B2 FUN_080216B2 (v2.05), called by chk_mounted
@ In        : r0 = FATFS pointer, r1 = sector number
@ Out       : r0 = 0 a FAT boot sector, 1 a valid sector 0xAA55 but not a FAT boot sector (may be a partition table), 2 no valid signature, 3 disk error
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080216B2..0x0802172B
@ Note      : reads the sector into the window and checks the signature 0xAA55 at offset 0x1FE and the strings "FAT" (0x544146 =
@             "FAT\0" masked to three characters) at offset 0x36 (FAT12/16) and 0x52 (FAT32).
@ -----------------------------------------------------------------------------
FUNC fat_check_fs
    push    {r3, r4, r5, lr}                @ 080216B2 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 080216B4 r4 = r0
    movs    r5, r1                          @ 080216B6 r5 = r1
    movs    r3, #1                          @ 080216B8 r3 = 1
    movs    r2, r5                          @ 080216BA r2 = r5
    adds.w  r1, r4, #0x30                   @ 080216BC r1 = r4 + 0x30
    ldrb    r0, [r4, #1]                    @ 080216C0 r0 = u8 [r4+0x1]
    @ read the sector into the window; a read error: 3
    bl      disk_read                       @ 080216C2 call disk_read
    cmp     r0, #0                          @ 080216C6 compare r0 with 0
    beq     .Lfat_check_fs_16CE             @ 080216C8 if (r0 == 0) goto 0x80216CE
    movs    r0, #3                          @ 080216CA r0 = 3
    b       .Lfat_check_fs_172A             @ 080216CC goto 0x802172A
.Lfat_check_fs_16CE:                    @ v2.05 0x080216CE, reached from 0x080216C8
    ldrb.w  r0, [r4, #0x22f]                @ 080216CE r0 = u8 [r4+0x22F]
    ldrb.w  r1, [r4, #0x22e]                @ 080216D2 r1 = u8 [r4+0x22E]
    orrs.w  r0, r1, r0, lsl #8              @ 080216D6 r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 080216DA r0 = u16(r0)
    @ window offset 0x1FE must be 0xAA55, else 2
    movw    r1, #0xaa55                     @ 080216DC
    cmp     r0, r1                          @ 080216E0 compare r0 with r1
    beq     .Lfat_check_fs_16E8             @ 080216E2 if (r0 == r1) goto 0x80216E8
    movs    r0, #2                          @ 080216E4 r0 = 2
    b       .Lfat_check_fs_172A             @ 080216E6 goto 0x802172A
    @ "FAT" at offset 0x36 (FAT12/16 boot sector): 0
.Lfat_check_fs_16E8:                    @ v2.05 0x080216E8, reached from 0x080216E2
    ldrb.w  r0, [r4, #0x68]                 @ 080216E8 r0 = u8 [r4+0x68]
    ldrb.w  r1, [r4, #0x67]                 @ 080216EC r1 = u8 [r4+0x67]
    lsls    r1, r1, #8                      @ 080216F0 r1 = r1 << 8
    orrs.w  r0, r1, r0, lsl #16             @ 080216F2 r0 = r1 | r0, lsl #16
    ldrb.w  r1, [r4, #0x66]                 @ 080216F6 r1 = u8 [r4+0x66]
    orrs    r0, r1                          @ 080216FA r0 |= r1
    ldr.w   r1, =0x00544146                 @ 080216FC r1 = 0x544146
    cmp     r0, r1                          @ 08021700 compare r0 with r1
    bne     .Lfat_check_fs_1708             @ 08021702 if (r0 != r1) goto 0x8021708
    movs    r0, #0                          @ 08021704 r0 = 0
    b       .Lfat_check_fs_172A             @ 08021706 goto 0x802172A
    @ "FAT" at offset 0x52 (FAT32 boot sector): 0; neither: 1
.Lfat_check_fs_1708:                    @ v2.05 0x08021708, reached from 0x08021702
    ldrb.w  r0, [r4, #0x84]                 @ 08021708 r0 = u8 [r4+0x84]
    ldrb.w  r1, [r4, #0x83]                 @ 0802170C r1 = u8 [r4+0x83]
    lsls    r1, r1, #8                      @ 08021710 r1 = r1 << 8
    orrs.w  r0, r1, r0, lsl #16             @ 08021712 r0 = r1 | r0, lsl #16
    ldrb.w  r1, [r4, #0x82]                 @ 08021716 r1 = u8 [r4+0x82]
    orrs    r0, r1                          @ 0802171A r0 |= r1
    ldr.w   r1, =0x00544146                 @ 0802171C r1 = 0x544146
    cmp     r0, r1                          @ 08021720 compare r0 with r1
    bne     .Lfat_check_fs_1728             @ 08021722 if (r0 != r1) goto 0x8021728
    movs    r0, #0                          @ 08021724 r0 = 0
    b       .Lfat_check_fs_172A             @ 08021726 goto 0x802172A
.Lfat_check_fs_1728:                    @ v2.05 0x08021728, reached from 0x08021722
    movs    r0, #1                          @ 08021728 r0 = 1
.Lfat_check_fs_172A:                    @ v2.05 0x0802172A, reached from 0x080216CC, 0x080216E6, 0x08021706, 0x08021726
    pop     {r1, r4, r5, pc}                @ 0802172A pop {r1, r4, r5, pc}
ENDFUNC fat_check_fs
    .ltorg

@ -----------------------------------------------------------------------------
@ fat_chk_mounted - make sure drive r0 of the path is mounted; mount it when needed (FatFs chk_mounted)
@ Replaces  : 0x0802172C FUN_0802172C (v2.05), called by f_open, f_opendir, f_stat, f_utime
@ In        : r0 = pointer to the path pointer (a "0:" prefix is removed), r1 = pointer that receives the FATFS pointer, r2 = 1 when write access is needed
@ Out       : r0 = 0 mounted, 3 not ready, 10 write protected, 11 invalid drive, 12 no file system object registered, 13 no FAT file system
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads the FATFS pointer registered by f_mount (0x20007C58), writes the mount counter 0x20007F98 and the FATFS fields
@ Spec      : v2.05 listing 0x0802172C..0x08021B4F
@ Note      : when fs_type is already set and the disk reports no change (disk_status), the existing mount is used.  Otherwise
@             the volume is mounted: disk_initialize (the SD card is brought up here), the boot sector is located (sector 0 or the
@             first partition of an MBR, 0x1BE entries), then the BPB is read: sector size must be 512 (0x200), sectors per cluster a
@             power of two, FAT count 1 or 2, root entries a multiple of 16 for FAT12/16, total sectors and FAT size (16- or 32-bit
@             fields).  The FAT type follows from the number of clusters (below 4086 FAT12, below 65526 FAT16, else FAT32).  For
@             FAT32 the FSInfo sector is read; when its signatures are valid, the free cluster count and the last allocated cluster are
@             taken from it (otherwise 0xFFFFFFFF and 0).  The mount id counter is incremented and stored in FATFS +6.
@ -----------------------------------------------------------------------------
FUNC fat_chk_mounted
    push.w  {r1, r4, r5, r6, r7, r8, r9, r10, r11, lr}@ 0802172C push {r1, r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub     sp, #0x20                       @ 08021730 sp -= 0x20
    mov     r11, r0                         @ 08021732 r11 = r0
    movs    r4, r2                          @ 08021734 r4 = r2
    ldr.w   r9, [r11]                       @ 08021736 r9 = u32 [r11]
    ldrb.w  r0, [r9]                        @ 0802173A r0 = u8 [r9]
    subs    r0, #0x30                       @ 0802173E r0 -= 0x30
    str     r0, [sp, #8]                    @ 08021740 u32 [sp+0x8] = r0
    ldr     r0, [sp, #8]                    @ 08021742 r0 = u32 [sp+0x8]
    @ drive prefix: a digit followed by ":" selects the drive and is skipped (a path without prefix is drive 0); a drive other than 0 gives 11
    cmp     r0, #0xa                        @ 08021744 compare r0 with 0xa
    bhs     .Lfat_chk_mounted_175A          @ 08021746 if (r0 >=u 0xa) goto 0x802175A
    ldrb.w  r0, [r9, #1]                    @ 08021748 r0 = u8 [r9+0x1]
    cmp     r0, #0x3a                       @ 0802174C compare r0 with 0x3a
    bne     .Lfat_chk_mounted_175A          @ 0802174E if (r0 != 0x3a) goto 0x802175A
    adds.w  r9, r9, #2                      @ 08021750 r9 = r9 + 2
    str.w   r9, [r11]                       @ 08021754 u32 [r11] = r9
    b       .Lfat_chk_mounted_175E          @ 08021758 goto 0x802175E
.Lfat_chk_mounted_175A:                 @ v2.05 0x0802175A, reached from 0x08021746, 0x0802174E
    movs    r0, #0                          @ 0802175A r0 = 0
    str     r0, [sp, #8]                    @ 0802175C u32 [sp+0x8] = r0
.Lfat_chk_mounted_175E:                 @ v2.05 0x0802175E, reached from 0x08021758
    ldr     r0, [sp, #8]                    @ 0802175E r0 = u32 [sp+0x8]
    cmp     r0, #0                          @ 08021760 compare r0 with 0
    beq     .Lfat_chk_mounted_1768          @ 08021762 if (r0 == 0) goto 0x8021768
    movs    r0, #0xb                        @ 08021764 r0 = 0xb
    b       .Lfat_chk_mounted_1B4A          @ 08021766 goto 0x8021B4A
    @ the FATFS pointer registered with f_mount for drive 0 (0x20007C58); none: 12
.Lfat_chk_mounted_1768:                 @ v2.05 0x08021768, reached from 0x08021762
    ldr.w   r0, =fat_fs_table               @ 08021768 r0 = &fat_fs_table
    ldr     r1, [sp, #8]                    @ 0802176C r1 = u32 [sp+0x8]
    ldr.w   r0, [r0, r1, lsl #2]            @ 0802176E r0 = u32 [fat_fs_table+r1*4]
    mov     r8, r0                          @ 08021772 r8 = r0
    ldr     r0, [sp, #0x20]                 @ 08021774 r0 = u32 [sp+0x20]
    str.w   r8, [r0]                        @ 08021776 u32 [r0] = r8
    cmp.w   r8, #0                          @ 0802177A compare r8 with 0
    bne     .Lfat_chk_mounted_1784          @ 0802177E if (r8 != 0) goto 0x8021784
    movs    r0, #0xc                        @ 08021780 r0 = 0xc
    b       .Lfat_chk_mounted_1B4A          @ 08021782 goto 0x8021B4A
    @ fs_type != 0 (already mounted): ask disk_status; if the disk is still initialised the mount is used (a write request on a write-protected disk gives 10)
.Lfat_chk_mounted_1784:                 @ v2.05 0x08021784, reached from 0x0802177E
    ldrb.w  r0, [r8]                        @ 08021784 r0 = u8 [r8]
    cmp     r0, #0                          @ 08021788 compare r0 with 0
    beq     .Lfat_chk_mounted_17B6          @ 0802178A if (r0 == 0) goto 0x80217B6
    ldrb.w  r0, [r8, #1]                    @ 0802178C r0 = u8 [r8+0x1]
    bl      disk_status                     @ 08021790 call disk_status
    strb.w  r0, [sp]                        @ 08021794 u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 08021798 r0 = u8 [sp]
    lsls    r0, r0, #0x1f                   @ 0802179C r0 = r0 << 0x1f
    bmi     .Lfat_chk_mounted_17B6          @ 0802179E if (r0 <0 0) goto 0x80217B6
    uxtb    r4, r4                          @ 080217A0 r4 = u8(r4)
    cmp     r4, #0                          @ 080217A2 compare r4 with 0
    beq     .Lfat_chk_mounted_17B2          @ 080217A4 if (r4 == 0) goto 0x80217B2
    ldrb.w  r0, [sp]                        @ 080217A6 r0 = u8 [sp]
    lsls    r0, r0, #0x1d                   @ 080217AA r0 = r0 << 0x1d
    bpl     .Lfat_chk_mounted_17B2          @ 080217AC if (r0 >=0 0) goto 0x80217B2
    movs    r0, #0xa                        @ 080217AE r0 = 0xa
    b       .Lfat_chk_mounted_1B4A          @ 080217B0 goto 0x8021B4A
.Lfat_chk_mounted_17B2:                 @ v2.05 0x080217B2, reached from 0x080217A4, 0x080217AC
    movs    r0, #0                          @ 080217B2 r0 = 0
    b       .Lfat_chk_mounted_1B4A          @ 080217B4 goto 0x8021B4A
    @ mount from scratch: fs_type = 0, drive = 0, disk_initialize (17C6): a failure gives 3, a write-protected disk with a write request 10
.Lfat_chk_mounted_17B6:                 @ v2.05 0x080217B6, reached from 0x0802178A, 0x0802179E
    movs    r0, #0                          @ 080217B6 r0 = 0
    strb.w  r0, [r8]                        @ 080217B8 u8 [r8] = r0
    ldr     r0, [sp, #8]                    @ 080217BC r0 = u32 [sp+0x8]
    strb.w  r0, [r8, #1]                    @ 080217BE u8 [r8+0x1] = r0
    ldrb.w  r0, [r8, #1]                    @ 080217C2 r0 = u8 [r8+0x1]
    bl      disk_initialize                 @ 080217C6 call disk_initialize
    strb.w  r0, [sp]                        @ 080217CA u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 080217CE r0 = u8 [sp]
    lsls    r0, r0, #0x1f                   @ 080217D2 r0 = r0 << 0x1f
    bpl     .Lfat_chk_mounted_17DA          @ 080217D4 if (r0 >=0 0) goto 0x80217DA
    movs    r0, #3                          @ 080217D6 r0 = 3
    b       .Lfat_chk_mounted_1B4A          @ 080217D8 goto 0x8021B4A
.Lfat_chk_mounted_17DA:                 @ v2.05 0x080217DA, reached from 0x080217D4
    uxtb    r4, r4                          @ 080217DA r4 = u8(r4)
    cmp     r4, #0                          @ 080217DC compare r4 with 0
    beq     .Lfat_chk_mounted_17EC          @ 080217DE if (r4 == 0) goto 0x80217EC
    ldrb.w  r0, [sp]                        @ 080217E0 r0 = u8 [sp]
    lsls    r0, r0, #0x1d                   @ 080217E4 r0 = r0 << 0x1d
    bpl     .Lfat_chk_mounted_17EC          @ 080217E6 if (r0 >=0 0) goto 0x80217EC
    movs    r0, #0xa                        @ 080217E8 r0 = 0xa
    b       .Lfat_chk_mounted_1B4A          @ 080217EA goto 0x8021B4A
.Lfat_chk_mounted_17EC:                 @ v2.05 0x080217EC, reached from 0x080217DE, 0x080217E6
    movs    r0, #0                          @ 080217EC r0 = 0
    str     r0, [sp, #4]                    @ 080217EE u32 [sp+0x4] = r0
    ldr     r1, [sp, #4]                    @ 080217F0 r1 = u32 [sp+0x4]
    mov     r0, r8                          @ 080217F2 r0 = r8
    @ find the boot sector: check_fs(0); result 1 (valid signature, no FAT boot sector) tries the first partition table entry (start sector at window offset 0x1C6)
    bl      fat_check_fs                    @ 080217F4 call fat_check_fs
    movs    r5, r0                          @ 080217F8 r5 = r0
    uxtb    r5, r5                          @ 080217FA r5 = u8(r5)
    cmp     r5, #1                          @ 080217FC compare r5 with 1
    bne     .Lfat_chk_mounted_1838          @ 080217FE if (r5 != 1) goto 0x8021838
    mov.w   r0, #0x1ee                      @ 08021800 r0 = 0x1ee
    add     r0, r8                          @ 08021804 r0 += r8
    str     r0, [sp, #0xc]                  @ 08021806 u32 [sp+0xC] = r0
    ldr     r0, [sp, #0xc]                  @ 08021808 r0 = u32 [sp+0xC]
    ldrb    r0, [r0, #4]                    @ 0802180A r0 = u8 [r0+0x4]
    cmp     r0, #0                          @ 0802180C compare r0 with 0
    beq     .Lfat_chk_mounted_1838          @ 0802180E if (r0 == 0) goto 0x8021838
    ldr     r0, [sp, #0xc]                  @ 08021810 r0 = u32 [sp+0xC]
    ldrb    r0, [r0, #0xb]                  @ 08021812 r0 = u8 [r0+0xB]
    ldr     r1, [sp, #0xc]                  @ 08021814 r1 = u32 [sp+0xC]
    ldrb    r1, [r1, #0xa]                  @ 08021816 r1 = u8 [r1+0xA]
    lsls    r1, r1, #0x10                   @ 08021818 r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 0802181A r0 = r1 | r0, lsl #24
    ldr     r1, [sp, #0xc]                  @ 0802181E r1 = u32 [sp+0xC]
    ldrb    r1, [r1, #9]                    @ 08021820 r1 = u8 [r1+0x9]
    orrs.w  r0, r0, r1, lsl #8              @ 08021822 r0 = r0 | r1, lsl #8
    ldr     r1, [sp, #0xc]                  @ 08021826 r1 = u32 [sp+0xC]
    ldrb    r1, [r1, #8]                    @ 08021828 r1 = u8 [r1+0x8]
    orrs    r0, r1                          @ 0802182A r0 |= r1
    str     r0, [sp, #4]                    @ 0802182C u32 [sp+0x4] = r0
    ldr     r1, [sp, #4]                    @ 0802182E r1 = u32 [sp+0x4]
    mov     r0, r8                          @ 08021830 r0 = r8
    bl      fat_check_fs                    @ 08021832 call fat_check_fs
    movs    r5, r0                          @ 08021836 r5 = r0
.Lfat_chk_mounted_1838:                 @ v2.05 0x08021838, reached from 0x080217FE, 0x0802180E
    uxtb    r5, r5                          @ 08021838 r5 = u8(r5)
    @ check_fs result 3 (disk error): 1; any result except 0 (FAT boot sector): 13
    cmp     r5, #3                          @ 0802183A compare r5 with 3
    bne     .Lfat_chk_mounted_1842          @ 0802183C if (r5 != 3) goto 0x8021842
    movs    r0, #1                          @ 0802183E r0 = 1
    b       .Lfat_chk_mounted_1B4A          @ 08021840 goto 0x8021B4A
.Lfat_chk_mounted_1842:                 @ v2.05 0x08021842, reached from 0x0802183C
    uxtb    r5, r5                          @ 08021842 r5 = u8(r5)
    cmp     r5, #0                          @ 08021844 compare r5 with 0
    beq     .Lfat_chk_mounted_184C          @ 08021846 if (r5 == 0) goto 0x802184C
    movs    r0, #0xd                        @ 08021848 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 0802184A goto 0x8021B4A
.Lfat_chk_mounted_184C:                 @ v2.05 0x0802184C, reached from 0x08021846
    ldrb.w  r0, [r8, #0x3c]                 @ 0802184C r0 = u8 [r8+0x3C]
    ldrb.w  r1, [r8, #0x3b]                 @ 08021850 r1 = u8 [r8+0x3B]
    orrs.w  r0, r1, r0, lsl #8              @ 08021854 r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08021858 r0 = u16(r0)
    @ BPB bytes per sector (BPB +0x0B) must be 0x200, else 13
    cmp.w   r0, #0x200                      @ 0802185A compare r0 with 0x200
    beq     .Lfat_chk_mounted_1864          @ 0802185E if (r0 == 0x200) goto 0x8021864
    movs    r0, #0xd                        @ 08021860 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 08021862 goto 0x8021B4A
.Lfat_chk_mounted_1864:                 @ v2.05 0x08021864, reached from 0x0802185E
    ldrb.w  r0, [r8, #0x47]                 @ 08021864 r0 = u8 [r8+0x47]
    ldrb.w  r1, [r8, #0x46]                 @ 08021868 r1 = u8 [r8+0x46]
    orrs.w  r0, r1, r0, lsl #8              @ 0802186C r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08021870 r0 = u16(r0)
    mov     r10, r0                         @ 08021872 r10 = r0
    @ sectors per FAT: the 16-bit field (BPB +0x16), or the 32-bit field (BPB +0x24) when it is 0
    cmp.w   r10, #0                         @ 08021874 compare r10 with 0
    bne     .Lfat_chk_mounted_1898          @ 08021878 if (r10 != 0) goto 0x8021898
    ldrb.w  r0, [r8, #0x57]                 @ 0802187A r0 = u8 [r8+0x57]
    ldrb.w  r1, [r8, #0x56]                 @ 0802187E r1 = u8 [r8+0x56]
    lsls    r1, r1, #0x10                   @ 08021882 r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 08021884 r0 = r1 | r0, lsl #24
    ldrb.w  r1, [r8, #0x55]                 @ 08021888 r1 = u8 [r8+0x55]
    orrs.w  r0, r0, r1, lsl #8              @ 0802188C r0 = r0 | r1, lsl #8
    ldrb.w  r1, [r8, #0x54]                 @ 08021890 r1 = u8 [r8+0x54]
    orrs    r0, r1                          @ 08021894 r0 |= r1
    mov     r10, r0                         @ 08021896 r10 = r0
.Lfat_chk_mounted_1898:                 @ v2.05 0x08021898, reached from 0x08021878
    str.w   r10, [r8, #0x1c]                @ 08021898 u32 [r8+0x1C] = r10
    ldrb.w  r0, [r8, #0x40]                 @ 0802189C r0 = u8 [r8+0x40]
    movs    r6, r0                          @ 080218A0 r6 = r0
    strb.w  r6, [r8, #3]                    @ 080218A2 u8 [r8+0x3] = r6
    uxtb    r6, r6                          @ 080218A6 r6 = u8(r6)
    @ number of FATs (BPB +0x10) must be 1 or 2
    cmp     r6, #1                          @ 080218A8 compare r6 with 1
    beq     .Lfat_chk_mounted_18B6          @ 080218AA if (r6 == 1) goto 0x80218B6
    uxtb    r6, r6                          @ 080218AC r6 = u8(r6)
    cmp     r6, #2                          @ 080218AE compare r6 with 2
    beq     .Lfat_chk_mounted_18B6          @ 080218B0 if (r6 == 2) goto 0x80218B6
    movs    r0, #0xd                        @ 080218B2 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 080218B4 goto 0x8021B4A
.Lfat_chk_mounted_18B6:                 @ v2.05 0x080218B6, reached from 0x080218AA, 0x080218B0
    uxtb    r6, r6                          @ 080218B6 r6 = u8(r6)
    mul     r10, r6, r10                    @ 080218B8 r10 = r6 * r10
    ldrb.w  r0, [r8, #0x3d]                 @ 080218BC r0 = u8 [r8+0x3D]
    movs    r6, r0                          @ 080218C0 r6 = r0
    strb.w  r6, [r8, #2]                    @ 080218C2 u8 [r8+0x2] = r6
    uxtb    r6, r6                          @ 080218C6 r6 = u8(r6)
    @ sectors per cluster (BPB +0x0D) must be a non-zero power of two
    cmp     r6, #0                          @ 080218C8 compare r6 with 0
    beq     .Lfat_chk_mounted_18D6          @ 080218CA if (r6 == 0) goto 0x80218D6
    subs    r1, r6, #1                      @ 080218CC r1 = r6 - 1
    movs    r0, r6                          @ 080218CE r0 = r6
    uxtb    r0, r0                          @ 080218D0 r0 = u8(r0)
    tst     r0, r1                          @ 080218D2 compare r0 with r1
    beq     .Lfat_chk_mounted_18DA          @ 080218D4 if ((r0 & r1) == 0) goto 0x80218DA
.Lfat_chk_mounted_18D6:                 @ v2.05 0x080218D6, reached from 0x080218CA
    movs    r0, #0xd                        @ 080218D6 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 080218D8 goto 0x8021B4A
.Lfat_chk_mounted_18DA:                 @ v2.05 0x080218DA, reached from 0x080218D4
    ldrb.w  r0, [r8, #0x42]                 @ 080218DA r0 = u8 [r8+0x42]
    ldrb.w  r1, [r8, #0x41]                 @ 080218DE r1 = u8 [r8+0x41]
    orrs.w  r0, r1, r0, lsl #8              @ 080218E2 r0 = r1 | r0, lsl #8
    strh.w  r0, [r8, #8]                    @ 080218E6 u16 [r8+0x8] = r0
    ldrb.w  r0, [r8, #8]                    @ 080218EA r0 = u8 [r8+0x8]
    movs    r1, #0xf                        @ 080218EE r1 = 0xf
    tst     r0, r1                          @ 080218F0 compare r0 with r1
    beq     .Lfat_chk_mounted_18F8          @ 080218F2 if ((r0 & r1) == 0) goto 0x80218F8
    movs    r0, #0xd                        @ 080218F4 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 080218F6 goto 0x8021B4A
    @ total sectors: the 16-bit field (BPB +0x13) ...
.Lfat_chk_mounted_18F8:                 @ v2.05 0x080218F8, reached from 0x080218F2
    ldrb.w  r0, [r8, #0x44]                 @ 080218F8 r0 = u8 [r8+0x44]
    ldrb.w  r1, [r8, #0x43]                 @ 080218FC r1 = u8 [r8+0x43]
    orrs.w  r0, r1, r0, lsl #8              @ 08021900 r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08021904 r0 = u16(r0)
    str     r0, [sp, #0x14]                 @ 08021906 u32 [sp+0x14] = r0
    ldr     r0, [sp, #0x14]                 @ 08021908 r0 = u32 [sp+0x14]
    @ ... or the 32-bit field (BPB +0x20) when the 16-bit field is 0
    cmp     r0, #0                          @ 0802190A compare r0 with 0
    bne     .Lfat_chk_mounted_192C          @ 0802190C if (r0 != 0) goto 0x802192C
    ldrb.w  r0, [r8, #0x53]                 @ 0802190E r0 = u8 [r8+0x53]
    ldrb.w  r1, [r8, #0x52]                 @ 08021912 r1 = u8 [r8+0x52]
    lsls    r1, r1, #0x10                   @ 08021916 r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 08021918 r0 = r1 | r0, lsl #24
    ldrb.w  r1, [r8, #0x51]                 @ 0802191C r1 = u8 [r8+0x51]
    orrs.w  r0, r0, r1, lsl #8              @ 08021920 r0 = r0 | r1, lsl #8
    ldrb.w  r1, [r8, #0x50]                 @ 08021924 r1 = u8 [r8+0x50]
    orrs    r0, r1                          @ 08021928 r0 |= r1
    str     r0, [sp, #0x14]                 @ 0802192A u32 [sp+0x14] = r0
.Lfat_chk_mounted_192C:                 @ v2.05 0x0802192C, reached from 0x0802190C
    ldrb.w  r0, [r8, #0x3f]                 @ 0802192C r0 = u8 [r8+0x3F]
    ldrb.w  r1, [r8, #0x3e]                 @ 08021930 r1 = u8 [r8+0x3E]
    orrs.w  r0, r1, r0, lsl #8              @ 08021934 r0 = r1 | r0, lsl #8
    strh.w  r0, [sp, #2]                    @ 08021938 u16 [sp+0x2] = r0
    ldrh.w  r0, [sp, #2]                    @ 0802193C r0 = u16 [sp+0x2]
    cmp     r0, #0                          @ 08021940 compare r0 with 0
    bne     .Lfat_chk_mounted_1948          @ 08021942 if (r0 != 0) goto 0x8021948
    movs    r0, #0xd                        @ 08021944 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 08021946 goto 0x8021B4A
.Lfat_chk_mounted_1948:                 @ v2.05 0x08021948, reached from 0x08021942
    ldrh.w  r0, [sp, #2]                    @ 08021948 r0 = u16 [sp+0x2]
    adds.w  r0, r10, r0                     @ 0802194C r0 = r10 + r0
    ldrh.w  r1, [r8, #8]                    @ 08021950 r1 = u16 [r8+0x8]
    adds.w  r0, r0, r1, lsr #4              @ 08021954 r0 = r0 + r1, lsr #4
    str     r0, [sp, #0x18]                 @ 08021958 u32 [sp+0x18] = r0
    ldr     r0, [sp, #0x14]                 @ 0802195A r0 = u32 [sp+0x14]
    ldr     r1, [sp, #0x18]                 @ 0802195C r1 = u32 [sp+0x18]
    @ reserved sectors + FATs + root directory must fit in the volume, else 13
    cmp     r0, r1                          @ 0802195E compare r0 with r1
    bhs     .Lfat_chk_mounted_1966          @ 08021960 if (r0 >=u r1) goto 0x8021966
    movs    r0, #0xd                        @ 08021962 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 08021964 goto 0x8021B4A
.Lfat_chk_mounted_1966:                 @ v2.05 0x08021966, reached from 0x08021960
    ldr     r0, [sp, #0x14]                 @ 08021966 r0 = u32 [sp+0x14]
    ldr     r1, [sp, #0x18]                 @ 08021968 r1 = u32 [sp+0x18]
    subs    r0, r0, r1                      @ 0802196A r0 = r0 - r1
    ldrb.w  r1, [r8, #2]                    @ 0802196C r1 = u8 [r8+0x2]
    udiv    r0, r0, r1                      @ 08021970
    str     r0, [sp, #0x10]                 @ 08021974 u32 [sp+0x10] = r0
    ldr     r0, [sp, #0x10]                 @ 08021976 r0 = u32 [sp+0x10]
    cmp     r0, #0                          @ 08021978 compare r0 with 0
    bne     .Lfat_chk_mounted_1980          @ 0802197A if (r0 != 0) goto 0x8021980
    movs    r0, #0xd                        @ 0802197C r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 0802197E goto 0x8021B4A
    @ number of clusters: above 0xFF5 FAT16, above 0xFFF5 FAT32 (r5 = FAT type 1, 2, 3)
.Lfat_chk_mounted_1980:                 @ v2.05 0x08021980, reached from 0x0802197A
    movs    r0, #1                          @ 08021980 r0 = 1
    movs    r5, r0                          @ 08021982 r5 = r0
    ldr     r0, [sp, #0x10]                 @ 08021984 r0 = u32 [sp+0x10]
    movw    r1, #0xff6                      @ 08021986
    cmp     r0, r1                          @ 0802198A compare r0 with r1
    blo     .Lfat_chk_mounted_1992          @ 0802198C if (r0 <u r1) goto 0x8021992
    movs    r0, #2                          @ 0802198E r0 = 2
    movs    r5, r0                          @ 08021990 r5 = r0
.Lfat_chk_mounted_1992:                 @ v2.05 0x08021992, reached from 0x0802198C
    ldr     r0, [sp, #0x10]                 @ 08021992 r0 = u32 [sp+0x10]
    movw    r1, #0xfff6                     @ 08021994
    cmp     r0, r1                          @ 08021998 compare r0 with r1
    blo     .Lfat_chk_mounted_19A0          @ 0802199A if (r0 <u r1) goto 0x80219A0
    movs    r0, #3                          @ 0802199C r0 = 3
    movs    r5, r0                          @ 0802199E r5 = r0
.Lfat_chk_mounted_19A0:                 @ v2.05 0x080219A0, reached from 0x0802199A
    ldr     r0, [sp, #0x10]                 @ 080219A0 r0 = u32 [sp+0x10]
    adds    r0, r0, #2                      @ 080219A2 r0 = r0 + 2
    str.w   r0, [r8, #0x18]                 @ 080219A4 u32 [r8+0x18] = r0
    ldr     r0, [sp, #4]                    @ 080219A8 r0 = u32 [sp+0x4]
    ldr     r1, [sp, #0x18]                 @ 080219AA r1 = u32 [sp+0x18]
    adds    r0, r1, r0                      @ 080219AC r0 = r1 + r0
    str.w   r0, [r8, #0x28]                 @ 080219AE u32 [r8+0x28] = r0
    ldr     r0, [sp, #4]                    @ 080219B2 r0 = u32 [sp+0x4]
    ldrh.w  r1, [sp, #2]                    @ 080219B4 r1 = u16 [sp+0x2]
    adds    r0, r1, r0                      @ 080219B8 r0 = r1 + r0
    str.w   r0, [r8, #0x20]                 @ 080219BA u32 [r8+0x20] = r0
    uxtb    r5, r5                          @ 080219BE r5 = u8(r5)
    @ FAT32: root directory is a cluster chain (root cluster at BPB +0x2C, and the 16-bit root entry count must be 0); FAT12/16: fixed root area behind the FATs
    cmp     r5, #3                          @ 080219C0 compare r5 with 3
    bne     .Lfat_chk_mounted_19FA          @ 080219C2 if (r5 != 3) goto 0x80219FA
    ldrh.w  r0, [r8, #8]                    @ 080219C4 r0 = u16 [r8+0x8]
    cmp     r0, #0                          @ 080219C8 compare r0 with 0
    beq     .Lfat_chk_mounted_19D0          @ 080219CA if (r0 == 0) goto 0x80219D0
    movs    r0, #0xd                        @ 080219CC r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 080219CE goto 0x8021B4A
.Lfat_chk_mounted_19D0:                 @ v2.05 0x080219D0, reached from 0x080219CA
    ldrb.w  r0, [r8, #0x5f]                 @ 080219D0 r0 = u8 [r8+0x5F]
    ldrb.w  r1, [r8, #0x5e]                 @ 080219D4 r1 = u8 [r8+0x5E]
    lsls    r1, r1, #0x10                   @ 080219D8 r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 080219DA r0 = r1 | r0, lsl #24
    ldrb.w  r1, [r8, #0x5d]                 @ 080219DE r1 = u8 [r8+0x5D]
    orrs.w  r0, r0, r1, lsl #8              @ 080219E2 r0 = r0 | r1, lsl #8
    ldrb.w  r1, [r8, #0x5c]                 @ 080219E6 r1 = u8 [r8+0x5C]
    orrs    r0, r1                          @ 080219EA r0 |= r1
    str.w   r0, [r8, #0x24]                 @ 080219EC u32 [r8+0x24] = r0
    ldr.w   r0, [r8, #0x18]                 @ 080219F0 r0 = u32 [r8+0x18]
    lsls    r0, r0, #2                      @ 080219F4 r0 = r0 << 2
    movs    r7, r0                          @ 080219F6 r7 = r0
    b       .Lfat_chk_mounted_1A34          @ 080219F8 goto 0x8021A34
.Lfat_chk_mounted_19FA:                 @ v2.05 0x080219FA, reached from 0x080219C2
    ldrh.w  r0, [r8, #8]                    @ 080219FA r0 = u16 [r8+0x8]
    cmp     r0, #0                          @ 080219FE compare r0 with 0
    bne     .Lfat_chk_mounted_1A06          @ 08021A00 if (r0 != 0) goto 0x8021A06
    movs    r0, #0xd                        @ 08021A02 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 08021A04 goto 0x8021B4A
.Lfat_chk_mounted_1A06:                 @ v2.05 0x08021A06, reached from 0x08021A00
    ldr.w   r0, [r8, #0x20]                 @ 08021A06 r0 = u32 [r8+0x20]
    adds.w  r0, r10, r0                     @ 08021A0A r0 = r10 + r0
    str.w   r0, [r8, #0x24]                 @ 08021A0E u32 [r8+0x24] = r0
    uxtb    r5, r5                          @ 08021A12 r5 = u8(r5)
    cmp     r5, #2                          @ 08021A14 compare r5 with 2
    bne     .Lfat_chk_mounted_1A20          @ 08021A16 if (r5 != 2) goto 0x8021A20
    ldr.w   r0, [r8, #0x18]                 @ 08021A18 r0 = u32 [r8+0x18]
    lsls    r7, r0, #1                      @ 08021A1C r7 = r0 << 1
    b       .Lfat_chk_mounted_1A34          @ 08021A1E goto 0x8021A34
.Lfat_chk_mounted_1A20:                 @ v2.05 0x08021A20, reached from 0x08021A16
    ldr.w   r0, [r8, #0x18]                 @ 08021A20 r0 = u32 [r8+0x18]
    movs    r1, #3                          @ 08021A24 r1 = 3
    muls    r0, r1, r0                      @ 08021A26 r0 = r1 * r0
    ldrb.w  r1, [r8, #0x18]                 @ 08021A28 r1 = u8 [r8+0x18]
    ands    r1, r1, #1                      @ 08021A2C r1 = r1 & 1
    adds.w  r7, r1, r0, lsr #1              @ 08021A30 r7 = r1 + r0, lsr #1
    @ the FAT must be large enough for all clusters, else 13
.Lfat_chk_mounted_1A34:                 @ v2.05 0x08021A34, reached from 0x080219F8, 0x08021A1E
    ldr.w   r0, [r8, #0x1c]                 @ 08021A34 r0 = u32 [r8+0x1C]
    addw    r1, r7, #0x1ff                  @ 08021A38
    cmp.w   r0, r1, lsr #9                  @ 08021A3C compare r0 with r1
    bhs     .Lfat_chk_mounted_1A46          @ 08021A40 if (r0 >=u r1) goto 0x8021A46
    movs    r0, #0xd                        @ 08021A42 r0 = 0xd
    b       .Lfat_chk_mounted_1B4A          @ 08021A44 goto 0x8021B4A
.Lfat_chk_mounted_1A46:                 @ v2.05 0x08021A46, reached from 0x08021A40
    movs.w  r0, #-1                         @ 08021A46 r0 = -1
    str.w   r0, [r8, #0x10]                 @ 08021A4A u32 [r8+0x10] = r0
    movs    r0, #0                          @ 08021A4E r0 = 0
    str.w   r0, [r8, #0xc]                  @ 08021A50 u32 [r8+0xC] = r0
    uxtb    r5, r5                          @ 08021A54 r5 = u8(r5)
    @ FAT32: FSInfo sector (BPB +0x30) is read; with valid signatures the free cluster count and the last allocated cluster are taken from it
    cmp     r5, #3                          @ 08021A56 compare r5 with 3
    bne     .Lfat_chk_mounted_1B26          @ 08021A58 if (r5 != 3) goto 0x8021B26
    movs    r0, #0                          @ 08021A5A r0 = 0
    strb.w  r0, [r8, #5]                    @ 08021A5C u8 [r8+0x5] = r0
    ldr     r0, [sp, #4]                    @ 08021A60 r0 = u32 [sp+0x4]
    ldrb.w  r1, [r8, #0x61]                 @ 08021A62 r1 = u8 [r8+0x61]
    ldrb.w  r2, [r8, #0x60]                 @ 08021A66 r2 = u8 [r8+0x60]
    orrs.w  r1, r2, r1, lsl #8              @ 08021A6A r1 = r2 | r1, lsl #8
    uxth    r1, r1                          @ 08021A6E r1 = u16(r1)
    adds    r0, r1, r0                      @ 08021A70 r0 = r1 + r0
    str.w   r0, [r8, #0x14]                 @ 08021A72 u32 [r8+0x14] = r0
    movs    r3, #1                          @ 08021A76 r3 = 1
    ldr.w   r2, [r8, #0x14]                 @ 08021A78 r2 = u32 [r8+0x14]
    adds.w  r1, r8, #0x30                   @ 08021A7C r1 = r8 + 0x30
    ldrb.w  r0, [r8, #1]                    @ 08021A80 r0 = u8 [r8+0x1]
    bl      disk_read                       @ 08021A84 call disk_read
    cmp     r0, #0                          @ 08021A88 compare r0 with 0
    bne     .Lfat_chk_mounted_1B26          @ 08021A8A if (r0 != 0) goto 0x8021B26
    ldrb.w  r0, [r8, #0x22f]                @ 08021A8C r0 = u8 [r8+0x22F]
    ldrb.w  r1, [r8, #0x22e]                @ 08021A90 r1 = u8 [r8+0x22E]
    orrs.w  r0, r1, r0, lsl #8              @ 08021A94 r0 = r1 | r0, lsl #8
    uxth    r0, r0                          @ 08021A98 r0 = u16(r0)
    movw    r1, #0xaa55                     @ 08021A9A
    cmp     r0, r1                          @ 08021A9E compare r0 with r1
    bne     .Lfat_chk_mounted_1B26          @ 08021AA0 if (r0 != r1) goto 0x8021B26
    ldrb.w  r0, [r8, #0x33]                 @ 08021AA2 r0 = u8 [r8+0x33]
    ldrb.w  r1, [r8, #0x32]                 @ 08021AA6 r1 = u8 [r8+0x32]
    lsls    r1, r1, #0x10                   @ 08021AAA r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 08021AAC r0 = r1 | r0, lsl #24
    ldrb.w  r1, [r8, #0x31]                 @ 08021AB0 r1 = u8 [r8+0x31]
    orrs.w  r0, r0, r1, lsl #8              @ 08021AB4 r0 = r0 | r1, lsl #8
    ldrb.w  r1, [r8, #0x30]                 @ 08021AB8 r1 = u8 [r8+0x30]
    orrs    r0, r1                          @ 08021ABC r0 |= r1
    ldr     r1, =0x41615252                 @ 08021ABE r1 = 0x41615252
    cmp     r0, r1                          @ 08021AC0 compare r0 with r1
    bne     .Lfat_chk_mounted_1B26          @ 08021AC2 if (r0 != r1) goto 0x8021B26
    ldrb.w  r0, [r8, #0x217]                @ 08021AC4 r0 = u8 [r8+0x217]
    ldrb.w  r1, [r8, #0x216]                @ 08021AC8 r1 = u8 [r8+0x216]
    lsls    r1, r1, #0x10                   @ 08021ACC r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 08021ACE r0 = r1 | r0, lsl #24
    ldrb.w  r1, [r8, #0x215]                @ 08021AD2 r1 = u8 [r8+0x215]
    orrs.w  r0, r0, r1, lsl #8              @ 08021AD6 r0 = r0 | r1, lsl #8
    ldrb.w  r1, [r8, #0x214]                @ 08021ADA r1 = u8 [r8+0x214]
    orrs    r0, r1                          @ 08021ADE r0 |= r1
    ldr     r1, =0x61417272                 @ 08021AE0 r1 = 0x61417272
    cmp     r0, r1                          @ 08021AE2 compare r0 with r1
    bne     .Lfat_chk_mounted_1B26          @ 08021AE4 if (r0 != r1) goto 0x8021B26
    ldrb.w  r0, [r8, #0x21f]                @ 08021AE6 r0 = u8 [r8+0x21F]
    ldrb.w  r1, [r8, #0x21e]                @ 08021AEA r1 = u8 [r8+0x21E]
    lsls    r1, r1, #0x10                   @ 08021AEE r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 08021AF0 r0 = r1 | r0, lsl #24
    ldrb.w  r1, [r8, #0x21d]                @ 08021AF4 r1 = u8 [r8+0x21D]
    orrs.w  r0, r0, r1, lsl #8              @ 08021AF8 r0 = r0 | r1, lsl #8
    ldrb.w  r1, [r8, #0x21c]                @ 08021AFC r1 = u8 [r8+0x21C]
    orrs    r0, r1                          @ 08021B00 r0 |= r1
    str.w   r0, [r8, #0xc]                  @ 08021B02 u32 [r8+0xC] = r0
    ldrb.w  r0, [r8, #0x21b]                @ 08021B06 r0 = u8 [r8+0x21B]
    ldrb.w  r1, [r8, #0x21a]                @ 08021B0A r1 = u8 [r8+0x21A]
    lsls    r1, r1, #0x10                   @ 08021B0E r1 = r1 << 0x10
    orrs.w  r0, r1, r0, lsl #24             @ 08021B10 r0 = r1 | r0, lsl #24
    ldrb.w  r1, [r8, #0x219]                @ 08021B14 r1 = u8 [r8+0x219]
    orrs.w  r0, r0, r1, lsl #8              @ 08021B18 r0 = r0 | r1, lsl #8
    ldrb.w  r1, [r8, #0x218]                @ 08021B1C r1 = u8 [r8+0x218]
    orrs    r0, r1                          @ 08021B20 r0 |= r1
    str.w   r0, [r8, #0x10]                 @ 08021B22 u32 [r8+0x10] = r0
    @ mounted: fs_type, mount id = ++0x20007F98, window sector 0, window clean
.Lfat_chk_mounted_1B26:                 @ v2.05 0x08021B26, reached from 0x08021A58, 0x08021A8A, 0x08021AA0, 0x08021AC2, 0x08021AE4
    strb.w  r5, [r8]                        @ 08021B26 u8 [r8] = r5
    ldr     r0, =fat_mount_id               @ 08021B2A r0 = &fat_mount_id
    ldrh    r0, [r0]                        @ 08021B2C r0 = u16 [fat_mount_id]
    adds    r0, r0, #1                      @ 08021B2E r0 = r0 + 1
    ldr     r1, =fat_mount_id               @ 08021B30 r1 = &fat_mount_id
    strh    r0, [r1]                        @ 08021B32 u16 [fat_mount_id] = r0
    ldr     r0, =fat_mount_id               @ 08021B34 r0 = &fat_mount_id
    ldrh    r0, [r0]                        @ 08021B36 r0 = u16 [fat_mount_id]
    strh.w  r0, [r8, #6]                    @ 08021B38 u16 [r8+0x6] = r0
    movs    r0, #0                          @ 08021B3C r0 = 0
    str.w   r0, [r8, #0x2c]                 @ 08021B3E u32 [r8+0x2C] = r0
    movs    r0, #0                          @ 08021B42 r0 = 0
    strb.w  r0, [r8, #4]                    @ 08021B44 u8 [r8+0x4] = r0
    movs    r0, #0                          @ 08021B48 r0 = 0
.Lfat_chk_mounted_1B4A:                 @ v2.05 0x08021B4A, reached from 0x08021766, 0x08021782, 0x080217B0, 0x080217B4, 0x080217D8, 0x080217EA, 0x08021840, 0x0802184A, 0x08021862, 0x080218B4, 0x080218D8, 0x080218F6, 0x08021946, 0x08021964, 0x0802197E, 0x080219CE, 0x08021A04, 0x08021A44
    add     sp, #0x24                       @ 08021B4A sp += 0x24
    pop.w   {r4, r5, r6, r7, r8, r9, r10, r11, pc}@ 08021B4C pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC fat_chk_mounted
    .ltorg

