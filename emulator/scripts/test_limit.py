"""Induced emulator test of the limit test (production image, FEATURES.md 2.1, DESIGN.md 10 IMP-20).

    python -I emulator/scripts/test_limit.py [image]      default firmware/build/EEVBlog.bin (production build)

DCV with known inputs, buzzer setting on (EEPROM 0x1E = 1).  Checks: dSP -> Lt -> Lo -> HI; "Lo---" before a capture; the
capture of the displayed value with REL in the edit and the label / value alternation; switching on refused without
both limits (refusal beep); switching on with Lo above HI (swapped); the verdict page after the edit; PASS / HI / Lo
for inputs inside, above and below, an overload counted as HI; the refusal pattern on leaving PASS and the accept beep
on returning; RANGE short and long refused while the test is on; a mode change ending the test (range_manual restored).
The helpers are those of test_backlight_timer.py.  The decoder reads the 7-segment I as 1 ("H1").
"""
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_RANGE = 0x2000803D
ADDR_RANGE_MANUAL = 0x20008042
ADDR_D = 0x20007D64


def volts(e, v, wait=2.0):
    e.command({'input': {'kind': 'V', 'value': v, 'ac': False}})
    e.advance(wait)


def goto(e, item):
    e.m.uc.mem_write(ADDR_ITEM, bytes([item]))
    e.m.uc.mem_write(0x20008062, bytes([1]))         # sub display redraw
    e.advance(0.3)


def buzz_pulses(e, seconds):
    """Number of buzzer on-switchings within the next `seconds` (sampled every 2 ms)."""
    n, prev = 0, e.snapshot()['buzzer']
    for _ in range(int(seconds / 0.002)):
        e.advance(0.002, slice_ms=2)
        b = e.snapshot()['buzzer']
        if b and not prev:
            n += 1
        prev = b
    return n


def capture(e, item):
    goto(e, item)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.3)
    T.long_press(e, 'SETUP')
    e.advance(0.3)


def switch(e):
    goto(e, 27)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.3)
    T.long_press(e, 'SETUP')
    e.advance(0.5)


def run_tests(image, a_on):
    e = T.make(image, {0x1E: 1})
    e.command({'dial': 2})
    volts(e, 1.0, 3.0)

    print('T1 pages and captures')
    goto(e, 24)
    T.press(e, 'SETUP', gap=0.4)
    T.check('SETUP short on dSP shows Lt: "LtOFF"', T.rd(e, ADDR_ITEM) == 27 and T.sub_text(e) == 'LT0FF', 'sub=%r' % T.sub_text(e))
    T.press(e, 'SETUP', gap=0.4)
    T.check('Lt -> Lo: "Lo---"', T.rd(e, ADDR_ITEM) == 28 and T.sub_text(e) == 'Lo---', 'sub=%r' % T.sub_text(e))
    T.press(e, 'SETUP', gap=0.4)
    T.check('Lo -> HI: "HI---"', T.rd(e, ADDR_ITEM) == 29 and T.sub_text(e) == 'H1---', 'sub=%r' % T.sub_text(e))
    switch(e)
    T.check('switching on without limits is refused', T.rd(e, a_on) == 0)
    capture(e, 28)                                   # Lo = 1.0000 V
    seen = set(T.sample_texts(e, n=8, step=0.25))
    T.check('Lo page alternates "Lo" and the value 1.0000', any(t.startswith('Lo') for t in seen) and '1.0000' in seen,
            'seen=%r' % (seen,))
    volts(e, 1.2)
    capture(e, 29)                                   # HI = 1.2000 V

    print('T2 verdicts and beeps')
    volts(e, 1.1)
    switch(e)
    T.check('test on, verdict page, range frozen', T.rd(e, a_on) == 1 and T.rd(e, ADDR_ITEM) == 36
            and T.rd(e, ADDR_RANGE_MANUAL) == 1, 'item=%d' % T.rd(e, ADDR_ITEM))
    e.advance(0.5)
    T.check('1.1 V: "PASS"', T.sub_text(e) == 'PA55 ', 'sub=%r' % T.sub_text(e))
    e.command({'input': {'kind': 'V', 'value': 1.3, 'ac': False}})
    n = buzz_pulses(e, 1.5)
    T.check('1.3 V: "HI" and the refusal pattern (2 pulses)', T.sub_text(e) == 'H1   ' and n == 2, 'sub=%r pulses=%d' % (T.sub_text(e), n))
    e.command({'input': {'kind': 'V', 'value': 1.1, 'ac': False}})
    n = buzz_pulses(e, 1.5)
    T.check('back to 1.1 V: "PASS" and the accept beep (1 pulse)', T.sub_text(e) == 'PA55 ' and n == 1, 'sub=%r pulses=%d' % (T.sub_text(e), n))
    volts(e, 0.9, 1.5)
    T.check('0.9 V: "Lo"', T.sub_text(e) == 'Lo   ', 'sub=%r' % T.sub_text(e))
    volts(e, 9.0, 1.5)                               # above the frozen 5 V range: overload
    T.check('overload (positive): "HI"', T.sub_text(e) == 'H1   ', 'sub=%r main=%r' % (T.sub_text(e), T.DEC.text(e.snapshot()['lcd'])[0]))
    volts(e, 1.1, 1.5)
    r0 = T.rd(e, ADDR_RANGE)
    T.press(e, 'RANGE', gap=0.4)
    T.check('RANGE short refused', T.rd(e, ADDR_RANGE) == r0 and T.rd(e, ADDR_RANGE_MANUAL) == 1)
    T.long_press(e, 'RANGE')
    T.check('RANGE long refused (stays manual)', T.rd(e, ADDR_RANGE_MANUAL) == 1 and T.rd(e, a_on) == 1)

    print('T3 mode change ends the test; Lo above HI')
    e.command({'dial': 5})                           # Ohm
    e.advance(2.0)
    T.check('mode change: test off', T.rd(e, a_on) == 0)
    e.command({'dial': 2})
    volts(e, 1.2, 3.0)
    capture(e, 28)                                   # Lo = 1.2 V
    volts(e, 1.0)
    capture(e, 29)                                   # HI = 1.0 V (below Lo)
    volts(e, 1.1)
    switch(e)
    e.advance(0.5)
    T.check('Lo above HI: swapped, 1.1 V passes', T.rd(e, a_on) == 1 and T.sub_text(e) == 'PA55 ', 'sub=%r' % T.sub_text(e))
    switch(e)
    T.check('Lt REL again: test off, range_manual restored (0, auto)', T.rd(e, a_on) == 0 and T.rd(e, ADDR_RANGE_MANUAL) == 0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'lt_on'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
