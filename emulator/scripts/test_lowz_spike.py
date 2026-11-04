"""Induced emulator test of the LowZ display while a voltage is pending (OF-30 and its port correction, both builds).

    python -I emulator/scripts/test_lowz_spike.py [image]      default firmware/build/EEVBlog.bin

On a meter in LowZ with nothing connected, the first mean after each AC/DC re-apply rises above the 10 V threshold for one
mean (ORIGINAL_FIRMWARE_ISSUES.md OF-30, port correction); the emulated front end settles at once, so the spike is induced:
50 V DC is applied until the detector has counted one mean above the threshold (0x2000023A 5 -> 4), then the input is
open again.  T1: during and after that single mean the main digits never show "-----" (they keep "0.0").  T2: 100 V DC
applied for good: the digits keep "0.0" for the first mean, then show "-----", then the value 100.0 after the five means
of the detector, as OF-30 describes.  T3 (production image): at an AC/DC re-apply of the dead band lowz_bar_hold is set;
50 V applied within that settling mean leaves the bar count at 0 until the mean is handled, then the bar shows it.
The main digits are sampled every 5 ms.  The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_CONFIRM_CNT = 0x2000023A                        # means still needed to confirm a voltage (5 in the dead band)
ADDR_MODE = 0x2000803C
ADDR_BAR_COUNT = 0x20008041                          # bar segment count (bargraph_count_from_value)


def main_text(e):
    return T.DEC.text(e.snapshot()['lcd'])[0].replace(' ', '')


def volts(e, v):
    e.command({'input': {'kind': 'V', 'value': v, 'ac': False}})


def run_tests(image, a_hold):
    e = T.make(image)
    e.command({'dial': 1})
    volts(e, 0.0)
    e.advance(5.0)
    T.check('LowZ (mode 0), "0.0" with no input', T.rd(e, ADDR_MODE) == 0 and main_text(e) == '0.0', 'main %r' % main_text(e))

    print('T1 a single mean above the threshold')
    volts(e, 50.0)
    seen = set()
    for _ in range(400):                             # up to 2 s until the first pending mean
        e.advance(0.005)
        seen.add(main_text(e))
        if T.rd(e, ADDR_CONFIRM_CNT) == 4:
            break
    T.check('the detector counted one mean above the threshold', T.rd(e, ADDR_CONFIRM_CNT) == 4,
            'count %d' % T.rd(e, ADDR_CONFIRM_CNT))
    volts(e, 0.0)
    for _ in range(300):                             # 1.5 s
        e.advance(0.005)
        seen.add(main_text(e))
    T.check('no "-----" for a single mean; the digits stay "0.0"', seen == {'0.0'}, 'seen %r' % sorted(seen))

    print('T2 a real voltage')
    e.advance(2.0)
    volts(e, 100.0)
    seq = []
    for _ in range(800):                             # 4 s
        e.advance(0.005)
        t = main_text(e)
        if not seq or seq[-1] != t:
            seq.append(t)
    T.check('100 V DC: "0.0", then "-----", then 100.0', seq[:3] == ['0.0', '-----', '100.0'], 'sequence %r' % seq[:6])
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])

    if a_hold is None:
        print('T3 skipped: no lowz_bar_hold in this image (strict build)')
        return
    print('T3 the bargraph holds during the settling mean (production)')
    e = T.make(image)
    e.command({'dial': 1})
    volts(e, 0.0)
    e.advance(4.0)
    for _ in range(600):                             # wait for an AC/DC re-apply of the dead band
        e.advance(0.002)
        if T.rd(e, a_hold) == 1:
            break
    T.check('lowz_bar_hold set by the re-apply', T.rd(e, a_hold) == 1)
    volts(e, 50.0)                                   # a voltage within the settling mean: the bar must wait for the mean
    counts = []
    for _ in range(600):
        e.advance(0.002)
        counts.append((T.rd(e, a_hold), T.rd(e, ADDR_BAR_COUNT)))
        if T.rd(e, a_hold) == 0:
            break
    T.check('bar count unchanged (0) while held', all(c == 0 for h, c in counts if h == 1), 'counts %r' % counts[-5:])
    e.advance(0.5)
    T.check('after the mean the bar shows the voltage', T.rd(e, ADDR_BAR_COUNT) > 0, 'count %d' % T.rd(e, ADDR_BAR_COUNT))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    try:
        a_hold = T.symbol(os.path.join(os.path.dirname(image), '121gw.map'), 'lowz_bar_hold')
    except SystemExit:                               # T.symbol exits when the symbol is missing (strict build)
        a_hold = None
    run_tests(image, a_hold)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
