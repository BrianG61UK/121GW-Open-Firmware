"""Frames the 121GW sends over its Bluetooth link, reassembled from the notification chunks.

The meter's Bluetooth module passes the USART2 byte stream through unchanged, split into notifications of any length.
Frames on that stream (analysis/ble_packet.md of the firmware repository, sections 3 and 6; the firmware's
FEATURES.md 2.10 and 2.11):

    start  length  frame                                  check
    F2     19      status frame (the reading)             XOR of all 19 bytes = 0
    F4     5       echo of a key frame                    the two hex pairs equal
    F8     15      echo of a set-clock frame              7th hex pair = XOR of the first six
    F6     7       version answer of the fast build       XOR of all 7 bytes = 0
    B5 5B  8+n     answer of the file transfer (2.10)     CRC-16/CCITT-FALSE

Bytes inside a binary frame can equal a start byte, so a frame is taken only when its whole length is present and its
check passes; otherwise the first byte is dropped and the search goes on from the next one (resynchronisation, also
after a frame the meter abandoned part way).  Standard library only.
"""

STATUS, KEY_ECHO, CLOCK_ECHO, VERSION, BFT = 'status', 'key_echo', 'clock_echo', 'version', 'bft'


def _xor(data):
    x = 0
    for b in data:
        x ^= b
    return x


def crc16(data, crc=0xFFFF):
    """CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF), as the file transfer of the firmware (ble/bft.s)."""
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc


def _hexval(c):
    if 0x30 <= c <= 0x39:
        return c - 0x30
    if 0x41 <= c <= 0x46:
        return c - 0x37
    return None


def _pair(data, i):
    hi, lo = _hexval(data[i]), _hexval(data[i + 1])
    return None if hi is None or lo is None else (hi << 4) | lo


class Reassembler:
    """feed(chunk) -> list of (kind, bytes) for every complete, checked frame in the stream so far."""

    def __init__(self):
        self.buf = bytearray()
        self.dropped = 0                 # bytes skipped while resynchronising

    def feed(self, chunk):
        self.buf += chunk
        out = []
        while self.buf:
            got = self._take()
            if got == 'wait':
                break
            if got is None:
                del self.buf[0]
                self.dropped += 1
                continue
            kind, n = got
            out.append((kind, bytes(self.buf[:n])))
            del self.buf[:n]
        return out

    def _take(self):
        """(kind, length) of a valid frame at the start of buf, None when there is none, 'wait' when more bytes are
        needed to decide."""
        b = self.buf
        s = b[0]
        if s == 0xF2:
            if len(b) < 19:
                return 'wait'
            return (STATUS, 19) if _xor(b[:19]) == 0 else None
        if s == 0xF6:
            if len(b) < 7:
                return 'wait'
            return (VERSION, 7) if _xor(b[:7]) == 0 and all(0x20 <= c < 0x7F for c in b[1:6]) else None
        if s == 0xF4:
            if len(b) < 5:
                return 'wait'
            p1, p2 = _pair(b, 1), _pair(b, 3)
            return (KEY_ECHO, 5) if p1 is not None and p1 == p2 else None
        if s == 0xF8:
            if len(b) < 15:
                return 'wait'
            v = [_pair(b, i) for i in range(1, 15, 2)]
            return (CLOCK_ECHO, 15) if None not in v and v[6] == _xor(v[:6]) else None
        if s == 0xB5:
            if len(b) < 2:
                return 'wait'
            if b[1] != 0x5B:
                return None
            if len(b) < 6:
                return 'wait'
            n = 8 + b[5]
            if len(b) < n:
                return 'wait'
            return (BFT, n) if crc16(b[2:n - 2]) == b[n - 2] | (b[n - 1] << 8) else None
        return None


def version_text(frame):
    """'F-1.00' from a version frame F6 c0..c4 x (the decimal point follows the third character)."""
    c = frame[1:6].decode('ascii')
    return c[:3] + '.' + c[3:]


def key_frame(code):
    """The key frame of `code` (0x01..0x08 short, 0x81..0x88 long, 0x90 version request): F4 and the code as an
    ASCII hex pair twice (analysis/ble_packet.md 6)."""
    h = b'%02X' % code
    return b'\xF4' + h + h


VERSION_REQUEST = key_frame(0x90)
