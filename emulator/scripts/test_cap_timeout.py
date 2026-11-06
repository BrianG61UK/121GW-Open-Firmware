"""Emulator test of the CAP no-result timeout (firmware/DESIGN.md IMP-43, experimental).

    python -I emulator/scripts/test_cap_timeout.py [IMAGE]          (default firmware/build/EEVBlog.bin)

Range 1 (100 nF) in auto range waits 2.5 s for a counter result before the timeout moves it to range 2 (1 uF), where a
capacitor near 100 nF is shown with a tenth of the resolution; v2.05 waits 2.0 s (1.5 s with the PF8 strap).  The
timeout is the u16 countdown 0x20007FC4 in 10 ms TIM2 ticks, reloaded at every counter result (mres/cap.s fn_0800EC28):
the largest value seen while the meter measures is the reload.  Checks: 50 nF in auto -> range 1, reload 250; the same
in manual range 1 -> 300 (as v2.05); 500 nF in auto -> range 2, reload 200 (as v2.05).
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

COUNTDOWN = 0x20007FC4                # u16 CAP timeout in TIM2 ticks
METER_RANGE = 0x2000803D
RANGE_MANUAL = 0x20008042
METER_MODE = 0x2000803C


def largest_reload(e, seconds=3.0):
    top = 0
    for _ in range(int(seconds / 0.02)):
        e.advance(0.02)
        top = max(top, T.rd(e, COUNTDOWN, 2))
    return top


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    print('T CAP timeout reload by range and auto / manual (IMP-43)')
    e = T.make(image)
    e.command({'dial': 5})                                   # OHM position; MODE steps through its modes, CAP among them
    e.advance(3.0)
    for _ in range(6):                                       # the starting mode is the one the EEPROM remembers for the
        if T.rd(e, METER_MODE) == 12:                        # position, so press until CAP is shown
            break
        T.press(e, 'MODE')
        e.advance(1.0)
    T.check('CAP mode', T.rd(e, METER_MODE) == 12, repr(T.rd(e, METER_MODE)))
    e.command({'input': {'kind': 'F', 'value': 50e-9}})
    e.advance(8.0)
    rng = T.rd(e, METER_RANGE)
    T.check('50 nF in auto range: range 1 (100 nF)', rng == 1 and T.rd(e, RANGE_MANUAL) == 0, repr(rng))
    top = largest_reload(e)
    print('  range 1 auto: largest countdown %d' % top)
    T.check('range 1 auto reloads 250 ticks (2.5 s)', 245 <= top <= 250, repr(top))
    T.press(e, 'RANGE')                                      # manual range: stays on the present range
    e.advance(3.0)
    rng = T.rd(e, METER_RANGE)
    T.check('manual range 1', rng == 1 and T.rd(e, RANGE_MANUAL) == 1, repr((rng, T.rd(e, RANGE_MANUAL))))
    top = largest_reload(e)
    print('  range 1 manual: largest countdown %d' % top)
    T.check('range 1 manual reloads 300 ticks (as v2.05)', 295 <= top <= 300, repr(top))
    T.long_press(e, 'RANGE')                                 # back to auto range
    e.command({'input': {'kind': 'F', 'value': 500e-9}})
    e.advance(8.0)
    rng = T.rd(e, METER_RANGE)
    T.check('500 nF in auto range: range 2 (1 uF)', rng == 2 and T.rd(e, RANGE_MANUAL) == 0, repr(rng))
    top = largest_reload(e)
    print('  range 2 auto: largest countdown %d' % top)
    T.check('range 2 auto reloads 200 ticks (as v2.05)', 195 <= top <= 200, repr(top))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
