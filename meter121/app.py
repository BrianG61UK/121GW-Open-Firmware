"""The companion program: meter link, decoded readings, session, local server, window.

    python -m meter121 [--port 8221] [--browser | --no-open]

The window is a native one (pywebview: WebKit on macOS, Edge WebView2 on Windows) where the system has a web view, else
the default browser; closing the window ends the program.  Recordings go to <Documents>/121GW unless --folder says
otherwise.
"""
import argparse
import os
import sys
import threading
import time
import webbrowser

from . import display, frames, record
from .link import MeterLink
from .server import serve

TITLE = '121GW Companion'


VERSION_WAIT = 2.0                               # seconds to wait for the answer to a version request
VERSION_RETRY = 10.0                             # seconds between requests while the link is not ready


class Companion:
    def __init__(self, folder):
        self.folder = folder
        self.session = record.Session()
        # firmware of the connected meter (FEATURES.md 2.11 stage 3): 'unknown' until asked; 'fast' with version;
        # 'other' = the meter echoed the request without a version frame (v2.05 or the like-v2.05 build)
        self.fw_kind, self.version = 'unknown', None
        self._echo = self._ver = None
        self._asked = threading.Event()
        self.link = MeterLink(self._frame, self._state)
        threading.Thread(target=self._ask_version, name='version', daemon=True).start()

    def _frame(self, kind, frame, t):
        if kind == frames.STATUS:
            self.session.add(display.decode(frame, t))
        elif kind == frames.VERSION:
            self._ver = frames.version_text(frame)
        elif kind == frames.KEY_ECHO and frame == frames.VERSION_REQUEST:
            self._echo = t

    def _state(self, state, detail):
        if state == 'connected':
            self.fw_kind, self.version = 'unknown', None
            self._asked.set()

    def _ask_version(self):
        """After each connection: ask until the meter answers (echo and version = fast build; echo only = other build;
        neither = the link was not ready, e.g. page Ld shown or an SD access running: ask again later)."""
        while True:
            self._asked.wait()
            while self.link.state == 'connected' and self.fw_kind == 'unknown':
                self._echo = self._ver = None
                try:
                    self.link.send(frames.VERSION_REQUEST)
                except (RuntimeError, OSError, TimeoutError):
                    break
                end = time.time() + VERSION_WAIT
                while time.time() < end and self._ver is None:
                    time.sleep(0.05)
                if self._ver is not None:
                    self.fw_kind, self.version = 'fast', self._ver
                elif self._echo is not None:
                    self.fw_kind = 'other'
                else:
                    time.sleep(VERSION_RETRY)
            self._asked.clear()

    def state(self, since=None):
        L = self.link
        return {'now': time.time(),
                'link': {'state': L.state, 'detail': L.detail, 'device': L.device, 'found': L.found,
                         'rx_bytes': L.rx_bytes, 'rx_dropped': L.rx_dropped},
                'meter': {'firmware': self.fw_kind, 'version': self.version},
                'session': self.session.snapshot(since),
                'folder': self.folder}

    def command(self, c):
        if 'connect' in c:
            self.link.connect(c['connect'])
            return {'ok': True}
        if 'disconnect' in c:
            self.link.disconnect()
            return {'ok': True}
        if 'record' in c:
            if c['record']:
                return {'ok': True, 'path': self.session.start_recording(self.folder)}
            return {'ok': True, 'path': self.session.stop_recording()}
        if 'reset_stats' in c:
            self.session.reset_stats()
            return {'ok': True}
        raise ValueError('unknown command')


def documents_folder():
    home = os.path.expanduser('~')
    docs = os.path.join(home, 'Documents')
    return os.path.join(docs if os.path.isdir(docs) else home, '121GW')


def open_window(url):
    """Native window; False when none can be made (the browser is used then)."""
    if sys.platform.startswith('linux'):
        return False
    try:
        import webview
        webview.create_window(TITLE, url, width=1180, height=760, min_size=(860, 560), background_color='#0c0c0b')
        webview.start(gui='edgechromium' if sys.platform == 'win32' else None)
        return True
    except Exception:
        return False


def main(argv=None):
    ap = argparse.ArgumentParser(description=TITLE)
    ap.add_argument('--port', type=int, default=8221)
    ap.add_argument('--port-tries', type=int, default=20)
    ap.add_argument('--folder', default=None, help='folder for recordings (default <Documents>/121GW)')
    ap.add_argument('--browser', action='store_true', help='use the default browser instead of a window')
    ap.add_argument('--no-open', action='store_true', help='open nothing (scripted use)')
    a = ap.parse_args(argv)
    app = Companion(a.folder or documents_folder())
    err = None
    for port in range(a.port, a.port + a.port_tries):
        try:
            serve(app, port)
            break
        except OSError as e:
            err = e
    else:
        raise SystemExit('no free port from %d: %s' % (a.port, err))
    url = 'http://127.0.0.1:%d/' % port
    print('%s: %s' % (TITLE, url), flush=True)
    if a.no_open:
        while True:
            time.sleep(3600)
    if a.browser or not open_window(url):
        threading.Timer(0.3, webbrowser.open, (url,)).start()
        while True:
            time.sleep(3600)
    app.link.disconnect()
