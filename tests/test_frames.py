"""Reassembly of the answers of type 0x82 (card and settings requests) from notifications of any length."""
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
