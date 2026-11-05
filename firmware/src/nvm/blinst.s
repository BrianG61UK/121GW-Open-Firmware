@ =============================================================================
@ blinst.s - NVM: program flash writer for the first install of the two-part bootloader (bootloader/DESIGN.md 6.4)
@
@ The only code of the image that writes program flash.  Owner decision 2026-11-04 (bootloader/DESIGN.md 5 item 6):
@ the application may write program flash only in
@     slot A          0x08052000..0x08057FFF   the bootloader image to install
@     control area    0x0805E000..0x0805FEFF   the INSTALL record for the starter
@     firmware mark   0x0805FF00..0x0805FFFF   the mark of the running firmware (the new bootloader starts only a
@                                              firmware with a valid mark, DESIGN.md G2)
@     starter         0x08000000..0x080003FF   the starter pages, once, only while 0x08000000..0x080000FF and
@                                              0x08000400..0x08005FFF are one of EEVblog's bootloader builds
@ Every write is checked against these ranges at the moment it is made, and only while a session opened by
@ blinst_open is active (blinst_open checks the bootloader area first).  Nothing else of program flash, the data
@ EEPROM or the option bytes is ever addressed here.
@
@ Hardware (RM0038 rev 15): page erase = word 0 stored to the page start with ERASE and PROG set in FLASH_PECR, from
@ any bank (the CPU stalls); fast word write = a word stored to an erased word with no mode bit set, from any bank;
@ half-page write = 32 sequential words with FPRG and PROG set, possible only from SRAM or from the other bank, and a
@ read of the same bank meanwhile is a bus error (3.4.3), so it runs from a RAM copy (blinst_ram) with interrupts off.
@ FLASH_PRGKEYR unlocks program memory after FLASH_PEKEYR unlocked FLASH_PECR (3.9.4, 3.9.5).  Erased flash reads 0.
@ Each operation: interrupts off, MPU off (the MPU guard makes program flash read-only, sys/reset.s), unlock, clear
@ the error flags, operate, wait for BSY = 0, read the error flags, lock (PELOCK), MPU and interrupts restored.
@ Context: main only (bft.s, END of a bootloader install transfer).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"

    .equ BLI_SLOT_A,        0x08052000
    .equ BLI_SLOT_END,      0x08058000
    .equ BLI_CTL,           0x0805E000
    .equ BLI_CTL_END,       0x0805FF00
    .equ BLI_FWMARK,        0x0805FF00
    .equ BLI_FWMARK_END,    0x08060000
    .equ BLI_STARTER,       0x08000000
    .equ BLI_STARTER_END,   0x08000400
    .equ BLI_BOOT_END,      0x08006000
    .equ BLI_FLASH_PRGKEYR, 0x40023C10      @ RM0038 3.9.5 (only here: never-brick rule exception of this module)
    .equ BLI_PEKEY1,        0x89ABCDEF      @ RM0038 3.9.4
    .equ BLI_PEKEY2,        0x02030405
    .equ BLI_PRGKEY1,       0x8C9DAEBF      @ RM0038 3.9.5
    .equ BLI_PRGKEY2,       0x13141516
    .equ BLI_SR_ERRORS,     0x00003F00      @ WRPERR, PGAERR, SIZERR, OPTVERR, OPTVERRUSR, RDERR (3.9.7)
    .equ BLI_PECR_PROG,     0x00000008
    .equ BLI_PECR_ERASE,    0x00000200
    .equ BLI_PECR_FPRG,     0x00000400
    .equ BLI_ARMED,         0xB1            @ blinst_session while a session is open
    .equ BLI_KNOWN_2018,    0x47430633      @ CRC-32 of 0x08000000..0x080000FF + 0x08000400..0x08005FFF, EEVblog build
                                            @ of the 2018 read-out (SHA-256 2d80fb01..., bootloader/DESIGN.md 1)
    .equ BLI_KNOWN_2026,    0xC6533EFA      @ the same of the owner's meter (SHA-256 1f0aa301...)
    .equ BLI_BUSY_POLLS,    0x40000         @ BSY wait bound: far above tprog 3.94 ms at 32 MHz (DS8576 Table 35)

@ results
    .equ BLI_OK,            0
    .equ BLI_E_SESSION,     1               @ no session open
    .equ BLI_E_RANGE,       2               @ address outside the allowed ranges or not aligned
    .equ BLI_E_FLASH,       3               @ FLASH_SR error flag, BSY timeout, or the written data reads back wrong

    .section .bss_port.blinst, "aw", %nobits
    .balign 4
    .equ BLI_RAM_LEN,       96
blinst_ram:     .space BLI_RAM_LEN          @ RAM copy of blinst_hp_code
blinst_session: .space 1                    @ BLI_ARMED while a session is open

    .section .text.nvm.blinst, "ax", %progbits

@ -----------------------------------------------------------------------------
@ blinst_crc32 - CRC-32 (zlib) update over flash or RAM
@ In       : r0 = running value (start 0xFFFFFFFF, final XOR 0xFFFFFFFF), r1 = address, r2 = length
@ Out      : r0 = running value
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC blinst_crc32
    ldr r12, =0xEDB88320
1:  cbz r2, 4f
    ldrb r3, [r1], #1
    eors r0, r0, r3
    movs r3, #8
2:  lsrs r0, r0, #1
    it cs
    eorcs r0, r0, r12
    subs r3, r3, #1
    bne 2b
    subs r2, r2, #1
    b 1b
4:  bx lr
ENDFUNC blinst_crc32

@ -----------------------------------------------------------------------------
@ blinst_open - open a write session if the bootloader area is one of EEVblog's builds
@ Out      : r0 = 0 opened; 1 the bootloader area is not a known EEVblog build (already replaced, or unknown)
@ Clobbers : r0-r3, r12, flags
@ Note     : pages 1..3 (0x08000100..0x080003FF) are left out of the check: the old bootloader's start without keys
@            does not use them (bootloader/DESIGN.md 6), and they hold the new starter after an interrupted install
@ -----------------------------------------------------------------------------
FUNC blinst_open
    push {r4, lr}
    mov r0, #0xFFFFFFFF
    ldr r1, =BLI_STARTER
    movs r2, #0x100
    bl blinst_crc32
    ldr r1, =BLI_STARTER_END
    ldr r2, =(BLI_BOOT_END - BLI_STARTER_END)
    bl blinst_crc32
    mvns r4, r0
    ldr r1, =BLI_KNOWN_2018
    cmp r4, r1
    beq 1f
    ldr r1, =BLI_KNOWN_2026
    cmp r4, r1
    beq 1f
    movs r0, #1
    pop {r4, pc}
1:  movs r0, #BLI_ARMED
    ldr r1, =blinst_session
    strb r0, [r1]
    movs r0, #0
    pop {r4, pc}
ENDFUNC blinst_open

@ -----------------------------------------------------------------------------
@ blinst_close - end the write session
@ Clobbers : r0, r1
@ -----------------------------------------------------------------------------
FUNC blinst_close
    movs r0, #0
    ldr r1, =blinst_session
    strb r0, [r1]
    bx lr
ENDFUNC blinst_close

@ -----------------------------------------------------------------------------
@ blinst_allowed - is [r0, r1) inside one allowed range, with a session open?
@ In       : r0 = first address, r1 = end address (exclusive)
@ Out      : r0 = 0 allowed, else BLI_E_SESSION or BLI_E_RANGE (r1 kept)
@ Clobbers : r2, r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC blinst_allowed
    ldr r2, =blinst_session
    ldrb r2, [r2]
    cmp r2, #BLI_ARMED
    bne 9f
    cmp r1, r0
    bls 8f                                  @ empty or wrapped range
    ldr r12, =blinst_ranges
    movs r3, #4
1:  ldr r2, [r12], #4                       @ range start
    cmp r0, r2
    ldr r2, [r12], #4                       @ range end
    blo 2f
    cmp r1, r2
    bls 7f
2:  subs r3, r3, #1
    bne 1b
8:  movs r0, #BLI_E_RANGE
    bx lr
9:  movs r0, #BLI_E_SESSION
    bx lr
7:  movs r0, #0
    bx lr
ENDFUNC blinst_allowed

@ -----------------------------------------------------------------------------
@ blinst_begin / blinst_end - enter and leave the write state around one operation
@ blinst_begin: Out r0 = saved PRIMASK, r1 = saved MPU_CTRL; interrupts off, MPU off, FLASH_PECR and program
@               memory unlocked, error flags cleared.   blinst_end: In r0, r1 as returned; Out r0 = 0 or BLI_E_FLASH
@               (an error flag was set); FLASH_PECR locked, MPU and interrupts restored.
@ Clobbers : r2, r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC blinst_begin
    mrs r0, primask
    cpsid i
    ldr r2, =MPU_CTRL
    ldr r1, [r2]
    movs r3, #0
    str r3, [r2]                            @ MPU off: program flash writable for the bus (PM0056 4.2.6)
    dsb
    isb
    ldr r2, =FLASH_PEKEYR
    ldr r3, =BLI_PEKEY1
    str r3, [r2]
    ldr r3, =BLI_PEKEY2
    str r3, [r2]
    ldr r2, =BLI_FLASH_PRGKEYR
    ldr r3, =BLI_PRGKEY1
    str r3, [r2]
    ldr r3, =BLI_PRGKEY2
    str r3, [r2]
    ldr r2, =FLASH_SR
    ldr r3, =BLI_SR_ERRORS
    str r3, [r2]
    bx lr
ENDFUNC blinst_begin

LFUNC blinst_end
    push {r0, r1}
    ldr r2, =FLASH_SR
    ldr r12, [r2]
    ldr r3, =BLI_SR_ERRORS
    ands r12, r12, r3
    ldr r2, =FLASH_PECR
    movs r3, #FLASH_PECR_PELOCK
    str r3, [r2]                            @ PELOCK: PECR, program memory and data EEPROM locked (3.9.2)
    pop {r0, r1}
    ldr r2, =MPU_CTRL
    str r1, [r2]
    dsb
    isb
    msr primask, r0
    movs r0, #0
    cmp r12, #0
    it ne
    movne r0, #BLI_E_FLASH
    bx lr
ENDFUNC blinst_end

@ -----------------------------------------------------------------------------
@ blinst_wait - wait for FLASH_SR.BSY = 0 (bounded)
@ Out      : r0 = 0, or BLI_E_FLASH after BLI_BUSY_POLLS reads
@ Clobbers : r1, r2, flags
@ -----------------------------------------------------------------------------
LFUNC blinst_wait
    ldr r1, =FLASH_SR
    ldr r2, =BLI_BUSY_POLLS
1:  ldr r0, [r1]
    tst r0, #1
    beq 2f
    subs r2, r2, #1
    bne 1b
    movs r0, #BLI_E_FLASH
    bx lr
2:  movs r0, #0
    bx lr
ENDFUNC blinst_wait

@ -----------------------------------------------------------------------------
@ blinst_erase_page - erase one page and check that it reads 0
@ In       : r0 = page start (256-byte aligned)
@ Out      : r0 = BLI_OK or BLI_E_*
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
FUNC blinst_erase_page
    push {r4-r6, lr}
    mov r4, r0
    movs r0, #BLI_E_RANGE
    tst r4, #0xFF
    bne 9f
    mov r0, r4
    add r1, r4, #0x100
    bl blinst_allowed
    cbnz r0, 9f
    bl blinst_begin
    mov r5, r0
    mov r6, r1
    bl blinst_wait
    ldr r2, =FLASH_PECR
    movw r3, #(BLI_PECR_ERASE | BLI_PECR_PROG)
    str r3, [r2]
    movs r3, #0
    str r3, [r4]                            @ page erase (3.4.2)
    bl blinst_wait
    ldr r2, =FLASH_PECR
    movs r3, #0
    str r3, [r2]
    mov r0, r5
    mov r1, r6
    bl blinst_end
    cbnz r0, 9f
    movs r1, #0                             @ the page reads 0
1:  ldr r2, [r4, r1]
    cbnz r2, 8f
    adds r1, r1, #4
    cmp r1, #0x100
    bne 1b
    b 9f
8:  movs r0, #BLI_E_FLASH
9:  pop {r4-r6, pc}
ENDFUNC blinst_erase_page

@ -----------------------------------------------------------------------------
@ blinst_write_word - fast word write to an erased word, read back
@ In       : r0 = address (word aligned), r1 = value
@ Out      : r0 = BLI_OK or BLI_E_*
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
FUNC blinst_write_word
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    movs r0, #BLI_E_RANGE
    tst r4, #3
    bne 9f
    mov r0, r4
    adds r1, r4, #4
    bl blinst_allowed
    cbnz r0, 9f
    bl blinst_begin
    push {r0, r1}
    bl blinst_wait
    str r5, [r4]                            @ fast word write (3.4.3)
    bl blinst_wait
    pop {r0, r1}
    bl blinst_end
    cbnz r0, 9f
    ldr r1, [r4]
    cmp r1, r5
    it ne
    movne r0, #BLI_E_FLASH
9:  pop {r4-r6, pc}
ENDFUNC blinst_write_word

@ -----------------------------------------------------------------------------
@ blinst_write_hp - write half-pages from RAM, read back
@ In       : r0 = first address (128-byte aligned), r1 = source in RAM (word aligned), r2 = number of half-pages
@ Out      : r0 = BLI_OK or BLI_E_*
@ Clobbers : r1-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
FUNC blinst_write_hp
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    movs r0, #BLI_E_RANGE
    tst r4, #0x7F
    bne 9f
    cbz r6, 9f
    mov r0, r4
    add r1, r4, r6, lsl #7
    bl blinst_allowed
    cbnz r0, 9f
    ldr r0, =blinst_hp_code                 @ the half-page routine to RAM
    bic r0, r0, #1
    ldr r1, =blinst_ram
    movs r2, #(blinst_hp_code_end - blinst_hp_code) / 2
1:  ldrh r3, [r0], #2
    strh r3, [r1], #2
    subs r2, r2, #1
    bne 1b
    dsb
    isb
    mov r7, #0                              @ r7 = half-pages done
2:  bl blinst_begin
    push {r0, r1}
    add r0, r4, r7, lsl #7                  @ destination
    add r1, r5, r7, lsl #7                  @ source
    ldr r2, =FLASH_PECR
    ldr r3, =FLASH_SR
    ldr r12, =blinst_ram + 1
    blx r12
    pop {r0, r1}
    mov r2, r12                             @ BSY timeout result of the RAM routine
    push {r2}
    bl blinst_end
    pop {r2}
    orrs r0, r0, r2
    bne 9f
    adds r7, r7, #1
    cmp r7, r6
    bne 2b
    movs r1, #0                             @ read back
    lsls r6, r6, #7
3:  ldr r2, [r4, r1]
    ldr r3, [r5, r1]
    cmp r2, r3
    bne 8f
    adds r1, r1, #4
    cmp r1, r6
    bne 3b
    movs r0, #0
    b 9f
8:  movs r0, #BLI_E_FLASH
9:  pop {r4-r7, pc}
ENDFUNC blinst_write_hp

@ -----------------------------------------------------------------------------
@ blinst_hp_code - one half-page write; runs only from its RAM copy blinst_ram (position independent)
@ In       : r0 = destination, r1 = source (RAM), r2 = FLASH_PECR address, r3 = FLASH_SR address
@ Out      : r12 = 0, or BLI_E_FLASH when BSY did not clear
@ Clobbers : r0, r1, lr, flags; r4-r6 saved.  Reads only RAM and FLASH registers (no flash read while bank busy)
@ -----------------------------------------------------------------------------
    .balign 4
FUNC blinst_hp_code
    push {r4-r6, lr}
    movw r4, #(BLI_PECR_FPRG | BLI_PECR_PROG)
    str r4, [r2]
    bl 5f                                   @ BSY = 0 before loading (3.4.3)
    cmp r12, #0
    bne 4f                                  @ still busy: nothing loaded
    movs r5, #32
1:  ldr r4, [r1], #4
    str r4, [r0], #4
    subs r5, r5, #1
    bne 1b
    bl 5f                                   @ the write ends
4:  movs r4, #0
    str r4, [r2]                            @ no mode bit left set
    pop {r4-r6, pc}
5:  mov r12, #0x40000                       @ BSY wait bound (BLI_BUSY_POLLS)
6:  ldr r6, [r3]
    tst r6, #1
    beq 7f
    subs r12, r12, #1
    bne 6b
    mov r12, #BLI_E_FLASH
    bx lr
7:  mov r12, #0
    bx lr
blinst_hp_code_end:
ENDFUNC blinst_hp_code
    .global blinst_hp_code_end              @ link/121gw.ld checks that the routine fits blinst_ram (96 bytes)

    .section .rodata.nvm.blinst, "a", %progbits
    .balign 4
@ allowed ranges: start, end (exclusive)
blinst_ranges:
    .word BLI_SLOT_A,  BLI_SLOT_END
    .word BLI_CTL,     BLI_CTL_END
    .word BLI_FWMARK,  BLI_FWMARK_END
    .word BLI_STARTER, BLI_STARTER_END

    .section .text.nvm.blinst, "ax", %progbits
    .ltorg
