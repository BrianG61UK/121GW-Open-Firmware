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
| IMP-03/04 | Faster Ohm readings and continuity/diode response (decided per sample) | continuity beep about 3..6 ms after contact instead of 14..16 ms; diode short tone about 20 ms instead of 0.38 s |
| IMP-05 | Extended continuity thresholds (EEPROM byte 0x14, codes 4..15: 1, 5, 10, 50, 100, 200 ohm, both directions) | same setting byte; codes 0..3 keep v2.05's meaning |
| IMP-06 | No busy-waiting: deferred LCD commits, blocking routines as state machines, WFI sleep between loop passes | every HY3131 conversion is processed (v2.05 drops most of them, OF-31); lower supply current |
| IMP-07 | Backlight auto-off timer: SETUP page bL, OFF (default) / 30 s / 1..99 min | after the chosen time without a key press or dial turn the backlight switches itself off (MODE long press switches it on, and off, as before); stored in EEPROM 0x017 (a byte v2.05 never uses, `EEPROM_MAP.md` 4.1); the flag and countdown also follow the pin after a STOP wake (v2.05 needed two MODE long presses after a wake with the backlight on) |
| IMP-08 | Selectable dBm reference on the ACV page 11: 600 ohm (default, as v2.05), 50 ohm, 75 ohm, dBV | long SETUP on the dBm page, REL / PEAK step, long SETUP saves; RF (50 ohm), video (75 ohm) and dBV readings without conversion by hand; stored in EEPROM 0x011 (`EEPROM_MAP.md` 4.1) |
| IMP-09 | Selectable Bluetooth frame rate: SETUP page bt, 2 (default, as v2.05) / 4 / 10 / 20 frames per second | faster live readings for a host that keeps up; the 500 ms timing of the rest of the meter is untouched; stored in EEPROM 0x015 (`EEPROM_MAP.md` 4.1) |

All fixes of original defects are listed with their evidence in `ORIGINAL_FIRMWARE_ISSUES.md` (OF-xx) and in
`DESIGN.md` section 10 (NF-, HW-, NVM- items). A faster analog settle profile exists but stays disabled until the
hardware step tests in `HARDWARE_TEST.md` confirm it.
