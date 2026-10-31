@ =============================================================================
@ ar.inc - names for the v2.05 RAM variables that module AR (src/ar) reads and writes
@
@ Owner W4.  Aliases of the v2.05 address symbols in ram_v205.inc; meaning from analysis/autorange_and_scheduler.md
@ 2.2 and the listing addresses cited.
@ =============================================================================

    .ifndef AR_INC
    .equ AR_INC, 1

    .equ ar_reading,        v_20007D64  @ smoothed reading in display counts (signed), the decision input (0x0800DFF2)
    .equ ar_full_scale,     v_20007D60  @ full scale of the present range (load_full_scale)
    .equ ar_settle,         v_20000238  @ settle count: while non-zero the decision is skipped (0x0800DEB4)
    .equ ar_range_manual,   range_manual @ 1 = range frozen (RANGE key, HOLD, REL, MIN/MAX, PEAK)
    .equ ar_overload,       v_20008046  @ overload flag, drawn as " OFL " (0x0800E08C)
    .equ ar_negative,       v_20008045  @ sign of the reading, 1 = negative (0x0800E008)
    .equ ar_blank,          v_2000805C  @ 1 = blank the main digits (range just changed, 0x0800E110)
    .equ ar_range_req,      v_2000804B  @ 1 = apply the new range (loop step 13)
    .equ ar_mode_req,       v_2000804A  @ 1 = apply a new mode (loop step 13)
    .equ ar_new_result,     v_2000805D  @ 1 = a new result is ready (set by frequency_select_range, 0x0800AEB8)
    .equ ar_ol_latch,       v_200080F8  @ previous result was an overload (U = FS + FS/12)
    .equ ar_cal_mode,       v_2000808A  @ 1 = calibration mode: no ranging
    .equ ar_tc_flag,        v_200080AD  @ thermocouple state in TEMP: 1 = open (OL, sign 0), 2 = OL, sign 1 (0x0800E04E)
    .equ ar_ohm_dir,        v_20008035  @ OHM direction memory: 1 = last change was up, 2 = down, 0 = none
    .equ ar_ohm_dir_tmr,    v_20008036  @ TIM2 ticks left before ar_ohm_dir is forgotten (reload 100, 0x0800E2F8)
    .equ ar_hold_jump,      v_20008055  @ OHM auto-hold stage 2: an overload was seen, jump on the next non-OL result
    .equ ar_hold_range,     v_20008056  @ OHM auto-hold stage 2: range to jump to (written by FUN_0800E30C)
    .equ ar_hold_value,     v_20007DA0  @ captured value of auto-hold stage 2 (zeroed on a range change)
    .equ ar_cap_small,      v_200080A2  @ set when CAP range 2 is left downwards with |D| < 11 (0x0800E216)
    .equ ar_freq64,         v_20007C40  @ measured frequency, 64-bit, in mHz (counter_compute_frequency)
    .equ ar_dec_digits,     v_2000803F  @ result of decimal_position_for_mode_range for the present range (0x0800AEC6)
    .equ ar_hold_active,    hold_active
    .equ ar_hold_stage2,    hold_stage2
    .equ ar_minmax,         minmax_state

    .endif
