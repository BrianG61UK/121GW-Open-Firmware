# Planned features of the replacement firmware: user interface, storage, constraints

Status: design. The backlight auto-off timer (2.9, IMP-07), the dBm reference (2.2, IMP-08), the Bluetooth frame rate
(2.5, IMP-09), the thermocouple type (2.8, IMP-10), REL in percent (2.3, IMP-11), the display level (2.4, IMP-12) and the 12-hour
clock (2.12, IMP-13) are implemented. The other features are designs for
the production image; none of them is in the tree as code. The EEPROM bytes of section 3 are approved (owner, 2026-11-02);
each is added to `EEPROM_MAP.md` 4.1 and `nvm_allow` only with the code that uses it. Citations: `KS` = `analysis/keys_setup.md`, `EMAP` =
`EEPROM_MAP.md`, `LCD` = `analysis/lcd_map.md`, `ARS` = `analysis/autorange_and_scheduler.md`, `DES` = `DESIGN.md`.

## 1. Rules that hold for every feature

### 1.1 Production image only

Every feature is assembled only when `LOOP_V205 == 0` (`.if LOOP_V205 == 0` around the code, the hooks into v2.05 routines
and the EEPROM table bits). The strict image (`make LOOP_V205=1`) contains none of them: it is byte-identical to the build
made before the first feature (checked for IMP-07 by `cmp`), it never reads or writes the port-only EEPROM bytes, and its
`nvm_allow` table does not allow them (`gen_nvm_allow.py` emits their bits as `mask * (1 - LOOP_V205)`, EMAP 4.1).

### 1.2 Keys

Only the 8 keys and the dial exist (KS 1). Every v2.05 key function of KS 2.2, 3 and 4 stays as it is. The one key
action that v2.05 neither performs nor refuses is the long press of HOLD (KS 2.1: `FUN_08016B4C` does not accept 0x20,
"holding HOLD 50 ticks does nothing, and the short press is lost"); the limit test (2.1) is the only feature that uses it. All other new behaviour is reached through SETUP pages, which use
only the keys SETUP, REL and PEAK in the way v2.05's pages do:

| Action | Keys (as v2.05, KS 4) |
|---|---|
| next page | SETUP short (no previous-page key; the list wraps) |
| start edit | SETUP long on an editable page (refusal beep on a page that is not editable, while logging, or in MEM view) |
| change the value | REL = up, PEAK = down (auto-repeat as KS 2.1) |
| save | SETUP long again (long beep; the EEPROM write goes through NVM, `nvm_arm` + SETTINGS class) |
| leave without saving | SETUP short (value stays changed in RAM until power-off, as v2.05's pages 0, 2, 3), or the edit timeout of about 2 minutes, which re-reads the stored value (`fn_0800D190`, extended per page) |
| digit pages (ID in v2.05) | SETUP short moves the digit cursor 4, 3, 2, 1, 0, 4 while editing (KS 4, item 8) |

No power-on key combination is used by any feature. KS 3 shows that the window combinations (MODE+REL calibration mode,
MEM+REL/PEAK+MODE cal.bin, SETUP date editing, RANGE all segments) are the calibration and backup paths; a new combination
there would sit next to a path that erases or restores calibration data, so the settings are reached only after the window
has closed.

### 1.3 SETUP pages

The page list of v2.05 (items 0..9 for all modes, 10..12 for some modes, 100 for MEM view/logging, KS 4) is unchanged. Port
pages are appended behind the last v2.05 page of every mode: the wrap of `fn_08015410` to item 0 lands on the first port page
that applies, the last port page goes to item 0 (as implemented for item 20, `src/set/setup.s`). The item byte 0x20008037
is read by other modules only for equality with 1, 7, 10, 11, 12 and 100 (DES 6.24), so new item numbers 20..35 are harmless
there; the BLE packet carries zeros in its sub-display field for them, as for items 3, 4, 8 and 9 (`ble/packet.s`).
Each page is drawn on the sub display (five characters) by `lcd_draw_5char(1, ...)` like `FUN_08018460` and `FUN_080184D4`.
Pages with a number that needs a sign and five digits (limits, standard deviation) draw a label on the sub display and
the value on the main display, which has the sign, the decimal point and the unit annunciators of the present range
(precedent for suppressing the main refresh: the MEM view, DES 3.5 step 3).

### 1.4 What the display can show

Ten 7-segment positions: sub 0..4, main 5..9 (LCD 2). The font (`FUN_0801AFFC`, LCD 2) has '0'..'9', 'A'..'Z', 'a'..'z',
' ', '-', '='; no other character is drawn. Shapes used in this document: b d h n o r t u c (lower case), A C E F H I
L P S (S looks like 5) U and 'O' (looks like 0), G looks like 9 and M like 8 (not used). Existing annunciators that the
features reuse: REL (w0b0), MIN, MAX, AVG, HOLD, A-, MEM, BT, Apo, battery, Sub% (w0b17, the % element that DUTY lights),
sub V/A/m/dB/k/Hz/Ohm units, sub minus (w4b29), main minus (w3b7) (LCD 4). No PASS/FAIL or unit-minute element exists, so
verdicts and units are written as text.

### 1.5 EEPROM

Only bytes that v2.05 never accesses (EMAP 4, the list "Every byte inside 0x000..0x4FF that no v2.05 routine other than
calbin_save / calbin_load reads or writes") and only in 4-byte words that hold no calibration, serial, date or marker byte,
because a byte write rewrites its whole word (EMAP 1): the words 0x00C..0x00F, 0x010..0x013 and 0x014..0x017 hold settings
only (rotary memory, unit, DIODE flag, continuity code, APO), and 0x020..0x023, 0x028..0x02B and 0x02C..0x02F hold nothing.
Rules for every byte:

- all-zero is v2.05 behaviour: a blank byte, a byte restored from a v2.05 `cal.bin` (the supplied backup is 0x00 at all of
  them, EMAP 4), or an invalid value reads as the default, and the invalid value is left in the EEPROM as found;
- v2.05 flashed back ignores the bytes (it never reads them), and a v2.05 `calbin_load` of a port backup writes the file's
  values into them without ever reading them;
- inside the `cal.bin` range 0x000..0x4AF: `calbin_save` stores them in the file, `calbin_load` restores them (RESTORE
  class); restoring a backup made by v2.05 therefore resets every port setting to its default;
- writes only through NVM with arming (`set_nvm_store`), class SETTINGS, one byte per call, MSB first for the two s32 limits;
  the table of allowed bytes is generated from EMAP 4.1, so a byte that is not listed there cannot be written.

### 1.6 HY3131

No feature sends the HY3131 anything. All of them work on values the existing chain has produced (display counts
0x20007D64, the mean, the flags) or on the host links, so the whitelist of DES 4.1 (the 47 (row, INTE) pairs and the six
frame shapes of v2.05) is untouched and `check_hy.py` needs no change. The two features that change how fast values appear
(2.4, 2.5) change the display-side mean length and the frame period only, never a configuration row (the rows may not be
changed, ARS 7: "r5/r6 are row-bound ... those rows may not change").

## 2. The features

### 2.1 Limit test (pass/fail)

- Where: SETUP pages `Lt` (on/off), `Lo` and `HI` (limit values), and a verdict page; quick on/off by HOLD long.
- Keys: HOLD long (0.5 s) switches the test on or off with the long beep. Refused with the refusal beep while logging, in MEM
  view, in calibration mode, while a setup edit is active, and when the limits do not belong to the present mode and range
  (below). HOLD short is unchanged. The pages use the edit keys of 1.2; `Lo` and `HI` are digit pages (cursor positions
  4..0 and a sixth for the sign; SETUP short moves the cursor).
- What is shown: `Lt` page `LtOn ` / `LtOFF`. `Lo` / `HI` pages: sub display `Lo   ` / `HI   `, main display the limit in
  display counts with the decimal point of the range and the unit annunciators of the mode, the digit under the cursor blinks.
  While the test is on the verdict page is the default page (it replaces item 0 or 10 in `fn_0800D718`) and shows
  `PASS ` when Lo <= reading <= HI, `HI   ` above HI, `Lo   ` below Lo; an overload counts as `HI   ` (positive) or `Lo   `
  (negative). A change from PASS to out of limits gives the refusal pattern of the buzzer once (`fn_0800EE6C`, if the buzzer
  is on), and the change back gives the accept beep. The reading compared is the displayed value 0x20007D64 after REL,
  smoothing and (in MIN/MAX) the state's value.
- Range: switching the test on freezes the range as MIN/MAX does (`range_manual = 1`, the saved value is restored when the
  test ends), and RANGE short is refused while it is on. A mode change (dial, MODE) switches the test off. Reason: the limits
  are counts of one range; a limit compared across ranges would need a table of 10^exponent per (mode, range).
- Storage: RAM only (owner, 2026-11-02: limits are forgotten at power-off). LO and HI as s32 and the range they belong to as
  `mode * 8 + range + 1` (0 = none) in RAM; saving a limit page binds both limits to the present mode and range. The on/off state is RAM only (off at
  power-on, so a meter never measures with a forgotten test). Until a limit is saved after power-on the tag is "none" and the
  test refuses to start.
- Limit entry (owner, 2026-11-02, left to the design): the value is taken from the present reading (long SETUP on `Lo` or `HI`
  captures the displayed value 0x20007D64) rather than typed digit by digit; the digit editor above is the fallback if capture
  proves unusable.
- Constraints: counts are limited to -99999..99999 by the display (`0x08017036`..`0x08017040`, OF-49); the editor does not
  accept more. Limits in LowZ and BEEP are accepted (single range). Logging with trigger "limits" (2.6) uses the same verdict.

### 2.2 Selectable dBm reference (implemented, IMP-08)

- Where: the existing ACV page 11 (the dBm value; KS 4 "dBm = 10 log10(x^2 / 0.6)"), which becomes editable. No new item.
- Keys: long SETUP on the page starts the edit (v2.05 refuses it there), REL/PEAK step the reference, long SETUP saves.
- What is shown: normally the dB value as in v2.05 with the sub units dB and m (dBm) or dB only (dBV). During the edit the page
  shows the reference as text: `r 600`, `r  50`, `r  75`, `r dbV` (r, a blank, the load in ohm; V is drawn like U) in the order
  600, 50, 75, dBV; the value returns after the save. For dBV the sub units show dB alone: the V element of the sub unit row
  sits below dB, not beside it (element boxes of `emulator/ui/assets/lcd`), so it is not lit.
- Storage: one byte 0x011: 0 = 600 ohm (v2.05: the constant 0.6, `0x0800A7C6`..`0x0800A7E8`), 1 = 50 ohm (0.05), 2 = 75 ohm
  (0.075), 3 = dBV (1.0); any other value reads as 0. Blank = v2.05 behaviour.
- Constraints: display-side arithmetic only (the constant of the dBm formula). The BLE packet keeps its sub-mode byte 0xB4
  for this page (`analysis/ble_packet.md` 4), so a phone application labels all four references "dBm"; for dBV that label is
  wrong. OF-46 (zero reading, five dashes) stays as fixed.

### 2.3 REL in percent (implemented, IMP-11)

- Where: SETUP page `rEL`, item 22, after `bt` in every mode; REL short and REL long keep their v2.05 meaning in every mode.
- Keys: the edit keys of 1.2 on the page (REL or PEAK switches between the two values); no new key action.
- What is shown: page `rEL-d` (difference, v2.05) or `rEL-P` (percent). With percent selected the main display shows
  (x - ref) / ref * 100 whenever v2.05 shows the REL sign (REL on, 0x20007FE1 = 0, 0x20007FE4 = 0): 0.001 % resolution
  below 100 %, then 0.01, 0.1 and 1 % up to 99999 %, each rounded half away from zero once from the exact quotient; above
  99999 % ` OFL ` (the OL flag is not set); a zero reference `-----`. The unit and prefix signs of the reading are off and
  the % sign (Sub%, the sign of DUTY) is on; when the view ends every sign of the mode is redrawn. The reference is the base
  REL captured from its first result, as in v2.05 (`fn_0800E594`, RAM 0x20007DA8).
- Storage: bit 0 of the byte 0x020 (0 = difference, v2.05); the other bits of the byte are written back as loaded, an
  erased byte reads as 0.
- Constraints: display-side only; logging, BLE (0x20007D70 keeps the REL value in counts) and MIN/MAX keep using the value
  that is not scaled. Modes where REL is vetoed in v2.05 (flag 0x20008048, KS 2.2) stay vetoed. Code: `ui/relpct.s`
  (view, draw, sign mask applied at every full commit), `set/relp.s` (page).

### 2.4 Faster display response (implemented, IMP-12)

- Where: SETUP page `dSP`, item 24, the last port page in every mode (after `rEL`, or after `tc` in TEMP).
- Keys: the edit keys of 1.2 (REL or PEAK switches between the two levels).
- What is shown: `dSP 1` (as v2.05) or `dSP 2` (fast).
- Meaning (owner decision, 2026-11-02: less smoothing, not shorter means): every displayed value is the thresholded mean of
  the last N means (`fn_0800B754`, `fn_08008344` and the OF-28 blocks); a step larger than the threshold restarts the
  filter at once, a smaller change takes up to N means. Level 2 uses a quarter of every depth, at least 1 (10 -> 2,
  20 -> 5, 5 -> 1, 2 -> 1); thresholds unchanged. The mean lengths, so the update rate of the digits (DCV 200 ms, DCmV and
  TEMP 400 ms, Ohm, AC, currents, DIODE and BEEP 100 ms in the production build), auto-ranging, the settle counts and the
  HY3131 rows are not changed. Shorter means were not taken: auto-ranging (`ar_apply`, M = 16), the settle counts, the AC+DC
  and burden dwell and the Ohm range-change skip all count means.
- Effect measured in the emulator: a 15-count step in ACV (threshold 20, depth 10) settles in 0.96 s at level 1 and 0.24 s
  at level 2. Noise: ACV 1 V, DCmV 10 mV and OHM 1 kohm stay steady at both levels; TEMP 100 degC is steady at level 1 and
  toggles its last digit (99.9 / 100.0, spread 0.4 counts) at level 2. A meter's noise can differ from the emulator's model;
  MIN/MAX follows the displayed value and sees the same noise.
- Storage: one byte 0x013 (0 = level 1). Any other value reads as 0.
- Constraints: no HY3131 write; the depth change needs no filter reset (`func/smooth.s` header). FREQ, PULSE, DUTY have no
  smoothing; CAP uses its own depth (10), which level 2 also reduces.

### 2.5 Faster Bluetooth streaming (implemented, IMP-09)

- Where: SETUP page `bt`, item 21, after `bL` (the BT annunciator and the PEAK long press that switch the transfer on and off are unchanged, KS 2.2).
- Keys: the edit keys of 1.2.
- What is shown: the number of frames per second: `bt  2` (as v2.05), `bt  4`, `bt 10`, `bt 20`.
- Meaning: v2.05 starts a 19-byte frame every 50 TIM2 ticks (0.501 s) and builds it 10 ticks before (`analysis/ble_packet.md`
  2). USART2 runs at 19200 baud, 8N1: a frame takes 19 x 10 / 19200 = 9.9 ms, about one tick. The same 50-tick counter also
  makes the 500 ms flag, the blink phases and the jack-warning beep, so the faster rates run on their own counter
  (`ble/rate.s`): periods 25, 10 and 5 ticks with the build requested 10, 5 and 2 ticks before the start; 2 per second keeps
  the v2.05 counter. The port's transmit side (OF-10) sends only complete frames and skips a start that finds none, so the
  rate is a maximum and a frame is never torn; command echoes keep their queue between frames. Frame format, checksum and
  sub-display content are unchanged.
- Storage: one byte 0x015 (0 = 2 per second). Any other value reads as 0.
- Verified working on a meter: 20 frames per second with the official iPhone application.
- Constraints: the link is raw serial through the module on USART2; whether the phone application keeps up with 20 frames per
  second is not known here (no hardware test); the option is therefore a setting, default v2.05.

### 2.6 Smarter SD logging

- Where: SETUP pages `tr` (trigger), `Ch` (change threshold); the existing page 9 `In nnn` (interval, KS 4) stays and gets a
  second meaning; closing MIN/MAX rows in the file; MIN/MAX time pages (below). Logging is started and stopped as in v2.05
  (MEM long, MEM+HOLD long).
- Keys: the edit keys of 1.2. `Ch` is a number page on the main display like `Lo`.
- What is shown: `tr-In` (a record every interval, v2.05), `tr-Ch` (a record when the reading has moved by at least the
  threshold since the last record, and every interval seconds if the interval is not 0), `tr-Lt` (a record at every change of
  the limit verdict of 2.1 and every interval seconds while out of limits; needs the limit test on, else it behaves as
  `tr-In`). Page `Ch`: sub `Ch   `, main the threshold in counts of the present range (1..255).
- How: the trigger is evaluated on the 1 s flag at the place of the interval counter (loop step 9, `v_20007FA8`), so the
  fastest rate is one record per second (whether a slow card keeps up is the open hardware question of DES 12.2). The record request is
  the existing flag 0x20007FE2; the record format, CSV header and file naming are v2.05's, byte for byte.
- MIN/MAX with timestamps: (a) in the file, the two closing rows of v2.05 (`MAX,<row>,<func>,<value>,<unit>` and `MIN,...`,
  `log_write_minmax_rows`) get two more columns at the end, `,YYYY/MM/DD,hh:mm:ss` of the row, so a reader of the first five
  columns sees v2.05's text; (b) on the meter, while MIN/MAX is on, two extra SETUP pages `tHI` and `tLo` (items 34, 35) show
  hour and minute of the maximum and of the minimum in the format of page 7 (`FUN_080188A0`); the times are taken from the
  clock chip when the extreme is recorded (`fn_0800E604`), RAM only.
- Storage: bits 2..1 of 0x020 (trigger 0, 1, 2; 3 reads as 0), 0x022 (threshold 1..255; 0 reads as 1). The interval stays at
  0x018..0x019.
- Constraints: LOG is state-machine code in production (IMP-06); the trigger only decides when the request flag is set. No
  change to what a record contains.

### 2.7 Statistics: standard deviation and count

- Where: extra SETUP pages `n` (item 32) and `Sd` (item 33), visible only while MIN/MAX is on, the way v2.05 adds
  mode-specific items (KS 4); switching MIN/MAX on makes `n` the page shown.
- Keys: SETUP short moves between pages, nothing else. The statistics restart with MIN/MAX (first MIN/MAX press clears the
  registers, `FUN_08015974`) and end with it (MIN/MAX long). No page is editable (long SETUP: refusal beep).
- What is shown: `n` page: `n` followed by the count, capped at 9999 on the display (the count itself is kept to
  1 000 000, as v2.05's `func_mm_count`); `Sd` page: sub `Sd   `, main the sample standard deviation in display counts with the
  decimal point of the range; `-----` while fewer than two readings exist.
- How: v2.05 already keeps the count and a running mean (`minmax.s`: mean as integer plus remainder, count to 1 000 000). The
  deviation uses Welford's update on those: M2 += d * (x - mean_new) in an unsigned 64-bit sum (d is at most 2 * 10^5 and the
  count 10^6, so M2 stays below 4 * 10^16 < 2^64), and sigma = sqrt(M2 / (n - 1)) with an unsigned 64-bit divide by n - 1, the
  unsigned-to-double conversion and `dsqrt`. M2 is non-negative by construction, so no catastrophic-cancellation formula
  (sum of squares minus square of the sum) is used. v2.05 keeps the mean as an integer and a remainder; whether the integer
  part alone is accurate enough for d (the display resolution is one count) is to be bounded when this is implemented.
- OF-51: statistics are the first caller that feeds data-dependent operands to these helpers. The helper deviations of OF-51
  that matter are `dsqrt` for a negative or negative-zero operand (it writes errno 0x20000228 and returns a wrong value) and
  the 64-bit divide by zero (returns the dividend). Neither occurs when n >= 2 and M2 >= 0, and the statistics code checks
  both; in addition the production runtime library gets the fixed behaviour for those two cases (`dsqrt`: NaN result and no
  errno store for a negative operand; divmod: documented result for a zero divisor), under `.if LOOP_V205 == 0`, because a
  silent wrong value would be a silently wrong measurement. The other OF-51 cases (float divide exponent 254, add/subtract with a
  subnormal operand) cannot be reached: the operands are integers converted from 64-bit values. OF-51's status changes to "fixed
  (fast build)" when the fix is made.
- Storage: none (RAM only: M2 u64, the two time stamps of 2.6).

### 2.8 Thermocouple types J and T (and K) (implemented, IMP-10)

- Where: SETUP page `tc`, item 23, reached from the page `bt` in TEMP mode (mode 5) only.
- Keys: the edit keys of 1.2.
- What is shown: `tc-K ` (v2.05), `tc-J `, `tc-t `. The degC/degF annunciators and the 0.1 degree display are unchanged.
- How: v2.05 converts the thermocouple voltage plus the cold junction (uV) with a table of 158 entries t[k] = EMF at (10 k - 210)
  degC, linear interpolation, and an input window x >= -5891 / x < 54139 uV for K (`analysis/hy3131_modes_misc.md` 4.1; table
  0x08025CF8); the cold junction is interpolated in the same table (0x08013CF8). J and T have tables of the same shape,
  generated by `firmware/tools/gen_tc_tables.py` from the NIST ITS-90 tables (J -210..1200 degC, 142 entries; T -210..400
  degC, 62 entries; NIST check points J 100 degC 5269 uV, T 100 degC 4279 uV). Both routines take the table and the window
  from the descriptor of the selected type (`mtmp/tctype.s`).
- Spans: K -200..1350 degC (v2.05); J -200..936 degC; T -200..400 degC. The low limit is the -200 degC entry for every type, as
  for K. TEMP measures on the DCmV 50 mV input and v2.05 accepts no EMF above 54138 uV, so J is limited to the same input
  voltage (936 degC); the NIST J range continues to 1200 degC (69553 uV), a voltage the original never measures. Beyond a
  limit the reading shows OFL, as K does (flag 0x200080AD).
- Storage: one byte 0x00F: 0 = K (v2.05), 1 = J, 2 = T; any other value reads as 0.
- Constraints: tables only, the AD1 chain and the HY3131 row of TEMP are untouched; calibration records (0x0F0) are for the
  voltage chain and do not depend on the type. The log and BLE carry the converted temperature, so they follow the type; the
  CSV unit text is unchanged. Finding while generating the tables: OF-56 (one K entry 1 uV low, kept).

### 2.9 Backlight auto-off timer (implemented, IMP-07)

- Where: SETUP page `bL` (item 20), after the last v2.05 page of every mode.
- Keys: the edit keys of 1.2. The MODE long press still switches the backlight on and off (KS 2.2); every key press, every dial
  position change, an injected remote key and every edit step restart the countdown.
- What is shown: `bLOFF` (never, default), `bL30S` (30 s; the 7-segment S, the shape of a 5, owner 2026-11-02),
  `bL  1` .. `bL 99` (minutes). Sub display only; the main display keeps the reading. REL steps OFF, 30 s, 1 .. 99 min and wraps;
  PEAK goes the other way.
- Behaviour: while the backlight is on and the setting is not OFF, `pwr_bl_second` counts the 1 s flag down (the same flag as the
  APO countdown). The start value is the time plus one second, so the backlight stays on for the chosen time and at most one
  second more. At zero the backlight is switched off as the MODE long press does it (RAM flag 0x2000807B and PE8), without a
  beep. No countdown runs while it is off. Power-on and STOP wake clear the flag and the count, because PE8 is low in both, then
  restore the state of bit 7 below. Any key press or dial change after a timer switch-off switches the backlight on again
  (the key press is consumed; the dial acts normally).
- Storage: byte 0x017 (EMAP 4.1), bits 6..0: 0 OFF, 1 = 30 s, 2..100 = 1..99 min; above 100 reads as OFF. Bit 7: the
  backlight state after the last MODE long press, restored at power-on and wake (owner, 2026-11-02); the timer's own
  switch-off and wake do not write it. 0xFF (erased) reads as OFF and dark. Word 0x014..0x017 holds the
  continuity code and the APO flag only.
- Constraints: no HY3131 access; absent from the strict image.

### 2.10 Firmware update over Bluetooth
- Request (owner, 2026-11-02): update the firmware without taking the SD card out.
- Facts (bootloader `inputs/binaries/bootloader.bin`, base 0x08000000, disassembly): update mode is entered only by the keys at
  reset (GPIOG IDR 0x40021C10 read at 0x0800486C..0x080048B2: MEM PG11 and HOLD PG13 low, then SETUP PG9 low within the wait
  loop 0x080048FE..0x0800490A); no RAM, EEPROM, RTC backup or reset-cause flag is read, so the application cannot start an
  update by itself. The only source is `EEVBlog.bin` on the card root (string 0x08004EF4); no serial port is referenced. The
  bootloader erases 0x08006000..0x0805FF00 (0x08004B8C) before it reads the file, ignores the erase and `f_read` results, and
  checks only the initial stack pointer of the programmed image (0x08004994..0x080049A0): a truncated file is programmed. It
  never writes below 0x08006000, so a bad image is recovered by a good file and the key sequence.
- Design: a receive mode in the production image (entry by a key combination to be chosen, shown on the display) takes the
  image over the Bluetooth link (USART2, 19200 baud, `analysis/ble_packet.md` 1) in numbered chunks with a CRC per chunk and an
  acknowledgement; a new frame type is needed, because the receive interrupt accepts only F4 and F8 frames (0x08024820). The
  chunks are written to a temporary file on the card (`fat_f_write`, `src/sd/fat_file.s`); after the last chunk the length and
  a CRC32 of the whole file are checked against the header sent first, and only then is the file renamed to `EEVBlog.bin`.
  The meter then asks for the usual update sequence (HOLD+MEM at power-on, SETUP). The application never writes flash.
- Host side: a sender program (computer Bluetooth; packaged with the emulator) that splits, sends and resends.
- Verified working on a meter: the official iPhone application connects to the production image and shows live readings
  (meter to phone direction).
- Open, measured on a meter first: whether the BLE112 module passes arbitrary bytes from the host to USART2 at the full rate
  (the official application writes only 5-byte F4 frames, `analysis/ble_packet.md` 7), and the real throughput. The UART bound
  is 1920 bytes per second (141 124 bytes: 74 s at least); receive is deaf while the card is accessed (`src/ble/usart.s`
  header), which the acknowledgement covers.
- Storage: none.

### 2.11 Bluetooth viewer for computers
- Request (owner, 2026-11-02): the official phone application connects but draws badly (glitches, colours, unreadable
  text); a viewer of our own.
- Design: a desktop program (macOS, Windows, Linux) that connects to the meter over the computer's Bluetooth LE, decodes
  the status frame (`analysis/ble_packet.md` 3) and draws the display with the emulator's LCD renderer
  (`emulator/ui/assets/lcd`), so the picture is the meter's own segments. Additions: CSV logging, a trend graph,
  statistics. It is the host side of 2.10 as well (sender of a firmware image).
- Open: the BLE112's GATT service and characteristic that carry the frames (to be read from a meter with a BLE scanner);
  no firmware change is needed for viewing.

### 2.12 12-hour clock (implemented, IMP-13)
- Where: SETUP page `CL`, item 25, the last port page (after `dSP`): `CL 24` (v2.05, default) or `CL 12`.
- What is shown: the time page (item 7) keeps its form `HH-MM` with the blinking separator; with `CL 12` the hour is 1..12
  (0 -> 12, 13..23 -> 1..11) with the leading zero blank (` 2-30`). No AM/PM mark (decision, 2026-11-02: the five
  characters are all used by `HH-MM`, and morning and afternoon are told apart by context).
- How: `fn_080188A0` (the only routine that draws the time; time page, its edit and the RTC module) converts the hour it
  is given. The clock chip, the hour edit (0..23 internally), the log timestamps and the BLE clock command stay 24-hour.
- Storage: bit 3 of the byte 0x020 (shared with 2.3; each page's save changes only its bit, `set_b20_store`).

## 3. EEPROM bytes the features need

| Offset | Feature | Meaning | Default (0x00) | Word shared with | Status |
|---|---|---|---|---|---|
| 0x00F | 2.8 thermocouple | 0 K, 1 J, 2 T | K | 0x00C..0x00E rotary memory | approved, implemented |
| 0x011 | 2.2 dBm | 0 600 ohm, 1 50 ohm, 2 75 ohm, 3 dBV | 600 ohm | 0x010 temperature unit, 0x012 DIODE flag | approved, implemented |
| 0x013 | 2.4 display | 0 level 1, 1 level 2 | level 1 | as 0x011 | approved, implemented |
| 0x015 | 2.5 BLE | 0 2/s, 1 4/s, 2 10/s, 3 20/s | 2/s | 0x014 continuity code, 0x016 APO | approved, implemented |
| 0x017 | 2.9 backlight | bits 6..0: 0 OFF, 1 30 s, 2..100 1..99 min; bit 7: on/off state | OFF, dark | as 0x015 | approved, implemented |
| 0x020 | 2.3, 2.6, 2.12 | bit 0 REL percent, bits 2..1 log trigger, bit 3 12-hour clock | v2.05 | none (free word 0x020..0x023) | approved, bits 0 and 3 implemented |
| 0x021 | 2.1 limits | `mode * 8 + range + 1` of the limits, 0 none | none | as 0x020 | approved, not used (limits RAM only) |
| 0x022 | 2.6 | change threshold 1..255 | 1 | as 0x020 | approved |
| 0x028..0x02B | 2.1 | LO limit, s32 big-endian | 0 | none (free word) | approved, not used (limits RAM only) |
| 0x02C..0x02F | 2.1 | HI limit, s32 big-endian | 0 | none (free word) | approved, not used (limits RAM only) |

0x023 stays unused. Every offset above is in the never-accessed list of EMAP 4. The alternative locations 0x4B0..0x4CF (32
bytes, never accessed by any code, outside `cal.bin`) would keep the settings out of a restored backup, but EMAP 9.1 item 2
forbids writing them, so they are not proposed. Items that need no byte: 2.7, the on/off state of 2.1, the time stamps of 2.6.

## 4. Setup item numbers

| Item | Page | Shown | Editable |
|---|---|---|---|
| 20 | `bL` backlight | always | yes (implemented) |
| 21 | `bt` | always | yes (implemented) |
| 22 | `rEL` | always | yes (implemented) |
| 23 | `tc` | TEMP mode only | yes (implemented) |
| 24 | `dSP` | always | yes (implemented) |
| 25 | `CL` | always | yes (implemented) |
| 26 | `Lt` | always | yes |
| 27 | `Lo` | always | yes (digits) |
| 28 | `HI` | always | yes (digits) |
| 29 | `tr` (log trigger) | always | yes |
| 30 | `Ch` | always | yes (digits) |
| 31 | verdict `PASS`/`HI`/`Lo` | while the limit test is on (also the default page) | no |
| 32 | `n` count | MIN/MAX on | no |
| 33 | `Sd` | MIN/MAX on | no |
| 34, 35 | `tHI`, `tLo` | MIN/MAX on | no |

Items 32..35 are the MIN/MAX pages. v2.05 uses 0..12 and 100; the page dispatcher falls back to item 0 for an unknown item
(`fn_0801797C` end), so each new page needs its own branch before that fallback, as `.Lsd_port` does for items 20 to 25. SETUP short steps
20 -> 21 -> 22 -> 23 (TEMP only) -> 24 -> 25 -> 0 (`fn_08015410`); each new page joins that chain.

## 5. Order of work and checks

1. 2.9 (done): both images built, `cmp` of the strict image against the build made before the change, `make check` for both,
   the induced emulator test `emulator/scripts/test_backlight_timer.py` (30 s setting, restart by key and dial, OFF never, the
   edit writes only 0x017, STOP and wake), one scenario of the differential harness for the page list
   (`setup_navigate_dcv`, entries IMP-07 in `deviations.txt`).
2. 2.8, 2.2, 2.3, 2.4, 2.5: independent display or host-link changes; each with a routine-level test and an induced emulator test.
3. 2.1 and 2.6 together (the log trigger uses the verdict), then 2.7 with the RT fix of OF-51.
4. 2.10 after a link test on a meter (throughput and transparency of the module), together with 2.11.
For each: the owner decision on its bytes first, then EMAP 4.1 rows and `gen_nvm_allow.py`, then code, then
`OPTIMIZATIONS.md` and `DESIGN.md` entries, `make check` for both images, and a byte comparison of the strict image.
