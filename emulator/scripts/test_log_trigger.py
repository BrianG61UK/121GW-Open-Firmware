"""Induced emulator test of the logging trigger (production image, FEATURES.md 2.6, DESIGN.md 10 IMP-21).

    python -I emulator/scripts/test_log_trigger.py [image]      default firmware/build/EEVBlog.bin (production build)

DCV with a FAT32 card image; logging started with MEM long; the records counted with log_total (0x20007D38).  Checks:
tr-In with interval 1 (one record per second) and interval 0 (the v2.05 5-per-second path); tr-Ch with interval 0 (the
first record, then one record per change of at least the threshold, none for smaller changes, no fast path); tr-Lt with
interval 0 (a record at each verdict change only); the pages tr -> Ch (with tr-Ch) after HI and Ch -> In -> SEt -> item 0 (IMP-52), and that the saves change only
EEPROM 0x020 bits 2..1 and 0x022.  The helpers are those of test_backlight_timer.py.
"""
import os
import struct
import sys
import tempfile

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402

ADDR_TOTAL = 0x20007D38
ADDR_LOGGING = 0x20007FE1
ADDR_ITEM = 0x20008037


def card():
    d = tempfile.mkdtemp(prefix='logtrig_')
    p = os.path.join(d, 'card.img')
    format_fat32(p, 64 * 1024 * 1024)
    return p


def meter(image, ee):
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card(), 64
    e = T.make(image, {0x1E: 0, **ee})
    e.command({'dial': 2})
    volts(e, 1.0, 3.0)
    return e


def volts(e, v, wait=0.0):
    e.command({'input': {'kind': 'V', 'value': v, 'ac': False}})
    if wait:
        e.advance(wait)


def total(e):
    return struct.unpack('<I', e.m.uc.mem_read(ADDR_TOTAL, 4))[0]


def start(e):
    T.long_press(e, 'MEM')
    e.advance(0.5)
    return T.rd(e, ADDR_LOGGING) == 1


def d(e):
    return struct.unpack('<i', e.m.uc.mem_read(0x20007D64, 4))[0]


def last(e, sym):
    return struct.unpack('<i', e.m.uc.mem_read(sym['log_last'], 4))[0]


def ee_trig(trig, interval, thr=None):
    ee = {0x18: interval >> 8, 0x19: interval & 0xFF, 0x20: trig << 1}
    if thr is not None:
        ee[0x22] = thr
    return ee


def run_tests(image, a_trig, sym):
    print('T1 tr-In (v2.05)')
    e = meter(image, ee_trig(0, 1))
    T.check('logging started', start(e))
    n0 = total(e)
    e.advance(10.0)
    n = total(e) - n0
    T.check('interval 1 s: 9..11 records in 10 s', 9 <= n <= 11, 'records=%d' % n)
    e = meter(image, ee_trig(0, 0))
    start(e)
    n0 = total(e)
    e.advance(4.0)
    n = total(e) - n0
    T.check('interval 0: the v2.05 fast path, 16..20 records in 4 s', 16 <= n <= 20, 'records=%d' % n)

    print('T2 tr-Ch, threshold 50 counts, interval 0')
    e = meter(image, ee_trig(1, 0, 50))
    start(e)
    e.advance(2.0)
    n1 = total(e)
    T.check('the first record of the session', n1 == 1, 'records=%d' % n1)
    e.advance(5.0)
    T.check('steady reading: no more records', total(e) == n1, 'records=%d' % total(e))
    # A reading is the mean of 16 samples, so the second after a step can record a mean that is partly old: the rule is
    # checked against the level actually recorded (log_last), not against the input steps.
    volts(e, 1.0100, 4.0)                            # +100 counts
    T.check('change of 100 counts: recorded', total(e) > n1, 'records=%d' % total(e))
    T.check('settled reading within the threshold of the last record', abs(d(e) - last(e, sym)) < 50,
            'd=%d last=%d' % (d(e), last(e, sym)))
    for v in (1.0120, 1.0050, 1.0300, 1.0310):
        n0, l0 = total(e), last(e, sym)
        volts(e, v, 4.0)
        dv = d(e)
        if abs(dv - l0) >= 50:
            T.check('%.4f V: |%d - last %d| >= 50: recorded' % (v, dv, l0), total(e) > n0, 'records %d -> %d' % (n0, total(e)))
        else:
            T.check('%.4f V: |%d - last %d| < 50: no record' % (v, dv, l0), total(e) == n0, 'records %d -> %d' % (n0, total(e)))

    print('T3 tr-Lt, interval 0')
    e = meter(image, ee_trig(2, 0))
    for item, v in ((28, 1.0), (29, 1.2)):           # limits 1.0 .. 1.2 V
        volts(e, v, 2.0)
        e.m.uc.mem_write(ADDR_ITEM, bytes([item]))
        T.long_press(e, 'SETUP')
        T.press(e, 'REL', gap=0.3)
        T.long_press(e, 'SETUP')
    volts(e, 1.1, 2.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([27]))
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.3)
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    start(e)                                         # logging freezes the range as the test does; mode unchanged
    e.advance(3.0)
    n1 = total(e)
    T.check('inside the limits: no records', n1 == 0, 'records=%d' % n1)
    volts(e, 1.3, 2.0)
    T.check('verdict PASS -> HI: one record', total(e) == n1 + 1, 'records=%d' % total(e))
    e.advance(3.0)
    T.check('staying HI with interval 0: no more', total(e) == n1 + 1, 'records=%d' % total(e))
    volts(e, 1.1, 2.0)
    T.check('back to PASS: one record', total(e) == n1 + 2, 'records=%d' % total(e))

    print('T4 pages')
    e = meter(image, {0x20: 0x09})                   # bits 0 and 3 set: REL percent, 12-hour clock
    e.m.uc.mem_write(ADDR_ITEM, bytes([29]))
    T.press(e, 'SETUP', gap=0.4)
    T.check('HI -> tr: "tr-In" (decoded Tr-1n)', T.rd(e, ADDR_ITEM) == 30 and T.sub_text(e) == 'Tr-1n', 'sub=%r' % T.sub_text(e))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.4)
    T.check('REL: tr-Ch', T.rd(e, a_trig) == 1)
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save changed only 0x020 bits 2..1: 0x09 -> 0x0B', diff == {0x20: (0x09, 0x0B)}, 'diff=%r' % (diff,))
    T.press(e, 'SETUP', gap=0.4)
    T.check('tr-Ch: tr -> Ch "Ch  1"', T.rd(e, ADDR_ITEM) == 31 and T.sub_text(e) == 'Ch  1', 'sub=%r' % T.sub_text(e))
    T.long_press(e, 'SETUP')
    for _ in range(4):
        T.press(e, 'REL', gap=0.3)
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    T.check('Ch 1 -> 5 saved in 0x022', e.m.eeprom[0x22] == 5 and T.sub_text(e) == 'Ch  5', 'ee=%d sub=%r' % (e.m.eeprom[0x22], T.sub_text(e)))
    T.press(e, 'SETUP', gap=0.4)
    T.check('Ch -> In (item 9)', T.rd(e, ADDR_ITEM) == 9)
    T.press(e, 'SETUP', gap=0.4)
    T.check('In -> SEt (item 43; MIN/MAX off: no statistics pages)', T.rd(e, ADDR_ITEM) == 43)
    T.press(e, 'SETUP', gap=0.4)
    T.check('SEt -> item 0', T.rd(e, ADDR_ITEM) == 0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'log_trig'), {'log_last': T.symbol(mp, 'log_last')})
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
