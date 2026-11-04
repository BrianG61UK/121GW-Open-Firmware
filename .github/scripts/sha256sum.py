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
    print('%s  %s' % (h.hexdigest(), path.replace('\\', '/')))
