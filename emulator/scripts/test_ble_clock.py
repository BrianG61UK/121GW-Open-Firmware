"""Induced emulator test of the set-clock frame over Bluetooth (production image, IMP-31, FEATURES.md 2.11 stage 5).

    python -I emulator/scripts/test_ble_clock.py [image]      default firmware/build/EEVBlog.bin

Bluetooth on (long PEAK).  The frame F8 + seven ASCII hex pairs v0..v6 (year 0..99, month, day, hour, minute, second as
plain numbers, v6 = XOR of v0..v5; analysis/ble_packet.md 6) is echoed and written to the clock chip (rtc_write_reg
converts each value to BCD).  IMP-31: a second frame in the same Bluetooth session is applied too (v2.05 applied only
the first one until Bluetooth was switched off and on).  A frame with a wrong checksum is neither echoed nor applied.
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
from test_ble_version import frames_after  # noqa: E402

ADDR_BLE_ON = 0x2000802B


def clock_frame(y, mo, d, h, mi, s, bad=False):
    v = [y, mo, d, h, mi, s]
    x = 0
    for b in v:
        x ^= b
    v.append(x ^ (1 if bad else 0))
    return b'\xF8' + ''.join('%02X' % b for b in v).encode('ascii')


def bcd(v):
    return (v // 10) << 4 | (v % 10)


def chip(e):
    c = e.nju.calendar()
    return c['year'], c['month'], c['date'], c['hour'], c['minute']


def send(e, frame):
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(frame)
    e.advance(1.0)
    return frames_after(e, n0)


def run_tests(image):
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    T.check('Bluetooth on', T.rd(e, ADDR_BLE_ON) == 1)

    print('T1 first set-clock frame of the session')
    f1 = clock_frame(31, 12, 24, 18, 45, 10)
    got = send(e, f1)
    T.check('echoed', got == f1, 'got %r' % got)
    want = tuple(bcd(v) for v in (31, 12, 24, 18, 45))
    T.check('clock chip set to 2031-12-24 18:45 (BCD registers)', chip(e) == want, 'chip %r' % (chip(e),))

    print('T2 second frame in the same Bluetooth session (IMP-31)')
    f2 = clock_frame(26, 11, 4, 9, 30, 0)
    got = send(e, f2)
    T.check('echoed', got == f2, 'got %r' % got)
    want = tuple(bcd(v) for v in (26, 11, 4, 9, 30))
    T.check('clock chip set to 2026-11-04 09:30', chip(e) == want, 'chip %r' % (chip(e),))

    print('T3 wrong checksum')
    got = send(e, clock_frame(20, 1, 1, 0, 0, 0, bad=True))
    T.check('not echoed', got == b'', 'got %r' % got)
    T.check('clock unchanged', chip(e) == want, 'chip %r' % (chip(e),))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
