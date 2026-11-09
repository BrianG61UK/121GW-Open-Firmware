"""Induced emulator test of link 2 (firmware IMP-62, ble/link2.s; GitHub issue 30).

    python -I emulator/scripts/test_link2.py [image]              default firmware/build/EEVBlog.bin

The decoder here is written from the block format in ble/link2.s's header, independently of the companion: it finds
blocks in the byte stream by their Reed-Solomon parity (all three syndromes 0), keeps the last STATE, decodes READ
blocks only when their version equals it, and rebuilds each reading as the status frame bytes [1..17].
  L1 link 2 (key code 0xA8) on a meter with a changing input: the readings it delivers equal, byte for byte ([1..17]),
     the status frames the same meter built (captured at every call of l2_frame), all of them, in order
  L2 every block a codeword; blocks at most 5 a second at the default pace (20 ticks); the first block a STATE
  L3 a key code while link 2 is on (0x90, the version question): its echo and the version frame arrive in TEXT blocks
  L4 one damaged byte in each of 50 blocks (the late-sampling pattern: shifted right with 1s at the top): every block
     repaired and the readings unchanged
  L5 20 readings a second (0x9C) and the pace key 0xAE (index 4: 14 ticks): at most 7.1 blocks a second, at least 6
  L6 0xFD (the companion's goodbye): status frames F2 again; 0xA8 again: blocks again, starting with a STATE
  L7 Bluetooth off and on: status frames F2 (link 2 must be asked again)
  L8 the key codes of removed features (0x97, 0x98, 0x9D, 0x9E, 0xA1..0xA4): echoed, nothing changes (no F3 copies,
     no F5 frames, the saved rate kept), no remote key
  L9 20 readings a second (0x9C), the default pace, a changing input and SETUP pressed through pages (settings versions,
     sub display changes): every reading delivered equals its built frame, in order; built = delivered + dropped
     (the drop counter of the STATE blocks); readings a second delivered reported
RUN LIMIT: 1 run of this script (6 boots).  The helpers are those of test_careful.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_careful as C  # noqa: E402
from unicorn import UC_HOOK_CODE  # noqa: E402

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


def syndromes(cw):
    out = []
    for k in range(3):
        s = 0
        for b in cw:
            s = gmul(s, EXP[k]) ^ b
        out.append(s)
    return out


def correct(cw):
    """The 20 bytes repaired (one damaged byte), as received (none), or None."""
    s0, s1, s2 = syndromes(cw)
    if (s0, s1, s2) == (0, 0, 0):
        return bytes(cw)
    if not (s0 and s1 and s2) or gmul(s1, s1) != gmul(s0, s2):
        return None
    pos = 19 - (LOG[s1] - LOG[s0]) % 255
    if not 0 <= pos < 20:
        return None
    out = bytearray(cw)
    out[pos] ^= s0
    return bytes(out) if syndromes(out) == [0, 0, 0] else None


class Decoder:
    def __init__(self):
        self.state = None                            # (ver, state7, ident4, period)
        self.readings = []                           # frame bytes [1..17] (17 bytes) of every reading delivered
        self.text = bytearray()
        self.blocks = []                             # (type, seq) of every block found
        self.corrected = 0
        self.versions = []
        self.dropped = 0

    def feed(self, data, fix=True):
        i = 0
        locked = False
        while i + 20 <= len(data):
            cw = bytes(data[i:i + 20])
            typ = cw[0] >> 6
            if syndromes(cw) == [0, 0, 0] and typ:
                good = cw
            elif locked and fix:
                good = correct(cw)
                if good is not None:
                    self.corrected += 1
            else:
                good = None
            if good is None or not good[0] >> 6:
                i += 1
                locked = False
                continue
            locked = True
            self.block(good)
            i += 20

    def block(self, b):
        typ, seq, p = b[0] >> 6, b[0] & 0x3F, b[1:17]
        self.blocks.append((typ, seq))
        if typ == 3:
            self.state = (p[0], bytes(p[1:8]), bytes(p[8:12]), p[12])
            self.versions.append(p[0])
            self.dropped = p[15]
        elif typ == 2:
            self.text += bytes(p[1:1 + p[0]])
        elif typ == 1:
            if self.state is None or p[0] != self.state[0]:
                return
            sub = list(p[2:5])
            r = list(p[5:])
            assert r[0] in (0xE2, 0xE3), 'READ block not opening with an absolute reading: %02X' % r[0]
            k = 0
            cur = None
            while k < len(r) and r[k] != 0x00:
                t = r[k]
                if t == 0xF4:
                    k += 2
                    continue
                if t == 0xF0:
                    sub = r[k + 1:k + 4]
                    k += 4
                    continue
                if t & 0xC0 == 0x80:
                    d = t & 0x3F
                    d = d - 64 if d & 0x20 else d
                    cur = dict(cur, v=cur['v'] + d, negzero=False)
                    k += 1
                elif 0xC0 <= t <= 0xD9:
                    x = r[k + 1]
                    d = x & 0x7F
                    d = d - 128 if d & 0x40 else d
                    cur = dict(cur, v=cur['v'] + d, bar=t - 0xC0, bsign=x >> 7, negzero=False)
                    k += 2
                elif t in (0xE0, 0xE1, 0xE2, 0xE3):
                    v2, v1, v0 = r[k + 1:k + 4]
                    a = ((v2 & 3) << 16) | (v1 << 8) | v0
                    neg = bool(v2 & 0x80)
                    nc = dict(cur or {}, v=-a if neg else a, negzero=neg and a == 0, ovl=t & 1)
                    k += 4
                    if t & 2:
                        nc['bar'], nc['bsign'] = r[k] & 0x1F, (r[k] >> 5) & 1
                        k += 1
                    cur = nc
                else:
                    raise AssertionError('unknown record tag %02X' % t)
                self.readings.append(self.frame(cur, sub))

    def frame(self, c, sub):
        ver, st, ident, _period = self.state
        a = abs(c['v'])
        neg = c['v'] < 0 or c['negzero']
        f = bytearray(18)
        f[1:5] = ident
        f[5] = st[0] | ((a >> 16) & 3) << 6
        f[6] = st[1] | (c['ovl'] << 7) | (0x40 if neg else 0)
        f[7], f[8] = (a >> 8) & 0xFF, a & 0xFF
        f[9] = st[2]
        f[10:13] = bytes(sub)
        f[13] = st[3] | (c['bsign'] << 2)
        f[14] = c['bar']
        f[15:18] = st[4:7]
        return bytes(f[1:18])


def stimulus(e, seconds):
    """The same input sequence on every meter: a slow ramp, a few jumps, a negative value."""
    values = [0.5, 0.501, 0.5012, 0.52, 1.2, -0.3, -0.31, 3.3, 3.3, 0.0, 0.7]
    step = seconds / len(values)
    for v in values:
        e.command({'input': {'kind': 'V', 'value': v, 'ac': False}})
        e.advance(step)


def plain_frames(e, n0):
    return [f for _, f in C.frames_with_times(e, n0)]


def capture_frames(e, image):
    """Every status frame the meter builds while link 2 is on: ble_frame_b at each entry of l2_frame."""
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    at, buf = T.symbol(mp, 'l2_frame'), T.symbol(mp, 'ble_frame_b')
    e.built = []

    def hook(uc, address, size, user):
        e.built.append(bytes(uc.mem_read(buf + 1, 17)))
    e.m.uc.hook_add(UC_HOOK_CODE, hook, None, at & ~1, at & ~1)


def run_tests(image):
    print('L1 / L2 link 2 against the frames the meter built')
    el = C.boot(image)
    capture_frames(el, image)
    n0l = len(el.ble_rx)
    el.usart2.rx_feed(C.key_frame(0xA8))
    stimulus(el, 11.0)
    el.advance(1.0)                                  # the last readings leave
    plain = list(el.built)
    raw = bytes(el.ble_rx[n0l:])
    i = raw.find(C.key_frame(0xA8))
    T.check('L1: 0xA8 echoed (plain, before the blocks)', i >= 0)
    dec = Decoder()
    dec.feed(raw[i + 5:])
    got = dec.readings
    T.check('L1: link 2 delivered readings', len(got) >= 15, '%d readings, %d blocks' % (len(got), len(dec.blocks)))
    diff = next((k for k in range(min(len(got), len(plain))) if got[k] != plain[k]), None)
    T.check('L1: every built frame delivered, byte for byte, in order', got == plain,
            '%d delivered, %d built; first difference at %s: %s / %s' % (
                len(got), len(plain), diff, got[diff].hex() if diff is not None else '-',
                plain[diff].hex() if diff is not None else '-'))
    T.check('L2: the first block is a STATE', dec.blocks[:1] and dec.blocks[0][0] == 3, repr(dec.blocks[:3]))
    T.check('L2: no damaged block', dec.corrected == 0)
    secs = 11.0
    T.check('L2: at most 5 blocks a second', len(dec.blocks) <= 5 * secs + 2, '%d blocks in %.0f s' % (len(dec.blocks), secs))
    seqs = [s for _, s in dec.blocks]
    T.check('L2: sequence numbers in order', all((b - a) % 64 == 1 for a, b in zip(seqs, seqs[1:])), repr(seqs[:12]))

    print('L3 a key code under link 2')
    n0 = len(el.ble_rx)
    el.usart2.rx_feed(C.key_frame(0x90))
    el.advance(2.0)
    d3 = Decoder()
    d3.feed(bytes(el.ble_rx[n0:]))
    T.check('L3: the echo and the version frame in TEXT blocks', C.key_frame(0x90) in bytes(d3.text) and b'\xF6' in bytes(d3.text),
            bytes(d3.text).hex())

    print('L4 damaged bytes')
    data = bytearray(raw[i + 5:])
    blocks_at = []
    k = 0
    while k + 20 <= len(data):
        if syndromes(data[k:k + 20]) == [0, 0, 0] and data[k] >> 6:
            blocks_at.append(k)
            k += 20
        else:
            k += 1
    for n, at in enumerate(blocks_at[1:51]):                 # the first stays clean: the decoder locks on it
        pos = at + (n * 7) % 20
        data[pos] = ((data[pos] >> 1) | 0x80) & 0xFF if data[pos] != ((data[pos] >> 1) | 0x80) else data[pos] ^ 0x10
    d4 = Decoder()
    d4.feed(bytes(data))
    T.check('L4: every damaged block repaired', d4.corrected == min(50, len(blocks_at) - 1), '%d of %d' % (
        d4.corrected, min(50, len(blocks_at) - 1)))
    T.check('L4: the readings unchanged', d4.readings == got, '%d vs %d' % (len(d4.readings), len(got)))

    print('L5 pace')
    el.usart2.rx_feed(C.key_frame(0x9C))
    el.usart2.rx_feed(C.key_frame(0xAE))
    el.advance(1.0)
    n0 = len(el.ble_rx)
    stimulus(el, 6.0)
    d5 = Decoder()
    d5.feed(bytes(el.ble_rx[n0:]))
    T.check('L5: 14 ticks: between 6 and 7.1 blocks a second', 36 <= len(d5.blocks) <= 6.0 / (14 * 0.01002) + 1,
            '%d in 6 s' % len(d5.blocks))

    print('L6 goodbye and again')
    el.usart2.rx_feed(b'\xFD')
    el.advance(1.0)
    n0 = len(el.ble_rx)
    el.advance(3.0)
    T.check('L6: status frames after 0xFD', len(plain_frames(el, n0)) >= 4)
    n0 = len(el.ble_rx)
    el.usart2.rx_feed(C.key_frame(0xA8))
    el.advance(3.0)
    d6 = Decoder()
    d6.feed(bytes(el.ble_rx[n0:]))
    T.check('L6: blocks again, a STATE first', d6.blocks[:1] and d6.blocks[0][0] == 3 and not plain_frames(el, n0),
            repr(d6.blocks[:3]))

    print('L7 Bluetooth off and on')
    T.long_press(el, 'PEAK')
    el.advance(1.0)
    T.long_press(el, 'PEAK')
    el.advance(1.0)
    n0 = len(el.ble_rx)
    el.advance(3.0)
    d7 = Decoder()
    d7.feed(bytes(el.ble_rx[n0:]))
    T.check('L7: status frames, no blocks', len(plain_frames(el, n0)) >= 4 and not d7.blocks)

    print('L8 removed key codes')
    e8 = C.boot(image)
    for code in (0x97, 0x98, 0x9D, 0x9E, 0xA1, 0xA2, 0xA3, 0xA4):
        n0 = len(e8.ble_rx)
        e8.usart2.rx_feed(C.key_frame(code))
        e8.advance(2.0)
        out = bytes(e8.ble_rx[n0:])
        fr = C.frames_with_times(e8, n0)
        T.check('L8: 0x%02X echoed, only F2 frames at the saved rate' % code,
                C.key_frame(code) in out and 3 <= len(fr) <= 5 and all(f[0] == 0xF2 for _, f in fr) and 0xF5 not in out,
                '%d frames' % len(fr))
    T.check('L8: none reached the key routine (key_remote_code 0x2000806D untouched)', T.rd(e8, 0x2000806D) == 0,
            'code 0x%02X' % T.rd(e8, 0x2000806D))

    print('L9 20 readings a second, pages')
    e9 = C.boot(image)
    capture_frames(e9, image)
    n0 = len(e9.ble_rx)
    e9.usart2.rx_feed(C.key_frame(0x9C))
    e9.advance(0.5)
    e9.usart2.rx_feed(C.key_frame(0xA8))
    t9 = T.now(e9)
    for _ in range(3):
        stimulus(e9, 3.0)
        T.press(e9, 'SETUP', gap=0.5)
    e9.advance(2.0)
    d9 = Decoder()
    raw9 = bytes(e9.ble_rx[n0:])
    d9.feed(raw9[raw9.find(C.key_frame(0xA8)) + 5:])
    built = list(e9.built)
    it = iter(built)
    in_order = all(any(r == b for b in it) for r in d9.readings)
    states = [b for b in d9.blocks if b[0] == 3]
    T.check('L9: every delivered reading is a built frame, in order', in_order and len(d9.readings) > 0,
            '%d delivered of %d built' % (len(d9.readings), len(built)))
    T.check('L9: several settings versions seen', len(set(s for s in d9.versions)) >= 2, repr(sorted(set(d9.versions))))
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    eh, et = T.rd(e9, T.symbol(mp, 'l2_eh')), T.rd(e9, T.symbol(mp, 'l2_et'))
    queued = (eh - et) & 15                          # readings still waiting for a block at the end
    unsent = 0
    if T.rd(e9, T.symbol(mp, 'l2_blk_ready')):       # a block built, not completely sent at the end: its readings
        dx = Decoder()
        dx.state = d9.state
        dx.block(bytes(e9.m.uc.mem_read(T.symbol(mp, 'l2_blk'), 20)))
        unsent = len(dx.readings)
    lost = len(built) - len(d9.readings)
    T.check('L9: built = delivered + dropped + still queued + in the unfinished block',
            lost == d9.dropped + queued + unsent, 'lost %d: dropped %d, queued %d, unfinished block %d' % (
                lost, d9.dropped, queued, unsent))
    secs = T.now(e9) - t9
    print('  20 a second: %d readings built in %.1f s, %d delivered (%.1f a second), %d blocks (%.1f a second), %d STATE' % (
        len(built), secs, len(d9.readings), len(d9.readings) / secs, len(d9.blocks), len(d9.blocks) / secs, len(states)))

    s = el.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'],
            'unmodelled %r safety %r' % (s['unmodelled'], s['safety']))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
