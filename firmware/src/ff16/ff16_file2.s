@ =============================================================================
@ ff16_file2.s - FatFs R0.16 (production image): f_lseek, f_opendir, f_readdir, f_stat, f_getfree, f_unlink, f_rename,
@ f_utime (DESIGN.md 7A, IMP-29)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c, FF_USE_FASTSEEK 0, FF_FS_EXFAT 0, FF_FS_RPATH 0, FF_USE_LFN 0,
@ FF_FS_LOCK 0, FF_USE_CHMOD 1 for f_utime).  DIR objects of these functions live on the stack as in the C code.
@ License and conventions: ff16_low.s.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "config.inc"

    .include "ff16.inc"

    .section .text.ff16.file2, "ax", %progbits

@ -----------------------------------------------------------------------------
@ f_lseek - move the file read/write pointer (ff.c f_lseek without the fast-seek branch)
@ In       : r0 = fp, r1 = ofs
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fp, r5 ofs, r6 fs, r7 bcs, r8 clst, r9 nsect, r10 ifptr
@ -----------------------------------------------------------------------------
FUNC ff16_f_lseek
    push {r4, r5, r6, r7, r8, r9, r10, lr}
    sub sp, sp, #8                          @ [sp] = fs
    mov r4, r0
    mov r5, r1
    mov r1, sp
    bl ff16_validate                        @ res = validate(&fp->obj, &fs);
    cmp r0, #0                       @ if (res == FR_OK) res = (FRESULT)fp->err;  if (res != FR_OK) return res;
    bne .Lls_ret
    ldrb r0, [r4, #FIL_ERR]
    cmp r0, #0
    bne .Lls_ret
    ldr r6, [sp]
    ldr r0, [r4, #OBJ_OBJSIZE]              @ if (ofs > fp->obj.objsize && (FF_FS_READONLY || !(fp->flag & FA_WRITE))) ofs = fp->obj.objsize;
    cmp r5, r0
    bls 1f
    ldrb r1, [r4, #FIL_FLAG]
    tst r1, #FA_WRITE
    it eq
    moveq r5, r0
1:  ldr r10, [r4, #FIL_FPTR]                @ ifptr = fp->fptr;
    movs r9, #0                             @ fp->fptr = nsect = 0;
    str r9, [r4, #FIL_FPTR]
    cmp r5, #0                              @ if (ofs > 0) {
    beq .Lls_after
    ldrh r7, [r6, #FS_CSIZE]
    lsl r7, r7, #9                          @   bcs = (DWORD)fs->csize * SS(fs);
    cmp r10, #0                             @   if (ifptr > 0 && (ofs - 1) / bcs >= (ifptr - 1) / bcs) {
    beq 2f
    subs r0, r5, #1
    udiv r0, r0, r7
    subs r1, r10, #1
    udiv r2, r1, r7
    cmp r0, r2
    blo 2f
    subs r0, r7, #1
    bic r0, r1, r0
    str r0, [r4, #FIL_FPTR]                 @     fp->fptr = (ifptr - 1) & ~(FSIZE_t)(bcs - 1);
    subs r5, r5, r0                         @     ofs -= fp->fptr;
    ldr r8, [r4, #FIL_CLUST]                @     clst = fp->clust;
    b 3f
2:  ldr r8, [r4, #OBJ_SCLUST]               @   } else { clst = fp->obj.sclust;
    cmp r8, #0                              @     if (clst == 0) {
    bne 21f
    mov r0, r4
    movs r1, #0
    bl ff16_create_chain                    @       clst = create_chain(&fp->obj, 0);
    mov r8, r0
    cmp r8, #1
    beq .Lls_int                            @       if (clst == 1) ABORT(fs, FR_INT_ERR);
    cmn r8, #1
    beq .Lls_disk                           @       if (clst == 0xFFFFFFFF) ABORT(fs, FR_DISK_ERR);
    str r8, [r4, #OBJ_SCLUST]               @       fp->obj.sclust = clst;
21: str r8, [r4, #FIL_CLUST]                @     fp->clust = clst;
3:  cmp r8, #0                              @   if (clst != 0) {
    beq .Lls_after
4:  cmp r5, r7                              @     while (ofs > bcs) {
    bls 6f
    sub r5, r5, r7                          @       ofs -= bcs;
    ldr r0, [r4, #FIL_FPTR]
    add r0, r0, r7
    str r0, [r4, #FIL_FPTR]                 @       fp->fptr += bcs;
    ldrb r0, [r4, #FIL_FLAG]                @       if (fp->flag & FA_WRITE) {
    tst r0, #FA_WRITE
    beq 41f
    mov r0, r4
    mov r1, r8
    bl ff16_create_chain                    @         clst = create_chain(&fp->obj, clst);
    mov r8, r0
    cmp r8, #0                              @         if (clst == 0) { ofs = 0; break; }
    bne 42f
    movs r5, #0
    b 6f
41: mov r0, r4                              @       } else { clst = get_fat(&fp->obj, clst); }
    mov r1, r8
    bl ff16_get_fat
    mov r8, r0
42: cmn r8, #1                              @       if (clst == 0xFFFFFFFF) ABORT(fs, FR_DISK_ERR);
    beq .Lls_disk
    cmp r8, #1                              @       if (clst <= 1 || clst >= fs->n_fatent) ABORT(fs, FR_INT_ERR);
    bls .Lls_int
    ldr r0, [r6, #FS_N_FATENT]
    cmp r8, r0
    bhs .Lls_int
    str r8, [r4, #FIL_CLUST]                @       fp->clust = clst;
    b 4b
6:  ldr r0, [r4, #FIL_FPTR]
    add r0, r0, r5
    str r0, [r4, #FIL_FPTR]                 @     fp->fptr += ofs;
    ubfx r0, r5, #0, #9                     @     if (ofs % SS(fs)) {
    cbz r0, .Lls_after
    mov r0, r6
    mov r1, r8
    bl ff16_clst2sect                       @       nsect = clst2sect(fs, clst);
    cmp r0, #0                              @       if (nsect == 0) ABORT(fs, FR_INT_ERR);
    beq .Lls_int
    add r9, r0, r5, lsr #9                  @       nsect += (DWORD)(ofs / SS(fs));
.Lls_after:
    ldr r0, [r4, #FIL_FPTR]                 @ if (!FF_FS_READONLY && fp->fptr > fp->obj.objsize) {
    ldr r1, [r4, #OBJ_OBJSIZE]
    cmp r0, r1
    bls 7f
    str r0, [r4, #OBJ_OBJSIZE]              @   fp->obj.objsize = fp->fptr;
    ldrb r1, [r4, #FIL_FLAG]
    orr r1, r1, #FA_MODIFIED
    strb r1, [r4, #FIL_FLAG]                @   fp->flag |= FA_MODIFIED;
7:  ubfx r0, r0, #0, #9                     @ if (fp->fptr % SS(fs) && nsect != fp->sect) {
    cbz r0, .Lls_ok
    ldr r0, [r4, #FIL_SECT]
    cmp r9, r0
    beq .Lls_ok
    ldrb r1, [r4, #FIL_FLAG]                @   if (fp->flag & FA_DIRTY) {
    tst r1, #FA_DIRTY
    beq 8f
    mov r2, r0                              @     if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    ldrb r0, [r6, #FS_PDRV]
    add r1, r4, #FIL_BUF
    movs r3, #1
    bl disk_write
    cmp r0, #0
    bne .Lls_disk
    ldrb r1, [r4, #FIL_FLAG]
    bic r1, r1, #FA_DIRTY
    strb r1, [r4, #FIL_FLAG]                @     fp->flag &= (BYTE)~FA_DIRTY;
8:  ldrb r0, [r6, #FS_PDRV]                 @   if (disk_read(fs->pdrv, fp->buf, nsect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    mov r2, r9
    movs r3, #1
    bl disk_read
    cmp r0, #0
    bne .Lls_disk
    str r9, [r4, #FIL_SECT]                 @   fp->sect = nsect;
.Lls_ok:
    movs r0, #FR_OK                         @ return res (FR_OK)
    b .Lls_ret
.Lls_int:
    movs r0, #FR_INT_ERR
    strb r0, [r4, #FIL_ERR]
    b .Lls_ret
.Lls_disk:
    movs r0, #FR_DISK_ERR
    strb r0, [r4, #FIL_ERR]
.Lls_ret:
    add sp, sp, #8
    pop {r4, r5, r6, r7, r8, r9, r10, pc}
ENDFUNC ff16_f_lseek

@ -----------------------------------------------------------------------------
@ f_opendir - open a directory (ff.c f_opendir)
@ In       : r0 = dp, r1 = path
@ Out      : r0 = FRESULT (dp->obj.fs = 0 on failure)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_f_opendir
    push {r4, r5, r6, lr}
    sub sp, sp, #8                          @ [sp] = fs, [sp + 4] = path
    str r1, [sp, #4]
    mov r4, r0
    cbnz r4, 1f                             @ if (!dp) return FR_INVALID_OBJECT;
    movs r0, #FR_INVALID_OBJECT
    b 9f
1:  add r0, sp, #4
    mov r1, sp
    movs r2, #0
    bl ff16_mount_volume                    @ res = mount_volume(&path, &fs, 0);
    mov r6, r0
    cbnz r6, 8f                             @ if (res == FR_OK) {
    ldr r5, [sp]
    str r5, [r4, #OBJ_FS]                   @   dp->obj.fs = fs;
    mov r0, r4
    ldr r1, [sp, #4]
    bl ff16_follow_path                     @   res = follow_path(dp, path);
    mov r6, r0
    cbnz r6, 7f                             @   if (res == FR_OK) {
    ldrb r0, [r4, #(DIR_FN + NSFLAG)]       @     if (!(dp->fn[NSFLAG] & NS_NONAME)) {
    tst r0, #NS_NONAME
    bne 3f
    ldrb r0, [r4, #OBJ_ATTR]                @       if (dp->obj.attr & AM_DIR) dp->obj.sclust = ld_clust(fs, dp->dir);
    tst r0, #AM_DIR
    beq 2f
    mov r0, r5
    ldr r1, [r4, #DIR_DIR]
    bl ff16_ld_clust
    str r0, [r4, #OBJ_SCLUST]
    b 3f
2:  movs r6, #FR_NO_PATH                    @       else res = FR_NO_PATH;
    b 7f
3:  ldrh r0, [r5, #FS_ID]                   @     if (res == FR_OK) { dp->obj.id = fs->id; res = dir_sdi(dp, 0); }
    strh r0, [r4, #OBJ_ID]
    mov r0, r4
    movs r1, #0
    bl ff16_dir_sdi
    mov r6, r0
7:  cmp r6, #FR_NO_FILE                     @   if (res == FR_NO_FILE) res = FR_NO_PATH;
    it eq
    moveq r6, #FR_NO_PATH
8:  cbz r6, 81f                             @ if (res != FR_OK) dp->obj.fs = 0;
    movs r0, #0
    str r0, [r4, #OBJ_FS]
81: mov r0, r6
9:  add sp, sp, #8
    pop {r4, r5, r6, pc}
ENDFUNC ff16_f_opendir

@ -----------------------------------------------------------------------------
@ f_readdir - read the next directory item (ff.c f_readdir, FF_USE_LFN 0); fno = 0 rewinds
@ In       : r0 = dp, r1 = fno
@ Out      : r0 = FRESULT (end of directory: FR_OK with fno->fname[0] = 0)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_f_readdir
    push {r4, r5, r6, lr}
    sub sp, sp, #8
    mov r4, r0
    mov r5, r1
    mov r1, sp
    bl ff16_validate                        @ res = validate(&dp->obj, &fs);
    mov r6, r0
    cbnz r6, 8f                             @ if (res == FR_OK) {
    cbnz r5, 1f                             @   if (!fno) res = dir_sdi(dp, 0);
    mov r0, r4
    movs r1, #0
    bl ff16_dir_sdi
    mov r6, r0
    b 8f
1:  movs r0, #0                             @   else { fno->fname[0] = 0 (FF_USE_LFN 0: the INIT_NAMBUF is empty; ff.c sets it here)
    strb r0, [r5, #FNO_FNAME]
    mov r0, r4
    movs r1, #0
    bl ff16_dir_read                        @     res = dir_read(dp, 0);
    mov r6, r0
    cmp r6, #FR_NO_FILE                     @     if (res == FR_NO_FILE) res = FR_OK;
    it eq
    moveq r6, #FR_OK
    cbnz r6, 8f                             @     if (res == FR_OK) {
    mov r0, r4
    mov r1, r5
    bl ff16_get_fileinfo                    @       get_fileinfo(dp, fno);
    mov r0, r4
    movs r1, #0
    bl ff16_dir_next                        @       res = dir_next(dp, 0);
    mov r6, r0
    cmp r6, #FR_NO_FILE                     @       if (res == FR_NO_FILE) res = FR_OK;
    it eq
    moveq r6, #FR_OK
8:  cbz r5, 9f                              @ if (fno && res != FR_OK) fno->fname[0] = 0;
    cbz r6, 9f
    movs r0, #0
    strb r0, [r5, #FNO_FNAME]
9:  mov r0, r6
    add sp, sp, #8
    pop {r4, r5, r6, pc}
ENDFUNC ff16_f_readdir

@ -----------------------------------------------------------------------------
@ f_stat - get file status (ff.c f_stat)
@ In       : r0 = path, r1 = fno (may be 0)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Stack    : [sp] path, [sp + 4 ..] DIR dj
@ -----------------------------------------------------------------------------
    .equ ST_PATH, 0
    .equ ST_DJ, 4
    .equ ST_FRAME, (4 + DIR_SIZE + 4)       @ 52: with the 4 registers pushed the stack stays 8-byte aligned
FUNC ff16_f_stat
    push {r4, r5, r6, lr}
    sub sp, sp, #ST_FRAME
    str r0, [sp, #ST_PATH]
    mov r5, r1
    add r4, sp, #ST_DJ                      @ r4 = &dj
    add r0, sp, #ST_PATH
    add r1, r4, #OBJ_FS
    movs r2, #0
    bl ff16_mount_volume                    @ res = mount_volume(&path, &dj.obj.fs, 0);
    mov r6, r0
    cbnz r6, 8f                             @ if (res == FR_OK) {
    mov r0, r4
    ldr r1, [sp, #ST_PATH]
    bl ff16_follow_path                     @   res = follow_path(&dj, path);
    mov r6, r0
    cbnz r6, 8f                             @   if (res == FR_OK) {
    ldrb r0, [r4, #(DIR_FN + NSFLAG)]       @     if (dj.fn[NSFLAG] & NS_NONAME) res = FR_INVALID_NAME;
    tst r0, #NS_NONAME
    beq 1f
    movs r6, #FR_INVALID_NAME
    b 8f
1:  cbz r5, 8f                              @     else if (fno) get_fileinfo(&dj, fno);
    mov r0, r4
    mov r1, r5
    bl ff16_get_fileinfo
8:  cbz r5, 9f                              @ if (fno && res != FR_OK) fno->fname[0] = 0;
    cbz r6, 9f
    movs r0, #0
    strb r0, [r5, #FNO_FNAME]
9:  mov r0, r6
    add sp, sp, #ST_FRAME
    pop {r4, r5, r6, pc}
ENDFUNC ff16_f_stat

@ -----------------------------------------------------------------------------
@ f_getfree - number of free clusters (ff.c f_getfree, FAT only)
@ In       : r0 = path, r1 = nclst (DWORD* out), r2 = fatfs (FATFS** out)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Stack    : [sp] fs, [sp + 4] path, [sp + 8 ..] FFOBJID obj (16)
@ Registers: r4 nclst, r5 fatfs, r6 fs, r7 nfree, r8 clst, r9 sect, r10 i, r11 res
@ -----------------------------------------------------------------------------
FUNC ff16_f_getfree
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #28
    str r0, [sp, #4]
    mov r4, r1
    mov r5, r2
    add r0, sp, #4
    mov r1, sp
    movs r2, #0
    bl ff16_mount_volume                    @ res = mount_volume(&path, &fs, 0);
    mov r11, r0
    cmp r11, #FR_OK                         @ if (res == FR_OK) {
    bne .Lgfr_ret
    ldr r6, [sp]
    str r6, [r5]                            @   *fatfs = fs;
    ldr r0, [r6, #FS_FREE_CLST]             @   if (fs->free_clst <= fs->n_fatent - 2) {
    ldr r1, [r6, #FS_N_FATENT]
    subs r1, r1, #2
    cmp r0, r1
    bhi 1f
    str r0, [r4]                            @     *nclst = fs->free_clst;
    b .Lgfr_ret
1:  movs r7, #0                             @   } else { nfree = 0;
    ldrb r0, [r6, #FS_FS_TYPE]              @     if (fs->fs_type == FS_FAT12) {
    cmp r0, #FS_FAT12
    bne 4f
    movs r8, #2                             @       clst = 2; obj.fs = fs;
    str r6, [sp, #(8 + OBJ_FS)]
2:  add r0, sp, #8                          @       do {
    mov r1, r8
    bl ff16_get_fat                         @         stat = get_fat(&obj, clst);
    cmn r0, #1                              @         if (stat == 0xFFFFFFFF) { res = FR_DISK_ERR; break; }
    bne 21f
    movs r11, #FR_DISK_ERR
    b 7f
21: cmp r0, #1                              @         if (stat == 1) { res = FR_INT_ERR; break; }
    bne 22f
    movs r11, #FR_INT_ERR
    b 7f
22: cmp r0, #0                              @         if (stat == 0) nfree++;
    it eq
    addeq r7, r7, #1
    adds r8, r8, #1                         @       } while (++clst < fs->n_fatent);
    ldr r0, [r6, #FS_N_FATENT]
    cmp r8, r0
    blo 2b
    b 7f
4:  ldr r8, [r6, #FS_N_FATENT]              @     } else { clst = fs->n_fatent;
    ldr r9, [r6, #FS_FATBASE]               @       sect = fs->fatbase;
    movs r10, #0                            @       i = 0;
5:  cmp r10, #0
    bne 51f                           @       do { if (i == 0) {
    mov r0, r6
    mov r1, r9
    adds r9, r9, #1
    bl ff16_move_window                     @           res = move_window(fs, sect++);
    mov r11, r0
    cmp r11, #0                             @           if (res != FR_OK) break;
    bne 7f
51: add r0, r6, r10
    adds r0, r0, #FS_WIN
    ldrb r1, [r6, #FS_FS_TYPE]              @         if (fs->fs_type == FS_FAT16) {
    cmp r1, #FS_FAT16
    bne 52f
    bl ff16_ld_16                           @           if (ld_16(fs->win + i) == 0) nfree++;
    cmp r0, #0
    it eq
    addeq r7, r7, #1
    adds r10, r10, #2                       @           i += 2;
    b 53f
52: bl ff16_ld_32                           @         } else { if ((ld_32(fs->win + i) & 0x0FFFFFFF) == 0) nfree++;
    bics r0, r0, #0xF0000000
    it eq
    addeq r7, r7, #1
    adds r10, r10, #4                       @           i += 4;
53: ubfx r10, r10, #0, #9                   @         i %= SS(fs);
    subs r8, r8, #1                         @       } while (--clst);
    bne 5b
7:  cmp r11, #FR_OK                         @     if (res == FR_OK) {
    bne .Lgfr_ret
    str r7, [r4]                            @       *nclst = nfree;
    str r7, [r6, #FS_FREE_CLST]             @       fs->free_clst = nfree;
    ldrb r0, [r6, #FS_FSI_FLAG]
    orr r0, r0, #1
    strb r0, [r6, #FS_FSI_FLAG]             @       fs->fsi_flag |= 1;
.Lgfr_ret:
    mov r0, r11
    add sp, sp, #28
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC ff16_f_getfree

@ -----------------------------------------------------------------------------
@ f_unlink - delete a file or an empty directory (ff.c f_unlink)
@ In       : r0 = path
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Stack    : [sp] fs, [sp + 4] path, [sp + 8] DIR dj, [sp + 8 + DIR_SIZE] DIR sdj
@ Registers: r4 &dj, r5 &sdj, r6 fs, r7 dclst, r8 res
@ -----------------------------------------------------------------------------
    .equ UL_FS, 0
    .equ UL_PATH, 4
    .equ UL_DJ, 8
    .equ UL_SDJ, (8 + DIR_SIZE)
    .equ UL_FRAME, (8 + 2 * DIR_SIZE)       @ 96: 8-byte aligned with the 6 registers pushed
FUNC ff16_f_unlink
    push {r4, r5, r6, r7, r8, lr}
    sub sp, sp, #UL_FRAME
    str r0, [sp, #UL_PATH]
    add r4, sp, #UL_DJ
    add r5, sp, #UL_SDJ
    movs r7, #0                             @ DWORD dclst = 0;
    add r0, sp, #UL_PATH
    add r1, sp, #UL_FS
    movs r2, #FA_WRITE
    bl ff16_mount_volume                    @ res = mount_volume(&path, &fs, FA_WRITE);
    mov r8, r0
    cmp r8, #FR_OK                          @ if (res == FR_OK) {
    bne .Lul_ret
    ldr r6, [sp, #UL_FS]
    str r6, [r4, #OBJ_FS]                   @   dj.obj.fs = fs;
    mov r0, r4
    ldr r1, [sp, #UL_PATH]
    bl ff16_follow_path                     @   res = follow_path(&dj, path);
    mov r8, r0
    cmp r8, #0                             @   if (res == FR_OK) {
    bne 2f
    ldrb r0, [r4, #(DIR_FN + NSFLAG)]       @     if (dj.fn[NSFLAG] & (NS_DOT | NS_NONAME)) res = FR_INVALID_NAME;
    tst r0, #(NS_DOT | NS_NONAME)
    beq 1f
    movs r8, #FR_INVALID_NAME
    b 2f
1:  ldrb r0, [r4, #OBJ_ATTR]                @     else if (dj.obj.attr & AM_RDO) res = FR_DENIED;
    tst r0, #AM_RDO
    it ne
    movne r8, #FR_DENIED
2:  cmp r8, #FR_OK                          @   if (res == FR_OK) {
    bne .Lul_ret
    mov r0, r6
    ldr r1, [r4, #DIR_DIR]
    bl ff16_ld_clust
    mov r7, r0                              @     dclst = ld_clust(fs, dj.dir);
    ldrb r0, [r4, #OBJ_ATTR]                @     if (dj.obj.attr & AM_DIR) {
    tst r0, #AM_DIR
    beq 4f
    str r6, [r5, #OBJ_FS]                   @       sdj.obj.fs = fs;
    str r7, [r5, #OBJ_SCLUST]               @       sdj.obj.sclust = dclst;
    mov r0, r5
    movs r1, #0
    bl ff16_dir_sdi                         @       res = dir_sdi(&sdj, 0);
    mov r8, r0
    cmp r8, #0                             @       if (res == FR_OK) {
    bne 3f
    mov r0, r5
    movs r1, #0
    bl ff16_dir_read                        @         res = dir_read(&sdj, 0);
    mov r8, r0
    cmp r8, #FR_OK                          @         if (res == FR_OK) res = FR_DENIED;
    it eq
    moveq r8, #FR_DENIED
    cmp r8, #FR_NO_FILE                     @         if (res == FR_NO_FILE) res = FR_OK;
    it eq
    moveq r8, #FR_OK
3:  cmp r8, #FR_OK
    bne .Lul_ret
4:  mov r0, r4                              @   if (res == FR_OK) {
    bl ff16_dir_remove                      @     res = dir_remove(&dj);
    mov r8, r0
    cmp r8, #0                       @     if (res == FR_OK && dclst != 0) res = remove_chain(&dj.obj, dclst, 0);
    bne .Lul_ret
    cbz r7, 5f
    mov r0, r4
    mov r1, r7
    movs r2, #0
    bl ff16_remove_chain
    mov r8, r0
    cmp r8, #0
    bne .Lul_ret
5:  mov r0, r6                              @     if (res == FR_OK) res = sync_fs(fs);
    bl ff16_sync_fs
    mov r8, r0
.Lul_ret:
    mov r0, r8
    add sp, sp, #UL_FRAME
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_f_unlink

@ -----------------------------------------------------------------------------
@ f_rename - rename / move a file or directory (ff.c f_rename, FF_USE_LFN 0)
@ In       : r0 = path_old, r1 = path_new
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Stack    : [sp] fs, [sp + 4] path_old, [sp + 8] path_new, [sp + 12] BYTE buf[32], [sp + 44] DIR djo, [sp + 44 + DIR_SIZE] DIR djn
@ Registers: r4 &djo, r5 &djn, r6 fs, r7 dir, r8 res
@ -----------------------------------------------------------------------------
    .equ RN_FS, 0
    .equ RN_OLD, 4
    .equ RN_NEW, 8
    .equ RN_BUF, 12
    .equ RN_DJO, 44
    .equ RN_DJN, (44 + DIR_SIZE)
    .equ RN_FRAME, (44 + 2 * DIR_SIZE + 4)  @ 136: 8-byte aligned with the 6 registers pushed
FUNC ff16_f_rename
    push {r4, r5, r6, r7, r8, lr}
    sub sp, sp, #RN_FRAME
    str r0, [sp, #RN_OLD]
    str r1, [sp, #RN_NEW]
    add r4, sp, #RN_DJO
    add r5, sp, #RN_DJN
    add r0, sp, #RN_NEW
    bl ff16_get_ldnumber                    @ get_ldnumber(&path_new);  (ignore the drive number of the new path)
    add r0, sp, #RN_OLD
    add r1, sp, #RN_FS
    movs r2, #FA_WRITE
    bl ff16_mount_volume                    @ res = mount_volume(&path_old, &fs, FA_WRITE);
    mov r8, r0
    cmp r8, #FR_OK                          @ if (res == FR_OK) {
    bne .Lrn_ret
    ldr r6, [sp, #RN_FS]
    str r6, [r4, #OBJ_FS]                   @   djo.obj.fs = fs;
    mov r0, r4
    ldr r1, [sp, #RN_OLD]
    bl ff16_follow_path                     @   res = follow_path(&djo, path_old);
    mov r8, r0
    cmp r8, #0                       @   if (res == FR_OK) { if (djo.fn[NSFLAG] & (NS_DOT | NS_NONAME)) res = FR_INVALID_NAME; }
    bne .Lrn_ret
    ldrb r0, [r4, #(DIR_FN + NSFLAG)]
    tst r0, #(NS_DOT | NS_NONAME)
    beq 1f
    movs r8, #FR_INVALID_NAME
    b .Lrn_ret
1:  add r0, sp, #RN_BUF                     @   if (res == FR_OK) { memcpy(buf, djo.dir, SZDIRE);
    ldr r1, [r4, #DIR_DIR]
    movs r2, #SZDIRE
    bl ff16_memcpy
    mov r0, r5                              @     memcpy(&djn, &djo, sizeof djn);
    mov r1, r4
    movs r2, #DIR_SIZE
    bl ff16_memcpy
    mov r0, r5
    ldr r1, [sp, #RN_NEW]
    bl ff16_follow_path                     @     res = follow_path(&djn, path_new);
    mov r8, r0
    cmp r8, #0                             @     if (res == FR_OK) res = (djn.obj.sclust == djo.obj.sclust && djn.dptr == djo.dptr) ? FR_NO_FILE : FR_EXIST;
    bne 2f
    movs r8, #FR_EXIST
    ldr r0, [r5, #OBJ_SCLUST]
    ldr r1, [r4, #OBJ_SCLUST]
    cmp r0, r1
    bne 2f
    ldr r0, [r5, #DIR_DPTR]
    ldr r1, [r4, #DIR_DPTR]
    cmp r0, r1
    it eq
    moveq r8, #FR_NO_FILE
2:  cmp r8, #FR_NO_FILE                     @     if (res == FR_NO_FILE) {
    bne 6f
    mov r0, r5
    bl ff16_dir_register                    @       res = dir_register(&djn);
    mov r8, r0
    cmp r8, #0                             @       if (res == FR_OK) {
    bne 6f
    ldr r7, [r5, #DIR_DIR]                  @         dir = djn.dir;
    add r0, r7, #13                         @         memcpy(dir + 13, buf + 13, SZDIRE - 13);
    add r1, sp, #(RN_BUF + 13)
    movs r2, #(SZDIRE - 13)
    bl ff16_memcpy
    ldrb r0, [sp, #(RN_BUF + DIR_Attr)]     @         dir[DIR_Attr] = buf[DIR_Attr];
    tst r0, #AM_DIR                         @         if (!(dir[DIR_Attr] & AM_DIR)) dir[DIR_Attr] |= AM_ARC;
    it eq
    orreq r0, r0, #AM_ARC
    strb r0, [r7, #DIR_Attr]
    movs r1, #1
    strb r1, [r6, #FS_WFLAG]                @         fs->wflag = 1;
    tst r0, #AM_DIR                         @         if ((dir[DIR_Attr] & AM_DIR) && djo.obj.sclust != djn.obj.sclust) {
    beq 6f
    ldr r0, [r4, #OBJ_SCLUST]
    ldr r1, [r5, #OBJ_SCLUST]
    cmp r0, r1
    beq 6f
    mov r0, r6
    mov r1, r7
    bl ff16_ld_clust
    mov r1, r0
    mov r0, r6
    bl ff16_clst2sect                       @           LBA_t sect = clst2sect(fs, ld_clust(fs, dir));
    cbnz r0, 3f                             @           if (sect == 0) res = FR_INT_ERR;
    movs r8, #FR_INT_ERR
    b 6f
3:  mov r1, r0                              @           else { res = move_window(fs, sect);
    mov r0, r6
    bl ff16_move_window
    mov r8, r0
    add r7, r6, #(FS_WIN + SZDIRE)          @             dir = fs->win + SZDIRE * 1;
    cmp r8, #0                             @             if (res == FR_OK && dir[1] == '.') {
    bne 6f
    ldrb r0, [r7, #1]
    cmp r0, #'.'
    bne 6f
    mov r0, r6
    mov r1, r7
    ldr r2, [r5, #OBJ_SCLUST]
    bl ff16_st_clust                        @               st_clust(fs, dir, djn.obj.sclust);
    movs r0, #1
    strb r0, [r6, #FS_WFLAG]                @               fs->wflag = 1;
6:  cmp r8, #FR_OK                          @   if (res == FR_OK) {
    bne .Lrn_ret
    mov r0, r4
    bl ff16_dir_remove                      @     res = dir_remove(&djo);
    mov r8, r0
    cmp r8, #0                       @     if (res == FR_OK) res = sync_fs(fs);
    bne .Lrn_ret
    mov r0, r6
    bl ff16_sync_fs
    mov r8, r0
.Lrn_ret:
    mov r0, r8
    add sp, sp, #RN_FRAME
    pop {r4, r5, r6, r7, r8, pc}
ENDFUNC ff16_f_rename

@ -----------------------------------------------------------------------------
@ f_utime - change the time stamp of a file or directory (ff.c f_utime)
@ In       : r0 = path, r1 = fno (fdate, ftime)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Stack    : [sp] fs, [sp + 4] path, [sp + 8 ..] DIR dj
@ -----------------------------------------------------------------------------
    .equ UT_FS, 0
    .equ UT_PATH, 4
    .equ UT_DJ, 8
    .equ UT_FRAME, (8 + DIR_SIZE + 4)       @ 56: 8-byte aligned with the 4 registers pushed
FUNC ff16_f_utime
    push {r4, r5, r6, lr}
    sub sp, sp, #UT_FRAME
    str r0, [sp, #UT_PATH]
    mov r5, r1
    add r4, sp, #UT_DJ
    add r0, sp, #UT_PATH
    add r1, sp, #UT_FS
    movs r2, #FA_WRITE
    bl ff16_mount_volume                    @ res = mount_volume(&path, &fs, FA_WRITE);
    mov r6, r0
    cbnz r6, 9f                             @ if (res == FR_OK) {
    ldr r0, [sp, #UT_FS]
    str r0, [r4, #OBJ_FS]                   @   dj.obj.fs = fs;
    mov r0, r4
    ldr r1, [sp, #UT_PATH]
    bl ff16_follow_path                     @   res = follow_path(&dj, path);
    mov r6, r0
    cbnz r6, 9f                             @   if (res == FR_OK && (dj.fn[NSFLAG] & (NS_DOT | NS_NONAME))) res = FR_INVALID_NAME;
    ldrb r0, [r4, #(DIR_FN + NSFLAG)]
    tst r0, #(NS_DOT | NS_NONAME)
    beq 1f
    movs r6, #FR_INVALID_NAME
    b 9f
1:  ldrh r1, [r5, #FNO_FDATE]               @   if (res == FR_OK) { if (fno->fdate) st_32(dj.dir + DIR_ModTime, (DWORD)fno->fdate << 16 | fno->ftime);
    cbz r1, 2f
    ldrh r0, [r5, #FNO_FTIME]
    orr r1, r0, r1, lsl #16
    ldr r0, [r4, #DIR_DIR]
    adds r0, r0, #DIR_ModTime
    bl ff16_st_32
2:  ldr r0, [sp, #UT_FS]
    movs r1, #1
    strb r1, [r0, #FS_WFLAG]                @     fs->wflag = 1;
    bl ff16_sync_fs                         @     res = sync_fs(fs);
    mov r6, r0
9:  mov r0, r6
    add sp, sp, #UT_FRAME
    pop {r4, r5, r6, pc}
ENDFUNC ff16_f_utime

