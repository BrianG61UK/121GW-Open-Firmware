# User guide: the new features of the fast build

Everything on this page is in the **fast build** (`2_fast/EEVBlog.bin`). The `1_like_v2.05` build behaves like the
original firmware apart from the defect fixes and has none of these features. At power-on the fast build shows its
version, `F-1.08` (the release number, v1.0.8), on the small display; the main display stays blank until the first
reading. The `1_like_v2.05` build shows `V-2.05` like the original.

All settings are stored in bytes of the data EEPROM that the original firmware never uses. Calibration, serial number
and the original settings are not touched, and a meter flashed back to v2.05 simply ignores the new bytes.

## The SETUP menu in short

| Action | Key |
|---|---|
| Next page | press **SETUP** |
| Start changing the shown setting (the value blinks) | hold **SETUP** about half a second, until the long beep |
| Change the value | **REL** = next value, **PEAK** = previous value |
| Save | hold **SETUP** again until the long beep |
| Leave without saving | press **SETUP** |

If you start changing a setting and then press nothing for about two minutes, the change is undone. Only a saved
setting is kept over a power-off.

The new pages come after the original SETUP pages, in this order:

`bL` (backlight) → `bt` (Bluetooth speed) → `Ld` (firmware over Bluetooth) → `For` (format the card as exFAT, only with the new bootloader) → `rEL` (REL mode) → `tc` (thermocouple type, TEMP only) → `dSP` (display
level) → `bH` (continuity hold, BEEP only) → `LP` (4–20 mA view, DC mA only) → `Pt` (PT100 / PT1000 view, Ω only) → `CL` (12 / 24-hour clock) → `Lt`, `Lo`, `HI` (limit test; the verdict page
while the test is on) → `tr`, `Ch` (logging trigger) → back to the first page (while MIN/MAX is on, the statistics pages
`n` and `Sd` and the time pages `tHI` and `tLo` come before it)

The dBm reference is not a new page: it is edited on the existing dBm page of ACV.

## Backlight auto-off and memory

- **Light on / off:** hold **MODE**, as on the original firmware.
- **Auto-off time:** page `bL`. Values: `bLOFF` (never switch off, the default), `bL30S` (30 seconds; the display draws
  S like a 5), `bL  1` to `bL 99` (minutes).
- **After an auto-off:** any key press or dial turn switches the light back on for the set time. That key press only
  wakes the light and does nothing else; a dial turn also changes the function as usual. Every key press and dial turn
  while the light is on starts the time again.
- **Memory:** the meter remembers whether you last switched the light on or off with **MODE** and restores it at
  power-on and after an auto power-off. A switch-off by the timer does not change what is remembered.

Tip: `bL 1` or `bL 2` saves the batteries in a dark place without having to remember to switch the light off.

## dBm reference (ACV)

The ACV function has a dBm page in SETUP; the original always computes dBm into 600 ohm.

- **Where:** dial to **V**, press **MODE** for ACV, press **SETUP** until the dBm value shows (units dB m).
- **Change:** hold **SETUP**; the page shows the reference: `r 600` (default, as the original), `r  50`, `r  75`,
  `r dbV`. **REL** / **PEAK** step through them, hold **SETUP** to save.
- **Meaning:** dBm into 600 ohm (audio), 50 ohm (RF), 75 ohm (video), or dBV (decibels relative to 1 volt). For dBV
  only the dB sign is lit.
- The Bluetooth packet has no code for dBV, so a phone app labels every reference "dBm".

Check: 1.000 V reads 2.218 dBm (600 ohm), 13.01 dBm (50 ohm), 11.25 dBm (75 ohm), 0.000 dBV.

## Bluetooth speed

- **Bluetooth on / off:** hold **1ms PEAK** until **BT** shows / disappears, as on the original firmware.
- **Speed:** page `bt`: `bt  2` (2 readings per second, the default, as the original), `bt  4`, `bt 10`, `bt 20`.
- Verified working on a meter: 20 readings per second with the official iPhone application.

Tip: use `bt 10` or `bt 20` for live plotting on a phone or computer, `bt  2` when battery life matters more.

## REL in percent

- **Where:** page `rEL`: `rEL-d` (difference, the default, as the original) or `rEL-P` (percent).
- **Use:** with `rEL-P` saved, press **REL** as usual: the reading at that moment becomes the reference, and the meter
  shows how far the present reading is from it **in percent**, with the % sign instead of V, A, ohm and so on.
  Press **REL** again to return to the normal reading.
- **Resolution:** 0.001 % below 100 %, then 0.01 %, 0.1 % and 1 % up to 99999 %. Above that the display shows OFL; a
  reference of exactly zero shows `-----`.
- Logging, MIN/MAX and Bluetooth keep the normal REL value; only the display shows percent.

Tip: sorting parts against a nominal value. Measure a known-good part, press **REL**, then each part shows its deviation
in percent directly (for example 1 % resistors should stay within -1.000 .. 1.000).

## Thermocouple type K, J, T, N, R or S (TEMP)

- **Where:** dial to **mV / Temp**, press **MODE** until TEMP, then page `tc` (it is only offered in TEMP):
  `tc-K` (default, as the original), `tc-J`, `tc-t`, `tc-n`, `tc-r`, `tc-S`.
- **Ranges:** K -200 .. 1350 °C (as the original), J -200 .. 936 °C, T -200 .. 400 °C, N -200 .. 1300 °C, R and S
  -50 .. 1760 °C. Outside the range the display shows OFL. J stops at 936 °C because the meter's TEMP input is only proven up to the voltage K reaches at 1350 °C;
  a J thermocouple reaches that voltage at 936 °C.
- The cold junction (meter temperature) is compensated with the curve of the chosen type. All curves are the official
  NIST ITS-90 tables.
- R and S (platinum) thermocouples give a small voltage (about 6 µV per °C near room temperature), so near room
  temperature the reading moves in steps of about 0.2 °C and depends strongly on the meter's microvolt accuracy; they are
  meant for high temperatures.

Tip: a probe read with the wrong setting shows a wrong temperature: a J probe at 100 °C reads about 122 °C with the K
setting (meter at 25 °C). Set `tc` to the probe you plug in.

## Display level

- **Where:** page `dSP`, the last of the new pages: `dSP 1` (default, as the original) or `dSP 2`.
- **What it does:** the meter averages its last few readings before showing them, so the last digit stays steady; a big
  change still shows immediately. With `dSP 2` that averaging is four times shorter, so small changes and slow drifts
  appear about four times sooner (in AC volts a small step: 0.24 s instead of 0.96 s). How often the digits update does
  not change.
- **Cost:** the last digit can be a little less steady (for example a temperature that toggles between 99.9 and 100.0).

Tip: `dSP 2` while adjusting a trimmer or watching something warm up or charge; `dSP 1` for the steadiest reading.

## Limit test (pass / fail)

1. Put a known-good part (or source) at the **low** limit on the probes. SETUP to `Lo`, hold **SETUP**, press **REL**: the
   reading is captured. Hold **SETUP** to finish. The page then shows `Lo` and the captured value in turn.
2. The same with a part at the **high** limit on the page `HI`.
3. On `Lt`: hold **SETUP**, press **REL** (`LtOn`), hold **SETUP**: the small display now shows the verdict for every
   reading: `PASS` inside the limits, `HI` above, `Lo` below (an overload counts as `HI` or `Lo`). Leaving the limits
   gives the refusal beep, coming back the accept beep.
- While the test is on the range stays fixed (RANGE is refused); turning the dial ends the test. The limits are kept
  until the meter is switched off.
- Switching on is refused (refusal beep) until both limits are captured in the present function and range.

Tip: check a box of resistors without reading a single number: capture 99 ohm and 101 ohm, then every part shows `PASS`
or not.

## Logging trigger

Logging to the SD card is started and stopped as before (hold **MEM**). The page `tr` chooses when a record is written:

- `tr-In` (default, as the original): every interval (page `In`, seconds; 0 = about 5 records per second).
- `tr-Ch`: when the reading has changed by at least the threshold of the page `Ch` (1 to 255 counts, in the last digit
  of the reading) since the last record; checked once per second. With an interval above 0 a record is also written
  every interval.
- `tr-Lt`: when the limit test verdict changes (PASS / HI / Lo); with an interval above 0 also every interval while the
  reading is outside the limits.

The files have the same format as the original's, with one addition: the two closing rows `MAX,...` and `MIN,...` end
with the date and time of the row that held the maximum and the minimum, for example
`MAX,7,DCV,01.5000,V,2026/11/02,23:40:52,`. The first five columns are as before.

Tip: `tr-Ch` with `Ch 10` and interval 0 records a slowly drifting value only when it actually moves, so a long session
stays short and readable.

## 4–20 mA loop in percent (DC mA)

- **Where:** in DC mA (mA jack, dial A), page `LP`: `LPOFF` (default: the current, as the original), `L4-20`, `L0-20`.
- **Effect:** the main display shows the loop signal as a percentage with the % sign: 4 mA = 0.00 %, 12 mA = 50.00 %,
  20 mA = 100.00 % (with `L0-20`: 0 mA = 0 %, 20 mA = 100 %). Below 4 mA it goes negative, so a broken loop (0 mA) shows
  -25.00 %. Logging, Bluetooth and MIN/MAX keep the current in mA.

Tip: with `L4-20` a sensor's output reads directly in percent of its range, for example a pressure transmitter at 63.50 %.

## Firmware update over Bluetooth

- **On the meter:** Bluetooth on (hold PEAK), then press SETUP until the page `Ld-bt` (right after `bt`).
- **On the computer:** `python emulator/tools/bt_upload.py EEVBlog.bin` (Python 3 with the package `bleak`: `pip install
  bleak`). The meter shows the progress in percent (`Ld 45`), a full image takes a few minutes.
- **Result:** `Ld oK` means the file is on the card as `EEVBlog.bin` and was read back correctly (the temporary file
  `BTLOAD.TMP` is deleted). `LdE n` means it was not stored (1 card problem, 2 the file arrived damaged, 3 not a firmware
  file, 4 the copy failed, 5 the copy reads back differently); start the transfer again or copy the file with a computer.
  After `LdE 4` or `LdE 5` the card holds either the old `EEVBlog.bin` untouched or none at all (a partly written one is
  deleted, so the update key sequence then leaves the installed firmware unchanged).
- **Then update as usual:** switch off, hold HOLD and MEM while switching on, then press SETUP. With the two-part
  bootloader installed (next section) the companion does this step itself: no keys.
- Logging must be off. The meter keeps measuring during the transfer. Leaving the page stops it; the old `EEVBlog.bin`
  stays until a new file has arrived complete and checked.

## Card files and settings from the companion (page `Ld-bt`)

With the meter on the SETUP page `Ld-bt` (Bluetooth on, logging off, not in calibration mode), the 121GW Companion can:

- **list the card's files** (root folder, long names), **download** them (about 1 KB/s, every piece checked with a CRC),
  **delete** them (`cal.bin`, `EEVBlog.bin` and `BTLOAD.TMP` cannot be deleted), show the free space, and copy new or
  changed files into a folder on the computer ("sync");
- **read and change the settings** of the SETUP pages: thermocouple type, temperature unit, dBm reference, display level,
  continuity threshold and hold, Bluetooth speed, auto power-off, backlight auto-off, contrast, VA burden, buzzer, REL
  view, logging trigger and change threshold, 12-hour clock, current-loop and RTD views, battery trim.  A change is
  stored exactly as the page itself stores it; calibration, serial number and the rotary memory cannot be reached.  The
  logging interval is set on the meter only.

Nothing is written to the card except the deletes you confirm.  While the companion uses the card the readings pause
(the page `Ld` owns the link).

## Two-part bootloader (with the 121GW Companion)

The two-part bootloader (`bootloader/README.md`, releases `bl-vA.B.C`) replaces EEVblog's. The fast build supports it in two
ways, both used by the companion program (releases `companion-vA.B.C`):

- **First install:** the companion sends the install file over the same page `Ld-bt` (start the transfer by pressing SETUP
  until `Ld-bt`). The meter checks that its bootloader area is one of EEVblog's builds and that the battery is at least
  4.80 V, writes the new bootloader, restarts, and the starter installs it. Extra `LdE` codes: `LdE 7` the bootloader area is
  not one of EEVblog's builds (nothing written), `LdE 8` battery below 4.80 V (nothing written), `LdE 9` the install file or
  a flash step failed.
- **Update requests:** once the two-part bootloader is installed, the companion can ask the running firmware to restart into
  the bootloader's update mode, and can ask for the bootloader version (`B-` and three digits, or `B-EEV` for EEVblog's).
  The firmware and bootloader updates then run over Bluetooth with nothing to press on the meter. With EEVblog's bootloader
  the restart request does nothing; the card and key sequence above is the way.

The card update (HOLD + MEM at power-on, SETUP) keeps working with the two-part bootloader.

## Format the SD card (exFAT)

- **Where:** SETUP page `For`, right after `Ld-bt`.  It appears only when the meter has the new two-part bootloader
  (`bootloader/README.md`): EEVblog's original bootloader cannot read exFAT, so its card update would stop working.
- **How:** hold SETUP until `Fr no` blinks, press REL (or PEAK) for `Fr yE`, hold SETUP again.  `Fr --` while it works,
  then `Fr oK`.  **Everything on the card is erased.**  `FrE n` means the format failed (n = the FatFs result),
  `FrE L`: refused because logging is running or calibration mode is on.
- The meter reads and writes FAT12, FAT16, FAT32 and exFAT cards, with long file names (cards larger than 32 GB come
  formatted as exFAT).

## Battery voltage trim

- **Where:** SETUP page `BAT` (the battery voltage, the page after the temperature unit).
- **Use:** measure the meter's battery with another meter. Hold SETUP until the page shows `bA` and the voltage with two
  decimals, press REL (up) or PEAK (down) until it matches (steps of 0.2 %, at most ±10 %), then hold SETUP to save.
  A short SETUP leaves without saving.
- **Why:** the battery is measured through two resistors whose tolerance varies from meter to meter by a few percent; the
  trim corrects your meter. The low-battery symbol then also comes at the right voltage.

## PT100 / PT1000 temperature sensors (Ω)

- **Where:** in Ω (dial Ω, resistance function), page `Pt`: `PtOFF` (default: the resistance, as the original), `Pt100`,
  `P1000`.
- **Effect:** the main display shows the temperature of a platinum sensor (IEC 60751, the usual "385" type) with 0.1 °,
  in °C or °F as chosen for the temperature function, from -200.0 to 850.0 °C (outside: `OFL` / `-OFL`). Logging,
  Bluetooth and MIN/MAX keep the resistance in Ω.
- **Lead resistance:** the meter measures with two wires, so the test leads add to the sensor: 0.1 Ω reads about
  0.26 °C high with a PT100. To remove it, press RANGE until the sensor's range is shown (PT100: 500.00 Ω, PT1000:
  5.0000 kΩ), short the leads, press REL, then connect the sensor. A PT1000 is ten times less affected.

## Continuity beep hold time

- **Where:** in the continuity (BEEP) function, page `bH`: `bH100` (default, as the original), `bH 50`, `bH 25`, `bHOFF`.
- **Effect:** how long the beep continues after the probes lose contact: 100, 50 or 25 ms, or with `bHOFF` about 15 ms,
  the shortest time that still gives a clean, unbroken beep on a steady contact. The beep still starts 1 to 4 ms after
  contact.

Tip: `bH100` makes even the shortest touch audible (good for scratching along a trace); `bHOFF` shows intermittent
contacts as broken beeps.

## Statistics (MIN/MAX)

- **Where:** press **MIN/MAX** as usual; the small display now shows `n` and the number of readings collected (from 10000
  in thousands with the k sign). Press **SETUP** for `Sd`: the main display then shows the **standard deviation** of the
  readings, in the unit of the reading and with one more decimal where the range allows. Press **SETUP** again to return
  to the normal pages.
- The statistics use the same readings as the MIN/MAX average (HOLD pauses them, overloads are left out) and restart each
  time MIN/MAX is switched on. With fewer than two readings `Sd` shows `-----`.

Tip: leave the probes on a source for a while with MIN/MAX on; `Sd` tells how much the reading wanders, `n` how many
readings that is based on.

**When did the maximum and the minimum happen?** Press **SETUP** once more after `Sd`: the small display shows `tHI` and
the main display the time of the maximum as hours-minutes (`14-32`, in the 12- or 24-hour form chosen on `CL`); once more
for `tLo`, the time of the minimum; once more to return to the normal pages. `-----` means there is no maximum or
minimum yet. The times are kept until MIN/MAX is switched off. If the maximum is an overload, `tHI` shows the time of the
first overload.

Tip: start MIN/MAX in the evening on a supply rail, read `tLo` in the morning to see when it sagged.

## 12-hour clock

- **Where:** page `CL`, the last of the new pages: `CL 24` (default, as the original) or `CL 12`.
- **Effect:** the time page shows the hour as 1 to 12 instead of 0 to 23, for example 14:30 as ` 2-30`. There is no AM/PM
  mark (the display has five characters and the time uses all of them).
- Setting the clock works as before (hour, then minute). Log files and Bluetooth keep 24-hour time.

## °C or °F (original feature)

The first SETUP page shows the meter's own temperature, for example ` 25.0c`. Hold **SETUP**, press **REL** to switch
between `c` and `F`, hold **SETUP** to save. The same setting switches the TEMP function between °C and °F.

## Buzzer off (original setting, both builds)

SETUP page 3 shows `b-On` or `b-OFF`. With `b-OFF` the key beeps, the diode short tone, the auto-hold capture beep, the
auto power-off warning and the power-off beep are silent. Continuity still beeps (it is a continuity tester), and so do
the wrong-jack and high-voltage warnings. (The original also beeped for the diode, auto-hold and power-off with `b-OFF`.)

## Faster responses without a setting

The fast build also reacts faster, with no setting needed:

- **Continuity beep:** 1 to 4 ms after contact (original: 6 to 22 ms), measured in the emulator.
- **Diode short tone:** designed for about 20 ms (original: 0.38 s, measured).
- **Readings:** DC and AC currents, diode, the continuity display and the lower AC volt ranges update every 100 ms, the
  highest AC volt range every 25 ms, by design (original: about 221 ms, measured).
- **DC volts:** twice as many updates as the original, with the same steadiness (each value is still the average of the
  same 16 conversions, just shown twice as often). After a jump of the input the first value is the new level: the
  original could show a value in between once (for example 4.5 V when connecting 9 V).
- **Auto-hold in Ω and diode:** a short (0 Ω, 0 V) is captured like any other value; the original ignored readings below
  1000 digits. Open probes (OL) are still ignored. In the volt and current functions auto-hold still ignores readings
  near zero, because there open probes read about 0.

The full list of changes and fixed defects is in `OPTIMIZATIONS.md` and `ORIGINAL_FIRMWARE_ISSUES.md`.

## Problems

If something does not work as described, please open an issue on GitHub with the build (`2_fast` or `1_like_v2.05`),
what you did, what you expected and what the meter showed.
