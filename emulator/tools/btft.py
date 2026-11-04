"""Bluetooth file transfer to the 121GW SD card: the packet format of the firmware (firmware/src/ble/bft.s, IMP-28).

Used by bt_upload.py (a real meter over Bluetooth LE) and emulator/scripts/test_bt_upload.py (the emulated meter).

Packet to the meter: B5 5B type seq(2) len(1) payload crc16(2), little-endian, CRC-16/CCITT-FALSE over type..payload.
Answer from the meter: B5 5B 81 seq(2) 03 status next(2) crc16(2).
"""
import struct
import zlib

T_START, T_DATA, T_END, T_ABORT, T_ANSWER = 1, 2, 3, 4, 0x81
MAX_PAYLOAD = 232
STATUS_TEXT = {0: 'accepted', 1: 'CRC wrong', 2: 'not the expected packet', 3: 'not allowed now', 4: 'START refused (size)',
               5: 'beyond the announced size', 0x11: 'card could not be written', 0x12: 'length or CRC-32 wrong',
               0x13: 'not an application image', 0x14: 'copy to EEVBlog.bin failed', 0x15: 'EEVBlog.bin read back differs'}
MIN_SIZE, MAX_SIZE = 0x124, 0x5A000


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def packet(ptype, seq, payload=b''):
    if len(payload) > MAX_PAYLOAD:
        raise ValueError('payload above %d bytes' % MAX_PAYLOAD)
    body = struct.pack('<BHB', ptype, seq & 0xFFFF, len(payload)) + bytes(payload)
    return b'\xB5\x5B' + body + struct.pack('<H', crc16(body))


def start_packet(data):
    return packet(T_START, 0, struct.pack('<II', len(data), zlib.crc32(data) & 0xFFFFFFFF))


def data_packets(data):
    return [packet(T_DATA, n, data[i:i + MAX_PAYLOAD]) for n, i in enumerate(range(0, len(data), MAX_PAYLOAD))]


def check_image(data):
    """The checks the meter makes at END (bft_finish), done before sending: None or the reason for refusing."""
    if not MIN_SIZE <= len(data) <= MAX_SIZE:
        return 'size %d outside %d .. %d bytes' % (len(data), MIN_SIZE, MAX_SIZE)
    sp, reset = struct.unpack_from('<II', data, 0)
    if not 0x20000001 <= sp <= 0x20014000:
        return 'initial stack pointer 0x%08X is not in the RAM' % sp
    if not (reset & 1) or not 0x08006000 <= reset < 0x08060000:
        return 'reset vector 0x%08X is not a Thumb address in 0x08006000 .. 0x0805FFFF' % reset
    return None


class AnswerParser:
    """Collects bytes from the meter and returns complete answers (status frames and other bytes are skipped)."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf.extend(data)
        out = []
        while True:
            i = self.buf.find(b'\xB5\x5B\x81')
            if i < 0:
                del self.buf[:max(0, len(self.buf) - 2)]
                return out
            if len(self.buf) < i + 11:
                del self.buf[:i]
                return out
            a = bytes(self.buf[i:i + 11])
            if a[5] == 3 and crc16(a[2:9]) == struct.unpack_from('<H', a, 9)[0]:
                seq, status, nxt = struct.unpack_from('<H', a, 3)[0], a[6], struct.unpack_from('<H', a, 7)[0]
                out.append((seq, status, nxt))
                del self.buf[:i + 11]
            else:
                del self.buf[:i + 1]
