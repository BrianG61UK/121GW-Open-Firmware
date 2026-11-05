"""Bluetooth file transfer to the 121GW SD card: the packet format of the firmware (firmware/src/ble/bft.s, IMP-28).

Used by bt_upload.py (a real meter over Bluetooth LE) and emulator/scripts/test_bt_upload.py (the emulated meter).

Packet to the meter: B5 5B type seq(2) len(1) payload crc16(2), little-endian, CRC-16/CCITT-FALSE over type..payload.
Answer from the meter: B5 5B 81 seq(2) 03 status next(2) crc16(2).
"""
import struct
import zlib

T_START, T_DATA, T_END, T_ABORT, T_STATUS, T_ANSWER = 1, 2, 3, 4, 5, 0x81
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
    """Readable text for the STATUS values 0..20 (ble/bft.s bft_diag_tab)."""
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
    return text


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
