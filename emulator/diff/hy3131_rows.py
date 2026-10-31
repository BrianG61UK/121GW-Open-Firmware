"""Exhaustive set of the HY3131 SPI writes of the original v2.05 configuration code, by execution of that code under
Unicorn (the method of analysis/hy3131_model.md section 3 "Method note"), for the hardware-safety whitelist.

Every SPI write of v2.05 goes through spi_write 0x0800C03C (buffer, first register, byte count).  Its call sites (all
eight `bl 0x0800C03C` of the image; no literal pointer to 0x0800C03C/0x0800C03D exists in the image):
    0x0800BE94  hy3131_load_config_regs 0x0800B994: the 20-byte row to 0x20..0x33
    0x0800BF74  hy3131_set_irq_enable 0x0800BEAC: {INTF = 0, INTE} to 0x1E
    0x0800BFC6  hy3131_counter_restart 0x0800BF8C: R20 with ENCTR (and ENPCMPO outside modes 6..8) cleared
    0x0800BFF0  same: counter preset CTA<7:0> = 0, CTA<15:8>, CTA<23:16> = bytes 0 and 1 of the word 0x2000001C
    0x0800C036  same: R20 = copy 0x2000807D | 0x02
    0x0800616C  IRQ service: 0x1E = 0 (0x0800615C stores 0 to the buffer 0x20007DC4 first)
    0x0800A872  peak routine: R29 = copy 0x2000807E & 0xFB
    0x0800A88C  same: R29 = copy 0x2000807E
The first five run inside 0x0800B974(mode, range) (hy3131_model.md section 3: 0x0800B982..0x0800B98E), which is what
this module executes, with spi_write, spi_read 0x0800C0C0 and delay 0x0800ECF6 replaced by a return, for
    every mode 0..24 and every range below range_count[mode] (RAM 0x20000000, analysis/decompile/ram_init.txt;
    analysis/verified_names.txt range_count), and every combination of the RAM bytes the code reads, discovered by
    tracing its memory reads and swept over their value sets:
        0x20008098 LowZ AC variant 0/1, 0x200080B7 peak_hold 0/1, 0x200080B9 filter_1khz 0/1, 0x200080BA AC+DC 0/1,
        0x200080BD AC+DC phase 0/1, 0x20007FE0 0/1, 0x20007FDF 0/1, 0x200080C4 va_channel 0/1,
        0x200080C6 voltage sub-range 0/1, 0x200080C7 current sub-range 0/1, and 2 in modes 15 and 24
        (hy3131_model.md section 3 flag legend; hy3131_modes_misc.md section 0 and 3.1; hy3131_modes_ac_current.md
        "Sub-ranges": c6 only 0 or 1, c7 = 2 only for modes 15 and 24, and meter_range = (0,0) -> 0, (1,0) -> 1, (0,!=0) -> 2, (1,!=0) -> 3 in the
        VA modes 13, 14, 15, 22, 23, 24, so there the range follows c6 / c7);
        the word 0x2000001C 0x0000E000 or 0x00008000 (hy3131_model.md section 3 "Counter preset", FUN_0800ED64);
    meter_mode 0x2000803C and meter_range 0x2000803D hold the arguments (the counter restart reads meter_mode).
A read of any other RAM byte that was not written before in the same run stops the generator with an error: the sweep
would not be exhaustive.  The peak routine's two writes (0x0800A85E..0x0800A88C) and the IRQ write (0x0800616C) are
added from their code: the copy 0x2000807E is the R29 value the chip returns (hy3131_model.md section 2: "copy rx[0x29]
-> 0x2000807E at each IRQ (0x08006196)"), i.e. the R29 of the row in force, and the routine runs only with ENPKH (R29
bit 2) set and AC+DC off (hy3131_model.md section 2.1, 0x080061C2).  At that time the counter restart has already
written R20 = row[0] | 0x02.

The register state used by emu/safety.py is the 20 configuration registers after each write frame; the state before
the first row of a power-up is "not written" ('--' everywhere), which frames to 0x1B..0x1E leave unchanged.
"""
import itertools
import os
import struct
import sys

from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UC_HOOK_CODE
from unicorn.arm_const import UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_SP

APP_BASE = 0x08006000
APPLY = 0x0800B974
SPI_WRITE, SPI_READ, DELAY = 0x0800C03C, 0x0800C0C0, 0x0800ECF6
STOP = 0x08005FF0                    # return address used to end a run (bootloader area, not part of the image run)
SP0 = 0x20001240                     # initial stack pointer of the image (ram_init.txt header)
STACK_LO = SP0 - 0x500               # stack window of the run (reads there are stack slots, not RAM flags)
RANGE_COUNT = bytes.fromhex('01 04 04 02 02 01 05 03 01 07 01 01 06 04 04 04 02 02 02 02 03 03 04 04 04')
MODE, RANGE = 0x2000803C, 0x2000803D
PRESET_WORD = 0x2000001C
FLAGS = {0x20008098: (0, 1), 0x200080B7: (0, 1), 0x200080B9: (0, 1), 0x200080BA: (0, 1), 0x200080BD: (0, 1),
         0x20007FE0: (0, 1), 0x20007FDF: (0, 1), 0x200080C4: (0, 1), 0x200080C6: (0, 1), 0x200080C7: (0, 1, 2)}
VA_MODES = (13, 14, 15, 22, 23, 24)
# c7 = 2 only in modes 15 and 24 (hy3131_modes_ac_current.md "Sub-ranges": the RANGE key path FUN_0801485A sets c7 = 1
# and changes it to 2 for modes 15 and 24; the autorange path 0x0800A358 sets c7 = 1)
C7_TWO_MODES = (15, 24)
CFG_LO, CFG_HI = 0x20, 0x33
# GPIO BSRR stores of v2.05 that change the supply / enable outputs (scan of the image, see power_writers())
POWER_WRITERS = ((0x0800FD50, 'PF6 on'), (0x0800FD76, 'PF6 off'), (0x0800FE06, 'PD1 on'), (0x0800FE64, 'PE12 on'),
                 (0x0800FE70, 'PE12 off'), (0x0801C094, 'PD1 on'), (0x0801C0CE, 'PE9 on'), (0x0801C0EA, 'PE12 off'),
                 (0x0801C240, 'PF15 off'), (0x0801C2AA, 'PF6 off'), (0x0801C39C, 'PF15 on'), (0x0801C5C6, 'PE12 off'),
                 (0x0801C606, 'PF6 off'), (0x0801C618, 'PE9 off'), (0x0801C95C, 'PF15 off'))


class SweepError(RuntimeError):
    pass


class Runner:
    def __init__(self, image):
        self.image = open(image, 'rb').read()

    def run(self, mode, rng, ram):
        """Execute 0x0800B974(mode, rng) with the given RAM bytes / words.  Returns (frames, reads) where frames is a list
        of (first register, bytes) and reads the set of RAM addresses read before being written.
        SRAM is an mmio region backed by a bytearray, so its reads and writes are seen in the callbacks: no
        UC_HOOK_MEM_READ is installed (Unicorn 2.1.4 mis-executes the instruction after an IT block that ends in a
        skipped load while such a hook is installed; emulator/diff/routine.py docstring, firmware/requests/W5_to_W10.md
        item 2)."""
        uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
        uc.mem_map(0x08000000, 0x60000)
        uc.mem_write(APP_BASE, self.image)
        sram = bytearray(0xC000)
        sram[0:len(RANGE_COUNT)] = RANGE_COUNT
        for addr, (size, val) in ram.items():
            o = addr - 0x20000000
            sram[o:o + size] = val.to_bytes(size, 'little')
        frames, reads, written = [], set(), set()

        def mread(u, off, size, _):
            a = 0x20000000 + off
            if not (STACK_LO <= a < SP0):
                reads.update(x for x in range(a, a + size) if x not in written)
            return int.from_bytes(sram[off:off + size], 'little')

        def mwrite(u, off, size, value, _):
            sram[off:off + size] = (value & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
            written.update(range(0x20000000 + off, 0x20000000 + off + size))

        def code(u, addr, size, _):
            if addr == SPI_WRITE:
                buf, reg, n = (u.reg_read(r) for r in (UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2))
                frames.append((reg, bytes(sram[buf - 0x20000000:buf - 0x20000000 + n])))
            u.reg_write(UC_ARM_REG_PC, u.reg_read(UC_ARM_REG_LR))
        uc.mmio_map(0x20000000, 0xC000, mread, None, mwrite, None)
        for addr in (SPI_WRITE, SPI_READ, DELAY):
            uc.hook_add(UC_HOOK_CODE, code, begin=addr, end=addr)
        uc.reg_write(UC_ARM_REG_SP, SP0)
        uc.reg_write(UC_ARM_REG_LR, STOP | 1)
        uc.reg_write(UC_ARM_REG_R0, mode)
        uc.reg_write(UC_ARM_REG_R1, rng)
        uc.emu_start(APPLY | 1, STOP, count=200000)
        if uc.reg_read(UC_ARM_REG_PC) != STOP:
            raise SweepError(f'mode {mode} range {rng}: did not return (pc 0x{uc.reg_read(UC_ARM_REG_PC):08X})')
        return frames, reads


def va_range(c6, c7):
    """meter_range of a VA mode from the sub-ranges (FUN_080148F6, hy3131_modes_ac_current.md "Sub-ranges")."""
    return (0 if c6 == 0 else 1) if c7 == 0 else (2 if c6 == 0 else 3)


def sweep(image):
    """All (mode, range, ram) runs.  Returns a list of (mode, range, flags dict, frames)."""
    r = Runner(image)
    known = set(FLAGS) | {MODE, RANGE} | set(range(PRESET_WORD, PRESET_WORD + 4)) | set(range(0x20000000, 0x20000019))
    out = []
    for mode in range(25):
        used = {0x200080C6, 0x200080C7} if mode in VA_MODES else set()   # the range follows c6 / c7
        while True:                                      # widen the flag set until the reads are stable
            flags = sorted(used)
            new = set()
            domains = [(0, 1) if f == 0x200080C7 and mode not in C7_TWO_MODES else FLAGS[f] for f in flags]
            for combo in itertools.product(*domains):
                fl = dict(zip(flags, combo))
                if mode in VA_MODES:
                    ranges = [va_range(fl.get(0x200080C6, 0), fl.get(0x200080C7, 0))]
                else:
                    ranges = range(RANGE_COUNT[mode])
                for rng in ranges:
                    for word in (0xE000, 0x8000):
                        ram = {MODE: (1, mode), RANGE: (1, rng), PRESET_WORD: (4, word)}
                        ram.update({f: (1, v) for f, v in fl.items()})
                        frames, reads = r.run(mode, rng, ram)
                        unknown = reads - known
                        if unknown:
                            raise SweepError(f'mode {mode} range {rng}: reads RAM '
                                             + ', '.join(f'0x{a:08X}' for a in sorted(unknown))
                                             + ' which the sweep does not cover')
                        new |= reads & set(FLAGS)
                        out.append((mode, rng, dict(fl, preset=word), frames))
            if new <= used:
                break
            used |= new
            out = [o for o in out if o[0] != mode]       # redo this mode with the wider flag set
    return out


def write_sets(image):
    """(pairs, frame shapes, states) of every run, the IRQ write and the peak routine writes (module docstring)."""
    pairs, shapes, states = set(), set(), {tuple([None] * (CFG_HI - CFG_LO + 1))}
    for mode, rng, fl, frames in sweep(image):
        state = [None] * (CFG_HI - CFG_LO + 1)
        for reg, data in frames:
            shapes.add((reg, len(data)))
            for i, v in enumerate(data):
                pairs.add((reg + i, v))
                if CFG_LO <= reg + i <= CFG_HI:
                    state[reg + i - CFG_LO] = v
            states.add(tuple(state))
        r29 = state[0x29 - CFG_LO]
        if r29 is not None and r29 & 0x04 and mode in (2, 4) and fl.get(0x200080BA, 0) == 0:
            peak = list(state)
            for v in (r29 & 0xFB, r29):                  # 0x0800A872, 0x0800A88C
                pairs.add((0x29, v))
                shapes.add((0x29, 1))
                peak[0x29 - CFG_LO] = v
                states.add(tuple(peak))
    pairs.add((0x1E, 0x00))                              # 0x0800616C
    shapes.add((0x1E, 1))
    return pairs, shapes, states


def power_writers(image):
    """GPIO BSRR stores in the image whose mask touches PE9, PE12, PD1, PF15 or PF6 (linear Thumb sweep of the code,
    register values tracked through literal loads and immediate moves).  Used to list POWER_WRITERS."""
    from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS
    d = open(image, 'rb').read()
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
    md.detail = True
    regs_bsrr = {0x40021018: ('E', 'on'), 0x4002101A: ('E', 'off'), 0x40020C18: ('D', 'on'), 0x40020C1A: ('D', 'off'),
                 0x40021818: ('F', 'on'), 0x4002181A: ('F', 'off')}
    pins = {'E': {9: 'PE9', 12: 'PE12'}, 'D': {1: 'PD1'}, 'F': {15: 'PF15', 6: 'PF6'}}
    code_end = 0x08025F00                                # literal / table area of the image starts after this
    out, regs, off = [], {}, 0
    while off < code_end - APP_BASE:
        last = off
        for i in md.disasm(d[off:off + 0x4000], APP_BASE + off):
            off = i.address + i.size - APP_BASE
            ops = i.op_str
            if i.mnemonic.startswith('ldr') and '[pc' in ops:
                a = ((i.address + 4) & ~3) + i.operands[1].mem.disp
                if APP_BASE <= a < APP_BASE + len(d) - 3:
                    regs[ops.split(',')[0]] = ('lit', struct.unpack_from('<I', d, a - APP_BASE)[0])
            elif i.mnemonic in ('movs', 'mov.w', 'mov', 'movw') and '#' in ops:
                regs[ops.split(',')[0]] = ('imm', i.operands[1].imm)
            elif i.mnemonic.startswith('str'):
                rs, rb = ops.split(',')[0], ops.split('[')[1].split(']')[0].split(',')[0]
                if (regs.get(rb, ('',))[0] == 'lit' and regs[rb][1] in regs_bsrr and regs.get(rs, ('',))[0] == 'imm'
                        and regs[rb][1] - 0x40020000 < 0x2000):
                    port, kind = regs_bsrr[regs[rb][1]]
                    hit = [pins[port][p] for p in pins[port] if regs[rs][1] >> p & 1]
                    if hit:
                        out.append((i.address, ' '.join(hit) + ' ' + kind))
        if off == last:
            off += 2
    return out


def main():
    image = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..', '..', 'inputs',
                                                                'binaries', 'EEVBlog2_05.bin')
    pairs, shapes, states = write_sets(image)
    print(f'{len(pairs)} pairs, {len(shapes)} frame shapes, {len(states)} states')
    curated = dict(POWER_WRITERS)
    for a, k in power_writers(image):
        note = '' if a in curated else '   (not in POWER_WRITERS: the address is a literal-pool word in the listing)'
        print(f'power writer 0x{a:08X} {k}{note}')


if __name__ == '__main__':
    main()
