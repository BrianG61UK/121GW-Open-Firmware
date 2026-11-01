#!/usr/bin/env python3
"""make_icons.py - application icons from the front-panel picture (needs Pillow; build time only).

    python3 -I packaging/make_icons.py OUTDIR

Writes OUTDIR/121gw-emulator.png (256 x 256), .ico (Windows) and .icns (macOS): the meter picture
emulator/ui/assets/panel.png, scaled to fit a square with a transparent background.
"""
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PANEL = os.path.join(HERE, '..', 'ui', 'assets', 'panel.png')


def square(img, size):
    img = img.convert('RGBA')
    img.thumbnail((size, size), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(img, ((size - img.width) // 2, (size - img.height) // 2), img)
    return out


def main(argv):
    if len(argv) != 1:
        sys.stderr.write(__doc__)
        return 2
    out = argv[0]
    os.makedirs(out, exist_ok=True)
    src = Image.open(PANEL)
    big = square(src, 1024)
    big.resize((256, 256), Image.LANCZOS).save(os.path.join(out, '121gw-emulator.png'))
    big.save(os.path.join(out, '121gw-emulator.ico'), sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    big.save(os.path.join(out, '121gw-emulator.icns'))
    for n in sorted(os.listdir(out)):
        print('make_icons: %s (%d bytes)' % (n, os.path.getsize(os.path.join(out, n))))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
