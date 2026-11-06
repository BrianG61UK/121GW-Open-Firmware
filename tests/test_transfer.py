"""Transfers to the meter (transfer.py) with a fake meter that loses or damages chosen answers: the file still arrives
complete, and the statistics count what the time went on (GitHub issue 9)."""
import struct
import unittest

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
        self.assertGreater(st['seconds'], 0)

    def test_bootloader_protocol_lost_last_answer(self):
        s = transfer.BootSender(None)
        m = FakeReceiver(s, lose={(transfer.T_DATA, self.n - 1): 1})       # nothing after it can confirm it
        s.run(self.image)
        self.assertEqual(bytes(m.data), self.image)
        st = s.stats
        self.assertEqual(st['timeouts'], 1)
        self.assertEqual(st['sends'], self.n + 3)
        self.assertEqual(st['stray'], 0)


if __name__ == '__main__':
    unittest.main()
