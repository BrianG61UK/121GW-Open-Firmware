#!/bin/sh
# make_dmg.sh - disk image with the emulator application, the licence and an Applications link (macOS only).
#
#   sh packaging/make_dmg.sh "dist/121GW Emulator.app" OUT.dmg
#
# The application is not signed with a developer identity or notarised (PyInstaller adds an ad-hoc signature): macOS asks for
# confirmation when it is opened the first time (README: Emulator, macOS).
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
rm -f "$out"
hdiutil create -quiet -volname "121GW Emulator" -srcfolder "$stage" -ov -format UDZO "$out"
echo "make_dmg: $out"
