"""Starter tests in the emulator (bootloader/DESIGN.md 6.2): every decision of the starter, and power cuts at every
stage of an install and of a rollback.

The machine: core + SCS + FLASH model (brick guard off: the starter writes the bootloader area), the reset clock
(MSI 2.097 MHz, the starter does not change it), option bytes as on the owner's meter (RDP level 0, no write
protection).  The bootloader images are small test programs linked at 0x08000400: they store their identity at
0x20003000 and stop, so a test sees which bootloader the starter started.  "Power cut": the operation the FLASH model
has in progress ends in one of three ways (not done, done, target filled with random bytes; the device's behaviour
is not specified), RAM is cleared, the FLASH interface and the core are reset.

Usage: python3 -I tests/test_starter.py   (from bootloader/, after make)
"""
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, 'tools'))
sys.path.insert(0, os.path.join(ROOT, '..', 'emulator'))

import blimage as B                                         # noqa: E402
from emu.core import Machine, FLASH_BASE, INFO_BASE, SRAM_BASE, SRAM_SIZE   # noqa: E402
from emu.scs import SCS                                     # noqa: E402
from emu.periph.flash import FLASH                          # noqa: E402

MSI_HZ = 2_097_000
ID_ADDR = 0x20003000
FLASH_R = 0x40023C00
OPTION_BYTES = bytes.fromhex('aa0055fff0000fff' + '0000ffff' * 6)   # owner's meter: RDP 0xAA, USER 0xF0, no WRP
STARTER = open(os.path.join(ROOT, 'build', 'starter.bin'), 'rb').read()
BOOT_BUDGET = 8_000_000                                     # cycles: about 3.8 s at MSI, far above one install


def test_bootloader(ident, length):
    """A bootloader image of `length` bytes that stores `ident` at ID_ADDR and stops."""
    code = struct.pack('<II', 0x20002000, B.BL_BASE + 8 + 1)
    code += bytes.fromhex('014802490160fee7')     # ldr r0,[pc,#4]; ldr r1,[pc,#8]; str r1,[r0]; b .
    code += struct.pack('<II', ID_ADDR, ident)
    rnd = random.Random(ident)
    return code + bytes(rnd.randrange(256) for _ in range(length - len(code)))


class Meter:
    def __init__(self):
        m = self.m = Machine(sysclk_hz=MSI_HZ)
        SCS(m)
        self.flash = FLASH(allow_protected=True)
        m.add_periph(FLASH_R, 0x400, self.flash)
        m.load(INFO_BASE, OPTION_BYTES)
        m.load(FLASH_BASE, STARTER)
        self.ops = 0
        self.oplog = []                                     # (kind, address) of every flash operation of a boot
        self.target = None
        f = self.flash
        pe, pw = f._page_erase, f._program_words

        def page_erase(addr, value):
            self.target = (addr, 256)
            self.ops += 1
            self.oplog.append(('erase', addr))
            pe(addr, value)

        def program_words(base, words, what):
            self.target = (base, 4 * len(words))
            self.ops += 1
            self.oplog.append(('half-page' if len(words) > 1 else 'word', base))
            pw(base, words, what)
        f._page_erase, f._program_words = page_erase, program_words
        self.power_on()

    def power_on(self):
        m = self.m
        m.uc.mem_write(SRAM_BASE, bytes(SRAM_SIZE))
        self.flash._op = None
        self.flash._bank_guard_off()
        self.flash.reset(power_on=True)
        m.nvic.vtor = 0
        m._stop_reason = None
        m.reset_request = None
        m.reset()

    def put(self, addr, data):
        self.m.uc.mem_write(addr, data)

    def get(self, addr, n):
        return bytes(self.m.uc.mem_read(addr, n))

    def boot(self, budget=BOOT_BUDGET):
        """Run from reset until a bootloader stored its identity (returned) or the budget ends (None)."""
        self.ops = 0
        self.oplog = []
        m = self.m
        end = m.cycles + budget
        while m.cycles < end:
            r = m.run(min(200_000, end - m.cycles))
            if r is not None:
                raise AssertionError('machine stopped: %s' % r)
            ident = struct.unpack('<I', self.get(ID_ADDR, 4))[0]
            if ident:
                return ident
        return None

    def cut_at(self, k, variant, rnd):
        """Run from reset until flash operation number k (1-based) is in progress, then cut the power with that
        operation ending as `variant`."""
        m = self.m
        self.ops = 0
        while not (self.ops >= k and self.flash._op is not None):
            r = m.run(1000)
            if r is not None:
                raise AssertionError('machine stopped: %s' % r)
            if self.ops > k:
                raise AssertionError('operation %d finished before it was seen in progress' % k)
        op = self.flash._op
        if op is not None and self.target is not None:
            if variant == 'done' and op['commit'] is not None:
                op['commit']()
            elif variant == 'random':
                a, n = self.target
                self.put(a, bytes(rnd.randrange(256) for _ in range(n)))
        self.power_on()

    def control(self):
        return B.parse_control(self.get(B.CTL_BASE, B.CTL_END - B.CTL_BASE))

    def write_record(self, cmd, arg):
        last, free = self.control()
        self.put(B.CTL_BASE + free, B.record(cmd, arg))

    def state_ok(self, ident):
        """After a start: VTOR at the bootloader, PECR locked, no bus error."""
        assert self.m.nvic.vtor == B.BL_BASE, hex(self.m.nvic.vtor)
        assert self.flash.pecr & 1, 'FLASH_PECR left unlocked'
        assert self.flash.bus_errors == 0, 'bus error'
        assert B.parse_header(self.get(B.MARK, 20)) is not None, 'mark invalid after start'


IMG_A = test_bootloader(0xA1, 9000)
IMG_B = test_bootloader(0xB2, 12345)


def fresh(mark=None, a=True, b=True):
    """A meter with the starter, slot A / B filled, and the bootloader of `mark` ('A', 'B' or None) installed."""
    t = Meter()
    if a:
        t.put(B.SLOT_A, B.slot(IMG_A, 1))
    if b:
        t.put(B.SLOT_B, B.slot(IMG_B, 2))
    if mark:
        img, ver = (IMG_A, 1) if mark == 'A' else (IMG_B, 2)
        t.put(B.BL_BASE, img)
        t.put(B.MARK, B.header(img, ver))
    t.power_on()
    return t


def check(name, cond, detail=''):
    if not cond:
        raise AssertionError('%s: %s' % (name, detail))
    print('ok   %s' % name)


def main():
    rnd = random.Random(1)

    t = fresh('A')
    check('S1 valid mark, no request: starts it without writing', t.boot() == 0xA1 and t.ops == 0)
    t.state_ok(0xA1)

    t = fresh('A')
    t.write_record(B.CMD_INSTALL, B.SLOT_B)
    t.power_on()
    t0 = t.m.cycles
    check('S2 install request: installs slot B and starts it', t.boot() == 0xB2)
    install_cycles = t.m.cycles - t0
    t.state_ok(0xB2)
    check('S2 record TRIAL with the previous slot A', t.control()[0] == (B.CMD_TRIAL, B.SLOT_A), t.control())
    check('S2 bootloader area equals image B', t.get(B.BL_BASE, len(IMG_B)) == IMG_B)
    print('     install time %.3f s at MSI (%d flash operations)' % (install_cycles / MSI_HZ, t.ops))

    t.power_on()
    check('S3 unconfirmed trial: previous bootloader A put back', t.boot() == 0xA1)
    t.state_ok(0xA1)
    check('S3 record OK', t.control()[0] == (B.CMD_OK, B.SLOT_A), t.control())

    t = fresh('A')
    t.write_record(B.CMD_INSTALL, B.SLOT_B)
    t.power_on()
    t.boot()
    t.write_record(B.CMD_OK, 0)                     # what the new bootloader does once it runs
    t.power_on()
    check('S4 confirmed trial: B stays, nothing written', t.boot() == 0xB2 and t.ops == 0)

    t = fresh('A')
    t.put(B.SLOT_B + B.SLOT_IMG + 100, b'\x5a')     # slot B image damaged
    t.write_record(B.CMD_INSTALL, B.SLOT_B)
    t.power_on()
    check('S5 install request for a damaged slot: dropped, A kept', t.boot() == 0xA1)
    check('S5 record OK', t.control()[0][0] == B.CMD_OK, t.control())

    t = fresh(None)
    check('S6 no bootloader: slot A installed', t.boot() == 0xA1)
    t.state_ok(0xA1)

    t = fresh(None)
    t.put(B.SLOT_A + 4, b'\x01')                    # slot A header damaged
    check('S7 no bootloader, slot A damaged: slot B installed', t.boot() == 0xB2)

    t = fresh(None, a=False, b=False)
    check('S8 nothing valid: no start', t.boot(2_000_000) is None)

    t = fresh('A')
    for i in range((B.CTL_END - B.CTL_BASE) // B.CTL_REC - 1):
        t.put(B.CTL_BASE + i * B.CTL_REC, B.record(B.CMD_OK, 0))
    t.put(B.CTL_END - B.CTL_REC, B.record(B.CMD_INSTALL, B.SLOT_B))
    t.power_on()
    check('S9 control area full: request ignored, A started', t.boot() == 0xA1 and t.ops == 0)

    # power cuts: one during each kind of step of an install and of the rollback after it (first, middle and last
    # erase, first, middle and last half-page, first and last word of the mark and of the control record); the
    # interrupted operation ends not done, done or with random contents, in turn
    variants = ('none', 'done', 'random')
    for label, setup, want in (
            ('S10 power cut during install', lambda t: t.write_record(B.CMD_INSTALL, B.SLOT_B), 0xB2),
            ('S11 power cut during rollback', lambda t: (t.write_record(B.CMD_INSTALL, B.SLOT_B), t.power_on(),
                                                          t.boot()), 0xA1)):
        t = fresh('A')
        setup(t)
        t.power_on()
        t.boot()
        log = t.oplog
        pick = []
        for kind in ('erase', 'half-page', 'word'):
            idx = [i for i, (k, a) in enumerate(log) if k == kind]
            if kind == 'word':
                words = [i for i in idx if log[i][1] < B.BL_END]
                recs = [i for i in idx if log[i][1] >= B.CTL_BASE]
                pick += [words[0], words[-1], recs[0], recs[-1]]
            else:
                pick += [idx[0], idx[len(idx) // 2], idx[-1]]
        for n, i in enumerate(sorted(set(pick))):
            variant = variants[n % 3]
            t = fresh('A')
            setup(t)
            t.power_on()
            t.cut_at(i + 1, variant, rnd)
            got = t.boot()
            if got != want:
                raise AssertionError('%s: cut during %s at 0x%08X (%s): started %r'
                                     % (label, log[i][0], log[i][1], variant, got))
            t.state_ok(got)
        check('%s: %d cuts, always ends in the expected bootloader' % (label, len(set(pick))), True)

    t = fresh('A')
    t.write_record(B.CMD_INSTALL, B.SLOT_B)
    t.power_on()
    t.boot()
    check('S12 no bus error in any run (same-bank read during a half-page write)', t.flash.bus_errors == 0)
    print('all starter tests passed')


if __name__ == '__main__':
    main()
