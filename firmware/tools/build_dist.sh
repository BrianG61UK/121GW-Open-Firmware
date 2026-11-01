#!/bin/sh
# build_dist.sh - build both firmware variants and collect them in the layout of the release archive.
#
#   sh firmware/tools/build_dist.sh OUTDIR [check-ci | check | none]
#
# OUTDIR gets
#   2_fast/EEVBlog.bin          production build       (make)
#   1_like_v2.05/EEVBlog.bin    strict build           (make LOOP_V205=1)
#   v205_tables.json            v2.05 constant tables of the sources for the emulator (tools/gen_emu_tables.py)
# The second argument is the make target run for each variant (default check-ci, the checks that need no original
# image; `check` needs inputs/binaries/EEVBlog2_05.bin and the analysis/ files; `none` builds the image only).
# GNU binutils arm-none-eabi 2.46 must be on PATH (firmware/Makefile toolcheck); PYTHON names the python with
# capstone and unicorn for the checks (default python3).
set -eu
out=${1:?usage: build_dist.sh OUTDIR [check-ci|check|none]}
target=${2:-check-ci}
[ "$target" = none ] && target=image
root=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$out/2_fast" "$out/1_like_v2.05"
out=$(cd "$out" && pwd)
cd "$root/firmware"
make "$target"
cp build/EEVBlog.bin "$out/2_fast/EEVBlog.bin"
${PYTHON:-python3} -I tools/gen_emu_tables.py build/121gw.elf build/EEVBlog.bin "$out/v205_tables.json"
make "$target" LOOP_V205=1
cp build/EEVBlog.bin "$out/1_like_v2.05/EEVBlog.bin"
if command -v shasum >/dev/null 2>&1; then sha='shasum -a 256'; else sha=sha256sum; fi
( cd "$out" && $sha 2_fast/EEVBlog.bin 1_like_v2.05/EEVBlog.bin v205_tables.json )
