"""STM32L152ZD USART (RM0038 chapter 27) in asynchronous mode; instance USART2 at 0x4000 4400, NVIC IRQ 38.

Instances (RM0038 Table 5 memory map, Table 51 vector table Cat.4/5/6): USART1 0x4001 3800 IRQ 37, USART2 0x4000 4400
IRQ 38, USART3 0x4000 4800 IRQ 39.  Block size 0x400.

    USART(0x40004400, 38, "USART2")

Registers (RM0038 27.6, register map table 158, pages 736 - 746); all are accessed by halfwords or words, byte
accesses are merged here because the core delivers them:
    0x00 SR (27.6.1)   0x04 DR (27.6.2)   0x08 BRR (27.6.3)   0x0C CR1 (27.6.4)   0x10 CR2 (27.6.5)
    0x14 CR3 (27.6.6)  0x18 GTPR (27.6.7)
Offsets above 0x18 are not described and are routed to unmodelled().

SR reset value: the register description (27.6.1, page 736) prints "0x00C0 0000" but the register map (table 158) and
the bit descriptions place TXE and TC at bits 7 and 6; the model resets to 0x0000 00C0 (TXE = 1, TC = 1).

Clock (RM0038 27.3.4): the baud rate clock is the APB1 clock (PCLK1) for USART2 and USART3.  If the machine has an
attribute `rcc`, `rcc.pclk1_hz` (a property of the RCC model) is used and the cycle count of every frame is computed
from the clocks current at the moment the frame starts; otherwise the model assumes APB1 prescaler = 1 and AHB
prescaler = 1, so PCLK1 equals m.sysclk_hz.
Clock gate (RM0038 6.3.10 note, page 158): while `rcc.clock_enabled(name)` is false, register reads return 0 ("the returned
value is always 0x0") and writes are ignored (RM0038 does not say what a write does; ignoring it is the model's
choice) and the first such access is logged.  A frame already running is not affected by a later gating.

Baud rate (27.3.4 equations 1 and 2): baud = fCK / (8 * (2 - OVER8) * USARTDIV).  With OVER8 = 0 USARTDIV = BRR / 16,
so one bit lasts BRR PCLK1 clocks; with OVER8 = 1 USARTDIV = mantissa + fraction[2:0] / 8, one bit lasts
8 * mantissa + fraction[2:0] clocks (DIV_Fraction3 is ignored).  In LIN, smartcard and IrDA mode OVER8 is forced to
0 (CR1 OVER8 description).  BRR = 0 gives no baud clock: nothing is transmitted or received until BRR is written.
BRR written during a frame only applies to the next frame (27.3.4 note: it must not be changed during communication).

Frame (27.3.1, 27.3.2, CR1.M, CR2.STOP): 1 start bit, 8 or 9 bits (parity, if PCE = 1, replaces the MSB), 0.5, 1,
1.5 or 2 stop bits.  8N1 is 10 bit times.

Transmitter (27.3.2, figure 218)
- Setting TE (with UE = 1) sends an idle frame (one frame time) before the first data frame; a write to DR during it
  waits in TDR.
- A write to DR clears TXE.  With the shift register idle the data moves to it at once and TXE is set again
  immediately; otherwise it waits in TDR and TXE is set when the running frame ends and the data moves.  When a frame
  ends and TDR is empty TC is set.  The interrupt for TXE is therefore raised right after the write.
- TC is cleared by reading SR then writing DR, or by writing 0 to it.  Clearing TE aborts the frame in progress (data
  lost, 27.3.2 note); clearing UE lets the current frame finish.
- SBK sends a break (10 low bits, 11 if M = 1, 13 in LIN mode, then the stop bits) after the current frame; SBK is
  cleared at the start of the stop bit (27.3.2 break characters, 27.6.2 CR2.LINEN).
- on_tx: list of callbacks cb(word) called at the end of each data frame with the word that was on the wire (8 bits,
  9 bits if M = 1; with parity enabled the MSB is the parity bit).  on_break: callbacks cb() at the end of a break.

Receiver (27.3.3)
- rx_feed(data, pe=False, fe=False, noise=False): the board side delivers a byte, an iterable of ints or a bytes
  object.  The model puts them on the line back to back, as a remote USART with the same frame format would (parity
  generated from CR1.PCE/PS; pe inverts it, fe makes the stop bit wrong, noise sets the noise flag); the flags apply
  to every byte of the call.  Frames that start while RE = 0 or UE = 0 are lost.  Clearing RE aborts the frame in
  progress.
- RXNE is set when the stop bit has been sampled: half a bit after its start for 1 stop bit, one bit for 2 and 1.5
  stop bits, at the end of the data bits for 0.5 (27.3.3 configurable stop bits).  If RXNE is still set the new word
  is lost and ORE is set (RDR keeps the old word, 27.3.3 overrun error).  PE (27.6.1), FE and NF are set together with
  RXNE; a word that is overrun sets only ORE.  NF is not set when CR3.ONEBIT = 1.  IDLE is set when the line stays idle
  for a frame time after a received frame and RXNE has been set since the last IDLE (27.6.1 IDLE note).
- PE, FE, NF, ORE and IDLE are cleared by reading SR and then DR; PE also by SR then a write to DR.  RXNE is cleared by
  a read of DR or by writing 0.

Interrupt (27.4, table 156, figure 239): one line, the OR of TXE & TXEIE, TC & TCIE, (RXNE | ORE) & RXNEIE,
IDLE & IDLEIE, PE & PEIE, LBD & LBDIE, CTS & CTSIE and EIE & DMAR & (FE | ORE | NF).  It is pended again after a
handler returns while a source is still active.

Routed to unmodelled() because the machine has nothing to connect them to; the bits are stored and read back:
mute mode (RWU, WAKE), LIN break detection (LINEN, LBDIE), synchronous clock output (CLKEN), smartcard (SCEN, NACK),
IrDA (IREN, IRLP), single-wire half duplex (HDSEL), CTS/RTS hardware flow control (CTSE, RTSE) and the DMA enables
(DMAT, DMAR).
"""
from fractions import Fraction
from math import ceil

from .base import Periph

USART_SIZE = 0x400

SR, DR, BRR, CR1, CR2, CR3, GTPR = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18

# SR bits (27.6.1)
PE, FE, NF, ORE, IDLE, RXNE, TC, TXE, LBD, CTS = (1 << i for i in range(10))
SR_RESET = TXE | TC                     # register map table 158
SR_ERR = PE | FE | NF | ORE | IDLE      # cleared by "read SR then read DR"
SR_RC_W0 = TC | RXNE | LBD | CTS        # rc_w0 bits

# CR1 bits (27.6.4)
CR1_SBK, CR1_RWU, CR1_RE, CR1_TE, CR1_IDLEIE, CR1_RXNEIE, CR1_TCIE, CR1_TXEIE, CR1_PEIE = (1 << i for i in range(9))
CR1_PS, CR1_PCE, CR1_WAKE, CR1_M, CR1_UE, CR1_OVER8 = 1 << 9, 1 << 10, 1 << 11, 1 << 12, 1 << 13, 1 << 15
CR1_MASK = 0xBFFF
# CR2 bits (27.6.5)
CR2_LBDIE, CR2_CLKEN, CR2_LINEN = 1 << 6, 1 << 11, 1 << 14
CR2_MASK = 0x7F6F
# CR3 bits (27.6.6)
CR3_EIE, CR3_IREN, CR3_IRLP, CR3_HDSEL, CR3_NACK, CR3_SCEN, CR3_DMAR, CR3_DMAT = (1 << i for i in range(8))
CR3_RTSE, CR3_CTSE, CR3_CTSIE, CR3_ONEBIT = 1 << 8, 1 << 9, 1 << 10, 1 << 11
CR3_MASK = 0x0FFF
CR3_UNMODELLED = CR3_IREN | CR3_IRLP | CR3_HDSEL | CR3_NACK | CR3_SCEN | CR3_DMAR | CR3_DMAT | CR3_RTSE | CR3_CTSE

STOP_HALVES = {0: 2, 1: 1, 2: 4, 3: 3}          # CR2.STOP: 1, 0.5, 2, 1.5 stop bits, in half bits
STOP_SAMPLE_HALVES = {0: 1, 1: 0, 2: 2, 3: 2}   # stop bit sample point after the stop bit starts (27.3.3)


class _LevelIrq:
    """Level-sensitive interrupt line towards the NVIC.

    The line is raised with nvic.irq(); the exception is pended again after a handler returns while the line is still
    high (a flag the handler did not clear), which is how an NVIC treats a level interrupt.  The re-pend check polls
    with a back-off while the exception is pending but not served.
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

    def update(self):
        if self.owner.m is None or not self.line():
            return
        self._pend()
        if not self._armed:
            self._arm(self.MIN_POLL)

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


def _parity_bit(data, odd):
    """Parity bit for the data bits (CR1.PS: 0 even parity, 1 odd parity)."""
    p = bin(data).count("1") & 1
    return p ^ 1 if odd else p


class USART(Periph):
    SIZE = USART_SIZE

    def __init__(self, base=0x40004400, irq=38, name="USART2"):
        super().__init__()
        self.base = base
        self.irq = irq
        self.name = name
        self.on_tx = []                 # callbacks cb(word) at the end of every data frame
        self.on_break = []              # callbacks cb() at the end of every break
        self._line_irq = _LevelIrq(self, irq, self._line)
        self.reset()

    def reset(self):
        self.sr = SR_RESET              # table 158
        self.rdr = 0                    # DR reset value is undefined (27.6.2); the model starts with 0
        self.tdr = None                 # data waiting for the shift register (None = TDR empty)
        self.brr = 0                    # 27.6.3: reset 0
        self.cr1 = 0
        self.cr2 = 0
        self.cr3 = 0
        self.gtpr = 0
        self._sr_seen = 0               # SR value at the last SR read (for the read-SR-then-DR sequences)
        self._tx_busy = False           # shift register busy (data frame, idle preamble or break)
        self._tx_gen = 0
        self._tx_preamble = False       # TE was set: an idle frame precedes the next data
        self._rx_q = []                 # words fed by the board side that have not started yet
        self._rx_busy = False
        self._rx_gen = 0
        self._rx_idle_armed = False
        self._idle_gen = 0
        self._gate_logged = False

    # ------------------------------------------------------------------ configuration helpers
    def _forced_over8_zero(self):
        return bool(self.cr2 & CR2_LINEN or self.cr3 & (CR3_SCEN | CR3_IREN))

    def _bit_pclk(self):
        """PCLK1 clocks per bit time from BRR and OVER8 (27.3.4), None when BRR gives no baud clock."""
        if self.cr1 & CR1_OVER8 and not self._forced_over8_zero():
            d = ((self.brr >> 4) << 3) | (self.brr & 7)
        else:
            d = self.brr
        return d or None

    def _core_per_pclk(self):
        """Core cycles per PCLK1 clock, from the current clocks (read again for every delay)."""
        rcc = getattr(self.m, "rcc", None)
        if rcc is None:
            return Fraction(1)
        v = rcc.pclk1_hz                # property of the RCC model
        pclk = v() if callable(v) else v
        return Fraction(self.m.sysclk_hz) / Fraction(pclk)

    def _clk_on(self):
        """RCC_APB1ENR clock gate of this USART (always on when the machine has no RCC model)."""
        rcc = getattr(self.m, "rcc", None)
        if rcc is None:
            return True
        try:
            return rcc.clock_enabled(self.name)
        except KeyError:
            return True

    def _gated(self, off, rw):
        if not self._gate_logged:
            self._gate_logged = True
            self.m.log.append((self.m.cycles, f"{self.name} {rw} access at offset 0x{off:02X} with its clock disabled"))

    def _cycles(self, halves):
        """Core cycles for a duration of `halves` half bit times, None without a valid baud rate."""
        d = self._bit_pclk()
        if d is None:
            return None
        return Fraction(halves, 2) * d * self._core_per_pclk()

    def _nbits(self):
        return 9 if self.cr1 & CR1_M else 8

    def _frame_halves(self):
        return 2 * (1 + self._nbits()) + STOP_HALVES[(self.cr2 >> 12) & 3]

    def frame_cycles(self):
        """Duration of one data frame in core cycles (float), None without a valid baud rate."""
        c = self._cycles(self._frame_halves())
        return None if c is None else float(c)

    def _delay(self, cycles):
        return max(1, ceil(cycles))

    def _tx_active(self):
        return bool(self.cr1 & CR1_UE and self.cr1 & CR1_TE)

    def _rx_active(self):
        return bool(self.cr1 & CR1_UE and self.cr1 & CR1_RE)

    def _wire_word(self, data, invert_parity=False):
        """Word on the line for a character: parity replaces the MSB when PCE = 1 (27.6.2, 27.6.4 PCE)."""
        n = self._nbits()
        if self.cr1 & CR1_PCE:
            d = data & ((1 << (n - 1)) - 1)
            return d | ((_parity_bit(d, bool(self.cr1 & CR1_PS)) ^ int(invert_parity)) << (n - 1))
        return data & ((1 << n) - 1)

    # ------------------------------------------------------------------ interrupt
    def _line(self):
        sr, c1, c3 = self.sr, self.cr1, self.cr3
        return bool((sr & TXE and c1 & CR1_TXEIE) or (sr & TC and c1 & CR1_TCIE)
                    or (sr & (RXNE | ORE) and c1 & CR1_RXNEIE) or (sr & IDLE and c1 & CR1_IDLEIE)
                    or (sr & PE and c1 & CR1_PEIE) or (sr & LBD and self.cr2 & CR2_LBDIE)
                    or (sr & CTS and c3 & CR3_CTSIE) or (c3 & CR3_EIE and c3 & CR3_DMAR and sr & (FE | ORE | NF)))

    # ------------------------------------------------------------------ transmitter
    def _tx_next(self):
        """Shift register is free: start the idle preamble, a break or the data waiting in TDR."""
        if self._tx_busy or not self._tx_active():
            return
        if self._tx_preamble:
            c = self._cycles(self._frame_halves())
            if c is None:
                return
            self._tx_preamble = False
            self._tx_start("preamble", None, c)
        elif self.cr1 & CR1_SBK:
            low = 13 if self.cr2 & CR2_LINEN else (11 if self.cr1 & CR1_M else 10)
            c = self._cycles(2 * low + STOP_HALVES[(self.cr2 >> 12) & 3])
            if c is None:
                return
            self._tx_start("break", None, c, self._cycles(2 * low))
        elif self.tdr is not None:
            c = self._cycles(self._frame_halves())
            if c is None:
                return
            word = self._wire_word(self.tdr)
            self.tdr = None
            self.sr |= TXE                      # data moved to the shift register: TXE set at once (27.3.2)
            self._tx_start("data", word, c)

    def _tx_start(self, kind, word, cycles, sbk_clear=None):
        self._tx_busy = True
        self._tx_gen += 1
        gen = self._tx_gen
        if sbk_clear is not None:
            self.m.schedule(self._delay(sbk_clear), lambda: self._tx_sbk_done(gen))
        self.m.schedule(self._delay(cycles), lambda: self._tx_end(gen, kind, word))

    def _tx_sbk_done(self, gen):
        if gen == self._tx_gen:
            self.cr1 &= ~CR1_SBK                # cleared by hardware at the start of the stop bit of the break

    def _tx_end(self, gen, kind, word):
        if gen != self._tx_gen:
            return
        self._tx_busy = False
        if kind == "data":
            for cb in list(self.on_tx):
                cb(word)
            if self.tdr is None:
                self.sr |= TC                   # frame sent and TXE set (27.6.1 TC)
        elif kind == "break":
            self.cr1 &= ~CR1_SBK
            for cb in list(self.on_break):
                cb()
        self._tx_next()
        self._line_irq.update()

    # ------------------------------------------------------------------ receiver
    def rx_feed(self, data, pe=False, fe=False, noise=False):
        """Board side: put characters on the RX line (see the module docstring)."""
        if isinstance(data, int):
            data = [data]
        for b in data:
            self._rx_q.append((int(b), pe, fe, noise))
        self._rx_kick()

    def _rx_kick(self):
        while not self._rx_busy and self._rx_q:
            b, pe, fe, noise = self._rx_q.pop(0)
            if not self._rx_active():
                self.m.log.append((self.m.cycles, f"{self.name} rx byte 0x{b & 0x1FF:02X} lost: receiver off"))
                continue
            halves = self._frame_halves()
            sample = 2 * (1 + self._nbits()) + STOP_SAMPLE_HALVES[(self.cr2 >> 12) & 3]
            c_sample = self._cycles(sample)
            if c_sample is None:
                self.m.log.append((self.m.cycles, f"{self.name} rx byte 0x{b & 0x1FF:02X} lost: BRR = 0"))
                continue
            c_end = self._cycles(halves)
            self._rx_busy = True
            self._rx_gen += 1
            gen = self._rx_gen
            word = self._wire_word(b, pe)
            self.m.schedule(self._delay(c_sample), lambda: self._rx_sample(gen, word, fe, noise))
            self.m.schedule(self._delay(c_end), lambda: self._rx_end(gen))

    def _rx_sample(self, gen, word, fe, noise):
        if gen != self._rx_gen:
            return
        n = self._nbits()
        if self.sr & RXNE:
            self.sr |= ORE                      # 27.3.3: word lost, RDR keeps the previous one
        else:
            self.rdr = word & ((1 << n) - 1)
            self.sr |= RXNE
            if self.cr1 & CR1_PCE:
                low = word & ((1 << (n - 1)) - 1)
                if _parity_bit(low, bool(self.cr1 & CR1_PS)) != (word >> (n - 1)) & 1:
                    self.sr |= PE
            if fe:
                self.sr |= FE
            if noise and not self.cr3 & CR3_ONEBIT:
                self.sr |= NF
        self._rx_idle_armed = True
        self._line_irq.update()

    def _rx_end(self, gen):
        if gen != self._rx_gen:
            return
        self._rx_busy = False
        self._idle_gen += 1
        igen = self._idle_gen
        c = self._cycles(self._frame_halves())
        if c is not None:
            self.m.schedule(self._delay(c), lambda: self._rx_idle(igen))
        self._rx_kick()

    def _rx_idle(self, igen):
        if igen != self._idle_gen or self._rx_busy or self._rx_q or not self._rx_idle_armed:
            return
        if not self._rx_active():
            return
        self._rx_idle_armed = False
        self.sr |= IDLE
        self._line_irq.update()

    # ------------------------------------------------------------------ bus
    def read(self, off, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'R')
            return 0
        if not self._clk_on():
            self._gated(off, 'R')
            return 0
        if reg == SR:
            w = self.sr
            self._sr_seen = self.sr             # first half of the "read SR, then DR" sequences
        elif reg == DR:
            w = self.rdr                        # 27.6.2: RDR
            self.sr &= ~(RXNE | (self._sr_seen & SR_ERR))
            self._sr_seen = 0
            self._line_irq.update()
        elif reg == BRR:
            w = self.brr
        elif reg == CR1:
            w = self.cr1
        elif reg == CR2:
            w = self.cr2
        elif reg == CR3:
            w = self.cr3
        elif reg == GTPR:
            w = self.gtpr
        else:
            self.unmodelled(off, 'R')
            return 0
        return self.extract(w, off, size)

    def write(self, off, value, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'W')
            return
        if not self._clk_on():
            self._gated(off, 'W')
            return
        if reg == SR:
            self.sr &= self.merge(0xFFFFFFFF, off, value, size) | ~SR_RC_W0     # 27.6.1: rc_w0 bits only
        elif reg == DR:
            self.tdr = self.merge(0, off, value, size) & 0x1FF      # DR[8:0] (27.6.2)
            self.sr &= ~TXE                     # cleared by a write to DR (27.6.1 TXE)
            self.sr &= ~(self._sr_seen & (TC | PE))     # read SR then write DR clears TC (and PE)
            self._sr_seen = 0
            self._tx_next()
        elif reg == BRR:
            self.brr = self.merge(self.brr, off, value, size) & 0xFFFF
            self._tx_next()
        elif reg == CR1:
            self._write_cr1(self.merge(self.cr1, off, value, size) & CR1_MASK)
        elif reg == CR2:
            self.cr2 = self.merge(self.cr2, off, value, size) & CR2_MASK
            if self.cr2 & (CR2_LINEN | CR2_CLKEN | CR2_LBDIE):
                self.unmodelled(off, 'W')       # LIN break detection and the CK pin are not modelled
        elif reg == CR3:
            self.cr3 = self.merge(self.cr3, off, value, size) & CR3_MASK
            if self.cr3 & CR3_UNMODELLED:
                self.unmodelled(off, 'W')       # smartcard, IrDA, half duplex, flow control, DMA
        elif reg == GTPR:
            self.gtpr = self.merge(self.gtpr, off, value, size) & 0xFFFF
        else:
            self.unmodelled(off, 'W')
            return
        self._line_irq.update()

    def _write_cr1(self, new):
        old = self.cr1
        self.cr1 = new
        if new & (CR1_RWU | CR1_WAKE):
            self.unmodelled(CR1, 'W')           # mute mode / wake-up method not modelled
        tx_was, tx_now = bool(old & CR1_UE and old & CR1_TE), self._tx_active()
        if tx_now and not tx_was:
            self._tx_preamble = True            # TE set: idle frame before the first data (27.3.2)
        elif old & CR1_TE and not new & CR1_TE and self._tx_busy:
            self._tx_gen += 1                   # TE cleared during a frame: the frame is lost (27.3.2 note)
            self._tx_busy = False
        if not new & CR1_TE:
            self._tx_preamble = False
        if old & CR1_RE and not new & CR1_RE and self._rx_busy:
            self._rx_gen += 1                   # RE cleared during reception: the frame is aborted (27.3.3 note)
            self._rx_busy = False
        self._tx_next()
        self._rx_kick()
