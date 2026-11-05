"""smoke.py - the started companion answers: page, state, and both protections (custom header, Host check).

    python3 -I .github/scripts/smoke.py http://127.0.0.1:PORT [--timeout 120] [--views]

Exit status 0 when GET / serves the page, GET /state answers JSON with the link idle, a POST without the header is
refused (403), a GET with a foreign Host header is refused (403), and a POST with the header is accepted.  Standard
library only; no meter is needed (the program does not connect by itself).

With --views the page is also opened in a headless Chromium (needs the Python package playwright and its Chromium) and
each of the five views (LIVE, SCOPE, LOG, CARD, METER) is shown, by tab and by the keys 1 to 5; the check fails on any
script error or console error, and when a view does not become visible.  The state of the idle program has none of the
desk / card / settings / diagnostics keys, so this also proves the page copes with missing keys.
"""
import json
import sys
import time
import urllib.error
import urllib.request


def req(url, data=None, headers=None):
    r = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with urllib.request.urlopen(r, timeout=10) as f:
            return f.status, f.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


VIEWS = ['live', 'scope', 'log', 'card', 'meter']


def check_views(base):
    """Open the page in headless Chromium, show every view, return [(name, ok)] for the checks."""
    from playwright.sync_api import sync_playwright
    errors, results = [], []
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={'width': 1180, 'height': 760})
        page.on('pageerror', lambda e: errors.append(str(e)))
        page.on('console', lambda m: errors.append(m.text) if m.type == 'error' else None)
        page.goto(base + '/')
        page.wait_for_selector('#v-live.on')
        for i, v in enumerate(VIEWS):
            page.click('nav button[data-v=%s]' % v)
            page.wait_for_timeout(400)
            shown = page.evaluate("(v) => { const e = document.getElementById('v-' + v); return e.classList.contains('on') && e.offsetHeight > 0 && e.innerText.trim().length > 0; }", v)
            results.append(('view %s shown by tab' % v.upper(), bool(shown)))
            page.keyboard.press('1' if i else '2')           # another view first, so the key must really switch back
            page.keyboard.press(str(i + 1))
            page.wait_for_timeout(200)
            results.append(('view %s shown by key %d' % (v.upper(), i + 1), page.evaluate("(v) => document.getElementById('v-' + v).classList.contains('on')", v)))
        browser.close()
    results.append(('no script or console error in the page', not errors))
    for e in errors:
        print('smoke: page error: %s' % e)
    return results


def main(argv):
    base = argv[0].rstrip('/')
    timeout = float(argv[argv.index('--timeout') + 1]) if '--timeout' in argv else 120.0
    end = time.time() + timeout
    while True:
        try:
            code, body = req(base + '/state')
            if code == 200:
                break
        except OSError:
            pass
        if time.time() > end:
            print('smoke: no answer from %s within %d s' % (base, timeout))
            return 1
        time.sleep(1)
    st = json.loads(body)
    checks = [('GET /state answers, link idle', st['link']['state'] == 'idle')]
    code, body = req(base + '/')
    checks.append(('GET / serves the page with its five views', code == 200 and b'121GW Companion' in body
                   and all(b'id="v-%s"' % v.encode() in body for v in VIEWS)))
    code, _ = req(base + '/api', b'{"reset_stats": true}', {'Content-Type': 'application/json'})
    checks.append(('POST without the header refused', code == 403))
    code, _ = req(base + '/state', headers={'Host': 'example.com'})
    checks.append(('foreign Host refused', code == 403))
    code, _ = req(base + '/api', b'{"reset_stats": true}', {'Content-Type': 'application/json', 'X-121GW-Companion': '1'})
    checks.append(('POST with the header accepted', code == 200))
    if '--views' in argv:
        checks += check_views(base)
    for name, ok in checks:
        print('smoke: %s %s' % ('PASS' if ok else 'FAIL', name))
    return 0 if all(ok for _, ok in checks) else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
