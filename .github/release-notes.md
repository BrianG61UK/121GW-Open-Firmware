121GW-Open-Firmware, like v2.05 build: the original v2.05 behaviour of the EEVblog 121GW with the defects of v2.05 fixed.

Assets of this release
- `firmware-<tag>.zip`: `1_like_v2.05/EEVBlog.bin` as the meter's bootloader expects it, `FIXES.md` (the v2.05 defects fixed), `LICENSE` and `SHA256SUMS`. Copy `EEVBlog.bin` to the root of a FAT32 SD card and follow `firmware/HARDWARE_TEST.md` in the repository.
- `*.sha256`: checksum of the file with the same name.

This build lives on the branch `like-v2.05` and changes only when a v2.05 defect fix is made. The fast build with the new features and the emulator are the main releases (tags `vA.B.C`).

Verified working on a meter. Flashing is at your own risk (see `LICENSE`).
