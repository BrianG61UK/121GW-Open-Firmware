#!/bin/sh
# build_appimage.sh - AppImage of the emulator from the PyInstaller one-folder output (Linux x86_64).
#
#   sh packaging/linux/build_appimage.sh dist/121gw-emulator OUT.AppImage ICON.png APPIMAGETOOL
#
# APPIMAGETOOL is the path of appimagetool-x86_64.AppImage (run with --appimage-extract-and-run, so FUSE is not needed).
# The AppImage starts the emulator in a terminal (the server log), opens the browser and stops with the terminal.
set -eu
src=${1:?usage: build_appimage.sh DIST_DIR OUT.AppImage ICON.png APPIMAGETOOL}
out=${2:?}
icon=${3:?}
tool=${4:?}
root=$(cd "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dir="$work/121GW-Emulator.AppDir"
mkdir -p "$dir/usr/lib" "$dir/usr/share/doc/121gw-emulator"
cp -R "$src" "$dir/usr/lib/121gw-emulator"
cp "$root/LICENSE" "$dir/usr/share/doc/121gw-emulator/LICENSE"
cp "$root/emulator/ui/assets/lcd/LICENSE" "$dir/usr/share/doc/121gw-emulator/LICENSE-LCD-graphics-MIT"
cp "$icon" "$dir/121gw-emulator.png"
cat > "$dir/121gw-emulator.desktop" <<'DESK'
[Desktop Entry]
Type=Application
Name=121GW Emulator
Comment=Emulator of the EEVblog 121GW multimeter with its open firmware
Exec=121gw-emulator
Icon=121gw-emulator
Terminal=true
Categories=Development;Electronics;
DESK
cat > "$dir/AppRun" <<'RUN'
#!/bin/sh
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/lib/121gw-emulator/121gw-emulator" "$@"
RUN
chmod +x "$dir/AppRun"
ARCH=x86_64 "$tool" --appimage-extract-and-run "$dir" "$out"
chmod +x "$out"
echo "build_appimage: $out"
