"""Induced emulator test of the samples per mean of MDC (production image, DESIGN.md 10 IMP-66, src/mdc/ad1.s mdc_retune).

    python -I emulator/scripts/test_mean_count.py [image]      default firmware/build/EEVBlog.bin

The sample count of the mean being built (0x20008080) is read every millisecond; it counts 1, 2, ... and is cleared when
the mean is complete, so the largest count seen plus one is N.  Outside calibration mode (IMP-66: sized for the AD1 result
period of chop rows, HARDWARE_TEST.md H5) and with calibration mode set in RAM (0x2000808A = 1: the counts of before
IMP-66, so a calibration capture averages as many samples as before):
  T1 BEEP 26 (64); T2 OHM ranges 0..4 6, 6, 15, 8, 8 (8, 8, 32, 16, 16), range 6 8 (8); T3 DIODE 12 (16);
  T4 DCmV range 0 12 (16); T5 TEMP 12 (16); T6 DCuA 12 (16).
The ranges of OHM are set with RANGE as on the meter (open input: autorange ends in range 6, the first press holds it,
each further press steps to the next range).  The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_backlight_timer as T  # noqa: E402

ADDR_MODE = 0x2000803C
ADDR_RANGE = 0x2000803D
ADDR_COUNT = 0x20008080                              # samples in the mean being built (ad1_accumulate_average)
ADDR_CAL = 0x2000808A                                # calibration mode (1)


def observed_n(e, seconds):
    """Largest count seen plus one, over `seconds` read every millisecond."""
    top = 0
    for _ in range(int(seconds * 1000)):
        e.advance(0.001)
        top = max(top, T.rd(e, ADDR_COUNT))
    return top + 1


def meter(image, dial, patch):
    e = T.make(image, patch)
    e.command({'dial': dial})
    e.advance(3.0)
    return e


def check(e, label, want, seconds, cal):
    if cal:
        e.m.uc.mem_write(ADDR_CAL, bytes([1]))
        e.advance(0.3)
    n = observed_n(e, seconds)
    T.check('%s%s: N = %d (mode %d range %d)' % (label, ' (calibration mode)' if cal else '', want, T.rd(e, ADDR_MODE),
                                                T.rd(e, ADDR_RANGE)), n == want, 'N %d' % n)
    if cal:
        e.m.uc.mem_write(ADDR_CAL, bytes([0]))
        e.advance(0.3)


def run_tests(image):
    for cal in (False, True):
        print('T1 BEEP')
        e = meter(image, 5, {0x0B: 10})
        check(e, 'BEEP', 64 if cal else 26, 1.0, cal)
        print('T2 OHM')
        e = meter(image, 5, {0x0B: 9})
        T.check('OHM, open input: range 6', T.rd(e, ADDR_RANGE) == 6, 'range %d' % T.rd(e, ADDR_RANGE))
        check(e, 'OHM r6', 8, 1.5, cal)
        T.press(e, 'RANGE', gap=0.6)                 # hold range 6
        want = (8, 8, 32, 16, 16) if cal else (6, 6, 15, 8, 8)
        for r in range(5):
            T.press(e, 'RANGE', gap=0.6)
            e.advance(1.0)
            ok = T.rd(e, ADDR_RANGE) == r
            T.check('OHM range %d set with RANGE' % r, ok, 'range %d' % T.rd(e, ADDR_RANGE))
            if ok:
                check(e, 'OHM r%d' % r, want[r], 1.5, cal)
        print('T3 DIODE')
        check(meter(image, 5, {0x0B: 11}), 'DIODE', 16 if cal else 12, 1.5, cal)
        print('T4 DCmV range 0')
        e = meter(image, 3, {0x09: 3})
        if T.rd(e, ADDR_RANGE) == 0:
            check(e, 'DCmV r0', 16 if cal else 12, 2.5, cal)
        else:
            T.check('DCmV, open input: range 0', False, 'range %d' % T.rd(e, ADDR_RANGE))
        print('T5 TEMP')
        check(meter(image, 3, {0x09: 5}), 'TEMP', 16 if cal else 12, 2.5, cal)
        print('T6 DCuA')
        check(meter(image, 7, {0x0D: 0x11}), 'DCuA', 16 if cal else 12, 1.5, cal)


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
