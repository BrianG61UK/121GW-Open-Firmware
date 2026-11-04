"""Induced emulator test of the Bluetooth file transfer to the SD card (production image, DESIGN.md 10 IMP-28,
FEATURES.md 2.10).

    python -I emulator/scripts/test_bt_upload.py [image] [--full]      default firmware/build/EEVBlog.bin

A 64 MiB FAT32 card image holds an old EEVBlog.bin.  Bluetooth on (long PEAK), SETUP page Ld (item 39, after bt).  The
host side is emulator/tools/btft.py; its packets go into the emulated USART2 at 19200 baud and the answers are read from
what the meter transmits.  The file sent is the first 20000 bytes of the image under test (three card writes of the 8 KiB
collection buffer; --full sends the whole image).
  T1 page and link: bt -> Ld ("Ld-bt"); no status frames while the page is shown.
  T2 refusals: START with a size below the vector table: status 4; DATA before START: status 3; a packet with a wrong
     CRC: status 1.
  T3 transfer: START, every DATA accepted ("Ld nn" shown meanwhile), one packet sent twice (accepted, not stored again),
     one packet skipped (status 2 with the packet expected), one packet cut short (dropped after 200 ms without a byte,
     the full packet after it is accepted), 3 card write faults injected before packet 30 (the write is repeated),
     2 card read faults injected during the check (repeated in new sessions), END: status 0 and "Ld oK"; the card then holds EEVBlog.bin
     equal to the file sent and no BTLOAD.TMP (deleted after the checked copy).
  T4 a file that is not an application image (initial SP 0): END status 0x13 ("LdE 3") and EEVBlog.bin unchanged.
  T5 leaving the page: status frames again.
  T6 (new card) a copy that fails in every attempt: the card has free space for BTLOAD.TMP but not for the copy as
     well, so each of the 3 attempts ends with a short write; END status 0x14 ("LdE 4"), the EEVBlog.bin that was begun
     is deleted (the bootloader finds no file and erases nothing, FEATURES.md 2.10) and BTLOAD.TMP holds the file.
The helpers are those of test_backlight_timer.py.
"""
import os
import struct
import sys
import tempfile

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import btft  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402
from diff.fat32 import Volume, fat_date, fat_time  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_BLE_ENABLE = 0x2000802B
OLD = b'OLD FIRMWARE FILE\r\n' * 100


class Link:
    def __init__(self, e):
        self.e, self.parser, self.seen = e, btft.AnswerParser(), 0

    def answers(self):
        new = bytes(self.e.ble_rx[self.seen:])
        self.seen = len(self.e.ble_rx)
        return self.parser.feed(new)

    def send(self, pkt, timeout=10.0):
        """Send one packet, return the first answer (seq, status, next) or None after `timeout` emulated seconds."""
        self.answers()
        self.e.usart2.rx_feed(pkt)
        t = 0.0
        while t < timeout:
            self.e.advance(0.02)
            t += 0.02
            got = self.answers()
            if got:
                return got[0]
        return None


def status_frames(e, seconds):
    n0 = len(e.ble_rx)
    e.advance(seconds)
    return bytes(e.ble_rx[n0:]).count(b'\xF2')


def card_files(path):
    out = {}
    with Volume(path) as v:
        for p, ent in v.walk():
            out[p.upper()] = v.read_chain(ent['cluster'], ent['size'])
    return out


def new_card(free_clusters=None):
    """A 64 MiB FAT32 card image with the old EEVBlog.bin; with `free_clusters`, a filler file leaves only that many free."""
    card = os.path.join(tempfile.mkdtemp(prefix='bft_'), 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    with Volume(card, writable=True) as v:
        v.add_file('EEVBLOG.BIN', OLD, fat_date(2026, 11, 1), fat_time(12, 0, 0))
        if free_clusters is not None:
            free = sum(1 for n in range(2, v.clusters + 2) if v.fat(n) == 0)
            v.add_file('FILLER.BIN', bytes((free - free_clusters) * v.csize), fat_date(2026, 11, 1), fat_time(12, 0, 0))
    return card


def open_page(image, card):
    """Emulator with `card`, Bluetooth on, SETUP page Ld shown."""
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')                          # Bluetooth on
    e.advance(1.0)
    T.check('Bluetooth on', T.rd(e, ADDR_BLE_ENABLE) == 1)
    T.check('status frames sent before the page', status_frames(e, 1.0) > 0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('bt -> Ld (item 39), "Ld-bt"', T.rd(e, ADDR_ITEM) == 39 and T.sub_text(e) == 'LD-BT',
            'item %d sub %r' % (T.rd(e, ADDR_ITEM), T.sub_text(e)))
    T.check('no status frames while the page is shown', status_frames(e, 1.5) == 0)
    return e, Link(e)


def send_file(link, data):
    """START, every DATA packet, END; the answer to END (or None)."""
    link.send(btft.start_packet(data))
    for p in btft.data_packets(data):
        link.send(p, timeout=20.0)
    return link.send(btft.packet(btft.T_END, len(btft.data_packets(data))), timeout=120.0)


def run_tests(image, full):
    payload = open(image, 'rb').read()
    if not full:
        payload = payload[:20000]
    card = new_card()
    print('T1 page and link')
    e, link = open_page(image, card)

    print('T2 refusals')
    a = link.send(btft.packet(btft.T_START, 0, struct.pack('<II', 16, 0)))
    T.check('START with 16 bytes: status 4', a is not None and a[1] == 4, repr(a))
    a = link.send(btft.packet(btft.T_DATA, 0, b'x' * 10))
    T.check('DATA before START: status 3', a is not None and a[1] == 3, repr(a))
    bad = bytearray(btft.start_packet(payload))
    bad[-1] ^= 0xFF
    a = link.send(bytes(bad))
    T.check('wrong CRC: status 1', a is not None and a[1] == 1, repr(a))

    print('T3 transfer of %d bytes' % len(payload))
    a = link.send(btft.start_packet(payload))
    T.check('START accepted', a is not None and a[1] == 0, repr(a))
    pkts = btft.data_packets(payload)
    ok, shown, t0 = True, set(), T.now(e)
    for n, p in enumerate(pkts):
        if n == 30:
            link.e.sdcard.faults['write_crc'] = 3    # the card refuses 3 blocks of the next write (OF-59 fault model)
        if n == 10:
            link.e.usart2.rx_feed(p[:20])            # a packet cut short (bytes lost): dropped after 200 ms idle
            link.e.advance(0.5)
        if n == 3:
            a = link.send(pkts[5])                   # skip ahead: the meter names the packet it expects
            T.check('packet 5 instead of 3: status 2, next 3', a is not None and a[1] == 2 and a[2] == 3, repr(a))
        a = link.send(p, timeout=20.0)
        if a is None or a[1] != 0:
            ok = False
            T.check('DATA %d accepted' % n, False, repr(a))
            break
        if n == 7:
            a = link.send(p)                         # the same packet again (as after a lost answer)
            T.check('packet 7 again: accepted (not stored twice)', a is not None and a[1] == 0 and a[2] == 8, repr(a))
        shown.add(T.sub_text(e))
    T.check('every DATA packet accepted (%d)' % len(pkts), ok)
    T.check('the 3 injected card write faults were met (and repeated)', e.sdcard.faults['write_crc'] == 0,
            'left %d' % e.sdcard.faults['write_crc'])
    T.check('percent shown during the transfer', any(s.startswith('LD') and s[2:].strip().isdigit() for s in shown),
            'shown %r' % sorted(shown)[:6])
    link.e.sdcard.faults['read_crc'] = 2             # two card reads fail during the check (repeated in new sessions)
    a = link.send(btft.packet(btft.T_END, len(pkts)), timeout=120.0)
    e.advance(0.3)                                   # the page is redrawn in the next refresh pass
    T.check('END: status 0, "Ld oK"', a is not None and a[1] == 0 and T.sub_text(e) == 'LD oK', '%r sub %r' % (a, T.sub_text(e)))
    T.check('END answer reports the repeated card sessions (> 0 after the injected faults)', a is not None and a[2] > 0,
            repr(a))
    vals = []
    for i in range(7):
        a2 = link.send(btft.status_packet(i))
        vals.append(a2[2] if a2 and a2[1] == 0 else None)
    print('    ' + btft.explain_diag([v or 0 for v in vals]))
    T.check('STATUS 0 = repeated card sessions reported by END (%r)' % (a[2] if a else None), a is not None and vals[0] == a[2],
            repr(vals))
    T.check('STATUS 2: the driver counted failed calls (> 0 after the injected faults)', (vals[2] or 0) > 0, repr(vals))
    T.check('the 2 injected read faults were met', e.sdcard.faults['read_crc'] == 0, 'left %d' % e.sdcard.faults['read_crc'])
    print('    %.1f s emulated for %d bytes (%.0f B/s)' % (T.now(e) - t0, len(payload), len(payload) / (T.now(e) - t0)))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    files = card_files(card)                         # the card model writes every block through to the image file
    T.check('BTLOAD.TMP deleted after the checked copy', '/BTLOAD.TMP' not in files, 'files %r' % sorted(files))

    print('T4 a file that is not an application image')
    junk = bytes(0x200)
    a = send_file(link, junk)
    e.advance(0.3)
    T.check('END: status 0x13, "LdE 3"', a is not None and a[1] == 0x13 and T.sub_text(e) == 'LDE 3',
            '%r sub %r' % (a, T.sub_text(e)))

    print('T5 leaving the page')
    T.press(e, 'SETUP', gap=0.6)
    T.check('Ld -> rEL (item 22)', T.rd(e, ADDR_ITEM) == 22, 'item %d' % T.rd(e, ADDR_ITEM))
    T.check('status frames again', status_frames(e, 1.5) > 0)
    del e
    files = card_files(card)
    img = files.get('/EEVBLOG.BIN')
    T.check('EEVBlog.bin on the card equals the file sent (%d bytes)' % len(payload), img == payload,
            'size %s' % (None if img is None else len(img)))
    T.check('BTLOAD.TMP holds the last transfer (the refused file)', files.get('/BTLOAD.TMP') == junk,
            'files %r' % sorted(files))

    print('T6 a copy that fails in every attempt (card full)')
    need = -(-len(payload) // 512)                   # clusters of BTLOAD.TMP (512-byte clusters on 64 MiB)
    card = new_card(free_clusters=need + 10)         # the copy finds 10 + the 4 of the old EEVBlog.bin: too few
    e, link = open_page(image, card)
    a = send_file(link, payload)
    e.advance(0.3)
    T.check('END: status 0x14, "LdE 4"', a is not None and a[1] == 0x14 and T.sub_text(e) == 'LDE 4',
            '%r sub %r' % (a, T.sub_text(e)))
    files = card_files(card)
    T.check('the EEVBlog.bin that was begun is deleted', '/EEVBLOG.BIN' not in files, 'files %r' % sorted(files))
    T.check('BTLOAD.TMP holds the file sent', files.get('/BTLOAD.TMP') == payload, 'files %r' % sorted(files))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e


def main(argv):
    full = '--full' in argv
    argv = [a for a in argv if a != '--full']
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image, full)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
