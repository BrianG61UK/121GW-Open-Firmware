#!/bin/sh
# build_dist.sh - build the like-v2.05 (strict) firmware and collect it in the layout of the release archive.
#
#   sh firmware/tools/build_dist.sh OUTDIR [check-ci | check | none]
#
# OUTDIR gets
#   1_like_v2.05/EEVBlog.bin    strict build           (make LOOP_V205=1)
# The second argument is the make target (default check-ci, the checks that need no original image; `check` needs
# inputs/binaries/EEVBlog2_05.bin and the analysis/ files; `none` builds the image only).
# The image must equal the hash recorded in firmware/STRICT_IMAGE.sha256: this branch changes only on the owner's
# decision, and a changed hash is then written there in the same commit.
# GNU binutils arm-none-eabi 2.46 must be on PATH (firmware/Makefile toolcheck); PYTHON names the python with
# capstone and unicorn for the checks (default python3).
set -eu
out=${1:?usage: build_dist.sh OUTDIR [check-ci|check|none]}
target=${2:-check-ci}
[ "$target" = none ] && target=image
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$out/1_like_v2.05"
out=$(cd "$out" && pwd)
cd "$root/firmware"
make "$target" LOOP_V205=1
cp build/EEVBlog.bin "$out/1_like_v2.05/EEVBlog.bin"
if command -v shasum >/dev/null 2>&1; then sha='shasum -a 256'; else sha=sha256sum; fi
want=$(cut -d' ' -f1 STRICT_IMAGE.sha256)
got=$($sha "$out/1_like_v2.05/EEVBlog.bin" | cut -d' ' -f1)
if [ "$got" != "$want" ]; then
  echo "build_dist: the strict image is $got, firmware/STRICT_IMAGE.sha256 records $want"
  echo "build_dist: the like-v2.05 build changes only on the owner's decision (then update STRICT_IMAGE.sha256)"
  exit 1
fi
( cd "$out" && $sha 1_like_v2.05/EEVBlog.bin )
