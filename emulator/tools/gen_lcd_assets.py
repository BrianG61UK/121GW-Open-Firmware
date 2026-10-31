"""Build the LCD element assets for the UI.

Inputs: the verified LCD map (markdown tables: shadow word/bit -> element / SVG layer name) and the
SVG layer files of the official 121GW app (MIT licence, (c) 2018 David Ledger), which all share one
canvas.  Output: ui/assets/lcd/*.svg (copied layers), ui/assets/lcd_bits.json
{ "w<word>b<bit>": [layer, ...] } and ui/assets/lcd/LICENSE.
Usage: gen_lcd_assets.py <lcd_map.md> <app layer directory> <app LICENSE>
"""
import json, os, re, shutil, sys

lcd_md, layer_dir, app_license = sys.argv[1:4]
out = os.path.join(os.path.dirname(__file__), '..', 'ui', 'assets')
layers = {os.path.splitext(f)[0]: f for f in os.listdir(layer_dir) if f.endswith('.svg')}
bits = {}

def add(bit, name):
    name = name.strip().strip('`').replace('.svg', '')
    if name in layers:
        bits.setdefault(bit, [])
        if name not in bits[bit]:
            bits[bit].append(name)
        return True
    return False

rows = [l for l in open(lcd_md) if l.startswith('|')]
for l in rows:
    c = [x.strip() for x in l.strip().strip('|').split('|')]
    # digit table: pos | SVG prefix | SEG pair | a..g | dp
    if len(c) == 11 and re.fullmatch(r'(seg|sub)\d\*', c[1]):
        pre = c[1][:-1]
        for seg, cell in zip('abcdefg', c[3:10]):
            if re.fullmatch(r'w\d+b\d+', cell):
                add(cell, pre + seg)
        m = re.match(r'(w\d+b\d+)\s*=\s*(\w+dp)', c[10])
        if m:
            add(m.group(1), m.group(2))
        continue
    # bargraph table: seg | bit | seg | bit ...
    if len(c) == 8 and c[0].isdigit():
        for k, b in zip(c[0::2], c[1::2]):
            if k.isdigit() and re.fullmatch(r'w\d+b\d+', b):
                add(b, f'bar{int(k) + 1:02d}')
        continue
    # icon tables: bit | COM/SEG | element | SVG | ...
    if len(c) >= 4 and re.match(r'w\d+b\d+', c[0]):
        bl = re.findall(r'w\d+b\d+', c[0])
        cand = []
        prefix = ''
        for tok in re.split(r'[,/]', re.sub(r'\(.*?\)', '', c[3])):
            t = tok.strip().strip('`').replace('.svg', '').strip()
            if t in layers:
                cand.append(t)
                m = re.match(r'(BarTick|Bar1000|Bar500)', t)
                prefix = m.group(1) if m else ''
            elif prefix and re.fullmatch(r'_?\d+_\d+', t):   # abbreviated group member, e.g. "2_2" or "_0_1"
                full = prefix + (t if t.startswith('_') else t)
                if full in layers:
                    cand.append(full)
        if len(bl) == len(cand) and len(bl) > 1:          # "w4b11 / w6b11 | ... | SegTempC / SegTempF"
            for b, n in zip(bl, cand):
                add(b, n)
        else:
            for b in bl:
                for n in cand:
                    add(b, n)

os.makedirs(os.path.join(out, 'lcd'), exist_ok=True)
used = sorted({n for v in bits.values() for n in v})
for n in used:
    shutil.copy(os.path.join(layer_dir, layers[n]), os.path.join(out, 'lcd', n + '.svg'))
shutil.copy(app_license, os.path.join(out, 'lcd', 'LICENSE'))
json.dump(bits, open(os.path.join(out, 'lcd_bits.json'), 'w'), indent=1, sort_keys=True)
unused = sorted(set(layers) - set(used))
print(f'bits mapped {len(bits)}, layers used {len(used)}, layers without a proven bit {len(unused)}:')
print(' '.join(unused))
