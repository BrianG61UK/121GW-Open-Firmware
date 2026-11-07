"""Induced emulator test of the bargraph fixes OF-74, OF-75 and OF-76 (firmware lcd/bargraph.s bargraph_count_from_value,
fn_0801912C; GitHub issues 19 and 17).

    python -I emulator/scripts/test_bargraph.py [image]                default firmware/build/EEVBlog.bin

The bar has 25 segments plus segment 0, count = |per-sample value| / 2000; the label at its right end is "5" (index 0),
"50" (index 1) or "500" (index 2) and follows the digits of the main display (full bar = 50000 counts).
  G1 DIODE 15 V, open leads: a steady 8 segments (count 7, no full-bar flash once per reading, OF-74), label "50" (OF-75);
     the emulator's lcd_seen (every state the LCD showed since the previous snapshot) shows no extra segment either
  G2 DIODE 3 V, open leads: 15 segments, label "5" (unchanged)
  G3 GitHub issue 17: with the mA jack, MODE to DCuVA at the uA position, then the dial to A/mA, back to uA and to mVA/VA:
     each VA mode shows its own label, not the one the mode before left (OF-76)
  G4 every range 0..3 of DCVA (RANGE key): labels as measured in the emulator for these ranges (0x20007D68 in display
     counts): range 0, 1 no label (full bar 5000 / 50000 of the unit shown), range 2 "50", range 3 "500"
RUN LIMIT: 1 run of this script (4 boots).
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_backlight_timer as T  # noqa: E402

ADDR_MODE, ADDR_RANGE = 0x2000803C, 0x2000803D
ADDR_COUNT, ADDR_SCALE, ADDR_15V = 0x20008041, 0x2000804D, 0x200080B3
LCD_SHADOW = 0x20007790
EE_DIAL5_MODE = 0x0B                                 # the mode remembered for the DIODE / BEEP dial position
# label index per range 0..3 of the VA modes (None: no label fits); AC 13..15 and DC 22..24 alike
VA_INDEX = {13: (2, None, None, None), 14: (1, 2, 2, None), 15: (None, None, 1, 2)}
VA_INDEX.update({m + 9: v for m, v in VA_INDEX.items()})


def labels(e):
    """("5", "0" of 50, "0" of 500) as set in the LCD shadow (w4 0x80, w6 0x80, w2 0x800)."""
    w = [T.rd(e, LCD_SHADOW + 4 * i, 4) for i in range(8)]
    return (int(bool(w[4] & 0x80)), int(bool(w[6] & 0x80)), int(bool(w[2] & 0x800)))


def want(index):
    return {None: (0, 0, 0), 0: (1, 0, 0), 1: (1, 1, 0), 2: (1, 1, 1)}[index]


def check_va(e, tag):
    m, r = T.rd(e, ADDR_MODE), T.rd(e, ADDR_RANGE)
    idx = VA_INDEX[m][r]
    T.check('%s: mode %d range %d label %s' % (tag, m, r, {None: 'none', 0: '5', 1: '50', 2: '500'}[idx]),
            labels(e) == want(idx) and T.rd(e, ADDR_SCALE) == (idx or 0),
            'labels %r scale %d' % (labels(e), T.rd(e, ADDR_SCALE)))


def diode(image, v15):
    e = T.make(image, {EE_DIAL5_MODE: 11})
    e.command({'dial': 5})
    e.advance(3.0)
    if v15:
        T.press(e, 'RANGE')
    e.advance(1.0)
    T.check('DIODE %s V selected' % ('15' if v15 else '3'), T.rd(e, ADDR_MODE) == 11 and T.rd(e, ADDR_15V) == int(v15))
    counts = set()
    for _ in range(300):
        e.advance(0.01)
        counts.add(T.rd(e, ADDR_COUNT))
    return e, counts


def pc(words):
    return sum(bin(w).count('1') for w in words)


def run_tests(image):
    print('G1 DIODE 15 V, open leads')
    e, counts = diode(image, True)
    T.check('G1: a steady 8 segments (count 7) in 300 samples at 10 ms', counts == {7}, repr(sorted(counts)))
    T.check('G1: label "50"', labels(e) == want(1) and T.rd(e, ADDR_SCALE) == 1, repr(labels(e)))
    e.snapshot()
    extra = 0
    for _ in range(20):
        e.advance(0.1)
        s = e.snapshot()
        extra += pc(s['lcd_seen']) != pc(s['lcd'])
    T.check('G1: no segment lit only between two snapshots (lcd_seen)', extra == 0, '%d of 20' % extra)

    print('G2 DIODE 3 V, open leads')
    e, counts = diode(image, False)
    T.check('G2: 15 segments (count 15)', counts == {15}, repr(sorted(counts)))
    T.check('G2: label "5"', labels(e) == want(0) and T.rd(e, ADDR_SCALE) == 0, repr(labels(e)))

    print('G3 issue 17: uA position to DCuVA (MODE), then A/mA, back, and mVA/VA')
    e = T.make(image)
    e.command({'jack': 'mA', 'plugged': True})
    e.command({'dial': 7})
    e.advance(2.0)
    for _ in range(4):
        if T.rd(e, ADDR_MODE) == 22:
            break
        T.press(e, 'MODE')
        e.advance(1.5)
    T.check('G3: DCuVA reached with MODE at the uA position', T.rd(e, ADDR_MODE) == 22, 'mode %d' % T.rd(e, ADDR_MODE))
    check_va(e, 'G3 uA position')
    va = 0
    for dial in (8, 7, 6):
        e.command({'dial': dial})
        e.advance(2.0)
        m = T.rd(e, ADDR_MODE)
        print('  dial %d: mode %d range %d labels %r' % (dial, m, T.rd(e, ADDR_RANGE), labels(e)))
        if m in VA_INDEX:
            va += 1
            check_va(e, 'G3 dial %d' % dial)
    T.check('G3: VA modes after the A/mA position', va >= 1, '%d' % va)

    print('G4 DCVA ranges 0..3')
    e = T.make(image)
    e.command({'dial': 6})
    e.advance(3.0)
    T.check('G4: DCVA at the mVA/VA position', T.rd(e, ADDR_MODE) == 24, 'mode %d' % T.rd(e, ADDR_MODE))
    seen = set()
    for _ in range(6):
        T.press(e, 'RANGE')
        e.advance(1.5)
        r = T.rd(e, ADDR_RANGE)
        if r not in seen:
            seen.add(r)
            check_va(e, 'G4')
    T.check('G4: all four ranges visited', seen == {0, 1, 2, 3}, repr(sorted(seen)))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'],
            'unmodelled %r safety %r' % (s['unmodelled'], s['safety']))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
