"""The companion program: meter link, decoded readings, session, local server, window.

    python -m meter121 [--port 8221] [--browser | --no-open]

The window is a native one (pywebview: WebKit on macOS, Edge WebView2 on Windows) where the system has a web view, else
the default browser; closing the window ends the program.  Recordings go to <Documents>/121GW unless --folder says
otherwise.
"""
import argparse
import json
import os
import sys
import threading
import time
import webbrowser

from . import clock, display, frames, paths, record, releases, transfer
from .link import MeterLink
from .server import serve

TITLE = '121GW Companion'


def config_path():
    """The program's settings file (JSON) in the user's configuration folder."""
    return os.path.join(paths.config_dir(), 'settings.json')


def load_settings():
    try:
        with open(config_path(), encoding='utf-8') as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_settings(d):
    p = config_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p + '.part', 'w', encoding='utf-8') as f:
        json.dump(d, f, indent=1)
    os.replace(p + '.part', p)


RELEASE_RECHECK = 1800.0                         # seconds between release checks while connected
VERSION_WAIT = 2.0                               # seconds to wait for the answer to a version request
VERSION_RETRY = 10.0                             # seconds between requests while the link is not ready


class Companion:
    def __init__(self, folder):
        self.folder = folder
        self.settings = load_settings()
        self.clock = {'server': self.settings.get('ntp_server') or clock.DEFAULT_SERVER, 'last': None}
        self._clock_echo = None
        self.session = record.Session()
        # firmware of the connected meter (FEATURES.md 2.11 stage 3): 'unknown' until asked; 'fast' with version;
        # 'other' = the meter echoed the request without a version frame (v2.05 or the like-v2.05 build)
        self.fw_kind, self.version = 'unknown', None
        self._echo = self._ver = None
        self._asked = threading.Event()
        # firmware update (FEATURES.md 2.11 stage 4): state none / available / downloading / waiting_ld / sending / done /
        # error; 'later' hides the notice until the next connection
        self.update = {'state': 'none', 'latest': None, 'tag': None, 'later': False, 'done': 0, 'total': 0, 'message': ''}
        self._sender = None
        self._cancel = False
        self.link = MeterLink(self._frame, self._state)
        threading.Thread(target=self._ask_version, name='version', daemon=True).start()
        threading.Thread(target=self._recheck_releases, name='releases', daemon=True).start()

    def _frame(self, kind, frame, t):
        if kind == frames.STATUS:
            self.session.add(display.decode(frame, t))
        elif kind == frames.VERSION:
            self._ver = frames.version_text(frame)
        elif kind == frames.KEY_ECHO and frame == frames.VERSION_REQUEST:
            self._echo = t
        elif kind == frames.CLOCK_ECHO:
            self._clock_echo = frame
        elif kind == frames.BFT and self._sender is not None:
            a = transfer.answer(frame)
            if a is not None:
                self._sender.answers.put(a)

    def _state(self, state, detail):
        if state == 'connected':
            self.fw_kind, self.version = 'unknown', None
            if self.update['state'] in ('none', 'available', 'done', 'error'):
                self.update.update(state='none', later=False, message='')
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
                    self._check_release()
                elif self._echo is not None:
                    self.fw_kind = 'other'
                else:
                    time.sleep(VERSION_RETRY)
            self._asked.clear()

    def _recheck_releases(self):
        """Look for a newer release again every RELEASE_RECHECK seconds while a fast-build meter is connected."""
        while True:
            time.sleep(RELEASE_RECHECK)
            if self.link.state == 'connected' and self.fw_kind == 'fast':
                self._check_release()

    def _check_release(self):
        """Offer an update when a newer fast release exists than the version the meter reported."""
        cur = releases.version_of_meter(self.version)
        if cur is None or self.update['state'] not in ('none', 'available'):
            return
        try:
            ver, tag = releases.latest()
        except (OSError, ValueError, releases.ReleaseError):
            return                                          # offline: no notice, the meter keeps its firmware
        if ver > cur:
            self.update.update(state='available', latest=releases.meter_text(ver), tag=tag)

    def _run_update(self):
        u = self.update
        try:
            u.update(state='downloading', message='getting %s from the releases' % u['latest'])
            data = releases.image(u['tag'])
            self._sender = transfer.Sender(self.link.send)
            u.update(state='waiting_ld', message='')
            while not self._sender.probe():
                if self._cancel:
                    raise transfer.TransferError('cancelled')
                time.sleep(1.0)
            u.update(state='sending', done=0, total=len(data))
            th = threading.Thread(target=lambda: setattr(self, '_result', self._send(data)), daemon=True)
            self._result = None
            th.start()
            while th.is_alive():
                u.update(done=self._sender.done)
                time.sleep(0.2)
            if isinstance(self._result, Exception):
                raise self._result
            u.update(state='done', done=len(data), message=('%d card session(s) were repeated' % self._result)
                     if self._result else '')
        except (OSError, ValueError, RuntimeError, releases.ReleaseError, transfer.TransferError) as e:
            u.update(state='error', message=str(e))
        finally:
            self._sender, self._cancel = None, False

    def _send(self, data):
        try:
            return self._sender.run(data)
        except (OSError, RuntimeError, transfer.TransferError) as e:
            return e

    def sync_time(self, server):
        """Set the meter's clock from NTP: query, wait for the next whole second, send the frame for that second,
        wait for the meter's echo.  Returns a summary for the page."""
        server = (server or self.clock['server']).strip()
        if not server:
            raise ValueError('no NTP server given')
        if self.link.state != 'connected':
            raise RuntimeError('not connected to a meter')
        now, offset, delay = clock.ntp_time(server)
        target = int(now) + 1                              # the next whole second of the server's time
        time.sleep(max(0.0, target - (time.time() + offset)))
        frame = clock.clock_frame(target)
        self._clock_echo = None
        self.link.send(frame)
        end = time.time() + 2.0
        while time.time() < end and self._clock_echo != frame:
            time.sleep(0.02)
        if self._clock_echo != frame:
            raise RuntimeError('the meter did not confirm the time (no echo); try again')
        if server != self.clock['server']:
            self.settings['ntp_server'] = server
            save_settings(self.settings)
        note = '' if self.fw_kind == 'fast' else ' (v2.05 firmware takes the time only once per Bluetooth session)'
        self.clock = {'server': server, 'last': {'time': time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(target)),
                                                 'offset': offset, 'delay': delay, 'note': note}}
        return {'ok': True, 'set_to': self.clock['last']['time'], 'server': server, 'offset': offset, 'note': note}

    def state(self, since=None):
        L = self.link
        return {'now': time.time(),
                'link': {'state': L.state, 'detail': L.detail, 'device': L.device, 'found': L.found,
                         'rx_bytes': L.rx_bytes, 'rx_dropped': L.rx_dropped},
                'meter': {'firmware': self.fw_kind, 'version': self.version},
                'update': dict(self.update),
                'clock': self.clock,
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
        if 'sync_time' in c:
            try:
                return self.sync_time(c.get('server'))
            except clock.ClockError as e:
                raise RuntimeError(str(e)) from e
        if 'update_later' in c:
            self.update['later'] = True
            return {'ok': True}
        if 'update_now' in c:
            if self.update['state'] not in ('available', 'error') or not self.update['tag']:
                raise ValueError('no update to install')
            if self.link.state != 'connected':
                raise RuntimeError('not connected to a meter')
            self._cancel = False
            self.update['later'] = False
            threading.Thread(target=self._run_update, name='update', daemon=True).start()
            return {'ok': True}
        if 'update_cancel' in c:
            self._cancel = True
            if self._sender is not None:
                self._sender.cancelled = True
            return {'ok': True}
        raise ValueError('unknown command')


def documents_folder():
    return paths.documents_dir()


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
