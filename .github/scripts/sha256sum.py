#!/usr/bin/env python3
"""sha256sum.py - `sha256sum FILE...` that behaves the same on Linux, macOS and Windows runners.

    python3 -I .github/scripts/sha256sum.py FILE... > SUMS        lines "<hash>  <path as given>"
"""
import hashlib
import sys

for path in sys.argv[1:]:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    # bytes with a bare LF: Windows text-mode output would end the line with CR LF, which sha256sum -c and shasum -c
    # read as part of the file name
    sys.stdout.buffer.write(('%s  %s\n' % (h.hexdigest(), path.replace('\\', '/'))).encode())
