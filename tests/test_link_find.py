"""Connecting as soon as the meter is heard (meter121/link.py _find, _pause; GitHub issue 23: a fixed 6 s scan made the
connection come about 5 s after the meter's advertisement, and the bootloader's update mode waits only 30 s).

bleak's BleakScanner and BleakClient are replaced by fakes (link.py imports them inside its functions): advertisements
are played at set times; the tests check that the search ends at the first matching advertisement, that other services,
other meters (when one is chosen) and BlueZ's cached devices do not end it, that every meter heard is listed, that
BleakClient gets the device object (so bleak does not scan again), the pauses, and that no held-by-the-system check runs
while the program waits for the update mode.  The real Bluetooth backends are not covered here.
"""
import asyncio
import time
import unittest
from unittest import mock

from support import card  # noqa: F401  (sets the import path)
import bleak
from meter121 import link as link_mod

OTHER = '0000180f-0000-1000-8000-00805f9b34fb'


class Dev:
    def __init__(self, address, name='121GW'):
        self.address, self.name = address, name


class Adv:
    def __init__(self, service=link_mod.SERVICE, rssi=-60, local_name='121GW'):
        self.service_uuids, self.rssi, self.local_name = [service.upper()], rssi, local_name


class FakeScanner:
    """Plays SCRIPT = [(seconds after the start, Dev, Adv)] to the detection callback."""
    SCRIPT = []
    FAIL = None
    runs = []

    def __init__(self, detection_callback=None, **kw):
        self.cb = detection_callback
        self.kw = kw

    async def __aenter__(self):
        if FakeScanner.FAIL:
            raise FakeScanner.FAIL
        self.t0 = time.monotonic()
        self.tasks = [asyncio.ensure_future(self._play(t, d, a)) for t, d, a in FakeScanner.SCRIPT]
        FakeScanner.runs.append({'start': self.t0, 'kw': self.kw})
        return self

    async def _play(self, t, d, a):
        await asyncio.sleep(t)
        self.cb(d, a)

    async def __aexit__(self, *exc):
        for k in self.tasks:
            k.cancel()
        FakeScanner.runs[-1]['stop'] = time.monotonic()
        return False


class FakeClient:
    made = []

    def __init__(self, target, disconnected_callback=None):
        FakeClient.made.append(target)

    async def connect(self):
        raise OSError('the fake does not connect')

    async def disconnect(self):
        pass


class Find(unittest.TestCase):
    def setUp(self):
        FakeScanner.SCRIPT, FakeScanner.FAIL, FakeScanner.runs = [], None, []
        FakeClient.made = []
        for name, value in (('BleakScanner', FakeScanner), ('BleakClient', FakeClient)):
            p = mock.patch.object(bleak, name, value)
            p.start()
            self.addCleanup(p.stop)
        p = mock.patch.object(link_mod, 'SCAN_SECONDS', 0.6)
        p.start()
        self.addCleanup(p.stop)
        self.link = link_mod.MeterLink(lambda *a: None)

    def find(self):
        t0 = time.monotonic()
        r = asyncio.run_coroutine_threadsafe(self.link._find(), self.link._loop).result(5)
        return r, time.monotonic() - t0

    def test_stops_at_the_first_matching_advertisement(self):
        meter = Dev('AA')
        FakeScanner.SCRIPT = [(0.05, meter, Adv())]
        (dev, name, rssi), took = self.find()
        self.assertIs(dev, meter)
        self.assertEqual((name, rssi), ('121GW', -60))
        self.assertLess(took, 0.3)                          # not the full SCAN_SECONDS
        self.assertEqual(self.link.found, [('AA', '121GW', -60)])
        self.assertEqual(FakeScanner.runs[0]['kw'], {})      # no service filter given to the scanner

    def test_other_services_do_not_count_and_nothing_found_takes_the_full_time(self):
        FakeScanner.SCRIPT = [(0.05, Dev('BB', 'phone'), Adv(service=OTHER))]
        r, took = self.find()
        self.assertIsNone(r)
        self.assertGreaterEqual(took, 0.55)
        self.assertEqual(self.link.found, [])

    def test_a_chosen_meter_waits_for_that_meter_and_lists_every_meter(self):
        self.link.address = 'CC'
        chosen = Dev('CC')
        FakeScanner.SCRIPT = [(0.02, Dev('DD'), Adv(rssi=-70)), (0.1, chosen, Adv(rssi=-55))]
        (dev, _n, rssi), took = self.find()
        self.assertIs(dev, chosen)
        self.assertEqual(rssi, -55)
        self.assertEqual([f[0] for f in self.link.found], ['DD', 'CC'])

    def test_bluez_cached_device_does_not_count(self):
        FakeScanner.SCRIPT = [(0.02, Dev('EE'), Adv(rssi=link_mod.STALE_RSSI)), (0.1, Dev('FF'), Adv(rssi=-50))]
        with mock.patch.object(link_mod.sys, 'platform', 'linux'):
            (dev, _n, _r), _t = self.find()
        self.assertEqual(dev.address, 'FF')

    def test_a_scanner_that_cannot_start_raises(self):
        FakeScanner.FAIL = OSError('Bluetooth is off')
        with self.assertRaises(OSError):
            self.find()

    def test_pauses(self):
        def pause():
            t0 = time.monotonic()
            asyncio.run_coroutine_threadsafe(self.link._pause(), self.link._loop).result(5)
            return time.monotonic() - t0
        with mock.patch.object(link_mod, 'RETRY_SECONDS', 0.4), mock.patch.object(link_mod, 'QUICK_RETRY', 0.05):
            self.assertGreaterEqual(pause(), 0.35)
            self.link.quick_retry = True
            self.assertLess(pause(), 0.2)


class KeepLoop(unittest.TestCase):
    """The reconnect loop with the fakes: the device object goes to BleakClient; no held check while quick_retry."""
    def setUp(self):
        FakeScanner.SCRIPT, FakeScanner.FAIL, FakeScanner.runs = [], None, []
        FakeClient.made = []
        for target, name, value in ((bleak, 'BleakScanner', FakeScanner), (bleak, 'BleakClient', FakeClient),
                                    (link_mod, 'SCAN_SECONDS', 0.1), (link_mod, 'RETRY_SECONDS', 0.05),
                                    (link_mod, 'QUICK_RETRY', 0.01)):
            p = mock.patch.object(target, name, value)
            p.start()
            self.addCleanup(p.stop)
        self.held_calls = []

        async def held(address, service):
            self.held_calls.append(address)
            return False
        p = mock.patch.object(link_mod.oshold, 'held', held)
        p.start()
        self.addCleanup(p.stop)
        self.details = []
        self.link = link_mod.MeterLink(lambda *a: None, on_state=lambda state, detail: self.details.append(detail))
        self.addCleanup(self.link.disconnect)

    def run_for(self, seconds):
        self.link.connect(None)
        time.sleep(seconds)
        self.link.disconnect()
        time.sleep(0.2)

    def test_bleakclient_gets_the_device_object(self):
        meter = Dev('AA')
        FakeScanner.SCRIPT = [(0.01, meter, Adv())]
        self.run_for(0.3)
        self.assertTrue(FakeClient.made)
        self.assertTrue(all(m is meter for m in FakeClient.made), FakeClient.made)

    def test_no_held_check_while_waiting_for_the_update_mode(self):
        self.link.device = ('AA', '121GW')                   # a meter was connected before the restart
        self.link.quick_retry = True
        self.run_for(0.8)
        self.assertGreater(len(FakeScanner.runs), link_mod.HELD_CHECK_AFTER)
        self.assertEqual(self.held_calls, [])
        self.assertTrue(any('update mode' in d for d in self.details), self.details)

    def test_held_check_otherwise(self):
        self.link.device = ('AA', '121GW')
        self.run_for(0.8)
        self.assertEqual(self.held_calls, ['AA'])


if __name__ == '__main__':
    unittest.main()
