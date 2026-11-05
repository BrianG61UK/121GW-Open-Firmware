121GW Companion: live view, recording and firmware information for the EEVblog 121GW over Bluetooth LE.

New in 1.2.0: five views (LIVE, SCOPE, LOG, CARD, METER) in a new bench-instrument design; derived values (REL %, loop %, Pt100 / Pt1000, own limit test); the meter's keys from the computer; the SD card from the computer (list, download, delete, sync to a folder) and the meter's settings, both with firmware F-1.05 or newer on the page Ld-bt; the diagnosis values.  Verified working on a meter: card list, a 169 KB download equal to the file on the card, settings read and changed.

Updates: it checks this project's releases, updates the meter's firmware (page `Ld-bt` and the card routine with EEVblog's bootloader), sets the meter's clock, installs the two-part bootloader once (releases `bl-vA.B.C`, fresh batteries) and from then on updates the firmware, the bootloader or both over Bluetooth with nothing to press on the meter. How-to: `bootloader/README.md` on the branch `bootloader` of 121GW-Open-Firmware.

Assets
- `121GW-Companion-<version>-macos-arm64.dmg`: macOS on Apple chips. Drag the app to Applications; macOS asks once to open an app that is not paid-signed (see "First start - READ ME.txt" in the image) and once for Bluetooth access.
- `121GW-Companion-<version>-windows-x64.exe`: installer for Windows 10 / 11.
- `121GW-Companion-<version>-linux-amd64.deb`: Ubuntu, Debian, Mint, Pop!_OS (`sudo apt install ./<file>`).
- `121GW-Companion-<version>-linux-x86_64.AppImage`: any other 64-bit Linux (make it executable, double-click).
- `*.sha256`: checksum of the file with the same name.

Everything the program needs is inside each package; nothing else has to be installed. Meter: Bluetooth on (hold PEAK), phone app closed. The firmware version is shown with the fast firmware F-1.02 or later.

Free for individuals, schools and non-profits; companies need written permission (see LICENSE). Third-party licences: THIRD_PARTY_LICENSES.txt in each package.
