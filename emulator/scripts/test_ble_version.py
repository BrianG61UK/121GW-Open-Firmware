"""Induced emulator test of the firmware version answer over Bluetooth (production image, FEATURES.md 2.11 stage 3).

    python -I emulator/scripts/test_ble_version.py [image]      default firmware/build/EEVBlog.bin

Bluetooth on (long PEAK), DCV.  The key frame with code 0x90 (F4 39 30 39 30) must be echoed and answered with the
version frame F6 c0..c4 x (the five characters of config.inc FW_VER_C0..C4, x = XOR of the six bytes before it, so the
XOR of all seven bytes is 0), and must not reach the key routine (remote key request 0x20008069 stays 0, code
0x2000806D unchanged, mode unchanged).  A normal remote key afterwards (code 5, the mode key: F4 30 35 30 35) is still
echoed and acted on (the mode changes) and gets no version frame.  The helpers are those of test_backlight_timer.py.
"""
import os
import re
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_BLE_ON = 0x2000802B
ADDR_KEY_REQ = 0x20008069
ADDR_KEY_CODE = 0x2000806D
ADDR_MODE = 0x2000803C


def frames_after(e, n0):
    """Bytes the meter sent since index n0 with the status frames (F2 + 18 bytes, XOR 0) taken out."""
    data = bytes(e.ble_rx[n0:])
    out, i = bytearray(), 0
    while i < len(data):
        if data[i] == 0xF2 and i + 19 <= len(data):
            x = 0
            for b in data[i:i + 19]:
                x ^= b
            if x == 0:
                i += 19
                continue
        out.append(data[i])
        i += 1
    return bytes(out)


def expected_version(image):
    cfg = open(os.path.join(T.ROOT, 'firmware', 'src', 'inc', 'config.inc')).read()
    chars = dict(re.findall(r"\.equ FW_VER_C(\d), '(.)'", cfg))
    body = bytes([0xF6]) + ''.join(chars[str(i)] for i in range(5)).encode('ascii')
    x = 0
    for b in body:
        x ^= b
    return body + bytes([x])


def run_tests(image):
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    T.check('Bluetooth on', T.rd(e, ADDR_BLE_ON) == 1)
    mode0, code0 = T.rd(e, ADDR_MODE), T.rd(e, ADDR_KEY_CODE)

    print('T1 version request (code 0x90)')
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(b'\xF4' + b'9090')
    e.advance(1.0)
    got = frames_after(e, n0)
    want = expected_version(image)
    T.check('echo of the request', got.startswith(b'\xF4' + b'9090'), 'got %r' % got[:12])
    T.check('version frame %s' % want.hex(' '), got[5:12] == want, 'got %r' % got)
    x = 0
    for b in got[5:12]:
        x ^= b
    T.check('XOR of the seven bytes is 0', len(got) >= 12 and x == 0)
    T.check('nothing else sent', len(got) == 12, 'got %d bytes' % len(got))
    T.check('not handed to the key routine (request 0, code unchanged)',
            T.rd(e, ADDR_KEY_REQ) == 0 and T.rd(e, ADDR_KEY_CODE) == code0,
            'req %d code 0x%02X' % (T.rd(e, ADDR_KEY_REQ), T.rd(e, ADDR_KEY_CODE)))
    T.check('mode unchanged', T.rd(e, ADDR_MODE) == mode0)

    print('T2 a normal remote key still works (code 5, mode key)')
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(b'\xF4' + b'0505')
    e.advance(1.0)
    got = frames_after(e, n0)
    T.check('echo of the key frame, no version frame', got == b'\xF4' + b'0505', 'got %r' % got)
    T.check('mode changed by the remote mode key', T.rd(e, ADDR_MODE) != mode0,
            'mode %d -> %d' % (mode0, T.rd(e, ADDR_MODE)))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
