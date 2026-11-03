"""Induced emulator test of auto-hold at zero in OHM and DIODE (production image, DESIGN.md 10 IMP-22).

    python -I emulator/scripts/test_autohold_zero.py [image]      default firmware/build/EEVBlog.bin (production build)

Auto-hold is switched on with two HOLD presses (HOLD, then auto-hold).  OHM (dial Ohm/beep, EEPROM 0x0B = 9) and DIODE
(0x0B = 11): probes open (OL), then a short (0 ohm / 0.000 V) for 6 s (OHM autoranges down from range 6 first), then open again.  Checks: the short is captured (the
capture beep: PE7 high at least once while the short is applied, buzzer setting on) and the main display keeps the captured
zero after the probes open.  DCV (dial V): 0 V for 2 s is not captured (no beep): open probes read about 0 there, so the 1000
count threshold stays.  The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402


def main_text(e):
    return T.DEC.text(e.snapshot()['lcd'])[0]


def run(image, dial, mode, short, open_):
    e = T.make(image, {0x0B: mode, 0x1E: 1} if mode is not None else {0x1E: 1})
    e.command({'dial': dial})
    e.command({'input': open_})
    e.advance(3.0)
    T.press(e, 'HOLD', gap=0.4)
    T.press(e, 'HOLD', gap=0.4)                      # second press: auto-hold
    e.advance(1.0)
    e.command({'input': short})
    beeps = 0
    for _ in range(600):                             # 6 s in 10 ms steps (OHM autoranges down from range 6 first)
        e.advance(0.01)
        beeps += e.snapshot()['buzzer'] or 0
    shown_short = main_text(e)
    e.command({'input': open_})
    e.advance(2.0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    return beeps, shown_short, main_text(e)


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    opn = {'kind': 'open'}
    for name, dial, mode, short in (('OHM', 5, 9, {'kind': 'ohm', 'value': 0.0}),
                                    ('DIODE', 5, 11, {'kind': 'diode', 'value': 0.0})):
        beeps, during, after = run(image, dial, mode, short, opn)
        T.check('%s: the short is captured (beep)' % name, beeps > 0, 'PE7 high in %d samples, display %r' % (beeps, during))
        T.check('%s: the captured zero stays after the probes open' % name, after == during and 'L' not in after,
                'during %r, after %r' % (during, after))
    beeps, during, after = run(image, 2, None, {'kind': 'V', 'value': 0.0, 'ac': False}, {'kind': 'V', 'value': 0.0, 'ac': False})
    T.check('DCV: 0 V is not captured (no beep)', beeps == 0, 'PE7 high in %d samples' % beeps)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
