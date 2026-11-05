#!/usr/bin/env python3
"""gen_synthetic_eeprom.py - write the SYNTHETIC data-EEPROM image the emulator starts with when no EEPROM is supplied.

    python3 -I emulator/tools/gen_synthetic_eeprom.py OUT.bin [--tables v205_tables.json]

THIS IS NOT THE CALIBRATION OF ANY METER.  It is made up from the nominal values documented below, so that the emulator
runs without anybody's calibration data.  It must never be copied to a meter: do not use it as a cal.bin, and do not
copy a cal.bin that the emulator wrote to a meter's SD card.  The image carries the text "SYNTHETIC ..." at EEPROM
0x480 (a range the firmware never reads, firmware/EEPROM_MAP.md section 4) so that any file made from it can be
recognised.

Layout and meaning of every field: firmware/EEPROM_MAP.md (section numbers below).  The image is 0x500 bytes (EEPROM
offsets 0x000..0x4FF, the range v2.05 and the port access; the rest of the 12 KB data EEPROM is never accessed, section
4).  It is the same layout as a cal.bin plus the user current-zero records at 0x4D0..0x4FF.

Contents
  * Settings (section 4) are written with the values the firmware's own readers fall back to when a byte is blank or
    invalid: rotary memory 0x08..0x0E = 1, 3, 6, 9, 0x18, 0x11, 0x13 (DCV, DCmV, FREQ, OHM, VA, uA, mA positions),
    temperature unit 1 (degC) at 0x10, LCD contrast 14 at 0x1A, buzzer on (1) at 0x1E.  All other settings, the date code
    (0x01..0x02), the serial / ID number (0x03..0x06) and the calibration markers 0x1F and 0x26 stay 0: this is not an
    identified, calibrated unit (the firmware then uses its defaults, e.g. date code 1708, ID 0).
  * Calibration records (section 5): offset 0 and one nominal gain per record, for every record of every mode and range
    in the base table T (section 5.1, read from --tables when given and compared with the documented values).
      - Voltage-code records (all modes except CAP) and the peak record: TYPICAL gains, the mean of the calibration
        of two real meters (two EEPROM images read in 2026), rounded to 3 significant digits.  The two meters agree within
        3 % on every one of these records, so the values stand for a typical unit and copy neither.  The gain sets the
        size of the raw AD1 codes per display count and with it the over-range point: the code is held at the register
        limit 2^23 - 1 (emulator/emu/hy3131.py), which a typical unit reaches at 2^23 / (g * full-scale counts), e.g.
        about 2.2 x full scale in OHM ranges 1..4 and 1.4 x in ranges 5 and 6, as a real meter does (a single nominal
        gain of 83.9 for every record, used before 2026-11-05, put that point at exactly 2 x everywhere).  Offsets
        stay 0: the emulator's calibrated front end builds the signal from the calibration it finds, so offsets change
        only the raw codes, not the readings.
      - CAP records (section 5.3, divisor 1e5): the two real meters differ by up to 27 x here, so no typical value
        exists; g is chosen so that 5000 display counts give a counter high time of
        65536 SYSCLK ticks (ranges 0, 1, 5; ranges 2..4 use X / 100, so their gain is 100 times larger).  Also a design
        choice; the physical capacitance method is not documented (emu/frontend.py _plan_cap).
      - Records with no calibration role are left 0: the frequency reference word 0x104 (the firmware then uses its default
        49 152 050), the PULSE / DUTY record 0x100, the OHM range-6 weight 0x178, the board temperature offset 0x2E0, the AC
        correction words, the user current-zero records (marker 0xA5 absent).
Gains are stored as u32 big-endian = round(g * 1e6) (CAP: g * 1e5), offsets as i32 big-endian (section 5.2).
"""
import json
import struct
import sys

sys.dont_write_bytecode = True

SIZE = 0x500
TYPICAL_GAIN = {                       # mode: (gain per range, VA current-record gain per range or None)
    1: ((60.9, 62.5, 62.6, 62.7), None),
    2: ((62.2, 62.1, 62.3, 622.0), None),
    3: ((6.18, 62.4), None),
    4: ((62.0, 62.0), None),
    5: ((6.19,), None),
    9: ((7.48, 74.9, 75.0, 75.1, 77.0, 123.0, 123.0), None),
    11: ((30.9,), None),
    13: ((62.3, 62.6, 62.3, 62.6), (125.0, 125.0, 125.0, 125.0)),
    14: ((62.3, 62.2, 62.3, 62.2), (126.0, 126.0, 127.0, 127.0)),
    15: ((62.2, 62.1, 60.1, 61.6), (123.0, 123.0, 124.0, 124.0)),
    16: ((125.0, 125.0), None),
    17: ((75.2, 12.6), None),
    18: ((126.0, 126.0), None),
    19: ((75.8, 12.7), None),
    20: ((123.0, 123.0, 124.0), None),
    21: ((73.9, 12.4, 124.0), None),
    22: ((60.9, 62.5, 60.9, 62.5), (75.1, 75.1, 12.6, 12.6)),
    23: ((60.9, 62.5, 60.9, 62.5), (75.8, 75.9, 12.7, 12.7)),
    24: ((60.8, 62.5, 59.2, 62.4), (73.9, 73.9, 124.0, 124.0)),
}
TYPICAL_PEAK_GAIN = 1.04
CAP_H_AT_5000 = 65536                  # CAP counter high time in SYSCLK ticks at 5000 display counts
CAP_COUNTS = 5000

# EEPROM_MAP.md 5.1: base of the records of each mode (index = mode, entry 25 = the peak record)
T = (0x030, 0x070, 0x030, 0x0B0, 0x0D0, 0x0F0, 0x100, 0x100, 0x100, 0x110, 0x120, 0x180, 0x190,
     0x300, 0x340, 0x380, 0x1F0, 0x210, 0x230, 0x250, 0x270, 0x2A0, 0x3C0, 0x400, 0x440, 0x2D0)
# EEPROM_MAP.md 5.3: ranges that have a record, by mode (OHM 7 ranges, CAP 6, VA modes 4, currents as listed)
RANGES = {1: 4, 2: 4, 3: 2, 4: 2, 5: 1, 9: 7, 11: 1, 12: 6, 13: 4, 14: 4, 15: 4, 16: 2, 17: 2, 18: 2, 19: 2,
          20: 3, 21: 3, 22: 4, 23: 4, 24: 4}
VA_MODES = (13, 14, 15, 22, 23, 24)
SETTINGS = {0x08: 1, 0x09: 3, 0x0A: 6, 0x0B: 9, 0x0C: 0x18, 0x0D: 0x11, 0x0E: 0x13, 0x10: 1, 0x1A: 14, 0x1E: 1}
MARK_AT = 0x480
MARK = b'SYNTHETIC EEPROM - NOT A METER CALIBRATION'      # 43 bytes, inside the never-read range 0x480..0x4AF


def cap_gain(rng):
    """Gain of CAP range rng: X = 5000 * g ticks (ranges 0, 1, 5) or high time X / 100 (ranges 2..4)."""
    return CAP_H_AT_5000 * (100 if 2 <= rng <= 4 else 1) / CAP_COUNTS


def build(table=T):
    e = bytearray(SIZE)
    for off, v in SETTINGS.items():
        e[off] = v
    put = lambda a, off, g, div: e.__setitem__(slice(a, a + 8), struct.pack('>iI', off, int(round(g * div))))
    seen = {}
    for mode, n in RANGES.items():
        for r in range(n):
            a = table[mode] + 16 * r
            if mode == 12:
                g, div = cap_gain(r), 1e5
            else:
                g, div = TYPICAL_GAIN[mode][0][r], 1e6
            if a in seen and seen[a] != (mode, g):
                raise SystemExit('record 0x%03X is shared by modes %d and %d with different gains' % (a, seen[a][0], mode))
            seen[a] = (mode, g)
            put(a, 0, g, div)
            if mode in VA_MODES:
                put(a + 8, 0, TYPICAL_GAIN[mode][1][r], div)
    put(table[25], 0, TYPICAL_PEAK_GAIN, 1e6)          # peak record
    e[MARK_AT:MARK_AT + len(MARK)] = MARK
    return bytes(e), len(seen) + 1


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    table = T
    if '--tables' in argv:
        path = argv[argv.index('--tables') + 1]
        args.remove(path)
        doc = json.load(open(path))
        base = 0x08028EE8
        for s in doc['segments']:
            if s['addr'] <= base and base + 52 <= s['addr'] + len(s['hex']) // 2:
                raw = bytes.fromhex(s['hex'])[base - s['addr']:base - s['addr'] + 52]
                got = struct.unpack('<26H', raw)
                if got != T:
                    raise SystemExit('the base table in %s differs from the documented table T (EEPROM_MAP.md 5.1)' % path)
                table = got
                break
        else:
            raise SystemExit('%s does not hold the base table 0x08028EE8' % path)
    if len(args) != 1:
        sys.stderr.write(__doc__)
        return 2
    img, n = build(table)
    with open(args[0], 'wb') as f:
        f.write(img)
    print('gen_synthetic_eeprom: %d records, %d bytes -> %s (SYNTHETIC, not a meter calibration)' % (n, len(img), args[0]))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
