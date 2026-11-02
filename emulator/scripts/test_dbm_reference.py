"""Induced emulator test of the selectable dBm reference (production image, FEATURES.md 2.2, DESIGN.md 10 IMP-08).

    python -I emulator/scripts/test_dbm_reference.py [image]      default firmware/build/EEVBlog.bin (production build)

Drives the emulated meter: ACV (dial V, MODE short) with a 1.000 V 1 kHz sine, SETUP to the dBm page (item 11), then
checks the value for each reference against 10 log10(x^2 / divisor), the edit texts, the units (dB m, dB alone for dBV),
that only EEPROM byte 0x011 is written and only by the save, the reference after a power cycle, the fallback of invalid
bytes to 600 ohm, and that the sub minus sign of a negative dBm value is off while the reference text is shown.
The helpers (meter construction, key presses, text decoding, map lookup) are those of test_backlight_timer.py.
"""
import math
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_DBM = 0x20007E94                                # dBm value, float32 (mac_dbm)
ADDR_ITEM = 0x20008037                               # setup item
ADDR_MODE = 0x2000803C                               # meter mode (2 = ACV)


def dbm(e):
    return struct.unpack('<f', e.m.uc.mem_read(ADDR_DBM, 4))[0]


def units(e):
    w0 = e.snapshot()['lcd'][0]                      # w0b19 SubdB, w0b18 Subm (analysis/lcd_map.md 4.3)
    return ('dB' if w0 >> 19 & 1 else '') + ('m' if w0 >> 18 & 1 else '')


def minus(e):
    return e.snapshot()['lcd'][4] >> 29 & 1          # w4b29 sub minus


def acv(e, volts):
    e.command({'dial': 2})
    e.advance(3.0)
    T.press(e, 'MODE', gap=0.5)                      # DCV -> ACV
    e.command({'input': {'kind': 'V', 'value': volts, 'ac': True, 'freq': 1000}})
    e.advance(3.0)


def to_item11(e):
    for _ in range(14):
        if T.rd(e, ADDR_ITEM) == 11:
            break
        T.press(e, 'SETUP', gap=0.5)
    e.advance(1.0)


def near(a, b):
    return abs(a - b) < 0.002


def run_tests(image, a_ref):
    expect = [10 * math.log10(1 / d) for d in (0.6, 0.05, 0.075, 1.0)]

    print('T1 600 ohm default and the edit')
    e = T.make(image, {0x11: 0})
    acv(e, 1.0)
    to_item11(e)
    T.check('ACV page 11 reached', T.rd(e, ADDR_MODE) == 2 and T.rd(e, ADDR_ITEM) == 11)
    T.check('600 ohm: 2.218 dBm, units dB m', near(dbm(e), expect[0]) and units(e) == 'dBm', 'value=%.4f' % dbm(e))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    e.advance(0.3)
    texts = T.sample_texts(e)
    T.check('edit shows "r 600"', 'r 600' in texts, 'samples=%r' % (texts,))
    T.press(e, 'REL', gap=0.5)
    e.advance(1.5)
    texts = T.sample_texts(e)
    T.check('REL: 50 ohm, "r  50"', T.rd(e, a_ref) == 1 and 'r  50' in texts, 'samples=%r' % (texts,))
    T.check('50 ohm: 13.010 dBm', near(dbm(e), expect[1]), 'value=%.4f' % dbm(e))
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save wrote only 0x011 = 1', diff == {0x11: (0, 1)}, 'diff=%r' % (diff,))

    print('T2 75 ohm, dBV, wrap and abandon')
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    e.advance(1.5)
    T.check('75 ohm: 11.249 dBm', T.rd(e, a_ref) == 2 and near(dbm(e), expect[2]), 'value=%.4f' % dbm(e))
    T.press(e, 'REL', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('dBV text "r dbV" (decoded r DBU: b and d drawn lower case, V as U)', 'r DBU' in texts, 'samples=%r' % (texts,))
    T.long_press(e, 'SETUP')
    e.advance(2.0)
    T.check('dBV: 0.000, units dB alone, EEPROM 3', near(dbm(e), expect[3]) and units(e) == 'dB' and e.m.eeprom[0x11] == 3,
            'value=%.4f units=%r' % (dbm(e), units(e)))
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.check('REL from dBV wraps to 600 ohm', T.rd(e, a_ref) == 0)
    T.press(e, 'PEAK', gap=0.5)
    T.press(e, 'PEAK', gap=0.5)
    T.check('PEAK twice from 600 ohm gives 75 ohm', T.rd(e, a_ref) == 2)
    T.press(e, 'SETUP', gap=0.5)
    T.check('SETUP short ends the edit without a save', e.m.eeprom[0x11] == 3)
    e.power_cycle()
    acv(e, 1.0)
    T.check('power cycle: dBV from the EEPROM', T.rd(e, a_ref) == 3)

    print('T3 stored values')
    for value, want in ((0xFF, 0), (4, 0), (2, 2)):
        e = T.make(image, {0x11: value})
        e.command({'dial': 2})
        e.advance(3.0)
        T.check('0x011 = 0x%02X reads as %d' % (value, want), T.rd(e, a_ref) == want and e.m.eeprom[0x11] == value)

    print('T4 negative value: the minus sign is off during the edit')
    e = T.make(image, {0x11: 0})
    acv(e, 0.1)
    to_item11(e)
    T.check('0.1 V: -17.782 dBm with the minus sign', near(dbm(e), 10 * math.log10(0.01 / 0.6)) and minus(e) == 1,
            'value=%.4f' % dbm(e))
    T.long_press(e, 'SETUP')
    e.advance(0.3)
    seen = []
    for _ in range(4):
        seen.append((T.sub_text(e), minus(e)))
        e.advance(0.25)
    T.check('edit: "r 600" without the minus sign', ('r 600', 0) in seen and all(m == 0 for _, m in seen), 'seen=%r' % (seen,))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'set_dbm_ref'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
