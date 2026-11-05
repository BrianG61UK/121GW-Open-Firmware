"""Build the user manual: firmware/docs/manual/src/manual.html + style.css -> firmware/docs/manual/manual.pdf.

    python3 -I firmware/docs/manual/tools/build_pdf.py            (needs Playwright with Chromium)

The table of contents is made from the h2 / h3 headings of the source (each gets an id); page numbers come from the PDF
footer.  The pictures are the PNG files in firmware/docs/manual/img, rendered from the emulator by make_screens.py, so
the manual shows what the firmware really displays.  The firmware version printed on the cover is read from
firmware/src/inc/config.inc (FW_VER_C0..C4), so the manual cannot name a version the source does not build.
"""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAN = os.path.normpath(os.path.join(HERE, '..'))
ROOT = os.path.normpath(os.path.join(MAN, '..', '..', '..'))
SRC = os.path.join(MAN, 'src', 'manual.html')
CSS = os.path.join(MAN, 'src', 'style.css')
OUT = os.path.join(MAN, 'manual.pdf')


def fw_version():
    txt = open(os.path.join(ROOT, 'firmware', 'src', 'inc', 'config.inc')).read()
    c = [re.search(r"\.equ FW_VER_C%d, '(.)'" % i, txt).group(1) for i in range(5)]
    return '%s%s%s.%s%s' % tuple(c)                       # "F-1.06": point after the third character


def slug(text, used):
    s = re.sub(r'[^a-z0-9]+', '-', re.sub(r'<[^>]+>', '', text).lower()).strip('-') or 'section'
    base, n = s, 2
    while s in used:
        s, n = '%s-%d' % (base, n), n + 1
    used.add(s)
    return s


def build_html():
    body = open(SRC, encoding='utf-8').read().replace('{{FW_VERSION}}', fw_version())
    used, toc = set(), []

    def head(m):
        level, attrs, text = m.group(1), m.group(2) or '', m.group(3)
        idm = re.search(r'id="([^"]+)"', attrs)
        hid = idm.group(1) if idm else slug(text, used)
        if not idm:
            attrs += ' id="%s"' % hid
        if 'data-notoc' not in attrs:
            toc.append((level, hid, re.sub(r'<[^>]+>', '', text)))
        return '<h%s%s>%s</h%s>' % (level, attrs, text, level)
    body = re.sub(r'<h([23])((?:\s[^>]*)?)>(.*?)</h\1>', head, body, flags=re.S)
    items = ''.join('<li class="toc%s"><a href="#%s">%s</a></li>' % (lv, hid, html.escape(t)) for lv, hid, t in toc)
    body = body.replace('{{TOC}}', '<ol class="toc">%s</ol>' % items)
    css = open(CSS, encoding='utf-8').read()
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>121GW Open Firmware - User Manual</title>'
            '<style>%s</style></head><body>%s</body></html>' % (css, body))


def main():
    from playwright.sync_api import sync_playwright
    page_html = os.path.join(MAN, 'src', '_build.html')
    open(page_html, 'w', encoding='utf-8').write(build_html())
    footer = ('<div style="font-size:8px;width:100%;padding:0 14mm;color:#666;display:flex;justify-content:space-between;'
              'font-family:Helvetica,Arial,sans-serif"><span>121GW Open Firmware ' + fw_version() + ' - User Manual</span>'
              '<span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>')
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        pg.goto('file://' + page_html)
        pg.wait_for_load_state('networkidle')
        pg.pdf(path=OUT, format='A4', print_background=True, display_header_footer=True,
               header_template='<span></span>', footer_template=footer,
               margin={'top': '16mm', 'bottom': '18mm', 'left': '14mm', 'right': '14mm'})
        b.close()
    os.remove(page_html)
    print('%s: %d bytes' % (OUT, os.path.getsize(OUT)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
