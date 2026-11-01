# EEVblog 121GW — open firmware port and emulator

| Folder | Content |
|---|---|
| `firmware/` | new firmware for the 121GW (STM32L152ZD) in hand-written Thumb-2 assembly, loaded by the meter's existing bootloader at 0x08006000 |
| `emulator/` | emulator of the 121GW with a front-panel UI, used to run and test firmware without hardware |

## Firmware
- Build (GNU binutils arm-none-eabi): `cd firmware && make` (production) or `make LOOP_V205=1` (strict build that
  behaves like v2.05 apart from the defect fixes). `make check` runs the never-brick, HY3131-configuration and
  pin-policy checks. Output: `firmware/build/EEVBlog.bin`.
- `DESIGN.md` design and deviation list, `EEPROM_MAP.md` every EEPROM byte, `ORIGINAL_FIRMWARE_ISSUES.md` the defects
  found in v2.05 (with evidence), `OPTIMIZATIONS.md`, `HARDWARE_TEST.md` checklist for the first run on a meter.
- Status: both builds match v2.05 in the emulator's 93 test scenarios and the STOP/wake scenario except documented
  deviations; not yet run on hardware. The strict build is compared frame by frame; in the production build the
  display during range changes is checked by the scenarios' assertions and final states.

## Emulator
- `cd emulator && python app.py --inputs <dir> --eeprom <eeprom image> [--sdcard <image>] [--app <firmware.bin>]`, then open
  http://127.0.0.1:8121. Needs Python 3 with unicorn, capstone and numpy; the original bootloader and v2.05 image are
  not included: `<dir>` must hold `bootloader.bin`, `EEVBlog2_05.bin` and `option.bytes` read from a meter.
- `emulator/diff/run.py` compares two firmware images scenario by scenario (see its docstring).

## Licence

Free to use, modify and share; selling or bundling only by zombu4 and EEVblog (David L. Jones). See `LICENSE`.
