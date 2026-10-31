"""STM32L152ZD external interrupt/event controller, EXTI (RM0038 10.2, 10.3), block at 0x4001 0400.

Registers (RM0038 10.3, register map table 52, page 245), all 24 lines (0..23, Cat.3 and above):
    0x00 IMR   0x04 EMR   0x08 RTSR   0x0C FTSR   0x10 SWIER   0x14 PR
Offsets 0x18 and above are not described in RM0038 and are routed to unmodelled().

Signal path (RM0038 figure 32): input line -> edge detect (RTSR/FTSR) -> OR with SWIER -> AND with IMR -> pending
register PR -> NVIC; the same OR output ANDed with EMR feeds the event pulse generator (wake-up for WFE, RM0038
10.2.3) and does not set PR (RM0038 10.2.4).

Line sources
- Lines 0..15 come from GPIO pins: the GPIO port models call gpio_edge(port_index, pin, level) (set up by
  attach_gpio) and SYSCFG_EXTICRx selects which port feeds each line (RM0038 10.2.5, 8.5.3 - 8.5.6).
  When an EXTICR selection changes, the line level is re-sampled from the newly selected pin without producing an
  edge (RM0038 does not define one).
- Lines 16..23 are internal sources (RM0038 10.2.5): 16 PVD, 17 RTC alarm, 18 USB wakeup, 19 RTC tamper/timestamp,
  20 RTC wakeup, 21 comparator 1, 22 comparator 2, 23 channel acquisition.  Peripheral models drive them with
  line_input(line, level).

NVIC mapping of the lines (RM0038 table 51, vector table for Cat.4/5/6, positions = IRQ numbers):
  lines 0..4 -> EXTI0..EXTI4 = IRQ 6..10; lines 5..9 -> EXTI9_5 = IRQ 23; lines 10..15 -> EXTI15_10 = IRQ 40;
  16 -> PVD IRQ 1; 17 -> RTC_Alarm IRQ 41; 18 -> USB_FS_WKUP IRQ 42; 19 -> TAMPER_STAMP IRQ 2;
  20 -> RTC_WKUP IRQ 3; 21, 22 -> COMP/CA IRQ 22.
  Line 23 ("channel acquisition interrupt", RM0038 10.2.5) is routed to IRQ 22, whose table 51 description is
  "Comparator wakeup through EXTI line (21 and 22) interrupt / Channel acquisition interrupt"; the table does not
  name line 23 explicitly.

The PR bit is the interrupt line level towards the NVIC: if a handler returns while a PR bit of its vector is still
set, the interrupt is taken again.  This is modelled with a short poll that starts when the IRQ is raised.
"""
from .base import Periph

EXTI_BASE = 0x40010400
EXTI_SIZE = 0x400

# Offsets (RM0038 table 52).
IMR, EMR, RTSR, FTSR, SWIER, PR = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14

LINE_MASK = 0xFFFFFF                    # 24 lines, bits 31:24 reserved (RM0038 10.3.1 - 10.3.6)
N_LINES = 24

# EXTI line -> NVIC IRQ number (RM0038 table 51, see module docstring).
IRQ_OF_LINE = ([6, 7, 8, 9, 10] + [23] * 5 + [40] * 6 + [1, 41, 42, 2, 3, 22, 22, 22])

_POLL_CYCLES = 16                       # period of the level re-assertion poll


class EXTI(Periph):
    name = "EXTI"
    base = EXTI_BASE

    def __init__(self, syscfg):
        super().__init__()
        self.syscfg = syscfg
        syscfg.exti = self
        self.event_hook = None          # event_hook(mask) called on every event pulse (WFE wake-up)
        self._gpios = {}                # port index -> GPIO model
        self._armed = set()             # IRQ numbers with a level poll scheduled
        self._gen = 0                   # voids the level polls scheduled before a reset
        self.reset()

    def reset(self):
        """Registers back to their reset values (RM0038 10.3.1 - 10.3.6).  The input levels of the internal lines 16..23
        are driven by other peripherals (RTC, PVD, ...) that are not reset together with this block, so they are kept
        (without a kept level the RTC would have to re-announce a flag that is still set); lines 0..15 are re-sampled
        from the pins by resync()."""
        internal = self._lvl[16:] if hasattr(self, '_lvl') else [0] * (N_LINES - 16)
        self._gen += 1
        self._armed.clear()
        self.imr = 0                    # RM0038 10.3.1: reset 0
        self.emr = 0                    # RM0038 10.3.2: reset 0
        self.rtsr = 0                   # RM0038 10.3.3: reset 0
        self.ftsr = 0                   # RM0038 10.3.4: reset 0
        self.swier = 0                  # RM0038 10.3.5: reset 0
        self.pr = 0                     # RM0038 10.3.6: reset value undefined, the model starts with 0
        self._event = 0                 # event pulses not yet consumed by pending_event()
        self._lvl = [0] * 16 + internal  # current input level of every line
        self.resync()

    # ------------------------------------------------------------------ wiring
    def attach_gpio(self, gpio):
        """Route a GPIO port model's input edges into this controller."""
        self._gpios[gpio.port_index] = gpio
        gpio.edge_hook = self.gpio_edge
        self.resync()

    def resync(self):
        """Re-sample lines 0..15 from the pins selected by SYSCFG_EXTICRx, without producing edges."""
        for line in range(16):
            port = self.syscfg.source_port(line)
            gpio = self._gpios.get(port) if port is not None else None
            self._lvl[line] = (gpio.idr >> line) & 1 if gpio is not None else 0

    def gpio_edge(self, port_index, pin, level):
        """Input level change of a GPIO pin; reaches the line only if SYSCFG_EXTICR selects this port for the pin."""
        if self.syscfg.source_port(pin) == port_index:
            self.line_input(pin, level)

    def line_input(self, line, level):
        """Drive EXTI line 0..23 to a level; a selected edge sets PR (if unmasked) and/or produces an event."""
        level = 1 if level else 0
        old = self._lvl[line]
        if old == level:
            return
        self._lvl[line] = level
        if level:
            sel = (self.rtsr >> line) & 1       # rising edge trigger (RM0038 10.3.3)
        else:
            sel = (self.ftsr >> line) & 1       # falling edge trigger (RM0038 10.3.4)
        if sel:
            self._trigger(line)

    # ------------------------------------------------------------------ trigger / NVIC
    def _trigger(self, line):
        bit = 1 << line
        if self.imr & bit:                      # interrupt path (RM0038 figure 32, 10.2.4)
            self.pr |= bit
            irq = IRQ_OF_LINE[line]
            self.m.nvic.irq(irq)
            self._arm(irq)
        if self.emr & bit:                      # event path: pulse, PR is not set (RM0038 10.2.4)
            self._event |= bit
            if self.event_hook is not None:
                self.event_hook(bit)

    def _group(self, irq):
        return sum(1 << n for n in range(N_LINES) if IRQ_OF_LINE[n] == irq)

    def _arm(self, irq):
        if irq not in self._armed:
            self._armed.add(irq)
            gen = self._gen
            self.m.schedule(_POLL_CYCLES, lambda: self._poll(irq, gen))

    def _poll(self, irq, gen):
        """PR drives the NVIC line as a level: re-pend after exception return if a PR bit is still set."""
        if gen != self._gen:
            return                              # scheduled before a reset
        self._armed.discard(irq)
        if not (self.pr & self._group(irq)):
            return
        nvic = self.m.nvic
        exc = 16 + irq
        if not nvic.enabled(exc):
            return
        if exc not in self.m.active and exc not in self.m.pending:
            nvic.irq(irq)
        self._arm(irq)

    def pending_event(self, clear=False):
        """Mask of EXTI lines that produced an event pulse since it was last cleared (WFE wake-up, RM0038 10.2.3)."""
        ev = self._event
        if clear:
            self._event = 0
        return ev

    # ------------------------------------------------------------------ bus
    def read(self, off, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'R')
            return 0
        if reg == IMR:
            w = self.imr                        # RM0038 10.3.1
        elif reg == EMR:
            w = self.emr                        # RM0038 10.3.2
        elif reg == RTSR:
            w = self.rtsr                       # RM0038 10.3.3
        elif reg == FTSR:
            w = self.ftsr                       # RM0038 10.3.4
        elif reg == SWIER:
            w = self.swier                      # RM0038 10.3.5
        elif reg == PR:
            w = self.pr                         # RM0038 10.3.6
        else:
            self.unmodelled(off, 'R')
            return 0
        return self.extract(w, off, size)

    def write(self, off, value, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'W')
            return
        wbits = ((value & ((1 << (8 * size)) - 1)) << (8 * (off & 3))) & LINE_MASK
        if reg == IMR:
            self.imr = self.merge(self.imr, off, value, size) & LINE_MASK
        elif reg == EMR:
            self.emr = self.merge(self.emr, off, value, size) & LINE_MASK
        elif reg == RTSR:
            self.rtsr = self.merge(self.rtsr, off, value, size) & LINE_MASK
        elif reg == FTSR:
            self.ftsr = self.merge(self.ftsr, off, value, size) & LINE_MASK
        elif reg == SWIER:
            # RM0038 10.3.5: writing 1 to a bit that is 0 raises a software interrupt/event on the line; the bit
            # is cleared by clearing the PR bit.  Writing 0 does not clear it.
            new = wbits & ~self.swier
            self.swier |= wbits
            for line in range(N_LINES):
                if (new >> line) & 1:
                    self._trigger(line)
        elif reg == PR:
            # RM0038 10.3.6: rc_w1, writing 1 clears the pending bit (and the matching SWIER bit, 10.3.5)
            self.pr &= ~wbits
            self.swier &= ~wbits
        else:
            self.unmodelled(off, 'W')
