"""Induced emulator test of the date and time of the closing MAX and MIN rows of the log file (production image, FEATURES.md
2.6, DESIGN.md 10 IMP-21, log/mmtime.s).

    python -I emulator/scripts/test_log_minmax_time.py [image]      default firmware/build/EEVBlog.bin (production build)

DCV with a FAT32 card image, interval 1 s, logging started and stopped with MEM long while the input steps 1.0 -> 1.5 ->
0.5 -> 1.0 V.  The CSV is read back from the card image.  Checks: the MAX row is "MAX,row,func,value,unit,date,time," with
the date and time of the data row it names, the same for MIN; the maximum is a 1.5 V row and the minimum a 0.5 V row.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_log_trigger as L  # noqa: E402
T = L.T
from diff.fat32 import Volume  # noqa: E402


def csv_lines(path):
    with Volume(path) as v:
        for p, e in v.walk():
            if p.upper().endswith('.CSV'):
                return v.read_chain(e['cluster'], e['size']).decode('latin1').split('\r\n')
    return []


def run_tests(image):
    print('T1 closing rows with date and time')
    e = L.meter(image, L.ee_trig(0, 1))
    card = T.Emulator.sdcard_path
    T.check('logging started', L.start(e))
    for v in (1.0, 1.5, 0.5, 1.0):
        L.volts(e, v, 4.0)
    T.long_press(e, 'MEM')
    e.advance(3.0)
    T.check('logging stopped', T.rd(e, L.ADDR_LOGGING) == 0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e                                            # the card image is complete once the meter has written it
    lines = csv_lines(card)
    rows = {}
    for ln in lines:
        f = ln.split(',')
        if f and f[0].isdigit():
            rows[f[0]] = f
    T.check('data rows present', len(rows) >= 12, 'rows=%d' % len(rows))
    for tag, want in (('MAX', '01.5000'), ('MIN', '00.5000')):
        r = [ln.split(',') for ln in lines if ln.startswith(tag + ',')]
        T.check('one %s row' % tag, len(r) == 1, 'rows=%r' % r)
        if len(r) != 1:
            continue
        f = r[0]
        T.check('%s: 8 fields and a final comma' % tag, len(f) == 8 and f[7] == '', 'fields=%r' % f)
        d = rows.get(f[1])
        T.check('%s: names data row %s' % (tag, f[1]), d is not None)
        if d is None or len(f) != 8:
            continue
        T.check('%s: value %s of the row (%s)' % (tag, f[3], want), f[3] == want and d[4] == want, 'row=%r' % d)
        T.check('%s: function and unit as v2.05 (%s %s)' % (tag, f[2], f[4]), f[2] == d[3] and f[4] == d[5])
        T.check('%s: date and time %s %s = those of the row' % (tag, f[5], f[6]), (f[5], f[6]) == (d[1], d[2]),
                'row date/time %s %s' % (d[1], d[2]))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
