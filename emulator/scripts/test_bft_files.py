"""Induced emulator test of the SD file requests of the Bluetooth link (production image, DESIGN.md 10 IMP-36,
FEATURES.md 2.11 stage 6, firmware/src/ble/bftsd.s).

    python -I emulator/scripts/test_bft_files.py [image]            default firmware/build/EEVBlog.bin

A 64 MiB FAT32 card image holds 34 root files: cal.bin, EEVBlog.bin, BTLOAD.TMP, a 20000-byte file, short 8.3 names and
long file names (LFN entries written by this script; the card model of emu/sdcard.py and diff/fat32.py knows only 8.3
names), one of 70 bytes.  Bluetooth on, SETUP page Ld (item 39).  The host side is emulator/tools/btft.py (request
builders and the parser of the type 0x82 answers); the helpers are those of test_bt_upload.py and test_backlight_timer.py.
  T1 gate: with logging on, with calibration mode on, and with another SETUP page shown, a request gets no answer at
     all (the link belongs to the v2.05 parser, status frames come again); after the condition ends the request is
     answered.  Also: a request with a wrong CRC gets the 0x81 answer (status 1), the unassigned type 0x15 status 3.
  T2 LIST: the whole directory in pages, equal to what was written (names, sizes, dates, attributes, order), a name of
     70 bytes cut to 63 with the cut flag, start beyond the end gives an empty page with the end flag, a wrong payload
     length is refused (0x22).
  T3 READ and CHUNK: 8192 bytes of the big file, CRC-32 equal to the host's, the 36 chunks reassemble to the same bytes;
     an offset in the middle; short read at the end of the file; offset beyond the end (0 bytes); a long name and another
     case; missing file 0x20; names and arguments refused (0x21 / 0x22); CHUNK without staged data and past the end 0x22;
     READ while a firmware transfer is receiving: 3, after ABORT: works.
  T4 DELETE: a short and a long-named file deleted (gone from the card, nothing else changed); a second delete 0x20;
     cal.bin, EEVBlog.bin, BTLOAD.TMP in several spellings, also with a trailing dot or space: 0x23 or 0x21 and still on the
     card; bad names refused (0x21).
  T5 INFO: sectors per cluster, free and total clusters equal to the card image's file allocation table.
  T6 the data EEPROM is unchanged by all of it, and nothing but the one deleted pair of files changed on the card.
"""
import os
import struct
import sys
import tempfile
import zlib
import random

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_bt_upload as U  # noqa: E402
import btft  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402
from diff.fat32 import Volume, fat_date, fat_time  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_LOGGING = 0x20007FE1                            # bft_logging
ADDR_CAL_MODE = 0x2000808A                           # bft_cal_mode
rng = random.Random(121)
BIG = bytes(rng.randrange(256) for _ in range(20000))
CAL = bytes(rng.randrange(256) for _ in range(1500))
OLD = b'OLD FIRMWARE FILE\r\n' * 100
TMP = bytes(rng.randrange(256) for _ in range(700))
LONG70 = 'L' * 66 + '.txt'
LONG_A = 'A long file name with spaces.txt'
LONG_B = 'Measurements 2026-11-04 evening run.csv'
LONG_C = 'MixedCase.Log'
ODD = 'Report (1) #2.txt'                            # characters the requests refuse to name
NAME63 = 'N' * 59 + '.csv'                           # exactly 63 bytes
SMALL = b'small file\r\n' * 7


def lfn_checksum(s11):
    c = 0
    for b in s11:
        c = (((c & 1) << 7) + (c >> 1) + b) & 0xFF
    return c


def lfn_entries(name, s11):
    """The long-name directory entries (last part first) of `name` for the short name `s11` (11 bytes)."""
    chars = [ord(c) for c in name]
    if len(chars) % 13:
        chars.append(0)
    chars += [0xFFFF] * (-len(chars) % 13)
    n = len(chars) // 13
    out = []
    for k in range(n, 0, -1):
        e = bytearray(32)
        e[0] = k | (0x40 if k == n else 0)
        e[11] = 0x0F
        e[13] = lfn_checksum(s11)
        for j, off in enumerate((1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30)):
            struct.pack_into('<H', e, off, chars[(k - 1) * 13 + j])
        out.append(bytes(e))
    return out


def dir_append(v, entries):
    """Append directory entries to the root directory, extending its cluster chain when it is full."""
    rc = v.chain(v.root)
    raw = bytearray(b''.join(v.read_cluster(c) for c in rc))
    end = next((i for i in range(0, len(raw), 32) if raw[i] == 0), len(raw))
    need = end + 32 * len(entries)
    while need > len(raw):
        c = v._free_clusters(1)[0]
        v._set_fat(rc[-1], c)
        v._set_fat(c, 0x0FFFFFFF)
        v._fsinfo_take(1)
        rc.append(c)
        raw += bytes(v.csize)
    raw[end:need] = b''.join(entries)
    for i, c in enumerate(rc):
        v._write_sector(v.data0 + (c - 2) * v.spc, bytes(raw[i * v.csize:(i + 1) * v.csize]))
    v.f.flush()


def put_file(v, name, data, wdate, wtime, serial):
    """Create `name` with `data` in the root; a name that is not an upper-case 8.3 name gets long-name entries."""
    base, _, ext = name.rpartition('.') if '.' in name else (name, '', '')
    is83 = name == name.upper() and 1 <= len(base) <= 8 and len(ext) <= 3 and ' ' not in name and name.count('.') <= 1
    if is83:
        s11 = (base.ljust(8) + ext.ljust(3)).encode('ascii')
        lfn = []
    else:
        s11 = ('LFN%03d~1' % serial).encode('ascii') + ext.upper()[:3].ljust(3).encode('ascii')
        lfn = lfn_entries(name, s11)
    n = -(-len(data) // v.csize)
    cl = v._free_clusters(n) if n else []
    for i, c in enumerate(cl):
        v._write_sector(v.data0 + (c - 2) * v.spc, data[i * v.csize:(i + 1) * v.csize].ljust(v.csize, b'\x00'))
        v._set_fat(c, cl[i + 1] if i + 1 < len(cl) else 0x0FFFFFFF)
    first = cl[0] if cl else 0
    short = s11 + bytes([0x20, 0, 0]) + struct.pack('<HHHHHHHI', wtime, wdate, wdate, first >> 16, wtime, wdate,
                                                    first & 0xFFFF, len(data))
    v._fsinfo_take(len(cl))
    dir_append(v, lfn + [short])


def build_card():
    """The card image and the expected LIST: [(shown name, size, wdate, wtime, data)] in directory order."""
    path = os.path.join(tempfile.mkdtemp(prefix='bftf_'), 'card.img')
    format_fat32(path, 64 * 1024 * 1024)
    files = [('CAL.BIN', CAL), ('EEVBLOG.BIN', OLD), ('BTLOAD.TMP', TMP), ('BIG.BIN', BIG), ('SMALL.TXT', SMALL),
             ('EMPTY.DAT', b''), (LONG_A, b'long name A\r\n' * 30), (LONG_B, b'1,2,3\r\n' * 200), (LONG_C, b'mixed\r\n'),
             (LONG70, b'seventy'), (NAME63, b'sixty-three'), (ODD, b'odd characters')]
    for i in range(22):
        files.append(('F%04d.CSV' % i, bytes((i * 7 + k) & 0xFF for k in range((i * 37) % 700))))
    expect = []
    with Volume(path, writable=True) as v:
        for n, (name, data) in enumerate(files):
            wdate, wtime = fat_date(2026, 11, 1 + n % 28), fat_time(n % 24, (n * 7) % 60, (n * 2) % 60)
            put_file(v, name, data, wdate, wtime, n)
            expect.append((name, len(data), wdate, wtime, data))
    return path, expect


def card_state(path):
    with Volume(path) as v:
        return {p: v.read_chain(e['cluster'], e['size']) for p, e in v.walk()}


class Files:
    """Requests to the meter and the checks on their answers."""

    def __init__(self, link):
        self.link, self.seq = link, 0

    def next_seq(self):
        self.seq += 1
        return self.seq

    def ask(self, build, *args, timeout=30.0):
        """Build and send a request (seq added), return the 0x82 answer after checking that it names the seq."""
        seq = self.next_seq()
        a = self.link.send(build(seq, *args), timeout=timeout)
        if isinstance(a, btft.Answer2) and a.seq != seq:
            T.check('answer names the seq of its request', False, 'seq %d answered %d' % (seq, a.seq))
        return a

    def list_all(self):
        out, start, pages = [], 0, 0
        while pages < 40:
            a = self.ask(btft.list_packet, start)
            if not isinstance(a, btft.Answer2) or a.status != 0:
                return None, pages, a
            ents, end = btft.parse_list(a)
            out += ents
            start += len(ents)
            pages += 1
            if end:
                return out, pages, a
            if not ents:
                return None, pages, a
        return None, pages, None

    def read(self, name, offset, length):
        a = self.ask(btft.read_packet, name, offset, length)
        return a

    def read_chunks(self, nbytes):
        out = b''
        for idx in range(-(-nbytes // btft.CHUNK)):
            a = self.ask(btft.chunk_packet, idx)
            if not isinstance(a, btft.Answer2) or a.status != 0 or a.field != idx:
                return None
            out += a.data
        return out


def status_of(a):
    return a.status if isinstance(a, btft.Answer2) else None


def quiet_packet(build, *args):
    """A request whose bytes contain no 0xF4 / 0xF8 (the v2.05 parser would take them for a key or clock frame)."""
    for seq in range(200, 400):
        p = build(seq, *args)
        if 0xF4 not in p and 0xF8 not in p:
            return p
    raise SystemExit('no quiet packet')


def reopen(e):
    """Back to the page Ld from any other page (as open_page does)."""
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('page Ld shown again', T.rd(e, ADDR_ITEM) == 39, 'item %d' % T.rd(e, ADDR_ITEM))
    e.advance(0.5)


def run_tests(image):
    card, expect = build_card()
    state0 = card_state(card)
    print('T1 page and gate (card with %d files)' % len(expect))
    e, link = U.open_page(image, card)
    eeprom0 = bytes(e.m.eeprom)
    f = Files(link)
    a = f.ask(btft.list_packet, 0)
    T.check('LIST answered on the page Ld: 0x82, status 0', status_of(a) == 0, repr(a))
    for name, addr in (('logging on', ADDR_LOGGING), ('calibration mode on', ADDR_CAL_MODE)):
        e.m.uc.mem_write(addr, bytes([1]))
        e.advance(0.5)
        T.check('%s: status frames come again (the link left the transfer)' % name, U.status_frames(e, 1.5) > 0)
        a = link.send(quiet_packet(btft.list_packet, 0), timeout=2.0)
        T.check('%s: no answer to LIST' % name, a is None, repr(a))
        e.m.uc.mem_write(addr, bytes([0]))
        e.advance(0.6)
        T.check('%s ended: no status frames' % name, U.status_frames(e, 1.0) == 0)
        a = f.ask(btft.list_packet, 0)
        T.check('%s ended: LIST answered' % name, status_of(a) == 0, repr(a))
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    T.press(e, 'SETUP', gap=0.6)                     # past Ld: another page
    item = T.rd(e, ADDR_ITEM)
    T.check('another SETUP page shown (item %d)' % item, item != 39)
    e.advance(0.5)
    a = link.send(quiet_packet(btft.list_packet, 0), timeout=2.0)
    T.check('other page: no answer to LIST', a is None, repr(a))
    reopen(e)
    bad = bytearray(btft.list_packet(7, 0))
    bad[-1] ^= 0xFF
    a = link.send(bytes(bad))
    T.check('wrong CRC: 0x81 answer, status 1', isinstance(a, tuple) and a[1] == 1, repr(a))
    a = link.send(btft.packet(btft.T_FORMAT, 8))
    T.check('FORMAT without its payload: 0x82 status 0x22', status_of(a) == 0x22 and a.seq == 8, repr(a))

    print('T2 LIST')
    ents, pages, last = f.list_all()
    T.check('LIST pages end with the end flag (%d pages)' % pages, ents is not None and pages >= 3, repr(last))
    if ents is not None:
        T.check('entry count %d = files written %d' % (len(ents), len(expect)), len(ents) == len(expect))
        names_ok = sizes_ok = dates_ok = attr_ok = True
        for en, (name, size, wdate, wtime, _) in zip(ents, expect):
            shown = name[:63]
            names_ok &= en.name == shown and en.cut == (len(name) > 63)
            sizes_ok &= en.size == size
            dates_ok &= (en.fdate, en.ftime) == (wdate, wtime)
            attr_ok &= en.attr == 0x20
        T.check('names (short, long, mixed case, 63 and 70 bytes) and their order', names_ok,
                repr([en.name for en in ents][:14]))
        T.check('sizes', sizes_ok)
        T.check('FAT date and time words', dates_ok)
        T.check('attributes (archive)', attr_ok)
        long70 = [en for en in ents if en.name.startswith('LLLL')]
        T.check('the 70-byte name is cut to 63 with the cut flag', len(long70) == 1 and len(long70[0].name) == 63
                and long70[0].cut and not any(en.cut for en in ents if not en.name.startswith('LLLL')), repr(long70))
    a = f.ask(btft.list_packet, 500)
    ents2, end2 = btft.parse_list(a) if status_of(a) == 0 else (None, None)
    T.check('start beyond the end: no entries, end flag', ents2 == [] and end2 is True, repr(a))
    a = link.send(btft.packet(btft.T_LIST, 9, b'\x00'))
    T.check('LIST with a 1-byte payload: 0x22', status_of(a) == 0x22, repr(a))

    print('T3 READ and CHUNK')
    a = f.read('BIG.BIN', 0, 8192)
    T.check('READ 8192 bytes of BIG.BIN: status 0, 8192 read, CRC-32 equal',
            status_of(a) == 0 and btft.parse_read(a) == (8192, zlib.crc32(BIG[:8192])), repr(a))
    got = f.read_chunks(8192)
    T.check('the 36 chunks reassemble to the same 8192 bytes', got == BIG[:8192], 'len %s' % (None if got is None else len(got)))
    a = f.ask(btft.chunk_packet, 36)
    T.check('CHUNK 36 (past the end of the staged data): 0x22', status_of(a) == 0x22, repr(a))
    a = f.read('big.bin', 12345, 8192)
    T.check('READ at 12345, 8192 asked: 7655 bytes (end of file), name in another case',
            status_of(a) == 0 and btft.parse_read(a) == (7655, zlib.crc32(BIG[12345:])), repr(a))
    got = f.read_chunks(7655)
    T.check('their chunks (33, the last 215 bytes)', got == BIG[12345:], 'len %s' % (None if got is None else len(got)))
    a = f.read('BIG.BIN', 30000, 100)
    T.check('READ beyond the end: 0 bytes, CRC 0', status_of(a) == 0 and btft.parse_read(a) == (0, 0), repr(a))
    a = f.read(LONG_A, 5, 40)
    want = (b'long name A\r\n' * 30)[5:45]
    T.check('READ by a long name', status_of(a) == 0 and btft.parse_read(a) == (40, zlib.crc32(want)), repr(a))
    a = f.read('EMPTY.DAT', 0, 100)
    T.check('READ of an empty file: 0 bytes', status_of(a) == 0 and btft.parse_read(a) == (0, 0), repr(a))
    a = f.read('CAL.BIN', 0, 1500)
    T.check('READ of cal.bin is allowed', status_of(a) == 0 and btft.parse_read(a) == (1500, zlib.crc32(CAL)), repr(a))
    a = f.read('NOSUCH.TXT', 0, 10)
    T.check('missing file: 0x20', status_of(a) == 0x20, repr(a))
    a = f.ask(btft.chunk_packet, 0)
    T.check('CHUNK after a failed READ: 0x22 (nothing staged)', status_of(a) == 0x22, repr(a))
    for label, name in (('slash', 'a/b.txt'), ('backslash', 'a\\b.txt'), ('colon', 'a:b.txt'), ('dotdot', 'x..y'),
                        ('only dots', '..'), ('percent sign', 'a%b'), ('asterisk', 'a*b'), ('tilde', 'LFN011~1.CSV'),
                        ('64 bytes', 'x' * 64), ('empty', ''), ('leading space', ' BIG.BIN'), ('trailing space', 'BIG.BIN '),
                        ('trailing dot', 'BIG.BIN.'), ('odd characters', ODD)):
        a = f.read(name, 0, 10)
        T.check('READ name refused (%s): 0x21' % label, status_of(a) == 0x21, repr(a))
    for label, length in (('0 bytes', 0), ('8193 bytes', 8193)):
        a = f.read('BIG.BIN', 0, length)
        T.check('READ %s: 0x22' % label, status_of(a) == 0x22, repr(a))
    a2 = link.send(btft.packet(btft.T_CHUNK, 99, b'\x00'))
    T.check('CHUNK with a 1-byte payload: 0x22', status_of(a2) == 0x22, repr(a2))
    a = link.send(btft.start_packet(bytes(1000)))
    T.check('START of a firmware transfer accepted', isinstance(a, tuple) and a[1] == 0, repr(a))
    a = f.read('BIG.BIN', 0, 100)
    T.check('READ while a transfer is receiving: 3', status_of(a) == 3, repr(a))
    a = link.send(btft.packet(btft.T_ABORT, 50))
    T.check('ABORT', isinstance(a, tuple) and a[1] == 0, repr(a))
    a = f.read('BIG.BIN', 0, 100)
    T.check('READ after ABORT works', status_of(a) == 0 and btft.parse_read(a) == (100, zlib.crc32(BIG[:100])), repr(a))

    print('T4 DELETE')
    a = f.ask(btft.delete_packet, 'SMALL.TXT')
    T.check('DELETE SMALL.TXT: status 0', status_of(a) == 0, repr(a))
    a = f.ask(btft.delete_packet, 'SMALL.TXT')
    T.check('DELETE SMALL.TXT again: 0x20', status_of(a) == 0x20, repr(a))
    a = f.ask(btft.delete_packet, LONG_B)
    T.check('DELETE a long-named file: status 0', status_of(a) == 0, repr(a))
    protected = ('cal.bin', 'CAL.BIN', 'Cal.Bin', 'EEVBlog.bin', 'EEVBLOG.BIN', 'eevblog.BIN', 'btload.tmp', 'BTLOAD.TMP', 'BtLoad.Tmp')
    for name in protected:
        a = f.ask(btft.delete_packet, name)
        T.check('DELETE %s: protected 0x23' % name, status_of(a) == 0x23, repr(a))
    for name in ('cal.bin.', 'CAL.BIN ', 'EEVBLOG.BIN..', 'btload.tmp  '):
        a = f.ask(btft.delete_packet, name)
        T.check('DELETE %r: refused 0x21 (FatFs would strip the end)' % name, status_of(a) == 0x21, repr(a))
    for label, name in (('slash', 'a/b'), ('backslash', 'a\\b'), ('colon', '0:BIG.BIN'), ('dotdot', '..'), ('empty', ''),
                        ('64 bytes', 'x' * 64), ('wildcard', '*.CSV'), ('leading space', ' F0001.CSV')):
        a = f.ask(btft.delete_packet, name)
        T.check('DELETE name refused (%s): 0x21' % label, status_of(a) == 0x21, repr(a))
    a = link.send(btft.packet(btft.T_DELETE, 77, b''))
    T.check('DELETE without payload: 0x22', status_of(a) == 0x22, repr(a))
    ents, pages, last = f.list_all()
    names = [en.name for en in ents] if ents else []
    T.check('LIST after the deletes: the two files are gone, 32 remain', ents is not None and len(ents) == len(expect) - 2
            and 'SMALL.TXT' not in names and LONG_B not in names, 'n=%s' % len(names))

    print('T5 INFO')
    a = f.ask(btft.info_packet)
    with Volume(card) as v:
        free = sum(1 for n in range(2, v.clusters + 2) if v.fat(n) == 0)
        total = v.clusters
        spc = v.spc
    T.check('INFO: sectors per cluster %d, free %d, total %d clusters as in the card image' % (spc, free, total),
            status_of(a) == 0 and btft.parse_info(a) == (spc, free, total), repr(a) + ' ' + (repr(btft.parse_info(a)) if status_of(a) == 0 else ''))
    a = link.send(btft.packet(btft.T_INFO, 60, b'\x01'))
    T.check('INFO with a payload: 0x22', status_of(a) == 0x22, repr(a))

    print('T5b FORMAT refused (EEVblog\'s bootloader, wrong word); the card is checked in T6')
    a = link.send(btft.format_packet(61, b'FORMAX'))
    T.check('FORMAT with another word: 0x22', status_of(a) == 0x22, repr(a))
    a = link.send(btft.format_packet(62, b'FORMAT!'))
    T.check('FORMAT with a longer payload: 0x22', status_of(a) == 0x22, repr(a))
    a = f.ask(btft.format_packet)
    T.check('FORMAT with EEVblog\'s bootloader: 0x25 (EEVblog\'s cannot read exFAT)', status_of(a) == 0x25, repr(a))

    print('T6 the EEPROM and the card')
    T.check('data EEPROM unchanged (%d bytes)' % len(eeprom0), bytes(e.m.eeprom) == eeprom0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    e.advance(0.5)
    del e
    state1 = card_state(card)
    gone = sorted(set(state0) - set(state1))
    T.check('on the card only SMALL.TXT and the long-named file were removed (gone: %r)' % gone,
            gone == ['/LFN007~1.CSV', '/SMALL.TXT'] and all(state1[p] == state0[p] for p in state1),
            repr(sorted(set(state0) ^ set(state1))))
    T.check('cal.bin, EEVBlog.bin and BTLOAD.TMP are byte for byte as written',
            state1.get('/CAL.BIN') == CAL and state1.get('/EEVBLOG.BIN') == OLD and state1.get('/BTLOAD.TMP') == TMP)


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
