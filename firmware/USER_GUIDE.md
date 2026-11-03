# User guide: the new features of the fast build

Everything on this page is in the **fast build** (`2_fast/EEVBlog.bin`). The `1_like_v2.05` build behaves like the
original firmware apart from the defect fixes and has none of these features.

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

`bL` (backlight) → `bt` (Bluetooth speed) → `rEL` (REL mode) → `tc` (thermocouple type, TEMP only) → `dSP` (display
level) → back to the first page

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

## Thermocouple type K, J or T (TEMP)

- **Where:** dial to **mV / Temp**, press **MODE** until TEMP, then page `tc` (it is only offered in TEMP):
  `tc-K` (default, as the original), `tc-J`, `tc-t`.
- **Ranges:** K -200 .. 1350 °C (as the original), J -200 .. 936 °C, T -200 .. 400 °C. Outside the range the display
  shows OFL. J stops at 936 °C because the meter's TEMP input is only proven up to the voltage K reaches at 1350 °C;
  a J thermocouple reaches that voltage at 936 °C.
- The cold junction (meter temperature) is compensated with the curve of the chosen type. The J and T curves are the
  official NIST ITS-90 tables.

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

## Faster responses without a setting

The fast build also reacts faster, with no setting needed:

- **Continuity beep:** 1 to 4 ms after contact (original: 6 to 22 ms), measured in the emulator.
- **Diode short tone:** designed for about 20 ms (original: 0.38 s, measured).
- **Readings:** DC and AC currents, diode, the continuity display and the lower AC volt ranges update every 100 ms, the
  highest AC volt range every 25 ms, by design (original: about 221 ms, measured).

The full list of changes and fixed defects is in `OPTIMIZATIONS.md` and `ORIGINAL_FIRMWARE_ISSUES.md`.

## Problems

If something does not work as described, please open an issue on GitHub with the build (`2_fast` or `1_like_v2.05`),
what you did, what you expected and what the meter showed.
