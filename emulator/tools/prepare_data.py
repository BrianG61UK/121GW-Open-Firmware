#!/usr/bin/env python3
"""prepare_data.py - fill emulator/data with what the emulator ships with (emu/bundle.py documents the layout).

    python3 -I emulator/tools/prepare_data.py --dist DIST [--out emulator/data]

DIST is the output of firmware/tools/build_dist.sh (the release workflow builds it):
    DIST/2_fast/EEVBlog.bin, DIST/1_like_v2.05/EEVBlog.bin, DIST/v205_tables.json
The tool copies them to OUT, then writes OUT/synthetic_eeprom.bin with tools/gen_synthetic_eeprom.py (checked against the
base table in v205_tables.json).  Nothing from an original EEVblog image or from any meter's calibration is involved.
Locally, from the repository root:
    PATH=<binutils 2.46 arm-none-eabi>:$PATH sh firmware/tools/build_dist.sh /tmp/dist none
    python3 -I emulator/tools/prepare_data.py --dist /tmp/dist
"""
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
FILES = (('2_fast', 'EEVBlog.bin'), ('1_like_v2.05', 'EEVBlog.bin'), ('v205_tables.json',))


def main(argv):
    if '--dist' not in argv:
        sys.stderr.write(__doc__)
        return 2
    dist = argv[argv.index('--dist') + 1]
    out = os.path.normpath(argv[argv.index('--out') + 1] if '--out' in argv else os.path.join(HERE, '..', 'data'))
    for parts in FILES:
        src = os.path.join(dist, *parts)
        if not os.path.isfile(src):
            print('prepare_data: missing %s (run firmware/tools/build_dist.sh)' % src)
            return 1
        dst = os.path.join(out, *(('firmware',) + parts if len(parts) == 2 else parts))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        print('prepare_data: %s' % os.path.relpath(dst))
    r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'gen_synthetic_eeprom.py'),
                        os.path.join(out, 'synthetic_eeprom.bin'), '--tables', os.path.join(out, 'v205_tables.json')])
    return r.returncode


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
