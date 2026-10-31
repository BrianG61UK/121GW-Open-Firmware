"""Build the front-panel background for the UI from the 121GW manual cover drawing (EEVblog artwork;
private use / for EEVblog review only).  Removes the printed LCD contents and the printed dial pointer
so the live LCD and the live knob can be drawn on top.  Geometry was measured from the image.
Usage: make_panel.py <cover.jpg> <out.png>
"""
import math, sys
from PIL import Image, ImageDraw

src, dst = sys.argv[1:3]
im = Image.open(src).convert('RGB')
px = im.load()
FACE = (68, 86, 98)                       # panel face colour (sampled)
KNOB_C, KNOB_R = (347.0, 873.6), 167      # knob centre / radius (circle fit to the printed outline)
HZ_DOT = (320, 688)                       # dial dot nearest to the printed pointer tip
LCD = (123, 188, 569, 443)                # LCD glass, inclusive (inside the black edge; walls and frame stay printed)
d = ImageDraw.Draw(im)
d.rounded_rectangle(LCD, radius=5, fill=(214, 222, 208))
# printed pointer tip outside the knob: repaint only pointer pixels (neutral grey body or dark outline,
# never the white label text or the dot) with the nearest face-coloured pixel of the same row
def is_face(c):
    return abs(c[0] - FACE[0]) + abs(c[1] - FACE[1]) + abs(c[2] - FACE[2]) <= 24
def is_pointer(c):
    r, g, b = c
    neutral = max(r, g, b) - min(r, g, b) < 22
    return (neutral and 90 <= r <= 200) or max(r, g, b) < 45
orig = im.copy().load()
for y in range(684, 722):
    row_face = [x for x in range(250, 420) if is_face(orig[x, y])]
    for x in range(298, 368):
        if math.dist((x, y), KNOB_C) <= KNOB_R or math.dist((x, y), HZ_DOT) <= 8:
            continue
        if is_pointer(orig[x, y]) and row_face:
            nx = min(row_face, key=lambda fx: abs(fx - x))
            px[x, y] = orig[nx, y]
# white page background around the meter -> transparent (flood fill from the corners), then remove the
# white fringe left by JPEG anti-aliasing: for pixels within 4 px of the cut-out, derive alpha from the
# amount of white mixed in and un-blend the colour (c = a*c' + (1-a)*255  ->  c' = (c - (1-a)*255) / a)
from PIL import ImageDraw as _D, ImageFilter as _F
rgba = im.convert('RGBA')
for corner in ((0, 0), (im.width - 1, 0), (0, im.height - 1), (im.width - 1, im.height - 1)):
    _D.floodfill(rgba, corner, (0, 0, 0, 0), thresh=60)
cut = rgba.getchannel('A').point(lambda v: 255 if v == 0 else 0)
near = cut.filter(_F.MaxFilter(9))                      # 4 px band around the cut-out
p = rgba.load(); nb = near.load()
EDGE = (24, 28, 34)                                    # darkest boot-edge colour (sampled outline)
for y in range(rgba.height):
    for x in range(rgba.width):
        r, g, b, a = p[x, y]
        if a == 0 or not nb[x, y]:
            continue
        w = min(r, g, b) / 255.0                       # whiteness 0..1
        alpha = max(0.0, min(1.0, 1.0 - (w - EDGE[0] / 255.0) / (1.0 - EDGE[0] / 255.0)))
        if alpha < 0.08:
            p[x, y] = (0, 0, 0, 0); continue
        un = [max(0, min(255, int((c - (1 - alpha) * 255) / alpha))) for c in (r, g, b)]
        p[x, y] = (un[0], un[1], un[2], int(alpha * 255))
rgba.save(dst)
print('written', dst, rgba.size)
