@ =============================================================================
@ calbin.s - CAL module: cal.bin backup (save) and restore (load) on the SD card
@
@ v2.05 (EEPROM_MAP.md 8): file "cal.bin" in the card root (string 0x08029290), FatFs file object 0x20006A60,
@ RAM buffer 0x20001240, 1200 bytes = EEPROM 0x000..0x4AF, identity mapping.  Save: mount (error 1), open
@ create-always (0x0A, up to 10 tries, error 4), one write (error 7 if short), close, reopen for reading,
@ read back 0x200 + 0x200 + rest and compare (error 8 short read, 9 mismatch), file time, card off.  Load:
@ mount, open for reading (error 4), read 0x200 + 0x200 + 0xB0 (error 8), close, card off, then write every
@ byte and compare (error 9).
@ Port (OF-12, DESIGN.md 7.3): save writes 1248 bytes, EEPROM 0x000..0x4AF then 0x4D0..0x4FF (the six user-zero
@ slots verbatim; 0x4B0..0x4CF is never accessed and is not saved), read-back verify over 1248 bytes.  Load takes
@ the size from the file object after f_open (v2.05 FatFs R0.08a: FIL + 0x0C, f_open 0x08021D40..0x08021D54 copies the
@ directory entry size there; f_read 0x08021DB4..0x08021DBA reads remaining = [FIL + 0x0C] - [FIL + 8]; the production
@ image's FatFs R0.16 keeps it as the 64-bit obj.objsize at FIL + OBJ_OBJSIZE = 16, ff16x.inc, IMP-32) and accepts
@ exactly 1200 bytes (restores 0x000..0x4AF) or 1248 bytes (also bytes +0..+4 of each user-zero slot); any other
@ size is refused before any read or write with error 8 ("-Err-").  The EEPROM writes go through the NVM class
@ RESTORE (nvm_restore_begin / _next / _verify) and are compared with the EEPROM directly (OPT-07).
@ Mount, open modes, retry counts, file name, file time and the error codes are v2.05's.
@ IMP-38 (production): before the restore writes anything, the file's serial number (bytes 0x003..0x006, u32 big
@ endian, EEPROM_MAP.md 4) must equal the meter's own serial (0x20007D14, loaded at power-on and 0 when the EEPROM
@ holds none or an invalid one): a cal.bin of another meter, or the emulator's (serial 0), would otherwise overwrite this
@ meter's calibration, serial and settings without a trace (v2.05 checks only the length).  A meter without a valid
@ serial accepts any file, so a meter whose EEPROM was lost can still be restored from its backup.  Refused: error 10,
@ shown as "-Err-" like every other error, nothing written.
@ Structure (IMP-06): a state machine calbin_start / calbin_step; calbin_save and calbin_load run it to
@ completion (v2.05 order and SD command sequence).  The SD part is one step, so SYSCLK is HSE only inside that
@ step as in v2.05 (sys_clock_select(1) .. (0)); the EEPROM restore advances 16 bytes per step.
@ Context: main.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "ff16x.inc"

    .equ CALBIN_BUF,        v_20001240      @ log / cal.bin buffer (v2.05 0x0801CD2C)
    .equ CALBIN_FS,         ff16_fatfs      @ FatFs file system object (f_mount argument 0x0801CD50; production: R0.16 exFAT FATFS in .bss_port, IMP-32)
    .equ CALBIN_FIL,        ff16_fil_a      @ FatFs file object production image: FatFs R0.16 objects (FIL 552 bytes, DIR 44: larger than the v2.05 areas) in .bss_port (ff16_api.s, IMP-29)
    .equ CALBIN_RDBUF,      v_20006EA8      @ read-back buffer, 0x200 bytes (0x0801CDC6)
    .equ CALBIN_FIL_FSIZE,  OBJ_OBJSIZE     @ file size field of the file object: R0.16 obj.objsize, 64 bits (see header).
                                            @ F-1.04 and F-1.05 still read R0.08a's 0x0C here, which is not the size in
                                            @ the R0.16 object: every cal.bin was refused with error 8 (OF-12 size check)
    .equ CALBIN_LEN_V205,   1200            @ v2.05 file length 0x4B0
    .equ CALBIN_LEN,        1248            @ port file length (OF-12)
    .equ CALBIN_UZ_EE,      0x4D0           @ first user-zero slot in the EEPROM
    .equ CALBIN_UZ_BYTES,   48              @ six 8-byte slots

    @ states of the state machine
    .equ CB_IDLE,           0
    .equ CB_SV_FILL,        1               @ save: copy the EEPROM image into the buffer
    .equ CB_SV_SD,          2               @ save: the whole SD sequence
    .equ CB_LD_SD,          3               @ load: the whole SD sequence
    .equ CB_LD_RBEGIN,      4               @ load: open the RESTORE session
    .equ CB_LD_RNEXT,       5               @ load: write 16 bytes
    .equ CB_LD_VERIFY,      6               @ load: compare with the EEPROM
    .equ CB_DONE,           7

    .section .bss_port.cal, "aw", %nobits
    .align 2
    .global calbin_state, calbin_result
calbin_len:     .space 2                    @ accepted file length of a load (1200 or 1248)
calbin_state:   .space 1                    @ CB_*
calbin_result:  .space 1                    @ error code of the last operation (v2.05 codes 0, 1, 4, 7, 8, 9; 10 IMP-38)

    .section .text.cal, "ax", %progbits

@ -----------------------------------------------------------------------------
@ calbin_save - write cal.bin from the EEPROM
@ Replaces : 0x0801CD14 calbin_save
@ In       : -
@ Out      : r0 = 0 saved and verified, 1 mount failed, 4 open failed, 7 short write, 8 short read-back,
@            9 read-back mismatch (v2.05 codes)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (power-on window)
@ Deviation: OF-12 (1248 bytes)
@ -----------------------------------------------------------------------------
FUNC calbin_save
    push {r4, lr}
    movs r0, #0
    bl calbin_start
1:  bl calbin_step
    cmp r0, #0
    beq 1b                                  @ run to completion (baseline order, DESIGN.md 3.5)
    ldr r0, =calbin_result
    ldrb r0, [r0]
    pop {r4, pc}
ENDFUNC calbin_save

@ -----------------------------------------------------------------------------
@ calbin_load - restore the EEPROM from cal.bin
@ Replaces : 0x0801CF06 calbin_load
@ In       : -
@ Out      : r0 = 0 restored and verified, 1 mount failed, 4 open failed, 8 size refused / short read /
@            restore refused before any write, 9 mismatch after the write (v2.05 codes)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (power-on window)
@ Deviation: OF-12, OPT-07
@ -----------------------------------------------------------------------------
FUNC calbin_load
    push {r4, lr}
    movs r0, #1
    bl calbin_start
1:  bl calbin_step
    cmp r0, #0
    beq 1b
    ldr r0, =calbin_result
    ldrb r0, [r0]
    pop {r4, pc}
ENDFUNC calbin_load

@ -----------------------------------------------------------------------------
@ calbin_start - start a cal.bin save or load
@ Replaces : nothing in v2.05 (state machine form of 0x0801CD14 / 0x0801CF06, IMP-06)
@ In       : r0 = 0 save, 1 load
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : main
@ RAM      : writes calbin_state, calbin_result
@ -----------------------------------------------------------------------------
FUNC calbin_start
    ldr r1, =calbin_result
    cmp r0, #0
    ite eq                                  @ save starts with the buffer fill, load with the SD sequence
    moveq r0, #CB_SV_FILL
    movne r0, #CB_LD_SD
    strb r0, [r1, #-1]                      @ calbin_state (just before calbin_result)
    movs r0, #0
    strb r0, [r1]                           @ result 0
    bx lr
ENDFUNC calbin_start

@ -----------------------------------------------------------------------------
@ calbin_step - advance the cal.bin operation by one step
@ Replaces : nothing in v2.05 (IMP-06)
@ In       : -
@ Out      : r0 = 0 busy, 1 done (result in calbin_result)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC calbin_step
    push {r4, r5, r6, lr}
    ldr r4, =calbin_state
    ldrb r0, [r4]
    cmp r0, #CB_SV_FILL
    beq .Lcbs_fill
    cmp r0, #CB_SV_SD
    beq .Lcbs_svsd
    cmp r0, #CB_LD_SD
    beq .Lcbs_ldsd
    cmp r0, #CB_LD_RBEGIN
    beq .Lcbs_rbegin
    cmp r0, #CB_LD_RNEXT
    beq .Lcbs_rnext
    cmp r0, #CB_LD_VERIFY
    beq .Lcbs_verify
    movs r0, #CB_DONE                       @ CB_DONE, CB_IDLE or unknown: done
    strb r0, [r4]
    movs r0, #1
    pop {r4, r5, r6, pc}
.Lcbs_fill:
    bl calbin_fill
    movs r0, #CB_SV_SD
    b .Lcbs_next
.Lcbs_svsd:
    bl calbin_sd_save
    strb r0, [r4, #1]                       @ calbin_result
    movs r0, #CB_DONE
    b .Lcbs_next
.Lcbs_ldsd:
    bl calbin_sd_load
    strb r0, [r4, #1]
    cmp r0, #0
    ite eq                                  @ file read: restore; error: done
    moveq r0, #CB_LD_RBEGIN
    movne r0, #CB_DONE
    b .Lcbs_next
.Lcbs_rbegin:
    bl calbin_ident_ok                      @ IMP-38: 0 this meter's file (or the meter has no serial), 10 refused
    cbz r0, 2f
    strb r0, [r4, #1]                       @ calbin_result = 10: nothing written
    movs r0, #CB_DONE
    b .Lcbs_next
2:  NVM_ARM RESTORE
    ldr r0, =CALBIN_BUF
    ldr r1, =calbin_len
    ldrh r1, [r1]
    bl nvm_restore_begin                    @ 0 session open, 8 refused before any write
    strb r0, [r4, #1]
    cmp r0, #0
    ite eq                                  @ session open: write; refused: done
    moveq r0, #CB_LD_RNEXT
    movne r0, #CB_DONE
    b .Lcbs_next
.Lcbs_rnext:
    bl nvm_restore_next                     @ 0 more to write, 1 all written, 9 stopped
    cmp r0, #0
    beq .Lcbs_busy
    cmp r0, #1
    beq 1f
    strb r0, [r4, #1]                       @ 9
    movs r0, #CB_DONE
    b .Lcbs_next
1:  movs r0, #CB_LD_VERIFY
    b .Lcbs_next
.Lcbs_verify:
    bl nvm_restore_verify                   @ 0 equal, 9 first mismatch
    strb r0, [r4, #1]
    movs r0, #CB_DONE
.Lcbs_next:
    strb r0, [r4]
    cmp r0, #CB_DONE
    bne .Lcbs_busy
    movs r0, #1
    pop {r4, r5, r6, pc}
.Lcbs_busy:
    movs r0, #0
    pop {r4, r5, r6, pc}
ENDFUNC calbin_step

@ -----------------------------------------------------------------------------
@ calbin_fill - copy EEPROM 0x000..0x4AF and 0x4D0..0x4FF into the cal.bin buffer
@ Replaces : the copy loop of 0x0801CD14 (0x0801CD20..0x0801CD34, eeprom_read_u8_wrapper per byte)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20001240..0x2000171F (1248 bytes)
@ Deviation: OF-12 (bytes 1200..1247 = EEPROM 0x4D0..0x4FF)
@ -----------------------------------------------------------------------------
LFUNC calbin_fill
    push {r4, r5, r6, lr}
    ldr r5, =CALBIN_BUF
    movs r4, #0                             @ r4 = offset 0x000..0x4AF
1:  mov r0, r4
    bl eeprom_read_u8_wrapper
    strb r0, [r5, r4]
    adds r4, r4, #1
    movw r0, #CALBIN_LEN_V205
    cmp r4, r0
    blo 1b
    movs r4, #0                             @ r4 = 0..47: EEPROM 0x4D0 + r4 -> buffer 1200 + r4
    movw r6, #CALBIN_LEN_V205
    add r6, r6, r5                          @ r6 = buffer + 1200
2:  mov r0, #CALBIN_UZ_EE
    add r0, r0, r4
    bl eeprom_read_u8_wrapper
    strb r0, [r6, r4]
    adds r4, r4, #1
    cmp r4, #CALBIN_UZ_BYTES
    blo 2b
    pop {r4, r5, r6, pc}
ENDFUNC calbin_fill

@ -----------------------------------------------------------------------------
@ calbin_ident_ok - is the cal.bin in CALBIN_BUF this meter's own? (IMP-38)
@ In       : CALBIN_BUF holds the file (bytes 0x003..0x006: its serial, u32 big endian)
@ Out      : r0 = 0 accepted (same serial, or the meter has no valid serial: 0x20007D14 = 0), 10 refused
@ Clobbers : r0-r3, flags
@ Context  : main only (calbin_step, before nvm_restore_begin)
@ -----------------------------------------------------------------------------
LFUNC calbin_ident_ok
    ldr r0, =v_20007D14
    ldr r0, [r0]                            @ r0 = the meter's serial (power-on load: 0 when none or >= 100000)
    cbz r0, 1f                              @ no serial on this meter: nothing to protect it from, accepted
    ldr r1, =CALBIN_BUF
    ldrb r2, [r1, #3]                       @ the file's serial, most significant byte first (as the EEPROM holds it)
    ldrb r3, [r1, #4]
    orr r2, r3, r2, lsl #8
    ldrb r3, [r1, #5]
    orr r2, r3, r2, lsl #8
    ldrb r3, [r1, #6]
    orr r2, r3, r2, lsl #8
    cmp r2, r0
    bne 2f
1:  movs r0, #0
    bx lr
2:  movs r0, #10                            @ another meter's file (or one without a serial): refused
    bx lr
ENDFUNC calbin_ident_ok

@ -----------------------------------------------------------------------------
@ calbin_read_chunk - read the next part of cal.bin into the read buffer 0x20006EA8
@ Replaces : one f_read block of 0x0801CD14 / 0x0801CF06 (e.g. 0x0801CDBE..0x0801CDF0)
@ In       : r0 = byte count
@ Out      : r0 = 0 read completely, 8 error or short read
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x200080F4 (f_read result), 0x20007ED4 (bytes read), 0x20006EA8..
@ -----------------------------------------------------------------------------
LFUNC calbin_read_chunk
    push {r4, lr}
    mov r4, r0                              @ r4 = count
    ldr r3, =v_20007ED4                     @ bytes read
    mov r2, r4
    ldr r1, =CALBIN_RDBUF
    ldr r0, =CALBIN_FIL
    bl fn_08021D72                          @ f_read
    ldr r1, =v_200080F4
    strb r0, [r1]                           @ result kept as v2.05 (0x0801CDD6)
    cbnz r0, 1f
    ldr r0, =v_20007ED4
    ldr r0, [r0]
    cmp r0, r4
    bne 1f                                  @ short read
    movs r0, #0
    pop {r4, pc}
1:  movs r0, #8
    pop {r4, pc}
ENDFUNC calbin_read_chunk

@ -----------------------------------------------------------------------------
@ calbin_compare - compare the read buffer with part of the cal.bin buffer
@ Replaces : the compare loops of 0x0801CD14 (0x0801CDF8..0x0801CE1A, 0x0801CE5C..0x0801CE82,
@            0x0801CEC8..0x0801CEEE)
@ In       : r0 = offset in the cal.bin buffer, r1 = count
@ Out      : r0 = 0 equal, 9 first mismatch
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC calbin_compare
    ldr r2, =CALBIN_BUF
    add r2, r2, r0                          @ r2 = buffer part
    ldr r3, =CALBIN_RDBUF                   @ r3 = read buffer
1:  cbz r1, 2f
    ldrb r0, [r2], #1
    ldrb r12, [r3], #1
    cmp r0, r12
    bne 3f
    subs r1, r1, #1
    b 1b
2:  movs r0, #0
    bx lr
3:  movs r0, #9
    bx lr
ENDFUNC calbin_compare

@ -----------------------------------------------------------------------------
@ calbin_copy - copy the read buffer into part of the cal.bin buffer
@ Replaces : the copy loops of 0x0801CF06 (0x0801CF88..0x0801CFA0, 0x0801CFDE..0x0801CFFA,
@            0x0801D03C..0x0801D058)
@ In       : r0 = offset in the cal.bin buffer, r1 = count
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC calbin_copy
    ldr r2, =CALBIN_BUF
    add r2, r2, r0
    ldr r3, =CALBIN_RDBUF
1:  cbz r1, 2f
    ldrb r0, [r3], #1
    strb r0, [r2], #1
    subs r1, r1, #1
    b 1b
2:  bx lr
ENDFUNC calbin_copy

@ -----------------------------------------------------------------------------
@ calbin_sd_save - the SD part of the save
@ Replaces : 0x0801CD36..0x0801CF04 of calbin_save
@ In       : -
@ Out      : r0 = error code (0, 1, 4, 7, 8, 9)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : 0x200080F4, 0x20007ED4, 0x20007ED8, 0x200080F5..0x200080F7, FatFs objects
@ Deviation: OF-12 (length 1248, last read-back part 0xE0 bytes)
@ -----------------------------------------------------------------------------
LFUNC calbin_sd_save
    push {r4, r5, r6, lr}
    movs r4, #0                             @ r4 = error code
    movw r5, #CALBIN_LEN                    @ r5 = file length
    movs r0, #1
    bl sys_clock_select                     @ SD clock (0x0801CD38)
    movs r0, #10
    bl fn_0801F84C                          @ card bring-up, 10 tries (0x0801CD3E)
    cbz r0, 1f
    movs r4, #1
1:  cbnz r4, 2f
    ldr r1, =CALBIN_FS
    movs r0, #0
    bl fn_08021B80                          @ f_mount(0, fs) (0x0801CD56)
2:  cbnz r4, 3f
    movs r0, #10
    bl fn_0801D0D6                          @ open create-always, 10 tries (0x0801CD62)
    cbz r0, 3f
    movs r4, #4
3:  cbnz r4, 4f
    ldr r3, =v_20007ED8                     @ bytes written
    mov r2, r5
    ldr r1, =CALBIN_BUF
    ldr r0, =CALBIN_FIL
    bl fn_08021F60                          @ f_write (0x0801CD84)
    ldr r1, =v_200080F4
    strb r0, [r1]
    cbnz r0, 31f
    ldr r0, =v_20007ED8
    ldr r0, [r0]
    cmp r0, r5
    beq 4f
31: movs r4, #7                             @ short write (0x0801CDA4)
4:  ldr r0, =CALBIN_FIL
    bl fn_0802224C                          @ f_close, also after an error (0x0801CDAC)
    movs r2, #1                             @ FA_READ
    ldr r1, =v205_tab_08029290              @ "cal.bin"
    ldr r0, =CALBIN_FIL
    bl fn_08021BCC                          @ f_open for reading, result ignored (0x0801CDBA)
    mov r0, #0x200
    bl calbin_read_chunk                    @ first part, read even after an error (0x0801CDCE)
    cbz r0, 5f
    movs r4, #8                             @ (0x0801CDEE)
5:  cbnz r4, 6f
    movs r0, #0
    mov r1, #0x200
    bl calbin_compare
    mov r4, r0
6:  cbnz r4, 7f
    mov r0, #0x200
    bl calbin_read_chunk                    @ second part (0x0801CE32)
    mov r4, r0
    cbnz r4, 7f
    mov r0, #0x200
    mov r1, #0x200
    bl calbin_compare
    mov r4, r0
7:  cbnz r4, 8f
    sub r6, r5, #0x400                      @ rest: 0xE0 bytes for 1248 (v2.05 0xB0, 0x0801CE8A)
    mov r0, r6
    bl calbin_read_chunk
    mov r4, r0
    cbnz r4, 8f
    mov r0, #0x400
    mov r1, r6
    bl calbin_compare
    mov r4, r0
8:  movs r0, #1
    bl fn_0801D37C                          @ file time (0x0801CEF2)
    bl fn_08022932                          @ card off (0x0801CEF6)
    movs r0, #0
    bl sys_clock_select                     @ run clock (0x0801CEFC)
    mov r0, r4
    pop {r4, r5, r6, pc}
ENDFUNC calbin_sd_save

@ -----------------------------------------------------------------------------
@ calbin_sd_load - the SD part of the load: read cal.bin into the buffer
@ Replaces : 0x0801CF12..0x0801D06A of calbin_load
@ In       : -
@ Out      : r0 = error code (0, 1, 4, 8); calbin_len = accepted length
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : 0x200080F4, 0x20007ED4, 0x20001240.., FatFs objects, calbin_len
@ Deviation: OF-12 (size check from the file object's size; 1248-byte files read 0x200 + 0x200 + 0xE0)
@ -----------------------------------------------------------------------------
LFUNC calbin_sd_load
    push {r4, r5, r6, lr}
    movs r4, #0                             @ r4 = error code
    movs r5, #0                             @ r5 = accepted length
    movs r0, #1
    bl sys_clock_select                     @ (0x0801CF14)
    movs r0, #10
    bl fn_0801F84C                          @ (0x0801CF1A)
    cbz r0, 1f
    movs r4, #1
1:  cbnz r4, 2f
    ldr r1, =CALBIN_FS
    movs r0, #0
    bl fn_08021B80                          @ f_mount (0x0801CF32)
2:  movs r2, #1                             @ FA_READ; opened even after a mount error (0x0801CF36)
    ldr r1, =v205_tab_08029290
    ldr r0, =CALBIN_FIL
    bl fn_08021BCC
    cbz r0, 3f
    movs r4, #4
3:  cbnz r4, 5f
    ldr r0, =CALBIN_FIL
    ldr r1, [r0, #(CALBIN_FIL_FSIZE + 4)]   @ high word of the 64-bit size: 0 for every accepted size
    ldr r0, [r0, #CALBIN_FIL_FSIZE]         @ file size, low word (OF-12)
    cbz r1, 6f
    movs r0, #0                             @ 4 GiB or more: no accepted size
6:  movw r5, #CALBIN_LEN_V205
    cmp r0, r5
    beq 4f
    movw r5, #CALBIN_LEN
    cmp r0, r5
    beq 4f
    movs r5, #0
    movs r4, #8                             @ any other size: refused before reading
    b 5f
4:  mov r0, #0x200
    bl calbin_read_chunk                    @ (0x0801CF62)
    mov r4, r0
    cbnz r4, 5f
    movs r0, #0
    mov r1, #0x200
    bl calbin_copy
    mov r0, #0x200
    bl calbin_read_chunk                    @ (0x0801CFB8)
    mov r4, r0
    cbnz r4, 5f
    mov r0, #0x200
    mov r1, #0x200
    bl calbin_copy
    sub r6, r5, #0x400                      @ rest: 0xB0 or 0xE0 (0x0801D002)
    mov r0, r6
    bl calbin_read_chunk                    @ (0x0801D016)
    mov r4, r0
    cbnz r4, 5f
    mov r0, #0x400
    mov r1, r6
    bl calbin_copy
5:  ldr r0, =CALBIN_FIL
    bl fn_0802224C                          @ f_close (0x0801D05E)
    bl fn_08022932                          @ card off (0x0801D062)
    movs r0, #0
    bl sys_clock_select                     @ (0x0801D068)
    ldr r1, =calbin_len
    strh r5, [r1]
    mov r0, r4
    pop {r4, r5, r6, pc}
ENDFUNC calbin_sd_load

@ -----------------------------------------------------------------------------
@ fn_0801D0D6 - open cal.bin for writing (create always), with retries
@ Replaces : 0x0801D0D6
@ In       : r0 = number of tries
@ Out      : r0 = 0 opened, 1 every try failed
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x200080F5..0x200080F7 = '0', ':', 0 (0x0801D0DC..0x0801D0F2)
@ -----------------------------------------------------------------------------
FUNC fn_0801D0D6
    push {r4, r5, r6, lr}
    uxtb r4, r0                             @ r4 = tries
    movs r6, #1                             @ r6 = result
    ldr r1, =v_200080F5
    movs r0, #0x30                          @ '0'
    strb r0, [r1]
    movs r0, #0x3A                          @ ':'
    strb r0, [r1, #1]
    movs r0, #0
    strb r0, [r1, #2]
    movs r5, #0                             @ r5 = try counter
1:  cmp r5, r4
    bhs 3f
    movs r2, #0x0A                          @ FA_CREATE_ALWAYS | FA_WRITE (0x0801D104)
    ldr r1, =v205_tab_08029290
    ldr r0, =CALBIN_FIL
    bl fn_08021BCC
    cbz r0, 2f
    adds r5, r5, #1
    uxtb r5, r5
    b 1b
2:  movs r6, #0
3:  mov r0, r6
    pop {r4, r5, r6, pc}
ENDFUNC fn_0801D0D6

    .ltorg
