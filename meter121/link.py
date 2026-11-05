"""Bluetooth LE link to a 121GW: scan, connect, receive frames, send bytes, reconnect.

The meter's BLE112 module carries the USART2 byte stream on one characteristic (the firmware's FEATURES.md 2.10, working
with the firmware transfer since 2026-11-04): notifications bring the meter's bytes, writes (with response) deliver bytes
to it.  The link runs its own asyncio loop in a background thread (bleak: CoreBluetooth on macOS, WinRT on Windows, BlueZ
on Linux); the rest of the program calls the thread-safe methods below and reads `state`.

States: 'idle' (not connecting), 'scanning', 'connecting', 'connected', 'lost' (the meter went away, e.g. its auto
power-off; the link scans again by itself while `want` is set).  One central at a time: the meter accepts a single
connection, so the phone application or another bridge must not be connected.
"""
import asyncio
import threading
import time

from . import frames

SERVICE = '0bd51666-e7cb-469b-8e4d-2742f1ba77cc'
CHAR = 'e7add780-b042-4876-aae1-112855353cc1'
SCAN_SECONDS = 6.0
RETRY_SECONDS = 3.0


class MeterLink:
    def __init__(self, on_frame, on_state=None):
        """on_frame(kind, frame, t) is called in the link thread for every checked frame (frames.Reassembler);
        on_state(state, detail) at every state change."""
        self.on_frame, self.on_state = on_frame, on_state
        self.state, self.detail = 'idle', ''
        self.device = None                 # (address, name) of the connected or last connected meter
        self.found = []                    # [(address, name, rssi)] of the last scan
        self.want = False                  # keep connected (reconnect after a loss)
        self.address = None                # meter chosen by the user; None = the first one found
        self._client = None
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, name='meter-link', daemon=True)
        self._thread.start()
        self._task = None
        self.rx_bytes = 0                  # bytes received in this connection
        self.rx_dropped = 0                # of them skipped while resynchronising (frames.Reassembler)

    # ------------------------------------------------------------------ thread-safe interface
    def connect(self, address=None):
        self.address, self.want = address, True
        self._call(self._start)

    def disconnect(self):
        self.want = False
        self._call(self._stop)

    def scan(self):
        """Scan once (also while connected the meter does not advertise, so it is not listed then)."""
        return asyncio.run_coroutine_threadsafe(self._scan(), self._loop).result(SCAN_SECONDS + 5)

    def send(self, data, timeout=5.0):
        """Write bytes to the meter; raises RuntimeError when not connected."""
        return asyncio.run_coroutine_threadsafe(self._send(bytes(data)), self._loop).result(timeout)

    # ------------------------------------------------------------------ link thread
    def _run(self):
        asyncio.set_event_loop(self._loop)
        self._loop.run_forever()

    def _call(self, coro_fn):
        self._loop.call_soon_threadsafe(lambda: self._loop.create_task(coro_fn()))

    def _set(self, state, detail=''):
        self.state, self.detail = state, detail
        if self.on_state:
            self.on_state(state, detail)

    async def _scan(self):
        from bleak import BleakScanner
        devs = await BleakScanner.discover(timeout=SCAN_SECONDS, return_adv=True)
        self.found = [(d.address, d.name or adv.local_name or '121GW', adv.rssi) for d, adv in devs.values()
                      if SERVICE in [str(u).lower() for u in adv.service_uuids]]
        return list(self.found)

    async def _start(self):
        """Start the connection task; a task that is still running (also one that is being cancelled by a Disconnect
        a moment ago) is ended first, so a Connect right after a Disconnect always starts a fresh search."""
        await self._end_task()
        self._task = asyncio.ensure_future(self._keep())

    async def _stop(self):
        await self._end_task()
        self._set('idle')

    async def _end_task(self):
        """Cancel the connection task and wait until it has ended; it closes its own client (_keep's finally), so no
        half-open connection is left behind that would keep the meter from advertising."""
        task, self._task = self._task, None
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass
        if self._client is not None:                      # defensive: the task's finally clears it
            await self._close(self._client)
            self._client = None

    @staticmethod
    async def _close(client):
        try:
            await client.disconnect()
        except Exception:
            pass

    async def _keep(self):
        """Connect and stay connected while `want` is set.  The state is never 'idle' while this runs: it is 'scanning'
        (also while the computer's Bluetooth is off and the search is repeated), 'connecting', 'connected' or 'lost'."""
        try:
            await self._keep_loop()
        finally:
            if self._client is not None:
                await self._close(self._client)
                self._client = None

    async def _keep_loop(self):
        from bleak import BleakClient
        lost = False
        while self.want:
            self._set('scanning', 'looking for the meter' + (' again' if lost else ''))
            try:
                found = await self._scan()
            except Exception as e:                       # Bluetooth off, no permission, no adapter: searched again
                self._set('lost' if lost else 'scanning', 'Bluetooth of the computer: %s (searching again)' % e)
                await asyncio.sleep(RETRY_SECONDS)
                continue
            pick = [f for f in found if self.address is None or f[0] == self.address]
            if not pick:
                self._set('lost' if lost else 'scanning', 'no 121GW found: meter on, Bluetooth on (long PEAK), phone app closed?')
                await asyncio.sleep(RETRY_SECONDS)
                continue
            address, name, _ = pick[0]
            self._set('connecting', name)
            gone = asyncio.Event()
            reasm = frames.Reassembler()
            self.rx_bytes = self.rx_dropped = 0

            def on_notify(_h, chunk):
                t = time.time()
                self.rx_bytes += len(chunk)
                got = reasm.feed(bytes(chunk))
                self.rx_dropped = reasm.dropped
                for kind, frame in got:
                    self.on_frame(kind, frame, t)

            client = BleakClient(address, disconnected_callback=lambda _c: self._loop.call_soon_threadsafe(gone.set))
            self._client = client                         # known from here on, so a cancel closes it (_keep's finally)
            try:
                await client.connect()
                await client.start_notify(CHAR, on_notify)
            except Exception as e:
                await self._close(client)
                self._client = None
                self._set('lost' if lost else 'scanning', 'connecting failed: %s' % e)
                await asyncio.sleep(RETRY_SECONDS)
                continue
            self.device = (address, name)
            self._set('connected', name)
            await gone.wait()
            self._client = None
            lost = True
            if self.want:
                self._set('lost', 'the meter went away (auto power-off or out of range); looking for it again')

    async def _send(self, data):
        if self._client is None or self.state != 'connected':
            raise RuntimeError('not connected to a meter')
        await self._client.write_gatt_char(CHAR, data, response=True)
