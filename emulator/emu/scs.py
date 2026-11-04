"""System control space: NVIC, SysTick, SCB (fault registers), MPU, DBGMCU (PM0056 / RM0038).

Offsets are relative to 0xE0000000.  Exception numbers: 15 = SysTick, 16+n = IRQn.

Memory protection unit (PM0056 4.2, class MPU below)
- Registers MPU_TYPER / CTRL / RNR / RBAR / RASR at 0xE000ED90..0xE000EDA0 (Table 40): 8 unified regions, regions of
  2^(SIZE+1) bytes from 32 bytes to 4 GB, base aligned to the size, eight subregions of regions of 256 bytes or more
  (SRD), highest enabled region wins, AP / XN permissions (Table 37) for privileged and unprivileged accesses,
  PRIVDEFENA background region, HFNMIENA (MPU off in HardFault / NMI / FAULTMASK handlers unless set), access to the
  system control space and the vector table always permitted.
- Violations raise MemManage: SCB_CFSR.MMFSR DACCVIOL (bit 1) with MMARVALID (bit 7) and SCB_MMFAR = address of the
  violating access, IACCVIOL (bit 0) for instruction fetches from an XN or no-access region, MSTKERR (bit 4) when the
  exception entry frame cannot be written.  The stacked PC is the faulting instruction (PM0056 4.4.10).  When
  SCB_SHCSR.MEMFAULTENA is clear, or the MemManage priority is not higher than the running priority (PRIMASK, BASEPRI,
  FAULTMASK, active handler), the fault is escalated to HardFault with SCB_HFSR.FORCED (PM0056 2.4.2); a fault while
  HardFault or NMI is active is a lockup (PM0056 2.4.4) and stops the machine.
- Mechanism: Unicorn has no MPU, so the memory-access hooks (which also fire for the MMIO regions) and the block check
  of core.py are used.  The write hook is installed with the first enabled MPU, the read hook only once a read can be
  denied (a region without read permission, or no background region), because Unicorn 2.1.4 mishandles the IT state
  after a load that precedes an opposite-condition instruction of the same IT block when a memory-read hook exists
  (tools/check_image.py item 6); a run without MPU pays nothing.  A violating access is cancelled: the core stops at that access, a store to SRAM is
  undone, MMIO callbacks are muted (Machine.mpu_hold) and the register state is the one before the instruction; the
  fault is taken at the next scheduling point of Machine.run().
- Not modelled, and loud about it: the alias registers MPU_RBAR_A1..A3 / RASR_A1..A3 (PM0056 4.2.3 names them, but
  does not define which region number an alias addresses; the accesses are logged as UNMODELLED), the unstacking
  violation MUNSTKERR (stops the machine with a message), regions of fewer than 32 bytes (SIZE < 4, a value PM0056
  4.2.9 calls minimum "3" in one place and 32 bytes = SIZE 4 in another; the region is ignored and logged),
  non-word accesses to MPU registers other than RASR (PM0056 4.2.4 requires aligned words; logged as UNMODELLED), the
  default-map XN attribute of the peripheral and system regions (PM0056 Table 12), and BusFault / UsageFault generation.
"""
import struct
from emu.core import SRAM_BASE, SRAM_SIZE, XPSR_IT, it_bits, it_xpsr, it_advance
from unicorn import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE, UC_HOOK_CODE, UC_MEM_WRITE, UC_CTL_IO_WRITE
from unicorn.unicorn_const import UC_CTL_TLB_FLUSH
from unicorn.arm_const import UC_ARM_REG_PC, UC_ARM_REG_XPSR, UC_ARM_REG_CONTROL, UC_ARM_REG_PRIMASK, \
    UC_ARM_REG_BASEPRI, UC_ARM_REG_FAULTMASK

SYSTICK_EXC = 15
PENDSV_EXC = 14


MPU_BASE_OFF = 0xED90                      # MPU_TYPER (PM0056 Table 40, offsets 0x00..0x10 from 0xE000ED90)
MPU_REGIONS = 8                            # DREGION = 8 (PM0056 4.2.5)
MPU_RASR_MASK = 0x173FFF3F                 # XN 28, AP 26:24, TEX/S/C/B 21:16, SRD 15:8, SIZE 5:1, ENABLE 0 (4.2.9)
SCS_FIRST, SCS_END = 0xE000E000, 0xE000F000  # system control space: always permitted while the MPU is on (4.2.6)
GRANULE = 32                               # smallest MPU region (4.2.9)

# SCB fault status bits (PM0056 4.4.9 - 4.4.11)
MMFSR_IACCVIOL, MMFSR_DACCVIOL, MMFSR_MUNSTKERR, MMFSR_MSTKERR, MMFSR_MMARVALID = 0x01, 0x02, 0x08, 0x10, 0x80
HFSR_FORCED = 1 << 30
SHCSR_MEMFAULTENA, SHCSR_BUSFAULTENA, SHCSR_USGFAULTENA = 1 << 16, 1 << 17, 1 << 18
EXC_HARDFAULT, EXC_MEMMANAGE = 3, 4


class MPU:
    """Memory protection unit of PM0056 4.2 (see the module docstring for the mechanism and the limits)."""

    def __init__(self, scs):
        self.scs = scs
        self.m = scs.m
        self._wr_hook = False              # memory-write hook installed (once; it stays installed and is gated by `active`)
        self._rd_hook = False              # memory-read hook installed (only once a read can be denied, see _sync_hooks)
        self._split = {}                   # instruction address -> hook handle (code hooks that cut a block, see block_check)
        self.reset()

    def reset(self):
        """Reset values of Table 40: every register 0 (MPU disabled, every region disabled, RNR 0)."""
        self.ctrl = 0
        self.rnr = 0
        self.rbar = [0] * MPU_REGIONS
        self.rasr = [0] * MPU_REGIONS

    # ---------------------------------------------------------------- register interface
    def _note(self, off, rw, why):
        self.m._note(0xE0000000 + off, rw)
        self.m.log.append((self.m.cycles, f"MPU: {why}"))

    def _size_n(self, r):
        """log2(region size) of region r, or None when the region is disabled or its SIZE is below 4."""
        rasr = self.rasr[r]
        if not rasr & 1:
            return None
        size = (rasr >> 1) & 31
        return size + 1 if size >= 4 else None

    def _base(self, r, n):
        return 0 if n >= 32 else self.rbar[r] & ~((1 << n) - 1) & 0xFFFFFFFF

    def read(self, off, size):
        reg = off - MPU_BASE_OFF
        if reg == 0x00:                                # MPU_TYPER: DREGION 8, IREGION 0, SEPARATE 0
            return MPU_REGIONS << 8
        if reg == 0x04:                                # MPU_CTRL
            return self.ctrl
        if reg == 0x08:                                # MPU_RNR
            return self.rnr
        if reg == 0x0C:                                # MPU_RBAR: ADDR masked by the region size, REGION = RNR, VALID reads 0
            r = self.rnr
            if r >= MPU_REGIONS:
                self._note(off, 'R', f"RBAR read with RNR = {r} (regions 0..7 only, PM0056 4.2.7): UNPREDICTABLE")
                return 0
            n = self._size_n(r)
            addr = self.rbar[r] if n is None else self._base(r, n)
            return (addr & ~0x1F) | (r & 0xF)
        if reg in (0x10, 0x11, 0x12, 0x13):            # MPU_RASR, byte / halfword / word accesses (4.2.9)
            r = self.rnr
            if r >= MPU_REGIONS:
                self._note(off, 'R', f"RASR read with RNR = {r} (regions 0..7 only, PM0056 4.2.7): UNPREDICTABLE")
                return 0
            return (self.rasr[r] >> (8 * (reg - 0x10))) & ((1 << (8 * size)) - 1)
        self._note(off, 'R', "alias registers MPU_RBAR_A1..A3 / MPU_RASR_A1..A3 are not modelled (PM0056 does not define "
                             "which region number an alias addresses)")
        return 0

    def write(self, off, value, size):
        reg = off - MPU_BASE_OFF
        if 0x00 <= reg < 0x10 and size != 4:
            self._note(off, 'W', f"{size}-byte write to MPU register 0x{reg:02X}: PM0056 4.2.4 requires aligned words")
            return
        if reg == 0x00:                                # MPU_TYPER is read-only
            return
        if reg == 0x04:                                # MPU_CTRL: PRIVDEFENA 2, HFNMIENA 1, ENABLE 0
            self.ctrl = value & 7
            self._sync_hooks()
            return
        if reg == 0x08:                                # MPU_RNR: REGION[7:0]
            self.rnr = value & 0xFF
            return
        if reg == 0x0C:                                # MPU_RBAR
            if value & 0x10:                           # VALID: RNR <- REGION[3:0]
                self.rnr = value & 0xF
            r = self.rnr
            if r >= MPU_REGIONS:
                self._note(off, 'W', f"RBAR write with region {r} (regions 0..7 only, PM0056 4.2.7): UNPREDICTABLE, ignored")
                return
            self.rbar[r] = value & ~0x1F & 0xFFFFFFFF
            return
        if reg in (0x10, 0x11, 0x12, 0x13):            # MPU_RASR: bytes, halfwords or the word (4.2.9)
            r = self.rnr
            if r >= MPU_REGIONS:
                self._note(off, 'W', f"RASR write with RNR = {r} (regions 0..7 only, PM0056 4.2.7): UNPREDICTABLE, ignored")
                return
            shift = 8 * (reg - 0x10)
            lane = ((1 << (8 * size)) - 1) << shift
            new = (self.rasr[r] & ~lane) | ((value << shift) & lane)
            self.rasr[r] = new & MPU_RASR_MASK
            if new & 1:
                size_f = (new >> 1) & 31
                if size_f < 4:
                    self.m.log.append((self.m.cycles, f"MPU: region {r} SIZE = {size_f} is below 32 bytes: region ignored "
                                                      f"(PM0056 4.2.9)"))
                elif size_f < 7 and (new >> 8) & 0xFF:
                    self.m.log.append((self.m.cycles, f"MPU: region {r} of {1 << (size_f + 1)} bytes has SRD = "
                                                      f"0x{(new >> 8) & 0xFF:02X} (UNPREDICTABLE, PM0056 'Subregions'): SRD ignored"))
            self._sync_hooks()
            return
        self._note(off, 'W', "alias registers MPU_RBAR_A1..A3 / MPU_RASR_A1..A3 are not modelled (PM0056 does not define "
                             "which region number an alias addresses)")

    # ---------------------------------------------------------------- permission check
    @property
    def active(self):
        """True while the MPU checks accesses: ENABLE = 1, and not in a HardFault / NMI / FAULTMASK context unless
        HFNMIENA = 1 (PM0056 4.2.6)."""
        if not self.ctrl & 1:
            return False
        if self.ctrl & 2:
            return True
        m = self.m
        if m.active and m.active[-1] in (2, 3):
            return False
        return not (m.uc.reg_read(UC_ARM_REG_FAULTMASK) & 1)

    def privileged(self):
        """Handler mode is always privileged; Thread mode follows CONTROL.nPRIV (PM0056 2.1.3)."""
        uc = self.m.uc
        if uc.reg_read(UC_ARM_REG_XPSR) & 0x1FF:
            return True
        return not (uc.reg_read(UC_ARM_REG_CONTROL) & 1)

    def lookup(self, addr):
        """Highest-numbered enabled region that matches addr with its subregion enabled, or None (PM0056 4.2)."""
        for r in range(MPU_REGIONS - 1, -1, -1):
            n = self._size_n(r)
            if n is None:
                continue
            if n < 32 and (addr >> n) != (self._base(r, n) >> n):
                continue
            if n >= 8 and (self.rasr[r] >> (8 + ((addr >> (n - 3)) & 7))) & 1:
                continue                               # subregion disabled
            return r
        return None

    def permitted(self, addr, kind, priv):
        """kind 'R', 'W' or 'X'.  Table 37 for the AP field; XN for fetches; PRIVDEFENA background region."""
        if SCS_FIRST <= addr < SCS_END:
            return True
        r = self.lookup(addr)
        if r is None:
            return bool(self.ctrl & 4) and priv        # background region: the default map, privileged only
        rasr = self.rasr[r]
        ap = (rasr >> 24) & 7
        if kind == 'X' and rasr & (1 << 28):
            return False
        if ap == 0 or ap == 4:                         # no access; 100 is reserved / unpredictable: refused
            return False
        rw = ap in (1, 2, 3) if priv else ap == 3
        ro = ap in (5, 6, 7) if priv else ap in (2, 6, 7)
        return rw if kind == 'W' else (rw or ro)

    def violation(self, addr, size, kind):
        """Address of the first violating byte of an access of `size` bytes at addr, or None."""
        priv = self.privileged()
        end = addr + size
        a = addr
        while a < end:
            if not self.permitted(a, kind, priv):
                return a
            a = (a & ~(GRANULE - 1)) + GRANULE
        return None

    # ---------------------------------------------------------------- hooks
    def _read_can_fault(self):
        """True when a read can be denied under the present configuration: a region without read permission for
        privileged code (AP 000, 100) or for unprivileged code (AP 001, 101), or no background region (PRIVDEFENA = 0)
        so that an access outside every region faults (PM0056 4.2.6, Table 37).  Otherwise no read can violate and
        the memory-read hook is not needed."""
        if not self.ctrl & 4:
            return True
        return any(self._size_n(r) is not None and ((self.rasr[r] >> 24) & 7) in (0, 1, 4, 5) for r in range(MPU_REGIONS))

    def _sync_hooks(self):
        """Install the memory hooks the present configuration needs.  The write hook is installed with the first
        enabled MPU; the read hook only when a read can fault, because Unicorn 2.1.4 mishandles the IT state after a
        load that precedes an opposite-condition instruction of the same IT block when a memory-read hook exists
        (firmware/requests/W5_to_W10.md item 2; tools/check_image.py item 6).  Hooks stay installed; `active` gates them.
        The write hook also corrects the IT state Unicorn leaves after an access inside an IT block (_mem_hook)."""
        if not self.ctrl & 1:
            return
        uc = self.m.uc
        added = False
        if not self._wr_hook:
            uc.hook_add(UC_HOOK_MEM_WRITE, self._mem_hook)
            self._wr_hook = added = True
        if not self._rd_hook and self._read_can_fault():
            uc.hook_add(UC_HOOK_MEM_READ, self._mem_hook)
            self._rd_hook = added = True
        if added:
            # translated code keeps its TLB entries: flush so that the new hook sees accesses to pages already used
            uc.ctl(UC_CTL_TLB_FLUSH, UC_CTL_IO_WRITE)

    def _mem_hook(self, uc, access, addr, size, value, ud):
        # Unicorn 2.1.4 with a memory hook writes the IT state of an access inside an IT block to the CPU state and
        # leaves it there after the block has ended; the next translated block it looks up is then decoded as part of
        # an IT block (measured: `it hi; strhi ...; b loop` followed by `cmp r6, #0` at the loop head, the compare
        # skipped while "hi" was false, ff16_f_write of the production image).  The state written for this access
        # is the access's own (confirmed against the code, Machine.it_state_at); the CPU state is set to the state of
        # the next instruction (ITAdvance, ARMv7-M ARM A7.3.2), which a Cortex-M3 has after this instruction.
        x = uc.reg_read(UC_ARM_REG_XPSR)
        it = it_bits(x)
        if it:
            nxt = it_advance(self.m.it_state_at(uc.reg_read(UC_ARM_REG_PC), it))
            if nxt != it:
                uc.reg_write(UC_ARM_REG_XPSR, (x & ~XPSR_IT) | it_xpsr(nxt))
        if not self.active:
            return
        scs = self.scs
        write = access == UC_MEM_WRITE
        if scs.fault_pending:                          # a later beat of the instruction that was cancelled
            if write:
                scs._journal(addr, size)
            return
        bad = self.violation(addr, size, 'W' if write else 'R')
        if bad is None:
            return
        pc = uc.reg_read(UC_ARM_REG_PC)
        if write:
            scs._journal(addr, size)
        self.m.log.append((self.m.cycles, f"MPU: {'write' if write else 'read'} of {size} bytes at 0x{addr:08X} "
                                          f"violates the region map (pc 0x{pc:08X})"))
        scs.raise_memmanage(pc, MMFSR_DACCVIOL | MMFSR_MMARVALID, bad)
        uc.emu_stop()

    def block_check(self, addr, size):
        """Called by Machine._on_block before a translated block runs.  Returns True when the block must not run
        (fault raised and the CPU stopped, or the block was cut so that the fault is raised at the violating
        instruction)."""
        scs = self.scs
        if scs.fault_pending or not self.active:
            return False
        bad = self.violation(addr, size, 'X')
        if bad is None:
            return False
        uc = self.m.uc
        code = bytes(uc.mem_read(addr, size))
        first = None
        for i in self.m.cs.disasm(code, addr):         # first instruction that touches a violating byte
            if i.address + i.size > bad:
                first = i.address
                break
        if first is None:
            first = addr
        if first == addr:
            self.m.log.append((self.m.cycles, f"MPU: instruction fetch at 0x{addr:08X} violates the region map"))
            scs.raise_memmanage(addr, MMFSR_IACCVIOL, None)
            uc.emu_stop()
            return True
        if first in self._split:                       # already cut: the code hook raises the fault when it is reached
            return False
        self._split[first] = uc.hook_add(UC_HOOK_CODE, self._split_hook, begin=first, end=first)
        uc.ctl_remove_cache(addr, addr + size)         # retranslate: the instructions before `first` execute, then the
        self.m._resume = addr | 1                      # code hook faults; run the block again from its start
        uc.emu_stop()
        return True

    def _split_hook(self, uc, addr, size, ud):
        if self.scs.fault_pending or not self.active:
            return
        if self.violation(addr, size, 'X') is None:
            return
        self.m.log.append((self.m.cycles, f"MPU: instruction fetch at 0x{addr:08X} violates the region map"))
        self.scs.raise_memmanage(addr, MMFSR_IACCVIOL, None)
        uc.emu_stop()

    def frame_violation(self, sp, new_exc):
        """First violating byte of the 32-byte exception entry frame at sp, or None (MSTKERR, PM0056 4.4.10).
        The frame is written with the privilege of the interrupted code.  Whether the HardFault / NMI exemption of
        HFNMIENA (4.2.6) applies to the stacking for the entry into those handlers is not stated in PM0056; the model
        applies the state of the new context (MPU off for HardFault and NMI unless HFNMIENA = 1): UNPROVEN."""
        if not self.ctrl & 1:
            return None
        if new_exc in (2, 3) and not self.ctrl & 2:
            return None
        return self.violation(sp, 32, 'W')

    def frame_read_violation(self, sp):
        """First unreadable byte of the exception return frame at sp, or None (MUNSTKERR, not modelled)."""
        return self.violation(sp, 32, 'R') if self.active else None


class SCS:
    def __init__(self, m, n_irq=57):
        self.m = m
        m.nvic = self
        self.n_irq = n_irq
        self.dbgmcu_cr = 0                 # DBGMCU_CR: reset by power-on reset only, "not reset by system reset" (RM0038 30.16.3)
        self.fault_pending = False         # a synchronous fault raised by the MPU model, taken by Machine.run()
        self._fault = None                 # (exception number, return address) of that fault, None for a lockup
        self._undo = []                    # (address, old bytes) of SRAM stores cancelled by the MPU
        self.mpu = MPU(self)
        self.reset()

    def reset(self):
        """Reset of the core peripherals, run at power-on and by every system reset (Machine.reset() resets the CPU
        registers and the pending / active exception lists).  Reset values from PM0056: NVIC_ISERx / ICERx / ISPRx /
        IPRx / IABRx 0 (4.3.2 - 4.3.7, Table 44), SCB_VTOR 0 (4.4.4), SCB_AIRCR 0xFA050000 so PRIGROUP 0 (4.4.5), SCB_SCR 0
        (4.4.6), SCB_CCR 0x00000200 on STM32L (4.4.7), SCB_SHPR1..3 0 (4.4.8), STK_CTRL / STK_LOAD / STK_VAL 0
        (4.5.1 - 4.5.3).  A running SysTick is stopped: its scheduled event is voided through the token."""
        self.iser = [0, 0]                 # interrupt enable bits (IRQ0..63)
        self.ipr = bytearray(64)           # IRQ priorities (8-bit fields, top 4 bits used)
        self.shpr = bytearray(16)          # system handler priorities indexed by exception number
        self.vtor = 0
        self.aircr_prigroup = 0
        self.ccr = 0x200                   # reset value 0x0000 0200 on STM32L (PM0056): STKALIGN = 1
        self.scr = 0
        # SysTick
        self.st_ctrl = 0
        self.st_load = 0
        self.st_val = 0
        self.st_start = 0                  # cycle at which st_val was last loaded
        self._st_event = None
        # fault registers (PM0056 4.4.9 - 4.4.12): reset values 0 (MMFAR "undefined": 0 here)
        self.shcsr_en = 0                  # SHCSR bits 18:16 USGFAULTENA, BUSFAULTENA, MEMFAULTENA
        self.cfsr = 0                      # CFSR = UFSR:BFSR:MMFSR
        self.hfsr = 0
        self.mmfar = 0
        self.bfar = 0
        self.fault_pending = False
        self._fault = None
        self._undo = []
        self.m.mpu_hold = False
        self.mpu.reset()

    # ------------------------------------------------------------------ helpers used by the core
    def stkalign(self):
        return bool(self.ccr & 0x200)

    def enabled(self, exc):
        n = exc - 16
        return bool(self.iser[n >> 5] & (1 << (n & 31)))

    def priority(self, exc):
        if exc < 4:
            return {1: -3, 2: -2, 3: -1}.get(exc, -3)
        if exc < 16:
            return self.shpr[exc] & 0xF0
        return self.ipr[exc - 16] & 0xF0

    def _shcsr(self):
        """SCB_SHCSR (PM0056 4.4.9): stored enable bits 18:16, pending bits 15:12 from the pending set, active bits
        from the active stack (MEMFAULTACT 0, BUSFAULTACT 1, USGFAULTACT 3, SVCALLACT 7, PENDSVACT 10, SYSTICKACT 11)."""
        m = self.m
        v = self.shcsr_en
        for bit, exc in ((13, EXC_MEMMANAGE), (14, 5), (12, 6), (15, 11)):
            if exc in m.pending:
                v |= 1 << bit
        for bit, exc in ((0, EXC_MEMMANAGE), (1, 5), (3, 6), (7, 11), (10, 14), (11, 15)):
            if exc in m.active:
                v |= 1 << bit
        return v

    def irq(self, n):
        """Peripheral requests IRQ n."""
        self.m.set_pending(16 + n)

    # ------------------------------------------------------------------ synchronous faults (MPU, PM0056 2.4)
    def exec_priority(self):
        """Priority of the running context: the active handler, raised by FAULTMASK (-1), PRIMASK (0) and BASEPRI
        (PM0056 2.3.2).  256 = Thread mode with nothing masked."""
        uc = self.m.uc
        cur = self.priority(self.m.active[-1]) if self.m.active else 256
        if uc.reg_read(UC_ARM_REG_FAULTMASK) & 1:
            cur = min(cur, -1)
        if uc.reg_read(UC_ARM_REG_PRIMASK) & 1:
            cur = min(cur, 0)
        base = uc.reg_read(UC_ARM_REG_BASEPRI) & 0xFF
        if base:
            cur = min(cur, base)
        return cur

    def _journal(self, addr, size):
        """Remember the old content of an SRAM store the MPU is about to cancel (the hook runs before the store)."""
        if SRAM_BASE <= addr and addr + size <= SRAM_BASE + SRAM_SIZE:
            self._undo.append((addr, bytes(self.m.uc.mem_read(addr, size))))

    def raise_memmanage(self, pc, mmfsr, addr):
        """A MemManage fault at the instruction at pc (PM0056 4.4.10).  Sets the MMFSR bits (and MMFAR when addr is
        given), decides MemManage or escalation to HardFault (2.4.2) or lockup (2.4.4), mutes the MMIO callbacks so
        that the cancelled access has no side effect, and leaves the exception to Machine.run()."""
        self.cfsr |= mmfsr
        if addr is not None:
            self.mmfar = addr & 0xFFFFFFFF
        cur = self.exec_priority()
        if (self.shcsr_en & SHCSR_MEMFAULTENA) and self.priority(EXC_MEMMANAGE) < cur:
            exc = EXC_MEMMANAGE
        else:
            exc = EXC_HARDFAULT                        # handler disabled or not of higher priority: escalate
            self.hfsr |= HFSR_FORCED
            if cur <= -1:                              # HardFault / NMI / FAULTMASK context: lockup (2.4.4)
                self.m._stop_reason = (f"LOCKUP: MemManage fault (MMFSR 0x{self.cfsr & 0xFF:02X}) at pc 0x{pc:08X} "
                                       f"while running at priority {cur}")
                exc = None
        self._fault = None if exc is None else (exc, pc)
        self.fault_pending = True
        self.m.mpu_hold = True

    def take_fault(self):
        """Called by Machine.run() after the CPU stopped: cancel the access (undo an SRAM store, unmute the MMIO
        callbacks) and return (exception number, return address), or None after a lockup."""
        for addr, old in reversed(self._undo):
            self.m.uc.mem_write(addr, old)
        self._undo = []
        f, self._fault = self._fault, None
        self.fault_pending = False
        self.m.mpu_hold = False
        return f

    def stacking_fault(self, handler_pc, bad):
        """The exception entry frame could not be written (MSTKERR): the SP is adjusted by the caller, the frame is
        not written (PM0056 4.4.10).  The MemManage fault is raised at the first instruction of the new handler."""
        self.m.log.append((self.m.cycles, f"MPU: exception entry frame at 0x{bad:08X} violates the region map (MSTKERR)"))
        self.raise_memmanage(handler_pc, MMFSR_MSTKERR, None)

    # ------------------------------------------------------------------ SysTick
    def _st_reload_cycles(self):
        # CLKSOURCE (bit 2): 1 = core clock, 0 = core clock / 8 (STM32L1 external reference = HCLK/8)
        return (self.st_load + 1) * (1 if self.st_ctrl & 4 else 8)

    def _st_arm(self):
        if not (self.st_ctrl & 1) or self.st_load == 0:
            return
        token = object()
        self._st_event = token

        def fire():
            if self._st_event is not token:
                return
            self.st_ctrl |= 0x10000                    # COUNTFLAG
            self.st_start = self.m.cycles
            if self.st_ctrl & 2:
                self.m.set_pending(SYSTICK_EXC)
            self._st_arm()
        self.st_start = self.m.cycles
        self.m.schedule(self._st_reload_cycles(), fire)

    def _st_current(self):
        if not (self.st_ctrl & 1):
            return self.st_val
        div = 1 if self.st_ctrl & 4 else 8
        elapsed = (self.m.cycles - self.st_start) // div
        return max(0, self.st_load - elapsed) & 0xFFFFFF

    # ------------------------------------------------------------------ register access
    def read(self, off, size):
        if 0xE100 <= off < 0xE108:                     # NVIC_ISER0/1
            return self.iser[(off - 0xE100) >> 2]
        if 0xE180 <= off < 0xE188:                     # NVIC_ICER0/1
            return self.iser[(off - 0xE180) >> 2]
        if 0xE200 <= off < 0xE208:                     # NVIC_ISPR0/1
            w = (off - 0xE200) >> 2
            return sum(1 << (e - 16 - 32 * w) for e in self.m.pending if 16 + 32 * w <= e < 48 + 32 * w)
        if 0xE300 <= off < 0xE308:                     # NVIC_IABR0/1
            w = (off - 0xE300) >> 2
            return sum(1 << (e - 16 - 32 * w) for e in self.m.active if 16 + 32 * w <= e < 48 + 32 * w)
        if 0xE400 <= off < 0xE440:                     # NVIC_IPR
            i = off - 0xE400
            return int.from_bytes(self.ipr[i:i + size], 'little')
        if off == 0xE010:
            v = self.st_ctrl
            self.st_ctrl &= ~0x10000                   # COUNTFLAG clears on read
            return v
        if off == 0xE014:
            return self.st_load
        if off == 0xE018:
            return self._st_current()
        if off == 0xE01C:
            return 0x00002328                          # STK_CALIB reset value (PM0056 4.5.4): NOREF 0, SKEW 0, TENMS 0x2328
        if off == 0xED04:                              # ICSR
            v = (self.m.active[-1] & 0x1FF) if self.m.active else 0
            if self.m.pending:
                v |= (min(self.m.pending) & 0x1FF) << 12 | (1 << 22)
            return v
        if off == 0xED08:
            return self.vtor
        if off == 0xED0C:
            return 0xFA050000 | (self.aircr_prigroup << 8)
        if off == 0xED10:
            return self.scr
        if off == 0xED14:
            return self.ccr
        if 0xED18 <= off < 0xED24:                     # SHPR1..3 (exceptions 4..15)
            i = 4 + (off - 0xED18)
            return int.from_bytes(self.shpr[i:i + size], 'little')
        if off == 0xED24:                              # SHCSR (4.4.9): enables, pending and active bits of the faults
            return self._shcsr()
        if 0xED28 <= off < 0xED2C:                     # CFSR (4.4.10): MMFSR byte 0, BFSR byte 1, UFSR bytes 2..3
            return (self.cfsr >> (8 * (off - 0xED28))) & ((1 << (8 * size)) - 1)
        if off == 0xED2C:                              # HFSR (4.4.11)
            return self.hfsr
        if off == 0xED34:                              # MMFAR (4.4.12)
            return self.mmfar
        if off == 0xED38:                              # BFAR (4.4.13); no BusFault is generated by the model
            return self.bfar
        if 0xED90 <= off < 0xEDBC:                     # MPU (4.2)
            return self.mpu.read(off, size)
        if off == 0x42004:                             # DBGMCU_CR (0xE0042004)
            return self.dbgmcu_cr
        self.m._note(0xE0000000 + off, 'R')
        return 0

    def write(self, off, value, size):
        if 0xE100 <= off < 0xE108:
            self.iser[(off - 0xE100) >> 2] |= value
            return
        if 0xE180 <= off < 0xE188:
            self.iser[(off - 0xE180) >> 2] &= ~value
            return
        if 0xE200 <= off < 0xE208:
            w = (off - 0xE200) >> 2
            for b in range(32):
                if value & (1 << b):
                    self.m.set_pending(16 + 32 * w + b)
            return
        if 0xE280 <= off < 0xE288:
            w = (off - 0xE280) >> 2
            for b in range(32):
                if value & (1 << b):
                    self.m.pending.discard(16 + 32 * w + b)
            return
        if 0xE400 <= off < 0xE440:
            i = off - 0xE400
            self.ipr[i:i + size] = value.to_bytes(size, 'little')
            return
        if off == 0xE010:
            was = self.st_ctrl & 1
            self.st_ctrl = (self.st_ctrl & 0x10000) | (value & 7)
            if (value & 1) and not was:
                self._st_arm()
            if not (value & 1):
                self._st_event = None
            return
        if off == 0xE014:
            self.st_load = value & 0xFFFFFF
            return
        if off == 0xE018:                              # any write clears VAL and COUNTFLAG
            self.st_val = 0
            self.st_ctrl &= ~0x10000
            if self.st_ctrl & 1:
                self._st_event = None
                self._st_arm()
            return
        if off == 0xED04:                              # ICSR: PENDSVSET / PENDSTSET
            if value & (1 << 28):
                self.m.set_pending(PENDSV_EXC)
            if value & (1 << 26):
                self.m.set_pending(SYSTICK_EXC)
            return
        if off == 0xED08:
            self.vtor = value & 0x3FFFFF80
            self.m.log.append((self.m.cycles, f"VTOR = 0x{self.vtor:08X}"))
            return
        if off == 0xED0C:
            if (value >> 16) == 0x05FA:
                self.aircr_prigroup = (value >> 8) & 7
                if value & 4:                          # SYSRESETREQ
                    self.m.request_reset("AIRCR.SYSRESETREQ")
            return
        if off == 0xED10:
            self.scr = value
            return
        if off == 0xED14:
            self.ccr = value
            return
        if 0xED18 <= off < 0xED24:
            i = 4 + (off - 0xED18)
            self.shpr[i:i + size] = value.to_bytes(size, 'little')
            return
        if off == 0xED24:                              # SHCSR: the enable bits are stored, the pending bits set / clear
            self.shcsr_en = value & (SHCSR_MEMFAULTENA | SHCSR_BUSFAULTENA | SHCSR_USGFAULTENA)
            for bit, exc in ((13, EXC_MEMMANAGE), (14, 5), (12, 6), (15, 11)):
                if value & (1 << bit):
                    self.m.set_pending(exc)
                else:
                    self.m.pending.discard(exc)
            return
        if 0xED28 <= off < 0xED2C:                     # CFSR is write-one-to-clear (rc_w1, 4.4.10)
            self.cfsr &= ~((value & ((1 << (8 * size)) - 1)) << (8 * (off - 0xED28)))
            return
        if off == 0xED2C:                              # HFSR is write-one-to-clear (4.4.11)
            self.hfsr &= ~value
            return
        if off == 0xED34:
            self.mmfar = value
            return
        if off == 0xED38:
            self.bfar = value
            return
        if 0xED90 <= off < 0xEDBC:
            self.mpu.write(off, value, size)
            return
        if off == 0x42004:
            self.dbgmcu_cr = value
            return
        self.m._note(0xE0000000 + off, 'W')
