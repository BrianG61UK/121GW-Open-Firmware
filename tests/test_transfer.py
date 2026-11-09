"""Transfers to the meter (transfer.py) with a fake meter that loses or damages chosen answers: the file still arrives
complete, and the statistics count what the time went on (GitHub issue 9)."""
import random
import struct
import unittest
import zlib

from meter121 import transfer


class FakeReceiver:
    """The meter's side of both protocols: accepts packets in order; a repeated one is answered again, one ahead of
    the expected is answered 'not the expected packet' with the expected number (ble/bft.s, bootloader bl_ble.s).
    lose: {(type, seq): n} answers that do not arrive; damage: {(type, seq): n} packets that arrive damaged (status 1)."""

    def __init__(self, sender, lose=None, damage=None):
        self.sender = sender
        self.lose = dict(lose or {})
        self.damage = dict(damage or {})
        self.expected = 0
        self.data = bytearray()
        self.start = None                              # payload of the START packet
        sender.send = self.send

    def answer(self, seq, status, nxt):
        self.sender.answers.put((seq, status, nxt))

    def send(self, pkt):
        rtype, seq, n = struct.unpack_from('<BHB', pkt, 2)
        key = (rtype, seq)
        if self.damage.get(key):
            self.damage[key] -= 1
            return self.answer(seq, 1, self.expected)
        lost = False
        if self.lose.get(key):
            self.lose[key] -= 1
            lost = True
        if rtype == transfer.T_START:
            self.start = pkt[6:6 + n]
        if rtype == transfer.T_DATA:
            if seq == self.expected:
                self.data += pkt[6:6 + n]
                self.expected += 1
            elif seq > self.expected:
                return None if lost else self.answer(seq, 2, self.expected)
        if not lost:
            self.answer(seq, 0, self.expected)


class Stats(unittest.TestCase):
    def setUp(self):
        saved = (transfer.TIMEOUT_DATA, transfer.TIMEOUT_END)
        transfer.TIMEOUT_DATA = transfer.TIMEOUT_END = 0.2
        self.addCleanup(lambda: setattr(transfer, 'TIMEOUT_DATA', saved[0]) or setattr(transfer, 'TIMEOUT_END', saved[1]))
        self.image = bytes(range(256)) * 10                     # 2560 bytes: 12 DATA packets
        self.n = -(-len(self.image) // transfer.MAX_PAYLOAD)

    def test_clean_transfer(self):
        s = transfer.Sender(None)
        m = FakeReceiver(s)
        s.run(self.image)
        self.assertEqual(bytes(m.data), self.image)
        st = s.stats
        self.assertEqual((st['packets'], st['sends'], st['timeouts'], st['crc_wrong'], st['resync']), (self.n + 2, self.n + 2, 0, 0, 0))
        self.assertIn('none sent again', transfer.stats_text(st))

    def test_lost_and_damaged_answers_are_counted(self):
        s = transfer.Sender(None)
        m = FakeReceiver(s, lose={(transfer.T_DATA, 3): 1, (transfer.T_DATA, 7): 1}, damage={(transfer.T_DATA, 5): 1})
        s.run(self.image)
        self.assertEqual(bytes(m.data), self.image)
        st = s.stats
        self.assertEqual((st['sends'], st['timeouts'], st['crc_wrong']), (self.n + 2 + 3, 2, 1))
        self.assertAlmostEqual(st['waited_s'], 0.4)
        text = transfer.stats_text(st, dropped=5)
        for part in ('3 sent again', '2 answers missing', '1 packets arrived damaged', '5 received bytes damaged'):
            self.assertIn(part, text)

    def test_bootloader_protocol_lost_answer_confirmed_by_the_next(self):
        """The bootloader takes DATA only in order: the answer to packet 5 confirms packet 4, whose answer was lost.
        Before this the sender stopped with "packet 5: accepted"."""
        s = transfer.BootSender(None)
        m = FakeReceiver(s, lose={(transfer.T_DATA, 4): 1})
        s.run(self.image)
        self.assertEqual(bytes(m.data), self.image)
        st = s.stats
        self.assertEqual((st['packets'], st['sends'], st['timeouts']), (self.n + 2, self.n + 2, 0))
        self.assertGreaterEqual(st['seconds'], 0.0)              # Windows' clock steps are about 15 ms: an instant run is 0.0

    def test_bootloader_protocol_lost_last_answer(self):
        s = transfer.BootSender(None)
        m = FakeReceiver(s, lose={(transfer.T_DATA, self.n - 1): 1})       # nothing after it can confirm it
        s.run(self.image)
        self.assertEqual(bytes(m.data), self.image)
        st = s.stats
        self.assertEqual(st['timeouts'], 1)
        self.assertEqual(st['sends'], self.n + 3)
        self.assertEqual(st['stray'], 0)



def unpack_stream(stream):
    """The file of a packed stream as the meter unpacks it (ble/bft.s bft_zdata, bl_ble.s bl_zdata): every piece must
    unpack to exactly its raw length and end exactly at its packed length."""
    out, i = bytearray(), 0
    while i < len(stream):
        raw, size = struct.unpack_from('<HH', stream, i)
        if size & transfer.RAW_PIECE:
            assert size == transfer.RAW_PIECE | raw and 1 <= raw <= transfer.PIECE
            out += stream[i + 4:i + 4 + raw]
            i += 4 + raw
            continue
        assert 1 <= raw <= transfer.PIECE and 1 <= size <= transfer.PIECE_PACK_MAX, (raw, size)
        assert stream[i + 4] & 7 == transfer.FINAL_DYNAMIC
        d = zlib.decompressobj(-15)
        piece = d.decompress(stream[i + 4:i + 4 + size])
        assert d.eof and not d.unused_data and len(piece) == raw
        out += piece
        i += 4 + size
    return bytes(out)


class Packed(unittest.TestCase):
    """IMP-63: START kind | 0x80, the DATA packets carry the packed stream; size and CRC-32 those of the file."""
    def setUp(self):
        saved = (transfer.TIMEOUT_DATA, transfer.TIMEOUT_END)
        transfer.TIMEOUT_DATA = transfer.TIMEOUT_END = 0.2
        self.addCleanup(lambda: setattr(transfer, 'TIMEOUT_DATA', saved[0]) or setattr(transfer, 'TIMEOUT_END', saved[1]))
        r = random.Random(63)
        self.image = b''.join(bytes([r.randrange(8)] * r.randrange(1, 20)) for _ in range(2000))   # compressible

    def check_start(self, m, kind):
        size, crc = struct.unpack_from('<II', m.start)
        self.assertEqual((size, crc, m.start[8]), (len(self.image), zlib.crc32(self.image), kind))

    def test_page_ld(self):
        s = transfer.Sender(None)
        m = FakeReceiver(s, lose={(transfer.T_DATA, 2): 1})
        s.run(self.image, packed=True)
        self.check_start(m, transfer.PACKED)
        self.assertEqual(unpack_stream(bytes(m.data)), self.image)
        self.assertLess(s.stats['sent'], len(self.image) * 0.8)
        self.assertIn('packed: %d bytes sent for %d' % (s.stats['sent'], len(self.image)), transfer.stats_text(s.stats))

    def test_install_file_packed_keeps_its_kind(self):
        s = transfer.Sender(None)
        m = FakeReceiver(s)
        s.run(self.image, kind=transfer.KIND_INSTALL, packed=True)
        self.check_start(m, transfer.KIND_INSTALL | transfer.PACKED)

    def test_bootloader_two_in_flight(self):
        s = transfer.BootSender(None)
        m = FakeReceiver(s, lose={(transfer.T_DATA, 4): 1})
        s.run(self.image, transfer.KIND_BOOTLOADER, 0x00010105, packed=True)
        self.check_start(m, transfer.KIND_BOOTLOADER | transfer.PACKED)
        self.assertEqual(struct.unpack_from('<I', m.start, 9)[0], 0x00010105)
        self.assertEqual(unpack_stream(bytes(m.data)), self.image)

    def test_plain_unchanged(self):
        s = transfer.Sender(None)
        m = FakeReceiver(s)
        s.run(self.image)
        self.assertEqual(len(m.start), 8)
        self.assertEqual(bytes(m.data), self.image)

    def test_pieces_within_the_meter_limits(self):
        r = random.Random(1)
        noise = bytes(r.randrange(256) for _ in range(3 * transfer.PIECE + 100))
        for data in (noise, bytes(5000), b'x'):
            stream = transfer.pack_stream(data)
            self.assertEqual(unpack_stream(stream), data)
        first = struct.unpack_from('<HH', transfer.pack_stream(noise), 0)
        self.assertEqual(first, (transfer.PIECE, transfer.RAW_PIECE | transfer.PIECE))     # incompressible: raw


if __name__ == '__main__':
    unittest.main()
