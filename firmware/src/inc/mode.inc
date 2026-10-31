@ =============================================================================
@ mode.inc - names for the v2.05 RAM variables that module MODE (src/mode) reads and writes
@
@ Owner W4.  Aliases of the v2.05 address symbols in ram_v205.inc; meaning from analysis/rotary.md, keys_setup.md,
@ autorange_and_scheduler.md 2.3 and the listing addresses cited.  Variables whose role the v2.05 code does not
@ show are not renamed: the routines use the v_XXXXXXXX symbol and say which module owns it.
@ =============================================================================

    .ifndef MODE_INC
    .equ MODE_INC, 1

@ ---- variables owned by MODE (Appendix B, DESIGN.md 5.2) -----------------------------------------------------
    .equ mode_settle,       v_20000238  @ means still to be discarded after an apply (one less is discarded: ARS 2.3), init 3
    .equ mode_full_scale,   v_20007D60  @ full scale of the present mode and range in display counts (load_full_scale)
    .equ mode_mode_req,     v_2000804A  @ 1 = apply with mode-change work (dial, MODE key, jack swap), loop step 13
    .equ mode_range_req,    v_2000804B  @ 1 = apply the changed range (RANGE key, auto-range), loop step 13
    .equ mode_ol_latch,     v_200080F8  @ the previous result was an overload (ARS 2.2: U = FS + FS/12 instead of FS/10)
    .equ mode_ohm_skip,     v_2000805A  @ display updates to skip after an OHM range 1..5 apply (set to 2, 0x0800D2F2)
    .equ mode_freq_flag,    v_20008074  @ 1 in FREQ / PULSE / DUTY after a MODE-key cycle (role UNPROVEN, rotary.md 2)

@ ---- variables of other modules that the ported mode code reads or writes ------------------------------------
    .equ mode_cal_mode,     v_2000808A  @ 1 = calibration mode
    .equ mode_diode_15v,    v_200080B3  @ 1 = DIODE 15 V range selected (0x0800D5FE)
    .equ mode_logging,      v_20007FE1  @ 1 = logging active
    .equ mode_setup_edit,   v_2000806E  @ 1 = a setup item is being edited (cleared at a mode change, 0x0800D3E4)
    .equ mode_sample_ctr,   v_20008080  @ AD1 samples in the running mean, cleared at every apply (0x0800D32E)
    .equ mode_shown,        v_20007D70  @ last drawn value (also the BLE value), cleared at every apply (0x0800D31E)
    .equ mode_reading,      v_20007D64  @ smoothed reading, cleared at every apply except OHM range 6 (0x0800D578)
    .equ mode_reading_smp,  v_20007D68  @ per-sample value, cleared with mode_reading (0x0800D580)
    .equ mode_new_result,   v_2000805D  @ 1 = a new result is waiting for post-processing (loop step 2)
    .equ mode_user_zero,    v_20007E0C  @ user current zero (loaded by current_extra_load)

    .endif
