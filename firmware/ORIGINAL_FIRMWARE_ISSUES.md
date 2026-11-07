# Issues found in the original 121GW firmware (v2.05)

Reference image: `EEVBlog2_05.bin`, SHA-256 `8f885f12f567c2cccd9862d9fe26f127e2a674c9afbce9f7a38d441b3f396722`
(identical to the official release `EEVBlog2_05.zip`), loaded at 0x08006000.

Every entry is proven from the original machine code; addresses are instruction addresses in that image
and can be checked with any disassembler. "Port" describes what this firmware does instead.
Status: **open** = documented, fix not yet implemented; **approval** = touches calibration/EEPROM
semantics, fix waits for owner approval; **by design** = documented, judged intended, behaviour kept;
**fixed** = implemented in the new firmware and verified in the emulator; **fixed (fast build)** = only in the production build; **kept** = left as v2.05 on purpose.

## Summary

| ID | Area | Issue | Severity | Status |
|---|---|---|---|---|
| OF-01 | Table lookup | Stale index used when a table search fails | medium | fixed |
| OF-02 | Mode setup | Unset register values stored to globals for unhandled cases | medium | fixed |
| OF-03 | Mode setup | Unset register stored for out-of-range modes (two functions) | low | fixed |
| OF-04 | Multiplier path | Unset register passed to a float multiply for a range byte > 3 (dBm path; not reached with a consistent mode and range) | low | fixed |
| OF-05 | Mode helper | Unset register passed on for modes outside the handled set | low | fixed |
| OF-06 | GPIO set-up | Pin mask left uninitialised for unhandled arguments | high | fixed |
| OF-07 | Calibration | LowZ calibration would write the ACV range-0 record, which LowZ never loads (reachable through OF-36); BEEP shares OHM range 1's record 0x120 | medium | fixed |
| OF-08 | Calibration | Entering calibration mode clears the six user current-zero records without confirmation or mention in the manual | medium | fixed |
| OF-09 | Calibration | Current zeroing (long REL) stores only the last increment: a second zeroing is lost at the next mode/range change | medium | fixed |
| OF-10 | Bluetooth | Packet build and transmit are not synchronised; command echoes can interleave with status frames | medium | fixed |
| OF-11 | Bluetooth | First frame after enabling BT can carry stale buffer contents | low | fixed |
| OF-12 | Backup | `cal.bin` does not include the six user current-zero records at EEPROM 0x4D0–0x4FF | medium | fixed |
| OF-13 | ADC | ADC sample-time register rewritten while the ADC is on, against the reference manual | low | fixed |
| OF-14 | Measurement | HY3131 AD1 result decoded with the wrong two's-complement offset: negative codes read 1 LSB high, negative full scale reads as positive | low | fixed |
| OF-15 | Measurement | Rounding to display counts truncates toward zero after adding 0.5: negative readings show one count too little in magnitude | medium | fixed |
| OF-16 | Measurement | The HY3131 true-RMS result is read, square-rooted and averaged on every RMS interrupt, then never used | low | fixed |
| OF-17 | Measurement | PEAK and the 1 kHz filter can be on together; the HY3131 then raises no serviced interrupt, the main display goes blank and stays blank | medium | fixed |
| OF-18 | Measurement | PULSE width is computed from a duty cycle truncated to 0.1 %: shown in 5 digits but quantised to 0.1 % of the period, always rounded down | medium | fixed |
| OF-19 | Measurement | TEMP re-converts its own previous result on every AD1 sample while MEM view is open; leaving the view shows a wrong temperature | low | fixed |
| OF-20 | Measurement | BEEP overload limit inherits the OL-hysteresis flag of the previous mode (OL from 541.67 ohm instead of 550.00 ohm) | low | fixed |
| OF-21 | Measurement | Temperature rounding to 0.1 degree tests the digit after the division: tenths digit 5 is never shown, readings up to 0.1 degree off | low | fixed |
| OF-22 | Measurement | degC to degF takes the sign from bit 15 and negates with one's complement: up to 0.02 degF error, -40.0 degC shows -39.9 degF | low | fixed |
| OF-23 | Settings | DIODE 15 V selection is written to EEPROM 0x12 and loaded at boot, then forced back to 3 V | low | fixed |
| OF-24 | Measurement | Cold-junction conversion silently keeps the previous (or power-on zero) value for board temperatures below -20.0 degC | low | fixed |
| OF-25 | Measurement | AC+DC: the sum of squares wraps at 2^32, so a large reading is shown as a small one, with no overload and no range change | high | fixed |
| OF-26 | Measurement | 1 kHz filter: below 20 Hz, or while no frequency has been measured, the reading is ten times too large | medium | fixed |
| OF-27 | Measurement | VA, mode 15 ranges 2/3 (0x20007FDF = 0): burden table read past the end of its rows; range 3 shows OFL for a valid voltage | medium | fixed |
| OF-28 | Measurement | One smoothing state shared by two different quantities (AC+DC, burden display, VA): readings are averaged with the other quantity | low | fixed |
| OF-29 | Measurement | DC VA burden correction depends on the sign: reversing the polarity changes the corrected magnitude | low | fixed |
| OF-30 | Measurement | LowZ shows "0.0" V for 1.1 to 2.4 s each time a voltage appears at the input (100 V, 230 V, 600 V tested), before the real value | high | fixed |
| OF-31 | Main loop | LCD update busy-wait in every display commit paces the main loop to the LCD frame: AD1 conversions beyond about 72 per second are dropped and the CPU never sleeps while measuring | low | fixed (fast build) |
| OF-32 | Display | BEEP and FREQ draw the zeroed value at mode entry: "0.00" ohm with open or connected leads, "0.000" Hz with a signal present | low | fixed (fast build) |
| OF-33 | Measurement | CAP timeout range jump draws the old count with the new range's decimal point and the old unit for one display update ("10.000" nF becomes "1.0000" nF) | low | fixed |
| OF-34 | Bluetooth | Status frames built during a range change report value 0, no overload, in the new range, with no flag that the value is invalid | low | fixed |
| OF-35 | Logging | Log records store the single per-sample value 0x20007D68, not the averaged value that is displayed | low | fixed |
| OF-36 | Calibration | A running offset/gain capture is not cancelled by a mode or range change; it completes in the new mode/range and is written to that mode/range's EEPROM record | high | fixed |
| OF-37 | Calibration | SETUP short in calibration mode continues into the MEM-short code: refusal beep after a started offset capture; in an AC band slot 2 is overwritten from the slot-1 reading | medium | fixed |
| OF-38 | Settings | Contrast 10 and 11 can be selected and are saved to EEPROM 0x1A, but power-up accepts only 12..17 and replaces them with 14 | low | fixed |
| OF-39 | ADC | ADC_Init passes an uninitialised stack word that is ORed unmasked into ADC_CR2 (value: core register r6 as left at reset) | low | fixed |
| OF-40 | Power-down | The TIM2 jack-warning beep can set the buzzer output again after power-down has cleared it (chirp of about 86 ms after the "-oFF-" beep) | low | fixed |
| OF-41 | Display | Setup page 7 (time): the TIM2 handler converts and draws the time through the same digit globals and text buffer the main loop uses for the reading; the reading shows wrong digits for about 0.22 s | low | fixed |
| OF-42 | SD card | The disk read routine `FUN_08023F7E` reads one sector whatever sector count the file system asks for; no v2.05 caller asks for more than one | low | fixed |
| OF-43 | Keys | The key hold time and the stable-sample count are unlimited byte counters: a key held for about 3.1 s fires its long-press action again, then every 2.57 s; released between 2.6 s and 3.1 s it also fires its short-press action | medium | fixed |
| OF-44 | Measurement | ACmV with the 1 kHz filter on: the per-sample value 0x20007D68 (bargraph, log record) lacks the filter correction that the reading and the ACV per-sample value have | medium | fixed |
| OF-45 | Bluetooth | `USART_SendData` waits for TXE without a bound inside the TIM2 handler: if it runs in the 148 us between the serial-transfer flag and the USART2 clock enable, the meter hangs until it is switched off | low | fixed |
| OF-46 | Measurement | ACV dBm sub display at a zero reading: log10(0) = -infinity is converted to 0xFFFFFFFF and shown as "- 7295" | low | fixed |
| OF-47 | Logging | Logging stopped by a low battery stores code 100 and the sub display shows "SdE" with two blank digits; the two-digit routine is right only up to 19 | low | fixed |
| OF-48 | Keys | Setup edit: REL or PEAK held longer than 0.5 s steps once more when the key is released (the press is queued, the MEM view excludes it) | low | fixed |
| OF-49 | Display | `FUN_0801B090`: the first digit word is n / 10000 without reduction, so n >= 100000 draws a blank or wrong first character; no defined v2.05 input reaches it | low | fixed |
| OF-50 | Display | `FUN_0801B77A` passes `LCD_FCR AND mask` instead of the mask to `LCD_ContrastConfig`; the result is always overwritten by the following `lcd_init` | low | fixed |
| OF-51 | Runtime library | Soft-float and 64-bit division helpers differ from IEEE 754 / the ARM run-time ABI in listed cases (fdiv exponent 254, subnormal operands of fadd/fsub/dadd/dsub, dsqrt special operands, division by zero); none reached by v2.05 code | low | kept (latent; dsqrt and 64-bit division fixed in the fast build) |
| OF-52 | Battery | The ADC-to-battery conversion is a straight line that matches the hardware divider only near 6.4 V: the gauge reads up to 6 % low near empty and the low-battery warning starts at 4.31 V instead of the displayed 4.1 V | low | fixed |
| OF-53 | Measurement | HY3131 interrupt flags are cleared by writing 0 after the status burst read: a flag raised in between is lost; a lost counter-done flag freezes the frequency reading until the next mode or range apply | medium | fixed |
| OF-54 | Measurement | The status burst reads the counter registers before INTF: a count that completes in between is seen as done with stale counter values; in AC modes the frequency correction then uses frequency 0 | medium | fixed |
| OF-55 | Backlight | The backlight state flag 0x2000807B stays 1 across an auto power-off (STOP): the pin PE8 is driven low by the power-down but nothing resets the flag, so after the wake the first MODE long press only clears the flag and a second one is needed to switch the backlight on | low | fixed |
| OF-56 | Temperature | One entry of the type K table 0x08025CF8 differs from the NIST ITS-90 table: 270 degC holds 10970 uV, NIST 10.971 mV (the NIST reference function gives 10970.95 uV); readings near 270 degC are 0.02 degC high | low | fixed |
| OF-57 | SD card | The SD byte address is built in 32 bits (`sector << 9`, upper word 0): every access at or past 4 GiB goes to sector N mod 2^23 of the card, so on a card larger than 4 GiB a write past that point overwrites the FAT, the directory or early files | high | fixed |
| OF-58 | SD card | `get_fattime` returns FatFs's sample constant 0x3449B3C0: every file is created on 2006-02-09 22:30 and each close writes that date as the modification time until the log code corrects it | low | fixed |
| OF-59 | SD card | SD errors are not passed on: the disk status is the raw `sd_init` code (even codes pass as ready), a read takes the buffer without waiting for the data end and ignores SDIO errors, a write ignores a negative CRC status token, so a block the card refused counts as written | medium | fixed |
| OF-60 | Logging | The file that is forced after 20 failed write attempts gets no CSV header: the header is due only while the forced-file counter is 0 | low | fixed |
| OF-61 | Logging | When all 40 write attempts fail, logging is switched off without `log_stop`: the range frozen by the logging start stays manual, the counters, the stop time and the MEM view window are not saved | medium | fixed |
| OF-62 | Calibration | After the ACV range-0 calibration writes its marker (EEPROM 0x01F) the RAM flag that selects the CORR70 correction keeps its boot value until the next power-on; the (unreachable) Ohm range-6 branch stores the opposite of what the next boot reads | low | fixed |
| OF-63 | Buzzer | The buzzer setting (SETUP "b-OFF") does not silence the diode short-circuit tone, the auto-hold capture beep, the auto power-off warning and the power-off beep | low | fixed |
| OF-64 | SD card | FatFs R0.08a error paths fixed by ChaN in R0.10a..R0.10c: f_write stores the result of create_chain as the start cluster before checking it (a disk error writes 0xFFFFFFFF into the directory entry), create_chain links a new cluster behind an entry it could not read, move_window keeps the old sector number after a failed read, put_fat marks the window dirty after a failed load | medium | fixed |
| OF-65 | BLE | The status frame's bar byte (14) carries the raw segment count, which exceeds the 25 segments of the display on an overload (45..55 seen); an application that masks the byte (the official one reads it & 0x1F) shows a wrong bar | low | fixed |
| OF-66 | SD card | disk_read / disk_write give the caller's buffer to the SDIO DMA, which aligns every word access down: a sector read into or written from a buffer that is not a multiple of 4 lands 1..3 bytes off (FatFs passes the caller's buffer for whole sectors) | medium | fixed |
| OF-67 | Keys | Holding MEM while switching on (the cal.bin backup / restore entry) for longer than the long-press time also starts logging; the following MODE then does not confirm the backup or restore | medium | fixed |
| OF-68 | SD card | The capacity of a high-capacity card is computed in 32 bits and wraps above 4 GiB (a 32 GB card reads as 1.72 GiB); unused in v2.05, but the port's card format sized the volume by it | medium | fixed |
| OF-69 | SD card | Card sessions run the CPU on the 4 MHz crystal with the PLL at a 48 MHz VCO, where the reference manual requires 96 MHz for the SDIO; on a meter block writes stopped with a transmit underrun | medium | fixed |
| OF-70 | Clock | The reset clock set-up raises the CPU clock 7.6-fold in one step; the reference manual allows less than 4-fold per step | low | fixed |
| OF-71 | Bluetooth | The USART2 receive interrupt returns without reading USART_DR when RXNE is clear; an overrun flag (ORE) that is set with RXNE = 0 also raises this interrupt and is then never cleared, so the interrupt repeats for ever | medium | fixed |
| OF-73 | Power | After auto power-off the meter wakes from STOP on a key or dial turn but hangs in the restart: a timer interrupt left asserted with the timer's clock off is entered again for ever | high (the meter could only be restarted with the dial) | fixed |
| OF-72 | Bluetooth | The baud computation of USART_Init drops the carry of the rounded fraction: for a clock 2.3 .. 2.5 % above nominal the Bluetooth serial line runs 7 % too fast | low (reachable only with the measured clock) | fixed |

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
`FUN_0800A74C` (the dBm value for the ACV sub display, OF-46) switches on the range byte `meter_range` (0x2000803D; the literal at `0x0800B064`, loaded at `0x0800A74E`/`0x0800A752`; the mode byte is
0x2000803C): ranges 0 to 3 load r4 (`0x0800A764`, `0x0800A77A`, `0x0800A790`, `0x0800A7A6`); a range byte above 3 takes the default branch (`0x0800A75E cmp r0,#3`, `0x0800A762 b.n 0x0800A7BA`),
which never writes r4; r4 is then passed to the float multiply (`0x0800A7BA movs r0,r4`, `0x0800A7BC movs r1,r4`). Execution check: range 3 gives 62.2185 dBm for 10000 counts whatever r4 held; range 4 or 9
with r4 = 1.0f gives 2.2185, with r4 = 2.0f 8.2391, with r4 = 0 -infinity. Reachability: the only caller (`FUN_080076BC`, from the ACV and VA voltage handlers) runs in modes 0, 2, 13, 14 and 15, whose range counts
are 1, 4, 4, 4 and 4 (table at 0x20000000); over the coverage runs the range byte at entry was always 0..3 (modes 0, 2, 13, 15; more than 1000 calls), so the default branch is not reached with a consistent
mode and range. Port: defined value (x = 1.0, dBm 2.2185 for a range byte above 3).

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
`FUN_080137B4` (returns at `0x080137EE` / `0x080137FE`); observed 40 times in 4 s of emulated running (every 0.1 s, alternating between channels 4 and 5).
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
Execution check (full emulator, ACV, 3 s after the keys): filter only — INTE 0x05, 214 interrupt services,
214 AD1 decodes, 14 display updates; PEAK only — INTE 0x11, R29 0xC4, 57 services and 57 peak-routine calls;
PEAK + filter (either key order) — INTE 0x11, R29 0x01, **0 services, 0 AD1 decodes, 0 peak calls, 0 display
updates**, while the chip itself completed 1122 AD1 conversions.
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
mean; the only writer of 0x2000805D in view is `0x0800781A` (= 1). On leaving the view (t = 19.291 s) the
display routine ran immediately and stored **357** in the displayed value 0x20007D70 (`0x08017178`); 242 came
back only at the next mean, 0.29 s later.
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
with 100 V DC present: "0.0" from 0.136 s to 1.423 s after the dial change (1.29 s), five zero stores by `0x08006600`
at 0.300..1.176 s, each right after the mean wrote 1000; HV symbol at 0.980 s; bargraph moves at 0.330 s. With
230 V AC 50 Hz present: "0.0" from 0.136 s to 2.263 s (2.13 s; DC state first, toggle to AC at 0.905 s, re-apply);
HV symbol at 1.600 s. Power-on in LowZ with 100 V DC / 230 V AC / 600 V DC: "0.0" for at least 0.88 s, HV symbol
0.85 s / 1.47 s / 0.85 s after the first "0.0". Meter already in LowZ at 0 V (it cycles DC/AC and re-applies every
5..7 means), voltage then applied at 12 different phases each: 230 V AC: "0.0" for 1.12..2.31 s; 100 V DC:
1.16..1.78 s; -100 V DC: 1.21..1.91 s; 24 V AC: 1.22..2.42 s (no HV symbol). The HV symbol appeared before the digits
in every trial with 100 V or more. 8.0 V DC is shown as "0.0" indefinitely; 11.0 V DC is shown after the same delay.
Impact: in the mode used to check whether a conductor is live, the main display reads "0.0 V" for 1.1 to 2.4 s after
the probes touch 100..600 V; until the HV symbol appears (up to 1.69 s in the trials) nothing but the bargraph
indicates the voltage. A user who reads the digits early can take a live conductor for dead. The times are firmware
times on an ideal front end; real settling can only lengthen them. The dead band below about 10 V (reading 0.0) is
covered by the manual's "not designed to be operated at low voltages (below 12V)" and is not part of this issue.
Port: while the LowZ detector has not confirmed a voltage, blank the main digits (or show dashes) instead of a
numeric 0.0.
Port correction (2026-11-03, seen on a meter): with nothing connected, the first mean after each AC/DC re-apply of the
dead band rises above the threshold for one mean (Bluetooth frames of a meter in LowZ at 0 V: one frame with a full bar
about every 2.9 s), so the dashes flashed briefly every few seconds (GitHub issue 1). v2.05 hid that mean behind its
forced 0. The port now keeps the digits on the glass for the first unconfirmed mean and shows the dashes from the second
on (`ui_blank_req` = 3, `mres/lowz.s`); a real voltage still shows dashes one mean later and its value after the five
means of v2.05. Verified working on a meter (v0.9.8, LowZ, nothing connected: no more dashes).
Production image, v0.9.9: the bargraph had the same cause (it follows the per-sample value, so the settling spike flicked
it to full scale and flipped its sign); it now keeps its segments during that first mean (`lowz_bar_hold`, `mres/lowz.s`,
read by `fn_08018B14`). Verified working on a meter (v0.9.9, LowZ, nothing connected: the bargraph stays put).

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
service; 2 s each, frame 72.27 Hz for FCR 0x00C05440 with LSI 37 kHz): BEEP 10 ohm: 72.5 commits/s, 515 ms/s inside
the wait, 72.5 HY3131 services/s for 641.5 AD1 conversions/s (89 % dropped), median main pass 13.84 ms. OHM 1 kohm:
72.5 services/s for 320.5 conversions/s, 534 ms/s waiting. DCV 1 V: 69.5 commits/s, 470 ms/s waiting, 68.5 services/s
for 77.0 conversions/s (11 % dropped). No partial commit occurred in these runs.
Impact: the 16-sample mean takes 16 x 13.84 = 221 ms on every configuration row faster than the frame rate (BEEP row:
25 ms possible), so update rate, range-change time and continuity digit response are set by the LCD frame, not by the
HY3131. 47 to 53 % of the active time is spent spinning instead of sleeping. Displayed values are not wrong: dropped
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
Execution check: OHM -> BEEP (MODE) with 100 ohm: "  0.00" ohm from 0.089 s to 0.297 s after the key release, then
"100.00"; with open leads: "  0.00" from 0.060 s to 0.269 s, then " OFL"; the buzzer stayed off in both runs.
DCV -> Hz (dial) with 1 kHz: " 0.000" Hz from 0.112 s to 0.567 s, then "1.0000" kHz. With no signal "0.000" Hz is
the correct final reading.
Impact: for about 0.2 s (BEEP) and 0.46 s (FREQ) a valid-looking reading of zero is shown; in BEEP open leads briefly
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
Port: contrast 10 and 11 are accepted at power-up (switch `SET_ACCEPT_CONTRAST_10_11`, default 1; NF-17).

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
(LCD disable wait in `FUN_0801C908`), 0.4 to 13.9 ms in the runs; the TIM2 period is 10.02 ms and the window starts
right after a tick, so only windows above 10.02 ms can contain one. PE7 is not left high into STOP: `0x0801CA22`
sets all GPIOE pins to analog before the `wfe` (`0x080207F6`). The TIM3 repeat path (`0x080247D4`) needs a repeat
count 0x2000807A pending at power-down; its only writer `FUN_0800EE7A` reloads the APO counter (`0x0800EE88`
`bl 0x0800ED26`), and it was not reproduced.
Execution check (DCV, plug in the A jack -> " LEAd" and the 0.5 s on / 0.5 s off warning; APO request 0x2000803A set
from a write hook on 0x20007F04 to choose the TIM2 phase, which in use drifts freely against the RTC second that
triggers APO; 108 runs): window above 10.02 ms in 44 runs; with the jack-warning tick inside the window (4 runs):
PE7 set by the TIM2 handler (pc `0x0800EEE4`, IPSR 44) 10.01..10.03 ms after `0x0801C58C`, TIM2 stopped at 12.51 ms, PE7 high
until its pin went analog at 96.6 ms. In the other runs, and in 40 runs with the APO countdown itself as trigger (window above 10.02 ms in 16 of them), PE7 stayed low from `0x0801C58C` until
the pins went analog.
Impact: occasionally, with a lead in a current jack at auto power-off, a second buzzer chirp of about 86 ms follows
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
to 49 at each `0x08017156`, which in use meet at random; 90 s): 8 nested calls, 5 visible: main display "1.2 56",
"1.2357", "0.0057", "0.2 57", "1.2-57", each for 16 LCD frames (about 0.22 s), then "1.2345" again.
Without the preset (20 s, 40 handler draws, 88 main draws of about 250 us) no overlap occurred.
Impact: on the time setup page the main reading can briefly show wrong digits (estimated from the measured window:
about 4.4 draws/s x 250 us, i.e. roughly 0.11 % of the half-second ticks). Cosmetic, transient.
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
Append: "Execution check (Unicorn, v2.05 image, FatFs structures built by hand: sector size 512, 4 sectors per cluster, file at cluster 2 at fptr 0, the block read `FUN_08022FCE` replaced by a stub that fills
the destination with the sector number): `f_read(fp, buf, 2048, &br)` returns 0 with br = 2048, performs one block read (sector 100), and the buffer holds sector 100 in the first 512 bytes and the old
contents in the remaining 1536. Reachability re-checked: the seven `f_read` call sites (`0x0801CDCE`, `0x0801CE32`, `0x0801CE9E`, `0x0801CF62`, `0x0801CFB8`, `0x0801D016`, `0x0801F728`) pass at most 0x200
bytes (the 0x4B0 byte calibration file is read as 0x200 + 0x200 + 0xB0), so the sector count at `0x08021E74` is never above 1."

### OF-43 — key hold counters wrap: a held key fires its long-press action again after 3.1 s
`process_pg8_15_press_release` (`0x0801688C`, called once per TIM2 tick flag 0x200080D0 from `main` `0x08024BAC` through `FUN_0801680C`;
the TIM2 handler stores it at `0x0802429E`) counts the hold time 0x20008072 (`adds r0,r0,#1` / `strb`, `0x08016964`, `0x0801696A`) and
the equal-sample count 0x200080EF (`0x080168D6`..`0x080168DC`) in bytes without a limit. The hold time is set to 0x33 when the long press
fires (`0x08016976`..`0x0801697C`) and keeps counting; it is 0xFF 204 ticks later and the next increment gives 0. A hold time of 0 means "no
key tracked" (`0x0801695A cmp r0,#0`, `0x0801695C beq 0x080169E8`): as soon as the lockout 0x20008073 is 0 (`0x080169E8`..`0x080169F0`) the key
that is still down is taken for a new press: hold time 1 (`0x080169FA`..`0x08016A00`), a short press is queued (0x200080EE = 1,
`0x08016A4E`..`0x08016A5A`; inside the power-on window 0x2000022E != 0 it fires at once, `0x08016A08`..`0x08016A34`), and 49 ticks later the hold
time is 0x32 and the long press fires again (`0x08016972`, `0x08016974`). The equal-sample count wraps the same way (0xFF to 0, then
`cmp r0,#2` `0x080168E4` / `blt.w 0x08016A5C` `0x080168E6`): the key logic skips two ticks every 256.
Execution check (Unicorn, `0x0801688C` and `FUN_0801682C` once per tick, GPIOG IDR `0x40021C10` driven, handlers `0x08014C3C` / `0x0801622C`
replaced by call logs, RAM zero, window counter 0): RANGE (PG12) pressed at tick 5 and held 1200 ticks: long press at ticks 56, 313, 570, 827 and
1084 (every 257 ticks = 2.57 s at 10.02 ms); the same for MODE (0x01) and MEM+HOLD (0x28); HOLD (0x20) has no long press. With the window counter
at 5 the wraps also give short presses at 264 and 521. Release scan (key down at tick 5): released at tick 264 or earlier, no extra event; released at
ticks 266 to 313 (265 was not run), a short press two ticks after the release although the long press had already fired (266 to 268, 313 to 315); released at 314 or later,
the second long press (313). Real handler `0x0801622C` called repeatedly: MODE (key 1) toggles 0x2000807B 1, 0, 1; PEAK (0x80) toggles 0x2000802B;
SETUP (2) toggles the edit flag 0x2000806E and the call that leaves the edit writes the EEPROM; RANGE (0x10) sets `range_manual` 0 and the range-change flag 0x2000804B again; REL (0x40, mode 16, range 0, 0x20007D64 = 5) adds the value to 0x20007E0C again and stores to the data EEPROM again (`0x0801645C`):
0x20007E0C = 5, 10, 15 on three calls. Full emulator (DCV): MODE held 4.5 s: backlight on 0.70 s after the press, off again at 4.03 s with the key
still down; MEM held 6 s with an SD card: logging flag 0x20007FE1 = 1 at 1.5 s and 3.0 s, 0 at 4.5 s and 6.0 s (the repeat comes 3.4 s after the first
long press there, because the main loop serves about 72 ticks per second, see OF-31).
Impact: a key held longer than about 3.1 s repeats its long-press action: MEM starts logging and stops it again (a file is created and closed),
MODE toggles the backlight back and forth, PEAK toggles the serial transfer, SETUP toggles the item edit and saves it, RANGE selects auto-range
again, REL in the current modes at range 0 adds the reading to the user zero again and writes the EEPROM (see OF-09). A key released between the
wrap and the second long press (2.6 s to 3.1 s) also fires its short-press action (dispatch executed; the actions are those of `analysis/keys_setup.md`
2.2: MODE changes the mode, RANGE steps the range).
Port: both counters stop at 0xFF (KEY, `keys.s`); one long press per hold, no short press after it.

### OF-44 — ACmV with the 1 kHz filter: the per-sample value lacks the filter correction
The mode 4 handler `FUN_080069B4` (dispatched at `0x0800629E`) applies the 1 kHz filter correction `fn 0x08006D40` to the mean (`0x08006A50`),
but its per-sample block (`0x08006A84`..`0x08006A9A`: 0x20007D74, `bl 0x08008468` at `0x08006A88`, `bl 0x0800742C` at `0x08006A94`, store to 0x20007D68
at `0x08006A9A`) never calls it. The ACV handler `FUN_08006AEC` ends its per-sample block with the correction
(`0x08006C50`..`0x08006C76`: mode 2 or 4 at `0x08006C52` / `0x08006C5A`, filter flag 0x200080B9 = 1 at `0x08006C5E`..`0x08006C64`, 0x20007D68 x 10,
`bl 0x08006D40` at `0x08006C70`, store at `0x08006C76`). The mode 4 comparison there is dead code: `FUN_08006AEC` has four callers (`0x080062C2`, `0x0800654C`, `0x08006676`, `0x08008BA4`) and mode 4 is dispatched to `FUN_080069B4` (`0x0800629E`), not to it; the
compare suggests the designer meant the correction for the ACmV sample too (inference from the dead compare, not proven). 0x20007D68 feeds the bargraph (`bargraph_count_from_value` `0x08018FA8`) and, in all modes
except 5 to 9 and 12, the log record (OF-35).
Execution check (full emulator, ACmV, 0.1 V AC): filter off, 50 Hz: 0x20007D64 = 10000, 0x20007D68 = 10000, bargraph count 5. Filter on, 50 Hz: 9999 / 9596,
count 4. Filter on, 1 kHz: 9999 / 2885, count 1. Same test in ACV (1.0 V AC, filter on): 0x20007D64 = 0x20007D68 = 9999 at 50 Hz and at 1 kHz, count 4.
Impact: with the filter on, the number on the main display is right, but the bargraph and the logged value follow the unscaled sample: at 1 kHz
the bargraph shows one segment for a reading that fills four or five; the log (OF-35) holds 2885 where the display shows 9999. The error depends on the
signal frequency.
Port: v2.05 behaviour kept (`firmware/src/mac/ac.s`, `.Lmac_acmv_sample`); the correction of the ACV block would have to be added for mode 4.

### OF-45 — USART_SendData waits for TXE without a bound inside the TIM2 handler
`FUN_0800D170` (USART_SendData with wait) loops `0x0800D176 movs r1,#0x80` / `0x0800D17A bl 0x0801CC5E` (USART_GetFlagStatus, TXE) /
`0x0800D17E cmp r0,#0` / `0x0800D180 beq 0x0800D176`: no counter and no other exit. Callers: the TIM2 handler (`IRQ28_Handler` 0x0802428C; 50-tick block
`0x0802461C`, flag test `0x08024630`..`0x08024638`, call `0x0802464C`), the USART2 handler (`0x0802481C`, TXE already set) and the main-loop echo
`FUN_0800C308` (`0x0800C328`). USART2 (0x40004400) is only set up while the transfer flag 0x2000802B is 1: the long PEAK handler stores the flag at
`0x08016536` and calls `FUN_0800C51A` (`0x08016560`), which calls `usart2_init` (`0x0801C390`); the USART2 clock is enabled at `0x0801C3EA` (`bl 0x0801FFBC`,
RCC_APB1ENR bit 17), TE/RE are set by the init structure (mode 0xC at `0x0801C40C`), no hardware flow control (`0x0801C408`), USART_Cmd at `0x0801C422`. Clearing
the flag calls `0x0801C954` (supply low, interrupts off, USART_Cmd 0 `0x0801C96E`, clock off `0x0801C978`). Between the store and the clock enable the USART2 registers
are not clocked and RM0038 6.3.10 (as quoted in `emulator/emu/periph/usart.py`) says reads then return 0: TXE reads 0.
Execution check (full emulator, hooks at `0x08016536` and `0x0801C3EA`): the window is 622 core cycles = 148.3 us (4.194304 MHz); the 50-tick block runs once per 0.501 s,
so a random TIM2 phase hits it about once in 3400 switch-ons. Normal run (DCV 1 V, long PEAK, step to 2.0 V): the main display shows 2.0000 three seconds later. Run with the TIM2
counter and 0x20007F04 set at the store so that the block runs 514 cycles later: the handler (IPSR 44) stays in the loop (`0x0800D17E` reached 1 176 119 times up to the end of the
run) and the display still shows 1.0000 three seconds after the step to 2.0 V. No code references an IWDG or WWDG register (`analysis/decompile/mmio_refs.txt`), so
only switching the meter off and on recovers. Not a cause: the BLE module supply (TXE does not depend on the line). The silicon behaviour with a gated clock was not measured;
the hang follows RM0038 6.3.10.
Impact: in rare cases (about 1 in 3400 switch-ons of the serial transfer) the TIM2 handler never returns: display, keys, measurement and auto power-off stop until the dial
is turned off and on. No effect otherwise.
Port: the wait is bounded (`firmware/src/ble/usart.s`, `fn_0800D170`, `SYS_WAIT_POLLS`; on timeout nothing is sent) and the TIM2 handler only records the frame request (OF-10, NF-04).

### OF-46 — ACV dBm sub display shows "- 7295" at a zero reading
`FUN_0800A74C` (called after every ACV mean from `FUN_080076BC`, `0x080076EE`) computes dBm = 10 log10(x x / 0.6) with x = reading / 10^(4 - range): float square
(`0x0800A7BE`), double conversion (`0x0800A7C2`), division by 0.6 (`0x0800A7C6`..`0x0800A7CE`, constant 0x3FE3333333333333), log10 (`0x0800A7DE bl 0x0801BB5C`), times 10.0
(`0x0800A7E4`..`0x0800A7E8`), float result to 0x20007E94 (`0x0800A7F4`). For a reading 0x20007D64 = 0 the library log10 returns -infinity (0xFF800000). The sub display
for ACV item 11 (`FUN_08018590`, called at `0x08017B66`) turns the magnitude into an unsigned integer (`FUN_0801BD24`: infinity gives 0xFFFFFFFF) and calls `FUN_0801B090`
(`0x0801868C`): the digit words are 429496, 7, 2, 9, 5, `FUN_0801B130` clears the first (above 255) and the display shows " 7295" with the minus sign.
Execution check: `0x0800A74C` with 0x20007D64 = 0: 0x20007E94 = 0xFF800000 in all four ranges (1 V = 10000 counts gives 2.2185 dBm, 10 log10(1/0.6)); `FUN_08018590` with that
value draws " 7295". Full emulator, ACV, 0 V input, one SETUP press (item 10 to 11): sub display "- 7295"; with 1.0 V AC: " 2.218".
Impact: with the dBm page selected and an open or shorted input (reading exactly 0) the sub display shows a number instead of an under-range indication.
Port: not changed (copies of `fn_0800A74C` in `mac/acdc.s` and `fn_08018590` in `set/setup.s`).

### OF-47 — logging stopped by a low battery shows "SdE" and two blank digits
While logging, the step function tests the battery flag 0x2000803B (`0x0801D2F8`..`0x0801D300`); when set it stops logging (`0x0801D304 bl 0x08010AF8`, 0x20007FE1 = 0), and stores
code 100 in 0x2000801B (`0x0801D316 movs r0,#0x64`, `0x0801D318`..`0x0801D31C`). Starting a log with the battery flag set stores 0x14 instead (`0x080109F6`..`0x080109FC`), and
the sub display shows "LoBat" for it: `FUN_0801797C` compares with 0x14 (`0x080179A6`) and calls `FUN_080198B0` ("LoBat", `0x080198C2`..`0x080198E8`). Every other code goes to `FUN_08019948`
(`0x080179B6`), which prints "SdE" and two digits: tens = n / 10 + '0' (`sdiv` `0x08019980`), units = (n - 10) + '0' for n >= 10 (`subs r5,#0xa` `0x0801998C`, `adds.w r0,r5,#0x30`
`0x08019998`), right only for n up to 19; the font has glyphs only for 0x30..0x39, 0x41..0x5A, 0x61..0x7A, 0x20, 0x2D, 0x3D and 0xFF. `FUN_08019698` (the "-O-nn" calibration step
display, units at `0x08019716`..`0x0801971C`) has the same arithmetic (`0x080196FC`..`0x0801970C`); its n is the capture counter 0x20008095, which is set to 16 or 4 (`0x080164F4`, `FUN_080157E8` result stored at `0x080157C2`) and decremented to 0 by nine sites (`0x08008618`, `0x08008CC4`, `0x0800EFB0`, `0x0800F05C`, `0x0800F0DC`, `0x0800F4BE`, `0x0800F586`, `0x0800F6E8`, `0x0800F7E0`), each followed by a zero test that clears the capture flag; the six calibration-capture runs (SETUP and MEM captures with RANGE and MODE pressed in the middle) wrote only 16..0 (or 4..0) to it, never 255. So only `FUN_08019948` is reachable with n >= 20.
Execution check (Unicorn, `0x08019948`): n = 19 "SdE19"; 20 "SdE2:" (0x3A); 23 "SdE2=" (glyph a+d); 25 "SdE2?"; 59 "SdE5a"; 99 0x39 0x89; 100 0x3A 0x8A. Full emulator (SD card, logging started by long MEM,
DCV 1 V, battery sense PA5 lowered to 0.90 V): the sub display shows the record counter, then "SdE" with two blank digits (decoded text "SdE  ") after the battery flag came on, and it stays so.
Impact: the user does not see why logging stopped (the battery symbol is shown, the "LoBat" text of the start case is not).
Port: the v2.05 routines are kept (`firmware/src/ui/messages.s` `fn_08019948`, `firmware/src/log/files.s` code 0x64).

### OF-48 — setup edit: REL or PEAK held longer than 0.5 s steps once more at release
The press is queued at `0x08016A36`..`0x08016A5A` unless the MEM view 0x20007FE4 is set and the key is REL (0x40) or PEAK (0x80) (`0x08016A3E`..`0x08016A4C`); the edit flag 0x2000806E is not
tested there. The hold branch (`0x080169B2`..`0x080169E6`) tests view OR edit (0x20007FE4 | 0x2000806E, pool `0x08016D1C`), keeps the hold time of REL/PEAK at 1 and calls the auto-repeat
`FUN_08016A64(1)`. The hold time therefore never reaches 0x32, the queued press (0x200080EE) is never cancelled (the cancel is on the 0x32 path, `0x08016984`) and the release dispatches it.
Execution check (Unicorn, key down at tick 5, up at tick 105, step events logged): REL in the MEM view: steps at ticks 11, 42, 73, 104, nothing at the release; REL in edit: steps at 58, 89 and 107
(the last one is the release); a 5-tick tap steps once in both cases; PEAK gives the same.
Impact: after a hold the digit or setting is one step further than the auto-repeat sequence (for example contrast 14 held up to 16 instead of 15). `analysis/keys_setup.md` 2.1 states that
REL and PEAK are not queued in edit; that is wrong (section 7).
Port: v2.05 behaviour kept (W4 notes).

### OF-49 — number-to-digits routine: first digit word n / 10000 for n >= 100000
`FUN_0801B090` (`0x0801B090`..`0x0801B11A`) stores the first digit word as n / 10000 (`movw r1,#0x2710`, `udiv` `0x0801B094`, store `0x0801B09C`) with no reduction; `FUN_0801B130`
(`0x0801B130`..`0x0801B140`) only sets a word above 255 to 0, then adds '0' to the words it draws. For 100000 <= n < 256000 the first character is 0x3A..0x48 (blank glyph or a wrong
letter), above that the first word is cleared.
Execution check (Unicorn, `FUN_0801B090` then `FUN_0801B130(0)`): 99999 "99999"; 100000 0x0A,"0000"; 123456 0x0C,"3456"; 256000 0x19,"6000"; 999999 'c'... (first word 99 = 0x63); 0x7FFFFFFF " 8364".
Reachability (call sites by return address, maxima observed over 102 runs, all below 100000): main display `0x0801715A` (max 99999: the reading is limited to -99999..99999,
`0x08017036`..`0x08017040`, pool 0x000186A0 / 0xFFFE7961; the REL branch passes value / 10); BLE `0x0800C546` (u16 year-month, first word at most 6) and `0x0800C584` (the ID, kept
below 100000 at boot, `0x08010FA6`); sub display `0x08017F6C` (frequency: 0x20007D84 / 10, and 0x20007D84 <= 100000 for all five ranges because the range is only taken below
the thresholds 10^5, 10^6, 10^7, 10^8, 10^9 at `0x0800AEE4`, `0x0800B750`, `0x0800B74C`, `0x0800B748`, `0x0800B744`; max seen 6000); `0x080181D6` (VA voltages and currents, max 50000, overload
flags at 55001); dBm `0x08018690` (max 6130; the only larger value is 0xFFFFFFFF from OF-46, whose first word is cleared); temperature `0x08018A5A` (max 8070, 12-bit ADC value x 10); setup pages
(`0x080183C2` clamped to 99, `0x080187A0`, `0x080187F4`, `0x08018834`, `0x080188BC`, `0x0801890E`, `0x080189C4` ID), splash `0x0801A862` (205), log file writer `0x0801F394` / `0x0801F3CE`.
The one path without a bound: a counter result of 1 MHz or more stores an unset register in 0x20007D84 (OF-02, `0x0800B014`..`0x0800B024`); with r7 / 10 between 100000 and 255999 the sub display
frequency page (ACV, ACmV, AC currents, default item 10) shows a wrong first character (executed: 0x20007D84 = 1 234 567 draws 0x0C,"3456"). The emulator starts with r7 = 0, ACV at 1.5 MHz shows 0.
Impact: none with defined inputs.
Port: the first digit word is reduced modulo 10 (`fn_0801B090`, src/lcd/draw.s).

### OF-50 — contrast set-up routine passes the register value, not the mask
`FUN_0801B77A` (`0x0801B77A`..`0x0801B800`, called from the tail of `FUN_08024DE0` at `0x08024EC4`) selects on the contrast setting 0x20000237 (10..17) and builds r4 as
`LCD_FCR AND mask` (`0x0801B7AC`, `0x0801B7B8`, `0x0801B7C4`, `0x0801B7D0`, `0x0801B7DC`, `0x0801B7E8`, `0x0801B7F4`; setting 10: 0, `0x0801B79E`..`0x0801B7A4`), then `bl 0x08020472` (LCD_ContrastConfig:
clear CC, OR r0). The mask itself is what `lcd_init`'s `FUN_0801B708` passes (`0x400`..`0x1C00`, `0x0801B72C`..`0x0801B774`). The routine can therefore only keep or clear CC bits.
Both callers of `FUN_08024DE0` (`main` `0x08024B56`, wake `0x08024EF2`) call `lcd_init` next (`0x08024B62`, `0x08024EFC`, same setting 0x20000237), which writes the right CC (`0x0801B48C bl 0x0801B708`).
Execution check (Unicorn): LCD_FCR.CC = 7 before: settings 10..17 give CC = 0, 1, 2, 3, 4, 5, 6, 7 (setting - 10); CC = 0 before: CC = 0 for every setting; CC = 1 before: CC = 0 or 1 by setting.
Impact: none (overwritten); latent. (Settings outside 10..17 are OF-05.)
Port: the mask itself is passed to the contrast configuration (`fn_0801B77A`, src/lcd/lcd.s).

### OF-51 — soft-float and 64-bit division helpers: deviations from IEEE 754 and the run-time ABI
Execution of the original helpers against IEEE results (hardware float/double as reference; 4000 random pairs per class unless stated):
- `fn 0x08012F94` (float divide): a result whose biased exponent is 254 returns +-infinity (`0x08012FEA cmp r4,#0xfe` / `bge 0x08013038`, IEEE needs 255). 0xC23C8DC1 / 0x828CAB39 gives 0x7F800000 (IEEE 0x7F2B9283); of 20000 random normal pairs, all 28 with an IEEE exponent of 254 differ, the other 19972 agree.
- `fn 0x080132EC` / `0x080133B4` (float add / subtract): a subnormal operand in a magnitude subtraction enters at half its value (0x01000000 - 0x00400000 gives 0x00E00000, IEEE 0x00C00000) and a negative result with exponent field 0 loses its leading one (0x00AAE475 - 0x0112A19A gives 0x8074BD7E, IEEE 0x807A5EBF): 154 and 172 of 4000 mismatches for add with one subnormal operand, 152 and 195 for subtract; none with two subnormal or two normal operands.
- `fn 0x080131B8` / `0x0801FB9C` (double add / subtract): with one subnormal operand and a negative larger operand the larger operand is returned unchanged (`0x08013286`, `0x0801FCF6` form the exponent difference from "sign and exponent" minus 1): 0x8010000000000000 + 0x8000000000000001 gives 0x8010000000000000 (IEEE 0x8010000000000001); 0x800B5B3E13F95954 - 0x0047152C8D4F9271 gives 0x8047152C8D4F9271 (IEEE 0x804880944FCEBD9C); mismatches in about 99 % of the pairs (1499 of 1513 and 1493 of 1511 for add, 1491 of 1504 and 1482 of 1503 for subtract) when the normal operand has an exponent field below 40, about 2 % (34 of 1470, 34 of 1494, 32 of 1488, 36 of 1528) with a random normal operand, none in about 1500 pairs per class when the larger operand is positive.
- `fn 0x08013EF4` (double sqrt): sqrt(-0) = +0 (`0x08013FD8`); a negative NaN with a non-zero high mantissa is returned unchanged without errno; every other negative operand (including -infinity) writes errno 0x21 (RAM 0x20000228) and returns r0 unchanged with r1 = NOT of sign and exponent (-1.0 gives 0xFFFFF40000000000).
- `fn 0x08014028` (unsigned 64-bit divmod) and `fn 0x08013FE4` (signed): a divisor of 0 returns the dividend as quotient and 0 as remainder (`0x08014030 cbz r2,0x0801403E` / `b.w 0x0802038C`); no trap, no errno (12345678901234 / 0 gives 12345678901234 remainder 0).
Reachability: `dsqrt` has two callers (`0x0800A73C`, `0x080082BE`), both preceded by the unsigned-to-double conversion `0x08013ED8` (result +0 or positive, never negative, -0 or NaN); operand classes seen over the runs: positive and +0 only, so none of its quirks is reachable.
`fdiv` (40 call sites), `fadd` / `fsub` (12), `dadd` / `dsub` (28, including the log10 library): the operands are converted counts (0 or at least 1.0), calibration words converted from unsigned integers, constants and thermocouple tables; a subnormal operand (below 1.2e-38 / 2.3e-308) or a quotient of 1.7e38 or more did not occur in any of 102 runs (hooks on every entry: 0 subnormal operands, 0 candidate quotients) and was not found in the call sites that were read; not every site was traced by hand.
`uldivmod` (14 sites): divisors are the constants 1, 10, 100, 1000, 10000 (`0x0800AF1C`..`0x0800AFE0`, `0x0800B0A2`, `0x0800B272`..`0x0800B2B2`, `0x0800B6A2`) or `0x20007E48 / 10` at `0x0800B662` (at least 0x200000 / 10: T = 0x1000000 - (word at 0x2000001C << 8) + CTA, and the word is 0xE000 after start-up, `analysis/decompile/ram_init.txt`), `(0x20007E18 / 1000) x 0x20007E40` at `0x0800B6B6` and `0x20007E40 x 100` at `0x0800B71A`: 0x20007E18 is at least 40 000 000 (`analysis/hy3131_modes_misc.md` 5.2) and 0x20007E40 is the counter's whole-cycle count, so a zero divisor needs a counter result with zero cycles. No zero divisor in any run, including PULSE and DUTY with no signal.
Impact: none found; the helpers were kept bit for bit in the port, so that any future caller sees the v2.05 results.
Port: kept bit for bit in the strict image. Production image (IMP-14 is the first caller with data-dependent operands):
`dsqrt` answers a negative operand as IEEE 754 requires (-0 gives -0, a negative NaN is returned quiet, every other
negative operand gives the default quiet NaN, no errno) and the 64-bit divisions give a zero divisor a defined result
(unsigned quotient all ones, signed quotient -1, remainder = dividend); verified against the strict image for 4000
non-negative square roots and 12000 non-zero divisions (identical) and for the special operands. The float divide, float
add/subtract and double add/subtract cases stay as v2.05 (no caller reaches them).

### OF-52 — battery conversion does not match the hardware divider
Hardware (wire-traced, `analysis/frontend_netlist.md` sections 7 and 9): B+ (BAT1 through the dial contact) - R69 1M -
PA5 - R70 330k - VSS, ratio 330/1330 = 0.2481 at printed values; the ADC reference VDDA = VREF+ is the VDD_P rail,
NJU7200U33, 3.300 V typical (NJU7200 data sheet p4), so ADC code = B+ x 0.2481 / 3.3 x 4095 = B+ x 307.9.
Firmware: `adc_ch5_process` (`0x080134DA`) clamps the code to 0x3FC..0xC30 and converts it with `FUN_08013728` (table
0x08028C9C, T[i] = 3120 - 140 i; value = 1050 - 50 i + 50 (code - T[i]) / 140, in 0.01 V), i.e. code / 280 - 0.643 V;
the low-battery flag is set below 41 (4.1 V) (`0x0801353A cmp #0x29`). The firmware line and the hardware line cross
at 6.4 V.
Execution check (the original `FUN_08013728` under Unicorn, codes from the hardware relation): B+ 4.00 V -> 3.75 V
(-6.2 %), 4.10 V -> 3.86 V, 4.31 V -> 4.09 V, 5.00 V -> 4.85 V (-3.0 %), 6.00 V -> 5.95 V, 6.40 V -> 6.39 V,
8.00 V -> 8.15 V, 9.50 V -> 9.80 V (+3.2 %).
Impact: the battery voltage shown is up to 6 % low near the end of the battery's life, and the low-battery symbol (and
everything tied to the flag) appears when B+ falls below 4.31 V, not 4.1 V. The figures use printed nominal values;
part tolerances shift them, a comparison of display and measured battery voltage on a meter confirms them.
Port: convert with the hardware relation (code x 3.3 / 4095 / 0.2481), keeping the 4.1 V threshold.

### OF-53 — HY3131 interrupt flags lost between the status read and the clear
`hy3131_service_irq` reads the 0x34-byte status burst from register 0, INTF included (`0x08006150`..`0x08006158`,
`bl 0x0800C0C0`), then writes one byte 0 to register 0x1E, INTF (`0x0800615C`..`0x0800616C`, `bl 0x0800C03C`). Writing
0 clears the flags (HY3131 data sheet p19, 10.2 (7)), including any flag the chip raised after the burst read, which
the firmware has not seen. A lost counter-done flag (CTF) means FUN_0800AA00 is not called and the counter is not
restarted, so the frequency reading stops updating until the next mode/range apply re-arms the counter.
Execution check (emulator, original image): in acv_values the count completes at 6.501886 s, after the INTF byte was
read (6.501460 s) and before the clear completes (6.503092 s); no counter restart follows until the re-apply at 7.43 s.
Over 93 scenarios of the scenario library (all but apo_disabled and apo_timing_wake) v2.05 lost the counter-done flag
30 times in 10 scenarios.
Impact: the frequency shown on the sub display (AC modes) or the main display freezes for up to the next apply; which
event is lost depends on sub-millisecond timing.
Port: clear only the flags that were read: write a value that is 0 for the flags seen set in the burst and 1 for all
other flags (INTF bits are cleared only by writing 0, data sheet p19), so no flag raised after the read is discarded.

### OF-54 — counter completion seen together with stale counter values
`hy3131_service_irq` reads the 0x34-byte status burst in register order (`0x08006150`..`0x08006158`), so the counter
registers CTA/CTB/CTC (0x15..0x1D) are read before INTF (0x1E). If the count completes after the counter registers
were clocked out and before INTF is, the firmware sees CTF set but computes the frequency from the values read before
completion (`counter_compute_frequency` wrote 0 to 0x20007C40 in the observed case); the frequency range byte
0x2000803E then drops to 0 and the AC frequency correction is evaluated for that frequency. Related to OF-53 (same
burst/clear sequence) but a distinct effect: a flag seen with stale data rather than a lost flag.
Execution check (emulator with the HY3131 model, original image): ACV, 2.3456 V at 1000 Hz shows 2.3334 (-0.52 %) for
about 0.45 s after such an event; the same episodes occur at other timings. What the real chip returns in the counter
registers while a count is running is not stated in the data sheet (the model returns the values of the last completed
count), so the size of the error on hardware is unproven; the inconsistency itself follows from the read order.
Impact: occasional short wrong AC readings (-0.5 % observed) and a wrong frequency value.
Port: read INTF first (or read the counter registers again after seeing CTF) so that counter data and the flag belong
to the same completed count; together with the OF-53 fix.

### OF-55 — backlight flag survives an auto power-off, the first MODE long press after the wake does nothing visible
The MODE long press (`0x080162E4`..`0x0801631A`) toggles the RAM flag 0x2000807B and drives PE8 (GPIOE BSRR bit 8): flag 0 -> 1 with
PE8 high, flag 1 -> 0 with PE8 low. The only references to the address of that flag in the image are the three loads of this
routine (literal pool word `0x08016C84`, listing references `0x080162E4`, `0x080162F0`, `0x0801630C`). The power-down before
a STOP (`power_down_peripherals` `0x0801C584`, PE8 low at `0x0801C596`) and the start-up after the wake (`FUN_08024DE0`,
which resets the run state but does not store to this flag) leave it as it was, so with the backlight on at the power-off
the flag is still 1 while PE8 is low.
Execution check (emulator booted through the bootloader image, original v2.05 image, dial on V, auto power-off enabled): MODE
long press: PE8 high, flag 1. The APO counter 0x20000230 put to 3: the meter powers down (PE8 low, flag 1). A dial change
wakes it: PE8 low, flag 1. First MODE long press: PE8 stays low, flag 0. Second: PE8 high, flag 1.
Impact: after every wake that followed a power-off with the backlight on, the backlight needs two long presses of MODE.
Port: `set_state_reset` clears the flag at power-on and after the wake, so the flag follows the pin and the first MODE long
press switches the backlight on (fast build: `pwr_bl_reset`, which also clears the auto-off countdown of IMP-07; strict
build: the flag alone, since 2026-11-03).

### OF-56 — type K table entry at 270 degC is 1 uV low
The type K table at 0x08025CF8 (158 x s32 uV at 10 k - 210 degC) was compared with the NIST ITS-90 type K table
(https://its90.nist.gov/downloadFiles/type_k.tab.txt) by `firmware/tools/gen_tc_tables.py`: 157 entries are equal, entry 48
(270 degC) holds 10970 where NIST tabulates 10.971 mV.  The NIST reference function gives 10970.95 uV at 270 degC, so the
v2.05 value is the function truncated instead of rounded.  Effect: between 260 and 280 degC the interpolated temperature is
at most 1 uV / 41 uV per degC = 0.024 degC high.
Port (both builds): `firmware/tools/gen_tc_tables.py` writes the NIST K table as `mtmp_tc_tab_k` (`src/mtmp/tc_tables.s`, stops
unless the only difference from the v2.05 table is this entry); the conversion (`temp.s`) and the cold junction
(`thermistor.s`) use it, the v2.05 table stays in the image unreferenced.  The emulator's thermocouple probe uses the NIST
tables for K as for J and T (`emulator/emu/tc_nist.py`).

### OF-57 — SD addresses wrap at 4 GiB
`disk_read` (`0x08023F7E`) passes the byte address `sector << 9` (`0x08023F96 lsls r2,r5,#9`) with the upper word 0
(`0x08023F98 movs r3,#0`); `disk_write` (`0x08023FB8`) computes `(first << 9) + 512 * i` in 32 bits (`0x08023FE4`..`0x08023FEA`)
and passes 0 as the upper word (`0x08023FFC`).  The driver itself handles 64-bit addresses: for an SDHC card
(`sd_card_type == 2`, the CCS bit of ACMD41) `FUN_08022FCE` / `FUN_08023100` shift the 64-bit address right by 9
(`0x0802300E`..`0x08023014`, `0x08023144`..`0x0802314A`).  Sector bits 23..31 are lost, so sector N >= 2^23 is accessed as N mod 2^23.
Execution check (emulator, `emulator/scripts/test_sd_large_card.py`, 8 GiB card image whose free clusters all lie above 4 GiB,
logging for 70 s): v0.9.2 production image (v2.05's code here) wrote the file data into sectors 8384512.. (the 4 GiB alias), the
file read back as zeros and the CSV had no rows.  Whether a card filled from the bottom ever reaches 4 GiB in normal use
depends on how full the card is.
Impact: on SDHC / SDXC cards larger than 4 GiB a write past 4 GiB corrupts the FAT, the directory or older files.
Port (both builds): the 64-bit byte address `(sector + i) * 512` (`src/sd/diskio.s`).  Checked at 8, 32, 128 GiB and at the
largest FAT32 volume, 2 TiB - 1 MiB (writes at sector 4 294 948 864): file complete, the alias sectors untouched.

### OF-58 — every file is dated 2006-02-09 22:30
`get_fattime` (`0x0802402E`) returns the literal at `0x08024034`, 0x3449B3C0: FAT date 0x3449 = 2006-02-09, time 0xB3C0 =
22:30:00, the value of FatFs's sample code.  `f_open` writes it as the creation time (directory entry bytes 0x0E..0x11,
`0x08021C56`), `f_sync` as the modification time (bytes 0x16..0x19, `0x08022218`, every close or sync).  `log_set_file_time`
(`0x0801D37C`) sets only the modification time from the clock chip, after a session; the creation time stays 2006 for good,
and a file whose last session did not reach the correction (power cut between the close and the correction) keeps a 2006
modification time.  Execution check (emulator, v0.9.2 production image, which has v2.05's code here, one logging session,
directory entry read from the card image): created 2006-02-09 22:30:00, modified at the clock chip's time.
Impact: wrong file dates on the PC.
Port (both builds): `get_fattime` builds the FAT date and time from the calendar copy of the clock chip (0x200080D7..DC), as
`log_set_file_time` does; 1980-01-01 00:00:00 (the first FAT date) while the copy holds no valid date.

### OF-59 — SD errors are not passed on
- `disk_initialize` (`0x08023F5C`) returns the `sd_init` result as the disk status; FatFs's `chk_mounted` tests only bit 0
  (STA_NOINIT, `0x080217CE`..`0x080217D4`), so an `sd_init` failure with an even code (2 CRC fail, 4 timeout, 6, 0xE, 0x10,
  0x26) counts as a ready card.  (`sd_probe_mount` `0x0801F8BA` also discards the result of its own `sd_init`, `0x0801F8C4`;
  the mount is lazy and repeats the initialisation in `chk_mounted`, which is where the result now counts.)
- `disk_read` takes the buffer as soon as CMD13 reports the transfer state; it neither waits for the SDIO data end and the
  DMA end nor looks at the SDIO error code `sd_transfer_error` (0x200080F7), so a block with a CRC error is used as read.
- `disk_write` ignores the SDIO error code and the return value of `sd_wait_write` (`0x08024000`..`0x08024008`): a block the
  card refused with a negative CRC status token counts as written.
Execution check (emulator, `emulator/scripts/test_sd_errors.py`, the card model's test fault 'write_crc' = one block arriving
with a CRC error at the start of logging): v0.9.2 production image: rows 1..8 missing from the file and zero bytes in their
place, no error reported; with the card refusing every write from the first flush on, v0.9.2 kept
logging and showed no error, and the file held 1541 bytes after 87 s of 1 s records.
Impact: silent loss or corruption of logged data after a single disturbed transfer.
Port (both builds, `src/sd/diskio.s`): `disk_initialize` returns STA_NOINIT for any `sd_init` failure; `disk_read` waits for
the data end and the DMA end (at most 20000 polls) and returns RES_ERROR on an SDIO error or a timeout; `disk_write` keeps
v2.05's sequence (the card is polled back to the transfer state) and returns RES_ERROR when the SDIO reported an error or
`sd_wait_write` failed.  Both also look at the data error flags of SDIO_STA (0x23A: DCRCFAIL, DTIMEOUT, TXUNDERR, RXOVERR,
STBITERR; `disk_read` clears them before each block, `sd_wait_write` tests them before it clears all flags): the interrupt
handler serves DATAEND first and then masks every source (`0x08023476`..`0x0802351A`), so an error flagged together with or
after DATAEND would otherwise not be seen.  Whether the SDIO block sets DATAEND together with DCRCFAIL is not stated in
RM0038; the flag test covers both orders.  The log's retry path then repeats the session.  Together with OF-64 the same test gives one
complete file, rows 1..N without a gap, for a disturbed write and a disturbed read.

Port correction (fast build, 2026-11-04, found with the Bluetooth file transfer of IMP-28): on a meter the SDIO
"data end" notification (`sd_transfer_end`, set by the SDIO interrupt on DATAEND) was sometimes never seen after a block
read, while the DMA end was seen, SDIO_STA held no error flag and the hardware counters showed the block complete
(SDIO_DCOUNT = 0, DMA2 channel 4 CNDTR = 0): 16 of the reads of one 155 kB transfer.  The OF-59 wait for both
notifications then failed the read (FatFs: disk error), so card writes (FatFs reads the FAT while it writes) and the
read-back check failed now and then, although every byte on the card was right (files compared on a computer).  v2.05
never waited for the notifications, so it never saw this.  `disk_read` now takes such a block on the hardware counters
(no error flag, DCOUNT 0, CNDTR 0) and counts it (`sd_dg_recov`); why the DATAEND notification is missed is not known
yet (the emulator does not reproduce it).  Verified working on a meter: the 155 kB transfer then ran with 0 failed
card sessions and 16 reads taken on the counters, and `EEVBlog.bin` was written and verified.

### OF-60 — the file forced after 20 failed attempts has no header
`log_session_once` sets the header due (0x20008026) after creating a file only while the forced-file counter 0x20007FAE is 0
(`0x0801D202`..`0x0801D214`).  `log_force_new_file` (`0x0801D51A`) increments that counter, so the file it starts after 20
failed attempts begins directly with data rows.
Impact: a CSV without its header lines.
Port (both builds): every newly created file gets the header.  Execution check (`test_sd_errors.py`, the card refusing every
write until the logger has started its second series): two files, both with the START header, rows 1..N without a gap.

### OF-61 — the final write failure leaves the range frozen
After both series of 20 attempts fail, the main loop clears the logging flag 0x20007FE1, powers the SD block off and leaves
the MEM view (`0x08024D6A`..`0x08024D74`) without calling `log_stop` (`0x08010AF8`).  `log_stop` is the routine that undoes
the range freeze of the logging start (range_manual = range_manual_saved, `0x08010B50`..`0x08010B5E`), saves the counters and
the stop time (`0x08010B00`, `0x08010B04`) and rebuilds the MEM view window (`0x08010B42`).
Impact: after a card failure the meter stays in manual range; the MEM view and the saved counters miss the session.
Port (both builds): `log_stop(0)` before the flag is cleared (the rows cannot be written: the card failed 40 times).
Execution check (`test_sd_errors.py`, card refusing every write): logging stops, range_manual back to 0 (autorange).

### OF-62 — the RAM variant flags do not follow a calibration marker
The boot sets 0x20008087 = (EEPROM 0x01F != 0xA5) and 0x20007FE0 = (EEPROM 0x026 != 0xA5) (`0x08024DE6`..`0x08024DF4`).
`FUN_0800F7B8` writes marker 0x1F after the ACV range-0 calibration (`0x0800F896`) but leaves 0x20008087 alone, so the CORR70
correction of ACV range 0 (`0x080074F8`, `0x0800767A`) stays as it was until the next power-on or wake.  The Ohm range-6 branch
writes marker 0x26 (`0x0800F8AE`) and stores 1 into 0x20007FE0 (`0x0800F8B2`..`0x0800F8B8`), the opposite of what the next boot
reads; that branch is not reached (FUN_0800F7B8 does not run in mode 9, analysis/hy3131_modes_misc.md DEF-13).
Impact: readings in ACV range 0 right after its calibration differ from those after the next power-on.
Port (both builds): after each marker write the flag is read back with the boot's own routine (`fn_080104BC`, `fn_08010F10`).

### OF-63 — the buzzer setting does not silence every beep
The setting (EEPROM 0x01E, RAM 0x20008078) is tested by `FUN_0800EEA8` (`0x0800EEB6`; key and mode beeps) and by the TIM3
repeat pulses (`0x080247C8`..`0x080247D4`).  `pe7_on_with_timeout` (`0x0800EED0`) drives PE7 without that test; it serves
continuity (`0x08007904`, `0x08007922`), the diode short-circuit tone (`0x08007F10`), the auto-hold capture beep (`0x0800E562`),
the jack and high-voltage warnings (`0x0802469E`) and the auto power-off warning (`0x08024D0E`); the 1 s power-off beep sets PE7
directly (`0x08024F12`).  The manual says only "disable/enable the buzzer"; which beeps should stay is not documented.
Execution check (`emulator/scripts/test_buzzer_off.py`, buzzer off, diode short): v0.9.2 image: PE7 high in 3965 of 4000
samples.
Port (both builds; owner decision 2026-11-03): with the setting off the diode, auto-hold capture, auto power-off warning and
power-off beeps are silent (`fn_0800EEA8`, and the power-off beep's PE7 gated); continuity and the jack and high-voltage
warnings still sound (a continuity tester and the safety warnings).

### OF-64 — FatFs R0.08a error paths (fixed by ChaN in R0.10a..R0.10c)
The file system is FatFs R0.08a.  ChaN's later releases fixed error paths that the v2.05 code still has (sources compared:
ff8a, ff10a, ff10b, ff10c from elm-chan.org):
- `f_write` (`0x08021FE8`..`0x08021FEE`) stores the result of `create_chain(0)` as the file's first cluster before testing
  it for 0, 1 and 0xFFFFFFFF; after a disk error `f_sync` / `f_close` write 0xFFFFFFFF into the directory entry (R0.10b:
  "Fixed a hard error in the disk I/O layer can collapse the directory entry").
- `create_chain` (`0x08021014`..`0x08021026`) takes a disk error of `get_fat` (0xFFFFFFFF) as the end of the chain and links a
  new cluster behind the entry it could not read (fixed without a changelog line in R0.10a).
- `move_window` (`0x08020C54`..`0x08020C5E`) keeps the old sector number after a failed read although the read may have
  overwritten part of the window; `put_fat` (`0x08020F70`) marks the window dirty also after a failed load, so a stale or
  invalid window could be written back (R0.10c: "Fixed a potential problem of FAT access that can appear on disk error").
These paths are reached only on a disk error, which v2.05 never reports (OF-59); with OF-59 fixed they are reached.
Execution check (`test_sd_errors.py` with the OF-59 fix but without these): a disturbed write left a directory entry with
start cluster 0xFFFFFFFF and size 0, the retries could not reopen it and a second file was forced.
Port (strict build, `src/sd/fat.s`, `src/sd/fat_file.s`): the four changes above as in R0.10a..R0.10c (window invalid =
sector number 0xFFFFFFFF).  The production build runs FatFs R0.16 with patches 1 and 2 instead (DESIGN.md 7A, IMP-29),
which contains these fixes.  Kept as v2.05 in both builds (R0.16 does the same in sync_window and sync_fs): the write results of the second FAT copy and of the FSInfo sector are not checked
(the first FAT is the one read back).

### OF-65 — the status frame's bar byte exceeds the display's 25 segments on an overload
The frame builder (`0x0800C7B6`..`0x0800C7C0`) copies the bargraph count 0x20008041 into byte 14 unchanged.  The display lights
segments 1..25 when the count is at least their number (`lcd_update_bargraph` `0x08018B80`), so every count from 25 up looks the
same; on an overload the count is larger: 45 in the emulator (v2.05 image, DCV manual range 0, 9.0 V) and 46 / 55 on a meter
(DCV range 0 with a 9.35 V battery; BEEP with open probes), read over Bluetooth.  The official application takes the bar value
as `& 0x1F` (analysis/ble_packet.md 3), so 46 reads as 14 segments.
Impact: a wrong bargraph in applications during an overload.
Port (both builds): byte 14 = min(count, 25), the segments the display shows.

### OF-66 — the SD DMA needs a word-aligned buffer
disk_read (FUN_08023F78) and disk_write (FUN_08023FB8) pass the FatFs buffer address unchanged to the block read and write,
which set it as the memory address of DMA2 channel 4 with 32-bit items.  RM0038 11.4.5 / 11.4.6: the DMA aligns each access
to the item size ("access is automatically aligned"), so with a buffer at an address that is not a multiple of 4 the words go
to or come from the aligned-down address: 1..3 bytes off, and the bytes before the buffer are overwritten on a read.  FatFs
hands the caller's own buffer to disk_read / disk_write for every whole sector of an f_read / f_write, and nothing makes that
buffer aligned.  Found with the SD file requests of IMP-36 (a READ at file offset 12345 into the aligned staging buffer puts
the whole sectors at an odd address): the data differed from the file.
Port (production): a sector whose buffer is not word aligned goes through a 512-byte aligned buffer (sd_bounce), copied byte
by byte; aligned buffers keep the direct DMA.

### OF-67 — a long MEM at power-on starts logging and breaks the cal.bin sequence
The cal.bin backup and restore start with MEM pressed inside the power-on window: the short-press handler fires on the
press (key_win_b = 1, "SdCAL", window 5000 ticks).  Held on past the long-press time, the same press is also handled as a
long MEM: logging is toggled (fn_0801657C).  REL / PEAK still show "SdSAv" / "SdSEt", but the MODE that should confirm does
nothing useful, and the card gets a log file instead of cal.bin.  Measured in the emulator with the comparison harness on
v2.05 and the port: MEM held 1.5 s at power-on, then REL and MODE: both images wrote 26010100.CSV and no CAL.BIN; MEM held
0.4 s: both saved.  Found on a meter (2026-11-05): holding MEM while turning the dial on is the natural way to do it.
Port: while the sequence is under way (key_win_b 1..3) the long MEM is ignored.

### OF-68 — the capacity of a card above 4 GiB wraps
sd_get_card_info (v2.05 FUN_08022AE4, 0x08022CBC..0x08022CC6) stores the capacity of a high-capacity card (CSD version
2.0) as (C_SIZE + 1) * 0x80000 with a 32-bit `muls` and a zero high word, so a card above 4 GiB gets the remainder: a 32 GB
card (C_SIZE 60871) reads as 1 849 688 064 bytes (1.72 GiB).  v2.05 never used the value (its disk_ioctl answered
GET_SECTOR_COUNT with the constant 0x20000).  The port's disk_ioctl hands the capacity to f_mkfs (IMP-32), so a card
formatted on the meter (page `Fr`) got a 1.72 GiB volume.  Found on a meter (2026-11-05): a 32 GB card formatted on the
meter showed 1.72 GB total in the Companion.  Port: the capacity is (C_SIZE + 1) << 19 as a 64-bit value.  Emulator
`test_sd_capacity.py`: a 32 GB card holds the full 31 914 459 136 bytes in the record (v1.0.7: 1 849 688 064).
A card already formatted this way keeps its small volume until it is formatted again.

### OF-69 — card sessions on the 4 MHz crystal, PLL VCO 48 MHz
FUN_0801BF1A(1) (0x0801BF5C..0x0801BF6E) switches SYSCLK to HSE for every card access; the PLL set up at reset
(SetSysClock, HSE x12 /3, 0x08026066..0x0802607C) gives a 48 MHz VCO and so SDIOCLK = VCO / 2 = 24 MHz.  RM0038 6.2: "If
the USB or SDIO interface is used ... the PLL VCO clock ... must be programmed to output a 96 MHz frequency".  With
HCLK 4 MHz and SDIO_CK 8 MHz (ClockDiv 1) the CPU has 16 cycles per 32-bit word the SDIO sends.  On a meter
(2026-11-05, the port F-1.08 .. F-1.11, which keeps this clock plan, 32 GB SanDisk card) block writes stopped with
TXUNDERR after DMA2 channel 4 had moved 3 of 128 words, and the card format failed.  Experiments on the meter: ClockDiv 4
(SDIO_CK 4 MHz) passed, a card clock held off until the FIFO was full passed (170 s per format), a delay after the DMA
start failed.  How v2.05 itself behaves with this card was not tested.  Port (IMP-41): a card session runs on the PLL,
HSE x24 /3 = 32 MHz, VCO 96 MHz, SDIOCLK 48 MHz.  Verified working on a meter: three formats in 16 s each, logging and a
download without a failed block.

### OF-70 — the reset clock set-up raises the clock 7.6-fold in one step
SetSysClock (0x08026092..0x080260A8) selects the PLL (16 MHz) while the CPU runs on MSI at 2.097 MHz.  RM0038 6.2.7 note:
"the final frequency is less then 4 x initial frequency to limit the VCORE drop due to a current consumption peak when
the frequency increases. It must also respect 5 us delay between two changes" (the same rule as datasheet Table 4 note
2).  Port: SW = PLL is written together with HPRE = /2 (8 MHz, 3.8 x), then after at least 5 us HPRE = /1 (16 MHz, 2 x).
No failure on a meter has been traced to this.

### OF-71 — an overrun with RXNE clear is never cleared, the receive interrupt repeats for ever
The USART2 handler (IRQ38_Handler 0x080247D8..0x080248AE) asks `USART_GetITStatus(USART2, 0x525)` (call 0x08024826) and
ends at 0x080248AE (`beq`, 0x0802482C) when the answer is 0. FUN_0801CC7C (0x0801CC7C..0x0801CCEA) answers 1 only if
CR1 bit 5 (RXNEIE: `ldrh r2,[r3,#0xc]` 0x0801CCAC, mask 1 << (0x525 & 0x1F)) and SR bit 5 (RXNE: `lsrs r2,r2,#0x8`
0x0801CCC4, `ldrh r2,[r3,#0x0]` 0x0801CCD0) are both set. USART_DR is read only after that check (FUN_0801CC00,
`ldrh r0,[r0,#0x4]` at 0x0801CC00, called at 0x08024830). The initialisation enables only this interrupt
(`movs r2,#0x1` 0x0801C426, `movw r1,#0x525` 0x0801C428, FUN_0801CC08 at 0x0801C430; the handler's TXE part uses 0x727).
RM0038 27.3.3 (rm0038.txt lines 39425-39448) says of an overrun: "An interrupt is generated if either the RXNEIE bit is
set or both the EIE and DMAR bits are set" and "The ORE bit is reset by a read to the USART_SR register followed by a
USART_DR register read operation"; the note adds that ORE can be set with RXNE = 0: "if RXNE=0, then it means that the
last valid data has already been read ... It may also occur when the new data is received during the reading sequence
(between the USART_SR register read access and the USART_DR read access)". The same follows from the ORE bit
description (27.6.1, lines 41229-41232: "An interrupt is generated if RXNEIE=1 in the USART_CR1 register. It is cleared
by a software sequence (an read to the USART_SR register followed by a read to the USART_DR register)").
So v2.05 has the same structure as the port had until F-1.14: with ORE = 1, RXNE = 0 and RXNEIE = 1 the interrupt line
is active, the handler finds RXNE clear, returns without reading DR, and is entered again at once; nothing else in the
handler clears ORE (the handler never reads the ORE bit). A byte arriving at the moment the handler reads the last
byte is enough to reach this state; at 19200 baud one byte lasts 0.52 ms. Not observed on a meter; found by
reading RM0038 against the handler. Port (F-1.15): `ble_usart2_isr` (`ble/usart.s`) reads SR once; with RXNE = 0,
ORE = 1 and RXNEIE = 1 it reads DR once (the sequence that clears ORE), drops the lost byte and counts the overrun for
the extended link diagnosis (IMP-44); every other path is unchanged. Emulator `test_ble_overrun.py` puts the state
RXNE = 0, ORE = 1 in place with the USART model (a byte arriving between the SR read and the DR read) and checks that ORE
is clear 50 ms after the interrupt is enabled (F-1.14: it stays set).

### OF-72 — the USART_Init fraction loses its carry
`fn_0801CAEC` (USART_Init of the StdPeriph library, 0x0801CAEC..0x0801CBD0) computes r7 = 25 x PCLK / (4 x baud)
(0x0801CB74..0x0801CB7E, 100 x USARTDIV), the mantissa r7 / 100 shifted into bits 15:4 (0x0801CB84..0x0801CB8C), then the
fraction ((r7 mod 100) x 16 + 50) / 100 (0x0801CBB6..0x0801CBBE) and masks it with `ands r0, r0, #0xf` (0x0801CBC2) before
the `orrs` into BRR (0x0801CBC6); with OVER8 the same with x 8 and `& 7` (0x0801CBA0..0x0801CBB0). When the fraction rounds
up to 16 (8 with OVER8) the mask makes it 0 and the mantissa is not raised: BRR is one mantissa step too low. RM0038 27.6.3
defines BRR as DIV_Mantissa[11:0] in bits 15:4 and DIV_Fraction[3:0] in bits 3:0 (USARTDIV = mantissa + fraction / 16), so
the rounded value 16 / 16 belongs to the mantissa. For 19200 baud the case is PCLK1 = 4.2916 .. 4.3008 MHz: BRR 208 instead
of 224, 20649 baud instead of 19174 (+7.5 %). v2.05 always passes the nominal MSI value 4.194304 MHz (fn_0801FE2A, BRR 218),
so the case cannot happen there; the port's measured clock (IMP-46) can be in that window (MSI +2.3 .. +2.5 %, inside the
data sheet's temperature drift). Port: the fraction is added to the mantissa field instead of masked and or-ed (a fraction of
16 carries into bit 4; with OVER8 a fraction of 8 becomes mantissa + 1, BRR bit 3 stays 0). Emulator `test_msical.py` C5.

### OF-73 — after auto power-off the restart hangs in a timer interrupt
`FUN_0801C92E` (0x0801C92E, called by the STOP preparation `FUN_0801C522` at 0x0801C528) disables TIM2 and TIM3
(TIM_Cmd) and then their clocks (RCC_APB1PeriphClockCmd), but leaves DIER.UIE set and does not clear SR.UIF.  An update
flag that is set at that moment keeps the timer's interrupt request asserted through STOP.  After the EXTI wake the
restart (`FUN_0801BE76`, called at 0x08024EEE) enables IRQ28 / IRQ29 in the NVIC (`FUN_0801BFDE`) while interrupts are
not masked (v2.05 never masks them); the handler clears UIF by a write to TIMx_SR, which has no effect while the timer's
clock is gated, so the level request stays and the handler is entered again at once, for ever.  The timers' clocks are
switched on only later in the restart (0x0801BF0C, 0x0801BF10).  On a meter with the port (F-1.17, the same sequence),
2026-11-07: a beep placed right after the STOP exit sounded on a key press, beeps after each restart step stopped
inside the NVIC set-up, and only the dial off and on restarted the meter (a power-up: the dial OFF position removes the
battery supply).  Not tested with v2.05 on a meter.  Port (F-1.18): `fn_0801C92E` clears DIER and SR of both timers
while their clocks still run.  Emulator `test_apo_wake.py`.
