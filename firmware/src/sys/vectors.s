@ =============================================================================
@ vectors.s - SYS: vector table at 0x08006000 and the empty system handlers
@
@ 73 words: 16 system vectors and the 57 IRQ vectors of the RM0038 Cat.4 table (RM0038 10.1.2 Table 51), the
@ same count as v2.05 (vector table 0x08006000..0x08006123).  Word 0 = 0x20001240 (passes the bootloader test
@ (SP & 0x2FFE0000) == 0x20000000 at bootloader 0x08004994), word 1 = sys_reset with bit 0 set (DESIGN.md 2.1,
@ 2.2).  Handler assignment: DESIGN.md 3.4.  Every vector v2.05 points at a `b .` loop (HardFault, MemManage,
@ BusFault, UsageFault 0x0802427E..0x08024284 and the unused IRQs 0x08029298..0x08029340) goes to
@ sys_fault_safe (NF-14).  Reserved words 7..10 and 13 are 0 as in v2.05.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"

    .section .vectors, "a", %progbits
    .global sys_vector_table
sys_vector_table:
    .word __stack_top                       @  0 initial MSP = 0x20001240 (asserted in link/121gw.ld)
    .word sys_reset                         @  1 Reset (Thumb bit set by the linker)
    .word sys_null_isr                      @  2 NMI          v2.05 0x0802427C bx lr
    .word sys_fault_safe                    @  3 HardFault    v2.05 0x0802427E b .
    .word sys_fault_safe                    @  4 MemManage    v2.05 0x08024280 b .
    .word sys_fault_safe                    @  5 BusFault     v2.05 0x08024282 b .
    .word sys_fault_safe                    @  6 UsageFault   v2.05 0x08024284 b .
    .word 0                                 @  7 reserved
    .word 0                                 @  8 reserved
    .word 0                                 @  9 reserved
    .word 0                                 @ 10 reserved
    .word sys_null_isr                      @ 11 SVCall       v2.05 0x08024286 bx lr
    .word sys_null_isr                      @ 12 DebugMonitor v2.05 0x08024288 bx lr
    .word 0                                 @ 13 reserved
    .word sys_null_isr                      @ 14 PendSV       v2.05 0x0802428A bx lr
    .word sys_systick_isr                   @ 15 SysTick      v2.05 0x080248B0
    @ IRQ 0..56 (exception 16..72)
    .word sys_fault_safe                    @ IRQ  0 WWDG           v2.05 0x08029298 b .
    .word sys_fault_safe                    @ IRQ  1 PVD            v2.05 0x0802929C b .
    .word sys_fault_safe                    @ IRQ  2 TAMPER_STAMP   v2.05 0x080292A0 b .
    .word brd_rtcwkup_isr                   @ IRQ  3 RTC_WKUP       v2.05 0x080248C8 (never enabled)
    .word sys_fault_safe                    @ IRQ  4 FLASH          v2.05 0x080292A4 b .
    .word sys_fault_safe                    @ IRQ  5 RCC            v2.05 0x080292A8 b .
    .word brd_exti_isr                      @ IRQ  6 EXTI0          v2.05 0x080248E8
    .word brd_exti_isr                      @ IRQ  7 EXTI1          v2.05 0x080248FC
    .word brd_exti_isr                      @ IRQ  8 EXTI2          v2.05 0x08024910
    .word brd_exti_isr                      @ IRQ  9 EXTI3          v2.05 0x08024924
    .word brd_exti_isr                      @ IRQ 10 EXTI4          v2.05 0x08024938
    .word sys_fault_safe                    @ IRQ 11 DMA1_CH1       v2.05 0x080292AC b .
    .word sys_fault_safe                    @ IRQ 12 DMA1_CH2       v2.05 0x080292B0 b .
    .word sys_fault_safe                    @ IRQ 13 DMA1_CH3       v2.05 0x080292B4 b .
    .word sys_fault_safe                    @ IRQ 14 DMA1_CH4       v2.05 0x080292B8 b .
    .word sys_fault_safe                    @ IRQ 15 DMA1_CH5       v2.05 0x080292BC b .
    .word sys_fault_safe                    @ IRQ 16 DMA1_CH6       v2.05 0x080292C0 b .
    .word sys_fault_safe                    @ IRQ 17 DMA1_CH7       v2.05 0x080292C4 b .
    .word brd_adc_isr                       @ IRQ 18 ADC1           v2.05 0x08024A24 (never enabled)
    .word sys_fault_safe                    @ IRQ 19 USB_HP         v2.05 0x080292C8 b .
    .word sys_fault_safe                    @ IRQ 20 USB_LP         v2.05 0x080292CC b .
    .word sys_fault_safe                    @ IRQ 21 DAC            v2.05 0x080292D0 b .
    .word sys_fault_safe                    @ IRQ 22 COMP/CA        v2.05 0x080292D4 b .
    .word brd_exti_isr                      @ IRQ 23 EXTI9_5        v2.05 0x0802494C
    .word sys_fault_safe                    @ IRQ 24 LCD            v2.05 0x080292D8 b .
    .word sys_fault_safe                    @ IRQ 25 TIM9           v2.05 0x080292DC b .
    .word sys_fault_safe                    @ IRQ 26 TIM10          v2.05 0x080292E0 b .
    .word sys_fault_safe                    @ IRQ 27 TIM11          v2.05 0x080292E4 b .
    .word sys_tim2_isr                      @ IRQ 28 TIM2           v2.05 0x0802428C
    .word bzb_tim3_isr                      @ IRQ 29 TIM3           v2.05 0x08024722
    .word sys_fault_safe                    @ IRQ 30 TIM4           v2.05 0x080292E8 b .
    .word sys_fault_safe                    @ IRQ 31 I2C1_EV        v2.05 0x080292EC b .
    .word sys_fault_safe                    @ IRQ 32 I2C1_ER        v2.05 0x080292F0 b .
    .word sys_fault_safe                    @ IRQ 33 I2C2_EV        v2.05 0x080292F4 b .
    .word sys_fault_safe                    @ IRQ 34 I2C2_ER        v2.05 0x080292F8 b .
    .word sys_fault_safe                    @ IRQ 35 SPI1           v2.05 0x080292FC b .
    .word sys_fault_safe                    @ IRQ 36 SPI2           v2.05 0x08029300 b .
    .word sys_fault_safe                    @ IRQ 37 USART1         v2.05 0x08029304 b .
    .word ble_usart2_isr                    @ IRQ 38 USART2         v2.05 0x080247D8
    .word sys_fault_safe                    @ IRQ 39 USART3         v2.05 0x08029308 b .
    .word brd_exti_isr                      @ IRQ 40 EXTI15_10      v2.05 0x080249A8
    .word sys_fault_safe                    @ IRQ 41 RTC_Alarm      v2.05 0x0802930C b .
    .word sys_fault_safe                    @ IRQ 42 USB_FS_WKUP    v2.05 0x08029310 b .
    .word sys_fault_safe                    @ IRQ 43 TIM6           v2.05 0x08029314 b .
    .word sys_fault_safe                    @ IRQ 44 TIM7           v2.05 0x08029318 b .
    .word sd_sdio_isr                       @ IRQ 45 SDIO           v2.05 0x080248B8
    .word sys_fault_safe                    @ IRQ 46 TIM5           v2.05 0x0802931C b .
    .word sys_fault_safe                    @ IRQ 47 SPI3           v2.05 0x08029320 b .
    .word sys_fault_safe                    @ IRQ 48 UART4          v2.05 0x08029324 b .
    .word sys_fault_safe                    @ IRQ 49 UART5          v2.05 0x08029328 b .
    .word sys_fault_safe                    @ IRQ 50 DMA2_CH1       v2.05 0x0802932C b .
    .word sys_fault_safe                    @ IRQ 51 DMA2_CH2       v2.05 0x08029330 b .
    .word sys_fault_safe                    @ IRQ 52 DMA2_CH3       v2.05 0x08029334 b .
    .word sd_dma_isr                        @ IRQ 53 DMA2_CH4       v2.05 0x080248C0
    .word sys_fault_safe                    @ IRQ 54 DMA2_CH5       v2.05 0x08029338 b .
    .word sys_fault_safe                    @ IRQ 55 AES            v2.05 0x0802933C b .
    .word sys_fault_safe                    @ IRQ 56 COMP_ACQ       v2.05 0x08029340 b .
    .size sys_vector_table, . - sys_vector_table

    .section .text.sys.vectors, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sys_null_isr - handler that returns at once
@ Replaces : 0x0802427C NMI_Handler, 0x08024286 SVC_Handler, 0x08024288 DebugMon_Handler, 0x0802428A
@            PendSV_Handler (v2.05, each a single bx lr)
@ In/Out   : - / -
@ Clobbers : none
@ Context  : exception
@ -----------------------------------------------------------------------------
FUNC sys_null_isr
    bx lr
ENDFUNC sys_null_isr
