121GW-Open-Firmware: replacement firmware for the EEVblog 121GW and an emulator of the meter.

Assets of this release
- `firmware-<tag>.zip`: the two firmware builds as the meter's bootloader expects them (`1_like_v2.05/EEVBlog.bin`, the strict build that behaves like v2.05 apart from the defect fixes, and `2_fast/EEVBlog.bin`, the production build), `FIXES.md` (the v2.05 defects fixed), `LICENSE` and `SHA256SUMS`. Copy one `EEVBlog.bin` to the root of a FAT32 SD card and follow `firmware/HARDWARE_TEST.md` in the repository.
- `121GW-Open-Firmware-Emulator-<tag>-<platform>`: the emulator with its web front panel for macOS (`.dmg`), Windows (`.exe` installer) and Linux (`.AppImage`). It contains both firmware builds and a SYNTHETIC EEPROM image (made-up nominal calibration, not a meter's); no original EEVblog image and no calibration of any meter. The installers are not signed or notarised.
- `*.sha256`: checksum of the file with the same name.

The firmware has been run in the emulator only, not yet on a meter. Flashing is at your own risk (see `LICENSE`).
