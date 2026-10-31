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
| OF-07 | Calibration | LowZ calibration would write the ACV range-0 record, which LowZ never loads (reachable through OF-36); BEEP shares OHM range 1's record 0x120 | medium | open |
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
| OF-30 | Measurement | LowZ shows "0.0" V for 1.1 to 2.4 s each time a voltage appears at the input (100 V, 230 V, 600 V tested), before the real value | high | open |
| OF-31 | Main loop | LCD update busy-wait in every display commit paces the main loop to the LCD frame: AD1 conversions beyond about 72 per second are dropped and the CPU never sleeps while measuring | low | open |
| OF-32 | Display | BEEP and FREQ draw the zeroed value at mode entry: "0.00" ohm with open or connected leads, "0.000" Hz with a signal present | low | open |
| OF-33 | Measurement | CAP timeout range jump draws the old count with the new range's decimal point and the old unit for one display update ("10.000" nF becomes "1.0000" nF) | low | open |
| OF-34 | Bluetooth | Status frames built during a range change report value 0, no overload, in the new range, with no flag that the value is invalid | low | open |
| OF-35 | Logging | Log records store the single per-sample value 0x20007D68, not the averaged value that is displayed | low | open |
| OF-36 | Calibration | A running offset/gain capture is not cancelled by a mode or range change; it completes in the new mode/range and is written to that mode/range's EEPROM record | high | open |
| OF-37 | Calibration | SETUP short in calibration mode continues into the MEM-short code: refusal beep after a started offset capture; in an AC band slot 2 is overwritten from the slot-1 reading | medium | open |
| OF-38 | Settings | Contrast 10 and 11 can be selected and are saved to EEPROM 0x1A, but power-up accepts only 12..17 and replaces them with 14 | low | open |
| OF-39 | ADC | ADC_Init passes an uninitialised stack word that is ORed unmasked into ADC_CR2 (value: core register r6 as left at reset) | low | open |
| OF-40 | Power-down | The TIM2 jack-warning beep can set the buzzer output again after power-down has cleared it (chirp of about 69 ms after the "-oFF-" beep) | low | open |
| OF-41 | Display | Setup page 7 (time): the TIM2 handler converts and draws the time through the same digit globals and text buffer the main loop uses for the reading; the reading shows wrong digits for about 0.22 s | low | open |
| OF-42 | SD card | The disk read routine `FUN_08023F7E` reads one sector whatever sector count the file system asks for; no v2.05 caller asks for more than one | low | open |

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

### OF-07 — LowZ calibration writes the ACV record; BEEP shares OHM range 1's record
LowZ: the loader `FUN_0801167C` reads mode 0 from table[2] + 0x30 = 0x60 (ACV range-3 record) when 0x20008098 != 0
and from table[1] + 0x30 = 0xA0 (DCV range-3 record) otherwise (`0x080117B2`..`0x080117E6`), matching the HY3131 rows
LowZ uses (ACV/DCV row 3, `0x0800BA30`). The writer `FUN_08011B40` has no mode-0 case and writes table[0] + 16 * range
= 0x30 + 16 * range (`0x08011C1C`..`0x08011C4C`; R+4 for the gain, `0x08011CB0`..`0x08011CD8`), i.e. the ACV range-0
record, which LowZ never loads. A calibration cannot be started in LowZ (`FUN_08015728` refuses mode 0,
`0x0801572C`..`0x08015748`; SETUP refused at `0x08014DC6`), so the write happens only when a capture started in another
mode completes after switching to LowZ (OF-36). Execution check: offset capture started in DCV, dial to LowZ ->
EEPROM 0x30 = 0x000019B5 (factory 0x00004D8F); a SETUP press in LowZ gives the refusal beep and writes nothing.
BEEP: writer and loader agree. The writer uses table[10] + 16 * range = 0x120 (range 0), the loader table[9] + 0x10
= 0x120 (`0x0801184A`..`0x08011866`). 0x120 is also OHM range 1's record (table[9] + 16), so a BEEP calibration
replaces the OHM range-1 calibration and the reverse. The two HY3131 rows differ only in byte 2 (BEEP 0x08029150:
0x10, OHM range 1 0x080285D0: 0x13). Execution check: BEEP and OHM range 1 both read 0x120/0x124 at apply; a BEEP
offset calibration (0 ohm) writes 0x120 = 0x00000147, the value already stored for OHM range 1. Whether the sharing is
intended is not shown by the code.
Impact: ACV range-0 calibration can be overwritten from LowZ (through OF-36). Recalibrating BEEP or OHM range 1 also
changes the other.
Port: calibration saves in LowZ and in BEEP are refused (refusal beep, no EEPROM write); both keep using the
records they load. BEEP is refused because it runs a different HY3131 row (byte 2 0x10 instead of 0x13) yet would
overwrite OHM range 1's record; OHM range 1 is calibrated in OHM. OF-36 (capture cancelled on a mode or range change)
closes the LowZ path.

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

### OF-30 — LowZ shows "0.0" V while a voltage is present
`0x08006558` (called from `main` at `0x08024B86` in mode 0) takes threshold 100 counts (10.0 V) when 0x20008099 = 0
and 30 counts when it is 1 (`0x08006564`, `0x0800656A`). For |D| above the threshold or overload, while 0x20008099 = 0,
it stores 0 to the displayed value 0x20007D64 (`0x080065FA movs r0,#0`, `0x08006600 str`) and counts 0x2000023A down;
only when that counter reaches 0 (fifth such mean) is 0x20008099 set (`0x0800661A`..`0x08006620`). Every mean within
the threshold reloads 0x2000023A = 5 and clears 0x20008099 (`0x08006594`..`0x080065A2`), and every fifth one toggles
the AC/DC state 0x20008098 and re-applies the mode (`0x080065C4`..`0x080065E6`, `bl 0x0800D2D0`), which loads settle
counter 5 (DC) or 3 (AC) (`FUN_0800DB48`). Mode 0 is exempt from the settle blank (`0x08016FE2`..`0x08016FEA`, cmp of
0x2000803C), so the forced 0 is drawn as a value ("   0.0", annunciators LowZ and V, no AC/DC annunciator). The
apply also zeroes 0x20007D64 (`0x0800D57C`).
Execution check (main digits and all LCD annunciators sampled every 5 ms; write trace of 0x20007D64): dial V -> LowZ
with 100 V DC present: "0.0" from 0.114 s to 1.400 s after the dial change (1.29 s), five zero stores by `0x08006600`
at 0.284..1.152 s, each right after the mean wrote 1000; HV symbol at 0.960 s; bargraph moves at 0.309 s. With
230 V AC 50 Hz present: "0.0" from 0.114 s to 2.247 s (2.13 s; DC state first, toggle to AC at 0.887 s, re-apply);
HV symbol at 1.583 s. Power-on in LowZ with 100 V DC / 230 V AC / 600 V DC: "0.0" for at least 0.9 s, HV symbol
0.85 s / 1.46 s / 0.85 s after the first "0.0". Meter already in LowZ at 0 V (it cycles DC/AC and re-applies every
5..7 means), voltage then applied at 12 different phases each: 230 V AC: "0.0" for 1.15..2.24 s; 100 V DC:
1.17..1.70 s; -100 V DC: 1.14..1.72 s; 24 V AC: 1.15..2.38 s (no HV symbol). The HV symbol appeared before the digits
in every trial with 100 V or more. 8.0 V DC is shown as "0.0" indefinitely; 11.0 V DC is shown after the same delay.
Impact: in the mode used to check whether a conductor is live, the main display reads "0.0 V" for 1.1 to 2.4 s after
the probes touch 100..600 V; until the HV symbol appears (up to 1.58 s in the trials) nothing but the bargraph
indicates the voltage. A user who reads the digits early can take a live conductor for dead. The times are firmware
times on an ideal front end; real settling can only lengthen them. The dead band below about 10 V (reading 0.0) is
covered by the manual's "not designed to be operated at low voltages (below 12V)" and is not part of this issue.
Port: while the LowZ detector has not confirmed a voltage, blank the main digits (or show dashes) instead of a
numeric 0.0.

### OF-31 — main loop paced by the LCD update busy-wait
`lcd_commit_shadow` (`0x0801B304`) waits before every RAM write until LCD_SR.UDR clears: `0x0801B336 movs r0,#4`,
`0x0801B338 bl 0x08020492`, `0x0801B33E bne 0x0801B336`; `0x08020492` reads LCD_SR (literal `0x080204B8` =
0x40002408) and tests the mask in r0 (bit 2 = UDR, RM0038 16.5.3). UDR is cleared by hardware only at the next frame,
so each commit after a previous commit blocks for up to one LCD frame. The only path that skips the wait is
`0x0801B326 beq` / `0x0801B328 bl 0x0801B396` (partial commit), taken when 0x20007FE1 is clear, 0x20008053 is clear
and auto-hold stage 2 (0x20008050) is set. LCD clock: `0x0801BFBC movs.w r0,#0x20000`, `0x0801BFC0 bl 0x0801FF34`
writes RCC_CSR.RTCSEL = 10 (LSI). The only WFI/WFE in the image (`0x080207F2` wfi, `0x080207F6` wfe, also no 32-bit
encodings) are in the STOP entry `0x080207CC` with SCR.SLEEPDEEP set (`0x080207E4`), called only from
`enter_stop_and_reinit` (`0x08024EE4`), which `main` reaches only when 0x2000803A is set (`0x08024DD0`..`0x08024DDA`).
Execution check (hooks at `0x08024B6A` poll call, `0x0801B304`, `0x0801B32E`..`0x0801B340` wait, `0x0800614E` HY3131
service; 2 s each, frame 72.27 Hz for FCR 0x00C05440 with LSI 37 kHz): BEEP 10 ohm: 72.5 commits/s, 665 ms/s inside
the wait, 72.5 HY3131 services/s for 641.5 AD1 conversions/s (89 % dropped), median main pass 13.84 ms. OHM 1 kohm:
72.0 services/s for 320.5 conversions/s, 679 ms/s waiting. DCV 1 V: 71.0 commits/s, 597 ms/s waiting, 69.5 services/s
for 77.0 conversions/s (10 % dropped). No partial commit occurred in these runs.
Impact: the 16-sample mean takes 16 x 13.84 = 221 ms on every configuration row faster than the frame rate (BEEP row:
25 ms possible), so update rate, range-change time and continuity digit response are set by the LCD frame, not by the
HY3131. 60 to 68 % of the active time is spent spinning instead of sleeping. Displayed values are not wrong: dropped
conversions are simply not averaged. The frame rate depends on the LSI frequency, which the STM32L151 datasheet
(Table 31) specifies as 26 to 56 kHz (typ 38 kHz), i.e. 51 to 109 Hz frame rate with this FCR value; the 72 Hz
figure is the emulator's nominal 37 kHz and differs from meter to meter. This is a throughput, latency and power
issue, not a measurement error.
Port: LCD commit without the UDR busy-wait (write only when UDR is clear, otherwise retry on the next pass), WFI at
the end of each pass, woken by the interrupts v2.05 already enables.

### OF-32 — BEEP and FREQ draw the zeroed value at mode entry
`FUN_0800DB48` loads settle counter 0x20000238 = 0 for BEEP (`0x0800DC1E cmp r0,#0xa` .. `0x0800DC28 strb`) and for
FREQ/PULSE/DUTY (`0x0800DBC6`..`0x0800DBDA`, value 0), and the apply zeroes 0x20007D64 (`0x0800D57C`), 0x20007D68
(`0x0800D584`) and 0x20007D70 (`0x0800D31E`). With the counter 0 and 0x2000805C clear the blank branch
(`0x08016FCE`..`0x08016FE0`) is not taken and the display draws 0x20007D64 = 0 until the first result.
Execution check: OHM -> BEEP (MODE) with 100 ohm: "  0.00" ohm from 0.082 s to 0.290 s after the key release, then
"100.00"; with open leads: "  0.00" from 0.054 s to 0.261 s, then " OFL"; the buzzer stayed off in both runs.
DCV -> Hz (dial) with 1 kHz: " 0.000" Hz from 0.119 s to 0.561 s, then "1.0000" kHz. With no signal "0.000" Hz is
the correct final reading.
Impact: for about 0.2 s (BEEP) and 0.44 s (FREQ) a valid-looking reading of zero is shown; in BEEP open leads briefly
read as a short. Cosmetic; no false continuity tone. Times are firmware times (lower bound).
Port: blank until the first result after an apply.

### OF-33 — CAP timeout jump draws the old count in the new range
The CAP counter timeout `FUN_0800B540` (called from `hy3131_poll`, `0x08006148`) in auto range sets 0x2000803D to 2
or 5 (`0x0800B5AE`, `0x0800B5C0`), 0x2000804A = 0 and 0x2000804B = 1 (`0x0800B5D8`); it does not set 0x2000805C.
The display stage of the same pass therefore draws the old 0x20007D64 with the new range's decimal point before
`meter_apply_mode_range` zeroes it (`0x0800D57C`).
Execution check (LCD sampled every 2 ms): 10 nF -> 10 uF: range 0 -> 2 at 1.514 s, LCD "1.0000" with the nF
annunciator from 1.526 s to 1.539 s, then blank with the uF annunciator, final " 9.999" uF at 2.923 s.
10 nF -> 1 mF: "1.0000" nF from 2.006 s to 2.034 s. 0x20007D70 (BLE value) was already 0 in that window.
Impact: one wrong reading (count 10 000 shown as 1.0000 nF instead of 10.000 nF) visible for one or two LCD frames
(13..28 ms). Cosmetic.
Port: set the display-blank flag on the timeout jump, as `autorange_step` does.

### OF-34 — Bluetooth frames report 0 during a range change
`meter_apply_mode_range` stores 0 to 0x20007D70 (`0x0800D318 movs r0,#0`, `0x0800D31E str`); the frame builder
(`0x0800C5DA`, built 10 TIM2 ticks before each 50-tick transmit) takes bytes 7..8 and the two top bits of byte 5 from
|0x20007D70| and byte 6 from 0x2000803D (range) and 0x20008048 (overload) (`0x0800C5E8`..`0x0800C6A8`). No byte
carries the settle counter 0x20000238 or the blank flag 0x2000805C, so a receiver cannot tell the zero from a reading.
Execution check (USART2 output decoded, BT on by long PEAK): DCV 0.1 V -> 500 V: frames at 0.432 s (mode 1, range 1,
value 0, ovl 0) and 0.934 s (range 2, value 0) while the LCD was blank, then 50000 from 1.437 s. 500 V -> 0.1 V:
frame at 0.940 s (range 0, value 0), then 1000.
Impact: a logging app records 0 V (in the new range) for every frame that falls inside a range change (DCV about
0.47 s per change, one frame every 0.501 s). Not every change produces such a frame.
Port: mark frames built while the display is blank, or repeat the last valid value.

### OF-35 — log records hold the per-sample value
`FUN_08010908` (called from `log_compose_mode_range` `0x080105D2`) stores to the record value 0x20007D28 the
per-sample value 0x20007D68 (`0x080109B2`, `0x080109CC`, `0x080109DC`) in all modes except 5, 6, 7, 8, 9 and 12, which
use the displayed mean 0x20007D64 (`0x0801097A`..`0x080109A4`). 0x20007D68 is written on every AD1 sample
(`0x080064D6`, hy3131_modes_misc.md). The record is copied by `FUN_0801217C` (reads 0x20007D28 at `0x080121CC`).
Execution check (SD image attached, logging started by long MEM, noise on, seed 3, hook at `0x0801217C`): DCV 1 V,
display steady "1.0000": logged 9999, 10000 and 10001. Step 1 V -> 4 V: the record at +0.17 s holds 39999 while the
display shows the mixed mean "1.9375".
Impact: the stored reading is one unaveraged sample (for uncorrelated noise, four times the noise of the 16-sample
mean shown on the display) and can differ from what was on the display at that moment. This may be
intended; it is recorded because the log does not say so. Range changes do not occur during normal logging: starting
a log saves and forces range_manual (0x20008043 = 0x20008042, 0x20008042 = 1 at `0x08010A1A`..`0x08010A2C`, skipped
only with auto-hold stage 2 set); execution confirmed "auto" goes off and a 40 V step in DCV range 0 is logged as OL
(0x7FFFFFFF, flags 0xA0).
Port: log the displayed (averaged) value.

### OF-36 — calibration capture completes in the mode/range that is active at its end
`FUN_08015768` sets 0x2000808C (offset) or 0x2000808E (gain) and the countdown 0x20008095; a mode or range change
(cal-mode RANGE `FUN_08014796`, MODE, dial, then `meter_apply_mode_range`) leaves them set (execution check below).
Each measurement path that runs with a flag set adds its own mean and, at 0, writes through `cal_record_write`
(`0x08011B40`) to table[mode] + 16 * range of the mode/range current at that moment (DC offset: `FUN_0800EF44`,
`0x0800F01A`). The start refusals of `FUN_08015728` (modes 0, 7, 8; 6, 11, 12 above range 1) are not applied at
completion.
Execution check (calibration mode, offset capture started by SETUP in DCV range 0 with 0 V, change made at count
12..9): RANGE -> completes in DCV range 1, writes 0x80..0x83 = 0x0000010E (270; a capture made entirely in range 1
gives 0x163 = 355, the factory value). Dial to LowZ -> completes in mode 0 (whose own start is refused), writes the ACV
range-0 offset 0x30 = 0x000019B5 (factory 0x00004D8F). Dial to mV -> DCmV range 0 offset 0xB0 = 0xFFFFFE82 (factory
0xFFFFFDAC). Dial to BEEP -> 0x120 = 0x0000001A (factory 0x147; 0x120 is also the OHM range-1 record). MODE to ACV ->
completes in the AC offset path: "OFF-E" shown, RAM 0x20007E08 only. Dial to Hz -> the capture never completes and
"-O-11" stays on the display. After the DCmV case, normal power-up with the front end kept at factory calibration:
DCmV range 0 reads "-0.034" mV at 0 mV and "9.965" mV at 10 mV (factory record: "0.000", "10.000").
Impact: a range or mode change during the about 4 s of a capture silently stores a mixed or foreign mean as the
calibration of another mode or range, including ones the firmware refuses to calibrate directly; the error appears
in normal use (shown: 34 counts in DCmV range 0). Only calibration mode is affected.
Port: switch `CAL_CANCEL_ON_MODE_CHANGE` (default 1: a mode or range apply cancels a pending capture with the refusal
beep) (NF-08).

### OF-37 — SETUP short in calibration mode falls into the MEM-short code
In the SETUP short branch (`0x08014D66`), calibration mode calls `FUN_08015728(0)` and `FUN_08015768(0)`
(`0x08014DCE`); only a return of 2 ends the branch (`0x08014DD6`, refusal beep). Any other result branches to the
MEM-short case (`0x08014DD4 bne 0x08014DEE`, also the target of `0x08014C56`). There, with the power-on window over and
calibration mode set: if 0x2000808C | 0x2000808E != 0 the refusal beep `FUN_0800EE6C` is called (`0x08014E40` ->
`0x08014E68`), which is the normal outcome right after a started offset capture (808C = 1). If `FUN_08015768(0)`
returned 1 (AC band reading: `FUN_0800F13C` set 0x2000809C and started no capture), the MEM code calls
`FUN_08015728(1)` and `FUN_08015768(1)` (`0x08014E44`, `0x08014E54`), which sets 0x2000809D for the same reading;
`FUN_08007532` then writes slot 1 (R'+8, D-5000) and slot 2 (R'+0xA, D-50000) through `FUN_0800F8E4`, slot 2 clamped
to 0 outside -20000..20000 (`FUN_080119F4`).
Execution check: DCV range 0, 0 V, beeper on: SETUP -> 808C = 1, refusal beep called from `0x08014E68`
(two 49 ms PE7 pulses at 0.19 s and 0.29 s; a REL short gives the accept beep, one 99 ms pulse); the capture still
counts down "-O-16".."-O-01", shows "OFF-E" and writes EEPROM 0x70..0x73. ACV range 2, 50.50 V at 10 kHz, EEPROM
0x58..0x5B preset to 0064 012C: one SETUP press -> 0x2000809C = 0x2000809D = 1, `FUN_0800F8E4(1, 5050)` and
`FUN_0800F8E4(2, 5050)`, EEPROM 0x58 = 0x0032 (slot 1) and 0x5A = 0x0000 (slot 2, was 0x012C); accept beeps from
`0x08014E62` and after each slot write.
Impact: a technician hears the error pattern for a correct offset start; re-calibrating only slot 1 of an AC band
(ACV/ACmV, ACuA/ACmA range 1) destroys the slot-2 correction unless the MEM step is repeated afterwards.
Port: switch `CAL_FIX_SETUP_FALLTHROUGH` (default 1: SETUP ends after its own action with the accept beep) (NF-07).

### OF-38 — contrast 10 and 11 saved but not restored at power-up
The setup editor `FUN_08015B54` (item 4 "Lcd-n") steps the contrast byte 0x20000237 up with wrap 17 -> 10
(`0x08015B64 cmp r0,#0x11`, `0x08015B68 movs r0,#0xa`) and down with wrap 10 -> 17 (`0x08015B8E cmp r0,#0xa`,
`0x08015B92 movs r0,#0x11`), applies it live (`0x08015BBE bl lcd_init`) and saves it with the long SETUP
(`0x08015BB2 bl 0x08011294` -> EEPROM 0x1A). The power-up loader `FUN_08011258` keeps the EEPROM value only for
12..17 (`0x08011264 cmp r4,#0xc` / `blt`, `0x0801126A cmp r4,#0x12` / `bge`) and otherwise stores 14
(`0x08011276 movs r0,#0xe`, `0x0801127C strb`).
Execution check (EEPROM 0x1A = 15 initially; long SETUP, REL steps, long SETUP, then power cycle): saved 10 -> EEPROM
0x1A = 10, LCD_FCR CC = 0 before the power cycle; after it 0x20000237 = 14, CC = 4, page shows "Lcd-4". Saved 11 ->
EEPROM 11, after power-up 14. Saved 12 -> after power-up 12 (control).
Impact: the two faintest contrast settings offered by the editor last only until the next power-up; the EEPROM keeps
10/11 while the display uses 14, without any indication. The code does not show whether the boot limit is meant as a
recovery from an unreadably faint setting.
Port: switch `SET_ACCEPT_CONTRAST_10_11` (default 0 keeps the v2.05 behaviour; 1 restores 10 and 11) (NF-17).

### OF-39 — uninitialised word ORed into ADC_CR2
`FUN_08013DD4` builds the ADC_InitTypeDef on the stack (`sub sp,#0x1c`) and writes [sp+0], [sp+4], [sp+5], [sp+0xC],
[sp+0x10] and [sp+0x14] (`0x08013DE0`..`0x08013DF8`), never the 32-bit field at [sp+8] (ExternalTrigConvEdge).
`FUN_080200B4` reads it without a mask and ORs it into CR2 (`0x080200DC ldr r5,[r1,#8]`, `0x080200DE orrs`,
`0x080200E8 str r3,[r0,#8]`); the mask `0xC0FFF7FD` at `0x080200D2` only clears old CR2 bits. The slot was last
written by the `push {r4-r7}` of `gpio_init` (`0x0801BD48`) called from `gpio_init_analog` (`0x0801C480`, also
`0x0801C45E`), so it holds r6 of the caller. Both callers of the init chain (`main` `0x08024B4E`, wake
`0x08024EEE`) run with the r6 that `main` received: `main` (0x08024B40..0x08024DDF) never writes r6, and the bootloader
and the C start-up (`cmain` 0x0802910C) leave it as at reset. PM0056 Table 2 gives R0..R12 the reset value "unknown".
Later CR2 accesses are read-modify-write only (`0x0802010A`/`0x08020114` ADON, `0x080202EA` SWSTART), so the bits
stay for the whole session and are ORed in again at every wake.
Execution check: core registers set to 0xA5A5000n before the reset vector: [sp+8] = 0xA5A50006 at `0x080200DC` and
CR2 written 0xA5A50006 (boot; random RAM fill does not change it, r6 = 0 gives CR2 = 0, which is the emulator's normal
case, as at the wake call). r6 = 0x00000800 (CR2.ALIGN): ADC results left-aligned; setup page 1 shows battery "9.9"
instead of "5.9" (0x20007FBA = 105 instead of 59) and page 0 the board temperature "0.0" instead of "27.0".
r6 = 0x2, 0x4, 0x10, 0x20 or 0x30000000 (CONT, CFG, DELS, EXTEN) gave no visible change in the emulator.
r6 = 0xFFFFFFFF behaves as ALIGN.
Impact: latent; correct whenever the CPU starts with r6 bit 11 clear. If it is set, the battery voltage (low-battery
indication) and the board temperature (cold junction) are wrong until a power-on that starts with a different r6.
Reserved CR2 bits (31, 23, 15:12, 7, 3) can also be written, against RM0038.
Port: the field is initialised to 0 (software trigger, as used via SWSTART `0x080202EA`) (NF-01).

### OF-40 — TIM2 jack-warning beep re-arms the buzzer during power-down
`enter_stop_and_reinit` (`0x08024ECA`) ends the 1 s "-oFF-" beep with PE7 low (`0x08024F34`), then
`power_down_peripherals` sets PE7 low again (`0x0801C58C`), but TIM2 and TIM3 keep running until `0x0801C92E`
(`0x0801C936` TIM2 CEN = 0, `0x0801C94E` TIM3 clock off), called after it at `0x0801C528`. No `cpsid` exists in the
image. In that window the TIM2 handler's 50-tick block (counter 0x20007F04, `0x0802461C`) calls
`pe7_on_with_timeout(500)` (`0x0802469A`..`0x0802469E`, sets PE7 at `0x0800EEE4`) when 0x20008077 toggles to 1 and
0x20008076 | 0x200080B2 != 0 (jack warning). The window lasts from `0x0801C58C` to the next LCD frame boundary
(LCD disable wait in `FUN_0801C908`), 4.5 to 13.9 ms in the runs; the TIM2 period is 10.02 ms and the window starts
right after a tick, so only windows above 10.02 ms can contain one. PE7 is not left high into STOP: `0x0801CA22`
sets all GPIOE pins to analog before the `wfe` (`0x080207F6`). The TIM3 repeat path (`0x080247D4`) needs a repeat
count 0x2000807A pending at power-down; its only writer `FUN_0800EE7A` reloads the APO counter (`0x0800EE88`
`bl 0x0800ED26`), and it was not reproduced.
Execution check (DCV, plug in the A jack -> " LEAd" and the 0.5 s on / 0.5 s off warning; APO request 0x2000803A set
from a write hook on 0x20007F04 to choose the TIM2 phase, which in use drifts freely against the RTC second that
triggers APO; 73 runs): window above 10.02 ms in 37 runs; with the jack-warning tick inside the window (2 runs):
PE7 set by the TIM2 handler (pc `0x0800EEE4`, IPSR 44) 10.02 ms after `0x0801C58C`, TIM2 stopped at 12.17 ms, PE7 high
until its pin went analog at 79.2 ms. In the other runs, and in 40 runs with the APO countdown itself as trigger, PE7 stayed low from `0x0801C58C` until
the pins went analog.
Impact: occasionally, with a lead in a current jack at auto power-off, a second buzzer chirp of about 69 ms follows
the power-off beep. Whether the sounder is still powered at that moment (PE9 is cleared at `0x0801C618`, about the
time the timers stop) is not known from the documents.
Port: TIM2 and TIM3 update interrupts are disabled before the buzzer state is cleared and PE7 set low (HW-08).

### OF-41 — time page drawn from the TIM2 handler through the main loop's digit buffers
When setup item 0x20008037 = 7, the TIM2 handler's 50-tick block toggles 0x200080D5 and calls `FUN_0801896C(1)`
(`0x080246D2`..`0x080246FC`) -> `FUN_080188A0`, which converts the time with `FUN_0801B090` (digit globals
0x20007DB0..0x20007DC0), writes the text buffer 0x20007C30 and draws it (`0x08018942 bl 0x08019AE0`) and commits
(`0x08018954 bl 0x0801B304`). The main loop draws the reading with the same routine and buffers
(`lcd_show_value_pos5_9` `0x08017100`: `0x08017156 bl 0x0801B090`, `0x0801715E bl 0x0801B130`, `0x08017168 bl
0x08019AE0`) without masking interrupts. A TIM2 tick between `0x08017156` and the draw makes main draw the time digits
or a mixture into the reading.
Execution check (DCV 1.2345 V, setup page 7; to bring the two events together the 0.5 s counter 0x20007F04 was preset
to 49 at each `0x08017156`, which in use meet at random; 90 s): 6 nested calls, 5 visible: main display "1.2-28",
"1.2 28", "1.2348", "1.1 29" (and one frame "1.23?5"), each for 16 LCD frames (about 0.22 s), then "1.2345" again.
Without the preset (20 s, 40 handler draws, 88 main draws of about 160 us) no overlap occurred.
Impact: on the time setup page the main reading can briefly show wrong digits (estimated from the measured window:
about 4.4 draws/s x 160 us, i.e. roughly 0.07 % of the half-second ticks). Cosmetic, transient.
Port: the handler only sets a request; main draws the page (NF-11).

### OF-42 — disk read ignores the sector count
`FUN_08023F7E` (disk_read, FatFs `disk_read(drv, buff, sector, count)`) moves its fourth argument into r6 at `0x08023F8A`
and never uses it again (`0x08023F8C`..`0x08023FB4`): it issues one block read (`FUN_08022FCE`, CMD16 + CMD17 for
`sector << 9`), polls the card state (`FUN_0802268A`, at most 0x4E20 times) and returns 0 or 2, whatever the count.
The FatFs read routine `FUN_08021D72` (f_read) passes a count above 1 when the caller's request holds whole sectors:
`0x08021E4E` r8 = bytes >> 9, clamped to the sectors left in the cluster (`0x08021E58`..`0x08021E72`), passed in r3 at
`0x08021E74`..`0x08021E80`. With such a count only the first sector arrives; f_read then advances its file pointer
and its destination by 0x200 x count (`0x08021EBE`..`0x08021EC6`, then the loop tail `0x08021F48`), so the rest of the caller's buffer keeps its old content and the call reports
success.
Not visible in v2.05: every other caller passes 1 (`0x08020C4A`, `0x080216B8`, `0x08021A76`, `0x08021EFE`,
`0x08022106`, `0x080223EC`), and the f_read callers ask for at most 0x200 bytes (cal.bin loop `0x0801CDC2`, `0x0801CE26`,
`0x0801CF56`, `0x0801CFAC` and the remainders `0x0801CE94`, `0x0801D00C`; log verification `0x0801F706`..`0x0801F71E`).
Impact: none in v2.05; a future caller reading 1024 bytes or more in one f_read from a sector-aligned position would
get one correct sector and stale data after it.
Port: `disk_read` reads `count` sectors in turn (CMD16 + CMD17 + status poll each, as `disk_write` writes them) and stops at the
first failure; with count 1 it is the v2.05 routine (deviation OF-42, module SD).
