@ =============================================================================
@ bftsd.s - BLE: SD card file requests over the Bluetooth transfer link (list, read, delete, free space)
@ (production image only, DESIGN.md 10 IMP-36, FEATURES.md 2.11 stage 6)
@
@ The companion app can look at the card without removing it: list the root directory, read a file in pieces, delete a
@ file and ask for the free space.  The requests ride on the packet framing of the firmware transfer (ble/bft.s: B5 5B
@ type seq(2) len(1) payload(len <= 232) crc16(2), little-endian, CRC-16/CCITT-FALSE over type..payload) and are handed
@ over by bft_packet (types 0x10 .. 0x17), so they are possible only under the gate of the transfer (bft_poll): the
@ SETUP page Ld shown, Bluetooth on, logging off, calibration mode off.  Outside that gate the link belongs to the v2.05
@ parser and a request is not seen at all (no answer).  Types 0x16 / 0x17 (settings) are in ble/bftset.s.
@
@ Requests (payload):
@     0x10 LIST    start(2) [max(1)]                 root directory, entries start .. , as many as fit in 232 bytes
@                                                    (IMP-50: at most max entries, 1..255, when the byte is given)
@     0x11 READ    namelen(1) name offset(4) len(2)  len 1 .. 8192: read into the staging buffer (log_buf, 8 KiB)
@     0x12 CHUNK   idx(2) [len(1)]                   bytes idx*232 .. of the staged data (RAM only, no card access);
@                                                    IMP-50: with len (1..232) the bytes idx*len .., len at most
@     0x13 DELETE  namelen(1) name                   f_unlink of one root file (or empty directory)
@     0x14 INFO    -                                 free and total clusters, cluster size
@     0x15 FORMAT  "FORMAT"(6)                       format the card as exFAT (f_mkfs, as the SETUP page Fr, set/fmt.s);
@                                                    only with the two-part bootloader (EEVblog's cannot read exFAT)
@ Answer: B5 5B 82 seq(2) len(1) status(1) field(2) data crc16(2); seq = the request's seq, len = 3 + length of data,
@     data <= 232 bytes, so an answer is at most 8 + 3 + 232 = 243 bytes (one Bluetooth write of 244 bytes; the transmit
@     queue ble_txq of usart.s holds 256).  field and the data per request:
@     LIST   field = count of entries | 0x8000 when the end of the directory was reached.  data = count entries of
@            size(4) fdate(2) ftime(2) attr(1) namelen(1) name(namelen).  size = low 32 bits of the file size (0xFFFFFFFF
@            above 4 GiB), fdate / ftime = the FAT date and time words, attr = the FAT attribute byte; a name of more
@            than 63 bytes (long file name, FF_MAX_LFN 255) is cut to 63 bytes and bit 7 of attr is set (the FAT
@            attributes use bits 0..5 only).  The name is the long file name, or the 8.3 name if there is none.  An
@            entry that does not fit in the answer is not counted: the next LIST (start += count) returns it first.
@     READ   field = number of bytes read (below len at the end of the file; 0 at or after the end), data = CRC-32
@            (IEEE 802.3, as zlib.crc32) of those bytes, 4 bytes.  The bytes stay in the staging buffer for CHUNK until
@            the next READ or the next START of a firmware transfer.
@     CHUNK  field = idx, data = the 232 bytes idx*232 .. of the staged data (fewer in the last chunk).
@     DELETE field = 0, no data.
@     FORMAT field = 0, no data; the answer comes when the card is formatted (seconds; the link is deaf meanwhile).
@     INFO   field = sectors per cluster (512 bytes each), data = free clusters(4) total clusters(4).  A card whose free
@            count is not known to the file system needs a scan of the allocation table: the answer can take seconds.
@     status 0 accepted; 3 not allowed now (a firmware transfer fills the staging buffer, a restart is due, or the type
@     is unknown); 0x20 not found (FatFs FR_NO_FILE or FR_NO_PATH); 0x21 name refused; 0x22 argument refused (payload
@     length, len or idx out of range, a FORMAT payload other than "FORMAT"); 0x23 protected (DELETE of cal.bin,
@     EEVBlog.bin or BTLOAD.TMP); 0x24 card error, field = step << 8 | FatFs result (step 1 open / opendir, 2 seek,
@     3 read / readdir, 4 delete, 5 getfree / close, 6 format); 0x25 FORMAT without the two-part bootloader.
@     (Statuses 1, 2, 4 and 5 of the transfer answers are not used here: a CRC error is answered with the 0x81 answer.)
@ Names: 1 .. 63 bytes out of A-Z a-z 0-9 . _ space -, no "..", no space at either end and no dot at the end (FatFs
@     removes trailing spaces and dots from a name, so "cal.bin." would reach cal.bin).  The path given to FatFs is "0:"
@     and the name: the root directory only.  Names are matched without regard to case, as FatFs does, also for the
@     protected names.  There is no write, rename or mkdir, and no EEPROM access of any kind in this module; FORMAT
@     erases the whole card (the companion asks for a typed confirmation first).
@
@ Card session.  Every card access is one session exactly as the firmware transfer does it (bft_card_begin / end of
@ bft.s): system clock HSE, SDIO up, drive registered, the operation, SDIO off, run clock.  The link is deaf meanwhile
@ (usart.s, NF-04); the sender waits for the answer (stop and wait).  A failing session is not repeated here: the answer
@ says 0x24 and the sender asks again.
@
@ RAM: the FatFs objects of the transfer (ff16_fatfs, ff16_fil_a, ff16_dir_a, ff16_finfo) and the staging buffer (log_buf,
@ as bft.s), which belong to logging and cal.bin, neither of which can run meanwhile (the gate).  Added here: bfx_ans
@ (248 bytes), bfx_path (68), bfx_staged (2) in .bss_port.
@
@ Context: main only (bft_packet).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "ff16x.inc"

    .equ BFX_T_LIST,        0x10
    .equ BFX_T_READ,        0x11
    .equ BFX_T_CHUNK,       0x12
    .equ BFX_T_DELETE,      0x13
    .equ BFX_T_INFO,        0x14
    .equ BFX_T_FORMAT,      0x15
    .equ BFX_T_GET,         0x16            @ settings (ble/bftset.s)
    .equ BFX_T_PUT,         0x17
    .equ BFX_MAXDATA,       232             @ data bytes of one answer (= BFT_MAXPAY of bft.s)
    .equ BFX_NAME_MAX,      63              @ longest name accepted, and longest name shown by LIST
    .equ BFX_READ_MAX,      8192            @ largest READ (the staging buffer, BFT_STAGE_LEN of bft.s)
    .equ BFX_ENTRY_HDR,     10              @ size(4) fdate(2) ftime(2) attr(1) namelen(1)
    .equ BFX_ST_NOTALLOWED, 3
    .equ BFX_ST_NOTFOUND,   0x20
    .equ BFX_ST_NAME,       0x21
    .equ BFX_ST_ARG,        0x22
    .equ BFX_ST_PROTECTED,  0x23
    .equ BFX_ST_CARD,       0x24
    .equ BFX_ST_NOFMT,      0x25            @ FORMAT refused: EEVblog's bootloader is installed (it cannot read exFAT)
    .equ BFX_STEP_FORMAT,   6
    .equ BFX_FMT_LEN,       6               @ the FORMAT payload "FORMAT"
    .equ BFX_STEP_OPEN,     1
    .equ BFX_STEP_READ,     3
    .equ BFX_STEP_DELETE,   4
    .equ BFX_STEP_FREE,     5
    .equ BFX_STEP_SEEK,     2
    .equ BFX_END,           0x8000          @ LIST field: the end of the directory was reached
    .equ BFX_ST_RECV,       1               @ BFT_ST_RECV of bft.s: a firmware transfer is receiving (staging buffer in use)
    .equ FA_READ,           0x01

    .equ bfx_stage,         v_20001240      @ log_buf (log/files.s), as bft_stage of bft.s
    .equ bfx_fil,           ff16_fil_a      @ as bft_fil_a
    .equ bfx_dir,           ff16_dir_a
    .equ bfx_finfo,         ff16_finfo

    .section .bss_port.bftsd, "aw", %nobits
    .balign 4
    .global bfx_ans
bfx_ans:        .space 248                  @ answer being built: 8 + 3 + 232 = 243 bytes at most; data from offset 9
bfx_path:       .space 68                   @ "0:" + name + NUL (2 + 63 + 1)
    .global bfx_staged
bfx_staged:     .space 2                    @ bytes of the last READ held in the staging buffer (0: none)

    .section .rodata.bftsd, "a", %progbits
bfx_root:       .asciz "0:"                 @ the root directory of drive 0
@ Protected names for DELETE: length, name in lower case, padded to 12 bytes.  Compared with the name folded to lower
@ case (bit 5 set, which only changes the letters of the permitted character set).
bfx_prot_tab:
    .byte 7
    .ascii "cal.bin"
    .byte 0, 0, 0, 0
    .byte 11
    .ascii "eevblog.bin"
    .byte 10
    .ascii "btload.tmp"
    .byte 0

    .section .text.bftsd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bfx_reply - build the answer of type 0x82 and queue it
@ In       : r0 = status, r1 = field (u16), r2 = length of the data (already at bfx_ans + 9, <= 232)
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ Note     : a refusal of the queue (full) leaves the sender to repeat the request, as with the 0x81 answers
@ -----------------------------------------------------------------------------
LFUNC bfx_reply
    push {r4, r5, lr}
    ldr r4, =bfx_ans
    mov r5, r2                              @ r5 = length of the data
    strb r0, [r4, #6]                       @ status
    strb r1, [r4, #7]                       @ field, low byte
    lsrs r1, r1, #8
    strb r1, [r4, #8]                       @ field, high byte
    movs r0, #0xB5
    strb r0, [r4, #0]
    movs r0, #0x5B
    strb r0, [r4, #1]
    movs r0, #0x82
    strb r0, [r4, #2]                       @ type: file / settings answer
    ldr r0, =bft_pkt
    ldrb r1, [r0, #3]
    strb r1, [r4, #3]                       @ seq of the request answered
    ldrb r1, [r0, #4]
    strb r1, [r4, #4]
    adds r0, r5, #3
    strb r0, [r4, #5]                       @ len = status + field + data
    adds r0, r4, #2
    adds r1, r5, #7                         @ type, seq(2), len, status, field(2), data
    bl bft_crc16
    adds r1, r4, r5
    strb r0, [r1, #9]                       @ crc16 behind the data
    lsrs r0, r0, #8
    strb r0, [r1, #10]
    mov r0, r4
    adds r1, r5, #11                        @ 8 + 3 + data
    bl ble_tx_queue_put
    pop {r4, r5, pc}
ENDFUNC bfx_reply

@ -----------------------------------------------------------------------------
@ bfx_fail - end the card session after a failed step and map the FatFs result to an answer
@ In       : r0 = FatFs result (non-zero), r1 = step (BFX_STEP_*)
@ Out      : r0 = status (0x20 for FR_NO_FILE / FR_NO_PATH, else 0x24), r1 = field (0, or step << 8 | result), r2 = 0
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ -----------------------------------------------------------------------------
LFUNC bfx_fail
    push {r4, r5, lr}
    mov r4, r0
    mov r5, r1
    bl bft_card_end                         @ SDIO off, run clock
    cmp r4, #FR_NO_FILE
    beq 1f
    cmp r4, #FR_NO_PATH
    beq 1f
    orr r1, r4, r5, lsl #8                  @ step << 8 | FatFs result
    movs r0, #BFX_ST_CARD
    b 2f
1:  movs r0, #BFX_ST_NOTFOUND
    movs r1, #0
2:  movs r2, #0
    pop {r4, r5, pc}
ENDFUNC bfx_fail

@ -----------------------------------------------------------------------------
@ bfx_status - answer values for a status without field or data
@ In       : r0 = status
@ Out      : r0 = status, r1 = 0, r2 = 0
@ Clobbers : r1, r2
@ -----------------------------------------------------------------------------
LFUNC bfx_status
    movs r1, #0
    movs r2, #0
    bx lr
ENDFUNC bfx_status

@ -----------------------------------------------------------------------------
@ bfx_name - check the name of a request and build the path "0:" + name
@ In       : r0 = address of the name bytes, r1 = their count
@ Out      : r0 = 0 accepted (bfx_path = "0:" name NUL), 1 refused
@ Clobbers : r1, r2, r3, r12, flags (r4, r5 saved)
@ Note     : rules in the file header.  The leading and trailing checks exist because FatFs (create_name) skips leading
@            spaces for the short name and removes trailing spaces and dots, so those names would reach another file.
@ -----------------------------------------------------------------------------
LFUNC bfx_name
    push {r4, r5}
    subs r2, r1, #1
    cmp r2, #(BFX_NAME_MAX - 1)
    bhi .Lbn_bad                            @ no name, or more than 63 bytes
    ldr r2, =bfx_path
    movs r3, #'0'
    strb r3, [r2], #1
    movs r3, #':'
    strb r3, [r2], #1                       @ "0:"
    mov r4, r1                              @ r4 = bytes left
    movs r5, #0                             @ r5 = the byte before
.Lbn_loop:
    ldrb r3, [r0], #1
    sub r12, r3, #'0'
    cmp r12, #9
    bls .Lbn_ok                             @ digit
    orr r12, r3, #0x20
    sub r12, r12, #'a'
    cmp r12, #25
    bls .Lbn_ok                             @ letter (A-Z or a-z)
    cmp r3, #'.'
    bne 1f
    cmp r5, #'.'
    beq .Lbn_bad                            @ ".." refused
    b .Lbn_ok
1:  cmp r3, #'_'
    beq .Lbn_ok
    cmp r3, #' '
    beq .Lbn_ok
    cmp r3, #'-'
    bne .Lbn_bad                            @ everything else, '/', '\\' and ':' included
.Lbn_ok:
    strb r3, [r2], #1
    mov r5, r3
    subs r4, r4, #1
    bne .Lbn_loop
    movs r3, #0
    strb r3, [r2]                           @ NUL
    cmp r5, #' '
    beq .Lbn_bad                            @ trailing space
    cmp r5, #'.'
    beq .Lbn_bad                            @ trailing dot
    ldr r2, =bfx_path
    ldrb r3, [r2, #2]
    cmp r3, #' '
    beq .Lbn_bad                            @ leading space
    movs r0, #0
    pop {r4, r5}
    bx lr
.Lbn_bad:
    movs r0, #1
    pop {r4, r5}
    bx lr
ENDFUNC bfx_name

@ -----------------------------------------------------------------------------
@ bfx_protected - is the accepted name one of cal.bin, EEVBlog.bin, BTLOAD.TMP (any case)?
@ In       : r0 = length of the name; the name is in bfx_path + 2 (bfx_name accepted it)
@ Out      : r0 = 1 protected, 0 not
@ Clobbers : r1, r2, r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
LFUNC bfx_protected
    push {r4-r6}
    ldr r2, =bfx_prot_tab
    movs r5, #3                             @ three protected names
.Lpr_ent:
    ldrb r3, [r2]
    cmp r3, r0
    bne .Lpr_next                           @ another length
    ldr r4, =bfx_path
    adds r4, r4, #2                         @ the name
    adds r6, r2, #1                         @ the protected name
    mov r12, r0
.Lpr_cmp:
    ldrb r3, [r4], #1
    orr r3, r3, #0x20                       @ fold to lower case
    ldrb r1, [r6], #1
    cmp r3, r1
    bne .Lpr_next
    subs r12, r12, #1
    bne .Lpr_cmp
    movs r0, #1                             @ every byte equal
    pop {r4-r6}
    bx lr
.Lpr_next:
    adds r2, r2, #12
    subs r5, r5, #1
    bne .Lpr_ent
    movs r0, #0
    pop {r4-r6}
    bx lr
ENDFUNC bfx_protected

@ -----------------------------------------------------------------------------
@ bfx_put32 - store r1 little-endian at the (unaligned) address r0
@ Out      : r1 destroyed
@ -----------------------------------------------------------------------------
LFUNC bfx_put32
    strb r1, [r0, #0]
    lsrs r1, r1, #8
    strb r1, [r0, #1]
    lsrs r1, r1, #8
    strb r1, [r0, #2]
    lsrs r1, r1, #8
    strb r1, [r0, #3]
    bx lr
ENDFUNC bfx_put32

@ -----------------------------------------------------------------------------
@ bfx_list - LIST: entries of the root directory
@ In       : bft_pkt (payload: start(2), or IMP-50 start(2) max(1))
@ Out      : r0 = status, r1 = field, r2 = length of the data (at bfx_ans + 9)
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Note     : the entries before start are read and dropped (a directory has no random access in FatFs without a seek
@            that the order of the entries would not support).  The data area is filled with whole entries only.
@ -----------------------------------------------------------------------------
LFUNC bfx_list
    push {r4-r7, lr}
    sub sp, sp, #8                          @ [sp] end flag
    ldr r4, =bft_pkt
    ldrb r0, [r4, #5]
    movs r1, #255                           @ no limit beyond the 232 bytes (at most 232 / 11 = 21 entries fit)
    cmp r0, #2
    beq 1f
    cmp r0, #3
    bne .Lls_arg                            @ the payload is start(2) or, IMP-50, start(2) max(1)
    ldrb r1, [r4, #8]
    cmp r1, #0
    beq .Lls_arg                            @ max 0 is refused
1:  str r1, [sp, #4]                        @ [sp + 4] = most entries in this answer
    ldrh r5, [r4, #6]                       @ r5 = entries to skip
    movs r6, #0                             @ r6 = entries packed
    movs r7, #0                             @ r7 = bytes packed
    movs r0, #0
    str r0, [sp]                            @ end flag
    bl bft_card_begin
    ldr r0, =bfx_dir
    ldr r1, =bfx_root
    bl fat_f_opendir
    cmp r0, #0
    bne .Lls_e1
.Lls_skip:
    cbz r5, .Lls_next
    ldr r0, =bfx_dir
    ldr r1, =bfx_finfo
    bl fat_f_readdir
    cmp r0, #0
    bne .Lls_e3
    ldr r1, =bfx_finfo
    ldrb r0, [r1, #FNO_FNAME]
    cmp r0, #0
    beq .Lls_end   @ the directory ended inside the skipped entries
    subs r5, r5, #1
    b .Lls_skip
.Lls_next:
    ldr r0, [sp, #4]
    cmp r6, r0
    bhs .Lls_done                           @ IMP-50: max entries packed (not the end: the next LIST continues)
    ldr r0, =bfx_dir
    ldr r1, =bfx_finfo
    bl fat_f_readdir
    cmp r0, #0
    bne .Lls_e3
    ldr r4, =bfx_finfo
    ldrb r0, [r4, #FNO_FNAME]
    cbz r0, .Lls_end                        @ empty name: the end of the directory
    add r1, r4, #FNO_FNAME
    movs r2, #0
.Lls_len:
    ldrb r3, [r1, r2]
    cbz r3, .Lls_lend
    adds r2, r2, #1                         @ the name is NUL-terminated inside FILINFO (255 + NUL)
    b .Lls_len
.Lls_lend:
    movs r5, #0                             @ r5 = attribute bit 7: name cut
    cmp r2, #BFX_NAME_MAX
    bls 1f
    movs r2, #BFX_NAME_MAX
    movs r5, #0x80
1:  adds r3, r2, #BFX_ENTRY_HDR             @ r3 = bytes of this entry
    adds r0, r7, r3
    cmp r0, #BFX_MAXDATA
    bhi .Lls_done                           @ does not fit: not counted, the next LIST starts with it
    ldr r0, =bfx_ans
    adds r0, r0, #9
    adds r0, r0, r7                         @ r0 = where the entry goes
    ldr r1, [r4, #FNO_FSIZE]                @ file size, low word of the 64-bit FSIZE_t
    ldr r12, [r4, #(FNO_FSIZE + 4)]
    cmp r12, #0
    beq 2f
    mvn r1, #0                              @ above 4 GiB: 0xFFFFFFFF
2:  bl bfx_put32                            @ size (r0 kept)
    ldrh r1, [r4, #FNO_FDATE]
    strb r1, [r0, #4]
    lsrs r1, r1, #8
    strb r1, [r0, #5]
    ldrh r1, [r4, #FNO_FTIME]
    strb r1, [r0, #6]
    lsrs r1, r1, #8
    strb r1, [r0, #7]
    ldrb r1, [r4, #FNO_FATTRIB]
    orrs r1, r1, r5
    strb r1, [r0, #8]
    strb r2, [r0, #9]                       @ namelen
    adds r0, r0, #BFX_ENTRY_HDR
    add r1, r4, #FNO_FNAME
3:  cbz r2, 4f
    ldrb r12, [r1], #1
    strb r12, [r0], #1
    subs r2, r2, #1
    b 3b
4:  adds r7, r7, r3
    adds r6, r6, #1
    b .Lls_next
.Lls_end:
    movs r0, #1
    str r0, [sp]                            @ end of the directory reached
.Lls_done:
    bl bft_card_end
    ldr r1, [sp]
    lsls r1, r1, #15                        @ BFX_END
    orrs r1, r1, r6                         @ field = count | end flag
    mov r2, r7
    movs r0, #0
    b .Lls_ret
.Lls_e1:
    movs r1, #BFX_STEP_OPEN
    b .Lls_fail
.Lls_e3:
    movs r1, #BFX_STEP_READ
.Lls_fail:
    bl bfx_fail
    b .Lls_ret
.Lls_arg:
    movs r0, #BFX_ST_ARG
    bl bfx_status
.Lls_ret:
    add sp, sp, #8
    pop {r4-r7, pc}
ENDFUNC bfx_list

@ -----------------------------------------------------------------------------
@ bfx_read - READ: part of a file into the staging buffer, with its CRC-32
@ In       : bft_pkt (payload: namelen(1) name offset(4) len(2))
@ Out      : r0 = status, r1 = field (bytes read), r2 = length of the data (the CRC-32 at bfx_ans + 9)
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Note     : an offset beyond the end of the file reads nothing (f_lseek in read mode stops at the end of the file).
@            The staging buffer is the one the firmware transfer fills, so a READ while a transfer is receiving is
@            refused (status 3); bfx_staged is cleared first, so a failed READ leaves nothing to CHUNK.
@ -----------------------------------------------------------------------------
LFUNC bfx_read
    push {r4-r7, lr}
    sub sp, sp, #8                          @ [sp] bytes read
    movs r0, #0
    ldr r1, =bfx_staged
    strh r0, [r1]                           @ the old staged bytes are lost from here on
    ldr r0, =bft_state
    ldrb r0, [r0]
    cmp r0, #BFX_ST_RECV
    beq .Lrd_busy                           @ the staging buffer holds received firmware bytes
    ldr r4, =bft_pkt
    ldrb r5, [r4, #5]                       @ r5 = payload length
    cmp r5, #0
    beq .Lrd_arg
    ldrb r6, [r4, #6]                       @ r6 = name length
    subs r0, r6, #1
    cmp r0, #(BFX_NAME_MAX - 1)
    bhi .Lrd_name                           @ no name, or more than 63 bytes
    adds r0, r6, #7                         @ namelen(1) name offset(4) len(2)
    cmp r0, r5
    bne .Lrd_arg
    adds r0, r4, #7
    mov r1, r6
    bl bfx_name
    cmp r0, #0
    bne .Lrd_name
    adds r0, r4, #7
    adds r0, r0, r6
    bl bft_le32                             @ offset
    mov r7, r0
    adds r0, r4, r6
    ldrb r1, [r0, #11]
    ldrb r2, [r0, #12]
    orr r5, r1, r2, lsl #8                  @ r5 = len
    subs r0, r5, #1
    movw r1, #(BFX_READ_MAX - 1)
    cmp r0, r1
    bhi .Lrd_arg                            @ 0 or above 8192
    bl bft_card_begin
    ldr r0, =bfx_fil
    ldr r1, =bfx_path
    movs r2, #FA_READ
    bl fat_f_open
    cbnz r0, .Lrd_f1
    ldr r0, =bfx_fil
    mov r1, r7
    bl fat_f_lseek
    cbnz r0, .Lrd_f2
    ldr r0, =bfx_fil
    ldr r1, =bfx_stage
    mov r2, r5
    mov r3, sp
    bl fat_f_read
    cbnz r0, .Lrd_f3
    ldr r0, =bfx_fil
    bl fat_f_close
    cbnz r0, .Lrd_f5
    bl bft_card_end
    @ the CRC-32 of the bytes read, outside the card session (the SDIO block is off, the link hears again)
    ldr r5, [sp]                            @ r5 = bytes read
    mvn r0, #0
    ldr r1, =bfx_stage
    mov r2, r5
    bl bft_crc32
    mvn r1, r0                              @ final XOR
    ldr r0, =bfx_ans
    adds r0, r0, #9
    bl bfx_put32
    ldr r0, =bfx_staged
    strh r5, [r0]                           @ the bytes can be fetched with CHUNK
    mov r1, r5                              @ field = bytes read
    movs r2, #4
    movs r0, #0
    b .Lrd_ret
.Lrd_f2:
    movs r1, #BFX_STEP_SEEK
    b .Lrd_fclose
.Lrd_f3:
    movs r1, #BFX_STEP_READ
.Lrd_fclose:
    mov r4, r0                              @ keep the result of the failed step, close the file
    mov r5, r1
    ldr r0, =bfx_fil
    bl fat_f_close
    mov r0, r4
    mov r1, r5
    b .Lrd_fail
.Lrd_f1:
    movs r1, #BFX_STEP_OPEN
    b .Lrd_fail
.Lrd_f5:
    movs r1, #BFX_STEP_FREE                 @ step 5: the close
.Lrd_fail:
    bl bfx_fail
    b .Lrd_ret
.Lrd_busy:
    movs r0, #BFX_ST_NOTALLOWED
    b .Lrd_stat
.Lrd_name:
    movs r0, #BFX_ST_NAME
    b .Lrd_stat
.Lrd_arg:
    movs r0, #BFX_ST_ARG
.Lrd_stat:
    bl bfx_status
.Lrd_ret:
    add sp, sp, #8
    pop {r4-r7, pc}
ENDFUNC bfx_read

@ -----------------------------------------------------------------------------
@ bfx_chunk - CHUNK: 232 bytes of the staged data, or len bytes (IMP-50)
@ In       : bft_pkt (payload: idx(2), or idx(2) len(1))
@ Out      : r0 = status, r1 = field (idx), r2 = length of the data (copied to bfx_ans + 9)
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ -----------------------------------------------------------------------------
LFUNC bfx_chunk
    push {r4, lr}
    ldr r3, =bft_pkt
    ldrb r0, [r3, #5]
    movs r12, #BFX_MAXDATA                  @ r12 = chunk size: 232, or IMP-50 the len byte
    cmp r0, #2
    beq 1f
    cmp r0, #3
    bne .Lch_arg                            @ the payload is idx(2) or idx(2) len(1)
    ldrb r12, [r3, #8]
    cmp r12, #0
    beq .Lch_arg                            @ len 0 is refused
    cmp r12, #BFX_MAXDATA
    bhi .Lch_arg                            @ above 232 is refused
1:  ldrh r1, [r3, #6]                       @ r1 = idx
    mul r0, r1, r12                         @ r0 = offset of the chunk (<= 65535 * 232)
    ldr r2, =bfx_staged
    ldrh r2, [r2]
    subs r2, r2, r0                         @ bytes staged beyond the offset
    ble .Lch_arg                            @ nothing there (or nothing staged)
    cmp r2, r12
    it hi
    movhi r2, r12                           @ r2 = length of this chunk
    mov r4, r2
    ldr r3, =bfx_stage
    adds r3, r3, r0                         @ source
    ldr r0, =bfx_ans
    adds r0, r0, #9                         @ destination
    mov r12, r4
1:  ldrb r2, [r3], #1
    strb r2, [r0], #1
    subs r12, r12, #1
    bne 1b
    movs r0, #0                             @ status 0, field = idx (r1)
    mov r2, r4
    pop {r4, pc}
.Lch_arg:
    movs r0, #BFX_ST_ARG
    bl bfx_status
    pop {r4, pc}
ENDFUNC bfx_chunk

@ -----------------------------------------------------------------------------
@ bfx_delete - DELETE: remove a file of the root directory
@ In       : bft_pkt (payload: namelen(1) name)
@ Out      : r0 = status, r1 = field, r2 = 0
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ Note     : cal.bin, EEVBlog.bin and BTLOAD.TMP are never deleted (status 0x23); f_unlink also removes an empty
@            directory and refuses (FR_DENIED, status 0x24) a read-only file or a directory that is not empty.
@ -----------------------------------------------------------------------------
LFUNC bfx_delete
    push {r4, r5, lr}
    ldr r4, =bft_pkt
    ldrb r0, [r4, #5]                       @ payload length
    cbz r0, .Ldl_arg
    ldrb r5, [r4, #6]                       @ name length
    subs r1, r5, #1
    cmp r1, #(BFX_NAME_MAX - 1)
    bhi .Ldl_name
    adds r1, r5, #1                         @ namelen(1) name
    cmp r1, r0
    bne .Ldl_arg
    adds r0, r4, #7
    mov r1, r5
    bl bfx_name
    cbnz r0, .Ldl_name
    mov r0, r5
    bl bfx_protected
    cbnz r0, .Ldl_prot
    bl bft_card_begin
    ldr r0, =bfx_path
    bl fat_f_unlink                         @ f_unlink syncs the volume before it returns
    cbnz r0, .Ldl_fail
    bl bft_card_end
    movs r0, #0
    bl bfx_status
    b .Ldl_ret
.Ldl_fail:
    movs r1, #BFX_STEP_DELETE
    bl bfx_fail
    b .Ldl_ret
.Ldl_prot:
    movs r0, #BFX_ST_PROTECTED
    b .Ldl_stat
.Ldl_name:
    movs r0, #BFX_ST_NAME
    b .Ldl_stat
.Ldl_arg:
    movs r0, #BFX_ST_ARG
.Ldl_stat:
    bl bfx_status
.Ldl_ret:
    pop {r4, r5, pc}
ENDFUNC bfx_delete

@ -----------------------------------------------------------------------------
@ bfx_info - INFO: free and total clusters, sectors per cluster
@ In       : bft_pkt (no payload)
@ Out      : r0 = status, r1 = field (sectors per cluster), r2 = 8 (free clusters(4), total clusters(4) at bfx_ans + 9)
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Note     : f_getfree sets fs->csize (sectors per cluster) and fs->n_fatent (clusters + 2) when it mounts the volume
@            (ff.c mount_volume), both read here after the call.
@ -----------------------------------------------------------------------------
LFUNC bfx_info
    push {r4, lr}
    sub sp, sp, #8                          @ [sp] free clusters, [sp+4] the FATFS pointer
    ldr r0, =bft_pkt
    ldrb r0, [r0, #5]
    cbnz r0, .Lin_arg                       @ no payload
    bl bft_card_begin
    ldr r0, =bfx_root
    mov r1, sp
    add r2, sp, #4
    bl fat_f_getfree
    cbnz r0, .Lin_fail
    bl bft_card_end
    ldr r4, [sp, #4]                        @ the FATFS object
    ldr r1, [sp]
    ldr r0, =bfx_ans
    adds r0, r0, #9
    bl bfx_put32                            @ free clusters
    ldr r1, [r4, #FS_N_FATENT]
    subs r1, r1, #2                         @ total clusters
    ldr r0, =bfx_ans
    adds r0, r0, #13
    bl bfx_put32
    ldrh r1, [r4, #FS_CSIZE]                @ field: sectors per cluster
    movs r2, #8
    movs r0, #0
    b .Lin_ret
.Lin_fail:
    movs r1, #BFX_STEP_FREE
    bl bfx_fail
    b .Lin_ret
.Lin_arg:
    movs r0, #BFX_ST_ARG
    bl bfx_status
.Lin_ret:
    add sp, sp, #8
    pop {r4, pc}
ENDFUNC bfx_info

@ -----------------------------------------------------------------------------
@ bfx_format - FORMAT: the card is formatted as exFAT, everything on it is gone (as the SETUP page Fr, set/fmt.s)
@ Out      : r0 = status, r1 = field, r2 = 0
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Note     : refused (0x22) unless the payload is exactly "FORMAT", so no other packet can erase a card; refused (0x25)
@            without the two-part bootloader, as the page Fr is not offered then; refused (3) while a firmware transfer
@            is receiving (f_mkfs works in log_buf, the staging buffer).  The staged READ bytes are lost (bfx_staged 0).
@ -----------------------------------------------------------------------------
LFUNC bfx_format
    push {r4, lr}
    ldr r0, =bft_state
    ldrb r0, [r0]
    cmp r0, #BFX_ST_RECV
    beq .Lfm_busy                           @ the staging buffer holds received firmware bytes
    ldr r4, =bft_pkt
    ldrb r0, [r4, #5]                       @ payload length
    cmp r0, #BFX_FMT_LEN
    bne .Lfm_arg
    adds r0, r4, #6                         @ the payload
    ldr r1, =bfx_fmt_word
    movs r2, #BFX_FMT_LEN
1:  ldrb r3, [r0], #1
    ldrb r12, [r1], #1
    cmp r3, r12
    bne .Lfm_arg
    subs r2, r2, #1
    bne 1b
    bl set_fmt_available                    @ 1 = the two-part bootloader is installed
    cbz r0, .Lfm_nofmt
    movs r0, #0
    ldr r1, =bfx_staged
    strh r0, [r1]                           @ f_mkfs overwrites the staging buffer
    bl bft_card_begin
    bl fmt_mkfs                             @ r0 = FatFs result
    cbnz r0, .Lfm_fail
    bl bft_card_end
    movs r0, #0
    bl bfx_status
    b .Lfm_ret
.Lfm_fail:
    movs r1, #BFX_STEP_FORMAT
    bl bfx_fail                             @ card off, 0x24 with step << 8 | result
    b .Lfm_ret
.Lfm_nofmt:
    movs r0, #BFX_ST_NOFMT
    b .Lfm_stat
.Lfm_busy:
    movs r0, #BFX_ST_NOTALLOWED
    b .Lfm_stat
.Lfm_arg:
    movs r0, #BFX_ST_ARG
.Lfm_stat:
    bl bfx_status
.Lfm_ret:
    pop {r4, pc}
ENDFUNC bfx_format

    .section .rodata.bftsd, "a", %progbits
bfx_fmt_word:
    .ascii "FORMAT"
    .section .text.bftsd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bfx_request - handle a request of type 0x10 .. 0x17 and queue the 0x82 answer
@ In       : r0 = type
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (bft_packet, after its CRC check and the gate of bft_poll)
@ Note     : refused with status 3 while a bootloader install is done and the restart is due (bft_reset_due), and for
@            any type of the range that is not assigned.
@ -----------------------------------------------------------------------------
FUNC bfx_request
    push {r4, lr}
    mov r4, r0
    ldr r0, =bft_reset_due
    ldrb r0, [r0]
    cbnz r0, .Lrq_refuse                    @ the meter is about to restart
    cmp r4, #BFX_T_LIST
    beq .Lrq_list
    cmp r4, #BFX_T_READ
    beq .Lrq_read
    cmp r4, #BFX_T_CHUNK
    beq .Lrq_chunk
    cmp r4, #BFX_T_DELETE
    beq .Lrq_delete
    cmp r4, #BFX_T_INFO
    beq .Lrq_info
    cmp r4, #BFX_T_FORMAT
    beq .Lrq_format
    cmp r4, #BFX_T_GET
    beq .Lrq_get
    cmp r4, #BFX_T_PUT
    beq .Lrq_put
.Lrq_refuse:
    movs r0, #BFX_ST_NOTALLOWED
    bl bfx_status
    b .Lrq_reply
.Lrq_list:
    bl bfx_list
    b .Lrq_reply
.Lrq_read:
    bl bfx_read
    b .Lrq_reply
.Lrq_chunk:
    bl bfx_chunk
    b .Lrq_reply
.Lrq_delete:
    bl bfx_delete
    b .Lrq_reply
.Lrq_info:
    bl bfx_info
    b .Lrq_reply
.Lrq_format:
    bl bfx_format
    b .Lrq_reply
.Lrq_get:
    bl bfs_get
    b .Lrq_reply
.Lrq_put:
    bl bfs_put
.Lrq_reply:
    bl bfx_reply
    pop {r4, pc}
ENDFUNC bfx_request

    .ltorg
