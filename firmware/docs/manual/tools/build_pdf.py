"""Build the user manual: firmware/docs/manual/src/manual.html + style.css -> firmware/docs/manual/manual.pdf.

    python3 -I firmware/docs/manual/tools/build_pdf.py            (needs Playwright with Chromium, and PyMuPDF)

The table of contents is made from the h2 / h3 headings of the source (each gets an id).  Chromium writes every
<a href="#id"> as a link to the page of that id; a first rendering is read back (PyMuPDF) to learn the page of every
heading, a second rendering then prints those page numbers in the contents and wherever the source writes
<a class="pg" href="#id"></a>, and the PDF gets bookmarks (the viewer's sidebar) for every chapter and section.
The pictures are the PNG files in firmware/docs/manual/img, rendered from the emulator by make_screens.py.  The
firmware version on the cover is read from firmware/src/inc/config.inc (FW_VER_C0..C4).
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


def build_html(pages):
    """The page HTML; `pages` = {id: page number} from an earlier rendering (empty on the first one)."""
    body = open(SRC, encoding='utf-8').read().replace('{{FW_VERSION}}', fw_version())
    used, toc = set(), []

    def head(m):
        level, attrs, text = m.group(1), m.group(2) or '', m.group(3)
        idm = re.search(r'id="([^"]+)"', attrs)
        hid = idm.group(1) if idm else slug(text, used)
        if not idm:
            attrs += ' id="%s"' % hid
        if 'data-notoc' not in attrs:
            toc.append((int(level), hid, re.sub(r'<[^>]+>', '', text).strip()))
        return '<h%s%s>%s</h%s>' % (level, attrs, text, level)
    body = re.sub(r'<h([23])((?:\s[^>]*)?)>(.*?)</h\1>', head, body, flags=re.S)
    items = ''.join('<li class="toc%d"><a href="#%s"><span class="t">%s</span><span class="n">%s</span></a></li>'
                    % (lv, hid, html.escape(t), pages.get(hid, '00')) for lv, hid, t in toc)
    body = body.replace('{{TOC}}', '<ol class="toc">%s</ol>' % items)
    body = re.sub(r'<a class="pg" href="#([^"]+)"></a>',
                  lambda m: '<a class="pg" href="#%s">page %s</a>' % (m.group(1), pages.get(m.group(1), '00')), body)
    css = open(CSS, encoding='utf-8').read()
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>121GW Open Firmware - User Manual</title>'
            '<style>%s</style></head><body>%s</body></html>' % (css, body)), toc


def render(page_html, out):
    from playwright.sync_api import sync_playwright
    footer = ('<div style="font-size:13px;width:100%;padding:0 15mm;color:#666;display:flex;justify-content:space-between;'
              'font-family:Helvetica,Arial,sans-serif"><span>121GW Open Firmware ' + fw_version() + ' - User Manual</span>'
              '<span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>')
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page()
        pg.goto('file://' + page_html)
        pg.wait_for_load_state('networkidle')
        pg.pdf(path=out, format='A4', print_background=True, display_header_footer=True,
               header_template='<span></span>', footer_template=footer,
               margin={'top': '15mm', 'bottom': '16mm', 'left': '15mm', 'right': '15mm'})
        b.close()


def heading_pages(pdf):
    """{id: page number (1-based)} from the links Chromium wrote (contents and page references)."""
    import pymupdf
    d = pymupdf.open(pdf)
    pages = {}
    for p in d:
        for ln in p.get_links():
            if ln.get('nameddest') and ln.get('page', -1) >= 0:
                pages.setdefault(ln['nameddest'], ln['page'] + 1)
    return pages, d.page_count


def explicit_links(d):
    """Chromium writes each link as a named destination (/Dest /name, resolved through the catalog's /Dests table).
    Preview and several other viewers do not follow those, so every link gets the explicit target array instead
    ([page /XYZ x y zoom], copied from the table); a link without a target stops the build."""
    kind, val = d.xref_get_key(d.pdf_catalog(), 'Dests')
    if kind != 'xref':
        raise SystemExit('no /Dests table in the rendered PDF')
    table = int(val.split()[0])
    bad = 0
    for p in d:
        for ln in p.get_links():
            k, name = d.xref_get_key(ln['xref'], 'Dest')
            if k != 'name':
                continue
            tk, target = d.xref_get_key(table, name.lstrip('/'))
            if tk != 'array':
                bad += 1
                continue
            d.xref_set_key(ln['xref'], 'Dest', target)
    if bad:
        raise SystemExit('%d links without a target' % bad)


def main():
    page_html = os.path.join(MAN, 'src', '_build.html')
    tmp = OUT + '.tmp.pdf'
    pages = {}
    for _ in range(3):                                     # numbers can move a heading only if the contents grow: repeat
        text, toc = build_html(pages)
        open(page_html, 'w', encoding='utf-8').write(text)
        render(page_html, tmp)
        found, n = heading_pages(tmp)
        if found == pages:
            break
        pages = found
    import pymupdf
    d = pymupdf.open(tmp)
    explicit_links(d)
    d.set_toc([[lv - 1, t, pages.get(hid, 1)] for lv, hid, t in toc])      # bookmarks: chapters level 1, sections 2
    d.set_metadata({'title': '121GW Open Firmware - User Manual', 'subject': 'EEVblog 121GW with the open firmware ' +
                    fw_version()})
    d.save(OUT, garbage=3, deflate=True)
    d.close()
    os.remove(tmp)
    os.remove(page_html)
    missing = [hid for _lv, hid, _t in toc if hid not in pages]
    print('%s: %d pages, %d bytes%s' % (OUT, n, os.path.getsize(OUT), ('; no page for ' + ', '.join(missing)) if missing else ''))
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
