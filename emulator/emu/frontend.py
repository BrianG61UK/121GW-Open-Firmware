"""Meter front end for the HY3131 model: turns the user's stimulus at the test jacks into the voltages at the
HY3131 pins (and the signal at its counter input).

Two backends, chosen at construction with make_frontend(kind, ...):

(a) "netlist"     NetlistFrontend: solves analysis/frontend_netlist.cir with ngspice (emu/spice.py).  What the
                  netlist must provide is listed in the class docstring; a missing netlist, library, element or
                  undefined node is reported (FrontendUnavailable) instead of being replaced by anything else.
(b) "calibrated"  CalibratedFrontend: a perfectly calibrated unit.  By construction of the firmware's calibration
                  (spec 7.2) the averaged AD1 result of such a unit is raw = D * g + offset, with D the true value
                  in display counts and offset / g the EEPROM record of the active mode and range (spec 5.1, 5.4).
                  The backend computes that raw value from the stimulus and returns the pin voltages that make the
                  chip's transfer formula (DS p31) produce it.  It is the reference used to validate (a).

Sources: DS = HY3131 datasheet DS-HY3131-V10_EN (page), spec = analysis/hy3131_model.md (section),
misc = analysis/hy3131_modes_misc.md, acc = analysis/hy3131_modes_ac_current.md (section),
FW = original application image address, ADR3412 = Analog Devices ADR3412/ADR3420/ADR3425/ADR3430/ADR3433/
ADR3440/ADR3450 data sheet Rev. C, Table 3 "ADR3412 Electrical Characteristics" (page 3), MAN = 121GW user manual
(specification tables), SCH = 121GW circuit diagram.

Stimulus (set_stimulus): {'kind': k, 'value': x, 'ac': bool, 'freq': Hz, 'duty': 0..1, 'width': s, 'dc': V,
                          'amps': A, 'board': degC or None}
    kind 'V'      volts: the DC value, or with ac the RMS of a sine of `freq` Hz plus the DC component 'dc'
    kind 'A'      amperes (DC, or RMS of a sine with ac), entering through the plugged current jack (A or mA)
    kind 'ohm'    resistance (also continuity in BEEP)
    kind 'Hz'     a signal of `value` Hz at the counter input; duty = high fraction, or 'width' = high time in s
                  (overrides duty when > 0)
    kind 'F'      capacitance in farads
    kind 'degC'   thermocouple (hot junction) temperature
    kind 'diode'  forward voltage of the device under test in volts
    kind 'VA'     voltage `value` and current 'amps' at the same time (both RMS with ac)
    duty          high fraction of the signal at the counter input (default 0.5)
    board         board temperature at the cold junction (degC); the application derives the PA4 thermistor
                  voltage from it.  None: the board temperature follows the PA4 voltage.

Noise (both backends, per AD1 conversion, drawn by the chip with its seedable RNG):
- Reference: ADR3412 output noise density 0.6 uV/sqrt(Hz) typ at 1 kHz (ADR3412 Table 3), integrated over the
  Nyquist band of the AD1 output samples (rate / 2).  The integration band is a design choice; the 0.1-10 Hz
  figure (8 uV p-p typ) is not used because the datasheet gives no p-p to rms conversion.
- Unspecified converter / front-end noise: the HY3131 datasheet states no noise figure (only the zero reading
  -1..+1 count at 5 sps, DS p12; spec 6).  NOISE_COUNTS (default 0.5 display count sigma per sample) is a design
  choice, as proposed in spec 6: it is converted to raw LSB with the active record's gain g.
- Resistor thermal noise: ngspice noise analysis in backend (a) only.
- AD1 zero drift and linearity: DS p12 gives bounds only (drift typ 0; linearity max +-(0.01 % + 2 counts) with
  no transfer curve), so nothing is added; the chip exposes the drift as a parameter (typ 0).
"""
import math
import os
import struct

from .hy3131 import AD1_SCALE, AD1_MAX

VREF_ADR3412 = 1.2000          # V, ADR3412 Table 3 "OUTPUT VOLTAGE" typ (min 1.1988, max 1.2012)
EN_ADR3412 = 0.6e-6            # V/sqrt(Hz), ADR3412 Table 3 "OUTPUT VOLTAGE NOISE DENSITY" typ at 1 kHz
NOISE_COUNTS = 0.5             # display counts sigma per AD1 sample: design choice (spec 6), not a datasheet value

# Firmware RAM / flash locations (spec 5.1, 5.2; analysis/verified_names.txt)
RAM_MODE, RAM_RANGE = 0x2000803C, 0x2000803D       # meter_mode, meter_range
RAM_LOWZ_AC = 0x20008098                           # LowZ variant flag: 0 = DC chain (spec 4.2, 5.1)
CAL_TABLE = 0x08028EE8                             # u16 table[mode] of EEPROM record bases (FW 0x0801167C)

MODE_NAMES = ['LowZ', 'DCV', 'ACV', 'DCmV', 'ACmV', 'TEMP', 'FREQ', 'PULSE', 'DUTY', 'OHM', 'BEEP', 'DIODE',
              'CAP', 'uVA', 'mVA', 'VA', 'ACuA', 'DCuA', 'ACmA', 'DCmA', 'ACA', 'DCA', 'DCuVA', 'DCmVA',
              'DCVA']                               # spec 2.1 / 4.2 mode numbering

# Modes whose firmware value chain is derived (spec 5.6) -> (stimulus kind, {range: (decimals, unit in SI)}).
# Decimals: spec 5.3 (function 0x0800D920 run per mode/range); LowZ: 0x0800D920 returns 1 for mode 0
# (decompiled branch at 0x0800DA0E).  Units: spec 5.3 / manual ranges.
DERIVED = {
    1: ('V', {0: (4, 1.0), 1: (3, 1.0), 2: (2, 1.0), 3: (1, 1.0)}),                 # DCV 5/50/500/600 V
    3: ('V', {0: (3, 1e-3), 1: (2, 1e-3)}),                                         # DCmV 50/500 mV
    9: ('ohm', {0: (3, 1.0), 1: (2, 1.0), 2: (4, 1e3), 3: (3, 1e3), 4: (2, 1e3)}),  # OHM 50 ohm .. 500 kohm
    0: ('V', {0: (1, 1.0)}),                                                        # LowZ DC variant only
}
# Conditions the calibrated backend still cannot derive, by firmware mode (shown in the UI as the status reason).
_AC_IN_DC = ('AC stimulus in DC mode {}: the AD1 comb-filter response to AC is not specified by the datasheet (DS p13 '
             'gives NMRR at 5/10 sps only); a reading of the DC component is stated only for the DCV rows (acc 10.4)')
UNSUPPORTED_WHY = {m: _AC_IN_DC.format(MODE_NAMES[m]) for m in (3, 17, 19, 21, 22, 23, 24)}
for _m in (2, 4):
    UNSUPPORTED_WHY[_m] = (f'{MODE_NAMES[_m]} PEAK with a DC component: the AD2 input path (OP1O against PB<3>) and '
                           'its coupling are not derived (misc 7, UNPROVEN list: AD2 code per volt)')
FILTER_WHY = ('1 kHz filter: the analog response is derived only for 20..6000 Hz, the span of the firmware table '
              '0x0802501C (acc 5.5); outside it the firmware returns the x10 value (F < 20, defect D4) or 0, which '
              'gives no response to invert')
BD_LEAD_WHY = ('bdOn burden-voltage channel: the manual measures it through an extra lead from the current jack to the '
               'V jack (MAN, burden voltage section); plug the V jack')
# FREQ: the counter is digital; the chip model implements the datasheet counter (DS p36-37) and the firmware
# formula is spec 4.3.  The front end presents the stimulus frequency at the selected counter input.
COUNTER_MODES = {6}
STIM_KINDS = ('V', 'ohm', 'A', 'Hz', 'F', 'degC', 'diode', 'VA')     # module docstring

# ---- calibrated backend: firmware RAM read (never written), sections of spec / misc / acc as cited ----
# Calibration data is taken from the EEPROM with the record rules of 0x0801167C (spec 5.1, acc 5.1, 7.7, VA.3, misc
# 6.1), not from its RAM copies (0x20007E00 ...): the firmware writes a new configuration row, including a counter
# restart with delay(10000) (spec 3), before it loads the new record, so conversions in between would see a stale copy.
EE_R6_W = 0x178                                         # OHM r6 correction weight, i32 BE, valid -3000..3000 (misc 6.1)
EE_CUR_ZERO = {16: 0x4D0, 17: 0x4D8, 18: 0x4E0, 19: 0x4E8, 20: 0x4F0, 21: 0x4F8}   # marker 0xA5 + i32 BE (acc 7.7)
RAM_FREQ_REF = 0x20007E18                               # counter reference 10 x SYSCLK, u32 (misc 5.2)
RAM_PRESET = 0x2000001C                                 # counter preset word, CTA<23:8> (misc 0)
RAM_FR, RAM_FR_ACDC = 0x2000803E, 0x200080A0            # frequency range byte (acc 3) and its AC+DC copy (acc 5.1)
RAM_FLAG87 = 0x20008087                                 # ACV r0 CORR70 enable (acc 5.4)
RAM_CALMODE = 0x2000808A                                # calibration mode (acc 4)
RAM_BURDEN = 0x200080A5                                 # bdOn burden-voltage display (acc 7.8)
RAM_DIODE15 = 0x200080B3                                # DIODE 15 V (misc 6.3)
RAM_PEAK, RAM_FILTER = 0x200080B7, 0x200080B9           # peak_hold, filter_1kHz (spec 3)
RAM_ACDC, RAM_ACDC_PHASE = 0x200080BA, 0x200080BD       # AC+DC active, phase 0 AC / 1 DC (acc 7.4)
RAM_VA_CH, RAM_C6, RAM_C7 = 0x200080C4, 0x200080C6, 0x200080C7   # va_channel, voltage / current sub-range (acc VA.2)
RAM_CUR_OL, RAM_JACK_CODE = 0x200080CB, 0x200080CC      # VA current overload, PE10/PE11 code (acc VA.5)
RAM_PF8, RAM_R6FLAG = 0x20007FDF, 0x20007FE0            # PF8 strap, OHM r6 flag (misc 3.2)
CTA_RANGE = 1 << 24                                     # CTA counts to 1000000h (DS p36)

# Display count exponents: count = quantity x 10^e in volts / ohms / farads / amperes (spec 5.3, misc 5.5, acc 9)
VOLT_EXP = {0: {0: 1}, 1: {0: 4, 1: 3, 2: 2, 3: 1}, 2: {0: 4, 1: 3, 2: 2, 3: 1}, 3: {0: 6, 1: 5}, 4: {0: 6, 1: 5}}
OHM_EXP = {0: 3, 1: 2, 2: 1, 3: 0, 4: -1, 5: -2, 6: -3}
CAP_EXP = {0: 12, 1: 11, 2: 10, 3: 9, 4: 8, 5: 6}
CUR_EXP = {16: (9, 8), 17: (9, 8), 18: (7, 6), 19: (7, 6), 20: (5, 4, 3), 21: (5, 4, 3)}
VA_I_EXP = {13: (9, 8), 22: (9, 8), 14: (7, 6), 23: (7, 6), 15: (5, 3), 24: (5, 3)}   # by c7 = 0 / != 0 (VA.7)
BURDEN_OHM = {16: 100.0, 17: 100.0, 18: 2.0, 19: 2.0, 20: 0.03, 21: 0.03}  # MAN current table: burden voltage
PLAN_OF = {0: '_plan_volt', 1: '_plan_volt', 2: '_plan_volt', 3: '_plan_volt', 4: '_plan_volt', 5: '_plan_temp',
           6: '_plan_counter', 7: '_plan_counter', 8: '_plan_counter', 9: '_plan_ohm', 10: '_plan_ohm',
           11: '_plan_diode', 12: '_plan_cap'}
PLAN_OF.update({m: '_plan_current' for m in range(16, 22)})
PLAN_OF.update({m: '_plan_va' for m in (13, 14, 15, 22, 23, 24)})

# Thermistor table 0x08028DD0 entries 0..23 (u16, entry k = 500 k - 3000 in 0.01 degC; misc 4.2); 0x08013AAC
# accepts 518..3672, i.e. -25.00 .. 85.00 degC
TH_TABLE = (3758, 3672, 3570, 3451, 3315, 3163, 2997, 2819, 2631, 2437, 2242, 2048, 1859, 1678, 1508, 1349, 1203,
            1070, 950, 842, 746, 661, 585, 518)
TH_TMIN, TH_TMAX = -2500, 8500
TC_TABLE = 0x08025CF8                                   # 158 x i32 thermocouple EMF in uV at 10 k - 210 degC (misc 4.1)
TC_MIN_C, TC_MAX_C = -210.0, 1360.0
# CORR tables X (address, words per row) by idx (acc 5.2)
CORR_X = {0: (0x08028A18, 9), 1: (0x08028A60, 9), 4: (0x08028E08, 7), 5: (0x08028E40, 7), 6: (0x08028E78, 7),
          7: (0x08028EB0, 7)}
# VA burden-correction tables B by (mode, range): (0x20007FDF = 0, 0x20007FDF = 1); mode 24 r2 / 7FDF = 1 by b2
# (acc VA.5); 0x080283C4 and 0x080284C0 have 7 words per row, the others 8
VA_B = {(13, 0): (0x080260E4, 0x08026204), (13, 1): (0x08026324, 0x08026444), (13, 2): (0x08026564, 0x08026684),
        (13, 3): (0x080267A4, 0x080268C4), (14, 0): (0x080269E4, 0x08026B04), (14, 1): (0x08026C24, 0x08026D44),
        (14, 2): (0x08026E64, 0x08026F84), (14, 3): (0x080270A4, 0x080271C4), (15, 0): (0x080272E4, 0x08027404),
        (15, 1): (0x08027524, 0x08027644), (15, 2): (0x080283C4, 0x08027764), (15, 3): (0x080284C0, 0x08027884),
        (24, 0): (0x080279A4, 0x08027AC4), (24, 1): (0x08027BE4, 0x08027D04),
        (24, 2): (0x08027E24, (0x08027F44, 0x08028064)), (24, 3): (0x08028184, 0x080282A4)}
# DC VA current offset K of 0x080087F8 (acc VA.6): (V >= 0, Ds > 0), (V < 0, Ds > 0), (V >= 0, Ds < 0), (V < 0, Ds < 0)
VA_K = {(22, 0): (200, 200, -200, -300), (22, 1): (2100, 2100, -2100, -2100), (22, 2): (130, 130, -170, -170),
        (22, 3): (2110, 2110, -2130, -2140), (23, 0): (130, 132, -71, -70), (23, 1): (1583, 1605, -1548, -1529),
        (23, 2): (82, 83, -120, -120), (23, 3): (1537, 1566, -1606, -1578), (24, 0): (128, 131, -65, -65),
        (24, 1): (1559, 1581, -1517, -1499), (24, 2): (5, 12, -16, -18), (24, 3): (156, 160, -161, -159)}


# ---- integer and float32 arithmetic of the original image's runtime (acc 5 notation; misc 4.1 helper list) ----
def _f32(x):
    """Round a double to float32 (an operation on two float32 operands done in double and rounded once gives the
    float32 result for + - * /)."""
    try:
        return struct.unpack('<f', struct.pack('<f', x))[0]
    except OverflowError:
        return math.copysign(math.inf, x)


def _i2f(i):
    return _f32(float(i))


def _fdiv(a, b):
    return _f32(a / b)


def _fmul(a, b):
    return _f32(a * b)


def _fadd(a, b):
    return _f32(a + b)


def _fsub(a, b):
    return _f32(a - b)


def _f2iz(x):
    """float to int, truncation toward zero (0x08013370)."""
    return int(x)


def _rnd(v):
    """RND(v) = trunc((double)v + 0.5) (f2d, dadd 0.5, d2iz)."""
    return int(v + 0.5)


def _s32(x):
    """Wrap to a signed 32-bit integer (register arithmetic)."""
    return ((x + 0x80000000) & 0xFFFFFFFF) - 0x80000000


def _sdiv(a, b):
    """C signed division, truncation toward zero (sdiv)."""
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


class FrontendUnavailable(RuntimeError):
    pass


class _Base:
    """Shared stimulus handling, firmware state access and counter input."""
    kind = 'base'

    def __init__(self, machine, noise_counts=NOISE_COUNTS):
        self.m = machine
        self.chip = None
        self.board = None              # emu.board.Board, set by the application (dial position)
        self.noise_counts = noise_counts
        self.stim = {'kind': 'V', 'value': 0.0, 'ac': False, 'freq': 0.0, 'duty': 0.5, 'width': 0.0, 'dc': 0.0,
                     'amps': 0.0, 'board': None}
        self.stim_epoch = 0.0          # chip time at which the current signal started (counter edge phase)

    def attach(self, chip):
        self.chip = chip

    def set_stimulus(self, s):
        """Validate and store the stimulus (module docstring); notify the chip (a waiting counter may start, the
        peak detector takes the extremes of the signal that ends now)."""
        kind = s.get('kind', self.stim['kind'])
        if kind not in STIM_KINDS:
            raise ValueError(f'unknown stimulus kind {kind}')
        b = s.get('board', self.stim.get('board'))
        st = {'kind': kind, 'value': float(s.get('value', 0.0)), 'ac': bool(s.get('ac', False)),
              'freq': float(s.get('freq', 0.0) or 0.0), 'duty': float(s.get('duty', 0.5)),
              'width': float(s.get('width', 0.0) or 0.0), 'dc': float(s.get('dc', 0.0) or 0.0),
              'amps': float(s.get('amps', 0.0) or 0.0), 'board': None if b is None else float(b)}
        if kind == 'Hz':
            st['ac'], st['freq'] = True, st['value']
        if kind in ('ohm', 'F', 'degC', 'diode', 'Hz'):
            st['ac'] = kind == 'Hz'
        if not all(math.isfinite(st[k]) for k in ('value', 'freq', 'duty', 'width', 'dc', 'amps')) or \
                (st['board'] is not None and not math.isfinite(st['board'])):
            raise ValueError('stimulus values must be finite numbers')
        if st['width'] < 0:
            raise ValueError('pulse width must not be negative')
        if st['width'] > 0:
            if st['freq'] <= 0:
                raise ValueError('a pulse width needs a frequency')
            st['duty'] = st['width'] * st['freq']
        if not 0.0 < st['duty'] < 1.0:
            raise ValueError('duty (or width x frequency) must be between 0 and 1')
        if st['freq'] < 0:
            raise ValueError('frequency must not be negative')
        if kind in ('ohm', 'F') and st['value'] < 0:
            raise ValueError('resistance / capacitance must not be negative')
        if st['ac'] and kind in ('V', 'A', 'VA') and (st['value'] < 0 or st['amps'] < 0):
            raise ValueError('an AC (RMS) value must not be negative')
        old = self.stim
        if self.chip is not None and hasattr(self.chip, 'peak_sample'):
            self.chip.peak_sample()
        self.stim = st
        if self.chip is not None:
            if (old['ac'], old['freq']) != (st['ac'], st['freq']):
                self.stim_epoch = self.chip.now_s()  # a new signal starts now; same signal keeps its phase
            self.chip.input_changed()

    # firmware state, read-only (spec 5.2: follow meter_mode / meter_range at each conversion)
    def _ram8(self, a):
        """One byte of emulated RAM (read only)."""
        return self.m.uc.mem_read(a, 1)[0]

    def fw_mode_range(self):
        """Firmware mode and range bytes (meter_mode 0x2000803C, meter_range 0x2000803D)."""
        return self._ram8(RAM_MODE), self._ram8(RAM_RANGE)

    def cal_record(self, mode, rng):
        """EEPROM record (offset i32, gain g) of mode/range: R = u16 table 0x08028EE8[mode] + 16 * range,
        LowZ DC uses table[1] + 0x30 (FW 0x080117B2..0x080117E6); offset = BE i32 at R, g = BE u32 at R + 4 /
        1e6 (FW 0x08011890..0x0801190A, spec 5.1).  Only called for the modes in DERIVED.  EEPROM is read, never
        written."""
        if mode == 0:
            base = struct.unpack('<H', self.m.uc.mem_read(CAL_TABLE + 2, 2))[0] + 0x30
        else:
            base = struct.unpack('<H', self.m.uc.mem_read(CAL_TABLE + 2 * mode, 2))[0] + 16 * rng
        ee = self.m.eeprom
        off = struct.unpack('>i', bytes(ee[base:base + 4]))[0]
        gu = struct.unpack('>I', bytes(ee[base + 4:base + 8]))[0]
        g = struct.unpack('<f', struct.pack('<f', struct.unpack('<f', struct.pack('<f', float(gu)))[0] / 1e6))[0]
        return base, off, g

    def support(self):
        """(supported, reason, mode, range) for the firmware's present mode and the stimulus."""
        mode, rng = self.fw_mode_range()
        if mode >= len(MODE_NAMES):
            return False, f'firmware mode {mode} unknown', mode, rng
        st = self.stim
        if mode in COUNTER_MODES:
            if st['ac'] and st['freq'] > 0:
                return True, 'counter input driven at the stimulus frequency', mode, rng
            return False, 'FREQ needs a stimulus with a frequency (kind Hz, or AC with freq)', mode, rng
        if mode == 0 and self._ram8(RAM_LOWZ_AC) != 0:
            return False, 'LowZ AC variant: AC chain offered by the calibrated backend only', mode, rng
        if mode not in DERIVED:
            return False, f'{MODE_NAMES[mode]}: chain offered by the calibrated backend only', mode, rng
        want, ranges = DERIVED[mode]
        if rng not in ranges:
            return False, f'{MODE_NAMES[mode]} range {rng}: offered by the calibrated backend only', mode, rng
        if st['kind'] != want:
            return False, f'stimulus kind {st["kind"]} does not apply to {MODE_NAMES[mode]} (needs {want})', mode, rng
        if st['ac']:
            return False, (f'AC stimulus in DC mode {MODE_NAMES[mode]}: the AD1 comb-filter response to AC is not '
                           'specified by the datasheet (DS p13 gives NMRR at 5/10 sps only)'), mode, rng
        return True, '', mode, rng

    def counter_input(self, source, t):
        """Signal at the counter input: the stimulus frequency and duty when the stimulus has a frequency.
        The conditioning between the jack and the CNT pin / comparator input PB<4> (amplitude, comparator
        thresholds SCMPRH/SCMPRL, DS p26) is not modelled: any non-zero signal toggles the input."""
        st = self.stim
        if st['ac'] and st['freq'] > 0:
            return st['freq'], st['duty'], self.stim_epoch
        return None

    def raw_per_count(self, mode, rng):
        """Raw AD1 LSB per display count = gain g of the active record (spec 6); 0 where no record applies."""
        if mode in DERIVED and rng in DERIVED[mode][1] and not (mode == 0 and self._ram8(RAM_LOWZ_AC)):
            return self.cal_record(mode, rng)[2]
        return 0.0

    def noise(self, sel):
        """Per-conversion noise sigmas (module docstring)."""
        mode, rng = self.fw_mode_range()
        rpc = self.raw_per_count(mode, rng)
        return {'vref_sigma': EN_ADR3412 * math.sqrt(max(sel['rate'], 0.0) / 2.0) if sel['rh'] == 'PB6' else 0.0,
                'code_sigma': self.noise_counts * rpc, 'raw_per_count': rpc,
                'vin_sigma': self._vin_sigma(sel)}

    def _vin_sigma(self, sel):
        """Input-node noise in volts; only the netlist backend computes one (thermal noise)."""
        return 0.0

    def status(self):
        """Backend, firmware mode/range and support state for the UI."""
        ok, why, mode, rng = self.support()
        return {'backend': self.kind, 'mode': mode, 'mode_name': MODE_NAMES[mode] if mode < len(MODE_NAMES) else '?',
                'range': rng, 'supported': ok, 'reason': why}


class CalibratedFrontend(_Base):
    """Backend (b): perfectly calibrated unit (module docstring), every mode 0..24.

    Principle (spec 7.2): the unit's analog response is what its calibration says, raw = D * g + offset, with D the
    physical quantity in display counts and offset / g the record that 0x0801167C loads for the active chain, read
    from the EEPROM with its rules (_cal: LowZ, BEEP, AC+DC phases, bdOn, peak, CAP divisors, VA pairs; the RAM
    copies are written after the configuration row, see EE_R6_W above).  Where the firmware corrects a hardware
    response (AC frequency correction, 1 kHz filter, OHM r5/r6, DIODE 15 V, VA burden correction, DC VA current
    offset, current zero offsets) the analog side is the
    response that correction was made for: the spec's inverse is evaluated at the stimulus' true frequency and value,
    so the firmware, running unmodified, shows its documented defects (negative rounding of 0x0800F3B8, DEF-1/2/4/9/
    10/11, D1/D3/D4, VA.D1/D3) by itself; nothing is compensated.

    AD1 target per conversion: plan() reads meter_mode / meter_range and the flags of the active chain from RAM and
    returns the raw code; pins() turns it into pin voltages through the inverse of DS p31.  Counter modes (FREQ,
    PULSE, DUTY, CAP) and the AC frequency use counter_input(); PEAK uses ad2_extremes()."""
    kind = 'calibrated'

    def __init__(self, machine, noise_counts=NOISE_COUNTS):
        super().__init__(machine, noise_counts)
        self._flash = {}                # (address, words) -> tuple of i32 read from the application image
        self._cache = {}                # inverse searches keyed by all their inputs
        self.pa4 = None                 # (volts, VREF+) last applied to ADC channel 4 (PA4 thermistor), set by the app
        self._gain = 0.0                # gain of the active chain (noise scaling)

    # ------------------------------------------------------------------ firmware memory (read only)
    def _ram(self, a, fmt):
        return struct.unpack(fmt, self.m.uc.mem_read(a, struct.calcsize(fmt)))[0]

    def _tab(self, a, n):
        """n little-endian i32 words of a flash table (cached; the application image does not change)."""
        k = (a, n)
        if k not in self._flash:
            self._flash[k] = struct.unpack(f'<{n}i', self.m.uc.mem_read(a, 4 * n))
        return self._flash[k]

    def _ee_s16(self, a):
        return struct.unpack('>h', bytes(self.m.eeprom[a:a + 2]))[0]

    def _ee_i32(self, a):
        return struct.unpack('>i', bytes(self.m.eeprom[a:a + 4]))[0]

    def _table(self, m):
        """u16 record base table 0x08028EE8[m] (index 25 = the peak record, misc 7.3)."""
        return struct.unpack('<H', self.m.uc.mem_read(CAL_TABLE + 2 * m, 2))[0]

    def _ee_rec(self, base, div=1e6):
        """(offset, g): offset = i32 BE at base, g = (float)(u32 BE at base + 4) / div in float32 (spec 5.1,
        0x08011890..0x0801190A)."""
        off, gu = struct.unpack('>iI', bytes(self.m.eeprom[base:base + 8]))
        return off, _f32(_i2f(gu) / div)

    def _cal(self, mode, rng):
        """(offset, g) of the record 0x0801167C loads for the active chain (spec 5.1): table[mode] + 16 range;
        LowZ table[1] + 0x30 (DC) / table[2] + 0x30 (AC); BEEP table[9] + 0x10; ACV AC+DC table[2] (AC phase) /
        table[1] (DC phase) + 16 range; ACV / ACmV with peak_hold the peak record table[25] (misc 7.3); bdOn
        burden-voltage channel the ACV r0 / DCV r0 record (acc 7.8)."""
        r8 = self._ram8
        if mode == 0:
            base = self._table(2 if r8(RAM_LOWZ_AC) else 1) + 0x30
        elif mode == 10:
            base = self._table(9) + 0x10
        elif mode == 2 and r8(RAM_ACDC):
            base = self._table(1 if r8(RAM_ACDC_PHASE) else 2) + 16 * rng
        elif mode in (2, 4) and r8(RAM_PEAK) == 1:
            base = self._table(25)
        elif 16 <= mode <= 21 and r8(RAM_BURDEN) == 1 and r8(RAM_CALMODE) == 0 and r8(RAM_VA_CH) == 1:
            base = self._table(2 if mode in (16, 18, 20) else 1)
        else:
            base = self._table(mode) + 16 * rng
        return self._ee_rec(base)

    def _ac_words(self, mode, rng):
        """w0..w3: i16 BE at R' + 8 .. R' + 0xE, R' = table[mode] + 16 r' with r' = 1 for modes 16 / 18, table[2] +
        0x30 for mode 0; w0, w1 outside -20000..20000 and w2, w3 outside -10000..10000 become 0 (acc 5.1)."""
        base = (self._table(2) + 0x30 if mode == 0 else
                self._table(mode) + 16 * (1 if mode in (16, 18) else rng))
        w = [self._ee_s16(base + 8 + 2 * i) for i in range(4)]
        return tuple(v if abs(v) <= (20000 if i < 2 else 10000) else 0 for i, v in enumerate(w))

    def _cur_zero(self, mode, rng):
        """Current zero offset 0x20007E0C as current_extra_load (0x08011448) sets it: the i32 BE after the marker
        0xA5 of the mode's record (EEPROM 0x4D0..0x4FF), modes 16..21 range 0 only; otherwise 0 (acc 7.7)."""
        a = EE_CUR_ZERO.get(mode)
        if a is None or rng != 0 or self.m.eeprom[a] != 0xA5:
            return 0
        return self._ee_i32(a + 1)

    # ------------------------------------------------------------------ stimulus
    def set_stimulus(self, s):
        """As _Base.set_stimulus, plus the range checks that need the firmware tables: board temperature inside the
        thermistor table range used by 0x08013AAC, thermocouple temperature inside the EMF table 0x08025CF8."""
        b = s.get('board', self.stim.get('board'))
        if b is not None:
            lo, hi = self._board_range()
            if not lo <= float(b) <= hi:
                raise ValueError(f'board temperature must be within {lo:.2f} .. {hi:.2f} degC (thermistor table '
                                 '518..3672 used by 0x08013AAC, offset EEPROM 0x2E0)')
        if s.get('kind', self.stim['kind']) == 'degC' and not TC_MIN_C <= float(s.get('value', 0.0)) <= TC_MAX_C:
            raise ValueError(f'thermocouple temperature must be within {TC_MIN_C} .. {TC_MAX_C} degC (EMF table '
                             '0x08025CF8, misc 4.1)')
        super().set_stimulus(s)

    def set_pa4(self, volts, vref):
        """The application applied `volts` to PA4 (ADC channel 4) with VREF+ = vref."""
        self.pa4 = (float(volts), float(vref))

    def clear_board(self):
        """The PA4 voltage was set directly: the board temperature now follows it (stimulus 'board' = None)."""
        self.stim = dict(self.stim, board=None)

    # ------------------------------------------------------------------ board temperature <-> PA4 (misc 4.2)
    def _th_offset(self):
        """Thermistor offset in 0.01 degC: u16 BE at EEPROM 0x2E0 as s16, 0 if outside -1000..1000 (misc 4.2,
        0x08011684..0x080116C4)."""
        v = self._ee_s16(0x2E0)
        return v if -1000 <= v <= 1000 else 0

    def _board_range(self):
        """Board temperatures whose thermistor reading Tth = board - offset is inside -25.00..85.00 degC, the part of
        the table 0x08028DD0 that 0x08013AAC accepts (518 <= avg <= 3672)."""
        o = self._th_offset()
        return (TH_TMIN + o) / 100.0, (TH_TMAX + o) / 100.0

    def pa4_volts(self, vref):
        """PA4 voltage for the stimulus' board temperature, or None when the stimulus has none.  Continuous inverse
        of the 0x08013AAC interpolation: Tth = board * 100 - offset (0.01 degC); i = the table entry index with
        500 (i - 1) - 3000 <= Tth <= 500 i - 3000; avg = TH[i-1] - (Tth - (500 i - 3500)) (TH[i-1] - TH[i]) / 500;
        volts = avg / 4095 * VREF+ (inverse of the ADC transfer of emu/periph/adc.py).  The ADC quantises the
        code and the firmware truncates its own interpolation (f2iz), as on a real unit."""
        b = self.stim.get('board')
        if b is None:
            return None
        tth = b * 100.0 - self._th_offset()
        i = max(1, min(len(TH_TABLE) - 1, math.ceil((tth + 3000.0) / 500.0)))
        avg = TH_TABLE[i - 1] - (tth - (500 * i - 3500)) * (TH_TABLE[i - 1] - TH_TABLE[i]) / 500.0
        return avg / 4095.0 * vref

    def board_c(self):
        """Board (cold-junction) temperature in degC: the stimulus value, or the temperature of the PA4 voltage
        (forward of pa4_volts) when the stimulus has none; None outside the table range 518..3672."""
        if self.stim.get('board') is not None:
            return self.stim['board']
        if self.pa4 is None or self.pa4[1] <= 0:
            return None
        avg = self.pa4[0] / self.pa4[1] * 4095.0
        if not TH_TABLE[-1] <= avg <= TH_TABLE[1]:
            return None
        i = next(k for k in range(1, len(TH_TABLE)) if avg >= TH_TABLE[k])
        tth = 500 * i - 3500 + (TH_TABLE[i - 1] - avg) * 500.0 / (TH_TABLE[i - 1] - TH_TABLE[i])
        return (tth + self._th_offset()) / 100.0

    def _tc_emf(self, t):
        """Thermocouple EMF in uV at t degC: linear interpolation of the table 0x08025CF8 (t[k] at 10 k - 210 degC),
        the curve the firmware inverts in 0x08013C40 (misc 4.1)."""
        tab = self._tab(TC_TABLE, 158)
        u = (t + 210.0) / 10.0
        k = max(0, min(156, int(math.floor(u))))
        return tab[k] + (tab[k + 1] - tab[k]) * (u - k)

    # ------------------------------------------------------------------ quantities at the jacks
    def _parts(self, value):
        """(AC RMS part, DC part) of a V or A stimulus value: AC stimulus = sine of RMS `value` plus 'dc' (V only)."""
        st = self.stim
        if st['ac']:
            return value, (st['dc'] if st['kind'] == 'V' else 0.0)
        return 0.0, value

    def _current_jack(self, mode):
        """Jack the current of `mode` enters through (SCH current inputs, spec 7: 10 A path F2 / SHUNT, mA/uA path
        F1 / R33 / R43): mA/uA modes and their VA modes use the mA jack, A modes the A jack."""
        return 'A' if mode in (15, 20, 21, 24) else 'mA'

    def _measured_current(self, mode, amps):
        """(current reaching the mode's shunt, note).  The stimulus current flows through the one plugged current
        jack (emu/board.py: a plug pulls PE10 (mA) / PE11 (A) low, acc 7.9); the mode's shunt sees it only when that
        is the mode's jack.  Both jacks plugged: the path is not defined -> None."""
        plugged = {'mA', 'A'} & set(self.board.jacks if self.board is not None else ())
        if len(plugged) == 2:
            return None, 'both current jacks plugged: the current path is not defined'
        want = self._current_jack(mode)
        if not plugged:
            return 0.0, f'no plug in a current jack: no current reaches the {want} shunt'
        if plugged != {want}:
            return 0.0, (f'current enters the {plugged.pop()} jack; the {MODE_NAMES[mode]} shunt ({want} jack) '
                         'carries none')
        return amps, ''

    # ------------------------------------------------------------------ firmware arithmetic (acc 5 notation)
    def _interp(self, a, k, t):
        """INTERP(X, k) = X[k-1] + RND(fmul(i2f(X[k] - X[k-1]), t)); X[-1] is the word before the table."""
        x0, x1 = self._tab(a + 4 * (k - 1), 2)
        return x0 + _rnd(_fmul(_i2f(_s32(x1 - x0)), t))

    def _search(self, ft, n, f):
        """k = first i in 0..n-1 with F <= FT[i], else n-1; t = fdiv(i2f(F - FT[k-1]), i2f(FT[k] - FT[k-1]))."""
        tab = self._tab(ft, n)
        k = next((i for i in range(n) if f <= tab[i]), n - 1)
        p, q = self._tab(ft + 4 * (k - 1), 2)
        return k, _fdiv(_i2f(_s32(f - p)), _i2f(_s32(q - p)))

    def _corr(self, d, w, idx, f, f87):
        """CORR(D, w, idx, F): 0x080124F4 (acc 5.2)."""
        if idx == 5 and d >= 6600 or idx == 4 and d >= 60000 or d >= 55000 or idx >= 8 or f < 51:
            return 0
        if idx in (2, 3):
            return self._corr_acv01(d, w, idx, f, f87)
        n, ft = (9, 0x0802900C) if idx in (0, 1) else (7, 0x080290F0)
        k, t = self._search(ft, n, f)
        xa, s = CORR_X[idx]
        p = self._interp(xa + 4 * s * (1 if d >= 5001 else 0), k, t)
        a = _f2iz(_fdiv(_fmul(_i2f(p), _i2f(w[0])), 100.0))
        b = _f2iz(_fdiv(_fmul(_i2f(p), _i2f(w[1])), 100.0))
        lo, hi, base = (a + 600, b + 5400, 600) if idx == 5 else (a + 5000, b + 45000, 5000)
        if d <= lo:
            return _f2iz(_fmul(_i2f(a), _fdiv(_i2f(d), _i2f(lo))))
        q = _f32(_fdiv(_i2f(d - base), _i2f(hi)) + -1.0)
        return b + _f2iz(_fmul(_i2f(b - a), q))

    def _corr_acv01(self, d, w, idx, f, f87):
        """CORR_ACV01: 0x080129EE (acc 5.3), ACV ranges 0 and 1."""
        w0, w1, w2, w3 = w
        low = f < 20001
        k, t = self._search(0x08029030 if low else 0x08029054, 9, f)
        if idx == 2:
            x = (0x08028B38 if low else 0x08028B80) if not f87 else (0x08028AA8 if low else 0x08028AF0)
        else:
            x = 0x08028BC8 if low else 0x08028C10
        p1, p2 = self._interp(x, k, t), self._interp(x + 0x24, k, t)
        if low:
            a, b = _sdiv(p1 * w2, 100), _sdiv(p2 * w3, 100)
        else:
            a, b = w2 + _sdiv(p1 * (w0 - w2), 100), w3 + _sdiv(p2 * (w1 - w3), 100)
        lv = w2 + 5000
        if lv < d:
            pct = _f2iz(_fmul(_fdiv(_fsub(_i2f(d), _i2f(lv)), _fsub(50000.0, _i2f(lv))), 100.0))
            return b - ((b - a) - _sdiv(pct * (b - a), 100))
        pct = _f2iz(_fmul(_fdiv(_fsub(_i2f(lv), _i2f(d)), _i2f(lv)), 100.0))
        return a - _sdiv(pct * a, 100)

    def _corr70(self, d, f):
        """CORR70(D, F): 0x080070CC (acc 5.4), ACV range 0 while 0x20008087 != 0."""
        if d >= 57000 or f < 51:
            return 0
        k, t = self._search(0x08028C58, 17, f)
        if d < 5001:
            c94, c98 = 0, self._interp(0x08028648, k, t)
        else:
            c94, c98 = self._interp(0x08028648, k, t), self._interp(0x08028648 + 0x44, k, t)
        ca8 = c94 + 5000
        if ca8 < d:
            pct = _f2iz(_fmul(_fdiv(_fsub(_i2f(d), _i2f(ca8)), _fsub(50000.0, _i2f(ca8))), 100.0))
        else:
            pct = _f2iz(_fmul(_fdiv(_fsub(_i2f(ca8), _i2f(d)), _i2f(ca8)), 100.0))
        return c98 - ((c98 - c94) - _sdiv(pct * (c98 - c94), 100))

    def _filt(self, d0, f):
        """FILT(D0, F): 0x08006D40 (acc 5.5), ACV/ACmV with the 1 kHz filter."""
        if f < 20:
            return d0
        if f >= 6001:
            return 0
        k, t = self._search(0x0802501C, 216, f)
        if d0 < 100000:
            c60 = self._interp(0x080256DC, k, t)
        elif d0 < 500001:
            c64, c68 = self._interp(0x080256DC, k, t), self._interp(0x0802537C, k, t)
            c60 = _f2iz(_fmul(_i2f(c68 - c64), _fdiv(_fadd(_i2f(d0), -100000.0), 400000.0))) + c64
        else:
            c60 = self._interp(0x0802537C, k, t)
        return _sdiv(_s32(c60 * d0), 10000)

    def _post(self, d, c):
        """POST(D0) = steps 4, 5 and 6 of the AC chain (acc 4): the steps that compensate the unit's response (filter,
        frequency correction, current zero offset).  Step 7 (smoothing) keeps a constant value; step 8 (AC current
        r0 readings below 31 counts shown as 0) is a display rule, not a response, so it is left to the firmware
        and stays visible instead of being searched around."""
        m = c['mode']
        if c['filt']:
            d = self._filt(d, c['F'])
        if c['corr']:
            d = _s32(d - self._corr(d, c['w'], c['idx'], c['F'], c['f87']))
            if m == 2 and c['rng'] == 0 and c['f87']:
                d = _s32(d - self._corr70(d, c['F']))
        if c['zero']:
            d = max(_s32(d - c['e0c']), 0)
        return d

    def _fw_freq(self, f, fr_prev):
        """Integer F (Hz) the firmware derives from a completed counter measurement of an f Hz signal (acc 3, 10.1):
        the chip's counter result (CTB = N whole cycles in the gate set by the preset word 0x2000001C, T = round(N *
        SYSCLK / f), emu/hy3131.py _ctr_start), f_mHz = floor(ref * CTB * 10 / floor(T / 10)) with ref = 0x20007E18
        (0x0800B610), range fr with hysteresis on fr_prev (0x0800AC1C), stored value (0x0800AEE8) and F (0x08012F28).
        For f_mHz >= 10^9 the firmware stores an uninitialised register (defect D3); the analog response is that of
        the true frequency, so the fr 4 value is used here."""
        fsys = self.chip.f_sys
        gate = CTA_RANGE - ((self._ram(RAM_PRESET, '<I') & 0xFFFF) << 8)
        n = max(1, math.ceil(gate * f / fsys - 1e-12))
        t = int(round(n * fsys / f))
        ref = self._ram(RAM_FREQ_REF, '<I')
        fm = (ref * n * 10) // (t // 10) if t >= 10 else 0
        fr = 0
        for r, (up, keep) in ((4, (10 ** 8, 8 * 10 ** 7)), (3, (10 ** 7, 8 * 10 ** 6)), (2, (10 ** 6, 8 * 10 ** 5)),
                              (1, (10 ** 5, 8 * 10 ** 4))):
            if fm >= up or (fr_prev == r and fm >= keep):
                fr = r
                break
        stored = (fm + (5 * 10 ** (fr - 1) if fr else 0)) // 10 ** fr
        return (stored // 1000, stored // 100, stored // 10, stored, stored * 10)[fr]

    def _ac_code(self, d0, off, g):
        """AD1 code whose AC-chain value is d0: m = round(offset + d0 g') checked with the forward chain x = m -
        offset (0 if x < 1, 0x0800F368), D0 = trunc((double)((float)x / g') + 0.5) (0x0800F3B8) and moved by up to
        +-4 until it matches (spec 5.4 step 3, acc 10.2 step 2)."""
        m0 = int(round(off + d0 * g))
        for dm in (0, 1, -1, 2, -2, 3, -3, 4, -4):
            x = m0 + dm - off
            x = x if x >= 1 else 0
            if (int(_f32(_i2f(x) / g) + 0.5) if g else 0) == d0:
                return m0 + dm
        return m0

    def _ac_inverse(self, dt, c, g):
        """D0 >= 0 minimising (|POST(D0) - Dt|, |D0 - Dt|) (acc 10.2 step 1).  POST is close to linear (identity
        with bounded corrections, or the filter's C60 x D0 / 10000), so the search starts at the secant iterate,
        scans a local window and widens to the bound of the correction (section 6: below 7200 counts; filter:
        the D0 interval spanned by the two C60 tables) only when no exact match is found.  Cached per input set."""
        key = ('ac', dt, tuple(sorted(c.items())))
        if key in self._cache:
            return self._cache[key]
        d0max = max(0, int((AD1_MAX - c['off']) / g)) if g > 0 else 0
        best = None

        def consider(d):
            nonlocal best
            if not 0 <= d <= d0max:
                return None
            try:
                p = self._post(d, c)
            except ZeroDivisionError:
                return None
            k = (abs(p - dt), abs(d - dt))
            if best is None or k < best[0]:
                best = (k, d)
            return p
        d = min(dt, d0max)
        if c['filt'] and c['F'] >= 20 and c['F'] < 6001:
            p = consider(max(d, 1))
            d = min(d0max, int(d * dt / p) if p else dt * 10)
        slope = 1.0
        for _ in range(12):
            p = consider(d)
            if p is None or p == dt:
                break
            slope = p / d if d > 0 and p > 0 else slope
            d = max(0, d + int(round((dt - p) / slope)))
        w = int(64 / min(1.0, slope)) + 1
        for x in range(max(0, d - w), d + w + 1):
            consider(x)
        if best is None:                               # target beyond the AD1 range: the code saturates
            return d0max
        if best[0][0] != 0:
            if c['filt'] and 20 <= c['F'] < 6001:
                k, t = self._search(0x0802501C, 216, c['F'])
                cs = [self._interp(0x080256DC, k, t), self._interp(0x0802537C, k, t)]
                lo, hi = (int(dt * 10000 / max(cs)) - 2, int(dt * 10000 / max(1, min(cs))) + 2) if min(cs) > 0 \
                    else (0, d0max)
            else:
                lo, hi = dt - 9000, dt + 9000
            for x in range(max(0, lo), min(d0max, hi) + 1):
                consider(x)
        self._cache[key] = best[1]
        if len(self._cache) > 512:
            self._cache.pop(next(iter(self._cache)))
        return best[1]

    def _ac_ctx(self, mode, rng, off, g, f_hz, fr_addr, filt, corr, zero):
        """Inputs of POST for the active AC chain (acc 4, 5.1): words w0..w3 (_ac_words), 0x20008087, the current
        zero (_cur_zero) and F from the true stimulus frequency (_fw_freq)."""
        return {'mode': mode, 'rng': rng, 'off': off, 'filt': filt, 'corr': corr, 'zero': zero,
                'F': self._fw_freq(f_hz, self._ram8(fr_addr)) if (filt or corr) else 0,
                'w': self._ac_words(mode, rng),
                'idx': {4: rng, 2: rng + 2, 16: 6, 18: 7, 20: 8}.get(mode, 0),
                'f87': self._ram8(RAM_FLAG87) != 0, 'e0c': self._cur_zero(mode, rng)}

    # ------------------------------------------------------------------ OHM r5 / r6 corrections (misc 6.3)
    @staticmethod
    def _c5(v):
        """c5(v): 0x08007B70."""
        if v < 1000 or v >= 50000:
            return 0
        if v < 15000:
            return v // 1000
        if v < 36000:
            return 15
        return 15 - (v - 35000) // 1000

    def _c6(self, v, w):
        """c6(v, w): 0x08007D1E with T = 0x08028838, W = 0x0802886C (13 i32 each; index -1 reads the word before)."""
        if v >= 56000:
            return 0
        tt = self._tab(0x08028838, 13)
        i = next((k for k in range(13) if _s32(tt[k] * 1000) >= v), 12)
        t0, t1 = self._tab(0x08028838 + 4 * (i - 1), 2)
        w0, w1 = self._tab(0x0802886C + 4 * (i - 1), 2)
        frac = _fdiv(_i2f(_s32(v - _s32(1000 * t0))), _i2f(_s32(1000 * _s32(t1 - t0))))
        interp = _fadd(_i2f(w0), _fmul(frac, _i2f(_s32(w1 - w0))))
        return _f2iz(_fdiv(_fmul(_i2f(w), interp), 100.0))

    def _ohm_target(self, rng, dt_cont):
        """D0 for an OHM r5/r6 display target when 0x08007A92 applies the correction: the D0 in [Dt - 3100,
        Dt + 3100] with D0 - c(D0) = Dt closest to Dt, else the nearest reachable (misc 6.5 step 2)."""
        dt = int(round(dt_cont))
        w = self._ee_i32(EE_R6_W)
        w = w if -3000 <= w < 3001 else 0                # 0x08011924
        key = ('ohm', rng, dt, w)
        if key not in self._cache:
            c = self._c5 if rng == 5 else (lambda v: self._c6(v, w))
            self._cache[key] = min(range(dt - 3100, dt + 3101), key=lambda d: (abs(d - c(d) - dt), abs(d - dt)))
        return self._cache[key] + (dt_cont - dt)

    # ------------------------------------------------------------------ VA (acc 12)
    def _va_burden(self, mode, rng, v, i, b2=None):
        """Burden correction of the VA voltage, 0x08008ED0 with the table fetch 0x08009364 (acc VA.5).  b2 (mode 24
        range 2 only) overrides the sign relation of V and I, for the magnitude solve of _va_vraw."""
        if self._ram8(RAM_CALMODE) or mode in (22, 23) or self._ram8(RAM_CUR_OL) or v >= 60001:
            return v
        pf8, cc = self._ram8(RAM_PF8), self._ram8(RAM_JACK_CODE)
        vs = v
        if mode == 24 and rng == 2:
            b2 = (1 if (v < 0) != (i < 0) else 0) if b2 is None else b2
            v, i = abs(v), abs(i)
        elif v < 0 or i < 0:
            return v
        row = 0 if mode in (13, 22) and rng < 2 else 2 if mode in (15, 24) and rng > 1 else 1
        t1 = self._tab(0x08028968 + 0x20 * row, 9)
        flag = (mode in (13, 22) and cc != 1) or (mode in (15, 24) and cc != 2)
        b3 = 8 if flag else next((k for k in range(1, 7) if i <= t1[k]), 7)
        b4 = 1 if v < 11 and mode != 15 else next((k for k, lim in ((2, 1001), (3, 5001), (4, 10001), (5, 30001),
                                                                    (6, 50001)) if v < lim), 7)
        t2 = self._tab(0x08029098, 8)
        ce4 = max(-100, min(100, _sdiv((v - t2[b4 - 1]) * 100, t2[b4] - t2[b4 - 1])))
        sel = VA_B[(mode, rng)][1 if pf8 else 0]
        base = sel[b2 or 0] if isinstance(sel, tuple) else sel
        s = 7 if base in (0x080283C4, 0x080284C0) else 8
        tb = self._tab(base, 9 * s + 1)
        eb8, ebc = tb[(b3 - 1) * s + b4 - 1], tb[(b3 - 1) * s + b4]
        ec0, ec4 = tb[b3 * s + b4 - 1], tb[b3 * s + b4]
        # 32-bit register arithmetic: the out-of-row reads of VA.D2 make these products overflow
        cf0 = _s32(_sdiv(_s32(ce4 * _s32(ebc - eb8)), 100) + eb8)
        cf4 = _s32(_sdiv(_s32(ce4 * _s32(ec4 - ec0)), 100) + ec0)
        if flag:
            d04 = cf4
        else:
            d00 = max(-100, min(100, _sdiv((i - t1[b3 - 1]) * 100, t1[b3] - t1[b3 - 1])))
            d04 = _s32(_sdiv(_s32(d00 * _s32(cf4 - cf0)), 100) + cf0)
        if mode == 24 and rng == 2 and pf8 and vs < 0:
            return _s32(vs - d04)
        return _s32(vs + d04)

    def _va_vraw(self, mode, rng, vt, it):
        """Voltage count before the burden correction that makes the firmware show vt (acc VA.8: search vt, vt - 1,
        vt + 1, ...; nearest result if none matches).  Mode 24 range 2: 0x08008ED0 computes D04 from |V| and |I|,
        so the analog side is taken as symmetric in sign (solved on magnitudes, sign restored) and the sign defect
        VA.D3 of the 0x20007FDF = 0 tables stays visible."""
        key = ('va', mode, rng, vt, it, self._ram8(RAM_PF8), self._ram8(RAM_JACK_CODE), self._ram8(RAM_CUR_OL))
        if key in self._cache:
            return self._cache[key]
        sym = mode == 24 and rng == 2 and vt < 0
        tv, ti = (abs(vt), abs(it)) if sym else (vt, it)
        b2 = (1 if it >= 0 else 0) if sym else None      # sign relation of the true V (< 0) and I
        best = None
        for dv in range(0, 10001):
            for cand in ((tv - dv, tv + dv) if dv else (tv,)):
                if mode in (13, 14, 15) and cand < 0:
                    continue
                r = self._va_burden(mode, rng, cand, ti, b2)
                k = (abs(r - tv), dv)
                if best is None or k < best[0]:
                    best = (k, cand)
            if best[0][0] == 0:
                break
        res = -best[1] if sym else best[1]
        self._cache[key] = res
        return res

    def _va_k(self, mode, rng, v, ds):
        """DC VA current offset K: 0x080087F8 (acc VA.6) for the smoothed current ds and voltage sign of v."""
        if (self._ram8(RAM_CALMODE) or mode not in (22, 23, 24) or self._ram8(RAM_PF8) != 0
                or self._ram8(RAM_R6FLAG) != 1 or -2500 <= ds <= 2500):
            return 0
        return VA_K[(mode, rng)][(0 if v >= 0 else 1) + (0 if ds > 0 else 2)]

    def _va_ir(self, mode, rng, vt, it):
        """Smoothed current count Ir with Ir + K(Ir) = it, else the nearest reachable (acc VA.8 current step 2)."""
        cands = [it - k for k in set(VA_K.get((mode, rng), (0,))) | {0}] + [2500, 2501, -2500, -2501, it]
        return min(cands, key=lambda d: (abs(d + self._va_k(mode, rng, vt, d) - it), abs(d - it)))

    # ------------------------------------------------------------------ plan of the active chain
    def plan(self):
        """What the unit presents for the firmware's present state: {'ok', 'why', 'mode', 'rng', 'raw' (AD1 code
        target or None), 'gain' (raw LSB per display count), 'cap_h' (CAP high time in SYSCLK ticks), 'peak' (AD2
        extremes)}.  'why' explains an unsupported state or carries a note when supported."""
        mode, rng = self.fw_mode_range()
        p = {'ok': False, 'why': '', 'mode': mode, 'rng': rng, 'raw': None, 'gain': 0.0, 'cap_h': None, 'peak': None}
        if mode >= len(MODE_NAMES):
            p['why'] = f'firmware mode {mode} unknown'
            return p
        try:
            getattr(self, PLAN_OF[mode])(p, mode, rng, self.stim)
        except ZeroDivisionError:
            p['ok'], p['why'] = False, 'calibration record has gain 0 (EEPROM record empty)'
        self._gain = p['gain']
        return p

    def _need(self, p, kind):
        if self.stim['kind'] != kind:
            p['why'] = f'stimulus kind {self.stim["kind"]} does not apply to {MODE_NAMES[p["mode"]]} (needs {kind})'
            return False
        return True

    def _set_dc(self, p, d0, off, g, note=''):
        """DC chain (spec 5.2): x = m - offset, D0 = trunc((float)x / g + 0.5); a unit with this calibration
        presents raw = offset + D0 g (D0 continuous, the chip rounds the code)."""
        if not g:
            raise ZeroDivisionError
        p.update(ok=True, raw=off + d0 * g, gain=g, why=note)

    def _set_ac(self, p, dt, c, off, g, note=''):
        """AC chain (acc 4): code of the D0 that POST maps to Dt (acc 10.2)."""
        if not g:
            raise ZeroDivisionError
        d0 = self._ac_inverse(dt, c, g) if dt and c and (c['filt'] or c['corr'] or c['zero']) else dt
        p.update(ok=True, raw=float(self._ac_code(d0, off, g)), gain=g, why=note)

    def _plan_counter(self, p, mode, rng, st):
        """FREQ / PULSE / DUTY: no AD1; the counter input carries the stimulus signal (spec 4.3, misc 5)."""
        if st['ac'] and st['freq'] > 0:
            p.update(ok=True, why='counter input driven at the stimulus frequency')
        else:
            p['why'] = f'{MODE_NAMES[mode]} needs a stimulus with a frequency (kind Hz, or AC with freq)'

    def _plan_cap(self, p, mode, rng, st):
        """CAP (misc 5.5): X = CTC / CTB (r0, r1, r5) or 100 CTC / CTB (r2..r4); the unit presents X = offset +
        D g with the EEPROM record R = u16 0x08028EE8[12] + 16 range, g = (float)u32(R + 4) / 100000.0f (10000.0f
        for r4 with 0x20007FDF != 0), 0x080118B2..0x08011906 (_cal / _ee_rec; traced in emulation: the counter
        restart of the configuration write samples the input while RAM still holds the previous range's record,
        which the RAM copy would turn into a wrong first gate).  The physical method
        is UNPROVEN (misc UNPROVEN list); the counter input is modelled as a pulse train of high time h = X (r0, r1,
        r5) or X / 100 (r2..r4) SYSCLK ticks at 50 % duty (design choice), at least one SYSCLK tick (CTC counts
        whole ticks, DS p36 (7))."""
        if not self._need(p, 'F'):
            return
        if rng not in CAP_EXP:
            p['why'] = f'CAP range {rng} unknown'
            return
        off, g = self._ee_rec(self._table(12) + 16 * rng, 10000.0 if rng == 4 and self._ram8(RAM_PF8) else 100000.0)
        if not g:
            raise ZeroDivisionError
        x = off + st['value'] * 10 ** CAP_EXP[rng] * g
        h = max(1.0, x / 100.0 if 2 <= rng <= 4 else x)
        if h >= CTA_RANGE:
            p['why'] = ('CAP: the high time exceeds the 24-bit CTC (DS p36); the counter behaviour on CTC overflow is '
                        'not stated (misc UNPROVEN: counter corner cases)')
            return
        p.update(ok=True, gain=g, cap_h=h,
                 why='CAP counter signal: pulse train, physical method UNPROVEN (misc 5.5)')

    def _plan_temp(self, p, mode, rng, st):
        """TEMP (misc 4): D (uV) = E(T_hot) - E(T_board) with E the table 0x08025CF8; the board temperature also
        sets PA4, from which the firmware computes its cold junction (0x0801385A, 0x08013CF8)."""
        if not self._need(p, 'degC'):
            return
        tb = self.board_c()
        if tb is None:
            p['why'] = 'board temperature unknown: PA4 voltage outside the thermistor table range 518..3672 (misc 4.2)'
            return
        off, g = self._cal(mode, rng)
        self._set_dc(p, self._tc_emf(st['value']) - self._tc_emf(tb), off, g, f'board {tb:.2f} degC')

    def _plan_ohm(self, p, mode, rng, st):
        """OHM r0..r6 (spec 5.2, misc 6.3) and BEEP (OHM chain, record 0x120, range 0, misc 6.3)."""
        if not self._need(p, 'ohm'):
            return
        off, g = self._cal(mode, rng)
        e = 2 if mode == 10 else OHM_EXP.get(rng)
        if e is None:
            p['why'] = f'OHM range {rng} unknown'
            return
        d = st['value'] * 10.0 ** e
        if (mode == 9 and rng in (5, 6) and self._ram8(RAM_R6FLAG) == 0 and self._ram8(RAM_CALMODE) == 0):
            d = self._ohm_target(rng, d)
        self._set_dc(p, d, off, g)

    def _plan_diode(self, p, mode, rng, st):
        """DIODE 3 V / 15 V (misc 6.3, 6.5): D0 = V x 10^4 in both variants; 15 V on units with 0x20007FDF = 1:
        D0 = 10 (Dt - 500) above 14.500 V (inverse of the +500 step at 0x08007ED4)."""
        if not self._need(p, 'diode'):
            return
        off, g = self._cal(mode, rng)
        d0 = st['value'] * 1e4
        if (self._ram8(RAM_DIODE15) and self._ram8(RAM_PF8) == 1 and self._ram8(RAM_CALMODE) == 0
                and st['value'] * 1e3 > 14500):
            d0 = 10 * (st['value'] * 1e3 - 500)
        self._set_dc(p, d0, off, g)

    def _plan_volt(self, p, mode, rng, st):
        """DCV, DCmV, LowZ (both variants), ACV (normal, 1 kHz filter, PEAK, AC+DC phases), ACmV."""
        if not self._need(p, 'V'):
            return
        ac, dc = self._parts(st['value'])
        r8 = self._ram8
        e = VOLT_EXP[mode].get(rng)
        if e is None:
            p['why'] = f'{MODE_NAMES[mode]} range {rng} unknown'
            return
        off, g = self._cal(mode, rng)
        lowz_ac = mode == 0 and r8(RAM_LOWZ_AC) != 0
        acdc = mode == 2 and r8(RAM_ACDC) != 0
        if mode in (1, 3) or (mode == 0 and not lowz_ac) or (acdc and r8(RAM_ACDC_PHASE)):
            # DC rows: the DCV row reads the DC component (acc 10.4); other DC rows need a DC stimulus
            if st['ac'] and mode == 3:
                p['why'] = UNSUPPORTED_WHY[3]
                return
            self._set_dc(p, dc * 10.0 ** e, off, g)
            return
        # AC rows read PB<7>, the AD8436 output = RMS of the AC component (acc 1, 10.4)
        if (ac > 0 or st['ac']) and st['freq'] <= 0:
            p['why'] = 'AC chain needs the stimulus frequency (freq > 0)'
            return
        if mode in (2, 4) and r8(RAM_PEAK) == 1 and r8(RAM_FILTER) == 0 and not acdc:
            if dc:
                p['why'] = UNSUPPORTED_WHY[mode]
                return
            if not g:
                raise ZeroDivisionError
            dpk = math.sqrt(2.0) * ac * 10.0 ** e             # sine peak (stimulus definition)
            p.update(ok=True, gain=g, peak=(int(round(off + dpk * g)), int(round(off - dpk * g))),
                     why='PEAK: AD2 extremes from the peak record (misc 7.4)')
            return
        filt = mode in (2, 4) and r8(RAM_FILTER) == 1
        gg = _f32(g / 10.0) if filt else g                     # 0x0800F3D4..0x0800F40C
        corr = (mode in (2, 4) and not filt and r8(RAM_BURDEN) == 0 and r8(RAM_CALMODE) == 0)
        c = (self._ac_ctx(mode, rng, off, gg, st['freq'], RAM_FR_ACDC if acdc else RAM_FR, filt, corr, False)
             if ac > 0 else {})
        if filt and c and not 20 <= c['F'] < 6001:
            p['why'] = FILTER_WHY
            return
        self._set_ac(p, int(round(ac * 10.0 ** e)), c, off, gg)
        p['gain'] = g                                  # noise in displayed counts: the record gain (module docstring)

    def _plan_current(self, p, mode, rng, st):
        """ACuA..DCA (acc 7.5 - 7.9), with the bdOn burden-voltage channel (acc 7.8)."""
        if not self._need(p, 'A'):
            return
        r8 = self._ram8
        amps, note = self._measured_current(mode, st['value'])
        if amps is None:
            p['why'] = note
            return
        ac, dc = self._parts(amps)
        is_ac = mode in (16, 18, 20)
        if not is_ac and st['ac']:
            p['why'] = UNSUPPORTED_WHY[mode]
            return
        if is_ac and st['ac'] and st['freq'] <= 0:
            p['why'] = 'AC chain needs the stimulus frequency (freq > 0)'
            return
        off, g = self._cal(mode, rng)
        burden = r8(RAM_BURDEN) == 1 and r8(RAM_CALMODE) == 0
        if burden and r8(RAM_VA_CH) == 1:
            # burden voltage: I x the manual's burden figure (MAN current table: 100 uV/uA, 2 mV/mA, 0.03 V/A),
            # measured through the extra lead from the current jack to the V jack (MAN burden voltage section)
            if 'V' not in (self.board.jacks if self.board is not None else ()):
                p['why'] = BD_LEAD_WHY
                return
            vb = (ac if is_ac else dc) * BURDEN_OHM[mode]
            if is_ac:
                self._set_ac(p, int(round(vb * 1e4)), {}, off, g, note)
            else:
                self._set_dc(p, vb * 1e4, off, g, note)
            return
        if rng >= len(CUR_EXP[mode]):
            p['why'] = f'{MODE_NAMES[mode]} range {rng} unknown'
            return
        e = CUR_EXP[mode][rng]
        if is_ac:
            c = self._ac_ctx(mode, rng, off, g, st['freq'], RAM_FR, False,
                             not burden and r8(RAM_CALMODE) == 0, rng == 0) if ac > 0 else {}
            self._set_ac(p, int(round(ac * 10.0 ** e)), c, off, g, note)
        else:
            self._set_dc(p, dc * 10.0 ** e + self._cur_zero(mode, rng), off, g, note)

    def _plan_va(self, p, mode, rng, st):
        """VA modes (acc 12): the voltage channel (va_channel 0x200080C4 = 0) or the current channel (1)."""
        if not self._need(p, 'VA'):
            return
        r8 = self._ram8
        amps, note = self._measured_current(mode, st['amps'])
        if amps is None:
            p['why'] = note
            return
        is_ac = mode in (13, 14, 15)
        if not is_ac and st['ac']:
            p['why'] = UNSUPPORTED_WHY[mode]
            return
        # AC rows read the AC component (acc 1, 10.4): a DC stimulus gives 0 there
        vc = st['value'] * 10.0 ** (4 if r8(RAM_C6) == 0 else 3) if st['ac'] == is_ac else 0.0
        ic = (amps if st['ac'] == is_ac else 0.0) * 10.0 ** VA_I_EXP[mode][0 if r8(RAM_C7) == 0 else 1]
        vt, it = int(round(vc)), int(round(ic))
        ch = r8(RAM_VA_CH)
        # both pairs of R = table[mode] + 16 range: voltage at R / R + 4, current at R + 8 / R + 0xC (acc VA.3)
        off, g = self._ee_rec(self._table(mode) + 16 * rng + (8 if ch else 0))
        if is_ac:
            d0 = it if ch else self._va_vraw(mode, rng, vt, it)
            self._set_ac(p, d0, {}, off, g, note)
        elif ch:
            ir = self._va_ir(mode, rng, vt, it)          # 0x20007E0C is 0 in VA modes (acc VA.3)
            self._set_dc(p, ir + (ic - it), off, g, note)
        else:
            self._set_dc(p, self._va_vraw(mode, rng, vt, it) + (vc - vt), off, g, note)

    # ------------------------------------------------------------------ chip interface
    def support(self):
        p = self.plan()
        return p['ok'], p['why'], p['mode'], p['rng']

    def raw_per_count(self, mode, rng):
        """Raw AD1 LSB per display count = gain of the chain planned last (spec 6)."""
        return self._gain

    def counter_input(self, source, t):
        """CAP: the pulse train of _plan_cap.  Otherwise the stimulus signal when the stimulus has a frequency;
        an AC V / A / VA stimulus whose amplitude at the input is zero (value 0, or a current that reaches no
        shunt) gives no signal and the counter waits (spec 4.3)."""
        mode, rng = self.fw_mode_range()
        if mode == 12:
            p = self.plan()
            if not p['ok'] or p['cap_h'] is None:
                return None
            return self.chip.f_sys / (2.0 * p['cap_h']), 0.5, self.stim_epoch
        st = self.stim
        if st['ac'] and st['kind'] in ('V', 'A', 'VA'):
            amp = st['value']
            if st['kind'] == 'A' and mode in CUR_EXP:
                amp = self._measured_current(mode, amp)[0] or 0.0
            if not amp:
                return None
        return super().counter_input(source, t)

    def ad2_extremes(self, t):
        """(max, min) AD2<18:0> code of the signal for the peak detector (DS p34-35), or None."""
        p = self.plan()
        return p['peak'] if p['ok'] else None

    def pins(self, sel, t):
        """Voltages for the AD1 selection that make the chip produce the planned raw code.  VR: the ADR3412
        typical output for the PB<6> reference rows; the other references (FB / RLU, VDDA / VSSA, REFO) have no
        derived voltage and the same nominal value is used: the code depends only on VIN / VR, which this backend
        sets.  The inverse of DS p31 gives VIN = (raw / 2^23 - DCOS / RG) * RG * VR / IG; AD1_SCALE is the
        constant the chip uses, so the displayed value does not depend on whether 2^23 is the true scale.  The
        chip outputs the true two's-complement code: the firmware's decode of negative codes (FW 0x080062F8,
        spec 4.1) is not compensated.  No plan or no AD1 target: no voltages (the chip holds 0)."""
        if sel['conv'] != 'AD1':
            return {}
        p = self.plan()
        if not p['ok'] or p['raw'] is None:
            return {}
        if (sel['fp'] == sel['fn'] or sel['rh'] == sel['rl'] or sel['fp'] in (sel['rh'], sel['rl'])
                or sel['fn'] == sel['rh']):
            return {}                                  # selection cannot carry an independent input
        vr = VREF_ADR3412
        vin = (p['raw'] / AD1_SCALE - sel['dcos'] / sel['rg']) * sel['rg'] * vr / sel['ig']
        return {sel['rl']: 0.0, sel['rh']: vr, sel['fn']: 0.0, sel['fp']: vin}

    def status(self):
        """_Base.status plus the board temperature (TEMP cold junction and PA4)."""
        s = super().status()
        tb = self.board_c()
        s['board_c'] = round(tb, 2) if tb is not None else None
        return s


class NetlistFrontend(_Base):
    """Backend (a): ngspice solution of the front-end circuit.

    Deck: analysis/frontend_sim.cir (WRAPPER, found next to the netlist path given), which includes the device
    models analysis/frontend_models.lib and then the extracted netlist analysis/frontend_netlist.cir unchanged; the
    model file's binding subcircuits replace the netlist's port-only boundaries (ngspice keeps the first definition
    of a subcircuit name).  The backend expands the .include lines itself (paths relative to the including file;
    the '.end' of an included file is dropped) and appends '.param' overrides before the final '.end' (ngspice uses
    the last definition of a parameter):
      t1pos          dial row = board.dial (rows are matched by contact name: rows 1..8 LowZ, VOLTS, mV/Temp,
                     Hz/Duty, O/B/D/C, VA, uA, mA/A are board.DIAL positions 1..8, the off rows 0 / 9 the off
                     positions; analysis/frontend_netlist.md section 4 and analysis/rotary.md on the mirrored PG order)
      hy_<name>      HY3131 switch / multiplexer state decoded from the chip registers R24..R33 (hy_params(), tables
                     DS p22-p28); CMPO (comparator output, not modelled) is taken as 0
      mcu_<line>, drv_<line>   level and drive state of the MCU control lines (MCU_LINES: port and pin from the U4
                     symbol, frontend_sim.cir), read from the emulated GPIO ports through self.board.g
    A changed dial row, register decode or line state reloads the deck (about 15 ms).  The stimulus is applied with
    'alter' (DC) or, for an AC stimulus, written into the source lines (sine) of a reloaded deck.
      V      vstim = value (DC) between JACK_V and COM through rstim = 1 uohm (source resistance: design choice)
      ohm    vstim = 0, rstim = value
      A      current source into the current jack: istim_a when board.jacks holds 'A', otherwise istim_ma; the
             V jack is open (rstim = 1e12 ohm)
      VA     V and A together (value volts, 'amps' amperes)
      AC     (V / A / VA with ac): sine of RMS value (peak = sqrt(2) x RMS) at 'freq' plus the 'dc' component;
             transient analysis of AC_SETTLE s (design choice: about ten 75 ms time constants of the AD8436
             output filter 16 kohm x C86 4.7 uF) and the node voltages averaged over the last AD1 conversion period
             (1 / rate) are returned.  Frequencies above AC_FMAX are not offered (run time).
    The AD1 reads the internal nodes ad1p / ad1n / ad1rh / ad1rl of the HY3131 model (after the input
    multiplexer, the pre-filter and the SAD1I selection; reference multiplexers), returned under the pin names
    of the selection (sel['fp'], ...).  Not offered (reason in support()): stimulus kinds F, degC, diode (no
    netlist part represents them: capacitance mode needs the HY3131 MOS current source, the thermocouple EMF is a
    firmware table, the diode under test has no model), configurations that use the HY3131 OP3 / MOS current
    source path (SVSO2, SCP, SCN; DS p23, no device data) and the internal temperature sensor (SAD1I = 1x).
    Noise: ngspice noise analysis at the operating point, input source vstim, integrated over 0.1 Hz .. rate / 2
    (band: design choice): vin_sigma between ad1p and ad1n (thermal noise of the resistors, the ADR3412 and
    MAX4238 noise generators of the models, shot noise of the semiconductor models) and vref_sigma between
    ad1rh and ad1rl (replaces the fixed ADR3412 density of the base class).  code_sigma as in _Base.
    """
    kind = 'netlist'
    WRAPPER = 'frontend_sim.cir'
    DEFAULT_LIB = '/Applications/KiCad/KiCad.app/Contents/PlugIns/sim/libngspice.dylib'   # KiCad application bundle
    AC_SETTLE = 0.8                 # s, transient settling before the averaging window (class docstring)
    AC_FMAX = 20000.0               # Hz, highest AC stimulus frequency offered (run time of the transient)
    AC_PTS = 40                     # time points per signal period (maximum time step = period / AC_PTS)
    NODES = ('xu3.xhy.ad1p', 'xu3.xhy.ad1n', 'xu3.xhy.ad1rh', 'xu3.xhy.ad1rl')
    # MCU control lines: netlist / deck node -> (GPIO port, pin), U4 symbol text, LQFP144 pin numbers checked in
    # the STM32L152 data sheet; PWR_CTL / PWR_CTL2 by label alignment only (frontend_sim.cir)
    MCU_LINES = {'ctl_a': ('D', 0), 'ctl_b': ('C', 11), 'ctl_d': ('F', 4), 'ctl_e': ('F', 5), 'temp_ctl': ('H', 2),
                 'fre_ctl': ('A', 12), 'led_ck': ('E', 15), 'a_ctl': ('E', 5), 'enb': ('F', 6), 'shdn_a': ('E', 12),
                 'pwr_ctl': ('E', 9), 'pwr_ctl2': ('D', 1)}
    # SMODE<3:0> (with CMPO for SMODE<3> = 1) -> SGND SVDD SVSS SVSO1 SVSO2 SCP SCN (DS p23 table)
    SMODE_TAB = {0: (0, 0, 0, 0, 0, 0, 0), 1: (1, 0, 0, 0, 0, 0, 0), 2: (0, 1, 0, 0, 0, 0, 0), 3: (0, 0, 1, 0, 0, 0, 0),
                 4: (0, 0, 0, 1, 0, 0, 0), 5: (1, 0, 0, 1, 0, 0, 0), 6: (0, 1, 0, 0, 1, 1, 0), 7: (0, 0, 1, 0, 1, 0, 1)}
    # VREF of OP3 by SFUVR<3:0> for SMODE<3> = 0, and by SFUVR<2:0> -> (CMPO = 0, CMPO = 1) for SMODE<3> = 1 (DS p23)
    VREF_A = ('VDS17', 'VDS16', 'VDS15', 'AGNDP9', 'AGNDP8', 'AGNDP7', 'AGNDP6', 'AGNDP0', 'VDS1', 'VDS2', 'VDS3',
              'AGNDN9', 'AGNDN8', 'AGNDN7', 'AGNDN6', 'PB7')
    VREF_B = (('VDS17', 'VDS1'), ('VDS16', 'VDS2'), ('VDS15', 'VDS3'), ('AGNDP9', 'AGNDN9'), ('AGNDP8', 'AGNDN8'),
              ('AGNDP7', 'AGNDN7'), ('AGNDP6', 'AGNDN6'), ('AGNDP0', 'PB7'))
    K1 = {17: 35, 16: 34, 15: 32, 3: 4, 2: 2, 1: 1}            # VDSC<X>: K1 x 36 (DS p22 table)
    K2 = {'P9': (100, 110), 'P8': (80, 100), 'P7': (60, 90), 'P6': (40, 80), 'P0': (0, 60), 'N6': (-40, 40),
          'N7': (-60, 30), 'N8': (-80, 20), 'N9': (-100, 10)}  # AGND[P/N]<X>: (K2, K2B) x 120 (DS p22 table)

    def __init__(self, machine, netlist_path, lib_path=None, noise_counts=NOISE_COUNTS):
        super().__init__(machine, noise_counts)
        if not netlist_path or not os.path.isfile(netlist_path):
            raise FrontendUnavailable(f'netlist backend: {netlist_path} does not exist')
        wrapper = os.path.join(os.path.dirname(os.path.abspath(netlist_path)), self.WRAPPER)
        if not os.path.isfile(wrapper):
            raise FrontendUnavailable(f'netlist backend: simulation deck {wrapper} does not exist')
        included = []
        try:
            lines = self._expand(wrapper, included, top=True)
        except OSError as e:
            raise FrontendUnavailable(f'netlist backend: {e}')
        if os.path.realpath(netlist_path) not in included:
            raise FrontendUnavailable(f'netlist backend: {wrapper} does not include {netlist_path}')
        low = [l.strip().lower() for l in lines]
        if not any(l.startswith('xu3 ') for l in low) or not any(l.startswith('.subckt hy3131_ports') for l in low):
            raise FrontendUnavailable('netlist backend: the deck has no HY3131 instance XU3 or no HY3131_PORTS model')
        if not any(l.startswith('vstim jack_v') for l in low):
            raise FrontendUnavailable('netlist backend: the deck has no stimulus source vstim at JACK_V')
        self.lines = lines
        from .spice import Spice, SpiceError
        self.SpiceError = SpiceError
        lib = lib_path or os.environ.get('NGSPICE_LIB') or (self.DEFAULT_LIB if os.path.isfile(self.DEFAULT_LIB)
                                                             else None)
        try:
            self.spice = Spice(lib)
        except (OSError, SpiceError) as e:
            raise FrontendUnavailable(f'netlist backend: ngspice library not available ({e})')
        self._deck_key = None           # (config, AC stimulus or None) of the loaded deck
        self._applied = None            # alter tuple applied to the loaded deck since its load
        self._cache = {}
        self.last_error = ''
        try:                            # check of the deck as written (dial row, registers and lines of the file)
            self.spice.load(lines + ['.end'])
            self._deck_key = ('as written',)
            self.spice.op(self._alters())
            self.spice.cmd('destroy all')
        except SpiceError as e:
            raise FrontendUnavailable(f'netlist backend: deck does not solve as written ({e})')

    # ------------------------------------------------------------------ deck
    def _expand(self, path, included, top=False):
        """Lines of a deck with its .include lines replaced by the included files (recursively).  The included
        files' '.end' lines are dropped; the top file's final '.end' is removed (appended again with the
        overrides)."""
        path = os.path.realpath(path)
        included.append(path)
        with open(path) as f:
            src = [l.rstrip('\n') for l in f]
        out = []
        for l in src:
            t = l.split()
            if t and t[0].lower() == '.include':
                inc = l.strip()[len(t[0]):].strip().strip('"\'')
                out += self._expand(os.path.join(os.path.dirname(path), inc), included)
            elif t and t[0].lower() == '.end':
                continue
            else:
                out.append(l)
        return out

    @classmethod
    def hy_params(cls, reg, cmpo=0):
        """HY3131 model parameters (frontend_models.lib, subcircuit HY3131) from the registers (DS p22-p28).
        reg: register file indexed by address; cmpo: comparator output (DS p26 (4)) for the SMODE<3> = 1 rows."""
        p = {}
        for n in range(10):                                 # R2A..R2E: PSn DSn FSn SSn (DS p23 table)
            nib = reg[0x2A + n // 2] >> (4 if n & 1 else 0)
            p[f'ps{n}'], p[f'ds{n}'], p[f'fs{n}'], p[f'ss{n}'] = (nib >> 3) & 1, (nib >> 2) & 1, (nib >> 1) & 1, nib & 1
        smode = reg[0x2F] & 0x7F                            # R2F bits 6:0
        s30 = smode & 0x0F
        row = cls.SMODE_TAB[s30] if s30 < 8 else cls.SMODE_TAB[(((s30 >> 1) & 3) << 1) | cmpo]
        p['sgnd'], p['svdd'], p['svss'], p['svso1'], p['svso2'], p['scp'], p['scn'] = row
        p['sm4'], p['sm5'] = (smode >> 4) & 1, (smode >> 5) & 1
        r24 = reg[0x24]                                     # SAD1FP<3:0>, SDIO, SAD1FN<2:0>
        p['sad1fp'], p['sdio'], p['sad1fn'] = r24 >> 4, (r24 >> 3) & 1, r24 & 7
        p['sad1rh'], p['sad1rl'] = (reg[0x28] >> 4) & 7, reg[0x28] & 7
        p['sft1'], p['sad1i'] = (reg[0x33] >> 2) & 3, reg[0x33] & 3
        r32 = reg[0x32]                                     # ENOP2, SOP2P<2:0>, ENOP1, SOP1P<2:0>
        p['enop2'], p['sop2p'], p['enop1'], p['sop1p'] = r32 >> 7, (r32 >> 4) & 7, (r32 >> 3) & 1, r32 & 7
        p['sacm'], p['ops2'], p['ops1'] = (reg[0x25] >> 2) & 3, (reg[0x25] >> 1) & 1, reg[0x25] & 1
        r31 = reg[0x31]                                     # ENREFO, ENBIAS, SAGND<1:0>, SFUVR<3:0>
        p['enrefo'], p['sagnd'], sfuvr = r31 >> 7, (r31 >> 4) & 3, r31 & 0x0F
        p['srefo'], p['acc'] = reg[0x30] >> 7, reg[0x30] & 0x7F
        name = cls.VREF_B[sfuvr & 7][cmpo] if (smode >> 3) & 1 else cls.VREF_A[sfuvr]
        if name.startswith('VDS'):
            p['vref_type'], p['vref_k1'], p['vref_k2'], p['vref_k2b'] = 0, cls.K1[int(name[3:])] / 36, 0, 0
        elif name == 'PB7':
            p['vref_type'], p['vref_k1'], p['vref_k2'], p['vref_k2b'] = 2, 0, 0, 0
        else:
            k2, k2b = cls.K2[name[4:]]
            p['vref_type'], p['vref_k1'], p['vref_k2'], p['vref_k2b'] = 1, 0, k2 / 120, k2b / 120
        return p

    def _gpio(self):
        """{line: (level, drives)} of the MCU control lines from the emulated ports, or None without a board."""
        g = getattr(self.board, 'g', None) if self.board is not None else None
        if not g:
            return None
        out = {}
        for name, (port, pin) in self.MCU_LINES.items():
            lvl = g[port].output_level(pin) if port in g else None
            out[name] = (int(lvl or 0), 0 if lvl is None else 1)
        return out

    def _config(self):
        """(dial row, HY3131 parameter tuple, MCU line tuple) of the present state."""
        row = self.board.dial if self.board is not None else None
        hp = self.hy_params(self.chip.reg) if self.chip is not None else None
        gp = self._gpio()
        return (row, None if hp is None else tuple(sorted(hp.items())),
                None if gp is None else tuple(sorted(gp.items())))

    def _deck(self, cfg, ac):
        """Deck lines for a configuration and (for an AC stimulus) the sine source lines."""
        row, hp, gp = cfg
        add = []
        if row is not None:
            add.append(f'.param t1pos={row}')
        if hp is not None:
            add += ['.param ' + ' '.join(f'hy_{k}={v!r}' for k, v in hp[i:i + 8]) for i in range(0, len(hp), 8)]
        if gp is not None:
            add += [f'.param mcu_{k}={lvl} drv_{k}={drv}' for k, (lvl, drv) in gp]
        lines = list(self.lines)
        if ac is not None:                  # replace the stimulus source lines by their AC form
            for i, l in enumerate(lines):
                t = l.split()
                if t and t[0].lower() in ac:
                    lines[i] = ac[t[0].lower()]
        return lines + add + ['.end']

    def _ensure(self, cfg, ac):
        """Load the deck for cfg / ac unless it is loaded."""
        key = (cfg, None if ac is None else tuple(sorted(ac.items())))
        if key == self._deck_key:
            return True
        try:
            if self._deck_key is not None:
                self.spice.cmd('remcirc')
            self._deck_key = None
            self.spice.load(self._deck(cfg, ac))
        except self.SpiceError as e:
            self._fail(f'deck load: {e}')
            return False
        self._deck_key, self._applied = key, None
        return True

    def _fail(self, msg):
        self.last_error = msg
        self.m.log.append((self.m.cycles, f'netlist backend: {msg}'))

    # ------------------------------------------------------------------ stimulus
    def _jack(self):
        """Current source of the plugged current jack (class docstring)."""
        jacks = getattr(self.board, 'jacks', ()) if self.board is not None else ()
        return 'istim_a' if 'A' in jacks else 'istim_ma'

    def _alters(self):
        """'alter' list of the DC stimulus (AC: the DC component)."""
        st = self.stim
        k = st['kind']
        v = st['dc'] if st['ac'] else st['value']
        a = 0.0
        if k == 'A':
            a = 0.0 if st['ac'] else st['value']
        elif k == 'VA':
            a = 0.0 if st['ac'] else st['amps']
        vs = v if k in ('V', 'VA') else 0.0
        rs = max(st['value'], 1e-6) if k == 'ohm' else (1e12 if k == 'A' else 1e-6)
        jack = self._jack()
        return (('vstim', 'dc', float(vs)), ('rstim', '', float(rs)),
                ('istim_a', 'dc', float(a) if jack == 'istim_a' else 0.0),
                ('istim_ma', 'dc', float(a) if jack == 'istim_ma' else 0.0))

    def _ac_lines(self):
        """Sine source lines for an AC stimulus (or None for DC)."""
        st = self.stim
        if not st['ac'] or st['kind'] not in ('V', 'A', 'VA'):
            return None
        f = st['freq']
        vpk = math.sqrt(2.0) * st['value'] if st['kind'] in ('V', 'VA') else 0.0
        ipk = math.sqrt(2.0) * (st['value'] if st['kind'] == 'A' else st['amps'] if st['kind'] == 'VA' else 0.0)
        vdc = st['dc'] if st['kind'] in ('V', 'VA') else 0.0
        jack = self._jack()
        out = {'vstim': f'vstim JACK_V n_stim dc {vdc!r} ac 1 sin({vdc!r} {vpk!r} {f!r})',
               'istim_ma': 'istim_ma 0 JACK_MA dc 0', 'istim_a': 'istim_a 0 JACK_A dc 0'}
        if ipk:
            node = 'JACK_A' if jack == 'istim_a' else 'JACK_MA'
            out[jack] = f'{jack} 0 {node} dc 0 sin(0 {ipk!r} {f!r})'
        return out

    # ------------------------------------------------------------------ chip interface
    def support(self):
        """(supported, reason, mode, range): counter modes as _Base; AD1 modes by stimulus kind and by the
        HY3131 configuration (class docstring)."""
        mode, rng = self.fw_mode_range()
        if mode >= len(MODE_NAMES):
            return False, f'firmware mode {mode} unknown', mode, rng
        st = self.stim
        if mode in COUNTER_MODES:
            if st['ac'] and st['freq'] > 0:
                return True, 'counter input driven at the stimulus frequency', mode, rng
            return False, 'FREQ needs a stimulus with a frequency (kind Hz, or AC with freq)', mode, rng
        if st['kind'] not in ('V', 'ohm', 'A', 'VA'):
            return False, (f'netlist backend: stimulus kind {st["kind"]} has no netlist representation (capacitance '
                           'needs the HY3131 MOS current source, thermocouple EMF and diode under test have no '
                           'model)'), mode, rng
        if st['ac'] and not 0 < st['freq'] <= self.AC_FMAX:
            return False, f'netlist backend: AC stimulus needs 0 < freq <= {self.AC_FMAX:g} Hz', mode, rng
        if self.chip is not None:
            hp = self.hy_params(self.chip.reg)
            if hp['svso2'] or hp['scp'] or hp['scn']:
                return False, ('netlist backend: this range uses the HY3131 OP3 / MOS current source (SVSO2, SCP, '
                               'SCN; DS p23), which has no device data and is not modelled'), mode, rng
            if hp['sad1i'] >= 2:
                return False, 'netlist backend: AD1 input on the internal temperature sensor (not modelled)', mode, rng
        if self.last_error:
            return True, f'last solver message: {self.last_error}', mode, rng
        return True, '', mode, rng

    def _solve(self):
        """Node voltages NODES for the present state, or None (cached per configuration and stimulus)."""
        cfg, ac = self._config(), self._ac_lines()
        alt = self._alters()
        rate = self.chip.ad1_selection()['rate'] if (ac is not None and self.chip is not None) else 0.0
        key = ('v', cfg, alt, None if ac is None else tuple(sorted(ac.items())), rate)
        if key in self._cache:
            return self._cache[key]
        if not self._ensure(cfg, ac):
            return None
        try:
            if ac is None:
                r = self.spice.op(alt)
                self._applied = alt
                res = {n: r[n] for n in self.NODES}
            else:
                res = self._tran(alt, rate)
            self.spice.cmd('destroy all')       # results are copied: free ngspice's plots
        except (self.SpiceError, KeyError) as e:
            self._fail(f'solution: {e}')
            return None
        self.last_error = ''
        if len(self._cache) > 512:
            self._cache.pop(next(iter(self._cache)))
        self._cache[key] = res
        return res

    def _tran(self, alt, rate):
        """AC stimulus: transient from the operating point, mean of NODES over the last AD1 period."""
        f = self.stim['freq']
        win = 1.0 / rate if rate > 0 else 1.0 / f
        tstop = self.AC_SETTLE + win
        tmax = 1.0 / (f * self.AC_PTS)
        self.spice.op(alt)
        self._applied = alt
        self.spice.cmd(f'tran {tmax!r} {tstop!r} 0 {tmax!r}')
        t = self.spice.vec('time')
        res = {}
        for n in self.NODES:
            v = self.spice.vec(n)
            acc = w = 0.0
            for i in range(1, len(t)):
                if t[i] <= tstop - win:
                    continue
                t0 = max(t[i - 1], tstop - win)
                y0 = v[i - 1] + (v[i] - v[i - 1]) * (t0 - t[i - 1]) / (t[i] - t[i - 1]) if t[i] > t[i - 1] else v[i]
                acc += 0.5 * (y0 + v[i]) * (t[i] - t0)
                w += t[i] - t0
            res[n] = acc / w if w > 0 else v[-1]
        return res

    def pins(self, sel, t):
        """Voltages at the AD1 inputs and reference inputs, under the pin names of the selection."""
        if sel['conv'] != 'AD1':
            return {}
        ok, _, mode, rng = self.support()
        if not ok or mode in COUNTER_MODES:
            return {}
        res = self._solve()
        if res is None:
            return {}
        p, n, rh, rl = (res[k] for k in self.NODES)
        out = {}
        for name, v in ((sel['rl'], rl), (sel['rh'], rh), (sel['fn'], n), (sel['fp'], p)):
            if name:
                out[name] = v
        return out

    def _noise_between(self, a, b, sel):
        """Integrated output noise (V rms) between internal nodes a and b, 0.1 Hz .. rate / 2."""
        if sel['rate'] <= 0 or self.stim['ac']:
            return 0.0
        if self._solve() is None:
            return 0.0
        cfg, alt = self._config(), self._alters()
        key = ('n', cfg, alt, a, b, sel['rate'])
        if key not in self._cache:
            try:
                if self._applied != alt:
                    self.spice.op(alt)
                    self._applied = alt
                self._cache[key] = self.spice.noise('xu3.xhy.' + a, 'vstim', 0.1, sel['rate'] / 2.0,
                                                    ref_node='xu3.xhy.' + b)
                self.spice.cmd('destroy all')
            except self.SpiceError as e:
                self._fail(f'noise: {e}')
                return 0.0
        return self._cache[key]

    def _vin_sigma(self, sel):
        return self._noise_between('ad1p', 'ad1n', sel)

    def noise(self, sel):
        """_Base noise with the reference noise from the netlist (class docstring)."""
        d = super().noise(sel)
        d['vref_sigma'] = self._noise_between('ad1rh', 'ad1rl', sel)
        return d


def make_frontend(kind, machine, netlist_path=None, lib_path=None, noise_counts=NOISE_COUNTS):
    """Construct backend 'calibrated' or 'netlist' (the latter raises FrontendUnavailable with the reason).
    netlist: netlist_path is analysis/frontend_netlist.cir; the simulation deck NetlistFrontend.WRAPPER next to it
    (analysis/frontend_sim.cir) includes it with the device models.  lib_path: libngspice (default: NGSPICE_LIB,
    then NetlistFrontend.DEFAULT_LIB)."""
    if kind == 'calibrated':
        return CalibratedFrontend(machine, noise_counts)
    if kind == 'netlist':
        return NetlistFrontend(machine, netlist_path, lib_path, noise_counts)
    raise ValueError(f'unknown front-end backend {kind}')
