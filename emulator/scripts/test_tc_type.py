"""Induced emulator test of the selectable thermocouple type (production image, FEATURES.md 2.8, DESIGN.md 10 IMP-10).

    python -I emulator/scripts/test_tc_type.py [image]      default firmware/build/EEVBlog.bin (production build)

Drives the emulated meter in TEMP (dial mV/Temp, EEPROM 0x09 = 5, unit degC) with a thermocouple probe of type K, J or T
(stimulus field 'probe', NIST ITS-90 EMF for J and T) at a board temperature of 25 degC, and checks for each type of the
SETUP page tc the displayed temperature at points across its span, the over-range limits (J 936 degC, T 400 degC), the
page navigation (bt -> tc in TEMP -> item 0), the page texts, that only EEPROM byte 0x00F is written and only by the
save, the type after a power cycle, the fallback of invalid bytes and the undo of an unsaved edit by the edit timeout.
The helpers are those of test_backlight_timer.py.
"""
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037                               # setup item
ADDR_TC_FLAG = 0x200080AD                            # thermocouple range flag: 1 over the high limit, 2 below the low
BOARD = 25.0                                         # board (cold-junction) temperature, degC
TOL = 0.3                                            # degC: cold junction from the thermistor (0.1 degC steps), noise


def temp(e, a_result):
    return struct.unpack('<i', e.m.uc.mem_read(a_result, 4))[0] / 10.0


def probe(e, kind, degc):
    e.command({'input': {'kind': 'degC', 'value': degc, 'probe': kind, 'board': BOARD}})
    e.advance(4.0)


def to_item(e, want):
    for _ in range(16):
        if T.rd(e, ADDR_ITEM) == want:
            break
        T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)


def meter(image, ee):
    e = T.make(image, {0x09: 5, 0x10: 1, **ee})          # arrive in TEMP, unit degC
    e.command({'dial': 3})
    e.advance(3.0)
    return e


def points(e, kind, a_result, temps):
    for t in temps:
        probe(e, kind, t)
        v = temp(e, a_result)
        T.check('type %s %7.1f degC reads %7.1f' % (kind, t, v), abs(v - t) <= TOL and T.rd(e, ADDR_TC_FLAG) == 0)


def over(e, kind, t, a_result):
    probe(e, kind, t)
    T.check('type %s %.1f degC: over range (flag 1)' % (kind, t), T.rd(e, ADDR_TC_FLAG) == 1,
            'flag=%d value=%.1f' % (T.rd(e, ADDR_TC_FLAG), temp(e, a_result)))


def under(e, kind, t, a_result):
    probe(e, kind, t)
    T.check('type %s %.1f degC: under range (flag 2)' % (kind, t), T.rd(e, ADDR_TC_FLAG) == 2,
            'flag=%d value=%.1f' % (T.rd(e, ADDR_TC_FLAG), temp(e, a_result)))


def run_tests(image, a_type, a_result):
    print('T1 K (default) and the page')
    e = meter(image, {0x0F: 0})
    T.check('TEMP, type K', T.rd(e, 0x2000803C) == 5 and T.rd(e, a_type) == 0)
    points(e, 'K', a_result, (-150.0, 0.0, 100.0, 500.0, 1000.0))
    to_item(e, 21)
    T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('SETUP short on bt in TEMP shows tc: "tc-K " (decoded Tc-K)', T.rd(e, ADDR_ITEM) == 23 and 'Tc-K ' in texts,
            'samples=%r' % (texts,))
    before = bytes(e.m.eeprom)

    print('T2 J')
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('REL: J, "tc-J "', T.rd(e, a_type) == 1 and 'Tc-J ' in texts, 'samples=%r' % (texts,))
    points(e, 'J', a_result, (-199.0, -150.0, 0.0, 100.0, 500.0, 760.0, 930.0))
    over(e, 'J', 945.0, a_result)
    under(e, 'J', -205.0, a_result)

    print('T3 T')
    T.press(e, 'REL', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('REL: T, "tc-t "', T.rd(e, a_type) == 2 and 'Tc-T ' in texts, 'samples=%r' % (texts,))
    points(e, 'T', a_result, (-199.0, -150.0, 0.0, 100.0, 350.0, 399.0))
    under(e, 'T', -205.0, a_result)
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save wrote only 0x00F = 2', diff == {0x0F: (0, 2)}, 'diff=%r' % (diff,))
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.check('REL from T wraps to K', T.rd(e, a_type) == 0)
    T.press(e, 'PEAK', gap=0.5)
    T.check('PEAK from K gives T', T.rd(e, a_type) == 2)
    T.press(e, 'SETUP', gap=0.5)
    T.check('SETUP short on tc goes to item 0, no save', T.rd(e, ADDR_ITEM) == 0 and e.m.eeprom[0x0F] == 2)
    e.power_cycle()
    e.command({'dial': 3})
    e.advance(3.0)
    T.check('power cycle: T from the EEPROM', T.rd(e, a_type) == 2)
    probe(e, 'T', 200.0)
    T.check('after the power cycle T 200 degC reads 200', abs(temp(e, a_result) - 200.0) <= TOL)

    print('T4 stored values, navigation outside TEMP, edit timeout')
    for value, want in ((0xFF, 0), (3, 0), (1, 1)):
        e = meter(image, {0x0F: value})
        T.check('0x00F = 0x%02X reads as %d' % (value, want), T.rd(e, a_type) == want and e.m.eeprom[0x0F] == value)
    e = T.make(image, {0x0F: 1})
    e.command({'dial': 2})                           # DCV
    e.advance(3.0)
    to_item(e, 21)
    T.press(e, 'SETUP', gap=0.5)
    T.check('outside TEMP: SETUP short on bt goes to item 0', T.rd(e, ADDR_ITEM) == 0)
    e = meter(image, {0x0F: 1})
    to_item(e, 21)
    T.press(e, 'SETUP', gap=0.5)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.check('tc edited to T', T.rd(e, a_type) == 2)
    e.advance(125.0)
    T.check('after the timeout: J again, EEPROM unchanged', T.rd(e, a_type) == 1 and e.m.eeprom[0x0F] == 1)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'mtmp_tc_type'), T.symbol(mp, 'mtmp_temp_result'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
