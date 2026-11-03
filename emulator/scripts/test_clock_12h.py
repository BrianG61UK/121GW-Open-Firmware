"""Induced emulator test of the 12 / 24-hour clock (production image, FEATURES.md 2.12, DESIGN.md 10 IMP-13).

    python -I emulator/scripts/test_clock_12h.py [image]      default firmware/build/EEVBlog.bin (production build)

On the time page (setup item 7) the hour edit buffer (0x200080E0) is stepped with REL through all 24 hours, and the shown
hour is checked: 24-hour "00".."23" as v2.05; 12-hour 0 -> "12", 1..12 -> " 1".."12" (leading zero blank), 13..23 ->
" 1".."11".  Checks the page CL (dSP -> CL -> item 0), that its save changes only bit 3 of EEPROM 0x020 and the save of
rEL only bit 0, the setting after a power cycle and the undo of an unsaved edit by the edit timeout.
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037                               # setup item
ADDR_HOUR_EDIT = 0x200080E0                          # hour edit buffer of item 7


def to_item(e, want):
    for _ in range(20):
        if T.rd(e, ADDR_ITEM) == want:
            break
        T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)


def shown_hour(e):
    """The two hour characters of the time page (the edited field blinks: take a sample where it is drawn)."""
    for t in T.sample_texts(e, n=6, step=0.2):
        if t[:2].strip():
            return t[:2]
    return None


def expect_12(h):
    v = h % 12 or 12
    return '%2d' % v


def hours(image, clk):
    e = T.make(image, {0x20: 0x08 if clk else 0x00})
    e.command({'dial': 2})
    e.advance(3.0)
    to_item(e, 7)
    T.long_press(e, 'SETUP')                         # hour edit
    seen = {}
    for _ in range(24):
        h = T.rd(e, ADDR_HOUR_EDIT)
        seen[h] = shown_hour(e)
        T.press(e, 'REL', gap=0.3)
    T.press(e, 'SETUP', gap=0.5)
    return seen


def run_tests(image, a_clk):
    print('T1 hours on the time page')
    s24 = hours(image, 0)
    bad = {h: v for h, v in s24.items() if v != '%02d' % h}
    T.check('24-hour: every hour shown as 00..23 (as v2.05)', len(s24) == 24 and not bad, 'bad=%r' % (bad,))
    s12 = hours(image, 1)
    bad = {h: v for h, v in s12.items() if v != expect_12(h)}
    T.check('12-hour: 0 -> 12, 13..23 -> 1..11, leading zero blank', len(s12) == 24 and not bad, 'bad=%r' % (bad,))
    print('    12-hour samples: 0 %r, 9 %r, 12 %r, 13 %r, 23 %r' % (s12.get(0), s12.get(9), s12.get(12), s12.get(13), s12.get(23)))

    print('T2 the page CL')
    e = T.make(image, {0x20: 0x07})                  # bits 0..2 set: REL percent and the bits of 2.6 must survive
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('0x020 = 0x07 loads 24-hour', T.rd(e, a_clk) == 0)
    to_item(e, 24)
    T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('SETUP short on dSP shows CL: "CL 24"', T.rd(e, ADDR_ITEM) == 25 and 'CL 24' in texts, 'samples=%r' % (texts,))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('REL: 12-hour, "CL 12"', T.rd(e, a_clk) == 1 and 'CL 12' in texts, 'samples=%r' % (texts,))
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save wrote only bit 3 of 0x020: 0x07 -> 0x0F', diff == {0x20: (0x07, 0x0F)}, 'diff=%r' % (diff,))
    T.press(e, 'SETUP', gap=0.5)
    T.check('SETUP short on CL goes to the limit page Lt (item 27)', T.rd(e, ADDR_ITEM) == 27)
    to_item(e, 22)                                   # rEL: save difference, bit 3 must stay
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    T.check('rEL save changes only bit 0: 0x0F -> 0x0E', e.m.eeprom[0x20] == 0x0E, '0x020=0x%02X' % e.m.eeprom[0x20])
    e.power_cycle()
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('power cycle: 12-hour from the EEPROM', T.rd(e, a_clk) == 1)
    to_item(e, 25)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.check('CL edited to 24-hour', T.rd(e, a_clk) == 0)
    e.advance(125.0)
    T.check('after the timeout: 12-hour again, EEPROM unchanged', T.rd(e, a_clk) == 1 and e.m.eeprom[0x20] == 0x0E)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'set_clk12'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
