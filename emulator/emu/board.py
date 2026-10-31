"""121GW board wiring: front-panel inputs and indicator outputs on the MCU pins.

Pin facts (firmware analysis + schematic):
- Keys PG8..PG15, active low, MCU pull-ups: MODE, SETUP, MIN/MAX, MEM, RANGE, HOLD, REL, PEAK.
- Rotary switch PG0..PG7: one-hot, active low; code bit k = !PG(7-k).  Code per dial position:
  Low Z 0x01, V 0x02, mV/Temp 0x04, Hz 0x08, Ohm 0x10, mVA/VA 0x20, uA/uVA 0x40, A/mA 0x80.
  Both OFF positions give no code; OFF removes power (no software handling exists).
- PE10 / PE11: outputs of the input-warning comparators (schematic U5, nets FUSE_mA / FUSE_A),
  driven high when nothing is plugged; low = a plug is detected in the mA/uA jack (PE10) or the
  A jack (PE11).
- PE7 buzzer driver, PE8 backlight, PE9 supply switch (outputs shown in the UI).
"""

KEYS = {'MODE': 8, 'SETUP': 9, 'MINMAX': 10, 'MEM': 11, 'RANGE': 12, 'HOLD': 13, 'REL': 14, 'PEAK': 15}
DIAL = [None, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, None]   # UI positions, clockwise
JACK_PIN = {'mA': 10, 'A': 11}                                       # on port E


class Board:
    def __init__(self, gpio):
        """gpio: dict port letter -> GPIO model (set_input / on_output / output_level)."""
        self.g = gpio
        self.keys = set()
        self.dial = 2                       # V
        self.jacks = set()
        self.outputs = {'buzzer': 0, 'backlight': 0, 'supply': 0}
        for name, pin in (('buzzer', 7), ('backlight', 8), ('supply', 9)):
            gpio['E'].on_output(pin, self._out(name))

    def _out(self, name):
        def cb(pin, level, cycles):
            self.outputs[name] = level
        return cb

    def apply(self):
        """Drive every input pin from the current front-panel state."""
        G, E = self.g['G'], self.g['E']
        for name, pin in KEYS.items():
            G.set_input(pin, 0 if name in self.keys else None)
        code = DIAL[self.dial] or 0
        for k in range(8):
            G.set_input(7 - k, 0 if code & (1 << k) else None)
        for jack, pin in JACK_PIN.items():
            E.set_input(pin, 0 if jack in self.jacks else 1)

    def powered(self):
        return DIAL[self.dial] is not None

    def key(self, name, down):
        if name not in KEYS:
            raise ValueError(f'unknown key {name}')
        (self.keys.add if down else self.keys.discard)(name)
        self.apply()

    def set_dial(self, pos):
        if not 0 <= pos < len(DIAL):
            raise ValueError('dial position out of range')
        self.dial = pos
        self.apply()

    def jack(self, name, plugged):
        # every jack's plug state is shown in the UI; only the current jacks drive MCU pins
        if name not in ('A', 'mA', 'COM', 'V'):
            raise ValueError(f'unknown jack {name}')
        (self.jacks.add if plugged else self.jacks.discard)(name)
        self.apply()
