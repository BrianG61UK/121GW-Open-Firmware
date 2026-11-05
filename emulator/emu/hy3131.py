"""HY3131 multimeter analog front end (HYCON), pin-level model on the MCU's GPIOF bit-bang bus.

Sources (cited as below in every comment):
    DS pN    HY3130/HY3131 datasheet DS-HY3131-V10_EN, page N (inputs/docs)
    spec     analysis/hy3131_model.md, section number
    misc     analysis/hy3131_modes_misc.md, acc  analysis/hy3131_modes_ac_current.md (section)
    FW addr  instruction or literal in the original application image (base 0x08006000)
    SCH      121GW circuit diagram (inputs/docs)

Wiring (spec 1.2; SCH nets HY_CK / HY_CS / HY_DI / HY_DO between U3 and U4):
    PF0 = CK (MCU output)   PF1 = CS, active low (MCU output)   PF2 = DI (MCU output, chip input)
    PF3 = DO (chip output, MCU input): SPI data while CS is low, IRQ output while CS is high (DS p15 7.2 (4))

SPI slave (DS p14-15 7.2 and the Read / Write / IRQ / Timing figures)
- CS falling starts a frame, CS rising ends it (DS p14 7.2 (2), (3)).
- DI is latched on the rising CK edge (DS p14 timing figure "Data Latch"; DS p15 (7)).  DO changes after the
  falling CK edge (DS p14 "Data Output", TDODL; DS p15 (8)).
- First 8 clocks: address bits 6..0, MSB first, then R/W (1 = read) (DS p14 7.2 (1)).
- Read: the 9th clock is blank ("SPI Read Period"); clocks 10..17 carry the register, MSB first, and every
  further 8 clocks the next address (auto-increment) until CS rises (DS p14 7.2 (2)).  The model loads the
  register into the output shift register at the falling edge of the 9th clock (and after every 8 data bits) and
  presents its MSB; the MCU samples DO while CK is high (FW 0x0800C138).
- Write: data bytes follow the 8th bit immediately (no blank clock), auto-increment per byte (DS p14 7.2 (3)).
- DO while CS is low before the first data bit is "XXX" (undefined) in the DS p14 figures; the model drives 0 there
  (model choice, the firmware never samples it: spec 1.1).
- Timing figures TCKHI/TCKLO/TDISET/TDIHOLD/TDODL (DS p13) are not checked: the model is edge-functional.

Registers 0x00..0x3F (DS p17 list, p18-19 data/interrupt registers, p20-37 functions; spec 2)
- 0x00..0x1A are results / status (read only).  0x1B..0x1D CTA: CTA<7:0> is cleared while ENCTR = 0 (DS p36 (4))
  and CTA<23:8> "can write in data through SPI only" while ENCTR = 0 (DS p36 (5)); the datasheet names no SPI
  write path for CTA<7:0>, so the model ignores writes to 0x1B (inference).  CTSTA bits 7:4 (PCNTI, ACPO, CMPHO,
  CMPLO: live comparator / CNT levels, DS p36, p25 (1)) are not modelled and read 0; the firmware never reads
  CTSTA (spec 2).
- 0x1E INTF: set by events whether or not enabled (DS p19 10.1 (7)), cleared by reset and when read, writable to 0
  but not to 1 (DS p19 10.2 (7)).  0x1F INTE.  IRQ = (INTF & INTE) != 0, output on DO while CS is high
  (DS p15 7.2 (4); DS p19 10.1 (6)); BORF has no enable and no IRQ (DS p19 10.2 (1)).
- 0x20..0x36 configuration (read back as written).  0x37: "Testing Mode, Don't use or Write "0" only" (DS p17);
  writing 0x60 resets the IC (DS p20 (7), (8)); other values are ignored and the register reads 0 (model choice).
- 0x38..0x3F: not described by the datasheet (spec 2 "UNPROVEN"); reads return 0, writes are ignored, both logged.
- Reset values: the datasheet gives none except the cases implemented here (ENAD1 = 0 clears AD1, DS p30 (1);
  ENPKH = 0 sets PKHMAX<18:0>/PKHMIN<18:0> to 40000h/3FFFFh, DS p34, stored sign-extended to 24 bits as DS p18
  (5), (6) state for these registers ("PKHMAX<23:19> and PKHMAX<18> is the same"), i.e. FC0000h / 03FFFFh;
  ENCTR = 0 clears CTB/CTC/CTBOV and CTA<7:0>, DS p36 (1), (4) - (1) says CTA<23:0> is cleared, (4)/(5) say
  CTA<23:8> is not; the model follows (4)/(5), which the firmware's preset-then-enable sequence relies on
  (FW 0x0800BFF0); INTF cleared, DS p19 10.2 (7)).  Every other register resets to 0x00 (model choice, spec 2).  The line
  "ADC Set default value" on DS p29 belongs to the temperature-sensor section and is a configuration
  recommendation, not a reset state, so it is not applied.

Clock (DS p20 (1)-(4)): SYSCLK = crystal oscillator when ENOSC = 1 and ENXI = 0.  SCH X1 is marked 4.9152 MHz
(DS p5 feature list and the DS p20 clock figure show the same crystal).  With ENOSC = 0 nothing converts or
counts (results hold their values).  ENXI = 1 (SYSCLK = XIN, DS p20 (2)) needs an external clock on XIN, which
the board does not have (SCH: crystal on XIN/XOUT); the firmware never sets it (every row of spec 3 has R33
bit 4 = 0) and the model then stops all converters (model choice).

Converters
- AD1: rate = (FSYSCLK / 30) / OSR1 (DS p20 (4), DS p31 (10), (11)).  AD1CHOP = 1x makes the output rate
  "one time slower" (DS p30 (2)); whether that means unchanged or halved is UNPROVEN (spec 8 #2), selectable with
  chop_rate_divisor (default 1: the manual's 5 readings per second equal 80 sps / 16 samples for the DCV rows
  only if the rate is not halved; spec 4.1 N = 16, spec 3 DCV rows OSR 2048; this is consistency, not proof).
  Transfer (DS p31): AD1<23:0> = IG * VIN / (RG * VR) + DCOS / RG.  The datasheet gives the ratio but not the
  scale of AD1<23:0>; the register range 800000h..7FFFFFh (DS p18 (1)) makes 2^23 the natural full-scale code
  for a ratio of 1, and the calibration constants agree with it to 0.5..0.8 % for DCV r1..r3 (spec 5.5).  The
  scale is therefore AD1_SCALE = 2^23, still UNPROVEN as an explicit datasheet statement.  The code is rounded to
  the nearest integer (rounding mode: model choice) and held at the register limits 800000h / 7FFFFFh when the
  input is beyond them: the datasheet gives the register range only, not what AD1 outputs when overloaded, so the
  clamp is a model choice (UNPROVEN).  The chip outputs a true
  two's-complement code; the firmware's off-by-one decode of negative codes (FW 0x080062F8, spec 4.1) is not
  compensated.
  AD1CHOP (DS p30 table): 00 -> VX + VOS, 01 -> VX - VOS, 1x -> VX.  VOS has no datasheet figure and is a
  parameter (default 0).  Input/reference buffers and the pre-filter (SFT1, DS p28) have no DC effect in this
  model (no input current, no settling).  A configuration change takes effect at the next conversion (comb-filter
  settling is not modelled).
  Digital filter (DS p30 block diagram of 13.1, read on a 600 dpi render): the 1-bit output of the AD1 modulator
  enters a block labelled "Comb Filter" with superscript 2, set by AD1OSR, whose output is the 24-bit result; the
  AD2 / AD3 blocks on DS p32 carry superscript 3.  The modulator samples at AD1CLK = FSYSCLK / 30 (DS p31 (10)) and
  the output rate is AD1CLK / OSR1 (DS p31 (11)), so the comb decimates by OSR1.  A second-order comb (sinc^2)
  decimating by R = OSR1 has the triangular impulse response of length 2R - 1 modulator samples and
      H(f) = [sin(pi f R / AD1CLK) / (R sin(pi f / AD1CLK))]^2,  linear phase, delay (R - 1) / AD1CLK,
  i.e. nulls at every multiple of the output rate.  Each conversion is that filter's output for the input waveform
  over its window (_ad1_ac).  Model limits, stated as such: the modulator's signal transfer function is not given by
  the datasheet and is taken as 1 (model choice; the frequencies applied here, mains pickup at 50/60 Hz, are below
  1/2700 of AD1CLK); the scale is the DC transfer of DS p31.  The NMRR figures of DS p13 (120 dB at 5 sps, 75 dB at
  10 sps, 50/60 Hz +-1 Hz) neither confirm nor contradict the order: sinc^2 gives infinite rejection at exactly 50
  and 60 Hz at both rates and 68.8..72.6 dB at +-1 Hz at both rates; no sinc^N gives the 45 dB difference between
  the two rates at the same offset (computed for N = 1, 2, 3), so the test conditions behind those figures are not
  those of a bare comb.  With AD1CHOP = 1x the datasheet says only that the ADC "switches input signal based on OSR
  configured time" and the output rate is "one time slower" (DS p30 (2)): how the chopped phases combine through the
  comb is not stated, so an AC component is NOT converted in that state (the conversion carries the DC part and
  reports 'ac_error' in snapshot()).  The firmware's DCV, LowZ DC, DCmV / TEMP, OHM, BEEP, DIODE, DC current and DC VA
  rows all set AD1CHOP = 2 or 3 (spec 3); only CAP r3 / r4 (AD1 on PB<2>) and the AC rows (PB<7>) use 0.
- AD2 (DS p32-33) runs at FAD2CLK / OSR2 with FAD2CLK = FSYSCLK / 2 or / 4 (SAD2CLK); LPF and RMS at the AD2 rate /
  OSR4 (DS p34).  The datasheet gives no AD2 transfer function and no high-pass filter specification for the RMS
  input (DS p34 "data that passed High Pass Filter"), so the AD2, LPF and RMS data are NOT modelled: AD2F, LPFF
  and RMSF are raised at their datasheet cadence, the data registers keep their cleared values and snapshot()
  reports this.  The peak detector (PKHMAX / PKHMIN, DS p34-35) tracks the extremes of the AD2 code that the front
  end supplies (_peak_update).
- Analog time constants: the specs give none for the AC paths (AD8436, filters) and no settling figure after a
  configuration change (acc 14, VA.11), so none is modelled.
- Frequency counter (DS p36-37): see _ctr_start().

Analog interface: a front-end provider object (emu/frontend.py) supplies
    pins(sel, t) -> {pin name: volts}   voltages at the pins selected by the multiplexers (sel), at chip time t
    noise(sel) -> {'vin_sigma': V, 'vref_sigma': V, 'code_sigma': raw LSB, 'raw_per_count': raw LSB}
    counter_input(source, t) -> None or (frequency Hz, duty 0..1, epoch s)
    ac_components(sel, t) -> [(peak volts at FP - FN, frequency Hz, phase rad), ...]   optional: sine components
                             v(t') = peak sin(2 pi f t' + phase) added to the DC input, converted by _ad1_ac
Noise is drawn per conversion from a seedable random.Random (deterministic runs: pass seed).
"""
import math
import random

# GPIOF pin numbers (spec 1.2; FW literals 0x0800C280..0x0800C288)
PIN_CK, PIN_CS, PIN_DI, PIN_DO = 0, 1, 2, 3

F_XTAL = 4_915_200                     # SCH X1 4.9152 MHz; DS p5 "4.9152MHz operation clock source"
AD1_SCALE = 1 << 23                    # full-scale code for a ratio of 1 (UNPROVEN scale, see module docstring)
AD1_MAX, AD1_MIN = 0x7FFFFF, -0x800000 # DS p18 (1)

# Register addresses (DS p17)
INTF, INTE = 0x1E, 0x1F
R20, R21, R22, R23, R24, R25, R26, R27, R28, R29 = range(0x20, 0x2A)
R30, R31, R32, R33, R37 = 0x30, 0x31, 0x32, 0x33, 0x37
CTSTA = 0x14

# INTF / INTE bits (DS p19)
BORF, RMSF, LPFF, AD1F, AD2F, CTF = 0x80, 0x10, 0x08, 0x04, 0x02, 0x01

# Multiplexer tables (DS p28)
SAD1FP_PIN = ['SENSE', 'FB', 'RLU', 'OP1O', 'OP2O', 'VDDA', 'REFO', 'VREF',
              'PB0', 'PB1', 'PB2', 'PB3', 'PB4', 'PB5', 'PB6', 'PB7']
SAD1FN_PIN = ['SENSE', 'RLU', 'VSSA', 'AGND', 'PB2', 'PB3', 'PB4', 'PB5']
SAD1RH_PIN = ['FB', 'REFO', 'VREF', 'PB6', 'RLU', 'VDDA', 'AGND', None]     # 111 = "X"
SAD1RL_PIN = ['RLU', 'AGND', 'PB3', 'PB5', 'FB', 'VSSA', 'VREF', None]
# SAD1I (DS p28): 00 filter outputs, 01 FB/RLU, 10/11 internal temperature sensor
SAD1I_PIN = {1: ('FB', 'RLU')}
# Comparator input SCMPI (DS p25-26 INCMP table, spec 3: 111 = PB<4>); names the counter source
SCMPI_NAME = ['SENSE', 'FB', 'OP1O', 'PB0', 'PB1', 'RLD', 'PB3', 'PB4']      # DS p25 INCMP table

AD1_IG = [0.9, 1.8, 2.7, 3.6]                       # DS p30 (3)
AD1_RG = [1.0, 0.333]                               # DS p30 (4)
AD1_DCOS = [0, 0.25, 0.5, 0.75, 0, -0.25, -0.5, -0.75]   # DS p31 AD1OS table
OSR1 = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768]  # DS p31 (11)
OSR2 = [32, 64, 128, 256, 512, 1024, 1024, 1024]         # DS p33 (6)
OSR4 = [128, 256, 512, 1024, 2048, 4096, 8192, 16384]    # DS p34 (3)

CTA_MOD = 1 << 24                                   # CTA/CTB/CTC are 24-bit (DS p36)


class HY3131:
    def __init__(self, machine, gpio_f, frontend, seed=None, noise=True, chop_rate_divisor=1,
                 vos_codes=0.0, zero_drift_counts_per_c=0.0, delta_t_c=0.0, f_sys=F_XTAL):
        """machine: emu.core.Machine; gpio_f: GPIOF model; frontend: provider of pin voltages (module docstring).
        seed: RNG seed (None = nondeterministic); noise: draw per-conversion noise when True.
        chop_rate_divisor: AD1 rate divisor applied when AD1CHOP = 1x (1 or 2, UNPROVEN, see module docstring).
        vos_codes: AD1 offset code VOS used by AD1CHOP = 00 / 01 (DS p30 table; no datasheet value, default 0).
        zero_drift_counts_per_c, delta_t_c: AD1 zero drift in datasheet counts per degree C and the temperature
        difference from calibration; DS p12 gives min -0.03 / typ 0 / max +0.03 counts/C, so the default is the
        typical value 0.  f_sys: crystal frequency (SCH X1)."""
        self.m = machine
        self.g = gpio_f
        self.frontend = frontend
        self.seed = seed                # kept so that other models (front-end environment) can derive their own RNG
        self.rng = random.Random(seed)
        self.noise = noise
        self.chop_rate_divisor = chop_rate_divisor
        self.vos_codes = vos_codes
        self.zero_drift_counts_per_c = zero_drift_counts_per_c
        self.delta_t_c = delta_t_c
        self.f_sys = f_sys
        # pin state seen by the chip; a floating MCU pin (output drive None) reads as CK/DI low, CS high
        # (model choice: the schematic shows no pull resistors on these nets)
        self.ck, self.cs, self.di = 0, 1, 0
        self.do = 0
        self.trace = []                 # optional SPI transaction log: list of (cycles, 'R'|'W', addr, bytes)
        self.trace_on = False
        self.counts = {'ad1': 0, 'lpf': 0, 'ctf': 0}   # number of completed events (for the UI / tests)
        self._reset_state()
        gpio_f.on_output(PIN_CK, self._on_ck)
        gpio_f.on_output(PIN_CS, self._on_cs)
        gpio_f.on_output(PIN_DI, self._on_di)
        self._drive_do()

    # ------------------------------------------------------------------ reset / time
    def _reset_state(self):
        """Power-on or soft reset (DS p20 (7)): registers 0 (model choice), peak registers at their
        disabled values (DS p34), INTF cleared (DS p19 10.2 (7)), converters stopped."""
        self.reg = bytearray(0x40)
        self._peak_reset()
        self.pk_edge = None             # chip time of the last ENPKH 0 -> 1 edge (None: ENPKH = 0)
        self.gen_ad1 = getattr(self, 'gen_ad1', 0) + 1     # generation counters invalidate scheduled events
        self.gen_lpf = getattr(self, 'gen_lpf', 0) + 1
        self.gen_ctr = getattr(self, 'gen_ctr', 0) + 1
        self.gen_ad2 = getattr(self, 'gen_ad2', 0) + 1
        self.gen_arm = getattr(self, 'gen_arm', 0) + 1     # AD2 IRQ arming token (one pending event at most)
        self.ad1_period = None          # current AD1 period in seconds (None = stopped)
        self.lpf_period = None
        self.ad2_start = None           # chip time at which AD2 started (AD2F is evaluated lazily)
        self.ad2_seen = 0
        self.ad2_period = None
        self.ctr_state = 'off'          # off | waiting (no input signal) | counting | done
        self.ctr_info = {}
        self.last_ad1 = None            # last AD1 conversion: dict for the UI
        self._spi_reset()

    def _peak_reset(self):
        """ENPKH = 0: PKHMAX<18:0> = 40000h, PKHMIN<18:0> = 3FFFFh (DS p34 (1)), sign-extended to the 24-bit
        registers (DS p18 (5), (6): bits 23:19 equal bit 18)."""
        self._set24(0x11, 0xFC0000)
        self._set24(0x0E, 0x03FFFF)

    def _spi_reset(self):
        self.phase = 'idle'             # idle | cmd | blank | read | write
        self.nbits = 0
        self.shift = 0
        self.addr = 0
        self.out_byte = 0
        self.out_idx = 0
        self.out_pending = None         # register whose read side effect is due at the next rising CK edge
        self.frame = []                 # bytes of the current frame (trace)

    def now_s(self):
        """Chip time in seconds: the machine's exact emulated time (cycle count integrated over the core clock
        history, core.Machine.elapsed_s).  The HY3131 runs from its own crystal, independent of the MCU clock."""
        return float(self.m.elapsed_s())

    def _at(self, due_s, cb):
        """Call cb at chip time due_s.  The delay is converted to core cycles at the present core clock; if the
        clock changes while waiting and the event comes early, the remainder is rescheduled.  Periodic converters
        pass absolute due times, so lateness of one event (the run loop advances by whole basic blocks) does not
        accumulate."""
        def fire():
            rem = due_s - self.now_s()
            if rem * self.m.sysclk_hz >= 1.0:
                self.m.schedule(rem * self.m.sysclk_hz, fire)
            else:
                cb()
        self.m.schedule(max(1, round((due_s - self.now_s()) * self.m.sysclk_hz)), fire)

    def _clock_running(self):
        """SYSCLK present: ENOSC = 1 and ENXI = 0 (DS p20 (1), (2))."""
        return (self.reg[R33] & 0x20) and not (self.reg[R33] & 0x10)

    # ------------------------------------------------------------------ register helpers
    def _get24(self, a):
        """24-bit little-endian register group starting at a (DS p18 byte order <7:0>, <15:8>, <23:16>)."""
        return self.reg[a] | (self.reg[a + 1] << 8) | (self.reg[a + 2] << 16)

    def _set24(self, a, v):
        """Store a 24-bit value (two's complement for signed results) into registers a..a+2."""
        v &= 0xFFFFFF
        self.reg[a], self.reg[a + 1], self.reg[a + 2] = v & 0xFF, (v >> 8) & 0xFF, v >> 16

    def _log(self, text):
        """Event log line in the UI."""
        self.m.log.append((self.m.cycles, 'HY3131 ' + text))

    # ------------------------------------------------------------------ pins
    def _on_di(self, pin, level, cycles):
        """PF2 output change: level presented on DI, latched at the next rising CK edge."""
        self.di = 1 if level else 0

    def _on_cs(self, pin, level, cycles):
        """PF1 output change: frame start (low) or end (high); DO switches between SPI data and IRQ."""
        cs = 0 if level == 0 else 1
        if cs == self.cs:
            return
        self.cs = cs
        if cs == 0:                                 # frame start (DS p14 7.2 (1))
            if self.ck:
                self._log('CS fell while CK was high (DS p15 7.2 (6) requires CK low)')
            self._spi_reset()
            self.phase = 'cmd'
        else:                                       # frame end (DS p14 7.2 (2), (3))
            if self.trace_on and self.phase in ('read', 'write') and self.frame:
                self.trace.append((self.m.cycles, 'R' if self.phase == 'read' else 'W', self.frame_addr,
                                   bytes(self.frame)))
            self._spi_reset()
        self._drive_do()

    def _on_ck(self, pin, level, cycles):
        """PF0 output change: rising / falling CK edge while CS is low."""
        ck = 1 if level else 0
        if ck == self.ck:
            return
        self.ck = ck
        if self.cs:                                 # clocks are ignored while CS is high
            return
        if ck:
            self._ck_rise()
        else:
            self._ck_fall()

    def _ck_rise(self):
        """Rising CK edge: DI is latched (DS p14 timing figure)."""
        if self.out_pending is not None:            # first data bit of a loaded register is being clocked out
            self._read_side_effect(self.out_pending)
            self.frame.append(self.out_byte)
            self.out_pending = None
        b = self.di
        if self.phase == 'cmd':
            self.shift = (self.shift << 1) | b
            self.nbits += 1
            if self.nbits == 8:                     # address<6:0> + R/W (DS p14 7.2 (1))
                self.addr = self.shift >> 1
                self.frame_addr = self.addr
                self.phase = 'blank' if self.shift & 1 else 'write'
                self.nbits, self.shift = 0, 0
                self.blank_rose = False
        elif self.phase == 'blank':                 # 9th clock of a read carries no data (DS p14 7.2 (2))
            self.blank_rose = True
        elif self.phase == 'write':
            self.shift = (self.shift << 1) | b
            self.nbits += 1
            if self.nbits == 8:                     # one data byte, then address + 1 (DS p14 7.2 (3))
                self.frame.append(self.shift)
                self._write(self.addr, self.shift)
                self.addr = (self.addr + 1) & 0x7F
                self.nbits, self.shift = 0, 0

    def _ck_fall(self):
        """Falling CK edge: DO is updated (DS p14 timing figure, DS p15 7.2 (8))."""
        if self.phase == 'blank' and self.blank_rose:
            self.phase = 'read'
            self._load(self.addr)
        elif self.phase == 'read':
            self.out_idx += 1
            if self.out_idx == 8:                   # next address after 8 data bits (DS p14 7.2 (2))
                self.addr = (self.addr + 1) & 0x7F
                self._load(self.addr)
            else:
                self._drive_do()

    def _load(self, a):
        """Load register a into the output shift register and present its MSB on DO."""
        self.out_byte = self._read(a)
        self.out_idx = 0
        self.out_pending = a
        self._drive_do()

    def _drive_do(self):
        """DO pin: SPI data while CS is low, IRQ while CS is high (DS p15 7.2 (4))."""
        if self.cs:
            self._lazy_ad2()
            level = 1 if (self.reg[INTF] & self.reg[INTE] & 0x1F) else 0
        elif self.phase == 'read':
            level = (self.out_byte >> (7 - self.out_idx)) & 1
        else:
            level = 0                               # "XXX" in the DS p14 figures (model choice)
        if level != self.do:
            self.do = level
        self.g.set_input(PIN_DO, level)

    # ------------------------------------------------------------------ register file
    def _read(self, a):
        """Register value for an SPI read (side effects run when the byte is clocked out: _read_side_effect)."""
        if a >= 0x40:
            self._log(f'read of address 0x{a:02X} beyond the register file')
            return 0
        if 0x38 <= a <= 0x3F:
            self._log(f'read of undocumented register 0x{a:02X} (returns 0)')
            return 0
        if a == INTF:
            self._lazy_ad2()
        if a in (0x0E, 0x11):                       # first byte of PKHMIN / PKHMAX: bring the peaks up to date
            self._peak_update()
        if a == R37:
            return 0                                # test register (DS p17): reads 0 (model choice)
        return self.reg[a]

    def _read_side_effect(self, a):
        """Clear-on-read registers.  The datasheet says INTF is cleared "after INTF register is read"
        (DS p19 10.2 (7)) and CTBOV is cleared by reading CTSTA (DS p36 (8)).  Model choice: a register counts as
        read once its first bit has been clocked out (the rising CK edge after it was loaded), and only the bits
        that were in the byte returned are cleared, so an event arriving between the load and the clear is kept.
        (The 3-byte read at 0x1B, FW 0x0800BFFA, loads 0x1E after its last bit but never clocks it out.)"""
        if a == INTF:
            self.reg[INTF] &= ~self.out_byte & 0xFF
        elif a == CTSTA:
            self.reg[CTSTA] &= ~(self.out_byte & 0x01) & 0xFF

    def _write(self, a, v):
        """SPI write of one register (DS p17 register list, p18-19 and the function pages)."""
        if a >= 0x40 or 0x38 <= a <= 0x3F:
            self._log(f'write 0x{v:02X} to undocumented address 0x{a:02X} ignored')
            return
        if a <= 0x1A:                               # result/status registers are read only (DS p17)
            self._log(f'write 0x{v:02X} to read-only register 0x{a:02X} ignored')
            return
        if a == 0x1B:                               # CTA<7:0>: not SPI-writable (DS p36 (4), (5))
            return
        if a in (0x1C, 0x1D):                       # CTA<23:8>: SPI-writable only while ENCTR = 0 (DS p36 (5))
            if not (self.reg[R20] & 0x02):
                self.reg[a] = v
            return
        if a in (INTF, INTE):
            self._lazy_ad2()                        # AD2 conversions completed before this write
        if a == INTF:                               # write 0 clears, 1 has no effect (DS p19 10.2 (7))
            self.reg[INTF] &= v
            self._drive_do()
            return
        if a == R37:
            if v == 0x60:                           # soft reset (DS p20 (7))
                self._log('soft reset (0x60 written to 0x37)')
                self._reset_state()
                self._drive_do()
            return
        old = self.reg[a]
        self.reg[a] = v
        if a == INTE:
            self._drive_do()
            self._ad2_irq_arm()
        elif a == R20:
            self._r20_changed(old, v)
        elif a in (R22, R23, R33):
            self._ad1_reconfigure()
            self._lpf_reconfigure()
            if a == R33:
                self._ctr_reconfigure()
        elif a in (R26, R29):
            self._lpf_reconfigure()
            if a == R29 and not (v & 0x04):
                self._peak_reset()
                self.pk_edge = None
            elif a == R29 and not (old & 0x04):     # ENPKH 0 -> 1: tracking starts (DS p34 (3), (4))
                self.pk_edge = self.now_s()

    # ------------------------------------------------------------------ AD1
    def _ad1_rate_period(self):
        """AD1 output period in seconds, or None when AD1 is off (ENAD1, R23 bit 7, DS p30 (1))."""
        if not (self.reg[R23] & 0x80) or not self._clock_running():
            return None
        osr = OSR1[self.reg[R22] & 0x07]
        div = self.chop_rate_divisor if (self.reg[R22] >> 3) & 0x02 else 1
        return osr * 30 * div / self.f_sys          # (FSYSCLK / 30) / OSR1 (DS p31 (10), (11))

    def _ad1_reconfigure(self):
        p = self._ad1_rate_period()
        if p == self.ad1_period:
            return
        self.gen_ad1 += 1
        self.ad1_period = p
        if p is None:
            if not (self.reg[R23] & 0x80):
                self._set24(0x00, 0)                # ENAD1 = 0 clears AD1<23:0> (DS p30 (1))
            return
        gen = self.gen_ad1
        self.ad1_due = self.now_s() + p
        self._at(self.ad1_due, lambda: self._ad1_done(gen))

    def ad1_selection(self):
        """Current AD1 multiplexer and gain selection (DS p28, p30-31) as passed to the front end."""
        r = self.reg
        sad1i = r[R33] & 0x03
        if sad1i == 0:
            fp, fn = SAD1FP_PIN[r[R24] >> 4], SAD1FN_PIN[r[R24] & 0x07]
        elif sad1i == 1:
            fp, fn = SAD1I_PIN[1]
        else:
            fp, fn = 'TS1P' if sad1i == 2 else 'TS1N', 'TS2N' if sad1i == 2 else 'TS2P'
        rh, rl = SAD1RH_PIN[(r[R28] >> 4) & 0x07], SAD1RL_PIN[r[R28] & 0x07]
        return {'conv': 'AD1', 'fp': fp, 'fn': fn, 'rh': rh, 'rl': rl,
                'ig': AD1_IG[(r[R25] >> 4) & 0x03], 'rg': AD1_RG[(r[R23] >> 4) & 0x01],
                'dcos': AD1_DCOS[r[R22] >> 5], 'chop': (r[R22] >> 3) & 0x03,
                'scale': AD1_SCALE, 'rate': 1.0 / self.ad1_period if self.ad1_period else 0.0,
                'refo_from_pb6': bool(r[R30] & 0x80)}

    def _pin_volts(self, pins, name, sel):
        """Voltage of a selected node.  REFO is the buffered PB<6> when SREFO = 1 (DS p23 (4), (10)); with
        SREFO = 0 it is the internal band gap, "approximate 1.2V" (DS p23 (3)), which has no exact value and must
        then come from the front end."""
        if name == 'REFO' and sel['refo_from_pb6'] and 'REFO' not in pins:
            name = 'PB6'
        if name not in pins:
            return None
        return pins[name]

    def ad1_comb_gain(self, f, osr=None):
        """|H(f)| of the AD1 sinc^2 comb at the present (or the given) OSR1 (module docstring, DS p30, p31 (10),
        (11)).  1 at DC; 0 at every multiple of the output rate AD1CLK / OSR1."""
        r = osr or OSR1[self.reg[R22] & 0x07]
        x = math.pi * f / (self.f_sys / 30.0)
        s = math.sin(x)
        if abs(s) < 1e-300:                         # f = k * AD1CLK: the comb passes it like DC
            return 1.0
        return (math.sin(r * x) / (r * s)) ** 2

    def _ad1_ac(self, sel, t, info):
        """Contribution of the front end's AC components to the conversion completing at chip time t: the sinc^2
        comb output over its window, sum of peak |H(f)| sin(2 pi f (t - (R - 1) / AD1CLK) + phase) (module
        docstring).  With AD1CHOP = 1x nothing is added and the reason goes to info['ac_error']."""
        fn = getattr(self.frontend, 'ac_components', None)
        comps = fn(sel, t) if fn is not None else None
        if not comps:
            return 0.0
        if sel['chop'] & 0x02:
            info['ac_error'] = ('AC component not converted: AD1CHOP = 1x, the chopped comb response is not stated '
                                '(DS p30 (2))')
            return 0.0
        r = OSR1[self.reg[R22] & 0x07]
        tc = t - (r - 1) / (self.f_sys / 30.0)      # centre of the triangular window (linear-phase delay)
        v = sum(a * self.ad1_comb_gain(f, r) * math.sin(2.0 * math.pi * f * tc + ph) for a, f, ph in comps)
        info['ac'] = v
        return v

    def _ad1_done(self, gen):
        """One AD1 conversion completed: compute the code, store AD1<23:0>, raise AD1F (DS p31 (12), (13))."""
        if gen != self.gen_ad1:
            return
        t = self.now_s()
        sel = self.ad1_selection()
        pins = self.frontend.pins(sel, t)
        vals = [self._pin_volts(pins, sel[k], sel) if sel[k] else None for k in ('fp', 'fn', 'rh', 'rl')]
        info = {'t': t, 'sel': {k: sel[k] for k in ('fp', 'fn', 'rh', 'rl', 'ig', 'rg')}}
        if None in vals or vals[2] == vals[3]:
            # a selected node has no voltage from the front end (or the reference is zero): the chip
            # model has nothing to convert; the code is held at 0 and the cause is shown in snapshot()
            code = 0
            if None in vals:
                info['error'] = 'no voltage for ' + ', '.join(
                    sel[k] or 'X' for k, v in zip(('fp', 'fn', 'rh', 'rl'), vals) if v is None)
            else:
                info['error'] = 'zero reference'
        else:
            vin, vr = vals[0] - vals[1], vals[2] - vals[3]
            vin += self._ad1_ac(sel, t, info)
            nz = self.frontend.noise(sel) if self.noise else {}
            if nz.get('vin_sigma'):
                vin += self.rng.gauss(0.0, nz['vin_sigma'])
            if nz.get('vref_sigma'):
                vr += self.rng.gauss(0.0, nz['vref_sigma'])
            x = (sel['ig'] * vin / (sel['rg'] * vr) + sel['dcos'] / sel['rg']) * AD1_SCALE   # DS p31
            if sel['chop'] == 0:                    # VX + VOS (DS p30 table)
                x += self.vos_codes
            elif sel['chop'] == 1:                  # VX - VOS
                x -= self.vos_codes
            if self.zero_drift_counts_per_c and self.delta_t_c:     # DS p12 zero drift (typ 0)
                rpc = self.frontend.noise(sel).get('raw_per_count', 0.0)
                x += self.zero_drift_counts_per_c * self.delta_t_c * rpc
            if nz.get('code_sigma'):
                x += self.rng.gauss(0.0, nz['code_sigma'])
            if not math.isfinite(x):                # e.g. an infinite input: held at the register limit (model, UNPROVEN)
                x = AD1_MAX if x > 0 else AD1_MIN
            code = max(AD1_MIN, min(AD1_MAX, int(math.floor(x + 0.5))))
            info.update(vin=vin, vref=vr, ideal=x)
        self._set24(0x00, code & 0xFFFFFF)          # 24-bit two's complement (DS p18 (1))
        info['code'] = code
        self.last_ad1 = info
        self.counts['ad1'] += 1
        self._raise(AD1F)
        self.ad1_due += self.ad1_period
        self._at(self.ad1_due, lambda: self._ad1_done(gen))

    # ------------------------------------------------------------------ AD2 / LPF / RMS (timing only)
    def _ad2_period(self):
        """AD2 output period (DS p33 (5), (6)) or None when ENAD2 = 0 (DS p33 (1)); ENCHOPAD2 uses the same
        "one time slower" divisor as AD1 (DS p32 (2), UNPROVEN meaning)."""
        r26 = self.reg[R26]
        if not (r26 & 0x80) or not self._clock_running():
            return None
        fclk = self.f_sys / (4 if r26 & 0x08 else 2)
        div = self.chop_rate_divisor if r26 & 0x20 else 1
        return OSR2[r26 & 0x07] * div / fclk

    def _lpf_reconfigure(self):
        """(Re)start the AD2 timebase and the LPF/RMS output timer (DS p34: LPF rate = AD2 rate / OSR4,
        RMS rate = LPF rate).  ENLPF = 0 clears LPF, ENRMS = 0 clears RMS, ENAD2 = 0 clears AD2."""
        p2 = self._ad2_period()
        self._lazy_ad2()                            # count conversions completed under the old timebase
        if p2 != self.ad2_period:
            self.ad2_period = p2
            self.gen_ad2 += 1
            self.ad2_start = self.now_s() if p2 else None
            self.ad2_seen = 0
            if p2 is None:
                self._set24(0x03, 0)                # DS p33 (1)
            self._ad2_irq_arm()
        r29 = self.reg[R29]
        if not (r29 & 0x40):
            self._set24(0x06, 0)                    # ENLPF = 0 clears LPF (DS p34 LPF (1))
        if not (r29 & 0x80):
            for a in range(0x09, 0x0E):             # ENRMS = 0 clears RMS (DS p34 RMS (1))
                self.reg[a] = 0
        p = p2 * OSR4[(r29 >> 3) & 0x07] if (p2 and r29 & 0xC0) else None
        if p == self.lpf_period:
            return
        self.gen_lpf += 1
        self.lpf_period = p
        if p is not None:
            gen = self.gen_lpf
            self.lpf_due = self.now_s() + p
            self._at(self.lpf_due, lambda: self._lpf_done(gen))

    def _lpf_done(self, gen):
        """LPF / RMS output event: raise LPFF (ENLPF) and RMSF (ENRMS) (DS p34).  Data not modelled."""
        if gen != self.gen_lpf:
            return
        r29 = self.reg[R29]
        self.counts['lpf'] += 1
        self._raise((LPFF if r29 & 0x40 else 0) | (RMSF if r29 & 0x80 else 0))
        self.lpf_due += self.lpf_period
        self._at(self.lpf_due, lambda: self._lpf_done(gen))

    def _lazy_ad2(self):
        """AD2F is set by every AD2 conversion (DS p33 (8)).  Conversions are counted from the elapsed chip time
        when INTF or the IRQ line is evaluated instead of scheduling an event per conversion (up to 76 800/s)."""
        if self.ad2_period is None:
            return
        n = int((self.now_s() - self.ad2_start) / self.ad2_period)
        if n > self.ad2_seen:
            self.ad2_seen = n
            self.reg[INTF] |= AD2F

    def _ad2_irq_arm(self):
        """With AD2IE set the IRQ line must rise at the next AD2 conversion: schedule exactly that event."""
        self.gen_arm += 1                           # any earlier arming event becomes stale
        if self.ad2_period is None or not (self.reg[INTE] & AD2F):
            return
        gen = self.gen_arm
        t = self.now_s()
        nxt = self.ad2_start + (int((t - self.ad2_start) / self.ad2_period) + 1) * self.ad2_period

        def fire():
            if gen == self.gen_arm:
                self._drive_do()
                self._ad2_irq_arm()
        self._at(nxt, fire)

    # ------------------------------------------------------------------ peak detector (DS p34-35)
    def _peak_update(self):
        """With ENPKH = 1, PKHMAX / PKHMIN hold the maximum / minimum of the selected source since the last
        ENPKH 0 -> 1 edge (DS p34 (3), (4)).  Source PKHSEL = 00 is AD2<18:0> (DS p35 table), the only one the
        firmware selects (spec 3, misc 7.1).  The AD2 transfer is not in the datasheet, so the extremes of the AD2
        code come from the front end (ad2_extremes(t); the calibrated backend derives them from the peak record,
        misc 7.4); they count once at least one AD2 conversion has completed since the edge.  The sampling of the
        waveform by AD2 is not modelled (PKHMAX update granularity is UNPROVEN, misc UNPROVEN list).  Other
        PKHSEL sources keep the reset values (logged once)."""
        r29 = self.reg[R29]
        if not (r29 & 0x04) or self.pk_edge is None or self.ad2_period is None:
            return
        if r29 & 0x03:
            if not getattr(self, '_pk_src_logged', False):
                self._log(f'peak source PKHSEL={r29 & 3} not modelled (only AD2, PKHSEL = 00)')
                self._pk_src_logged = True
            return
        t = self.now_s()
        fn = getattr(self.frontend, 'ad2_extremes', None)
        ext = fn(t) if fn is not None and t - self.pk_edge >= self.ad2_period else None
        if ext is None:
            return
        sx = lambda v: v - CTA_MOD if v & 0x800000 else v
        mx = max(-0x40000, min(0x3FFFF, int(ext[0])))     # AD2<18:0> range (DS p18 (5), (6))
        mn = max(-0x40000, min(0x3FFFF, int(ext[1])))
        self._set24(0x11, max(sx(self._get24(0x11)), mx))   # stored sign-extended to 24 bits (DS p18 (5), (6))
        self._set24(0x0E, min(sx(self._get24(0x0E)), mn))

    def peak_sample(self):
        """Called by the front end before its signal changes: the extremes of the ending signal are kept."""
        self._peak_update()

    # ------------------------------------------------------------------ frequency counter
    def _ctr_source(self):
        """Counter input: ENCNTI = 1 -> PCNTI (CNT pin buffer), 0 -> ACPO (comparator, input SCMPI) (DS p36 (2))."""
        r20 = self.reg[R20]
        return 'CNT' if r20 & 0x08 else 'CMP:' + SCMPI_NAME[r20 >> 5]

    def _ctr_source_enabled(self):
        """The comparator works only with ENCMP = 1 (R20 bit 4, DS p26 (5)); the CNT buffer is enabled by ENCNTI
        itself (DS p37 CNT pin (1))."""
        r20 = self.reg[R20]
        return bool(r20 & 0x08) or bool(r20 & 0x10)

    def _r20_changed(self, old, new):
        """R20 write: ENCTR (bit 1) starts or clears the counter, ENCNTI (bit 3) changes its input (DS p36)."""
        if (old ^ new) & 0x02:
            if new & 0x02:
                self._ctr_start()
            else:                                   # ENCTR = 0 clears CTA<7:0>, CTB, CTC, CTBOV (DS p36 (1), (4), (5))
                self.gen_ctr += 1
                self.ctr_state = 'off'
                self.reg[0x1B] = 0
                self._set24(0x18, 0)
                self._set24(0x15, 0)
                self.reg[CTSTA] &= ~0x01 & 0xFF
        elif (old ^ new) & 0x18 and new & 0x02:     # input source or comparator enable changed while counting
            self._ctr_start()

    def _ctr_reconfigure(self):
        """Clock configuration changed (R33): restart a counter that is enabled and not finished."""
        if self.reg[R20] & 0x02 and self.ctr_state in ('waiting', 'counting'):
            self._ctr_start()

    def input_changed(self):
        """Called by the front end when its stimulus changes: a waiting counter starts now; a running count is
        restarted with the new signal (or stops waiting for edges if the signal was removed)."""
        if self.ctr_state in ('waiting', 'counting'):
            self._ctr_start()

    def _ctr_start(self):
        """Counting sequence of DS p36-37:
        - Gate: CTA counts SYSCLK from CTA_initial; the gate is (1000000h - CTA_initial) / FSYSCLK.
        - After CTA overflows, counting continues until CTB holds a whole number of input cycles, then stops and
          CTF is raised (DS p36 step (3)); CTB = whole cycles, CTC = SYSCLK ticks with the input high (DS p36 (6),
          (7)).
        - The datasheet results "Frequency = CTB / T, T = [1000000h - CTA_initial + CTA_final] / FSYSCLK" and
          "Duty = CTC / [...]" (DS p37 (8)) are exact only if CTA and CTB start and stop on the same input edge, so
          the model starts counting at the first rising input edge after ENCTR = 1 and stops at the first rising
          edge after the CTA overflow (edge alignment inferred from that formula, not stated: spec 4.3 UNPROVEN).
        - The input waveform comes from the front end as (frequency, duty, epoch): rising edges at
          epoch + k / frequency.  No signal: the counter waits and CTF never sets (spec 4.3).
        - CTBOV is set when CTB overflows 24 bits (DS p36 (8))."""
        self.gen_ctr += 1
        gen = self.gen_ctr
        if not self._clock_running():
            self.ctr_state = 'waiting'
            return
        t = self.now_s()
        src = self._ctr_source()
        sig = self.frontend.counter_input(src, t) if self._ctr_source_enabled() else None
        cta0 = self._get24(0x1B) & 0xFFFF00          # CTA<7:0> is 0 while ENCTR was 0 (DS p36 (4))
        if not sig or not 0 < sig[0] < math.inf:
            self.ctr_state = 'waiting'
            self.ctr_info = {'source': src, 'cta_initial': cta0}
            return
        f, duty, epoch = sig
        per = 1.0 / f
        k0 = math.ceil((t - epoch) / per)
        t_start = epoch + k0 * per                  # first rising edge at or after ENCTR = 1
        gate_ticks = CTA_MOD - cta0
        n = max(1, math.ceil(gate_ticks * f / self.f_sys - 1e-12))   # whole cycles to the edge after overflow
        t_ticks = int(round(n * self.f_sys / f))
        info = {'source': src, 'cta_initial': cta0, 'freq': f, 'duty': duty, 'n': n, 'ticks': t_ticks}
        self.ctr_state = 'counting'
        self.ctr_info = info

        def done():
            if gen != self.gen_ctr:
                return
            self._set24(0x1B, (cta0 + t_ticks) % CTA_MOD)          # CTA_final
            self._set24(0x18, n % CTA_MOD)                          # CTB
            self._set24(0x15, int(round(t_ticks * duty)) % CTA_MOD) # CTC (SYSCLK ticks while high)
            if n >= CTA_MOD:
                self.reg[CTSTA] |= 0x01                             # CTBOV
            self.ctr_state = 'done'                                 # "Ceased counting" (DS p37 (5))
            self.counts['ctf'] += 1
            self._raise(CTF)
        self._at(t_start + n * per, done)

    # ------------------------------------------------------------------ interrupts
    def _raise(self, bits):
        """Set INTF bits (DS p19 10.2 (8)) and update the IRQ output."""
        if bits:
            self.reg[INTF] |= bits
            if self.cs:
                self._drive_do()

    # ------------------------------------------------------------------ UI
    def snapshot(self):
        """State summary for the UI."""
        a = self.last_ad1 or {}
        return {
            'regs': self.reg[0x20:0x34].hex(' '),
            'intf': self.reg[INTF], 'inte': self.reg[INTE],
            'ad1_sps': (1.0 / self.ad1_period) if self.ad1_period else 0.0,
            'ad1_code': a.get('code'), 'ad1_error': a.get('error'),
            'ad1_sel': a.get('sel'),
            'ad1_ac_volts': a.get('ac'), 'ad1_ac_error': a.get('ac_error'),
            'lpf_rms_hz': (1.0 / self.lpf_period) if self.lpf_period else 0.0,
            'counter': self.ctr_state, 'counter_info': self.ctr_info,
            'events': dict(self.counts),
            'not_modelled': 'AD2/LPF/RMS data registers (no AD2 transfer function in the datasheet); their flags '
                            'run at the datasheet cadence; the peak registers hold the AD2 extremes from the front end',
        }
