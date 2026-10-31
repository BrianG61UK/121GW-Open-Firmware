"""STM32L152ZD real-time clock (RTC), RM0038 chapter 20, block at 0x4000 2800 (category 4 device).

Register map (RM0038 20.6, table 91, word access only, 20.6 intro):
    0x00 TR      0x04 DR      0x08 CR      0x0C ISR     0x10 PRER    0x14 WUTR    0x18 CALIBR  0x1C ALRMAR
    0x20 ALRMBR  0x24 WPR     0x28 SSR     0x2C SHIFTR  0x30 TSTR    0x34 TSDR    0x38 TSSSR   0x3C CALR
    0x40 TAFCR   0x44 ALRMASSR 0x48 ALRMBSSR 0x50..0xCC BKP0R..BKP31R (32 backup registers, Cat.4, 20.6.20)
Offsets 0x4C and above 0xCC are not described in RM0038; they, sub-word accesses and the features listed under
"not modelled" below are routed to unmodelled() and never ignored silently.

Time base
- The RTC counts RTCCLK pulses.  RTCCLK comes from the RCC model (rcc.rtc_clock_hz(): RTCEN = 1 and the selected
  oscillator ready, RM0038 6.3.14).  Pulses are counted on the machine's emulated real time (Machine.elapsed_s(), the
  cycle count integrated over the core clock history), exactly, with Fractions.  Every RCC change that can alter the
  clock reaches clock_changed() through rcc.rtc_clock_hooks; RTC domain resets reach domain_reset() through
  rcc.rtc_reset_hooks (RM0038 6.1.3, 6.3.14 RTCRST).  Queued events are in core cycles, so a core clock change
  (Machine.clock_hooks) re-times them.
- Prescalers (20.3.1, 20.6.5): ck_apre = RTCCLK / (PREDIV_A + 1); SS is a down-counter on ck_apre that reloads from
  PREDIV_S after 0; the calendar advances one second at each reload (20.6.11: fraction = (PREDIV_S - SS)/(PREDIV_S+1)).
  The counter chain is described by an anchor (pulse, SS, calendar second); every state is computed from the pulse
  count, so nothing runs between events.  Alarms, the wakeup timer and the time stamp are scheduled events.

Modelled
- TR/DR/SSR shadow registers copied every 2 RTCCLK, RSF, BYPSHAD, the TR -> DR read lock (20.3.2, 20.3.6, 20.6.4).
- Write protection: PWR_CR.DBP (20.3.5, 5.1.3), key 0xCA 0x53 in WPR, unprotected ISR[13:8], TAFCR, BKPxR (20.3.5).
- INIT / INITF / INITS, calendar load on INIT exit, restart after 4 RTCCLK (20.3.5), 24 h and AM/PM formats.
- ADD1H / SUB1H (next second), shift (SHIFTR, SHPF), alarms A and B with date/weekday, hour, minute, second and
  sub-second masks, wakeup timer with all clock selections, ALRAWF/ALRBWF/WUTWF/RECALPF.
- Time stamp and tamper detection (edge and filtered level modes) on the RTC_AF1 input (PC13, attach_af1()) and
  tamper inputs 2 and 3 (tamper_input()); backup registers reset by a tamper event.
- EXTI lines 17 (alarm), 19 (time stamp / tamper) and 20 (wakeup) are driven as the level of "flag AND enable"
  (20.5, tables 89 and 90); PWR_CSR.WUF is set through PWR.wakeup_event('RTC') when such a flag is raised.
- POR / RTC domain reset and system reset values of every register (20.6.x "reset value" lines, 20.3.7).

Not modelled (reported through unmodelled() when software enables them)
- Smooth calibration (CALR: CALP, CALM, CALW8, CALW16) and coarse calibration (CALIBR with DCE = 1, DC != 0): the
  calendar keeps counting uncalibrated.  RTC_CALIB / RTC_ALARM outputs on RTC_AF1 (CR.COE, CR.OSEL != 0): the pin
  is not taken over from the GPIO model.  Reference clock detection (CR.REFCKON) has no input source on this board,
  which 20.3.9 defines as "reference clock halted" (calendar from RTCCLK alone), so it needs no action.
- Stop / Standby behaviour (shadow registers frozen, 20.3.2) because the emulator does not enter those modes.

Facts RM0038 does not give; the model's choice is stated here and where it is applied
- Leap years are the years divisible by 4 (20.1 only says leap years are compensated).
- Weekday increments with the date; it is a free counter 1..7 (Monday .. Sunday, 20.6.2).
- 12 h format: 12 AM is hour 0 and 12 PM is hour 12 of the 24 h count.
- RM0038 gives "1 to 2 RTCCLK" for the synchronisation delays of INITF, WUTWF, CR enable bits; the model uses 2.
- Loading an out-of-range BCD value (month 0, hour 25, ...) clamps each field to its legal range.
- In INIT mode TR / DR / SSR show the counters as frozen at INITF; the first shadow copy after INIT exit happens at
  the first even RTCCLK pulse after the counters restart.
- A shift completes at the next ck_apre pulse; the wakeup timer on ck_spre restarts when the prescaler anchor changes.
- ALRMBSSR is writable when ALRBE is clear (RM0038 20.6.19 names ALRBIE, a typo of the ALRAE rule of 20.6.18).
- Tamper pre-charge (TAMPPUDIS, TAMPPRCH) has no effect on an externally driven pin and is not simulated.
"""
import bisect
import math
from fractions import Fraction

from .base import Periph

# ---------------------------------------------------------------- calendar arithmetic (shared with the NJU6350 model)
MONTH_DAYS = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)


def is_leap(y):
    return y % 4 == 0


def days_in_month(y, m):
    return 29 if (m == 2 and is_leap(y)) else MONTH_DAYS[m - 1]


def days_before_year(y):
    return 365 * y + (y + 3) // 4              # years 0..y-1; the leap years among them are 0, 4, 8, ...


def to_days(y, m, d):
    """Day number counted from 1 January of year 0."""
    return days_before_year(y) + sum(days_in_month(y, k) for k in range(1, m)) + d - 1


def from_days(n):
    y = n // 366
    while days_before_year(y + 1) <= n:
        y += 1
    n -= days_before_year(y)
    m = 1
    while n >= days_in_month(y, m):
        n -= days_in_month(y, m)
        m += 1
    return y, m, n + 1


def bcd(tens, units):
    return tens * 10 + units


# ---------------------------------------------------------------- register offsets (20.6.21)
TR, DR, CR, ISR, PRER, WUTR, CALIBR, ALRMAR, ALRMBR, WPR = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24
SSR, SHIFTR, TSTR, TSDR, TSSSR, CALR, TAFCR, ALRMASSR, ALRMBSSR = 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40, 0x44, 0x48
BKP0, BKP31 = 0x50, 0xCC

# RTC_CR bits (20.6.3)
CR_WUCKSEL = 0x7
CR_TSEDGE, CR_REFCKON, CR_BYPSHAD, CR_FMT, CR_DCE = 1 << 3, 1 << 4, 1 << 5, 1 << 6, 1 << 7
CR_ALRAE, CR_ALRBE, CR_WUTE, CR_TSE = 1 << 8, 1 << 9, 1 << 10, 1 << 11
CR_ALRAIE, CR_ALRBIE, CR_WUTIE, CR_TSIE = 1 << 12, 1 << 13, 1 << 14, 1 << 15
CR_ADD1H, CR_SUB1H, CR_BKP, CR_COSEL, CR_POL = 1 << 16, 1 << 17, 1 << 18, 1 << 19, 1 << 20
CR_OSEL, CR_COE = 3 << 21, 1 << 23
CR_MASK = 0x00FFFFFF
CR_INIT_ONLY = CR_DCE | CR_FMT | CR_REFCKON          # bits 7, 6, 4: writable in initialization mode only

# RTC_ISR bits (20.6.4); the flags live in bits 15:8 exactly as in the register
ISR_ALRAWF, ISR_ALRBWF, ISR_WUTWF, ISR_SHPF, ISR_INITS, ISR_RSF, ISR_INITF, ISR_INIT = 1, 2, 4, 8, 16, 32, 64, 128
F_ALRAF, F_ALRBF, F_WUTF, F_TSF, F_TSOVF, F_TAMP1F, F_TAMP2F, F_TAMP3F = (1 << 8, 1 << 9, 1 << 10, 1 << 11, 1 << 12,
                                                                          1 << 13, 1 << 14, 1 << 15)
F_TAMPERS = F_TAMP1F | F_TAMP2F | F_TAMP3F
ISR_RECALPF = 1 << 16
ISR_UNPROTECTED_FLAGS = 0x3F00                       # ISR[13:8] stay writable without the key (20.3.5, 20.6.4 note)

# RTC_TAFCR bits (20.6.17)
TAF_MASK = 0x0004FFFF
TAF_TAMP1E, TAF_TAMPIE, TAF_TAMPTS = 1 << 0, 1 << 2, 1 << 7

# register reset values (20.6.x)
PRER_RESET = 0x007F00FF
WUTR_RESET = 0xFFFF
DR_RESET = 0x00002101                                 # 20.6.2: 00-01-01, Monday (WDU = 001)
SYNC_PULSES = 2                                       # synchronisation delay used for "1 to 2 RTCCLK" (20.3.5)
RESTART_PULSES = 4                                    # counting restarts 4 RTCCLK after INIT is cleared (20.3.5)
MAX_ALARM_DAYS = 3000                                 # alarm date search horizon (Feb 29 recurs every 4 years)


class _PulseClock:
    """Counts RTCCLK pulses on the machine's real-time base (exact)."""

    def __init__(self, m):
        self.m = m
        self.hz = 0
        self.acc = Fraction(0)             # pulses counted before the current segment
        self.t0 = m.elapsed_s()            # real time at the start of the current segment

    def exact(self):
        return self.acc + (self.m.elapsed_s() - self.t0) * self.hz

    def n(self):
        """Index of the last RTCCLK pulse that has occurred (0 before the first)."""
        return math.floor(self.exact())

    def retune(self, hz):
        self.acc = self.exact()
        self.t0 = self.m.elapsed_s()
        self.hz = hz

    def reset(self):
        self.acc = Fraction(0)
        self.t0 = self.m.elapsed_s()

    def time_of(self, pulse):
        """Emulated time at which pulse number `pulse` occurs (None without a clock)."""
        if not self.hz:
            return None
        return self.t0 + (pulse - self.acc) / self.hz


class RTC(Periph):
    name = "RTC"
    base = 0x40002800

    def __init__(self, exti=None):
        self._m = None
        super().__init__()
        self.exti = exti
        self._clk = None
        self._af1 = 0
        self._tin = {1: 0, 2: 0, 3: 0}     # tamper input levels (1 = RTC_AF1)
        self._logged = set()
        self._gen = 0
        self._seq = 0
        self._lines_now = {17: 0, 19: 0, 20: 0}
        self._por_state()

    # ------------------------------------------------------------------ attach to the machine
    @property
    def m(self):
        return self._m

    @m.setter
    def m(self, machine):
        self._m = machine
        if machine is None:
            return
        machine.rtc = self
        self._clk = _PulseClock(machine)
        machine.clock_hooks.append(self._arm)      # queued events are in core cycles: re-time them on a core clock change
        rcc = getattr(machine, 'rcc', None)
        if rcc is not None:
            rcc.rtc_reset_hooks.append(self.domain_reset)
            rcc.rtc_clock_hooks.append(self.clock_changed)
            self._clk.retune(rcc.rtc_clock_hz())

    def attach_af1(self, port, pin=13):
        """Connect RTC_AF1 (PC13, RM0038 7.3.15) to the pad of a GPIO model: time stamp and tamper 1 input."""
        port.on_output(pin, lambda p, level, cycles: self.af1_input(port.pad_level(pin)))
        self._af1 = port.pad_level(pin)
        self._tin[1] = self._af1

    # ------------------------------------------------------------------ reset
    def _por_state(self):
        """Power-on / RTC domain reset values (20.6.x, 20.3.7)."""
        self.cr = 0                                    # 20.6.3
        self.prer = PRER_RESET                         # 20.6.5
        self.wutr = WUTR_RESET                         # 20.6.6
        self.calibr = 0                                # 20.6.7
        self.alrmar = self.alrmbr = 0                  # 20.6.8, 20.6.9
        self.alrmassr = self.alrmbssr = 0              # 20.6.18, 20.6.19
        self.calr = 0                                  # 20.6.16
        self.tafcr = 0                                 # 20.6.17
        self.bkp = [0] * 32                            # 20.6.20
        self.tstr = self.tsdr = self.tsssr = 0         # 20.6.13 - 20.6.15
        self.flags = 0                                 # ISR bits 15:8
        self.init = False
        self.init_n = None
        self.wp = 0                                    # 0 locked, 1 after 0xCA, 2 unlocked (20.3.5)
        # counter chain: calendar 2000-01-01 Monday 00:00:00 running from pulse 0 (20.6.1, 20.6.2 reset values)
        self.run = True
        self.cha, self.chs = 0x7F, 0xFF
        self.na, self.ssa = 0, 0xFF
        self.anchor_inc = False
        self.ca = to_days(0, 1, 1) * 86400
        self.wda = 1
        self._fz = None                                # counters at INITF (kept for a system reset in INIT mode)
        # shadow registers (20.3.2); POR value of TR/DR/SSR (20.6.1, 20.6.2, 20.6.11), first copy at pulse 2
        self.sh_tr, self.sh_dr, self.sh_ss = 0, DR_RESET, 0
        self.first_copy = self.rsf_p = 2
        self._lk_tr = self._lk_dr = None
        # wakeup timer, alarms, shift, time stamp
        self.wut_start = None
        self._wut_k = 0
        self._wut_b0 = 0
        self.wutwf_val, self.wutwf_n = True, 0         # WUTWF = 1 at reset (ISR reset value 0x7, 20.6.4)
        self._alr_eff = [None, None]
        self._alr_last = [-1, -1]
        self._pend = []                                # (pulse, seq, kind, arg), sorted
        self.shift_p = None                            # pulse at which a shift completes (SHPF)
        self.recalpf_n = None                          # RECALPF is 1 until this pulse
        self._ts_pending = False
        self._tsig = {1: 0, 2: 0, 3: 0}
        self._tcnt = {1: 0, 2: 0, 3: 0}
        self._tsamp = None                             # next tamper sampling pulse
        self._tsamp_per = 0
        self._pend_hour = None

    def domain_reset(self):
        """Power-on reset or RTCRST: every RTC register returns to its reset value, the RTC stops (20.3.7)."""
        self._gen += 1
        self._por_state()
        if self._clk is not None:
            self._clk.reset()
        self._lines()

    def reset(self, kind='system'):
        """kind 'por': as domain_reset().  'system': the shadow registers return to their defaults, INIT, INITF and
        RSF clear, everything else is kept (20.3.7, 20.6.1 - 20.6.4); the write protection is not affected (20.3.5)."""
        if kind == 'por':
            self.domain_reset()
            return
        n = self._sync()
        if self.init:
            self.init = False
            if not self.run:                           # leave INIT with the counters as they were frozen
                secs, wd, ss = self._fz
                self._anchor(n + RESTART_PULSES, secs, wd, ss)
            self.init_n = None
        self.sh_tr, self.sh_dr, self.sh_ss = 0, DR_RESET, 0
        self.first_copy = self.rsf_p = (n // 2 + 1) * 2
        self._lk_tr = self._lk_dr = None
        self._arm()

    # ------------------------------------------------------------------ clock hooks
    def clock_changed(self):
        """RCC reports that RTCEN, RTCSEL, the selected oscillator or RTCPRE changed."""
        hz = self.m.rcc.rtc_clock_hz()
        if hz != self._clk.hz:
            self._sync()
            self._clk.retune(hz)
            self._arm()

    def _log(self, text):
        self.m.log.append((self.m.cycles, "RTC: " + text))

    def _log_once(self, key, text):
        if key not in self._logged:
            self._logged.add(key)
            self._log(text)

    # ------------------------------------------------------------------ counter chain
    def _anchor(self, pulse, secs, wd, ss, inc=False):
        """Start the chain at `pulse` with calendar second `secs`, weekday `wd` and SS = ss (from PRER).
        inc: the anchor tick is a calendar second increment (an hour change at a second boundary)."""
        self.run = True
        self.anchor_inc = inc
        self.cha = self.prer >> 16 & 0x7F
        self.chs = self.prer & 0x7FFF
        self.na, self.ssa, self.ca, self.wda = pulse, ss, secs, wd
        self._wut_restart()

    def _tick(self, n):
        return max(0, (n - self.na) // (self.cha + 1))      # before the anchor the counters hold the loaded values

    def _sec_ss(self, t):
        """(calendar seconds elapsed since the anchor, SS) at ck_apre tick t after the anchor (20.3.1)."""
        if t <= self.ssa:
            return 0, self.ssa - t
        d = t - self.ssa - 1
        return 1 + d // (self.chs + 1), self.chs - d % (self.chs + 1)

    def _ts_start(self, c):
        """ck_apre tick at which calendar second number c (0 = the anchor second) begins."""
        return 0 if c == 0 else self.ssa + 1 + (c - 1) * (self.chs + 1)

    def _wd_of(self, secs):
        return (self.wda - 1 + secs // 86400 - self.ca // 86400) % 7 + 1

    def _state(self, n):
        """(absolute seconds, weekday, SS) of the counters at pulse n (n >= na)."""
        c, ss = self._sec_ss(self._tick(n))
        secs = self.ca + c
        return secs, self._wd_of(secs), ss

    def _boundary_pulse(self, b):
        return self.na + self._ts_start(b) * (self.cha + 1)

    def _boundaries_upto(self, n):
        return 0 if n < self.na else self._sec_ss(self._tick(n))[0]

    def _regs(self, secs, wd, ss):
        """(TR, DR, SS) register images of a calendar state (20.6.1, 20.6.2) in the current hour format."""
        days, tod = divmod(secs, 86400)
        y, mo, d = from_days(days)
        h, r = divmod(tod, 3600)
        mi, s = divmod(r, 60)
        pm = 0
        if self.cr & CR_FMT:
            pm = 1 if h >= 12 else 0
            h = h % 12 or 12
        tr = pm << 22 | (h // 10) << 20 | h % 10 << 16 | (mi // 10) << 12 | mi % 10 << 8 | (s // 10) << 4 | s % 10
        yy = y % 100
        dr = ((yy // 10) << 20 | yy % 10 << 16 | wd << 13 | (mo // 10) << 12 | mo % 10 << 8 |
              (d // 10) << 4 | d % 10)
        return tr, dr, ss

    def _load(self, tr, dr):
        """Calendar (absolute seconds, weekday) from TR and DR; out-of-range BCD values are clamped."""
        s = min(bcd(tr >> 4 & 7, tr & 15), 59)
        mi = min(bcd(tr >> 12 & 7, tr >> 8 & 15), 59)
        h = bcd(tr >> 20 & 3, tr >> 16 & 15)
        if self.cr & CR_FMT:
            h = min(max(h, 1), 12) % 12 + (12 if tr >> 22 & 1 else 0)
        else:
            h = min(h, 23)
        y = min(bcd(dr >> 20 & 15, dr >> 16 & 15), 99)
        mo = min(max(bcd(dr >> 12 & 1, dr >> 8 & 15), 1), 12)
        d = min(max(bcd(dr >> 4 & 3, dr & 15), 1), days_in_month(y, mo))
        wd = min(max(dr >> 13 & 7, 1), 7)
        return to_days(y, mo, d) * 86400 + h * 3600 + mi * 60 + s, wd

    def _reanchor(self, pulse, delta_secs=0, delta_ss=0, inc=False):
        """Continue the chain from its state at `pulse` (a ck_apre pulse) with the calendar and SS changed."""
        secs, wd, ss = self._state(pulse)
        new = secs + delta_secs
        wd = (wd - 1 + new // 86400 - secs // 86400) % 7 + 1
        self._anchor(pulse, new, wd, min(ss + delta_ss, 0xFFFF), inc)

    # ------------------------------------------------------------------ synchronisation and flags
    def _initf(self, n):
        return self.init and self.init_n is not None and n >= self.init_n + SYNC_PULSES

    def _shpf(self, n):
        return self.shift_p is not None and n < self.shift_p

    def _wutwf(self, n):
        return self.wutwf_val if n >= self.wutwf_n else not self.wutwf_val

    def _rsf(self, n):
        return not (self.init or self._shpf(n) or self.cr & CR_BYPSHAD) and n >= self.rsf_p

    def _recalpf(self, n):
        return self.recalpf_n is not None and n < self.recalpf_n

    def _sync(self):
        """Bring the model to the current RTCCLK pulse: apply due state changes in time order, freeze the counters
        when INITF is reached.  Returns the pulse index."""
        n = self._clk.n()
        if self.init and self.run and self._initf(n):
            self._apply_due(self.init_n + SYNC_PULSES - 1)     # events before INITF act on the running counters
            self._freeze(self.init_n + SYNC_PULSES)
        self._apply_due(n)
        return n

    def _apply_due(self, limit):
        while self._pend and self._pend[0][0] <= limit:
            pulse, _, kind, arg = self._pend.pop(0)
            self._apply(pulse, kind, arg)

    def _add_pend(self, pulse, kind, arg=None):
        self._seq += 1
        bisect.insort(self._pend, (pulse, self._seq, kind, arg))

    def _freeze(self, pulse):
        """INITF reached: the counters stop (20.3.5); TR, DR and SSR show them (model choice, see module docstring)."""
        if pulse >= self.na:
            self._fz = self._state(pulse)
            self.sh_tr, self.sh_dr, self.sh_ss = self._regs(*self._fz)
        else:
            self._fz = self._load(self.sh_tr, self.sh_dr) + (self.chs,)
        self.run = False
        self._lk_tr = self._lk_dr = None

    def _exit_init(self, n):
        """INIT cleared: the calendar counters load TR and DR and restart after 4 RTCCLK (20.3.5)."""
        self.init_n = None
        if self.run:                                    # INIT cleared before INITF: nothing was stopped
            return
        secs, wd = self._load(self.sh_tr, self.sh_dr)
        self._anchor(n + RESTART_PULSES, secs, wd, self.prer & 0x7FFF)
        self.first_copy = self.rsf_p = self.na + (self.na & 1)
        self._lk_tr = self._lk_dr = None
        self._log(f"calendar loaded, counting restarts at pulse {self.na}")

    def _apply(self, pulse, kind, arg):
        if kind == 'shift':
            subfs, add1s = arg
            if self.run:                               # dropped when INIT stopped the counters meanwhile
                self._reanchor(pulse, 1 if add1s else 0, subfs)
            self.shift_p = None
            self.rsf_p = (pulse // 2 + 1) * 2
        elif kind == 'hour':
            if self.run:
                self._reanchor(pulse, arg * 3600, inc=True)
            self._pend_hour = None
        elif kind == 'tsflag':
            self._ts_flag(arg)

    def _set_flag(self, bit):
        self.flags |= bit
        if self._irq_of(bit):
            pwr = getattr(self.m, 'pwr', None)
            if pwr is not None:
                pwr.wakeup_event('RTC')              # RTC event wakes Stop / Standby, sets PWR_CSR.WUF (5.4.2)
        self._lines()

    def _irq_of(self, bit):
        """True when `bit` is an interrupt source whose enable bit is set (20.5 table 90)."""
        if bit & F_ALRAF:
            return bool(self.cr & CR_ALRAIE)
        if bit & F_ALRBF:
            return bool(self.cr & CR_ALRBIE)
        if bit & F_WUTF:
            return bool(self.cr & CR_WUTIE)
        if bit & F_TSF:
            return bool(self.cr & CR_TSIE)
        if bit & F_TAMPERS:
            return bool(self.tafcr & TAF_TAMPIE)
        return False

    def _lines(self):
        """Drive the EXTI lines: 17 alarm, 19 time stamp / tamper, 20 wakeup (20.5)."""
        f, cr = self.flags, self.cr
        lv = {17: bool(f & F_ALRAF and cr & CR_ALRAIE or f & F_ALRBF and cr & CR_ALRBIE),
              19: bool(f & F_TSF and cr & CR_TSIE or f & F_TAMPERS and self.tafcr & TAF_TAMPIE),
              20: bool(f & F_WUTF and cr & CR_WUTIE)}
        for line, level in lv.items():
            level = int(level)
            if level != self._lines_now[line]:
                self._lines_now[line] = level
                if self.exti is not None:
                    self.exti.line_input(line, level)

    # ------------------------------------------------------------------ shadow registers (20.3.2, 20.3.6)
    def _shadow(self, n):
        if self.cr & CR_BYPSHAD:                       # direct counter access
            if self.run and n >= self.na:
                return self._regs(*self._state(n))
            return self.sh_tr, self.sh_dr, self.sh_ss
        ne = n & ~1                                    # copied every 2 RTCCLK
        if self.run and ne >= max(self.na, self.first_copy):
            return self._regs(*self._state(ne))
        return self.sh_tr, self.sh_dr, self.sh_ss

    def _rd_tr(self, n):
        tr, dr, _ = self._shadow(n)
        if self.cr & CR_BYPSHAD:
            return tr
        if self._lk_tr is not None:
            return self._lk_tr
        if self._lk_dr is None:                        # reading TR locks DR until DR is read (20.3.6)
            self._lk_dr = dr
        return tr

    def _rd_dr(self, n):
        _, dr, _ = self._shadow(n)
        if self.cr & CR_BYPSHAD:
            return dr
        v = self._lk_dr if self._lk_dr is not None else dr
        self._lk_tr = self._lk_dr = None
        return v

    def _rd_ss(self, n):
        tr, dr, ss = self._shadow(n)
        if not self.cr & CR_BYPSHAD:                   # reading SSR locks TR and DR (20.3.6)
            if self._lk_tr is None:
                self._lk_tr = tr
            if self._lk_dr is None:
                self._lk_dr = dr
        return ss

    def _isr(self, n):
        _, dr, _ = self._shadow(n)
        v = self.flags
        if self.init:
            v |= ISR_INIT
        initf = self._initf(n)
        if initf:
            v |= ISR_INITF
        else:
            v |= ISR_ALRAWF | ISR_ALRBWF               # always set outside initialization mode (20.3.5, 20.6.4)
        if self._rsf(n):
            v |= ISR_RSF
        if dr >> 16 & 0xFF:
            v |= ISR_INITS                             # year field != 0 (20.6.4)
        if self._shpf(n):
            v |= ISR_SHPF
        if self._wutwf(n):
            v |= ISR_WUTWF
        if self._recalpf(n):
            v |= ISR_RECALPF
        return v

    # ------------------------------------------------------------------ bus
    def read(self, off, size):
        if size != 4 or off & 3:                       # RTC registers are word accessible only (20.6)
            self.unmodelled(off, 'R')
            return 0
        n = self._sync()
        if off == TR:
            return self._rd_tr(n)                      # 20.6.1
        if off == DR:
            return self._rd_dr(n)                      # 20.6.2
        if off == CR:
            return self.cr                             # 20.6.3, ADD1H / SUB1H read 0
        if off == ISR:
            return self._isr(n)                        # 20.6.4
        if off == PRER:
            return self.prer                           # 20.6.5
        if off == WUTR:
            return self.wutr                           # 20.6.6
        if off == CALIBR:
            return self.calibr                         # 20.6.7
        if off == ALRMAR:
            return self.alrmar                         # 20.6.8
        if off == ALRMBR:
            return self.alrmbr                         # 20.6.9
        if off == WPR:
            return 0                                   # 20.6.10: reads 0x00
        if off == SSR:
            return self._rd_ss(n)                      # 20.6.11
        if off == SHIFTR:
            return 0                                   # 20.6.12: write only, reads 0
        if off == TSTR:
            return self.tstr                           # 20.6.13
        if off == TSDR:
            return self.tsdr                           # 20.6.14
        if off == TSSSR:
            return self.tsssr                          # 20.6.15
        if off == CALR:
            return self.calr                           # 20.6.16
        if off == TAFCR:
            return self.tafcr                          # 20.6.17
        if off == ALRMASSR:
            return self.alrmassr                       # 20.6.18
        if off == ALRMBSSR:
            return self.alrmbssr                       # 20.6.19
        if BKP0 <= off <= BKP31:
            return self.bkp[(off - BKP0) >> 2]         # 20.6.20
        self.unmodelled(off, 'R')
        return 0

    def write(self, off, value, size):
        if size != 4 or off & 3:
            self.unmodelled(off, 'W')
            return
        if not (off in (TR, DR, CR, ISR, PRER, WUTR, CALIBR, ALRMAR, ALRMBR, WPR, SHIFTR, CALR, TAFCR, ALRMASSR,
                        ALRMBSSR, SSR, TSTR, TSDR, TSSSR) or BKP0 <= off <= BKP31):
            self.unmodelled(off, 'W')
            return
        pwr = getattr(self.m, 'pwr', None)
        if pwr is not None and not pwr.dbp:            # RTC registers are write protected while DBP = 0 (5.1.3, 20.3.5)
            self._log_once(('dbp', off), f"write to offset 0x{off:02X} ignored: PWR_CR.DBP = 0")
            return
        n = self._sync()
        if off == WPR:
            self._w_wpr(value & 0xFF)                  # 20.6.10, KEY = bits 7:0
            return
        if off == ISR:
            self._w_isr(n, value)
        elif off == TAFCR:
            self._w_tafcr(n, value)                    # not key protected (20.3.5)
        elif BKP0 <= off <= BKP31:
            if not self.flags & F_TAMPERS:             # held in reset while a tamper flag is set (20.6.20)
                self.bkp[(off - BKP0) >> 2] = value & 0xFFFFFFFF
        elif off in (SSR, TSTR, TSDR, TSSSR):
            pass                                       # read-only registers (20.6.11, 20.6.13 - 20.6.15)
        elif self.wp != 2:
            self._log_once(('wp', off), f"write to offset 0x{off:02X} ignored: write protection active (WPR key)")
            return
        elif off == TR:
            if self._initf(n):
                self.sh_tr = value & 0x007F7F7F        # 20.6.1: TR is writable in initialization mode only
        elif off == DR:
            if self._initf(n):
                self.sh_dr = value & 0x00FFFF3F        # 20.6.2
        elif off == CR:
            self._w_cr(n, value)
        elif off == PRER:
            if self._initf(n):
                self.prer = value & 0x007F7FFF         # 20.6.5: initialization mode only
        elif off == WUTR:
            if self._wutwf(n):
                self.wutr = value & 0xFFFF             # 20.6.6: only while WUTWF = 1
        elif off == CALIBR:
            if self._initf(n):
                self.calibr = value & 0x9F             # 20.6.7: initialization mode only
                self._check_cal()
        elif off == ALRMAR:
            self.alrmar = value                        # 20.6.8: ALRAWF = 1 or INIT, i.e. always
        elif off == ALRMBR:
            self.alrmbr = value                        # 20.6.9
        elif off == SHIFTR:
            self._w_shift(n, value)
        elif off == CALR:
            self._w_calr(n, value)
        elif off == ALRMASSR:
            if not (self.cr & CR_ALRAE) or self.init:
                self.alrmassr = value & 0x0F007FFF     # 20.6.18: ALRAE clear or initialization mode
        elif off == ALRMBSSR:
            if not (self.cr & CR_ALRBE) or self.init:
                self.alrmbssr = value & 0x0F007FFF     # 20.6.19
        self._arm()

    def _w_wpr(self, key):
        """Key sequence 0xCA, 0x53 unlocks, any wrong key locks again (20.3.5)."""
        if self.wp == 0 and key == 0xCA:
            self.wp = 1
        elif self.wp == 1 and key == 0x53:
            self.wp = 2
        else:
            self.wp = 0

    # ------------------------------------------------------------------ RTC_CR / RTC_ISR / RTC_TAFCR / SHIFTR / CALR
    def _w_cr(self, n, value):
        old = self.cr
        new = value & CR_MASK & ~(CR_ADD1H | CR_SUB1H)
        if not self._initf(n):                         # DCE, FMT, REFCKON: initialization mode only (20.6.3 note)
            new = (new & ~CR_INIT_ONLY) | (old & CR_INIT_ONLY)
        if old & CR_WUTE or not self._wutwf(n):        # WUCKSEL: WUTE = 0 and WUTWF = 1 only (20.6.3 note)
            new = (new & ~CR_WUCKSEL) | (old & CR_WUCKSEL)
        self.cr = new
        for i, bit in enumerate((CR_ALRAE, CR_ALRBE)):
            if new & bit and not old & bit:
                self._alr_eff[i] = n + SYNC_PULSES     # taken into account after 1 to 2 RTCCLK (20.3.5)
                self._alr_last[i] = -1
        if new & CR_WUTE and not old & CR_WUTE:        # timer starts counting down (20.3.4, 20.6.6 note)
            self.wut_start = n + SYNC_PULSES
            self._wut_k = 0
            self._wut_b0 = self._boundaries_upto(self.wut_start)
            self.wutwf_val, self.wutwf_n = False, n + SYNC_PULSES      # WUTWF cleared up to 2 RTCCLK later (20.6.4)
        elif old & CR_WUTE and not new & CR_WUTE:
            self.wut_start = None
            self.wutwf_val, self.wutwf_n = True, n + SYNC_PULSES       # WUTWF set up to 2 RTCCLK later (20.6.4)
        if (new ^ old) & CR_BYPSHAD:
            self._lk_tr = self._lk_dr = None
            self.rsf_p = (n // 2 + 1) * 2              # RSF is cleared in bypass mode, set again at the next copy
        if value & (CR_ADD1H | CR_SUB1H) and self.run and self._pend_hour is None:
            self._hour_change(n, +1 if value & CR_ADD1H else -1)
        if new & (CR_COE | CR_OSEL):
            self.unmodelled(CR, 'W')                   # RTC_CALIB / RTC_ALARM output on RTC_AF1 not modelled
        self._check_cal()
        self._lines()
        self._tamper_recheck(n)

    def _hour_change(self, n, sign):
        """ADD1H / SUB1H take effect at the next second (20.6.3 note); SUB1H does nothing at hour 0 (20.6.3)."""
        secs, _, _ = self._state(n)
        if sign < 0 and secs % 86400 < 3600:
            return
        self._pend_hour = sign
        self._add_pend(self._boundary_pulse(self._boundaries_upto(n) + 1), 'hour', sign)

    def _check_cal(self):
        """Calibration changes the calendar rate; the model does not apply it, so report it."""
        if self.cr & CR_DCE and self.calibr & 0x1F:
            self.unmodelled(CALIBR, 'W')
        if self.calr & 0x81FF:
            self.unmodelled(CALR, 'W')

    def _w_isr(self, n, value):
        """Flags ISR[15:8] are rc_w0; INIT is rw and RSF rc_w0 behind the key (20.6.4)."""
        mask = ISR_UNPROTECTED_FLAGS if self.wp != 2 else 0xFF00
        clr = ~value & mask & self.flags
        if clr:
            self.flags &= ~clr
            if clr & F_TSF:                            # TSTR / TSDR / TSSSR are cleared with TSF (20.6.13 - 20.6.15)
                self.tstr = self.tsdr = self.tsssr = 0
            self._lines()
        init = bool(value & ISR_INIT)
        clear_rsf = not value & ISR_RSF and self._rsf(n)
        if self.wp != 2:
            if init != self.init or clear_rsf:
                self._log_once(('wp', ISR), "write to ISR[7:0] ignored: write protection active (WPR key)")
            return
        if clear_rsf:
            self.rsf_p = (n // 2 + 1) * 2
        if init and not self.init:
            self.init, self.init_n = True, n
        elif self.init and not init:
            self.init = False
            self._exit_init(n)
            self._check_cal()

    def _w_tafcr(self, n, value):
        self.tafcr = value & TAF_MASK                  # 20.6.17
        self._lines()
        self._tamper_recheck(n)

    def _w_shift(self, n, value):
        """SUBFS is added to SS, ADD1S adds a second; ignored while a shift is pending (20.6.12, 20.3.8)."""
        if self._shpf(n):
            return
        if not self.run:
            self.unmodelled(SHIFTR, 'W')               # shift in initialization mode: counters stopped, RM silent
            return
        t = self._tick(n) + 1
        pulse = self.na + t * (self.cha + 1)
        self.shift_p = pulse
        self._add_pend(pulse, 'shift', (value & 0x7FFF, bool(value >> 31 & 1)))
        self.rsf_p = (pulse // 2 + 1) * 2              # writing SUBFS clears RSF (20.6.12 note)

    def _w_calr(self, n, value):
        if self._recalpf(n):                           # RTC_CALR blocked while RECALPF = 1 (20.3.11)
            return
        v = value & 0xE1FF
        if v & 1 << 14:                                # CALW8: CALM[1:0] stuck at 00 (20.6.16)
            v &= ~3
        if v & 1 << 13:                                # CALW16: CALM[0] stuck at 0
            v &= ~1
        self.calr = v
        self.recalpf_n = n + 3 * (self.cha + 1)        # new setting effective within 3 ck_apre cycles (20.3.11)
        self._add_pend(self.recalpf_n, 'recal')
        self._check_cal()

    # ------------------------------------------------------------------ alarms (20.3.3, 20.6.8, 20.6.9, 20.6.18, 20.6.19)
    @staticmethod
    def _first_tod(lo, h, mi, s):
        """Smallest time of day >= lo (seconds) whose hour/minute/second equal the fixed ones (None = any)."""
        for hh in ([h] if h is not None else range(24)):
            if hh * 3600 + 3599 < lo:
                continue
            for mm in ([mi] if mi is not None else range(60)):
                if hh * 3600 + mm * 60 + 59 < lo:
                    continue
                for ss in ([s] if s is not None else range(60)):
                    t = hh * 3600 + mm * 60 + ss
                    if t >= lo:
                        return t
        return None

    def _alarm_next_second(self, reg, c_from):
        """Smallest calendar second number >= c_from (counted from the anchor second) matching the alarm fields."""
        s = None if reg >> 7 & 1 else bcd(reg >> 4 & 7, reg & 15)                 # MSK1
        mi = None if reg >> 15 & 1 else bcd(reg >> 12 & 7, reg >> 8 & 15)         # MSK2
        h = None
        if not reg >> 23 & 1:                                                     # MSK3
            hv = bcd(reg >> 20 & 3, reg >> 16 & 15)
            if self.cr & CR_FMT:
                if not 1 <= hv <= 12:
                    return None
                h = hv % 12 + (12 if reg >> 22 & 1 else 0)
            elif hv > 23:
                return None
            else:
                h = hv
        if s is not None and s > 59 or mi is not None and mi > 59:
            return None
        start = self.ca + c_from
        day0, tod0 = divmod(start, 86400)
        for dd in range(MAX_ALARM_DAYS):
            day = day0 + dd
            if not reg >> 31 & 1:                                                 # MSK4
                if reg >> 30 & 1:                                                 # WDSEL: weekday
                    wd = (self.wda - 1 + day - self.ca // 86400) % 7 + 1
                    if wd != (reg >> 24 & 15):
                        continue
                else:
                    if from_days(day)[2] != bcd(reg >> 28 & 3, reg >> 24 & 15):
                        continue
            t = self._first_tod(tod0 if dd == 0 else 0, h, mi, s)
            if t is not None:
                return day * 86400 + t - self.ca
        return None

    def _alarm_tick(self, c, ssr, lo):
        """First ck_apre tick >= lo inside calendar second c whose SS satisfies the sub-second compare, or None."""
        start = self._ts_start(c)
        ss0 = self.ssa if c == 0 else self.chs
        masks = ssr >> 24 & 15
        if masks == 0:
            # no sub-second compare: the flag is set when the seconds are incremented (20.6.18 MASKSS = 0);
            # the anchor tick of a chain is not an increment, except after an hour change (second boundary)
            return start if (c > 0 or self.anchor_inc) and start >= lo else None
        mask = (1 << masks) - 1
        r = ssr & 0x7FFF & mask
        ss_hi = ss0 - max(lo - start, 0)
        if ss_hi < r:
            return None
        return start + ss0 - (r + ((ss_hi - r) >> masks << masks))

    def _alarm_next(self, i, lower):
        """Pulse of the first alarm match at or after pulse `lower`, or None."""
        if not self.run:
            return None
        reg = self.alrmar if i == 0 else self.alrmbr
        ssr = self.alrmassr if i == 0 else self.alrmbssr
        per = self.cha + 1
        t_low = 0 if lower <= self.na else -((self.na - lower) // per)
        c_from = self._sec_ss(t_low)[0]
        for _ in range(3):
            c = self._alarm_next_second(reg, c_from)
            if c is None:
                return None
            t = self._alarm_tick(c, ssr, t_low)
            if t is not None:
                return self.na + t * per
            if c > 0 and self._ts_start(c) >= t_low:   # a whole second has no matching tick: never matches
                return None
            c_from = c + 1
        return None

    # ------------------------------------------------------------------ wakeup timer (20.3.4, 20.6.6)
    def _wut_restart(self):
        """A new counter anchor restarts a wakeup timer that counts ck_spre (model choice, see module docstring)."""
        if self.wut_start is not None and (self.cr & CR_WUCKSEL) >= 4:
            self.wut_start = max(self._clk.n() if self._clk else 0, self.na)
            self._wut_k = 0
            self._wut_b0 = 0

    def _wut_pulse(self, k):
        sel = self.cr & CR_WUCKSEL
        if sel < 4:                                    # RTCCLK / 16, 8, 4, 2
            return self.wut_start + k * (self.wutr + 1) * (16, 8, 4, 2)[sel]
        if not self.run:
            return None                                # ck_spre stopped in initialization mode
        per = self.wutr + 1 + (0x10000 if sel >= 6 else 0)      # 17-bit counter for WUCKSEL[2:1] = 11
        return self._boundary_pulse(self._wut_b0 + k * per)

    def _wut_done(self, n):
        sel = self.cr & CR_WUCKSEL
        if sel < 4:
            return (n - self.wut_start) // ((self.wutr + 1) * (16, 8, 4, 2)[sel])
        per = self.wutr + 1 + (0x10000 if sel >= 6 else 0)
        return (self._boundaries_upto(n) - self._wut_b0) // per

    # ------------------------------------------------------------------ time stamp and tamper (20.3.12, 20.3.13)
    def af1_input(self, level):
        """Level of RTC_AF1 (PC13): time stamp input and tamper input 1."""
        level = 1 if level else 0
        if level == self._af1:
            return
        self._af1 = level
        self._tin[1] = level
        if not (self.cr & CR_TSE or self.tafcr & 0x2F):     # time stamp and tamper inputs disabled: only the level is kept
            return
        n = self._sync()
        rising = level == 1
        if self.cr & CR_TSE and rising != bool(self.cr & CR_TSEDGE):      # TSEDGE: 0 rising, 1 falling (20.6.3)
            self._ts_event(n, 0)
        self._tamper_recheck(n)
        self._arm()

    def tamper_input(self, num, level):
        """Level of tamper input 2 or 3 (RTC_TAMP2 / RTC_TAMP3)."""
        n = self._sync()
        self._tin[num] = 1 if level else 0
        self._tamper_recheck(n)
        self._arm()

    def _tamper_cfg(self, num):
        """(enabled, trigger bit, filter count) of tamper input num (20.6.17)."""
        t = self.tafcr
        en = bool(t >> (0 if num == 1 else 3 if num == 2 else 5) & 1)
        trg = t >> (1 if num == 1 else 4 if num == 2 else 6) & 1
        flt = (0, 2, 4, 8)[t >> 11 & 3]
        return en, trg, flt

    def _tamper_recheck(self, n):
        """Edge mode: an event on the rising edge of (pin at the active level AND TAMPxE) (20.3.13)."""
        flt_any = False
        for num in (1, 2, 3):
            en, trg, flt = self._tamper_cfg(num)
            if flt:
                flt_any = flt_any or en
                self._tsig[num] = 0
                continue
            sig = int(en and self._tin[num] == 1 - trg)     # TRG = 0: rising edge, 1: falling edge
            if sig and not self._tsig[num]:
                self._tamper_event(n, num)
            self._tsig[num] = sig
        self._tsamp_per = 32768 >> (self.tafcr >> 8 & 7)    # TAMPFREQ: RTCCLK / 32768 .. / 256 (20.6.17)
        if flt_any:
            if self._tsamp is None:
                self._tsamp = (n // self._tsamp_per + 1) * self._tsamp_per
        else:
            self._tsamp = None

    def _tamper_sample(self, n):
        for num in (1, 2, 3):
            en, trg, flt = self._tamper_cfg(num)
            if not (en and flt):
                self._tcnt[num] = 0
                continue
            self._tcnt[num] = self._tcnt[num] + 1 if self._tin[num] == trg else 0
            if self._tcnt[num] >= flt:                      # 2, 4 or 8 consecutive samples at the active level
                self._tcnt[num] = 0
                self._tamper_event(n, num)

    def _tamper_event(self, n, num):
        """A tamper event resets the backup registers (20.3.13); with TAMPTS it also records a time stamp."""
        self.bkp = [0] * 32
        flag = (F_TAMP1F, F_TAMP2F, F_TAMP3F)[num - 1]
        if self.tafcr & TAF_TAMPTS:
            self._ts_event(n, flag)
        else:
            self._set_flag(flag)

    def _ts_event(self, n, tamper_flag):
        """Time stamp event at pulse n: capture the counters, TSF is set 2 ck_apre later, TSOVF at once (20.3.12)."""
        if self.flags & F_TSF or self._ts_pending:
            self.flags |= F_TSOVF
            if tamper_flag:
                self._set_flag(tamper_flag)                 # tamper flag set together with TSOVF (20.3.13)
            self._lines()
            return
        if n >= self.na and self.run:
            tr, dr, ss = self._regs(*self._state(n))
        else:
            tr, dr, ss = self.sh_tr, self.sh_dr, self.sh_ss
        self.tstr, self.tsdr, self.tsssr = tr, dr & 0xFFFF, ss
        self._ts_pending = True
        self._add_pend(n + 2 * (self.cha + 1), 'tsflag', tamper_flag)

    def _ts_flag(self, tamper_flag):
        self._ts_pending = False
        self._set_flag(F_TSF)
        if tamper_flag:
            self._set_flag(tamper_flag)

    # ------------------------------------------------------------------ event scheduling
    def _next_due(self):
        due = []
        for i in (0, 1):
            if self.cr & (CR_ALRAE << i):
                lower = max(self._alr_eff[i], self._alr_last[i] + 1)
                p = self._alarm_next(i, lower)
                if p is not None:
                    due.append(p)
        if self.cr & CR_WUTE and self.wut_start is not None:
            p = self._wut_pulse(self._wut_k + 1)
            if p is not None:
                due.append(p)
        if self._pend:
            due.append(self._pend[0][0])
        if self._tsamp is not None:
            due.append(self._tsamp)
        return min(due) if due else None

    def _arm(self):
        """(Re)schedule the next RTC event on the machine's event queue."""
        self._gen += 1
        gen = self._gen
        self._sync()
        due = self._next_due()
        if due is None or not self._clk.hz:
            return
        delay = math.ceil((self._clk.time_of(due) - self.m.elapsed_s()) * self.m.sysclk_hz)
        self.m.schedule(max(1, delay), lambda: self._fire(gen))

    def _fire(self, gen):
        if gen != self._gen:
            return
        n = self._sync()
        for i in (0, 1):
            if self.cr & (CR_ALRAE << i):
                p = self._alarm_next(i, max(self._alr_eff[i], self._alr_last[i] + 1))
                if p is not None and p <= n:
                    self._alr_last[i] = n
                    self._set_flag(F_ALRAF << i)
        if self.cr & CR_WUTE and self.wut_start is not None:
            p = self._wut_pulse(self._wut_k + 1)
            if p is not None and p <= n:
                self._wut_k = max(self._wut_k + 1, self._wut_done(n))
                self._set_flag(F_WUTF)
        while self._tsamp is not None and self._tsamp <= n:
            self._tsamp += self._tsamp_per
            self._tamper_sample(n)
        self._arm()
