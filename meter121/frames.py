"""Frames the 121GW sends over its Bluetooth link, reassembled from the notification chunks.

The meter's Bluetooth module passes the USART2 byte stream through unchanged, split into notifications of any length.
Frames on that stream (analysis/ble_packet.md of the firmware repository, sections 3 and 6; the firmware's
FEATURES.md 2.10 and 2.11):

    start  length  frame                                  check
    F2     19      status frame (the reading)             XOR of all 19 bytes = 0
    F4     5       echo of a key frame                    the two hex pairs equal
    F8     15      echo of a set-clock frame              7th hex pair = XOR of the first six
    F6     7       version answer of the fast build       XOR of all 7 bytes = 0
    F7     7       bootloader version answer (F-1.03 on)  XOR of all 7 bytes = 0
    F9     20      extended link diagnosis (F-1.15 on):   XOR of all 20 bytes = 0
                   the nine u16 counters of the meter, little-endian (answer to key code 0x95, xdiag_values())
    FA     20      clock measurement (F-1.17 on):         XOR of all 20 bytes = 0
                   the meter's RC run clock measured against its crystal (answer to key code 0x96, mclock_values())
    B5 5B  8+n     answer of the file transfer (2.10)     CRC-16/CCITT-FALSE; type 0x81 = transfer / status answer
                   (transfer.py), type 0x82 = answer of the card and settings requests (card.py, settings.py); the
                   length byte [5] gives n, so both are taken the same way

Bytes inside a binary frame can equal a start byte, so a frame is taken only when its whole length is present and its
check passes; otherwise the first byte is dropped and the search goes on from the next one (resynchronisation, also
after a frame the meter abandoned part way).  The bytes skipped in one run are kept (Reassembler.damaged(), the report's
"damaged pieces").  Standard library only.
"""
import collections
import struct

STATUS, KEY_ECHO, CLOCK_ECHO, VERSION, BL_VERSION, BFT = 'status', 'key_echo', 'clock_echo', 'version', 'bl_version', 'bft'
XDIAG = 'xdiag'
MCLOCK = 'mclock'
MCLOCK_LEN = 20
MCLOCK_NOMINAL_HZ = 4194304             # MSI range 6, the meter's run clock (firmware sys/msical.s)
MCLOCK_BAUD = 19200                     # the meter's serial line to its Bluetooth module
# ck_status of the firmware (macros.inc CK_ST_*): what the last measurement at power-on / wake came to
MCLOCK_STATUS = {0: 'not measured since the meter was switched on', 1: 'measured', 2: 'not measured (the meter was not '
                 'on its RC clock)', 3: 'not measured (the crystal was already running)', 4: 'not measured (the crystal '
                 'did not start)', 5: 'not measured (no signal from the crystal on the timer)', 6: 'measured, but more than '
                 '6 % off: not used', 7: 'measured; the trimmed clock measured worse, the trim was taken back'}
DAMAGED_KEEP = 20                       # skipped runs kept
DAMAGED_BYTES = 32                      # bytes kept of one run (its real length is kept too)
XDIAG_LEN = 20
XDIAG_NAMES = ('bytes received', 'overruns (ORE)', 'noise flags (NE)', 'framing errors (FE)',
               'bytes discarded on the card-session clock', 'rejected key / clock frames',
               'page Ld packets with a wrong CRC', 'answers not queued (transmit queue full)', 'battery voltage (0.01 V)')


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

    def __init__(self, pieces=None):
        """pieces: a deque (maxlen DAMAGED_KEEP) that receives the skipped runs; given, it outlives this reassembler (the
        link makes a new one at every connection and keeps the damaged pieces of all of them)."""
        self.buf = bytearray()
        self.dropped = 0                 # bytes skipped while resynchronising
        self.pieces = pieces if pieces is not None else collections.deque(maxlen=DAMAGED_KEEP)   # (length, first bytes)
        self._run = bytearray()          # the run being skipped: first DAMAGED_BYTES bytes
        self._run_len = 0                # and its real length

    def feed(self, chunk):
        self.buf += chunk
        out = []
        while self.buf:
            got = self._take()
            if got == 'wait':
                break
            if got is None:
                if len(self._run) < DAMAGED_BYTES:
                    self._run.append(self.buf[0])
                self._run_len += 1
                del self.buf[0]
                self.dropped += 1
                continue
            self._end_run()              # a valid frame ends the run of skipped bytes before it
            kind, n = got
            out.append((kind, bytes(self.buf[:n])))
            del self.buf[:n]
        return out

    def _end_run(self):
        if self._run_len:
            self.pieces.append((self._run_len, bytes(self._run)))
        self._run, self._run_len = bytearray(), 0

    def damaged(self):
        """[(length, bytes)] of the last skipped runs, oldest first, the run in progress last; of a run longer than
        DAMAGED_BYTES only the first DAMAGED_BYTES bytes are kept."""
        out = list(self.pieces)
        if self._run_len:
            out.append((self._run_len, bytes(self._run)))
        return out[-DAMAGED_KEEP:]

    def _take(self):
        """(kind, length) of a valid frame at the start of buf, None when there is none, 'wait' when more bytes are
        needed to decide."""
        b = self.buf
        s = b[0]
        if s == 0xF2:
            if len(b) < 19:
                return 'wait'
            return (STATUS, 19) if _xor(b[:19]) == 0 else None
        if s in (0xF6, 0xF7):
            if len(b) < 7:
                return 'wait'
            ok = _xor(b[:7]) == 0 and all(0x20 <= c < 0x7F for c in b[1:6])
            return ((VERSION if s == 0xF6 else BL_VERSION), 7) if ok else None
        if s == 0xF9:
            if len(b) < XDIAG_LEN:
                return 'wait'
            return (XDIAG, XDIAG_LEN) if _xor(b[:XDIAG_LEN]) == 0 else None
        if s == 0xFA:
            if len(b) < MCLOCK_LEN:
                return 'wait'
            return (MCLOCK, MCLOCK_LEN) if _xor(b[:MCLOCK_LEN]) == 0 else None
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
    """The key frame of `code` (0x01..0x08 short, 0x81..0x88 long, 0x90 version, 0x91 update mode, 0x92 bootloader
    version, 0x93 / 0x94 / 0x95 extended diagnosis on / off / counters): F4 and the code as an
    ASCII hex pair twice (analysis/ble_packet.md 6)."""
    h = b'%02X' % code
    return b'\xF4' + h + h


VERSION_REQUEST = key_frame(0x90)
UPDATE_MODE_REQUEST = key_frame(0x91)          # restart into the two-part bootloader's update mode (firmware ble/blcmd.s)
BL_VERSION_REQUEST = key_frame(0x92)           # bootloader version, answered with F7


def bl_version_text(frame):
    """'B-1.00' from F7 'B' '-' d d d x, or 'EEV' for EEVblog's bootloader ('B-EEV')."""
    c = frame[1:6].decode('ascii')
    return 'EEV' if c == 'B-EEV' else c[:3] + '.' + c[3:]


XDIAG_ON_REQUEST = key_frame(0x93)             # extended diagnosis on, counters cleared (firmware F-1.15 on, ble/xdiag.s)
XDIAG_OFF_REQUEST = key_frame(0x94)            # extended diagnosis off
XDIAG_REQUEST = key_frame(0x95)                # the counters, answered with F9 while the diagnosis is on
MCLOCK_REQUEST = key_frame(0x96)               # the clock measurement, answered with FA (firmware F-1.17 on, sys/msical.s)


def xdiag_values(frame):
    """The nine u16 values of an F9 frame, in the order of XDIAG_NAMES."""
    return [frame[1 + 2 * i] | frame[2 + 2 * i] << 8 for i in range(9)]


def mclock_values(frame):
    """The values of an FA frame: {'hz0', 'hz', 'trim', 'status', 'steps', 'brr', 'cal_run', 'cal_now'} (firmware
    ck_send: FA, ck_hz0 u32, ck_hz u32, MSITRIM as a signed byte, status, measurements u16, USART2_BRR u16, MSICAL at the
    end of the measurement, MSICAL at the answer, 2 zero bytes, XOR)."""
    hz0, hz, trim, status, steps, brr, cal_run, cal_now = struct.unpack_from('<IIbBHHBB', frame, 1)
    return {'hz0': hz0, 'hz': hz, 'trim': trim, 'status': status, 'steps': steps, 'brr': brr, 'cal_run': cal_run,
            'cal_now': cal_now}


def mclock_from_status(values):
    """The same values from the page Ld STATUS 49 .. 55 (u16 each: ck_hz0 low / high, ck_hz low / high, MSITRIM |
    status << 8, measurements, USART2_BRR; firmware ble/bft.s bft_diag_tab)."""
    v = list(values)
    trim = v[4] & 0xFF
    return {'hz0': v[0] | v[1] << 16, 'hz': v[2] | v[3] << 16, 'trim': trim - 256 if trim & 0x80 else trim,
            'status': v[4] >> 8, 'steps': v[5], 'brr': v[6]}


def mclock_lines(c):
    """Report lines for the clock values.  The baud on the line is the meter's clock in use / BRR (oversampling by 16):
    the measured clock when there is one, else the nominal value the firmware then computes the BRR from."""
    pct = lambda f, ref: (f - ref) * 100.0 / ref
    out = ['  %-24s %s' % ('result', MCLOCK_STATUS.get(c['status'], 'unknown status %d' % c['status']))]
    if c['hz0']:
        out.append('  %-24s %d Hz (%+.3f %% from %d)' % ('RC clock as found', c['hz0'], pct(c['hz0'], MCLOCK_NOMINAL_HZ),
                                                        MCLOCK_NOMINAL_HZ))
    if c['status'] in (1, 7) and c['hz']:
        out.append('  %-24s %d Hz (%+.3f %%), trim %d, %d measurements' % ('RC clock in use', c['hz'],
                                                                          pct(c['hz'], MCLOCK_NOMINAL_HZ), c['trim'], c['steps']))
    clk = c['hz'] if c['status'] in (1, 7) and c['hz'] else (c['hz0'] or 0)
    if c['brr'] and clk:
        bd = clk / c['brr']
        out.append('  %-24s %.0f (BRR %d; %+.2f %% from %d)' % ('Bluetooth serial baud', bd, c['brr'],
                                                                  pct(bd, MCLOCK_BAUD), MCLOCK_BAUD))
    elif c['brr']:
        out.append('  %-24s BRR %d (clock not measured)' % ('Bluetooth serial baud', c['brr']))
    if 'cal_run' in c:
        out.append('  %-24s 0x%02X after the measurement, 0x%02X now%s' % (
            'MSICAL', c['cal_run'], c['cal_now'], '' if c['cal_run'] == c['cal_now'] else ' (changed since)'))
    return out


def hex_spaced(data):
    """'F2 0A 00': the bytes as hex pairs separated by spaces (a separator that anonymise() does not take for an address)."""
    return ' '.join('%02X' % b for b in data)
