"""Induced emulator test of the status frames with error correction (firmware IMP-60, ble/usart.s ble_tx_pump and
ble_rs_feed, ble/commands.s 0x9D / 0x9E; GitHub issue 30).

    python -I emulator/scripts/test_fec.py [image]                default firmware/build/EEVBlog.bin

With key code 0x9D the meter sends each status frame as F5, the 17 value bytes of the F2 frame and three Reed-Solomon
parity bytes (21 bytes; GF(256), polynomial 0x11D, generator (x - 1)(x - 2)(x - 4)).  The parity is checked here with an
independent encoder (polynomial division with log / antilog tables, not the firmware's shift-and-add form):
  E1 without 0x9D: F2 frames only
  E2 0x9D echoed; then only F5 frames of 21 bytes, every one a codeword (all three syndromes 0), with the value bytes of
     the F2 frames before (a steady reading: the same 17 bytes)
  E3 careful mode (0x97) together with 0x9D: no F3 copies while frames carry the parity
  E4 0x9E: F2 frames again
  E5 0x9D, then the companion's goodbye byte 0xFD: F2 frames again
  E6 0x9D, then Bluetooth off and on (long PEAK twice): F2 frames again
  E7 0x9D with the link rate 20 a second (0x9C): at least 36 F5 frames in 2 s, all codewords
RUN LIMIT: 1 run of this script (5 boots).  The helpers are those of test_careful.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_careful as C  # noqa: E402

EXP, LOG = [0] * 512, [0] * 256
_x = 1
for _i in range(255):
    EXP[_i], LOG[_x] = _x, _i
    _x <<= 1
    if _x & 0x100:
        _x ^= 0x11D
for _i in range(255, 512):
    EXP[_i] = EXP[_i - 255]


def gmul(a, b):
    return 0 if a == 0 or b == 0 else EXP[LOG[a] + LOG[b]]


GEN = [1, 7, 14, 8]                                  # (x - 1)(x - 2)(x - 4)


def parity(msg):
    """Remainder of msg(x) * x^3 divided by GEN (long division)."""
    r = list(msg) + [0, 0, 0]
    for i in range(len(msg)):
        c = r[i]
        if c:
            for j in range(1, 4):
                r[i + j] ^= gmul(GEN[j], c)
    return bytes(r[-3:])


def syndromes(cw):
    out = []
    for k in range(3):
        s = 0
        for b in cw:
            s = gmul(s, EXP[k]) ^ b
        out.append(s)
    return out


def fec_frames(e, n0):
    data = bytes(e.ble_rx[n0:])
    out, i = [], 0
    while i + 21 <= len(data):
        if data[i] == 0xF5 and syndromes(data[i:i + 21]) == [0, 0, 0]:
            out.append(data[i:i + 21])
            i += 21
            continue
        i += 1
    return out


def kinds(e, n0, secs):
    e.advance(secs)
    f2 = [f for _, f in C.frames_with_times(e, n0)]
    f5 = fec_frames(e, n0)
    raw = bytes(e.ble_rx[n0:])
    return f2, f5, raw


def run_tests(image):
    assert syndromes(b'\xF5' + bytes(17) + parity(b'\xF5' + bytes(17))) == [0, 0, 0]   # the checker itself

    print('E1 .. E4')
    e = C.boot(image)
    n0 = len(e.ble_rx)
    f2, f5, raw = kinds(e, n0, 3.0)
    T.check('E1: without 0x9D only F2 frames', len(f2) >= 4 and not f5 and 0xF5 not in raw[:1], '%d F2, %d F5' % (len(f2), len(f5)))
    before = f2[-1]
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(C.key_frame(0x9D))
    e.advance(0.5)
    T.check('E2: 0x9D echoed', C.key_frame(0x9D) in bytes(e.ble_rx[n0:]))
    n0 = len(e.ble_rx)
    f2, f5, raw = kinds(e, n0, 3.0)
    T.check('E2: only F5 frames, every one a codeword', len(f5) >= 4 and not f2 and len(raw) == 21 * len(f5) + (len(raw) % 21),
            '%d F5, %d F2, %d bytes' % (len(f5), len(f2), len(raw)))
    T.check('E2: the parity equals an independent encoder', all(f[18:] == parity(f[:18]) for f in f5))
    T.check('E2: the value bytes are those of the F2 frame', all(f[1:18] == before[1:18] for f in f5),
            '%s / %s' % (f5[0][1:18].hex() if f5 else '-', before[1:18].hex()))
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(C.key_frame(0x97))
    f2, f5, raw = kinds(e, n0, 3.0)
    T.check('E3: careful mode with 0x9D: no F3 copy', 0xF3 not in [f[0] for f in f2] and len(f5) >= 4 and not f2,
            '%d F5, %d F2/F3' % (len(f5), len(f2)))
    e.usart2.rx_feed(C.key_frame(0x98))
    e.advance(0.5)
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(C.key_frame(0x9E))
    e.advance(0.5)
    n0 = len(e.ble_rx)
    f2, f5, raw = kinds(e, n0, 3.0)
    T.check('E4: 0x9E: F2 frames again', len(f2) >= 4 and not f5, '%d F2, %d F5' % (len(f2), len(f5)))

    print('E5 goodbye byte')
    e = C.boot(image)
    e.usart2.rx_feed(C.key_frame(0x9D))
    e.advance(1.0)
    e.usart2.rx_feed(b'\xFD')
    e.advance(0.5)
    n0 = len(e.ble_rx)
    f2, f5, raw = kinds(e, n0, 3.0)
    T.check('E5: after 0xFD F2 frames', len(f2) >= 4 and not f5, '%d F2, %d F5' % (len(f2), len(f5)))

    print('E6 Bluetooth off and on')
    e = C.boot(image)
    e.usart2.rx_feed(C.key_frame(0x9D))
    e.advance(1.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    T.check('E6: Bluetooth on again', T.rd(e, C.ADDR_BLE_ON) == 1)
    n0 = len(e.ble_rx)
    f2, f5, raw = kinds(e, n0, 3.0)
    T.check('E6: F2 frames on the new link', len(f2) >= 4 and not f5, '%d F2, %d F5' % (len(f2), len(f5)))

    print('E7 20 a second')
    e = C.boot(image)
    e.usart2.rx_feed(C.key_frame(0x9C))
    e.usart2.rx_feed(C.key_frame(0x9D))
    e.advance(1.0)
    n0 = len(e.ble_rx)
    f2, f5, raw = kinds(e, n0, 2.0)
    T.check('E7: 20 a second with parity: at least 36 F5 frames in 2 s', len(f5) >= 36 and not f2,
            '%d F5, %d F2' % (len(f5), len(f2)))
    T.check('E7: every one with the independent parity', all(f[18:] == parity(f[:18]) for f in f5))

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
