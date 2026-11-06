"""The animated picture of the capacitance anti-hunting for README.md (firmware/docs/antihunt/antihunt.gif), made in the emulator.

    /tmp/eev/venv/bin/python -I emulator/tools/make_antihunt_gif.py [OUT.gif]      (after `make` in firmware/; needs Pillow and
                                                                                    Playwright with Chromium; default firmware/docs/antihunt/antihunt.gif)

Two parts, one after the other, each a meter in CAP auto range with a 95 nF capacitor that never completes a measurement on
range 1 (the emulator's model setting `cap_slow_ranges`, emulator/emu/frontend.py: the cause of such a capacitor on a real
meter is unproven):
  1. SETUP page HUnt off (the default): the range keeps changing between 100 nF and 1 uF, the digits stay blank and only the
     decimal point moves.
  2. HUnt on (EEPROM 0x020 bit 4): after two timeouts of the 100 nF range the meter stays on the 1 uF range and shows the value.
The display words (LCD RAM as committed) are sampled with their emulated times and drawn with the emulator page's own glass layers
(emulator/ui/assets, through firmware/docs/manual/tools/make_screens.py, the tool of the manual's pictures); a caption is added
below the display.  Time-lapse: one third of the emulated time, at least 0.1 s per picture.
"""
import io
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'firmware', 'docs', 'manual', 'tools'))
import make_screens as MS  # noqa: E402

CAPACITOR = {'kind': 'F', 'value': 95e-9, 'cap_slow_ranges': [1]}
LAPSE = 3.0                       # emulated seconds per second of the picture
MIN_S, MAX_S, END_S = 0.1, 2.0, 2.5
CLIP = {'x': 118, 'y': 183, 'width': 457, 'height': 266}      # the display with a margin (MS.LCD_BOX)
WIDTH, BAND = 380, 30


def cap_meter(patch=None):
    e = MS.meter(patch=patch)
    e.command({'dial': 5})
    e.advance(2.0)
    if not MS.to_mode(e, 'CAP'):
        raise SystemExit('FAIL: CAP not reached')
    e.command({'input': dict(CAPACITOR)})
    return e


def record(e, seconds, step=0.1):
    """[(display words, backlight, seconds shown)] over `seconds` of emulated time; equal neighbours are merged."""
    frames = []
    t = 0.0
    while t < seconds:
        e.advance(step)
        t += step
        s = e.snapshot()
        words = tuple(s['lcd'])
        if frames and frames[-1][0] == words:
            w, b, d = frames[-1]
            frames[-1] = (w, b, d + step)
        else:
            frames.append((words, bool(s['backlight']), step))
    return frames


def main(argv):
    out = argv[0] if argv else os.path.join(ROOT, 'firmware', 'docs', 'antihunt', 'antihunt.gif')
    MS.load()
    print('part 1: HUnt off', flush=True)
    off = record(cap_meter(), 22.0)
    print('part 2: HUnt on', flush=True)
    on = record(cap_meter({0x20: 0x10}), 30.0)
    parts = [(off, 'HUnt oFF: the range keeps changing, no value'), (on, 'HUnt on: it stays on 1 uF and shows the value')]

    from playwright.sync_api import sync_playwright
    from PIL import Image, ImageDraw, ImageFont
    import tempfile
    html = os.path.join(tempfile.mkdtemp(prefix='antihunt_'), 'p.html')
    open(html, 'w').write(MS.page_html())
    try:
        font = ImageFont.load_default(size=15)
    except TypeError:
        font = ImageFont.load_default()
    images, durs = [], []
    with sync_playwright() as p:
        br = p.chromium.launch()
        pg = br.new_page(viewport={'width': MS.PW, 'height': MS.PH})
        pg.goto('file://' + html)
        pg.wait_for_timeout(1500)
        for frames, caption in parts:
            for i, (words, lit, secs) in enumerate(frames):
                pg.evaluate('([w,l,d,j]) => show(w,l,d,j)', [list(words), lit, 5, []])
                pg.wait_for_timeout(30)
                im = Image.open(io.BytesIO(pg.screenshot(clip=CLIP))).convert('RGB')
                im = im.resize((WIDTH, round(CLIP['height'] * WIDTH / CLIP['width'])), Image.LANCZOS)
                canvas = Image.new('RGB', (WIDTH, im.height + BAND), 'white')
                canvas.paste(im, (0, 0))
                d = ImageDraw.Draw(canvas)
                d.text((WIDTH // 2, im.height + BAND // 2), caption, fill='black', font=font, anchor='mm')
                images.append(canvas)
                durs.append(int(min(MAX_S, max(MIN_S, secs / LAPSE)) * 1000))
            durs[-1] = int(END_S * 1000)                 # hold the last picture of the part
        br.close()
    pal = [i.quantize(colors=32, method=Image.Quantize.MEDIANCUT).convert('RGB') for i in images]
    pal[0].save(out, save_all=True, append_images=pal[1:], duration=durs, loop=0, optimize=True)
    print('%s: %d pictures, %d bytes, %.1f s' % (out, len(pal), os.path.getsize(out), sum(durs) / 1000.0))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
