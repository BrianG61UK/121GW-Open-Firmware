"""Careful mode for meters with the old BLE112 Bluetooth module (firmware F-1.19, IMP-50; GitHub issues 9 and 14):
chosen by the negotiated MTU (23 = BLE112, 247 = BGM220S), key code 0x97 at the connection, every status frame taken once
although the meter sends it twice, and the card requests with small answers.  The program's settings file is the test's
own (AppCase patches app.config_path)."""
import threading
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
        for name, value in (('CAREFUL_WAIT_MIN', 0.02), ('CAREFUL_WAIT_START', 0.05)):
            self.addCleanup(setattr, card, name, getattr(card, name))
            setattr(card, name, value)

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
        self.assertTrue(lists and lists[0][2] == card.CAREFUL_LIST_MAX and all(len(p) == 3 and p[2] in (4, 2, 1) for p in lists))
        big = max(m.files, key=lambda n: len(m.files[n][0]))
        got = []
        c.read_file(big, len(m.files[big][0]), got.append)
        self.assertEqual(b''.join(got), m.files[big][0])
        chunks = [p for t, p in m.sent if t == card.T_CHUNK]
        self.assertTrue(chunks and all(len(p) == 3 and p[2] in card.CAREFUL_SIZES for p in chunks))
        self.assertGreater(card.LAST_CAREFUL['again'], 0)              # 128-byte answers never arrive (damage_over 100)
        self.assertIn(64, card.LAST_CAREFUL['sizes'])                   # and the size came down to one that does

    def test_adaptive_pieces_on_random_damage(self):
        """Per-byte damage as on Excali-bur's link (about a quarter of the bytes in damaged answers): the file arrives
        intact, the size settles below the largest, and a lost piece costs the short wait, not the 5 s timeout."""
        m = FakeMeter(sample_files())
        m.careful_fw = True
        m.damage_rate = 0.004
        c = card.Card(make_client(m), careful=True)
        big = max(m.files, key=lambda n: len(m.files[n][0]))
        got = []
        old = dict(card.TIMEOUTS)
        card.TIMEOUTS[card.T_CHUNK] = 5.0
        self.addCleanup(card.TIMEOUTS.update, old)
        t0 = time.monotonic()
        c.read_file(big, len(m.files[big][0]), got.append)
        self.assertEqual(b''.join(got), m.files[big][0])
        st = card.LAST_CAREFUL
        self.assertGreater(st['again'], 0)
        self.assertLess(time.monotonic() - t0, 5.0 * st['again'])      # the waits were shorter than the timeout
        sizes = [p[2] for t, p in m.sent if t == card.T_CHUNK]
        self.assertGreater(len(set(sizes)), 1)                          # the size moved

    def test_sizes_change_only_at_aligned_offsets(self):
        """Every CHUNK idx(2) len(1) asks for bytes idx*len .. that follow on the bytes already received."""
        m = FakeMeter(sample_files())
        m.careful_fw = True
        m.damage_rate = 0.006
        c = card.Card(make_client(m), careful=True)
        big = max(m.files, key=lambda n: len(m.files[n][0]))
        got = []
        c.read_file(big, len(m.files[big][0]), got.append)
        self.assertEqual(b''.join(got), m.files[big][0])

    def test_list_pages_shrink_with_long_names(self):
        """GitHub issue 9: four entries with long names (the folders a Mac writes on a card) fill a whole answer that a
        damaging link never delivers; the pages shrink until they arrive, and the list is complete."""
        files = sample_files()
        for i in range(6):
            files['.Spotlight-V100-folder-with-a-long-name-%d.txt' % i] = (b'x', files['cal.bin'][1], files['cal.bin'][2])
        m = FakeMeter(files)
        m.careful_fw = True
        m.damage_over = 130                            # an answer above 130 data bytes never arrives intact
        names = [e['name'] for e in card.Card(make_client(m), careful=True).list_entries()]
        self.assertEqual(sorted(names), sorted(files))
        sizes = [p[2] for t, p in m.sent if t == card.T_LIST]
        self.assertEqual(sizes[0], card.CAREFUL_LIST_MAX)
        self.assertLess(min(sizes), card.CAREFUL_LIST_MAX)              # the page size came down

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

    def test_switched_on_at_the_connection_with_readings_once(self):
        # GitHub issue 30: the second copy of every reading did not help (link tests on two meters): the meter is told
        # 0x98 (readings once; also ends a doubling an older companion left on), the card answers stay small
        self.app.link.stats.mtu = 23
        self.meter.dup_frames = True                     # left on by an older companion
        self.app._careful_connect()
        self.assertFalse(self.app.careful_on)
        self.assertFalse(self.meter.dup_frames)
        self.assertIn(frames.key_frame(0x98), [bytes(k) for k in self.meter.keys])
        self.assertNotIn(frames.key_frame(0x97), [bytes(k) for k in self.meter.keys])
        self.assertTrue(any('careful mode on' in t for _, t in self.app.events))
        self.assertIn('careful mode     on: small card answers, readings once', report.build(self.app))

    def test_piece_statistics_in_the_report(self):
        self.addCleanup(card.LAST_CAREFUL.clear)
        card.LAST_CAREFUL.clear()
        card.LAST_CAREFUL.update(pieces=10, again=3, sizes={32: 6, 64: 4})
        self.assertIn('careful pieces   last card read: 10 pieces, 3 sent again; pieces by size: 32 bytes 6, 64 bytes 4',
                      report.build(self.app))

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


class KeptLinkRestart(AppCase):
    """GitHub issue 21: with the older BLE112 module the link survives the meter's restart into update mode (it dropped
    only when the bootloader gave up after 30 s).  The companion asks on the same connection instead of waiting for a
    drop; a link that drops (BGM220S) still takes the reconnection path."""
    def setUp(self):
        super().setUp()
        old = app_mod.RESTART_POLL
        app_mod.RESTART_POLL = 0.05
        self.addCleanup(setattr, app_mod, 'RESTART_POLL', old)
        self.sent = []

    def test_update_mode_found_on_the_kept_link(self):
        answers = iter([None, None, (1, 1, 3)])
        self.app._boot_probe = lambda: next(answers, (1, 1, 3))
        self.app.link.send = self.sent.append
        t0 = time.time()
        self.app._enter_update_mode()
        self.assertLess(time.time() - t0, 5.0)
        self.assertEqual((self.app.mode, self.app.bl), ('bootloader', 'B-1.13'))
        self.assertEqual(self.sent, [frames.UPDATE_MODE_REQUEST])
        self.assertTrue(any('probe on the kept link' in t for _, t in self.app.events))

    def test_new_firmware_found_on_the_kept_link(self):
        self.app.mode, self.app.version = 'bootloader', 'F-1.18'
        calls = []

        def send(data):
            calls.append(bytes(data))
            if bytes(data) == bytes(frames.VERSION_REQUEST) and len(calls) >= 3:     # the restart takes a while
                self.app._ver = 'F-1.19'
            if bytes(data) == bytes(frames.BL_VERSION_REQUEST):
                self.app._blver = 'B-1.13'
        self.app.link.send = send
        old = app_mod.VERSION_WAIT
        app_mod.VERSION_WAIT = 0.05
        self.addCleanup(setattr, app_mod, 'VERSION_WAIT', old)
        self.app._wait_restart(lambda: self.app.mode == 'firmware' and self.app.version == 'F-1.19', 'failed', 'x',
                               timeout=5.0, poll=self.app._version_kept_link)
        self.assertEqual((self.app.mode, self.app.version, self.app.bl), ('firmware', 'F-1.19', 'B-1.13'))

    def test_a_write_failing_while_the_meter_restarts_does_not_stop_the_wait(self):
        # the owner's update 2026-11-07 21:07:52: the version question on the dying connection failed (BleakError,
        # now OSError from the link); the wait goes on and ends when the reconnection has found the new firmware
        self.app.mode, self.app.version = 'bootloader', 'F-1.22'

        def send(data):
            raise OSError('write failed: BleakError: disconnected')
        self.app.link.send = send

        def come_back():
            time.sleep(0.2)
            self.app.link.state = 'lost'
            time.sleep(0.2)
            self.app.link.state = 'connected'
            self.app.version, self.app.mode = 'F-1.23', 'firmware'   # what _ask_version finds after the reconnection
        threading.Thread(target=come_back, daemon=True).start()
        self.app._wait_restart(lambda: self.app.mode == 'firmware' and self.app.version == 'F-1.23', 'failed', 'x',
                               timeout=5.0, poll=self.app._version_kept_link)
        self.assertEqual((self.app.mode, self.app.version), ('firmware', 'F-1.23'))

    def test_an_unexpected_error_ends_the_update_with_its_message(self):
        def boom():
            raise KeyError('a bug')
        self.app._update_firmware = boom
        self.app._run_update('firmware')
        self.assertEqual(self.app.update['state'], 'error')
        self.assertIn('KeyError', self.app.update['message'])

    def test_a_dropped_link_still_reconnects(self):
        self.app._boot_probe = lambda: None              # no answer on the old connection: it is going away
        self.app.link.send = self.sent.append

        def drop_and_come_back():
            time.sleep(0.2)
            self.app.link.state = 'lost'
            time.sleep(0.2)
            self.app.link.state = 'connected'
            self.app.bl, self.app.mode = 'B-1.13', 'bootloader'      # what _ask_version finds after the reconnection
        threading.Thread(target=drop_and_come_back, daemon=True).start()
        self.app._enter_update_mode()
        self.assertEqual(self.app.mode, 'bootloader')


class LinkTest(AppCase):
    """The link test (GitHub issue 30): the doubled status frames on, off, on, off, and careful mode back afterwards."""
    def setUp(self):
        super().setUp()
        self.meter.careful_fw = True
        self.app._frame_t = time.time() + 3600
        self.app.version, self.app.fw_kind, self.app.mode = 'F-1.19', 'fast', 'firmware'
        self.app.link.stats.mtu = 23
        for name, value in (('XDIAG_WAIT', 0.2), ('LTEST_PHASE', 0.05), ('LTEST_SETTLE', 0.01)):
            old = getattr(app_mod, name)
            setattr(app_mod, name, value)
            self.addCleanup(setattr, app_mod, name, old)

    def wait_end(self):
        end = time.time() + 10
        while time.time() < end and self.app.ltest.get('state') == 'running':
            time.sleep(0.02)
        return self.app.ltest

    def test_four_phases_then_careful_mode_as_wanted(self):
        self.app.command({'link_test': True})
        t = self.wait_end()
        self.assertEqual(t['state'], 'done', t)
        self.assertEqual([r['doubled'] for r in t['results']], [True, False, True, False])
        codes = [frames._pair(bytes(k), 1) for k in self.meter.keys]
        self.assertEqual(codes[-5:], [0x97, 0x98, 0x97, 0x98, 0x98])   # the last one: readings once again (issue 30)
        self.assertFalse(self.meter.dup_frames or self.app.careful_on)
        self.assertIn('doubled on:', t['summary'])
        self.assertIn('link test        careful mode', report.build(self.app))

    def test_the_newer_module_ends_with_the_doubling_off(self):
        self.app.link.stats.mtu = 247
        self.app.command({'link_test': True})
        self.assertEqual(self.wait_end()['state'], 'done')
        self.assertEqual(frames._pair(bytes(self.meter.keys[-1]), 1), 0x98)
        self.assertFalse(self.meter.dup_frames or self.app.careful_on)

    def test_no_echo_stops_and_says_why(self):
        self.meter.echo_keys = False
        self.app.command({'link_test': True})
        t = self.wait_end()
        self.assertEqual(t['state'], 'error')
        self.assertIn('did not echo', t['error'])

    def test_link_note_for_a_ble112_sending_too_fast(self):
        a = self.app
        a.link.state = 'connected'
        a.settings_st = {'items': [{'code': 'bt', 'value': 3}]}          # 20 per second
        self.assertIn('sends 20 a second', a.link_hint())
        self.assertIn('link note', report.build(a))
        a.settings_st = {'items': [{'code': 'bt', 'value': 1}]}          # 4 per second: fits
        self.assertIsNone(a.link_hint())
        a.settings_st = {'items': []}                                    # not read: the measured readings decide
        a._st_n, a._st_first, a._st_last = 41, 100.0, 105.0              # 8 a second
        self.assertIn('sends 8.0 a second', a.link_hint())
        a._st_n, a._st_first, a._st_last = 21, 100.0, 110.0              # 2 a second
        self.assertIsNone(a.link_hint())
        a.link.stats.mtu = 247                                           # the newer module: no note
        a.settings_st = {'items': [{'code': 'bt', 'value': 3}]}
        self.assertIsNone(a.link_hint())

    def test_refused_without_the_firmware_or_on_page_ld(self):
        self.app.version = 'F-1.18'
        with self.assertRaises(RuntimeError):
            self.app.command({'link_test': True})
        self.app.version, self.app.desk = 'F-1.19', True
        with self.assertRaises(RuntimeError):
            self.app.command({'link_test': True})


class AutoRate(AppCase):
    """IMP-55 (GitHub issue 30): on a BLE112 meter with F-1.25 the reading rate follows the damage of the link."""
    def setUp(self):
        super().setUp()
        self.meter.careful_fw = self.meter.adapt_fw = True
        self.app._frame_t = time.time() + 3600
        self.app.version, self.app.fw_kind, self.app.mode = 'F-1.25', 'fast', 'firmware'
        self.app.link.stats.mtu = 23
        self.app.link.state = 'connected'
        old = app_mod.XDIAG_WAIT
        app_mod.XDIAG_WAIT = 0.2
        self.addCleanup(setattr, app_mod, 'XDIAG_WAIT', old)
        self.t = 1000.0

    def window(self, nbytes, damaged):
        """One judgement window: the link counters advance, the controller looks after RATE_WINDOW seconds."""
        L = self.app.link
        self.app._rate_step(self.t)                       # opens the window if none
        L.rx_bytes += nbytes
        L.rx_dropped += damaged
        self.t += app_mod.RATE_WINDOW
        self.app._rate_step(self.t)

    def codes(self):
        return [frames._pair(bytes(k), 1) for k in self.meter.keys if 0x99 <= frames._pair(bytes(k), 1) <= 0x9C]

    def test_starts_at_2_a_second_and_steps_down_on_damage(self):
        self.app._careful_connect()
        self.assertEqual((self.app.arate['code'], self.meter.rate_code), (0, 0))   # the lowest rate first
        self.assertIn('reading rate     2 a second', report.build(self.app))
        for _ in range(app_mod.RATE_UP_CLEAN):
            self.window(380, 0)                            # a clean minute at 2 a second
        self.assertEqual(self.app.arate['code'], 1)
        self.window(760, 19)                               # one lost reading at 4 a second (2.5 %)
        self.assertEqual((self.app.arate['code'], self.meter.rate_code), (0, 0))

    def test_steps_up_to_4_at_most(self):
        """The BLE112 carries about 150 bytes/s: 4 a second is the highest rate tried (RATE_CAREFUL_MAX, IMP-60)."""
        self.app._careful_connect()
        for _ in range(4 * app_mod.RATE_UP_CLEAN):
            self.window(380, 0)
        self.assertEqual(self.app.arate['code'], 1)       # 4 a second after a clean minute, never 10
        self.assertEqual(self.codes(), [0x99, 0x9A])

    def test_a_rate_failing_right_after_the_step_up_becomes_the_ceiling(self):
        self.app._careful_connect()
        for _ in range(app_mod.RATE_UP_CLEAN):
            self.window(380, 0)
        self.assertEqual(self.app.arate['code'], 1)
        self.window(760, 40)                               # damage right after the step up
        self.assertEqual((self.app.arate['code'], self.app.arate['ceiling']), (0, 0))
        for _ in range(3 * app_mod.RATE_UP_CLEAN):
            self.window(380, 0)
        self.assertEqual(self.app.arate['code'], 0)       # no going back to the rate that failed
        self.assertEqual(self.codes(), [0x99, 0x9A, 0x99])

    def test_never_above_the_saved_rate(self):
        self.app._careful_connect()
        self.app.settings_st = {'items': [{'code': 'bt', 'value': 1}]}   # the user saved 4 a second
        for _ in range(4 * app_mod.RATE_UP_CLEAN):
            self.window(380, 0)
        self.assertEqual(self.app.arate['code'], 1)

    def test_paused_on_page_ld(self):
        self.app._careful_connect()
        self.app.desk = True
        self.window(380, 200)
        self.assertEqual(self.app.arate['code'], 0)

    def test_older_firmware_gets_no_rate_codes_but_the_note(self):
        self.app.version = 'F-1.24'
        self.app._careful_connect()
        self.assertIsNone(self.app.arate['code'])
        self.assertEqual(self.codes(), [])
        self.app.settings_st = {'items': [{'code': 'bt', 'value': 3}]}
        self.assertIn('sends 20 a second', self.app.link_hint())

    def test_a_meter_that_left_the_set_rate_gets_it_again(self):
        # Mike's report 2026-11-08: the companion set 2 a second, the meter then sent about 13 (its rate was reset on
        # the meter); far more bytes than the set rate sends -> the rate is set again
        self.app._careful_connect()
        self.meter.rate_code = None                        # the meter forgot the link rate
        self.window(2500, 0)                               # 2 a second sends about 380 bytes in 10 s
        self.assertEqual((self.app.arate['code'], self.meter.rate_code, self.app.arate['resets']), (0, 0, 1))
        self.assertTrue(any('set again' in t for _, t in self.app.events))
        self.window(380, 0)                                # back at the rate: no second reset
        self.assertEqual(self.app.arate['resets'], 1)


class ErrorCorrection(AutoRate):
    """IMP-60 (GitHub issue 30): on a BLE112 meter with F-1.29 the companion asks for status frames with three repair bytes
    (key code 0x9D), asks again when the meter has left it, and reports the corrected readings."""
    def setUp(self):
        super().setUp()
        self.meter.fec_fw = True
        self.app.version = 'F-1.29'

    def test_switched_on_with_f129(self):
        self.app._careful_connect()
        self.assertTrue(self.app.fec_on and self.meter.fec_on)
        self.assertIn('error correction on (F-1.29)', report.build(self.app))

    def test_not_with_older_firmware(self):
        self.app.version = 'F-1.28'
        self.app._careful_connect()
        self.assertFalse(self.app.fec_on or self.meter.fec_on)

    def test_asked_again_when_the_meter_sends_plain_frames(self):
        self.app._careful_connect()
        r = self.app.link.reasm
        self.window(380, 0)
        self.meter.fec_on = False                          # the meter restarted: F2 frames again
        r.plain_frames += 20
        self.window(380, 0)
        self.assertTrue(self.meter.fec_on)
        self.assertTrue(any('error correction set again' in e for _, e in self.app.events))


class RateSearch(AutoRate):
    """IMP-61: with error correction and F-1.30 the companion starts at 7 a second (or the rate saved for this meter),
    steps down when a window loses readings, and saves the rate after three windows in which every reading arrived."""
    def setUp(self):
        super().setUp()
        self.meter.fec_fw = True
        self.app.version = 'F-1.30'
        self.app.link.device = ('AA:BB:CC:DD:EE:FF', '121GW')
        self.app.settings.pop('link_rates', None)

    def window(self, readings, damaged=0):
        """One window of RATE_WINDOW seconds in which `readings` status frames arrived and `damaged` bytes were lost."""
        L = self.app.link
        self.app._rate_step(self.t)
        L.reasm.fec_frames += readings
        L.rx_bytes += 21 * readings
        L.rx_dropped += damaged
        self.t += app_mod.RATE_WINDOW
        self.app._rate_step(self.t)

    def per_s(self):
        return self.app.rate_per_s()

    def test_first_try_7_then_found_and_saved(self):
        self.app._careful_connect()
        self.assertEqual((self.per_s(), self.meter.rate_code, self.app.arate['found']), (7, 6, False))
        for _ in range(app_mod.PROBE_GOOD):
            self.window(71)
        self.assertTrue(self.app.arate['found'])
        self.assertEqual(self.app.settings['link_rates'], {'AA:BB:CC:DD:EE:FF': 7})
        self.assertIn('found for this meter and saved', report.build(self.app))

    def test_lost_readings_step_down_until_every_reading_arrives(self):
        self.app._careful_connect()
        self.window(50)                                    # 7 a second: only 50 of 71 readings (the module's buffer overflowed)
        self.assertEqual((self.per_s(), self.meter.rate_code), (6, 5))
        self.window(40, damaged=21)                        # 6 a second: a reading lost beyond repair
        self.assertEqual(self.per_s(), 5)
        for _ in range(app_mod.PROBE_GOOD):
            self.window(50)
        self.assertEqual(self.app.settings['link_rates'], {'AA:BB:CC:DD:EE:FF': 5})

    def test_the_saved_rate_is_used_at_the_next_connection(self):
        self.app.settings['link_rates'] = {'AA:BB:CC:DD:EE:FF': 6}
        self.app.settings['link_rates_by'] = report.app_version()
        self.app._careful_connect()
        self.assertEqual((self.per_s(), self.meter.rate_code, self.app.arate['found']), (6, 5, True))

    def test_a_found_rate_that_fails_later_is_replaced(self):
        self.app.settings['link_rates'] = {'AA:BB:CC:DD:EE:FF': 6}
        self.app.settings['link_rates_by'] = report.app_version()
        self.app._careful_connect()
        self.window(59)
        self.window(30)                                    # the computer got busier: readings lost
        self.assertEqual((self.per_s(), self.app.arate['found']), (5, False))
        for _ in range(app_mod.PROBE_GOOD):
            self.window(50)
        self.assertEqual(self.app.settings['link_rates'], {'AA:BB:CC:DD:EE:FF': 5})

    # the AutoRate tests describe the controller of F-1.25..F-1.29; with F-1.30 the search above replaces it
    test_starts_at_2_a_second_and_steps_down_on_damage = None
    test_steps_up_to_4_at_most = None
    test_a_rate_failing_right_after_the_step_up_becomes_the_ceiling = None
    test_never_above_the_saved_rate = None
    test_paused_on_page_ld = None
    test_a_meter_that_left_the_set_rate_gets_it_again = None

    def test_a_failure_saves_the_lower_rate_at_once(self):
        self.app._careful_connect()
        self.window(50)                                    # 7 a second fails in the first window
        self.assertEqual(self.app.settings['link_rates'], {'AA:BB:CC:DD:EE:FF': 6})
        self.assertFalse(self.app.arate['found'])

    def test_a_stalled_link_counts_against_the_rate(self):
        self.app.settings['link_rates'] = {'AA:BB:CC:DD:EE:FF': 7}
        self.app.settings['link_rates_by'] = report.app_version()
        self.app._careful_connect()
        self.app._probe_fail('the link stalled')
        self.assertEqual(self.app.settings['link_rates'], {'AA:BB:CC:DD:EE:FF': 6})
        self.assertTrue(any('the link stalled' in e for _, e in self.app.events))

    def test_rates_saved_by_another_version_are_measured_again(self):
        self.app.settings['link_rates'] = {'AA:BB:CC:DD:EE:FF': 5}
        self.app.settings['link_rates_by'] = 'companion-v1.2.36'
        self.app._careful_connect()
        self.assertEqual((self.per_s(), self.app.arate['found']), (7, False))   # the first try again
        self.window(50)
        self.assertEqual(self.app.settings['link_rates_by'], report.app_version())
        self.assertEqual(self.app.settings['link_rates'], {'AA:BB:CC:DD:EE:FF': 6})

