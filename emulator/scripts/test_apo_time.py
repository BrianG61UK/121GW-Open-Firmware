"""Induced emulator test of the auto power-off time (firmware IMP-49: set/apot.s, set/setup.s fn_08015A22 / fn_08018460,
pwr/apo.s; EEPROM 0x02B, EEPROM_MAP.md 4.1).

    python -I emulator/scripts/test_apo_time.py [image]                default firmware/build/EEVBlog.bin

The SETUP page APO (item 2) steps with REL through APO.oF, APO. 1, APO.15, APO.30, APO.60 (PEAK backwards); a long SETUP
saves the on / off state in EEPROM 0x016 (as v2.05) and the time code in 0x02B (0 = 30 min, 1 = 1 min, 2 = 15 min,
3 = 60 min).  The countdown (RAM 0x20000230, seconds) is reloaded at every key press with the chosen time, doubled while
MIN/MAX is on; the warning beeps start at 60 s left, at 15 s with the 1-minute time.
  P1 the page: from APO.30 (the synthetic EEPROM) REL gives APO.60, APO.oF, APO. 1, APO.15, APO.30; PEAK goes back; the save
     of APO.15 writes 0x016 = 0 and 0x02B = 2 and no other EEPROM byte
  P2 the countdown after a key press: 30, 1, 15 and 60 min; 15 min with MIN/MAX on: 30 min
  P3 the 1-minute time: no warning beep until 15 s are left, the warning then, the power-off at 60 s (STOP)
  P4 an invalid code (0x02B = 7) reads as 30 min and the byte stays 7
RUN LIMIT: 1 run of this script (8 boots).
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_APO = 0x20000230
ADDR_DISABLE = 0x20008039
EE_ON, EE_TIME = 0x016, 0x02B


def boot(image, patch=None):
    e = T.make(image, patch=patch)
    e.command({'dial': 2})
    e.advance(3.0)
    return e


def shown(e):
    """The page text while it blinks in the edit (the lit phase; the decoder shows O as 0)."""
    for s in T.sample_texts(e, n=6, step=0.2):
        if s.strip():
            return s
    return ''


def countdown(e):
    return T.rd(e, ADDR_APO, 2)


def run_tests(image):
    print('P1 the page APO')
    e = boot(image)
    e.m.uc.mem_write(ADDR_ITEM, bytes([1]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('P1: page 2 shown', T.rd(e, ADDR_ITEM) == 2, 'item %d' % T.rd(e, ADDR_ITEM))
    T.check('P1: APO.30 at the start', T.sub_text(e) == 'AP0.30', repr(T.sub_text(e)))
    T.long_press(e, 'SETUP')
    seen = []
    for _ in range(5):
        T.press(e, 'REL', gap=0.6)
        seen.append(shown(e))
    T.check('P1: REL steps APO.60, APO.oF, APO. 1, APO.15, APO.30', seen == ['AP0.60', 'AP0.oF', 'AP0. 1', 'AP0.15', 'AP0.30'],
            repr(seen))
    T.press(e, 'PEAK', gap=0.6)
    T.check('P1: PEAK goes back to APO.15', shown(e) == 'AP0.15', repr(shown(e)))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    e.advance(0.5)
    diff = sorted(i for i in range(len(before)) if before[i] != e.m.eeprom[i])
    T.check('P1: saved: 0x016 = 0, 0x02B = 2', e.m.eeprom[EE_ON] == 0 and e.m.eeprom[EE_TIME] == 2,
            '0x016 %d 0x02B %d' % (e.m.eeprom[EE_ON], e.m.eeprom[EE_TIME]))
    T.check('P1: no other EEPROM byte changed', set(diff) <= {EE_ON, EE_TIME}, repr([hex(i) for i in diff]))

    print('P2 the countdown')
    for code, want in ((0, 1800), (1, 60), (2, 900), (3, 3600)):
        e = boot(image, {EE_TIME: code})
        T.press(e, 'HOLD')
        T.press(e, 'HOLD')
        c = countdown(e)
        T.check('P2: code %d: countdown about %d s after a key press' % (code, want), want - 3 <= c <= want, 'countdown %d' % c)
    e = boot(image, {EE_TIME: 2})                    # a fresh meter: MIN/MAX is refused while HOLD is on
    T.press(e, 'MINMAX')
    T.press(e, 'MINMAX')                             # the second key beep reloads with MIN/MAX on
    c = countdown(e)
    T.check('P2: 15 min with MIN/MAX on: about 1800 s', T.rd(e, 0x2000804E) != 0 and 1797 <= c <= 1800,
            'minmax_state %d countdown %d' % (T.rd(e, 0x2000804E), c))

    print('P3 the 1-minute time')
    e = boot(image, {EE_TIME: 1})
    beeps = []
    e.gpio['E'].on_output(7, lambda pin, lv, cyc: beeps.append((float(e.m.elapsed_s()), lv)))
    T.press(e, 'HOLD')
    T.press(e, 'HOLD')
    t0 = float(e.m.elapsed_s())
    e.advance(40.0)
    early = [t for t, lv in beeps if lv == 1 and t > t0 + 0.5]
    T.check('P3: no warning beep in the first 40 s', early == [], repr([round(t - t0, 1) for t in early]))
    e.advance(25.0)
    warn = [t - t0 for t, lv in beeps if lv == 1 and t > t0 + 0.5]
    T.check('P3: warning beeps start 15 s before the power-off (about 45 s)', warn and 43 <= warn[0] <= 47,
            repr([round(t, 1) for t in warn][:6]))
    T.check('P3: powered off (STOP) about 60 s after the key press', e.m.rcc.msirange == 0, 'MSIRANGE %d' % e.m.rcc.msirange)

    print('P4 an invalid code')
    e = boot(image, {EE_TIME: 7})
    T.press(e, 'HOLD')
    T.press(e, 'HOLD')
    c = countdown(e)
    T.check('P4: 0x02B = 7 reads as 30 min', 1797 <= c <= 1800, 'countdown %d' % c)
    T.check('P4: the byte is left as found', e.m.eeprom[EE_TIME] == 7)
    s = e.snapshot()
    T.check('P4: no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'],
            'unmodelled %r safety %r' % (s['unmodelled'], s['safety']))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
