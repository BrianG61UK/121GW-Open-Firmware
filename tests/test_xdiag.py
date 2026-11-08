"""Extended link diagnosis (firmware F-1.15, ble/xdiag.s): the frame F9, the damaged pieces, the link statistics, the
setting "Extended diagnosis" (key codes 0x93 / 0x94 / 0x95, never sent to older firmware) and the report's [link details].
The program's settings file is the test's own (AppCase patches app.config_path): nothing here touches the user's settings."""
import asyncio
import os
import struct
import time
import unittest

from support import FakeMeter, frames, mclock_frame, mclock_status, xdiag_frame
from test_app import AppCase, status_frame, wait
from meter121 import app as app_mod, link as link_mod, report, transfer

VALUES = [1000, 2, 1, 3, 0, 4, 5, 6, 598]


def split(stream, cut):
    r = frames.Reassembler()
    out = []
    for i in range(0, len(stream), cut):
        out += r.feed(stream[i:i + cut])
    return r, out


def status_bytes():
    f = bytearray(19)
    f[0] = 0xF2
    f[5] = 1
    f[18] = frames._xor(f[:18])
    return bytes(f)


class F9Frame(unittest.TestCase):
    def test_frame_layout_and_values(self):
        f = xdiag_frame(VALUES)
        self.assertEqual(len(f), 20)
        self.assertEqual(f[0], 0xF9)
        self.assertEqual(frames._xor(f), 0)                         # XOR of all 20 bytes
        self.assertEqual(f[1:3], struct.pack('<H', 1000))           # little-endian
        self.assertEqual(frames.xdiag_values(f), VALUES)
        self.assertEqual(frames.xdiag_values(xdiag_frame([0xFFFF] * 9)), [0xFFFF] * 9)

    def test_every_notification_size(self):
        f = xdiag_frame([0xF2F2, 0xF4F4, 0xB55B, 0xF8F8, 0xF9F9, 0xF6F6, 0xF7F7, 0, 1])    # start bytes of other frames inside
        for cut in (1, 2, 3, 7, 19, 20, 21, 244):
            r, out = split(f, cut)
            self.assertEqual(out, [(frames.XDIAG, f)], 'cut %d' % cut)
            self.assertEqual(r.dropped, 0)

    def test_wrong_xor_is_skipped_and_the_next_frame_found(self):
        bad = bytearray(xdiag_frame(VALUES))
        bad[19] ^= 0x01
        good = xdiag_frame([7] * 9)
        r, out = split(bytes(bad) + good, 5)
        self.assertEqual(out, [(frames.XDIAG, good)])
        self.assertGreater(r.dropped, 0)

    def test_the_other_frames_still_work(self):
        st = status_bytes()
        f4 = frames.key_frame(0x93)
        f6 = b'\xF6F-115'
        f6 += bytes([frames._xor(f6)])
        f7 = b'\xF7B-113'
        f7 += bytes([frames._xor(f7)])
        v = [26, 11, 5, 12, 30, 45]
        f8 = b'\xF8' + ''.join('%02X' % b for b in v + [frames._xor(v)]).encode()
        bft = b'\xB5\x5B\x82' + struct.pack('<H', 1) + b'\x03' + b'\x00\x00\x00'
        bft += struct.pack('<H', frames.crc16(bft[2:]))
        stream = st + f4 + f6 + f7 + f8 + bft + xdiag_frame(VALUES) + st
        kinds = [frames.STATUS, frames.KEY_ECHO, frames.VERSION, frames.BL_VERSION, frames.CLOCK_ECHO, frames.BFT,
                 frames.XDIAG, frames.STATUS]
        for cut in (1, 4, 20, 1000):
            r, out = split(stream, cut)
            self.assertEqual([k for k, _ in out], kinds, 'cut %d' % cut)
            self.assertEqual(r.dropped, 0)
            self.assertEqual(b''.join(f for _, f in out), stream)

    def test_requests(self):
        self.assertEqual(frames.XDIAG_ON_REQUEST, b'\xF4' + b'9393')
        self.assertEqual(frames.XDIAG_OFF_REQUEST, b'\xF4' + b'9494')
        self.assertEqual(frames.XDIAG_REQUEST, b'\xF4' + b'9595')
        self.assertEqual(len(frames.XDIAG_NAMES), 9)


class DamagedPieces(unittest.TestCase):
    def test_a_run_of_skipped_bytes_is_kept_when_a_frame_follows(self):
        r = frames.Reassembler()
        st = status_bytes()
        junk = bytes([0x00, 0x11, 0x22, 0x33])
        out = r.feed(st + junk + st)
        self.assertEqual(len(out), 2)
        self.assertEqual(r.damaged(), [(4, junk)])
        self.assertEqual(r.dropped, 4)

    def test_two_runs_are_two_pieces_and_the_run_in_progress_is_listed(self):
        r = frames.Reassembler()
        st = status_bytes()
        r.feed(b'\x01\x02' + st + b'\x03' + st + b'\x04\x05\x06')
        self.assertEqual(r.damaged(), [(2, b'\x01\x02'), (1, b'\x03'), (3, b'\x04\x05\x06')])

    def test_a_run_across_notifications_is_one_piece(self):
        r = frames.Reassembler()
        r.feed(b'\x01\x02')
        r.feed(b'\x03')
        r.feed(status_bytes())
        self.assertEqual(r.damaged(), [(3, b'\x01\x02\x03')])

    def test_a_partial_frame_start_that_turns_out_damaged_joins_the_run(self):
        r = frames.Reassembler()
        bad = bytearray(status_bytes())
        bad[10] ^= 0xFF                                           # damaged: the F2 and its 18 bytes are skipped one by one
        r.feed(b'\xAA' + bytes(bad[:10]))                         # a run, then a held F2
        r.feed(bytes(bad[10:]) + status_bytes())
        d = r.damaged()
        self.assertEqual(len(d), 1)
        self.assertEqual(d[0][0], 1 + 19)                         # the whole damaged frame and the byte before it

    def test_at_most_32_bytes_of_a_piece_and_20_pieces(self):
        r = frames.Reassembler()
        st = status_bytes()
        r.feed(bytes(range(0x30, 0x30 + 100)) + st)               # 100 bytes of text-like junk, no start bytes inside
        (n, data), = r.damaged()
        self.assertEqual((n, len(data)), (100, frames.DAMAGED_BYTES))
        self.assertEqual(data, bytes(range(0x30, 0x30 + 32)))
        for i in range(30):
            r.feed(bytes([0x40 + i]) + st)
        d = r.damaged()
        self.assertEqual(len(d), frames.DAMAGED_KEEP)
        self.assertEqual(d[-1], (1, bytes([0x40 + 29])))          # the newest is kept, the oldest dropped
        self.assertEqual(d[0], (1, bytes([0x40 + 10])))

    def test_pieces_outlive_one_reassembler(self):
        import collections
        shared = collections.deque(maxlen=frames.DAMAGED_KEEP)
        a = frames.Reassembler(shared)
        a.feed(b'\x01' + status_bytes())
        b = frames.Reassembler(shared)
        b.feed(b'\x02' + status_bytes())
        self.assertEqual(list(shared), [(1, b'\x01'), (1, b'\x02')])

    def test_hex_with_spaces(self):
        self.assertEqual(frames.hex_spaced(b'\xAA\xBB\x0C'), 'AA BB 0C')
        self.assertEqual(frames.hex_spaced(b''), '')


class LinkStatistics(unittest.TestCase):
    def test_notifications_sizes_and_gaps(self):
        s = link_mod.LinkStats()
        for size, t in ((20, 0.0), (20, 0.1), (21, 0.3), (64, 0.4), (65, 1.4), (244, 1.5), (300, 1.6)):
            s.notification(size, t)
        n = s.snapshot()
        self.assertEqual(n['notifications'], 7)
        self.assertEqual(n['sizes'], [2, 2, 2, 1])                # 1..20, 21..64, 65..244, larger
        self.assertAlmostEqual(n['gap_max'], 1.0)
        self.assertAlmostEqual(n['gap_median'], 0.1)              # gaps 0.1 0.2 0.1 1.0 0.1 0.1 -> nearest rank median
        self.assertAlmostEqual(n['gap_p95'], 1.0)

    def test_a_gap_never_spans_two_connections(self):
        s = link_mod.LinkStats()
        s.notification(20, 0.0)
        s.connected(247)
        s.notification(20, 100.0)
        self.assertIsNone(s.snapshot()['gap_max'])
        self.assertEqual(s.snapshot()['mtu'], 247)

    def test_empty(self):
        n = link_mod.LinkStats().snapshot()
        self.assertEqual((n['notifications'], n['gap_median'], n['write_median'], n['rssi'], n['mtu']), (0, None, None, [], None))

    def test_percentile(self):
        self.assertIsNone(link_mod.percentile([], 0.5))
        self.assertEqual(link_mod.percentile([5], 0.95), 5)
        self.assertEqual(link_mod.percentile(list(range(1, 101)), 0.95), 95)
        self.assertEqual(link_mod.percentile(list(range(1, 101)), 0.5), 50)

    def test_disconnects_and_rssi(self):
        s = link_mod.LinkStats()
        s.advertised(-71)
        s.connected(None)
        s.disconnect('the stack reported it', now=1000.0)
        s.advertised(None)
        n = s.snapshot()
        self.assertEqual(n['rssi'], [(1, -71), (2, None)])
        self.assertEqual((n['disconnect_count'], n['disconnects']), (1, [(1000.0, False, 'the stack reported it')]))

    def test_writes_are_timed_in_the_link(self):
        """MeterLink._send times the confirmation of a write with response, and counts a failed one."""
        class Client:
            def __init__(self):
                self.fail = False

            async def write_gatt_char(self, char, data, response):
                assert response is True
                await asyncio.sleep(0.05)
                if self.fail:
                    raise OSError('write refused')

        L = link_mod.MeterLink(lambda *a: None)
        L._client, L.state = Client(), 'connected'
        L.send(b'abc')
        L.send(b'def')
        n = L.stats.snapshot()
        self.assertEqual(n['writes'], 2)
        self.assertGreaterEqual(n['write_median'], 0.04)
        self.assertLess(n['write_max'], 1.0)
        L._client.fail = True
        with self.assertRaises(OSError):
            L.send(b'x')
        n = L.stats.snapshot()
        self.assertEqual((n['writes'], n['write_errors']), (2, 1))
        self.assertIn('write refused', L.stats.recent_write_error())
        L.state = 'idle'

    def test_a_backend_error_reaches_the_caller_as_oserror(self):
        """bleak raises its own BleakError ("disconnected") when the meter restarts under a write; the callers catch
        OSError, and an update thread that met BleakError ended without a word (notice stuck at "restarting")."""
        class BleakError(Exception):
            pass

        class Client:
            async def write_gatt_char(self, char, data, response):
                raise BleakError('disconnected')

        L = link_mod.MeterLink(lambda *a: None)
        L._client, L.state = Client(), 'connected'
        with self.assertRaises(OSError) as cm:
            L.send(b'x')
        self.assertIn('BleakError: disconnected', str(cm.exception))
        self.assertIn('BleakError: disconnected', L.stats.recent_write_error())
        L.state = 'idle'


class Setting(AppCase):
    def test_default_and_validation_and_persistence(self):
        self.assertIs(self.app.state()['prefs']['ext_diag'], False)
        self.assertIn('ext_diag', app_mod.PREF_DEFAULTS)
        for bad in ('yes', 1, 0, None, 'on'):
            with self.assertRaises(ValueError, msg=repr(bad)):
                self.app.command({'prefs_set': {'key': 'ext_diag', 'value': bad}})
        self.assertFalse(os.path.exists(app_mod.config_path()))     # nothing stored (and the user's own file untouched)
        self.app.command({'prefs_set': {'key': 'ext_diag', 'value': True}})
        self.assertTrue(app_mod.Companion(os.path.join(self.tmp, 'docs')).prefs()['ext_diag'])
        self.assertTrue(app_mod.config_path().startswith(self.tmp))
        self.app.command({'prefs_reset': True})
        self.assertIs(self.app.prefs()['ext_diag'], False)


class Switching(AppCase):
    """Key codes 0x93 / 0x94 are sent only with the setting on and only to firmware F-1.15 or newer."""
    def setUp(self):
        super().setUp()
        self.meter.fast_xdiag = True
        self.app._frame_t = time.time() + 3600                     # fresh status frames: the page Ld watcher stays quiet
        for name, value in (('XDIAG_WAIT', 0.2), ('VERSION_WAIT', 0.1), ('VERSION_RETRY', 0.1)):
            old = getattr(app_mod, name)
            setattr(app_mod, name, value)
            self.addCleanup(setattr, app_mod, name, old)
        self.app._check_release = lambda: None

    def keys(self):
        return [bytes(k) for k in self.meter.keys]

    def fw(self, version, kind='fast'):
        self.app.fw_kind, self.app.version, self.app.mode = kind, version, 'firmware'

    def test_connect_sends_0x93_after_the_questions(self):
        """The whole ask-version thread: 0x90, 0x92, then 0x93."""
        f6 = b'\xF6F-115'
        f6 += bytes([frames._xor(f6)])
        sent = []

        def meter_send(pkt):
            pkt = bytes(pkt)
            sent.append(pkt)
            self.meter.send(pkt)
            if pkt == frames.VERSION_REQUEST:
                self.meter._out(f6)
        self.app.link.send = meter_send
        self.app.settings['ext_diag'] = True
        self.app.fw_kind, self.app.version, self.app.mode = 'unknown', None, 'unknown'
        self.app._asked.set()
        self.assertTrue(wait(lambda: self.app.xdiag_on, 10), 'the diagnosis was not switched on')
        self.assertEqual(sent[0], frames.VERSION_REQUEST)
        self.assertEqual(sent.count(frames.XDIAG_ON_REQUEST), 1)
        on = sent.index(frames.XDIAG_ON_REQUEST)
        self.assertEqual(sent[1:on], [frames.BL_VERSION_REQUEST] * app_mod.BL_ASK_TRIES)    # after the questions, not before
        self.assertEqual(len(sent), on + 1)
        self.assertTrue(self.meter.xdiag_counting)
        self.assertTrue(self.app.state()['meter']['xdiag'])

    def test_switched_on_after_an_update(self):
        """The reconnection after an update asks its questions while the update still owns the link: the switch is
        refused then and sent once the update is done (GitHub issue 9: F-1.16 installed, the counting never started)."""
        self.app.settings['ext_diag'] = True

        def update_firmware():                            # the new firmware answers while the state is still 'sending'
            self.app.update['state'] = 'sending'
            self.fw('F-1.16')
            self.app._xdiag_connect()
            self.assertFalse(self.app.xdiag_on)
        self.app._update_firmware = update_firmware
        self.app.update.update(fw=('F-1.16', 'v1.1.6'), bl=None)
        self.app._run_update('firmware')
        self.assertEqual(self.app.update['state'], 'done')
        self.assertTrue(self.app.xdiag_on)
        self.assertEqual(self.keys(), [frames.XDIAG_ON_REQUEST])

    def test_connect_with_the_setting_off_sends_nothing(self):
        self.fw('F-1.15')
        self.app._xdiag_connect()
        self.assertEqual(self.keys(), [])
        self.assertFalse(self.app.xdiag_on)

    def test_older_firmware_gets_none_of_the_codes(self):
        self.app.settings['ext_diag'] = True
        for version, kind in (('F-1.14', 'fast'), ('F-1.09', 'fast'), ('F-0.99', 'fast'), (None, 'other')):
            self.fw(version, kind)
            self.app._xdiag_connect()
            self.assertFalse(self.app._xdiag_switch(True))
            self.assertFalse(self.app._xdiag_switch(False))
            r = self.app.xdiag_collect()
            self.assertEqual(r['state'], 'unsupported', version)
            self.app.command({'prefs_set': {'key': 'ext_diag', 'value': False}})    # changed while connected: nothing sent
            self.app.command({'prefs_set': {'key': 'ext_diag', 'value': True}})
            wait(lambda: False, 0.3)                              # let the setting's thread run
            self.assertEqual(self.keys(), [], '%s %s' % (kind, version))
        self.assertTrue(any('F-1.15 or newer needed' in t for _, t in self.app.events))

    def test_newer_firmware_is_supported(self):
        for version in ('F-1.15', 'F-1.16', 'F-1.20', 'F-2.00'):
            self.fw(version)
            self.assertTrue(self.app._xdiag_supported(), version)
        self.fw('F-1.15', 'other')
        self.assertFalse(self.app._xdiag_supported())

    def test_switch_on_and_off_while_connected(self):
        self.fw('F-1.15')
        self.app.command({'prefs_set': {'key': 'ext_diag', 'value': True}})
        self.assertTrue(wait(lambda: self.app.xdiag_on, 5))
        self.assertEqual(self.keys(), [frames.XDIAG_ON_REQUEST])
        self.assertTrue(self.meter.xdiag_counting)
        self.app.command({'prefs_set': {'key': 'ext_diag', 'value': False}})
        self.assertTrue(wait(lambda: not self.app.xdiag_on and not self.meter.xdiag_counting, 5))
        self.assertEqual(self.keys(), [frames.XDIAG_ON_REQUEST, frames.XDIAG_OFF_REQUEST])

    def test_switched_while_not_connected_sends_nothing(self):
        self.fw('F-1.15')
        self.app.link.state = 'idle'
        self.app.command({'prefs_set': {'key': 'ext_diag', 'value': True}})
        wait(lambda: False, 0.3)
        self.assertEqual(self.keys(), [])

    def test_a_lost_echo_is_tried_again_and_then_given_up(self):
        self.fw('F-1.15')
        sent = []
        self.app.link.send = lambda pkt: sent.append(bytes(pkt))
        self.assertFalse(self.app._xdiag_switch(True))
        self.assertEqual(sent, [frames.XDIAG_ON_REQUEST] * app_mod.XDIAG_TRIES)
        self.assertTrue(any('no echo' in t for _, t in self.app.events))

    def test_not_on_page_ld(self):
        self.fw('F-1.15')
        self.app._frame_t = 0.0
        self.go_desk()
        self.assertFalse(self.app._xdiag_switch(True))
        self.assertEqual(self.keys(), [])


class Collect(AppCase):
    """The counters for the report: the frame F9 (0x95), or STATUS 40..48 on page Ld."""
    def setUp(self):
        super().setUp()
        self.meter.fast_xdiag = True
        self.meter.diag = list(range(100, 121)) + [0] * 19 + self.meter.xdiag_values
        self.app._frame_t = time.time() + 3600                     # fresh status frames: the page Ld watcher stays quiet
        self.app.fw_kind, self.app.version, self.app.mode = 'fast', 'F-1.15', 'firmware'
        self.app.settings['ext_diag'] = True
        for name, value in (('XDIAG_WAIT', 0.2), ):
            old = getattr(app_mod, name)
            setattr(app_mod, name, value)
            self.addCleanup(setattr, app_mod, name, old)

    def test_frame_f9(self):
        self.app._xdiag_switch(True)
        r = self.app.xdiag_collect()
        self.assertEqual(r['state'], 'values')
        self.assertEqual(r['values'], self.meter.xdiag_values)
        self.assertEqual(r['source'], 'frame F9')
        self.assertTrue(r['counting'])
        self.assertEqual(self.meter.keys[-1], frames.XDIAG_REQUEST)

    def test_up_to_three_tries(self):
        self.app._xdiag_switch(True)
        self.meter.xdiag_lost = 2
        n = len(self.meter.keys)
        r = self.app.xdiag_collect()
        self.assertEqual(r['state'], 'values')
        self.assertEqual(len(self.meter.keys) - n, 3)
        self.meter.xdiag_lost = 3
        n = len(self.meter.keys)
        r = self.app.xdiag_collect()
        self.assertEqual(r['state'], 'error')
        self.assertIn('no answer to the counters request after 3 tries', r['text'])
        self.assertEqual(len(self.meter.keys) - n, 3)

    def test_counting_off_in_the_meter_gives_no_answer(self):
        r = self.app.xdiag_collect()                              # the meter was never told to count: only the echo comes
        self.assertEqual(r['state'], 'error')
        self.assertFalse(self.meter.xdiag_counting)

    def test_page_ld_reads_status_40_to_48(self):
        self.app._xdiag_switch(True)
        self.app._frame_t = 0.0
        self.go_desk()
        r = self.app.xdiag_collect()
        self.assertEqual((r['state'], r['values']), ('values', self.meter.xdiag_values))
        self.assertEqual(r['source'], 'page Ld STATUS 40..48')
        asked = [p[0] for t, p in self.meter.sent if t == transfer.T_STATUS]
        self.assertEqual(asked[-9:], list(range(40, 49)))
        self.assertNotIn(frames.XDIAG_REQUEST, [bytes(k) for k in self.meter.keys])    # no key frame on page Ld

    def test_page_ld_with_older_firmware_values_refused(self):
        self.app._xdiag_switch(True)
        self.app._frame_t = 0.0
        self.go_desk()
        self.meter.diag = self.meter.diag[:40]                    # STATUS 40 is refused (status 3)
        r = self.app.xdiag_collect()
        self.assertEqual(r['state'], 'error')

    def test_setting_off_and_unsupported(self):
        self.app.settings['ext_diag'] = False
        self.assertEqual(self.app.xdiag_collect()['state'], 'off')
        self.app.settings['ext_diag'] = True
        self.app.version = 'F-1.14'
        r = self.app.xdiag_collect()
        self.assertEqual(r['state'], 'unsupported')
        self.assertEqual(self.meter.keys, [])
        self.app.link.state = 'idle'
        self.assertEqual(self.app.xdiag_collect()['state'], 'error')


class LinkDetails(AppCase):
    """The report's section [link details]."""
    def setUp(self):
        super().setUp()
        self.app._frame_t = time.time() + 3600                     # fresh status frames: the page Ld watcher stays quiet

    def make_report(self):
        return report.build(self.app)

    @staticmethod
    def read(path):
        with open(path, encoding='utf-8') as f:
            return f.read()

    def section(self, text):
        i = text.index('[link details]')
        return text[i:text.index('\n\n', i)]

    def test_section_is_always_there(self):
        text = self.make_report()
        sec = self.section(text)
        for part in ('damaged pieces   none', 'notifications    0;', 'writes (with response)  0;', 'advertisement signal  not seen',
                     'MTU              not available', 'disconnects      0', 'status frames    not measured yet',
                     'meter counters   not read'):
            self.assertIn(part, sec)
        path = report.save(self.app, os.path.join(self.tmp, 'out'))     # saving reads the counters: the setting is off
        self.assertIn('meter counters   off (SETTINGS: Extended diagnosis)', self.section(self.read(path)))
        self.assertLess(text.index('[link]'), text.index('[link details]'))
        self.assertLess(text.index('[link details]'), text.index('[update]'))
        self.assertIn('ext_diag', text)

    def test_numbers_and_damaged_pieces(self):
        L = self.app.link
        for size, t in ((20, 0.0), (20, 0.1), (100, 0.3)):
            L.stats.notification(size, t)
        L.stats.write(0.12)
        L.stats.write(0.3)
        L.stats.advertised(-67)
        L.stats.connected(247)
        L.stats.disconnect('the stack reported it', now=0.0)
        L.reasm.feed(b'\x01\x02' + status_bytes() + bytes(range(0x30, 0x30 + 40)) + status_bytes())
        for i in range(3):
            self.app._frame(frames.STATUS, status_bytes(), 100.0 + i * 0.5)
        self.app.settings_st['items'] = [{'code': 'bt', 'name': 'Bluetooth frame rate', 'value': 0, 'text': '2 per second'}]
        sec = self.section(self.make_report())
        self.assertIn('the last 2 runs of skipped bytes', sec)
        self.assertIn('    2 bytes: 01 02', sec)
        self.assertIn('   40 bytes: 30 31 32', sec)
        self.assertIn(' ...', sec)                                # 40 bytes, only 32 are shown
        self.assertIn('notifications    3; sizes 1..20: 2, 21..64: 0, 65..244: 1; gap median 100 ms, 95 % 200 ms, max 200 ms', sec)
        self.assertIn('writes (with response)  2; confirmed after median 120 ms, max 300 ms', sec)
        self.assertIn('connection 1: -67 dBm', sec)
        self.assertIn('MTU              247 bytes (bleak client mtu_size)', sec)
        self.assertIn('disconnects      1:', sec)
        self.assertIn('the stack reported it', sec)
        self.assertIn('status frames    2.00 per second measured (3 frames in 1.0 s of this connection); meter setting bt: 2 per second', sec)

    def test_hex_dumps_are_not_taken_for_addresses_or_ids(self):
        run = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]) + bytes.fromhex('0123456789ABCDEF0123456789ABCDEF0123')
        self.app.link.reasm.feed(run + status_bytes())
        text = self.make_report()
        self.assertIn('AA BB CC DD EE FF 01 23 45 67 89 AB CD EF', text)
        self.assertNotIn('<address>', text)
        self.assertNotIn('<id>', text)
        self.assertNotIn('<path>', text)
        # the same bytes written with ':' or '-' ARE an address to anonymise() (so the report must keep using spaces)
        self.assertEqual(report.anonymise('AA:BB:CC:DD:EE:FF'), '<address>')
        self.assertEqual(report.anonymise(frames.hex_spaced(run[:6])), 'AA BB CC DD EE FF')
        self.assertEqual(report.anonymise(frames.hex_spaced(bytes(range(32)))), frames.hex_spaced(bytes(range(32))))

    def test_still_anonymised_with_the_new_section(self):
        self.app.link.device = ('6C6DCEDE-1C8B-ECC5-EA3B-4067CF1EB479', '121GW')
        self.app.link.stats.disconnect('lost 6C6DCEDE-1C8B-ECC5-EA3B-4067CF1EB479 AA:BB:CC:DD:EE:FF', now=0.0)
        text = self.make_report()
        self.assertNotIn('6C6DCEDE', text)
        self.assertNotIn('AA:BB:CC:DD:EE:FF', text)
        self.assertIn('<id>', text)
        self.assertIn('<address>', text)

    def test_counters_with_the_setting_on(self):
        self.meter.fast_xdiag = True
        self.app.fw_kind, self.app.version, self.app.mode = 'fast', 'F-1.15', 'firmware'
        self.app.settings['ext_diag'] = True
        old = app_mod.XDIAG_WAIT
        app_mod.XDIAG_WAIT = 0.2
        self.addCleanup(setattr, app_mod, 'XDIAG_WAIT', old)
        self.app._xdiag_switch(True)
        path = report.save(self.app, os.path.join(self.tmp, 'out'))
        text = self.read(path)
        sec = self.section(text)
        self.assertIn('meter counters   frame F9; the meter was told to count', sec)
        want = ['%d' % v for v in self.meter.xdiag_values]
        want[8] = '598 (= 5.98 V)'
        for name, v in zip(frames.XDIAG_NAMES, want):
            self.assertIn('  %-44s %s' % (name, v), sec)
        self.assertIn('overruns (ORE)', sec)
        self.assertIn('answers not queued (transmit queue full)', sec)

    def test_counters_unsupported_and_error_are_said(self):
        self.app.settings['ext_diag'] = True
        self.app.fw_kind, self.app.version, self.app.mode = 'fast', 'F-1.14', 'firmware'
        path = report.save(self.app, os.path.join(self.tmp, 'out'))
        sec = self.section(self.read(path))
        self.assertIn('meter counters   not supported by this firmware (F-1.14; F-1.15 or newer needed)', sec)
        self.assertEqual(self.meter.keys, [])

    def test_counters_on_page_ld(self):
        self.meter.fast_xdiag = True
        self.meter.diag = list(range(100, 121)) + [0] * 19 + self.meter.xdiag_values
        self.app.fw_kind, self.app.version, self.app.mode = 'fast', 'F-1.15', 'firmware'
        self.app.settings['ext_diag'] = True
        self.app._frame_t = 0.0
        self.go_desk()
        path = report.save(self.app, os.path.join(self.tmp, 'out'))
        sec = self.section(self.read(path))
        self.assertIn('meter counters   page Ld STATUS 40..48', sec)
        self.assertIn('  %-44s 1000' % frames.XDIAG_NAMES[0], sec)


if __name__ == '__main__':
    unittest.main()


class MeterClock(AppCase):
    """The clock measurement of firmware F-1.17 (sys/msical.s): key code 0x96 answered with FA, or STATUS 49..55 on page
    Ld; asked only with the setting on and only from F-1.17."""
    def setUp(self):
        super().setUp()
        self.meter.fast_xdiag = self.meter.fast_mclock = True
        self.meter.diag = (list(range(100, 121)) + [0] * 19 + self.meter.xdiag_values
                           + mclock_status(self.meter.mclock))
        self.app._frame_t = time.time() + 3600
        self.app.fw_kind, self.app.version, self.app.mode = 'fast', 'F-1.17', 'firmware'
        self.app.settings['ext_diag'] = True
        old = app_mod.XDIAG_WAIT
        app_mod.XDIAG_WAIT = 0.2
        self.addCleanup(setattr, app_mod, 'XDIAG_WAIT', old)

    def test_frame_layout(self):
        f = mclock_frame(self.meter.mclock)
        self.assertEqual((len(f), f[0], frames._xor(f)), (20, 0xFA, 0))
        r, out = split(f + status_bytes(), 3)
        self.assertEqual([k for k, _ in out], [frames.MCLOCK, frames.STATUS])
        self.assertEqual(r.dropped, 0)
        v = frames.mclock_values(f)
        self.assertEqual(v, self.meter.mclock)
        st = frames.mclock_from_status(mclock_status(self.meter.mclock))
        self.assertEqual(st, {k: v for k, v in self.meter.mclock.items() if not k.startswith('cal_')})
        self.assertEqual(frames.MCLOCK_REQUEST, b'\xF4' + b'9696')

    def test_frame_fa_in_the_report(self):
        self.app._xdiag_switch(True)
        r = self.app.xdiag_collect()
        c = r['clock']
        self.assertEqual(c['source'], 'frame FA')
        self.assertEqual({k: c[k] for k in self.meter.mclock}, self.meter.mclock)
        self.assertIn(frames.MCLOCK_REQUEST, [bytes(k) for k in self.meter.keys])
        text = report.build(self.app)
        self.assertIn('meter clock      frame FA', text)
        self.assertIn('RC clock as found        4187000 Hz (-0.174 % from 4194304)', text)
        self.assertIn('RC clock in use          4194100 Hz (-0.005 %), trim -3, 6 measurements', text)
        self.assertIn('Bluetooth serial baud    19239 (BRR 218; +0.20 % from 19200)', text)
        self.assertIn('MSICAL                   0x9D after the measurement, 0x9D now', text)

    def test_answered_without_counting(self):
        r = self.app.xdiag_collect()                              # counting off: no F9, but FA comes
        self.assertEqual(r['state'], 'error')
        self.assertEqual(r['clock']['hz'], self.meter.mclock['hz'])

    def test_page_ld_reads_status_49_to_55(self):
        self.app._frame_t = 0.0
        self.go_desk()
        r = self.app.xdiag_collect()
        self.assertEqual(r['clock']['source'], 'page Ld STATUS 49..55')
        self.assertEqual({k: r['clock'][k] for k in self.meter.mclock if not k.startswith('cal_')},
                         {k: v for k, v in self.meter.mclock.items() if not k.startswith('cal_')})
        self.assertNotIn(frames.MCLOCK_REQUEST, [bytes(k) for k in self.meter.keys])

    def test_older_firmware_is_not_asked(self):
        self.app.version = 'F-1.16'
        r = self.app.xdiag_collect()
        self.assertNotIn('clock', r)
        self.assertNotIn(frames.MCLOCK_REQUEST, [bytes(k) for k in self.meter.keys])

    def test_no_answer(self):
        self.meter.fast_mclock = False
        r = self.app.xdiag_collect()
        self.assertIn('no answer to the clock request after 3 tries', r['clock']['text'])

    def test_lines_for_failures(self):
        c = dict(self.meter.mclock, status=6, hz=0, hz0=4488000)
        lines = frames.mclock_lines(c)
        self.assertIn('more than 6 % off', lines[0])
        self.assertTrue(any('RC clock as found' in s and '+7.0' in s for s in lines), lines)
        self.assertFalse(any('in use' in s for s in lines))
        c = dict(self.meter.mclock, status=4, hz=0, hz0=0)
        lines = frames.mclock_lines(c)
        self.assertIn('crystal did not start', lines[0])
        self.assertTrue(any('BRR 218 (clock not measured)' in s for s in lines), lines)


class LeaveLd(AppCase):
    """The page Ld request LEAVE (type 0x19, firmware F-1.17): the program takes the meter out of Ld-bt."""
    def setUp(self):
        super().setUp()
        self.meter.fast_leave = True
        self.app.fw_kind, self.app.version, self.app.mode = 'fast', 'F-1.17', 'firmware'
        self.app._frame_t = 0.0
        self.go_desk()

    def test_leave(self):
        self.assertTrue(self.app.state()['can_leave_ld'])
        r = self.app.command({'leave_ld': True})
        self.assertEqual(r, {'ok': True})
        self.assertFalse(self.meter.on_ld)
        self.assertIn((transfer.T_LEAVE, b''), self.meter.sent)
        self.assertTrue(any('page Ld left by the program' in t for _, t in self.app.events))

    def test_leave_stops_a_hanging_card_operation(self):
        """GitHub issue 9: a card list that keeps retrying held the link, and Leave only said "the link is busy: list"."""
        self.meter.drop_next = 1000                     # no card answer arrives: the list keeps retrying
        r = self.app.command({'card_list': True})
        self.assertTrue(wait(lambda: self.app.card_st['busy']), 'the list did not start')
        t0 = time.time()
        self.assertEqual(self.app.command({'leave_ld': True}), {'ok': True})
        self.assertLess(time.time() - t0, app_mod.LINK_WAIT + app_mod.LEAVE_CANCEL_WAIT)
        self.assertFalse(self.meter.on_ld)
        self.assertTrue(any('running card operation' in t for _, t in self.app.events))
        self.assertTrue(wait(lambda: self.app.state()['card']['done_job'] >= r['job']), 'the list did not end')

    def test_older_firmware(self):
        self.app.version = 'F-1.16'
        self.assertFalse(self.app.state()['can_leave_ld'])
        with self.assertRaises(RuntimeError) as cm:
            self.app.command({'leave_ld': True})
        self.assertIn('press SETUP on the meter', str(cm.exception))
        self.assertTrue(self.meter.on_ld)
        self.assertNotIn(transfer.T_LEAVE, [t for t, _ in self.meter.sent])


class NotFoundText(unittest.TestCase):
    """GitHub issue 23: on Windows a meter added in Settings > Bluetooth & devices is held connected by Windows and does
    not advertise; after WINDOWS_HINT_AFTER searches without it the status says so."""
    def test_windows_hint_after_two_misses(self):
        self.assertEqual(link_mod.not_found_text(1, 'win32'), link_mod.NOT_FOUND)
        self.assertEqual(link_mod.not_found_text(2, 'win32'), link_mod.NOT_FOUND_WINDOWS)
        self.assertIn('Settings > Bluetooth & devices', link_mod.NOT_FOUND_WINDOWS)

    def test_no_hint_elsewhere(self):
        for platform in ('darwin', 'linux'):
            self.assertEqual(link_mod.not_found_text(5, platform), link_mod.NOT_FOUND)


class CloseUnsubscribesFirst(unittest.TestCase):
    """GitHub issue 23: on Windows the link stayed up after Disconnect; the notifications are unsubscribed first."""
    def run_close(self, client):
        asyncio.run(link_mod.MeterLink._close(client))
        return client.calls

    def make(self, connected=True, hang=False, fail=False):
        class Client:
            def __init__(self):
                self.calls, self.is_connected = [], connected

            async def stop_notify(self, char):
                self.calls.append('stop_notify')
                if hang:
                    await asyncio.sleep(60)
                if fail:
                    raise OSError('not subscribed')

            async def disconnect(self):
                self.calls.append('disconnect')
        return Client()

    def test_unsubscribe_then_disconnect(self):
        self.assertEqual(self.run_close(self.make()), ['stop_notify', 'disconnect'])

    def test_a_hanging_or_failing_unsubscribe_still_disconnects(self):
        old = link_mod.STOP_NOTIFY_WAIT
        link_mod.STOP_NOTIFY_WAIT = 0.1
        self.addCleanup(setattr, link_mod, 'STOP_NOTIFY_WAIT', old)
        self.assertEqual(self.run_close(self.make(hang=True)), ['stop_notify', 'disconnect'])
        self.assertEqual(self.run_close(self.make(fail=True)), ['stop_notify', 'disconnect'])

    def test_a_gone_link_is_only_disconnected(self):
        self.assertEqual(self.run_close(self.make(connected=False)), ['disconnect'])
