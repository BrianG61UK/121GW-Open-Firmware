#!/bin/sh
# build_deb.sh - Debian / Ubuntu package of the emulator from the PyInstaller one-folder output (amd64).
#
#   sh packaging/linux/build_deb.sh dist/121gw-emulator VERSION OUT.deb ICON.png
#
# VERSION is the release tag (v1.2.3 -> package version 1.2.3; anything else -> 0.0.0~VERSION).  The package installs the
# application folder to /opt/121gw-emulator, the command /usr/bin/121gw-emulator, a menu entry and its icon.  It needs
# nothing that a desktop system lacks: the bundled interpreter links only the C library (built on Ubuntu 22.04, glibc
# 2.35) and the panel opens in the default browser through xdg-open.  Installed by a double click (the software centre)
# or with "sudo apt install ./OUT.deb".
set -eu
src=${1:?usage: build_deb.sh DIST_DIR VERSION OUT.deb ICON.png}
tag=${2:?}
out=${3:?}
icon=${4:?}
root=$(cd "$(dirname "$0")/../../.." && pwd)
case "$tag" in
  v[0-9]*) version=${tag#v} ;;
  *) version="0.0.0~$(printf '%s' "$tag" | tr -c 'A-Za-z0-9.+~\n' '.')" ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pkg="$work/pkg"
mkdir -p "$pkg/DEBIAN" "$pkg/opt" "$pkg/usr/bin" "$pkg/usr/share/applications" \
         "$pkg/usr/share/icons/hicolor/256x256/apps" "$pkg/usr/share/doc/121gw-emulator"
cp -R "$src" "$pkg/opt/121gw-emulator"
ln -s /opt/121gw-emulator/121gw-emulator "$pkg/usr/bin/121gw-emulator"
cp "$icon" "$pkg/usr/share/icons/hicolor/256x256/apps/121gw-emulator.png"
cp "$root/LICENSE" "$pkg/usr/share/doc/121gw-emulator/copyright"
cp "$root/emulator/ui/assets/lcd/LICENSE" "$pkg/usr/share/doc/121gw-emulator/LICENSE-LCD-graphics-MIT"
cat > "$pkg/usr/share/applications/121gw-emulator.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=121GW Emulator
Comment=Emulator of the EEVblog 121GW multimeter with its open firmware
Exec=/opt/121gw-emulator/121gw-emulator
Icon=121gw-emulator
Terminal=false
Categories=Development;Electronics;
DESK
size=$(du -sk "$pkg" | cut -f1)
cat > "$pkg/DEBIAN/control" <<CTRL
Package: 121gw-emulator
Version: $version
Architecture: amd64
Maintainer: 121GW-Open-Firmware <https://github.com/zombu4/121GW-Open-Firmware>
Installed-Size: $size
Depends: libc6 (>= 2.35), xdg-utils
Recommends: zenity
Section: electronics
Priority: optional
Homepage: https://github.com/zombu4/121GW-Open-Firmware
Description: Emulator of the EEVblog 121GW multimeter
 Runs the 121GW firmware (the open replacement firmware builds are included,
 any EEVBlog.bin can be loaded) on an emulated meter with its front panel in
 the browser. Everything it needs is inside the package.
CTRL
dpkg-deb --root-owner-group --build "$pkg" "$out"
echo "build_deb: $out ($version)"
