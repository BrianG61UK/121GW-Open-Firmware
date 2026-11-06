"""Firmware builds fetched on demand from the project's GitHub releases, kept in a per-user cache.

The emulator ships without firmware.  When a build is selected (fetch(name)), the latest release of that build is looked
up, its firmware-<tag>.zip downloaded, checked against the release's firmware-<tag>.zip.sha256 and the image taken out of
it into the cache; later starts take the cached image of the latest release without downloading again.  Offline, the
newest cached image of the build is used; with none, FirmwareUnavailable says why (the page then offers "Load firmware
file...").

    build name       release tags      image in the zip           label
    2_fast           vA.B.C            2_fast/EEVBlog.bin          fast (branch main)
    1_like_v2.05     like205-vA.B.C    1_like_v2.05/EEVBlog.bin    like v2.05 (branch like-v2.05)

Cache directory: the environment variable EEV121GW_CACHE, else ~/Library/Caches/121GW-Emulator (macOS),
%LOCALAPPDATA%\\121GW-Emulator (Windows), $XDG_CACHE_HOME/121GW-Emulator or ~/.cache/121GW-Emulator (other); layout
<cache>/<tag>/<build name>/EEVBlog.bin.  Standard library only (urllib, zipfile, hashlib).
"""
import hashlib
import io
import json
import os
import re
import sys
import ssl
import urllib.request
import zipfile

REPO = 'zombu4/121GW-Open-Firmware'
API = 'https://api.github.com/repos/%s/releases?per_page=100' % REPO
ASSET = 'https://github.com/%s/releases/download/%s/%s'
BUILDS = {
    '2_fast': (re.compile(r'v(\d+)\.(\d+)\.(\d+)'), 'fast'),
    '1_like_v2.05': (re.compile(r'like205-v(\d+)\.(\d+)\.(\d+)'), 'like v2.05'),
}
DEFAULT_BUILD = '2_fast'
TIMEOUT = 15                                   # seconds per HTTP request


class FirmwareUnavailable(Exception):
    """The build could not be downloaded and no cached copy exists."""


def cache_dir():
    if os.environ.get('EEV121GW_CACHE'):
        return os.environ['EEV121GW_CACHE']
    if sys.platform == 'darwin':
        base = os.path.expanduser('~/Library/Caches')
    elif sys.platform == 'win32':
        base = os.environ.get('LOCALAPPDATA') or os.path.expanduser('~\\AppData\\Local')
    else:
        base = os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache')
    return os.path.join(base, '121GW-Emulator')


def _version(name, tag):
    """(A, B, C) of a release tag of build `name`, or None when the tag belongs to another build."""
    m = BUILDS[name][0].fullmatch(tag)
    return tuple(int(x) for x in m.groups()) if m else None


def _ssl_context():
    """TLS context for the downloads from GitHub: the system's certificates plus certifi's CA list.  The packaged
    macOS program carries the python.org Python, which does not use the macOS keychain: without a CA file of its own
    every download failed with "certificate verify failed: unable to get the local issuer certificate" (GitHub
    issue 13)."""
    ctx = ssl.create_default_context()
    try:
        import certifi
        ctx.load_verify_locations(cafile=certifi.where())
    except (ImportError, OSError):
        pass                                            # the system's certificates alone
    return ctx


def _get(url):
    req = urllib.request.Request(url, headers={'User-Agent': '121GW-Emulator', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=_ssl_context()) as r:
        return r.read()


def latest_tag(name):
    """Tag of the newest published release of build `name` (highest version; drafts and pre-releases are skipped)."""
    releases = json.loads(_get(API))
    tags = [r['tag_name'] for r in releases
            if not r.get('draft') and not r.get('prerelease') and _version(name, r['tag_name'])]
    if not tags:
        raise FirmwareUnavailable('no release of the %s build found on github.com/%s' % (BUILDS[name][1], REPO))
    return max(tags, key=lambda t: _version(name, t))


def cached(name):
    """[(tag, path)] of the cached images of build `name`, newest first."""
    out = []
    root = cache_dir()
    if os.path.isdir(root):
        for tag in os.listdir(root):
            p = os.path.join(root, tag, name, 'EEVBlog.bin')
            if _version(name, tag) and os.path.isfile(p):
                out.append((tag, p))
    return sorted(out, key=lambda tp: _version(name, tp[0]), reverse=True)


def download(name, tag, check=None):
    """Download firmware-<tag>.zip, check its SHA-256 against firmware-<tag>.zip.sha256 and store the image of build
    `name` in the cache.  check(data) -> list of problems (the emulator's application image test).  Returns the path."""
    zname = 'firmware-%s.zip' % tag
    data = _get(ASSET % (REPO, tag, zname))
    want = _get(ASSET % (REPO, tag, zname + '.sha256')).decode('ascii', 'replace').split()[0].lower()
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        raise FirmwareUnavailable('%s: SHA-256 %s does not match the published %s' % (zname, got, want))
    member = '%s/EEVBlog.bin' % name
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        if member not in z.namelist():
            raise FirmwareUnavailable('%s has no %s' % (zname, member))
        image = z.read(member)
    problems = check(image) if check else []
    if problems:
        raise FirmwareUnavailable('%s in %s is not a 121GW application image: %s' % (member, zname, '; '.join(problems)))
    path = os.path.join(cache_dir(), tag, name, 'EEVBlog.bin')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.part'
    with open(tmp, 'wb') as f:
        f.write(image)
    os.replace(tmp, path)
    return path


def fetch(name, check=None):
    """(path, tag, note) of build `name`: the latest release's image (cached, or downloaded now); offline the newest
    cached image with a note saying so.  Raises FirmwareUnavailable when neither is possible."""
    if name not in BUILDS:
        raise FirmwareUnavailable('unknown firmware build %r; builds: %s' % (name, ', '.join(BUILDS)))
    try:
        tag = latest_tag(name)
        path = os.path.join(cache_dir(), tag, name, 'EEVBlog.bin')
        if not os.path.isfile(path):
            path = download(name, tag, check)
        return path, tag, None
    except (OSError, ValueError, zipfile.BadZipFile, FirmwareUnavailable) as e:   # urllib errors are OSError
        have = cached(name)
        if have:
            tag, path = have[0]
            return path, tag, 'could not reach GitHub (%s): using the cached %s' % (e, tag)
        raise FirmwareUnavailable('the %s build could not be downloaded (%s) and none is cached; use "Load firmware '
                                  'file..." or start with --app FILE' % (BUILDS[name][1], e)) from e
