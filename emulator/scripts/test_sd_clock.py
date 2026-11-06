"""Emulator test of the card-session clock (firmware/DESIGN.md IMP-41, GitHub issue 5).

    python -I emulator/scripts/test_sd_clock.py [IMAGE]          (default firmware/build/EEVBlog.bin)

A card session switches SYSCLK from MSI (4.194 MHz) to the PLL: HSE 4 MHz x24 /3, VCO 96 MHz as RM0038 6.2 requires
for the SDIO (SDIOCLK = VCO / 2 = 48 MHz), SYSCLK 32 MHz; afterwards back to MSI.  The step up goes through HCLK 16 MHz (SW = PLL with HPRE / 2, then HPRE / 1):
every frequency increase must stay below 4 x with 5 us between two changes (RM0038 6.2.7 note).  The TIM2 / TIM3
prescalers follow the clock, so the 10 ms tick keeps its length.  Logging on a 64 MiB card for 30 s; every clock change is recorded with
the core's clock hook.  Checks: sessions ran at 32 MHz with SDIOCLK 48 MHz; no core clock other than MSI, 16 MHz and
32 MHz; every increase below 4 x; the 10 ms tick counted 30 s within 1 %; one complete CSV file; no unmodelled access, no safety violation.
"""
import os
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402
from diff.fat32 import Volume  # noqa: E402

ADDR_LOGGING = 0x20007FE1
ADDR_TICK = 0x20007FC6          # free-running 10 ms tick (TIM2), u16
MSI_HZ, STEP_HZ, PLL_HZ, SDIO_HZ = 4_194_304, 16_000_000, 32_000_000, 48_000_000


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    print('T logging 30 s: card sessions on the PLL at 32 MHz, the tick keeps its length')
    d = tempfile.mkdtemp(prefix='sdclk_')
    card = os.path.join(d, 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(image, {0x1E: 0, 0x18: 0, 0x19: 1})
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(3.0)
    seen = []
    e.m.clock_hooks.append(lambda *a: seen.append((e.m.sysclk_hz, e.m.rcc.sdioclk_hz)))
    T.long_press(e, 'MEM')
    e.advance(1.0)
    t0, k0 = T.now(e), T.rd(e, ADDR_TICK, 2)
    e.advance(30.0)
    t1, k1 = T.now(e), T.rd(e, ADDR_TICK, 2)
    ticks = (k1 - k0) & 0xFFFF
    T.check('logging running', T.rd(e, ADDR_LOGGING) == 1)
    T.long_press(e, 'MEM')
    e.advance(5.0)
    clocks = sorted({c for c, _ in seen})
    sess = [s for c, s in seen if c == PLL_HZ]
    print('  SYSCLK values used %r; SDIOCLK in the sessions %r; %d clock changes' % (clocks, sorted(set(sess)), len(seen)))
    T.check('card sessions ran at 32 MHz', PLL_HZ in clocks and len(sess) >= 2)
    T.check('SDIOCLK 48 MHz in every session (VCO 96 MHz, RM0038 6.2)', sess and all(s == SDIO_HZ for s in sess), repr(set(sess)))
    T.check('no core clock other than MSI, the 16 MHz step and the 32 MHz PLL', set(clocks) <= {MSI_HZ, STEP_HZ, PLL_HZ},
            repr(clocks))
    order = [c for c, _ in seen]
    ups = [(a, b) for a, b in zip(order, order[1:]) if b > a]
    T.check('every frequency increase below 4 x (RM0038 6.2.7)', ups and all(b < 4 * a for a, b in ups),
            repr(sorted(set(ups))))
    expect = (t1 - t0) / (261 * 161 / MSI_HZ)
    print('  10 ms ticks in %.1f s: %d (expected %.0f)' % (t1 - t0, ticks, expect))
    T.check('the 10 ms tick kept its length within 1 %', abs(ticks - expect) <= 0.01 * expect, '%d vs %.0f' % (ticks, expect))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e
    with Volume(card) as v:
        texts = [v.read_chain(ent['cluster'], ent['size']).decode('latin1') for p, ent in v.walk() if p.upper().endswith('.CSV')]
    T.check('one CSV file with the START header and records', len(texts) == 1 and texts[0].startswith('START,')
            and texts[0].count('\n') > 30, repr([len(x) for x in texts]))
    os.remove(card)
    os.rmdir(d)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
