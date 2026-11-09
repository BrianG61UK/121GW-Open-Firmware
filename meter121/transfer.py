"""Transfers to the meter: the file transfer of the firmware's page Ld (FEATURES.md 2.10, ble/bft.s) and the update
protocol of the two-part bootloader (bootloader/DESIGN.md 6.3, bootloader/src/bl_ble.s).

Packet to the meter: B5 5B type seq(2) len(1) payload crc16(2), little-endian, CRC-16/CCITT-FALSE over type..payload.
Answer: B5 5B 81 seq(2) 03 status next(2) crc16(2).  Stop and wait: every packet is answered before the next one goes.
The transfer works only while the meter shows the SETUP page Ld ("Ld-bt"); there the meter checks length, CRC-32 and the
image header at END and writes the file as EEVBlog.bin.  Timeouts and retries are those of the sender that wrote a
firmware image to a meter over Bluetooth (155 kB in 159 to 172 s, 2026-11-04).

Packed (IMP-63): firmware F-1.32 (page Ld) and bootloader B-1.15 (update mode) take START kind | 0x80: the DATA bytes are
then pack_stream(file), pieces of PIECE raw bytes behind a header raw length u16, packed length u16: packed with zlib
(raw deflate, Z_FINISH) when that gives one final dynamic-code block shorter than the piece (the only block the
meter's inflater takes, firmware/src/sys/zinf.s), else the raw bytes with packed length 0x8000 | raw length; START keeps the size and CRC-32 of the file itself, and the meter checks them
on the unpacked bytes as for a plain transfer.  The firmware image packs to about 64 % (2026-11-09, F-1.31 image).
"""
import queue
import struct
import time
import zlib

from .frames import crc16

T_START, T_DATA, T_END, T_STATUS = 1, 2, 3, 5
T_LEAVE = 0x19                                   # leave the page Ld as a SETUP press does (firmware F-1.17, ble/bft.s)
MAX_PAYLOAD = 232
PACKED = 0x80                                    # START kind bit 7: the DATA bytes are the packed stream
PIECE = 2048                                     # raw bytes of one piece (bft.s BFT_ZRAW_MAX, bl_ble.s ZRAW_MAX)
PIECE_PACK_MAX = 2064                            # packed bytes of one piece the meter takes
FINAL_DYNAMIC = 5                                # first 3 bits of a piece the meter unpacks: BFINAL 1, BTYPE 2 (zinf.s)
RAW_PIECE = 0x8000                               # packed length flag: the piece is its raw bytes
TIMEOUT_DATA = 20.0
TIMEOUT_END = 120.0
RETRIES = 8
STATUS_TEXT = {0: 'accepted', 1: 'CRC wrong', 2: 'not the expected packet', 3: 'not allowed now', 4: 'size refused',
               5: 'beyond the announced size', 0x11: 'the card could not be written', 0x12: 'length or CRC-32 wrong',
               0x13: 'not an application image', 0x14: 'the copy to EEVBlog.bin failed',
               0x15: 'EEVBlog.bin read back differs', 0x16: 'the received file could not be read back',
               0x17: "the meter does not have one of EEVblog's bootloaders (already replaced?)",
               0x18: 'battery too low for the bootloader install: put in fresh batteries',
               0x19: 'the bootloader install failed (the file or a flash step)',
               0x1A: 'the packed data was damaged (nothing was kept; send the file again)'}
BOOT_STATUS_TEXT = {0: 'accepted', 1: 'CRC wrong', 2: 'not the expected packet', 3: 'not allowed now', 4: 'refused',
                    5: 'beyond the announced size', 0x12: 'length or CRC-32 of the written image wrong',
                    0x13: 'not a firmware image', 0x16: 'flash write or check failed',
                    0x17: 'the packed data was damaged (the meter stays in update mode; send it again)'}
KIND_FIRMWARE, KIND_INSTALL, KIND_BOOTLOADER = 0, 1, 2
BOOT_VERSION_INDEX = 0x80                     # STATUS index answered only by the bootloader (bl_ble.s)
TIMEOUT_START = 30.0                          # the bootloader erases the target before it answers START


class TransferError(Exception):
    pass


def pack_stream(data, piece=PIECE):
    """The packed stream of `data` (module docstring): per piece raw length u16, packed length u16, raw deflate."""
    out = bytearray()
    for p in range(0, len(data), piece):
        raw = data[p:p + piece]
        c = zlib.compressobj(9, zlib.DEFLATED, -11, 9)
        blk = c.compress(raw) + c.flush()             # Z_FINISH: the block ends in its last byte
        if blk[0] & 7 == FINAL_DYNAMIC and len(blk) < len(raw):
            out += struct.pack('<HH', len(raw), len(blk)) + blk
        else:                                         # stored, fixed or several blocks: the raw bytes (flag 0x8000)
            out += struct.pack('<HH', len(raw), RAW_PIECE | len(raw)) + raw
    return bytes(out)


def _packets(stream):
    return [packet(T_DATA, n, stream[i:i + MAX_PAYLOAD]) for n, i in enumerate(range(0, len(stream), MAX_PAYLOAD))]


def new_stats():
    """What a transfer spent its time on (GitHub issue 9: a firmware took 55 minutes instead of 3 over a Mac's link):
    packets of the file, packets sent in all (with repeats), answers that did not come within the timeout and the
    seconds waited for them, answers 'CRC wrong' (the meter got a damaged packet), resynchronisations ('not the
    expected packet'), answers to an earlier packet (late or repeated), the slowest answer, the whole time."""
    return {'packets': 0, 'sends': 0, 'timeouts': 0, 'waited_s': 0.0, 'crc_wrong': 0, 'resync': 0, 'stray': 0,
            'slowest_s': 0.0, 'seconds': 0.0}


def stats_text(st, dropped=None):
    """One line for the page."""
    parts = ['%d packets in %.0f s' % (st['packets'], st['seconds'])]
    if st.get('sent') and st.get('file') and st['sent'] != st['file']:
        parts.append('packed: %d bytes sent for %d (%.0f %%)' % (st['sent'], st['file'], 100.0 * st['sent'] / st['file']))
    repeats = st['sends'] - st['packets']
    parts.append('%d sent again' % repeats if repeats > 0 else 'none sent again')
    if st['timeouts']:
        parts.append('%d answers missing (%.0f s waited for them)' % (st['timeouts'], st['waited_s']))
    if st['crc_wrong']:
        parts.append('%d packets arrived damaged' % st['crc_wrong'])
    if st['resync']:
        parts.append('%d resynchronisations' % st['resync'])
    if st['stray']:
        parts.append('%d late answers' % st['stray'])
    parts.append('slowest answer %.1f s' % st['slowest_s'])
    if dropped:
        parts.append('%d received bytes damaged' % dropped)
    return ', '.join(parts)


def packet(ptype, seq, payload=b''):
    body = struct.pack('<BHB', ptype, seq & 0xFFFF, len(payload)) + bytes(payload)
    return b'\xB5\x5B' + body + struct.pack('<H', crc16(body))


def answer(frame):
    """(seq, status, next) of a checked answer frame (frames.BFT)."""
    if frame[2] != 0x81 or frame[5] != 3:
        return None
    return struct.unpack_from('<H', frame, 3)[0], frame[6], struct.unpack_from('<H', frame, 7)[0]


class Sender:
    """Runs a transfer over `send` (bytes -> None) with the answers put into `answers` (a queue of answer tuples)."""

    def __init__(self, send):
        self.send = send
        self.answers = queue.Queue()
        self.done = 0
        self.total = 0
        self.cancelled = False
        self.stats = new_stats()

    def _ask(self, pkt, seq, timeout):
        st = self.stats
        for _ in range(RETRIES):
            while not self.answers.empty():
                self.answers.get_nowait()
            self.send(pkt)
            st['sends'] += 1
            sent = time.monotonic()
            end = sent + timeout
            answered = False
            while time.monotonic() < end:
                if self.cancelled:
                    raise TransferError('cancelled')
                try:
                    a_seq, status, nxt = self.answers.get(timeout=min(0.5, max(0.01, end - time.monotonic())))
                except queue.Empty:
                    continue
                if status == 1:
                    st['crc_wrong'] += 1
                    answered = True
                    break                                     # CRC wrong: send again
                if a_seq != seq:
                    st['stray'] += 1
                    continue
                st['slowest_s'] = max(st['slowest_s'], time.monotonic() - sent)
                return status, nxt
            if not answered:
                st['timeouts'] += 1
                st['waited_s'] += timeout
        raise TransferError('no answer to packet %d (is "Ld-bt" still shown on the meter?)' % seq)

    def probe(self, timeout=1.5):
        """True when the meter answers a status request, i.e. it shows the page Ld."""
        while not self.answers.empty():
            self.answers.get_nowait()
        self.send(packet(T_STATUS, 0, b'\x00'))
        try:
            self.answers.get(timeout=timeout)
            return True
        except queue.Empty:
            return False

    def status_value(self, index, timeout=2.0):
        """Diagnosis value `index` (STATUS request, type 5; ble/bft.s .Lpk_status, indices 0..20): the "next" field of the
        answer.  The request's seq is the index, which the answer echoes."""
        status, nxt = self._ask(packet(T_STATUS, index, bytes([index])), index, timeout)
        if status:
            raise TransferError('STATUS %d: %s' % (index, STATUS_TEXT.get(status, status)))
        return nxt

    def leave(self, timeout=2.0):
        """Leave the page Ld (LEAVE request, type 0x19, firmware F-1.17 on): the meter answers status 0 and goes to the next
        SETUP page, as a SETUP press would; the readings come back."""
        status, _ = self._ask(packet(T_LEAVE, 0, b''), 0, timeout)
        if status:
            raise TransferError('leave page Ld: %s' % STATUS_TEXT.get(status, status))

    def run(self, data, kind=None, packed=False):
        """Send `data` as EEVBlog.bin, or with kind 1 as the first-install file of the two-part bootloader (firmware
        F-1.03 on: the meter writes it to flash and restarts); `packed` (firmware F-1.32 on): as the packed stream.
        Returns the number of card sessions the meter had to repeat."""
        stream = pack_stream(data) if packed else data
        pkts = _packets(stream)
        self.total, self.done = len(stream), 0
        self.stats = dict(new_stats(), packets=len(pkts) + 2, file=len(data), sent=len(stream))  # START, data, END
        t0 = time.monotonic()
        try:
            return self._run(pkts, data, kind, packed)
        finally:
            self.stats['seconds'] = time.monotonic() - t0

    def _run(self, pkts, data, kind, packed=False):
        start = struct.pack('<II', len(data), zlib.crc32(data) & 0xFFFFFFFF)
        if packed:
            start += bytes([(kind or 0) | PACKED])
        elif kind is not None:
            start += bytes([kind])
        status, _ = self._ask(packet(T_START, 0, start), 0, TIMEOUT_DATA)
        if status:
            raise TransferError('START: %s' % STATUS_TEXT.get(status, status))
        n = 0
        while n < len(pkts):
            status, nxt = self._ask(pkts[n], n, TIMEOUT_DATA)
            if status == 2:
                self.stats['resync'] += 1
                n = nxt                                       # the meter names the packet it expects
                continue
            if status:
                raise TransferError('packet %d: %s' % (n, STATUS_TEXT.get(status, status)))
            n += 1
            self.done = min(self.total, n * MAX_PAYLOAD)
        status, info = self._ask(packet(T_END, len(pkts)), len(pkts), TIMEOUT_END)
        if status in (0x14, 0x15):
            raise TransferError('%s: the card holds the old EEVBlog.bin untouched or none at all; do not use the update keys,'
                                ' send the file again' % STATUS_TEXT[status])
        if status:
            raise TransferError('END: %s' % STATUS_TEXT.get(status, status))
        return info


def boot_version(sender, timeout=1.5):
    """(major, minor, patch) when the meter is in the bootloader's update mode, else None (any other answer or none;
    the firmware's page Ld refuses the index)."""
    while not sender.answers.empty():
        sender.answers.get_nowait()
    sender.send(packet(T_STATUS, 0, bytes([BOOT_VERSION_INDEX])))
    try:
        seq, status, nxt = sender.answers.get(timeout=timeout)
    except queue.Empty:
        return None
    return (nxt >> 8, (nxt >> 4) & 0xF, nxt & 0xF) if status == 0 else None


class BootSender(Sender):
    """The bootloader's update protocol: START (the meter erases, then answers), DATA with two packets in flight, END
    (the meter checks the flash and restarts half a second after its answer)."""

    def run(self, data, kind=KIND_FIRMWARE, version=None, packed=False):
        """`packed` (bootloader B-1.15 on): the DATA packets carry the packed stream."""
        stream = pack_stream(data) if packed else data
        pkts = _packets(stream)
        self.total, self.done = len(stream), 0
        self.stats = dict(new_stats(), packets=len(pkts) + 2, file=len(data), sent=len(stream))  # START, data, END
        t0 = time.monotonic()
        try:
            return self._run_boot(pkts, data, kind | (PACKED if packed else 0), version)
        finally:
            self.stats['seconds'] = time.monotonic() - t0

    def _run_boot(self, pkts, data, kind, version):
        st = self.stats
        start = struct.pack('<IIB', len(data), zlib.crc32(data) & 0xFFFFFFFF, kind)
        if version is not None:
            start += struct.pack('<I', version)
        status, _ = self._ask(packet(T_START, 0, start), 0, TIMEOUT_START)
        if status:
            raise TransferError('START: %s' % BOOT_STATUS_TEXT.get(status, status))
        acked = 0                                     # packets the meter confirmed, in order
        while acked < len(pkts):
            while not self.answers.empty():
                self.answers.get_nowait()
            nxt_send = acked
            inflight = 0
            stalled = False
            while acked < len(pkts) and not stalled:
                while inflight < 2 and nxt_send < len(pkts):
                    self.send(pkts[nxt_send])
                    st['sends'] += 1
                    nxt_send += 1
                    inflight += 1
                waiting = time.monotonic()
                end = waiting + TIMEOUT_DATA
                got = None
                while time.monotonic() < end:
                    if self.cancelled:
                        raise TransferError('cancelled')
                    try:
                        got = self.answers.get(timeout=0.5)
                        break
                    except queue.Empty:
                        continue
                if got is None:
                    st['timeouts'] += 1
                    st['waited_s'] += TIMEOUT_DATA
                    stalled = True                    # no answer: start again from the first unconfirmed packet
                    break
                st['slowest_s'] = max(st['slowest_s'], time.monotonic() - waiting)
                seq, status, nxt = got
                if status == 0 and seq >= acked:
                    # the bootloader takes DATA only in order (bl_ble.s .Lp_data) and names the next packet it expects:
                    # an answer to a later packet confirms the earlier ones too (their answers were lost)
                    new = max(acked + 1, min(nxt, nxt_send))
                    inflight = max(0, inflight - (new - acked))
                    acked = new
                    self.done = min(self.total, acked * MAX_PAYLOAD)
                elif status == 0 and seq < acked:
                    st['stray'] += 1
                    inflight = max(0, inflight - 1)   # the answer to a repeated packet: its slot is free again
                elif status in (1, 2):
                    st['crc_wrong' if status == 1 else 'resync'] += 1
                    stalled = True                    # CRC wrong or out of order: resend from the expected one
                    if status == 2:
                        acked = nxt
                else:
                    raise TransferError('packet %d: %s' % (seq, BOOT_STATUS_TEXT.get(status, status)))
            if stalled:
                time.sleep(0.3)                       # let packets still in flight be answered and dropped
        status, _ = self._ask(packet(T_END, len(pkts)), len(pkts), TIMEOUT_START)
        if status:
            raise TransferError('END: %s' % BOOT_STATUS_TEXT.get(status, status))
        return 0
