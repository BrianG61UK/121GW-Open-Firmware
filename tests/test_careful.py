"""Careful mode for meters with the old BLE112 Bluetooth module (firmware F-1.19, IMP-50; GitHub issues 9 and 14):
chosen by the negotiated MTU (23 = BLE112, 247 = BGM220S), the card requests with small answers; link 2 (firmware
F-1.31, IMP-62, GitHub issue 30): key codes 0xAA + pace and 0xA8 at the connection, the pace control.  The program's settings file is the test's
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

    def test_piece_statistics_in_the_report(self):
        self.addCleanup(card.LAST_CAREFUL.clear)
        card.LAST_CAREFUL.clear()
        card.LAST_CAREFUL.update(pieces=10, again=3, sizes={32: 6, 64: 4})
        self.assertIn('careful pieces   last card read: 10 pieces, 3 sent again; pieces by size: 32 bytes 6, 64 bytes 4',
                      report.build(self.app))

    def test_not_for_the_newer_module(self):
        self.app.link.stats.mtu = 247
        self.app.version = 'F-1.31'
        self.app._link2_connect()
        self.assertFalse(self.app.l2c['on'])
        self.assertNotIn(frames.key_frame(0xA8), [bytes(k) for k in self.meter.keys])
        self.assertIn('careful mode     off (MTU 247', report.build(self.app))


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


class Link2Connect(AppCase):
    """IMP-62: on a BLE112 link with F-1.31 the companion sets the pace and switches link 2 on; older firmware gets the
    note to update; the pace follows lost blocks (down 2, up 1 after 3 clean windows) and is saved per meter."""
    def setUp(self):
        super().setUp()
        self.meter.careful_fw = self.meter.adapt_fw = self.meter.l2_fw = True
        self.app._frame_t = time.time() + 3600
        self.app.version, self.app.fw_kind, self.app.mode = 'F-1.31', 'fast', 'firmware'
        self.app.link.stats.mtu = 23
        self.app.link.state = 'connected'
        self.app.link.device = ('AA:BB:CC:DD:EE:FF', '121GW')
        self.app.settings.pop('link_paces', None)
        old = app_mod.XDIAG_WAIT
        app_mod.XDIAG_WAIT = 0.2
        self.addCleanup(setattr, app_mod, 'XDIAG_WAIT', old)
        self.t = 1000.0

    def codes(self):
        return [frames._pair(bytes(k), 1) for k in self.meter.keys]

    def window(self, lost=0, blocks=50, readings=0):
        L = self.app.link
        self.app._pace_step(self.t)
        L.l2.stats['lost'] += lost
        L.l2.stats['blocks'] += blocks
        self.app._st_n += readings
        self.t += app_mod.PACE_WINDOW
        self.app._pace_step(self.t)

    def test_switched_on_with_the_start_pace(self):
        self.app._link2_connect()
        self.assertTrue(self.app.l2c['on'])
        self.assertEqual(self.codes()[-2:], [0xAA + app_mod.PACE_START, 0xA8])
        self.assertEqual(self.meter.l2_pace, app_mod.PACE_START)
        self.assertIn('link 2           on (F-1.31)', report.build(self.app))

    def test_older_firmware_gets_the_note(self):
        self.app.version = 'F-1.30'
        self.app._link2_connect()
        self.assertFalse(self.app.l2c['on'])
        self.assertNotIn(0xA8, self.codes())
        self.assertIn('update the firmware', self.app.link2_note())

    def test_pace_down_on_loss_up_after_clean_windows_saved(self):
        self.app._link2_connect()
        self.window(lost=2)
        self.assertEqual(self.app.l2c['pace'], app_mod.PACE_START - app_mod.PACE_DOWN)
        self.assertEqual(self.app.settings['link_paces'], {'AA:BB:CC:DD:EE:FF': app_mod.PACE_START - app_mod.PACE_DOWN})
        for _ in range(app_mod.PACE_UP_CLEAN):
            self.window()
        self.assertEqual(self.app.l2c['pace'], app_mod.PACE_START - app_mod.PACE_DOWN + 1)
        self.assertEqual(self.meter.l2_pace, self.app.l2c['pace'])

    def test_saved_pace_used_and_cleared_after_an_update(self):
        self.app.settings['link_paces'] = {'AA:BB:CC:DD:EE:FF': 5}
        self.app.settings['link_paces_by'] = report.app_version()
        self.app._link2_connect()
        self.assertEqual(self.app.l2c['pace'], 5)
        self.app.settings['link_paces_by'] = 'companion-v1.2.37'
        self.app.l2c = {'on': False}
        self.app._link2_connect()
        self.assertEqual(self.app.l2c['pace'], app_mod.PACE_START)

    def test_a_stalled_link_saves_a_slower_pace(self):
        self.app._link2_connect()
        self.app._pace_fail('the link stalled')
        self.assertEqual(self.app.settings['link_paces'], {'AA:BB:CC:DD:EE:FF': app_mod.PACE_START - app_mod.PACE_DOWN})

    def test_asked_again_when_the_meter_left_link_2(self):
        self.app._link2_connect()
        n = self.codes().count(0xA8)
        self.window(blocks=0, readings=20)                 # readings, but no block: plain frames again
        self.assertEqual(self.codes().count(0xA8), n + 1)
        self.assertTrue(any('link 2 set again' in e for _, e in self.app.events))

    def test_paused_on_page_ld(self):
        self.app._link2_connect()
        self.app.desk = True
        self.window(lost=5)
        self.assertEqual(self.app.l2c['pace'], app_mod.PACE_START)

