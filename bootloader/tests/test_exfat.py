"""exFAT on the meter, in the emulator (firmware IMP-32, bootloader/DESIGN.md 5 item 7, G4).

    python3 -I bootloader/tests/test_exfat.py [--x6] [REF]   --x6: only X6;  REF: the host build of ChaN's FatFs R0.16 (exFAT configuration)
                                                        used to read the card image (default: the harness's `ref`)

The meter: starter, bootloader and this project's firmware (flash image as tests/test_bootloader.py), a 64 MiB FAT32 card.
  X1 the page For is reached from Ld (SETUP), long SETUP starts the edit ("Fr no"), REL chooses "Fr yE", long SETUP
     formats: "Fr oK", the card holds an exFAT volume (boot sector "EXFAT   "), the host's FatFs mounts it, empty
  X2 logging on the exFAT card (MEM long, about 70 s, MEM long): a YYMMDDnn.csv file with data on the card
  X3 Bluetooth file transfer (page Ld) of the firmware image to the exFAT card: EEVBlog.bin of the right size
  X4 card update by the bootloader from the exFAT card (MEM + HOLD at power-on, SETUP): " Good", flash = the image,
     firmware mark, the firmware runs
  X5 without the two-part bootloader (EEVblog's bootloader area empty of a mark) the page For is not offered
  X6 FORMAT over Bluetooth (request 0x15 on the page Ld, ble/bftsd.s): a FAT32 card with a file is formatted: status 0,
     an empty exFAT volume, LIST over Bluetooth answers no entries
  X7 X6 with one block of the format programmed for 0.9 s, longer than the write wait (firmware IMP-40: the block is
     confirmed with ACMD22); the format completes (--x6 runs X6 and X7 alone)
The data EEPROM is unchanged.
"""
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.dont_write_bytecode = True
sys.path[:0] = [HERE]
import test_bootloader as X                          # noqa: E402

T, U, B, btft = X.T, X.U, X.B, X.btft
REF = os.path.normpath(os.path.join(ROOT, '..', 'fatfs16', 'harness_x', 'ref'))
ADDR_ITEM = 0x20008037


def ref(img, lines):
    """Run the host FatFs on the card image; its output lines."""
    path = os.path.join(T.TMP, 'exf_%d.txt' % os.getpid())
    open(path, 'w').write('\n'.join(lines) + '\n')
    out = subprocess.run([REF, img, path], capture_output=True, text=True, timeout=120)
    return out.stdout.split('\n')


def listing(img):
    out = ref(img, ['mount', 'opendir -'] + ['readdir'] * 12)
    names = []
    for l in out:
        if l.startswith('readdir 0  '):                # empty name: end of the directory
            break
        p = l.split()
        if len(p) >= 4 and p[0] == 'readdir' and p[1] == '0' and p[2] != '0':
            names.append((p[2], int(p[3])))
    return out[0] if out else '', names


def sub(e):
    return T.sub_text(e)


def to_page(e, item_before):
    e.m.uc.mem_write(ADDR_ITEM, bytes([item_before]))
    T.press(e, 'SETUP', gap=0.6)


def vbr_of(card):
    """The volume boot sector of the card image: behind the MBR when f_mkfs made a partition, else sector 0."""
    with open(card, 'rb') as f:
        sec = f.read(512)
    lba = struct.unpack_from('<I', sec, 0x1C6)[0] if sec[0x1FE:0x200] == b'\x55\xAA' and sec[3:11] != b'EXFAT   ' else 0
    with open(card, 'rb') as f:
        f.seek(lba * 512)
        return f.read(512)


def x6(slow=False):
    print('X7 FORMAT over Bluetooth with one slow block (0.9 s busy, IMP-40)' if slow else 'X6 FORMAT over Bluetooth')
    card6 = X._card_with(b'')                          # FAT32 card with EEVBlog.bin on it
    e = X.meter(X.flash_image(), card=card6)
    e.advance(2.0)
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    to_page(e, 21)                                     # bt -> Ld
    T.check('page Ld', T.rd(e, ADDR_ITEM) == 39 and sub(e).upper() == 'LD-BT', sub(e))
    ee6 = bytes(e.m.eeprom)
    first, names = listing(card6)
    T.check('before: a card with files', names != [], '%r %r' % (first, names))
    link = U.Link(e)
    if slow:
        e.sdcard.faults['write_slow'] = 1             # one block of f_mkfs keeps the card busy longer than the write wait
    t0 = T.now(e)
    a = link.send(btft.format_packet(1), timeout=120.0)
    took = T.now(e) - t0
    T.check('FORMAT answered with status 0 (%.1f s emulated)' % took, isinstance(a, btft.Answer2) and a.status == 0
            and a.seq == 1, repr(a))
    vbr = vbr_of(card6)
    T.check('the card holds an exFAT volume', vbr[3:11] == b'EXFAT   ', repr(vbr[3:11]))
    first, names = listing(card6)
    T.check('the host FatFs mounts it, nothing on it', first == 'mount 0' and names == [], '%r %r' % (first, names))
    a = link.send(btft.list_packet(2, 0), timeout=30.0)
    ents, end = btft.parse_list(a) if isinstance(a, btft.Answer2) and a.status == 0 else (None, None)
    T.check('LIST over Bluetooth after the format: no entries, end flag', ents == [] and end is True, repr(a))
    T.check('data EEPROM unchanged', bytes(e.m.eeprom) == ee6)
    if slow:
        T.check('the slow block was met', e.sdcard.faults['write_slow'] == 0)
        v = []
        for i in range(21, 26):
            r = link.send(btft.status_packet(i), timeout=10.0)
            v.append(r[2] if isinstance(r, tuple) and r[1] == 0 else None)
        T.check("STATUS 21..25: wait 2 (the card's busy) ran out, ACMD22 answered 1 block, 1 late block, 0 written again",
                v[0] == 2 and v[1] is not None and v[1] >= 60 and v[2] == 0x8001 and v[3] == 1 and v[4] == 0, repr(v))


def main(argv):
    global REF
    only6 = '--x6' in argv                             # X6 alone (the format over Bluetooth)
    argv = [a for a in argv if a != '--x6']
    if argv:
        REF = argv[0]
    if only6:
        x6()
        x6(slow=True)
        print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
        return 1 if T.fails else 0
    card = X._card_with(b'')                           # FAT32 card (an empty EEVBlog.bin on it)

    print('X1 format as exFAT from the page For')
    e = X.meter(X.flash_image(), card=card)
    e.advance(2.0)
    e.command({'dial': 2})
    e.advance(3.0)
    to_page(e, 39)                                     # Ld -> For
    T.check('page For after Ld ("Fr no")', T.rd(e, ADDR_ITEM) == 40 and sub(e).upper() == 'FR NO',
            'item %d sub %r' % (T.rd(e, ADDR_ITEM), sub(e)))
    T.long_press(e, 'SETUP')                           # edit
    T.press(e, 'REL')                                  # yes
    seen = {t[1].upper() for t in (T.DEC.text(e.snapshot()['lcd']) for _ in range(1))}
    for _ in range(6):                                 # the edited value blinks: sample over 1.5 s
        e.advance(0.25)
        seen.add(sub(e).upper())
    T.check('"Fr yE" chosen (blinking)', 'FR YE' in seen, repr(seen))
    T.long_press(e, 'SETUP')                           # confirm: format
    for _ in range(100):
        e.advance(0.2)
        if sub(e).upper() in ('FR OK',) or sub(e).upper().startswith('FRE'):
            break
    T.check('"Fr oK" after the format', sub(e).upper() == 'FR OK', repr(sub(e)))
    with open(card, 'rb') as f:
        sec = f.read(512)
    mbr_lba = struct.unpack_from('<I', sec, 0x1C6)[0] if sec[0x1FE:0x200] == b'\x55\xAA' and sec[3:11] != b'EXFAT   ' else 0
    with open(card, 'rb') as f:
        f.seek(mbr_lba * 512)
        vbr = f.read(512)
    T.check('the card holds an exFAT volume', vbr[3:11] == b'EXFAT   ', repr(vbr[3:11]))
    first, names = listing(card)
    T.check('the host FatFs mounts it, nothing on it', first == 'mount 0' and names == [], '%r %r' % (first, names))

    print('X2 logging on the exFAT card')
    e.command({'dial': 2})
    e.advance(2.0)
    T.long_press(e, 'MEM')
    e.advance(70.0)
    T.long_press(e, 'MEM')
    e.advance(3.0)
    first, names = listing(card)
    csv = [(n, s) for n, s in names if n.lower().endswith('.csv') and len(n) == 12]
    T.check('a YYMMDDnn.csv with data', len(csv) == 1 and csv[0][1] > 100, repr(names))

    print('X3 Bluetooth file transfer to the exFAT card')
    e.command({'dial': 2})
    e.advance(2.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    to_page(e, 21)                                     # bt -> Ld
    T.check('page Ld', T.rd(e, ADDR_ITEM) == 39 and sub(e).upper() == 'LD-BT', sub(e))
    link = U.Link(e)
    a = U.send_file(link, X.APP)
    e.advance(0.5)
    T.check('END status 0, "Ld oK"', a is not None and a[1] == 0, repr(a))
    first, names = listing(card)
    T.check('EEVBlog.bin of the image size on the card', ('EEVBlog.bin', len(X.APP)) in names
            or ('EEVBLOG.BIN', len(X.APP)) in names, repr(names))
    ee0 = e.ee0

    print('X4 card update by the bootloader from the exFAT card')
    old = X.APP[:-16] + b'OLD FIRMWARE....'
    e = X.meter(X.flash_image(app=old), keys=('MEM', 'HOLD'), card=card)
    e.advance(1.0)
    X.release(e)
    e.advance(0.5)
    T.press(e, 'SETUP', hold=0.3, gap=0.2)
    shown = set()
    for _ in range(300):
        e.advance(0.1)
        shown.add(X.texts(e)[0])
        if 0x08006000 <= e.m.pc < 0x08052000:
            break
    T.check('" Good" shown', ' 9ooD' in shown, repr(sorted(shown)))
    T.check('flash = the image, firmware mark', X.flash(e, 0x08006000, len(X.APP)) == X.APP
            and X.flash(e, B.FW_MARK, 20) == X.fw_mark(X.APP))
    T.check('the firmware runs', X.app_running(e))
    T.check('data EEPROM unchanged', bytes(e.m.eeprom) == ee0)

    print('X5 without the two-part bootloader: no page For')
    f = bytearray(X.flash_image())
    f[B.MARK - 0x08000000:B.MARK - 0x08000000 + 20] = bytes(20)    # no bootloader mark
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = X._card_with(b''), 64
    e = T.make(X.IMAGE_PATH)                           # direct boot of the firmware, the flash as given
    e.m.uc.mem_write(0x08000000, bytes(f[:0x6000]))
    e.advance(2.0)
    e.command({'dial': 2})
    e.advance(3.0)
    to_page(e, 39)
    T.check('Ld -> rEL (item 22)', T.rd(e, ADDR_ITEM) == 22, 'item %d' % T.rd(e, ADDR_ITEM))

    x6()
    x6(slow=True)

    if T.fails:
        print('FAILED: %d checks' % len(T.fails))
        return 1
    print('exFAT: all checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
