"""Induced emulator test of the logged power in the VA functions (production image, GitHub issue 46, firmware log/log.s
log_shown, ORIGINAL_FIRMWARE_ISSUES.md OF-35).

    python -I emulator/scripts/test_log_va.py [image]      default firmware/build/EEVBlog.bin (production build)

DCmVA (mA jack, VA position, MODE) with a FAT32 card image and a steady source of 3.05 V and 2.5 mA (7.625 mVA).
In the VA functions the meter measures the voltage and the current in turn; between two power results the value behind
the display holds those voltage and current means, which F-1.35 logged as the main reading.  Checks:
  V1 interval 1 s: every data row of the CSV is "DCmVA,<power>,mVA,DCV,<V>,V,DCmA,<I>,mA": the power is that of the
     source (within 0.5 %) and of the row's own V and mA (within 0.5 %), never a voltage or current mean
  V2 tr-Ch, threshold 50 counts, interval 0: the first record, then none in 6 s of the steady source (the change test
     compares the power, not the alternating means)
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_log_trigger as L  # noqa: E402
import test_log_minmax_time as M  # noqa: E402
T = L.T

ADDR_MODE = 0x2000803C
DCMVA = 23
VOLTS, AMPS = 3.05, 0.0025
POWER = VOLTS * AMPS * 1000.0                        # mVA


def va_meter(image, ee):
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = L.card(), 64
    e = T.make(image, {0x1E: 0, **ee})
    e.command({'jack': 'mA', 'plugged': True})
    e.command({'dial': 6})
    e.command({'input': {'kind': 'VA', 'value': VOLTS, 'amps': AMPS, 'ac': False}})
    e.advance(2.0)
    for _ in range(4):
        if T.rd(e, ADDR_MODE) == DCMVA:
            break
        T.press(e, 'MODE')
        e.advance(1.5)
    T.check('DCmVA reached (mode %d)' % T.rd(e, ADDR_MODE), T.rd(e, ADDR_MODE) == DCMVA)
    e.advance(4.0)                                   # autorange and smoothing settled
    return e


def run_tests(image):
    print('V1 logged rows, interval 1 s')
    e = va_meter(image, L.ee_trig(0, 1))
    card = T.Emulator.sdcard_path
    T.check('logging started', L.start(e))
    e.advance(12.0)
    T.long_press(e, 'MEM')
    e.advance(3.0)
    T.check('logging stopped', T.rd(e, L.ADDR_LOGGING) == 0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e                                            # the card image is complete once the meter has written it
    rows = [ln.split(',') for ln in M.csv_lines(card) if ln.split(',')[0].isdigit()]
    T.check('data rows present', len(rows) >= 10, 'rows=%d' % len(rows))
    bad = []
    for f in rows:
        try:
            ok = [x.strip() for x in (f[3], f[5], f[6], f[8], f[9], f[11])] == ['DCmVA', 'mVA', 'DCV', 'V', 'DCmA', 'mA']
            p, v, i = float(f[4]), float(f[7]), float(f[10])
        except (IndexError, ValueError):
            bad.append(','.join(f))
            continue
        if not ok or abs(p - POWER) > 0.005 * POWER or abs(p - v * i) > 0.005 * POWER:
            bad.append('%s (V x mA = %.3f)' % (','.join(f), v * i))
    T.check('every row: power %.3f mVA = V x mA' % POWER, rows and not bad, '; '.join(bad[:4]))

    print('V2 tr-Ch, threshold 50 counts, interval 0')
    e = va_meter(image, L.ee_trig(1, 0, 50))
    L.start(e)
    e.advance(2.0)
    n1 = L.total(e)
    T.check('the first record of the session', n1 == 1, 'records=%d' % n1)
    e.advance(6.0)
    T.check('steady power: no more records', L.total(e) == n1, 'records=%d' % L.total(e))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
