#!/bin/sh
# sign_macos.sh - sign the companion application with a Developer ID Application identity (macOS only).
#
#   sh packaging/sign_macos.sh "dist/121GW Companion.app" "Developer ID Application: NAME (TEAMID)" [KEYCHAIN]
#
# Every Mach-O file inside the bundle (the Python runtime, its extension modules, PyObjC, the libraries) is signed on its
# own, deepest path first, then the bundle itself, each with the hardened runtime (--options runtime) and a secure
# timestamp: notarization refuses anything less.  No entitlements are given.  KEYCHAIN (optional) is the keychain that
# holds the identity (CI uses a temporary one).  Ends with a strict verification.
set -eu
app=${1:?usage: sign_macos.sh APP.app IDENTITY [KEYCHAIN]}
identity=${2:?usage: sign_macos.sh APP.app IDENTITY [KEYCHAIN]}
keychain=${3:-}
[ -d "$app" ] || { echo "sign_macos: no such bundle: $app" >&2; exit 1; }
set -- --force --options runtime --timestamp --sign "$identity"
[ -n "$keychain" ] && set -- "$@" --keychain "$keychain"

list=$(mktemp)
trap 'rm -f "$list"' EXIT
# Mach-O files only (the bundle also holds Python sources, the page, licences); sorted by path depth, deepest first, so
# a library is signed before anything that contains it
find "$app/Contents" -type f -print | while IFS= read -r f; do
    case $(file -b "$f") in
        Mach-O*) printf '%s\t%s\n' "$(printf '%s' "$f" | tr -cd '/' | wc -c)" "$f" ;;
    esac
done | sort -rn | cut -f2- > "$list"
n=$(wc -l < "$list" | tr -d ' ')
[ "$n" -gt 0 ] || { echo "sign_macos: no Mach-O file in $app" >&2; exit 1; }
while IFS= read -r f; do
    codesign "$@" "$f"
done < "$list"
codesign "$@" "$app"
codesign --verify --deep --strict --verbose=1 "$app"
echo "sign_macos: $n binaries and the bundle signed: $app"
