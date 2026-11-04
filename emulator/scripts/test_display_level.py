"""Induced emulator test of the display level (production image, FEATURES.md 2.4, DESIGN.md 10 IMP-12).

    python -I emulator/scripts/test_display_level.py [image]      default firmware/build/EEVBlog.bin (production build)

Measures, in ACV (smoothing threshold 20 counts, depth 10, a mean every 100 ms), for display level 1 and level 2: the time
a step of 15 counts (inside the threshold, so it goes through the smoothing) takes until the reading is within 2 counts
of its final value, and the spread of the reading over 5 s at 1 V.  Checks the page navigation (rEL -> dSP -> CL
outside TEMP, rEL -> tc -> dSP in TEMP), the page texts, that only EEPROM byte 0x013 is written and only by the save, the
level after a power cycle, the fallback of invalid bytes and the undo of an unsaved edit by the edit timeout.
The helpers are those of test_backlight_timer.py.
"""
import os
import statistics
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037                               # setup item
ADDR_D = 0x20007D64                                  # displayed reading D (counts)


def d(e):
    return struct.unpack('<i', e.m.uc.mem_read(ADDR_D, 4))[0]


def acv(e, v, wait=0.0):
    e.command({'input': {'kind': 'V', 'value': v, 'ac': True, 'freq': 1000}})
    if wait:
        e.advance(wait)


def to_item(e, want):
    for _ in range(18):
        if T.rd(e, ADDR_ITEM) == want:
            break
        T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)


def settle_and_noise(image, level):
    e = T.make(image, {0x13: level})
    e.command({'dial': 2})
    e.advance(3.0)
    T.press(e, 'MODE', gap=0.5)                      # ACV
    acv(e, 1.0, 6.0)
    samples = []
    for _ in range(50):
        e.advance(0.1)
        samples.append(d(e))
    spread = statistics.pstdev(samples)
    acv(e, 1.0015)                                   # +15 counts on the 5 V range (1 count = 0.1 mV)
    e.advance(8.0)
    final = statistics.mean(d(e) for _ in range(1))
    acv(e, 1.0, 8.0)
    acv(e, 1.0015)
    t = 0.0
    while abs(d(e) - final) > 2 and t < 8.0:
        e.advance(0.02)
        t += 0.02
    return spread, t, e


def run_tests(image, a_level):
    print('T1 settling and noise in ACV')
    s1, t1, _ = settle_and_noise(image, 0)
    s2, t2, e = settle_and_noise(image, 1)
    print('    level 1: spread %.2f counts, 15-count step settled in %.2f s' % (s1, t1))
    print('    level 2: spread %.2f counts, 15-count step settled in %.2f s' % (s2, t2))
    T.check('level 2 settles at least 3x faster than level 1', t2 * 3 <= t1, 't1=%.2f t2=%.2f' % (t1, t2))
    T.check('level 1 settles within 1.5 s (depth 10 x 100 ms plus the mean)', t1 <= 1.5, 't1=%.2f' % t1)

    print('T2 the page dSP')
    e = T.make(image, {0x13: 0})
    e.command({'dial': 2})
    e.advance(3.0)
    to_item(e, 22)
    T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('outside TEMP: SETUP short on rEL shows dSP: "dSP 1" (decoded D5P 1)', T.rd(e, ADDR_ITEM) == 24 and 'D5P 1' in texts,
            'samples=%r' % (texts,))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('REL: level 2, "dSP 2"', T.rd(e, a_level) == 1 and 'D5P 2' in texts, 'samples=%r' % (texts,))
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save wrote only 0x013 = 1', diff == {0x13: (0, 1)}, 'diff=%r' % (diff,))
    T.press(e, 'SETUP', gap=0.5)
    T.check('SETUP short on dSP (DCV) goes to the page CL (item 25)', T.rd(e, ADDR_ITEM) == 25)
    e.power_cycle()
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('power cycle: level 2 from the EEPROM', T.rd(e, a_level) == 1)

    print('T3 TEMP order, stored values, edit timeout')
    e = T.make(image, {0x09: 5, 0x13: 0})
    e.command({'dial': 3})
    e.advance(3.0)
    to_item(e, 22)
    T.press(e, 'SETUP', gap=0.5)
    T.check('TEMP: rEL -> tc', T.rd(e, ADDR_ITEM) == 23)
    T.press(e, 'SETUP', gap=0.5)
    T.check('TEMP: tc -> dSP', T.rd(e, ADDR_ITEM) == 24)
    for value, want in ((0xFF, 0), (2, 0), (1, 1)):
        e = T.make(image, {0x13: value})
        e.command({'dial': 2})
        e.advance(3.0)
        T.check('0x013 = 0x%02X reads as %d' % (value, want), T.rd(e, a_level) == want and e.m.eeprom[0x13] == value)
    e = T.make(image, {0x13: 0})
    e.command({'dial': 2})
    e.advance(3.0)
    to_item(e, 24)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.check('dSP edited to level 2', T.rd(e, a_level) == 1)
    e.advance(125.0)
    T.check('after the timeout: level 1 again, EEPROM unchanged', T.rd(e, a_level) == 0 and e.m.eeprom[0x13] == 0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'func_dsp_level'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
