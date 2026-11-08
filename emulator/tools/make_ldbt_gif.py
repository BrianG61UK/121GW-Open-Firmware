"""Animated picture: how to get to the meter's page Ld-bt (GitHub issue 34), made in the emulator.

    python -I emulator/tools/make_ldbt_gif.py [OUT.gif]      default firmware/docs/bootloader/to_ld_bt.gif
                                                            (after `make` in firmware/; needs Pillow and Playwright with
                                                            Chromium)

The production image runs headless (emulator/scripts/test_backlight_timer.py helpers): DCV, Bluetooth on (long PEAK),
then SETUP pressed page by page to SEt, SETUP held (the meter pages), SETUP pressed page by page to Ld-bt.  After every
key action the display words (LCD RAM as committed) are drawn with the emulator page's own glass layers
(emulator/ui/assets: panel.png, lcd/*.svg, lcd_bits.json) in Chromium, as bootloader/tools/make_gifs.py on the branch
bootloader does; the SETUP key is ringed and a caption under the meter says what to do.  RUN LIMIT: 1 boot.
"""
import io
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ROOT, 'emulator', 'scripts'))
import test_backlight_timer as T  # noqa: E402

ASSETS = os.path.join(ROOT, 'emulator', 'ui', 'assets')
PW, PH = 695, 1338
LCD_BOX = (123, 188, 570, 444)
CROP_H = 700                                         # display and keys; the dial is not part of the picture
SETUP_KEY = (530, 620, 44)                           # centre x, y and ring radius of SETUP on panel.png (pixels)
WIDTH = 420


def is_set(sub):
    return sub.replace('5', 'S') == 'SET'              # the decoder reads the S of SEt as 5


def frames():
    """[(display words or None, step title, caption, key mark: None / 'press' / 'hold', seconds shown)]"""
    e = T.make(os.path.join(ROOT, 'firmware', 'build', 'EEVBlog.bin'))
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')                          # Bluetooth on (the companion is connected)
    e.advance(1.0)
    out = []

    def shot(title, caption, mark, secs):
        s = e.snapshot()
        out.append((tuple(s['lcd']) if s['lcd_on'] else None, title, caption, mark, secs))

    shot('Start', 'Meter on. Companion connected.', None, 3.0)
    n = 0
    for _ in range(20):
        T.press(e, 'SETUP', gap=0.6)
        n += 1
        if is_set(T.sub_text(e).strip().upper()):
            shot('Step 1', 'It says SEt.  Good!', 'press', 3.0)
            break
        shot('Step 1', 'Press SETUP.  (%d)' % n, 'press', 1.0)
    else:
        raise SystemExit('SEt not reached: %r' % T.sub_text(e))
    e.command({'key': 'SETUP', 'down': True})
    e.advance(1.0)
    shot('Step 2', 'Now HOLD SETUP down ... BEEP!', 'hold', 3.5)
    e.command({'key': 'SETUP', 'down': False})
    e.advance(0.6)
    shot('Step 2', 'Let go.', None, 2.0)
    n = 0
    for _ in range(20):
        T.press(e, 'SETUP', gap=0.6)
        n += 1
        if T.sub_text(e).strip().upper().startswith('LD'):
            shot('Step 3', 'It says Ld-bt.  STOP here!', 'press', 3.0)
            break
        shot('Step 3', 'Press SETUP.  (%d)' % n, 'press', 1.0)
    else:
        raise SystemExit('Ld-bt not reached: %r' % T.sub_text(e))
    shot('Step 4', 'Wait. The companion does the rest.', None, 5.0)
    return out


def page():
    bits = json.load(open(os.path.join(ASSETS, 'lcd_bits.json')))
    layers = sorted({n for v in bits.values() for n in v})
    imgs = ''.join('<img id="L_%d" src="file://%s">' % (i, os.path.join(ASSETS, 'lcd', n + '.svg'))
                   for i, n in enumerate(layers))
    x0, y0, x1, y1 = LCD_BOX
    css = ('body{margin:0;background:#fff}#panel{position:relative;width:%dpx;height:%dpx;background:url(file://%s) '
           '0 0/100%% 100%% no-repeat}#lcd{position:absolute;left:%dpx;top:%dpx;width:%dpx;height:%dpx;background:#b3bdab;'
           'border-radius:5px;overflow:hidden}#lcd.off{background:#9aa394}'
           '#lcd img{position:absolute;inset:0;width:100%%;height:100%%;opacity:0;filter:brightness(0.05)}'
           '#lcd img.on{opacity:.92}') % (PW, PH, os.path.join(ASSETS, 'panel.png'), x0, y0, x1 - x0, y1 - y0)
    js = ('const BITS=%s, LAYERS=%s;function show(words){const on=new Set();if(words){for(let w=0;w<8;w++)'
          'for(let b=0;b<32;b++)if(words[w]>>>b&1)for(const n of BITS["w"+w+"b"+b]||[])on.add(n);}'
          'LAYERS.forEach((n,i)=>document.getElementById("L_"+i).classList.toggle("on",on.has(n)));'
          'document.getElementById("lcd").className=words?"":"off";}') % (json.dumps(bits), json.dumps(layers))
    return '<html><head><style>%s</style></head><body><div id="panel"><div id="lcd">%s</div></div><script>%s</script>' \
           '</body></html>' % (css, imgs, js)


def render(fr, out):
    from playwright.sync_api import sync_playwright
    from PIL import Image, ImageDraw, ImageFont
    html = os.path.join(tempfile.mkdtemp(prefix='ldbt_'), 'p.html')
    open(html, 'w').write(page())

    def font(size):
        try:
            return ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf', size)
        except OSError:
            return ImageFont.load_default()
    f_title, f_cap, f_key = font(64), font(46), font(40)
    top, bottom = 110, 130
    images, durs = [], []
    with sync_playwright() as p:
        br = p.chromium.launch()
        pg = br.new_page(viewport={'width': PW, 'height': PH})
        pg.goto('file://' + html)
        pg.wait_for_timeout(1500)
        for words, title, caption, mark, secs in fr:
            pg.evaluate('(w) => show(w)', list(words) if words else None)
            pg.wait_for_timeout(30)
            im = Image.open(io.BytesIO(pg.locator('#panel').screenshot())).convert('RGB').crop((0, 0, PW, CROP_H))
            canvas = Image.new('RGB', (PW, top + CROP_H + bottom), (255, 248, 225))
            canvas.paste(im, (0, top))
            d = ImageDraw.Draw(canvas)
            w = d.textlength(title, font=f_title)
            d.text(((PW - w) / 2, 22), title, fill=(220, 60, 30), font=f_title)
            if mark:
                x, y, r = SETUP_KEY
                y += top
                if mark == 'hold':                      # a second ring: held down, the key's name stays readable
                    d.ellipse((x - r - 24, y - r - 24, x + r + 24, y + r + 24), outline=(255, 30, 30), width=8)
                d.ellipse((x - r - 6, y - r - 6, x + r + 6, y + r + 6), outline=(255, 30, 30), width=12)
                tip, tail = x + r + 12, PW - 4          # a big arrow from the right edge onto the key
                d.polygon([(tail, y - 20), (tip + 50, y - 20), (tip + 50, y - 46), (tip, y), (tip + 50, y + 46),
                           (tip + 50, y + 20), (tail, y + 20)], fill=(255, 30, 30))
                word = 'HOLD' if mark == 'hold' else 'PRESS'
                ww = d.textlength(word, font=f_key)
                bx = PW - ww - 30
                d.rectangle((bx - 12, y - 128, bx + ww + 12, y - 72), fill=(255, 30, 30))
                d.text((bx, y - 124), word, fill=(255, 255, 255), font=f_key)
            fc, size = f_cap, 46
            while d.textlength(caption, font=fc) > PW - 30 and size > 24:   # long captions shrink to fit
                size -= 2
                fc = font(size)
            w = d.textlength(caption, font=fc)
            d.text(((PW - w) / 2, top + CROP_H + 36), caption, fill=(30, 30, 30), font=fc)
            canvas.thumbnail((WIDTH, WIDTH * 3), Image.LANCZOS)
            images.append(canvas)
            durs.append(int(secs * 1000))
        br.close()
    images = [i.quantize(colors=96, method=Image.Quantize.MEDIANCUT).convert('RGB') for i in images]
    images[0].save(out, save_all=True, append_images=images[1:], duration=durs, loop=0, optimize=True)
    print('%s: %d frames' % (out, len(images)))


def main(argv):
    out = argv[0] if argv else os.path.join(ROOT, 'firmware', 'docs', 'bootloader', 'to_ld_bt.gif')
    render(frames(), out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
