"""Draw the program icon: OUTDIR/121gw-companion.png (256 x 256), .ico (Windows) and .icns (macOS).

    python3 -I packaging/make_icons.py OUTDIR

The icon follows the window's design: a matte black square, a yellow hairline frame, a short bargraph and "121GW" in
the scalable default font of Pillow (Pillow 10.1 or later), so no font file is needed.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

BG, ACC, INK, RULE = (12, 12, 11, 255), (242, 194, 0, 255), (233, 231, 223, 255), (58, 58, 52, 255)


def draw(size=1024):
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    m = size // 16
    d.rectangle([m, m, size - m, size - m], fill=BG)
    w = max(2, size // 160)
    d.rectangle([m + 4 * w, m + 4 * w, size - m - 4 * w, size - m - 4 * w], outline=ACC, width=w)
    font = ImageFont.load_default(size=size // 5)
    text = '121GW'
    tw = d.textlength(text, font=font)
    d.text(((size - tw) / 2, size * 0.30), text, font=font, fill=INK)
    x0, x1, y = size * 0.20, size * 0.80, size * 0.66
    n, gap = 13, size * 0.008
    seg = (x1 - x0 - gap * (n - 1)) / n
    for i in range(n):
        xa = x0 + i * (seg + gap)
        d.rectangle([xa, y, xa + seg, y + size * 0.07], fill=ACC if i < 9 else RULE)
    return im


def main(argv):
    out = argv[0]
    os.makedirs(out, exist_ok=True)
    big = draw()
    big.resize((256, 256), Image.LANCZOS).save(os.path.join(out, '121gw-companion.png'))
    big.save(os.path.join(out, '121gw-companion.ico'), sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    big.save(os.path.join(out, '121gw-companion.icns'))
    print('icons written to %s' % out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
