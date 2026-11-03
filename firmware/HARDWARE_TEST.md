# Hardware test checklist (first run on a meter)

The image has only run in the emulator. These checks confirm on hardware what the emulator cannot.

## Before flashing
1. Dump the full data EEPROM over SWD: 0x08080000..0x08082FFF (12 KB). Keep it.
2. Save `cal.bin` to an SD card with v2.05 (power-on with MEM held, then REL, then MODE).
3. Note the battery voltage measured at the battery terminals.

## Flashing
- Build: `make` in `firmware/` (production) or `make LOOP_V205=1` (strict build that behaves like v2.05 apart from
  the defect fixes). The output `firmware/build/EEVBlog.bin` already has the file name the bootloader looks for
  (the only file name in the bootloader image; FAT short names ignore case, so the manual's "EEVblog.bin" is the same
  file).
- Normal route: copy `EEVBlog.bin` to the SD card and use the manual's Firmware Update procedure (page 72: battery
  not low, both buttons held at power-on, "IAP", confirm; the meter restarts itself). The bootloader
  0x08000000..0x08005FFF is not changed; it writes the application from 0x08006000.
- Alternatively over SWD to 0x08006000 (application area only).

## First boot
1. Power on (batteries; a current-limited supply instead of the batteries is optional). Splash `V-2.05` on the sub
   display, first reading within about 0.5 s.
2. Every dial position: reading and annunciators plausible; DCV/Ohm against a reference source.
3. Dump the EEPROM again and compare with the dump from before: must be identical (no write at boot).

## Checks the emulator cannot make
1. Battery reading against the measured battery voltage (OF-52: the port uses the hardware divider; v2.05 read up
   to 6 % low near empty).
2. Auto power-off / STOP and wake by every key and dial position (power-down pin order HW-02/03/04/08; STOP wake
   with SEVONPEND, NF-05).
3. SD logging with a slow card for a few minutes, then check the CSV and the card on a PC (v2.05's write wait is
   about 7 ms; whether SDIO TXACT stays set during card busy decides if slow cards fail: DESIGN 12.2).
4. Calibration-mode entry no longer clears the user current zeros (OF-08); cal.bin save/load round trip
   (1248-byte file; a 1200-byte v2.05 file must also load).
5. Analog settling for the faster settle profile (`AR_PROFILE_TP`, off by default): step tests below. Enable the
   profile only for the paths whose test passes.

| Test | Procedure and pass criterion | Unlocks |
|---|---|---|
| H1 | DCV: input step 0 -> 4 V and 4 V -> 0 V in r0, r1, r2 and 0 -> 400 V in r2/r3. Record the raw AD1 code per conversion after the range change (UART debug). Pass when the 3rd conversion after the change is within 1 count of the settled value in r1..r3, and in r0 within 1 count after 321 ms (input pre-filter time constant) | TP for DCV |
| H2 | OHM: steps open -> 10 ohm, 1 kohm, 100 kohm, 4 Mohm, 40 Mohm with 1 m test leads, per range. Pass as in H1 | TP for OHM |
| H3 | Currents: shunt range change r0 <-> r1 (<-> r2) at 0.4 A and 4 A, as in H1 | TP for currents |
| H4 | ACV/ACmV/AC current: AD8436 output after range changes and steps, per conversion, to obtain its settling time | an AC discard shorter than v2.05's |
| H5 | AD1CHOP = 1x output rate: count AD1F events per second on a DCV row | the AD1 rate with chopping on |
| H6 | BEEP per-sample noise at 1, 5 and 10 ohm (standard deviation in counts over 1000 samples) | hysteresis of codes 4, 5, 6, 10, 11, 12 |
| H7 | VA channel switch: the conversions after a c4 toggle, as in H1 | a shorter VA channel dwell |
| H8 | Range change with the delay(10000) of `hy3131_counter_restart` (0x0800BFCE) removed: counter and AD1 results after the change compared with the delay kept | t_apply of about 7 ms instead of 24 ms |
6. Continuity beep latency and the new thresholds (SETUP, codes 4..15).
7. Backlight auto-off timer (production build): SETUP page bL, set 30 s, switch the backlight on with MODE long, count the
   time to switch-off (30..31 s after the last key press or dial turn), check that a key press restarts it, that OFF never
   switches it off, that after an auto power-off and wake the backlight comes back as it was last switched by MODE long, and that the
   on/off state is kept over a power-off (on stays on, off stays off). Dump the
   EEPROM after the save: only byte 0x017 may differ.
8. dBm reference (production build): ACV with a known sine (for example 1.000 V at 1 kHz), SETUP to the dBm page (2.218
   dBm), long SETUP, REL to `r  50` and long SETUP: 13.01 dBm; `r  75`: 11.25 dBm; `r dbV`: 0.000 with dB alone. Power off
   and on: the reference is kept. Dump the EEPROM after the save: only byte 0x011 may differ.
9. Bluetooth frame rate (production build): transfer on (PEAK long), SETUP to the page bt (after bL), long SETUP, step to
   `bt  4`, `bt 10`, `bt 20` and save; check in the phone application (or a BLE logger) that readings arrive at the chosen
   rate and that the application still connects and decodes them. Dump the EEPROM after the save: only byte 0x015 may differ.
10. Thermocouple type (production build): TEMP, SETUP to the page tc (after bt), select J or T and save; with a J or T probe
   (or a thermocouple calibrator set to J / T) compare readings at room temperature, in ice water (0 degC) and at a known
   hot point. Dump the EEPROM after the save: only byte 0x00F may differ.
11. REL in percent (production build): SETUP to the page rEL (after bt), select `rEL-P` and save; DCV with a source at 1 V,
   REL, then 1.1 V: 10.000 with the % sign and no V; REL off: volts again. Dump the EEPROM after the save: only byte 0x020
   may differ.
12. Display level (production build): SETUP to the page dSP (last page), select `dSP 2` and save; a slowly changing
   source (or a small step) settles visibly faster; the reading is somewhat noisier. Dump the EEPROM after the save: only
   byte 0x013 may differ.

## After the tests
- Dump the EEPROM once more; only the bytes of the actions you performed may differ (settings, calibration you ran).
- To return to v2.05: flash the original image; settings and calibration stay readable (same EEPROM layout).

Intended differences from v2.05 are listed in `ORIGINAL_FIRMWARE_ISSUES.md`, `OPTIMIZATIONS.md` and `DESIGN.md`
section 10.
