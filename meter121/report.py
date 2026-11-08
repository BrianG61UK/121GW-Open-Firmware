"""The diagnosis report (METER view, "Save report"): one text file with what the companion knows about the meter and
the link, to attach to a GitHub issue instead of a screenshot.

Contents: the companion's version and the system; the meter (firmware, bootloader, mode, page Ld); the link (state,
bytes received, bytes skipped as damaged); the link details (the last damaged pieces as hex, the notifications, the writes
with response, the advertisement signal strength, the MTU, the disconnects, the status frame rate, and with the setting
"Extended diagnosis" on and firmware F-1.15 or newer the meter's own counters); the update state; the statistics of the last transfer; the diagnosis values
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

from . import card, frames

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


def anonymise(text, names=None, keep=None):
    """The report without addresses, IDs, paths, computer or user names.  `keep` (default: the Linux distribution's
    name) is left as it is although a computer may be named like it ("ubuntu"): it names no one."""
    text = PATH_RE.sub('<path>', text)
    text = UUID_RE.sub('<id>', text)
    text = MAC_RE.sub('<address>', text)
    keep = linux_distribution()[:-2] if keep is None else keep
    parts = text.split(keep) if keep else [text]
    for n in (names if names is not None else _names()):
        parts = [re.sub(r'(?<![A-Za-z0-9])' + re.escape(n) + r'(?![A-Za-z0-9])', '<name>', t, flags=re.IGNORECASE)
                 for t in parts]
    return keep.join(parts) if keep else parts[0]


def system_text():
    if sys.platform == 'darwin':
        return 'macOS %s (%s)' % (platform.mac_ver()[0] or '?', platform.machine())
    if sys.platform == 'win32':
        return 'Windows %s (%s)' % (platform.version(), platform.machine())
    return '%s%s %s (%s)' % (linux_distribution(), platform.system(), platform.release(), platform.machine())


def linux_distribution():
    """'<PRETTY_NAME>, ' from /etc/os-release (platform.freedesktop_os_release, Python 3.10 on), or '' when the file or
    the function is missing: the kernel version alone does not tell the distribution (GitHub issue 21)."""
    try:
        name = platform.freedesktop_os_release().get('PRETTY_NAME', '')
    except (AttributeError, OSError):
        return ''
    return name + ', ' if name else ''


def _ms(seconds):
    return '-' if seconds is None else '%.0f ms' % (seconds * 1000)


def link_details(app):
    """The lines of the section [link details]: what the companion measured on the link, and the meter's own counters
    (app.xdiag, read by app.xdiag_collect() when the report is saved).  Hex dumps use spaces between the bytes, so
    anonymise() does not take them for addresses."""
    out = []
    w = out.append
    L = app.link
    st = L.stats.snapshot()
    pieces = L.damaged()
    w('damaged pieces   %s' % ('none (no byte was skipped)' if not pieces else
                               'the last %d runs of skipped bytes, oldest first (length: first %d bytes)' % (
                                   len(pieces), frames.DAMAGED_BYTES)))
    for n, data in pieces:
        w('  %3d bytes: %s%s' % (n, frames.hex_spaced(data), ' ...' if n > len(data) else ''))
    sz = st['sizes']
    w('notifications    %d; sizes 1..20: %d, 21..64: %d, 65..244: %d%s; gap median %s, 95 %% %s, max %s' % (
        st['notifications'], sz[0], sz[1], sz[2], ', larger: %d' % sz[3] if sz[3] else '',
        _ms(st['gap_median']), _ms(st['gap_p95']), _ms(st['gap_max'])))
    w('writes (with response)  %d; confirmed after median %s, max %s%s' % (
        st['writes'], _ms(st['write_median']), _ms(st['write_max']),
        '; %d failed' % st['write_errors'] if st['write_errors'] else ''))
    if st['rssi']:
        sig = '; '.join('connection %d: %s' % (n, '%d dBm' % r if r is not None else 'not given') for n, r in st['rssi'])
    else:
        sig = 'not seen'
    w('advertisement signal  %s' % sig)
    w('MTU              %s' % ('%d bytes (bleak client mtu_size)' % st['mtu'] if st['mtu'] is not None else
                               'not available from the Bluetooth backend'))
    w('careful mode     %s' % ('on: every status frame twice (the link test), small card answers (old BLE112 module, MTU 23)'
                               if getattr(app, 'careful_on', False) else
                               'on: small card answers, readings once (old BLE112 module, MTU 23)' if app.careful_wanted() else
                               'off (MTU %s; careful mode is for the old BLE112 module and firmware F-1.19 or newer)'
                               % (st['mtu'] if st['mtu'] is not None else 'unknown')))
    ar = getattr(app, 'arate', None) or {}
    if ar.get('code') is not None:
        from .app import RATE_PER_S
        w('reading rate     %d a second, set by the companion for this link (automatic, F-1.25; at most %d)' % (
            RATE_PER_S[ar['code']], RATE_PER_S[ar['ceiling']]))
    hint = app.link_hint()
    if hint:
        w('link note        ' + hint)
    cs = card.LAST_CAREFUL
    if cs.get('pieces') or cs.get('again'):
        w('careful pieces   last card read: %d pieces, %d sent again; pieces by size: %s' % (
            cs['pieces'], cs['again'], ', '.join('%d bytes %d' % (k, cs['sizes'][k]) for k in sorted(cs['sizes']))))
    w('disconnects      %d%s' % (st['disconnect_count'], ':' if st['disconnect_count'] else ''))
    for t, user, why in st['disconnects']:
        w('  %s  %s' % (time.strftime('%H:%M:%S', time.localtime(t)), why))
    n, a, b = app._st_n, app._st_first, app._st_last
    bt = next((it.get('text') for it in ((app.settings_st or {}).get('items') or []) if it.get('code') == 'bt'), None)
    if n >= 2 and b > a:
        w('status frames    %.2f per second measured (%d frames in %.1f s of this connection); meter setting bt: %s' % (
            (n - 1) / (b - a), n, b - a, bt or 'not read (SETTINGS of the meter)'))
    else:
        w('status frames    not measured yet (%d in this connection); meter setting bt: %s' % (n, bt or 'not read'))
    lt = getattr(app, 'ltest', None) or {'state': 'none'}
    if lt.get('results'):
        w('link test        careful mode\'s doubled status frames on against off (%s)%s' % (
            lt['state'], ': ' + lt['error'] if lt.get('error') else ''))
        for r in lt['results']:
            w('  doubled %-3s  %5.1f s  %7d bytes  %6d damaged (%4.1f %%)  %4d readings (%.2f/s)' % (
                'on' if r['doubled'] else 'off', r['seconds'], r['bytes'], r['damaged'],
                100.0 * r['damaged'] / r['bytes'] if r['bytes'] else 0.0, r['readings'],
                r['readings'] / r['seconds'] if r['seconds'] else 0.0))
        if lt.get('summary'):
            w('  ' + lt['summary'])
    x = getattr(app, 'xdiag', None) or {'state': 'not read'}
    if x['state'] == 'values':
        w('meter counters   %s; %s' % (x['source'], 'the meter was told to count (key code 0x93) after this connection began'
                                          if x.get('counting') else 'the counting was not started in this connection: the '
                                          'values are from the last start of counting in the meter (or 0)'))
        for name, v in zip(frames.XDIAG_NAMES, x['values']):
            w('  %-44s %d%s' % (name, v, ' (= %.2f V)' % (v / 100.0) if name.startswith('battery') else
                                 ' (65535 = the counter is full)' if v == 0xFFFF else ''))
    else:
        w('meter counters   %s' % (x.get('text') or 'not read'))
    c = x.get('clock')
    if c is not None:
        if 'status' in c:
            w('meter clock      %s; the RC clock measured against the crystal at the last power-on or wake' % c['source'])
            for line in frames.mclock_lines(c):
                w(line)
        else:
            w('meter clock      %s' % c.get('text', 'not read'))
    return out


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
    w('[link details]')
    out.extend(link_details(app))
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
    for k in ('update_check', 'clock_on_connect', 'csv_format', 'theme', 'diag_log', 'ext_diag'):
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
    if read_diag:
        app.xdiag_collect()                             # the meter's own counters (setting "Extended diagnosis")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, time.strftime('121GW-report-%Y-%m-%d_%H-%M-%S.txt'))
    with open(path, 'w', encoding='utf-8') as f:
        f.write(build(app))
    return path
