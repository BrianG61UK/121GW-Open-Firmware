"""Shared helpers of the tests: the import path of the package and a fake meter that speaks the card / settings protocol.

The fake meter implements the requests 0x10 .. 0x17 of firmware/src/ble/bftsd.s and bftset.s (answer
B5 5B 82 seq len status field(2) data crc16) in Python over an in-memory set of files and settings, including the name
rules, the statuses and the ranges of the firmware.  Its answers go through the real frames.Reassembler in notifications
of a few bytes each, like the Bluetooth link delivers them, so the framing and resynchronisation of the program are in
the loop.
"""
import os
import queue
import struct
import sys
import zlib

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')))

from meter121 import card, frames, settings, transfer      # noqa: E402  (after the path change)


def fat_date(y, m, d):
    return (y - 1980) << 9 | m << 5 | d


def fat_time(h, mi, s):
    return h << 11 | mi << 5 | s // 2


# bftset.s bfs_tab: id -> (min, max); 0x020 is one id with the value 0..15
RANGES = {0x00F: (0, 5), 0x010: (0, 1), 0x011: (0, 3), 0x013: (0, 1), 0x014: (0, 15), 0x015: (0, 3), 0x016: (0, 1),
          0x017: (0, 100), 0x01A: (10, 17), 0x01B: (0, 1), 0x01E: (0, 1), 0x020: (0, 15), 0x021: (0, 3), 0x022: (1, 255),
          0x028: (0, 2), 0x029: (0, 2), 0x02A: (50, 150)}
OK_NAME = set('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._ -')


def name_ok(name):
    """bftsd.s name rules: 1 .. 63 bytes of the permitted set, no "..", no space at an end, no dot at the end."""
    return (1 <= len(name) <= 63 and set(name) <= OK_NAME and '..' not in name and name == name.strip(' ')
            and not name.endswith('.'))


class FakeMeter:
    """send(bytes) takes a request packet; the answer frames are put into `answers` (as the app's link does)."""

    def __init__(self, files=None, eeprom=None, page=3, notify=7):
        self.files = dict(files or {})                 # name -> (bytes, fat_date, fat_time) or + attr
        self.eeprom = dict(eeprom or {})               # setting id -> value (the ids it reports with GET)
        self.page = page                               # LIST entries per answer (at most; also limited by 232 bytes)
        self.notify = notify                           # bytes per notification
        self.answers = queue.Queue()
        self.reasm = frames.Reassembler()
        self.staged = b''
        self.logging = False                           # status 3 "not allowed now" for the requests that change things
        self.sectors_per_cluster = 64
        self.free, self.total = 1_000_000, 100_000_000     # clusters
        self.sent = []                                 # (type, payload) of every request received
        self.drop_next = 0                             # answers to swallow (a lost notification)
        self.corrupt_chunk_once = False                # one CHUNK answer with wrong data but a valid packet CRC
        self.refuse_put = None                         # status for PUT
        self.deliver = None                            # deliver(kind, frame, t) instead of `answers` (the app's _frame)
        self.two_part = True                           # False: EEVblog's bootloader, FORMAT is answered 0x25
        self.on_ld = True                              # False: the meter shows a measuring page and ignores transfer requests
        self.echo_keys = True                          # answer a key frame F4 with its echo
        self.keys = []                                 # key frames received
        self.diag = list(range(100, 121))              # STATUS values 0..20
        self.fast_xdiag = False                        # firmware F-1.15: key codes 0x93 / 0x94 / 0x95, STATUS 40..48
        self.xdiag_counting = False
        self.xdiag_values = [1000, 2, 1, 3, 0, 4, 5, 6, 598]    # the nine counters (rx_bytes .. battery_cv)
        self.xdiag_lost = 0                            # F9 answers to swallow (a lost notification)

    # -- the link side
    def _out(self, data):
        for i in range(0, len(data), self.notify):
            for kind, f in self.reasm.feed(data[i:i + self.notify]):
                if self.deliver:
                    self.deliver(kind, f, 0.0)
                elif kind == frames.BFT:
                    self.answers.put(f)

    def send(self, pkt):
        pkt = bytes(pkt)
        if pkt[:1] == b'\xF4':                          # a key frame: the meter echoes it
            self.keys.append(pkt)
            if self.echo_keys:
                self._out(pkt)
            if self.fast_xdiag:                         # ble/commands.s: 0x93 on and clear, 0x94 off, 0x95 counters (F9 only while on)
                code = frames._pair(pkt, 1)
                if code == 0x93:
                    self.xdiag_counting = True
                elif code == 0x94:
                    self.xdiag_counting = False
                elif code == 0x95 and self.xdiag_counting:
                    if self.xdiag_lost:
                        self.xdiag_lost -= 1
                    else:
                        self._out(xdiag_frame(self.xdiag_values))
            return
        if not self.on_ld:
            return
        if pkt[:2] != b'\xB5\x5B' or frames.crc16(pkt[2:-2]) != pkt[-2] | pkt[-1] << 8:
            return                                     # a damaged request: the meter answers 0x81 status 1, never 0x82
        rtype, seq, n = struct.unpack_from('<BHB', pkt, 2)
        payload = pkt[6:6 + n]
        self.sent.append((rtype, payload))
        if rtype == transfer.T_STATUS:                 # diagnosis value: type 0x81 answer, value in "next" (ble/bft.s)
            idx = payload[0]
            ok = idx < len(self.diag)
            self._out(transfer.packet(0x81, seq, bytes([0 if ok else 3]) + struct.pack('<H', self.diag[idx] if ok else 0)))
            return
        status, field, data = self._handle(rtype, payload)
        if self.drop_next:
            self.drop_next -= 1
            return
        self._out(card.answer_packet(seq, status, field, data))

    # -- the meter side: (status, field, data)
    def _entry(self, name):
        f = self.files[name]
        attr = f[3] if len(f) > 3 else 0x20
        raw = name.encode('latin-1')
        cut = len(raw) > 63
        raw = raw[:63]
        return struct.pack('<IHHBB', min(len(f[0]), 0xFFFFFFFF), f[1], f[2], attr | (0x80 if cut else 0), len(raw)) + raw

    def _handle(self, rtype, p):
        if self.logging and rtype in (card.T_LIST, card.T_READ, card.T_DELETE, card.T_INFO, card.T_FORMAT, settings.T_PUT):
            return card.ST_NOT_NOW, 0, b''
        if rtype == card.T_LIST:
            if len(p) != 2:
                return card.ST_ARG, 0, b''
            start = struct.unpack('<H', p)[0]
            names = sorted(self.files)[start:]
            data, count = b'', 0
            for n in names[:self.page]:
                e = self._entry(n)
                if len(data) + len(e) > 232:
                    break
                data += e
                count += 1
            return card.ST_OK, count | (card.LIST_END if count == len(names) else 0), data
        if rtype == card.T_READ:
            self.staged = b''                          # a failed READ leaves nothing to CHUNK
            if not p or len(p) != p[0] + 7:
                return card.ST_ARG, 0, b''
            name = p[1:1 + p[0]].decode('latin-1')
            offset, length = struct.unpack_from('<IH', p, 1 + p[0])
            if not name_ok(name):
                return card.ST_NAME, 0, b''
            if not 1 <= length <= card.WINDOW:
                return card.ST_ARG, 0, b''
            found = [n for n in self.files if n.lower() == name.lower()]
            if not found:
                return card.ST_NOT_FOUND, 0, b''
            self.staged = self.files[found[0]][0][offset:offset + length]
            return card.ST_OK, len(self.staged), struct.pack('<I', zlib.crc32(self.staged) & 0xFFFFFFFF)
        if rtype == card.T_CHUNK:
            if len(p) != 2:
                return card.ST_ARG, 0, b''
            idx = struct.unpack('<H', p)[0]
            if len(self.staged) - idx * card.CHUNK <= 0:
                return card.ST_ARG, 0, b''
            data = self.staged[idx * card.CHUNK:(idx + 1) * card.CHUNK]
            if self.corrupt_chunk_once and idx == 0:
                self.corrupt_chunk_once = False
                data = bytes([data[0] ^ 0xFF]) + data[1:]
            return card.ST_OK, idx, data
        if rtype == card.T_DELETE:
            if not p or len(p) != p[0] + 1:
                return card.ST_ARG, 0, b''
            name = p[1:].decode('latin-1')
            if not name_ok(name):
                return card.ST_NAME, 0, b''
            if name.lower() in card.PROTECTED:
                return card.ST_PROTECTED, 0, b''
            found = [n for n in self.files if n.lower() == name.lower()]
            if not found:
                return card.ST_NOT_FOUND, 0, b''
            del self.files[found[0]]
            return card.ST_OK, 0, b''
        if rtype == card.T_FORMAT:
            if p != card.FORMAT_WORD:
                return card.ST_ARG, 0, b''
            if not self.two_part:
                return card.ST_NO_FORMAT, 0, b''
            self.files.clear()
            self.free = self.total
            return card.ST_OK, 0, b''
        if rtype == card.T_INFO:
            if p:
                return card.ST_ARG, 0, b''
            return card.ST_OK, self.sectors_per_cluster, struct.pack('<II', self.free, self.total)
        if rtype == settings.T_GET:
            if p:
                return card.ST_ARG, 0, b''
            return (card.ST_OK,) + settings.get_answer(sorted(self.eeprom.items()))
        if rtype == settings.T_PUT:
            if self.refuse_put:
                return self.refuse_put, 0, b''
            if len(p) != 3:
                return card.ST_ARG, 0, b''
            i, v = struct.unpack('<HB', p)
            if i not in RANGES or i not in self.eeprom or not RANGES[i][0] <= v <= RANGES[i][1]:
                return card.ST_ARG, 0, b''
            if i == 0x020 and (v >> 1) & 3 == 3:      # the trigger 3 is refused
                return card.ST_ARG, 0, b''
            self.eeprom[i] = v
            return card.ST_OK, i, bytes([v])
        return card.ST_NOT_NOW, 0, b''                 # an unknown type


def xdiag_frame(values):
    """The frame F9 of the firmware (ble/xdiag.s): F9, nine u16 little-endian, XOR of the 19 bytes before it."""
    body = b'\xF9' + b''.join(struct.pack('<H', v) for v in values)
    return body + bytes([frames._xor(body)])


def make_client(meter):
    return card.Client(meter.send, meter.answers)


def sample_files():
    """A few files of different sizes (one window, several windows, empty) with dates."""
    big = bytes((i * 7 + 3) & 0xFF for i in range(20000))        # 3 windows of 8192
    return {'LOG0001.CSV': (b'time,value\n1,2\n' * 40, fat_date(2026, 11, 3), fat_time(12, 30, 10)),
            'LOG0002.CSV': (big, fat_date(2026, 11, 4), fat_time(8, 5, 0)),
            'cal.bin': (bytes(range(256)) * 4, fat_date(2025, 1, 2), fat_time(1, 2, 4)),
            'EMPTY.TXT': (b'', fat_date(2026, 11, 4), fat_time(9, 0, 0)),
            'EEVBlog.bin': (b'\x00' * 300, fat_date(2026, 10, 1), fat_time(0, 0, 0))}


__all__ = ['FakeMeter', 'make_client', 'xdiag_frame', 'sample_files', 'fat_date', 'fat_time', 'card', 'frames', 'settings', 'transfer']
