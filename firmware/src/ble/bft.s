@ =============================================================================
@ bft.s - BLE: file transfer over Bluetooth to the SD card, for a firmware update without removing the card
@ (production image only, DESIGN.md 10 IMP-28, FEATURES.md 2.10)
@
@ The bootloader programs only EEVBlog.bin from the card, and only when the update keys are held at power-on
@ (FEATURES.md 2.10); the application never writes flash.  This module receives a file over the Bluetooth link and
@ writes it to the card: first to a temporary file, then, only after its length and CRC-32 match what the sender
@ announced and its first two words look like an application image, it is copied to EEVBlog.bin and that copy is read
@ back and checked again, and the temporary file is deleted.  A broken or refused transfer never touches EEVBlog.bin; a copy
@ that fails in every attempt deletes the EEVBlog.bin it had begun, so that no part of an image is left to program.  (A
@ rename of the temporary file is not used: R0.16 f_rename writes the new entry before it removes the old one, and a card
@ error between the two writes leaves two entries on one cluster chain.)
@
@ Consent and state.  The transfer is possible only while the SETUP page Ld (setup item 39, after the page bt) is shown
@ with Bluetooth on, logging off and outside calibration mode (bft_poll).  The sub display shows "Ld-bt" (waiting),
@ "Ld nn" (nn = percent received), "Ld oK" (EEVBlog.bin written and verified) or "LdE n" (error n, below).  Leaving the
@ page ends the transfer; the meter keeps measuring meanwhile.  While the page is active the status frames are not sent
@ (ble_tx_start_frame) and the USART2 handler passes every received byte to the ring bft_ring (bft_rx_byte) instead of
@ the v2.05 key / clock parser.
@
@ Protocol (all multi-byte fields little-endian).  Packet: B5 5B type seq(2) len(1) payload(len <= 232) crc16(2); the
@ CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) covers type, seq, len and the payload.  One packet fits one Bluetooth
@ write (244 bytes, MTU 247: measured on a meter, 2026-11-03).  The sender waits for the answer to every packet
@ (stop and wait), so nothing is in flight while the card is written (the link is deaf then: usart.s, NF-04).
@     type 0x01 START  payload size(4) crc32(4): size 0x124 .. 0x4C000 (vector table .. image limit of the linker
@                      script); a new transfer, expected seq 0
@     type 0x02 DATA   seq = packet number from 0, payload = the next bytes of the file
@     type 0x03 END    all bytes sent: flush, check, copy, check the copy
@     type 0x04 ABORT  back to waiting
@     type 0x05 STATUS payload index(1): a diagnosis value in the answer's "next" field (bft_diag_tab: index 0 .. 55; 40 .. 48
@                      are the extended link diagnosis counters and the battery voltage, ble/xdiag.s, IMP-44; 49 .. 55
@                      the clock measurement, sys/msical.s, IMP-46)
@     types 0x10 .. 0x15 SD card requests (LIST, READ, CHUNK, DELETE, INFO, FORMAT; ble/bftsd.s, IMP-36, IMP-39) and
@     0x16 / 0x17 settings (GET, PUT; ble/bftset.s, IMP-37), answered with the type 0x82 answer described in ble/bftsd.s
@     type 0x19 LEAVE    leave the page Ld as a SETUP press does (next page Fr or rEL), answered with status 0 first (IMP-47)
@     type 0x18 UPDMODE  restart into the two-part bootloader's update mode (blcmd_update_mode, IMP-42); no answer (the
@                      meter restarts), status 3 without the two-part bootloader
@ Answer: B5 5B 81 seq(2) 03 status next(2) crc16(2), seq = the packet answered, next = the packet number expected
@     (with status 0x11 instead: the failed step << 8 | its FatFs result, step 1 open, 2 seek, 3 write, 4 short write,
@     5 close; with status 0 to END: the number of failed card sessions that were repeated successfully).
@     status 0 accepted; 1 CRC wrong (resend); 2 not the expected packet (send "next"); 3 not allowed in this state;
@     4 START refused (size); 5 bytes beyond the announced size; 0x10 + n: END failed with error n (below)
@ Errors (shown "LdE n"): 1 the card could not be written; 2 length or CRC-32 of the received file wrong; 3 not an
@     application image (initial SP outside the RAM, reset vector outside 0x08006000..0x08051FFF or not Thumb);
@     4 the copy to EEVBlog.bin failed; 5 the copy read back differs (after 4 or 5 no EEVBlog.bin is left once an
@     open for writing was tried); 6 the received file could not be read back.
@     Bootloader install (START kind 1, bft_install): 7 the bootloader area is not one of EEVblog's builds (nothing
@     written); 8 battery low or below 4.80 V (nothing written); 9 the install file or a flash step failed.  After
@     status 0 to END the meter restarts and the starter installs the bootloader (bootloader/DESIGN.md 6.4).
@     START payload: size(4) crc32(4) [kind(1)]: kind 0 or absent = firmware file (EEVBlog.bin), 1 = install file.
@ Buffers: the received bytes are collected in log_buf (8 KiB of its 10000 bytes, 0x20001240..0x2000394F; 0x20003950 is
@ the BLE value ring, written all the time) and written to the card
@ when the next packet might not fit; the card work uses the FIL objects of the log (log_fil, log_fil_new) and the
@ FATFS area fat_fs_obj.  All of them belong to logging and to cal.bin, which cannot run meanwhile (logging is refused,
@ cal.bin needs calibration mode).
@
@ Context: main only, except bft_rx_byte (USART2 interrupt).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ BFT_ITEM,          39              @ setup item of the page Ld
    .equ BFT_RING_LEN,      512             @ receive ring, power of two (two full packets)
    .equ BFT_MAXPAY,        232             @ payload limit: 8 + 232 = 240 bytes, one Bluetooth write
    .equ BFT_STAGE_LEN,     8192            @ bytes collected before a card write (log_buf holds 10000)
    .equ BFT_MIN_SIZE,      0x124           @ the 73-word vector table
    .equ BFT_MAX_SIZE,      0x4C000         @ image limit (link/121gw.ld: __image_end <= APP_LIMIT)
    .equ BFT_COPY_LEN,      4096            @ copy step
    .equ BFT_GAP_TICKS,     20              @ 200 ms without a byte ends a packet being assembled
    .equ BFT_COPY_TRIES,    3               @ attempts of the copy to EEVBlog.bin
    .equ BFT_FLUSH_TRIES,   10              @ card sessions for one collected write
    .equ BFT_READ_TRIES,    10              @ card sessions for reading the received file back
    .equ BFT_RESET_TICKS,   50              @ 500 ms after the last received byte: the END answer has gone out
    .equ BFT_BAT_MIN,       480             @ bootloader install only above 4.80 V (pwr_bat_cv, 0.01 V; DESIGN.md 6.4)
    .equ BLI_FILE_MIN,      0x580           @ install file: starter 0x400 + slot header page 0x100 + one half-page
    .equ BLI_FILE_MAX,      0x6000          @ starter 0x400 + slot header 0x100 + image 0x5B00 (bootloader/DESIGN.md 6.1)
    .equ BLI_SLOT_A,        0x08052000      @ slot A (nvm/blinst.s)
    .equ BLI_SLOT_END,      0x08058000
    .equ BLI_CTL,           0x0805E000      @ control area
    .equ BLI_CTL_END,       0x0805FF00
    .equ BLI_FWMARK,        0x0805FF00      @ firmware mark page
    .equ BLI_APP_BASE,      0x08006000
    .equ BLI_HDR_MAGIC,     0x32484C42      @ "BLH2": bootloader header (bootloader/tools/blimage.py)
    .equ BLI_FW_MAGIC,      0x32485746      @ "FWH2": firmware mark
    .equ BLI_CTL_MAGIC,     0x4C525443      @ "CTRL": control record
    .equ BLI_CMD_INSTALL,   1
    .equ BLI_BL_MAX,        0x5B00          @ largest bootloader image
    .equ BFT_ST_WAIT,       0               @ waiting for START
    .equ BFT_ST_RECV,       1               @ receiving
    .equ BFT_ST_DONE,       2               @ EEVBlog.bin written and verified
    .equ BFT_ST_ERR,        3               @ failed (bft_err)
    .equ FA_READ,           0x01
    .equ FA_WRITE,          0x02
    .equ FA_CREATE_ALWAYS,  0x08

    .equ bft_stage,         v_20001240      @ log_buf (log/files.s)
    .equ bft_fatfs,         ff16_fatfs      @ fat_fs_obj (production: R0.16 exFAT FATFS in .bss_port, ff16_api.s, IMP-32)
    .equ bft_fil_a,         ff16_fil_a      @ log_fil (FatFs R0.16 FIL in .bss_port, ff16_api.s, IMP-29)
    .equ bft_fil_b,         ff16_fil_b      @ log_fil_new
    .equ bft_vbuf,          v_20006EA8      @ log_verify_buf, 0x200 bytes
    .equ bft_set_item,      v_20008037      @ setup item
    .equ bft_ble_enable,    v_2000802B      @ Bluetooth on (long PEAK)
    .equ bft_logging,       v_20007FE1      @ logging active
    .equ bft_cal_mode,      v_2000808A      @ calibration mode
    .equ bft_redraw,        v_20008062      @ sub display redraw request
    .equ bft_commit,        v_2000805B      @ LCD commit request
    .equ bft_legacy_idx,    v_2000802D      @ v2.05 receive index (ble_rx_idx)

    .section .bss_port.bft, "aw", %nobits
    .balign 4
bft_ring:       .space BFT_RING_LEN         @ received bytes (USART2 handler writes, main reads)
    .global bft_pkt
bft_pkt:        .space 8 + BFT_MAXPAY       @ packet being assembled
bft_ack:        .space 12                   @ answer being built
bft_size:       .space 4                    @ announced file size
bft_crc:        .space 4                    @ announced CRC-32
bft_recv:       .space 4                    @ bytes received
bft_flushed:    .space 4                    @ bytes written to the temporary file
bft_staged:     .space 4                    @ bytes waiting in bft_stage
bft_hdr:        .space 8                    @ first two words of the received file
bft_rx_head:    .space 2                    @ ring write index (USART2 handler)
bft_rx_tail:    .space 2                    @ ring read index (main)
bft_pos:        .space 2                    @ bytes of the packet assembled so far
bft_seq:        .space 2                    @ packet number expected next
bft_diag:       .space 2                    @ last failed card write session: step << 8 | FatFs result
bft_fails:      .space 2                    @ failed card write sessions of this transfer (repeated successfully or not)
bft_alt_next:   .space 3                    @ u16 for the "next" field of the coming answer, and at +2 the flag 1 = use it
    .global bft_active
bft_active:     .space 1                    @ 1 = the page Ld owns the link (read by usart.s)
    .global bft_state
bft_state:      .space 1                    @ BFT_ST_*
bft_err:        .space 1                    @ error code of BFT_ST_ERR
bft_pct:        .space 1                    @ percent shown
bft_created:    .space 1                    @ the temporary file exists for this transfer
bft_idle:       .space 1                    @ 10 ms ticks since the last received byte (TIM2, saturates at 255)
bft_kind:       .space 1                    @ START kind: 0 firmware (EEVBlog.bin), 1 bootloader install (nvm/blinst.s)
    .global bft_reset_due
bft_reset_due:  .space 1                    @ 1: restart once the link has been quiet for BFT_RESET_TICKS (install done)

    .section .rodata.bft, "a", %progbits
    .balign 4
@ STATUS (type 5) values: 0 failed card sessions of the transfer, 1 last card failure (step << 8 | FatFs result),
@ 2 failed disk_read / disk_write calls since power-on, 3 their op and reason, 4 SDIO_STA, 5 sd_transfer_error,
@ 6 sd_wait_write result, 7 end flags (transfer end << 1 | DMA end), 8 DMA2 channel 4 flags, 9 CNDTR, 10 SDIO_DCOUNT,
@ 11 SDIO_STA high half, 12 reads taken on the hardware counters, 13 / 14 low / high half of the card status of the last
@ CMD13 answer before the failure, 15 10 ms ticks of the failed status polling, 16 failed card start-ups since power-on,
@ 17 the sd_init error code of the last one, 18 SCR reads since power-on, 19 / 20 of these the reads whose polling loop had
@ read no word / one word when the block end was seen (IMP-34), 21 the write wait that last ran out (1 DMA / transfer end,
@ 2 the card's busy; values 7 .. 11 then hold the transfer state at that moment), 22 its length in 10 ms ticks, 23 the last
@ ACMD22 answer (0x8000 | SD error << 8 | count, 0 none yet), 24 blocks ACMD22 confirmed, 25 blocks written again (IMP-40),
@ and of the first write timeout of the power-on: 26 / 27 the sector (low / high half), 28 / 29 the DMA source address,
@ 30 DMA2 channel 4 CCR, 31 / 32 its CMAR, 33 SDIO_DCTRL, 34 SDIO_DLEN, 35 SDIO_FIFOCNT, 36 / 37 SDIO_STA, 38 which attempt,
@ 39 SDIO_CLKCR
@ (21, 22 and 7 .. 11 are of that first timeout as well) (sd/diskio.s, sd_dg_*).  Extended link diagnosis (IMP-44,
@ ble/xdiag.s; the counters count only after the key code 0x93, and keep their values after 0x94): 40 bytes received on USART2,
@ 41 overruns (SR.ORE), 42 noise flags (SR.NE), 43 framing errors (SR.FE), 44 bytes discarded while SYSCLK was not MSI (NF-04),
@ 45 key / set-clock frames rejected, 46 packets answered with status 1 (CRC wrong), 47 answers / echoes not queued for lack of
@ room, 48 battery voltage (0.01 V, read at the moment of the request).  Clock measurement (IMP-46, sys/msical.s; written at
@ power-on and at every STOP wake): 49 / 50 MSI Hz measured with the trim as found (low / high half), 51 / 52 MSI Hz in use,
@ 53 MSITRIM | status << 8 (CK_ST_*, macros.inc), 54 measurements made, 55 USART2_BRR
bft_diag_tab:   .word bft_fails, bft_diag, sd_dg_count, sd_dg_op, sd_dg_sta, sd_dg_terr, sd_dg_wait
                .word sd_dg_flags, sd_dg_dmaisr, sd_dg_cndtr, sd_dg_dcount, sd_dg_stahi, sd_dg_recov
                .word sd_dg_r1, sd_dg_r1 + 2, sd_dg_ticks, sd_dg_icount, sd_dg_ierr, sd_dg_scrs, sd_dg_scr0, sd_dg_scr1
                .word sd_dg_wphase, sd_dg_wticks, sd_dg_a22, sd_dg_late, sd_dg_retry
                .word sd_dg_wsec, sd_dg_wsec + 2, sd_dg_wbuf, sd_dg_wbuf + 2, sd_dg_wccr, sd_dg_wcmar, sd_dg_wcmar + 2
                .word sd_dg_wdctrl, sd_dg_wdlen, sd_dg_wfifo, sd_dg_wsta, sd_dg_wsta + 2, sd_dg_wtry, sd_dg_wclkcr
                .word xd_rx_bytes, xd_err_ore, xd_err_ne, xd_err_fe, xd_rx_dropped_hse, xd_bad_frames, xd_bft_crc_bad
                .word xd_tx_q_full, pwr_bat_cv
                .word ck_hz0, ck_hz0 + 2, ck_hz, ck_hz + 2, ck_trim, ck_steps, USART2_BASE + USART_BRR
bft_diag_wid:   .byte 2, 2, 2, 2, 2, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2
                .byte 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 2
                .byte 2, 2, 2, 2, 2, 2, 2, 2, 2             @ 40 .. 48: nine u16 (IMP-44)
                .byte 2, 2, 2, 2, 2, 2, 2                   @ 49 .. 55: the clock measurement (IMP-46)
    .equ BFT_DIAG_N, 56
    .equ BFT_T_UPDMODE, 0x18                @ request: restart into the two-part bootloader's update mode (as key code
                                            @ 0x91, which the page Ld does not take: it owns the link)
    .equ BFT_T_LEAVE,   0x19                @ request: leave the page Ld as a SETUP press does (IMP-47)
bft_name_tmp:   .asciz "0:BTLOAD.TMP"
bft_name_img:   .asciz "0:EEVBlog.bin"

    .section .text.bft, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bft_le32 - little-endian u32 from any address (the packet fields are not aligned)
@ In       : r0 = address
@ Out      : r0 = value
@ Clobbers : r1, r2
@ -----------------------------------------------------------------------------
FUNC bft_le32
    ldrb r1, [r0, #3]
    ldrb r2, [r0, #2]
    orr r1, r2, r1, lsl #8
    ldrb r2, [r0, #1]
    orr r1, r2, r1, lsl #8
    ldrb r2, [r0, #0]
    orr r0, r2, r1, lsl #8
    bx lr
ENDFUNC bft_le32

@ -----------------------------------------------------------------------------
@ bft_rx_byte - store one received byte in the ring
@ In       : r0 = byte
@ Clobbers : r0-r3, r12, flags
@ Context  : USART2 interrupt (ble_usart2_isr, only while bft_active)
@ Note     : a full ring drops the byte (the packet CRC then fails and the sender repeats it)
@ -----------------------------------------------------------------------------
FUNC bft_rx_byte
    ldr r1, =bft_rx_head
    ldrh r2, [r1]
    adds r3, r2, #1
    bfc r3, #9, #23                         @ (head + 1) mod 512
    ldr r12, =bft_rx_tail
    ldrh r12, [r12]
    cmp r3, r12
    beq 1f                                  @ full: drop
    ldr r12, =bft_ring
    strb r0, [r12, r2]
    strh r3, [r1]                           @ publish after the byte
1:  movs r0, #0
    ldr r1, =bft_idle
    strb r0, [r1]                           @ a byte arrived
    bx lr
ENDFUNC bft_rx_byte

@ -----------------------------------------------------------------------------
@ bft_tick - count the 10 ms ticks since the last received byte
@ Clobbers : r0, r1, flags
@ Context  : TIM2 interrupt (sys_tim2_isr, every tick)
@ -----------------------------------------------------------------------------
FUNC bft_tick
    ldr r1, =bft_idle
    ldrb r0, [r1]
    cmp r0, #255
    it lo
    addlo r0, r0, #1
    strb r0, [r1]
    bx lr
ENDFUNC bft_tick

@ -----------------------------------------------------------------------------
@ bft_crc16 - CRC-16/CCITT-FALSE
@ In       : r0 = buffer, r1 = length
@ Out      : r0 = CRC (init 0xFFFF, poly 0x1021, no reflection, no final XOR)
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC bft_crc16
    movw r2, #0xFFFF
    movw r12, #0x1021
1:  cbz r1, 4f
    ldrb r3, [r0], #1
    eor r2, r2, r3, lsl #8
    movs r3, #8
2:  lsls r2, r2, #1
    tst r2, #0x10000
    it ne
    eorne r2, r2, r12
    subs r3, r3, #1
    bne 2b
    uxth r2, r2
    subs r1, r1, #1
    b 1b
4:  mov r0, r2
    bx lr
ENDFUNC bft_crc16

@ -----------------------------------------------------------------------------
@ bft_crc32 - CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320) update
@ In       : r0 = running value (start 0xFFFFFFFF, final value XOR 0xFFFFFFFF), r1 = buffer, r2 = length
@ Out      : r0 = running value
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC bft_crc32
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
ENDFUNC bft_crc32

@ -----------------------------------------------------------------------------
@ bft_answer - queue the answer to the packet in bft_pkt
@ In       : r0 = status
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ -----------------------------------------------------------------------------
LFUNC bft_answer
    push {r4, lr}
    ldr r4, =bft_ack
    movs r1, #0xB5
    strb r1, [r4, #0]
    movs r1, #0x5B
    strb r1, [r4, #1]
    movs r1, #0x81
    strb r1, [r4, #2]
    ldr r1, =bft_pkt
    ldrb r2, [r1, #3]
    strb r2, [r4, #3]                       @ seq of the packet answered
    ldrb r2, [r1, #4]
    strb r2, [r4, #4]
    movs r1, #3
    strb r1, [r4, #5]
    strb r0, [r4, #6]                       @ status
    ldr r1, =bft_seq
    ldr r2, =bft_alt_next
    ldrb r3, [r2, #2]
    cbz r3, 1f
    mov r1, r2                              @ an answer that carries other information in the field (bft_alt_next)
    movs r3, #0
    strb r3, [r2, #2]
1:  ldrh r1, [r1]
    strb r1, [r4, #7]                       @ next expected
    lsrs r1, r1, #8
    strb r1, [r4, #8]
    adds r0, r4, #2
    movs r1, #7
    bl bft_crc16                            @ over type .. payload
    strb r0, [r4, #9]
    lsrs r0, r0, #8
    strb r0, [r4, #10]
    mov r0, r4
    movs r1, #11
    bl ble_tx_queue_put                     @ a refusal (queue full) leaves the sender to repeat the packet
    pop {r4, pc}
ENDFUNC bft_answer

@ -----------------------------------------------------------------------------
@ bft_card_begin / bft_card_end - the card session frame of log_session_once: card-session clock (PLL 32 MHz, IMP-41), card up, mount ...
@ power the SDIO block off, run clock again
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC bft_card_begin
    push {r4, lr}
    movs r0, #1
    bl sys_clock_select                     @ the card-session clock (PLL 32 MHz, IMP-41)
    movs r0, #10
    bl sd_bringup_retry
    ldr r1, =bft_fatfs
    movs r0, #0
    bl fat_f_mount                          @ drive 0 (no I/O yet; the first file call initialises the card)
    pop {r4, pc}
ENDFUNC bft_card_begin

FUNC bft_card_end
    push {r4, lr}
    bl sd_power_off
    movs r0, #0
    bl sys_clock_select                     @ run clock: the link hears again
    pop {r4, pc}
ENDFUNC bft_card_end

@ -----------------------------------------------------------------------------
@ bft_flush - write the collected bytes to the temporary file, up to BFT_FLUSH_TRIES card sessions
@ Out      : r0 = 0 written, 1 every attempt failed
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Note     : on a meter a card write session failed after 14 and, in a second transfer, after 5 good ones (2026-11-03,
@            the transfer stopped with LdE 1; cause not known yet, bft_diag reports the step and the FatFs result);
@            log_write_step repeats a failed log session the same way (20 attempts), and log_open_and_seek its f_open
@            and f_lseek (21 attempts each).  A repeated attempt rewrites the
@            same bytes at the same offset (bft_flushed advances only after a complete write), so a partial write of a
@            failed attempt is overwritten.
@ -----------------------------------------------------------------------------
LFUNC bft_flush
    push {r4, lr}
    movs r4, #BFT_FLUSH_TRIES
1:  bl bft_flush_once
    cbz r0, 2f
    ldr r1, =bft_fails
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]                           @ one more failed session
    subs r4, r4, #1
    bne 1b
    movs r0, #1
2:  pop {r4, pc}
ENDFUNC bft_flush

@ -----------------------------------------------------------------------------
@ bft_flush_once - one card session that writes the collected bytes to the temporary file
@ Out      : r0 = 0 written (bft_flushed advanced, bft_staged = 0), 1 failed
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
LFUNC bft_flush_once
    push {r4-r6, lr}
    sub sp, sp, #8
    ldr r0, =bft_staged
    ldr r5, [r0]
    cmp r5, #0
    beq .Lfl_ok                             @ nothing collected
    bl bft_card_begin
    movs r6, #1                             @ r6 = result, failed until proven
    movs r4, #1                             @ r4 = step for the diagnosis: 1 open
    ldr r0, =bft_created
    ldrb r0, [r0]
    cmp r0, #0
    ite eq
    moveq r2, #(FA_WRITE | FA_CREATE_ALWAYS) @ first write of this transfer: a new (or emptied) file
    movne r2, #FA_WRITE                     @ later: the existing file
    ldr r0, =bft_fil_a
    ldr r1, =bft_name_tmp
    bl fat_f_open
    cmp r0, #0
    bne .Lfl_diag
    movs r4, #2                             @ 2 seek
    ldr r0, =bft_fil_a
    ldr r1, =bft_flushed
    ldr r1, [r1]
    bl fat_f_lseek                          @ to the end of what is written
    cmp r0, #0
    bne .Lfl_close_diag
    movs r4, #3                             @ 3 write
    ldr r0, =bft_fil_a
    ldr r1, =bft_stage
    mov r2, r5
    add r3, sp, #0
    bl fat_f_write
    cmp r0, #0
    bne .Lfl_close_diag
    movs r4, #4                             @ 4 short write (card full)
    ldr r0, [sp, #0]
    cmp r0, r5
    bne .Lfl_close_diag
    movs r6, #0
    movs r4, #5                             @ 5 close
    ldr r0, =bft_fil_a
    bl fat_f_close
    cmp r0, #0
    beq .Lfl_end
    movs r6, #1                             @ the directory entry must be written too
    b .Lfl_diag
.Lfl_close_diag:
    push {r0}
    ldr r0, =bft_fil_a
    bl fat_f_close
    pop {r0}
.Lfl_diag:
    orr r0, r0, r4, lsl #8                  @ step << 8 | FatFs result of that step
    ldr r1, =bft_diag
    strh r0, [r1]
.Lfl_end:
    bl bft_card_end
    cmp r6, #0
    bne .Lfl_fail
    movs r0, #1
    ldr r1, =bft_created
    strb r0, [r1]
    ldr r1, =bft_flushed
    ldr r0, [r1]
    add r0, r0, r5
    str r0, [r1]
    movs r0, #0
    ldr r1, =bft_staged
    str r0, [r1]
.Lfl_ok:
    movs r0, #0
    add sp, sp, #8
    pop {r4-r6, pc}
.Lfl_fail:
    movs r0, #1
    add sp, sp, #8
    pop {r4-r6, pc}
ENDFUNC bft_flush_once

@ -----------------------------------------------------------------------------
@ bft_file_crc - CRC-32 and length of a file
@ In       : r0 = path
@ Out      : r0 = 0 read, else the FatFs result of the failed open or read; r1 = CRC-32 (final), r2 = length; the first
@            8 bytes in bft_hdr
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Context  : inside a card session
@ -----------------------------------------------------------------------------
LFUNC bft_file_crc
    push {r4-r7, lr}
    sub sp, sp, #12
    mov r1, r0
    ldr r0, =bft_fil_a
    movs r2, #FA_READ
    bl fat_f_open
    cbnz r0, .Lfc_fail
    mov r4, #0xFFFFFFFF                     @ r4 = running CRC
    movs r5, #0                             @ r5 = length
.Lfc_loop:
    ldr r0, =bft_fil_a
    ldr r1, =bft_vbuf
    mov r2, #0x200
    add r3, sp, #0
    bl fat_f_read
    cbnz r0, .Lfc_close_fail
    ldr r6, [sp, #0]                        @ bytes read
    cbz r6, .Lfc_eof
    cbnz r5, 1f
    cmp r6, #8                              @ first block: keep the first two words
    blo 1f
    ldr r0, =bft_vbuf
    ldr r1, =bft_hdr
    ldr r2, [r0, #0]
    str r2, [r1, #0]
    ldr r2, [r0, #4]
    str r2, [r1, #4]
1:  mov r0, r4
    ldr r1, =bft_vbuf
    mov r2, r6
    bl bft_crc32
    mov r4, r0
    add r5, r5, r6
    cmp r6, #0x200
    beq .Lfc_loop                           @ a full block: more may follow
.Lfc_eof:
    ldr r0, =bft_fil_a
    bl fat_f_close
    mvn r1, r4                              @ final XOR
    mov r2, r5
    movs r0, #0
    add sp, sp, #12
    pop {r4-r7, pc}
.Lfc_close_fail:
    mov r4, r0                              @ keep the result of the failed read
    ldr r0, =bft_fil_a
    bl fat_f_close
    mov r0, r4
.Lfc_fail:
    add sp, sp, #12
    pop {r4-r7, pc}                         @ r0 = FatFs result of the failed open or read (non-zero)
ENDFUNC bft_file_crc

@ -----------------------------------------------------------------------------
@ bft_finish - END: check the temporary file, copy it to EEVBlog.bin, check the copy, delete the temporary file
@ Out      : r0 = 0 done, else the error code 2..5
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
LFUNC bft_finish
    push {r4-r7, lr}
    sub sp, sp, #12
    bl bft_card_begin
    @ 1. the received file: length and CRC-32 as announced.  A failed read is repeated in a new card session (on a meter
    @    a read of the complete, correct file failed once, 2026-11-03: the check said "length or CRC-32 wrong" while the
    @    card held every byte right); error 6 if every attempt fails, error 2 only for a file read completely but wrong
    movs r4, #BFT_READ_TRIES
.Lfi_rd:
    ldr r0, =bft_name_tmp
    bl bft_file_crc
    cmp r0, #0
    beq .Lfi_rd_ok
    orr r0, r0, #0x600                      @ diagnosis: step 6 (read back) << 8 | FatFs result
    ldr r3, =bft_diag
    strh r0, [r3]
    ldr r3, =bft_fails
    ldrh r0, [r3]
    adds r0, r0, #1
    strh r0, [r3]
    bl bft_card_end
    bl bft_card_begin
    subs r4, r4, #1
    bne .Lfi_rd
    movs r7, #6
    b .Lfi_end
.Lfi_rd_ok:
    movs r7, #2
    ldr r0, =bft_size
    ldr r0, [r0]
    cmp r2, r0
    bne .Lfi_end
    ldr r0, =bft_crc
    ldr r0, [r0]
    cmp r1, r0
    bne .Lfi_end
    @ a bootloader install file is not copied: bft_install writes it to flash, then the meter restarts
    ldr r0, =bft_kind
    ldrb r0, [r0]
    cbz r0, 21f
    bl bft_install
    movs r7, r0
    bne .Lfi_end
    ldr r0, =bft_name_tmp
    bl fat_f_unlink
    movs r0, #1
    ldr r1, =bft_reset_due
    strb r0, [r1]
    movs r0, #0                             @ the 500 ms are counted from now: the END answer goes out first (the
    ldr r1, =bft_idle                       @ ticks of the install itself must not count, on a meter the restart
    strb r0, [r1]                           @ came before the answer, 2026-11-04)
    b .Lfi_end
21:
    @ 2. an application image: initial SP in the RAM (0x20000001 .. 0x20014000), reset vector Thumb and inside
    @    0x08006000 .. 0x08051FFF (the bootloader checks only the SP: FEATURES.md 2.10)
    movs r7, #3
    ldr r3, =bft_hdr
    ldr r0, [r3, #0]
    ldr r1, =0x20000001
    cmp r0, r1
    blo .Lfi_end
    ldr r1, =0x20014000
    cmp r0, r1
    bhi .Lfi_end
    ldr r0, [r3, #4]
    tst r0, #1
    beq .Lfi_end
    ldr r1, =0x08006000
    cmp r0, r1
    blo .Lfi_end
    ldr r1, =APP_LIMIT
    cmp r0, r1
    bhs .Lfi_end
    @ 3. copy to EEVBlog.bin (create always: the old file is replaced only now), 4. read the copy back; a failed copy is
    @    repeated from the intact temporary file (BFT_COPY_TRIES attempts), so a card hiccup does not leave EEVBlog.bin short
    movs r4, #BFT_COPY_TRIES
    movs r0, #0
    str r0, [sp, #8]                        @ 1 once an open of EEVBlog.bin for writing was tried (its old content may be gone)
.Lfi_try:
    movs r7, #4
    ldr r0, =bft_fil_a
    ldr r1, =bft_name_tmp
    movs r2, #FA_READ
    bl fat_f_open
    cmp r0, #0
    bne .Lfi_retry
    movs r0, #1                             @ set before the open: a CREATE_ALWAYS that fails while it truncates the old
    str r0, [sp, #8]                        @ file may already have written its entry with size 0
    ldr r0, =bft_fil_b
    ldr r1, =bft_name_img
    movs r2, #(FA_WRITE | FA_CREATE_ALWAYS)
    bl fat_f_open
    cmp r0, #0
    bne .Lfi_close_a
.Lfi_copy:
    ldr r0, =bft_fil_a
    ldr r1, =bft_stage
    mov r2, #BFT_COPY_LEN
    add r3, sp, #0
    bl fat_f_read
    cmp r0, #0
    bne .Lfi_close_b
    ldr r5, [sp, #0]                        @ bytes read
    cbz r5, .Lfi_copied
    ldr r0, =bft_fil_b
    ldr r1, =bft_stage
    mov r2, r5
    add r3, sp, #4
    bl fat_f_write
    cmp r0, #0
    bne .Lfi_close_b
    ldr r0, [sp, #4]
    cmp r0, r5
    bne .Lfi_close_b                        @ card full
    cmp r5, #BFT_COPY_LEN
    beq .Lfi_copy
.Lfi_copied:
    ldr r0, =bft_fil_b
    bl fat_f_close
    mov r6, r0
    ldr r0, =bft_fil_a
    bl fat_f_close
    cmp r6, #0
    bne .Lfi_retry                          @ the entry of EEVBlog.bin was not written
    movs r7, #5
    ldr r0, =bft_name_img
    bl bft_file_crc
    cmp r0, #0
    bne .Lfi_retry
    ldr r0, =bft_size
    ldr r0, [r0]
    cmp r2, r0
    bne .Lfi_retry
    ldr r0, =bft_crc
    ldr r0, [r0]
    cmp r1, r0
    bne .Lfi_retry
    @ 5. done: the temporary file is deleted (its result does not matter: EEVBlog.bin is complete and checked, a
    @    remaining BTLOAD.TMP is replaced by the next transfer)
    movs r7, #0
    ldr r0, =bft_name_tmp
    bl fat_f_unlink
    b .Lfi_end
.Lfi_close_b:
    ldr r0, =bft_fil_b
    bl fat_f_close
.Lfi_close_a:
    ldr r0, =bft_fil_a
    bl fat_f_close
.Lfi_retry:
    subs r4, r4, #1
    bne .Lfi_try                            @ r7 keeps the error of the last attempt
    @ every attempt failed: an EEVBlog.bin opened for writing is short or wrong and is deleted, so that the bootloader
    @ finds no file to program instead of a part of an image
    ldr r0, [sp, #8]
    cbz r0, .Lfi_end
    ldr r0, =bft_name_img
    bl fat_f_unlink
.Lfi_end:
    bl bft_card_end
    mov r0, r7
    add sp, sp, #12
    pop {r4-r7, pc}
ENDFUNC bft_finish

@ -----------------------------------------------------------------------------
@ bft_install - END of a bootloader install transfer: write the two-part bootloader (bootloader/DESIGN.md 6.4)
@ In       : BTLOAD.TMP complete, its length and CRC-32 as announced; inside a card session
@ Out      : r0 = 0 installed (the meter restarts next, bft_poll), 7 the bootloader area is not one of EEVblog's builds
@            (already replaced or unknown: nothing written), 8 battery below 4.80 V or low (nothing written), 9 the file
@            or a flash step failed (bft_diag = 0x0700 | step: 1 open, 2 read, 3 starter, 4 header, 5 size, 6 slot,
@            7 slot CRC, 8 control area, 9 firmware mark, 10 starter pages)
@ Clobbers : r0-r3, r12, flags (r4-r8 saved)
@ Install file: starter (0x400 bytes, written to 0x08000000..0x080003FF), then the slot contents: header page (0x100,
@ header in its first 20 bytes) and the bootloader image in whole half-pages (bootloader/tools/blimage.py install).
@ Order: slot A, control record INSTALL, firmware mark, then the starter pages 3, 2, 1 (the old bootloader still starts
@ the firmware without them) and page 0 last: only a power cut during page 0 (about 10 ms) leaves no start.
@ -----------------------------------------------------------------------------
LFUNC bft_install
    push {r4-r8, lr}
    sub sp, sp, #8                          @ [sp] bytes read, [sp+4] step
    @ battery: the low-battery flag clear and at least 4.80 V
    movs r7, #8
    ldr r0, =v_200080F9
    ldrb r0, [r0]
    cmp r0, #0
    bne .Lin_ret
    ldr r0, =pwr_bat_cv
    ldrh r0, [r0]
    cmp r0, #BFT_BAT_MIN
    blo .Lin_ret
    @ the file: starter and slot header into bft_stage (0x500 bytes)
    movs r7, #9
    movs r0, #1
    str r0, [sp, #4]
    ldr r0, =bft_fil_a
    ldr r1, =bft_name_tmp
    movs r2, #FA_READ
    bl fat_f_open
    cmp r0, #0
    bne .Lin_fail
    movs r0, #2
    str r0, [sp, #4]
    ldr r0, =bft_fil_a
    ldr r1, =bft_stage
    mov r2, #0x500
    bl bft_read_exact
    cmp r0, #0
    bne .Lin_close
    movs r0, #3                             @ starter: initial SP in the RAM, reset vector Thumb inside the starter
    str r0, [sp, #4]
    ldr r3, =bft_stage
    ldr r0, [r3, #0]
    ldr r1, =0x20000001
    cmp r0, r1
    blo .Lin_close
    ldr r1, =0x2000C000
    cmp r0, r1
    bhi .Lin_close
    ldr r0, [r3, #4]
    tst r0, #1
    beq .Lin_close
    cmp r0, #0x08000000
    blo .Lin_close
    ldr r1, =0x08000400
    cmp r0, r1
    bhs .Lin_close
    movs r0, #4                             @ slot header: magic, length 1..BLI_BL_MAX, CRC-32 of its first 16 bytes
    str r0, [sp, #4]
    add r4, r3, #0x400                      @ r4 = header in RAM
    ldr r0, [r4, #0]
    ldr r1, =BLI_HDR_MAGIC
    cmp r0, r1
    bne .Lin_close
    ldr r5, [r4, #4]                        @ r5 = image length
    subs r0, r5, #1
    cmp r0, #BLI_BL_MAX
    bhs .Lin_close
    mov r0, #0xFFFFFFFF
    mov r1, r4
    movs r2, #16
    bl blinst_crc32
    mvns r0, r0
    ldr r1, [r4, #16]
    cmp r0, r1
    bne .Lin_close
    movs r0, #5                             @ the file holds exactly the image in whole half-pages
    str r0, [sp, #4]
    adds r6, r5, #127
    lsrs r6, r6, #7                         @ r6 = image half-pages
    add r0, r6, #10                         @ 0x500 / 128 = 10
    ldr r1, =bft_size
    ldr r1, [r1]
    cmp r1, r0, lsl #7
    bne .Lin_close
    @ the bootloader area must be one of EEVblog's builds (pages 1..3 not checked): else nothing is written
    bl blinst_open
    cbz r0, 1f
    movs r7, #7
    b .Lin_close
1:  movs r0, #6                             @ slot A: erase, header page, image
    str r0, [sp, #4]
    ldr r0, =BLI_SLOT_A
    ldr r1, =BLI_SLOT_END
    bl bft_erase_range
    cmp r0, #0
    bne .Lin_close
    ldr r0, =BLI_SLOT_A
    mov r1, r4
    movs r2, #2
    bl blinst_write_hp
    cmp r0, #0
    bne .Lin_close
    ldr r8, =BLI_SLOT_A + 0x100             @ r8 = destination
2:  cbz r6, 3f
    cmp r6, #4                              @ up to 4 half-pages (512 bytes) per card read
    ite hs
    movhs r7, #4
    movlo r7, r6
    ldr r1, =bft_vbuf
    lsls r2, r7, #7
    ldr r0, =bft_fil_a
    bl bft_read_exact
    cbnz r0, 4f
    mov r0, r8
    ldr r1, =bft_vbuf
    mov r2, r7
    bl blinst_write_hp
    cbnz r0, 4f
    add r8, r8, r7, lsl #7
    subs r6, r6, r7
    b 2b
4:  movs r7, #9
    b .Lin_close
3:  movs r7, #9
    movs r0, #7                             @ the image in slot A has the CRC-32 of its header
    str r0, [sp, #4]
    mov r0, #0xFFFFFFFF
    ldr r1, =BLI_SLOT_A + 0x100
    mov r2, r5
    bl blinst_crc32
    mvns r0, r0
    ldr r1, [r4, #8]
    cmp r0, r1
    bne .Lin_close
    movs r0, #8                             @ control area: erased, one INSTALL record for slot A
    str r0, [sp, #4]
    ldr r0, =BLI_CTL
    ldr r1, =BLI_CTL_END
    bl bft_erase_range
    cmp r0, #0
    bne .Lin_close
    ldr r6, =bft_stage + 0x500              @ r6 = record / mark under construction
    ldr r0, =BLI_CTL_MAGIC
    str r0, [r6, #0]
    movs r0, #BLI_CMD_INSTALL
    str r0, [r6, #4]
    ldr r0, =BLI_SLOT_A
    str r0, [r6, #8]
    mov r0, #0xFFFFFFFF
    mov r1, r6
    movs r2, #12
    bl blinst_crc32
    mvns r0, r0
    str r0, [r6, #12]
    ldr r0, =BLI_CTL
    movs r1, #4
    bl bft_write_words
    cmp r0, #0
    bne .Lin_close
    movs r0, #9                             @ firmware mark of the running firmware (the new bootloader starts only a
    str r0, [sp, #4]                        @ firmware with a valid mark)
    ldr r0, =BLI_FWMARK
    add r1, r0, #0x100
    bl bft_erase_range
    cmp r0, #0
    bne .Lin_close
    ldr r0, =BLI_FW_MAGIC
    str r0, [r6, #0]
    ldr r1, =BLI_APP_BASE
    ldr r2, =__image_end
    subs r2, r2, r1                         @ image length
    str r2, [r6, #4]
    mov r0, #0xFFFFFFFF
    bl blinst_crc32
    mvns r0, r0
    str r0, [r6, #8]
    ldr r0, =((FW_VER_C2 - '0') << 16) | ((FW_VER_C3 - '0') << 8) | (FW_VER_C4 - '0')
    str r0, [r6, #12]
    mov r0, #0xFFFFFFFF
    mov r1, r6
    movs r2, #16
    bl blinst_crc32
    mvns r0, r0
    str r0, [r6, #16]
    ldr r0, =BLI_FWMARK
    movs r1, #5
    bl bft_write_words
    cmp r0, #0
    bne .Lin_close
    movs r0, #10                            @ starter pages 3, 2, 1, then 0
    str r0, [sp, #4]
    movs r4, #3
5:  lsls r6, r4, #8                         @ page offset
    add r0, r6, #0x08000000
    add r1, r0, #0x100
    bl bft_erase_range
    cbnz r0, 6f
    add r0, r6, #0x08000000
    ldr r1, =bft_stage
    add r1, r1, r6
    movs r2, #2
    bl blinst_write_hp
    cbnz r0, 6f
    subs r4, r4, #1
    bpl 5b
    movs r7, #0                             @ installed
    b .Lin_close
6:  movs r7, #9
.Lin_close:
    bl blinst_close
    ldr r0, =bft_fil_a
    bl fat_f_close
.Lin_fail:
    cbz r7, .Lin_ret
    cmp r7, #9
    bne .Lin_ret
    ldr r0, [sp, #4]
    orr r0, r0, #0x700
    ldr r1, =bft_diag
    strh r0, [r1]
.Lin_ret:
    mov r0, r7
    add sp, sp, #8
    pop {r4-r8, pc}
ENDFUNC bft_install

@ -----------------------------------------------------------------------------
@ bft_read_exact - read exactly r2 bytes from the open file r0 to r1
@ Out      : r0 = 0, else non-zero (FatFs error or short read)
@ Clobbers : r1-r3, r12, flags (r4 saved)
@ -----------------------------------------------------------------------------
LFUNC bft_read_exact
    push {r4, lr}
    sub sp, sp, #8
    mov r4, r2
    mov r3, sp
    bl fat_f_read
    cbnz r0, 1f
    ldr r1, [sp]
    subs r0, r1, r4                         @ 0 when all bytes came
1:  add sp, sp, #8
    pop {r4, pc}
ENDFUNC bft_read_exact

@ -----------------------------------------------------------------------------
@ bft_erase_range - erase the pages r0 .. r1 (exclusive) through nvm/blinst.s
@ Out      : r0 = 0, else the blinst result
@ Clobbers : r1-r3, r12, flags (r4, r5 saved)
@ -----------------------------------------------------------------------------
LFUNC bft_erase_range
    push {r4, r5, lr}
    mov r4, r0
    mov r5, r1
1:  cmp r4, r5
    bhs 2f
    mov r0, r4
    bl blinst_erase_page
    cbnz r0, 3f
    add r4, r4, #0x100
    b 1b
2:  movs r0, #0
3:  pop {r4, r5, pc}
ENDFUNC bft_erase_range

@ -----------------------------------------------------------------------------
@ bft_write_words - write r1 words from bft_stage + 0x500 to the erased flash at r0 through nvm/blinst.s
@ Out      : r0 = 0, else the blinst result
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
LFUNC bft_write_words
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    ldr r6, =bft_stage + 0x500
1:  ldr r1, [r6], #4
    mov r0, r4
    bl blinst_write_word
    cbnz r0, 2f
    adds r4, r4, #4
    subs r5, r5, #1
    bne 1b
2:  pop {r4-r6, pc}
ENDFUNC bft_write_words

@ -----------------------------------------------------------------------------
@ bft_sysreset - system reset (PM0056 4.4.5: SYSRESETREQ with the key, PRIGROUP kept); does not return
@ -----------------------------------------------------------------------------
LFUNC bft_sysreset
    dsb
    ldr r0, =SCB_AIRCR
    ldr r1, [r0]
    and r1, r1, #SCB_AIRCR_PRIGROUP_MASK
    ldr r2, =(SCB_AIRCR_VECTKEY | SCB_AIRCR_SYSRESETREQ)
    orr r1, r1, r2
    str r1, [r0]
    dsb
1:  b 1b
ENDFUNC bft_sysreset

@ -----------------------------------------------------------------------------
@ bft_alt - the coming answer carries r0 (u16) in its "next" field
@ Clobbers : r1, r2
@ -----------------------------------------------------------------------------
LFUNC bft_alt
    ldr r1, =bft_alt_next
    strh r0, [r1]
    movs r2, #1
    strb r2, [r1, #2]
    bx lr
ENDFUNC bft_alt

@ -----------------------------------------------------------------------------
@ bft_set_state - state change with redraw
@ In       : r0 = state, r1 = error code
@ Clobbers : r0-r2
@ -----------------------------------------------------------------------------
LFUNC bft_set_state
    ldr r2, =bft_state
    strb r0, [r2]
    ldr r2, =bft_err
    strb r1, [r2]
    movs r0, #1
    ldr r2, =bft_redraw
    strb r0, [r2]
    bx lr
ENDFUNC bft_set_state

@ -----------------------------------------------------------------------------
@ bft_packet - handle the complete packet in bft_pkt (CRC already checked)
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
LFUNC bft_packet
    push {r4-r7, lr}
    bl fn_0800ED26                          @ activity: reload the auto-power-off counter
    ldr r4, =bft_pkt
    ldrb r0, [r4, #2]                       @ type
    cmp r0, #1
    beq .Lpk_start
    cmp r0, #2
    beq .Lpk_data
    cmp r0, #3
    beq .Lpk_end
    cmp r0, #4
    beq .Lpk_abort
    cmp r0, #5
    beq .Lpk_status
    cmp r0, #0x10
    blo 1f
    cmp r0, #0x17
    bhi 2f
    bl bfx_request                          @ 0x10 .. 0x17: SD card files and settings, answered with type 0x82
    pop {r4-r7, pc}                         @ (ble/bftsd.s, ble/bftset.s; r0 = type)
2:  cmp r0, #BFT_T_UPDMODE
    bne 5f
    bl blcmd_update_mode                    @ restart into the bootloader's update mode; returns only with EEVblog's
    b 1f
5:  cmp r0, #BFT_T_LEAVE
    bne 1f
    @ IMP-47: leave the page Ld from the companion (keys do not reach the meter while the page owns the link): what a
    @ SETUP short press on the page does (key/short.s .Lsh_setup_next without the beep): the next page (fn_08015410: Fr
    @ with the two-part bootloader, else rEL) and a redraw of the setup page.  The answer (status 0) is queued first; bft_poll gives the link back on its next
    @ pass, the queued answer still goes out, then the status frames resume.
    movs r0, #0
    bl bft_answer
    bl fn_08015410
    movs r0, #1
    ldr r1, =bft_redraw
    strb r0, [r1]
    pop {r4-r7, pc}
1:  movs r0, #3                             @ unknown type (or 0x18 without the two-part bootloader): not allowed
    b .Lpk_answer
.Lpk_start:
    ldrb r0, [r4, #5]                       @ payload 8 bytes (firmware) or 9 (+ kind)
    movs r5, #0                             @ r5 = kind
    cmp r0, #9
    bne 1f
    ldrb r5, [r4, #14]
    cmp r5, #1
    bhi .Lpk_refuse
    b 2f
1:  cmp r0, #8
    bne .Lpk_refuse
2:  adds r0, r4, #6
    bl bft_le32                             @ size
    cbnz r5, 3f
    cmp r0, #BFT_MIN_SIZE                   @ firmware: 0x124 .. BFT_MAX_SIZE
    blo .Lpk_refuse
    ldr r1, =BFT_MAX_SIZE
    cmp r0, r1
    bhi .Lpk_refuse
    b 4f
3:  cmp r0, #BLI_FILE_MIN                   @ bootloader install: BLI_FILE_MIN .. BLI_FILE_MAX, whole half-pages
    blo .Lpk_refuse
    cmp r0, #BLI_FILE_MAX
    bhi .Lpk_refuse
    tst r0, #0x7F
    bne .Lpk_refuse
4:  ldr r1, =bft_kind
    strb r5, [r1]
    ldr r1, =bft_size
    str r0, [r1]
    adds r0, r4, #10
    bl bft_le32                             @ CRC-32
    ldr r1, =bft_crc
    str r0, [r1]
    movs r0, #0
    ldr r1, =bft_recv
    str r0, [r1]
    ldr r1, =bft_flushed
    str r0, [r1]
    ldr r1, =bft_staged
    str r0, [r1]
    ldr r1, =bft_seq
    strh r0, [r1]
    ldr r1, =bft_fails
    strh r0, [r1]
    ldr r1, =bft_diag
    strh r0, [r1]
    ldr r1, =bft_created
    strb r0, [r1]
    ldr r1, =bfx_staged
    strh r0, [r1]                           @ the received bytes overwrite the data a READ staged (bftsd.s)
    ldr r1, =bft_pct
    strb r0, [r1]
    movs r0, #BFT_ST_RECV
    movs r1, #0
    bl bft_set_state
    movs r0, #0
    b .Lpk_answer
.Lpk_refuse:
    movs r0, #4
    b .Lpk_answer
.Lpk_status:
    @ STATUS: payload 1 byte = index of a diagnosis value, answered in the "next" field (any state, nothing changes)
    ldrb r0, [r4, #5]
    cmp r0, #1
    bne .Lpk_notallowed
    ldrb r0, [r4, #6]
    cmp r0, #BFT_DIAG_N
    bhs .Lpk_notallowed
    ldr r1, =bft_diag_tab
    ldr r1, [r1, r0, lsl #2]                @ address of the value
    ldr r2, =bft_diag_wid
    ldrb r2, [r2, r0]
    cmp r2, #1
    ite eq
    ldrbeq r0, [r1]
    ldrhne r0, [r1]
    bl bft_alt
    movs r0, #0
    b .Lpk_answer
.Lpk_abort:
    movs r0, #BFT_ST_WAIT
    movs r1, #0
    bl bft_set_state
    movs r0, #0
    b .Lpk_answer
.Lpk_data:
    ldr r0, =bft_state
    ldrb r0, [r0]
    cmp r0, #BFT_ST_RECV
    bne .Lpk_notallowed
    ldrb r1, [r4, #3]
    ldrb r0, [r4, #4]
    orr r1, r1, r0, lsl #8                  @ seq
    ldr r2, =bft_seq
    ldrh r3, [r2]
    cmp r1, r3
    beq 1f
    adds r0, r1, #1
    uxth r0, r0
    cmp r0, r3
    bne .Lpk_order                          @ neither the expected packet nor the one before it
    movs r0, #0                             @ the previous packet again (its answer was lost): accepted, not stored
    b .Lpk_answer
1:  ldrb r5, [r4, #5]                       @ r5 = payload length
    ldr r0, =bft_recv
    ldr r6, [r0]                            @ r6 = received so far
    add r1, r6, r5
    ldr r0, =bft_size
    ldr r0, [r0]
    cmp r1, r0
    bhi .Lpk_beyond
    ldr r7, =bft_staged
    ldr r0, [r7]
    ldr r1, =bft_stage
    add r1, r1, r0                          @ destination
    adds r2, r4, #6                         @ payload
    mov r3, r5
2:  cbz r3, 3f
    ldrb r0, [r2], #1
    strb r0, [r1], #1
    subs r3, r3, #1
    b 2b
3:  ldr r0, [r7]
    add r0, r0, r5
    str r0, [r7]                            @ staged += len
    add r6, r6, r5
    ldr r0, =bft_recv
    str r6, [r0]                            @ received += len
    ldr r2, =bft_seq
    ldrh r3, [r2]
    adds r3, r3, #1
    strh r3, [r2]
    @ write to the card when the next full packet might not fit, or when the file is complete
    ldr r0, [r7]
    movw r1, #(BFT_STAGE_LEN - BFT_MAXPAY)
    cmp r0, r1
    bhi 4f
    ldr r0, =bft_size
    ldr r0, [r0]
    cmp r6, r0
    bne 5f
4:  bl bft_flush
    cbz r0, 5f
    movs r0, #BFT_ST_ERR
    movs r1, #1                             @ error 1: card
    bl bft_set_state
    ldr r0, =bft_diag
    ldrh r0, [r0]
    bl bft_alt                              @ the answer reports the failed step and its FatFs result
    movs r0, #0x11
    b .Lpk_answer
5:  @ percent for the page: recv * 100 / size, at most 99 until END has succeeded
    movs r0, #100
    muls r0, r6, r0                         @ <= 0x4C000 * 100: fits
    ldr r1, =bft_size
    ldr r1, [r1]
    udiv r0, r0, r1
    cmp r0, #99
    it hi
    movhi r0, #99
    ldr r1, =bft_pct
    ldrb r2, [r1]
    cmp r0, r2
    beq 6f
    strb r0, [r1]
    movs r0, #1
    ldr r1, =bft_redraw
    strb r0, [r1]
6:  movs r0, #0
    b .Lpk_answer
.Lpk_end:
    ldr r0, =bft_state
    ldrb r0, [r0]
    cmp r0, #BFT_ST_DONE
    bne 1f
    movs r0, #0                             @ END again after success (the answer was lost): done
    b .Lpk_answer
1:  cmp r0, #BFT_ST_RECV
    bne .Lpk_notallowed
    ldr r0, =bft_recv
    ldr r0, [r0]
    ldr r1, =bft_size
    ldr r1, [r1]
    cmp r0, r1
    bne .Lpk_order                          @ bytes missing: the answer names the packet expected
    bl bft_flush                            @ anything left (normally written with the last DATA)
    cbz r0, 2f
    ldr r0, =bft_diag
    ldrh r0, [r0]
    bl bft_alt
    movs r0, #1
    b 3f
2:  bl bft_finish
3:  mov r5, r0
    cbz r5, 4f
    movs r0, #BFT_ST_ERR
    mov r1, r5
    bl bft_set_state
    ldr r0, =bft_diag
    ldrh r0, [r0]
    bl bft_alt                              @ the answer carries the last failed card step and its FatFs result
    add r0, r5, #0x10
    b .Lpk_answer
4:  movs r0, #BFT_ST_DONE
    movs r1, #0
    bl bft_set_state
    ldr r0, =bft_fails
    ldrh r0, [r0]
    bl bft_alt                              @ success: the field reports the failed card sessions that were repeated
    movs r0, #0
    b .Lpk_answer
.Lpk_notallowed:
    movs r0, #3
    b .Lpk_answer
.Lpk_order:
    movs r0, #2
    b .Lpk_answer
.Lpk_beyond:
    movs r0, #5
.Lpk_answer:
    bl bft_answer
    pop {r4-r7, pc}
ENDFUNC bft_packet

@ -----------------------------------------------------------------------------
@ bft_poll - main-loop step: own the link while the page Ld is shown, assemble and handle packets
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (sys/main.s, every pass, before step 11)
@ Note     : at most one packet is handled per pass (a card write can take a second; the loop runs in between)
@ -----------------------------------------------------------------------------
FUNC bft_poll
    push {r4-r7, lr}
    @ a finished bootloader install: restart once the END answer has gone out (the starter then installs, DESIGN.md 6.4)
    ldr r0, =bft_reset_due
    ldrb r0, [r0]
    cbz r0, 0f
    ldr r0, =bft_idle
    ldrb r0, [r0]
    cmp r0, #BFT_RESET_TICKS
    blo 0f
    bl bft_sysreset
0:
    @ is the page Ld active?
    movs r4, #0
    ldr r0, =bft_set_item
    ldrb r0, [r0]
    cmp r0, #BFT_ITEM
    bne 1f
    ldr r0, =bft_ble_enable
    ldrb r0, [r0]
    cbz r0, 1f
    ldr r0, =ble_usart_on
    ldrb r0, [r0]
    cbz r0, 1f
    ldr r0, =bft_logging
    ldrb r0, [r0]
    cbnz r0, 1f
    ldr r0, =bft_cal_mode
    ldrb r0, [r0]
    cbnz r0, 1f
    movs r4, #1
1:  ldr r5, =bft_active
    ldrb r0, [r5]
    cmp r4, r0
    beq 3f
    @ change of ownership: start or end with an empty ring and the parser at a packet start
    mrs r7, primask
    cpsid i
    strb r4, [r5]
    ldr r1, =bft_rx_head
    ldrh r0, [r1]
    ldr r1, =bft_rx_tail
    strh r0, [r1]                           @ ring empty
    movs r0, #0
    ldr r1, =bft_legacy_idx
    strb r0, [r1]                           @ the v2.05 parser starts at a frame start again
    msr primask, r7
    movs r0, #0
    ldr r1, =bft_pos
    strh r0, [r1]
    ldr r1, =bfx_staged
    strh r0, [r1]                           @ IMP-36: the staged READ bytes are void once the page changes owner
                                            @ (log_buf may be reused by logging or cal.bin meanwhile)
    movs r0, #BFT_ST_WAIT
    movs r1, #0
    bl bft_set_state                        @ waiting (also after leaving: shown when the page comes back)
3:  cmp r4, #0
    beq .Lpo_ret
    @ a packet cut short (a byte lost: ring full, or received while the card was written) is dropped after 200 ms
    @ without a byte, so the sender's repetition starts on a fresh packet
    ldr r1, =bft_pos
    ldrh r0, [r1]
    cbz r0, 31f
    ldr r0, =bft_idle
    ldrb r0, [r0]
    cmp r0, #BFT_GAP_TICKS
    blo 31f
    movs r0, #0
    strh r0, [r1]
31:
    @ assemble: bytes from the ring into bft_pkt
    ldr r6, =bft_pkt
.Lpo_byte:
    ldr r1, =bft_rx_tail
    ldrh r2, [r1]
    ldr r0, =bft_rx_head
    ldrh r0, [r0]
    cmp r0, r2
    beq .Lpo_ret                            @ ring empty
    ldr r0, =bft_ring
    ldrb r3, [r0, r2]                       @ r3 = byte
    adds r2, r2, #1
    bfc r2, #9, #23
    strh r2, [r1]
    ldr r1, =bft_pos
    ldrh r7, [r1]                           @ r7 = position
    cbnz r7, 4f
    cmp r3, #0xB5
    bne .Lpo_byte                           @ not a packet start
    strb r3, [r6, #0]
    movs r7, #1
    b .Lpo_store
4:  cmp r7, #1
    bne 5f
    cmp r3, #0x5B
    beq 41f
    cmp r3, #0xB5
    ite eq
    moveq r7, #1                            @ B5 B5: the second one may start the packet
    movne r7, #0
    b .Lpo_store
41: strb r3, [r6, #1]
    movs r7, #2
    b .Lpo_store
5:  strb r3, [r6, r7]
    adds r7, r7, #1
    cmp r7, #6
    blo .Lpo_store
    ldrb r0, [r6, #5]                       @ payload length
    cmp r0, #BFT_MAXPAY
    bls 6f
    movs r7, #0                             @ impossible length: resynchronise
    b .Lpo_store
6:  adds r0, r0, #8
    cmp r7, r0
    blo .Lpo_store
    @ complete: check the CRC, then handle (one packet per pass)
    movs r0, #0
    strh r0, [r1]                           @ next packet starts at 0
    ldrb r5, [r6, #5]
    adds r0, r6, #2
    adds r1, r5, #4
    bl bft_crc16
    adds r5, r5, #6
    ldrb r1, [r6, r5]
    adds r5, r5, #1
    ldrb r2, [r6, r5]
    orr r1, r1, r2, lsl #8
    cmp r0, r1
    beq 7f
    ldr r0, =xd_bft_crc_bad
    bl xd_inc                               @ IMP-44: counted while the extended link diagnosis is on
    movs r0, #1                             @ CRC wrong: resend
    bl bft_answer
    b .Lpo_ret
7:  bl bft_packet
    b .Lpo_ret
.Lpo_store:
    ldr r1, =bft_pos
    strh r7, [r1]
    b .Lpo_byte
.Lpo_ret:
    pop {r4-r7, pc}
ENDFUNC bft_poll

@ -----------------------------------------------------------------------------
@ set_bft_draw - draw the page Ld (setup item 39)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ -----------------------------------------------------------------------------
FUNC set_bft_draw
    push {r4, lr}
    sub sp, sp, #8
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    str r1, [r0, #0x10]
    movs r0, #0
    bl fn_08017FB4                          @ sub decimal points off
    movs r0, #'L'
    strb r0, [sp, #0]
    movs r0, #'d'
    strb r0, [sp, #1]
    ldr r0, =bft_state
    ldrb r0, [r0]
    cmp r0, #BFT_ST_RECV
    beq .Lbd_pct
    cmp r0, #BFT_ST_DONE
    beq .Lbd_ok
    cmp r0, #BFT_ST_ERR
    beq .Lbd_err
    movs r0, #'-'                           @ waiting: "Ld-bt"
    strb r0, [sp, #2]
    movs r0, #'b'
    strb r0, [sp, #3]
    movs r0, #'t'
    strb r0, [sp, #4]
    b .Lbd_draw
.Lbd_pct:
    movs r0, #' '                           @ "Ld nn"
    strb r0, [sp, #2]
    ldr r0, =bft_pct
    ldrb r0, [r0]
    movs r1, #10
    udiv r2, r0, r1
    mls r3, r2, r1, r0
    adds r2, r2, #'0'
    strb r2, [sp, #3]
    adds r3, r3, #'0'
    strb r3, [sp, #4]
    b .Lbd_draw
.Lbd_ok:
    movs r0, #' '                           @ "Ld oK"
    strb r0, [sp, #2]
    movs r0, #'o'
    strb r0, [sp, #3]
    movs r0, #'K'
    strb r0, [sp, #4]
    b .Lbd_draw
.Lbd_err:
    movs r0, #'E'                           @ "LdE n"
    strb r0, [sp, #2]
    movs r0, #' '
    strb r0, [sp, #3]
    ldr r0, =bft_err
    ldrb r0, [r0]
    adds r0, r0, #'0'
    strb r0, [sp, #4]
.Lbd_draw:
    movs r0, #1
    mov r1, sp
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =bft_commit
    strb r0, [r1]
    add sp, sp, #8
    pop {r4, pc}
ENDFUNC set_bft_draw

    .ltorg

