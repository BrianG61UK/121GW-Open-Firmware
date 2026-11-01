@ =============================================================================
@ draw.s - LCD: font lookup, digit and glyph drawing into the shadow RAM, value drawers (DESIGN.md 6.7)
@
@ Replaces lcd_draw_glyph 0x0801A950 with the font lookup 0x0801AFFC (tables 0x08029184 digits, 0x080290B8 A..Z,
@ 0x080290D4 a..z, in font.s), lcd_draw_5char 0x08019AE0 and its two partial forms, the number-to-digit helpers
@ 0x0801B090 / 0x0801B130, the value drawers lcd_show_value_pos5_9 0x08017100 and lcd_show_value_pos0_4 0x08017F28 and the
@ decimal-point setters 0x0801717E / 0x08017FB4.  The instruction streams are v2.05's; the shadow bit of every
@ position is listed in analysis/lcd_map.md section 2.
@ Context: main only (the digit work words 0x20007DB0..0x20007DC0 and the text buffer 0x20007C30 are shared state).
@
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.lcd.draw, "ax", %progbits

@ -----------------------------------------------------------------------------
@ lcd_show_value_pos5_9 - draw a signed value on the main display
@ Replaces : 0x08017100 lcd_show_value_pos5_9 (v2.05, 126 bytes)
@ In       : r0 = meter mode (unused by the code), r1 = decimal-point position d (0..4), r2 = signed value (counts),
@            r3 = 1 skip while hold is active, 0 draw always
@ Out      : -
@ Context  : main only
@ RAM      : reads hold_active (0x2000804F); writes lcd_shadow (decimal point, minus sign w3 bit 7, digits), 0x20007C30,
@            0x20007DB0..DC0, 0x2000805B (commit request) and 0x20007D70 (last drawn value, also the BLE value)
@ Spec     : analysis/lcd_map.md 2 (positions 5..9 = main display, sign w3b7)
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC lcd_show_value_pos5_9
    stmdb sp!, {r4, r5, r6, r7, r8, lr}      @ 08017100
    @ r4 = mode, r5 = decimal-point position, r6 = value, r7 = skip-when-held flag
    movs r4, r0                              @ 08017104
    movs r5, r1                              @ 08017106
    movs r6, r2                              @ 08017108
    movs r7, r3                              @ 0801710A
    movs.w r8, #0                            @ 0801710C
    @ r3 = 1: draw only if hold is not active
    uxtb r7, r7                              @ 08017110
    cmp r7, #0                               @ 08017112
    beq .L08017120                           @ 08017114
    ldr r0, =hold_active                     @ 08017116 &hold_active
    ldrb r0, [r0, #0]                        @ 0801711A
    cmp r0, #0                               @ 0801711C branch if hold_active != 0
    bne .L0801717A                           @ 0801711E
.L08017120:                                @ reached from 08017114 beq (equal / zero); falls in
    @ set the decimal point (fn_0801717E), then sign and magnitude
    movs r0, r5                              @ 08017120
    uxtb r0, r0                              @ 08017122
    bl fn_0801717E                           @ 08017124
    @ negative value: set the main minus sign and use the magnitude; otherwise clear the sign
    cmp r6, #0                               @ 08017128
    bpl .L08017142                           @ 0801712A
    negs r0, r6                              @ 0801712C
    mov r8, r0                               @ 0801712E
    ldr r0, =lcd_shadow                      @ 08017130 &LCD shadow
    ldr r0, [r0, #12]                        @ 08017134
    orrs.w r0, r0, #128                      @ 08017136
    ldr r1, =lcd_shadow                      @ 0801713A &LCD shadow
    str r0, [r1, #12]                        @ 0801713E w3 |= 0x80: main minus
    b .L08017154                             @ 08017140
.L08017142:                                @ reached from 0801712A bpl (positive or zero)
    mov r8, r6                               @ 08017142
    ldr r0, =lcd_shadow                      @ 08017144 &LCD shadow
    ldr r0, [r0, #12]                        @ 08017148
    bics.w r0, r0, #128                      @ 0801714A
    ldr r1, =lcd_shadow                      @ 0801714E &LCD shadow
    str r0, [r1, #12]                        @ 08017152 w3 &= ~0x80: clears main minus
.L08017154:                                @ reached from 08017140 b; falls in
    @ five digits of the magnitude (fn_0801B090), leading zeros blanked (fn_0801B130), main display (lcd_draw_5char)
    mov r0, r8                               @ 08017154
    bl fn_0801B090                           @ 08017156
    movs r0, r5                              @ 0801715A
    uxtb r0, r0                              @ 0801715C
    bl fn_0801B130                           @ 0801715E
    ldr r1, =v_20007C30                      @ 08017162 &5-char text buffer
    movs r0, #0                              @ 08017166
    bl lcd_draw_5char                        @ 08017168
    @ ask for a commit and remember the drawn value in 0x20007D70 (the value the BLE status packet reports)

    movs r0, #1                              @ 0801716C
    ldr r1, =v_2000805B                      @ 0801716E &LCD commit request
    strb r0, [r1, #0]                        @ 08017172
    ldr r0, =v_20007D70                      @ 08017174 &last drawn main value
    str r6, [r0, #0]                         @ 08017178
.L0801717A:                                @ reached from 0801711E bne (not equal / non-zero); falls in
    ldmia.w sp!, {r4, r5, r6, r7, r8, pc}    @ 0801717A
ENDFUNC lcd_show_value_pos5_9
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801717E - set the main-display decimal point
@ Replaces : 0x0801717E FUN_0801717E (v2.05, 124 bytes)
@ In       : r0 = decimal-point position d (0 = none, 1..4); the point sits right of main digit (5 + 4 - d)
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow words 0 (bit 14) and 1 (bits 1, 3, 5)
@ Spec     : analysis/lcd_map.md 2: d = 1 w0b14, d = 2 w1b1, d = 3 w1b3, d = 4 w1b5; the other points are cleared first
@            (w0 clear mask 0x4000, w1 keeps mask 0xFD5)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801717E
    ldr r1, =lcd_shadow                      @ 0801717E &LCD shadow
    ldr r1, [r1, #0]                         @ 08017182
    bics.w r1, r1, #16384                    @ 08017184
    ldr r2, =lcd_shadow                      @ 08017188 &LCD shadow
    str r1, [r2, #0]                         @ 0801718C w0 &= ~0x4000: clears main dp1 (seg4dp)
    ldr r1, =lcd_shadow                      @ 0801718E &LCD shadow
    ldr r1, [r1, #4]                         @ 08017192
    movw r2, #4053                           @ 08017194
    ands r1, r2                              @ 08017198
    ldr r2, =lcd_shadow                      @ 0801719A &LCD shadow
    str r1, [r2, #4]                         @ 0801719E w1 &= 0xFD5: clears 23 bits
    uxtb r0, r0                              @ 080171A0
    cmp r0, #1                               @ 080171A2
    beq .L080171E8                           @ 080171A4
    bcc .L080171F8                           @ 080171A6
    cmp r0, #3                               @ 080171A8
    beq .L080171C4                           @ 080171AA
    bcc .L080171D6                           @ 080171AC
    cmp r0, #4                               @ 080171AE
    bne .L080171F8                           @ 080171B0
    ldr r1, =lcd_shadow                      @ 080171B2 &LCD shadow
    ldr r1, [r1, #4]                         @ 080171B6
    orrs.w r1, r1, #32                       @ 080171B8
    ldr r2, =lcd_shadow                      @ 080171BC &LCD shadow
    str r1, [r2, #4]                         @ 080171C0 w1 |= 0x20: main dp4 (seg1dp)
    b .L080171F8                             @ 080171C2
.L080171C4:                                @ reached from 080171AA beq (equal / zero)
    ldr r1, =lcd_shadow                      @ 080171C4 &LCD shadow
    ldr r1, [r1, #4]                         @ 080171C8
    orrs.w r1, r1, #8                        @ 080171CA
    ldr r2, =lcd_shadow                      @ 080171CE &LCD shadow
    str r1, [r2, #4]                         @ 080171D2 w1 |= 0x8: main dp3 (seg2dp)
    b .L080171F8                             @ 080171D4
.L080171D6:                                @ reached from 080171AC bcc (unsigned <)
    ldr r1, =lcd_shadow                      @ 080171D6 &LCD shadow
    ldr r1, [r1, #4]                         @ 080171DA
    orrs.w r1, r1, #2                        @ 080171DC
    ldr r2, =lcd_shadow                      @ 080171E0 &LCD shadow
    str r1, [r2, #4]                         @ 080171E4 w1 |= 0x2: main dp2 (seg3dp)
    b .L080171F8                             @ 080171E6
.L080171E8:                                @ reached from 080171A4 beq (equal / zero)
    ldr r1, =lcd_shadow                      @ 080171E8 &LCD shadow
    ldr r1, [r1, #0]                         @ 080171EC
    orrs.w r1, r1, #16384                    @ 080171EE
    ldr r2, =lcd_shadow                      @ 080171F2 &LCD shadow
    str r1, [r2, #0]                         @ 080171F6 w0 |= 0x4000: main dp1 (seg4dp)
.L080171F8:                                @ reached from 080171A6 bcc (unsigned <); 080171B0 bne (not equal / non-zero); 080171C2 b; 080171D4 b; 080171E6 b; falls in
    bx lr                                    @ 080171F8
ENDFUNC fn_0801717E
    .ltorg
    .global lcd_main_dp
    .set lcd_main_dp, fn_0801717E

@ -----------------------------------------------------------------------------
@ lcd_show_value_pos0_4 - draw a signed value on the sub display
@ Replaces : 0x08017F28 lcd_show_value_pos0_4 (v2.05, 108 bytes)
@ In       : r0 = signed value, r1 = decimal-point position d (0..4), r2 = 0 request a deferred commit (set 0x2000805B),
@            non-zero commit now
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow (sub minus sign w4 bit 29, digits, decimal point), 0x20007C30, 0x20007DB0..DC0, 0x2000805B
@ Spec     : analysis/lcd_map.md 2 (positions 0..4 = sub display, sign w4b29)
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC lcd_show_value_pos0_4
    push {r3, r4, r5, r6, r7, lr}            @ 08017F28
    movs r4, r0                              @ 08017F2A
    movs r5, r1                              @ 08017F2C
    movs r6, r2                              @ 08017F2E
    movs r7, #0                              @ 08017F30
    @ negative value: set the sub minus sign and use the magnitude; otherwise clear the sign
    cmp r4, #0                               @ 08017F32
    bpl .L08017F4C                           @ 08017F34
    negs r0, r4                              @ 08017F36
    movs r7, r0                              @ 08017F38
    ldr r0, =lcd_shadow                      @ 08017F3A &LCD shadow
    ldr r0, [r0, #16]                        @ 08017F3E
    orrs.w r0, r0, #536870912                @ 08017F40
    ldr r1, =lcd_shadow                      @ 08017F44 &LCD shadow
    str r0, [r1, #16]                        @ 08017F48 w4 |= 0x20000000: sub minus
    b .L08017F5E                             @ 08017F4A
.L08017F4C:                                @ reached from 08017F34 bpl (positive or zero)
    movs r7, r4                              @ 08017F4C
    ldr r0, =lcd_shadow                      @ 08017F4E &LCD shadow
    ldr r0, [r0, #16]                        @ 08017F52
    bics.w r0, r0, #536870912                @ 08017F54
    ldr r1, =lcd_shadow                      @ 08017F58 &LCD shadow
    str r0, [r1, #16]                        @ 08017F5C w4 &= ~0x20000000: clears sub minus
.L08017F5E:                                @ reached from 08017F4A b; falls in
    @ decimal point (fn_08017FB4), five digits, leading zeros blanked, sub display
    movs r0, r5                              @ 08017F5E
    uxtb r0, r0                              @ 08017F60
    bl fn_08017FB4                           @ 08017F62
    movs r0, r7                              @ 08017F66
    bl fn_0801B090                           @ 08017F68
    movs r0, r5                              @ 08017F6C
    uxtb r0, r0                              @ 08017F6E
    bl fn_0801B130                           @ 08017F70
    ldr r1, =v_20007C30                      @ 08017F74 &5-char text buffer
    movs r0, #1                              @ 08017F78
    bl lcd_draw_5char                        @ 08017F7A
    @ r2 = 0: only request a commit (0x2000805B); otherwise lcd_commit_shadow now

    uxtb r6, r6                              @ 08017F7E
    cmp r6, #0                               @ 08017F80
    bne .L08017F8E                           @ 08017F82
    movs r0, #1                              @ 08017F84
    ldr r1, =v_2000805B                      @ 08017F86 &LCD commit request
    strb r0, [r1, #0]                        @ 08017F8A
    b .L08017F92                             @ 08017F8C
.L08017F8E:                                @ reached from 08017F82 bne (not equal / non-zero)
    bl lcd_commit_shadow                     @ 08017F8E
.L08017F92:                                @ reached from 08017F8C b; falls in
    pop {r0, r4, r5, r6, r7, pc}             @ 08017F92
ENDFUNC lcd_show_value_pos0_4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08017FB4 - set the sub-display decimal point
@ Replaces : 0x08017FB4 FUN_08017FB4 (v2.05, 106 bytes)
@ In       : r0 = decimal-point position d (0 = none, 1..4)
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow word 0 (bits 21, 23, 25, 27)
@ Spec     : analysis/lcd_map.md 2: d = 1 w0b21, d = 2 w0b23, d = 3 w0b25, d = 4 w0b27; all four are cleared first (w0 clear mask 0x0AA00000)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08017FB4
    ldr r1, =lcd_shadow                      @ 08017FB4 &LCD shadow
    ldr r1, [r1, #0]                         @ 08017FB8
    bics.w r1, r1, #178257920                @ 08017FBA
    ldr r2, =lcd_shadow                      @ 08017FBE &LCD shadow
    str r1, [r2, #0]                         @ 08017FC2 w0 &= ~0xAA00000: clears sub dp1 (sub4dp); sub dp2 (sub3dp); sub dp3 (sub2dp); sub dp4 (sub1dp)
    uxtb r0, r0                              @ 08017FC4
    cmp r0, #1                               @ 08017FC6
    beq .L0801800C                           @ 08017FC8
    bcc .L0801801C                           @ 08017FCA
    cmp r0, #3                               @ 08017FCC
    beq .L08017FE8                           @ 08017FCE
    bcc .L08017FFA                           @ 08017FD0
    cmp r0, #4                               @ 08017FD2
    bne .L0801801C                           @ 08017FD4
    ldr r1, =lcd_shadow                      @ 08017FD6 &LCD shadow
    ldr r1, [r1, #0]                         @ 08017FDA
    orrs.w r1, r1, #134217728                @ 08017FDC
    ldr r2, =lcd_shadow                      @ 08017FE0 &LCD shadow
    str r1, [r2, #0]                         @ 08017FE4 w0 |= 0x8000000: sub dp4 (sub1dp)
    b .L0801801C                             @ 08017FE6
.L08017FE8:                                @ reached from 08017FCE beq (equal / zero)
    ldr r1, =lcd_shadow                      @ 08017FE8 &LCD shadow
    ldr r1, [r1, #0]                         @ 08017FEC
    orrs.w r1, r1, #33554432                 @ 08017FEE
    ldr r2, =lcd_shadow                      @ 08017FF2 &LCD shadow
    str r1, [r2, #0]                         @ 08017FF6 w0 |= 0x2000000: sub dp3 (sub2dp)
    b .L0801801C                             @ 08017FF8
.L08017FFA:                                @ reached from 08017FD0 bcc (unsigned <)
    ldr r1, =lcd_shadow                      @ 08017FFA &LCD shadow
    ldr r1, [r1, #0]                         @ 08017FFE
    orrs.w r1, r1, #8388608                  @ 08018000
    ldr r2, =lcd_shadow                      @ 08018004 &LCD shadow
    str r1, [r2, #0]                         @ 08018008 w0 |= 0x800000: sub dp2 (sub3dp)
    b .L0801801C                             @ 0801800A
.L0801800C:                                @ reached from 08017FC8 beq (equal / zero)
    ldr r1, =lcd_shadow                      @ 0801800C &LCD shadow
    ldr r1, [r1, #0]                         @ 08018010
    orrs.w r1, r1, #2097152                  @ 08018012
    ldr r2, =lcd_shadow                      @ 08018016 &LCD shadow
    str r1, [r2, #0]                         @ 0801801A w0 |= 0x200000: sub dp1 (sub4dp)
.L0801801C:                                @ reached from 08017FCA bcc (unsigned <); 08017FD4 bne (not equal / non-zero); 08017FE6 b; 08017FF8 b; 0801800A b; falls in
    bx lr                                    @ 0801801C
ENDFUNC fn_08017FB4
    .ltorg
    .global lcd_sub_dp
    .set lcd_sub_dp, fn_08017FB4

@ -----------------------------------------------------------------------------
@ lcd_draw_5char - draw five characters from a buffer on the main or the sub display
@ Replaces : 0x08019AE0 lcd_draw_5char (v2.05, 50 bytes)
@ In       : r0 = display (0 = main, positions 5..9; non-zero = sub, positions 0..4), r1 = pointer to five character codes
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow (through lcd_draw_glyph)
@ Spec     : analysis/lcd_map.md 2
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC lcd_draw_5char
    push {r3, r4, r5, r6, r7, lr}            @ 08019AE0
    movs r4, r0                              @ 08019AE2
    movs r5, r1                              @ 08019AE4
    @ r6 = characters done, r4 = display, r5 = buffer pointer, r7 = position
    movs r6, #0                              @ 08019AE6
    @ display 0 -> first position 5, otherwise 0
    uxtb r4, r4                              @ 08019AE8
    cmp r4, #0                               @ 08019AEA
    bne .L08019AF4                           @ 08019AEC
    movs r0, #5                              @ 08019AEE
    movs r7, r0                              @ 08019AF0
    b .L08019AF8                             @ 08019AF2
.L08019AF4:                                @ reached from 08019AEC bne (not equal / non-zero)
    movs r0, #0                              @ 08019AF4
    movs r7, r0                              @ 08019AF6
.L08019AF8:                                @ reached from 08019AF2 b; 08019B0E b; falls in
    @ one character: lcd_draw_glyph(buffer[i], position)
    movs r1, r7                              @ 08019AF8
    uxtb r1, r1                              @ 08019AFA
    ldrb r0, [r5, #0]                        @ 08019AFC
    bl lcd_draw_glyph                        @ 08019AFE
    @ five characters drawn?

    adds r6, r6, #1                          @ 08019B02
    uxtb r6, r6                              @ 08019B04
    cmp r6, #5                               @ 08019B06
    bge .L08019B10                           @ 08019B08
    adds r5, r5, #1                          @ 08019B0A
    adds r7, r7, #1                          @ 08019B0C
    b .L08019AF8                             @ 08019B0E
.L08019B10:                                @ reached from 08019B08 bge (signed >=)
    pop {r0, r4, r5, r6, r7, pc}             @ 08019B10
ENDFUNC lcd_draw_5char
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019B12 - draw one character from a buffer at a position
@ Replaces : 0x08019B12 FUN_08019B12 (v2.05, 18 bytes)
@ In       : r0 = position 0..9, r1 = pointer to the character
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow (through lcd_draw_glyph)
@ Spec     : analysis/lcd_map.md 2
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019B12
    push {r3, r4, r5, lr}                    @ 08019B12
    movs r4, r0                              @ 08019B14
    movs r5, r1                              @ 08019B16
    movs r1, r4                              @ 08019B18
    uxtb r1, r1                              @ 08019B1A
    ldrb r0, [r5, #0]                        @ 08019B1C
    bl lcd_draw_glyph                        @ 08019B1E
    pop {r0, r4, r5, pc}                     @ 08019B22
ENDFUNC fn_08019B12
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019B24 - draw two characters from a buffer at consecutive positions
@ Replaces : 0x08019B24 FUN_08019B24 (v2.05, 36 bytes)
@ In       : r0 = first position 0..8, r1 = pointer to two character codes
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow (through lcd_draw_glyph)
@ Spec     : analysis/lcd_map.md 2
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019B24
    push {r3, r4, r5, r6, r7, lr}            @ 08019B24
    movs r4, r0                              @ 08019B26
    movs r5, r1                              @ 08019B28
    movs r6, #0                              @ 08019B2A
    movs r7, r4                              @ 08019B2C
.L08019B2E:                                @ reached from 08019B44 b; falls in
    movs r1, r7                              @ 08019B2E
    uxtb r1, r1                              @ 08019B30
    ldrb r0, [r5, #0]                        @ 08019B32
    bl lcd_draw_glyph                        @ 08019B34
    adds r6, r6, #1                          @ 08019B38
    uxtb r6, r6                              @ 08019B3A
    cmp r6, #2                               @ 08019B3C
    bge .L08019B46                           @ 08019B3E
    adds r5, r5, #1                          @ 08019B40
    adds r7, r7, #1                          @ 08019B42
    b .L08019B2E                             @ 08019B44
.L08019B46:                                @ reached from 08019B3E bge (signed >=)
    pop {r0, r4, r5, r6, r7, pc}             @ 08019B46
ENDFUNC fn_08019B24
    .ltorg

@ -----------------------------------------------------------------------------
@ lcd_draw_glyph - draw one character at a display position (0..4 sub display, 5..9 main display)
@ Replaces : 0x0801A950 lcd_draw_glyph (v2.05, 1702 bytes)
@ In       : r0 = character code, r1 = position 0..9 (other positions draw nothing)
@ Out      : -
@ Context  : main only
@ RAM      : read-modify-writes lcd_shadow words 0, 2, 4, 6 and 1, 3, 5, 7 (the positions' segment bits only)
@ Spec     : analysis/lcd_map.md 2 (table "position -> word/bit"): for position p the lower segment of the pair carries
@            COM3..0 = b, g, c, x and the upper segment COM3..0 = a, f, e, d; font bit 6 (x, the decimal-point slot)
@            is never set by the font and is not cleared here either
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC lcd_draw_glyph
    push {r4, r5, r6, lr}                    @ 0801A950
    movs r4, r0                              @ 0801A952
    movs r5, r1                              @ 0801A954
    movs r0, r4                              @ 0801A956
    uxtb r0, r0                              @ 0801A958
    @ r6 = segment byte from the font lookup
    bl fn_0801AFFC                           @ 0801A95A
    movs r6, r0                              @ 0801A95E
    @ dispatch on the position in r5: 0..9
    uxtb r5, r5                              @ 0801A960
    cmp r5, #0                               @ 0801A962
    beq .L0801A994                           @ 0801A964
    cmp r5, #2                               @ 0801A966
    beq .L0801AB4C                           @ 0801A968
    bcc .L0801AA26                           @ 0801A96C
    cmp r5, #4                               @ 0801A96E
    beq .L0801AC70                           @ 0801A970
    bcc .L0801ABDE                           @ 0801A974
    cmp r5, #6                               @ 0801A978
    beq .L0801AD9C                           @ 0801A97A
    bcc .L0801AD02                           @ 0801A97E
    cmp r5, #8                               @ 0801A982
    beq .L0801AED0                           @ 0801A984
    bcc .L0801AE36                           @ 0801A988
    cmp r5, #9                               @ 0801A98C
    beq .L0801AF62                           @ 0801A98E
    b .L0801AFF4                             @ 0801A992
.L0801A994:                                @ reached from 0801A964 beq (equal / zero)
    @ position 0 (sub display, leftmost): clear then set the segment bits of SEG27/28 in words 0, 2, 4, 6
    ldr r0, =lcd_shadow                      @ 0801A994 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A998
    bics.w r0, r0, #268435456                @ 0801A99A
    ldr r1, =lcd_shadow                      @ 0801A99E &LCD shadow
    str r0, [r1, #0]                         @ 0801A9A2 w0 &= ~0x10000000: clears digit0 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801A9A4 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A9A8
    bics.w r0, r0, #402653184                @ 0801A9AA
    ldr r1, =lcd_shadow                      @ 0801A9AE &LCD shadow
    str r0, [r1, #8]                         @ 0801A9B2 w2 &= ~0x18000000: clears digit0 seg c [sub]; digit0 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801A9B4 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801A9B8
    bics.w r0, r0, #402653184                @ 0801A9BA
    ldr r1, =lcd_shadow                      @ 0801A9BE &LCD shadow
    str r0, [r1, #16]                        @ 0801A9C2 w4 &= ~0x18000000: clears digit0 seg g [sub]; digit0 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801A9C4 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801A9C8
    bics.w r0, r0, #402653184                @ 0801A9CA
    ldr r1, =lcd_shadow                      @ 0801A9CE &LCD shadow
    str r0, [r1, #24]                        @ 0801A9D2 w6 &= ~0x18000000: clears digit0 seg b [sub]; digit0 seg a [sub]
    ldr r0, =lcd_shadow                      @ 0801A9D4 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801A9D8
    lsls r1, r6, #21                         @ 0801A9DA
    ands.w r1, r1, #402653184                @ 0801A9DC
    orrs r0, r1                              @ 0801A9E0
    ldr r1, =lcd_shadow                      @ 0801A9E2 &LCD shadow
    str r0, [r1, #0]                         @ 0801A9E6 w0 |= (r6 << 21) & 0x18000000: sub dp4 (sub1dp); digit0 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801A9E8 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801A9EC
    lsls r1, r6, #23                         @ 0801A9EE
    ands.w r1, r1, #402653184                @ 0801A9F0
    orrs r0, r1                              @ 0801A9F4
    ldr r1, =lcd_shadow                      @ 0801A9F6 &LCD shadow
    str r0, [r1, #8]                         @ 0801A9FA w2 |= (r6 << 23) & 0x18000000: digit0 seg c [sub]; digit0 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801A9FC &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AA00
    lsls r1, r6, #25                         @ 0801AA02
    ands.w r1, r1, #402653184                @ 0801AA04
    orrs r0, r1                              @ 0801AA08
    ldr r1, =lcd_shadow                      @ 0801AA0A &LCD shadow
    str r0, [r1, #16]                        @ 0801AA0E w4 |= (r6 << 25) & 0x18000000: digit0 seg g [sub]; digit0 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801AA10 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AA14
    lsls r1, r6, #27                         @ 0801AA16
    ands.w r1, r1, #402653184                @ 0801AA18
    orrs r0, r1                              @ 0801AA1C
    ldr r1, =lcd_shadow                      @ 0801AA1E &LCD shadow
    str r0, [r1, #24]                        @ 0801AA22 w6 |= (r6 << 27) & 0x18000000: digit0 seg b [sub]; digit0 seg a [sub]
    b .L0801AFF4                             @ 0801AA24
.L0801AA26:                                @ reached from 0801A96C bcc (unsigned <)
    @ position 1 (sub display, SEG25 and SEG40): words 0, 2, 4, 6 (SEG25) and 1, 3, 5, 7 (SEG40)
    ldr r0, =lcd_shadow                      @ 0801AA26 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AA2A
    ldr r1, =lcd_shadow                      @ 0801AA2C &LCD shadow
    str r0, [r1, #0]                         @ 0801AA30 w0 written back unchanged
    ldr r0, =lcd_shadow                      @ 0801AA32 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AA36
    bics.w r0, r0, #33554432                 @ 0801AA38
    ldr r1, =lcd_shadow                      @ 0801AA3C &LCD shadow
    str r0, [r1, #8]                         @ 0801AA40 w2 &= ~0x2000000: clears digit1 seg c [sub]
    ldr r0, =lcd_shadow                      @ 0801AA42 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AA46
    bics.w r0, r0, #33554432                 @ 0801AA48
    ldr r1, =lcd_shadow                      @ 0801AA4C &LCD shadow
    str r0, [r1, #16]                        @ 0801AA50 w4 &= ~0x2000000: clears digit1 seg g [sub]
    ldr r0, =lcd_shadow                      @ 0801AA52 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AA56
    bics.w r0, r0, #33554432                 @ 0801AA58
    ldr r1, =lcd_shadow                      @ 0801AA5C &LCD shadow
    str r0, [r1, #24]                        @ 0801AA60 w6 &= ~0x2000000: clears digit1 seg b [sub]
    ldr r0, =lcd_shadow                      @ 0801AA62 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AA66
    lsls r1, r6, #19                         @ 0801AA68
    ands.w r1, r1, #33554432                 @ 0801AA6A
    orrs r0, r1                              @ 0801AA6E
    ldr r1, =lcd_shadow                      @ 0801AA70 &LCD shadow
    str r0, [r1, #0]                         @ 0801AA74 w0 |= (r6 << 19) & 0x2000000: sub dp3 (sub2dp)
    ldr r0, =lcd_shadow                      @ 0801AA76 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AA7A
    lsls r1, r6, #21                         @ 0801AA7C
    ands.w r1, r1, #33554432                 @ 0801AA7E
    orrs r0, r1                              @ 0801AA82
    ldr r1, =lcd_shadow                      @ 0801AA84 &LCD shadow
    str r0, [r1, #8]                         @ 0801AA88 w2 |= (r6 << 21) & 0x2000000: digit1 seg c [sub]
    ldr r0, =lcd_shadow                      @ 0801AA8A &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AA8E
    lsls r1, r6, #23                         @ 0801AA90
    ands.w r1, r1, #33554432                 @ 0801AA92
    orrs r0, r1                              @ 0801AA96
    ldr r1, =lcd_shadow                      @ 0801AA98 &LCD shadow
    str r0, [r1, #16]                        @ 0801AA9C w4 |= (r6 << 23) & 0x2000000: digit1 seg g [sub]
    ldr r0, =lcd_shadow                      @ 0801AA9E &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AAA2
    lsls r1, r6, #25                         @ 0801AAA4
    ands.w r1, r1, #33554432                 @ 0801AAA6
    orrs r0, r1                              @ 0801AAAA
    ldr r1, =lcd_shadow                      @ 0801AAAC &LCD shadow
    str r0, [r1, #24]                        @ 0801AAB0 w6 |= (r6 << 25) & 0x2000000: digit1 seg b [sub]
    ldr r0, =lcd_shadow                      @ 0801AAB2 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801AAB6
    movw r1, #3839                           @ 0801AAB8
    ands r0, r1                              @ 0801AABC
    ldr r1, =lcd_shadow                      @ 0801AABE &LCD shadow
    str r0, [r1, #4]                         @ 0801AAC2 w1 &= 0xEFF: clears 21 bits
    ldr r0, =lcd_shadow                      @ 0801AAC4 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801AAC8
    movw r1, #3839                           @ 0801AACA
    ands r0, r1                              @ 0801AACE
    ldr r1, =lcd_shadow                      @ 0801AAD0 &LCD shadow
    str r0, [r1, #12]                        @ 0801AAD4 w3 &= 0xEFF: clears 21 bits
    ldr r0, =lcd_shadow                      @ 0801AAD6 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801AADA
    movw r1, #3839                           @ 0801AADC
    ands r0, r1                              @ 0801AAE0
    ldr r1, =lcd_shadow                      @ 0801AAE2 &LCD shadow
    str r0, [r1, #20]                        @ 0801AAE6 w5 &= 0xEFF: clears 21 bits
    ldr r0, =lcd_shadow                      @ 0801AAE8 &LCD shadow
    ldr r0, [r0, #28]                        @ 0801AAEC
    movw r1, #3839                           @ 0801AAEE
    ands r0, r1                              @ 0801AAF2
    ldr r1, =lcd_shadow                      @ 0801AAF4 &LCD shadow
    str r0, [r1, #28]                        @ 0801AAF8 w7 &= 0xEFF: clears 21 bits
    ldr r0, =lcd_shadow                      @ 0801AAFA &LCD shadow
    ldr r0, [r0, #4]                         @ 0801AAFE
    lsls r1, r6, #1                          @ 0801AB00
    ands.w r1, r1, #256                      @ 0801AB02
    orrs r0, r1                              @ 0801AB06
    ldr r1, =lcd_shadow                      @ 0801AB08 &LCD shadow
    str r0, [r1, #4]                         @ 0801AB0C w1 |= (r6 << 1) & 0x100: digit1 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801AB0E &LCD shadow
    ldr r0, [r0, #12]                        @ 0801AB12
    lsls r1, r6, #3                          @ 0801AB14
    ands.w r1, r1, #256                      @ 0801AB16
    orrs r0, r1                              @ 0801AB1A
    ldr r1, =lcd_shadow                      @ 0801AB1C &LCD shadow
    str r0, [r1, #12]                        @ 0801AB20 w3 |= (r6 << 3) & 0x100: digit1 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801AB22 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801AB26
    lsls r1, r6, #5                          @ 0801AB28
    ands.w r1, r1, #256                      @ 0801AB2A
    orrs r0, r1                              @ 0801AB2E
    ldr r1, =lcd_shadow                      @ 0801AB30 &LCD shadow
    str r0, [r1, #20]                        @ 0801AB34 w5 |= (r6 << 5) & 0x100: digit1 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801AB36 &LCD shadow
    ldr r0, [r0, #28]                        @ 0801AB3A
    lsls r1, r6, #7                          @ 0801AB3C
    ands.w r1, r1, #256                      @ 0801AB3E
    orrs r0, r1                              @ 0801AB42
    ldr r1, =lcd_shadow                      @ 0801AB44 &LCD shadow
    str r0, [r1, #28]                        @ 0801AB48 w7 |= (r6 << 7) & 0x100: digit1 seg a [sub]
    b .L0801AFF4                             @ 0801AB4A
.L0801AB4C:                                @ reached from 0801A968 beq (equal / zero)
    @ position 2 (sub display, SEG23/24)
    ldr r0, =lcd_shadow                      @ 0801AB4C &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AB50
    bics.w r0, r0, #16777216                 @ 0801AB52
    ldr r1, =lcd_shadow                      @ 0801AB56 &LCD shadow
    str r0, [r1, #0]                         @ 0801AB5A w0 &= ~0x1000000: clears digit2 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801AB5C &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AB60
    bics.w r0, r0, #25165824                 @ 0801AB62
    ldr r1, =lcd_shadow                      @ 0801AB66 &LCD shadow
    str r0, [r1, #8]                         @ 0801AB6A w2 &= ~0x1800000: clears digit2 seg c [sub]; digit2 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801AB6C &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AB70
    bics.w r0, r0, #25165824                 @ 0801AB72
    ldr r1, =lcd_shadow                      @ 0801AB76 &LCD shadow
    str r0, [r1, #16]                        @ 0801AB7A w4 &= ~0x1800000: clears digit2 seg g [sub]; digit2 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801AB7C &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AB80
    bics.w r0, r0, #25165824                 @ 0801AB82
    ldr r1, =lcd_shadow                      @ 0801AB86 &LCD shadow
    str r0, [r1, #24]                        @ 0801AB8A w6 &= ~0x1800000: clears digit2 seg b [sub]; digit2 seg a [sub]
    ldr r0, =lcd_shadow                      @ 0801AB8C &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AB90
    lsls r1, r6, #17                         @ 0801AB92
    ands.w r1, r1, #25165824                 @ 0801AB94
    orrs r0, r1                              @ 0801AB98
    ldr r1, =lcd_shadow                      @ 0801AB9A &LCD shadow
    str r0, [r1, #0]                         @ 0801AB9E w0 |= (r6 << 17) & 0x1800000: sub dp2 (sub3dp); digit2 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801ABA0 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801ABA4
    lsls r1, r6, #19                         @ 0801ABA6
    ands.w r1, r1, #25165824                 @ 0801ABA8
    orrs r0, r1                              @ 0801ABAC
    ldr r1, =lcd_shadow                      @ 0801ABAE &LCD shadow
    str r0, [r1, #8]                         @ 0801ABB2 w2 |= (r6 << 19) & 0x1800000: digit2 seg c [sub]; digit2 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801ABB4 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801ABB8
    lsls r1, r6, #21                         @ 0801ABBA
    ands.w r1, r1, #25165824                 @ 0801ABBC
    orrs r0, r1                              @ 0801ABC0
    ldr r1, =lcd_shadow                      @ 0801ABC2 &LCD shadow
    str r0, [r1, #16]                        @ 0801ABC6 w4 |= (r6 << 21) & 0x1800000: digit2 seg g [sub]; digit2 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801ABC8 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801ABCC
    lsls r1, r6, #23                         @ 0801ABCE
    ands.w r1, r1, #25165824                 @ 0801ABD0
    orrs r0, r1                              @ 0801ABD4
    ldr r1, =lcd_shadow                      @ 0801ABD6 &LCD shadow
    str r0, [r1, #24]                        @ 0801ABDA w6 |= (r6 << 23) & 0x1800000: digit2 seg b [sub]; digit2 seg a [sub]
    b .L0801AFF4                             @ 0801ABDC
.L0801ABDE:                                @ reached from 0801A974 bcc (unsigned <)
    @ position 3 (sub display, SEG21/22)
    ldr r0, =lcd_shadow                      @ 0801ABDE &LCD shadow
    ldr r0, [r0, #0]                         @ 0801ABE2
    bics.w r0, r0, #4194304                  @ 0801ABE4
    ldr r1, =lcd_shadow                      @ 0801ABE8 &LCD shadow
    str r0, [r1, #0]                         @ 0801ABEC w0 &= ~0x400000: clears digit3 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801ABEE &LCD shadow
    ldr r0, [r0, #8]                         @ 0801ABF2
    bics.w r0, r0, #6291456                  @ 0801ABF4
    ldr r1, =lcd_shadow                      @ 0801ABF8 &LCD shadow
    str r0, [r1, #8]                         @ 0801ABFC w2 &= ~0x600000: clears digit3 seg c [sub]; digit3 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801ABFE &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AC02
    bics.w r0, r0, #6291456                  @ 0801AC04
    ldr r1, =lcd_shadow                      @ 0801AC08 &LCD shadow
    str r0, [r1, #16]                        @ 0801AC0C w4 &= ~0x600000: clears digit3 seg g [sub]; digit3 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801AC0E &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AC12
    bics.w r0, r0, #6291456                  @ 0801AC14
    ldr r1, =lcd_shadow                      @ 0801AC18 &LCD shadow
    str r0, [r1, #24]                        @ 0801AC1C w6 &= ~0x600000: clears digit3 seg b [sub]; digit3 seg a [sub]
    ldr r0, =lcd_shadow                      @ 0801AC1E &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AC22
    lsls r1, r6, #15                         @ 0801AC24
    ands.w r1, r1, #6291456                  @ 0801AC26
    orrs r0, r1                              @ 0801AC2A
    ldr r1, =lcd_shadow                      @ 0801AC2C &LCD shadow
    str r0, [r1, #0]                         @ 0801AC30 w0 |= (r6 << 15) & 0x600000: sub dp1 (sub4dp); digit3 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801AC32 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AC36
    lsls r1, r6, #17                         @ 0801AC38
    ands.w r1, r1, #6291456                  @ 0801AC3A
    orrs r0, r1                              @ 0801AC3E
    ldr r1, =lcd_shadow                      @ 0801AC40 &LCD shadow
    str r0, [r1, #8]                         @ 0801AC44 w2 |= (r6 << 17) & 0x600000: digit3 seg c [sub]; digit3 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801AC46 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AC4A
    lsls r1, r6, #19                         @ 0801AC4C
    ands.w r1, r1, #6291456                  @ 0801AC4E
    orrs r0, r1                              @ 0801AC52
    ldr r1, =lcd_shadow                      @ 0801AC54 &LCD shadow
    str r0, [r1, #16]                        @ 0801AC58 w4 |= (r6 << 19) & 0x600000: digit3 seg g [sub]; digit3 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801AC5A &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AC5E
    lsls r1, r6, #21                         @ 0801AC60
    ands.w r1, r1, #6291456                  @ 0801AC62
    orrs r0, r1                              @ 0801AC66
    ldr r1, =lcd_shadow                      @ 0801AC68 &LCD shadow
    str r0, [r1, #24]                        @ 0801AC6C w6 |= (r6 << 21) & 0x600000: digit3 seg b [sub]; digit3 seg a [sub]
    b .L0801AFF4                             @ 0801AC6E
.L0801AC70:                                @ reached from 0801A970 beq (equal / zero)
    @ position 4 (sub display, rightmost, SEG19/20)
    ldr r0, =lcd_shadow                      @ 0801AC70 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AC74
    bics.w r0, r0, #1048576                  @ 0801AC76
    ldr r1, =lcd_shadow                      @ 0801AC7A &LCD shadow
    str r0, [r1, #0]                         @ 0801AC7E w0 &= ~0x100000: clears digit4 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801AC80 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AC84
    bics.w r0, r0, #1572864                  @ 0801AC86
    ldr r1, =lcd_shadow                      @ 0801AC8A &LCD shadow
    str r0, [r1, #8]                         @ 0801AC8E w2 &= ~0x180000: clears digit4 seg c [sub]; digit4 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801AC90 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AC94
    bics.w r0, r0, #1572864                  @ 0801AC96
    ldr r1, =lcd_shadow                      @ 0801AC9A &LCD shadow
    str r0, [r1, #16]                        @ 0801AC9E w4 &= ~0x180000: clears digit4 seg g [sub]; digit4 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801ACA0 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801ACA4
    bics.w r0, r0, #1572864                  @ 0801ACA6
    ldr r1, =lcd_shadow                      @ 0801ACAA &LCD shadow
    str r0, [r1, #24]                        @ 0801ACAE w6 &= ~0x180000: clears digit4 seg b [sub]; digit4 seg a [sub]
    ldr r0, =lcd_shadow                      @ 0801ACB0 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801ACB4
    lsls r1, r6, #13                         @ 0801ACB6
    ands.w r1, r1, #1572864                  @ 0801ACB8
    orrs r0, r1                              @ 0801ACBC
    ldr r1, =lcd_shadow                      @ 0801ACBE &LCD shadow
    str r0, [r1, #0]                         @ 0801ACC2 w0 |= (r6 << 13) & 0x180000: sub dB (SubdB; the digit-4 x slot); digit4 seg d [sub]
    ldr r0, =lcd_shadow                      @ 0801ACC4 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801ACC8
    lsls r1, r6, #15                         @ 0801ACCA
    ands.w r1, r1, #1572864                  @ 0801ACCC
    orrs r0, r1                              @ 0801ACD0
    ldr r1, =lcd_shadow                      @ 0801ACD2 &LCD shadow
    str r0, [r1, #8]                         @ 0801ACD6 w2 |= (r6 << 15) & 0x180000: digit4 seg c [sub]; digit4 seg e [sub]
    ldr r0, =lcd_shadow                      @ 0801ACD8 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801ACDC
    lsls r1, r6, #17                         @ 0801ACDE
    ands.w r1, r1, #1572864                  @ 0801ACE0
    orrs r0, r1                              @ 0801ACE4
    ldr r1, =lcd_shadow                      @ 0801ACE6 &LCD shadow
    str r0, [r1, #16]                        @ 0801ACEA w4 |= (r6 << 17) & 0x180000: digit4 seg g [sub]; digit4 seg f [sub]
    ldr r0, =lcd_shadow                      @ 0801ACEC &LCD shadow
    ldr r0, [r0, #24]                        @ 0801ACF0
    lsls r1, r6, #19                         @ 0801ACF2
    ands.w r1, r1, #1572864                  @ 0801ACF4
    orrs r0, r1                              @ 0801ACF8
    ldr r1, =lcd_shadow                      @ 0801ACFA &LCD shadow
    str r0, [r1, #24]                        @ 0801ACFE w6 |= (r6 << 19) & 0x180000: digit4 seg b [sub]; digit4 seg a [sub]
    b .L0801AFF4                             @ 0801AD00
.L0801AD02:                                @ reached from 0801A97E bcc (unsigned <)
    @ position 5 (main display, leftmost, SEG37/38): words 1, 3, 5, 7
    ldr r0, =lcd_shadow                      @ 0801AD02 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801AD06
    movw r1, #4031                           @ 0801AD08
    ands r0, r1                              @ 0801AD0C
    ldr r1, =lcd_shadow                      @ 0801AD0E &LCD shadow
    str r0, [r1, #4]                         @ 0801AD12 w1 &= 0xFBF: clears 21 bits
    ldr r0, =lcd_shadow                      @ 0801AD14 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801AD18
    movw r1, #3999                           @ 0801AD1A
    ands r0, r1                              @ 0801AD1E
    ldr r1, =lcd_shadow                      @ 0801AD20 &LCD shadow
    str r0, [r1, #12]                        @ 0801AD24 w3 &= 0xF9F: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801AD26 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801AD2A
    movw r1, #3999                           @ 0801AD2C
    ands r0, r1                              @ 0801AD30
    ldr r1, =lcd_shadow                      @ 0801AD32 &LCD shadow
    str r0, [r1, #20]                        @ 0801AD36 w5 &= 0xF9F: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801AD38 &LCD shadow
    ldr r0, [r0, #28]                        @ 0801AD3C
    movw r1, #3999                           @ 0801AD3E
    ands r0, r1                              @ 0801AD42
    ldr r1, =lcd_shadow                      @ 0801AD44 &LCD shadow
    str r0, [r1, #28]                        @ 0801AD48 w7 &= 0xF9F: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801AD4A &LCD shadow
    ldr r0, [r0, #4]                         @ 0801AD4E
    lsrs r1, r6, #1                          @ 0801AD50
    ands.w r1, r1, #96                       @ 0801AD52
    orrs r0, r1                              @ 0801AD56
    ldr r1, =lcd_shadow                      @ 0801AD58 &LCD shadow
    str r0, [r1, #4]                         @ 0801AD5C w1 |= (r6 >> 1) & 0x60: main dp4 (seg1dp); digit5 seg d [main]
    ldr r0, =lcd_shadow                      @ 0801AD5E &LCD shadow
    ldr r0, [r0, #12]                        @ 0801AD62
    lsls r1, r6, #1                          @ 0801AD64
    ands.w r1, r1, #96                       @ 0801AD66
    orrs r0, r1                              @ 0801AD6A
    ldr r1, =lcd_shadow                      @ 0801AD6C &LCD shadow
    str r0, [r1, #12]                        @ 0801AD70 w3 |= (r6 << 1) & 0x60: digit5 seg c [main]; digit5 seg e [main]
    ldr r0, =lcd_shadow                      @ 0801AD72 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801AD76
    lsls r1, r6, #3                          @ 0801AD78
    ands.w r1, r1, #96                       @ 0801AD7A
    orrs r0, r1                              @ 0801AD7E
    ldr r1, =lcd_shadow                      @ 0801AD80 &LCD shadow
    str r0, [r1, #20]                        @ 0801AD84 w5 |= (r6 << 3) & 0x60: digit5 seg g [main]; digit5 seg f [main]
    ldr r0, =lcd_shadow                      @ 0801AD86 &LCD shadow
    ldr r0, [r0, #28]                        @ 0801AD8A
    lsls r1, r6, #5                          @ 0801AD8C
    ands.w r1, r1, #96                       @ 0801AD8E
    orrs r0, r1                              @ 0801AD92
    ldr r1, =lcd_shadow                      @ 0801AD94 &LCD shadow
    str r0, [r1, #28]                        @ 0801AD98 w7 |= (r6 << 5) & 0x60: digit5 seg b [main]; digit5 seg a [main]
    b .L0801AFF4                             @ 0801AD9A
.L0801AD9C:                                @ reached from 0801A97A beq (equal / zero)
    @ position 6 (main display, SEG35/36): words 1, 3, 5, 7
    ldr r0, =lcd_shadow                      @ 0801AD9C &LCD shadow
    ldr r0, [r0, #4]                         @ 0801ADA0
    movw r1, #4079                           @ 0801ADA2
    ands r0, r1                              @ 0801ADA6
    ldr r1, =lcd_shadow                      @ 0801ADA8 &LCD shadow
    str r0, [r1, #4]                         @ 0801ADAC w1 &= 0xFEF: clears 21 bits
    ldr r0, =lcd_shadow                      @ 0801ADAE &LCD shadow
    ldr r0, [r0, #12]                        @ 0801ADB2
    movw r1, #4071                           @ 0801ADB4
    ands r0, r1                              @ 0801ADB8
    ldr r1, =lcd_shadow                      @ 0801ADBA &LCD shadow
    str r0, [r1, #12]                        @ 0801ADBE w3 &= 0xFE7: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801ADC0 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801ADC4
    movw r1, #4071                           @ 0801ADC6
    ands r0, r1                              @ 0801ADCA
    ldr r1, =lcd_shadow                      @ 0801ADCC &LCD shadow
    str r0, [r1, #20]                        @ 0801ADD0 w5 &= 0xFE7: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801ADD2 &LCD shadow
    ldr r0, [r0, #28]                        @ 0801ADD6
    movw r1, #4071                           @ 0801ADD8
    ands r0, r1                              @ 0801ADDC
    ldr r1, =lcd_shadow                      @ 0801ADDE &LCD shadow
    str r0, [r1, #28]                        @ 0801ADE2 w7 &= 0xFE7: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801ADE4 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801ADE8
    lsrs r1, r6, #3                          @ 0801ADEA
    ands.w r1, r1, #24                       @ 0801ADEC
    orrs r0, r1                              @ 0801ADF0
    ldr r1, =lcd_shadow                      @ 0801ADF2 &LCD shadow
    str r0, [r1, #4]                         @ 0801ADF6 w1 |= (r6 >> 3) & 0x18: main dp3 (seg2dp); digit6 seg d [main]
    ldr r0, =lcd_shadow                      @ 0801ADF8 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801ADFC
    lsrs r1, r6, #1                          @ 0801ADFE
    ands.w r1, r1, #24                       @ 0801AE00
    orrs r0, r1                              @ 0801AE04
    ldr r1, =lcd_shadow                      @ 0801AE06 &LCD shadow
    str r0, [r1, #12]                        @ 0801AE0A w3 |= (r6 >> 1) & 0x18: digit6 seg c [main]; digit6 seg e [main]
    ldr r0, =lcd_shadow                      @ 0801AE0C &LCD shadow
    ldr r0, [r0, #20]                        @ 0801AE10
    lsls r1, r6, #1                          @ 0801AE12
    ands.w r1, r1, #24                       @ 0801AE14
    orrs r0, r1                              @ 0801AE18
    ldr r1, =lcd_shadow                      @ 0801AE1A &LCD shadow
    str r0, [r1, #20]                        @ 0801AE1E w5 |= (r6 << 1) & 0x18: digit6 seg g [main]; digit6 seg f [main]
    ldr r0, =lcd_shadow                      @ 0801AE20 &LCD shadow
    ldr r0, [r0, #28]                        @ 0801AE24
    lsls r1, r6, #3                          @ 0801AE26
    ands.w r1, r1, #24                       @ 0801AE28
    orrs r0, r1                              @ 0801AE2C
    ldr r1, =lcd_shadow                      @ 0801AE2E &LCD shadow
    str r0, [r1, #28]                        @ 0801AE32 w7 |= (r6 << 3) & 0x18: digit6 seg b [main]; digit6 seg a [main]
    b .L0801AFF4                             @ 0801AE34
.L0801AE36:                                @ reached from 0801A988 bcc (unsigned <)
    @ position 7 (main display, SEG33/34): words 1, 3, 5, 7
    ldr r0, =lcd_shadow                      @ 0801AE36 &LCD shadow
    ldr r0, [r0, #4]                         @ 0801AE3A
    movw r1, #4091                           @ 0801AE3C
    ands r0, r1                              @ 0801AE40
    ldr r1, =lcd_shadow                      @ 0801AE42 &LCD shadow
    str r0, [r1, #4]                         @ 0801AE46 w1 &= 0xFFB: clears 21 bits
    ldr r0, =lcd_shadow                      @ 0801AE48 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801AE4C
    movw r1, #4089                           @ 0801AE4E
    ands r0, r1                              @ 0801AE52
    ldr r1, =lcd_shadow                      @ 0801AE54 &LCD shadow
    str r0, [r1, #12]                        @ 0801AE58 w3 &= 0xFF9: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801AE5A &LCD shadow
    ldr r0, [r0, #20]                        @ 0801AE5E
    movw r1, #4089                           @ 0801AE60
    ands r0, r1                              @ 0801AE64
    ldr r1, =lcd_shadow                      @ 0801AE66 &LCD shadow
    str r0, [r1, #20]                        @ 0801AE6A w5 &= 0xFF9: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801AE6C &LCD shadow
    ldr r0, [r0, #28]                        @ 0801AE70
    movw r1, #4089                           @ 0801AE72
    ands r0, r1                              @ 0801AE76
    ldr r1, =lcd_shadow                      @ 0801AE78 &LCD shadow
    str r0, [r1, #28]                        @ 0801AE7C w7 &= 0xFF9: clears 22 bits
    ldr r0, =lcd_shadow                      @ 0801AE7E &LCD shadow
    ldr r0, [r0, #4]                         @ 0801AE82
    lsrs r1, r6, #5                          @ 0801AE84
    ands.w r1, r1, #6                        @ 0801AE86
    orrs r0, r1                              @ 0801AE8A
    ldr r1, =lcd_shadow                      @ 0801AE8C &LCD shadow
    str r0, [r1, #4]                         @ 0801AE90 w1 |= (r6 >> 5) & 0x6: main dp2 (seg3dp); digit7 seg d [main]
    ldr r0, =lcd_shadow                      @ 0801AE92 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801AE96
    lsrs r1, r6, #3                          @ 0801AE98
    ands.w r1, r1, #6                        @ 0801AE9A
    orrs r0, r1                              @ 0801AE9E
    ldr r1, =lcd_shadow                      @ 0801AEA0 &LCD shadow
    str r0, [r1, #12]                        @ 0801AEA4 w3 |= (r6 >> 3) & 0x6: digit7 seg c [main]; digit7 seg e [main]
    ldr r0, =lcd_shadow                      @ 0801AEA6 &LCD shadow
    ldr r0, [r0, #20]                        @ 0801AEAA
    lsrs r1, r6, #1                          @ 0801AEAC
    ands.w r1, r1, #6                        @ 0801AEAE
    orrs r0, r1                              @ 0801AEB2
    ldr r1, =lcd_shadow                      @ 0801AEB4 &LCD shadow
    str r0, [r1, #20]                        @ 0801AEB8 w5 |= (r6 >> 1) & 0x6: digit7 seg g [main]; digit7 seg f [main]
    ldr r0, =lcd_shadow                      @ 0801AEBA &LCD shadow
    ldr r0, [r0, #28]                        @ 0801AEBE
    lsls r1, r6, #1                          @ 0801AEC0
    ands.w r1, r1, #6                        @ 0801AEC2
    orrs r0, r1                              @ 0801AEC6
    ldr r1, =lcd_shadow                      @ 0801AEC8 &LCD shadow
    str r0, [r1, #28]                        @ 0801AECC w7 |= (r6 << 1) & 0x6: digit7 seg b [main]; digit7 seg a [main]
    b .L0801AFF4                             @ 0801AECE
.L0801AED0:                                @ reached from 0801A984 beq (equal / zero)
    @ position 8 (main display, SEG14/15): words 0, 2, 4, 6
    ldr r0, =lcd_shadow                      @ 0801AED0 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AED4
    bics.w r0, r0, #32768                    @ 0801AED6
    ldr r1, =lcd_shadow                      @ 0801AEDA &LCD shadow
    str r0, [r1, #0]                         @ 0801AEDE w0 &= ~0x8000: clears digit8 seg d [main]
    ldr r0, =lcd_shadow                      @ 0801AEE0 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AEE4
    bics.w r0, r0, #49152                    @ 0801AEE6
    ldr r1, =lcd_shadow                      @ 0801AEEA &LCD shadow
    str r0, [r1, #8]                         @ 0801AEEE w2 &= ~0xC000: clears digit8 seg c [main]; digit8 seg e [main]
    ldr r0, =lcd_shadow                      @ 0801AEF0 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AEF4
    bics.w r0, r0, #49152                    @ 0801AEF6
    ldr r1, =lcd_shadow                      @ 0801AEFA &LCD shadow
    str r0, [r1, #16]                        @ 0801AEFE w4 &= ~0xC000: clears digit8 seg g [main]; digit8 seg f [main]
    ldr r0, =lcd_shadow                      @ 0801AF00 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AF04
    bics.w r0, r0, #49152                    @ 0801AF06
    ldr r1, =lcd_shadow                      @ 0801AF0A &LCD shadow
    str r0, [r1, #24]                        @ 0801AF0E w6 &= ~0xC000: clears digit8 seg b [main]; digit8 seg a [main]
    ldr r0, =lcd_shadow                      @ 0801AF10 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AF14
    lsls r1, r6, #8                          @ 0801AF16
    ands.w r1, r1, #49152                    @ 0801AF18
    orrs r0, r1                              @ 0801AF1C
    ldr r1, =lcd_shadow                      @ 0801AF1E &LCD shadow
    str r0, [r1, #0]                         @ 0801AF22 w0 |= (r6 << 8) & 0xC000: main dp1 (seg4dp); digit8 seg d [main]
    ldr r0, =lcd_shadow                      @ 0801AF24 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AF28
    lsls r1, r6, #10                         @ 0801AF2A
    ands.w r1, r1, #49152                    @ 0801AF2C
    orrs r0, r1                              @ 0801AF30
    ldr r1, =lcd_shadow                      @ 0801AF32 &LCD shadow
    str r0, [r1, #8]                         @ 0801AF36 w2 |= (r6 << 10) & 0xC000: digit8 seg c [main]; digit8 seg e [main]
    ldr r0, =lcd_shadow                      @ 0801AF38 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AF3C
    lsls r1, r6, #12                         @ 0801AF3E
    ands.w r1, r1, #49152                    @ 0801AF40
    orrs r0, r1                              @ 0801AF44
    ldr r1, =lcd_shadow                      @ 0801AF46 &LCD shadow
    str r0, [r1, #16]                        @ 0801AF4A w4 |= (r6 << 12) & 0xC000: digit8 seg g [main]; digit8 seg f [main]
    ldr r0, =lcd_shadow                      @ 0801AF4C &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AF50
    lsls r1, r6, #14                         @ 0801AF52
    ands.w r1, r1, #49152                    @ 0801AF54
    orrs r0, r1                              @ 0801AF58
    ldr r1, =lcd_shadow                      @ 0801AF5A &LCD shadow
    str r0, [r1, #24]                        @ 0801AF5E w6 |= (r6 << 14) & 0xC000: digit8 seg b [main]; digit8 seg a [main]
    b .L0801AFF4                             @ 0801AF60
.L0801AF62:                                @ reached from 0801A98E beq (equal / zero)
    @ position 9 (main display, rightmost, SEG12/13): words 0, 2, 4, 6

    ldr r0, =lcd_shadow                      @ 0801AF62 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AF66
    bics.w r0, r0, #8192                     @ 0801AF68
    ldr r1, =lcd_shadow                      @ 0801AF6C &LCD shadow
    str r0, [r1, #0]                         @ 0801AF70 w0 &= ~0x2000: clears digit9 seg d [main]
    ldr r0, =lcd_shadow                      @ 0801AF72 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AF76
    bics.w r0, r0, #12288                    @ 0801AF78
    ldr r1, =lcd_shadow                      @ 0801AF7C &LCD shadow
    str r0, [r1, #8]                         @ 0801AF80 w2 &= ~0x3000: clears digit9 seg c [main]; digit9 seg e [main]
    ldr r0, =lcd_shadow                      @ 0801AF82 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AF86
    bics.w r0, r0, #12288                    @ 0801AF88
    ldr r1, =lcd_shadow                      @ 0801AF8C &LCD shadow
    str r0, [r1, #16]                        @ 0801AF90 w4 &= ~0x3000: clears digit9 seg g [main]; digit9 seg f [main]
    ldr r0, =lcd_shadow                      @ 0801AF92 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AF96
    bics.w r0, r0, #12288                    @ 0801AF98
    ldr r1, =lcd_shadow                      @ 0801AF9C &LCD shadow
    str r0, [r1, #24]                        @ 0801AFA0 w6 &= ~0x3000: clears digit9 seg b [main]; digit9 seg a [main]
    ldr r0, =lcd_shadow                      @ 0801AFA2 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801AFA6
    lsls r1, r6, #6                          @ 0801AFA8
    ands.w r1, r1, #12288                    @ 0801AFAA
    orrs r0, r1                              @ 0801AFAE
    ldr r1, =lcd_shadow                      @ 0801AFB0 &LCD shadow
    str r0, [r1, #0]                         @ 0801AFB4 w0 |= (r6 << 6) & 0x3000: bar tick group A (digit-9 x slot); digit9 seg d [main]
    ldr r0, =lcd_shadow                      @ 0801AFB6 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801AFBA
    lsls r1, r6, #8                          @ 0801AFBC
    ands.w r1, r1, #12288                    @ 0801AFBE
    orrs r0, r1                              @ 0801AFC2
    ldr r1, =lcd_shadow                      @ 0801AFC4 &LCD shadow
    str r0, [r1, #8]                         @ 0801AFC8 w2 |= (r6 << 8) & 0x3000: digit9 seg c [main]; digit9 seg e [main]
    ldr r0, =lcd_shadow                      @ 0801AFCA &LCD shadow
    ldr r0, [r0, #16]                        @ 0801AFCE
    lsls r1, r6, #10                         @ 0801AFD0
    ands.w r1, r1, #12288                    @ 0801AFD2
    orrs r0, r1                              @ 0801AFD6
    ldr r1, =lcd_shadow                      @ 0801AFD8 &LCD shadow
    str r0, [r1, #16]                        @ 0801AFDC w4 |= (r6 << 10) & 0x3000: digit9 seg g [main]; digit9 seg f [main]
    ldr r0, =lcd_shadow                      @ 0801AFDE &LCD shadow
    ldr r0, [r0, #24]                        @ 0801AFE2
    lsls r1, r6, #12                         @ 0801AFE4
    ands.w r1, r1, #12288                    @ 0801AFE6
    orrs r0, r1                              @ 0801AFEA
    ldr r1, =lcd_shadow                      @ 0801AFEC &LCD shadow
    str r0, [r1, #24]                        @ 0801AFF0 w6 |= (r6 << 12) & 0x3000: digit9 seg b [main]; digit9 seg a [main]
    b .L0801AFF4                             @ 0801AFF2
.L0801AFF4:                                @ reached from 0801A992 b; 0801AA24 b; 0801AB4A b; 0801ABDC b; 0801AC6E b; 0801AD00 b; 0801AD9A b; 0801AE34 b; 0801AECE b; 0801AF60 b; 0801AFF2 b
    pop {r4, r5, r6, pc}                     @ 0801AFF4
ENDFUNC lcd_draw_glyph
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801AFFC - font lookup: character code to seven-segment bit pattern
@ Replaces : 0x0801AFFC FUN_0801AFFC (v2.05, 136 bytes)
@ In       : r0 = character code (low byte)
@ Out      : r0 = segment byte (bit0 b, bit1 a, bit2 g, bit3 f, bit4 c, bit5 e, bit7 d; bit 6 is never set); 0 for any
@            character not listed below
@ Context  : main only
@ RAM      : -
@ Spec     : analysis/lcd_map.md 2 (font bit to segment); tables v205_tab_08029184 (digits), v205_tab_080290B8 (A..Z),
@            v205_tab_080290D4 (a..z) in font.s
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801AFFC
    movs r1, r0                              @ 0801AFFC
    movs r0, #0                              @ 0801AFFE
    uxtb r1, r1                              @ 0801B000
    @ '0'..'9' (0x30..0x39): table 0x08029184 indexed by (code - 0x30)
    cmp r1, #48                              @ 0801B002
    blt .L0801B01C                           @ 0801B004
    uxtb r1, r1                              @ 0801B006
    cmp r1, #58                              @ 0801B008
    bge .L0801B01C                           @ 0801B00A
    ldr r2, =v205_tab_08029184               @ 0801B00C
    uxtb r1, r1                              @ 0801B010
    add r2, r1                               @ 0801B012
    ldrb.w r2, [r2, #-48]                    @ 0801B014
    movs r0, r2                              @ 0801B018
    b .L0801B080                             @ 0801B01A
.L0801B01C:                                @ reached from 0801B004 blt (signed <); 0801B00A bge (signed >=)
    @ 'A'..'Z' (0x41..0x5A): table 0x080290B8 indexed by (code - 0x41)
    uxtb r1, r1                              @ 0801B01C
    cmp r1, #91                              @ 0801B01E
    bge .L0801B038                           @ 0801B020
    uxtb r1, r1                              @ 0801B022
    cmp r1, #65                              @ 0801B024
    blt .L0801B038                           @ 0801B026
    ldr r2, =v205_tab_080290B8               @ 0801B028
    uxtb r1, r1                              @ 0801B02C
    add r2, r1                               @ 0801B02E
    ldrb.w r2, [r2, #-65]                    @ 0801B030
    movs r0, r2                              @ 0801B034
    b .L0801B080                             @ 0801B036
.L0801B038:                                @ reached from 0801B020 bge (signed >=); 0801B026 blt (signed <)
    @ 'a'..'z' (0x61..0x7A): table 0x080290D4 indexed by (code - 0x61)
    uxtb r1, r1                              @ 0801B038
    cmp r1, #123                             @ 0801B03A
    bge .L0801B054                           @ 0801B03C
    uxtb r1, r1                              @ 0801B03E
    cmp r1, #97                              @ 0801B040
    blt .L0801B054                           @ 0801B042
    ldr r2, =v205_tab_080290D4               @ 0801B044
    uxtb r1, r1                              @ 0801B048
    add r2, r1                               @ 0801B04A
    ldrb.w r2, [r2, #-97]                    @ 0801B04C
    movs r0, r2                              @ 0801B050
    b .L0801B080                             @ 0801B052
.L0801B054:                                @ reached from 0801B03C bge (signed >=); 0801B042 blt (signed <)
    @ other codes: ' ' (0x20) -> 0x00, '-' (0x2D) -> 0x04 (segment g), '=' (0x3D) -> 0x82 (segments a and d), 0xFF -> 0xBF (all seven), anything else -> 0

    uxtb r1, r1                              @ 0801B054
    movs r2, r1                              @ 0801B056
    cmp r2, #32                              @ 0801B058
    beq .L0801B06A                           @ 0801B05A
    cmp r2, #45                              @ 0801B05C
    beq .L0801B070                           @ 0801B05E
    cmp r2, #61                              @ 0801B060
    beq .L0801B076                           @ 0801B062
    cmp r2, #255                             @ 0801B064
    beq .L0801B07C                           @ 0801B066
    b .L0801B080                             @ 0801B068
.L0801B06A:                                @ reached from 0801B05A beq (equal / zero)
    movs r2, #0                              @ 0801B06A
    movs r0, r2                              @ 0801B06C
    b .L0801B080                             @ 0801B06E
.L0801B070:                                @ reached from 0801B05E beq (equal / zero)
    movs r2, #4                              @ 0801B070
    movs r0, r2                              @ 0801B072
    b .L0801B080                             @ 0801B074
.L0801B076:                                @ reached from 0801B062 beq (equal / zero)
    movs r2, #130                            @ 0801B076
    movs r0, r2                              @ 0801B078
    b .L0801B080                             @ 0801B07A
.L0801B07C:                                @ reached from 0801B066 beq (equal / zero)
    movs r2, #191                            @ 0801B07C
    movs r0, r2                              @ 0801B07E
.L0801B080:                                @ reached from 0801B01A b; 0801B036 b; 0801B052 b; 0801B068 b; 0801B06E b; 0801B074 b; 0801B07A b; falls in
    uxtb r0, r0                              @ 0801B080
    bx lr                                    @ 0801B082
ENDFUNC fn_0801AFFC
    .ltorg
    .global lcd_font_lookup
    .set lcd_font_lookup, fn_0801AFFC

@ -----------------------------------------------------------------------------
@ fn_0801B090 - split a magnitude into five decimal digit words
@ Replaces : 0x0801B090 FUN_0801B090 (v2.05, 140 bytes)
@ In       : r0 = unsigned value
@ Deviation: OF-49 (v2.05 stored the first word unreduced, so values >= 100000 gave a first word >= 10)
@ Out      : 0x20007DB0 = (r0 / 10000) mod 10,
@            0x20007DB4 = (r0 mod 10000) / 1000, 0x20007DB8 = (r0 mod 1000) / 100, 0x20007DBC = (r0 mod 100) / 10,
@            0x20007DC0 = r0 mod 10
@ Clobbers : r1, r2 (v2.05 regeffects)
@ Context  : main only
@ RAM      : writes 0x20007DB0, 0x20007DB4, 0x20007DB8, 0x20007DBC, 0x20007DC0
@ Spec     : analysis/lcd_map.md 2 (callers lcd_show_value_pos5_9 / pos0_4, fn_0801A854)
@
@ -----------------------------------------------------------------------------
FUNC fn_0801B090
    movw r1, #10000                          @ 0801B090
    udiv r1, r0, r1                          @ 0801B094
    @ OF-49: reduce the first word modulo 10 (v2.05 stored n / 10000 unreduced: n >= 100000 drew a wrong first character).
    @ Only r1 and r2 are used, as in v2.05: r1 mod 10 = r1 - 8 q - 2 q with q = r1 / 10.
    movs r2, #10
    udiv r2, r1, r2                          @ r2 = (n / 10000) / 10
    sub r1, r1, r2, lsl #3
    sub r1, r1, r2, lsl #1                   @ r1 = (n / 10000) mod 10
    ldr r2, =v_20007DB0                      @ 0801B098 &digit word 0 (10^4)
    str r1, [r2, #0]                         @ 0801B09C
    movw r1, #10000                          @ 0801B09E
    udiv r2, r0, r1                          @ 0801B0A2
    mls r1, r1, r2, r0                       @ 0801B0A6
    ldr r2, =v_20007DB4                      @ 0801B0AA &digit word 1 (10^3)
    str r1, [r2, #0]                         @ 0801B0AE
    ldr r1, =v_20007DB4                      @ 0801B0B0 &digit word 1 (10^3)
    ldr r1, [r1, #0]                         @ 0801B0B4
    mov.w r2, #1000                          @ 0801B0B6
    sdiv r1, r1, r2                          @ 0801B0BA
    ldr r2, =v_20007DB4                      @ 0801B0BE &digit word 1 (10^3)
    str r1, [r2, #0]                         @ 0801B0C2
    mov.w r1, #1000                          @ 0801B0C4
    udiv r2, r0, r1                          @ 0801B0C8
    mls r1, r1, r2, r0                       @ 0801B0CC
    ldr r2, =v_20007DB8                      @ 0801B0D0 &digit word 2 (10^2)
    str r1, [r2, #0]                         @ 0801B0D4
    ldr r1, =v_20007DB8                      @ 0801B0D6 &digit word 2 (10^2)
    ldr r1, [r1, #0]                         @ 0801B0DA
    movs r2, #100                            @ 0801B0DC
    sdiv r1, r1, r2                          @ 0801B0DE
    ldr r2, =v_20007DB8                      @ 0801B0E2 &digit word 2 (10^2)
    str r1, [r2, #0]                         @ 0801B0E6
    movs r1, #100                            @ 0801B0E8
    udiv r2, r0, r1                          @ 0801B0EA
    mls r1, r1, r2, r0                       @ 0801B0EE
    ldr r2, =v_20007DBC                      @ 0801B0F2 &digit word 3 (10^1)
    str r1, [r2, #0]                         @ 0801B0F6
    ldr r1, =v_20007DBC                      @ 0801B0F8 &digit word 3 (10^1)
    ldr r1, [r1, #0]                         @ 0801B0FC
    movs r2, #10                             @ 0801B0FE
    sdiv r1, r1, r2                          @ 0801B100
    ldr r2, =v_20007DBC                      @ 0801B104 &digit word 3 (10^1)
    str r1, [r2, #0]                         @ 0801B108
    movs r1, #10                             @ 0801B10A
    udiv r2, r0, r1                          @ 0801B10C
    mls r1, r1, r2, r0                       @ 0801B110
    ldr r2, =v_20007DC0                      @ 0801B114 &digit word 4 (10^0)
    str r1, [r2, #0]                         @ 0801B118
    bx lr                                    @ 0801B11A
ENDFUNC fn_0801B090
    .ltorg
    .global lcd_split_digits
    .set lcd_split_digits, fn_0801B090

@ -----------------------------------------------------------------------------
@ fn_0801B130 - turn the five digit words into the character buffer, blanking leading zeros
@ Replaces : 0x0801B130 FUN_0801B130 (v2.05, 464 bytes)
@ In       : r0 = decimal-point position d (0..4; the digit left of the decimal point is never blanked)
@ Out      : 0x20007C30[0..4] = characters (digit + '0', or ' ' for a blanked leading zero)
@ Context  : main only
@ RAM      : reads and rewrites 0x20007DB0..0x20007DC0; writes 0x20007C30..0x20007C34
@ Spec     : analysis/lcd_map.md 2 (decimal points); behaviour: d = 0 blanks up to four leading zeros, d = 1 three, d = 2 two,
@            d = 3 one, d = 4 none (cases at 0x0801B20C, 0x0801B1D4, 0x0801B1AE, 0x0801B19A)
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801B130
    @ digit words larger than 255 are replaced by 0 (five checks: 0x0801B136..0x0801B180)
    ldr r1, =v_20007DB0                      @ 0801B130 &digit word 0 (10^4)
    ldr r1, [r1, #0]                         @ 0801B134
    cmp r1, #255                             @ 0801B136 branch if digit word 0 (10^4) <= 255
    ble .L0801B142                           @ 0801B138
    movs r1, #0                              @ 0801B13A
    ldr r2, =v_20007DB0                      @ 0801B13C &digit word 0 (10^4)
    str r1, [r2, #0]                         @ 0801B140
.L0801B142:                                @ reached from 0801B138 ble (signed <=); falls in
    ldr r1, =v_20007DB4                      @ 0801B142 &digit word 1 (10^3)
    ldr r1, [r1, #0]                         @ 0801B146
    cmp r1, #255                             @ 0801B148 branch if digit word 1 (10^3) <= 255
    ble .L0801B154                           @ 0801B14A
    movs r1, #0                              @ 0801B14C
    ldr r2, =v_20007DB4                      @ 0801B14E &digit word 1 (10^3)
    str r1, [r2, #0]                         @ 0801B152
.L0801B154:                                @ reached from 0801B14A ble (signed <=); falls in
    ldr r1, =v_20007DB8                      @ 0801B154 &digit word 2 (10^2)
    ldr r1, [r1, #0]                         @ 0801B158
    cmp r1, #255                             @ 0801B15A branch if digit word 2 (10^2) <= 255
    ble .L0801B166                           @ 0801B15C
    movs r1, #0                              @ 0801B15E
    ldr r2, =v_20007DB8                      @ 0801B160 &digit word 2 (10^2)
    str r1, [r2, #0]                         @ 0801B164
.L0801B166:                                @ reached from 0801B15C ble (signed <=); falls in
    ldr r1, =v_20007DBC                      @ 0801B166 &digit word 3 (10^1)
    ldr r1, [r1, #0]                         @ 0801B16A
    cmp r1, #255                             @ 0801B16C branch if digit word 3 (10^1) <= 255
    ble .L0801B178                           @ 0801B16E
    movs r1, #0                              @ 0801B170
    ldr r2, =v_20007DBC                      @ 0801B172 &digit word 3 (10^1)
    str r1, [r2, #0]                         @ 0801B176
.L0801B178:                                @ reached from 0801B16E ble (signed <=); falls in
    ldr r1, =v_20007DC0                      @ 0801B178 &digit word 4 (10^0)
    ldr r1, [r1, #0]                         @ 0801B17C
    cmp r1, #255                             @ 0801B17E branch if digit word 4 (10^0) <= 255
    ble .L0801B18A                           @ 0801B180
    movs r1, #0                              @ 0801B182
    ldr r2, =v_20007DC0                      @ 0801B184 &digit word 4 (10^0)
    str r1, [r2, #0]                         @ 0801B188
.L0801B18A:                                @ reached from 0801B180 ble (signed <=); falls in
    @ leading-zero blanking by decimal-point position d in r0
    uxtb r0, r0                              @ 0801B18A
    cmp r0, #0                               @ 0801B18C
    beq .L0801B20C                           @ 0801B18E
    cmp r0, #2                               @ 0801B190
    beq .L0801B1AE                           @ 0801B192
    bcc .L0801B1D4                           @ 0801B194
    cmp r0, #3                               @ 0801B196
    bne .L0801B254                           @ 0801B198
    ldr r1, =v_20007DB0                      @ 0801B19A &digit word 0 (10^4)
    ldr r1, [r1, #0]                         @ 0801B19E
    cmp r1, #0                               @ 0801B1A0 branch if digit word 0 (10^4) != 0
    bne .L0801B1AC                           @ 0801B1A2
    movs r1, #32                             @ 0801B1A4
    ldr r2, =v_20007DB0                      @ 0801B1A6 &digit word 0 (10^4)
    str r1, [r2, #0]                         @ 0801B1AA
.L0801B1AC:                                @ reached from 0801B1A2 bne (not equal / non-zero); falls in
    b .L0801B254                             @ 0801B1AC
.L0801B1AE:                                @ reached from 0801B192 beq (equal / zero)
    ldr r1, =v_20007DB0                      @ 0801B1AE &digit word 0 (10^4)
    ldr r1, [r1, #0]                         @ 0801B1B2
    cmp r1, #0                               @ 0801B1B4 branch if digit word 0 (10^4) != 0
    bne .L0801B1D2                           @ 0801B1B6
    movs r1, #32                             @ 0801B1B8
    ldr r2, =v_20007DB0                      @ 0801B1BA &digit word 0 (10^4)
    str r1, [r2, #0]                         @ 0801B1BE
    ldr r1, =v_20007DB4                      @ 0801B1C0 &digit word 1 (10^3)
    ldr r1, [r1, #0]                         @ 0801B1C4
    cmp r1, #0                               @ 0801B1C6 branch if digit word 1 (10^3) != 0
    bne .L0801B1D2                           @ 0801B1C8
    movs r1, #32                             @ 0801B1CA
    ldr r2, =v_20007DB4                      @ 0801B1CC &digit word 1 (10^3)
    str r1, [r2, #0]                         @ 0801B1D0
.L0801B1D2:                                @ reached from 0801B1B6 bne (not equal / non-zero); 0801B1C8 bne (not equal / non-zero); falls in
    b .L0801B254                             @ 0801B1D2
.L0801B1D4:                                @ reached from 0801B194 bcc (unsigned <)
    ldr r1, =v_20007DB0                      @ 0801B1D4 &digit word 0 (10^4)
    ldr r1, [r1, #0]                         @ 0801B1D8
    cmp r1, #0                               @ 0801B1DA branch if digit word 0 (10^4) != 0
    bne .L0801B20A                           @ 0801B1DC
    movs r1, #32                             @ 0801B1DE
    ldr r2, =v_20007DB0                      @ 0801B1E0 &digit word 0 (10^4)
    str r1, [r2, #0]                         @ 0801B1E4
    ldr r1, =v_20007DB4                      @ 0801B1E6 &digit word 1 (10^3)
    ldr r1, [r1, #0]                         @ 0801B1EA
    cmp r1, #0                               @ 0801B1EC branch if digit word 1 (10^3) != 0
    bne .L0801B20A                           @ 0801B1EE
    movs r1, #32                             @ 0801B1F0
    ldr r2, =v_20007DB4                      @ 0801B1F2 &digit word 1 (10^3)
    str r1, [r2, #0]                         @ 0801B1F6
    ldr r1, =v_20007DB8                      @ 0801B1F8 &digit word 2 (10^2)
    ldr r1, [r1, #0]                         @ 0801B1FC
    cmp r1, #0                               @ 0801B1FE branch if digit word 2 (10^2) != 0
    bne .L0801B20A                           @ 0801B200
    movs r1, #32                             @ 0801B202
    ldr r2, =v_20007DB8                      @ 0801B204 &digit word 2 (10^2)
    str r1, [r2, #0]                         @ 0801B208
.L0801B20A:                                @ reached from 0801B1DC bne (not equal / non-zero); 0801B1EE bne (not equal / non-zero); 0801B200 bne (not equal / non-zero); falls in
    b .L0801B254                             @ 0801B20A
.L0801B20C:                                @ reached from 0801B18E beq (equal / zero)
    ldr r1, =v_20007DB0                      @ 0801B20C &digit word 0 (10^4)
    ldr r1, [r1, #0]                         @ 0801B210
    cmp r1, #0                               @ 0801B212 branch if digit word 0 (10^4) != 0
    bne .L0801B254                           @ 0801B214
    movs r1, #32                             @ 0801B216
    ldr r2, =v_20007DB0                      @ 0801B218 &digit word 0 (10^4)
    str r1, [r2, #0]                         @ 0801B21C
    ldr r1, =v_20007DB4                      @ 0801B21E &digit word 1 (10^3)
    ldr r1, [r1, #0]                         @ 0801B222
    cmp r1, #0                               @ 0801B224 branch if digit word 1 (10^3) != 0
    bne .L0801B254                           @ 0801B226
    movs r1, #32                             @ 0801B228
    ldr r2, =v_20007DB4                      @ 0801B22A &digit word 1 (10^3)
    str r1, [r2, #0]                         @ 0801B22E
    ldr r1, =v_20007DB8                      @ 0801B230 &digit word 2 (10^2)
    ldr r1, [r1, #0]                         @ 0801B234
    cmp r1, #0                               @ 0801B236 branch if digit word 2 (10^2) != 0
    bne .L0801B254                           @ 0801B238
    movs r1, #32                             @ 0801B23A
    ldr r2, =v_20007DB8                      @ 0801B23C &digit word 2 (10^2)
    str r1, [r2, #0]                         @ 0801B240
    ldr r1, =v_20007DBC                      @ 0801B242 &digit word 3 (10^1)
    ldr r1, [r1, #0]                         @ 0801B246
    cmp r1, #0                               @ 0801B248 branch if digit word 3 (10^1) != 0
    bne .L0801B254                           @ 0801B24A
    movs r1, #32                             @ 0801B24C
    ldr r2, =v_20007DBC                      @ 0801B24E &digit word 3 (10^1)
    str r1, [r2, #0]                         @ 0801B252
.L0801B254:                                @ reached from 0801B198 bne (not equal / non-zero); 0801B1AC b; 0801B1D2 b; 0801B20A b; 0801B214 bne (not equal / non-zero); 0801B226 bne (not equal / non-zero); 0801B238 bne (not equal / non-zero); 0801B24A bne (not equal / non-zero); falls in
    @ words below 10 become ASCII digits (+ 0x30); a blanked word holds 0x20 and is left alone
    ldr r1, =v_20007DB0                      @ 0801B254 &digit word 0 (10^4)
    ldr r1, [r1, #0]                         @ 0801B258
    cmp r1, #10                              @ 0801B25A branch if digit word 0 (10^4) >= 10
    bge .L0801B26C                           @ 0801B25C
    ldr r1, =v_20007DB0                      @ 0801B25E &digit word 0 (10^4)
    ldr r1, [r1, #0]                         @ 0801B262
    adds r1, #48                             @ 0801B264
    ldr r2, =v_20007DB0                      @ 0801B266 &digit word 0 (10^4)
    str r1, [r2, #0]                         @ 0801B26A
.L0801B26C:                                @ reached from 0801B25C bge (signed >=); falls in
    ldr r1, =v_20007DB4                      @ 0801B26C &digit word 1 (10^3)
    ldr r1, [r1, #0]                         @ 0801B270
    cmp r1, #10                              @ 0801B272 branch if digit word 1 (10^3) >= 10
    bge .L0801B284                           @ 0801B274
    ldr r1, =v_20007DB4                      @ 0801B276 &digit word 1 (10^3)
    ldr r1, [r1, #0]                         @ 0801B27A
    adds r1, #48                             @ 0801B27C
    ldr r2, =v_20007DB4                      @ 0801B27E &digit word 1 (10^3)
    str r1, [r2, #0]                         @ 0801B282
.L0801B284:                                @ reached from 0801B274 bge (signed >=); falls in
    ldr r1, =v_20007DB8                      @ 0801B284 &digit word 2 (10^2)
    ldr r1, [r1, #0]                         @ 0801B288
    cmp r1, #10                              @ 0801B28A branch if digit word 2 (10^2) >= 10
    bge .L0801B29C                           @ 0801B28C
    ldr r1, =v_20007DB8                      @ 0801B28E &digit word 2 (10^2)
    ldr r1, [r1, #0]                         @ 0801B292
    adds r1, #48                             @ 0801B294
    ldr r2, =v_20007DB8                      @ 0801B296 &digit word 2 (10^2)
    str r1, [r2, #0]                         @ 0801B29A
.L0801B29C:                                @ reached from 0801B28C bge (signed >=); falls in
    ldr r1, =v_20007DBC                      @ 0801B29C &digit word 3 (10^1)
    ldr r1, [r1, #0]                         @ 0801B2A0
    cmp r1, #10                              @ 0801B2A2 branch if digit word 3 (10^1) >= 10
    bge .L0801B2B4                           @ 0801B2A4
    ldr r1, =v_20007DBC                      @ 0801B2A6 &digit word 3 (10^1)
    ldr r1, [r1, #0]                         @ 0801B2AA
    adds r1, #48                             @ 0801B2AC
    ldr r2, =v_20007DBC                      @ 0801B2AE &digit word 3 (10^1)
    str r1, [r2, #0]                         @ 0801B2B2
.L0801B2B4:                                @ reached from 0801B2A4 bge (signed >=); falls in
    ldr r1, =v_20007DC0                      @ 0801B2B4 &digit word 4 (10^0)
    ldr r1, [r1, #0]                         @ 0801B2B8
    cmp r1, #10                              @ 0801B2BA branch if digit word 4 (10^0) >= 10
    bge .L0801B2CC                           @ 0801B2BC
    ldr r1, =v_20007DC0                      @ 0801B2BE &digit word 4 (10^0)
    ldr r1, [r1, #0]                         @ 0801B2C2
    adds r1, #48                             @ 0801B2C4
    ldr r2, =v_20007DC0                      @ 0801B2C6 &digit word 4 (10^0)
    str r1, [r2, #0]                         @ 0801B2CA
.L0801B2CC:                                @ reached from 0801B2BC bge (signed >=); falls in
    @ copy the five words into the text buffer 0x20007C30 as bytes

    ldr r1, =v_20007DB0                      @ 0801B2CC &digit word 0 (10^4)
    ldr r1, [r1, #0]                         @ 0801B2D0
    ldr r2, =v_20007C30                      @ 0801B2D2 &5-char text buffer
    strb r1, [r2, #0]                        @ 0801B2D4
    ldr r1, =v_20007DB4                      @ 0801B2D6 &digit word 1 (10^3)
    ldr r1, [r1, #0]                         @ 0801B2DA
    ldr r2, =v_20007C30                      @ 0801B2DC &5-char text buffer
    strb r1, [r2, #1]                        @ 0801B2DE
    ldr r1, =v_20007DB8                      @ 0801B2E0 &digit word 2 (10^2)
    ldr r1, [r1, #0]                         @ 0801B2E4
    ldr r2, =v_20007C30                      @ 0801B2E6 &5-char text buffer
    strb r1, [r2, #2]                        @ 0801B2E8
    ldr r1, =v_20007DBC                      @ 0801B2EA &digit word 3 (10^1)
    ldr r1, [r1, #0]                         @ 0801B2EE
    ldr r2, =v_20007C30                      @ 0801B2F0 &5-char text buffer
    strb r1, [r2, #3]                        @ 0801B2F2
    ldr r1, =v_20007DC0                      @ 0801B2F4 &digit word 4 (10^0)
    ldr r1, [r1, #0]                         @ 0801B2F8
    ldr r2, =v_20007C30                      @ 0801B2FA &5-char text buffer
    strb r1, [r2, #4]                        @ 0801B2FC
    bx lr                                    @ 0801B2FE
ENDFUNC fn_0801B130
    .ltorg
    .global lcd_digits_to_chars
    .set lcd_digits_to_chars, fn_0801B130
