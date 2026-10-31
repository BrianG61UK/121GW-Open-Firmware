@ =============================================================================
@ short.s - KEY: the short-press action of every key (v2.05 handle_pg8_15_short_press 0x08014C3C)
@
@ A short press fires when its key is released (or at once during the power-on window).  The routine is one
@ dispatch on the key code followed by one block per key; the blocks are described in the routine.  All
@ calibration-mode requests go through CAL (fn_08015728 / fn_08015768), the display work through LCD / UI, the beeps
@ through BZB (fn_0800EE50 accept, fn_0800EE6C refusal).
@
@ Deviations: OF-17 (PEAK refused while the 1 kHz filter is on), OF-37 (switch CAL_FIX_SETUP_FALLTHROUGH).
@ Source of truth: analysis/keys_setup.md 2.2 and 3, checked against the v2.05 listing.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "key.inc"

    .section .text.key.short, "ax", %progbits

@ -----------------------------------------------------------------------------
@ handle_pg8_15_short_press - action of a short key press
@ Replaces : 0x08014C3C handle_pg8_15_short_press (v2.05)
@ In       : r0 = key code: 0x01 MODE, 0x02 SETUP, 0x04 MIN/MAX, 0x08 MEM, 0x10 RANGE, 0x20 HOLD, 0x40 REL, 0x80 PEAK
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main (fn_0801682C, fn_08014AE6)
@ RAM      : meter_mode, meter_range, range_manual, hold_active, hold_stage2, minmax_state, rel_active, peak_hold,
@            filter_1khz (all read), key_window/key_win_a/key_win_b (power-on window), key_logging, key_mem_view,
@            key_setup_item, key_setup_edit, key_cal_mode, key_cal_off_req, key_cal_gain_req and the other KEY
@            variables of key.inc; see the blocks below for what each key writes
@ Spec     : analysis/keys_setup.md 2.2 (per key table) and 3 (power-on window)
@ Deviation: OF-17 (PEAK refused while the 1 kHz filter is on), OF-37 (SETUP in calibration mode ends after its own
@            action; switch CAL_FIX_SETUP_FALLTHROUGH)
@ -----------------------------------------------------------------------------
FUNC handle_pg8_15_short_press

@ r4 = key code.  Dispatch on the code; an unknown code returns without a beep
    push {r4, lr}                       @ 08014C3C
    movs r4, r0                         @ 08014C3E
    uxtb r4, r4                         @ 08014C40
    movs r0, r4                         @ 08014C42
    cmp r0, #1                          @ 08014C44
    beq .Lsh_key_mode                   @ 08014C46
    cmp r0, #2                          @ 08014C48
    beq .Lsh_key_setup                  @ 08014C4A
    cmp r0, #4                          @ 08014C4E
    beq .Lsh_key_minmax                 @ 08014C50
    cmp r0, #8                          @ 08014C54
    beq .Lsh_key_mem                    @ 08014C56
    cmp r0, #0x10                       @ 08014C5A
    beq .Lsh_key_range                  @ 08014C5C
    cmp r0, #0x20                       @ 08014C5E
    beq .Lsh_key_hold_                  @ 08014C60
    cmp r0, #0x40                       @ 08014C64
    beq .Lsh_key_rel                    @ 08014C66
    cmp r0, #0x80                       @ 08014C6A
    beq .Lsh_key_peak                   @ 08014C6C
    b .Lsh_end                          @ 08014C70

@ ---- MODE ----  refused while logging or MEM view.  Outside the power-on window: cycle the mode.  In the window:
@ MODE starts the calibration entry (keys_setup.md 3: key_win_a = 1, window reload 2000, beep) or, after
@ MEM + REL/PEAK, confirms the cal.bin action (key_win_b = 3, window reload 5000, no beep)
@ reached from 08014C46 beq (equal / zero) after cmp r0, #1
.Lsh_key_mode:
    ldr r0, =key_logging                @ 08014C72
    ldrb r0, [r0]                       @ 08014C76
    ldr r1, =key_mem_view               @ 08014C78
    ldrb r1, [r1]                       @ 08014C7C
    orrs r0, r1                         @ 08014C7E
    uxtb r0, r0                         @ 08014C80
    cmp r0, #0                          @ 08014C82
    beq .Lsh_08014C8C                   @ 08014C84
    bl fn_0800EE6C                      @ 08014C86
    b .Lsh_end                          @ 08014C8A

@ power-on window test: closed (key_window == 0) = normal mode cycle
@ reached from 08014C84 beq (equal / zero) after cmp r0, #0
.Lsh_08014C8C:
    ldr r0, =key_window                 @ 08014C8C
    ldrh r0, [r0]                       @ 08014C90
    cmp r0, #0                          @ 08014C92
    beq .Lsh_cycle_mode                 @ 08014C94

@ window open and key_win_a == 0 and key_win_b == 0: first window key = MODE, calibration entry step 1
    ldr r0, =key_win_a                  @ 08014C96
    ldrb r0, [r0]                       @ 08014C9A
    cmp r0, #0                          @ 08014C9C
    bne .Lsh_08014CC4                   @ 08014C9E
    ldr r0, =key_win_b                  @ 08014CA0
    ldrb r0, [r0]                       @ 08014CA4
    cmp r0, #0                          @ 08014CA6
    bne .Lsh_08014CC4                   @ 08014CA8
    ldr r0, =key_win_a                  @ 08014CAA
    ldrb r0, [r0]                       @ 08014CAE
    adds r0, r0, #1                     @ 08014CB0
    ldr r1, =key_win_a                  @ 08014CB2
    strb r0, [r1]                       @ 08014CB6
    mov.w r0, #0x7D0                    @ 08014CB8
    ldr r1, =key_window                 @ 08014CBC
    strh r0, [r1]                       @ 08014CC0
    b .Lsh_accept_beep                  @ 08014CC2

@ key_win_a != 0, or key_win_b != 2: plain accept beep.  key_win_a == 0 and key_win_b == 2: confirm cal.bin action
@ reached from 08014C9E bne (not equal / non-zero) after cmp r0, #0
@              and from 08014CA8 bne (not equal / non-zero) after cmp r0, #0
.Lsh_08014CC4:
    ldr r0, =key_win_a                  @ 08014CC4
    ldrb r0, [r0]                       @ 08014CC8
    cmp r0, #0                          @ 08014CCA
    bne .Lsh_accept_beep                @ 08014CCC
    ldr r0, =key_win_b                  @ 08014CCE
    ldrb r0, [r0]                       @ 08014CD2
    cmp r0, #2                          @ 08014CD4
    bne .Lsh_accept_beep                @ 08014CD6
    movs r0, #3                         @ 08014CD8
    ldr r1, =key_win_b                  @ 08014CDA
    strb r0, [r1]                       @ 08014CDE
    movw r0, #0x1388                    @ 08014CE0
    ldr r1, =key_window                 @ 08014CE4
    strh r0, [r1]                       @ 08014CE8
    b .Lsh_end                          @ 08014CEA
@ reached from 08014C94 beq (equal / zero) after cmp r0, #0
.Lsh_cycle_mode:
    bl cycle_mode_on_bit0               @ 08014CEC

@ accept beep (fn_0800EE50), then return
@ reached from 08014CC2 b (jump)
@              and from 08014CCC bne (not equal / non-zero) after cmp r0, #0
@              and from 08014CD6 bne (not equal / non-zero) after cmp r0, #2
.Lsh_accept_beep:
    bl fn_0800EE50                      @ 08014CF0
    b .Lsh_end                          @ 08014CF4

@ ---- RANGE ----  in the power-on window with no sequence started: all LCD segments on (lamp test), window
@ reload 2000, no beep.  Outside the window: refused while logging, MEM view or MIN/MAX; in DIODE it switches
@ 3 V / 15 V; otherwise the range key proper (fn_08014796)
@ reached from 08014C5C beq (equal / zero) after cmp r0, #0x10
.Lsh_key_range:
    ldr r0, =key_window                 @ 08014CF6
    ldrh r0, [r0]                       @ 08014CFA
    cmp r0, #0                          @ 08014CFC
    beq .Lsh_range_normal               @ 08014CFE
    ldr r0, =key_win_a                  @ 08014D00
    ldrb r0, [r0]                       @ 08014D04
    cmp r0, #0                          @ 08014D06
    bne .Lsh_08014D26                   @ 08014D08
    ldr r0, =key_win_b                  @ 08014D0A
    ldrb r0, [r0]                       @ 08014D0E
    cmp r0, #0                          @ 08014D10
    bne .Lsh_08014D26                   @ 08014D12
    mov.w r0, #0x7D0                    @ 08014D14
    ldr r1, =key_window                 @ 08014D18
    strh r0, [r1]                       @ 08014D1C
    bl fn_0801A89C                      @ 08014D1E
    bl lcd_commit_shadow                @ 08014D22
@ reached from 08014D08 bne (not equal / non-zero) after cmp r0, #0
@              and from 08014D12 bne (not equal / non-zero) after cmp r0, #0
.Lsh_08014D26:
    b .Lsh_end                          @ 08014D26
@ reached from 08014CFE beq (equal / zero) after cmp r0, #0
.Lsh_range_normal:
    ldr r0, =key_logging                @ 08014D28
    ldrb r0, [r0]                       @ 08014D2C
    ldr r1, =key_mem_view               @ 08014D2E
    ldrb r1, [r1]                       @ 08014D32
    orrs r0, r1                         @ 08014D34
    uxtb r0, r0                         @ 08014D36
    cmp r0, #0                          @ 08014D38
    bne .Lsh_refuse_beep                @ 08014D3A
    ldr r0, =minmax_state               @ 08014D3C
    ldrb r0, [r0]                       @ 08014D40
    cmp r0, #0                          @ 08014D42
    beq .Lsh_08014D4C                   @ 08014D44

@ refusal beep (fn_0800EE6C), then return
@ reached from 08014D3A bne (not equal / non-zero) after cmp r0, #0
.Lsh_refuse_beep:
    bl fn_0800EE6C                      @ 08014D46
    b .Lsh_end                          @ 08014D4A

@ DIODE: toggle the 3 V / 15 V range (fn_080159C8) with accept beep; any other mode: RANGE key (fn_08014796)
@ reached from 08014D44 beq (equal / zero) after cmp r0, #0
.Lsh_08014D4C:
    ldr r0, =meter_mode                 @ 08014D4C
    ldrb r0, [r0]                       @ 08014D50
    cmp r0, #0xB                        @ 08014D52 mode 11 DIODE
    bne .Lsh_08014D60                   @ 08014D54
    bl fn_080159C8                      @ 08014D56
    bl fn_0800EE50                      @ 08014D5A
    b .Lsh_08014D64                     @ 08014D5E
@ reached from 08014D54 bne (not equal / non-zero) after cmp r0, #0xB
.Lsh_08014D60:
    bl fn_08014796                      @ 08014D60
@ reached from 08014D5E b (jump)
.Lsh_08014D64:
    b .Lsh_end                          @ 08014D64

@ ---- SETUP ----  in the window with no sequence started: key_win_a = 3 (date-code enable), reload 500.
@ Outside: refused while logging or MEM view.  Not in calibration mode: next setup item.  In calibration mode:
@ start an offset request (keys_setup.md 5.3)
@ reached from 08014C4A beq (equal / zero) after cmp r0, #2
.Lsh_key_setup:
    ldr r0, =key_window                 @ 08014D66
    ldrh r0, [r0]                       @ 08014D6A
    cmp r0, #0                          @ 08014D6C
    beq .Lsh_setup_normal               @ 08014D6E
    ldr r0, =key_win_a                  @ 08014D70
    ldrb r0, [r0]                       @ 08014D74
    cmp r0, #0                          @ 08014D76
    bne .Lsh_08014D96                   @ 08014D78
    ldr r0, =key_win_b                  @ 08014D7A
    ldrb r0, [r0]                       @ 08014D7E
    cmp r0, #0                          @ 08014D80
    bne .Lsh_08014D96                   @ 08014D82
    movs r0, #3                         @ 08014D84
    ldr r1, =key_win_a                  @ 08014D86
    strb r0, [r1]                       @ 08014D8A
    mov.w r0, #0x1F4                    @ 08014D8C
    ldr r1, =key_window                 @ 08014D90
    strh r0, [r1]                       @ 08014D94
@ reached from 08014D78 bne (not equal / non-zero) after cmp r0, #0
@              and from 08014D82 bne (not equal / non-zero) after cmp r0, #0
.Lsh_08014D96:
    b .Lsh_end                          @ 08014D96
@ reached from 08014D6E beq (equal / zero) after cmp r0, #0
.Lsh_setup_normal:
    ldr r0, =key_logging                @ 08014D98
    ldrb r0, [r0]                       @ 08014D9C
    ldr r1, =key_mem_view               @ 08014D9E
    ldrb r1, [r1]                       @ 08014DA2
    orrs r0, r1                         @ 08014DA4
    uxtb r0, r0                         @ 08014DA6
    cmp r0, #0                          @ 08014DA8
    beq .Lsh_08014DB2                   @ 08014DAA
    bl fn_0800EE6C                      @ 08014DAC
    b .Lsh_end                          @ 08014DB0

@ not in calibration mode: next setup item.  In calibration mode: ask CAL whether an offset request is allowed for
@ this mode and range (fn_08015728(0) = 1 refused), then start it (fn_08015768(0); result 2 = refused band)
@ reached from 08014DAA beq (equal / zero) after cmp r0, #0
.Lsh_08014DB2:
    ldr r0, =key_cal_mode               @ 08014DB2
    ldrb r0, [r0]                       @ 08014DB6
    cmp r0, #0                          @ 08014DB8
    beq .Lsh_setup_next                 @ 08014DBA
    movs r0, #0                         @ 08014DBC
    bl fn_08015728                      @ 08014DBE fn_08015728(kind 0 = offset)
    cmp r0, #0                          @ 08014DC2
    beq .Lsh_08014DCC                   @ 08014DC4
    bl fn_0800EE6C                      @ 08014DC6
    b .Lsh_end                          @ 08014DCA
@ reached from 08014DC4 beq (equal / zero) after cmp r0, #0
.Lsh_08014DCC:
    movs r0, #0                         @ 08014DCC
    bl fn_08015768                      @ 08014DCE fn_08015768(kind 0 = offset)
    cmp r0, #2                          @ 08014DD2
    .if CAL_FIX_SETUP_FALLTHROUGH           @ 08014DD4 replaces v2.05 bne 0x08014dee
        bne .Lsh_setup_started                @ OF-37: request started, SETUP is done
    .else
        bne .Lsh_key_mem                      @ v2.05: falls into the MEM-short code (refusal beep after a start)
    .endif
    bl fn_0800EE6C                      @ 08014DD6
    b .Lsh_end                          @ 08014DDA
    .ltorg
    .if CAL_FIX_SETUP_FALLTHROUGH
    .Lsh_setup_started:
        bl fn_0800EE50                        @ OF-37: accept beep, then return (v2.05 ran the MEM-short code)
        b .Lsh_end
    .endif

@ next setup item (fn_08015410), accept beep, request a redraw of the setup page (0x20008062 = 1)
@ reached from 08014DBA beq (equal / zero) after cmp r0, #0
.Lsh_setup_next:
    bl fn_08015410                      @ 08014DDC
    bl fn_0800EE50                      @ 08014DE0
    movs r0, #1                         @ 08014DE4
    ldr r1, =v_20008062                 @ 08014DE6
    strb r0, [r1]                       @ 08014DEA
    b .Lsh_end                          @ 08014DEC

@ ---- MEM ----  in the window with no sequence started: key_win_b = 1 (cal.bin menu), reload 5000, accept beep.
@ Outside: calibration mode = gain request; otherwise open or close the MEM view
@ reached from 08014C56 beq (equal / zero) after cmp r0, #8
@              and from 08014DD4 bne (not equal / non-zero) after cmp r0, #2
.Lsh_key_mem:
    ldr r0, =key_window                 @ 08014DEE
    ldrh r0, [r0]                       @ 08014DF2
    cmp r0, #0                          @ 08014DF4
    beq .Lsh_mem_normal                 @ 08014DF6
    ldr r0, =key_win_a                  @ 08014DF8
    ldrb r0, [r0]                       @ 08014DFC
    cmp r0, #0                          @ 08014DFE
    bne .Lsh_08014E22                   @ 08014E00
    ldr r0, =key_win_b                  @ 08014E02
    ldrb r0, [r0]                       @ 08014E06
    cmp r0, #0                          @ 08014E08
    bne .Lsh_08014E22                   @ 08014E0A
    movs r0, #1                         @ 08014E0C
    ldr r1, =key_win_b                  @ 08014E0E
    strb r0, [r1]                       @ 08014E12
    movw r0, #0x1388                    @ 08014E14
    ldr r1, =key_window                 @ 08014E18
    strh r0, [r1]                       @ 08014E1C
    bl fn_0800EE50                      @ 08014E1E
@ reached from 08014E00 bne (not equal / non-zero) after cmp r0, #0
@              and from 08014E0A bne (not equal / non-zero) after cmp r0, #0
.Lsh_08014E22:
    b .Lsh_end                          @ 08014E22

@ calibration mode: refused while a request is already running (key_cal_off_req | key_cal_gain_req)
@ reached from 08014DF6 beq (equal / zero) after cmp r0, #0
.Lsh_mem_normal:
    ldr r0, =key_cal_mode               @ 08014E24
    ldrb r0, [r0]                       @ 08014E28
    cmp r0, #0                          @ 08014E2A
    beq .Lsh_mem_view_toggle            @ 08014E2C
    ldr r0, =key_cal_off_req            @ 08014E2E
    ldrb r0, [r0]                       @ 08014E32
    ldr r1, =key_cal_gain_req           @ 08014E34
    ldrb r1, [r1]                       @ 08014E38
    orrs r0, r1                         @ 08014E3A
    uxtb r0, r0                         @ 08014E3C
    cmp r0, #0                          @ 08014E3E
    bne .Lsh_mem_refuse                 @ 08014E40
    movs r0, #1                         @ 08014E42
    bl fn_08015728                      @ 08014E44 fn_08015728(kind 1 = gain)
    cmp r0, #0                          @ 08014E48
    beq .Lsh_08014E52                   @ 08014E4A
    bl fn_0800EE6C                      @ 08014E4C
    b .Lsh_end                          @ 08014E50
@ reached from 08014E4A beq (equal / zero) after cmp r0, #0
.Lsh_08014E52:
    movs r0, #1                         @ 08014E52
    bl fn_08015768                      @ 08014E54 fn_08015768(kind 1 = gain)
    cmp r0, #2                          @ 08014E58
    bne .Lsh_08014E62                   @ 08014E5A
    bl fn_0800EE6C                      @ 08014E5C
    b .Lsh_end                          @ 08014E60
@ reached from 08014E5A bne (not equal / non-zero) after cmp r0, #2
.Lsh_08014E62:
    bl fn_0800EE50                      @ 08014E62
    b .Lsh_end_jump                     @ 08014E66
@ reached from 08014E40 bne (not equal / non-zero) after cmp r0, #0
.Lsh_mem_refuse:
    bl fn_0800EE6C                      @ 08014E68
    b .Lsh_end_jump                     @ 08014E6C

@ not calibration mode: refused while logging or with no stored record; else toggle the MEM view (key_mem_view)
@ reached from 08014E2C beq (equal / zero) after cmp r0, #0
.Lsh_mem_view_toggle:
    ldr r0, =key_logging                @ 08014E6E
    ldrb r0, [r0]                       @ 08014E72
    cmp r0, #0                          @ 08014E74
    beq .Lsh_08014E7E                   @ 08014E76
    bl fn_0800EE6C                      @ 08014E78
    b .Lsh_end_jump                     @ 08014E7C
@ reached from 08014E76 beq (equal / zero) after cmp r0, #0
.Lsh_08014E7E:
    ldr r0, =key_log_count              @ 08014E7E
    ldrh r0, [r0]                       @ 08014E82
    cmp r0, #0                          @ 08014E84
    bne .Lsh_08014E8E                   @ 08014E86
    bl fn_0800EE6C                      @ 08014E88
    b .Lsh_end_jump                     @ 08014E8C
@ reached from 08014E86 bne (not equal / non-zero) after cmp r0, #0
.Lsh_08014E8E:
    ldr r0, =key_mem_view               @ 08014E8E
    ldrb r0, [r0]                       @ 08014E92
    teq r0, #1                          @ 08014E94
    beq .Lsh_08014EA4                   @ 08014E98
    movs r0, #1                         @ 08014E9A
    ldr r1, =key_mem_view               @ 08014E9C
    strb r0, [r1]                       @ 08014EA0
    b .Lsh_08014EAC                     @ 08014EA2
@ reached from 08014E98 beq (equal / zero) after teq r0, #1
.Lsh_08014EA4:
    movs r0, #0                         @ 08014EA4
    ldr r1, =key_mem_view               @ 08014EA6
    strb r0, [r1]                       @ 08014EAA

@ view opened: clear the timeout, setup item 100, start at the record numbered by 0x20007FA2 (owner LOG) and draw it
@ with the view routines (LCD, LOG, UI); view closed: fn_080153AC ends the view (default setup item)
@ reached from 08014EA2 b (jump)
.Lsh_08014EAC:
    ldr r0, =key_mem_view               @ 08014EAC
    ldrb r0, [r0]                       @ 08014EB0
    cmp r0, #0                          @ 08014EB2
    beq .Lsh_08014EF4                   @ 08014EB4
    movs r0, #0                         @ 08014EB6
    ldr r1, =key_view_timer             @ 08014EB8
    strh r0, [r1]                       @ 08014EBC
    movs r0, #0x64                      @ 08014EBE
    ldr r1, =key_setup_item             @ 08014EC0
    strb r0, [r1]                       @ 08014EC4
    ldr r0, =v_20007FA2                 @ 08014EC6
    ldrh r0, [r0]                       @ 08014ECA
    ldr r1, =key_view_index             @ 08014ECC
    strh r0, [r1]                       @ 08014ED0
    movs r0, #0                         @ 08014ED2
    bl fn_08017FB4                      @ 08014ED4
    bl fn_08010CE2                      @ 08014ED8
    bl fn_0801772E                      @ 08014EDC
    ldr r0, =key_view_index             @ 08014EE0
    ldrh r0, [r0]                       @ 08014EE4
    bl fn_080170AC                      @ 08014EE6
    bl fn_08010D92                      @ 08014EEA
    bl fn_08010E98                      @ 08014EEE
    b .Lsh_mem_done                     @ 08014EF2
@ reached from 08014EB4 beq (equal / zero) after cmp r0, #0
.Lsh_08014EF4:
    bl fn_080153AC                      @ 08014EF4
@ reached from 08014EF2 b (jump)
.Lsh_mem_done:
    movs r0, #1                         @ 08014EF8
    bl fn_0801A32A                      @ 08014EFA
    bl fn_0800EE50                      @ 08014EFE
@ reached from 08014E66 b (jump)
@              and from 08014E6C b (jump)
@              and from 08014E7C b (jump)
@              and from 08014E8C b (jump)
.Lsh_end_jump:
    b .Lsh_end                          @ 08014F02

@ ---- HOLD ----  refused while logging or MEM view.  First press: hold the displayed value, freeze the range.
@ Second press: auto-hold (stage 2), or hold off in FREQ / PULSE / DUTY / CAP and with MIN/MAX.  Third press: off
@ reached from 08014C60 beq (equal / zero) after cmp r0, #0x20
.Lsh_key_hold_:
    ldr r0, =key_logging                @ 08014F04
    ldrb r0, [r0]                       @ 08014F08
    ldr r1, =key_mem_view               @ 08014F0A
    ldrb r1, [r1]                       @ 08014F0E
    orrs r0, r1                         @ 08014F10
    uxtb r0, r0                         @ 08014F12
    cmp r0, #0                          @ 08014F14
    beq .Lsh_08014F1E                   @ 08014F16
    bl fn_0800EE6C                      @ 08014F18
    b .Lsh_end                          @ 08014F1C

@ first press: hold_active = 1, held value 0x20007D6C = last drawn value 0x20007D70; with MIN/MAX running it is the
@ value at 0x20007D9C instead; otherwise range_manual is saved in 0x20008044 and set (AUTO annunciator off)
@ reached from 08014F16 beq (equal / zero) after cmp r0, #0
.Lsh_08014F1E:
    ldr r0, =hold_active                @ 08014F1E
    ldrb r0, [r0]                       @ 08014F22
    ldr r1, =hold_stage2                @ 08014F24
    ldrb r1, [r1]                       @ 08014F28
    orrs r0, r1                         @ 08014F2A
    uxtb r0, r0                         @ 08014F2C
    cmp r0, #0                          @ 08014F2E
    bne .Lsh_hold_second                @ 08014F30
    movs r0, #1                         @ 08014F32
    ldr r1, =hold_active                @ 08014F34
    strb r0, [r1]                       @ 08014F38
    ldr r0, =v_20007D70                 @ 08014F3A
    ldr r0, [r0]                        @ 08014F3E
    ldr r1, =v_20007D6C                 @ 08014F40
    str r0, [r1]                        @ 08014F44
    ldr r0, =minmax_state               @ 08014F46
    ldrb r0, [r0]                       @ 08014F4A
    cmp r0, #0                          @ 08014F4C
    beq .Lsh_08014F5E                   @ 08014F4E
    ldr r0, =v_20007D9C                 @ 08014F50
    ldr r0, [r0]                        @ 08014F54
    ldr r1, =v_20007D6C                 @ 08014F56
    str r0, [r1]                        @ 08014F5A
    b .Lsh_hold_done                    @ 08014F5C
@ reached from 08014F4E beq (equal / zero) after cmp r0, #0
.Lsh_08014F5E:
    ldr r0, =range_manual               @ 08014F5E
    ldrb r0, [r0]                       @ 08014F62
    ldr r1, =key_range_saved            @ 08014F64
    strb r0, [r1]                       @ 08014F68
    movs r0, #1                         @ 08014F6A
    ldr r1, =range_manual               @ 08014F6C
    strb r0, [r1]                       @ 08014F70
    movs r0, #0                         @ 08014F72
    bl fn_08019D68                      @ 08014F74
    b .Lsh_hold_done                    @ 08014F78
    .ltorg

@ a HOLD flag is already set: with hold_active set this is the second press (hold off for FREQ / PULSE / DUTY / CAP
@ and with MIN/MAX, else auto-hold stage 2 by fn_0801584C(1, 0))
@ reached from 08014F30 bne (not equal / non-zero) after cmp r0, #0
.Lsh_hold_second:
    ldr r0, =hold_active                @ 08014F7A
    ldrb r0, [r0]                       @ 08014F7E
    cmp r0, #0                          @ 08014F80
    beq .Lsh_hold_third                 @ 08014F82
    ldr r0, =meter_mode                 @ 08014F84
    ldrb r0, [r0]                       @ 08014F88
    cmp r0, #6                          @ 08014F8A mode 6 FREQ
    beq .Lsh_hold_off                   @ 08014F8C
    ldr r0, =meter_mode                 @ 08014F8E
    ldrb r0, [r0]                       @ 08014F92
    cmp r0, #7                          @ 08014F94 mode 7 PULSE
    beq .Lsh_hold_off                   @ 08014F96
    ldr r0, =meter_mode                 @ 08014F98
    ldrb r0, [r0]                       @ 08014F9C
    cmp r0, #8                          @ 08014F9E mode 8 DUTY
    beq .Lsh_hold_off                   @ 08014FA0
    ldr r0, =meter_mode                 @ 08014FA2
    ldrb r0, [r0]                       @ 08014FA6
    cmp r0, #0xC                        @ 08014FA8 mode 12 CAP
    beq .Lsh_hold_off                   @ 08014FAA
    ldr r0, =minmax_state               @ 08014FAC
    ldrb r0, [r0]                       @ 08014FB0
    cmp r0, #0                          @ 08014FB2
    beq .Lsh_08014FC8                   @ 08014FB4
@ reached from 08014F8C beq (equal / zero) after cmp r0, #6
@              and from 08014F96 beq (equal / zero) after cmp r0, #7
@              and from 08014FA0 beq (equal / zero) after cmp r0, #8
@              and from 08014FAA beq (equal / zero) after cmp r0, #0xC
.Lsh_hold_off:
    movs r0, #0                         @ 08014FB6
    ldr r1, =hold_active                @ 08014FB8
    strb r0, [r1]                       @ 08014FBC
    movs r0, #0                         @ 08014FBE
    ldr r1, =hold_stage2                @ 08014FC0
    strb r0, [r1]                       @ 08014FC4
    b .Lsh_08014FD0                     @ 08014FC6
@ reached from 08014FB4 beq (equal / zero) after cmp r0, #0
.Lsh_08014FC8:
    movs r1, #0                         @ 08014FC8
    movs r0, #1                         @ 08014FCA
    bl fn_0801584C                      @ 08014FCC
@ reached from 08014FC6 b (jump)
.Lsh_08014FD0:
    ldr r0, =minmax_state               @ 08014FD0
    ldrb r0, [r0]                       @ 08014FD4
    cmp r0, #0                          @ 08014FD6
    bne .Lsh_hold_done                  @ 08014FD8
    ldr r0, =key_range_saved            @ 08014FDA
    ldrb r0, [r0]                       @ 08014FDE
    ldr r1, =range_manual               @ 08014FE0
    strb r0, [r1]                       @ 08014FE4
    movs r0, #0                         @ 08014FE6
    bl fn_08019D68                      @ 08014FE8
    b .Lsh_hold_done                    @ 08014FEC

@ hold_active clear, so only hold_stage2 is set: third press, both flags off
@ reached from 08014F82 beq (equal / zero) after cmp r0, #0
.Lsh_hold_third:
    movs r0, #0                         @ 08014FEE
    ldr r1, =hold_active                @ 08014FF0
    strb r0, [r1]                       @ 08014FF4
    movs r0, #0                         @ 08014FF6
    ldr r1, =hold_stage2                @ 08014FF8
    strb r0, [r1]                       @ 08014FFC

@ common end of HOLD: AUTO annunciator (fn_08019D68), A- annunciator (fn_08019FA2), accept beep
@ reached from 08014F5C b (jump)
@              and from 08014F78 b (jump)
@              and from 08014FD8 bne (not equal / non-zero) after cmp r0, #0
@              and from 08014FEC b (jump)
.Lsh_hold_done:
    movs r0, #0                         @ 08014FFE
    bl fn_08019D68                      @ 08015000
    movs r0, #1                         @ 08015004
    bl fn_08019FA2                      @ 08015006
    bl fn_0800EE50                      @ 0801500A
    b .Lsh_end                          @ 0801500E

@ ---- REL ----  in the window: with key_win_a = 1 the calibration entry is confirmed (key_win_a = 2, reload 500);
@ with key_win_b = 1 REL chooses cal.bin save (key_win_b = 2, key_win_save = 1, reload 5000).
@ Outside: setup edit = UP, MEM view = next record, else switch REL on or off
@ reached from 08014C66 beq (equal / zero) after cmp r0, #0x40
.Lsh_key_rel:
    ldr r0, =key_window                 @ 08015010
    ldrh r0, [r0]                       @ 08015014
    cmp r0, #0                          @ 08015016
    beq .Lsh_rel_normal                 @ 08015018

@ window open: key_win_a == 1 and key_win_b == 0 confirms the calibration entry: key_win_a = 2, reload 500 (the
@ power-on loop of CAL then enters calibration mode)
    ldr r0, =key_win_a                  @ 0801501A
    ldrb r0, [r0]                       @ 0801501E
    cmp r0, #1                          @ 08015020
    bne .Lsh_08015048                   @ 08015022
    ldr r0, =key_win_b                  @ 08015024
    ldrb r0, [r0]                       @ 08015028
    cmp r0, #0                          @ 0801502A
    bne .Lsh_08015048                   @ 0801502C
    ldr r0, =key_win_a                  @ 0801502E
    ldrb r0, [r0]                       @ 08015032
    adds r0, r0, #1                     @ 08015034
    ldr r1, =key_win_a                  @ 08015036
    strb r0, [r1]                       @ 0801503A
    mov.w r0, #0x1F4                    @ 0801503C
    ldr r1, =key_window                 @ 08015040
    strh r0, [r1]                       @ 08015044
    b .Lsh_accept_end                   @ 08015046

@ key_win_a == 0 and key_win_b == 1 (MEM pressed): REL chooses the cal.bin save
@ reached from 08015022 bne (not equal / non-zero) after cmp r0, #1
@              and from 0801502C bne (not equal / non-zero) after cmp r0, #0
.Lsh_08015048:
    ldr r0, =key_win_a                  @ 08015048
    ldrb r0, [r0]                       @ 0801504C
    cmp r0, #0                          @ 0801504E
    bne .Lsh_accept_end                 @ 08015050
    ldr r0, =key_win_b                  @ 08015054
    ldrb r0, [r0]                       @ 08015058
    cmp r0, #1                          @ 0801505A
    bne .Lsh_accept_end                 @ 0801505C
    movs r0, #2                         @ 08015060
    ldr r1, =key_win_b                  @ 08015062
    strb r0, [r1]                       @ 08015066
    movs r0, #1                         @ 08015068
    ldr r1, =key_win_save               @ 0801506A
    strb r0, [r1]                       @ 0801506E
    movw r0, #0x1388                    @ 08015070
    ldr r1, =key_window                 @ 08015074
    strh r0, [r1]                       @ 08015078
    b .Lsh_accept_end                   @ 0801507A

@ window closed: setup edit = UP (fn_080165F4(1)); MEM view = next record; else switch REL
@ reached from 08015018 beq (equal / zero) after cmp r0, #0
.Lsh_rel_normal:
    ldr r0, =key_setup_edit             @ 0801507C
    ldrb r0, [r0]                       @ 08015080
    cmp r0, #0                          @ 08015082
    beq .Lsh_rel_view                   @ 08015084
    movs r0, #1                         @ 08015086
    bl fn_080165F4                      @ 08015088
    b .Lsh_accept_end                   @ 0801508C

@ MEM view: next record (key_view_index + 1, wrapping to 1 after key_view_last), clear the view timeout, redraw
@ the record (fn_080170AC)
@ reached from 08015084 beq (equal / zero) after cmp r0, #0
.Lsh_rel_view:
    ldr r0, =key_mem_view               @ 0801508E
    ldrb r0, [r0]                       @ 08015092
    cmp r0, #0                          @ 08015094
    beq .Lsh_rel_toggle                 @ 08015096
    ldr r0, =key_view_index             @ 08015098
    ldrh r0, [r0]                       @ 0801509C
    adds r0, r0, #1                     @ 0801509E
    ldr r1, =key_view_index             @ 080150A0
    strh r0, [r1]                       @ 080150A4
    ldr r0, =key_view_last              @ 080150A6
    ldrh r0, [r0]                       @ 080150AA
    ldr r1, =key_view_index             @ 080150AC
    ldrh r1, [r1]                       @ 080150B0
    cmp r0, r1                          @ 080150B2
    bcs .Lsh_080150BE                   @ 080150B4
    movs r0, #1                         @ 080150B6
    ldr r1, =key_view_index             @ 080150B8
    strh r0, [r1]                       @ 080150BC
@ reached from 080150B4 bcs (unsigned >=) after cmp r0, r1
.Lsh_080150BE:
    movs r0, #0                         @ 080150BE
    ldr r1, =key_view_timer             @ 080150C0
    strh r0, [r1]                       @ 080150C4
    ldr r0, =key_view_index             @ 080150C6
    ldrh r0, [r0]                       @ 080150CA
    bl fn_080170AC                      @ 080150CC
    b .Lsh_accept_end                   @ 080150D0

@ not in LowZ (refused there).  Skipped while the overload latch is set and REL is off
@ reached from 08015096 beq (equal / zero) after cmp r0, #0
.Lsh_rel_toggle:
    ldr r0, =meter_mode                 @ 080150D2
    ldrb r0, [r0]                       @ 080150D6
    cmp r0, #0                          @ 080150D8 mode 0 LowZ
    bne .Lsh_080150E2                   @ 080150DA
    bl fn_0800EE6C                      @ 080150DC
    b .Lsh_end                          @ 080150E0
@ reached from 080150DA bne (not equal / non-zero) after cmp r0, #0
.Lsh_080150E2:
    ldr r0, =key_ol_latch               @ 080150E2
    ldrb r0, [r0]                       @ 080150E6
    ldr r1, =rel_active                 @ 080150E8
    ldrb r1, [r1]                       @ 080150EC
    eors r1, r1, #1                     @ 080150EE
    tst r0, r1                          @ 080150F2
    bne .Lsh_rel_done                   @ 080150F4

@ toggle rel_active.  Going on: freeze the range (save range_manual in 0x200080ED), take over the held value
@ if HOLD is active; going off: restore range_manual from 0x200080ED and clear the REL base value 0x20007DA8
    ldr r0, =rel_active                 @ 080150F8
    ldrb r0, [r0]                       @ 080150FC
    teq r0, #1                          @ 080150FE
    beq .Lsh_0801510E                   @ 08015102
    movs r0, #1                         @ 08015104
    ldr r1, =rel_active                 @ 08015106
    strb r0, [r1]                       @ 0801510A
    b .Lsh_08015116                     @ 0801510C
    .ltorg
@ reached from 08015102 beq (equal / zero) after teq r0, #1
.Lsh_0801510E:
    movs r0, #0                         @ 0801510E
    ldr r1, =rel_active                 @ 08015110
    strb r0, [r1]                       @ 08015114
@ reached from 0801510C b (jump)
.Lsh_08015116:
    ldr r0, =rel_active                 @ 08015116
    ldrb r0, [r0]                       @ 0801511A
    cmp r0, #0                          @ 0801511C
    beq .Lsh_08015192                   @ 0801511E
    ldr r0, =range_manual               @ 08015120
    ldrb r0, [r0]                       @ 08015122
    ldr r1, =key_rel_range_sv           @ 08015124
    strb r0, [r1]                       @ 08015128
    movs r0, #1                         @ 0801512A
    ldr r1, =range_manual               @ 0801512C
    strb r0, [r1]                       @ 0801512E
    ldr r0, =hold_active                @ 08015130
    ldrb r0, [r0]                       @ 08015134
    cmp r0, #0                          @ 08015136
    beq .Lsh_0801515C                   @ 08015138
    ldr r0, =v_20007D6C                 @ 0801513A
    ldr r0, [r0]                        @ 0801513E
    ldr r1, =v_20007DA8                 @ 08015140
    str r0, [r1]                        @ 08015144
    movs r3, #0                         @ 08015146
    movs r2, #0                         @ 08015148
    ldr r0, =v_2000803F                 @ 0801514A
    ldrb r1, [r0]                       @ 0801514E
    ldr r0, =meter_mode                 @ 08015150
    ldrb r0, [r0]                       @ 08015154
    bl lcd_show_value_pos5_9            @ 08015156
    b .Lsh_rel_done                     @ 0801515A
@ reached from 08015138 beq (equal / zero) after cmp r0, #0
.Lsh_0801515C:
    ldr r0, =hold_stage2                @ 0801515C
    ldrb r0, [r0]                       @ 08015160
    cmp r0, #0                          @ 08015162
    beq .Lsh_08015188                   @ 08015164
    ldr r0, =v_20007DAC                 @ 08015166
    ldr r0, [r0]                        @ 0801516A
    ldr r1, =v_20007DA8                 @ 0801516C
    str r0, [r1]                        @ 08015170
    movs r3, #0                         @ 08015172
    movs r2, #0                         @ 08015174
    ldr r0, =v_2000803F                 @ 08015176
    ldrb r1, [r0]                       @ 0801517A
    ldr r0, =meter_mode                 @ 0801517C
    ldrb r0, [r0]                       @ 08015180
    bl lcd_show_value_pos5_9            @ 08015182
    b .Lsh_rel_done                     @ 08015186
@ reached from 08015164 beq (equal / zero) after cmp r0, #0
.Lsh_08015188:
    movs r0, #1                         @ 08015188
    ldr r1, =key_rel_on_flag            @ 0801518A
    strb r0, [r1]                       @ 0801518E
    b .Lsh_rel_done                     @ 08015190
@ reached from 0801511E beq (equal / zero) after cmp r0, #0
.Lsh_08015192:
    ldr r0, =key_rel_range_sv           @ 08015192
    ldrb r0, [r0]                       @ 08015196
    cmp r0, #0                          @ 08015198
    beq .Lsh_080151A4                   @ 0801519A
    movs r0, #1                         @ 0801519C
    ldr r1, =range_manual               @ 0801519E
    strb r0, [r1]                       @ 080151A0
    b .Lsh_080151AA                     @ 080151A2
@ reached from 0801519A beq (equal / zero) after cmp r0, #0
.Lsh_080151A4:
    movs r0, #0                         @ 080151A4
    ldr r1, =range_manual               @ 080151A6
    strb r0, [r1]                       @ 080151A8
@ reached from 080151A2 b (jump)
.Lsh_080151AA:
    movs r0, #0                         @ 080151AA
    ldr r1, =v_20007DA8                 @ 080151AC
    str r0, [r1]                        @ 080151B0
    ldr r0, =hold_active                @ 080151B2
    ldrb r0, [r0]                       @ 080151B6
    cmp r0, #0                          @ 080151B8
    beq .Lsh_080151D6                   @ 080151BA
    movs r3, #0                         @ 080151BC
    ldr r0, =v_20007D6C                 @ 080151BE
    ldr r2, [r0]                        @ 080151C2
    ldr r0, =v_2000803F                 @ 080151C4
    ldrb r1, [r0]                       @ 080151C8
    ldr r0, =meter_mode                 @ 080151CA
    ldrb r0, [r0]                       @ 080151CE
    bl lcd_show_value_pos5_9            @ 080151D0
    b .Lsh_rel_done                     @ 080151D4
@ reached from 080151BA beq (equal / zero) after cmp r0, #0
.Lsh_080151D6:
    ldr r0, =hold_stage2                @ 080151D6
    ldrb r0, [r0]                       @ 080151DA
    cmp r0, #0                          @ 080151DC
    beq .Lsh_rel_done                   @ 080151DE
    ldr r0, =v_20007DAC                 @ 080151E0
    ldr r0, [r0]                        @ 080151E4
    ldr r1, =v_20007DA0                 @ 080151E6
    str r0, [r1]                        @ 080151EA
    movs r3, #0                         @ 080151EC
    ldr r0, =v_20007DA0                 @ 080151EE
    ldr r2, [r0]                        @ 080151F2
    ldr r0, =v_2000803F                 @ 080151F4
    ldrb r1, [r0]                       @ 080151F8
    ldr r0, =meter_mode                 @ 080151FA
    ldrb r0, [r0]                       @ 080151FE
    bl lcd_show_value_pos5_9            @ 08015200

@ common end of REL: AUTO annunciator (fn_08019D68), request a redraw (0x20008053), REL annunciator
@ (fn_08019F2E), accept beep
@ reached from 080150F4 bne (not equal / non-zero) after tst r0, r1
@              and from 0801515A b (jump)
@              and from 08015186 b (jump)
@              ... and 3 more
.Lsh_rel_done:
    movs r0, #0                         @ 08015204
    bl fn_08019D68                      @ 08015206
    movs r0, #1                         @ 0801520A
    ldr r1, =key_post_flag              @ 0801520C
    strb r0, [r1]                       @ 08015210
    movs r0, #1                         @ 08015212
    bl fn_08019F2E                      @ 08015214
@ reached from 08015046 b (jump)
@              and from 08015050 bne (not equal / non-zero) after cmp r0, #0
@              and from 0801505C bne (not equal / non-zero) after cmp r0, #1
@              ... and 3 more
.Lsh_accept_end:
    bl fn_0800EE50                      @ 08015218
    b .Lsh_end                          @ 0801521C

@ ---- PEAK ----  in the window with key_win_a = 0 and key_win_b = 1 PEAK chooses cal.bin load (key_win_b = 2,
@ key_win_load = 1, reload 5000); the code then continues as the normal PEAK key.  Setup edit = DOWN, MEM
@ view = previous record, else toggle peak hold in ACV (not AC+DC) and ACmV
@ reached from 08014C6C beq (equal / zero) after cmp r0, #0x80
.Lsh_key_peak:
    ldr r0, =key_window                 @ 0801521E
    ldrh r0, [r0]                       @ 08015222
    cmp r0, #0                          @ 08015224
    beq .Lsh_peak_edit                  @ 08015226
    ldr r0, =key_win_a                  @ 08015228
    ldrb r0, [r0]                       @ 0801522C
    cmp r0, #0                          @ 0801522E
    bne .Lsh_peak_edit                  @ 08015230
    ldr r0, =key_win_b                  @ 08015232
    ldrb r0, [r0]                       @ 08015236
    cmp r0, #1                          @ 08015238
    bne .Lsh_peak_edit                  @ 0801523A
    movs r0, #2                         @ 0801523C
    ldr r1, =key_win_b                  @ 0801523E
    strb r0, [r1]                       @ 08015242
    movs r0, #1                         @ 08015244
    ldr r1, =key_win_load               @ 08015246
    strb r0, [r1]                       @ 0801524A
    movw r0, #0x1388                    @ 0801524C
    ldr r1, =key_window                 @ 08015250
    strh r0, [r1]                       @ 08015254

@ setup edit: PEAK = DOWN (fn_080165F4(2)) with accept beep
@ reached from 08015226 beq (equal / zero) after cmp r0, #0
@              and from 08015230 bne (not equal / non-zero) after cmp r0, #0
@              and from 0801523A bne (not equal / non-zero) after cmp r0, #1
.Lsh_peak_edit:
    ldr r0, =key_setup_edit             @ 08015256
    ldrb r0, [r0]                       @ 0801525A
    cmp r0, #0                          @ 0801525C
    beq .Lsh_peak_view                  @ 0801525E
    movs r0, #2                         @ 08015260
    bl fn_080165F4                      @ 08015262
    bl fn_0800EE50                      @ 08015266
    b .Lsh_08015332                     @ 0801526A

@ MEM view: previous record (key_view_index - 1, wrapping from 1 to key_view_last), clear the view timeout, redraw
@ reached from 0801525E beq (equal / zero) after cmp r0, #0
.Lsh_peak_view:
    ldr r0, =key_mem_view               @ 0801526C
    ldrb r0, [r0]                       @ 08015270
    cmp r0, #0                          @ 08015272
    beq .Lsh_peak_toggle                @ 08015274
    ldr r0, =key_view_index             @ 08015276
    ldrh r0, [r0]                       @ 0801527A
    cmp r0, #1                          @ 0801527C
    bne .Lsh_0801528E                   @ 0801527E
    ldr r0, =key_view_last              @ 08015280
    ldrh r0, [r0]                       @ 08015284
    ldr r1, =key_view_index             @ 08015286
    strh r0, [r1]                       @ 0801528A
    b .Lsh_0801529C                     @ 0801528C
@ reached from 0801527E bne (not equal / non-zero) after cmp r0, #1
.Lsh_0801528E:
    ldr r0, =key_view_index             @ 0801528E
    ldrh r0, [r0]                       @ 08015292
    subs r0, r0, #1                     @ 08015294
    ldr r1, =key_view_index             @ 08015296
    strh r0, [r1]                       @ 0801529A
@ reached from 0801528C b (jump)
.Lsh_0801529C:
    ldr r0, =key_view_index             @ 0801529C
    ldrh r0, [r0]                       @ 080152A0
    bl fn_080170AC                      @ 080152A2
    movs r0, #0                         @ 080152A6
    ldr r1, =key_view_timer             @ 080152A8
    strh r0, [r1]                       @ 080152AC
    bl fn_0800EE50                      @ 080152AE
    b .Lsh_08015332                     @ 080152B2
    .ltorg

@ only in ACV without AC+DC and in ACmV
@ reached from 08015274 beq (equal / zero) after cmp r0, #0
.Lsh_peak_toggle:
    ldr r0, =meter_mode                 @ 080152B4
    ldrb r0, [r0]                       @ 080152B8
    cmp r0, #2                          @ 080152BA mode 2 ACV
    bne .Lsh_080152C8                   @ 080152BC
    ldr r0, =acdc_active                @ 080152BE
    ldrb r0, [r0]                       @ 080152C2
    cmp r0, #0                          @ 080152C4
    beq .Lsh_080152D2                   @ 080152C6
@ reached from 080152BC bne (not equal / non-zero) after cmp r0, #2
.Lsh_080152C8:
    ldr r0, =meter_mode                 @ 080152C8
    ldrb r0, [r0]                       @ 080152CC
    cmp r0, #4                          @ 080152CE mode 4 ACmV
    bne .Lsh_peak_refuse                @ 080152D0

@ OF-17: with the 1 kHz filter on PEAK is refused.  Else toggle peak_hold, clear peak_show_min, request a mode apply
@ (0x2000804A); peak on = freeze the range and clear MIN/MAX, peak off = range unfrozen; zero the stored PEAK
@ values 0x20007E8C / 0x20007E90, refresh the PEAK annunciator (fn_0801A07C), accept beep
@ reached from 080152C6 beq (equal / zero) after cmp r0, #0
.Lsh_080152D2:
    ldr r0, =filter_1khz                    @ 080152D2 replaces v2.05 ldr.w r0,[0x08015f6c]
    ldrb r0, [r0]
    cbnz r0, .Lsh_peak_refuse                @ OF-17: PEAK and the 1 kHz filter cannot be on together
    ldr r0, =peak_hold
    ldrb r0, [r0]                       @ 080152D6
    eors r0, r0, #1                     @ 080152D8
    ldr r1, =peak_hold                  @ 080152DC
    strb r0, [r1]                       @ 080152E0
    movs r0, #0                         @ 080152E2
    ldr r1, =peak_show_min              @ 080152E4
    strb r0, [r1]                       @ 080152E8
    movs r0, #1                         @ 080152EA
    ldr r1, =key_mode_req               @ 080152EC
    strb r0, [r1]                       @ 080152F0
    ldr r0, =peak_hold                  @ 080152F2
    ldrb r0, [r0]                       @ 080152F6
    cmp r0, #0                          @ 080152F8
    beq .Lsh_0801530C                   @ 080152FA
    movs r0, #1                         @ 080152FC
    ldr r1, =range_manual               @ 080152FE
    strb r0, [r1]                       @ 08015300
    movs r0, #0                         @ 08015302
    ldr r1, =minmax_state               @ 08015304
    strb r0, [r1]                       @ 08015308
    b .Lsh_08015312                     @ 0801530A
@ reached from 080152FA beq (equal / zero) after cmp r0, #0
.Lsh_0801530C:
    movs r0, #0                         @ 0801530C
    ldr r1, =range_manual               @ 0801530E
    strb r0, [r1]                       @ 08015310
@ reached from 0801530A b (jump)
.Lsh_08015312:
    movs r0, #0                         @ 08015312
    ldr r1, =key_peak_hi                @ 08015314
    str r0, [r1]                        @ 08015318
    movs r0, #0                         @ 0801531A
    ldr r1, =key_peak_lo                @ 0801531C
    str r0, [r1]                        @ 08015320
    movs r0, #1                         @ 08015322
    bl fn_0801A07C                      @ 08015324
    bl fn_0800EE50                      @ 08015328
    b .Lsh_08015332                     @ 0801532C
@ reached from 080152D0 bne (not equal / non-zero) after cmp r0, #4
.Lsh_peak_refuse:
    bl fn_0800EE6C                      @ 0801532E
@ reached from 0801526A b (jump)
@              and from 080152B2 b (jump)
@              and from 0801532C b (jump)
.Lsh_08015332:
    b .Lsh_end                          @ 08015332

@ ---- MIN/MAX ----  refused while logging, MEM view, calibration mode, in LowZ, with HOLD (unless MIN/MAX is
@ already running) and with PEAK; otherwise step MIN/MAX (fn_080158D4)
@ reached from 08014C50 beq (equal / zero) after cmp r0, #4
.Lsh_key_minmax:
    ldr r0, =key_logging                @ 08015334
    ldrb r0, [r0]                       @ 08015338
    ldr r1, =key_mem_view               @ 0801533A
    ldrb r1, [r1]                       @ 0801533E
    orrs r0, r1                         @ 08015340
    uxtb r0, r0                         @ 08015342
    cmp r0, #0                          @ 08015344
    beq .Lsh_0801534E                   @ 08015346
    bl fn_0800EE6C                      @ 08015348
    b .Lsh_end                          @ 0801534C
@ reached from 08015346 beq (equal / zero) after cmp r0, #0
.Lsh_0801534E:
    ldr r0, =key_cal_mode               @ 0801534E
    ldrb r0, [r0]                       @ 08015352
    cmp r0, #0                          @ 08015354
    beq .Lsh_0801535E                   @ 08015356
    bl fn_0800EE6C                      @ 08015358
    b .Lsh_end                          @ 0801535C
@ reached from 08015356 beq (equal / zero) after cmp r0, #0
.Lsh_0801535E:
    ldr r0, =meter_mode                 @ 0801535E
    ldrb r0, [r0]                       @ 08015362
    cmp r0, #0                          @ 08015364 mode 0 LowZ
    bne .Lsh_0801536E                   @ 08015366
    bl fn_0800EE6C                      @ 08015368
    b .Lsh_end                          @ 0801536C
@ reached from 08015366 bne (not equal / non-zero) after cmp r0, #0
.Lsh_0801536E:
    ldr r0, =hold_active                @ 0801536E
    ldrb r0, [r0]                       @ 08015372
    cmp r0, #0                          @ 08015374
    beq .Lsh_08015382                   @ 08015376
    ldr r0, =minmax_state               @ 08015378
    ldrb r0, [r0]                       @ 0801537C
    cmp r0, #0                          @ 0801537E
    beq .Lsh_minmax_refuse              @ 08015380
@ reached from 08015376 beq (equal / zero) after cmp r0, #0
.Lsh_08015382:
    ldr r0, =hold_stage2                @ 08015382
    ldrb r0, [r0]                       @ 08015386
    cmp r0, #0                          @ 08015388
    bne .Lsh_minmax_refuse              @ 0801538A
    ldr r0, =peak_hold                  @ 0801538C
    ldrb r0, [r0]                       @ 08015390
    cmp r0, #0                          @ 08015392
    beq .Lsh_0801539C                   @ 08015394
@ reached from 08015380 beq (equal / zero) after cmp r0, #0
@              and from 0801538A bne (not equal / non-zero) after cmp r0, #0
.Lsh_minmax_refuse:
    bl fn_0800EE6C                      @ 08015396
    b .Lsh_end                          @ 0801539A
@ reached from 08015394 beq (equal / zero) after cmp r0, #0
.Lsh_0801539C:
    bl fn_080158D4                      @ 0801539C
    bl fn_0800EE50                      @ 080153A0
@ reached from 08014C70 b (jump)
@              and from 08014C8A b (jump)
@              and from 08014CEA b (jump)
@              ... and 22 more
.Lsh_end:
    pop {r4, pc}                        @ 080153A4
ENDFUNC handle_pg8_15_short_press
    .ltorg
