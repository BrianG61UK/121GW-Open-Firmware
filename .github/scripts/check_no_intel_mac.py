#!/usr/bin/env python3
"""check_no_intel_mac.py - refuse any Intel (x86_64) macOS emulator build or download.

    python3 -I .github/scripts/check_no_intel_mac.py [REPO_ROOT]          default: the repository of this script
    python3 -I .github/scripts/check_no_intel_mac.py --dist PATH...       also: no Intel macOS package among these files

The emulator is published for macOS on Apple chips only (macos-arm64.dmg); the owner removed the Intel macOS build
(2026-11-01, again 2026-11-03 after it had been re-added by mistake).  Fails (exit status 1) when a text file of the
repository (outside .git) names an Intel macOS runner (macos-NN-intel, macos-13 or older) or an Intel macOS package
(macos-x86_64, x86_64.dmg, a "Mac with Intel" download row), or when a given package file is an Intel macOS package.
Saying that there is no Intel version ("no Intel Mac version", "no version for Macs with an Intel processor") is allowed.
Run by both workflows before anything is built.
"""
import os
import re
import sys

PATTERNS = [
    (re.compile(r'macos-\d+-intel'), 'Intel macOS runner'),
    (re.compile(r'\bmacos-(?:1[0-3]|[0-9])\b(?!\.)'), 'Intel-only macOS runner (macos-13 or older)'),
    (re.compile(r'macos-x86_64'), 'Intel macOS package name'),
    (re.compile(r'x86_64\.dmg'), 'Intel macOS package name'),
    (re.compile(r'Mac with Intel', re.I), 'Intel Mac download row'),
    (re.compile(r'arch:\s*x86_64'), 'x86_64 entry in a build matrix'),
]
SKIP_DIRS = {'.git', 'node_modules', '__pycache__', 'build', 'dist'}
TEXT_EXT = {'.yml', '.yaml', '.md', '.py', '.sh', '.svg', '.txt', '.json', '.iss', '.spec', '.html', '.js', '.css', '.toml',
            '.cfg', '.ini', ''}
SELF = os.path.abspath(__file__)


def scan_repo(root):
    bad = []
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in files:
            p = os.path.join(d, f)
            if os.path.abspath(p) == SELF or os.path.splitext(f)[1].lower() not in TEXT_EXT:
                continue
            try:
                text = open(p, encoding='utf-8').read()
            except (UnicodeDecodeError, OSError):
                continue
            for n, line in enumerate(text.splitlines(), 1):
                for rx, what in PATTERNS:
                    if rx.search(line):
                        bad.append('%s:%d: %s: %s' % (os.path.relpath(p, root), n, what, line.strip()[:160]))
    return bad


def scan_dist(paths):
    bad = []
    for top in paths:
        for d, _, files in (os.walk(top) if os.path.isdir(top) else [(os.path.dirname(top), [], [os.path.basename(top)])]):
            for f in files:
                if re.search(r'macos-x86_64|x86_64\.dmg', f):
                    bad.append('%s: Intel macOS package' % os.path.join(d, f))
    return bad


def main(argv):
    if argv[:1] == ['--dist']:
        bad = scan_dist(argv[1:])
    else:
        root = argv[0] if argv else os.path.normpath(os.path.join(os.path.dirname(SELF), '..', '..'))
        bad = scan_repo(root)
    for b in bad:
        print('check_no_intel_mac: ' + b)
    if bad:
        print('check_no_intel_mac: FAILED - there is no Intel macOS emulator build (owner decision); remove the lines above')
        return 1
    print('check_no_intel_mac: no Intel macOS build or package')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
