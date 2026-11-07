"""STM32L152ZD general-purpose timers TIM2 .. TIM4 (RM0038 chapter 17), one class instantiated per timer.

Instances on this device (RM0038 Table 5, memory map): TIM2 0x4000 0000, TIM3 0x4000 0400, TIM4 0x4000 0800.
NVIC IRQ numbers (RM0038 Table 51, Cat.4/5/6 vector table): TIM2 = 28, TIM3 = 29, TIM4 = 30.
All three have a 16-bit counter (RM0038 17.2; only TIM5 is 32-bit, which this class does not cover).

    Tim(0x40000000, 28, "TIM2"),  Tim(0x40000400, 29, "TIM3")      Tim.SIZE = 0x400

Registers (RM0038 17.4, register map table 82, pages 420 - 441)
    0x00 CR1   0x04 CR2   0x08 SMCR   0x0C DIER   0x10 SR   0x14 EGR   0x18 CCMR1   0x1C CCMR2   0x20 CCER
    0x24 CNT   0x28 PSC   0x2C ARR    0x34 CCR1   0x38 CCR2 0x3C CCR3  0x40 CCR4    0x48 DCR     0x4C DMAR
    0x50 OR (TIM2_OR 17.4.19, TIM3_OR 17.4.20, bit 0 only)
Offsets 0x30, 0x44 and everything not listed are reserved and routed to unmodelled().

Clock (RM0038 6.2, page 130): the timer clock is the APB1 clock when the APB1 prescaler is 1 and twice the APB1
clock otherwise.  If the machine has an attribute `rcc`, `rcc.timclk1_hz()` is used (it applies that rule); otherwise
the model assumes APB1 prescaler = 1 and AHB prescaler = 1, so the timer clock equals m.sysclk_hz.  The ratio
timer clock / core clock is re-read at every access and every delay is computed from the current clock: when the
clock changes the elapsed time is accounted at the old rate at the next access or event; whoever changes the clock
can call clock_changed() right after the change to make that exact.
Clock gate (RM0038 6.3.10 note, page 158): while `rcc.clock_enabled(name)` is false, register reads return 0
("the returned value is always 0x0") and writes are ignored (RM0038 does not say what a write does; ignoring it is
the model's choice) and the first such access is logged.  The gate acts on register access only; a counter that
is already running keeps running if its clock is gated afterwards.

Counting (virtual time, no per-tick work)
- CNT is computed from the elapsed core cycles on every access; update events, compare events and the interrupt are
  found analytically and the interrupt is scheduled with m.schedule() at the exact cycle.
- CNT_EN is set one CK_INT period after CEN (17.3.1 "Note that the actual counter enable signal CNT_EN is set 1
  clock cycle after CEN") and the first CK_CNT edge follows one CK_INT period later (figure 104).  RM0038 only gives
  this as a figure, so the start is accurate to one timer clock.
- Prescaler: the counter is clocked at CK_PSC / (PSC + 1); a new PSC is taken at the next update event (17.4.11).
- Edge-aligned up (17.3.2 upcounting): CNT 0 .. ARR, update event (UEV) when it wraps to 0, so the period is
  (ARR + 1) counter clocks (figures 87 - 92).  Down: ARR .. 0, UEV at the reload (period ARR + 1).  Centre-aligned
  (CMS != 0): 0 .. ARR, UEV (overflow) on reaching ARR, ARR .. 0, UEV (underflow) on reaching 0, period 2 * ARR
  (figure 98: the sequence ... 01 00 01 ... 05 06 05 ...; the text "0 to ARR-1 ... overflow ... ARR down to 1 ...
  underflow" is the same sequence with the event at the following clock edge).  DIR is read only in centre mode.
- ARR = 0 blocks the counter (17.4.12).  ARPE = 0: ARR takes effect immediately; ARPE = 1: at the next UEV.
- UEV is suppressed by UDIS (17.4.1): no shadow register load and no UIF, the counter still wraps.  OPM clears CEN at
  the UEV.  URS and UG are handled as in 17.4.1 and 17.4.6.
- UIF is set at the UEV; CCxIF of an output-compare channel is set when CNT arrives at the compare value, with the
  centre-aligned filter of CMS (17.4.1) and, when CCRx is greater than ARR, at the overflow (up and centre) or
  underflow (down) event (17.4.5 CC1IF description).  CCxIF does not depend on CCxE or OCxM.
- Interrupts: one IRQ line, level = (SR & DIER & (UIF | CC1IF..CC4IF | TIF)); it is pended again after a handler
  returns while a flag is still set.

Input capture: there are no timer input pins in the machine.  `input_edge(ch)` (ch = 0..3) is the entry for the board
side: it is called once per active edge already selected by CCxP/CCxNP and filtered; the model applies CCxE, the input
capture prescaler ICxPSC, CCRx capture, CCxIF/CCxOF and the interrupt (17.4.5, 17.4.7).  CCxIF of an input channel is
cleared by reading CCRx (17.4.5).  EGR.CCxG captures the current counter (17.4.6).

Routed to unmodelled() because the machine has nothing to connect them to: slave modes, external clock modes and
ETR (SMCR.SMS != 0 or ECE = 1; the counter then has no clock), TRGO master modes (CR2.MMS != 0 or TI1S), all DMA
requests and the DMAR burst register, and output pin driving (CCxE = 1 on an output channel; OCxREF and the pin
level are not computed).  The register bits are stored and read back.
"""
from fractions import Fraction
from math import ceil

from .base import Periph

TIM_SIZE = 0x400

# Offsets (RM0038 table 82).
CR1, CR2, SMCR, DIER, SR, EGR, CCMR1, CCMR2, CCER = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20
CNT, PSC, ARR = 0x24, 0x28, 0x2C
CCR_OFF = (0x34, 0x38, 0x3C, 0x40)
DCR, DMAR, OR = 0x48, 0x4C, 0x50

CR1_MASK = 0x03FF                       # 17.4.1: bits 15:10 reserved
CR1_CEN, CR1_UDIS, CR1_URS, CR1_OPM, CR1_DIR, CR1_ARPE = 1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4, 1 << 7
CR2_MASK = 0x00F8                       # 17.4.2: TI1S, MMS[2:0], CCDS
SMCR_MASK = 0xFFFF                      # 17.4.3
DIER_MASK = 0x5F5F                      # 17.4.4: UIE, CC1IE..CC4IE, TIE, UDE, CC1DE..CC4DE, TDE
DIER_DMA = 0x5F00                       # DMA request enables (bits 14, 12:8)
SR_MASK = 0x1E5F                        # 17.4.5: UIF, CC1IF..CC4IF, TIF, CC1OF..CC4OF
SR_IRQ = 0x005F                         # flags that have an enable in DIER
CCER_MASK = 0xBBBB                      # 17.4.9: CCxE, CCxP, CCxNP of the four channels (bits 14, 10, 6, 2 reserved)
DCR_MASK = 0x1F1F                       # 17.4.17: DBL[4:0], DBA[4:0]
SR_UIF, SR_TIF = 1 << 0, 1 << 6
SR_CCIF = (1 << 1, 1 << 2, 1 << 3, 1 << 4)
SR_CCOF = (1 << 9, 1 << 10, 1 << 11, 1 << 12)
EGR_UG, EGR_TG = 1 << 0, 1 << 6
EGR_CCG = (1 << 1, 1 << 2, 1 << 3, 1 << 4)


class _LevelIrq:
    """Level-sensitive interrupt line towards the NVIC.

    The line is raised with nvic.irq(); the exception is pended again after a handler returns while the line is still
    high (a flag the handler did not clear), which is how an NVIC treats a level interrupt: at the exception return
    itself (Machine.exc_exit_hooks), so a handler that cannot clear its flag (the timer's clock is off: its SR write is
    ignored) is entered again at once and the interrupted code makes no progress, as on the chip.  Besides that, the
    re-pend check polls with a back-off while the exception is pending but not served.
    """
    MIN_POLL = 64                       # cycles
    MAX_POLL = 4096

    def __init__(self, owner, irq, line):
        self.owner, self.irq, self.line = owner, irq, line
        self._armed = False
        self._gen = 0

    def _pend(self):
        m = self.owner.m
        exc = 16 + self.irq
        if exc in m.pending or exc in m.active:
            return False
        if m.nvic is not None:
            m.nvic.irq(self.irq)
        else:
            m.set_pending(exc)
        return True

    def _on_exit(self, exc):
        if exc == 16 + self.irq and self.line():
            self._pend()

    def update(self):
        if self.owner.m is not None and not getattr(self, '_hooked', False):
            self.owner.m.exc_exit_hooks.append(self._on_exit)
            self._hooked = True
        if self.owner.m is None or not self.line():
            return
        self._pend()
        if not self._armed:
            self._arm(self.MIN_POLL)

    def reset(self):
        """Cancel the re-pend poll (peripheral reset)."""
        self._armed = False
        self._gen += 1

    def _arm(self, interval):
        self._armed = True
        self._gen += 1
        gen = self._gen
        self.owner.m.schedule(interval, lambda: self._beat(gen, interval))

    def _beat(self, gen, interval):
        if gen != self._gen:
            return
        self._armed = False
        if not self.line():
            return
        if 16 + self.irq in self.owner.m.active or self._pend():
            nxt = self.MIN_POLL
        else:
            nxt = min(self.MAX_POLL, interval * 2)
        self._arm(nxt)


class _State:
    """Counter state that evolves with time: counter, direction, prescaler phase and the active (shadow) registers."""
    __slots__ = ("cnt", "dir", "p", "psc", "arr", "ccr", "stopped")

    def __init__(self):
        self.cnt = 0
        self.dir = 0                    # 0 counting up, 1 counting down
        self.p = 0                      # CK_PSC clocks already counted in the current prescaler period
        self.psc = 0                    # active prescaler value
        self.arr = 0xFFFF               # active auto-reload value
        self.ccr = [0, 0, 0, 0]         # active compare values
        self.stopped = False            # one-pulse mode stopped the counter

    def copy(self):
        c = _State()
        c.cnt, c.dir, c.p, c.psc, c.arr, c.stopped = self.cnt, self.dir, self.p, self.psc, self.arr, self.stopped
        c.ccr = list(self.ccr)
        return c


class _Events:
    """Flags raised while the counter advanced."""
    __slots__ = ("uif", "cc")

    def __init__(self):
        self.uif = False
        self.cc = [False, False, False, False]

    def merge(self, other):
        self.uif = self.uif or other.uif
        for i in range(4):
            self.cc[i] = self.cc[i] or other.cc[i]


class Tim(Periph):
    SIZE = TIM_SIZE
    OR_MASK = 1                         # TIM2_OR / TIM3_OR: ITR1_RMP only (17.4.19, 17.4.20)

    def __init__(self, base, irq, name="TIM", has_or=True, apb=1):
        """has_or: TIM2 and TIM3 have the option register at 0x50 (17.4.19, 17.4.20); pass False for TIM4.
        apb: the bus whose timer clock drives the counter (1: TIM2..TIM7; 2: TIM9..TIM11, 6.2 / 6.3.9)."""
        super().__init__()
        self.base = base
        self.irq = irq
        self.name = name
        self.has_or = has_or
        self.apb = apb
        self._line_irq = _LevelIrq(self, irq, self._line)
        self.reset()

    # ------------------------------------------------------------------ state
    def reset(self):
        self.cr1 = 0                    # 17.4.1: reset 0 (DIR is kept in st.dir)
        self.cr2 = 0                    # 17.4.2
        self.smcr = 0                   # 17.4.3
        self.dier = 0                   # 17.4.4
        self.sr = 0                     # 17.4.5
        self.ccmr = [0, 0]              # 17.4.7, 17.4.8
        self.ccer = 0                   # 17.4.9
        self.psc = 0                    # 17.4.11: reset 0
        self.arr = 0xFFFF               # 17.4.12: reset 0xFFFF
        self.ccr = [0, 0, 0, 0]         # 17.4.13 .. 17.4.16: reset 0 (preload / captured value)
        self.dcr = 0                    # 17.4.17
        self.opt = 0                    # 17.4.19, 17.4.20
        self.st = _State()
        self._icpsc = [0, 0, 0, 0]      # input capture prescaler event counters
        self._ratio = None              # timer clock / core clock, as Fraction
        self.origin = 0                 # core cycle at which CNT_EN rose
        self.ticks_done = 0             # CK_PSC clocks consumed since origin
        self._gen = getattr(self, '_gen', 0) + 1    # invalidates scheduled events (never reset to 0: old events would match)
        self._line_irq.reset()
        self._gate_logged = False

    # ------------------------------------------------------------------ small helpers
    @property
    def cms(self):
        return (self.cr1 >> 5) & 3

    def _is_out(self, ch):
        return ((self.ccmr[ch >> 1] >> (8 * (ch & 1))) & 3) == 0

    def _ccer_en(self, ch):
        return (self.ccer >> (4 * ch)) & 1

    def _ratio_now(self):
        """Timer clock divided by core clock (see module docstring); read again whenever it is needed."""
        rcc = getattr(self.m, "rcc", None)
        if rcc is None:
            tim = self.m.sysclk_hz
        else:
            tim = rcc.timclk2_hz() if self.apb == 2 else rcc.timclk1_hz()
        return Fraction(tim) / Fraction(self.m.sysclk_hz)

    def _clk_on(self):
        """RCC_APB1ENR clock gate of this timer (always on when the machine has no RCC model)."""
        rcc = getattr(self.m, "rcc", None)
        if rcc is None:
            return True
        try:
            return rcc.clock_enabled(self.name)
        except KeyError:
            return True

    @property
    def running(self):
        """The counter is clocked from CK_INT: CEN set, slave mode off, external clock mode 2 off."""
        return bool(self.cr1 & CR1_CEN) and (self.smcr & 7) == 0 and not (self.smcr & (1 << 14))

    def _follow(self):
        """Active registers that are not preloaded follow their write value (ARPE = 0, OCxPE = 0)."""
        if not self.cr1 & CR1_ARPE:
            self.st.arr = self.arr
        for ch in range(4):
            if self._is_out(ch) and not (self.ccmr[ch >> 1] >> (8 * (ch & 1) + 3)) & 1:
                self.st.ccr[ch] = self.ccr[ch]

    # ------------------------------------------------------------------ counter model
    def _ticks_to_uev(self, st):
        """Counter clocks until the next update event, None if the counter is blocked (ARR = 0)."""
        if st.arr == 0:
            return None
        if self.cms:
            return max(1, st.arr - st.cnt) if st.dir == 0 else max(1, st.cnt)
        if st.dir == 0:
            return max(1, st.arr - st.cnt + 1)
        return st.cnt + 1

    def _cc_allowed(self, up):
        cms = self.cms
        return cms == 0 or cms == 3 or (cms == 2 and up) or (cms == 1 and not up)

    def _matches(self, st, c):
        """Compare matches (offset in counter clocks, channel) among the c clocks that precede the next UEV."""
        out = []
        if c <= 0:
            return out
        up = st.dir == 0
        if not self._cc_allowed(up):
            return out
        for ch in range(4):
            if not self._is_out(ch):
                continue
            v = st.ccr[ch]
            if up:
                if st.cnt < v <= st.cnt + c:
                    out.append((v - st.cnt, ch))
            elif st.cnt - c <= v < st.cnt:
                out.append((st.cnt - v, ch))
        return out

    def _move(self, st, c, ev):
        if c <= 0:
            return
        for _, ch in self._matches(st, c):
            ev.cc[ch] = True
        st.cnt += c if st.dir == 0 else -c

    def _apply_uev(self, st, ev):
        """Counter clock that raises the update event (prescaler phase is 0 here)."""
        udis = bool(self.cr1 & CR1_UDIS)
        if not udis:
            st.psc = self.psc                   # 17.3.2: buffers reloaded at the UEV
            st.arr = self.arr
            for ch in range(4):
                if self._is_out(ch):
                    st.ccr[ch] = self.ccr[ch]
            ev.uif = True
        center = self.cms != 0
        if center:
            overflow = st.dir == 0
            if overflow:
                st.cnt, st.dir, arrival_up = st.arr, 1, True
            else:
                st.cnt, st.dir, arrival_up = 0, 0, False
        else:
            arrival_up = st.dir == 0
            st.cnt = 0 if st.dir == 0 else st.arr
            overflow = True
        for ch in range(4):
            if not self._is_out(ch):
                continue
            v = st.ccr[ch]
            hit = v == st.cnt and self._cc_allowed(arrival_up)
            if v > st.arr and overflow:         # 17.4.5 CC1IF: CCRx greater than ARR -> flag at overflow/underflow
                hit = True
            if hit:
                ev.cc[ch] = True
        if self.cr1 & CR1_OPM and not udis:
            st.stopped = True

    def _cycle_ticks(self, st):
        """CK_PSC clocks of one full repeating cycle starting right after a UEV (prescaler phase 0)."""
        m = self._ticks_to_uev(st)
        if m is None:
            return None
        d = st.psc + 1
        return (2 * st.arr * d) if self.cms else (m * d)

    def _advance(self, st, n, ev, skip=True):
        """Advance the state by n CK_PSC clocks, collecting the raised flags in ev."""
        while n > 0 and not st.stopped:
            m = self._ticks_to_uev(st)
            if m is None:
                return
            d = st.psc + 1
            need = m * d - st.p
            if n < need:
                total = st.p + n
                st.p = total % d
                self._move(st, total // d, ev)
                return
            self._move(st, m - 1, ev)
            n -= need
            st.p = 0
            self._apply_uev(st, ev)
            if skip and n > 0 and not st.stopped:
                cyc = self._cycle_ticks(st)
                if cyc and n >= cyc:            # identical cycles: account the flags of one, skip the rest
                    tmp, tmp_ev = st.copy(), _Events()
                    self._advance(tmp, cyc, tmp_ev, skip=False)
                    ev.merge(tmp_ev)
                    n %= cyc

    def _next_irq_ticks(self):
        """CK_PSC clocks from now to the next event that has its DIER enable bit set, or None."""
        ie_u = bool(self.dier & 1)
        ie_cc = [bool(self.dier & (2 << ch)) for ch in range(4)]
        if not (ie_u or any(ie_cc)):
            return None
        st = self.st.copy()
        consumed = 0
        for _ in range(3):              # current partial period, first full period, repeating period
            if st.stopped:
                return None
            m = self._ticks_to_uev(st)
            if m is None:
                return None
            d = st.psc + 1
            best = None
            for off, ch in self._matches(st, m - 1):
                if ie_cc[ch] and (best is None or off < best):
                    best = off
            if best is not None:
                return consumed + best * d - st.p
            need = m * d - st.p
            ev = _Events()
            self._apply_uev(st, ev)
            consumed += need
            st.p = 0
            if (ev.uif and ie_u) or any(ev.cc[ch] and ie_cc[ch] for ch in range(4)):
                return consumed
        return None

    # ------------------------------------------------------------------ time handling
    def _sync_core(self):
        if not self.running or self.st.stopped:
            return
        now = self.m.cycles
        if now <= self.origin:
            return
        avail = int((now - self.origin) * self._ratio)
        n = avail - self.ticks_done
        if n <= 0:
            return
        self.ticks_done = avail
        ev = _Events()
        self._advance(self.st, n, ev)
        if self.st.stopped:                     # one-pulse mode: CEN cleared at the UEV (17.4.1 OPM)
            self.cr1 &= ~CR1_CEN
        self._apply_events(ev)

    def _sync(self):
        """Bring the counter up to m.cycles."""
        r = self._ratio_now()
        if self._ratio is None:
            self._ratio = r
        elif r != self._ratio:                  # clock changed: account the past at the old rate
            self._sync_core()
            self._ratio = r
            self.origin = self.m.cycles
            self.ticks_done = 0
        self._sync_core()

    def _apply_events(self, ev):
        if ev.uif:
            self.sr |= SR_UIF
        for ch in range(4):
            if ev.cc[ch]:
                self.sr |= SR_CCIF[ch]

    def _start(self):
        """CEN 0 -> 1: CNT_EN rises one CK_INT period later (17.3.1)."""
        self._ratio = self._ratio_now()
        self.origin = self.m.cycles + ceil(1 / self._ratio)
        self.ticks_done = 0
        self.st.stopped = False

    def _reschedule(self):
        self._gen += 1
        if not self.running or self.st.stopped:
            return
        t = self._next_irq_ticks()
        if t is None:
            return
        target = self.origin + ceil(Fraction(self.ticks_done + t) / self._ratio)
        gen = self._gen
        self.m.schedule(max(1, target - self.m.cycles), lambda: self._fire(gen))

    def _fire(self, gen):
        if gen != self._gen:
            return
        self._sync()
        self._line_irq.update()
        self._reschedule()

    def clock_changed(self):
        """Call after the timer clock or m.sysclk_hz changed (the RCC model)."""
        self._sync()
        self._reschedule()

    def _line(self):
        return bool(self.sr & self.dier & SR_IRQ)

    def _changed(self):
        self._reschedule()
        self._line_irq.update()

    # ------------------------------------------------------------------ events by software / board
    def _capture(self, ch, prescale):
        if (self.ccmr[ch >> 1] >> (8 * (ch & 1))) & 3 == 0 or not self._ccer_en(ch):
            return
        if prescale:                            # 17.4.7 ICxPSC: capture once every 1, 2, 4 or 8 events
            self._icpsc[ch] += 1
            if self._icpsc[ch] < (1 << ((self.ccmr[ch >> 1] >> (8 * (ch & 1) + 2)) & 3)):
                return
            self._icpsc[ch] = 0
        self._set_capture(ch)

    def _set_capture(self, ch):
        self.ccr[ch] = self.st.cnt
        if self.sr & SR_CCIF[ch]:
            self.sr |= SR_CCOF[ch]              # 17.4.5 CC1OF: captured while CC1IF was already set
        self.sr |= SR_CCIF[ch]

    def input_edge(self, ch):
        """Board side: one active edge (already polarity-selected and filtered) on the input of channel ch (0..3)."""
        self._sync()
        self._capture(ch, True)
        self._changed()

    def _ug(self):
        """EGR.UG (17.4.6): re-initialise the counter and the prescaler counter, update the registers."""
        udis = bool(self.cr1 & CR1_UDIS)
        st = self.st
        if not udis:
            st.psc, st.arr = self.psc, self.arr
            for ch in range(4):
                if self._is_out(ch):
                    st.ccr[ch] = self.ccr[ch]
        st.p = 0
        if self.cms:
            st.cnt, st.dir = 0, 0
        else:
            st.cnt = 0 if st.dir == 0 else st.arr
        if not udis and not self.cr1 & CR1_URS:
            self.sr |= SR_UIF

    # ------------------------------------------------------------------ bus
    def _gated(self, off, rw):
        if not self._gate_logged:
            self._gate_logged = True
            self.m.log.append((self.m.cycles, f"{self.name} {rw} access at offset 0x{off:02X} with its clock disabled"))

    def read(self, off, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'R')
            return 0
        if not self._clk_on():
            self._gated(off, 'R')
            return 0
        self._sync()
        if reg == CR1:
            w = (self.cr1 & ~CR1_DIR) | (CR1_DIR if self.st.dir else 0) if self.cms else self.cr1   # 17.4.1
        elif reg == CR2:
            w = self.cr2
        elif reg == SMCR:
            w = self.smcr
        elif reg == DIER:
            w = self.dier
        elif reg == SR:
            w = self.sr
        elif reg == EGR:
            w = 0                               # 17.4.6: write-only
        elif reg == CCMR1:
            w = self.ccmr[0]
        elif reg == CCMR2:
            w = self.ccmr[1]
        elif reg == CCER:
            w = self.ccer
        elif reg == CNT:
            w = self.st.cnt                     # 17.4.10
        elif reg == PSC:
            w = self.psc                        # 17.4.11
        elif reg == ARR:
            w = self.arr                        # 17.4.12: preload register
        elif reg in CCR_OFF:
            ch = CCR_OFF.index(reg)
            w = self.ccr[ch]                    # 17.4.13 .. 17.4.16
            if not self._is_out(ch):
                self.sr &= ~SR_CCIF[ch]         # 17.4.5: input CCxIF is cleared by reading CCRx
        elif reg == DCR:
            w = self.dcr
        elif reg == OR and self.has_or:
            w = self.opt
        else:                                   # DMAR and reserved offsets
            self.unmodelled(off, 'R')
            return 0
        self._line_irq.update()
        return self.extract(w, off, size)

    def write(self, off, value, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'W')
            return
        if not self._clk_on():
            self._gated(off, 'W')
            return
        self._sync()
        was_running = self.running
        if reg == CR1:
            self._write_cr1(self.merge(self.cr1, off, value, size) & CR1_MASK)
        elif reg == CR2:
            self.cr2 = self.merge(self.cr2, off, value, size) & CR2_MASK
            if self.cr2 & 0xF0:
                self.unmodelled(off, 'W')       # MMS / TI1S: TRGO and TI1 selection have no connection here
        elif reg == SMCR:
            self.smcr = self.merge(self.smcr, off, value, size) & SMCR_MASK
            if (self.smcr & 7) or (self.smcr & (1 << 14)):
                self.unmodelled(off, 'W')       # slave / external clock modes: no trigger or ETR source
        elif reg == DIER:
            self.dier = self.merge(self.dier, off, value, size) & DIER_MASK
            if self.dier & DIER_DMA:
                self.unmodelled(off, 'W')       # DMA requests are not modelled
        elif reg == SR:
            self.sr &= self.merge(0xFFFFFFFF, off, value, size)     # 17.4.5: rc_w0, reserved bits read 0
        elif reg == EGR:
            self._write_egr(self.merge(0, off, value, size))
        elif reg in (CCMR1, CCMR2):
            self._write_ccmr(reg == CCMR2, self.merge(self.ccmr[reg == CCMR2], off, value, size))
        elif reg == CCER:
            new = self.merge(self.ccer, off, value, size) & CCER_MASK
            for ch in range(4):
                if (new >> (4 * ch)) & 1 and not (self.ccer >> (4 * ch)) & 1:
                    if self._is_out(ch):
                        self.unmodelled(off, 'W')   # CCxE = 1 on an output: pin driving is not modelled
                    else:
                        self._icpsc[ch] = 0
                elif not (new >> (4 * ch)) & 1:
                    self._icpsc[ch] = 0         # 17.4.7: the capture prescaler is reset when CCxE = 0
            self.ccer = new
        elif reg == CNT:
            self.st.cnt = self.merge(self.st.cnt, off, value, size) & 0xFFFF
        elif reg == PSC:
            self.psc = self.merge(self.psc, off, value, size) & 0xFFFF      # takes effect at the next UEV
        elif reg == ARR:
            self.arr = self.merge(self.arr, off, value, size) & 0xFFFF
            self._follow()
        elif reg in CCR_OFF:
            ch = CCR_OFF.index(reg)
            if self._is_out(ch):                # input channels: CCRx is read only (17.4.13)
                self.ccr[ch] = self.merge(self.ccr[ch], off, value, size) & 0xFFFF
                self._follow()
        elif reg == DCR:
            self.dcr = self.merge(self.dcr, off, value, size) & DCR_MASK
        elif reg == OR and self.has_or:
            self.opt = self.merge(self.opt, off, value, size) & self.OR_MASK
        else:                                   # DMAR and reserved offsets
            self.unmodelled(off, 'W')
            return
        if self.running and not was_running:    # CEN set, or slave/external clock mode left: CNT_EN rises (17.3.1)
            self._start()
        self._changed()

    def _write_cr1(self, new):
        old = self.cr1
        if (new >> 5) & 3:                      # DIR is read only in centre-aligned mode
            new = (new & ~CR1_DIR) | (old & CR1_DIR)
        else:
            self.st.dir = (new >> 4) & 1
        self.cr1 = new
        self._follow()

    def _write_ccmr(self, hi, new):
        old = self.ccmr[hi]
        for half in range(2):                   # 17.4.7: CCxS is writable only while CCxE = 0
            ch = 2 * hi + half
            if self._ccer_en(ch):
                sh = 8 * half
                new = (new & ~(3 << sh)) | (old & (3 << sh))
        self.ccmr[hi] = new & 0xFFFF
        self._follow()

    def _write_egr(self, w):
        if w & EGR_UG:
            self._ug()
        for ch in range(4):
            if w & EGR_CCG[ch]:
                if self._is_out(ch):
                    self.sr |= SR_CCIF[ch]
                else:
                    self._set_capture(ch)       # 17.4.6: input: capture the counter, CCxOF if CCxIF was set
        if w & EGR_TG:
            self.sr |= SR_TIF


class Tim11(Tim):
    """TIM11 (RM0038 18.5, APB2, base 0x40011000) with the channel-1 input remap of TIM11_OR (18.5.13): TI1_RMP = 10
    puts HSE_RTC (HSE / RTCPRE, RCC.hse_rtc_hz) on channel 1 "for measurement purposes" (6.2.14).  The firmware uses it
    only that way (sys/msical.s, IMP-46): counter on the APB2 timer clock, input capture 1 with prescaler.  The register
    subset TIM11 shares with TIM2..TIM4 (CR1, DIER, SR, EGR, CCMR1, CCER, CNT, PSC, ARR, CCR1, OR at the same offsets,
    18.5.14) is the Tim model; the edges of HSE_RTC are delivered as input edges of channel 1 at their real times
    (Machine.elapsed_s), so the captured counts follow the ratio of the timer clock to the HSE crystal.  TI1_RMP = 01
    (MSI on channel 1) and the GPIO input are not modelled (logged when selected).
    Observed on a meter (2026-11-07, firmware F-1.17 test image), not stated in RM0038: with RTCSEL = LSI the timer counted
    but captured nothing (SR UIF, never CC1IF); with RTCSEL = HSE (and RTCEN = 1) it captured.  The model therefore
    delivers HSE_RTC edges only while RTCSEL = HSE."""

    OR_TI1_RMP = 3
    OR_MASK = 0x0F                      # 18.5.13: TI1_RMP[1:0], ETR_RMP, TI1_RMP_RI

    def __init__(self):
        super().__init__(0x40011000, 27, 'TIM11', has_or=True, apb=2)

    def reset(self):
        super().reset()
        self._edge_gen = getattr(self, '_edge_gen', 0) + 1
        self._edge_on = False

    def _rtc_source(self):
        """HSE_RTC frequency reaching channel 1, 0 when it does not (remap not 10, clock gate off, HSE not ready)."""
        rcc = getattr(self.m, 'rcc', None)
        if rcc is None or (self.opt & self.OR_TI1_RMP) != 2 or not self._clk_on() or rcc.rtcsel != 3:
            return 0
        return rcc.hse_rtc_hz

    def _edges_wanted(self):
        return bool(self._rtc_source()) and bool(self.cr1 & 1) and self._ccer_en(0) and not self._is_out(0)

    def _edges_update(self):
        """Start or stop the HSE_RTC edge train after a register write."""
        if self._edges_wanted() and not self._edge_on:
            self._edge_on = True
            self._edge_gen += 1
            self._edge_t0 = self.m.elapsed_s()
            self._edge_k = 0
            self._edge_next(self._edge_gen)
        elif not self._edges_wanted() and self._edge_on:
            self._edge_on = False
            self._edge_gen += 1

    def _edge_next(self, gen):
        f = self._rtc_source()
        if gen != self._edge_gen or not f:
            self._edge_on = False
            return
        # only the edge that completes the input capture prescaler (IC1PSC: every 1, 2, 4 or 8 edges) captures; the edges
        # before it only count, so the event is placed on that edge and the count is completed there (_edge)
        div = 1 << ((self.ccmr[0] >> 2) & 3)
        self._edge_k += max(1, div - self._icpsc[0])
        due = self._edge_t0 + Fraction(self._edge_k, f)
        delay = (due - self.m.elapsed_s()) * self.m.sysclk_hz
        cycles = max(1, -(-delay.numerator // delay.denominator)) if delay > 0 else 1
        due = self.m.cycles + cycles
        self.m.schedule(cycles, lambda: self._edge(gen, due))

    def _edge(self, gen, due):
        if gen != self._edge_gen or not self._edges_wanted():
            self._edge_on = False
            return
        # The machine runs an event at the first basic block start at or after its due cycle (core.py schedule), so
        # the counter has moved on by the cycles since `due`.  The hardware latches CNT at the edge (18.3.5): the
        # capture takes the counter value of the due cycle.
        self._late = max(0, self.m.cycles - due)
        self._icpsc[0] = (1 << ((self.ccmr[0] >> 2) & 3)) - 1      # the skipped edges of the prescaler (_edge_next)
        self.input_edge(0)
        self._late = 0
        self._edge_next(gen)

    def _set_capture(self, ch):
        super()._set_capture(ch)
        late = getattr(self, '_late', 0)
        if late and self.running and self.st.psc == 0:
            self.ccr[ch] = (self.ccr[ch] - int(late * self._ratio_now())) % (self.st.arr + 1)

    def write(self, off, value, size):
        super().write(off, value, size)
        if (off & ~3) == OR and ((self.opt & self.OR_TI1_RMP) in (1, 3) or (self.opt & ~self.OR_TI1_RMP)):
            self.unmodelled(off, 'W')           # MSI / GPIO on channel 1, RI and ETR remaps: not modelled
        self._edges_update()
