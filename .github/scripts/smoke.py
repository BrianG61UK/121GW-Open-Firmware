"""smoke.py - the started companion answers: page, state, and both protections (custom header, Host check).

    python3 -I .github/scripts/smoke.py http://127.0.0.1:PORT [--timeout 120]

Exit status 0 when GET / serves the page, GET /state answers JSON with the link idle, a POST without the header is
refused (403), a GET with a foreign Host header is refused (403), and a POST with the header is accepted.  Standard
library only; no meter is needed (the program does not connect by itself).
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
    checks.append(('GET / serves the page', code == 200 and b'121GW Companion' in body))
    code, _ = req(base + '/api', b'{"reset_stats": true}', {'Content-Type': 'application/json'})
    checks.append(('POST without the header refused', code == 403))
    code, _ = req(base + '/state', headers={'Host': 'example.com'})
    checks.append(('foreign Host refused', code == 403))
    code, _ = req(base + '/api', b'{"reset_stats": true}', {'Content-Type': 'application/json', 'X-121GW-Companion': '1'})
    checks.append(('POST with the header accepted', code == 200))
    for name, ok in checks:
        print('smoke: %s %s' % ('PASS' if ok else 'FAIL', name))
    return 0 if all(ok for _, ok in checks) else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
