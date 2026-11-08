"""IMP-56 (GitHub issue 23): the companion's heartbeat byte, its check that the meter is alive, the offline window and
the clean disconnect."""
import time
import unittest

from support import frames
from test_app import AppCase, app_mod


class Heartbeat(AppCase):
    def setUp(self):
        super().setUp()
        self.raw = []
        send = self.app.link.send

        def tap(pkt, timeout=5.0):
            self.raw.append(bytes(pkt))
            self.app.link.last_write = time.time()
            return send(pkt)
        self.app.link.send = tap
        self.app.link.last_write = 0.0
        self.app.link.rx_bytes = 100
        self.app.link.want = True
        self.app.link.device = ('AA:BB:CC:DD:EE:FF', '121GW')
        old = app_mod.XDIAG_WAIT
        app_mod.XDIAG_WAIT = 0.1
        self.addCleanup(setattr, app_mod, 'XDIAG_WAIT', old)
        self.connects = []
        self.app.link.connect = lambda addr=None: self.connects.append(addr)

    def test_the_byte_goes_out_when_nothing_else_was_written(self):
        t = time.time()
        self.app._hb_step(t)
        self.assertEqual(self.raw, [b'\xFE'])
        self.app._hb_step(t + 1)                       # written a moment ago: not again
        self.assertEqual(self.raw, [b'\xFE'])

    def test_quiet_on_page_ld_and_in_the_bootloader(self):
        self.app.desk = True
        self.app._hb_step(time.time())
        self.app.desk, self.app.mode = False, 'bootloader'
        self.app._hb_step(time.time() + 10)
        self.assertEqual(self.raw, [])

    def test_kept_during_the_waits_of_an_update(self):
        # review 2026-11-08: the download and the wait for page Ld can exceed the meter's 15 s
        for st in ('downloading', 'waiting_ld'):
            self.raw.clear()
            self.app.link.last_write = 0.0
            self.app.update['state'] = st
            self.app._hb_step(time.time())
            self.assertEqual(self.raw, [b'\xFE'], st)
        self.app.update['state'] = 'none'

    def test_a_silent_meter_is_asked_and_then_reconnected(self):
        self.app._alive = (time.time() - 60, self.app.link.rx_bytes)   # nothing for a minute
        self.meter.echo_keys = False
        self.app._hb_step(time.time())
        self.assertEqual(self.connects, ['AA:BB:CC:DD:EE:FF'])
        self.assertEqual(self.app.hb['dead'], 1)
        self.assertTrue(any('did not answer' in t for _, t in self.app.events))

    def test_a_silent_meter_that_answers_is_left_alone(self):
        self.app._alive = (time.time() - 60, self.app.link.rx_bytes)
        self.app._hb_step(time.time())                  # the fake meter echoes the version question
        self.assertEqual(self.connects, [])
        self.assertIn(frames.key_frame(0x90), self.raw)

    def test_offline_after_a_minute_down(self):
        L = self.app.link
        L.state = 'lost'
        t = time.time()
        self.app._hb_step(t)
        self.assertFalse(self.app.offline)
        self.app._hb_step(t + app_mod.OFFLINE_AFTER + 1)
        self.assertTrue(self.app.offline)
        self.assertTrue(self.app.state()['offline'])
        L.state = 'connected'
        self.app._hb_step(t + app_mod.OFFLINE_AFTER + 2)
        self.assertFalse(self.app.offline)

    def test_clean_disconnect_switches_the_watch_off_first(self):
        closed = []
        self.app.link.disconnect = lambda: closed.append(True)
        self.app.disconnect_clean()
        self.assertEqual(self.raw, [b'\xFD'])
        self.assertEqual(closed, [True])
        self.app._hb_step(time.time())                   # quiet afterwards
        self.assertEqual(self.raw, [b'\xFD'])

    def test_a_dead_link_does_not_hold_up_the_disconnect(self):
        def dead(pkt, timeout=5.0):
            raise OSError('write failed')
        self.app.link.send = dead
        closed = []
        self.app.link.disconnect = lambda: closed.append(True)
        self.app.disconnect_clean()
        self.assertEqual(closed, [True])


if __name__ == '__main__':
    unittest.main()
