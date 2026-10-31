"""STM32L152ZD LCD controller, block at 0x4000 2400 (RM0038 chapter 16, Table 5 memory map), NVIC IRQ 24.

Registers (RM0038 16.5, register map table 78, pages 375 - 382), accessed by words in hardware; byte and halfword
accesses are merged here because the core delivers them (bit-band writes arrive as byte accesses):
    0x00 CR   0x04 FCR   0x08 SR   0x0C CLR   0x14..0x50 RAM0..RAM15 (COM0 low/high, COM1 low/high ... COM7 low/high)
Offsets 0x10 and 0x54 and above are not described in RM0038 and are routed to unmodelled().

Frame timing (RM0038 16.4.2, page 359)
    f_ckdiv  = f_LCDCLK / (2**PS * (16 + DIV))
    f_frame  = f_ckdiv * duty            -> the frame period is  ncom * 2**PS * (16 + DIV) / f_LCDCLK
where ncom is 1, 2, 3, 4 or 8 for static, 1/2, 1/3, 1/4 and 1/8 duty (CR.DUTY).  The table 74 examples of RM0038
(for instance 32.768 kHz, PS=4, DIV=1, 1/4 duty -> 30.12 Hz) are reproduced by this formula.  LCDCLK is RTCCLK
(RM0038 16.4.1 note).  If the machine has an attribute `rcc`, `rcc.rtcclk_hz` (RTCSEL selection) is read every time a
frame is timed; a value of 0 means no clock is selected, the frame generator then waits (polling every 4096 core
cycles) and FCRSF is not set, as on the device.  Without an RCC model `lcdclk_hz` is used; this board uses the LSI
of about 37 kHz (RM0038 16.4.2), so it defaults to 37000.  The frame period is converted to core cycles with
m.sysclk_hz read at the start of each frame; a change of m.sysclk_hz in the middle of a frame lengthens or shortens
that one frame (the RCC model does not notify the LCD).
Clock gate (RM0038 6.3.10 note, page 158): while `rcc.clock_enabled('LCD')` is false, register reads return 0
("the returned value is always 0x0") and writes are ignored (RM0038 does not say what a write does; ignoring it is the
model's choice) and the first such access is logged.  DEAD (dead time, 16.4.6) is held inside the frame period: RM0038 states that it reduces the contrast
"without modifying the frame rate", so it is stored but does not change any timing.

Double buffering (RM0038 16.4.7, page 370, and LCD_SR bit descriptions, page 378)
- The application writes LCD_RAM; setting SR.UDR requests the transfer of LCD_RAM into the second buffer
  LCD_DISPLAY.  The transfer is done at the beginning of the next frame; until then UDR stays set and LCD_RAM is write
  protected.  When it completes UDR is cleared by hardware and UDD is set (interrupt if FCR.UDDIE).
- The update does not happen while the display is disabled (UDR = 1 and UDD = 0 until LCDEN = 1).
- With the display enabled only the LCD_DISPLAY locations of the active commons are updated (for duty 1/2: COM0 and
  COM1); when UDR was requested with the display disabled all 16 locations are updated (SR.UDR note).
- `display` is the list of the 16 LCD_DISPLAY words currently shown, `enabled` is LCDEN and ENS, and `on_update` is a
  list of callbacks; each is called as cb(display_copy) after every display update.

Enable / disable (RM0038 16.5.1 LCDEN, 16.5.3 ENS and RDY)
- LCDEN 0 -> 1: ENS becomes 1 immediately.  The step-up converter then starts; RDY is set by hardware when it is
  ready (only with the internal source, VSEL = 0; with VSEL = 1 the converter is off and RDY stays 0).  The first
  frame starts at that moment.
- LCDEN 1 -> 0: the display turns off at the beginning of the next frame; ENS (and RDY) become 0 there.
- BIAS, DUTY, VSEL and MUX_SEG are write protected while ENS = 1 (note under 16.5.1).
- FCR is applied at the beginning of the next frame (note under 16.5.2); FCRSF is cleared by a write to FCR and set
  when the new value has been applied.

Values RM0038 does not give, chosen here and stated explicitly
- Settling time of the step-up converter until RDY: RM0038 and the device datasheet (table 73) give no number; the
  model uses one frame period of the programmed configuration.
- Synchronisation of FCR into the LCDCLK domain while the controller is disabled: RM0038 gives no number; the model
  uses two LCDCLK periods.
- Which frame boundary performs the update: RM0038 says "the beginning of the next frame" and "in the worst case one
  odd and one even frame"; the model updates at the next frame boundary (odd or even).
- SOF is set at every frame boundary (RM0038: "at the beginning of a new frame").

Not modelled (no effect on what the firmware can observe through registers): contrast control CC, pulse-on PON,
high drive HD, blink (BLINK, BLINKF), MUX_SEG pin remapping.  The bits are stored and read back; the UI that draws
`display` must apply MUX_SEG and blink itself if it wants them.
"""
from fractions import Fraction
from math import ceil

from .base import Periph

LCD_BASE = 0x40002400
LCD_SIZE = 0x400
LCD_IRQ = 24                            # RM0038 table 51 (Cat.4/5/6): position 24 = LCD global interrupt

# Offsets (RM0038 table 78).
CR, FCR, SR, CLR = 0x00, 0x04, 0x08, 0x0C
RAM_FIRST, RAM_LAST = 0x14, 0x50        # 16 words, RM0038 16.5.5
N_RAM = 16

CR_LCDEN = 1 << 0                       # RM0038 16.5.1
CR_VSEL = 1 << 1
CR_PROTECTED = 0xFE                     # VSEL, DUTY, BIAS, MUX_SEG: write protected while ENS = 1
CR_MASK = 0xFF                          # bits 31:8 reserved
FCR_MASK = 0x03FFFFFB                   # RM0038 16.5.2: bits 31:26 and bit 2 reserved
FCR_UDDIE = 1 << 3
FCR_SOFIE = 1 << 1
SR_ENS, SR_SOF, SR_UDR, SR_UDD, SR_RDY, SR_FCRSF = 1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4, 1 << 5   # RM0038 16.5.3
CLR_SOFC, CLR_UDDC = 1 << 1, 1 << 3     # RM0038 16.5.4

DUTY_NCOM = {0: 1, 1: 2, 2: 3, 3: 4, 4: 8}      # RM0038 16.5.1 DUTY[2:0]; 101..111 are forbidden
FCR_SYNC_LCDCLK = 2                     # assumed FCR synchronisation delay in LCDCLK periods (see module docstring)
CLOCK_POLL = 4096                       # core cycles between checks while LCDCLK is absent


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


class LCD(Periph):
    name = "LCD"
    base = LCD_BASE
    SIZE = LCD_SIZE
    IRQ = LCD_IRQ

    def __init__(self, lcdclk_hz=37000):
        super().__init__()
        self.lcdclk_hz = lcdclk_hz              # LCDCLK when the machine has no RCC model (LSI, RM0038 16.4.2)
        self.on_update = []                     # callbacks cb(display_copy) after each LCD_DISPLAY update
        self._irq = _LevelIrq(self, LCD_IRQ, self._line)
        self.reset()

    # ------------------------------------------------------------------ state
    def reset(self):
        self.cr = 0                             # RM0038 16.5.1: reset 0
        self.fcr = 0                            # RM0038 16.5.2: reset 0
        self.fcrsf = True                       # RM0038 16.5.3: SR reset value 0x0000 0020 -> FCRSF = 1
        self.rdy = False
        self.udd = False
        self.udr = False
        self.sof = False
        self.ens = False
        self.ram = [0] * N_RAM                  # RM0038 16.5.5: reset 0
        self.display = [0] * N_RAM              # second buffer LCD_DISPLAY (16.4.7)
        self._udr_full = False                  # UDR requested while disabled: update all locations
        self._fcr_applied = 0                   # PS/DIV value in use by the frame generator
        self._duty_ncom = 4
        # invalidate the scheduled frame / FCR synchronisation events of the previous life: the counters only ever
        # increase, a reset to 0 would make an old event match again
        self._gen = getattr(self, '_gen', 0) + 1
        self._fcr_gen = getattr(self, '_fcr_gen', 0) + 1
        self._irq.reset()
        self._t_next = Fraction(0)              # core cycle (exact) of the next frame boundary
        self._gate_logged = False

    @property
    def enabled(self):
        """True when the display is on: LCDEN set and ENS set (what the UI should show)."""
        return bool(self.cr & CR_LCDEN) and self.ens

    # ------------------------------------------------------------------ timing
    def _ratio(self):
        """LCDCLK periods per frame for the configuration in use: ncom * 2**PS * (16 + DIV) (RM0038 16.4.2)."""
        ps = (self._fcr_applied >> 22) & 0xF
        div = (self._fcr_applied >> 18) & 0xF
        return self._duty_ncom * (1 << ps) * (16 + div)

    def _lcdclk(self):
        """LCDCLK in Hz (0 when no clock is selected)."""
        rcc = getattr(self.m, "rcc", None)
        if rcc is None:
            return self.lcdclk_hz
        v = rcc.rtcclk_hz               # property of the RCC model
        return v() if callable(v) else v

    def _clk_on(self):
        rcc = getattr(self.m, "rcc", None)
        if rcc is None:
            return True
        try:
            return rcc.clock_enabled("LCD")
        except KeyError:
            return True

    def _gated(self, off, rw):
        if not self._gate_logged:
            self._gate_logged = True
            self.m.log.append((self.m.cycles, f"LCD {rw} access at offset 0x{off:02X} with its clock disabled"))

    def frame_cycles(self):
        """Frame period in core cycles for the configuration in use (exact Fraction), None without LCDCLK."""
        clk = self._lcdclk()
        if not clk:
            return None
        return Fraction(self._ratio()) * Fraction(self.m.sysclk_hz) / Fraction(clk)

    def frame_hz(self):
        """Frame rate in Hz for the configuration in use (f_frame of RM0038 16.4.2), 0 without LCDCLK."""
        clk = self._lcdclk()
        return float(Fraction(clk) / self._ratio()) if clk else 0.0

    def _delay_to(self, t):
        return max(1, ceil(t) - self.m.cycles)

    def _schedule_boundary(self):
        gen = self._gen
        self.m.schedule(self._delay_to(self._t_next), lambda: self._boundary(gen))

    def _enable(self):
        """LCDEN went 0 -> 1 (RM0038 16.5.1, 16.5.3: ENS is set immediately)."""
        if self.ens:                            # a pending disable is cancelled
            return
        self.ens = True
        self._gen += 1
        self._fcr_applied = self.fcr
        self._set_duty()
        self.m.log.append((self.m.cycles, "LCD enabled"))
        self._start_frames(self._gen)

    def _start_frames(self, gen):
        """Wait for LCDCLK, then run the step-up settling time (one frame with VSEL = 0) before the first frame."""
        if gen != self._gen:
            return
        fc = self.frame_cycles()
        if fc is None:
            self.m.schedule(CLOCK_POLL, lambda: self._start_frames(gen))
            return
        self._t_next = Fraction(self.m.cycles) + (fc if not (self.cr & CR_VSEL) else 0)
        self._schedule_boundary()

    def _set_duty(self):
        n = DUTY_NCOM.get((self.cr >> 2) & 7)
        if n is not None:
            self._duty_ncom = n

    def _boundary(self, gen):
        """Start of a frame."""
        if gen != self._gen:
            return
        if not (self.cr & CR_LCDEN):            # RM0038 16.5.1 / 16.5.3: off at the end of the last frame
            self.ens = False
            self.rdy = False
            self.m.log.append((self.m.cycles, "LCD disabled"))
            self._irq.update()
            return
        self.rdy = not (self.cr & CR_VSEL)      # step-up converter ready (internal source only)
        self._fcr_applied = self.fcr            # FCR takes effect at the start of a frame
        self._set_duty()
        self.fcrsf = True
        self.sof = True
        if self.udr:
            self._do_update()
        fc = self.frame_cycles()
        if fc is None:                          # LCDCLK stopped: the next frame waits for it
            self.m.schedule(CLOCK_POLL, lambda: self._resume(gen))
        else:
            self._t_next += fc
            self._schedule_boundary()
        self._irq.update()

    def _resume(self, gen):
        if gen != self._gen:
            return
        fc = self.frame_cycles()
        if fc is None:
            self.m.schedule(CLOCK_POLL, lambda: self._resume(gen))
            return
        self._t_next = Fraction(self.m.cycles) + fc
        self._schedule_boundary()

    def _do_update(self):
        """Copy LCD_RAM into LCD_DISPLAY (RM0038 16.4.7, SR.UDR note)."""
        n = N_RAM if self._udr_full else 2 * self._duty_ncom
        for i in range(min(n, N_RAM)):
            self.display[i] = self.ram[i]
        self.udr = False
        self.udd = True
        self._udr_full = False
        snapshot = list(self.display)
        for cb in list(self.on_update):
            cb(snapshot)

    def _fcr_arm(self, gen):
        clk = self._lcdclk()
        delay = Fraction(FCR_SYNC_LCDCLK) * Fraction(self.m.sysclk_hz) / Fraction(clk) if clk else CLOCK_POLL
        self.m.schedule(max(1, ceil(delay)), lambda: self._fcr_synced(gen))

    def _fcr_synced(self, gen):
        if gen != self._fcr_gen or self.ens:    # while enabled the next frame boundary applies FCR
            return
        if not self._lcdclk():                  # no LCDCLK: the register cannot be synchronised yet
            self._fcr_arm(gen)
            return
        self._fcr_applied = self.fcr
        self.fcrsf = True

    # ------------------------------------------------------------------ interrupt
    def _line(self):
        return bool((self.sof and self.fcr & FCR_SOFIE) or (self.udd and self.fcr & FCR_UDDIE))

    # ------------------------------------------------------------------ bus
    def _sr(self):
        return ((SR_FCRSF if self.fcrsf else 0) | (SR_RDY if self.rdy else 0) | (SR_UDD if self.udd else 0)
                | (SR_UDR if self.udr else 0) | (SR_SOF if self.sof else 0) | (SR_ENS if self.ens else 0))

    def read(self, off, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'R')
            return 0
        if not self._clk_on():
            self._gated(off, 'R')
            return 0
        if reg == CR:
            w = self.cr                         # RM0038 16.5.1
        elif reg == FCR:
            w = self.fcr                        # RM0038 16.5.2: last value written
        elif reg == SR:
            w = self._sr()                      # RM0038 16.5.3
        elif reg == CLR:
            w = 0                               # RM0038 16.5.4: write-only
        elif RAM_FIRST <= reg <= RAM_LAST:
            w = self.ram[(reg - RAM_FIRST) >> 2]    # RM0038 16.5.5
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
        if reg == CR:
            self._write_cr(self.merge(self.cr, off, value, size) & CR_MASK)
        elif reg == FCR:
            self.fcr = self.merge(self.fcr, off, value, size) & FCR_MASK    # RM0038 16.5.2
            self.fcrsf = False                  # cleared by hardware when writing FCR
            if not self.ens:
                self._fcr_gen += 1
                self._fcr_arm(self._fcr_gen)
            self._irq.update()
        elif reg == SR:
            # RM0038 16.5.3: only UDR is writable (rs: writing 1 sets it, 0 has no effect); the rest is read-only.
            w = self.merge(0, off, value, size)
            if (w & SR_UDR) and not self.udr:
                self.udr = True
                self._udr_full = not self.ens
        elif reg == CLR:
            w = self.merge(0, off, value, size)  # RM0038 16.5.4: write 1 to clear
            if w & CLR_UDDC:
                self.udd = False
            if w & CLR_SOFC:
                self.sof = False
            self._irq.update()
        elif RAM_FIRST <= reg <= RAM_LAST:
            if self.udr:                        # RM0038 16.4.7: LCD_RAM is write protected while UDR = 1
                return
            i = (reg - RAM_FIRST) >> 2
            mask = 0xFFFFFFFF if (i & 1) == 0 else 0x00000FFF   # high word of a COM holds S32..S43 only (table 78)
            self.ram[i] = self.merge(self.ram[i], off, value, size) & mask
        else:
            self.unmodelled(off, 'W')

    def _write_cr(self, new):
        old = self.cr
        if self.ens:                            # RM0038 16.5.1 note: VSEL, MUX_SEG, BIAS, DUTY protected
            new = (old & CR_PROTECTED) | (new & CR_LCDEN)
        if (new >> 5) & 3 == 3 or ((new >> 2) & 7) > 4:
            self.unmodelled(CR, 'W')            # BIAS = 11 and DUTY = 101..111 are forbidden (RM0038 16.5.1)
        self.cr = new
        if not self.ens:
            self._set_duty()                    # no frame is running: the duty applies at once
        if new & CR_LCDEN and not old & CR_LCDEN:
            self._enable()
        # LCDEN 1 -> 0 is handled at the next frame boundary (_boundary)
