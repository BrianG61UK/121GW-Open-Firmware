"""Level-sensitive interrupt line towards the NVIC, shared by the DMA and SDIO models.

An interrupt of these peripherals is the OR of status flags and enable bits: the request stays active until software has
cleared the flag.  The line is raised with nvic.irq(); the exception is pended again after a handler returned while the
line is still high (a flag the handler did not clear), which is how an NVIC treats a level interrupt (the same mechanism as
the USART and timer models, which keep private copies).  The re-pend check polls with a back-off while the exception is
pending but not served.
"""


class LevelIrq:
    MIN_POLL = 64                       # cycles
    MAX_POLL = 4096

    def __init__(self, owner, irq, line):
        """owner: the Periph (its .m is the Machine); irq: NVIC IRQ number (vector table position); line(): bool."""
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
        """Call after any change of a flag or enable bit."""
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
