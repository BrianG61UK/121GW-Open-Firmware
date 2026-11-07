"""The text of one release page: the introduction (what the release is and its assets) and only the paragraphs of this
version from the changelog, then a link to the whole changelog (GitHub issue 29: every release page used to carry the
history of every version).

    python3 -I .github/scripts/release_notes.py HEADER CHANGELOG LABEL URL OUT

HEADER     the introduction (.github/release-notes.md)
CHANGELOG  every version's paragraphs, newest first, separated by blank lines (CHANGELOG.md)
LABEL      the version as the paragraphs name it ("v1.2.3", "1.2.26", "bl-v1.1.4"): the paragraphs that start with
           "New in LABEL" or "Fixed in LABEL" (followed by a space, a colon or a parenthesis) are taken
URL        the address of the whole changelog, linked at the end
OUT        the file written
Exits with 1 when the changelog has no paragraph for LABEL: a release is never published without its notes.
"""
import re
import sys


def paragraphs(text):
    return [p.strip() for p in re.split(r'\n\s*\n', text) if p.strip()]


def notes(header, changelog, label, url):
    pat = re.compile(r'^(New|Fixed) in %s(?=[ :(])' % re.escape(label))
    own = [p for p in paragraphs(changelog) if pat.match(p)]
    if not own:
        return None
    return '%s\n\n%s\n\nEarlier versions: [the whole changelog](%s).\n' % (header.strip(), '\n\n'.join(own), url)


def main(argv):
    if len(argv) != 5:
        sys.exit(__doc__)
    header_path, changelog_path, label, url, out = argv
    text = notes(open(header_path, encoding='utf-8').read(), open(changelog_path, encoding='utf-8').read(), label, url)
    if text is None:
        print('release_notes: no paragraph "New in %s" or "Fixed in %s" in %s' % (label, label, changelog_path))
        return 1
    with open(out, 'w', encoding='utf-8') as f:
        f.write(text)
    print('release_notes: %s, %d bytes' % (out, len(text.encode('utf-8'))))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
