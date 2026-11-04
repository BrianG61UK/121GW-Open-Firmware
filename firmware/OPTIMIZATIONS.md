# Optimisations and improvements over v2.05

Invisible optimisations: external behaviour (LCD, keys, buzzer, backlight, SD files, BLE/USART protocol, EEPROM
contents, HY3131 configuration sequence) is identical to v2.05; each is verified as listed.

| ID | Optimisation | Why it is invisible or an improvement | Verified by |
|---|---|---|---|
| OPT-01 | RAM init by plain copy instead of lz77 | identical RAM content at `main` entry (6.27) | build check |
| OPT-02 | RMS square root and average removed (with OF-16) | no reader of the results | OF-16 evidence; spi stream |
| OPT-03 | NVM skips programming a byte that already holds the value | EEPROM content identical, fewer erase/write cycles (v2.05 setting saves rewrite unchanged bytes, EMAP 7.1) and fewer power-loss windows | streams `eeprom` and `eeprom_final` (`eeprom_store` differs and is not compared) |
| OPT-04 | one RT copy for all modules | code size | RT tests |
| OPT-06 | table lookups where v2.05 uses compare ladders (mode dispatch, INTE selection, rotary readers), tables equal to the ladders' cases | same result for every input; out-of-range inputs keep the v2.05 default branch | routine tests over the whole input range |
| OPT-07 | cal.bin read-back compared against the EEPROM directly | no 1200-byte stack buffer; same result | routine test of `calbin_load` |
| OPT-08 | calibration records read from the RAM cache | identical values (the cache is the EEPROM image, updated on every verified write); apply faster | routine tests of the loaders; scenarios |

## User-visible improvements (production build)

| ID | Improvement | Effect |
|---|---|---|
| IMP-01 | Auto-ranging decides on two out-of-range samples and jumps straight to the target range | range changes about 2x faster (e.g. DCV 0 -> 500 V 0.60 s against 1.15 s); settled values, thresholds and OL behaviour as v2.05 |
| IMP-02 | Measuring starts during the power-on window | first reading 0.11..0.56 s after power-on instead of 2.2..2.8 s; every power-on key combination still works |
| IMP-03/04 | Faster Ohm readings and continuity/diode response (decided per sample) | continuity beep 1.0..4.3 ms after contact (median 2.3 ms) instead of 6.3..22.5 ms (median 13.4 ms), measured in the emulator over 20 contacts at 10 and 25 ohm; diode short tone about 20 ms instead of 0.38 s |
| IMP-05 | Extended continuity thresholds (EEPROM byte 0x14, codes 4..15: 1, 5, 10, 50, 100, 200 ohm, both directions) | same setting byte; codes 0..3 keep v2.05's meaning |
| IMP-06 | No busy-waiting: deferred LCD commits, blocking routines as state machines, WFI sleep between loop passes | every HY3131 conversion is processed (v2.05 drops most of them, OF-31); lower supply current |
| IMP-07 | Backlight auto-off timer: SETUP page bL, OFF (default) / 30 s / 1..99 min | after the chosen time without a key press or dial turn the backlight switches itself off (MODE long press switches it on, and off, as before); stored in EEPROM 0x017 (a byte v2.05 never uses, `EEPROM_MAP.md` 4.1); the flag and countdown also follow the pin after a STOP wake (v2.05 needed two MODE long presses after a wake with the backlight on) |
| IMP-08 | Selectable dBm reference on the ACV page 11: 600 ohm (default, as v2.05), 50 ohm, 75 ohm, dBV | long SETUP on the dBm page, REL / PEAK step, long SETUP saves; RF (50 ohm), video (75 ohm) and dBV readings without conversion by hand; stored in EEPROM 0x011 (`EEPROM_MAP.md` 4.1) |
| IMP-09 | Selectable Bluetooth frame rate: SETUP page bt, 2 (default, as v2.05) / 4 / 10 / 20 frames per second | faster live readings for a host that keeps up; the 500 ms timing of the rest of the meter is untouched; stored in EEPROM 0x015 (`EEPROM_MAP.md` 4.1) |
| IMP-10 | Selectable thermocouple type in TEMP: SETUP page tc, K (default, as v2.05) / J / T / N / R / S (N, R, S: IMP-26) | J, T, N, R and S probes read correctly (NIST ITS-90 tables), cold junction included; stored in EEPROM 0x00F (`EEPROM_MAP.md` 4.1) |
| IMP-11 | REL in percent: SETUP page rEL, difference (default, as v2.05) / percent | tolerance checks read directly in % of the reference (0.001 % resolution below 100 %); logging and Bluetooth keep the plain REL value; stored in EEPROM 0x020 bit 0 (`EEPROM_MAP.md` 4.1) |
| IMP-12 | Display level: SETUP page dSP, level 1 (default, as v2.05) / level 2 | small changes and drifts settle in a quarter of the smoothing depth (big steps were already immediate); readings somewhat noisier; stored in EEPROM 0x013 (`EEPROM_MAP.md` 4.1) |
| IMP-13 | 12-hour clock: SETUP page CL, 24-hour (default, as v2.05) / 12-hour | the time page shows 1..12 (` 2-30`); stored in EEPROM 0x020 bit 3 (`EEPROM_MAP.md` 4.1) |
| IMP-14 | Statistics while MIN/MAX is on: pages n (count) and Sd (standard deviation) | the spread of a reading without a computer; numerically stable (Welford, binary64); no EEPROM |
| IMP-15 | Bargraph sign steady at zero | with no bar lit the bargraph sign (LCD and Bluetooth) follows the digits instead of flickering with the noise |
| IMP-16 | Continuity beep hold time: SETUP page bH in BEEP, 100 ms (default, as v2.05) / 50 / 25 ms / off (15 ms) | the tone can follow the contact closely instead of latching 100 ms; stored in EEPROM 0x021 (`EEPROM_MAP.md` 4.1) |
| IMP-17 + IMP-18 + IMP-19 | Faster servicing of the HY3131 in the 640-conversion modes | bargraph update in one table pass instead of a 25-call cascade, fewer SPI reads per conversion, SPI writes at the v2.05 read timing: in BEEP 462 instead of 236 conversions handled per second, continuity re-armed every 2.0 ms (median, 90 % within 2.4 ms) instead of 4.0 ms (emulator); verified working on a meter |
| IMP-20 | Limit test: pages Lt, Lo, HI and the PASS / HI / Lo verdict | sorting and checking parts without reading digits; limits taken from known-good parts; beeps on leaving and returning to the limits |
| IMP-21 | Logging trigger: SETUP pages tr and Ch: every interval (as v2.05), on a change of N counts, or on a limit-verdict change; date and time of the MAX / MIN closing rows; MIN/MAX pages tHI / tLo with the time of the maximum and minimum | long recordings keep only the interesting records; the file shows when the extremes happened, the meter shows it while MIN/MAX runs; the first five columns of the file are v2.05's |
| IMP-22 | Auto-hold captures 0 ohm and 0 V in OHM and DIODE (open probes, OL, are still ignored) | a short, a good fuse or a shorted junction can be held; v2.05 ignored readings below 1000 counts in every function | emulator: `emulator/scripts/test_autohold_zero.py` |
| IMP-23 | DCV: the 16-sample mean shown every 8 samples, restarted on a step | twice the update rate with the same noise, and no mixed value after a step | emulator: `emulator/scripts/test_dcv_fast.py` against the previous release |

All fixes of original defects are listed with their evidence in `ORIGINAL_FIRMWARE_ISSUES.md` (OF-xx) and in
`DESIGN.md` section 10 (NF-, HW-, NVM- items). A faster analog settle profile exists but stays disabled until the
hardware step tests in `HARDWARE_TEST.md` confirm it.
