"""Induced emulator test of the link watch (firmware IMP-56, ble/heartbeat.s; GitHub issue 23) and the page bAcK
(IMP-57, set/setup.s, set/menu.s; GitHub issue 31).

    python -I emulator/scripts/test_heartbeat.py [image]                default firmware/build/EEVBlog.bin

The companion writes the single byte 0xFE every 5 s ("still here") and 0xFD before a clean disconnect.  The meter, once
it has seen 0xFE, switches its Bluetooth module off when nothing has come from the computer for 15 s, and on again 5 s
later, so a computer that kept a connection the companion gave up must let it go.  The module's state is read from the
firmware's own flag ble_usart_on (1 between usart2_init and usart2_deinit), sampled every 0.25 s.
  H1 without 0xFE (another Bluetooth app, an older companion): 40 s of silence, the module stays on
  H2 0xFE, then silence: the module goes off 15 s after the last byte (14.5 .. 16 s), on again 5 s later (4.5 .. 5.5 s),
     status frames flow again, the watch is off afterwards (40 s more silence: no second reset)
  H3 0xFE every 5 s for 40 s: the module stays on
  H4 0xFE, then 0xFD, then 40 s of silence: the module stays on
  H5 0xFE, then page Ld shown (60 s idle there): the module stays on; on leaving the page the watch counts from 0 again
  H6 0xFE, silence until the module is off, then a long PEAK (Bluetooth off by the user) during the off phase: it stays off
  H7 0xFE, then Bluetooth off and on with PEAK (a new link, maybe another Bluetooth app): the watch starts disarmed, 25 s of
     silence: the module stays on (critique 2026-11-08)
  B1 the meter walk ends with the page bAcK after CL; SETUP there gives item 0 (the temperature page); a long SETUP on
     bAcK does the same
RUN LIMIT: 1 run of this script (8 boots).  The helpers are those of test_careful.py and test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_careful as C  # noqa: E402
import test_bt_upload as U  # noqa: E402

ITEM_CLK, ITEM_BACK = 25, 44


def sym(image, name):
    return T.symbol(os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map'), name)


def watch(e, on_addr, seconds, step=0.25):
    """[(t, module on)] every `step` seconds for `seconds`; t from the start of the watch."""
    out, t = [], 0.0
    while t < seconds - 1e-9:
        e.advance(step)
        t += step
        out.append((t, T.rd(e, on_addr)))
    return out


def first(samples, value, after=0.0):
    return next((t for t, v in samples if t > after and v == value), None)


def run_tests(image):
    on = sym(image, 'ble_usart_on')

    print('H1 no heartbeat: never a reset')
    e = C.boot(image)
    s = watch(e, on, 40.0)
    T.check('H1: 40 s of silence without 0xFE: the module stays on', all(v == 1 for _, v in s), 'off at %r' % first(s, 0))

    print('H2 0xFE then silence')
    e = C.boot(image)
    e.usart2.rx_feed(b'\xFE')
    s = watch(e, on, 25.0)
    off = first(s, 0)
    back = first(s, 1, after=off or 99)
    T.check('H2: the module off 15 s after the last byte', off is not None and 14.5 <= off <= 16.0, 'off at %r' % off)
    T.check('H2: on again 5 s later', back is not None and off is not None and 4.5 <= back - off <= 5.5,
            'off %r, on %r' % (off, back))
    n0 = len(e.ble_rx)
    e.advance(3.0)
    fr = C.frames_with_times(e, n0)
    T.check('H2: status frames flow again', len(fr) >= 4, '%d frames in 3 s' % len(fr))
    s = watch(e, on, 40.0)
    T.check('H2: the watch is off afterwards (no second reset in 40 s)', all(v == 1 for _, v in s), 'off at %r' % first(s, 0))

    print('H3 0xFE every 5 s')
    e = C.boot(image)
    s = []
    for k in range(8):
        e.usart2.rx_feed(b'\xFE')
        s += [(t + 5.0 * k, v) for t, v in watch(e, on, 5.0)]
    T.check('H3: 40 s with 0xFE every 5 s: the module stays on', all(v == 1 for _, v in s), 'off at %r' % first(s, 0))

    print('H4 0xFE, then 0xFD')
    e = C.boot(image)
    e.usart2.rx_feed(b'\xFE')
    e.advance(1.0)
    e.usart2.rx_feed(b'\xFD')
    s = watch(e, on, 40.0)
    T.check('H4: after 0xFD 40 s of silence: the module stays on', all(v == 1 for _, v in s), 'off at %r' % first(s, 0))

    print('H5 page Ld')
    card, _expect = C.F.build_card()
    e, link = U.open_page(image, card)
    e.usart2.rx_feed(b'\xFE')                        # on page Ld the bytes belong to the file transfer: no watch
    s = watch(e, on, 60.0)
    T.check('H5: 0xFE on page Ld arms nothing; 60 s idle there: the module stays on', all(v == 1 for _, v in s),
            'off at %r' % first(s, 0))

    print('H6 Bluetooth off by the user during the off phase')
    e = C.boot(image)
    e.usart2.rx_feed(b'\xFE')
    s = watch(e, on, 17.0)
    off = first(s, 0)
    T.check('H6: the module off by the watch', off is not None, 'off at %r' % off)
    T.long_press(e, 'PEAK')                          # the user switches Bluetooth off (it was on)
    s = watch(e, on, 10.0)
    T.check('H6: the long PEAK wins: the module stays off', all(v == 0 for _, v in s), 'on at %r' % first(s, 1))
    T.check('H6: Bluetooth switched off', T.rd(e, C.ADDR_BLE_ON) == 0, 'key_ble_on %d' % T.rd(e, C.ADDR_BLE_ON))

    print('H7 Bluetooth off and on disarms the watch')
    e = C.boot(image)
    e.usart2.rx_feed(b'\xFE')
    e.advance(2.0)
    T.long_press(e, 'PEAK')                          # off
    e.advance(1.0)
    T.long_press(e, 'PEAK')                          # on again: a new link
    e.advance(1.0)
    T.check('H7: Bluetooth on again', T.rd(e, C.ADDR_BLE_ON) == 1)
    s = watch(e, on, 25.0)
    T.check('H7: 25 s of silence after the PEAK off/on: the module stays on', all(v == 1 for _, v in s),
            'off at %r' % first(s, 0))

    print('B1 the page bAcK')
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('B1: page CL reached through the meter walk', T.to_item(e, ITEM_CLK), 'item %d' % T.rd(e, T.ADDR_ITEM))
    T.press(e, 'SETUP', gap=0.6)
    item = T.rd(e, T.ADDR_ITEM)
    texts = ' '.join(T.sample_texts(e))
    T.check('B1: after CL the page bAcK (item 44)', item == ITEM_BACK and 'BACK' in texts.upper().replace('C', 'C'),
            'item %d, sub %r' % (item, texts))
    T.press(e, 'SETUP', gap=0.6)
    T.check('B1: SETUP on bAcK: item 0, the temperature page', T.rd(e, T.ADDR_ITEM) == 0, 'item %d' % T.rd(e, T.ADDR_ITEM))
    T.to_item(e, ITEM_BACK)
    T.long_press(e, 'SETUP')
    T.check('B1: a long SETUP on bAcK: item 0 too', T.rd(e, T.ADDR_ITEM) == 0, 'item %d' % T.rd(e, T.ADDR_ITEM))

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
