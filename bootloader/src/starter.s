@ =============================================================================
@ starter.s - first part of the two-part bootloader (bootloader/DESIGN.md 6.2)
@
@ Occupies 0x08000000..0x080003FF and is written once per meter (DESIGN.md 6.4); it never writes itself.  At every
@ reset it decides which bootloader runs: it installs a bootloader image from slot A or B into 0x08000400..0x08005FFF
@ when the control area asks for it, puts the previous bootloader back when a new one never confirmed its start
@ (trial), installs from a slot when no valid bootloader is present, and then starts the bootloader at 0x08000400.
@
@ Formats (bootloader/tools/blimage.py builds and checks the same):
@   header (slot header at the slot start, bootloader mark at 0x08005F00), 5 words:
@     magic HDR_MAGIC, length 1..BL_MAX, CRC-32 of the image, version, CRC-32 of the four words before it
@   slot: header, image from slot + 0x100
@   control record (CTL_BASE..CTL_END, 16 bytes each, appended into erased words, the last valid one counts):
@     magic CTL_MAGIC, command, argument (a slot address), CRC-32 of the three words before it
@ CRC-32: the reflected polynomial 0xEDB88320, initial value and final XOR 0xFFFFFFFF (zlib crc32).
@
@ Flash facts (RM0038 rev 15): erased flash reads 0x00; page erase = word store of 0 to the page start with ERASE
@ and PROG set (3.4.2); half-page write = 32 sequential word stores with FPRG and PROG set, possible only from SRAM
@ or from the other bank, and a read of the same bank while it runs is a bus error (3.4.3); fast word write = a word
@ store to an erased word with no mode bit set, allowed from flash (3.4.3); wait for SR.BSY = 0 before every
@ operation.  The bootloader area is in bank 1, so erase and half-page writes run from the RAM copy of ram_flash
@ with interrupts off.  Times: 3.28 ms typical, 3.94 ms maximum per erase, word or half-page (DS8576 Table 35).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb

    .equ FLASH_R,       0x40023C00      @ FLASH interface (RM0038 3.9)
    .equ F_PECR,        0x04
    .equ F_PEKEYR,      0x0C
    .equ F_PRGKEYR,     0x10
    .equ F_SR,          0x18
    .equ PEKEY1,        0x89ABCDEF      @ PECR unlock keys (3.9.4)
    .equ PEKEY2,        0x02030405
    .equ PRGKEY1,       0x8C9DAEBF      @ program memory unlock keys (3.9.5)
    .equ PRGKEY2,       0x13141516
    .equ SR_ERRORS,     0x3F00          @ WRPERR, PGAERR, SIZERR, OPTVERR, OPTVERRUSR, RDERR (rc_w1, 3.9.7)
    .equ PECR_PELOCK,   0x0001
    .equ PECR_PROG,     0x0008
    .equ PECR_ERASE,    0x0200
    .equ PECR_FPRG,     0x0400

    .equ BL_BASE,       0x08000400      @ bootloader: vector table here (512-byte boundary needed, PM0056 4.4.4)
    .equ MARK,          0x08005F00      @ bootloader mark (header format), page of its own
    .equ BL_END,        0x08006000      @ end of the bootloader area, the firmware starts here
    .equ BL_MAX,        0x5B00          @ MARK - BL_BASE: largest bootloader image
    .equ SLOT_A,        0x08052000      @ slots of 24 KB: header page, image from +0x100
    .equ SLOT_B,        0x08058000
    .equ SLOT_XOR,      0x0000A000      @ SLOT_A ^ SLOT_B: the other slot
    .equ SLOT_IMG,      0x100
    .equ CTL_BASE,      0x0805E000      @ control area: records of 16 bytes
    .equ CTL_END,       0x0805FF00      @ the firmware mark page follows
    .equ HDR_MAGIC,     0x32484C42      @ "BLH2"
    .equ CTL_MAGIC,     0x4C525443      @ "CTRL"
    .equ CMD_INSTALL,   1               @ install the slot named by the argument
    .equ CMD_TRIAL,     2               @ starter: installed, not yet confirmed; argument = slot of the previous one
    .equ CMD_OK,        3               @ nothing to do (written by the bootloader to confirm, or by the starter)
    .equ VTOR,          0xE000ED08      @ SCB vector table offset register (PM0056 4.4.4)
    .equ STACK_TOP,     0x20002000

@ -----------------------------------------------------------------------------
@ vector table: stack pointer, reset; NMI and HardFault stop (MemManage, BusFault and UsageFault are disabled after
@ reset and escalate to HardFault, PM0056 2.3.2).  No interrupt is ever enabled by the starter.
@ -----------------------------------------------------------------------------
    .section .vectors, "a", %progbits
    .word STACK_TOP
    .word st_reset + 1
    .word st_halt + 1
    .word st_halt + 1

    .section .text, "ax", %progbits
    .thumb_func
st_halt:
    b       st_halt

@ -----------------------------------------------------------------------------
@ st_reset - reset entry
@ -----------------------------------------------------------------------------
    .global st_reset
    .thumb_func
st_reset:
    cpsid   i                           @ no interrupt during flash work (none is enabled, this is a second guard)
    ldr     r0, =__ram_lma              @ copy ram_flash to its RAM address
    ldr     r1, =__ram_vma
    ldr     r2, =__ram_lma_end
1:  ldr     r3, [r0], #4
    str     r3, [r1], #4
    cmp     r0, r2
    blo     1b
    ldr     r3, =FLASH_R                @ unlock FLASH_PECR, then program memory (3.9.4, 3.9.5)
    ldr     r0, =PEKEY1
    str     r0, [r3, #F_PEKEYR]
    ldr     r0, =PEKEY2
    str     r0, [r3, #F_PEKEYR]
    ldr     r0, =PRGKEY1
    str     r0, [r3, #F_PRGKEYR]
    ldr     r0, =PRGKEY2
    str     r0, [r3, #F_PRGKEYR]
    mov     r0, #SR_ERRORS              @ clear error flags left from before the reset
    str     r0, [r3, #F_SR]

    bl      ctl_scan                    @ r0 = last valid record or 0, r1 = first free record or 0
    cbz     r0, st_boot                 @ no request
    cbz     r1, st_boot                 @ control area full: requests are ignored, so nothing repeats at every reset
    mov     r6, r1
    ldr     r4, [r0, #4]                @ command
    ldr     r5, [r0, #8]                @ slot
    cmp     r4, #CMD_INSTALL
    beq     st_install
    cmp     r4, #CMD_TRIAL
    bne     st_boot
    @ the bootloader installed last never confirmed its start: put the previous one back (DESIGN.md 6.2 step 3)
    mov     r0, r5
    bl      slot_ok
    cbz     r0, 2f
    mov     r0, r5
    bl      install
2:  movs    r0, #CMD_OK
    b       st_record
st_install:                             @ install request (DESIGN.md 6.2 step 2)
    mov     r0, r5
    bl      slot_ok
    cbz     r0, 3f                      @ slot not valid: request dropped
    mov     r0, r5
    bl      install
    cbz     r0, 3f                      @ install failed (written flash differs): dropped, fallback below
    eor     r5, r5, #SLOT_XOR           @ previous bootloader = the other slot
    movs    r0, #CMD_TRIAL
    b       st_record
3:  movs    r0, #CMD_OK
st_record:
    mov     r1, r5
    mov     r2, r6
    bl      ctl_write

@ start the bootloader whose mark is valid; else install slot A, else slot B; else stop (DESIGN.md 6.2 step 4)
st_boot:
    ldr     r4, =SLOT_A
    movs    r5, #3
4:  ldr     r0, =MARK
    bl      hdr_ok
    cbnz    r0, st_start
    subs    r5, #1
    beq     st_halt
    mov     r0, r4
    bl      slot_ok
    cbz     r0, 5f
    mov     r0, r4
    bl      install
5:  eor     r4, r4, #SLOT_XOR
    b       4b

st_start:                               @ hand over in reset state: flash locked, interrupts on, VTOR = its table
    ldr     r3, =FLASH_R
    movs    r0, #PECR_PELOCK
    str     r0, [r3, #F_PECR]
    ldr     r0, =BL_BASE
    ldr     r1, =VTOR
    str     r0, [r1]
    ldr     r1, [r0]
    ldr     r2, [r0, #4]
    msr     msp, r1
    cpsie   i
    bx      r2

@ -----------------------------------------------------------------------------
@ install - copy the slot's image into the bootloader area and write the mark (DESIGN.md 6.2 step 2)
@ In : r0 = slot (already checked by slot_ok)    Out: r0 = mark length (non-zero) if the mark checks, else 0
@ Order: mark page erased first, then the image pages, image programmed, compared, mark written last, so a power cut
@ at any point leaves no valid mark and the next reset installs again.
@ -----------------------------------------------------------------------------
    .thumb_func
install:
    push    {r4, r5, lr}
    mov     r4, r0
    ldr     r5, [r4, #4]                @ length rounded up to half-pages
    adds    r5, #127
    bic     r5, r5, #127
    ldr     r0, =MARK                   @ erase the mark page
    movs    r1, #0
    ldr     r2, =BL_END
    bl      ramcall
    ldr     r0, =BL_BASE                @ erase the image pages
    movs    r1, #0
    ldr     r2, =MARK
    bl      ramcall
    ldr     r0, =BL_BASE                @ program the image
    add     r1, r4, #SLOT_IMG
    adds    r2, r0, r5
    bl      ramcall
    ldr     r0, =BL_BASE                @ compare
    add     r1, r4, #SLOT_IMG
1:  ldr     r2, [r0], #4
    ldr     r3, [r1], #4
    cmp     r2, r3
    bne     3f
    subs    r5, #4
    bne     1b
    ldr     r3, =FLASH_R                @ mark = the slot header, five fast word writes
    movs    r5, #0
2:  ldr     r1, [r4, r5]
    ldr     r0, =MARK
    add     r0, r5
    bl      wword
    adds    r5, #4
    cmp     r5, #20
    bne     2b
3:  ldr     r0, =MARK
    pop     {r4, r5, lr}
    b       hdr_ok

@ ramcall - run ram_flash from RAM (r0..r2 as ram_flash)
    .thumb_func
ramcall:
    ldr     r3, =__ram_vma + 1
    bx      r3

@ -----------------------------------------------------------------------------
@ wword - fast word write of r1 to the erased word at r0; r3 = FLASH_R; waits for the end.  Clobbers r2.
@ -----------------------------------------------------------------------------
    .thumb_func
wword:
    str     r1, [r0]
1:  ldr     r2, [r3, #F_SR]
    lsls    r2, r2, #31                 @ BSY
    bne     1b
    bx      lr

@ -----------------------------------------------------------------------------
@ hdr_ok - check a header (slot header or bootloader mark)
@ In : r0 = address    Out: r0 = length if magic, length range and self CRC are right, else 0.  Clobbers r1-r3, r12.
@ -----------------------------------------------------------------------------
    .thumb_func
hdr_ok:
    push    {r4, lr}
    mov     r4, r0
    ldr     r1, [r4]
    ldr     r2, =HDR_MAGIC
    cmp     r1, r2
    bne     1f
    ldr     r1, [r4, #4]
    subs    r1, #1                      @ 1 <= length <= BL_MAX
    cmp     r1, #BL_MAX
    bhs     1f
    movs    r1, #16
    bl      crc32
    ldr     r1, [r4, #16]
    cmp     r0, r1
    bne     1f
    ldr     r0, [r4, #4]
    pop     {r4, pc}
1:  movs    r0, #0
    pop     {r4, pc}

@ -----------------------------------------------------------------------------
@ slot_ok - check a slot: header and the CRC-32 of its image
@ In : r0 = slot    Out: r0 = length, or 0.  Clobbers r1-r3, r12.
@ -----------------------------------------------------------------------------
    .thumb_func
slot_ok:
    push    {r4, lr}
    mov     r4, r0
    bl      hdr_ok
    cbz     r0, 1f
    mov     r1, r0
    add     r0, r4, #SLOT_IMG
    bl      crc32
    ldr     r1, [r4, #8]
    cmp     r0, r1
    ite     eq
    ldreq   r0, [r4, #4]
    movne   r0, #0
1:  pop     {r4, pc}

@ -----------------------------------------------------------------------------
@ crc32 - CRC-32 (zlib) of r1 bytes at r0, bitwise
@ In : r0 = address, r1 = length    Out: r0 = CRC.  Clobbers r1-r3, r12.
@ -----------------------------------------------------------------------------
    .thumb_func
crc32:
    mov     r2, #-1
    ldr     r3, =0xEDB88320
1:  subs    r1, #1
    bmi     3f
    ldrb    r12, [r0], #1
    eor     r2, r2, r12
    mov     r12, #8
2:  lsrs    r2, r2, #1
    it      cs
    eorcs   r2, r2, r3
    subs    r12, r12, #1
    bne     2b
    b       1b
3:  mvn     r0, r2
    bx      lr

@ -----------------------------------------------------------------------------
@ ctl_scan - read the control area
@ Out: r0 = last record with the right magic and CRC, or 0; r1 = first record with four zero words, or 0 (full).
@ A record cut short by a power loss fails its CRC and is skipped; the next one is written after it.
@ -----------------------------------------------------------------------------
    .thumb_func
ctl_scan:
    push    {r4-r6, lr}
    movs    r5, #0
    ldr     r4, =CTL_BASE
1:  ldr     r0, =CTL_END
    cmp     r4, r0
    bhs     3f
    ldm     r4, {r0-r3}
    orr     r6, r0, r1
    orr     r6, r6, r2
    orrs    r6, r6, r3
    beq     4f                          @ erased record: the first free one
    ldr     r1, =CTL_MAGIC
    cmp     r0, r1
    bne     2f
    mov     r0, r4
    movs    r1, #12
    bl      crc32
    ldr     r1, [r4, #12]
    cmp     r0, r1
    it      eq
    moveq   r5, r4
2:  adds    r4, #16
    b       1b
3:  movs    r4, #0
4:  mov     r0, r5
    mov     r1, r4
    pop     {r4-r6, pc}

@ -----------------------------------------------------------------------------
@ ctl_write - append a record: r0 = command, r1 = argument, r2 = free record (from ctl_scan, not 0)
@ The CRC word is written last, so a record cut short by a power loss is never valid.
@ -----------------------------------------------------------------------------
    .thumb_func
ctl_write:
    push    {r4, r5, lr}
    sub     sp, #16
    mov     r5, r2
    ldr     r4, =CTL_MAGIC
    str     r4, [sp]
    str     r0, [sp, #4]
    str     r1, [sp, #8]
    mov     r0, sp
    movs    r1, #12
    bl      crc32
    str     r0, [sp, #12]
    ldr     r3, =FLASH_R
    movs    r4, #0
1:  ldr     r1, [sp, r4]
    add     r0, r5, r4
    bl      wword
    adds    r4, #4
    cmp     r4, #16
    bne     1b
    add     sp, #16
    pop     {r4, r5, pc}

    .ltorg

@ -----------------------------------------------------------------------------
@ ram_flash - runs from RAM (copied by st_reset): erase pages or write half-pages in bank 1
@ In : r0 = first address (page start for erase, half-page start for writing), r2 = end address,
@      r1 = 0: erase the pages r0..r2;  r1 != 0: write the half-pages r0..r2 from r1 (word aligned, other bank)
@ Reads only RAM, FLASH registers and, while the half-page buffer is loaded, the source; it waits for BSY = 0
@ before every operation and after the last, so no flash read of bank 1 happens while bank 1 is busy.
@ Clobbers r0-r3, r12.
@ -----------------------------------------------------------------------------
    .section .ramcode, "ax", %progbits
    .thumb_func
ram_flash:
    push    {r4, lr}
    ldr     r3, 9f
1:  bl      7f                          @ previous operation finished
    cmp     r0, r2
    bhs     5f
    cbnz    r1, 3f
    movw    r4, #(PECR_ERASE | PECR_PROG)   @ page erase: word 0 to the page start
    str     r4, [r3, #F_PECR]
    movs    r4, #0
    str     r4, [r0]
    add     r0, r0, #256
    b       1b
3:  movw    r4, #(PECR_FPRG | PECR_PROG)    @ half-page write: 32 sequential words
    str     r4, [r3, #F_PECR]
    bl      7f
    mov     r12, #32
4:  ldr     r4, [r1], #4
    str     r4, [r0], #4
    subs    r12, r12, #1
    bne     4b
    b       1b
5:  movs    r4, #0                      @ no mode bit left set
    str     r4, [r3, #F_PECR]
    pop     {r4, pc}
7:  ldr     r4, [r3, #F_SR]             @ wait for BSY = 0
    lsls    r4, r4, #31
    bne     7b
    bx      lr
    .p2align 2
9:  .word   FLASH_R
