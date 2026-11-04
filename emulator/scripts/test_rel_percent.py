"""Induced emulator test of REL in percent (production image, FEATURES.md 2.3, DESIGN.md 10 IMP-11).

    python -I emulator/scripts/test_rel_percent.py [image]      default firmware/build/EEVBlog.bin (production build)

Drives the emulated meter in DCV: SETUP page rEL (bL -> bt -> Ld -> rEL -> dSP outside TEMP) set to percent and saved, REL on
at 1 V, then other inputs; checks the main display (percent with the decimal point by magnitude, minus sign), the signs
(V off and % on while the view is shown, V back after REL off), that the BLE value 0x20007D70 keeps the REL value in
counts, the base-0 dashes and the over-99999 % OFL (base set in RAM, the OL flag untouched), that only EEPROM byte 0x020
bit 0 is written (other bits kept), the fallback of an erased byte, the setting after a power cycle and the undo of an
unsaved edit by the edit timeout.  The helpers are those of test_backlight_timer.py.
"""
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037                               # setup item
ADDR_D = 0x20007D64                                  # displayed reading D (counts, after REL)
ADDR_BASE = 0x20007DA8                               # REL base
ADDR_BLE_VALUE = 0x20007D70                          # last drawn main value, the BLE value
ADDR_REL = 0x20008058                                # rel_active
ADDR_OL = 0x20008046                                 # overload flag


def main_text(e):
    return T.DEC.text(e.snapshot()['lcd'])[0]


def signs(e):
    w = e.snapshot()['lcd']
    return {'V': w[4] >> 10 & 1, '%': w[0] >> 17 & 1, 'minus': w[3] >> 7 & 1}


def s32(e, addr):
    return struct.unpack('<i', e.m.uc.mem_read(addr, 4))[0]


def volts(e, v, wait=3.0):
    e.command({'input': {'kind': 'V', 'value': v, 'ac': False}})
    e.advance(wait)


def to_item(e, want):
    for _ in range(16):
        if T.rd(e, ADDR_ITEM) == want:
            break
        T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)


def pct_of(text):
    """Main text as a number ('-' and blanks allowed), or None."""
    try:
        return float(text.replace(' ', ''))
    except ValueError:
        return None


def run_tests(image, a_relp):
    print('T1 the page rEL')
    e = T.make(image, {0x20: 0x06})                  # bits 2..1 set (reserved for 2.6), bit 0 difference
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('0x020 = 0x06 loads difference', T.rd(e, a_relp) == 0)
    to_item(e, 39)                                   # the page Ld (IMP-28), between bt and rEL
    T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('SETUP short on Ld shows rEL: "rEL-d" (decoded rEL-D)', T.rd(e, ADDR_ITEM) == 22 and 'rEL-D' in texts, 'samples=%r' % (texts,))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('REL: percent, "rEL-P"', T.rd(e, a_relp) == 1 and 'rEL-P' in texts, 'samples=%r' % (texts,))
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save wrote only 0x020 = 0x07 (bits 2..1 kept)', diff == {0x20: (0x06, 0x07)}, 'diff=%r' % (diff,))
    T.press(e, 'SETUP', gap=0.5)
    T.check('outside TEMP: SETUP short on rEL goes to dSP (item 24)', T.rd(e, ADDR_ITEM) == 24)

    print('T2 the percent view')
    volts(e, 1.0)
    T.press(e, 'REL', gap=0.5)
    e.advance(2.0)
    base = s32(e, ADDR_BASE)
    T.check('REL on, base about 1 V', T.rd(e, ADDR_REL) == 1 and base != 0, 'base=%d' % base)
    for v, want in ((1.1, 10.0), (0.5, -50.0), (3.0, 200.0), (1.0005, 0.05)):
        volts(e, v)
        txt = main_text(e)
        p = pct_of(txt)
        sg = signs(e)
        d = s32(e, ADDR_D)
        exact = d * 100.0 / base
        T.check('%.4f V: main %r = %.3f %% (exact %.4f)' % (v, txt, p if p is not None else float('nan'), exact),
                p is not None and abs(p - exact) <= (0.0015 if abs(exact) < 100 else 0.015) and abs(p - want) < 0.5)
        T.check('%.4f V: V off, %% on, minus = sign' % v, sg['V'] == 0 and sg['%'] == 1 and sg['minus'] == (p < 0),
                'signs=%r' % (sg,))
        T.check('%.4f V: BLE value = D in counts' % v, s32(e, ADDR_BLE_VALUE) == d, 'ble=%d d=%d' % (s32(e, ADDR_BLE_VALUE), d))

    print('T3 base 0 and over 99999 %')
    e.m.uc.mem_write(ADDR_BASE, struct.pack('<i', 0))
    volts(e, 1.5, 2.0)
    txt = main_text(e)
    T.check('base 0: "-----", no minus, OL flag 0', txt.strip() == '-----' and signs(e)['minus'] == 0 and T.rd(e, ADDR_OL) == 0,
            'main=%r' % txt)
    e.m.uc.mem_write(ADDR_BASE, struct.pack('<i', 1))
    volts(e, 1.5, 2.0)
    txt = main_text(e)
    T.check('base 1 count: " OFL ", OL flag 0', 'OFL' in txt.replace('0', 'O') and T.rd(e, ADDR_OL) == 0, 'main=%r' % txt)

    print('T4 REL off restores the units')
    T.press(e, 'REL', gap=0.5)
    e.advance(2.0)
    sg = signs(e)
    T.check('REL off: V on, % off, reading in volts', T.rd(e, ADDR_REL) == 0 and sg['V'] == 1 and sg['%'] == 0,
            'signs=%r main=%r' % (sg, main_text(e)))

    print('T5 stored values and edit timeout')
    e.power_cycle()
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('power cycle: percent from the EEPROM', T.rd(e, a_relp) == 1)
    e = T.make(image, {0x20: 0xFF})
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('0x020 = 0xFF reads as difference', T.rd(e, a_relp) == 0)
    to_item(e, 39)                                   # the page Ld (IMP-28), between bt and rEL
    T.press(e, 'SETUP', gap=0.5)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.check('rEL edited to percent', T.rd(e, a_relp) == 1)
    e.advance(125.0)
    T.check('after the timeout: difference again, EEPROM unchanged', T.rd(e, a_relp) == 0 and e.m.eeprom[0x20] == 0xFF)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'set_relp'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
