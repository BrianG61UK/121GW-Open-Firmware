"""System control space: NVIC, SysTick, SCB, DBGMCU (PM0056 / RM0038).

Offsets are relative to 0xE0000000.  Exception numbers: 15 = SysTick, 16+n = IRQn.
"""
import struct

SYSTICK_EXC = 15
PENDSV_EXC = 14


class SCS:
    def __init__(self, m, n_irq=57):
        self.m = m
        m.nvic = self
        self.n_irq = n_irq
        self.iser = [0, 0]                 # interrupt enable bits (IRQ0..63)
        self.ipr = bytearray(64)           # IRQ priorities (8-bit fields, top 4 bits used)
        self.shpr = bytearray(16)          # system handler priorities indexed by exception number
        self.vtor = 0
        self.aircr_prigroup = 0
        self.ccr = 0x200                   # reset value 0x0000 0200 on STM32L (PM0056): STKALIGN = 1
        self.scr = 0
        self.dbgmcu_cr = 0
        # SysTick
        self.st_ctrl = 0
        self.st_load = 0
        self.st_val = 0
        self.st_start = 0                  # cycle at which st_val was last loaded
        self._st_event = None

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

    def irq(self, n):
        """Peripheral requests IRQ n."""
        self.m.set_pending(16 + n)

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
            return 0                                   # SysTick CALIB: TENMS not provided
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
        if off == 0x42004:
            self.dbgmcu_cr = value
            return
        self.m._note(0xE0000000 + off, 'W')
