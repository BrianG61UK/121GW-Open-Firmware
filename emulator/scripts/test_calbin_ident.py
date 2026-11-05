"""Induced emulator test of the cal.bin restore check (firmware/DESIGN.md IMP-38, cal/calbin.s calbin_ident_ok).

    python -I emulator/scripts/test_calbin_ident.py [image]      default firmware/build/EEVBlog.bin

The restore of cal.bin (MEM held at power-on, then PEAK and MODE: emulator/diff/scenarios/calbin_load.txt) writes the
file over EEPROM 0x000..0x4AF.  The production image first compares the file's serial (bytes 0x003..0x006, u32 big
endian) with the meter's own (RAM 0x20007D14, loaded at power-on).
  C1 meter serial 12345, file serial 12345, file byte 0x10 changed: restored ("SAvEd", EEPROM 0x10 changed).
  C2 meter serial 12345, file serial 54321 (another meter's file): refused ("-Err-"), EEPROM unchanged.
  C3 meter serial 12345, file serial 0 (an emulator cal.bin): refused, EEPROM unchanged.
  C4 meter without a serial (0), file serial 54321: restored (a meter whose EEPROM was lost can be restored).
  C5 as C1 with MEM held 1.5 s at power-on: restored (OF-67: in v2.05 the long press started logging and MODE could
     not confirm).
C1 and C4 also prove the size check reads the R0.16 file object (FIL + OBJ_OBJSIZE): F-1.04 and F-1.05 read the old
R0.08a offset 0x0C and refused every cal.bin with error 8.
The cards are FAT32 images made with the helpers of test_bft_files.py; the meter helpers are those of
test_backlight_timer.py.
"""
import os
import sys
import tempfile

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
import test_bft_files as F  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402
from diff.fat32 import Volume  # noqa: E402


def serial_bytes(n):
    return {3: n >> 24 & 0xFF, 4: n >> 16 & 0xFF, 5: n >> 8 & 0xFF, 6: n & 0xFF}


def run(image, name, meter_serial, file_serial, expect_restored, hold=0.4):
    print(name)
    ee = bytearray(T.SYNTHETIC)
    for off, v in serial_bytes(meter_serial).items():
        ee[off] = v
    cal = bytearray(ee[:1200])
    for off, v in serial_bytes(file_serial).items():
        cal[off] = v
    cal[0x10] ^= 0x01                                 # a byte the restore must change
    d = tempfile.mkdtemp(prefix='calid_')
    card = os.path.join(d, 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    with Volume(card, writable=True) as v:
        F.put_file(v, 'CAL.BIN', bytes(cal), F.fat_date(2026, 11, 5), F.fat_time(12, 0, 0), 0)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(image, {i: ee[i] for i in range(0x40)})
    before = bytes(e.m.eeprom)
    e.command({'key': 'MEM', 'down': True})          # calbin_load.txt: MEM held at power-on, PEAK = load, MODE
    e.command({'dial': 2})
    e.advance(hold)                                   # C5: held past the long-press time (OF-67)
    e.command({'key': 'MEM', 'down': False})
    e.advance(0.4)
    T.press(e, 'PEAK')
    T.press(e, 'MODE')
    e.advance(8.0)
    after = bytes(e.m.eeprom)
    texts = T.DEC.text(e.snapshot()['lcd'])
    T.check('meter serial read at power-on: %d' % meter_serial, T.rd(e, 0x20007D14, 4) == meter_serial,
            str(T.rd(e, 0x20007D14, 4)))
    if expect_restored:
        T.check('restored: EEPROM 0x000..0x4AF equal to the file', after[:1200] == bytes(cal), 'byte 0x10 %d' % after[0x10])
    else:
        T.check('refused: EEPROM unchanged', after == before, '%d bytes differ' % sum(a != b for a, b in zip(after, before)))
    T.check('nothing beyond 0x4AF changed', after[0x4B0:] == before[0x4B0:])
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    code = T.rd(e, T.symbol(mp, 'calbin_result'))
    print('  display %r, calbin_result %d' % (texts[:2], code))
    T.check('result code %d (0 restored, 10 refused by the serial check)' % code, code == (0 if expect_restored else 10))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run(image, 'C1 same serial', 12345, 12345, True)
    run(image, 'C2 another meter\'s file', 12345, 54321, False)
    run(image, 'C3 a file without a serial (emulator cal.bin)', 12345, 0, False)
    run(image, 'C4 meter without a serial', 0, 54321, True)
    run(image, 'C5 same serial, MEM held 1.5 s at power-on (OF-67: the long press must not start logging)', 12345, 12345,
        True, hold=1.5)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
