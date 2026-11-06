"""Emulator test of the capacitance anti-hunting rule (firmware/DESIGN.md IMP-45, SETUP page HUnt, EEPROM 0x020 bit 4).

    python -I emulator/scripts/test_cap_antihunt.py [IMAGE]          (default firmware/build/EEVBlog.bin)

With some ceramic capacitors of about 100 nF the CAP auto range hunts: range 1 (100 nF) delivers no counter result within
the no-signal timeout (2.5 s), the timeout jumps to range 2 (1 uF), where the capacitor reads below 1000 counts, so the
decision steps down to range 1 again, and so on; every change blanks the digits.  The emulator reproduces the cause with the
model setting cap_slow_ranges of the stimulus (emulator/emu/frontend.py: on those ranges no counter result completes; the
physical cause of such a capacitor is UNPROVEN).  With 95 nF and cap_slow_ranges [1]:
  T1 setting off (the default): the range alternates 1 / 2 for 20 s, the digits stay blank, nothing is counted or locked.
  T2 the SETUP page HUnt reached with the SETUP key (item 41, after dSP): sub display "HUnt", main display "oFF" (steady
     although the range jumps); long SETUP, REL: "on"; long SETUP saves exactly EEPROM 0x020 = 0x10 and RAM set_hunt_on = 1;
     SETUP short goes on to the page CL (item 25).
  T3 setting on: after two counted range-1 timeouts range 2 stays and the value (about 0.095 uF) is shown, 10 s steady.
  T3b manual range (RANGE key) ends the lock and clears the count; back in auto range the hunting capacitor is locked again.
  T4 another capacitor (470 nF): the lock ends, normal ranging; then 20 nF measured normally on range 1, no lock.
  T5 setting on by the EEPROM byte (0x020 = 0x10; an erased byte 0xFF reads as off): open leads (0 F, no counter result on
     ranges 0 and 1) never lock or count two timeouts and keep cycling between ranges 0 and 2 (the production ar_sample jumps
     from range 2 straight to range 0 for a zero reading; the step by step rule of v2.05 is not used); a following 1 nF
     capacitor reads on range 0; a normal 50 nF capacitor
     stays on range 1 without a lock or a counted timeout; the hunting 95 nF then locks as in T3.
  T6 no unmodelled access and no hardware-safety violation in either meter.
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402

METER_MODE, METER_RANGE, RANGE_MANUAL = 0x2000803C, 0x2000803D, 0x20008042
ADDR_ITEM, ADDR_EDIT, ADDR_BLANK = 0x20008037, 0x2000806E, 0x2000805C


def num(text):
    """The main display as a number (the decimal point is part of the text), None when it holds no number."""
    try:
        return float(text.replace(' ', ''))
    except ValueError:
        return None


def has_digit(text):
    return any(c.isdigit() for c in text)


def to_cap(e):
    e.command({'dial': 5})                                   # OHM position; MODE steps through its modes, CAP among them
    e.advance(3.0)
    for _ in range(6):
        if T.rd(e, METER_MODE) == 12:
            break
        T.press(e, 'MODE')
        e.advance(1.0)
    T.check('CAP mode', T.rd(e, METER_MODE) == 12, repr(T.rd(e, METER_MODE)))


class Watch:
    """Samples of the range, the anti-hunting state and the main display every 0.25 s."""

    def __init__(self, e, syms):
        self.e, self.s = e, syms

    def state(self):
        e, s = self.e, self.s
        t = T.DEC.text(e.snapshot()['lcd'])
        return {'rng': T.rd(e, METER_RANGE), 'lock': T.rd(e, s['ah_lock']), 'to': T.rd(e, s['ah_timeouts']),
                'ref': T.rd(e, s['ah_ref'], 4), 'on': T.rd(e, s['set_hunt_on']), 'main': t[0], 'sub': t[1],
                'blank': T.rd(e, ADDR_BLANK)}

    def run(self, seconds, until=None):
        out = []
        for _ in range(int(seconds / 0.25)):
            self.e.advance(0.25)
            st = self.state()
            out.append(st)
            if until and until(st):
                break
        return out


def symbols(image):
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    return {n: T.symbol(mp, n) for n in ('ah_lock', 'ah_timeouts', 'ah_ref', 'set_hunt_on')}


def settled_on_range2(samples, lo, hi):
    return all(s['rng'] == 2 and s['lock'] == 2 and s['to'] == 2 and num(s['main']) is not None and lo <= num(s['main']) <= hi
               for s in samples)


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    syms = symbols(image)
    hunting = {'kind': 'F', 'value': 95e-9, 'cap_slow_ranges': [1]}

    print('T1 setting off: 95 nF that never completes on range 1 hunts')
    e = T.make(image)
    to_cap(e)
    w = Watch(e, syms)
    T.check('default: setting off', w.state()['on'] == 0)
    e.command({'input': hunting})
    e.advance(3.0)
    run = w.run(20.0)
    rngs = [s['rng'] for s in run]
    jumps = sum(1 for a, b in zip(rngs, rngs[1:]) if a == 1 and b == 2)
    T.check('range alternates 1 / 2 for 20 s (%d jumps from 1 to 2)' % jumps, {1, 2} <= set(rngs) and jumps >= 4, repr(sorted(set(rngs))))
    T.check('no value is shown (digits blank)', not any(has_digit(s['main']) for s in run),
            repr(sorted({s['main'] for s in run})))
    T.check('nothing counted or locked', all(s['lock'] == 0 and s['to'] == 0 for s in run))

    print('T2 SETUP page HUnt')
    for _ in range(25):
        if T.rd(e, ADDR_ITEM) == 41:
            break
        T.press(e, 'SETUP', gap=0.5)
    T.check('SETUP pages reach item 41 (HUnt) in CAP', T.rd(e, ADDR_ITEM) == 41, repr(T.rd(e, ADDR_ITEM)))
    e.advance(0.6)
    run = w.run(8.0)                                         # the range jumps meanwhile: the page must stay steady
    print('    sub %r, main %r' % (run[-1]['sub'], run[-1]['main']))
    T.check('page text: sub "HUNT", main "OFF" in every sample over 8 s of hunting',
            all(s['sub'].strip().upper() == 'HUNT' and s['main'].strip().upper().replace('0', 'O') == 'OFF' for s in run),
            repr(sorted({(s['sub'], s['main']) for s in run})))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.check('long SETUP starts the edit', T.rd(e, ADDR_EDIT) == 1)
    T.press(e, 'REL', gap=0.5)
    e.advance(0.6)
    run = w.run(1.5)
    T.check('REL: setting on in RAM, main "ON"', run[-1]['on'] == 1 and any(s['main'].strip().upper() == 'ON' for s in run),
            repr(sorted({(s['on'], s['main']) for s in run})))
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    diff = {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('save wrote only EEPROM 0x020 = 0x10', diff == {0x20: (0, 0x10)}, repr(diff))
    T.check('edit ended', T.rd(e, ADDR_EDIT) == 0)
    T.press(e, 'SETUP', gap=0.5)
    e.advance(0.6)
    T.check('SETUP short on HUnt goes to the page CL (item 25)', T.rd(e, ADDR_ITEM) == 25, repr(T.rd(e, ADDR_ITEM)))
    T.check('the live reading is back on the main display', w.state()['main'].strip().upper() not in ('ON', 'OFF'))

    print('T3 setting on: two counted timeouts lock range 2')
    run = w.run(40.0, until=lambda s: s['lock'] == 2 and s['blank'] == 0)
    e.advance(1.0)
    run = w.run(10.0)
    T.check('range 2 stays 10 s with lock 2, two counted timeouts and a value of about 0.095 uF',
            settled_on_range2(run, 0.093, 0.097), repr(sorted({(s['rng'], s['lock'], s['to'], s['main']) for s in run})))

    print('T3b manual range ends the lock; back in auto range it is taken again')
    T.press(e, 'RANGE')                                      # manual range: stays on the present range (2)
    run = w.run(3.0)
    st = w.state()
    T.check('RANGE (manual): lock and count cleared, range 2 kept', T.rd(e, RANGE_MANUAL) == 1 and st['lock'] == 0 and st['to'] == 0 and
            st['rng'] == 2, repr(st))
    T.long_press(e, 'RANGE')                                 # back to auto range: the capacitor hunts again until the next lock
    run = w.run(60.0, until=lambda s: s['lock'] == 2 and s['blank'] == 0)
    e.advance(1.0)
    run = w.run(5.0)
    T.check('auto range again: locked again on range 2, about 0.095 uF', settled_on_range2(run, 0.093, 0.097),
            repr(sorted({(s['rng'], s['lock'], s['to'], s['main']) for s in run})))

    print('T4 another capacitor ends the lock')
    e.command({'input': {'kind': 'F', 'value': 470e-9, 'cap_slow_ranges': [1]}})
    run = w.run(10.0, until=lambda s: s['lock'] == 0 and num(s['main']) is not None and s['blank'] == 0)
    e.advance(1.5)
    st = w.state()
    T.check('470 nF: lock ended, count cleared, range 2, 0.47 uF', st['lock'] == 0 and st['to'] == 0 and st['rng'] == 2 and
            num(st['main']) is not None and 0.46 <= num(st['main']) <= 0.48, repr(st))
    e.command({'input': {'kind': 'F', 'value': 20e-9}})
    run = w.run(15.0, until=lambda s: s['rng'] == 1 and s['blank'] == 0 and num(s['main']) is not None)
    e.advance(2.0)
    st = w.state()
    T.check('20 nF measured normally: range 1, no lock, no count, 20.0 nF', st['rng'] == 1 and st['lock'] == 0 and st['to'] == 0 and
            num(st['main']) is not None and 19.0 <= num(st['main']) <= 21.0, repr(st))
    s1 = e.snapshot()
    T.check('no unmodelled access, no safety violation (meter 1)', s1['unmodelled'] == 0 and not s1['safety'])

    print('T5 setting on from the EEPROM byte')
    e = T.make(image, {0x20: 0xFF})
    e.command({'dial': 5})
    e.advance(3.0)
    T.check('0x020 = 0xFF (erased) reads as off', T.rd(e, syms['set_hunt_on']) == 0)
    e = T.make(image, {0x20: 0x10})
    to_cap(e)
    w = Watch(e, syms)
    T.check('0x020 = 0x10: setting on', w.state()['on'] == 1)
    e.command({'input': {'kind': 'F', 'value': 0.0, 'cap_slow_ranges': [0, 1]}})     # open leads of the real meter
    e.advance(2.0)
    run = w.run(40.0)
    rngs = {s['rng'] for s in run}
    print('    open leads: ranges %r, largest count %d' % (sorted(rngs), max(s['to'] for s in run)))
    T.check('open leads never lock and never count two timeouts, the ranges 0 and 2 keep cycling',
            all(s['lock'] == 0 and s['to'] < 2 for s in run) and {0, 2} <= rngs, repr(sorted(rngs)))
    e.command({'input': {'kind': 'F', 'value': 1e-9}})
    run = w.run(15.0, until=lambda s: s['rng'] == 0 and s['blank'] == 0 and num(s['main']) is not None)
    e.advance(3.0)
    st = w.state()
    T.check('1 nF after open leads: range 0, no lock, 1.0 nF', st['rng'] == 0 and st['lock'] == 0 and
            num(st['main']) is not None and 0.9 <= num(st['main']) <= 1.1, repr(st))
    e.command({'input': {'kind': 'F', 'value': 50e-9}})
    run = w.run(15.0, until=lambda s: s['rng'] == 1 and s['blank'] == 0 and num(s['main']) is not None)
    e.advance(8.0)
    run = w.run(5.0)
    T.check('50 nF normal: range 1, no lock, no count, 50.0 nF',
            all(s['rng'] == 1 and s['lock'] == 0 and s['to'] == 0 and num(s['main']) is not None and 49.0 <= num(s['main']) <= 51.0
                for s in run), repr(sorted({(s['rng'], s['lock'], s['to'], s['main']) for s in run})))
    e.command({'input': hunting})
    run = w.run(40.0, until=lambda s: s['lock'] == 2 and s['blank'] == 0)
    e.advance(1.0)
    run = w.run(10.0)
    T.check('hunting 95 nF locks (EEPROM setting): range 2 steady, about 0.095 uF',
            settled_on_range2(run, 0.093, 0.097), repr(sorted({(s['rng'], s['lock'], s['to'], s['main']) for s in run})))
    s2 = e.snapshot()
    T.check('no unmodelled access, no safety violation (meter 2)', s2['unmodelled'] == 0 and not s2['safety'])
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
