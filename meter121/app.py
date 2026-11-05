"""The companion program: meter link, decoded readings, session, local server, window.

    python -m meter121 [--port 8221] [--browser | --no-open]

The window is a native one (pywebview: WebKit on macOS, Edge WebView2 on Windows) where the system has a web view, else
the default browser; closing the window ends the program.  Recordings go to <Documents>/121GW unless --folder says
otherwise.
"""
import argparse
import json
import os
import queue
import sys
import threading
import time
import webbrowser
from contextlib import contextmanager

from . import card, clock, derived, diag, display, frames, keys, paths, record, releases, transfer
from . import settings as meter_settings
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


DESK_STALE = 4.0                                 # seconds without a status frame before the meter is asked for page Ld
DESK_PERIOD = 1.0                                # seconds between looks of the desk watcher
DESK_PROBE_TIMEOUT = 1.5                         # seconds the page Ld has to answer a status request
KEY_ECHO_WAIT = 1.0                              # seconds to wait for the echo of a key frame
LINK_WAIT = 2.5                                  # seconds a command waits for the link while the desk watcher's page check has it
UPDATE_ACTIVE = ('downloading', 'waiting_ld', 'restarting', 'sending')      # update states that own the link
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
        # bootloader (bootloader/DESIGN.md): 'EEV' = EEVblog's, 'B-A.BC' = the two-part bootloader, None = not known
        # (firmware older than F-1.03 does not answer the question); mode 'bootloader' = the meter is in its update mode
        self.bl, self.mode = None, 'unknown'
        self._echo = self._ver = self._blver = None
        self._asked = threading.Event()
        # firmware update (FEATURES.md 2.11 stage 4): state none / available / downloading / waiting_ld / sending / done /
        # error; 'later' hides the notice until the next connection
        # 'fw' / 'bl': (meter text, release tag) of a newer firmware / bootloader, or None; 'what' of a running update
        self.update = {'state': 'none', 'fw': None, 'bl': None, 'checked': None, 'latest': [], 'check_error': '',
                       'what': None, 'step': '', 'later': False, 'done': 0,
                       'total': 0, 'message': ''}
        self._sender = None
        self._cancel = False
        # desk mode: the meter shows the SETUP page Ld (status frames stop, the page answers transfer requests); the
        # exclusive use of the link by one operation (probe, diagnosis, card, settings) is the lock
        self.desk = False
        self._frame_t = 0.0                              # time of the last status frame
        self._key_echo = None
        self._bft_lock = threading.Lock()
        self._bft_what = ''
        self._ops_sender = None
        self._ext_answers = queue.Queue(maxsize=64)      # answer frames of type 0x82 (card.py, settings.py)
        self._card_client = None
        self._card_gate = threading.Lock()               # makes "no operation running" and "start one" one step
        # derived values (derived.py); options survive restarts in settings.json under 'derived'
        try:
            self.derived = derived.Derived(self.settings.get('derived'))
        except ValueError:
            self.derived = derived.Derived()
        self.diag = {'values': [], 'text': ''}
        self.card_st = {'files': [], 'free_bytes': None, 'total_bytes': None, 'busy': False, 'op': '', 'progress': 0.0,
                        'sync': {'folder': self.settings.get('card_sync_folder'), 'last': None, 'copied': 0},
                        'error': None, 'result': ''}
        self.settings_st = {'items': [], 'error': None}
        self.link = MeterLink(self._frame, self._state)
        threading.Thread(target=self._ask_version, name='version', daemon=True).start()
        threading.Thread(target=self._watch_desk, name='desk', daemon=True).start()
        threading.Thread(target=self._recheck_releases, name='releases', daemon=True).start()

    def _frame(self, kind, frame, t):
        if kind == frames.STATUS:
            r = display.decode(frame, t)
            self.session.add(r)
            self.derived.feed(r)
            self._frame_t, self.desk = t, False          # status frames are sent only while page Ld is not shown
        elif kind == frames.VERSION:
            self._ver = frames.version_text(frame)
        elif kind == frames.BL_VERSION:
            self._blver = frames.bl_version_text(frame)
        elif kind == frames.KEY_ECHO:
            self._key_echo = frame
            if frame == frames.VERSION_REQUEST:
                self._echo = t
        elif kind == frames.CLOCK_ECHO:
            self._clock_echo = frame
        elif kind == frames.BFT:
            if frame[2] == card.T_ANSWER:                # answers of the card and settings requests
                try:
                    self._ext_answers.put_nowait(frame)
                except queue.Full:
                    pass
                return
            a = transfer.answer(frame)
            if a is not None:
                for sender in (self._sender, self._ops_sender):
                    if sender is not None:
                        sender.answers.put(a)

    def _state(self, state, detail):
        self.desk = False                                # a new connection or none: the page is not known any more
        self._frame_t = 0.0
        if state == 'connected':
            self.fw_kind, self.version, self.mode = 'unknown', None, 'unknown'
            if self.update['state'] in ('none', 'available', 'done', 'error'):
                self.update.update(state='none', later=False, message='')
            self._asked.set()

    def _ask_version(self):
        """After each connection: what runs on the meter.  The firmware answers the version request with its echo and,
        the fast build, a version frame (then the bootloader question, F-1.03 on); the bootloader's update mode answers
        only its own status request.  Nothing at all: the link was not ready (page Ld shown or an SD access running):
        ask again later."""
        while True:
            self._asked.wait()
            while self.link.state == 'connected' and self.mode == 'unknown':
                self._echo = self._ver = self._blver = None
                try:
                    self.link.send(frames.VERSION_REQUEST)
                except (RuntimeError, OSError, TimeoutError):
                    break
                end = time.time() + VERSION_WAIT
                while time.time() < end and self._ver is None:
                    time.sleep(0.05)
                if self._ver is not None:
                    self.fw_kind, self.version = 'fast', self._ver
                    self.bl = self._ask_bootloader()
                    self.mode = 'firmware'
                    self._check_release()
                elif self._echo is not None:
                    self.fw_kind, self.mode = 'other', 'firmware'
                else:
                    v = self._boot_probe()
                    if v is not None:
                        self.bl, self.mode = releases.bootloader_text(v), 'bootloader'
                        self._check_release()
                    else:
                        time.sleep(VERSION_RETRY)
            self._asked.clear()

    def _ask_bootloader(self):
        """'EEV', 'B-A.BC', or None when the firmware does not answer key code 0x92 (older than F-1.03)."""
        self._blver = None
        try:
            self.link.send(frames.BL_VERSION_REQUEST)
        except (RuntimeError, OSError, TimeoutError):
            return None
        end = time.time() + VERSION_WAIT
        while time.time() < end and self._blver is None:
            time.sleep(0.05)
        return self._blver

    def _boot_probe(self):
        """(A, B, C) when the bootloader's update mode answers its status request, else None."""
        if not self._bft_lock.acquire(blocking=False):  # a card or settings operation has the link: ask again later
            return None
        own = self._sender is None
        if own:
            self._sender = transfer.Sender(self.link.send)
        try:
            return transfer.boot_version(self._sender)
        except (RuntimeError, OSError, TimeoutError):
            return None
        finally:
            if own:
                self._sender = None
            self._bft_lock.release()

    def _recheck_releases(self):
        """Look for newer releases again every RELEASE_RECHECK seconds while a meter is connected."""
        while True:
            time.sleep(RELEASE_RECHECK)
            if self.link.state == 'connected' and self.mode != 'unknown':
                self._check_release()

    def _check_release(self):
        """Offer what is newer than the meter has: the fast firmware (a meter in the bootloader's update mode is offered
        the latest firmware), the two-part bootloader (first install on a meter with EEVblog's bootloader needs
        firmware F-1.03 or newer: the firmware writes it)."""
        if self.update['state'] not in ('none', 'available'):
            return
        fw = bl = None
        latest, problems = [], []
        try:
            ver, tag = releases.latest()
            latest.append(tag)
            cur = releases.version_of_meter(self.version)
            if self.mode == 'bootloader' or (cur is not None and ver > cur):
                fw = (releases.meter_text(ver), tag)
        except (OSError, ValueError, releases.ReleaseError) as e:
            problems.append('firmware releases: %s' % e)    # offline or none published: nothing offered
        try:
            bver, btag = releases.latest_bootloader()
            latest.append(btag)
            have = releases.version_of_bootloader(self.bl)
            if have is not None and bver > have:
                bl = (releases.bootloader_text(bver), btag)
            elif self.bl == 'EEV':
                bl = (releases.bootloader_text(bver), btag)
        except (OSError, ValueError, releases.ReleaseError) as e:
            problems.append('bootloader releases: %s' % e)
        state = 'available' if fw or bl else 'none'
        # checked / latest / check_error: what the UI shows for 'none' (up to date, or why nothing could be checked)
        self.update.update(state=state, fw=fw, bl=bl, checked=time.time(), latest=latest, check_error='; '.join(problems))

    # ------------------------------------------------------------------ updates
    def _run_update(self, what):
        """what: 'firmware', 'bootloader' or 'both'.  With EEVblog's bootloader the firmware goes first (the first
        install needs F-1.03 on the meter); with the two-part bootloader the bootloader goes first (DESIGN.md 5)."""
        u = self.update
        try:
            steps = ['firmware', 'bootloader'] if what == 'both' else [what]
            if what == 'both' and self.bl != 'EEV':
                steps.reverse()
            for step in steps:
                if step == 'firmware':
                    self._update_firmware()
                else:
                    self._update_bootloader()
            u.update(state='done', step='', message=u.get('message', ''))
        except (OSError, ValueError, RuntimeError, releases.ReleaseError, transfer.TransferError) as e:
            u.update(state='error', message=str(e))
        finally:
            self._sender, self._cancel = None, False

    def _update_firmware(self):
        u = self.update
        if not u['fw']:
            return
        text, tag = u['fw']
        u.update(state='downloading', what='firmware', step=text, message='getting %s from the releases' % text)
        data = releases.image(tag)
        if self.mode == 'bootloader' or releases.version_of_bootloader(self.bl):
            self._enter_update_mode()
            self._boot_send(data, transfer.KIND_FIRMWARE, None, text)
            self._wait_restart(lambda: self.mode == 'firmware' and self.version == text,
                               'the meter did not come back with %s' % text)
            u.update(message='')
        else:
            self._sender = transfer.Sender(self.link.send)
            self._wait_ld()
            self._send_tracked(lambda: self._sender.run(data), len(data), text)
            u.update(message='%s is on the SD card. To install: switch the meter off, hold HOLD and MEM while '
                             'switching it on, then press SETUP.' % text)

    def _update_bootloader(self):
        u = self.update
        if not u['bl']:
            return
        text, tag = u['bl']
        u.update(state='downloading', what='bootloader', step=text, message='getting %s from the releases' % text)
        install, boot = releases.bootloader_files(tag)
        if self.bl == 'EEV':
            if releases.version_of_meter(self.version) is None or releases.version_of_meter(self.version) < (1, 0, 3):
                raise transfer.TransferError('the first bootloader install needs firmware F-1.03 or newer on the meter: '
                                             'update the firmware first')
            self._sender = transfer.Sender(self.link.send)
            self._wait_ld()
            try:
                self._send_tracked(lambda: self._sender.run(install, kind=transfer.KIND_INSTALL), len(install), text)
            except transfer.TransferError as e:
                # F-1.03 as first built could restart before its END answer went out (2026-11-04): the meter's own
                # report after the restart decides
                if 'no answer to packet' not in str(e):
                    raise
        else:
            self._enter_update_mode()
            ver = releases.version_of_bootloader(text)
            self._boot_send(boot, transfer.KIND_BOOTLOADER, ver[0] << 16 | ver[1] << 8 | ver[2], text)
        self._wait_restart(lambda: self.bl == text, 'the meter did not report bootloader %s' % text)
        u.update(message='')

    def _wait_ld(self):
        self.update.update(state='waiting_ld', message='')
        while not self._sender.probe():
            if self._cancel:
                raise transfer.TransferError('cancelled')
            time.sleep(1.0)

    def _enter_update_mode(self):
        """Restart the meter into the bootloader's update mode (key code 0x91) unless it is there already."""
        if self.mode == 'bootloader':
            return
        self.update.update(state='restarting', message='the meter restarts into its update mode')
        try:
            self.link.send(frames.UPDATE_MODE_REQUEST)
        except Exception:                               # noqa: BLE001 - the meter restarts at once: the write's
            pass                                        # confirmation can be lost with the link (bleak: disconnected)
        self._wait_restart(lambda: self.mode == 'bootloader', 'the meter did not come back in its update mode')

    def _wait_restart(self, ready, failure, timeout=90.0):
        """The meter restarts (its Bluetooth module is switched off with it): wait for the link to drop, the link
        reconnects by itself, then for `ready()` after the version questions."""
        self.update.update(state='restarting')
        end = time.time() + timeout
        while time.time() < end and self.link.state == 'connected' and not ready():
            time.sleep(0.2)
        while time.time() < end and not ready():
            if self._cancel:
                raise transfer.TransferError('cancelled')
            time.sleep(0.2)
        if not ready():
            raise transfer.TransferError(failure)

    def _boot_send(self, data, kind, version, text):
        self._sender = transfer.BootSender(self.link.send)
        self._send_tracked(lambda: self._sender.run(data, kind, version), len(data), text)

    def _send_tracked(self, job, total, text):
        u = self.update
        u.update(state='sending', done=0, total=total, step=text)
        box = {}
        th = threading.Thread(target=lambda: box.setdefault('r', self._guard(job)), daemon=True)
        th.start()
        while th.is_alive():
            u.update(done=self._sender.done)
            time.sleep(0.2)
        if isinstance(box.get('r'), Exception):
            raise box['r']
        u.update(done=total)
        self._sender = None

    @staticmethod
    def _guard(job):
        try:
            return job()
        except (OSError, RuntimeError, transfer.TransferError) as e:
            return e

    # ------------------------------------------------------------------ link use outside the update: keys, desk, card
    def _update_active(self):
        return self.update['state'] in UPDATE_ACTIVE

    def _lock_reason(self):
        """Why the file-transfer operations (diagnosis, card, settings) cannot run now, or None."""
        if self.link.state != 'connected':
            return 'not connected to a meter'
        if self._update_active():
            return 'a firmware or bootloader update is running'
        if self.card_st['busy']:
            return 'a card operation is running: %s' % self.card_st['op']
        if not self.desk:
            return 'show the SETUP page Ld on the meter (Bluetooth on, logging off)'
        return None

    @contextmanager
    def _ops(self, what, need_desk=True, wait=0.0):
        """Exclusive use of the link for one operation of the file-transfer protocol (the meter takes one request at a
        time): yields (Sender for the 0x81 answers, card.Client for the 0x82 answers).  RuntimeError when the link is
        not connected, an update has it, another operation still runs after `wait` seconds, or (need_desk) the page Ld
        is not shown.  Commands of the user wait LINK_WAIT, because the desk watcher's page check holds the link for
        up to DESK_PROBE_TIMEOUT every DESK_PERIOD while no status frames come; the watcher itself does not wait."""
        if self.link.state != 'connected':
            raise RuntimeError('not connected to a meter')
        if self._update_active():
            raise RuntimeError('a firmware or bootloader update is running')
        if need_desk and not self.desk:
            raise RuntimeError('show the SETUP page Ld on the meter first (Bluetooth on, logging off)')
        if not self._bft_lock.acquire(timeout=wait):
            raise RuntimeError('the link is busy: %s' % (self._bft_what or 'another operation'))
        if need_desk and not self.desk:                  # the page was left while this command waited for the link
            self._bft_lock.release()
            raise RuntimeError('show the SETUP page Ld on the meter first (Bluetooth on, logging off)')
        self._bft_what = what
        sender = self._ops_sender = transfer.Sender(self.link.send)
        client = card.Client(self.link.send, self._ext_answers)
        self._card_client = client
        while not self._ext_answers.empty():
            self._ext_answers.get_nowait()
        try:
            yield sender, client
        finally:
            self._ops_sender = self._card_client = None
            self._bft_what = ''
            self._bft_lock.release()

    def _watch_desk(self):
        """Desk mode: while the meter shows page Ld it sends no status frames and answers the transfer's status request
        (transfer.Sender.probe).  So: no status frame for DESK_STALE seconds on a connected meter that has the transfer
        (the fast firmware, or one not asked yet) -> ask; an answer means desk.  Any status frame ends desk (_frame).
        Not asked while an update or another operation uses the link, nor for v2.05 firmware (no transfer there) or
        the bootloader's update mode."""
        while True:
            time.sleep(DESK_PERIOD)
            if (self.link.state != 'connected' or self._update_active() or self.mode == 'bootloader'
                    or self.fw_kind == 'other' or time.time() - self._frame_t < DESK_STALE):
                continue
            try:
                with self._ops('page check', need_desk=False) as (sender, _):
                    self.desk = sender.probe(DESK_PROBE_TIMEOUT)
            except RuntimeError:
                continue                                 # the link is in use: desk stays as it is
            except (OSError, TimeoutError):
                self.desk = False

    def press_key(self, name, long=False):
        """Send the F4 key frame of a key of the meter (keys.py) and wait for its echo.  Refused while page Ld owns the
        link (no key arrives there), while an update or a card operation uses it, and in the bootloader's update mode."""
        frame = keys.frame(name, long)                   # ValueError for an unknown name
        if self.link.state != 'connected':
            raise RuntimeError('not connected to a meter')
        if self.mode == 'bootloader':
            raise RuntimeError('the meter is in its update mode: no keys')
        if self.desk:
            raise RuntimeError('page Ld owns the link: leave it on the meter before using the keys')
        if self.card_st['busy']:
            raise RuntimeError('a card operation is running: %s' % self.card_st['op'])
        with self._ops('key', need_desk=False, wait=LINK_WAIT):
            if self.desk:                                # found while the command waited for the link
                raise RuntimeError('page Ld owns the link: leave it on the meter before using the keys')
            self._key_echo = None
            self.link.send(frame)
            end = time.time() + KEY_ECHO_WAIT
            while time.time() < end and self._key_echo != frame:
                time.sleep(0.02)
        if self._key_echo != frame:
            raise RuntimeError('the meter did not confirm the key (page Ld shown, an SD access running, or the link '
                               'is not ready); try again')
        return {'ok': True, 'key': str(name).upper(), 'long': bool(long)}

    def diag_read(self):
        """STATUS values 0..20 of the file transfer with their readable text (diag.py); needs page Ld."""
        try:
            with self._ops('diagnosis', wait=LINK_WAIT) as (sender, _):
                values = [sender.status_value(i) for i in range(diag.COUNT)]
        except transfer.TransferError as e:
            raise RuntimeError(str(e)) from e
        self.diag = {'values': values, 'text': diag.explain(values)}
        return {'ok': True, 'diag': self.diag}

    # ------------------------------------------------------------------ settings of the meter (settings.py)
    def settings_get(self):
        return self._settings_op(lambda m: m.get_all())

    def settings_put(self, setting_id, value):
        meter_settings.check(setting_id, value)          # range check before the link is touched
        return self._settings_op(lambda m: m.put(setting_id, value))

    def _settings_op(self, job):
        try:
            with self._ops('settings', wait=LINK_WAIT) as (_, client):
                items = job(meter_settings.Settings(client))
        except (RuntimeError, ValueError, OSError) as e:
            self.settings_st['error'] = str(e)
            raise
        self.settings_st.update(items=items, error=None)
        return {'ok': True, 'items': items}

    # ------------------------------------------------------------------ SD card (card.py); one operation at a time, in a thread
    def _card_start(self, op, job, check=None):
        """Run job(card.Card, progress) in a thread; the page follows state.card.  `check` runs first (ValueError and
        RuntimeError reach the caller).  Returns at once."""
        st = self.card_st
        with self._card_gate:
            reason = self._lock_reason()
            if reason:
                raise RuntimeError(reason)
            if check:
                check()
            st.update(busy=True, op=op, progress=0.0, error=None, result='')

        def progress(done, total):
            st['progress'] = done / total if total else 1.0

        def run():
            try:
                with self._ops(op, wait=LINK_WAIT) as (_, client):
                    st['result'] = job(card.Card(client), progress)
                st['progress'] = 1.0
            except (RuntimeError, ValueError, OSError, transfer.TransferError) as e:
                st['error'] = str(e)
            except Exception as e:                       # noqa: BLE001 - a bug must reach the page, not die in the thread
                st['error'] = 'internal error: %r' % (e,)
            finally:
                st['busy'], st['op'] = False, ''

        # the lock is taken by run() itself; busy is set above so no second operation starts between the two
        threading.Thread(target=run, name='card', daemon=True).start()
        return {'ok': True}

    @staticmethod
    def _folder_arg(value, default):
        """Absolute folder path from a command parameter (text, ~ allowed); `default` when none was given."""
        if value is not None and not isinstance(value, str):
            raise ValueError('the folder must be text')
        return os.path.abspath(os.path.expanduser(value or default))

    def card_cancel(self):
        """Stop the running card operation at its next packet (a started local file is removed)."""
        if self._card_client is not None:
            self._card_client.cancelled = True
        return {'ok': True}

    def card_list(self):
        def job(c, progress):
            self.card_st['files'] = c.list()
            return '%d files' % len(self.card_st['files'])
        return self._card_start('list', job)

    def card_info(self):
        def job(c, progress):
            self.card_st.update(c.info())
            return 'card information'
        return self._card_start('info', job)

    def card_download(self, name, dest):
        card.check_local_name(name)
        folder = self._folder_arg(dest, os.path.join(self.folder, 'card'))

        def job(c, progress):
            size = next((f['size'] for f in self.card_st['files'] if f['name'] == name), None)
            return c.download(name, folder, size, progress)
        return self._card_start('download', job)

    def card_delete(self, name):
        def check():
            card.check_name(name)
            if card.is_protected(name):
                raise card.CardError('%s is protected: the meter needs it' % name, card.ST_PROTECTED)

        def job(c, progress):
            c.delete(name)
            self.card_st['files'] = c.list()             # the page shows the folder as it is now
            return 'deleted %s' % name
        return self._card_start('delete', job, check)

    def card_sync(self, folder):
        folder = self._folder_arg(folder, self.card_st['sync']['folder'] or os.path.join(self.folder, 'card'))

        def job(c, progress):
            r = c.sync(folder, progress)
            self.card_st['sync'] = {'folder': folder, 'last': time.strftime('%Y-%m-%d %H:%M:%S'), 'copied': r['copied']}
            if self.settings.get('card_sync_folder') != folder:
                self.settings['card_sync_folder'] = folder
                save_settings(self.settings)
            return '%d copied, %d unchanged%s' % (r['copied'], r['unchanged'],
                                                  (', skipped: ' + ', '.join(r['skipped'])) if r['skipped'] else '')
        return self._card_start('sync', job)

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
                'meter': {'firmware': self.fw_kind, 'version': self.version, 'bootloader': self.bl, 'mode': self.mode},
                'update': dict(self.update),
                'clock': self.clock,
                'session': self.session.snapshot(since),
                'folder': self.folder,
                'derived': self.derived.snapshot(),
                'desk': self.desk,
                'diag': dict(self.diag),
                'card': dict(self.card_st, files=list(self.card_st['files']), locked_reason=self._lock_reason()),
                'settings': dict(self.settings_st, locked_reason=self._lock_reason())}

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
            what = c['update_now'] if c['update_now'] in ('firmware', 'bootloader', 'both') else 'both'
            u = self.update
            if u['state'] not in ('available', 'error') or not (u['fw'] or u['bl']):
                raise ValueError('no update to install')
            if self.link.state != 'connected':
                raise RuntimeError('not connected to a meter')
            if self.card_st['busy']:
                raise RuntimeError('a card operation is running: %s' % self.card_st['op'])
            if not self._bft_lock.acquire(timeout=3.0):         # a page check or settings operation has the link
                raise RuntimeError('the link is busy: %s; try again' % self._bft_what)
            try:
                self._cancel = False
                u['later'] = False
                u['state'] = 'downloading'                        # the update owns the link from here (_update_active)
                threading.Thread(target=self._run_update, args=(what,), name='update', daemon=True).start()
            finally:
                self._bft_lock.release()
            return {'ok': True}
        if 'update_cancel' in c:
            self._cancel = True
            if self._sender is not None:
                self._sender.cancelled = True
            return {'ok': True}
        if 'key' in c:
            return self.press_key(c['key'], bool(c.get('long')))
        if 'card_cancel' in c:
            return self.card_cancel()
        if 'card_list' in c:
            return self.card_list()
        if 'card_info' in c:
            return self.card_info()
        if 'card_download' in c:
            return self.card_download(self._arg(c, 'card_download', 'name'), self._arg(c, 'card_download', 'dest'))
        if 'card_delete' in c:
            return self.card_delete(self._arg(c, 'card_delete', 'name'))
        if 'card_sync' in c:
            return self.card_sync(self._arg(c, 'card_sync', 'folder'))
        if 'settings_get' in c:
            return self.settings_get()
        if 'settings_put' in c:
            return self.settings_put(self._arg(c, 'settings_put', 'id'), self._arg(c, 'settings_put', 'value'))
        if 'diag_read' in c:
            return self.diag_read()
        if 'set_derived' in c:
            opts = c['set_derived'] if isinstance(c['set_derived'], dict) else \
                {k: c[k] for k in ('loop_range', 'pt_type', 'limit') if k in c}
            self.derived.set_options(opts)
            self.settings['derived'] = self.derived.options()
            save_settings(self.settings)
            return {'ok': True, 'derived': self.derived.snapshot()}
        raise ValueError('unknown command')

    @staticmethod
    def _arg(c, command, name):
        """Parameter `name` of a command given either inside the command's object or beside it."""
        v = c[command]
        return v.get(name) if isinstance(v, dict) else c.get(name)


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
