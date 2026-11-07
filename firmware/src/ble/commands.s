@ =============================================================================
@ commands.s - BLE: command frames and enable
@
@ BLE module, part 2: received command frames (analysis/ble_packet.md 6).
@
@ Replaces the v2.05 routines 0x0800C308 (echo), 0x0800C332 (frame processing), 0x0800C470 (hex pair decoding)
@ and 0x0800C51A (enable / disable).  The receive side is ble_usart2_isr (usart.s).  Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

@ Module-local names of v2.05 RAM variables (address = the v_XXXXXXXX symbol of ram_v205.inc)
    .equ ble_rx_buf,            v_20007B80   @ USART2 receive buffer (up to 20 bytes)
    .equ ble_cmd_buf,           v_20007B94   @ copy of a received command frame
    .equ ble_enable,            v_2000802B   @ BLE / serial transfer enabled (long PEAK)
    .equ ble_rx_len,            v_2000802F   @ length of the last complete frame
    .equ ble_rx_ready,          v_20008030   @ a complete command frame is waiting
    .equ ble_clock_set,         v_20008033   @ set-clock frame applied since the BT toggle (written only; IMP-31)
    .equ ble_clock_bad,         v_20008034   @ last set-clock frame failed its checksum (write only)
    .equ ble_key_remote_req,    v_20008069   @ remote key request pending
    .equ ble_key_remote_code,   v_2000806D   @ remote key code (1..8, 0x81..0x88)
    .equ ble_year,              v_200080D7   @ year 0..99 (BCD-converted NJU6350 register 2)
    .equ ble_month,             v_200080D8   @ month 1..12 (register 4)
    .equ ble_day,               v_200080D9   @ day 1..31 (register 6)
    .equ ble_hour,              v_200080DA   @ hour 0..23 (register 10)
    .equ ble_minute,            v_200080DB   @ minute 0..59 (register 12)
    .equ ble_second,            v_200080DC   @ second 0..59 (register 14)

    .equ BLE_VERSION_CODE,  0x90             @ key code of the version request (F4 39 30 39 30; v2.05 ignores it)
    .equ BLE_VERSION_LEN,   7
    .equ BLE_BLUPD_CODE,    0x91             @ restart into update mode (F4 39 31 39 31; ble/blcmd.s)
    .equ BLE_BLINFO_CODE,   0x92             @ bootloader version request (F4 39 32 39 32; ble/blcmd.s)
    .equ BLE_XDON_CODE,     0x93             @ extended link diagnosis on, counters cleared (F4 39 33 39 33; ble/xdiag.s)
    .equ BLE_XDOFF_CODE,    0x94             @ extended link diagnosis off (F4 39 34 39 34; ble/xdiag.s)
    .equ BLE_XDGET_CODE,    0x95             @ extended link diagnosis counters request, answered with F9 (F4 39 35 39 35)
    .equ BLE_CKGET_CODE,    0x96             @ clock measurement request, answered with FA (F4 39 36 39 36; sys/msical.s)
    .equ BLE_DUPON_CODE,    0x97             @ careful mode on: each status frame twice (F4 39 37 39 37; IMP-50)
    .equ BLE_DUPOFF_CODE,   0x98             @ careful mode off (F4 39 38 39 38)

    .section .rodata.ble.version, "a", %progbits
@ ble_version_frame - answer to the version request: F6, the five characters the meter shows at power-on (config.inc
@ FW_VER_C0..C4, the decimal point after the third), XOR of the six bytes before it (FEATURES.md 2.11 stage 3)
ble_version_frame:
    .byte 0xF6, FW_VER_C0, FW_VER_C1, FW_VER_C2, FW_VER_C3, FW_VER_C4
    .byte 0xF6 ^ FW_VER_C0 ^ FW_VER_C1 ^ FW_VER_C2 ^ FW_VER_C3 ^ FW_VER_C4

    .section .text.ble, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800C308 - echo the received command frame
@ Replaces : 0x0800C308 FUN_0800C308 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only (fn_0800C332)
@ RAM      : reads ble_cmd_buf, ble_rx_len
@ Spec     : analysis/ble_packet.md 6 (key frame: echo 5 bytes; clock frame: echo 15 bytes)
@ Deviation: OF-10: v2.05 sends the echo from the main loop with blocking USART_SendData calls (can interleave with a
@            status frame); the port queues it (ble_tx_queue_put) and the USART2 handler sends it between frames.
@            If the queue lacks room (HSE use blocks the link) the echo is dropped.
@ -----------------------------------------------------------------------------
FUNC fn_0800C308
    push {r4, lr}
    ldr r0, =ble_cmd_buf                    @ copy of the received frame
    ldr r1, =ble_rx_len
    ldrb r1, [r1]                           @ number of bytes of the frame (5 or 15)
    bl ble_tx_queue_put                     @ queue them (r0 = 0 queued, 1 refused)
    pop {r4, pc}
ENDFUNC fn_0800C308
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800C332 - process a received command frame (key frame 0xF4, set-clock frame 0xF8)
@ Replaces : 0x0800C332 FUN_0800C332 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (loop step 11, flag ble_rx_ready)
@ RAM      : reads ble_rx_buf, ble_rx_len; writes ble_clock_bad, ble_clock_set, ble_cmd_buf, ble_day, ble_hour,
@            ble_key_remote_code, ble_key_remote_req, ble_minute, ble_month, ble_rx_ready, ble_second, ble_year,
@            xd_bad_frames (xd_inc)
@ Spec     : analysis/ble_packet.md 6
@ Note     : Clears ble_rx_ready, copies the ble_rx_len received bytes to ble_cmd_buf, then: 0xF8 frame: decodes 7 hex
@            pairs (offsets 1, 3, ..., 13), checks v6 == v0 ^ ... ^ v5, echoes the frame, and applies v0..v5 to
@            rtc_year .. rtc_second and the NJU6350 (fn_0801016C) every time (IMP-31; v2.05 only while ble_clock_set
@            is 0) and sets ble_clock_set; a failed
@            checksum clears ble_clock_bad (never read).  0xF4 frame: pairs at offsets 1 and 3 must be equal; then
@            echo, key_remote_req = 1 and key_remote_code = the code (decoded by fn_08014AE6 in KEY); code 0x90 is
@            answered with ble_version_frame instead (FEATURES.md 2.11 stage 3), 0x91 and 0x92 by ble/blcmd.s
@            (bootloader update mode, bootloader version), 0x93 / 0x94 / 0x95 by ble/xdiag.s (extended link diagnosis on,
@            off, counters frame F9; IMP-44), 0x96 by sys/msical.s (clock measurement frame FA; IMP-46), 0x97 / 0x98 careful mode on / off (each status
@            frame twice, ble/usart.s; IMP-50).  A frame rejected for its checksum (F8) or its unequal code pairs (F4) is
@            counted in xd_bad_frames.  Any other first byte is ignored.
@ -----------------------------------------------------------------------------
FUNC fn_0800C332
    push {r3, r4, r5, r6, r7, r8, r9, r10, r11, lr} @ 0800C332
    movs r0, #0x0                           @ 0800C336
    ldr.w r1, =ble_rx_ready                 @ 0800C338
    strb r0, [r1, #0x0]                     @ 0800C33C  ble_rx_ready = 0
    movs r0, #0x0                           @ 0800C33E
    mov r10, r0                             @ 0800C340
.L0800C342:  @ reached from 0800C36C b
    mov r0, r10                             @ 0800C342
    ldr.w r1, =ble_rx_len                   @ 0800C344
    ldrb r1, [r1, #0x0]                     @ 0800C348  r1 = ble_rx_len
    uxtb r0, r0                             @ 0800C34A
    cmp r0, r1                              @ 0800C34C  compare r0 with ble_rx_len
    bcs .L0800C36E                          @ 0800C34E  if r0 >=u ble_rx_len
    ldr.w r0, =ble_rx_buf                   @ 0800C350
    uxtb r10, r10                           @ 0800C354
    ldrb r0, [r0, r10]                      @ 0800C358  r0 = ble_rx_buf[r10]
    ldr.w r1, =ble_cmd_buf                  @ 0800C35C
    uxtb r10, r10                           @ 0800C360
    strb r0, [r1, r10]                      @ 0800C364  ble_cmd_buf[r10] = r0
    adds r10, r10, #0x1                     @ 0800C368  r10 = r10 + 1
    b .L0800C342                            @ 0800C36C
.L0800C36E:  @ reached from 0800C34E bcs (r0 >=u ble_rx_len)
    ldr.w r0, =ble_cmd_buf                  @ 0800C36E
    ldrb r0, [r0, #0x0]                     @ 0800C372  r0 = ble_cmd_buf
    cmp r0, #0xf8                           @ 0800C374  compare ble_cmd_buf with 248 (0xF8)
    bne .L0800C428                          @ 0800C376  if ble_cmd_buf != 248 (0xF8)
    movs r0, #0x1                           @ 0800C378
    bl fn_0800C470                          @ 0800C37A  two ASCII hex characters at offset r0 to a byte [r0=1]
    strb r0, [sp, #0x0]                     @ 0800C37E  local [sp+0] = r0
    ldrb r0, [sp, #0x0]                     @ 0800C382  r0 = local [sp+0]
    mov r11, r0                             @ 0800C386
    movs r0, #0x3                           @ 0800C388
    bl fn_0800C470                          @ 0800C38A  two ASCII hex characters at offset r0 to a byte [r0=3]
    movs r4, r0                             @ 0800C38E
    eors r11, r4, r11                       @ 0800C390  r11 = r4 ^ r11
    movs r0, #0x5                           @ 0800C394
    bl fn_0800C470                          @ 0800C396  two ASCII hex characters at offset r0 to a byte [r0=5]
    movs r5, r0                             @ 0800C39A
    eors r11, r5, r11                       @ 0800C39C  r11 = r5 ^ (r4 ^ r11)
    movs r0, #0x7                           @ 0800C3A0
    bl fn_0800C470                          @ 0800C3A2  two ASCII hex characters at offset r0 to a byte [r0=7]
    movs r6, r0                             @ 0800C3A6
    eors r11, r6, r11                       @ 0800C3A8  r11 = r6 ^ (r5 ^ (r4 ^ r11))
    movs r0, #0x9                           @ 0800C3AC
    bl fn_0800C470                          @ 0800C3AE  two ASCII hex characters at offset r0 to a byte [r0=9]
    movs r7, r0                             @ 0800C3B2
    eors r11, r7, r11                       @ 0800C3B4  r11 = r7 ^ (r6 ^ (r5 ^ (r4 ^ r11)))
    movs r0, #0xb                           @ 0800C3B8
    bl fn_0800C470                          @ 0800C3BA  two ASCII hex characters at offset r0 to a byte [r0=11 (0xB)]
    mov r8, r0                              @ 0800C3BE
    eors r11, r8, r11                       @ 0800C3C0  r11 = r8 ^ (r7 ^ (r6 ^ (r5 ^ (r4 ^ r11))))
    movs r0, #0xd                           @ 0800C3C4
    bl fn_0800C470                          @ 0800C3C6  two ASCII hex characters at offset r0 to a byte [r0=13 (0xD)]
    mov r9, r0                              @ 0800C3CA
    mov r0, r11                             @ 0800C3CC
    mov r1, r9                              @ 0800C3CE
    uxtb r0, r0                             @ 0800C3D0
    uxtb r1, r1                             @ 0800C3D2
    cmp r0, r1                              @ 0800C3D4  compare (r8 ^ (r7 ^ (r6 ^ (r5 ^ (r4 ^ r11))))) with r1
    bne .L0800C41E                          @ 0800C3D6  if (r8 ^ (r7 ^ (r6 ^ (r5 ^ (r4 ^ r11))))) != r1
    bl fn_0800C308                          @ 0800C3D8  echo the received command frame [r0=(r8 ^ (r7 ^ (r6 ^ (r5 ^ (r4 ^ r11)))))]
    @ IMP-31: every set-clock frame with a valid checksum is applied.  v2.05 applies only the first one after the Bluetooth
    @ toggle (test of ble_clock_set at 0x0800C3DC..0x0800C3E4, removed); the flag is still written below.
    ldrb r0, [sp, #0x0]                     @ 0800C3E6  r0 = local [sp+0]
    ldr.w r1, =ble_year                     @ 0800C3EA
    strb r0, [r1, #0x0]                     @ 0800C3EE  ble_year = r0
    ldr.w r0, =ble_month                    @ 0800C3F0
    strb r4, [r0, #0x0]                     @ 0800C3F4  ble_month = r4
    ldr.w r0, =ble_day                      @ 0800C3F6
    strb r5, [r0, #0x0]                     @ 0800C3FA  ble_day = r5
    ldr.w r0, =ble_hour                     @ 0800C3FC
    strb r6, [r0, #0x0]                     @ 0800C400  ble_hour = r6
    ldr.w r0, =ble_minute                   @ 0800C402
    strb r7, [r0, #0x0]                     @ 0800C406  ble_minute = r7
    ldr.w r0, =ble_second                   @ 0800C408
    strb r8, [r0, #0x0]                     @ 0800C40C  ble_second = r8
    bl fn_0801016C                          @ 0800C410  write the six time registers from RAM [r0=&ble_second, r1=&ble_year]
    movs r0, #0x1                           @ 0800C414
    ldr.w r1, =ble_clock_set                @ 0800C416
    strb r0, [r1, #0x0]                     @ 0800C41A  ble_clock_set = 1
    b .L0800C46C                            @ 0800C41C
.L0800C41E:  @ reached from 0800C3D6 bne ((r8 ^ (r7 ^ (r6 ^ (r5 ^ (r4 ^ r11))))) != r1)
    movs r0, #0x0                           @ 0800C41E
    ldr.w r1, =ble_clock_bad                @ 0800C420
    strb r0, [r1, #0x0]                     @ 0800C424  ble_clock_bad = 0
    ldr r0, =xd_bad_frames
    bl xd_inc                               @ IMP-44: a set-clock frame rejected for its checksum
    b .L0800C46C                            @ 0800C426
.L0800C428:  @ reached from 0800C376 bne (ble_cmd_buf != 248 (0xF8))
    ldr.w r0, =ble_cmd_buf                  @ 0800C428
    ldrb r0, [r0, #0x0]                     @ 0800C42C  r0 = ble_cmd_buf
    cmp r0, #0xf4                           @ 0800C42E  compare ble_cmd_buf with 244 (0xF4)
    bne .L0800C46C                          @ 0800C430  if ble_cmd_buf != 244 (0xF4)
    movs r0, #0x1                           @ 0800C432
    bl fn_0800C470                          @ 0800C434  two ASCII hex characters at offset r0 to a byte [r0=1]
    strb r0, [sp, #0x1]                     @ 0800C438  local [sp+1] = r0
    ldrb r0, [sp, #0x1]                     @ 0800C43C  r0 = local [sp+1]
    mov r11, r0                             @ 0800C440
    movs r0, #0x3                           @ 0800C442
    bl fn_0800C470                          @ 0800C444  two ASCII hex characters at offset r0 to a byte [r0=3]
    mov r9, r0                              @ 0800C448
    mov r0, r11                             @ 0800C44A
    mov r1, r9                              @ 0800C44C
    uxtb r0, r0                             @ 0800C44E
    uxtb r1, r1                             @ 0800C450
    cmp r0, r1                              @ 0800C452  compare r0 with r1
    bne .Lkey_bad                           @ 0800C454  if r0 != r1 (v2.05 branches to the end)
    bl fn_0800C308                          @ 0800C456  echo the received command frame
    ldrb r0, [sp, #0x1]                     @ the key code
    cmp r0, #BLE_BLINFO_CODE
    bne 2f
    bl blcmd_info                           @ 0x92: bootloader version frame F7 (ble/blcmd.s)
    b .L0800C46C
2:  cmp r0, #BLE_BLUPD_CODE
    bne 3f
    bl blcmd_update_mode                    @ 0x91: restart into the bootloader's update mode (returns only without it)
    b .L0800C46C
3:  cmp r0, #BLE_VERSION_CODE
    bne 4f
    @ FEATURES.md 2.11 stage 3: code 0x90 asks for the firmware version.  It is answered with ble_version_frame and is
    @ not handed to the key routine (a remote key restarts the backlight countdown and clears a pending message).
    @ Answer refused by a full queue: the host asks again.
    ldr r0, =ble_version_frame
    movs r1, #BLE_VERSION_LEN
    bl ble_tx_queue_put
    b .L0800C46C
4:  cmp r0, #BLE_XDON_CODE
    bne 5f
    bl xd_start                             @ 0x93: extended link diagnosis on, counters cleared (ble/xdiag.s, IMP-44)
    b .L0800C46C
5:  cmp r0, #BLE_XDOFF_CODE
    bne 6f
    bl xd_stop                              @ 0x94: extended link diagnosis off
    b .L0800C46C
6:  cmp r0, #BLE_XDGET_CODE
    bne 7f
    bl xd_send                              @ 0x95: counters frame F9 (only while the diagnosis is on)
    b .L0800C46C
7:  cmp r0, #BLE_CKGET_CODE
    bne 8f
    bl ck_send                              @ 0x96: clock measurement frame FA (IMP-46)
    b .L0800C46C
8:  cmp r0, #BLE_DUPON_CODE
    bne 9f
    movs r0, #1
    ldr r1, =ble_dup_on
    strb r0, [r1]                           @ 0x97: careful mode on (IMP-50; one byte, read by the USART2 handler)
    b .L0800C46C
9:  cmp r0, #BLE_DUPOFF_CODE
    bne 1f
    movs r0, #0
    ldr r1, =ble_dup_on
    strb r0, [r1]                           @ 0x98: careful mode off
    b .L0800C46C
.Lkey_bad:
    ldr r0, =xd_bad_frames
    bl xd_inc                               @ IMP-44: a key frame whose two code pairs differ
    b .L0800C46C
1:  movs r0, #0x1                           @ 0800C45A
    ldr.w r1, =ble_key_remote_req           @ 0800C45C
    strb r0, [r1, #0x0]                     @ 0800C460  ble_key_remote_req = 1
    ldrb r0, [sp, #0x1]                     @ 0800C462  r0 = local [sp+1]
    ldr.w r1, =ble_key_remote_code          @ 0800C466
    strb r0, [r1, #0x0]                     @ 0800C46A  ble_key_remote_code = r0
.L0800C46C:  @ reached from 0800C41C b, 0800C426 b, 0800C430 bne (ble_cmd_buf != 244 (0xF4)), 0800C454 bne (r0 != r1)
    pop {r0, r4, r5, r6, r7, r8, r9, r10, r11, pc} @ 0800C46C
ENDFUNC fn_0800C332
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800C470 - decode two ASCII hex characters of the command buffer
@ Replaces : 0x0800C470 FUN_0800C470 (v2.05)
@ In       : r0 = offset of the first (high) character in ble_cmd_buf
@ Out      : r0 = byte value
@ Clobbers : r1, r2, flags
@ Context  : main only
@ RAM      : reads ble_cmd_buf
@ Spec     : analysis/ble_packet.md 6
@ Note     : "0".."9" and "A".."F" are accepted; any other character (lower case included) contributes 0 to its
@            nibble.
@ -----------------------------------------------------------------------------
FUNC fn_0800C470
    movs r1, r0                             @ 0800C470
    movs r0, #0x0                           @ 0800C472
    ldr.w r2, =ble_cmd_buf                  @ 0800C474
    uxtb r1, r1                             @ 0800C478
    ldrb r2, [r2, r1]                       @ 0800C47A  r2 = ble_cmd_buf[r1]
    cmp r2, #0x30                           @ 0800C47C  compare r2 with 48 (0x30)
    blt .L0800C49A                          @ 0800C47E  if r2 <s 48 (0x30)
    ldr.w r2, =ble_cmd_buf                  @ 0800C480
    uxtb r1, r1                             @ 0800C484
    ldrb r2, [r2, r1]                       @ 0800C486  r2 = ble_cmd_buf[r1]
    cmp r2, #0x3a                           @ 0800C488  compare r2 with 58 (0x3A)
    bge .L0800C49A                          @ 0800C48A  if r2 >=s 58 (0x3A)
    ldr.w r2, =ble_cmd_buf                  @ 0800C48C
    uxtb r1, r1                             @ 0800C490
    ldrb r2, [r2, r1]                       @ 0800C492  r2 = ble_cmd_buf[r1]
    lsls r2, r2, #0x4                       @ 0800C494  r2 = r2 << 4
    movs r0, r2                             @ 0800C496
    b .L0800C4C0                            @ 0800C498
.L0800C49A:  @ reached from 0800C47E blt (r2 <s 48 (0x30)), 0800C48A bge (r2 >=s 58 (0x3A))
    ldr.w r2, =ble_cmd_buf                  @ 0800C49A
    uxtb r1, r1                             @ 0800C49E
    ldrb r2, [r2, r1]                       @ 0800C4A0  r2 = ble_cmd_buf[r1]
    cmp r2, #0x41                           @ 0800C4A2  compare r2 with 65 (0x41)
    blt .L0800C4C0                          @ 0800C4A4  if r2 <s 65 (0x41)
    ldr.w r2, =ble_cmd_buf                  @ 0800C4A6
    uxtb r1, r1                             @ 0800C4AA
    ldrb r2, [r2, r1]                       @ 0800C4AC  r2 = ble_cmd_buf[r1]
    cmp r2, #0x47                           @ 0800C4AE  compare r2 with 71 (0x47)
    bge .L0800C4C0                          @ 0800C4B0  if r2 >=s 71 (0x47)
    ldr.w r2, =ble_cmd_buf                  @ 0800C4B2
    uxtb r1, r1                             @ 0800C4B6
    ldrb r2, [r2, r1]                       @ 0800C4B8  r2 = ble_cmd_buf[r1]
    subs r2, #0x37                          @ 0800C4BA  r2 = r2 - 55 (0x37)
    lsls r2, r2, #0x4                       @ 0800C4BC  r2 = (r2 - 55 (0x37)) << 4
    movs r0, r2                             @ 0800C4BE
.L0800C4C0:  @ reached from 0800C498 b, 0800C4A4 blt (r2 <s 65 (0x41)), 0800C4B0 bge (r2 >=s 71 (0x47))
    ldr.w r2, =ble_cmd_buf                  @ 0800C4C0
    uxtb r1, r1                             @ 0800C4C4
    add r2, r1                              @ 0800C4C6  r2 = &ble_cmd_buf + r1
    ldrb r2, [r2, #0x1]                     @ 0800C4C8  r2 = [r2+1]
    cmp r2, #0x30                           @ 0800C4CA  compare r2 with 48 (0x30)
    blt .L0800C4EC                          @ 0800C4CC  if r2 <s 48 (0x30)
    ldr.w r2, =ble_cmd_buf                  @ 0800C4CE
    uxtb r1, r1                             @ 0800C4D2
    add r2, r1                              @ 0800C4D4  r2 = &ble_cmd_buf + r1
    ldrb r2, [r2, #0x1]                     @ 0800C4D6  r2 = [r2+1]
    cmp r2, #0x3a                           @ 0800C4D8  compare r2 with 58 (0x3A)
    bge .L0800C4EC                          @ 0800C4DA  if r2 >=s 58 (0x3A)
    ldr.w r2, =ble_cmd_buf                  @ 0800C4DC
    uxtb r1, r1                             @ 0800C4E0
    add r2, r1                              @ 0800C4E2  r2 = &ble_cmd_buf + r1
    ldrb r2, [r2, #0x1]                     @ 0800C4E4  r2 = [r2+1]
    subs r2, #0x30                          @ 0800C4E6  r2 = r2 - 48 (0x30)
    adds r0, r2, r0                         @ 0800C4E8  r0 = (r2 - 48 (0x30)) + r0
    b .L0800C516                            @ 0800C4EA
.L0800C4EC:  @ reached from 0800C4CC blt (r2 <s 48 (0x30)), 0800C4DA bge (r2 >=s 58 (0x3A))
    ldr.w r2, =ble_cmd_buf                  @ 0800C4EC
    uxtb r1, r1                             @ 0800C4F0
    add r2, r1                              @ 0800C4F2  r2 = &ble_cmd_buf + r1
    ldrb r2, [r2, #0x1]                     @ 0800C4F4  r2 = [r2+1]
    cmp r2, #0x41                           @ 0800C4F6  compare r2 with 65 (0x41)
    blt .L0800C516                          @ 0800C4F8  if r2 <s 65 (0x41)
    ldr.w r2, =ble_cmd_buf                  @ 0800C4FA
    uxtb r1, r1                             @ 0800C4FE
    add r2, r1                              @ 0800C500  r2 = &ble_cmd_buf + r1
    ldrb r2, [r2, #0x1]                     @ 0800C502  r2 = [r2+1]
    cmp r2, #0x47                           @ 0800C504  compare r2 with 71 (0x47)
    bge .L0800C516                          @ 0800C506  if r2 >=s 71 (0x47)
    ldr.w r2, =ble_cmd_buf                  @ 0800C508
    uxtb r1, r1                             @ 0800C50C
    add r2, r1                              @ 0800C50E  r2 = &ble_cmd_buf + r1
    ldrb r2, [r2, #0x1]                     @ 0800C510  r2 = [r2+1]
    subs r2, #0x37                          @ 0800C512  r2 = r2 - 55 (0x37)
    adds r0, r2, r0                         @ 0800C514  r0 = (r2 - 55 (0x37)) + r0
.L0800C516:  @ reached from 0800C4EA b, 0800C4F8 blt (r2 <s 65 (0x41)), 0800C506 bge (r2 >=s 71 (0x47))
    uxtb r0, r0                             @ 0800C516
    bx lr                                   @ 0800C518
ENDFUNC fn_0800C470
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800C51A - apply the BLE enable flag: start or stop the USART2 link
@ Replaces : 0x0800C51A FUN_0800C51A (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (KEY, long PEAK, after toggling ble_enable)
@ RAM      : reads ble_enable
@ Spec     : analysis/ble_packet.md 1
@ Deviation: OF-11: the first status frame is built before it can be transmitted
@ Note     : ble_enable set: usart2_init_19200_pf15_high, then (OF-11) fn_0800C5D2 builds a frame, so the first
@            transmission at the next TIM2 count 50 never carries old buffer contents; ble_enable clear:
@            usart2_deinit_pf15_low.  Finally the BT annunciator is updated (fn_08019D2C(1)).
@ -----------------------------------------------------------------------------
FUNC fn_0800C51A
    push {r4, lr}                           @ 0800C51A
    movs r4, r0                             @ 0800C51C
    ldr.w r0, =ble_enable                   @ 0800C51E
    ldrb r0, [r0, #0x0]                     @ 0800C522  r0 = ble_enable
    cmp r0, #0x0                            @ 0800C524  compare ble_enable with 0
    beq .L0800C52E                          @ 0800C526  if ble_enable == 0
    bl usart2_init_19200_pf15_high          @ 0800C528  power the BLE module and start USART2 at 19200 baud [r0=ble_enable]
    bl fn_0800C5D2                       @ OF-11: build a frame now (v2.05 builds only at TIM2 count 40)
    b .L0800C532                            @ 0800C52C
.L0800C52E:  @ reached from 0800C526 beq (ble_enable == 0)
    bl usart2_deinit_pf15_low               @ 0800C52E  stop USART2 and switch the BLE module off
.L0800C532:  @ reached from 0800C52C b
    movs r0, #0x1                           @ 0800C532
    bl fn_08019D2C                          @ 0800C534  BT annunciator update [r0=1]
    pop {r4, pc}                            @ 0800C538
ENDFUNC fn_0800C51A
    .ltorg
