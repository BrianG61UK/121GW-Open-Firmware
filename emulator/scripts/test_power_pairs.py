"""Induced emulator test of the service paths at power-on (firmware IMP-58, cal/bootwin.s pw_check; GitHub issue 32).

    python -I emulator/scripts/test_power_pairs.py [image]              default firmware/build/EEVBlog.bin

In v2.05 one key pressed in the 2 s after a start started a service path (MODE: " CAL1", SETUP: date-code editing,
MEM: the cal.bin menu, RANGE: all segments), so a MODE pressed by chance after a start showed CAL1.  Since IMP-58 each
path needs two keys held together while the dial switches the meter on, 0.5 s long:
  P1 MODE + REL held: calibration mode (0x2000808A = 1)
  P2 MODE + SETUP held: date-code editing (0x2000808B = 1)
  P3 MEM + PEAK held: the cal.bin menu (state B 0x200080CE = 1, "SdCAL" on the display)
  P4 RANGE + MIN/MAX held: all segments (ui_lamp_test = 1)
  S1 MODE, SETUP, MEM, RANGE each held alone at power-on: no path, the mode unchanged (no short or long press)
  S2 MODE pressed 0.5 s after the start (not held before): no CAL1, no calibration mode, the mode unchanged
  S3 MODE + REL held, REL let go after 0.3 s, MODE held on to 1.5 s: no path, the mode unchanged
  S4 MODE + REL pressed together 0.6 s after the start (a pair formed late): no calibration mode
  S5 auto power-off, wake with the dial, then MODE + REL held 1 s: no calibration mode (no service path after a wake)
  S6 MEM + HOLD held at power-on (the bootloader's update keys; this image runs without the bootloader): no path
  S7 HOLD pressed on the first key tick after the 20-tick settle time: a normal press (auto-hold on), the check is over
     (critique 2026-11-08: the press was swallowed when it came on tick 21)
RUN LIMIT: 1 run of this script (14 boots).  The helpers are those of test_backlight_timer.py.
"""
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_CAL_MODE = 0x2000808A
ADDR_DATE_EDIT = 0x2000808B
ADDR_WIN_A = 0x200080CD
ADDR_WIN_B = 0x200080CE
ADDR_MODE = 0x2000803C                                # meter_mode
ADDR_APO = 0x20000230
ADDR_LOGGING = 0x20007FE1                             # key_logging
ADDR_HOLD = 0x2000804F                                # hold_active


def hold_at_power_on(image, keys, hold=1.0):
    """Keys down, the dial from OFF to DCV, `hold` s, keys up; returns the emulator 0.2 s later."""
    e = T.make(image)
    for k in keys:
        e.command({'key': k, 'down': True})
    e.command({'dial': 2})
    e.advance(hold)
    texts = list(T.DEC.text(e.snapshot()['lcd'])[:2])          # main and sub display
    for k in keys:
        e.command({'key': k, 'down': False})
    e.advance(0.2)
    return e, texts


def state(e):
    return {'cal': T.rd(e, ADDR_CAL_MODE), 'date': T.rd(e, ADDR_DATE_EDIT), 'a': T.rd(e, ADDR_WIN_A),
            'b': T.rd(e, ADDR_WIN_B), 'mode': T.rd(e, ADDR_MODE)}


def nothing(name, e, mode0, texts=None):
    s = state(e)
    T.check(name + ': no service path', s['cal'] == 0 and s['date'] == 0 and s['a'] == 0 and s['b'] == 0, repr(s))
    T.check(name + ': the mode unchanged', s['mode'] == mode0, 'mode %d, at the start %d' % (s['mode'], mode0))
    if texts is not None:
        T.check(name + ': no CAL1 on the display', 'CAL' not in ' '.join(texts).upper(), repr(texts))


def run_tests(image):
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    lamp = T.symbol(mp, 'ui_lamp_test')

    e0, _ = hold_at_power_on(image, [], hold=2.5)
    mode0 = T.rd(e0, ADDR_MODE)
    print('DCV start mode %d' % mode0)

    print('P1 MODE + REL')
    e, _ = hold_at_power_on(image, ['MODE', 'REL'])
    T.check('P1: calibration mode', T.rd(e, ADDR_CAL_MODE) == 1, repr(state(e)))
    print('P2 MODE + SETUP')
    e, _ = hold_at_power_on(image, ['MODE', 'SETUP'])
    T.check('P2: date-code editing', T.rd(e, ADDR_DATE_EDIT) == 1, repr(state(e)))
    T.check('P2: not calibration mode', T.rd(e, ADDR_CAL_MODE) == 0)
    print('P3 MEM + PEAK')
    e, texts = hold_at_power_on(image, ['MEM', 'PEAK'])
    T.check('P3: the cal.bin menu (B = 1)', T.rd(e, ADDR_WIN_B) == 1, repr(state(e)))
    T.check('P3: SdCAL shown', any('CAL' in t.upper() for t in texts), repr(texts))
    print('P4 RANGE + MIN/MAX')
    e, _ = hold_at_power_on(image, ['RANGE', 'MINMAX'])
    T.check('P4: all segments (ui_lamp_test)', T.rd(e, lamp) == 1, 'ui_lamp_test %d' % T.rd(e, lamp))

    for k in ('MODE', 'SETUP', 'MEM', 'RANGE'):
        print('S1 %s alone' % k)
        e, texts = hold_at_power_on(image, [k])
        e.advance(2.5)
        nothing('S1 %s' % k, e, mode0, texts)

    print('S2 MODE 0.5 s after the start')
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(0.5)
    T.press(e, 'MODE', gap=0.1)
    texts = [T.DEC.text(e.snapshot()['lcd'])[0]]
    texts += T.sample_texts(e, n=3)
    e.advance(2.0)
    nothing('S2', e, mode0, texts)

    print('S3 pair, REL let go first')
    e = T.make(image)
    e.command({'key': 'MODE', 'down': True})
    e.command({'key': 'REL', 'down': True})
    e.command({'dial': 2})
    e.advance(0.3)
    e.command({'key': 'REL', 'down': False})
    e.advance(1.2)
    e.command({'key': 'MODE', 'down': False})
    e.advance(2.0)
    nothing('S3', e, mode0)

    print('S4 pair formed 0.6 s after the start')
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(0.6)
    e.command({'key': 'MODE', 'down': True})
    e.command({'key': 'REL', 'down': True})
    e.advance(1.0)
    e.command({'key': 'MODE', 'down': False})
    e.command({'key': 'REL', 'down': False})
    e.advance(2.0)
    T.check('S4: no calibration mode', T.rd(e, ADDR_CAL_MODE) == 0, repr(state(e)))

    print('S5 wake from auto power-off')
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    e.m.uc.mem_write(ADDR_APO, struct.pack('<H', 3))
    e.advance(9.0)
    T.check('S5: in STOP after the auto power-off', e.m.rcc.msirange == 0, 'MSIRANGE %d' % e.m.rcc.msirange)
    e.command({'key': 'MODE', 'down': True})
    e.command({'key': 'REL', 'down': True})
    e.command({'dial': 3})
    e.advance(1.0)
    e.command({'key': 'MODE', 'down': False})
    e.command({'key': 'REL', 'down': False})
    e.advance(2.0)
    T.check('S5: awake', e.m.rcc.msirange == 6, 'MSIRANGE %d' % e.m.rcc.msirange)
    T.check('S5: no calibration mode after a wake', T.rd(e, ADDR_CAL_MODE) == 0, repr(state(e)))

    print('S6 MEM + HOLD')
    e, _ = hold_at_power_on(image, ['MEM', 'HOLD'])
    e.advance(2.5)
    nothing('S6', e, mode0)
    T.check('S6: logging not started by the held pair', T.rd(e, ADDR_LOGGING) == 0, "key_logging %d" % T.rd(e, ADDR_LOGGING))

    print('S7 HOLD right after the settle time')
    active = T.symbol(mp, 'bootwin_active')           # bootwin.s .bss_port.cal: active, cb, pw_done, pw_ticks
    e = T.make(image)
    e.command({'dial': 2})
    t0 = T.now(e)
    while T.rd(e, active + 3) < 20 and T.now(e) - t0 < 2.0:
        e.advance(0.001)
    ticks = T.rd(e, active + 3)
    e.command({'key': 'HOLD', 'down': True})
    e.advance(0.15)
    e.command({'key': 'HOLD', 'down': False})
    e.advance(0.4)
    T.check('S7: HOLD pressed at pw_ticks %d works (auto-hold on)' % ticks, T.rd(e, ADDR_HOLD) == 1,
            'hold_active %d' % T.rd(e, ADDR_HOLD))
    T.check('S7: the check is over', T.rd(e, active + 2) == 1, 'pw_done %d' % T.rd(e, active + 2))

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
