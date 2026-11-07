# Features of the replacement firmware: user interface, storage, constraints

Status: sections 2.1 to 2.16 (with 2.10a), 2.18 and 2.19 are implemented in the production image (the heading of each names its
IMP number or release; of 2.11, the companion, stages 1 to 7 are implemented on the branch `companion`); section 2.17 is a
design for the production image and is not in the tree as code. The EEPROM bytes of section 3 are approved (owner, 2026-11-02);
each is added to `EEPROM_MAP.md` 4.1 and `nvm_allow` only with the code that uses it. Citations: `KS` = `analysis/keys_setup.md`, `EMAP` =
`EEPROM_MAP.md`, `LCD` = `analysis/lcd_map.md`, `ARS` = `analysis/autorange_and_scheduler.md`, `DES` = `DESIGN.md`.

## 1. Rules that hold for every feature

### 1.1 Production image only

The features are part of the fast build only (branch `main`). The like-v2.05 build (branch `like-v2.05`, `make
LOOP_V205=1` there) contains none of them: it never reads or writes the port-only EEPROM bytes and its `nvm_allow` table
does not allow them (EMAP 4.1). Until 2026-11-04 both builds came from the same sources, with every feature inside
`.if LOOP_V205 == 0`; since then each build has its own branch.

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
that applies, the last page of the chain goes to item 0 (`fn_08015410` in `src/set/setup.s`; the chain is in section 4). The item byte 0x20008037
is read by other modules only for equality with 1, 7, 10, 11, 12 and 100 (DES 6.24), so new item numbers are harmless
there (the numbers in use are in section 4); the BLE packet carries zeros in its sub-display field for them, as for items 3, 4, 8 and 9 (`ble/packet.s`).
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

- Where: SETUP page `rEL`, item 22, after `Ld` (after `Fr` with the two-part bootloader) in every mode; REL short and REL long keep their v2.05 meaning in every mode.
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

- Where: SETUP page `dSP`, item 24, in every mode, after `rEL` (after `tc` in TEMP); in BEEP, DCmA, OHM and CAP `bH`, `LP`, `Pt`
  or `HUnt` follows, otherwise `CL`.
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

### 2.5 Faster Bluetooth streaming (implemented, IMP-09; verified working on a meter)

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
- Constraints: the link is raw serial through the module on USART2; the option is a setting, default v2.05.

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

- Where: SETUP page `tc`, item 23, reached from the page `rEL` in TEMP mode (mode 5) only.
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

### 2.10 Firmware update over Bluetooth (implemented, IMP-28)
- Request (owner, 2026-11-02): update the firmware without taking the SD card out.
- Facts (bootloader `inputs/binaries/bootloader.bin`, base 0x08000000, disassembly): update mode is entered only by the keys at
  reset (GPIOG IDR 0x40021C10 read at 0x0800486C..0x080048B2: MEM PG11 and HOLD PG13 low, then SETUP PG9 low within the wait
  loop 0x080048FE..0x0800490A); no RAM, EEPROM, RTC backup or reset-cause flag is read, so the application cannot start an
  update by itself. The only source is `EEVBlog.bin` on the card root (string 0x08004EF4); no serial port is referenced. The
  bootloader erases 0x08006000..0x0805FF00 (0x08004B8C) before it reads the file, ignores the erase and `f_read` results, and
  checks only the initial stack pointer of the programmed image (0x08004994..0x080049A0): a truncated file is programmed. It
  never writes below 0x08006000, so a bad image is recovered by a good file and the key sequence.
- Measured on a meter (2026-11-03, `bt_rate` test with the key frame of the unused code 0): the Bluetooth module accepts
  writes of up to 244 bytes (MTU 247) and passes them to USART2; with v2.05's frame handling about 600 bytes per second
  arrived (the losses at higher rates were the one-frame-per-pass parser and the 64-byte echo queue, not the radio).
- What it does: on the SETUP page `Ld` (item 39, after `bt`; shown `Ld-bt`) with Bluetooth on, logging off and outside
  calibration mode, the meter takes a file from the sender: packets of up to 232 bytes with a CRC-16, each answered
  (stop and wait, so nothing is in flight while the card is written and the link is deaf, NF-04). The bytes are collected
  in 8 KiB of log_buf and appended to `BTLOAD.TMP`; at the end the meter checks length and CRC-32 against the announced
  values and the first two words (initial SP in the RAM, reset vector Thumb inside 0x08006000..0x08051FFF, `ble/bft.s`), only then
  copies the file to `EEVBlog.bin`, reads the copy back and deletes `BTLOAD.TMP`. The page shows `Ld nn` (percent), `Ld oK` or `LdE n` (1 card,
  2 length/CRC, 3 not an image, 4 copy failed, 5 copy differs). The application writes flash only for the first install of the two-part
  bootloader (2.10a); the update itself is the usual key sequence afterwards.
- Residual risk: a failed copy is repeated from the intact temporary file (3 attempts in all). If every attempt fails,
  an `EEVBlog.bin` that an attempt had opened for writing is deleted (FatFs R0.16, IMP-29) and the page shows `LdE 4` / `LdE 5`: the bootloader
  opens `EEVBlog.bin` before it erases anything (0x08004A8A: f_mount, f_open of the name at 0x08004EF4 with FA_READ;
  a failed open branches to 0x08004982 past the erase and program step 0x080049C2), so with no file the key sequence
  leaves the installed firmware as it is.  Only a power loss while the copy is written leaves an incomplete
  `EEVBlog.bin`, which the bootloader would program if the key sequence is used.  After a checked copy `BTLOAD.TMP` is
  deleted; the card needs free space for the file twice during the transfer.  Recovery as for any bad file: a good
  `EEVBlog.bin` and the key sequence (EEVblog's bootloader is not written by this path).
- How: `ble/bft.s` (protocol in its header), hooks in `ble/usart.s` (the USART2 handler gives every byte to the ring of
  bft.s while the page owns the link; no status frames then), `sys/main.s` (bft_poll every pass) and `set/setup.s`.
- Host side: `emulator/tools/bt_upload.py` (Python, needs the package bleak) with the packet code in
  `emulator/tools/btft.py`; `emulator/scripts/test_bt_upload.py` runs the transfer against the emulated meter and card.
- Verified working on a meter (2026-11-04): the 155 kB production image sent with `bt_upload.py` in 159 s (about
  1060 bytes per second over the link), checked and written as `EEVBlog.bin`.  The way there found an SD driver
  problem (ORIGINAL_FIRMWARE_ISSUES.md OF-59, port correction): reads whose "data end" notification was missed.
- Storage: none (EEPROM untouched).

### 2.10a Two-part bootloader support (implemented, F-1.04; verified working on a meter 2026-11-04/05)
- Facts: `ble/bft.s` (header), `ble/blcmd.s` (header), `nvm/blinst.s`, `bootloader/README.md` and `bootloader/DESIGN.md` on the
  branch `bootloader`.
- First install: the transfer of 2.10 with START kind 1 carries the install file; the meter writes it to flash (only if the
  bootloader area is one of EEVblog's builds and the battery is at least 4.80 V), restarts, and the starter installs the
  bootloader. Errors `LdE 7` (bootloader area not EEVblog's, nothing written), `LdE 8` (battery), `LdE 9` (install file or
  flash step failed).
- Update requests: key code 0x91 of the key frame restarts the meter into the bootloader's update mode, only when the
  two-part bootloader's mark is valid (the request is left in RTC_BKP0R for the bootloader; with EEVblog's bootloader
  nothing happens); key code 0x92 is answered with the bootloader version frame `F7` (`B-` and three digits, or `B-EEV`).
- Verified working on a meter: firmware update into bootloader B-1.11 and bootloader update 1.1.0 to 1.1.1 over Bluetooth.

### 2.11 Meter companion program (stages 1 to 7 implemented, branch companion; owner go 2026-11-04)
- Request (owner, 2026-11-02 and 2026-11-04): the official phone application connects but draws badly; a program of our
  own for Windows, macOS and Linux that shows the meter live, records, and updates the firmware, with a design of its
  own ("sleek, functional, not the run-of-the-mill look").
- Where (owner decision 2026-11-04): a separate program on its own branch `companion` (orphan branch: only the
  companion's code, its own CI, installers and releases tagged `companion-vA.B.C`); the emulator stays on `main`.
  Every package bundles everything it needs (Python, the Bluetooth library, the UI): nothing to install.  What the
  operating system provides is used as it is: the macOS Bluetooth permission prompt, BlueZ on Linux.
- Link (facts, `emulator/tools/bt_upload.py`, working on a meter 2026-11-04): Bluetooth LE service
  0bd51666-e7cb-469b-8e4d-2742f1ba77cc, characteristic e7add780-b042-4876-aae1-112855353cc1 (notify: the meter's
  USART2 bytes; write: bytes to the meter).  The status frame is the 19-byte frame of `analysis/ble_packet.md` 3
  (start 0xF2, XOR checksum); it carries mode, range, value, sub display, bargraph and symbols, no firmware version.
- Stages:
  1. Live view: scan, connect, decode the status frame into the reading as the meter shows it (decimal point and unit
     from the mode and range, the sub display, bargraph, symbols), connection state.  No firmware change.
  2. Recording: CSV file of the decoded readings with time stamps while connected; trend graph; min / max / mean /
     count.  No firmware change.
  3. Firmware version (implemented in F-1.02, IMP-30; emulator test test_ble_version.py; verified working on a meter with the F-1.01 test build): a key frame with the unused code 0x90 (`F4 39 30 39 30`; fn_0800C470
     decodes '9','0' to 0x90, the pairs are equal) is echoed as every key frame and then answered with a version frame
     `F6 c0 c1 c2 c3 c4 x` (FW_VER_C0..C4 of config.inc, x = XOR of the six bytes before it), queued with
     ble_tx_queue_put after the echo.  The answer is made in fn_0800C332 and 0x90 is not handed to the key routine: a
     remote key would restart the backlight countdown and clear a pending SdExx / setup message (keys.s:831-839).
     Host rule: echo and F6 = fast build with that version; echo without F6 within the timeout = v2.05 or the like-v2.05
     build (both echo 0x90, analysis/ble_packet.md 6); neither = the link is not ready (page Ld owns it, the system clock
     is HSE during an SD access, the queue was full) and the host asks again later.  Version characters: one digit each
     (tag vA.B.C = "F-A.BC", checked by check_fw_version.py), so A, B, C stay 0..9.
  4. Update (implemented; verified working on a meter 2026-11-04: F-1.01 to F-1.02 through the companion): when a
     newer fast release exists than the version the meter reports (emu/fetch.py looks it up), the program
     shows it and offers "Update now" or "Later".  Update now = the transfer of 2.10; the user brings the meter to the
     SETUP page Ld and afterwards does the bootloader key sequence: the program never sends key frames for it with EEVblog's
     bootloader (companion-v1.1.0 with the two-part bootloader sends the update-mode request of 2.10a instead; a remote
     SETUP is refused while logging, starts an offset calibration in calibration mode, and the page shown cannot be told
     from the status frame for every item; on Ld remote keys no longer arrive).  Later = remind at the next connection.
  5. Time sync (implemented; verified working on a meter 2026-11-04; owner request 2026-11-04): a button that takes the time from an NTP server (default pool.ntp.org,
     configurable, e.g. the owner's 10.0.10.123) and sends the set-clock frame `F8` with year 0..99, month, day, hour,
     minute, second as plain numbers (the firmware converts them to BCD: rtc_write_reg calls the binary-to-BCD routine,
     rtc/nju6350.s) and their XOR.  IMP-31 (F-1.02): the fast firmware applies every valid frame; v2.05 only the first one
     after the Bluetooth toggle.  Emulator test test_ble_clock.py.
  6. SD card file manager and synced folder (firmware implemented: IMP-36 file requests, IMP-37 settings, emulator tests
     test_bft_files.py / test_bft_settings.py all pass; verified working on a meter 2026-11-05 with F-1.05 and the companion:
     LIST 0.1 s, INFO, a download of 169384 bytes in 163 s (1038 B/s) byte for byte equal to the file written, GET of 19
     settings, PUT of the display level and back with read-back; owner request 2026-11-04; owner chose the synced folder over a drive mount,
     which would need macFUSE / WinFsp / FUSE and is slow for file browsers at about 1 KB/s): list, download, delete and
     rename files, and a "sync" that copies new or changed files of the card into a normal folder on the computer.
     Firmware change (fast build): the transfer protocol of 2.10 gains list / read / delete / rename requests, using
     FatFs R0.16 (f_opendir / f_readdir / f_read / f_unlink / f_rename); only while logging is off and outside
     calibration mode, as 2.10.  Speed about 1 KB/s (measured for 2.10: 155 kB in 159 to 172 s).
  7. Extended link diagnosis (implemented in F-1.15, IMP-44, `ble/xdiag.s`; emulator tests test_xdiag.py and, for the
     overrun fix OF-71, test_ble_overrun.py; companion 1.2.15; the counters verified working on a meter 2026-11-06: the frame F9
     answered with the counters; the overrun that OF-71 clears has not been seen on a meter): a setting of the companion
     ("Extended diagnosis", off by default) makes it send the key codes 0x93 / 0x94 / 0x95 of the key frame (as 0x90 ..
     0x92, `F4 39 33 39 33` and so on; echoed first). 0x93 clears the counters and switches counting on (a RAM flag, 0 at
     every reset, never stored), 0x94 switches it off, 0x95 is answered with the frame `F9` (20 bytes) while counting is
     on. The eight u16 counters (saturating at 65535) are bytes received on USART2, overruns, noise flags and framing
     errors (from the status register of the receive interrupt), bytes discarded while the system clock is the crystal
     (card sessions), rejected key / set-clock frames, page Ld packets answered "CRC wrong", and answers not queued
     because the transmit queue was full; the ninth value is the battery voltage in 0.01 V. They are also the page Ld
     STATUS values 40 .. 48. Purpose: a user's report with damaged data (GitHub issue 9) must show whether the damage
     happens in the meter, on the radio or in the computer. Older firmware ignores the three codes; the companion sends
     them only to F-1.15 or newer.
- Decoding rules (plan review 2026-11-04): the decimal point and unit prefix per mode and range are not in the frame
  (only the range index): taken from the firmware's range tables, not from the official app (they differ for modes 12,
  13, 14, 18, 23, ble_packet.md 8); the magnitude has 18 bits (bytes [5] bits 7..6, [7], [8]); the bar count [14] is
  clamped to 25 (OF-65: 45..55 on an overload); frames arrive split over several notifications and are reassembled by
  start byte, length (F2 19, F4 5, F8 15, F6 7, F7 7, F9 20, bft B5 5B) and checksum, with a resync after a frame abandoned under NF-04;
  no frames come while the main digits are blank and while page Ld is shown.
- Safety of the local program: every request that sends anything to the meter (version request, clock, file operations,
  firmware transfer) needs a custom request header, so no web page can trigger it; one Bluetooth central at a time (not
  together with the phone application or another bridge); reconnect after the meter's auto power-off.
- Packaging: bleak and its platform backends bundled (hidden imports), the macOS Bluetooth usage text in Info.plist.
- Design (owner choice "bench instrument"): matte black, the 121GW yellow as the only accent, hairlines instead of
  boxes, large tabular digits for the reading, oscilloscope-style grid for the trend graph; dense, no rounded cards, no
  shadows, no decorative gradients; system fonts only (works offline).
- Platform notes: the Bluetooth library is bleak (CoreBluetooth on macOS, WinRT on Windows, BlueZ on Linux); the macOS
  application needs the Bluetooth usage text in its Info.plist; only macOS can be tested against a meter here, Windows and
  Linux connections need a tester with Bluetooth there.

### 2.12 12-hour clock (implemented, IMP-13; verified working on a meter)
- Where: SETUP page `CL`, item 25, after `dSP` (after `bH`, `LP`, `Pt` or `HUnt` in their functions), before the limit pages: `CL 24` (v2.05, default) or `CL 12`.
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

### 2.16 Battery voltage trim (implemented, IMP-27)
- Request (GitHub issue 2, 2026-11-03; owner): the battery reading differs from a reference meter by a few percent.
- Facts: since OF-52 the battery value follows the nominal divider (R69 1 M, R70 330 k, 3.300 V reference); part tolerances
  remain and nothing calibrates them: one meter read 5.2 V at 5.0 V (+3 %), another 0.1 V low at 4 to 6 V (-2 %).
- Where: the battery page (SETUP item 1, `BAT5.0`), editable in the production image only (v2.05 refuses the edit). Long
  SETUP: the page shows `bA` and the trimmed voltage in 0.01 V (`bA5.03`); REL +0.2 %, PEAK -0.2 % (stops at +-10 %, no
  wrap); long SETUP saves; SETUP short leaves without saving; the edit timeout re-reads the EEPROM.
- How: `pwr_bat_trim` (pwr/battery.s) scales the filtered value by (1000 + 2 t) / 1000 before the low-battery limit and the
  page, so the 4.1 V limit acts on the trimmed (more accurate) voltage; the reading history stays untrimmed, so a new trim
  shows at the next reading (200 ms).
- Storage: one byte 0x02A = t + 100 (t = -50..+50); any value outside 50..150 (0x00, 0xFF included) means no trim
  (EEPROM_MAP.md 4.1).

### 2.17 Capacitor leakage test (future feature, not started)
- Request (owner, 2026-11-03): a selectable leakage mode that uses the DIODE test source; `LEAK` on the sub display, the
  leakage current on the main digits, RANGE switching between the two source voltages.
- Facts: the DIODE source is not a constant current: 3 V setting 1.4 mA, 15 V setting 7 mA, limited by a nominal 2.2 kOhm
  of PTC and resistors (user manual, 3 March 2025, p. 51 and the specification table). The 15 V setting switches the
  RT9271 boost U10 on (PF6 = ENB high, PE15 low; `brd/frontend.s` from the v2.05 drivers); its output is set by the fixed
  divider R40 47 k / R83 680 and also supplies U9 (HEF4053) through R81, so the firmware can only switch it on or off, not
  set other voltages (`analysis/frontend_netlist.md`, U10 rows). The HY3131 row is the same in both settings.
- Principle: once the capacitor has charged (up to the source current), only the leakage flows; it drops
  I_leak x R_series below the open-circuit voltage, so I_leak = (V_open - V_cap) / R_series. With about 2.2 kOhm and the
  1 mV resolution of the DIODE reading: about 0.45 uA per mV, up to the source current (a leak near 1 mA is plainly bad).
- To measure on a meter before any design: open-circuit voltage at 3 V and 15 V, short-circuit current at both (gives
  R_series), the drift of the boost output over a few minutes (drift reads as leakage), and a 1 MOhm resistor as a known
  leak (about 15 uA at 15 V). The PTC resistance changes with temperature, which bounds the accuracy of the uA scale.
- Limits to document: 15 V overstresses capacitors rated below it; the capacitor stays charged after the test; polarity
  (+ on the VOhm jack); a test at 15 V does not prove a capacitor good at its rated voltage.
- ESR is not measurable on this hardware (the CAP mode gives the firmware only counter times, AD1 is not read there and
  is far too slow for a step), so it is not part of this feature.

### 2.18 exFAT, long file names and card format (implemented, IMP-32, F-1.04; format verified working on a meter 2026-11-04/05)
- Facts: DESIGN.md section 10, IMP-32 (FatFs R0.16 with exFAT and long file names, translated by hand), IMP-33 and IMP-34
  (the SD fixes found on the way, 5 Bluetooth transfers with 0 failed writes and 0 failed card start-ups in 220 start-ups).
- What it does: the meter reads and writes FAT12, FAT16, FAT32 and exFAT cards with long file names. The SETUP page `Fr`
  (item 40, after `Ld`) formats the card as exFAT after a confirmation, only with the two-part bootloader installed:
  EEVblog's bootloader cannot read exFAT, so its card update would stop working. `Fr --` while it works, `Fr oK`; `FrE n` a
  FatFs failure, `FrE L` refused while logging or in calibration mode (`set/fmt.s`).
- Format from the 121GW Companion (IMP-39, F-1.09): on the page `Ld-bt` the companion's CARD view has "Format card"; after
  the user types FORMAT the meter formats the card exactly as the page `Fr` does (request 0x15 of `ble/bftsd.s`, same
  conditions: two-part bootloader, not while a firmware transfer runs).  The meter cannot report progress meanwhile (its
  link is deaf during card work); the companion shows a window whose OK unlocks when the meter answers.
- Card clock (F-1.12, IMP-41, OF-69, OF-70; GitHub issue 5): v2.05 runs every card session on the 4 MHz crystal with the PLL at
  a 48 MHz VCO, where RM0038 6.2 requires 96 MHz for the SDIO; on a meter block writes stopped with a transmit underrun.  Card
  sessions now run on the PLL (VCO 96 MHz, SDIOCLK 48 MHz, the CPU at 32 MHz, our choice) and the clock is raised in steps
  below 4x (OF-70, also at reset).  Verified working on a meter 2026-11-05: three formats of a 32 GB card in 16 s each
  without a failed block (40 s at ClockDiv 4 before), 100 s of logging, the file downloaded over Bluetooth.

### 2.19 Capacitance anti-hunting (implemented, IMP-45, F-1.16; off by default)
- Request (EEVblog forum, firmware thread, 2026-11-06): with a small ceramic capacitor of about 100 nF the CAP auto range
  keeps changing range, the digits stay blank and only the decimal point moves.
- Facts: DESIGN.md section 10, IMP-45. In auto range, range 1 (100 nF) gets no counter result within the no-signal timeout
  (2.5 s since IMP-43), so the timeout jumps to range 2 (1 uF); there the capacitor reads below 1000 counts (below
  0.1000 uF), so the decision steps down to range 1, and so on. Every range change blanks the digits (OF-33). No such
  capacitor has been measured on a meter, so why range 1 gets no result is not proven; the emulator reproduces the behaviour
  with a model setting for a capacitor that cannot be measured in time on a range (`cap_slow_ranges`).
- What it does (CAP, auto range, page `HUnt` on): after two consecutive range-1 timeouts the meter stays on range 2 and
  shows the value as long as the reading is 10.0 to 99.9 nF on range 2 (100..999 counts). It lets go (normal ranging
  again) when the reading changes by more than 20 % (and 50 counts), when a result arrives on range 1, when the range is
  changed by hand (also REL), on a mode change, with the setting off, and at power-off. Open leads (a zero reading) never
  lock. Everything else is unchanged: the up step, the other ranges, the other modes.
- Where: the SETUP page `HUnt` (item 41, CAP mode only, after `dSP`, before `CL`). The four letters leave no room for the
  value on the sub display, so the sub display shows `HUnt` and the main display `on` or `oFF`, as the pages `Sd`, `tHI`
  and `tLo` show their values on the main display. Long SETUP edits (the sub display blinks), REL or PEAK switches, long
  SETUP saves, SETUP short leaves without saving; the edit timeout re-reads the EEPROM.
- How: `mres/antihunt.s` (state in RAM: counted timeouts, lock, reference), hooks in `mres/cap.s` (count, result),
  `ar/arfast.s` (`ar_sample` and `ar_apply`) and `ar/autorange.s`; the page in `set/relp.s`, its main display text in
  `ui/hunt.s`. Storage: EEPROM 0x020 bit 4 (1 = on; an erased byte reads as off). The companion (1.2.16) shows and
  changes it on the METER view.

### 2.20 Run clock measured against the crystal (implemented, IMP-46, F-1.17; verified working on a meter 2026-11-07)
- Reason (GitHub issue 9, 2026-11-07): a user's report shows single damaged bytes on the Bluetooth link, each looking like a
  byte read with the wrong bit timing (not proven). The meter's serial line to its Bluetooth module (19200 baud) runs from
  the processor's RC oscillator (MSI, 4.194304 MHz nominal; +-0.5 % from the factory, +-3 % over temperature, data sheet
  Table 32), and v2.05 computes the baud from the nominal value, so any oscillator error goes into the baud. The same
  error is in the 10 ms tick, the 1 ms tick, the HY3131 bit timing and every delay.
- What it does: at power-on and at every wake from auto power-off the meter counts its RC oscillator against its 4 MHz
  crystal (TIM11 captures the crystal divided by 16; 8.2 ms per measurement), trims the oscillator towards 4.194304 MHz one
  measured step at a time (MSITRIM; a step is kept only if it measured better), and gives the serial line the measured
  frequency, so the baud is within 0.23 % of 19200 on every meter (the step of the baud register). If the crystal does not
  start, no signal comes, or the oscillator is more than 6 % off, nothing changes: the meter works as before. Nothing is
  written to the EEPROM or the flash. Start-up and wake take about 10 ms longer (up to about 0.25 s with a far-off oscillator).
- The result: page `Ld` STATUS 49 .. 55 and the frame FA (key code 0x96); the companion (1.2.18) puts it into the report
  (section "meter clock": the oscillator as found, after the trim, the trim, the baud on the line), with SETTINGS
  "Extended diagnosis" on.
- How: `sys/msical.s`, called from `sys_system_init`; `fn_0801FE2A` (`sys/clock.s`) returns the measured value to
  USART_Init; OF-72 (`ble/usart.s`) fixed with it.

### 2.21 Leave the page Ld from the companion (implemented, IMP-47, F-1.17; verified working on a meter 2026-11-07)
- Reason (owner, 2026-11-07): while the page `Ld-bt` owns the Bluetooth link, keys sent by the companion do not reach the
  meter, so only a SETUP press on the meter gave the readings back.
- What it does: the page Ld takes a request LEAVE (type 0x19): the meter answers and goes to the next SETUP page, as a SETUP
  press does; the readings and the keys work again. The companion (1.2.18) offers it as "Leave Ld-bt" on the CARD view.

### 2.22 Wake from auto power-off with a key, Bluetooth kept (OF-73 fixed, IMP-48, F-1.18; verified working on a meter 2026-11-07)
- After "-oFF-" a key press or a dial turn switches the meter on again (F-1.17 and v2.05: the restart hung, only the dial
  off and on started the meter, OF-73), and Bluetooth comes back on when it was on before the power-off (IMP-48).

### 2.23 Auto power-off time (implemented, IMP-49, F-1.18; verified working on a meter 2026-11-07)
- Request (owner, 2026-11-07): the auto power-off after 1, 15, 30 or 60 minutes instead of always 30.
- What it does: the SETUP page APO steps through `APO.oF`, `APO. 1`, `APO.15`, `APO.30`, `APO.60`; the time is doubled
  while MIN/MAX is on; the warning beeps start 60 s before the power-off (15 s with the 1-minute time). EEPROM 0x016 keeps
  on / off as v2.05 stores it, 0x02B the time (EEPROM_MAP.md 4.1). The companion (1.2.19) shows and changes it.

## 3. EEPROM bytes the features need

| Offset | Feature | Meaning | Default (0x00) | Word shared with | Status |
|---|---|---|---|---|---|
| 0x00F | 2.8 thermocouple | 0 K, 1 J, 2 T, 3 N, 4 R, 5 S | K | 0x00C..0x00E rotary memory | approved, implemented |
| 0x011 | 2.2 dBm | 0 600 ohm, 1 50 ohm, 2 75 ohm, 3 dBV | 600 ohm | 0x010 temperature unit, 0x012 DIODE flag | approved, implemented |
| 0x013 | 2.4 display | 0 level 1, 1 level 2 | level 1 | as 0x011 | approved, implemented |
| 0x015 | 2.5 BLE | 0 2/s, 1 4/s, 2 10/s, 3 20/s | 2/s | 0x014 continuity code, 0x016 APO | approved, implemented |
| 0x017 | 2.9 backlight | bits 6..0: 0 OFF, 1 30 s, 2..100 1..99 min; bit 7: on/off state | OFF, dark | as 0x015 | approved, implemented |
| 0x020 | 2.3, 2.6, 2.12, 2.19 | bit 0 REL percent, bits 2..1 log trigger, bit 3 12-hour clock, bit 4 CAP anti-hunting | v2.05 | none (free word 0x020..0x023) | approved, implemented |
| 0x021 | 2.13 continuity | hold code 0..3 (100 / 50 / 25 ms / off = 15 ms) | 100 ms | as 0x020 | approved, implemented (the limits of 2.1 are RAM only) |
| 0x022 | 2.6 | change threshold 1..255 | 1 | as 0x020 | approved, implemented |
| 0x028 | 2.14 loop | view code 0..2 (off / 4..20 / 0..20 mA) | off | none (free word 0x028..0x02B) | approved, implemented (planned for the LO limit of 2.1, which stays RAM only) |
| 0x029 | 2.15 RTD | view code 0..2 (off / Pt100 / Pt1000) | off | as 0x028 | approved, implemented |
| 0x02A | 2.16 battery | trim t + 100 (t = -50..+50, 0.2 % steps) | no trim | as 0x028 | approved, implemented |
| 0x02B | - | - | - | as 0x028 | approved, not used |
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
| 37 | `LP` 4..20 mA view (after `dSP`) | DCmA mode only | yes (implemented) |
| 38 | `Pt` PT100 / PT1000 view (after `dSP`) | OHM mode only | yes (implemented) |
| 39 | `Ld` firmware over Bluetooth (after `bt`) | always (only the transfer needs Bluetooth on, logging off, not calibration mode) | transfer (implemented) |
| 40 | `Fr` card format (after `Ld`) | only with the two-part bootloader | yes, after a confirmation (implemented) |
| 41 | `HUnt` CAP anti-hunting (after `dSP`) | CAP mode only; name on the sub display, `on` / `oFF` on the main display | yes (implemented) |
| 32 | `n` count | MIN/MAX on | no |
| 33 | `Sd` | MIN/MAX on | no |
| 34, 35 | `tHI`, `tLo` | MIN/MAX on | no |

Items 32..35 are the MIN/MAX pages. v2.05 uses 0..12 and 100; the page dispatcher falls back to item 0 for an unknown item
(`fn_0801797C` end), so each new page needs its own branch before that fallback, as `.Lsd_port` does for items 20 to 25. SETUP short steps
20 -> 21 -> 39 -> 40 (two-part bootloader only) -> 22 -> 23 (TEMP only) -> 24 -> 26 (BEEP only) / 37 (DCmA only) / 38 (OHM only) /
41 (CAP only) -> 25 -> 27 -> 28 -> 29 -> 36 (test on) -> 30 -> 31 (tr-Ch) -> 32 -> 33 -> 34 -> 35 (MIN/MAX on) -> 0 (`fn_08015410`);
each new page joins that chain.

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
