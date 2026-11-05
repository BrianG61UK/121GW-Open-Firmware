"""Induced emulator test of a card that stays busy after a block longer than the firmware's write wait (DESIGN.md IMP-40).

    python -I emulator/scripts/test_sd_slow.py [IMAGE [MAP]]       (default firmware/build/EEVBlog.bin and its 121gw.map)

The card model's test fault 'write_slow' (emu/sdcard.py) programs one block for 0.9 s, longer than the 600 ms of the
firmware's busy wait (sd_wait_write, IMP-33).  On a meter (2026-11-05) a 32 GB card did that during f_mkfs: the write counted
as failed, the format stopped and the card was left without a file system.  disk_write now asks the card with ACMD22 how
many blocks the write wrote and takes a confirmed block as done (sd_dg_late counts them).  Here one slow block is met at
the logging start (file creation) and one at the first flush of the records; logging must go on, no disk call may fail,
and the card must hold one complete CSV file.  An image without IMP-40 fails the "no failed disk call" check.
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


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    print('T one block programmed for 0.9 s at the logging start and at the first flush')
    d = tempfile.mkdtemp(prefix='sdslow_')
    card = os.path.join(d, 'card.img')
    format_fat32(card, 64 * 1024 * 1024)
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(image, {0x1E: 0, 0x18: 0, 0x19: 1})
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.0, 'ac': False}})
    e.advance(3.0)
    e.sdcard.faults['write_slow'] = 1
    T.long_press(e, 'MEM')
    e.advance(3.0)
    T.check('logging started', T.rd(e, ADDR_LOGGING) == 1)
    left_start = e.sdcard.faults['write_slow']
    e.advance(55.0)
    e.sdcard.faults['write_slow'] = 1
    e.advance(20.0)
    left_flush = e.sdcard.faults['write_slow']
    T.check('logging still running after both slow blocks', T.rd(e, ADDR_LOGGING) == 1)
    T.long_press(e, 'MEM')
    e.advance(5.0)
    T.check('logging stopped', T.rd(e, ADDR_LOGGING) == 0)
    T.check('both slow blocks were met (start %d, flush %d left)' % (left_start, left_flush), left_start == 0 and left_flush == 0)
    if os.path.exists(mp):
        failed = T.rd(e, T.symbol(mp, 'sd_dg_count'), 2)
        has_late = any(l.rstrip().endswith(' sd_dg_late') for l in open(mp))      # absent in images before IMP-40
        late = T.rd(e, T.symbol(mp, 'sd_dg_late'), 2) if has_late else None
        print('  failed disk calls %d, late blocks confirmed by ACMD22 %s' % (failed, late))
        T.check('no failed disk call', failed == 0)
        T.check('two late blocks confirmed by the card', late == 2)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])
    del e
    with Volume(card) as v:
        texts = [v.read_chain(ent['cluster'], ent['size']).decode('latin1') for p, ent in v.walk() if p.upper().endswith('.CSV')]
    T.check('one CSV file with the START header and records', len(texts) == 1 and texts[0].startswith('START,')
            and texts[0].count('\n') > 60, repr([len(x) for x in texts]))
    os.remove(card)
    os.rmdir(d)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
