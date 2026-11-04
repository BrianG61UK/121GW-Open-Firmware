@ =============================================================================
@ logpg.s - SET: SETUP pages tr (logging trigger) and Ch (change threshold) (production image only, DESIGN.md 10
@ IMP-21, FEATURES.md 2.6)
@
@ SET module, part 12.  Item 30, page tr: "tr-In" (v2.05), "tr-Ch", "tr-Lt" (log/trigger.s); item 31, page Ch (offered
@ with tr-Ch only): "Ch" and the threshold 1..255 counts right-aligned.  Long SETUP starts the edit, REL steps up, PEAK
@ steps down, long SETUP saves, SETUP short ends the edit without a save, the edit times out after about 2 minutes
@ (fn_0800D190 re-reads the EEPROM).  Storage: tr in bits 2..1 of EEPROM 0x020 (set_b20_store, the other bits kept), Ch in
@ EEPROM 0x022 (0 reads as 1).
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


    .equ SET_CH_EEPROM,       0x022
    .equ set_lg_text5,        v_20007C30
    .equ set_lg_redraw,       v_20008062
    .equ set_lg_commit_req,   v_2000805B

    .section .rodata.set.logpg, "a", %progbits
set_tr_texts:
    .ascii "tr-In"
    .ascii "tr-Ch"
    .ascii "tr-Lt"

    .section .text.set.logpg, "ax", %progbits

@ -----------------------------------------------------------------------------
@ set_ch_load - load the change threshold from EEPROM 0x022 (0 reads as 1)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (set_state_reset; fn_0800D190)
@ -----------------------------------------------------------------------------
FUNC set_ch_load
    push {r4, lr}
    movs r0, #SET_CH_EEPROM
    bl eeprom_read_u8
    cmp r0, #0
    it eq
    moveq r0, #1                            @ 0 is not a threshold: 1 count
    ldr r1, =log_ch_thr
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_ch_load

@ -----------------------------------------------------------------------------
@ set_tr_edit - edit action of the page tr (item 30): 1 up, 2 down, 100 save
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ -----------------------------------------------------------------------------
FUNC set_tr_edit
    push {r4, lr}
    uxtb r4, r0
    ldr r1, =log_trig
    ldrb r0, [r1]
    cmp r4, #100
    beq .Ltr_save
    cmp r4, #1
    bne 1f
    adds r0, r0, #1                         @ up: In, Ch, Lt, In
    cmp r0, #2
    it hi
    movhi r0, #0
    b 2f
1:  subs r0, r0, #1                         @ down: In, Lt, Ch, In
    it mi
    movmi r0, #2
2:  strb r0, [r1]
    b .Ltr_redraw
.Ltr_save:
    lsls r1, r0, #1                         @ bits 2..1 = trigger
    movs r0, #6                             @ mask: bits 2..1
    bl set_b20_store
.Ltr_redraw:
    movs r0, #1
    ldr r1, =set_lg_redraw
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_tr_edit

@ -----------------------------------------------------------------------------
@ set_ch_edit - edit action of the page Ch (item 31): 1 up, 2 down (1..255 with wrap), 100 save
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ -----------------------------------------------------------------------------
FUNC set_ch_edit
    push {r4, lr}
    uxtb r4, r0
    ldr r1, =log_ch_thr
    ldrb r0, [r1]
    cmp r4, #100
    beq .Lch_save
    cmp r4, #1
    bne 1f
    adds r0, r0, #1                         @ up, 255 -> 1
    cmp r0, #255
    it hi
    movhi r0, #1
    b 2f
1:  subs r0, r0, #1                         @ down, 1 -> 255
    it eq
    moveq r0, #255
2:  strb r0, [r1]
    b .Lch_redraw
.Lch_save:
    mov r1, r0
    movs r0, #SET_CH_EEPROM
    movs r2, #1
    bl set_nvm_store                        @ SETTINGS class, armed inside
.Lch_redraw:
    movs r0, #1
    ldr r1, =set_lg_redraw
    strb r0, [r1]
    pop {r4, pc}
ENDFUNC set_ch_edit

@ -----------------------------------------------------------------------------
@ set_lg_draw - draw the page tr (r0 = 30) or Ch (r0 = 31)
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ -----------------------------------------------------------------------------
FUNC set_lg_draw
    push {r4, r5, lr}
    mov r5, r0
    ldr r0, =lcd_shadow
    ldr r1, [r0, #0x10]
    bic r1, r1, #0x20000000                 @ sub minus off
    str r1, [r0, #0x10]
    movs r0, #0
    bl fn_08017FB4                          @ sub decimal points off
    cmp r5, #30
    bne .Llg_ch
    ldr r0, =log_trig
    ldrb r0, [r0]
    cmp r0, #2
    it hi
    movhi r0, #0
    add r0, r0, r0, lsl #2
    ldr r1, =set_tr_texts
    add r1, r1, r0
    b .Llg_draw
.Llg_ch:
    ldr r4, =set_lg_text5
    movs r0, #'C'
    strb r0, [r4, #0]
    movs r0, #'h'
    strb r0, [r4, #1]
    ldr r0, =log_ch_thr
    ldrb r0, [r0]                           @ threshold 1..255, three characters right-aligned, leading zeros blank
    movs r2, #100
    udiv r1, r0, r2
    mls r0, r1, r2, r0                      @ r1 = hundreds, r0 = rest
    movs r2, #10
    udiv r3, r0, r2
    mls r0, r3, r2, r0                      @ r3 = tens, r0 = units
    cbz r1, 1f
    adds r1, r1, #'0'
    b 2f
1:  movs r1, #' '
2:  strb r1, [r4, #2]
    cmp r1, #' '
    bne 3f
    cbnz r3, 3f
    movs r3, #' '                           @ no hundreds and no tens: blank
    b 4f
3:  adds r3, r3, #'0'
4:  strb r3, [r4, #3]
    adds r0, r0, #'0'
    strb r0, [r4, #4]
    mov r1, r4
.Llg_draw:
    movs r0, #1
    bl lcd_draw_5char
    movs r0, #1
    ldr r1, =set_lg_commit_req
    strb r0, [r1]
    pop {r4, r5, pc}
ENDFUNC set_lg_draw

    .ltorg

