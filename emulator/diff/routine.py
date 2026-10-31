"""Routine-level runner: a port routine against the v2.05 routine it replaces, from identical state (DESIGN.md 9.4
level 2, 13.1 worker W10).

Purpose
    The scenario harness (run.py, scenario.py) compares whole firmware runs.  This module compares ONE routine pair at a
    time: the v2.05 routine and the port routine are executed from the same CPU registers, RAM, data EEPROM and
    peripheral register state, and everything the routine can do is compared: result registers, the callee-saved
    registers and SP, the condition flags (optional), every store (address, size, value, order), the final RAM and
    EEPROM images, every peripheral / system-control-space access (kind, address, size, value, order) and the calls it
    makes to a chosen set of v2.05 routines.

Method
    * One Unicorn instance (Cortex-M3, Thumb) holds the v2.05 image at 0x08006000 (inputs/binaries/EEVBlog2_05.bin) and
      the port code linked at an alternate base (default 0x08100000), so both exist at once.  SRAM 0x20000000..0x2000BFFF
      is plain memory; the data EEPROM 0x08080000..0x08082FFF is plain memory (its stores are logged like RAM stores);
      peripherals 0x40000000.. , their bit-band alias 0x42000000.. , the SRAM bit-band alias 0x22000000.. and the system
      control space 0xE0000000.. are "scripted memory": a read returns the last written value unless a read model
      supplies the value (see --mmio-read), every access is logged in order.  Flash and the option-byte page are mapped
      read-only: a store is a fault, reported as a status difference.
    * The routine is called as AAPCS says: r0..r3 arguments, LR = a sentinel address, run until the sentinel is fetched.
      r4..r11 start with distinct markers, so a routine that does not preserve them differs from one that does.
    * The two sides always start from one State (registers, SRAM, EEPROM, peripheral memory) and run one after the other
      in the same world; the state is reloaded in between.  Nothing else carries over (the read-model counters and the
      logs are reset), so a side cannot see what the other did.
    * Port side: the runner assembles (--asm) and links (--obj, --asm) the objects under test itself, at the alternate
      base, with arm-none-eabi-as / -ld.  Every undefined symbol is bound, in this order: --bind SYM=ADDR; a symbol
      defined by another given object (port calling port); `fn_XXXXXXXX` and `v205_tab_XXXXXXXX` = that v2.05 address
      (a function gets the Thumb bit); a name of analysis/verified_names.txt = its v2.05 address.  Anything else is an
      error that lists the names; nothing is bound silently.  Callees bound to v2.05 run the original code, so both
      sides execute the same callee.  --stub ADDR[=v1,v2:w2,...] replaces a v2.05 callee (for both sides) by `bx lr` that
      records its arguments and returns scripted r0 (and r1).
    * A whole port ELF that is already linked at the alternate window can be given with --elf; a port ELF linked at
      0x08006000 cannot share the address space with v2.05 and is refused (relink the objects with --obj).
    * Stimuli: RAM modes cycle through `initial` (analysis/decompile/ram_init.txt, rest zero), `zero`, `pattern`,
      `random` (seeded); registers and RAM / peripheral cells are overridden by generators (const, list, range, rand,
      bits); `State` files captured from a real v2.05 run (capture_state, --capture) are used as they are.  The sample
      number and --seed determine everything, so a failing sample is reproduced with --only N.
    * Expected differences (--expect FILE or `expect =` lines of a pairs file): a deviation of DESIGN.md 10 is stated as
      `kind spec ID text`; a difference not covered by a line fails, a line that never matched is a warning.
    * --self-check runs a table of >= 25 v2.05 routines against themselves in two ways: (a) the same routine in two
      independent worlds (determinism of the engine and of the read models), (b) the routine at its original address
      against a byte copy of the v2.05 image mapped in the alternate window (the copy executes its own pc-relative calls
      and reads the original literal pools; this exercises binding-free comparison end to end).  Zero differences is the
      pass criterion.  Limit of (b): code that depends on its own absolute address (none was found in the table) would
      differ; the Cortex-M code of v2.05 reaches its callees by pc-relative bl.

Unicorn defect and how this runner avoids it
    Unicorn 2.1.4 loses the effect of the instruction after an IT block whose last, skipped instruction is a load when a
    UC_HOOK_MEM_READ hook is installed (firmware/requests/W5_to_W10.md item 2; reproduced for ldr, ldrh and ldrb, with
    and without a code hook, not with write-only hooks, not for non-load instructions).  This runner installs a
    UC_HOOK_MEM_WRITE hook, UC_HOOK_CODE hooks and mmio callbacks only, never a read hook, so it is not affected;
    --selftest proves that with the same hook configuration, and a warning lists every IT block ending in a load in the
    port code and in the v2.05 code ranges, so that nobody adds a read hook without knowing.

Limits
    * The peripheral model is memory plus read scripts, not the emulator's peripheral models: a routine that waits for a
      hardware event needs a read model that supplies it (--mmio-read ADDR|=MASK sets always-set bits, ADDR=v1,v2,..
      is a sequence).  Time-dependent behaviour (timers, HY3131 answers) is not modelled; the scenario harness covers it.
    * Routines that depend on interrupts, WFI/WFE, or exception return are not run here.
    * RAM stores below SP in the stack window are not compared (frame layouts legitimately differ between v2.05 and
      the port); everything else in SRAM is.  Port-only RAM (0x20008100..0x200097FF, DESIGN.md 5.1) is reported as
      information unless --strict-port-ram.

Usage (from the project root, with the project Python in isolated mode)
    python -I emulator/diff/routine.py --self-check
    python -I emulator/diff/routine.py --selftest
    python -I emulator/diff/routine.py --asm firmware/src/sys/reset.s --pair nvic_set_vector_table=0x080208E0 \\
        --arg r0=list:0x08000000,0x20000000 --arg r1=rand --regs r0 --samples 40
    python -I emulator/diff/routine.py --pairs cases.txt [--only NAME] [--expect FILE]
    python -I emulator/diff/routine.py --capture 0x08006124:3 --capture-seconds 4 --capture-out state.json
Pairs file (--pairs): one `[name]` section per pair, `key = value` lines, `#` comments, a key may repeat:
    [cal_subtract_offset_clamp]
    port   = cal_subtract_offset_clamp         # symbol in the given --asm/--obj
    v205   = 0x0800F368                        # address, fn_XXXXXXXX or verified name
    r0     = rand                              # const:V | list:V,.. | range:LO:HI | rand | bits:N
    set    = 0x20007E00 u32 range:0:100        # ADDR u8|u16|u32 GEN   (RAM, EEPROM, peripheral or SCS cell)
    mmio-read = 0x40012400|=0x42               # ADDR=v1,v2,..  |  ADDR|=MASK  |  ADDR&=MASK
    stub   = 0x0800EF44=5                      # replace a v2.05 callee by bx lr returning 5
    regs   = r0                                # compared result registers (none for a void routine)
    expect = ram 0x20007F00-0x20007F03 OF-99 text   # kind spec ID text; kinds reg write ram eeprom mmio call flag status any
    samples = 40   ram = initial,zero,pattern,random   budget = 3000000   writes = ordered|final|off   mmio = ordered|final|off
Exit status 0 = no unexplained difference, 1 = difference, 2 = usage or build error.
"""
import argparse
import base64
import difflib
import json
import os
import random
import re
import struct
import subprocess
import sys
import tempfile
import zlib

from unicorn import (Uc, UcError, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UC_HOOK_CODE, UC_HOOK_MEM_WRITE,
                     UC_PROT_ALL, UC_PROT_READ, UC_PROT_EXEC)
from unicorn.arm_const import (UC_ARM_REG_R0, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_XPSR)
import unicorn.arm_const as _armc

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
V205_BIN = os.path.join(ROOT, 'inputs', 'binaries', 'EEVBlog2_05.bin')
V205_BASE = 0x08006000
NAMES_FILE = os.path.join(ROOT, 'analysis', 'verified_names.txt')
RAM_INIT_FILE = os.path.join(ROOT, 'analysis', 'decompile', 'ram_init.txt')
BYTEMAP_FILE = os.path.join(ROOT, 'analysis', 'decompile', 'bytemap.txt')
INC_DIR = os.path.join(ROOT, 'firmware', 'src', 'inc')

# address map of the world
FLASH_BASE, FLASH_SIZE = 0x08000000, 0x80000            # v2.05 window (0x08000000..0x0807FFFF)
EE_BASE, EE_SIZE = 0x08080000, 0x3000                   # data EEPROM
WIN_BASE, WIN_SIZE = 0x08100000, 0x100000               # window of the port code (or of the v2.05 copy)
RET_ADDR = 0x081F0000                                   # sentinel the routine returns to (inside the window)
TRAP_BASE = 0x081F0100                                  # traps of symbols left unbound with --allow-unbound
NOOP_BASE = 0x081F0800                                  # `bx lr` stubs of symbols given with --noop
INFO_BASE, INFO_SIZE = 0x1FF80000, 0x1000               # option-byte page, read-only
SRAM_BASE, SRAM_SIZE = 0x20000000, 0xC000
PERIPH_BASE, PERIPH_SIZE = 0x40000000, 0x100000
BB_PERIPH, BB_SRAM, BB_SIZE = 0x42000000, 0x22000000, 0x2000000
SCS_BASE, SCS_SIZE = 0xE0000000, 0x100000
PORT_RAM_LO, PORT_RAM_HI = 0x20008100, 0x20009800       # port-only RAM (DESIGN.md 5.1)
V205_VAR_LO, V205_VAR_HI = 0x20000000, 0x200080FC       # v2.05 variables (DESIGN.md 5.1)
SYNTH_SP, SYNTH_STACK_LO = 0x2000BF00, 0x2000B000       # stack of synthetic states and the window excluded from compares
CAPT_STACK_LO = 0x2000023E                              # .stack of the v2.05 / port layout (DESIGN.md 5.1)
SENTINEL_REG = 0xA5A50000                               # r4..r11 start as SENTINEL_REG | register number

REGNAMES = ['r%d' % i for i in range(13)]
REG_CONST = [getattr(_armc, 'UC_ARM_REG_R%d' % i) for i in range(13)]
EXPECT_ID = re.compile(r'\b(?:OF|NF|HW|IMP|OPT|NVM)-\d+\b')
DEFAULT_ASFLAGS = ['-mcpu=cortex-m3', '-mthumb', '-mimplicit-it=never', '--fatal-warnings', '-I', INC_DIR]
LINKER_CONSTANTS = {'__stack_top': 0x20001240, '__data_v205_start': 0x20000000, '__data_v205_end': 0x2000023E,
                    '__bss_v205_start': 0x20001240, '__bss_v205_end': 0x200080FC}   # firmware/link/121gw.ld


class RunnerError(Exception):
    """Usage, build or binding error (exit status 2)."""


# ------------------------------------------------------------------------------------------------------ small helpers
def parse_int(text):
    """'0x20008000', '123', '-5' -> int."""
    try:
        return int(str(text).strip(), 0)
    except ValueError:
        raise RunnerError(f'not a number: {text!r}')


def run_tool(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        raise RunnerError(f"{' '.join(cmd[:2])} failed:\n{r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


def load_verified_names():
    """analysis/verified_names.txt -> {name: (address, is_function)}."""
    out = {}
    for line in open(NAMES_FILE):
        m = re.match(r'^([FL])\s+([0-9a-fA-F]{8})\s+(\S+)', line)
        if m:
            out[m.group(3)] = (int(m.group(2), 16), m.group(1) == 'F')
    return out


def resolve_v205(text, names=None):
    """A v2.05 address given as number, fn_XXXXXXXX or verified name."""
    m = re.match(r'^(?:fn_|FUN_)([0-9A-Fa-f]{8})$', text)
    if m:
        return int(m.group(1), 16)
    try:
        return parse_int(text) & ~1
    except RunnerError:
        names = names or load_verified_names()
        if text in names:
            return names[text][0]
        raise RunnerError(f'unknown v2.05 routine {text!r} (not a number, fn_XXXXXXXX or a verified name)')


def read_ram_init():
    """analysis/decompile/ram_init.txt -> {address: byte} (the 574-byte RAM image at 0x20000000)."""
    d = {}
    for line in open(RAM_INIT_FILE):
        m = re.match(r'^([0-9a-f]{8})  ((?:[0-9a-f]{2} ?)+)', line)
        if m:
            a = int(m.group(1), 16)
            for i, b in enumerate(m.group(2).split()):
                d[a + i] = int(b, 16)
    return d


def v205_code_ranges():
    """Address ranges the byte map classifies as code, for the IT-block scan."""
    out = []
    for line in open(BYTEMAP_FILE):
        p = line.split()
        if len(p) >= 3 and p[2] == 'code':
            out.append((int(p[0], 16), int(p[1], 16)))
    return out


def scan_it_loads(code, base):
    """Addresses of IT blocks whose last conditional instruction is a load (the Unicorn defect pattern)."""
    from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS
    cs = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
    hits = []
    pending = 0
    it_addr = 0
    for ins in cs.disasm(code, base):
        if pending:
            pending -= 1
            if pending == 0 and ins.mnemonic.startswith('ld'):
                hits.append(it_addr)
            continue
        if re.match(r'^it[te]{0,3}$', ins.mnemonic):
            pending = len(ins.mnemonic) - 1
            it_addr = ins.address
    return hits


# --------------------------------------------------------------------------------------------------------- ELF / link
def read_elf_segments(path):
    """Loadable segments of a 32-bit little-endian ELF: [(vaddr, paddr, bytes, memsz)]."""
    e = open(path, 'rb').read()
    if e[:4] != b'\x7fELF' or e[4] != 1 or e[5] != 1:
        raise RunnerError(f'{path} is not a 32-bit little-endian ELF')
    phoff, = struct.unpack_from('<I', e, 28)
    phentsize, phnum = struct.unpack_from('<HH', e, 42)
    segs = []
    for i in range(phnum):
        t, off, va, pa, fsz, msz = struct.unpack_from('<IIIIII', e, phoff + i * phentsize)
        if t == 1 and msz:
            segs.append((va, pa, e[off:off + fsz], msz))
    return segs


def elf_symbols(path):
    """{name: (value, type_letter)} of the defined symbols (arm-none-eabi-nm)."""
    out = {}
    for line in run_tool(['arm-none-eabi-nm', path]).splitlines():
        p = line.split()
        if len(p) == 3:
            out[p[2]] = (int(p[0], 16), p[1])
    return out


def obj_undefined(path):
    return [l.split()[1] for l in run_tool(['arm-none-eabi-nm', '-u', path]).splitlines() if len(l.split()) == 2]


def obj_defined(path):
    return [l.split()[2] for l in run_tool(['arm-none-eabi-nm', '--defined-only', path]).splitlines() if len(l.split()) == 3]


class PortImage:
    """The port code under test, linked at `base`.  Built from sources/objects or taken from a linked ELF."""

    def __init__(self, base=WIN_BASE):
        self.base = base
        self.segments = []         # [(address, bytes)] to load into the window
        self.symbols = {}          # name -> address (Thumb bit set for functions)
        self.bound = {}            # undefined name -> address it was bound to (the v2.05 callees)
        self.code = b''
        self.code_base = base

    @classmethod
    def build(cls, asm=(), objs=(), binds=None, base=WIN_BASE, workdir=None, asflags=None, allow_unbound=False, noops=()):
        self = cls(base)
        self.traps = {}                                    # trap address -> name of the unbound symbol
        work = workdir or tempfile.mkdtemp(prefix='routine_')
        os.makedirs(work, exist_ok=True)
        objects = [os.path.abspath(o) for o in objs]
        for s in asm:
            o = os.path.join(work, re.sub(r'[^A-Za-z0-9_.-]', '_', os.path.relpath(os.path.abspath(s), ROOT)) + '.o')
            run_tool(['arm-none-eabi-as'] + (asflags or DEFAULT_ASFLAGS) + ['-o', o, s])
            objects.append(o)
        if not objects:
            raise RunnerError('no port objects: give --asm, --obj or --elf')
        defined = set()
        undefined = set()
        for o in objects:
            defined.update(obj_defined(o))
            undefined.update(obj_undefined(o))
        names = load_verified_names()
        defsyms, unresolved = {}, []
        for i, u in enumerate(sorted(noops)):                # explicit: the symbol is a `bx lr` (nothing happens, r0 kept)
            addr = NOOP_BASE + 4 * i
            defsyms[u] = addr | 1
            self.segments.append((addr, b'\x70\x47'))
        for u in sorted(undefined - defined - set(noops)):
            if binds and u in binds:
                defsyms[u] = binds[u]
            elif u in LINKER_CONSTANTS:
                continue                                    # defined in the generated script
            elif re.match(r'^fn_[0-9A-Fa-f]{8}$', u):
                defsyms[u] = int(u[3:], 16) | 1
            elif re.match(r'^v205_tab_[0-9A-Fa-f]{8}$', u):
                defsyms[u] = int(u[9:], 16)
            elif u in names:
                defsyms[u] = names[u][0] | (1 if names[u][1] else 0)
            else:
                unresolved.append(u)
        if unresolved and allow_unbound:
            # explicit opt-in: every remaining undefined symbol is bound to its own trap (an undefined instruction);
            # a run that reaches one is a fault that names the symbol, a run that does not is unaffected
            for i, u in enumerate(unresolved):
                addr = TRAP_BASE + 4 * i
                defsyms[u] = addr | 1
                self.traps[addr] = u
                self.segments.append((addr, b'\xfe\xde'))
            unresolved = []
        if unresolved:
            raise RunnerError('unresolved symbols (bind them with --bind SYM=ADDR, add the object that defines them, '
                              'or stub them):\n  ' + '\n  '.join(unresolved))
        self.bound = dict(defsyms)
        script = os.path.join(work, 'port.ld')
        consts = ''.join(f'{k} = 0x{v:X};\n' for k, v in LINKER_CONSTANTS.items())
        open(script, 'w').write(
            f'{consts}SECTIONS {{\n'
            f'  .text 0x{base:X} : {{ *(.vectors) *(.text) *(.text.*) *(.rodata) *(.rodata.*) *(.data) *(.data.*) }}\n'
            f'  .data_v205 0x20000000 (NOLOAD) : {{ *(.data_v205) }}\n'
            f'  .bss_v205 0x20001240 (NOLOAD) : {{ *(.bss_v205) }}\n'
            f'  .bss_port 0x{PORT_RAM_LO:X} (NOLOAD) : {{ *(.bss_port) *(.bss_port.*) }}\n'
            f'  /DISCARD/ : {{ *(.v205tab) *(.ARM.attributes) *(.comment) *(.note*) }}\n'
            f'}}\n')
        elf = os.path.join(work, 'port.elf')
        cmd = ['arm-none-eabi-ld', '-T', script, '--build-id=none', '-nostdlib', '--no-undefined', '-o', elf]
        for k, v in sorted(defsyms.items()):
            cmd += ['--defsym', f'{k}=0x{v:X}']
        run_tool(cmd + sorted(objects))
        self.elf = elf
        self._load_elf(elf)
        return self

    @classmethod
    def from_elf(cls, path, base=WIN_BASE):
        self = cls(base)
        self.elf = path
        self._load_elf(path)
        return self

    def _load_elf(self, path):
        for va, pa, data, msz in read_elf_segments(path):
            if not data:
                continue
            if not (WIN_BASE <= pa and pa + len(data) <= RET_ADDR):
                if V205_BASE <= pa < V205_BASE + 0x80000:
                    raise RunnerError(f'{path}: segment at 0x{pa:08X} overlaps the v2.05 image; relink the objects at an '
                                      f'alternate base with --obj/--asm (a port ELF linked at 0x08006000 cannot share the world)')
                if SRAM_BASE <= pa < SRAM_BASE + SRAM_SIZE:
                    continue                                # initial RAM image: the State provides RAM
                raise RunnerError(f'{path}: segment 0x{pa:08X}..0x{pa + len(data):08X} outside the window '
                                  f'0x{WIN_BASE:08X}..0x{RET_ADDR:08X}')
            self.segments.append((pa, data))
        if self.segments:
            self.code_base, self.code = min(self.segments)
        for name, (v, t) in elf_symbols(path).items():
            self.symbols[name] = v | 1 if t in 'Tt' else v

    def entry(self, symbol):
        if symbol not in self.symbols:
            raise RunnerError(f'port symbol {symbol!r} not defined (defined: {len(self.symbols)} symbols)')
        return self.symbols[symbol] | 1


# ------------------------------------------------------------------------------------------------ generators / state
class Gen:
    """Value generator: const:V, list:V1,V2,.., range:LO:HI (inclusive), rand (32 bit), bits:N.  A bare number is const."""

    def __init__(self, spec):
        self.spec = spec.strip()
        s = self.spec
        if s == 'rand':
            self.kind, self.arg = 'rand', None
        elif ':' in s and s.split(':', 1)[0] in ('const', 'list', 'range', 'bits'):
            k, rest = s.split(':', 1)
            self.kind = k
            if k == 'const':
                self.arg = parse_int(rest)
            elif k == 'list':
                self.arg = [parse_int(x) for x in rest.split(',') if x.strip()]
                if not self.arg:
                    raise RunnerError(f'empty list generator {spec!r}')
            elif k == 'range':
                lo, hi = rest.split(':')
                self.arg = (parse_int(lo), parse_int(hi))
                if self.arg[0] > self.arg[1]:
                    raise RunnerError(f'empty range {spec!r}')
            else:
                self.arg = parse_int(rest)
        else:
            self.kind, self.arg = 'const', parse_int(s)

    def draw(self, rng, idx):
        if self.kind == 'const':
            return self.arg
        if self.kind == 'list':
            return self.arg[idx % len(self.arg)]
        if self.kind == 'range':
            return rng.randint(*self.arg)
        if self.kind == 'bits':
            return rng.getrandbits(self.arg)
        return rng.getrandbits(32)


class State:
    """Everything a routine can read: registers, SRAM, data EEPROM, peripheral and SCS memory, stack window."""

    def __init__(self):
        self.regs = {r: 0 for r in REGNAMES}
        self.sp = SYNTH_SP
        self.apsr = 0                          # N Z C V in bits 31..28
        self.ipsr = 0
        self.sram = bytearray(SRAM_SIZE)
        self.eeprom = bytearray(EE_SIZE)
        self.periph = {}                       # address -> bytes (sparse initial peripheral memory)
        self.scs = {}
        self.stack_lo = SYNTH_STACK_LO
        self.label = ''

    def copy(self):
        s = State()
        s.regs, s.sp, s.apsr, s.ipsr = dict(self.regs), self.sp, self.apsr, self.ipsr
        s.sram, s.eeprom = bytearray(self.sram), bytearray(self.eeprom)
        s.periph, s.scs = dict(self.periph), dict(self.scs)
        s.stack_lo, s.label = self.stack_lo, self.label
        return s

    def poke(self, addr, size, value):
        """Write a little-endian cell into the right memory space."""
        data = (value & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
        if SRAM_BASE <= addr and addr + size <= SRAM_BASE + SRAM_SIZE:
            self.sram[addr - SRAM_BASE:addr - SRAM_BASE + size] = data
        elif EE_BASE <= addr and addr + size <= EE_BASE + EE_SIZE:
            self.eeprom[addr - EE_BASE:addr - EE_BASE + size] = data
        elif PERIPH_BASE <= addr < PERIPH_BASE + PERIPH_SIZE:
            self.periph[addr] = data
        elif SCS_BASE <= addr < SCS_BASE + SCS_SIZE:
            self.scs[addr] = data
        else:
            raise RunnerError(f'address 0x{addr:08X} is not SRAM, EEPROM, peripheral or SCS memory')

    def to_json(self):
        enc = lambda b: base64.b64encode(zlib.compress(bytes(b))).decode()
        return json.dumps({'format': 'routine-state-1', 'regs': self.regs, 'sp': self.sp, 'apsr': self.apsr,
                           'ipsr': self.ipsr, 'sram': enc(self.sram), 'eeprom': enc(self.eeprom),
                           'periph': {str(a): d.hex() for a, d in self.periph.items()},
                           'scs': {str(a): d.hex() for a, d in self.scs.items()},
                           'stack_lo': self.stack_lo, 'label': self.label})

    @classmethod
    def from_json(cls, text):
        d = json.loads(text)
        if d.get('format') != 'routine-state-1':
            raise RunnerError('not a routine-state-1 file')
        s = cls()
        dec = lambda t: bytearray(zlib.decompress(base64.b64decode(t)))
        s.regs, s.sp, s.apsr, s.ipsr = d['regs'], d['sp'], d['apsr'], d['ipsr']
        s.sram, s.eeprom = dec(d['sram']), dec(d['eeprom'])
        s.periph = {int(a): bytes.fromhex(x) for a, x in d['periph'].items()}
        s.scs = {int(a): bytes.fromhex(x) for a, x in d['scs'].items()}
        s.stack_lo, s.label = d['stack_lo'], d['label']
        return s


# ------------------------------------------------------------------------------------------------------------ world
class Result:
    """Outcome of one call."""

    def __init__(self):
        self.status = 'ok'                 # 'ok' | 'budget' | 'fault: <unicorn error>'
        self.fault_pc = None               # pc at the fault
        self.regs = {}                     # r0..r12, sp
        self.apsr = 0
        self.writes = []                   # (address, size, value) stores to SRAM / EEPROM / flash, outside the stack window
        self.mmio = []                     # (kind 'R'/'W', address, size, value) peripheral and SCS accesses
        self.calls = []                    # (address, r0, r1, r2, r3) at traced entries and stubs
        self.sram = b''
        self.eeprom = b''
        self.periph = b''


class World:
    """The Unicorn instance shared by both sides."""

    def __init__(self, port=None, copy_v205=False, stubs=None, trace=()):
        if port is not None and copy_v205:
            raise RunnerError('a world holds either the port code or the v2.05 copy in the alternate window')
        self.uc = uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
        self.port = port
        self.copy_delta = (WIN_BASE - V205_BASE) if copy_v205 else None
        v205 = bytearray(open(V205_BIN, 'rb').read())
        self.stubs = {}                                      # v2.05 address -> list of (r0, r1 or None)
        for addr, vals in (stubs or {}).items():
            a = addr & ~1
            v205[a - V205_BASE:a - V205_BASE + 2] = b'\x70\x47'     # bx lr
            self.stubs[a] = vals
        uc.mem_map(FLASH_BASE, FLASH_SIZE)
        uc.mem_write(V205_BASE, bytes(v205))
        uc.mem_map(EE_BASE, EE_SIZE)
        uc.mem_map(WIN_BASE, WIN_SIZE)
        uc.mem_write(RET_ADDR, b'\x00\xbf\x00\xbf')
        if copy_v205:
            uc.mem_write(WIN_BASE, bytes(v205))              # byte copy: v2.05 address A is at A + copy_delta
        if port is not None:
            for addr, data in port.segments:
                uc.mem_write(addr, data)
        uc.mem_protect(FLASH_BASE, FLASH_SIZE, UC_PROT_READ | UC_PROT_EXEC)
        uc.mem_protect(WIN_BASE, WIN_SIZE, UC_PROT_READ | UC_PROT_EXEC)
        uc.mem_map(INFO_BASE, INFO_SIZE, UC_PROT_READ)
        uc.mem_map(SRAM_BASE, SRAM_SIZE, UC_PROT_ALL)
        # scripted memory: peripherals, system control space and the two bit-band aliases
        self.space = {PERIPH_BASE: bytearray(PERIPH_SIZE), SCS_BASE: bytearray(SCS_SIZE)}
        uc.mmio_map(PERIPH_BASE, PERIPH_SIZE, self._mread, PERIPH_BASE, self._mwrite, PERIPH_BASE)
        uc.mmio_map(SCS_BASE, SCS_SIZE, self._mread, SCS_BASE, self._mwrite, SCS_BASE)
        uc.mmio_map(BB_PERIPH, BB_SIZE, self._bread, BB_PERIPH, self._bwrite, BB_PERIPH)
        uc.mmio_map(BB_SRAM, BB_SIZE, self._bread, BB_SRAM, self._bwrite, BB_SRAM)
        # write hook only: a read hook would trigger the Unicorn IT-block defect (module docstring)
        uc.hook_add(UC_HOOK_MEM_WRITE, self._on_write)
        self.models = {}                                     # register word address -> (kind, data)
        self.rd_count = {}
        self.res = Result()
        self.stack_win = (SYNTH_STACK_LO, SYNTH_SP)
        self.sp0 = SYNTH_SP
        self.stub_calls = {}
        self.entry_skip = set()
        self._hooked = set()
        self.trace = set(a & ~1 for a in trace)
        for a in list(self.stubs):
            self._hook_call(a)
        for a in self.trace:
            self._hook_call(a)

    # -- call logging / stubs
    def _norm(self, addr):
        if self.copy_delta is not None and WIN_BASE <= addr < WIN_BASE + WIN_SIZE:
            return addr - self.copy_delta
        return addr

    def _hook_call(self, a):
        targets = [a]
        if self.copy_delta is not None:
            targets.append(a + self.copy_delta)
        for t in targets:
            if t in self._hooked:
                continue
            self._hooked.add(t)
            self.uc.hook_add(UC_HOOK_CODE, self._on_call, begin=t, end=t + 1)

    def _on_call(self, uc, addr, size, ud):
        n = self._norm(addr)
        if addr in self.entry_skip:
            return
        args = tuple(uc.reg_read(r) for r in REG_CONST[:4])
        self.res.calls.append((n,) + args)
        if n in self.stubs:
            vals = self.stubs[n]
            if vals:
                k = self.stub_calls.get(n, 0)
                self.stub_calls[n] = k + 1
                r0, r1 = vals[min(k, len(vals) - 1)]
                uc.reg_write(UC_ARM_REG_R0, r0 & 0xFFFFFFFF)
                if r1 is not None:
                    uc.reg_write(REG_CONST[1], r1 & 0xFFFFFFFF)

    # -- memory hooks
    @staticmethod
    def _is_mmio(addr):
        return (PERIPH_BASE <= addr < PERIPH_BASE + PERIPH_SIZE or SCS_BASE <= addr < SCS_BASE + SCS_SIZE
                or BB_SRAM <= addr < BB_SRAM + BB_SIZE or BB_PERIPH <= addr < BB_PERIPH + BB_SIZE)

    def _on_write(self, uc, access, addr, size, value, ud):
        if self._is_mmio(addr):
            return                                           # logged by the mmio callbacks
        if self.stack_win[0] <= addr < self.stack_win[1]:
            return                                           # stack frames are not compared
        self.res.writes.append((addr, size, value & ((1 << (8 * size)) - 1)))

    def _word(self, addr):
        base = PERIPH_BASE if addr < SCS_BASE else SCS_BASE
        off = addr - base
        return int.from_bytes(self.space[base][off:off + 4], 'little')

    def _model_read(self, addr, size):
        """Value of a read of `size` bytes at addr: the stored bytes unless a read model overrides the register."""
        w = addr & ~3
        raw = self._word(w)
        m = self.models.get(w)
        if m is not None:
            kind, d = m
            n = self.rd_count.get(w, 0)
            self.rd_count[w] = n + 1
            if kind == 'seq':
                raw = d[min(n, len(d) - 1)]
            elif kind == 'or':
                raw |= d
            else:
                raw &= ~d
        return (raw >> (8 * (addr - w))) & ((1 << (8 * size)) - 1)

    def _store(self, addr, size, value):
        base = PERIPH_BASE if addr < SCS_BASE else SCS_BASE
        off = addr - base
        self.space[base][off:off + size] = (value & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')

    def _mread(self, uc, off, size, base):
        addr = base + off
        v = self._model_read(addr, size)
        self.res.mmio.append(('R', addr, size, v))
        return v

    def _mwrite(self, uc, off, size, value, base):
        addr = base + off
        v = value & ((1 << (8 * size)) - 1)
        self._store(addr, size, v)
        self.res.mmio.append(('W', addr, size, v))

    def _bb_target(self, base, off, size):
        """Bit-band alias access -> (aligned unit address, bit): the bus access has the alias access's size."""
        region = PERIPH_BASE if base == BB_PERIPH else SRAM_BASE
        a, bit = region + off // 32, (off % 32) // 4
        unit = a & ~(size - 1)
        return unit, bit + 8 * (a - unit)

    def _unit_read(self, unit, size):
        if unit >= PERIPH_BASE:
            base = PERIPH_BASE
            return int.from_bytes(self.space[base][unit - base:unit - base + size], 'little')
        return int.from_bytes(self.uc.mem_read(unit, size), 'little')

    def _bread(self, uc, off, size, base):
        unit, bit = self._bb_target(base, off, size)
        v = (self._unit_read(unit, size) >> bit) & 1
        self.res.mmio.append(('R', base + off, size, v))
        return v

    def _bwrite(self, uc, off, size, value, base):
        unit, bit = self._bb_target(base, off, size)
        old = self._unit_read(unit, size)
        new = (old | (1 << bit)) if value & 1 else (old & ~(1 << bit))
        data = (new & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
        if unit >= PERIPH_BASE:
            self.space[PERIPH_BASE][unit - PERIPH_BASE:unit - PERIPH_BASE + size] = data
        else:
            self.uc.mem_write(unit, data)
        self.res.mmio.append(('W', base + off, size, value & 1))

    # -- running
    def load_state(self, st):
        uc = self.uc
        uc.mem_write(SRAM_BASE, bytes(st.sram))
        uc.mem_write(EE_BASE, bytes(st.eeprom))
        for base in self.space:
            self.space[base][:] = bytes(len(self.space[base]))
        for table in (st.periph, st.scs):
            for a, d in table.items():
                base = PERIPH_BASE if a < SCS_BASE else SCS_BASE
                self.space[base][a - base:a - base + len(d)] = d
        self.stack_win = (st.stack_lo, st.sp)
        self.sp0 = st.sp

    def run(self, st, entry, budget, models=None, skip_entry=None):
        """Run the routine at `entry` (address, Thumb bit added) from state `st`; returns a Result."""
        uc = self.uc
        self.load_state(st)
        self.res = res = Result()
        self.models = models or {}
        self.rd_count = {}
        self.stub_calls = {}
        self.entry_skip = set(skip_entry or ())
        for i, r in enumerate(REG_CONST):
            v = st.regs.get(REGNAMES[i], 0)
            if 4 <= i <= 11 and v == 0:
                v = SENTINEL_REG | i
            uc.reg_write(r, v & 0xFFFFFFFF)
        uc.reg_write(UC_ARM_REG_SP, st.sp)
        uc.reg_write(UC_ARM_REG_LR, RET_ADDR | 1)
        uc.reg_write(UC_ARM_REG_XPSR, (1 << 24) | (st.apsr & 0xF0000000) | (st.ipsr & 0x1FF))
        before = {n: uc.reg_read(REG_CONST[i]) for i, n in enumerate(REGNAMES)}
        before['sp'] = st.sp
        try:
            uc.emu_start(entry | 1, RET_ADDR, count=budget)
            if uc.reg_read(UC_ARM_REG_PC) != RET_ADDR:
                res.status = 'budget'
        except UcError as e:
            res.status = f'fault: {e}'
            res.fault_pc = uc.reg_read(UC_ARM_REG_PC)
        res.regs = {n: uc.reg_read(REG_CONST[i]) for i, n in enumerate(REGNAMES)}
        res.regs['sp'] = uc.reg_read(UC_ARM_REG_SP)
        res.before = before
        res.apsr = uc.reg_read(UC_ARM_REG_XPSR) & 0xF0000000
        res.sram = bytes(uc.mem_read(SRAM_BASE, SRAM_SIZE))
        res.eeprom = bytes(uc.mem_read(EE_BASE, EE_SIZE))
        res.periph = bytes(self.space[PERIPH_BASE][:0x40000])
        return res


# ----------------------------------------------------------------------------------------------------------- compare
TRAPS = {}                                 # trap address -> unbound symbol name (filled by main)


class Diff:
    """One difference between the two sides."""

    def __init__(self, kind, addr, v205, port, text):
        self.kind, self.addr, self.v205, self.port, self.text = kind, addr, v205, port, text
        self.reason = None                     # set when an expectation covers it

    def __str__(self):
        return self.text


def diff_sequences(kind, a, b, fmt, addr_of):
    """Ordered comparison of two logs; one Diff per mismatching item."""
    out = []
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        n = max(i2 - i1, j2 - j1)
        for k in range(n):
            x = a[i1 + k] if i1 + k < i2 else None
            y = b[j1 + k] if j1 + k < j2 else None
            ad = addr_of(x if x is not None else y)
            out.append(Diff(kind, ad, x, y, f'{kind} #{i1 + k}: v2.05 {fmt(x)} | port {fmt(y)}'))
    return out


def fmt_write(t):
    return '(none)' if t is None else f'{t[1]}-byte store 0x{t[0]:08X} <- 0x{t[2]:0{2 * t[1]}X}'


def fmt_mmio(t):
    return '(none)' if t is None else f'{t[0]} {t[2]}-byte 0x{t[1]:08X} = 0x{t[3]:0{2 * t[2]}X}'


def fmt_call(t):
    return '(none)' if t is None else 'call 0x%08X(%s)' % (t[0], ', '.join('0x%X' % x for x in t[1:]))


def image_runs(a, b, base, skip):
    """Runs of differing bytes between two equal-length images, `skip(addr)` excludes addresses."""
    runs = []
    i, n = 0, len(a)
    while i < n:
        if a[i] != b[i] and not skip(base + i):
            j = i
            while j < n and a[j] != b[j] and not skip(base + j):
                j += 1
            runs.append((base + i, a[i:j], b[i:j]))
            i = j
        else:
            i += 1
    return runs


def compare(rv, rp, case, st, strict_port_ram=False):
    """All differences between the v2.05 result `rv` and the port result `rp` for one stimulus."""
    diffs, info = [], []
    if rv.status.split(':')[0] != rp.status.split(':')[0] or (rv.status.startswith('fault') and rv.status != rp.status):
        def where(r):
            if r.fault_pc is None:
                return ''
            name = TRAPS.get(r.fault_pc & ~1)
            return f' at pc 0x{r.fault_pc:08X}' + (f' (unbound symbol {name})' if name else '')
        diffs.append(Diff('status', None, rv.status, rp.status,
                          f'status: v2.05 {rv.status}{where(rv)} | port {rp.status}{where(rp)}'))
    callee_saved = ['r4', 'r5', 'r6', 'r7', 'r8', 'r9', 'r10', 'r11', 'sp']
    returned = rv.status == 'ok' and rp.status == 'ok'
    if not returned:
        # registers of a call that faulted or ran out of budget are mid-routine temporaries, which legitimately differ
        # between v2.05 and the port; stores, peripheral accesses and calls up to that point are still compared
        info.append('registers not compared in samples where a side did not return')
    for r in (list(dict.fromkeys(case.regs + callee_saved)) if returned else []):
        if rv.regs[r] != rp.regs[r]:
            note = ''
            if r in callee_saved:
                note = ' (callee-saved: v2.05 %s, port %s)' % (
                    'preserved' if rv.regs[r] == rv.before[r] else 'changed',
                    'preserved' if rp.regs[r] == rp.before[r] else 'changed')
            diffs.append(Diff('reg', r, rv.regs[r], rp.regs[r],
                              f'{r}: v2.05 0x{rv.regs[r]:08X} | port 0x{rp.regs[r]:08X}{note}'))
    if case.flags and returned and rv.apsr != rp.apsr:
        diffs.append(Diff('flag', None, rv.apsr, rp.apsr, f'flags NZCV: v2.05 {rv.apsr >> 28:04b} | port {rp.apsr >> 28:04b}'))
    if case.writes_mode == 'ordered':
        diffs += diff_sequences('write', rv.writes, rp.writes, fmt_write, lambda t: t[0])
    if case.mmio_mode == 'ordered':
        diffs += diff_sequences('mmio', rv.mmio, rp.mmio, fmt_mmio, lambda t: t[1])
    elif case.mmio_mode == 'final':
        for a, x, y in image_runs(rv.periph, rp.periph, PERIPH_BASE, lambda a: False):
            diffs.append(Diff('mmio', a, x.hex(), y.hex(), f'peripheral memory 0x{a:08X}: v2.05 {x.hex()} | port {y.hex()}'))
    if case.trace_enabled or case.stubs:
        diffs += diff_sequences('call', rv.calls, rp.calls, fmt_call, lambda t: t[0])
    lo, hi = st.stack_lo, st.sp
    ign = case.ignore_ram

    def skip_ram(a):
        if lo <= a < hi or any(l <= a < h for l, h in ign):
            return True
        return (not strict_port_ram) and PORT_RAM_LO <= a < PORT_RAM_HI

    for a, x, y in image_runs(rv.sram, rp.sram, SRAM_BASE, skip_ram):
        diffs.append(Diff('ram', a, x, y, f'RAM 0x{a:08X}..0x{a + len(x) - 1:08X}: v2.05 {x[:8].hex()}{"..." if len(x) > 8 else ""} '
                                          f'| port {y[:8].hex()}{"..." if len(y) > 8 else ""}'))
    for a, x, y in image_runs(rv.eeprom, rp.eeprom, EE_BASE, lambda a: False):
        diffs.append(Diff('eeprom', a, x, y, f'EEPROM 0x{a:08X}..0x{a + len(x) - 1:08X}: v2.05 {x[:8].hex()} | port {y[:8].hex()}'))
    if not strict_port_ram:
        n = sum(1 for a in range(PORT_RAM_LO, PORT_RAM_HI) if rv.sram[a - SRAM_BASE] != rp.sram[a - SRAM_BASE])
        if n:
            info.append(f'{n} bytes of port-only RAM differ (information, DESIGN.md 5.1)')
    return diffs, info


class Expectation:
    """One `kind spec ID text` line of an expect file."""

    def __init__(self, line):
        toks = line.split()
        if len(toks) < 2:
            raise RunnerError(f'bad expectation line: {line!r}')
        self.kind = toks[0]
        self.line = line
        if not EXPECT_ID.search(line):
            raise RunnerError(f'expectation without a deviation ID (OF-/NF-/HW-/IMP-/OPT-/NVM-nnn): {line!r}')
        self.regs, self.lo, self.hi, self.flags = None, None, None, False
        if self.kind == 'reg':
            m = re.match(r'^r(\d+)(?:-r(\d+))?$', toks[1])
            if not m:
                raise RunnerError(f'bad register spec in {line!r}')
            a = int(m.group(1))
            b = int(m.group(2) or a)
            self.regs = {'r%d' % i for i in range(a, b + 1)}
            if a <= 12 and b >= 13:
                self.regs.add('sp')
        elif self.kind in ('ram', 'eeprom', 'write', 'mmio', 'call'):
            m = re.match(r'^(0x[0-9A-Fa-f]+|\d+)(?:-(0x[0-9A-Fa-f]+|\d+))?$', toks[1])
            if not m:
                raise RunnerError(f'bad address spec in {line!r}')
            self.lo = int(m.group(1), 0)
            self.hi = int(m.group(2), 0) if m.group(2) else self.lo
        elif self.kind not in ('flag', 'status', 'any'):
            raise RunnerError(f'unknown expectation kind {self.kind!r}')
        self.hits = 0
        self.scope = 'case'                      # 'all': an expect-file line before any [case] header

    def covers(self, d):
        if self.kind == 'any':
            return True
        if d.kind != self.kind:
            return False
        if self.kind == 'reg':
            return d.addr in self.regs
        if self.lo is not None:
            if d.addr is None:
                return False
            if d.kind in ('ram', 'eeprom'):
                return True                      # run-level test is done by the caller (split by byte)
            return self.lo <= d.addr <= self.hi
        return True


def apply_expectations(diffs, expects):
    """Split RAM/EEPROM runs by covered bytes; mark covered diffs; return the unexplained ones."""
    out = []
    for d in diffs:
        if d.kind in ('ram', 'eeprom'):
            ex = [e for e in expects if e.kind in (d.kind, 'any')]
            if ex:
                n = len(d.v205)
                keep = bytearray(n)
                for i in range(n):
                    a = d.addr + i
                    cov = [e for e in ex if e.kind == 'any' or e.lo <= a <= e.hi]
                    if cov:
                        for e in cov:
                            e.hits += 1
                    else:
                        keep[i] = 1
                if not any(keep):
                    continue
                i = 0
                while i < n:                         # report the uncovered bytes as runs
                    if keep[i]:
                        j = i
                        while j < n and keep[j]:
                            j += 1
                        nd = Diff(d.kind, d.addr + i, d.v205[i:j], d.port[i:j],
                                  f'{"RAM" if d.kind == "ram" else "EEPROM"} 0x{d.addr + i:08X}..0x{d.addr + j - 1:08X}: '
                                  f'v2.05 {bytes(d.v205[i:j][:8]).hex()} | port {bytes(d.port[i:j][:8]).hex()}')
                        out.append(nd)
                        i = j
                    else:
                        i += 1
                continue
            out.append(d)
            continue
        cov = [e for e in expects if e.covers(d)]
        if cov:
            for e in cov:
                e.hits += 1
            d.reason = cov[0].line
        else:
            out.append(d)
    return out


# -------------------------------------------------------------------------------------------------- cases / stimuli
class Case:
    """One routine pair and how to exercise and compare it."""

    def __init__(self, name):
        self.name = name
        self.port = None                       # port symbol or None (v2.05 against itself)
        self.v205 = None                       # v2.05 address
        self.args = {}                         # 'r0'.. -> Gen
        self.sets = []                         # (address, size, Gen)
        self.regs = ['r0']
        self.flags = False
        self.samples = 20
        self.ram_modes = ['initial', 'zero', 'pattern', 'random']
        self.models = {}                       # register word -> (kind, data)
        self.stubs = {}                        # v2.05 address -> [(r0, r1)]
        self.trace = []
        self.trace_bound = False
        self.expect = []
        self.budget = 3_000_000
        self.ignore_ram = []
        self.writes_mode = 'ordered'
        self.mmio_mode = 'ordered'
        self.state_file = None
        self.sp = SYNTH_SP

    def set_option(self, key, value):
        """Apply `key = value` of a pairs file (or the equivalent command-line option)."""
        k = key.strip().lower()
        v = value.strip()
        if k == 'port':
            self.port = v
        elif k == 'v205':
            self.v205 = resolve_v205(v)
        elif re.match(r'^r(\d+)$', k):
            self.args[k] = Gen(v)
        elif k == 'regs':
            self.regs = [x.strip() for x in v.split(',') if x.strip() and x.strip() != 'none']
            for r in self.regs:
                if r not in REGNAMES:
                    raise RunnerError(f'bad register {r!r} in regs')
        elif k == 'flags':
            self.flags = v.lower() in ('1', 'yes', 'true', 'on')
        elif k == 'samples':
            self.samples = parse_int(v)
        elif k == 'ram':
            self.ram_modes = [x.strip() for x in v.split(',')]
            for x in self.ram_modes:
                if x not in ('initial', 'zero', 'pattern', 'random'):
                    raise RunnerError(f'unknown RAM mode {x!r}')
        elif k == 'set':
            m = re.match(r'^(\S+)\s+(u8|u16|u32)\s+(.+)$', v)
            if not m:
                raise RunnerError(f'bad set line (ADDR u8|u16|u32 GEN): {v!r}')
            self.sets.append((parse_int(m.group(1)), {'u8': 1, 'u16': 2, 'u32': 4}[m.group(2)], Gen(m.group(3))))
        elif k == 'mmio-read':
            self.add_model(v)
        elif k == 'stub':
            self.add_stub(v)
        elif k == 'trace':
            self.trace.append(resolve_v205(v))
        elif k == 'trace-bound':
            self.trace_bound = v.lower() in ('1', 'yes', 'true', 'on')
        elif k == 'expect':
            self.expect.append(Expectation(v))
        elif k == 'budget':
            self.budget = parse_int(v)
        elif k == 'ignore-ram':
            lo, _, hi = v.partition('-')
            self.ignore_ram.append((parse_int(lo), parse_int(hi) + 1 if hi else parse_int(lo) + 1))
        elif k == 'writes':
            if v not in ('ordered', 'final', 'off'):
                raise RunnerError('writes = ordered|final|off')
            self.writes_mode = v
        elif k == 'mmio':
            if v not in ('ordered', 'final', 'off'):
                raise RunnerError('mmio = ordered|final|off')
            self.mmio_mode = v
        elif k == 'state':
            self.state_file = v
        elif k == 'sp':
            self.sp = parse_int(v)
        else:
            raise RunnerError(f'unknown option {key!r} for case {self.name}')

    @property
    def trace_enabled(self):
        return bool(self.trace) or self.trace_bound

    def add_model(self, text):
        """ADDR=v1,v2,..  sequence; ADDR|=MASK  bits always read as 1; ADDR&=MASK  bits always read as 0."""
        m = re.match(r'^(\S+?)(\|=|&=|=)(.+)$', text.strip())
        if not m:
            raise RunnerError(f'bad mmio-read spec: {text!r}')
        w = parse_int(m.group(1)) & ~3
        if m.group(2) == '|=':
            self.models[w] = ('or', parse_int(m.group(3)))
        elif m.group(2) == '&=':
            self.models[w] = ('clr', parse_int(m.group(3)))
        else:
            self.models[w] = ('seq', [parse_int(x) for x in m.group(3).split(',')])

    def add_stub(self, text):
        a, _, vals = text.partition('=')
        lst = []
        for tok in vals.split(','):
            if tok.strip():
                p = tok.split(':')
                lst.append((parse_int(p[0]), parse_int(p[1]) if len(p) > 1 else None))
        self.stubs[resolve_v205(a)] = lst


def make_state(case, idx, seed, ram_init):
    """The idx-th synthetic stimulus of a case."""
    rng = random.Random(seed * 1000003 + idx)
    st = State()
    st.sp = case.sp
    mode = case.ram_modes[idx % len(case.ram_modes)]
    if mode in ('initial', 'random'):
        for a, b in ram_init.items():
            st.sram[a - SRAM_BASE] = b
    if mode == 'pattern':
        for a in range(0, V205_VAR_HI - SRAM_BASE):
            st.sram[a] = (a * 7 + 13) & 0xFF
    elif mode == 'random':
        n = V205_VAR_HI - SRAM_BASE
        st.sram[:n] = bytes(rng.getrandbits(8) for _ in range(n))
    for r, g in case.args.items():
        st.regs[r] = g.draw(rng, idx)
    for a, size, g in case.sets:
        st.poke(a, size, g.draw(rng, idx))
    st.label = f'sample {idx} ram={mode}' + ''.join(f' {r}=0x{v:X}' for r, v in sorted(st.regs.items()) if v)
    return st


# ---------------------------------------------------------------------------------------------------------- capture
CAPTURE_SAFE = [(0x40020000, 0x40021FFF, 0x2C), (0x40023800, 0x4002383F, 0x40), (0x40007000, 0x40007007, 8),
                (0x40010000, 0x4001001F, 0x20), (0x40010400, 0x40010417, 0x18), (0x40023C00, 0x40023C0B, 12)]
CAPTURE_SCS = [0xE000E100, 0xE000E104, 0xE000ED08, 0xE000ED0C, 0xE000ED10, 0xE000ED14]


def capture_state(emulator, entry, nth=1, seconds=10.0, drive=None, step_s=0.002):
    """Run the real emulator (emulator/app.py Emulator, v2.05 or any image) until the entry of the routine is
    fetched for the nth time and snapshot it as a State.  `drive(emulator, t)` is called before every slice (key
    presses, signals, a scenario).  Peripheral registers are read from the emulator's models only in blocks without
    read side effects (GPIO, RCC, PWR, SYSCFG, EXTI, FLASH ACR/PECR) and NVIC/SCB cells through the SCS model; other
    peripheral cells stay zero, which is also what the scripted memory returns for them.  The stack window is the
    firmware's .stack (0x2000023E..SP)."""
    m = emulator.m
    entry &= ~1
    hit = {'n': 0, 'st': None}

    def on_entry(uc, addr, size, ud):
        hit['n'] += 1
        if hit['n'] != nth or hit['st'] is not None:
            return
        st = State()
        for i, n in enumerate(REGNAMES):
            st.regs[n] = uc.reg_read(REG_CONST[i])
        st.sp = uc.reg_read(UC_ARM_REG_SP)
        xpsr = uc.reg_read(UC_ARM_REG_XPSR)
        st.apsr, st.ipsr = xpsr & 0xF0000000, xpsr & 0x1FF
        st.sram = bytearray(uc.mem_read(SRAM_BASE, SRAM_SIZE))
        st.eeprom = bytearray(m.eeprom)
        for lo, hi, length in CAPTURE_SAFE:
            for blk in range(lo & ~0x3FF if hi - lo > 0x400 else lo, hi + 1, 0x400 if hi - lo > 0x400 else hi - lo + 1):
                for off in range(0, length, 4):
                    a = blk + off
                    try:
                        v = m._pread(uc, a - PERIPH_BASE, 4, None)
                    except Exception:                        # model without that register: leave the cell zero
                        continue
                    if v:
                        st.periph[a] = int(v & 0xFFFFFFFF).to_bytes(4, 'little')
        for a in CAPTURE_SCS:
            try:
                v = m.nvic.read(a - SCS_BASE, 4)
            except Exception:
                continue
            if v:
                st.scs[a] = int(v & 0xFFFFFFFF).to_bytes(4, 'little')
        st.stack_lo = CAPT_STACK_LO
        st.label = f'captured at 0x{entry:08X} call {nth}, t={float(m.elapsed_s()):.6f} s'
        hit['st'] = st
        uc.emu_stop()

    h = m.uc.hook_add(UC_HOOK_CODE, on_entry, begin=entry, end=entry + 1)
    t = 0.0
    try:
        while hit['st'] is None and t < seconds:
            if drive:
                drive(emulator, t)
            r = m.run(max(1, int(m.sysclk_hz * step_s)))
            t += step_s
            if r or m.reset_request:
                break
    finally:
        m.uc.hook_del(h)
    if hit['st'] is None:
        raise RunnerError(f'entry 0x{entry:08X} was reached {hit["n"]} time(s), call {nth} not seen in {t:.2f} s')
    return hit['st']


# ---------------------------------------------------------------------------------------------------- case execution
class CaseReport:
    def __init__(self, case):
        self.case = case
        self.samples = 0
        self.unexplained = []                  # (label, Diff)
        self.explained = 0
        self.info = set()
        self.warnings = []
        self.vacuous = False
        self.ok_samples = 0                    # samples in which the v2.05 routine returned
        self.stores = self.mmio = self.calls = 0   # events compared (v2.05 side)


def run_case(case, port, ram_init, seed=1, only=None, strict_port_ram=False, worlds=None):
    """Run all stimuli of a case; compare v2.05 against the port routine (or against the copy / a second world)."""
    rep = CaseReport(case)
    if case.v205 is None:
        raise RunnerError(f'case {case.name}: no v2.05 routine (v205 = ...)')
    trace = set(case.trace)
    if case.trace_bound and port is not None:
        trace |= {v & ~1 for v in port.bound.values() if V205_BASE <= v < V205_BASE + 0x80000}
    trace.discard(case.v205)
    stubs = dict(case.stubs)
    trace |= set(stubs)
    if worlds is None:
        w = World(port=port, stubs=stubs, trace=trace if case.trace_enabled or stubs else ())
        wv = wp = w
        mode = 'port'
    else:
        wv, wp, mode = worlds(stubs, trace if case.trace_enabled or stubs else ())
    if mode == 'port':
        if case.port is None:
            raise RunnerError(f'case {case.name}: no port routine (port = SYMBOL)')
        pentry = port.entry(case.port)
    elif mode == 'copy':
        pentry = (case.v205 + wp.copy_delta) | 1
    else:
        pentry = case.v205 | 1
    ventry = case.v205 | 1
    states = []
    if case.state_file:
        s = State.from_json(open(case.state_file).read())
        for r, g in case.args.items():
            s.regs[r] = g.draw(random.Random(seed), 0)
        states = [s]
    else:
        states = [make_state(case, i, seed, ram_init) for i in range(case.samples)]
    for idx, st in enumerate(states):
        if only is not None and idx != only:
            continue
        rv = wv.run(st, ventry, case.budget, case.models, skip_entry={case.v205})
        rp = wp.run(st, pentry, case.budget, case.models, skip_entry={pentry & ~1})
        diffs, info = compare(rv, rp, case, st, strict_port_ram)
        rep.info.update(info)
        rep.ok_samples += rv.status == 'ok'
        rep.stores += len(rv.writes)
        rep.mmio += len(rv.mmio)
        rep.calls += len(rv.calls)
        left = apply_expectations(diffs, case.expect)
        rep.explained += len(diffs) - len(left)
        rep.samples += 1
        for d in left:
            rep.unexplained.append((st.label, d))
    if rep.samples and rep.ok_samples == 0:
        rep.warnings.append('vacuous: the v2.05 routine never returned within the budget in any sample '
                            f'(raise budget or supply read models); only the status was compared')
        rep.vacuous = True
    for e in case.expect:
        if e.hits == 0 and e.scope == 'case':
            rep.warnings.append(f'expected difference never occurred: {e.line}')
    return rep


def print_report(rep, limit=6, out=sys.stdout):
    c = rep.case
    verdict = 'PASS' if not rep.unexplained else 'FAIL'
    what = f'{c.port or "v2.05"} vs 0x{c.v205:08X}'
    print(f'{verdict} {c.name}: {what}, {rep.samples} samples ({rep.ok_samples} returned; {rep.stores} stores, '
          f'{rep.mmio} peripheral accesses, {rep.calls} traced calls compared), {len(rep.unexplained)} unexplained, '
          f'{rep.explained} expected differences', file=out)
    shown = {}
    for label, d in rep.unexplained:
        k = d.kind
        if shown.get(k, 0) >= limit:
            continue
        shown[k] = shown.get(k, 0) + 1
        print(f'    [{label}] {d}', file=out)
    kinds = {}
    for _, d in rep.unexplained:
        kinds[d.kind] = kinds.get(d.kind, 0) + 1
    if kinds:
        print('    by kind: ' + ', '.join(f'{k} {n}' for k, n in sorted(kinds.items())), file=out)
    for i in sorted(rep.info):
        print(f'    info: {i}', file=out)
    for w in rep.warnings:
        print(f'    warning: {w}', file=out)


def parse_pairs_file(path):
    """Sections `[name]` with `key = value` lines (a key may repeat); `#` starts a comment."""
    cases, cur = [], None
    for n, line in enumerate(open(path), 1):
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        m = re.match(r'^\[(.+)\]$', line)
        if m:
            cur = Case(m.group(1).strip())
            cases.append(cur)
            continue
        if cur is None or '=' not in line:
            raise RunnerError(f'{path}:{n}: expected [name] or key = value')
        k, v = line.split('=', 1)
        cur.set_option(k, v)
    return cases


# ------------------------------------------------------------------------------------------------------- self-check
# (name, v2.05 address, options).  Arguments are chosen so that pointers stay inside RAM; the aim is breadth of code
# shapes: pure arithmetic, table lookups, RAM state machines, GPIO bit-banging with delays, EEPROM readers, a routine
# with callees, status-polling routines (read models end the loops).  Addresses and roles: analysis/verified_names.txt.
GPIOF_IDR, GPIOG_IDR, GPIOE_IDR, GPIOB_IDR = 0x40021810, 0x40021C10, 0x40021010, 0x40020410
SELF_CHECK = [
    ('nvic_set_vector_table', 0x080208E0, ['r0=list:0x08000000,0x20000000', 'r1=range:0:0x7FFFFF']),
    ('delay', 0x0800ECF6, ['r0=range:0:300']),
    ('cal_subtract_offset_clamp', 0x0800F368, ['r0=rand', 'ram=initial,random']),
    ('cal_divide_by_gain', 0x0800F3B8, ['r0=range:0:0x7FFFFF', 'set=0x20007E10 u32 list:0x3F800000,0x40000000,0x41200000,0']),
    ('load_full_scale', 0x0800D5F4, ['set=0x2000803C u8 range:0:24', 'set=0x2000803D u8 range:0:6']),
    ('decimal_position_for_mode_range', 0x0800D920, ['r0=range:0:24', 'r1=range:0:6']),
    ('sample_pg0_7', 0x08014A14, ['regs=r0', f'set={GPIOG_IDR:#x} u32 rand']),
    ('sample_pg8_15', 0x08016BCA, [f'set={GPIOG_IDR:#x} u32 rand']),
    ('debounce_pg0_7_onehot', 0x0801496E, ['set=0x20008066 u8 list:1,2,4,8,16,32,64,128', 'set=0x20008065 u8 rand']),
    ('sense_pe10_pe11', 0x0801417C, [f'set={GPIOE_IDR:#x} u32 rand', 'set=0x2000803C u8 range:0:24']),
    ('eeprom_read_byte', 0x0801204C, ['r0=range:0:0x2FFF', 'set=0x08080000 u32 rand', 'set=0x08080100 u32 rand']),
    ('eeprom_read_u8', 0x0801203A, ['r0=range:0:0x4FF', 'set=0x08080010 u32 rand']),
    ('eeprom_read_u16_be', 0x08012000, ['r0=range:0:0x4FE', 'set=0x08080020 u32 rand']),
    ('eeprom_read_u32_be', 0x08011F80, ['r0=range:0:0x4FC', 'set=0x08080030 u32 rand']),
    ('load_cal_record_from_eeprom', 0x0801167C, ['r0=range:0:24', 'r1=range:0:6', 'set=0x2000803C u8 range:0:24',
                                                'set=0x2000803D u8 range:0:6', 'set=0x08080100 u32 rand',
                                                'trace=0x0801204C', 'trace=0x0801203A', 'trace=0x08012000', 'trace=0x08011F80']),
    ('hy3131_spi_read_byte', 0x0800C138, [f'mmio-read={GPIOF_IDR:#x}=8,0,8,8,0,0,8,0']),
    ('hy3131_spi_write_byte', 0x0800C16C, ['r0=range:0:255', 'budget=500000']),
    ('hy3131_spi_clock_pulse', 0x0800C1BC, ['budget=500000']),
    ('hy3131_write_regs', 0x0800C03C, ['r0=0x20007000', 'r1=range:0:0x3F', 'r2=range:1:4', 'set=0x20007000 u32 rand',
                                      'budget=2000000']),
    ('rtc_write_reg', 0x080101AC, ['r0=range:0:15', 'r1=range:0:255', 'budget=1000000']),
    ('rtc_read_byte', 0x08010254, [f'mmio-read={GPIOB_IDR:#x}=0x80,0,0x80,0x80,0,0,0x80,0', 'budget=1000000']),
    ('rtc_ce_high', 0x08010308, []),
    ('rtc_ce_low', 0x0801031E, []),
    ('adc_select_channel_4_or_5', 0x080137B4, ['r0=range:0:1', 'mmio-read=0x40012400|=0x42']),
    ('adc_ch4_average_10', 0x0801381E, ['mmio-read=0x40012400|=0x42', 'mmio-read=0x40012458=0x123,0x234,0x345,0x456,0x567']),
    ('bargraph_count_from_value', 0x08018FA8, ['r0=range:0:60000', 'set=0x2000803C u8 range:0:24']),
    ('lcd_draw_glyph', 0x0801A950, ['r0=range:0:9', 'r1=range:0:255', 'budget=500000']),
    ('lcd_set_mode_annunciators', 0x080172A8, ['r0=range:0:24', 'set=0x2000803C u8 range:0:24', 'budget=500000']),
    ('gpio_set_alternate_function', 0x0801BE04, ['r0=0x40020400', 'r1=range:0:15', 'r2=range:0:15']),
    ('rcc_lsi_as_rtc_lcd_clock', 0x0801BF92, ['mmio-read=0x40023834|=0x2', 'mmio-read=0x40007000|=0x100',
                                              'budget=1000000']),
    ('sample_pf8_at_boot', 0x0800C28C, [f'mmio-read={GPIOF_IDR:#x}=0x100,0,0x100,0x100,0,0x100', 'budget=1000000']),
]


def selfcheck_case(name, addr, opts, samples):
    c = Case(name)
    c.v205 = addr
    c.samples = samples
    c.budget = 400_000                         # a routine that waits for an interrupt ends by budget on both sides
    for o in opts:
        k, _, v = o.partition('=')
        c.set_option(k, v)
    return c


def run_self_check(samples=12, seed=1, only=None, out=sys.stdout):
    ram_init = read_ram_init()
    bad = 0
    for name, addr, opts in SELF_CHECK:
        if only and only != name:
            continue
        for how in ('two worlds', 'copy window'):
            c = selfcheck_case(f'{name} [{how}]', addr, opts, samples)
            if how == 'two worlds':
                def worlds(stubs, trace, c=c):
                    return World(stubs=stubs, trace=trace), World(stubs=stubs, trace=trace), 'same'
            else:
                def worlds(stubs, trace, c=c):
                    w = World(copy_v205=True, stubs=stubs, trace=trace)
                    return w, w, 'copy'
            rep = run_case(c, None, ram_init, seed=seed, worlds=worlds)
            print_report(rep, out=out)
            bad += bool(rep.unexplained) or rep.vacuous
    return bad


# ------------------------------------------------------------------------------------------------------------ selftest
IT_SOURCE = '''.syntax unified
.thumb
.thumb_func
.global caller
caller:
  push {r4,lr}
  movs r4,#0
  ldr r2,=0x20000000
  cmp r0,#0
  bl callee
  ldr r1,=0x1234
  adds r4,r1
  mov r0,r4
  pop {r4,pc}
.ltorg
.thumb_func
callee:
  ite eq
  %s
  %s
  bx lr
'''


def run_selftest(out=sys.stdout):
    """The IT-block defect cannot occur in this runner: a routine whose IT block ends in a skipped load runs correctly
    in the runner's world (write hook, code hooks, mmio callbacks, no read hook), for ldr, ldrh and ldrb, both arms."""
    fails = 0
    with tempfile.TemporaryDirectory(prefix='routine_selftest_') as work:
        for tag, a, b in (('ldrh', 'ldrheq r0,[r2]', 'ldrhne r0,[r2,#2]'), ('ldr', 'ldreq r0,[r2]', 'ldrne r0,[r2,#4]'),
                          ('ldrb', 'ldrbeq r0,[r2]', 'ldrbne r0,[r2,#1]')):
            src = os.path.join(work, tag + '.s')
            open(src, 'w').write(IT_SOURCE % (a, b))
            img = PortImage.build(asm=[src], workdir=os.path.join(work, tag))
            w = World(port=img, trace=())
            for r0 in (0, 1):
                st = State()
                st.regs['r0'] = r0
                res = w.run(st, img.entry('caller'), 10000)
                ok = res.status == 'ok' and res.regs['r0'] == 0x1234
                fails += not ok
                print(f'{"PASS" if ok else "FAIL"} IT block ending in a skipped {tag}, r0={r0}: r0 = 0x{res.regs["r0"]:X} '
                      f'({res.status})', file=out)
            hits = scan_it_loads(img.code, img.code_base)
            print(f'     scan: {len(hits)} IT block(s) ending in a load in the test code (expected 1)', file=out)
            fails += len(hits) != 1
    # IT blocks ending in a load in the v2.05 image (information; the runner installs no read hook)
    img = open(V205_BIN, 'rb').read()
    hits = []
    for lo, hi in v205_code_ranges():
        hits += scan_it_loads(img[lo - V205_BASE:hi + 1 - V205_BASE], lo)
    print(f'     scan: {len(hits)} IT block(s) ending in a load in the v2.05 code ranges'
          + (f' (first 0x{min(hits):08X})' if hits else ''), file=out)
    # bit-band aliases: a store of 1 / 0 to the alias sets / clears one bit of the register or SRAM word (PM0056 2.2.5)
    with tempfile.TemporaryDirectory(prefix='routine_selftest_') as work:
        alias_p = BB_PERIPH + ((0x40023830 - PERIPH_BASE) * 32) + 5 * 4          # bit 5 of 0x40023830
        alias_s = BB_SRAM + ((0x20000100 - SRAM_BASE) * 32) + 9 * 4              # bit 9 of 0x20000100
        src = os.path.join(work, 'bb.s')
        open(src, 'w').write(f'.syntax unified\n.thumb\n.thumb_func\n.global bb\nbb:\n  movs r0,#1\n  ldr r1,=0x{alias_p:X}\n'
                             f'  str r0,[r1]\n  ldr r2,=0x{alias_s:X}\n  str r0,[r2]\n  ldr r0,[r1]\n  bx lr\n.ltorg\n')
        img = PortImage.build(asm=[src], workdir=work)
        w = World(port=img, trace=())
        res = w.run(State(), img.entry('bb'), 1000)
        reg = int.from_bytes(w.space[PERIPH_BASE][0x23830:0x23834], 'little')
        ram = struct.unpack('<I', res.sram[0x100:0x104])[0]
        ok = res.status == 'ok' and res.regs['r0'] == 1 and reg == 1 << 5 and ram == 1 << 9
        fails += not ok
        print(f'{"PASS" if ok else "FAIL"} engine: bit-band alias write/read (register 0x{reg:X}, RAM word 0x{ram:X}, '
              f'read-back {res.regs["r0"]})', file=out)
    # engine sanity: a store to read-only flash is a fault, an unmapped read is a fault, a loop ends by budget
    with tempfile.TemporaryDirectory(prefix='routine_selftest_') as work:
        src = os.path.join(work, 'eng.s')
        open(src, 'w').write('.syntax unified\n.thumb\n.thumb_func\n.global storeflash\nstoreflash:\n  ldr r1,=0x08006000\n'
                             '  str r0,[r1]\n  bx lr\n.ltorg\n.thumb_func\n.global spin\nspin:\n  b spin\n'
                             '.thumb_func\n.global readunmapped\nreadunmapped:\n  ldr r1,=0x30000000\n  ldr r0,[r1]\n  bx lr\n.ltorg\n')
        img = PortImage.build(asm=[src], workdir=work)
        w = World(port=img, trace=())
        for sym, want in (('storeflash', 'fault'), ('readunmapped', 'fault'), ('spin', 'budget')):
            res = w.run(State(), img.entry(sym), 1000)
            ok = res.status.startswith(want)
            fails += not ok
            print(f'{"PASS" if ok else "FAIL"} engine: {sym} -> {res.status}', file=out)
    return fails


# ----------------------------------------------------------------------------------------------------------------- CLI
def build_parser():
    p = argparse.ArgumentParser(description=__doc__.split('\n\nPurpose')[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog='Method, limits and the Unicorn IT-block note: see the module docstring '
                                       '(python -I -c "import routine; print(routine.__doc__)" from emulator/diff).')
    p.add_argument('--asm', action='append', default=[], metavar='FILE', help='port source to assemble and link (repeatable)')
    p.add_argument('--obj', action='append', default=[], metavar='FILE', help='port object to link (repeatable)')
    p.add_argument('--elf', metavar='FILE', help='port ELF already linked inside 0x08100000..0x081F0000')
    p.add_argument('--bind', action='append', default=[], metavar='SYM=ADDR', help='bind an undefined symbol (repeatable)')
    p.add_argument('--allow-unbound', action='store_true', help='bind symbols nothing defines to a trap that faults '
                   'and names the symbol when reached (default: unresolved symbols are an error)')
    p.add_argument('--noop', action='append', default=[], metavar='SYM', help='bind a port symbol to a bare `bx lr` (repeatable): '
                   'for new port routines that are not under test and have no v2.05 counterpart')
    p.add_argument('--workdir', metavar='DIR', help='directory for objects and the linked ELF (default: a temporary one)')
    p.add_argument('--pair', action='append', default=[], metavar='PORT_SYM=V205', help='routine pair (v2.05 address, '
                   'fn_XXXXXXXX or verified name); repeatable, all pairs share the options below')
    p.add_argument('--pairs', metavar='FILE', help='pairs file: [name] sections of key = value lines '
                   '(port, v205, r0..r12, regs, flags, samples, ram, set, mmio-read, stub, trace, trace-bound, expect, '
                   'budget, ignore-ram, writes, mmio, state, sp)')
    p.add_argument('--only', metavar='N_OR_NAME', help='run only sample N, or only the pair/case NAME')
    p.add_argument('--arg', action='append', default=[], metavar='rN=GEN', help='register generator: const:V, list:V,V, '
                   'range:LO:HI, rand, bits:N')
    p.add_argument('--set', action='append', default=[], metavar='"ADDR u8|u16|u32 GEN"', help='RAM/EEPROM/peripheral cell generator')
    p.add_argument('--regs', default=None, help='result registers compared besides r4..r11 and sp (default r0; "none" for a void routine)')
    p.add_argument('--flags', action='store_true', help='compare the condition flags N Z C V after the call')
    p.add_argument('--samples', type=int, default=None, help='number of stimuli per pair (default 20)')
    p.add_argument('--ram', default=None, help='RAM modes cycled: initial,zero,pattern,random')
    p.add_argument('--seed', type=int, default=1, help='random seed (default 1)')
    p.add_argument('--mmio-read', action='append', default=[], metavar='SPEC', help='ADDR=v1,v2,.. | ADDR|=MASK | ADDR&=MASK (register read model)')
    p.add_argument('--stub', action='append', default=[], metavar='ADDR[=v1[:w1],..]', help='replace a v2.05 callee by bx lr')
    p.add_argument('--trace', action='append', default=[], metavar='ADDR', help='v2.05 entry whose calls are compared')
    p.add_argument('--trace-calls', action='store_true', help='compare calls to every v2.05 routine the port was bound to')
    p.add_argument('--expect', metavar='FILE', help='expected-difference lines (kind spec ID text); lines before the first '
                   '[pair name] header apply to every pair, lines after a header to that pair only')
    p.add_argument('--budget', type=int, default=None, help='instruction budget per call (default 3000000)')
    p.add_argument('--strict-port-ram', action='store_true', help='port-only RAM differences are failures')
    p.add_argument('--state', metavar='FILE', help='start every pair from this captured State file')
    p.add_argument('--capture', metavar='ADDR[:N]', help='run the real emulator on v2.05 until the nth call of ADDR and save the State')
    p.add_argument('--capture-out', metavar='FILE', help='where --capture writes the State (JSON)')
    p.add_argument('--capture-seconds', type=float, default=10.0, help='emulated seconds before --capture gives up')
    p.add_argument('--capture-eeprom', metavar='FILE', help='EEPROM image for the emulator of --capture')
    p.add_argument('--self-check', action='store_true', help='v2.05 against itself for the built-in routine table')
    p.add_argument('--self-check-samples', type=int, default=12)
    p.add_argument('--selftest', action='store_true', help='engine and Unicorn IT-block checks')
    p.add_argument('--list-self-check', action='store_true')
    return p


def cmd_capture(args):
    sys.path.insert(0, os.path.join(ROOT, 'emulator'))
    from app import Emulator
    spec = args.capture.split(':')
    entry = parse_int(spec[0])
    nth = parse_int(spec[1]) if len(spec) > 1 else 1
    e = Emulator(os.path.join(ROOT, 'inputs', 'binaries'), eeprom=args.capture_eeprom)
    st = capture_state(e, entry, nth, seconds=args.capture_seconds)
    if args.capture_out:
        open(args.capture_out, 'w').write(st.to_json())
    print(f'captured: {st.label}; SP 0x{st.sp:08X}; r0..r3 = ' + ' '.join(f'0x{st.regs[r]:X}' for r in REGNAMES[:4]))
    return 0


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.selftest:
            return 1 if run_selftest() else 0
        if args.list_self_check:
            for n, a, o in SELF_CHECK:
                print(f'0x{a:08X} {n}  {" ".join(o)}')
            return 0
        if args.self_check:
            only = args.only
            bad = run_self_check(samples=args.self_check_samples, seed=args.seed, only=only)
            print('SELF-CHECK ' + ('FAILED' if bad else f'PASSED: {len(SELF_CHECK)} routines, 0 differences'))
            return 1 if bad else 0
        if args.capture:
            return cmd_capture(args)
        cases = []
        if args.pairs:
            cases += parse_pairs_file(args.pairs)
        for pr in args.pair:
            sym, _, addr = pr.partition('=')
            c = Case(sym)
            c.port, c.v205 = sym, resolve_v205(addr)
            cases.append(c)
        if not cases:
            raise RunnerError('nothing to do: give --pair, --pairs, --self-check, --selftest or --capture')
        pair_cases = [c for c in cases if c.name in {pr.partition('=')[0] for pr in args.pair}]
        common = []
        for a in args.arg:
            k, _, v = a.partition('=')
            common.append((k, v))
        for a in args.set:
            common.append(('set', a))
        for a in args.mmio_read:
            common.append(('mmio-read', a))
        for a in args.stub:
            common.append(('stub', a))
        for a in args.trace:
            common.append(('trace', a))
        if args.regs:
            common.append(('regs', args.regs))
        if args.samples is not None:
            common.append(('samples', str(args.samples)))
        if args.ram:
            common.append(('ram', args.ram))
        if args.budget is not None:
            common.append(('budget', str(args.budget)))
        if args.state:
            common.append(('state', args.state))
        if args.trace_calls:
            common.append(('trace-bound', 'yes'))
        expect_all, expect_by_case = [], {}
        if args.expect:                              # lines before any [case] header apply to every pair
            cur = None
            for line in open(args.expect):
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                m = re.match(r'^\[(.+)\]$', line)
                if m:
                    cur = m.group(1).strip()
                    continue
                e = Expectation(line)
                if cur is None:
                    e.scope = 'all'
                    expect_all.append(e)
                else:
                    expect_by_case.setdefault(cur, []).append(e)
        for c in cases:
            c.expect += expect_all + expect_by_case.get(c.name, [])
        for c in pair_cases:                         # command-line options apply to --pair cases; a pairs file is complete
            for k, v in common:
                c.set_option(k, v)
            if args.flags:
                c.flags = True
        only_n, only_name = None, None
        if args.only is not None:
            if args.only.isdigit():
                only_n = int(args.only)
            else:
                only_name = args.only
                cases = [c for c in cases if c.name == only_name]
                if not cases:
                    raise RunnerError(f'no case named {only_name!r}')
        binds = {}
        for b in args.bind:
            k, _, v = b.partition('=')
            binds[k] = parse_int(v)
        if args.elf:
            port = PortImage.from_elf(args.elf)
        else:
            port = PortImage.build(asm=args.asm, objs=args.obj, binds=binds, workdir=args.workdir,
                                   allow_unbound=args.allow_unbound, noops=args.noop)
            TRAPS.update(port.traps)
        hits = scan_it_loads(port.code, port.code_base) if port.code else []
        if hits:
            print(f'note: {len(hits)} IT block(s) ending in a load in the port code (0x{hits[0]:08X}..): harmless here, this '
                  f'runner installs no read hook (module docstring)')
        ram_init = read_ram_init()
        bad = 0
        for c in cases:
            rep = run_case(c, port, ram_init, seed=args.seed, only=only_n, strict_port_ram=args.strict_port_ram)
            print_report(rep)
            bad += bool(rep.unexplained)
        for e in expect_all:
            if e.hits == 0:
                print(f'warning: expected difference never occurred in any pair: {e.line}')
        return 1 if bad else 0
    except RunnerError as e:
        print(f'error: {e}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
