#!/bin/sh
# make_dmg.sh - disk image with the companion application, the licences and an Applications link (macOS only).
#
#   sh packaging/make_dmg.sh "dist/121GW Companion.app" THIRD_PARTY_LICENSES.txt OUT.dmg
#
# Without SIGNED=1 the application is not signed with a developer identity or notarised (PyInstaller adds an ad-hoc
# signature): macOS asks for confirmation the first time; the image carries "First start - READ ME.txt" with the steps.
# SIGNED=1: the application was signed by sign_macos.sh (the image is signed and notarised after this script); the
# READ ME then has only the install step and the Bluetooth question.
set -eu
app=${1:?usage: make_dmg.sh APP.app THIRD_PARTY.txt OUT.dmg}
third=${2:?usage: make_dmg.sh APP.app THIRD_PARTY.txt OUT.dmg}
out=${3:?usage: make_dmg.sh APP.app THIRD_PARTY.txt OUT.dmg}
root=$(cd "$(dirname "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
cp "$root/LICENSE" "$stage/LICENSE"
cp "$third" "$stage/THIRD_PARTY_LICENSES.txt"
ln -s /Applications "$stage/Applications"
if [ "${SIGNED:-0}" = 1 ]; then
cat > "$stage/First start - READ ME.txt" <<'TXT'
121GW Companion - first start

1. Drag "121GW Companion" onto "Applications".
2. Open Applications and double-click "121GW Companion".
3. The first time you connect, macOS asks to allow Bluetooth: click "Allow".
TXT
else
cat > "$stage/First start - READ ME.txt" <<'TXT'
121GW Companion - first start

1. Drag "121GW Companion" onto "Applications".
2. Open Applications and double-click "121GW Companion".
   macOS says it could not verify the app: click "Done" (not "Move to Trash").
3. Apple menu > System Settings > Privacy & Security. Scroll down to "Security"
   and click "Open Anyway".
4. Click "Open Anyway" again and enter your password.
5. The first time you connect, macOS asks to allow Bluetooth: click "Allow".

Only the first time. The app is free and not paid-signed by Apple, which is why macOS asks once.
TXT
fi
rm -f "$out"
hdiutil create -quiet -volname "121GW Companion" -srcfolder "$stage" -ov -format UDZO "$out"
echo "make_dmg: $out"
