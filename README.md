# 121GW Companion

A program for Windows, macOS and Linux that connects to an EEVblog 121GW multimeter over Bluetooth LE.

This is the branch `companion` of [121GW-Open-Firmware](https://github.com/zombu4/121GW-Open-Firmware): only the companion
program lives here.  The firmware and the emulator are on `main`, the build that behaves like v2.05 on `like-v2.05`.

## What it does

| | |
|---|---|
| Live view | the reading as the meter shows it: value with the meter's decimal point and unit for every mode and range, the small display (board temperature, frequency, dB, VA pages, setup values), the bargraph and the symbols (AC, DC, AUTO, HOLD, REL, MIN/MAX/AVG, PEAK, MEM, 1 kHz, high voltage, APO, battery) |
| Statistics | minimum, maximum, mean, standard deviation and count of the readings; they restart when the mode, unit or range changes |
| Trend | the last 10 minutes on a scope-style grid; the trace breaks where the meter had no value (overload, range change) |
| Recording | every reading with its time to a CSV file (`Documents/121GW` by default) |
| Firmware version | the fast firmware from F-1.02 on reports its version; the header shows it |
| Firmware and bootloader updates | when a newer firmware or bootloader release exists, a notice offers "Update both", "Firmware only", "Bootloader only" or "Later" (checked at every connection and every 30 minutes).  With the two-part bootloader (releases `bl-vA.B.C`) the meter restarts into its update mode and receives the file over Bluetooth, nothing to press, then restarts into it.  With EEVblog's bootloader the firmware goes to the card on the page `Ld-bt` and the key sequence installs it; the first install of the two-part bootloader also goes through `Ld-bt` (firmware F-1.03 or newer, fresh batteries) |
| Bootloader | the meter's bootloader is shown next to the firmware version (EEVblog original, or B-A.BC) |
| Meter clock | "Sync time" sets the meter's clock from an NTP server (pool.ntp.org, or your own) to the second |

The meter accepts one Bluetooth connection at a time: close the phone application before connecting.  Turn Bluetooth
on at the meter with a long press of PEAK.  While the SETUP page `Ld` (firmware transfer) is shown the meter sends no
readings.

## Everything included

The installers carry everything the program needs (Python, the Bluetooth library bleak, the window toolkit); nothing
else has to be installed.  The system provides only what every desktop has: macOS asks once for Bluetooth access,
Windows shows the window with its built-in WebView2 (otherwise the default browser opens), Linux uses its Bluetooth
service BlueZ and opens the program in the browser.

## Run from the source

    python -m pip install bleak pywebview
    python -m meter121            # from this folder; --browser, --no-open, --port N, --folder DIR

## Build

    python -m pip install bleak pywebview pyinstaller pillow
    python packaging/make_icons.py build/icons
    python packaging/third_party.py build/THIRD_PARTY_LICENSES.txt
    APP_VERSION=1.0.0 APP_ICON=build/icons/121gw-companion.icns pyinstaller --noconfirm packaging/companion.spec

then `packaging/make_dmg.sh` (macOS), `packaging/windows/121gw_companion.iss` (Inno Setup) or
`packaging/linux/build_appimage.sh` / `build_deb.sh`.

## How it works

| File | |
|---|---|
| `meter121/link.py` | Bluetooth LE: scan, connect, notifications, writes, reconnect after the meter's auto power-off |
| `meter121/frames.py` | frames on the meter's byte stream (status, echoes, version answer, transfer answers), reassembled and checked |
| `meter121/display.py` | the status frame decoded as the meter's display shows it; the decimal point and unit tables come from the firmware |
| `meter121/record.py` | statistics, trend history, CSV recording |
| `meter121/server.py` | local server between the window and the program (127.0.0.1 only; commands need a custom header) |
| `meter121/releases.py` | the fast firmware's releases: latest version, image downloaded and checked (SHA-256, header) |
| `meter121/transfer.py` | the file transfer to the meter's SD card (packets with CRC-16, stop and wait, retries) |
| `meter121/clock.py` | NTP query and the meter's set-clock frame |
| `meter121/paths.py` | the user's settings, cache and documents folders |
| `meter121/derived.py` | values computed on the computer: REL percent, 4-20 / 0-20 mA loop percent, Pt100 / Pt1000 temperature (IEC 60751), limit test |
| `meter121/keys.py` | remote keys (short and long codes of the firmware's key routine) |
| `meter121/card.py` | SD card file manager over the transfer link (list, download, delete, info) and the sync to a folder |
| `meter121/settings.py` | the meter's settings over the transfer link (read all, change one, range checked) |
| `meter121/diag.py` | the transfer's diagnosis values and their readable text |
| `meter121/STATE.md` | the state and command contract between the program and the page |
| `tests/` | unit tests, `python3 -I -m unittest discover -s tests` (no meter, no Bluetooth) |
| `meter121/app.py` | the program: link, version request, update, clock, window |
| `ui/index.html` | the window |

The status frame does not carry the main decimal point or the unit prefix; both come from the firmware's tables
(`dec_table` in `firmware/src/mode/mode.s`, annunciators in `firmware/src/lcd/annun.s` on `main`).  What the frame cannot
tell is not shown rather than guessed: texts such as " LEAD", the port-only views (REL percent, loop percent, Pt100,
statistics pages), the dB reference, the 12-hour clock setting and the sign of an overload.

## Licence

Free for individuals, schools and non-profits to use, modify and share; companies need written permission from zombu4; selling or bundling only by zombu4 and EEVblog (David L. Jones), who both keep full rights. See `LICENSE`.
The installers also contain third-party software under its own licences (THIRD_PARTY_LICENSES.txt).
