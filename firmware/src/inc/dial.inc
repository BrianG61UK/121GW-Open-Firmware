@ =============================================================================
@ dial.inc - names for the v2.05 RAM variables that module DIAL (src/dial) reads and writes
@
@ Owner W4.  Aliases of the v2.05 address symbols in ram_v205.inc; meaning from analysis/rotary.md 1, 2, 5 and
@ the listing addresses cited.
@ =============================================================================

    .ifndef DIAL_INC
    .equ DIAL_INC, 1

@ ---- variables owned by DIAL (Appendix B) ----------------------------------------------------------------------
    .equ dial_sample,       v_20008066  @ PG0..PG7 sample, bit k = contact PG(7-k) low (sample_pg0_7 0x08014A14)
    .equ dial_prev,         v_2000023C  @ sample of the previous call (init 0xFF, 0x08014992)
    .equ dial_stable,       v_200080EC  @ consecutive calls with sample == dial_prev (0x080149C0)
    .equ dial_latched,      v_20008065  @ dial position code latched after 5 equal one-hot samples (0 = none yet)
    .equ dial_changed,      v_20008064  @ 1 = a new position was latched, handled by fn_08014954 (0x08014A0C)
    .equ dial_lockout,      v_200080EB  @ calls left in which no new position is latched (reload 0x0F, 0x08014A02)
    .equ jack_code,         v_200080EA  @ last jack code (PE10 low = 1, PE11 low = 2) (0x0801419E)
    .equ jack_count,        v_2000023B  @ calls left until the jack code is accepted (reload 10, init 10)
    .equ jack_ma_selected,  v_20008075  @ 1 = mA jack in use (PE10 low only, code 1) (0x080141E4)
    .equ jack_warning,      v_20008076  @ 1 = lead in the wrong jack (warning beep / annunciator) (0x08014320)
    .equ jack_changed,      v_200080CC  @ jack code of the last change (written 0x080141BE; owner DIAL, read by others)

@ ---- variables of other modules that the ported dial code writes ------------------------------------------------
    .equ dial_mode_req,     v_2000804A  @ 1 = apply the new mode (meter_apply_mode_range, loop step 13)
    .equ dial_log_flag1,    v_2000801B  @ cleared on a dial change (0x0801449E; logging fields, owner LOG)
    .equ dial_log_flag2,    v_2000801D  @ cleared on a dial change (0x080144A6; owner KEY)
    .equ dial_post_flag53,  v_20008053  @ cleared on a dial change (0x080144CE; owner FUNC)
    .equ dial_post_flag51,  v_20008051  @ cleared on a dial change (0x080144D8; owner FUNC)
    .equ dial_post_flag52,  v_20008052  @ set from (dial_func_hw != 0) on a dial change (0x080144E6; owner FUNC)
    .equ dial_func_hw,     v_20007FB2  @ halfword cleared on a dial change (0x080144E0; owner FUNC)

    .endif
