"""Induced emulator test of the platinum RTD temperature view of OHM (production image, DESIGN.md 10 IMP-25, FEATURES.md 2.15).

    python -I emulator/scripts/test_rtd.py [image]      default firmware/build/EEVBlog.bin (production build)

OHM: dial 5 with EEPROM 0x0B = 9.  The expected temperature is computed here from the resistance the meter measured (the
BLE value 0x20007D70 = D and the range) with the exact inverse of the IEC 60751 Callendar-Van Dusen equation, rounded to
0.1 degree; the display must equal it (0.1 tolerance only for a value on a rounding boundary) and lie within 0.5 degC of
the nominal temperature of the applied resistance.
  T1 Pt100 (EEPROM 0x029 = 1): 100.00, 138.51, 18.52 (range 0), 390.48 ohm -> 0.0, 100.0, -200.0, 850.0 degC; degC on,
     ohm and k off; 18.50 ohm (-200.05 degC) and 10 ohm "-OFL", 390.50 ohm (850.06 degC) and 400 ohm " OFL ".
  T2 degF (0x200080AB = 0): 138.51 ohm -> 212.0 degF, degF on.
  T3 Pt1000 (0x029 = 2): 1385.06 ohm (range 2) -> 100.0 degC; 0x029 = 0: the resistance as v2.05, ohm on.
  T4 REL: 100.20 ohm, REL (lead zeroing; the range is fixed), then 138.71 ohm: D = 38.51 ohm is converted (view kept).
  T5 MIN/MAX page Sd (item 33): the standard deviation keeps the ohm sign (no degC mask).
  T6 page Pt: SETUP short from dSP (item 24) goes to Pt (item 38, "PtOFF", decoded as "PT0FF"); REL steps, long SETUP saves and changes only
     EEPROM 0x029; Pt -> CL (item 25).
The helpers are those of test_backlight_timer.py.
"""
import os
import sys
from fractions import Fraction as F

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_MODE = 0x2000803C
ADDR_RANGE = 0x2000803D
ADDR_ITEM = 0x20008037
ADDR_BLE_VALUE = 0x20007D70
ADDR_UNIT_C = 0x200080AB
A, B, C = F(39083, 10 ** 7), F(-5775, 10 ** 10), F(-4183, 10 ** 15)
OHM_MOHM = {0: 1, 1: 10, 2: 100, 3: 1000}            # mohm per count of OHM ranges 0..3


def w(t):
    t = F(t)
    v = 1 + A * t + B * t * t
    if t < 0:
        v += C * (t - 100) * t ** 3
    return v


def t_exact(ratio):
    lo, hi = F(-200), F(850)
    for _ in range(60):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if w(mid) < ratio else (lo, mid)
    return float((lo + hi) / 2)


def meter(image, code, wait=6.0, ohms=100.0):
    e = T.make(image, {0x0B: 9, 0x29: code})
    e.command({'dial': 5})
    e.command({'input': {'kind': 'ohm', 'value': ohms}})
    e.advance(wait)                                  # OHM starts at range 6 and ranges down
    return e


def ohm(e, r, wait=3.0):
    e.command({'input': {'kind': 'ohm', 'value': r}})
    e.advance(wait)


def view(e):
    s = e.snapshot()
    main = T.DEC.text(s['lcd'])[0].replace(' ', '')
    segs = T.DEC.segments(s['lcd'])
    return main, segs


def expected(e, r0, fahrenheit=False):
    d = T.rd(e, ADDR_BLE_VALUE, 4)
    d = d - (1 << 32) if d & 0x80000000 else d
    rng = T.rd(e, ADDR_RANGE)
    t = t_exact(F(d * OHM_MOHM[rng], r0 * 1000))
    if fahrenheit:
        t = t * 1.8 + 32
    return t, d, rng


def check_temp(e, name, r0, nominal, fahrenheit=False):
    main, segs = view(e)
    t, d, rng = expected(e, r0, fahrenheit)
    try:
        shown = float(main)
    except ValueError:
        shown = None
    sign = 'SegTempF' if fahrenheit else 'SegTempC'
    ok = (shown is not None and abs(shown - round(t, 1)) <= 0.1 + 1e-9 and abs(shown - nominal) <= 0.5
          and sign in segs and 'SegR' not in segs and 'Segk' not in segs)
    T.check(name, ok, 'main %r expected %.3f (D %d range %d) %s=%r R=%r k=%r'
            % (main, t, d, rng, sign, sign in segs, 'SegR' in segs, 'Segk' in segs))


def run_tests(image):
    print('T1 Pt100')
    e = meter(image, 1)
    T.check('OHM (mode 9)', T.rd(e, ADDR_MODE) == 9, 'mode=%d' % T.rd(e, ADDR_MODE))
    T.check('degC selected (EEPROM default)', T.rd(e, ADDR_UNIT_C) != 0)
    for r, nominal in ((100.0, 0.0), (138.51, 100.0), (18.52, -200.0), (390.48, 850.0)):
        ohm(e, r)
        check_temp(e, '%.2f ohm shows %.1f degC' % (r, nominal), 100, nominal)
    for r, want in ((18.50, '-0FL'), (10.0, '-0FL'), (390.50, '0FL'), (400.0, '0FL')):
        ohm(e, r)
        main, segs = view(e)
        T.check('%.1f ohm shows %s' % (r, want), main == want and 'SegTempC' in segs, 'main %r' % main)
    print('T2 degF')
    e.m.uc.mem_write(ADDR_UNIT_C, bytes([0]))
    ohm(e, 138.51)
    check_temp(e, '138.51 ohm shows 212.0 degF', 100, 212.0, fahrenheit=True)
    main, segs = view(e)
    T.check('degC off in degF', 'SegTempC' not in segs)
    print('T3 Pt1000 and off')
    e = meter(image, 2, ohms=1385.06)
    check_temp(e, '1385.06 ohm (Pt1000) shows 100.0 degC', 1000, 100.0)
    T.check('Pt1000 in range 2 (5.0000 kohm)', T.rd(e, ADDR_RANGE) == 2, 'range %d' % T.rd(e, ADDR_RANGE))
    e = meter(image, 0)
    main, segs = view(e)
    T.check('off: the resistance 100.00 ohm (+-0.02, front-end noise), ohm on',
            main.replace('.', '').isdigit() and abs(float(main) - 100.0) <= 0.02 and 'SegR' in segs
            and 'SegTempC' not in segs, 'main %r' % main)
    print('T4 REL lead zeroing')
    e = meter(image, 1, ohms=100.20)
    T.press(e, 'REL', gap=2.0)
    ohm(e, 138.71)
    check_temp(e, 'REL at 100.20 ohm, then 138.71 ohm: 38.51 ohm converted', 100, -152.9)
    print('T5 MIN/MAX page Sd')
    e = meter(image, 1)
    T.press(e, 'MINMAX', gap=1.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([33]))
    e.advance(2.0)
    main, segs = view(e)
    T.check('page Sd: ohm sign kept, no degC', 'SegR' in segs and 'SegTempC' not in segs, 'main %r R=%r C=%r'
            % (main, 'SegR' in segs, 'SegTempC' in segs))
    print('T6 page Pt')
    e = meter(image, 0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([24]))
    T.press(e, 'SETUP', gap=0.4)
    T.check('OHM: dSP -> Pt "PtOFF"', T.rd(e, ADDR_ITEM) == 38 and T.sub_text(e) == 'PT0FF',
            'item %d sub %r' % (T.rd(e, ADDR_ITEM), T.sub_text(e)))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.4)
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('REL then save: "Pt100", only EEPROM 0x029 changed to 1', diff == {0x29: (0, 1)} and T.sub_text(e) == 'PT100',
            'diff %r sub %r' % (diff, T.sub_text(e)))
    T.press(e, 'SETUP', gap=0.4)
    T.check('Pt -> CL (item 25)', T.rd(e, ADDR_ITEM) == 25)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
