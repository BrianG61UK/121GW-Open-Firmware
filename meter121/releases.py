"""The fast firmware's releases on GitHub: the latest version, and its image downloaded and checked.

Releases of the fast firmware are tagged vA.B.C and carry firmware-<tag>.zip with 2_fast/EEVBlog.bin and the zip's
SHA-256 in firmware-<tag>.zip.sha256.  The meter shows the version as F-A.BC (the firmware's config.inc and
.github/scripts/check_fw_version.py on main), so "F-1.01" is release v1.0.1.  Downloaded images are kept in the user's
cache folder so a second update of another meter needs no download.  Standard library only.
"""
import hashlib
import io
import json
import os
import re
import struct
import urllib.request
import zipfile

from . import paths

REPO = 'zombu4/121GW-Open-Firmware'
API = 'https://api.github.com/repos/%s/releases?per_page=100' % REPO
ASSET = 'https://github.com/%s/releases/download/%s/%s'
TAG = re.compile(r'v(\d)\.(\d)\.(\d)')
TIMEOUT = 20


class ReleaseError(Exception):
    pass


def cache_dir():
    return paths.cache_dir()


def version_of_meter(text):
    """(A, B, C) from the meter's 'F-A.BC', or None."""
    m = re.fullmatch(r'F-(\d)\.(\d)(\d)', text or '')
    return tuple(int(x) for x in m.groups()) if m else None


def meter_text(v):
    return 'F-%d.%d%d' % v


def _get(url):
    req = urllib.request.Request(url, headers={'User-Agent': '121GW-Companion', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read()


def latest():
    """(version tuple, tag) of the newest published fast release."""
    rel = json.loads(_get(API))
    found = [(tuple(int(x) for x in TAG.fullmatch(r['tag_name']).groups()), r['tag_name']) for r in rel
             if not r.get('draft') and not r.get('prerelease') and TAG.fullmatch(r['tag_name'])]
    if not found:
        raise ReleaseError('no fast firmware release found on github.com/%s' % REPO)
    return max(found)


def check_image(data):
    """The checks the meter makes before it accepts a file (firmware ble/bft.s bft_finish): None or the reason."""
    if not 0x124 <= len(data) <= 0x5A000:
        return 'size %d outside 292 .. 368640 bytes' % len(data)
    sp, reset = struct.unpack_from('<II', data, 0)
    if not 0x20000001 <= sp <= 0x20014000:
        return 'initial stack pointer 0x%08X is not in the RAM' % sp
    if not (reset & 1) or not 0x08006000 <= reset < 0x08060000:
        return 'reset vector 0x%08X is not a Thumb address in 0x08006000 .. 0x0805FFFF' % reset
    return None


def image(tag):
    """The fast build's EEVBlog.bin of release `tag` (bytes), from the cache or downloaded and checked."""
    path = os.path.join(cache_dir(), tag, 'EEVBlog.bin')
    if os.path.isfile(path):
        data = open(path, 'rb').read()
        if check_image(data) is None:
            return data
    zname = 'firmware-%s.zip' % tag
    blob = _get(ASSET % (REPO, tag, zname))
    want = _get(ASSET % (REPO, tag, zname + '.sha256')).decode('ascii', 'replace').split()[0].lower()
    got = hashlib.sha256(blob).hexdigest()
    if got != want:
        raise ReleaseError('%s: SHA-256 %s does not match the published %s' % (zname, got, want))
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        if '2_fast/EEVBlog.bin' not in z.namelist():
            raise ReleaseError('%s has no 2_fast/EEVBlog.bin' % zname)
        data = z.read('2_fast/EEVBlog.bin')
    bad = check_image(data)
    if bad:
        raise ReleaseError('%s: not a 121GW application image: %s' % (zname, bad))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + '.part', 'wb') as f:
        f.write(data)
    os.replace(path + '.part', path)
    return data
