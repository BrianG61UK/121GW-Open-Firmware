"""Induced emulator test of the continuity beep hold time (production image, FEATURES.md 2.13, DESIGN.md 10 IMP-16).

    python -I emulator/scripts/test_beep_hold.py [image]      default firmware/build/EEVBlog.bin (production build)

BEEP (dial Ohm/beep, EEPROM 0x0B = 10) with 10 ohm contacts: for each code of the page bH (EEPROM 0x021) the time from
opening the contact until the buzzer (PE7) stops, sampled every 0.25 ms over 10 openings at different phases, and the
number of buzzer switchings during a steady 1 s contact (0 = no chopping).  Checks the page (only in BEEP, between dSP
and Lt), its texts, that only EEPROM byte 0x021 is written and only by the save, the fallback of invalid bytes and the
contact-to-tone time (unchanged).  The helpers are those of test_backlight_timer.py.
"""
import os
import statistics
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_MODE = 0x2000803C
EXPECT_MS = {0: 100, 1: 50, 2: 25, 3: 15}            # TIM3 ticks of 0.996 ms


def meter(image, code):
    e = T.make(image, {0x0B: 10, 0x21: code})
    e.command({'dial': 5})
    e.advance(3.0)
    return e


def buzz(e):
    return e.snapshot()['buzzer']


def run_slices(e, seconds, step_s=0.00025):
    n = int(e.m.sysclk_hz * step_s)
    out = []
    for _ in range(int(round(seconds / step_s))):
        e.m.run(n)
        out.append(buzz(e))
    return out


def measure(image, code):
    e = meter(image, code)
    T.check('code %d: BEEP mode' % code, T.rd(e, ADDR_MODE) == 10, 'mode=%d' % T.rd(e, ADDR_MODE))
    offs, ons, chops = [], [], []
    for k in range(10):
        e.command({'input': {'kind': 'open'}})
        run_slices(e, 0.25 + 0.0013 * k)
        e.command({'input': {'kind': 'ohm', 'value': 10.0}})
        s = run_slices(e, 0.06)
        ons.append(s.index(1) * 0.25 if 1 in s else None)
        s = run_slices(e, 1.0)                       # steady contact
        chops.append(sum(1 for a, b in zip(s, s[1:]) if a != b))
        e.command({'input': {'kind': 'open'}})
        s = run_slices(e, 0.2)
        offs.append(s.index(0) * 0.25 if 0 in s else None)
    return offs, ons, chops


def run_tests(image, a_code):
    print('T1 hold time per code')
    for code, ms in EXPECT_MS.items():
        offs, ons, chops = measure(image, code)
        ok = all(o is not None for o in offs)
        print('    code %d: off after %.2f..%.2f ms (median %.2f), on after median %.2f ms, switchings in 1 s contact %s'
              % (code, min(offs), max(offs), statistics.median(offs), statistics.median(ons), max(chops)))
        # the last re-arm comes 0 .. 10 ms before the contact opens (re-arm gaps 3.1 .. 10.0 ms): tone end in hold - 10.5 .. hold + 2
        T.check('code %d: tone ends %d ms after the last re-arm (within %d - 10.5 .. %d + 2 ms of the opening)' % (code, ms, ms, ms),
                ok and ms - 10.5 <= min(offs) and max(offs) <= ms + 2.0, 'offs=%r' % (offs,))
        T.check('code %d: steady tone during the contact (no switching)' % code, max(chops) == 0, 'chops=%r' % (chops,))
        # first contact to tone.  The HY3131 delivers a BEEP result every 3.91 ms (owner's meter 2026-11-10, Q3; the
        # emulator follows since emu/hy3131.py AD1_CHOP_SETTLE_S; the earlier 1.5625 ms model gave a median of 2.00 ms).
        # A contact lands anywhere in a conversion: the first result that holds it comes after up to two periods, then
        # the service reads it (at most 0.69 ms after the event, meter Q2): bound 2 x 3.91 + 0.69 = 8.5 ms each; the
        # 10 phases here gave 0.75..5.5 ms, median 4.0..4.25 ms (2026-11-10), bound on the median 5.0 ms.
        T.check('code %d: tone after the contact: median <= 5.0 ms, each <= 8.5 ms' % code,
                all(o is not None for o in ons) and statistics.median(ons) <= 5.0 and max(ons) <= 8.5, 'ons=%r' % (ons,))

    print('T2 the page bH')
    e = meter(image, 0)
    for _ in range(18):
        if T.rd(e, ADDR_ITEM) == 24:
            break
        T.press(e, 'SETUP', gap=0.5)
    T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('BEEP: SETUP short on dSP shows bH: "bH100"', T.rd(e, ADDR_ITEM) == 26 and 'BH100' in texts, 'samples=%r' % (texts,))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    for code, text in ((1, 'BH 50'), (2, 'BH 25'), (3, 'BH0FF')):
        T.press(e, 'REL', gap=0.5)
        e.advance(0.6)
        texts = T.sample_texts(e)
        T.check('REL: code %d, "%s"' % (code, text), T.rd(e, a_code) == code and text in texts, 'samples=%r' % (texts,))
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save wrote only 0x021 = 3', diff == {0x21: (0, 3)}, 'diff=%r' % (diff,))
    T.press(e, 'SETUP', gap=0.5)
    T.check('SETUP short on bH goes to Lt (item 27)', T.rd(e, ADDR_ITEM) == 27)

    print('T3 outside BEEP, stored values')
    e = T.make(image, {0x21: 0})
    e.command({'dial': 2})
    e.advance(3.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([24]))
    T.press(e, 'SETUP', gap=0.5)
    T.check('DCV: SETUP short on dSP goes to Lt (item 27, no bH)', T.rd(e, ADDR_ITEM) == 27)
    for value, want in ((0xFF, 0), (4, 0), (2, 2)):
        e = meter(image, value)
        T.check('0x021 = 0x%02X reads as %d' % (value, want), T.rd(e, a_code) == want and e.m.eeprom[0x21] == value)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'set_bh_code'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
