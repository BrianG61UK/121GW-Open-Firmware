121GW Companion: live view, recording and firmware information for the EEVblog 121GW over Bluetooth LE.

New in 1.2.5: the METER view's diagnosis shows the write-timeout values of firmware F-1.11 (which part of a card write timed out, for how long, what the card answered); older firmware shows the values it has.

Fixed in 1.2.4: a format refused by a meter whose firmware is older than F-1.09 says so (it said "not allowed now"); formatting a large card works with firmware F-1.10 (a slow card write stopped the format).

New in 1.2.3: "Format card" in the CARD view (meter on the page Ld-bt, firmware F-1.09 or newer with the two-part bootloader): type FORMAT to confirm, a window stays open until the meter has formatted the card.

Fixed in 1.2.3: buttons answer the first click on macOS (Connect needed up to ten clicks, the update notice's button did not answer: the page rewrote the button text on every redraw, and WebKit drops a click whose pressed text was replaced); the CARD view shows the card's space (two requests sent together refused the second); the LOG view lists the recordings folder with size and date; the update notice says where the meter restarts to.

Fixed in 1.2.2: the Windows installer asks for administrator rights at start and installs for all users into Program Files (before it installed into the user's AppData folder and could fail); an earlier per-user copy is removed first. Without administrator rights, start the installer with /CURRENTUSER. The .sha256 file of the Windows installer ends its line with LF, so sha256sum -c / shasum -c accept it.

Fixed in 1.2.1: Connect works on the first click (macOS: the window is brought to the front at start; a Connect right after a Disconnect starts a new search; a search stopped half-way leaves no half-open connection behind, which kept the meter from being found); the button shows Connect / Stop searching / Disconnect; the update check shows "up to date" with the newest releases and the time of the check, or why it failed; versions shown once (F-1.05, not F-F-1.05).

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
