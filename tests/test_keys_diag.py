"""Remote key frames (codes of key/keys.s) and the readable diagnosis text."""
import unittest

from support import frames  # noqa: F401  (sets the import path)
from meter121 import diag, keys


class Keys(unittest.TestCase):
    def test_short_and_long_codes(self):
        # key/keys.s fn_08014AE6: 1 RANGE, 2 HOLD, 3 REL, 4 PEAK, 5 MODE, 6 MIN/MAX, 7 MEM, 8 SETUP; long = 0x80 + code
        for n, name in enumerate(('RANGE', 'HOLD', 'REL', 'PEAK', 'MODE', 'MINMAX', 'MEM', 'SETUP'), 1):
            self.assertEqual(keys.code(name), n)
            self.assertEqual(keys.code(name, long=True), 0x80 | n)
        self.assertEqual(keys.frame('REL'), b'\xF4' + b'0303')
        self.assertEqual(keys.frame('setup', True), b'\xF4' + b'8888')
        self.assertEqual(keys.frame('min/max'), b'\xF4' + b'0606')

    def test_frames_are_accepted_by_the_reassembler(self):
        r = frames.Reassembler()
        self.assertEqual(r.feed(keys.frame('MEM', True)), [(frames.KEY_ECHO, keys.frame('MEM', True))])

    def test_unknown_names(self):
        for bad in ('', 'POWER', 'REL2', None):
            with self.assertRaises(ValueError):
                keys.code(bad)


class Diag(unittest.TestCase):
    def test_readable_text(self):
        v = [2, 3 << 8 | 17, 5, 2 | 2 << 8, 0x0002, 1, 0, 0b10, 0x5, 12, 300, 0x10, 4, 0x0900, 0x0000, 7, 3, 9, 11, 1, 2]
        self.assertEqual(len(v), diag.BASE_COUNT)                     # a firmware before F-1.10
        t = diag.explain(v)
        self.assertNotIn('last write wait', t)
        t26 = diag.explain(v + [2, 61, 0x8000 | 0 << 8 | 1, 3, 1])  # F-1.10: wait 2 for 61 ticks, ACMD22 said 1 block
        self.assertEqual(len(v) + 5, diag.COUNT)
        self.assertIn("last write wait that ran out: wait 2 (the card's busy) after 61 ticks", t26)
        self.assertIn('last ACMD22 answer: SD error 0, 1 block(s) written; 3 late block(s) confirmed, 1 block(s) written again', t26)
        self.assertIn('2 failed card sessions in this transfer', t)
        self.assertIn('step write, FatFs result 17', t)
        self.assertIn('write: the end-of-write wait ran out of polls', t)
        self.assertIn("['DCRCFAIL']", t)
        self.assertIn('card status 0x00000900: state tran', t)
        self.assertIn('11 SCR reads since power-on, 1 of them with no word and 2 with one word', t)

    def test_short_lists_and_no_cmd13(self):
        v = [0, 0, 0, 0, 0, 0, 0]
        self.assertNotIn('CMD13', diag.explain(v))
        v = [0] * 16
        v[13] = v[14] = 0xFFFF
        self.assertIn('no CMD13 answer', diag.explain(v))


if __name__ == '__main__':
    unittest.main()
