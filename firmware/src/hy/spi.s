@ =============================================================================
@ spi.s - HY: HY3131 bit-banged SPI bus (PF0 CK, PF1 CS, PF2 DI, PF3 DO/IRQ)
@
@ Replaces v2.05 hy3131_spi_clock_pulse 0x0800C1BC, hy3131_spi_write_byte 0x0800C16C, hy3131_spi_read_byte 0x0800C138,
@ hy3131_write_regs 0x0800C03C and hy3131_read_regs_to_rxbuf 0x0800C0C0 (analysis/hy3131_model.md 1.2).
@
@ Hardware safety (DESIGN.md 4.1): the HY3131 is written only through hy_write_frame, which refuses any frame whose
@ (first register, byte count) shape is not one of the six v2.05 shapes, and whose content is not one the v2.05
@ configuration code can produce (row membership, INTE set, restart bytes derived from the loaded row).  Bit order,
@ delays and pin sequences are the v2.05 ones; nothing here changes a GPIOF pin direction (BRD owns MODER).
@
@ Pin map (GPIOF, analysis/hy3131_model.md 1.2): PF0 = HY_CK (BSRR bit 0), PF1 = HY_CS (bit 1), PF2 = HY_DI (bit 2),
@ PF3 = HY_DO (IDR bit 3).  BSRRL (+0x18) sets, BSRRH (+0x1A) resets; v2.05 never writes ODR.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ HY_MIRROR_SIZE, 0x34              @ bytes of the register mirror adc_regs (registers 0x00..0x33, v2.05 0x08006152)
    .equ HY_PIN_CK, 1                      @ GPIOF pin 0 mask
    .equ HY_PIN_CS, 2                      @ GPIOF pin 1 mask
    .equ HY_PIN_DI, 4                      @ GPIOF pin 2 mask

    .section .text.hy.spi, "ax", %progbits

@ -----------------------------------------------------------------------------
@ hy3131_spi_clock_pulse - one HY3131 clock pulse on PF0 (CK)
@ Replaces : 0x0800C1BC hy3131_spi_clock_pulse (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS; calls fn_0800ECF6)
@ Context  : main only
@ RAM      : none directly
@ Spec     : analysis/hy3131_model.md 1.2
@ Deviation: none
@ Sequence (v2.05): delay(1); CK high; delay(1); CK low.  The chip latches DI on the rising edge (DS p14).
@ -----------------------------------------------------------------------------
FUNC hy3131_spi_clock_pulse
    push {r7, lr}                      @ 0x0800C1BC
    movs r0, #1                        @ 0x0800C1BE  delay(1) before the rising edge
    bl fn_0800ECF6                     @ 0x0800C1C0
    movs r0, #1                        @ 0x0800C1C4
    ldr r1, =(GPIOF_BASE + GPIO_BSRRL) @ 0x0800C1C6 pool 0x0800C280 = 0x40021818  GPIOF BSRRL
    strh r0, [r1, #0]                  @ 0x0800C1C8  PF0 (HY_CK) high
    movs r0, #1                        @ 0x0800C1CA
    bl fn_0800ECF6                     @ 0x0800C1CC  delay(1) with CK high
    movs r0, #1                        @ 0x0800C1D0
    ldr r1, =(GPIOF_BASE + GPIO_BSRRH) @ 0x0800C1D2 pool 0x0800C284 = 0x4002181A  GPIOF BSRRH
    strh r0, [r1, #0]                  @ 0x0800C1D4  PF0 (HY_CK) low
    pop {r0, pc}                       @ 0x0800C1D6
    .ltorg
ENDFUNC hy3131_spi_clock_pulse

@ -----------------------------------------------------------------------------
@ hy3131_spi_write_byte - shift one byte out on PF2 (DI), MSB first
@ Replaces : 0x0800C16C hy3131_spi_write_byte (v2.05)
@ In       : r0 = byte (bits 7..0 sent in that order)
@            r1 = 1: send one extra clock with DI low (the "SPI read period" clock of a read header, DS p14); 0: none
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : none directly
@ Spec     : analysis/hy3131_model.md 1.2
@ Deviation: none
@ Per bit: set or reset PF2 to the bit value, then one hy3131_spi_clock_pulse.  Afterwards DI is left high.
@ Deviation: IMP-19 (production: bit timing of the v2.05 read loop instead of delay(1) calls; same waveform order)
@ -----------------------------------------------------------------------------
FUNC hy3131_spi_write_byte
    @ IMP-19 (production): the same bits, levels and order with the bit timing of v2.05's own read loop instead of two
    @ delay(1) calls per bit.  v2.05 reads with no delay (hy3131_spi_read_byte below: CK high for 6..9 instructions,
    @ 0x0800C14E..0x0800C162), a timing every meter runs; here CK is high for at least 6 instructions and DI is set at least
    @ 3 instructions before the rising edge (datasheet figures: TCKHI 20 ns, TCKLO 60 ns, TDISET 60 ns, TDIHOLD 20 ns, DS
    @ p13; one instruction is 238 ns at 4.19 MHz).  DI changes only while CK is low, as before.
    push {r4, r5, lr}
    mov r4, r0                              @ byte
    ldr r2, =(GPIOF_BASE + GPIO_BSRRL)
    ldr r3, =(GPIOF_BASE + GPIO_BSRRH)
    movs r5, #0x80                          @ bit mask, MSB first
.Lwb_bit:
    movs r0, #HY_PIN_DI
    tst r4, r5
    ite ne
    strhne r0, [r2]                         @ bit set: DI high
    strheq r0, [r3]                         @ bit clear: DI low
    nop                                     @ DI setup: 3 instructions to the rising edge
    movs r0, #HY_PIN_CK
    strh r0, [r2]                           @ CK high: the chip latches DI
    nop
    nop
    nop
    nop
    nop                                     @ CK high for 6 instructions (5 nop and the store below)
    strh r0, [r3]                           @ CK low
    lsrs r5, r5, #1
    bne .Lwb_bit
    cmp r1, #1
    bne .Lwb_idle                           @ no extra clock
    movs r0, #HY_PIN_DI
    strh r0, [r3]                           @ the extra clock of a read header ("SPI read period", DS p14): DI low
    nop
    nop
    movs r0, #HY_PIN_CK
    strh r0, [r2]                           @ CK high
    nop
    nop
    nop
    nop
    nop
    strh r0, [r3]                           @ CK low
.Lwb_idle:
    movs r0, #HY_PIN_DI
    strh r0, [r2]                           @ DI left high (idle level), as v2.05
    pop {r4, r5, pc}
    .ltorg
ENDFUNC hy3131_spi_write_byte

@ -----------------------------------------------------------------------------
@ hy3131_spi_read_byte - shift one byte in from PF3 (DO), MSB first
@ Replaces : 0x0800C138 hy3131_spi_read_byte (v2.05)
@ In       : -
@ Out      : r0 = byte read
@ Clobbers : r0-r3, flags
@ Context  : main only
@ RAM      : none directly
@ Spec     : analysis/hy3131_model.md 1.2
@ Deviation: none
@ Per bit: CK high, sample IDR bit 3, CK low.  The chip changes DO after the falling edge (DS p14), so the sample after the
@ rising edge sees the bit presented since the previous falling edge.  There is no delay inside the loop (v2.05).
@ -----------------------------------------------------------------------------
FUNC hy3131_spi_read_byte
    movs r0, #0                        @ 0x0800C138
    movs r2, #1                        @ 0x0800C13A
    ldr r3, =(GPIOF_BASE + GPIO_BSRRH) @ 0x0800C13C pool 0x0800C284 = 0x4002181A
    strh r2, [r3, #0]                  @ 0x0800C13E  make sure CK is low before the first bit
    movs r2, #0                        @ 0x0800C140
    movs r1, r2                        @ 0x0800C142
.L0800C144:                              @ reached from 0x0800C166 b
    uxtb r1, r1                        @ 0x0800C144  bit counter r1 = 0..7
    cmp r1, #8                         @ 0x0800C146
    bge .L0800C168                     @ 0x0800C148
    movs r2, #1                        @ 0x0800C14A
    ldr r3, =(GPIOF_BASE + GPIO_BSRRL) @ 0x0800C14C pool 0x0800C280 = 0x40021818
    strh r2, [r3, #0]                  @ 0x0800C14E  CK high
    ldr r2, =(GPIOF_BASE + GPIO_IDR)   @ 0x0800C150 pool 0x0800C288 = 0x40021810
    ldrh r2, [r2, #0]                  @ 0x0800C152  sample GPIOF IDR
    lsls r2, r2, #28                   @ 0x0800C154  move IDR bit 3 (PF3) into the sign flag
    bpl .L0800C15E                     @ 0x0800C156
    movs r2, #128                      @ 0x0800C158  bit 3 set: OR in 0x80 >> bit
    asrs r2, r1                        @ 0x0800C15A
    orrs r0, r2                        @ 0x0800C15C
.L0800C15E:                              @ reached from 0x0800C156 bpl
    movs r2, #1                        @ 0x0800C15E
    ldr r3, =(GPIOF_BASE + GPIO_BSRRH) @ 0x0800C160 pool 0x0800C284 = 0x4002181A
    strh r2, [r3, #0]                  @ 0x0800C162  CK low
    adds r1, r1, #1                    @ 0x0800C164
    b .L0800C144                       @ 0x0800C166
.L0800C168:                              @ reached from 0x0800C148 bge
    uxtb r0, r0                        @ 0x0800C168  return the assembled byte
    bx lr                              @ 0x0800C16A
    .ltorg
ENDFUNC hy3131_spi_read_byte


@ -----------------------------------------------------------------------------
@ hy_note_refusal - count one refused HY3131 request
@ Replaces : new (DESIGN.md 4.1 item 4, hardware-safety counter in port RAM)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1, flags
@ Context  : main only
@ RAM      : reads  hy_refused_count
@            writes hy_refused_count
@ Spec     : DESIGN.md 4.1 items 2 and 4; 9.4 level 5 (the probe build reads this counter)
@ Deviation: NF-15 / HW-05 (refusals instead of writing an unlisted frame)
@ -----------------------------------------------------------------------------
FUNC hy_note_refusal
    ldr r1, =hy_refused_count
    ldrb r0, [r1]
    cmp r0, #255                            @ saturate: the counter is a diagnostic, never wraps to 0
    it lo                                   @ below the limit
    addlo r0, #1                            @ count the refusal
    strb r0, [r1]
    bx lr
    .ltorg
ENDFUNC hy_note_refusal

@ -----------------------------------------------------------------------------
@ hy_row_equal - compare two 20-byte configuration rows
@ Replaces : new
@ In       : r0 = row A, r1 = row B (byte pointers)
@ Out      : r0 = 1 equal, 0 different
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : none directly
@ Spec     : DESIGN.md 4.1 item 7
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC hy_row_equal
    movs r2, #20                            @ row length: registers 0x20..0x33
.Lre_next:
    ldrb r3, [r0], #1                       @ byte of A, advance
    ldrb r12, [r1], #1                      @ byte of B, advance
    cmp r3, r12
    bne .Lre_diff                           @ first difference ends the compare
    subs r2, #1
    bne .Lre_next
    movs r0, #1                             @ all 20 bytes equal
    bx lr
.Lre_diff:
    movs r0, #0
    bx lr
    .ltorg
ENDFUNC hy_row_equal

@ -----------------------------------------------------------------------------
@ hy_row_whitelisted - is a 20-byte row one that the v2.05 selector can produce?
@ Replaces : new (DESIGN.md 4.1 item 1 run-time companion of the build check; emulator/diff/hy3131_whitelist)
@ In       : r0 = pointer to the 20 bytes about to be written to registers 0x20..0x33
@ Out      : r0 = 1 the row equals a row of one of the 15 v2.05 tables or one of the two derived rows, 0 otherwise
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  hy_row_counts, hy_row_tables
@ Spec     : DESIGN.md 4.1; analysis/hy3131_model.md 3; hy_rows.s
@ Deviation: NF-15 (an unlisted row is refused instead of written)
@ -----------------------------------------------------------------------------
FUNC hy_row_whitelisted
    push {r4, r5, r6, r7, lr}
    movs r4, r0                             @ r4 = candidate row
    movs r7, #0                             @ r7 = table index
.Lrw_table:
    ldr r0, =hy_row_tables
    ldr r5, [r0, r7, lsl #2]                @ r5 = first row of this table
    ldr r0, =hy_row_counts
    ldrb r6, [r0, r7]                       @ r6 = rows left in this table
.Lrw_row:
    movs r0, r5
    movs r1, r4
    bl hy_row_equal
    cbnz r0, .Lrw_yes                       @ found in the v2.05 tables
    adds r5, #20                            @ next row (20 bytes per row)
    subs r6, #1
    bne .Lrw_row
    adds r7, #1
    cmp r7, #HY_TABLE_COUNT
    blo .Lrw_table
    ldr r5, =hy_row_variants                @ the two rows v2.05 derives at run time
    movs r6, #2
.Lrw_var:
    movs r0, r5
    movs r1, r4
    bl hy_row_equal
    cbnz r0, .Lrw_yes
    adds r5, #20
    subs r6, #1
    bne .Lrw_var
    movs r0, #0                             @ not a v2.05 row
    pop {r4, r5, r6, r7, pc}
.Lrw_yes:
    movs r0, #1
    pop {r4, r5, r6, r7, pc}
    .ltorg
ENDFUNC hy_row_whitelisted

@ -----------------------------------------------------------------------------
@ hy_frame_allowed - run-time whitelist of HY3131 write frames
@ Replaces : new (DESIGN.md 4.1 item 4)
@ In       : r0 = first register, r1 = pointer to the data bytes, r2 = byte count
@ Out      : r0 = 1 allowed, 0 refused
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  hy_row_r20, hy_row_r29, hy_write_shapes
@ Spec     : DESIGN.md 4.1 item 4 and the table of the eight v2.05 call sites
@ Deviation: NF-15, HW-05
@ Allowed frames (first register, bytes) and content:
@   (0x20, 20)  a configuration row (hy_row_whitelisted)                       v2.05 0x0800BE94
@   (0x1E,  2)  INTF = 0, INTE in {0x01, 0x04, 0x05, 0x11}                     v2.05 0x0800BF74
@   (0x1E,  1)  INTF acknowledge: any value with bits 6:5 = 0                  v2.05 0x0800616C (writes 0; OF-53)
@               INTF is a flag register, not configuration: a written 0 clears a flag, a written 1 leaves it unchanged
@               (DS p19 10.2 (7)); bits 6:5 carry no flag ("-") and stay 0 as in v2.05's write
@   (0x20,  1)  R20 restart value: row R20 & 0xFD, & 0xF9, or | 0x02            v2.05 0x0800BFC6, 0x0800C036
@   (0x1B,  3)  counter preset 00 00 E0 or 00 00 80                            v2.05 0x0800BFF0
@   (0x29,  1)  R29 peak restart value: row R29 or row R29 & 0xFB              v2.05 0x0800A872, 0x0800A88C
@ -----------------------------------------------------------------------------
FUNC hy_frame_allowed
    push {r4, lr}
    ldr r12, =hy_write_shapes               @ table of {first register, count} pairs
    movs r3, #0                             @ r3 = shape index
.Lfa_scan:
    ldrb r4, [r12, r3, lsl #1]              @ first register of shape r3
    cmp r4, r0
    bne .Lfa_next
    add r4, r12, r3, lsl #1                 @ address of the pair
    ldrb r4, [r4, #1]                       @ byte count of shape r3
    cmp r4, r2
    beq .Lfa_shape                          @ (register, count) both match
.Lfa_next:
    adds r3, #1
    cmp r3, #HY_SHAPE_COUNT
    blo .Lfa_scan
    b .Lfa_refuse                           @ shape not in the table
.Lfa_shape:
    cmp r3, #0
    beq .Lfa_row                            @ shape 0: 20-byte row
    cmp r3, #1
    beq .Lfa_inte                           @ shape 1: INTF + INTE
    cmp r3, #2
    beq .Lfa_intf                           @ shape 2: INTF only
    cmp r3, #3
    beq .Lfa_r20                            @ shape 3: R20 restart value
    cmp r3, #4
    beq .Lfa_preset                         @ shape 4: counter preset
    b .Lfa_r29                              @ shape 5: R29 restart value
.Lfa_row:
    movs r0, r1                             @ pointer to the row
    bl hy_row_whitelisted
    pop {r4, pc}
.Lfa_inte:
    ldrb r0, [r1]                           @ INTF byte must be 0 (write of 0 clears flags)
    cbnz r0, .Lfa_refuse
    ldrb r0, [r1, #1]                       @ INTE byte
    cmp r0, #0x01
    beq .Lfa_ok
    cmp r0, #0x04
    beq .Lfa_ok
    cmp r0, #0x05
    beq .Lfa_ok
    cmp r0, #0x11
    beq .Lfa_ok
    b .Lfa_refuse                           @ INTE value not produced by v2.05
.Lfa_intf:
    ldrb r0, [r1]
    tst r0, #0x60                           @ bits 6:5 ("-", DS p19) must be 0; flag bits 7, 4..0 may be 0 (clear) or 1 (keep)
    bne .Lfa_refuse
    b .Lfa_ok
.Lfa_r20:
    ldrb r0, [r1]                           @ value about to be written to R20
    ldr r2, =hy_row_r20
    ldrb r2, [r2]                           @ R20 of the loaded row
    and r3, r2, #0xFD                       @ modes 6..8: ENCTR cleared (v2.05 0x0800BFAA)
    cmp r0, r3
    beq .Lfa_ok
    and r3, r2, #0xF9                       @ other modes: ENCTR and ENPCMPO cleared (0x0800BFB8)
    cmp r0, r3
    beq .Lfa_ok
    orr r3, r2, #0x02                       @ final write: ENCTR set (0x0800C01A, 0x0800C028)
    cmp r0, r3
    beq .Lfa_ok
    b .Lfa_refuse
.Lfa_preset:
    ldrb r0, [r1]                           @ CTA<7:0> is always written as 0 (v2.05 0x0800BFD2)
    cbnz r0, .Lfa_refuse
    ldrb r0, [r1, #1]                       @ CTA<15:8>: low byte of the preset word 0x2000001C
    cbnz r0, .Lfa_refuse                    @ both presets 0xE000 and 0x8000 have a zero low byte
    ldrb r0, [r1, #2]                       @ CTA<23:16>: second byte of the preset word
    cmp r0, #0xE0
    beq .Lfa_ok
    cmp r0, #0x80
    beq .Lfa_ok
    b .Lfa_refuse
.Lfa_r29:
    ldrb r0, [r1]                           @ value about to be written to R29
    ldr r2, =hy_row_r29
    ldrb r2, [r2]                           @ R29 of the loaded row
    cmp r0, r2
    beq .Lfa_ok                             @ restore value
    and r3, r2, #0xFB                       @ ENPKH cleared (v2.05 0x0800A86C)
    cmp r0, r3
    beq .Lfa_ok
.Lfa_refuse:
    movs r0, #0
    pop {r4, pc}
.Lfa_ok:
    movs r0, #1
    pop {r4, pc}
    .ltorg
ENDFUNC hy_frame_allowed

@ -----------------------------------------------------------------------------
@ hy_write_frame - write bytes to consecutive HY3131 registers (checked)
@ Replaces : 0x0800C03C hy3131_write_regs (v2.05; the checks are new, the bus sequence is v2.05's)
@ In       : r0 = first register, r1 = pointer to the data bytes, r2 = byte count
@ Out      : r0 = 0 frame sent, 1 refused (no pin touched, hy_refused_count incremented)
@ Clobbers : r0-r3, r12, flags (r4-r8 preserved)
@ Context  : main only
@ RAM      : none directly
@ Spec     : analysis/hy3131_model.md 1.2; DESIGN.md 4.1 items 4 and 9
@ Deviation: NF-15, HW-05
@ Bus sequence (v2.05 0x0800C046..0x0800C0AA): DI high, CK low, CS low, delay(10), address byte (register << 1, R/W = 0,
@ no extra clock), delay(10), then per data byte: byte, delay(10); finally CS high.
@ -----------------------------------------------------------------------------
FUNC hy_write_frame
    push {r4, r5, r6, r7, r8, lr}
    movs r4, r0                             @ r4 = first register
    movs r5, r1                             @ r5 = data pointer
    movs r6, r2                             @ r6 = byte count
    bl hy_frame_allowed                     @ r0..r2 still hold the three arguments
    cbnz r0, .Lwf_send
    bl hy_note_refusal                      @ unlisted frame: count it and touch no pin
    movs r0, #1
    pop {r4, r5, r6, r7, r8, pc}
.Lwf_send:
    movs r0, #HY_PIN_DI
    ldr r1, =(GPIOF_BASE + GPIO_BSRRL)
    strh r0, [r1]                           @ PF2 (DI) high (v2.05 0x0800C046)
    movs r0, #HY_PIN_CK
    ldr r1, =(GPIOF_BASE + GPIO_BSRRH)
    strh r0, [r1]                           @ PF0 (CK) low
    movs r0, #HY_PIN_CS
    ldr r1, =(GPIOF_BASE + GPIO_BSRRH)
    strh r0, [r1]                           @ PF1 (CS) low: frame starts
    movs r0, #10
    bl fn_0800ECF6                          @ delay(10)
    lsls r7, r4, #1                         @ address byte: register << 1, R/W bit 0 = write (DS p14)
    movs r1, #0                             @ no extra clock for a write header
    uxtb r0, r7
    bl hy3131_spi_write_byte
    movs r0, #10
    bl fn_0800ECF6                          @ delay(10)
    movs r0, #0
    mov r8, r0                              @ r8 = data byte index
.Lwf_loop:
    cmp r8, r6
    bhs .Lwf_done                           @ all bytes sent
    ldrb.w r0, [r5, r8]                     @ data byte
    movs r1, #0
    bl hy3131_spi_write_byte
    movs r0, #10
    bl fn_0800ECF6                          @ delay(10) after each byte
    add.w r8, r8, #1
    b .Lwf_loop
.Lwf_done:
    movs r0, #HY_PIN_CS
    ldr r1, =(GPIOF_BASE + GPIO_BSRRL)
    strh r0, [r1]                           @ PF1 (CS) high: frame ends (v2.05 0x0800C0A4)
    movs r0, #0
    pop {r4, r5, r6, r7, r8, pc}
    .ltorg
ENDFUNC hy_write_frame

@ -----------------------------------------------------------------------------
@ hy3131_write_regs - v2.05 entry of the HY3131 register write (checked)
@ Replaces : 0x0800C03C hy3131_write_regs (v2.05)
@ In       : r0 = pointer to the data bytes, r1 = first register, r2 = byte count
@ Out      : r0 = 0 sent, 1 refused (v2.05 returns nothing; callers ignore r0)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : none directly
@ Spec     : DESIGN.md 4.1 item 4, Appendix C.1 (internal to HY; MAC uses hy_peak_restart)
@ Deviation: NF-15
@ Swaps r0 and r1 and continues in hy_write_frame (tail call), so every HY3131 write goes through the frame check.
@ -----------------------------------------------------------------------------
FUNC hy3131_write_regs
    movs r3, r0                             @ r3 = data pointer
    movs r0, r1                             @ r0 = first register
    movs r1, r3                             @ r1 = data pointer
    b hy_write_frame
ENDFUNC hy3131_write_regs

@ -----------------------------------------------------------------------------
@ hy_read_frame - read consecutive HY3131 registers into the register mirror
@ Replaces : 0x0800C0C0 hy3131_read_regs_to_rxbuf (v2.05; the destination and the bounds check are new)
@ In       : r0 = first register, r1 = byte count
@ Out      : r0 = 0 read, 1 refused (count 0, or first + count beyond the 52-byte mirror; nothing sent)
@ Clobbers : r0-r3, r12, flags (r4-r8 preserved)
@ Context  : main only
@ RAM      : none directly
@ Spec     : analysis/hy3131_model.md 1.2; DESIGN.md 6.13 (read sets)
@ Deviation: IMP-06 (reads land at the register's own mirror position; v2.05 stored at index 0 whatever the register,
@            0x0800C112, which put the counter read-back 0x1B..0x1D over the AD1 bytes rx[0..2])
@ Bus sequence (v2.05 0x0800C0CA..0x0800C12E): DI high, CK low, CS low, delay(5), address byte (register << 1 | 1) with
@ one extra clock (the read period of DS p14), delay(5), per byte: read byte, store, delay(2); finally CS high.
@ -----------------------------------------------------------------------------
FUNC hy_read_frame
    push {r4, r5, r6, r7, r8, lr}
    movs r4, r0                             @ r4 = first register
    movs r5, r1                             @ r5 = byte count
    cbz r5, .Lrf_refuse                     @ nothing to read
    adds r2, r4, r5
    cmp r2, #HY_MIRROR_SIZE
    bhi .Lrf_refuse                         @ would run past the mirror (registers above 0x33 have no mirror byte)
    movs r0, #HY_PIN_DI
    ldr r1, =(GPIOF_BASE + GPIO_BSRRL)
    strh r0, [r1]                           @ PF2 (DI) high (v2.05 0x0800C0CA)
    movs r0, #HY_PIN_CK
    ldr r1, =(GPIOF_BASE + GPIO_BSRRH)
    strh r0, [r1]                           @ PF0 (CK) low
    movs r0, #HY_PIN_CS
    ldr r1, =(GPIOF_BASE + GPIO_BSRRH)
    strh r0, [r1]                           @ PF1 (CS) low: frame starts
    movs r0, #5
    bl fn_0800ECF6                          @ delay(5)
    lsls r0, r4, #1
    orr r0, r0, #1                          @ address byte: register << 1 | 1 = read (DS p14)
    uxtb r0, r0
    movs r1, #1                             @ extra clock: the "SPI read period" before the data (DS p14)
    bl hy3131_spi_write_byte
    movs r0, #5
    bl fn_0800ECF6                          @ delay(5)
    movs r6, #0                             @ r6 = byte index
.Lrf_loop:
    cmp r6, r5
    bhs .Lrf_done
    bl hy3131_spi_read_byte                 @ r0 = register value
    ldr r1, =adc_regs
    adds r1, r1, r4                         @ mirror position of the first register
    strb r0, [r1, r6]                       @ mirror[first + index]
    movs r0, #2
    bl fn_0800ECF6                          @ delay(2) between bytes
    adds r6, #1
    b .Lrf_loop
.Lrf_done:
    movs r0, #HY_PIN_CS
    ldr r1, =(GPIOF_BASE + GPIO_BSRRL)
    strh r0, [r1]                           @ PF1 (CS) high: frame ends
    movs r0, #0
    pop {r4, r5, r6, r7, r8, pc}
.Lrf_refuse:
    bl hy_note_refusal
    movs r0, #1
    pop {r4, r5, r6, r7, r8, pc}
    .ltorg
ENDFUNC hy_read_frame

@ -----------------------------------------------------------------------------
@ hy3131_read_regs_to_rxbuf - v2.05 entry of the HY3131 register read
@ Replaces : 0x0800C0C0 hy3131_read_regs_to_rxbuf (v2.05)
@ In       : r0 = buffer (ignored, as in v2.05: the mirror adc_regs is used), r1 = first register, r2 = byte count
@ Out      : r0 = 0 read, 1 refused
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : none directly
@ Spec     : DESIGN.md 6.13
@ Deviation: IMP-06 (destination = mirror position of the register)
@ -----------------------------------------------------------------------------
FUNC hy3131_read_regs_to_rxbuf
    movs r0, r1                             @ r0 = first register
    movs r1, r2                             @ r1 = byte count
    b hy_read_frame
ENDFUNC hy3131_read_regs_to_rxbuf

@ -----------------------------------------------------------------------------
@ Read-only tables of the run-time whitelist
@ -----------------------------------------------------------------------------
    .equ HY_SHAPE_COUNT, 6
    .equ HY_TABLE_COUNT, 15

    .section .rodata.hy.spi, "a", %progbits
    .balign 4
@ {first register, byte count} of the six frame shapes v2.05 sends (DESIGN.md 4.1 table of call sites)
hy_write_shapes:
    .byte 0x20, 20                          @ configuration row            0x0800BE94
    .byte 0x1E, 2                           @ INTF = 0, INTE               0x0800BF74
    .byte 0x1E, 1                           @ INTF acknowledge (OF-53)     0x0800616C
    .byte 0x20, 1                           @ R20 counter restart          0x0800BFC6, 0x0800C036
    .byte 0x1B, 3                           @ counter preset CTA           0x0800BFF0
    .byte 0x29, 1                           @ R29 peak restart             0x0800A872, 0x0800A88C

    .balign 4
@ the 15 row tables of hy_rows.s, first row of each
hy_row_tables:
    .word v205_tab_080285BC, v205_tab_080286D0, v205_tab_08028748, v205_tab_080288A0, v205_tab_08028904
    .word v205_tab_080289C8, v205_tab_08028D1C, v205_tab_08028D58, v205_tab_08028D94, v205_tab_08028F1C
    .word v205_tab_08028F44, v205_tab_08028F6C, v205_tab_08028F94, v205_tab_08028FBC, v205_tab_08029150
@ number of 20-byte rows in each table above (table size / 20, hy_rows.s)
hy_row_counts:
    .byte 7, 6, 6, 5, 5, 4, 3, 3, 3, 2, 2, 2, 2, 2, 1

    .balign 4
@ The two rows v2.05 derives from a table row at run time (hy3131_load_config_regs):
@  1. LowZ AC: row 3 of 0x080289C8 with byte 10 |= 0x20 and byte 14 = (byte 14 & 0x7F) | 0x20 (0x0800BA58..0x0800BA86)
@  2. OHM range 6 with 0x20007FE0 set: row 6 of 0x080285BC with byte 10 &= 0xF7 (0x0800BE78..0x0800BE80)
hy_row_variants:
    .byte 0xF6, 0xDD, 0x00, 0x83, 0xF5, 0x41, 0x02, 0x4D, 0x31, 0x01, 0x20, 0x00, 0x09, 0x00, 0x28, 0xB0, 0x80, 0xC0, 0x38, 0x2C
    .byte 0x00, 0x00, 0x14, 0x93, 0x85, 0x00, 0x00, 0x00, 0x55, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x86, 0x80, 0xD1, 0x00, 0xAC
