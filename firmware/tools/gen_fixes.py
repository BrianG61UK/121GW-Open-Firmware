#!/usr/bin/env python3
"""gen_fixes.py - write FIXES.md, the list of v2.05 defects fixed by a firmware release, from the issues document.

    python3 -I firmware/tools/gen_fixes.py [firmware/ORIGINAL_FIRMWARE_ISSUES.md] > FIXES.md
    python3 -I firmware/tools/gen_fixes.py ISSUES.md OUT.md

Input: the summary table of firmware/ORIGINAL_FIRMWARE_ISSUES.md, rows `| ID | Area | Issue | Severity | Status |`, with the
status words defined at the top of that file:
    fixed                 fixed in both builds, `1_like_v2.05` and `2_fast`
    fixed (fast build)    fixed only in the production build `2_fast`
    kept ...              left as v2.05 on purpose
    open, approval, by design   documented and not changed
Sections of the output:
    Fixed in both builds       status "fixed", except the latent defects below
    Fixed only in the fast build   status "fixed (fast build)"
    Latent defects (never reachable on the meter)   LATENT below, plus every row whose status says "latent"; the column
                               "New firmware" is the status
    Documented, not changed    every other row (open, approval, by design, kept): listed with its status, never dropped
A status that is none of the above words is an error (exit status 1), so a new status cannot vanish from the file.
The latent set is a list here because the issues document's status column does not mark OF-49 and OF-50 (fixed although
no defined input reaches them): their detail sections say "Impact: none".
"""
import re
import sys

sys.dont_write_bytecode = True
LATENT = ('OF-49', 'OF-50', 'OF-51')
LATENT_NOTE = {'OF-51': 'run-time library edge cases'}     # wording for a kept latent item; default: its area
KNOWN = ('fixed', 'fixed (fast build)', 'open', 'approval', 'by design')
ROW = re.compile(r'^\| (OF-\d+) \| (.*?) \| (.*) \| (low|medium|high) \| (.*?) \|$')


def rows(text):
    """[(id, area, issue, severity, status)] of the summary table (the part before '## Details')."""
    out = []
    for line in text.split('## Details')[0].splitlines():
        m = ROW.match(line)
        if m:
            out.append(m.groups())
    if not out:
        raise SystemExit('gen_fixes: no issue rows found')
    ids = [r[0] for r in out]
    if len(set(ids)) != len(ids):
        raise SystemExit('gen_fixes: duplicate issue id in the summary table')
    return out


def render(rs):
    latent = [r for r in rs if r[0] in LATENT or 'latent' in r[4]]
    rest = [r for r in rs if r not in latent]
    both = [r for r in rest if r[4] == 'fixed']
    fast = [r for r in rest if r[4] == 'fixed (fast build)']
    other = [r for r in rest if r[4] not in ('fixed', 'fixed (fast build)')]
    for r in latent:
        if not (r[4] in KNOWN or r[4].startswith('kept')):
            raise SystemExit('gen_fixes: unknown status %r of %s' % (r[4], r[0]))
    for r in other:
        if r[4] not in KNOWN and not r[4].startswith('kept'):
            raise SystemExit('gen_fixes: unknown status %r of %s' % (r[4], r[0]))
    out = ['# Defects of firmware v2.05 fixed in the new firmware', '',
           'Evidence for every item (addresses, execution checks): `firmware/ORIGINAL_FIRMWARE_ISSUES.md` in the repository.', '',
           '## Fixed in both builds (`1_like_v2.05` and `2_fast`): %d' % len(both), '',
           '| ID | Severity | Area | v2.05 defect |', '|---|---|---|---|']
    out += ['| %s | %s | %s | %s |' % (i, sev, area, issue) for i, area, issue, sev, st in both]
    if fast:
        out += ['', '## Fixed only in the fast build (`2_fast`): %d' % len(fast), '',
                "`1_like_v2.05` keeps v2.05's main-loop and mode-entry display behaviour here.", '',
                '| ID | Severity | Area | v2.05 defect |', '|---|---|---|---|']
        out += ['| %s | %s | %s | %s |' % (i, sev, area, issue) for i, area, issue, sev, st in fast]
    if latent:
        fixed_l = [r[0] for r in latent if r[4] == 'fixed']
        kept_l = [r for r in latent if r[4] != 'fixed']
        words = 'Mistakes in code paths that v2.05 never takes.'
        if fixed_l:
            words += ' %s %s fixed anyway;' % (' and '.join(fixed_l) if len(fixed_l) < 3 else ', '.join(fixed_l),
                                                'are' if len(fixed_l) > 1 else 'is')
        if kept_l:
            words += ' %s is kept identical to v2.05 so that every calculation the meter does stays bit-identical.' % \
                     ', '.join('%s (%s)' % (r[0], LATENT_NOTE.get(r[0], r[1].lower())) for r in kept_l)
        else:
            words = words.rstrip(';') + '.'
        out += ['', '## Latent defects (never reachable on the meter)', '', words, '',
                '| ID | Area | v2.05 defect | New firmware |', '|---|---|---|---|']
        out += ['| %s | %s | %s | %s |' % (i, area, issue, 'kept' if st.startswith('kept') else st) for i, area, issue, sev, st in latent]
    if other:
        out += ['', '## Documented, not changed in this release', '',
                '| ID | Severity | Area | v2.05 defect | Status |', '|---|---|---|---|---|']
        out += ['| %s | %s | %s | %s | %s |' % (i, sev, area, issue, st) for i, area, issue, sev, st in other]
    return '\n'.join(out) + '\n'


def main(argv):
    src = argv[0] if argv else 'firmware/ORIGINAL_FIRMWARE_ISSUES.md'
    with open(src) as f:
        text = render(rows(f.read()))
    if len(argv) > 1:
        with open(argv[1], 'w') as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
