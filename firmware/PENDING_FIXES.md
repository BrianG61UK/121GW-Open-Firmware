# Defect fixes of the fast build not yet in this build

This branch's `firmware/src` equals main at 27c7561 (2026-11-04); `ORIGINAL_FIRMWARE_ISSUES.md` here ends at OF-65.  The
fast build (branch main) has fixed OF-66 .. OF-76 since.  Owner decision 2026-11-07: this build stays as it is for now,
the work below is done later.  Each fix changes the image, so `STRICT_IMAGE.sha256` is regenerated after the port; the
OF rows of `ORIGINAL_FIRMWARE_ISSUES.md` and `DESIGN.md` come along.  Only the defect fix of each commit is taken, never
the fast build's improvements (IMP) in the same commit.

| OF | main commit, place | applies here | port notes | test (main's emulator tree, against the strict image) |
|---|---|---|---|---|
| 66 | ab3e342, `sd/diskio.s` disk_read / disk_write, `sd_bounce` (512 B, `.bss_port.sdbounce`), `sd_copy512` | adapted by hand | main's patch does not apply at diskio.s:50 (the `sd_dg_*` block is fast-build only here); add the bounce buffer outside the `.if LOOP_V205 == 0` block; disk_read here uses `cbz r6` and a `uxtb` count; check the RAM end after the build | none for this build (`test_bft_files.py` needs the fast build's Bluetooth transfer) |
| 67 | c3fbf88, `key/long.s` `.Llp_key_mem` (key_win_b 1..3 -> `.Llp_end`) | yes | applies as is | `test_calbin_ident.py` C5 only (C2, C3 test IMP-38) |
| 68 | 6646cc3, `sd/sdcard.s` sd_get_card_info (64-bit capacity: `lsrs r3, r2, #13; lsls r2, r2, #19`) | yes | applies as is; nothing here reads the capacity field, so no behaviour change | `test_sd_capacity.py` |
| 69 | f57bed9 (IMP-41): `sys/clock.s` sys_pll_session, `sd/sdcard.s`, `sd/diskio.s`, `ble/usart.s`, `hw.inc`, timer prescalers | not as a small fix | main's fix is the IMP-41 redesign (PLL VCO 96 MHz, card sessions at 32 MHz, timers and polls adjusted); the write failure was seen on a meter with the fast build only, the strict build at v2.05's clock is untested; needs a design for this build first | `test_sd_clock.py` expects 32 MHz: to be adapted |
| 70 | f57bed9, only the `sys_set_sysclk` hunk of `sys/clock.s` (switch to the PLL with HPRE /2, `.Lsss_step` delay, then /1; `.Lsss_fail` also clears HPRE); `SYS_STEP_LOOPS`, `RCC_CFGR_HPRE_MASK`, `RCC_CFGR_HPRE_DIV2` | yes | no LOOP_V205 code in clock.s; the start-up gets about 16 us longer; leave the session and timer hunks out | `test_sd_clock.py`'s clock step check, adapted |
| 71 | 58092bf, `ble/usart.s` ble_usart2_isr, `USART_SR_ORE` in hw.inc | adapted | drop the calls `xd_rx_account` / `xd_inc` (IMP-44, not in this build); keep: read SR, with RXNE 0, ORE 1 and RXNEIE 1 read DR once and drop the byte | `test_ble_overrun.py` T1, T2 (T3, T4 use the 0x90 version request of the fast build) |
| 72 | 5e71ea7, only the `fn_0801CAEC` hunks of `ble/usart.s` (fraction carry, OVER8 path) | yes | self-contained arithmetic; v2.05 gives the nominal clock, so the case is not reached here (it needs IMP-46's measured clock): hardening only | none here (`test_msical.py` C5 needs IMP-46) |
| 73 | ed47878, only the `brd/stop.s` fn_0801C92E hunk (TIM2 / TIM3 DIER and SR cleared before the clocks are gated) | yes | leave `poweroff.s` (IMP-48) out; the same STOP sequence is here, so the wake hang applies here as well (not tested on a meter with this build) | `test_apo_wake.py` W2 and the stuck-exception check (W1 tests IMP-48); needs main's emulator (`core.py` exc_exit_hooks, `tim.py` _LevelIrq) |
| 74, 75, 76 | 3fdf093, `lcd/bargraph.s` bargraph_count_from_value (no overload override in DIODE), fn_0801912C (`.Lbl_diode`, `.Lbl_va`, `.Lbl_va_dc`) | yes | applies as is (the LOOP_V205 blocks are elsewhere in the file); leave config.inc and the emulator out | `test_bargraph.py` G1..G4 (G1's flash check reads the emulator's `lcd_seen`) |

Order: 68, 67; 74..76; 73; 70; 71; 66; 72; 69 after its design.  Then `make LOOP_V205=1`, `make check-ci`, the new
`STRICT_IMAGE.sha256`, and only the tests named above, at most 3 at once.
