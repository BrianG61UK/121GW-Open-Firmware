"""Induced emulator test of the backlight auto-off timer (firmware IMP-07, firmware/FEATURES.md 2.9), production image.

    python3 -I emulator/scripts/test_backlight_timer.py [IMAGE]            the five checks below (about 15 minutes)
    python3 -I emulator/scripts/test_backlight_timer.py --of55 ORIGINAL    the OF-55 evidence run on the original v2.05 image

IMAGE defaults to firmware/build/EEVBlog.bin (the production build, `make` in firmware/); the linker map
firmware/build/121gw.map next to it gives the RAM addresses of pwr_bl_count and pwr_bl_setting.  Needs `unicorn` and
`capstone`.  Every state that would take minutes is put in place instead of waited for: the setting is written into the
EEPROM image before the start (byte 0x017) and the APO countdown 0x20000230 is set to 3.  Emulated time is exact; about 5 minutes of it are
emulated, which takes about three times as long in wall-clock time.

Checks (each prints PASS or FAIL):
  T1 setting 30 s: MODE long press switches the backlight on; it goes off 30..31.6 s after the last key activity; a RANGE
     press 20 s into the countdown restarts it; a dial change restarts it; MODE long press while on switches it off at once
  T2 setting OFF (blank byte): the backlight stays on for 70 s; MODE long press still switches it off
  T3 invalid stored values (0xFF, 101) read as OFF, 100 (99 min) is accepted, the byte is not changed
  T4 SETUP page bL: ten SETUP presses in DCV reach "bLOFF"; REL/PEAK edit; the save writes only EEPROM 0x017; an abandoned
     edit writes nothing; the setting survives a power cycle
  T5 auto power-off and wake with the backlight on: the flag 0x2000807B and PE8 agree after the wake and the first MODE
     long press switches the backlight on (OF-55)
"""
import importlib.util
import os
import re
import struct
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'emulator'))
from app import Emulator  # noqa: E402

_spec = importlib.util.spec_from_file_location('eev_trace', os.path.join(ROOT, 'emulator', 'diff', 'trace.py'))
_trace = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_trace)
DEC = _trace.LcdDecoder()                       # decodes the LCD words into display text ('b' reads as 'B', 'O' as '0')

SYNTHETIC = open(os.path.join(ROOT, 'emulator', 'data', 'synthetic_eeprom.bin'), 'rb').read()
ADDR_FLAG = 0x2000807B                          # backlight flag of the MODE long press (v2.05 RAM)
ADDR_APO = 0x20000230                           # APO countdown (v2.05 RAM, u16)
TMP = os.environ.get('TMPDIR', '/tmp')
fails = []

# Wall-clock guard for every test script that imports these helpers: a script still running after WALL_LIMIT_S seconds
# (EMU_TEST_WALL_S, default 1800, at least 60; it cannot be switched off) prints a FAIL result and ends with status 1.
# A timer thread is used, because an exception raised by a signal handler inside the emulator's callbacks is swallowed.
WALL_LIMIT_S = max(60.0, float(os.environ.get('EMU_TEST_WALL_S', '1800') or 1800))


def _wall_expired():
    print('RESULT FAIL: wall-clock limit of %.0f s reached (EMU_TEST_WALL_S): the test stopped making progress or needs a '
          'longer limit' % WALL_LIMIT_S, flush=True)
    os._exit(1)


_guard = threading.Timer(WALL_LIMIT_S, _wall_expired)
_guard.daemon = True
_guard.start()


def check(name, cond, detail=''):
    print(('PASS ' if cond else 'FAIL ') + name + (('  ' + detail) if detail else ''), flush=True)
    if not cond:
        fails.append(name)


def symbol(map_path, name):
    for line in open(map_path):
        m = re.match(r'\s+0x([0-9a-f]{8})\s+%s$' % re.escape(name), line)
        if m:
            return int(m.group(1), 16)
    raise SystemExit('symbol %s not found in %s' % (name, map_path))


def make(image, patch=None, **kw):
    ee = bytearray(SYNTHETIC)
    for off, v in (patch or {}).items():
        ee[off] = v
    path = os.path.join(TMP, 'bl_test_eeprom_%d.bin' % os.getpid())   # one per process: tests run in parallel
    open(path, 'wb').write(ee)
    return Emulator(app=image, eeprom=path, **kw)


def rd(e, addr, n=1):
    return int.from_bytes(bytes(e.m.uc.mem_read(addr, n)), 'little')


def now(e):
    return e.snapshot()['time_ms'] / 1000.0


def press(e, key, hold=0.15, gap=0.35):
    e.command({'key': key, 'down': True})
    e.advance(hold)
    e.command({'key': key, 'down': False})
    t = now(e)
    e.advance(gap)
    return t                                    # emulated time of the key release


def long_press(e, key):
    return press(e, key, hold=1.0, gap=0.3)


def lit(e):
    return bool(e.snapshot()['backlight'])      # PE8 (None while the meter is unpowered)


def wait_off(e, limit, step=0.1):
    t0 = now(e)
    while now(e) - t0 < limit:
        e.advance(step)
        if not lit(e):
            return now(e)
    return None


def sub_text(e):
    return DEC.text(e.snapshot()['lcd'])[1]


def sample_texts(e, n=4, step=0.25):
    out = []
    for _ in range(n):                          # the edited value blinks: sample over one second
        out.append(sub_text(e))
        e.advance(step)
    return out


def in_window(dt):
    return dt is not None and 29.9 <= dt <= 31.6


def run_tests(image, a_count, a_setting):
    print('T1 30 s setting (EEPROM 0x017 = 1)')
    e = make(image, {0x17: 1})
    e.command({'dial': 2})
    e.advance(3.0)
    check('setting loaded from EEPROM', rd(e, a_setting) == 1)
    check('backlight off after power-on', not lit(e) and rd(e, ADDR_FLAG) == 0)
    t_up = long_press(e, 'MODE')
    check('MODE long press: backlight on', lit(e) and rd(e, ADDR_FLAG) == 1)
    check('countdown started', 25 <= rd(e, a_count, 2) <= 31, 'count=%d' % rd(e, a_count, 2))
    t_off = wait_off(e, 40)
    dt = None if t_off is None else t_off - t_up
    check('off 30..31.6 s after the MODE key release', in_window(dt), 'dt=%s s' % (None if dt is None else round(dt, 2)))
    check('RAM flag cleared with PE8', rd(e, ADDR_FLAG) == 0)
    t_a = long_press(e, 'MODE')
    check('on again', lit(e))
    e.advance(20.0)
    t_p = press(e, 'RANGE')
    check('still on 20 s after the long press', lit(e))
    t_off2 = wait_off(e, 40)
    dt2 = None if t_off2 is None else t_off2 - t_p
    check('key press restarted: off 30..31.6 s after the RANGE press', in_window(dt2) and t_off2 - t_a >= 49,
          'dt=%s s' % (None if dt2 is None else round(dt2, 2)))
    long_press(e, 'MODE')
    check('on a third time', lit(e))
    e.advance(20.0)
    e.command({'dial': 3})
    t_d = now(e)
    e.advance(0.2)
    check('still on 20 s after the long press (dial turned)', lit(e))
    t_off3 = wait_off(e, 40)
    dt3 = None if t_off3 is None else t_off3 - t_d
    check('dial change restarted: off 30..31.6 s after the dial change', in_window(dt3), 'dt=%s s' % (None if dt3 is None else round(dt3, 2)))
    long_press(e, 'MODE')
    check('MODE long press on', lit(e))
    long_press(e, 'MODE')
    check('MODE long press off at once', not lit(e) and rd(e, ADDR_FLAG) == 0)
    e.advance(35.0)
    check('no countdown while off: nothing switched on', not lit(e))

    print('T2 OFF (blank EEPROM byte, the default)')
    e = make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    check('OFF loaded', rd(e, a_setting) == 0)
    long_press(e, 'MODE')
    check('on, no countdown', lit(e) and rd(e, a_count, 2) == 0)
    e.advance(70.0)
    check('still on after 70 s', lit(e) and rd(e, ADDR_FLAG) == 1)
    long_press(e, 'MODE')
    check('MODE long press still switches it off', not lit(e))

    print('T3 stored values')
    for value, expect in ((0xFF, 0), (101, 0), (100, 100)):
        e = make(image, {0x17: value})
        e.command({'dial': 2})
        e.advance(3.0)
        check('0x017 = %d reads as %d' % (value, expect), rd(e, a_setting) == expect and e.m.eeprom[0x17] == value)

    print('T4 setup page bL: the edit writes only EEPROM 0x017')
    e = make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    before = bytes(e.m.eeprom)
    for _ in range(10):
        press(e, 'SETUP', gap=0.5)
    check('tenth SETUP press shows bLOFF', sub_text(e) == 'BL0FF', 'sub=%r' % sub_text(e))
    long_press(e, 'SETUP')
    press(e, 'REL', gap=0.5)
    e.advance(0.6)
    texts = sample_texts(e)
    check('30 s page "bL30S" (S and 5 share one 7-segment shape)', 'BL305' in texts, 'samples=%r' % (texts,))
    check('nothing written before the save', bytes(e.m.eeprom) == before and rd(e, a_setting) == 1)
    long_press(e, 'SETUP')
    e.advance(1.5)
    after = bytes(e.m.eeprom)
    diff = {i: (before[i], after[i]) for i in range(len(before)) if before[i] != after[i]}
    check('save wrote only EEPROM 0x017 = 1', diff == {0x17: (0, 1)}, 'diff=%r' % (diff,))
    long_press(e, 'SETUP')
    press(e, 'PEAK', gap=0.5)
    press(e, 'PEAK', gap=0.5)
    check('PEAK twice from 30 s gives 99 min (code 100)', rd(e, a_setting) == 100)
    e.advance(0.6)
    texts = sample_texts(e)
    check('99 min page "bL 99"', 'BL 99' in texts, 'samples=%r' % (texts,))
    press(e, 'REL', gap=0.5)
    check('REL from 99 min gives OFF', rd(e, a_setting) == 0)
    for _ in range(3):
        press(e, 'REL', gap=0.5)
    check('REL x 3 from OFF gives 2 min (code 3)', rd(e, a_setting) == 3)
    e.advance(0.6)
    texts = sample_texts(e)
    check('2 min page "bL  2"', 'BL  2' in texts, 'samples=%r' % (texts,))
    long_press(e, 'SETUP')
    e.advance(1.5)
    after2 = bytes(e.m.eeprom)
    diff2 = {i: (after[i], after2[i]) for i in range(len(after)) if after[i] != after2[i]}
    check('second save wrote only 0x017 = 3', diff2 == {0x17: (1, 3)}, 'diff=%r' % (diff2,))
    press(e, 'SETUP', gap=0.5)
    check('SETUP short on the page bL goes to item 0', not sub_text(e).startswith('BL'), 'sub=%r' % sub_text(e))
    e.power_cycle()
    e.command({'dial': 2})
    e.advance(3.0)
    check('setting survives a power cycle', rd(e, a_setting) == 3)
    e = make(image, {0x17: 2})
    e.command({'dial': 2})
    e.advance(3.0)
    before = bytes(e.m.eeprom)
    for _ in range(10):
        press(e, 'SETUP', gap=0.5)
    long_press(e, 'SETUP')
    press(e, 'REL', gap=0.5)
    press(e, 'SETUP', gap=0.5)
    check('abandoned edit writes nothing', bytes(e.m.eeprom) == before)

    print('T5 auto power-off and wake with the backlight on')
    e = make(image, {0x16: 0, 0x17: 1})
    e.command({'dial': 2})
    e.advance(3.0)
    long_press(e, 'MODE')
    check('on before the power-off', lit(e) and rd(e, ADDR_FLAG) == 1)
    e.m.uc.mem_write(ADDR_APO, struct.pack('<H', 3))
    e.advance(9.0)
    check('APO power-off: PE8 low', not lit(e))
    e.command({'dial': 3})
    e.advance(3.5)
    check('after the wake the remembered state is restored: flag 1, PE8 high', rd(e, ADDR_FLAG) == 1 and lit(e))
    check('the MODE long press stored the state in 0x017 bit 7', e.m.eeprom[0x17] == 0x81)
    long_press(e, 'MODE')
    check('MODE long press after the wake switches the backlight off', not lit(e) and rd(e, ADDR_FLAG) == 0)
    check('the off state is stored: 0x017 = 1', e.m.eeprom[0x17] == 0x01)

    print('T6 backlight state over a power cycle (0x017 bit 7)')
    e = make(image, {0x17: 3})
    e.command({'dial': 2})
    e.advance(3.0)
    check('remembered off: dark at power-on', not lit(e))
    long_press(e, 'MODE')
    check('MODE long press on: 0x017 = 0x83', lit(e) and e.m.eeprom[0x17] == 0x83)
    e.power_cycle()
    e.command({'dial': 2})
    e.advance(3.0)
    check('remembered on: lit at power-on, setting 2 min kept', lit(e) and rd(e, ADDR_FLAG) == 1 and rd(e, a_setting) == 3)
    wait_off(e, 125.0)
    check('timer switch-off does not write the EEPROM', not lit(e) and e.m.eeprom[0x17] == 0x83)
    e.power_cycle()
    e.command({'dial': 2})
    e.advance(3.0)
    check('lit again at power-on after a timer switch-off', lit(e))
    e = make(image, {0x17: 0xFF})
    e.command({'dial': 2})
    e.advance(3.0)
    check('erased byte 0xFF: dark, setting OFF', not lit(e) and rd(e, a_setting) == 0)
    s = e.snapshot()
    check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def of55(original):
    """The original v2.05 image, booted through the bootloader image as a meter does (inputs/binaries)."""
    path = os.path.join(TMP, 'bl_test_eeprom_%d.bin' % os.getpid())   # one per process: tests run in parallel
    open(path, 'wb').write(SYNTHETIC)
    e = Emulator(inputs=os.path.join(ROOT, 'inputs', 'binaries'), app=original, eeprom=path)
    e.command({'dial': 0})
    e.advance(0.1)
    e.command({'dial': 2})
    e.advance(3.0)
    states = []

    def note(what):
        states.append((what, e.snapshot()['backlight'], rd(e, ADDR_FLAG)))
        print('%-30s PE8=%r flag=%d' % states[-1], flush=True)
    long_press(e, 'MODE')
    note('MODE long press')
    e.m.uc.mem_write(ADDR_APO, struct.pack('<H', 3))
    e.advance(9.0)
    note('after the auto power-off')
    e.command({'dial': 3})
    e.advance(3.5)
    note('after the wake')
    long_press(e, 'MODE')
    note('first MODE long press')
    long_press(e, 'MODE')
    note('second MODE long press')
    ok = [s[1:] for s in states] == [(1, 1), (None, 1), (0, 1), (0, 0), (1, 1)]
    check('OF-55 reproduced on the original image', ok)


def main(argv):
    if argv and argv[0] == '--of55':
        of55(argv[1])
    else:
        image = argv[0] if argv else os.path.join(ROOT, 'firmware', 'build', 'EEVBlog.bin')
        mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
        run_tests(image, symbol(mp, 'pwr_bl_count'), symbol(mp, 'pwr_bl_setting'))
    print('RESULT', ('FAIL: ' + ', '.join(fails)) if fails else 'ALL PASS', flush=True)
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
