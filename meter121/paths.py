"""Folders of the user running the program: home, settings, cache, documents.

On macOS and Linux the home folder comes from the account database (pwd) of the user the program runs as, not from the
HOME variable, which a launcher can pass on from another user (for example sudo -u without -H); on Windows from the
user-profile variables Windows sets for every program.
"""
import os
import sys


def home():
    if sys.platform != 'win32':
        import pwd
        return pwd.getpwuid(os.getuid()).pw_dir
    return os.environ.get('USERPROFILE') or os.path.expanduser('~')


def config_dir():
    if sys.platform == 'darwin':
        return os.path.join(home(), 'Library', 'Application Support', '121GW-Companion')
    if sys.platform == 'win32':
        return os.path.join(os.environ.get('APPDATA') or os.path.join(home(), 'AppData', 'Roaming'), '121GW-Companion')
    return os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.join(home(), '.config'), '121GW-Companion')


def cache_dir():
    if sys.platform == 'darwin':
        return os.path.join(home(), 'Library', 'Caches', '121GW-Companion')
    if sys.platform == 'win32':
        return os.path.join(os.environ.get('LOCALAPPDATA') or os.path.join(home(), 'AppData', 'Local'), '121GW-Companion')
    return os.path.join(os.environ.get('XDG_CACHE_HOME') or os.path.join(home(), '.cache'), '121GW-Companion')


def documents_dir():
    docs = os.path.join(home(), 'Documents')
    return os.path.join(docs if os.path.isdir(docs) else home(), '121GW')
