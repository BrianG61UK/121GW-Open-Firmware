"""Induced emulator test of the DIODE contact chirp (firmware IMP-51: mres/chirp.s, set/chirp.s, the check in
mres/diode.s at 0x08007EF6; SETUP page CHIrP, item 42; EEPROM 0x02C).  Idea: GitHub PR 22.

    python -I emulator/scripts/test_diode_chirp.py [image]                default firmware/build/EEVBlog.bin

The double beep of DIODE is fn_0800EE6C (v2.05's "refused" pattern); every call of it is counted (a code hook on its
address from build/121gw.map), per phase of a probe sequence on the 3 V range: leads open at the start, a 0.60 V diode,
lifted, the diode again, a drift to 0.75 V, a 40 ms bounce, a short, the diode again.  A phase lasts 2 s, longer than
v2.05's chirp lockout (100 TIM2 ticks, about 1 s), so each phase shows what its own change does.
  C1 off (EEPROM 0x02C = 0, the default): v2.05's jump chirp, a beep on every change of more than 1000 counts; the code
     path is v2.05's, unchanged by IMP-51: the counts per phase equal the ones of the production build before IMP-51
     (v1.2.0, FAST below).  v2.05 itself gives V205 (the original image in the emulator, 2026-11-07): the same rule on its
     own timing.  Its means of a lifted probe are 6000, 18400, 30800 with the lockout of the contact beep still running at
     18400 (one beep), the fast build's are 6000, 15300, 30800 with that lockout over (a beep at 15300 and, after its own
     lockout, one at 30800); the short and the contact after it differ the same way.
  C2 on (0x02C = 1): one beep per contact (diode, diode again, diode after the short), none at the start with open
     leads, on lifting, on the drift, on the bounce or on the short (the short-circuit tone is separate, IMP-04)
  C3 the page: in DIODE, SETUP from dSP goes to CHIrP ("CHIrP" on the sub display, "oFF" on the main display); REL
     switches to on, long SETUP saves EEPROM 0x02C = 1 and no other byte; in DCV the walk goes from dSP to Lt (27; the page CL is on the meter walk, IMP-52)
RUN LIMIT: 1 run of this script (3 boots).
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_backlight_timer as T  # noqa: E402
from unicorn import UC_HOOK_CODE  # noqa: E402

ADDR_MODE, ADDR_ITEM = 0x2000803C, 0x20008037
WARMUP = 4.0                                         # s with open leads in DIODE before the first phase
EE_DIAL5_MODE, EE_CHIRP = 0x0B, 0x02C
ITEM_DSP, ITEM_LT, ITEM_CHIRP = 24, 27, 42
PHASES = [('start, leads open', {'kind': 'open'}),
          ('0.60 V diode', {'kind': 'diode', 'value': 0.60}),
          ('lifted', {'kind': 'open'}),
          ('0.60 V diode again', {'kind': 'diode', 'value': 0.60}),
          ('drift to 0.75 V', {'kind': 'diode', 'value': 0.75}),
          ('40 ms bounce', None),
          ('short', {'kind': 'diode', 'value': 0.0}),
          ('0.60 V diode after the short', {'kind': 'diode', 'value': 0.60})]
# calls of fn_0800EE6C per phase after WARMUP with the original v2.05 image (emulator, 2026-11-07)
V205 = [0, 2, 1, 2, 1, 2, 0, 1]
# the same with the production build v1.2.0 (before IMP-51)
FAST = [0, 2, 2, 2, 1, 2, 1, 2]
ON = [0, 1, 0, 1, 0, 0, 0, 1]


def boot(image, chirp):
    e = T.make(image, {EE_DIAL5_MODE: 11, EE_CHIRP: chirp})
    addr = T.symbol(os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map'), 'fn_0800EE6C')
    e.calls = [0]

    def hook(uc, address, size, user):
        e.calls[0] += 1
    e.m.uc.hook_add(UC_HOOK_CODE, hook, None, addr & ~1, addr & ~1)
    e.command({'input': {'kind': 'open'}})
    e.command({'dial': 5})
    return e


def sequence(e):
    e.advance(WARMUP)                                # every image fully started (v2.05 starts through the bootloader)
    counts = []
    for name, stim in PHASES:
        n0 = e.calls[0]
        if stim is None:                             # the probe lifts for 40 ms and touches again
            e.command({'input': {'kind': 'open'}})
            e.advance(0.04)
            e.command({'input': {'kind': 'diode', 'value': 0.75}})
        else:
            e.command({'input': stim})
        e.advance(2.0)
        counts.append(e.calls[0] - n0)
    return counts


def run_tests(image):
    print('C1 off (default): v2.05 jump chirp')
    e = boot(image, 0)
    off = sequence(e)
    T.check('C1: DIODE', T.rd(e, ADDR_MODE) == 11, 'mode %d' % T.rd(e, ADDR_MODE))
    for (name, _), got, want in zip(PHASES, off, FAST):
        T.check('C1: %s: %d beep(s) as before IMP-51' % (name, want), got == want, 'got %d' % got)

    print('C2 on: one beep per contact')
    e = boot(image, 1)
    on = sequence(e)
    for (name, _), got, want in zip(PHASES, on, ON):
        T.check('C2: %s: %d beep(s)' % (name, want), got == want, 'got %d' % got)

    print('C3 the page CHIrP')
    e = boot(image, 0)
    e.advance(2.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([ITEM_DSP]))
    T.press(e, 'SETUP', gap=0.6)                     # outside SETUP the first press shows the page set (dSP)
    T.check('C3: DIODE: page dSP shown', T.rd(e, ADDR_ITEM) == ITEM_DSP, 'item %d' % T.rd(e, ADDR_ITEM))
    T.press(e, 'SETUP', gap=0.6)
    T.check('C3: DIODE: dSP -> CHIrP', T.rd(e, ADDR_ITEM) == ITEM_CHIRP, 'item %d' % T.rd(e, ADDR_ITEM))
    main, sub, _ = T.DEC.text(e.snapshot()['lcd'])
    T.check('C3: "CHIrP" on the sub display, the value off on the main display', sub.strip().upper() == 'CH1RP'
            and main.strip().upper() == 'OFF', 'sub %r main %r' % (sub, main))
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.6)
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    e.advance(0.5)
    diff = [i for i in range(len(before)) if before[i] != e.m.eeprom[i]]
    T.check('C3: the save writes EEPROM 0x02C = 1 and nothing else', diff == [EE_CHIRP] and e.m.eeprom[EE_CHIRP] == 1,
            repr([hex(i) for i in diff]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('C3: CHIrP -> Lt', T.rd(e, ADDR_ITEM) == ITEM_LT, 'item %d' % T.rd(e, ADDR_ITEM))
    e.command({'dial': 2})
    e.advance(2.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([ITEM_DSP]))
    T.press(e, 'SETUP', gap=0.6)
    if T.rd(e, ADDR_ITEM) == ITEM_DSP:               # the press showed dSP: the next one steps
        T.press(e, 'SETUP', gap=0.6)
    T.check('C3: DCV: dSP -> Lt (no CHIrP outside DIODE)', T.rd(e, ADDR_ITEM) == ITEM_LT, 'item %d' % T.rd(e, ADDR_ITEM))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'],
            'unmodelled %r safety %r' % (s['unmodelled'], s['safety']))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
