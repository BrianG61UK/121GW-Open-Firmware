#!/usr/bin/env python3
"""meter_api.py - the meter API of the fast firmware (F-1.33 and newer, IMP-65) from the command line, over Bluetooth.

    COMPANION_DIR=<path of the companion checkout> python3 tools/meter_api.py COMMAND ...

Commands (run one after another in a single connection):
    where                   dial position, mode, SETUP page, edit state, flags
    show ITEM               the meter shows SETUP page ITEM (set_item number, ble/bfapi.s), as SETUP presses would
    get                     every setting {id: value} (the two-byte settings included)
    put ID VALUE            change one setting as its page does (ID hex like 0x02D or decimal)
    key NAME [long]         a key of the meter (companion keys.py names), e.g. key setup / key mode long
    read                    the meter's display from the newest status frame
    wait SECONDS            pause
Example:  meter_api.py where show 45 put 0x02D 97 where

The link comes from the companion (meter121.link.MeterLink, the same connection code); COMPANION_DIR names its checkout.
Every request is repeated up to three times when no answer comes (the meter drops a cut packet after 100 ms).
"""
import os
import queue
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import btft  # noqa: E402

ANSWER_WAIT = 4.0       # seconds for one answer (a 99-byte GET answer over link 2 at 5 blocks/s takes about 1.3 s)
TRIES = 3


def _companion():
    d = os.environ.get('COMPANION_DIR')
    if not d or not os.path.isdir(os.path.join(d, 'meter121')):
        sys.exit('meter_api: set COMPANION_DIR to the companion checkout (the folder that holds meter121/)')
    sys.path.insert(0, d)
    from meter121 import frames, keys       # noqa: E402
    from meter121.link import MeterLink     # noqa: E402
    return frames, keys, MeterLink


class Api:
    def __init__(self):
        frames, self.keys, MeterLink = _companion()
        self.frames = frames
        self.answers, self.echo, self.state, self.seq = queue.Queue(), queue.Queue(), {}, 0
        self.parser = btft.AnswerParser()
        self.last_status = None
        self.link = MeterLink(self._frame, lambda s, d: self.state.__setitem__('s', s))

    def _frame(self, kind, frame, t):
        if kind == self.frames.STATUS:
            self.last_status = (bytes(frame), t)
        if kind == self.frames.BFT:
            for a in self.parser.feed(bytes(frame)):
                self.answers.put(a)
        elif kind == self.frames.KEY_ECHO:
            self.echo.put(bytes(frame))

    def connect(self, timeout=60):
        self.link.connect(None)
        end = time.time() + timeout
        while self.state.get('s') != 'connected':
            if time.time() > end:
                sys.exit('meter_api: no connection (%s)' % self.state.get('s'))
            time.sleep(0.3)

    def close(self):
        """Disconnect and wait until the link has let go: MeterLink.disconnect only schedules the stop, and a
        CoreBluetooth callback that arrives while Python shuts down aborts the process (2026-11-10, crash report
        "pthread_exit() called from a thread not created by pthread_create()" in PyGILState_Ensure)."""
        self.link.disconnect()
        end = time.time() + 5.0
        while self.state.get('s') == 'connected' and time.time() < end:
            time.sleep(0.1)
        time.sleep(0.5)                       # the last notifications of the connection drain before the exit

    def request(self, make):
        """Send make(seq) and return the type 0x82 answer with that seq."""
        for _ in range(TRIES):
            self.seq = (self.seq + 1) & 0xFFFF
            self.link.send(make(self.seq))
            end = time.time() + ANSWER_WAIT
            while time.time() < end:
                try:
                    a = self.answers.get(timeout=max(0.05, end - time.time()))
                except queue.Empty:
                    break
                if isinstance(a, btft.Answer2) and a.seq == self.seq:
                    return a
        raise RuntimeError('no answer after %d tries' % TRIES)

    def where(self):
        a = self.request(btft.where_packet)
        if a.status:
            raise RuntimeError('WHERE refused: status 0x%02X' % a.status)
        return btft.parse_where(a)

    def show(self, item):
        a = self.request(lambda s: btft.show_packet(s, item))
        return a.status

    def get(self):
        out, start = {}, 0
        while True:
            a = self.request(lambda s: btft.get_wide_packet(s, start, 16, 1))
            if a.status:
                raise RuntimeError('GET refused: status 0x%02X' % a.status)
            got = btft.parse_get_wide(a)
            out.update(dict(got))
            if a.field & 0x8000 or not got:
                return out
            start += len(got)

    def put(self, sid, value):
        a = self.request(lambda s: btft.put_wide_packet(s, sid, value))
        applied = struct.unpack('<H', a.data[:2])[0] if a.status == 0 and len(a.data) >= 2 else None
        return a.status, applied

    def read(self):
        """The display of the newest status frame (companion meter121.display.decode), or None."""
        from meter121 import display          # noqa: E402 (COMPANION_DIR is on the path after _companion)
        end = time.time() + ANSWER_WAIT
        while self.last_status is None and time.time() < end:
            time.sleep(0.1)
        if self.last_status is None:
            return None
        f, t = self.last_status
        d = display.decode(f, t)
        return '%s %s %s (sub %s %s)' % (d['mode_name'], d['text'], d['unit'] or '', d['sub_text'] or '', d['sub_unit'] or '')

    def key(self, name, long=False):
        f = self.keys.frame(name, long)
        while not self.echo.empty():
            self.echo.get_nowait()
        self.link.send(f)
        try:
            return self.echo.get(timeout=ANSWER_WAIT) == f
        except queue.Empty:
            return False


def main(argv):
    if not argv:
        sys.exit(__doc__)
    api = Api()
    api.connect()
    try:
        i = 0
        while i < len(argv):
            c = argv[i]
            if c == 'where':
                print('where', api.where())
                i += 1
            elif c == 'show':
                item = int(argv[i + 1], 0)
                st = api.show(item)
                print('show %d: %s' % (item, 'ok' if st == 0 else 'status 0x%02X' % st))
                i += 2
            elif c == 'get':
                print('get', {'0x%03X' % k: v for k, v in sorted(api.get().items())})
                i += 1
            elif c == 'put':
                sid, value = int(argv[i + 1], 0), int(argv[i + 2], 0)
                st, applied = api.put(sid, value)
                print('put 0x%03X %d: %s' % (sid, value, ('applied %d' % applied) if st == 0 else 'status 0x%02X' % st))
                i += 3
            elif c == 'key':
                name = argv[i + 1]
                long = i + 2 < len(argv) and argv[i + 2] == 'long'
                print('key %s%s: %s' % (name, ' long' if long else '', 'echoed' if api.key(name, long) else 'no echo'))
                i += 3 if long else 2
            elif c == 'read':
                print('read', api.read())
                i += 1
            elif c == 'wait':
                time.sleep(float(argv[i + 1]))
                i += 2
            else:
                sys.exit('meter_api: unknown command %r' % c)
    finally:
        api.close()


if __name__ == '__main__':
    main(sys.argv[1:])
