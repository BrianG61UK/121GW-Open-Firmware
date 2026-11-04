"""Induced emulator test of the battery voltage trim (production image, DESIGN.md 10 IMP-27, FEATURES.md 2.16).

    python -I emulator/scripts/test_battery_trim.py [image]      default firmware/build/EEVBlog.bin (production build)

B+ = 5.00 V (command 'battery').  T1: no trim (EEPROM 0x02A = 0x00 and 0xFF): the battery page shows "BAT5.0" and
pwr_bat_cv is the untrimmed value.  T2: EEPROM 0x02A = 115 (t = +15, +3.0 %): the value is round(v x 1.030).  T3: on the
battery page long SETUP starts the edit ("bA" and the voltage in 0.01 V), five PEAK steps lower the value by 1.0 %, long
SETUP saves and only EEPROM 0x02A changes (to 95); the trim stops at -50 (no wrap); SETUP short leaves an edit unsaved
and the saved trim acts again; the next edit starts from the saved trim.  T4: an unsaved edit is undone by the
edit timeout (induced: the counter 0x20008070 set one tick before its end).  T5: the low-battery symbol follows the
trimmed value (B+ 4.20 V with t = -50, -10 %: 3.78 V, below the 4.1 V limit).
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_EDIT = 0x2000806E
ADDR_EDIT_TIMER = 0x20008070
ADDR_BAT_VALUE = 0x20007FBA                          # battery value / 10 (0.1 V)
ADDR_LOWBAT = 0x200080F9


def meter(image, byte, vbat=5.0):
    e = T.make(image, {0x2A: byte})
    e.command({'dial': 2})
    e.command({'battery': vbat})
    e.advance(6.0)                                   # the 20-reading history fills (one reading per 200 ms)
    return e


def cv(e, sym):
    return T.rd(e, sym, 2)


def to_bat_page(e):
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    T.press(e, 'SETUP', gap=0.6)                     # item 0 -> item 1


def run_tests(image, a_cv):
    print('T1 no trim')
    base = None
    for byte in (0x00, 0xFF):
        e = meter(image, byte)
        to_bat_page(e)
        v = cv(e, a_cv)
        base = v if base is None else base
        T.check('0x02A = 0x%02X: no trim, page "BAT5.0", value %d (0.01 V) = untrimmed' % (byte, v),
                T.rd(e, ADDR_ITEM) == 1 and T.sub_text(e) == 'BAT5.0' and abs(v - 500) <= 2
                and v == base, 'item %d sub %r' % (T.rd(e, ADDR_ITEM), T.sub_text(e)))
    print('T2 stored trim +3.0 %')
    e = meter(image, 115)
    want = (base * 1030 + 500) // 1000
    T.check('0x02A = 115: value %d = round(%d x 1.030) = %d' % (cv(e, a_cv), base, want), cv(e, a_cv) == want)
    T.check('battery value / 10 = %d' % (want // 10), T.rd(e, ADDR_BAT_VALUE, 2) == want // 10)
    print('T3 edit on the battery page')
    e = meter(image, 0x00)
    to_bat_page(e)
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.check('long SETUP on item 1: edit on (v2.05: refused)', T.rd(e, ADDR_EDIT) == 1)
    for _ in range(5):
        T.press(e, 'PEAK', gap=0.3)
    e.advance(0.6)
    want = (base * 990 + 500) // 1000
    texts = T.sample_texts(e)
    shown = 'BA%d.%02d' % (want // 100, want % 100)
    T.check('5 x PEAK: -1.0 %%, value %d, page "bA" + 0.01 V (%s)' % (want, shown), cv(e, a_cv) == want and shown in texts,
            'cv %d samples %r' % (cv(e, a_cv), texts))
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save: only EEPROM 0x02A changed, to 95', diff == {0x2A: (0, 95)}, 'diff %r' % (diff,))
    T.check('edit off after the save, page "BAT" again', T.rd(e, ADDR_EDIT) == 0 and T.sub_text(e).startswith('BAT'),
            'sub %r' % T.sub_text(e))
    T.long_press(e, 'SETUP')
    for _ in range(60):
        T.press(e, 'PEAK', hold=0.1, gap=0.1)
    e.advance(0.6)
    want = (base * 900 + 500) // 1000
    T.check('60 x PEAK stops at -10 %% (value %d)' % want, cv(e, a_cv) == want, 'cv %d' % cv(e, a_cv))
    T.press(e, 'SETUP', gap=0.6)                     # leave without a save
    want = (base * 990 + 500) // 1000
    T.check('SETUP short leaves the edit unsaved: the saved -1.0 %% acts again (value %d)' % want,
            T.rd(e, ADDR_EDIT) == 0 and cv(e, a_cv) == want and e.m.eeprom[0x2A] == 95, 'cv %d' % cv(e, a_cv))
    to_bat_page(e)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.6)
    want = (base * 992 + 500) // 1000
    T.check('the next edit starts from the saved trim: REL gives -0.8 %% (value %d)' % want, cv(e, a_cv) == want,
            'cv %d' % cv(e, a_cv))
    print('T4 edit timeout')
    e.m.uc.mem_write(ADDR_EDIT_TIMER, bytes([0xF0]))
    e.advance(1.5)
    want = (base * 990 + 500) // 1000
    T.check('timeout: edit off, the saved -1.0 %% again (value %d)' % want, T.rd(e, ADDR_EDIT) == 0 and cv(e, a_cv) == want,
            'edit %d cv %d' % (T.rd(e, ADDR_EDIT), cv(e, a_cv)))
    print('T5 low-battery limit uses the trimmed value')
    e = meter(image, 50, vbat=4.2)
    T.check('B+ 4.20 V, t = -50: value %d (0.01 V) below 4.1 V, low battery' % cv(e, a_cv),
            cv(e, a_cv) < 410 and T.rd(e, ADDR_LOWBAT) == 1, 'lowbat %d' % T.rd(e, ADDR_LOWBAT))
    e = meter(image, 0x00, vbat=4.2)
    T.check('B+ 4.20 V, no trim: not low', T.rd(e, ADDR_LOWBAT) == 0, 'cv %d' % cv(e, a_cv))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    a_cv = T.symbol(os.path.join(os.path.dirname(image), '121gw.map'), 'pwr_bat_cv')
    run_tests(image, a_cv)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
