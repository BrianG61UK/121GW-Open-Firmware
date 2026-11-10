@ =============================================================================
@ bl.inc - constants of the bootloader (bootloader/DESIGN.md 6); the starter (starter.s) and bootloader/tools/blimage.py
@ use the same values
@ =============================================================================

    .equ BL_BASE,           0x08000400      @ this bootloader: vector table (512-byte boundary, PM0056 4.4.4)
    .equ BL_MARK,           0x08005F00      @ bootloader mark (written by the starter)
    .equ BL_MAX,            0x5B00          @ largest bootloader image
    .equ APP_BASE,          0x08006000      @ firmware
    .equ APP_LIMIT,         0x08052000      @ end of the firmware area (firmware/link/121gw.ld)
    .equ APP_MAX,           0x4C000
    .equ SLOT_A,            0x08052000      @ bootloader slots: header page, image from +0x100
    .equ SLOT_B,            0x08058000
    .equ SLOT_XOR,          0x0000A000      @ SLOT_A ^ SLOT_B
    .equ SLOT_IMG,          0x100
    .equ SLOT_SIZE,         0x6000
    .equ CTL_BASE,          0x0805E000      @ control area: 16-byte records
    .equ CTL_END,           0x0805FF00
    .equ FW_MARK,           0x0805FF00      @ firmware mark page
    .equ HDR_MAGIC,         0x32484C42      @ "BLH2" bootloader header / mark
    .equ FW_MAGIC,          0x32485746      @ "FWH2" firmware mark
    .equ CTL_MAGIC,         0x4C525443      @ "CTRL" control record
    .equ CMD_INSTALL,       1
    .equ CMD_TRIAL,         2
    .equ CMD_OK,            3
    .equ BKP_MAGIC,         0x55504454      @ RTC_BKP0R: update mode requested by the firmware (firmware ble/blcmd.s)
    .equ RTC_BKP0R,         0x40002850      @ RM0038 20.6.20
    .equ RTC_BKP1R,         0x40002854      @ RM0038 20.6.20 (RTC base + 0x50 + 4)
    .equ BKP_BT_MAGIC,      0x4E4F5442      @ "BTON" RTC_BKP1R: a Bluetooth update has ended, the firmware switches
                                            @ Bluetooth on (DESIGN.md 6.5.1; firmware sys/main.s, ble/bft.s)
    .equ BL_VERSION,        0x00010106      @ this bootloader: 1.1.6 (major << 16 | minor << 8 | patch)

    .equ BL_RAM_BASE,       0x20008100      @ RAM of the bootloader's own objects; below it the v2.05 addresses the
                                            @ firmware's SD driver uses (firmware/src/sd) are left to that driver
    .equ BL_STACK_TOP,      0x2000C000

    .equ SYST_CSR,          0xE000E010      @ SysTick (PM0056 4.5)
    .equ SYST_RVR,          0xE000E014
    .equ SYST_CVR,          0xE000E018
    .equ MSI_HZ,            4194304         @ run clock, MSI range 6 (firmware sys_clock_select 0)
    .equ TICK_RELOAD,       (MSI_HZ / 100) - 1  @ 10 ms

    .equ USART2_BASE_BL,    0x40004400
    .equ USART_SR,          0x00
    .equ USART_DR,          0x04
    .equ USART_BRR,         0x08
    .equ USART_CR1,         0x0C
    .equ USART_BRR_19200,   0xDA            @ 4194304 / (16 x 19200) = 13.65: mantissa 13, fraction 10 (ST USART_Init
                                            @ rounding, as the firmware computes it at MSI)
