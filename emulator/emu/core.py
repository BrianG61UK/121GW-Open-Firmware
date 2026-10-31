"""121GW emulator core: Cortex-M3 CPU (Unicorn), memory map, exception engine, virtual clock.

Execution model
- The CPU runs in slices.  Between slices the run loop delivers pending exceptions and advances
  peripheral events on the virtual clock.
- Instruction counting: a block hook adds the number of instructions in each executed basic block
  (counted once per block start with Capstone), so the virtual clock is exact to the block.
- Exception entry is done here (ARMv7-M: 8-word frame, EXC_RETURN in LR).  Exception return is the
  Unicorn M-class "exception exit" interrupt (intno 8): the frame is popped here and execution resumes.
- WFI/WFE: a code hook on the instruction advances virtual time to the next event and skips it
  (Unicorn rejects WFE).
"""
import struct
from unicorn import Uc, UcError, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UC_HOOK_BLOCK, UC_HOOK_INTR, UC_HOOK_CODE, UC_HOOK_MEM_INVALID, UC_PROT_READ, UC_PROT_EXEC, UC_PROT_ALL
from unicorn.arm_const import *
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS

FLASH_BASE, FLASH_SIZE = 0x08000000, 0x60000          # 384 KB (STM32L152ZD)
EEPROM_BASE, EEPROM_SIZE = 0x08080000, 0x3000         # 12 KB data EEPROM
INFO_BASE, INFO_SIZE = 0x1FF80000, 0x1000             # option bytes / factory area (page)
SYSMEM_BASE, SYSMEM_SIZE = 0x1FF00000, 0x80000        # system memory (read as 0 unless modelled)
SRAM_BASE, SRAM_SIZE = 0x20000000, 0xC000             # 48 KB
PERIPH_BASE, PERIPH_SIZE = 0x40000000, 0x100000
BB_PERIPH, BB_SRAM = 0x42000000, 0x22000000           # bit-band aliases (32 MB each)
SCS_BASE, SCS_SIZE = 0xE0000000, 0x100000

FRAME_REGS = [UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
              UC_ARM_REG_R12, UC_ARM_REG_LR, UC_ARM_REG_PC, UC_ARM_REG_XPSR]


class Machine:
    def __init__(self, sysclk_hz=16_000_000):
        self.uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
        self.cs = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
        self.cycles = 0                       # virtual time in core clock cycles (1 instruction = 1 cycle)
        self.sysclk_hz = sysclk_hz            # updated by the RCC model
        self.periphs = []                     # (base, end, model)
        self.events = []                      # (due_cycle, seq, callback)
        self._seq = 0
        self.pending = set()                  # pending exception numbers (16+IRQ for interrupts)
        self.active = []                      # stack of active exception numbers
        self.unmodelled = {}                  # (addr, rw) -> first pc, count
        self.log = []                         # (cycle, text)
        self._blk = {}
        self._resume = None
        self._stop_reason = None
        self.nvic = None                      # set by scs.SCS()
        self.reset_request = None
        self._in_slice = False
        self._slice_end = 0
        self._map()

    # ---------------------------------------------------------------- memory
    def _map(self):
        uc = self.uc
        uc.mem_map(FLASH_BASE, FLASH_SIZE, UC_PROT_READ | UC_PROT_EXEC)
        uc.mem_write(FLASH_BASE, b'\x00' * FLASH_SIZE)   # STM32L1 erased flash reads 0x00
        self.eeprom = bytearray(EEPROM_SIZE)    # data EEPROM backing store (erased = 0x00)
        self.flash_ctl = None                    # FLASH model (cpu_store for EEPROM programming)
        uc.mmio_map(EEPROM_BASE, EEPROM_SIZE, self._ee_read, None, self._ee_write, None)
        uc.mem_map(SYSMEM_BASE, SYSMEM_SIZE, UC_PROT_READ)
        uc.mem_map(INFO_BASE, INFO_SIZE, UC_PROT_READ)
        uc.mem_map(SRAM_BASE, SRAM_SIZE, UC_PROT_ALL)
        uc.mmio_map(PERIPH_BASE, PERIPH_SIZE, self._pread, None, self._pwrite, None)
        uc.mmio_map(BB_PERIPH, 0x2000000, self._bb_read, BB_PERIPH, self._bb_write, BB_PERIPH)
        uc.mmio_map(BB_SRAM, 0x2000000, self._bb_read, BB_SRAM, self._bb_write, BB_SRAM)
        uc.mmio_map(SCS_BASE, SCS_SIZE, self._scs_read, None, self._scs_write, None)
        uc.hook_add(UC_HOOK_BLOCK, self._on_block)
        uc.hook_add(UC_HOOK_INTR, self._on_intr)
        uc.hook_add(UC_HOOK_MEM_INVALID, self._on_invalid)

    def load(self, addr, data):
        if EEPROM_BASE <= addr < EEPROM_BASE + EEPROM_SIZE:
            o = addr - EEPROM_BASE
            self.eeprom[o:o + len(data)] = data
        else:
            self.uc.mem_write(addr, data)

    def _ee_read(self, uc, off, size, ud):
        return int.from_bytes(self.eeprom[off:off + size], 'little')

    def _ee_write(self, uc, off, size, value, ud):
        if self.flash_ctl is None:
            self._note(EEPROM_BASE + off, 'W'); return
        self.flash_ctl.cpu_store(EEPROM_BASE + off, value, size)

    def add_periph(self, base, size, model):
        self.periphs.append((base, base + size, model))
        model.m = self

    def _find(self, addr):
        for b, e, mdl in self.periphs:
            if b <= addr < e:
                return b, mdl
        return None, None

    def _note(self, addr, rw):
        pc = self.uc.reg_read(UC_ARM_REG_PC)
        k = (addr, rw)
        if k not in self.unmodelled:
            self.unmodelled[k] = [pc, 0]
            self.log.append((self.cycles, f"UNMODELLED {rw} 0x{addr:08X} at pc 0x{pc:08X}"))
        self.unmodelled[k][1] += 1

    def _pread(self, uc, off, size, ud):
        addr = PERIPH_BASE + off
        b, mdl = self._find(addr)
        if mdl is None:
            self._note(addr, 'R'); return 0
        return mdl.read(addr - b, size) & ((1 << (8 * size)) - 1)

    def _pwrite(self, uc, off, size, value, ud):
        addr = PERIPH_BASE + off
        b, mdl = self._find(addr)
        if mdl is None:
            self._note(addr, 'W'); return
        mdl.write(addr - b, value, size)

    def _bb_target(self, base, off):
        region = PERIPH_BASE if base == BB_PERIPH else SRAM_BASE
        return region + off // 32, (off % 32) // 4

    def _bb_access(self, base, off, size):
        """Bit-band alias access of `size` bytes -> (aligned target address, bit within that unit).
        The bus access to the bit-band region has the same size as the alias access (PM0056 / RM0038)."""
        a, bit = self._bb_target(base, off)
        unit = a & ~(size - 1)
        return unit, bit + 8 * (a - unit)

    def _bb_read(self, uc, off, size, base):
        a, bit = self._bb_access(base, off, size)
        if base == BB_SRAM:
            v = int.from_bytes(self.uc.mem_read(a, size), 'little')
        else:
            v = self._pread(uc, a - PERIPH_BASE, size, None)
        return (v >> bit) & 1

    def _bb_write(self, uc, off, size, value, base):
        a, bit = self._bb_access(base, off, size)
        if base == BB_SRAM:
            v = int.from_bytes(self.uc.mem_read(a, size), 'little')
            v = (v | (1 << bit)) if value & 1 else (v & ~(1 << bit))
            self.uc.mem_write(a, v.to_bytes(size, 'little'))
        else:
            # read-modify-write of the containing unit, as the bit-band logic does on the bus
            v = self._pread(uc, a - PERIPH_BASE, size, None)
            v = (v | (1 << bit)) if value & 1 else (v & ~(1 << bit))
            self._pwrite(uc, a - PERIPH_BASE, size, v, None)

    def _scs_read(self, uc, off, size, ud):
        if self.nvic is None:
            self._note(SCS_BASE + off, 'R'); return 0
        return self.nvic.read(off, size)

    def _scs_write(self, uc, off, size, value, ud):
        if self.nvic is None:
            self._note(SCS_BASE + off, 'W'); return
        self.nvic.write(off, value, size)

    def _on_invalid(self, uc, access, addr, size, value, ud):
        pc = uc.reg_read(UC_ARM_REG_PC)
        self.log.append((self.cycles, f"INVALID access type {access} at 0x{addr:08X} size {size} pc 0x{pc:08X}"))
        self._stop_reason = f"invalid memory access 0x{addr:08X} at pc 0x{pc:08X}"
        return False

    # ---------------------------------------------------------------- time / events
    def _on_block(self, uc, addr, size, ud):
        n = self._blk.get(addr)
        if n is None:
            code = uc.mem_read(addr, size)
            n = sum(1 for _ in self.cs.disasm(bytes(code), addr)) or 1
            self._blk[addr] = n
        self.cycles += n

    def schedule(self, delay_cycles, cb):
        self._seq += 1
        due = self.cycles + max(1, int(delay_cycles))
        self.events.append((due, self._seq, cb))
        self.events.sort()
        # an event created during a slice that falls due before the slice ends must not wait for
        # the slice boundary: end the slice now so the run loop handles it on time
        if self._in_slice and due < self._slice_end:
            self.uc.emu_stop()

    def cycles_per_us(self):
        return self.sysclk_hz / 1_000_000

    def _run_events(self):
        while self.events and self.events[0][0] <= self.cycles:
            _, _, cb = self.events.pop(0)
            cb()

    # ---------------------------------------------------------------- exceptions
    def set_pending(self, excnum):
        self.pending.add(excnum)

    def _can_take(self):
        """Highest-priority pending exception that may preempt now, or None."""
        if not self.pending or self.nvic is None:
            return None
        primask = self.uc.reg_read(UC_ARM_REG_PRIMASK) & 1
        basepri = self.uc.reg_read(UC_ARM_REG_BASEPRI) & 0xFF
        cur = self.nvic.priority(self.active[-1]) if self.active else 256
        best = None
        for e in sorted(self.pending):
            if e >= 16 and not self.nvic.enabled(e):
                continue
            p = self.nvic.priority(e)
            if primask and e >= 4:            # PRIMASK masks all configurable-priority exceptions
                continue
            if basepri and p >= basepri:
                continue
            if p >= cur:
                continue
            if best is None or p < self.nvic.priority(best):
                best = e
        return best

    def _enter(self, exc, pc):
        uc = self.uc
        sp = uc.reg_read(UC_ARM_REG_SP)
        align = (sp & 4) and self.nvic.stkalign()
        sp = (sp - 32) & ~(7 if self.nvic.stkalign() else 3)
        vals = [uc.reg_read(r) for r in FRAME_REGS]
        vals[6] = pc & ~1
        vals[7] = (vals[7] | (1 << 24)) | ((1 << 9) if align else 0)
        uc.mem_write(sp, struct.pack('<8I', *vals))
        uc.reg_write(UC_ARM_REG_SP, sp)
        uc.reg_write(UC_ARM_REG_LR, 0xFFFFFFF9)       # return to Thread/Handler mode, main stack
        self.pending.discard(exc)
        self.active.append(exc)
        ipsr = exc & 0x1FF
        uc.reg_write(UC_ARM_REG_XPSR, (1 << 24) | ipsr)
        vtor = self.nvic.vtor
        handler = struct.unpack('<I', uc.mem_read(vtor + 4 * exc, 4))[0]
        self.cycles += 12                              # Cortex-M3 exception entry latency
        return handler | 1

    def _on_intr(self, uc, intno, ud):
        if intno == 8:                                 # EXCP_EXCEPTION_EXIT (EXC_RETURN branch)
            sp = uc.reg_read(UC_ARM_REG_SP)
            vals = struct.unpack('<8I', uc.mem_read(sp, 32))
            for r, v in zip(FRAME_REGS, vals):
                if r != UC_ARM_REG_PC:
                    uc.reg_write(r, v)
            sp += 32
            if vals[7] & (1 << 9):
                sp += 4
            uc.reg_write(UC_ARM_REG_SP, sp)
            if self.active:
                self.active.pop()
            self._resume = vals[6] | 1
            self.cycles += 12
            uc.emu_stop()
        else:
            pc = uc.reg_read(UC_ARM_REG_PC)
            self._stop_reason = f"CPU exception intno {intno} at pc 0x{pc:08X}"
            uc.emu_stop()

    def add_idle_hook(self, addr):
        """WFI/WFE at addr: advance time to the next event and skip the instruction."""
        def hook(uc, a, size, ud):
            if self.events:
                self.cycles = max(self.cycles, self.events[0][0])
            self._resume = (a + size) | 1
            uc.emu_stop()
        self.uc.hook_add(UC_HOOK_CODE, hook, begin=addr, end=addr)

    def request_reset(self, why):
        self.reset_request = why
        self.log.append((self.cycles, f"RESET requested: {why}"))
        self.uc.emu_stop()

    # ---------------------------------------------------------------- run loop
    def reset(self):
        sp, pc = struct.unpack('<II', self.uc.mem_read(FLASH_BASE, 8))
        self.uc.reg_write(UC_ARM_REG_SP, sp)
        self.uc.reg_write(UC_ARM_REG_XPSR, 1 << 24)
        self.pc = pc | 1
        self.active.clear(); self.pending.clear()

    def run(self, max_cycles, slice_cycles=4000):
        end = self.cycles + max_cycles
        while self.cycles < end and self._stop_reason is None and self.reset_request is None:
            self._run_events()
            exc = self._can_take()
            if exc is not None:
                self.pc = self._enter(exc, self.pc)
            n = slice_cycles
            if self.events:
                n = max(1, min(n, self.events[0][0] - self.cycles))
            self._resume = None
            start = self.cycles
            self._slice_end = self.cycles + n
            self._in_slice = True
            try:
                self.uc.emu_start(self.pc, 0xFFFFFFFF, count=n)
            except UcError as e:
                pc = self.uc.reg_read(UC_ARM_REG_PC)
                self._stop_reason = f"{e} at pc 0x{pc:08X}"
                break
            finally:
                self._in_slice = False
            if self._resume is not None:
                self.pc = self._resume
            else:
                self.pc = self.uc.reg_read(UC_ARM_REG_PC) | 1
            if self.cycles == start:                   # no block executed (stopped at once)
                self.cycles += 1
        return self._stop_reason
