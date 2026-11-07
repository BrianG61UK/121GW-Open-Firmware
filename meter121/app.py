"""The companion program: meter link, decoded readings, session, local server, window.

    python -m meter121 [--port 8221] [--browser | --no-open]

The window is a native one (pywebview: WebKit on macOS, Edge WebView2 on Windows) where the system has a web view, else
the default browser; closing the window ends the program.  Recordings go to <Documents>/121GW unless --folder says
otherwise.
"""
import argparse
import collections
import json
import os
import queue
import sys
import threading
import time
import webbrowser
from contextlib import contextmanager

from . import card, clock, derived, diag, display, frames, keys, paths, record, releases, report, transfer
from . import settings as meter_settings
from .link import MeterLink
from . import server
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
TRACE_UI = os.environ.get('COMPANION_LOG') == '1'     # the page and the window report pointer events (diagnosis)
UPDATE_ACTIVE = ('downloading', 'waiting_ld', 'restarting', 'sending')      # update states that own the link
RELEASE_RECHECK = 1800.0                         # seconds between release checks while connected
VERSION_WAIT = 2.0                               # seconds to wait for the answer to a version request
VERSION_RETRY = 10.0                             # seconds between requests while the link is not ready
VERSION_TRIES = 3                                # version requests answered by the echo alone until the firmware counts as v2.05
EVENTS_KEEP = 300                                # events kept for the diagnosis report
BL_ASK_TRIES = 3                                 # bootloader questions (key code 0x92) until an answer counts as none
DAILY = 86400.0                                  # update check "daily": seconds between two release checks
HUNT_MIN_VERSION = (1, 1, 6)                     # firmware F-1.16: EEPROM 0x020 bit 4, the SETUP page HUnt (ble/bftset.s accepts 0..31)
XDIAG_MIN_VERSION = (1, 1, 5)                    # firmware F-1.15: key codes 0x93 / 0x94 / 0x95 and STATUS 40..48 (ble/xdiag.s)
XDIAG_TRIES = 3                                  # tries of a key frame of the extended diagnosis / of the counters request
XDIAG_WAIT = 2.0                                 # seconds to wait for the answer to each try
XDIAG_STATUS_FIRST, XDIAG_STATUS_COUNT = 40, 9   # page Ld STATUS indices of the nine values (ble/bft.s bft_diag_tab)
MCLOCK_MIN_VERSION = (1, 1, 7)                   # firmware F-1.17: key code 0x96 / frame FA, STATUS 49..55 (sys/msical.s)
LEAVE_MIN_VERSION = (1, 1, 7)                    # firmware F-1.17: the page Ld request LEAVE (type 0x19, ble/bft.s)
MCLOCK_STATUS_FIRST, MCLOCK_STATUS_COUNT = 49, 7 # page Ld STATUS indices of the clock measurement

# the program's own settings (SETTINGS view), stored in settings.json; the meter's SETUP settings are on the meter
PREF_DEFAULTS = {'recordings_folder': None,      # None: <Documents>/121GW
                 'card_sync_folder': None,       # None: <recordings folder>/card
                 'ntp_server': clock.DEFAULT_SERVER,
                 'clock_on_connect': False,      # set the meter's clock from the time server after each connection
                 'update_check': 'connect',      # 'connect' (at each connection and every 30 min), 'daily', 'never'
                 'csv_format': 'comma',          # recordings: 'comma' = , and decimal point; 'semicolon' = ; and decimal comma
                 'diag_log': False,              # the COMPANION_LOG=1 diagnosis, from the next start
                 'ext_diag': False}              # the meter counts link errors inside (F-1.15 on) and the report shows them
UPDATE_CHECKS = ('connect', 'daily', 'never')
CSV_FORMATS = {'comma': (',', '.'), 'semicolon': (';', ',')}


class Companion:
    def __init__(self, folder=None):
        """folder: the recordings folder given on the command line (--folder); it then overrides the setting."""
        self.settings = load_settings()
        self.events = collections.deque(maxlen=EVENTS_KEEP)    # (time, text) for the diagnosis report (report.py)
        self.folder_forced = folder is not None
        self.folder = folder if folder is not None else self._pref_folder()
        self.clock = {'server': self.settings.get('ntp_server') or clock.DEFAULT_SERVER, 'last': None, 'auto': ''}
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
        self.last_transfer = None                        # statistics of the last firmware / bootloader transfer
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
        # extended link diagnosis (meter F-1.15 on): xdiag_on = the meter was told to count in this connection; the frame
        # F9 of the last counters request; xdiag = the result the report shows (xdiag_collect)
        self.xdiag_on = False
        self._xdiag_frame = None
        self._xdiag_evt = threading.Event()
        self._mclock_frame = None
        self._mclock_evt = threading.Event()
        self.xdiag = {'state': 'not read'}
        self._st_n, self._st_first, self._st_last = 0, None, None   # status frames of this connection (frames per second)
        self.card_st = {'files': [], 'listed': False, 'free_bytes': None, 'total_bytes': None, 'busy': False, 'op': '', 'progress': 0.0,
                        'sync': {'folder': self.settings.get('card_sync_folder'), 'last': None, 'copied': 0},
                        'error': None, 'result': '', 'job': 0, 'done_job': 0}
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
            self._st_n, self._st_first, self._st_last = self._st_n + 1, (t if self._st_first is None else self._st_first), t
            if self.desk:
                self.event('page Ld left (status frames again)')
            self._frame_t, self.desk = t, False          # status frames are sent only while page Ld is not shown
        elif kind == frames.VERSION:
            self._ver = frames.version_text(frame)
        elif kind == frames.BL_VERSION:
            self._blver = frames.bl_version_text(frame)
        elif kind == frames.XDIAG:
            self._xdiag_frame = frame
            self._xdiag_evt.set()
        elif kind == frames.MCLOCK:
            self._mclock_frame = frame
            self._mclock_evt.set()
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

    def event(self, text):
        """One line of the event log (the diagnosis report anonymises it)."""
        self.events.append((time.time(), text))

    def _state(self, state, detail):
        self.event('link %s%s' % (state, (': ' + detail) if detail else ''))
        self.desk = False                                # a new connection or none: the page is not known any more
        self._frame_t = 0.0
        self.xdiag_on = False                            # the counting is told again at each connection
        self._st_n, self._st_first, self._st_last = 0, None, None
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
            echo_only = 0                                # answers with the echo but without a version frame
            while self.link.state == 'connected' and self.mode == 'unknown':
                self._echo = self._ver = self._blver = None
                try:
                    self.link.send(frames.VERSION_REQUEST)
                except (RuntimeError, OSError, TimeoutError):
                    break
                end = time.time() + VERSION_WAIT
                while time.time() < end and self._ver is None:
                    time.sleep(0.05)
                self.event('version question: %s' % ('answer %s' % self._ver if self._ver is not None else
                                                     'echo only' if self._echo is not None else 'no answer'))
                if self._ver is not None:
                    self.fw_kind, self.version = 'fast', self._ver
                    self.bl = self._ask_bootloader()
                    self.mode = 'firmware'
                    self._xdiag_connect()
                    self._check_release()
                    self._clock_on_connect()
                elif self._echo is not None:
                    echo_only += 1
                    if echo_only < VERSION_TRIES:       # the version frame may have been lost (GitHub issue 9: F-1.12
                        continue                         # was shown as v2.05): ask again before deciding "v2.05"
                    self.fw_kind, self.mode = 'other', 'firmware'
                    self._clock_on_connect()
                else:
                    v = self._boot_probe()
                    self.event('update-mode probe: %s' % ('bootloader %d.%d.%d' % v if v is not None else 'no answer'))
                    if v is not None:
                        self.bl, self.mode = releases.bootloader_text(v), 'bootloader'
                        self._check_release()
                    else:
                        time.sleep(VERSION_RETRY)
            self._asked.clear()

    # ------------------------------------------------------------------ extended link diagnosis (meter F-1.15 on)
    def _xdiag_supported(self):
        """True when the connected meter runs the fast firmware F-1.15 or newer: only that firmware knows the key codes
        0x93 / 0x94 / 0x95 and STATUS 40..48.  Older firmware gets none of them."""
        v = releases.version_of_meter(self.version)
        return self.fw_kind == 'fast' and v is not None and v >= XDIAG_MIN_VERSION

    def _hunt_supported(self):
        """True when the connected meter runs F-1.16 or newer: only that firmware takes bit 4 of the setting id 0x020 (the
        capacitance anti-hunting, row HUnt); older firmware refuses the value."""
        v = releases.version_of_meter(self.version)
        return self.fw_kind == 'fast' and v is not None and v >= HUNT_MIN_VERSION

    def _xdiag_connect(self):
        """After the version and bootloader questions of a connection: switch the meter's counting on when the setting
        is on and the firmware knows it."""
        if not self.settings.get('ext_diag'):
            return
        if not self._xdiag_supported():
            self.event('extended diagnosis: not switched on, the meter has %s (F-1.15 or newer needed)' % (self.version or 'v2.05'))
            return
        self._xdiag_switch(True)

    def _xdiag_switch(self, on):
        """Send key code 0x93 (on, counters cleared) or 0x94 (off) and wait for its echo, up to XDIAG_TRIES times.
        Returns True when the meter echoed it.  Never sent to firmware older than F-1.15, and not while the page Ld owns
        the link (no key arrives there)."""
        what = 'extended diagnosis ' + ('on' if on else 'off')
        if not self._xdiag_supported():
            self.event('%s: not sent, the meter has %s' % (what, self.version or 'v2.05'))
            return False
        frame = frames.XDIAG_ON_REQUEST if on else frames.XDIAG_OFF_REQUEST
        try:
            with self._ops(what, need_desk=False, wait=LINK_WAIT):
                if self.desk:
                    raise RuntimeError('page Ld owns the link')
                for _ in range(XDIAG_TRIES):
                    self._key_echo = None
                    self.link.send(frame)
                    end = time.time() + XDIAG_WAIT
                    while time.time() < end and self._key_echo != frame:
                        time.sleep(0.02)
                    if self._key_echo == frame:
                        self.xdiag_on = on
                        self.event('%s: confirmed' % what)
                        return True
        except (RuntimeError, OSError, TimeoutError) as e:
            self.event('%s: not done (%s)' % (what, e))
            return False
        self.event('%s: no echo after %d tries' % (what, XDIAG_TRIES))
        return False

    def xdiag_collect(self):
        """The meter's nine counters for the report (setting ext_diag on, firmware F-1.15 or newer): on the page Ld the
        STATUS values 40..48, else the counters request 0x95 (up to XDIAG_TRIES tries of XDIAG_WAIT seconds each).
        The result is kept in self.xdiag: {'state': 'off' | 'unsupported' | 'values' | 'error', 'values', 'source',
        'counting', 'text'}."""
        res = {'state': 'off', 'text': 'off (SETTINGS: Extended diagnosis)'}
        if self.settings.get('ext_diag'):
            if self.link.state != 'connected':
                res = {'state': 'error', 'text': 'not connected to a meter'}
            elif not self._xdiag_supported():
                res = {'state': 'unsupported',
                       'text': 'not supported by this firmware (%s; F-1.15 or newer needed)' % (self.version or 'v2.05')}
            else:
                res = self._xdiag_read()
                if self._mclock_supported():
                    res['clock'] = self._mclock_read()
        self.xdiag = res
        return res

    def _leave_supported(self):
        """True when the meter (last version answer of this connection, F-1.17 or newer) takes the LEAVE request.  The
        version is asked before the page Ld is shown, so it is known while the page owns the link."""
        v = releases.version_of_meter(self.version)
        return self.fw_kind == 'fast' and v is not None and v >= LEAVE_MIN_VERSION

    def leave_ld(self):
        """Leave the page Ld from here (keys do not reach the meter while the page owns the link)."""
        if not self._leave_supported():
            raise RuntimeError('this firmware (%s) cannot be told to leave the page Ld: press SETUP on the meter '
                               '(F-1.17 or newer needed)' % (self.version or 'unknown'))
        with self._ops('leave page Ld', wait=LINK_WAIT) as (sender, _):
            sender.leave()
        self.event('page Ld left by the program (LEAVE request)')
        return {'ok': True}

    def _mclock_supported(self):
        """True when the connected meter runs F-1.17 or newer: only that firmware measures its clock (key code 0x96,
        frame FA, STATUS 49..55)."""
        v = releases.version_of_meter(self.version)
        return self.fw_kind == 'fast' and v is not None and v >= MCLOCK_MIN_VERSION

    def _mclock_read(self):
        """The meter's clock measurement for the report: on the page Ld the STATUS values 49..55, else the request
        0x96 (answered with FA whether or not the counting is on), up to XDIAG_TRIES tries of XDIAG_WAIT seconds.
        Returns the values (frames.mclock_values) with 'source', or {'text': why not}."""
        try:
            if self.desk:
                with self._ops('clock measurement', wait=LINK_WAIT) as (sender, _):
                    v = [sender.status_value(i) for i in range(MCLOCK_STATUS_FIRST, MCLOCK_STATUS_FIRST + MCLOCK_STATUS_COUNT)]
                c = frames.mclock_from_status(v)
                c['source'] = 'page Ld STATUS %d..%d' % (MCLOCK_STATUS_FIRST, MCLOCK_STATUS_FIRST + MCLOCK_STATUS_COUNT - 1)
                return c
            with self._ops('clock measurement', need_desk=False, wait=LINK_WAIT):
                if self.desk:
                    raise RuntimeError('page Ld owns the link')
                for _ in range(XDIAG_TRIES):
                    self._mclock_frame = None
                    self._mclock_evt.clear()
                    self.link.send(frames.MCLOCK_REQUEST)
                    if self._mclock_evt.wait(XDIAG_WAIT) and self._mclock_frame is not None:
                        c = frames.mclock_values(self._mclock_frame)
                        c['source'] = 'frame FA'
                        return c
            return {'text': 'no answer to the clock request after %d tries of %.0f s' % (XDIAG_TRIES, XDIAG_WAIT)}
        except (RuntimeError, OSError, TimeoutError, transfer.TransferError) as e:
            return {'text': 'not read: %s' % e}

    def _xdiag_read(self):
        counting = self.xdiag_on
        try:
            if self.desk:
                with self._ops('extended diagnosis', wait=LINK_WAIT) as (sender, _):
                    values = [sender.status_value(i) for i in range(XDIAG_STATUS_FIRST, XDIAG_STATUS_FIRST + XDIAG_STATUS_COUNT)]
                return {'state': 'values', 'values': values, 'source': 'page Ld STATUS %d..%d' % (
                    XDIAG_STATUS_FIRST, XDIAG_STATUS_FIRST + XDIAG_STATUS_COUNT - 1), 'counting': counting}
            with self._ops('extended diagnosis', need_desk=False, wait=LINK_WAIT):
                if self.desk:
                    raise RuntimeError('page Ld owns the link')
                for _ in range(XDIAG_TRIES):
                    self._xdiag_frame = None
                    self._xdiag_evt.clear()
                    self.link.send(frames.XDIAG_REQUEST)
                    if self._xdiag_evt.wait(XDIAG_WAIT) and self._xdiag_frame is not None:
                        return {'state': 'values', 'values': frames.xdiag_values(self._xdiag_frame), 'source': 'frame F9',
                                'counting': counting}
            return {'state': 'error', 'text': 'no answer to the counters request after %d tries of %.0f s (the meter counts '
                    'only after it was told to; or the link was not ready)' % (XDIAG_TRIES, XDIAG_WAIT)}
        except (RuntimeError, OSError, TimeoutError, transfer.TransferError) as e:
            return {'state': 'error', 'text': 'not read: %s' % e}

    def _xdiag_apply(self, on):
        """The setting was changed while connected: tell the meter (on: 0x93 clears and starts the counting; off: 0x94)."""
        if self.link.state != 'connected' or self.mode != 'firmware':
            return
        self._xdiag_switch(on)

    def _xdiag_note(self):
        """One line for the SETTINGS view under the setting."""
        if not self.settings.get('ext_diag'):
            return ''
        if self.link.state != 'connected' or self.mode == 'unknown':
            return 'starts when a meter is connected'
        if not self._xdiag_supported():
            return 'not supported by this firmware (%s): F-1.15 or newer needed' % (self.version or 'v2.05')
        return 'the meter is counting' if self.xdiag_on else 'switched on at the next connection (or when the link is free)'

    def _clock_on_connect(self):
        """Setting clock_on_connect: the meter's clock from the time server once per connection (the result or the
        reason it failed goes to clock.auto for the page)."""
        if not self.settings.get('clock_on_connect'):
            return
        try:
            r = self.sync_time(None)
            self.clock['auto'] = 'set on connect to ' + r['set_to']
        except (RuntimeError, ValueError, OSError, clock.ClockError) as e:
            self.clock['auto'] = 'not set on connect: %s' % e

    def _ask_bootloader(self, tries=BL_ASK_TRIES):
        """'EEV', 'B-A.BC', or None when the firmware does not answer key code 0x92 (older than F-1.03).  Asked up to
        `tries` times: one lost answer showed "B-—" for the whole connection, and an update then took the card route
        of EEVblog's bootloader on a meter that may have the two-part one (GitHub issue 10)."""
        for _ in range(tries):
            self._blver = None
            try:
                self.link.send(frames.BL_VERSION_REQUEST)
            except (RuntimeError, OSError, TimeoutError):
                return None
            end = time.time() + VERSION_WAIT
            while time.time() < end and self._blver is None:
                time.sleep(0.05)
            self.event('bootloader question: %s' % (self._blver or 'no answer'))
            if self._blver is not None:
                return self._blver
        return None

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
        policy = self.settings.get('update_check', 'connect')
        if policy == 'never':
            self.update.update(state='none', fw=None, bl=None, checked=None, latest=[],
                               check_error='update check off (SETTINGS)')
            return
        last = self.settings.get('release_checked_at')
        if policy == 'daily' and isinstance(last, (int, float)) and time.time() - last < DAILY:
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
        if not problems:
            self.settings['release_checked_at'] = time.time()
            save_settings(self.settings)

    # ------------------------------------------------------------------ updates
    def _run_update(self, what):
        """what: 'firmware', 'bootloader' or 'both'.  With EEVblog's bootloader the firmware goes first (the first
        install needs F-1.03 on the meter); with the two-part bootloader the bootloader goes first (DESIGN.md 5)."""
        u = self.update
        self.event('update %s started (firmware %s, bootloader %s)' % (what, u['fw'][0] if u['fw'] else '-',
                                                                       u['bl'][0] if u['bl'] else '-'))
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
            self.event('update done')
            if self.link.state == 'connected' and self.mode == 'firmware':
                self._xdiag_connect()                    # the reconnection after the update asked while the update still
                                                         # owned the link, so the switch was refused (GitHub issue 9)
        except (OSError, ValueError, RuntimeError, releases.ReleaseError, transfer.TransferError) as e:
            u.update(state='error', message=str(e))
            self.event('update stopped: %s' % e)
        finally:
            self._sender, self._cancel = None, False

    def _update_firmware(self):
        u = self.update
        if not u['fw']:
            return
        text, tag = u['fw']
        u.update(state='downloading', what='firmware', step=text, message='getting %s from the releases' % text)
        data = releases.image(tag)
        if self.bl is None and self.mode == 'firmware' and self.fw_kind == 'fast' and not self.desk:
            self.bl = self._ask_bootloader()             # not known yet: the route depends on it (issue 10)
        if self.mode == 'bootloader' or releases.version_of_bootloader(self.bl):
            self._enter_update_mode()
            self._boot_send(data, transfer.KIND_FIRMWARE, None, text)
            self._wait_restart(lambda: self.mode == 'firmware' and self.version == text,
                               'the meter did not come back with %s' % text, 'it starts %s' % text)
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
        self._wait_restart(lambda: self.bl == text, 'the meter did not report bootloader %s' % text,
                           'it starts bootloader %s' % text)
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
        try:
            self.link.send(frames.UPDATE_MODE_REQUEST)
        except Exception:                               # noqa: BLE001 - the meter restarts at once: the write's
            pass                                        # confirmation can be lost with the link (bleak: disconnected)
        self._wait_restart(lambda: self.mode == 'bootloader', 'the meter did not come back in its update mode',
                           'into its update mode')

    def _wait_restart(self, ready, failure, what, timeout=90.0):
        """The meter restarts (its Bluetooth module is switched off with it): wait for the link to drop, the link
        reconnects by itself, then for `ready()` after the version questions.  `what` says where it restarts to (the
        page shows "the meter restarts: <what>")."""
        self.update.update(state='restarting', message=what)
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
        sender, dropped0 = self._sender, self.link.rx_dropped
        th = threading.Thread(target=lambda: box.setdefault('r', self._guard(job)), daemon=True)
        th.start()
        while th.is_alive():
            u.update(done=sender.done)
            time.sleep(0.2)
        dropped = max(0, self.link.rx_dropped - dropped0)
        self.last_transfer = dict(sender.stats, what=text, rx_dropped=dropped, ok=not isinstance(box.get('r'), Exception),
                                  text=transfer.stats_text(sender.stats, dropped), at=time.time())
        self.event('transfer of %s: %s' % (text, self.last_transfer['text']))
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
                    was, self.desk = self.desk, sender.probe(DESK_PROBE_TIMEOUT)
                if self.desk and not was:
                    self.event('page Ld shown')
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
        """STATUS values of the file transfer with their readable text (diag.py); needs page Ld.  Values 0..20 every
        firmware with the transfer has; 21..25 (F-1.11 on) are read until the meter refuses one (older firmware)."""
        try:
            with self._ops('diagnosis', wait=LINK_WAIT) as (sender, _):
                values = [sender.status_value(i) for i in range(diag.BASE_COUNT)]
                for i in range(diag.BASE_COUNT, diag.COUNT):
                    try:
                        values.append(sender.status_value(i))
                    except transfer.TransferError:
                        break                           # a firmware before F-1.11: the values end here
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
                items = job(meter_settings.Settings(client, hunt=self._hunt_supported()))
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
            st['job'] += 1
            job_no = st['job']                           # the page waits for done_job to reach it (a short job can end
            st.update(busy=True, op=op, progress=0.0, error=None, result='')   # between two of its polls)

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
                self.event('card %s: %s' % (op, ('failed: ' + st['error']) if st['error'] else 'done'))
                st['busy'], st['op'] = False, ''
                st['done_job'] = job_no

        # the lock is taken by run() itself; busy is set above so no second operation starts between the two
        threading.Thread(target=run, name='card', daemon=True).start()
        return {'ok': True, 'job': job_no}

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
            self.card_st['listed'] = True                 # a listing has arrived (the page tells empty from unknown)
            return '%d files' % len(self.card_st['files'])
        return self._card_start('list', job)

    def card_info(self):
        def job(c, progress):
            self.card_st.update(c.info())
            return 'card information'
        return self._card_start('info', job)

    def card_refresh(self):
        """The file list and then the card's space in one job: two separate requests sent together would meet a
        running job, and the second one would be refused ("a card operation is running")."""
        def job(c, progress):
            self.card_st['files'] = c.list()
            self.card_st['listed'] = True                 # a listing has arrived (the page tells empty from unknown)
            self.card_st.update(c.info())
            return '%d files, card information' % len(self.card_st['files'])
        return self._card_start('list', job)

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
            self.card_st['listed'] = True
            return 'deleted %s' % name
        return self._card_start('delete', job, check)

    def card_format(self, confirm):
        """Format the meter's card (exFAT); `confirm` must be the word FORMAT the user typed."""
        def check():
            if confirm != 'FORMAT':
                raise ValueError('type FORMAT to confirm')

        def job(c, progress):
            c.format()
            self.card_st['files'] = c.list()
            self.card_st['listed'] = True                 # a listing has arrived (the page tells empty from unknown)
            self.card_st.update(c.info())
            return 'the card is formatted'
        return self._card_start('format', job, check)

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

    RECORDINGS_MAX = 50              # newest files listed on the LOG view
    RECORDINGS_EVERY = 2.0           # seconds between two looks at the folder (the page polls state() far more often)

    def recordings(self):
        """The CSV files in the recordings folder, newest first: [{'name', 'size' (bytes), 'date' 'YYYY-MM-DD', 'time'
        'HH:MM'}], at most RECORDINGS_MAX; [] while the folder does not exist.  Looked up at most every
        RECORDINGS_EVERY seconds."""
        now = time.time()
        cache = getattr(self, '_rec_cache', None)
        if cache and now - cache[0] < self.RECORDINGS_EVERY:
            return cache[1]
        out = []
        try:
            with os.scandir(self.folder) as it:
                for e in it:
                    if e.is_file() and e.name.lower().endswith('.csv'):
                        st = e.stat()
                        out.append((st.st_mtime, e.name, st.st_size))
        except OSError:
            out = []
        out.sort(reverse=True)
        lst = [{'name': n, 'size': s, 'date': time.strftime('%Y-%m-%d', time.localtime(m)),
                'time': time.strftime('%H:%M', time.localtime(m))} for m, n, s in out[:self.RECORDINGS_MAX]]
        self._rec_cache = (now, lst)
        return lst

    # ------------------------------------------------------------------ the program's settings (SETTINGS view)
    def _pref_folder(self):
        return self.settings.get('recordings_folder') or documents_folder()

    def prefs(self):
        """The settings as they apply now, plus what the page needs to explain them."""
        p = {k: self.settings.get(k, d) for k, d in PREF_DEFAULTS.items()}
        p['recordings_folder'] = self.folder
        p['card_sync_folder'] = self.card_st['sync']['folder'] or os.path.join(self.folder, 'card')
        p['ntp_server'] = self.clock['server']
        p.update(folder_forced=self.folder_forced, diag_log_active=TRACE_UI, file=config_path(),
                 ext_diag_note=self._xdiag_note())
        return p

    @staticmethod
    def _folder_value(v):
        if not isinstance(v, str) or not v.strip():
            raise ValueError('a folder is needed')
        return os.path.abspath(os.path.expanduser(v.strip()))

    def set_pref(self, key, value):
        """Change one setting: checked, applied at once (diag_log from the next start), stored."""
        if key not in PREF_DEFAULTS:
            raise ValueError('unknown setting %r' % (key,))
        if key == 'recordings_folder':
            if self.folder_forced:
                raise ValueError('the recordings folder was given on the command line (--folder)')
            if self.session.snapshot()['recording']:
                raise RuntimeError('a recording is running: stop it first')
            value = self._folder_value(value)
            self.folder, self._rec_cache = value, None
        elif key == 'card_sync_folder':
            value = self._folder_value(value)
            self.card_st['sync']['folder'] = value
        elif key == 'ntp_server':
            value = value.strip() if isinstance(value, str) else ''
            if not value or len(value) > 253 or any(ch.isspace() for ch in value):
                raise ValueError('a time server name or address is needed')
            self.clock['server'] = value
        elif key in ('clock_on_connect', 'diag_log', 'ext_diag'):
            if not isinstance(value, bool):
                raise ValueError('%s: true or false' % key)
        elif key == 'update_check':
            if value not in UPDATE_CHECKS:
                raise ValueError('update_check: one of %s' % ', '.join(UPDATE_CHECKS))
        elif key == 'csv_format':
            if value not in CSV_FORMATS:
                raise ValueError('csv_format: one of %s' % ', '.join(CSV_FORMATS))
        self.settings[key] = value
        save_settings(self.settings)
        if key == 'ext_diag' and self.link.state == 'connected' and self.mode == 'firmware':
            threading.Thread(target=self._xdiag_apply, args=(value,), name='xdiag', daemon=True).start()
        if key == 'update_check' and self.link.state == 'connected' and self.mode != 'unknown':
            if value == 'never' or self.update['state'] in ('none', 'available'):
                self.update.update(state='none', check_error='', checked=None)
                threading.Thread(target=self._check_release, name='releases-now', daemon=True).start()
        return {'ok': True, 'prefs': self.prefs()}

    def reset_prefs(self):
        """Every setting of the program back to its default (the meter's own settings are not touched)."""
        if self.session.snapshot()['recording']:
            raise RuntimeError('a recording is running: stop it first')
        for k in list(PREF_DEFAULTS) + ['derived', 'release_checked_at']:
            self.settings.pop(k, None)
        save_settings(self.settings)
        if not self.folder_forced:
            self.folder, self._rec_cache = self._pref_folder(), None
        self.card_st['sync']['folder'] = None
        self.clock['server'] = clock.DEFAULT_SERVER
        self.derived = derived.Derived()
        return {'ok': True, 'prefs': self.prefs()}

    def state(self, since=None):
        L = self.link
        return {'now': time.time(),
                'link': {'state': L.state, 'detail': L.detail, 'device': L.device, 'found': L.found,
                         'rx_bytes': L.rx_bytes, 'rx_dropped': L.rx_dropped},
                'meter': {'firmware': self.fw_kind, 'version': self.version, 'bootloader': self.bl, 'mode': self.mode,
                          'xdiag': self.xdiag_on},
                'update': dict(self.update),
                'last_transfer': self.last_transfer,
                'clock': self.clock,
                'session': self.session.snapshot(since),
                'folder': self.folder,
                'recordings': self.recordings(),
                'derived': self.derived.snapshot(),
                'desk': self.desk,
                'can_leave_ld': bool(self.desk and self._leave_supported()),
                'diag': dict(self.diag),
                'trace_ui': TRACE_UI,
                'card': dict(self.card_st, files=list(self.card_st['files']), locked_reason=self._lock_reason()),
                'settings': dict(self.settings_st, locked_reason=self._lock_reason()),
                'prefs': self.prefs()}

    def command(self, c):
        if 'ui_event' in c:                             # COMPANION_LOG=1: the page reports a pointer event (diagnosis)
            return {'ok': True}
        if 'connect' in c:
            self.link.connect(c['connect'])
            return {'ok': True}
        if 'disconnect' in c:
            self.link.disconnect()
            return {'ok': True}
        if 'record' in c:
            if c['record']:
                sep, dec = CSV_FORMATS.get(self.settings.get('csv_format'), CSV_FORMATS['comma'])
                return {'ok': True, 'path': self.session.start_recording(self.folder, sep, dec)}
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
        if 'leave_ld' in c:
            try:
                return self.leave_ld()
            except transfer.TransferError as e:
                raise RuntimeError(str(e)) from e
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
        if 'card_refresh' in c:
            return self.card_refresh()
        if 'card_download' in c:
            return self.card_download(self._arg(c, 'card_download', 'name'), self._arg(c, 'card_download', 'dest'))
        if 'card_delete' in c:
            return self.card_delete(self._arg(c, 'card_delete', 'name'))
        if 'card_format' in c:
            return self.card_format(self._arg(c, 'card_format', 'confirm'))
        if 'card_sync' in c:
            return self.card_sync(self._arg(c, 'card_sync', 'folder'))
        if 'settings_get' in c:
            return self.settings_get()
        if 'settings_put' in c:
            return self.settings_put(self._arg(c, 'settings_put', 'id'), self._arg(c, 'settings_put', 'value'))
        if 'diag_read' in c:
            return self.diag_read()
        if 'prefs_set' in c:
            return self.set_pref(self._arg(c, 'prefs_set', 'key'), self._arg(c, 'prefs_set', 'value'))
        if 'prefs_reset' in c:
            return self.reset_prefs()
        if 'save_report' in c:
            path = report.save(self, self.folder)
            return {'ok': True, 'path': path, 'name': os.path.basename(path)}
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


def _activate_mac(win):
    """Make the program the active application and its window the key window once the window is shown (macOS).

    A program that was not started from the Dock or the Finder (a terminal, a script) is not activated by macOS: its
    window stays inactive, and a click on an inactive window only activates it, so the first clicks on a button did
    nothing (2026-11-05: Connect needed up to four clicks; the update notice's button did not answer until the user had
    switched to another program and back; the cause of that one was the page, see index.html setText).  AppKit is called
    on the main thread (the shown event comes on another one)."""
    try:
        import AppKit
        app = AppKit.NSApplication.sharedApplication()

        def front():
            if hasattr(app, 'activate'):                 # macOS 14 and later
                app.activate()
            else:
                app.activateIgnoringOtherApps_(True)
            if getattr(win, 'native', None) is not None:
                win.native.makeKeyAndOrderFront_(None)
        AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(front)
    except Exception:
        pass                                            # not fatal: the window works, it is only not in front


def _trace_clicks():
    """COMPANION_LOG=1: every mouse press that reaches pywebview's web view (webview.platforms.cocoa
    BrowserView.WebKitHost) is written to the log with the window's key / main state and whether the program is
    active; the page reports its own pointer events (ui_event), so a lost click shows where it was lost (macOS)."""
    try:
        import AppKit
        from webview.platforms.cocoa import BrowserView
        down = BrowserView.WebKitHost.mouseDown_

        def mouseDown_(self, event):
            w = self.window()
            print('%.3f native mouseDown key=%s main=%s active=%s' % (
                time.time(), bool(w and w.isKeyWindow()), bool(w and w.isMainWindow()),
                bool(AppKit.NSApplication.sharedApplication().isActive())), file=sys.stderr, flush=True)
            return down(self, event)
        BrowserView.WebKitHost.mouseDown_ = mouseDown_
    except Exception:
        pass                                            # diagnosis only


def open_window(url):
    """Native window; False when none can be made (the browser is used then)."""
    if sys.platform.startswith('linux'):
        return False
    try:
        import webview
        win = webview.create_window(TITLE, url, width=1180, height=760, min_size=(860, 560), background_color='#0c0c0b')
        if sys.platform == 'darwin':
            if TRACE_UI:
                _trace_clicks()
            win.events.shown += lambda: _activate_mac(win)
        webview.start(gui='edgechromium' if sys.platform == 'win32' else None)
        return True
    except Exception:
        return False


def main(argv=None):
    ap = argparse.ArgumentParser(description=TITLE)
    ap.add_argument('--port', type=int, default=8221)
    ap.add_argument('--port-tries', type=int, default=20)
    ap.add_argument('--folder', default=None, help='folder for recordings (default: the SETTINGS view, else <Documents>/121GW)')
    ap.add_argument('--browser', action='store_true', help='use the default browser instead of a window')
    ap.add_argument('--no-open', action='store_true', help='open nothing (scripted use)')
    a = ap.parse_args(argv)
    app = Companion(a.folder)
    if app.settings.get('diag_log') is True:             # SETTINGS: diagnostic logging (as COMPANION_LOG=1)
        global TRACE_UI
        TRACE_UI = True
        server.LOG_COMMANDS = True
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
