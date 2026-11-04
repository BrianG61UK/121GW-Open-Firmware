"""Induced emulator test of the selectable Bluetooth frame rate (production image, FEATURES.md 2.5, DESIGN.md 10 IMP-09).

    python -I emulator/scripts/test_ble_rate.py [image]      default firmware/build/EEVBlog.bin (production build)

Drives the emulated meter in DCV with 1 V applied and the transfer on (PEAK long), counts the complete status frames the
meter sends on USART2 (19 bytes from 0xF2, XOR of all 19 bytes 0, analysis/ble_packet.md 3, 5) for each rate of the SETUP
page bt, and checks the page navigation (bL -> bt -> Ld, then on to item 0), the page texts, that only EEPROM byte 0x015 is written and
only by the save, the rate after a power cycle, the fallback of invalid bytes, and that an edit left unsaved is undone by
the edit timeout (fn_0800D190) for bt and for the dBm reference.  The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_ITEM = 0x20008037                               # setup item
ADDR_BLE_ON = 0x2000802B                             # transfer on (PEAK long)


def frames(e, seconds):
    """Complete, checksum-valid frames sent during the next `seconds` of emulated time."""
    start = len(e.ble_rx)
    e.advance(seconds)
    data = bytes(e.ble_rx[start:])
    n, i = 0, 0
    while i + 19 <= len(data):
        if data[i] == 0xF2:
            x = 0
            for b in data[i:i + 19]:
                x ^= b
            if x == 0:
                n += 1
                i += 19
                continue
        i += 1
    return n


def to_item(e, want):
    for _ in range(16):
        if T.rd(e, ADDR_ITEM) == want:
            break
        T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)


def dcv(e):
    e.command({'dial': 2})
    e.advance(3.0)
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(1.0)


def run_tests(image, a_rate, a_dbm):
    print('T1 rates')
    e = T.make(image, {0x15: 0})
    dcv(e)
    T.long_press(e, 'PEAK')
    T.check('transfer on', T.rd(e, ADDR_BLE_ON) == 1)
    e.advance(1.0)
    n = frames(e, 5.0)
    T.check('2 per second: 9..11 frames in 5 s', 9 <= n <= 11, 'frames=%d' % n)
    to_item(e, 20)
    T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('SETUP short on bL shows bt: "bt  2"', T.rd(e, ADDR_ITEM) == 21 and 'BT  2' in texts, 'samples=%r' % (texts,))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    for code, rate, text in ((1, 4, 'BT  4'), (2, 10, 'BT 10'), (3, 20, 'BT 20')):
        T.press(e, 'REL', gap=0.5)
        e.advance(0.6)
        texts = T.sample_texts(e)
        T.check('REL: code %d, "%s"' % (code, text.lower()), T.rd(e, a_rate) == code and text in texts, 'samples=%r' % (texts,))
        n = frames(e, 3.0)
        T.check('%d per second: %d..%d frames in 3 s' % (rate, 3 * rate - 1, 3 * rate + 1), 3 * rate - 1 <= n <= 3 * rate + 1,
                'frames=%d' % n)
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save wrote only 0x015 = 3', diff == {0x15: (0, 3)}, 'diff=%r' % (diff,))
    texts = T.sample_texts(e, n=6)
    T.check('after the save the edit has ended: steady "bt 20", no blink', 'BT 20' in texts and '     ' not in texts,
            'samples=%r' % (texts,))
    T.press(e, 'SETUP', gap=0.5)
    T.check('SETUP short on bt goes to the page Ld (item 39, IMP-28)', T.rd(e, ADDR_ITEM) == 39)
    to_item(e, 0)
    T.check('SETUP short through the remaining pages: item 0', T.rd(e, ADDR_ITEM) == 0)
    T.long_press(e, 'PEAK')
    e.advance(0.5)
    n = frames(e, 2.0)
    T.check('transfer off: no frames', T.rd(e, ADDR_BLE_ON) == 0 and n == 0, 'frames=%d' % n)
    e.power_cycle()
    dcv(e)
    T.check('power cycle: 20 per second from the EEPROM', T.rd(e, a_rate) == 3)

    print('T2 stored values')
    for value, want in ((0xFF, 0), (4, 0), (2, 2)):
        e = T.make(image, {0x15: value})
        e.command({'dial': 2})
        e.advance(3.0)
        T.check('0x015 = 0x%02X reads as %d' % (value, want), T.rd(e, a_rate) == want and e.m.eeprom[0x15] == value)

    print('T3 edit timeout undoes an unsaved edit')
    e = T.make(image, {0x15: 1})
    dcv(e)
    to_item(e, 20)
    T.press(e, 'SETUP', gap=0.5)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.check('bt edited to 10 per second', T.rd(e, a_rate) == 2)
    e.advance(125.0)
    T.check('after the timeout: 4 per second again, EEPROM unchanged', T.rd(e, a_rate) == 1 and e.m.eeprom[0x15] == 1)
    e = T.make(image, {0x11: 0})
    e.command({'dial': 2})
    e.advance(3.0)
    T.press(e, 'MODE', gap=0.5)                      # ACV
    to_item(e, 11)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.5)
    T.check('dBm reference edited to 50 ohm', T.rd(e, a_dbm) == 1)
    e.advance(125.0)
    T.check('after the timeout: 600 ohm again, EEPROM unchanged', T.rd(e, a_dbm) == 0 and e.m.eeprom[0x11] == 0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'ble_rate'), T.symbol(mp, 'set_dbm_ref'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
