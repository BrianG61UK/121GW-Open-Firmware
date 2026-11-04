"""Generate the NVM allowed-byte tables from firmware/EEPROM_MAP.md (EMAP 9.2; DESIGN.md 6.21, 9.3 item 3).

    python -I firmware/tools/gen_nvm_allow.py           write firmware/src/nvm/nvm_allow.s and firmware/src/inc/nvm_allow.inc
    python -I firmware/tools/gen_nvm_allow.py --check   regenerate in memory, compare with both files (build check)
    python -I firmware/tools/gen_nvm_allow.py --list    print the allowed offsets of every class as ranges

Sources read and cross-checked (any mismatch stops the tool with exit status 1 and writes nothing):
  EMAP header         range count per mode "1,4,4,2,..."   == RAM 0x20000000..0x20000018 of ram_init.txt
  EMAP 5.1            record base table T (26 entries)      == u16 LE table at 0x08028EE8 in the original image
  EMAP 5.3            records listed per mode               == records computed from T and the range counts
  EMAP 9.2            the explicit offsets of each class row (SETTINGS, IDENT, USERZERO, CAL, RESTORE)
  EMAP 4              the list of bytes no v2.05 routine except calbin_save/calbin_load accesses: none of them
                      may be in SETTINGS, IDENT, USERZERO or CAL, except the port-only settings of EMAP 4.1
  EMAP 4.1            the port-only settings (bytes from that list that the production port reads and writes as
                      settings, owner-approved one by one): each must be in the never-accessed list, in the SETTINGS
                      row of 9.2 and in no other class but RESTORE (the like-v2.05 build on its branch does not
                      allow them)
Rules computed for CAL (EMAP 9.2 row CAL, 5.3, 3 ac_words_base 0x080115CC):
  R+0..R+7 of every (mode, range) record of 5.3 (R = T[mode] + 16*range; mode 6 contributes only 0x104..0x107;
  mode 0 contributes 0x060 and 0x0A0; mode 10 contributes 0x120), R+8..R+0xF of the AC-word records
  (ac_words_base(mode, sub) = T[mode] + 8 + 16*sub, sub forced to 1 for modes 16 and 18; modes 2, 4, 20 use every
  range), R+8..R+0xF of the VA records (modes 13, 14, 15, 22, 23, 24, 4 ranges), plus the explicit offsets of the row.
Global invariants asserted: nothing at 0x4FD and above, nothing in 0x4B0..0x4CF, nothing at the user-zero slot bytes
+5..+7, 0x012 only in RESTORE.

Table format (nvm_allow.s): one bitmap of 0x500 bits (160 bytes) per class, class order SETTINGS, IDENT, USERZERO, CAL,
RESTORE; bit (off & 7) of byte (class * 160 + (off >> 3)) is 1 when the class may write offset off.
The port-only settings' SETTINGS bits are emitted as "v2.05 bits | port-only bits", so the part of the table that v2.05
itself allows stays visible next to the bytes the port adds.
"""
import os
import re
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v205  # noqa: E402

OUT_S = os.path.join(v205.ROOT, 'firmware', 'src', 'nvm', 'nvm_allow.s')
OUT_INC = os.path.join(v205.ROOT, 'firmware', 'src', 'inc', 'nvm_allow.inc')
RAM_INIT = os.path.join(v205.ROOT, 'analysis', 'decompile', 'ram_init.txt')
CLASSES = ['SETTINGS', 'IDENT', 'USERZERO', 'CAL', 'RESTORE']
LIMIT = 0x500
STRIDE = LIMIT // 8
VA_MODES = (13, 14, 15, 22, 23, 24)


class Fail(Exception):
    pass


def hex_ranges(text):
    """Set of offsets from tokens 0xAAA..0xBBB and 0xAAA in text."""
    out = set()
    for m in re.finditer(r'0x([0-9A-Fa-f]{3})(?:\.\.0x([0-9A-Fa-f]{3}))?', text):
        a = int(m.group(1), 16)
        b = int(m.group(2), 16) if m.group(2) else a
        out.update(range(a, b + 1))
    return out


def ram_init_bytes(addr, n):
    vals = {}
    for line in open(RAM_INIT):
        if line.startswith(';') or not line.strip():
            continue
        p = line.split()
        base = int(p[0], 16)
        for i, h in enumerate(p[1:17]):
            if re.fullmatch(r'[0-9a-f]{2}', h):
                vals[base + i] = int(h, 16)
    return [vals[addr + i] for i in range(n)]


def port_only(emap):
    """Offsets of the port-only settings: the rows of the table in EMAP 4.1 (first cell = offset or range, last cell =
    class, which must be SETTINGS)."""
    if '### 4.1 ' not in emap:
        return set()
    sec = emap[emap.index('### 4.1 '):]
    sec = sec[:sec.index('\n## ')] if '\n## ' in sec else sec
    out = set()
    for line in sec.splitlines():
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cells) >= 2 and re.fullmatch(r'0x[0-9A-Fa-f]{3}(\.\.0x[0-9A-Fa-f]{3})?', cells[0]):
            if cells[-1] != 'SETTINGS':
                raise Fail('EMAP 4.1: class of %s is %r, not SETTINGS' % (cells[0], cells[-1]))
            out |= hex_ranges(cells[0])
    return out


def build():
    emap = open(v205.EEPROM_MAP).read()
    # range counts
    m = re.search(r'\(`analysis/decompile/ram_init.txt`\):\s*([\d,]+)\.', emap)
    if not m:
        raise Fail('EMAP: range count line not found')
    rc = [int(x) for x in m.group(1).split(',')]
    if rc != ram_init_bytes(0x20000000, 25):
        raise Fail('EMAP range counts differ from ram_init.txt: %r' % rc)
    # T table
    tvals = []
    for line in emap.splitlines():
        if line.startswith('| T |'):
            tvals += [int(x, 16) for x in re.findall(r'0x([0-9A-Fa-f]{3})', line)]
    img = v205.image()
    timg = [int.from_bytes(v205.image_bytes(img, 0x08028EE8 + 2 * i, 2), 'little') for i in range(26)]
    if tvals != timg:
        raise Fail('EMAP 5.1 T differs from the image table 0x08028EE8: %r / %r' % (tvals, timg))
    T = timg
    # records per mode computed
    rec = {}
    for mode in range(25):
        if mode == 0:
            rec[0] = [T[2] + 0x30, T[1] + 0x30]           # 0x060 (LowZ AC), 0x0A0 (LowZ DC), EMAP 5.2 item 6
        elif mode == 6:
            rec[6] = []                                    # frequency reference word only, EMAP 5.3
        elif mode == 10:
            rec[10] = [T[9] + 0x10]                        # 0x120, EMAP 5.2 item 8
        else:
            rec[mode] = [T[mode] + 16 * r for r in range(rc[mode])]
    # cross-check with EMAP 5.3 "Records" column
    sec53 = emap[emap.index('### 5.3'):emap.index('### 5.4')]
    seen = set()
    for line in sec53.splitlines():
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        mm = re.match(r'^([\d, ]+) [A-Za-z]', cells[0]) if len(cells) >= 2 else None
        if not mm:
            continue
        modes = [int(x) for x in re.findall(r'\d+', mm.group(1))]
        reccell = cells[1].split(';')[0]                   # text after ';' names AC-word slots, not records
        listed = set(int(x, 16) for x in re.findall(r'0x([0-9A-Fa-f]{3})', reccell))
        for mode in modes:
            if mode in VA_MODES:
                continue                                   # VA row gives the range 0x300..0x47F, checked below
            if mode == 6:
                if listed != {0x104, 0x107} or '0x104..0x107' not in reccell:
                    raise Fail('EMAP 5.3 mode 6 lists %r' % sorted(listed))
                continue
            # the Records column lists record bases; a span 0xAAA..0xBBB stands for every 16th offset
            span = re.search(r'0x([0-9A-Fa-f]{3})\.\.0x([0-9A-Fa-f]{3})', reccell)
            if span:
                got = set(range(int(span.group(1), 16), int(span.group(2), 16) + 1, 16))
            else:
                got = listed
            if got != set(rec[mode]):
                raise Fail('EMAP 5.3 mode %d records %r, computed %r' % (mode, sorted(got), sorted(rec[mode])))
            seen.add(mode)
    if seen != set(range(25)) - set(VA_MODES) - {6}:
        raise Fail('EMAP 5.3: rows missing for modes %r' % sorted(set(range(25)) - set(VA_MODES) - {6} - seen))
    va = set()
    for mode in VA_MODES:
        for r in range(rc[mode]):
            va.update(range(T[mode] + 16 * r, T[mode] + 16 * r + 16))
    if va != set(range(0x300, 0x480)):
        raise Fail('VA records do not cover exactly 0x300..0x47F')
    # AC-word slots (ac_words_base 0x080115CC)
    acw = set()
    for mode in (2, 4, 16, 18, 20):
        subs = [1] if mode in (16, 18) else range(rc[mode])
        for sub in subs:
            b = T[mode] + 8 + 16 * sub
            acw.update(range(b, b + 8))
    # class rows of EMAP 9.2
    sec92 = emap[emap.index('### 9.2'):emap.index('### 9.3')]
    rows = {}
    for line in sec92.splitlines():
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cells) >= 3 and cells[0] in CLASSES:
            rows[cells[0]] = cells[1]
    if set(rows) != set(CLASSES):
        raise Fail('EMAP 9.2: class rows found %r' % sorted(rows))
    allow = {c: set() for c in CLASSES}
    allow['SETTINGS'] = hex_ranges(rows['SETTINGS'])
    allow['IDENT'] = hex_ranges(rows['IDENT'])
    allow['USERZERO'] = hex_ranges(rows['USERZERO'])
    for phrase in ('R+0..R+7 of every (mode, range) record of section 5.3', 'R+8..R+0xF of the AC-word records',
                   'of the VA records'):
        if phrase not in rows['CAL']:
            raise Fail('EMAP 9.2 CAL row no longer contains "%s"' % phrase)
    cal = hex_ranges(rows['CAL'])
    for mode, bases in rec.items():
        for b in bases:
            cal.update(range(b, b + 8))
    cal.update(acw)
    cal.update(va)
    allow['CAL'] = cal
    if 'and the USERZERO bytes' not in rows['RESTORE']:
        raise Fail('EMAP 9.2 RESTORE row no longer names the USERZERO bytes')
    allow['RESTORE'] = hex_ranges(rows['RESTORE']) | allow['USERZERO']
    # invariants
    head = 'other than calbin_save / calbin_load reads or writes:'
    sec4 = emap[emap.index(head) + len(head):emap.index('The supplied 1200-byte')]
    never = hex_ranges(sec4)
    port = port_only(emap)
    if not port <= never:
        raise Fail('EMAP 4.1 lists bytes that are not in the never-accessed list of EMAP 4: %s' % fmt(port - never))
    if not port <= allow['SETTINGS']:
        raise Fail('EMAP 4.1 lists bytes that the SETTINGS row of EMAP 9.2 does not allow: %s' % fmt(port - allow['SETTINGS']))
    for c in ('IDENT', 'USERZERO', 'CAL'):
        if port & allow[c]:
            raise Fail('port-only setting also in class %s: %s' % (c, fmt(port & allow[c])))
    for c in ('SETTINGS', 'IDENT', 'USERZERO', 'CAL'):
        bad = allow[c] & never
        if c == 'SETTINGS':
            bad -= port                                    # the port-only settings are the declared exception
        if bad:
            raise Fail('class %s allows bytes listed as never accessed: %s' % (c, fmt(bad)))
    forbidden = set(range(0x4B0, 0x4D0)) | set(range(0x4FD, LIMIT))
    for b in range(0x4D0, 0x500, 8):
        forbidden.update(range(b + 5, b + 8))
    for c in CLASSES:
        if allow[c] & forbidden:
            raise Fail('class %s allows forbidden bytes %s' % (c, fmt(allow[c] & forbidden)))
        if any(x >= LIMIT or x < 0 for x in allow[c]):
            raise Fail('class %s outside 0x000..0x4FF' % c)
    for c in CLASSES:
        if c != 'RESTORE' and 0x012 in allow[c]:
            raise Fail('0x012 in class %s' % c)
    if allow['USERZERO'] != set(x for b in range(0x4D0, 0x500, 8) for x in range(b, b + 5)):
        raise Fail('USERZERO is not exactly bytes +0..+4 of the six slots')
    return allow, port


def fmt(s):
    s = sorted(s)
    out = []
    i = 0
    while i < len(s):
        j = i
        while j + 1 < len(s) and s[j + 1] == s[j] + 1:
            j += 1
        out.append('0x%03X' % s[i] if i == j else '0x%03X..0x%03X' % (s[i], s[j]))
        i = j + 1
    return ', '.join(out)


def wrap(text, width, prefix):
    lines = []
    cur = prefix
    for tok in text.split(' '):
        if len(cur) + len(tok) + 1 > width and cur.strip() != prefix.strip():
            lines.append(cur.rstrip())
            cur = prefix
        cur += tok + ' '
    lines.append(cur.rstrip())
    return lines


def render(allow, port):
    inc = []
    inc.append('@ nvm_allow.inc - class numbers and layout of the NVM allowed-byte table (generated)')
    inc.append('@ Generated by firmware/tools/gen_nvm_allow.py from firmware/EEPROM_MAP.md section 9.2; do not edit.')
    inc.append('    .ifndef NVM_ALLOW_INC')
    inc.append('    .equ NVM_ALLOW_INC, 1')
    for i, c in enumerate(CLASSES):
        inc.append('    .equ NVM_CLASS_%-9s %d          @ bitmap %d of nvm_allow' % (c + ',', i, i))
    inc.append('    .equ NVM_CLASS_COUNT,     %d' % len(CLASSES))
    inc.append('    .equ NVM_ALLOW_LIMIT,     0x%03X      @ offsets 0x000..0x%03X are described by the table' % (LIMIT, LIMIT - 1))
    inc.append('    .equ NVM_ALLOW_STRIDE,    %d        @ bytes per class bitmap (0x%03X bits)' % (STRIDE, LIMIT))
    inc.append('    .endif')
    s = []
    s.append('@ -----------------------------------------------------------------------------')
    s.append('@ nvm_allow.s - allowed-byte table of the NVM write classes (EMAP 9.2)')
    s.append('@ Generated by firmware/tools/gen_nvm_allow.py from firmware/EEPROM_MAP.md; do not edit.')
    s.append('@ `gen_nvm_allow.py --check` regenerates the table and compares it with this file (DESIGN.md 9.3 item 3).')
    s.append('@ Layout: one bitmap of NVM_ALLOW_LIMIT bits per class (NVM_ALLOW_STRIDE bytes), class order as in')
    s.append('@ nvm_allow.inc; bit (off & 7) of byte [class * NVM_ALLOW_STRIDE + (off >> 3)] = 1: class may write off.')
    if port:
        s.append('@ Port-only settings (EMAP 4.1): %s.  v2.05 never writes them; SETTINGS allows them' % fmt(port))
        s.append('@ (written as "v2.05 bits | port-only bits", so the v2.05 part of the table stays visible).')
    s.append('@ Users: nvm_write_bytes and the store-time re-check of the byte program (src/nvm/nvm.s).')
    s.append('@ -----------------------------------------------------------------------------')
    s.append('    .syntax unified')
    s.append('    .cpu cortex-m3')
    s.append('    .thumb')
    s.append('    .include "macros.inc"')
    s.append('    .include "nvm_allow.inc"')
    s.append('')
    s.append('    .section .rodata.nvm, "a", %progbits')
    s.append('    .align 2')
    s.append('    .global nvm_allow')
    s.append('    .type nvm_allow, %object')
    s.append('nvm_allow:')
    for i, c in enumerate(CLASSES):
        strict = allow[c] - port if c == 'SETTINGS' else allow[c]
        bits = bytearray(STRIDE)
        for off in strict:
            bits[off >> 3] |= 1 << (off & 7)
        extra = bytearray(STRIDE)                          # port-only bits (EMAP 4.1)
        if c == 'SETTINGS':
            for off in port:
                extra[off >> 3] |= 1 << (off & 7)
        s.append('@ class %d %s: %d bytes allowed%s' % (i, c, len(allow[c]), (' (%d of them port-only)' % len(port)) if (c == 'SETTINGS' and port) else ''))
        s += wrap(fmt(strict), 118, '@   ')
        if c == 'SETTINGS' and port:
            s.append('@   port-only (EMAP 4.1): ' + fmt(port))
        for row in range(0, STRIDE, 16):
            items = []
            for k in range(row, row + 16):
                if extra[k]:
                    items.append('0x%02X | 0x%02X' % (bits[k], extra[k]))
                else:
                    items.append('0x%02X' % bits[k])
            s.append('    .byte ' + ', '.join(items) +
                     '   @ offsets 0x%03X..0x%03X' % (row * 8, row * 8 + 127))
    s.append('    .size nvm_allow, . - nvm_allow')
    s.append('')
    return '\n'.join(s) + '\n', '\n'.join(inc) + '\n'


def main(argv):
    try:
        allow, port = build()
    except Fail as e:
        print('gen_nvm_allow: ' + str(e))
        return 1
    text_s, text_inc = render(allow, port)
    if '--list' in argv:
        for c in CLASSES:
            print('%-9s %4d  %s' % (c, len(allow[c]), fmt(allow[c])))
        if port:
            print('port-only %4d  %s  (in SETTINGS; v2.05 never writes them)' % (len(port), fmt(port)))
        return 0
    if '--check' in argv:
        bad = 0
        for path, text in ((OUT_S, text_s), (OUT_INC, text_inc)):
            if not os.path.exists(path) or open(path).read() != text:
                print('differs from the regenerated table: ' + os.path.relpath(path, v205.ROOT))
                bad = 1
        print('nvm_allow check: ' + ('FAIL' if bad else 'equal to EEPROM_MAP.md 9.2'))
        return bad
    os.makedirs(os.path.dirname(OUT_S), exist_ok=True)
    with open(OUT_S, 'w') as f:
        f.write(text_s)
    with open(OUT_INC, 'w') as f:
        f.write(text_inc)
    for c in CLASSES:
        print('%-9s %4d bytes' % (c, len(allow[c])))
    if port:
        print('of which port-only (production image only): %s' % fmt(port))
    print('wrote ' + os.path.relpath(OUT_S, v205.ROOT) + ', ' + os.path.relpath(OUT_INC, v205.ROOT))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
