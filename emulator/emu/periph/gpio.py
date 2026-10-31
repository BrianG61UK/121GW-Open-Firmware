"""STM32L152ZD general-purpose I/O ports (RM0038 chapter 7) with a board-level pin electrical model.

One GPIO instance models one port (A..H).  Register block size is 0x400 (RM0038 table 5, memory map).

Register map implemented (RM0038 7.4, register map table 40, page 190); every offset is a 32-bit register
and sub-word accesses are merged:
    0x00 MODER    0x04 OTYPER   0x08 OSPEEDR  0x0C PUPDR   0x10 IDR     0x14 ODR
    0x18 BSRR (BSRRL = low half at 0x18 sets, BSRRH = high half at 0x1A resets)
    0x1C LCKR     0x20 AFRL     0x24 AFRH     0x28 BRR
Offsets above 0x28 are not described in RM0038 and are routed to unmodelled().

Pin electrical model (board side)
- Each pin has an external drive state set by board code with set_input(pin, level); level 0, 1 or None.
  None means "not driven" (floating).
- Output drive of a pin (output_level(pin)):
    0     the pin actively drives low
    1     the pin actively drives high (push-pull only)
    None  the pin does not drive the pad: input mode, analog mode, open-drain with a 1 in ODR (RM0038 7.3.10:
          "a 1 in the Output register leaves the port in Hi-Z"), or alternate-function mode while no peripheral
          model has supplied a level with set_af_output().
- Pad level, which is what IDR samples (RM0038 7.3.9, 7.3.10, 7.3.11: IDR holds the I/O state in input, output and
  alternate function modes):
    * an actively driven pin shows its own level (the output wins over an external driver);
    * otherwise the external level if driven;
    * otherwise the weak pull resistor from PUPDR: pull-up -> 1, pull-down -> 0;
    * otherwise (floating, no pull) the model returns 0.  RM0038 does not define the level of a floating pin,
      0 is the documented choice of this model.
    * analog mode: the Schmitt trigger output is forced to 0 and the pull resistors are disabled (RM0038 7.3.12),
      so IDR reads 0.
- Observers: on_output(pin, cb) registers cb(pin, level, cycles) which is called for every change of the output
  drive state above (level is 0, 1 or None).  Callbacks run in the order the changes happened, even when a callback
  causes further pin changes (a shared queue delivers them first-in first-out).
- Input edges: edge_hook(port_index, pin, level) is called whenever an IDR bit changes.  port_index is the
  SYSCFG_EXTICRx port code (RM0038 8.5.3: A=0, B=1, C=2, D=3, E=4, H=5, F=6, G=7).
"""
from collections import deque

from .base import Periph

# Port base addresses (RM0038 table 5, memory map: AHB bus peripherals at 0x4002 0000 - 0x4002 1FFF).
GPIO_BASES = {
    'A': 0x40020000, 'B': 0x40020400, 'C': 0x40020800, 'D': 0x40020C00,
    'E': 0x40021000, 'H': 0x40021400, 'F': 0x40021800, 'G': 0x40021C00,
}
GPIO_SIZE = 0x400

# Port selection codes used by SYSCFG_EXTICRx (RM0038 8.5.3).
EXTI_PORT_CODE = {'A': 0, 'B': 1, 'C': 2, 'D': 3, 'E': 4, 'H': 5, 'F': 6, 'G': 7}

# MODERy field values (RM0038 7.4.1).
MODE_INPUT, MODE_OUTPUT, MODE_AF, MODE_ANALOG = 0, 1, 2, 3

# Register offsets (RM0038 7.4.12, table 40).
MODER, OTYPER, OSPEEDR, PUPDR, IDR, ODR = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14
BSRR, BSRRL, BSRRH, LCKR, AFRL, AFRH, BRR = 0x18, 0x18, 0x1A, 0x1C, 0x20, 0x24, 0x28

# Reset values per port (RM0038 7.4.1 MODER, 7.4.3 OSPEEDR, 7.4.4 PUPDR; every other register resets to 0).
_RESET_MODER = {'A': 0xA800_0000, 'B': 0x0000_0280}
_RESET_OSPEEDR = {'B': 0x0000_00C0}
_RESET_PUPDR = {'A': 0x6400_0000, 'B': 0x0000_0100}

# Shared first-in first-out notification queue: keeps callbacks ordered across ports and re-entrant calls.
_queue = deque()
_busy = False


def _dispatch(items):
    global _busy
    _queue.extend(items)
    if _busy:
        return
    _busy = True
    try:
        while _queue:
            fn, args = _queue.popleft()
            fn(*args)
    finally:
        _busy = False
        _queue.clear()


def _spread2(m16):
    """Expand a 16-bit pin mask to the 2-bit-per-pin register layout (MODER, OSPEEDR, PUPDR)."""
    r = 0
    for p in range(16):
        if (m16 >> p) & 1:
            r |= 3 << (2 * p)
    return r


def _spread4(m8):
    """Expand an 8-bit pin mask to the 4-bit-per-pin register layout (AFRL, AFRH)."""
    r = 0
    for p in range(8):
        if (m8 >> p) & 1:
            r |= 0xF << (4 * p)
    return r


def _fold2(diff):
    """Collapse a 2-bit-per-pin difference mask to a 16-bit pin mask."""
    r = 0
    for p in range(16):
        if (diff >> (2 * p)) & 3:
            r |= 1 << p
    return r


class GPIO(Periph):
    def __init__(self, letter):
        super().__init__()
        if letter not in GPIO_BASES:
            raise ValueError("GPIO port must be one of A..H")
        self.letter = letter
        self.name = 'GPIO' + letter
        self.base = GPIO_BASES[letter]
        self.port_index = EXTI_PORT_CODE[letter]
        self.edge_hook = None                      # edge_hook(port_index, pin, level)
        self._observers = [[] for _ in range(16)]
        self._ext = [None] * 16                    # external drive per pin (board)
        self._af_out = [None] * 16                 # alternate-function output level supplied by a peripheral model
        self._load_reset()
        self._out = [None] * 16
        self._pad = [0] * 16
        self._idr = 0
        for p in range(16):
            self._out[p], self._pad[p] = self._eval(p)
            self._idr |= self._pad[p] << p

    # ------------------------------------------------------------------ reset
    def _load_reset(self):
        L = self.letter
        self.moder = _RESET_MODER.get(L, 0)        # RM0038 7.4.1
        self.otyper = 0                            # RM0038 7.4.2
        self.ospeedr = _RESET_OSPEEDR.get(L, 0)    # RM0038 7.4.3
        self.pupdr = _RESET_PUPDR.get(L, 0)        # RM0038 7.4.4
        self.odr = 0                               # RM0038 7.4.6
        self.lckr = 0                              # RM0038 7.4.8
        self.afrl = 0                              # RM0038 7.4.9
        self.afrh = 0                              # RM0038 7.4.10
        self._lck_state = 0                        # lock key sequence progress (0..3)
        self._lck_x = 0                            # LCK[15:0] value used by the sequence
        self._lck_done = False                     # lock active until reset (RM0038 7.4.8)
        self._lck_mask = 0

    def reset(self):
        """MCU or peripheral reset (GPIOxRST in RCC): restore all registers, re-evaluate the pins."""
        self._load_reset()
        self._update(0xFFFF)

    # ------------------------------------------------------------------ board / peripheral interface
    @staticmethod
    def _chk_pin(pin):
        if not (isinstance(pin, int) and 0 <= pin < 16):
            raise ValueError("pin must be 0..15")

    def set_input(self, pin, level):
        """External drive of a pin: 0, 1 or None (not driven, floating)."""
        self._chk_pin(pin)
        if level is not None:
            level = 1 if level else 0
        self._ext[pin] = level
        self._update(1 << pin)

    def set_af_output(self, pin, level):
        """Level driven by an on-chip peripheral through the alternate-function path (0, 1 or None)."""
        self._chk_pin(pin)
        if level is not None:
            level = 1 if level else 0
        self._af_out[pin] = level
        self._update(1 << pin)

    def on_output(self, pin, cb):
        """Register cb(pin, level, cycles) for output drive changes of a pin (level 0, 1 or None)."""
        self._chk_pin(pin)
        self._observers[pin].append(cb)

    def output_level(self, pin):
        """Current output drive of a pin: 0, 1 or None (not driving the pad)."""
        self._chk_pin(pin)
        return self._out[pin]

    def pad_level(self, pin):
        """Level sampled by IDR for a pin."""
        self._chk_pin(pin)
        return self._pad[pin]

    def mode(self, pin):
        """MODERy: 0 input, 1 output, 2 alternate function, 3 analog."""
        self._chk_pin(pin)
        return (self.moder >> (2 * pin)) & 3

    def af(self, pin):
        """AFRLy / AFRHy: alternate function number 0..15."""
        self._chk_pin(pin)
        word = self.afrl if pin < 8 else self.afrh
        return (word >> (4 * (pin & 7))) & 0xF

    def otype(self, pin):
        """OTy: 0 push-pull, 1 open-drain."""
        self._chk_pin(pin)
        return (self.otyper >> pin) & 1

    def pull(self, pin):
        """PUPDRy: 0 none, 1 pull-up, 2 pull-down (3 is reserved in RM0038, treated as no pull)."""
        self._chk_pin(pin)
        return (self.pupdr >> (2 * pin)) & 3

    @property
    def idr(self):
        return self._idr

    # ------------------------------------------------------------------ electrical evaluation
    def _eval(self, p):
        """Return (output drive, pad level) of pin p from the register state and the external drive."""
        mode = (self.moder >> (2 * p)) & 3
        if mode == MODE_ANALOG:                    # RM0038 7.3.12: output off, pulls off, IDR reads 0
            return None, 0
        if mode == MODE_OUTPUT:                    # RM0038 7.3.10
            drv = (self.odr >> p) & 1
        elif mode == MODE_AF:                      # RM0038 7.3.11
            drv = self._af_out[p]
        else:                                      # RM0038 7.3.9
            drv = None
        od = (self.otyper >> p) & 1                # 1 = open-drain (RM0038 7.4.2)
        if drv == 0:
            return 0, 0
        if drv == 1 and not od:
            return 1, 1
        ext = self._ext[p]
        if ext is not None:
            return None, ext
        return None, 1 if ((self.pupdr >> (2 * p)) & 3) == 1 else 0

    def _update(self, mask):
        """Re-evaluate the pins in `mask`; queue output callbacks and input edge notifications in pin order."""
        if not mask:
            return
        now = self.m.cycles if self.m is not None else 0
        items = []
        for p in range(16):
            if not (mask >> p) & 1:
                continue
            out, pad = self._eval(p)
            if out != self._out[p]:
                self._out[p] = out
                for cb in list(self._observers[p]):
                    items.append((cb, (p, out, now)))
            if pad != self._pad[p]:
                self._pad[p] = pad
                self._idr = (self._idr & ~(1 << p)) | (pad << p)
                if self.edge_hook is not None:
                    items.append((self.edge_hook, (self.port_index, p, pad)))
        if items:
            _dispatch(items)

    # ------------------------------------------------------------------ bus
    def _locked(self, reg):
        """Bits of a control register frozen by an active lock (RM0038 7.3.6, 7.4.8)."""
        if not self._lck_done:
            return 0
        k = self._lck_mask
        if reg in (MODER, OSPEEDR, PUPDR):
            return _spread2(k)
        if reg == OTYPER:
            return k
        if reg == AFRL:
            return _spread4(k & 0xFF)
        return _spread4(k >> 8)                    # AFRH

    def read(self, off, size):
        reg = off & ~3
        if (off & 3) + size > 4 or reg > BRR:
            self.unmodelled(off, 'R')
            return 0
        if reg == MODER:
            w = self.moder                         # RM0038 7.4.1
        elif reg == OTYPER:
            w = self.otyper                        # RM0038 7.4.2
        elif reg == OSPEEDR:
            w = self.ospeedr                       # RM0038 7.4.3
        elif reg == PUPDR:
            w = self.pupdr                         # RM0038 7.4.4
        elif reg == IDR:
            w = self._idr                          # RM0038 7.4.5
        elif reg == ODR:
            w = self.odr                           # RM0038 7.4.6
        elif reg == BSRR:
            w = 0                                  # RM0038 7.4.7: write-only, reads return 0
        elif reg == LCKR:
            if size != 4:                          # RM0038 7.4.8: word access only
                self.unmodelled(off, 'R')
            elif self._lck_state == 3:             # the read that completes the lock key sequence
                self._lck_done = True
                self._lck_mask = self.lckr & 0xFFFF
                self._lck_state = 0
                self.lckr |= 1 << 16
            w = self.lckr
        elif reg == AFRL:
            w = self.afrl                          # RM0038 7.4.9
        elif reg == AFRH:
            w = self.afrh                          # RM0038 7.4.10
        else:
            w = 0                                  # BRR (RM0038 7.4.11): write-only, reads return 0
        return self.extract(w, off, size)

    def write(self, off, value, size):
        reg = off & ~3
        if (off & 3) + size > 4 or reg > BRR:
            self.unmodelled(off, 'W')
            return
        sh = 8 * (off & 3)
        wbits = (value & ((1 << (8 * size)) - 1)) << sh    # bits actually written, in register position
        if reg in (MODER, OTYPER, OSPEEDR, PUPDR, AFRL, AFRH):
            old = {MODER: self.moder, OTYPER: self.otyper, OSPEEDR: self.ospeedr,
                   PUPDR: self.pupdr, AFRL: self.afrl, AFRH: self.afrh}[reg]
            new = self.merge(old, off, value, size)
            if reg == OTYPER:
                new &= 0xFFFF                      # RM0038 7.4.2: bits 31:16 reserved
            lock = self._locked(reg)
            new = (old & lock) | (new & ~lock & 0xFFFFFFFF)
            if reg == MODER:                       # RM0038 7.4.1
                self.moder = new
                self._update(_fold2(old ^ new))
            elif reg == OTYPER:                    # RM0038 7.4.2
                self.otyper = new
                self._update(old ^ new)
            elif reg == OSPEEDR:                   # RM0038 7.4.3: speed has no effect on levels
                self.ospeedr = new
            elif reg == PUPDR:                     # RM0038 7.4.4
                self.pupdr = new
                self._update(_fold2(old ^ new))
            elif reg == AFRL:                      # RM0038 7.4.9
                self.afrl = new
            else:                                  # RM0038 7.4.10
                self.afrh = new
        elif reg == IDR:
            pass                                   # RM0038 7.4.5: read-only, writes have no effect
        elif reg == ODR:                           # RM0038 7.4.6: bits 31:16 reserved
            old = self.odr
            self.odr = self.merge(old, off, value, size) & 0xFFFF
            self._update(old ^ self.odr)
        elif reg == BSRR:                          # RM0038 7.4.7 / 7.3.5: BS in 15:0, BR in 31:16, set wins
            setb = wbits & 0xFFFF
            rstb = (wbits >> 16) & 0xFFFF
            old = self.odr
            self.odr = (old & ~rstb | setb) & 0xFFFF
            self._update(old ^ self.odr)
        elif reg == LCKR:
            self._lckr_write(off, value, size)
        else:                                      # BRR, RM0038 7.4.11: bits 15:0 reset ODR bits, 31:16 reserved
            old = self.odr
            self.odr = old & ~(wbits & 0xFFFF)
            self._update(old ^ self.odr)

    def _lckr_write(self, off, value, size):
        """LCKR write with the key sequence of RM0038 7.4.8:
        WR LCKK=1 + X, WR LCKK=0 + X, WR LCKK=1 + X, RD LCKR (X = LCK[15:0], unchanged during the sequence).
        Any error aborts the sequence.  A wrong write is treated as a possible new first step."""
        if self._lck_done:
            return                                 # locked until reset
        if size != 4:                              # RM0038 7.4.8: word access only
            self.unmodelled(off, 'W')
            self._lck_state = 0
            return
        key = (value >> 16) & 1
        x = value & 0xFFFF
        st = self._lck_state
        if st == 1 and key == 0 and x == self._lck_x:
            self._lck_state = 2
        elif st == 2 and key == 1 and x == self._lck_x:
            self._lck_state = 3
        else:
            self._lck_state = 1 if key else 0
            self._lck_x = x
        self.lckr = value & 0x1FFFF                # bits 31:17 reserved


def make_ports():
    """Return {letter: GPIO} for ports A..H; the board adds each with machine.add_periph(base, GPIO_SIZE, port)."""
    return {letter: GPIO(letter) for letter in GPIO_BASES}
