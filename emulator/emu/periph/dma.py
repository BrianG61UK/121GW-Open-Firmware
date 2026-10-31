"""STM32L152 DMA controllers DMA1 (7 channels, 0x4002 6000) and DMA2 (5 channels, 0x4002 6400), RM0038 chapter 11.

Instances (RM0038 table 5 memory map, vector table 51 for Cat.4):
    DMA("DMA1", 0x40026000, 7, 11)     NVIC IRQ 11..17 = DMA1_Channel1..7
    DMA("DMA2", 0x40026400, 5, 50)     NVIC IRQ 50..54 = DMA2_CH1..5
Register block 0x400.  Registers (RM0038 11.4, register map 11.4.7 table 57), byte, halfword and word accesses:
    0x00 DMA_ISR (11.4.1, read only)       GIFx = bit 4(x-1), TCIFx = +1, HTIFx = +2, TEIFx = +3
    0x04 DMA_IFCR (11.4.2, write only)     CGIFx / CTCIFx / CHTIFx / CTEIFx, same bit positions; reads give 0
    channel x (1..N), base 0x08 + 0x14 * (x - 1):
        +0x00 DMA_CCRx (11.4.3)   +0x04 DMA_CNDTRx (11.4.4)   +0x08 DMA_CPARx (11.4.5)   +0x0C DMA_CMARx (11.4.6)
        +0x10 reserved (word between the channels, RM0038 table 57)
Everything else (channels 6 and 7 of DMA2, the reserved words) is reported through unmodelled().
Clock gate: RCC_AHBENR DMA1EN / DMA2EN (RM0038 6.3.8).  While it is off reads return 0 and writes are ignored, and the first such
access is logged (same policy as the USART model; RM0038 6.3.10 note: "the returned value is always 0x0").  RCC_AHBRSTR
DMAxRST resets the controller (rcc.reset_hooks).

Behaviour
- Channel configuration (11.3.3, 11.4.3): EN, TCIE, HTIE, TEIE, DIR (0 read from peripheral, 1 read from memory), CIRC, PINC,
  MINC, PSIZE, MSIZE, PL, MEM2MEM.  CCR bits 31:15 are reserved and read 0.  PSIZE / MSIZE = 11b is "reserved" in RM0038: the
  model treats it as 32 bit and logs it (RM0038 gives no behaviour).
- DMA_CNDTRx can only be written while the channel is disabled (11.4.4); a write while EN = 1 is ignored.  DMA_CPARx / DMA_CMARx
  "must not be written when the channel is enabled" (11.4.5, 11.4.6): RM0038 does not define the effect, the model ignores such
  a write and logs it.  While the channel is enabled CNDTR reads the number of items still to transfer (11.4.4).
- Enabling a channel (EN 0 -> 1) loads the internal current addresses from CPAR / CMAR; they are not readable (11.3.3).  Disabling
  does not reset the registers (11.3.3 note).  With NDT = 0 no transfer is served whether the channel is enabled or not (11.4.4).
- In non-circular mode EN stays 1 after the last transfer and no request is served any more (11.3.3: "the DMA channel must be
  disabled" to load a new count).  In circular mode NDT and the addresses are reloaded after the last transfer (11.3.3).
- Transfer: one request moves one data item: read from the source with its size, write to the destination with its size, source
  and destination addresses incremented by their size when PINC / MINC are set, NDT decremented (11.3.1).  Different sizes
  follow table 53 of 11.3.4: a wider destination is zero extended, a narrower one takes the low bytes.  Addresses are aligned
  down to the item size (11.4.5 / 11.4.6 "access is automatically aligned").
- Flags (11.4.1): HTIF when half of NDT has been transferred (the model sets it after ceil(NDT/2) items, RM0038 does not
  say how an odd count rounds), TCIF when NDT reaches 0, GIF with any of them (cleared by CGIF only, as written in 11.4.1 /
  11.4.2), TEIF on a bus error.  A bus error (11.3.5: access to a reserved address, here: an unmapped address, the core private
  peripheral bus, or a write to flash / EEPROM / system memory, which are read-only for the DMA, 11.2 "Access to ... Flash as
  source") clears EN, sets TEIF and GIF.  Addresses inside the 1 MiB peripheral window are served by the peripheral models; an
  address that no model covers (a reserved one in RM0038 terms) is reported as UNMODELLED by the machine and does not raise TEIF.
- Interrupt (11.3.6, table 54): channel IRQ = TCIF & TCIE | HTIF & HTIE | TEIF & TEIE, level sensitive.
- Requests: MEM2MEM channels request as soon as they are enabled (11.3.3).  Other channels need a hardware request.  A peripheral
  model connects with attach_request(channel, level_fn) (level_fn() -> bool is the live request level) and calls poke() whenever
  the level may have risen.  SDIO is channel 4 of DMA2 (RM0038 table 56); no other peripheral model in this emulator drives a
  request (USART DMAT / DMAR remain unmodelled in their own model), so channels without a connection only run memory to memory.
- Arbitration (11.3.2): software priority PL (very high > high > medium > low), equal priority: lowest channel number first.
  One data item is served per arbitration round.
Timing: RM0038 gives no cycle count for a DMA item.  The model needs XFER_CYCLES = 4 core cycles per item (one AHB read and one
AHB write, not shared with the core); this is a model parameter and unproven.
"""
from unicorn import UcError

from .base import Periph
from .irqline import LevelIrq
from ..core import (PERIPH_BASE, PERIPH_SIZE, SRAM_BASE, SRAM_SIZE, SCS_BASE, SCS_SIZE)

DMA_SIZE = 0x400
ISR, IFCR = 0x00, 0x04
CH0, CH_STRIDE = 0x08, 0x14
R_CCR, R_CNDTR, R_CPAR, R_CMAR = 0x00, 0x04, 0x08, 0x0C

# DMA_CCRx bits (11.4.3)
EN, TCIE, HTIE, TEIE, DIR, CIRC, PINC, MINC = (1 << i for i in range(8))
MEM2MEM = 1 << 14
CCR_MASK = 0x7FFF

# per-channel flag bits inside the 4-bit group of DMA_ISR (11.4.1)
GIF, TCIF, HTIF, TEIF = 1, 2, 4, 8

XFER_CYCLES = 4
GATE_POLL_CYCLES = 2000             # recheck interval for work that waits for the AHB clock gate to be switched on again


class _BusError(Exception):
    pass


class _Channel:
    def __init__(self):
        self.ccr = 0
        self.cndtr = 0
        self.cpar = 0
        self.cmar = 0
        self.ndt_init = 0           # NDT latched when the channel was enabled (circular reload, half transfer point)
        self.done = 0               # items transferred since enable / reload
        self.cur_p = 0              # internal current peripheral / memory addresses (not readable by software)
        self.cur_m = 0
        self.flags = 0              # GIF | TCIF | HTIF | TEIF
        self.req = None             # level_fn() -> bool, hardware request


class DMA(Periph):
    SIZE = DMA_SIZE

    def __init__(self, name, base, channels, irq_base):
        super().__init__()
        self.name = name
        self.base = base
        self.n = channels
        self.irq_base = irq_base
        self.ch = [_Channel() for _ in range(channels)]
        self._irqs = [LevelIrq(self, irq_base + i, lambda i=i: self._line(i)) for i in range(channels)]
        self._ev = False            # a service event is scheduled
        self._gen = 0
        self._noted = set()

    # ------------------------------------------------------------------ board / peripheral interface
    def attach_request(self, channel, level_fn):
        """Connect a peripheral's DMA request line (channel 1-based) to this controller."""
        self.ch[channel - 1].req = level_fn

    def poke(self):
        """A peripheral request level may have changed: schedule service if some channel now has work."""
        if self.m is not None and self._pick() is not None:
            self._kick()

    def reset(self):
        """Peripheral reset (RCC_AHBRSTR DMAxRST) or power-on: every register back to 0, flags cleared, transfers aborted."""
        for c in self.ch:
            req = c.req
            c.__init__()
            c.req = req
        self._gen += 1
        self._ev = False
        for q in self._irqs:
            q.reset()

    def _log_once(self, key, text):
        if key not in self._noted:
            self._noted.add(key)
            self.m.log.append((self.m.cycles, f"{self.name}: {text}"))

    # ------------------------------------------------------------------ interrupt
    def _line(self, i):
        c = self.ch[i]
        f = c.flags
        return bool((f & TCIF and c.ccr & TCIE) or (f & HTIF and c.ccr & HTIE) or (f & TEIF and c.ccr & TEIE))

    def _irq_update(self, i):
        self._irqs[i].update()

    # ------------------------------------------------------------------ clock gate
    def _clk_on(self):
        rcc = getattr(self.m, "rcc", None)
        return True if rcc is None else rcc.clock_enabled(self.name)

    def _gated(self, off, rw):
        if self._clk_on():
            return False
        self._log_once("gate", f"{'read' if rw == 'R' else 'write'} at offset 0x{off:03X} while RCC_AHBENR.{self.name}EN = 0 "
                               "(reads give 0, writes are ignored, RM0038 6.3.10 note)")
        return True

    # ------------------------------------------------------------------ registers
    def _locate(self, reg):
        """reg (word aligned offset) -> (channel index, register) or None."""
        if reg < CH0:
            return None
        i, r = divmod(reg - CH0, CH_STRIDE)
        if i >= self.n or r not in (R_CCR, R_CNDTR, R_CPAR, R_CMAR):
            return None
        return i, r

    def _isr(self):
        v = 0
        for i, c in enumerate(self.ch):
            v |= c.flags << (4 * i)
        return v

    def _reg_read(self, reg):
        if reg == ISR:
            return self._isr()
        if reg == IFCR:
            return 0                                    # write only (11.4.2)
        loc = self._locate(reg)
        if loc is None:
            return None
        c, r = self.ch[loc[0]], loc[1]
        return {R_CCR: c.ccr, R_CNDTR: c.cndtr, R_CPAR: c.cpar, R_CMAR: c.cmar}[r]

    def read(self, off, size):
        if self._gated(off, 'R'):
            return 0
        val = self._reg_read(off & ~3)
        if val is None:
            self.unmodelled(off, 'R')
            return 0
        return self.extract(val, off, size)

    def write(self, off, value, size):
        if self._gated(off, 'W'):
            return
        reg = off & ~3
        if reg == ISR:
            return                                      # read only: no effect (11.4.1)
        if reg == IFCR:
            self._ifcr(value << (8 * (off & 3)) & 0xFFFFFFFF if size < 4 else value)
            return
        loc = self._locate(reg)
        if loc is None:
            self.unmodelled(off, 'W')
            return
        i, r = loc
        c = self.ch[i]
        new = self.merge(self._reg_read(reg), off, value, size)
        if r == R_CCR:
            self._w_ccr(i, new & CCR_MASK)
        elif r == R_CNDTR:
            if c.ccr & EN:
                self._log_once(f"ndtr{i}", f"channel {i + 1}: write to CNDTR while EN = 1 ignored (11.4.4)")
            else:
                c.cndtr = new & 0xFFFF
        else:
            if c.ccr & EN:
                self._log_once(f"par{i}{r}", f"channel {i + 1}: write to {'CPAR' if r == R_CPAR else 'CMAR'} while EN = 1 ignored "
                                              "(must not be written, 11.4.5 / 11.4.6)")
            elif r == R_CPAR:
                c.cpar = new
            else:
                c.cmar = new

    def _ifcr(self, value):
        for i, c in enumerate(self.ch):
            nib = (value >> (4 * i)) & 0xF
            if nib & GIF:
                c.flags = 0                             # CGIF clears GIF, TEIF, HTIF and TCIF (11.4.2)
            else:
                c.flags &= ~(nib & (TCIF | HTIF | TEIF))
            self._irq_update(i)

    def _w_ccr(self, i, new):
        c = self.ch[i]
        old, c.ccr = c.ccr, new
        for fld in ((new >> 8) & 3, (new >> 10) & 3):
            if fld == 3:
                self._log_once(f"size{i}", f"channel {i + 1}: PSIZE / MSIZE = 11b is reserved (RM0038 11.4.3); treated as 32 bit")
        if new & EN and not old & EN:
            c.ndt_init = c.cndtr
            c.done = 0
            c.cur_p = c.cpar
            c.cur_m = c.cmar
            if new & MEM2MEM and new & CIRC:
                self._log_once(f"m2mcirc{i}", f"channel {i + 1}: MEM2MEM together with CIRC is not allowed (11.3.3)")
            self._kick()
        self._irq_update(i)

    # ------------------------------------------------------------------ transfers
    def _active(self, c):
        """Channel that can serve a transfer now."""
        if not (c.ccr & EN) or c.cndtr == 0:
            return False
        if c.ccr & MEM2MEM:
            return True
        return c.req is not None and bool(c.req())

    def _pick(self):
        best = None
        for i, c in enumerate(self.ch):
            if self._active(c):
                pl = (c.ccr >> 12) & 3
                if best is None or pl > best[0]:
                    best = (pl, i)
        return None if best is None else best[1]

    def _kick(self, delay=XFER_CYCLES):
        if self._ev:
            return
        self._ev = True
        gen = self._gen
        self.m.schedule(delay, lambda: self._service(gen))

    def _service(self, gen):
        if gen != self._gen:
            return
        self._ev = False
        if not self._clk_on():                          # DMAxEN switched off: the transfers wait for it to come back
            if self._pick() is not None:
                self._kick(GATE_POLL_CYCLES)
            return
        i = self._pick()
        if i is None:
            return
        self._xfer(i)
        if self._pick() is not None:
            self._kick()

    def _bus_read(self, addr, size):
        m = self.m
        if PERIPH_BASE <= addr < PERIPH_BASE + PERIPH_SIZE:
            return m._pread(None, addr - PERIPH_BASE, size, None)
        if SCS_BASE <= addr < SCS_BASE + SCS_SIZE:
            raise _BusError()
        try:
            return int.from_bytes(m.uc.mem_read(addr, size), "little")
        except UcError:
            raise _BusError()

    def _bus_write(self, addr, size, value):
        m = self.m
        if PERIPH_BASE <= addr < PERIPH_BASE + PERIPH_SIZE:
            m._pwrite(None, addr - PERIPH_BASE, size, value, None)
            return
        if not (SRAM_BASE <= addr and addr + size <= SRAM_BASE + SRAM_SIZE):
            raise _BusError()                           # flash / EEPROM / system memory are read-only for the DMA, others unmapped
        m.uc.mem_write(addr, value.to_bytes(size, "little"))

    def _xfer(self, i):
        c = self.ch[i]
        ccr = c.ccr
        psz = 4 if (ccr >> 8) & 3 == 3 else 1 << ((ccr >> 8) & 3)
        msz = 4 if (ccr >> 10) & 3 == 3 else 1 << ((ccr >> 10) & 3)
        pa, ma = c.cur_p & ~(psz - 1), c.cur_m & ~(msz - 1)
        try:
            if ccr & DIR:                               # read from memory, write to the peripheral address
                v = self._bus_read(ma, msz)
                self._bus_write(pa, psz, v & ((1 << (8 * psz)) - 1))
            else:                                       # read from the peripheral address, write to memory
                v = self._bus_read(pa, psz)
                self._bus_write(ma, msz, v & ((1 << (8 * msz)) - 1))
        except _BusError:
            c.ccr &= ~EN                                # 11.3.5: the faulty channel is disabled by hardware
            c.flags |= TEIF | GIF
            self.m.log.append((self.m.cycles, f"{self.name} channel {i + 1}: transfer error "
                                              f"(peripheral side 0x{pa:08X}, memory side 0x{ma:08X})"))
            self._irq_update(i)
            return
        if ccr & PINC:
            c.cur_p += psz
        if ccr & MINC:
            c.cur_m += msz
        c.cndtr -= 1
        c.done += 1
        if c.done == (c.ndt_init + 1) // 2:
            c.flags |= HTIF | GIF
        if c.cndtr == 0:
            c.flags |= TCIF | GIF
            if ccr & CIRC:                              # 11.3.3 circular mode: reload NDT and the addresses
                c.cndtr = c.ndt_init
                c.cur_p, c.cur_m = c.cpar, c.cmar
                c.done = 0
        self._irq_update(i)
