@ =============================================================================
@ cu.s - SET: the user continuity threshold and hysteresis, SETUP pages th and HY (production image only,
@ DESIGN.md 10 IMP-64, FEATURES.md 2.38)
@
@ SET module, part 12.  The threshold page (item 10 in BEEP) offers two codes besides the 16 fixed thresholds: 16 "DNUSr"
@ (tone while the reading is at or below the user threshold: beep on a short) and 17 "UPUSr" (tone while the reading is
@ at or above it: beep on an open, which finds intermittent connections).  Both use the threshold of the page th and the
@ hysteresis of the page HY:
@     page  item  text      value                         storage (EEPROM_MAP.md 4.1)
@     th    45    "th 30"   1..500 ohm in 1 ohm steps     0x02D..0x02E, u16 big endian; 0 or above 500 reads as 30 ohm
@     HY    46    "HY 5.0"  0.1..25.0 ohm in 0.1 ohm      0x02F, tenths of an ohm; 0 or above 250 reads as 5.0 ohm
@ The two pages follow bH in the BEEP walk while the code is 16 or 17 (set/setup.s fn_08015410).  Long SETUP starts the
@ edit (the value blinks), REL steps up, PEAK steps down (the key auto-repeat of key/keys.s fn_08016A64 steps faster
@ while a key is held), both wrap around, long SETUP again saves, SETUP short ends the edit without a save, the edit
@ times out after about 2 minutes (fn_0800D190 then re-reads the EEPROM).
@ Thresholds of the decision (mres/beep.s fn_08007940), in 0.01 ohm with T the threshold in ohm, H the hysteresis in
@ tenths of an ohm: tone off -> on at 100 T for both codes; tone on -> off past 100 T + 10 H for DNUSr, below
@ 100 T - 10 H for UPUSr, at least 1 (a clamped short, 0, ends an open tone even with a hysteresis above the threshold).
@
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ SET_UT_EEPROM,       0x02D         @ EEPROM offset of the threshold, u16 big endian (0x02D high, 0x02E low byte)
    .equ SET_UH_EEPROM,       0x02F         @ EEPROM offset of the hysteresis
    .equ SET_UT_MAX,          500           @ highest threshold in ohm (0x7D << 2, an encodable immediate)
    .equ SET_UT_DEFAULT,      30            @ threshold of a blank or invalid EEPROM value (30 ohm, as code 0 DN 30)
    .equ SET_UH_MAX,          250           @ highest hysteresis in tenths of an ohm (25.0 ohm)
    .equ SET_UH_DEFAULT,      50            @ 5.0 ohm, the hysteresis of the fixed thresholds from 30 ohm up
    .equ SET_CU_ITEM_UH,      46            @ setup item of the page HY (set/setup.s SET_ITEM_UH)
    .equ SET_CU_CODE_UP,      17            @ continuity code UPUSr
    .equ set_cu_redraw,       v_20008062    @ sub display redraw request
    .equ set_cu_commit_req,   v_2000805B    @ LCD commit request
    .equ set_cu_text5,        v_20007C30    @ the five-character text buffer of the sub display (as set/logpg.s)

    .section .bss_port.set, "aw", %nobits
    .balign 2
@ set_ut_ohm: user continuity threshold 1..500 ohm (SET; read by fn_08007940 through set_cu_thr)
    .global set_ut_ohm
set_ut_ohm:     .space 2
@ set_uh_tenth: user continuity hysteresis 1..250 tenths of an ohm
    .global set_uh_tenth
set_uh_tenth:   .space 1

    .section .text.set.cu, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_cu_thr - threshold of the user codes for the continuity decision
@ In       : r0 = code (16 DNUSr, 17 UPUSr), r1 = tone state (0 off: the start threshold, 1 on: the continue threshold)
@ Out      : r0 = threshold in 0.01 ohm
@ Clobbers : r1-r3, flags
@ Context  : main only (fn_08007940)
@ -----------------------------------------------------------------------------
FUNC set_cu_thr
    ldr r2, =set_ut_ohm
    ldrh r2, [r2]
    movs r3, #100
    muls r2, r3, r2                         @ r2 = 100 T: the start threshold
    cbz r1, 2f                              @ tone off: start threshold
    ldr r3, =set_uh_tenth
    ldrb r3, [r3]
    add r3, r3, r3, lsl #2
    lsls r3, r3, #1                         @ r3 = 10 H
    cmp r0, #SET_CU_CODE_UP
    beq 1f
    add r2, r2, r3                          @ DNUSr: the tone stays on up to 100 T + 10 H
    b 2f
1:  subs r2, r2, r3                         @ UPUSr: the tone stays on down to 100 T - 10 H ...
    it le
    movle r2, #1                            @ ... and at least 0.01 ohm
2:  mov r0, r2
    bx lr
    .ltorg
ENDFUNC set_cu_thr

@ -----------------------------------------------------------------------------
@ set_ut_load - load the user continuity threshold from the EEPROM
@ Replaces : nothing (new)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ -----------------------------------------------------------------------------
FUNC set_ut_load
    push {r4, lr}
    movs r0, #SET_UT_EEPROM
    bl eeprom_read_u16_be                   @ r0 = 0x02D * 256 + 0x02E (cache or EEPROM, NVM reader)
    cmp r0, #0
    beq 1f                                  @ blank: the default
    cmp r0, #SET_UT_MAX
    bls 2f
1:  movs r0, #SET_UT_DEFAULT                @ 0 or above 500 (0xFFFF included): 30 ohm, the bytes are left as found
2:  ldr r1, =set_ut_ohm
    strh r0, [r1]
    pop {r4, pc}
    .ltorg
ENDFUNC set_ut_load

@ -----------------------------------------------------------------------------
@ set_uh_load - load the user continuity hysteresis from the EEPROM
@ Replaces : nothing (new)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset; fn_0800D190)
@ -----------------------------------------------------------------------------
FUNC set_uh_load
    push {r4, lr}
    movs r0, #SET_UH_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x02F
    cmp r0, #0
    beq 1f                                  @ blank: the default
    cmp r0, #SET_UH_MAX
    bls 2f
1:  movs r0, #SET_UH_DEFAULT                @ 0 or above 250 (0xFF included): 5.0 ohm, the byte is left as found
2:  ldr r1, =set_uh_tenth
    strb r0, [r1]
    pop {r4, pc}
    .ltorg
ENDFUNC set_uh_load

@ -----------------------------------------------------------------------------
@ set_ut_edit - edit action of the page th (setup item 45)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4; ble/bftset.s PUT with the action 100)
@ Note     : up 1 .. 500 then 1 again, down the reverse; the next reading uses the new value.  Save writes EEPROM
@            0x02D..0x02E (big endian) through set_nvm_store (NVM skips bytes that do not change).
@ -----------------------------------------------------------------------------
FUNC set_ut_edit
    push {r4, lr}
    uxtb r4, r0
    ldr r1, =set_ut_ohm
    ldrh r0, [r1]
    cmp r4, #1
    beq .Lue_up
    cmp r4, #2
    beq .Lue_down
    mov r1, r0                              @ save (100): EEPROM 0x02D..0x02E = threshold
    movs r0, #SET_UT_EEPROM
    movs r2, #2                             @ width 2: u16 big endian
    bl set_nvm_store
    b .Lue_redraw
.Lue_up:
    adds r0, r0, #1
    cmp r0, #SET_UT_MAX
    it hi
    movhi r0, #1                            @ past 500: 1 ohm
    b 1f
.Lue_down:
    subs r0, r0, #1
    it eq
    moveq r0, #SET_UT_MAX                   @ below 1: 500 ohm
1:  strh r0, [r1]
.Lue_redraw:
    movs r0, #1
    ldr r1, =set_cu_redraw
    strb r0, [r1]
    pop {r4, pc}
    .ltorg
ENDFUNC set_ut_edit

@ -----------------------------------------------------------------------------
@ set_uh_edit - edit action of the page HY (setup item 46)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4; ble/bftset.s PUT with the action 100)
@ Note     : up 0.1 .. 25.0 ohm then 0.1 again, down the reverse.  Save writes EEPROM 0x02F through set_nvm_store.
@ -----------------------------------------------------------------------------
FUNC set_uh_edit
    push {r4, lr}
    uxtb r4, r0
    ldr r1, =set_uh_tenth
    ldrb r0, [r1]
    cmp r4, #1
    beq .Lhy_up
    cmp r4, #2
    beq .Lhy_down
    mov r1, r0                              @ save (100): EEPROM 0x02F = hysteresis
    movs r0, #SET_UH_EEPROM
    movs r2, #1
    bl set_nvm_store
    b .Lhy_redraw
.Lhy_up:
    adds r0, r0, #1
    cmp r0, #SET_UH_MAX
    it hi
    movhi r0, #1                            @ past 25.0: 0.1 ohm
    b 1f
.Lhy_down:
    subs r0, r0, #1
    it eq
    moveq r0, #SET_UH_MAX                   @ below 0.1: 25.0 ohm
1:  strb r0, [r1]
.Lhy_redraw:
    movs r0, #1
    ldr r1, =set_cu_redraw
    strb r0, [r1]
    pop {r4, pc}
    .ltorg
ENDFUNC set_uh_edit

@ -----------------------------------------------------------------------------
@ set_cu_draw - draw the page th (r0 = 45) or HY (r0 = 46)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C)
@ RAM      : reads set_ut_ohm, set_uh_tenth; writes lcd_shadow (sub minus off, the decimal point of HY), set_cu_text5,
@            the commit request
@ -----------------------------------------------------------------------------
FUNC set_cu_draw
    push {r4, lr}
    mov r4, r0
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    str r1, [r0, #0x10]
    cmp r4, #SET_CU_ITEM_UH
    ite eq
    moveq r0, #1                            @ HY: the decimal point before the last digit, "HY 5.0"
    movne r0, #0                            @ th: no decimal point
    bl fn_08017FB4
    cmp r4, #SET_CU_ITEM_UH
    beq 1f
    ldr r0, =set_ut_ohm
    ldrh r0, [r0]                           @ th: 1..500, leading zeros blank: "th  1", "th 30", "th500"
    movw r1, #('t' | ('h' << 8))
    movs r2, #1
    b 2f
1:  ldr r0, =set_uh_tenth
    ldrb r0, [r0]                           @ HY: 1..250 tenths, the units digit always drawn: "HY 0.1", "HY25.0"
    movw r1, #('H' | ('Y' << 8))
    movs r2, #2
2:  bl cu_text                              @ r1 = the five characters
    movs r0, #1                             @ sub display
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_cu_commit_req
    strb r0, [r1]
    pop {r4, pc}
    .ltorg
ENDFUNC set_cu_draw

@ -----------------------------------------------------------------------------
@ cu_text - two letters and a value 0..999 in three characters, leading zeros blank
@ In       : r0 = value 0..999, r1 = the two letters (first in bits 7..0, second in bits 15..8), r2 = digits always
@            drawn (1: the units, 2: the tens and the units)
@ Out      : r1 = set_cu_text5 (the five characters)
@ Clobbers : r0, r2, r3, flags
@ -----------------------------------------------------------------------------
LFUNC cu_text
    push {r4, r5, lr}
    ldr r4, =set_cu_text5
    strb r1, [r4, #0]
    lsrs r1, r1, #8
    strb r1, [r4, #1]
    movs r1, #100
    udiv r3, r0, r1                         @ r3 = hundreds
    mls r0, r3, r1, r0
    movs r1, #10
    udiv r5, r0, r1                         @ r5 = tens
    mls r0, r5, r1, r0                      @ r0 = units
    movs r1, #' '
    cmp r3, #0
    it ne
    addne r1, r3, #'0'
    strb r1, [r4, #2]                       @ hundreds, blank when 0
    cmp r2, #2
    it eq
    orreq r3, r3, #1                        @ two digits always drawn: the tens are drawn as with hundreds
    movs r1, #' '
    orrs r3, r3, r5
    it ne
    addne r1, r5, #'0'
    strb r1, [r4, #3]                       @ tens, blank when it and the hundreds are 0 (and only the units must show)
    adds r0, r0, #'0'
    strb r0, [r4, #4]                       @ units
    mov r1, r4
    pop {r4, r5, pc}
    .ltorg
ENDFUNC cu_text
