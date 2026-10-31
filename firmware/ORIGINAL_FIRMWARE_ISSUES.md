# Issues found in the original 121GW firmware (v2.05)

Reference image: `EEVBlog2_05.bin`, SHA-256 `8f885f12f567c2cccd9862d9fe26f127e2a674c9afbce9f7a38d441b3f396722`
(identical to the official release `EEVBlog2_05.zip`), loaded at 0x08006000.

Every entry is proven from the original machine code; addresses are instruction addresses in that image
and can be checked with any disassembler. "Port" describes what this firmware does instead.
Status: **open** = documented, fix not yet implemented; **approval** = touches calibration/EEPROM
semantics, fix waits for owner approval; **fixed** = implemented and verified in the emulator.

## Summary

| ID | Area | Issue | Severity | Status |
|---|---|---|---|---|
| OF-01 | Table lookup | Stale index used when a table search fails | medium | open |
| OF-02 | Mode setup | Unset register values stored to globals for unhandled cases | medium | open |
| OF-03 | Mode setup | Unset register stored for out-of-range modes (two functions) | low | open |
| OF-04 | Multiplier path | Unset register passed to a float multiply for mode byte > 3 | medium | open |
| OF-05 | Mode helper | Unset register passed on for modes outside the handled set | low | open |
| OF-06 | GPIO set-up | Pin mask left uninitialised for unhandled arguments | high | open |
| OF-07 | Calibration | Save and load use different EEPROM locations in LowZ and BEEP | high | approval |
| OF-08 | Calibration | Entering calibration mode erases six current-offset records without confirmation | high | approval |
| OF-09 | Calibration | Current-extra store writes a value different from the one used in RAM | medium | approval |
| OF-10 | Bluetooth | Packet build and transmit are not synchronised; command echoes can interleave with status frames | medium | open |
| OF-11 | Bluetooth | First frame after enabling BT can carry stale buffer contents | low | open |
| OF-12 | Backup | `cal.bin` does not include the six current-offset records at EEPROM 0x4D0–0x4FF | medium | approval |
| OF-13 | ADC | ADC sample-time register rewritten while the ADC is on, against the reference manual | low | open |

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
is later loaded. Port: to be decided with the owner (fixing changes stored calibration semantics).

### OF-08 — calibration mode erases current-offset records without confirmation
Power-on, then MODE, then REL within the start-up window enters calibration mode and immediately calls
`FUN_0801150E` (`0x0800EAF6`), which rewrites the six records at EEPROM 0x4D0, 0x4D8, 0x4E0, 0x4E8,
0x4F0, 0x4F8 (marker 0xA5 + value 0). There is no confirmation step, and the user manual does not
mention it. Port: to be decided with the owner.

### OF-09 — current-extra store value
A long REL in modes 16..21 at range 0 stores `0x20007D64` to EEPROM (`FUN_080114BC`, called at
`0x0801645C`) while RAM uses `0x20007D64 + 0x20007E0C`. Whether this is intended is not provable from
the code. Port: to be decided with the owner.

### OF-10 — unsynchronised Bluetooth packet build/transmit
The status packet buffer at 0x20007AE0 is built in the main loop (`0x08024C0C`) and transmitted from
the TIM2 interrupt and the USART2 TXE interrupt, with no lock between them; command echoes are also
sent from the main loop and can interleave with a status frame. Port: single transmit queue.

### OF-11 — stale first Bluetooth frame
Enabling BT does not force a packet build, so the first frame can carry old buffer contents.
Port: build before the first transmit.

### OF-12 — incomplete calibration backup
`cal.bin` save/load (`FUN_0801CD14` / `FUN_0801CF06`) covers EEPROM 0x000–0x4AF only; the
current-offset records at 0x4D0–0x4FF (read by `FUN_08011448`) are not included. Port: to be decided
with the owner (extending the file changes the `cal.bin` format).

### OF-13 — ADC sample time changed while the ADC is enabled
RM0038 (rev. 15) section 12.15.6, ADC_SMPR3: "These bits must be written only when ADON=0."
The channel-configuration routine writes ADC_SMPR3 (0x40012414) at `0x080201F0` while CR2.ADON = 1,
every time the firmware switches between channel 4 (thermistor) and channel 5 (battery sense) via
`FUN_080137B4` (returns at `0x080137EE` / `0x080137FE`); observed 20 times in 4 s of emulated running.
Impact: behaviour outside the manufacturer's specification (the sample time may not take effect
cleanly for the next conversion). Port: configure sample times once with ADON = 0.
