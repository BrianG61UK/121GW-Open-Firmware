@ =============================================================================
@ bftset.s - BLE: remote settings over the Bluetooth transfer link (GET and PUT of the setup pages' values)
@ (production image only, DESIGN.md 10 IMP-37, FEATURES.md 2.11 stage 6)
@
@ The companion app can read and change the settings of the SETUP pages.  A setting is named by the offset of its byte in
@ the data EEPROM (EEPROM_MAP.md 4); the value is the value of the setup page, which for every id but 0x017 and 0x020
@ is the stored byte itself.  The requests arrive through bft_packet (ble/bft.s) under its gate (page Ld shown, Bluetooth
@ on, logging off, calibration mode off) and are answered with the type 0x82 answer of ble/bftsd.s, whose header and
@ statuses are described there.
@
@     0x16 GET   no payload (status 0x22 if there is one).  Answer: field = number of entries, data = entries of id(2) value(1), in table order
@     0x17 PUT   id(2) value(1).  Answer: field = id, data = the value now in effect (1 byte).
@                status 0 applied; 3 refused: a setting is being edited on the meter (set_edit); 0x22 unknown id, value
@                out of range, or payload length not 3.
@
@ PUT does what the meter's own page does when the value is edited and saved, in the same order and with the same
@ routines: (1) the RAM variable of the page gets the value, (2) the side effect the page's edit routine performs on each
@ step (an annunciator, the thermocouple table, the backlight countdown), (3) the page's save action: the edit routine
@ called with the action 100, or the store routine itself (set_bl_store, set_b20_store), which ends in set_nvm_store
@ (set/settings.s).  The write to the EEPROM therefore goes through the NVM settings class and its allow table only (the
@ ids below are all of that class, EEPROM_MAP.md 9.2); this module contains no EEPROM access and calls no nvm_ routine.
@
@ Settings (id, range of the value, RAM variable, side effect, save routine):
@     0x00F thermocouple type     0..5    mtmp_tc_type       mtmp_tc_select           set_tc_edit      (page tc)
@     0x010 temperature unit      0..1    set_temp_celsius   fn_0801A3A4 annunciator  fn_08015BE0      (page 0: 1 degC)
@     0x011 dBm reference         0..3    set_dbm_ref        -                        set_dbm_edit     (ACV page)
@     0x013 display level         0..1    func_dsp_level     -                        set_dsp_edit     (page dSP)
@     0x014 continuity threshold  0..15   set_cont_code      -                        fn_08015C20      (page 10, BEEP)
@     0x015 Bluetooth rate        0..3    ble_rate           -                        set_bt_edit      (page bt)
@     0x016 auto power-off off    0..1    set_apo_disable    fn_08019C5C(1) Apo       fn_08015A22      (page 2)
@     0x017 backlight auto-off    0..100  pwr_bl_setting     pwr_bl_restart           set_bl_store     (page bL; bit 7 of
@                                                            the EEPROM byte, the remembered state, is kept by the store)
@     0x01A LCD contrast          10..17  lcd_contrast       (lcd_init inside save)   fn_08015B54      (page 4)
@     0x01B VA burden "bd"        0..1    set_va_bd_edit     -                        fn_08016190      (page 11; its save
@                                                            copies the edit buffer to set_va_bd)
@     0x01E buzzer on             0..1    set_buzzer_on      -                        fn_08015A74      (page 3)
@     0x020 bit field             0..31   set_relp, log_trig, set_clk12, set_hunt_on, then set_b20_store (below)
@     0x021 continuity hold       0..3    set_bh_code        -                        set_bh_edit      (page bH)
@     0x022 logging change thr.   1..255  log_ch_thr         -                        set_ch_edit      (page Ch)
@     0x028 current-loop view     0..2    set_lp_code        -                        set_lp_edit      (page LP)
@     0x029 RTD view              0..2    set_rtd_code       -                        set_rtd_edit     (page Pt)
@     0x02A battery trim          50..150 set_btrim (= v - 100, signed)  -            set_btrim_edit   (battery page; v is the
@                                                            EEPROM byte = trim + 100, as the page stores it)
@     0x02B auto power-off time   0..3    pwr_apo_code       -                        fn_08015A22      (page 2; 0 = 30 min,
@                                                            1 = 1, 2 = 15, 3 = 60 min; its save also rewrites 0x016)
@ 0x020 holds four settings: bit 0 the REL view (page rEL), bits 2..1 the logging trigger 0..2 (page tr; 3 is refused),
@ bit 3 the clock (page CL), bit 4 the capacitance anti-hunting (page HUnt, IMP-45; 1 = on); bits 7..5 must be 0.  PUT sets
@ the four RAM variables (switching the anti-hunting off also clears its state, as the page does) and calls set_b20_store
@ with the mask 0x1F, which changes bits 4..0 of the byte and keeps bits 7..5 (EEPROM_MAP.md 4.1); the pages call it with
@ the mask of their own bits, one page at a time.
@ The save routines of the pages do not return the result of the EEPROM write (set_nvm_store's status is dropped by the
@ page code, as in v2.05): PUT answers the value in effect in RAM; a write the NVM layer refused is not reported.
@ Not offered: 0x018 (logging interval, 0..999 does not fit the one-byte value), the rotary memory 0x008..0x00E, the
@ identity, calibration, restore and user-zero bytes (EEPROM_MAP.md 9.2).
@
@ Context: main only (bft_packet through bfx_request).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ BFS_N,             18              @ entries of bfs_tab (checked against the table below)
    .equ BFS_REC,           24              @ bytes of one entry
    .equ BFS_ST_NOTALLOWED, 3
    .equ BFS_ST_ARG,        0x22
    .equ BFS_ACT_SAVE,      100             @ edit action "save" of the setup pages (fn_080165F4)
    .equ BFS_ARG_VALUE,     0xFF            @ side effect called with the value itself in r0
    .equ BFS_KIND_B20,      1               @ the bit field of EEPROM 0x020

    .equ bfs_set_edit,      v_2000806E      @ setup edit mode active (set/settings.s set_edit)
    .equ bfs_temp_celsius,  v_200080AB      @ set_temp_celsius
    .equ bfs_cont_code,     v_200080B6      @ set_cont_code
    .equ bfs_apo_disable,   v_20008039      @ set_apo_disable
    .equ bfs_va_bd,         v_200080A8      @ set_va_bd
    .equ bfs_va_bd_edit,    v_200080A9      @ set_va_bd_edit
    .equ bfs_buzzer_on,     v_20008078      @ set_buzzer_on

@ One entry (24 bytes): id(2) min max bias harg kind pad(1) get(4) set(4) hook(4) save(4).  value = RAM byte of get + bias (mod 256); the RAM
@ byte of set = value - bias; hook(harg or the value in r0) when non-zero; save(100).  set = 0: the hook sets the
@ variable (mtmp_tc_select).
    .macro BFS_ENTRY id, min, max, bias, harg, kind, get, set, hook, save
    .hword \id
    .byte \min, \max, \bias, \harg, \kind, 0
    .word \get, \set, \hook, \save
    .endm

    .section .rodata.bftset, "a", %progbits
    .balign 4
bfs_tab:
    BFS_ENTRY 0x00F, 0,   5,   0,   BFS_ARG_VALUE, 0, mtmp_tc_type,     0,                mtmp_tc_select,  set_tc_edit
    BFS_ENTRY 0x010, 0,   1,   0,   0,             0, bfs_temp_celsius,  bfs_temp_celsius, fn_0801A3A4,     fn_08015BE0
    BFS_ENTRY 0x011, 0,   3,   0,   0,             0, set_dbm_ref,       set_dbm_ref,      0,               set_dbm_edit
    BFS_ENTRY 0x013, 0,   1,   0,   0,             0, func_dsp_level,    func_dsp_level,   0,               set_dsp_edit
    BFS_ENTRY 0x014, 0,   15,  0,   0,             0, bfs_cont_code,     bfs_cont_code,    0,               fn_08015C20
    BFS_ENTRY 0x015, 0,   3,   0,   0,             0, ble_rate,          ble_rate,         0,               set_bt_edit
    BFS_ENTRY 0x016, 0,   1,   0,   1,             0, bfs_apo_disable,   bfs_apo_disable,  fn_08019C5C,     fn_08015A22
    BFS_ENTRY 0x017, 0,   100, 0,   0,             0, pwr_bl_setting,    pwr_bl_setting,   pwr_bl_restart,  set_bl_store
    BFS_ENTRY 0x01A, 10,  17,  0,   0,             0, lcd_contrast,      lcd_contrast,     0,               fn_08015B54
    BFS_ENTRY 0x01B, 0,   1,   0,   0,             0, bfs_va_bd,         bfs_va_bd_edit,   0,               fn_08016190
    BFS_ENTRY 0x01E, 0,   1,   0,   0,             0, bfs_buzzer_on,     bfs_buzzer_on,    0,               fn_08015A74
    BFS_ENTRY 0x020, 0,   31,  0,   0,             BFS_KIND_B20, 0,      0,                0,               0
    BFS_ENTRY 0x021, 0,   3,   0,   0,             0, set_bh_code,       set_bh_code,      0,               set_bh_edit
    BFS_ENTRY 0x022, 1,   255, 0,   0,             0, log_ch_thr,        log_ch_thr,       0,               set_ch_edit
    BFS_ENTRY 0x028, 0,   2,   0,   0,             0, set_lp_code,       set_lp_code,      0,               set_lp_edit
    BFS_ENTRY 0x029, 0,   2,   0,   0,             0, set_rtd_code,      set_rtd_code,     0,               set_rtd_edit
    BFS_ENTRY 0x02A, 50,  150, 100, 0,             0, set_btrim,         set_btrim,        0,               set_btrim_edit
    BFS_ENTRY 0x02B, 0,   3,   0,   0,             0, pwr_apo_code,      pwr_apo_code,     0,               fn_08015A22
    .size bfs_tab, . - bfs_tab
    .if (. - bfs_tab) != BFS_N * BFS_REC
    .error "BFS_N does not match the entries of bfs_tab"
    .endif

    .section .text.bftset, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bfs_value - the value of a setting as the companion sees it
@ In       : r0 = address of its bfs_tab entry
@ Out      : r0 = value (0..255)
@ Clobbers : r1-r3, flags
@ -----------------------------------------------------------------------------
LFUNC bfs_value
    ldrb r1, [r0, #6]                       @ kind
    cmp r1, #BFS_KIND_B20
    beq .Lbv_b20
    ldr r1, [r0, #8]                        @ get address
    ldrb r2, [r0, #4]                       @ bias
    ldrb r1, [r1]
    add r0, r1, r2
    uxtb r0, r0                             @ RAM byte + bias (the battery trim: t + 100)
    bx lr
.Lbv_b20:
    ldr r1, =set_relp
    ldrb r0, [r1]
    and r0, r0, #1                          @ bit 0: REL view
    ldr r1, =log_trig
    ldrb r2, [r1]
    and r2, r2, #3
    orr r0, r0, r2, lsl #1                  @ bits 2..1: logging trigger
    ldr r1, =set_clk12
    ldrb r2, [r1]
    and r2, r2, #1
    orr r0, r0, r2, lsl #3                  @ bit 3: clock
    ldr r1, =set_hunt_on
    ldrb r2, [r1]
    and r2, r2, #1
    orr r0, r0, r2, lsl #4                  @ bit 4: anti-hunting (IMP-45)
    bx lr
ENDFUNC bfs_value

@ -----------------------------------------------------------------------------
@ bfs_get - GET: every setting of the table
@ In       : -
@ Out      : r0 = 0 (status), r1 = BFS_N (field), r2 = 3 * BFS_N (data at bfx_ans + 9: id(2) value(1) per entry)
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
FUNC bfs_get
    push {r4-r6, lr}
    ldr r4, =bft_pkt
    ldrb r0, [r4, #5]
    cmp r0, #0
    bne .Lge_arg                            @ GET has no payload
    ldr r4, =bfs_tab
    ldr r5, =bfx_ans
    adds r5, r5, #9
    movs r6, #BFS_N
1:  ldrh r1, [r4]
    strb r1, [r5], #1
    lsrs r1, r1, #8
    strb r1, [r5], #1                       @ id
    mov r0, r4
    bl bfs_value
    strb r0, [r5], #1                       @ value
    adds r4, r4, #BFS_REC
    subs r6, r6, #1
    bne 1b
    movs r0, #0
    movs r1, #BFS_N
    movs r2, #(3 * BFS_N)
    pop {r4-r6, pc}
.Lge_arg:
    movs r0, #BFS_ST_ARG                    @ 0x22: a payload was sent
    movs r1, #0
    movs r2, #0
    pop {r4-r6, pc}
ENDFUNC bfs_get

@ -----------------------------------------------------------------------------
@ bfs_put - PUT: set one setting as its setup page does
@ In       : bft_pkt (payload: id(2) value(1))
@ Out      : r0 = status, r1 = field, r2 = length of the data (the value now in effect at bfx_ans + 9)
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
FUNC bfs_put
    push {r4-r7, lr}
    ldr r4, =bft_pkt
    ldrb r0, [r4, #5]
    cmp r0, #3
    bne .Lpu_arg                            @ the payload is id(2) value(1)
    ldr r0, =bfs_set_edit
    ldrb r0, [r0]
    cmp r0, #0
    bne .Lpu_busy                           @ a setting is being edited on the meter: its buffers are in use
    ldrb r1, [r4, #6]
    ldrb r2, [r4, #7]
    orr r5, r1, r2, lsl #8                  @ r5 = id
    ldrb r6, [r4, #8]                       @ r6 = value
    ldr r7, =bfs_tab
    movs r3, #BFS_N
1:  ldrh r0, [r7]
    cmp r0, r5
    beq 2f
    adds r7, r7, #BFS_REC
    subs r3, r3, #1
    bne 1b
    b .Lpu_arg                              @ not a setting of the table
2:  ldrb r0, [r7, #2]
    cmp r6, r0
    blo .Lpu_arg                            @ below the minimum
    ldrb r0, [r7, #3]
    cmp r6, r0
    bhi .Lpu_arg                            @ above the maximum
    ldrb r0, [r7, #6]
    cmp r0, #BFS_KIND_B20
    beq .Lpu_b20
    @ 1. the RAM variable of the page
    ldr r0, [r7, #12]                       @ set address (0: the side effect sets it)
    cbz r0, 3f
    ldrb r1, [r7, #4]
    subs r1, r6, r1                         @ value - bias
    strb r1, [r0]
    @ 2. the side effect of the page's edit step
3:  ldr r3, [r7, #16]
    cbz r3, 4f
    ldrb r0, [r7, #5]                       @ argument
    cmp r0, #BFS_ARG_VALUE
    it eq
    moveq r0, r6                            @ the value itself
    blx r3
    @ 3. the save action of the page: its edit routine with the action 100, or the store routine
4:  ldr r3, [r7, #20]
    movs r0, #BFS_ACT_SAVE
    blx r3
    b .Lpu_done
.Lpu_b20:
    tst r6, #0xE0
    bne .Lpu_arg                            @ bits 7..5 are not settings
    ubfx r0, r6, #1, #2
    cmp r0, #2
    bhi .Lpu_arg                            @ trigger 3 does not exist
    ldr r1, =log_trig
    strb r0, [r1]                           @ bits 2..1: logging trigger
    and r0, r6, #1
    ldr r1, =set_relp
    strb r0, [r1]                           @ bit 0: REL view
    ubfx r0, r6, #3, #1
    ldr r1, =set_clk12
    strb r0, [r1]                           @ bit 3: clock
    ubfx r0, r6, #4, #1
    ldr r1, =set_hunt_on
    strb r0, [r1]                           @ bit 4: capacitance anti-hunting (IMP-45)
    cbnz r0, 5f
    bl ah_reset                             @ off: no lock and no counted timeout may remain (the page does the same)
5:  movs r0, #0x1F                          @ mask: bits 4..0
    mov r1, r6
    bl set_b20_store                        @ read-modify-write of those bits through set_nvm_store
.Lpu_done:
    mov r0, r7
    bl bfs_value                            @ the value now in effect
    ldr r1, =bfx_ans
    strb r0, [r1, #9]
    mov r1, r5                              @ field = id
    movs r2, #1
    movs r0, #0
    pop {r4-r7, pc}
.Lpu_busy:
    movs r0, #BFS_ST_NOTALLOWED
    b .Lpu_stat
.Lpu_arg:
    movs r0, #BFS_ST_ARG
.Lpu_stat:
    movs r1, #0
    movs r2, #0
    pop {r4-r7, pc}
ENDFUNC bfs_put

    .ltorg
