@ =============================================================================
@ ff16_file.s - FatFs R0.16 (production image): f_mount, f_open, f_read, f_write, f_sync, f_close (DESIGN.md 7A, IMP-29)
@
@ Hand translation of ChaN's FatFs R0.16 w/patch 2 (ff.c, FF_FS_READONLY 0, FF_FS_TINY 0, FF_FS_EXFAT 0, FF_USE_FASTSEEK 0,
@ FF_FS_LOCK 0).  The DIR "dj" of f_open lives on the stack (DIR_SIZE bytes) as in the C code.  License and conventions:
@ ff16_low.s.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "config.inc"

    .include "ff16.inc"

    .section .text.ff16.file, "ax", %progbits

@ -----------------------------------------------------------------------------
@ f_mount - register / unregister the work area of drive 0 (ff.c f_mount)
@ In       : r0 = fs (0: unregister), r1 = path, r2 = opt (0: delayed mount, 1: mount now)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_f_mount
    push {r0, r1, r4, r5, r6, lr}           @ [sp] = fs, [sp + 4] = path (also rp)
    mov r6, r2                              @ r6 = opt
    add r0, sp, #4
    ldr r4, [sp, #4]                        @ (path kept for mount_volume)
    push {r4}                               @ [sp] = rp = path; fs at [sp + 4], path at [sp + 8]
    mov r0, sp
    bl ff16_get_ldnumber                    @ vol = get_ldnumber(&rp);
    add sp, sp, #4
    cmp r0, #0                              @ if (vol < 0) return FR_INVALID_DRIVE;
    bge 1f
    movs r0, #FR_INVALID_DRIVE
    b .Lmt_ret
1:  mov r5, r0                              @ r5 = vol
    ldr r1, =ff16_fatfs_ptr
    ldr r2, [r1, r5, lsl #2]                @ cfs = FatFs[vol];
    cbz r2, 2f                              @ if (cfs) {
    movs r3, #0
    str r3, [r1, r5, lsl #2]                @   FatFs[vol] = 0;
    strb r3, [r2, #FS_FS_TYPE]              @   cfs->fs_type = 0;
2:  ldr r0, [sp]                            @ if (fs) {
    cbz r0, 3f
    strb r5, [r0, #FS_PDRV]                 @   fs->pdrv = LD2PD(vol);
    movs r3, #0
    strb r3, [r0, #FS_FS_TYPE]              @   fs->fs_type = 0;
    str r0, [r1, r5, lsl #2]                @   FatFs[vol] = fs;
3:  cbnz r6, 4f                             @ if (opt == 0) return FR_OK;
    movs r0, #FR_OK
    b .Lmt_ret
4:  add r0, sp, #4                          @ res = mount_volume(&path, &fs, 0);
    mov r1, sp
    movs r2, #0
    bl ff16_mount_volume
.Lmt_ret:
    add sp, sp, #8
    pop {r4, r5, r6, pc}
    .ltorg
ENDFUNC ff16_f_mount

@ -----------------------------------------------------------------------------
@ f_open - open or create a file (ff.c f_open)
@ In       : r0 = fp, r1 = path, r2 = mode
@ Out      : r0 = FRESULT (fp->obj.fs = 0 on failure)
@ Clobbers : r1-r3, r12, flags
@ Stack    : [sp] fs, [sp + 4] path, [sp + 8 ..] DIR dj (DIR_SIZE)
@ Registers: r4 fp, r5 mode, r6 res, r7 fs, r8 dj, r9..r11 scratch of the append branch
@ -----------------------------------------------------------------------------
    .equ FO_FS, 0
    .equ FO_PATH, 4
    .equ FO_DJ, 8
    .equ FO_FRAME, (8 + DIR_SIZE + 4)       @ 56: keeps sp 8-byte aligned with the 9 registers pushed
FUNC ff16_f_open
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #FO_FRAME
    mov r4, r0
    str r1, [sp, #FO_PATH]
    add r8, sp, #FO_DJ                      @ r8 = &dj
    cbnz r4, 1f                             @ if (!fp) return FR_INVALID_OBJECT;
    movs r0, #FR_INVALID_OBJECT
    b .Lop_ret
1:  and r5, r2, #(FA_READ | FA_WRITE | FA_CREATE_ALWAYS | FA_CREATE_NEW | FA_OPEN_ALWAYS | FA_OPEN_APPEND)
                                            @ mode &= FA_READ | FA_WRITE | FA_CREATE_ALWAYS | FA_CREATE_NEW | FA_OPEN_ALWAYS | FA_OPEN_APPEND;
    add r0, sp, #FO_PATH
    add r1, sp, #FO_FS
    mov r2, r5
    bl ff16_mount_volume                    @ res = mount_volume(&path, &fs, mode);
    mov r6, r0
    cmp r6, #FR_OK                          @ if (res == FR_OK) {
    bne .Lop_fail
    ldr r7, [sp, #FO_FS]
    str r7, [r4, #OBJ_FS]                   @   fp->obj.fs = fs;
    str r7, [r8, #OBJ_FS]                   @   dj.obj.fs = fs;
    mov r0, r8
    ldr r1, [sp, #FO_PATH]
    bl ff16_follow_path                     @   res = follow_path(&dj, path);
    mov r6, r0
    cbnz r6, 2f                             @   if (res == FR_OK) { if (dj.fn[NSFLAG] & NS_NONAME) res = FR_INVALID_NAME; }
    ldrb r0, [r8, #(DIR_FN + NSFLAG)]
    tst r0, #NS_NONAME
    it ne
    movne r6, #FR_INVALID_NAME
2:  tst r5, #(FA_CREATE_ALWAYS | FA_OPEN_ALWAYS | FA_CREATE_NEW)    @ if (mode & (FA_CREATE_ALWAYS | FA_OPEN_ALWAYS | FA_CREATE_NEW)) {
    beq .Lop_noncreate
    cbz r6, 3f                              @   if (res != FR_OK) {
    cmp r6, #FR_NO_FILE                     @     if (res == FR_NO_FILE) res = dir_register(&dj);
    bne 21f
    mov r0, r8
    bl ff16_dir_register
    mov r6, r0
21: orr r5, r5, #FA_CREATE_ALWAYS           @     mode |= FA_CREATE_ALWAYS;
    b 4f
3:  tst r5, #FA_CREATE_NEW                  @   } else { if (mode & FA_CREATE_NEW) res = FR_EXIST;
    beq 31f
    movs r6, #FR_EXIST
    b 4f
31: ldrb r0, [r8, #OBJ_ATTR]                @     else if (dj.obj.attr & (AM_RDO | AM_DIR)) res = FR_DENIED;
    tst r0, #(AM_RDO | AM_DIR)
    it ne
    movne r6, #FR_DENIED
4:  cmp r6, #FR_OK                          @   if (res == FR_OK && (mode & FA_CREATE_ALWAYS)) {
    bne .Lop_common
    tst r5, #FA_CREATE_ALWAYS
    beq .Lop_common
    bl get_fattime                          @     DWORD tm = GET_FATTIME();
    mov r9, r0
    ldr r10, [r8, #DIR_DIR]                 @     (r10 = dj.dir)
    add r0, r10, #DIR_CrtTime
    mov r1, r9
    bl ff16_st_32                           @     st_32(dj.dir + DIR_CrtTime, tm);
    add r0, r10, #DIR_ModTime
    mov r1, r9
    bl ff16_st_32                           @     st_32(dj.dir + DIR_ModTime, tm);
    mov r0, r7
    mov r1, r10
    bl ff16_ld_clust
    mov r9, r0                              @     cl = ld_clust(fs, dj.dir);
    movs r0, #AM_ARC
    strb r0, [r10, #DIR_Attr]               @     dj.dir[DIR_Attr] = AM_ARC;
    mov r0, r7
    mov r1, r10
    movs r2, #0
    bl ff16_st_clust                        @     st_clust(fs, dj.dir, 0);
    add r0, r10, #DIR_FileSize
    movs r1, #0
    bl ff16_st_32                           @     st_32(dj.dir + DIR_FileSize, 0);
    movs r0, #1
    strb r0, [r7, #FS_WFLAG]                @     fs->wflag = 1;
    cmp r9, #0                              @     if (cl != 0) {
    beq .Lop_common
    ldr r11, [r7, #FS_WINSECT]              @       LBA_t sc = fs->winsect;
    mov r0, r8
    mov r1, r9
    movs r2, #0
    bl ff16_remove_chain                    @       res = remove_chain(&dj.obj, cl, 0);
    mov r6, r0
    cbnz r6, .Lop_common                    @       if (res == FR_OK) {
    mov r0, r7
    mov r1, r11
    bl ff16_move_window                     @         res = move_window(fs, sc);
    mov r6, r0
    subs r0, r9, #1
    str r0, [r7, #FS_LAST_CLST]             @         fs->last_clst = cl - 1;
    b .Lop_common
.Lop_noncreate:                             @ } else {
    cbnz r6, .Lop_common                    @   if (res == FR_OK) {
    ldrb r0, [r8, #OBJ_ATTR]
    tst r0, #AM_DIR                         @     if (dj.obj.attr & AM_DIR) res = FR_NO_FILE;
    beq 5f
    movs r6, #FR_NO_FILE
    b .Lop_common
5:  tst r5, #FA_WRITE                       @     else if ((mode & FA_WRITE) && (dj.obj.attr & AM_RDO)) res = FR_DENIED;
    beq .Lop_common
    tst r0, #AM_RDO
    it ne
    movne r6, #FR_DENIED
.Lop_common:
    cmp r6, #FR_OK                          @ if (res == FR_OK) {
    bne .Lop_fail
    tst r5, #FA_CREATE_ALWAYS               @   if (mode & FA_CREATE_ALWAYS) mode |= FA_MODIFIED;
    it ne
    orrne r5, r5, #FA_MODIFIED
    ldr r0, [r7, #FS_WINSECT]
    str r0, [r4, #FIL_DIR_SECT]             @   fp->dir_sect = fs->winsect;
    ldr r10, [r8, #DIR_DIR]
    str r10, [r4, #FIL_DIR_PTR]             @   fp->dir_ptr = dj.dir;
    mov r0, r7                              @ if (res == FR_OK) {
    mov r1, r10
    bl ff16_ld_clust
    str r0, [r4, #OBJ_SCLUST]               @   fp->obj.sclust = ld_clust(fs, dj.dir);
    add r0, r10, #DIR_FileSize
    bl ff16_ld_32
    str r0, [r4, #OBJ_OBJSIZE]              @   fp->obj.objsize = ld_32(dj.dir + DIR_FileSize);
    ldrh r0, [r7, #FS_ID]
    strh r0, [r4, #OBJ_ID]                  @   fp->obj.id = fs->id;
    strb r5, [r4, #FIL_FLAG]                @   fp->flag = mode;
    movs r0, #0
    strb r0, [r4, #FIL_ERR]                 @   fp->err = 0;
    str r0, [r4, #FIL_SECT]                 @   fp->sect = 0;
    str r0, [r4, #FIL_FPTR]                 @   fp->fptr = 0;
    add r0, r4, #FIL_BUF
    movs r1, #0
    mov r2, #512
    bl ff16_memset                          @   memset(fp->buf, 0, sizeof fp->buf);
    tst r5, #FA_SEEKEND                     @   if ((mode & FA_SEEKEND) && fp->obj.objsize > 0) {
    beq .Lop_ret_res
    ldr r9, [r4, #OBJ_OBJSIZE]
    cmp r9, #0
    beq .Lop_ret_res
    str r9, [r4, #FIL_FPTR]                 @     fp->fptr = fp->obj.objsize;
    ldrh r10, [r7, #FS_CSIZE]
    lsl r10, r10, #9                        @     bcs = (DWORD)fs->csize * SS(fs);
    ldr r11, [r4, #OBJ_SCLUST]              @     clst = fp->obj.sclust;
6:  cmp r6, #FR_OK                          @     for (ofs = fp->obj.objsize; res == FR_OK && ofs > bcs; ofs -= bcs) {
    bne 7f
    cmp r9, r10
    bls 7f
    mov r0, r4
    mov r1, r11
    bl ff16_get_fat                         @       clst = get_fat(&fp->obj, clst);
    mov r11, r0
    cmp r11, #1                             @       if (clst <= 1) res = FR_INT_ERR;
    it ls
    movls r6, #FR_INT_ERR
    cmn r11, #1                             @       if (clst == 0xFFFFFFFF) res = FR_DISK_ERR;
    it eq
    moveq r6, #FR_DISK_ERR
    sub r9, r9, r10
    b 6b
7:  str r11, [r4, #FIL_CLUST]               @     fp->clust = clst;
    cmp r6, #FR_OK                          @     if (res == FR_OK && ofs % SS(fs)) {
    bne .Lop_fail
    ubfx r0, r9, #0, #9
    cmp r0, #0
    beq .Lop_ret_res
    mov r0, r7
    mov r1, r11
    bl ff16_clst2sect                       @       LBA_t sec = clst2sect(fs, clst);
    cbnz r0, 8f                             @       if (sec == 0) res = FR_INT_ERR;
    movs r6, #FR_INT_ERR
    b .Lop_fail
8:  add r2, r0, r9, lsr #9
    str r2, [r4, #FIL_SECT]                 @       fp->sect = sec + (DWORD)(ofs / SS(fs));
    ldrb r0, [r7, #FS_PDRV]                 @       if (disk_read(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) res = FR_DISK_ERR;
    add r1, r4, #FIL_BUF
    movs r3, #1
    bl disk_read
    cbz r0, .Lop_ret_res
    movs r6, #FR_DISK_ERR
.Lop_fail:
    movs r0, #0                             @ if (res != FR_OK) fp->obj.fs = 0;
    str r0, [r4, #OBJ_FS]
.Lop_ret_res:
    mov r0, r6                              @ return res;
.Lop_ret:
    add sp, sp, #FO_FRAME
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC ff16_f_open

@ -----------------------------------------------------------------------------
@ f_read - read data from a file (ff.c f_read)
@ In       : r0 = fp, r1 = buff, r2 = btr, r3 = br (UINT* out)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fp, r5 rbuff, r6 btr, r7 br, r8 fs, r9 csect, r10 sect, r11 rcnt
@ -----------------------------------------------------------------------------
FUNC ff16_f_read
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #4                          @ [sp] = fs (validate output)
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
    movs r0, #0
    str r0, [r7]                            @ *br = 0;
    mov r0, r4
    mov r1, sp
    bl ff16_validate                        @ res = validate(&fp->obj, &fs);
    cmp r0, #0                       @ if (res != FR_OK || (res = (FRESULT)fp->err) != FR_OK) return res;
    bne .Lrd_ret
    ldrb r0, [r4, #FIL_ERR]
    cmp r0, #0
    bne .Lrd_ret
    ldr r8, [sp]
    ldrb r0, [r4, #FIL_FLAG]                @ if (!(fp->flag & FA_READ)) return FR_DENIED;
    tst r0, #FA_READ
    bne 1f
    movs r0, #FR_DENIED
    b .Lrd_ret
1:  ldr r0, [r4, #OBJ_OBJSIZE]              @ remain = fp->obj.objsize - fp->fptr;
    ldr r1, [r4, #FIL_FPTR]
    subs r0, r0, r1
    cmp r6, r0                              @ if (btr > remain) btr = (UINT)remain;
    it hi
    movhi r6, r0
.Lrd_loop:                                  @ for ( ; btr > 0; ...) {
    cmp r6, #0
    beq .Lrd_ok
    ldr r0, [r4, #FIL_FPTR]
    ubfx r1, r0, #0, #9                     @   if (fp->fptr % SS(fs) == 0) {
    cmp r1, #0
    bne .Lrd_copy
    ldrh r1, [r8, #FS_CSIZE]                @     csect = (UINT)(fp->fptr / SS(fs) & (fs->csize - 1));
    subs r1, r1, #1
    and r9, r1, r0, lsr #9
    cmp r9, #0                              @     if (csect == 0) {
    bne 3f
    cbnz r0, 2f                             @       if (fp->fptr == 0) clst = fp->obj.sclust;
    ldr r0, [r4, #OBJ_SCLUST]
    b 21f
2:  mov r0, r4                              @       else clst = get_fat(&fp->obj, fp->clust);
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_get_fat
21: cmp r0, #2                              @       if (clst < 2) ABORT(fs, FR_INT_ERR);
    blo .Lrd_int
    cmn r0, #1                              @       if (clst == 0xFFFFFFFF) ABORT(fs, FR_DISK_ERR);
    beq .Lrd_disk
    str r0, [r4, #FIL_CLUST]                @       fp->clust = clst;
3:  mov r0, r8
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_clst2sect                       @     sect = clst2sect(fs, fp->clust);
    cmp r0, #0                              @     if (sect == 0) ABORT(fs, FR_INT_ERR);
    beq .Lrd_int
    add r10, r0, r9                         @     sect += csect;
    lsrs r2, r6, #9                         @     cc = btr / SS(fs);
    cbz r2, 5f                              @     if (cc > 0) {
    ldrh r1, [r8, #FS_CSIZE]                @       if (csect + cc > fs->csize) cc = fs->csize - csect;
    add r0, r9, r2
    cmp r0, r1
    it hi
    subhi r2, r1, r9
    mov r11, r2                             @       (r11 = cc)
    ldrb r0, [r8, #FS_PDRV]                 @       if (disk_read(fs->pdrv, rbuff, sect, cc) != RES_OK) ABORT(fs, FR_DISK_ERR);
    mov r1, r5
    mov r3, r2
    mov r2, r10
    bl disk_read
    cmp r0, #0
    bne .Lrd_disk
    ldrb r0, [r4, #FIL_FLAG]                @       if ((fp->flag & FA_DIRTY) && fp->sect - sect < cc)
    tst r0, #FA_DIRTY
    beq 4f
    ldr r0, [r4, #FIL_SECT]
    subs r0, r0, r10
    cmp r0, r11
    bhs 4f
    add r0, r5, r0, lsl #9                  @         memcpy(rbuff + ((fp->sect - sect) * SS(fs)), fp->buf, SS(fs));
    add r1, r4, #FIL_BUF
    mov r2, #512
    bl ff16_memcpy
4:  lsl r11, r11, #9                        @       rcnt = SS(fs) * cc;
    b .Lrd_next                             @       continue;
5:  ldr r0, [r4, #FIL_SECT]                 @     if (fp->sect != sect) {
    cmp r0, r10
    beq 7f
    ldrb r1, [r4, #FIL_FLAG]                @       if (fp->flag & FA_DIRTY) {
    tst r1, #FA_DIRTY
    beq 6f
    mov r2, r0                              @         if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    ldrb r0, [r8, #FS_PDRV]
    add r1, r4, #FIL_BUF
    movs r3, #1
    bl disk_write
    cmp r0, #0
    bne .Lrd_disk
    ldrb r1, [r4, #FIL_FLAG]
    bic r1, r1, #FA_DIRTY
    strb r1, [r4, #FIL_FLAG]                @         fp->flag &= (BYTE)~FA_DIRTY;
6:  ldrb r0, [r8, #FS_PDRV]                 @       if (disk_read(fs->pdrv, fp->buf, sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    mov r2, r10
    movs r3, #1
    bl disk_read
    cmp r0, #0
    bne .Lrd_disk
7:  str r10, [r4, #FIL_SECT]                @     fp->sect = sect;
.Lrd_copy:
    ldr r0, [r4, #FIL_FPTR]                 @   rcnt = SS(fs) - (UINT)fp->fptr % SS(fs);
    ubfx r1, r0, #0, #9
    rsb r11, r1, #512
    cmp r11, r6                             @   if (rcnt > btr) rcnt = btr;
    it hi
    movhi r11, r6
    mov r0, r5                              @   memcpy(rbuff, fp->buf + fp->fptr % SS(fs), rcnt);
    add r1, r1, r4
    adds r1, r1, #FIL_BUF
    mov r2, r11
    bl ff16_memcpy
.Lrd_next:                                  @   btr -= rcnt, *br += rcnt, rbuff += rcnt, fp->fptr += rcnt
    sub r6, r6, r11
    ldr r0, [r7]
    add r0, r0, r11
    str r0, [r7]
    add r5, r5, r11
    ldr r0, [r4, #FIL_FPTR]
    add r0, r0, r11
    str r0, [r4, #FIL_FPTR]
    b .Lrd_loop
.Lrd_ok:
    movs r0, #FR_OK
    b .Lrd_ret
.Lrd_int:
    movs r0, #FR_INT_ERR                    @ ABORT: fp->err = (BYTE)(res); return res;
    strb r0, [r4, #FIL_ERR]
    b .Lrd_ret
.Lrd_disk:
    movs r0, #FR_DISK_ERR
    strb r0, [r4, #FIL_ERR]
.Lrd_ret:
    add sp, sp, #4
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC ff16_f_read

@ -----------------------------------------------------------------------------
@ f_write - write data to a file (ff.c f_write)
@ In       : r0 = fp, r1 = buff, r2 = btw, r3 = bw (UINT* out)
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fp, r5 wbuff, r6 btw, r7 bw, r8 fs, r9 csect, r10 sect, r11 wcnt
@ -----------------------------------------------------------------------------
FUNC ff16_f_write
    push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub sp, sp, #4                          @ [sp] = fs
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
    movs r0, #0
    str r0, [r7]                            @ *bw = 0;
    mov r0, r4
    mov r1, sp
    bl ff16_validate                        @ res = validate(&fp->obj, &fs);
    cmp r0, #0                              @ if (res != FR_OK || (res = (FRESULT)fp->err) != FR_OK) return res;
    bne .Lwr_ret
    ldrb r0, [r4, #FIL_ERR]
    cmp r0, #0
    bne .Lwr_ret
    ldr r8, [sp]
    ldrb r0, [r4, #FIL_FLAG]                @ if (!(fp->flag & FA_WRITE)) return FR_DENIED;
    tst r0, #FA_WRITE
    bne 1f
    movs r0, #FR_DENIED
    b .Lwr_ret
1:  ldr r0, [r4, #FIL_FPTR]                 @ if ((DWORD)(fp->fptr + btw) < (DWORD)fp->fptr) btw = (UINT)(0xFFFFFFFF - (DWORD)fp->fptr);
    adds r1, r0, r6
    bcc .Lwr_loop                           @   (carry clear: no wrap)
    mvn r6, r0
.Lwr_loop:                                  @ for ( ; btw > 0; ...) {
    cmp r6, #0
    beq .Lwr_done
    ldr r0, [r4, #FIL_FPTR]
    ubfx r1, r0, #0, #9                     @   if (fp->fptr % SS(fs) == 0) {
    cmp r1, #0
    bne .Lwr_copy
    ldrh r1, [r8, #FS_CSIZE]                @     csect = (UINT)(fp->fptr / SS(fs)) & (fs->csize - 1);
    subs r1, r1, #1
    and r9, r1, r0, lsr #9
    cmp r9, #0                              @     if (csect == 0) {
    bne 4f
    cbnz r0, 2f                             @       if (fp->fptr == 0) {
    ldr r0, [r4, #OBJ_SCLUST]               @         clst = fp->obj.sclust;
    cbnz r0, 3f                             @         if (clst == 0) clst = create_chain(&fp->obj, 0);
    mov r0, r4
    movs r1, #0
    bl ff16_create_chain
    b 3f
2:  mov r0, r4                              @       } else { clst = create_chain(&fp->obj, fp->clust); }
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_create_chain
3:  cmp r0, #0                              @       if (clst == 0) break;
    beq .Lwr_done
    cmp r0, #1                              @       if (clst == 1) ABORT(fs, FR_INT_ERR);
    beq .Lwr_int
    cmn r0, #1                              @       if (clst == 0xFFFFFFFF) ABORT(fs, FR_DISK_ERR);
    beq .Lwr_disk
    str r0, [r4, #FIL_CLUST]                @       fp->clust = clst;
    ldr r1, [r4, #OBJ_SCLUST]               @       if (fp->obj.sclust == 0) fp->obj.sclust = clst;
    cmp r1, #0
    it eq
    streq r0, [r4, #OBJ_SCLUST]
4:  ldrb r0, [r4, #FIL_FLAG]                @     if (fp->flag & FA_DIRTY) {
    tst r0, #FA_DIRTY
    beq 5f
    ldrb r0, [r8, #FS_PDRV]                 @       if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    ldr r2, [r4, #FIL_SECT]
    movs r3, #1
    bl disk_write
    cmp r0, #0
    bne .Lwr_disk
    ldrb r0, [r4, #FIL_FLAG]
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]                @       fp->flag &= (BYTE)~FA_DIRTY;
5:  mov r0, r8
    ldr r1, [r4, #FIL_CLUST]
    bl ff16_clst2sect                       @     sect = clst2sect(fs, fp->clust);
    cmp r0, #0                              @     if (sect == 0) ABORT(fs, FR_INT_ERR);
    beq .Lwr_int
    add r10, r0, r9                         @     sect += csect;
    lsrs r2, r6, #9                         @     cc = btw / SS(fs);
    cbz r2, 7f                              @     if (cc > 0) {
    ldrh r1, [r8, #FS_CSIZE]                @       if (csect + cc > fs->csize) cc = fs->csize - csect;
    add r0, r9, r2
    cmp r0, r1
    it hi
    subhi r2, r1, r9
    mov r11, r2                             @       (r11 = cc)
    ldrb r0, [r8, #FS_PDRV]                 @       if (disk_write(fs->pdrv, wbuff, sect, cc) != RES_OK) ABORT(fs, FR_DISK_ERR);
    mov r1, r5
    mov r3, r2
    mov r2, r10
    bl disk_write
    cmp r0, #0
    bne .Lwr_disk
    ldr r0, [r4, #FIL_SECT]                 @       if (fp->sect - sect < cc) {
    subs r0, r0, r10
    cmp r0, r11
    bhs 6f
    add r1, r5, r0, lsl #9                  @         memcpy(fp->buf, wbuff + ((fp->sect - sect) * SS(fs)), SS(fs));
    add r0, r4, #FIL_BUF
    mov r2, #512
    bl ff16_memcpy
    ldrb r0, [r4, #FIL_FLAG]
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]                @         fp->flag &= (BYTE)~FA_DIRTY;
6:  lsl r11, r11, #9                        @       wcnt = SS(fs) * cc;
    b .Lwr_next                             @       continue;
7:  ldr r0, [r4, #FIL_SECT]                 @     if (fp->sect != sect && fp->fptr < fp->obj.objsize && disk_read(fs->pdrv, fp->buf, sect, 1) != RES_OK) ABORT(fs, FR_DISK_ERR);
    cmp r0, r10
    beq 8f
    ldr r0, [r4, #FIL_FPTR]
    ldr r1, [r4, #OBJ_OBJSIZE]
    cmp r0, r1
    bhs 8f
    ldrb r0, [r8, #FS_PDRV]
    add r1, r4, #FIL_BUF
    mov r2, r10
    movs r3, #1
    bl disk_read
    cmp r0, #0
    bne .Lwr_disk
8:  str r10, [r4, #FIL_SECT]                @     fp->sect = sect;
.Lwr_copy:
    ldr r0, [r4, #FIL_FPTR]                 @   wcnt = SS(fs) - (UINT)fp->fptr % SS(fs);
    ubfx r1, r0, #0, #9
    rsb r11, r1, #512
    cmp r11, r6                             @   if (wcnt > btw) wcnt = btw;
    it hi
    movhi r11, r6
    add r0, r1, r4                          @   memcpy(fp->buf + fp->fptr % SS(fs), wbuff, wcnt);
    adds r0, r0, #FIL_BUF
    mov r1, r5
    mov r2, r11
    bl ff16_memcpy
    ldrb r0, [r4, #FIL_FLAG]
    orr r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]                @   fp->flag |= FA_DIRTY;
.Lwr_next:                                  @   btw -= wcnt, *bw += wcnt, wbuff += wcnt, fp->fptr += wcnt,
    sub r6, r6, r11                         @   fp->obj.objsize = (fp->fptr > fp->obj.objsize) ? fp->fptr : fp->obj.objsize
    ldr r0, [r7]
    add r0, r0, r11
    str r0, [r7]
    add r5, r5, r11
    ldr r0, [r4, #FIL_FPTR]
    add r0, r0, r11
    str r0, [r4, #FIL_FPTR]
    ldr r1, [r4, #OBJ_OBJSIZE]
    cmp r0, r1
    it hi
    strhi r0, [r4, #OBJ_OBJSIZE]
    b .Lwr_loop
.Lwr_done:
    ldrb r0, [r4, #FIL_FLAG]
    orr r0, r0, #FA_MODIFIED
    strb r0, [r4, #FIL_FLAG]                @ fp->flag |= FA_MODIFIED;
    movs r0, #FR_OK
    b .Lwr_ret
.Lwr_int:
    movs r0, #FR_INT_ERR
    strb r0, [r4, #FIL_ERR]
    b .Lwr_ret
.Lwr_disk:
    movs r0, #FR_DISK_ERR
    strb r0, [r4, #FIL_ERR]
.Lwr_ret:
    add sp, sp, #4
    pop {r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC ff16_f_write

@ -----------------------------------------------------------------------------
@ f_sync - flush the cached data of a writing file (ff.c f_sync)
@ In       : r0 = fp
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ Registers: r4 fp, r5 fs, r6 dir, r7 res
@ -----------------------------------------------------------------------------
FUNC ff16_f_sync
    push {r4, r5, r6, r7, lr}
    sub sp, sp, #4
    mov r4, r0
    mov r1, sp
    bl ff16_validate                        @ res = validate(&fp->obj, &fs);
    mov r7, r0
    cmp r7, #0                             @ if (res == FR_OK) {
    bne 9f
    ldr r5, [sp]
    ldrb r0, [r4, #FIL_FLAG]                @   if (fp->flag & FA_MODIFIED) {
    tst r0, #FA_MODIFIED
    beq 9f
    tst r0, #FA_DIRTY                       @     if (fp->flag & FA_DIRTY) {
    beq 1f
    ldrb r0, [r5, #FS_PDRV]                 @       if (disk_write(fs->pdrv, fp->buf, fp->sect, 1) != RES_OK) LEAVE_FF(fs, FR_DISK_ERR);
    add r1, r4, #FIL_BUF
    ldr r2, [r4, #FIL_SECT]
    movs r3, #1
    bl disk_write
    cbz r0, 0f
    movs r7, #FR_DISK_ERR
    b 9f
0:  ldrb r0, [r4, #FIL_FLAG]
    bic r0, r0, #FA_DIRTY
    strb r0, [r4, #FIL_FLAG]                @       fp->flag &= (BYTE)~FA_DIRTY;
1:  mov r0, r5
    ldr r1, [r4, #FIL_DIR_SECT]
    bl ff16_move_window                     @     res = move_window(fs, fp->dir_sect);
    mov r7, r0
    cbnz r7, 9f                             @     if (res == FR_OK) {
    ldr r6, [r4, #FIL_DIR_PTR]              @       BYTE *dir = fp->dir_ptr;
    ldrb r0, [r6, #DIR_Attr]
    orr r0, r0, #AM_ARC
    strb r0, [r6, #DIR_Attr]                @       dir[DIR_Attr] |= AM_ARC;
    ldr r0, [r4, #OBJ_FS]
    mov r1, r6
    ldr r2, [r4, #OBJ_SCLUST]
    bl ff16_st_clust                        @       st_clust(fp->obj.fs, dir, fp->obj.sclust);
    add r0, r6, #DIR_FileSize
    ldr r1, [r4, #OBJ_OBJSIZE]
    bl ff16_st_32                           @       st_32(dir + DIR_FileSize, (DWORD)fp->obj.objsize);
    bl get_fattime
    mov r1, r0
    add r0, r6, #DIR_ModTime
    bl ff16_st_32                           @       st_32(dir + DIR_ModTime, GET_FATTIME());
    add r0, r6, #DIR_LstAccDate
    movs r1, #0
    bl ff16_st_16                           @       st_16(dir + DIR_LstAccDate, 0);
    movs r0, #1
    strb r0, [r5, #FS_WFLAG]                @       fs->wflag = 1;
    mov r0, r5
    bl ff16_sync_fs                         @       res = sync_fs(fs);
    mov r7, r0
    ldrb r0, [r4, #FIL_FLAG]
    bic r0, r0, #FA_MODIFIED
    strb r0, [r4, #FIL_FLAG]                @       fp->flag &= (BYTE)~FA_MODIFIED;
9:  mov r0, r7
    add sp, sp, #4
    pop {r4, r5, r6, r7, pc}
ENDFUNC ff16_f_sync

@ -----------------------------------------------------------------------------
@ f_close - close an open file (ff.c f_close, FF_FS_LOCK 0)
@ In       : r0 = fp
@ Out      : r0 = FRESULT
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC ff16_f_close
    push {r4, lr}
    sub sp, sp, #8
    mov r4, r0
    bl ff16_f_sync                          @ res = f_sync(fp);
    cbnz r0, 9f                             @ if (res == FR_OK) {
    mov r0, r4
    mov r1, sp
    bl ff16_validate                        @   res = validate(&fp->obj, &fs);
    cbnz r0, 9f                             @   if (res == FR_OK) fp->obj.fs = 0;
    str r0, [r4, #OBJ_FS]
9:  add sp, sp, #8
    pop {r4, pc}
ENDFUNC ff16_f_close

