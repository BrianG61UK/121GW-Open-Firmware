"""Induced emulator test of SD access beyond 4 GiB (both images, ORIGINAL_FIRMWARE_ISSUES.md OF-57).

    python -I emulator/scripts/test_sd_large_card.py [image] [--sizes 8,32,128]      default firmware/build/EEVBlog.bin

For each card size (GiB; default 8 = just past the 4 GiB wrap, 32 = the largest SDHC card, 128 = an SDXC card formatted
FAT32, which FatFs R0.08a mounts as it has no exFAT; 2048 = the largest FAT32 volume, 2 TiB - 1 MiB, as the sector
count is 32 bits) a FAT32 card image (sparse file) in which every cluster but the
last 512 is marked bad (0x0FFFFFF7) in both FATs, so the file has to go to the top of the card (FSInfo free count and
next-free hint adjusted).  DCV 1 V, logging
started with MEM long for about 70 s (one ring flush of 60 records and more) and stopped.  Checks: the CSV file exists,
its first cluster lies above 4 GiB, the content read back by the host's FAT reader holds the header and the data rows;
the sectors at (data sector mod 2^23), where v2.05's 32-bit byte address would write, still hold what the format put
there (the boot sector, FSInfo, FAT and root directory are unchanged apart from the entries of the new file).
The helpers are those of test_backlight_timer.py.
"""
import hashlib
import os
import shutil
import struct
import sys
import tempfile

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402
from emu.fat32 import FatError, Volume  # noqa: E402

LIMIT = 1 << 23                                      # first sector at 4 GiB
ADDR_LOGGING = 0x20007FE1
LAST_DIR = [None]


def make_card(path, size):
    clusters = format_fat32(path, size)
    with open(path, 'r+b') as f:
        bs = f.read(512)
        spc, rsvd, nfats = bs[13], struct.unpack_from('<H', bs, 14)[0], bs[16]
        fatsz = struct.unpack_from('<I', bs, 36)[0]
        data = rsvd + nfats * fatsz
        first_high = clusters + 2 - 512                                      # the last 512 clusters stay free
        entries = struct.pack('<I', 0x0FFFFFF7) * (first_high - 3)           # clusters 3 .. first_high - 1: bad
        for n in range(nfats):
            f.seek((rsvd + n * fatsz) * 512 + 3 * 4)
            f.write(entries)
        for base in (1, 7):                                                  # FSInfo and its backup
            f.seek(base * 512 + 488)
            free = struct.unpack('<I', f.read(4))[0]
            f.seek(base * 512 + 488)
            f.write(struct.pack('<II', free - (first_high - 3), first_high - 1))
    return {'spc': spc, 'data': data, 'first_high': first_high, 'rsvd': rsvd, 'fatsz': fatsz, 'nfats': nfats}


def sector_hashes(path, sectors):
    out = {}
    with open(path, 'rb') as f:
        for s in sectors:
            f.seek(s * 512)
            out[s] = hashlib.sha256(f.read(512)).hexdigest()
    return out


def run_tests(image, size_gib):
    d = tempfile.mkdtemp(prefix='bigcard_')
    LAST_DIR[0] = d
    card = os.path.join(d, 'card.img')
    size = size_gib * 1024 ** 3
    if size >= 2048 * 1024 ** 3:
        size = 2048 * 1024 ** 3 - 1024 * 1024        # FAT32 / FatFs limit: the sector count is 32 bits (2 TiB - 1 MiB)
    g = make_card(card, size)
    print('T %d GiB card, free space only in the last 512 clusters (first free cluster %d, sector %d)'
          % (size_gib, g['first_high'], g['data'] + (g['first_high'] - 2) * g['spc']))
    hi_sector = g['data'] + (g['first_high'] - 2) * g['spc']
    alias = [(hi_sector + i) % LIMIT for i in range(64)]                     # where a 32-bit address would land
    before = sector_hashes(card, alias)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, size // (1024 * 1024)
    e = T.make(image, {0x1E: 0, 0x18: 0, 0x19: 1})                           # interval 1 s
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(3.0)
    T.long_press(e, 'MEM')
    e.advance(1.0)
    T.check('logging started', T.rd(e, ADDR_LOGGING) == 1)
    e.advance(70.0)
    T.long_press(e, 'MEM')
    e.advance(5.0)
    T.check('logging stopped', T.rd(e, ADDR_LOGGING) == 0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e
    after = sector_hashes(card, alias)
    changed = [sct for sct in alias if before[sct] != after[sct]]
    T.check('nothing written at the 32-bit alias of the file sectors', not changed, 'changed sectors %r' % changed[:8])
    found = None
    try:
        with Volume(card) as v:
            for p, ent in v.walk():
                if p.upper().endswith('.CSV'):
                    found = (p, ent, v.read_chain(ent['cluster'], ent['size']).decode('latin1'))
        T.check('the card is still a readable FAT32 volume', True)
    except FatError as ex:
        T.check('the card is still a readable FAT32 volume', False, str(ex))
    T.check('a CSV file exists', found is not None)
    if found:
        p, ent, text = found
        T.check('its first cluster is one of the free clusters at the top', ent['cluster'] >= g['first_high'], 'cluster %d' % ent['cluster'])
        lines = text.split('\r\n')
        rows = [ln for ln in lines if ln[:1].isdigit()]
        T.check('header present (START line)', lines[0].startswith('START,'), 'first line %r' % lines[0][:40])
        T.check('at least 60 data rows read back', len(rows) >= 60, 'rows=%d' % len(rows))
        T.check('MAX and MIN rows present', any(ln.startswith('MAX,') for ln in lines) and any(ln.startswith('MIN,') for ln in lines))


def main(argv):
    sizes = [8, 32, 128]
    if '--sizes' in argv:
        i = argv.index('--sizes')
        sizes = [int(x) for x in argv[i + 1].split(',')]
        argv = argv[:i] + argv[i + 2:]
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    for gib in sizes:
        run_tests(image, gib)
        shutil.rmtree(LAST_DIR[0], ignore_errors=True)   # the card image (up to 1 GiB of FAT data) is not kept
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
