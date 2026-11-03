@ diskio.s - SD module: the disk layer that FatFs calls, the card bring-up and the card power-off (DESIGN.md 6.23, W8)
@
@ The routines disk_initialize, disk_status, disk_read, disk_write, disk_ioctl and get_fattime are the FatFs low-level
@ interface (diskio) of drive 0, the SD card.  Sector size is 512 bytes; read and write address the card by byte address
@ (sector * 512, the SDHC conversion to block numbers is done by sd_read_block and sd_write_blocks).  Every transfer is
@ followed by polling the card state with CMD13 (sd_get_status) up to 20000 times until it is back in the transfer state.
@ sd_bringup and sd_probe_mount are the "bring-up" that the log session and cal.bin run before opening files.
@
@ Deviation of this file: OF-42 (disk_read honours the sector count).
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
    .equ fat_fs_obj,              v_20006830            @ 0x20006830 FATFS work area of drive 0 (registered by f_mount)
    .equ sd_stop_condition,       v_20007EF0            @ 0x20007EF0 1 = the running transfer is a multi-block write that needs CMD12; 0 = single block read
    .equ sd_transfer_end,         v_20007EF4            @ 0x20007EF4 set to 1 by the SDIO interrupt at the end of the data transfer
    .equ sd_dma_end,              v_20007EF8            @ 0x20007EF8 set to 1 by the DMA interrupt when the DMA transfer is complete
    .equ sd_transfer_error,       v_200080F7            @ 0x200080F7 error code set by the SDIO interrupt (0 none, 2 CRC fail, 4 timeout, 5 TX underrun, 6 RX overrun, 7 start bit error)

@ -----------------------------------------------------------------------------
@ sd_bringup_retry - bring the card up, repeating sd_bringup up to r0 times
@ Replaces  : 0x0801F84C FUN_0801F84C (v2.05), canonical symbol fn_0801F84C, called by log_session_once and by calbin_save / calbin_load (CAL)
@ In        : r0 = number of tries (u8; 10)
@ Out       : r0 = 0 ok (also when r0 tries = 0 and nothing was tried: the initial result 0), 1 or 2 = result of the last sd_bringup
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only; the caller holds SYSCLK = HSE (sys_clock_select(1))
@ Spec      : v2.05 listing 0x0801F84C..0x0801F87D
@ Note      : because sd_bringup reports success even when no card answers (see sd_bringup), this routine returns 0 after the first
@             call in every case seen; the card is really tested by the first file call (fat_chk_mounted -> disk_initialize).
@ -----------------------------------------------------------------------------
FUNC sd_bringup_retry
    push    {r4, r5, r6, lr}                @ 0801F84C push {r4, r5, r6, lr}
    movs    r4, r0                          @ 0801F84E r4 = r0
    movs    r5, #0                          @ 0801F850 r5 = 0
    movs    r0, #0                          @ 0801F852 r0 = 0
    movs    r6, r0                          @ 0801F854 r6 = r0
.Lsd_bringup_retry_F856:                @ v2.05 0x0801F856, reached from 0x0801F876
    movs    r0, r6                          @ 0801F856 r0 = r6
    movs    r1, r4                          @ 0801F858 r1 = r4
    uxtb    r0, r0                          @ 0801F85A r0 = u8(r0)
    uxtb    r1, r1                          @ 0801F85C r1 = u8(r1)
    cmp     r0, r1                          @ 0801F85E compare r0 with r1
    bhs     .Lsd_bringup_retry_F878         @ 0801F860 if (r0 >=u r1) goto 0x801F878
    bl      sd_bringup                      @ 0801F862 call sd_bringup
    movs    r5, r0                          @ 0801F866 r5 = r0
    uxtb    r5, r5                          @ 0801F868 r5 = u8(r5)
    cmp     r5, #0                          @ 0801F86A compare r5 with 0
    bne     .Lsd_bringup_retry_F874         @ 0801F86C if (r5 != 0) goto 0x801F874
    movs    r0, r5                          @ 0801F86E r0 = r5
    uxtb    r0, r0                          @ 0801F870 r0 = u8(r0)
    b       .Lsd_bringup_retry_F87C         @ 0801F872 goto 0x801F87C
.Lsd_bringup_retry_F874:                @ v2.05 0x0801F874, reached from 0x0801F86C
    adds    r6, r6, #1                      @ 0801F874 r6 = r6 + 1
    b       .Lsd_bringup_retry_F856         @ 0801F876 goto 0x801F856
.Lsd_bringup_retry_F878:                @ v2.05 0x0801F878, reached from 0x0801F860
    movs    r0, r5                          @ 0801F878 r0 = r5
    uxtb    r0, r0                          @ 0801F87A r0 = u8(r0)
.Lsd_bringup_retry_F87C:                @ v2.05 0x0801F87C, reached from 0x0801F872
    pop     {r4, r5, r6, pc}                @ 0801F87C pop {r4, r5, r6, pc}
ENDFUNC sd_bringup_retry
    .global fn_0801F84C
    .thumb_set fn_0801F84C, sd_bringup_retry
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_bringup - reset the SDIO block and probe the card, up to 0x301 times
@ Replaces  : 0x0801F87E FUN_0801F87E (v2.05), called by sd_bringup_retry
@ In        : -
@ Out       : r0 = 0 ok; 1 only if the probe succeeded exactly on the last pass (see Note); 2 if sd_detect were 0 (it never is)
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0801F87E..0x0801F8B9
@ Note      : each pass is sdio_gpio_deinit followed by sd_probe_mount; a pass that returns 0 ends the loop.  The failure test after
@             the loop looks at r6, the loop counter, which is decremented after the last failed pass (0x0801F898) and then holds
@             0xFFFFFFFF, so the test r6 == 0 at 0x0801F89E is true only if the probe succeeded exactly on the last pass.  After 0x301
@             failed passes the routine therefore returns 0 (the sd_detect test that follows is always true, sd_detect returns 1).
@             sd_probe_mount returns 0 whenever f_mount returns 0, which it always does (f_mount only registers the work area), so the
@             first pass ends the loop and the routine returns 0 without ever having tested the card.  Behaviour kept as v2.05.
@ -----------------------------------------------------------------------------
FUNC sd_bringup
    push    {r4, r5, r6, lr}                @ 0801F87E push {r4, r5, r6, lr}
    movs    r4, #0                          @ 0801F880 r4 = 0
    movs    r5, #0                          @ 0801F882 r5 = 0
    mov.w   r6, #0x300                      @ 0801F884 r6 = 0x300
    @ deinitialise the SDIO pins and block, then probe
.Lsd_bringup_F888:                      @ v2.05 0x0801F888, reached from 0x0801F89C
    bl      sdio_gpio_deinit                @ 0801F888 call sdio_gpio_deinit
    bl      sd_probe_mount                  @ 0801F88C call sd_probe_mount
    movs    r5, r0                          @ 0801F890 r5 = r0
    cmp     r5, #0                          @ 0801F892 compare r5 with 0
    beq     .Lsd_bringup_F89E               @ 0801F894 if (r5 == 0) goto 0x801F89E
    movs    r0, r6                          @ 0801F896 r0 = r6
    subs    r6, r0, #1                      @ 0801F898 r6 = r0 - 1
    cmp     r0, #0                          @ 0801F89A compare r0 with 0
    bne     .Lsd_bringup_F888               @ 0801F89C if (r0 != 0) goto 0x801F888
    @ r6 == 0 only when the probe succeeded exactly on the last of the 0x301 passes: return 1; otherwise sd_detect (always 1): return 0
.Lsd_bringup_F89E:                      @ v2.05 0x0801F89E, reached from 0x0801F894
    cmp     r6, #0                          @ 0801F89E compare r6 with 0
    bne     .Lsd_bringup_F8A8               @ 0801F8A0 if (r6 != 0) goto 0x801F8A8
    movs    r0, #1                          @ 0801F8A2 r0 = 1
    movs    r4, r0                          @ 0801F8A4 r4 = r0
    b       .Lsd_bringup_F8B4               @ 0801F8A6 goto 0x801F8B4
.Lsd_bringup_F8A8:                      @ v2.05 0x0801F8A8, reached from 0x0801F8A0
    bl      sd_detect                       @ 0801F8A8 call sd_detect
    cmp     r0, #0                          @ 0801F8AC compare r0 with 0
    bne     .Lsd_bringup_F8B4               @ 0801F8AE if (r0 != 0) goto 0x801F8B4
    movs    r0, #2                          @ 0801F8B0 r0 = 2
    movs    r4, r0                          @ 0801F8B2 r4 = r0
.Lsd_bringup_F8B4:                      @ v2.05 0x0801F8B4, reached from 0x0801F8A6, 0x0801F8AE
    movs    r0, r4                          @ 0801F8B4 r0 = r4
    uxtb    r0, r0                          @ 0801F8B6 r0 = u8(r0)
    pop     {r4, r5, r6, pc}                @ 0801F8B8 pop {r4, r5, r6, pc}
ENDFUNC sd_bringup
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_probe_mount - try to initialise the card and register the file system work area
@ Replaces  : 0x0801F8BA FUN_0801F8BA (v2.05), called by sd_bringup
@ In        : -
@ Out       : r0 = 0 when f_mount returned 0 (always), 1 otherwise
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : registers fat_fs_obj 0x20006830 as work area of drive 0
@ Spec      : v2.05 listing 0x0801F8BA..0x0801F8D5
@ Note      : the result of sd_init is not looked at; the card is initialised here (and again at the first file call, because the
@             mount is lazy and fs_type is 0 after f_mount).
@ -----------------------------------------------------------------------------
FUNC sd_probe_mount
    push    {r7, lr}                        @ 0801F8BA push {r7, lr}
    bl      sd_init                         @ 0801F8BC call sd_init
    ldr.w   r1, =fat_fs_obj                 @ 0801F8C0 r1 = &fat_fs_obj
    movs    r0, #0                          @ 0801F8C4 r0 = 0
    bl      fat_f_mount                     @ 0801F8C6 call fat_f_mount
    cmp     r0, #0                          @ 0801F8CA compare r0 with 0
    beq     .Lsd_probe_mount_F8D2           @ 0801F8CC if (r0 == 0) goto 0x801F8D2
    movs    r0, #1                          @ 0801F8CE r0 = 1
    b       .Lsd_probe_mount_F8D4           @ 0801F8D0 goto 0x801F8D4
.Lsd_probe_mount_F8D2:                  @ v2.05 0x0801F8D2, reached from 0x0801F8CC
    movs    r0, #0                          @ 0801F8D2 r0 = 0
.Lsd_probe_mount_F8D4:                  @ v2.05 0x0801F8D4, reached from 0x0801F8D0
    pop     {r1, pc}                        @ 0801F8D4 pop {r1, pc}
ENDFUNC sd_probe_mount
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_get_status - card status for the polling loops: 0 transfer state, 1 busy, 2 error
@ Replaces  : 0x0802268A FUN_0802268A (v2.05), called by disk_read and disk_write
@ In        : -
@ Out       : r0 = 0 the card is in the transfer state (state 4), 2 the state could not be read (0xFF), 1 any other state
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802268A..0x080226AB (ST driver SD_GetStatus)
@ -----------------------------------------------------------------------------
FUNC sd_get_status
    push    {r4, lr}                        @ 0802268A push {r4, lr}
    movs    r4, #4                          @ 0802268C r4 = 4
    bl      sd_get_state                    @ 0802268E call sd_get_state
    movs    r4, r0                          @ 08022692 r4 = r0
    uxtb    r4, r4                          @ 08022694 r4 = u8(r4)
    cmp     r4, #4                          @ 08022696 compare r4 with 4
    bne     .Lsd_get_status_269E            @ 08022698 if (r4 != 4) goto 0x802269E
    movs    r0, #0                          @ 0802269A r0 = 0
    b       .Lsd_get_status_26AA            @ 0802269C goto 0x80226AA
.Lsd_get_status_269E:                   @ v2.05 0x0802269E, reached from 0x08022698
    uxtb    r4, r4                          @ 0802269E r4 = u8(r4)
    cmp     r4, #0xff                       @ 080226A0 compare r4 with 0xff
    bne     .Lsd_get_status_26A8            @ 080226A2 if (r4 != 0xff) goto 0x80226A8
    movs    r0, #2                          @ 080226A4 r0 = 2
    b       .Lsd_get_status_26AA            @ 080226A6 goto 0x80226AA
.Lsd_get_status_26A8:                   @ v2.05 0x080226A8, reached from 0x080226A2
    movs    r0, #1                          @ 080226A8 r0 = 1
.Lsd_get_status_26AA:                   @ v2.05 0x080226AA, reached from 0x0802269C, 0x080226A6
    pop     {r4, pc}                        @ 080226AA pop {r4, pc}
ENDFUNC sd_get_status
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_get_state - current state field of the card status (CMD13)
@ Replaces  : 0x080226AC FUN_080226AC (v2.05), called by sd_get_status
@ In        : -
@ Out       : r0 = (card status >> 9) & 0xF (0 idle .. 4 transfer .. 7 programming), or 0xFF when the card is not present or CMD13 failed
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080226AC..0x080226D5 (ST driver SD_GetState)
@ -----------------------------------------------------------------------------
FUNC sd_get_state
    push    {r7, lr}                        @ 080226AC push {r7, lr}
    movs    r0, #0                          @ 080226AE r0 = 0
    str     r0, [sp]                        @ 080226B0 u32 [sp] = r0
    bl      sd_detect                       @ 080226B2 call sd_detect
    cmp     r0, #1                          @ 080226B6 compare r0 with 1
    bne     .Lsd_get_state_26D2             @ 080226B8 if (r0 != 1) goto 0x80226D2
    mov     r0, sp                          @ 080226BA r0 = sp
    bl      sd_send_status                  @ 080226BC call sd_send_status
    cmp     r0, #0                          @ 080226C0 compare r0 with 0
    beq     .Lsd_get_state_26C8             @ 080226C2 if (r0 == 0) goto 0x80226C8
    movs    r0, #0xff                       @ 080226C4 r0 = 0xff
    b       .Lsd_get_state_26D4             @ 080226C6 goto 0x80226D4
.Lsd_get_state_26C8:                    @ v2.05 0x080226C8, reached from 0x080226C2
    ldr     r0, [sp]                        @ 080226C8 r0 = u32 [sp]
    lsrs    r0, r0, #9                      @ 080226CA r0 = r0 >> 9
    ands    r0, r0, #0xf                    @ 080226CC r0 = r0 & 0xf
    b       .Lsd_get_state_26D4             @ 080226D0 goto 0x80226D4
.Lsd_get_state_26D2:                    @ v2.05 0x080226D2, reached from 0x080226B8
    movs    r0, #0xff                       @ 080226D2 r0 = 0xff
.Lsd_get_state_26D4:                    @ v2.05 0x080226D4, reached from 0x080226C6, 0x080226D0
    pop     {r1, pc}                        @ 080226D4 pop {r1, pc}
ENDFUNC sd_get_state
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_detect - card detect: always present
@ Replaces  : 0x080226D6 FUN_080226D6 (v2.05), called by sd_get_state and sd_bringup
@ In        : -
@ Out       : r0 = 1
@ Clobbers  : r0, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080226D6..0x080226E5; the board has no card-detect contact
@ -----------------------------------------------------------------------------
FUNC sd_detect
    sub     sp, #4                          @ 080226D6 sp -= 4
    movs    r0, #1                          @ 080226D8 r0 = 1
    strb.w  r0, [sp]                        @ 080226DA u8 [sp] = r0
    ldrb.w  r0, [sp]                        @ 080226DE r0 = u8 [sp]
    add     sp, #4                          @ 080226E2 sp += 4
    bx      lr                              @ 080226E4 return
ENDFUNC sd_detect
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_power_off - switch the SDIO block power off (the board has no switch for the card supply, so the card stays powered)
@ Replaces  : 0x08022932 FUN_08022932 (v2.05), canonical symbol fn_08022932, called by log_session_once, calbin_save, calbin_load and the main loop
@ In        : -
@ Out       : r0 = 0
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08022932..0x08022941; SDIO_POWER = 0 (sdio_set_power_state(0))
@ -----------------------------------------------------------------------------
FUNC sd_power_off
    push    {r4, lr}                        @ 08022932 push {r4, lr}
    movs    r4, #0                          @ 08022934 r4 = 0
    movs    r0, #0                          @ 08022936 r0 = 0
    bl      sdio_set_power_state            @ 08022938 call sdio_set_power_state
    movs    r0, r4                          @ 0802293C r0 = r4
    uxtb    r0, r0                          @ 0802293E r0 = u8(r0)
    pop     {r4, pc}                        @ 08022940 pop {r4, pc}
ENDFUNC sd_power_off
    .global fn_08022932
    .thumb_set fn_08022932, sd_power_off
    .ltorg

@ -----------------------------------------------------------------------------
@ disk_initialize - initialise the card (FatFs disk_initialize)
@ Replaces  : 0x08023F5C FUN_08023F5C (v2.05), called by fat_chk_mounted
@ In        : r0 = drive (not used)
@ Out       : r0 = 0 the card is ready, 1 (STA_NOINIT) sd_init failed with any SD error code
@ Clobbers  : r0-r3, r12, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08023F5C..0x08023F6D (the constant 0x29 stored in r5 first is overwritten)
@ Deviation : OF-59 (ORIGINAL_FIRMWARE_ISSUES.md): v2.05 returns the sd_init code as the disk status; fat_chk_mounted takes only bit 0
@             (STA_NOINIT, 0x080217CE), so a failure with an even code (2 CRC fail, 4 timeout, 6, 0xE, 0x10, 0x26) counted as a
@             ready card and the volume was mounted from whatever the reads then returned.
@ -----------------------------------------------------------------------------
FUNC disk_initialize
    push    {r3, r4, r5, lr}                @ 08023F5C push {r3, r4, r5, lr}
    movs    r4, r0                          @ 08023F5E r4 = r0
    movs    r5, #0x29                       @ 08023F60 r5 = 0x29
    bl      sd_init                         @ 08023F62 call sd_init
    movs    r5, r0                          @ 08023F66 r5 = r0
    cmp     r5, #0
    ite     eq
    moveq   r0, #0                          @ sd_init ok: status 0 (ready)
    movne   r0, #1                          @ any SD error: STA_NOINIT (OF-59; v2.05 returns the error code itself, 0x08023F68,
                                            @ and fat_chk_mounted tests only bit 0, so the even codes passed as ready)
    pop     {r1, r4, r5, pc}                @ 08023F6C pop {r1, r4, r5, pc}
ENDFUNC disk_initialize
    .ltorg

@ -----------------------------------------------------------------------------
@ disk_status - disk status (FatFs disk_status)
@ Replaces  : 0x08023F6E FUN_08023F6E (v2.05), called by fat_validate and fat_chk_mounted
@ In        : r0 = drive
@ Out       : r0 = 0 for drive 0 (ready), 1 (STA_NOINIT) for any other drive
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08023F6E..0x08023F7D; no card detect and no write protect switch exist on the board (the SD socket has none, emulator/emu/periph/sdio.py)
@ -----------------------------------------------------------------------------
FUNC disk_status
    movs    r1, r0                          @ 08023F6E r1 = r0
    uxtb    r1, r1                          @ 08023F70 r1 = u8(r1)
    cmp     r1, #0                          @ 08023F72 compare r1 with 0
    beq     .Ldisk_status_3F7A              @ 08023F74 if (r1 == 0) goto 0x8023F7A
    movs    r0, #1                          @ 08023F76 r0 = 1
    b       .Ldisk_status_3F7C              @ 08023F78 goto 0x8023F7C
.Ldisk_status_3F7A:                     @ v2.05 0x08023F7A, reached from 0x08023F74
    movs    r0, #0                          @ 08023F7A r0 = 0
.Ldisk_status_3F7C:                     @ v2.05 0x08023F7C, reached from 0x08023F78
    bx      lr                              @ 08023F7C return
ENDFUNC disk_status
    .ltorg

@ -----------------------------------------------------------------------------
@ disk_read - read r3 sectors from the SD card (FatFs disk_read)
@ Replaces : 0x08023F7E FUN_08023F7E (v2.05)
@ In       : r0 = drive (0), r1 = buffer, r2 = first sector number, r3 = sector count (u8)
@ Out      : r0 = 0 ok, 2 the card did not return to the transfer state within 20000 status polls, 1 (RES_ERROR) the SDIO
@            reported an error for the block or its data end / DMA end did not come within 20000 polls (OF-59)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main only
@ Spec     : v2.05 listing 0x08023F7E..0x08023FB7; the SD command sequence per sector (CMD16 512, CMD17 sector, then CMD13
@            polling) is sd_read_block + sd_get_status as in v2.05
@ Deviation: OF-42 (ORIGINAL_FIRMWARE_ISSUES.md).  v2.05 reads exactly one sector whatever r3 says: the routine keeps r3 in r6 and never uses it
@            (0x08023F8A..0x08023FB4).  FatFs passes a count greater than 1 when f_read has whole sectors for the caller
@            (0x08021E58..0x08021E80), and then only the first sector would arrive in the caller's buffer.  No v2.05 caller
@            asks for more than one sector (the log verification and cal.bin read 512 bytes per call, the FAT, directory and
@            window reads are single sectors), so no v2.05 behaviour is visible; with count = 1 this routine is the v2.05
@            routine.  The port reads the sectors one by one (sector s + i into buffer + 512 * i), like disk_write, and stops
@            at the first failure.  OF-57: the 64-bit byte address (v2.05: upper word 0, wrong past 4 GiB).  OF-59: each block
@            is taken only after the SDIO data end and the DMA end, and an SDIO error (sd_transfer_error) fails the read.
@ -----------------------------------------------------------------------------
FUNC disk_read
    push    {r4, r5, r6, r7, r8, lr}
    sub     sp, sp, #8                      @ [sp] = byte count argument of sd_read_block (8-byte aligned frame)
    movs    r4, r0                          @ r4 = drive (unused, v2.05 keeps it in r4)
    mov     r8, r1                          @ r8 = buffer
    movs    r5, r2                          @ r5 = first sector
    uxtb    r6, r3                          @ r6 = sectors left (u8, as disk_write)
.Ldr_next:
    cbz     r6, .Ldr_done                   @ nothing left: success
    movw    r7, #0x4E20                     @ r7 = 20000 status polls (v2.05 0x08023F8C)
    movs    r0, #0x200
    str     r0, [sp]                        @ block length 0x200 (5th argument)
    lsls    r2, r5, #9                      @ r2:r3 = 64-bit byte address = sector * 512 (sd_read_block turns it into the block
    lsrs    r3, r5, #23                     @ number for SDHC cards); OF-57: v2.05 sets the upper word to 0 (0x08023F98)
    movs    r0, #0
    ldr     r1, =sd_dma_end
    str     r0, [r1]                        @ OF-59: the DMA end flag of this block (sd_read_block clears only the SDIO flags)
    movw    r0, #0x23a
    ldr     r1, =(SDIO_BASE + SDIO_ICR)
    str     r0, [r1]                        @ OF-59: data error flags of SDIO_STA cleared, so that the test after the block sees
                                            @ only this block's errors
    mov     r0, r8
    mov     r1, r8                          @ v2.05 passes the buffer twice (0x08023F9A)
    bl      sd_read_block
.Ldr_poll:
    bl      sd_get_status                   @ 0 = card in the transfer state
    cmp     r0, #0
    beq     .Ldr_end
    subs    r7, r7, #1                      @ 0x08023FA8
    cmp     r7, #0                          @ 0x08023FAA: kept although subs set the flags, so that one poll takes the
                                            @ v2.05 instruction count and the number of CMD13 commands per sector is v2.05's
    bne     .Ldr_poll                       @ at most 20000 polls (0x08023FAC)
    movs    r0, #2                          @ timeout: RES_ERROR
    b       .Ldr_ret
    @ OF-59: the card has sent the block; wait for the SDIO data end and the DMA end, or an SDIO error (v2.05 takes the
    @ buffer as soon as the card is back in the transfer state and never looks at sd_transfer_error)
.Ldr_end:
    movw    r7, #0x4E20                     @ at most 20000 polls
1:  ldr     r0, =sd_transfer_error
    ldrb    r0, [r0]
    cbnz    r0, .Ldr_err                    @ CRC fail, timeout, overrun or start bit error: the data is not valid
    ldr     r0, =(SDIO_BASE + SDIO_STA)
    ldr     r0, [r0]
    movw    r1, #0x23a
    tst     r0, r1
    bne     .Ldr_err                        @ the same errors flagged in SDIO_STA (the handler serves DATAEND first and then
                                            @ masks all sources, so an error flagged with DATAEND appears only here)
    ldr     r0, =sd_transfer_end
    ldr     r0, [r0]
    ldr     r1, =sd_dma_end
    ldr     r1, [r1]
    ands    r0, r0, r1
    bne     .Ldr_ok                         @ both ends seen: the block is in the buffer
    subs    r7, r7, #1
    bne     1b
.Ldr_err:
    movs    r0, #1                          @ RES_ERROR
    b       .Ldr_ret
.Ldr_ok:
    add     r8, r8, #0x200                  @ next 512 bytes of the buffer
    adds    r5, r5, #1                      @ next sector
    subs    r6, r6, #1
    b       .Ldr_next
.Ldr_done:
    movs    r0, #0
.Ldr_ret:
    add     sp, sp, #8
    pop     {r4, r5, r6, r7, r8, pc}
    .ltorg
ENDFUNC disk_read

@ -----------------------------------------------------------------------------
@ disk_write - write r3 sectors to the SD card (FatFs disk_write)
@ Replaces  : 0x08023FB8 FUN_08023FB8 (v2.05), called by fat_move_window, fat_f_read, fat_f_write, fat_f_sync, fat_f_lseek, fat_sync_fs
@ In        : r0 = drive, r1 = buffer, r2 = first sector number, r3 = sector count (u8)
@ Out       : r0 = 0 ok, 2 the card did not return to the transfer state within 20000 CMD13 polls, 1 (RES_ERROR) the block was
@             rejected (OF-59)
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ RAM       : uses the SD driver state (sd_stop_condition, sd_transfer_end, sd_dma_end, sd_transfer_error)
@ Spec      : v2.05 listing 0x08023FB8..0x0802402D
@ Note      : one sector at a time: sd_write_blocks (CMD16 512, CMD55, ACMD23 with one block, CMD25, data by DMA2 channel 4),
@             sd_wait_write (waits for the end of the data and sends CMD12), then CMD13 polling (sd_get_status).
@ Deviation : OF-57: the 64-bit byte address (v2.05 computes it in 32 bits, wrong past 4 GiB).  OF-59: v2.05 looks at neither the
@             SDIO error code (sd_transfer_error) nor the return value of sd_wait_write, so a block the card rejected (negative CRC
@             status token) counted as written and was only noticed, if at all, by the read-back verification of the log
@             (log_verify_file) or of cal.bin; the port keeps v2.05's sequence (the card is polled back to the transfer state) and
@             then returns RES_ERROR for such a block.
@ -----------------------------------------------------------------------------
FUNC disk_write
    push.w  {r4, r5, r6, r7, r8, r9, r10, r11, lr}@ 08023FB8 push {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    sub     sp, #0xc                        @ 08023FBC sp -= 0xc
    mov     r11, r0                         @ 08023FBE r11 = r0
    mov     r10, r1                         @ 08023FC0 r10 = r1
    movs    r5, r2                          @ 08023FC2 r5 = r2
    movs    r6, r3                          @ 08023FC4 r6 = r3
    movs    r7, #0                          @ 08023FC6 r7 = 0
    movs.w  r8, #0                          @ 08023FC8 r8 = 0
    movs    r4, #0                          @ 08023FCC r4 = 0
    movs    r0, #0                          @ 08023FCE r0 = 0
    movs    r7, r0                          @ 08023FD0 r7 = r0
    @ loop over the sectors: buffer offset 512 * i, 64-bit byte address (first sector + i) * 512
.Ldisk_write_3FD2:                      @ v2.05 0x08023FD2, reached from 0x08024026
    uxtb    r6, r6                          @ 08023FD2 r6 = u8(r6)
    cmp     r7, r6                          @ 08023FD4 compare r7 with r6
    bhs     .Ldisk_write_4028               @ 08023FD6 if (r7 >=u r6) goto 0x8024028
    mov.w   r0, #0x200                      @ 08023FD8 r0 = 0x200
    mul     r0, r0, r7                      @ 08023FDC r0 = r0 * r7
    add     r0, r10                         @ 08023FE0 r0 += r10
    mov     r8, r0                          @ 08023FE2 r8 = r0
    adds    r1, r5, r7                      @ r1 = sector of this block (first sector + i)
    lsls    r4, r1, #9                      @ r4 = low word of the byte address sector * 512
    lsrs    r1, r1, #23                     @ r1 = upper word (OF-57: v2.05 computes (first << 9) + 512 * i in 32 bits,
                                            @ 0x08023FE4..0x08023FEA, and passes 0 as the upper word, 0x08023FFC)
    movs    r0, #1                          @ 08023FF0 r0 = 1
    str     r0, [sp, #4]                    @ 08023FF2 u32 [sp+0x4] = r0
    mov.w   r0, #0x200                      @ 08023FF4 r0 = 0x200
    str     r0, [sp]                        @ 08023FF8 u32 [sp] = r0
    movs    r2, r4                          @ 08023FFA r2 = r4
    movs    r3, r1                          @ r3 = upper word of the byte address (OF-57)
    mov     r0, r8                          @ 08023FFE r0 = r8
    @ start the write (CMD16, CMD55, ACMD23, CMD25) and the DMA
    bl      sd_write_blocks                 @ 08024000 call sd_write_blocks
    @ wait for the end of the transfer, send CMD12
    bl      sd_wait_write                   @ 08024004 call sd_wait_write
    ldr     r1, =sd_transfer_error
    ldrb    r1, [r1]
    orrs    r0, r0, r1
    str     r0, [sp, #8]                    @ OF-59: [sp+8] = non-zero when sd_wait_write failed or the SDIO reported an error
                                            @ (CRC status token negative, timeout, underrun); the card is still polled below
    movw    r0, #0x4e20                     @ 08024008
    mov     r9, r0                          @ 0802400C r9 = r0
    @ poll the card state with CMD13 up to 20000 times: transfer state = ready
.Ldisk_write_400E:                      @ v2.05 0x0802400E, reached from 0x0802401E
    bl      sd_get_status                   @ 0802400E call sd_get_status
    cmp     r0, #0                          @ 08024012 compare r0 with 0
    beq     .Ldisk_write_4024               @ 08024014 if (r0 == 0) goto 0x8024024
    subs.w  r9, r9, #1                      @ 08024016 r9 = r9 - 1
    cmp.w   r9, #0                          @ 0802401A compare r9 with 0
    bne     .Ldisk_write_400E               @ 0802401E if (r9 != 0) goto 0x802400E
    movs    r0, #2                          @ 08024020 r0 = 2
    b       .Ldisk_write_402A               @ 08024022 goto 0x802402A
.Ldisk_write_4024:                      @ v2.05 0x08024024, reached from 0x08024014
    ldr     r0, [sp, #8]
    cbz     r0, 1f
    movs    r0, #1                          @ OF-59: the block was not written: RES_ERROR
    b       .Ldisk_write_402A
1:  adds    r7, r7, #1                      @ 08024024 r7 = r7 + 1
    b       .Ldisk_write_3FD2               @ 08024026 goto 0x8023FD2
.Ldisk_write_4028:                      @ v2.05 0x08024028, reached from 0x08023FD6
    movs    r0, #0                          @ 08024028 r0 = 0
.Ldisk_write_402A:                      @ v2.05 0x0802402A, reached from 0x08024022
    pop.w   {r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}@ 0802402A pop {r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, pc}
ENDFUNC disk_write
    .ltorg

@ -----------------------------------------------------------------------------
@ get_fattime - time stamp of the file being created or written (FatFs get_fattime)
@ Replaces  : 0x0802402E FUN_0802402E (v2.05), called by fat_f_open and fat_f_sync
@ In        : -
@ Out       : r0 = FAT date << 16 | FAT time from the calendar copy of the clock chip: date = (year + 20) << 9 | month << 5 | day
@             (year counted from 1980, the copy from 2000), time = hour << 11 | minute << 5 | second / 2 (as log_set_file_time);
@             0x00210000 (1980-01-01 00:00:00, the first FAT date) while the copy holds no valid date (month 0 or above 12,
@             day 0 or above 31: the clock chip has not been read yet)
@ Clobbers  : r0, flags (r1-r3 kept: v2.05 regeffects.txt, the callers keep values in them)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802402E..0x08024031 and literal 0x08024034; FatFs R0.08a get_fattime; FAT date / time format
@ Deviation : OF-58 (ORIGINAL_FIRMWARE_ISSUES.md): v2.05 returns the constant 0x3449B3C0 of FatFs's sample code (2006-02-09
@             22:30:00).  f_open writes it as the creation time of every file and f_sync as the modification time; log_set_file_time
@             corrects only the modification time after a log session, so every file showed a 2006 creation date, and a file
@             whose session ended without that correction (power cut) also a 2006 modification date.
@ -----------------------------------------------------------------------------
FUNC get_fattime
    push    {r1, r2, r3, lr}
    ldr     r3, =v_200080D7                 @ calendar copy: year (from 2000), month, day, hour, minute, second at +0..+5
    ldrb    r1, [r3, #1]                    @ month
    subs    r2, r1, #1
    cmp     r2, #11
    bhi     .Lgft_none                      @ month not 1..12
    ldrb    r2, [r3, #2]                    @ day
    subs    r0, r2, #1
    cmp     r0, #30
    bhi     .Lgft_none                      @ day not 1..31
    ldrb    r0, [r3, #0]                    @ year from 2000
    adds    r0, r0, #20                     @ from 1980
    lsls    r0, r0, #9
    orr     r0, r0, r1, lsl #5
    orrs    r0, r0, r2                      @ r0 = FAT date
    ldrb    r1, [r3, #3]                    @ hour
    ldrb    r2, [r3, #4]                    @ minute
    lsls    r1, r1, #11
    orr     r1, r1, r2, lsl #5
    ldrb    r2, [r3, #5]                    @ second
    orr     r1, r1, r2, lsr #1              @ r1 = FAT time
    orr     r0, r1, r0, lsl #16
    pop     {r1, r2, r3, pc}
.Lgft_none:
    mov     r0, #0x00210000                 @ 1980-01-01 00:00:00
    pop     {r1, r2, r3, pc}
ENDFUNC get_fattime
    .ltorg

@ -----------------------------------------------------------------------------
@ disk_ioctl - disk control (FatFs disk_ioctl)
@ Replaces  : 0x08024038 FUN_08024038 (v2.05), called by fat_sync_fs
@ In        : r0 = drive, r1 = command (0 sync, 1 sector count, 2 sector size, 3 erase block size), r2 = result pointer
@ Out       : r0 = 0
@ Clobbers  : r0-r1, r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08024038..0x08024073
@ Note      : command 0 does nothing; command 1 stores the constant 0x20000 (131072 sectors) as a word, command 2 the halfword 0x200,
@             command 3 the word 0x20.  The sector count does not describe the card; FatFs does not use it for the operations ported here.
@ -----------------------------------------------------------------------------
FUNC disk_ioctl
    push    {r4}                            @ 08024038 push {r4}
    movs    r3, r0                          @ 0802403A r3 = r0
    movs    r0, #0                          @ 0802403C r0 = 0
    uxtb    r1, r1                          @ 0802403E r1 = u8(r1)
    cmp     r1, #1                          @ 08024040 compare r1 with 1
    beq     .Ldisk_ioctl_404E               @ 08024042 if (r1 == 1) goto 0x802404E
    blo     .Ldisk_ioctl_406E               @ 08024044 if (r1 <u 1) goto 0x802406E
    cmp     r1, #3                          @ 08024046 compare r1 with 3
    beq     .Ldisk_ioctl_4066               @ 08024048 if (r1 == 3) goto 0x8024066
    blo     .Ldisk_ioctl_405A               @ 0802404A if (r1 <u 3) goto 0x802405A
    b       .Ldisk_ioctl_406E               @ 0802404C goto 0x802406E
.Ldisk_ioctl_404E:                      @ v2.05 0x0802404E, reached from 0x08024042
    movs.w  r4, #0x20000                    @ 0802404E r4 = 0x20000
    str     r4, [r2]                        @ 08024052 u32 [r2] = r4
    movs    r4, #0                          @ 08024054 r4 = 0
    movs    r0, r4                          @ 08024056 r0 = r4
    b       .Ldisk_ioctl_406E               @ 08024058 goto 0x802406E
.Ldisk_ioctl_405A:                      @ v2.05 0x0802405A, reached from 0x0802404A
    mov.w   r4, #0x200                      @ 0802405A r4 = 0x200
    strh    r4, [r2]                        @ 0802405E u16 [r2] = r4
    movs    r4, #0                          @ 08024060 r4 = 0
    movs    r0, r4                          @ 08024062 r0 = r4
    b       .Ldisk_ioctl_406E               @ 08024064 goto 0x802406E
.Ldisk_ioctl_4066:                      @ v2.05 0x08024066, reached from 0x08024048
    movs    r4, #0x20                       @ 08024066 r4 = 0x20
    str     r4, [r2]                        @ 08024068 u32 [r2] = r4
    movs    r4, #0                          @ 0802406A r4 = 0
    movs    r0, r4                          @ 0802406C r0 = r4
.Ldisk_ioctl_406E:                      @ v2.05 0x0802406E, reached from 0x08024044, 0x0802404C, 0x08024058, 0x08024064
    uxtb    r0, r0                          @ 0802406E r0 = u8(r0)
    pop     {r4}                            @ 08024070 pop {r4}
    bx      lr                              @ 08024072 return
ENDFUNC disk_ioctl
    .ltorg

