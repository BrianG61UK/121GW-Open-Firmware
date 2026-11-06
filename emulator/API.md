# 121GW emulator: running it, HTTP API, Python API

The emulator runs the meter's firmware (STM32L152ZD core, HY3131 measurement chip, LCD, SD card, front panel) and shows
the front panel in a browser. Everything the page does goes through the HTTP API below, so a script can do the same.

Contents: 1 Starting, 2 Boot modes and bundled data, 3 GET /state, 4 POST /input, 5 POST /firmware, POST /quit, 6 Python API,
7 Errors and limits.

## 1. Starting

Release packages (macOS `.dmg`, Windows installer, Linux `.deb` / `.AppImage`; how to start them: `START.md`) run
`launcher.py`: the front panel opens in its own window on macOS and Windows (closing it stops the emulator) and in the
browser on Linux, or wherever the window cannot be made; the server listens on `http://127.0.0.1:8121` (the next free port
if 8121 is taken).  The packages take every option below and also `--browser` (the browser instead of the window) and
`--no-open` (neither).  From the source tree:

```
sh firmware/tools/build_dist.sh /tmp/dist none          # the v2.05 table data (GNU binutils arm-none-eabi 2.46 on PATH)
python3 emulator/tools/prepare_data.py --dist /tmp/dist # fills emulator/data (once)
python3 emulator/app.py [options]                       # then open http://127.0.0.1:8121
```

Needs Python 3 with `unicorn` and `capstone` (`pip install unicorn capstone`); nothing else.

| Option | Meaning |
|---|---|
| `--port N` (8121), `--port-tries N` (1) | listen on `127.0.0.1:N`, or the first free of N consecutive ports |
| `--open` / `--no-open` | open the browser when the server is up (packages open it unless `--no-open`) |
| `--no-ui` | no HTTP server (the process runs the machine only) |
| `--speed X` (1.0) | run rate: 1.0 is real time, 2.0 twice as fast (limited by the host's speed) |
| `--firmware 2_fast\|1_like_v2.05` | firmware build from the project's GitHub releases, fetched on demand (2.4; default `2_fast`); also selectable in the page |
| `--app FILE` | any application image (raw binary, loaded at 0x08006000) instead of a release build; in the page: **Load firmware file…** or drop the file (`POST /firmware`) |
| `--eeprom FILE` | EEPROM image, raw bytes from EEPROM offset 0 (default: the bundled SYNTHETIC image) |
| `--hw-cal FILE` | EEPROM image that describes the physical calibration of the emulated front end (default: the EEPROM as loaded at start) |
| `--sdcard PATH`, `--sdcard-mb N` (512) | SD card backed by the raw image file PATH (created and formatted FAT32 when missing, at least 64 MiB); without it the socket is empty |
| `--frontend calibrated\|netlist` | front-end model: `calibrated` (default) or the ngspice netlist model (needs ngspice and the analysis files, not part of the packages) |
| `--bootloader FILE` | boot through this bootloader image (raw, at 0x08000000) as a meter does, instead of direct boot |
| `--option-bytes FILE` | option bytes as an OpenOCD `mdb 0x1FF80000 256` dump (default: synthetic, 2.2) |
| `--v205-image FILE` | the original v2.05 application image: the front end then reads the v2.05 tables from it instead of the table data |
| `--tables FILE` | v2.05 table data file (default: the bundled `v205_tables.json`) |
| `--inputs DIR`, `--no-inputs` | a directory with `bootloader.bin`, `EEVBlog2_05.bin`, `option.bytes` (the three images of the earlier usage); without either option `inputs/binaries` of the source tree is used when it exists |

The environment variable `EEV121GW_DATA` names a data directory to use before the built-in ones (2.1).

## 2. Boot modes, bundled data and firmware on demand

### 2.1 What ships with the emulator

`emulator/data/` (a release package carries it inside the application; `emulator/tools/prepare_data.py` fills it in a source tree):

| File | Content |
|---|---|
| `v205_tables.json` | the v2.05 constant tables at their v2.05 addresses, written by `firmware/tools/gen_emu_tables.py` from the `TABLE_V205` tables of the firmware sources |
| `synthetic_eeprom.bin` | the SYNTHETIC data EEPROM (2.3), written by `emulator/tools/gen_synthetic_eeprom.py` |

No firmware, no original EEVblog image and no calibration of any meter is part of the emulator or of its release packages.
The page and `GET /state` (`machine`) show which firmware runs, the boot mode and the EEPROM source.

### 2.2 Direct boot (no bootloader image)

Without a bootloader image (`--bootloader`, or `bootloader.bin` in `--inputs`) the core starts the application from its
vector table at 0x08006000 on every reset: stack pointer = word 0, program counter = word 1 (reset vector), VTOR =
0x08006000. That is what the meter's bootloader hands over (firmware/DESIGN.md 2.1: it checks word 0, loads MSP from it
and jumps to word 1), with these differences. Direct boot does **not** reproduce, of the state the bootloader leaves at
the application's entry (DESIGN.md 2.1):

- the bootloader's TIM2 set-up (counter running, update interrupt enabled), so TIM2-derived timing of the application
  starts at the application's own phase, not the bootloader's (DESIGN.md 3.2 step 1: the port leaves TIM2 as the bootloader
  left it so that its TIM2-derived flags keep v2.05's phase), and the NVIC enables of IRQ 28, 45 and 53;
- SYSCLK = HSE with the PLL on but not selected (direct boot starts on the reset clock, MSI);
- FLASH_PECR = 0x00000004 (data EEPROM and program flash unlocked): direct boot leaves the flash controller locked as
  after reset;
- the backup-domain reset, the lamp-test pattern on the LCD and the GPIO levels the bootloader sets (PE9 high, PF0..PF2
  and PF6..PF10 outputs, PE8 high, PD7 low);
- VTOR: the bootloader leaves 0x08000000 (its own table); direct boot sets 0x08006000, because the bootloader area is
  empty and an exception taken before the application sets VTOR itself would otherwise fetch a zero vector;
- a system reset (`sysreset`, or the firmware writing SYSRESETREQ) restarts the application directly again; a meter runs the bootloader first.

The replacement firmware's start-up sequence (DESIGN.md 3.2) sets its clocks, NVIC, VTOR and flash lock itself and boots to
a reading in direct boot. A firmware that depends on the bootloader's state would behave differently from a meter. The update
path of the bootloader (SD card file `EEVBlog.bin`) exists only with a bootloader image.

### 2.3 The synthetic EEPROM

`synthetic_eeprom.bin` (1280 bytes, EEPROM offsets 0x000..0x4FF) is **synthetic: it is not the calibration of any meter**.
It is made by `emulator/tools/gen_synthetic_eeprom.py` (the header of that file lists every field): settings at the values
the firmware's own readers fall back to, no serial number, no date code, no calibration markers, offset 0, and per
calibration record a typical gain (the voltage-code records: the mean of two real meters, rounded to 3 digits, so the
raw codes and the over-range point are those of a typical unit; the CAP records: a counter gain chosen by design, as the
two meters differ widely there). The emulator's calibrated front end
derives the signal from the calibration it finds in the EEPROM, so the display reads the stimulus. The image carries the
text `SYNTHETIC EEPROM - NOT A METER CALIBRATION` at offset 0x480. Never copy it to a meter, and never copy a `cal.bin`
that the emulator wrote to a meter's SD card.

Option bytes without a dump: RDP level 0, USER 0xF0 (BOR off), no write protection (`app.py synthetic_option_bytes()`).

With `--inputs` and no `--eeprom` the EEPROM is blank, as before.

### 2.4 Firmware on demand

The firmware builds are not shipped; `emu/fetch.py` gets them from the project's GitHub releases when one is selected
(`--firmware`, the page's selector, `{"firmware": NAME}`):

| Build | Release tags | Branch | Image in `firmware-<tag>.zip` |
|---|---|---|---|
| `2_fast` (fast, the default) | `vA.B.C` | `main` | `2_fast/EEVBlog.bin` |
| `1_like_v2.05` (like v2.05: v2.05 with its defects fixed) | `like205-vA.B.C` | `like-v2.05` | `1_like_v2.05/EEVBlog.bin` |

The latest release of the build is looked up, its zip downloaded once, checked against the published `.sha256` and with the
application image test of `POST /firmware` (5), and the image kept in a cache: `EEV121GW_CACHE`, else
`~/Library/Caches/121GW-Emulator` (macOS), `%LOCALAPPDATA%\121GW-Emulator` (Windows), `~/.cache/121GW-Emulator` (other).
Later starts use the cached image of the latest release.  Without a connection the newest cached image runs and
`machine.firmware_note` says so; with none cached the meter stays dark, the note says why, and **Load firmware file…** or
`--app FILE` runs an image instead.

## 3. GET /state

`GET /state` returns one JSON object, a snapshot of the machine (`Emulator.snapshot()`). Fields:

| Field | Type, unit | Meaning |
|---|---|---|
| `running` | bool | the machine is running (not paused with `run`, not stopped, meter powered: dial not at OFF) |
| `time_ms` | float, ms | emulated time since the last power-up (virtual time, not wall time) |
| `sysclk` | int, Hz | current core clock |
| `lcd` | 8 x uint32 | LCD RAM, COM x SEG: word `2*com + (seg>>5)`, bit `seg & 31`, COM 0..3, SEG 0..43. `ui/assets/lcd_bits.json` maps `"w<word>b<bit>"` to the glass elements it lights |
| `lcd_on` | bool | the LCD controller is enabled and the meter is powered |
| `backlight`, `buzzer` | 0 / 1 | levels of PE8 and PE7 |
| `dial` | int 0..9 | rotary switch position (4.2) |
| `keys` | list of str | keys held down |
| `jacks` | list of str | plugged jacks (`A`, `mA`, `COM`, `V`) |
| `unmodelled` | int | number of distinct (address, read / write) peripheral accesses the emulator does not model (0 for the release builds) |
| `analog` | `{PA5, PA4}`, V | voltages at the ADC pins: PA5 battery sense, PA4 board thermistor |
| `battery` | float, V | B+ battery voltage: PA5 divided by the divider ratio 330 / 1330 (R69 1 M, R70 330 k) |
| `stimulus` | object | the signal at the test leads as set by the `input` command (4.4), fields completed with their defaults |
| `environment` | object | mains pickup around the meter (4.5): `pickup_hz`, `pickup_v`, `coupling_pf`, `drift` |
| `frontend` | object | front-end model status: `backend`, `mode` / `mode_name` / `range` (firmware's present mode, `LowZ`, `DCV`, `ACV`, `DCmV`, `ACmV`, `TEMP`, `FREQ`, `PULSE`, `DUTY`, `OHM`, `BEEP`, `DIODE`, `CAP`, `uVA`, `mVA`, `VA`, `ACuA`, `DCuA`, `ACmA`, `DCmA`, `ACA`, `DCA`, `DCuVA`, `DCmVA`, `DCVA`), `supported` (bool: the stimulus can be presented in this mode) with `reason` (why not, or a note), `environment`, `pickup` (`v_rms_at_jack` V, `input_ohms`, `network`), `board_c` (board temperature, degC or null), `error` |
| `hy3131` | object | measurement chip: `regs` (registers 0x20..0x33 as hex), `intf`, `inte`, `ad1_sps` (AD1 rate, samples per second, 0 = off), `ad1_code` (last AD1 code), `ad1_error`, `ad1_sel` (selected inputs and gains), `ad1_ac_volts`, `lpf_rms_hz`, `counter` (`off`, `waiting`, `counting`, `done`), `counter_info`, `events` (completed AD1 / LPF / counter events), `not_modelled` (text) |
| `sdcard` | object | `configured` (an image was given), `present` (inserted), `image` (file name), `capacity_mb`, `state`, `rca`, `blocks` (512 bytes each), `reads`, `writes`, `bus_width` |
| `stop` | str or null | why the machine stopped (invalid memory access, CPU exception, hardware-safety stop), null while it runs |
| `safety` | list of str | violations found by the hardware-safety monitor (`emu/safety.py`) |
| `machine` | object | what the emulated meter was started with: `firmware` (release build name or file name), `firmware_bundled` (true for a release build), `firmware_tag` (its release tag), `firmware_loaded` (false: no image, the meter is dark), `firmware_note` (why a cached image runs or none), `firmware_choices` (list of `{name, label}`), `boot` (`direct` or `bootloader`), `boot_note`, `eeprom` (`synthetic`, `file` or `blank`), `eeprom_note`, `option_bytes` (`synthetic` or `file`), `v205_tables` (`table data` or `original image`) |
| `log` | list of str | the last 200 events, `"<ms> ms  <text>"` |

```
curl -s http://127.0.0.1:8121/state | python3 -m json.tool | head -30
```

Static files: `GET /` (the page), `GET /assets/...` (panel picture, LCD glass elements, `lcd_bits.json`).

## 4. POST /input

Body: one JSON object with one command, `curl -X POST http://127.0.0.1:8121/input -d '<json>'`. The reply is
`{"ok":true}` (HTTP 200) or `{"error": "<message>"}` (HTTP 400). If an object holds several command keys, the first in this
order is executed: `key`, `dial`, `jack`, `run`, `reset`, `sysreset`, `battery`, `analog`, `input`, `environment`, `sdcard`,
`speed`, `firmware`.

### 4.1 key

`{"key": NAME, "down": bool}`: press (`true`) or release (`false`) a key. Names: `MODE`, `SETUP`, `MINMAX`, `MEM`, `RANGE`,
`HOLD`, `REL`, `PEAK`. A long press is a key held down for the firmware's long-press time: send `down: true`, let the machine run, send
`down: false`. The differential harness holds a short press for 0.15 s and a long press for 1.0 s of emulated time
(`emulator/diff/scenario.py`).

```
curl -s -X POST localhost:8121/input -d '{"key":"RANGE","down":true}'
curl -s -X POST localhost:8121/input -d '{"key":"RANGE","down":false}'
```

### 4.2 dial

`{"dial": N}` with N 0..9, clockwise from the left: 0 OFF, 1 Low Z, 2 V, 3 mV / Temp, 4 Hz ms %, 5 Ohm / beep / diode / cap,
6 mVA / VA, 7 uA / uVA, 8 A / mA, 9 OFF. The OFF positions remove power; leaving OFF powers the meter up (a cold start,
the EEPROM stays).

```
curl -s -X POST localhost:8121/input -d '{"dial":5}'
```

### 4.3 jack

`{"jack": NAME, "plugged": bool}` with NAME `A`, `mA`, `COM` or `V`. Only the two current jacks reach the meter's input-warning
logic; currents flow only through a plugged current jack, and the stimulus kind `A` / `VA` needs the matching jack for the
dial position.

```
curl -s -X POST localhost:8121/input -d '{"jack":"mA","plugged":true}'
```

### 4.4 input (the signal at the test leads)

`{"input": {...}}` sets the stimulus. Fields left out take their default (the command replaces the stimulus), except `kind`
and `board`, which keep their present value.

| Field | Default | Meaning |
|---|---|---|
| `kind` | present kind | `open`, `V`, `A`, `ohm`, `Hz`, `F`, `degC`, `diode`, `VA` (below) |
| `value` | 0 | the quantity in SI units: volts, amperes, ohms, hertz, farads, degC, volts |
| `ac` | false | for `V`, `A`, `VA`: `value` is an RMS value of a sine of `freq` hertz (plus the DC part `dc` for `V`) instead of a DC value |
| `freq` | 0 | Hz, of the AC signal; for `Hz` it is set to `value` |
| `duty` | 0.5 | high fraction of the signal at the counter input, between 0 and 1 (exclusive) |
| `width` | 0 | high time in seconds; when above 0 it overrides `duty` (`duty = width * freq`), needs `freq` |
| `dc` | 0 | V, DC component of an AC voltage (AC+DC) |
| `amps` | 0 | A, the current of the `VA` kind |
| `board` | present | board temperature in degC at the cold junction (sets the PA4 thermistor voltage), or `null`: the board temperature follows the PA4 voltage |
| `cap_slow_ranges` | `[]` | list of CAP ranges 0..5, kind `F` only: a MODEL SETTING for a capacitor that cannot be measured in time on those ranges; on them no counter result ever completes, so the firmware's no-signal timeout fires (`[1]` with 95 nF reproduces the range hunting reported for some ceramic capacitors; `[0, 1]` with 0 F models open leads). The physical cause is unproven |
| `probe` | present (`K` at start) | thermocouple type of the `degC` kind: `K`, `J` or `T`; the EMF follows the K table of the firmware image or the NIST ITS-90 J / T tables (`emu/tc_nist.py`); temperature span K -210..1360, J -210..1200, T -210..400 degC |

Kinds: `open` test leads open, nothing connected (the default; every field except `board` is ignored); `V` volts (DC, or RMS
with `ac`); `A` amperes (DC, or RMS with `ac`) entering through the plugged current jack; `ohm` resistance in ohms (also
continuity in BEEP); `Hz` a signal of `value` hertz at the counter input (FREQ, PULSE, DUTY); `F` capacitance in farads;
`degC` thermocouple hot-junction temperature (type from `probe`); `diode` forward voltage of the device under test in volts; `VA` voltage `value`
and current `amps` at the same time (both RMS with `ac`). The stimulus must fit the firmware's present mode: `GET /state`
`frontend.supported` and `frontend.reason` say whether it does. Validation errors (HTTP 400): unknown kind; non-finite
numbers; negative `width`, `freq`, resistance or capacitance; a negative AC value; `duty` outside (0, 1); `width` without
`freq`; `cap_slow_ranges` that is not a list of integers 0..5.

```
curl -s -X POST localhost:8121/input -d '{"input":{"kind":"V","value":1.5}}'                          # 1.5 V DC
curl -s -X POST localhost:8121/input -d '{"input":{"kind":"V","value":230,"ac":true,"freq":50}}'     # 230 V RMS 50 Hz
curl -s -X POST localhost:8121/input -d '{"input":{"kind":"ohm","value":4700}}'
curl -s -X POST localhost:8121/input -d '{"input":{"kind":"Hz","value":1000,"duty":0.25}}'
curl -s -X POST localhost:8121/input -d '{"input":{"kind":"degC","value":100,"board":25}}'
curl -s -X POST localhost:8121/input -d '{"input":{"kind":"open"}}'
```

### 4.5 environment (not part of the meter)

`{"environment": {"pickup_hz": 50|60, "pickup_v": V, "coupling_pf": pF, "drift": D}}`: mains pickup on the open V jack: an
open-circuit source of `pickup_v` volts RMS (0 = shielded, no pickup) at `pickup_hz` behind the coupling capacitance
`coupling_pf` (above 0); `drift` (0 to below 1) is the depth of its slow amplitude variation. Keys left out keep their value.
Defaults: 50 Hz, 230 V, 0.02 pF, 0.3.

```
curl -s -X POST localhost:8121/input -d '{"environment":{"pickup_v":0}}'
```

### 4.6 analog and battery

`{"battery": V}`: battery (B+) voltage, 0 to 12 V; the ADC pin PA5 sees it through the divider (default 6 V).
`{"analog": "PA4" | "PA5", "volts": V}`: the voltage at an ADC pin directly (PA4 board thermistor, default half of the 3.3 V
reference; PA5 battery sense). Setting PA4 makes the board temperature follow it.

```
curl -s -X POST localhost:8121/input -d '{"battery":4.2}'
curl -s -X POST localhost:8121/input -d '{"analog":"PA4","volts":1.5}'
```

### 4.7 sdcard

`{"sdcard": bool}`: insert (`true`) or remove (`false`) the card whose image was given with `--sdcard`. Error without an image.

```
curl -s -X POST localhost:8121/input -d '{"sdcard":false}'
```

### 4.8 run, reset, sysreset, speed, firmware

- `{"run": bool}`: pause (`false`) or resume (`true`) the machine.
- `{"reset": true}`: power cycle: everything restarts, the EEPROM, the board inputs, the stimulus and the clock chip stay.
- `{"sysreset": true}`: system reset of the MCU in place (as the firmware writing SCB_AIRCR.SYSRESETREQ): SRAM, EEPROM and the
  RTC domain stay; with a bootloader image the bootloader runs again, in direct boot the application restarts (2.2).
- `{"speed": X}`: run rate, 1.0 = real time.
- `{"firmware": NAME}`: switch to the release build `NAME` (`2_fast` or `1_like_v2.05`, `machine.firmware_choices`; fetched
  on demand, 2.4) and power cycle. The EEPROM stays, as when a meter is updated. When the build cannot be had the answer
  is 400 with the reason and the meter keeps running what it ran.

```
curl -s -X POST localhost:8121/input -d '{"firmware":"1_like_v2.05"}'
curl -s -X POST localhost:8121/input -d '{"reset":true}'
```

## 5. POST /firmware, POST /quit

`curl -X POST -H 'X-121GW: firmware' -H 'X-121GW-File: EEVBlog.bin' --data-binary @EEVBlog.bin http://127.0.0.1:8121/firmware`
runs the application image in the body (what the page's **Load firmware file…** button and a dropped file send): the
meter is power cycled with it, the EEPROM, board inputs and clock chip stay. The image is refused (400, with the reasons)
when it is not an application image: at most 368 KiB (the flash above the bootloader), word 0 an initial stack pointer in
the RAM 0x20000000..0x2000C000, word 1 a Thumb reset vector inside the image (`app.check_app_image`). A full flash dump
that starts with the bootloader is refused for that reason. `GET /state` `machine.firmware` then names the file.


`curl -X POST -H 'X-121GW: quit' http://127.0.0.1:8121/quit` stops the emulator process (the page has a Quit button; the
packaged macOS application has no console to close). The header is required: a web page of another origin cannot send it
without a CORS preflight, which the server does not answer.

## 6. Python API

`emulator/app.py` defines `Emulator`; the HTTP server is a thin shell around it. Run Python with `-I` (as the project does) and
let the script put `emulator/` on `sys.path`.

```python
Emulator(inputs=None, app=None, eeprom=None, speed=1.0, hw_cal=None, *,
         bootloader=None, option_bytes=None, v205_image=None, tables=None, firmware=None)
```

| Argument | Meaning |
|---|---|
| `inputs` | directory with `bootloader.bin`, `EEVBlog2_05.bin`, `option.bytes` (the earlier usage); `None`: none needed |
| `app` | application image file (default: `inputs/EEVBlog2_05.bin`, else the release build `firmware`, 2.4) |
| `eeprom` | EEPROM image file from offset 0 (default: the synthetic image when `inputs` is `None`, else blank) |
| `speed` | run rate of the real-time loop |
| `hw_cal` | EEPROM image file for the physical calibration of the front end (default: the EEPROM as loaded) |
| `bootloader`, `option_bytes`, `v205_image` | files that override those of `inputs` |
| `tables` | v2.05 table data file (default: bundled) |
| `firmware` | release build name, default `2_fast` (fetched on demand, 2.4) |

Class attributes to set before constructing: `Emulator.frontend_kind` (`'calibrated'` or `'netlist'`), `hy_noise`
(measurement noise on / off), `hy_seed` (noise seed, reproducible runs), `sdcard_path`, `sdcard_mb`.

| Method | Meaning |
|---|---|
| `command(dict)` | one command of section 4, exactly as `POST /input`; raises `ValueError` (or `KeyError` for a missing field) for a bad one |
| `snapshot()` | the dict of section 3 |
| `advance(seconds)` | run for that much emulated time, unpaced (headless); returns the stop reason or `None` |
| `loop()` | the real-time loop of the application; does not return |
| `power_cycle()`, `system_reset(why)`, `set_sdcard(bool)`, `machine_info()` | as the commands / the `machine` field |
| `m` | the low-level `Machine` (`m.uc` Unicorn, `m.log`, `m.unmodelled`, `m.run(cycles)`) |

Headless example (`emulator/scripts/example_headless.py`, run with `python3 -I emulator/scripts/example_headless.py`):

```python
import json, os, sys
sys.path.insert(0, 'emulator'); sys.path.insert(0, 'emulator/tools')
from app import Emulator
import smoke                                   # smoke.lit_names / smoke.main_reading decode the display

bits = json.load(open('emulator/ui/assets/lcd_bits.json'))
e = Emulator()                                 # direct boot, release build 2_fast, synthetic EEPROM
e.advance(2.0)                                 # 2 s emulated: boot, splash, first readings
e.command({'input': {'kind': 'V', 'value': 1.5}})
e.advance(1.0)
s = e.snapshot()
print(smoke.main_reading(smoke.lit_names(s, bits)), 'V', s['frontend']['mode_name'], s['unmodelled'])
```

Output: `1.5000 V DCV 0`.

The server and a script can share one `Emulator`: `from ui.server import serve; serve(emu, 8121); emu.loop()` serves the page while
the loop runs it; a script then calls `emu.command(...)` / `emu.snapshot()` from another thread (both take the machine lock).

`emulator/tools/smoke.py` checks a running emulator (it boots to a reading, every access modelled); `emulator/diff/run.py`
compares two firmware images scenario by scenario (its docstring), and needs the original v2.05 image as the reference.

## 7. Errors and limits

- The server binds `127.0.0.1` only, has no authentication and accepts a command from any local program or web page:
  do not expose the port.
- A bad command gives HTTP 400 and `{"error": ...}`; unknown paths give HTTP 404.
- With the `calibrated` front end every mode is supported; a stimulus that does not fit the dial position is accepted and
  reported through `frontend.supported` / `frontend.reason`.
- The emulator runs as fast as the host allows; with `speed` above what the host manages it runs slower than asked.
