#!/usr/bin/env python3
"""check_no_originals.py - refuse to publish anything that is, or could be, an original EEVblog image or a calibration.

    python3 -I .github/scripts/check_no_originals.py PATH...        PATH = directory (searched recursively) or .zip

Fails (exit status 1) when a file
  * has the SHA-256 of the original v2.05 application image (8f885f12..., published in firmware/ORIGINAL_FIRMWARE_ISSUES.md), or
  * is named like one of the inputs the project keeps out of the repository: bootloader.bin, EEVBlog2_05.bin, option.bytes,
    or a calibration backup (a .bin whose name starts with CAL), or
  * is exactly 24576 bytes and named like a bootloader, or is a raw 12 KiB EEPROM dump (12288 bytes, with the extension of a
    raw dump: .bin .eep .eeprom .dump .dmp .img .dat; a library or resource of that size is not a dump).
The files the project publishes are none of these: firmware builds (EEVBlog.bin of the replacement firmware, any other size),
the table data, the SYNTHETIC EEPROM image (1280 bytes).  A zip is checked member by member.
"""
import hashlib
import os
import sys
import zipfile

V205_SHA256 = '8f885f12f567c2cccd9862d9fe26f127e2a674c9afbce9f7a38d441b3f396722'
NAMES = {'bootloader.bin', 'eevblog2_05.bin', 'option.bytes'}
DUMP_EXT = ('.bin', '.eep', '.eeprom', '.dump', '.dmp', '.img', '.dat')


def members(path):
    """Yield (display name, base name, size, sha256) of every file under path."""
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for i in z.infolist():
                if not i.is_dir():
                    data = z.read(i)
                    yield '%s:%s' % (path, i.filename), os.path.basename(i.filename), len(data), hashlib.sha256(data).hexdigest()
    elif os.path.isdir(path):
        for root, _, files in os.walk(path):
            for n in files:
                p = os.path.join(root, n)
                with open(p, 'rb') as f:
                    data = f.read()
                yield p, n, len(data), hashlib.sha256(data).hexdigest()
    else:
        raise SystemExit('check_no_originals: %s is neither a directory nor a zip' % path)


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    bad, n = [], 0
    for arg in argv:
        for shown, base, size, digest in members(arg):
            n += 1
            low = base.lower()
            if digest == V205_SHA256:
                bad.append('%s is the original v2.05 image' % shown)
            elif low in NAMES:
                bad.append('%s is named like an original input' % shown)
            elif low.startswith('cal') and low.endswith('.bin'):
                bad.append('%s is named like a calibration backup' % shown)
            elif 'bootloader' in low and size == 24576:
                bad.append('%s looks like the bootloader image' % shown)
            elif size == 12288 and low.endswith(DUMP_EXT):
                bad.append('%s is 12288 bytes, the size of a raw data-EEPROM dump' % shown)
    for b in bad:
        print('check_no_originals: FAIL ' + b)
    print('check_no_originals: %d files checked in %d paths, %s' % (n, len(argv), 'FAIL' if bad else 'none is an original image or calibration'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
