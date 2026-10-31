#!/usr/bin/env python3
"""check_gpio.py - GPIO pin-policy and front-end table check of the linked firmware ELF (DESIGN.md 9.3 items 3 and 4).

Usage (from firmware/, as the Makefile does):  python3 -I tools/check_gpio.py build/121gw.elf [--map build/121gw.map] [-v]
(-v lists every decoded call site; a mask marked * was computed at run time and is checked as all 16 pins)
Exit status 0 = PASS, 1 = FAIL (one line per finding on standard output), 2 = the tool could not run (bad input).
Needs the Python standard library and capstone (Thumb-2 decoder).

What it checks
  1. Call sites.  Every call or tail branch to `brd_gpio_init`, `gpio_init` and `gpio_set_alternate_function`
     (Appendix C.2 / PHASE0_W1_DONE.md) is decoded from the machine code: port base, pin mask, mode, output type and
     alternate function are recovered by constant propagation inside the function (literal pools, movw/movt, adds,
     descriptors in the ELF read through `ldr rX,=symbol`, descriptors or v2.05 structures built on the stack).
     Each pin of the mask is then checked against the policy below.  A call whose port or pin mask cannot be
     recovered is a finding, unless the function is listed in PROBE_ALLOWLIST or WRAPPERS (printed when used).
  2. Direct register writes.  Any store whose effective address is known and falls on GPIOx_MODER, OTYPER, OSPEEDR,
     PUPDR, AFRL or AFRH of a port A..H (also through the bit-band alias) and that lies outside the BRD objects is a
     finding.  BRD objects are the input sections whose object path has the directory `brd`, taken from the linker map.
  3. Address taken.  A literal pool word, movw/movt pair or adr that materialises the address of one of the three
     entry routines is a finding (the routine would be reached by an indirect call that step 1 cannot decode).
  4. brd_pin_policy audit.  The run-time policy table of BRD (src/brd/gpio.s) must not allow anything the policy
     below forbids.
  5. brd_fe_table (DESIGN.md 4.4, 9.3 item 3): the 26 x 16 u16 words of the ELF symbol `brd_fe_table` must equal
     the levels of tools/fe_levels.txt for every (mode, filter, diode, range0, c7).

Policy (DESIGN.md 4.2 and 9.3 item 4; where the two texts differ the stricter 4.2 rule is applied)
  PA13, PA14 (SWD)               never reconfigured, any mode
  PH0, PH1 (crystal)             analog only
  PF3 (HY_DO), PE10, PE11 (fuse comparators), PG0..PG15 (dial contacts, keys)
                                 never output, never alternate function
  PD6 (BT_RX)                    alternate function AF7 or analog only
  PC8, PD2 (SD_D0, SD_CMD)       never output; alternate function only AF12
  PB7 (NJU6350 DATA, HW-01)      never a push-pull drive (push-pull output, or alternate function with push-pull type)
  Writing AF number 0 (reset value) to a pin that has no alternate function is accepted by gpio_set_alternate_function
  (sdio_gpio_deinit 0x08023CD8 writes it).

Method and limits
  - Instruction decoding with capstone (Thumb, M-class).  Code and data are separated with the ARM mapping symbols
    `$t` and `$d` of the ELF; functions are the STT_FUNC symbols.
  - Constant propagation is a forward pass over each function.  At a branch target the state is the join (equal
    values survive) of the fall-through state and the states of all earlier branches to it; a target that is also
    the target of a backward branch (loop) starts with unknown registers.  r4..r11 survive a call (AAPCS, which the
    BRD routines keep); r0..r3, r12, lr do not.  Stack slots of the function are tracked byte-wise so that a
    descriptor built in a local frame (src/lcd/lcd.s) is decoded; a call that is passed a stack pointer and is not
    one of the GPIO routines or fn_0801BDEC (v2.05 GPIO_StructInit, {0xFFFF,0,0,0,0}) forgets the frame.
  - It does not follow data through memory other than the local frame, does not decode computed jumps (`tbb`, `tbh`,
    `mov pc`; labels after one start with unknown registers) and does not prove anything about stores whose base
    address is not a known constant: those cannot be classified statically and are covered by the run-time policy
    check of brd_gpio_init and the emulator safety monitor (DESIGN.md 9.4 level 5).
  - Conditional (IT-block) instructions are treated as possibly executed: their destinations become unknown, and a
    conditional store counts as a store.
"""
import os
import re
import struct
import sys

try:
    import capstone
    from capstone import arm_const as AC
except ImportError:
    print('check_gpio: the capstone module is required (pip install capstone)')
    sys.exit(2)

TOOLS = os.path.dirname(os.path.abspath(__file__))
FE_LEVELS = os.path.join(TOOLS, 'fe_levels.txt')

WATCHED = ('brd_gpio_init', 'gpio_init', 'gpio_set_alternate_function')

# Functions whose call sites cannot be decoded and are exempt, with the reason; every use is printed.
# PROBE_ALLOWLIST: call sites of the SAFETY_PROBE image (DESIGN.md 9.4 item 5), the only intended entries.  No probe
# source exists in the tree at this time (src/inc/config.inc names the switch only), so the list is empty; when the
# probe routines are written, add `'<function symbol>': '<why>'` here.
PROBE_ALLOWLIST = {}
# WRAPPERS: routines that forward the arguments of their own caller (the caller's call sites are decoded one by one).
WRAPPERS = {
    'gpio_init': 'forwards the v2.05 structure of its caller to brd_gpio_init (src/brd/gpio.s); callers are decoded',
}

# Port bases (RM0038 Table 5 / DESIGN.md 2.3) and the per-port register offsets of RM0038 8.4
PORTS = {0x40020000: 'A', 0x40020400: 'B', 0x40020800: 'C', 0x40020C00: 'D', 0x40021000: 'E', 0x40021400: 'H',
         0x40021800: 'F', 0x40021C00: 'G'}
CFG_REGS = {0x00: 'MODER', 0x04: 'OTYPER', 0x08: 'OSPEEDR', 0x0C: 'PUPDR', 0x20: 'AFRL', 0x24: 'AFRH'}
BB_PERIPH, BB_END = 0x42000000, 0x44000000
MODE_IN, MODE_OUT, MODE_AF, MODE_AN = 0, 1, 2, 3
MODE_NAME = {0: 'input', 1: 'output', 2: 'alternate function', 3: 'analog'}
BRD_AF_KEEP = 0xFF
STRUCT_INIT = 'fn_0801BDEC'                    # v2.05 GPIO_StructInit: {mask 0xFFFF, mode 0, speed 0, otype 0, pupd 0}
RESTRICTED_AF = {('D', 6): 7, ('C', 8): 12, ('D', 2): 12}     # pins whose only alternate function is fixed
FE_COLS = ['PD0', 'PC11', 'PF4', 'PF5', 'PE15', 'PF6', 'PA12', 'PH2', 'PE12', 'PE5', 'PD7', 'PA11']
FE_ROWS = 26


# =====================================================================================================================
# policy
# =====================================================================================================================
def pin_violation(port, pin, mode, otype, af):
    """Reason string if configuring `port``pin` as (mode, otype, af) breaks the policy, else None.
    otype / af may be None when the caller does not know them (v2.05 structure without AF number); an unknown AF
    number is accepted here and checked by the caller against the gpio_set_alternate_function calls."""
    p = (port, pin)
    name = f'P{port}{pin}'
    if p in (('A', 13), ('A', 14)):
        return f'{name} (SWD) must never be reconfigured (DESIGN.md 4.2)'
    if p in (('H', 0), ('H', 1)):
        return None if mode == MODE_AN else f'{name} (crystal) may only be analog, requested {MODE_NAME[mode]} (4.2)'
    if p in (('F', 3), ('E', 10), ('E', 11)) or port == 'G':
        if mode in (MODE_OUT, MODE_AF):
            return f'{name} is driven by an external device: {MODE_NAME[mode]} forbidden (4.2, 9.3 item 4)'
        return None
    if p == ('D', 6):
        if mode == MODE_AN:
            return None
        if mode == MODE_AF:
            return None if af in (7, None) else f'{name} (BT_RX) alternate function must be AF7, found {af} (4.2)'
        return f'{name} (BT_RX) may only be AF7 or analog, requested {MODE_NAME[mode]} (4.2)'
    if p in (('C', 8), ('D', 2)):
        if mode == MODE_OUT:
            return f'{name} (SD line) must never be an output (4.2)'
        if mode == MODE_AF and af is not None and af != 12:
            return f'{name} (SD line) alternate function must be AF12, found {af} (4.2)'
        return None
    if p == ('B', 7):
        if mode == MODE_OUT and otype == 0:
            return f'{name} (NJU6350 DATA) must not be a push-pull output (HW-01)'
        if mode == MODE_AF and otype == 0:
            return f'{name} (NJU6350 DATA) must not be driven push-pull in alternate-function mode (HW-01)'
        return None
    return None


# =====================================================================================================================
# ELF reader
# =====================================================================================================================
class Elf:
    """Minimal 32-bit little-endian ELF reader: sections, symbols, memory image of the allocated sections."""

    def __init__(self, path):
        d = self.data = open(path, 'rb').read()
        if d[:4] != b'\x7fELF' or d[4] != 1 or d[5] != 1:
            raise ValueError('not a 32-bit little-endian ELF file')
        (self.e_shoff,) = struct.unpack_from('<I', d, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x2E)
        self.sections = []
        for i in range(shnum):
            name, typ, flags, addr, off, size, link, info, align, entsize = \
                struct.unpack_from('<10I', d, self.e_shoff + i * shentsize)
            self.sections.append(dict(idx=i, name_off=name, type=typ, flags=flags, addr=addr, off=off, size=size,
                                      link=link, info=info, entsize=entsize))
        stro = self.sections[shstrndx]['off']
        for s in self.sections:
            s['name'] = self._cstr(stro + s['name_off'])
        self.symbols = []
        for s in self.sections:
            if s['type'] == 2:                               # SHT_SYMTAB
                so = self.sections[s['link']]['off']
                for k in range(s['size'] // 16):
                    n, v, sz, info, other, shndx = struct.unpack_from('<IIIBBH', d, s['off'] + 16 * k)
                    self.symbols.append(dict(name=self._cstr(so + n), value=v, size=sz, type=info & 15,
                                             bind=info >> 4, shndx=shndx))
        self.by_name = {}
        for sym in self.symbols:
            if sym['name'] and sym['name'] not in self.by_name:
                self.by_name[sym['name']] = sym
        self.loaded = [s for s in self.sections if s['flags'] & 2 and s['type'] == 1 and s['size']]   # ALLOC PROGBITS

    def _cstr(self, off):
        e = self.data.index(b'\0', off)
        return self.data[off:e].decode('ascii', 'replace')

    def read(self, addr, n):
        """Bytes at a load address of an allocated PROGBITS section (None if not fully inside one)."""
        for s in self.loaded:
            if s['addr'] <= addr and addr + n <= s['addr'] + s['size']:
                o = s['off'] + addr - s['addr']
                return self.data[o:o + n]
        return None

    def u32(self, addr):
        b = self.read(addr, 4)
        return None if b is None else struct.unpack('<I', b)[0]

    def exec_sections(self):
        return [s for s in self.sections if s['flags'] & 4 and s['type'] == 1 and s['size']]


def code_spans(elf):
    """[(start, end)] of Thumb code from the ARM mapping symbols ($t = code, $d = data) of the executable sections."""
    spans = []
    for sec in elf.exec_sections():
        marks = sorted((s['value'], s['name'][:2]) for s in elf.symbols
                       if s['shndx'] == sec['idx'] and s['name'][:2] in ('$t', '$d') and s['type'] == 0)
        end_sec = sec['addr'] + sec['size']
        for i, (a, k) in enumerate(marks):
            b = marks[i + 1][0] if i + 1 < len(marks) else end_sec
            if k == '$t' and b > a:
                if spans and spans[-1][1] == a:
                    spans[-1] = (spans[-1][0], b)
                else:
                    spans.append((a, b))
    return spans


def data_spans(elf):
    """[(start, end)] of literal data inside executable sections ($d) plus every non-executable allocated section."""
    spans = []
    for sec in elf.exec_sections():
        marks = sorted((s['value'], s['name'][:2]) for s in elf.symbols
                       if s['shndx'] == sec['idx'] and s['name'][:2] in ('$t', '$d') and s['type'] == 0)
        end_sec = sec['addr'] + sec['size']
        for i, (a, k) in enumerate(marks):
            b = marks[i + 1][0] if i + 1 < len(marks) else end_sec
            if k == '$d' and b > a:
                spans.append((a, b))
    for sec in elf.loaded:
        if not sec['flags'] & 4:
            spans.append((sec['addr'], sec['addr'] + sec['size']))
    return spans


def parse_map(path):
    """[(start, end, object path)] of the input sections in the linker map (both the one-line form and the form with
    the section name on its own line)."""
    spans = []
    rx = re.compile(r'^\s+(?:\S+\s+)?0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S+\.o)\s*$')
    with open(path, errors='replace') as f:
        for line in f:
            m = rx.match(line)
            if m:
                a, n = int(m.group(1), 16), int(m.group(2), 16)
                if n:
                    spans.append((a, a + n, m.group(3)))
    return spans


# =====================================================================================================================
# abstract state
# =====================================================================================================================
# register value: None (unknown), int (known constant) or ('s', off) = address in the local frame, off relative to the
# stack pointer at function entry.  Frame memory: dict byte offset -> int 0..255.
REGNAMES = ['r0', 'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8', 'r9', 'r10', 'r11', 'r12', 'sp', 'lr', 'pc']
RIDX = {n: i for i, n in enumerate(REGNAMES)}
RIDX['ip'], RIDX['fp'], RIDX['sb'], RIDX['sl'] = 12, 11, 9, 10
M32 = 0xFFFFFFFF


class State:
    __slots__ = ('r', 'mem')

    def __init__(self, r=None, mem=None):
        self.r = list(r) if r is not None else [None] * 16
        self.mem = dict(mem) if mem is not None else {}

    def copy(self):
        return State(self.r, self.mem)

    @staticmethod
    def join(a, b):
        r = [x if x == y else None for x, y in zip(a.r, b.r)]
        mem = {k: v for k, v in a.mem.items() if b.mem.get(k) == v}
        return State(r, mem)


def v_add(a, b):
    if isinstance(a, int) and isinstance(b, int):
        return (a + b) & M32
    if isinstance(a, tuple) and isinstance(b, int):
        return ('s', a[1] + (b if b < 0x80000000 else b - 0x100000000))
    if isinstance(b, tuple) and isinstance(a, int):
        return ('s', b[1] + (a if a < 0x80000000 else a - 0x100000000))
    return None


def v_sub(a, b):
    if isinstance(a, int) and isinstance(b, int):
        return (a - b) & M32
    if isinstance(a, tuple) and isinstance(b, int):
        return ('s', a[1] - (b if b < 0x80000000 else b - 0x100000000))
    if isinstance(a, tuple) and isinstance(b, tuple):
        return (a[1] - b[1]) & M32
    return None


class Finding:
    def __init__(self, func, addr, text):
        self.func, self.addr, self.text = func, addr, text

    def __str__(self):
        return f'FINDING {self.func} 0x{self.addr:08X}: {self.text}'


# =====================================================================================================================
# per-function analysis
# =====================================================================================================================
class Analyzer:
    def __init__(self, elf, roles, report):
        self.elf = elf
        self.roles = roles                              # callable address -> True when the address is in a BRD object
        self.report = report                            # callable (Finding)
        self.md = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_THUMB | capstone.CS_MODE_MCLASS)
        self.md.detail = True
        self.watched_addr = {}                          # entry address (thumb bit cleared) -> name
        for n in WATCHED + (STRUCT_INIT,):
            s = elf.by_name.get(n)
            if s:
                self.watched_addr[s['value'] & ~1] = n
        self.sym_at = {}                                # address -> name of FUNC symbols
        for s in elf.symbols:
            if s['type'] == 2 and s['name']:
                self.sym_at.setdefault(s['value'] & ~1, s['name'])
        self.stats = dict(calls=0, stores_checked=0, allowlisted=0)
        self.decoded = []                               # one text line per decoded call site (--verbose)
        self.used_exemptions = {}

    # ---- helpers ---------------------------------------------------------------------------------------------
    def rn(self, insn, reg):
        return insn.reg_name(reg)

    def op_val(self, st, insn, op):
        """Value of a register or immediate operand."""
        if op.type == AC.ARM_OP_IMM:
            return op.imm & M32
        if op.type == AC.ARM_OP_REG:
            v = st.r[RIDX[self.rn(insn, op.reg)]]
            if getattr(op, 'shift', None) is not None and op.shift.type:
                return None
            return v
        return None

    def mem_ea(self, st, insn, mop):
        """Effective address of a memory operand (without write-back effect), or None."""
        m = mop.mem
        base = self.rn(insn, m.base)
        if base == 'pc':
            return ((insn.address + 4) & ~3) + m.disp
        bv = st.r[RIDX[base]]
        if m.index:
            iv = st.r[RIDX[self.rn(insn, m.index)]]
            if m.scale != 1 or m.lshift or iv is None:
                return None
            return v_sub(bv, iv) if mop.subtracted else v_add(bv, iv)
        return v_add(bv, m.disp & M32) if m.disp >= 0 else v_sub(bv, (-m.disp) & M32)

    # ---- one function ----------------------------------------------------------------------------------------
    def analyse(self, fname, start, end):
        elf = self.elf
        code = elf.read(start, end - start)
        if code is None:
            return
        insns = list(self.md.disasm(code, start))
        if not insns:
            return
        # pre-pass: branch targets inside the function and which of them have a backward branch
        targets, back, indirect = set(), set(), False
        for i in insns:
            if capstone.CS_GRP_JUMP in i.groups and i.operands and i.operands[-1].type == AC.ARM_OP_IMM:
                t = i.operands[-1].imm
                if start <= t < end:
                    targets.add(t)
                    if t <= i.address:
                        back.add(t)
            elif i.mnemonic.startswith(('tbb', 'tbh')) or (i.mnemonic.startswith(('mov', 'ldr')) and i.op_str.split(',')[0].strip() == 'pc'):
                indirect = True
        st = State()
        st.r[13] = ('s', 0)
        incoming = {}                                   # target -> list of states
        flow = True
        for i in insns:
            a = i.address
            if a in targets or not flow:
                cands = incoming.get(a, [])
                if flow:
                    cands = cands + [st]
                if cands and a not in back and not (indirect and not flow and not incoming.get(a)):
                    ns = cands[0].copy()
                    for c in cands[1:]:
                        ns = State.join(ns, c)
                    if indirect:
                        ns.r = [ns.r[13] if k == 13 else None for k in range(16)]
                        ns.mem = {}
                else:
                    ns = State()
                    sps = [c.r[13] for c in cands]
                    ns.r[13] = sps[0] if sps and all(s == sps[0] for s in sps) else None
                st = ns
                flow = True
            flow = self.step(fname, st, i, start, end, incoming)
        for (port, pin, addr, name) in self.pending_af.get(fname, []):
            af = self.af_seen.get(fname, {}).get((port, pin))
            want = RESTRICTED_AF[(port, pin)]
            if af != want:
                self.report(Finding(fname, addr, f'call of {name}: P{port}{pin} set to alternate-function mode but '
                                                 f'gpio_set_alternate_function(AF{want}) is not called for it in the same '
                                                 f'function (found {"none" if af is None else "AF" + str(af)})'))

    def clobber(self, st, insn):
        for r in insn.regs_access()[1]:
            nm = insn.reg_name(r)
            if nm in RIDX and nm != 'pc':
                st.r[RIDX[nm]] = None

    def set_mem(self, st, off, size, value):
        for k in range(size):
            if value is None:
                st.mem.pop(off + k, None)
            else:
                st.mem[off + k] = (value >> (8 * k)) & 0xFF

    def get_mem(self, st, off, size):
        v = 0
        for k in range(size):
            b = st.mem.get(off + k)
            if b is None:
                return None
            v |= b << (8 * k)
        return v

    def step(self, fname, st, insn, fstart, fend, incoming):
        """Interpret one instruction; returns True if control can fall through to the next one."""
        m = insn.mnemonic
        cond = insn.cc not in (AC.ARM_CC_AL, AC.ARM_CC_INVALID)
        ops = insn.operands
        groups = insn.groups
        a = insn.address
        base = re.sub(r'\.[wn]$', '', m)
        # ---- calls
        if capstone.CS_GRP_CALL in groups:
            tgt = ops[0].imm if ops and ops[0].type == AC.ARM_OP_IMM else None
            name = self.watched_addr.get(tgt & ~1) if tgt is not None else None
            if name is None and ops and ops[0].type == AC.ARM_OP_REG:
                v = st.r[RIDX[self.rn(insn, ops[0].reg)]]
                if isinstance(v, int):
                    name = self.watched_addr.get(v & ~1)
            if name in WATCHED:
                self.call(fname, st, insn, name)
            self.after_call(st, name)
            return True
        # ---- jumps: b, b<cc>, cbz, cbnz, bx, tbb, tbh
        if capstone.CS_GRP_JUMP in groups:
            tgt = ops[-1].imm if ops and ops[-1].type == AC.ARM_OP_IMM else None
            if tgt is not None and fstart <= tgt < fend:
                incoming.setdefault(tgt, []).append(st.copy())
            elif tgt is not None and (tgt & ~1) in self.watched_addr:          # tail call into a GPIO routine
                self.call(fname, st, insn, self.watched_addr[tgt & ~1])
            if base.startswith(('cbz', 'cbnz')) or cond:
                return True                                                   # conditional: falls through as well
            return False                                                      # b, bx, tbb, tbh end the flow
        # ---- stack pointer manipulation
        if base in ('push', 'pop', 'stmdb', 'ldmia', 'stmfd', 'ldmfd', 'ldm', 'stm', 'stmia', 'stmea', 'ldmdb'):
            return self.step_multi(fname, st, insn, base, cond)
        # ---- stores
        if base.startswith('str') and base not in ('strex', 'strexb', 'strexh'):
            self.step_store(st, insn, base, cond)
            return True
        # ---- loads
        if base.startswith('ldr') and ops and ops[-1].type == AC.ARM_OP_MEM or \
                (base.startswith('ldr') and len(ops) >= 2 and ops[1].type == AC.ARM_OP_MEM):
            self.step_load(st, insn, base, cond)
            return not (insn.reg_name(ops[0].reg) == 'pc' and not cond)
        # ---- data processing
        if cond:
            self.clobber(st, insn)
            return True
        self.step_alu(st, insn, base)
        return True

    # ---- calls ----------------------------------------------------------------------------------------------
    def after_call(self, st, name):
        sp_args = any(isinstance(st.r[k], tuple) for k in range(4))
        if name == STRUCT_INIT and isinstance(st.r[0], tuple):
            off = st.r[0][1]
            for k, b in enumerate([0xFF, 0xFF, 0, 0, 0, 0, 0, 0]):
                st.mem[off + k] = b
        elif sp_args and name not in WATCHED:
            st.mem = {}
        for k in (0, 1, 2, 3, 12, 14):
            st.r[k] = None

    def decode_struct(self, st, ptr, size):
        """Bytes at pointer value `ptr` (image address or frame address): list of ints/None, length `size`."""
        if isinstance(ptr, tuple):
            return [st.mem.get(ptr[1] + k) for k in range(size)]
        if isinstance(ptr, int):
            b = self.elf.read(ptr, size)
            if b is not None:
                return list(b)
        return [None] * size

    def call(self, fname, st, insn, name):
        self.stats['calls'] += 1
        a = insn.address
        port_v, r1, r2 = st.r[0], st.r[1], st.r[2]
        if fname in PROBE_ALLOWLIST or fname in WRAPPERS:
            self.used_exemptions[fname] = PROBE_ALLOWLIST.get(fname) or WRAPPERS[fname]
            self.stats['allowlisted'] += 1
            return
        bad = lambda text: self.report(Finding(fname, a, f'call of {name}: {text}'))
        if not (isinstance(port_v, int) and port_v in PORTS):
            bad(f'port base not a known constant GPIO base (r0 = {self.fmt(port_v)}); the call cannot be decoded')
            return
        port = PORTS[port_v]
        if name == 'gpio_set_alternate_function':
            if not (isinstance(r1, int) and isinstance(r2, int)):
                bad(f'pin or AF number not constant on port {port} (r1 = {self.fmt(r1)}, r2 = {self.fmt(r2)})')
                return
            if r1 > 15 or r2 > 15:
                bad(f'pin {r1} or AF {r2} out of range on port {port}')
                return
            self.note_af(fname, port, r1, r2)
            self.decoded.append(f'{fname} 0x{a:08X} gpio_set_alternate_function P{port}{r1} AF{r2}')
            if r2 == 0:
                return
            why = pin_violation(port, r1, MODE_AF, None, r2)
            if why is None and (port == 'G' or (port, r1) in (('F', 3), ('E', 10), ('E', 11), ('H', 0), ('H', 1),
                                                              ('A', 13), ('A', 14), ('B', 7))):
                why = f'P{port}{r1} must not get alternate function AF{r2}'
            if why:
                bad(why)
            return
        # brd_gpio_init: 12-byte descriptor; gpio_init: 8-byte v2.05 structure
        size = 12 if name == 'brd_gpio_init' else 8
        d = self.decode_struct(st, r1, size)
        if d[4] is None:
            bad(f'mode of the descriptor not decodable (r1 = {self.fmt(r1)})')
            return
        if all(b is not None for b in d[0:4]):
            mask = d[0] | (d[1] << 8) | (d[2] << 16) | (d[3] << 24)
        else:
            # pin mask computed at run time (src/brd/board.s gpio_init_pg_inputs, OF-06): every pin of the port is
            # assumed selected, so the mode must be allowed for all 16 pins
            mask = 0xFFFF
        mode, otype = d[4], d[6] if size > 6 else None
        af = d[8] if size == 12 else None
        if mode > 3:
            bad(f'mode value {mode} is not a GPIO mode')
            return
        if mask >> 16:
            bad(f'pin mask 0x{mask:08X} has bits above pin 15')
            return
        if mode in (MODE_OUT, MODE_AF) and otype is None:
            bad('output type of the descriptor is not a known constant')
            return
        if size == 12 and mode == MODE_AF and af is None:
            bad('alternate function number of the descriptor is not a known constant')
            return
        self.decoded.append(f'{fname} 0x{a:08X} {name} GPIO{port} mask 0x{mask:04X}{"*" if mask == 0xFFFF and not all(b is not None for b in d[0:4]) else ""} '
                            f'{MODE_NAME[mode]} otype {otype} af {af}')
        for pin in range(16):
            if not mask >> pin & 1:
                continue
            af_eff = af
            if size == 8 and mode == MODE_AF:
                af_eff = self.af_pending(fname, port, pin)
            elif size == 12 and mode == MODE_AF and af == BRD_AF_KEEP:
                af_eff = self.af_pending(fname, port, pin)
            why = pin_violation(port, pin, mode, otype if mode in (MODE_OUT, MODE_AF) else 0, af_eff)
            if why is None and mode == MODE_AF and (port, pin) in RESTRICTED_AF and af_eff is None:
                # the AF number is set by a gpio_set_alternate_function call elsewhere in this function (v2.05 calls
                # gpio_init first and the AF setter after it): resolved when the function has been analysed
                self.pending_af.setdefault(fname, []).append((port, pin, a, name))
            if why:
                bad(why)

    # AF numbers set by gpio_set_alternate_function earlier in the same function (v2.05 gpio_init sets the mode only)
    def note_af(self, fname, port, pin, af):
        self.af_seen.setdefault(fname, {})[(port, pin)] = af

    def af_pending(self, fname, port, pin):
        return self.af_seen.get(fname, {}).get((port, pin))

    af_seen = None
    pending_af = None

    @staticmethod
    def fmt(v):
        if v is None:
            return 'unknown'
        if isinstance(v, tuple):
            return f'frame+{v[1]}'
        return f'0x{v:X}'

    # ---- loads / stores ---------------------------------------------------------------------------------------
    def step_load(self, st, insn, base, cond):
        ops = insn.operands
        rt = insn.reg_name(ops[0].reg)
        mop = next(o for o in ops if o.type == AC.ARM_OP_MEM)
        ea = self.mem_ea(st, insn, mop)
        size = {'ldr': 4, 'ldrb': 1, 'ldrh': 2, 'ldrsb': 1, 'ldrsh': 2}.get(base)
        val = None
        if not cond and size and isinstance(ea, int):
            lit = self.elf.read(ea, size)
            if lit is not None and self.in_data(ea):
                val = int.from_bytes(lit, 'little', signed=False)
                if base in ('ldrsb', 'ldrsh'):
                    sign = 1 << (8 * size - 1)
                    val = ((val ^ sign) - sign) & M32
        elif not cond and size and isinstance(ea, tuple):
            val = self.get_mem(st, ea[1], size)
            if val is not None and base in ('ldrsb', 'ldrsh'):
                sign = 1 << (8 * size - 1)
                val = ((val ^ sign) - sign) & M32
        self.writeback(st, insn, mop, ea)
        self.clobber(st, insn)
        if rt != 'pc':
            st.r[RIDX[rt]] = val
        if base == 'ldrd' and len(ops) > 1 and ops[1].type == AC.ARM_OP_REG:
            st.r[RIDX[insn.reg_name(ops[1].reg)]] = None

    def in_data(self, addr):
        return self.data_ok(addr)

    def writeback(self, st, insn, mop, ea):
        """Update the base register of a pre/post-indexed access."""
        ops = insn.operands
        post = len(ops) >= 3 and ops[-1].type in (AC.ARM_OP_IMM, AC.ARM_OP_REG) and ops[-2].type == AC.ARM_OP_MEM
        if not (insn.writeback or post):
            return
        b = RIDX[insn.reg_name(mop.mem.base)]
        if post:
            inc = ops[-1].imm if ops[-1].type == AC.ARM_OP_IMM else None
            bv = st.r[b]
            st.r[b] = None if inc is None or bv is None else (v_add(bv, inc & M32) if inc >= 0 else v_sub(bv, (-inc) & M32))
        else:
            st.r[b] = ea

    def step_store(self, st, insn, base, cond):
        ops = insn.operands
        mop = next(o for o in ops if o.type == AC.ARM_OP_MEM)
        ea = self.mem_ea(st, insn, mop)
        size = {'str': 4, 'strb': 1, 'strh': 2, 'strd': 8, 'strt': 4, 'strbt': 1, 'strht': 2}.get(base, 4)
        rt = ops[0]
        val = st.r[RIDX[insn.reg_name(rt.reg)]] if rt.type == AC.ARM_OP_REG else None
        if isinstance(ea, int):
            self.check_store(insn, ea, size)
        elif isinstance(ea, tuple):
            self.set_mem(st, ea[1], size, None if (cond or not isinstance(val, int) or size == 8) else val & ((1 << 8 * size) - 1))
        self.writeback(st, insn, mop, ea)

    def step_multi(self, st_fname, st, insn, base, cond):
        ops = insn.operands
        regs = [insn.reg_name(o.reg) for o in ops if o.type == AC.ARM_OP_REG]
        spv = st.r[13]
        if base == 'push' or base == 'pop':
            n = len(regs)
            if cond or spv is None:
                st.r[13] = None
            elif base == 'push':
                st.r[13] = v_sub(spv, 4 * n)
                for k in range(n):
                    self.set_mem(st, st.r[13][1] + 4 * k, 4, None)
            else:
                st.r[13] = v_add(spv, 4 * n)
            if base == 'pop':
                for r in regs:
                    if r != 'pc':
                        st.r[RIDX[r]] = None
                return not ('pc' in regs and not cond)
            return True
        # ldm/stm family with an explicit base register
        baseop = ops[0]
        breg = insn.reg_name(baseop.reg)
        lst = regs[1:]
        bv = st.r[RIDX[breg]]
        n = len(lst)
        is_store = base.startswith('stm')
        down = base in ('stmdb', 'stmfd', 'ldmdb')
        if is_store and isinstance(bv, int):
            lo = (bv - 4 * n) & M32 if down else bv
            self.check_store(insn, lo, 4 * n)
        elif is_store and isinstance(bv, tuple):
            lo = bv[1] - 4 * n if down else bv[1]
            for k in range(n):
                self.set_mem(st, lo + 4 * k, 4, None)
        if insn.writeback:
            st.r[RIDX[breg]] = None if bv is None else (v_sub(bv, 4 * n) if down else v_add(bv, 4 * n))
        if not is_store:
            for r in lst:
                st.r[RIDX[r]] = None
            return not ('pc' in lst and not cond)
        return True

    # ---- store address check ----------------------------------------------------------------------------------
    def check_store(self, insn, ea, size):
        self.stats['stores_checked'] += 1
        func = self.current
        if self.roles(insn.address):
            return
        ranges = [(ea, size, 'direct')]
        if BB_PERIPH <= ea < BB_END:                            # bit-band alias of the peripheral region
            byte = 0x40000000 + (ea - BB_PERIPH) // 32
            ranges.append((byte, 1, 'bit-band alias'))
        for (e, sz, how) in ranges:
            for pb, pl in PORTS.items():
                if pb <= e < pb + 0x400:
                    for off, reg in CFG_REGS.items():
                        if e < pb + off + 4 and pb + off < e + sz:
                            self.report(Finding(func, insn.address,
                                                f'{insn.mnemonic} writes GPIO{pl}_{reg} (0x{pb + off:08X}, {how}) outside the BRD objects'))

    current = '?'

    def scan_literals(self, text_spans, data_sp):
        """Step 3: literal words equal to the address of a watched routine."""
        found = []
        for (s, e) in data_sp:
            s4 = (s + 3) & ~3
            for a in range(s4, e - 3, 4):
                w = self.elf.u32(a)
                if w is not None and (w & ~1) in self.watched_addr and self.watched_addr[w & ~1] in WATCHED:
                    found.append((a, self.watched_addr[w & ~1]))
        return found

    # ---- ALU --------------------------------------------------------------------------------------------------
    BINARY = {'orr': lambda p, q: p | q, 'and': lambda p, q: p & q, 'bic': lambda p, q: p & ~q,
              'eor': lambda p, q: p ^ q, 'lsl': lambda p, q: (p << q) if q < 32 else 0,
              'lsr': lambda p, q: (p >> q) if q < 32 else 0, 'rsb': lambda p, q: q - p, 'mul': lambda p, q: p * q}
    ALU_NAMES = {'mov': 'mov', 'movs': 'mov', 'movw': 'mov', 'mvn': 'mvn', 'mvns': 'mvn', 'add': 'add', 'adds': 'add',
                 'addw': 'add', 'sub': 'sub', 'subs': 'sub', 'subw': 'sub', 'movt': 'movt', 'adr': 'adr',
                 'uxtb': 'uxtb', 'uxth': 'uxth'}
    for _n in BINARY:
        ALU_NAMES[_n] = _n
        ALU_NAMES[_n + 's'] = _n

    def step_alu(self, st, insn, base):
        """Data-processing instruction: the destination gets its value when the operation is one of ALU_NAMES with
        known operands, otherwise it becomes unknown.  Compares and tests (no destination) change nothing."""
        ops = insn.operands
        old = list(st.r)
        self.clobber(st, insn)                                  # every register the instruction writes: unknown
        name = self.ALU_NAMES.get(base)
        if name is None or not ops or ops[0].type != AC.ARM_OP_REG:
            return
        rd = RIDX[insn.reg_name(ops[0].reg)]
        if rd == 15:
            return
        src = [self.op_val_from(old, insn, o) for o in ops[1:]]
        res = None
        if name == 'movt':
            if isinstance(old[rd], int) and ops[1].type == AC.ARM_OP_IMM:
                res = ((ops[1].imm & 0xFFFF) << 16) | (old[rd] & 0xFFFF)
        elif name == 'adr':                                     # rd = Align(pc + 4, 4) + imm
            res = (((insn.address + 4) & ~3) + ops[1].imm) & M32
        elif name == 'mov' and len(ops) == 2:
            res = src[0]
        elif name in ('add', 'sub') or name in self.BINARY:
            x, y = (old[rd], src[0]) if len(src) == 1 else (src[0], src[1])          # two-operand form: rd op= x
            if name == 'add':
                res = v_add(x, y)
            elif name == 'sub':
                res = v_sub(x, y)
            elif isinstance(x, int) and isinstance(y, int):
                res = self.BINARY[name](x, y) & M32
        elif name == 'uxtb' and isinstance(src[0], int):
            res = src[0] & 0xFF
        elif name == 'uxth' and isinstance(src[0], int):
            res = src[0] & 0xFFFF
        elif name == 'mvn' and isinstance(src[0], int):
            res = ~src[0] & M32
        st.r[rd] = res

    def op_val_from(self, regs, insn, op):
        if op.type == AC.ARM_OP_IMM:
            return op.imm & M32
        if op.type == AC.ARM_OP_REG:
            nm = insn.reg_name(op.reg)
            if nm == 'pc':
                return (insn.address + 4) & M32
            if getattr(op, 'shift', None) is not None and op.shift.type:
                return None
            return regs[RIDX[nm]]
        return None


# =====================================================================================================================
# brd_pin_policy audit and brd_fe_table comparison
# =====================================================================================================================
def audit_policy_table(elf, report):
    """The run-time policy table must not allow anything the policy of this tool forbids."""
    sym = elf.by_name.get('brd_pin_policy')
    if sym is None or sym['size'] != 8 * 28:
        report(Finding('brd_pin_policy', 0, 'symbol missing or not 8 entries of 28 bytes'))
        return 0
    raw = elf.read(sym['value'], sym['size'])
    order = ['A', 'B', 'C', 'D', 'E', 'H', 'F', 'G']                     # port index (base - 0x40020000) / 0x400
    n = 0
    for pi, port in enumerate(order):
        e = raw[pi * 28:(pi + 1) * 28]
        pp, od, afm, inp, an = struct.unpack_from('<5H', e, 0)
        afnum = e[12:28]
        for pin in range(16):
            bit = 1 << pin
            cfgs = []
            if pp & bit:
                cfgs.append((MODE_OUT, 0, None, 'push-pull output'))
            if od & bit:
                cfgs.append((MODE_OUT, 1, None, 'open-drain output'))
            if afm & bit:
                cfgs.append((MODE_AF, 0, afnum[pin], f'alternate function AF{afnum[pin]}'))
            if inp & bit:
                cfgs.append((MODE_IN, 0, None, 'input'))
            if an & bit:
                cfgs.append((MODE_AN, 0, None, 'analog'))
            for (mode, ot, af, txt) in cfgs:
                n += 1
                why = pin_violation(port, pin, mode, ot, af)
                if why:
                    report(Finding('brd_pin_policy', sym['value'] + pi * 28,
                                   f'run-time policy allows P{port}{pin} as {txt}: {why}'))
    return n


def load_fe_levels(path):
    """Parse tools/fe_levels.txt into {(row, filter, diode, range0, c7): 'HLH...'} (see the file header for the format)."""
    table, errors = {}, []
    rx = re.compile(r'^row\s+(\d+|other)\s+filter=([01*])\s+diode=([01*])\s+range0=([01*])\s+c7=([01*])\s+([HL]{12})\s*$')
    with open(path) as f:
        for ln, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            m = rx.match(s)
            if not m:
                errors.append(f'{path} line {ln}: not a rule: {s!r}')
                continue
            row = FE_ROWS - 1 if m.group(1) == 'other' else int(m.group(1))
            if row >= FE_ROWS:
                errors.append(f'{path} line {ln}: row {row} out of range')
                continue
            opts = [(0, 1) if g == '*' else (int(g),) for g in m.groups()[1:5]]
            for f_ in opts[0]:
                for d_ in opts[1]:
                    for r_ in opts[2]:
                        for c_ in opts[3]:
                            k = (row, f_, d_, r_, c_)
                            if k in table:
                                errors.append(f'{path} line {ln}: combination {k} given twice')
                            table[k] = m.group(6)
    for row in range(FE_ROWS):
        for f_ in (0, 1):
            for d_ in (0, 1):
                for r_ in (0, 1):
                    for c_ in (0, 1):
                        if (row, f_, d_, r_, c_) not in table:
                            errors.append(f'{path}: combination (row {row}, filter {f_}, diode {d_}, range0 {r_}, c7 {c_}) not covered')
    return table, errors


def check_fe_table(elf, report):
    sym = elf.by_name.get('brd_fe_table')
    if sym is None:
        report(Finding('brd_fe_table', 0, 'symbol not found in the ELF'))
        return 0
    if sym['size'] != FE_ROWS * 16 * 2:
        report(Finding('brd_fe_table', sym['value'], f'size {sym["size"]} bytes, expected {FE_ROWS * 16 * 2}'))
        return 0
    raw = elf.read(sym['value'], sym['size'])
    if raw is None:
        report(Finding('brd_fe_table', sym['value'], 'table is not in a loaded section'))
        return 0
    try:
        ref, errors = load_fe_levels(FE_LEVELS)
    except OSError as e:
        report(Finding('fe_levels.txt', 0, f'cannot read: {e}'))
        return 0
    for e in errors:
        report(Finding('fe_levels.txt', 0, e))
    n = 0
    for (row, f_, d_, r_, c_), lv in sorted(ref.items()):
        idx = row * 16 + f_ * 8 + d_ * 4 + r_ * 2 + c_
        word = struct.unpack_from('<H', raw, 2 * idx)[0]
        got = ''.join('H' if word >> k & 1 else 'L' for k in range(12))
        n += 1
        if word >> 12:
            report(Finding('brd_fe_table', sym['value'] + 2 * idx, f'index {idx}: bits 12..15 are not zero (0x{word:04X})'))
        if got != lv:
            diff = ', '.join(f'{FE_COLS[k]} table {got[k]} / fe_levels {lv[k]}' for k in range(12) if got[k] != lv[k])
            rowname = 'other' if row == FE_ROWS - 1 else str(row)
            report(Finding('brd_fe_table', sym['value'] + 2 * idx,
                           f'row {rowname} filter {f_} diode {d_} range0 {r_} c7 {c_} (index {idx}): {diff}'))
    return n


# =====================================================================================================================
# driver
# =====================================================================================================================
def main(argv):
    args = argv[1:]
    mapfile = None
    verbose = '-v' in args or '--verbose' in args
    args = [x for x in args if x not in ('-v', '--verbose')]
    if '--map' in args:
        i = args.index('--map')
        mapfile = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        print(__doc__.split('\n\n')[0])
        print('usage: check_gpio.py <elf> [--map <map>] [-v]')
        return 2
    elfpath = args[0]
    if mapfile is None:
        mapfile = os.path.splitext(elfpath)[0] + '.map'
    try:
        elf = Elf(elfpath)
    except (OSError, ValueError, struct.error) as e:
        print(f'check_gpio: cannot read {elfpath}: {e}')
        return 2
    try:
        spans = parse_map(mapfile)
    except OSError as e:
        print(f'check_gpio: cannot read the linker map {mapfile}: {e}')
        return 2
    if not spans:
        print(f'check_gpio: no input sections found in {mapfile}')
        return 2

    def is_brd(addr):
        for (s, e, obj) in spans:
            if s <= addr < e:
                return ('/' + obj.replace('\\', '/')).find('/brd/') >= 0
        return False

    findings = []
    report = findings.append
    an = Analyzer(elf, is_brd, report)
    an.af_seen = {}
    an.pending_af = {}
    an.data_ok = lambda addr: any(s <= addr < e for (s, e) in dspans)
    cspans = code_spans(elf)
    dspans = data_spans(elf)
    funcs = sorted({(s['value'] & ~1, s['name']) for s in elf.symbols if s['type'] == 2 and s['name']
                    and any(cs <= (s['value'] & ~1) < ce for cs, ce in cspans)})
    nfunc = 0
    for (cs, ce) in cspans:
        inside = [(a, n) for (a, n) in funcs if cs <= a < ce]
        if not inside or inside[0][0] > cs:
            inside.insert(0, (cs, f'<code at 0x{cs:08X}>'))
        for k, (a, n) in enumerate(inside):
            b = inside[k + 1][0] if k + 1 < len(inside) else ce
            an.current = n
            an.analyse(n, a, b)
            nfunc += 1
    for (a, name) in an.scan_literals(cspans, dspans):
        fn = next((n for (fa, n) in reversed(funcs) if fa <= a), '?')
        findings.append(Finding(fn, a, f'literal word holds the address of {name}: indirect calls cannot be decoded'))
    npol = audit_policy_table(elf, report)
    nfe = check_fe_table(elf, report)

    print(f'check_gpio: {elfpath}: {nfunc} code regions, {an.stats["calls"]} GPIO routine call sites decoded or exempted, '
          f'{an.stats["stores_checked"]} constant-address stores checked, {npol} run-time policy entries audited, '
          f'{nfe} brd_fe_table words compared')
    if verbose:
        for line in an.decoded:
            print('call ' + line)
    for fn, why in sorted(an.used_exemptions.items()):
        kind = 'probe allowlist' if fn in PROBE_ALLOWLIST else 'wrapper'
        print(f'exempt ({kind}): {fn}: {why}')
    for f in sorted(findings, key=lambda f: (f.addr, f.func, f.text)):
        print(f)
    print('check_gpio: ' + ('PASS' if not findings else f'FAIL ({len(findings)} findings)'))
    return 0 if not findings else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
