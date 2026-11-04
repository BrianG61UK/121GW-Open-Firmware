#!/bin/sh
# build_deb.sh - Debian / Ubuntu package of the companion from the PyInstaller one-folder output (amd64).
#
#   sh packaging/linux/build_deb.sh dist/121gw-companion TAG THIRD_PARTY.txt OUT.deb ICON.png
#
# Everything the program needs is inside the package (interpreter, bleak, the page).  It uses what a desktop system has:
# the C library, xdg-open for the browser, and the BlueZ service for Bluetooth (bluez).  Installed by a double click
# (the software centre) or with "sudo apt install ./OUT.deb".
set -eu
src=${1:?usage: build_deb.sh DIST_DIR TAG THIRD_PARTY.txt OUT.deb ICON.png}
tag=${2:?}
third=${3:?}
out=${4:?}
icon=${5:?}
root=$(cd "$(dirname "$0")/../.." && pwd)
case "$tag" in
  companion-v[0-9]*) version=${tag#companion-v} ;;
  *) version="0.0.0~$(printf '%s' "$tag" | tr -c 'A-Za-z0-9.+~\n' '.')" ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pkg="$work/pkg"
mkdir -p "$pkg/DEBIAN" "$pkg/opt" "$pkg/usr/bin" "$pkg/usr/share/applications" \
         "$pkg/usr/share/icons/hicolor/256x256/apps" "$pkg/usr/share/doc/121gw-companion"
cp -R "$src" "$pkg/opt/121gw-companion"
ln -s /opt/121gw-companion/121gw-companion "$pkg/usr/bin/121gw-companion"
cp "$icon" "$pkg/usr/share/icons/hicolor/256x256/apps/121gw-companion.png"
cp "$root/LICENSE" "$pkg/usr/share/doc/121gw-companion/copyright"
cp "$third" "$pkg/usr/share/doc/121gw-companion/THIRD_PARTY_LICENSES.txt"
cat > "$pkg/usr/share/applications/121gw-companion.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=121GW Companion
Comment=Live view, recording and firmware updates for the EEVblog 121GW multimeter
Exec=/opt/121gw-companion/121gw-companion
Icon=121gw-companion
Terminal=false
Categories=Utility;Electronics;
DESK
size=$(du -sk "$pkg" | cut -f1)
cat > "$pkg/DEBIAN/control" <<CTRL
Package: 121gw-companion
Version: $version
Architecture: amd64
Maintainer: 121GW-Open-Firmware <https://github.com/zombu4/121GW-Open-Firmware>
Installed-Size: $size
Depends: libc6 (>= 2.35), xdg-utils, bluez
Section: electronics
Priority: optional
Homepage: https://github.com/zombu4/121GW-Open-Firmware
Description: Companion program for the EEVblog 121GW multimeter
 Connects to the 121GW over Bluetooth LE: live view of the reading, recording
 to CSV with a trend graph and statistics. Everything it needs is inside the
 package.
CTRL
dpkg-deb --root-owner-group --build "$pkg" "$out"
echo "build_deb: $out ($version)"
