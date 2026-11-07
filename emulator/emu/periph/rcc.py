"""RCC (reset and clock control) model for the STM32L152ZD (category 4 device), base 0x40023800.

Everything here follows RM0038 chapter 6.  References use the section number and, in
brackets, the line of the RM0038 text conversion (rm0038.txt) where the register is described.

Device variant: STM32L152xD is a category 4 device (RM0038 Table 3, rm0038.txt:1872), so the
category-4 register bits exist (FSMC, SDIO, DMA2, GPIOF/G, SPI3, TIM5, UART4/5, LSE CSS) and
the AES bits (L16x only) do not.

Timing parameters that RM0038 does not give (oscillator start-up times) come from the
STM32L151xD/L152xD datasheet electrical characteristics and are constructor arguments.

Services offered to other models and to the machine core:
    clock_enabled(name)      peripheral clock enable bit by name (e.g. 'USART2')
    reset(kind)              apply a reset of the given kind (see RESET_FLAGS)
    reset_for_request(why)   same, keyed by the text given to Machine.request_reset
    fail_hse() / fail_lse()  clock security system events (RM0038 6.2.9 / 6.2.10)
    force_lsi()              the independent watchdog forces the LSI on (RM0038 6.2.12)
    rtc_reset_hooks          callables run when the RTC domain is reset (RM0038 6.1.3)
    reset_hooks              {name: [callables]} run when the peripheral reset bit RCC_xxxRSTR of that name (as in
                             clock_enabled, e.g. 'SDIO', 'DMA2') goes from 0 to 1
    sdioclk_hz               SDIOCLK = PLL VCO / 2 while the PLL is locked, else 0 (RM0038 6.2.4)
    rtc_clock_hz()           RTCCLK frequency reaching the RTC (0 = no clock, RM0038 6.3.14)
    rtc_clock_hooks          callables run whenever rtc_clock_hz() may have changed
"""
from .base import Periph

# ------------------------------------------------------------------ constants from RM0038
HSI_HZ = 16_000_000                       # 6.2.2, rm0038.txt:6852 (internal 16 MHz RC)
LSI_HZ = 37_000                           # 6.2.6, rm0038.txt:6975 (around 37 kHz)
LSE_HZ = 32_768                           # 6.2.5, rm0038.txt:6957
MSI_BASE_HZ = 65_536                      # 6.2.3 / 6.3.2: range n = 65.536 kHz * 2^n, n = 0..6
MSI_RANGE_DEFAULT = 5                     # 6.3.2, rm0038.txt:7384 (2.097 MHz after reset)
PLL_MUL = {0: 3, 1: 4, 2: 6, 3: 8, 4: 12, 5: 16, 6: 24, 7: 32, 8: 48}    # 6.3.3 PLLMUL, rm0038.txt:7459
PLL_DIV = {1: 2, 2: 3, 3: 4}                                              # 6.3.3 PLLDIV, rm0038.txt:7443
HPRE_DIV = [1, 1, 1, 1, 1, 1, 1, 1, 2, 4, 8, 16, 64, 128, 256, 512]       # 6.3.3 HPRE, rm0038.txt:7507
PPRE_DIV = [1, 1, 1, 1, 2, 4, 8, 16]                                      # 6.3.3 PPRE1/2, rm0038.txt:7483

# MSI start-up time in microseconds per range (datasheet table "MSI oscillator characteristics",
# tSU(MSI) typical column); range 6 differs for voltage range 3.
MSI_STARTUP_US = {0: 30, 1: 20, 2: 15, 3: 10, 4: 6, 5: 5, 6: 3.5}
MSI_STARTUP_US_R6_VRANGE3 = 5
HSI_STARTUP_US = 3.7                      # datasheet tSU(HSI) typical
LSI_STARTUP_US = 200                      # datasheet tsu(LSI) maximum (no typical value is given)
PLL_LOCK_US = 115                         # datasheet tLOCK typical (PLL input 16 MHz, VCO 96 MHz)
HSE_STARTUP_US_DEFAULT = 1000             # datasheet tSU(HSE) typical
LSE_STARTUP_US_DEFAULT = 1_000_000        # datasheet tSU(LSE) typical
PLL_UNLOCK_US = 1                         # model parameter: RM0038 gives no PLLRDY fall time (6.2.4)

# RCC_CSR reset-flag bits (6.3.14, rm0038.txt:8640)
RESET_FLAGS = {
    'lpwr': 1 << 31,    # LPWRRSTF
    'wwdg': 1 << 30,    # WWDGRSTF
    'iwdg': 1 << 29,    # IWDGRSTF
    'sft': 1 << 28,     # SFTRSTF
    'por': 1 << 27,     # PORRSTF
    'pin': 1 << 26,     # PINRSTF
    'obl': 1 << 25,     # OBLRSTF
}
CSR_FLAG_MASK = 0xFE000000
# Machine.request_reset() reason -> RESET_FLAGS key.  6.1.1 (Software reset): SYSRESETREQ in SCB_AIRCR forces the software
# reset, flag SFTRSTF; 6.1.1 (Option byte loader reset): OBL_LAUNCH in FLASH_PECR, flag OBLRSTF.  The watchdog and the
# low-power management resets have no model that could request them.
REQUEST_KIND = {'AIRCR.SYSRESETREQ': 'sft', 'OBL_LAUNCH': 'obl'}
CSR_POR_VALUE = 0x0C000000                # 6.3.14 "Power-on reset value", rm0038.txt:8612

# RCC_CIR bits (6.3.4, rm0038.txt:7542): flags 7:0, enables 14:8, clear bits 23:16
CIR_FLAG = {'LSI': 1 << 0, 'LSE': 1 << 1, 'HSI': 1 << 2, 'HSE': 1 << 3, 'PLL': 1 << 4,
            'MSI': 1 << 5, 'LSECSS': 1 << 6, 'CSS': 1 << 7}
CIR_IE_MASK = 0x00007F00                  # LSECSSIE .. LSIRDYIE (bit 15 reserved)

# ------------------------------------------------------------------ peripheral bit maps (category 4)
# (bit, name) lists for the reset / enable / low-power-enable registers.
AHB_BITS = [(0, 'GPIOA'), (1, 'GPIOB'), (2, 'GPIOC'), (3, 'GPIOD'), (4, 'GPIOE'), (5, 'GPIOH'),
            (6, 'GPIOF'), (7, 'GPIOG'), (12, 'CRC'), (15, 'FLITF'), (24, 'DMA1'), (25, 'DMA2'),
            (30, 'FSMC')]                                               # 6.3.5 / 6.3.8
APB2_BITS = [(0, 'SYSCFG'), (2, 'TIM9'), (3, 'TIM10'), (4, 'TIM11'), (9, 'ADC1'), (11, 'SDIO'),
             (12, 'SPI1'), (14, 'USART1')]                              # 6.3.6 / 6.3.9
APB1_BITS = [(0, 'TIM2'), (1, 'TIM3'), (2, 'TIM4'), (3, 'TIM5'), (4, 'TIM6'), (5, 'TIM7'),
             (9, 'LCD'), (11, 'WWDG'), (14, 'SPI2'), (15, 'SPI3'), (17, 'USART2'), (18, 'USART3'),
             (19, 'UART4'), (20, 'UART5'), (21, 'I2C1'), (22, 'I2C2'), (23, 'USB'), (28, 'PWR'),
             (29, 'DAC'), (31, 'COMP')]                                 # 6.3.7 / 6.3.10


def _mask(bits, extra=()):
    m = 0
    for b, _ in list(bits) + list(extra):
        m |= 1 << b
    return m


AHB_MASK = _mask(AHB_BITS)
AHBLP_MASK = _mask(AHB_BITS, [(16, 'SRAM')])      # SRAMLPEN, 6.3.11 bit 16 (rm0038.txt:8348)
APB2_MASK = _mask(APB2_BITS)
APB1_MASK = _mask(APB1_BITS)

# Reset values.  RCC_AHBENR / APB2ENR / APB1ENR / the three reset registers: text of 6.3.5-6.3.10.
# The low-power enable registers: the register-map table (Table 36, rm0038.txt:8863-8960) lists 1 for
# every low-power-enable bit that exists in category 4; the reset values quoted in the text of
# 6.3.11-6.3.13 (0x0101903F, 0x0000521D, 0xB0E64A37) are the subset present on the smaller categories.
AHBENR_RESET = 0x00008000                 # 6.3.8, rm0038.txt:7994
AHBLPENR_RESET = AHBLP_MASK               # Table 36, all implemented bits set
APB2LPENR_RESET = APB2_MASK
APB1LPENR_RESET = APB1_MASK


class RCC(Periph):
    name = "RCC"
    base = 0x40023800

    def __init__(self, hse_hz=4_000_000, hse_startup_us=HSE_STARTUP_US_DEFAULT,
                 lse_startup_us=LSE_STARTUP_US_DEFAULT, hsical=0, msical=0, msi_error_ppm=0, msi_trim_ppm=0):
        """hse_hz: crystal/clock fitted on the board.  hsical / msical: factory calibration values
        loaded into RCC_ICSCR at reset (6.2.2 / 6.2.3); their factory value is not in RM0038.
        msi_error_ppm / msi_trim_ppm: MODEL SETTINGS, not data sheet values.  msi_error_ppm is the deviation of this
        part's MSI from its nominal frequency after factory calibration (DS Table 32: ACCMSI +-0.5 %, drift +-3 % over
        temperature, 2.5 %/V); msi_trim_ppm is the change of the MSI frequency per MSITRIM code (two's complement view of
        the 8-bit field).  Neither RM0038 nor the data sheet gives the MSI trim step or its sign, so tests choose it
        (negative = a higher code lowers the frequency); 0 = MSITRIM has no effect on the frequency."""
        self._m = None
        super().__init__()
        self.hse_freq = hse_hz
        self.msi_error_ppm = msi_error_ppm
        self.msi_trim_ppm = msi_trim_ppm
        self.hse_startup_us = hse_startup_us
        self.lse_startup_us = lse_startup_us
        self.factory_hsical = hsical & 0xFF
        self.factory_msical = msical & 0xFF
        self.rtc_reset_hooks = []
        self.reset_hooks = {}
        self.rtc_clock_hooks = []
        self.lsi_forced = False
        self._logged = set()
        self._osc = {n: {'on': False, 'rdy': False, 'gen': 0, 'pending': False}
                     for n in ('MSI', 'HSI', 'HSE', 'PLL', 'LSI', 'LSE')}
        # registers that survive a system reset (power reset only)
        self.rtcpre = 0
        self.hsebyp = 0
        self.csr_flags = 0
        self.lseon_reg = 0
        self.lsebyp = 0
        self.lsecsson = 0
        self.lsecssd = 0
        self.rtcsel = 0
        self.rtcen = 0
        self.rtcrst = 0

    # ------------------------------------------------------------------ attach to the machine
    @property
    def m(self):
        return self._m

    @m.setter
    def m(self, machine):
        self._m = machine
        if machine is not None:
            machine.rcc = self
            self.reset('por')

    # ------------------------------------------------------------------ helpers
    def _log(self, text):
        self.m.log.append((self.m.cycles, "RCC: " + text))

    def _log_once(self, key, text):
        if key not in self._logged:
            self._logged.add(key)
            self._log(text)

    def _cyc(self, us):
        return max(1, int(us * self.m.sysclk_hz / 1_000_000))

    def _pwr(self):
        return getattr(self.m, 'pwr', None)

    def _flash_power_down(self):
        f = getattr(self.m, 'flash_ctl', None)
        return bool(f is not None and f.run_pd)

    # ------------------------------------------------------------------ reset
    def reset_for_request(self, why):
        """Map the reason given to Machine.request_reset to a reset kind (REQUEST_KIND) and apply it.  A reason that is
        not in the table is a programming error: raising keeps a wrong flag from being set silently."""
        if why not in REQUEST_KIND:
            raise ValueError(f'RCC: no reset flag defined for the reset request {why!r}')
        self.reset(REQUEST_KIND[why])

    def reset(self, kind='por'):
        """System reset (kind in RESET_FLAGS other than 'por') or power-on reset ('por').
        6.1.1 / 6.1.2 (rm0038.txt:6552, 6596): a system reset sets all registers to their reset
        values unless specified otherwise; RTCPRE/HSEBYP (6.3.1) and the RTC domain bits and reset
        flags of RCC_CSR (6.3.14) are kept."""
        por = (kind == 'por')
        for n, o in self._osc.items():
            if n == 'LSE' and not por:
                continue                                 # RTC domain: LSE start-up is not affected
            o['gen'] += 1
            o['pending'] = False
        if por:
            self.rtcpre = 0
            self.hsebyp = 0
            self._rtc_domain_reset()
            self.csr_flags = CSR_POR_VALUE & CSR_FLAG_MASK
        else:
            self.csr_flags |= RESET_FLAGS.get(kind, 0)
        self.rmvf = 0
        # RCC_CR 0x00000300 reset: MSION and MSIRDY set, everything else clear (6.3.1)
        for n in ('HSI', 'HSE', 'PLL'):
            self._osc[n].update(on=False, rdy=False)
        self._osc['MSI'].update(on=True, rdy=True)
        self.csson = 0
        # RCC_ICSCR (6.3.2): MSITRIM 0, MSIRANGE 5, HSITRIM 0x10, CAL = factory value
        self.msitrim = 0
        self.msirange = MSI_RANGE_DEFAULT
        self.hsitrim = 0x10
        self.msical = self.factory_msical
        self.hsical = self.factory_hsical
        # RCC_CFGR 0 (6.3.3)
        self.sw = 0
        self.sws = 0
        self.hpre = 0
        self.ppre1 = 0
        self.ppre2 = 0
        self.pllsrc = 0
        self.pllmul = 0
        self.plldiv = 0
        self.mcosel = 0
        self.mcopre = 0
        # RCC_CIR 0 (6.3.4)
        self.cir_ie = 0
        self.cir_flags = 0
        # peripheral reset / enable registers
        self.ahbrstr = 0
        self.apb2rstr = 0
        self.apb1rstr = 0
        self.ahbenr = AHBENR_RESET
        self.apb2enr = 0
        self.apb1enr = 0
        self.ahblpenr = AHBLPENR_RESET
        self.apb2lpenr = APB2LPENR_RESET
        self.apb1lpenr = APB1LPENR_RESET
        # RCC_CSR system-reset values: LSION / LSIRDY are reset by system reset (6.3.14)
        self._osc['LSI'].update(on=self.lsi_forced, rdy=self.lsi_forced, pending=False)
        self._recalc_clock()
        self._rtc_clock_changed()

    def _rtc_domain_reset(self):
        """RTC domain reset: power-on reset or RTCRST (6.1.3, 6.3.14 bits 8-11, 16-17, 22)."""
        self.rtcsel = 0
        self.rtcen = 0
        self.lsebyp = 0
        self.lsecsson = 0
        self.lsecssd = 0
        lse = self._osc['LSE']
        lse['gen'] += 1
        lse['pending'] = False
        lse['on'] = False
        lse['rdy'] = False
        for hook in self.rtc_reset_hooks:
            hook()
        self._rtc_clock_changed()

    # ------------------------------------------------------------------ clock computation
    @property
    def msi_hz(self):
        """MSI frequency: the nominal range value (6.2.3) with this part's error and the MSITRIM effect (model settings,
        see __init__)."""
        nominal = MSI_BASE_HZ << self.msirange
        if not self.msi_error_ppm and not self.msi_trim_ppm:
            return nominal
        trim = self.msitrim - 256 if self.msitrim & 0x80 else self.msitrim
        return nominal * (1_000_000 + self.msi_error_ppm) * (1_000_000 + self.msi_trim_ppm * trim) // 10 ** 12

    @property
    def hse_rtc_hz(self):
        """HSE_RTC: HSE divided by RTCPRE (6.3.1: /2, /4, /8, /16), 0 while HSE is not ready.  Besides the RTC / LCD
        clock mux it goes to TIM11 channel 1 when TIM11_OR TI1_RMP = 10 (6.2.14, 18.5.13)."""
        if not self._osc['HSE']['rdy']:
            return 0
        return self.hse_freq // (2 << self.rtcpre)

    def _pll_params_valid(self):
        return self.pllmul in PLL_MUL and self.plldiv in PLL_DIV

    @property
    def pll_hz(self):
        if not self._pll_params_valid():
            return 0
        src = self.hse_freq if self.pllsrc else HSI_HZ
        return src * PLL_MUL[self.pllmul] // PLL_DIV[self.plldiv]

    @property
    def sdioclk_hz(self):
        """48 MHz SDIO clock: "SDIOCLK or USBCLK = PLLVCO/2", derived from the PLL VCO before the output divider
        (6.2.4, rm0038.txt:6926).  It exists only while the PLL is running and locked (PLLRDY)."""
        if not self._osc['PLL']['rdy'] or not self._pll_params_valid():
            return 0
        src = self.hse_freq if self.pllsrc else HSI_HZ
        return src * PLL_MUL[self.pllmul] // 2

    def _source_hz(self, sel):
        return (self.msi_hz, HSI_HZ, self.hse_freq, self.pll_hz)[sel]

    @property
    def hclk_hz(self):
        return self._source_hz(self.sws) // HPRE_DIV[self.hpre]

    # Method aliases for other peripheral models (the properties below are the implementation).
    def timclk1_hz(self):
        return self.tim_clk1_hz

    def timclk2_hz(self):
        return self.tim_clk2_hz

    @property
    def sysclk_src_hz(self):
        return self._source_hz(self.sws)

    @property
    def pclk1_hz(self):
        return self.hclk_hz // PPRE_DIV[self.ppre1]

    @property
    def pclk2_hz(self):
        return self.hclk_hz // PPRE_DIV[self.ppre2]

    @property
    def tim_clk1_hz(self):
        """Timer clock on APB1: x2 when the APB1 prescaler is not 1 (6.2, rm0038.txt:6775)."""
        return self.pclk1_hz * (1 if PPRE_DIV[self.ppre1] == 1 else 2)

    @property
    def tim_clk2_hz(self):
        return self.pclk2_hz * (1 if PPRE_DIV[self.ppre2] == 1 else 2)

    def rtc_clock_hz(self):
        """RTCCLK frequency that reaches the RTC: 0 unless RTCEN = 1 and the selected oscillator is
        ready (RTCSEL 01 LSE, 10 LSI, 11 HSE, 6.3.14)."""
        src = {1: 'LSE', 2: 'LSI', 3: 'HSE'}.get(self.rtcsel)
        if not self.rtcen or src is None or not self._osc[src]['rdy']:
            return 0
        return self.rtcclk_hz

    def _rtc_clock_changed(self):
        for hook in list(self.rtc_clock_hooks):
            hook()

    @property
    def rtcclk_hz(self):
        """RTC / LCD clock selected by RTCSEL (6.3.14, rm0038.txt:8700; HSE divider from 6.3.1)."""
        if self.rtcsel == 1:
            return LSE_HZ
        if self.rtcsel == 2:
            return LSI_HZ
        if self.rtcsel == 3:
            return self.hse_freq // (2 << self.rtcpre)
        return 0

    def _recalc_clock(self):
        hclk = self.hclk_hz
        if hclk and hclk != self.m.sysclk_hz:
            self._log(f"core clock {self.m.sysclk_hz} -> {hclk} Hz "
                      f"(SWS={self.sws}, HPRE={self.hpre})")
        if hclk:
            self.m.sysclk_hz = hclk

    def clock_enabled(self, name):
        """Peripheral clock enable bit (RCC_AHBENR / APB2ENR / APB1ENR) by peripheral name."""
        for bits, reg in ((AHB_BITS, self.ahbenr), (APB2_BITS, self.apb2enr), (APB1_BITS, self.apb1enr)):
            for b, n in bits:
                if n == name:
                    return bool(reg >> b & 1)
        raise KeyError(name)

    # ------------------------------------------------------------------ oscillators
    def _is_ready(self, name):
        return self._osc[name]['rdy']

    def _startup_us(self, name):
        if name == 'HSI':
            return HSI_STARTUP_US
        if name == 'MSI':
            if self.msirange == 6:
                pwr = self._pwr()
                if pwr is not None and pwr.vos == 3:
                    return MSI_STARTUP_US_R6_VRANGE3
            return MSI_STARTUP_US[min(self.msirange, 6)]
        if name == 'HSE':
            return self.hse_startup_us
        if name == 'LSI':
            return LSI_STARTUP_US
        if name == 'LSE':
            return self.lse_startup_us
        return PLL_LOCK_US

    def _stop_cycles(self, name):
        """Delay until RDY falls after the enable bit is cleared: 6 oscillator cycles for HSI, HSE,
        MSI and LSE, 3 for LSI (6.3.1 rm0038.txt:7310,7325,7336; 6.3.14 rm0038.txt:8751,8762)."""
        if name == 'PLL':
            return self._cyc(PLL_UNLOCK_US)
        freq, n = {'HSI': (HSI_HZ, 6), 'MSI': (self.msi_hz, 6), 'HSE': (self.hse_freq, 6),
                   'LSE': (LSE_HZ, 6), 'LSI': (LSI_HZ, 3)}[name]
        return max(1, int(n * self.m.sysclk_hz / freq))

    def _set_flag(self, name):
        """Ready interrupt flag: set when the oscillator becomes stable and its enable bit is set."""
        bit = CIR_FLAG[name]
        if self.cir_ie & (bit << 8):
            self.cir_flags |= bit
            if self.m.nvic is not None:
                self.m.nvic.irq(5)                       # RCC global interrupt, Table 51 (rm0038.txt:12999)

    def _osc_set(self, name, want):
        o = self._osc[name]
        if want == o['on']:
            return
        o['on'] = want
        o['gen'] += 1
        g = o['gen']
        if want:
            if o['rdy']:
                return                                   # still ready: the pending fall is cancelled
            if name == 'PLL':
                self._pll_try_lock()
            else:
                self.m.schedule(self._cyc(self._startup_us(name)), lambda: self._osc_ready(name, g))
        else:
            o['pending'] = False
            if o['rdy']:
                self.m.schedule(self._stop_cycles(name), lambda: self._osc_unready(name, g))

    def _osc_ready(self, name, gen):
        o = self._osc[name]
        if o['gen'] != gen or not o['on']:
            return
        o['rdy'] = True
        self._set_flag(name)
        if name in ('HSI', 'HSE'):
            self._pll_try_lock()
        self._try_switch()
        self._rtc_clock_changed()

    def _osc_unready(self, name, gen):
        o = self._osc[name]
        if o['gen'] != gen or o['on']:
            return
        o['rdy'] = False
        if name in ('HSI', 'HSE') and ((name == 'HSE') == bool(self.pllsrc)):
            pll = self._osc['PLL']
            if pll['rdy']:                               # PLL loses its input
                pll['rdy'] = False
            pll['pending'] = False
            pll['gen'] += 1
        self._rtc_clock_changed()

    def _pll_src_name(self):
        return 'HSE' if self.pllsrc else 'HSI'

    def _pll_try_lock(self):
        pll = self._osc['PLL']
        if not pll['on'] or pll['rdy'] or pll['pending']:
            return
        if not self._osc[self._pll_src_name()]['rdy']:
            return                                       # starts locking when its source is stable
        if not self._pll_params_valid():
            self._log_once('pll_params', f"PLL enabled with PLLMUL={self.pllmul} PLLDIV={self.plldiv}: "
                           "not allowed (6.3.3), PLL does not lock")
            return
        pll['pending'] = True
        g = pll['gen']

        def locked():
            if pll['gen'] != g or not pll['on']:
                return
            pll['pending'] = False
            pll['rdy'] = True
            self._set_flag('PLL')
            self._try_switch()
        self.m.schedule(self._cyc(PLL_LOCK_US), locked)

    def _in_use(self, name):
        """True when the oscillator drives the system clock directly or through the PLL (6.3.1)."""
        if name == 'PLL':
            return self.sws == 3 or self.sw == 3            # "used or selected to become" (rm0038.txt:7289)
        if name == 'MSI':
            return self.sws == 0
        if name == 'HSI':
            return self.sws == 1 or (self.sws == 3 and not self.pllsrc)
        if name == 'HSE':
            return self.sws == 2 or (self.sws == 3 and bool(self.pllsrc))
        return False

    def _request(self, name, want):
        if not want and self._in_use(name):
            return                                       # cannot be cleared while in use
        self._osc_set(name, want)

    def _try_switch(self):
        """6.2.7 (rm0038.txt:7003): the switch happens when the selected source is ready."""
        if self.sws != self.sw and self._osc[('MSI', 'HSI', 'HSE', 'PLL')[self.sw]]['rdy']:
            self.sws = self.sw
            self._recalc_clock()

    # ------------------------------------------------------------------ clock security system
    def fail_hse(self):
        """HSE failure seen by the CSS (6.2.9, rm0038.txt:7039).  Only acts when CSSON is set and
        the HSE is ready (the detector runs then)."""
        if not (self.csson and self._osc['HSE']['rdy']):
            self._log("HSE failure ignored: CSS not active")
            return
        self.cir_flags |= CIR_FLAG['CSS']
        self.m.set_pending(2)                            # CSSI is linked to the NMI vector
        used = self._in_use('HSE')
        hse = self._osc['HSE']                           # the HSE oscillator is disabled by hardware
        hse.update(on=False, rdy=False, pending=False)
        hse['gen'] += 1
        pll = self._osc['PLL']
        if self.pllsrc:                                  # the PLL loses its input clock
            pll.update(rdy=False, pending=False)
            pll['gen'] += 1
        if used:
            # system clock falls back to MSI (SW forced to 00, MSION forced on); a PLL fed by HSE is
            # disabled too (6.2.9 rm0038.txt:7046)
            self._osc_set('MSI', True)
            self.sw = 0
            if self._osc['MSI']['rdy']:
                self.sws = 0
            if self.pllsrc:
                pll['on'] = False
            self._recalc_clock()
        self._rtc_clock_changed()

    def fail_lse(self):
        """LSE failure seen by the CSS on LSE (6.2.10, rm0038.txt:7063)."""
        if not self.lsecsson:
            return
        self.lsecssd = 1
        if self.cir_ie & (CIR_FLAG['LSECSS'] << 8):
            self.cir_flags |= CIR_FLAG['LSECSS']

    def force_lsi(self):
        """Independent watchdog active: LSI forced on and cannot be disabled (6.2.12, rm0038.txt:7107)."""
        self.lsi_forced = True
        self._osc_set('LSI', True)

    # ------------------------------------------------------------------ register read
    def _cr(self):
        o = self._osc
        return (o['HSI']['on'] | o['HSI']['rdy'] << 1 | o['MSI']['on'] << 8 | o['MSI']['rdy'] << 9 |
                o['HSE']['on'] << 16 | o['HSE']['rdy'] << 17 | self.hsebyp << 18 |
                o['PLL']['on'] << 24 | o['PLL']['rdy'] << 25 | self.csson << 28 | self.rtcpre << 29)

    def _icscr(self):
        return (self.msitrim << 24 | self.msical << 16 | self.msirange << 13 |
                self.hsitrim << 8 | self.hsical)

    def _cfgr(self):
        return (self.mcopre << 28 | self.mcosel << 24 | self.plldiv << 22 | self.pllmul << 18 |
                self.pllsrc << 16 | self.ppre2 << 11 | self.ppre1 << 8 | self.hpre << 4 |
                self.sws << 2 | self.sw)

    def _cir(self):
        return self.cir_flags | self.cir_ie                # clear bits 23:16 are write-only, read 0

    def _csr(self):
        o = self._osc
        return (self.csr_flags | self.rmvf << 24 | self.rtcrst << 23 | self.rtcen << 22 |
                self.rtcsel << 16 | self.lsecssd << 12 | self.lsecsson << 11 | self.lsebyp << 10 |
                o['LSE']['rdy'] << 9 | o['LSE']['on'] << 8 | o['LSI']['rdy'] << 1 | o['LSI']['on'])

    def _reg_read(self, reg):
        if reg == 0x00:
            return self._cr()                              # RCC_CR 6.3.1 rm0038.txt:7249
        if reg == 0x04:
            return self._icscr()                           # RCC_ICSCR 6.3.2 rm0038.txt:7353
        if reg == 0x08:
            return self._cfgr()                            # RCC_CFGR 6.3.3 rm0038.txt:7397
        if reg == 0x0C:
            return self._cir()                             # RCC_CIR 6.3.4 rm0038.txt:7542
        if reg == 0x10:
            return self.ahbrstr                            # RCC_AHBRSTR 6.3.5 rm0038.txt:7695
        if reg == 0x14:
            return self.apb2rstr                           # RCC_APB2RSTR 6.3.6 rm0038.txt:7798
        if reg == 0x18:
            return self.apb1rstr                           # RCC_APB1RSTR 6.3.7 rm0038.txt:7860
        if reg == 0x1C:
            return self.ahbenr                             # RCC_AHBENR 6.3.8 rm0038.txt:7992
        if reg == 0x20:
            return self.apb2enr                            # RCC_APB2ENR 6.3.9 rm0038.txt:8096
        if reg == 0x24:
            return self.apb1enr                            # RCC_APB1ENR 6.3.10 rm0038.txt:8170
        if reg == 0x28:
            return self.ahblpenr                           # RCC_AHBLPENR 6.3.11 rm0038.txt:8300
        if reg == 0x2C:
            return self.apb2lpenr                          # RCC_APB2LPENR 6.3.12 rm0038.txt:8407
        if reg == 0x30:
            return self.apb1lpenr                          # RCC_APB1LPENR 6.3.13 rm0038.txt:8479
        if reg == 0x34:
            return self._csr()                             # RCC_CSR 6.3.14 rm0038.txt:8610
        return None

    def read(self, off, size):
        val = self._reg_read(off & ~3)
        if val is None:
            self.unmodelled(off, 'R')
            return 0
        return self.extract(val, off, size)

    # ------------------------------------------------------------------ register write
    def write(self, off, value, size):
        reg = off & ~3
        old = self._reg_read(reg)
        if old is None:
            self.unmodelled(off, 'W')
            return
        new = self.merge(old, off, value, size)
        if reg == 0x00:
            self._w_cr(new)
        elif reg == 0x04:
            self._w_icscr(new)
        elif reg == 0x08:
            self._w_cfgr(new)
        elif reg == 0x0C:
            self._w_cir(new)
        elif reg == 0x10:
            self.ahbrstr = self._flitf_gate(old, new & AHB_MASK, self.ahbrstr)
            self._notify_resets(old, self.ahbrstr, AHB_BITS)
        elif reg == 0x14:
            self.apb2rstr = new & APB2_MASK
            self._notify_resets(old, self.apb2rstr, APB2_BITS)
        elif reg == 0x18:
            self.apb1rstr = new & APB1_MASK
            self._notify_resets(old, self.apb1rstr, APB1_BITS)
        elif reg == 0x1C:
            self.ahbenr = self._flitf_gate(old, new & AHB_MASK, self.ahbenr)
        elif reg == 0x20:
            self.apb2enr = new & APB2_MASK
        elif reg == 0x24:
            self.apb1enr = new & APB1_MASK
        elif reg == 0x28:
            self.ahblpenr = self._flitf_gate(old, new & AHBLP_MASK, self.ahblpenr)
        elif reg == 0x2C:
            self.apb2lpenr = new & APB2_MASK
        elif reg == 0x30:
            self.apb1lpenr = new & APB1_MASK
        elif reg == 0x34:
            self._w_csr(new)
        if reg in (0x00, 0x34):                            # RTCPRE, LSION, LSEON, RTCSEL, RTCEN, RTCRST
            self._rtc_clock_changed()

    def _flitf_gate(self, old, new, current):
        """FLITFEN / FLITFLPEN / FLITFRST (bit 15) can be written only while the Flash is in power
        down mode (6.3.5 rm0038.txt:7743, 6.3.8 rm0038.txt:8036, 6.3.11 rm0038.txt:8353)."""
        if not self._flash_power_down():
            new = (new & ~(1 << 15)) | (current & (1 << 15))
        return new

    def _notify_resets(self, old, new, bits):
        """PWRRST is the only peripheral reset whose effect RM0038 defines in a model-visible way
        (PWR_CR, 5.4.1 rm0038.txt:6241).  Other models register callables in reset_hooks[name]."""
        for b, n in bits:
            if (new >> b & 1) and not (old >> b & 1):
                for hook in self.reset_hooks.get(n, ()):
                    hook()
        pwr = self._pwr()
        if pwr is None:
            return
        for b, n in bits:
            if n == 'PWR' and (new >> b & 1) and not (old >> b & 1):
                pwr.rcc_reset_asserted()

    # RCC_CR ---------------------------------------------------------------
    def _w_cr(self, new):
        hseon_before = self._osc['HSE']['on']
        if not hseon_before:
            self.hsebyp = new >> 18 & 1                    # HSEBYP writable only when HSE is off
            self.rtcpre = new >> 29 & 3                    # RTCPRE not modifiable while HSEON = 1
        self.csson = new >> 28 & 1
        self._request('HSI', bool(new & 1))
        self._request('MSI', bool(new >> 8 & 1))
        self._request('HSE', bool(new >> 16 & 1))
        self._request('PLL', bool(new >> 24 & 1))

    # RCC_ICSCR ------------------------------------------------------------
    def _w_icscr(self, new):
        msitrim = new >> 24 & 0xFF
        msirange = new >> 13 & 7
        hsitrim = new >> 8 & 0x1F
        if msirange == 7:
            self._log_once('msirange7', "MSIRANGE=111 is not allowed (6.3.2): write of that field ignored")
        else:
            if msirange != self.msirange:
                self.msirange = msirange
                if self.sws == 0:
                    self._recalc_clock()
        if msitrim != self.msitrim:
            self.msitrim = msitrim
            self.msical = (self.factory_msical + msitrim) & 0xFF      # MSICAL = factory + MSITRIM
            if self.sws == 0 and self.msi_trim_ppm:
                self._recalc_clock()                                   # the trim moves the MSI frequency (model)
        if hsitrim != self.hsitrim:
            self.hsitrim = hsitrim
            self.hsical = (self.factory_hsical + hsitrim) & 0xFF      # HSICAL = factory + HSITRIM

    # RCC_CFGR -------------------------------------------------------------
    def _w_cfgr(self, new):
        pll_on = self._osc['PLL']['on']
        if not pll_on:                                     # PLLSRC / PLLMUL / PLLDIV: only with PLL off
            self.pllsrc = new >> 16 & 1
            self.pllmul = new >> 18 & 0xF
            self.plldiv = new >> 22 & 3
        self.ppre2 = new >> 11 & 7
        self.ppre1 = new >> 8 & 7
        self.hpre = new >> 4 & 0xF
        self.mcosel = new >> 24 & 7
        self.mcopre = new >> 28 & 7
        self.sw = new & 3
        self._try_switch()
        self._recalc_clock()

    # RCC_CIR --------------------------------------------------------------
    def _w_cir(self, new):
        self.cir_ie = new & CIR_IE_MASK
        self.cir_flags &= ~((new >> 16) & 0xFF)

    # RCC_CSR --------------------------------------------------------------
    def _dbp(self):
        pwr = self._pwr()
        return bool(pwr is not None and pwr.dbp)

    def _w_csr(self, new):
        # LSION: system-reset domain; cannot be cleared while the IWDG forces the LSI (6.2.12)
        want = bool(new & 1)
        if want or not self.lsi_forced:
            self._osc_set('LSI', want)
        # RMVF clears all reset flags (bits 31:25)
        self.rmvf = new >> 24 & 1
        if self.rmvf:
            self.csr_flags = 0
        # RTCRST: holds the RTC domain in reset while set
        was_rst = self.rtcrst
        self.rtcrst = new >> 23 & 1
        if self.rtcrst and not was_rst:
            self._rtc_domain_reset()
        # LSECSSON: once set it can be cleared only after an LSE failure (LSECSSD = 1)
        if (new >> 11 & 1) or self.lsecssd:
            if not self.rtcrst:
                self.lsecsson = new >> 11 & 1
        # LSEON, LSEBYP, RTCSEL and RTCEN are write protected unless PWR_CR.DBP = 1
        if self._dbp() and not self.rtcrst:
            lse_was_on = self._osc['LSE']['on']
            if not lse_was_on:
                self.lsebyp = new >> 10 & 1               # LSEBYP only while LSE is disabled
            self._osc_set('LSE', bool(new >> 8 & 1))
            sel = new >> 16 & 3
            if self.rtcsel == 0 or (self.rtcsel == 1 and self.lsecssd):
                self.rtcsel = sel                         # selection is locked once made (6.3.14)
            self.rtcen = new >> 22 & 1
