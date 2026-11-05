121GW two-part bootloader: firmware and bootloader updates over Bluetooth from the 121GW Companion, no card and no keys needed; the card update (MEM + HOLD, then SETUP) keeps working, now with a 30 s window and from FAT or exFAT cards.

Assets of this release
- `bootloader-<tag>.zip`: `install.bin` (the first install, sent by the companion to firmware F-1.03 or newer on the page Ld), `blimage.bin` (the bootloader image the companion sends to an installed bootloader), `starter.bin`, `README.md` (what it does, how to install and update, what the display shows), `LICENSE` and `SHA256SUMS`.
- `*.sha256`: checksum of the file with the same name.

Install it with the companion: it offers the bootloader when the meter reports EEVblog's original one, and checks the meter, the battery (at least 4.80 V) and the file before anything is written. See `README.md` in the zip or `bootloader/README.md` on the branch `bootloader`.

Never writes the data EEPROM (calibration, serial number, settings) or the option bytes. Verified working on a meter. Flashing is at your own risk (see `LICENSE`).
