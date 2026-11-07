The 121GW two-part bootloader: firmware and bootloader updates over Bluetooth from the 121GW Companion, nothing to press on the meter. The card update (MEM + HOLD at power-on, then SETUP) keeps working.

### Downloads

| File | What it is |
|---|---|
| `bootloader-<tag>.zip` | the bootloader files and their [README](https://github.com/zombu4/121GW-Open-Firmware/blob/bootloader/bootloader/README.md) |

Install it with the Companion: it offers the bootloader, and checks the meter, the battery and the file before anything is written. It never writes the calibration, serial number or settings. Flashing is at your own risk.
