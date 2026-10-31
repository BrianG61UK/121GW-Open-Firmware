@ =============================================================================
@ key.inc - names for the v2.05 RAM variables that module KEY (src/key) reads and writes
@
@ Owner W4.  Every name is an alias of the v2.05 address symbol in ram_v205.inc (same address, DESIGN.md 5.1);
@ the meaning in the comment is what the v2.05 code shows (analysis/keys_setup.md section 2, listing addresses
@ cited).  Variables of other modules carry the prefix key_ too and are only read or written where the v2.05
@ function that KEY ports does so (DESIGN.md 5.2).
@ =============================================================================

    .ifndef KEY_INC
    .equ KEY_INC, 1

@ ---- variables owned by KEY (Appendix B) ---------------------------------------------------------------------
    .equ key_sample,        v_2000806A  @ PG8..PG15 sample, bit k = key on PG(8+k) pressed (sample_pg8_15 0x08016BCA)
    .equ key_prev,          v_200080F0  @ sample of the previous 10 ms tick (0x080168B0)
    .equ key_stable,        v_200080EF  @ number of consecutive ticks with sample == key_prev (0x080168D0)
    .equ key_hold,          v_20008072  @ ticks the key has been down: 0 idle, 0x32 long press, 0x33 long press done
    .equ key_lockout,       v_20008073  @ ticks left in which a new press is ignored after an event (0x08016898)
    .equ key_queued,        v_200080EE  @ 1 = a short press waits for the release of its key (0x08016912)
    .equ key_queued_code,   v_200080F1  @ key code of the queued short press (0x08016932)
    .equ key_short_ev,      v_20008067  @ 1 = short-press event pending for fn_0801682C (0x08016926)
    .equ key_short_code,    v_2000806B  @ key code of the pending short-press event
    .equ key_long_ev,       v_20008068  @ 1 = long-press event pending for fn_0801682C (0x08016996)
    .equ key_long_code,     v_2000806C  @ key code of the pending long-press event
    .equ key_remote_ev,     v_20008069  @ 1 = remote key code waiting (BLE packet 0xF4, set by fn_0800C332)
    .equ key_remote_code,   v_2000806D  @ the remote key code 1..8 (short) or 0x81..0x88 (long)
    .equ key_rep_phase,     v_200080F2  @ auto-repeat phase of REL/PEAK in MEM view and edit (fn_08016A64)
    .equ key_rep_count,     v_200080F3  @ ticks counted inside the auto-repeat phase
    .equ key_backlight_on,  v_2000807B  @ 1 = backlight (PE8) on (MODE long press 0x080162E4)
    .equ key_backlight_tmr, v_20007FB8  @ halfword loaded with 0x78 when the backlight goes on (0x080162F8)
    .equ key_range_saved,   v_20008044  @ range_manual saved by HOLD and MIN/MAX (0x08014F64, 0x080164A0)
    .equ key_rel_range_sv,  v_200080ED  @ range_manual saved when REL goes on (0x08015124)

@ ---- variables of other modules that the ported key code reads or writes ----------------------------------
    .equ key_window,        v_2000022E  @ power-on window counter in TIM3 ticks, 0 = closed (CAL, IRQ29)
    .equ key_win_a,         v_200080CD  @ power-on window state A (MODE pressed, SETUP pressed: keys_setup.md 3)
    .equ key_win_b,         v_200080CE  @ power-on window state B (MEM / REL / PEAK / MODE sequence)
    .equ key_win_save,      v_20008088  @ power-on window: cal.bin save chosen
    .equ key_win_load,      v_20008089  @ power-on window: cal.bin load chosen
    .equ key_cal_mode,      v_2000808A  @ 1 = calibration mode (set by the power-on window)
    .equ key_cal_off_req,   v_2000808C  @ calibration offset request (fn_08015768)
    .equ key_cal_gain_req,  v_2000808E  @ calibration gain request (fn_08015768)
    .equ key_cal_ohm6_req,  v_20008090  @ OHM range 6 weight capture request (MEM long, 0x080164EE)
    .equ key_cal_count,     v_20008095  @ capture countdown (0x080164F6)
    .equ key_cal_board_req, v_20008096  @ board-temperature offset capture request (MEM long, 0x08016500)
    .equ key_logging,       v_20007FE1  @ 1 = logging to SD / RAM records active
    .equ key_mem_view,      v_20007FE4  @ 1 = stored-data view (MEM) open
    .equ key_log_count,     v_20007FA4  @ number of stored records (halfword)
    .equ key_view_index,    v_20007F9C  @ record number shown in the MEM view (halfword)
    .equ key_view_last,     v_20007F9E  @ highest record number (halfword)
    .equ key_view_timer,    v_20007FAA  @ halfword cleared by KEY at every MEM-view key action (owner SYS, Appendix B)
    .equ key_setup_item,    v_20008037  @ SETUP menu item (100 = logging / MEM view)
    .equ key_setup_edit,    v_2000806E  @ 1 = a setup item is being edited
    .equ key_setup_blink,   v_20008070  @ edit blink state (cleared when an edit starts, 0x080162BA)
    .equ key_setup_digit,   v_20008071  @ digit cursor of the ID edit (set to 4 when an edit starts)
    .equ key_hold_stage2,   hold_stage2 @ auto-hold stage 2
    .equ key_ble_on,        v_2000802B  @ 1 = serial / BLE status transfer on (PEAK long press)
    .equ key_peak_hi,       v_20007E8C  @ PEAK maximum value (zeroed when PEAK is toggled)
    .equ key_peak_lo,       v_20007E90  @ PEAK minimum value (zeroed when PEAK is toggled)
    .equ key_user_zero,     v_20007E0C  @ current-mode user zero in display counts (REL long press)
    .equ key_reading,       v_20007D64  @ smoothed reading in display counts
    .equ key_mode_req,      v_2000804A  @ 1 = apply the new mode (meter_apply_mode_range, loop step 13)
    .equ key_range_req,     v_2000804B  @ 1 = apply the new range
    .equ key_post_flag,     v_20008053  @ set to 1 at the end of the REL key action (0x08015210), cleared at an apply (owner FUNC)
    .equ key_ol_latch,      v_20008048  @ latched copy of the overload flag; while set REL cannot be switched on (0x080150E2)
    .equ key_rel_on_flag,   v_20008059  @ set to 1 when REL goes on with HOLD off (0x08015188; owner FUNC)

    .endif
