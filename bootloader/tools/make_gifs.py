"""Animated pictures of the meter's display for bootloader/README.md, made in the emulator.

    python3 -I bootloader/tools/make_gifs.py OUT_DIR       (after `make` in firmware/ and bootloader/; needs Pillow and
                                                             Playwright with Chromium)

Each scenario runs the emulator headless (bootloader/tests/test_bootloader.py helpers) and records the display words
(LCD_RAM as committed) with their emulated times; the frames are then drawn with the emulator page's own glass layers
(emulator/ui/assets: panel.png, lcd/*.svg, lcd_bits.json) in Chromium and written as GIF:
  bt_update.gif   firmware over Bluetooth: request from the firmware, "-IAP-", "Ld nn" with the bargraph, "Ld oK",
                  the new firmware starts
  card_update.gif MEM + HOLD at power-on, SETUP: "douun" with the bargraph, " Good", the firmware starts
"""
import io
import json
import os
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.dont_write_bytecode = True
sys.path[:0] = [os.path.join(ROOT, 'bootloader', 'tests')]
import test_bootloader as X                          # noqa: E402

ASSETS = os.path.join(ROOT, 'emulator', 'ui', 'assets')
PW, PH = 695, 1338
LCD_BOX = (123, 188, 570, 444)


class Recorder:
    """Emulated-time samples of the display: [(words, lit, seconds shown)]."""
    def __init__(self, e):
        self.e, self.frames = e, []
        self.last = X.T.now(e)

    def take(self, show=None):
        """Sample the display; `show` = seconds it stands for, default the emulated time since the last sample."""
        now = X.T.now(self.e)
        if show is None:
            show = now - self.last
        self.last = now
        s = self.e.snapshot()
        words = tuple(s['lcd']) if s['lcd_on'] else None
        if self.frames and self.frames[-1][0] == words:
            w, b, t = self.frames[-1]
            self.frames[-1] = (w, b, t + show)
        else:
            self.frames.append((words, bool(s['backlight']), show))

    def run(self, seconds, step):
        t = 0.0
        while t < seconds:
            self.e.advance(step)
            t += step
            self.take()


def bt_update():
    e = X.meter(X.flash_image())
    r = Recorder(e)
    r.run(1.0, 0.1)                                  # lamp test, firmware
    e.command({'dial': 2})
    r.run(2.0, 0.25)
    X.T.long_press(e, 'PEAK')                        # Bluetooth on
    r.run(0.5, 0.25)
    e.usart2.rx_feed(b'\xF4' + b'9191')              # the companion's "update now": restart into update mode
    r.run(2.0, 0.1)
    h = X.Host(e)
    data = X.APP
    orig = h.wait

    def wait(n, timeout):
        got = orig(n, timeout)
        if X.T.now(e) - r.last >= 2.0:              # one picture per 2 s of the transfer (time-lapse)
            r.take()
        return got
    h.wait = wait
    h.transfer(data, X.KIND_FW)
    r.run(4.0, 0.1)                                  # "Ld oK", restart, the new firmware
    return r.frames


def card_update():
    e = X.meter(X.flash_image(), keys=('MEM', 'HOLD'), card=X._card_with(X.APP))
    r = Recorder(e)
    r.run(1.0, 0.1)
    X.release(e)
    r.run(1.0, 0.2)
    e.command({'key': 'SETUP', 'down': True})
    r.run(0.3, 0.1)
    e.command({'key': 'SETUP', 'down': False})
    r.run(16.0, 0.25)
    return r.frames


def page(frames_json):
    bits = json.load(open(os.path.join(ASSETS, 'lcd_bits.json')))
    layers = sorted({n for v in bits.values() for n in v})
    imgs = ''.join('<img id="L_%d" src="file://%s">' % (i, os.path.join(ASSETS, 'lcd', n + '.svg'))
                   for i, n in enumerate(layers))
    x0, y0, x1, y1 = LCD_BOX
    css = ('body{margin:0;background:#fff}#panel{position:relative;width:%dpx;height:%dpx;background:url(file://%s) '
           '0 0/100%% 100%% no-repeat}#lcd{position:absolute;left:%dpx;top:%dpx;width:%dpx;height:%dpx;background:#b3bdab;'
           'border-radius:5px;overflow:hidden}#lcd.lit{background:#c9e8c1}#lcd.off{background:#9aa394}'
           '#lcd img{position:absolute;inset:0;width:100%%;height:100%%;opacity:0;filter:brightness(0.05)}'
           '#lcd img.on{opacity:.92}') % (PW, PH, os.path.join(ASSETS, 'panel.png'), x0, y0, x1 - x0, y1 - y0)
    js = ('const BITS=%s, LAYERS=%s;function show(words,lit){const on=new Set();if(words){for(let w=0;w<8;w++)'
          'for(let b=0;b<32;b++)if(words[w]>>>b&1)for(const n of BITS["w"+w+"b"+b]||[])on.add(n);}'
          'LAYERS.forEach((n,i)=>document.getElementById("L_"+i).classList.toggle("on",on.has(n)));'
          'const l=document.getElementById("lcd");l.className=words?(lit?"lit":""):"off";}') % (json.dumps(bits),
                                                                                              json.dumps(layers))
    return '<html><head><style>%s</style></head><body><div id="panel"><div id="lcd">%s</div></div><script>%s</script>' \
           '</body></html>' % (css, imgs, js)


def render(frames, out, width=260):
    from playwright.sync_api import sync_playwright
    from PIL import Image
    html = os.path.join(tempfile.mkdtemp(prefix='blgif_'), 'p.html')
    open(html, 'w').write(page(None))
    images, durs = [], []
    with sync_playwright() as p:
        br = p.chromium.launch()
        pg = br.new_page(viewport={'width': PW, 'height': PH})
        pg.goto('file://' + html)
        pg.wait_for_timeout(1500)
        for words, lit, secs in frames:
            if secs <= 0:
                continue
            pg.evaluate('([w,l]) => show(w,l)', [list(words) if words else None, lit])
            pg.wait_for_timeout(30)
            im = Image.open(io.BytesIO(pg.locator('#panel').screenshot())).convert('RGB')
            im = im.crop((0, 0, PW, 700))            # display and keys; the dial is not part of these pictures
            im.thumbnail((width, width * 2), Image.LANCZOS)
            images.append(im)
            durs.append(int(max(0.08, min(1.8, secs / 6.0)) * 1000))   # time-lapse: one sixth of the emulated time
        br.close()
    images = [i.quantize(colors=48, method=Image.Quantize.MEDIANCUT).convert('RGB') for i in images]
    images[0].save(out, save_all=True, append_images=images[1:], duration=durs, loop=0, optimize=True)
    print('%s: %d frames' % (out, len(images)))


def main(argv):
    out = argv[0] if argv else os.path.join(ROOT, 'bootloader', 'docs')
    os.makedirs(out, exist_ok=True)
    render(bt_update(), os.path.join(out, 'bt_update.gif'))
    render(card_update(), os.path.join(out, 'card_update.gif'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
