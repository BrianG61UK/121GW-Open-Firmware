"""Local HTTP server between the program's window and the meter link (127.0.0.1 only).

    GET  /                 the page (ui/index.html)
    GET  /assets/<file>    files of ui/assets
    GET  /state?since=T    JSON: link, meter, session (statistics, trend points newer than T), update notice, and the
                           derived values, desk mode, diagnosis, SD card and settings of the meter (STATE.md)
    POST /api              JSON command; needs the request header "X-121GW-Companion: 1"
    POST /upload?kind=auto|firmware|bootloader&name=<file name>   (auto: the file says what it is)
                           the bytes of a file the user chose (METER view); the program checks it (app.stage_file) and
                           keeps it for the command install_chosen; at most UPLOAD_MAX bytes; same header rule

Protection: the server binds 127.0.0.1, answers only requests whose Host header names 127.0.0.1 or localhost (a web
page cannot reach it through a DNS name), and every POST needs the custom header, which a page of another origin cannot
send without a CORS preflight this server never grants.  So no web page can make the program send anything to the meter.
"""
import json
import mimetypes
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LOG_COMMANDS = os.environ.get('COMPANION_LOG') == '1'

HERE = os.path.dirname(os.path.abspath(__file__))
# the page: next to the package in a source tree; in the packaged program (PyInstaller) in the bundle folder
# sys._MEIPASS, because there the package's own folder exists only inside the archive, not on disk
UI = os.path.join(getattr(sys, '_MEIPASS', None) or os.path.normpath(os.path.join(HERE, '..')), 'ui')
HEADER = 'X-121GW-Companion'
UPLOAD_MAX = 0x5A000                             # largest file taken: the largest firmware image the meter accepts
UPLOAD_TIMEOUT = 30.0                            # seconds the bytes of an uploaded file may take


def make_handler(app):
    class Handler(BaseHTTPRequestHandler):
        server_version = '121GW-Companion'

        def log_message(self, fmt, *args):
            pass

        def _host_ok(self):
            host = (self.headers.get('Host') or '').rsplit(':', 1)[0].strip('[]')
            return host in ('127.0.0.1', 'localhost')

        def _send(self, code, body, ctype='application/json'):
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def _json(self, code, obj):
            self._send(code, json.dumps(obj).encode())

        def do_GET(self):
            if not self._host_ok():
                return self._json(403, {'error': 'wrong host'})
            u = urlparse(self.path)
            if u.path == '/':
                return self._file(os.path.join(UI, 'index.html'))
            if u.path.startswith('/assets/'):
                p = os.path.normpath(os.path.join(UI, 'assets', u.path[len('/assets/'):]))
                if not p.startswith(os.path.normpath(os.path.join(UI, 'assets')) + os.sep):
                    return self._json(404, {'error': 'not found'})
                return self._file(p)
            if u.path == '/state':
                q = parse_qs(u.query)
                since = float(q['since'][0]) if 'since' in q else None
                return self._json(200, app.state(since))
            return self._json(404, {'error': 'not found'})

        def _file(self, p):
            if not os.path.isfile(p):
                return self._json(404, {'error': 'not found'})
            ctype = mimetypes.guess_type(p)[0] or 'application/octet-stream'
            with open(p, 'rb') as f:
                self._send(200, f.read(), ctype)

        def _upload(self, q):
            """The bytes of a file the user chose: a length is demanded (no waiting for the end of the connection), the
            read has a time limit, and nothing is kept unless the program's checks pass."""
            try:
                n = int(self.headers.get('Content-Length') or -1)
            except ValueError:
                n = -1
            if n < 0:
                return self._json(400, {'error': 'bad Content-Length'})
            if n > UPLOAD_MAX:
                return self._json(413, {'error': 'file too large: at most %d bytes' % UPLOAD_MAX})
            try:
                self.connection.settimeout(UPLOAD_TIMEOUT)
                data = self.rfile.read(n)
                if len(data) != n:
                    return self._json(400, {'error': 'the file did not arrive completely'})
                return self._json(200, app.stage_file((q.get('kind') or [''])[0], (q.get('name') or [''])[0], data))
            except (ValueError, TypeError, KeyError, RuntimeError, OSError) as e:
                return self._json(400, {'error': str(e)})

        def do_POST(self):
            if not self._host_ok():
                return self._json(403, {'error': 'wrong host'})
            if self.headers.get(HEADER) != '1':
                return self._json(403, {'error': 'missing header %s' % HEADER})
            u = urlparse(self.path)
            if u.path == '/upload':
                return self._upload(parse_qs(u.query))
            if u.path != '/api':
                return self._json(404, {'error': 'not found'})
            try:
                n = int(self.headers.get('Content-Length') or 0)
            except ValueError:
                return self._json(400, {'error': 'bad Content-Length'})
            if n < 0:                                   # rfile.read(-1) would wait for the end of the connection
                return self._json(400, {'error': 'bad Content-Length'})
            if n > 65536:
                return self._json(413, {'error': 'request too large'})
            try:
                cmd = json.loads(self.rfile.read(n) or b'{}')
                if LOG_COMMANDS:                        # COMPANION_LOG=1: every command as it arrives (diagnosis)
                    print('%.3f command %s' % (time.time(), json.dumps(cmd)[:200]), file=sys.stderr, flush=True)
                return self._json(200, app.command(cmd))
            except (ValueError, TypeError, KeyError, RuntimeError, OSError) as e:
                return self._json(400, {'error': str(e)})

    return Handler


def serve(app, port):
    httpd = ThreadingHTTPServer(('127.0.0.1', port), make_handler(app))
    threading.Thread(target=httpd.serve_forever, name='http', daemon=True).start()
    return httpd
