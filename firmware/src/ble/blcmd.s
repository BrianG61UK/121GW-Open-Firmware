@ =============================================================================
@ blcmd.s - BLE: bootloader requests of the companion (bootloader/DESIGN.md G3, 6.3; production image)
@
@ Two key codes of the key frame F4 (as the version request 0x90, commands.s fn_0800C332):
@   0x91  restart into update mode: only when the two-part bootloader is installed (its mark at 0x08005F00 is valid).
@         The request is left in RTC_BKP0R (BLCMD_MAGIC) and the MCU is reset (SYSRESETREQ); the bootloader reads and
@         clears the register before it touches the RTC domain and starts its Bluetooth update mode.  With EEVblog's
@         bootloader nothing happens (it would not read the register): the companion asks 0x92 first.
@   0x92  bootloader version: answered with the frame F7 c0..c4 XOR (seven bytes, as F6 of the firmware version):
@         "B-" and the three digits of the mark's version word (major << 16 | minor << 8 | patch), or "B-EEV" when no
@         valid mark is present (EEVblog's bootloader, or an install not finished).
@ RTC_BKP0R: not reset by a system reset, reset by a power-on reset (RM0038 20.3.13); written with DBP set in PWR_CR
@ (RM0038 5.4.1, the backup domain write protection).
@ Context: main only (commands.s).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"

    .equ BLCMD_MARK,        0x08005F00      @ bootloader mark (bootloader/tools/blimage.py header)
    .equ BLCMD_HDR_MAGIC,   0x32484C42      @ "BLH2"
    .equ BLCMD_BL_MAX,      0x5B00
    .equ BLCMD_MAGIC,       0x55504454      @ "TDPU": update mode requested (read by the bootloader)
    .equ RTC_BKP0R,         0x40002850      @ RTC_BASE + 0x50 (RM0038 20.6.20)
    .equ BLCMD_APB1_PWREN,  0x10000000      @ RCC_APB1ENR bit 28 PWREN (RM0038 6.3.10)

    .section .bss_port.blcmd, "aw", %nobits
blcmd_frame:    .space 8                    @ the F7 frame being queued

    .section .text.ble.blcmd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ blcmd_mark_version - the version word of a valid bootloader mark
@ Out      : r0 = version word, or -1 when the mark is not valid
@ Clobbers : r1-r3, r12, flags (r4 saved)
@ -----------------------------------------------------------------------------
FUNC blcmd_mark_version
    push {r4, lr}
    ldr r4, =BLCMD_MARK
    ldr r0, [r4, #0]
    ldr r1, =BLCMD_HDR_MAGIC
    cmp r0, r1
    bne 9f
    ldr r0, [r4, #4]
    subs r0, r0, #1
    cmp r0, #BLCMD_BL_MAX
    bhs 9f
    mov r0, #0xFFFFFFFF
    mov r1, r4
    movs r2, #16
    bl blinst_crc32
    mvns r0, r0
    ldr r1, [r4, #16]
    cmp r0, r1
    bne 9f
    ldr r0, [r4, #12]
    pop {r4, pc}
9:  mov r0, #0xFFFFFFFF
    pop {r4, pc}
ENDFUNC blcmd_mark_version

@ -----------------------------------------------------------------------------
@ blcmd_info - queue the F7 bootloader version frame (code 0x92)
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC blcmd_info
    push {r4, lr}
    bl blcmd_mark_version
    ldr r4, =blcmd_frame
    movs r1, #0xF7
    strb r1, [r4, #0]
    movs r1, #'B'
    strb r1, [r4, #1]
    movs r1, #'-'
    strb r1, [r4, #2]
    adds r1, r0, #1
    bne 1f
    movs r1, #'E'                           @ no valid mark: EEVblog's bootloader
    strb r1, [r4, #3]
    strb r1, [r4, #4]
    movs r1, #'V'
    strb r1, [r4, #5]
    b 2f
1:  ubfx r1, r0, #16, #8                    @ major, minor, patch digits (each 0..9 in a release)
    adds r1, r1, #'0'
    strb r1, [r4, #3]
    ubfx r1, r0, #8, #8
    adds r1, r1, #'0'
    strb r1, [r4, #4]
    uxtb r1, r0
    adds r1, r1, #'0'
    strb r1, [r4, #5]
2:  movs r0, #0                             @ XOR of the six bytes
    movs r1, #0
3:  ldrb r2, [r4, r1]
    eors r0, r0, r2
    adds r1, r1, #1
    cmp r1, #6
    bne 3b
    strb r0, [r4, #6]
    mov r0, r4
    movs r1, #7
    bl ble_tx_queue_put                     @ refused when the queue is full: the host asks again
    pop {r4, pc}
ENDFUNC blcmd_info

@ -----------------------------------------------------------------------------
@ blcmd_ble_on - Bluetooth on, the steps of a long PEAK that switches it on (key/long.s .Llp_key_peak): the transfer flag,
@ no pending remote key, the module told (fn_0800C51A), the counter 0x20007FB0 cleared; called at power-up by a
@ development build (config.inc BLE_AT_POWERUP)
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC blcmd_ble_on
    push {r4, lr}
    movs r0, #1
    ldr r1, =v_2000802B
    strb r0, [r1]                           @ key_ble_on: the status frames go out
    movs r0, #0
    ldr r1, =v_20008033
    strb r0, [r1]
    ldr r1, =v_20008069
    strb r0, [r1]                           @ key_remote_ev: no remote key waiting
    ldr r1, =v_2000806D
    strb r0, [r1]                           @ key_remote_code
    movs r0, #1
    bl fn_0800C51A                          @ tell the Bluetooth module (as 0x08016560)
    movs r0, #0
    ldr r1, =v_20007FB0
    strh r0, [r1]
    pop {r4, pc}
ENDFUNC blcmd_ble_on

@ -----------------------------------------------------------------------------
@ blcmd_update_mode - restart into the bootloader's update mode (code 0x91); returns only when no two-part
@ bootloader is installed
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC blcmd_update_mode
    push {r4, lr}
    bl blcmd_mark_version
    adds r0, r0, #1
    beq 9f                                  @ EEVblog's bootloader: nothing to do
    ldr r0, =RCC_APB1ENR
    ldr r1, [r0]
    orr r1, r1, #BLCMD_APB1_PWREN
    str r1, [r0]                            @ PWR interface clock (RM0038 6.3.10)
    ldr r0, =PWR_CR
    ldr r1, [r0]
    orr r1, r1, #PWR_CR_DBP
    str r1, [r0]                            @ backup domain writable (RM0038 5.4.1)
    ldr r0, =RTC_BKP0R
    ldr r1, =BLCMD_MAGIC
    str r1, [r0]
    dsb
    ldr r0, =SCB_AIRCR
    ldr r1, [r0]
    and r1, r1, #SCB_AIRCR_PRIGROUP_MASK
    ldr r2, =(SCB_AIRCR_VECTKEY | SCB_AIRCR_SYSRESETREQ)
    orr r1, r1, r2
    str r1, [r0]                            @ system reset (PM0056 4.4.5)
    dsb
1:  b 1b
9:  pop {r4, pc}
ENDFUNC blcmd_update_mode

    .ltorg
