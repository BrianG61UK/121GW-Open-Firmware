"""Bluetooth file transfer to the 121GW SD card: the packet format of the firmware (firmware/src/ble/bft.s, IMP-28).

Used by bt_upload.py (a real meter over Bluetooth LE), emulator/scripts/test_bt_upload.py, test_bft_files.py and
test_bft_settings.py (the emulated meter).

Packet to the meter: B5 5B type seq(2) len(1) payload crc16(2), little-endian, CRC-16/CCITT-FALSE over type..payload.
Answer to the firmware transfer (types 1 .. 5): B5 5B 81 seq(2) 03 status next(2) crc16(2).
Answer to the SD file and settings requests (types 0x10 .. 0x17, firmware/src/ble/bftsd.s, bftset.s):
    B5 5B 82 seq(2) len status field(2) data crc16(2), len = 3 + len(data), data <= 232 bytes.
Requests (payload):
    0x10 LIST   start(2)                           root directory entries from `start`
    0x11 READ   namelen(1) name offset(4) len(2)   len 1 .. 8192, staged in the meter's RAM
    0x12 CHUNK  idx(2)                             232-byte piece idx of the staged bytes (no card access)
    0x13 DELETE namelen(1) name
    0x14 INFO   -
    0x16 GET    -                                  every setting: field = count, data = (id(2) value(1)) per setting
    0x17 PUT    id(2) value(1)                     one setting; the meter applies it as its setup page does
"""
import struct
import zlib
from collections import namedtuple

T_START, T_DATA, T_END, T_ABORT, T_STATUS, T_ANSWER = 1, 2, 3, 4, 5, 0x81
T_LIST, T_READ, T_CHUNK, T_DELETE, T_INFO, T_FORMAT, T_GET, T_PUT, T_ANSWER2 = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x82
T_UPDMODE, T_LEAVE = 0x18, 0x19                     # restart into update mode; leave the page Ld (firmware F-1.17, IMP-47)
FORMAT_WORD = b'FORMAT'      # the only payload FORMAT accepts (ble/bftsd.s)
DIAG_NAMES = ['failed card sessions of the transfer', 'last card failure (step << 8 | FatFs result)',
              'failed disk_read / disk_write since power-on', 'their op | reason << 8', 'SDIO_STA', 'sd_transfer_error',
              'sd_wait_write result']
MAX_PAYLOAD = 232
STATUS_TEXT = {0: 'accepted', 1: 'CRC wrong', 2: 'not the expected packet', 3: 'not allowed now', 4: 'START refused (size)',
               5: 'beyond the announced size', 0x11: 'card could not be written', 0x12: 'length or CRC-32 wrong',
               0x13: 'not an application image', 0x14: 'copy to EEVBlog.bin failed', 0x15: 'EEVBlog.bin read back differs',
               0x16: 'the received file could not be read back'}
MIN_SIZE, MAX_SIZE = 0x124, 0x4C000     # firmware limit (firmware/link/121gw.ld)
CARD_STEP = {1: 'open', 2: 'seek', 3: 'write', 4: 'short write (card full?)', 5: 'close', 6: 'read back'}

# 0x82 answers
S_OK, S_NOT_ALLOWED, S_NOT_FOUND, S_NAME, S_ARG, S_PROTECTED, S_CARD = 0, 3, 0x20, 0x21, 0x22, 0x23, 0x24
STATUS2_TEXT = {0: 'ok', 3: 'not allowed now', 0x20: 'not found', 0x21: 'name refused', 0x22: 'argument or value refused',
                0x23: 'protected file', 0x24: 'card error'}
CARD_STEP2 = {1: 'open', 2: 'seek', 3: 'read', 4: 'delete', 5: 'getfree / close'}
CHUNK = 232                                     # data bytes of a CHUNK answer
READ_MAX = 8192                                 # largest READ
NAME_MAX = 63
LIST_END = 0x8000                               # LIST field flag: end of the directory reached
NAME_CUT = 0x80                                 # LIST attribute bit: a name above 63 bytes was cut
Answer2 = namedtuple('Answer2', 'seq status field data')
Entry = namedtuple('Entry', 'size fdate ftime attr name cut')


def card_diag(nxt):
    """The 'next' field of a status 0x11 answer: failed step << 8 | FatFs result of that step."""
    return 'step %s, FatFs result %d' % (CARD_STEP.get(nxt >> 8, nxt >> 8), nxt & 0xFF)


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


def status_packet(index):
    return packet(T_STATUS, 0, bytes([index]))


def explain_diag(values):
    """Readable text for the STATUS values 0..25 (ble/bft.s bft_diag_tab; firmware before F-1.10 has 0..20)."""
    op, reason = values[3] & 0xFF, values[3] >> 8
    why = {(1, 1): 'read: card did not return to the transfer state', (1, 2): 'read: SDIO error flag',
           (1, 3): 'read: data end / DMA end not seen in time', (2, 1): 'write: card did not return to the transfer state',
           (2, 2): 'write: the end-of-write wait ran out of polls (or CMD12 failed)', (2, 3): 'write: SDIO error code'}
    sta = values[4]
    flags = [n for b, n in ((1, 'DCRCFAIL'), (3, 'DTIMEOUT'), (4, 'TXUNDERR'), (5, 'RXOVERR'), (9, 'STBITERR')) if sta >> b & 1]
    text = ('%d failed card sessions in this transfer, last card failure %s; driver: %d failed calls since power-on, last %s,'
            ' SDIO_STA 0x%04X %s, transfer error %d, wait result %d'
            % (values[0], card_diag(values[1]), values[2], why.get((op, reason), 'op %d reason %d' % (op, reason)), sta,
               flags, values[5], values[6]))
    if len(values) >= 13:
        f = values[7]
        text += ('; at the last end-wait timeout: data end flag %d, DMA end flag %d, DMA ch4 flags 0x%X, DMA words left %d,'
                 ' SDIO bytes left %d, SDIO_STA high 0x%04X; %d reads taken on the hardware counters'
                 % (f >> 1 & 1, f & 1, values[8], values[9], values[10], values[11], values[12]))
    if len(values) >= 16:
        r1 = values[13] | values[14] << 16
        states = ('idle', 'ready', 'ident', 'stby', 'tran', 'data', 'rcv', 'prg', 'dis')
        if r1 == 0xFFFFFFFF:
            card = 'no CMD13 answer'
        else:
            st = r1 >> 9 & 0xF
            errs = [n for b, n in ((31, 'OUT_OF_RANGE'), (30, 'ADDRESS_ERROR'), (29, 'BLOCK_LEN_ERROR'),
                                   (28, 'ERASE_SEQ_ERROR'), (27, 'ERASE_PARAM'), (26, 'WP_VIOLATION'), (23, 'COM_CRC_ERROR'),
                                   (22, 'ILLEGAL_COMMAND'), (21, 'CARD_ECC_FAILED'), (20, 'CC_ERROR'), (19, 'ERROR'),
                                   (8, 'READY_FOR_DATA')) if r1 >> b & 1]
            card = 'card status 0x%08X: state %s %s' % (r1, states[st] if st < len(states) else st, errs)
        text += '; last CMD13 before the failure: %s; the polling lasted %d ticks of 10 ms' % (card, values[15])
    if len(values) >= 18:
        text += '; %d failed card start-ups since power-on, last sd_init error %d' % (values[16], values[17])
    if len(values) >= 21:
        text += ('; %d SCR reads since power-on, %d of them with no word and %d with one word read before the block end'
                 % (values[18], values[19], values[20]))
    if len(values) >= 26:
        phase = {0: 'none', 1: 'wait 1 (DMA / transfer end)', 2: "wait 2 (the card's busy)"}.get(values[21], values[21])
        a22 = values[23]
        ans = 'none' if not a22 & 0x8000 else 'SD error %d, %d block(s) written' % (a22 >> 8 & 0x7F, a22 & 0xFF)
        text += ('; last write wait that ran out: %s after %d ticks of 10 ms (the end-wait values above are from that moment);'
                 ' last ACMD22 answer: %s; %d late block(s) confirmed, %d block(s) written again'
                 % (phase, values[22], ans, values[24], values[25]))
    return text


def _name_payload(name):
    raw = name.encode('latin-1') if isinstance(name, str) else bytes(name)
    return bytes([len(raw)]) + raw


def list_packet(seq, start=0):
    return packet(T_LIST, seq, struct.pack('<H', start))


def read_packet(seq, name, offset, length):
    return packet(T_READ, seq, _name_payload(name) + struct.pack('<IH', offset, length))


def chunk_packet(seq, idx):
    return packet(T_CHUNK, seq, struct.pack('<H', idx))


def delete_packet(seq, name):
    return packet(T_DELETE, seq, _name_payload(name))


def info_packet(seq):
    return packet(T_INFO, seq)


def format_packet(seq, word=FORMAT_WORD):
    """FORMAT (0x15): the meter formats its card as exFAT; refused (0x22) unless the payload is exactly FORMAT_WORD,
    and (0x25) without the two-part bootloader.  Everything on the card is gone."""
    return packet(T_FORMAT, seq, word)


def get_packet(seq):
    return packet(T_GET, seq)


def put_packet(seq, setting_id, value):
    return packet(T_PUT, seq, struct.pack('<HB', setting_id, value))


def parse_list(a):
    """(entries, end) of a LIST answer; entries are Entry(size, fdate, ftime, attr, name, cut)."""
    count, end = a.field & 0x7FFF, bool(a.field & LIST_END)
    out, pos = [], 0
    for _ in range(count):
        size, fdate, ftime, attr, nlen = struct.unpack_from('<IHHBB', a.data, pos)
        pos += 10
        out.append(Entry(size, fdate, ftime, attr & 0x7F, a.data[pos:pos + nlen].decode('latin-1'), bool(attr & NAME_CUT)))
        pos += nlen
    if pos != len(a.data):
        raise ValueError('LIST answer: %d bytes of data, entries use %d' % (len(a.data), pos))
    return out, end


def parse_read(a):
    """(bytes read, CRC-32 of them) of a READ answer."""
    return a.field, struct.unpack('<I', a.data)[0]


def parse_info(a):
    """(sectors per cluster, free clusters, total clusters) of an INFO answer."""
    free, total = struct.unpack('<II', a.data)
    return a.field, free, total


def parse_get(a):
    """{setting id: value} of a GET answer."""
    return {struct.unpack_from('<H', a.data, 3 * i)[0]: a.data[3 * i + 2] for i in range(a.field)}


def card_diag2(field):
    """The field of a status 0x24 answer: failed step << 8 | FatFs result."""
    return 'step %s, FatFs result %d' % (CARD_STEP2.get(field >> 8, field >> 8), field & 0xFF)


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
    if not (reset & 1) or not 0x08006000 <= reset < 0x08052000:
        return 'reset vector 0x%08X is not a Thumb address in 0x08006000 .. 0x08051FFF' % reset
    return None


class AnswerParser:
    """Collects bytes from the meter and returns complete answers (status frames and other bytes are skipped): a
    tuple (seq, status, next) for a type 0x81 answer, an Answer2 (seq, status, field, data) for a type 0x82 answer."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf.extend(data)
        out = []
        while True:
            i = self.buf.find(b'\xB5\x5B')
            while i >= 0 and (len(self.buf) < i + 3 or self.buf[i + 2] not in (0x81, 0x82)):
                if len(self.buf) < i + 3:
                    break
                i = self.buf.find(b'\xB5\x5B', i + 1)
            if i < 0:
                del self.buf[:max(0, len(self.buf) - 2)]
                return out
            if len(self.buf) < i + 3:
                del self.buf[:i]
                return out
            kind = self.buf[i + 2]
            if len(self.buf) < i + 6:
                del self.buf[:i]
                return out
            ln = self.buf[i + 5]
            total = 8 + ln
            if len(self.buf) < i + total:
                del self.buf[:i]
                return out
            a = bytes(self.buf[i:i + total])
            ok = crc16(a[2:6 + ln]) == struct.unpack_from('<H', a, 6 + ln)[0]
            if ok and kind == 0x81 and ln == 3:
                out.append((struct.unpack_from('<H', a, 3)[0], a[6], struct.unpack_from('<H', a, 7)[0]))
            elif ok and kind == 0x82 and ln >= 3:
                out.append(Answer2(struct.unpack_from('<H', a, 3)[0], a[6], struct.unpack_from('<H', a, 7)[0], a[9:6 + ln]))
            else:
                del self.buf[:i + 1]
                continue
            del self.buf[:i + total]
