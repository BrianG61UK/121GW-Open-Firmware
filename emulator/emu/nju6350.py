"""NJU6350 serial real-time clock (NJRC datasheet NJU6350, E-39971), pin-level model.

Board wiring (schematic, RTC Circuit and the STM32 pin table): DATA (pin 7) = net EE_DO = PB7, CLK (pin 6) = net EE_CLK
= PB6, CE (pin 5) = net RTC_CE = PC13.  The chip is powered from VDD_P through D10 or from the 3 V coin cell BAT2
through D11, so it keeps counting while the meter is switched off.  The model listens to the MCU pin outputs through
GPIO.on_output() and drives DATA through GPIO.set_input(); the pads are read with GPIO.pad_level().

Protocol (datasheet "Data writing operation", "Data reading operation", "Timing chart"), all bits LSB first:
- CE high starts a frame, CE low ends it and releases DATA (high impedance).  CLK must be low at both CE edges.
- Bits are taken from DATA on each CLK rising edge.  The first 4 bits are the system control data RW, C0, C1, C2
  (bit 0 = RW).  C2C1C0 selects: 001 year, 010 month, 011 date, 100 day of week, 101 hour, 110 minute, 111 second,
  000 oscillator output / test mode.  RW = 1 writes, RW = 0 reads; RW = 0 with C2C1C0 = 000 is "invalidity".
  The firmware's register numbers are (C2C1C0 << 1) | RW: year 2/3, month 4/5, date 6/7, hour 10/11, minute 12/13,
  second 14/15 (read/write).
- Write: after the control bits the timer data follows (8 bits, 4 bits for the day of week); with more than 12 bits the
  first 4 are the control data and the last 8 (4) the timer data (note 3).  Timer updating stops from the write
  recognition and the divider restarts when CE falls.
- Read: when the 4th rising edge has recognised the read mode, the next CLK falling edge switches DATA to output; DATA
  then shows the first data bit after tRDD (200 ns max) and the next bit after each following falling edge.  The first
  8 bits (4 for the day of week) are valid.
- Day-of-week register: bit 3 is DC, the low-battery flag, set at the once-per-second detection when the supply is
  below VDET (typ. 1.6 V), cleared by power-on reset and by a data write.

Time base: the machine's emulated real time (Machine.elapsed_s()); the calendar is initialised from the host clock when
the chip is created (first power-on of the emulated meter).  A power cycle of the emulated meter detaches the chip and
attaches it to the new machine; the time that passed on the host meanwhile is added, because the chip runs from its
battery.

Choices the datasheet does not settle (stated here, applied where used)
- Data written is committed when CE falls and only if the frame carried the full 12 (8 for the day of week) bits.
- A read returns the register value as it is when the read mode is recognised.
- Bits clocked out beyond the valid ones are 0; day of week 1 = Sunday .. 7 = Saturday; the leap year rule is
  "year divisible by 4" (the datasheet says leap years are compensated up to AD 2099).
- Out-of-range BCD values written to the registers are kept as written and clamped to their legal range when the
  calendar next advances; the test-mode bits T0..T6 are stored but their effect is not documented (logged once).
- Timing limits (tCWH, tCWL, tCS, tCH, tWDS, tWDH) are not enforced; CLK high at a CE edge is logged once.
"""
import math
import time
from collections import deque
from fractions import Fraction

from .periph.rtc import days_in_month, from_days, to_days

T_RDD_S = Fraction(200, 10 ** 9)           # DATA delay after CLK falling, 200 ns max (AC characteristics)
VDET_V = 1.6                               # low-voltage detection level, typical (DC characteristics)
CODE_NAME = {1: 'year', 2: 'month', 3: 'date', 4: 'day of week', 5: 'hour', 6: 'minute', 7: 'second'}
KEY_NAME = {1: 'year', 2: 'month', 3: 'date', 4: 'dow', 5: 'hour', 6: 'minute', 7: 'second'}
REG_MASK = {1: 0xFF, 2: 0x1F, 3: 0x3F, 4: 0x07, 5: 0x3F, 6: 0x7F, 7: 0x7F}    # unused bits are always 0 (timer data format)


def _bcd(v):
    return (v // 10) << 4 | v % 10


def _dec(b):
    return (b >> 4) * 10 + (b & 15)


class NJU6350:
    def __init__(self, now=None):
        """now: time.struct_time of the initial calendar (default: the host clock, local time)."""
        t = now or time.localtime()
        self.reg = {1: _bcd(t.tm_year % 100), 2: _bcd(t.tm_mon), 3: _bcd(t.tm_mday),
                    4: (t.tm_wday + 1) % 7 + 1, 5: _bcd(t.tm_hour), 6: _bcd(t.tm_min), 7: _bcd(t.tm_sec)}
        self.osc = 0                       # F, T6..T0 as written with C2C1C0 = 000 (datasheet, system control data)
        self.dc = 0                        # low-battery flag (power-on reset value 0)
        self.supply_v = 3.0                # coin cell voltage, application circuit "3V"
        self.frames = deque(maxlen=256)    # decoded frames: (cycles, text)
        self.m = None
        self._wall = None
        self._phase = Fraction(0)
        self._logged = set()

    # ------------------------------------------------------------------ connection to the board
    def attach(self, m, ce, clk, data):
        """ce, clk, data: (GPIO model, pin) tuples of the three pins; connects the chip to machine m."""
        self.m = m
        self.frames.clear()
        self._ce, self._clk, self._data = ce, clk, data
        self._gen = 0
        self._stopped = False
        self._frame_reset()
        self._ce_level = self._pad(ce)
        self._clk_level = self._pad(clk)
        total = self._phase
        if self._wall is not None:                   # battery-backed: the host time that passed counts
            total += Fraction(time.time() - self._wall)
        n = math.floor(total)
        self._div0 = m.elapsed_s() - (total - n)
        if n:
            self._advance_secs(n)
        self._wall = None
        for port, pin in (ce, clk):
            port.on_output(pin, self._on_pin)
        if self._ce_level:                           # CE already high at connection: a frame is open
            self._frame_start()

    def detach(self):
        """Meter power removed: CE drops (internal pull-down), DATA is released; the chip keeps counting."""
        if self.m is None:
            return
        self._ce_end()
        self._drive(None)
        self._advance()
        self._phase = self.m.elapsed_s() - self._div0
        self._wall = time.time()
        self.m = None

    def set_supply_volts(self, volts):
        """Coin cell / VDD level seen by the low-voltage detector."""
        self.supply_v = volts

    def calendar(self):
        """Current registers as BCD bytes: {'year', 'month', 'date', 'dow', 'hour', 'minute', 'second'}."""
        self._advance()
        return {KEY_NAME[c]: v for c, v in self.reg.items()}

    # ------------------------------------------------------------------ calendar
    @staticmethod
    def _pad(pin):
        port, p = pin
        return port.pad_level(p)

    def _advance(self):
        """Add the seconds that elapsed since the divider was last cleared (the timer is stopped while writing)."""
        if self._stopped or self.m is None:
            return
        n = math.floor(self.m.elapsed_s() - self._div0)
        if n > 0:
            self._div0 += n
            self._advance_secs(n)

    def _advance_secs(self, n):
        r = self.reg
        y = min(_dec(r[1]), 99)
        mo = min(max(_dec(r[2]), 1), 12)
        d = min(max(_dec(r[3]), 1), days_in_month(y, mo))
        h, mi, s = min(_dec(r[5]), 23), min(_dec(r[6]), 59), min(_dec(r[7]), 59)
        wd = min(max(r[4] & 7, 1), 7)
        secs = to_days(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
        days0 = secs // 86400
        secs += n
        days, tod = divmod(secs, 86400)
        y, mo, d = from_days(days)
        r[1], r[2], r[3] = _bcd(y % 100), _bcd(mo), _bcd(d)
        r[4] = (wd - 1 + days - days0) % 7 + 1
        r[5], r[6], r[7] = _bcd(tod // 3600), _bcd(tod % 3600 // 60), _bcd(tod % 60)
        if self.supply_v < VDET_V:                   # detector runs once per second (Voltage Detect Function)
            self.dc = 1

    # ------------------------------------------------------------------ pins
    def _on_pin(self, pin, level, cycles):
        """An MCU output on CE or CLK changed (or its pad level changed through the pin mode)."""
        ce, clk = self._pad(self._ce), self._pad(self._clk)
        if ce != self._ce_level:
            self._ce_level = ce
            if ce:
                if self._clk_level:
                    self._log_once('ce_clk', "CLK high at a CE edge (datasheet: CLK must be low)")
                self._frame_start()
            else:
                if self._clk_level:
                    self._log_once('ce_clk', "CLK high at a CE edge (datasheet: CLK must be low)")
                self._ce_end()
        if clk != self._clk_level:
            self._clk_level = clk
            if self._ce_level:
                self._clk_rising() if clk else self._clk_falling()

    def _log_once(self, key, text):
        if key not in self._logged:
            self._logged.add(key)
            self.m.log.append((self.m.cycles, "NJU6350: " + text))

    def _drive(self, level):
        """Level on DATA driven by the chip (None = high impedance)."""
        port, p = self._data
        port.set_input(p, level)

    # ------------------------------------------------------------------ frame state machine
    def _frame_reset(self):
        self._bits = []                    # data bits received in this frame, in order
        self._mode = None                  # None, 'w' (write), 'r' (read), 'x' (invalid control data)
        self._code = 0
        self._armed = False                # read recognised, DATA switches to output at the next falling edge
        self._out_idx = None               # index of the data bit on DATA, None while DATA is an input
        self._rdata = 0
        self._rbits = 8

    def _frame_start(self):
        self._gen += 1
        self._frame_reset()

    def _clk_rising(self):
        self._bits.append(self._pad(self._data))        # DATA sampled on the rising edge (Data writing operation)
        if len(self._bits) == 4:
            b = self._bits
            cmd = b[0] | b[1] << 1 | b[2] << 2 | b[3] << 3      # RW, C0, C1, C2 (LSB first)
            rw, self._code = cmd & 1, cmd >> 1
            if rw:
                self._mode = 'w'
                if self._code:                          # timer data: updating stops, divider cleared (Data writing)
                    self._advance()
                    self._stopped = True
                    self.dc = 0                         # DC cleared by a data writing operation (Voltage Detect)
            elif self._code:
                self._mode = 'r'
                self._advance()
                self._rbits = 4 if self._code == 4 else 8
                self._rdata = self.reg[self._code] | (self.dc << 3 if self._code == 4 else 0)
                self._armed = True
            else:
                self._mode = 'x'                        # RW = 0 with C2C1C0 = 000: "invalidity"

    def _clk_falling(self):
        if self._mode != 'r':
            return
        if self._armed:                                 # first falling edge after the read recognition
            self._armed = False
            self._out_idx = 0
        elif self._out_idx is not None:
            self._out_idx += 1
        else:
            return
        i, gen = self._out_idx, self._gen
        bit = self._rdata >> i & 1 if i < self._rbits else 0
        delay = max(1, math.ceil(T_RDD_S * self.m.sysclk_hz))      # DATA valid tRDD after the falling edge
        self.m.schedule(delay, lambda: self._drive(bit) if gen == self._gen and self._ce_level else None)

    def _ce_end(self):
        """CE fell: DATA is released; a complete write is committed and the divider restarts."""
        self._gen += 1
        self._drive(None)
        text = None
        if self._mode == 'w':
            if self._code == 0:
                if len(self._bits) >= 12:
                    self.osc = sum(b << k for k, b in enumerate(self._bits[-8:]))
                    text = f"write oscillator/test 0x{self.osc:02X}"
                    if self.osc & 0x7F:
                        self._log_once('test', "test-mode bits written; their effect is not documented")
            else:
                n = 4 if self._code == 4 else 8
                if len(self._bits) >= 4 + n:
                    v = sum(b << k for k, b in enumerate(self._bits[-n:])) & REG_MASK[self._code]
                    self.reg[self._code] = v
                    text = f"write {CODE_NAME[self._code]} = 0x{v:02X}"
                else:
                    text = f"write {CODE_NAME[self._code]} incomplete ({len(self._bits)} bits), discarded"
            if self._stopped:
                self._stopped = False
                self._div0 = self.m.elapsed_s()          # divider starts when CE changes from H to L
        elif self._mode == 'r':
            text = f"read {CODE_NAME[self._code]} -> 0x{self._rdata:02X}"
        elif self._bits:
            text = f"frame of {len(self._bits)} bits ignored"
        if text:
            self.frames.append((self.m.cycles, text))
        self._frame_reset()
