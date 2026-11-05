"""Values the companion derives from the decoded reading (display.decode) on the computer; the meter is not involved.

    rel_pct    percent change against the value the reading had when REL was switched on
    loop_pct   DC current as percent of a 4-20 mA or 0-20 mA loop
    pt_c       temperature of a Pt100 / Pt1000 sensor from the measured resistance (IEC 60751)
    limit      pass / fail against a low and a high limit of the user

Each value is None where it cannot be told, never guessed.  All maths is done on values in the SI base unit of the
reading (V, A, Ohm, Hz, ...), because the displayed unit changes with the range (display.TABLE: mV / V, Ohm / kOhm / MOhm).

REL.  With REL on the status frame carries the difference to the reference (display.py: the port-only REL percent view
is not in the frame, the frame keeps the counts), so rel_pct = difference / reference x 100.  The reference is the value
of the last reading before REL went on (same mode and quantity): the frame does not carry the reference itself, and
the meter's own reference is the value at the key press, which can differ from the previous reading by one frame of
noise.  Where the program connected while REL was already on, the reference is unknown and rel_pct stays None until REL
has been switched off and on again.  A reference of zero gives None (the meter shows "-----", USER_GUIDE.md REL in percent).

Loop.  Offered in the DC current modes DCuA, DCmA and DCA (modes 17, 19, 21); the meter's own LP view is DC mA only
(USER_GUIDE.md 4-20 mA loop).  p = (I - 4 mA) / 16 mA x 100 for 4-20, I / 20 mA x 100 for 0-20; below the start of the
range it goes negative (0 mA in a 4-20 mA loop = -25 %), as on the meter.  None while REL is on (the reading is then a
difference, not the current).

Pt.  Offered in the OHM mode (mode 9).  With REL on the reading is taken as the sensor resistance: the lead resistance
is removed by shorting the leads and pressing REL (USER_GUIDE.md PT100 / PT1000), so the difference is the sensor.
Range -200 .. 850 degC as the meter's view (outside: None).

Limit.  The limits are given with a unit (for example 99 and 101 ohm, or 4.9 and 5.1 V) and apply to readings of the
same quantity only (a limit in ohm gives no verdict on a voltage).  PASS = lo <= value <= hi, HI above, LO below; an
overload gives None (the frame does not carry its sign, display.py); None while REL is on (a difference is not the
quantity the limits are about).
"""
import math
import threading

MU, OMEGA = '\u00b5', '\u03a9'            # the micro sign and the Greek capital omega, as display.TABLE writes them
# displayed unit -> (quantity, factor to the SI base unit); every unit display.TABLE can produce, plus the temperature units
UNITS = {'V': ('V', 1.0), 'mV': ('V', 1e-3), 'Hz': ('Hz', 1.0), 'kHz': ('Hz', 1e3), 'ms': ('s', 1e-3), '%': ('%', 1.0),
         OMEGA: ('ohm', 1.0), 'k' + OMEGA: ('ohm', 1e3), 'M' + OMEGA: ('ohm', 1e6),
         'nF': ('F', 1e-9), MU + 'F': ('F', 1e-6), MU + 'VA': ('VA', 1e-6), 'mVA': ('VA', 1e-3), 'VA': ('VA', 1.0),
         MU + 'A': ('A', 1e-6), 'mA': ('A', 1e-3), 'A': ('A', 1.0), '°C': ('degC', 1.0), '°F': ('degF', 1.0)}
# the same units in plain ASCII, as a page or a script can type them
ALIASES = {'ohm': OMEGA, 'kohm': 'k' + OMEGA, 'mohm': 'M' + OMEGA, 'uF': MU + 'F', 'uA': MU + 'A', 'uVA': MU + 'VA',
           'degC': '°C', 'degF': '°F'}
MODE_OHM = 9                                         # display.MODES index of OHM
DC_CURRENT_MODES = (17, 19, 21)                      # DCuA, DCmA, DCA
LOOP_RANGES = {'4-20': (4.0, 20.0), '0-20': (0.0, 20.0)}    # mA at 0 % and 100 %
PT_TYPES = {'Pt100': 100.0, 'Pt1000': 1000.0}        # ohm at 0 degC
# IEC 60751 Callendar-Van Dusen coefficients of the usual "385" sensor
CVD_A, CVD_B, CVD_C = 3.9083e-3, -5.775e-7, -4.183e-12
PT_MIN_C, PT_MAX_C = -200.0, 850.0                   # the range of the standard and of the meter's view

DEFAULTS = {'loop_range': '4-20', 'pt_type': None, 'limit': None}


def unit_scale(unit):
    """(quantity, factor to the base unit) of a displayed unit; ValueError for an unknown one."""
    u = ALIASES.get(unit, unit)
    if u not in UNITS:
        raise ValueError('unknown unit %r' % (unit,))
    return UNITS[u]


def pt_resistance(t, r0):
    """Resistance in ohm of a Pt sensor with r0 ohm at 0 degC, at t degC (IEC 60751): the C term below 0 degC only."""
    r = 1.0 + CVD_A * t + CVD_B * t * t
    if t < 0.0:
        r += CVD_C * (t - 100.0) * t ** 3
    return r0 * r


def pt_temperature(r, r0):
    """Temperature in degC from the resistance, the inverse of pt_resistance solved by bisection (the curve rises
    monotonically over -200 .. 850 degC); None outside that range."""
    if not isinstance(r, (int, float)) or not math.isfinite(r):
        return None
    lo, hi = PT_MIN_C, PT_MAX_C
    if r < pt_resistance(lo, r0) or r > pt_resistance(hi, r0):
        return None
    for _ in range(100):                             # 1050 degC / 2^100: far below float resolution
        mid = (lo + hi) / 2.0
        if pt_resistance(mid, r0) < r:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


def _sign(x):
    return 1.0 if x >= 0 else -1.0


def _clean_limit(lim, current_unit):
    """Validated limit option {'lo', 'hi', 'unit'} (lo / hi in `unit`, either may be None) or None."""
    if lim is None:
        return None
    if not isinstance(lim, dict):
        raise ValueError('limit must be an object {lo, hi, unit} or null')
    out = {}
    for k in ('lo', 'hi'):
        v = lim.get(k)
        if v is None or v == '':
            out[k] = None
        elif isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
            raise ValueError('limit %s must be a number' % k)
        else:
            out[k] = float(v)
    if out['lo'] is None and out['hi'] is None:
        return None
    if out['lo'] is not None and out['hi'] is not None and out['lo'] > out['hi']:
        raise ValueError('limit: lo is above hi')
    unit = lim.get('unit') or current_unit
    if not unit:
        raise ValueError('limit needs a unit (no reading to take it from)')
    if not isinstance(unit, str):
        raise ValueError('limit unit must be text')
    unit_scale(unit)                                  # ValueError when unknown
    out['unit'] = ALIASES.get(unit, unit)
    return out


class Derived:
    def __init__(self, options=None):
        self._lock = threading.Lock()
        self.opt = dict(DEFAULTS)
        self.last = None                              # last reading (display.decode dictionary)
        self._abs = None                              # (mode, quantity, base value) of the last reading with REL off
        self._ref = None                              # same, the value when REL went on; None = unknown
        self._rel_on = False
        if options:
            self.set_options(options)

    # ------------------------------------------------------------------ options
    def options(self):
        """The options as stored in the program's settings file."""
        with self._lock:
            return dict(self.opt)

    def set_options(self, d):
        """Apply the keys given in `d` (loop_range, pt_type, limit); ValueError on a bad value; returns options()."""
        if not isinstance(d, dict):
            raise ValueError('derived options must be an object')
        with self._lock:
            new = dict(self.opt)
            if 'loop_range' in d:
                if not isinstance(d['loop_range'], str) or d['loop_range'] not in LOOP_RANGES:
                    raise ValueError('loop_range must be one of %s' % ', '.join(LOOP_RANGES))
                new['loop_range'] = d['loop_range']
            if 'pt_type' in d:
                if d['pt_type'] is not None and (not isinstance(d['pt_type'], str) or d['pt_type'] not in PT_TYPES):
                    raise ValueError('pt_type must be null or one of %s' % ', '.join(PT_TYPES))
                new['pt_type'] = d['pt_type']
            if 'limit' in d:
                cur = self.last['unit'] if self.last else None
                new['limit'] = _clean_limit(d['limit'], cur)
            self.opt = new
            return dict(new)

    # ------------------------------------------------------------------ readings
    def feed(self, r):
        """Track REL from every decoded reading (called for each status frame, in order)."""
        with self._lock:
            self.last = r
            base = self._base(r)
            rel = 'REL' in r.get('symbols', [])
            if not rel:
                self._abs, self._ref, self._rel_on = base, None, False
                return
            if not self._rel_on:                      # REL has just gone on: the reference is the reading before
                self._rel_on = True
                a = self._abs
                self._ref = a if a and base and a[0] == base[0] and a[1] == base[1] else None
            elif self._ref is not None and (base is None or self._ref[0] != base[0] or self._ref[1] != base[1]):
                self._ref = None                      # mode or quantity changed while REL stayed on: reference void

    @staticmethod
    def _base(r):
        """(mode, quantity, value in base units) of a numeric reading, else None."""
        if r.get('value') is None:
            return None
        try:
            q, f = unit_scale(r.get('unit') or '')
        except ValueError:
            return None
        return r['mode'], q, r['value'] * f

    def snapshot(self):
        """state.derived for the page."""
        with self._lock:
            r, opt = self.last, self.opt
            base = self._base(r) if r else None
            rel = bool(r) and 'REL' in r.get('symbols', [])
            out = {'rel_pct': None, 'loop_pct': None, 'loop_range': opt['loop_range'], 'pt_c': None,
                   'pt_type': opt['pt_type'], 'limit': {'lo': None, 'hi': None, 'unit': None, 'verdict': None}}
            lim = opt['limit']
            if lim:
                out['limit'].update(lo=lim['lo'], hi=lim['hi'], unit=lim['unit'])
            if base is None:
                return out
            mode, quantity, v = base
            if rel and self._ref is not None and self._ref[2] != 0.0:
                out['rel_pct'] = v / self._ref[2] * 100.0
            if mode in DC_CURRENT_MODES and not rel:
                lo, hi = LOOP_RANGES[opt['loop_range']]
                out['loop_pct'] = (v * 1000.0 - lo) / (hi - lo) * 100.0
            if mode == MODE_OHM and opt['pt_type']:
                out['pt_c'] = pt_temperature(v, PT_TYPES[opt['pt_type']])
            if lim and not rel:
                lq, lf = unit_scale(lim['unit'])
                if lq == quantity:
                    # a relative tolerance of 1e-9 keeps a reading exactly on a limit PASS across unit conversions
                    if lim['lo'] is not None and v < lim['lo'] * lf * (1 - 1e-9 * _sign(lim['lo'])):
                        out['limit']['verdict'] = 'LO'
                    elif lim['hi'] is not None and v > lim['hi'] * lf * (1 + 1e-9 * _sign(lim['hi'])):
                        out['limit']['verdict'] = 'HI'
                    else:
                        out['limit']['verdict'] = 'PASS'
            return out
