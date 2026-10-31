"""Extract every v2.05 constant table from the original image into module source files (DESIGN.md 4.1, 8.3, 9.3, 13.2).

    python -I firmware/tools/extract_tables.py              write the table source files (list printed)
    python -I firmware/tools/extract_tables.py --verify     compare every TABLE_V205 region in the tree with the image,
                                                            check that the classification covers every data byte, and
                                                            check src/sys/data_v205.s against the image's lz77 RAM image
    python -I firmware/tools/extract_tables.py --verify --elf firmware/build/121gw.elf
                                                            additionally compare the linked tables through .v205tab
    python -I firmware/tools/extract_tables.py --report     print the classification of every data byte range

Classification of the image (analysis/decompile/bytemap.txt kinds 'data' and 'vector_table'; code is not touched):
  pool      literal-pool words: 4 bytes (8 for ldrd) at every address loaded pc-relative by a v2.05 instruction
  table     every other byte; a table starts at each address that code takes as a pointer (a pool word whose value is
            that address, or an `adr` target) and runs to the next table start, pool word or end of data range;
            consecutive tables of one module stay together in one block so that indexing across a table end keeps
            working exactly as in v2.05; a block is split only where the user module changes
  padding   0x00 bytes (or one 0xBF00 `nop`) before a 4-aligned pool or table start that nothing references
  vectors   0x08006000..0x08006123, rebuilt by SYS (DESIGN.md 2.2), not extracted
  initdesc  0x08029078..0x08029097, the start-up descriptors data_init 0x08028FE4 finds by pc-relative arithmetic
            (0x08028FE6..0x08028FF0): zero_init 0x6EBC bytes at 0x20001240 and lz77_init of 0x08029344 (420 bytes)
            into 0x20000000; replaced by the plain copy of OPT-01 (DESIGN.md 6.27)
  lz77      0x08029344..0x080294E7, the compressed RAM image; decompressed here (same algorithm as lz77_init
            0x080287C0) into src/sys/data_v205.s (section .data_v205, 574 bytes), verified against
            analysis/decompile/ram_init.txt
Module of a table: the module (DESIGN.md Appendix A, with its moves to AR and NVM) of the functions that load the
pointer, most users first, ties to the module listed first in Appendix A.  Files: HY -> src/hy/hy_rows.s, MVA ->
src/mva/burden_tables.s, LCD -> src/lcd/font.s, MODE -> src/mode/tables.s, every other module ->
src/<module>/tables_v205.s.  Each table: `TABLE_V205 <v2.05 address>, <length>` (macros.inc) immediately followed by
the global label v205_tab_XXXXXXXX (plus the verified name of analysis/verified_names.txt where one exists) and the
bytes as .byte/.hword/.word directives (.hword/.word only where every v2.05 access through the pointer has that width
and the table is aligned for it).  Header comment per table: address, size, users, accesses.
The generated files contain tables only; module code lives in other files of the module directory.
"""
import os
import re
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v205  # noqa: E402

SRC = os.path.join(v205.ROOT, 'firmware', 'src')
RAM_INIT = os.path.join(v205.ROOT, 'analysis', 'decompile', 'ram_init.txt')
FILES = {'HY': 'hy/hy_rows.s', 'MVA': 'mva/burden_tables.s', 'LCD': 'lcd/font.s', 'MODE': 'mode/tables.s'}
ORDER = ['SYS', 'BRD', 'PWR', 'BZB', 'RT', 'FUNC', 'LCD', 'UI', 'KEY', 'DIAL', 'MODE', 'AR', 'HY', 'MDC', 'MRES',
         'MFRQ', 'MTMP', 'MAC', 'MVA', 'CAL', 'NVM', 'LOG', 'SD', 'SET', 'RTC', 'BLE']
VECTORS = (0x08006000, 0x08006123)
INITDESC = (0x08029078, 0x08029097)
LZ77 = (0x08029344, 0x080294E7)
LZ77_DESC = 0x0802908C          # lz77_init argument block: src offset, length*2|flag, destination
DATA_V205 = os.path.join(SRC, 'sys', 'data_v205.s')
WIDTH = {'ldrb': 1, 'ldrsb': 1, 'ldrb.w': 1, 'ldrsb.w': 1, 'ldrh': 2, 'ldrsh': 2, 'ldrh.w': 2, 'ldrsh.w': 2,
         'ldr': 4, 'ldr.w': 4, 'ldrd': 8}


class Fail(Exception):
    pass


def file_for(mod):
    return FILES.get(mod, '%s/tables_v205.s' % mod.lower())


def access_widths(insns, code, index, start_addr, reg):
    """Widths of loads through reg (or reg advanced by add/adds reg, reg, ...) after the instruction at start_addr."""
    out = set()
    n = index[start_addr] + 1
    func = insns[start_addr].func
    for _ in range(24):
        if n >= len(code):
            break
        ins = insns[code[n]]
        if ins.func != func:
            break
        if re.search(r'\[' + re.escape(reg) + r'(?:[,\]])', ins.ops) and ins.mnem.split('.')[0].startswith('ldr'):
            if ins.mnem in WIDTH:
                out.add(WIDTH[ins.mnem])
        first = ins.ops.split(',')[0].strip()
        m = ins.mnem.split('.')[0]
        if first == reg and not m.startswith('str') and m not in ('cmp', 'cmn', 'tst', 'teq'):
            if m in ('add', 'adds') and re.match(re.escape(reg) + r',' + re.escape(reg) + r'\b', ins.ops.replace(' ', '')):
                pass
            elif m in ('add', 'adds') and re.match(re.escape(reg) + r',r\d+,' + re.escape(reg) + r'\b',
                                                   ins.ops.replace(' ', '')):
                pass
            else:
                break
        if ins.mnem in ('b', 'b.w', 'bx', 'pop', 'pop.w', 'bl', 'blx'):
            break
        n += 1
    return out


def classify():
    insns, funcs = v205.listing()
    img = v205.image()
    bm = v205.bytemap()
    mods = v205.appendix_a()
    names = v205.verified_names()
    loads = v205.pool_loads(insns)
    code = sorted(a for a, i in insns.items() if i.func is not None)
    index = {a: n for n, a in enumerate(code)}
    data = set()
    for s, e, k, _ in bm:
        if k in ('data', 'vector_table'):
            data.update(range(s, e + 1))
    pool = {}
    for p, users in loads.items():
        if any(u[2] == 'adr' for u in users):
            continue
        w = 8 if any(u[2].startswith('ldrd') for u in users) else 4
        for i in range(w):
            pool[p + i] = p
    # pointer targets inside data
    targets = {}
    for p, users in loads.items():
        if any(u[2] == 'adr' for u in users):
            t = p
            for (a, dest, mnem) in users:
                targets.setdefault(t, []).append((a, dest))
            continue
        v = int.from_bytes(v205.image_bytes(img, p, 4), 'little')
        if v in data and v not in pool:
            for (a, dest, mnem) in users:
                targets.setdefault(v, []).append((a, dest))
        elif v in data and v in pool:
            raise Fail('pointer 0x%08X (pool 0x%08X) points at a literal-pool word' % (v, p))
    special = set(range(VECTORS[0], VECTORS[1] + 1)) | set(range(INITDESC[0], INITDESC[1] + 1)) | \
        set(range(LZ77[0], LZ77[1] + 1))
    # walk the data bytes in address order and cut tables
    tables = []        # dicts: start, length, users, mod, widths
    padding = []
    cur = None
    for a in sorted(data):
        if a in pool or a in special:
            if cur:
                tables.append(cur)
                cur = None
            continue
        if a in targets:
            if cur:
                tables.append(cur)
            cur = {'start': a, 'end': a, 'refs': targets[a]}
            continue
        if cur and a == cur['end'] + 1:
            cur['end'] = a
            continue
        # byte not inside a table: must be padding before something aligned
        if cur:
            tables.append(cur)
            cur = None
        padding.append(a)
    if cur:
        tables.append(cur)
    # padding runs: zero bytes or one nop, at most 6 bytes, followed by a pool word, table or code
    runs = []
    for a in padding:
        if runs and runs[-1][1] == a - 1:
            runs[-1][1] = a
        else:
            runs.append([a, a])
    for s, e in runs:
        b = v205.image_bytes(img, s, e - s + 1)
        if e - s + 1 > 6 or not (set(b) == {0} or b == b'\x00\xbf'):
            raise Fail('unreferenced non-padding bytes 0x%08X..0x%08X: %s' % (s, e, b.hex()))
        nxt = e + 1
        if nxt % 4 and nxt not in index:
            raise Fail('padding 0x%08X..0x%08X is not followed by an aligned item' % (s, e))
    # annotate tables
    for t in tables:
        t['length'] = t['end'] - t['start'] + 1
        users = sorted(set(insns[a].func for a, _ in t['refs']))
        t['users'] = users
        count = {}
        for f in users:
            m = mods.get(f, '?')
            count[m] = count.get(m, 0) + 1
        best = sorted(count.items(), key=lambda kv: (-kv[1], ORDER.index(kv[0]) if kv[0] in ORDER else 99))
        t['mod'] = best[0][0]
        t['mods'] = sorted(count)
        w = set()
        for a, dest in t['refs']:
            if insns[a].mnem == 'adr':
                continue
            w |= access_widths(insns, code, index, a, dest)
        t['widths'] = w
        t['names'] = [n for (addr, (k, n)) in names.items() if addr == t['start'] and k == 'L']
        t['funcnames'] = {f: funcs[f][0] for f in users if f in funcs}
    return tables, runs, img, insns, funcs, data, pool, mods


def blocks_of(tables):
    """Consecutive tables (no gap) of one module form a block."""
    blocks = []
    for t in tables:
        if blocks and blocks[-1][-1]['end'] + 1 == t['start'] and blocks[-1][-1]['mod'] == t['mod']:
            blocks[-1].append(t)
        else:
            blocks.append([t])
    return blocks


def lz77_unpack(img):
    """Decompress the v2.05 RAM image exactly as lz77_init 0x080287C0 does (argument block 0x0802908C)."""
    word = lambda a: int.from_bytes(v205.image_bytes(img, a, 4), 'little')
    r0 = LZ77_DESC
    src = r0 + word(r0)                       # 0x080287C2/0x080287C8: r1 = r0 + [r0]
    n = word(r0 + 4)                          # 0x080287C4
    end = src + (n >> 1)                      # 0x080287CA: r2 = r1 + (r4 >> 1)
    if n & 1:
        raise Fail('lz77 descriptor requests the r9-relative destination (0x080287CE); not expected')
    out = bytearray()
    pos = src
    rd = lambda: v205.image_bytes(img, pos, 1)[0]
    while pos != end:                         # 0x080287D4
        b = rd(); pos += 1                    # 0x080287DE token
        lit = b & 3                           # 0x080287E2
        if lit == 0:
            lit = rd() + 3; pos += 1          # 0x080287E8..0x080287EC
        mlen = b >> 4                         # 0x080287EE
        if mlen == 15:
            mlen = rd() + 15; pos += 1        # 0x080287F4..0x080287F8
        lit -= 1                              # 0x08028804 subs then loop while != 0
        while lit:
            out.append(rd()); pos += 1
            lit -= 1
        if mlen == 0:                         # 0x08028808
            continue
        lo = rd(); pos += 1                   # 0x0802880E
        hi = (b >> 2) & 3                     # 0x0802880C..0x08028812
        if hi == 3:
            hi = rd(); pos += 1               # 0x0802881A
        dist = lo + (hi << 8)                 # 0x0802881E
        mlen += 2                             # 0x08028824
        sp = len(out) - dist                  # 0x08028822..0x08028826: r5 = r3 - dist
        while mlen:
            out.append(out[sp]); sp += 1
            mlen -= 1
    if pos != end:
        raise Fail('lz77 overran its input')
    return bytes(out)


def ram_init_bytes():
    vals = {}
    for line in open(RAM_INIT):
        if line.startswith(';') or not line.strip():
            continue
        p = line.split()
        base = int(p[0], 16)
        for i, h in enumerate(p[1:17]):
            if re.fullmatch(r'[0-9a-f]{2}', h):
                vals[base + i] = int(h, 16)
    n = max(vals) - 0x20000000 + 1
    return bytes(vals[0x20000000 + i] for i in range(n))


def fmt_users(t):
    out = []
    for f in t['users']:
        n = t['funcnames'].get(f, '')
        out.append('0x%08X%s' % (f, '' if n.startswith('FUN_') or not n else ' ' + n))
    return ', '.join(out)


def render_table(t, img, hyrows, first):
    data = v205.image_bytes(img, t['start'], t['length'])
    lines = []
    lines.append('@ v2.05 0x%08X, %d bytes; loaded by %s (%s)' % (t['start'], t['length'], fmt_users(t),
                                                                 ','.join(t['mods'])))
    w = sorted(t['widths'])
    lines.append('@ accesses through the pointer in v2.05: %s' % (', '.join('%d-byte' % x for x in w) if w else
                                                                  'by computed offsets only'))
    if first:
        # a block starts word-aligned in v2.05 and in the port, so every later table of the block keeps its
        # v2.05 alignment without padding between tables
        if t['start'] % 4:
            raise Fail('block starting at 0x%08X is not word-aligned in v2.05' % t['start'])
        lines.append('    .balign 4')
    lines.append('    TABLE_V205 0x%08X, %d' % (t['start'], t['length']))
    sym = 'v205_tab_%08X' % t['start']
    lines.append('    .global %s' % sym)
    lines.append('    .type %s, %%object' % sym)
    for n in t['names']:
        lines.append('    .global %s' % n)
        lines.append('    .type %s, %%object' % n)
        lines.append('    .set %s, %s' % (n, sym))
    lines.append('%s:' % sym)
    unit = 1
    if len(w) == 1 and w[0] in (2, 4) and t['start'] % w[0] == 0 and t['length'] % w[0] == 0:
        unit = w[0]
    if hyrows and t['length'] % 20 == 0:
        per = 20
    else:
        per = 16
    off = 0
    while off < t['length']:
        chunk = data[off:off + per]
        addr = t['start'] + off
        if unit == 1:
            txt = '    .byte ' + ', '.join('0x%02X' % b for b in chunk)
        elif unit == 2:
            txt = '    .hword ' + ', '.join('0x%04X' % v for v in struct.unpack('<%dH' % (len(chunk) // 2), chunk))
        else:
            txt = '    .word ' + ', '.join('0x%08X' % v for v in struct.unpack('<%dI' % (len(chunk) // 4), chunk))
        asc = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
        note = '@ 0x%08X' % addr
        if hyrows and per == 20:
            note += ' row %d' % (off // 20)
        if sum(32 <= b < 127 for b in chunk) >= len(chunk) // 2:
            note += ' "%s"' % asc
        lines.append('%-110s %s' % (txt, note) if len(txt) < 110 else txt + '  ' + note)
        off += per
    lines.append('    .size %s, . - %s' % (sym, sym))
    return lines


def render_file(mod, blocks, img):
    path = file_for(mod)
    lines = []
    lines.append('@ -----------------------------------------------------------------------------')
    lines.append('@ %s - v2.05 constant tables of module %s' % (os.path.basename(path), mod))
    lines.append('@ Generated by firmware/tools/extract_tables.py from inputs/binaries/EEVBlog2_05.bin; do not edit.')
    lines.append('@ Every table is preceded by TABLE_V205 <v2.05 address>, <length> (macros.inc); the build check and')
    lines.append('@ `extract_tables.py --verify` compare its bytes with the original image (DESIGN.md 9.3 item 3).')
    lines.append('@ Tables that are adjacent in v2.05 and belong to this module are kept adjacent here (same order, no')
    lines.append('@ gap), so code that indexes past the end of one table into the next reads the same bytes as v2.05.')
    lines.append('@ -----------------------------------------------------------------------------')
    lines.append('    .syntax unified')
    lines.append('    .cpu cortex-m3')
    lines.append('    .thumb')
    lines.append('    .include "macros.inc"')
    lines.append('')
    lines.append('    .section .rodata.%s, "a", %%progbits' % mod.lower())
    for blk in blocks:
        lines.append('')
        if len(blk) > 1:
            lines.append('@ ---- block 0x%08X..0x%08X: %d adjacent tables ----' % (blk[0]['start'], blk[-1]['end'],
                                                                                  len(blk)))
        for i, t in enumerate(blk):
            if i:
                lines.append('')
            lines += render_table(t, img, mod == 'HY', i == 0)
    lines.append('')
    return path, '\n'.join(lines) + '\n'


def render_data_v205(ram):
    lines = []
    lines.append('@ -----------------------------------------------------------------------------')
    lines.append('@ data_v205.s - initial image of the v2.05 initialised RAM 0x20000000..0x%08X (%d bytes)' %
                 (0x20000000 + len(ram) - 1, len(ram)))
    lines.append('@ Generated by firmware/tools/extract_tables.py; do not edit.')
    lines.append('@ v2.05 builds this RAM content at start-up with lz77_init 0x080287C0 from the compressed bytes')
    lines.append('@ 0x08029344..0x080294E7 (descriptor 0x0802908C, called by data_init 0x08028FE4); the port copies this')
    lines.append('@ image instead (OPT-01, DESIGN.md 3.2 step 4 and 6.27).  `extract_tables.py --verify` decompresses the')
    lines.append('@ original bytes with the same algorithm and compares them with this file and with')
    lines.append('@ analysis/decompile/ram_init.txt.  Linked at 0x20000000 (.data_v205, load address in flash).')
    lines.append('@ -----------------------------------------------------------------------------')
    lines.append('    .syntax unified')
    lines.append('    .cpu cortex-m3')
    lines.append('    .thumb')
    lines.append('    .include "macros.inc"')
    lines.append('')
    lines.append('    .section .data_v205, "aw", %progbits')
    lines.append('    .global data_v205_image')
    lines.append('    .type data_v205_image, %object')
    lines.append('data_v205_image:')
    for off in range(0, len(ram), 16):
        chunk = ram[off:off + 16]
        asc = ''.join(chr(b) if 32 <= b < 127 else '.' for b in chunk)
        txt = '    .byte ' + ', '.join('0x%02X' % b for b in chunk)
        lines.append('%-110s @ 0x%08X "%s"' % (txt, 0x20000000 + off, asc))
    lines.append('    .size data_v205_image, . - data_v205_image')
    lines.append('')
    return '\n'.join(lines) + '\n'


# ---------------------------------------------------------------- verification

DIRECTIVE = re.compile(r'^\s*\.(byte|hword|word)\s+([^@]*)')


def parse_source_tables(text):
    """List of (v2.05 addr, length, bytes) from TABLE_V205 marks and the data directives after them."""
    out = []
    cur = None
    for line in text.splitlines():
        m = re.match(r'^\s*TABLE_V205\s+(0x[0-9A-Fa-f]+)\s*,\s*(\d+)', line)
        if m:
            if cur:
                out.append(cur)
            cur = [int(m.group(1), 16), int(m.group(2)), bytearray()]
            continue
        if cur is None:
            continue
        if re.match(r'^\s*\.size\s', line):
            out.append(cur)
            cur = None
            continue
        m = DIRECTIVE.match(line)
        if m:
            vals = [int(x.strip(), 0) for x in m.group(2).split(',') if x.strip()]
            size = {'byte': 1, 'hword': 2, 'word': 4}[m.group(1)]
            for v in vals:
                cur[2] += v.to_bytes(size, 'little')
    if cur:
        out.append(cur)
    return out


def elf_sections(path):
    """Minimal ELF32 little-endian reader: list of (name, type, flags, addr, offset, size) and the file bytes."""
    b = open(path, 'rb').read()
    if b[:4] != b'\x7fELF' or b[4] != 1 or b[5] != 1:
        raise Fail('%s is not an ELF32 little-endian file' % path)
    shoff, = struct.unpack_from('<I', b, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x2E)
    secs = []
    for i in range(shnum):
        name, typ, flags, addr, off, size = struct.unpack_from('<IIIIII', b, shoff + i * shentsize)
        secs.append([name, typ, flags, addr, off, size])
    stro = secs[shstrndx][4]
    for s in secs:
        n = s[0]
        e = b.index(b'\0', stro + n)
        s[0] = b[stro + n:e].decode()
    return secs, b


def verify_elf(path, img, src_tables):
    secs, b = elf_sections(path)
    tab = [s for s in secs if s[0] == '.v205tab']
    if not tab:
        raise Fail('%s has no .v205tab section' % path)
    _, _, _, _, off, size = tab[0]
    entries = [struct.unpack_from('<III', b, off + i) for i in range(0, size, 12)]
    loadable = [s for s in secs if s[1] == 1 and (s[2] & 2) and s[5]]     # PROGBITS, SHF_ALLOC

    def read(addr, n):
        for s in loadable:
            if s[3] <= addr and addr + n <= s[3] + s[5]:
                return b[s[4] + addr - s[3]:s[4] + addr - s[3] + n]
        raise Fail('linked table at 0x%08X+%d is not inside a loaded section' % (addr, n))
    bad = 0
    seen = set()
    for a, n, port in entries:
        if read(port, n) != v205.image_bytes(img, a, n):
            print('ELF table 0x%08X (%d bytes) at 0x%08X differs from the image' % (a, n, port))
            bad += 1
        seen.add((a, n))
    for a, n, _ in src_tables:
        if (a, n) not in seen:
            print('table 0x%08X (%d bytes) is in the sources but not in the ELF .v205tab' % (a, n))
            bad += 1
    print('ELF: %d .v205tab entries checked, %d problems' % (len(entries), bad))
    return bad


def verify(argv):
    tables, runs, img, insns, funcs, data, pool, mods = classify()
    bad = 0
    found = []
    for root, dirs, files in os.walk(SRC):
        for fn in sorted(files):
            if fn.endswith('.s'):
                p = os.path.join(root, fn)
                for a, n, by in parse_source_tables(open(p).read()):
                    found.append((a, n, bytes(by), os.path.relpath(p, v205.ROOT)))
    for a, n, by, p in found:
        if len(by) != n:
            print('%s: TABLE_V205 0x%08X declares %d bytes, data directives give %d' % (p, a, n, len(by)))
            bad += 1
        elif by != v205.image_bytes(img, a, n):
            print('%s: table 0x%08X differs from the image' % (p, a))
            bad += 1
    want = {(t['start'], t['length']) for t in tables}
    have = {(a, n) for a, n, _, _ in found}
    for a, n in sorted(want - have):
        print('table 0x%08X (%d bytes) of the image is missing from the sources' % (a, n))
        bad += 1
    for a, n in sorted(have - want):
        print('TABLE_V205 0x%08X (%d bytes) does not match a table of the classification' % (a, n))
        bad += 1
    # coverage of every data byte
    covered = set()
    for t in tables:
        covered.update(range(t['start'], t['end'] + 1))
    covered.update(pool)
    for s, e in runs:
        covered.update(range(s, e + 1))
    for lo, hi in (VECTORS, INITDESC, LZ77):
        covered.update(range(lo, hi + 1))
    missing = sorted(data - covered)
    if missing:
        print('data bytes not classified: %d, first 0x%08X' % (len(missing), missing[0]))
        bad += 1
    # RAM image
    ram = lz77_unpack(img)
    ri = ram_init_bytes()
    if ram != ri:
        print('lz77 output differs from analysis/decompile/ram_init.txt')
        bad += 1
    if not os.path.exists(DATA_V205):
        print('missing ' + os.path.relpath(DATA_V205, v205.ROOT))
        bad += 1
    else:
        by = bytearray()
        for line in open(DATA_V205):
            m = DIRECTIVE.match(line)
            if m:
                by += bytes(int(x.strip(), 0) for x in m.group(2).split(',') if x.strip())
        if bytes(by) != ram:
            print('src/sys/data_v205.s differs from the decompressed v2.05 RAM image')
            bad += 1
    print('tables: %d in sources, %d in the image classification; RAM image %d bytes; %d problems' %
          (len(found), len(tables), len(ram), bad))
    if '--elf' in argv:
        bad += verify_elf(argv[argv.index('--elf') + 1], img, [(a, n, by) for a, n, by, _ in found])
    return 1 if bad else 0


def main(argv):
    try:
        if '--verify' in argv:
            return verify(argv)
        tables, runs, img, insns, funcs, data, pool, mods = classify()
        if '--report' in argv:
            for t in tables:
                print('table   0x%08X %5d %-5s users %s widths %s' % (t['start'], t['length'], t['mod'], fmt_users(t),
                                                                      sorted(t['widths'])))
            for s, e in runs:
                print('padding 0x%08X %5d' % (s, e - s + 1))
            for a, b in zip(tables, tables[1:]):
                if a['end'] + 1 == b['start'] and a['mod'] != b['mod']:
                    print('module boundary between adjacent tables: 0x%08X (%s) ends where 0x%08X (%s) starts; '
                          'the two are emitted in different files' % (a['start'], a['mod'], b['start'], b['mod']))
            print('pool words: %d bytes' % len(pool))
            return 0
        bymod = {}
        for blk in blocks_of(tables):
            bymod.setdefault(blk[0]['mod'], []).append(blk)
        for mod, blks in sorted(bymod.items()):
            path, text = render_file(mod, blks, img)
            full = os.path.join(SRC, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, 'w') as f:
                f.write(text)
            n = sum(len(b) for b in blks)
            print('%-26s %3d tables %6d bytes' % ('src/' + path, n, sum(t['length'] for b in blks for t in b)))
        ram = lz77_unpack(img)
        if ram != ram_init_bytes():
            raise Fail('lz77 output differs from analysis/decompile/ram_init.txt')
        os.makedirs(os.path.dirname(DATA_V205), exist_ok=True)
        with open(DATA_V205, 'w') as f:
            f.write(render_data_v205(ram))
        print('%-26s RAM image %d bytes' % ('src/sys/data_v205.s', len(ram)))
        return 0
    except Fail as e:
        print('extract_tables: ' + str(e))
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
