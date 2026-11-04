"""Induced emulator test of the MIN/MAX statistics (production image, FEATURES.md 2.7, DESIGN.md 10 IMP-14).

    python -I emulator/scripts/test_statistics.py [image]      default firmware/build/EEVBlog.bin (production build)

DCV with the input switched between 1.0 V and 1.1 V while MIN/MAX is on.  Every reading that enters the statistics is
recorded from the meter (func_stats_n polled every 10 ms; DCV publishes a value every 100 ms in the production image, IMP-23), and the count, mean and
sample standard deviation computed here with Python's statistics module from that list must equal the meter's binary64
mean, m2 and the shown standard deviation.  Checks: page n shown when MIN/MAX is switched on, its text (count, and the
thousands form with the k sign), page Sd on the sub display and the standard deviation on the main digits (one more
decimal than the reading, rounded to nearest), "-----" with fewer than two readings, the navigation tr -> n -> Sd -> tHI
while MIN/MAX is on (tr, the logging trigger page with tr-In, is the last page before the statistics) and tr -> item 0
while it is off, the return to item 0 when MIN/MAX ends, HOLD freezing the
statistics, and no change of the BLE value (0x20007D70 keeps the MIN/MAX value).
The helpers are those of test_backlight_timer.py.
"""
import math
import os
import statistics
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_MM_STATE = 0x2000804E
ADDR_MM_LAST = 0x20007D9C                            # last recorded MIN/MAX reading
ADDR_D = 0x20007D64
ADDR_BLE_VALUE = 0x20007D70
ADDR_REDRAW = 0x20008062


def u32(e, a):
    return struct.unpack('<I', e.m.uc.mem_read(a, 4))[0]


def s32(e, a):
    return struct.unpack('<i', e.m.uc.mem_read(a, 4))[0]


def f64(e, a):
    return struct.unpack('<d', e.m.uc.mem_read(a, 8))[0]


def main_text(e):
    return T.DEC.text(e.snapshot()['lcd'])[0]


def subk(e):
    return e.snapshot()['lcd'][4] >> 17 & 1


def volts(e, v):
    e.command({'input': {'kind': 'V', 'value': v, 'ac': False}})


def run_tests(image, sym):
    a_n, a_mean, a_m2 = sym['func_stats_n'], sym['func_stats_mean'], sym['func_stats_m2']
    e = T.make(image)
    e.command({'dial': 2})
    volts(e, 1.0)
    e.advance(4.0)

    print('T1 MIN/MAX on shows page n')
    rec, n_prev = [], 0                              # every reading from the switch-on is recorded (polled every 10 ms)

    def poll(seconds):
        nonlocal n_prev
        for _ in range(int(round(seconds / 0.01))):
            e.advance(0.01)
            n = u32(e, a_n)
            if n != n_prev:
                if n != n_prev + 1:
                    T.check('one reading per poll', False, 'n %d -> %d' % (n_prev, n))
                e.advance(0.001)                     # the poll may stop between func_stats_add and the store of the
                rec.append(s32(e, ADDR_MM_LAST))     # last reading (func/minmax.s): let the record path finish first
                n_prev = n

    e.command({'key': 'MINMAX', 'down': True})
    poll(0.15)
    e.command({'key': 'MINMAX', 'down': False})
    poll(0.35)
    T.check('MIN/MAX on, item 32', T.rd(e, ADDR_MM_STATE) != 0 and T.rd(e, ADDR_ITEM) == 32, 'item=%d' % T.rd(e, ADDR_ITEM))
    e.command({'key': 'SETUP', 'down': True})
    poll(0.15)
    e.command({'key': 'SETUP', 'down': False})
    poll(0.35)
    T.check('SETUP short on n shows Sd', T.rd(e, ADDR_ITEM) == 33)

    print('T2 statistics against an independent computation')
    for k in range(40):
        volts(e, 1.1 if k % 3 == 1 else 1.0)
        poll(0.6)                                    # 0.6 s per level
    n = u32(e, a_n)
    mean, m2 = f64(e, a_mean), f64(e, a_m2)
    sd_meter = math.sqrt(m2 / (n - 1))
    sd_py = statistics.stdev(rec)
    T.check('count = readings recorded (%d)' % len(rec), n == len(rec), 'n=%d' % n)
    T.check('mean = Python mean (%.6f)' % statistics.fmean(rec), abs(mean - statistics.fmean(rec)) < 1e-9 * max(1, abs(mean)))
    T.check('sd = Python stdev (%.6f counts)' % sd_py, abs(sd_meter - sd_py) < 1e-9 * max(1, sd_py), 'meter %.9f' % sd_meter)
    txt = main_text(e)
    dp = T.rd(e, 0x2000803F)                         # decimal point code of the reading
    q10 = math.floor(sd_py * 10 + 0.5)
    if dp < 4 and q10 <= 99999:
        q, dec = q10, dp + 1                         # one more decimal
    else:
        q, dec = math.floor(sd_py + 0.5), dp
    digits = str(q).rjust(dec + 1, '0')
    expect = (digits[:-dec] + '.' + digits[-dec:]) if dec else digits
    T.check('page Sd: main %r = %s (sd %.3f counts, reading dp %d)' % (txt, expect, sd_py, dp), txt.replace(' ', '') == expect)
    T.check('BLE value = MIN/MAX value in counts, not the standard deviation', s32(e, ADDR_BLE_VALUE) == s32(e, ADDR_D),
            'ble=%d d=%d' % (s32(e, ADDR_BLE_VALUE), s32(e, ADDR_D)))

    print('T3 page n text')
    T.press(e, 'SETUP', gap=0.3)                     # Sd -> the time page tHI (IMP-21, test_minmax_time.py)
    T.check('SETUP short on Sd goes to tHI (item 34)', T.rd(e, ADDR_ITEM) == 34, 'item=%d' % T.rd(e, ADDR_ITEM))
    e.m.uc.mem_write(ADDR_ITEM, bytes([32]))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    e.advance(0.2)
    sub, n_now = T.sub_text(e), u32(e, a_n)
    # a reading may have entered after the last redraw: the page is redrawn in the refresh pass that follows the new
    # result (ui_stats_tick), so the count shown is n or, until that pass, n - 1
    T.check('page n: "n" and the count %d right-aligned, no k' % n_now,
            sub in ('n%4d' % n_now, 'n%4d' % (n_now - 1)) and subk(e) == 0, 'sub=%r' % sub)
    e.m.uc.mem_write(a_n, struct.pack('<I', 123456))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    e.advance(0.2)
    sub = T.sub_text(e)
    T.check('count 123456: "n 123" with the k sign', sub == 'n 123' and subk(e) == 1, 'sub=%r k=%d' % (sub, subk(e)))
    e.m.uc.mem_write(a_n, struct.pack('<I', 0))       # statistics emptied as the switch-on does (count, mean, m2)
    e.m.uc.mem_write(a_mean, bytes(8))
    e.m.uc.mem_write(a_m2, bytes(8))
    e.m.uc.mem_write(ADDR_ITEM, bytes([33]))
    for _ in range(50):                              # until the first reading has entered (and been drawn)
        e.advance(0.01)
        if u32(e, a_n) == 1:
            break
    e.advance(0.01)
    T.check('one reading: page Sd shows "-----", no minus, no decimal point', u32(e, a_n) == 1
            and main_text(e).strip() == '-----' and (e.snapshot()['lcd'][3] >> 7 & 1) == 0,
            'n=%d main=%r' % (u32(e, a_n), main_text(e)))
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))

    print('T4 HOLD freezes, navigation, MIN/MAX off')
    T.press(e, 'HOLD', gap=0.3)
    n0 = u32(e, a_n)
    volts(e, 1.1)
    e.advance(2.0)
    T.check('HOLD: no reading added', u32(e, a_n) == n0, 'n %d -> %d' % (n0, u32(e, a_n)))
    T.press(e, 'HOLD', gap=0.3)                      # with MIN/MAX on the second HOLD press switches HOLD off
    T.check('HOLD off again', T.rd(e, 0x2000804F) == 0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([30]))         # the logging trigger page tr (IMP-21, tr-In) before the statistics
    T.press(e, 'SETUP', gap=0.3)
    T.check('MIN/MAX on: SETUP short on tr shows n', T.rd(e, ADDR_ITEM) == 32, 'item=%d' % T.rd(e, ADDR_ITEM))
    T.long_press(e, 'MINMAX')
    e.advance(0.5)
    T.check('MIN/MAX off: page n left for item 0', T.rd(e, ADDR_MM_STATE) == 0 and T.rd(e, ADDR_ITEM) == 0,
            'state=%d item=%d' % (T.rd(e, ADDR_MM_STATE), T.rd(e, ADDR_ITEM)))
    e.m.uc.mem_write(ADDR_ITEM, bytes([30]))
    T.press(e, 'SETUP', gap=0.3)
    T.check('MIN/MAX off: SETUP short on tr goes to item 0', T.rd(e, ADDR_ITEM) == 0)
    T.press(e, 'MINMAX', gap=0.3)
    T.check('MIN/MAX on again: statistics restarted', T.rd(e, ADDR_MM_STATE) == 1 and u32(e, a_n) <= 5,
            'n=%d' % u32(e, a_n))                    # 0.45 s at up to 10 readings per second (DCV, IMP-23)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    sym = {k: T.symbol(mp, k) for k in ('func_stats_n', 'func_stats_mean', 'func_stats_m2')}
    run_tests(image, sym)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
