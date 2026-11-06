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
"""
import hashlib
import io
import json
import os
import re
import struct
import ssl
import urllib.request
import zipfile

from . import paths

REPO = 'zombu4/121GW-Open-Firmware'
API = 'https://api.github.com/repos/%s/releases?per_page=100' % REPO
ASSET = 'https://github.com/%s/releases/download/%s/%s'
TAG = re.compile(r'v(\d)\.(\d)\.(\d)')
BL_TAG = re.compile(r'bl-v(\d)\.(\d)\.(\d)')
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


def _latest(pattern, what):
    rel = json.loads(_get(API))
    found = [(tuple(int(x) for x in pattern.fullmatch(r['tag_name']).groups()), r['tag_name']) for r in rel
             if not r.get('draft') and not r.get('prerelease') and pattern.fullmatch(r['tag_name'])]
    if not found:
        raise ReleaseError('no %s release found on github.com/%s' % (what, REPO))
    return max(found)


def latest():
    """(version tuple, tag) of the newest published fast release."""
    return _latest(TAG, 'fast firmware')


def latest_bootloader():
    """(version tuple, tag) of the newest published bootloader release."""
    return _latest(BL_TAG, 'bootloader')


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
