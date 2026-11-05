"""Induced emulator test of the card capacity of a card above 4 GiB (firmware/ORIGINAL_FIRMWARE_ISSUES.md OF-68).

    python -I emulator/scripts/test_sd_capacity.py [IMAGE]          (default firmware/build/EEVBlog.bin)

sd_get_card_info (sd/sdcard.s, v2.05 FUN_08022AE4) stores the capacity of a high-capacity card, (C_SIZE + 1) * 512 KiB,
in the card information record (CardCapacity, u64 at +0x48).  v2.05 multiplied in 32 bits, so a 32 GB card read as
1.72 GiB; disk_ioctl GET_SECTOR_COUNT (sd/diskio.s, IMP-32) hands that value to f_mkfs, which then formats only that much
of the card.  The test starts logging on a FAT32 image of 31 914 983 424 bytes (C_SIZE 60871, a common 32 GB card; the
image file is sparse) and reads the record: it must hold the full size and logging must work.  An image without the fix
holds 1 850 212 352 (the 32-bit remainder).
"""
import os
import struct
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402

ADDR_LOGGING = 0x20007FE1
ADDR_CAPACITY = 0x20007698 + 0x48      # sd_card_info, CardCapacity (u64)
CARD_BYTES = 60872 * 512 * 1024         # C_SIZE 60871


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    print('T 32 GB card (C_SIZE 60871): capacity in the card record, logging')
    d = tempfile.mkdtemp(prefix='sdcap_')
    card = os.path.join(d, 'card.img')
    format_fat32(card, CARD_BYTES)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, CARD_BYTES // (1024 * 1024)
    e = T.make(image, {0x1E: 0, 0x18: 0, 0x19: 1})
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(3.0)
    T.long_press(e, 'MEM')
    e.advance(5.0)
    lo, hi = T.rd(e, ADDR_CAPACITY, 4), T.rd(e, ADDR_CAPACITY + 4, 4)
    cap = lo | hi << 32
    print('  capacity in the card record: %d bytes (%.2f GiB), card %d bytes' % (cap, cap / 2 ** 30, CARD_BYTES))
    T.check('the card record holds the full capacity', cap == CARD_BYTES, '%d' % cap)
    T.check('logging started', T.rd(e, ADDR_LOGGING) == 1)
    if T.rd(e, ADDR_LOGGING):
        T.long_press(e, 'MEM')
        e.advance(5.0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e
    os.remove(card)
    os.rmdir(d)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
