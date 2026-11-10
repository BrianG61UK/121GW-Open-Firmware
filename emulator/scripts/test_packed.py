"""Induced emulator test of packed card reads and packed transfers (firmware F-1.32, DESIGN.md 10 IMP-63).

    python -I emulator/scripts/test_packed.py [image]      default firmware/build/EEVBlog.bin

The page Ld as test_bt_upload.py (card image, Bluetooth on, SETUP page Ld); the host side is emulator/tools/btft.py.
  Z1 packed transfer (START kind 0x80, btft.pack_stream) of the whole image: every DATA accepted, one packet sent
     again after its answer (accepted, its pieces not applied twice), END status 0 ("Ld oK"), EEVBlog.bin equals the
     image; fewer packets than the plain transfer.
  Z2 damaged streams, each a new transfer (packet CRCs right, the stream wrong): a piece whose deflate bytes are
     changed, a piece header whose raw length goes beyond the file, stream bytes after the last piece: status 0x1A,
     "LdE10", EEVBlog.bin unchanged; the next START is accepted again.
  Z3 READZ of a log file as log/csv.s writes it (rows of 45 .. 50 bytes): windows of 4096, method 1, unpacked equal to
     the file, CRC-32 right; the packed share printed.  An incompressible file: method 0, the bytes themselves.
     Offset at the end: 0 bytes, staged 0.  READZ with len 4097: status 0x22.  Every packed window is byte for
     byte the output of the reference model emulator/tools/zdyn.py (dynamic or fixed code, whichever is shorter).
  Z4 READ (0x11) of the same file unchanged (the CRC-32 answer of 4 bytes, 8192 bytes at most).
  Z5 READZ edge cases (zeros, abc repeated, 1 / 2 / 3 bytes, two symbols, machine code, exactly 4096 bytes of a log):
     method and bytes as the model (method 0 when packing is not shorter), unpacked equal to the file; the time to the
     answer printed.
RUN LIMIT: 1 run of this script (2 boots).
"""
import os
import random
import struct
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_bt_upload as U  # noqa: E402
import test_bft_files as F  # noqa: E402
import btft  # noqa: E402
import zdyn  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402
from emu.fat32 import Volume, fat_date, fat_time  # noqa: E402


def log_text(rows):
    """A log file in the layout of log/csv.s: header, then one row a second with a slowly drifting DCV reading."""
    r = random.Random(63)
    out = [b'START,2026/11/09,10:00:00,\r\nID,123456789,\r\nINTERVAL,1,sec,\r\n,,,MAIN,,,SUB-1,,,SUB-2,,,Remark,\r\n'
           b'No. ,Date      ,Time    ,Func. ,Value,Unit,Func. ,Value,Unit,Func. ,Value,Unit,\r\n']
    v = 12.3456
    for i in range(1, rows + 1):
        v += r.uniform(-0.002, 0.002)
        s = 10 * 3600 + i
        out.append(b'%d,2026/11/09,%02d:%02d:%02d,DCV,%07.4f,V,,,,,,,,\r\n' % (i, s // 3600, s // 60 % 60, s % 60, v))
    return b''.join(out)


LOG = log_text(600)
_R = random.Random(7)
NOISE = bytes(_R.randrange(256) for _ in range(3000))
_R2 = random.Random(11)
EDGE = {'ZEROS.BIN': bytes(4096), 'ABC.TXT': b'abc' * 1000, 'ONE.TXT': b'A', 'TWO.TXT': b'AA', 'THREE.TXT': b'AAA',
        'AB.TXT': bytes(_R2.choice(b'ab') for _ in range(4000)), 'IMAGE.BIN': None,    # filled from the image
        'EXACT.CSV': LOG[:4096]}


def new_card():
    card = os.path.join(tempfile.mkdtemp(prefix='bftz_'), 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    with Volume(card, writable=True) as v:
        v.add_file('EEVBLOG.BIN', U.OLD, fat_date(2026, 11, 1), fat_time(12, 0, 0))
        v.add_file('26110900.CSV', LOG, fat_date(2026, 11, 9), fat_time(10, 0, 0))
        v.add_file('NOISE.BIN', NOISE, fat_date(2026, 11, 9), fat_time(10, 0, 0))
        for name, data in EDGE.items():
            v.add_file(name, data, fat_date(2026, 11, 9), fat_time(10, 0, 0))
    return card


def send_stream(link, data, stream, again=None):
    """START (kind 0x80), the stream in DATA packets (packet `again` sent twice), END; (answers, END answer)."""
    a = link.send(btft.start_packet(data, 0x80))
    if a is None or a[1] != 0:
        return [a], None
    pkts = btft.data_packets(stream)
    got = []
    for n, p in enumerate(pkts):
        a = link.send(p, timeout=20.0)
        got.append(a)
        if a is None or a[1] != 0:
            return got, None
        if n == again:
            got.append(link.send(p))
    return got, link.send(btft.packet(btft.T_END, len(pkts)), timeout=120.0)


def run_tests(image):
    data = open(image, 'rb').read()
    EDGE['IMAGE.BIN'] = data[8192:8192 + 4096]                 # machine code: packs to about three quarters
    card = new_card()
    e, link = U.open_page(image, card)

    print('Z1 packed transfer of %d bytes' % len(data))
    stream = btft.pack_stream(data)
    npk, nplain = len(btft.data_packets(stream)), len(btft.data_packets(data))
    got, end = send_stream(link, data, stream, again=5)
    T.check('Z1: every DATA accepted', all(a is not None and a[1] == 0 for a in got), repr([a for a in got if a][-1:]))
    T.check('Z1: packet 5 again accepted (next 6)', got[6] is not None and got[6][1] == 0 and got[6][2] == 6, repr(got[6]))
    T.check('Z1: END status 0, "Ld oK"', end is not None and end[1] == 0 and T.sub_text(e) == 'LD oK',
            '%r %r' % (end, T.sub_text(e)))
    files = U.card_files(card)
    T.check('Z1: EEVBlog.bin equals the image', files.get('/EEVBLOG.BIN') == data)
    T.check('Z1: fewer packets than plain (%d of %d)' % (npk, nplain), npk < nplain * 0.8)

    print('Z2 damaged streams')
    small = data[:9000]
    good = bytearray(btft.pack_stream(small))
    bad_deflate = bytearray(good)
    bad_deflate[4 + 40] ^= 0x5A                      # inside the first piece's deflate bytes
    beyond = bytearray(good)
    p = 0                                            # the last piece header: raw length + 1
    while p + 4 + struct.unpack_from('<H', good, p + 2)[0] < len(good):
        p += 4 + struct.unpack_from('<H', good, p + 2)[0]
    struct.pack_into('<H', beyond, p, struct.unpack_from('<H', good, p)[0] + 1)
    trailing = good + struct.pack('<HH', 1, 3) + b'\x63\x00\x00'
    raw0, plen0 = struct.unpack_from('<HH', good, 0)
    d = zlib.decompressobj(-15)                      # the damaged piece as zlib sees it: an error or a wrong length
    try:                                             # is a stream error (0x1A); a piece of the right length with
        out0 = d.decompress(bytes(bad_deflate[4:4 + plen0]))    # wrong bytes is found by the CRC-32 at END (0x12)
        z_bad = not d.eof or bool(d.unused_data) or len(out0) != raw0
    except zlib.error:
        z_bad = True
    for name, s, want in (('changed deflate bytes', bad_deflate, (0x1A, 'LDE10') if z_bad else (0x12, 'LDE 2')),
                          ('raw length beyond the file', beyond, (0x1A, 'LDE10')),
                          ('bytes after the last piece', trailing, (0x1A, 'LDE10'))):
        got, end = send_stream(link, small, bytes(s))
        last = got[-1] if end is None else end
        e.advance(0.3)                               # the page is redrawn by the main loop after the answer
        T.check('Z2 %s: status 0x%X, "%s"' % (name, want[0], want[1]), last is not None and last[1] == want[0]
                and T.sub_text(e) == want[1], '%r %r' % (last, T.sub_text(e)))
        T.check('Z2 %s: EEVBlog.bin unchanged' % name, U.card_files(card).get('/EEVBLOG.BIN') == data)
    a = link.send(btft.start_packet(small, 0x80))
    T.check('Z2: START accepted again', a is not None and a[1] == 0, repr(a))
    link.send(btft.packet(btft.T_ABORT, 0))

    print('Z3 READZ')
    f = F.Files(link)
    out, packed = b'', 0
    for off in range(0, len(LOG), btft.READZ_MAX):
        a = f.ask(btft.readz_packet, '26110900.CSV', off, btft.READZ_MAX)
        if not isinstance(a, btft.Answer2) or a.status != 0:
            T.check('Z3: READZ at %d' % off, False, repr(a))
            break
        n, crc, staged, method = btft.parse_readz(a)
        raw = f.read_chunks(staged)
        piece = btft.unpack_readz(raw, n, method)
        T.check('Z3: READZ at %d: method 1, CRC-32 right' % off, method == 1 and zlib.crc32(piece) == crc,
                'method %d' % method)
        T.check('Z3: READZ at %d: the bytes of the reference model (zdyn.py)' % off,
                raw == zdyn.compress(LOG[off:off + btft.READZ_MAX])[0], '%d bytes' % len(raw))
        out += piece
        packed += staged
    T.check('Z3: the log file unpacked equals the file', out == LOG, '%d of %d bytes' % (len(out), len(LOG)))
    print('    log file %d bytes, packed %d (%.1f %%)' % (len(LOG), packed, 100.0 * packed / len(LOG)))
    a = f.ask(btft.readz_packet, 'NOISE.BIN', 0, btft.READZ_MAX)
    n, crc, staged, method = btft.parse_readz(a)
    raw = f.read_chunks(staged)
    T.check('Z3: incompressible file: method 0, the bytes themselves', method == 0 and n == staged == len(NOISE)
            and raw == NOISE, 'n %d staged %d method %d' % (n, staged, method))
    a = f.ask(btft.readz_packet, 'NOISE.BIN', len(NOISE), 100)
    T.check('Z3: offset at the end: 0 bytes, staged 0', a.status == 0 and btft.parse_readz(a)[:3:2] == (0, 0), repr(a))
    a = f.ask(btft.readz_packet, 'NOISE.BIN', 0, btft.READZ_MAX + 1)
    T.check('Z3: len 4097 refused (0x22)', a.status == 0x22, repr(a))

    print('Z5 READZ edge cases: every file as it is, packed exactly as the reference model where that is shorter')
    for name, data in EDGE.items():
        t0 = T.now(e)
        a = f.ask(btft.readz_packet, name, 0, btft.READZ_MAX)
        dt = T.now(e) - t0
        if not isinstance(a, btft.Answer2) or a.status != 0:
            T.check('Z5 %s: READZ answered' % name, False, repr(a))
            continue
        n, crc, staged, method = btft.parse_readz(a)
        raw = f.read_chunks(staged) if staged else b''
        model, _kind = zdyn.compress(data)
        want = (1, model) if len(data) >= 2 and len(model) < len(data) else (0, data)
        T.check('Z5 %s (%d bytes): method %d, %d staged, as the model, unpacks to the file' % (name, len(data), method,
                staged), (method, raw) == want and btft.unpack_readz(raw, n, method) == data and n == len(data)
                and zlib.crc32(data) == crc, 'model %d bytes, answer after %.2f s' % (len(model), dt))

    print('Z4 READ unchanged')
    a = f.read('26110900.CSV', 0, 8192)
    n, crc = btft.parse_read(a)
    raw = f.read_chunks(n)
    T.check('Z4: READ 8192: CRC-32 answer of 4 bytes, the bytes', len(a.data) == 4 and raw == LOG[:8192]
            and zlib.crc32(raw) == crc)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
