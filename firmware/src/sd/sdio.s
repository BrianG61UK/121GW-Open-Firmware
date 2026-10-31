@ sdio.s - SD module: SDIO host and DMA2 register access, the two interrupt handlers, the SD pins (DESIGN.md 6.23, W8)
@
@ The register wrappers are the STM32 standard peripheral library functions that the v2.05 SD driver uses (SDIO_Init,
@ SDIO_ClockCmd, SDIO_SetPowerState, SDIO_SendCommand, SDIO_DataConfig, SDIO_ITConfig, SDIO_GetFlagStatus, SDIO_ClearFlag,
@ DMA_Init, DMA_Cmd, DMA_ITConfig, DMA_ClearITPendingBit); each accesses the register block through a literal
@ address, as in v2.05.  Bit-band aliases (SD_CLKCR_CLKEN_BB, SD_DCTRL_DMAEN_BB) are used for the single-bit enables.
@ SDIO registers: RM0038 chapter 29 (base 0x40012C00); DMA2 channel 4 serves the SDIO (RM0038 table of DMA requests).
@
@ Interrupts (DESIGN.md 3.4): IRQ45 SDIO and IRQ53 DMA2 channel 4 at priority 0, so they preempt TIM2 and TIM3.  Their handlers
@ only set flag variables read by the polling loops of sdcard.s (sd_transfer_end, sd_dma_end, sd_transfer_error).
@
@ The pins (PC8 = SD_D0, PD2 = SD_CMD, PC12 = SD_CK) are configured through brd_gpio_init and gpio_set_alternate_function of BRD
@ (sdio_gpio_init, sdio_gpio_deinit, hand-written in this port).
@
.equ SD_CLKCR_CLKEN_BB,  0x422580A0        @ bit-band alias of SDIO_CLKCR bit 8 (CLKEN): 0x42000000 + (0x40012C04 - 0x40000000) * 32 + 8 * 4
.equ SD_DCTRL_DMAEN_BB,  0x4225858C        @ bit-band alias of SDIO_DCTRL bit 3 (DMAEN): 0x42000000 + (0x40012C2C - 0x40000000) * 32 + 3 * 4
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
    .equ sd_transfer_end,         v_20007EF4            @ 0x20007EF4 set to 1 by the SDIO interrupt at the end of the data transfer
    .equ sd_dma_end,              v_20007EF8            @ 0x20007EF8 set to 1 by the DMA interrupt when the DMA transfer is complete
    .equ sd_transfer_error,       v_200080F7            @ 0x200080F7 error code set by the SDIO interrupt (0 none, 2 CRC fail, 4 timeout, 5 TX underrun, 6 RX overrun, 7 start bit error)

@ -----------------------------------------------------------------------------
@ sd_sdio_isr_body - SDIO interrupt: note the end of the transfer or its error and mask the interrupt sources
@ Replaces  : 0x08023476 FUN_08023476 (v2.05), called by sd_sdio_isr
@ In        : -
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : ISR (IRQ45, priority 0)
@ RAM       : writes sd_transfer_error 0x200080F7 and sd_transfer_end 0x20007EF4
@ Spec      : v2.05 listing 0x08023476..0x08023523
@ Note      : tests the pending interrupt flags in this order and handles the first that is set: DATAEND (0x100): error code 0,
@             sd_transfer_end = 1; DCRCFAIL (0x2): error 2; DTIMEOUT (0x8): error 4; TXUNDERR (0x10): error 5; RXOVERR (0x20): error 6;
@             STBITERR (0x200): error 7.  The flag is cleared and finally the interrupt sources 0xC33A are disabled (SDIO_MASK).
@             The polling loops of sdcard.s read the variables; this routine never starts a transfer.
@ -----------------------------------------------------------------------------
FUNC sd_sdio_isr_body
    @ DATAEND
    push    {r7, lr}                        @ 08023476 push {r7, lr}
    mov.w   r0, #0x100                      @ 08023478 r0 = 0x100
    bl      sdio_get_it_status              @ 0802347C call sdio_get_it_status
    cmp     r0, #0                          @ 08023480 compare r0 with 0
    beq     .Lsd_sdio_isr_body_349A         @ 08023482 if (r0 == 0) goto 0x802349A
    movs    r0, #0                          @ 08023484 r0 = 0
    ldr     r1, =sd_transfer_error          @ 08023486 r1 = &sd_transfer_error
    strb    r0, [r1]                        @ 08023488 u8 [sd_transfer_error] = r0
    mov.w   r0, #0x100                      @ 0802348A r0 = 0x100
    bl      sdio_clear_it_pending_bit       @ 0802348E call sdio_clear_it_pending_bit
    movs    r0, #1                          @ 08023492 r0 = 1
    ldr     r1, =sd_transfer_end            @ 08023494 r1 = &sd_transfer_end
    str     r0, [r1]                        @ 08023496 u32 [sd_transfer_end] = r0
    b       .Lsd_sdio_isr_body_3514         @ 08023498 goto 0x8023514
.Lsd_sdio_isr_body_349A:                @ v2.05 0x0802349A, reached from 0x08023482
    movs    r0, #2                          @ 0802349A r0 = 2
    @ DCRCFAIL
    bl      sdio_get_it_status              @ 0802349C call sdio_get_it_status
    cmp     r0, #0                          @ 080234A0 compare r0 with 0
    beq     .Lsd_sdio_isr_body_34B2         @ 080234A2 if (r0 == 0) goto 0x80234B2
    movs    r0, #2                          @ 080234A4 r0 = 2
    bl      sdio_clear_it_pending_bit       @ 080234A6 call sdio_clear_it_pending_bit
    movs    r0, #2                          @ 080234AA r0 = 2
    ldr     r1, =sd_transfer_error          @ 080234AC r1 = &sd_transfer_error
    strb    r0, [r1]                        @ 080234AE u8 [sd_transfer_error] = r0
    b       .Lsd_sdio_isr_body_3514         @ 080234B0 goto 0x8023514
.Lsd_sdio_isr_body_34B2:                @ v2.05 0x080234B2, reached from 0x080234A2
    movs    r0, #8                          @ 080234B2 r0 = 8
    @ DTIMEOUT
    bl      sdio_get_it_status              @ 080234B4 call sdio_get_it_status
    cmp     r0, #0                          @ 080234B8 compare r0 with 0
    beq     .Lsd_sdio_isr_body_34CA         @ 080234BA if (r0 == 0) goto 0x80234CA
    movs    r0, #8                          @ 080234BC r0 = 8
    bl      sdio_clear_it_pending_bit       @ 080234BE call sdio_clear_it_pending_bit
    movs    r0, #4                          @ 080234C2 r0 = 4
    ldr     r1, =sd_transfer_error          @ 080234C4 r1 = &sd_transfer_error
    strb    r0, [r1]                        @ 080234C6 u8 [sd_transfer_error] = r0
    b       .Lsd_sdio_isr_body_3514         @ 080234C8 goto 0x8023514
.Lsd_sdio_isr_body_34CA:                @ v2.05 0x080234CA, reached from 0x080234BA
    movs    r0, #0x20                       @ 080234CA r0 = 0x20
    @ TXUNDERR
    bl      sdio_get_it_status              @ 080234CC call sdio_get_it_status
    cmp     r0, #0                          @ 080234D0 compare r0 with 0
    beq     .Lsd_sdio_isr_body_34E2         @ 080234D2 if (r0 == 0) goto 0x80234E2
    movs    r0, #0x20                       @ 080234D4 r0 = 0x20
    bl      sdio_clear_it_pending_bit       @ 080234D6 call sdio_clear_it_pending_bit
    movs    r0, #6                          @ 080234DA r0 = 6
    ldr     r1, =sd_transfer_error          @ 080234DC r1 = &sd_transfer_error
    strb    r0, [r1]                        @ 080234DE u8 [sd_transfer_error] = r0
    b       .Lsd_sdio_isr_body_3514         @ 080234E0 goto 0x8023514
.Lsd_sdio_isr_body_34E2:                @ v2.05 0x080234E2, reached from 0x080234D2
    movs    r0, #0x10                       @ 080234E2 r0 = 0x10
    @ RXOVERR
    bl      sdio_get_it_status              @ 080234E4 call sdio_get_it_status
    cmp     r0, #0                          @ 080234E8 compare r0 with 0
    beq     .Lsd_sdio_isr_body_34FA         @ 080234EA if (r0 == 0) goto 0x80234FA
    movs    r0, #0x10                       @ 080234EC r0 = 0x10
    bl      sdio_clear_it_pending_bit       @ 080234EE call sdio_clear_it_pending_bit
    movs    r0, #5                          @ 080234F2 r0 = 5
    ldr     r1, =sd_transfer_error          @ 080234F4 r1 = &sd_transfer_error
    strb    r0, [r1]                        @ 080234F6 u8 [sd_transfer_error] = r0
    b       .Lsd_sdio_isr_body_3514         @ 080234F8 goto 0x8023514
.Lsd_sdio_isr_body_34FA:                @ v2.05 0x080234FA, reached from 0x080234EA
    mov.w   r0, #0x200                      @ 080234FA r0 = 0x200
    @ STBITERR
    bl      sdio_get_it_status              @ 080234FE call sdio_get_it_status
    cmp     r0, #0                          @ 08023502 compare r0 with 0
    beq     .Lsd_sdio_isr_body_3514         @ 08023504 if (r0 == 0) goto 0x8023514
    mov.w   r0, #0x200                      @ 08023506 r0 = 0x200
    bl      sdio_clear_it_pending_bit       @ 0802350A call sdio_clear_it_pending_bit
    movs    r0, #7                          @ 0802350E r0 = 7
    ldr     r1, =sd_transfer_error          @ 08023510 r1 = &sd_transfer_error
    strb    r0, [r1]                        @ 08023512 u8 [sd_transfer_error] = r0
    @ disable all interrupt sources of the SDIO (0xC33A)
.Lsd_sdio_isr_body_3514:                @ v2.05 0x08023514, reached from 0x08023498, 0x080234B0, 0x080234C8, 0x080234E0, 0x080234F8, 0x08023504
    movs    r1, #0                          @ 08023514 r1 = 0
    movw    r0, #0xc33a                     @ 08023516
    bl      sdio_it_config                  @ 0802351A call sdio_it_config
    ldr     r0, =sd_transfer_error          @ 0802351E r0 = &sd_transfer_error
    ldrb    r0, [r0]                        @ 08023520 r0 = u8 [sd_transfer_error]
    pop     {r1, pc}                        @ 08023522 pop {r1, pc}
ENDFUNC sd_sdio_isr_body
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_dma_isr_body - DMA2 interrupt: note the end of the DMA transfer
@ Replaces  : 0x08023524 FUN_08023524 (v2.05), called by sd_dma_isr
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : ISR (IRQ53, priority 0)
@ RAM       : writes sd_dma_end 0x20007EF8
@ Spec      : v2.05 listing 0x08023524..0x08023543
@ Note      : if the transfer-complete flag of channel 4 is set in DMA2_ISR (mask 0x10002000, bit 28 is the DMA2 marker of the library flag
@             word) sd_dma_end = 1 and the flags of channel 4 are cleared (flag word 0x1000F000 to DMA2_IFCR).
@ -----------------------------------------------------------------------------
FUNC sd_dma_isr_body
    push    {r7, lr}                        @ 08023524 push {r7, lr}
    ldr.w   r0, =DMA2_BASE                  @ 08023526 r0 = DMA2_BASE
    ldr     r0, [r0]                        @ 0802352A r0 = u32 [DMA2_BASE]
    ldr.w   r1, =0x10002000                 @ 0802352C r1 = 0x10002000
    tst     r0, r1                          @ 08023530 compare r0 with r1
    beq     .Lsd_dma_isr_body_3542          @ 08023532 if ((r0 & r1) == 0) goto 0x8023542
    movs    r0, #1                          @ 08023534 r0 = 1
    ldr     r1, =sd_dma_end                 @ 08023536 r1 = &sd_dma_end
    str     r0, [r1]                        @ 08023538 u32 [sd_dma_end] = r0
    ldr.w   r0, =0x1000F000                 @ 0802353A r0 = 0x1000F000
    bl      dma_clear_it_pending_bit        @ 0802353E call dma_clear_it_pending_bit
.Lsd_dma_isr_body_3542:                 @ v2.05 0x08023542, reached from 0x08023532
    pop     {r0, pc}                        @ 08023542 pop {r0, pc}
ENDFUNC sd_dma_isr_body
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_gpio_deinit - switch the SDIO block off and release the SD pins
@ Replaces : 0x08023CD8 sdio_gpio_deinit (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (called from sd_bringup before every probe)
@ RAM      : none
@ Spec     : RM0038 6.3.10 (APB2RSTR), 7.3.2; DESIGN.md 4.2 (PC8/PD2 become inputs, never outputs)
@ Order    : v2.05 0x08023CD8..0x08023D54: SDIO clock off (CLKCR.CLKEN), SDIO power off (POWER = 0), SDIO reset
@            (APB2RSTR bit 11 set then cleared), SDIO bus clock off (APB2ENR bit 11), AFR = 0 for PC8, PC12, PD2, then
@            PC8, PD2, PC12 as plain inputs without pull.  The v2.05 gpio_init calls leave the speed and output-type
@            bytes of their descriptor uninitialised (stack garbage, 0x08023D1C..0x08023D4E); an input pin ignores
@            both (RM0038 7.4), the port passes defined values.
@ -----------------------------------------------------------------------------
FUNC sdio_gpio_deinit
    push    {r4, lr}
    movs    r0, #0
    bl      sdio_clock_cmd                  @ SDIO_ClockCmd(DISABLE)
    movs    r0, #0
    bl      sdio_set_power_state            @ SDIO_SetPowerState(OFF)
    bl      sdio_reset                      @ pulse APB2RSTR.SDIORST
    movw    r0, #RCC_APB2_SDIO
    movs    r1, #0
    bl      fn_0801FF9E                     @ RCC_APB2PeriphClockCmd(SDIO, DISABLE)
    ldr     r0, =GPIOC_BASE
    movs    r1, #8
    movs    r2, #0
    bl      gpio_set_alternate_function     @ PC8 AFR = 0
    ldr     r0, =GPIOC_BASE
    movs    r1, #12
    movs    r2, #0
    bl      gpio_set_alternate_function     @ PC12 AFR = 0
    ldr     r0, =GPIOD_BASE
    movs    r1, #2
    movs    r2, #0
    bl      gpio_set_alternate_function     @ PD2 AFR = 0
    ldr     r0, =GPIOC_BASE
    ldr     r1, =.Lsdio_desc_in_pc8
    bl      brd_gpio_init                   @ PC8 input
    ldr     r0, =GPIOD_BASE
    ldr     r1, =.Lsdio_desc_in_pd2
    bl      brd_gpio_init                   @ PD2 input
    ldr     r0, =GPIOC_BASE
    ldr     r1, =.Lsdio_desc_in_pc12
    bl      brd_gpio_init                   @ PC12 input
    pop     {r4, pc}
    .ltorg
ENDFUNC sdio_gpio_deinit

@ -----------------------------------------------------------------------------
@ sdio_gpio_init - clock the SD pins and the SDIO/DMA2 blocks, put PC8, PC12 and PD2 under SDIO control
@ Replaces : 0x08023D56 sdio_gpio_init (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (called from sd_init)
@ RAM      : none
@ Spec     : RM0038 7.3.2, 29.2 (SDIO pins), 11.3 (DMA2 serves SDIO); DESIGN.md 4.2 (SD_D0 = PC8, SD_CMD = PD2 are
@            driven by the card, AF12 only), 6.23
@ Order    : v2.05 0x08023D56..0x08023DE6: GPIOC+GPIOD clock on (0x0C), AF12 into AFR for PC8, PC12, PD2, then one
@            gpio_init per pin group, SDIO clock (APB2 bit 11), DMA2 clock (AHB bit 25).  Here every group is one
@            brd_gpio_init call that writes AFR, speed, type, pull and MODER in that order (HW-04 order of BRD), so the
@            AFR of PC8 is written just before PC8 becomes an AF pin instead of before PC12/PD2 are touched; the final
@            register state is the same as v2.05's.
@ Pins     : PC8 = SD_D0 (AF12, 40 MHz, push-pull, pull-up), PD2 = SD_CMD (same), PC12 = SD_CK (no pull)
@ -----------------------------------------------------------------------------
FUNC sdio_gpio_init
    push    {r4, lr}
    movs    r0, #0x0C                       @ AHBENR bits 2 and 3 = GPIOCEN | GPIODEN (v2.05 0x08023D5A)
    movs    r1, #1                          @ ENABLE
    bl      fn_0801FF80                     @ RCC_AHBPeriphClockCmd
    ldr     r0, =GPIOC_BASE
    ldr     r1, =.Lsdio_desc_pc8
    bl      brd_gpio_init                   @ PC8 = SDIO_D0, AF12, pull-up (v2.05 0x08023D6A..0x08023D9C)
    ldr     r0, =GPIOD_BASE
    ldr     r1, =.Lsdio_desc_pd2
    bl      brd_gpio_init                   @ PD2 = SDIO_CMD, AF12, pull-up
    ldr     r0, =GPIOC_BASE
    ldr     r1, =.Lsdio_desc_pc12
    bl      brd_gpio_init                   @ PC12 = SDIO_CK, AF12, no pull
    movw    r0, #RCC_APB2_SDIO              @ APB2ENR bit 11 = SDIOEN (v2.05 0x08023DD4)
    movs    r1, #1
    bl      fn_0801FF9E                     @ RCC_APB2PeriphClockCmd(SDIO, ENABLE)
    ldr     r0, =RCC_AHBENR_DMA2EN          @ AHBENR bit 25 = DMA2EN (v2.05 0x08023DDC)
    movs    r1, #1
    bl      fn_0801FF80                     @ RCC_AHBPeriphClockCmd(DMA2, ENABLE)
    pop     {r4, pc}
    .ltorg
ENDFUNC sdio_gpio_init

    .pushsection .rodata.sd, "a", %progbits
.Lsdio_desc_pc8:
    GPIO_DESC 0x0100, GPIO_MODE_AF, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_UP, 12, BRD_LEVEL_KEEP
.Lsdio_desc_pd2:
    GPIO_DESC 0x0004, GPIO_MODE_AF, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_UP, 12, BRD_LEVEL_KEEP
.Lsdio_desc_pc12:
    GPIO_DESC 0x1000, GPIO_MODE_AF, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_NONE, 12, BRD_LEVEL_KEEP
.Lsdio_desc_in_pc8:
    GPIO_DESC 0x0100, GPIO_MODE_IN, GPIO_SPEED_400K, GPIO_OT_PP, GPIO_PUPD_NONE, 0xFF, BRD_LEVEL_KEEP
.Lsdio_desc_in_pd2:
    GPIO_DESC 0x0004, GPIO_MODE_IN, GPIO_SPEED_400K, GPIO_OT_PP, GPIO_PUPD_NONE, 0xFF, BRD_LEVEL_KEEP
.Lsdio_desc_in_pc12:
    GPIO_DESC 0x1000, GPIO_MODE_IN, GPIO_SPEED_400K, GPIO_OT_PP, GPIO_PUPD_NONE, 0xFF, BRD_LEVEL_KEEP
    .popsection

@ -----------------------------------------------------------------------------
@ sd_dma_start_tx - start the DMA2 channel 4 transfer memory to the SDIO FIFO
@ Replaces  : 0x08023DE8 FUN_08023DE8 (v2.05), called by sd_write_blocks
@ In        : r0 = source buffer, r1 = byte count (a multiple of 4)
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08023DE8..0x08023E57
@ Note      : the flags of channel 4 are cleared (flag word 0x1000F000), the channel is disabled, then configured with the DMA_InitTypeDef
@             {peripheral address SDIO_FIFO 0x40012C80, memory address = r0, direction memory to peripheral (0x10), buffer size = r1 / 4 words,
@             peripheral increment off, memory increment on (0x80), peripheral and memory data size word (0x200, 0x800), normal mode,
@             priority 0x2000 (high), no memory-to-memory}, the transfer-complete interrupt is enabled (CCR bit 1) and the channel is enabled.
@ -----------------------------------------------------------------------------
FUNC sd_dma_start_tx
    push    {r4, r5, lr}                    @ 08023DE8 push {r4, r5, lr}
    sub     sp, #0x2c                       @ 08023DEA sp -= 0x2c
    movs    r4, r0                          @ 08023DEC r4 = r0
    movs    r5, r1                          @ 08023DEE r5 = r1
    ldr.w   r0, =0x1000F000                 @ 08023DF0 r0 = 0x1000F000
    bl      dma_clear_it_pending_bit        @ 08023DF4 call dma_clear_it_pending_bit
    movs    r1, #0                          @ 08023DF8 r1 = 0
    ldr.w   r0, =(DMA2_BASE + DMA_CH4_CCR)  @ 08023DFA r0 = (DMA2_BASE + DMA_CH4_CCR)
    bl      dma_cmd                         @ 08023DFE call dma_cmd
    ldr.w   r0, =(SDIO_BASE + SDIO_FIFO)    @ 08023E02 r0 = (SDIO_BASE + SDIO_FIFO)
    str     r0, [sp]                        @ 08023E06 u32 [sp] = r0
    str     r4, [sp, #4]                    @ 08023E08 u32 [sp+0x4] = r4
    movs    r0, #0x10                       @ 08023E0A r0 = 0x10
    str     r0, [sp, #8]                    @ 08023E0C u32 [sp+0x8] = r0
    lsrs    r0, r5, #2                      @ 08023E0E r0 = r5 >> 2
    str     r0, [sp, #0xc]                  @ 08023E10 u32 [sp+0xC] = r0
    movs    r0, #0                          @ 08023E12 r0 = 0
    str     r0, [sp, #0x10]                 @ 08023E14 u32 [sp+0x10] = r0
    movs    r0, #0x80                       @ 08023E16 r0 = 0x80
    str     r0, [sp, #0x14]                 @ 08023E18 u32 [sp+0x14] = r0
    mov.w   r0, #0x200                      @ 08023E1A r0 = 0x200
    str     r0, [sp, #0x18]                 @ 08023E1E u32 [sp+0x18] = r0
    mov.w   r0, #0x800                      @ 08023E20 r0 = 0x800
    str     r0, [sp, #0x1c]                 @ 08023E24 u32 [sp+0x1C] = r0
    movs    r0, #0                          @ 08023E26 r0 = 0
    str     r0, [sp, #0x20]                 @ 08023E28 u32 [sp+0x20] = r0
    mov.w   r0, #0x2000                     @ 08023E2A r0 = 0x2000
    str     r0, [sp, #0x24]                 @ 08023E2E u32 [sp+0x24] = r0
    movs    r0, #0                          @ 08023E30 r0 = 0
    str     r0, [sp, #0x28]                 @ 08023E32 u32 [sp+0x28] = r0
    mov     r1, sp                          @ 08023E34 r1 = sp
    ldr.w   r0, =(DMA2_BASE + DMA_CH4_CCR)  @ 08023E36 r0 = (DMA2_BASE + DMA_CH4_CCR)
    bl      dma_init                        @ 08023E3A call dma_init
    movs    r2, #1                          @ 08023E3E r2 = 1
    movs    r1, #2                          @ 08023E40 r1 = 2
    ldr.w   r0, =(DMA2_BASE + DMA_CH4_CCR)  @ 08023E42 r0 = (DMA2_BASE + DMA_CH4_CCR)
    bl      dma_it_config                   @ 08023E46 call dma_it_config
    movs    r1, #1                          @ 08023E4A r1 = 1
    ldr.w   r0, =(DMA2_BASE + DMA_CH4_CCR)  @ 08023E4C r0 = (DMA2_BASE + DMA_CH4_CCR)
    bl      dma_cmd                         @ 08023E50 call dma_cmd
    add     sp, #0x2c                       @ 08023E54 sp += 0x2c
    pop     {r4, r5, pc}                    @ 08023E56 pop {r4, r5, pc}
ENDFUNC sd_dma_start_tx
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_dma_start_rx - start the DMA2 channel 4 transfer SDIO FIFO to memory
@ Replaces  : 0x08023E58 FUN_08023E58 (v2.05), called by sd_read_block
@ In        : r0 = destination buffer, r1 = byte count (a multiple of 4)
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08023E58..0x08023EC7
@ Note      : the same as sd_dma_start_tx with direction peripheral to memory (0).
@ -----------------------------------------------------------------------------
FUNC sd_dma_start_rx
    push    {r4, r5, lr}                    @ 08023E58 push {r4, r5, lr}
    sub     sp, #0x2c                       @ 08023E5A sp -= 0x2c
    movs    r4, r0                          @ 08023E5C r4 = r0
    movs    r5, r1                          @ 08023E5E r5 = r1
    ldr.w   r0, =0x1000F000                 @ 08023E60 r0 = 0x1000F000
    bl      dma_clear_it_pending_bit        @ 08023E64 call dma_clear_it_pending_bit
    movs    r1, #0                          @ 08023E68 r1 = 0
    ldr.w   r0, =(DMA2_BASE + DMA_CH4_CCR)  @ 08023E6A r0 = (DMA2_BASE + DMA_CH4_CCR)
    bl      dma_cmd                         @ 08023E6E call dma_cmd
    ldr.w   r0, =(SDIO_BASE + SDIO_FIFO)    @ 08023E72 r0 = (SDIO_BASE + SDIO_FIFO)
    str     r0, [sp]                        @ 08023E76 u32 [sp] = r0
    str     r4, [sp, #4]                    @ 08023E78 u32 [sp+0x4] = r4
    movs    r0, #0                          @ 08023E7A r0 = 0
    str     r0, [sp, #8]                    @ 08023E7C u32 [sp+0x8] = r0
    lsrs    r0, r5, #2                      @ 08023E7E r0 = r5 >> 2
    str     r0, [sp, #0xc]                  @ 08023E80 u32 [sp+0xC] = r0
    movs    r0, #0                          @ 08023E82 r0 = 0
    str     r0, [sp, #0x10]                 @ 08023E84 u32 [sp+0x10] = r0
    movs    r0, #0x80                       @ 08023E86 r0 = 0x80
    str     r0, [sp, #0x14]                 @ 08023E88 u32 [sp+0x14] = r0
    mov.w   r0, #0x200                      @ 08023E8A r0 = 0x200
    str     r0, [sp, #0x18]                 @ 08023E8E u32 [sp+0x18] = r0
    mov.w   r0, #0x800                      @ 08023E90 r0 = 0x800
    str     r0, [sp, #0x1c]                 @ 08023E94 u32 [sp+0x1C] = r0
    movs    r0, #0                          @ 08023E96 r0 = 0
    str     r0, [sp, #0x20]                 @ 08023E98 u32 [sp+0x20] = r0
    mov.w   r0, #0x2000                     @ 08023E9A r0 = 0x2000
    str     r0, [sp, #0x24]                 @ 08023E9E u32 [sp+0x24] = r0
    movs    r0, #0                          @ 08023EA0 r0 = 0
    str     r0, [sp, #0x28]                 @ 08023EA2 u32 [sp+0x28] = r0
    mov     r1, sp                          @ 08023EA4 r1 = sp
    ldr.w   r0, =(DMA2_BASE + DMA_CH4_CCR)  @ 08023EA6 r0 = (DMA2_BASE + DMA_CH4_CCR)
    bl      dma_init                        @ 08023EAA call dma_init
    movs    r2, #1                          @ 08023EAE r2 = 1
    movs    r1, #2                          @ 08023EB0 r1 = 2
    ldr.w   r0, =(DMA2_BASE + DMA_CH4_CCR)  @ 08023EB2 r0 = (DMA2_BASE + DMA_CH4_CCR)
    bl      dma_it_config                   @ 08023EB6 call dma_it_config
    movs    r1, #1                          @ 08023EBA r1 = 1
    ldr.w   r0, =(DMA2_BASE + DMA_CH4_CCR)  @ 08023EBC r0 = (DMA2_BASE + DMA_CH4_CCR)
    bl      dma_cmd                         @ 08023EC0 call dma_cmd
    add     sp, #0x2c                       @ 08023EC4 sp += 0x2c
    pop     {r4, r5, pc}                    @ 08023EC6 pop {r4, r5, pc}
ENDFUNC sd_dma_start_rx
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_reset - pulse the SDIO reset bit (APB2RSTR bit 11)
@ Replaces  : 0x08024074 FUN_08024074 (v2.05), called by sd_init
@ In        : -
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08024074..0x0802408B: fn_0801FFDA (RCC_APB2PeriphResetCmd) with (0x800, 1) then (0x800, 0)
@ -----------------------------------------------------------------------------
FUNC sdio_reset
    push    {r7, lr}                        @ 08024074 push {r7, lr}
    movs    r1, #1                          @ 08024076 r1 = 1
    mov.w   r0, #0x800                      @ 08024078 r0 = 0x800
    bl      fn_0801FFDA                     @ 0802407C call fn_0801FFDA
    movs    r1, #0                          @ 08024080 r1 = 0
    mov.w   r0, #0x800                      @ 08024082 r0 = 0x800
    bl      fn_0801FFDA                     @ 08024086 call fn_0801FFDA
    pop     {r0, pc}                        @ 0802408A pop {r0, pc}
ENDFUNC sdio_reset
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_init - configure the SDIO clock register (SDIO_Init)
@ Replaces  : 0x0802408C FUN_0802408C (v2.05), called by sd_init, sd_power_on, sd_set_bus_width
@ In        : r0 = pointer to the 6-word structure {ClockEdge, ClockBypass, ClockPowerSave, BusWide, HardwareFlowControl, ClockDiv (byte at +0x14)}
@ Out       : -
@ Clobbers  : r1-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802408C..0x080240B5
@ Note      : SDIO_CLKCR = (SDIO_CLKCR & 0xFFFF8100) | ClockDiv | ClockPowerSave | ClockBypass | BusWide | ClockEdge | HardwareFlowControl; the CLKEN bit 8 is kept.
@ -----------------------------------------------------------------------------
FUNC sdio_init
    movs    r1, #0                          @ 0802408C r1 = 0
    ldr     r2, =(SDIO_BASE + SDIO_CLKCR)   @ 0802408E r2 = (SDIO_BASE + SDIO_CLKCR)
    ldr     r2, [r2]                        @ 08024090 r2 = u32 [(SDIO_BASE + SDIO_CLKCR)]
    movs    r1, r2                          @ 08024092 r1 = r2
    ldr     r2, =0xFFFF8100                 @ 08024094 r2 = 0xFFFF8100
    ands    r1, r2                          @ 08024096 r1 &= r2
    ldrb    r2, [r0, #0x14]                 @ 08024098 r2 = u8 [r0+0x14]
    ldr     r3, [r0, #8]                    @ 0802409A r3 = u32 [r0+0x8]
    orrs    r2, r3                          @ 0802409C r2 |= r3
    ldr     r3, [r0, #4]                    @ 0802409E r3 = u32 [r0+0x4]
    orrs    r2, r3                          @ 080240A0 r2 |= r3
    ldr     r3, [r0, #0xc]                  @ 080240A2 r3 = u32 [r0+0xC]
    orrs    r2, r3                          @ 080240A4 r2 |= r3
    ldr     r3, [r0]                        @ 080240A6 r3 = u32 [r0]
    orrs    r2, r3                          @ 080240A8 r2 |= r3
    ldr     r3, [r0, #0x10]                 @ 080240AA r3 = u32 [r0+0x10]
    orrs    r2, r3                          @ 080240AC r2 |= r3
    orrs    r1, r2                          @ 080240AE r1 |= r2
    ldr     r2, =(SDIO_BASE + SDIO_CLKCR)   @ 080240B0 r2 = (SDIO_BASE + SDIO_CLKCR)
    str     r1, [r2]                        @ 080240B2 u32 [(SDIO_BASE + SDIO_CLKCR)] = r1
    bx      lr                              @ 080240B4 return
ENDFUNC sdio_init
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_clock_cmd - SDIO clock output on/off (SDIO_ClockCmd)
@ Replaces  : 0x080240B6 FUN_080240B6 (v2.05), called by sdio_gpio_deinit and sd_power_on
@ In        : r0 = 0 off, 1 on
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080240B6..0x080240BD: byte store to the bit-band alias of SDIO_CLKCR.CLKEN
@ -----------------------------------------------------------------------------
FUNC sdio_clock_cmd
    uxtb    r0, r0                          @ 080240B6 r0 = u8(r0)
    ldr     r1, =SD_CLKCR_CLKEN_BB          @ 080240B8 r1 = SD_CLKCR_CLKEN_BB
    str     r0, [r1]                        @ 080240BA u32 [SD_CLKCR_CLKEN_BB] = r0
    bx      lr                              @ 080240BC return
ENDFUNC sdio_clock_cmd
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_set_power_state - SDIO power state (SDIO_SetPowerState)
@ Replaces  : 0x080240BE FUN_080240BE (v2.05), called by sd_power_on and sd_power_off
@ In        : r0 = 0 power off, 3 power on
@ Out       : -
@ Clobbers  : r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080240BE..0x080240C3: SDIO_POWER = r0
@ -----------------------------------------------------------------------------
FUNC sdio_set_power_state
    ldr     r1, =(SDIO_BASE + SDIO_POWER)   @ 080240BE r1 = (SDIO_BASE + SDIO_POWER)
    str     r0, [r1]                        @ 080240C0 u32 [(SDIO_BASE + SDIO_POWER)] = r0
    bx      lr                              @ 080240C2 return
ENDFUNC sdio_set_power_state
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_get_power_state - SDIO power state read (SDIO_GetPowerState)
@ Replaces  : 0x080240C4 FUN_080240C4 (v2.05), called by sd_init_cards
@ In        : -
@ Out       : r0 = SDIO_POWER & 3
@ Clobbers  : r0, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080240C4..0x080240CD
@ -----------------------------------------------------------------------------
FUNC sdio_get_power_state
    ldr     r0, =(SDIO_BASE + SDIO_POWER)   @ 080240C4 r0 = (SDIO_BASE + SDIO_POWER)
    ldr     r0, [r0]                        @ 080240C6 r0 = u32 [(SDIO_BASE + SDIO_POWER)]
    ands    r0, r0, #3                      @ 080240C8 r0 = r0 & 3
    bx      lr                              @ 080240CC return
ENDFUNC sdio_get_power_state
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_dma_cmd - SDIO DMA enable (SDIO_DMACmd)
@ Replaces  : 0x080240CE FUN_080240CE (v2.05), called by sd_read_block and sd_write_blocks
@ In        : r0 = 0 off, 1 on
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080240CE..0x080240D5: byte store to the bit-band alias of SDIO_DCTRL.DMAEN
@ -----------------------------------------------------------------------------
FUNC sdio_dma_cmd
    uxtb    r0, r0                          @ 080240CE r0 = u8(r0)
    ldr     r1, =SD_DCTRL_DMAEN_BB          @ 080240D0 r1 = SD_DCTRL_DMAEN_BB
    str     r0, [r1]                        @ 080240D2 u32 [SD_DCTRL_DMAEN_BB] = r0
    bx      lr                              @ 080240D4 return
ENDFUNC sdio_dma_cmd
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_send_command - send a command (SDIO_SendCommand)
@ Replaces  : 0x080240D6 FUN_080240D6 (v2.05), called by every command of sdcard.s
@ In        : r0 = pointer to {Argument, CmdIndex, Response, WaitForInt, CPSM}
@ Out       : -
@ Clobbers  : r1-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080240D6..0x080240FD
@ Note      : SDIO_ARG = Argument; SDIO_CMD = (SDIO_CMD & 0xFFFFF800) | CmdIndex | Response | WaitForInt | CPSM.  CPSM 0x400 enables the command path.
@ -----------------------------------------------------------------------------
FUNC sdio_send_command
    movs    r1, #0                          @ 080240D6 r1 = 0
    ldr     r2, [r0]                        @ 080240D8 r2 = u32 [r0]
    ldr     r3, =(SDIO_BASE + SDIO_ARG)     @ 080240DA r3 = (SDIO_BASE + SDIO_ARG)
    str     r2, [r3]                        @ 080240DC u32 [(SDIO_BASE + SDIO_ARG)] = r2
    ldr     r2, =(SDIO_BASE + SDIO_CMD)     @ 080240DE r2 = (SDIO_BASE + SDIO_CMD)
    ldr     r2, [r2]                        @ 080240E0 r2 = u32 [(SDIO_BASE + SDIO_CMD)]
    movs    r1, r2                          @ 080240E2 r1 = r2
    lsrs    r1, r1, #0xb                    @ 080240E4 r1 = r1 >> 0xb
    lsls    r1, r1, #0xb                    @ 080240E6 r1 = r1 << 0xb
    ldr     r2, [r0, #4]                    @ 080240E8 r2 = u32 [r0+0x4]
    ldr     r3, [r0, #8]                    @ 080240EA r3 = u32 [r0+0x8]
    orrs    r2, r3                          @ 080240EC r2 |= r3
    ldr     r3, [r0, #0xc]                  @ 080240EE r3 = u32 [r0+0xC]
    orrs    r2, r3                          @ 080240F0 r2 |= r3
    ldr     r3, [r0, #0x10]                 @ 080240F2 r3 = u32 [r0+0x10]
    orrs    r2, r3                          @ 080240F4 r2 |= r3
    orrs    r1, r2                          @ 080240F6 r1 |= r2
    ldr     r2, =(SDIO_BASE + SDIO_CMD)     @ 080240F8 r2 = (SDIO_BASE + SDIO_CMD)
    str     r1, [r2]                        @ 080240FA u32 [(SDIO_BASE + SDIO_CMD)] = r1
    bx      lr                              @ 080240FC return
ENDFUNC sdio_send_command
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_get_command_response - index of the last command answer (SDIO_GetCommandResponse)
@ Replaces  : 0x080240FE FUN_080240FE (v2.05), called by sd_cmd_resp1_error and sd_cmd_resp6_error
@ In        : -
@ Out       : r0 = SDIO_RESPCMD & 0xFF
@ Clobbers  : r0, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080240FE..0x08024105
@ -----------------------------------------------------------------------------
FUNC sdio_get_command_response
    ldr     r0, =(SDIO_BASE + SDIO_RESPCMD) @ 080240FE r0 = (SDIO_BASE + SDIO_RESPCMD)
    ldr     r0, [r0]                        @ 08024100 r0 = u32 [(SDIO_BASE + SDIO_RESPCMD)]
    uxtb    r0, r0                          @ 08024102 r0 = u8(r0)
    bx      lr                              @ 08024104 return
ENDFUNC sdio_get_command_response
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_get_response - answer word (SDIO_GetResponse)
@ Replaces  : 0x08024106 FUN_08024106 (v2.05), called by sd_power_on, sd_init_cards, sd_enable_wide_bus, sd_send_status and the answer checks
@ In        : r0 = byte offset from SDIO_RESP1 (0, 4, 8, 0xC)
@ Out       : r0 = the word at SDIO_RESP1 + r0
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08024106..0x0802411B
@ -----------------------------------------------------------------------------
FUNC sdio_get_response
    sub     sp, #4                          @ 08024106 sp -= 4
    movs    r1, r0                          @ 08024108 r1 = r0
    movs    r0, #0                          @ 0802410A r0 = 0
    str     r0, [sp]                        @ 0802410C u32 [sp] = r0
    ldr     r0, =(SDIO_BASE + SDIO_RESP1)   @ 0802410E r0 = (SDIO_BASE + SDIO_RESP1)
    adds    r0, r0, r1                      @ 08024110 r0 = r0 + r1
    str     r0, [sp]                        @ 08024112 u32 [sp] = r0
    ldr     r0, [sp]                        @ 08024114 r0 = u32 [sp]
    ldr     r0, [r0]                        @ 08024116 r0 = u32 [r0]
    add     sp, #4                          @ 08024118 sp += 4
    bx      lr                              @ 0802411A return
ENDFUNC sdio_get_response
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_data_config - configure the data path (SDIO_DataConfig)
@ Replaces  : 0x0802411C FUN_0802411C (v2.05), called by sd_read_block, sd_write_blocks, sd_find_scr
@ In        : r0 = pointer to {DataTimeOut, DataLength, DataBlockSize, TransferDir, TransferMode, DPSM}
@ Out       : -
@ Clobbers  : r1-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802411C..0x08024149
@ Note      : SDIO_DTIMER = DataTimeOut; SDIO_DLEN = DataLength; SDIO_DCTRL = (SDIO_DCTRL & 0xFFFFFF08) | DataBlockSize | TransferDir | TransferMode | DPSM.
@ -----------------------------------------------------------------------------
FUNC sdio_data_config
    movs    r1, #0                          @ 0802411C r1 = 0
    ldr     r2, [r0]                        @ 0802411E r2 = u32 [r0]
    ldr     r3, =(SDIO_BASE + SDIO_DTIMER)  @ 08024120 r3 = (SDIO_BASE + SDIO_DTIMER)
    str     r2, [r3]                        @ 08024122 u32 [(SDIO_BASE + SDIO_DTIMER)] = r2
    ldr     r2, [r0, #4]                    @ 08024124 r2 = u32 [r0+0x4]
    ldr     r3, =(SDIO_BASE + SDIO_DLEN)    @ 08024126 r3 = (SDIO_BASE + SDIO_DLEN)
    str     r2, [r3]                        @ 08024128 u32 [(SDIO_BASE + SDIO_DLEN)] = r2
    ldr     r2, =(SDIO_BASE + SDIO_DCTRL)   @ 0802412A r2 = (SDIO_BASE + SDIO_DCTRL)
    ldr     r2, [r2]                        @ 0802412C r2 = u32 [(SDIO_BASE + SDIO_DCTRL)]
    movs    r1, r2                          @ 0802412E r1 = r2
    bics    r1, r1, #0xf7                   @ 08024130 r1 = r1 & ~ 0xf7
    ldr     r2, [r0, #8]                    @ 08024134 r2 = u32 [r0+0x8]
    ldr     r3, [r0, #0xc]                  @ 08024136 r3 = u32 [r0+0xC]
    orrs    r2, r3                          @ 08024138 r2 |= r3
    ldr     r3, [r0, #0x10]                 @ 0802413A r3 = u32 [r0+0x10]
    orrs    r2, r3                          @ 0802413C r2 |= r3
    ldr     r3, [r0, #0x14]                 @ 0802413E r3 = u32 [r0+0x14]
    orrs    r2, r3                          @ 08024140 r2 |= r3
    orrs    r1, r2                          @ 08024142 r1 |= r2
    ldr     r2, =(SDIO_BASE + SDIO_DCTRL)   @ 08024144 r2 = (SDIO_BASE + SDIO_DCTRL)
    str     r1, [r2]                        @ 08024146 u32 [(SDIO_BASE + SDIO_DCTRL)] = r1
    bx      lr                              @ 08024148 return
ENDFUNC sdio_data_config
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_read_data - read one word from the data FIFO (SDIO_ReadData)
@ Replaces  : 0x0802414A FUN_0802414A (v2.05), called by sd_find_scr
@ In        : -
@ Out       : r0 = word at SDIO_FIFO (0x40012C80)
@ Clobbers  : r0, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802414A..0x0802414F
@ -----------------------------------------------------------------------------
FUNC sdio_read_data
    ldr     r0, =(SDIO_BASE + SDIO_FIFO)    @ 0802414A r0 = (SDIO_BASE + SDIO_FIFO)
    ldr     r0, [r0]                        @ 0802414C r0 = u32 [(SDIO_BASE + SDIO_FIFO)]
    bx      lr                              @ 0802414E return
ENDFUNC sdio_read_data
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_it_config - enable or disable SDIO interrupt sources (SDIO_ITConfig)
@ Replaces  : 0x08024150 FUN_08024150 (v2.05), called by sd_read_block, sd_write_blocks and sd_sdio_isr_body
@ In        : r0 = mask of SDIO_MASK bits, r1 = 0 clear the bits, else set them
@ Out       : -
@ Clobbers  : r1-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main and ISR
@ Spec      : v2.05 listing 0x08024150..0x0802416D
@ -----------------------------------------------------------------------------
FUNC sdio_it_config
    uxtb    r1, r1                          @ 08024150 r1 = u8(r1)
    cmp     r1, #0                          @ 08024152 compare r1 with 0
    beq     .Lsdio_it_config_4162           @ 08024154 if (r1 == 0) goto 0x8024162
    ldr     r2, =(SDIO_BASE + SDIO_MASK)    @ 08024156 r2 = (SDIO_BASE + SDIO_MASK)
    ldr     r2, [r2]                        @ 08024158 r2 = u32 [(SDIO_BASE + SDIO_MASK)]
    orrs    r2, r0                          @ 0802415A r2 |= r0
    ldr     r3, =(SDIO_BASE + SDIO_MASK)    @ 0802415C r3 = (SDIO_BASE + SDIO_MASK)
    str     r2, [r3]                        @ 0802415E u32 [(SDIO_BASE + SDIO_MASK)] = r2
    b       .Lsdio_it_config_416C           @ 08024160 goto 0x802416C
.Lsdio_it_config_4162:                  @ v2.05 0x08024162, reached from 0x08024154
    ldr     r2, =(SDIO_BASE + SDIO_MASK)    @ 08024162 r2 = (SDIO_BASE + SDIO_MASK)
    ldr     r2, [r2]                        @ 08024164 r2 = u32 [(SDIO_BASE + SDIO_MASK)]
    bics    r2, r0                          @ 08024166 r2 & ~= r0
    ldr     r3, =(SDIO_BASE + SDIO_MASK)    @ 08024168 r3 = (SDIO_BASE + SDIO_MASK)
    str     r2, [r3]                        @ 0802416A u32 [(SDIO_BASE + SDIO_MASK)] = r2
.Lsdio_it_config_416C:                  @ v2.05 0x0802416C, reached from 0x08024160
    bx      lr                              @ 0802416C return
ENDFUNC sdio_it_config
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_get_flag_status - test status flags (SDIO_GetFlagStatus)
@ Replaces  : 0x0802416E FUN_0802416E (v2.05), called by sd_cmd_error and sd_find_scr
@ In        : r0 = mask of SDIO_STA bits
@ Out       : r0 = 1 when any bit of the mask is set in SDIO_STA, else 0
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802416E..0x08024187
@ -----------------------------------------------------------------------------
FUNC sdio_get_flag_status
    movs    r1, r0                          @ 0802416E r1 = r0
    movs    r0, #0                          @ 08024170 r0 = 0
    ldr     r2, =(SDIO_BASE + SDIO_STA)     @ 08024172 r2 = (SDIO_BASE + SDIO_STA)
    ldr     r2, [r2]                        @ 08024174 r2 = u32 [(SDIO_BASE + SDIO_STA)]
    tst     r2, r1                          @ 08024176 compare r2 with r1
    beq     .Lsdio_get_flag_status_4180     @ 08024178 if ((r2 & r1) == 0) goto 0x8024180
    movs    r2, #1                          @ 0802417A r2 = 1
    movs    r0, r2                          @ 0802417C r0 = r2
    b       .Lsdio_get_flag_status_4184     @ 0802417E goto 0x8024184
.Lsdio_get_flag_status_4180:            @ v2.05 0x08024180, reached from 0x08024178
    movs    r2, #0                          @ 08024180 r2 = 0
    movs    r0, r2                          @ 08024182 r0 = r2
.Lsdio_get_flag_status_4184:            @ v2.05 0x08024184, reached from 0x0802417E
    uxtb    r0, r0                          @ 08024184 r0 = u8(r0)
    bx      lr                              @ 08024186 return
ENDFUNC sdio_get_flag_status
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_clear_flag - clear static status flags (SDIO_ClearFlag)
@ Replaces  : 0x08024188 FUN_08024188 (v2.05), called by the answer and wait routines of sdcard.s
@ In        : r0 = mask for SDIO_ICR
@ Out       : -
@ Clobbers  : r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x08024188..0x0802418D
@ -----------------------------------------------------------------------------
FUNC sdio_clear_flag
    ldr     r1, =(SDIO_BASE + SDIO_ICR)     @ 08024188 r1 = (SDIO_BASE + SDIO_ICR)
    str     r0, [r1]                        @ 0802418A u32 [(SDIO_BASE + SDIO_ICR)] = r0
    bx      lr                              @ 0802418C return
ENDFUNC sdio_clear_flag
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_get_it_status - test interrupt flags (SDIO_GetITStatus)
@ Replaces  : 0x0802418E FUN_0802418E (v2.05), called by sd_sdio_isr_body
@ In        : r0 = mask of SDIO_STA bits
@ Out       : r0 = 1 when any bit of the mask is set in SDIO_STA, else 0
@ Clobbers  : r0-r2, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : ISR
@ Spec      : v2.05 listing 0x0802418E..0x080241A7 (the same code as sdio_get_flag_status)
@ -----------------------------------------------------------------------------
FUNC sdio_get_it_status
    movs    r1, r0                          @ 0802418E r1 = r0
    movs    r0, #0                          @ 08024190 r0 = 0
    ldr     r2, =(SDIO_BASE + SDIO_STA)     @ 08024192 r2 = (SDIO_BASE + SDIO_STA)
    ldr     r2, [r2]                        @ 08024194 r2 = u32 [(SDIO_BASE + SDIO_STA)]
    tst     r2, r1                          @ 08024196 compare r2 with r1
    beq     .Lsdio_get_it_status_41A0       @ 08024198 if ((r2 & r1) == 0) goto 0x80241A0
    movs    r2, #1                          @ 0802419A r2 = 1
    movs    r0, r2                          @ 0802419C r0 = r2
    b       .Lsdio_get_it_status_41A4       @ 0802419E goto 0x80241A4
.Lsdio_get_it_status_41A0:              @ v2.05 0x080241A0, reached from 0x08024198
    movs    r2, #0                          @ 080241A0 r2 = 0
    movs    r0, r2                          @ 080241A2 r0 = r2
.Lsdio_get_it_status_41A4:              @ v2.05 0x080241A4, reached from 0x0802419E
    uxtb    r0, r0                          @ 080241A4 r0 = u8(r0)
    bx      lr                              @ 080241A6 return
ENDFUNC sdio_get_it_status
    .ltorg

@ -----------------------------------------------------------------------------
@ sdio_clear_it_pending_bit - clear interrupt flags (SDIO_ClearITPendingBit)
@ Replaces  : 0x080241A8 FUN_080241A8 (v2.05), called by sd_sdio_isr_body
@ In        : r0 = mask for SDIO_ICR
@ Out       : -
@ Clobbers  : r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : ISR
@ Spec      : v2.05 listing 0x080241A8..0x080241AD (the same code as sdio_clear_flag)
@ -----------------------------------------------------------------------------
FUNC sdio_clear_it_pending_bit
    ldr     r1, =(SDIO_BASE + SDIO_ICR)     @ 080241A8 r1 = (SDIO_BASE + SDIO_ICR)
    str     r0, [r1]                        @ 080241AA u32 [(SDIO_BASE + SDIO_ICR)] = r0
    bx      lr                              @ 080241AC return
ENDFUNC sdio_clear_it_pending_bit
    .ltorg

@ -----------------------------------------------------------------------------
@ dma_init - configure a DMA channel (DMA_Init)
@ Replaces  : 0x080241F0 FUN_080241F0 (v2.05), called by sd_dma_start_tx and sd_dma_start_rx
@ In        : r0 = channel register block, r1 = pointer to the structure {PeripheralBaseAddr, MemoryBaseAddr, DIR, BufferSize, PeripheralInc, MemoryInc, PeripheralDataSize, MemoryDataSize, Mode, Priority, M2M}
@ Out       : -
@ Clobbers  : r2-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x080241F0..0x0802422D
@ Note      : CCR = (CCR & 0xFFFF800F) | DIR | Mode | PeripheralInc | MemoryInc | PeripheralDataSize | MemoryDataSize | Priority | M2M;
@             CNDTR = BufferSize; CPAR = PeripheralBaseAddr; CMAR = MemoryBaseAddr.
@ -----------------------------------------------------------------------------
FUNC dma_init
    push    {r4}                            @ 080241F0 push {r4}
    movs    r2, #0                          @ 080241F2 r2 = 0
    ldr     r3, [r0]                        @ 080241F4 r3 = u32 [r0]
    movs    r2, r3                          @ 080241F6 r2 = r3
    bfc     r2, #4, #0xb                    @ 080241F8
    ldr     r3, [r1, #8]                    @ 080241FC r3 = u32 [r1+0x8]
    ldr     r4, [r1, #0x20]                 @ 080241FE r4 = u32 [r1+0x20]
    orrs    r3, r4                          @ 08024200 r3 |= r4
    ldr     r4, [r1, #0x10]                 @ 08024202 r4 = u32 [r1+0x10]
    orrs    r3, r4                          @ 08024204 r3 |= r4
    ldr     r4, [r1, #0x14]                 @ 08024206 r4 = u32 [r1+0x14]
    orrs    r3, r4                          @ 08024208 r3 |= r4
    ldr     r4, [r1, #0x18]                 @ 0802420A r4 = u32 [r1+0x18]
    orrs    r3, r4                          @ 0802420C r3 |= r4
    ldr     r4, [r1, #0x1c]                 @ 0802420E r4 = u32 [r1+0x1C]
    orrs    r3, r4                          @ 08024210 r3 |= r4
    ldr     r4, [r1, #0x24]                 @ 08024212 r4 = u32 [r1+0x24]
    orrs    r3, r4                          @ 08024214 r3 |= r4
    ldr     r4, [r1, #0x28]                 @ 08024216 r4 = u32 [r1+0x28]
    orrs    r3, r4                          @ 08024218 r3 |= r4
    orrs    r2, r3                          @ 0802421A r2 |= r3
    str     r2, [r0]                        @ 0802421C u32 [r0] = r2
    ldr     r3, [r1, #0xc]                  @ 0802421E r3 = u32 [r1+0xC]
    str     r3, [r0, #4]                    @ 08024220 u32 [r0+0x4] = r3
    ldr     r3, [r1]                        @ 08024222 r3 = u32 [r1]
    str     r3, [r0, #8]                    @ 08024224 u32 [r0+0x8] = r3
    ldr     r3, [r1, #4]                    @ 08024226 r3 = u32 [r1+0x4]
    str     r3, [r0, #0xc]                  @ 08024228 u32 [r0+0xC] = r3
    pop     {r4}                            @ 0802422A pop {r4}
    bx      lr                              @ 0802422C return
ENDFUNC dma_init
    .ltorg

@ -----------------------------------------------------------------------------
@ dma_cmd - enable or disable a DMA channel (DMA_Cmd)
@ Replaces  : 0x0802422E FUN_0802422E (v2.05), called by sd_dma_start_tx and sd_dma_start_rx
@ In        : r0 = channel register block, r1 = 0 disable, else enable
@ Out       : -
@ Clobbers  : r1-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802422E..0x08024249: CCR bit 0 (EN)
@ -----------------------------------------------------------------------------
FUNC dma_cmd
    uxtb    r1, r1                          @ 0802422E r1 = u8(r1)
    cmp     r1, #0                          @ 08024230 compare r1 with 0
    beq     .Ldma_cmd_423E                  @ 08024232 if (r1 == 0) goto 0x802423E
    ldr     r2, [r0]                        @ 08024234 r2 = u32 [r0]
    orrs    r2, r2, #1                      @ 08024236 r2 = r2 | 1
    str     r2, [r0]                        @ 0802423A u32 [r0] = r2
    b       .Ldma_cmd_4248                  @ 0802423C goto 0x8024248
.Ldma_cmd_423E:                         @ v2.05 0x0802423E, reached from 0x08024232
    ldr     r2, [r0]                        @ 0802423E r2 = u32 [r0]
    movw    r3, #0xfffe                     @ 08024240
    ands    r2, r3                          @ 08024244 r2 &= r3
    str     r2, [r0]                        @ 08024246 u32 [r0] = r2
.Ldma_cmd_4248:                         @ v2.05 0x08024248, reached from 0x0802423C
    bx      lr                              @ 08024248 return
ENDFUNC dma_cmd
    .ltorg

@ -----------------------------------------------------------------------------
@ dma_it_config - enable or disable DMA channel interrupt sources (DMA_ITConfig)
@ Replaces  : 0x0802424A FUN_0802424A (v2.05), called by sd_dma_start_tx and sd_dma_start_rx
@ In        : r0 = channel register block, r1 = CCR interrupt bits (2 = transfer complete), r2 = 0 disable, else enable
@ Out       : -
@ Clobbers  : r2-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : main only
@ Spec      : v2.05 listing 0x0802424A..0x0802425F
@ -----------------------------------------------------------------------------
FUNC dma_it_config
    uxtb    r2, r2                          @ 0802424A r2 = u8(r2)
    cmp     r2, #0                          @ 0802424C compare r2 with 0
    beq     .Ldma_it_config_4258            @ 0802424E if (r2 == 0) goto 0x8024258
    ldr     r3, [r0]                        @ 08024250 r3 = u32 [r0]
    orrs    r3, r1                          @ 08024252 r3 |= r1
    str     r3, [r0]                        @ 08024254 u32 [r0] = r3
    b       .Ldma_it_config_425E            @ 08024256 goto 0x802425E
.Ldma_it_config_4258:                   @ v2.05 0x08024258, reached from 0x0802424E
    ldr     r3, [r0]                        @ 08024258 r3 = u32 [r0]
    bics    r3, r1                          @ 0802425A r3 & ~= r1
    str     r3, [r0]                        @ 0802425C u32 [r0] = r3
.Ldma_it_config_425E:                   @ v2.05 0x0802425E, reached from 0x08024256
    bx      lr                              @ 0802425E return
ENDFUNC dma_it_config
    .ltorg

@ -----------------------------------------------------------------------------
@ dma_clear_it_pending_bit - clear DMA interrupt flags (DMA_ClearITPendingBit)
@ Replaces  : 0x08024260 FUN_08024260 (v2.05), called by sd_dma_isr_body and the DMA start routines
@ In        : r0 = flag word of the library; bit 28 selects DMA2, otherwise DMA1
@ Out       : -
@ Clobbers  : r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : ISR and main
@ Spec      : v2.05 listing 0x08024260..0x0802426F: the flag word is written to DMA2_IFCR (0x40026404) when bit 28 is set, else to DMA1_IFCR (0x40026004)
@ -----------------------------------------------------------------------------
FUNC dma_clear_it_pending_bit
    lsls    r1, r0, #3                      @ 08024260 r1 = r0 << 3
    bmi     .Ldma_clear_it_pending_bit_426A @ 08024262 if (r1 <0 0) goto 0x802426A
    ldr     r1, =(DMA1_BASE + DMA_IFCR)     @ 08024264 r1 = (DMA1_BASE + DMA_IFCR)
    str     r0, [r1]                        @ 08024266 u32 [(DMA1_BASE + DMA_IFCR)] = r0
    b       .Ldma_clear_it_pending_bit_426E @ 08024268 goto 0x802426E
.Ldma_clear_it_pending_bit_426A:        @ v2.05 0x0802426A, reached from 0x08024262
    ldr     r1, =(DMA2_BASE + DMA_IFCR)     @ 0802426A r1 = (DMA2_BASE + DMA_IFCR)
    str     r0, [r1]                        @ 0802426C u32 [(DMA2_BASE + DMA_IFCR)] = r0
.Ldma_clear_it_pending_bit_426E:        @ v2.05 0x0802426E, reached from 0x08024268
    bx      lr                              @ 0802426E return
ENDFUNC dma_clear_it_pending_bit
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_sdio_isr - IRQ45 vector entry (v2.05 handler thunk)
@ Replaces  : 0x080248B8 IRQ45_Handler (v2.05); canonical name sd_sdio_isr (DESIGN.md Appendix C.2)
@ In        : -
@ Out       : -
@ Clobbers  : r0-r3, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : ISR (IRQ45, priority 0)
@ Spec      : v2.05 listing 0x080248B8..0x080248BF: calls sd_sdio_isr_body (push {r7, lr} keeps the stack 8-byte aligned)
@ -----------------------------------------------------------------------------
FUNC sd_sdio_isr
    push    {r7, lr}                        @ 080248B8 push {r7, lr}
    bl      sd_sdio_isr_body                @ 080248BA call sd_sdio_isr_body
    pop     {r0, pc}                        @ 080248BE pop {r0, pc}
ENDFUNC sd_sdio_isr
    .ltorg

@ -----------------------------------------------------------------------------
@ sd_dma_isr - IRQ53 vector entry (v2.05 handler thunk)
@ Replaces  : 0x080248C0 IRQ53_Handler (v2.05); canonical name sd_dma_isr (DESIGN.md Appendix C.2)
@ In        : -
@ Out       : -
@ Clobbers  : r0-r1, flags (v2.05 regeffects.txt; r4-r11 preserved)
@ Context   : ISR (IRQ53, priority 0)
@ Spec      : v2.05 listing 0x080248C0..0x080248C7: calls sd_dma_isr_body
@ -----------------------------------------------------------------------------
FUNC sd_dma_isr
    push    {r7, lr}                        @ 080248C0 push {r7, lr}
    bl      sd_dma_isr_body                 @ 080248C2 call sd_dma_isr_body
    pop     {r0, pc}                        @ 080248C6 pop {r0, pc}
ENDFUNC sd_dma_isr
    .ltorg

