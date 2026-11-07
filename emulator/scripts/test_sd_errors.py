"""Induced emulator test of SD transfer errors during logging (both images, ORIGINAL_FIRMWARE_ISSUES.md OF-59).

    python -I emulator/scripts/test_sd_errors.py [--cases a,b,...] [image]      default every case, firmware/build/EEVBlog.bin

Cases (each boots its own emulator): write, read, burst20, forced, burst_all.  CI runs two jobs of this script at the
same time, one per case group (.github/workflows/emulator.yml): all five in one job took 22 .. 38 minutes on a hosted
runner, past the job limit on slow runners.

A 64 MiB FAT32 card image; DCV 1 V, interval 1 s, logging started with MEM long.  The card model's test faults
(emu/sdcard.py SDCard.faults) disturb single data blocks on the bus: 'write_crc' (the card sees a CRC error in a block it
receives and answers with a negative CRC status token: nothing is written), 'read_crc' (the CRC16 of a block the card sends
does not match at the host).  Faults are set at the start of logging and at the first ring flush (about 60 s in).
Checks after logging is stopped: every fault was consumed (the disturbed transfer happened), there is exactly one CSV file
with a valid directory entry (the retry continues the same file), the file read back by the host holds the START header, data rows numbered 1..N without a gap, and the MAX and MIN rows.  The firmware must notice
each disturbed block (disk_write / disk_read return RES_ERROR) and repeat the operation through its retry path; a block
taken as written although the card refused it leaves a hole of zeros or stale data in the file.
The helpers are those of test_backlight_timer.py.
"""
import os
import sys
import tempfile

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402
from diff.fat32 import FatError, Volume  # noqa: E402

ADDR_LOGGING = 0x20007FE1
ADDR_RANGE_MANUAL = 0x20008042


def csv_files(card):
    out = []
    with Volume(card) as v:
        for p, ent in v.walk():
            if p.upper().endswith('.CSV'):
                out.append((p, v.read_chain(ent['cluster'], ent['size']).decode('latin1') if 2 <= ent['cluster'] < 0x0FFFFFF0 or ent['size'] == 0 else None))
    return out


def run_case(image, name, kind, count):
    print('T %s: %d %s fault(s) at the logging start and at the first flush' % (name, count, kind))
    d = tempfile.mkdtemp(prefix='sderr_')
    card = os.path.join(d, 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(image, {0x1E: 0, 0x18: 0, 0x19: 1})
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(3.0)
    e.sdcard.faults[kind] = count
    T.long_press(e, 'MEM')
    e.advance(2.0)
    T.check('logging started', T.rd(e, ADDR_LOGGING) == 1)
    left_start = e.sdcard.faults[kind]
    e.advance(55.0)
    e.sdcard.faults[kind] = count
    e.advance(20.0)
    left_flush = e.sdcard.faults[kind]
    T.long_press(e, 'MEM')
    e.advance(5.0)
    T.check('logging stopped', T.rd(e, ADDR_LOGGING) == 0)
    T.check('the faults were met (start %d, flush %d left)' % (left_start, left_flush), left_start == 0 and left_flush == 0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e
    files = []
    try:
        files = csv_files(card)
    except FatError as ex:
        T.check('card readable', False, str(ex))
    T.check('exactly one CSV file, its directory entry valid', len(files) == 1 and files[0][1] is not None,
            'files %r' % [(p, None if t is None else len(t)) for p, t in files])
    text = files[0][1] if len(files) == 1 else None
    if text is not None:
        lines = text.split('\r\n')
        nums = [int(ln.split(',')[0]) for ln in lines if ln[:1].isdigit()]
        T.check('START header', lines[0].startswith('START,'), 'first line %r' % lines[0][:40])
        T.check('rows 1..N without a gap (N >= 60)', nums == list(range(1, len(nums) + 1)) and len(nums) >= 60,
                'rows %d, first %r, last %r' % (len(nums), nums[:3], nums[-3:]))
        T.check('MAX and MIN rows', any(ln.startswith('MAX,') for ln in lines) and any(ln.startswith('MIN,') for ln in lines))
        T.check('no byte 0 in the file', '\x00' not in text)
    os.remove(card)
    os.rmdir(d)


def run_burst(image, count):
    """count write faults at the first flush: 20 consumed attempts force a new file (OF-60), more stop the logging (OF-61)."""
    print('T burst of %d write faults at the first flush' % count)
    d = tempfile.mkdtemp(prefix='sderr_')
    card = os.path.join(d, 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(image, {0x1E: 0, 0x18: 0, 0x19: 1})
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(3.0)
    T.check('autorange before logging', T.rd(e, ADDR_RANGE_MANUAL) == 0)
    T.long_press(e, 'MEM')
    e.advance(57.0)
    e.sdcard.faults['write_crc'] = count
    e.advance(30.0)
    left = e.sdcard.faults['write_crc']
    e.sdcard.faults['write_crc'] = 0
    logging = T.rd(e, ADDR_LOGGING)
    if logging:
        T.long_press(e, 'MEM')
        e.advance(5.0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    T.check('logging off, autorange back (range_manual %d)' % T.rd(e, ADDR_RANGE_MANUAL),
            T.rd(e, ADDR_LOGGING) == 0 and T.rd(e, ADDR_RANGE_MANUAL) == 0)
    del e
    files = csv_files(card)
    print('  faults left %d, logging after the burst %d, files %r' % (left, logging, [(p, None if t is None else len(t)) for p, t in files]))
    T.check('every CSV file has a valid directory entry', files and all(t is not None for p, t in files))
    if files and all(t is not None for p, t in files):
        T.check('every CSV file starts with the START header', all(t.split('\r\n')[0].startswith('START,') for p, t in files),
                'first lines %r' % [t[:20] for p, t in files])
        nums = sorted(int(ln.split(',')[0]) for p, t in files for ln in t.split('\r\n') if ln[:1].isdigit())
        T.check('the rows of all files: 1..N without a gap or a repeat', nums == list(range(1, len(nums) + 1)),
                'rows %d, last %r' % (len(nums), nums[-3:]))
        T.check('no byte 0 in the files', all('\x00' not in t for p, t in files))
    os.remove(card)
    os.rmdir(d)


def run_forced(image):
    """the card refuses every write until the first series of 20 attempts has failed and the logger has forced a new file
    (log_write_state = 2, the second series); then it works again: the new file must get the START header (OF-60)."""
    print('T card failing for exactly the first series of 20 attempts')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    a_state = T.symbol(mp, 'log_write_state')
    d = tempfile.mkdtemp(prefix='sderr_')
    card = os.path.join(d, 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(image, {0x1E: 0, 0x18: 0, 0x19: 1})
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(3.0)
    T.long_press(e, 'MEM')
    e.advance(57.0)
    e.sdcard.faults['write_crc'] = 10 ** 9
    reached = False
    for _ in range(6000):                            # up to 60 s in 10 ms slices
        e.advance(0.01)
        if T.rd(e, a_state) == 2:
            reached = True
            break
    e.sdcard.faults['write_crc'] = 0
    T.check('the logger reached the second series (new file forced)', reached)
    e.advance(70.0)
    T.long_press(e, 'MEM')
    e.advance(5.0)
    del e
    files = csv_files(card)
    print('  files %r' % [(p, None if t is None else len(t)) for p, t in files])
    T.check('two CSV files with valid directory entries', len(files) == 2 and all(t is not None for p, t in files))
    if len(files) == 2 and all(t is not None for p, t in files):
        T.check('both start with the START header', all(t.split('\r\n')[0].startswith('START,') for p, t in files),
                'first lines %r' % [t[:20] for p, t in files])
        nums = sorted(int(ln.split(',')[0]) for p, t in files for ln in t.split('\r\n') if ln[:1].isdigit())
        T.check('rows of both files 1..N without a gap or a repeat (N >= 60)',
                nums == list(range(1, len(nums) + 1)) and len(nums) >= 60, 'rows %d, last %r' % (len(nums), nums[-3:]))
    os.remove(card)
    os.rmdir(d)


CASES = {'write': lambda img: run_case(img, 'write', 'write_crc', 1),
         'read': lambda img: run_case(img, 'read', 'read_crc', 1),
         'burst20': lambda img: run_burst(img, 20),
         'forced': run_forced,
         'burst_all': lambda img: run_burst(img, 10 ** 9)}


def main(argv):
    argv = list(argv)
    names = list(CASES)
    if argv and argv[0] == '--cases':
        names = argv[1].split(',')
        argv = argv[2:]
        unknown = [n for n in names if n not in CASES]
        if unknown:
            raise SystemExit('unknown case(s) %s; cases: %s' % (', '.join(unknown), ', '.join(CASES)))
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    for n in names:
        CASES[n](image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
