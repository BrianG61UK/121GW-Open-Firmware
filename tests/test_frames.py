"""Reassembly of the answers of type 0x82 (card and settings requests) from notifications of any length; repair of
status frames with one byte read late (GitHub issue 30)."""
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


# the frame the meter sent and ten damaged copies from the report of GitHub issue 30 (2026-11-08); byte 8 and the check
# byte differ between frames of that run, so each damaged frame is given with its own sent form
GOOD = bytes.fromhex('F2 17 81 23 45 01 00 00 00 69 01 02 BC 00 00 0E 40 00 9B')
ISSUE30 = [
    ('F2 17 81 23 45 01 00 00 00 69 01 02 BC 00 00 0E 08 00 9B', 16),
    ('F2 17 81 23 45 01 00 00 01 69 01 02 BC 00 00 0E 40 40 9A', 17),
    ('F2 8B 81 23 45 01 00 00 01 69 01 02 BC 00 00 0E 40 00 9A', 1),
    ('F2 17 C0 23 45 01 00 00 00 69 01 02 BC 00 00 0E 40 00 9B', 2),
    ('F2 17 81 91 45 01 00 00 01 69 01 02 BC 00 00 0E 40 00 9A', 3),
    ('F2 8B 81 23 45 01 00 00 00 69 01 02 BC 00 00 0E 40 00 9B', 1),
    ('F2 45 81 23 45 01 00 00 01 69 01 02 BC 00 00 0E 40 00 9A', 1),
    ('F2 17 E0 23 45 01 00 00 00 69 01 02 BC 00 00 0E 40 00 9B', 2),
    ('F2 17 C0 23 45 01 00 00 01 69 01 02 BC 00 00 0E 40 00 9A', 2),
    ('F2 17 81 48 45 01 00 00 00 69 01 02 BD 00 00 0E 40 00 9A', 3),
]


def checked(body):
    return body[:18] + bytes([frames._xor(body[:18])])


class Repair(unittest.TestCase):
    def test_issue30_frames(self):
        """All ten damaged frames of the report come back as the frame sent: the damaged byte restored, nothing else."""
        for hexs, pos in ISSUE30:
            bad = bytes.fromhex(hexs)
            sent = bytearray(bad)
            sent[pos] = GOOD[pos]
            self.assertEqual(frames._xor(sent), 0, hexs)             # the sent form passes its own check
            last = checked(bytes(sent[:12]) + GOOD[12:18])           # an earlier good frame of the run
            self.assertEqual(frames.repair(bad, last), bytes(sent), hexs)

    def test_stream(self):
        """In a stream: a good frame, a damaged one, a good one: three status frames, one repaired, nothing dropped."""
        bad = bytes.fromhex(ISSUE30[2][0])
        prev = checked(bytes.fromhex('F2 17 81 23 45 01 00 00 01 69 01 02 BC 00 00 0E 40 00 00'))
        r = frames.Reassembler()
        got = r.feed(prev + bad + prev)
        self.assertEqual([k for k, _ in got], [frames.STATUS] * 3)
        self.assertEqual(got[1][1], prev)
        self.assertEqual((r.repaired, r.dropped), (1, 0))

    def test_not_repaired(self):
        """No last frame, a changed reading byte, a damage that is no shift, two damaged bytes: skipped as before."""
        last = GOOD
        bad = bytearray(GOOD)
        bad[1] = 0x8B                                                 # 0x17 one bit late
        self.assertIsNone(frames.repair(bytes(bad), None))
        changed = bytearray(GOOD)
        changed[13] = 0x05                                            # a digit that changed ...
        changed[18] = frames._xor(changed[:18])
        hit = bytearray(changed)
        hit[13] = 0x82                                                # ... and was hit: not the last frame's byte
        self.assertIsNone(frames.repair(bytes(hit), last))
        noshift = bytearray(GOOD)
        noshift[2] = 0x7E                                             # 0x81 -> 0x7E is no late read
        self.assertIsNone(frames.repair(bytes(noshift), last))
        two = bytearray(GOOD)
        two[1], two[3] = 0x8B, 0x91
        self.assertIsNone(frames.repair(bytes(two), last))
        r = frames.Reassembler()
        r.feed(GOOD)
        r.feed(bytes(two))
        self.assertEqual(r.repaired, 0)
        self.assertGreater(r.dropped, 0)

