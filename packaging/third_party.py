"""Write THIRD_PARTY_LICENSES.txt: the licence texts of the Python packages the build bundles and of Python itself.

    python -I packaging/third_party.py OUT.txt

The packages are those the program imports on this system (bleak and its backend dependencies, pywebview and its
platform dependencies) found with importlib.metadata in the build environment; their licence files come from their
installed metadata, Python's from sys.base_prefix.  A package that ships no licence file but declares exactly "MIT" in its
metadata (several PyObjC framework wrappers and proxy_tools do) gets the standard MIT licence text with the author its
metadata names, marked as such.  Any other package without a licence file stops the build with its name, so nothing is
shipped without its notice.
"""
import importlib.metadata as md
import os
import re
import sys

ROOTS = ['bleak', 'pywebview']


def requirements(name, seen):
    key = re.sub(r'[-_.]+', '-', name).lower()
    if key in seen:
        return
    try:
        dist = md.distribution(name)
    except md.PackageNotFoundError:
        return                                  # a dependency for another platform (marker not met)
    seen[key] = dist
    for req in dist.requires or []:
        if 'extra ==' in req:
            continue
        marker_ok = True
        if ';' in req:
            from packaging.markers import Marker  # packaging is a dependency of PyInstaller, present in the build
            marker_ok = Marker(req.split(';', 1)[1]).evaluate()
        if marker_ok:
            requirements(re.split(r'[ <>=!~;\[(]', req.strip(), maxsplit=1)[0], seen)


def licence_text(dist):
    files = [f for f in (dist.files or []) if re.search(r'(LICEN[CS]E|COPYING|NOTICE)', f.name, re.I)]
    texts = []
    for f in files:
        p = f.locate()
        if os.path.isfile(p):
            texts.append(open(p, encoding='utf-8', errors='replace').read().strip())
    return '\n\n'.join(texts)


MIT = '''Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.'''


def declared_mit(dist):
    """Standard MIT text for a package whose metadata declares exactly MIT and ships no licence file, else ''."""
    m = dist.metadata
    lic = (m.get('License-Expression') or m.get('License') or '').strip()
    if lic != 'MIT':
        return ''
    author = m.get('Author') or m.get('Author-email') or m.get('Maintainer') or 'the authors named in the package'
    return ('(The package ships no licence file; its metadata declares the MIT licence. Standard MIT text:)\n\n'
            'Copyright (c) %s\n\n%s' % (author, MIT))


def python_licence():
    for p in (os.path.join(sys.base_prefix, 'LICENSE.txt'), os.path.join(sys.base_prefix, 'LICENSE'),
              os.path.join(sys.base_prefix, 'lib', 'python%d.%d' % sys.version_info[:2], 'LICENSE.txt')):
        if os.path.isfile(p):
            return open(p, encoding='utf-8', errors='replace').read().strip()
    raise SystemExit('third_party: Python licence file not found under %s' % sys.base_prefix)


def main(argv):
    out = argv[0]
    seen = {}
    for r in ROOTS:
        requirements(r, seen)
    parts = ['Third-party software bundled with the 121GW Companion', '',
             '=' * 78, 'Python %s (Python Software Foundation License)' % sys.version.split()[0], '=' * 78, python_licence()]
    missing = []
    for key in sorted(seen):
        dist = seen[key]
        text = licence_text(dist) or declared_mit(dist)
        if not text:
            missing.append(dist.metadata['Name'])
            continue
        lic = dist.metadata.get('License-Expression') or dist.metadata.get('License') or ''
        parts += ['', '=' * 78, '%s %s%s' % (dist.metadata['Name'], dist.version, (' (%s)' % lic.splitlines()[0]) if lic else ''),
                  '=' * 78, text]
    if missing:
        raise SystemExit('third_party: no licence file in the metadata of: %s' % ', '.join(missing))
    with open(out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(parts) + '\n')
    print('third_party: %d packages + Python -> %s' % (len(seen), out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
