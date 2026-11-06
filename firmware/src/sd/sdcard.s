@ sdcard.s - SD module: the SD memory card protocol on the SDIO host (DESIGN.md 6.23, W8)
@
@ Equivalent to the STM32 SDIO SD card driver (initialisation, card identification, single block read, block write with
@ DMA, status polling); the ST function names appear in comments for orientation.  Source of the protocol: SD Physical Layer
@ Simplified Specification Version 2.00 (PLS 2.00), the same document emulator/emu/sdcard.py implements.
@
@ Command sequence of a bring-up (sd_init): CMD0, CMD8 (0x1AA), CMD55/ACMD41 until the card is ready, CMD2 (CID), CMD3 (RCA),
@ CMD9 (CSD), then the host clock is raised (sdio_init, ClockDiv 1: CLKCR = 0x0101, 8 MHz from the 24 MHz SDIO clock in the
@ emulator), CMD7 (select), the card information is decoded, and sd_set_bus_width(0) sets the 1-bit bus (CMD55 + ACMD6 with 0).
@ Read: CMD16 512, CMD17.  Write: CMD16 512, CMD55, ACMD23 (one block), CMD25, DMA, CMD12.  After every transfer CMD13 is polled.
@
@ Error codes returned by the sd_cmd_* routines (ST driver SD_Error): 0 ok, 1 command CRC fail, 3 command timeout, 4 data timeout,
@ 7 start bit error, 9..26 the R1 card status error bits (9 address misaligned, 10 block length, 11 erase sequence, 12 bad erase
@ parameter, 13 write protect violation, 14 lock/unlock failed, 15 command CRC, 16 illegal command, 17 card ECC failed, 18 card
@ controller error, 19 general error, 20 stream read underrun, 21 stream write overrun, 22 CID/CSD overwrite, 23 write protect
@ erase skip, 24 card ECC disabled, 25 erase reset, 26 AKE sequence error, 28 address out of range), 0x10 response command
@ index mismatch, 0x1B invalid voltage range, 0x25 unsupported feature, 0x26 invalid parameter, 0x27 request not applicable.
@

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.sd, "ax", %progbits

@ names of the v2.05 variables used in this file (addresses unchanged, DESIGN.md 5.1)
    .equ SD_CLKDIV_FULL,          1                     @ ClockDiv of the data transfers: SDIO_CK = SDIOCLK / (ClockDiv + 2)
                                                        @ (v2.05: 1, 8 MHz from SDIOCLK 24 MHz; IMP-41: 16 MHz from 48 MHz)
    .equ SD_WRITE_TICKS,          60                    @ IMP-33: write wait 600 ms (10 ms ticks): above the SD write timeout of
                                                                @ 250 ms (SDSC/SDHC) / 500 ms (SDXC), Physical Layer 4.6.2.2
    .equ SD_WRITE_POLLS,          800000                @ backstop when the tick counter does not run (about 0.8 s at 32 MHz, IMP-41)
    .equ sd_card_info,            v_20007698            @ 0x20007698 card information record (0x58 bytes, filled by sd_get_card_info): CSD fields from +0, CID fields from +0x2C, capacity (u64) +0x48, block size +0x50, RCA (u16) +0x54, card type +0x56
    .equ sdio_init_struct,        v_20007B50            @ 0x20007B50 SDIO host configuration being built (6 words: ClockEdge, ClockBypass, ClockPowerSave, BusWide, HardwareFlowControl, ClockDiv in the byte at +0x14)
    .equ sdio_data_struct,        v_20007B68            @ 0x20007B68 data path configuration (DataTimeOut, DataLength, DataBlockSize, TransferDir, TransferMode, DPSM)
    .equ sdio_cmd_struct,         v_20007BBC            @ 0x20007BBC command configuration (Argument, CmdIndex, Response, WaitForInt, CPSM)
    .equ sd_csd,                  v_20007BF0            @ 0x20007BF0 CSD register of the card (4 words, word 0 = bits 127..96)
    .equ sd_cid,                  v_20007C00            @ 0x20007C00 CID register of the card (4 words)
    .equ sd_card_type,            v_20007EE8            @ 0x20007EE8 0 SD V1.1, 1 SD V2.0, 2 SDHC, 3 MMC, 4 SDIO, 5 high speed MMC, 6 SDIO combo, 7 high capacity MMC
    .equ sd_rca,                  v_20007EEC            @ 0x20007EEC relative card address << 16 (u32, as the command argument form)
    .equ sd_stop_condition,       v_20007EF0            @ 0x20007EF0 1 = the running transfer is a multi-block write that needs CMD12; 0 = single block read
    .equ sd_transfer_end,         v_20007EF4            @ 0x20007EF4 set to 1 by the SDIO interrupt at the end of the data transfer
    .equ sd_dma_end,              v_20007EF8            @ 0x20007EF8 set to 1 by the DMA interrupt when the DMA transfer is complete
    .equ sd_wait_count,           v_20007EFC            @ 0x20007EFC countdown of the wait loops of sd_wait_write
    .equ sd_transfer_error,       v_200080F7            @ 0x200080F7 error code set by the SDIO interrupt (0 none, 2 CRC fail, 4 timeout, 5 TX underrun, 6 RX overrun, 7 start bit error)

@ -----------------------------------------------------------------------------
@ sd_init - bring the SD card up and select it (ST SD_Init)
@ Replaces  : 0x080225D8 FUN_080225D8 (v2.05), called by sd_probe_mount and disk_initialize
@ In        : -
@ Out       : r0 = 0 ok, else the SD error code of the failing step
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only; SYSCLK must be HSE (the caller did sys_clock_select(1))
@ Spec      : v2.05 listing 0x080225D8..0x08022689
@ Note      : sequence: sdio_gpio_init (pins, clocks), sdio_reset, sd_power_on, sd_init_cards, host clock to full speed (sdio_init with
@             ClockDiv 1), sd_get_card_info, sd_select_deselect (CMD7 with the card's RCA), sd_set_bus_width(0).  The first failure ends
@             the sequence with its code.
@ -----------------------------------------------------------------------------
FUNC sd_init
    push    {r7, lr}                        @ 080225D8 push {r7, lr}
    movs    r0, #0                          @ 080225DA r0 = 0
    strb.w  r0, [sp]                        @ 080225DC u8 [sp] = r0
    @ pins and clocks of the SDIO block, then a reset of the block
    bl      sdio_gpio_init                  @ 080225E0 call sdio_gpio_init
    bl      sdio_reset                      @ 080225E4 call sdio_reset
    @ power up the card (CMD0, CMD8, ACMD41 loop)
    bl      sd_power_on                     @ 080225E8 call sd_power_on
    strb.w  r0, [sp]                        @ 080225EC u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 080225F0 r0 = u8 [sp]
    cmp     r0, #0                          @ 080225F4 compare r0 with 0
    beq     .Lsd_init_25FE                  @ 080225F6 if (r0 == 0) goto 0x80225FE
    ldrb.w  r0, [sp]                        @ 080225F8 r0 = u8 [sp]
    b       .Lsd_init_2688                  @ 080225FC goto 0x8022688
    @ card identification and RCA (CMD2, CMD3, CSD)
.Lsd_init_25FE:                         @ v2.05 0x080225FE, reached from 0x080225F6
    bl      sd_init_cards                   @ 080225FE call sd_init_cards
    strb.w  r0, [sp]                        @ 08022602 u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 08022606 r0 = u8 [sp]
    cmp     r0, #0                          @ 0802260A compare r0 with 0
    beq     .Lsd_init_2614                  @ 0802260C if (r0 == 0) goto 0x8022614
    ldrb.w  r0, [sp]                        @ 0802260E r0 = u8 [sp]
    b       .Lsd_init_2688                  @ 08022612 goto 0x8022688
    @ full speed: the SDIO_InitTypeDef is built at 0x20007B50 and written by sdio_init (CLKCR = 0x0101)
.Lsd_init_2614:                         @ v2.05 0x08022614, reached from 0x0802260C
    movs    r0, #SD_CLKDIV_FULL             @ 08022614 v2.05: 1 (SDIO_CK = SDIOCLK / 3)
    ldr.w   r1, =sdio_init_struct           @ 08022616 r1 = &sdio_init_struct
    strb    r0, [r1, #0x14]                 @ 0802261A u8 [sdio_init_struct+0x14] = r0
    movs    r0, #0                          @ 0802261C r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 0802261E r1 = &sdio_init_struct
    str     r0, [r1]                        @ 08022622 u32 [sdio_init_struct] = r0
    movs    r0, #0                          @ 08022624 r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 08022626 r1 = &sdio_init_struct
    str     r0, [r1, #4]                    @ 0802262A u32 [sdio_init_struct+0x4] = r0
    movs    r0, #0                          @ 0802262C r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 0802262E r1 = &sdio_init_struct
    str     r0, [r1, #8]                    @ 08022632 u32 [sdio_init_struct+0x8] = r0
    movs    r0, #0                          @ 08022634 r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 08022636 r1 = &sdio_init_struct
    str     r0, [r1, #0xc]                  @ 0802263A u32 [sdio_init_struct+0xC] = r0
    movs    r0, #0                          @ 0802263C r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 0802263E r1 = &sdio_init_struct
    str     r0, [r1, #0x10]                 @ 08022642 u32 [sdio_init_struct+0x10] = r0
    ldr.w   r0, =sdio_init_struct           @ 08022644 r0 = &sdio_init_struct
    bl      sdio_init                       @ 08022648 call sdio_init
    ldr.w   r0, =sd_card_info               @ 0802264C r0 = &sd_card_info
    @ decode CID and CSD into sd_card_info
    bl      sd_get_card_info                @ 08022650 call sd_get_card_info
    strb.w  r0, [sp]                        @ 08022654 u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 08022658 r0 = u8 [sp]
    cmp     r0, #0                          @ 0802265C compare r0 with 0
    bne     .Lsd_init_2672                  @ 0802265E if (r0 != 0) goto 0x8022672
    ldr.w   r0, =sd_card_info               @ 08022660 r0 = &sd_card_info
    ldrh.w  r0, [r0, #0x54]                 @ 08022664 r0 = u16 [sd_card_info+0x54]
    lsls    r0, r0, #0x10                   @ 08022668 r0 = r0 << 0x10
    @ select the card (CMD7)
    bl      sd_select_deselect              @ 0802266A call sd_select_deselect
    strb.w  r0, [sp]                        @ 0802266E u8 [sp] = r0
.Lsd_init_2672:                         @ v2.05 0x08022672, reached from 0x0802265E
    ldrb.w  r0, [sp]                        @ 08022672 r0 = u8 [sp]
    cmp     r0, #0                          @ 08022676 compare r0 with 0
    bne     .Lsd_init_2684                  @ 08022678 if (r0 != 0) goto 0x8022684
    movs    r0, #0                          @ 0802267A r0 = 0
    @ 1-bit bus width (sd_set_bus_width(0))
    bl      sd_set_bus_width                @ 0802267C call sd_set_bus_width
    strb.w  r0, [sp]                        @ 08022680 u8 [sp] = r0
.Lsd_init_2684:                         @ v2.05 0x08022684, reached from 0x08022678
    ldrb.w  r0, [sp]                        @ 08022684 r0 = u8 [sp]
.Lsd_init_2688:                         @ v2.05 0x08022688, reached from 0x080225FC, 0x08022612
    pop     {r1, pc}                        @ 08022688 pop {r1, pc}
ENDFUNC sd_init
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_power_on - power up the card and wait for it to become ready (ST SD_PowerON)
@ Replaces  : 0x080226E6 FUN_080226E6 (v2.05), called by sd_init
@ In        : -
@ Out       : r0 = 0 ok, 0x1B invalid voltage range (no answer to ACMD41 after 0xFFFF tries), or the SD error of a command
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : writes sd_card_type 0x20007EE8 (1 after a valid CMD8 answer, 2 when the card reports high capacity in its OCR),
@             the SDIO configuration structures
@ Spec      : v2.05 listing 0x080226E6..0x08022931; PLS 2.00 4.2 (card initialisation), 4.3.13 (ACMD41)
@ Note      : SDIO host: ClockDiv 0x76, power state 3 (on), clock enabled (CLKCR = 0x0176: SDIO_CK = SDIOCLK / 120, 200 kHz with the
@             24 MHz SDIOCLK of the emulator, 400 kHz with 48 MHz).  CMD0 (go idle), CMD8 with 0x1AA (voltage 2.7-3.6 V, check
@             pattern 0xAA): a valid R7 answer marks a version 2.00 card (sd_card_type = 1 and the HCS bit 30 is set in the ACMD41
@             argument); otherwise CMD55 is sent once (version 1.x or MMC).  The loop CMD55 (RCA 0), ACMD41 with 0x80100000 | HCS runs
@             until the busy bit 31 of the answer is set or 0xFFFF tries are used up; bit 30 (CCS) of the last answer sets sd_card_type
@             = 2 (SDHC, block addressing).
@ -----------------------------------------------------------------------------
FUNC sd_power_on
    push    {r3, r4, r5, r6, r7, lr}        @ 080226E6 push {r3, r4, r5, r6, r7, lr}
    movs    r0, #0                          @ 080226E8 r0 = 0
    strb.w  r0, [sp]                        @ 080226EA u8 [sp] = r0
    movs    r4, #0                          @ 080226EE r4 = 0
    movs    r5, #0                          @ 080226F0 r5 = 0
    movs    r6, #0                          @ 080226F2 r6 = 0
    movs    r7, #0                          @ 080226F4 r7 = 0
    @ SDIO host configuration: ClockDiv 0x76, no edge/bypass/powersave, 1-bit bus, no flow control (sdio_init_struct)
    movs    r0, #0x76                       @ 080226F6 r0 = 0x76
    ldr.w   r1, =sdio_init_struct           @ 080226F8 r1 = &sdio_init_struct
    strb    r0, [r1, #0x14]                 @ 080226FC u8 [sdio_init_struct+0x14] = r0
    movs    r0, #0                          @ 080226FE r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 08022700 r1 = &sdio_init_struct
    str     r0, [r1]                        @ 08022704 u32 [sdio_init_struct] = r0
    movs    r0, #0                          @ 08022706 r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 08022708 r1 = &sdio_init_struct
    str     r0, [r1, #4]                    @ 0802270C u32 [sdio_init_struct+0x4] = r0
    movs    r0, #0                          @ 0802270E r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 08022710 r1 = &sdio_init_struct
    str     r0, [r1, #8]                    @ 08022714 u32 [sdio_init_struct+0x8] = r0
    movs    r0, #0                          @ 08022716 r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 08022718 r1 = &sdio_init_struct
    str     r0, [r1, #0xc]                  @ 0802271C u32 [sdio_init_struct+0xC] = r0
    movs    r0, #0                          @ 0802271E r0 = 0
    ldr.w   r1, =sdio_init_struct           @ 08022720 r1 = &sdio_init_struct
    str     r0, [r1, #0x10]                 @ 08022724 u32 [sdio_init_struct+0x10] = r0
    ldr.w   r0, =sdio_init_struct           @ 08022726 r0 = &sdio_init_struct
    bl      sdio_init                       @ 0802272A call sdio_init
    @ power state 3 = on; clock enabled
    movs    r0, #3                          @ 0802272E r0 = 3
    bl      sdio_set_power_state            @ 08022730 call sdio_set_power_state
    movs    r0, #1                          @ 08022734 r0 = 1
    bl      sdio_clock_cmd                  @ 08022736 call sdio_clock_cmd
    movs    r0, #0                          @ 0802273A r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 0802273C r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08022740 u32 [sdio_cmd_struct] = r0
    movs    r0, #0                          @ 08022742 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08022744 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08022748 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0                          @ 0802274A r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 0802274C r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08022750 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08022752 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08022754 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08022758 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 0802275A r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 0802275E r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08022762 u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08022764 r0 = &sdio_cmd_struct
    @ CMD0 (GO_IDLE_STATE): argument 0, no answer; sd_cmd_error waits for CMDSENT (error 3 on timeout)
    bl      sdio_send_command               @ 08022768 call sdio_send_command
    bl      sd_cmd_error                    @ 0802276C call sd_cmd_error
    strb.w  r0, [sp]                        @ 08022770 u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 08022774 r0 = u8 [sp]
    cmp     r0, #0                          @ 08022778 compare r0 with 0
    beq     .Lsd_power_on_2782              @ 0802277A if (r0 == 0) goto 0x8022782
    ldrb.w  r0, [sp]                        @ 0802277C r0 = u8 [sp]
    b       .Lsd_power_on_2930              @ 08022780 goto 0x8022930
    @ CMD8 with argument 0x1AA (index 8, short answer R7)
.Lsd_power_on_2782:                     @ v2.05 0x08022782, reached from 0x0802277A
    mov.w   r0, #0x1aa                      @ 08022782 r0 = 0x1aa
    ldr.w   r1, =sdio_cmd_struct            @ 08022786 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 0802278A u32 [sdio_cmd_struct] = r0
    movs    r0, #8                          @ 0802278C r0 = 8
    ldr.w   r1, =sdio_cmd_struct            @ 0802278E r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08022792 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08022794 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 08022796 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 0802279A u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 0802279C r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 0802279E r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 080227A2 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 080227A4 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 080227A8 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 080227AC u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 080227AE r0 = &sdio_cmd_struct
    bl      sdio_send_command               @ 080227B2 call sdio_send_command
    bl      sd_cmd_resp7_error              @ 080227B6 call sd_cmd_resp7_error
    strb.w  r0, [sp]                        @ 080227BA u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 080227BE r0 = u8 [sp]
    cmp     r0, #0                          @ 080227C2 compare r0 with 0
    bne     .Lsd_power_on_27D6              @ 080227C4 if (r0 != 0) goto 0x80227D6
    @ valid R7: sd_card_type = 1 (version 2.00 card), r7 = HCS 0x40000000
    movs    r0, #1                          @ 080227C6 r0 = 1
    ldr.w   r1, =sd_card_type               @ 080227C8 r1 = &sd_card_type
    str     r0, [r1]                        @ 080227CC u32 [sd_card_type] = r0
    movs.w  r0, #0x40000000                 @ 080227CE r0 = 0x40000000
    movs    r7, r0                          @ 080227D2 r7 = r0
    b       .Lsd_power_on_2812              @ 080227D4 goto 0x8022812
    @ no valid R7: CMD55 (index 0x37) with argument 0 as a check for a version 1.x card
.Lsd_power_on_27D6:                     @ v2.05 0x080227D6, reached from 0x080227C4
    movs    r0, #0                          @ 080227D6 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 080227D8 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 080227DC u32 [sdio_cmd_struct] = r0
    movs    r0, #0x37                       @ 080227DE r0 = 0x37
    ldr.w   r1, =sdio_cmd_struct            @ 080227E0 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 080227E4 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 080227E6 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 080227E8 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 080227EC u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 080227EE r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 080227F0 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 080227F4 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 080227F6 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 080227FA r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 080227FE u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08022800 r0 = &sdio_cmd_struct
    bl      sdio_send_command               @ 08022804 call sdio_send_command
    movs    r0, #0x37                       @ 08022808 r0 = 0x37
    bl      sd_cmd_resp1_error              @ 0802280A call sd_cmd_resp1_error
    strb.w  r0, [sp]                        @ 0802280E u8 [sp] = r0
    @ CMD55 again (RCA 0); a failure ends the routine with its code
.Lsd_power_on_2812:                     @ v2.05 0x08022812, reached from 0x080227D4
    movs    r0, #0                          @ 08022812 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08022814 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08022818 u32 [sdio_cmd_struct] = r0
    movs    r0, #0x37                       @ 0802281A r0 = 0x37
    ldr.w   r1, =sdio_cmd_struct            @ 0802281C r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08022820 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08022822 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 08022824 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08022828 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 0802282A r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 0802282C r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08022830 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08022832 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08022836 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 0802283A u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 0802283C r0 = &sdio_cmd_struct
    bl      sdio_send_command               @ 08022840 call sdio_send_command
    movs    r0, #0x37                       @ 08022844 r0 = 0x37
    bl      sd_cmd_resp1_error              @ 08022846 call sd_cmd_resp1_error
    strb.w  r0, [sp]                        @ 0802284A u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 0802284E r0 = u8 [sp]
    cmp     r0, #0                          @ 08022852 compare r0 with 0
    bne     .Lsd_power_on_292C              @ 08022854 if (r0 != 0) goto 0x802292C
    @ loop while the card is busy (r6 = 0) and fewer than 0xFFFF tries (r5)
.Lsd_power_on_2856:                     @ v2.05 0x08022856, reached from 0x08022906
    cmp     r6, #0                          @ 08022856 compare r6 with 0
    bne     .Lsd_power_on_2908              @ 08022858 if (r6 != 0) goto 0x8022908
    movw    r0, #0xffff                     @ 0802285A
    cmp     r5, r0                          @ 0802285E compare r5 with r0
    bhs     .Lsd_power_on_2908              @ 08022860 if (r5 >=u r0) goto 0x8022908
    movs    r0, #0                          @ 08022862 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08022864 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08022868 u32 [sdio_cmd_struct] = r0
    movs    r0, #0x37                       @ 0802286A r0 = 0x37
    ldr.w   r1, =sdio_cmd_struct            @ 0802286C r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08022870 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08022872 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 08022874 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08022878 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 0802287A r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 0802287C r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08022880 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08022882 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08022886 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 0802288A u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 0802288C r0 = &sdio_cmd_struct
    @ CMD55 (RCA 0)
    bl      sdio_send_command               @ 08022890 call sdio_send_command
    movs    r0, #0x37                       @ 08022894 r0 = 0x37
    bl      sd_cmd_resp1_error              @ 08022896 call sd_cmd_resp1_error
    strb.w  r0, [sp]                        @ 0802289A u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 0802289E r0 = u8 [sp]
    cmp     r0, #0                          @ 080228A2 compare r0 with 0
    beq     .Lsd_power_on_28AC              @ 080228A4 if (r0 == 0) goto 0x80228AC
    ldrb.w  r0, [sp]                        @ 080228A6 r0 = u8 [sp]
    b       .Lsd_power_on_2930              @ 080228AA goto 0x8022930
    @ ACMD41 (index 0x29) with argument 0x80100000 | HCS; answer R3
.Lsd_power_on_28AC:                     @ v2.05 0x080228AC, reached from 0x080228A4
    ldr.w   r0, =0x80100000                 @ 080228AC r0 = 0x80100000
    orrs    r0, r7                          @ 080228B0 r0 |= r7
    ldr.w   r1, =sdio_cmd_struct            @ 080228B2 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 080228B6 u32 [sdio_cmd_struct] = r0
    movs    r0, #0x29                       @ 080228B8 r0 = 0x29
    ldr.w   r1, =sdio_cmd_struct            @ 080228BA r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 080228BE u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 080228C0 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 080228C2 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 080228C6 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 080228C8 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 080228CA r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 080228CE u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 080228D0 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 080228D4 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 080228D8 u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 080228DA r0 = &sdio_cmd_struct
    bl      sdio_send_command               @ 080228DE call sdio_send_command
    bl      sd_cmd_resp3_error              @ 080228E2 call sd_cmd_resp3_error
    strb.w  r0, [sp]                        @ 080228E6 u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 080228EA r0 = u8 [sp]
    cmp     r0, #0                          @ 080228EE compare r0 with 0
    beq     .Lsd_power_on_28F8              @ 080228F0 if (r0 == 0) goto 0x80228F8
    ldrb.w  r0, [sp]                        @ 080228F2 r0 = u8 [sp]
    b       .Lsd_power_on_2930              @ 080228F6 goto 0x8022930
.Lsd_power_on_28F8:                     @ v2.05 0x080228F8, reached from 0x080228F0
    movs    r0, #0                          @ 080228F8 r0 = 0
    @ r4 = answer (OCR); r6 = bit 31 (power-up complete)
    bl      sdio_get_response               @ 080228FA call sdio_get_response
    movs    r4, r0                          @ 080228FE r4 = r0
    lsrs    r0, r4, #0x1f                   @ 08022900 r0 = r4 >> 0x1f
    movs    r6, r0                          @ 08022902 r6 = r0
    adds    r5, r5, #1                      @ 08022904 r5 = r5 + 1
    b       .Lsd_power_on_2856              @ 08022906 goto 0x8022856
    @ tries used up: invalid voltage range (0x1B)
.Lsd_power_on_2908:                     @ v2.05 0x08022908, reached from 0x08022858, 0x08022860
    movw    r0, #0xffff                     @ 08022908
    cmp     r5, r0                          @ 0802290C compare r5 with r0
    blo     .Lsd_power_on_291C              @ 0802290E if (r5 <u r0) goto 0x802291C
    movs    r0, #0x1b                       @ 08022910 r0 = 0x1b
    strb.w  r0, [sp]                        @ 08022912 u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 08022916 r0 = u8 [sp]
    b       .Lsd_power_on_2930              @ 0802291A goto 0x8022930
    @ OCR bit 30 (CCS) set: sd_card_type = 2 (SDHC)
.Lsd_power_on_291C:                     @ v2.05 0x0802291C, reached from 0x0802290E
    ands    r4, r4, #0x40000000             @ 0802291C r4 = r4 & 0x40000000
    cmp     r4, #0                          @ 08022920 compare r4 with 0
    beq     .Lsd_power_on_292C              @ 08022922 if (r4 == 0) goto 0x802292C
    movs    r0, #2                          @ 08022924 r0 = 2
    ldr.w   r1, =sd_card_type               @ 08022926 r1 = &sd_card_type
    str     r0, [r1]                        @ 0802292A u32 [sd_card_type] = r0
.Lsd_power_on_292C:                     @ v2.05 0x0802292C, reached from 0x08022854, 0x08022922
    ldrb.w  r0, [sp]                        @ 0802292C r0 = u8 [sp]
.Lsd_power_on_2930:                     @ v2.05 0x08022930, reached from 0x08022780, 0x080228AA, 0x080228F6, 0x0802291A
    pop     {r1, r4, r5, r6, r7, pc}        @ 08022930 pop {r1, r4, r5, r6, r7, pc}
ENDFUNC sd_power_on
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_init_cards - read the CID, get the relative card address, read the CSD (ST SD_InitializeCards)
@ Replaces  : 0x08022942 FUN_08022942 (v2.05), called by sd_init
@ In        : -
@ Out       : r0 = 0 ok, 0x25 the SDIO block is not powered, or the SD error of a command
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads sd_card_type; writes sd_cid 0x20007C00 (4 words), sd_rca 0x20007EEC, sd_csd 0x20007BF0 (4 words)
@ Spec      : v2.05 listing 0x08022942..0x08022AE3; PLS 2.00 4.2.2
@ Note      : not for SDIO-only cards (type 4).  CMD2 (ALL_SEND_CID, R2), CMD3 (SEND_RELATIVE_ADDR, R6) for the SD types 0, 1, 2 and
@             6 -> RCA, CMD9 (SEND_CSD, R2) with the RCA as argument.
@ -----------------------------------------------------------------------------
FUNC sd_init_cards
    push    {r4, lr}                        @ 08022942 push {r4, lr}
    sub     sp, #8                          @ 08022944 sp -= 8
    movs    r4, #0                          @ 08022946 r4 = 0
    movs    r0, #1                          @ 08022948 r0 = 1
    strh.w  r0, [sp]                        @ 0802294A u16 [sp] = r0
    @ the SDIO block must be powered (power state non-zero)
    bl      sdio_get_power_state            @ 0802294E call sdio_get_power_state
    cmp     r0, #0                          @ 08022952 compare r0 with 0
    bne     .Lsd_init_cards_2960            @ 08022954 if (r0 != 0) goto 0x8022960
    movs    r0, #0x25                       @ 08022956 r0 = 0x25
    movs    r4, r0                          @ 08022958 r4 = r0
    movs    r0, r4                          @ 0802295A r0 = r4
    uxtb    r0, r0                          @ 0802295C r0 = u8(r0)
    b       .Lsd_init_cards_2AE2            @ 0802295E goto 0x8022AE2
.Lsd_init_cards_2960:                   @ v2.05 0x08022960, reached from 0x08022954
    ldr.w   r0, =sd_card_type               @ 08022960 r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08022964 r0 = u32 [sd_card_type]
    cmp     r0, #4                          @ 08022966 compare r0 with 4
    @ type 4 (SDIO card) skips the CID read
    beq     .Lsd_init_cards_29DE            @ 08022968 if (r0 == 4) goto 0x80229DE
    movs    r0, #0                          @ 0802296A r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 0802296C r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08022970 u32 [sdio_cmd_struct] = r0
    movs    r0, #2                          @ 08022972 r0 = 2
    ldr.w   r1, =sdio_cmd_struct            @ 08022974 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08022978 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0xc0                       @ 0802297A r0 = 0xc0
    ldr.w   r1, =sdio_cmd_struct            @ 0802297C r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08022980 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08022982 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08022984 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08022988 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 0802298A r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 0802298E r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08022992 u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08022994 r0 = &sdio_cmd_struct
    @ CMD2, answer R2 into sd_cid (four sdio_get_response calls)
    bl      sdio_send_command               @ 08022998 call sdio_send_command
    bl      sd_cmd_resp2_error              @ 0802299C call sd_cmd_resp2_error
    movs    r4, r0                          @ 080229A0 r4 = r0
    uxtb    r4, r4                          @ 080229A2 r4 = u8(r4)
    cmp     r4, #0                          @ 080229A4 compare r4 with 0
    beq     .Lsd_init_cards_29AE            @ 080229A6 if (r4 == 0) goto 0x80229AE
    movs    r0, r4                          @ 080229A8 r0 = r4
    uxtb    r0, r0                          @ 080229AA r0 = u8(r0)
    b       .Lsd_init_cards_2AE2            @ 080229AC goto 0x8022AE2
.Lsd_init_cards_29AE:                   @ v2.05 0x080229AE, reached from 0x080229A6
    movs    r0, #0                          @ 080229AE r0 = 0
    bl      sdio_get_response               @ 080229B0 call sdio_get_response
    ldr.w   r1, =sd_cid                     @ 080229B4 r1 = &sd_cid
    str     r0, [r1]                        @ 080229B8 u32 [sd_cid] = r0
    movs    r0, #4                          @ 080229BA r0 = 4
    bl      sdio_get_response               @ 080229BC call sdio_get_response
    ldr.w   r1, =sd_cid                     @ 080229C0 r1 = &sd_cid
    str     r0, [r1, #4]                    @ 080229C4 u32 [sd_cid+0x4] = r0
    movs    r0, #8                          @ 080229C6 r0 = 8
    bl      sdio_get_response               @ 080229C8 call sdio_get_response
    ldr.w   r1, =sd_cid                     @ 080229CC r1 = &sd_cid
    str     r0, [r1, #8]                    @ 080229D0 u32 [sd_cid+0x8] = r0
    movs    r0, #0xc                        @ 080229D2 r0 = 0xc
    bl      sdio_get_response               @ 080229D4 call sdio_get_response
    ldr.w   r1, =sd_cid                     @ 080229D8 r1 = &sd_cid
    str     r0, [r1, #0xc]                  @ 080229DC u32 [sd_cid+0xC] = r0
.Lsd_init_cards_29DE:                   @ v2.05 0x080229DE, reached from 0x08022968
    ldr.w   r0, =sd_card_type               @ 080229DE r0 = &sd_card_type
    ldr     r0, [r0]                        @ 080229E2 r0 = u32 [sd_card_type]
    @ card types 0, 1, 6, 2 get an RCA with CMD3
    cmp     r0, #0                          @ 080229E4 compare r0 with 0
    beq     .Lsd_init_cards_2A06            @ 080229E6 if (r0 == 0) goto 0x8022A06
    ldr.w   r0, =sd_card_type               @ 080229E8 r0 = &sd_card_type
    ldr     r0, [r0]                        @ 080229EC r0 = u32 [sd_card_type]
    cmp     r0, #1                          @ 080229EE compare r0 with 1
    beq     .Lsd_init_cards_2A06            @ 080229F0 if (r0 == 1) goto 0x8022A06
    ldr.w   r0, =sd_card_type               @ 080229F2 r0 = &sd_card_type
    ldr     r0, [r0]                        @ 080229F6 r0 = u32 [sd_card_type]
    cmp     r0, #6                          @ 080229F8 compare r0 with 6
    beq     .Lsd_init_cards_2A06            @ 080229FA if (r0 == 6) goto 0x8022A06
    ldr.w   r0, =sd_card_type               @ 080229FC r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08022A00 r0 = u32 [sd_card_type]
    cmp     r0, #2                          @ 08022A02 compare r0 with 2
    bne     .Lsd_init_cards_2A4E            @ 08022A04 if (r0 != 2) goto 0x8022A4E
.Lsd_init_cards_2A06:                   @ v2.05 0x08022A06, reached from 0x080229E6, 0x080229F0, 0x080229FA
    movs    r0, #0                          @ 08022A06 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08022A08 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08022A0C u32 [sdio_cmd_struct] = r0
    movs    r0, #3                          @ 08022A0E r0 = 3
    ldr.w   r1, =sdio_cmd_struct            @ 08022A10 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08022A14 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08022A16 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 08022A18 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08022A1C u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08022A1E r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08022A20 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08022A24 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08022A26 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08022A2A r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08022A2E u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08022A30 r0 = &sdio_cmd_struct
    @ CMD3 (R6): RCA = answer bits 31..16
    bl      sdio_send_command               @ 08022A34 call sdio_send_command
    mov     r1, sp                          @ 08022A38 r1 = sp
    movs    r0, #3                          @ 08022A3A r0 = 3
    bl      sd_cmd_resp6_error              @ 08022A3C call sd_cmd_resp6_error
    movs    r4, r0                          @ 08022A40 r4 = r0
    uxtb    r4, r4                          @ 08022A42 r4 = u8(r4)
    cmp     r4, #0                          @ 08022A44 compare r4 with 0
    beq     .Lsd_init_cards_2A4E            @ 08022A46 if (r4 == 0) goto 0x8022A4E
    movs    r0, r4                          @ 08022A48 r0 = r4
    uxtb    r0, r0                          @ 08022A4A r0 = u8(r0)
    b       .Lsd_init_cards_2AE2            @ 08022A4C goto 0x8022AE2
.Lsd_init_cards_2A4E:                   @ v2.05 0x08022A4E, reached from 0x08022A04, 0x08022A46
    ldr.w   r0, =sd_card_type               @ 08022A4E r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08022A52 r0 = u32 [sd_card_type]
    @ type 4 skips the CSD read
    cmp     r0, #4                          @ 08022A54 compare r0 with 4
    beq     .Lsd_init_cards_2ADA            @ 08022A56 if (r0 == 4) goto 0x8022ADA
    ldrh.w  r0, [sp]                        @ 08022A58 r0 = u16 [sp]
    ldr.w   r1, =sd_rca                     @ 08022A5C r1 = &sd_rca
    str     r0, [r1]                        @ 08022A60 u32 [sd_rca] = r0
    ldrh.w  r0, [sp]                        @ 08022A62 r0 = u16 [sp]
    lsls    r0, r0, #0x10                   @ 08022A66 r0 = r0 << 0x10
    ldr.w   r1, =sdio_cmd_struct            @ 08022A68 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08022A6C u32 [sdio_cmd_struct] = r0
    movs    r0, #9                          @ 08022A6E r0 = 9
    ldr.w   r1, =sdio_cmd_struct            @ 08022A70 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08022A74 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0xc0                       @ 08022A76 r0 = 0xc0
    ldr.w   r1, =sdio_cmd_struct            @ 08022A78 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08022A7C u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08022A7E r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08022A80 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08022A84 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08022A86 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08022A8A r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08022A8E u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08022A90 r0 = &sdio_cmd_struct
    @ CMD9 with the RCA, answer R2 into sd_csd
    bl      sdio_send_command               @ 08022A94 call sdio_send_command
    bl      sd_cmd_resp2_error              @ 08022A98 call sd_cmd_resp2_error
    movs    r4, r0                          @ 08022A9C r4 = r0
    uxtb    r4, r4                          @ 08022A9E r4 = u8(r4)
    cmp     r4, #0                          @ 08022AA0 compare r4 with 0
    beq     .Lsd_init_cards_2AAA            @ 08022AA2 if (r4 == 0) goto 0x8022AAA
    movs    r0, r4                          @ 08022AA4 r0 = r4
    uxtb    r0, r0                          @ 08022AA6 r0 = u8(r0)
    b       .Lsd_init_cards_2AE2            @ 08022AA8 goto 0x8022AE2
.Lsd_init_cards_2AAA:                   @ v2.05 0x08022AAA, reached from 0x08022AA2
    movs    r0, #0                          @ 08022AAA r0 = 0
    bl      sdio_get_response               @ 08022AAC call sdio_get_response
    ldr.w   r1, =sd_csd                     @ 08022AB0 r1 = &sd_csd
    str     r0, [r1]                        @ 08022AB4 u32 [sd_csd] = r0
    movs    r0, #4                          @ 08022AB6 r0 = 4
    bl      sdio_get_response               @ 08022AB8 call sdio_get_response
    ldr.w   r1, =sd_csd                     @ 08022ABC r1 = &sd_csd
    str     r0, [r1, #4]                    @ 08022AC0 u32 [sd_csd+0x4] = r0
    movs    r0, #8                          @ 08022AC2 r0 = 8
    bl      sdio_get_response               @ 08022AC4 call sdio_get_response
    ldr.w   r1, =sd_csd                     @ 08022AC8 r1 = &sd_csd
    str     r0, [r1, #8]                    @ 08022ACC u32 [sd_csd+0x8] = r0
    movs    r0, #0xc                        @ 08022ACE r0 = 0xc
    bl      sdio_get_response               @ 08022AD0 call sdio_get_response
    ldr.w   r1, =sd_csd                     @ 08022AD4 r1 = &sd_csd
    str     r0, [r1, #0xc]                  @ 08022AD8 u32 [sd_csd+0xC] = r0
.Lsd_init_cards_2ADA:                   @ v2.05 0x08022ADA, reached from 0x08022A56
    movs    r0, #0                          @ 08022ADA r0 = 0
    movs    r4, r0                          @ 08022ADC r4 = r0
    movs    r0, r4                          @ 08022ADE r0 = r4
    uxtb    r0, r0                          @ 08022AE0 r0 = u8(r0)
.Lsd_init_cards_2AE2:                   @ v2.05 0x08022AE2, reached from 0x0802295E, 0x080229AC, 0x08022A4C, 0x08022AA8
    pop     {r1, r2, r4, pc}                @ 08022AE2 pop {r1, r2, r4, pc}
ENDFUNC sd_init_cards
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_get_card_info - decode the CSD and CID registers into the card information record (ST SD_GetCardInfo)
@ Replaces  : 0x08022AE4 FUN_08022AE4 (v2.05), called by sd_init
@ In        : r0 = pointer to the card information record (sd_card_info, 0x58 bytes)
@ Out       : r0 = 0
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads sd_csd, sd_cid, sd_card_type, sd_rca; writes the record
@ Spec      : v2.05 listing 0x08022AE4..0x08022ECD; PLS 2.00 5.3 (CSD version 1.0 and 2.0 fields) and 5.2 (CID)
@ Note      : the record is the ST SD_CardInfo layout: the SD_CSD structure from +0 (CSDStruct, SysSpecVersion, TAAC, NSAC,
@             MaxBusClkFrec, CCC at +6, RdBlockLen +8, ..., DeviceSize +0x10, ...), the SD_CID structure from +0x2C (ManufacturerID,
@             OEM_AppliID +0x2E, ProdName +0x30/+0x34, ProdRev +0x35, ProdSN +0x38, ManufactDate +0x3E, CID_CRC +0x40), then CardCapacity
@             (u64 +0x48), CardBlockSize (+0x50), RCA (u16 +0x54), CardType (+0x56).  For card types 0 and 1 the capacity is
@             (DeviceSize + 1) * 2^(DeviceSizeMul + 2) * 2^RdBlockLen (64-bit multiplications) and the block size 2^RdBlockLen.
@             For type 2 (SDHC) DeviceSize is the 22-bit C_SIZE of the version 2.0 CSD, the capacity (C_SIZE + 1) * 0x80000 bytes and the
@             block size 0x200.  The fields are extracted from the four CSD words and four CID words with shifts and masks.
@ -----------------------------------------------------------------------------
FUNC sd_get_card_info
    @ card type and RCA first, then the CSD fields from the first CSD word (the record pointer is r1)
    push.w  {r4, r6, r7, r8, r9}            @ 08022AE4 push {r4, r6, r7, r8, r9}
    movs    r1, r0                          @ 08022AE8 r1 = r0
    movs    r0, #0                          @ 08022AEA r0 = 0
    movs    r4, #0                          @ 08022AEC r4 = 0
    ldr.w   r2, =sd_card_type               @ 08022AEE r2 = &sd_card_type
    ldr     r2, [r2]                        @ 08022AF2 r2 = u32 [sd_card_type]
    strb.w  r2, [r1, #0x56]                 @ 08022AF4 u8 [r1+0x56] = r2
    ldr.w   r2, =sd_rca                     @ 08022AF8 r2 = &sd_rca
    ldr     r2, [r2]                        @ 08022AFC r2 = u32 [sd_rca]
    strh.w  r2, [r1, #0x54]                 @ 08022AFE u16 [r1+0x54] = r2
    ldr.w   r2, =sd_csd                     @ 08022B02 r2 = &sd_csd
    ldr     r2, [r2]                        @ 08022B06 r2 = u32 [sd_csd]
    lsrs    r2, r2, #0x18                   @ 08022B08 r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022B0A r4 = r2
    movs    r2, r4                          @ 08022B0C r2 = r4
    uxtb    r2, r2                          @ 08022B0E r2 = u8(r2)
    lsrs    r2, r2, #6                      @ 08022B10 r2 = r2 >> 6
    strb    r2, [r1]                        @ 08022B12 u8 [r1] = r2
    ubfx    r2, r4, #2, #4                  @ 08022B14
    strb    r2, [r1, #1]                    @ 08022B18 u8 [r1+0x1] = r2
    ands    r2, r4, #3                      @ 08022B1A r2 = r4 & 3
    strb    r2, [r1, #2]                    @ 08022B1E u8 [r1+0x2] = r2
    ldr.w   r2, =sd_csd                     @ 08022B20 r2 = &sd_csd
    ldr     r2, [r2]                        @ 08022B24 r2 = u32 [sd_csd]
    lsrs    r2, r2, #0x10                   @ 08022B26 r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022B28 r4 = r2
    strb    r4, [r1, #3]                    @ 08022B2A u8 [r1+0x3] = r4
    ldr.w   r2, =sd_csd                     @ 08022B2C r2 = &sd_csd
    ldr     r2, [r2]                        @ 08022B30 r2 = u32 [sd_csd]
    lsrs    r2, r2, #8                      @ 08022B32 r2 = r2 >> 8
    movs    r4, r2                          @ 08022B34 r4 = r2
    strb    r4, [r1, #4]                    @ 08022B36 u8 [r1+0x4] = r4
    ldr.w   r2, =sd_csd                     @ 08022B38 r2 = &sd_csd
    ldr     r2, [r2]                        @ 08022B3C r2 = u32 [sd_csd]
    movs    r4, r2                          @ 08022B3E r4 = r2
    strb    r4, [r1, #5]                    @ 08022B40 u8 [r1+0x5] = r4
    ldr.w   r2, =sd_csd                     @ 08022B42 r2 = &sd_csd
    ldr     r2, [r2, #4]                    @ 08022B46 r2 = u32 [sd_csd+0x4]
    lsrs    r2, r2, #0x18                   @ 08022B48 r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022B4A r4 = r2
    uxtb    r4, r4                          @ 08022B4C r4 = u8(r4)
    lsls    r2, r4, #4                      @ 08022B4E r2 = r4 << 4
    strh    r2, [r1, #6]                    @ 08022B50 u16 [r1+0x6] = r2
    ldr.w   r2, =sd_csd                     @ 08022B52 r2 = &sd_csd
    ldr     r2, [r2, #4]                    @ 08022B56 r2 = u32 [sd_csd+0x4]
    lsrs    r2, r2, #0x10                   @ 08022B58 r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022B5A r4 = r2
    ldrh    r3, [r1, #6]                    @ 08022B5C r3 = u16 [r1+0x6]
    movs    r2, r4                          @ 08022B5E r2 = r4
    uxtb    r2, r2                          @ 08022B60 r2 = u8(r2)
    lsrs    r2, r2, #4                      @ 08022B62 r2 = r2 >> 4
    uxtb    r2, r2                          @ 08022B64 r2 = u8(r2)
    orrs    r2, r3                          @ 08022B66 r2 |= r3
    strh    r2, [r1, #6]                    @ 08022B68 u16 [r1+0x6] = r2
    ands    r2, r4, #0xf                    @ 08022B6A r2 = r4 & 0xf
    strb    r2, [r1, #8]                    @ 08022B6E u8 [r1+0x8] = r2
    ldr.w   r2, =sd_csd                     @ 08022B70 r2 = &sd_csd
    ldr     r2, [r2, #4]                    @ 08022B74 r2 = u32 [sd_csd+0x4]
    lsrs    r2, r2, #8                      @ 08022B76 r2 = r2 >> 8
    movs    r4, r2                          @ 08022B78 r4 = r2
    movs    r2, r4                          @ 08022B7A r2 = r4
    uxtb    r2, r2                          @ 08022B7C r2 = u8(r2)
    lsrs    r2, r2, #7                      @ 08022B7E r2 = r2 >> 7
    strb    r2, [r1, #9]                    @ 08022B80 u8 [r1+0x9] = r2
    ubfx    r2, r4, #6, #1                  @ 08022B82
    strb    r2, [r1, #0xa]                  @ 08022B86 u8 [r1+0xA] = r2
    ubfx    r2, r4, #5, #1                  @ 08022B88
    strb    r2, [r1, #0xb]                  @ 08022B8C u8 [r1+0xB] = r2
    ubfx    r2, r4, #4, #1                  @ 08022B8E
    strb    r2, [r1, #0xc]                  @ 08022B92 u8 [r1+0xC] = r2
    movs    r2, #0                          @ 08022B94 r2 = 0
    strb    r2, [r1, #0xd]                  @ 08022B96 u8 [r1+0xD] = r2
    ldr.w   r2, =sd_card_type               @ 08022B98 r2 = &sd_card_type
    ldr     r2, [r2]                        @ 08022B9C r2 = u32 [sd_card_type]
    cmp     r2, #0                          @ 08022B9E compare r2 with 0
    beq     .Lsd_get_card_info_2BAC         @ 08022BA0 if (r2 == 0) goto 0x8022BAC
    ldr.w   r2, =sd_card_type               @ 08022BA2 r2 = &sd_card_type
    ldr     r2, [r2]                        @ 08022BA6 r2 = u32 [sd_card_type]
    cmp     r2, #1                          @ 08022BA8 compare r2 with 1
    bne     .Lsd_get_card_info_2C6E         @ 08022BAA if (r2 != 1) goto 0x8022C6E
.Lsd_get_card_info_2BAC:                @ v2.05 0x08022BAC, reached from 0x08022BA0
    uxtb    r4, r4                          @ 08022BAC r4 = u8(r4)
    lsls    r2, r4, #0xa                    @ 08022BAE r2 = r4 << 0xa
    ands    r2, r2, #0xc00                  @ 08022BB0 r2 = r2 & 0xc00
    str     r2, [r1, #0x10]                 @ 08022BB4 u32 [r1+0x10] = r2
    ldr.w   r2, =sd_csd                     @ 08022BB6 r2 = &sd_csd
    ldr     r2, [r2, #4]                    @ 08022BBA r2 = u32 [sd_csd+0x4]
    movs    r4, r2                          @ 08022BBC r4 = r2
    ldr     r2, [r1, #0x10]                 @ 08022BBE r2 = u32 [r1+0x10]
    uxtb    r4, r4                          @ 08022BC0 r4 = u8(r4)
    orrs.w  r2, r2, r4, lsl #2              @ 08022BC2 r2 = r2 | r4, lsl #2
    str     r2, [r1, #0x10]                 @ 08022BC6 u32 [r1+0x10] = r2
    ldr.w   r2, =sd_csd                     @ 08022BC8 r2 = &sd_csd
    ldr     r2, [r2, #8]                    @ 08022BCC r2 = u32 [sd_csd+0x8]
    lsrs    r2, r2, #0x18                   @ 08022BCE r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022BD0 r4 = r2
    ldr     r3, [r1, #0x10]                 @ 08022BD2 r3 = u32 [r1+0x10]
    movs    r2, r4                          @ 08022BD4 r2 = r4
    uxtb    r2, r2                          @ 08022BD6 r2 = u8(r2)
    lsrs    r2, r2, #6                      @ 08022BD8 r2 = r2 >> 6
    uxtb    r2, r2                          @ 08022BDA r2 = u8(r2)
    orrs    r2, r3                          @ 08022BDC r2 |= r3
    str     r2, [r1, #0x10]                 @ 08022BDE u32 [r1+0x10] = r2
    ubfx    r2, r4, #3, #3                  @ 08022BE0
    strb    r2, [r1, #0x14]                 @ 08022BE4 u8 [r1+0x14] = r2
    ands    r2, r4, #7                      @ 08022BE6 r2 = r4 & 7
    strb    r2, [r1, #0x15]                 @ 08022BEA u8 [r1+0x15] = r2
    ldr.w   r2, =sd_csd                     @ 08022BEC r2 = &sd_csd
    ldr     r2, [r2, #8]                    @ 08022BF0 r2 = u32 [sd_csd+0x8]
    lsrs    r2, r2, #0x10                   @ 08022BF2 r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022BF4 r4 = r2
    movs    r2, r4                          @ 08022BF6 r2 = r4
    uxtb    r2, r2                          @ 08022BF8 r2 = u8(r2)
    lsrs    r2, r2, #5                      @ 08022BFA r2 = r2 >> 5
    strb    r2, [r1, #0x16]                 @ 08022BFC u8 [r1+0x16] = r2
    ubfx    r2, r4, #2, #3                  @ 08022BFE
    strb    r2, [r1, #0x17]                 @ 08022C02 u8 [r1+0x17] = r2
    lsls    r2, r4, #1                      @ 08022C04 r2 = r4 << 1
    ands    r2, r2, #6                      @ 08022C06 r2 = r2 & 6
    strb    r2, [r1, #0x18]                 @ 08022C0A u8 [r1+0x18] = r2
    ldr.w   r2, =sd_csd                     @ 08022C0C r2 = &sd_csd
    ldr     r2, [r2, #8]                    @ 08022C10 r2 = u32 [sd_csd+0x8]
    lsrs    r2, r2, #8                      @ 08022C12 r2 = r2 >> 8
    movs    r4, r2                          @ 08022C14 r4 = r2
    ldrb    r3, [r1, #0x18]                 @ 08022C16 r3 = u8 [r1+0x18]
    movs    r2, r4                          @ 08022C18 r2 = r4
    uxtb    r2, r2                          @ 08022C1A r2 = u8(r2)
    orrs.w  r2, r3, r2, lsr #7              @ 08022C1C r2 = r3 | r2, lsr #7
    strb    r2, [r1, #0x18]                 @ 08022C20 u8 [r1+0x18] = r2
    ldr     r2, [r1, #0x10]                 @ 08022C22 r2 = u32 [r1+0x10]
    adds    r2, r2, #1                      @ 08022C24 r2 = r2 + 1
    movs    r3, #0                          @ 08022C26 r3 = 0
    strd    r2, r3, [r1, #0x48]             @ 08022C28
    ldrd    r6, r7, [r1, #0x48]             @ 08022C2C
    movs    r2, #1                          @ 08022C30 r2 = 1
    ldrb    r3, [r1, #0x18]                 @ 08022C32 r3 = u8 [r1+0x18]
    adds    r3, r3, #2                      @ 08022C34 r3 = r3 + 2
    lsls    r2, r3                          @ 08022C36 r2 <<= r3
    asrs    r3, r2, #0x1f                   @ 08022C38 r3 = r2 >>(arith) 0x1f
    umull   r8, r9, r2, r6                  @ 08022C3A
    mla     r9, r2, r7, r9                  @ 08022C3E
    mla     r9, r3, r6, r9                  @ 08022C42
    strd    r8, r9, [r1, #0x48]             @ 08022C46
    movs    r2, #1                          @ 08022C4A r2 = 1
    ldrsb.w r3, [r1, #8]                    @ 08022C4C r3 = s8 [r1+0x8]
    lsls    r2, r3                          @ 08022C50 r2 <<= r3
    str     r2, [r1, #0x50]                 @ 08022C52 u32 [r1+0x50] = r2
    ldrd    r6, r7, [r1, #0x48]             @ 08022C54
    ldr     r2, [r1, #0x50]                 @ 08022C58 r2 = u32 [r1+0x50]
    movs    r3, #0                          @ 08022C5A r3 = 0
    umull   r8, r9, r2, r6                  @ 08022C5C
    mla     r9, r2, r7, r9                  @ 08022C60
    mla     r9, r3, r6, r9                  @ 08022C64
    strd    r8, r9, [r1, #0x48]             @ 08022C68
    b       .Lsd_get_card_info_2CD0         @ 08022C6C goto 0x8022CD0
.Lsd_get_card_info_2C6E:                @ v2.05 0x08022C6E, reached from 0x08022BAA
    ldr.w   r2, =sd_card_type               @ 08022C6E r2 = &sd_card_type
    ldr     r2, [r2]                        @ 08022C72 r2 = u32 [sd_card_type]
    cmp     r2, #2                          @ 08022C74 compare r2 with 2
    bne     .Lsd_get_card_info_2CD0         @ 08022C76 if (r2 != 2) goto 0x8022CD0
    ldr.w   r2, =sd_csd                     @ 08022C78 r2 = &sd_csd
    ldr     r2, [r2, #4]                    @ 08022C7C r2 = u32 [sd_csd+0x4]
    movs    r4, r2                          @ 08022C7E r4 = r2
    uxtb    r4, r4                          @ 08022C80 r4 = u8(r4)
    lsls    r2, r4, #0x10                   @ 08022C82 r2 = r4 << 0x10
    ands    r2, r2, #0x3f0000               @ 08022C84 r2 = r2 & 0x3f0000
    str     r2, [r1, #0x10]                 @ 08022C88 u32 [r1+0x10] = r2
    ldr.w   r2, =sd_csd                     @ 08022C8A r2 = &sd_csd
    ldr     r2, [r2, #8]                    @ 08022C8E r2 = u32 [sd_csd+0x8]
    lsrs    r2, r2, #0x18                   @ 08022C90 r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022C92 r4 = r2
    ldr     r2, [r1, #0x10]                 @ 08022C94 r2 = u32 [r1+0x10]
    uxtb    r4, r4                          @ 08022C96 r4 = u8(r4)
    orrs.w  r2, r2, r4, lsl #8              @ 08022C98 r2 = r2 | r4, lsl #8
    str     r2, [r1, #0x10]                 @ 08022C9C u32 [r1+0x10] = r2
    ldr.w   r2, =sd_csd                     @ 08022C9E r2 = &sd_csd
    ldr     r2, [r2, #8]                    @ 08022CA2 r2 = u32 [sd_csd+0x8]
    lsrs    r2, r2, #0x10                   @ 08022CA4 r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022CA6 r4 = r2
    ldr     r2, [r1, #0x10]                 @ 08022CA8 r2 = u32 [r1+0x10]
    uxtb    r4, r4                          @ 08022CAA r4 = u8(r4)
    orrs    r2, r4                          @ 08022CAC r2 |= r4
    str     r2, [r1, #0x10]                 @ 08022CAE u32 [r1+0x10] = r2
    ldr.w   r2, =sd_csd                     @ 08022CB0 r2 = &sd_csd
    ldr     r2, [r2, #8]                    @ 08022CB4 r2 = u32 [sd_csd+0x8]
    lsrs    r2, r2, #8                      @ 08022CB6 r2 = r2 >> 8
    movs    r4, r2                          @ 08022CB8 r4 = r2
    ldr     r2, [r1, #0x10]                 @ 08022CBA r2 = u32 [r1+0x10]
    adds    r2, r2, #1                      @ 08022CBC r2 = C_SIZE + 1
    @ OF-68: CardCapacity = (C_SIZE + 1) * 512 KiB as a 64-bit value.  v2.05 multiplied in 32 bits (0x08022CBE..0x08022CC4:
    @ movs.w r3, #0x80000; muls; movs r3, #0), which wraps above 4 GiB (a 32 GB card: 1.72 GiB); v2.05 never used the
    @ value, the port's disk_ioctl GET_SECTOR_COUNT does (f_mkfs sizes the volume by it, IMP-32)
    lsrs    r3, r2, #13                     @ high word: (C_SIZE + 1) >> (32 - 19)
    lsls    r2, r2, #19                     @ low word: (C_SIZE + 1) << 19
    strd    r2, r3, [r1, #0x48]             @ 08022CC6
    mov.w   r2, #0x200                      @ 08022CCA r2 = 0x200
    str     r2, [r1, #0x50]                 @ 08022CCE u32 [r1+0x50] = r2
.Lsd_get_card_info_2CD0:                @ v2.05 0x08022CD0, reached from 0x08022C6C, 0x08022C76
    ubfx    r2, r4, #6, #1                  @ 08022CD0
    strb    r2, [r1, #0x19]                 @ 08022CD4 u8 [r1+0x19] = r2
    lsls    r2, r4, #1                      @ 08022CD6 r2 = r4 << 1
    ands    r2, r2, #0x7e                   @ 08022CD8 r2 = r2 & 0x7e
    strb    r2, [r1, #0x1a]                 @ 08022CDC u8 [r1+0x1A] = r2
    ldr.w   r2, =sd_csd                     @ 08022CDE r2 = &sd_csd
    ldr     r2, [r2, #8]                    @ 08022CE2 r2 = u32 [sd_csd+0x8]
    movs    r4, r2                          @ 08022CE4 r4 = r2
    ldrb    r3, [r1, #0x1a]                 @ 08022CE6 r3 = u8 [r1+0x1A]
    movs    r2, r4                          @ 08022CE8 r2 = r4
    uxtb    r2, r2                          @ 08022CEA r2 = u8(r2)
    orrs.w  r2, r3, r2, lsr #7              @ 08022CEC r2 = r3 | r2, lsr #7
    strb    r2, [r1, #0x1a]                 @ 08022CF0 u8 [r1+0x1A] = r2
    ands    r2, r4, #0x7f                   @ 08022CF2 r2 = r4 & 0x7f
    strb    r2, [r1, #0x1b]                 @ 08022CF6 u8 [r1+0x1B] = r2
    ldr.w   r2, =sd_csd                     @ 08022CF8 r2 = &sd_csd
    ldr     r2, [r2, #0xc]                  @ 08022CFC r2 = u32 [sd_csd+0xC]
    lsrs    r2, r2, #0x18                   @ 08022CFE r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022D00 r4 = r2
    movs    r2, r4                          @ 08022D02 r2 = r4
    uxtb    r2, r2                          @ 08022D04 r2 = u8(r2)
    lsrs    r2, r2, #7                      @ 08022D06 r2 = r2 >> 7
    strb    r2, [r1, #0x1c]                 @ 08022D08 u8 [r1+0x1C] = r2
    ubfx    r2, r4, #5, #2                  @ 08022D0A
    strb    r2, [r1, #0x1d]                 @ 08022D0E u8 [r1+0x1D] = r2
    ubfx    r2, r4, #2, #3                  @ 08022D10
    strb    r2, [r1, #0x1e]                 @ 08022D14 u8 [r1+0x1E] = r2
    lsls    r2, r4, #2                      @ 08022D16 r2 = r4 << 2
    ands    r2, r2, #0xc                    @ 08022D18 r2 = r2 & 0xc
    strb    r2, [r1, #0x1f]                 @ 08022D1C u8 [r1+0x1F] = r2
    ldr.w   r2, =sd_csd                     @ 08022D1E r2 = &sd_csd
    ldr     r2, [r2, #0xc]                  @ 08022D22 r2 = u32 [sd_csd+0xC]
    lsrs    r2, r2, #0x10                   @ 08022D24 r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022D26 r4 = r2
    ldrb    r3, [r1, #0x1f]                 @ 08022D28 r3 = u8 [r1+0x1F]
    movs    r2, r4                          @ 08022D2A r2 = r4
    uxtb    r2, r2                          @ 08022D2C r2 = u8(r2)
    orrs.w  r2, r3, r2, lsr #6              @ 08022D2E r2 = r3 | r2, lsr #6
    strb    r2, [r1, #0x1f]                 @ 08022D32 u8 [r1+0x1F] = r2
    ubfx    r2, r4, #5, #1                  @ 08022D34
    strb.w  r2, [r1, #0x20]                 @ 08022D38 u8 [r1+0x20] = r2
    movs    r2, #0                          @ 08022D3C r2 = 0
    strb.w  r2, [r1, #0x21]                 @ 08022D3E u8 [r1+0x21] = r2
    ands    r2, r4, #1                      @ 08022D42 r2 = r4 & 1
    strb.w  r2, [r1, #0x22]                 @ 08022D46 u8 [r1+0x22] = r2
    ldr.w   r2, =sd_csd                     @ 08022D4A r2 = &sd_csd
    ldr     r2, [r2, #0xc]                  @ 08022D4E r2 = u32 [sd_csd+0xC]
    lsrs    r2, r2, #8                      @ 08022D50 r2 = r2 >> 8
    movs    r4, r2                          @ 08022D52 r4 = r2
    movs    r2, r4                          @ 08022D54 r2 = r4
    uxtb    r2, r2                          @ 08022D56 r2 = u8(r2)
    lsrs    r2, r2, #7                      @ 08022D58 r2 = r2 >> 7
    strb.w  r2, [r1, #0x23]                 @ 08022D5A u8 [r1+0x23] = r2
    ubfx    r2, r4, #6, #1                  @ 08022D5E
    strb.w  r2, [r1, #0x24]                 @ 08022D62 u8 [r1+0x24] = r2
    ubfx    r2, r4, #5, #1                  @ 08022D66
    strb.w  r2, [r1, #0x25]                 @ 08022D6A u8 [r1+0x25] = r2
    ubfx    r2, r4, #4, #1                  @ 08022D6E
    strb.w  r2, [r1, #0x26]                 @ 08022D72 u8 [r1+0x26] = r2
    ubfx    r2, r4, #2, #2                  @ 08022D76
    strb.w  r2, [r1, #0x27]                 @ 08022D7A u8 [r1+0x27] = r2
    ands    r2, r4, #3                      @ 08022D7E r2 = r4 & 3
    strb.w  r2, [r1, #0x28]                 @ 08022D82 u8 [r1+0x28] = r2
    ldr.w   r2, =sd_csd                     @ 08022D86 r2 = &sd_csd
    ldr     r2, [r2, #0xc]                  @ 08022D8A r2 = u32 [sd_csd+0xC]
    movs    r4, r2                          @ 08022D8C r4 = r2
    movs    r2, r4                          @ 08022D8E r2 = r4
    uxtb    r2, r2                          @ 08022D90 r2 = u8(r2)
    lsrs    r2, r2, #1                      @ 08022D92 r2 = r2 >> 1
    strb.w  r2, [r1, #0x29]                 @ 08022D94 u8 [r1+0x29] = r2
    movs    r2, #1                          @ 08022D98 r2 = 1
    strb.w  r2, [r1, #0x2a]                 @ 08022D9A u8 [r1+0x2A] = r2
    ldr.w   r2, =sd_cid                     @ 08022D9E r2 = &sd_cid
    ldr     r2, [r2]                        @ 08022DA2 r2 = u32 [sd_cid]
    lsrs    r2, r2, #0x18                   @ 08022DA4 r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022DA6 r4 = r2
    strb.w  r4, [r1, #0x2c]                 @ 08022DA8 u8 [r1+0x2C] = r4
    ldr.w   r2, =sd_cid                     @ 08022DAC r2 = &sd_cid
    ldr     r2, [r2]                        @ 08022DB0 r2 = u32 [sd_cid]
    lsrs    r2, r2, #0x10                   @ 08022DB2 r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022DB4 r4 = r2
    uxtb    r4, r4                          @ 08022DB6 r4 = u8(r4)
    lsls    r2, r4, #8                      @ 08022DB8 r2 = r4 << 8
    strh    r2, [r1, #0x2e]                 @ 08022DBA u16 [r1+0x2E] = r2
    ldr.w   r2, =sd_cid                     @ 08022DBC r2 = &sd_cid
    ldr     r2, [r2]                        @ 08022DC0 r2 = u32 [sd_cid]
    lsrs    r2, r2, #8                      @ 08022DC2 r2 = r2 >> 8
    movs    r4, r2                          @ 08022DC4 r4 = r2
    ldrh    r2, [r1, #0x2e]                 @ 08022DC6 r2 = u16 [r1+0x2E]
    uxtb    r4, r4                          @ 08022DC8 r4 = u8(r4)
    orrs    r2, r4                          @ 08022DCA r2 |= r4
    strh    r2, [r1, #0x2e]                 @ 08022DCC u16 [r1+0x2E] = r2
    ldr.w   r2, =sd_cid                     @ 08022DCE r2 = &sd_cid
    ldr     r2, [r2]                        @ 08022DD2 r2 = u32 [sd_cid]
    movs    r4, r2                          @ 08022DD4 r4 = r2
    uxtb    r4, r4                          @ 08022DD6 r4 = u8(r4)
    lsls    r2, r4, #0x18                   @ 08022DD8 r2 = r4 << 0x18
    str     r2, [r1, #0x30]                 @ 08022DDA u32 [r1+0x30] = r2
    ldr.w   r2, =sd_cid                     @ 08022DDC r2 = &sd_cid
    ldr     r2, [r2, #4]                    @ 08022DE0 r2 = u32 [sd_cid+0x4]
    lsrs    r2, r2, #0x18                   @ 08022DE2 r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022DE4 r4 = r2
    ldr     r2, [r1, #0x30]                 @ 08022DE6 r2 = u32 [r1+0x30]
    uxtb    r4, r4                          @ 08022DE8 r4 = u8(r4)
    orrs.w  r2, r2, r4, lsl #16             @ 08022DEA r2 = r2 | r4, lsl #16
    str     r2, [r1, #0x30]                 @ 08022DEE u32 [r1+0x30] = r2
    ldr.w   r2, =sd_cid                     @ 08022DF0 r2 = &sd_cid
    ldr     r2, [r2, #4]                    @ 08022DF4 r2 = u32 [sd_cid+0x4]
    lsrs    r2, r2, #0x10                   @ 08022DF6 r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022DF8 r4 = r2
    ldr     r2, [r1, #0x30]                 @ 08022DFA r2 = u32 [r1+0x30]
    uxtb    r4, r4                          @ 08022DFC r4 = u8(r4)
    orrs.w  r2, r2, r4, lsl #8              @ 08022DFE r2 = r2 | r4, lsl #8
    str     r2, [r1, #0x30]                 @ 08022E02 u32 [r1+0x30] = r2
    ldr.w   r2, =sd_cid                     @ 08022E04 r2 = &sd_cid
    ldr     r2, [r2, #4]                    @ 08022E08 r2 = u32 [sd_cid+0x4]
    lsrs    r2, r2, #8                      @ 08022E0A r2 = r2 >> 8
    movs    r4, r2                          @ 08022E0C r4 = r2
    ldr     r2, [r1, #0x30]                 @ 08022E0E r2 = u32 [r1+0x30]
    uxtb    r4, r4                          @ 08022E10 r4 = u8(r4)
    orrs    r2, r4                          @ 08022E12 r2 |= r4
    str     r2, [r1, #0x30]                 @ 08022E14 u32 [r1+0x30] = r2
    ldr.w   r2, =sd_cid                     @ 08022E16 r2 = &sd_cid
    ldr     r2, [r2, #4]                    @ 08022E1A r2 = u32 [sd_cid+0x4]
    movs    r4, r2                          @ 08022E1C r4 = r2
    strb.w  r4, [r1, #0x34]                 @ 08022E1E u8 [r1+0x34] = r4
    ldr.w   r2, =sd_cid                     @ 08022E22 r2 = &sd_cid
    ldr     r2, [r2, #8]                    @ 08022E26 r2 = u32 [sd_cid+0x8]
    lsrs    r2, r2, #0x18                   @ 08022E28 r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022E2A r4 = r2
    strb.w  r4, [r1, #0x35]                 @ 08022E2C u8 [r1+0x35] = r4
    ldr.w   r2, =sd_cid                     @ 08022E30 r2 = &sd_cid
    ldr     r2, [r2, #8]                    @ 08022E34 r2 = u32 [sd_cid+0x8]
    lsrs    r2, r2, #0x10                   @ 08022E36 r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022E38 r4 = r2
    uxtb    r4, r4                          @ 08022E3A r4 = u8(r4)
    lsls    r2, r4, #0x18                   @ 08022E3C r2 = r4 << 0x18
    str     r2, [r1, #0x38]                 @ 08022E3E u32 [r1+0x38] = r2
    ldr.w   r2, =sd_cid                     @ 08022E40 r2 = &sd_cid
    ldr     r2, [r2, #8]                    @ 08022E44 r2 = u32 [sd_cid+0x8]
    lsrs    r2, r2, #8                      @ 08022E46 r2 = r2 >> 8
    movs    r4, r2                          @ 08022E48 r4 = r2
    ldr     r2, [r1, #0x38]                 @ 08022E4A r2 = u32 [r1+0x38]
    uxtb    r4, r4                          @ 08022E4C r4 = u8(r4)
    orrs.w  r2, r2, r4, lsl #16             @ 08022E4E r2 = r2 | r4, lsl #16
    str     r2, [r1, #0x38]                 @ 08022E52 u32 [r1+0x38] = r2
    ldr.w   r2, =sd_cid                     @ 08022E54 r2 = &sd_cid
    ldr     r2, [r2, #8]                    @ 08022E58 r2 = u32 [sd_cid+0x8]
    movs    r4, r2                          @ 08022E5A r4 = r2
    ldr     r2, [r1, #0x38]                 @ 08022E5C r2 = u32 [r1+0x38]
    uxtb    r4, r4                          @ 08022E5E r4 = u8(r4)
    orrs.w  r2, r2, r4, lsl #8              @ 08022E60 r2 = r2 | r4, lsl #8
    str     r2, [r1, #0x38]                 @ 08022E64 u32 [r1+0x38] = r2
    ldr.w   r2, =sd_cid                     @ 08022E66 r2 = &sd_cid
    ldr     r2, [r2, #0xc]                  @ 08022E6A r2 = u32 [sd_cid+0xC]
    lsrs    r2, r2, #0x18                   @ 08022E6C r2 = r2 >> 0x18
    movs    r4, r2                          @ 08022E6E r4 = r2
    ldr     r2, [r1, #0x38]                 @ 08022E70 r2 = u32 [r1+0x38]
    uxtb    r4, r4                          @ 08022E72 r4 = u8(r4)
    orrs    r2, r4                          @ 08022E74 r2 |= r4
    str     r2, [r1, #0x38]                 @ 08022E76 u32 [r1+0x38] = r2
    ldr.w   r2, =sd_cid                     @ 08022E78 r2 = &sd_cid
    ldr     r2, [r2, #0xc]                  @ 08022E7C r2 = u32 [sd_cid+0xC]
    lsrs    r2, r2, #0x10                   @ 08022E7E r2 = r2 >> 0x10
    movs    r4, r2                          @ 08022E80 r4 = r2
    ldrb.w  r3, [r1, #0x3c]                 @ 08022E82 r3 = u8 [r1+0x3C]
    movs    r2, r4                          @ 08022E86 r2 = r4
    uxtb    r2, r2                          @ 08022E88 r2 = u8(r2)
    orrs.w  r2, r3, r2, lsr #4              @ 08022E8A r2 = r3 | r2, lsr #4
    strb.w  r2, [r1, #0x3c]                 @ 08022E8E u8 [r1+0x3C] = r2
    uxtb    r4, r4                          @ 08022E92 r4 = u8(r4)
    lsls    r2, r4, #8                      @ 08022E94 r2 = r4 << 8
    ands    r2, r2, #0xf00                  @ 08022E96 r2 = r2 & 0xf00
    strh    r2, [r1, #0x3e]                 @ 08022E9A u16 [r1+0x3E] = r2
    ldr.w   r2, =sd_cid                     @ 08022E9C r2 = &sd_cid
    ldr     r2, [r2, #0xc]                  @ 08022EA0 r2 = u32 [sd_cid+0xC]
    lsrs    r2, r2, #8                      @ 08022EA2 r2 = r2 >> 8
    movs    r4, r2                          @ 08022EA4 r4 = r2
    ldrh    r2, [r1, #0x3e]                 @ 08022EA6 r2 = u16 [r1+0x3E]
    uxtb    r4, r4                          @ 08022EA8 r4 = u8(r4)
    orrs    r2, r4                          @ 08022EAA r2 |= r4
    strh    r2, [r1, #0x3e]                 @ 08022EAC u16 [r1+0x3E] = r2
    ldr.w   r2, =sd_cid                     @ 08022EAE r2 = &sd_cid
    ldr     r2, [r2, #0xc]                  @ 08022EB2 r2 = u32 [sd_cid+0xC]
    movs    r4, r2                          @ 08022EB4 r4 = r2
    movs    r2, r4                          @ 08022EB6 r2 = r4
    uxtb    r2, r2                          @ 08022EB8 r2 = u8(r2)
    lsrs    r2, r2, #1                      @ 08022EBA r2 = r2 >> 1
    strb.w  r2, [r1, #0x40]                 @ 08022EBC u8 [r1+0x40] = r2
    movs    r2, #1                          @ 08022EC0 r2 = 1
    strb.w  r2, [r1, #0x41]                 @ 08022EC2 u8 [r1+0x41] = r2
    uxtb    r0, r0                          @ 08022EC6 r0 = u8(r0)
    pop.w   {r4, r6, r7, r8, r9}            @ 08022EC8 pop {r4, r6, r7, r8, r9}
    bx      lr                              @ 08022ECC return
ENDFUNC sd_get_card_info
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_set_bus_width - set the bus width of the card and the host (ST SD_EnableWideBusOperation)
@ Replaces  : 0x08022ECE sd_set_bus_width (v2.05 verified name), called by sd_init
@ In        : r0 = host bus width constant: 0 = 1 bit, 0x800 = 4 bits, 0x1000 = 8 bits (not supported)
@ Out       : r0 = 0 ok, 0x27 (8 bits requested, or the card is an MMC), else the SD error of the ACMD6 sequence
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : sdio_init_struct (rebuilt for sdio_init), sd_card_type
@ Spec      : v2.05 listing 0x08022ECE..0x08022F95
@ Note      : sd_init calls it with 0 (1 bit).  Card type 3 (MMC) gives 0x27; types 0, 1 and 2 are handled; the other types do
@             nothing and return 0.  Width 0x1000 gives 0x27; width 0x800 (4 bits): sd_enable_wide_bus(1), then the host is configured with
@             BusWide 0x800; any other value (1 bit): sd_enable_wide_bus(0), then the host is configured with BusWide 0 (sdio_init_struct
@             with ClockDiv 1, written by sdio_init).  The board and the emulated SD socket have one data line (PC8): only 1 bit is used.
@ -----------------------------------------------------------------------------
FUNC sd_set_bus_width
    push    {r3, r4, r5, lr}                @ 08022ECE push {r3, r4, r5, lr}
    movs    r4, r0                          @ 08022ED0 r4 = r0
    movs    r5, #0                          @ 08022ED2 r5 = 0
    ldr.w   r0, =sd_card_type               @ 08022ED4 r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08022ED8 r0 = u32 [sd_card_type]
    @ card type 3 (MMC): unsupported feature 0x27
    cmp     r0, #3                          @ 08022EDA compare r0 with 3
    bne     .Lsd_set_bus_width_2EE8         @ 08022EDC if (r0 != 3) goto 0x8022EE8
    movs    r0, #0x27                       @ 08022EDE r0 = 0x27
    movs    r5, r0                          @ 08022EE0 r5 = r0
    movs    r0, r5                          @ 08022EE2 r0 = r5
    uxtb    r0, r0                          @ 08022EE4 r0 = u8(r0)
    b       .Lsd_set_bus_width_2F94         @ 08022EE6 goto 0x8022F94
.Lsd_set_bus_width_2EE8:                @ v2.05 0x08022EE8, reached from 0x08022EDC
    ldr.w   r0, =sd_card_type               @ 08022EE8 r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08022EEC r0 = u32 [sd_card_type]
    cmp     r0, #0                          @ 08022EEE compare r0 with 0
    beq     .Lsd_set_bus_width_2F06         @ 08022EF0 if (r0 == 0) goto 0x8022F06
    ldr.w   r0, =sd_card_type               @ 08022EF2 r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08022EF6 r0 = u32 [sd_card_type]
    cmp     r0, #1                          @ 08022EF8 compare r0 with 1
    beq     .Lsd_set_bus_width_2F06         @ 08022EFA if (r0 == 1) goto 0x8022F06
    ldr.w   r0, =sd_card_type               @ 08022EFC r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08022F00 r0 = u32 [sd_card_type]
    cmp     r0, #2                          @ 08022F02 compare r0 with 2
    bne     .Lsd_set_bus_width_2F90         @ 08022F04 if (r0 != 2) goto 0x8022F90
    @ card types 0, 1, 2: width 0x1000 is refused with 0x27
.Lsd_set_bus_width_2F06:                @ v2.05 0x08022F06, reached from 0x08022EF0, 0x08022EFA
    cmp.w   r4, #0x1000                     @ 08022F06 compare r4 with 0x1000
    bne     .Lsd_set_bus_width_2F16         @ 08022F0A if (r4 != 0x1000) goto 0x8022F16
    movs    r0, #0x27                       @ 08022F0C r0 = 0x27
    movs    r5, r0                          @ 08022F0E r5 = r0
    movs    r0, r5                          @ 08022F10 r0 = r5
    uxtb    r0, r0                          @ 08022F12 r0 = u8(r0)
    b       .Lsd_set_bus_width_2F94         @ 08022F14 goto 0x8022F94
    @ 0x800 (4 bits): ACMD6 sequence with wide = 1, then the host BusWide field 0x800 (2F42) and sdio_init
.Lsd_set_bus_width_2F16:                @ v2.05 0x08022F16, reached from 0x08022F0A
    cmp.w   r4, #0x800                      @ 08022F16 compare r4 with 0x800
    bne     .Lsd_set_bus_width_2F58         @ 08022F1A if (r4 != 0x800) goto 0x8022F58
    movs    r0, #1                          @ 08022F1C r0 = 1
    bl      sd_enable_wide_bus              @ 08022F1E call sd_enable_wide_bus
    movs    r5, r0                          @ 08022F22 r5 = r0
    uxtb    r5, r5                          @ 08022F24 r5 = u8(r5)
    cmp     r5, #0                          @ 08022F26 compare r5 with 0
    bne     .Lsd_set_bus_width_2F90         @ 08022F28 if (r5 != 0) goto 0x8022F90
    movs    r0, #SD_CLKDIV_FULL             @ 08022F2A v2.05: 1 (SDIO_CK = SDIOCLK / 3)
    ldr     r1, =sdio_init_struct           @ 08022F2C r1 = &sdio_init_struct
    strb    r0, [r1, #0x14]                 @ 08022F2E u8 [sdio_init_struct+0x14] = r0
    movs    r0, #0                          @ 08022F30 r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F32 r1 = &sdio_init_struct
    str     r0, [r1]                        @ 08022F34 u32 [sdio_init_struct] = r0
    movs    r0, #0                          @ 08022F36 r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F38 r1 = &sdio_init_struct
    str     r0, [r1, #4]                    @ 08022F3A u32 [sdio_init_struct+0x4] = r0
    movs    r0, #0                          @ 08022F3C r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F3E r1 = &sdio_init_struct
    str     r0, [r1, #8]                    @ 08022F40 u32 [sdio_init_struct+0x8] = r0
    mov.w   r0, #0x800                      @ 08022F42 r0 = 0x800
    ldr     r1, =sdio_init_struct           @ 08022F46 r1 = &sdio_init_struct
    str     r0, [r1, #0xc]                  @ 08022F48 u32 [sdio_init_struct+0xC] = r0
    movs    r0, #0                          @ 08022F4A r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F4C r1 = &sdio_init_struct
    str     r0, [r1, #0x10]                 @ 08022F4E u32 [sdio_init_struct+0x10] = r0
    ldr     r0, =sdio_init_struct           @ 08022F50 r0 = &sdio_init_struct
    bl      sdio_init                       @ 08022F52 call sdio_init
    b       .Lsd_set_bus_width_2F90         @ 08022F56 goto 0x8022F90
    @ otherwise (1 bit): ACMD6 sequence with wide = 0, then BusWide 0 and sdio_init
.Lsd_set_bus_width_2F58:                @ v2.05 0x08022F58, reached from 0x08022F1A
    movs    r0, #0                          @ 08022F58 r0 = 0
    bl      sd_enable_wide_bus              @ 08022F5A call sd_enable_wide_bus
    movs    r5, r0                          @ 08022F5E r5 = r0
    uxtb    r5, r5                          @ 08022F60 r5 = u8(r5)
    cmp     r5, #0                          @ 08022F62 compare r5 with 0
    bne     .Lsd_set_bus_width_2F90         @ 08022F64 if (r5 != 0) goto 0x8022F90
    movs    r0, #SD_CLKDIV_FULL             @ 08022F66 v2.05: 1 (SDIO_CK = SDIOCLK / 3)
    ldr     r1, =sdio_init_struct           @ 08022F68 r1 = &sdio_init_struct
    strb    r0, [r1, #0x14]                 @ 08022F6A u8 [sdio_init_struct+0x14] = r0
    movs    r0, #0                          @ 08022F6C r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F6E r1 = &sdio_init_struct
    str     r0, [r1]                        @ 08022F70 u32 [sdio_init_struct] = r0
    movs    r0, #0                          @ 08022F72 r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F74 r1 = &sdio_init_struct
    str     r0, [r1, #4]                    @ 08022F76 u32 [sdio_init_struct+0x4] = r0
    movs    r0, #0                          @ 08022F78 r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F7A r1 = &sdio_init_struct
    str     r0, [r1, #8]                    @ 08022F7C u32 [sdio_init_struct+0x8] = r0
    movs    r0, #0                          @ 08022F7E r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F80 r1 = &sdio_init_struct
    str     r0, [r1, #0xc]                  @ 08022F82 u32 [sdio_init_struct+0xC] = r0
    movs    r0, #0                          @ 08022F84 r0 = 0
    ldr     r1, =sdio_init_struct           @ 08022F86 r1 = &sdio_init_struct
    str     r0, [r1, #0x10]                 @ 08022F88 u32 [sdio_init_struct+0x10] = r0
    ldr     r0, =sdio_init_struct           @ 08022F8A r0 = &sdio_init_struct
    bl      sdio_init                       @ 08022F8C call sdio_init
.Lsd_set_bus_width_2F90:                @ v2.05 0x08022F90, reached from 0x08022F04, 0x08022F28, 0x08022F56, 0x08022F64
    movs    r0, r5                          @ 08022F90 r0 = r5
    uxtb    r0, r0                          @ 08022F92 r0 = u8(r0)
.Lsd_set_bus_width_2F94:                @ v2.05 0x08022F94, reached from 0x08022EE6, 0x08022F14
    pop     {r1, r4, r5, pc}                @ 08022F94 pop {r1, r4, r5, pc}
ENDFUNC sd_set_bus_width
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_select_deselect - CMD7 with the argument r0 (ST SD_SelectDeselect)
@ Replaces  : 0x08022F96 FUN_08022F96 (v2.05), called by sd_init
@ In        : r0 = argument (RCA << 16 to select)
@ Out       : r0 = SD error code of the R1 answer (0 ok)
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08022F96..0x08022FCD; PLS 2.00 4.3.1 (CMD7)
@ -----------------------------------------------------------------------------
FUNC sd_select_deselect
    push    {r3, r4, r5, lr}                @ 08022F96 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 08022F98 r4 = r0
    movs    r5, #0                          @ 08022F9A r5 = 0
    ldr     r0, =sdio_cmd_struct            @ 08022F9C r0 = &sdio_cmd_struct
    str     r4, [r0]                        @ 08022F9E u32 [sdio_cmd_struct] = r4
    movs    r0, #7                          @ 08022FA0 r0 = 7
    ldr     r1, =sdio_cmd_struct            @ 08022FA2 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08022FA4 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08022FA6 r0 = 0x40
    ldr     r1, =sdio_cmd_struct            @ 08022FA8 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08022FAA u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08022FAC r0 = 0
    ldr     r1, =sdio_cmd_struct            @ 08022FAE r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08022FB0 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08022FB2 r0 = 0x400
    ldr     r1, =sdio_cmd_struct            @ 08022FB6 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08022FB8 u32 [sdio_cmd_struct+0x10] = r0
    ldr     r0, =sdio_cmd_struct            @ 08022FBA r0 = &sdio_cmd_struct
    bl      sdio_send_command               @ 08022FBC call sdio_send_command
    movs    r0, #7                          @ 08022FC0 r0 = 7
    bl      sd_cmd_resp1_error              @ 08022FC2 call sd_cmd_resp1_error
    movs    r5, r0                          @ 08022FC6 r5 = r0
    movs    r0, r5                          @ 08022FC8 r0 = r5
    uxtb    r0, r0                          @ 08022FCA r0 = u8(r0)
    pop     {r1, r4, r5, pc}                @ 08022FCC pop {r1, r4, r5, pc}
ENDFUNC sd_select_deselect
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_read_block - start a single block read by DMA (ST SD_ReadBlock)
@ Replaces  : 0x08022FCE FUN_08022FCE (v2.05), called by disk_read
@ In        : r0 = destination buffer, r1 = unused (v2.05 passes the buffer twice), r2 = byte address low, r3 = byte address high, [sp] = block size (0x200)
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : clears sd_transfer_error 0x200080F7, sd_transfer_end 0x20007EF4, sd_stop_condition 0x20007EF0, SDIO_DCTRL; reads sd_card_type
@ Spec      : v2.05 listing 0x08022FCE..0x080230EB; PLS 2.00 4.3.4 (CMD17), 4.3.13 (CMD16)
@ Note      : for an SDHC card (type 2) the block size is forced to 512 and the address becomes a block number (address >> 9).
@             CMD16 sets the block length, the data path is configured for a single block from card to host (DTIMER 0xFFFFFFFF,
@             length = block size, block size 2^9), CMD17 with the address, then SDIO interrupts are enabled (mask 0x32A: DCRCFAIL,
@             DTIMEOUT, DATAEND, RXOVERR, STBITERR), DMAEN is set and DMA2 channel 4 is started (sd_dma_start_rx).  The caller polls
@             sd_get_status; the data arrives by DMA while the SDIO interrupt sets sd_transfer_end.
@ -----------------------------------------------------------------------------
FUNC sd_read_block
    push.w  {r4, r5, r6, r7, r8, lr}        @ 08022FCE push {r4, r5, r6, r7, r8, lr}
    movs    r7, r0                          @ 08022FD2 r7 = r0
    movs    r4, r2                          @ 08022FD4 r4 = r2
    movs    r5, r3                          @ 08022FD6 r5 = r3
    ldr     r6, [sp, #0x18]                 @ 08022FD8 r6 = u32 [sp+0x18]
    movs.w  r8, #0                          @ 08022FDA r8 = 0
    movs    r0, #0                          @ 08022FDE r0 = 0
    ldr.w   r1, =sd_transfer_error          @ 08022FE0 r1 = &sd_transfer_error
    @ clear the transfer state variables and the data control register
    strb    r0, [r1]                        @ 08022FE4 u8 [sd_transfer_error] = r0
    movs    r0, #0                          @ 08022FE6 r0 = 0
    ldr.w   r1, =sd_transfer_end            @ 08022FE8 r1 = &sd_transfer_end
    str     r0, [r1]                        @ 08022FEC u32 [sd_transfer_end] = r0
    movs    r0, #0                          @ 08022FEE r0 = 0
    ldr.w   r1, =sd_stop_condition          @ 08022FF0 r1 = &sd_stop_condition
    str     r0, [r1]                        @ 08022FF4 u32 [sd_stop_condition] = r0
    movs    r0, #0                          @ 08022FF6 r0 = 0
    ldr.w   r1, =(SDIO_BASE + SDIO_DCTRL)   @ 08022FF8 r1 = (SDIO_BASE + SDIO_DCTRL)
    str     r0, [r1]                        @ 08022FFC u32 [(SDIO_BASE + SDIO_DCTRL)] = r0
    ldr.w   r0, =sd_card_type               @ 08022FFE r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08023002 r0 = u32 [sd_card_type]
    @ SDHC: block size 512 and block address
    cmp     r0, #2                          @ 08023004 compare r0 with 2
    bne     .Lsd_read_block_3016            @ 08023006 if (r0 != 2) goto 0x8023016
    mov.w   r0, #0x200                      @ 08023008 r0 = 0x200
    movs    r6, r0                          @ 0802300C r6 = r0
    lsrs    r4, r4, #9                      @ 0802300E r4 = r4 >> 9
    orr.w   r4, r4, r5, lsl #23             @ 08023010 r4 = r4 | r5, lsl #23
    lsrs    r5, r5, #9                      @ 08023014 r5 = r5 >> 9
.Lsd_read_block_3016:                   @ v2.05 0x08023016, reached from 0x08023006
    uxth    r6, r6                          @ 08023016 r6 = u16(r6)
    ldr     r0, =sdio_cmd_struct            @ 08023018 r0 = &sdio_cmd_struct
    str     r6, [r0]                        @ 0802301A u32 [sdio_cmd_struct] = r6
    movs    r0, #0x10                       @ 0802301C r0 = 0x10
    ldr     r1, =sdio_cmd_struct            @ 0802301E r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023020 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08023022 r0 = 0x40
    ldr     r1, =sdio_cmd_struct            @ 08023024 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023026 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08023028 r0 = 0
    ldr     r1, =sdio_cmd_struct            @ 0802302A r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 0802302C u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 0802302E r0 = 0x400
    ldr     r1, =sdio_cmd_struct            @ 08023032 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08023034 u32 [sdio_cmd_struct+0x10] = r0
    ldr     r0, =sdio_cmd_struct            @ 08023036 r0 = &sdio_cmd_struct
    @ CMD16 (block length)
    bl      sdio_send_command               @ 08023038 call sdio_send_command
    movs    r0, #0x10                       @ 0802303C r0 = 0x10
    bl      sd_cmd_resp1_error              @ 0802303E call sd_cmd_resp1_error
    mov     r8, r0                          @ 08023042 r8 = r0
    uxtb.w  r8, r8                          @ 08023044 r8 = u8(r8)
    cmp.w   r8, #0                          @ 08023048 compare r8 with 0
    beq     .Lsd_read_block_3054            @ 0802304C if (r8 == 0) goto 0x8023054
    mov     r0, r8                          @ 0802304E r0 = r8
    uxtb    r0, r0                          @ 08023050 r0 = u8(r0)
    b       .Lsd_read_block_30E8            @ 08023052 goto 0x80230E8
.Lsd_read_block_3054:                   @ v2.05 0x08023054, reached from 0x0802304C
    movs.w  r0, #-1                         @ 08023054 r0 = -1
    ldr.w   r1, =sdio_data_struct           @ 08023058 r1 = &sdio_data_struct
    str     r0, [r1]                        @ 0802305C u32 [sdio_data_struct] = r0
    uxth    r6, r6                          @ 0802305E r6 = u16(r6)
    ldr.w   r0, =sdio_data_struct           @ 08023060 r0 = &sdio_data_struct
    str     r6, [r0, #4]                    @ 08023064 u32 [sdio_data_struct+0x4] = r6
    movs    r0, #0x90                       @ 08023066 r0 = 0x90
    ldr.w   r1, =sdio_data_struct           @ 08023068 r1 = &sdio_data_struct
    str     r0, [r1, #8]                    @ 0802306C u32 [sdio_data_struct+0x8] = r0
    movs    r0, #2                          @ 0802306E r0 = 2
    ldr.w   r1, =sdio_data_struct           @ 08023070 r1 = &sdio_data_struct
    str     r0, [r1, #0xc]                  @ 08023074 u32 [sdio_data_struct+0xC] = r0
    movs    r0, #0                          @ 08023076 r0 = 0
    ldr.w   r1, =sdio_data_struct           @ 08023078 r1 = &sdio_data_struct
    str     r0, [r1, #0x10]                 @ 0802307C u32 [sdio_data_struct+0x10] = r0
    movs    r0, #1                          @ 0802307E r0 = 1
    ldr.w   r1, =sdio_data_struct           @ 08023080 r1 = &sdio_data_struct
    str     r0, [r1, #0x14]                 @ 08023084 u32 [sdio_data_struct+0x14] = r0
    ldr.w   r0, =sdio_data_struct           @ 08023086 r0 = &sdio_data_struct
    @ data path: single block, card to host
    bl      sdio_data_config                @ 0802308A call sdio_data_config
    ldr     r0, =sdio_cmd_struct            @ 0802308E r0 = &sdio_cmd_struct
    str     r4, [r0]                        @ 08023090 u32 [sdio_cmd_struct] = r4
    movs    r0, #0x11                       @ 08023092 r0 = 0x11
    ldr     r1, =sdio_cmd_struct            @ 08023094 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023096 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08023098 r0 = 0x40
    ldr     r1, =sdio_cmd_struct            @ 0802309A r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 0802309C u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 0802309E r0 = 0
    ldr     r1, =sdio_cmd_struct            @ 080230A0 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 080230A2 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 080230A4 r0 = 0x400
    ldr     r1, =sdio_cmd_struct            @ 080230A8 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 080230AA u32 [sdio_cmd_struct+0x10] = r0
    ldr     r0, =sdio_cmd_struct            @ 080230AC r0 = &sdio_cmd_struct
    @ CMD17
    bl      sdio_send_command               @ 080230AE call sdio_send_command
    movs    r0, #0x11                       @ 080230B2 r0 = 0x11
    bl      sd_cmd_resp1_error              @ 080230B4 call sd_cmd_resp1_error
    mov     r8, r0                          @ 080230B8 r8 = r0
    uxtb.w  r8, r8                          @ 080230BA r8 = u8(r8)
    cmp.w   r8, #0                          @ 080230BE compare r8 with 0
    beq     .Lsd_read_block_30CA            @ 080230C2 if (r8 == 0) goto 0x80230CA
    mov     r0, r8                          @ 080230C4 r0 = r8
    uxtb    r0, r0                          @ 080230C6 r0 = u8(r0)
    b       .Lsd_read_block_30E8            @ 080230C8 goto 0x80230E8
.Lsd_read_block_30CA:                   @ v2.05 0x080230CA, reached from 0x080230C2
    movs    r1, #1                          @ 080230CA r1 = 1
    @ interrupts DCRCFAIL, DTIMEOUT, DATAEND, RXOVERR, STBITERR (0x32A); DMA request on; DMA2 channel 4 to the buffer
    movw    r0, #0x32a                      @ 080230CC
    bl      sdio_it_config                  @ 080230D0 call sdio_it_config
    movs    r0, #1                          @ 080230D4 r0 = 1
    bl      sdio_dma_cmd                    @ 080230D6 call sdio_dma_cmd
    uxth    r6, r6                          @ 080230DA r6 = u16(r6)
    movs    r1, r6                          @ 080230DC r1 = r6
    movs    r0, r7                          @ 080230DE r0 = r7
    bl      sd_dma_start_rx                 @ 080230E0 call sd_dma_start_rx
    mov     r0, r8                          @ 080230E4 r0 = r8
    uxtb    r0, r0                          @ 080230E6 r0 = u8(r0)
.Lsd_read_block_30E8:                   @ v2.05 0x080230E8, reached from 0x08023052, 0x080230C8
    pop.w   {r4, r5, r6, r7, r8, pc}        @ 080230E8 pop {r4, r5, r6, r7, r8, pc}
ENDFUNC sd_read_block
    .ltorg

    .if !SD_READ_ONLY                       @ the card write path (not in the read-only bootloader build)
@ -----------------------------------------------------------------------------
@ sd_write_blocks - start a block write by DMA (ST SD_WriteBlock / SD_WriteMultiBlocks)
@ Replaces  : 0x08023100 FUN_08023100 (v2.05), called by disk_write
@ In        : r0 = source buffer, r1 = not used (v2.05 passes 0x200; disk_write now leaves the upper address word there), r2 = byte
@             address low, r3 = byte address high, [sp] = block size, [sp+4] = number of blocks (1)
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : sets sd_stop_condition = 1, clears sd_transfer_end and sd_transfer_error
@ Spec      : v2.05 listing 0x08023100..0x080232DF; PLS 2.00 4.3.4 (CMD25), 4.3.13 (CMD16, ACMD23)
@ Note      : for an SDHC card (type 2) the block size is forced to 512 and the address becomes a block number.  CMD16 (block
@             length), CMD55 with the RCA and ACMD23 (SET_WR_BLK_ERASE_COUNT with the number of blocks), CMD25 (WRITE_MULTIPLE_BLOCK)
@             with the address; the data path is configured host to card (DTIMER 0xFFFFFFFF, length = block size * blocks, block size
@             2^9); interrupts 0x32A (DCRCFAIL, DTIMEOUT, RXOVERR, DATAEND, STBITERR - the same mask as the read; TXUNDERR is not
@             enabled), DMAEN, DMA2 channel 4 from the buffer (sd_dma_start_tx).  The multi-block write is terminated by CMD12 in
@             sd_wait_write.
@ -----------------------------------------------------------------------------
FUNC sd_write_blocks
    push.w  {r3, r4, r5, r6, r7, r8, r9, lr}@ 08023100 push {r3, r4, r5, r6, r7, r8, r9, lr}
    movs    r7, r0                          @ 08023104 r7 = r0
    movs    r4, r2                          @ 08023106 r4 = r2
    movs    r5, r3                          @ 08023108 r5 = r3
    ldr     r6, [sp, #0x20]                 @ 0802310A r6 = u32 [sp+0x20]
    ldr.w   r8, [sp, #0x24]                 @ 0802310C r8 = u32 [sp+0x24]
    movs.w  r9, #0                          @ 08023110 r9 = 0
    movs    r0, #0                          @ 08023114 r0 = 0
    ldr.w   r1, =sd_transfer_error          @ 08023116 r1 = &sd_transfer_error
    strb    r0, [r1]                        @ 0802311A u8 [sd_transfer_error] = r0
    movs    r0, #0                          @ 0802311C r0 = 0
    ldr.w   r1, =sd_transfer_end            @ 0802311E r1 = &sd_transfer_end
    str     r0, [r1]                        @ 08023122 u32 [sd_transfer_end] = r0
    movs    r0, #1                          @ 08023124 r0 = 1
    ldr.w   r1, =sd_stop_condition          @ 08023126 r1 = &sd_stop_condition
    str     r0, [r1]                        @ 0802312A u32 [sd_stop_condition] = r0
    movs    r0, #0                          @ 0802312C r0 = 0
    ldr.w   r1, =(SDIO_BASE + SDIO_DCTRL)   @ 0802312E r1 = (SDIO_BASE + SDIO_DCTRL)
    str     r0, [r1]                        @ 08023132 u32 [(SDIO_BASE + SDIO_DCTRL)] = r0
    ldr.w   r0, =sd_card_type               @ 08023134 r0 = &sd_card_type
    ldr     r0, [r0]                        @ 08023138 r0 = u32 [sd_card_type]
    @ SDHC: block size 512 and block address
    cmp     r0, #2                          @ 0802313A compare r0 with 2
    bne     .Lsd_write_blocks_314C          @ 0802313C if (r0 != 2) goto 0x802314C
    mov.w   r0, #0x200                      @ 0802313E r0 = 0x200
    movs    r6, r0                          @ 08023142 r6 = r0
    lsrs    r4, r4, #9                      @ 08023144 r4 = r4 >> 9
    orr.w   r4, r4, r5, lsl #23             @ 08023146 r4 = r4 | r5, lsl #23
    lsrs    r5, r5, #9                      @ 0802314A r5 = r5 >> 9
.Lsd_write_blocks_314C:                 @ v2.05 0x0802314C, reached from 0x0802313C
    uxth    r6, r6                          @ 0802314C r6 = u16(r6)
    ldr.w   r0, =sdio_cmd_struct            @ 0802314E r0 = &sdio_cmd_struct
    str     r6, [r0]                        @ 08023152 u32 [sdio_cmd_struct] = r6
    movs    r0, #0x10                       @ 08023154 r0 = 0x10
    ldr.w   r1, =sdio_cmd_struct            @ 08023156 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 0802315A u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 0802315C r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 0802315E r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023162 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08023164 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08023166 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 0802316A u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 0802316C r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08023170 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08023174 u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08023176 r0 = &sdio_cmd_struct
    @ CMD16
    bl      sdio_send_command               @ 0802317A call sdio_send_command
    movs    r0, #0x10                       @ 0802317E r0 = 0x10
    bl      sd_cmd_resp1_error              @ 08023180 call sd_cmd_resp1_error
    mov     r9, r0                          @ 08023184 r9 = r0
    uxtb.w  r9, r9                          @ 08023186 r9 = u8(r9)
    cmp.w   r9, #0                          @ 0802318A compare r9 with 0
    beq     .Lsd_write_blocks_3196          @ 0802318E if (r9 == 0) goto 0x8023196
    mov     r0, r9                          @ 08023190 r0 = r9
    uxtb    r0, r0                          @ 08023192 r0 = u8(r0)
    b       .Lsd_write_blocks_32D4          @ 08023194 goto 0x80232D4
.Lsd_write_blocks_3196:                 @ v2.05 0x08023196, reached from 0x0802318E
    ldr     r0, =sd_rca                     @ 08023196 r0 = &sd_rca
    ldr     r0, [r0]                        @ 08023198 r0 = u32 [sd_rca]
    lsls    r0, r0, #0x10                   @ 0802319A r0 = r0 << 0x10
    ldr.w   r1, =sdio_cmd_struct            @ 0802319C r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 080231A0 u32 [sdio_cmd_struct] = r0
    movs    r0, #0x37                       @ 080231A2 r0 = 0x37
    ldr.w   r1, =sdio_cmd_struct            @ 080231A4 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 080231A8 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 080231AA r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 080231AC r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 080231B0 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 080231B2 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 080231B4 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 080231B8 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 080231BA r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 080231BE r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 080231C2 u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 080231C4 r0 = &sdio_cmd_struct
    @ CMD55 (RCA)
    bl      sdio_send_command               @ 080231C8 call sdio_send_command
    movs    r0, #0x37                       @ 080231CC r0 = 0x37
    bl      sd_cmd_resp1_error              @ 080231CE call sd_cmd_resp1_error
    mov     r9, r0                          @ 080231D2 r9 = r0
    uxtb.w  r9, r9                          @ 080231D4 r9 = u8(r9)
    cmp.w   r9, #0                          @ 080231D8 compare r9 with 0
    beq     .Lsd_write_blocks_31E4          @ 080231DC if (r9 == 0) goto 0x80231E4
    mov     r0, r9                          @ 080231DE r0 = r9
    uxtb    r0, r0                          @ 080231E0 r0 = u8(r0)
    b       .Lsd_write_blocks_32D4          @ 080231E2 goto 0x80232D4
.Lsd_write_blocks_31E4:                 @ v2.05 0x080231E4, reached from 0x080231DC
    ldr.w   r0, =sdio_cmd_struct            @ 080231E4 r0 = &sdio_cmd_struct
    str.w   r8, [r0]                        @ 080231E8 u32 [sdio_cmd_struct] = r8
    movs    r0, #0x17                       @ 080231EC r0 = 0x17
    ldr.w   r1, =sdio_cmd_struct            @ 080231EE r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 080231F2 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 080231F4 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 080231F6 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 080231FA u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 080231FC r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 080231FE r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08023202 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08023204 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08023208 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 0802320C u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 0802320E r0 = &sdio_cmd_struct
    @ ACMD23 (number of blocks)
    bl      sdio_send_command               @ 08023212 call sdio_send_command
    movs    r0, #0x17                       @ 08023216 r0 = 0x17
    bl      sd_cmd_resp1_error              @ 08023218 call sd_cmd_resp1_error
    mov     r9, r0                          @ 0802321C r9 = r0
    uxtb.w  r9, r9                          @ 0802321E r9 = u8(r9)
    cmp.w   r9, #0                          @ 08023222 compare r9 with 0
    beq     .Lsd_write_blocks_322E          @ 08023226 if (r9 == 0) goto 0x802322E
    mov     r0, r9                          @ 08023228 r0 = r9
    uxtb    r0, r0                          @ 0802322A r0 = u8(r0)
    b       .Lsd_write_blocks_32D4          @ 0802322C goto 0x80232D4
.Lsd_write_blocks_322E:                 @ v2.05 0x0802322E, reached from 0x08023226
    ldr.w   r0, =sdio_cmd_struct            @ 0802322E r0 = &sdio_cmd_struct
    str     r4, [r0]                        @ 08023232 u32 [sdio_cmd_struct] = r4
    movs    r0, #0x19                       @ 08023234 r0 = 0x19
    ldr.w   r1, =sdio_cmd_struct            @ 08023236 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 0802323A u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 0802323C r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 0802323E r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023242 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08023244 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08023246 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 0802324A u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 0802324C r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08023250 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08023254 u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08023256 r0 = &sdio_cmd_struct
    @ CMD25
    bl      sdio_send_command               @ 0802325A call sdio_send_command
    movs    r0, #0x19                       @ 0802325E r0 = 0x19
    bl      sd_cmd_resp1_error              @ 08023260 call sd_cmd_resp1_error
    mov     r9, r0                          @ 08023264 r9 = r0
    uxtb.w  r9, r9                          @ 08023266 r9 = u8(r9)
    cmp.w   r9, #0                          @ 0802326A compare r9 with 0
    beq     .Lsd_write_blocks_3276          @ 0802326E if (r9 == 0) goto 0x8023276
    mov     r0, r9                          @ 08023270 r0 = r9
    uxtb    r0, r0                          @ 08023272 r0 = u8(r0)
    b       .Lsd_write_blocks_32D4          @ 08023274 goto 0x80232D4
.Lsd_write_blocks_3276:                 @ v2.05 0x08023276, reached from 0x0802326E
    movs.w  r0, #-1                         @ 08023276 r0 = -1
    ldr.w   r1, =sdio_data_struct           @ 0802327A r1 = &sdio_data_struct
    str     r0, [r1]                        @ 0802327E u32 [sdio_data_struct] = r0
    uxth    r6, r6                          @ 08023280 r6 = u16(r6)
    mul     r0, r6, r8                      @ 08023282 r0 = r6 * r8
    ldr.w   r1, =sdio_data_struct           @ 08023286 r1 = &sdio_data_struct
    str     r0, [r1, #4]                    @ 0802328A u32 [sdio_data_struct+0x4] = r0
    movs    r0, #0x90                       @ 0802328C r0 = 0x90
    ldr.w   r1, =sdio_data_struct           @ 0802328E r1 = &sdio_data_struct
    str     r0, [r1, #8]                    @ 08023292 u32 [sdio_data_struct+0x8] = r0
    movs    r0, #0                          @ 08023294 r0 = 0
    ldr.w   r1, =sdio_data_struct           @ 08023296 r1 = &sdio_data_struct
    str     r0, [r1, #0xc]                  @ 0802329A u32 [sdio_data_struct+0xC] = r0
    movs    r0, #0                          @ 0802329C r0 = 0
    ldr.w   r1, =sdio_data_struct           @ 0802329E r1 = &sdio_data_struct
    str     r0, [r1, #0x10]                 @ 080232A2 u32 [sdio_data_struct+0x10] = r0
    movs    r0, #1                          @ 080232A4 r0 = 1
    ldr.w   r1, =sdio_data_struct           @ 080232A6 r1 = &sdio_data_struct
    str     r0, [r1, #0x14]                 @ 080232AA u32 [sdio_data_struct+0x14] = r0
    ldr.w   r0, =sdio_data_struct           @ 080232AC r0 = &sdio_data_struct
    @ data path configuration and interrupts, DMA start
    bl      sdio_data_config                @ 080232B0 call sdio_data_config
    movs    r1, #1                          @ 080232B4 r1 = 1
    movw    r0, #0x32a                      @ 080232B6
    bl      sdio_it_config                  @ 080232BA call sdio_it_config
    movs    r0, #1                          @ 080232BE r0 = 1
    bl      sdio_dma_cmd                    @ 080232C0 call sdio_dma_cmd
    uxth    r6, r6                          @ 080232C4 r6 = u16(r6)
    mul     r1, r6, r8                      @ 080232C6 r1 = r6 * r8
    movs    r0, r7                          @ 080232CA r0 = r7
    bl      sd_dma_start_tx                 @ 080232CC call sd_dma_start_tx
    mov     r0, r9                          @ 080232D0 r0 = r9
    uxtb    r0, r0                          @ 080232D2 r0 = u8(r0)
.Lsd_write_blocks_32D4:                 @ v2.05 0x080232D4, reached from 0x08023194, 0x080231E2, 0x0802322C, 0x08023274
    pop.w   {r1, r4, r5, r6, r7, r8, r9, pc}@ 080232D4 pop {r1, r4, r5, r6, r7, r8, r9, pc}
ENDFUNC sd_write_blocks
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_wait_write - wait for the end of a block write and stop the transmission (ST SD_WaitWriteOperation / SD_StopTransfer)
@ Replaces  : 0x080232E0 FUN_080232E0 (v2.05), called by disk_write
@ In        : -
@ Out       : r0 = 4 when the first wait ran out of polls, otherwise the result of the last step (0, or the CMD12 error); callers ignore it
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : reads sd_dma_end, sd_transfer_end, sd_transfer_error, SDIO_STA; uses sd_wait_count 0x20007EFC
@ Spec      : v2.05 listing 0x080232E0..0x080233BD
@ Note      : first wait until the DMA-complete flag, the transfer-end flag or an error is set; then sd_dma_end is cleared and the
@             routine waits for the SDIO transmit-active bit (STA bit 12) to clear (the DPSM holds it while the card signals busy
@             after the block).  Then, when sd_stop_condition is 1, CMD12 (STOP_TRANSMISSION) is sent and the static flags are
@             cleared (ICR = 0x5FF).
@ Deviation : IMP-33 (production): each wait lasts up to SD_WRITE_TICKS (600 ms, above the SD write timeout) instead of v2.05's
@             1000 polls (about 7 ms), and a wait that runs out still sends CMD12 and returns 4.  v2.05 returned at once without
@             CMD12: a card still busy after 7 ms (allowed up to 250 / 500 ms) stayed in the receive state and every following
@             CMD13 poll failed (measured on a meter, 2026-11-04: state 6, status 0x00000D00, 1.9 s of polling; the cause of the
@             failed card writes of the Bluetooth transfers and of a failed format).
@ -----------------------------------------------------------------------------
FUNC sd_wait_write
    push    {r3, r4, r5, lr}                @ 080232E0 push {r3, r4, r5, lr}
    movs    r4, #0                          @ 080232E2 r4 = 0
    @ IMP-33: both waits are bounded by time, SD_WRITE_TICKS ticks of the 10 ms counter v_20007FC6 (the card may hold the
    @ data line busy for the SD write timeout, Physical Layer 4.6.2.2), with SD_WRITE_POLLS polls as a backstop; v2.05
    @ waited 1000 polls (about 7 ms) and then returned without CMD12, which left the card in the receive state (state 6:
    @ on a meter, 2026-11-04, status 0x00000D00 polled for 1.9 s after the second wait ran out, DMA end seen).
    movs.w  r0, #-1                         @ 080232E4 r0 = -1
    movs    r5, r0                          @ 080232E8 r5 = r0 (0 = a wait ran out)
    ldr     r0, =SD_WRITE_POLLS
    ldr.w   r1, =sd_wait_count              @ 080232EE r1 = &sd_wait_count
    str     r0, [r1]                        @ 080232F2 u32 [sd_wait_count] = r0
    ldr     r3, =v_20007FC6
    ldrh    r3, [r3]                        @ r3 = tick at the start
    @ first loop: leave when sd_dma_end, sd_transfer_end or sd_transfer_error is set, or the time is over
.Lsd_wait_write_32F4:                   @ v2.05 0x080232F4, reached from 0x08023332
    ldr.w   r0, =sd_dma_end                 @ 080232F4 r0 = &sd_dma_end
    ldr     r0, [r0]                        @ 080232F8 r0 = u32 [sd_dma_end]
    cmp     r0, #0                          @ 080232FA compare r0 with 0
    bne     .Lsd_wait_write_3338            @ 080232FC if (r0 != 0) goto 0x8023338
    ldr.w   r0, =sd_transfer_end            @ 080232FE r0 = &sd_transfer_end
    ldr     r0, [r0]                        @ 08023302 r0 = u32 [sd_transfer_end]
    cmp     r0, #0                          @ 08023304 compare r0 with 0
    bne     .Lsd_wait_write_3338            @ 08023306 if (r0 != 0) goto 0x8023338
    ldr.w   r0, =sd_transfer_error          @ 08023308 r0 = &sd_transfer_error
    ldrb    r0, [r0]                        @ 0802330C r0 = u8 [sd_transfer_error]
    cmp     r0, #0                          @ 0802330E compare r0 with 0
    bne     .Lsd_wait_write_3338            @ 08023310 if (r0 != 0) goto 0x8023338
    bl      sd_write_wait_over              @ time or backstop over?
    cmp     r0, #0
    beq     .Lsd_wait_write_32F4
    movs    r5, #0                          @ the first wait ran out: CMD12 all the same (below), result 4
    movs    r0, #1
    bl      sd_dg_wtimeout                  @ diagnosis: wait 1 (DMA / transfer end), its length, the transfer state
    b       .Lsd_wait_write_3380
    @ sd_dma_end = 0, the second wait from now
.Lsd_wait_write_3338:                   @ v2.05 0x08023338, reached from 0x080232FC, 0x08023306, 0x08023310, 0x0802331A
    movs    r0, #0                          @ 08023338 r0 = 0
    ldr.w   r1, =sd_dma_end                 @ 0802333A r1 = &sd_dma_end
    str     r0, [r1]                        @ 0802333E u32 [sd_dma_end] = r0
    ldr     r0, =SD_WRITE_POLLS
    ldr.w   r1, =sd_wait_count              @ 0802334A r1 = &sd_wait_count
    str     r0, [r1]                        @ 0802334E u32 [sd_wait_count] = r0
    ldr     r3, =v_20007FC6
    ldrh    r3, [r3]                        @ r3 = tick at the start of the second wait
    @ second loop: while SDIO_STA bit 12 (TXACT) is set (the DPSM waits for the card's busy to end) and the time is not over
.Lsd_wait_write_3350:                   @ v2.05 0x08023350, reached from 0x0802337A
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 08023350 r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 08023354 r0 = u32 [(SDIO_BASE + SDIO_STA)]
    lsls    r0, r0, #0x13                   @ 08023356 r0 = r0 << 0x13
    bpl     .Lsd_wait_write_3380            @ 08023358 if (r0 >=0 0) goto 0x8023380
    bl      sd_write_wait_over
    cmp     r0, #0
    beq     .Lsd_wait_write_3350
    movs    r5, #0                          @ the second wait ran out: CMD12 all the same, result 4
    movs    r0, #2
    bl      sd_dg_wtimeout                  @ diagnosis: wait 2 (TXACT: the card's busy), its length, the transfer state
    @ stop condition: CMD12 (sd_stop_transfer)
.Lsd_wait_write_3380:                   @ v2.05 0x08023380, reached from 0x08023358, 0x08023362
    ldr.w   r0, =sd_stop_condition          @ 08023380 r0 = &sd_stop_condition
    ldr     r0, [r0]                        @ 08023384 r0 = u32 [sd_stop_condition]
    cmp     r0, #1                          @ 08023386 compare r0 with 1
    bne     .Lsd_wait_write_3390            @ 08023388 if (r0 != 1) goto 0x8023390
    bl      sd_stop_transfer                @ 0802338A call sd_stop_transfer
    movs    r4, r0                          @ 0802338E r4 = r0
.Lsd_wait_write_3390:                   @ v2.05 0x08023390, reached from 0x08023388
    cmp     r5, #0                          @ 08023390 compare r5 with 0
    bne     .Lsd_wait_write_339E            @ 08023392 if (r5 != 0) goto 0x802339E
    uxtb    r4, r4                          @ 08023394 r4 = u8(r4)
    cmp     r4, #0                          @ 08023396 compare r4 with 0
    bne     .Lsd_wait_write_339E            @ 08023398 if (r4 != 0) goto 0x802339E
    movs    r0, #4                          @ 0802339A r0 = 4
    movs    r4, r0                          @ 0802339C r4 = r0
    @ clear all static SDIO flags (ICR = 0x5FF)
.Lsd_wait_write_339E:                   @ v2.05 0x0802339E, reached from 0x08023392, 0x08023398
    @ OF-59: a data error flag still set in SDIO_STA (DCRCFAIL, DTIMEOUT, TXUNDERR, RXOVERR, STBITERR = 0x23A) makes the result
    @ non-zero before the flags are cleared: the interrupt handler serves DATAEND first and then masks every source, so an
    @ error flagged with or after DATAEND (a negative CRC status token) is seen only here
    ldr     r0, =(SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]
    movw    r1, #0x23a
    tst     r0, r1
    it      ne
    movne   r4, #2                          @ SD error 2 (data error), as the handler's DCRCFAIL code
    movw    r0, #0x5ff                      @ 0802339E
    bl      sdio_clear_flag                 @ 080233A2 call sdio_clear_flag
    ldr.w   r0, =sd_transfer_error          @ 080233A6 r0 = &sd_transfer_error
    ldrb    r0, [r0]                        @ 080233AA r0 = u8 [sd_transfer_error]
    cmp     r0, #0                          @ 080233AC compare r0 with 0
    beq     .Lsd_wait_write_33B8            @ 080233AE if (r0 == 0) goto 0x80233B8
    ldr.w   r0, =sd_transfer_error          @ 080233B0 r0 = &sd_transfer_error
    ldrb    r0, [r0]                        @ 080233B4 r0 = u8 [sd_transfer_error]
    b       .Lsd_wait_write_33BC            @ 080233B6 goto 0x80233BC
.Lsd_wait_write_33B8:                   @ v2.05 0x080233B8, reached from 0x080233AE
    movs    r0, r4                          @ 080233B8 r0 = r4
    uxtb    r0, r0                          @ 080233BA r0 = u8(r0)
.Lsd_wait_write_33BC:                   @ v2.05 0x080233BC, reached from 0x08023336, 0x0802337E, 0x080233B6
    pop     {r1, r4, r5, pc}                @ 080233BC pop {r1, r4, r5, pc}
ENDFUNC sd_wait_write

@ -----------------------------------------------------------------------------
@ sd_write_wait_over - one step of a write wait: the backstop count sd_wait_count down by one
@ In       : r3 = tick (v_20007FC6) at the start of the wait
@ Out      : r0 = 1 when SD_WRITE_TICKS ticks have passed or the backstop count reached 0, else 0
@ Clobbers : r0, r1, flags
@ -----------------------------------------------------------------------------
LFUNC sd_write_wait_over
    ldr     r1, =v_20007FC6
    ldrh    r0, [r1]
    subs    r0, r0, r3
    uxth    r0, r0                          @ ticks since the start (the counter wraps at 16 bits)
    cmp     r0, #SD_WRITE_TICKS
    bhs     1f
    ldr     r1, =sd_wait_count
    ldr     r0, [r1]
    subs    r0, r0, #1
    str     r0, [r1]
    beq     1f
    movs    r0, #0
    bx      lr
1:  movs    r0, #1
    bx      lr
ENDFUNC sd_write_wait_over
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_stop_transfer - CMD12 STOP_TRANSMISSION (ST SD_StopTransfer)
@ Replaces  : 0x080233BE FUN_080233BE (v2.05), called by sd_wait_write
@ In        : -
@ Out       : r0 = SD error code of the R1b answer
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080233BE..0x08023401; PLS 2.00 4.3.1 (CMD12)
@ -----------------------------------------------------------------------------
FUNC sd_stop_transfer
    push    {r4, lr}                        @ 080233BE push {r4, lr}
    movs    r4, #0                          @ 080233C0 r4 = 0
    movs    r0, #0                          @ 080233C2 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 080233C4 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 080233C8 u32 [sdio_cmd_struct] = r0
    movs    r0, #0xc                        @ 080233CA r0 = 0xc
    ldr.w   r1, =sdio_cmd_struct            @ 080233CC r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 080233D0 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 080233D2 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 080233D4 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 080233D8 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 080233DA r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 080233DC r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 080233E0 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 080233E2 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 080233E6 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 080233EA u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 080233EC r0 = &sdio_cmd_struct
    bl      sdio_send_command               @ 080233F0 call sdio_send_command
    movs    r0, #0xc                        @ 080233F4 r0 = 0xc
    bl      sd_cmd_resp1_error              @ 080233F6 call sd_cmd_resp1_error
    movs    r4, r0                          @ 080233FA r4 = r0
    movs    r0, r4                          @ 080233FC r0 = r4
    uxtb    r0, r0                          @ 080233FE r0 = u8(r0)
    pop     {r4, pc}                        @ 08023400 pop {r4, pc}
ENDFUNC sd_stop_transfer
    .ltorg
    .endif                                  @ !SD_READ_ONLY

@ -----------------------------------------------------------------------------
@ sd_send_status - CMD13 SEND_STATUS (ST SD_SendStatus)
@ Replaces  : 0x08023408 FUN_08023408 (v2.05), called by sd_get_state
@ In        : r0 = pointer that receives the card status word (R1)
@ Out       : r0 = 0 ok, 0x26 invalid parameter (r0 = 0), or the SD error of the answer
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08023408..0x08023475; PLS 2.00 4.3.10 (CMD13) - the argument is the RCA << 16
@ -----------------------------------------------------------------------------
FUNC sd_send_status
    push    {r3, r4, r5, lr}                @ 08023408 push {r3, r4, r5, lr}
    movs    r4, r0                          @ 0802340A r4 = r0
    movs    r5, #0                          @ 0802340C r5 = 0
    cmp     r4, #0                          @ 0802340E compare r4 with 0
    bne     .Lsd_send_status_341C           @ 08023410 if (r4 != 0) goto 0x802341C
    movs    r0, #0x26                       @ 08023412 r0 = 0x26
    movs    r5, r0                          @ 08023414 r5 = r0
    movs    r0, r5                          @ 08023416 r0 = r5
    uxtb    r0, r0                          @ 08023418 r0 = u8(r0)
    b       .Lsd_send_status_3474           @ 0802341A goto 0x8023474
.Lsd_send_status_341C:                  @ v2.05 0x0802341C, reached from 0x08023410
    ldr.w   r0, =sd_rca                     @ 0802341C r0 = &sd_rca
    ldr     r0, [r0]                        @ 08023420 r0 = u32 [sd_rca]
    lsls    r0, r0, #0x10                   @ 08023422 r0 = r0 << 0x10
    ldr.w   r1, =sdio_cmd_struct            @ 08023424 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08023428 u32 [sdio_cmd_struct] = r0
    movs    r0, #0xd                        @ 0802342A r0 = 0xd
    ldr.w   r1, =sdio_cmd_struct            @ 0802342C r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023430 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08023432 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 08023434 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023438 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 0802343A r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 0802343C r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08023440 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08023442 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08023446 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 0802344A u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 0802344C r0 = &sdio_cmd_struct
    bl      sdio_send_command               @ 08023450 call sdio_send_command
    movs    r0, #0xd                        @ 08023454 r0 = 0xd
    bl      sd_cmd_resp1_error              @ 08023456 call sd_cmd_resp1_error
    movs    r5, r0                          @ 0802345A r5 = r0
    uxtb    r5, r5                          @ 0802345C r5 = u8(r5)
    cmp     r5, #0                          @ 0802345E compare r5 with 0
    beq     .Lsd_send_status_3468           @ 08023460 if (r5 == 0) goto 0x8023468
    movs    r0, r5                          @ 08023462 r0 = r5
    uxtb    r0, r0                          @ 08023464 r0 = u8(r0)
    b       .Lsd_send_status_3474           @ 08023466 goto 0x8023474
.Lsd_send_status_3468:                  @ v2.05 0x08023468, reached from 0x08023460
    movs    r0, #0                          @ 08023468 r0 = 0
    bl      sdio_get_response               @ 0802346A call sdio_get_response
    str     r0, [r4]                        @ 0802346E u32 [r4] = r0
    movs    r0, r5                          @ 08023470 r0 = r5
    uxtb    r0, r0                          @ 08023472 r0 = u8(r0)
.Lsd_send_status_3474:                  @ v2.05 0x08023474, reached from 0x0802341A, 0x08023466
    pop     {r1, r4, r5, pc}                @ 08023474 pop {r1, r4, r5, pc}
ENDFUNC sd_send_status
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_cmd_error - wait for the command-sent flag after a command without answer (ST CmdError)
@ Replaces  : 0x08023558 FUN_08023558 (v2.05), called by sd_power_on
@ In        : -
@ Out       : r0 = 0 ok, 3 command timeout
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08023558..0x080235A3
@ Note      : polls SDIO_STA for CMDSENT (bit 7) at most 20000 times (the second counter 0x10000 is not reached first); the static flags are cleared (ICR = 0x5FF).
@ -----------------------------------------------------------------------------
FUNC sd_cmd_error
    push    {r4, r5, r6, lr}                @ 08023558 push {r4, r5, r6, lr}
    movs    r4, #0                          @ 0802355A r4 = 0
    movs.w  r0, #0x10000                    @ 0802355C r0 = 0x10000
    movs    r5, r0                          @ 08023560 r5 = r0
    movw    r0, #0x4e20                     @ 08023562
    movs    r6, r0                          @ 08023566 r6 = r0
.Lsd_cmd_error_3568:                    @ v2.05 0x08023568, reached from 0x0802357C
    cmp     r5, #0                          @ 08023568 compare r5 with 0
    beq     .Lsd_cmd_error_3588             @ 0802356A if (r5 == 0) goto 0x8023588
    movs    r0, #0x80                       @ 0802356C r0 = 0x80
    bl      sdio_get_flag_status            @ 0802356E call sdio_get_flag_status
    cmp     r0, #0                          @ 08023572 compare r0 with 0
    bne     .Lsd_cmd_error_3588             @ 08023574 if (r0 != 0) goto 0x8023588
    subs    r5, r5, #1                      @ 08023576 r5 = r5 - 1
    subs    r6, r6, #1                      @ 08023578 r6 = r6 - 1
    cmp     r6, #0                          @ 0802357A compare r6 with 0
    bne     .Lsd_cmd_error_3568             @ 0802357C if (r6 != 0) goto 0x8023568
    movs    r0, #3                          @ 0802357E r0 = 3
    movs    r4, r0                          @ 08023580 r4 = r0
    movs    r0, r4                          @ 08023582 r0 = r4
    uxtb    r0, r0                          @ 08023584 r0 = u8(r0)
    b       .Lsd_cmd_error_35A2             @ 08023586 goto 0x80235A2
.Lsd_cmd_error_3588:                    @ v2.05 0x08023588, reached from 0x0802356A, 0x08023574
    cmp     r5, #0                          @ 08023588 compare r5 with 0
    bne     .Lsd_cmd_error_3596             @ 0802358A if (r5 != 0) goto 0x8023596
    movs    r0, #3                          @ 0802358C r0 = 3
    movs    r4, r0                          @ 0802358E r4 = r0
    movs    r0, r4                          @ 08023590 r0 = r4
    uxtb    r0, r0                          @ 08023592 r0 = u8(r0)
    b       .Lsd_cmd_error_35A2             @ 08023594 goto 0x80235A2
.Lsd_cmd_error_3596:                    @ v2.05 0x08023596, reached from 0x0802358A
    movw    r0, #0x5ff                      @ 08023596
    bl      sdio_clear_flag                 @ 0802359A call sdio_clear_flag
    movs    r0, r4                          @ 0802359E r0 = r4
    uxtb    r0, r0                          @ 080235A0 r0 = u8(r0)
.Lsd_cmd_error_35A2:                    @ v2.05 0x080235A2, reached from 0x08023586, 0x08023594
    pop     {r4, r5, r6, pc}                @ 080235A2 pop {r4, r5, r6, pc}
ENDFUNC sd_cmd_error
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_cmd_resp7_error - wait for the answer R7 (ST CmdResp7Error)
@ Replaces  : 0x080235A4 FUN_080235A4 (v2.05), called by sd_power_on
@ In        : -
@ Out       : r0 = 0 answer received, 3 timeout (flag CTIMEOUT, bit 2)
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080235A4..0x08023615
@ Note      : polls STA for CCRCFAIL|CMDREND|CTIMEOUT (mask 0x45) at most 20000 times; a timeout clears the CTIMEOUT flag and returns 3; CMDREND clears itself (ICR 0x40).
@ -----------------------------------------------------------------------------
FUNC sd_cmd_resp7_error
    push    {r3, r4, r5, r6, r7, lr}        @ 080235A4 push {r3, r4, r5, r6, r7, lr}
    movs    r4, #0                          @ 080235A6 r4 = 0
    movs.w  r7, #0x10000                    @ 080235A8 r7 = 0x10000
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 080235AC r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 080235B0 r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r5, r0                          @ 080235B2 r5 = r0
    movw    r0, #0x4e20                     @ 080235B4
    movs    r6, r0                          @ 080235B8 r6 = r0
.Lsd_cmd_resp7_error_35BA:              @ v2.05 0x080235BA, reached from 0x080235D2
    tst.w   r5, #0x45                       @ 080235BA compare r5 with 0x45
    bne     .Lsd_cmd_resp7_error_35E4       @ 080235BE if ((r5 & 0x45) != 0) goto 0x80235E4
    cmp     r7, #0                          @ 080235C0 compare r7 with 0
    beq     .Lsd_cmd_resp7_error_35E4       @ 080235C2 if (r7 == 0) goto 0x80235E4
    subs    r7, r7, #1                      @ 080235C4 r7 = r7 - 1
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 080235C6 r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 080235CA r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r5, r0                          @ 080235CC r5 = r0
    subs    r6, r6, #1                      @ 080235CE r6 = r6 - 1
    cmp     r6, #0                          @ 080235D0 compare r6 with 0
    bne     .Lsd_cmd_resp7_error_35BA       @ 080235D2 if (r6 != 0) goto 0x80235BA
    movs    r0, #3                          @ 080235D4 r0 = 3
    movs    r4, r0                          @ 080235D6 r4 = r0
    movs    r0, #4                          @ 080235D8 r0 = 4
    bl      sdio_clear_flag                 @ 080235DA call sdio_clear_flag
    movs    r0, r4                          @ 080235DE r0 = r4
    uxtb    r0, r0                          @ 080235E0 r0 = u8(r0)
    b       .Lsd_cmd_resp7_error_3614       @ 080235E2 goto 0x8023614
.Lsd_cmd_resp7_error_35E4:              @ v2.05 0x080235E4, reached from 0x080235BE, 0x080235C2
    cmp     r7, #0                          @ 080235E4 compare r7 with 0
    beq     .Lsd_cmd_resp7_error_35EC       @ 080235E6 if (r7 == 0) goto 0x80235EC
    lsls    r0, r5, #0x1d                   @ 080235E8 r0 = r5 << 0x1d
    bpl     .Lsd_cmd_resp7_error_35FC       @ 080235EA if (r0 >=0 0) goto 0x80235FC
.Lsd_cmd_resp7_error_35EC:              @ v2.05 0x080235EC, reached from 0x080235E6
    movs    r0, #3                          @ 080235EC r0 = 3
    movs    r4, r0                          @ 080235EE r4 = r0
    movs    r0, #4                          @ 080235F0 r0 = 4
    bl      sdio_clear_flag                 @ 080235F2 call sdio_clear_flag
    movs    r0, r4                          @ 080235F6 r0 = r4
    uxtb    r0, r0                          @ 080235F8 r0 = u8(r0)
    b       .Lsd_cmd_resp7_error_3614       @ 080235FA goto 0x8023614
.Lsd_cmd_resp7_error_35FC:              @ v2.05 0x080235FC, reached from 0x080235EA
    lsls    r0, r5, #0x19                   @ 080235FC r0 = r5 << 0x19
    bpl     .Lsd_cmd_resp7_error_3610       @ 080235FE if (r0 >=0 0) goto 0x8023610
    movs    r0, #0                          @ 08023600 r0 = 0
    movs    r4, r0                          @ 08023602 r4 = r0
    movs    r0, #0x40                       @ 08023604 r0 = 0x40
    bl      sdio_clear_flag                 @ 08023606 call sdio_clear_flag
    movs    r0, r4                          @ 0802360A r0 = r4
    uxtb    r0, r0                          @ 0802360C r0 = u8(r0)
    b       .Lsd_cmd_resp7_error_3614       @ 0802360E goto 0x8023614
.Lsd_cmd_resp7_error_3610:              @ v2.05 0x08023610, reached from 0x080235FE
    movs    r0, r4                          @ 08023610 r0 = r4
    uxtb    r0, r0                          @ 08023612 r0 = u8(r0)
.Lsd_cmd_resp7_error_3614:              @ v2.05 0x08023614, reached from 0x080235E2, 0x080235FA, 0x0802360E
    pop     {r1, r4, r5, r6, r7, pc}        @ 08023614 pop {r1, r4, r5, r6, r7, pc}
ENDFUNC sd_cmd_resp7_error
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_cmd_resp1_error - wait for the answer R1 of command r0 and check the card status bits (ST CmdResp1Error)
@ Replaces  : 0x0802361C FUN_0802361C (v2.05), called by every command routine of this file
@ In        : r0 = command index expected in the answer
@ Out       : r0 = 0 ok, 3 timeout, 1 command CRC fail, 0x10 wrong command index, or 9..0x1C/0x1A the first error bit of the card status
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802361C..0x08023751; PLS 2.00 4.10.1 (card status bits)
@ Note      : waits at most 20000 polls for CCRCFAIL|CMDREND|CTIMEOUT (0x45).  The answer must carry the expected command index.
@             The status word is checked against the mask 0xFDFFE008 and then bit by bit from bit 31 down: ADDRESS_OUT_OF_RANGE 0x1C,
@             ADDRESS_MISALIGNED 9, BLOCK_LEN_ERROR 10, ERASE_SEQ_ERROR 11, BAD_ERASE_PARAM 12, WRITE_PROT_VIOLATION 13,
@             LOCK_UNLOCK_FAILED 14, COM_CRC_FAILED 15, ILLEGAL_COMMAND 16, CARD_ECC_FAILED 17, CC_ERROR 18, GENERAL_UNKNOWN_ERROR 19,
@             STREAM_READ_UNDERRUN 20, STREAM_WRITE_OVERRUN 21, CID_CSD_OVERWRITE 22, WP_ERASE_SKIP 23, CARD_ECC_DISABLED 24,
@             ERASE_RESET 25, AKE_SEQ_ERROR 26.
@ Deviation : IMP-34 (production): second entry sd_cmd_resp1_keep with r1 = the SDIO_STA flags to clear after a good answer;
@             sd_cmd_resp1_error passes v2.05's 0x5FF (all static flags, data flags included).
@ -----------------------------------------------------------------------------
FUNC sd_cmd_resp1_error
    movw    r1, #0x5ff                      @ IMP-34: v2.05's mask for the clear below
@ sd_cmd_resp1_keep - as sd_cmd_resp1_error; In: r0 = command index, r1 = flags cleared after a good answer (sd_find_scr:
@ the command flags only, so that the data flags of a block the card has already sent survive)
    .global sd_cmd_resp1_keep
    .type sd_cmd_resp1_keep, %function
    .thumb_func
sd_cmd_resp1_keep:
    push.w  {r4, r5, r6, r7, r8, lr}        @ 0802361C push {r4, r5, r6, r7, r8, lr}
    movs    r4, r0                          @ 08023620 r4 = r0
    movs    r5, #0                          @ 08023622 r5 = 0
    ldr     r0, =(SDIO_BASE + SDIO_STA)     @ 08023624 r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 08023626 r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r6, r0                          @ 08023628 r6 = r0
    @ r6 = SDIO_STA; poll up to 20000 times for 0x45
    movw    r0, #0x4e20                     @ 0802362A
    mov     r8, r0                          @ 0802362E r8 = r0
.Lsd_cmd_resp1_error_3630:              @ v2.05 0x08023630, reached from 0x08023644
    tst.w   r6, #0x45                       @ 08023630 compare r6 with 0x45
    bne     .Lsd_cmd_resp1_error_3656       @ 08023634 if ((r6 & 0x45) != 0) goto 0x8023656
    ldr     r0, =(SDIO_BASE + SDIO_STA)     @ 08023636 r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 08023638 r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r6, r0                          @ 0802363A r6 = r0
    subs.w  r8, r8, #1                      @ 0802363C r8 = r8 - 1
    cmp.w   r8, #0                          @ 08023640 compare r8 with 0
    bne     .Lsd_cmd_resp1_error_3630       @ 08023644 if (r8 != 0) goto 0x8023630
    movs    r0, #3                          @ 08023646 r0 = 3
    movs    r5, r0                          @ 08023648 r5 = r0
    movs    r0, #4                          @ 0802364A r0 = 4
    bl      sdio_clear_flag                 @ 0802364C call sdio_clear_flag
    movs    r0, r5                          @ 08023650 r0 = r5
    uxtb    r0, r0                          @ 08023652 r0 = u8(r0)
    b       .Lsd_cmd_resp1_error_374E       @ 08023654 goto 0x802374E
    @ CTIMEOUT: error 3; CCRCFAIL: error 1
.Lsd_cmd_resp1_error_3656:              @ v2.05 0x08023656, reached from 0x08023634
    lsls    r0, r6, #0x1d                   @ 08023656 r0 = r6 << 0x1d
    bpl     .Lsd_cmd_resp1_error_366A       @ 08023658 if (r0 >=0 0) goto 0x802366A
    movs    r0, #3                          @ 0802365A r0 = 3
    movs    r5, r0                          @ 0802365C r5 = r0
    movs    r0, #4                          @ 0802365E r0 = 4
    bl      sdio_clear_flag                 @ 08023660 call sdio_clear_flag
    movs    r0, r5                          @ 08023664 r0 = r5
    uxtb    r0, r0                          @ 08023666 r0 = u8(r0)
    b       .Lsd_cmd_resp1_error_374E       @ 08023668 goto 0x802374E
.Lsd_cmd_resp1_error_366A:              @ v2.05 0x0802366A, reached from 0x08023658
    lsls    r0, r6, #0x1f                   @ 0802366A r0 = r6 << 0x1f
    bpl     .Lsd_cmd_resp1_error_367E       @ 0802366C if (r0 >=0 0) goto 0x802367E
    movs    r0, #1                          @ 0802366E r0 = 1
    movs    r5, r0                          @ 08023670 r5 = r0
    movs    r0, #1                          @ 08023672 r0 = 1
    bl      sdio_clear_flag                 @ 08023674 call sdio_clear_flag
    movs    r0, r5                          @ 08023678 r0 = r5
    uxtb    r0, r0                          @ 0802367A r0 = u8(r0)
    b       .Lsd_cmd_resp1_error_374E       @ 0802367C goto 0x802374E
    @ the command index of the answer (RESPCMD) must equal r0, else 0x10
.Lsd_cmd_resp1_error_367E:              @ v2.05 0x0802367E, reached from 0x0802366C
    mov     r8, r1                          @ IMP-34: the mask (r8, the poll counter, is free now; r1 is clobbered below)
    bl      sdio_get_command_response       @ 0802367E call sdio_get_command_response
    movs    r1, r4                          @ 08023682 r1 = r4
    uxtb    r1, r1                          @ 08023684 r1 = u8(r1)
    cmp     r0, r1                          @ 08023686 compare r0 with r1
    beq     .Lsd_cmd_resp1_error_3694       @ 08023688 if (r0 == r1) goto 0x8023694
    movs    r0, #0x10                       @ 0802368A r0 = 0x10
    movs    r5, r0                          @ 0802368C r5 = r0
    movs    r0, r5                          @ 0802368E r0 = r5
    uxtb    r0, r0                          @ 08023690 r0 = u8(r0)
    b       .Lsd_cmd_resp1_error_374E       @ 08023692 goto 0x802374E
    @ clear the static flags, read the status word (RESP1)
.Lsd_cmd_resp1_error_3694:              @ v2.05 0x08023694, reached from 0x08023688
    mov     r0, r8                          @ 08023694 (v2.05: movw r0, #0x5ff; IMP-34: the caller's mask)
    bl      sdio_clear_flag                 @ 08023698 call sdio_clear_flag
    movs    r0, #0                          @ 0802369C r0 = 0
    bl      sdio_get_response               @ 0802369E call sdio_get_response
    movs    r7, r0                          @ 080236A2 r7 = r0
    ldr.w   r0, =0xFDFFE008                 @ 080236A4 r0 = 0xFDFFE008
    tst     r7, r0                          @ 080236A8 compare r7 with r0
    @ no error bit in the status: 0; otherwise the first bit from 31 down decides the code
    bne     .Lsd_cmd_resp1_error_36B2       @ 080236AA if ((r7 & r0) != 0) goto 0x80236B2
    movs    r0, r5                          @ 080236AC r0 = r5
    uxtb    r0, r0                          @ 080236AE r0 = u8(r0)
    b       .Lsd_cmd_resp1_error_374E       @ 080236B0 goto 0x802374E
.Lsd_cmd_resp1_error_36B2:              @ v2.05 0x080236B2, reached from 0x080236AA
    cmp     r7, #0                          @ 080236B2 compare r7 with 0
    bpl     .Lsd_cmd_resp1_error_36BA       @ 080236B4 if (r7 >=0 0) goto 0x80236BA
    movs    r0, #0x1c                       @ 080236B6 r0 = 0x1c
    b       .Lsd_cmd_resp1_error_374E       @ 080236B8 goto 0x802374E
.Lsd_cmd_resp1_error_36BA:              @ v2.05 0x080236BA, reached from 0x080236B4
    lsls    r0, r7, #1                      @ 080236BA r0 = r7 << 1
    bpl     .Lsd_cmd_resp1_error_36C2       @ 080236BC if (r0 >=0 0) goto 0x80236C2
    movs    r0, #9                          @ 080236BE r0 = 9
    b       .Lsd_cmd_resp1_error_374E       @ 080236C0 goto 0x802374E
.Lsd_cmd_resp1_error_36C2:              @ v2.05 0x080236C2, reached from 0x080236BC
    lsls    r0, r7, #2                      @ 080236C2 r0 = r7 << 2
    bpl     .Lsd_cmd_resp1_error_36CA       @ 080236C4 if (r0 >=0 0) goto 0x80236CA
    movs    r0, #0xa                        @ 080236C6 r0 = 0xa
    b       .Lsd_cmd_resp1_error_374E       @ 080236C8 goto 0x802374E
.Lsd_cmd_resp1_error_36CA:              @ v2.05 0x080236CA, reached from 0x080236C4
    lsls    r0, r7, #3                      @ 080236CA r0 = r7 << 3
    bpl     .Lsd_cmd_resp1_error_36D2       @ 080236CC if (r0 >=0 0) goto 0x80236D2
    movs    r0, #0xb                        @ 080236CE r0 = 0xb
    b       .Lsd_cmd_resp1_error_374E       @ 080236D0 goto 0x802374E
.Lsd_cmd_resp1_error_36D2:              @ v2.05 0x080236D2, reached from 0x080236CC
    lsls    r0, r7, #4                      @ 080236D2 r0 = r7 << 4
    bpl     .Lsd_cmd_resp1_error_36DA       @ 080236D4 if (r0 >=0 0) goto 0x80236DA
    movs    r0, #0xc                        @ 080236D6 r0 = 0xc
    b       .Lsd_cmd_resp1_error_374E       @ 080236D8 goto 0x802374E
.Lsd_cmd_resp1_error_36DA:              @ v2.05 0x080236DA, reached from 0x080236D4
    lsls    r0, r7, #5                      @ 080236DA r0 = r7 << 5
    bpl     .Lsd_cmd_resp1_error_36E2       @ 080236DC if (r0 >=0 0) goto 0x80236E2
    movs    r0, #0xd                        @ 080236DE r0 = 0xd
    b       .Lsd_cmd_resp1_error_374E       @ 080236E0 goto 0x802374E
.Lsd_cmd_resp1_error_36E2:              @ v2.05 0x080236E2, reached from 0x080236DC
    lsls    r0, r7, #7                      @ 080236E2 r0 = r7 << 7
    bpl     .Lsd_cmd_resp1_error_36EA       @ 080236E4 if (r0 >=0 0) goto 0x80236EA
    movs    r0, #0xe                        @ 080236E6 r0 = 0xe
    b       .Lsd_cmd_resp1_error_374E       @ 080236E8 goto 0x802374E
.Lsd_cmd_resp1_error_36EA:              @ v2.05 0x080236EA, reached from 0x080236E4
    lsls    r0, r7, #8                      @ 080236EA r0 = r7 << 8
    bpl     .Lsd_cmd_resp1_error_36F2       @ 080236EC if (r0 >=0 0) goto 0x80236F2
    movs    r0, #0xf                        @ 080236EE r0 = 0xf
    b       .Lsd_cmd_resp1_error_374E       @ 080236F0 goto 0x802374E
.Lsd_cmd_resp1_error_36F2:              @ v2.05 0x080236F2, reached from 0x080236EC
    lsls    r0, r7, #9                      @ 080236F2 r0 = r7 << 9
    bpl     .Lsd_cmd_resp1_error_36FA       @ 080236F4 if (r0 >=0 0) goto 0x80236FA
    movs    r0, #0x10                       @ 080236F6 r0 = 0x10
    b       .Lsd_cmd_resp1_error_374E       @ 080236F8 goto 0x802374E
.Lsd_cmd_resp1_error_36FA:              @ v2.05 0x080236FA, reached from 0x080236F4
    lsls    r0, r7, #0xa                    @ 080236FA r0 = r7 << 0xa
    bpl     .Lsd_cmd_resp1_error_3702       @ 080236FC if (r0 >=0 0) goto 0x8023702
    movs    r0, #0x11                       @ 080236FE r0 = 0x11
    b       .Lsd_cmd_resp1_error_374E       @ 08023700 goto 0x802374E
.Lsd_cmd_resp1_error_3702:              @ v2.05 0x08023702, reached from 0x080236FC
    lsls    r0, r7, #0xb                    @ 08023702 r0 = r7 << 0xb
    bpl     .Lsd_cmd_resp1_error_370A       @ 08023704 if (r0 >=0 0) goto 0x802370A
    movs    r0, #0x12                       @ 08023706 r0 = 0x12
    b       .Lsd_cmd_resp1_error_374E       @ 08023708 goto 0x802374E
.Lsd_cmd_resp1_error_370A:              @ v2.05 0x0802370A, reached from 0x08023704
    lsls    r0, r7, #0xc                    @ 0802370A r0 = r7 << 0xc
    bpl     .Lsd_cmd_resp1_error_3712       @ 0802370C if (r0 >=0 0) goto 0x8023712
    movs    r0, #0x13                       @ 0802370E r0 = 0x13
    b       .Lsd_cmd_resp1_error_374E       @ 08023710 goto 0x802374E
.Lsd_cmd_resp1_error_3712:              @ v2.05 0x08023712, reached from 0x0802370C
    lsls    r0, r7, #0xd                    @ 08023712 r0 = r7 << 0xd
    bpl     .Lsd_cmd_resp1_error_371A       @ 08023714 if (r0 >=0 0) goto 0x802371A
    movs    r0, #0x14                       @ 08023716 r0 = 0x14
    b       .Lsd_cmd_resp1_error_374E       @ 08023718 goto 0x802374E
.Lsd_cmd_resp1_error_371A:              @ v2.05 0x0802371A, reached from 0x08023714
    lsls    r0, r7, #0xe                    @ 0802371A r0 = r7 << 0xe
    bpl     .Lsd_cmd_resp1_error_3722       @ 0802371C if (r0 >=0 0) goto 0x8023722
    movs    r0, #0x15                       @ 0802371E r0 = 0x15
    b       .Lsd_cmd_resp1_error_374E       @ 08023720 goto 0x802374E
.Lsd_cmd_resp1_error_3722:              @ v2.05 0x08023722, reached from 0x0802371C
    lsls    r0, r7, #0xf                    @ 08023722 r0 = r7 << 0xf
    bpl     .Lsd_cmd_resp1_error_372A       @ 08023724 if (r0 >=0 0) goto 0x802372A
    movs    r0, #0x16                       @ 08023726 r0 = 0x16
    b       .Lsd_cmd_resp1_error_374E       @ 08023728 goto 0x802374E
.Lsd_cmd_resp1_error_372A:              @ v2.05 0x0802372A, reached from 0x08023724
    lsls    r0, r7, #0x10                   @ 0802372A r0 = r7 << 0x10
    bpl     .Lsd_cmd_resp1_error_3732       @ 0802372C if (r0 >=0 0) goto 0x8023732
    movs    r0, #0x17                       @ 0802372E r0 = 0x17
    b       .Lsd_cmd_resp1_error_374E       @ 08023730 goto 0x802374E
.Lsd_cmd_resp1_error_3732:              @ v2.05 0x08023732, reached from 0x0802372C
    lsls    r0, r7, #0x11                   @ 08023732 r0 = r7 << 0x11
    bpl     .Lsd_cmd_resp1_error_373A       @ 08023734 if (r0 >=0 0) goto 0x802373A
    movs    r0, #0x18                       @ 08023736 r0 = 0x18
    b       .Lsd_cmd_resp1_error_374E       @ 08023738 goto 0x802374E
.Lsd_cmd_resp1_error_373A:              @ v2.05 0x0802373A, reached from 0x08023734
    lsls    r0, r7, #0x12                   @ 0802373A r0 = r7 << 0x12
    bpl     .Lsd_cmd_resp1_error_3742       @ 0802373C if (r0 >=0 0) goto 0x8023742
    movs    r0, #0x19                       @ 0802373E r0 = 0x19
    b       .Lsd_cmd_resp1_error_374E       @ 08023740 goto 0x802374E
.Lsd_cmd_resp1_error_3742:              @ v2.05 0x08023742, reached from 0x0802373C
    lsls    r0, r7, #0x1c                   @ 08023742 r0 = r7 << 0x1c
    bpl     .Lsd_cmd_resp1_error_374A       @ 08023744 if (r0 >=0 0) goto 0x802374A
    movs    r0, #0x1a                       @ 08023746 r0 = 0x1a
    b       .Lsd_cmd_resp1_error_374E       @ 08023748 goto 0x802374E
.Lsd_cmd_resp1_error_374A:              @ v2.05 0x0802374A, reached from 0x08023744
    movs    r0, r5                          @ 0802374A r0 = r5
    uxtb    r0, r0                          @ 0802374C r0 = u8(r0)
.Lsd_cmd_resp1_error_374E:              @ v2.05 0x0802374E, reached from 0x08023654, 0x08023668, 0x0802367C, 0x08023692, 0x080236B0, 0x080236B8, 0x080236C0, 0x080236C8, 0x080236D0, 0x080236D8, 0x080236E0, 0x080236E8, 0x080236F0, 0x080236F8, 0x08023700, 0x08023708, 0x08023710, 0x08023718, 0x08023720, 0x08023728, 0x08023730, 0x08023738, 0x08023740, 0x08023748
    pop.w   {r4, r5, r6, r7, r8, pc}        @ 0802374E pop {r4, r5, r6, r7, r8, pc}
ENDFUNC sd_cmd_resp1_error
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_cmd_resp3_error - wait for the answer R3 (ACMD41; no CRC) (ST CmdResp3Error)
@ Replaces  : 0x08023752 FUN_08023752 (v2.05), called by sd_power_on
@ In        : -
@ Out       : r0 = 0 ok, 3 timeout
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08023752..0x080237A9; polls STA for 0x45 at most 20000 times; only CTIMEOUT is an error (the CRC of R3 is not valid)
@ -----------------------------------------------------------------------------
FUNC sd_cmd_resp3_error
    push    {r4, r5, r6, lr}                @ 08023752 push {r4, r5, r6, lr}
    movs    r4, #0                          @ 08023754 r4 = 0
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 08023756 r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 0802375A r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r5, r0                          @ 0802375C r5 = r0
    movw    r0, #0x4e20                     @ 0802375E
    movs    r6, r0                          @ 08023762 r6 = r0
.Lsd_cmd_resp3_error_3764:              @ v2.05 0x08023764, reached from 0x08023776
    tst.w   r5, #0x45                       @ 08023764 compare r5 with 0x45
    bne     .Lsd_cmd_resp3_error_3788       @ 08023768 if ((r5 & 0x45) != 0) goto 0x8023788
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 0802376A r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 0802376E r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r5, r0                          @ 08023770 r5 = r0
    subs    r6, r6, #1                      @ 08023772 r6 = r6 - 1
    cmp     r6, #0                          @ 08023774 compare r6 with 0
    bne     .Lsd_cmd_resp3_error_3764       @ 08023776 if (r6 != 0) goto 0x8023764
    movs    r0, #3                          @ 08023778 r0 = 3
    movs    r4, r0                          @ 0802377A r4 = r0
    movs    r0, #4                          @ 0802377C r0 = 4
    bl      sdio_clear_flag                 @ 0802377E call sdio_clear_flag
    movs    r0, r4                          @ 08023782 r0 = r4
    uxtb    r0, r0                          @ 08023784 r0 = u8(r0)
    b       .Lsd_cmd_resp3_error_37A8       @ 08023786 goto 0x80237A8
.Lsd_cmd_resp3_error_3788:              @ v2.05 0x08023788, reached from 0x08023768
    lsls    r0, r5, #0x1d                   @ 08023788 r0 = r5 << 0x1d
    bpl     .Lsd_cmd_resp3_error_379C       @ 0802378A if (r0 >=0 0) goto 0x802379C
    movs    r0, #3                          @ 0802378C r0 = 3
    movs    r4, r0                          @ 0802378E r4 = r0
    movs    r0, #4                          @ 08023790 r0 = 4
    bl      sdio_clear_flag                 @ 08023792 call sdio_clear_flag
    movs    r0, r4                          @ 08023796 r0 = r4
    uxtb    r0, r0                          @ 08023798 r0 = u8(r0)
    b       .Lsd_cmd_resp3_error_37A8       @ 0802379A goto 0x80237A8
.Lsd_cmd_resp3_error_379C:              @ v2.05 0x0802379C, reached from 0x0802378A
    movw    r0, #0x5ff                      @ 0802379C
    bl      sdio_clear_flag                 @ 080237A0 call sdio_clear_flag
    movs    r0, r4                          @ 080237A4 r0 = r4
    uxtb    r0, r0                          @ 080237A6 r0 = u8(r0)
.Lsd_cmd_resp3_error_37A8:              @ v2.05 0x080237A8, reached from 0x08023786, 0x0802379A
    pop     {r4, r5, r6, pc}                @ 080237A8 pop {r4, r5, r6, pc}
ENDFUNC sd_cmd_resp3_error
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_cmd_resp2_error - wait for the long answer R2 (CID, CSD) (ST CmdResp2Error)
@ Replaces  : 0x080237AA FUN_080237AA (v2.05), called by sd_init_cards
@ In        : -
@ Out       : r0 = 0 ok, 3 timeout, 1 command CRC fail
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080237AA..0x08023815; polls STA for 0x45 at most 20000 times
@ -----------------------------------------------------------------------------
FUNC sd_cmd_resp2_error
    push    {r4, r5, r6, lr}                @ 080237AA push {r4, r5, r6, lr}
    movs    r4, #0                          @ 080237AC r4 = 0
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 080237AE r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 080237B2 r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r5, r0                          @ 080237B4 r5 = r0
    movw    r0, #0x4e20                     @ 080237B6
    movs    r6, r0                          @ 080237BA r6 = r0
.Lsd_cmd_resp2_error_37BC:              @ v2.05 0x080237BC, reached from 0x080237CE
    tst.w   r5, #0x45                       @ 080237BC compare r5 with 0x45
    bne     .Lsd_cmd_resp2_error_37E0       @ 080237C0 if ((r5 & 0x45) != 0) goto 0x80237E0
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 080237C2 r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 080237C6 r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r5, r0                          @ 080237C8 r5 = r0
    subs    r6, r6, #1                      @ 080237CA r6 = r6 - 1
    cmp     r6, #0                          @ 080237CC compare r6 with 0
    bne     .Lsd_cmd_resp2_error_37BC       @ 080237CE if (r6 != 0) goto 0x80237BC
    movs    r0, #3                          @ 080237D0 r0 = 3
    movs    r4, r0                          @ 080237D2 r4 = r0
    movs    r0, #4                          @ 080237D4 r0 = 4
    bl      sdio_clear_flag                 @ 080237D6 call sdio_clear_flag
    movs    r0, r4                          @ 080237DA r0 = r4
    uxtb    r0, r0                          @ 080237DC r0 = u8(r0)
    b       .Lsd_cmd_resp2_error_3814       @ 080237DE goto 0x8023814
.Lsd_cmd_resp2_error_37E0:              @ v2.05 0x080237E0, reached from 0x080237C0
    lsls    r0, r5, #0x1d                   @ 080237E0 r0 = r5 << 0x1d
    bpl     .Lsd_cmd_resp2_error_37F4       @ 080237E2 if (r0 >=0 0) goto 0x80237F4
    movs    r0, #3                          @ 080237E4 r0 = 3
    movs    r4, r0                          @ 080237E6 r4 = r0
    movs    r0, #4                          @ 080237E8 r0 = 4
    bl      sdio_clear_flag                 @ 080237EA call sdio_clear_flag
    movs    r0, r4                          @ 080237EE r0 = r4
    uxtb    r0, r0                          @ 080237F0 r0 = u8(r0)
    b       .Lsd_cmd_resp2_error_3814       @ 080237F2 goto 0x8023814
.Lsd_cmd_resp2_error_37F4:              @ v2.05 0x080237F4, reached from 0x080237E2
    lsls    r0, r5, #0x1f                   @ 080237F4 r0 = r5 << 0x1f
    bpl     .Lsd_cmd_resp2_error_3808       @ 080237F6 if (r0 >=0 0) goto 0x8023808
    movs    r0, #1                          @ 080237F8 r0 = 1
    movs    r4, r0                          @ 080237FA r4 = r0
    movs    r0, #1                          @ 080237FC r0 = 1
    bl      sdio_clear_flag                 @ 080237FE call sdio_clear_flag
    movs    r0, r4                          @ 08023802 r0 = r4
    uxtb    r0, r0                          @ 08023804 r0 = u8(r0)
    b       .Lsd_cmd_resp2_error_3814       @ 08023806 goto 0x8023814
.Lsd_cmd_resp2_error_3808:              @ v2.05 0x08023808, reached from 0x080237F6
    movw    r0, #0x5ff                      @ 08023808
    bl      sdio_clear_flag                 @ 0802380C call sdio_clear_flag
    movs    r0, r4                          @ 08023810 r0 = r4
    uxtb    r0, r0                          @ 08023812 r0 = u8(r0)
.Lsd_cmd_resp2_error_3814:              @ v2.05 0x08023814, reached from 0x080237DE, 0x080237F2, 0x08023806
    pop     {r4, r5, r6, pc}                @ 08023814 pop {r4, r5, r6, pc}
ENDFUNC sd_cmd_resp2_error
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_cmd_resp6_error - wait for the answer R6 of command r0 and extract the RCA (ST CmdResp6Error)
@ Replaces  : 0x0802381C FUN_0802381C (v2.05), called by sd_init_cards
@ In        : r0 = command index (3), r1 = pointer that receives the RCA (u16)
@ Out       : r0 = 0 ok, 3 timeout, 1 CRC fail, 0x10 wrong command index, 0x13 general error, 0x10 illegal command, 0xF CRC error of the status bits
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802381C..0x080238E1
@ Note      : the R6 status bits tested are 15 (COM_CRC_ERROR), 14 (ILLEGAL_CMD) and 13 (GENERAL_UNKNOWN_ERROR) (mask 0xE000); with none set the RCA is bits 31..16.
@ -----------------------------------------------------------------------------
FUNC sd_cmd_resp6_error
    push.w  {r3, r4, r5, r6, r7, r8, r9, lr}@ 0802381C push {r3, r4, r5, r6, r7, r8, r9, lr}
    movs    r4, r0                          @ 08023820 r4 = r0
    movs    r5, r1                          @ 08023822 r5 = r1
    movs    r6, #0                          @ 08023824 r6 = 0
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 08023826 r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 0802382A r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r7, r0                          @ 0802382C r7 = r0
    movw    r0, #0x4e20                     @ 0802382E
    mov     r9, r0                          @ 08023832 r9 = r0
.Lsd_cmd_resp6_error_3834:              @ v2.05 0x08023834, reached from 0x0802384A
    tst.w   r7, #0x45                       @ 08023834 compare r7 with 0x45
    bne     .Lsd_cmd_resp6_error_385C       @ 08023838 if ((r7 & 0x45) != 0) goto 0x802385C
    ldr.w   r0, =(SDIO_BASE + SDIO_STA)     @ 0802383A r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 0802383E r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movs    r7, r0                          @ 08023840 r7 = r0
    subs.w  r9, r9, #1                      @ 08023842 r9 = r9 - 1
    cmp.w   r9, #0                          @ 08023846 compare r9 with 0
    bne     .Lsd_cmd_resp6_error_3834       @ 0802384A if (r9 != 0) goto 0x8023834
    movs    r0, #3                          @ 0802384C r0 = 3
    movs    r6, r0                          @ 0802384E r6 = r0
    movs    r0, #4                          @ 08023850 r0 = 4
    bl      sdio_clear_flag                 @ 08023852 call sdio_clear_flag
    movs    r0, r6                          @ 08023856 r0 = r6
    uxtb    r0, r0                          @ 08023858 r0 = u8(r0)
    b       .Lsd_cmd_resp6_error_38DE       @ 0802385A goto 0x80238DE
.Lsd_cmd_resp6_error_385C:              @ v2.05 0x0802385C, reached from 0x08023838
    lsls    r0, r7, #0x1d                   @ 0802385C r0 = r7 << 0x1d
    bpl     .Lsd_cmd_resp6_error_3870       @ 0802385E if (r0 >=0 0) goto 0x8023870
    movs    r0, #3                          @ 08023860 r0 = 3
    movs    r6, r0                          @ 08023862 r6 = r0
    movs    r0, #4                          @ 08023864 r0 = 4
    bl      sdio_clear_flag                 @ 08023866 call sdio_clear_flag
    movs    r0, r6                          @ 0802386A r0 = r6
    uxtb    r0, r0                          @ 0802386C r0 = u8(r0)
    b       .Lsd_cmd_resp6_error_38DE       @ 0802386E goto 0x80238DE
.Lsd_cmd_resp6_error_3870:              @ v2.05 0x08023870, reached from 0x0802385E
    lsls    r0, r7, #0x1f                   @ 08023870 r0 = r7 << 0x1f
    bpl     .Lsd_cmd_resp6_error_3884       @ 08023872 if (r0 >=0 0) goto 0x8023884
    movs    r0, #1                          @ 08023874 r0 = 1
    movs    r6, r0                          @ 08023876 r6 = r0
    movs    r0, #1                          @ 08023878 r0 = 1
    bl      sdio_clear_flag                 @ 0802387A call sdio_clear_flag
    movs    r0, r6                          @ 0802387E r0 = r6
    uxtb    r0, r0                          @ 08023880 r0 = u8(r0)
    b       .Lsd_cmd_resp6_error_38DE       @ 08023882 goto 0x80238DE
.Lsd_cmd_resp6_error_3884:              @ v2.05 0x08023884, reached from 0x08023872
    bl      sdio_get_command_response       @ 08023884 call sdio_get_command_response
    movs    r1, r4                          @ 08023888 r1 = r4
    uxtb    r1, r1                          @ 0802388A r1 = u8(r1)
    cmp     r0, r1                          @ 0802388C compare r0 with r1
    beq     .Lsd_cmd_resp6_error_389A       @ 0802388E if (r0 == r1) goto 0x802389A
    movs    r0, #0x10                       @ 08023890 r0 = 0x10
    movs    r6, r0                          @ 08023892 r6 = r0
    movs    r0, r6                          @ 08023894 r0 = r6
    uxtb    r0, r0                          @ 08023896 r0 = u8(r0)
    b       .Lsd_cmd_resp6_error_38DE       @ 08023898 goto 0x80238DE
.Lsd_cmd_resp6_error_389A:              @ v2.05 0x0802389A, reached from 0x0802388E
    movw    r0, #0x5ff                      @ 0802389A
    bl      sdio_clear_flag                 @ 0802389E call sdio_clear_flag
    movs    r0, #0                          @ 080238A2 r0 = 0
    bl      sdio_get_response               @ 080238A4 call sdio_get_response
    mov     r8, r0                          @ 080238A8 r8 = r0
    tst.w   r8, #0xe000                     @ 080238AA compare r8 with 0xe000
    bne     .Lsd_cmd_resp6_error_38BC       @ 080238AE if ((r8 & 0xe000) != 0) goto 0x80238BC
    lsrs.w  r0, r8, #0x10                   @ 080238B0 r0 = r8 >> 0x10
    strh    r0, [r5]                        @ 080238B4 u16 [r5] = r0
    movs    r0, r6                          @ 080238B6 r0 = r6
    uxtb    r0, r0                          @ 080238B8 r0 = u8(r0)
    b       .Lsd_cmd_resp6_error_38DE       @ 080238BA goto 0x80238DE
.Lsd_cmd_resp6_error_38BC:              @ v2.05 0x080238BC, reached from 0x080238AE
    lsls.w  r0, r8, #0x12                   @ 080238BC r0 = r8 << 0x12
    bpl     .Lsd_cmd_resp6_error_38C6       @ 080238C0 if (r0 >=0 0) goto 0x80238C6
    movs    r0, #0x13                       @ 080238C2 r0 = 0x13
    b       .Lsd_cmd_resp6_error_38DE       @ 080238C4 goto 0x80238DE
.Lsd_cmd_resp6_error_38C6:              @ v2.05 0x080238C6, reached from 0x080238C0
    lsls.w  r0, r8, #0x11                   @ 080238C6 r0 = r8 << 0x11
    bpl     .Lsd_cmd_resp6_error_38D0       @ 080238CA if (r0 >=0 0) goto 0x80238D0
    movs    r0, #0x10                       @ 080238CC r0 = 0x10
    b       .Lsd_cmd_resp6_error_38DE       @ 080238CE goto 0x80238DE
.Lsd_cmd_resp6_error_38D0:              @ v2.05 0x080238D0, reached from 0x080238CA
    lsls.w  r0, r8, #0x10                   @ 080238D0 r0 = r8 << 0x10
    bpl     .Lsd_cmd_resp6_error_38DA       @ 080238D4 if (r0 >=0 0) goto 0x80238DA
    movs    r0, #0xf                        @ 080238D6 r0 = 0xf
    b       .Lsd_cmd_resp6_error_38DE       @ 080238D8 goto 0x80238DE
.Lsd_cmd_resp6_error_38DA:              @ v2.05 0x080238DA, reached from 0x080238D4
    movs    r0, r6                          @ 080238DA r0 = r6
    uxtb    r0, r0                          @ 080238DC r0 = u8(r0)
.Lsd_cmd_resp6_error_38DE:              @ v2.05 0x080238DE, reached from 0x0802385A, 0x0802386E, 0x08023882, 0x08023898, 0x080238BA, 0x080238C4, 0x080238CE, 0x080238D8
    pop.w   {r1, r4, r5, r6, r7, r8, r9, pc}@ 080238DE pop {r1, r4, r5, r6, r7, r8, r9, pc}
ENDFUNC sd_cmd_resp6_error
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_enable_wide_bus - switch the card to a bus width with ACMD6 (ST SD_EnWideBus)
@ Replaces  : 0x080238F0 FUN_080238F0 (v2.05), called by sd_set_bus_width
@ In        : r0 = 1 for 4 bits (ACMD6 argument 2), 0 for 1 bit (argument 0)
@ Out       : r0 = 0 ok, 0xE card is locked, 0x25 the SCR does not allow the width, or the SD error of the commands
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080238F0..0x08023A8B; PLS 2.00 4.3.10 (ACMD6), 5.6 (SCR)
@ Note      : the card status word (CMD13-like read of the response) must not show the card locked (bit 25); the SCR is read
@             (sd_find_scr) and tested for the 4-bit (bit 18) or 1-bit (bit 16) bus width support; then CMD55 with the RCA and ACMD6.
@ -----------------------------------------------------------------------------
FUNC sd_enable_wide_bus
    push    {r4, r5, lr}                    @ 080238F0 push {r4, r5, lr}
    sub     sp, #0xc                        @ 080238F2 sp -= 0xc
    movs    r4, r0                          @ 080238F4 r4 = r0
    movs    r5, #0                          @ 080238F6 r5 = 0
    mov     r0, sp                          @ 080238F8 r0 = sp
    movs    r1, #0                          @ 080238FA r1 = 0
    movs    r2, #0                          @ 080238FC r2 = 0
    strd    r1, r2, [r0]                    @ 080238FE
    movs    r0, #0                          @ 08023902 r0 = 0
    @ response word 0 bit 25 = card locked: error 0xE
    bl      sdio_get_response               @ 08023904 call sdio_get_response
    lsls    r0, r0, #6                      @ 08023908 r0 = r0 << 6
    bpl     .Lsd_enable_wide_bus_3916       @ 0802390A if (r0 >=0 0) goto 0x8023916
    movs    r0, #0xe                        @ 0802390C r0 = 0xe
    movs    r5, r0                          @ 0802390E r5 = r0
    movs    r0, r5                          @ 08023910 r0 = r5
    uxtb    r0, r0                          @ 08023912 r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 08023914 goto 0x8023A86
.Lsd_enable_wide_bus_3916:              @ v2.05 0x08023916, reached from 0x0802390A
    mov     r1, sp                          @ 08023916 r1 = sp
    ldr.w   r0, =sd_rca                     @ 08023918 r0 = &sd_rca
    ldr     r0, [r0]                        @ 0802391C r0 = u32 [sd_rca]
    uxth    r0, r0                          @ 0802391E r0 = u16(r0)
    @ read the SCR (sd_find_scr)
    bl      sd_find_scr                     @ 08023920 call sd_find_scr
    movs    r5, r0                          @ 08023924 r5 = r0
    uxtb    r5, r5                          @ 08023926 r5 = u8(r5)
    cmp     r5, #0                          @ 08023928 compare r5 with 0
    beq     .Lsd_enable_wide_bus_3932       @ 0802392A if (r5 == 0) goto 0x8023932
    movs    r0, r5                          @ 0802392C r0 = r5
    uxtb    r0, r0                          @ 0802392E r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 08023930 goto 0x8023A86
.Lsd_enable_wide_bus_3932:              @ v2.05 0x08023932, reached from 0x0802392A
    uxtb    r4, r4                          @ 08023932 r4 = u8(r4)
    @ r4 = 1 (4-bit): the SCR must announce 4-bit support (SCR word 1 bit 18, 3938); r4 = 0 (1-bit): bit 16 (39E4); else 0x25
    cmp     r4, #1                          @ 08023934 compare r4 with 1
    bne     .Lsd_enable_wide_bus_39E0       @ 08023936 if (r4 != 1) goto 0x80239E0
    ldr     r0, [sp, #4]                    @ 08023938 r0 = u32 [sp+0x4]
    lsls    r0, r0, #0xd                    @ 0802393A r0 = r0 << 0xd
    bpl     .Lsd_enable_wide_bus_39D6       @ 0802393C if (r0 >=0 0) goto 0x80239D6
    ldr.w   r0, =sd_rca                     @ 0802393E r0 = &sd_rca
    ldr     r0, [r0]                        @ 08023942 r0 = u32 [sd_rca]
    lsls    r0, r0, #0x10                   @ 08023944 r0 = r0 << 0x10
    ldr.w   r1, =sdio_cmd_struct            @ 08023946 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 0802394A u32 [sdio_cmd_struct] = r0
    movs    r0, #0x37                       @ 0802394C r0 = 0x37
    ldr.w   r1, =sdio_cmd_struct            @ 0802394E r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023952 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08023954 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 08023956 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 0802395A u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 0802395C r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 0802395E r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08023962 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08023964 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08023968 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 0802396C u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 0802396E r0 = &sdio_cmd_struct
    @ CMD55 with the RCA
    bl      sdio_send_command               @ 08023972 call sdio_send_command
    movs    r0, #0x37                       @ 08023976 r0 = 0x37
    bl      sd_cmd_resp1_error              @ 08023978 call sd_cmd_resp1_error
    movs    r5, r0                          @ 0802397C r5 = r0
    uxtb    r5, r5                          @ 0802397E r5 = u8(r5)
    cmp     r5, #0                          @ 08023980 compare r5 with 0
    beq     .Lsd_enable_wide_bus_398A       @ 08023982 if (r5 == 0) goto 0x802398A
    movs    r0, r5                          @ 08023984 r0 = r5
    uxtb    r0, r0                          @ 08023986 r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 08023988 goto 0x8023A86
.Lsd_enable_wide_bus_398A:              @ v2.05 0x0802398A, reached from 0x08023982
    movs    r0, #2                          @ 0802398A r0 = 2
    ldr.w   r1, =sdio_cmd_struct            @ 0802398C r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08023990 u32 [sdio_cmd_struct] = r0
    movs    r0, #6                          @ 08023992 r0 = 6
    ldr.w   r1, =sdio_cmd_struct            @ 08023994 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023998 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 0802399A r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 0802399C r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 080239A0 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 080239A2 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 080239A4 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 080239A8 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 080239AA r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 080239AE r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 080239B2 u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 080239B4 r0 = &sdio_cmd_struct
    @ ACMD6 (index 6) with argument 2 (4 bits)
    bl      sdio_send_command               @ 080239B8 call sdio_send_command
    movs    r0, #6                          @ 080239BC r0 = 6
    bl      sd_cmd_resp1_error              @ 080239BE call sd_cmd_resp1_error
    movs    r5, r0                          @ 080239C2 r5 = r0
    uxtb    r5, r5                          @ 080239C4 r5 = u8(r5)
    cmp     r5, #0                          @ 080239C6 compare r5 with 0
    beq     .Lsd_enable_wide_bus_39D0       @ 080239C8 if (r5 == 0) goto 0x80239D0
    movs    r0, r5                          @ 080239CA r0 = r5
    uxtb    r0, r0                          @ 080239CC r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 080239CE goto 0x8023A86
.Lsd_enable_wide_bus_39D0:              @ v2.05 0x080239D0, reached from 0x080239C8
    movs    r0, r5                          @ 080239D0 r0 = r5
    uxtb    r0, r0                          @ 080239D2 r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 080239D4 goto 0x8023A86
.Lsd_enable_wide_bus_39D6:              @ v2.05 0x080239D6, reached from 0x0802393C
    movs    r0, #0x25                       @ 080239D6 r0 = 0x25
    movs    r5, r0                          @ 080239D8 r5 = r0
    movs    r0, r5                          @ 080239DA r0 = r5
    uxtb    r0, r0                          @ 080239DC r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 080239DE goto 0x8023A86
.Lsd_enable_wide_bus_39E0:              @ v2.05 0x080239E0, reached from 0x08023936
    ldr     r0, [sp, #4]                    @ 080239E0 r0 = u32 [sp+0x4]
    lsls    r0, r0, #0xf                    @ 080239E2 r0 = r0 << 0xf
    bpl     .Lsd_enable_wide_bus_3A7E       @ 080239E4 if (r0 >=0 0) goto 0x8023A7E
    ldr.w   r0, =sd_rca                     @ 080239E6 r0 = &sd_rca
    ldr     r0, [r0]                        @ 080239EA r0 = u32 [sd_rca]
    lsls    r0, r0, #0x10                   @ 080239EC r0 = r0 << 0x10
    ldr.w   r1, =sdio_cmd_struct            @ 080239EE r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 080239F2 u32 [sdio_cmd_struct] = r0
    movs    r0, #0x37                       @ 080239F4 r0 = 0x37
    ldr.w   r1, =sdio_cmd_struct            @ 080239F6 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 080239FA u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 080239FC r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 080239FE r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023A02 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08023A04 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08023A06 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08023A0A u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08023A0C r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08023A10 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08023A14 u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08023A16 r0 = &sdio_cmd_struct
    @ CMD55 with the RCA
    bl      sdio_send_command               @ 08023A1A call sdio_send_command
    movs    r0, #0x37                       @ 08023A1E r0 = 0x37
    bl      sd_cmd_resp1_error              @ 08023A20 call sd_cmd_resp1_error
    movs    r5, r0                          @ 08023A24 r5 = r0
    uxtb    r5, r5                          @ 08023A26 r5 = u8(r5)
    cmp     r5, #0                          @ 08023A28 compare r5 with 0
    beq     .Lsd_enable_wide_bus_3A32       @ 08023A2A if (r5 == 0) goto 0x8023A32
    movs    r0, r5                          @ 08023A2C r0 = r5
    uxtb    r0, r0                          @ 08023A2E r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 08023A30 goto 0x8023A86
.Lsd_enable_wide_bus_3A32:              @ v2.05 0x08023A32, reached from 0x08023A2A
    movs    r0, #0                          @ 08023A32 r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08023A34 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08023A38 u32 [sdio_cmd_struct] = r0
    movs    r0, #6                          @ 08023A3A r0 = 6
    ldr.w   r1, =sdio_cmd_struct            @ 08023A3C r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023A40 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08023A42 r0 = 0x40
    ldr.w   r1, =sdio_cmd_struct            @ 08023A44 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023A48 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08023A4A r0 = 0
    ldr.w   r1, =sdio_cmd_struct            @ 08023A4C r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08023A50 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08023A52 r0 = 0x400
    ldr.w   r1, =sdio_cmd_struct            @ 08023A56 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08023A5A u32 [sdio_cmd_struct+0x10] = r0
    ldr.w   r0, =sdio_cmd_struct            @ 08023A5C r0 = &sdio_cmd_struct
    @ ACMD6 with argument 0 (1 bit)
    bl      sdio_send_command               @ 08023A60 call sdio_send_command
    movs    r0, #6                          @ 08023A64 r0 = 6
    bl      sd_cmd_resp1_error              @ 08023A66 call sd_cmd_resp1_error
    movs    r5, r0                          @ 08023A6A r5 = r0
    uxtb    r5, r5                          @ 08023A6C r5 = u8(r5)
    cmp     r5, #0                          @ 08023A6E compare r5 with 0
    beq     .Lsd_enable_wide_bus_3A78       @ 08023A70 if (r5 == 0) goto 0x8023A78
    movs    r0, r5                          @ 08023A72 r0 = r5
    uxtb    r0, r0                          @ 08023A74 r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 08023A76 goto 0x8023A86
.Lsd_enable_wide_bus_3A78:              @ v2.05 0x08023A78, reached from 0x08023A70
    movs    r0, r5                          @ 08023A78 r0 = r5
    uxtb    r0, r0                          @ 08023A7A r0 = u8(r0)
    b       .Lsd_enable_wide_bus_3A86       @ 08023A7C goto 0x8023A86
.Lsd_enable_wide_bus_3A7E:              @ v2.05 0x08023A7E, reached from 0x080239E4
    movs    r0, #0x25                       @ 08023A7E r0 = 0x25
    movs    r5, r0                          @ 08023A80 r5 = r0
    movs    r0, r5                          @ 08023A82 r0 = r5
    uxtb    r0, r0                          @ 08023A84 r0 = u8(r0)
.Lsd_enable_wide_bus_3A86:              @ v2.05 0x08023A86, reached from 0x08023914, 0x08023930, 0x08023988, 0x080239CE, 0x080239D4, 0x080239DE, 0x08023A30, 0x08023A76, 0x08023A7C
    pop     {r1, r2, r3, r4, r5, pc}        @ 08023A86 pop {r1, r2, r3, r4, r5, pc}
ENDFUNC sd_enable_wide_bus
    .ltorg

    .if !SD_READ_ONLY                       @ the card write path (not in the read-only bootloader build)
@ -----------------------------------------------------------------------------
@ sd_cmd_r1 - send a command with a short response (R1) and check it (sd_cmd_resp1_error, all static flags cleared)
@ In        : r0 = argument, r1 = command index
@ Out       : r0 = SD error code (0 = R1 without error bits)
@ Clobbers  : r0-r3, r12, flags (r4 saved)
@ Context   : main only
@ -----------------------------------------------------------------------------
LFUNC sd_cmd_r1
    push    {r4, lr}
    mov     r4, r1
    ldr     r2, =sdio_cmd_struct
    str     r0, [r2]                        @ argument
    str     r1, [r2, #4]                    @ command index
    movs    r0, #0x40
    str     r0, [r2, #8]                    @ short response
    movs    r0, #0
    str     r0, [r2, #0xc]                  @ no wait for interrupt
    mov.w   r0, #0x400
    str     r0, [r2, #0x10]                 @ CPSM on
    mov     r0, r2
    bl      sdio_send_command
    mov     r0, r4
    bl      sd_cmd_resp1_error
    uxtb    r0, r0
    pop     {r4, pc}
ENDFUNC sd_cmd_r1

@ -----------------------------------------------------------------------------
@ sd_num_wr_blocks - ACMD22 SEND_NUM_WR_BLOCKS: how many blocks the last write command wrote without error (IMP-40)
@ Out       : r0 = SD error code (0 = the card answered), r1 = the number of blocks (the 32-bit value, MSB first on DAT0)
@ Clobbers  : r0-r3, r12, flags (r4-r8 preserved)
@ Context   : main only (disk_write, after a write whose busy wait ran out; the card is back in the transfer state)
@ Spec      : SD Physical Layer Simplified 2.00, 4.3.4 (the host can ask with ACMD22 how many blocks were written correctly
@             after an error), table 4-27 (ACMD22, R1, 32 bits on the data line).  Built as sd_find_scr (ACMD51): CMD16 with
@             the length 4, CMD55, the data path for 4 bytes card to host, ACMD22 with only the command flags cleared
@             (IMP-34), the FIFO read until DBCKEND and a word still in the FIFO after it; then all flags cleared and CMD16
@             512 again (the block length every read and write of the driver assumes).
@ -----------------------------------------------------------------------------
FUNC sd_num_wr_blocks
    push    {r4, r5, r6, r7, r8, lr}
    movs    r6, #0                          @ words read
    movs    r7, #0                          @ the raw word of the answer
    movs    r0, #4
    movs    r1, #0x10
    bl      sd_cmd_r1                       @ CMD16 SET_BLOCKLEN 4
    mov     r4, r0
    cmp     r0, #0
    bne     8f
    ldr     r0, =sd_rca
    ldr     r0, [r0]
    lsls    r0, r0, #0x10
    movs    r1, #0x37
    bl      sd_cmd_r1                       @ CMD55 APP_CMD with the RCA
    mov     r4, r0
    cmp     r0, #0
    bne     8f
    ldr     r1, =sdio_data_struct
    movs.w  r0, #-1
    str     r0, [r1]                        @ data timeout: the largest
    movs    r0, #4
    str     r0, [r1, #4]                    @ 4 bytes
    movs    r0, #0x20
    str     r0, [r1, #8]                    @ block size 2^2
    movs    r0, #2
    str     r0, [r1, #0xc]                  @ card to host
    movs    r0, #0
    str     r0, [r1, #0x10]                 @ block mode
    movs    r0, #1
    str     r0, [r1, #0x14]                 @ DPSM on
    ldr     r0, =sdio_data_struct
    bl      sdio_data_config
    ldr     r2, =sdio_cmd_struct
    movs    r0, #0
    str     r0, [r2]
    movs    r0, #0x16
    str     r0, [r2, #4]                    @ ACMD22
    movs    r0, #0x40
    str     r0, [r2, #8]
    movs    r0, #0
    str     r0, [r2, #0xc]
    mov.w   r0, #0x400
    str     r0, [r2, #0x10]
    mov     r0, r2
    bl      sdio_send_command
    movs    r0, #0x16
    movs    r1, #0xc5                       @ only the command flags: the data block can already be in (IMP-34)
    bl      sd_cmd_resp1_keep
    uxtb    r4, r0
    cmp     r4, #0
    bne     8f
    movw    r8, #0x4e20                     @ 20000 polls, as the SCR read
1:  ldr     r0, =(SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]
    movw    r1, #0x62a                      @ DCRCFAIL, DTIMEOUT, RXOVERR, STBITERR, DBCKEND
    tst     r0, r1
    bne     2f
    tst     r0, #0x200000                   @ RXDAVL: a word in the receive FIFO
    beq     3f
    bl      sdio_read_data
    cbnz    r6, 4f
    mov     r7, r0                          @ the first (only) word
4:  adds    r6, r6, #1
3:  subs    r8, r8, #1
    bne     1b
    movs    r4, #4                          @ no block end: timeout
    b       8f
2:  movw    r1, #0x22a                      @ DCRCFAIL, DTIMEOUT, RXOVERR, STBITERR
    tst     r0, r1
    beq     5f
    movs    r4, #2                          @ data error
    b       8f
5:  cbnz    r6, 8f                          @ the word was read in the loop
    ldr     r0, =(SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]
    tst     r0, #0x200000
    beq     6f
    bl      sdio_read_data
    mov     r7, r0
    adds    r6, r6, #1
    b       8f
6:  movs    r4, #4                          @ block end without the word
8:  movw    r0, #0x5ff
    bl      sdio_clear_flag
    mov.w   r0, #0x200
    movs    r1, #0x10
    bl      sd_cmd_r1                       @ CMD16 512 again
    cbnz    r4, 9f
    mov     r4, r0                          @ its error, when everything before went well
9:  rev     r1, r7                          @ the count, MSB first on the bus
    mov     r0, r4
    pop     {r4, r5, r6, r7, r8, pc}
ENDFUNC sd_num_wr_blocks
    .ltorg
    .endif                                  @ !SD_READ_ONLY

@ -----------------------------------------------------------------------------
@ sd_find_scr - read the 8-byte SCR register of the card by polling the FIFO (ST FindSCR)
@ Replaces  : 0x08023A8C FUN_08023A8C (v2.05), called by sd_enable_wide_bus
@ In        : r0 = RCA, r1 = pointer to two words that receive the SCR (byte swapped)
@ Out       : r0 = 0 ok, 4 data timeout, 2 CRC fail, 6 RX overrun, 7 start bit error, or the SD error of a command
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08023A8C..0x08023C7F; PLS 2.00 5.6 (SCR), ACMD51
@ Note      : CMD16 with 8, CMD55 with the RCA, a data path for 8 bytes card to host (DTIMER 0xFFFFFFFF), ACMD51 (command 0x33); the
@             FIFO is read word by word while no error/end flag (mask 0x62A) is set, at most 20000 polls; the two words are byte
@             swapped into the result.
@ Deviation : IMP-34 (production): the answer of ACMD51 is checked without clearing the data flags (sd_cmd_resp1_keep with
@             0xC5), and after the block end the words still in the receive FIFO are read (v2.05 returned zeros for them, and
@             a zero SCR fails the start-up with 0x25); the reads are counted (sd_dg_scrs, sd_dg_scr0, sd_dg_scr1).
@ -----------------------------------------------------------------------------
FUNC sd_find_scr
    push.w  {r2, r3, r4, r5, r6, r7, r8, lr}@ 08023A8C push {r2, r3, r4, r5, r6, r7, r8, lr}
    movs    r4, r0                          @ 08023A90 r4 = r0
    movs    r5, r1                          @ 08023A92 r5 = r1
    movs    r6, #0                          @ 08023A94 r6 = 0
    movs    r7, #0                          @ 08023A96 r7 = 0
    mov     r0, sp                          @ 08023A98 r0 = sp
    movs    r1, #0                          @ 08023A9A r1 = 0
    movs    r2, #0                          @ 08023A9C r2 = 0
    strd    r1, r2, [r0]                    @ 08023A9E
    movs    r0, #8                          @ 08023AA2 r0 = 8
    ldr     r1, =sdio_cmd_struct            @ 08023AA4 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08023AA6 u32 [sdio_cmd_struct] = r0
    movs    r0, #0x10                       @ 08023AA8 r0 = 0x10
    ldr     r1, =sdio_cmd_struct            @ 08023AAA r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023AAC u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08023AAE r0 = 0x40
    ldr     r1, =sdio_cmd_struct            @ 08023AB0 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023AB2 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08023AB4 r0 = 0
    ldr     r1, =sdio_cmd_struct            @ 08023AB6 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08023AB8 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08023ABA r0 = 0x400
    ldr     r1, =sdio_cmd_struct            @ 08023ABE r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08023AC0 u32 [sdio_cmd_struct+0x10] = r0
    ldr     r0, =sdio_cmd_struct            @ 08023AC2 r0 = &sdio_cmd_struct
    @ CMD16 (block length 8)
    bl      sdio_send_command               @ 08023AC4 call sdio_send_command
    movs    r0, #0x10                       @ 08023AC8 r0 = 0x10
    bl      sd_cmd_resp1_error              @ 08023ACA call sd_cmd_resp1_error
    movs    r7, r0                          @ 08023ACE r7 = r0
    uxtb    r7, r7                          @ 08023AD0 r7 = u8(r7)
    cmp     r7, #0                          @ 08023AD2 compare r7 with 0
    beq     .Lsd_find_scr_3ADC              @ 08023AD4 if (r7 == 0) goto 0x8023ADC
    movs    r0, r7                          @ 08023AD6 r0 = r7
    uxtb    r0, r0                          @ 08023AD8 r0 = u8(r0)
    b       .Lsd_find_scr_3C7C              @ 08023ADA goto 0x8023C7C
.Lsd_find_scr_3ADC:                     @ v2.05 0x08023ADC, reached from 0x08023AD4
    ldr     r0, =sd_rca                     @ 08023ADC r0 = &sd_rca
    ldr     r0, [r0]                        @ 08023ADE r0 = u32 [sd_rca]
    lsls    r0, r0, #0x10                   @ 08023AE0 r0 = r0 << 0x10
    ldr     r1, =sdio_cmd_struct            @ 08023AE2 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08023AE4 u32 [sdio_cmd_struct] = r0
    movs    r0, #0x37                       @ 08023AE6 r0 = 0x37
    ldr     r1, =sdio_cmd_struct            @ 08023AE8 r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023AEA u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08023AEC r0 = 0x40
    ldr     r1, =sdio_cmd_struct            @ 08023AEE r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023AF0 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08023AF2 r0 = 0
    ldr     r1, =sdio_cmd_struct            @ 08023AF4 r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08023AF6 u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08023AF8 r0 = 0x400
    ldr     r1, =sdio_cmd_struct            @ 08023AFC r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08023AFE u32 [sdio_cmd_struct+0x10] = r0
    ldr     r0, =sdio_cmd_struct            @ 08023B00 r0 = &sdio_cmd_struct
    @ CMD55 (RCA)
    bl      sdio_send_command               @ 08023B02 call sdio_send_command
    movs    r0, #0x37                       @ 08023B06 r0 = 0x37
    bl      sd_cmd_resp1_error              @ 08023B08 call sd_cmd_resp1_error
    movs    r7, r0                          @ 08023B0C r7 = r0
    uxtb    r7, r7                          @ 08023B0E r7 = u8(r7)
    cmp     r7, #0                          @ 08023B10 compare r7 with 0
    beq     .Lsd_find_scr_3B1A              @ 08023B12 if (r7 == 0) goto 0x8023B1A
    movs    r0, r7                          @ 08023B14 r0 = r7
    uxtb    r0, r0                          @ 08023B16 r0 = u8(r0)
    b       .Lsd_find_scr_3C7C              @ 08023B18 goto 0x8023C7C
.Lsd_find_scr_3B1A:                     @ v2.05 0x08023B1A, reached from 0x08023B12
    movs.w  r0, #-1                         @ 08023B1A r0 = -1
    ldr     r1, =sdio_data_struct           @ 08023B1E r1 = &sdio_data_struct
    str     r0, [r1]                        @ 08023B20 u32 [sdio_data_struct] = r0
    movs    r0, #8                          @ 08023B22 r0 = 8
    ldr     r1, =sdio_data_struct           @ 08023B24 r1 = &sdio_data_struct
    str     r0, [r1, #4]                    @ 08023B26 u32 [sdio_data_struct+0x4] = r0
    movs    r0, #0x30                       @ 08023B28 r0 = 0x30
    ldr     r1, =sdio_data_struct           @ 08023B2A r1 = &sdio_data_struct
    str     r0, [r1, #8]                    @ 08023B2C u32 [sdio_data_struct+0x8] = r0
    movs    r0, #2                          @ 08023B2E r0 = 2
    ldr     r1, =sdio_data_struct           @ 08023B30 r1 = &sdio_data_struct
    str     r0, [r1, #0xc]                  @ 08023B32 u32 [sdio_data_struct+0xC] = r0
    movs    r0, #0                          @ 08023B34 r0 = 0
    ldr     r1, =sdio_data_struct           @ 08023B36 r1 = &sdio_data_struct
    str     r0, [r1, #0x10]                 @ 08023B38 u32 [sdio_data_struct+0x10] = r0
    movs    r0, #1                          @ 08023B3A r0 = 1
    ldr     r1, =sdio_data_struct           @ 08023B3C r1 = &sdio_data_struct
    str     r0, [r1, #0x14]                 @ 08023B3E u32 [sdio_data_struct+0x14] = r0
    ldr     r0, =sdio_data_struct           @ 08023B40 r0 = &sdio_data_struct
    @ data path: 8 bytes, 2^3, card to host
    bl      sdio_data_config                @ 08023B42 call sdio_data_config
    movs    r0, #0                          @ 08023B46 r0 = 0
    ldr     r1, =sdio_cmd_struct            @ 08023B48 r1 = &sdio_cmd_struct
    str     r0, [r1]                        @ 08023B4A u32 [sdio_cmd_struct] = r0
    movs    r0, #0x33                       @ 08023B4C r0 = 0x33
    ldr     r1, =sdio_cmd_struct            @ 08023B4E r1 = &sdio_cmd_struct
    str     r0, [r1, #4]                    @ 08023B50 u32 [sdio_cmd_struct+0x4] = r0
    movs    r0, #0x40                       @ 08023B52 r0 = 0x40
    ldr     r1, =sdio_cmd_struct            @ 08023B54 r1 = &sdio_cmd_struct
    str     r0, [r1, #8]                    @ 08023B56 u32 [sdio_cmd_struct+0x8] = r0
    movs    r0, #0                          @ 08023B58 r0 = 0
    ldr     r1, =sdio_cmd_struct            @ 08023B5A r1 = &sdio_cmd_struct
    str     r0, [r1, #0xc]                  @ 08023B5C u32 [sdio_cmd_struct+0xC] = r0
    mov.w   r0, #0x400                      @ 08023B5E r0 = 0x400
    ldr     r1, =sdio_cmd_struct            @ 08023B62 r1 = &sdio_cmd_struct
    str     r0, [r1, #0x10]                 @ 08023B64 u32 [sdio_cmd_struct+0x10] = r0
    ldr     r0, =sdio_cmd_struct            @ 08023B66 r0 = &sdio_cmd_struct
    @ ACMD51 (command 0x33, SEND_SCR)
    bl      sdio_send_command               @ 08023B68 call sdio_send_command
    movs    r0, #0x33                       @ 08023B6C r0 = 0x33
    @ IMP-34: clear only the command flags CCRCFAIL, CTIMEOUT, CMDREND, CMDSENT (0xC5).  v2.05 cleared 0x5FF here, which
    @ also wipes DBCKEND, DATAEND and the data error flags of an SCR block that is already in: the loop below then reads the
    @ two words and polls 20000 times for a flag that never comes (error 4)
    movs    r1, #0xc5
    bl      sd_cmd_resp1_keep               @ 08023B6E call sd_cmd_resp1_error (v2.05)
    movs    r7, r0                          @ 08023B72 r7 = r0
    uxtb    r7, r7                          @ 08023B74 r7 = u8(r7)
    cmp     r7, #0                          @ 08023B76 compare r7 with 0
    beq     .Lsd_find_scr_3B80              @ 08023B78 if (r7 == 0) goto 0x8023B80
    movs    r0, r7                          @ 08023B7A r0 = r7
    uxtb    r0, r0                          @ 08023B7C r0 = u8(r0)
    b       .Lsd_find_scr_3C7C              @ 08023B7E goto 0x8023C7C
.Lsd_find_scr_3B80:                     @ v2.05 0x08023B80, reached from 0x08023B78
    movw    r0, #0x4e20                     @ 08023B80
    mov     r8, r0                          @ 08023B84 r8 = r0
    @ poll loop: until DCRCFAIL|DTIMEOUT|RXOVERR|STBITERR|DBCKEND (0x62A) or 20000 polls; RXDAVL (bit 21) -> read a word
.Lsd_find_scr_3B86:                     @ v2.05 0x08023B86, reached from 0x08023BB2
    ldr     r0, =(SDIO_BASE + SDIO_STA)     @ 08023B86 r0 = (SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]                        @ 08023B88 r0 = u32 [(SDIO_BASE + SDIO_STA)]
    movw    r1, #0x62a                      @ 08023B8A
    tst     r0, r1                          @ 08023B8E compare r0 with r1
    bne     .Lsd_find_scr_3BC4              @ 08023B90 if ((r0 & r1) != 0) goto 0x8023BC4
    movs.w  r0, #0x200000                   @ 08023B92 r0 = 0x200000
    bl      sdio_get_flag_status            @ 08023B96 call sdio_get_flag_status
    cmp     r0, #0                          @ 08023B9A compare r0 with 0
    beq     .Lsd_find_scr_3BAA              @ 08023B9C if (r0 == 0) goto 0x8023BAA
    bl      sdio_read_data                  @ 08023B9E call sdio_read_data
    mov     r1, sp                          @ 08023BA2 r1 = sp
    str.w   r0, [r1, r6, lsl #2]            @ 08023BA4 u32 [r1+r6*4] = r0
    adds    r6, r6, #1                      @ 08023BA8 r6 = r6 + 1
.Lsd_find_scr_3BAA:                     @ v2.05 0x08023BAA, reached from 0x08023B9C
    subs.w  r8, r8, #1                      @ 08023BAA r8 = r8 - 1
    cmp.w   r8, #0                          @ 08023BAE compare r8 with 0
    bne     .Lsd_find_scr_3B86              @ 08023BB2 if (r8 != 0) goto 0x8023B86
    movs    r0, #8                          @ 08023BB4 r0 = 8
    bl      sdio_clear_flag                 @ 08023BB6 call sdio_clear_flag
    movs    r0, #4                          @ 08023BBA r0 = 4
    movs    r7, r0                          @ 08023BBC r7 = r0
    movs    r0, r7                          @ 08023BBE r0 = r7
    uxtb    r0, r0                          @ 08023BC0 r0 = u8(r0)
    b       .Lsd_find_scr_3C7C              @ 08023BC2 goto 0x8023C7C
    @ error flags in this order: DTIMEOUT (4), DCRCFAIL (2), RXOVERR (6), STBITERR (7)
.Lsd_find_scr_3BC4:                     @ v2.05 0x08023BC4, reached from 0x08023B90
    movs    r0, #8                          @ 08023BC4 r0 = 8
    bl      sdio_get_flag_status            @ 08023BC6 call sdio_get_flag_status
    cmp     r0, #0                          @ 08023BCA compare r0 with 0
    beq     .Lsd_find_scr_3BDE              @ 08023BCC if (r0 == 0) goto 0x8023BDE
    movs    r0, #8                          @ 08023BCE r0 = 8
    bl      sdio_clear_flag                 @ 08023BD0 call sdio_clear_flag
    movs    r0, #4                          @ 08023BD4 r0 = 4
    movs    r7, r0                          @ 08023BD6 r7 = r0
    movs    r0, r7                          @ 08023BD8 r0 = r7
    uxtb    r0, r0                          @ 08023BDA r0 = u8(r0)
    b       .Lsd_find_scr_3C7C              @ 08023BDC goto 0x8023C7C
.Lsd_find_scr_3BDE:                     @ v2.05 0x08023BDE, reached from 0x08023BCC
    movs    r0, #2                          @ 08023BDE r0 = 2
    bl      sdio_get_flag_status            @ 08023BE0 call sdio_get_flag_status
    cmp     r0, #0                          @ 08023BE4 compare r0 with 0
    beq     .Lsd_find_scr_3BF8              @ 08023BE6 if (r0 == 0) goto 0x8023BF8
    movs    r0, #2                          @ 08023BE8 r0 = 2
    bl      sdio_clear_flag                 @ 08023BEA call sdio_clear_flag
    movs    r0, #2                          @ 08023BEE r0 = 2
    movs    r7, r0                          @ 08023BF0 r7 = r0
    movs    r0, r7                          @ 08023BF2 r0 = r7
    uxtb    r0, r0                          @ 08023BF4 r0 = u8(r0)
    b       .Lsd_find_scr_3C7C              @ 08023BF6 goto 0x8023C7C
.Lsd_find_scr_3BF8:                     @ v2.05 0x08023BF8, reached from 0x08023BE6
    movs    r0, #0x20                       @ 08023BF8 r0 = 0x20
    bl      sdio_get_flag_status            @ 08023BFA call sdio_get_flag_status
    cmp     r0, #0                          @ 08023BFE compare r0 with 0
    beq     .Lsd_find_scr_3C12              @ 08023C00 if (r0 == 0) goto 0x8023C12
    movs    r0, #0x20                       @ 08023C02 r0 = 0x20
    bl      sdio_clear_flag                 @ 08023C04 call sdio_clear_flag
    movs    r0, #6                          @ 08023C08 r0 = 6
    movs    r7, r0                          @ 08023C0A r7 = r0
    movs    r0, r7                          @ 08023C0C r0 = r7
    uxtb    r0, r0                          @ 08023C0E r0 = u8(r0)
    b       .Lsd_find_scr_3C7C              @ 08023C10 goto 0x8023C7C
.Lsd_find_scr_3C12:                     @ v2.05 0x08023C12, reached from 0x08023C00
    mov.w   r0, #0x200                      @ 08023C12 r0 = 0x200
    bl      sdio_get_flag_status            @ 08023C16 call sdio_get_flag_status
    cmp     r0, #0                          @ 08023C1A compare r0 with 0
    beq     .Lsd_find_scr_3C30              @ 08023C1C if (r0 == 0) goto 0x8023C30
    mov.w   r0, #0x200                      @ 08023C1E r0 = 0x200
    bl      sdio_clear_flag                 @ 08023C22 call sdio_clear_flag
    movs    r0, #7                          @ 08023C26 r0 = 7
    movs    r7, r0                          @ 08023C28 r7 = r0
    movs    r0, r7                          @ 08023C2A r0 = r7
    uxtb    r0, r0                          @ 08023C2C r0 = u8(r0)
    b       .Lsd_find_scr_3C7C              @ 08023C2E goto 0x8023C7C
    @ success: static flags cleared, the two words byte swapped into the result
.Lsd_find_scr_3C30:                     @ v2.05 0x08023C30, reached from 0x08023C1C
    @ IMP-34: the loop above ends at DBCKEND, which the DPSM sets as soon as the 8 bytes and their CRC are in; words the loop
    @ has not read yet are still in the receive FIFO (RXDAVL).  v2.05 left them there and returned the zeros of its buffer:
    @ when the card sends the SCR before the loop runs (the block lasts 82 SDIO_CK clocks, about 10 us, one loop pass about
    @ 10 us at 4 MHz, and an interrupt can delay the loop), the SCR reads 0 and sd_enable_wide_bus refuses with 0x25.
    @ Read the remaining words, at most two in all.  Diagnosis: count the reads and how many words the loop had.
    ldr     r1, =sd_dg_scrs
    ldrh    r0, [r1]
    adds    r0, r0, #1
    strh    r0, [r1]
    cmp     r6, #1
    bhi     2f
    ite     eq
    ldreq   r1, =sd_dg_scr1
    ldrne   r1, =sd_dg_scr0
    ldrh    r0, [r1]
    adds    r0, r0, #1
    strh    r0, [r1]
1:  cmp     r6, #2
    bhs     2f
    ldr     r0, =(SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]
    tst     r0, #0x200000                   @ RXDAVL: a word in the receive FIFO
    beq     2f
    bl      sdio_read_data
    mov     r1, sp
    str.w   r0, [r1, r6, lsl #2]
    adds    r6, r6, #1
    b       1b
2:  movw    r0, #0x5ff                      @ 08023C30
    bl      sdio_clear_flag                 @ 08023C34 call sdio_clear_flag
    ldr     r0, [sp]                        @ 08023C38 r0 = u32 [sp]
    ldr     r1, [sp]                        @ 08023C3A r1 = u32 [sp]
    lsls    r1, r1, #8                      @ 08023C3C r1 = r1 << 8
    ands    r1, r1, #0xff0000               @ 08023C3E r1 = r1 & 0xff0000
    orrs.w  r0, r1, r0, lsl #24             @ 08023C42 r0 = r1 | r0, lsl #24
    ldr     r1, [sp]                        @ 08023C46 r1 = u32 [sp]
    lsrs    r1, r1, #8                      @ 08023C48 r1 = r1 >> 8
    ands    r1, r1, #0xff00                 @ 08023C4A r1 = r1 & 0xff00
    orrs    r0, r1                          @ 08023C4E r0 |= r1
    ldr     r1, [sp]                        @ 08023C50 r1 = u32 [sp]
    orrs.w  r0, r0, r1, lsr #24             @ 08023C52 r0 = r0 | r1, lsr #24
    str     r0, [r5, #4]                    @ 08023C56 u32 [r5+0x4] = r0
    ldr     r0, [sp, #4]                    @ 08023C58 r0 = u32 [sp+0x4]
    ldr     r1, [sp, #4]                    @ 08023C5A r1 = u32 [sp+0x4]
    lsls    r1, r1, #8                      @ 08023C5C r1 = r1 << 8
    ands    r1, r1, #0xff0000               @ 08023C5E r1 = r1 & 0xff0000
    orrs.w  r0, r1, r0, lsl #24             @ 08023C62 r0 = r1 | r0, lsl #24
    ldr     r1, [sp, #4]                    @ 08023C66 r1 = u32 [sp+0x4]
    lsrs    r1, r1, #8                      @ 08023C68 r1 = r1 >> 8
    ands    r1, r1, #0xff00                 @ 08023C6A r1 = r1 & 0xff00
    orrs    r0, r1                          @ 08023C6E r0 |= r1
    ldr     r1, [sp, #4]                    @ 08023C70 r1 = u32 [sp+0x4]
    orrs.w  r0, r0, r1, lsr #24             @ 08023C72 r0 = r0 | r1, lsr #24
    str     r0, [r5]                        @ 08023C76 u32 [r5] = r0
    movs    r0, r7                          @ 08023C78 r0 = r7
    uxtb    r0, r0                          @ 08023C7A r0 = u8(r0)
.Lsd_find_scr_3C7C:                     @ v2.05 0x08023C7C, reached from 0x08023ADA, 0x08023B18, 0x08023B7E, 0x08023BC2, 0x08023BDC, 0x08023BF6, 0x08023C10, 0x08023C2E
    pop.w   {r1, r2, r4, r5, r6, r7, r8, pc}@ 08023C7C pop {r1, r2, r4, r5, r6, r7, r8, pc}
ENDFUNC sd_find_scr
    .ltorg

