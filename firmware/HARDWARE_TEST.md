# Hardware test checklist (first run on a meter)

These checks confirm on hardware what the emulator cannot.

## Before flashing
1. Dump the full data EEPROM over SWD: 0x08080000..0x08082FFF (12 KB). Keep it.
2. Save `cal.bin` to an SD card with v2.05 (power-on with MEM held, then REL, then MODE).
3. Note the battery voltage measured at the battery terminals.

## Flashing
- Build: `make` in `firmware/` (the fast build; the build that behaves like v2.05 apart from the defect fixes is
  `make LOOP_V205=1` on the branch `like-v2.05`). The output `firmware/build/EEVBlog.bin` already has the file name the bootloader looks for
  (the only file name in the bootloader image; FAT short names ignore case, so the manual's "EEVblog.bin" is the same
  file).
- Normal route: copy `EEVBlog.bin` to the SD card and use the manual's Firmware Update procedure (page 72: battery
  not low, both buttons held at power-on, "IAP", confirm; the meter restarts itself). EEVblog's bootloader
  0x08000000..0x08005FFF is not changed by this route; it writes the application from 0x08006000. The card must be FAT
  (FAT32) for EEVblog's bootloader; exFAT only once the two-part bootloader is installed (`bootloader/README.md` on the
  branch `bootloader`), which also updates over Bluetooth through the 121GW Companion.
- Alternatively over SWD to 0x08006000 (application area only).

## First boot
1. Power on (batteries; a current-limited supply instead of the batteries is optional). The version (`F-1.16` for the
   fast build, `V-2.05` for the like-v2.05 build) shows on the sub display; the fast build shows nothing on the main display
   until the first reading (IMP-35). First reading within about 0.5 s.
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
10. Thermocouple type (production build): TEMP, SETUP to the page tc (after rEL), select J, T, N, R or S and save; with such a probe
   (or a thermocouple calibrator set to the type) compare readings at room temperature, in ice water (0 degC) and at a known
   hot point. Dump the EEPROM after the save: only byte 0x00F may differ.
11. REL in percent (production build): SETUP to the page rEL (after Ld, or after Fr with the two-part bootloader), select `rEL-P` and save; DCV with a source at 1 V,
   REL, then 1.1 V: 10.000 with the % sign and no V; REL off: volts again. Dump the EEPROM after the save: only byte 0x020
   may differ.
12. Display level (production build): SETUP to the page dSP (after rEL, or after tc in TEMP), select `dSP 2` and save; a slowly changing
   source (or a small step) settles visibly faster; the reading is somewhat noisier. Dump the EEPROM after the save: only
   byte 0x013 may differ.
13. 12-hour clock (production build): SETUP to the page CL (after dSP, or after bH, LP, Pt or HUnt in their functions), select `CL 12` and save; the time page shows the
   hour 1..12 (for example 14:30 as ` 2-30`); the clock keeps running correctly. Only byte 0x020 may differ.
14. Statistics (production build): DCV, MIN/MAX on: page `n` counts the readings; SETUP to `Sd`: the standard deviation
   on the main digits (a steady source: a few counts; switching between two voltages: about half their difference);
   MIN/MAX long press: back to the normal page. No EEPROM change.
15. Continuity hold (production build): BEEP, SETUP to the page bH (after dSP), select `bHOFF` and save; tap the probes
   together: the beep ends about 15 ms after the touch; with `bH100` a tap gives a beep of about 0.1 s. Only byte 0x021 may differ.
16. HY3131 write timing (production build, IMP-19): the configuration writes now run at the bit timing of the v2.05 read
   loop. Check that every function reads correctly and ranges correctly: DCV with a known source on every range (auto and
   manual RANGE), ACV, Ohm (short, 1 k, 100 k, 1 M), continuity, diode, capacitance, frequency, temperature, the current
   modes with a known current, peak hold in ACV. Any wrong range, frozen reading or wrong value: report it with the build
   and the function; the strict build is unchanged and can be flashed back.
17. Limit test (production build): DCV, a source at the low limit: SETUP to `Lo`, long SETUP, REL, long SETUP; the same at
   the high limit on `HI`; `Lt`: long SETUP, REL, long SETUP: the verdict page; values inside show `PASS`, outside `HI` /
   `Lo` with the refusal beep, back inside the accept beep; RANGE is refused; turning the dial ends the test.
18. Logging trigger (production build): SD card in, `tr-Ch`, `Ch 10`, interval 0; log a slowly changing source: the file
   holds a record only when the value moved 10 counts; `tr-In` logs as before. Stop the logging: the closing `MAX` and
   `MIN` rows end with the date and time of the rows they name (compare with those rows in the file).
19. MIN/MAX times (production build): DCV, MIN/MAX on; raise the input, wait for the clock minute to change, lower it;
   SETUP past `n` and `Sd`: `tHI` shows the hour-minute of the raise, `tLo` that of the drop (12-hour form with `CL`);
   SETUP again returns to the normal pages; long MIN/MAX ends it.
20. Large SD card (both builds, OF-57): an SD card of 8 GB or more, formatted FAT32 (or exFAT with the two-part bootloader). On a PC copy files onto it until more
   than 4.5 GB are used, then log on the meter for two minutes. Afterwards the PC opens the card without a repair prompt,
   the copied files are unchanged and the log file is complete (its rows run without a gap and end with MAX and MIN).
21. File dates (both builds, OF-58): the log file and a saved `cal.bin` show the meter's date and time as created and
   modified on the PC (v2.05: created 2006-02-09 22:30).
22. Buzzer off (both builds, OF-63): SETUP page 3 `b-OFF`. Diode short, auto-hold capture, the auto power-off warning and the
   power-off beep are silent; continuity still beeps, and so do the wrong-jack and high-voltage warnings.
23. 4-20 mA view (production build, IMP-24): DCmA, SETUP page `LP` = `L4-20`; a known current (for example a 4-20 mA
   source or a 9 V battery through a resistor): the display shows (I - 4 mA) / 16 mA x 100 % with the % sign; `LPOFF` shows
   the current again.
24. PT100 / PT1000 view (production build, IMP-25): OHM, SETUP page `Pt` = `Pt100`; a resistor near 100 ohm (or a PT100
   sensor): the display shows the IEC 60751 temperature of the reading with the degC sign (100.00 ohm = 0.0 degC,
   138.51 ohm = 100.0 degC); `PtOFF` shows the resistance again.
25. Battery trim (production build, IMP-27): measure the battery with another meter; SETUP to `BAT`, long SETUP (`bA` and
   the voltage in 0.01 V), REL / PEAK until it matches, long SETUP saves. Power off and on: the trimmed value is kept. Dump
   the EEPROM after the save: only byte 0x02A may differ.
26. Bluetooth firmware transfer (production build, IMP-28): Bluetooth on, SETUP to `Ld-bt`, run
   `emulator/tools/bt_upload.py EEVBlog.bin` on a computer: `Ld nn` counts up, then `Ld oK`. Card in a computer: `EEVBlog.bin`
   equals the file sent (compare the SHA-256). Then the usual update with HOLD + MEM at power-on and SETUP; the new version
   shows at power-on. Leave the page during a transfer: the sender reports no answer, the old `EEVBlog.bin` is unchanged.
27. Format as exFAT (production build with the two-part bootloader, IMP-32; verified working on a meter 2026-11-04/05):
   SETUP to `Fr` (after `Ld`), long SETUP (`Fr no` blinks), REL for `Fr yE`, long SETUP: `Fr --` then `Fr oK`. Card in a computer: it is
   exFAT and empty. Log on the meter and save `cal.bin`: both files are on the card. Without the two-part bootloader the
   page `Fr` is not shown.
28. SD card reliability (production build, IMP-33, IMP-34; verified working on a meter 2026-11-04/05: 5 Bluetooth transfers
   to the card with 0 failed writes and 0 failed card start-ups in 220 start-ups): repeat the Bluetooth transfer of item 26
   and power the meter on with the card in several times. Every transfer ends with `Ld oK`; the card starts every time (no
   `SdEnn` message, `sd_init` error 0x25 never).
29. Bootloader install and updates through the companion (verified working on a meter 2026-11-04/05: firmware update into
   bootloader B-1.11 and bootloader update 1.1.0 to 1.1.1 over Bluetooth): follow `bootloader/README.md` (branch
   `bootloader`): fresh batteries, install from the companion, then a firmware and a bootloader update. The data EEPROM
   dump before and after must be identical.
30. Capacitance anti-hunting (production build, IMP-45; not yet tried on a meter: no capacitor that hunts is at hand): CAP,
   SETUP page `HUnt` (after `dSP`): the sub display shows `HUnt`, the main display `oFF`; long SETUP (the sub display
   blinks), REL: `on`, long SETUP saves (only EEPROM 0x020 bit 4 changes). A ceramic capacitor of about 100 nF that makes
   the range hunt (digits blank, decimal point moving, with `oFF`) must then stay on the 1 µF range after two range-1 timeouts
   (two timeouts of 2.5 s each, plus the time of the range-2 measurements in between) and show its value; a different capacitor, open probes or a MODE or RANGE press end the lock. Capacitors
   that measure normally behave as before with `on` or `oFF`.
31. CAP 100 nF range wait (production build, F-1.13, IMP-43; experimental; not measured on a meter yet): CAP in auto range
   with a capacitor of about 100 nF whose reading does not arrive on the 100 nF range: the range changes to 1 µF about
   2.5 s after the capacitor is connected, by stopwatch (v2.05: 2.0 s); a capacitor that gives its result on the 100 nF range
   shows it with the 100 nF range's digits (for example `100.00` nF). The wait itself is checked in the emulator by
   `emulator/scripts/test_cap_timeout.py` (reload of range 1 in auto range 250 ticks of 10 ms, manual range 300, range 2 200).
   Report how long your capacitors take.
32. Extended link diagnosis (production build, F-1.15, IMP-44; the counters answered with the frame F9 on a meter 2026-11-06:
   verified working on a meter for the counters themselves): Bluetooth on, the Companion (1.2.15 or newer) connected, SETTINGS
   "Extended diagnosis" on, then "Save report" on the METER view: the report holds the nine values (bytes received, overruns,
   noise flags, framing errors, bytes discarded while the clock was not MSI, rejected frames, packets answered "CRC wrong",
   answers not queued, battery in 0.01 V); the byte count grows when the Companion sends keys. Switch the meter off and on:
   the counters are zero again (RAM only). With the setting off the Companion does not switch counting on and the report shows no counters. Dump the EEPROM before and after:
   identical.
33. Card clock (production build, F-1.12, IMP-41, OF-69, OF-70; verified working on a meter 2026-11-05: three formats of a
   32 GB card of 16 s each without a failed block, 100 s of logging, the file downloaded over Bluetooth): format the card as
   in item 27 and time it; log for a minute or more, then download the file over Bluetooth. No card error (`SdEnn`, `FrE n`,
   `LdE 1`) and a complete file. Before F-1.12 a format of this card took 40 s at ClockDiv 4, or stopped on a transmit underrun.
34. Run clock measurement (production build, F-1.17, IMP-46, OF-72; verified working on a meter 2026-11-07): Bluetooth on, the
   Companion (1.2.18 or newer) connected, SETTINGS "Extended diagnosis" on, "Save report" on the METER view: the section
   "meter clock" says "measured", the clock as found within a few tenths of a percent of 4194304 Hz (2026-11-05 a DWT count
   against the HY3131 gave about 4.187 MHz on one meter), the clock in use closer to 4194304 Hz than the clock as found or
   equal to it, and the baud within 0.25 % of 19200. Then a live view of several minutes and a card file list without
   damaged bytes (report "damaged pieces" none), a firmware transfer over Bluetooth, an auto power-off and a wake (the report
   again "measured", the trim kept), a card format and logging (the card session runs on the crystal and must work as in
   item 33). Dump the EEPROM before and after: identical. On a meter whose crystal does not start (not expected) the result
   says so and everything works as with F-1.16.
   Verified working on a meter 2026-11-07 (F-1.17 dev image): 4190308 .. 4190796 Hz (-0.084 .. -0.095 %) at four starts
   and one dial OFF / on, trim 0 (both neighbouring trims measured worse), 19223 baud (BRR 218), 0 % damaged bytes over
   60 s at bt 20, MSICAL 0x5A unchanged after a card session.  The first F-1.17 image measured nothing (status 5): HSE_RTC
   reached TIM11 only with RTCSEL = HSE (DESIGN.md IMP-46).
35. Leave page Ld (F-1.17, IMP-47; verified working on a meter 2026-11-07): with the meter on `Ld-bt`, the Companion's
   button "Leave Ld-bt" (CARD view): the meter shows the next SETUP page and the readings come back.
36. Wake from auto power-off (F-1.18, OF-73, IMP-48; the wake by a key verified working on a meter 2026-11-07 with a test
   image whose auto power-off came after 70 s; Bluetooth on again after the wake verified the same day): Bluetooth on, let the meter switch itself off ("-oFF-", blank display), press HOLD:
   the meter shows its reading again and Bluetooth is on; again with the dial turned to another position instead of a
   key.
37. Auto power-off time (F-1.18, IMP-49; verified working on a meter 2026-11-07: the page, APO. 1 saved, the warning, the
   power-off after one minute and the key wake): page APO, REL steps APO.60, APO.oF, APO. 1, APO.15, APO.30; save APO. 1 and
   wait: five warning beeps about 15 s before the meter switches off one minute after the last key press; a key wakes it
   (item 36). Dump the EEPROM: only 0x016 and 0x02B changed.

## After the tests
- Dump the EEPROM once more; only the bytes of the actions you performed may differ (settings, calibration you ran).
- To return to v2.05: flash the original image; settings and calibration stay readable (same EEPROM layout).

Intended differences from v2.05 are listed in `ORIGINAL_FIRMWARE_ISSUES.md`, `OPTIMIZATIONS.md` and `DESIGN.md`
section 10.
