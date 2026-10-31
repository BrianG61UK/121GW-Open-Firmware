"""Shared reader for the v2.05 analysis files, used by the firmware tools.

Reads (paths relative to the project root):
  inputs/binaries/EEVBlog2_05.bin              the original application image, base 0x08006000
  analysis/decompile/EEVBlog2_05_listing.asm   disassembly listing (address, bytes, instruction, references)
  analysis/decompile/bytemap.txt               classification of every image byte range (code, data, padding)
  analysis/verified_names.txt                  verified function (F) and variable/table (L) names
  firmware/DESIGN.md                           Appendix A (function -> module) and Appendix B (RAM base -> module)

Nothing here writes a file.  The tools that import this module are run with `python -I`, so they insert this
directory into sys.path themselves.
"""
import os
import re

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(TOOLS, '..', '..'))
IMAGE = os.path.join(ROOT, 'inputs', 'binaries', 'EEVBlog2_05.bin')
LISTING = os.path.join(ROOT, 'analysis', 'decompile', 'EEVBlog2_05_listing.asm')
BYTEMAP = os.path.join(ROOT, 'analysis', 'decompile', 'bytemap.txt')
NAMES = os.path.join(ROOT, 'analysis', 'verified_names.txt')
DESIGN = os.path.join(ROOT, 'firmware', 'DESIGN.md')
EEPROM_MAP = os.path.join(ROOT, 'firmware', 'EEPROM_MAP.md')
BASE = 0x08006000

# One listing line: address, hex bytes (may end in '+' when truncated), instruction text, optional '; refs'.
_LINE = re.compile(r'^([0-9a-f]{8})  ([0-9a-f]+\+?)\s+(.*?)\s*(?:;\s*(.*))?$')
_FUNC = re.compile(r'^; FUNCTION .*?\b(\w+)\(')
_BODY = re.compile(r'^; body \[\[([0-9a-f]{8}), ([0-9a-f]{8})\](?:, \[([0-9a-f]{8}), ([0-9a-f]{8})\])*')
_BODYPART = re.compile(r'\[([0-9a-f]{8}), ([0-9a-f]{8})\]')


def image():
    """Return the original image bytes."""
    with open(IMAGE, 'rb') as f:
        return f.read()


def image_bytes(img, addr, length):
    """Bytes of the original image at absolute address addr."""
    off = addr - BASE
    if off < 0 or off + length > len(img):
        raise ValueError('address range 0x%08X+%d outside the image' % (addr, length))
    return img[off:off + length]


class Insn:
    __slots__ = ('addr', 'raw', 'mnem', 'ops', 'refs', 'func')

    def __init__(self, addr, raw, mnem, ops, refs):
        self.addr = addr
        self.raw = raw
        self.mnem = mnem
        self.ops = ops
        self.refs = refs
        self.func = None


def listing():
    """Parse the listing.  Returns (insns: dict addr -> Insn in file order, funcs: dict start -> (name, [(s, e)]))."""
    insns = {}
    funcs = {}
    pending = None
    with open(LISTING) as f:
        for line in f:
            line = line.rstrip('\n')
            m = _FUNC.match(line)
            if m:
                pending = m.group(1)
                continue
            if line.startswith('; body [['):
                parts = [(int(a, 16), int(b, 16)) for a, b in _BODYPART.findall(line)]
                if pending is not None and parts:
                    funcs[parts[0][0]] = (pending, parts)
                pending = None
                continue
            m = _LINE.match(line)
            if not m:
                continue
            addr = int(m.group(1), 16)
            text = m.group(3)
            sp = text.split(None, 1)
            mnem = sp[0] if sp else ''
            ops = sp[1] if len(sp) > 1 else ''
            refs = m.group(4) or ''
            insns[addr] = Insn(addr, m.group(2), mnem, ops, refs)
    # Attach every instruction to the function whose body contains it.
    ranges = []
    for start, (name, parts) in funcs.items():
        for s, e in parts:
            ranges.append((s, e, start))
    ranges.sort()
    import bisect
    starts = [r[0] for r in ranges]
    for a, ins in insns.items():
        i = bisect.bisect_right(starts, a) - 1
        if i >= 0 and ranges[i][0] <= a <= ranges[i][1]:
            ins.func = ranges[i][2]
    return insns, funcs


def bytemap():
    """List of (start, end_inclusive, kind, rest) from bytemap.txt."""
    out = []
    with open(BYTEMAP) as f:
        for line in f:
            p = line.split(None, 3)
            if len(p) < 3:
                continue
            out.append((int(p[0], 16), int(p[1], 16), p[2], p[3].strip() if len(p) > 3 else ''))
    return out


def verified_names():
    """dict addr -> (kind 'F' or 'L', name)."""
    out = {}
    with open(NAMES) as f:
        for line in f:
            if line.startswith('#') or not line.strip():
                continue
            p = line.split()
            if len(p) >= 3 and p[0] in ('F', 'L'):
                out[int(p[1], 16)] = (p[0], p[2])
    return out


def _design_text():
    with open(DESIGN) as f:
        return f.read()


def appendix_a():
    """dict function start address -> module name, from DESIGN.md Appendix A, with the moves stated there
    (AR takes 0x0800DE24, 0x0800E2A0, 0x0800AC1C; NVM takes the EEPROM byte layer and the FLASH driver)."""
    text = _design_text()
    a = text.index('## Appendix A.')
    b = text.index('## Appendix B.')
    out = {}
    for m in re.finditer(r'^\*\*(\w+)\*\* \(W\d+; [^)]*\): (.*)$', text[a:b], re.M):
        mod = m.group(1)
        for am in re.finditer(r'\b([0-9A-F]{8})\b', m.group(2)):
            out[int(am.group(1), 16)] = mod
    for x in (0x0800DE24, 0x0800E2A0, 0x0800AC1C):
        out[x] = 'AR'
    nvm = [0x08011F80, 0x08011FD4, 0x08012000, 0x0801203A, 0x0801204C, 0x08012068, 0x080120A8, 0x080120D0,
           0x080120F0, 0x08012148, 0x080104F8, 0x08010504, 0x0801159C, 0x080115CC, 0x08011B40, 0x08011DCE,
           0x08011E88, 0x08011F38, 0x0801F9FC, 0x0801FA1C, 0x0801FA2E, 0x0801FAFA, 0x0801FB00, 0x0801FB60]
    for x in nvm:
        out[x] = 'NVM'
    return out


def appendix_b():
    """dict RAM base address -> (module, shared flag) from DESIGN.md Appendix B."""
    text = _design_text()
    a = text.index('## Appendix B.')
    b = text.index('## Appendix C.')
    out = {}
    for m in re.finditer(r'^\*\*(\w+)\*\* \(\d+\): (.*)$', text[a:b], re.M):
        mod = m.group(1)
        for am in re.finditer(r'\b(2000[0-9A-F]{4})(\*?)', m.group(2)):
            out[int(am.group(1), 16)] = (mod, am.group(2) == '*')
    return out


POOL_LOAD = re.compile(r'\[0x(0?8[0-9a-f]{6})\]')


def pool_loads(insns):
    """dict pool word address -> list of (loading instruction address, destination register, mnemonic) for every
    pc-relative load in code (`ldr`/`ldr.w`/`ldrd`/`adr` operands written as [0xADDR] by the listing)."""
    out = {}
    for a, ins in insns.items():
        if ins.func is None:
            continue
        m = POOL_LOAD.search(ins.ops)
        if not m:
            continue
        dest = ins.ops.split(',')[0].strip()
        out.setdefault(int(m.group(1), 16), []).append((a, dest, ins.mnem))
    return out
