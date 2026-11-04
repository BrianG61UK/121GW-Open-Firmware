# Planned features of the replacement firmware: user interface, storage, constraints

Status: design. The backlight auto-off timer (2.9, IMP-07), the dBm reference (2.2, IMP-08), the Bluetooth frame rate
(2.5, IMP-09), the thermocouple type (2.8, IMP-10), REL in percent (2.3, IMP-11), the display level (2.4, IMP-12), the 12-hour
clock (2.12, IMP-13), the statistics (2.7, IMP-14), the continuity hold time (2.13, IMP-16) and the limit test (2.1, IMP-20) are
implemented. The other features are designs for
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

### 2.1 Limit test (pass/fail) (implemented, IMP-20; verified working on a meter)

- Where: SETUP pages `Lt` (item 27), `Lo` (28), `HI` (29) after `CL`, and the verdict page (36) while the test is on.
- Keys (decisions 2026-11-02: limits captured from the reading, not typed; RAM only): `Lt`: long SETUP, REL or PEAK
  switches the test on or off, long SETUP ends the edit and shows the verdict page. `Lo` / `HI`: long SETUP, REL or PEAK
  captures the displayed value, long SETUP ends the edit. Switching on is refused (refusal beep) unless both limits were
  captured in the present mode and range; Lo above HI is swapped. HOLD keeps its v2.05 meaning (no HOLD long action: HOLD
  is not a long-press key in v2.05, KS 2.2).
- What is shown: `LtOn ` / `LtOFF`; `Lo---` / `HI---` before a capture, then the label and the value (digits and decimal
  point of its range) alternating every 0.5 s; verdict `PASS `, `HI   ` (above HI), `Lo   ` (below Lo), an overload by
  its sign; `-----` before the first verdict.
- Behaviour: the verdict compares the displayed value 0x20007D64 (after REL and smoothing) for every new result; leaving
  PASS gives the refusal pattern, returning to PASS the accept beep (both through the buzzer setting). While the test is on
  the range is frozen as MIN/MAX freezes it and RANGE short and long are refused; a mode change ends the test (the range
  setting is restored). A capture in another mode or range binds both limits to it (the other is captured again).
- Storage: none (RAM only; off and no limits after power-on and STOP wake).
- Constraints: counts are limited to -99999..99999 by the display. Logging with trigger "limits" (2.6) uses the same
  verdict.

### 2.2 Selectable dBm reference (implemented, IMP-08; verified working on a meter)

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

### 2.3 REL in percent (implemented, IMP-11; verified working on a meter)

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

### 2.4 Faster display response (implemented, IMP-12; verified working on a meter)

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

### 2.6 Smarter SD logging (implemented, IMP-21; verified working on a meter)

- Where: SETUP pages `tr` (item 30, after the limit pages) and `Ch` (item 31, with `tr-Ch` only); the existing page 9
  `In nnn` (interval) keeps its meaning. Logging is started and stopped as in v2.05 (MEM long, MEM+HOLD long).
- What is shown: `tr-In` (a record every interval, v2.05), `tr-Ch` (a record when the displayed reading has moved by at
  least the threshold since the last record, tested once per second; with an interval above 0 also every interval),
  `tr-Lt` (a record at every change of the limit verdict of 2.1; with an interval above 0 also every interval while the
  verdict is not PASS). With `tr-Ch` and `tr-Lt` an interval of 0 means the trigger only (v2.05's 5-per-second path of
  interval 0 is for `tr-In`). Page `Ch`: `Ch` and the threshold 1..255 counts. The first record of a `tr-Ch` session is
  taken at the first second. The change is measured against the value of the last record; a record taken while a step
  settles holds a partly settled mean, and the next record comes when the reading has moved the threshold from it.
- How: the trigger only sets v2.05's record request 0x20007FE2 (sys_main step 9; `log/trigger.s`); the record format, CSV
  header and file naming are v2.05's, byte for byte (mem_logging_sd with noise off identical to v2.05).
- MIN/MAX with timestamps (implemented): (a) in the file, the two closing rows of v2.05 (`MAX,<row>,<func>,<value>,<unit>,`
  and `MIN,...`, `log_write_minmax_rows`) end with the date and time of the row they name, `YYYY/MM/DD,hh:mm:ss,` (as the data
  rows write them), so a reader of the first five columns sees v2.05's text (`log/mmtime.s`; the time is kept when
  `log_take_max_main` / `log_take_min_main` take the row); (b) on the meter, while MIN/MAX is on, two extra SETUP pages after
  `Sd`: `tHI` (item 34) and `tLo` (item 35); the sub display shows the label, the main display the hour and minute of the
  maximum / minimum as `HH-MM`, the form of page 7 (24-hour, or 12-hour with page `CL`), `-----` while the register holds
  no value yet; not editable; nothing drawn while HOLD is active (as `Sd`). The time is taken from the clock chip copy
  (rtc_hour / rtc_minute, read every 100 ms) whenever `fn_0800E604` changes the maximum or minimum; an overload sets the
  register to +-100000 as in v2.05 and the time is kept only when it was not that value already (the first overload).
  RAM only (`ui/mmtime.s`).
- Storage: bits 2..1 of 0x020 (trigger 0, 1, 2; 3 reads as 0), 0x022 (threshold 1..255; 0 reads as 1). The interval stays at
  0x018..0x019. (Trigger and threshold implemented.)
- Constraints: LOG is state-machine code in production (IMP-06); the trigger only decides when the request flag is set. No
  change to what a record contains.

### 2.7 Statistics: standard deviation and count (implemented, IMP-14; verified working on a meter)

- Where: SETUP pages `n` (item 32) and `Sd` (item 33), only while MIN/MAX is on; switching MIN/MAX on shows `n`. SETUP
  short goes `n` -> `Sd` -> item 0; from `CL` it reaches `n` while MIN/MAX is on. When MIN/MAX ends (its long press, HOLD,
  a mode change) a selected statistics page is replaced by item 0 at the next result.
- Keys: SETUP short only; the pages are not editable (long SETUP: refusal beep).
- What is shown: page `n`: `n` and the count right-aligned up to 9999, from 10000 the count in thousands with the sub k
  sign (`n 125` k); page `Sd`: `Sd` on the sub display and the sample standard deviation on the main digits in the unit,
  range and decimal point of the reading, with one more decimal where the range allows (decimal point code below 4 and at
  most 99999), rounded to nearest; `-----` for fewer than two readings, ` OFL ` above 99999 counts. Nothing is redrawn
  while HOLD is active. The BLE value keeps the MIN/MAX value.
- How: the readings that enter v2.05's running mean (MIN/MAX on, HOLD off, no overload; fn_0800E604) are given to
  Welford's update in binary64 (`func/stats.s`): n, mean, m2; sigma = sqrt(m2 / (n - 1)). Each added term equals
  delta^2 (n - 1) / n >= 0, so m2 never goes negative and no difference of large sums is formed. Readings (|x| < 2^24)
  and n convert exactly. At 1 000 000 readings (v2.05's own count limit) the statistics freeze.
- OF-51: the production runtime library answers a negative dsqrt operand with NaN (-0 with -0, no errno) and gives a
  64-bit division by zero a defined result (unsigned: quotient all ones, signed: -1; remainder = dividend). The
  statistics never reach either case (m2 >= 0, n - 1 >= 1).
- Storage: none (RAM only).

### 2.8 Thermocouple types J, T, N, R and S (and K) (implemented, IMP-10; N, R, S IMP-26)

- Where: SETUP page `tc`, item 23, reached from the page `bt` in TEMP mode (mode 5) only.
- Keys: the edit keys of 1.2.
- What is shown: `tc-K ` (v2.05), `tc-J `, `tc-t `, `tc-n `, `tc-r `, `tc-S ` (N, R, S: forum request 2026-11-03,
  IMP-26). The degC/degF annunciators and the 0.1 degree display are unchanged.
- How: v2.05 converts the thermocouple voltage plus the cold junction (uV) with a table of 158 entries t[k] = EMF at (10 k - 210)
  degC, linear interpolation, and an input window x >= -5891 / x < 54139 uV for K (`analysis/hy3131_modes_misc.md` 4.1; table
  0x08025CF8); the cold junction is interpolated in the same table (0x08013CF8). J and T have tables of the same shape,
  generated by `firmware/tools/gen_tc_tables.py` from the NIST ITS-90 tables (J -210..1200 degC, 142 entries; T -210..400
  degC, 62 entries; NIST check points J 100 degC 5269 uV, T 100 degC 4279 uV; N -210..1300 degC, 152 entries; R and S
  -210..1760 degC, 198 entries, of which 0..15 (-210..-60 degC) are search sentinels below the NIST start of -50 degC). The
  linear interpolation between 10 degC entries differs from the NIST 1 degC values by at most K 0.161, J 0.156, T 0.122,
  N 0.226, R 0.263, S 0.227 degC (printed by the generator). Both routines take the table and the window
  from the descriptor of the selected type (`mtmp/tctype.s`).
- Spans: K -200..1350 degC (v2.05); J -200..936 degC; T -200..400 degC; N -200..1300 degC; R and S -50..1760 degC (NIST
  ends at 1768 degC, beyond the last 10 degC entry). The low limit is the -200 degC entry, as for K, except R and S (-50 degC,
  where NIST starts). R and S give about 5.4 uV per degC near 0 degC, so one 1 uV count is about 0.2 degC there and the
  microvolt accuracy of the input dominates; they suit high temperatures. TEMP measures on the DCmV 50 mV input and v2.05 accepts no EMF above 54138 uV, so J is limited to the same input
  voltage (936 degC); the NIST J range continues to 1200 degC (69553 uV), a voltage the original never measures. Beyond a
  limit the reading shows OFL, as K does (flag 0x200080AD).
- Storage: one byte 0x00F: 0 = K (v2.05), 1 = J, 2 = T, 3 = N, 4 = R, 5 = S; any other value reads as 0.
- Constraints: tables only, the AD1 chain and the HY3131 row of TEMP are untouched; calibration records (0x0F0) are for the
  voltage chain and do not depend on the type. The log and BLE carry the converted temperature, so they follow the type; the
  CSV unit text is unchanged. Finding while generating the tables: OF-56 (one K entry 1 uV low, kept).

### 2.9 Backlight auto-off timer (implemented, IMP-07; verified working on a meter)

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

### 2.12 12-hour clock (implemented, IMP-13; verified working on a meter)
- Where: SETUP page `CL`, item 25, the last port page (after `dSP`): `CL 24` (v2.05, default) or `CL 12`.
- What is shown: the time page (item 7) keeps its form `HH-MM` with the blinking separator; with `CL 12` the hour is 1..12
  (0 -> 12, 13..23 -> 1..11) with the leading zero blank (` 2-30`). No AM/PM mark (decision, 2026-11-02: the five
  characters are all used by `HH-MM`, and morning and afternoon are told apart by context).
- How: `fn_080188A0` (the only routine that draws the time; time page, its edit and the RTC module) converts the hour it
  is given. The clock chip, the hour edit (0..23 internally), the log timestamps and the BLE clock command stay 24-hour.
- Storage: bit 3 of the byte 0x020 (shared with 2.3; each page's save changes only its bit, `set_b20_store`).

### 2.13 Continuity beep hold time (implemented, IMP-16; verified working on a meter)
- Request (forum, 2026-11-03): the continuity beep latches a little too long; a setting for it.
- Where: SETUP page `bH`, item 26, offered in BEEP only (between `dSP` and `CL`): `bH100` (v2.05, default), `bH 50`,
  `bH 25`, `bHOFF`.
- What it does: v2.05 keeps the tone 100 TIM3 ticks after the last reading that passed the threshold
  (`pe7_on_with_timeout(100)`, 0x08007902 / 0x08007920), so a short contact gives an audible beep. The page sets that
  time to 100, 50 or 25 ms, or 15 ms (`bHOFF`: the shortest hold that never chops a steady contact; the re-arms of a
  steady contact come every 4.0 ms, 3.1 .. 10.0 ms in the emulator, so 10 ms or less would interrupt the tone). The threshold, the detection per
  conversion (IMP-04) and the time to the tone are unchanged.
- Storage: one byte 0x021 (0 = 100 ms); a value above 3 reads as 0.

### 2.14 Current-loop percent for DC mA (implemented, IMP-24)
- Request (forum, 2026-11-03): show a 4-20 mA (or 0-20 mA) signal as 0-100 %.
- Where: SETUP page `LP`, item 37, offered in DCmA only (between `dSP` and `CL`): `LPOFF` (v2.05, default), `L4-20`,
  `L0-20`.
- What is shown: in DCmA the main display shows p = (I - 4 mA) / 16 mA x 100 % (or I / 20 mA x 100 %) with 0.01 %, rounded
  half away from zero, the % sign on and the A sign off; below 4 mA negative (-25.00 % at 0 mA). DCmA range 0 (5.0000 mA,
  0.1 uA) and range 1 (50.000 mA, 1 uA) are both used. REL keeps its own display; HOLD freezes the display; an overload
  shows OFL.
- How: `ui/loop.s` replaces the draw of D in `fn_08016E08` like the REL percent view (2.3) and shares its sign mask; logging,
  MIN/MAX and the BLE frame keep the current in counts.
- Storage: one byte 0x028 (0 = off); a value above 2 reads as 0 (EEPROM_MAP.md 4.1).
- Not in calibration mode: there DCmA shows the current.

### 2.15 Platinum RTD temperature in OHM (implemented, IMP-25)
- Request (forum, 2026-11-03): read a PT100 / PT1000 sensor as a temperature.
- Where: SETUP page `Pt`, item 38, offered in OHM only (between `dSP` and `CL`): `PtOFF` (v2.05, default), `Pt100`, `P1000`.
- What is shown: in OHM the main display shows the sensor temperature with 0.1 degree, in degC or degF as TEMP (SETUP page
  of the temperature unit), with the degC or degF sign on and the ohm and k signs off; -200.0 .. 850.0 degC, outside that
  ` OFL ` / `-OFL`. The conversion follows IEC 60751 (Callendar-Van Dusen, A = 3.9083e-3, B = -5.775e-7,
  C = -4.183e-12): a table of R / R0 every 5 degC (`mtmp/rtd_table.s`, generated by `tools/gen_rtd_table.py`) with linear
  interpolation; the conversion error is at most 0.0074 degC before the rounding to 0.1 degree (checked by the generator
  at every 0.01 ohm of a Pt100). OHM ranges 0..3 are used (Pt100 normally 500.00 ohm, 0.01 ohm = 0.026 degC; Pt1000 normally
  5.0000 kohm, 0.1 ohm = 0.026 degC).
- 2-wire: the lead resistance adds to the sensor (0.1 ohm = about 0.26 degC on a Pt100, 0.026 degC on a Pt1000). REL
  removes it: select the sensor's range with RANGE (REL fixes the range), short the leads, press REL, connect the sensor;
  the view converts the REL reading. With REL in percent (`rEL-P`) the percent view is shown instead.
- How: `ui/rtd.s` replaces the draw of D in `fn_08016E08` like the loop view (2.14); `ui_relpct_mask` lights degC / degF
  instead of %. Logging, MIN/MAX and the BLE frame keep the resistance in counts. Not shown while logging, in the MEM view
  or in calibration mode; HOLD freezes the display; an overload shows OFL.
- Storage: one byte 0x029 (0 = off); a value above 2 reads as 0 (EEPROM_MAP.md 4.1).

## 3. EEPROM bytes the features need

| Offset | Feature | Meaning | Default (0x00) | Word shared with | Status |
|---|---|---|---|---|---|
| 0x00F | 2.8 thermocouple | 0 K, 1 J, 2 T, 3 N, 4 R, 5 S | K | 0x00C..0x00E rotary memory | approved, implemented |
| 0x011 | 2.2 dBm | 0 600 ohm, 1 50 ohm, 2 75 ohm, 3 dBV | 600 ohm | 0x010 temperature unit, 0x012 DIODE flag | approved, implemented |
| 0x013 | 2.4 display | 0 level 1, 1 level 2 | level 1 | as 0x011 | approved, implemented |
| 0x015 | 2.5 BLE | 0 2/s, 1 4/s, 2 10/s, 3 20/s | 2/s | 0x014 continuity code, 0x016 APO | approved, implemented |
| 0x017 | 2.9 backlight | bits 6..0: 0 OFF, 1 30 s, 2..100 1..99 min; bit 7: on/off state | OFF, dark | as 0x015 | approved, implemented |
| 0x020 | 2.3, 2.6, 2.12 | bit 0 REL percent, bits 2..1 log trigger, bit 3 12-hour clock | v2.05 | none (free word 0x020..0x023) | approved, implemented |
| 0x021 | 2.13 continuity | hold code 0..3 (100 / 50 / 25 ms / off = 15 ms) | 100 ms | as 0x020 | approved, implemented (the limits of 2.1 are RAM only) |
| 0x022 | 2.6 | change threshold 1..255 | 1 | as 0x020 | approved, implemented |
| 0x028 | 2.14 loop | view code 0..2 (off / 4..20 / 0..20 mA) | off | none (free word 0x028..0x02B) | approved, implemented (planned for the LO limit of 2.1, which stays RAM only) |
| 0x029 | 2.15 RTD | view code 0..2 (off / Pt100 / Pt1000) | off | as 0x028 | approved, implemented |
| 0x02A..0x02B | - | - | - | as 0x028 | approved, not used |
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
| 26 | `bH` | BEEP mode only | yes (implemented) |
| 27 | `Lt` | always | yes (implemented) |
| 28 | `Lo` | always | capture (implemented) |
| 29 | `HI` | always | capture (implemented) |
| 30 | `tr` (log trigger) | always | yes (implemented) |
| 31 | `Ch` | with `tr-Ch` | yes (implemented) |
| 36 | verdict `PASS`/`HI`/`Lo` | while the limit test is on (shown when it is switched on) | no (implemented) |
| 32 | `n` count | MIN/MAX on | no |
| 33 | `Sd` | MIN/MAX on | no |
| 34, 35 | `tHI`, `tLo` | MIN/MAX on | no |

Items 32..35 are the MIN/MAX pages. v2.05 uses 0..12 and 100; the page dispatcher falls back to item 0 for an unknown item
(`fn_0801797C` end), so each new page needs its own branch before that fallback, as `.Lsd_port` does for items 20 to 25. SETUP short steps
20 -> 21 -> 22 -> 23 (TEMP only) -> 24 -> 26 (BEEP only) -> 25 -> 27 -> 28 -> 29 -> 36 (test on) -> 30 -> 31 (tr-Ch) ->
32 -> 33 (MIN/MAX on) -> 0 (`fn_08015410`); each new page joins that chain.

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
