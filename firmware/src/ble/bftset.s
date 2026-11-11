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
@     0x16 GET   no payload: every setting.  Answer: field = number of entries, data = entries of id(2) value(1), in table order.
@                IMP-55 (GitHub issue 30): payload start(1) max(1): at most max entries (1..255) from entry start of the
@                table; field = the entries in this answer | 0x8000 when the last setting is among them (as LIST), so a
@                damaging link can fetch the settings in small answers.  start beyond the table, max 0 or another
@                payload length: status 0x22.
@                IMP-64: payload start(1) max(1) flags(1) with flags = 1: the same paging over every setting, the
@                two-byte ones included, as entries id(2) value(2, little endian); another flags value: status 0x22.
@                Without flags the answers hold the one-byte settings only (the first BFS_N entries of the table), so a
@                companion that parses id(2) value(1) entries never meets a two-byte value.
@     0x17 PUT   id(2) value(1), or (IMP-64) id(2) value(2, little endian).  Answer: field = id, data = the value now
@                in effect (1 byte, or 2 little endian for the two-byte form).  A two-byte setting needs the two-byte
@                form.  status 0 applied; 3 refused: a setting is being edited on the meter (set_edit); 0x22 unknown id
@                (or a two-byte setting with a one-byte value), value out of range, or payload length not 3 or 4.
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
@     0x014 continuity threshold  0..17   set_cont_code      -                        fn_08015C20      (page 10, BEEP)
@     0x015 Bluetooth rate        0..3    ble_rate           -                        set_bt_edit      (page bt)
@     0x016 auto power-off off    0..1    set_apo_disable    fn_08019C5C(1) Apo       fn_08015A22      (page 2)
@     0x017 backlight auto-off    0..100  pwr_bl_setting     pwr_bl_restart           set_bl_store     (page bL; bit 7 of
@                                                            the EEPROM byte, the remembered state, is kept by the store)
@     0x01A LCD contrast          10..17  lcd_contrast       (lcd_init inside save)   fn_08015B54      (page 4)
@     0x01B VA burden "bd"        0..1    set_va_bd_edit     -                        fn_08016190      (page 11; its save
@                                                            copies the edit buffer to set_va_bd)
@     0x01E buzzer setting        0..2    set_buzzer_on      -                        fn_08015A74      (page 3)
@     0x020 bit field             0..31   set_relp, log_trig, set_clk12, set_hunt_on, then set_b20_store (below)
@     0x021 continuity hold       0..3    set_bh_code        -                        set_bh_edit      (page bH)
@     0x022 logging change thr.   1..255  log_ch_thr         -                        set_ch_edit      (page Ch)
@     0x023 battery type          0..1    set_bat_nimh       -                        set_bat_edit     (page bAt, IMP-67;
@                                                            0 = alkaline, 1 = NiMH)
@     0x028 current-loop view     0..2    set_lp_code        -                        set_lp_edit      (page LP)
@     0x029 RTD view              0..2    set_rtd_code       -                        set_rtd_edit     (page Pt)
@     0x02A battery trim          50..150 set_btrim (= v - 100, signed)  -            set_btrim_edit   (battery page; v is the
@                                                            EEPROM byte = trim + 100, as the page stores it)
@     0x02B auto power-off time   0..3    pwr_apo_code       -                        fn_08015A22      (page 2; 0 = 30 min,
@                                                            1 = 1, 2 = 15, 3 = 60 min; its save also rewrites 0x016)
@     0x02C DIODE contact chirp   0..1    set_chirp_on       mres_chirp_reset         set_chirp_edit   (page CHIrP in DIODE,
@                                                            IMP-51; 0 = off, v2.05's jump chirp, 1 = on)
@     0x02F continuity hysteresis 1..250  set_uh_tenth       -                        set_uh_edit      (page HY, IMP-64;
@                                                            tenths of an ohm)
@     0x02D continuity threshold  1..500  set_ut_ohm (u16)   -                        set_ut_edit      (page th, IMP-64;
@           of the user codes                                ohm; two-byte, the last entry; stored in 0x02D..0x02E)
@ 0x020 holds four settings: bit 0 the REL view (page rEL), bits 2..1 the logging trigger 0..2 (page tr; 3 is refused),
@ bit 3 the clock (page CL), bit 4 the capacitance anti-hunting (page HUnt, IMP-45; 1 = on); bits 7..5 must be 0.  PUT sets
@ the four RAM variables (switching the anti-hunting off also clears its state, as the page does) and calls set_b20_store
@ with the mask 0x1F, which changes bits 4..0 of the byte and keeps bits 7..5 (EEPROM_MAP.md 4.1); the pages call it with
@ the mask of their own bits, one page at a time.
@ The save routines of the pages do not return the result of the EEPROM write (set_nvm_store's status is dropped by the
@ page code, as in v2.05): PUT answers the value in effect in RAM; a write the NVM layer refused is not reported.
@     0x018 logging interval      0..999  set_interval_edit (u16) -               fn_08015AC0      (page In, IMP-65;
@                                                            two-byte, after 0x02D; the save copies it to set_log_interval)
@ IMP-65: the same GET and PUT also arrive outside the page Ld through the meter API (ble/bfapi.s api_request), which
@ refuses PUT in calibration mode, while logging, in the MEM view and in the power-on window.
@ Not offered: the rotary memory 0x008..0x00E, the
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

    .equ BFS_N,             21              @ one-byte entries of bfs_tab, first in the table (checked below)
    .equ BFS_NW,            23              @ every entry, the two-byte ones last (IMP-64; 0x018 IMP-65)
    .equ BFS_REC,           28              @ bytes of one entry
    .equ BFS_ST_NOTALLOWED, 3
    .equ BFS_ST_ARG,        0x22
    .equ BFS_ACT_SAVE,      100             @ edit action "save" of the setup pages (fn_080165F4)
    .equ BFS_ARG_VALUE,     0xFF            @ side effect called with the value itself in r0
    .equ BFS_KIND_B20,      1               @ the bit field of EEPROM 0x020
    .equ BFS_KIND_U16,      2               @ a u16 RAM variable (IMP-64: the user continuity threshold)

    .equ bfs_set_edit,      v_2000806E      @ setup edit mode active (set/settings.s set_edit)
    .equ bfs_temp_celsius,  v_200080AB      @ set_temp_celsius
    .equ bfs_cont_code,     v_200080B6      @ set_cont_code
    .equ bfs_apo_disable,   v_20008039      @ set_apo_disable
    .equ bfs_va_bd,         v_200080A8      @ set_va_bd
    .equ bfs_va_bd_edit,    v_200080A9      @ set_va_bd_edit
    .equ bfs_buzzer_on,     v_20008078      @ set_buzzer_on
    .equ bfs_log_interval,  v_2000022C      @ set_log_interval (set/setup.s), u16
    .equ bfs_interval_edit, v_20007FA6      @ set_interval_edit (set/setup.s), u16

@ One entry (28 bytes): id(2) min(2) max(2) bias harg kind pad(3) get(4) set(4) hook(4) save(4), offsets 0, 2, 4, 6, 7,
@ 8, 12, 16, 20, 24.  value = RAM byte of get + bias (mod 256), or the RAM halfword for kind BFS_KIND_U16; the RAM
@ byte (halfword) of set = value - bias; hook(harg or the value in r0) when non-zero; save(100).  set = 0: the hook
@ sets the variable (mtmp_tc_select).
    .macro BFS_ENTRY id, min, max, bias, harg, kind, get, set, hook, save
    .hword \id, \min, \max
    .byte \bias, \harg, \kind, 0, 0, 0
    .word \get, \set, \hook, \save
    .endm

    .section .rodata.bftset, "a", %progbits
    .balign 4
bfs_tab:
    BFS_ENTRY 0x00F, 0,   5,   0,   BFS_ARG_VALUE, 0, mtmp_tc_type,     0,                mtmp_tc_select,  set_tc_edit
    BFS_ENTRY 0x010, 0,   1,   0,   0,             0, bfs_temp_celsius,  bfs_temp_celsius, fn_0801A3A4,     fn_08015BE0
    BFS_ENTRY 0x011, 0,   3,   0,   0,             0, set_dbm_ref,       set_dbm_ref,      0,               set_dbm_edit
    BFS_ENTRY 0x013, 0,   1,   0,   0,             0, func_dsp_level,    func_dsp_level,   0,               set_dsp_edit
    BFS_ENTRY 0x014, 0,   17,  0,   0,             0, bfs_cont_code,     bfs_cont_code,    0,               fn_08015C20
    BFS_ENTRY 0x015, 0,   3,   0,   0,             0, ble_rate,          ble_rate,         0,               set_bt_edit
    BFS_ENTRY 0x016, 0,   1,   0,   1,             0, bfs_apo_disable,   bfs_apo_disable,  fn_08019C5C,     fn_08015A22
    BFS_ENTRY 0x017, 0,   100, 0,   0,             0, pwr_bl_setting,    pwr_bl_setting,   pwr_bl_restart,  set_bl_store
    BFS_ENTRY 0x01A, 10,  17,  0,   0,             0, lcd_contrast,      lcd_contrast,     0,               fn_08015B54
    BFS_ENTRY 0x01B, 0,   1,   0,   0,             0, bfs_va_bd,         bfs_va_bd_edit,   0,               fn_08016190
    BFS_ENTRY 0x01E, 0,   2,   0,   0,             0, bfs_buzzer_on,     bfs_buzzer_on,    0,               fn_08015A74   @ 2 qUiEt (IMP-54)
    BFS_ENTRY 0x020, 0,   31,  0,   0,             BFS_KIND_B20, 0,      0,                0,               0
    BFS_ENTRY 0x021, 0,   3,   0,   0,             0, set_bh_code,       set_bh_code,      0,               set_bh_edit
    BFS_ENTRY 0x022, 1,   255, 0,   0,             0, log_ch_thr,        log_ch_thr,       0,               set_ch_edit
    BFS_ENTRY 0x023, 0,   1,   0,   0,             0, set_bat_nimh,      set_bat_nimh,     0,               set_bat_edit
    BFS_ENTRY 0x028, 0,   2,   0,   0,             0, set_lp_code,       set_lp_code,      0,               set_lp_edit
    BFS_ENTRY 0x029, 0,   2,   0,   0,             0, set_rtd_code,      set_rtd_code,     0,               set_rtd_edit
    BFS_ENTRY 0x02A, 50,  150, 100, 0,             0, set_btrim,         set_btrim,        0,               set_btrim_edit
    BFS_ENTRY 0x02B, 0,   3,   0,   0,             0, pwr_apo_code,      pwr_apo_code,     0,               fn_08015A22
    BFS_ENTRY 0x02C, 0,   1,   0,   0,             0, set_chirp_on,      set_chirp_on,     mres_chirp_reset, set_chirp_edit
    BFS_ENTRY 0x02F, 1,   250, 0,   0,             0, set_uh_tenth,      set_uh_tenth,     0,               set_uh_edit
bfs_tab_wide:                               @ the two-byte settings: GET with flags 1 and the two-byte PUT only
    BFS_ENTRY 0x02D, 1,   500, 0,   0,             BFS_KIND_U16, set_ut_ohm, set_ut_ohm,   0,               set_ut_edit
    @ IMP-65: the logging interval (page In, item 9) in seconds 0..999 as fn_08015AC0 steps it; set = the edit buffer,
    @ which the save action 100 copies to set_log_interval and stores (EEPROM 0x018, fn_08011248), as the page does
    BFS_ENTRY 0x018, 0,   999, 0,   0,             BFS_KIND_U16, bfs_log_interval, bfs_interval_edit, 0,      fn_08015AC0
    .size bfs_tab, . - bfs_tab
    .if (bfs_tab_wide - bfs_tab) != BFS_N * BFS_REC
    .error "BFS_N does not match the one-byte entries of bfs_tab"
    .endif
    .if (. - bfs_tab) != BFS_NW * BFS_REC
    .error "BFS_NW does not match the entries of bfs_tab"
    .endif

    .section .text.bftset, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bfs_value - the value of a setting as the companion sees it
@ In       : r0 = address of its bfs_tab entry
@ Out      : r0 = value (0..255; 0..65535 for a two-byte setting)
@ Clobbers : r1-r3, flags
@ -----------------------------------------------------------------------------
LFUNC bfs_value
    ldrb r1, [r0, #8]                       @ kind
    cmp r1, #BFS_KIND_B20
    beq .Lbv_b20
    cmp r1, #BFS_KIND_U16
    bne 1f
    ldr r1, [r0, #12]                       @ get address
    ldrh r0, [r1]                           @ the RAM halfword (no bias)
    bx lr
1:  ldr r1, [r0, #12]                       @ get address
    ldrb r2, [r0, #6]                       @ bias
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
@ bfs_get - GET: every setting of the table, or (IMP-55) a page of it
@ In       : bft_pkt (payload: none, start(1) max(1), or (IMP-64) start(1) max(1) flags(1) with flags = 1)
@ Out      : r0 = status; r1 = field: BFS_N without a payload, else the entries in this answer | 0x8000 when the last
@            setting of the request's table is among them; r2 = data length (data at bfx_ans + 9: id(2) value(1) per
@            entry, 3 bytes; with flags 1 id(2) value(2, little endian), 4 bytes)
@ Clobbers : r0-r3, r12, flags (r4-r9 saved; [sp] holds the paged flag in the slot of the saved r3)
@ Note     : r9 = the entries the request sees: BFS_N (the one-byte settings), or BFS_NW with flags 1; r8 = 1 for
@            two-byte values.
@ -----------------------------------------------------------------------------
FUNC bfs_get
    push {r3-r9, lr}
    ldr r4, =bft_pkt
    ldrb r0, [r4, #5]
    movs r6, #0                             @ r6 = first entry
    movs r7, #BFS_N                         @ r7 = most entries
    mov r9, r7                              @ r9 = entries of the table this request sees
    mov r8, r6                              @ r8 = 0: one-byte values
    str r6, [sp]                            @ paged flag: 0 = no payload, the answer of every version before IMP-55
    cbz r0, 2f                              @ no payload: every one-byte setting
    cmp r0, #3
    bne 5f
    ldrb r1, [r4, #8]                       @ IMP-64: flags
    cmp r1, #1
    bne .Lge_arg                            @ flags 1 (two-byte values, every setting) is the only one
    mov r8, r1
    movs r1, #BFS_NW
    mov r9, r1
    b 6f
5:  cmp r0, #2
    bne .Lge_arg                            @ the payload is none, start(1) max(1) or start(1) max(1) flags(1)
6:  ldrb r6, [r4, #6]                       @ start
    ldrb r7, [r4, #7]                       @ max
    cmp r7, #0
    beq .Lge_arg                            @ max 0 is refused
    cmp r6, r9
    bhi .Lge_arg                            @ start beyond the table (start = its length: no entry, the end)
    movs r0, #1
    str r0, [sp]                            @ paged
2:  sub r0, r9, r6                          @ r0 = entries from start to the end of the table
    cmp r7, r0
    it hi
    movhi r7, r0                            @ r7 = entries in this answer
    ldr r4, =bfs_tab
    movs r0, #BFS_REC
    mla r4, r6, r0, r4                      @ r4 = record of the first entry
    ldr r5, =bfx_ans
    adds r5, r5, #9
    movs r6, r7                             @ r6 = entries left to pack
    cbz r6, 3f
1:  ldrh r1, [r4]
    strb r1, [r5], #1
    lsrs r1, r1, #8
    strb r1, [r5], #1                       @ id
    mov r0, r4
    bl bfs_value
    strb r0, [r5], #1                       @ value (low byte)
    cmp r8, #0
    beq 7f
    lsrs r0, r0, #8
    strb r0, [r5], #1                       @ two-byte values: the high byte
7:  adds r4, r4, #BFS_REC
    subs r6, r6, #1
    bne 1b
3:  mov r1, r7                              @ field = entries in this answer
    ldr r0, [sp]
    cbz r0, 4f                              @ no payload: field = BFS_N as before (r7 = BFS_N)
    ldr r2, =bfs_tab
    movs r0, #BFS_REC
    mla r2, r9, r0, r2                      @ r2 = end of the entries this request sees
    cmp r4, r2
    it eq
    orreq r1, r1, #0x8000                   @ the last setting is in this answer
4:  add r2, r7, r7, lsl #1                  @ r2 = 3 * entries
    cmp r8, #0
    it ne
    addne r2, r2, r7                        @ two-byte values: 4 * entries
    movs r0, #0
    pop {r3-r9, pc}
.Lge_arg:
    movs r0, #BFS_ST_ARG                    @ 0x22: a payload that is not of the three forms, max 0, start beyond the table
    movs r1, #0
    movs r2, #0
    pop {r3-r9, pc}
ENDFUNC bfs_get

@ -----------------------------------------------------------------------------
@ bfs_put - PUT: set one setting as its setup page does
@ In       : bft_pkt (payload: id(2) value(1), or (IMP-64) id(2) value(2, little endian))
@ Out      : r0 = status, r1 = field, r2 = length of the data (the value now in effect at bfx_ans + 9: 1 byte, or 2
@            little endian for the two-byte form)
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Note     : The one-byte form looks up the BFS_N one-byte settings only, so a two-byte setting is "unknown" (0x22) to
@            it; the two-byte form looks up all BFS_NW, and the range check keeps a one-byte setting within 0..255.
@ -----------------------------------------------------------------------------
FUNC bfs_put
    push {r4-r7, lr}
    ldr r4, =bft_pkt
    ldrb r0, [r4, #5]
    cmp r0, #3
    beq 6f
    cmp r0, #4
    bne .Lpu_arg                            @ the payload is id(2) value(1) or id(2) value(2)
6:  ldr r1, =bfs_set_edit
    ldrb r1, [r1]
    cmp r1, #0
    bne .Lpu_busy                           @ a setting is being edited on the meter: its buffers are in use
    ldrb r1, [r4, #6]
    ldrb r2, [r4, #7]
    orr r5, r1, r2, lsl #8                  @ r5 = id
    ldrb r6, [r4, #8]                       @ r6 = value (its low byte)
    movs r3, #BFS_N                         @ one-byte form: the one-byte settings
    cmp r0, #4
    bne 7f
    ldrb r1, [r4, #9]
    orr r6, r6, r1, lsl #8                  @ two-byte form: r6 = value
    movs r3, #BFS_NW                        @ every setting
7:  mov r4, r0                              @ r4 = payload length (3 or 4), for the answer
    ldr r7, =bfs_tab
1:  ldrh r0, [r7]
    cmp r0, r5
    beq 2f
    adds r7, r7, #BFS_REC
    subs r3, r3, #1
    bne 1b
    b .Lpu_arg                              @ not a setting of the table
2:  ldrh r0, [r7, #2]
    cmp r6, r0
    blo .Lpu_arg                            @ below the minimum
    ldrh r0, [r7, #4]
    cmp r6, r0
    bhi .Lpu_arg                            @ above the maximum
    ldrb r0, [r7, #8]
    cmp r0, #BFS_KIND_B20
    beq .Lpu_b20
    @ 1. the RAM variable of the page
    ldr r0, [r7, #16]                       @ set address (0: the side effect sets it)
    cbz r0, 3f
    ldrb r1, [r7, #8]
    cmp r1, #BFS_KIND_U16
    bne 8f
    strh r6, [r0]                           @ a u16 variable (IMP-64)
    b 3f
8:  ldrb r1, [r7, #6]
    subs r1, r6, r1                         @ value - bias
    strb r1, [r0]
    @ 2. the side effect of the page's edit step
3:  ldr r3, [r7, #20]
    cbz r3, 4f
    ldrb r0, [r7, #7]                       @ argument
    cmp r0, #BFS_ARG_VALUE
    it eq
    moveq r0, r6                            @ the value itself
    blx r3
    @ 3. the save action of the page: its edit routine with the action 100, or the store routine
4:  ldr r3, [r7, #24]
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
    lsrs r0, r0, #8
    strb r0, [r1, #10]                      @ high byte (part of the data for the two-byte form only)
    mov r1, r5                              @ field = id
    subs r2, r4, #2                         @ data length: 1 for the one-byte form, 2 for the two-byte form
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
