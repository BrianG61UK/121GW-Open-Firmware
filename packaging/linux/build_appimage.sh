#!/bin/sh
# build_appimage.sh - AppImage of the companion from the PyInstaller one-folder output (Linux x86_64).
#
#   sh packaging/linux/build_appimage.sh dist/121gw-companion THIRD_PARTY.txt OUT.AppImage ICON.png APPIMAGETOOL
#
# The AppImage opens the program in the default browser (the Linux build carries no web view).  Bluetooth goes through
# the system's BlueZ service (D-Bus), which every desktop distribution runs.
set -eu
src=${1:?usage: build_appimage.sh DIST_DIR THIRD_PARTY.txt OUT.AppImage ICON.png APPIMAGETOOL}
third=${2:?}
out=${3:?}
icon=${4:?}
tool=${5:?}
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dir="$work/121GW-Companion.AppDir"
mkdir -p "$dir/usr/lib" "$dir/usr/share/doc/121gw-companion"
cp -R "$src" "$dir/usr/lib/121gw-companion"
cp "$root/LICENSE" "$dir/usr/share/doc/121gw-companion/LICENSE"
cp "$third" "$dir/usr/share/doc/121gw-companion/THIRD_PARTY_LICENSES.txt"
cp "$icon" "$dir/121gw-companion.png"
cat > "$dir/121gw-companion.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=121GW Companion
Comment=Live view, recording and firmware updates for the EEVblog 121GW multimeter
Exec=121gw-companion
Icon=121gw-companion
Terminal=false
Categories=Utility;Electronics;
DESK
cat > "$dir/AppRun" <<'RUN'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/lib/121gw-companion/121gw-companion" "$@"
RUN
chmod +x "$dir/AppRun"
ARCH=x86_64 "$tool" --appimage-extract-and-run "$dir" "$out"
chmod +x "$out"
echo "build_appimage: $out"
