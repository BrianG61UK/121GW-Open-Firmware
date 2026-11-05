@ =============================================================================
@ bl_flash.s - program flash of the bootloader: erase, half-page and word writes, CRC-32, marks, control records
@
@ The bootloader writes only: the firmware area 0x08006000..0x08051FFF, the firmware mark page 0x0805FF00..0x0805FFFF,
@ the slots 0x08052000..0x0805DFFF and the control area 0x0805E000..0x0805FEFF (bootloader/DESIGN.md 6.1).  Every
@ operation is checked against these ranges when it is made; the starter and the bootloader area are never written by
@ the bootloader (only the starter writes 0x08000400..0x08005FFF, from a slot).  The data EEPROM and the option bytes
@ are never addressed.
@
@ Every operation runs in bl_ram_op, a routine in RAM (RM0038 3.4.3: half-page writes only from SRAM or the other bank;
@ a read of the bank being written is a bus error; 3.4.2: an erase or word write from the same bank stalls the CPU for
@ one tprog, so the receive interrupt could not run).  While the Bluetooth link is open the vector table and the
@ USART2 handler are in RAM too (bl_ble.s), so interrupts stay enabled during flash operations; in the card update
@ the caller masks interrupts around each operation (the SD driver's handlers are in flash).
@ Times (DS8576 Table 35): 3.28 ms typical, 3.94 ms maximum per erase, word or half-page.  Erased flash reads 0x00.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "bl.inc"

    .equ BL_PRGKEYR,        0x40023C10      @ RM0038 3.9.5
    .equ BL_PEKEY1,         0x89ABCDEF      @ FLASH_PEKEYR key 1 (unlocks FLASH_PECR, RM0038 3.9.4)
    .equ BL_PEKEY2,         0x02030405      @ FLASH_PEKEYR key 2
    .equ BL_PRGKEY1,        0x8C9DAEBF      @ FLASH_PRGKEYR key 1 (unlocks program memory, 3.9.5)
    .equ BL_PRGKEY2,        0x13141516      @ FLASH_PRGKEYR key 2
    .equ BL_SR_ERRORS,      0x00003F00      @ FLASH_SR bits 13..8, the error flags
    .equ BL_BUSY_POLLS,     0x40000         @ bound of the BSY wait: reads of FLASH_SR (bl_ram_op)
    .equ OP_ERASE,          0               @ page erase (256 bytes)
    .equ OP_HALFPAGE,       1               @ write one half-page (32 words, 128 bytes)
    .equ OP_WORD,           2               @ write one word

    .section .text.bl_flash, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bl_crc32 - CRC-32 (zlib) update
@ In       : r0 = running value (start 0xFFFFFFFF, final XOR 0xFFFFFFFF), r1 = address, r2 = length
@ Out      : r0 = running value
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ Note     : bitwise, no table: each byte is XORed into the low 8 bits, then eight right shifts, the polynomial
@            (reflected) XORed in whenever a 1 leaves.  Also used on RAM buffers (card update, headers) and on flash.
@ -----------------------------------------------------------------------------
FUNC bl_crc32
    ldr r12, =0xEDB88320                    @ reflected CRC-32 polynomial
1:  cbz r2, 4f                              @ length 0: done
    ldrb r3, [r1], #1
    eors r0, r0, r3                         @ the byte joins the low 8 bits of the running value
    movs r3, #8
2:  lsrs r0, r0, #1                         @ shift right, the bit shifted out is the carry
    it cs
    eorcs r0, r0, r12                       @ carry set: XOR the polynomial
    subs r3, r3, #1
    bne 2b
    subs r2, r2, #1
    b 1b
4:  bx lr
ENDFUNC bl_crc32

@ -----------------------------------------------------------------------------
@ bl_crc_final - CRC-32 of a whole region: start value 0xFFFFFFFF, bl_crc32, final inversion
@ In       : r1 = address, r2 = length
@ Out      : r0 = CRC-32
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC bl_crc_final
    push {lr}
    mov r0, #0xFFFFFFFF
    bl bl_crc32
    mvns r0, r0
    pop {pc}
ENDFUNC bl_crc_final

@ -----------------------------------------------------------------------------
@ bl_allowed - is [r0, r1) inside one range the bootloader may write?
@ In       : r0 = start address, r1 = end address (exclusive)
@ Out      : flags: Z set = allowed (r0, r1 kept), Z clear = refused
@ Clobbers : r2, r3, r12
@ Context  : main; the gate in front of every erase and program operation (the file header lists the ranges)
@ Note     : bl_ranges holds three (start, end) pairs; the range must lie wholly inside one of them.  An empty or
@            reversed range is refused.  The loads between cmp and the branch do not change the flags.
@ -----------------------------------------------------------------------------
LFUNC bl_allowed
    cmp r1, r0                              @ end <= start: refused
    bls 8f
    ldr r12, =bl_ranges                     @ table of three (start, end) pairs
    movs r3, #3                             @ pairs left
1:  ldr r2, [r12], #4                       @ r2 = start of the range
    cmp r0, r2
    ldr r2, [r12], #4                       @ r2 = end of the range (exclusive)
    blo 2f                                  @ our start is below this range: try the next
    cmp r1, r2
    bls 7f                                  @ our end <= range end: inside
2:  subs r3, r3, #1
    bne 1b
8:  movs r2, #1
    cmp r2, #0                              @ Z clear: refused
    bx lr
7:  cmp r0, r0                              @ Z set: allowed
    bx lr
ENDFUNC bl_allowed

@ -----------------------------------------------------------------------------
@ bl_op - one flash operation through bl_ram_op, unlocked before and locked after
@ In       : r0 = operation (OP_*), r1 = address, r2 = source (half-page) or value (word)
@ Out      : r0 = 0 done, else FLASH_SR error bits or 1 (BSY did not clear)
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ Context  : main (and the receive path with the USART2 interrupt enabled, see the file header)
@ Note     : the address is not range checked here; the callers (bl_erase, bl_write_hp, bl_write_words) call bl_allowed
@            first.  The unlock is repeated for every operation and FLASH_PECR is set to PELOCK afterwards, so
@            the flash is locked whenever no operation is running.
@ -----------------------------------------------------------------------------
LFUNC bl_op
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    ldr r0, =FLASH_PEKEYR                   @ unlock FLASH_PECR, then program memory (3.9.4, 3.9.5)
    ldr r1, =BL_PEKEY1
    str r1, [r0]
    ldr r1, =BL_PEKEY2
    str r1, [r0]
    @ second lock: program memory (FLASH_PRGKEYR keys, RM0038 3.9.5)
    ldr r0, =BL_PRGKEYR
    ldr r1, =BL_PRGKEY1
    str r1, [r0]
    ldr r1, =BL_PRGKEY2
    str r1, [r0]
    ldr r0, =FLASH_SR
    ldr r1, =BL_SR_ERRORS
    str r1, [r0]                            @ error flags of an earlier operation cleared
    @ arguments back into r0-r2 (the key writes used them)
    mov r0, r4
    mov r1, r5
    mov r2, r6
    ldr r3, =bl_ram_op                      @ the RAM copy of bl_ram_op (copied by bl_reset)
    blx r3
    mov r4, r0                              @ keep the result across the lock write
    ldr r0, =FLASH_PECR
    movs r1, #FLASH_PECR_PELOCK
    str r1, [r0]                            @ locked again
    mov r0, r4
    pop {r4-r6, pc}
ENDFUNC bl_op

@ -----------------------------------------------------------------------------
@ bl_erase - erase the pages [r0, r1) and check that they read 0
@ In       : r0 = start address (256-byte aligned), r1 = end address (the last page is erased in full)
@ Out      : r0 = 0, else non-zero (1 refused or not blank, else the bl_op error)
@ Clobbers : r1-r3, r12, flags (r4, r5 saved)
@ Context  : main
@ Note     : the page size is 256 bytes.  Erased flash reads 0x00 (not 0xFF), so a page is blank when all 64 words
@            are 0.  A start that is not page aligned, or a range outside bl_ranges, is refused before anything is
@            touched.
@ -----------------------------------------------------------------------------
FUNC bl_erase
    push {r4, r5, lr}
    mov r4, r0
    mov r5, r1
    tst r4, #0xFF                           @ start not 256-byte aligned: refused
    bne 8f
    bl bl_allowed
    bne 8f                                  @ range outside the allowed ranges: refused
1:  cmp r4, r5                              @ r4 = next page, r5 = end
    bhs 6f
    movs r0, #OP_ERASE
    mov r1, r4
    bl bl_op
    cbnz r0, 9f                             @ operation error (r0 from bl_op): return it
    @ read back: all 64 words of the page must read 0
    movs r1, #0
2:  ldr r2, [r4, r1]
    cbnz r2, 8f                             @ a non-zero word: refused
    adds r1, r1, #4
    cmp r1, #0x100                          @ 0x100 bytes = one page
    bne 2b
    add r4, r4, #0x100
    b 1b
6:  movs r0, #0
    b 9f
8:  movs r0, #1
9:  pop {r4, r5, pc}
ENDFUNC bl_erase

@ -----------------------------------------------------------------------------
@ bl_write_hp - write r2 half-pages from RAM r1 to r0 (128-byte aligned), read back
@ In       : r0 = destination in flash (128-byte aligned, erased), r1 = source in RAM, r2 = number of half-pages (>= 1)
@ Out      : r0 = 0, else non-zero (1 refused or the read-back differs, else the bl_op error)
@ Clobbers : r1-r3, r12, flags (r4-r7 saved)
@ Context  : main
@ Note     : a half-page is 128 bytes = 32 words, the write unit of the flash (RM0038 3.4.3).  Nothing here erases:
@            the destination must be blank.  After all half-pages are written the whole region is compared with the
@            source word by word.
@ -----------------------------------------------------------------------------
FUNC bl_write_hp
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    tst r4, #0x7F                           @ destination not 128-byte aligned: refused
    bne 8f
    cbz r6, 8f                              @ zero half-pages: refused
    add r1, r4, r6, lsl #7                  @ r1 = end = destination + count x 128
    bl bl_allowed
    bne 8f
    movs r7, #0                             @ r7 = half-page index
1:  movs r0, #OP_HALFPAGE
    add r1, r4, r7, lsl #7                  @ destination of this half-page
    add r2, r5, r7, lsl #7                  @ source of this half-page
    bl bl_op
    cbnz r0, 9f
    adds r7, r7, #1
    cmp r7, r6
    bne 1b
    lsls r6, r6, #7                         @ r6 = bytes in total
    @ read back: every word of the flash against the source
    movs r1, #0
2:  ldr r2, [r4, r1]
    ldr r3, [r5, r1]
    cmp r2, r3
    bne 8f
    adds r1, r1, #4
    cmp r1, r6
    bne 2b
    movs r0, #0
    b 9f
8:  movs r0, #1
9:  pop {r4-r7, pc}
ENDFUNC bl_write_hp

@ -----------------------------------------------------------------------------
@ bl_write_words - write r2 words from r1 to the erased flash at r0, read back
@ In       : r0 = destination (word aligned, erased), r1 = source, r2 = number of words (>= 1)
@ Out      : r0 = 0, else non-zero (1 refused or the read-back differs, else the bl_op error)
@ Clobbers : r1-r3, r12, flags (r4-r7 saved)
@ Context  : main
@ Note     : used for headers, marks and control records (5 or 4 words).  Words are written one at a time in ascending
@            order and each is read back at once, so a write that is cut short leaves the later words blank.
@ -----------------------------------------------------------------------------
FUNC bl_write_words
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    tst r4, #3                              @ destination not word aligned: refused
    bne 8f
    cbz r6, 8f                              @ zero words: refused
    add r1, r4, r6, lsl #2                  @ r1 = end = destination + count x 4
    bl bl_allowed
    bne 8f
1:  ldr r7, [r5], #4                        @ r7 = next word of the source
    movs r0, #OP_WORD
    mov r1, r4
    mov r2, r7
    bl bl_op
    cbnz r0, 9f
    ldr r0, [r4]                            @ read back
    cmp r0, r7
    bne 8f
    adds r4, r4, #4
    subs r6, r6, #1
    bne 1b
    movs r0, #0
    b 9f
8:  movs r0, #1
9:  pop {r4-r7, pc}
ENDFUNC bl_write_words

@ -----------------------------------------------------------------------------
@ bl_hdr_check - check a 5-word header (magic, length, CRC, version, self CRC)
@ In       : r0 = address, r1 = magic, r2 = largest length
@ Out      : r0 = length, or 0 when not valid
@ Clobbers : r1-r3, r12, flags (r4 saved)
@ Context  : main (the mark and slot headers, DESIGN.md 3 and 6.1)
@ Note     : layout: +0 magic, +4 image length, +8 CRC-32 of the image, +12 version, +16 CRC-32 of the first 16 bytes
@            (the header's own check).  Valid when the magic matches, the length is 1..r2 and the self CRC matches.
@            The image CRC is not checked here (boot-time check of the mark only, DESIGN.md 3).
@ -----------------------------------------------------------------------------
FUNC bl_hdr_check
    push {r4, lr}
    mov r4, r0
    ldr r3, [r4, #0]
    cmp r3, r1                              @ word 0 against the expected magic
    bne 8f
    @ length - 1 must be below the largest length (unsigned): length 1..r2
    ldr r3, [r4, #4]
    subs r3, r3, #1
    cmp r3, r2
    bhs 8f
    @ self CRC: CRC-32 of the first 16 bytes against word 4 (+16)
    mov r1, r4
    movs r2, #16
    bl bl_crc_final
    ldr r1, [r4, #16]
    cmp r0, r1
    bne 8f
    ldr r0, [r4, #4]                        @ r0 = the length
    pop {r4, pc}
8:  movs r0, #0
    pop {r4, pc}
ENDFUNC bl_hdr_check

@ -----------------------------------------------------------------------------
@ bl_fw_mark_ok - is the firmware mark valid?
@ Out      : r0 = length of the firmware image if the mark at FW_MARK is valid (magic FWH2, length 1..APP_MAX), else 0
@ Clobbers : r1-r3, r12, flags
@ Context  : main (bl_reset decides on it; update mode checks it for the 30 s start)
@ -----------------------------------------------------------------------------
FUNC bl_fw_mark_ok
    ldr r0, =FW_MARK
    ldr r1, =FW_MAGIC
    ldr r2, =APP_MAX
    b bl_hdr_check                          @ tail call
ENDFUNC bl_fw_mark_ok

@ -----------------------------------------------------------------------------
@ bl_write_header - build a header in bl_hdr_buf and write it to an erased page start
@ In       : r0 = destination, r1 = magic, r2 = length, r3 = CRC of the image; version word from bl_hdr_ver
@ Out      : r0 = 0, else non-zero
@ Clobbers : r1-r3, r12, flags (r4, r5 saved)
@ Context  : main (firmware mark at the end of an update, slot header of a bootloader image)
@ Note     : words 0..3 are magic, length, CRC, version; word 4 is the CRC-32 of those 16 bytes.  The words are written
@            in ascending order, so the self CRC goes last and an interrupted write leaves a header that fails
@            bl_hdr_check.
@ -----------------------------------------------------------------------------
@ -----------------------------------------------------------------------------
FUNC bl_write_header
    push {r4, r5, lr}
    mov r4, r0
    ldr r5, =bl_hdr_buf
    str r1, [r5, #0]
    str r2, [r5, #4]
    str r3, [r5, #8]
    ldr r0, =bl_hdr_ver
    ldr r0, [r0]
    str r0, [r5, #12]                       @ version word: from the START packet, 0 for a card update
    mov r1, r5
    movs r2, #16
    bl bl_crc_final                         @ self CRC over the 16 bytes just built
    str r0, [r5, #16]
    mov r0, r4
    mov r1, r5
    movs r2, #5                             @ 5 words
    bl bl_write_words
    pop {r4, r5, pc}
ENDFUNC bl_write_header

@ -----------------------------------------------------------------------------
@ bl_ctl_scan - read the control area
@ Out      : r0 = address of the last valid record or 0; r1 = first erased record or 0 (full)
@ Clobbers : r2, r3, r12, flags (r4-r6 saved)
@ Context  : main
@ Note     : the area CTL_BASE..CTL_END holds records of 16 bytes: +0 CTRL magic, +4 command, +8 argument, +12 CRC-32
@            of the first 12 bytes.  A record whose four words are all 0 is blank (erased flash reads 0) and ends the
@            scan; records with a wrong magic or CRC are skipped, so the last valid one counts (DESIGN.md 6.1).
@ -----------------------------------------------------------------------------
@ -----------------------------------------------------------------------------
FUNC bl_ctl_scan
    push {r4-r6, lr}
    movs r5, #0                             @ r5 = last valid record so far (0 none)
    ldr r4, =CTL_BASE
1:  ldr r0, =CTL_END
    cmp r4, r0                              @ end of the area reached: full
    bhs 3f
    ldm r4, {r0-r3}                         @ the four words of the record
    orr r6, r0, r1
    orr r6, r6, r2
    orrs r6, r6, r3
    beq 4f                                  @ all four words 0: blank record, stop here
    ldr r1, =CTL_MAGIC
    cmp r0, r1
    bne 2f
    mov r1, r4
    movs r2, #12
    bl bl_crc_final
    ldr r1, [r4, #12]
    cmp r0, r1
    it eq
    moveq r5, r4                            @ valid: remember it
2:  adds r4, r4, #16                        @ next record
    b 1b
3:  movs r4, #0                             @ no blank record: r4 = 0
4:  mov r0, r5                              @ r0 = last valid record
    mov r1, r4                              @ r1 = first blank record (or 0)
    pop {r4-r6, pc}
ENDFUNC bl_ctl_scan

@ -----------------------------------------------------------------------------
@ bl_ctl_append - append a record (command r0, argument r1); with fewer than 4 erased records left the area is erased
@ first (the starter ignores requests in a full area, DESIGN.md 6.3)
@ In       : r0 = command (CMD_INSTALL, CMD_TRIAL, CMD_OK), r1 = argument (a slot address for INSTALL)
@ Out      : r0 = 0, else non-zero
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ Context  : main (END of a bootloader image, bl_confirm)
@ Note     : erasing the area removes the earlier records with it; the new record is then the only one.  The record is
@            built in bl_hdr_buf and written as 4 words.
@ -----------------------------------------------------------------------------
@ -----------------------------------------------------------------------------
FUNC bl_ctl_append
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    bl bl_ctl_scan
    mov r6, r1
    cbz r6, 1f                              @ no blank record: erase first
    ldr r0, =(CTL_END - 4 * 16)             @ 4 blank records must remain: first blank <= CTL_END - 64
    cmp r6, r0
    bls 2f                                  @ enough room: write there
    @ erase the whole control area
1:  ldr r0, =CTL_BASE
    ldr r1, =CTL_END
    bl bl_erase
    cbnz r0, 9f
    ldr r6, =CTL_BASE
    @ record: magic, command, argument, CRC-32 of those 12 bytes
2:  ldr r3, =bl_hdr_buf
    ldr r0, =CTL_MAGIC
    str r0, [r3, #0]
    str r4, [r3, #4]
    str r5, [r3, #8]
    mov r1, r3
    movs r2, #12
    bl bl_crc_final
    ldr r1, =bl_hdr_buf
    str r0, [r1, #12]
    mov r0, r6
    movs r2, #4                             @ 4 words = 16 bytes
    bl bl_write_words
9:  pop {r4-r6, pc}
ENDFUNC bl_ctl_append

@ -----------------------------------------------------------------------------
@ bl_confirm - a bootloader started for the first time after an install (last record TRIAL) confirms itself: OK
@ Clobbers : r0-r3, r12, flags
@ Context  : main, from bl_reset right after the LCD lamp test and before the key test
@ Note     : appends an OK record (argument 0) only when the last valid record is TRIAL; with any other last record, or
@            none, nothing is written.  Without the OK the starter puts the previous bootloader back at the next reset
@            (DESIGN.md 6.2 step 3).
@ -----------------------------------------------------------------------------
@ -----------------------------------------------------------------------------
FUNC bl_confirm
    push {r4, lr}
    bl bl_ctl_scan
    cbz r0, 9f                              @ no valid record: nothing to confirm
    ldr r1, [r0, #4]                        @ r1 = command of the last record
    cmp r1, #CMD_TRIAL
    bne 9f
    movs r0, #CMD_OK
    movs r1, #0
    bl bl_ctl_append
9:  pop {r4, pc}
ENDFUNC bl_confirm

    .ltorg

    .section .rodata.bl_flash, "a", %progbits
    .balign 4
@ ranges that bl_allowed accepts
bl_ranges:                                  @ start, end (exclusive) of what the bootloader may write
    .word APP_BASE, APP_LIMIT               @ firmware
    .word SLOT_A, CTL_END                   @ slots and control area
    .word FW_MARK, FW_MARK + 0x100          @ firmware mark

    .section .bss.bl_flash, "aw", %nobits
    .balign 4
    .global bl_hdr_buf, bl_hdr_ver
bl_hdr_buf:     .space 20                   @ header or record under construction
bl_hdr_ver:     .space 4                    @ version word of the next header

@ -----------------------------------------------------------------------------
@ bl_ram_op - the flash operation itself, run from RAM (copied by bl_reset)
@ In       : r0 = OP_ERASE (r1 page start), OP_HALFPAGE (r1 destination, r2 source of 32 words in RAM), OP_WORD (r1
@            address, r2 value); FLASH_PECR and program memory unlocked
@ Out      : r0 = 0, FLASH_SR error bits, or 1 when BSY did not clear
@ Clobbers : r1-r3, r12, flags
@ Context  : main, called through bl_op; the only code that writes the flash
@ Note     : r3 = FLASH_SR, r4 = FLASH_PECR, r5 = operation.  Reads only RAM and the FLASH registers (literals in its
@            own RAM copy), so it never fetches from the flash bank being written (RM0038 3.4.3).  The local routine 10:
@            waits for BSY = 0 and returns r0 = 0, or 1 when BL_BUSY_POLLS reads did not see it clear.
@ -----------------------------------------------------------------------------
    .section .ramcode.bl_flash, "ax", %progbits
FUNC bl_ram_op
    push {r4, r5, lr}
    ldr r3, 20f                             @ FLASH_SR
    ldr r4, 21f                             @ FLASH_PECR
    mov r5, r0                              @ r5 = operation
    bl 10f                                  @ wait for BSY = 0 before starting
    cbnz r0, 9f                             @ BSY stuck: return 1, FLASH_PECR untouched
    cmp r5, #OP_HALFPAGE
    beq 2f                                  @ OP_HALFPAGE
    bhi 3f                                  @ above OP_HALFPAGE: OP_WORD
    movw r0, #0x208                         @ page erase: ERASE | PROG, word 0 to the page start (3.4.2)
    str r0, [r4]
    movs r0, #0
    str r0, [r1]                            @ the write starts the erase
    b 5f
2:  movw r0, #0x408                         @ half-page: FPRG | PROG, BSY = 0, 32 sequential words (3.4.3)
    str r0, [r4]
    bl 10f                                  @ BSY clear before the words are sent
    cbnz r0, 8f
    mov r12, #32                            @ 32 words = one half-page
4:  ldr r0, [r2], #4                        @ next source word (RAM)
    str r0, [r1], #4                        @ to the next flash word, in sequence
    subs r12, r12, #1
    bne 4b
    b 5f
3:  str r2, [r1]                            @ fast word write (3.4.3)
5:  bl 10f                                  @ the operation ends
    cbnz r0, 8f
    @ no wait error: collect the error flags of FLASH_SR (non-zero = failure)
    ldr r0, [r3]
    ldr r1, 22f
    ands r0, r0, r1                         @ error flags
8:  movs r1, #0
    str r1, [r4]                            @ no mode bit left set
9:  pop {r4, r5, pc}
10: ldr r0, 23f                             @ wait for BSY = 0: r0 = 0, or 1 after BL_BUSY_POLLS reads
11: ldr r12, [r3]
    tst r12, #1
    beq 12f
    subs r0, r0, #1
    bne 11b
    movs r0, #1
    bx lr
12: movs r0, #0
    bx lr
    .balign 4
20: .word FLASH_SR
21: .word FLASH_PECR
22: .word BL_SR_ERRORS
23: .word BL_BUSY_POLLS
ENDFUNC bl_ram_op
