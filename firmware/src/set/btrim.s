@ =============================================================================
@ btrim.s - SET: battery voltage trim on the SETUP battery page (production image only, DESIGN.md 10 IMP-27,
@ FEATURES.md 2.16)
@
@ The battery voltage follows the nominal divider (pwr/battery.s fn_08013728, OF-52).  The parts of each meter (R69 1 M,
@ R70 330 k, the 3.3 V reference) differ from nominal by a few percent (two meters: +3 % and -2 %, GitHub issue 2), and
@ neither v2.05 nor the port calibrates the reading.  The trim scales the filtered battery value by (1000 + 2 t) / 1000,
@ t = -50..+50 (0.2 % steps, -10 .. +10 %), so an owner can match the page to a reference meter.
@ Where: SETUP item 1 (the battery page "BAT5.0", not editable in v2.05).  Long SETUP starts the edit: the page shows
@ "bA" and the trimmed voltage in 0.01 V ("bA5.03", blinking); REL raises the trim one step, PEAK lowers it, the value
@ follows at the next battery reading (every 200 ms); long SETUP again saves; SETUP short ends the edit without a save
@ (the saved trim acts again at the next reading), and the edit timeout (about 2 minutes, fn_0800D190) re-reads the
@ EEPROM through set_btrim_load.
@ The trimmed value is the battery value everywhere: the page, the low-battery limit (4.1 V), and what reads 0x20007FBA.
@ Storage: EEPROM 0x02A (EEPROM_MAP.md 4.1), byte = t + 100 (50..150); any other value (0x00 and 0xFF included) reads as
@ t = 0, so an untouched byte means no trim.
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


    .equ SET_BTRIM_EEPROM,    0x02A         @ EEPROM offset of the trim byte (EEPROM_MAP.md 4.1)
    .equ SET_BTRIM_BIAS,      100           @ byte = t + 100
    .equ SET_BTRIM_MAX,       50            @ |t| <= 50: +-10 % in 0.2 % steps
    .equ set_btrim_redraw,    v_20008062    @ sub display redraw request
    .equ set_btrim_commit,    v_2000805B    @ LCD commit request

    .section .bss_port.set, "aw", %nobits
@ set_btrim: trim t being edited, signed -50..+50; set_btrim_saved: the trim in the EEPROM (owner SET; both read by
@ pwr_bat_trim, which takes set_btrim only while item 1 is being edited, so an edit left without a save by any path
@ (SETUP short, the dial, a mode change) stops acting at once)
    .global set_btrim, set_btrim_saved
set_btrim:      .space 1
set_btrim_saved: .space 1

    .section .text.set.btrim, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_btrim_load - load the battery trim from the EEPROM
@ Replaces : nothing in v2.05 (new: EEPROM 0x02A is not accessed by v2.05)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset at boot and after a STOP wake; fn_0800D190 when an edit times out)
@ -----------------------------------------------------------------------------
FUNC set_btrim_load
    push {r4, lr}
    movs r0, #SET_BTRIM_EEPROM
    bl eeprom_read_u8                       @ r0 = EEPROM byte 0x02A (cache or EEPROM, NVM reader)
    subs r0, r0, #SET_BTRIM_BIAS            @ t = byte - 100
    cmp r0, #SET_BTRIM_MAX
    bgt 1f
    cmn r0, #SET_BTRIM_MAX
    bge 2f
1:  movs r0, #0                             @ outside 50..150 (0x00, 0xFF included): no trim
2:  ldr r1, =set_btrim
    strb r0, [r1]
    ldr r1, =set_btrim_saved
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_btrim_load

@ -----------------------------------------------------------------------------
@ set_btrim_edit - edit action of the battery page (setup item 1)
@ In       : r0 = action: 1 up, 2 down, 100 save
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_080165F4)
@ Note     : up and down stop at +-50 (no wrap: the trim is a value, not a list).  Save writes EEPROM 0x02A = t + 100
@            through set_nvm_store (NVM skips a byte that does not change).
@ -----------------------------------------------------------------------------
FUNC set_btrim_edit
    push {r4, lr}
    uxtb r4, r0
    ldr r1, =set_btrim
    ldrsb r0, [r1]
    cmp r4, #1
    beq .Lbt_up
    cmp r4, #2
    beq .Lbt_down
    ldr r2, =set_btrim_saved
    strb r0, [r2]                           @ save (100): the saved trim ...
    adds r1, r0, #SET_BTRIM_BIAS            @ ... and EEPROM 0x02A = t + 100
    movs r0, #SET_BTRIM_EEPROM
    movs r2, #1
    bl set_nvm_store
    b .Lbt_redraw
.Lbt_up:
    cmp r0, #SET_BTRIM_MAX
    bge .Lbt_redraw                         @ at +10 %: stays
    adds r0, r0, #1
    b 1f
.Lbt_down:
    cmn r0, #SET_BTRIM_MAX
    ble .Lbt_redraw                         @ at -10 %: stays
    subs r0, r0, #1
1:  strb r0, [r1]
.Lbt_redraw:
    movs r0, #1
    ldr r1, =set_btrim_redraw
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_btrim_edit

@ -----------------------------------------------------------------------------
@ set_btrim_draw - draw the battery page while it is edited: "bA" and the trimmed voltage in 0.01 V
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0801797C, item 1 with set_edit != 0)
@ RAM      : reads pwr_bat_cv; writes lcd_shadow (sub minus off, decimal point 2, five characters), commit request
@ -----------------------------------------------------------------------------
FUNC set_btrim_draw
    push {r4, lr}
    sub sp, sp, #8
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    str r1, [r0, #0x10]
    movs r0, #2
    bl fn_08017FB4                          @ sub decimal point before the last two digits: "bA5.03"
    ldr r0, =pwr_bat_cv
    ldrh r0, [r0]
    movw r1, #999
    cmp r0, r1
    it hi
    movhi r0, r1                            @ three digits (the conversion gives at most 1013 x 1.1)
    movs r1, #'b'
    strb r1, [sp, #0]
    movs r1, #'A'
    strb r1, [sp, #1]
    movs r2, #10
    udiv r3, r0, r2                         @ r3 = v / 10
    mls r1, r3, r2, r0                      @ hundredths digit
    adds r1, r1, #'0'
    strb r1, [sp, #4]
    udiv r0, r3, r2
    mls r1, r0, r2, r3                      @ tenths digit
    adds r1, r1, #'0'
    strb r1, [sp, #3]
    adds r0, r0, #'0'                       @ volts digit (v < 1000)
    strb r0, [sp, #2]
    movs r0, #1                             @ sub display
    mov r1, sp
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_btrim_commit
    strb r0, [r1]
    add sp, sp, #8
    pop {r4, pc}
ENDFUNC set_btrim_draw

    .ltorg

