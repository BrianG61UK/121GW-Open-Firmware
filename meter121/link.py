"""Bluetooth LE link to a 121GW: scan, connect, receive frames, send bytes, reconnect.

The meter's BLE112 module carries the USART2 byte stream on one characteristic (the firmware's FEATURES.md 2.10, working
with the firmware transfer since 2026-11-04): notifications bring the meter's bytes, writes (with response) deliver bytes
to it.  The link runs its own asyncio loop in a background thread (bleak: CoreBluetooth on macOS, WinRT on Windows, BlueZ
on Linux); the rest of the program calls the thread-safe methods below and reads `state`.

States: 'idle' (not connecting), 'scanning', 'connecting', 'connected', 'lost' (the meter went away, e.g. its auto
power-off; the link scans again by itself while `want` is set).  One central at a time: the meter accepts a single
connection, so no other Bluetooth app or bridge may be connected.
"""
import asyncio
import collections
import concurrent.futures
import math
import sys
import threading
import time

from . import frames, oshold

SERVICE = '0bd51666-e7cb-469b-8e4d-2742f1ba77cc'
CHAR = 'e7add780-b042-4876-aae1-112855353cc1'
SCAN_SECONDS = 6.0
WRITE_WAIT = 5.0                        # seconds a write may take before it counts as failed
HELD_CHECK_AFTER = 2                    # searches without the meter before asking whether the system holds it
STOP_NOTIFY_WAIT = 2.0                  # seconds for unsubscribing the notifications before a disconnect (issue 23)
RETRY_SECONDS = 3.0
WINDOWS_HINT_AFTER = 2                 # searches in a row without the meter before the Windows hint (GitHub issue 23)
NOT_FOUND = 'no 121GW found: meter on, Bluetooth on (long PEAK), other Bluetooth apps closed?'
# a meter added in Windows Settings > Bluetooth & devices is kept connected by Windows; connected, the module does not
# advertise, so no search finds it (the companion needs no pairing)
NOT_FOUND_WINDOWS = ('no 121GW found: if Windows lists "121GW" as connected in Settings > Bluetooth & devices, remove it '
                     'there, then switch the meter\'s Bluetooth off and on (long PEAK)')


def not_found_text(misses, platform=None):
    """The status text after `misses` searches in a row without the meter: on Windows, from WINDOWS_HINT_AFTER on,
    the hint that Windows may be holding the meter."""
    if (platform or sys.platform) == 'win32' and misses >= WINDOWS_HINT_AFTER:
        return NOT_FOUND_WINDOWS
    return NOT_FOUND


SIZE_BUCKETS = ((1, 20), (21, 64), (65, 244))     # notification sizes in the report (244 = the largest the meter's MTU 247 gives)
SAMPLES_KEEP = 4000                                # gaps and confirmation times kept for the median / 95 % / maximum
DISCONNECTS_KEEP = 50


def percentile(values, q):
    """Nearest-rank percentile (q in 0..1) of a list of numbers; None for an empty list."""
    if not values:
        return None
    v = sorted(values)
    return v[min(len(v) - 1, max(0, int(math.ceil(q * len(v))) - 1))]


class LinkStats:
    """What the report's [link details] shows about the Bluetooth link itself (always recorded, a few numbers per
    notification): notification count, sizes and gaps; writes with response and the time until they were confirmed; the
    advertisement signal strength when the meter was found; the negotiated MTU; the disconnects with their reasons.
    Written by the link thread, read by the report thread: all under one lock."""

    def __init__(self):
        self._lock = threading.Lock()
        self.notifications = 0
        self.sizes = [0] * (len(SIZE_BUCKETS) + 1)      # one per bucket and one for anything larger
        self.gaps = collections.deque(maxlen=SAMPLES_KEEP)      # seconds between two notifications of one connection
        self._last = None
        self.writes = 0
        self.write_errors = 0
        self.last_write_error = None                    # (monotonic time, text)
        self.write_times = collections.deque(maxlen=SAMPLES_KEEP)   # seconds from the write to its confirmation
        self.rssi = []                                  # [(connection number, dBm or None)] at discovery
        self.connections = 0
        self.mtu = None                                 # bleak client mtu_size of the last connection, None = not available
        self.disconnects = collections.deque(maxlen=DISCONNECTS_KEEP)   # (wall time, user?, reason)
        self.disconnect_count = 0

    def notification(self, size, t=None):
        t = time.monotonic() if t is None else t
        with self._lock:
            self.notifications += 1
            for i, (lo, hi) in enumerate(SIZE_BUCKETS):
                if size <= hi:
                    self.sizes[i] += 1
                    break
            else:
                self.sizes[-1] += 1
            if self._last is not None:
                self.gaps.append(t - self._last)
            self._last = t

    def write(self, seconds):
        with self._lock:
            self.writes += 1
            self.write_times.append(seconds)

    def write_error(self, text, t=None):
        with self._lock:
            self.write_errors += 1
            self.last_write_error = (time.monotonic() if t is None else t, text)

    def advertised(self, rssi):
        with self._lock:
            self.rssi.append((self.connections + 1, rssi))
            del self.rssi[:-DISCONNECTS_KEEP]

    def connected(self, mtu):
        with self._lock:
            self.connections += 1
            self.mtu = mtu
            self._last = None                           # a gap never spans two connections

    def disconnect(self, reason, user=False, now=None):
        with self._lock:
            self.disconnect_count += 1
            self._last = None
            self.disconnects.append((time.time() if now is None else now, user, reason))

    def recent_write_error(self, within=5.0):
        with self._lock:
            e = self.last_write_error
        return e[1] if e and time.monotonic() - e[0] <= within else None

    def snapshot(self):
        with self._lock:
            gaps, wt = list(self.gaps), list(self.write_times)
            return {'notifications': self.notifications, 'sizes': list(self.sizes),
                    'gap_median': percentile(gaps, 0.5), 'gap_p95': percentile(gaps, 0.95), 'gap_max': max(gaps) if gaps else None,
                    'writes': self.writes, 'write_errors': self.write_errors,
                    'write_median': percentile(wt, 0.5), 'write_max': max(wt) if wt else None,
                    'rssi': list(self.rssi), 'connections': self.connections, 'mtu': self.mtu,
                    'disconnects': list(self.disconnects), 'disconnect_count': self.disconnect_count}


class MeterLink:
    def __init__(self, on_frame, on_state=None):
        """on_frame(kind, frame, t) is called in the link thread for every checked frame (frames.Reassembler);
        on_state(state, detail) at every state change."""
        self.on_frame, self.on_state = on_frame, on_state
        self.state, self.detail = 'idle', ''
        self.device = None                 # (address, name) of the connected or last connected meter
        self.found = []                    # [(address, name, rssi)] of the last scan
        self.held = None                   # the last check whether the system still holds the meter (oshold.py)
        self.last_write = 0.0              # time of the last write to the meter (the heartbeat writes when idle)
        self._wlock = None                 # one write at a time (_send)
        self.want = False                  # keep connected (reconnect after a loss)
        self.address = None                # meter chosen by the user; None = the first one found
        self._client = None
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, name='meter-link', daemon=True)
        self._thread.start()
        self._task = None
        self.rx_bytes = 0                  # bytes received in this connection
        self.rx_dropped = 0                # of them skipped while resynchronising (frames.Reassembler)
        self.l2 = frames.Link2()           # link 2 decoder (firmware F-1.31, IMP-62), in front of the Reassembler
        self.stats = LinkStats()           # notification / write / disconnect statistics for the report
        self.pieces = collections.deque(maxlen=frames.DAMAGED_KEEP)   # damaged pieces of all connections (frames.Reassembler)
        self.reasm = frames.Reassembler(self.pieces)

    def damaged(self):
        """The last runs of bytes the reassembler skipped, oldest first: [(length, first bytes)]."""
        return self.reasm.damaged()

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
        """Write bytes to the meter; raises RuntimeError when not connected, OSError when the write fails or is
        cancelled (the connection went away under it), TimeoutError after `timeout` seconds."""
        try:
            return asyncio.run_coroutine_threadsafe(self._send(bytes(data)), self._loop).result(timeout)
        except concurrent.futures.CancelledError as e:   # a BaseException: it would end the calling thread
            raise OSError('the write was cancelled (the connection went away)') from e

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
        was = self.state
        await self._end_task()
        if was == 'connected':
            self.stats.disconnect('disconnected by the user', user=True)
        self._set('idle')
        if was == 'connected' and self.device:            # does the system still hold the meter? (issue 23)
            asyncio.ensure_future(self._after_disconnect(self.device[0]))

    async def _after_disconnect(self, address):
        held, released, hint = await oshold.check_after_disconnect(address, SERVICE)
        self.held = {'held': held, 'released': released, 'hint': hint, 'at': time.time()}
        if hint and not self.want:                       # not when a new Connect is already searching
            self._set('idle', hint)

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
        """Unsubscribe the notifications, then disconnect.  bleak's Windows backend (bleak/backends/winrt/client.py
        disconnect) only drops its own handlers and closes its objects without waiting for the link to go; the meter
        keeps its notification subscription, and Windows was seen to keep the connection ("Connected (1)" in the tray)
        so that the meter did not advertise again and a new Connect found nothing until Bluetooth was switched off and
        on (GitHub issue 23).  stop_notify writes the subscription off first; it is given STOP_NOTIFY_WAIT seconds, so a
        link that is already gone does not hold up the disconnect."""
        try:
            if client.is_connected:
                await asyncio.wait_for(client.stop_notify(CHAR), STOP_NOTIFY_WAIT)
        except Exception:                                # noqa: BLE001 - gone, not subscribed, or slow: disconnect anyway
            pass
        oshold.prepare_close(client)                     # Windows: maintain_connection False (oshold.py)
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
        misses = 0                                       # searches in a row without the meter
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
                misses += 1
                text = not_found_text(misses)
                if misses == HELD_CHECK_AFTER and self.device:   # not advertising: does the system hold it? (issue 23)
                    state = await oshold.held(self.device[0], SERVICE)
                    if state is True and await oshold.release(self.device[0]):
                        text = 'the system still held the meter; BlueZ was asked to release it (searching again)'
                    elif state is True:
                        key = 'win32' if sys.platform == 'win32' else 'darwin' if sys.platform == 'darwin' else 'linux'
                        text = oshold.HINT[key]
                    self.held = {'held': state, 'released': False, 'hint': text if state else None, 'at': time.time()}
                self._set('lost' if lost else 'scanning', text)
                await asyncio.sleep(RETRY_SECONDS)
                continue
            address, name, rssi = pick[0]
            misses = 0
            self.stats.advertised(rssi)                   # the advertisement's signal strength at discovery (dBm)
            self._set('connecting', name)
            gone = asyncio.Event()
            reasm = self.reasm = frames.Reassembler(self.pieces)
            l2 = self.l2 = frames.Link2()
            self.rx_bytes = self.rx_dropped = 0

            def on_notify(_h, chunk):
                t = time.time()
                self.stats.notification(len(chunk))
                self.rx_bytes += len(chunk)
                plain, readings = l2.feed(bytes(chunk))      # link 2 blocks out, every other byte on
                for frame, age in readings:
                    self.on_frame(frames.STATUS, frame, t - age)
                got = reasm.feed(plain)
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
            try:
                mtu = int(client.mtu_size)                # not every backend knows it
            except Exception:                             # noqa: BLE001 - absent, or the backend raises: not available
                mtu = None
            self.stats.connected(mtu)
            self._set('connected', name)
            await gone.wait()
            self._client = None
            lost = True
            why = 'the Bluetooth stack reported the connection as gone (it gives no cause)'
            err = self.stats.recent_write_error()
            self.stats.disconnect(why + ('; last write error: %s' % err if err else ''))
            if self.want:
                self._set('lost', 'the meter went away (auto power-off or out of range); looking for it again')

    async def _send(self, data):
        """One write at a time (IMP-56 review: the heartbeat thread, key frames and page Ld packets are written from
        different threads; a second write while one is in flight is refused by some backends), each bounded by
        WRITE_WAIT so an abandoned write cannot pile up on a dead link; last_write is the time of the last write."""
        if self._client is None or self.state != 'connected':
            raise RuntimeError('not connected to a meter')
        if self._wlock is None:
            self._wlock = asyncio.Lock()               # created on the link's own loop
        async with self._wlock:
            return await self._send_one(data)

    async def _send_one(self, data):
        if self._client is None or self.state != 'connected':
            raise RuntimeError('not connected to a meter')
        t0 = time.monotonic()
        self.last_write = time.time()
        try:
            await asyncio.wait_for(self._client.write_gatt_char(CHAR, data, response=True), WRITE_WAIT)
        except Exception as e:
            self.stats.write_error('%s: %s' % (type(e).__name__, e))
            # one error type for the callers: bleak's own (BleakError "disconnected" while the meter restarts) is no
            # OSError, and an update thread that met it ended without a word (issue: notice stuck at "restarting")
            raise OSError('write failed: %s: %s' % (type(e).__name__, e)) from e
        self.stats.write(time.monotonic() - t0)         # seconds until the write was confirmed
