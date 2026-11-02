# 121GW-Open-Firmware — EEVblog 121GW open firmware port and emulator

<p align="center"><img src="emulator/ui/assets/logo_anim.gif" alt="121GW running this firmware in the emulator" width="300"></p>

| Folder | Content |
|---|---|
| `firmware/` | new firmware for the 121GW (STM32L152ZD) in hand-written Thumb-2 assembly, loaded by the meter's existing bootloader at 0x08006000 |
| `emulator/` | emulator of the 121GW with a front-panel UI, used to run and test firmware without hardware |

## Downloads

Every release (tag `v*`, see [Releases](../../releases)) carries:

| File | Content |
|---|---|
| `firmware-<tag>.zip` | `2_fast/EEVBlog.bin` (production build), `1_like_v2.05/EEVBlog.bin` (strict build that behaves like v2.05 apart from the defect fixes), `FIXES.md` (the v2.05 defects fixed), `LICENSE`, `SHA256SUMS` |
| `121GW-Open-Firmware-Emulator-<tag>-macos-arm64.dmg` | emulator for macOS (Apple Silicon) |
| `121GW-Open-Firmware-Emulator-<tag>-windows-x64.exe` | emulator installer for Windows |
| `121GW-Open-Firmware-Emulator-<tag>-linux-x86_64.AppImage` | emulator for Linux |
| `<file>.sha256` | SHA-256 of the file with that name |

No file of a release contains an original EEVblog image (bootloader, v2.05) or the calibration of any meter.

## Firmware
- Build (GNU binutils arm-none-eabi 2.46, the `Makefile` refuses other versions): `cd firmware && make` (production) or
  `make LOOP_V205=1` (strict build that behaves like v2.05 apart from the defect fixes). `make check` runs the never-brick,
  HY3131-configuration and pin-policy checks and needs the original v2.05 image in `inputs/` (not in this repository);
  `make check-ci` runs the checks that do not need it and names the ones it skips. Output: `firmware/build/EEVBlog.bin`.
  `sh firmware/tools/build_dist.sh <dir>` builds both variants into the layout of the release archive.
- CI (`.github/workflows/firmware.yml`): on every push and pull request both variants are built with GNU binutils 2.46.0
  (built from the release tarball, SHA-256 pinned; the packages of Ubuntu 24.04 and 26.04 are 2.42 and 2.45.50) and checked with `make check-ci`
  (`check_image`, `check_hy` against the committed reference data `firmware/tools/hy_reference.txt`, `check_gpio`; skipped:
  `gen_nvm_allow --check`, `gen_ram_symbols --check`, `extract_tables --verify`, which compare with the original image). On a
  tag `v*` the workflow publishes `firmware-<tag>.zip`.
- `DESIGN.md` design and deviation list, `EEPROM_MAP.md` every EEPROM byte, `ORIGINAL_FIRMWARE_ISSUES.md` the defects
  found in v2.05 (with evidence), `OPTIMIZATIONS.md`, `FEATURES.md` planned user-visible features (keys, display, storage; the backlight auto-off timer is
  implemented), `HARDWARE_TEST.md` checklist for the first run on a meter.
- Status: both builds match v2.05 in the emulator's 93 test scenarios and the STOP/wake scenario except documented
  deviations; not yet run on hardware. The strict build is compared frame by frame; in the production build the
  display during range changes is checked by the scenarios' assertions and final states.

### Flashing a meter from the SD card
The firmware has only run in the emulator. Read `firmware/HARDWARE_TEST.md` first; it is the procedure and checklist.
1. Before flashing: dump the data EEPROM over SWD and save `cal.bin` to an SD card with v2.05 (HARDWARE_TEST.md, "Before
   flashing"). Keep both: they hold the meter's calibration, serial number and settings.
2. Unpack `firmware-<tag>.zip`. Copy one `EEVBlog.bin`, unchanged, to the root of a FAT32 SD card: `2_fast/EEVBlog.bin` or
   `1_like_v2.05/EEVBlog.bin`. The bootloader looks for exactly this file name (FAT short names ignore case).
3. Run the manual's Firmware Update procedure (page 72, summarised in HARDWARE_TEST.md, "Flashing"). The bootloader
   (0x08000000..0x08005FFF) is not changed; it writes the application from 0x08006000. The data EEPROM is not touched.
4. First boot and checks: HARDWARE_TEST.md. To return to v2.05, flash the original image the same way; settings and
   calibration stay readable (same EEPROM layout).

## Emulator
- Release packages: macOS, open the `.dmg` and start `121GW Emulator` (the application is not signed with a developer
  identity or notarised, so macOS may ask for confirmation the first time: Control-click, Open); Windows, run the installer
  (it is not signed either, so SmartScreen may warn); Linux, `chmod +x` the `.AppImage` and run it. The application opens
  the front panel in the browser at http://127.0.0.1:8121.
- It contains both firmware builds (choose one in the page), runs them without any original image (direct boot from the
  application's vector table) and starts with a SYNTHETIC EEPROM: made-up nominal calibration, not the calibration of any
  meter, with no serial number. Never copy it, or a `cal.bin` written by the emulator, to a meter.
- From the source tree: `sh firmware/tools/build_dist.sh /tmp/dist none && python3 emulator/tools/prepare_data.py --dist /tmp/dist`
  once (fills `emulator/data`), then `python3 emulator/app.py` and open http://127.0.0.1:8121. Needs Python 3 with
  `unicorn` and `capstone`. Own files: `--eeprom`, `--bootloader`, `--option-bytes`, `--v205-image`, `--app`, `--sdcard`;
  the original images are not included: they are read from a meter.
- `emulator/API.md`: HTTP API (`GET /state`, `POST /input`), Python API, options, what direct boot does not reproduce.
- `emulator/diff/run.py` compares two firmware images scenario by scenario (see its docstring); it needs the original v2.05
  image as the reference.
- CI (`.github/workflows/emulator.yml`) builds the packages above on a tag and attaches them to the release.

## Licence

Free to use, modify and share; selling or bundling only by zombu4 and EEVblog (David L. Jones). See `LICENSE`.
