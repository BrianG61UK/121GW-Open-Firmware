"""121GW emulator core: Cortex-M3 CPU (Unicorn), memory map, exception engine, virtual clock.

Execution model
- The CPU runs in slices.  Between slices the run loop delivers pending exceptions and advances
  peripheral events on the virtual clock.
- Virtual clock: a block hook adds the core clock cycles of each translated block when the block is entered: the
  Cortex-M3 cycle estimate of its instructions (emu/cycles.py, computed once per translated block with Capstone) plus
  the pipeline refill of a taken branch when the block is not entered from the end of the block before.  A block left
  before its end (slice limit, emu_stop from a hook or MMIO callback, WFI/WFE, MPU fault) is corrected when the CPU
  stops (_settle): the cycles of the instructions from the stop address to the block end are taken off again, because
  Unicorn resumes at that address as a new translated block that is counted on entry.  Every executed instruction is
  thus counted exactly once.  Inside a block the clock reads the value at the block end; a slice ends at the first
  block start at or after its end cycle (or earlier, at the Unicorn instruction count), so an event is handled at most
  one block late.  The clock never goes back behind a value a peripheral access has seen (_vis): a correction that
  would do so is kept as prepaid cycles (_prepay), taken from the next charges instead (_charge / _refund).
- Exception entry is done here (ARMv7-M: 8-word frame, EXC_RETURN in LR).  Exception return is the
  Unicorn M-class "exception exit" interrupt (intno 8): the frame is popped here and execution resumes.
- WFI/WFE: Unicorn rejects them as invalid instructions; run() catches that and emulates the sleep (_sleep,
  semantics in add_idle_hook), at no cost to code that does not sleep.
- IT state: Unicorn can report a stale ITSTATE after an IT block has ended; the IT bits stacked at an exception
  entry and those a slice starts with are the architectural state at the PC (it_state_at), never Unicorn's alone.
"""
import struct
from bisect import bisect_left
from fractions import Fraction
from unicorn.arm_const import UC_CPU_ARM_CORTEX_M3
from unicorn import Uc, UcError, UC_ARCH_ARM, UC_MODE_THUMB, UC_MODE_MCLASS, UC_HOOK_BLOCK, UC_HOOK_INTR, UC_HOOK_CODE, UC_HOOK_MEM_INVALID, UC_PROT_READ, UC_PROT_EXEC, UC_PROT_ALL, UC_MEM_WRITE_PROT
from unicorn.arm_const import *
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_MCLASS
from .cycles import CycleModel
import unicorn as _unicorn

# Unicorn 2.1.4 (the version this was checked with) reports a rejected WFE / WFI with PC past the instruction; later
# versions are assumed to do the same (unverified), older ones report the instruction address (run())
_UC_PC_PAST_WFX = tuple(int(x) for x in _unicorn.__version__.split('.')[:3]) >= (2, 1, 4)

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

# xPSR IT bits (ARMv7-M ARM B1.4.2 / A2.5.2): ITSTATE[1:0] in xPSR[26:25], ITSTATE[7:2] in xPSR[15:10]
XPSR_IT = (3 << 25) | (0x3F << 10)


def it_bits(xpsr):
    """ITSTATE (8 bits: IT[7:5] base condition, IT[4:0] mask) from an xPSR value."""
    return ((xpsr >> 25) & 3) | (((xpsr >> 10) & 0x3F) << 2)


def it_xpsr(itstate):
    """The xPSR IT bits that hold `itstate`."""
    return ((itstate & 3) << 25) | (((itstate >> 2) & 0x3F) << 10)


def it_advance(itstate):
    """ITAdvance() of the ARMv7-M ARM (A7.3.2): the state of the next instruction of the IT block."""
    if itstate & 7 == 0:
        return 0
    return (itstate & 0xE0) | ((itstate << 1) & 0x1F)


class Machine:
    def __init__(self, sysclk_hz=16_000_000):
        self.uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB | UC_MODE_MCLASS)
        # the STM32L152 core is a Cortex-M3 (PM0056 1.1): select that CPU model explicitly, before any memory is mapped,
        # instead of relying on Unicorn's default model for M-class mode
        self.uc.ctl_set_cpu_model(UC_CPU_ARM_CORTEX_M3)
        self.cs = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_MCLASS)
        self.cyc = CycleModel()
        # virtual time in core clock cycles: per instruction the best-case Cortex-M3 count of ARM DDI 0337H Table 3.1
        # with the flash branch penalty of RM0038 3.3.2 (emu/cycles.py; a lower bound of the hardware time).  Exception
        # entry and return add 12 cycles each, a tail-chained entry 6 (ARM DDI 0337H "Exception handling": "a maximum
        # of a 12 cycle latency ... when the memory being accessed has no wait states", "Returns from interrupts
        # similarly take twelve cycles", "Tail chaining requires 6 cycles when using zero wait state memory").
        self.cycles = 0
        self._sysclk_hz = sysclk_hz           # updated by the RCC model through the sysclk_hz property
        self._clk_mark = (0, Fraction(0))     # (cycles, elapsed seconds) when the core clock last changed
        self.clock_hooks = []                 # callables run after every core clock change (event re-timing)
        self._run_end = None                  # end cycle of the running run() call (None outside run()); re-scaled
                                              # by a core clock change (sysclk_hz setter) so the budget stays a time
        self.periphs = []                     # (base, end, model)
        self.events = []                      # (due_cycle, seq, callback)
        self._seq = 0
        self.pending = set()                  # pending exception numbers (16+IRQ for interrupts)
        self.event_reg = False                # WFE event register: set by SEV and by an external event signal (EXTI event
                                              # line), PM0056 2.5.2 / 2.5.3 / 3.12.9; cleared by a WFE that returns on it
        self.idle = False                     # core asleep in WFI/WFE with nothing scheduled
        self._asleep_at = None                # address of the WFI / WFE the core sleeps at (see _sleep)
        self._wfi_hooked = set()              # WFI addresses with an idle hook (see _on_block)
        self.active = []                      # stack of active exception numbers
        self.unmodelled = {}                  # (addr, rw) -> first pc, count
        self.log = []                         # (cycle, text)
        self._blk = {}                        # (block start, size) -> (instruction addresses, cumulative cycles)
        self._cur = None                      # the block counted last: (start, end, addresses, cumulative cycles,
                                              #   cycles taken off its first instruction, carry it consumed)
        self._last = None                     # (end, address of the last instruction) of the block entered last; None
                                              #   when execution continues without a branch (resume, exception)
        self._carry = None                    # (address, cycles) of an instruction a slice stopped at: its cost in
                                              #   the block it was cut from (pipelining / IT folding context)
        self._tail = False                    # an exception return with no instruction since (tail-chaining)
        self.exc_exit_hooks = []              # hook(exception number) after each exception return (periph/tim.py _LevelIrq)
        self._vis = 0                         # cycles value last seen by a peripheral / SCS / EEPROM access
        self._prepay = 0                      # cycles counted ahead of the executed instructions (see _refund)
        self._restart = False                 # the slice ended at once to retranslate a block (no progress needed)
        self._resume = None
        self._stop_reason = None
        self.nvic = None                      # set by scs.SCS()
        self.boot_base = FLASH_BASE           # address of the vector table the core boots from on every reset.  FLASH_BASE: the
                                              # meter (the bootloader runs and hands over).  The application's table
                                              # (0x08006000): direct boot, no bootloader image loaded (app.py)
        self.reset_request = None
        self._in_slice = False
        self._slice_end = 0
        self.mpu_hold = False                 # an access cancelled by the MPU model (scs.py): MMIO callbacks do nothing
        self._fault = None                    # (exception number, return address) of a synchronous fault, entered next
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
        self._vis = self.cycles
        if self.mpu_hold:
            return
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
        self._vis = self.cycles
        if self.mpu_hold:
            return 0
        addr = PERIPH_BASE + off
        b, mdl = self._find(addr)
        if mdl is None:
            self._note(addr, 'R'); return 0
        return mdl.read(addr - b, size) & ((1 << (8 * size)) - 1)

    def _pwrite(self, uc, off, size, value, ud):
        self._vis = self.cycles
        if self.mpu_hold:
            return
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
        if self.mpu_hold:
            return
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
        self._vis = self.cycles
        if self.mpu_hold:
            return 0
        if self.nvic is None:
            self._note(SCS_BASE + off, 'R'); return 0
        return self.nvic.read(off, size)

    def _scs_write(self, uc, off, size, value, ud):
        self._vis = self.cycles
        if self.mpu_hold:
            return
        if self.nvic is None:
            self._note(SCS_BASE + off, 'W'); return
        self.nvic.write(off, value, size)

    def _on_invalid(self, uc, access, addr, size, value, ud):
        if self.nvic is not None and self.nvic.fault_pending:   # the MPU model cancelled this access (scs.py)
            return False
        if (access == UC_MEM_WRITE_PROT and self.flash_ctl is not None
                and (FLASH_BASE <= addr < FLASH_BASE + FLASH_SIZE or INFO_BASE <= addr < INFO_BASE + INFO_SIZE
                     or SYSMEM_BASE <= addr < SYSMEM_BASE + SYSMEM_SIZE)):
            # a CPU store to program flash, the option bytes or system memory (read-only Unicorn memory): the FLASH
            # model decides what it does (periph/flash.py cpu_store); the store itself is skipped by Unicorn
            self._vis = self.cycles
            self.flash_ctl.cpu_store(addr, value, size)
            return True
        pc = uc.reg_read(UC_ARM_REG_PC)
        self.log.append((self.cycles, f"INVALID access type {access} at 0x{addr:08X} size {size} pc 0x{pc:08X}"))
        self._stop_reason = f"invalid memory access 0x{addr:08X} at pc 0x{pc:08X}"
        return False

    # ---------------------------------------------------------------- time / events
    def _on_block(self, uc, addr, size, ud):
        self._cur = None                      # the previous block ran to its end (control reached a new block)
        self._tail = False
        if self.cycles >= self._slice_end:    # slice over: stop before this block runs (counted when the slice resumes)
            uc.emu_stop()
            return
        if self.nvic is not None and self.nvic.mpu.ctrl & 1 and self.nvic.mpu.block_check(addr, size):
            self._restart = True              # MPU: instruction fetch violation (or block cut at the violating
            return                            # instruction); the block is not run and not counted
        key = (addr, size) if addr < SRAM_BASE else (addr, size, bytes(uc.mem_read(addr, size)))   # code in RAM
        b = self._blk.get(key)                                                                     # may change
        if b is None:
            ia, cum, wfi = self.cyc.block(bytes(uc.mem_read(addr, size)), addr)
            # Unicorn executes WFI as a no-op: hook each WFI the first time its block is seen, flush the translated
            # block so the hook takes effect, and restart the block (WFE raises an error instead, handled in run())
            wfi = [a for a in wfi if a not in self._wfi_hooked]
            if wfi:
                for a in wfi:
                    self._wfi_hooked.add(a)
                    self.add_idle_hook(a, 'wfi')
                uc.ctl_remove_cache(addr, addr + size)
                self._resume = addr | 1
                self._restart = True
                uc.emu_stop()
                return
            b = self._blk[key] = (ia, cum)
        ia, cum = b
        c = cum[-1]
        last, carry = self._last, self._carry
        self._carry = None
        adj = 0
        if carry is not None and carry[0] == addr:
            adj = cum[1] - carry[1]           # resumed at a cut point: the cost it had in the block it was cut from
        if last is not None and addr != last[0]:  # not entered from the end of the block before: a taken branch
            c += 1 + self._flash_penalty(last[1], addr)       # refill P = 1 (DDI 0337H Table 3.1: 1 to 3)
        if self._prepay:
            self._charge(c - adj)
        else:
            self.cycles += c - adj
        self._cur = (addr, addr + size, ia, cum, adj, carry)
        self._last = (addr + size, ia[-1])

    def _flash_penalty(self, br, target):
        """Wait states of a taken branch from the instruction at br to target (RM0038 3.3.2 note): FLASH_ACR.LATENCY when
        the target is in flash and in neither the 64-bit line of the branch nor, with PRFTEN, the next (prefetched)
        line."""
        f = self.flash_ctl
        if f is None or not FLASH_BASE <= target < FLASH_BASE + FLASH_SIZE:
            return 0
        acr = f.acr
        if not acr & 1:                                # LATENCY (FLASH_ACR bit 0): 0 wait states
            return 0
        tl, bl = target & ~7, br & ~7
        if tl == bl or (acr & 2 and tl == bl + 8):     # PRFTEN (bit 1)
            return 0
        return 1

    def _settle(self, pc):
        """The CPU stopped with pc as the next instruction to execute.  When pc lies inside the block counted last,
        the instructions from pc to the block end did not execute: take their cycles off (they are counted again when
        the slice resumes at pc, which Unicorn translates as a new block).  A taken-branch refill charged on entry
        stays (the branch was taken); execution then continues at pc without a branch."""
        cur, self._cur = self._cur, None
        if cur is not None and cur[0] <= pc < cur[1]:
            ia, cum = cur[2], cur[3]
            k = bisect_left(ia, pc)
            sub = cum[-1] - cum[k]
            if k == 0:
                sub -= cur[4]                          # nothing ran: the resumed block is this block again
                self._carry = cur[5]
            else:
                self._carry = (pc, cum[k + 1] - cum[k])
            self._refund(sub)
            self._last = None

    def _charge(self, c):
        """Add c >= 0 executed cycles; prepaid cycles are used up first."""
        t = self.cycles - self._prepay + c
        if t >= self.cycles:
            self.cycles, self._prepay = t, 0
        else:
            self._prepay = self.cycles - t

    def _refund(self, c):
        """Take off c cycles counted for instructions that did not execute.  The clock does not go back behind _vis (a
        peripheral may have stored that time, e.g. SysTick reload instant): the rest stays prepaid."""
        t = self.cycles - self._prepay - c
        if t >= self._vis:
            self.cycles, self._prepay = t, 0
        else:
            self.cycles, self._prepay = self._vis, self._vis - t

    def schedule(self, delay_cycles, cb):
        self._seq += 1
        due = self.cycles + max(1, int(delay_cycles))
        self.events.append((due, self._seq, cb))
        self.events.sort()
        # an event created during a slice that falls due before the slice ends must not wait for
        # the slice boundary: the slice end moves to the due cycle, so the run loop handles it on time.  The stop is not
        # issued here: schedule() is mostly called from inside a peripheral register access, and Unicorn re-executes a
        # load/store that is stopped inside its MMIO callback (the access would reach the peripheral twice).  The block
        # hook stops at the first basic block start at or after the slice end instead.
        if self._in_slice and due < self._slice_end:
            self._slice_end = due

    def stop_soon(self):
        """End the running slice at the next basic block start (safe from inside an MMIO callback, see schedule())."""
        if self._in_slice:
            self._slice_end = min(self._slice_end, self.cycles)

    @property
    def sysclk_hz(self):
        return self._sysclk_hz

    @sysclk_hz.setter
    def sysclk_hz(self, hz):
        old = self._sysclk_hz
        self._clk_mark = (self.cycles, self.elapsed_s())   # close the time segment run at the old clock
        self._sysclk_hz = hz
        # A run() budget is given in cycles of the clock in effect when run() was called (callers compute it as
        # seconds x sysclk_hz).  The cycles still to run are re-scaled to the new clock so the call ends at the same
        # emulated time: without this a drop from 4.194 MHz to 65.536 kHz (v2.05 FUN_0801C522 before STOP) made the
        # rest of a 50 ms scenario chunk last 64 times longer and moved every later scenario step.
        if self._run_end is not None and hz != old:
            rem = self._run_end - self.cycles
            if rem > 0:
                self._run_end = self.cycles + max(1, -(-rem * hz // old))     # ceil(rem * hz / old)
                if self._in_slice and self._run_end < self._slice_end:
                    self._slice_end = self._run_end
        for hook in list(self.clock_hooks):
            hook()

    def elapsed_s(self):
        """Emulated time in seconds (exact): the cycle count integrated over the core clock history.
        Models on clocks that are independent of the core clock (RTC, external RTC chip) use this."""
        c0, t0 = self._clk_mark
        return t0 + Fraction(self.cycles - c0, self._sysclk_hz)

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

    def it_state_at(self, pc, reported):
        """Architectural ITSTATE of the instruction at pc, given the state Unicorn reports (`reported`).

        Unicorn 2.1.4 keeps its IT state in the translated code and writes it to the CPU state only at some
        instructions of an IT block; after the block has ended the stale value stays.  Measured: after
        `cmp r0, r1; it hi; strhi r0, [r2]; b L` with the store executed under a memory hook, a stop at L reports
        ITSTATE 0x88 although L is outside the block; stacked at an exception entry and restored at its return, that
        value makes the instruction at L conditional ("hi"), and with the condition false it is skipped (seen in the
        production image: `cmp r6, #0` at the loop head of ff16_f_write skipped, the loop never ended).
        A real Cortex-M3 advances ITSTATE with every instruction (ARMv7-M ARM A7.3.2), so the state at pc is fixed by
        the code: pc must be the k-th instruction after an IT instruction (k = 1..4) whose state, advanced k - 1 times,
        equals `reported`.  The IT instruction is searched in the 8 halfwords before pc (IT + 3 instructions of up to
        4 bytes), and the instruction sizes from it to pc decide whether pc is reached.  Returns `reported` when it is
        confirmed that way, else 0."""
        if reported & 0xF == 0:
            return 0
        pc &= ~1
        for back in range(2, 18, 2):
            a = pc - back
            try:
                hw = int.from_bytes(self.uc.mem_read(a, 2), 'little')
            except UcError:                            # before the start of the mapped region: no instruction there
                continue
            if hw & 0xFF00 != 0xBF00 or hw & 0xF == 0:
                continue                               # not an IT instruction (IT: 0xBFxx with a nonzero mask)
            state, addr = hw & 0xFF, a + 2
            while addr < pc and state:
                first = int.from_bytes(self.uc.mem_read(addr, 2), 'little')
                addr += 4 if first >> 11 in (0x1D, 0x1E, 0x1F) else 2
                state = it_advance(state)
            if addr == pc and state == reported:
                return reported
        return 0

    def _it_checked_xpsr(self):
        """Unicorn's xPSR with the IT bits replaced by the architectural ITSTATE of the instruction at self.pc
        (it_state_at); written back when they differ, so that the next slice is translated with the right state."""
        x = self.uc.reg_read(UC_ARM_REG_XPSR)
        it = it_bits(x)
        if it:
            good = self.it_state_at(self.pc, it)
            if good != it:
                x = (x & ~XPSR_IT) | it_xpsr(good)
                self.uc.reg_write(UC_ARM_REG_XPSR, x)
        return x

    def _enter(self, exc, pc):
        uc = self.uc
        sp = uc.reg_read(UC_ARM_REG_SP)
        align = (sp & 4) and self.nvic.stkalign()
        sp = (sp - 32) & ~(7 if self.nvic.stkalign() else 3)
        vals = [uc.reg_read(r) for r in FRAME_REGS]
        vals[6] = pc & ~1
        it = it_bits(vals[7])
        if it:                                         # the stacked IT bits: the architectural state at pc
            vals[7] = (vals[7] & ~XPSR_IT) | it_xpsr(self.it_state_at(pc, it))
        vals[7] = (vals[7] | (1 << 24)) | ((1 << 9) if align else 0)
        bad = self.nvic.mpu.frame_violation(sp, exc)      # MPU: frame not writable -> MSTKERR (PM0056 4.4.10)
        if bad is None:
            uc.mem_write(sp, struct.pack('<8I', *vals))
        uc.reg_write(UC_ARM_REG_SP, sp)
        uc.reg_write(UC_ARM_REG_LR, 0xFFFFFFF9)       # return to Thread/Handler mode, main stack
        self.pending.discard(exc)
        self.active.append(exc)
        ipsr = exc & 0x1FF
        uc.reg_write(UC_ARM_REG_XPSR, (1 << 24) | ipsr)
        vtor = self.nvic.vtor
        handler = struct.unpack('<I', uc.mem_read(vtor + 4 * exc, 4))[0]
        # exception entry latency (ARM DDI 0337H "Exception handling"): 12 cycles; tail-chained to an exception return
        # with no instruction in between, the return (12, charged in _on_intr) and this entry together take 6
        if self._tail:
            self._refund(6)
        else:
            self._charge(12)
        self._tail = False
        self._last = self._carry = None
        if bad is not None:
            self.nvic.stacking_fault(handler | 1, bad)
        return handler | 1

    def _on_intr(self, uc, intno, ud):
        if intno == 8:                                 # EXCP_EXCEPTION_EXIT (EXC_RETURN branch)
            sp = uc.reg_read(UC_ARM_REG_SP)
            if self.nvic is not None and self.nvic.mpu.frame_read_violation(sp) is not None:
                self._stop_reason = (f"MPU: exception return frame at 0x{sp:08X} violates the region map "
                                     f"(MUNSTKERR is not modelled, emu/scs.py)")
                uc.emu_stop()
                return
            self._cur = None                           # the EXC_RETURN branch ends its block and has executed
            self._last = self._carry = None
            self._tail = True
            vals = struct.unpack('<8I', uc.mem_read(sp, 32))
            for r, v in zip(FRAME_REGS, vals):
                if r != UC_ARM_REG_PC:
                    uc.reg_write(r, v)
            sp += 32
            if vals[7] & (1 << 9):
                sp += 4
            uc.reg_write(UC_ARM_REG_SP, sp)
            done = self.active.pop() if self.active else None
            for hook in list(self.exc_exit_hooks):     # level-sensitive sources still asserted pend again at once
                hook(done)
            self._resume = vals[6] | 1
            self._charge(12)
            uc.emu_stop()
        else:
            pc = uc.reg_read(UC_ARM_REG_PC)
            self._stop_reason = f"CPU exception intno {intno} at pc 0x{pc:08X}"
            uc.emu_stop()

    def add_idle_hook(self, addr, kind):
        """WFI (kind 'wfi') or WFE (kind 'wfe') at addr.  Unicorn does not implement the sleep (it rejects WFE), so the
        instruction is emulated here (PM0056 3.12.11 WFI, 3.12.10 WFE, 4.4.6 SCB_SCR):
        - wake condition met: continue after the instruction.  WFI wakes on a pending, enabled exception, also while
          PRIMASK masks it (the exception is then taken only when PRIMASK clears).  WFE wakes when the event register
          is set (consumed), or on a pending, enabled exception, or with SCR.SEVONPEND on any pending interrupt.
        - otherwise the core sleeps: virtual time jumps to the next scheduled event and the instruction is executed
          again afterwards, so the wake condition is re-evaluated; with no event scheduled the slice ends (idle) and
          the core stays at the instruction until an external input (key, dial) makes an exception pending.  An
          exception taken while the core sleeps there returns to the instruction AFTER the WFI / WFE (the exception
          that wakes the core is entered with the next instruction as return address, PM0056 3.12.11); run() does that
          with `_asleep_at`."""
        op = 0xBF30 if kind == 'wfi' else 0xBF20

        def hook(uc, a, size, ud):
            if size != 2 or int.from_bytes(uc.mem_read(a, 2), 'little') != op:
                return                                 # the code at a changed (RAM): no longer a WFI / WFE
            self._settle(a)                            # the code hook runs before the instruction at a
            self._resume = self._sleep(a, kind)
            uc.emu_stop()
        self.uc.hook_add(UC_HOOK_CODE, hook, begin=addr, end=addr)

    def _sleep(self, a, kind):
        """Execute WFI/WFE at a (semantics in add_idle_hook); returns the address to resume at (Thumb bit set)."""
        self._asleep_at = None
        if self._wake_ok(kind):
            if kind == 'wfe':
                self.event_reg = False
            self._charge(1)                            # the WFI / WFE executes: 1 + W (DDI 0337H Table 3.1), W = 0
            return (a + 2) | 1
        self._asleep_at = a
        if self.events:                                # asleep until the next event, at most to the end of the run()
            due = self.events[0][0]                    # call (the sleep goes on in the next call: the instruction is
            if self._run_end is not None:              # executed again there)
                due = min(due, self._run_end)
            self._charge(max(0, due - (self.cycles - self._prepay)))
        else:
            self.idle = True
        return a | 1

    def _wake_ok(self, kind):
        """Wake condition of WFI / WFE (PM0056).
        WFI (2.5.2 "Wakeup from WFI", 3.12.11): an exception with sufficient priority to cause exception entry, i.e.
        enabled, pending, above the current execution priority and not masked by BASEPRI or FAULTMASK; PRIMASK does not
        prevent the wake-up (the core wakes but takes the exception only when PRIMASK clears).
        WFE (3.12.10): the event register set (SEV, external event signal), or an exception not masked by the exception
        mask registers (PRIMASK, FAULTMASK, BASEPRI) or the current priority, or, with SCR.SEVONPEND, an exception
        entering the Pending state (modelled as: any pending exception)."""
        if kind == 'wfe':
            if self.event_reg:
                return True
            if self.nvic is not None and self.nvic.scr & 0x10 and self.pending:   # SEVONPEND (SCR bit 4)
                return True
        if not self.pending:
            return False
        if self.nvic is None:
            return True
        uc = self.uc
        primask = uc.reg_read(UC_ARM_REG_PRIMASK) & 1
        faultmask = uc.reg_read(UC_ARM_REG_FAULTMASK) & 1
        basepri = uc.reg_read(UC_ARM_REG_BASEPRI) & 0xFF
        cur = self.nvic.priority(self.active[-1]) if self.active else 256
        for e in self.pending:
            if e >= 16 and not self.nvic.enabled(e):
                continue
            p = self.nvic.priority(e)
            if p >= cur:
                continue
            if e != 2 and faultmask:                      # FAULTMASK masks everything except NMI
                continue
            if e >= 4 and basepri and p >= basepri:
                continue
            if kind == 'wfe' and primask and e >= 4:      # WFE: PRIMASK masks configurable exceptions
                continue
            return True
        return False

    def _take_fault(self):
        """Collect a synchronous fault raised by the MPU model (scs.py): cancel the access and queue the exception."""
        if self.nvic is not None and self.nvic.fault_pending:
            self._fault = self.nvic.take_fault()
            if self._fault is not None:
                self._settle(self._fault[1] & ~1)      # the faulting instruction did not execute
            else:                                      # lockup: the run stops at the instruction
                self._settle(self.uc.reg_read(UC_ARM_REG_PC) & ~1)

    def request_reset(self, why):
        self.reset_request = why
        self.log.append((self.cycles, f"RESET requested: {why}"))
        self.uc.emu_stop()

    # ---------------------------------------------------------------- run loop
    def reset(self):
        """Core reset (power-on or system reset): the CPU restarts from the vector table at 0x08000000 (boot from
        flash), or from boot_base when that is set to the application's table (direct boot, see app.py).  PM0056 2.1.3 (Table 2, "Core register set summary") and 2.3.2 (Reset): MSP loaded from the first
        word, PC from the reset vector, LR = 0xFFFFFFFF, PSR = 0x01000000 (Thread mode, T bit), PRIMASK, FAULTMASK,
        BASEPRI and CONTROL = 0 (privileged Thread mode on the main stack).  R0-R12 and PSP have the reset value
        "Unknown" in Table 2: they are left as they are.  Exceptions that were pending or active are dropped."""
        uc = self.uc
        sp, pc = struct.unpack('<II', uc.mem_read(self.boot_base, 8))
        # the special registers can only be written from a privileged state, and a CONTROL.nPRIV = 1 left over from
        # before the reset would refuse the write: go through Handler mode (privileged), then drop to Thread mode
        uc.reg_write(UC_ARM_REG_XPSR, (1 << 24) | 1)
        for reg in (UC_ARM_REG_CONTROL, UC_ARM_REG_PRIMASK, UC_ARM_REG_FAULTMASK, UC_ARM_REG_BASEPRI):
            uc.reg_write(reg, 0)
        uc.reg_write(UC_ARM_REG_XPSR, 1 << 24)
        uc.reg_write(UC_ARM_REG_MSP, sp)
        uc.reg_write(UC_ARM_REG_LR, 0xFFFFFFFF)
        for reg in (UC_ARM_REG_CONTROL, UC_ARM_REG_PRIMASK, UC_ARM_REG_FAULTMASK, UC_ARM_REG_BASEPRI):
            if uc.reg_read(reg):                       # never continue silently with a core that kept mask state
                raise RuntimeError(f'core reset: special register {reg} did not clear')
        if uc.reg_read(UC_ARM_REG_SP) != sp or uc.reg_read(UC_ARM_REG_XPSR) & 0x1FF:
            raise RuntimeError('core reset: stack pointer or IPSR not restored')
        self.pc = pc | 1
        if self.boot_base != FLASH_BASE:               # direct boot: the table the core booted from is the active one,
            self.nvic.vtor = self.boot_base            # as after the bootloader's hand-over to the application (VTOR)
        self.active.clear(); self.pending.clear()
        self._asleep_at = None
        self._resume = None
        self._cur = self._last = self._carry = None
        self._tail = False
        self._prepay = 0                               # the abandoned instructions never execute

    def run(self, max_cycles, slice_cycles=4000):
        """Run for max_cycles cycles of the current core clock (a time budget: a clock change during the call re-scales
        the cycles still to run, see the sysclk_hz setter), or until the core stops, a reset is requested or the core
        sleeps with nothing scheduled.  Returns the stop reason (None when the CPU did not stop)."""
        self._run_end = self.cycles + max_cycles
        try:
            return self._run(slice_cycles)
        finally:
            self._run_end = None

    def _run(self, slice_cycles):
        while self.cycles < self._run_end and self._stop_reason is None and self.reset_request is None:
            self._run_events()
            if self._fault is not None:                # synchronous fault of the MPU model: taken before anything else
                exc, rpc = self._fault
                self._fault = None
                self.pc = self._enter(exc, rpc)
                self._take_fault()                     # a stacking fault of this entry
                continue
            exc = self._can_take()
            if exc is not None:
                if self._asleep_at is not None and (self.pc & ~1) == self._asleep_at:
                    self.pc = (self._asleep_at + 2) | 1        # woken by this exception: it returns past the WFI / WFE
                self._asleep_at = None
                self.pc = self._enter(exc, self.pc)
                self._take_fault()
                if self._fault is not None:            # stacking fault of this entry: enter it before the handler runs
                    continue
            n = max(1, min(slice_cycles, self._run_end - self.cycles))   # a slice does not run past the run() budget
            if self.events:
                n = max(1, min(n, self.events[0][0] - self.cycles))
            self._resume = None
            start = self.cycles - self._prepay         # executed time at the slice start
            self._slice_end = self.cycles + n
            self._restart = False
            self._cur = None
            self._in_slice = True
            self._it_checked_xpsr()                    # no stale IT state into the translation at self.pc
            try:
                self.uc.emu_start(self.pc, 0xFFFFFFFF, count=n)
            except UcError as e:
                if self.nvic is not None and self.nvic.fault_pending:   # access cancelled by the MPU model: not an error
                    self._in_slice = False
                    self._take_fault()
                    continue
                pc = self.uc.reg_read(UC_ARM_REG_PC)
                # WFI / WFE: Unicorn rejects them.  Unicorn 2.1.4 reports the error with PC already past the instruction
                # (the failing WFE of v2.05 at 0x080207F6 is reported at 0x080207F8), an older one at the instruction
                # itself: the candidate the installed version reports is tried first (with 2.1.4 the halfword at PC
                # may be a second WFE / WFI, e.g. "wfe; wfe", which is not the one that failed)
                wfx = None
                cands = ((pc & ~1) - 2, pc & ~1) if _UC_PC_PAST_WFX else (pc & ~1, (pc & ~1) - 2)
                for cand in cands:
                    hw = int.from_bytes(self.uc.mem_read(cand, 2), 'little')
                    if hw in (0xBF30, 0xBF20):
                        wfx = (cand, hw)
                        break
                if wfx is not None:                    # emulate the sleep here
                    self._in_slice = False
                    self._settle(wfx[0])               # the WFI / WFE and the rest of its block did not execute
                    self.pc = self._sleep(wfx[0], 'wfi' if wfx[1] == 0xBF30 else 'wfe')
                    if self.cycles - self._prepay == start:
                        self._charge(1)
                    if self.idle:
                        self.idle = False
                        break
                    continue
                self._stop_reason = f"{e} at pc 0x{pc:08X}"
                break
            finally:
                self._in_slice = False
            if self.nvic is not None and self.nvic.fault_pending:
                self._take_fault()                     # MPU fault raised in this slice
                continue
            self._settle(self.uc.reg_read(UC_ARM_REG_PC) & ~1)   # block left before its end (count, emu_stop)
            if self._resume is not None:
                self.pc = self._resume
            else:
                self.pc = self.uc.reg_read(UC_ARM_REG_PC) | 1
            if self.cycles - self._prepay == start and not self._restart:   # nothing executed: keep time moving
                self._charge(1)
            if self.idle:                              # asleep with nothing scheduled: give the caller back
                self.idle = False                      # control; it supplies inputs and calls run() again
                break
        return self._stop_reason
