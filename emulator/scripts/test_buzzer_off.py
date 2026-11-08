"""Induced emulator test of the buzzer setting (both images, ORIGINAL_FIRMWARE_ISSUES.md OF-63; fast build IMP-54).

    python -I emulator/scripts/test_buzzer_off.py [image]      default firmware/build/EEVBlog.bin

The buzzer setting is EEPROM 0x01E (SETUP page 3 "b-On" / "b-OFF"; 0 off).  With it off, continuity and the jack / high-voltage warnings
still sound, the diode short-circuit tone does not (OF-63); with it on, both sound.  Dial Ohm/beep position (5) with
EEPROM 0x0B = 10 (BEEP) or 11 (DIODE); contact: 10 ohm (BEEP) or a diode forward voltage of 0.000 V (DIODE short).
PE7 is sampled every 0.25 ms for 1 s after the contact is made.  Auto power-off: the countdown 0x20000230 is set to 8
instead of waiting out the configured minutes, PE7 sampled every 10 ms for 20 s (warning beeps and the 1 s power-off
beep): silent with the buzzer off, sounding with it on.  The helpers are those of test_backlight_timer.py.
IMP-54 (fast build, GitHub issue 28): the third value 2 "qUiEt": the key beeps silent (RANGE pressed in DCV, PE7 sampled
every 0.25 ms while the key is down and 0.4 s after), the measurement beeps sounding (diode short tone, auto power-off
warning and power-off beep); the page cycles b-On -> b-OFF -> qUiEt with REL in its edit and keeps the value.
Pass --no-quiet for an image without IMP-54 (the strict build).
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


def key_beep(image, setting):
    """PE7 samples (every 0.25 ms) while RANGE is pressed in DCV and 0.4 s after: the key's accept beep."""
    e = T.make(image, {0x1E: setting})
    e.command({'dial': 2})
    e.advance(3.0)
    n = int(e.m.sysclk_hz * 0.00025)
    hi = 0
    e.command({'key': 'RANGE', 'down': True})
    for _ in range(600):                             # 0.15 s down
        e.m.run(n)
        hi += e.snapshot()['buzzer'] or 0
    e.command({'key': 'RANGE', 'down': False})
    for _ in range(1600):                            # 0.4 s after
        e.m.run(n)
        hi += e.snapshot()['buzzer'] or 0
    return hi


def page_cycle(image):
    """The buzzer page (item 3): long SETUP starts the edit, REL steps b-On -> b-OFF -> qUiEt -> b-On, long SETUP saves."""
    e = T.make(image, {0x1E: 1})
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('buzzer page reached', T.to_item(e, 3), 'item=%d' % T.rd(e, T.ADDR_ITEM))
    seen = [' '.join(T.sample_texts(e))]
    T.long_press(e, 'SETUP')                         # edit: the value blinks
    vals = []
    for _ in range(3):
        T.press(e, 'REL', gap=0.5)
        vals.append(T.rd(e, 0x20008078))
        seen.append(' '.join(T.sample_texts(e)))
    T.check('REL steps b-On -> b-OFF -> qUiEt -> b-On', vals == [0, 2, 1], 'setting %r' % vals)
    T.check('the page shows qUiEt for the third value', 'QUiET' in seen[2], 'texts %r' % seen)   # the decoder's form of q U i E t
    T.press(e, 'REL', gap=0.5)                       # b-OFF ...
    T.press(e, 'REL', gap=0.5)                       # ... qUiEt
    T.long_press(e, 'SETUP')                         # save
    T.check('qUiEt kept after the save', T.rd(e, 0x20008078) == 2, 'setting %d' % T.rd(e, 0x20008078))


def main(argv):
    quiet = '--no-quiet' not in argv
    argv = [a for a in argv if a != '--no-quiet']
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
    if quiet:                                        # IMP-54: the third value qUiEt
        for mode, name in ((10, 'continuity'), (11, 'diode short')):
            q = sounded(image, mode, 2)
            T.check('%s, qUiEt: sounds' % name, bool(q), 'PE7 high in %r of 4000 samples' % q)
        q = apo_beeps(image, 2)
        T.check('auto power-off warning and power-off beep, qUiEt: sound', q > 0, 'PE7 high in %d of 2000 samples' % q)
        k_on, k_quiet, k_off = key_beep(image, 1), key_beep(image, 2), key_beep(image, 0)
        T.check('key beep (RANGE), b-On: sounds', k_on > 0, 'PE7 high in %d of 2200 samples' % k_on)
        T.check('key beep (RANGE), qUiEt: silent', k_quiet == 0, 'PE7 high in %d of 2200 samples' % k_quiet)
        T.check('key beep (RANGE), b-OFF: silent', k_off == 0, 'PE7 high in %d of 2200 samples' % k_off)
        page_cycle(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
