#!/bin/sh
# notarize_macos.sh - submit a signed disk image to Apple's notary service, wait for the verdict, staple the ticket.
#
#   NOTARY_PROFILE=121gw sh packaging/notarize_macos.sh OUT.dmg                       (keychain profile, a Mac)
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=... NOTARY_ISSUER=... sh packaging/notarize_macos.sh OUT.dmg   (API key, CI)
#
# The image must already be signed (codesign) and hold a signed application (sign_macos.sh).  On a refusal the notary
# log (which file failed and why) is printed and the script fails.  After stapling, the image opens without a network
# lookup; spctl confirms Gatekeeper accepts it.
set -eu
dmg=${1:?usage: notarize_macos.sh OUT.dmg}
[ -f "$dmg" ] || { echo "notarize_macos: no such file: $dmg" >&2; exit 1; }
if [ -n "${NOTARY_PROFILE:-}" ]; then
    set -- --keychain-profile "$NOTARY_PROFILE"
elif [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    set -- --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
else
    echo "notarize_macos: set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER" >&2
    exit 1
fi
out=$(mktemp)
trap 'rm -f "$out"' EXIT
# the exit status of submit is not relied on: the verdict is read from its answer, so a refusal still prints its log
rc=0
xcrun notarytool submit "$dmg" "$@" --wait --timeout 45m --output-format plist > "$out" || rc=$?
status=$(plutil -extract status raw -o - "$out" 2>/dev/null) || status=none
id=$(plutil -extract id raw -o - "$out" 2>/dev/null) || id=none
[ "$id" != none ] || { echo "notarize_macos: no submission (notarytool exit $rc)" >&2; exit 1; }
echo "notarize_macos: submission $id: $status"
if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" "$@" || true
    exit 1
fi
# stapling fetches the ticket from Apple's CloudKit service: a dropped connection there (CI 2026-11-11, Intel runner:
# NSURLErrorDomain -1005 "The network connection was lost", stapler error 68) is retried, at most 5 tries 30 s apart
n=1
until xcrun stapler staple "$dmg"; do
    [ "$n" -lt 5 ] || { echo "notarize_macos: stapling failed $n times" >&2; exit 1; }
    echo "notarize_macos: stapling failed (try $n of 5), again in 30 s"
    n=$((n + 1))
    sleep 30
done
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "notarize_macos: $dmg notarized and stapled"
