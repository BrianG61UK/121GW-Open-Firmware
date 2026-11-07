"""Careful mode for meters with the old BLE112 Bluetooth module (firmware F-1.19, IMP-50; GitHub issues 9 and 14):
chosen by the negotiated MTU (23 = BLE112, 247 = BGM220S), key code 0x97 at the connection, every status frame taken once
although the meter sends it twice, and the card requests with small answers.  The program's settings file is the test's
own (AppCase patches app.config_path)."""
import time
import unittest

from support import FakeMeter, frames, make_client, sample_files
from test_app import AppCase, status_frame, wait
from meter121 import app as app_mod, card, report


class CardPieces(unittest.TestCase):
    def setUp(self):
        old = dict(card.TIMEOUTS)
        for k in card.TIMEOUTS:
            card.TIMEOUTS[k] = 0.05
        self.addCleanup(card.TIMEOUTS.update, old)

    def meter(self):
        m = FakeMeter(sample_files())
        m.careful_fw = True
        m.damage_over = 100                            # a long answer never arrives intact, a short one does
        return m

    def test_plain_download_fails_on_a_damaging_link(self):
        m = self.meter()
        big = max(m.files, key=lambda n: len(m.files[n][0]))
        self.assertGreater(len(m.files[big][0]), card.CHUNK)
        with self.assertRaises(card.CardError):
            card.Card(make_client(m)).read_file(big, len(m.files[big][0]), lambda b: None)

    def test_careful_list_and_download_get_through(self):
        m = self.meter()
        c = card.Card(make_client(m), careful=True)
        names = [f['name'] for f in c.list()]
        self.assertEqual(sorted(names), sorted(n for n in m.files if card.Card.is_file(
            {'attr': 0x20, 'cut': False, 'size': 0, 'name': n})))
        lists = [p for t, p in m.sent if t == card.T_LIST]
        self.assertTrue(lists and all(len(p) == 3 and p[2] == card.CAREFUL_LIST_MAX for p in lists))
        big = max(m.files, key=lambda n: len(m.files[n][0]))
        got = []
        c.read_file(big, len(m.files[big][0]), got.append)
        self.assertEqual(b''.join(got), m.files[big][0])
        chunks = [p for t, p in m.sent if t == card.T_CHUNK]
        self.assertTrue(chunks and all(len(p) == 3 and p[2] == card.CAREFUL_CHUNK for p in chunks))

    def test_request_forms(self):
        self.assertEqual(card.list_request(5), b'\x05\x00')
        self.assertEqual(card.list_request(5, 4), b'\x05\x00\x04')
        self.assertEqual(card.chunk_request(2), b'\x02\x00')
        self.assertEqual(card.chunk_request(2, 48), b'\x02\x00\x30')


class CopyFrames(unittest.TestCase):
    """The reassembler takes an F3 copy only where a copy can be: right after its intact F2 frame, or right after the
    19 bytes of a damaged F2 frame."""
    @staticmethod
    def frame(v):
        f = bytearray(19)
        f[0], f[5], f[9] = 0xF2, 1, v
        f[18] = frames._xor(f[:18])
        return bytes(f)

    @staticmethod
    def copy(f):
        c = bytearray(f)
        c[0] = 0xF3
        c[18] ^= 0xF2 ^ 0xF3
        return bytes(c)

    def test_copy_after_its_frame(self):
        f = self.frame(7)
        out = frames.Reassembler().feed(f + self.copy(f) + f)
        self.assertEqual([k for k, _ in out], [frames.STATUS, frames.STATUS_COPY, frames.STATUS])

    def test_copy_after_its_damaged_frame(self):
        f = self.frame(7)
        bad = bytearray(f)
        bad[9] ^= 0x40                                   # one byte damaged: the frame is skipped, its copy is taken
        out = frames.Reassembler().feed(bytes(bad) + self.copy(f))
        self.assertEqual(out, [(frames.STATUS_COPY, self.copy(f))])

    def test_a_check_byte_of_f3_does_not_eat_the_next_frame(self):
        r = frames.Reassembler()
        f = self.frame(0)                                # its check byte is 0xF3
        self.assertEqual(f[18], 0xF3)
        bad = bytearray(f)
        bad[10] ^= 0xFF
        out = r.feed(b'\xAA' + bytes(bad) + f)
        self.assertEqual(out, [(frames.STATUS, f)])     # the next frame is found, no false copy
        self.assertEqual(r.damaged()[0][0], 1 + 19)


class CarefulConnect(AppCase):
    def setUp(self):
        super().setUp()
        self.meter.careful_fw = True
        self.app._frame_t = time.time() + 3600
        self.app.version = 'F-1.19'
        for name, value in (('XDIAG_WAIT', 0.2),):
            old = getattr(app_mod, name)
            setattr(app_mod, name, value)
            self.addCleanup(setattr, app_mod, name, old)

    def test_chosen_by_mtu_and_version(self):
        self.app.link.stats.mtu = 23
        self.assertTrue(self.app.careful_wanted())
        self.app.link.stats.mtu = 247                    # the newer BGM220S module
        self.assertFalse(self.app.careful_wanted())
        self.app.link.stats.mtu, self.app.version = 23, 'F-1.18'
        self.assertFalse(self.app.careful_wanted())      # older firmware does not know the requests
        self.app.link.stats.mtu = None                   # a backend that does not report the MTU
        self.app.version = 'F-1.19'
        self.assertFalse(self.app.careful_wanted())

    def test_switched_on_at_the_connection(self):
        self.app.link.stats.mtu = 23
        self.app._careful_connect()
        self.assertTrue(self.app.careful_on)
        self.assertTrue(self.meter.dup_frames)
        self.assertIn(frames.key_frame(0x97), [bytes(k) for k in self.meter.keys])
        self.assertTrue(any('careful mode on' in t for _, t in self.app.events))
        self.assertIn('careful mode     on:', report.build(self.app))

    def test_not_for_the_newer_module(self):
        self.app.link.stats.mtu = 247
        self.app._careful_connect()
        self.assertFalse(self.app.careful_on)
        self.assertNotIn(frames.key_frame(0x97), [bytes(k) for k in self.meter.keys])
        self.assertIn('careful mode     off (MTU 247', report.build(self.app))

    def test_the_copy_is_used_only_when_its_frame_was_lost(self):
        f = status_frame()
        copy = bytearray(f)
        copy[0] = 0xF3
        copy[18] ^= 0xF2 ^ 0xF3
        copy = bytes(copy)
        self.assertEqual(frames.Reassembler().feed(f + copy), [(frames.STATUS, f), (frames.STATUS_COPY, copy)])
        t = time.time()
        before = self.app._st_n
        self.app._frame(frames.STATUS, f, t)
        self.app._frame(frames.STATUS_COPY, copy, t + 0.011)      # its frame arrived: the copy is dropped
        self.assertEqual(self.app._st_n - before, 1)
        self.app._frame(frames.STATUS_COPY, copy, t + 0.511)      # the next frame was damaged: its copy is the reading
        self.assertEqual(self.app._st_n - before, 2)
        self.app._frame(frames.STATUS, f, t + 1.0)                # steady readings: two equal F2 frames are two readings
        self.app._frame(frames.STATUS, f, t + 1.03)
        self.assertEqual(self.app._st_n - before, 4)
        self.assertEqual(frames.copy_as_status(copy), f)
