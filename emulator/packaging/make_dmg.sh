#!/bin/sh
# make_dmg.sh - disk image with the emulator application, the licence and an Applications link (macOS only).
#
#   sh packaging/make_dmg.sh "dist/121GW Emulator.app" OUT.dmg
#
# The application is not signed with a developer identity or notarised (PyInstaller adds an ad-hoc signature): macOS asks for
# confirmation when it is opened the first time; the image carries "First start - READ ME.txt" with the steps (START.md).
set -eu
app=${1:?usage: make_dmg.sh APP.app OUT.dmg}
out=${2:?usage: make_dmg.sh APP.app OUT.dmg}
root=$(cd "$(dirname "$0")/../.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
cp "$root/LICENSE" "$stage/LICENSE"
cp "$root/emulator/ui/assets/lcd/LICENSE" "$stage/LICENSE-LCD-graphics-MIT"
ln -s /Applications "$stage/Applications"
cat > "$stage/First start - READ ME.txt" <<'TXT'
121GW Emulator - first start

1. Drag "121GW Emulator" onto "Applications".
2. Open Applications and double-click "121GW Emulator".
   macOS says it could not verify the app: click "Done" (not "Move to Trash").
3. Apple menu > System Settings > Privacy & Security. Scroll down to "Security"
   and click "Open Anyway".
4. Click "Open Anyway" again and enter your password.

Only the first time. Afterwards a double-click on "121GW Emulator" is enough.
The app is free and not paid-signed by Apple, which is why macOS asks once.

Steps with pictures:
https://github.com/zombu4/121GW-Open-Firmware/blob/main/emulator/START.md
TXT
rm -f "$out"
hdiutil create -volname "121GW Emulator" -srcfolder "$stage" -ov -format UDZO "$out"
echo "make_dmg: $out"
