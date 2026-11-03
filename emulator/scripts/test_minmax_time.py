"""Induced emulator test of the time pages tHI and tLo of MIN/MAX (production image, FEATURES.md 2.6, DESIGN.md 10 IMP-21,
ui/mmtime.s).

    python -I emulator/scripts/test_minmax_time.py [image]      default firmware/build/EEVBlog.bin (production build)

DCV; the clock chip model is set to 23:59:40 so that the minute and the hour roll during the test.  MIN/MAX on, the input
steps up (a new maximum before 00:00) and down (a new minimum after 00:00).  Checks: SETUP short goes Sd -> tHI -> tLo ->
item 0; tHI shows "tHI" on the sub display and the hour-minute of the maximum on the main display, tLo the same for the
minimum, both equal to the clock chip copy (0x200080DA / 0x200080DB) read right after each step; 24-hour and 12-hour
(EEPROM 0x020 bit 3); a positive overload (manual range, 10 V): tHI shows the time in place of "OFL", tLo "-----"; HOLD
keeps the held display; ending MIN/MAX sends the page back to item 0.  The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_MM_STATE = 0x2000804E
ADDR_HOUR = 0x200080DA
ADDR_MINUTE = 0x200080DB
ADDR_REDRAW = 0x20008062


def main_text(e):
    return T.DEC.text(e.snapshot()['lcd'])[0]


def volts(e, v, wait=0.0):
    e.command({'input': {'kind': 'V', 'value': v, 'ac': False}})
    if wait:
        e.advance(wait)


def meter(image, ee):
    e = T.make(image, {0x1E: 0, **ee})
    e.nju.reg[5], e.nju.reg[6], e.nju.reg[7] = 0x23, 0x59, 0x40     # BCD 23:59:40
    e.command({'dial': 2})
    volts(e, 1.0, 3.0)
    return e


def minmax_on(e):
    e.command({'key': 'MINMAX', 'down': True})
    e.advance(0.15)
    e.command({'key': 'MINMAX', 'down': False})
    e.advance(0.5)
    return T.rd(e, ADDR_MM_STATE) != 0 and T.rd(e, ADDR_ITEM) == 32


def hm(e):
    return T.rd(e, ADDR_HOUR), T.rd(e, ADDR_MINUTE)


def fmt(h, m, h12):
    if h12:
        h = h % 12 or 12
        return ('%2d-%02d' % (h, m))
    return '%02d-%02d' % (h, m)


def steps(image, h12):
    print('T%d %s clock' % (2 if h12 else 1, '12-hour' if h12 else '24-hour'))
    e = meter(image, {0x20: 0x08} if h12 else {})
    T.check('MIN/MAX on, page n', minmax_on(e))
    volts(e, 1.5, 1.0)
    t_max = hm(e)
    T.check('maximum taken before midnight', t_max == (23, 59), 'time=%r' % (t_max,))
    e.advance(25.0)
    volts(e, 0.5, 1.0)
    t_min = hm(e)
    T.check('minimum taken after midnight', t_min == (0, 0), 'time=%r' % (t_min,))
    T.press(e, 'SETUP', gap=0.4)
    T.check('n -> Sd', T.rd(e, ADDR_ITEM) == 33)
    T.press(e, 'SETUP', gap=0.6)
    T.check('Sd -> tHI: sub "tHI" (decoded TH1)', T.rd(e, ADDR_ITEM) == 34 and T.sub_text(e) == 'TH1  ', 'sub=%r' % T.sub_text(e))
    want = fmt(*t_max, h12)
    T.check('tHI main %r' % want, main_text(e) == want, 'main=%r' % main_text(e))
    T.press(e, 'SETUP', gap=0.6)
    T.check('tHI -> tLo: sub "tLo"', T.rd(e, ADDR_ITEM) == 35 and T.sub_text(e) == 'TLo  ', 'sub=%r' % T.sub_text(e))
    want = fmt(*t_min, h12)
    T.check('tLo main %r' % want, main_text(e) == want, 'main=%r' % main_text(e))
    T.press(e, 'SETUP', gap=0.6)
    T.check('tLo -> item 0, the reading on the main display', T.rd(e, ADDR_ITEM) == 0 and '-' not in main_text(e),
            'item=%d main=%r' % (T.rd(e, ADDR_ITEM), main_text(e)))
    return e


def run_tests(image):
    steps(image, False)
    e = steps(image, True)

    print('T3 HOLD and the end of MIN/MAX')
    e.m.uc.mem_write(ADDR_ITEM, bytes([34]))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    e.advance(0.6)
    shown = main_text(e)
    T.check('tHI selected again: the time', shown == '11-59', 'main=%r' % shown)
    T.press(e, 'HOLD', gap=0.3)
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    volts(e, 2.0, 1.0)
    T.check('HOLD: the main display stays', main_text(e) == shown, 'main=%r' % main_text(e))
    T.press(e, 'HOLD', gap=0.3)                      # with MIN/MAX on the second HOLD press switches HOLD off
    e.m.uc.mem_write(ADDR_ITEM, bytes([35]))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    e.advance(0.6)
    e.command({'key': 'MINMAX', 'down': True})
    e.advance(2.5)                                   # long MINMAX ends MIN/MAX
    e.command({'key': 'MINMAX', 'down': False})
    e.advance(0.6)
    T.check('MIN/MAX off: item 0', T.rd(e, ADDR_MM_STATE) == 0 and T.rd(e, ADDR_ITEM) == 0,
            'state=%d item=%d' % (T.rd(e, ADDR_MM_STATE), T.rd(e, ADDR_ITEM)))

    print('T4 positive overload')
    e = meter(image, {})
    volts(e, 0.1, 2.0)
    T.press(e, 'RANGE', gap=0.5)                     # manual range: the 5 V range of 0.1 V
    volts(e, 10.0, 1.0)
    T.check('MIN/MAX on', minmax_on(e))
    e.advance(1.0)
    t = hm(e)
    e.m.uc.mem_write(ADDR_ITEM, bytes([34]))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    e.advance(0.6)
    T.check('tHI: the time of the overload maximum %r in place of OFL' % fmt(*t, False), main_text(e) == fmt(*t, False),
            'main=%r' % main_text(e))
    e.m.uc.mem_write(ADDR_ITEM, bytes([35]))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    e.advance(0.6)
    T.check('tLo: no minimum yet, "-----"', main_text(e) == '-----', 'main=%r' % main_text(e))
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    e.advance(0.6)
    T.check('item 0: OFL as v2.05', 'OFL' in main_text(e).replace('0', 'O'), 'main=%r' % main_text(e))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
