# Issues found in the original 121GW firmware (v2.05)

Reference image: `EEVBlog2_05.bin`, SHA-256 `8f885f12f567c2cccd9862d9fe26f127e2a674c9afbce9f7a38d441b3f396722`
(identical to the official release `EEVBlog2_05.zip`), loaded at 0x08006000.

Every entry is proven from the original machine code; addresses are instruction addresses in that image
and can be checked with any disassembler. "Port" describes what this firmware does instead.
Status: **open** = documented, fix not yet implemented; **approval** = touches calibration/EEPROM
semantics, fix waits for owner approval; **by design** = documented, judged intended, behaviour kept;
**fixed** = implemented and verified in the emulator.

## Summary

| ID | Area | Issue | Severity | Status |
|---|---|---|---|---|
| OF-01 | Table lookup | Stale index used when a table search fails | medium | open |
| OF-02 | Mode setup | Unset register values stored to globals for unhandled cases | medium | open |
| OF-03 | Mode setup | Unset register stored for out-of-range modes (two functions) | low | open |
| OF-04 | Multiplier path | Unset register passed to a float multiply for mode byte > 3 | medium | open |
| OF-05 | Mode helper | Unset register passed on for modes outside the handled set | low | open |
| OF-06 | GPIO set-up | Pin mask left uninitialised for unhandled arguments | high | open |
| OF-07 | Calibration | Calibration save in LowZ and BEEP overwrites the ACV record area, which those modes never load | high | open |
| OF-08 | Calibration | Entering calibration mode clears the six user current-zero records without confirmation or mention in the manual | medium | open |
| OF-09 | Calibration | Current zeroing (long REL) stores only the last increment: a second zeroing is lost at the next mode/range change | medium | open |
| OF-10 | Bluetooth | Packet build and transmit are not synchronised; command echoes can interleave with status frames | medium | open |
| OF-11 | Bluetooth | First frame after enabling BT can carry stale buffer contents | low | open |
| OF-12 | Backup | `cal.bin` does not include the six user current-zero records at EEPROM 0x4D0–0x4FF | medium | open |
| OF-13 | ADC | ADC sample-time register rewritten while the ADC is on, against the reference manual | low | open |
| OF-14 | Measurement | HY3131 AD1 result decoded with the wrong two's-complement offset: negative codes read 1 LSB high, negative full scale reads as positive | low | open |
| OF-15 | Measurement | Rounding to display counts truncates toward zero after adding 0.5: negative readings show one count too little in magnitude | medium | open |
| OF-16 | Measurement | The HY3131 true-RMS result is read, square-rooted and averaged on every RMS interrupt, then never used | low | open |
| OF-17 | Measurement | PEAK and the 1 kHz filter can be on together; the HY3131 then raises no serviced interrupt, the main display goes blank and stays blank | medium | open |
| OF-18 | Measurement | PULSE width is computed from a duty cycle truncated to 0.1 %: shown in 5 digits but quantised to 0.1 % of the period, always rounded down | medium | open |
| OF-19 | Measurement | TEMP re-converts its own previous result on every AD1 sample while MEM view is open; leaving the view shows a wrong temperature | low | open |
| OF-20 | Measurement | BEEP overload limit inherits the OL-hysteresis flag of the previous mode (OL from 541.67 ohm instead of 550.00 ohm) | low | open |
| OF-21 | Measurement | Temperature rounding to 0.1 degree tests the digit after the division: tenths digit 5 is never shown, readings up to 0.1 degree off | low | open |
| OF-22 | Measurement | degC to degF takes the sign from bit 15 and negates with one's complement: up to 0.02 degF error, -40.0 degC shows -39.9 degF | low | open |
| OF-23 | Settings | DIODE 15 V selection is written to EEPROM 0x12 and loaded at boot, then forced back to 3 V | low | open |
| OF-24 | Measurement | Cold-junction conversion silently keeps the previous (or power-on zero) value for board temperatures below -20.0 degC | low | open |
| OF-25 | Measurement | AC+DC: the sum of squares wraps at 2^32, so a large reading is shown as a small one, with no overload and no range change | high | open |
| OF-26 | Measurement | 1 kHz filter: below 20 Hz, or while no frequency has been measured, the reading is ten times too large | medium | open |
| OF-27 | Measurement | VA, mode 15 ranges 2/3 (0x20007FDF = 0): burden table read past the end of its rows; range 3 shows OFL for a valid voltage | medium | open |
| OF-28 | Measurement | One smoothing state shared by two different quantities (AC+DC, burden display, VA): readings are averaged with the other quantity | low | open |
| OF-29 | Measurement | DC VA burden correction depends on the sign: reversing the polarity changes the corrected magnitude | low | open |

## Details

### OF-01 — stale index when a table search fails
`FUN_08007D1E`: the index register r7 is only set when the search hits (`0x08007D5E movs r7,r6`).
When the loop runs out (`0x08007D46 cmp r6,#13` / `0x08007D48 bge 0x08007D66`), execution continues at
`0x08007D6A uxtb r7,r7` and r7 — whatever the caller left in it — is used as the table index.
Impact: reads an arbitrary table entry. Port: explicit "not found" handling.

### OF-02 — unset values stored for unhandled cases
`FUN_0800AEE8`: for `param_2` outside 0..4 and 9 the default path (`0x0800AF0A b.n 0x0800B004`) writes
neither r6 nor r7; case 9 writes r6 only (`0x0800AFEA`). Both are then stored to globals
(`0x0800B00C str r7`, `0x0800B010 strb r6`). Port: defined values on every path.

Further evidence: the case-9 path also runs with param_1 != 0, from the frequency counter (`0x0800AA00` → `frequency_select_range`)
when the counter result is >= 10^9 mHz (1 MHz). That path stores the unset r7 to 0x20007D84, 0x20007E60 and 0x20007E64
(`0x0800B014`..`0x0800B024`) and sets 0x20008047 = 1. `main` (0x08024B40..0x08024DDF) never writes r7 and the start-up
code does not change it (executed from the reset vector to main entry), so r7 is the value present at reset entry,
which this image does not define. Execution check, ACV range 0, 1.2 MHz counter result, input 10000 counts: r7 = 0 → 10000,
r7 = 0x123 → 10249, r7 = 1000000 → -322535; at 90 kHz the result is 9534 for every r7. Impact: above 1 MHz the main AC
reading carries a correction computed from an undefined frequency.

### OF-03 — unset register stored for out-of-range modes
`FUN_0800CEFC` (`0x0800CF16 bhi 0x0800CF22` → `0x0800CF28 strb r7,[r0,r4]`) and `FUN_0800CFB0`
(`0x0800CFD6 b.n 0x0800CFFA` → `0x0800CFFE strb r7,[r0,r4]`): r7 is stored without being set when the
mode is not in the handled ranges. Port: defined value.

### OF-04 — unset multiplier
`FUN_0800A74C`: a mode byte > 3 takes the default branch (`0x0800A75E cmp r0,#3`, `0x0800A762 b.n
0x0800A7BA`), which never writes r4; r4 is then passed to the float multiply (`0x0800A7BA movs r0,r4`,
`0x0800A7BC movs r1,r4`). Port: defined value.

### OF-05 — unset register passed on
`FUN_0801B77A`: modes < 10 or > 17 leave r4 unset (`0x0801B784 bcc 0x0801B7FA`, `0x0801B79C b.n
0x0801B7FA`) before `0x0801B7FA movs r0,r4` passes it to `FUN_08020472`. Port: defined value.

### OF-06 — uninitialised GPIO pin mask
`FUN_0801C2C6` reserves the GPIO init structure on the stack with `push {r2,r3,r4,lr}`. For an argument
that is not 0/1/2/4/8/0x10/0x20/0x40/0x80 the pin-mask word at `[sp]` is never written
(`0x0801C2F2 b.n 0x0801C328`), so the caller's leftover r2 becomes the pin mask read by the GPIO
initialisation (`0x0801BD60 ldr r6,[r1,#0]`). Impact: arbitrary GPIO pins can be reconfigured.
Port: mask always initialised.

### OF-07 — calibration save/load location mismatch (LowZ, BEEP)
The loader (`FUN_0801167C`) reads LowZ from table `T[1]+0x30` (or `T[2]+0x30` depending on a flag)
and BEEP from `T[9]+0x10`, but the writer (`FUN_08011B40`) has no special case for those modes and
writes `T[0]+16·range` (= 0x30, the ACV record area) and `T[10]+16·range` (0x120).
Impact: calibrating in LowZ overwrites ACV calibration; a LowZ/BEEP calibration is not the record that
is later loaded. Port: a calibration save in LowZ or BEEP is refused (refusal beep, no EEPROM write); both modes
keep using the records they already load, so no calibration record can be overwritten from these modes.

### OF-08 — calibration mode erases current-offset records without confirmation
Power-on, then MODE, then REL within the start-up window enters calibration mode and immediately calls
`FUN_0801150E` (`0x0800EAF6`), which rewrites the six records at EEPROM 0x4D0, 0x4D8, 0x4E0, 0x4E8,
0x4F0, 0x4F8 (marker 0xA5 + value 0). There is no confirmation step, and the user manual does not
mention it. The six records are the user current-zero offsets set by a long REL (OF-09), not factory calibration;
they are cleared all at once, even for ranges that are not recalibrated. Port: a record is cleared only when
calibration of its mode and range is performed (before its calibration measurement if that measurement includes
the zero offset).

### OF-09 — current-extra store value
A long REL in modes 16..21 at range 0 stores `0x20007D64` to EEPROM (`FUN_080114BC`, called at
`0x0801645C`) while RAM uses `0x20007D64 + 0x20007E0C`. The loader `current_extra_load` (`FUN_08011448`, called from `0x0800D854` in every mode/range application)
assigns the stored record to 0x20007E0C (`0x0801149E`..`0x080114A6`), it does not add to it. The long REL adds
the reading to RAM (`0x08016436`..`0x08016448`, 0x20007E0C += 0x20007D64) but stores only the increment
(`0x0801644A ldr r2` from 0x20007D64, `0x0801645C bl 0x080114BC`). Execution check (DCuA range 0, EEPROM record
0x4D8): offset 25 counts → long REL → RAM 25, EEPROM A5/25, display 0; offset drifts to 35 → display 10 → long REL →
RAM 35, EEPROM A5/10, display 0; mode/range application → RAM 10, display 25 with the input unchanged.
Impact: after a second zeroing, the next mode or range change loses the earlier part of the zero.
Port: store the accumulated offset (same location and format; approved by the owner).

### OF-10 — unsynchronised Bluetooth packet build/transmit
The status packet buffer at 0x20007AE0 is built in the main loop (`0x08024C0C`) and transmitted from
the TIM2 interrupt and the USART2 TXE interrupt, with no lock between them; command echoes are also
sent from the main loop and can interleave with a status frame. Port: single transmit queue.

### OF-11 — stale first Bluetooth frame
Enabling BT does not force a packet build, so the first frame can carry old buffer contents.
Port: build before the first transmit.

### OF-12 — incomplete calibration backup
`cal.bin` save/load (`FUN_0801CD14` / `FUN_0801CF06`) covers EEPROM 0x000–0x4AF only; the
current-offset records at 0x4D0–0x4FF (read by `FUN_08011448`) are not included. The omitted records are user current-zero offsets (OF-09), not calibration, so leaving them out of a calibration
backup loses them. Port: `cal.bin` also carries the six records; a 1200-byte v2.05 file is still accepted and
then leaves 0x4D0–0x4FF untouched.

### OF-13 — ADC sample time changed while the ADC is enabled
RM0038 (rev. 15) section 12.15.6, ADC_SMPR3: "These bits must be written only when ADON=0."
The channel-configuration routine writes ADC_SMPR3 (0x40012414) at `0x080201F0` while CR2.ADON = 1,
every time the firmware switches between channel 4 (thermistor) and channel 5 (battery sense) via
`FUN_080137B4` (returns at `0x080137EE` / `0x080137FE`); observed 20 times in 4 s of emulated running.
Impact: behaviour outside the manufacturer's specification (the sample time may not take effect
cleanly for the next conversion). Port: configure sample times once with ADON = 0.

### OF-14 — wrong two's-complement decode of the HY3131 AD1 result
The HY3131 AD1 result is a signed 24-bit two's-complement value, 0x7FFFFF maximum and 0x800000 minimum
(HY3131 datasheet, register AD1_DATA). The decode routine at `0x080062F8` assembles the three bytes, then
keeps every code `<= 0x800000` as positive (`0x0800631E cmp.w r2,#0x800000`, `0x08006322 bls`) and
otherwise returns `-(0xFFFFFF - code)` (`0x08006324 mvns r2,#0xff000000` = 0x00FFFFFF,
`0x0800632E subs`, `0x08006332 rsbs`), i.e. `code - 0xFFFFFF`. The correct value is `code - 0x1000000`.
Impact: every negative conversion is 1 LSB too close to zero (on DCV one display count is about 62 LSB,
on DCmV range 0 about 6 LSB, so the error enters the 16-sample mean as a small positive bias on
negative readings), and the negative full-scale code 0x800000 is taken as +8388608.
Port: sign-extend bit 23.

### OF-15 — negative readings rounded the wrong way
`cal_divide_by_gain` (`0x0800F3B8`) converts the gain-scaled float to double (`0x0800F420 bl 0x08013168`),
adds 0.5 (`0x0800F424`/`0x0800F426`: r2:r3 = 0x00000000:0x3FE00000 = 0.5, `bl 0x080131B8`) and converts to
integer with `bl 0x080132A0`. Executing these three helpers from the original image proves the conversion
truncates toward zero: −12344.6 + 0.5 = −12344.1 → **−12344** (correct: −12345); −12344.4 → **−12343**
(correct: −12344); +12344.6 → 12345 (correct). Adding 0.5 and truncating rounds only positive values;
for negative values it shifts every result one count toward zero.
Impact: in the emulator with exact calibration, −1.2345 V displays `-1.2344`, −12.345 mV displays
`-12.344`, −0.5 mV displays `-0.0004`; a real unit with the same calibration shows the same.
Together with OF-14 every negative DC reading is biased toward zero. Port: round half away from zero.

### OF-16 — true-RMS result computed and discarded
On every HY3131 RMS interrupt the handler at `0x08008208` assembles RMS<39:8> (`0x0800827C`), stores
`(int)sqrt(x) << 3` at 0x20007DE0 and a copy at 0x20007D78, and keeps a 4-sample average at 0x20007DE8 with
ready flag 0x20008082 (`0x080082D4`). The per-mode consumers it then calls (`0x0800A5B2`, `0x0800A5BA`,
`0x0800A7F8`, `0x0800A7FA`) are bare `bx lr` returns, and each of the result words has exactly one
literal-pool reference, inside this handler. Dynamic check in the emulator (ACV range 0, PEAK on, 20 s,
375 RMS interrupts, read watchpoints installed before the first instruction): 0x20007DE0/0x20007DE4 are read
only by the handler itself (pcs 0x08008218, 0x08008224, 0x080082EE, 0x08008314); 0x20007D78,
0x20007DE8..0x20007DEB and 0x20008082 are never read.
Impact: about 19 SPI bursts, double-precision square roots and averages per second of wasted CPU time and
SPI traffic in AC modes. Port: do not enable or service the RMS interrupt unless a feature uses it.

### OF-17 — PEAK together with the 1 kHz filter stops all measurement
The PEAK short press (`0x080152B4..0x0801532E`, store of `peak_hold` 0x200080B7) does not test the filter flag
0x200080B9, and the 1 kHz long press (REL, `0x080163C4`) does not test 0x200080B7, so both can be set in ACV/ACmV.
With both set, the row selector `0x0800B994` returns the plain ACV/ACmV row (R29 = 0x01: ENPKH = 0, ENRMS = 0),
while `0x0800BEAC` still writes the peak-mode interrupt enable INTE = 0x11 (RMSIE + CTIE, no AD1IE). RMSF can
never occur (RMS off) and AD1F is not enabled, so `hy3131_service_irq` (`0x0800614E`) is never entered: neither
the AD1 chain nor the peak routine (`0x0800A7FC`) runs, and 0x2000805D (new-value flag) is never set.
Execution check (full emulator, ACV, 3 s after the keys): filter only — INTE 0x05, 217 interrupt services,
218 AD1 decodes, 14 display updates; PEAK only — INTE 0x11, R29 0xC4, 57 services and 57 peak-routine calls;
PEAK + filter (either key order) — INTE 0x11, R29 0x01, **0 services, 0 AD1 decodes, 0 peak calls, 0 display
updates**, while the chip itself completed 1124 AD1 conversions.
Nothing sets 0x2000805D, so `autorange_step` never runs and the settle counter 0x20000238 set at mode
application is never decremented; while it is non-zero `FUN_08016E08` calls `0x08019A98`, which draws five spaces
(string 0x080291B0).
End-to-end check in the emulator (ACV, 0 V input): after the 1 kHz long press the main digits read `0.0000`; 0.2 s after PEAK and still 3 s later only the decimal point of the main display is lit.
Impact: two key presses (PEAK, long REL) in ACV/ACmV leave the main display blank and the meter stops measuring until PEAK or the filter is turned off or the mode is changed. Port: refuse the second key (or define a combined row) so that row and INTE always agree.

### OF-18 — PULSE width quantised to 0.1 % of the period
`FUN_0800B6D4` computes duty = CTC / (T / 1000) with `udiv` (`0x0800B6DC`, `0x0800B6E6`), truncated, in units
of 0.1 % (0x20007E34). `FUN_0800B67C` computes the period P = T·100000 / ((ref / 1000)·CTB) with the 64-bit
divide `0x08014028` (ref = 0x20007E18, divided by 1000 at `0x0800B69C..0x0800B6A2`, i.e. 49152 instead of
49152.05). `0x0800B080..0x0800B0AA` then sets W = P·duty / 1000. The high time CTC that the counter measured
directly is used only through the truncated per-mille duty, so W moves in steps of P/1000 and is always
rounded down.
Execution check (full emulator, PULSE, counter input driven at the stated frequency and duty):
1 kHz 25 % (0.25000 ms) shows 0.2499 ms; 1 kHz 50 % shows 0.4999 ms; 100 Hz 12.3456 % (1.23456 ms) shows
1.2300 ms; 10 Hz 25.03 % (25.030 ms) shows 25.000 ms — a 30-count error on a 5-digit display, the step at 10 Hz
being 100 µs.
Impact: the last one to two displayed digits of pulse width are not real resolution, and exact widths read one
count low. Port: compute the width from the measured counts, W = CTC·10^8 / (ref·CTB) in 0.1 µs, rounded.

### OF-19 — TEMP re-converts a stale result during MEM view
`FUN_08007840` (TEMP handler, called per AD1 sample from `0x080062D4`) converts when 0x2000805D != 0
(`0x08007846`), using x = 0x20007D64 + CJ, and writes the converted temperature back into 0x20007D64
(`0x080078AE`). Only a new 16-sample mean (`0x08007812`) refreshes 0x20007D64 with microvolts, and only the
display routine clears 0x2000805D (`0x08016E0C`). That routine is skipped while MEM view is active
(0x20007FE4 != 0, test at `0x08016D36`), so between means each sample feeds the previous temperature (in
0.1 degC) back in as if it were microvolts.
Execution check (full emulator, TEMP, 35 records logged to an emulated SD card, then MEM view; write
watchpoints on 0x2000805D, 0x20007D64, 0x20007D70): before the view each mean gives 242 (24.2 degC). In view,
0x20007D64 goes 242 → 329 → 350 → 356 → 357 on successive samples (pc 0x080078AE) and returns to 242 at each
mean; the only writer of 0x2000805D in view is `0x0800781A` (= 1). On leaving the view (t = 19.296 s) the
display routine ran immediately and stored **357** in the displayed value 0x20007D70 (`0x08017178`); 242 came
back only at the next mean, 0.26 s later.
Impact: after closing MEM view in TEMP mode the meter shows a wrong temperature (here 35.7 degC instead of 24.2 degC) for up to one mean period.
Port: keep the converted temperature in its own variable; never feed 0x20007D64 back into the conversion.

### OF-20 — BEEP overload limit depends on the previous mode
In `autorange_step` (`0x0800DE24`) the overload limit is FS + FS/12 when 0x200080F8 is set (`0x0800DF72..
0x0800DF8C`) and FS + FS/10 otherwise (`0x0800DF90..0x0800DFA0`); 0x200080F8 is OL hysteresis. Its only writers
(single literal at `0x0800EC14`) are `0x0800DECE` (= 0 while the settle count 0x20000238 runs down),
`0x0800DEF2` (= 0 in cal mode) and `0x0800E262`/`0x0800E26C` (= OL flag 0x20008046) in the range-switching
path. BEEP has settle count 0 and its single-range path never reaches `0x0800E256`, so the flag is never
updated in BEEP.
Execution check: Unicorn, `autorange_step` with mode 10, FS 50000: D = 54167 and 55000 give OL = 1 with
0x200080F8 = 1 and OL = 0 with 0x200080F8 = 0; D = 55001 gives OL either way; 0x200080F8 is left unchanged in
every case. Full emulator: DCV with 1000 V applied set 0x200080F8 = 1; turning the dial to Ohm restored BEEP
(mode 10, settle count 0) and 0x200080F8 stayed 1 for the 6 s observed.
Impact: after an overload in another mode, BEEP shows OL for 541.67–550.00 ohm instead of the value, until a
mode with a settle count is entered. Port: clear the hysteresis flag on every mode apply.

### OF-21 — temperature rounding tests the wrong digit
Main TEMP value (`0x0800788A..0x0800789E`) and board temperature on the sub-display (`FUN_08018AD8`,
`0x08018AF4..0x08018B0C`): r = sdiv(T, 10); then r += 1 if (r − 10·sdiv(r, 10)) >= 5 (`mls`, `cmp r0,#5`). The
rounding decision uses the last digit of the already divided value (the tenths) instead of the discarded
hundredths. Negative values are additionally truncated toward zero.
Execution check (Unicorn, both code paths, degC, T in 0.01 degC): 23.50 → 23.6; 23.49 → 23.4; 25.49 → 25.4;
25.51 → 25.6; 25.74 → 25.8; −23.59 → −23.5 (correct: 23.5, 23.5, 25.5, 25.5, 25.7, −23.6).
Impact: a displayed tenths digit of 5 is impossible for positive temperatures, and readings are off by up to one
count (0.1 degree) on the main display and on the board-temperature sub-display. Port: round on T mod 10, half
away from zero.

### OF-22 — degC to degF sign handling
`FUN_08013B76` decides the sign from bit 15 (`0x08013B7A lsls r0,r4,#16`, `0x08013B7C bpl`) of a 32-bit value
in 0.01 degC, and negates with one's complement (`0x08013B82 mvns`, and `0x08013C34 mvns` on the result).
Positive inputs with bit 15 set (327.68–655.35 and 983.04–1310.71 degC) take the negative path; negative inputs
are converted as |x| − 1.
Execution check (Unicorn, every input in the ranges scanned): 0..32767 — 0 mismatches against exact rounding;
32768..39999, 65000..65535, 98304..98803, 100000..100499, 130572..131071 — every value 0.02 degF high;
65536..66035 and 131072..135000 — 0 mismatches; −20000..−2 — 16355 of 19999 wrong by 0.01–0.02 degF. Through the
TEMP display path (`0x08007870..0x080078B4`, degF): −40.00 degC shows −39.9 degF (−40.0 with an exact
conversion); 327.71 degC shows 622.0 degF (621.9 with an exact conversion).
Impact: in degF, about one reading in six in the affected bands shows one count (0.1 degF) too high or too low.
Port: convert with signed arithmetic on the full 32-bit value.

### OF-23 — DIODE 15 V selection saved but never restored
RANGE in DIODE (`FUN_080159C8`) toggles 0x200080B3 (3 V / 15 V, `0x080159DC`) and saves it to EEPROM 0x12
(`FUN_08011384`). At boot `0x08011358..0x0801135C` loads EEPROM 0x12 into 0x200080B3, then `0x08024E78`
writes 0. `FUN_0800FBE8`, called on every mode apply (`0x0800D594`), also writes 0 (`0x0800FC0A`).
Execution check (full emulator): RANGE in DIODE set 0x200080B3 = 1 and EEPROM 0x12 = 1; HOLD presses kept it;
cycling MODE back to DIODE wrote 0 five times from `0x0800FC0A`; after a power cycle 0x200080B3 = 0 with
EEPROM 0x12 = 1.
Impact: the 15 V choice is lost on every mode change and power-up although the firmware stores it, and every
RANGE press in DIODE costs an EEPROM write that has no effect. Port: either restore the saved value or stop
saving it (owner decision).

### OF-24 — cold-junction value silently stale below −20.0 degC
`FUN_08013CF8` returns without writing the cold-junction value 0x20007E7C when the board temperature is negative
with a >= 201 (0.1 degC units; `0x08013D02 cmp r1,#0xc9`, `0x08013D04 bge`) or above 100.0 degC
(`0x08013D06`), and sets no fault flag. The thermistor table is valid down to ADC average 3672 = −25.00 degC
(`0x08013AAC`), and the EEPROM board offset (±10 degC) is added, so board temperatures from −20.1 degC down to
the table limit plus offset reach this path.
Execution check: Unicorn `adc_ch4_process` (`0x0801385A`), offset +2.05 degC: raw 3600 → −19.43 degC, CJ
−749 µV; raw 3672 → −22.95 degC, CJ left at the preset 12345, 0x200080AF = 0, 0x200080AC = 0; raw 3673 → fault
path (CJ 0, both flags set). Full emulator, TEMP: powered up with PA4 at raw 3650 (board −21.88 degC) CJ stayed 0
with no fault flag and the reading was −2.7 degC, i.e. the thermocouple was evaluated as if the junction were
at 0 degC; after warming to raw 3550 (CJ −661 µV) and cooling back to raw 3650, CJ stuck at −768 µV.
Impact: below the stated operating range (0–50 degC) and partly below the storage range (−20 degC), so low; but
the error is silent and can reach the full cold-junction value (about 22 degC at power-up). Port: extend the
conversion to the thermistor range or raise the existing cold-junction fault.

### OF-25 — AC+DC sum of squares wraps at 2^32
`FUN_0800A6A8` takes |AC| (0x20007E9C) and |DC| (0x20007EA0) and returns 100000 only when one of them is >= 60001
(`0x0800A6E0 movw r1,#0xea61` .. `0x0800A6F4 blt`). Otherwise it forms a·a + b·b with 32-bit `muls`
(`0x0800A70E`, `0x0800A722`) and `adds` (`0x0800A736`), converts the 32-bit result as unsigned
(`0x0800A738 bl 0x08013ED8`), takes the square root (`0x0800A73C bl 0x08013EF4`) and stores the integer to 0x20007D64.
When a² + b² >= 2^32 (combined value >= 65536 counts, both components below 60001) the sum wraps.
Execution check: the function alone gives (50000, 50000) → 26552 (correct 70710), (46341, 46341) → 96 (correct 65536),
(47000, 47000) → 11092 (correct 66468); (30000, 40000) → 50000 and (46340, 46340) → 65534 are correct.
End to end (AC+DC entered by `0x0801472C`, mode set-up `0x0800D2D0`, counter result for 60 Hz through `0x0800AA00`,
AD1 means through `0x080061E4`, alternating AC/DC phases): an AC component of 47000 counts plus a DC component of
47000 counts shows 11092 at every display update in ranges 0, 1 and 2. `autorange_step` (`0x0800DE24`) executed
afterwards leaves the range unchanged and 0x20008046 (overload) = 0; run with the correct value 66468 it moves range 0
up to range 1.
Impact: 4.7 V AC + 4.7 V DC displays 1.1092 V; 47 V AC + 47 V DC displays 11.092 V (true 66.47 V); 470 V AC + 470 V DC
displays 110.92 V. A hazardous voltage is shown as a much smaller one, with no overload or range change.
Port: 64-bit sum of squares; a combined value above the range limit ranges up or shows OFL.

### OF-26 — 1 kHz filter: reading ten times too large below 20 Hz or with no frequency
With the filter on (0x200080B9 = 1, modes 2 and 4) `cal_divide_by_gain` divides by g/10 (`0x0800F3F2`..`0x0800F40C`),
so the count is ten times the unfiltered count. `0x08006D40` is meant to scale it back with a frequency table
(coefficient about 1015/10000 at 20 Hz). For F < 20 Hz it returns the value unchanged (`0x08006D86 cmp r0,#0x14`,
`0x08006D88 bge`, `0x08006D8A movs r0,r6`). F = 0 is the value after a mode application, before the first counter
result. The per-sample path divides the same filtered value by 10 (`0x080084AC movs r1,#0xa`, `0x080084AE sdiv`).
Execution check (mode set-up `0x0800D2D0`, counter through `0x0800AA00`, 12 means through `0x080061E4`, then
`autorange_step` `0x0800DE24`), ACV, unfiltered input 10000 counts: filter off → 10000; filter on with F = 0, 15 Hz or
19.5 Hz → 100000 and the range moves up (r0 → r1, r1 → r2); 20.5 Hz → 10150; 25 Hz → 10200; 60 Hz → 10590.
ACV range 2, input 2300 counts (23.00 V): F = 0 or 10 Hz → 23000 (230.00 V), stays in range 2; 50 Hz → 2396.
ACmV range 1, 2000 counts: F = 0 → 20000, 50 Hz → 2084.
Impact: with the filter on, a signal below 20 Hz, or any signal before a frequency is measured, reads ten times
too high (23 V shown as 230.00 V) or pushes the meter up a range. Port: apply the 1/10 scale on every path.

### OF-27 — VA mode 15 ranges 2/3: burden table read past the end of its rows
The burden correction `0x08008ED0` uses the table fetch `0x08009364` with 7 words per row for mode 15 range 2
(0x080283C4) and range 3 (0x080284C0) when 0x20007FDF = 0, but its voltage column index reaches 7 for V >= 50001,
so column 7 is read from the next row. When the jack code 0x200080CC is not 2 (codes 0 and 3 keep mode 15,
`sense_pe10_pe11` 0x0801417C), the current row index is 8 and the last word read is past the table: for range 3 it is
0x080285BC (value -1894527116), a word that `0x0800BD9A` uses as HY3131 configuration data (literal 0x0800C24C).
Execution check, `0x08008ED0` alone with read tracing, mode 15 range 3, 0x200080CC = 0, I = 5000: V = 50000 → 50108;
V = 50001 → 50109 (reads 0x080285BC); V = 52000 → 7693719; V = 55000 → -2315698. With 0x200080CC = 2: 52000 → 52087;
with 0x20007FDF = 1: 52000 → 52129. Range 2 with 0x200080CC = 0 reads the first word of the next table (0x080284C0).
Whole VA loop (`0x080061E4` per sample, `0x0800DCFC`, `0x08016D34`): ranging to range 3 (sub-range flags 0x200080C6 = 1,
0x200080C7 = 1) and then a voltage of 52000 counts (52.000 V) with 5000 current counts gives 0x20007D7C = 7693719,
voltage overload 0x200080CA = 1, and the main display draws only " OFL " (`0x080199B4`, 6 calls in 600 samples).
With 49000 counts the same loop shows the normal value 49105.
Impact: in VA range 3 a voltage between 50.001 V and 55.000 V, inside the range, is shown as overload; in range 2 the
column-7 correction uses the wrong words. Port: tables with 8 columns or clamp the column index.

### OF-28 — one smoothing state shared by two quantities
`0x0800B754` keeps one history (0x20007DF8, 0x20008085, 0x20007238) and `0x08008344` one history (0x20007CD8, 0x20008084,
0x200070A8); neither selects a state per caller. The history is only restarted when a new value differs from the
last output by more than the threshold. Two different quantities pass through the same state: AC+DC DC phase
(`0x0800B754`(D, 2, 2) from 0x08007714) and AC+DC combined value (`0x0800B754`(D, 20, 10) at `0x0800A65E`);
AC VA voltage (0x08006AB2..0x08006ABA) and current (0x080068C8..0x080068D2) through `0x08008344`(D, 20, 10);
DC VA voltage and current through `0x0800B754`; the current and burden-voltage values of the burden display.
Execution check, AC+DC range 0, DC 20000 counts, 60 Hz: AC 600 → shows 20002 (true 20009); AC 850 → 20006 (true
20018); AC 1000 → 20024 and AC 3000 → 20223 (outside the threshold, correct). Whole VA loop: DCuVA range 0, voltage
10000 and current 10005 counts → current shown 10003; uVA range 0, voltage 10000 and current 10015 → current 10010
and voltage 10064 after the burden correction (10055 in the first cycle, before any current value existed).
Impact: when the two quantities are close, the steady reading is pulled toward the other one by up to about the
threshold (12 counts in the AC+DC example). Port: one state per quantity.

### OF-29 — DC VA burden correction depends on the sign
`0x08008ED0` in mode 24 range 2 computes the correction from |V| and |I| (`0x08008F3A`..`0x08008F6E`). With
0x20007FDF != 0 it is subtracted for negative V (`0x0800929A`..`0x080092AE`); with 0x20007FDF = 0 it is added to the
signed V (`0x080092C2`..`0x080092CE`).
Execution check, `0x08008ED0` alone, mode 24 range 2, 0x20007FDF = 0: (V, I) = (+20000, +3000) → +19931,
(-20000, -3000) → -20069 with 0x200080CC = 2; +19669 / -20331 with 0x200080CC = 0. With 0x20007FDF = 1:
+19939 / -19939 and +19771 / -19771. In ranges 0, 1 and 3 negative V or I gets no correction at all
(+20000 → +19976, -20000 → -20000 in range 0), so a sign difference exists there as well.
Impact: reversing the polarity of the same DC VA measurement changes the shown voltage magnitude, by 138 to 662
counts at 20000 counts (0.7 % to 3.3 %) in range 2. Port: apply the correction to the magnitude and restore the sign.
