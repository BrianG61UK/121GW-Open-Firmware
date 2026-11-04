#!/usr/bin/env python3
"""check_image.py - image, never-brick and symbol checks of the linked firmware (DESIGN.md 9.3 items 1, 2 and 5).

Usage (from firmware/, as the Makefile does):
    python3 -I tools/check_image.py build/121gw.elf build/EEVBlog.bin [--map build/121gw.map] [--design DESIGN.md]
                                    [--switch NAME=value ...]   (build switches as the Makefile passes them)
    python3 -I tools/check_image.py --v205 ../inputs/binaries/EEVBlog2_05.bin     (analysis mode, see below)
Exit status 0 = every check passed, 1 = at least one violation, 2 = the tool could not do its job.  The report goes to
standard output: the facts the checks rest on (counts, coverage), one line per violation, a final PASS or FAIL line.
Needs Python 3 and Capstone (the same as the other tools of this directory).

What is checked
  Item 1, image (DESIGN 2.1, 2.2): the raw image equals the loadable flash content of the ELF; its size is a multiple
    of 4 and at most 0x5A000; vector 0 is 0x20001240 and passes the bootloader test (SP & 0x2FFE0000) == 0x20000000
    (bootloader 0x08004994); vector 1 is odd and inside the image; the table has 73 vectors, every one except the
    reserved slots 7..10 and 13 is odd, points at a decoded instruction and lies inside the code, the reserved slots
    are zero.
  Item 2, never brick (DESIGN 1, 4.6, 9.3 item 2, corrected statement of the project): instruction-level analysis of the
    linked ELF.  Every code range (ELF mapping symbols $t / $d) is disassembled with Capstone, split into basic
    blocks and run through a forward constant propagation over the control-flow graph of the image (values meet at
    block joins: equal constants survive, anything else becomes unknown).  The tracked value of a register is a
    constant (movw / movt / literal pool load / mov / add / sub / orr / and / bic / eor / shifts of constants) or a
    "loaded" value (a word read from a known address with known OR / AND-NOT masks applied, used for the
    read-modify-write of FLASH_PECR).  For every load and store the effective address is computed when the base
    register (and index register) is known.  Rejected (each reported with function, address and reason):
      * any access whose effective address lies in the FLASH interface block 0x40023C00..0x40023FFF other than the
        allowed registers: FLASH_ACR 0x40023C00 (object sys/clock only), FLASH_PECR 0x40023C04, FLASH_PEKEYR
        0x40023C0C and FLASH_SR 0x40023C18 (objects under nvm/ only).  That covers PDKEYR 0x08, PRGKEYR 0x10, OPTKEYR
        0x14, OBR 0x1C and WRPR 0x20.. (RM0038 3.9, FLASH register map).  FLASH_SR is allowed (RM0038 3.9.7);
      * any access to the FLASH block with a base in the block plus a non-zero offset or a register offset (DESIGN 8.2:
        every FLASH register is addressed by its own literal with offset 0), also by a post-indexed or writeback form;
      * any access (effective address of a single load or store, or any word of a multiple access) in the option-byte
        area 0x1FF80000..0x1FF800FF, and any access through the bit-band alias of the FLASH block (0x42478000..0x4247FFFF);
      * any store with a known address in 0x08000000..0x0809FFFF (program flash incl. the bootloader sectors; data
        EEPROM 0x08080000..0x08082FFF only in objects under nvm/, nothing above 0x08082FFF);
      * any known constant (produced by any instruction, or present as a pool word / table word at any byte offset of a
        data range) equal to an address of the rejected FLASH registers or option-byte area, to the program-memory,
        option-byte or power-down key values (PRGKEY 0x8C9DAEBF 0x13141516, OPTKEY 0xFBEAD9C8 0x24252627, PDKEY
        0x04152637 0xFAFBFCFD; RM0038 3.9.3, 3.9.5, 3.9.6), or a `movt` that produces 0x1FF8 in the high half or 0x4002
        over an unknown low half; the data-EEPROM key values 0x89ABCDEF 0x02030405 and the EEPROM range
        0x08080000..0x08082FFF only inside objects under nvm/;
      * stores to FLASH_PECR whose value is not "the value just read from FLASH_PECR with only bit 0 (PELOCK) ORed in
        and / or only bit 8 (FTDW) cleared"; stores to FLASH_PEKEYR whose value is not exactly one of the two PEKEY
        words; stores to FLASH_ACR that are not a read-modify-write that sets only LATENCY, PRFTEN or ACC64; any
        store to a FLASH register by an instruction other than a single `str`;
      * the exemption asked for by the MPU guard (DESIGN 12.2 Q12, `MPU_GUARD`): the pool word 0x1FF80000 in the object
        sys/reset.o is accepted only while the register that holds it is used as the data of a store to MPU_RBAR
        (0xE000ED9C); any other use of that register is a violation.
    Limits (stated, not hidden): propagation is per register and stops at calls (r0-r3, r12, lr are clobbered by a `bl`;
    r4-r11 are assumed preserved as AAPCS requires); memory is not tracked, so a constant stored to RAM and
    reloaded is unknown; a base register that is unknown (a pointer from RAM, an argument) is not checked; the
    protection against such constants is the census of every constant, pool word and `movt` above, which sees the
    literal wherever it is used; DMA transfers and the MPU are outside this check.  The number of loads and stores
    with a known effective address is printed so the coverage is visible.
  Item 5, symbols (DESIGN 9.3 item 5, Appendix C): no undefined symbol in the ELF; every symbol that Appendix C.1 / C.2
    lists is defined exactly once (routines the C.1 text declares internal need not exist).
  Item 7, lint (DESIGN 8.2 "`it` blocks at most two instructions"): longer IT blocks are violations except in the objects
    under rt/, which keep the v2.05 sequences whose later conditional instructions test flags set inside the block.
  Item 6, test infrastructure (not in DESIGN 9.3): IT blocks in which a load is followed by an instruction of the opposite
    condition.  Unicorn 2.1.4 skips an instruction after such a block when a memory-read hook is installed (reproduced and
    characterised, see Checker.check_it_blocks).  No emulator component installs a read hook in normal runs (the MPU model
    installs one only when a region can deny a read), so the blocks are listed as notes; --strict-it turns them into
    violations for runs that do use a read hook.

Analysis mode (--v205 BIN): the same instruction analysis on the original image (base 0x08006000, code ranges from
analysis/decompile/bytemap.txt, no objects, so no object is allowed to use the FLASH registers).  The expected result
is FAIL with the option-byte and key accesses of the original firmware (FLASH_OPTKEYR, FLASH_OBR and the OPTKEY
values, DESIGN 3.1 / EEPROM_MAP 2.4); it shows that the checker finds what it exists to find.

Roles of objects (from the linker map): "nvm" = any object in a directory named nvm; "sysclock" = sys/clock.o;
"mpuguard" = sys/reset.o.  Without a map file every code address has no role, so the NVM and clock code fail:
a missing map is never a silent pass.
"""
import argparse
import bisect
import os
import re
import struct
import sys

try:
    import capstone
    from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS
    from capstone.arm import (ARM_OP_REG, ARM_OP_IMM, ARM_OP_MEM, ARM_CC_AL, ARM_CC_INVALID)
except ImportError:                                           # pragma: no cover - environment problem
    sys.stderr.write('check_image.py: the Python module capstone is required\n')
    sys.exit(2)

# ---------------------------------------------------------------------------------------------------- constants
APP_BASE = 0x08006000
IMAGE_MAX = 0x5A000
INITIAL_SP = 0x20001240
N_VECTORS = 73
RESERVED_VECTORS = (7, 8, 9, 10, 13)

FLASH_IF = 0x40023C00                       # FLASH interface block 0x40023C00..0x40023FFF (RM0038 memory map)
FLASH_IF_END = 0x40024000
FLASH_ACR, FLASH_PECR, FLASH_PEKEYR, FLASH_SR = 0x40023C00, 0x40023C04, 0x40023C0C, 0x40023C18
# allowed register -> (name, role that may address it)
FLASH_ALLOWED = {FLASH_ACR: ('FLASH_ACR', 'sysclock'), FLASH_PECR: ('FLASH_PECR', 'nvm'),
                 FLASH_PEKEYR: ('FLASH_PEKEYR', 'nvm'), FLASH_SR: ('FLASH_SR', 'nvm')}
FLASH_NAMES = {0x40023C08: 'FLASH_PDKEYR', 0x40023C10: 'FLASH_PRGKEYR', 0x40023C14: 'FLASH_OPTKEYR',
               0x40023C1C: 'FLASH_OBR', 0x40023C20: 'FLASH_WRPR1', 0x40023C28: 'FLASH_WRPR2', 0x40023C2C: 'FLASH_WRPR3'}
PECR_PELOCK, PECR_FTDW = 0x1, 0x100                         # RM0038 3.9.2
ACR_BITS = 0x7                                              # LATENCY 1, PRFTEN 2, ACC64 4 (RM0038 3.9.1)
OPT_FIRST, OPT_LAST = 0x1FF80000, 0x1FF800FF
BB_FLASH_FIRST = 0x42000000 + (FLASH_IF - 0x40000000) * 32  # bit-band alias of the FLASH block (RM0038 / PM0056)
BB_FLASH_LAST = 0x42000000 + (FLASH_IF_END - 0x40000000) * 32 - 1
PFLASH_FIRST, PFLASH_LAST = 0x08000000, 0x0809FFFF          # program flash window + EEPROM window; stores rejected
EEPROM_FIRST, EEPROM_LAST = 0x08080000, 0x08082FFF
MPU_RBAR = 0xE000ED9C
SCS_BASE = 0xE000E000
KEYS_FORBIDDEN = {0x8C9DAEBF: 'PRGKEY1', 0x13141516: 'PRGKEY2', 0xFBEAD9C8: 'OPTKEY1', 0x24252627: 'OPTKEY2',
                  0x04152637: 'PDKEY1', 0xFAFBFCFD: 'PDKEY2'}
KEYS_NVM = {0x89ABCDEF: 'PEKEY1', 0x02030405: 'PEKEY2'}
MPU_EXEMPT_VALUE = 0x1FF80000

REGNAMES = {'sp': 13, 'lr': 14, 'pc': 15, 'ip': 12, 'fp': 11, 'sl': 10, 'sb': 9}
for _i in range(13):
    REGNAMES['r%d' % _i] = _i
CALL_CLOBBER = (0, 1, 2, 3, 12, 14)
M32 = 0xFFFFFFFF

LOAD_PREFIX = ('ldr', 'ldm', 'pop', 'tbb', 'tbh')
STORE_PREFIX = ('str', 'stm', 'push')
CONDS = ('eq', 'ne', 'cs', 'hs', 'cc', 'lo', 'mi', 'pl', 'vs', 'vc', 'hi', 'ls', 'ge', 'lt', 'gt', 'le', 'al')
FLAGSET_BASES = ('mov', 'mvn', 'add', 'sub', 'adc', 'sbc', 'rsb', 'and', 'orr', 'eor', 'bic', 'orn', 'lsl', 'lsr', 'asr',
                 'ror', 'rrx', 'mul', 'neg', 'cmp')


class ToolError(Exception):
    """The tool cannot do its job (missing file, malformed ELF): exit status 2, never a pass."""


# ---------------------------------------------------------------------------------------------------- ELF reader
class Elf:
    """Minimal ELF32 little-endian reader: sections, program headers, symbols."""

    def __init__(self, path):
        d = self.data = open(path, 'rb').read()
        if d[:4] != b'\x7fELF' or d[4] != 1 or d[5] != 1:
            raise ToolError('%s is not a 32-bit little-endian ELF file' % path)
        (self.e_type, self.e_machine, _v, self.entry, self.phoff, self.shoff, _fl, _eh, self.phentsize, self.phnum,
         self.shentsize, self.shnum, self.shstrndx) = struct.unpack_from('<HHIIIIIHHHHHH', d, 16)
        if self.e_machine != 40:
            raise ToolError('%s is not an ARM ELF file' % path)
        self.segments = []
        for i in range(self.phnum):
            p_type, p_off, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, _al = struct.unpack_from(
                '<IIIIIIII', d, self.phoff + i * self.phentsize)
            self.segments.append(dict(type=p_type, off=p_off, vaddr=p_vaddr, paddr=p_paddr, filesz=p_filesz,
                                      memsz=p_memsz, flags=p_flags))
        self.sections = []
        for i in range(self.shnum):
            n, t, fl, a, o, sz, lk, inf, _al, es = struct.unpack_from('<IIIIIIIIII', d, self.shoff + i * self.shentsize)
            self.sections.append(dict(nameoff=n, type=t, flags=fl, addr=a, off=o, size=sz, link=lk, info=inf,
                                      entsize=es))
        shstr = self.sections[self.shstrndx]
        for s in self.sections:
            s['name'] = self._cstr(shstr['off'] + s['nameoff'])
        self.symbols = []
        for s in self.sections:
            if s['type'] == 2:                               # SHT_SYMTAB
                strtab = self.sections[s['link']]
                for k in range(s['size'] // 16):
                    nm, val, sz, info, other, shndx = struct.unpack_from('<IIIBBH', d, s['off'] + 16 * k)
                    self.symbols.append(dict(name=self._cstr(strtab['off'] + nm), value=val, size=sz, bind=info >> 4,
                                             type=info & 15, shndx=shndx))

    def _cstr(self, off):
        e = self.data.index(b'\0', off)
        return self.data[off:e].decode('ascii', 'replace')

    def flash_loads(self):
        """(load address, bytes) of every program-header segment whose load address lies in program flash."""
        out = []
        for s in self.segments:
            if s['type'] == 1 and s['filesz'] and PFLASH_FIRST <= s['paddr'] <= PFLASH_LAST:
                out.append((s['paddr'], self.data[s['off']:s['off'] + s['filesz']]))
        return sorted(out)


# ---------------------------------------------------------------------------------------------------- linker map
def parse_map(path):
    """Intervals (start, end, object path) of the input sections in the output sections .text and .rodata of a GNU ld
    map.  A long section name may sit alone on one line with address, size and file on the next."""
    if not path or not os.path.isfile(path):
        return None
    iv = []
    pending = None
    in_alloc = False
    for line in open(path, errors='replace'):
        m = re.match(r'^(\.\S+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s*$', line)       # output section header
        if m:
            in_alloc = True
            continue
        m = re.match(r'^ (\.\S+)\s*$', line)
        if m:
            pending = m.group(1)
            continue
        m = re.match(r'^ (\.\S+)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S+)\s*$', line)
        if m:
            name, addr, size, obj = m.group(1), int(m.group(2), 16), int(m.group(3), 16), m.group(4)
            pending = None
        else:
            m = re.match(r'^\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S+)\s*$', line)
            if m and pending:
                name, addr, size, obj = pending, int(m.group(1), 16), int(m.group(2), 16), m.group(3)
                pending = None
            else:
                continue
        if size and 0x08000000 <= addr < 0x08100000:
            iv.append((addr, addr + size, obj, name))
    iv.sort()
    return iv


def role_of_object(obj):
    """Role of an object file path: nvm, sysclock, mpuguard or None."""
    parts = obj.replace('\\', '/').split('/')
    if 'nvm' in parts[:-1]:
        return 'nvm'
    if parts[-2:] == ['sys', 'clock.o']:
        return 'sysclock'
    if parts[-2:] == ['sys', 'reset.o']:
        return 'mpuguard'
    return None


# ---------------------------------------------------------------------------------------------------- image model
class Image:
    """What the analysis needs: bytes by address, code ranges, function starts, object roles, symbol names."""

    def __init__(self):
        self.loads = []                  # (address, bytes) in ascending order
        self.code = []                   # (start, end) decoded as Thumb code
        self.pools = []                  # (start, end) literal pools: data ranges inside executable sections
        self.entries = {}                # address -> name (function entries, analysis start points)
        self.names = []                  # sorted (address, name) for 'function+offset' reports
        self.mapiv = None                # linker map intervals or None
        self.mapkeys = []
        self.symbols = []                # ELF symbol dicts (for item 5)
        self.kind = 'elf'

    def read(self, addr, n):
        for base, data in self.loads:
            if base <= addr and addr + n <= base + len(data):
                return data[addr - base:addr - base + n]
        return None

    def end(self):
        return max(b + len(d) for b, d in self.loads)

    def finish(self):
        self.names.sort()
        self._nameaddrs = [a for a, _ in self.names]
        if self.mapiv:
            self.mapkeys = [s for s, _e, _o, _n in self.mapiv]

    def where(self, addr):
        i = bisect.bisect_right(self._nameaddrs, addr) - 1
        if i < 0:
            return '0x%08X' % addr
        a, n = self.names[i]
        return '%s+0x%X' % (n, addr - a) if addr != a else n

    def obj_at(self, addr):
        """Object path whose input section contains addr, or None."""
        if not self.mapiv:
            return None
        i = bisect.bisect_right(self.mapkeys, addr) - 1
        while i >= 0:
            s, e, o, _n = self.mapiv[i]
            if s <= addr < e:
                return o
            if addr - s > 0x10000:
                break
            i -= 1
        return None

    def role_at(self, addr):
        o = self.obj_at(addr)
        return role_of_object(o) if o else None


def load_elf_image(path, mappath):
    elf = Elf(path)
    img = Image()
    img.loads = elf.flash_loads()
    if not img.loads:
        raise ToolError('%s has no loadable segment in program flash' % path)
    img.symbols = elf.symbols
    # code ranges from the mapping symbols $t / $d of the executable sections (ARM ELF ABI)
    for idx, s in enumerate(elf.sections):
        if not (s['flags'] & 4) or s['type'] != 1 or not s['size']:      # SHF_EXECINSTR, SHT_PROGBITS
            continue
        marks = sorted((y['value'] & ~1, 't' if y['name'].startswith('$t') else 'd') for y in elf.symbols
                       if y['shndx'] == idx and re.match(r'\$[td](\.\d+)?$', y['name']))
        end = s['addr'] + s['size']
        if not marks:
            img.code.append((s['addr'], end))
            continue
        if marks[0][0] > s['addr']:
            marks.insert(0, (s['addr'], 't'))
        for k, (a, kind) in enumerate(marks):
            b = marks[k + 1][0] if k + 1 < len(marks) else end
            if kind == 'd' and b > a:
                img.pools.append((a, b))
            if kind == 't' and b > a:
                if img.code and img.code[-1][1] == a:
                    img.code[-1] = (img.code[-1][0], b)
                else:
                    img.code.append((a, b))
    code_starts = [a for a, _ in img.code]
    for y in elf.symbols:
        if y['shndx'] == 0 or y['shndx'] >= 0xFF00 or not y['name'] or y['name'].startswith('$'):
            continue
        if y['type'] in (0, 2) and y['name'] and PFLASH_FIRST <= (y['value'] & ~1) <= PFLASH_LAST:
            a = y['value'] & ~1
            i = bisect.bisect_right(code_starts, a) - 1
            if i >= 0 and img.code[i][0] <= a < img.code[i][1]:
                if y['type'] == 2 or y['name'] not in img.entries.values():
                    img.entries.setdefault(a, y['name'])
                img.names.append((a, y['name']))
    img.mapiv = parse_map(mappath)
    img.finish()
    return img, elf


def load_v205_image(binpath, base, bytemap):
    img = Image()
    img.kind = 'v205'
    data = open(binpath, 'rb').read()
    img.loads = [(base, data)]
    for line in open(bytemap):
        p = line.split()
        if len(p) >= 4 and p[2] in ('data', 'padding'):
            img.pools.append((int(p[0], 16), int(p[1], 16) + 1))
        if len(p) >= 4 and p[2] == 'code':
            a, b = int(p[0], 16), int(p[1], 16) + 1
            if img.code and img.code[-1][1] == a:
                img.code[-1] = (img.code[-1][0], b)
            else:
                img.code.append((a, b))
            img.entries[a] = p[3]
            img.names.append((a, p[3]))
    img.finish()
    return img


# ---------------------------------------------------------------------------------------------------- decoding
class Ins:
    """One decoded instruction with the facts the analysis needs."""
    __slots__ = ('addr', 'size', 'op', 'cc', 'raw', 'cond', 'regs_w', 'wb', 'post')

    def __init__(self, cs_insn, md):
        self.raw = cs_insn
        self.addr = cs_insn.address
        self.size = cs_insn.size
        self.cc = cs_insn.cc
        self.cond = self.cc not in (ARM_CC_AL, ARM_CC_INVALID)
        mn = cs_insn.mnemonic.lower().split('.')[0]
        if self.cond and mn != 'it' and not (mn.startswith('b') and len(mn) <= 4 and mn[1:] in CONDS) and \
                len(mn) > 2 and mn[-2:] in CONDS:
            mn = mn[:-2]                                    # conditional execution suffix inside an IT block
        if cs_insn.update_flags and mn.endswith('s') and mn[:-1] in FLAGSET_BASES:
            mn = mn[:-1]
        self.op = mn
        self.regs_w = [REGNAMES[cs_insn.reg_name(r)] for r in cs_insn.regs_access()[1]
                       if cs_insn.reg_name(r) in REGNAMES]
        self.wb = cs_insn.writeback
        self.post = getattr(cs_insn, 'post_index', False)


def decode_ranges(img):
    """Decode every code range; returns (sorted list of Ins, undecodable byte ranges)."""
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
    md.detail = True
    out = []
    bad = []
    for a, b in img.code:
        code = img.read(a, b - a)
        if code is None:
            raise ToolError('code range 0x%08X..0x%08X is not in the loaded image' % (a, b))
        pos = a
        while pos < b:
            n = 0
            for ci in md.disasm(code[pos - a:], pos):
                out.append(Ins(ci, md))
                n += 1
                pos = ci.address + ci.size
            if pos < b:                                     # Capstone stopped: not decodable
                bad.append((pos, min(b, pos + 2)))
                pos += 2
    return out, bad


# ---------------------------------------------------------------------------------------------------- values
# A register value is None (unknown), ('c', const, tag) or ('l', address, set_mask, clear_mask): the word read from
# `address` with `set_mask` ORed in and `clear_mask` cleared.  `tag` is None or 'mpu' (see MPU_EXEMPT_VALUE).
def const(v, tag=None):
    return ('c', v & M32, tag)


def join_states(a, b):
    """Meet of two register states: only equal values survive."""
    return {r: v for r, v in a.items() if b.get(r) == v}


class Checker:
    def __init__(self, img):
        self.img = img
        self.v = []                          # (addr, id, message)
        self.seen = set()
        self.facts = {'insns': 0, 'blocks': 0, 'loads': 0, 'stores': 0, 'loads_known': 0, 'stores_known': 0,
                      'flash_accesses': {}, 'literals': 0}
        self.collect = False
        self.long_it = []                    # (address, mnemonic) of IT blocks of more than two instructions
        self.observers = []                  # callables(ins, role, is_store, ea, span, value, op, multi): known-address accesses

    # --- reporting
    def violation(self, addr, vid, msg):
        if not self.collect:
            return
        key = (addr, vid, msg)
        if key not in self.seen:
            self.seen.add(key)
            self.v.append(key)

    # --- constants census
    def classify_const(self, value, role, tag=None):
        """None when the constant is acceptable for code of `role`, else the reason."""
        if FLASH_IF <= value < FLASH_IF_END:
            ent = FLASH_ALLOWED.get(value)
            nm = FLASH_NAMES.get(value, 'FLASH interface address 0x%08X' % value)
            if ent is None:
                return '%s is not on the allowed FLASH register list (FLASH_ACR, FLASH_PECR, FLASH_PEKEYR, FLASH_SR)' % nm
            if role != ent[1]:
                return '%s outside its object (%s only)' % (ent[0], 'sys/clock.o' if ent[1] == 'sysclock' else 'objects under nvm/')
            return None
        if OPT_FIRST <= value <= OPT_LAST:
            if tag == 'mpu' and role == 'mpuguard':
                return None
            return 'option-byte area address 0x%08X' % value
        if BB_FLASH_FIRST <= value <= BB_FLASH_LAST:
            return 'bit-band alias of the FLASH interface block'
        if value in KEYS_FORBIDDEN:
            return 'FLASH key value %s 0x%08X' % (KEYS_FORBIDDEN[value], value)
        if value in KEYS_NVM and role != 'nvm':
            return 'data-EEPROM key value %s outside the NVM objects' % KEYS_NVM[value]
        if EEPROM_FIRST <= value <= EEPROM_LAST and role != 'nvm':
            return 'data EEPROM address 0x%08X outside the NVM objects' % value
        return None

    # --- test-infrastructure hazard: loads inside IT blocks (module docstring, item 6)
    def check_it_blocks(self, insns):
        """Unicorn 2.1.4 (the emulator) mishandles the IT state after a load that is followed, inside the same IT block,
        by an instruction of the opposite condition, when a memory-read hook is installed: the instruction after the
        first one that follows the block is skipped.  Reproduced with `ite eq; ldreq r0,[r2]; movne r0,#1; bx lr` and with
        the case of firmware/requests/W5_to_W10.md item 2; an enumeration of all IT shapes up to four instructions with
        every load position and both flag outcomes failed exactly when a load that executes is followed in the block by
        an instruction of the other condition (it, itt, ittt and a load in the last position never failed).  Returns the
        list of (address, text) of such blocks; a block of one instruction cannot be affected."""
        out = []
        n = 0
        k = 0
        while k < len(insns):
            i = insns[k]
            mn = i.raw.mnemonic.lower()
            if re.fullmatch(r'it[te]{0,3}', mn):
                length = len(mn) - 1                          # it = 1, ite / itt = 2, ittt / itte ... = 3 or 4
                blk = insns[k + 1:k + 1 + length]
                letters = 't' + mn[2:]                        # condition of each instruction: t = as written, e = inverse
                n += 1
                if length > 2:
                    self.long_it.append((i.addr, mn))
                for q in range(len(blk) - 1):
                    if blk[q].op.startswith(LOAD_PREFIX) and letters[q] != letters[q + 1]:
                        out.append((blk[q].addr, '%s: %s followed by %s' % (mn, blk[q].raw.mnemonic, blk[q + 1].raw.mnemonic)))
                k += 1 + length
                continue
            k += 1
        self.facts['it_blocks'] = n
        return out

    # --- the analysis
    def run(self, insns):
        img = self.img
        self.insns = insns
        addrs = [i.addr for i in insns]
        self.index = {a: k for k, a in enumerate(addrs)}
        entries = set(img.entries)
        leaders = set(entries)
        succ_cache = {}
        targets_of_tbl = {}
        for k, ins in enumerate(insns):
            nxt = insns[k + 1].addr if k + 1 < len(insns) else None
            op = ins.op
            raw = ins.raw
            ends = False
            tg = []
            if op in ('b', 'cbz', 'cbnz') and raw.operands and raw.operands[-1].type == ARM_OP_IMM:
                tg.append(raw.operands[-1].imm)
                leaders.add(raw.operands[-1].imm)
                if op != 'b' or ins.cond:
                    if nxt is not None:
                        leaders.add(nxt)
                else:
                    ends = True
            elif op in ('bx',) or (op in ('pop', 'ldm', 'ldr', 'mov') and 15 in ins.regs_w) or op in ('tbb', 'tbh'):
                ends = True
                if op in ('tbb', 'tbh'):
                    tg.extend(self.table_targets(ins))
                    for t in tg:
                        leaders.add(t)
            if ends and nxt is not None:
                leaders.add(nxt)
            succ_cache[ins.addr] = (tg, ends, op in ('b', 'cbz', 'cbnz', 'bx', 'tbb', 'tbh') or ends)
        # blocks
        starts = sorted(a for a in leaders if a in self.index)
        blocks = []
        for n, a in enumerate(starts):
            k0 = self.index[a]
            k1 = self.index[starts[n + 1]] if n + 1 < len(starts) else len(insns)
            blocks.append((k0, k1))
        self.facts['blocks'] = len(blocks)
        self.facts['insns'] = len(insns)
        bidx = {insns[k0].addr: n for n, (k0, k1) in enumerate(blocks)}
        # forward dataflow: in-state per block (None = not reached yet)
        in_state = [None] * len(blocks)
        for n, (k0, k1) in enumerate(blocks):
            if insns[k0].addr in entries:
                in_state[n] = {}
        work = list(range(len(blocks)))
        guard = 0
        while work:
            guard += 1
            if guard > 200 * len(blocks) + 1000:
                raise ToolError('constant propagation did not converge')
            n = work.pop(0)
            if in_state[n] is None:
                continue
            k0, k1 = blocks[n]
            self.collect = False
            out = self.run_block(k0, k1, dict(in_state[n]))
            last = insns[k1 - 1]
            tg, ends, _t = succ_cache[last.addr]
            nexts = [t for t in tg if t in bidx]
            fall = (not ends) or (last.op in ('b', 'cbz', 'cbnz') and (last.cond or last.op != 'b'))
            if fall and k1 < len(insns):
                nexts.append(insns[k1].addr)
            for t in nexts:
                m = bidx.get(t)
                if m is None:
                    continue
                new = out if in_state[m] is None else join_states(in_state[m], out)
                if in_state[m] is None or new != in_state[m]:
                    in_state[m] = new
                    if m not in work:
                        work.append(m)
        # final pass: collect findings once with the converged states
        self.collect = True
        for n, (k0, k1) in enumerate(blocks):
            st = in_state[n]
            self.run_block(k0, k1, dict(st) if st is not None else {})

    def table_targets(self, ins):
        """Branch targets of a TBB / TBH: the entries of the data range that follows the instruction."""
        base = ins.addr + 4
        half = ins.op == 'tbh'
        out = []
        pos = base
        # the table ends where code resumes; entries are limited to a sane count, targets beyond the image are ignored
        for _ in range(256):
            raw = self.img.read(pos, 2 if half else 1)
            if raw is None:
                break
            e = int.from_bytes(raw, 'little')
            t = base + 2 * e
            if self.img.read(t, 2) is not None:
                out.append(t)
            pos += 2 if half else 1
            if any(a <= pos < b for a, b in self.img.code):
                break
        return out

    # --- one basic block
    def run_block(self, k0, k1, st):
        for k in range(k0, k1):
            st = self.step(self.insns[k], st)
        return st

    def val_of(self, st, reg, ins=None):
        if reg == 15:
            return const((ins.addr + 4) & M32)
        if reg == 13:
            return None
        return st.get(reg)

    def set_reg(self, st, reg, val, ins):
        if reg == 13 or reg == 15:
            return
        if val is None or ins.cond:
            st.pop(reg, None)
            return
        st[reg] = val
        if val[0] == 'c':
            msg = self.classify_const(val[1], self.img.role_at(ins.addr), val[2])
            if msg:
                self.violation(ins.addr, 'CONST', 'produces constant 0x%08X: %s' % (val[1], msg))

    def step(self, ins, st):
        raw, op = ins.raw, ins.op
        ops = raw.operands
        role = self.img.role_at(ins.addr)
        # exemption bookkeeping: a register holding the MPU exemption constant may only be stored to MPU_RBAR
        exempt_regs = [r for r, v in st.items() if v[0] == 'c' and v[2] == 'mpu']
        uses_exempt = False
        if exempt_regs:
            reads = [REGNAMES[raw.reg_name(r)] for r in raw.regs_access()[0] if raw.reg_name(r) in REGNAMES]
            uses_exempt = any(r in exempt_regs for r in reads)
        if re.fullmatch(r'it[te]{0,3}', raw.mnemonic.lower()):
            return st
        if op.startswith(LOAD_PREFIX) or op.startswith(STORE_PREFIX):
            st = self.mem_op(ins, st, role, exempt_regs, uses_exempt)
            return st
        if uses_exempt:
            self.violation(ins.addr, 'MPU-EXEMPT', '%s uses the register that holds 0x%08X other than as the data of a '
                           'store to MPU_RBAR' % (raw.mnemonic, MPU_EXEMPT_VALUE))
        if op in ('bl', 'blx'):
            for r in CALL_CLOBBER:
                st.pop(r, None)
            return st
        if op in ('cmp', 'cmn', 'tst', 'teq', 'nop', 'b', 'bx', 'cbz', 'cbnz', 'cpsid', 'cpsie', 'dsb', 'dmb', 'isb',
                  'wfi', 'wfe', 'sev', 'svc', 'bkpt', 'msr'):
            return st
        d = self.alu(ins, st, ops, op)
        written = ins.regs_w
        if d is not False:
            dst, val = d
            for r in written:
                if r != dst:
                    st.pop(r, None)
            self.set_reg(st, dst, val, ins)
            return st
        for r in written:
            st.pop(r, None)
        return st

    # --- data processing: returns (dest reg, value) or False when not modelled
    def alu(self, ins, st, ops, op):
        raw = ins.raw
        if not ops or ops[0].type != ARM_OP_REG:
            return False
        dst = REGNAMES.get(raw.reg_name(ops[0].reg))
        if dst is None:
            return False

        def rv(o):
            if o.type == ARM_OP_IMM:
                return const(o.imm)
            if o.type == ARM_OP_REG:
                if getattr(o, 'shift', None) is not None and getattr(o.shift, 'type', 0):
                    return None
                n = REGNAMES.get(raw.reg_name(o.reg))
                return self.val_of(st, n, ins) if n is not None else None
            return None
        if op in ('mov', 'movw') and len(ops) == 2:
            return dst, rv(ops[1])
        if op == 'mvn' and len(ops) == 2:
            v = rv(ops[1])
            return dst, (const(~v[1]) if v and v[0] == 'c' else None)
        if op == 'movt' and len(ops) == 2:
            hi = ops[1].imm & 0xFFFF
            old = st.get(dst)
            if hi == 0x1FF8:
                self.violation(ins.addr, 'MOVT', 'movt produces 0x1FF8 (option-byte area high half)')
            if old and old[0] == 'c':
                return dst, const((old[1] & 0xFFFF) | (hi << 16))
            if hi == 0x4002:
                self.violation(ins.addr, 'MOVT', 'movt produces 0x4002 over a low half that is not a known constant '
                               'in this function: the result could address the FLASH interface block')
            return dst, None
        if op in ('add', 'sub', 'addw', 'subw', 'adc', 'sbc', 'rsb') and len(ops) in (2, 3):
            if op in ('adc', 'sbc', 'rsb'):
                return dst, None
            a, b = (ops[0], ops[1]) if len(ops) == 2 else (ops[1], ops[2])
            va = rv(a) if a.type == ARM_OP_IMM or a.type == ARM_OP_REG else None
            if a.type == ARM_OP_REG and REGNAMES.get(raw.reg_name(a.reg)) == 15 and b.type == ARM_OP_IMM:
                va = const((ins.addr + 4) & ~3 & M32)          # ADR form: Align(PC, 4)
            vb = rv(b)
            if va and vb and va[0] == 'c' and vb[0] == 'c':
                r = va[1] + vb[1] if op.startswith('add') else va[1] - vb[1]
                return dst, const(r, None)
            if va and va[0] == 'l' and vb and vb[0] == 'c':
                return dst, None
            return dst, None
        if op in ('orr', 'and', 'bic', 'eor') and len(ops) in (2, 3):
            a, b = (ops[0], ops[1]) if len(ops) == 2 else (ops[1], ops[2])
            va, vb = rv(a), rv(b)
            if va and vb and va[0] == 'c' and vb[0] == 'c':
                x, y = va[1], vb[1]
                r = {'orr': x | y, 'and': x & y, 'bic': x & ~y, 'eor': x ^ y}[op]
                return dst, const(r)
            if va and va[0] == 'l' and vb and vb[0] == 'c' and b.type == ARM_OP_IMM:
                _k, ad, s, c = va
                m = vb[1]
                if op == 'orr':
                    return dst, ('l', ad, s | m, c & ~m & M32)
                if op == 'bic':
                    return dst, ('l', ad, s & ~m & M32, c | m)
                if op == 'and':
                    return dst, ('l', ad, s & m, c | (~m & M32))
            return dst, None
        if op in ('lsl', 'lsr', 'asr', 'ror') and len(ops) == 3 and ops[2].type == ARM_OP_IMM:
            va = rv(ops[1])
            if va and va[0] == 'c':
                x, n = va[1], ops[2].imm
                if op == 'lsl':
                    r = x << n
                elif op == 'lsr':
                    r = x >> n
                elif op == 'asr':
                    r = (x - (1 << 32) if x & 0x80000000 else x) >> n
                else:
                    r = ((x >> n) | (x << (32 - n))) if n else x
                return dst, const(r)
            return dst, None
        return False

    # --- loads and stores
    def mem_op(self, ins, st, role, exempt_regs, uses_exempt):
        raw, op = ins.raw, ins.op
        ops = raw.operands
        is_store = op.startswith(STORE_PREFIX)
        is_load = not is_store
        base_reg = None
        ea = None
        size = 4
        count = 1
        disp = 0
        has_index = False
        base_val = None
        data_reg = None
        reg_ops = []
        multi = op.startswith(('ldm', 'stm')) and not op.startswith(('ldrm',))
        post_imm = None
        if op in ('push', 'pop'):
            # SP-relative stack traffic: the stack is in RAM; only the loaded registers change
            for o in ops:
                if o.type == ARM_OP_REG:
                    n = REGNAMES.get(raw.reg_name(o.reg))
                    if is_load and n is not None:
                        st.pop(n, None)
            if uses_exempt and is_store:
                self.violation(ins.addr, 'MPU-EXEMPT', 'push of the register that holds 0x%08X' % MPU_EXEMPT_VALUE)
            return st
        if op in ('tbb', 'tbh'):
            return st
        if multi:
            n0 = ops[0]
            base_reg = REGNAMES.get(raw.reg_name(n0.reg))
            reg_ops = [REGNAMES.get(raw.reg_name(o.reg)) for o in ops[1:] if o.type == ARM_OP_REG]
            count = len(reg_ops)
            base_val = self.val_of(st, base_reg, ins) if base_reg is not None else None
            if base_val and base_val[0] == 'c':
                ea = base_val[1] - (4 * count if 'db' in op else 0)
            size = 4 * count
        else:
            mem = None
            memop = None
            regs = []
            for o in ops:
                if o.type == ARM_OP_MEM:
                    mem = o.mem
                    memop = o
                elif o.type == ARM_OP_REG:
                    regs.append(REGNAMES.get(raw.reg_name(o.reg)))
                elif o.type == ARM_OP_IMM:
                    post_imm = o.imm
            if mem is None:
                # exclusive forms or unrecognised operand layout: be conservative
                for r in ins.regs_w:
                    st.pop(r, None)
                return st
            data_reg = regs[0] if regs else None
            reg_ops = regs
            if 'd' in op[3:] and op.startswith(('ldrd', 'strd')):
                size = 8
            elif op.endswith(('b', 'sb')) and not op.startswith('ldrex'):
                size = 1
            elif op.endswith(('h', 'sh')):
                size = 2
            base_reg = REGNAMES.get(raw.reg_name(mem.base)) if mem.base else None
            base_val = self.val_of(st, base_reg, ins) if base_reg is not None else None
            has_index = bool(mem.index)
            disp = mem.disp
            if mem.base and base_reg == 15:
                base_val = const((ins.addr + 4) & ~3 & M32)
            if base_val and base_val[0] == 'c':
                ea = base_val[1]
                if not ins.post:
                    ea += disp
                if has_index:
                    iv = self.val_of(st, REGNAMES.get(raw.reg_name(mem.index)), ins)
                    if iv and iv[0] == 'c':
                        off = iv[1] << (mem.lshift or 0)
                        ea += -off if memop.subtracted else off
                    else:
                        ea = None
                ea = ea & M32 if ea is not None else None
        # statistics
        self.facts['stores' if is_store else 'loads'] += 1
        if ea is not None:
            self.facts['stores_known' if is_store else 'loads_known'] += 1
        # exemption: the exempt register may only be the data of a word store to MPU_RBAR
        if uses_exempt:
            ok = (is_store and op == 'str' and ea == MPU_RBAR and data_reg in exempt_regs and
                  base_reg not in exempt_regs)
            if not ok:
                self.violation(ins.addr, 'MPU-EXEMPT', '%s uses the register that holds 0x%08X other than as the data of '
                               'a store to MPU_RBAR' % (raw.mnemonic, MPU_EXEMPT_VALUE))
        if ea is not None:
            span = size if not multi else 4 * count
            self.check_access(ins, role, is_store, ea, span, base_val, disp, has_index, post_imm, st, data_reg, op, multi)
        # register results
        if is_load:
            if multi:
                for r in reg_ops:
                    st.pop(r, None)
            else:
                val = None
                if ea is not None and op == 'ldr' and not has_index and not ins.cond:
                    if base_reg == 15:
                        w = self.img.read(ea, 4)
                        if w is not None:
                            lit = int.from_bytes(w, 'little')
                            # the literal 0x1FF80000 of sys_mpu_guard carries the exemption tag (module docstring)
                            val = const(lit, 'mpu' if lit == MPU_EXEMPT_VALUE and role == 'mpuguard' else None)
                            self.facts['literals'] += 1
                    elif ea >= 0x40000000:                    # a word read from a peripheral address: tracked for the
                        val = ('l', ea, 0, 0)               # read-modify-write analysis of FLASH_PECR / FLASH_ACR
                for r in (reg_ops[:2] if op.startswith('ldrd') else reg_ops[:1]):
                    self.set_reg(st, r, val if r == reg_ops[0] else None, ins)
        elif op.startswith('strex') and reg_ops:
            st.pop(reg_ops[0], None)                         # status register
        # base register update
        if ins.wb and base_reg is not None and base_reg != 15:
            if base_val and base_val[0] == 'c':
                if multi:
                    nv = base_val[1] + (-4 * count if 'db' in op else 4 * count)
                elif ins.post:
                    nv = base_val[1] + (post_imm or 0)
                else:
                    nv = base_val[1] + disp
                self.set_reg(st, base_reg, const(nv), ins)
            else:
                st.pop(base_reg, None)
        return st

    def check_access(self, ins, role, is_store, ea, span, base_val, disp, has_index, post_imm, st, data_reg, op, multi):
        addr = ins.addr
        kind = 'store' if is_store else 'load'
        last = ea + span - 1
        words = range(ea & ~3, (last & ~3) + 1, 4)
        for w in words:
            if BB_FLASH_FIRST <= w <= BB_FLASH_LAST:
                self.violation(addr, 'BITBAND', '%s through the bit-band alias 0x%08X of the FLASH interface block' % (kind, w))
            if OPT_FIRST <= w <= OPT_LAST:
                self.violation(addr, 'OPTBYTE', '%s of 0x%08X in the option-byte area' % (kind, w))
        in_block = [w for w in words if FLASH_IF <= w < FLASH_IF_END]
        if in_block:
            for w in in_block:
                nm = FLASH_ALLOWED.get(w, (FLASH_NAMES.get(w, 'FLASH interface 0x%08X' % w), None))[0]
                cnt = self.facts['flash_accesses']
                key = (role or 'none', nm, kind)
                cnt[key] = cnt.get(key, 0) + 1
                msg = self.classify_const(w, role)
                if msg:
                    self.violation(addr, 'FLASHREG', '%s: %s' % (kind, msg))
            base_in_block = base_val and base_val[0] == 'c' and FLASH_IF <= base_val[1] < FLASH_IF_END
            if base_in_block and ((disp != 0 and not ins.post) or has_index):
                self.violation(addr, 'FLASHFORM', '%s of the FLASH interface block with base 0x%08X plus %s '
                               '(DESIGN 8.2: own literal and offset 0)' % (kind, base_val[1], 'a register offset' if has_index
                                                                           else 'offset %d' % disp))
            if base_in_block and (ins.wb or multi):
                self.violation(addr, 'FLASHFORM', '%s of the FLASH interface block by %s' % (kind, ins.raw.mnemonic))
            if is_store:
                self.check_flash_store(ins, ea, st, data_reg, op, multi)
        if self.observers and self.collect:
            dv = self.val_of(st, data_reg, ins) if data_reg is not None else None
            for f in self.observers:
                f(ins, role, is_store, ea, span, dv, op, multi)
        if is_store:
            for w in words:
                if PFLASH_FIRST <= w <= PFLASH_LAST:
                    if EEPROM_FIRST <= w <= EEPROM_LAST:
                        if role != 'nvm':
                            self.violation(addr, 'EEPROM', 'store to data EEPROM 0x%08X outside the NVM objects' % w)
                    else:
                        self.violation(addr, 'PFLASH', 'store to program flash / bootloader window 0x%08X' % w)
        else:
            for w in words:
                if EEPROM_FIRST <= w <= EEPROM_LAST and role != 'nvm':
                    self.violation(addr, 'EEPROM', 'load of data EEPROM 0x%08X outside the NVM objects' % w)

    def check_flash_store(self, ins, ea, st, data_reg, op, multi):
        addr = ins.addr
        if op != 'str' or multi:
            self.violation(addr, 'FLASHVAL', 'store to FLASH register 0x%08X by %s (only a single `str` is allowed)'
                           % (ea, ins.raw.mnemonic))
            return
        v = self.val_of(st, data_reg, ins) if data_reg is not None else None
        if ea == FLASH_PECR:
            ok = v is not None and v[0] == 'l' and v[1] == FLASH_PECR and (v[2] & ~PECR_PELOCK) == 0 and (v[3] & ~PECR_FTDW) == 0
            if not ok:
                self.violation(addr, 'PECR', 'store to FLASH_PECR of %s: only "the value just read, with PELOCK ORed in '
                               'and / or FTDW cleared" is allowed (value analysis)' % self.describe(v))
        elif ea == FLASH_PEKEYR:
            ok = v is not None and v[0] == 'c' and v[1] in KEYS_NVM
            if not ok:
                self.violation(addr, 'PEKEYR', 'store to FLASH_PEKEYR of %s: only the two PEKEY words are allowed' % self.describe(v))
        elif ea == FLASH_ACR:
            ok = v is not None and v[0] == 'l' and v[1] == FLASH_ACR and (v[2] & ~ACR_BITS) == 0 and v[3] == 0
            if not ok:
                self.violation(addr, 'ACR', 'store to FLASH_ACR of %s: only a read-modify-write setting LATENCY, PRFTEN or '
                               'ACC64 is allowed' % self.describe(v))
        elif ea == FLASH_SR:
            pass
        # any other FLASH register was already reported by classify_const

    @staticmethod
    def describe(v):
        if v is None:
            return 'a value that is not known'
        if v[0] == 'c':
            return 'the constant 0x%08X' % v[1]
        return 'the word read from 0x%08X with OR 0x%X, clear 0x%X' % (v[1], v[2], v[3])


# ---------------------------------------------------------------------------------------------------- census of data
def census_data(chk, img, insns_ranges):
    """Constants in the non-code bytes of the image.  The six FLASH key values are looked for at every byte offset of
    every non-code range; addresses of the FLASH interface block, the option-byte area and the bit-band alias of the
    FLASH block at every word-aligned offset; the data-EEPROM range only in literal pools (the `$d` ranges inside
    executable sections), because constant tables of the original firmware hold arbitrary 16-bit pairs that can look
    like 0x0808xxxx without being addresses."""
    code = img.code
    n = 0
    for base, data in img.loads:
        pos = 0
        end = len(data)
        # data = everything outside the code ranges
        segs = []
        cur = base
        for a, b in sorted(code):
            if b <= base or a >= base + end:
                continue
            if a > cur:
                segs.append((cur, a))
            cur = max(cur, b)
        if cur < base + end:
            segs.append((cur, base + end))
        for a, b in segs:
            for x in range(a, b - 3):
                w = int.from_bytes(data[x - base:x - base + 4], 'little')
                # keys are looked for at every byte offset, addresses only at word-aligned offsets (a pool word is
                # always aligned: `ldr rX, =value` loads from a 4-byte aligned literal)
                if not (w in KEYS_FORBIDDEN or w in KEYS_NVM or (not x & 3 and (
                        FLASH_IF <= w < FLASH_IF_END or OPT_FIRST <= w <= OPT_LAST or BB_FLASH_FIRST <= w <= BB_FLASH_LAST
                        or EEPROM_FIRST <= w <= EEPROM_LAST))):
                    continue
                if EEPROM_FIRST <= w <= EEPROM_LAST and not any(pa <= x < pb for pa, pb in img.pools):
                    continue                                  # a table word, not a literal
                n += 1
                role = img.role_at(x)
                tag = 'mpu' if (w == MPU_EXEMPT_VALUE and role == 'mpuguard') else None
                msg = chk.classify_const(w, role, tag)
                if msg:
                    chk.collect = True
                    chk.violation(x, 'POOL', 'data word 0x%08X: %s' % (w, msg))
    return n


# ---------------------------------------------------------------------------------------------------- item 1: image
def check_image_item1(img, elf, binpath, vio):
    facts = []
    data = open(binpath, 'rb').read()
    size = len(data)
    facts.append('image file: %d bytes (0x%X)' % (size, size))
    if size % 4:
        vio.append('IMG-1 size %d is not a multiple of 4' % size)
    if size > IMAGE_MAX:
        vio.append('IMG-1 size 0x%X exceeds 0x%X' % (size, IMAGE_MAX))
    if size < N_VECTORS * 4:
        vio.append('IMG-1 image is shorter than the vector table')
        return facts
    # the raw image equals the flash content of the ELF
    end = img.end()
    expect = bytearray(end - APP_BASE)
    for base, d in img.loads:
        expect[base - APP_BASE:base - APP_BASE + len(d)] = d
    pad = (-len(expect)) % 4
    expect += bytes(pad)
    if bytes(expect) != data:
        vio.append('IMG-1 the raw image differs from the loadable flash content of the ELF (%d bytes vs %d)' % (size, len(expect)))
    else:
        facts.append('raw image equals the loadable flash content of the ELF (end 0x%08X)' % end)
    vec = struct.unpack_from('<%dI' % N_VECTORS, data, 0)
    if vec[0] != INITIAL_SP:
        vio.append('IMG-2 vector 0 = 0x%08X, expected 0x%08X' % (vec[0], INITIAL_SP))
    if (vec[0] & 0x2FFE0000) != 0x20000000:
        vio.append('IMG-2 vector 0 0x%08X fails the bootloader test (SP & 0x2FFE0000) == 0x20000000' % vec[0])
    if not vec[1] & 1:
        vio.append('IMG-2 vector 1 (reset) 0x%08X has bit 0 clear' % vec[1])
    inside = lambda a: APP_BASE <= (a & ~1) < APP_BASE + size
    if not inside(vec[1]):
        vio.append('IMG-2 vector 1 (reset) 0x%08X is outside the image' % vec[1])
    n_ok = 0
    for i in range(1, N_VECTORS):
        w = vec[i]
        if i in RESERVED_VECTORS:
            if w != 0:
                vio.append('IMG-3 reserved vector %d = 0x%08X, expected 0' % (i, w))
            continue
        if not w & 1:
            vio.append('IMG-3 vector %d = 0x%08X has bit 0 clear' % (i, w))
            continue
        if not any(a <= (w & ~1) < b for a, b in img.code):
            vio.append('IMG-3 vector %d = 0x%08X does not point into code' % (i, w))
            continue
        n_ok += 1
    facts.append('vector table: %d vectors, %d handler vectors odd and inside code, reserved slots %s zero'
                 % (N_VECTORS, n_ok, RESERVED_VECTORS))
    return facts


def vector_instruction_starts(img, insns, vio):
    starts = {i.addr for i in insns}
    data = img.read(APP_BASE, N_VECTORS * 4)
    vec = struct.unpack_from('<%dI' % N_VECTORS, data, 0)
    for i in range(1, N_VECTORS):
        if i in RESERVED_VECTORS or not vec[i] & 1:
            continue
        if (vec[i] & ~1) not in starts:
            vio.append('IMG-3 vector %d = 0x%08X is not the start of a decoded instruction' % (i, vec[i]))


# ---------------------------------------------------------------------------------------------------- item 5: symbols
def appendix_c_names(design):
    """Symbols that DESIGN.md Appendix C.1 / C.2 lists: the second column of C.1 rows, the first column of C.2 rows.
    Returns (names, production_only): the C.2 rows whose text says "production" name routines that v2.05 does not have
    (DESIGN 3.5), for example lcd_commit_retry; this build must define them like every other listed name."""
    text = open(design, errors='replace').read()
    i1 = text.index('### C.1')
    i2 = text.index('### C.2')
    c1, c2 = text[i1:i2], text[i2:]
    names = []
    prod = set()
    for line in c1.splitlines():
        m = re.match(r'^\|\s*([0-9A-Fa-f]{8})\s*\|\s*`([^`]+)`\s*\|', line)
        if m:
            names.append(m.group(2))
    in_table = False
    for line in c2.splitlines():
        if line.startswith('|---'):
            in_table = True
            continue
        if not line.startswith('|'):
            in_table = False
            continue
        if not in_table:
            continue
        cell = line.split('|')[1]
        for m in re.finditer(r'`([A-Za-z_][A-Za-z0-9_]*)`', cell):
            names.append(m.group(1))
            if 'production' in line.lower():
                prod.add(m.group(1))
    return names, prod


def appendix_c_exceptions(design):
    """Names that the C.1 text itself says are not exported: the bullets of "Exceptions decided by this design" that say
    a routine "is / are internal to <module>" or "is no longer called".  Only the backticked names before that phrase
    count (the names after it are the replacement routines)."""
    text = open(design, errors='replace').read()
    i = text.index('Exceptions decided by this design:')
    block = []
    for line in text[i:].splitlines()[1:]:
        if line.startswith('- '):
            block.append(line[2:])
        elif line.startswith('  ') and block:
            block[-1] += ' ' + line.strip()
        else:
            break
    out = {}
    for bullet in block:
        m = re.search(r'\b(?:is|are) (?:internal to ([A-Z]+)|no longer called)', bullet)
        if m:
            reason = m.group(0)
            for n in re.findall(r'`([A-Za-z_][A-Za-z0-9_]*)`', bullet[:m.start()]):
                out[n] = reason
    return out


def check_symbols(img, design, vio):
    facts = []
    undefined = [y['name'] for y in img.symbols if y['shndx'] == 0 and y['name']]
    for nme in undefined:
        vio.append('SYM-1 undefined symbol %s' % nme)
    facts.append('undefined symbols: %d' % len(undefined))
    if not design or not os.path.isfile(design):
        vio.append('SYM-2 DESIGN.md not found at %s: Appendix C cannot be checked' % design)
        return facts
    names, prod = appendix_c_names(design)
    exempt = appendix_c_exceptions(design)
    count = {}
    for y in img.symbols:
        if y['shndx'] != 0 and y['name']:
            count[y['name']] = count.get(y['name'], 0) + 1
    missing = []
    dup = []
    for nme in sorted(set(names)):
        c = count.get(nme, 0)
        if c == 0:
            if nme not in exempt:
                missing.append(nme)
        elif c > 1:
            dup.append(nme)
    for nme in missing:
        vio.append('SYM-2 Appendix C symbol %s is not defined' % nme)
    for nme in dup:
        vio.append('SYM-2 Appendix C symbol %s is defined %d times' % (nme, count[nme]))
    ex_absent = sorted(n for n in exempt if n in names and count.get(n, 0) == 0)
    facts.append('Appendix C symbols: %d listed, %d defined exactly once, %d missing, %d defined more than once, %d not '
                 'exported by design (%s)' % (len(set(names)), sum(1 for n in set(names) if count.get(n, 0) == 1),
                                              len(missing), len(dup), len(ex_absent), ', '.join(ex_absent)))
    return facts


# ---------------------------------------------------------------------------------------------------- main
def main(argv):
    ap = argparse.ArgumentParser(description='image, never-brick and symbol checks (DESIGN.md 9.3 items 1, 2, 5)')
    ap.add_argument('elf', nargs='?')
    ap.add_argument('bin', nargs='?')
    ap.add_argument('--map')
    ap.add_argument('--design', default='DESIGN.md')
    ap.add_argument('--strict-it', action='store_true', help='report IT blocks that trigger the Unicorn read-hook defect as violations')
    ap.add_argument('--switch', action='append', default=[], help='a build switch NAME=value as the Makefile passes it')
    ap.add_argument('--v205', help='analysis mode: check the original image (raw binary)')
    ap.add_argument('--base', default='0x08006000')
    ap.add_argument('--bytemap', default='../analysis/decompile/bytemap.txt')
    a = ap.parse_args(argv)
    vio = []
    try:
        if a.v205:
            base = int(a.base, 0)
            img = load_v205_image(a.v205, base, a.bytemap)
            elf = None
            print('check_image (analysis mode): %s base 0x%08X, %d code ranges' % (a.v205, base, len(img.code)))
            print('note: the original has no object roles, so its EEPROM / FLASH_PECR / FLASH_PEKEYR / FLASH_SR driver '
                  '(0x0801F9FC..0x0801FB60, eeprom byte layer 0x0801204C..) is reported as outside the NVM objects; the '
                  'violations that matter are the OPTKEY / FLASH_OPTKEYR / FLASH_OBR / option-byte store / PECR bit 18 '
                  '(OBL_LAUNCH) group of FUN_0801FA68, FUN_0801FA8E, FUN_0801FAA0, FUN_0801FAEE (EEPROM_MAP.md 2.4)')
        else:
            if not a.elf or not a.bin:
                ap.error('ELF and BIN are required')
            mp = a.map or re.sub(r'\.elf$', '.map', a.elf)
            img, elf = load_elf_image(a.elf, mp)
            print('check_image: %s %s' % (a.elf, a.bin))
            if img.mapiv is None:
                print('warning: no linker map (%s): object roles unavailable, NVM and clock code will fail' % mp)
            else:
                print('linker map: %d input-section intervals' % len(img.mapiv))
        insns, bad = decode_ranges(img)
        for s, e in bad:
            vio.append('DECODE undecodable bytes at 0x%08X (%s)' % (s, img.where(s)))
        print('code: %d ranges, %d instructions, %d function entries' % (len(img.code), len(insns), len(img.entries)))
        if not a.v205:
            for f in check_image_item1(img, elf, a.bin, vio):
                print('item 1: ' + f)
            vector_instruction_starts(img, insns, vio)
        chk = Checker(img)
        chk.run(insns)
        it_hazards = chk.check_it_blocks(insns)
        nlit = census_data(chk, img, None)
        fa = chk.facts
        print('item 2: %d basic blocks; loads %d (effective address known: %d), stores %d (known: %d); %d pc-relative '
              'literals read; %d suspect data words' % (fa['blocks'], fa['loads'], fa['loads_known'], fa['stores'],
                                                        fa['stores_known'], fa['literals'], nlit))
        if fa['flash_accesses']:
            print('item 2: FLASH register accesses seen (object role, register, kind, count):')
            for (role, nm, kind), n in sorted(fa['flash_accesses'].items()):
                print('    %-9s %-13s %-5s %d' % (role, nm, kind, n))
        print('item 6: %d IT blocks examined, %d with a load followed by an instruction of the opposite condition '
              '(Unicorn defect when a memory-read hook is installed; %s)'
              % (fa['it_blocks'], len(it_hazards), 'listed as violations' if a.strict_it else 'listed below, not a violation '
                 'without --strict-it'))
        for addr, text in it_hazards:
            obj = img.obj_at(addr)
            line = 'IT-LOAD %s (0x%08X%s): %s' % (img.where(addr), addr, ' in ' + obj if obj else '', text)
            if a.strict_it:
                vio.append(line)
            else:
                print('note: ' + line)
        long_rt = [(x, m) for x, m in chk.long_it if 'rt' in (img.obj_at(x) or '').replace('\\', '/').split('/')[:-1]]
        long_other = [(x, m) for x, m in chk.long_it if (x, m) not in long_rt]
        print('item 7: %d IT blocks of more than two instructions, %d in the RT objects (exempt, v2.05 flag-dependent '
              'sequences, W2_to_W10.md item 1), %d elsewhere' % (len(chk.long_it), len(long_rt), len(long_other)))
        for addr, m in long_other:
            obj = img.obj_at(addr)
            vio.append('IT-LEN %s (0x%08X%s): %s block of more than two instructions (DESIGN 8.2: at most two outside RT)'
                       % (img.where(addr), addr, ' in ' + obj if obj else '', m))
        for addr, vid, msg in sorted(chk.v):
            obj = img.obj_at(addr)
            vio.append('%s %s (0x%08X%s): %s' % (vid, img.where(addr), addr, ' in ' + obj if obj else '', msg))
        if not a.v205:
            for f in check_symbols(img, a.design, vio):
                print('item 5: ' + f)
    except ToolError as e:
        print('check_image: ERROR %s' % e)
        return 2
    for v in vio:
        print('VIOLATION ' + v)
    print('check_image: %s (%d violations)' % ('PASS' if not vio else 'FAIL', len(vio)))
    return 0 if not vio else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
