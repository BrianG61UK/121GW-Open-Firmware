#!/usr/bin/env python3
"""check_hy.py - HY3131 write-whitelist check of the linked firmware (DESIGN.md 4.1 item 7, 9.3 items 3 and 4).

Usage (from firmware/, as the Makefile does):
    python3 -I tools/check_hy.py build/121gw.elf [--map build/121gw.map] [--v205 ../inputs/binaries/EEVBlog2_05.bin]
    python3 -I tools/check_hy.py --reference            (v2.05 only: the numbers of DESIGN 4.1 from the original image)
Needs Python 3 with Capstone and Unicorn (the project Python: make check PYTHON=<python with both modules>).
Exit status 0 = PASS, 1 = at least one violation, 2 = the tool could not do its job.

The HY3131 is configured only by 20-byte rows and a few short register writes (DESIGN 4.1).  The port must write nothing
that the original (v2.05) cannot write.  The reference is the original image, executed, not a list typed in: its
configuration routine 0x0800B974(mode, range) is run for every mode 0..24, every range below range_count[mode] and every
combination of the RAM flags it reads (the method of analysis/hy3131_model.md section 3, "Method note"; flag value sets
from hy3131_model.md and hy3131_modes_*.md, quoted at FLAGS below), in Unicorn, with the SPI write routine 0x0800C03C
intercepted to record every frame (first register, data bytes).  The same sweep is run on the port (symbol
fn_0800B974, frame writer hy3131_write_regs).  Checks:
  1. Tables (4.1 item 7): each of the 15 row tables v205_tab_XXXXXXXX of the ELF equals the v2.05 image bytes at its address.
  2. Reference numbers (DESIGN 4.1, 4): the v2.05 sweep yields 41 distinct rows, 47 distinct (row, INTE) pairs and the six
     frame shapes (0x20,20) (0x1E,2) (0x1E,1) (0x20,1) (0x1B,3) (0x29,1); other numbers fail (the design text would be
     wrong), so the reference cannot drift silently.
  3. Equality: the port's reachable (row, INTE) pairs equal the v2.05 pairs; every frame the port requests during the sweep is
     a frame of the v2.05 sweep, its restart sequence follows; for each (mode, range, flags) the port's frame sequence equals
     the v2.05 sequence (reported as HY-SEQ otherwise).  The peak-restart routine is run for every row R29 with ENPKH set
     and must write R29 & 0xFB then R29 (v2.05 0x0800A872 / 0x0800A88C, modes 13..15 excluded by the caller).
  4. Wire level: for one representative of every distinct frame sequence the port is run without any interception and
     the bus pins are decoded from the GPIOF BSRR writes (PF0 CK, PF1 CS, PF2 DI; DS p14 frame format: CS low, address
     byte = register << 1 | R/W, data bytes MSB first, DI sampled at the rising CK edge).  The bus frames must equal the
     requested frames: the port's own run-time guard must not refuse any v2.05 sequence.
  5. Guard probe: with the port's loaded-row state set, every single-bit mutation of every v2.05 frame, every
     (register 0..0x3F, count 1..24) that is not one of the six shapes, and the soft-reset write 0x37 = 0x60 are offered to
     hy3131_write_regs: each must be refused (return value 1) with no pin touched; every v2.05 frame must be accepted.
     The IRQ acknowledge (0x1E, 1) is checked against INTF_ACK (OF-53: any value with bits 6:5 clear, see INTF_ACK).
  6. Random RAM: 300 runs with flag bytes set to random values 0..255 (fixed seed): every frame that reaches the bus is a
     v2.05 frame (a corrupted RAM cannot make the port write a row that v2.05 never writes).
  7. Instruction level (module check_image): outside the HY bus routines (hy3131_spi_clock_pulse, hy3131_spi_write_byte,
     hy3131_spi_read_byte, hy_write_frame, hy_read_frame, hy3131_write_regs, hy3131_read_regs_to_rxbuf) no store sets
     GPIOF pin 0 (HY_CK) high, and no store addresses GPIOF ODR; stores that change pin 1 or 2 or clear pin 0 are allowed only in
     objects under hy/, brd/ and sys/fault.o (idle levels: board init, power-down, fault-safe state, DESIGN 4.1 item 7);
     a store to GPIOF BSRR / ODR whose value is not known and which is not in one of those objects is reported.
Limits: the flag value sets are those of the analysis documents; a flag byte holding another value is covered only by check 6
at bus level.  Peripheral reads other than the SPI read routines return 0.  Time is not modelled.
"""
import argparse
import importlib.util
import itertools
import os
import random
import re
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
TOOLS = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    """Import a sibling tool by path (python -I removes the script directory from sys.path)."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(TOOLS, name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


try:
    from unicorn import (Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UC_HOOK_CODE, UC_HOOK_MEM_READ,
                         UC_HOOK_MEM_WRITE, UC_PROT_ALL, UcError)
    from unicorn.arm_const import (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_LR, UC_ARM_REG_PC,
                                   UC_ARM_REG_SP)
except ImportError:                                           # pragma: no cover - environment problem
    sys.stderr.write('check_hy.py: the Python module unicorn is required (use the project Python)\n')
    sys.exit(2)

ci = _load('check_image')
v205 = _load('v205')

APP_BASE = 0x08006000
STOP = 0x08005FF0                    # return address that ends a run (bootloader window, never executed)
SP0 = 0x20001240
V205_SELECT, V205_WRITE, V205_READ, V205_DELAY = 0x0800B974, 0x0800C03C, 0x0800C0C0, 0x0800ECF6
MODE, RANGE = 0x2000803C, 0x2000803D
GPIOF = 0x40021800
BSRRL, BSRRH, ODR = GPIOF + 0x18, GPIOF + 0x1A, GPIOF + 0x14
SHAPES = ((0x20, 20), (0x1E, 2), (0x1E, 1), (0x20, 1), (0x1B, 3), (0x29, 1))
# The IRQ acknowledge (0x1E, 1) after an event service (v2.05 0x0800616C writes 0x00).  OF-53 (owner decision): the port
# writes 0 for the INTF flags it has read as set and 1 for the others, so a flag raised after the read is not discarded.
# INTF is a flag register, not a configuration register: a written 0 clears a flag, a written 1 has no effect ("INTF
# register can be written as 0 by SPI Interface, but not 1", HY3131 data sheet p19 10.2 (7)); bits 6:5 carry no flag
# ("-", data sheet p19) and are written 0 as v2.05 writes them.  So every value with bits 6:5 clear is allowed: none can
# change the chip's configuration, and the value 0x00 of v2.05 is among them.
INTF_ACK = {(0x1E, bytes([v])) for v in range(256) if not v & 0x60}
TABLE_ADDRS = (0x080285BC, 0x080286D0, 0x08028748, 0x080288A0, 0x08028904, 0x080289C8, 0x08028D1C, 0x08028D58,
               0x08028D94, 0x08028F1C, 0x08028F44, 0x08028F6C, 0x08028F94, 0x08028FBC, 0x08029150)   # DESIGN 4.1
EXPECT_ROWS, EXPECT_PAIRS = 41, 47                              # DESIGN 4.1
# RAM flags read by the selector and their value sets (hy3131_model.md section 3 flag legend; hy3131_modes_misc.md
# section 0 and 3.1; hy3131_modes_ac_current.md "Sub-ranges"): 0x20008098 LowZ AC, 0x200080B7 peak, 0x200080B9 1 kHz
# filter, 0x200080BA AC+DC, 0x200080BD AC+DC phase, 0x20007FE0 OHM range 6 flag, 0x20007FDF CAP variant, 0x200080C4 VA
# channel, 0x200080C6 voltage sub-range, 0x200080C7 current sub-range (2 only in modes 15 and 24).
FLAGS = {0x20008098: (0, 1), 0x200080B7: (0, 1), 0x200080B9: (0, 1), 0x200080BA: (0, 1), 0x200080BD: (0, 1),
         0x20007FE0: (0, 1), 0x20007FDF: (0, 1), 0x200080C4: (0, 1), 0x200080C6: (0, 1), 0x200080C7: (0, 1, 2)}
VA_MODES = (13, 14, 15, 22, 23, 24)
C7_TWO_MODES = (15, 24)
PRESET_WORD = 0x2000001C                                       # counter preset word, read by the restart
HY_BUS_FUNCS = ('hy3131_spi_clock_pulse', 'hy3131_spi_write_byte', 'hy3131_spi_read_byte', 'hy_write_frame',
                'hy_read_frame', 'hy3131_write_regs', 'hy3131_read_regs_to_rxbuf')


class CheckError(Exception):
    pass


def fmt_flags(key):
    """Readable form of a flag assignment (sorted (address, value) items)."""
    return '{' + ', '.join('0x%08X: %d' % kv for kv in key) + '}' if key else '-'


def va_range(c6, c7):
    """meter_range of a VA mode from the sub-ranges (hy3131_modes_ac_current.md): (0,0) -> 0, (1,0) -> 1, (0,!=0) -> 2, (1,!=0) -> 3."""
    return (0 if c6 == 0 else 1) if c7 == 0 else (2 if c6 == 0 else 3)


# ---------------------------------------------------------------------------------------------------- the world
class World:
    """One Unicorn instance with an image at 0x08006000, the RAM initial image and scripted peripherals."""

    def __init__(self, flash, ram_init, syms, port):
        self.flash, self.ram_init, self.syms, self.port = flash, ram_init, syms, port

    def build(self, hooks, wire=False, trace_reads=False):
        uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
        uc.mem_map(0x08000000, 0x60000, UC_PROT_ALL)
        for addr, data in self.flash:
            uc.mem_write(addr, data)
        uc.mem_map(0x20000000, 0xC000, UC_PROT_ALL)
        uc.mem_write(0x20000000, self.ram_init)
        uc.mem_map(0x40000000, 0x100000, UC_PROT_ALL)            # peripherals as plain memory
        run = {'frames': [], 'reads': set(), 'written': set(), 'wire': [], 'wire_partial': 0, 'pins': {}}
        run['bus'] = Bus(run) if wire else None

        def code(u, addr, size, _):
            fn = hooks.get(addr & ~1)
            if fn:
                fn(u, run)
        for addr in hooks:
            uc.hook_add(UC_HOOK_CODE, code, begin=addr, end=addr)
        if trace_reads:
            def mread(u, access, addr, size, value, _):
                if 0x20000000 <= addr < 0x2000C000:
                    sp = u.reg_read(UC_ARM_REG_SP)
                    if not (sp - 0x100 <= addr < SP0):
                        for a in range(addr, addr + size):
                            if a not in run['written']:
                                run['reads'].add(a)

            def mwrite(u, access, addr, size, value, _):
                run['written'].update(range(addr, addr + size))
            uc.hook_add(UC_HOOK_MEM_READ, mread)
            uc.hook_add(UC_HOOK_MEM_WRITE, mwrite)
        if wire:
            def gpiof(u, access, addr, size, value, _):
                run['bus'].store(addr, size, value)
            uc.hook_add(UC_HOOK_MEM_WRITE, gpiof, begin=ODR, end=ODR + 0x7)
        return uc, run

    def finish_restart(self, uc, step, run, label, count=3_000_000):
        """Finish a pending counter restart of the port (production build: hy_counter_restart_step).  While the TIM3 wait
        hy_restart_ticks is armed the step must report busy (0) and send nothing; this checker runs no interrupts, so the
        count-down of bzb_tim3_isr is stood in for by writing 0 to hy_restart_ticks, after which the step must finish."""
        ticks = self.syms.get('hy_restart_ticks')
        if ticks is not None and uc.mem_read(ticks, 1)[0]:
            n_frames, n_wire = len(run['frames']), len(run['wire'])
            if self.call(uc, step, count=count) != 0 or len(run['frames']) != n_frames or len(run['wire']) != n_wire:
                raise CheckError('%s: restart step did not wait for its TIM3 ticks' % label)
            uc.mem_write(ticks, b'\x00')                 # the TIM3 count-down (bzb_tim3_isr) has run out
        for _ in range(100):
            if self.call(uc, step, count=count) == 1:
                return
        raise CheckError('%s: restart step never finished' % label)

    @staticmethod
    def call(uc, addr, args=(), count=3_000_000):
        for r, v in zip((UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2), args):
            uc.reg_write(r, v & 0xFFFFFFFF)
        uc.reg_write(UC_ARM_REG_SP, SP0)
        uc.reg_write(UC_ARM_REG_LR, STOP | 1)
        uc.emu_start(addr | 1, STOP, count=count)
        if uc.reg_read(UC_ARM_REG_PC) != STOP:
            raise CheckError('routine at 0x%08X did not return (pc 0x%08X)' % (addr, uc.reg_read(UC_ARM_REG_PC)))
        return uc.reg_read(UC_ARM_REG_R0)


class Bus:
    """HY3131 bus decoder on GPIOF stores (PF0 CK, PF1 CS, PF2 DI): frames of one address byte and data bytes (DS p14)."""

    def __init__(self, run):
        self.run = run
        self.pins = 0x0002 | 0x0004          # CS and DI high at the start of a run, CK low
        self.cs, self.ck, self.di = 1, 0, 1
        self.bits = []
        self.addr = None
        self.data = []

    def store(self, addr, size, value):
        if addr == ODR:
            self.run['odr_write'] = True
            return
        if addr == BSRRL and size == 2:
            self.apply(value & 0xFFFF, 0)
        elif addr == BSRRH and size == 2:
            self.apply(0, value & 0xFFFF)
        elif addr == BSRRL and size == 4:
            self.apply(value & 0xFFFF, value >> 16)
        else:
            self.run['odr_write'] = True

    def apply(self, setm, clrm):
        old_cs, old_ck = self.cs, self.ck
        new = ((self.cs << 1) | (self.ck << 0) | (self.di << 2))
        new = (new & ~clrm) | setm
        self.cs, self.ck, self.di = (new >> 1) & 1, new & 1, (new >> 2) & 1
        if old_cs and not self.cs:                       # frame start
            self.bits, self.addr, self.data = [], None, []
        if not self.cs and not old_ck and self.ck:       # rising CK edge: DI sampled
            self.bits.append(self.di)
            if len(self.bits) == 8:
                v = int(''.join(map(str, self.bits)), 2)
                self.bits = []
                if self.addr is None:
                    self.addr = v
                else:
                    self.data.append(v)
        if self.cs and old_cs == 0:                      # frame end
            if self.addr is not None:
                reg, rw = self.addr >> 1, self.addr & 1
                if rw == 0:                              # a write frame must end on a byte boundary
                    if self.bits:
                        self.run['wire_partial'] += 1
                    self.run['wire'].append((reg, bytes(self.data)))
            self.bits, self.addr, self.data = [], None, []


# ---------------------------------------------------------------------------------------------------- hooks
def hook_ret(u, run):
    u.reg_write(UC_ARM_REG_PC, u.reg_read(UC_ARM_REG_LR))


def hook_write(u, run):
    buf, reg, n = (u.reg_read(r) for r in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2))
    run['frames'].append((reg, bytes(u.mem_read(buf, n))))
    u.reg_write(UC_ARM_REG_R0, 0)
    u.reg_write(UC_ARM_REG_PC, u.reg_read(UC_ARM_REG_LR))


# ---------------------------------------------------------------------------------------------------- sweep
def sweep(world, select, write, read, delay, step, range_count, label):
    """All (mode, range, flags) runs of the selector.  Returns {key: frame list} with key = (mode, range, flag items)."""
    hooks = {write: hook_write, read: hook_ret, delay: hook_ret}
    out = {}
    unknown = set()
    for mode in range(25):
        va = mode in VA_MODES
        base_flags = [0x200080C6, 0x200080C7] if va else []
        domains = {f: ((0, 1) if f == 0x200080C7 and mode not in C7_TWO_MODES else FLAGS[f]) for f in FLAGS}
        for combo in itertools.product(*[domains[f] for f in base_flags]):
            start = dict(zip(base_flags, combo))
            rngs = [va_range(start[0x200080C6], start[0x200080C7])] if va else list(range(range_count[mode]))
            for rng in rngs:
                pending, seen = [dict(start)], set()
                while pending:
                    asg = pending.pop()
                    key = tuple(sorted(asg.items()))
                    if key in seen:
                        continue
                    seen.add(key)
                    uc, run = world.build(hooks, trace_reads=True)
                    uc.mem_write(MODE, bytes([mode]))
                    uc.mem_write(RANGE, bytes([rng]))
                    for a, v in asg.items():
                        uc.mem_write(a, bytes([v]))
                    r = world.call(uc, select, (mode, rng))
                    if step:
                        world.finish_restart(uc, step, run, '%s (mode %d range %d)' % (label, mode, rng))
                    out[(mode, rng, key)] = (run['frames'], r)
                    for a in sorted(run['reads']):
                        if a in FLAGS and a not in asg:
                            for v in domains[a]:
                                nxt = dict(asg)
                                nxt[a] = v
                                pending.append(nxt)
                        elif not (a in (MODE, RANGE) or 0x20000000 <= a < 0x20000019 or PRESET_WORD <= a < PRESET_WORD + 4
                                  or a in FLAGS or a >= 0x20008100 or 0x2000023E <= a < 0x20001240):
                            unknown.add(a)
    if unknown:
        raise CheckError('%s: the selector reads RAM that the sweep does not vary: %s (the sweep would not be exhaustive)'
                         % (label, ', '.join('0x%08X' % a for a in sorted(unknown))))
    return out


def pairs_of(results):
    """(rows, pairs, frame set, shape set) of a sweep result."""
    rows, pairs, frames, shapes = set(), set(), set(), set()
    for (mode, rng, key), (fr, ret) in results.items():
        for f in fr:
            frames.add(f)
            shapes.add((f[0], len(f[1])))
        if len(fr) >= 2 and fr[0][0] == 0x20 and len(fr[0][1]) == 20 and fr[1][0] == 0x1E and len(fr[1][1]) == 2:
            rows.add(fr[0][1])
            pairs.add((fr[0][1], fr[1][1][1]))
    return rows, pairs, frames, shapes


# ---------------------------------------------------------------------------------------------------- port image
def load_port(elfpath, mappath):
    img, elf = ci.load_elf_image(elfpath, mappath)
    syms = {y['name']: (y['value'] & ~1 if y['type'] == 2 else y['value']) for y in img.symbols
            if y['shndx'] != 0 and y['name']}          # clear the Thumb bit of functions only
    ram = bytearray(0x23E)
    got = False
    for s in elf.segments:
        if s['type'] == 1 and s['vaddr'] == 0x20000000 and s['filesz']:
            ram[0:s['filesz']] = elf.data[s['off']:s['off'] + s['filesz']]
            got = True
    if not got:
        raise CheckError('the ELF has no .data_v205 segment at 0x20000000')
    return img, elf, syms, bytes(ram)


def need(syms, *names):
    miss = [n for n in names if n not in syms]
    if miss:
        raise CheckError('symbols missing in the ELF: ' + ', '.join(miss))
    return [syms[n] for n in names]


# ---------------------------------------------------------------------------------------------------- the checks
def check_tables(img, elf, vio, ref):
    n = 0
    byname = {y['name']: y for y in img.symbols if y['shndx'] != 0}
    for a in TABLE_ADDRS:
        nm = 'v205_tab_%08X' % a
        y = byname.get(nm)
        if y is None:
            vio.append('HY-TAB %s is not defined in the ELF' % nm)
            continue
        size = y['size']
        got = img.read(y['value'] & ~1, size)
        want = ref[a - APP_BASE:a - APP_BASE + size]
        if size == 0 or got is None or got != want:
            vio.append('HY-TAB %s (%d bytes) differs from the v2.05 image at 0x%08X' % (nm, size, a))
        else:
            n += 1
    return n


def check_sequences(ref, port, vio):
    same, diff = 0, []
    for k, (fr, ret) in sorted(ref.items()):
        pf = port.get(k)
        if pf is None:
            diff.append((k, 'missing in the port sweep'))
        elif pf[0] != fr:
            diff.append((k, 'port %s, v2.05 %s' % ([(hex(a), b.hex()) for a, b in pf[0]][:3], [(hex(a), b.hex()) for a, b in fr][:3])))
        else:
            same += 1
    for k in port:
        if k not in ref:
            diff.append((k, 'only in the port sweep'))
    for k, why in diff[:10]:
        vio.append('HY-SEQ mode %d range %d flags %s: %s' % (k[0], k[1], fmt_flags(k[2]), why))
    if len(diff) > 10:
        vio.append('HY-SEQ ... %d more sequences differ' % (len(diff) - 10))
    return same, len(ref)


def check_wire(world, syms, ref, vio):
    """Run one representative of every distinct v2.05 sequence on the port without interception."""
    sel = syms['fn_0800B974']
    step = syms.get('hy_counter_restart_step')
    seen, n = {}, 0
    for k, (fr, ret) in sorted(ref.items()):
        sig = tuple(fr)
        if sig in seen:
            continue
        seen[sig] = k
    hooks = {syms['fn_0800ECF6']: hook_ret}
    for sig, k in seen.items():
        mode, rng, key = k
        uc, run = world.build(hooks, wire=True)
        uc.mem_write(MODE, bytes([mode]))
        uc.mem_write(RANGE, bytes([rng]))
        for a, v in key:
            uc.mem_write(a, bytes([v]))
        world.call(uc, sel, (mode, rng), count=6_000_000)
        if step:
            world.finish_restart(uc, step, run, 'wire (mode %d range %d)' % (mode, rng), count=6_000_000)
        wire = run['wire']
        if wire != list(sig):
            vio.append('HY-WIRE mode %d range %d flags %s: bus frames %s differ from the requested v2.05 frames %s'
                       % (mode, rng, fmt_flags(key), [(hex(a), b.hex()) for a, b in wire][:4],
                          [(hex(a), b.hex()) for a, b in sig][:4]))
        if run['wire_partial']:
            vio.append('HY-WIRE mode %d range %d: %d frames ended with a partial byte' % (mode, rng, run['wire_partial']))
        n += 1
    return n


def check_peak(world, syms, rows, vio):
    if 'hy_peak_restart' not in syms:
        vio.append('HY-PEAK hy_peak_restart is not defined')
        return 0
    n = 0
    hooks = {syms['hy3131_write_regs']: hook_write, syms['fn_0800ECF6']: hook_ret}
    for row in sorted(rows):
        r29 = row[9]                                           # register 0x29 = row byte 9
        if not r29 & 4:
            continue                                           # the routine runs only with ENPKH set (hy3131_model.md 2.1)
        uc, run = world.build(hooks)
        uc.mem_write(syms['hy_row_valid'], b'\x01')
        uc.mem_write(syms['hy_row_r29'], bytes([r29]))
        world.call(uc, syms['hy_peak_restart'])
        want = [(0x29, bytes([r29 & 0xFB])), (0x29, bytes([r29]))]
        if run['frames'] != want:
            vio.append('HY-PEAK R29 0x%02X: frames %s, expected %s' % (r29, [(hex(a), b.hex()) for a, b in run['frames']],
                                                                       [(hex(a), b.hex()) for a, b in want]))
        n += 1
    return n


def guard_probe(world, syms, ref_frames, rows, vio):
    """Offer mutated frames to the port's checked writer; see the module docstring, check 5."""
    wr = syms['hy3131_write_regs']
    hooks = {syms['fn_0800ECF6']: hook_ret}
    uc, run = world.build(hooks, wire=True)
    probes = 0

    def offer(reg, data, r20=0x00, r29=0x00):
        """returns (return value, bus frames)"""
        uc.mem_write(syms['hy_row_r20'], bytes([r20]))
        uc.mem_write(syms['hy_row_r29'], bytes([r29]))
        uc.mem_write(syms['hy_row_valid'], b'\x01')
        uc.mem_write(0x20006000, data + bytes(8))
        run['wire'].clear()
        r = world.call(uc, wr, (0x20006000, reg, len(data)), count=2_000_000)
        return r, list(run['wire'])
    allowed_static = {f for f in ref_frames}
    # state-dependent frames: loaded row state for the R20 / R29 values (DESIGN 4.1 item 3 formulas)
    for row in sorted(rows):
        r20, r29 = row[0], row[9]
        for reg, val in ((0x20, r20 & 0xFD), (0x20, r20 & 0xF9), (0x20, r20 | 2), (0x29, r29 & 0xFB), (0x29, r29)):
            r, w = offer(reg, bytes([val]), r20, r29)
            probes += 1
            if r != 0 or w != [(reg, bytes([val]))]:
                vio.append('HY-GUARD the v2.05 frame (0x%02X, %02X) for the row with R20 %02X R29 %02X was refused (%d, %s)'
                           % (reg, val, r20, r29, r, w))
        for bad in (r20 ^ 0x01, r20 ^ 0x10, r20 ^ 0x80):
            if bad in (r20 & 0xFD, r20 & 0xF9, r20 | 2):
                continue
            r, w = offer(0x20, bytes([bad]), r20, r29)
            probes += 1
            if r != 1 or w:
                vio.append('HY-GUARD (0x20, %02X) with loaded R20 %02X was not refused (%d, %s)' % (bad, r20, r, w))
        for bad in (r29 ^ 0x01, r29 ^ 0x08, r29 ^ 0x80):
            if bad in (r29 & 0xFB, r29):
                continue
            r, w = offer(0x29, bytes([bad]), r20, r29)
            probes += 1
            if r != 1 or w:
                vio.append('HY-GUARD (0x29, %02X) with loaded R29 %02X was not refused (%d, %s)' % (bad, r29, r, w))
    # static frames: all must be accepted; every single-bit mutation must be refused unless it is itself a v2.05 frame
    static = sorted(f for f in ref_frames if (f[0], len(f[1])) in ((0x20, 20), (0x1E, 2), (0x1E, 1), (0x1B, 3)))
    for reg, data in static:
        r, w = offer(reg, data)
        probes += 1
        if r != 0 or w != [(reg, data)]:
            vio.append('HY-GUARD the v2.05 frame (0x%02X, %s) was refused (%d, %s)' % (reg, data.hex(), r, w))
        for i in range(len(data)):
            for b in range(8):
                m = bytearray(data)
                m[i] ^= 1 << b
                mut = (reg, bytes(m))
                if mut in ref_frames:
                    continue
                r, w = offer(*mut)
                probes += 1
                if r != 1 or w:
                    vio.append('HY-GUARD the mutated frame (0x%02X, %s) was accepted (%d, %s)' % (reg, bytes(m).hex(), r, w))
    # shapes
    allowed_shapes = set(SHAPES)
    for reg in range(0x40):
        for cnt in range(1, 25):
            if (reg, cnt) in allowed_shapes:
                continue
            r, w = offer(reg, bytes([0x60] * cnt))
            probes += 1
            if r != 1 or w:
                vio.append('HY-GUARD shape (0x%02X, %d) was not refused (%d, %s)' % (reg, cnt, r, w))
    # the soft reset write 0x37 = 0x60 is covered by the shape loop; say so by an explicit probe
    r, w = offer(0x37, b'\x60')
    probes += 1
    if r != 1 or w:
        vio.append('HY-GUARD the soft reset write 0x37 = 0x60 was not refused')
    return probes


def random_ram(world, syms, ref_frames, vio, runs=300):
    sel = syms['fn_0800B974']
    step = syms.get('hy_counter_restart_step')
    rng = random.Random(0x121)
    hooks = {syms['fn_0800ECF6']: hook_ret}
    bad = 0
    for i in range(runs):
        mode = rng.randrange(25)
        r = rng.randrange(8)
        uc, run = world.build(hooks, wire=True)
        uc.mem_write(MODE, bytes([mode]))
        uc.mem_write(RANGE, bytes([r]))
        for a in FLAGS:
            uc.mem_write(a, bytes([rng.randrange(256)]))
        uc.mem_write(PRESET_WORD, bytes([rng.randrange(256) for _ in range(4)]))
        try:
            world.call(uc, sel, (mode, r), count=6_000_000)
            if step:
                world.finish_restart(uc, step, run, 'random run %d (mode %d range %d)' % (i, mode, r), count=6_000_000)
        except UcError as e:
            vio.append('HY-RANDOM run %d (mode %d range %d): emulation error %s' % (i, mode, r, e))
            continue
        for f in run['wire']:
            if f not in ref_frames and not (f[0] in (0x20, 0x29) and len(f[1]) == 1):
                bad += 1
                vio.append('HY-RANDOM run %d (mode %d range %d): bus frame (0x%02X, %s) is not a v2.05 frame'
                           % (i, mode, r, f[0], f[1].hex()))
    return runs


def static_scan(img, vio):
    """Check 7: stores to GPIOF BSRR / ODR with an effective address that is known."""
    insns, bad = ci.decode_ranges(img)
    chk = ci.Checker(img)
    found = {'bsrr': 0}

    def alias_target(ea):
        if 0x42000000 <= ea < 0x42200000:
            return 0x40000000 + ((ea - 0x42000000) >> 5), ((ea - 0x42000000) >> 2) & 7
        return None, None

    def observe(ins, role, is_store, ea, span, value, op, multi):
        if not is_store:
            return
        func = img.where(ins.addr).split('+')[0]
        obj = img.obj_at(ins.addr) or ''
        parts = obj.replace('\\', '/').split('/')
        in_bus = func in HY_BUS_FUNCS
        in_idle = 'hy' in parts or 'brd' in parts or parts[-2:] == ['sys', 'fault.o']
        words = range(ea & ~3, ((ea + span - 1) & ~3) + 1, 4)
        for w in words:
            tgt, bit = alias_target(w)
            if tgt is not None and GPIOF <= tgt < GPIOF + 0x400:
                if not in_bus:
                    vio.append('HY-BUS %s (0x%08X): store through the bit-band alias of a GPIOF register (0x%08X)' % (func, ins.addr, tgt))
        if not (ea <= BSRRL + 3 and ea + span > ODR):
            return
        found['bsrr'] += 1
        if in_bus:
            return
        if ea <= ODR + 3 and ea + span > ODR:
            vio.append('HY-BUS %s (0x%08X in %s): store to GPIOF ODR outside the HY bus routines (v2.05 never writes ODR)' % (func, ins.addr, obj))
            return
        # BSRR store: which bits does it touch?
        mask_set = mask_clr = None
        if value is not None and value[0] == 'c':
            v = value[1]
            if ea == BSRRL and span == 2:
                mask_set, mask_clr = v & 0xFFFF, 0
            elif ea == BSRRH and span == 2:
                mask_set, mask_clr = 0, v & 0xFFFF
            elif ea == BSRRL and span == 4:
                mask_set, mask_clr = v & 0xFFFF, v >> 16
            elif ea == BSRRL and span == 1:
                mask_set, mask_clr = v & 0xFF, 0
            elif ea == BSRRH and span == 1:
                mask_set, mask_clr = 0, v & 0xFF
        if mask_set is None:
            if not in_idle:
                vio.append('HY-BUS %s (0x%08X in %s): store to GPIOF BSRR with a value that is not known and not in an idle-level object'
                           % (func, ins.addr, obj))
            else:
                found.setdefault('unknown_idle', []).append((func, ins.addr))
            return
        if mask_set & 1:
            vio.append('HY-BUS %s (0x%08X in %s): sets GPIOF pin 0 (HY_CK) high outside the HY bus routines' % (func, ins.addr, obj))
        if (((mask_set | mask_clr) & 6) or (mask_clr & 1)) and not in_idle:
            vio.append('HY-BUS %s (0x%08X in %s): changes GPIOF pins 0..2 (HY bus) outside hy/, brd/ and sys/fault.o' % (func, ins.addr, obj))
    chk.observers.append(observe)
    chk.run(insns)
    return found, chk


# ---------------------------------------------------------------------------------------------------- main
def main(argv):
    ap = argparse.ArgumentParser(description='HY3131 write whitelist check (DESIGN.md 4.1, 9.3)')
    ap.add_argument('elf', nargs='?')
    ap.add_argument('--reference', action='store_true', help='only run the v2.05 sweep and compare its numbers with DESIGN 4.1 (no ELF)')
    ap.add_argument('--map')
    ap.add_argument('--v205', default=v205.IMAGE)
    a = ap.parse_args(argv)
    vio = []
    try:
        ref_img = open(a.v205, 'rb').read()
        from_ram = bytearray(0x23E)
        ram = extract_ram()
        from_ram[0:len(ram)] = ram
        range_count = ram[0:25]
        if a.reference:
            world_ref = World([(APP_BASE, ref_img)], bytes(from_ram), {}, False)
            ref = sweep(world_ref, V205_SELECT, V205_WRITE, V205_READ, V205_DELAY, None, range_count, 'v2.05')
            rows, pairs, frames, shapes = pairs_of(ref)
            print('check_hy (reference): v2.05 sweep: %d runs, %d distinct rows, %d distinct (row, INTE) pairs, shapes %s'
                  % (len(ref), len(rows), len(pairs), sorted((hex(r), n) for r, n in shapes)))
            if len(rows) != EXPECT_ROWS or len(pairs) != EXPECT_PAIRS:
                vio.append('HY-REF the v2.05 sweep gives %d rows / %d pairs, DESIGN 4.1 states %d / %d' % (len(rows), len(pairs), EXPECT_ROWS, EXPECT_PAIRS))
            for v in vio:
                print('VIOLATION ' + v)
            print('check_hy (reference): %s' % ('PASS' if not vio else 'FAIL'))
            return 0 if not vio else 1
        if not a.elf:
            ap.error('ELF is required unless --reference is given')
        mp = a.map or re.sub(r'\.elf$', '.map', a.elf)
        img, elf, syms, port_ram = load_port(a.elf, mp)
        print('check_hy: %s against %s' % (a.elf, a.v205))
        # 1. tables
        nt = check_tables(img, elf, vio, ref_img)
        print('tables: %d of %d row tables equal the v2.05 image' % (nt, len(TABLE_ADDRS)))
        # 2. reference sweep on v2.05
        world_ref = World([(APP_BASE, ref_img)], bytes(from_ram), {}, False)
        ref = sweep(world_ref, V205_SELECT, V205_WRITE, V205_READ, V205_DELAY, None, range_count, 'v2.05')
        rows, pairs, frames, shapes = pairs_of(ref)
        print('v2.05 sweep: %d runs, %d distinct rows, %d distinct (row, INTE) pairs, %d frame shapes %s'
              % (len(ref), len(rows), len(pairs), len(shapes), sorted((hex(r), n) for r, n in shapes)))
        if len(rows) != EXPECT_ROWS or len(pairs) != EXPECT_PAIRS:
            vio.append('HY-REF the v2.05 sweep gives %d rows / %d pairs, DESIGN 4.1 states %d / %d' % (len(rows), len(pairs), EXPECT_ROWS, EXPECT_PAIRS))
        extra = shapes - set(SHAPES)
        for s in sorted(extra):
            vio.append('HY-REF the v2.05 sweep sends the frame shape (0x%02X, %d), not one of the six of DESIGN 4.1' % s)
        print('v2.05 shapes outside the selector sweep: (0x29, 1) peak restart 0x0800A872 / 0x0800A88C and (0x1E, 1) IRQ '
              'acknowledge 0x0800616C (values: INTF_ACK, OF-53); with them the six shapes of DESIGN 4.1 are complete')
        # 3. port sweep
        sel, wr, rd, dl = need(syms, 'fn_0800B974', 'hy3131_write_regs', 'hy3131_read_regs_to_rxbuf', 'fn_0800ECF6')
        step = syms.get('hy_counter_restart_step')
        world_port = World(img.loads, bytes(port_ram), syms, True)
        port = sweep(world_port, sel, wr, rd, dl, step, range_count, 'port')
        prows, ppairs, pframes, pshapes = pairs_of(port)
        print('port sweep: %d runs, %d distinct rows, %d distinct (row, INTE) pairs, shapes %s'
              % (len(port), len(prows), len(ppairs), sorted((hex(r), n) for r, n in pshapes)))
        if ppairs != pairs:
            vio.append('HY-PAIRS port pairs differ from v2.05: %d only in the port, %d only in v2.05'
                       % (len(ppairs - pairs), len(pairs - ppairs)))
        if prows != rows:
            vio.append('HY-ROWS port rows differ from v2.05 rows: %d only in the port, %d only in v2.05'
                       % (len(prows - rows), len(rows - prows)))
        if pshapes - set(SHAPES):
            vio.append('HY-SHAPE the port requests shapes outside the six: %s' % sorted(pshapes - set(SHAPES)))
        for f in sorted(pframes - frames):
            vio.append('HY-FRAME the port requests the frame (0x%02X, %s) which the v2.05 sweep never sends' % (f[0], f[1].hex()))
        same, total = check_sequences(ref, port, vio)
        print('sequences: %d of %d (mode, range, flags) runs give the identical frame sequence' % (same, total))
        # 3b. peak restart
        npk = check_peak(world_port, syms, rows, vio)
        print('peak restart: %d rows with ENPKH set checked' % npk)
        # 4. wire level
        nw = check_wire(world_port, syms, ref, vio)
        print('wire level: %d distinct sequences decoded from the GPIOF BSRR writes' % nw)
        # 5. guard probe
        ref_frames = set(frames) | INTF_ACK                # + the IRQ acknowledge 0x0800616C (v2.05 0x00; port OF-53)
        npb = guard_probe(world_port, syms, ref_frames, rows, vio)
        print('guard probe: %d offered frames, each accepted or refused as required' % npb)
        # 6. random RAM
        nr = random_ram(world_port, syms, ref_frames, vio)
        print('random RAM: %d runs, every bus frame is a v2.05 frame' % nr)
        # 7. instruction level
        found, chk = static_scan(img, vio)
        print('instruction level: %d stores to GPIOF ODR / BSRR with a known address examined' % found['bsrr'])
        for func, addr in found.get('unknown_idle', []):
            print('note: %s (0x%08X) stores an unknown value to GPIOF BSRR in an idle-level object' % (func, addr))
    except (CheckError, ci.ToolError) as e:
        print('check_hy: ERROR %s' % e)
        return 2
    for v in vio:
        print('VIOLATION ' + v)
    print('check_hy: %s (%d violations)' % ('PASS' if not vio else 'FAIL', len(vio)))
    return 0 if not vio else 1


def extract_ram():
    """The 574-byte RAM image of the original after data_init (analysis/decompile/ram_init.txt), via the W7 reader."""
    et = _load('extract_tables')
    return et.ram_init_bytes()


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
