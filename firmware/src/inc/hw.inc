@ =============================================================================
@ hw.inc - STM32L152ZD register addresses and bit names used by the firmware
@
@ Sources: RM0038 rev 15 (inputs/docs, text cited by section number), PM0056 for the Cortex-M3 core
@ registers.  Names follow the manuals.  Every address below is also the literal the v2.05 image uses where
@ v2.05 touches the register (analysis/decompile/mmio_refs.txt), unless noted.
@
@ Deliberately NOT defined here (never-brick rule, DESIGN.md 1, 4.6, 9.3 item 2): FLASH_PRGKEYR (0x40023C10),
@ FLASH_OPTKEYR (0x40023C14), FLASH_OBR (0x40023C1C), FLASH_WRPRx (0x40023C20..), the option-byte area
@ 0x1FF80000, and every FLASH key value.  The data-EEPROM key values (PEKEY1/PEKEY2) and the EEPROM base live
@ only in the NVM objects (DESIGN.md 6.21).
@ =============================================================================

    .ifndef HW_INC
    .equ HW_INC, 1

@ -----------------------------------------------------------------------------
@ Bit-band alias of a peripheral register bit (RM0038 2.3, PM0056 2.2.5):
@ alias = 0x42000000 + (byte address - 0x40000000) * 32 + bit * 4, bit counted inside that byte.
@ Use: .equ NAME, BB_PERIPH(register byte address, bit 0..7)
@ -----------------------------------------------------------------------------
    .equ PERIPH_BASE,         0x40000000
    .equ PERIPH_BB_BASE,      0x42000000
    .macro BB_EQU name, byteaddr, bit
    .equ \name, PERIPH_BB_BASE + ((\byteaddr) - PERIPH_BASE) * 32 + (\bit) * 4
    .endm

@ -----------------------------------------------------------------------------
@ Memory map (RM0038 2.3 Table 5; DESIGN.md 2.3)
@ -----------------------------------------------------------------------------
    .equ FLASH_PROG_BASE,     0x08000000      @ program flash (never written by this firmware)
    .equ APP_BASE,            0x08006000      @ application load address (bootloader contract, DESIGN.md 2.1)
    .equ APP_LIMIT,           0x08052000      @ end of the firmware area; slots above (bootloader/DESIGN.md 6.1)
    .equ SRAM_BASE,           0x20000000
    .equ SRAM_END,            0x2000C000      @ 48 KB
    .equ V205_INITIAL_SP,     0x20001240      @ v2.05 vector word 0 (image 0x08006000); the bootloader test
                                              @ (SP & 0x2FFE0000) == 0x20000000 at bootloader 0x08004994

@ -----------------------------------------------------------------------------
@ RCC (RM0038 6.3; base 0x40023800)
@ -----------------------------------------------------------------------------
    .equ RCC_BASE,            0x40023800
    .equ RCC_CR,              0x40023800      @ 6.3.1
    .equ RCC_CR_B2,           0x40023802      @ byte 2 of RCC_CR: HSEON/HSERDY/HSEBYP (v2.05 0x0801FD7A)
    .equ RCC_ICSCR,           0x40023804      @ 6.3.2
    .equ RCC_CFGR,            0x40023808      @ 6.3.3
    .equ RCC_CIR,             0x4002380C      @ 6.3.4
    .equ RCC_AHBRSTR,         0x40023810      @ 6.3.5
    .equ RCC_APB2RSTR,        0x40023814      @ 6.3.6
    .equ RCC_APB1RSTR,        0x40023818      @ 6.3.7
    .equ RCC_AHBENR,          0x4002381C      @ 6.3.8
    .equ RCC_APB2ENR,         0x40023820      @ 6.3.9
    .equ RCC_APB1ENR,         0x40023824      @ 6.3.10
    .equ RCC_AHBLPENR,        0x40023828      @ 6.3.11
    .equ RCC_APB2LPENR,       0x4002382C      @ 6.3.12
    .equ RCC_APB1LPENR,       0x40023830      @ 6.3.13
    .equ RCC_CSR,             0x40023834      @ 6.3.14
    .equ RCC_CSR_B1,          0x40023835      @ byte 1 of RCC_CSR: LSEON/LSERDY/LSEBYP (v2.05 0x0801FDEC)

    @ RCC_CR bits (6.3.1)
    .equ RCC_CR_HSION,        0x00000001
    .equ RCC_CR_HSIRDY,       0x00000002
    .equ RCC_CR_MSION,        0x00000100
    .equ RCC_CR_MSIRDY,       0x00000200
    .equ RCC_CR_HSEON,        0x00010000
    .equ RCC_CR_HSERDY,       0x00020000
    .equ RCC_CR_HSEBYP,       0x00040000
    .equ RCC_CR_PLLON,        0x01000000
    .equ RCC_CR_PLLRDY,       0x02000000
    .equ RCC_CR_CSSON,        0x10000000
    BB_EQU RCC_CR_HSION_BB,   0x40023800, 0   @ 0x42470000, v2.05 0x0801FDE2 (RCC_HSICmd)

    @ RCC_ICSCR (6.3.2): MSIRANGE bits 15:13
    .equ RCC_ICSCR_MSIRANGE_MASK, 0x0000E000
    .equ RCC_ICSCR_MSIRANGE_0,    0x00000000  @ 65.536 kHz (FUN_0801C522 0x0801C558)
    .equ RCC_ICSCR_MSIRANGE_6,    0x0000C000  @ 4.194 MHz (FUN_0801BF1A 0x0801BF3A)

    @ RCC_CFGR (6.3.3)
    .equ RCC_CFGR_SW_MASK,    0x00000003
    .equ RCC_CFGR_SW_MSI,     0x00000000
    .equ RCC_CFGR_SW_HSI,     0x00000001
    .equ RCC_CFGR_SW_HSE,     0x00000002
    .equ RCC_CFGR_SW_PLL,     0x00000003
    .equ RCC_CFGR_SWS_MASK,   0x0000000C
    .equ RCC_CFGR_HPRE_MASK,  0x000000F0      @ AHB prescaler HPRE[3:0] (RM0038 6.3.3)
    .equ RCC_CFGR_PPRE2_MASK, 0x00003800      @ APB2 prescaler PPRE2[2:0] (RM0038 6.3.3; IMP-46)
    .equ RCC_CFGR_HPRE_DIV2,  0x00000080      @ HPRE = 1000b: HCLK = SYSCLK / 2
    .equ RCC_CFGR_SWS_MSI,    0x00000000
    .equ RCC_CFGR_SWS_PLL,    0x0000000C
    .equ RCC_CFGR_PLL_MASK,   0x00FD0000      @ PLLSRC | PLLMUL | PLLDIV (v2.05 0x08025FA6 bics #0xfd0000)
    .equ RCC_CFGR_PLL_HSE_X24_DIV3, 0x00990000 @ PLLSRC=HSE, PLLMUL=0110 x24, PLLDIV=10 /3 (RM0038 6.3.3): VCO 96 MHz
    .equ RCC_CFGR_PLL_HSE_X12_DIV3, 0x00910000 @ PLLSRC=HSE, PLLMUL=x12, PLLDIV=/3 (v2.05 0x08026076)
    .equ RCC_CFGR_RESET_KEEP, 0x88FFC00C      @ v2.05 0x08025F82 (SystemInit: SW, HPRE, PPRE1, PPRE2, MCOSEL,
                                              @ MCOPRE cleared)
    .equ RCC_CR_RESET_KEEP,   0xEEFEFFFE      @ v2.05 0x08025F8E (HSION, HSEON, CSSON, PLLON cleared)

    @ RCC_AHBENR (6.3.8)
    .equ RCC_AHBENR_GPIOAEN,  0x00000001
    .equ RCC_AHBENR_GPIOCEN,  0x00000004
    .equ RCC_AHBENR_GPIOGEN,  0x00000080
    .equ RCC_AHBENR_GPIO_ALL, 0x000000FF      @ GPIOA..GPIOH: bits 0..7 = ports A, B, C, D, E, H, F, G
                                              @ (RM0038 6.3.8; v2.05 0x0801BFCA movs r0,#0xff)
    .equ RCC_AHBENR_DMA2EN,   0x02000000

    @ RCC_APB2ENR (6.3.9) / RCC_APB2RSTR (6.3.6)
    .equ RCC_APB2_SYSCFG,     0x00000001
    .equ RCC_APB2_ADC1,       0x00000200
    .equ RCC_APB2_SDIO,       0x00000800
    .equ RCC_APB2_TIM11,      0x00000010      @ TIM11EN, bit 4 (6.3.9, rm0038.txt:8136; IMP-46)

    @ RCC_APB1ENR (6.3.10)
    .equ RCC_APB1_TIM2,       0x00000001
    .equ RCC_APB1_TIM3,       0x00000002
    .equ RCC_APB1_LCD,        0x00000200
    .equ RCC_APB1_USART2,     0x00020000
    .equ RCC_APB1_PWR,        0x10000000

    @ RCC_CSR (6.3.14)
    .equ RCC_CSR_LSION,       0x00000001
    .equ RCC_CSR_LSIRDY,      0x00000002
    .equ RCC_CSR_LSEON,       0x00000100
    .equ RCC_CSR_RTCSEL_MASK, 0x00030000
    .equ RCC_CSR_RTCSEL_LSI,  0x00020000      @ v2.05 0x0801BFBC
    .equ RCC_CSR_RTCSEL_HSE,  0x00030000      @ the RTCPRE path of RCC_RTCCLKConfig (v2.05 0x0801FF36)
    .equ RCC_CR_RTCPRE_MASK,  0x60000000
    .equ RCC_CR_RTCPRE_DIV16, 0x60000000      @ HSE_RTC = HSE / 16; writable only while HSEON = 0 (6.3.1; IMP-46)
    .equ RCC_ICSCR_MSITRIM_B, 0x40023807      @ byte 3 of RCC_ICSCR: MSITRIM[7:0] (6.3.2, byte access allowed; IMP-46)
    .equ RCC_CSR_RTCEN,       0x00400000
    .equ RCC_CSR_RTCRST,      0x00800000
    BB_EQU RCC_CSR_LSION_BB,  0x40023834, 0   @ 0x42470680, v2.05 0x0801FDFC (RCC_LSICmd)
    BB_EQU RCC_CSR_RTCEN_BB,  0x40023836, 6   @ 0x424706D8, v2.05 0x0801FF70 (RCC_RTCCLKCmd)
    BB_EQU RCC_CSR_RTCRST_BB, 0x40023836, 7   @ 0x424706DC, v2.05 0x0801FF78 (RCC_RTCResetCmd)

    @ RCC flag numbers of the v2.05 RCC_GetFlagStatus (0x0801FFF8): bits 7:5 = register (1 = CR, else CSR),
    @ bits 4:0 = bit number
    .equ RCC_FLAG_HSIRDY,     0x21
    .equ RCC_FLAG_HSERDY,     0x31
    .equ RCC_FLAG_LSIRDY,     0x41

    @ Clock values of the v2.05 RCC_GetClocksFreq (0x0801FE2A)
    .equ HSI_VALUE,           16000000        @ 0x00F42400 (v2.05 pool 0x08020068)
    .equ HSE_VALUE,           8000000         @ 0x007A1200 (v2.05 pool 0x0802006C; the StdPeriph constant,
                                              @ not the crystal of the schematic text)

@ -----------------------------------------------------------------------------
@ PWR (RM0038 5.4; base 0x40007000)
@ -----------------------------------------------------------------------------
    .equ PWR_CR,              0x40007000      @ 5.4.1
    .equ PWR_CSR,             0x40007004      @ 5.4.2
    .equ PWR_CR_LPSDSR,       0x00000001
    .equ PWR_CR_PDDS,         0x00000002
    .equ PWR_CR_CWUF,         0x00000004
    .equ PWR_CR_CSBF,         0x00000008
    .equ PWR_CR_PVDE,         0x00000010
    .equ PWR_CR_DBP,          0x00000100
    .equ PWR_CR_ULP,          0x00000200
    .equ PWR_CR_VOS_MASK,     0x00001800
    .equ PWR_CR_VOS_RANGE1,   0x00000800      @ 1.8 V (v2.05 0x0801BED8, 0x0802603E)
    .equ PWR_CR_VOS_RANGE3,   0x00001800      @ 1.2 V (v2.05 0x0801C546)
    .equ PWR_CSR_WUF,         0x00000001
    .equ PWR_CSR_SBF,         0x00000002
    .equ PWR_CSR_VOSF,        0x00000010
    BB_EQU PWR_CR_PVDE_BB,    0x40007000, 4   @ 0x420E0010, v2.05 0x080207A4 (PWR_PVDCmd)
    BB_EQU PWR_CR_DBP_BB,     0x40007001, 0   @ 0x420E0020, v2.05 0x0802079C (PWR_RTCAccessCmd)
    BB_EQU PWR_CR_ULP_BB,     0x40007001, 1   @ 0x420E0024, v2.05 0x080207AC (PWR_UltraLowPowerCmd)

@ -----------------------------------------------------------------------------
@ FLASH interface (RM0038 3.9; base 0x40023C00).  Only these four registers exist for the firmware; each is
@ addressed with its own literal and offset 0 (DESIGN.md 8.2).  FLASH_ACR is used by the SYS clock object only;
@ FLASH_PECR, FLASH_PEKEYR and FLASH_SR by the NVM objects only (DESIGN.md 9.3 item 2).
@ -----------------------------------------------------------------------------
    .equ FLASH_ACR,           0x40023C00      @ 3.9.1
    .equ FLASH_PECR,          0x40023C04      @ 3.9.2
    .equ FLASH_PEKEYR,        0x40023C0C      @ 3.9.4
    .equ FLASH_SR,            0x40023C18      @ 3.9.7
    .equ FLASH_ACR_LATENCY,   0x00000001
    .equ FLASH_ACR_PRFTEN,    0x00000002
    .equ FLASH_ACR_ACC64,     0x00000004
    .equ FLASH_PECR_PELOCK,   0x00000001
    .equ FLASH_PECR_FTDW,     0x00000100
    .equ FLASH_SR_CLEAR_ALL,  0x00001F02      @ EOP and the error flags of bits 8..12 (RDERR, bit 13,
                                              @ is not in it), the value v2.05 writes at 0x0801BEA4

@ -----------------------------------------------------------------------------
@ GPIO (RM0038 7.4; ports A..H; DESIGN.md 2.3)
@ -----------------------------------------------------------------------------
    .equ GPIOA_BASE,          0x40020000
    .equ GPIOB_BASE,          0x40020400
    .equ GPIOC_BASE,          0x40020800
    .equ GPIOD_BASE,          0x40020C00
    .equ GPIOE_BASE,          0x40021000
    .equ GPIOH_BASE,          0x40021400
    .equ GPIOF_BASE,          0x40021800
    .equ GPIOG_BASE,          0x40021C00
    .equ GPIO_MODER,          0x00            @ 7.4.1
    .equ GPIO_OTYPER,         0x04            @ 7.4.2 (16 bits)
    .equ GPIO_OSPEEDR,        0x08            @ 7.4.3
    .equ GPIO_PUPDR,          0x0C            @ 7.4.4
    .equ GPIO_IDR,            0x10            @ 7.4.5
    .equ GPIO_ODR,            0x14            @ 7.4.6
    .equ GPIO_BSRRL,          0x18            @ 7.4.7 bits 15:0, write 1 = set (v2.05 halfword stores)
    .equ GPIO_BSRRH,          0x1A            @ 7.4.7 bits 31:16, write 1 = reset
    .equ GPIO_AFRL,           0x20            @ 7.4.9
    .equ GPIO_AFRH,           0x24            @ 7.4.10
    @ MODER / PUPDR / OTYPER field values (7.4.1, 7.4.4, 7.4.2)
    .equ GPIO_MODE_IN,        0
    .equ GPIO_MODE_OUT,       1
    .equ GPIO_MODE_AF,        2
    .equ GPIO_MODE_AN,        3
    .equ GPIO_OT_PP,          0
    .equ GPIO_OT_OD,          1
    .equ GPIO_PUPD_NONE,      0
    .equ GPIO_PUPD_UP,        1
    .equ GPIO_PUPD_DOWN,      2
    @ OSPEEDR values used by v2.05: 0 = 400 kHz, 1 = 2 MHz, 3 = 40 MHz (7.4.3)
    .equ GPIO_SPEED_400K,     0
    .equ GPIO_SPEED_2M,       1
    .equ GPIO_SPEED_40M,      3

@ -----------------------------------------------------------------------------
@ SYSCFG (RM0038 8.5) and EXTI (RM0038 10.3)
@ -----------------------------------------------------------------------------
    .equ SYSCFG_EXTICR1,      0x40010008      @ 8.5.3 (EXTICR1..4 at +0, +4, +8, +12)
    .equ EXTI_PORTSOURCE_G,   7               @ EXTIx field value of port G (8.5.3..8.5.6)
    .equ EXTI_BASE,           0x40010400
    .equ EXTI_IMR,            0x40010400      @ 10.3.1
    .equ EXTI_EMR,            0x40010404      @ 10.3.2
    .equ EXTI_RTSR,           0x40010408      @ 10.3.3
    .equ EXTI_FTSR,           0x4001040C      @ 10.3.4
    .equ EXTI_SWIER,          0x40010410      @ 10.3.5
    .equ EXTI_PR,             0x40010414      @ 10.3.6
    .equ EXTI_LINE20_RTC_WKUP, 0x00100000     @ EXTI line 20 = RTC wakeup (10.2.5; v2.05 0x080248DE)

@ -----------------------------------------------------------------------------
@ ADC1 (RM0038 12.15; base 0x40012400) and ADC common (12.15.19/20)
@ -----------------------------------------------------------------------------
    .equ ADC1_BASE,           0x40012400
    .equ ADC_SR,              0x00            @ 12.15.1
    .equ ADC_CR1,             0x04            @ 12.15.2
    .equ ADC_CR2,             0x08            @ 12.15.3
    .equ ADC_SMPR1,           0x0C            @ 12.15.4  channels 20..29
    .equ ADC_SMPR2,           0x10            @ 12.15.5  channels 10..19
    .equ ADC_SMPR3,           0x14            @ 12.15.6  channels 0..9 ("written only when ADON=0")
    .equ ADC_SQR1,            0x30            @ 12.15.10 L[4:0] = bits 24:20, ranks 25..28
    .equ ADC_SQR2,            0x34            @ 12.15.11 ranks 19..24
    .equ ADC_SQR3,            0x38            @ 12.15.12 ranks 13..18
    .equ ADC_SQR4,            0x3C            @ 12.15.13 ranks 7..12
    .equ ADC_SQR5,            0x40            @ 12.15.14 ranks 1..6
    .equ ADC_DR,              0x58            @ 12.15.17
    .equ ADC_SMPR0,           0x5C            @ 12.15.18 channels 30, 31
    .equ ADC_SR_EOC,          0x00000002
    .equ ADC_SR_ADONS,        0x00000040
    .equ ADC_CR2_ADON,        0x00000001
    .equ ADC_CR2_SWSTART,     0x40000000
    .equ ADC_CR1_KEEP,        0xFCFFFEFF      @ v2.05 ADC_Init 0x080200BE: RES and SCAN cleared
    .equ ADC_CR2_KEEP,        0xC0FFF7FD      @ v2.05 ADC_Init 0x080200D2: EXTEN, EXTSEL, ALIGN, CONT cleared
    .equ ADC_CH_TEMP_SENSE,   4               @ PA4 thermistor (adc_ch4_average_10)
    .equ ADC_CH_BATTERY,      5               @ PA5 battery sense (adc_ch5_process)
    .equ ADC_SMP_384,         7               @ 384 cycles (12.15.6), v2.05 0x080137E0 / 0x080137F0

@ -----------------------------------------------------------------------------
@ General purpose timers TIM2/TIM3 (RM0038 17.4)
@ -----------------------------------------------------------------------------
    .equ TIM2_BASE,           0x40000000
    .equ TIM3_BASE,           0x40000400
    .equ TIM4_BASE,           0x40000800
    .equ TIM5_BASE,           0x40000C00
    .equ TIM6_BASE,           0x40001000
    .equ TIM7_BASE,           0x40001400
    .equ TIM_CR1,             0x00            @ 17.4.1
    .equ TIM_DIER,            0x0C            @ 17.4.4
    .equ TIM_SR,              0x10            @ 17.4.5
    .equ TIM_EGR,             0x14            @ 17.4.6
    .equ TIM_CNT,             0x24            @ 17.4.10
    .equ TIM_PSC,             0x28            @ 17.4.11
    .equ TIM_ARR,             0x2C            @ 17.4.12
    .equ TIM_CR1_CEN,         0x0001
    .equ TIM_CR1_KEEP_CMS_DIR, 0xFF8F         @ v2.05 TIM_TimeBaseInit 0x08020926 (DIR and CMS cleared)
    .equ TIM_CR1_KEEP_CKD,    0xFCFF          @ v2.05 TIM_TimeBaseInit 0x0802093C (CKD cleared)
    .equ TIM_DIER_UIE,        0x0001
    .equ TIM_SR_UIF,          0x0001
    .equ TIM_EGR_UG,          0x0001

@ -----------------------------------------------------------------------------
@ TIM11 (RM0038 18.5; base 0x40011000, APB2), used only by sys/msical.s (IMP-46) to measure MSI against HSE_RTC
@ -----------------------------------------------------------------------------
    .equ TIM11_BASE,          0x40011000      @ rm0038.txt:2279
    .equ TIM_CCMR1,           0x18            @ 18.5.6
    .equ TIM_CCER,            0x20            @ 18.5.7
    .equ TIM_CCR1,            0x34            @ 18.5.11
    .equ TIM11_OR,            0x50            @ 18.5.13
    .equ TIM_SR_CC1IF,        0x0002          @ 18.5.4 bit 1: capture 1 occurred (cleared by reading CCR1)
    .equ TIM_SR_CC1OF,        0x0200          @ 18.5.4 bit 9: a capture came while CC1IF was still set
    .equ TIM_CCMR1_IC1_PSC8,  0x000D          @ CC1S = 01 (IC1 on TI1), IC1PSC = 11 (every 8 events), IC1F = 0
    .equ TIM_CCER_CC1E,       0x0001          @ capture enabled, CC1P = 0 (rising edge)
    .equ TIM11_OR_HSE_RTC,    0x0002          @ TI1_RMP = 10: HSE_RTC on TIM11_CH1 (rm0038.txt:27834..27840)

@ -----------------------------------------------------------------------------
@ LCD controller (RM0038 16.5; base 0x40002400)
@ -----------------------------------------------------------------------------
    .equ LCD_BASE,            0x40002400
    .equ LCD_CR,              0x40002400      @ 16.5.1
    .equ LCD_FCR,             0x40002404      @ 16.5.2
    .equ LCD_SR,              0x40002408      @ 16.5.3
    .equ LCD_CLR,             0x4000240C      @ 16.5.4
    .equ LCD_RAM,             0x40002414      @ 16.5.5 (LCD_RAM0; v2.05 commits words 0..7 to 0x40002414..0x40002430)
    .equ LCD_CR_LCDEN,        0x00000001
    .equ LCD_SR_ENS,          0x00000001
    .equ LCD_SR_SOF,          0x00000002
    .equ LCD_SR_UDR,          0x00000004
    .equ LCD_SR_UDD,          0x00000008
    .equ LCD_SR_RDY,          0x00000010
    .equ LCD_SR_FCRSF,        0x00000020
    BB_EQU LCD_CR_LCDEN_BB,   0x40002400, 0   @ 0x42048000 (v2.05 LCD_Cmd 0x080203FA)
    BB_EQU LCD_CR_MUX_SEG_BB, 0x40002400, 7   @ 0x4204801C (v2.05 0x08020422, FUN_0802041E)
    BB_EQU LCD_SR_UDR_BB,     0x40002408, 2   @ 0x42048108

@ -----------------------------------------------------------------------------
@ RTC (RM0038 20.6; base 0x40002800)
@ -----------------------------------------------------------------------------
    .equ RTC_BASE,            0x40002800
    .equ RTC_CR,              0x40002808      @ 20.6.3
    .equ RTC_ISR,             0x4000280C      @ 20.6.4
    .equ RTC_WPR,             0x40002824      @ 20.6.10
    .equ RTC_TAFCR,           0x40002840      @ 20.6.17
    .equ RTC_WPR_KEY1,        0xCA            @ 20.6.10 unlock sequence (v2.05 0x080209A8)
    .equ RTC_WPR_KEY2,        0x53
    .equ RTC_WPR_LOCK,        0xFF            @ any other value re-enables the protection (v2.05 0x080209F4)
    .equ RTC_IT_WUT,          0x00004000      @ RTC_CR WUTIE (v2.05 0x0801C56E)
    .equ RTC_TAFCR_TAMPIE,    0x00000004

@ -----------------------------------------------------------------------------
@ USART2 (RM0038 27.6; base 0x40004400)
@ -----------------------------------------------------------------------------
    .equ USART2_BASE,         0x40004400
    .equ USART_SR,            0x00            @ 27.6.1
    .equ USART_DR,            0x04            @ 27.6.2
    .equ USART_BRR,           0x08            @ 27.6.3
    .equ USART_CR1,           0x0C            @ 27.6.4
    .equ USART_CR2,           0x10            @ 27.6.5
    .equ USART_CR3,           0x14            @ 27.6.6
    .equ USART_GTPR,          0x18            @ 27.6.7
    .equ USART_SR_FE,         0x0002          @ framing error (27.6.1 bit 1)
    .equ USART_SR_NF,         0x0004          @ noise detected (27.6.1 bit 2)
    .equ USART_SR_ORE,        0x0008          @ overrun error (27.6.1 bit 3)
    .equ USART_SR_RXNE,       0x0020
    .equ USART_SR_TC,         0x0040
    .equ USART_SR_TXE,        0x0080
    .equ USART_CR1_RE,        0x0004
    .equ USART_CR1_TE,        0x0008
    .equ USART_CR1_RXNEIE,    0x0020
    .equ USART_CR1_TXEIE,     0x0080
    .equ USART_CR1_UE,        0x2000

@ -----------------------------------------------------------------------------
@ SDIO (RM0038 29.9; base 0x40012C00) and DMA (RM0038 11.4; DMA2 channel 4 serves SDIO)
@ -----------------------------------------------------------------------------
    .equ SDIO_BASE,           0x40012C00
    .equ SDIO_POWER,          0x00
    .equ SDIO_CLKCR,          0x04
    .equ SDIO_ARG,            0x08
    .equ SDIO_CMD,            0x0C
    .equ SDIO_RESPCMD,        0x10
    .equ SDIO_RESP1,          0x14
    .equ SDIO_RESP2,          0x18
    .equ SDIO_RESP3,          0x1C
    .equ SDIO_RESP4,          0x20
    .equ SDIO_DTIMER,         0x24
    .equ SDIO_DLEN,           0x28
    .equ SDIO_DCTRL,          0x2C
    .equ SDIO_DCOUNT,         0x30
    .equ SDIO_STA,            0x34
    .equ SDIO_ICR,            0x38
    .equ SDIO_MASK,           0x3C
    .equ SDIO_FIFOCNT,        0x48
    .equ SDIO_FIFO,           0x80
    .equ DMA1_BASE,           0x40026000
    .equ DMA2_BASE,           0x40026400
    .equ DMA_ISR,             0x00
    .equ DMA_IFCR,            0x04
    .equ DMA_CH4_CCR,         0x44            @ 0x08 + 20 * (4 - 1)
    .equ DMA_CH4_CNDTR,       0x48
    .equ DMA_CH4_CPAR,        0x4C
    .equ DMA_CH4_CMAR,        0x50

@ -----------------------------------------------------------------------------
@ Debug MCU (RM0038 30.16.3)
@ -----------------------------------------------------------------------------
    .equ DBGMCU_CR,           0xE0042004
    .equ DBGMCU_CR_SLEEP_STOP_STANDBY, 0x00000007 @ DBG_SLEEP | DBG_STOP | DBG_STANDBY (v2.05 0x0801BEF6)

@ -----------------------------------------------------------------------------
@ Cortex-M3 core (PM0056 4.2 MPU, 4.3 NVIC, 4.4 SCB, 4.5 SysTick)
@ -----------------------------------------------------------------------------
    .equ STK_CTRL,            0xE000E010      @ 4.5.1
    .equ STK_LOAD,            0xE000E014      @ 4.5.2
    .equ STK_VAL,             0xE000E018      @ 4.5.3
    .equ STK_CTRL_TICKINT,    0x00000002
    .equ NVIC_ISER0,          0xE000E100      @ 4.3.2 (ISER1 at +4)
    .equ NVIC_ICER0,          0xE000E180      @ 4.3.3
    .equ NVIC_ISPR0,          0xE000E200      @ 4.3.4
    .equ NVIC_ICPR0,          0xE000E280      @ 4.3.5
    .equ NVIC_IABR0,          0xE000E300      @ 4.3.6
    .equ NVIC_IPR0,           0xE000E400      @ 4.3.7 (one byte per IRQ, priority in bits 7:4 on STM32L1)
    .equ NVIC_IPR_WORDS,      15              @ IRQ 0..59 covers the 57 IRQs of the Cat.4 table (RM0038 Table 51)
    .equ SCB_ICSR,            0xE000ED04      @ 4.4.3
    .equ SCB_VTOR,            0xE000ED08      @ 4.4.4
    .equ SCB_AIRCR,           0xE000ED0C      @ 4.4.5
    .equ SCB_SCR,             0xE000ED10      @ 4.4.6
    .equ SCB_CCR,             0xE000ED14      @ 4.4.7
    .equ SCB_SHCSR,           0xE000ED24      @ 4.4.9
    .equ SCB_AIRCR_VECTKEY,   0x05FA0000      @ write key (v2.05 0x080208EC)
    .equ SCB_AIRCR_PRIGROUP_2_2, 0x00000500   @ PRIGROUP 5: 2 preemption bits, 2 subpriority bits (0x0801BFE0)
    .equ SCB_AIRCR_PRIGROUP_MASK, 0x00000700
    .equ SCB_AIRCR_SYSRESETREQ, 0x00000004
    .equ SCB_SCR_SLEEPDEEP,   0x00000004
    .equ SCB_SCR_SEVONPEND,   0x00000010
    .equ SCB_VTOR_MASK,       0x1FFFFF80      @ v2.05 nvic_set_vector_table 0x080208E0
    .equ MPU_TYPER,           0xE000ED90      @ 4.2.5
    .equ MPU_CTRL,            0xE000ED94      @ 4.2.6
    .equ MPU_RNR,             0xE000ED98      @ 4.2.7
    .equ MPU_RBAR,            0xE000ED9C      @ 4.2.8
    .equ MPU_RASR,            0xE000EDA0      @ 4.2.9
    .equ MPU_CTRL_ENABLE,     0x00000001
    .equ MPU_CTRL_PRIVDEFENA, 0x00000004

@ -----------------------------------------------------------------------------
@ IRQ numbers (RM0038 10.1.2 Table 51, Cat.4 devices) used by the firmware
@ -----------------------------------------------------------------------------
    .equ IRQ_RTC_WKUP,        3
    .equ IRQ_EXTI0,           6
    .equ IRQ_EXTI1,           7
    .equ IRQ_EXTI2,           8
    .equ IRQ_EXTI3,           9
    .equ IRQ_EXTI4,           10
    .equ IRQ_ADC1,            18
    .equ IRQ_EXTI9_5,         23
    .equ IRQ_TIM2,            28
    .equ IRQ_TIM3,            29
    .equ IRQ_USART2,          38
    .equ IRQ_EXTI15_10,       40
    .equ IRQ_SDIO,            45
    .equ IRQ_DMA2_CH4,        53
    .equ IRQ_COUNT,           57              @ vector table: 16 system words + 57 IRQ words (DESIGN.md 2.2)

    .endif
