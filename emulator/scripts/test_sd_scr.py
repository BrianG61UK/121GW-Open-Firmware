"""Induced emulator test of the SCR read at the card start-up (firmware/DESIGN.md IMP-34).

    python -I emulator/scripts/test_sd_scr.py [image [map]]      default firmware/build/EEVBlog.bin and its 121gw.map

The firmware's SCR read (sd/sdcard.s sd_find_scr, v2.05 FUN_08023A8C) polls the receive FIFO until the DPSM sets DBCKEND.  A
card whose register read latency is short sends the 8-byte SCR before the polling loop runs; v2.05 then returns the zeros of
its buffer and the start-up fails with 0x25 (sd_enable_wide_bus: "1-bit bus not supported").  The card model's read latency
(emu/sdcard.py SDCard.read_latency_us, normally the declared 1 ms) is set to 0 before logging is started with MEM long.
Checks: logging starts, a CSV file with the START header is written; with the map of the image, the start-up counters
(no failed start-up) and the SCR counters (the loop had read no word, the words came from the FIFO afterwards).
A v2.05-style image without IMP-34 (no map given) is expected to fail the first check.
The helpers are those of test_backlight_timer.py.
"""
import os
import sys
import tempfile

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
from emu.sdcard import format_fat32  # noqa: E402
from diff.fat32 import Volume  # noqa: E402

ADDR_LOGGING = 0x20007FE1


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = argv[1] if len(argv) > 1 else (os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map') if not argv else None)
    print('T card that sends the SCR without read latency, logging started')
    d = tempfile.mkdtemp(prefix='sdscr_')
    card = os.path.join(d, 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(image, {0x1E: 0, 0x18: 0, 0x19: 1})
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(3.0)
    e.sdcard.read_latency_us = 0.0
    T.long_press(e, 'MEM')
    e.advance(5.0)
    T.check('logging started', T.rd(e, ADDR_LOGGING) == 1)
    if mp:
        icount, ierr, scrs, scr0, scr1 = (T.rd(e, T.symbol(mp, n), 2) for n in ('sd_dg_icount', 'sd_dg_ierr', 'sd_dg_scrs',
                                                                                 'sd_dg_scr0', 'sd_dg_scr1'))
        print('  failed start-ups %d (last error %d), SCR reads %d, loop had no word %d, one word %d'
              % (icount, ierr, scrs, scr0, scr1))
        T.check('no failed card start-up', icount == 0)
        T.check('the SCR came from the FIFO after the block end (loop had no word)', scrs >= 1 and scr0 == scrs)
    if T.rd(e, ADDR_LOGGING):
        T.long_press(e, 'MEM')
        e.advance(5.0)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e
    with Volume(card) as v:
        heads = [v.read_chain(ent['cluster'], ent['size'])[:6] for p, ent in v.walk() if p.upper().endswith('.CSV')]
    T.check('one CSV file with the START header', heads == [b'START,'], repr(heads))
    os.remove(card)
    os.rmdir(d)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
