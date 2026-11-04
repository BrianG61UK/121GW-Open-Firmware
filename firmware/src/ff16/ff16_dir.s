@ =============================================================================
@ ff16_dir.s - FatFs R0.16 (production image): directory index, entries, names and path (DESIGN.md 7A, IMP-29)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c, FF_USE_LFN 0, FF_FS_EXFAT 0, FF_FS_RPATH 0, FF_CODE_PAGE 932):
@ dir_sdi, dir_next, dir_alloc, ld_clust, st_clust, dir_read, dir_find, dir_register, dir_remove, get_fileinfo,
@ create_name, follow_path.  License and conventions: ff16_low.s.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "config.inc"

    .include "ff16.inc"

    .section .text.ff16.dir, "ax", %progbits

@ -----------------------------------------------------------------------------
@ dir_sdi - set the directory index (ff.c dir_sdi)
@ In       : r0 = dp, r1 = ofs (byte offset in the directory)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 ofs, r7 clst, r8 csz
@ -----------------------------------------------------------------------------
FUNC ff16_dir_sdi
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    mov r6, r1
    cmp r6, #MAX_DIR                        @ if (ofs >= MAX_DIR || ofs % SZDIRE) return FR_INT_ERR;
    bhs .Lsdi_int
    tst r6, #(SZDIRE - 1)
    bne .Lsdi_int
    str r6, [r4, #DIR_DPTR]                 @ dp->dptr = ofs;
    ldr r7, [r4, #OBJ_SCLUST]               @ clst = dp->obj.sclust;
    cbnz r7, 1f                             @ if (clst == 0 && fs->fs_type >= FS_FAT32) clst = fs->dirbase;
    ldrb r0, [r5, #FS_FS_TYPE]
    cmp r0, #FS_FAT32
    it hs
    ldrhs r7, [r5, #FS_DIRBASE]
1:  cbnz r7, 2f                             @ if (clst == 0) {
    ldrh r0, [r5, #FS_N_ROOTDIR]            @   if (ofs / SZDIRE >= fs->n_rootdir) return FR_INT_ERR;
    cmp r0, r6, lsr #5
    bls .Lsdi_int
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
    beq .Lsdi_disk                          @     if (clst == 0xFFFFFFFF) return FR_DISK_ERR;
    cmp r7, #2                              @     if (clst < 2 || clst >= fs->n_fatent) return FR_INT_ERR;
    blo .Lsdi_int
    ldr r0, [r5, #FS_N_FATENT]
    cmp r7, r0
    bhs .Lsdi_int
    sub r6, r6, r8                          @     ofs -= csz;
    b 3b
31: mov r0, r5
    mov r1, r7
    bl ff16_clst2sect
    str r0, [r4, #DIR_SECT]                 @   dp->sect = clst2sect(fs, clst);
4:  str r7, [r4, #DIR_CLUST]                @ dp->clust = clst;
    ldr r0, [r4, #DIR_SECT]                 @ if (dp->sect == 0) return FR_INT_ERR;
    cbz r0, .Lsdi_int
    add r0, r0, r6, lsr #9
    str r0, [r4, #DIR_SECT]                 @ dp->sect += ofs / SS(fs);
    ubfx r0, r6, #0, #9
    add r0, r0, r5
    adds r0, r0, #FS_WIN
    str r0, [r4, #DIR_DIR]                  @ dp->dir = fs->win + (ofs % SS(fs));
    movs r0, #FR_OK
    pop {r4, r5, r6, r7, r8, pc}
.Lsdi_int:
    movs r0, #FR_INT_ERR
    pop {r4, r5, r6, r7, r8, pc}
.Lsdi_disk:
    movs r0, #FR_DISK_ERR
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_dir_sdi

@ -----------------------------------------------------------------------------
@ dir_next - move the directory index to the next entry (ff.c dir_next)
@ In       : r0 = dp, r1 = stretch (0: no table stretch, 1: stretch the table if needed)
@ Out      : r0 = FRESULT (FR_NO_FILE at the end, FR_DENIED when the table could not be stretched)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 ofs, r7 stretch, r8 clst
@ -----------------------------------------------------------------------------
FUNC ff16_dir_next
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    mov r7, r1
    ldr r6, [r4, #DIR_DPTR]
    adds r6, r6, #SZDIRE                    @ ofs = dp->dptr + SZDIRE;
    cmp r6, #MAX_DIR                        @ if (ofs >= MAX_DIR) dp->sect = 0;
    itt hs
    movhs r0, #0
    strhs r0, [r4, #DIR_SECT]
    ldr r0, [r4, #DIR_SECT]                 @ if (dp->sect == 0) return FR_NO_FILE;
    cmp r0, #0
    beq .Ldn_nofile
    ubfx r1, r6, #0, #9                     @ if (ofs % SS(fs) == 0) {
    cmp r1, #0
    bne .Ldn_set
    adds r0, r0, #1
    str r0, [r4, #DIR_SECT]                 @   dp->sect++;
    ldr r0, [r4, #DIR_CLUST]                @   if (dp->clust == 0) {
    cbnz r0, 1f
    ldrh r0, [r5, #FS_N_ROOTDIR]            @     if (ofs / SZDIRE >= fs->n_rootdir) { dp->sect = 0; return FR_NO_FILE; }
    cmp r0, r6, lsr #5
    bhi .Ldn_set
    b .Ldn_end
1:  ldrh r1, [r5, #FS_CSIZE]                @   } else { if ((ofs / SS(fs) & (fs->csize - 1)) == 0) {
    subs r1, r1, #1
    lsrs r2, r6, #9
    tst r2, r1
    bne .Ldn_set
    mov r1, r0
    mov r0, r4
    bl ff16_get_fat                         @       clst = get_fat(&dp->obj, dp->clust);
    mov r8, r0
    cmp r8, #1
    bls .Ldn_int                            @       if (clst <= 1) return FR_INT_ERR;
    cmn r8, #1
    beq .Ldn_disk                           @       if (clst == 0xFFFFFFFF) return FR_DISK_ERR;
    ldr r0, [r5, #FS_N_FATENT]
    cmp r8, r0                              @       if (clst >= fs->n_fatent) {
    blo 2f
    cmp r7, #0                              @         if (!stretch) { dp->sect = 0; return FR_NO_FILE; }
    beq .Ldn_end
    mov r0, r4
    ldr r1, [r4, #DIR_CLUST]
    bl ff16_create_chain                    @         clst = create_chain(&dp->obj, dp->clust);
    mov r8, r0
    cmp r8, #0
    beq .Ldn_denied                         @         if (clst == 0) return FR_DENIED;
    cmp r8, #1
    beq .Ldn_int                            @         if (clst == 1) return FR_INT_ERR;
    cmn r8, #1
    beq .Ldn_disk                           @         if (clst == 0xFFFFFFFF) return FR_DISK_ERR;
    mov r0, r5
    mov r1, r8
    bl ff16_dir_clear                       @         if (dir_clear(fs, clst) != FR_OK) return FR_DISK_ERR;
    cmp r0, #0
    bne .Ldn_disk
2:  str r8, [r4, #DIR_CLUST]                @       dp->clust = clst;
    mov r0, r5
    mov r1, r8
    bl ff16_clst2sect
    str r0, [r4, #DIR_SECT]                 @       dp->sect = clst2sect(fs, clst);
.Ldn_set:
    str r6, [r4, #DIR_DPTR]                 @ dp->dptr = ofs;
    ubfx r0, r6, #0, #9
    add r0, r0, r5
    adds r0, r0, #FS_WIN
    str r0, [r4, #DIR_DIR]                  @ dp->dir = fs->win + ofs % SS(fs);
    movs r0, #FR_OK
    pop {r4, r5, r6, r7, r8, pc}
.Ldn_end:
    movs r0, #0
    str r0, [r4, #DIR_SECT]                 @ dp->sect = 0;
.Ldn_nofile:
    movs r0, #FR_NO_FILE
    pop {r4, r5, r6, r7, r8, pc}
.Ldn_int:
    movs r0, #FR_INT_ERR
    pop {r4, r5, r6, r7, r8, pc}
.Ldn_disk:
    movs r0, #FR_DISK_ERR
    pop {r4, r5, r6, r7, r8, pc}
.Ldn_denied:
    movs r0, #FR_DENIED
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_dir_next

@ -----------------------------------------------------------------------------
@ dir_alloc - reserve n_ent consecutive directory entries (ff.c dir_alloc)
@ In       : r0 = dp, r1 = n_ent
@ Out      : r0 = FRESULT (FR_DENIED when the table is full)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 n_ent, r7 n
@ -----------------------------------------------------------------------------
FUNC ff16_dir_alloc
    push {r4, r5, r6, r7, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    mov r6, r1
    movs r1, #0
    bl ff16_dir_sdi                         @ res = dir_sdi(dp, 0);
    cbnz r0, 9f                             @ if (res == FR_OK) {
    movs r7, #0                             @   n = 0;
1:  mov r0, r5                              @   do {
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @     res = move_window(fs, dp->sect);
    cbnz r0, 9f                             @     if (res != FR_OK) break;
    ldr r0, [r4, #DIR_DIR]
    ldrb r0, [r0]                           @     if (dp->dir[0] == DDEM || dp->dir[0] == 0) {
    cmp r0, #DDEM
    beq 2f
    cbz r0, 2f
    movs r7, #0                             @     } else { n = 0; }
    b 3f
2:  adds r7, r7, #1                         @       if (++n == n_ent) break;
    cmp r7, r6
    beq 8f
3:  mov r0, r4
    movs r1, #1
    bl ff16_dir_next                        @     res = dir_next(dp, 1);
    cmp r0, #FR_OK
    beq 1b                                  @   } while (res == FR_OK);
9:  cmp r0, #FR_NO_FILE                     @ if (res == FR_NO_FILE) res = FR_DENIED;
    it eq
    moveq r0, #FR_DENIED
    pop {r4, r5, r6, r7, pc}
8:  movs r0, #FR_OK                         @ break with res = FR_OK (from move_window)
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_dir_alloc

@ -----------------------------------------------------------------------------
@ ld_clust - start cluster of a directory entry (ff.c ld_clust)
@ In       : r0 = fs, r1 = dir (entry pointer)
@ Out      : r0 = cluster
@ Clobbers : r1-r3, flags
@ -----------------------------------------------------------------------------
FUNC ff16_ld_clust
    push {r4, r5, r6, lr}
    mov r4, r0
    mov r5, r1
    add r0, r5, #DIR_FstClusLO
    bl ff16_ld_16                           @ cl = ld_16(dir + DIR_FstClusLO);
    mov r6, r0
    ldrb r0, [r4, #FS_FS_TYPE]              @ if (fs->fs_type == FS_FAT32) {
    cmp r0, #FS_FAT32
    bne 1f
    add r0, r5, #DIR_FstClusHI
    bl ff16_ld_16
    orr r6, r6, r0, lsl #16                 @   cl |= (DWORD)ld_16(dir + DIR_FstClusHI) << 16;
1:  mov r0, r6
    pop {r4, r5, r6, pc}
ENDFUNC ff16_ld_clust

@ -----------------------------------------------------------------------------
@ st_clust - store the start cluster into a directory entry (ff.c st_clust)
@ In       : r0 = fs, r1 = dir, r2 = cl
@ Clobbers : r0-r3, flags
@ -----------------------------------------------------------------------------
FUNC ff16_st_clust
    push {r4, r5, r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    add r0, r5, #DIR_FstClusLO
    uxth r1, r6
    bl ff16_st_16                           @ st_16(dir + DIR_FstClusLO, (WORD)cl);
    ldrb r0, [r4, #FS_FS_TYPE]              @ if (fs->fs_type == FS_FAT32) {
    cmp r0, #FS_FAT32
    bne 1f
    add r0, r5, #DIR_FstClusHI
    lsrs r1, r6, #16
    bl ff16_st_16                           @   st_16(dir + DIR_FstClusHI, (WORD)(cl >> 16));
1:  pop {r4, r5, r6, pc}
ENDFUNC ff16_st_clust

@ -----------------------------------------------------------------------------
@ dir_read - read the next valid entry (ff.c dir_read, without the LFN branch; vol = 0 is the only use: f_readdir)
@ In       : r0 = dp, r1 = vol (0: a file or directory entry, 1: the volume label)
@ Out      : r0 = FRESULT (FR_NO_FILE at the end of the table; dp->sect = 0 on any failure)
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 vol, r7 res
@ -----------------------------------------------------------------------------
FUNC ff16_dir_read
    push {r4, r5, r6, r7, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    mov r6, r1
    movs r7, #FR_NO_FILE                    @ FRESULT res = FR_NO_FILE;
1:  ldr r1, [r4, #DIR_SECT]                 @ while (dp->sect) {
    cbz r1, 8f
    mov r0, r5
    bl ff16_move_window                     @   res = move_window(fs, dp->sect);
    mov r7, r0
    cbnz r7, 8f                             @   if (res != FR_OK) break;
    ldr r3, [r4, #DIR_DIR]
    ldrb r2, [r3, #0]                       @   et = dp->dir[DIR_Name];
    cbnz r2, 2f                             @   if (et == 0) { res = FR_NO_FILE; break; }
    movs r7, #FR_NO_FILE
    b 8f
2:  ldrb r1, [r3, #DIR_Attr]
    and r1, r1, #AM_MASK
    strb r1, [r4, #OBJ_ATTR]                @   dp->obj.attr = attr = dp->dir[DIR_Attr] & AM_MASK;
    @ if (et != DDEM && et != '.' && attr != AM_LFN && (int)((attr & ~AM_ARC) == AM_VOL) == vol) break;
    cmp r2, #DDEM
    beq 3f
    cmp r2, #'.'
    beq 3f
    cmp r1, #AM_LFN
    beq 3f
    bic r0, r1, #AM_ARC
    cmp r0, #AM_VOL
    ite eq
    moveq r0, #1
    movne r0, #0
    cmp r0, r6
    beq 8f                                  @   (break with res = FR_OK)
3:  mov r0, r4
    movs r1, #0
    bl ff16_dir_next                        @   res = dir_next(dp, 0);
    mov r7, r0
    cmp r7, #FR_OK
    beq 1b                                  @   if (res != FR_OK) break;
8:  cbz r7, 9f                              @ if (res != FR_OK) dp->sect = 0;
    movs r0, #0
    str r0, [r4, #DIR_SECT]
9:  mov r0, r7
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_dir_read

@ -----------------------------------------------------------------------------
@ dir_find - find the entry named dp->fn (ff.c dir_find, without the LFN branch)
@ In       : r0 = dp
@ Out      : r0 = FRESULT (FR_OK found, dp points at the entry; FR_NO_FILE not found)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_dir_find
    push {r4, r5, r6, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    movs r1, #0
    bl ff16_dir_sdi                         @ res = dir_sdi(dp, 0);
    cbnz r0, 9f                             @ if (res != FR_OK) return res;
1:  mov r0, r5                              @ do {
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @   res = move_window(fs, dp->sect);
    cbnz r0, 9f                             @   if (res != FR_OK) break;
    ldr r6, [r4, #DIR_DIR]
    ldrb r0, [r6, #0]                       @   c = dp->dir[DIR_Name];
    cbnz r0, 2f                             @   if (c == 0) { res = FR_NO_FILE; break; }
    movs r0, #FR_NO_FILE
    b 9f
2:  ldrb r0, [r6, #DIR_Attr]
    and r1, r0, #AM_MASK
    strb r1, [r4, #OBJ_ATTR]                @   dp->obj.attr = dp->dir[DIR_Attr] & AM_MASK;
    tst r0, #AM_VOL                         @   if (!(dp->dir[DIR_Attr] & AM_VOL) && !memcmp(dp->dir, dp->fn, 11)) break;
    bne 3f
    mov r0, r6
    add r1, r4, #DIR_FN
    movs r2, #11
    bl ff16_memcmp
    cbz r0, 9f                              @   (break with res = FR_OK)
3:  mov r0, r4
    movs r1, #0
    bl ff16_dir_next                        @   res = dir_next(dp, 0);
    cmp r0, #FR_OK
    beq 1b                                  @ } while (res == FR_OK);
9:  pop {r4, r5, r6, pc}
ENDFUNC ff16_dir_find

@ -----------------------------------------------------------------------------
@ dir_register - add the entry named dp->fn (ff.c dir_register, without the LFN branch)
@ In       : r0 = dp
@ Out      : r0 = FRESULT (FR_DENIED when the table is full)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_dir_register
    push {r4, r5, r6, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    movs r1, #1
    bl ff16_dir_alloc                       @ res = dir_alloc(dp, 1);
    cbnz r0, 9f                             @ if (res == FR_OK) {
    mov r0, r5
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @   res = move_window(fs, dp->sect);
    cbnz r0, 9f                             @   if (res == FR_OK) {
    ldr r6, [r4, #DIR_DIR]
    mov r0, r6
    movs r1, #0
    movs r2, #SZDIRE
    bl ff16_memset                          @     memset(dp->dir, 0, SZDIRE);
    mov r0, r6
    add r1, r4, #DIR_FN
    movs r2, #11
    bl ff16_memcpy                          @     memcpy(dp->dir + DIR_Name, dp->fn, 11);
    movs r0, #1
    strb r0, [r5, #FS_WFLAG]                @     fs->wflag = 1;
    movs r0, #FR_OK
9:  pop {r4, r5, r6, pc}
ENDFUNC ff16_dir_register

@ -----------------------------------------------------------------------------
@ dir_remove - mark the current entry deleted (ff.c dir_remove, without the LFN branch)
@ In       : r0 = dp
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_dir_remove
    push {r4, r5, r6, lr}
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    mov r0, r5
    ldr r1, [r4, #DIR_SECT]
    bl ff16_move_window                     @ res = move_window(fs, dp->sect);
    cbnz r0, 9f                             @ if (res == FR_OK) {
    ldr r1, [r4, #DIR_DIR]
    movs r0, #DDEM
    strb r0, [r1, #DIR_Name]                @   dp->dir[DIR_Name] = DDEM;
    movs r0, #1
    strb r0, [r5, #FS_WFLAG]                @   fs->wflag = 1;
    movs r0, #FR_OK
9:  pop {r4, r5, r6, pc}
ENDFUNC ff16_dir_remove

@ -----------------------------------------------------------------------------
@ get_fileinfo - fill a FILINFO from the current entry (ff.c get_fileinfo, FF_USE_LFN 0, FF_FS_CRTIME 0)
@ In       : r0 = dp, r1 = fno
@ Clobbers : r0-r3, r12, flags
@ Registers: r4 dp, r5 fno, r6 si, r7 di, r8 dir
@ -----------------------------------------------------------------------------
FUNC ff16_get_fileinfo
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r0
    mov r5, r1
    movs r0, #0
    strb r0, [r5, #FNO_FNAME]               @ fno->fname[0] = 0;
    ldr r0, [r4, #DIR_SECT]                 @ if (dp->sect == 0) return;
    cbz r0, 9f
    ldr r8, [r4, #DIR_DIR]
    movs r6, #0                             @ si = di = 0;
    movs r7, #0
1:  cmp r6, #11                             @ while (si < 11) {
    bhs 3f
    ldrb r0, [r8, r6]                       @   c = (TCHAR)dp->dir[si++];
    adds r6, r6, #1
    cmp r0, #' '                            @   if (c == ' ') continue;
    beq 1b
    cmp r0, #RDDEM                          @   if (c == RDDEM) c = DDEM;
    it eq
    moveq r0, #DDEM
    cmp r6, #9                              @   if (si == 9) fno->fname[di++] = '.';
    bne 2f
    add r1, r5, r7
    movs r2, #'.'
    strb r2, [r1, #FNO_FNAME]
    adds r7, r7, #1
2:  add r1, r5, r7
    strb r0, [r1, #FNO_FNAME]               @   fno->fname[di++] = c;
    adds r7, r7, #1
    b 1b
3:  add r1, r5, r7
    movs r0, #0
    strb r0, [r1, #FNO_FNAME]               @ fno->fname[di] = 0;
    ldrb r0, [r8, #DIR_Attr]
    and r0, r0, #AM_MASK
    strb r0, [r5, #FNO_FATTRIB]             @ fno->fattrib = dp->dir[DIR_Attr] & AM_MASK;
    add r0, r8, #DIR_FileSize
    bl ff16_ld_32
    str r0, [r5, #FNO_FSIZE]                @ fno->fsize = ld_32(dp->dir + DIR_FileSize);
    add r0, r8, #DIR_ModTime
    bl ff16_ld_16
    strh r0, [r5, #FNO_FTIME]               @ fno->ftime = ld_16(dp->dir + DIR_ModTime + 0);
    add r0, r8, #(DIR_ModTime + 2)
    bl ff16_ld_16
    strh r0, [r5, #FNO_FDATE]               @ fno->fdate = ld_16(dp->dir + DIR_ModTime + 2);
9:  pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_get_fileinfo

@ -----------------------------------------------------------------------------
@ create_name - the next path segment as an 8.3 name in dp->fn (ff.c create_name, FF_USE_LFN 0, CP932)
@ In       : r0 = dp, r1 = path (pointer to the path pointer)
@ Out      : r0 = FRESULT (FR_INVALID_NAME); *path advanced past the segment
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp->fn (sfn), r5 path pointer pointer, r6 p, r7 si, r8 i, r9 ni, r10 c
@ -----------------------------------------------------------------------------
FUNC ff16_create_name
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    add r4, r0, #DIR_FN                     @ sfn = dp->fn;
    mov r5, r1
    ldr r6, [r5]                            @ p = *path;
    mov r0, r4
    movs r1, #' '
    movs r2, #11
    bl ff16_memset                          @ memset(sfn, ' ', 11);
    movs r7, #0                             @ si = i = 0; ni = 8;
    movs r8, #0
    movs r9, #8
.Lcn_loop:                                  @ for (;;) {
    ldrb r10, [r6, r7]                      @   c = (BYTE)p[si++];
    adds r7, r7, #1
    cmp r10, #' '                           @   if (c <= ' ') break;
    bls .Lcn_end
    cmp r10, #'/'                           @   if (IsSeparator(c)) {
    beq 1f
    cmp r10, #'\\'
    bne 2f
1:  ldrb r0, [r6, r7]                       @     while (IsSeparator(p[si])) si++;
    cmp r0, #'/'
    beq 11f
    cmp r0, #'\\'
    bne .Lcn_end                            @     break;
11: adds r7, r7, #1
    b 1b
2:  cmp r10, #'.'                           @   if (c == '.' || i >= ni) {
    beq 3f
    cmp r8, r9
    blo 4f
3:  cmp r9, #11                             @     if (ni == 11 || c != '.') return FR_INVALID_NAME;
    beq .Lcn_inv
    cmp r10, #'.'
    bne .Lcn_inv
    movs r8, #8                             @     i = 8; ni = 11;
    movs r9, #11
    b .Lcn_loop                             @     continue;
4:  mov r0, r10
    bl ff16_dbc_1st                         @   if (dbc_1st(c)) {
    cbz r0, 5f
    ldrb r12, [r6, r7]                      @     d = (BYTE)p[si++];
    adds r7, r7, #1
    push {r12}
    mov r0, r12
    bl ff16_dbc_2nd
    pop {r12}
    cbz r0, .Lcn_inv                        @     if (!dbc_2nd(d) || i >= ni - 1) return FR_INVALID_NAME;
    sub r0, r9, #1
    cmp r8, r0
    bhs .Lcn_inv
    strb r10, [r4, r8]                      @     sfn[i++] = c;
    adds r8, r8, #1
    strb r12, [r4, r8]                      @     sfn[i++] = d;
    adds r8, r8, #1
    b .Lcn_loop
5:  ldr r0, =ff16_badchr                    @   } else { if (strchr("*+,:;<=>[]|\"\?\x7F", (int)c)) return FR_INVALID_NAME;
6:  ldrb r1, [r0], #1
    cbz r1, 7f                              @     (strchr matches the terminating 0 too, but c > ' ' here)
    cmp r1, r10
    beq .Lcn_inv
    b 6b
7:  sub r0, r10, #'a'                       @     if (IsLower(c)) c -= 0x20;
    cmp r0, #('z' - 'a')
    it ls
    subls r10, r10, #0x20
    strb r10, [r4, r8]                      @     sfn[i++] = c;
    adds r8, r8, #1
    b .Lcn_loop
.Lcn_end:
    add r0, r6, r7
    str r0, [r5]                            @ *path = &p[si];
    cmp r8, #0                              @ if (i == 0) return FR_INVALID_NAME;
    beq .Lcn_inv
    ldrb r0, [r4, #0]                       @ if (sfn[DIR_Name] == DDEM) sfn[DIR_Name] = RDDEM;
    cmp r0, #DDEM
    itt eq
    moveq r0, #RDDEM
    strbeq r0, [r4, #0]
    movs r1, #0                             @ sfn[NSFLAG] = (c <= ' ' || p[si] <= ' ') ? NS_LAST : 0;
    cmp r10, #' '
    bls 8f
    ldrb r0, [r6, r7]
    cmp r0, #' '
    bhi 9f
8:  movs r1, #NS_LAST
9:  strb r1, [r4, #NSFLAG]
    movs r0, #FR_OK
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
.Lcn_inv:
    movs r0, #FR_INVALID_NAME
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
    .ltorg
ENDFUNC ff16_create_name

@ -----------------------------------------------------------------------------
@ follow_path - follow a path to the object (ff.c follow_path, FF_FS_RPATH 0, FF_USE_LFN 0)
@ In       : r0 = dp, r1 = path
@ Out      : r0 = FRESULT; dp points at the object (or at the origin directory with fn[NSFLAG] = NS_NONAME for "")
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 dp, r5 fs, r6 ns; the path pointer lives at [sp] (create_name advances it)
@ -----------------------------------------------------------------------------
FUNC ff16_follow_path
    push {r1, r4, r5, r6, r7, lr}           @ [sp] = path
    mov r4, r0
    ldr r5, [r4, #OBJ_FS]                   @ FATFS *fs = dp->obj.fs;
    ldr r0, [sp]
1:  ldrb r1, [r0]                           @ while (IsSeparator(*path)) path++;
    cmp r1, #'/'
    beq 2f
    cmp r1, #'\\'
    bne 3f
2:  adds r0, r0, #1
    b 1b
3:  str r0, [sp]
    movs r2, #0
    str r2, [r4, #OBJ_SCLUST]               @ dp->obj.sclust = 0;
    cmp r1, #' '                            @ if ((UINT)*path < ' ') {
    bhs .Lfp_loop
    movs r0, #NS_NONAME
    strb r0, [r4, #(DIR_FN + NSFLAG)]       @   dp->fn[NSFLAG] = NS_NONAME;
    mov r0, r4
    movs r1, #0
    bl ff16_dir_sdi                         @   res = dir_sdi(dp, 0);
    b .Lfp_ret
.Lfp_loop:                                  @ } else { for (;;) {
    mov r0, r4
    mov r1, sp
    bl ff16_create_name                     @   res = create_name(dp, &path);
    cbnz r0, .Lfp_ret                       @   if (res != FR_OK) break;
    ldrb r6, [r4, #(DIR_FN + NSFLAG)]       @   ns = dp->fn[NSFLAG];
    mov r0, r4
    bl ff16_dir_find                        @   res = dir_find(dp);
    cbz r0, 4f                              @   if (res != FR_OK) {
    cmp r0, #FR_NO_FILE                     @     if (res == FR_NO_FILE) {
    bne .Lfp_ret
    tst r6, #NS_LAST                        @       if (!(ns & NS_LAST)) res = FR_NO_PATH;
    it eq
    moveq r0, #FR_NO_PATH
    b .Lfp_ret                              @     break;
4:  tst r6, #NS_LAST                        @   if (ns & NS_LAST) break;
    bne .Lfp_ret
    ldrb r1, [r4, #OBJ_ATTR]                @   if (!(dp->obj.attr & AM_DIR)) { res = FR_NO_PATH; break; }
    tst r1, #AM_DIR
    beq .Lfp_nopath
    ldr r1, [r4, #DIR_DPTR]
    ubfx r1, r1, #0, #9
    add r1, r1, r5
    adds r1, r1, #FS_WIN
    mov r0, r5
    bl ff16_ld_clust
    str r0, [r4, #OBJ_SCLUST]               @   dp->obj.sclust = ld_clust(fs, fs->win + dp->dptr % SS(fs));
    b .Lfp_loop
.Lfp_nopath:
    movs r0, #FR_NO_PATH
.Lfp_ret:
    add sp, sp, #4
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_follow_path

    .section .rodata.ff16.dir, "a", %progbits
@ characters not allowed in an 8.3 name (ff.c create_name: "*+,:;<=>[]|\"\?\x7F")
ff16_badchr:
    .ascii "*+,:;<=>[]|\"?\x7F"
    .byte 0

