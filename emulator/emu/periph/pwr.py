"""PWR (power control) model for the STM32L152ZD, base 0x40007000.

Follows RM0038 chapter 5 (power control).  References use the section number and, in brackets,
the line of the RM0038 text conversion (rm0038.txt).

Both registers must be accessed as half-words or words (RM0038 5.4, rm0038.txt:6212); byte accesses
are reported through unmodelled() and have no effect.

Services offered to other models and to the machine core:
    dbp, vos                  PWR_CR.DBP (backup domain write enable, used by RCC_CSR) and the
                              voltage range 1..3 (VOS = 01, 10, 11)
    request_deepsleep()       the CPU executed WFI/WFE with SLEEPDEEP set: returns the requested
                              low-power mode (STOP or STANDBY) and records it in lowpower_requests
    enter_standby()           sets SBF; the core then resets the device with reset('standby')
    wakeup_event(source)      WKUP pin / RTC wakeup event: sets WUF
    wkup_pin(n, level)        drive the level of WKUP pin n (1..3)
    set_vdd(volts)            supply level seen by the PVD
    rcc_reset_asserted()      RCC_APB1RSTR.PWRRST was set (PWR_CR reset, RM0038 5.4.1 rm0038.txt:6241)
    reset(kind)               'por', 'system' or 'standby'
"""
from .base import Periph

# PWR_CR bit positions (5.4.1, rm0038.txt:6214)
CR_LPSDSR = 1 << 0
CR_PDDS = 1 << 1
CR_CWUF = 1 << 2
CR_CSBF = 1 << 3
CR_PVDE = 1 << 4
CR_DBP = 1 << 8
CR_ULP = 1 << 9
CR_FWU = 1 << 10
CR_LPRUN = 1 << 14
CR_RESET = 0x00001000                      # 5.4.1 reset value (VOS = 10, range 2), rm0038.txt:6216

# PWR_CSR bit positions (5.4.2, rm0038.txt:6337)
CSR_WUF = 1 << 0
CSR_SBF = 1 << 1
CSR_PVDO = 1 << 2
CSR_VREFINTRDYF = 1 << 3
CSR_VOSF = 1 << 4
CSR_REGLPF = 1 << 5
CSR_EWUP_SHIFT = 8
CSR_RESET = 0x00000008                     # 5.4.2 reset value, rm0038.txt:6339

# PVD thresholds for PLS[2:0] = 000..110 (5.4.1 PLS, rm0038.txt:6283); 111 is the external input
PVD_THRESHOLD_V = [1.9, 2.1, 2.3, 2.5, 2.7, 2.9, 3.1]

# Modelling parameters that RM0038 does not quantify ("a delay is required", 5.4.2 rm0038.txt:6391)
VOS_SETTLE_US_DEFAULT = 20
REGULATOR_SETTLE_US_DEFAULT = 20
VREFINT_STARTUP_US_DEFAULT = 2000          # datasheet TVREFINT typical 2 ms (max 3 ms)


class PWR(Periph):
    name = "PWR"
    base = 0x40007000

    def __init__(self, vdd_volts=3.3, vos_settle_us=VOS_SETTLE_US_DEFAULT,
                 regulator_settle_us=REGULATOR_SETTLE_US_DEFAULT,
                 vrefint_startup_us=VREFINT_STARTUP_US_DEFAULT):
        self._m = None
        super().__init__()
        self.vdd_volts = vdd_volts
        self.pvd_in_below = False              # PLS = 111: PVD_IN input below VREFINT
        self.vos_settle_us = vos_settle_us
        self.regulator_settle_us = regulator_settle_us
        self.vrefint_startup_us = vrefint_startup_us
        self.pvd_callback = None               # called with the new PVDO value on every change
        self.lowpower_requests = []            # (cycles, mode, regulator_lp, ulp, fwu)
        self._wkup_level = {1: 0, 2: 0, 3: 0}
        self._vos_gen = 0
        self._reg_gen = 0
        self._vref_gen = 0
        self._logged = set()
        self.cr = CR_RESET
        self.csr = CSR_RESET

    # ------------------------------------------------------------------ attach to the machine
    @property
    def m(self):
        return self._m

    @m.setter
    def m(self, machine):
        self._m = machine
        if machine is not None:
            machine.pwr = self

    # ------------------------------------------------------------------ derived state
    @property
    def vos(self):
        return self.cr >> 11 & 3

    @property
    def dbp(self):
        return bool(self.cr & CR_DBP)

    @property
    def regulator_low_power(self):
        """Regulator in low-power mode while running: LPRUN together with LPSDSR (5.4.1 rm0038.txt:6229)."""
        return bool(self.cr & CR_LPRUN and self.cr & CR_LPSDSR)

    def _log(self, text):
        self.m.log.append((self.m.cycles, "PWR: " + text))

    def _cyc(self, us):
        return max(1, int(us * self.m.sysclk_hz / 1_000_000))

    # ------------------------------------------------------------------ reset
    def reset(self, kind='system'):
        """kind 'por': everything; 'system': PWR_CR and the system-reset part of PWR_CSR;
        'standby': wakeup from Standby, PWR_CR reset and PWR_CSR kept (5.4.1 rm0038.txt:6216,
        5.4.2 rm0038.txt:6339, 5.3.8 rm0038.txt:6112)."""
        self._vos_gen += 1
        self._reg_gen += 1
        self._vref_gen += 1
        self.cr = CR_RESET
        if kind == 'por':
            self.csr = CSR_RESET
        elif kind == 'system':
            # EWUPx and WUF are cleared by a system reset (rm0038.txt:6359, 6414); SBF is kept
            # (cleared only by POR or CSBF, rm0038.txt:6409); the regulator flags return to idle
            self.csr = (self.csr & CSR_SBF) | CSR_VREFINTRDYF
        # PVDO is 0 after Standby or reset until PVDE is set (rm0038.txt:6406)
        self.csr &= ~(CSR_PVDO | CSR_VOSF | CSR_REGLPF) if kind != 'standby' else ~CSR_PVDO
        self._update_pvd()

    def rcc_reset_asserted(self):
        """PWRRST: PWR_CR is reset except FWU and ULP (5.4.1 rm0038.txt:6256, 6270)."""
        keep = self.cr & (CR_FWU | CR_ULP)
        self._vos_gen += 1
        self._reg_gen += 1
        self.cr = CR_RESET | keep
        self.csr &= ~(CSR_VOSF | CSR_REGLPF)
        self._update_pvd()

    # ------------------------------------------------------------------ PVD
    def set_vdd(self, volts):
        self.vdd_volts = volts
        self._update_pvd()

    def _update_pvd(self):
        pls = self.cr >> 5 & 7
        if not (self.cr & CR_PVDE):
            below = False                        # PVDO is valid only when PVDE = 1
        elif pls == 7:
            below = self.pvd_in_below
        else:
            below = self.vdd_volts < PVD_THRESHOLD_V[pls]
        old = bool(self.csr & CSR_PVDO)
        self.csr = (self.csr & ~CSR_PVDO) | (CSR_PVDO if below else 0)
        if below != old and self.pvd_callback is not None:
            self.pvd_callback(below)

    # ------------------------------------------------------------------ wakeup flags
    def wakeup_event(self, source='RTC'):
        """Wakeup event: RTC alarm / wakeup / tamper / time-stamp ('RTC') or a rising edge on
        'WKUP1'..'WKUP3' (only counts when EWUPx is set).  Sets WUF (5.4.2 rm0038.txt:6413)."""
        if source.startswith('WKUP'):
            n = int(source[4:])
            if not (self.csr >> (CSR_EWUP_SHIFT + n - 1) & 1):
                return
        self.csr |= CSR_WUF

    def wkup_pin(self, n, level):
        old = self._wkup_level[n]
        self._wkup_level[n] = 1 if level else 0
        if level and not old:
            self.wakeup_event('WKUP%d' % n)

    def request_deepsleep(self):
        """WFI/WFE with SLEEPDEEP set (5.3.7 rm0038.txt:6003, 5.3.8 rm0038.txt:6086).  PDDS selects Standby
        (1) or Stop (0); LPSDSR puts the regulator in low-power mode.  Entry requires WUF clear
        (Tables 32 and 33): when WUF is set the entry procedure is ignored and `entered` is False."""
        mode = 'STANDBY' if self.cr & CR_PDDS else 'STOP'
        req = {'mode': mode, 'regulator_lp': bool(self.cr & CR_LPSDSR), 'ulp': bool(self.cr & CR_ULP),
               'fwu': bool(self.cr & CR_FWU), 'entered': not (self.csr & CSR_WUF)}
        if req['entered']:
            self.lowpower_requests.append((self.m.cycles, mode, req['regulator_lp'], req['ulp'], req['fwu']))
            self._log(f"deepsleep request: {mode}, regulator {'low-power' if req['regulator_lp'] else 'on'}")
        return req

    def enter_standby(self):
        """The device entered Standby: SBF is set by hardware (5.4.2 rm0038.txt:6409)."""
        self.csr |= CSR_SBF

    def exit_lowpower(self):
        """Wakeup from Stop (5.3.7 rm0038.txt:6040): with ULP = 1 VREFINT was off in low-power mode;
        VREFINTRDYF rises again after its start-up time, which is skipped by the wakeup when FWU = 1
        (5.4.1 rm0038.txt:6250)."""
        if not (self.cr & CR_ULP):
            return
        self.csr &= ~CSR_VREFINTRDYF
        self._vref_gen += 1
        g = self._vref_gen

        def ready():
            if g == self._vref_gen:
                self.csr |= CSR_VREFINTRDYF
        self.m.schedule(self._cyc(self.vrefint_startup_us), ready)

    # ------------------------------------------------------------------ register access
    def read(self, off, size):
        if size == 1:
            self.unmodelled(off, 'R')           # registers are half-word / word accessible only
            return 0
        reg = off & ~3
        if reg == 0x00:
            val = self.cr & ~(CR_CWUF | CR_CSBF)         # PWR_CR 5.4.1; CSBF/CWUF always read 0
        elif reg == 0x04:
            val = self.csr                               # PWR_CSR 5.4.2
        else:
            self.unmodelled(off, 'R')
            return 0
        return self.extract(val, off, size)

    def write(self, off, value, size):
        if size == 1:
            self.unmodelled(off, 'W')
            return
        reg = off & ~3
        if reg == 0x00:
            self._w_cr(self.merge(self.cr & ~(CR_CWUF | CR_CSBF), off, value, size))
        elif reg == 0x04:
            self._w_csr(self.merge(self.csr, off, value, size))
        else:
            self.unmodelled(off, 'W')

    # PWR_CR (5.4.1, rm0038.txt:6214) --------------------------------------
    def _w_cr(self, new):
        old = self.cr
        # CSBF: clears SBF; CWUF: clears WUF after 2 system clock cycles
        if new & CR_CSBF:
            self.csr &= ~CSR_SBF
        if new & CR_CWUF:
            self.m.schedule(2, lambda: setattr(self, 'csr', self.csr & ~CSR_WUF))
        # LPSDSR cannot be reset while in low-power run mode (rm0038.txt:6232)
        if not (new & CR_LPSDSR) and (old & CR_LPRUN) and (old & CR_LPSDSR):
            new |= CR_LPSDSR
        # VOS = 00 is forbidden: the bits keep their previous value (rm0038.txt:6244)
        vos = new >> 11 & 3
        if vos == 0:
            vos = old >> 11 & 3
        new = (new & ~(3 << 11)) | (vos << 11)
        keep = (CR_LPSDSR | CR_PDDS | CR_PVDE | CR_DBP | CR_ULP | CR_FWU | CR_LPRUN | (3 << 11) | (7 << 5))
        self.cr = new & keep
        if vos != (old >> 11 & 3):
            self._vos_change()
        was_lp = bool(old & CR_LPRUN and old & CR_LPSDSR)
        now_lp = self.regulator_low_power
        if now_lp and not was_lp:
            self._reg_gen += 1
            self.csr |= CSR_REGLPF                     # set while in low-power run (rm0038.txt:6376)
        elif was_lp and not now_lp:
            self._regulator_to_main()
        self._update_pvd()

    def _vos_change(self):
        """VOSF is set when VOS changes and reset once the regulator is ready (rm0038.txt:6394)."""
        self.csr |= CSR_VOSF
        self._vos_gen += 1
        g = self._vos_gen

        def settled():
            if g == self._vos_gen:
                self.csr &= ~CSR_VOSF
        self.m.schedule(self._cyc(self.vos_settle_us), settled)

    def _regulator_to_main(self):
        """After leaving low-power run REGLPF stays 1 until the regulator is ready in main mode
        (rm0038.txt:6377)."""
        self._reg_gen += 1
        g = self._reg_gen

        def ready():
            if g == self._reg_gen:
                self.csr &= ~CSR_REGLPF
        self.m.schedule(self._cyc(self.regulator_settle_us), ready)

    # PWR_CSR (5.4.2, rm0038.txt:6337) -------------------------------------
    def _w_csr(self, new):
        old_ewup = self.csr >> CSR_EWUP_SHIFT & 7
        ewup = new >> CSR_EWUP_SHIFT & 7
        self.csr = (self.csr & ~(7 << CSR_EWUP_SHIFT)) | (ewup << CSR_EWUP_SHIFT)
        # a WKUP pin that is already high when it is enabled gives an additional wakeup event
        # (rm0038.txt:6419)
        for n in (1, 2, 3):
            if (ewup & ~old_ewup) >> (n - 1) & 1 and self._wkup_level[n]:
                self.csr |= CSR_WUF
