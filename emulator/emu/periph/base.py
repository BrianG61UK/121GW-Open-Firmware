"""Common base for peripheral models.

A model covers one register block.  The machine calls
    read(off, size)  -> int     off = byte offset inside the block, size = 1, 2 or 4
    write(off, value, size)
for every access (byte/halfword accesses arrive with their own offset and size; models that keep
32-bit registers must merge sub-word writes themselves — use `merge`).

Services available through self.m (the Machine, set by Machine.add_periph):
    self.m.cycles                    virtual time in core clock cycles
    self.m.sysclk_hz                 current core clock (the RCC model updates it)
    self.m.schedule(delay, cb)       call cb() after `delay` cycles
    self.m.nvic.irq(n)               raise IRQ n (STM32L1 vector table position)
    self.m.log.append((cycles, s))   event log shown in the UI
    self.m._note(addr, 'R'|'W')      report an access the model does not implement (never ignore silently)
    self.m.uc                        Unicorn instance (e.g. to program flash/EEPROM bytes)
    self.m.request_reset(why)        system reset
"""


class Periph:
    name = "periph"
    base = 0

    def __init__(self):
        self.m = None

    @staticmethod
    def merge(old, off, value, size):
        """Merge a size-byte write at byte offset `off` (0..3 within the word) into a 32-bit value."""
        sh = 8 * (off & 3)
        mask = ((1 << (8 * size)) - 1) << sh
        return (old & ~mask) | ((value << sh) & mask)

    @staticmethod
    def extract(word, off, size):
        return (word >> (8 * (off & 3))) & ((1 << (8 * size)) - 1)

    def unmodelled(self, off, rw):
        self.m._note(self.base + off, rw)

    def read(self, off, size):
        self.unmodelled(off, 'R')
        return 0

    def write(self, off, value, size):
        self.unmodelled(off, 'W')
