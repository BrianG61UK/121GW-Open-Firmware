@ =============================================================================
@ bl_main.s - the bootloader: vector table, start, update decision, update mode (bootloader/DESIGN.md 2, 5, 6)
@
@ Started by the starter (VTOR = 0x08000400).  It starts the firmware at 0x08006000 unless an update is wanted:
@   - MEM (PG11) and HOLD (PG13) held at power-on and no other key of PG8..PG15 (the old bootloader's test, 0x08004874),
@   - the firmware asked for it (RTC_BKP0R = BKP_MAGIC, firmware/src/ble/blcmd.s; read before the RTC domain reset of
@     the LCD clock set-up clears it),
@   - the firmware mark is not valid (an update was interrupted, or a firmware without mark).
@ Update mode: "-IAP-" on both displays, Bluetooth on (bl_ble.s).  SETUP (PG9) starts the update from the card
@ (bl_card.s).  Without a key and without a packet for 30 s the firmware starts, if its mark is valid (owner: 30 s
@ instead of the old 201 ticks, about 8 s); with no valid firmware the bootloader stays, and switches the BLE module off
@ after 10 minutes without a packet (battery); any key switches it on again.
@ Before the update decision: GPIO as the old bootloader of the owner's meter (GPIO_Config 0x080042D4, PF15 high),
@ LCD lamp test (all segments, as 0x0800365E), and a bootloader started for the first time confirms itself (control
@ record OK, the starter otherwise puts the previous one back).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "bl.inc"

    .equ KEY_SETUP,         0x0200          @ PG9
    .equ KEY_ALL,           0xFF00          @ PG8..PG15 (keys and dial contacts read by the old bootloader)
    .equ KEYS_UPDATE,       0xD700          @ PG8, 9, 10, 12, 14, 15 high; PG11 MEM and PG13 HOLD low
    .equ WINDOW_TICKS,      3000            @ 30 s
    .equ BLE_OFF_TICKS,     60000           @ 10 min
    .equ RESET_DELAY,       30              @ 300 ms after the last answer
    .equ NVIC_ISER1,        0xE000E104
    .equ NVIC_ICER0,        0xE000E180
    .equ IRQ45_53_BITS,     0x00202000      @ IRQ45 (SDIO) bit 13, IRQ53 (DMA2 channel 4) bit 21 of ISER1
    .equ APB1_PWREN,        0x10000000

@ -----------------------------------------------------------------------------
@ vector table (73 entries as the firmware's): SDIO and DMA2 channel 4 to the firmware's SD driver, the rest stop
@ -----------------------------------------------------------------------------
    .section .vectors, "a", %progbits
    .global bl_vectors
bl_vectors:
    .word BL_STACK_TOP
    .word bl_reset + 1
    .rept 14
    .word bl_fault + 1                      @ exceptions 2..15
    .endr
    .rept 45
    .word bl_fault + 1                      @ IRQ0..44
    .endr
    .word sd_sdio_isr                       @ IRQ45 SDIO
    .rept 7
    .word bl_fault + 1                      @ IRQ46..52
    .endr
    .word sd_dma_isr                        @ IRQ53 DMA2 channel 4
    .rept 3
    .word bl_fault + 1                      @ IRQ54..56
    .endr

    .section .bss.bl_main, "aw", %nobits
    .balign 4
bl_ticks:       .space 4                    @ 10 ms ticks (SysTick COUNTFLAG, polled)
bl_bkp:         .space 4                    @ RTC_BKP0R at the start
bl_idle:        .space 4                    @ tick of the last activity
bl_done_tick:   .space 4

    .section .text.bl_main, "ax", %progbits

    .thumb_func
bl_fault:
    b bl_fault

@ -----------------------------------------------------------------------------
@ bl_reset - reset entry (from the starter)
@ -----------------------------------------------------------------------------
    .global bl_reset
    .thumb_func
bl_reset:
    ldr r0, =RCC_APB1ENR                    @ PWR interface clock, then RTC_BKP0R before anything resets the RTC domain
    ldr r1, [r0]
    orr r1, r1, #APB1_PWREN
    str r1, [r0]
    ldr r0, =RTC_BKP0R
    ldr r4, [r0]
    ldr r0, =0x20000000                     @ RAM below the stack: zero (the SD driver's variables start at 0 as in the
    ldr r1, =__bss_end                      @ firmware), then the RAM code
    movs r2, #0
1:  str r2, [r0], #4
    cmp r0, r1
    blo 1b
    ldr r0, =bl_bkp
    str r4, [r0]
    ldr r0, =__ram_lma
    ldr r1, =__ram_vma
    ldr r2, =__ram_lma_end
2:  cmp r0, r2
    bhs 3f
    ldr r3, [r0], #4
    str r3, [r1], #4
    b 2b
3:  bl sys_clock_preinit                    @ as the firmware's start: HSE x12 /3 PLL if HSE starts
    movs r0, #0
    bl sys_clock_select                     @ run clock MSI 4.194 MHz, GPIO clocks on
    bl bl_gpio_config
    bl bl_lcd_init
    bl bl_lcd_all_on
    bl bl_confirm
    ldr r0, =GPIOG_BASE                     @ keys at power-on
    ldr r0, [r0, #GPIO_IDR]
    and r0, r0, #KEY_ALL
    cmp r0, #KEYS_UPDATE
    beq bl_update
    ldr r0, =bl_bkp
    ldr r0, [r0]
    ldr r1, =BKP_MAGIC
    cmp r0, r1
    beq bl_update
    bl bl_fw_mark_ok
    cmp r0, #0
    beq bl_update
    b bl_start_app

@ -----------------------------------------------------------------------------
@ bl_start_app - start the firmware: SysTick off, interrupts of the bootloader off, MSP and reset vector from 0x08006000
@ -----------------------------------------------------------------------------
    .thumb_func
bl_start_app:
    cpsid i
    ldr r0, =SYST_CSR
    movs r1, #0
    str r1, [r0]
    ldr r0, =NVIC_ICER0
    mov r1, #0xFFFFFFFF
    str r1, [r0]
    str r1, [r0, #4]
    ldr r0, =SCB_VTOR
    ldr r1, =BL_BASE
    str r1, [r0]
    dsb
    isb
    ldr r0, =APP_BASE
    ldr r1, [r0, #0]
    ldr r2, [r0, #4]
    msr msp, r1
    cpsie i
    bx r2

@ -----------------------------------------------------------------------------
@ bl_update - update mode (does not return: ends with the firmware's start or a system reset)
@ -----------------------------------------------------------------------------
    .thumb_func
bl_update:
    ldr r0, =NVIC_ISER1                     @ the SD driver's interrupts (card update)
    ldr r1, =IRQ45_53_BITS
    str r1, [r0]
    ldr r0, =SYST_RVR                       @ SysTick: 10 ms on the run clock, polled
    ldr r1, =TICK_RELOAD
    str r1, [r0]
    ldr r0, =SYST_CVR
    movs r1, #0
    str r1, [r0]
    ldr r0, =SYST_CSR
    movs r1, #5                             @ ENABLE | CLKSOURCE (processor clock), no interrupt
    str r1, [r0]
.Lu_show:
    bl bl_show_iap
    bl bl_ble_on
    movs r6, #1                             @ r6 = BLE module on
    bl bl_now
    ldr r1, =bl_idle
    str r0, [r1]
    ldr r1, =bl_ble_activity
    str r0, [r1]
.Lu_loop:
    bl bl_now
    mov r4, r0                              @ r4 = now
    cbz r6, 1f
    bl bl_ble_poll
    ldr r0, =bl_ble_activity                @ a packet counts as activity
    ldr r0, [r0]
    ldr r1, =bl_idle
    ldr r2, [r1]
    cmp r0, r2
    it hi
    strhi r0, [r1]
1:  ldr r0, =bl_reset_due                   @ a finished transfer: restart after RESET_DELAY
    ldrb r0, [r0]
    cbz r0, 2f
    ldr r1, =bl_ble_activity
    ldr r1, [r1]
    subs r1, r4, r1
    cmp r1, #RESET_DELAY
    blo 2f
    b bl_sysreset
2:  ldr r0, =GPIOG_BASE                     @ keys
    ldr r0, [r0, #GPIO_IDR]
    and r0, r0, #KEY_ALL
    tst r0, #KEY_SETUP
    beq .Lu_card
    cmp r0, #KEY_ALL
    beq 3f                                  @ no key
    cbnz r6, 3f
    bl bl_ble_on                            @ any key switches the BLE module on again
    movs r6, #1
    ldr r1, =bl_idle
    str r4, [r1]
3:  ldr r1, =bl_idle                        @ timeouts
    ldr r1, [r1]
    subs r5, r4, r1                         @ r5 = idle ticks
    bl bl_fw_mark_ok
    cbz r0, 4f
    movw r1, #WINDOW_TICKS
    cmp r5, r1
    blo .Lu_loop
    bl bl_ble_off                           @ 30 s without a key or a packet, firmware valid: start it
    b bl_start_app
4:  cmp r6, #0
    beq .Lu_loop
    ldr r0, =BLE_OFF_TICKS
    cmp r5, r0
    blo .Lu_loop
    bl bl_ble_off                           @ no valid firmware, 10 min without a packet: BLE module off
    movs r6, #0
    b .Lu_loop
.Lu_card:
    bl bl_now                               @ SETUP: still pressed 50 ms later (contact bounce)
    add r5, r0, #5
5:  bl bl_now
    cmp r0, r5
    blo 5b
    ldr r0, =GPIOG_BASE
    ldr r0, [r0, #GPIO_IDR]
    tst r0, #KEY_SETUP
    bne .Lu_loop
    cbz r6, 6f
    bl bl_ble_off
6:  movs r6, #0
    bl bl_card_update
    mov r7, r0
    bl bl_now                               @ the result for 2 s
    add r5, r0, #200
7:  bl bl_now
    cmp r0, r5
    blo 7b
    cmp r7, #0
    bne .Lu_show
    b bl_start_app

@ -----------------------------------------------------------------------------
@ bl_show_iap - "-IAP-" on both displays (old bootloader 0x08003388, 0x08003328), bargraph off
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC bl_show_iap
    push {lr}
    bl bl_lcd_clear
    movs r0, #0
    ldr r1, =bl_txt_iap
    bl bl_lcd_text
    movs r0, #5
    ldr r1, =bl_txt_iap
    bl bl_lcd_text
    bl bl_lcd_commit
    pop {pc}
ENDFUNC bl_show_iap

@ -----------------------------------------------------------------------------
@ bl_now - the 10 ms tick count (SysTick COUNTFLAG polled; the caller polls often enough: every loop pass is far
@ shorter than 10 ms except a flash erase at START, which counts as one tick)
@ Out      : r0 = ticks
@ Clobbers : r1
@ -----------------------------------------------------------------------------
LFUNC bl_now
    ldr r1, =SYST_CSR
    ldr r0, [r1]
    ldr r1, =bl_ticks
    tst r0, #0x10000                        @ COUNTFLAG (cleared by the read)
    ldr r0, [r1]
    it ne
    addne r0, r0, #1
    str r0, [r1]
    bx lr
ENDFUNC bl_now

@ -----------------------------------------------------------------------------
@ bl_sysreset - system reset (PM0056 4.4.5); the starter runs, then the bootloader, then the firmware
@ -----------------------------------------------------------------------------
    .thumb_func
bl_sysreset:
    bl bl_ble_off
    dsb
    ldr r0, =SCB_AIRCR
    ldr r1, [r0]
    and r1, r1, #SCB_AIRCR_PRIGROUP_MASK
    ldr r2, =(SCB_AIRCR_VECTKEY | SCB_AIRCR_SYSRESETREQ)
    orr r1, r1, r2
    str r1, [r0]
    dsb
1:  b 1b

@ -----------------------------------------------------------------------------
@ bl_gpio_config - GPIO as the old bootloader of the owner's meter (GPIO_Config 0x080042D4: GPIO_Init calls with the
@ pin masks and settings below, then the BSRR writes in the same order)
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ -----------------------------------------------------------------------------
LFUNC bl_gpio_config
    push {r4, lr}
    ldr r4, =bl_gpio_seq
1:  ldr r0, [r4], #4                        @ port base, 0 ends
    cbz r0, 3f
    ldr r1, [r4], #4                        @ pins, or BSRR value when bit 31 is set
    ldr r2, [r4], #4                        @ mode | speed << 8 | otype << 16 | pupd << 24, or the BSRR offset
    tst r1, #0x80000000
    beq 2f
    strh r1, [r0, r2]                       @ BSRRL (0x18) sets, BSRRH (0x1A) resets
    b 1b
2:  bl bl_gpio_init
    b 1b
3:  pop {r4, pc}
ENDFUNC bl_gpio_config

@ -----------------------------------------------------------------------------
@ bl_gpio_init - ST GPIO_Init semantics (old bootloader 0x08001CD0): for every pin of the mask, MODER; for output and
@ AF also OSPEEDR and OTYPER; then PUPDR
@ In       : r0 = port, r1 = pins, r2 = mode | speed << 8 | otype << 16 | pupd << 24
@ Clobbers : r1-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
LFUNC bl_gpio_init
    push {r4-r7, lr}
    mov r4, r1
    mov r5, r2
    movs r6, #0                             @ pin
1:  lsrs r1, r4, r6
    tst r1, #1
    beq 4f
    lsls r7, r6, #1                         @ 2 bits per pin
    movs r3, #3
    lsls r3, r3, r7
    ldr r1, [r0, #0x00]                     @ MODER
    bics r1, r1, r3
    and r2, r5, #0xFF
    lsls r2, r2, r7
    orrs r1, r1, r2
    str r1, [r0, #0x00]
    and r2, r5, #0xFF
    cmp r2, #1
    beq 2f
    cmp r2, #2
    bne 3f
2:  ldr r1, [r0, #0x08]                     @ OSPEEDR
    bics r1, r1, r3
    ubfx r2, r5, #8, #8
    lsls r2, r2, r7
    orrs r1, r1, r2
    str r1, [r0, #0x08]
    ldrh r1, [r0, #0x04]                    @ OTYPER
    movs r2, #1
    lsls r2, r2, r6
    bics r1, r1, r2
    ubfx r2, r5, #16, #8
    lsls r2, r2, r6
    orrs r1, r1, r2
    strh r1, [r0, #0x04]
3:  ldr r1, [r0, #0x0C]                     @ PUPDR
    bics r1, r1, r3
    ubfx r2, r5, #24, #8
    lsls r2, r2, r7
    orrs r1, r1, r2
    str r1, [r0, #0x0C]
4:  adds r6, r6, #1
    cmp r6, #16
    bne 1b
    pop {r4-r7, pc}
ENDFUNC bl_gpio_init

    .ltorg

    .section .rodata.bl_main, "a", %progbits
    .balign 4
@ old GPIO_Config (owner's build), in order: port, pins, mode | speed << 8 | otype << 16 | pupd << 24; or port,
@ 0x80000000 | BSRR value, BSRR offset
    .equ IN_UP_40M,  0x01000300             @ mode 0 input, speed 3, pull-up
    .equ OUT_2M,     0x00000101             @ mode 1 output, speed 1, push-pull, no pull
    .equ SET,        0x18
    .equ CLR,        0x1A
bl_gpio_seq:
    .word GPIOG_BASE, 0xFFFF, IN_UP_40M                     @ keys and dial contacts
    .word GPIOE_BASE, 0x33F0, OUT_2M                        @ PE4..9, PE12, PE13
    .word GPIOE_BASE, 0x80000200, SET                       @ PE9 high
    .word GPIOE_BASE, 0x80000100, SET                       @ PE8 high
    .word GPIOE_BASE, 0x80000080, CLR                       @ PE7 low
    .word GPIOE_BASE, 0x80001000, CLR                       @ PE12 low
    .word GPIOE_BASE, 0x80002000, CLR                       @ PE13 low
    .word GPIOE_BASE, 0x80000020, CLR                       @ PE5 low
    .word GPIOE_BASE, 0x80000010, CLR                       @ PE4 low
    .word GPIOE_BASE, 0x80000040, CLR                       @ PE6 low
    .word GPIOF_BASE, 0x0004, OUT_2M                        @ PF2
    .word GPIOF_BASE, 0x0001, OUT_2M                        @ PF0
    .word GPIOF_BASE, 0x0002, OUT_2M                        @ PF1
    .word GPIOF_BASE, 0x0008, IN_UP_40M                     @ PF3 input, pull-up
    .word GPIOF_BASE, 0x80000002, SET                       @ PF1 high
    .word GPIOF_BASE, 0x80000004, SET                       @ PF2 high
    .word GPIOF_BASE, 0x80000001, CLR                       @ PF0 low
    .word GPIOF_BASE, 0x87C0, OUT_2M                        @ PF6..10, PF15
    .word GPIOF_BASE, 0x80000200, SET                       @ PF9 high
    .word GPIOF_BASE, 0x80000080, CLR                       @ PF7 low
    .word GPIOF_BASE, 0x80000040, CLR                       @ PF6 low
    .word GPIOF_BASE, 0x80000400, CLR                       @ PF10 low
    .word GPIOF_BASE, 0x80000100, SET                       @ PF8 high
    .word GPIOF_BASE, 0x80008000, SET                       @ PF15 high (BLE module supply, owner's build)
    .word GPIOD_BASE, 0x0080, OUT_2M                        @ PD7
    .word GPIOD_BASE, 0x80000080, CLR                       @ PD7 low
    .word 0
