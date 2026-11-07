"""SD card file manager of the meter over the file-transfer link (list, read, delete, info), and the sync to a folder.

Host side of the request types 0x10 .. 0x14 of the firmware (firmware/src/ble/bftsd.s).  Like the transfer of transfer.py
it works only while the meter shows the SETUP page Ld (Bluetooth on, logging off, outside calibration mode); outside that
gate the meter does not answer at all, so the request runs into its timeout.

Packet to the meter (as transfer.py): B5 5B type seq(2) len(1) payload crc16(2), little-endian, CRC-16/CCITT-FALSE over
type .. payload.  Answer: B5 5B 82 seq(2) len status(1) field(2) data crc16(2), len = 3 + len(data), data <= 232 bytes.
A request with a wrong CRC-16 gets the type 0x81 answer of the transfer, not a 0x82 answer: the host sees silence and
sends the request again after its timeout.  The meter answers one request at a time (stop and wait).

    0x10 LIST    start:u16                          field = count | 0x8000 when the end of the directory was reached
                                                    data = count x entry: size:u32 fdate:u16 ftime:u16 attr:u8 namelen:u8
                                                    name; bit 7 of attr = the name was cut to 63 bytes; an entry that
                                                    does not fit is not counted, the next start (+= count) returns it
    0x11 READ    namelen:u8 name offset:u32 len:u16 len 1 .. 8192; field = bytes read (0 at or after the end of the file)
                                                    data = CRC-32 (zlib.crc32) of those bytes, u32; they stay staged
    0x12 CHUNK   idx:u16                            field = idx, data = staged bytes idx*232 .. (232, fewer in the last)
    0x13 DELETE  namelen:u8 name                    field 0, no data
    0x14 INFO    -                                  field = sectors per cluster (512 bytes each), data = free clusters:u32
                                                    total clusters:u32 (a card whose free count is unknown is scanned:
                                                    the answer can take seconds)
Statuses: 0 accepted, 3 not allowed now, 0x20 not found, 0x21 name refused, 0x22 argument refused, 0x23 protected
(DELETE of cal.bin, EEVBlog.bin, BTLOAD.TMP), 0x24 card error with field = step << 8 | FatFs result (step 1 open,
2 seek, 3 read, 4 delete, 5 getfree / close).
Names: 1 .. 63 bytes out of A-Z a-z 0-9 . _ space -, no "..", no space at either end, no dot at the end; the root
folder only, matched without regard to case.

Resends.  Every request is idempotent except DELETE, so a request with no answer is simply sent again: for CHUNK this
is the resend of that chunk (the data stays staged until the next READ).  A DELETE sent again after an answer was lost
gets "not found", which is taken as done.  The CRC-32 of the staged window is checked by the host after all its chunks
arrived: on a mismatch the chunks of the window are requested again once (a chunk that passed the packet CRC-16 but is
wrong cannot be told apart, so all are fetched again), then the window is staged again (READ repeated) up to
WINDOW_TRIES times, then the transfer stops with an error.  Nothing is written to the local file before its window
checked.

Local safety.  A file is written as <name>.part and renamed to <name> only when complete (os.replace is atomic on the
same folder).  The sync never deletes anything in the local folder.  Names the card reports are used as local file
names only after check_local_name (the card's name rules, no Windows device names).  Directories, volume labels and
names the meter cut and sizes of 4 GiB and above are not files the meter can read: list() leaves them out and sync() reports them as skipped.
"""
import json
import os
import queue
import struct
import time
import zlib

from . import transfer

# ---------------------------------------------------------------------------------------------------- byte layouts
T_LIST, T_READ, T_CHUNK, T_DELETE, T_INFO, T_FORMAT = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15
FORMAT_WORD = b'FORMAT'                            # the only payload the meter's FORMAT accepts (ble/bftsd.s)
T_ANSWER = 0x82                                    # type byte of every answer to the requests above and to settings.py
ST_OK, ST_NOT_NOW, ST_NOT_FOUND, ST_NAME, ST_ARG, ST_PROTECTED, ST_CARD, ST_NO_FORMAT = 0, 3, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25
STATUS_TEXT = {ST_OK: 'accepted',
               ST_NOT_NOW: 'not allowed now (a firmware transfer, a restart due or a setting being edited on the meter)',
               ST_NOT_FOUND: 'not found on the card', ST_NAME: 'name refused', ST_ARG: 'argument or value refused',
               ST_PROTECTED: 'protected file', ST_CARD: 'card error',
               ST_NO_FORMAT: 'formatting needs the two-part bootloader (EEVblog\'s bootloader cannot read exFAT cards)'}
CARD_STEP = {1: 'open', 2: 'seek', 3: 'read', 4: 'delete', 5: 'getfree / close', 6: 'format'}
NAME_ENCODING = 'latin-1'                          # the meter's names are bytes; the permitted ones are ASCII
CHUNK = transfer.MAX_PAYLOAD                       # 232: bytes of one CHUNK answer (bft.s BFT_MAXPAY)
WINDOW = 8192                                      # largest READ (bft.s BFT_STAGE_LEN)
LIST_END = 0x8000                                  # LIST field flag: the end of the directory was reached
NAME_CUT = 0x80                                    # LIST attr bit 7: a name above 63 bytes was cut to 63
ATTR_DIR, ATTR_VOLUME = 0x10, 0x08                 # FAT attribute bits (not files the meter can read)
MAX_NAME = 63                                      # longest name the meter accepts (and shows)
SECTOR = 512                                       # bytes per sector; INFO gives sectors per cluster


def describe(status, field=0):
    """Readable reason for a status (and, for a card error, the failed step and FatFs result in `field`)."""
    text = STATUS_TEXT.get(status, 'status 0x%02X' % status)
    if status == ST_CARD:
        text += ' (step %s, FatFs result %d)' % (CARD_STEP.get(field >> 8, field >> 8), field & 0xFF)
    return text


def answer_packet(seq, status, field=0, data=b''):
    """An answer frame as the meter sends it (used by the tests' fake meter and by parse_answer's counterpart)."""
    return transfer.packet(T_ANSWER, seq, struct.pack('<BH', status, field) + bytes(data))


def parse_answer(frame):
    """(seq, status, field, data) of a checked answer frame (frames.BFT, type 0x82), else None."""
    if len(frame) < 11 or frame[2] != T_ANSWER or frame[5] < 3:
        return None
    return (struct.unpack_from('<H', frame, 3)[0], frame[6], struct.unpack_from('<H', frame, 7)[0],
            bytes(frame[9:6 + frame[5]]))


def _name(name):
    raw = name.encode(NAME_ENCODING)
    return bytes([len(raw)]) + raw


def list_request(start, most=None):
    """LIST start(2); with `most` (careful mode, firmware F-1.19 on) start(2) max(1): at most that many entries."""
    return struct.pack('<H', start) if most is None else struct.pack('<HB', start, most)


def read_request(name, offset, length):
    return _name(name) + struct.pack('<IH', offset, length)


def chunk_request(idx, size=None):
    """CHUNK idx(2); with `size` (careful mode, firmware F-1.19 on) idx(2) len(1): the bytes idx*size .. ."""
    return struct.pack('<H', idx) if size is None else struct.pack('<HB', idx, size)


def delete_request(name):
    return _name(name)


def parse_list(field, data):
    """([(name, size, fat_date, fat_time, attr, cut)], end) from the field and data of a LIST answer."""
    count, end = field & 0x7FFF, bool(field & LIST_END)
    pos, out = 0, []
    for _ in range(count):
        if pos + 10 > len(data):
            raise CardError('LIST answer cut off')
        size, date, tm, attr, n = struct.unpack_from('<IHHBB', data, pos)
        pos += 10
        if pos + n > len(data):
            raise CardError('LIST answer cut off')
        out.append((data[pos:pos + n].decode(NAME_ENCODING), size, date, tm, attr & 0x7F, bool(attr & NAME_CUT)))
        pos += n
    if pos != len(data):
        raise CardError('LIST answer: %d bytes of data, the entries use %d' % (len(data), pos))
    return out, end


def list_answer(entries, end):
    """(field, data) of a LIST answer (counterpart of parse_list); entries as parse_list gives them."""
    data = b''
    for name, size, date, tm, attr, cut in entries:
        raw = name.encode(NAME_ENCODING)
        data += struct.pack('<IHHBB', size, date, tm, attr | (NAME_CUT if cut else 0), len(raw)) + raw
    return len(entries) | (LIST_END if end else 0), data


def parse_read(field, data):
    """(bytes staged, crc32 of them) from the field and data of a READ answer."""
    if len(data) != 4:
        raise CardError('READ answer has %d bytes of data, expected 4' % len(data))
    return field, struct.unpack('<I', data)[0]


def parse_info(field, data):
    """(free bytes, total bytes) from the field (sectors per cluster) and data of an INFO answer."""
    if len(data) != 8 or not field:
        raise CardError('INFO answer has %d bytes of data and %d sectors per cluster' % (len(data), field))
    free, total = struct.unpack('<II', data)
    return free * field * SECTOR, total * field * SECTOR


def fat_date(d):
    """'YYYY-MM-DD' of a FAT date word (bits 15..9 year-1980, 8..5 month, 4..0 day); '' when it is not a date."""
    y, m, day = 1980 + (d >> 9), (d >> 5) & 15, d & 31
    return '%04d-%02d-%02d' % (y, m, day) if 1 <= m <= 12 and 1 <= day <= 31 else ''


def fat_time(t):
    """'HH:MM:SS' of a FAT time word (bits 15..11 hour, 10..5 minute, 4..0 second/2); '' when it is not a time."""
    h, mi, s = t >> 11, (t >> 5) & 63, (t & 31) * 2
    return '%02d:%02d:%02d' % (h, mi, s) if h < 24 and mi < 60 and s < 60 else ''


# ---------------------------------------------------------------------------------------------------- names
PROTECTED = ('cal.bin', 'eevblog.bin', 'btload.tmp')      # never deleted from here (the firmware answers 0x23 too)
SKIP_SYNC = ('btload.tmp',)                               # transient partial upload of the firmware transfer
MANIFEST = '.121gw-sync.json'
_OK_CHARS = frozenset('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._ -')     # bftsd.s name rules
_DEVICES = {'CON', 'PRN', 'AUX', 'NUL'} | {'COM%d' % i for i in range(1, 10)} | {'LPT%d' % i for i in range(1, 10)}


class CardError(RuntimeError):
    """A card operation failed; `status` is the meter's status when it gave one."""

    def __init__(self, msg, status=None):
        super().__init__(msg)
        self.status = status


def check_name(name):
    """Refuse what the meter refuses (bftsd.s): 1 .. 63 bytes out of A-Z a-z 0-9 . _ space -, no "..", no space at either
    end, no dot at the end (FatFs would drop it and reach another file)."""
    if not isinstance(name, str) or not name:
        raise CardError('name refused: empty', ST_NAME)
    if any(c not in _OK_CHARS for c in name):
        raise CardError('name refused: %r has a character the meter does not take (A-Z a-z 0-9 . _ space -)' % name, ST_NAME)
    if '..' in name or name != name.strip(' ') or name.endswith('.'):
        raise CardError('name refused: %r has "..", a space at an end or a dot at the end' % name, ST_NAME)
    if len(name) > MAX_NAME:
        raise CardError('name refused: longer than %d bytes' % MAX_NAME, ST_NAME)


def is_protected(name):
    return name.lower() in PROTECTED


def check_local_name(name):
    """check_name plus what a file of the local disk cannot be called (Windows device names, the sync's own files)."""
    check_name(name)
    if name == MANIFEST or name.lower().endswith('.part'):
        raise CardError('name %r is used by the sync itself' % name, ST_NAME)
    if name.split('.')[0].upper() in _DEVICES:
        raise CardError('name %r is a device name on Windows' % name, ST_NAME)


# ---------------------------------------------------------------------------------------------------- requests
RETRIES = 4                                        # sends of one request without a usable answer
CHUNK_RETRIES = 8                                  # CHUNK is cheap and idempotent: more sends
WINDOW_TRIES = 3                                   # stagings of one window until its CRC-32 matches
# careful mode (old BLE112 module, firmware F-1.19 on; app.py): small answers, more sends (a damaged byte costs one small
# answer instead of a 232-byte one; GitHub issues 9 and 14)
CAREFUL_LIST_MAX = 4                               # entries of one LIST answer (about 60 bytes with short names)
CAREFUL_CHUNK = 48                                 # bytes of one CHUNK answer
CAREFUL_RETRIES = 12                               # sends of one LIST / CHUNK request
CHUNK_PASSES = 2                                   # fetches of the chunks of one staging
TIMEOUTS = {T_LIST: 15.0, T_READ: 30.0, T_CHUNK: 5.0, T_DELETE: 20.0, T_INFO: 30.0,    # f_getfree scans the FAT
            T_FORMAT: 180.0}                   # f_mkfs writes the whole file system; the meter answers when done


class Client:
    """Stop-and-wait requests over `send` (bytes -> None); the answer frames (type 0x82) are put into `answers`."""

    def __init__(self, send, answers):
        self.send, self.answers = send, answers
        self.seq = 0
        self.cancelled = False

    def request(self, rtype, payload=b'', timeout=None, retries=RETRIES):
        """(status, field, data) of the answer to the request; CardError after `retries` sends without an answer.  The
        status is returned as it is (the caller decides)."""
        timeout = timeout or TIMEOUTS.get(rtype, 10.0)
        self.seq = (self.seq + 1) & 0xFFFF
        seq = self.seq
        pkt = transfer.packet(rtype, seq, payload)
        for _ in range(retries):
            while not self.answers.empty():
                self.answers.get_nowait()
            self.send(pkt)
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                if self.cancelled:
                    raise CardError('cancelled')
                try:
                    frame = self.answers.get(timeout=min(0.5, max(0.01, end - time.monotonic())))
                except queue.Empty:
                    continue
                a = parse_answer(frame)
                if a is None or a[0] != seq:
                    continue
                return a[1:]
        raise CardError('no answer from the meter (is "Ld-bt" still shown on it?)')

    def ok(self, rtype, payload=b'', **kw):
        """(field, data) of an accepted request; CardError with the meter's reason otherwise."""
        status, field, data = self.request(rtype, payload, **kw)
        if status:
            raise CardError(describe(status, field), status)
        return field, data


# ---------------------------------------------------------------------------------------------------- the card
def _atomic_json(path, obj):
    with open(path + '.part', 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1, sort_keys=True)
    os.replace(path + '.part', path)


class Card:
    def __init__(self, client, careful=False):
        """`careful`: the meter has the old BLE112 module and firmware F-1.19 or newer (app.py): LIST in pages of
        CAREFUL_LIST_MAX entries and CHUNK in pieces of CAREFUL_CHUNK bytes, each sent up to CAREFUL_RETRIES times."""
        self.c = client
        self.careful = careful

    def list_entries(self):
        """Every entry of the root directory: [{'name', 'size', 'date', 'time', 'attr', 'cut'}], every page fetched."""
        out, start = [], 0
        while True:
            if self.careful:
                answer = self.c.ok(T_LIST, list_request(start, CAREFUL_LIST_MAX), retries=CAREFUL_RETRIES)
            else:
                answer = self.c.ok(T_LIST, list_request(start))
            entries, end = parse_list(*answer)
            out += [{'name': n, 'size': sz, 'date': fat_date(d), 'time': fat_time(t), 'attr': a, 'cut': cut}
                    for n, sz, d, t, a, cut in entries]
            if end:
                return out
            if not entries or len(out) > 0x7FFF:
                raise CardError('LIST did not advance (%d entries, none new after %d)' % (len(out), start))
            start += len(entries)

    @staticmethod
    def is_file(e):
        """A file the meter can read: not a directory, not a volume label, name not cut, size known (the meter gives
        0xFFFFFFFF for 4 GiB and above)."""
        return not e['attr'] & (ATTR_DIR | ATTR_VOLUME) and not e['cut'] and e['size'] != 0xFFFFFFFF

    def list(self):
        """The files of the card: [{'name', 'size', 'date', 'time'}], every page fetched."""
        return [{k: e[k] for k in ('name', 'size', 'date', 'time')} for e in self.list_entries() if self.is_file(e)]

    def info(self):
        """{'free_bytes', 'total_bytes'} of the card."""
        free, total = parse_info(*self.c.ok(T_INFO))
        return {'free_bytes': free, 'total_bytes': total}

    def format(self):
        """Format the card as exFAT (FORMAT, firmware F-1.09 or newer with the two-part bootloader): everything on it
        is gone.  Sent once (no repetition: the answer comes only when the meter has finished)."""
        status, field, _ = self.c.request(T_FORMAT, FORMAT_WORD, retries=1)
        if status == ST_NOT_NOW:                       # firmware before F-1.09 answers every unknown type with 3
            raise CardError('format refused: the meter\'s firmware is older than F-1.09 and does not know this command '
                            '(update it first: leave the page Ld-bt, the update is offered on a measuring page), or a '
                            'firmware transfer is running', status)
        if status != ST_OK:
            raise CardError('format refused: ' + describe(status, field), status)

    def delete(self, name):
        """Delete a file; refused here for the protected names (the meter refuses them as well)."""
        check_name(name)
        if is_protected(name):
            raise CardError('%s is protected: the meter needs it' % name, ST_PROTECTED)
        pkt = delete_request(name)
        for attempt in range(RETRIES):
            try:
                status, field, _ = self.c.request(T_DELETE, pkt, retries=1)
            except CardError:
                if attempt == RETRIES - 1 or self.c.cancelled:
                    raise
                continue
            if status == ST_NOT_FOUND and attempt:
                return                                   # an earlier send was done, only its answer was lost
            if status:
                raise CardError(describe(status, field), status)
            return

    # -------------------------------------------------------------- reading
    def _chunks(self, n):
        """The n staged bytes, chunk by chunk (each chunk is sent again until an answer of the right length arrives)."""
        buf = bytearray()
        size = CAREFUL_CHUNK if self.careful else CHUNK
        for idx in range((n + size - 1) // size):
            want = min(size, n - idx * size)
            for _ in range(CAREFUL_RETRIES if self.careful else CHUNK_RETRIES):
                try:
                    status, field, data = self.c.request(T_CHUNK, chunk_request(idx, size if self.careful else None),
                                                         retries=1)
                except CardError:
                    if self.c.cancelled:
                        raise
                    continue                                   # no answer: the same chunk is requested again
                if status != ST_OK:
                    raise CardError('chunk %d: %s' % (idx, describe(status, field)), status)
                if field == idx and len(data) == want:
                    buf += data
                    break                                      # a wrong index or length is asked for again
            else:
                raise CardError('chunk %d did not arrive' % idx)
        return bytes(buf)

    def read_window(self, name, offset, length):
        """Up to `length` (<= WINDOW) bytes of the file from `offset`, checked against the CRC-32 the meter gave."""
        if not 0 < length <= WINDOW:
            raise ValueError('window length 1..%d' % WINDOW)
        for _ in range(WINDOW_TRIES):
            n, crc = parse_read(*self.c.ok(T_READ, read_request(name, offset, length)))
            if n == 0:
                return b''
            if n > length:
                raise CardError('READ staged %d bytes, more than the %d asked' % (n, length))
            for _ in range(CHUNK_PASSES):
                data = self._chunks(n)
                if zlib.crc32(data) & 0xFFFFFFFF == crc:
                    return data
        raise CardError('CRC-32 of %s at offset %d did not match after %d tries' % (name, offset, WINDOW_TRIES))

    def read_file(self, name, size, write, progress=None):
        """Read `size` bytes of the file through `write(bytes)` in checked windows; progress(done_bytes) after each."""
        offset = 0
        while offset < size:
            data = self.read_window(name, offset, min(WINDOW, size - offset))
            if not data:
                raise CardError('%s is shorter than listed (%d of %d bytes)' % (name, offset, size))
            write(data)
            offset += len(data)
            if progress:
                progress(offset)
        return offset

    def download(self, name, folder, size=None, progress=None):
        """Copy a card file into `folder` (.part, then renamed); returns the local path.  `size` from LIST when omitted;
        progress(done_bytes, size) after each window."""
        check_local_name(name)
        if size is None:
            match = [f for f in self.list() if f['name'].lower() == name.lower()]
            if not match:
                raise CardError('%s is not on the card' % name, ST_NOT_FOUND)
            size = match[0]['size']
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, name)
        part = path + '.part'
        try:
            with open(part, 'wb') as f:
                self.read_file(name, size, f.write, (lambda done: progress(done, size)) if progress else None)
            os.replace(part, path)
        except BaseException:
            try:
                os.remove(part)
            except OSError:
                pass
            raise
        return path

    # -------------------------------------------------------------- sync
    def sync(self, folder, progress=None):
        """Copy the card's new or changed files into `folder`; {'copied', 'unchanged', 'skipped', 'bytes'}.

        The manifest MANIFEST in the folder records name -> size, date, time of every file copied.  A file is copied when
        it is not in the manifest, when its size, date or time differ, or when the local file is missing or has another
        size than the manifest says.  Local files are never deleted or touched otherwise."""
        os.makedirs(folder, exist_ok=True)
        mpath = os.path.join(folder, MANIFEST)
        try:
            with open(mpath, encoding='utf-8') as f:
                manifest = json.load(f)
            files_done = manifest['files'] if isinstance(manifest, dict) and isinstance(manifest.get('files'), dict) else {}
        except (OSError, ValueError):
            files_done = {}                                # none or damaged: everything is copied again, nothing deleted
        todo, skipped, unchanged = [], [], 0
        for f in self.list_entries():
            if not self.is_file(f):
                skipped.append(f['name'])                  # a directory, a volume label or a cut name
                continue
            try:
                check_local_name(f['name'])
            except CardError:
                skipped.append(f['name'])
                continue
            if f['name'].lower() in SKIP_SYNC:
                skipped.append(f['name'])
                continue
            rec = files_done.get(f['name'])
            local = os.path.join(folder, f['name'])
            same = (isinstance(rec, dict) and (rec.get('size'), rec.get('date'), rec.get('time')) ==
                    (f['size'], f['date'], f['time']) and os.path.isfile(local) and os.path.getsize(local) == f['size'])
            if same:
                unchanged += 1
            else:
                todo.append(f)
        total, base = sum(f['size'] for f in todo), 0
        for f in todo:
            self.download(f['name'], folder, f['size'],
                          (lambda done, _size, b=base: progress(b + done, total)) if progress else None)
            base += f['size']
            files_done[f['name']] = {'size': f['size'], 'date': f['date'], 'time': f['time']}
            _atomic_json(mpath, {'files': files_done})
        return {'copied': len(todo), 'unchanged': unchanged, 'skipped': skipped, 'bytes': total}
