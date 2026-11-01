"""Local web UI for the 121GW emulator (Python standard library only).

GET  /               front panel page
GET  /assets/...     static assets (LCD layers, bit map)
GET  /state          JSON snapshot: LCD RAM, outputs, run state, recent log lines
POST /input          JSON command: {"key": name, "down": bool} | {"dial": position} |
                     {"jack": name, "plugged": bool} | {"run": bool} | {"reset": true} | {"speed": x} |
                     {"analog": "PA4"|"PA5", "volts": v} | {"battery": B+ volts (PA5 via R69/R70)} |
                     {"input": {"kind": "open"|"V"|"A"|"ohm"|"Hz"|"F"|"degC"|"diode"|"VA", "value": x,
                                "ac": bool, "freq": f, "duty": d, "width": s, "dc": v, "amps": a, "board": t}} |
                     {"environment": {"pickup_hz": 50|60, "pickup_v": v, "coupling_pf": c, "drift": d}}
                     (stimulus fields: emu/frontend.py module docstring; app.py Emulator.command)
The emulator object passed to serve() must provide snapshot() and command(dict); it runs in its
own thread and is shared with scripted tests, so the page always shows the machine under test.
"""
import json, os, threading
from urllib.parse import unquote
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

HERE = os.path.dirname(os.path.abspath(__file__))
TYPES = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
         '.svg': 'image/svg+xml', '.json': 'application/json', '.png': 'image/png', '.jpg': 'image/jpeg'}


def make_handler(emu):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _send(self, code, body, ctype):
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = unquote(self.path.split('?')[0])
            if path == '/state':
                return self._send(200, json.dumps(emu.snapshot()).encode(), TYPES['.json'])
            rel = 'index.html' if path == '/' else path.lstrip('/')
            full = os.path.normpath(os.path.join(HERE, rel))
            if not full.startswith(HERE) or not os.path.isfile(full):
                return self._send(404, b'not found', 'text/plain')
            with open(full, 'rb') as f:
                self._send(200, f.read(), TYPES.get(os.path.splitext(full)[1], 'application/octet-stream'))

        def do_POST(self):
            if self.path != '/input':
                return self._send(404, b'not found', 'text/plain')
            n = int(self.headers.get('Content-Length', 0))
            try:
                cmd = json.loads(self.rfile.read(n) or b'{}')
                emu.command(cmd)
                self._send(200, b'{"ok":true}', TYPES['.json'])
            except Exception as e:                       # report bad commands to the page
                self._send(400, json.dumps({'error': str(e)}).encode(), TYPES['.json'])
    return H


def serve(emu, port=8121):
    httpd = ThreadingHTTPServer(('127.0.0.1', port), make_handler(emu))
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd
