"""Induced emulator test of the current-loop percent view of DCmA (production image, DESIGN.md 10 IMP-24, FEATURES.md 2.14).

    python -I emulator/scripts/test_loop_percent.py [image]      default firmware/build/EEVBlog.bin (production build)

DCmA: mA jack plugged, dial A (EEPROM 0x0B default).  EEPROM 0x028 = 1 (4..20 mA): 4, 12, 20 mA show 0.00, 50.00, 100.00 %;
0 mA -25.00 %; 3.5 and 4.5 mA (range 0) -3.13 and 3.13 % (rounded half away from zero); the % sign is on and the A sign
off.  0x028 = 2 (0..20 mA): 10 mA shows 50.00 %.  0x028 = 0: the current as v2.05 (4.0000 mA).  REL on: the REL display,
not the loop view.  Page LP: in DCmA SETUP short from dSP (item 24) goes to LP (item 37, "L4-20"); REL steps, long SETUP saves
and changes only EEPROM 0x028.  The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_MODE = 0x2000803C
ADDR_ITEM = 0x20008037


def meter(image, code):
    e = T.make(image, {0x28: code})
    e.command({'jack': 'mA', 'plugged': True})
    e.command({'dial': 8})
    e.advance(3.0)
    return e


def amps(e, a, wait=2.0):
    e.command({'input': {'kind': 'A', 'value': a, 'ac': False}})
    e.advance(wait)


def view(e):
    s = e.snapshot()
    main = T.DEC.text(s['lcd'])[0].replace(' ', '')
    segs = T.DEC.segments(s['lcd'])
    return main, ('Sub%' in segs), ('SegA' in segs)


def run_tests(image):
    print('T1 4..20 mA')
    e = meter(image, 1)
    T.check('DCmA (mode 19)', T.rd(e, ADDR_MODE) == 19, 'mode=%d' % T.rd(e, ADDR_MODE))
    for a, want in ((0.004, '0.00'), (0.012, '50.00'), (0.020, '100.00'), (0.0, '-25.00'), (0.0035, '-3.13'), (0.0045, '3.13')):
        amps(e, a)
        main, pct, unit_a = view(e)
        T.check('%.4f A shows %s %% (%% on, A off)' % (a, want), main == want and pct and not unit_a,
                'main %r %%=%r A=%r' % (main, pct, unit_a))
    print('T2 0..20 mA')
    e = meter(image, 2)
    amps(e, 0.010)
    main, pct, unit_a = view(e)
    T.check('10 mA shows 50.00 %', main == '50.00' and pct, 'main %r' % main)
    print('T3 off and REL')
    e = meter(image, 0)
    amps(e, 0.004)
    main, pct, unit_a = view(e)
    T.check('off: the current 4.0000 mA', main == '4.0000' and not pct, 'main %r %%=%r' % (main, pct))
    e = meter(image, 1)
    amps(e, 0.012)
    T.press(e, 'REL', gap=1.5)
    main, pct, unit_a = view(e)
    T.check('REL on: the REL difference, not the loop view', main in ('0.000', '0.0000', '-0.000', '-0.0000') and not pct,
            'main %r %%=%r' % (main, pct))
    print('T4 page LP')
    e = meter(image, 0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([24]))
    T.press(e, 'SETUP', gap=0.4)
    T.check('DCmA: dSP -> LP "LPOFF"', T.rd(e, ADDR_ITEM) == 37 and T.sub_text(e) == 'LP0FF', 'item %d sub %r' % (T.rd(e, ADDR_ITEM), T.sub_text(e)))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.4)
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('REL then save: "L4-20", only EEPROM 0x028 changed to 1', diff == {0x28: (0, 1)} and T.sub_text(e) == 'L4-20',
            'diff %r sub %r' % (diff, T.sub_text(e)))
    T.press(e, 'SETUP', gap=0.4)
    T.check('LP -> CL (item 25)', T.rd(e, ADDR_ITEM) == 25)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
