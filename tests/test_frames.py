"""Reassembly of the answers of type 0x82 (card and settings requests) from notifications of any length; the link 2
decoder (firmware F-1.31, IMP-62, GitHub issue 30)."""
import unittest

from support import card, frames, settings


def answer(seq, status, data=b'', field=0):
    return card.answer_packet(seq, status, field, data)


class Answers82(unittest.TestCase):
    def feed_split(self, stream, cut):
        r = frames.Reassembler()
        out = []
        for i in range(0, len(stream), cut):
            out += r.feed(stream[i:i + cut])
        return r, out

    def test_every_notification_size(self):
        # data with the start bytes of other frames inside (F2, F4, B5 5B), 232 bytes = a full CHUNK answer
        data = bytes([0xF2, 0xF4, 0xB5, 0x5B, 0x82] * 46) + b'\xF8\x00'
        frame = answer(0x1234, card.ST_OK, data)
        self.assertEqual(len(frame), 8 + 3 + 232)
        for cut in (1, 2, 3, 5, 7, 19, 20, 100, 241, 242, 500):
            r, out = self.feed_split(frame, cut)
            self.assertEqual(out, [(frames.BFT, frame)], 'cut %d' % cut)
            self.assertEqual(r.dropped, 0)
            self.assertEqual(card.parse_answer(out[0][1]), (0x1234, card.ST_OK, 0, data))

    def test_split_at_every_byte(self):
        frame = answer(7, card.ST_NOT_FOUND)
        for k in range(1, len(frame)):
            r = frames.Reassembler()
            got = r.feed(frame[:k]) + r.feed(frame[k:])
            self.assertEqual(got, [(frames.BFT, frame)], 'split at %d' % k)

    def test_two_frames_and_a_damaged_one_between(self):
        a, b = answer(1, card.ST_OK, b'abc'), answer(3, card.ST_OK, b'xyz')
        bad = bytearray(answer(2, card.ST_OK, b'mid'))
        bad[8] ^= 0x55                                   # CRC-16 no longer matches
        r, out = self.feed_split(a + bytes(bad) + b + b'\x00\x01', 5)
        self.assertEqual([f for _, f in out], [a, b])
        self.assertGreater(r.dropped, 0)                 # the damaged frame's bytes were skipped, the next frame found

    def test_status_and_answer_mixed(self):
        status = bytearray(19)
        status[0] = 0xF2
        status[18] = frames._xor(status[:18])
        count, data = settings.get_answer([(0x15, 2), (0x28, 1)])
        frame = answer(9, card.ST_OK, data, count)
        self.assertEqual(card.parse_answer(frame), (9, card.ST_OK, 2, data))
        r, out = self.feed_split(bytes(status) + frame, 4)
        self.assertEqual([k for k, _ in out], [frames.STATUS, frames.BFT])

    def test_81_and_82_are_told_apart(self):
        from support import transfer
        self.assertIsNone(card.parse_answer(transfer.packet(0x81, 1, b'\x00\x00\x00')))   # a 0x81 frame is not a card answer
        self.assertIsNone(transfer.answer(answer(1, 0)))          # a 0x82 frame is not a transfer answer


if __name__ == '__main__':
    unittest.main()


class Certificates(unittest.TestCase):
    """GitHub issue 13: the packaged macOS program had no CA file; the downloads carry certifi's list."""
    def test_context_has_certifi_list(self):
        import certifi
        from meter121 import releases
        ctx = releases._ssl_context()
        self.assertGreater(ctx.cert_store_stats()['x509_ca'], 100)
        self.assertTrue(certifi.where().endswith('.pem'))


# link 2 blocks built here with a parity from polynomial division (independent of the decoder's syndrome check)
_EXP, _LOG = [0] * 512, [0] * 256
_v = 1
for _i in range(255):
    _EXP[_i], _LOG[_v] = _v, _i
    _v <<= 1
    if _v & 0x100:
        _v ^= 0x11D
for _i in range(255, 512):
    _EXP[_i] = _EXP[_i - 255]


def _mul(a, b):
    return 0 if a == 0 or b == 0 else _EXP[_LOG[a] + _LOG[b]]


def block(typ, seq, payload):
    msg = [typ << 6 | seq] + list(payload) + [0] * (16 - len(payload))
    r = msg + [0, 0, 0]
    for i in range(17):
        c = r[i]
        if c:
            for j, g in enumerate((7, 14, 8), 1):
                r[i + j] ^= _mul(g, c)
    return bytes(msg + r[17:])


STATE7 = bytes([0x01, 0x02, 0x69, 0x01, 0x0E, 0x40, 0x00])     # [5]&3F [6]&3F [9] [13]&FB [15] [16] [17]
IDENT = bytes([0x17, 0x81, 0x23, 0x45])
SUB0 = (0x01, 0x00, 0xFA)


def state_block(seq, ver=1, dropped=0):
    return block(3, seq, [ver] + list(STATE7) + list(IDENT) + [5, 0x02, 0x0C, dropped])


def f2(v, bar, sub=SUB0, ovl=0, bsign=0):
    a, neg = abs(v), v < 0
    f = bytearray(19)
    f[0] = 0xF2
    f[1:5] = IDENT
    f[5] = STATE7[0] | ((a >> 16) & 3) << 6
    f[6] = STATE7[1] | ovl << 7 | (0x40 if neg else 0)
    f[7], f[8] = (a >> 8) & 0xFF, a & 0xFF
    f[9] = STATE7[2]
    f[10:13] = bytes(sub)
    f[13] = STATE7[3] | bsign << 2
    f[14] = bar
    f[15:18] = STATE7[4:7]
    f[18] = frames._xor(f[:18])
    return bytes(f)


def read_block(seq, ver=1, age=3):
    """1234 with bar 12, +2 and -1 (one byte each), +55 with bar 13 (the bar form)."""
    return block(1, seq, [ver, age] + list(SUB0) + [0xE2, 0x00, 0x04, 0xD2, 12, 0x82, 0xBF, 0xC0 + 13, 55])


def sub_block(seq, ver=1):
    """-5 (absolute, negative), then a new sub display and -6 (one byte)."""
    return block(1, seq, [ver, 0] + list(SUB0) + [0xE2, 0x80, 0x00, 0x05, 0, 0xF0, 0x02, 0x00, 0xFB, 0x80 | (-1 & 0x3F)])


EXPECT = [f2(1234, 12), f2(1236, 12), f2(1235, 12), f2(1290, 13)]


class Link2(unittest.TestCase):
    def stream(self):
        return state_block(0) + read_block(1)

    def test_readings_rebuilt_as_status_frames(self):
        d = frames.Link2()
        plain, got = d.feed(self.stream())
        self.assertEqual(plain, b'')
        self.assertEqual([f for f, _ in got], EXPECT)
        ages = [a for _, a in got]
        self.assertAlmostEqual(ages[-1], 3 * frames.L2_TICK_S)
        self.assertTrue(all(x > y for x, y in zip(ages, ages[1:])))  # older first

    def test_negative_values_and_a_new_sub_display(self):
        d = frames.Link2()
        _plain, got = d.feed(state_block(0) + sub_block(1))
        self.assertEqual([f for f, _ in got], [f2(-5, 0), f2(-6, 0, sub=(0x02, 0x00, 0xFB))])

    def test_every_single_damaged_byte_is_corrected(self):
        good = read_block(1)
        for pos in range(20):
            for e in (0x01, 0x80, 0xFF, 0x5A):
                bad = bytearray(good)
                bad[pos] ^= e
                self.assertEqual(frames.l2_correct(bytes(bad)), good, (pos, e))

    def test_two_damaged_bytes_never_a_wrong_block(self):
        import random
        rnd = random.Random(62)
        good = read_block(1)
        for _ in range(20000):
            bad = bytearray(good)
            p, q = rnd.sample(range(20), 2)
            bad[p] ^= rnd.randrange(1, 256)
            bad[q] ^= rnd.randrange(1, 256)
            self.assertIsNone(frames.l2_correct(bytes(bad)))

    def test_plain_bytes_before_the_lock_pass_on(self):
        d = frames.Link2()
        key_echo = frames.key_frame(0xA8)
        plain, got = d.feed(key_echo + self.stream())
        self.assertEqual(plain, key_echo)
        self.assertEqual(len(got), 4)

    def test_a_damaged_block_after_the_lock_is_corrected_and_counted(self):
        s = bytearray(self.stream() + read_block(2))
        s[40 + 7] ^= 0x40
        d = frames.Link2()
        _plain, got = d.feed(bytes(s))
        self.assertEqual([f for f, _ in got], EXPECT * 2)
        self.assertEqual(d.stats['corrected'], 1)

    def test_a_reading_of_another_version_is_never_shown(self):
        d = frames.Link2()
        _plain, got = d.feed(state_block(0, ver=1) + read_block(1, ver=2) + read_block(2, ver=1))
        self.assertEqual([f for f, _ in got], EXPECT)
        self.assertEqual(d.stats['stale'], 1)

    def test_text_blocks_go_to_the_reassembler(self):
        echo = frames.key_frame(0x90) + b'\xF6F-1311'
        d = frames.Link2()
        plain, _got = d.feed(state_block(0) + block(2, 1, [len(echo)] + list(echo)))
        self.assertEqual(plain, echo)

    def test_back_to_plain_after_three_bad_blocks(self):
        d = frames.Link2()
        d.feed(self.stream())
        plain_frames = f2(1, 1) * 4                       # the meter left link 2: plain status frames
        plain, got = d.feed(plain_frames)
        self.assertEqual(got, [])
        self.assertFalse(d.locked)
        self.assertEqual(plain + bytes(d.buf), plain_frames)   # nothing lost; the tail waits for more bytes

    def test_lost_block_counted_from_the_sequence(self):
        d = frames.Link2()
        d.feed(state_block(0) + read_block(1) + read_block(3))
        self.assertEqual(d.stats['lost'], 1)

