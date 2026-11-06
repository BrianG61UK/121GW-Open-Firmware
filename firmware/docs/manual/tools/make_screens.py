"""Still pictures of the meter's display for the user manual, made in the emulator.

    /tmp/eev/venv/bin/python -I firmware/docs/manual/tools/make_screens.py [GROUP ...] [--out DIR] [--jobs N]
                                                                         [--bootloader-src DIR]

Without GROUP every group runs, each in its own process (`timeout 1500` each; `--jobs` at a time, default 1).  Needs
firmware/build/EEVBlog.bin (`make PYTHON=/tmp/eev/venv/bin/python` in firmware/), and Pillow and Playwright with Chromium.
Groups:
  dial     every dial position and its MODE functions with a typical input (the normal display)
  func     function states: HOLD, REL, PEAK, MIN/MAX, bar graph, overload, auto / manual range, logging, Bluetooth, filter
  setup    every SETUP page of DCV (the pages shared by all functions), normal and edit state; also with MIN/MAX on
           (statistics pages) and with Bluetooth on
  setupm1..4  the SETUP pages that differ from DCV's, for the other functions (Low Z, V and mV / Temp; Hz and Ohm / ...;
           mVA / VA and uA / uVA; A / mA), normal and edit state (the walk of setupm2 draws the CAP page HUnt by itself: no code per page)
  special  lamp test, version, power-off, cal.bin messages, logging messages, SD errors
  limit    the limit test (Lt, Lo, HI pages and the PASS / HI / Lo verdicts) and the logging trigger pages (tr, Ch)
  boot     the bootloader's screens: lamp test, -IAP-, Ld nn, Ld oK, the card update
  bootfw   the firmware's pages that need the two-part bootloader: Ld-bt, Ld nn, Ld oK, For (Fr no, Fr yE, Fr --, Fr oK)
           (boot and bootfw run in the bootloader branch's tree, --bootloader-src DIR, default ../121gw-work/bootloader-src next to the repository:
           it holds the bootloader build and tests/test_bootloader.py; its emulator and firmware sources equal this tree's)

How a picture is made: the emulator runs the production firmware image with the synthetic EEPROM (serial bytes 0x003..0x006
set to 0; no meter's calibration), the dial, keys and the input at the test leads are set as a user would, and the display
words (LCD RAM, as committed by the firmware) are drawn with the emulator page's own glass layers and panel drawing
(emulator/ui/assets).  No segment is drawn by hand.  The pictures and img/INDEX.md (file, what it shows, how it was made)
are written to firmware/docs/manual/img.
"""
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.normpath(os.path.join(HERE, '..', '..', '..'))          # firmware/
ROOT = os.path.normpath(os.path.join(FW, '..'))                       # repository root
ASSETS = os.path.join(ROOT, 'emulator', 'ui', 'assets')
IMAGE = os.path.join(FW, 'build', 'EEVBlog.bin')
OUT = os.path.join(FW, 'docs', 'manual', 'img')
BL_SRC = os.path.normpath(os.path.join(ROOT, '..', '121gw-work', 'bootloader-src'))

def fw_version():
    """The firmware version text the image shows at power-on, from firmware/src/inc/config.inc (FW_VER_C0..C4)."""
    txt = open(os.path.join(ROOT, 'firmware', 'src', 'inc', 'config.inc')).read()
    c = [re.search(r"\.equ FW_VER_C%d, '(.)'" % k, txt).group(1) for k in range(5)]
    return '%s%s%s.%s%s' % tuple(c)

GROUPS = ['dial', 'func', 'setup', 'setupm1', 'setupm2', 'setupm3', 'setupm4', 'special', 'limit', 'boot', 'bootfw', 'feat']
TITLES = {'dial': 'Dial positions and functions', 'func': 'Function states', 'setup': 'SETUP pages common to all functions (DCV)',
          'setupm1': 'SETUP pages of Low Z, V and mV / Temp that differ from DCV', 'setupm2': 'SETUP pages of Hz and Ohm / beep / diode / cap that differ from DCV',
          'setupm3': 'SETUP pages of mVA / VA and uA / uVA that differ from DCV', 'setupm4': 'SETUP pages of A / mA that differ from DCV',
          'special': 'Special screens', 'limit': 'Limit test and logging trigger pages', 'boot': 'Bootloader screens', 'bootfw': 'Firmware pages that need the two-part bootloader',
          'feat': 'Features of the open firmware in use'}
PW, PH = 695, 1338                                                    # panel drawing size (emulator/ui/index.html)
LCD_BOX = (123, 188, 570, 444)
DOTS = [-80.6, -62.4, -44.0, -25.9, -8.3, 9.4, 27.4, 44.5, 62.9, 81.1]  # pointer angles per dial position
JACKS = {'A': (163, 1183), 'mA': (313, 1183), 'COM': (462, 1183), 'V': (532, 1053)}
DIAL_NAMES = ['OFF', 'Low Z', 'V', 'mV / Temp', 'Hz ms %', 'Ohm / beep / diode / cap', 'mVA / VA', 'uA / uVA', 'A / mA', 'OFF']
CROP_TOP = 665                                                        # display and keys; the dial is cut off
ADDR_ITEM = 0x20008037                                                # SETUP item (tests/test_exfat.py)
ADDR_APO = 0x20000230                                                 # APO countdown, u16
ADDR_EDIT = 0x2000806E                                                # SETUP edit active (set_edit)
SETUP_MODES = {'setupm1': [(1, None), (2, None), (3, None)], 'setupm2': [(4, None), (5, None)],
               'setupm3': [(6, 'mA'), (6, 'A'), (7, 'mA')], 'setupm4': [(8, 'mA'), (8, 'A')]}
T = None                                                              # test_backlight_timer helpers (loaded by load())


# ---------------------------------------------------------------------------------------------- emulator helpers
def load():
    """Import the emulator helpers of the tree this process works in (once)."""
    global T
    if T is not None:
        return
    sys.path.insert(0, os.path.join(ROOT, 'emulator', 'scripts'))
    import test_backlight_timer as t                                  # noqa: E402
    T = t


def meter(card=None, patch=None):
    """Emulator with the production image, the synthetic EEPROM (serial bytes 0), a quiet front end, dial at V."""
    load()
    p = {3: 0, 4: 0, 5: 0, 6: 0}
    p.update(patch or {})
    T.Emulator.hy_seed = 1
    T.Emulator.hy_noise = False                                       # ideal input: the same reading every run
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(IMAGE, p)
    e.command({'environment': {'pickup_v': 0}})                      # shielded: no mains pickup on the open leads
    return e


def new_card():
    load()
    from emu.sdcard import format_fat32
    path = os.path.join(tempfile.mkdtemp(prefix='manual_'), 'card.img')
    format_fat32(path, 64 * 1024 * 1024)
    return path


def snap(e):
    return e.snapshot()


def mode_name(e):
    return snap(e)['frontend'].get('mode_name')


def text(e):
    """(main, sub, annunciators) of the display now."""
    return T.DEC.text(snap(e)['lcd'])


def popcount(words):
    return sum(bin(w).count('1') for w in words)


# Stimulus per firmware mode (SI units): a typical value for the manual.  Modes of the VA positions carry both quantities.
STIM = {
    'LowZ': dict(kind='V', value=12.0), 'DCV': dict(kind='V', value=1.234),
    'ACV': dict(kind='V', value=12.34, ac=True, freq=50), 'DCmV': dict(kind='V', value=0.1234),
    'ACmV': dict(kind='V', value=0.1, ac=True, freq=1000), 'TEMP': dict(kind='degC', value=100, board=23),
    'FREQ': dict(kind='Hz', value=1000), 'PULSE': dict(kind='Hz', value=1000, width=0.0002),
    'DUTY': dict(kind='Hz', value=1000, duty=0.25), 'OHM': dict(kind='ohm', value=4700), 'BEEP': dict(kind='ohm', value=10),
    'DIODE': dict(kind='diode', value=0.65), 'CAP': dict(kind='F', value=100e-9),
    'uVA': dict(kind='VA', value=0.05, amps=100e-6, ac=True, freq=50), 'mVA': dict(kind='VA', value=1.0, amps=10e-3, ac=True, freq=50),
    'VA': dict(kind='VA', value=12.0, amps=1.0, ac=True, freq=50),
    'ACuA': dict(kind='A', value=200e-6, ac=True, freq=50), 'DCuA': dict(kind='A', value=123.4e-6),
    'ACmA': dict(kind='A', value=20e-3, ac=True, freq=50), 'DCmA': dict(kind='A', value=12.34e-3),
    'ACA': dict(kind='A', value=1.5, ac=True, freq=50), 'DCA': dict(kind='A', value=1.234),
    'DCuVA': dict(kind='VA', value=0.05, amps=100e-6), 'DCmVA': dict(kind='VA', value=1.0, amps=10e-3),
    'DCVA': dict(kind='VA', value=12.0, amps=1.0),
}
JACK = {m: 'mA' for m in ('uVA', 'mVA', 'ACuA', 'DCuA', 'ACmA', 'DCmA', 'DCuVA', 'DCmVA')}
JACK.update({m: 'A' for m in ('VA', 'ACA', 'DCA', 'DCVA')})
SETTLE = {'CAP': 6.0, 'TEMP': 4.0, 'FREQ': 4.0, 'PULSE': 4.0, 'DUTY': 4.0}
SETTLE.update({m: 9.0 for m in ('uVA', 'mVA', 'VA', 'DCuVA', 'DCmVA', 'DCVA')})     # the first VA reading takes about 4 s


def plug(e, jack):
    """Plug the current jack `jack` ('A', 'mA' or None) and unplug the other."""
    for j in ('A', 'mA'):
        e.command({'jack': j, 'plugged': j == jack})


def apply_stim(e, mode, **over):
    """Present the typical input of the mode (over: fields replaced); the input as text."""
    st = dict(STIM[mode])
    st.update(over)
    e.command({'input': st})
    return stim_text(st, JACK.get(mode))


def stim_text(st, jack=None):
    k, v = st['kind'], st.get('value', 0)
    units = {'V': 'V', 'A': 'A', 'ohm': 'ohm', 'Hz': 'Hz', 'F': 'F', 'degC': 'degC', 'diode': 'V', 'VA': 'V'}[k]
    s = '%s %g %s' % (k, v, units)
    if st.get('ac'):
        s += ' AC rms %g Hz' % st.get('freq', 0)
    if k == 'VA':
        s += ' and %g A' % st['amps']
    if st.get('width'):
        s += ', high time %g s' % st['width']
    if st.get('duty') and k == 'Hz':
        s += ', duty %g' % st['duty']
    if st.get('board') is not None:
        s += ', board %g degC' % st['board']
    if jack:
        s += ', jack %s plugged' % jack
    return s


def modes_of(e, dial, cap=8):
    """Go to the dial position and step MODE through its functions: yields (mode name, mode index) once per function."""
    e.command({'dial': dial})
    e.advance(2.0)
    first = prev = None
    for k in range(cap):
        sig = (mode_name(e), 'AC_DC+' in text(e)[2])
        if k and (sig == first or sig == prev):                      # back at the first function, or MODE has no effect here
            return
        first = first or sig
        prev = sig
        yield sig[0], k
        T.press(e, 'MODE', hold=0.15, gap=0.4)
        e.advance(0.6)


# ---------------------------------------------------------------------------------------------- shots and output
class Rec:
    """The pictures of one group: each is (file, display words, backlight, dial, plugged jacks, crop, what, how)."""
    def __init__(self, group):
        self.group, self.shots, self.missed = group, [], []
        self.names = set()

    def add(self, e, name, shows, how, crop='top', words=None, note=True):
        assert name not in self.names, 'duplicate picture ' + name
        self.names.add(name)
        s = snap(e)
        w = list(words if words is not None else s['lcd'])
        main, sub, ann = T.DEC.text(w)
        if note:
            shows += ' - main display "%s", sub display "%s"%s' % (main.strip(), sub.strip(), ann_str(ann))
        self.shots.append((name + '.png', w, bool(s['backlight']), s['dial'], list(s['jacks']), crop, shows, how))
        print('  %-28s main %-8r sub %-8r %s' % (name, main, sub, ann_str(ann).strip()), flush=True)

    def miss(self, what, why):
        self.missed.append((what, why))
        print('  NOT MADE %s: %s' % (what, why), flush=True)

    def blink(self, e, name, shows, how, crop='top', n=12, step=0.1):
        """A blinking value: the picture of the phase with the most segments on (the value shown)."""
        best = None
        for _ in range(n):
            w = list(snap(e)['lcd'])
            if best is None or popcount(w) > popcount(best):
                best = w
            e.advance(step)
        self.add(e, name, shows, how, crop, words=best)


def ann_str(ann):
    """The lit annunciators (not the fixed bar graph scale) and how many bar graph segments are on."""
    bars = [a for a in ann if a.startswith('bar')]
    rest = [a for a in ann if not a.startswith('bar') and not a.startswith('Bar')]
    s = ''
    if rest:
        s += ', lit: ' + ' '.join(rest)
    if bars:
        s += ', bar graph %d segments' % len(bars)
    return s


def sane(s):
    return ''.join(c if c.isalnum() else '_' for c in s.strip()).strip('_') or 'blank'


def page_html():
    bits = json.load(open(os.path.join(ASSETS, 'lcd_bits.json')))
    layers = sorted({n for v in bits.values() for n in v})
    imgs = ''.join('<img id="L_%d" src="file://%s">' % (i, os.path.join(ASSETS, 'lcd', n + '.svg')) for i, n in enumerate(layers))
    x0, y0, x1, y1 = LCD_BOX
    ridges = ''.join('<circle cx="%.2f" cy="%.2f" r="13" fill="#1d2023" stroke="#050606" stroke-width="2"/>' % (
        347 + 148 * __import__('math').sin(a * 3.14159265 / 180), 873.6 - 148 * __import__('math').cos(a * 3.14159265 / 180))
        for a in range(0, 360, 30))
    jacks = ''.join('<div class="jack" id="J_%s" style="left:%dpx;top:%dpx"></div>' % (n, x - 36, y - 36) for n, (x, y) in JACKS.items())
    css = ('body{margin:0;background:#fff}#panel{position:relative;width:%dpx;height:%dpx;background:url(file://%s) 0 0/100%% 100%% '
           'no-repeat}#lcd{position:absolute;left:%dpx;top:%dpx;width:%dpx;height:%dpx;background:#b3bdab;border-radius:5px;'
           'overflow:hidden}#lcd.lit{background:#c9e8c1}#lcd.off{background:#9aa394}#lcd img{position:absolute;inset:0;width:100%%;'
           'height:100%%;opacity:0;filter:brightness(0.05)}#lcd img.on{opacity:.92}#knob{position:absolute;left:0;top:0}'
           '.jack{position:absolute;width:72px;height:72px;border-radius:50%%}.jack.on{background:radial-gradient(circle,#cfd3d6 0 34%%,'
           '#1b1d1f 35%% 48%%,#c62626 49%% 64%%,#0000 65%%)}') % (PW, PH, os.path.join(ASSETS, 'panel.png'), x0, y0, x1 - x0, y1 - y0)
    knob = ('<svg id="knob" width="%d" height="%d" viewBox="0 0 %d %d"><defs><radialGradient id="kg" cx="50%%" cy="45%%" r="55%%">'
            '<stop offset="0" stop-color="#2a2d30"/><stop offset="1" stop-color="#121416"/></radialGradient></defs>'
            '<circle cx="347" cy="873.6" r="176" fill="#0c0d0e"/><circle cx="347" cy="873.6" r="168" fill="url(#kg)"/>%s'
            '<g id="pointer"><path d="M 347 696 L 371 762 L 371 1018 L 347 1034 L 323 1018 L 323 762 Z" fill="#2e3236" stroke="#000" '
            'stroke-width="3"/><rect x="340" y="734" width="14" height="40" rx="4" fill="#f2f2f2" stroke="#000" stroke-width="2"/></g>'
            '</svg>') % (PW, PH, PW, PH, ridges)
    js = ('const BITS=%s, LAYERS=%s, DOTS=%s;function show(words,lit,dial,jacks){const on=new Set();if(words){for(let w=0;w<8;w++)'
          'for(let b=0;b<32;b++)if(words[w]>>>b&1)for(const n of BITS["w"+w+"b"+b]||[])on.add(n);}'
          'LAYERS.forEach((n,i)=>document.getElementById("L_"+i).classList.toggle("on",on.has(n)));'
          'const l=document.getElementById("lcd");l.className=words?(lit?"lit":""):"off";'
          'document.getElementById("pointer").setAttribute("transform","rotate("+DOTS[dial]+" 347 873.6)");'
          'for(const j of ["A","mA","COM","V"])document.getElementById("J_"+j).classList.toggle("on",jacks.includes(j));}'
          ) % (json.dumps(bits), json.dumps(layers), json.dumps(DOTS))
    return ('<html><head><style>%s</style></head><body><div id="panel"><div id="lcd">%s</div>%s%s</div><script>%s</script></body>'
            '</html>') % (css, imgs, knob, jacks, js)


def render(shots, out):
    """Draw every shot with the emulator page's glass layers in Chromium; PNG files in `out`."""
    from playwright.sync_api import sync_playwright
    from PIL import Image
    os.makedirs(out, exist_ok=True)
    html = os.path.join(tempfile.mkdtemp(prefix='manual_page_'), 'p.html')
    open(html, 'w').write(page_html())
    with sync_playwright() as p:
        br = p.chromium.launch()
        pg = br.new_page(viewport={'width': PW, 'height': PH})
        pg.goto('file://' + html)
        pg.wait_for_timeout(1500)
        for fn, words, lit, dial, jacks, crop, _what, _how in shots:
            pg.evaluate('([w,l,d,j]) => show(w,l,d,j)', [words, lit, dial, jacks])
            pg.wait_for_timeout(30)
            im = Image.open(io.BytesIO(pg.locator('#panel').screenshot())).convert('RGB')
            if crop == 'top':
                im = im.crop((0, 0, PW, CROP_TOP))
            im.save(os.path.join(out, fn), optimize=True)
        br.close()


def write_index(out, group, rec):
    """Replace the section of `group` in INDEX.md, keep the others (in group order)."""
    path = os.path.join(out, 'INDEX.md')
    secs = {}
    if os.path.isfile(path):
        for part in open(path).read().split('\n## ')[1:]:
            title, _, body = part.partition('\n')
            secs[title.strip()] = body.strip('\n')
    lines = ['| File | What it shows | How it was made |', '|---|---|---|']
    for fn, _w, _l, _d, _j, crop, what, how in rec.shots:
        lines.append('| %s | %s | %s |' % (fn, what.replace('|', '/'), how.replace('|', '/')))
    if rec.missed:
        lines += ['', 'Not made:', ''] + ['- %s: %s' % m for m in rec.missed]
    secs[TITLES[group]] = '\n'.join(lines)
    head = ('# Display pictures for the user manual\n\nMade by `tools/make_screens.py` from the emulator running the production '
            'firmware (`firmware/build/EEVBlog.bin`, ' + fw_version() + ') with the synthetic EEPROM; every picture shows the display words '
            'the firmware wrote, drawn with the emulator page\'s glass layers.  Pictures that show the whole front panel '
            '(695 x 1338 px) include the dial position and the plugged jacks; the others are cut off below the keys (695 x %d px).  '
            '"main" and "sub" are the decoded text of the main and sub display (the font draws S like 5, b like B, I like 1).  '
            'Keys: "long" = held 1 s.  In the edit state of a SETUP page (SETUP held 1 s) the value blinks; an edit picture is made '
            'only where the lit phase differs from the normal page, otherwise the normal page picture shows it.  The emulator runs '
            'without measurement noise, so every run gives the same readings.\n') % CROP_TOP
    body = ''.join('\n## %s\n\n%s\n' % (TITLES[g], secs[TITLES[g]]) for g in GROUPS if TITLES[g] in secs)
    open(path, 'w').write(head + body)


# ---------------------------------------------------------------------------------------------- groups
def sub_phase(e, want, limit=8.0):
    """Run until the sub display of a VA function shows the voltage ('SubV') or the current ('SubA'): it alternates every 3 s."""
    t = 0.0
    while 'Sub' + want not in text(e)[2] and t < limit:
        e.advance(0.25)
        t += 0.25
    e.advance(0.5)


def g_dial(r):
    e = meter()
    # the VA and current positions offer other functions with the A jack plugged than with the mA jack plugged; the uA / uVA
    # position takes its current through the mA jack only (with the A jack plugged the meter shows LEAD)
    for dial, jack in [(d, None) for d in range(1, 6)] + [(6, 'mA'), (6, 'A'), (7, 'mA'), (8, 'mA'), (8, 'A')]:
        plug(e, jack)
        for m, k in modes_of(e, dial):
            if m not in STIM:
                r.miss('dial %d %s' % (dial, m), 'no typical input defined')
                continue
            how = 'dial %d (%s)%s, MODE pressed %d x; input %s' % (dial, DIAL_NAMES[dial], ', jack %s plugged' % jack if jack else '',
                                                                   k, apply_stim(e, m))
            e.advance(SETTLE.get(m, 3.0))
            f = snap(e)['frontend']
            print('    mode %s supported %s %s' % (m, f.get('supported'), f.get('reason')), flush=True)
            name = 'dial_%s' % m
            if not f.get('supported', True):
                r.miss(name, 'the emulator cannot present this input in this function: %s' % f.get('reason'))
                continue
            if name + '.png' in [x[0] for x in r.shots]:
                name += '_%d' % k if 'AC_DC+' in text(e)[2] else '_' + (jack or 'x')
            if name + '.png' in [x[0] for x in r.shots]:
                continue
            if m.endswith('VA'):                                    # the sub display alternates between the voltage and the current
                sub_phase(e, 'V')
                r.add(e, name, 'Dial %s, function %s, sub display showing the voltage' % (DIAL_NAMES[dial], m), how, crop='full')
                sub_phase(e, 'A')
                r.add(e, name + '_current', 'Dial %s, function %s, sub display showing the current' % (DIAL_NAMES[dial], m), how, crop='full')
            else:
                r.add(e, name, 'Dial %s, function %s' % (DIAL_NAMES[dial], m), how, crop='full')


def g_func(r):
    card = new_card()
    e = meter(card=card, patch={0x1E: 0, 0x18: 0, 0x19: 1})        # buzzer on, logging interval 1 s (tests/test_sd_errors.py)
    e.command({'dial': 2})
    e.advance(2.0)

    def volts(v, **kw):
        st = dict(kind='V', value=v, **kw)
        e.command({'input': st})
        return stim_text(st)

    def need(cond, what):
        if not cond:
            raise SystemExit('FAIL: ' + what)

    # HOLD
    how = 'dial 2 (V), DCV; input %s; ' % volts(1.0)
    e.advance(3.0)
    T.press(e, 'HOLD')
    e.advance(1.0)
    need('HOLD' in text(e)[2], 'HOLD not lit')
    r.add(e, 'func_hold', 'HOLD: the reading is frozen', how + 'HOLD pressed once')
    T.press(e, 'HOLD')
    e.advance(1.5)
    need('A-' in text(e)[2], 'AutoHOLD (A-) not lit after the second press')
    r.add(e, 'func_autohold', 'AutoHOLD: the A- symbol and HOLD are lit', how + 'HOLD pressed twice')
    T.press(e, 'HOLD')
    e.advance(1.5)
    need('HOLD' not in text(e)[2] and 'A-' not in text(e)[2], 'HOLD not off after the third press')
    # REL
    e.advance(2.0)
    T.press(e, 'REL')
    e.advance(1.0)
    how = 'DCV; input 1.0 V, REL pressed, input then raised to %s' % volts(1.5)
    e.advance(3.0)
    need('REL' in text(e)[2], 'REL not lit')
    r.add(e, 'func_rel', 'REL: the reading relative to the value when REL was pressed (1.5 V - 1.0 V)', how)
    T.press(e, 'REL')
    volts(1.234)
    e.advance(2.5)
    # MIN/MAX
    how = 'DCV; input 1.0 V, MIN/MAX pressed, input then 2.0 V, then 0.5 V, then %s; ' % volts(1.234)
    volts(1.0)
    e.advance(2.5)
    T.press(e, 'MINMAX')
    volts(2.0)
    e.advance(2.5)
    volts(0.5)
    e.advance(2.5)
    volts(1.234)
    e.advance(2.5)
    names = []
    for k in range(1, 5):
        ann = text(e)[2]
        tag = [a for a in ('MAX', 'MIN', 'AVG') if a in ann]
        nm = 'func_%s' % ('_'.join(t.lower() for t in tag) if len(tag) < 3 and tag else 'minmax_all' if tag else 'minmax%d' % k)
        if nm in r.names:
            break
        r.add(e, nm, 'MIN/MAX mode, %s shown (MIN/MAX pressed %d x)' % (' '.join(tag) or 'no MAX / MIN symbol', k),
              how + 'MIN/MAX pressed %d x in all' % k)
        T.press(e, 'MINMAX')
        e.advance(1.0)
    T.long_press(e, 'MINMAX')                                      # leave MIN/MAX
    e.advance(1.5)
    need('MAX' not in text(e)[2] and 'MIN' not in text(e)[2], 'MIN/MAX not left')
    # bar graph
    how = 'DCV; input %s' % volts(3.0)
    e.advance(3.0)
    r.add(e, 'func_bargraph', 'Bar graph at 3.0 V of the 5 V range (about 60 %)', how)
    # auto / manual range
    volts(1.234)
    e.advance(3.0)
    need('auto' in text(e)[2], 'AUTO not lit')
    r.add(e, 'func_range_auto', 'Auto range: the AUTO symbol is lit', 'DCV; input 1.234 V; nothing pressed')
    T.press(e, 'RANGE')
    e.advance(2.0)
    need('auto' not in text(e)[2], 'AUTO still lit')
    r.add(e, 'func_range_manual', 'Manual range (RANGE pressed once): the AUTO symbol is off', 'DCV; input 1.234 V; RANGE pressed once')
    T.long_press(e, 'RANGE')
    e.advance(1.5)
    need('auto' in text(e)[2], 'auto range not back')
    # overload
    how = 'DCV; input %s' % volts(650.0)
    e.advance(3.0)
    r.add(e, 'func_highvoltage', 'High-voltage symbol (Shock) lit at 650 V', how)
    volts(1.234)
    e.command({'dial': 3})
    e.advance(2.0)
    how = 'dial 3 (mV), DCmV; input %s' % volts(0.7)
    e.advance(3.0)
    r.add(e, 'func_ofl_mv', 'Overload on the mV range', how)
    e.command({'input': {'kind': 'open'}})
    e.command({'dial': 5})
    e.advance(2.0)
    e.advance(3.0)
    r.add(e, 'func_ofl_ohm', 'Ohm, test leads open: overload', 'dial 5 (Ohm), OHM; input open')
    # 1 kHz filter, PEAK (ACV)
    e.command({'dial': 2})
    e.advance(2.0)
    T.press(e, 'MODE')
    e.advance(0.6)
    need(mode_name(e) == 'ACV', 'not in ACV')
    how = 'dial 2 (V), ACV; input %s; ' % volts(12.34, ac=True, freq=50)
    e.advance(3.0)
    T.press(e, 'PEAK')
    e.advance(3.0)
    r.add(e, 'func_peak', 'PEAK in ACV (symbol MAX, sub display in ms): the state is the firmware\'s; the value is not representative, '
          'the emulator does not derive the peak converter (AD2) from the input', how + 'PEAK pressed')
    T.press(e, 'PEAK')
    e.advance(1.5)
    T.long_press(e, 'REL')
    e.advance(3.0)
    need('1 kHz' in text(e)[2], '1 kHz filter not lit')
    r.add(e, 'func_filter', 'The 1 kHz filter is on in ACV', how + 'REL held 1 s')
    T.long_press(e, 'REL')
    e.advance(1.5)
    # Bluetooth
    T.press(e, 'MODE')
    e.advance(0.6)
    T.press(e, 'MODE')
    e.advance(1.0)
    volts(1.234)
    e.advance(2.0)
    T.long_press(e, 'PEAK')
    e.advance(2.0)
    need('bt' in text(e)[2], 'Bluetooth symbol not lit')
    r.add(e, 'func_bluetooth', 'Bluetooth is on: the bt symbol is lit', 'DCV; input 1.234 V; PEAK held 1 s')
    T.long_press(e, 'PEAK')
    e.advance(1.5)
    # logging
    T.long_press(e, 'MEM')
    e.advance(4.0)
    r.add(e, 'func_logging', 'Logging to the SD card is running (MEM symbol)',
          'DCV; input 1.234 V; SD card (FAT32 image) inserted; logging interval 1 s; MEM held 1 s, 4 s later')
    T.long_press(e, 'MEM')
    e.advance(2.0)


def walk(e, r, how, prefix, base, known, capture=True):
    """Press SETUP through every page once (back to the first); the pages not in `base` / `known` are drawn, each in its
    normal state and, when a long SETUP starts an edit, in the edit state (the value blinks).  The next SETUP press leaves
    the edit without saving.  Returns the set of (item, sub display text) seen."""
    seen, start = set(), None
    for n in range(70):
        if n:
            T.press(e, 'SETUP', hold=0.15, gap=0.35)
            e.advance(0.4)
        item = T.rd(e, ADDR_ITEM)
        if start is None:
            start = item
        elif item == start:
            return seen
        sub = T.sub_text(e)
        key = (item, None if item in (5, 6, 7) else sub)           # the time pages change with the clock
        seen.add(key)
        if not capture or key in base or key in known:
            continue
        known.add(key)
        name = 'setup_%s%02d_%s' % (prefix, item, sane(sub))
        r.add(e, name, 'SETUP page %s (item %d)' % (sub.strip(), item), '%s; SETUP pressed %d x' % (how, n))
        if item == 8:                                              # the ID edit moves a digit cursor and has no short-press exit
            r.miss(name + '_edit', 'the edit of the ID page (item 8) is left only by saving the serial number or after 2 minutes')
            continue
        normal = text(e)
        T.long_press(e, 'SETUP')
        if T.rd(e, ADDR_EDIT):
            best = max((list(snap(e)['lcd']) for _ in range(12) if not e.advance(0.1)), key=popcount)   # phase with the value lit
            t = T.DEC.text(best)
            if t[1] != normal[1] or [a for a in t[2] if not a.startswith('bar')] != [a for a in normal[2] if not a.startswith('bar')]:
                r.add(e, name + '_edit', 'Edit state of page %s: the value changes look and blinks (the picture shows the phase with the value lit)' % sub.strip(),
                      '%s; SETUP pressed %d x, then held 1 s' % (how, n), words=best)
    raise SystemExit('SETUP pages did not wrap around')


def g_setup(r):
    e = meter()
    how = 'dial 2 (V), DCV; input %s' % apply_stim(e, 'DCV')
    e.advance(10.0)                                                # the version (fw_version()) stays on the sub display for a few seconds
    known = set()
    walk(e, r, how, '', set(), known)
    T.press(e, 'MINMAX')                                           # the MIN/MAX statistics and time pages
    e.advance(4.0)
    walk(e, r, how + '; MIN/MAX pressed once', '', set(), known)
    T.long_press(e, 'MINMAX')
    e.advance(1.0)
    T.long_press(e, 'PEAK')                                        # Bluetooth on: page Ld-bt
    e.advance(2.0)
    walk(e, r, how + '; Bluetooth on (PEAK held 1 s)', '', set(), known)


def g_setupm(r, group):
    e = meter()
    apply_stim(e, 'DCV')
    e.advance(10.0)
    base = walk(e, r, '', '', set(), set(), capture=False)        # the pages every function has
    known = set()
    for dial, jack in SETUP_MODES[group]:
        plug(e, jack)
        for m, k in modes_of(e, dial):
            if m not in STIM:
                continue
            how = 'dial %d (%s)%s, MODE pressed %d x; input %s' % (dial, DIAL_NAMES[dial], ', jack %s plugged' % jack if jack else '',
                                                                   k, apply_stim(e, m))
            e.advance(2.5 if not m.endswith('VA') else 9.0)
            print('  %s%s: pages seen %d' % (m, ' (jack %s)' % jack if jack else '',
                                              len(walk(e, r, how, m + '_', base, known))), flush=True)


def until(e, pred, limit, step=0.05):
    """Run in steps until pred(e) holds; False after `limit` emulated seconds."""
    t = 0.0
    while t < limit:
        if pred(e):
            return True
        e.advance(step)
        t += step
    return pred(e)


def sd_error(r, e, t, what, how):
    """The picture of an SdE nn message on the sub display (the font draws S like 5): named by its number."""
    sub = t[1].replace('.', '').strip().upper()
    if sub.startswith(('5DE', 'SDE')):
        r.add(e, 'msg_SdE' + sub[3:], 'SD error "SdE %s": %s' % (sub[3:], what), how)
    else:
        r.miss('msg_SdExx', 'no SdE message (%s): main "%s", sub "%s"' % (what, t[0], t[1]))


def g_special(r):
    import struct
    # power-on: the version on the sub display, the lamp test of the power-on window (RANGE)
    e = meter(card=new_card())
    e.command({'reset': True})
    if until(e, lambda e: text(e)[1].strip() == fw_version(), 3.0):
        r.add(e, 'special_version', 'Power-on: the firmware version on the sub display (the main display is still blank)',
              'dial 2 (V); power cycle, display after %.2f s' % (snap(e)['time_ms'] / 1000.0))
    else:
        r.miss('special_version', 'no %s on the sub display within 3 s of the power-up' % fw_version())
    e.command({'reset': True})
    e.advance(0.5)
    e.command({'key': 'RANGE', 'down': True})
    e.advance(0.3)
    lit = popcount(snap(e)['lcd'])
    r.add(e, 'special_lamptest', 'Lamp test of the power-on window: every segment on', 'power cycle, RANGE pressed 0.5 s later and held', note=False)
    print('    lamp test: %d segment bits on' % lit)
    e.command({'key': 'RANGE', 'down': False})
    # power-off screen
    e = meter()
    e.command({'dial': 2})
    e.advance(3.0)
    e.m.uc.mem_write(ADDR_APO, struct.pack('<H', 2))
    if until(e, lambda e: 'FF' in text(e)[0].upper(), 6.0, 0.02):
        r.add(e, 'msg_oFF', 'Power-off screen "-oFF-" (auto power-off, shown for the last beep)',
              'dial 2 (V); auto power-off countdown (RAM 0x20000230) set to 2 s and run out')
    else:
        r.miss('msg_oFF', 'not seen within 6 s of the countdown reaching 0')
    # cal.bin messages (power-on window with MEM held)
    card = new_card()
    e = meter(card=card)

    def window(e, keys, first):
        for k in keys:
            e.command({'key': k, 'down': True})
        e.command({'reset': True})
        e.advance(0.5)
        for k in keys:
            e.command({'key': k, 'down': False})
        e.advance(0.5)

    window(e, ['MEM'], 'MEM')
    r.add(e, 'msg_SdCAL', 'cal.bin menu "SdCAL" (MEM held at power-on)', 'power cycle with MEM held, released after 0.5 s')
    T.press(e, 'REL')
    e.advance(0.5)
    r.add(e, 'msg_SdSAv', 'cal.bin: save chosen, "SdSAv"', 'as msg_SdCAL, then REL pressed')
    T.press(e, 'MODE')
    until(e, lambda e: text(e)[0].strip().upper() in ('SAVED', '5AVED', '5AVEd'.upper()) or 'AVE' in text(e)[0].upper(), 8.0, 0.1)
    r.add(e, 'msg_SAvEd', 'cal.bin written to the card: "SAvEd"', 'as msg_SdSAv, then MODE pressed (card: empty FAT32 image)')
    window(e, ['MEM'], 'MEM')
    T.press(e, 'PEAK')
    e.advance(0.5)
    r.add(e, 'msg_SdSEt', 'cal.bin: load chosen, "SdSEt"', 'as msg_SdCAL, then PEAK pressed')
    e2 = meter(card=new_card())
    window(e2, ['MEM'], 'MEM')
    T.press(e2, 'PEAK')
    e2.advance(0.5)
    T.press(e2, 'MODE')
    until(e2, lambda e: text(e)[0].strip().upper().startswith('-ERR'), 8.0, 0.1)
    r.add(e2, 'msg_Err', 'cal.bin could not be loaded (no CAL.BIN on the card): "-Err-"',
          'power cycle with MEM held, PEAK, MODE; card: empty FAT32 image')
    # low battery: the battery symbol, and logging refused: LoBAt
    e = meter(card=new_card(), patch={0x1E: 0, 0x18: 0, 0x19: 1})
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.234}})
    e.advance(3.0)
    done = False
    for v in (4.6, 4.4, 4.2, 4.0, 3.8):
        e.command({'battery': v})
        e.advance(3.0)
        if 'Battery' in text(e)[2]:
            if 'special_battery' not in r.names:
                r.add(e, 'special_battery', 'Low-battery symbol (battery voltage %.1f V)' % v,
                      'DCV; input 1.234 V; battery set to %.1f V' % v)
            T.long_press(e, 'MEM')
            e.advance(1.5)
            if 'LOB' in text(e)[1].upper():
                r.add(e, 'msg_LoBAt', 'Logging refused because the battery is low: "LoBAt"',
                      'DCV; battery set to %.1f V; MEM held 1 s' % v)
                done = True
                break
            if snap(e)['lcd'] and 'MEM' in text(e)[2]:
                T.long_press(e, 'MEM')                             # logging started: stop it
                e.advance(1.0)
    if not done:
        r.miss('msg_LoBAt', 'logging was not refused at 4.6 .. 3.8 V battery')
    # card errors: no card in the socket
    e = meter()
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.234}})
    e.advance(3.0)
    T.long_press(e, 'MEM')
    e.advance(2.0)
    t = text(e)
    print('    no card, MEM long: main %r sub %r' % t[:2], flush=True)
    sd_error(r, e, t, 'logging started with no card in the socket', 'DCV; no SD card image; MEM held 1 s, display 2 s later')
    # a card without a file system (all zero): another error code
    blank = os.path.join(tempfile.mkdtemp(prefix='manual_'), 'blank.img')
    with open(blank, 'wb') as f:
        f.truncate(64 * 1024 * 1024)
    e = meter(card=blank)
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.234}})
    e.advance(3.0)
    T.long_press(e, 'MEM')
    e.advance(8.0)
    t = text(e)
    print('    blank card, MEM long: main %r sub %r' % t[:2], flush=True)
    sd_error(r, e, t, 'logging started with a card that has no file system (64 MiB of zeros)',
             'DCV; SD card image of zeros; MEM held 1 s, display 8 s later')
    # wrong jack: LEAD
    e = meter()
    plug(e, 'A')
    e.command({'dial': 7})
    e.advance(3.0)
    r.add(e, 'msg_LEAD', 'Wrong current jack: the uA position with the A jack plugged shows LEAD',
          'dial 7 (uA / uVA), jack A plugged')


def goto_item(e, item):
    """Press SETUP until the SETUP page `item` is shown."""
    for _ in range(50):
        if T.rd(e, ADDR_ITEM) == item:
            e.advance(0.3)
            return True
        T.press(e, 'SETUP', hold=0.15, gap=0.35)
        e.advance(0.4)
    return False


def g_limit(r):
    e = meter()
    e.command({'dial': 5})
    e.advance(2.5)

    def ohm(v):
        e.command({'input': {'kind': 'ohm', 'value': v}})
        e.advance(3.5)

    def need(cond, what):
        if not cond:
            raise SystemExit('FAIL: ' + what)

    how = 'dial 5 (Ohm), OHM'
    for item, name, value, what in ((28, 'lo', 99, 'low'), (29, 'hi', 101, 'high')):
        ohm(value)
        need(goto_item(e, item), 'page %d not reached' % item)
        r.add(e, 'limit_%s_page' % name, 'Limit test, page of the %s limit, nothing captured yet' % what,
              '%s; input %d ohm; SETUP pressed up to the page' % (how, value))
        T.long_press(e, 'SETUP')
        T.press(e, 'REL')
        e.advance(0.5)
        r.blink(e, 'limit_%s_edit' % name, 'Limit test, edit of the %s limit page after REL (the reading %d ohm is captured)' % (what, value),
                '%s; input %d ohm; the page, SETUP held 1 s, REL pressed' % (how, value))
        T.long_press(e, 'SETUP')
        e.advance(1.0)
    need(goto_item(e, 27), 'page Lt not reached')
    r.add(e, 'limit_lt_page', 'Limit test page Lt, test off', how + '; limits 99 and 101 ohm captured; SETUP pressed up to the page')
    T.long_press(e, 'SETUP')
    T.press(e, 'REL')
    e.advance(0.5)
    r.blink(e, 'limit_lt_edit', 'Limit test page Lt in edit after REL: "LtOn" (test on)', how + '; the page, SETUP held 1 s, REL pressed')
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    ohm(100)
    need(goto_item(e, 36), 'verdict page 36 not reached')
    for v, nm, what in ((100, 'pass', 'PASS: inside the limits'), (150, 'hi', 'HI: above the high limit'), (50, 'lo', 'Lo: below the low limit')):
        ohm(v)
        r.add(e, 'limit_verdict_' + nm, 'Limit test verdict %s (input %d ohm, limits 99 and 101 ohm)' % (what, v),
              '%s; limits captured, Lt on; input %d ohm' % (how, v))
    # logging trigger pages
    e.command({'dial': 2})
    e.command({'input': {'kind': 'V', 'value': 1.234}})
    e.advance(3.0)
    how = 'dial 2 (V), DCV; input 1.234 V'
    need(goto_item(e, 30), 'page tr not reached')
    r.add(e, 'trig_tr_page', 'Logging trigger page tr, the default "tr-In" (a record every interval)', how + '; SETUP pressed up to the page')
    T.long_press(e, 'SETUP')
    T.press(e, 'REL')
    e.advance(0.3)
    r.blink(e, 'trig_tr_edit_ch', 'Page tr in edit after REL: "tr-Ch" (a record when the reading changes by the threshold)', how + '; the page, SETUP held 1 s, REL pressed')
    T.press(e, 'REL')
    e.advance(0.3)
    r.blink(e, 'trig_tr_edit_lt', 'Page tr in edit after REL twice: "tr-Lt" (a record when the limit test verdict changes)', how + '; the page, SETUP held 1 s, REL pressed twice')
    T.press(e, 'PEAK')
    e.advance(0.3)
    T.long_press(e, 'SETUP')                                       # save tr-Ch
    e.advance(1.0)
    T.press(e, 'SETUP', hold=0.15, gap=0.35)
    e.advance(0.5)
    need(T.rd(e, ADDR_ITEM) == 31, 'page Ch not offered after tr-Ch')
    r.add(e, 'trig_ch_page', 'Logging trigger page Ch (the change threshold, offered with tr-Ch)', how + '; tr set to tr-Ch and saved; SETUP pressed once more')
    T.long_press(e, 'SETUP')
    T.press(e, 'REL')
    e.advance(0.3)
    r.blink(e, 'trig_ch_edit', 'Page Ch in edit after REL: the threshold changed by one step', how + '; the page, SETUP held 1 s, REL pressed')


def boot_env():
    """Import the bootloader branch's test helpers (bootloader build, flash images, host side of the Bluetooth link)."""
    global T
    if not os.path.isfile(os.path.join(BL_SRC, 'bootloader', 'tests', 'test_bootloader.py')):
        sys.exit('no bootloader tree at %s (--bootloader-src DIR)' % BL_SRC)
    sys.path[:0] = [os.path.join(BL_SRC, 'bootloader', 'tests'), os.path.join(BL_SRC, 'bootloader', 'tools'),
                    os.path.join(BL_SRC, 'emulator', 'scripts'), os.path.join(BL_SRC, 'emulator', 'tools')]
    import test_bootloader as X
    T = X.T
    T.Emulator.hy_noise = False
    X.IMAGE_PATH = IMAGE                                          # this tree's firmware build, not the bootloader tree's older one
    X.APP = open(IMAGE, 'rb').read()
    return X


def g_boot(r):
    """The bootloader's own screens: lamp test, -IAP-, Ld nn over Bluetooth, the card update."""
    X = boot_env()
    # power-on of a meter with the two-part bootloader: the bootloader's lamp test, then the firmware
    e = X.meter(X.flash_image(app=X.APP))
    frames = []
    for _ in range(80):
        w = list(snap(e)['lcd'])
        if snap(e)['lcd_on'] and (not frames or frames[-1][1] != w):
            frames.append((snap(e)['time_ms'] / 1000.0, w))
        e.advance(0.025)
    for t0, w in frames[:6]:
        print('    t=%.3f s  %d bits  %r' % (t0, popcount(w), T.DEC.text(w)[:2]))
    lamp = [f for f in frames if popcount(f[1]) >= 150]
    if lamp:
        r.add(e, 'boot_lamptest', 'Power-on lamp test of the two-part bootloader: every segment on',
              'flash image with starter, bootloader and firmware, power-on with no key held', words=lamp[0][1], note=False)
    else:
        r.miss('boot_lamptest', 'no frame with all segments on in the first 2 s')
    # update mode: -IAP-, then the transfer over Bluetooth with the percentage
    e = X.meter(X.flash_image(mark=False, app=X.APP))
    e.advance(1.5)
    r.add(e, 'boot_iap', 'Bootloader update mode (no valid firmware): "-IAP-" on both displays, Bluetooth on',
          'flash image whose firmware mark is erased, power-on with no key held')
    h = X.Host(e)
    shots, last = [], [T.now(e)]
    orig = h.wait

    def wait(n, timeout):
        got = orig(n, timeout)
        if T.now(e) - last[0] >= 1.0:
            last[0] = T.now(e)
            w = list(snap(e)['lcd'])
            m, sub, ann = T.DEC.text(w)
            if m.upper().startswith('LD'):
                shots.append((m, w))
        return got
    h.wait = wait
    ans, secs = h.transfer(X.APP, X.KIND_FW)
    print('    transfer answer %r in %.0f s emulated; Ld samples %s' % (ans, secs, [m for m, _w in shots][:12] + ['...'] + [m for m, _w in shots][-3:]), flush=True)
    mid = [f for f in shots if f[0].replace(' ', '')[2:].isdigit()]
    if mid:
        pick = min(mid, key=lambda f: abs(int(f[0].replace(' ', '')[2:]) - 50))
        r.add(e, 'boot_ld_nn', 'Bootloader receiving the firmware over Bluetooth: "Ld nn" (progress in percent) with the bar graph',
              'update mode (-IAP-), firmware image sent over the Bluetooth link; the picture is the sample nearest 50 %', words=pick[1])
    else:
        r.miss('boot_ld_nn', 'no Ld nn sample during the transfer')
    t = text(e)
    e.advance(0.1)
    if until(e, lambda e: text(e)[0].upper().startswith('LD') and 'OK' in text(e)[0].upper(), 3.0, 0.05):
        r.add(e, 'boot_ld_ok', 'Bootloader: the firmware is received and written: "Ld oK"', 'as boot_ld_nn, after the last packet')
    # the card update: MEM + HOLD at power-on, SETUP
    e = X.meter(X.flash_image(app=X.APP), keys=('MEM', 'HOLD'), card=X._card_with(X.APP))
    e.advance(1.0)
    X.release(e)
    e.advance(1.0)
    r.add(e, 'boot_card_menu', 'Bootloader update mode with the card (MEM + HOLD at power-on)',
          'MEM and HOLD held through the power-on, released after 1 s; EEVBlog.bin on the card')
    T.press(e, 'SETUP', hold=0.3, gap=0.2)
    seen = {}
    for _ in range(400):
        e.advance(0.1)
        w = list(snap(e)['lcd'])
        m = T.DEC.text(w)[0]
        if m not in seen or (m.upper().startswith('DOUUN') and popcount(w) > popcount(seen[m])):
            seen[m] = w
        if 0x08006000 <= e.m.pc < 0x08052000:
            break
    print('    card update displays: %s' % sorted(seen), flush=True)
    for m, w in seen.items():
        if m.upper().startswith('DOUUN'):
            r.add(e, 'boot_card_progress', 'Bootloader programming from the card: "douun" with the bar graph (the picture is the fullest bar graph)',
                  'as boot_card_menu, then SETUP pressed', words=w)
        elif m.upper().replace(' ', '') in ('9OOD', '90OD'):
            r.add(e, 'boot_card_good', 'Bootloader: card update done, " Good"', 'as boot_card_menu, then SETUP pressed', words=w)


def g_bootfw(r):
    """The firmware's own pages that need the two-part bootloader: Ld-bt with the transfer and For (format as exFAT)."""
    X = boot_env()
    U = X.U
    card = X._card_with(b'')
    e = X.meter(X.flash_image(app=X.APP), card=card)
    e.advance(2.0)
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    r.add(e, 'ld_bt', 'SETUP page Ld-bt: the card file transfer over Bluetooth is ready', 'DCV, Bluetooth on (PEAK held 1 s); SETUP pressed until page Ld')
    link = U.Link(e)
    shots, cnt, orig = [], [0], link.send

    def send(pkt, timeout=10.0):
        a = orig(pkt, timeout)
        cnt[0] += 1
        if cnt[0] % 25 == 0:
            w = list(snap(e)['lcd'])
            m, sub, ann = T.DEC.text(w)
            if sub.upper().startswith('LD'):
                shots.append((sub, w))
        return a
    link.send = send
    ans = U.send_file(link, X.APP)
    e.advance(0.5)
    print('    END answer %r; samples %s' % (ans, [s_[0] for s_ in shots][:6] + ['...'] + [s_[0] for s_ in shots][-2:]), flush=True)
    mid = [f for f in shots if f[0].replace(' ', '')[2:].isdigit()]
    if mid:
        pick = min(mid, key=lambda f: abs(int(f[0].replace(' ', '')[2:]) - 50))
        r.add(e, 'ld_nn', 'Page Ld during a file transfer from the companion: "Ld nn" (progress in percent)',
              'as ld_bt; the firmware image sent over Bluetooth, the sample nearest 50 %', words=pick[1])
    else:
        r.miss('ld_nn', 'no Ld nn sample during the transfer')
    if 'OK' in text(e)[1].upper():
        r.add(e, 'ld_ok', 'Page Ld: the file arrived and was checked: "Ld oK"', 'as ld_nn, after the last packet')
    else:
        r.miss('ld_ok', 'sub display after the transfer: %r' % text(e)[1])
    # format as exFAT
    e = X.meter(X.flash_image(app=X.APP), card=X._card_with(b''))
    e.advance(2.0)
    e.command({'dial': 2})
    e.advance(3.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([39]))
    T.press(e, 'SETUP', gap=0.6)
    r.add(e, 'for_page', 'SETUP page For (format the card as exFAT), the question "Fr no"', 'DCV; SETUP pressed until page For (after Ld-bt)')
    T.long_press(e, 'SETUP')
    T.press(e, 'REL')
    r.blink(e, 'for_edit_yes', 'Page For in edit after REL: the answer "Fr yE" (yes)', 'as for_page, SETUP held 1 s, REL pressed')
    T.long_press(e, 'SETUP')
    seen = {}
    for _ in range(200):
        e.advance(0.1)
        sub = text(e)[1]
        if sub not in seen:
            seen[sub] = list(snap(e)['lcd'])
        if sub.upper() == 'FR OK' or sub.upper().startswith('FRE'):
            break
    print('    format displays: %s' % sorted(seen), flush=True)
    for sub, w in seen.items():
        if sub.upper().replace(' ', '') == 'FR--':
            r.add(e, 'for_working', 'Page For while the card is being formatted: "Fr --"', 'as for_edit_yes, then SETUP held 1 s to confirm', words=w)
        elif sub.upper() == 'FR OK':
            r.add(e, 'for_ok', 'Page For: the card is now exFAT: "Fr oK"', 'as for_edit_yes, then SETUP held 1 s to confirm', words=w)


def to_mode(e, name, tries=6):
    """Press MODE until the function `name` is active."""
    for _ in range(tries):
        if mode_name(e) == name:
            return True
        T.press(e, 'MODE')
        e.advance(1.5)
    return mode_name(e) == name


def g_feat(r):
    """The open firmware's features in use.  Each setting is preset in the EEPROM byte the SETUP page itself stores
    (firmware/EEPROM_MAP.md 4.1), so the meter starts with it as after a saved edit."""
    def need(cond, what):
        if not cond:
            raise SystemExit('FAIL: ' + what)

    # REL in percent (rEL-P: EEPROM 0x020 bit 0)
    e = meter(patch={0x020: 1})
    e.command({'dial': 2})
    e.command({'input': dict(kind='V', value=1.0)})
    e.advance(3.0)
    T.press(e, 'REL')
    e.advance(1.0)
    e.command({'input': dict(kind='V', value=1.1)})
    e.advance(3.0)
    r.add(e, 'feat_relpct', 'REL in percent: reference 1.000 V, now 1.100 V', 'dial 2 DCV, rEL-P preset (0x020 = 1); 1.0 V, REL, then 1.1 V')
    # dBm value and its reference (ACV page 11; 0x011 = 0: 600 ohm)
    need(to_mode(e, 'ACV'), 'ACV not reached')
    e.command({'input': dict(kind='V', value=1.0, ac=True, freq=1000)})
    e.advance(3.0)
    need(goto_item(e, 11), 'dBm page not reached')
    e.advance(1.0)
    r.add(e, 'feat_dbm', 'dBm of 1.000 V AC (600 ohm reference)', 'dial 2 ACV, 1.0 V AC 1 kHz, SETUP to the dBm page (11)')
    T.long_press(e, 'SETUP')
    r.blink(e, 'feat_dbm_ref', 'dBm reference page in edit: r 600', 'as feat_dbm, SETUP held: reference edit')
    T.press(e, 'SETUP')                                               # short: leave without saving
    e.advance(0.5)
    # 4-20 mA loop percent (LP: 0x028 = 1), 12 mA = 50 %
    e = meter(patch={0x028: 1})
    plug(e, 'mA')
    e.command({'dial': 8})
    e.advance(2.0)
    need(to_mode(e, 'DCmA'), 'DCmA not reached')
    e.command({'input': dict(kind='A', value=12e-3)})
    e.advance(3.0)
    r.add(e, 'feat_loop', '4-20 mA loop view: 12 mA shown as 50 %', 'dial 8 DCmA, mA jack, L4-20 preset (0x028 = 1), 12 mA')
    # PT100 (Pt: 0x029 = 1), 138.51 ohm = 100 degC (IEC 60751)
    e = meter(patch={0x029: 1})
    e.command({'dial': 5})
    e.advance(2.0)
    need(to_mode(e, 'OHM'), 'OHM not reached')
    e.command({'input': dict(kind='ohm', value=138.51)})
    e.advance(4.0)
    r.add(e, 'feat_pt100', 'PT100 view: 138.51 ohm shown as a temperature', 'dial 5 OHM, Pt100 preset (0x029 = 1), 138.51 ohm')
    # continuity UP300 (0x014 = 3) and beep hold 25 ms (0x021 = 2)
    e = meter(patch={0x014: 3, 0x021: 2})
    e.command({'dial': 5})
    e.advance(2.0)
    need(to_mode(e, 'BEEP'), 'BEEP not reached')
    e.command({'input': dict(kind='ohm', value=1000)})
    e.advance(2.0)
    need(goto_item(e, 10), 'BEEP threshold page not reached')
    r.add(e, 'feat_up300', 'Continuity threshold UP300 (beep above 300 ohm)', 'dial 5 BEEP, 0x014 = 3, SETUP to page 10')
    need(goto_item(e, 26), 'bH page not reached')
    r.add(e, 'feat_bh25', 'Continuity beep hold 25 ms', 'dial 5 BEEP, 0x021 = 2, SETUP to the bH page')
    # thermocouple type J (0x00F = 1)
    e = meter(patch={0x00F: 1})
    e.command({'dial': 3})
    e.advance(2.0)
    need(to_mode(e, 'TEMP'), 'TEMP not reached')
    e.command({'input': dict(kind='degC', value=100, board=23)})
    e.advance(4.0)
    need(goto_item(e, 23), 'tc page not reached')
    r.add(e, 'feat_tcJ', 'Thermocouple type J selected', 'dial 3 TEMP, 0x00F = 1, SETUP to the tc page')
    # capacitance anti-hunting (HUnt: EEPROM 0x020 bit 4 = 1): the page shows its name on the sub display, "on" on the main display
    e = meter(patch={0x020: 0x10})
    e.command({'dial': 5})
    e.advance(2.0)
    need(to_mode(e, 'CAP'), 'CAP not reached')
    e.command({'input': dict(kind='F', value=100e-9)})
    e.advance(6.0)
    need(goto_item(e, 41), 'HUnt page not reached')
    e.advance(1.0)
    r.add(e, 'feat_hunt', 'Capacitance anti-hunting on: the page HUnt', 'dial 5 CAP, HUnt preset (0x020 = 0x10), 100 nF, SETUP to the page HUnt (item 41)')
    # display level 2, Bluetooth 20/s, 12-hour clock, backlight 30 s (one meter)
    e = meter(patch={0x013: 1, 0x015: 3, 0x020: 8, 0x017: 1})
    e.command({'dial': 2})
    e.command({'input': dict(kind='V', value=1.234)})
    e.advance(3.0)
    for item, name, what in ((24, 'feat_dsp2', 'Display level 2'), (21, 'feat_bt20', 'Bluetooth 20 readings per second'),
                             (25, 'feat_cl12', '12-hour clock display'), (20, 'feat_bl30', 'Backlight off after 30 s'),
                             (7, 'feat_time12', 'Time page in 12-hour form')):
        need(goto_item(e, item), 'page %d not reached' % item)
        r.add(e, name, what, 'dial 2 DCV; preset 0x013 = 1, 0x015 = 3, 0x020 = 8, 0x017 = 1; SETUP to page %d' % item)


def run_group(group, out):
    r = Rec(group)
    if not os.path.isfile(IMAGE):
        sys.exit('missing %s: run `make PYTHON=/tmp/eev/venv/bin/python` in firmware/' % IMAGE)
    t0 = time.time()
    if group.startswith('setupm'):
        g_setupm(r, group)
    else:
        globals()['g_' + group](r)
    print('%s: %d pictures, %d not made, %.0f s' % (group, len(r.shots), len(r.missed), time.time() - t0), flush=True)
    render(r.shots, out)
    write_index(out, group, r)


def main(argv):
    global BL_SRC
    out, jobs, bl, groups = OUT, 1, BL_SRC, []
    it = iter(argv)
    for a in it:
        if a == '--out':
            out = next(it)
        elif a == '--jobs':
            jobs = int(next(it))
        elif a == '--bootloader-src':
            bl = next(it)
        else:
            groups.append(a)
    BL_SRC = bl
    bad = [g for g in groups if g not in GROUPS]
    if bad:
        sys.exit('unknown group %s; groups: %s' % (bad, ' '.join(GROUPS)))
    if len(groups) == 1:
        run_group(groups[0], out)
        return 0
    todo, running, rc = list(groups or GROUPS), [], 0
    while todo or running:
        while todo and len(running) < jobs:
            g = todo.pop(0)
            running.append((g, subprocess.Popen([sys.executable, '-I', os.path.abspath(__file__), g, '--out', out,
                                                 '--bootloader-src', bl])))
        for g, p in list(running):
            try:
                p.wait(timeout=1)
            except subprocess.TimeoutExpired:
                continue
            running.remove((g, p))
            rc |= p.returncode
        time.sleep(0.2)
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
