"""Induced emulator test of the buzzer setting (both images, ORIGINAL_FIRMWARE_ISSUES.md OF-63).

    python -I emulator/scripts/test_buzzer_off.py [image]      default firmware/build/EEVBlog.bin

The buzzer setting is EEPROM 0x01E (SETUP page 3 "b-On" / "b-OFF"; 0 off).  With it off, continuity and the jack / high-voltage warnings
still sound, the diode short-circuit tone does not (OF-63); with it on, both sound.  Dial Ohm/beep position (5) with
EEPROM 0x0B = 10 (BEEP) or 11 (DIODE); contact: 10 ohm (BEEP) or a diode forward voltage of 0.000 V (DIODE short).
PE7 is sampled every 0.25 ms for 1 s after the contact is made.  Auto power-off: the countdown 0x20000230 is set to 8
instead of waiting out the configured minutes, PE7 sampled every 10 ms for 20 s (warning beeps and the 1 s power-off
beep): silent with the buzzer off, sounding with it on.  The helpers are those of test_backlight_timer.py.
"""
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

ADDR_MODE = 0x2000803C


def sounded(image, mode, setting):
    e = T.make(image, {0x0B: mode, 0x1E: setting})
    e.command({'dial': 5})
    e.advance(3.0)
    if T.rd(e, ADDR_MODE) != mode:
        T.check('mode %d reached' % mode, False, 'mode=%d' % T.rd(e, ADDR_MODE))
        return None
    if mode == 10:
        e.command({'input': {'kind': 'ohm', 'value': 10.0}})
    else:
        e.command({'input': {'kind': 'diode', 'value': 0.0}})
    n = int(e.m.sysclk_hz * 0.00025)
    hi = 0
    for _ in range(4000):
        e.m.run(n)
        hi += e.snapshot()['buzzer']
    s = e.snapshot()
    T.check('mode %d setting %d: no unmodelled access, no safety violation' % (mode, setting),
            s['unmodelled'] == 0 and not s['safety'])
    return hi


def apo_beeps(image, setting):
    """Auto power-off with the countdown 0x20000230 set to 8 (a few seconds instead of the configured minutes): PE7 samples
    (every 10 ms) from then until the meter has powered down; the warning beeps and the 1 s power-off beep fall in this span."""
    e = T.make(image, {0x1E: setting})
    e.command({'dial': 2})
    e.advance(3.0)
    e.m.uc.mem_write(T.ADDR_APO, struct.pack('<H', 8))
    hi = 0
    for _ in range(2000):                            # 20 s
        e.advance(0.01)
        hi += e.snapshot()['buzzer'] or 0
    s = e.snapshot()
    T.check('APO setting %d: the meter powered down (PE9 supply low)' % setting, not s['lcd_on'], 'lcd_on=%r' % s['lcd_on'])
    return hi


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    for mode, name, off_sounds in ((10, 'continuity', True), (11, 'diode short', False)):
        on = sounded(image, mode, 1)
        off = sounded(image, mode, 0)
        T.check('%s, buzzer on: sounds' % name, bool(on), 'PE7 high in %r of 4000 samples' % on)
        T.check('%s, buzzer off: %s' % (name, 'still sounds' if off_sounds else 'silent'), bool(off) == off_sounds,
                'PE7 high in %r of 4000 samples' % off)
    on, off = apo_beeps(image, 1), apo_beeps(image, 0)
    T.check('auto power-off warning and power-off beep, buzzer on: sound', on > 0, 'PE7 high in %d of 2000 samples' % on)
    T.check('auto power-off warning and power-off beep, buzzer off: silent', off == 0, 'PE7 high in %d of 2000 samples' % off)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
