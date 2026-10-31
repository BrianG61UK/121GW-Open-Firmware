"""Generate firmware/src/inc/ram_v205.inc: one symbol for every v2.05 RAM base address (DESIGN.md 5.1).

    python -I firmware/tools/gen_ram_symbols.py            write firmware/src/inc/ram_v205.inc
    python -I firmware/tools/gen_ram_symbols.py --check    regenerate in memory and compare with the file in the tree
    python -I firmware/tools/gen_ram_symbols.py --stdout   print instead of writing

Method (DESIGN.md 5.1, Appendix B): every literal-pool word of the original image whose value lies in RAM
0x20000000..0x2000BFFF and that is loaded by a pc-relative load inside a v2.05 function is a RAM base address.  For each
base the tool records
  - the access widths and offsets used through the loaded register in the following instructions of the same
    function (ldrb/strb/ldrsb = 1 byte, ldrh/strh/ldrsh = 2, ldr/str = 4, ldrd/strd = 8),
  - the number of functions that load it and their modules (DESIGN.md Appendix A),
  - the primary module of Appendix B ('*' = also referenced by another module),
  - the initial value from analysis/decompile/ram_init.txt for 0x20000000..0x2000023D (zero for 0x20001240..0x200080FB).
Symbol names: the verified name of analysis/verified_names.txt ('L' entries) where one exists, and v_XXXXXXXX (upper-case
hex) for every base, so code may use either.  The generated file is maintained by review afterwards (DESIGN.md 8.1);
--check reports every difference between the regenerated symbol set and the file.
"""
import os
import re
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v205  # noqa: E402

OUT = os.path.join(v205.ROOT, 'firmware', 'src', 'inc', 'ram_v205.inc')
RAM_INIT = os.path.join(v205.ROOT, 'analysis', 'decompile', 'ram_init.txt')
RAM_LO, RAM_HI = 0x20000000, 0x2000BFFF

WIDTH = {'ldrb': 1, 'strb': 1, 'ldrsb': 1, 'ldrb.w': 1, 'strb.w': 1, 'ldrsb.w': 1,
         'ldrh': 2, 'strh': 2, 'ldrsh': 2, 'ldrh.w': 2, 'strh.w': 2, 'ldrsh.w': 2,
         'ldr': 4, 'str': 4, 'ldr.w': 4, 'str.w': 4,
         'ldrd': 8, 'strd': 8}
# Fixed owners of DESIGN.md 5.2 that override the Appendix B count.
FIXED = {0x2000803C: 'MODE', 0x2000803D: 'MODE', 0x20007E0C: 'MVA', 0x20007FDF: 'BRD', 0x200077D0: 'HY',
         0x20007790: 'LCD', 0x20007AE0: 'BLE', 0x20007B80: 'BLE', 0x20008095: 'CAL'}
FIXED.update({a: 'CAL' for a in range(0x20007E00, 0x20007E59) if a != 0x20007E0C})
FIXED.update({a: 'CAL' for a in range(0x20008088, 0x20008090)})
FIXED.update({a: 'PWR' for a in range(0x200080E6, 0x200080EA)})
STOP = ('b', 'b.w', 'bx', 'pop', 'pop.w', 'bl', 'blx', 'cbz', 'cbnz')


def ram_init():
    """dict addr -> byte for 0x20000000..0x2000023D."""
    out = {}
    with open(RAM_INIT) as f:
        for line in f:
            if line.startswith(';') or not line.strip():
                continue
            p = line.split()
            base = int(p[0], 16)
            for i, h in enumerate(p[1:17]):
                if re.fullmatch(r'[0-9a-f]{2}', h):
                    out[base + i] = int(h, 16)
    return out


def written_regs(ins):
    """First operand register of instructions that write a register (approximation used to end the scan)."""
    m = ins.mnem.split('.')[0]
    if m.startswith('str') or m in ('cmp', 'cmn', 'tst', 'teq', 'it', 'itt', 'ite', 'ittt', 'itte', 'itee', 'iteee',
                                    'ittte', 'itttt', 'itet', 'push', 'nop'):
        return set()
    if m.startswith('ldm') or m == 'pop':
        return set(re.findall(r'r\d+|lr|pc', ins.ops))
    first = ins.ops.split(',')[0].strip()
    if m == 'ldrd':
        return set(x.strip() for x in ins.ops.split(',')[:2])
    return {first}


def analyse(insns):
    img = v205.image()
    loads = v205.pool_loads(insns)
    code = sorted(a for a, i in insns.items() if i.func is not None)
    index = {a: n for n, a in enumerate(code)}
    bases = {}
    for pool, users in loads.items():
        try:
            val = int.from_bytes(v205.image_bytes(img, pool, 4), 'little')
        except ValueError:
            continue
        if not (RAM_LO <= val <= RAM_HI):
            continue
        for (a, dest, mnem) in users:
            if not mnem.startswith('ldr') or mnem.startswith('ldrd'):
                continue
            e = bases.setdefault(val, {'funcs': set(), 'acc': set()})
            e['funcs'].add(insns[a].func)
            # follow the loaded register through the rest of the basic block
            n = index[a] + 1
            steps = 0
            while n < len(code) and steps < 16:
                ins = insns[code[n]]
                if ins.func != insns[a].func:
                    break
                mm = re.search(r'\[' + re.escape(dest) + r'(?:,#(-?0x[0-9a-f]+|-?\d+))?\]', ins.ops)
                if mm and ins.mnem in WIDTH:
                    off = int(mm.group(1), 0) if mm.group(1) else 0
                    kind = 'r' if ins.mnem.startswith('ld') else 'w'
                    e['acc'].add((off, WIDTH[ins.mnem], kind))
                if dest in written_regs(ins) and not (mm and ins.mnem.startswith('str')):
                    break
                if ins.mnem in STOP:
                    break
                n += 1
                steps += 1
    return bases


def generate():
    insns, funcs = v205.listing()
    bases = analyse(insns)
    mods = v205.appendix_a()
    appb = v205.appendix_b()
    names = {a: n for a, (k, n) in v205.verified_names().items() if k == 'L' and RAM_LO <= a <= RAM_HI}
    init = ram_init()
    lines = []
    lines.append('@ ram_v205.inc - every v2.05 RAM base address at its v2.05 address (DESIGN.md 5.1, Appendix B)')
    lines.append('@')
    lines.append('@ Generated by firmware/tools/gen_ram_symbols.py from the literal pools of')
    lines.append('@ analysis/decompile/EEVBlog2_05_listing.asm and the image inputs/binaries/EEVBlog2_05.bin; maintained by')
    lines.append('@ review afterwards (DESIGN.md 8.1).  `gen_ram_symbols.py --check` compares this file with a fresh run.')
    lines.append('@')
    lines.append('@ Every base gets v_XXXXXXXX; a verified name (analysis/verified_names.txt) is an alias of it.  Column notes:')
    lines.append('@   mod   primary module of DESIGN.md Appendix B (* = also referenced by functions of another module)')
    lines.append('@   acc   accesses through the loaded register in v2.05: +offset:width r(ead)/w(rite)')
    lines.append('@   fn    number of v2.05 functions that load the base, and their modules (Appendix A)')
    lines.append('@   init  initial bytes from analysis/decompile/ram_init.txt (0x20000000..0x2000023D); bases at')
    lines.append('@         0x20001240..0x200080FB start at zero (zero_init 0x08028CDC)')
    lines.append('@ The section layout that keeps these addresses is DESIGN.md 5.1 / 9.2 (link/121gw.ld).')
    lines.append('')
    lines.append('    .ifndef RAM_V205_INC')
    lines.append('    .equ RAM_V205_INC, 1')
    lines.append('')
    count = 0
    for addr in sorted(bases):
        e = bases[addr]
        count += 1
        sym = 'v_%08X' % addr
        acc = ' '.join('+%d:%d%s' % (o, w, k) for (o, w, k) in sorted(e['acc'])) or '-'
        fmods = sorted(set(mods.get(f, '?') for f in e['funcs']))
        mod, shared = appb.get(addr, ('?', False))
        modtxt = mod + ('*' if shared else '')
        if addr in FIXED and FIXED[addr] != mod:
            modtxt += ' (owner %s, DESIGN.md 5.2)' % FIXED[addr]
        note = 'mod %s  acc %s  fn %d %s' % (modtxt, acc, len(e['funcs']), ','.join(fmods))
        if addr in init:
            width = max([w for (o, w, k) in e['acc'] if o == 0] or [1])
            width = min(width, 4)
            ib = [init.get(addr + i) for i in range(width)]
            if None not in ib:
                note += '  init ' + ' '.join('%02X' % b for b in ib)
        lines.append('    .equ %-28s 0x%08X  @ %s' % (sym + ',', addr, note))
        if addr in names:
            lines.append('    .equ %-28s %s' % (names[addr] + ',', sym))
    lines.append('')
    lines.append('    .endif')
    lines.append('@ %d base addresses' % count)
    return '\n'.join(lines) + '\n', count, bases, names


def parse_inc(text):
    out = {}
    for m in re.finditer(r'^\s*\.equ\s+(\w+),\s+(0x[0-9A-Fa-f]+|\w+)', text, re.M):
        out[m.group(1)] = m.group(2)
    return out


def main(argv):
    text, count, bases, names = generate()
    if '--stdout' in argv:
        sys.stdout.write(text)
        return 0
    if '--check' in argv:
        if not os.path.exists(OUT):
            print('missing', OUT)
            return 1
        have = parse_inc(open(OUT).read())
        want = parse_inc(text)
        bad = 0
        for k, v in want.items():
            if have.get(k) != v:
                print('differs: %s want %s have %s' % (k, v, have.get(k)))
                bad += 1
        for k in have:
            if k not in want and k != 'RAM_V205_INC':
                print('extra in file (review entry): %s = %s' % (k, have[k]))
        print('%d bases, %d differences' % (count, bad))
        return 1 if bad else 0
    with open(OUT, 'w') as f:
        f.write(text)
    print('wrote %s: %d base addresses, %d verified names' % (os.path.relpath(OUT, v205.ROOT), count, len(names)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
