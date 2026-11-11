"""Induced emulator test of the two SETUP walks (firmware IMP-52: set/setup.s fn_08015410, set/menu.s, key/long.s; GitHub
issue 24).

    python -I emulator/scripts/test_setup_walks.py [image]                default firmware/build/EEVBlog.bin

SETUP short walks the measurement pages and ends on the page SEt (item 43); a long SETUP on SEt opens the meter pages.
Each check presses SETUP short and records the item after every press (set_item, RAM 0x20008037), starting on item 0.
  W1 DCV: 0 -> rEL 22 -> dSP 24 -> Lt 27 -> Lo 28 -> HI 29 -> tr 30 -> In 9 -> SEt 43 -> 0; the page In loads its edit
     buffer (set_interval_edit = set_log_interval, as v2.05 on entering item 9); SEt shows "SEt" on the sub display
  W2 the meter walk: long SETUP on SEt -> 1 -> bAt 47 (IMP-67) -> 2 .. 8 -> bL 20 -> bt 21 -> Ld 39 -> CL 25 -> bAcK 44
     (F-1.26, IMP-57) -> 0 (no two-part
     bootloader in the emulator: no Fr); no edit is started by the long SETUP on SEt
  W3 ACV (function pages 10, 11): from item 0: 10 -> 11 -> rEL ... ; DIODE: 0 -> 10 -> 22 -> 24 -> CHIrP 42 -> 27
  W4 tr-Ch and MIN/MAX on: tr 30 -> Ch 31 -> In 9 -> n 32 -> Sd 33 -> tHI 34 -> tLo 35 -> SEt 43
RUN LIMIT: 1 run of this script (4 boots).
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM, ADDR_EDIT = 0x20008037, 0x2000806E
ADDR_LOG_INTERVAL, ADDR_INTERVAL_EDIT = 0x2000022C, 0x20007FA6
ADDR_MINMAX = 0x2000804E
EE_DIAL5_MODE = 0x0B


def walk(e, n):
    out = []
    for _ in range(n):
        T.press(e, 'SETUP', gap=0.5)
        out.append(T.rd(e, ADDR_ITEM))
    return out


def start(image, dial, patch=None):
    e = T.make(image, patch)
    e.command({'dial': dial})
    e.advance(3.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    return e


def run_tests(image):
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')

    print('W1 DCV measurement walk')
    e = start(image, 2)
    e.m.uc.mem_write(ADDR_LOG_INTERVAL, (7).to_bytes(2, 'little'))
    seq = walk(e, 9)
    T.check('W1: 0 -> rEL dSP Lt Lo HI tr In SEt -> 0', seq == [22, 24, 27, 28, 29, 30, 9, 43, 0], repr(seq))
    e.m.uc.mem_write(ADDR_ITEM, bytes([30]))
    T.press(e, 'SETUP', gap=0.5)
    T.check('W1: In loads its edit buffer from the log interval', T.rd(e, ADDR_ITEM) == 9
            and T.rd(e, ADDR_INTERVAL_EDIT, 2) == 7, 'item %d edit %d' % (T.rd(e, ADDR_ITEM), T.rd(e, ADDR_INTERVAL_EDIT, 2)))
    T.press(e, 'SETUP', gap=0.5)
    T.check('W1: SEt shows "SEt"', T.rd(e, ADDR_ITEM) == 43 and T.sub_text(e).strip().upper() == '5ET',          # the decoder reads S as 5
            'item %d sub %r' % (T.rd(e, ADDR_ITEM), T.sub_text(e)))

    print('W2 the meter walk')
    T.long_press(e, 'SETUP')
    T.check('W2: long SETUP on SEt opens item 1, no edit', T.rd(e, ADDR_ITEM) == 1 and T.rd(e, ADDR_EDIT) == 0,
            'item %d edit %d' % (T.rd(e, ADDR_ITEM), T.rd(e, ADDR_EDIT)))
    seq = walk(e, 14)
    T.check('W2: bAt 47, 2 .. 8 -> bL bt Ld CL bAcK -> 0', seq == [47, 2, 3, 4, 5, 6, 7, 8, 20, 21, 39, 25, 44, 0], repr(seq))

    print('W3 ACV and DIODE')
    e = start(image, 2)                                  # V position: DCV, MODE to ACV
    T.press(e, 'MODE', gap=1.0)
    mode = T.rd(e, 0x2000803C)
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    seq = walk(e, 4)
    T.check('W3: ACV (mode %d): 0 -> 10 -> 11 -> rEL -> dSP' % mode, mode == 2 and seq == [10, 11, 22, 24], repr(seq))
    e = start(image, 5, {EE_DIAL5_MODE: 11})
    seq = walk(e, 5)
    T.check('W3: DIODE: 0 -> 10 -> rEL -> dSP -> CHIrP -> Lt', seq == [10, 22, 24, 42, 27], repr(seq))

    print('W4 tr-Ch and MIN/MAX on')
    e = start(image, 2)
    e.m.uc.mem_write(T.symbol(mp, 'log_trig'), bytes([1]))
    T.press(e, 'MINMAX', gap=1.0)
    T.check('W4: MIN/MAX on', T.rd(e, ADDR_MINMAX) != 0, 'minmax_state %d' % T.rd(e, ADDR_MINMAX))
    e.m.uc.mem_write(ADDR_ITEM, bytes([29]))
    seq = walk(e, 8)
    T.check('W4: HI -> tr Ch In n Sd tHI tLo SEt', seq == [30, 31, 9, 32, 33, 34, 35, 43], repr(seq))
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
