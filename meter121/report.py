"""The diagnosis report (METER view, "Save report"): one text file with what the companion knows about the meter and
the link, to attach to a GitHub issue instead of a screenshot.

Contents: the companion's version and the system; the meter (firmware, bootloader, mode, page Ld); the link (state,
bytes received, bytes skipped as damaged); the update state; the statistics of the last transfer; the diagnosis values
of the firmware with their text; the meter's SETUP settings as last read; the companion's own settings (no token, no
paths); the event log (connections, version and bootloader questions, page Ld, updates, card operations, errors).
Anonymised (anonymise() runs over the whole text at the end, whatever a field held): no Bluetooth device ID (a
per-computer UUID on macOS, the meter's address elsewhere), no MAC address, no UUID, no computer name, no user name, no
file path (paths become <path>; the recordings folder is only "default" or "custom").
"""
import getpass
import os
import platform
import re
import socket
import sys
import time

MAC_RE = re.compile(r'\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b')
UUID_RE = re.compile(r'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b')
# a path: drive letter or ~ or / followed by path characters up to a space or the end (Windows and POSIX)
PATH_RE = re.compile(r'(?:[A-Za-z]:\\|~[/\\]|/(?:Users|home|var|private|tmp|Volumes|media|mnt|root)\b)[^\s,;]*')

HERE = os.path.dirname(os.path.abspath(__file__))


def app_version():
    """The companion's version: written into the packaged program by packaging/companion.spec (app_version.txt);
    'source' when it runs from the source tree."""
    base = getattr(sys, '_MEIPASS', None)
    if base:
        try:
            with open(os.path.join(base, 'app_version.txt'), encoding='utf-8') as f:
                return f.read().strip() or 'unknown'
        except OSError:
            return 'unknown'
    return 'source'


def _names():
    """Names of this computer and user that must not appear in the report (empty strings dropped)."""
    out = set()
    for get in (socket.gethostname, lambda: socket.gethostname().split('.')[0], getpass.getuser,
                lambda: os.path.basename(os.path.expanduser('~'))):
        try:
            v = get()
        except Exception:                               # noqa: BLE001 - a name that cannot be read cannot leak either
            continue
        if v and len(v) >= 3:
            out.add(v)
    try:
        from . import paths
        h = os.path.basename(paths.home())
        if len(h) >= 3:
            out.add(h)
    except Exception:                                   # noqa: BLE001
        pass
    return sorted(out, key=len, reverse=True)


def anonymise(text, names=None):
    """The report without addresses, IDs, paths, computer or user names."""
    text = PATH_RE.sub('<path>', text)
    text = UUID_RE.sub('<id>', text)
    text = MAC_RE.sub('<address>', text)
    for n in (names if names is not None else _names()):
        text = re.sub(r'(?<![A-Za-z0-9])' + re.escape(n) + r'(?![A-Za-z0-9])', '<name>', text, flags=re.IGNORECASE)
    return text


def system_text():
    if sys.platform == 'darwin':
        return 'macOS %s (%s)' % (platform.mac_ver()[0] or '?', platform.machine())
    if sys.platform == 'win32':
        return 'Windows %s (%s)' % (platform.version(), platform.machine())
    return '%s %s (%s)' % (platform.system(), platform.release(), platform.machine())


def build(app, now=None):
    """The report as text."""
    now = time.time() if now is None else now
    st = app.state()
    L, M, U = st['link'], st['meter'], st['update']
    out = []
    w = out.append
    w('121GW Companion diagnosis report')
    w('written     %s' % time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(now)))          # no time zone: no hint of a place
    w('companion   %s' % app_version())
    w('system      %s, Python %s' % (system_text(), platform.python_version()))
    w('')
    w('[meter]')
    w('firmware    %s (%s)' % (M['version'] or '-', M['firmware']))
    w('bootloader  %s' % (M['bootloader'] or 'not known'))
    w('mode        %s%s' % (M['mode'], ', page Ld shown' if st['desk'] else ''))
    w('')
    w('[link]')
    w('state       %s %s' % (L['state'], L.get('detail') or ''))
    w('name        %s' % ((L.get('device') or [None, '-'])[1] if L.get('device') else '-'))
    w('received    %s bytes, %s skipped as damaged' % (L.get('rx_bytes'), L.get('rx_dropped')))
    w('')
    w('[update]')
    w('state       %s%s' % (U.get('state'), (' - ' + U['message']) if U.get('message') else ''))
    w('checked     %s; newest %s%s' % (time.strftime('%H:%M', time.localtime(U['checked'])) if U.get('checked') else '-',
                                       ', '.join(U.get('latest') or []) or '-',
                                       ('; ' + U['check_error']) if U.get('check_error') else ''))
    X = st.get('last_transfer')
    w('last transfer  %s' % ('%s%s: %s' % ('' if X['ok'] else 'stopped, ', X['what'], X['text']) if X else '-'))
    w('')
    w('[diagnosis of the firmware]')
    d = st.get('diag') or {}
    if d.get('values'):
        w('values      %s' % ' '.join('%d:%d' % (i, v) for i, v in enumerate(d['values'])))
        w(d.get('text') or '')
    else:
        w('not read (the meter must show page Ld; the report reads it when it can)')
    w('')
    w('[meter settings, as last read]')
    items = (st.get('settings') or {}).get('items') or []
    if items:
        for it in items:
            w('%-6s %-32s %s' % (it.get('code', ''), it.get('name', ''), it.get('text', it.get('value'))))
    else:
        w('not read')
    w('')
    w('[companion settings]')
    p = st.get('prefs') or {}
    for k in ('update_check', 'clock_on_connect', 'csv_format', 'diag_log'):
        w('%-17s %s' % (k, p.get(k)))
    w('recordings folder %s' % ('custom' if app.settings.get('recordings_folder') or app.folder_forced else 'default'))
    w('')
    w('[events, oldest first]')
    for t, text in list(app.events):
        w('%s.%03d  %s' % (time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t)), int((t % 1) * 1000), text))
    if not app.events:
        w('none')
    return anonymise('\n'.join(out) + '\n')


def save(app, folder, read_diag=True):
    """Write the report into `folder` (the recordings folder); the diagnosis is read first when the meter allows it.
    Returns the file path."""
    if read_diag and app.desk:
        try:
            app.diag_read()
        except (RuntimeError, ValueError, OSError):
            pass                                        # the report is written with what is known
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, time.strftime('121GW-report-%Y-%m-%d_%H-%M-%S.txt'))
    with open(path, 'w', encoding='utf-8') as f:
        f.write(build(app))
    return path
