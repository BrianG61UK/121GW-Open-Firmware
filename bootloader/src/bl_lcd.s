@ =============================================================================
@ bl_lcd.s - display of the bootloader: controller set-up, 7-segment text, bargraph
@
@ Controller set-up as the firmware's lcd_init (firmware/src/lcd/lcd.s; RM0038 16.5): RTC/LCD clock = LSI
@ (rcc_lsi_as_rtc_lcd_clock, firmware/src/sys/clock.s), LCD pins AF11 (masks of analysis/lcd_map.md 1: PA 0x87CE,
@ PB 0xFF3B, PC 0x06FF, PD 0xFF00, PE 0x000F), FCR: PS = 3, DIV = 0, CC = 4, PON = 4; CR: DUTY = 1/4, BIAS = 1/3,
@ internal step-up; LCDEN; ENS and RDY waited for with a bound.  The display is driven from an 8-word shadow,
@ committed to LCD_RAM0..7 with an update request (only words 0..7 carry segments, lcd_map.md 1).
@ Text: positions 0..4 = sub display, 5..9 = main display (lcd_map.md 2); the font is the firmware's (lcd/font.s:
@ '0'..'9', 'A'..'Z', 'a'..'z'; ' ' blank, '-' segment g), font bit -> segment b a g f c e - d (bit 6 unused).
@ Bargraph: segments 0..25 (lcd_map.md 3).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "bl.inc"

    .equ LCD_SR_FCRSF,      0x20            @ RM0038 16.5.3
    .equ LCD_SR_RDY,        0x10
    .equ LCD_FCR_VALUE,     0x00C01040      @ PS = 3 (bits 25:22), DIV = 0, CC = 4 (bits 12:10), PON = 4 (bits 6:4)
    .equ LCD_CR_VALUE,      0x0000004C      @ BIAS = 2 (1/3, bits 6:5), DUTY = 3 (1/4, bits 4:2), VSEL = 0, MUX_SEG = 0
    .equ LCD_POLLS,         0x8000          @ bound of the set-up waits (as the firmware's LCD_WAIT_POLLS use)
    .equ UDR_POLLS,         0x40000         @ bound of the wait for the previous update (several LCD frames)
    .equ APB1_LCDEN,        0x00000200      @ RCC_APB1ENR bit 9 (RM0038 6.3.10)
    .equ APB1_PWREN,        0x10000000      @ RCC_APB1ENR bit 28

    .section .bss.bl_lcd, "aw", %nobits
    .balign 4
bl_shadow:      .space 32                   @ LCD_RAM0..7

    .section .text.bl_lcd, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bl_lcd_init - pins, clock and controller; the shadow cleared (nothing shown until bl_lcd_commit)
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC bl_lcd_init
    push {r4, lr}
    ldr r4, =bl_lcd_pins                    @ AF11 pins, port by port
1:  ldr r0, [r4], #4                        @ port base, 0 ends the list
    cbz r0, 2f
    mov r1, r4
    bl brd_gpio_init
    adds r4, r4, #GPIO_DESC_SIZE
    b 1b
2:  ldr r0, =RCC_APB1ENR
    ldr r1, [r0]
    ldr r2, =(APB1_LCDEN | APB1_PWREN)
    orrs r1, r1, r2
    str r1, [r0]
    bl rcc_lsi_as_rtc_lcd_clock             @ LCD clock = RTCCLK = LSI
    ldr r0, =LCD_FCR
    ldr r1, =LCD_FCR_VALUE
    str r1, [r0]
    movs r0, #LCD_SR_FCRSF                  @ FCR taken over (16.5.2)
    bl bl_lcd_wait
    ldr r0, =LCD_CR
    movs r1, #LCD_CR_VALUE
    str r1, [r0]
    orr r1, r1, #LCD_CR_LCDEN
    str r1, [r0]
    movs r0, #LCD_SR_ENS
    bl bl_lcd_wait
    movs r0, #LCD_SR_RDY
    bl bl_lcd_wait
    bl bl_lcd_clear
    pop {r4, pc}
ENDFUNC bl_lcd_init

@ bl_lcd_wait - wait until LCD_SR has all bits of r0 (bounded); clobbers r1-r3
LFUNC bl_lcd_wait
    ldr r1, =LCD_SR
    ldr r2, =LCD_POLLS
1:  ldr r3, [r1]
    bics r3, r0, r3
    beq 2f
    subs r2, r2, #1
    bne 1b
2:  bx lr
ENDFUNC bl_lcd_wait

@ -----------------------------------------------------------------------------
@ bl_lcd_clear - all segments off in the shadow
@ Clobbers : r0-r2
@ -----------------------------------------------------------------------------
FUNC bl_lcd_clear
    ldr r0, =bl_shadow
    movs r1, #0
    movs r2, #8
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    bx lr
ENDFUNC bl_lcd_clear

@ -----------------------------------------------------------------------------
@ bl_lcd_all_on - every segment on (the lamp test the old bootloader shows at every start), committed
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC bl_lcd_all_on
    ldr r0, =bl_shadow
    mov r1, #0xFFFFFFFF
    movs r2, #8
1:  str r1, [r0], #4
    subs r2, r2, #1
    bne 1b
    b bl_lcd_commit
ENDFUNC bl_lcd_all_on

@ -----------------------------------------------------------------------------
@ bl_lcd_text - draw 5 characters
@ In       : r0 = first position (0 sub display, 5 main display), r1 = 5 characters
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
FUNC bl_lcd_text
    push {r4-r7, lr}
    mov r4, r0
    mov r5, r1
    add r6, r4, #5
1:  ldrb r0, [r5], #1
    bl bl_font
    mov r1, r4
    bl bl_lcd_glyph
    adds r4, r4, #1
    cmp r4, r6
    bne 1b
    pop {r4-r7, pc}
ENDFUNC bl_lcd_text

@ bl_font - segment byte of character r0 (firmware fn_0801AFFC rules); clobbers r1
LFUNC bl_font
    sub r1, r0, #'0'
    cmp r1, #10
    bhs 1f
    ldr r0, =v205_tab_08029184
    ldrb r0, [r0, r1]
    bx lr
1:  sub r1, r0, #'A'
    cmp r1, #26
    bhs 2f
    ldr r0, =v205_tab_080290B8
    ldrb r0, [r0, r1]
    bx lr
2:  sub r1, r0, #'a'
    cmp r1, #26
    bhs 3f
    ldr r0, =v205_tab_080290D4
    ldrb r0, [r0, r1]
    bx lr
3:  cmp r0, #'-'
    ite eq
    moveq r0, #0x04                         @ segment g
    movne r0, #0                            @ blank (space and every other character)
    bx lr
ENDFUNC bl_font

@ -----------------------------------------------------------------------------
@ bl_lcd_glyph - set the segments of one position to a font byte (the 7 segments of the position are written, the
@ decimal point slot is not)
@ In       : r0 = font byte, r1 = position 0..9
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC bl_lcd_glyph
    push {r4-r6, lr}
    mov r4, r0
    ldr r5, =bl_lcd_posmap
    movs r2, #7                             @ 7 bytes per position
    mla r5, r1, r2, r5
    movs r6, #0                             @ font bits 0..5, then bit 7
1:  ldrb r0, [r5, r6]                       @ word << 5 | bit
    cmp r6, #6
    ite lo
    movlo r1, r6
    movhs r1, #7
    lsr r2, r4, r1
    and r1, r2, #1                          @ r1 = segment on
    bl bl_lcd_seg
    adds r6, r6, #1
    cmp r6, #7
    bne 1b
    pop {r4-r6, pc}
ENDFUNC bl_lcd_glyph

@ bl_lcd_seg - shadow segment r0 (word << 5 | bit) on (r1 = 1) or off (r1 = 0); clobbers r0-r3
LFUNC bl_lcd_seg
    lsrs r2, r0, #5                         @ word
    and r0, r0, #31                         @ bit
    movs r3, #1
    lsls r3, r3, r0
    ldr r0, =bl_shadow
    ldr r12, [r0, r2, lsl #2]
    cmp r1, #0
    ite ne
    orrne r12, r12, r3
    biceq r12, r12, r3
    str r12, [r0, r2, lsl #2]
    bx lr
ENDFUNC bl_lcd_seg

@ -----------------------------------------------------------------------------
@ bl_lcd_bar - bargraph: segments 0..n-1 on, n..25 off
@ In       : r0 = n (0..26)
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ -----------------------------------------------------------------------------
FUNC bl_lcd_bar
    push {r4, r5, lr}
    mov r4, r0
    movs r5, #0
1:  ldr r0, =bl_lcd_barmap
    ldrb r0, [r0, r5]
    cmp r5, r4
    ite lo
    movlo r1, #1
    movhs r1, #0
    bl bl_lcd_seg
    adds r5, r5, #1
    cmp r5, #26
    bne 1b
    pop {r4, r5, pc}
ENDFUNC bl_lcd_bar

@ -----------------------------------------------------------------------------
@ bl_lcd_commit - shadow to LCD_RAM0..7, update request (RM0038 16.3.6: LCD_RAM is write-protected while UDR is set,
@ so the previous update is waited for)
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC bl_lcd_commit
    push {lr}
    ldr r1, =LCD_SR
    ldr r2, =UDR_POLLS
1:  ldr r3, [r1]
    tst r3, #LCD_SR_UDR
    beq 2f
    subs r2, r2, #1
    bne 1b
2:  ldr r0, =bl_shadow
    ldr r1, =LCD_RAM
    movs r2, #8
3:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 3b
    ldr r1, =LCD_SR
    movs r0, #LCD_SR_UDR
    str r0, [r1]                            @ UDR: transfer the RAM to the display
    pop {pc}
ENDFUNC bl_lcd_commit

    .ltorg

    .section .rodata.bl_lcd, "a", %progbits
@ position -> shadow segment (word << 5 | bit) for font bits 0..5 and 7 (segments b a g f c e d; lcd_map.md 2)
bl_lcd_posmap:
    .byte 0xDB, 0xDC, 0x9B, 0x9C, 0x5B, 0x5C, 0x1C    @ position 0 (sub)
    .byte 0xD9, 0xE8, 0x99, 0xA8, 0x59, 0x68, 0x28    @ position 1 (sub)
    .byte 0xD7, 0xD8, 0x97, 0x98, 0x57, 0x58, 0x18    @ position 2 (sub)
    .byte 0xD5, 0xD6, 0x95, 0x96, 0x55, 0x56, 0x16    @ position 3 (sub)
    .byte 0xD3, 0xD4, 0x93, 0x94, 0x53, 0x54, 0x14    @ position 4 (sub)
    .byte 0xE5, 0xE6, 0xA5, 0xA6, 0x65, 0x66, 0x26    @ position 5 (main)
    .byte 0xE3, 0xE4, 0xA3, 0xA4, 0x63, 0x64, 0x24    @ position 6 (main)
    .byte 0xE1, 0xE2, 0xA1, 0xA2, 0x61, 0x62, 0x22    @ position 7 (main)
    .byte 0xCE, 0xCF, 0x8E, 0x8F, 0x4E, 0x4F, 0x0F    @ position 8 (main)
    .byte 0xCC, 0xCD, 0x8C, 0x8D, 0x4C, 0x4D, 0x0D    @ position 9 (main)
@ bargraph segments 0..25 (lcd_map.md 3)
bl_lcd_barmap:
    .byte 0x01, 0x41, 0x81, 0xC1, 0xC2, 0x82, 0x42, 0x02, 0x03, 0x43, 0x83, 0xC3, 0xC4
    .byte 0x84, 0x44, 0x04, 0x05, 0x45, 0x85, 0xC5, 0xC6, 0x86, 0x46, 0x06, 0x07, 0x47
@ LCD pins: port base, then a GPIO_DESC (AF11, as the firmware's fn_0801B4D6)
    .balign 4
bl_lcd_pins:
    .word GPIOA_BASE
    GPIO_DESC 0x87CE, GPIO_MODE_AF, 0, GPIO_OT_PP, GPIO_PUPD_NONE, 11, BRD_LEVEL_KEEP
    .word GPIOB_BASE
    GPIO_DESC 0xFF3B, GPIO_MODE_AF, 0, GPIO_OT_PP, GPIO_PUPD_NONE, 11, BRD_LEVEL_KEEP
    .word GPIOC_BASE
    GPIO_DESC 0x06FF, GPIO_MODE_AF, 0, GPIO_OT_PP, GPIO_PUPD_NONE, 11, BRD_LEVEL_KEEP
    .word GPIOD_BASE
    GPIO_DESC 0xFF00, GPIO_MODE_AF, 0, GPIO_OT_PP, GPIO_PUPD_NONE, 11, BRD_LEVEL_KEEP
    .word GPIOE_BASE
    GPIO_DESC 0x000F, GPIO_MODE_AF, 0, GPIO_OT_PP, GPIO_PUPD_NONE, 11, BRD_LEVEL_KEEP
    .word 0
