"""Releases on GitHub of the fast firmware and of the two-part bootloader: the latest version, the files downloaded
and checked.

Releases of the fast firmware are tagged vA.B.C and carry firmware-<tag>.zip with 2_fast/EEVBlog.bin and the zip's
SHA-256 in firmware-<tag>.zip.sha256.  The meter shows the version as F-A.BC (the firmware's config.inc and
.github/scripts/check_fw_version.py on main), so "F-1.01" is release v1.0.1.  Downloaded images are kept in the user's
cache folder so a second update of another meter needs no download.  Standard library only.

Releases of the bootloader (branch bootloader) are tagged bl-vA.B.C and carry bootloader-<tag>.zip with install.bin
(starter and bootloader, for the first install through the firmware) and blimage.bin (the bootloader image, for an
update through the bootloader), and the zip's SHA-256 in bootloader-<tag>.zip.sha256.  The meter reports the version as
B-A.BC (firmware ble/blcmd.s, key code 0x92); its bootloader header carries A << 16 | B << 8 | C.

Releases of this program are tagged companion-vA.B.C (any number of digits); they carry the installers, no images.
list_releases() sorts all published releases into the three kinds, newest first, for the chooser of the METER view (any
version, also an older one) and for the notice about a newer program.
"""
import hashlib
import io
import json
import os
import re
import struct
import ssl
import time
import urllib.request
import zipfile

from . import paths

REPO = 'zombu4/121GW-Open-Firmware'
API = 'https://api.github.com/repos/%s/releases?per_page=100' % REPO
ASSET = 'https://github.com/%s/releases/download/%s/%s'
TAG = re.compile(r'v(\d)\.(\d)\.(\d)')
BL_TAG = re.compile(r'bl-v(\d)\.(\d)\.(\d)')
COMPANION_TAG = re.compile(r'companion-v(\d+)\.(\d+)\.(\d+)')
PAGE_URL = 'https://github.com/%s/releases/tag/%s'
TIMEOUT = 20
PER_PAGE, MAX_PAGES = 100, 5                    # the release list is fetched page by page, at most 500 releases
CACHE_SECONDS = 30.0                            # the lists of firmware, bootloader and program come from one fetch
BL_BASE, BL_MAX, BL_STACK_TOP = 0x08000400, 0x5B00, 0x2000C000     # bootloader/src/bl.inc, bl_main.s vector table
BL_VECTORS = 73                                 # words of the two-part bootloader's vector table (bl_main.s)


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
    req = urllib.request.Request(url, headers={'User-Agent': '121GW-Companion', 'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=_ssl_context()) as r:
        return r.read()


_cache = {'at': 0.0, 'data': None}


def _fetch():
    """The releases of the project as the API lists them (newest first), a few pages if need be; kept for
    CACHE_SECONDS so that the three questions of one release check cost one fetch."""
    if _cache['data'] is not None and time.monotonic() - _cache['at'] < CACHE_SECONDS:
        return _cache['data']
    out = []
    for page in range(1, MAX_PAGES + 1):
        part = json.loads(_get(API + '&page=%d' % page))
        if not isinstance(part, list):
            raise ReleaseError('the release list is not a list')
        out.extend(part)
        if len(part) < PER_PAGE:
            break
    _cache.update(at=time.monotonic(), data=out)
    return out


def forget():
    """Drop the kept release list (the next question fetches again)."""
    _cache.update(at=0.0, data=None)


def companion_text(v):
    return '%d.%d.%d' % v


def parse_releases(rel):
    """Sort the API's release list into {'firmware': [...], 'bootloader': [...], 'companion': [...]}, each newest
    first.  An entry is {'version': (A, B, C), 'tag': tag, 'text': 'F-A.BC' / 'B-A.BC' / 'A.B.C', 'published': 'YYYY-MM-DD'
    or ''}.  Drafts and pre-releases are left out, as are tags of no kind (like205-v1.0.0, ...)."""
    kinds = (('firmware', TAG, meter_text), ('bootloader', BL_TAG, bootloader_text), ('companion', COMPANION_TAG, companion_text))
    out = {k: [] for k, _, _ in kinds}
    for r in rel:
        if not isinstance(r, dict) or r.get('draft') or r.get('prerelease'):
            continue
        tag = r.get('tag_name')
        if not isinstance(tag, str):
            continue
        for kind, pattern, text in kinds:
            m = pattern.fullmatch(tag)
            if m:
                v = tuple(int(x) for x in m.groups())
                out[kind].append({'version': v, 'tag': tag, 'text': text(v), 'published': str(r.get('published_at') or '')[:10]})
                break
    for lst in out.values():
        lst.sort(key=lambda e: e['version'], reverse=True)
    return out


def list_releases():
    """All published releases by kind, newest first (parse_releases of the GitHub list)."""
    return parse_releases(_fetch())


def _latest(kind, what):
    found = list_releases()[kind]
    if not found:
        raise ReleaseError('no %s release found on github.com/%s' % (what, REPO))
    return found[0]['version'], found[0]['tag']


def latest():
    """(version tuple, tag) of the newest published fast release."""
    return _latest('firmware', 'fast firmware')


def latest_bootloader():
    """(version tuple, tag) of the newest published bootloader release."""
    return _latest('bootloader', 'bootloader')


def latest_companion():
    """(version tuple, tag) of the newest published release of this program."""
    return _latest('companion', 'companion')


def version_of_companion(text):
    """(A, B, C) from the program's own version text ('1.2.24'), or None ('source', 'dev', 'unknown')."""
    m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', text or '')
    return tuple(int(x) for x in m.groups()) if m else None


def page_url(tag):
    """The release page of `tag` on GitHub."""
    return PAGE_URL % (REPO, tag)


def version_of_bootloader(text):
    """(A, B, C) from the meter's 'B-A.BC', or None ('EEV' = EEVblog's bootloader)."""
    m = re.fullmatch(r'B-(\d)\.(\d)(\d)', text or '')
    return tuple(int(x) for x in m.groups()) if m else None


def bootloader_text(v):
    return 'B-%d.%d%d' % v


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


def check_bootloader_image(data):
    """The checks of a bootloader image (blimage.bin; loaded at 0x08000400) for an update through the two-part bootloader:
    None or the reason.  The bootloader itself checks only length and CRC-32 of this kind (bootloader/src/bl_ble.s
    bl_end_check), so a wrong file would be installed and started by the starter.  What identifies the two-part
    bootloader is its vector table (bl_main.s): 73 words, the stack top 0x2000C000, every other word a Thumb address
    inside the image; EEVblog's bootloaders are 24576 bytes (DESIGN.md 1) against the 23296 bytes at most (BL_MAX)."""
    if not 4 * BL_VECTORS <= len(data) <= BL_MAX:
        return 'size %d outside %d .. %d bytes (the vector table alone is %d)' % (len(data), 4 * BL_VECTORS, BL_MAX, 4 * BL_VECTORS)
    words = struct.unpack_from('<%dI' % BL_VECTORS, data)
    if words[0] != BL_STACK_TOP:
        return 'initial stack pointer 0x%08X is not the two-part bootloader\'s 0x%08X' % (words[0], BL_STACK_TOP)
    for i, w in enumerate(words[1:], 1):
        if not w & 1 or not BL_BASE <= w < BL_BASE + len(data):
            return 'vector %d (0x%08X) is not a Thumb address inside the image placed at 0x%08X' % (i, w, BL_BASE)
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


def _zip_checked(tag, zname):
    blob = _get(ASSET % (REPO, tag, zname))
    want = _get(ASSET % (REPO, tag, zname + '.sha256')).decode('ascii', 'replace').split()[0].lower()
    got = hashlib.sha256(blob).hexdigest()
    if got != want:
        raise ReleaseError('%s: SHA-256 %s does not match the published %s' % (zname, got, want))
    return zipfile.ZipFile(io.BytesIO(blob))


def check_install(data):
    """The checks the firmware makes before a first install (ble/bft.s bft_install): None or the reason."""
    if not 0x580 <= len(data) <= 0x6000 or len(data) % 128:
        return 'install file of %d bytes: 0x580 .. 0x6000 in whole half-pages expected' % len(data)
    sp, reset = struct.unpack_from('<II', data, 0)
    if not 0x20000001 <= sp <= 0x2000C000 or not reset & 1 or not 0x08000000 <= reset < 0x08000400:
        return 'the starter part has no valid vector table'
    if struct.unpack_from('<I', data, 0x400)[0] != 0x32484C42:
        return 'no bootloader header after the starter'
    return None


def bootloader_files(tag):
    """(install.bin, blimage.bin) of bootloader release `tag`, from the cache or downloaded and checked."""
    folder = os.path.join(cache_dir(), tag)
    paths_ = [os.path.join(folder, n) for n in ('install.bin', 'blimage.bin')]
    if all(os.path.isfile(p) for p in paths_):
        inst, boot = (open(p, 'rb').read() for p in paths_)
        if check_install(inst) is None and boot:
            return inst, boot
    zname = 'bootloader-%s.zip' % tag
    with _zip_checked(tag, zname) as z:
        names = z.namelist()
        if 'install.bin' not in names or 'blimage.bin' not in names:
            raise ReleaseError('%s lacks install.bin or blimage.bin' % zname)
        inst, boot = z.read('install.bin'), z.read('blimage.bin')
    bad = check_install(inst)
    if bad:
        raise ReleaseError('%s: %s' % (zname, bad))
    if inst[0x500:0x500 + len(boot)] != boot:
        raise ReleaseError('%s: install.bin and blimage.bin hold different bootloaders' % zname)
    os.makedirs(folder, exist_ok=True)
    for p, d in zip(paths_, (inst, boot)):
        with open(p + '.part', 'wb') as f:
            f.write(d)
        os.replace(p + '.part', p)
    return inst, boot
