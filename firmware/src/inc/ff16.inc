@ =============================================================================
@ ff16.inc - FatFs R0.16 structure offsets and constants for the production image (DESIGN.md 7A, IMP-29)
@
@ Offsets measured with arm-none-eabi-gcc (Cortex-M3) on ff.h R0.16 with the configuration of DESIGN.md 7A (offsetof /
@ sizeof of FATFS, FFOBJID, FIL, DIR, FILINFO).  FRESULT, FA_*, AM_* and the directory-entry offsets are ff.h / ff.c values.
@ =============================================================================

@ FRESULT
    .equ FR_OK, 0
    .equ FR_DISK_ERR, 1
    .equ FR_INT_ERR, 2
    .equ FR_NOT_READY, 3
    .equ FR_NO_FILE, 4
    .equ FR_NO_PATH, 5
    .equ FR_INVALID_NAME, 6
    .equ FR_DENIED, 7
    .equ FR_EXIST, 8
    .equ FR_INVALID_OBJECT, 9
    .equ FR_WRITE_PROTECTED, 10
    .equ FR_INVALID_DRIVE, 11
    .equ FR_NOT_ENABLED, 12
    .equ FR_NO_FILESYSTEM, 13

@ FAT types (fs_type)
    .equ FS_FAT12, 1
    .equ FS_FAT16, 2
    .equ FS_FAT32, 3

@ FATFS (560 bytes)
    .equ FS_FS_TYPE, 0
    .equ FS_PDRV, 1
    .equ FS_LDRV, 2
    .equ FS_N_FATS, 3
    .equ FS_WFLAG, 4
    .equ FS_FSI_FLAG, 5
    .equ FS_ID, 6
    .equ FS_N_ROOTDIR, 8
    .equ FS_CSIZE, 10
    .equ FS_LAST_CLST, 12
    .equ FS_FREE_CLST, 16
    .equ FS_N_FATENT, 20
    .equ FS_FSIZE, 24
    .equ FS_WINSECT, 28
    .equ FS_VOLBASE, 32
    .equ FS_FATBASE, 36
    .equ FS_DIRBASE, 40
    .equ FS_DATABASE, 44
    .equ FS_WIN, 48
    .equ FATFS_SIZE, 560

@ FFOBJID (16 bytes), at offset 0 of FIL and DIR
    .equ OBJ_FS, 0
    .equ OBJ_ID, 4
    .equ OBJ_ATTR, 6
    .equ OBJ_STAT, 7
    .equ OBJ_SCLUST, 8
    .equ OBJ_OBJSIZE, 12

@ FIL (552 bytes)
    .equ FIL_FLAG, 16
    .equ FIL_ERR, 17
    .equ FIL_FPTR, 20
    .equ FIL_CLUST, 24
    .equ FIL_SECT, 28
    .equ FIL_DIR_SECT, 32
    .equ FIL_DIR_PTR, 36
    .equ FIL_BUF, 40
    .equ FIL_SIZE, 552

@ DIR (44 bytes)
    .equ DIR_DPTR, 16
    .equ DIR_CLUST, 20
    .equ DIR_SECT, 24
    .equ DIR_DIR, 28
    .equ DIR_FN, 32
    .equ DIR_SIZE, 44

@ FILINFO (24 bytes)
    .equ FNO_FSIZE, 0
    .equ FNO_FDATE, 4
    .equ FNO_FTIME, 6
    .equ FNO_FATTRIB, 8
    .equ FNO_FNAME, 9
    .equ FILINFO_SIZE, 24

@ open mode and file status flags (ff.h / ff.c)
    .equ FA_READ, 0x01
    .equ FA_WRITE, 0x02
    .equ FA_OPEN_EXISTING, 0x00
    .equ FA_CREATE_NEW, 0x04
    .equ FA_CREATE_ALWAYS, 0x08
    .equ FA_OPEN_ALWAYS, 0x10
    .equ FA_OPEN_APPEND, 0x30
    .equ FA_SEEKEND, 0x20
    .equ FA_MODIFIED, 0x40
    .equ FA_DIRTY, 0x80

@ attributes
    .equ AM_RDO, 0x01
    .equ AM_HID, 0x02
    .equ AM_SYS, 0x04
    .equ AM_VOL, 0x08
    .equ AM_LFN, 0x0F
    .equ AM_DIR, 0x10
    .equ AM_ARC, 0x20
    .equ AM_MASK, 0x3F

@ directory entry (32 bytes)
    .equ DIR_Name, 0
    .equ DIR_Attr, 11
    .equ DIR_NTres, 12
    .equ DIR_CrtTime10, 13
    .equ DIR_CrtTime, 14
    .equ DIR_LstAccDate, 18
    .equ DIR_FstClusHI, 20
    .equ DIR_ModTime, 22
    .equ DIR_FstClusLO, 26
    .equ DIR_FileSize, 28
    .equ SZDIRE, 32
    .equ DDEM, 0xE5
    .equ RDDEM, 0x05

@ create_name status byte (fn[11], NSFLAG)
    .equ NSFLAG, 11
    .equ NS_LOSS, 0x01
    .equ NS_LFN, 0x02
    .equ NS_LAST, 0x04
    .equ NS_BODY, 0x08
    .equ NS_EXT, 0x10
    .equ NS_DOT, 0x20
    .equ NS_NOLFN, 0x40
    .equ NS_NONAME, 0x80

@ limits (ff.c)
    .equ MAX_DIR, 0x200000
    .equ MAX_FAT12, 0xFF5
    .equ MAX_FAT16, 0xFFF5
    .equ MAX_FAT32, 0x0FFFFFF5
    .equ MIN_FAT12, 32
    .equ MIN_VOLUME, 64

@ boot sector / BPB (ff.c)
    .equ BS_JmpBoot, 0
    .equ BPB_BytsPerSec, 11
    .equ BPB_SecPerClus, 13
    .equ BPB_RsvdSecCnt, 14
    .equ BPB_NumFATs, 16
    .equ BPB_RootEntCnt, 17
    .equ BPB_TotSec16, 19
    .equ BPB_FATSz16, 22
    .equ BPB_TotSec32, 32
    .equ BPB_FATSz32, 36
    .equ BPB_FSVer32, 42
    .equ BPB_RootClus32, 44
    .equ BPB_FSInfo32, 48
    .equ BS_FilSysType, 54
    .equ BS_FilSysType32, 82
    .equ BS_55AA, 510
    .equ FSI_LeadSig, 0
    .equ FSI_StrucSig, 484
    .equ FSI_Free_Count, 488
    .equ FSI_Nxt_Free, 492
    .equ MBR_Table, 446
    .equ SZ_PTE, 16
    .equ PTE_System, 4
    .equ PTE_StLba, 8
