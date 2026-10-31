"""STM32L152ZD 12-bit ADC (ADC1 and the common registers), base 0x40012400, size 0x400.

Sources: RM0038 chapter 12 (rm0038.txt lines 14920 - 17540; section numbers and text-file lines are quoted next
to each item) and the STM32L151xD/L152xD datasheet (DocID022027 Rev 12: Table 64 ADC characteristics, Table 16
VREFINT, Table 70 temperature sensor).

Address map (RM0038 Table 5 "Register boundary addresses", rm0038.txt:2276: ADC 0x4001 2400 - 0x4001 27FF; Table 64
ADC global register map, rm0038.txt:17192: 0x000 - 0x058 ADC1, 0x05C SMPR0, 0x05C - 0x2FC reserved, 0x300 - 0x304
common registers).  Offsets are relative to 0x40012400, so the common registers sit at 0x40012700.

    0x00 SR     0x04 CR1    0x08 CR2    0x0C SMPR1  0x10 SMPR2  0x14 SMPR3  0x18-0x24 JOFR1..4
    0x28 HTR    0x2C LTR    0x30-0x40 SQR1..SQR5    0x44 JSQR   0x48-0x54 JDR1..4   0x58 DR   0x5C SMPR0
    0x300 CSR   0x304 CCR
Every other offset is reserved and goes to unmodelled().  JDRx, DR and CSR are read only; a write to them is ignored
and logged once.

Interrupt: ADC1 global interrupt, vector table position 18 (RM0038 Table 51, rm0038.txt:13024), nvic.irq(18).
The line is the OR of EOC&EOCIE, JEOC&JEOCIE, AWD&AWDIE and OVR&OVRIE (12.14 Table 63, rm0038.txt:16260); it is
level sensitive and is pended again after a handler returns while a flag is still set.

Clock gate: while rcc.clock_enabled('ADC1') (RCC_APB2ENR bit 9) is false, reads return 0 and writes are ignored (the
first such access is logged); this matches the other peripheral models.  ADCCLK is HSI divided by ADCPRE (12.3.2,
rm0038.txt:15147; 12.15.20 ADCPRE, rm0038.txt:17173), independent of the CPU clock.  A conversion or power-up starts
only while the HSI oscillator reports ready; if it does not, the action waits and is retried every
CLOCK_POLL_CYCLES core cycles.  The clock is sampled when an action starts: a conversion already running is not
interrupted when HSI is switched off afterwards.  Without an RCC model on the machine, HSI is assumed running.

Analog inputs (board side)
    set_channel_volts(ch, volts, bank='A')   voltage on ADC_INch (bank 'B' = ADC_INchb), 0 V until set
    vref_volts                               VREF+ = VDDA; code = floor(volts / vref_volts * (2**RES - 1) + 0.5), clamped
    temp_c                                   junction temperature seen by the temperature sensor
Channels that RM0038 Table 41 (rm0038.txt:10653) lists as "ADC_INx/ADC_INxb" (4, 5, 13 - 31) are the same pin in both
banks; a value set for bank 'A' is used for bank 'B' unless a bank 'B' value was set explicitly.  The other channels
(0 - 3, 6 - 12) have separate pins in the two banks.
Internal channels (12.12, rm0038.txt:16057): ADC_IN16 = temperature sensor, ADC_IN17 = VREFINT, both only while
ADC_CCR.TSVREFE = 1; with TSVREFE = 0 they read as 0 V (RM0038 does not give the result of converting them while
disabled; 0 V is the model's choice).  Values (datasheet, typical column):
    VREFINT      = 1.224 V                              Table 16 VREFINT out
    V_TS(T)      = 626.8 mV + 1.61 mV/degC * (T - 110)  Table 70: V110 = 626.8 mV at 110 degC, Avg_Slope = 1.61 mV/degC
Both are voltages that the ADC converts relative to VREF+ like any other input (12.12 "ratio between the analog
power supply and the voltage applied on the converted channel", rm0038.txt:16160).  set_channel_volts(16 or 17, v)
replaces the datasheet value (still gated by TSVREFE).  Channel 26 (VCOMP) is an ordinary board-set input.  The
tSTART (10 us) and TVREFINT (2 ms) start-up times of the two internal sources are not modelled.

Conversion timing (12.3.6 and 12.5, rm0038.txt:15251, 15551): total conversion time = sampling time (SMPx, 4 - 384
ADCCLK cycles) + 12 / 11 / 9 / 7 ADCCLK cycles for RES = 12 / 10 / 8 / 6 bit (12.15.2 RES, 12.8).  The input is
latched when the sampling phase ends; EOC / JEOC and the data registers update when the conversion ends.

Timing values RM0038 does not give, taken from the datasheet or fixed by the model:
    tSTAB 3.5 us         datasheet Table 64 "Power-up time" (maximum; no typical value is given)
    trigger latency      a trigger (SWSTART, JSWSTART or external) starts the conversion after 3 ADCCLK cycles for the
                         regular group and 4 for the injected group: the middle of the datasheet tlatr 2.5 - 3.5 and
                         tlat 3.5 - 4.5 cycles (those are given for external triggers; software start has no figure)
    abort / not-ready    RCNR / JCNR stay set for 5 ADCCLK + 5 APB cycles after an SQRx / JSQR write or an OVR clear:
                         the upper bounds of "3 to 5 ADC clock cycles + 2 to 5 APB clock cycles" (12.7.1, rm0038.txt:15661)
    delay sync           DELS delays add 3 ADCCLK cycles + 1 APB cycle: the upper bounds of "2 or 3 ADC clock
                         cycles" and "0 to 1 PCLK clock cycles" (12.9.1 footnote 2, rm0038.txt:15804)
    ADONS fall / PDI     ADONS follows ADON after one ADCCLK period when the ADC is switched off, or on when PDI = 1
                         ("synchronized to the ADCCLK clock domain", 12.3.1, rm0038.txt:15116)

Features implemented (all per RM0038 chapter 12): ADON power-up with ADONS after tSTAB; PDI / PDD power-down (the
tSTAB power-up time is added to the next conversion); single, continuous, scan and discontinuous (DISCEN, JDISCEN,
DISCNUM) conversions; injected conversions (JSWSTART / external trigger, JAUTO, scan); injected priority over the
regular group with the interrupted regular conversion converted again afterwards; external triggers through
ext_trigger() (Tables 60 - 62); 6/8/10/12-bit resolution; right / left alignment (Figures 44 - 46); JOFRx offset
subtraction; analog watchdog (Table 59); EOC / JEOC / OVR / AWD / STRT / JSTRT flags and the ADC1 interrupt; EOCS;
overrun and the DR-emptied rule (12.11); DELS freeze / delay insertion (12.9); RCNR / JCNR (12.7); DMA request line
(below); CSR / CCR.

SWSTART / JSWSTART written while ADONS = 0 or RCNR / JCNR = 1 (RM0038: "must be set only when ADONS=1 and RCNR=0")
are held and start the conversion as soon as the ADC is ready; RM0038 does not say what hardware does in that case.
The bit reads 1 until the conversion starts.  A start event that arrives while the group is in a delay, while its
sequence is running, or while OVR is set is ignored (12.9, 12.11.1).

DMA: the DMA controller is separate.  Board code sets `adc.dma_request` to a callable (called with this ADC) that
makes the controller transfer DR; after its last programmed transfer the controller calls
`adc.dma_transfer_complete()`, which blocks further requests when DDS = 0 until DMA is written 0 then 1
(12.11.1, rm0038.txt:15983).  Writing CR2.DMA = 1 without a dma_request routes to unmodelled().

Reset: reset() restores the reset values (all registers 0 except HTR = 0xFFF).  RCC does not call the ADC when
RCC_APB2RSTR.ADC1RST is pulsed; board code that models that reset must call reset().
"""
import math
from fractions import Fraction

from .base import Periph

# ------------------------------------------------------------------ registers (offsets inside the block)
SR, CR1, CR2, SMPR1, SMPR2, SMPR3 = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14
JOFR = (0x18, 0x1C, 0x20, 0x24)
HTR, LTR = 0x28, 0x2C
SQR1, SQR2, SQR3, SQR4, SQR5 = 0x30, 0x34, 0x38, 0x3C, 0x40
JSQR = 0x44
JDR = (0x48, 0x4C, 0x50, 0x54)
DR, SMPR0 = 0x58, 0x5C
CSR, CCR = 0x300, 0x304
READ_ONLY = frozenset(JDR + (DR, CSR))
KNOWN = frozenset((SR, CR1, CR2, SMPR0, SMPR1, SMPR2, SMPR3, HTR, LTR, SQR1, SQR2, SQR3, SQR4, SQR5, JSQR, CCR)
                  + JOFR) | READ_ONLY

IRQ = 18                                    # Table 51 position of ADC1 (rm0038.txt:13024)

# SR bits (12.15.1, rm0038.txt:16274)
SR_AWD, SR_EOC, SR_JEOC, SR_JSTRT, SR_STRT, SR_OVR = 1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4, 1 << 5
SR_ADONS, SR_RCNR, SR_JCNR = 1 << 6, 1 << 8, 1 << 9
SR_RC_W0 = SR_AWD | SR_EOC | SR_JEOC | SR_JSTRT | SR_STRT | SR_OVR      # rc_w0 bits

# CR1 bits (12.15.2, rm0038.txt:16351); bits 31:27 and 21:18 reserved
CR1_MASK = 0x07C3FFFF
CR1_AWDCH = 0x1F
CR1_EOCIE, CR1_AWDIE, CR1_JEOCIE, CR1_SCAN = 1 << 5, 1 << 6, 1 << 7, 1 << 8
CR1_AWDSGL, CR1_JAUTO, CR1_DISCEN, CR1_JDISCEN = 1 << 9, 1 << 10, 1 << 11, 1 << 12
CR1_PDD, CR1_PDI = 1 << 16, 1 << 17
CR1_JAWDEN, CR1_AWDEN, CR1_OVRIE = 1 << 22, 1 << 23, 1 << 26
CR1_ON_ONLY = (3 << 24) | CR1_PDI | CR1_PDD | (7 << 13) | CR1_JDISCEN | CR1_DISCEN | CR1_JAUTO | CR1_SCAN

# CR2 bits (12.15.3, rm0038.txt:16485); bits 31, 23, 15:12, 7, 3 reserved
CR2_MASK = 0x7F7F0F77
CR2_ADON, CR2_CONT, CR2_CFG = 1 << 0, 1 << 1, 1 << 2
CR2_DMA, CR2_DDS, CR2_EOCS, CR2_ALIGN = 1 << 8, 1 << 9, 1 << 10, 1 << 11
CR2_JSWSTART, CR2_SWSTART = 1 << 22, 1 << 30
CR2_DELS = 7 << 4

CCR_MASK = 0x00830000                       # TSVREFE (bit 23) and ADCPRE[1:0] (17:16), 12.15.20
CCR_TSVREFE = 1 << 23

SMPR_MASK = 0x3FFFFFFF                      # SMPR1..3: 30 bits (12.15.4 - 12.15.6)
SMPR0_MASK = 0x3F                           # SMPR0: channels 30, 31 (12.15.18, rm0038.txt:17075)
SMP_CYCLES = (4, 9, 16, 24, 48, 96, 192, 384)                   # SMPx[2:0] 12.15.4
CONV_CYCLES = (12, 11, 9, 7)                                    # RES[1:0] 12.15.2 (rm0038.txt:16375)
RES_BITS = (12, 10, 8, 6)
ADCPRE_DIV = (1, 2, 4, None)                # 12.15.20: 00 /1, 01 /2, 10 /4, 11 reserved

HSI_HZ = 16_000_000                         # 12.3.2 (rm0038.txt:15147)
TSTAB_US = Fraction(7, 2)                   # datasheet Table 64 tSTAB (maximum)
LAT_REGULAR, LAT_INJECTED = 3, 4            # ADCCLK cycles, middle of datasheet tlatr / tlat ranges
ABORT_ADC, ABORT_APB = 5, 5                 # 12.7.1 upper bounds
DELAY_SYNC_ADC, DELAY_SYNC_APB = 3, 1       # 12.9.1 footnote 2 upper bounds
CLOCK_POLL_CYCLES = 64

VREFINT_V = 1.224                           # datasheet Table 16, typical
TS_V110, TS_SLOPE, TS_T110 = 0.6268, 0.00161, 110.0             # datasheet Table 70, typical
SHARED_CHANNELS = frozenset([4, 5] + list(range(13, 32)))       # ADC_INx / ADC_INxb, Table 41

# External trigger sources, Table 61 (regular, rm0038.txt:15592) and Table 62 (injected, rm0038.txt:15624)
EXT_REGULAR = {'TIM9_CC2': 0, 'TIM9_TRGO': 1, 'TIM2_CC3': 2, 'TIM2_CC2': 3, 'TIM3_TRGO': 4, 'TIM4_CC4': 5,
               'TIM2_TRGO': 6, 'TIM3_CC1': 7, 'TIM3_CC3': 8, 'TIM4_TRGO': 9, 'TIM6_TRGO': 10, 'EXTI11': 15}
EXT_INJECTED = {'TIM9_CC1': 0, 'TIM9_TRGO': 1, 'TIM2_TRGO': 2, 'TIM2_CC1': 3, 'TIM3_CC4': 4, 'TIM4_TRGO': 5,
                'TIM4_CC1': 6, 'TIM4_CC2': 7, 'TIM4_CC3': 8, 'TIM10_CC1': 9, 'TIM7_TRGO': 10, 'EXTI15': 15}


class ADC(Periph):
    name = "ADC1"
    base = 0x40012400
    SIZE = 0x400

    def __init__(self, vref_volts=3.3, temp_c=25.0):
        super().__init__()
        self.vref_volts = vref_volts
        self.temp_c = temp_c
        self.dma_request = None
        self._volts = {'A': {}, 'B': {}}
        self._gate_logged = False
        self._warned = set()
        self._gen = 0                       # invalidates everything scheduled before a power-down / reset
        self.tok = 0                        # token of the conversion in flight (monotonic, never reset)
        self.r_ep = self.j_ep = 0           # start epochs: an SQRx / JSQR write cancels start events in flight
        self._irq_armed = False
        self._irq_gen = 0
        self._clock_polling = False
        self._poll_gen = 0                  # voids the ADCCLK poll scheduled before a reset
        self.reset()

    # ------------------------------------------------------------------ reset
    def reset(self):
        """All registers to their reset values (12.15, Table 65 / 66); HTR = 0xFFF (12.15.8)."""
        self._gen += 1
        self.tok += 1
        self.r_ep += 1
        self.j_ep += 1
        self._poll_gen += 1
        self._clock_polling = False
        self._irq_gen += 1                  # the level re-pend poll of the previous life is void
        self._irq_armed = False
        self.flags = 0                      # SR bits that are flip-flops (AWD, EOC, JEOC, JSTRT, STRT, OVR)
        self.cr1 = self.cr2 = self.ccr = 0
        self.smpr = {SMPR0: 0, SMPR1: 0, SMPR2: 0, SMPR3: 0}
        self.jofr = [0, 0, 0, 0]
        self.htr, self.ltr = 0xFFF, 0
        self.sqr = [0, 0, 0, 0, 0]          # SQR1..SQR5
        self.jsqr = 0
        self.jdr = [0, 0, 0, 0]
        self.dr = 0
        self.dr_valid = False               # DR holds data that were not read yet (12.11.4)
        self.on = False                     # ADON as seen by the engine
        self.ready = False                  # ADONS
        self.powering = False
        self.need_stab = False              # next conversion pays tSTAB (PDI / PDD power-down)
        self.busy = None                    # ('R' | 'J', rank, channel) while converting
        self.r_active = self.r_req = False
        self.r_seq, self.r_pos, self.r_left, self.r_disc_pos = [], 0, None, 0
        self.j_active = self.j_req = self.j_auto = False
        self.j_seq, self.j_pos, self.j_left, self.j_disc_pos = [], 0, None, 0
        self.sw_r = self.sw_j = False       # SWSTART / JSWSTART written, waiting for ADONS / RCNR / JCNR
        self.r_block_until = self.j_block_until = 0
        self.rcnr_until = self.jcnr_until = 0
        self.dma_blocked = False
        self._wake_at = {'R': -1, 'J': -1}

    # ------------------------------------------------------------------ board side
    def set_channel_volts(self, ch, volts, bank='A'):
        if not 0 <= ch <= 31:
            raise ValueError("ADC channel must be 0..31")
        if bank not in ('A', 'B'):
            raise ValueError("bank must be 'A' or 'B'")
        self._volts[bank][ch] = float(volts)

    def ext_trigger(self, source, edge):
        """Board side: an external trigger event.  source is a name from Table 61 / 62 (e.g. 'TIM2_CC3', 'EXTI11'),
        edge is 'rising' or 'falling'.  Applies EXTEN / EXTSEL (regular) and JEXTEN / JEXTSEL (injected), 12.6 Table 60."""
        want = 1 if edge == 'rising' else 2
        if not self._clk_on() or not self._ready_now():
            return
        exten, extsel = (self.cr2 >> 28) & 3, (self.cr2 >> 24) & 15
        if exten & want and EXT_REGULAR.get(source) == extsel:
            self._start_after(LAT_REGULAR, 'R', sw=False)
        jexten, jextsel = (self.cr2 >> 20) & 3, (self.cr2 >> 16) & 15
        if jexten & want and EXT_INJECTED.get(source) == jextsel:
            self._start_after(LAT_INJECTED, 'J', sw=False)

    def dma_transfer_complete(self):
        """DMA controller side: the last programmed transfer finished (12.11.1)."""
        if not self.cr2 & CR2_DDS:
            self.dma_blocked = True

    # ------------------------------------------------------------------ clocks and time
    def _rcc(self):
        return getattr(self.m, "rcc", None)

    def _clk_on(self):
        rcc = self._rcc()
        if rcc is None:
            return True
        try:
            return rcc.clock_enabled(self.name)
        except KeyError:
            return True

    def _adc_hz(self):
        """ADCCLK in Hz, or None while it is not running (HSI not ready, or the reserved ADCPRE = 3)."""
        div = ADCPRE_DIV[(self.ccr >> 16) & 3]
        if div is None:
            return None
        rcc = self._rcc()
        if rcc is not None and not rcc._is_ready('HSI'):
            return None
        return HSI_HZ // div

    def _cyc_adc(self, n):
        """Core cycles for n ADCCLK cycles (at least 1)."""
        div = ADCPRE_DIV[(self.ccr >> 16) & 3] or 4
        return max(1, math.ceil(Fraction(n) * self.m.sysclk_hz * div / HSI_HZ))

    def _cyc_us(self, us):
        return max(1, math.ceil(Fraction(us) * self.m.sysclk_hz / 1_000_000))

    def _cyc_apb(self, n):
        rcc = self._rcc()
        pclk = rcc.pclk2_hz if rcc is not None else self.m.sysclk_hz
        return max(1, math.ceil(Fraction(n) * self.m.sysclk_hz / pclk))

    def _need_clock(self):
        """Wait for ADCCLK: poll until it runs, then resume (the reserved ADCPRE is retried on the next CCR write)."""
        if self._clock_polling or ((self.ccr >> 16) & 3) == 3:
            return
        self._clock_polling = True
        gen, pgen = self._gen, self._poll_gen
        self.m.schedule(CLOCK_POLL_CYCLES, lambda: self._clock_poll(gen, pgen))

    def _clock_poll(self, gen, pgen):
        if pgen != self._poll_gen:
            return
        self._clock_polling = False
        if gen != self._gen:
            return
        if self._adc_hz() is None:
            self._need_clock()
        else:
            self._resume()

    def _resume(self):
        if self.on and not self.ready and not self.powering:
            self._power_up()
        self._kick()
        self._pump()

    def _log_once(self, key, text):
        if key not in self._warned:
            self._warned.add(key)
            self.m.log.append((self.m.cycles, text))

    # ------------------------------------------------------------------ power (12.3.1, 12.10)
    def _power_up(self):
        if self._adc_hz() is None:
            self._need_clock()
            return
        self.powering = True
        gen = self._gen
        pdi = bool(self.cr1 & CR1_PDI)
        # PDI = 1: ADONS is the image of ADON; the power-up time is paid when a conversion starts (12.3.1)
        delay = self._cyc_adc(1) if pdi else self._cyc_us(TSTAB_US)
        self.need_stab = pdi
        self.m.schedule(delay, lambda: self._powered(gen))

    def _powered(self, gen):
        if gen != self._gen or not self.on:
            return
        self.powering = False
        self.ready = True
        self._kick()
        self._pump()

    def _power_down(self):
        self._gen += 1                      # abort scheduled conversions, power-up and delays
        self.tok += 1
        self.r_ep += 1
        self.j_ep += 1
        self.on = False
        self.powering = False
        self.busy = None
        self.r_active = self.r_req = self.j_active = self.j_req = self.j_auto = False
        self.r_disc_pos = self.j_disc_pos = 0
        self.sw_r = self.sw_j = False
        self.cr2 &= ~(CR2_SWSTART | CR2_JSWSTART)
        self.r_block_until = self.j_block_until = 0
        self._wake_at = {'R': -1, 'J': -1}
        gen = self._gen
        # ADONS is cleared after ADON was synchronized to ADCCLK (12.3.1)
        self.m.schedule(self._cyc_adc(1), lambda: self._off_sync(gen))

    def _off_sync(self, gen):
        if gen == self._gen:
            self.ready = False

    def _ready_now(self):
        return self.on and self.ready

    # ------------------------------------------------------------------ analog inputs
    def _volts_of(self, ch):
        if ch in (16, 17):
            if not self.ccr & CCR_TSVREFE:
                return 0.0
            for bank in ('A', 'B'):
                if ch in self._volts[bank]:
                    return self._volts[bank][ch]
            if ch == 17:
                return VREFINT_V
            return TS_V110 + TS_SLOPE * (self.temp_c - TS_T110)
        bank = 'B' if self.cr2 & CR2_CFG else 'A'
        v = self._volts[bank].get(ch)
        if v is None and ch in SHARED_CHANNELS:
            v = self._volts['A'].get(ch)
        return 0.0 if v is None else v

    def _code(self, volts):
        fs = (1 << RES_BITS[(self.cr1 >> 24) & 3]) - 1
        c = int(math.floor(volts / self.vref_volts * fs + 0.5)) if self.vref_volts > 0 else fs
        return max(0, min(fs, c))

    def _smp_cycles(self, ch):
        if ch >= 30:
            reg, k = SMPR0, ch - 30
        elif ch >= 20:
            reg, k = SMPR1, ch - 20
        elif ch >= 10:
            reg, k = SMPR2, ch - 10
        else:
            reg, k = SMPR3, ch
        return SMP_CYCLES[(self.smpr[reg] >> (3 * k)) & 7]

    # ------------------------------------------------------------------ sequences
    def _sq(self, i):
        """Channel of regular conversion i (1..28): SQR5 holds SQ1..6, SQR4 SQ7..12, SQR3 SQ13..18, SQR2 SQ19..24,
        SQR1 SQ25..28 (12.15.10 - 12.15.14, 5 bits each)."""
        reg = self.sqr[4 - (i - 1) // 6]
        return (reg >> (5 * ((i - 1) % 6))) & 0x1F

    def _regular_sequence(self):
        n = min((self.sqr[0] >> 20) & 0x1F, 27) + 1         # L[4:0] + 1; values above 27 are reserved
        return [self._sq(i) for i in range(1, n + 1)]

    def _injected_sequence(self):
        """JL + 1 conversions: JL = 3 converts JSQ1..JSQ4, JL = 2 JSQ2..JSQ4, JL = 1 JSQ3, JSQ4, JL = 0 JSQ4 only
        (12.15.15 note, rm0038.txt:17025).  Result: [(rank, channel)], rank 0 -> JDR1 / JOFR1."""
        jl = (self.jsqr >> 20) & 3
        jsq = [(self.jsqr >> (5 * k)) & 0x1F for k in range(4)]     # JSQ1..JSQ4
        return [(r, jsq[3 - jl + r]) for r in range(jl + 1)]

    # ------------------------------------------------------------------ triggers
    def _blocked(self, kind):
        """Delay insertion / freeze (12.9): a new conversion of the group cannot start."""
        freeze = (self.cr2 & CR2_DELS) == (1 << 4)
        if kind == 'R':
            return self.m.cycles < self.r_block_until or (freeze and self.dr_valid)
        return self.m.cycles < self.j_block_until or (freeze and bool(self.flags & SR_JEOC))

    def _not_ready(self, kind):
        return self.m.cycles < (self.rcnr_until if kind == 'R' else self.jcnr_until)

    def _drop_sw(self, kind):
        self.cr2 &= ~(CR2_SWSTART if kind == 'R' else CR2_JSWSTART)

    def _start_after(self, lat, kind, sw):
        """A start event of the group.  Ignored while the group cannot start: in a delay or freeze (12.9: "a trigger
        event ... occurring during this delay is ignored"), while its sequence runs, and for the regular group while
        OVR is set (12.11.1: "further regular triggers are ignored")."""
        if (not self._ready_now() or self._not_ready(kind) or self._blocked(kind) or
                (kind == 'R' and (self.flags & SR_OVR or self.r_active or self.r_req)) or
                (kind == 'J' and (self.j_active or self.j_req))):
            if sw:
                self._drop_sw(kind)
            return
        gen, ep = self._gen, (self.r_ep if kind == 'R' else self.j_ep)
        self.m.schedule(self._cyc_adc(lat), lambda: self._fire(gen, ep, kind, sw))

    def _fire(self, gen, ep, kind, sw):
        if gen != self._gen or ep != (self.r_ep if kind == 'R' else self.j_ep):
            return                          # powered down, reset or SQRx / JSQR written meanwhile (12.7)
        if not self._ready_now():
            return
        if kind == 'R':
            if self.flags & SR_OVR or self.r_active or self.r_req:
                if sw:
                    self._drop_sw('R')
                return
            self.r_req = True
        else:
            if self.j_active or self.j_req:
                if sw:
                    self._drop_sw('J')
                return
            self.j_req = True
            if self.busy is not None and self.busy[0] == 'R':
                self.tok += 1               # the injected group resets the regular conversion in flight (12.3.9);
                self.busy = None            # r_active / r_pos stay, so that conversion is made again afterwards
        self._pump()

    def _kick(self):
        """Software starts that were waiting for ADONS / RCNR / JCNR."""
        if self.sw_r and self._ready_now() and not self._not_ready('R'):
            self.sw_r = False
            self._start_after(LAT_REGULAR, 'R', sw=True)
        if self.sw_j and self._ready_now() and not self._not_ready('J'):
            self.sw_j = False
            self._start_after(LAT_INJECTED, 'J', sw=True)

    # ------------------------------------------------------------------ engine
    def _pump(self):
        if self.busy is not None or not self._ready_now():
            return
        if (self.j_active or self.j_req) and self._j_step():
            return
        if self.r_active or self.r_req:
            self._r_step()

    def _wake(self, kind):
        """Re-run the engine when the timed delay of the group ends (a freeze ends by a flag clear instead)."""
        until = self.r_block_until if kind == 'R' else self.j_block_until
        if until <= self.m.cycles or self._wake_at[kind] == until:
            return
        self._wake_at[kind] = until
        gen = self._gen
        self.m.schedule(until - self.m.cycles, lambda: self._wake_fire(gen))

    def _wake_fire(self, gen):
        if gen == self._gen:
            self._pump()

    def _r_step(self):
        if self._blocked('R'):
            self._wake('R')
            return
        if not self.r_active:
            self.r_req = False
            full = self._regular_sequence()
            if self.cr1 & CR1_DISCEN and not self.cr1 & CR1_JAUTO:             # 12.3.10
                self.r_seq = full
                self.r_pos = self.r_disc_pos if self.r_disc_pos < len(full) else 0
                self.r_left = ((self.cr1 >> 13) & 7) + 1                      # DISCNUM + 1
            else:
                self.r_seq = full if self.cr1 & CR1_SCAN else full[:1]       # 12.3.4 / 12.3.8
                self.r_pos, self.r_left = 0, None
            self.r_active = True
            self._drop_sw('R')                                               # cleared as the conversion starts
        self._begin('R', self.r_pos, self.r_seq[self.r_pos])

    def _j_step(self):
        if self._blocked('J'):
            self._wake('J')
            return False
        if not self.j_active:
            self.j_req = False
            full = self._injected_sequence()
            if self.cr1 & CR1_JDISCEN and not self.cr1 & CR1_JAUTO:           # 12.3.10
                self.j_seq = full
                self.j_pos = self.j_disc_pos if self.j_disc_pos < len(full) else 0
                self.j_left = ((self.cr1 >> 13) & 7) + 1
            else:
                self.j_seq = full if self.cr1 & CR1_SCAN else full[:1]
                self.j_pos, self.j_left = 0, None
            self.j_active = True
            self.flags |= SR_JSTRT                                           # injected GROUP start flag
            self._drop_sw('J')
        rank, ch = self.j_seq[self.j_pos]
        return self._begin('J', rank, ch)

    def _begin(self, kind, rank, ch):
        if self._adc_hz() is None:
            self._need_clock()
            return False
        extra = 0
        if self.need_stab:
            extra = self._cyc_us(TSTAB_US)
            self.need_stab = False
        smp = self._smp_cycles(ch)
        self.tok += 1
        tok, gen = self.tok, self._gen
        self.busy = (kind, rank, ch)
        if kind == 'R':
            self.flags |= SR_STRT                                            # regular CHANNEL start flag
        t_sample = extra + self._cyc_adc(smp)
        t_end = extra + self._cyc_adc(smp + CONV_CYCLES[(self.cr1 >> 24) & 3])
        latched = []
        self.m.schedule(t_sample, lambda: latched.append(self._code(self._volts_of(ch)))
                        if (tok == self.tok and gen == self._gen) else None)
        self.m.schedule(max(t_end, t_sample + 1), lambda: self._done(tok, latched))
        return True

    def _done(self, tok, latched):
        if tok != self.tok or self.busy is None or not latched:
            return                          # aborted
        kind, rank, ch = self.busy
        self.busy = None
        if kind == 'R':
            self._r_done(ch, latched[0])
        else:
            self._j_done(rank, ch, latched[0])
        if not (self.r_active or self.r_req or self.j_active or self.j_req) and self.cr1 & CR1_PDI:
            self.need_stab = True           # waiting for a start event with PDI = 1: ADC powered down (12.10)
        self._irq_update()
        self._pump()

    def _awd(self, ch, raw, enable_bit):
        """Analog watchdog compare before alignment (12.3.7, Table 59); True when the scan must abort."""
        if not self.cr1 & enable_bit:
            return False
        if self.cr1 & CR1_AWDSGL and ch != (self.cr1 & CR1_AWDCH):
            return False
        if raw > self.htr or raw < self.ltr:
            self.flags |= SR_AWD
            return bool(self.cr1 & CR1_AWDIE and self.cr1 & CR1_SCAN)       # 12.15.2 AWDIE: scan aborted
        return False

    def _res(self):
        return RES_BITS[(self.cr1 >> 24) & 3]

    def _align_regular(self, code):
        if not self.cr2 & CR2_ALIGN:
            return code                                                      # Figure 44
        res = self._res()
        return (code << ((8 if res == 6 else 16) - res)) & 0xFFFF            # Figures 45 / 46

    def _align_injected(self, val):
        if not self.cr2 & CR2_ALIGN:
            return val & 0xFFFF                                              # SEXT = sign, Figure 44
        res = self._res()
        return (val << ((8 if res == 6 else 16) - (res + 1))) & 0xFFFF       # sign + data, Figures 45 / 46

    def _r_done(self, ch, raw):
        eocs, dma = bool(self.cr2 & CR2_EOCS), bool(self.cr2 & CR2_DMA)
        if (eocs or dma) and self.dr_valid:
            # DR was not emptied: the new data are lost and an overrun is flagged (12.11.4, SR.OVR 12.15.1)
            self.flags |= SR_OVR
            self.r_active = self.r_req = False
            self.r_pos = self.r_disc_pos = 0
            return
        self.dr = self._align_regular(raw)
        self.dr_valid = True
        last = self.r_pos == len(self.r_seq) - 1
        if eocs or last:
            self.flags |= SR_EOC
        abort = self._awd(ch, raw, CR1_AWDEN)
        if dma and not self.dma_blocked and self.dma_request is not None:
            self.dma_request(self)
        self.r_pos += 1
        if self.r_left is not None:
            self.r_left -= 1
        self._delay_after('R')
        if abort:
            self.r_active = self.r_req = False
            self.r_disc_pos = 0
        elif last:
            self.r_active = False
            self.r_disc_pos = 0
            if self.cr1 & CR1_JAUTO:                                        # 12.3.9 auto-injected conversion
                self.j_req = self.j_auto = True
            elif self.cr2 & CR2_CONT and not self.cr1 & CR1_DISCEN:         # 12.3.5 continuous
                self.r_req = True
        elif self.r_left == 0:                                              # discontinuous burst complete
            self.r_active = False
            self.r_disc_pos = self.r_pos

    def _j_done(self, rank, ch, raw):
        self.jdr[rank] = self._align_injected(raw - self.jofr[rank])         # 12.4: offset subtracted, may be negative
        last = self.j_pos == len(self.j_seq) - 1
        abort = self._awd(ch, raw, CR1_JAWDEN)
        self.j_pos += 1
        if self.j_left is not None:
            self.j_left -= 1
        if abort:
            self.j_active = False
            self.j_disc_pos = 0
            self.j_auto = False
            self._delay_after('J')
        elif last:
            self.j_active = False
            self.j_disc_pos = 0
            self.flags |= SR_JEOC
            self._delay_after('J')
            if self.j_auto:
                self.j_auto = False
                if self.cr2 & CR2_CONT:
                    self.r_req = True
        elif self.j_left == 0:
            self.j_active = False
            self.j_disc_pos = self.j_pos

    def _delay_after(self, kind):
        """Delay insertion after a regular conversion / an injected sequence (12.9, DELS in 12.15.3)."""
        dels = (self.cr2 >> 4) & 7
        if dels < 2:
            return                          # 000 none, 001 freeze (evaluated dynamically in _blocked)
        n = (1 << (dels + 1)) - 1           # 7, 15, 31, 63, 127, 255 APB cycles
        until = self.m.cycles + self._cyc_apb(n + DELAY_SYNC_APB) + self._cyc_adc(DELAY_SYNC_ADC)
        if kind == 'R':
            self.r_block_until = until
        else:
            self.j_block_until = until
        if self.cr1 & CR1_PDD:
            self.need_stab = True

    # ------------------------------------------------------------------ aborts (12.7)
    def _abort_regular(self):
        if self.busy is not None and self.busy[0] == 'R':
            self.tok += 1
            self.busy = None
        self.r_ep += 1
        self.r_active = self.r_req = False
        self.r_disc_pos = 0
        self.sw_r = False
        self._drop_sw('R')
        self._not_ready_pulse('R')

    def _abort_injected(self):
        if self.busy is not None and self.busy[0] == 'J':
            self.tok += 1
            self.busy = None
        self.j_ep += 1
        self.j_active = self.j_req = self.j_auto = False
        self.j_disc_pos = 0
        self.sw_j = False
        self._drop_sw('J')
        self._not_ready_pulse('J')

    def _not_ready_pulse(self, kind):
        cyc = self._cyc_adc(ABORT_ADC) + self._cyc_apb(ABORT_APB)
        if kind == 'R':
            self.rcnr_until = self.m.cycles + cyc
        else:
            self.jcnr_until = self.m.cycles + cyc
        gen = self._gen
        self.m.schedule(cyc, lambda: self._nr_end(gen))

    def _nr_end(self, gen):
        if gen == self._gen:
            self._kick()
            self._pump()

    # ------------------------------------------------------------------ interrupt line
    def _line(self):
        c1, f = self.cr1, self.flags
        return bool((f & SR_EOC and c1 & CR1_EOCIE) or (f & SR_JEOC and c1 & CR1_JEOCIE) or
                    (f & SR_AWD and c1 & CR1_AWDIE) or (f & SR_OVR and c1 & CR1_OVRIE))

    def _pend(self):
        m = self.m
        exc = 16 + IRQ
        if exc in m.pending or exc in m.active:
            return False
        if m.nvic is not None:
            m.nvic.irq(IRQ)
        else:
            m.set_pending(exc)
        return True

    def _irq_update(self):
        if self.m is None or not self._line():
            return
        self._pend()
        if not self._irq_armed:
            self._irq_arm(64)

    def _irq_arm(self, interval):
        self._irq_armed = True
        self._irq_gen += 1
        g = self._irq_gen
        self.m.schedule(interval, lambda: self._irq_beat(g, interval))

    def _irq_beat(self, g, interval):
        """Pend the exception again after a handler returned with a flag still set (level-sensitive line)."""
        if g != self._irq_gen:
            return
        self._irq_armed = False
        if not self._line():
            return
        self._irq_arm(64 if (16 + IRQ in self.m.active or self._pend()) else min(4096, interval * 2))

    # ------------------------------------------------------------------ registers
    def _sr_value(self):
        v = self.flags
        if self.ready:
            v |= SR_ADONS
        if self._not_ready('R'):
            v |= SR_RCNR
        if self._not_ready('J'):
            v |= SR_JCNR
        return v

    def _reg_read(self, reg):
        if reg == SR:
            return self._sr_value()
        if reg == CR1:
            return self.cr1
        if reg == CR2:
            return self.cr2
        if reg in self.smpr:
            return self.smpr[reg]
        if reg in JOFR:
            return self.jofr[JOFR.index(reg)]
        if reg == HTR:
            return self.htr
        if reg == LTR:
            return self.ltr
        if SQR1 <= reg <= SQR5:
            return self.sqr[(reg - SQR1) // 4]
        if reg == JSQR:
            return self.jsqr
        if reg in JDR:
            return self.jdr[JDR.index(reg)]
        if reg == DR:
            return self.dr
        if reg == CSR:
            return self._sr_value() & 0x7F                  # ADONS1 .. AWD1 are copies of SR bits 6:0 (12.15.19)
        return self.ccr                                     # CCR

    def _gated(self, off, rw):
        if not self._gate_logged:
            self._gate_logged = True
            self.m.log.append((self.m.cycles, f"{self.name} {rw} access at offset 0x{off:03X} with its clock disabled"))

    def read(self, off, size):
        reg = off & ~3
        if reg not in KNOWN:
            self.unmodelled(off, 'R')
            return 0
        if not self._clk_on():
            self._gated(off, 'R')
            return 0
        v = self._reg_read(reg)
        if reg == DR:
            self.flags &= ~SR_EOC                           # reading DR clears EOC and empties DR (12.15.1, 12.11.4)
            self.dr_valid = False
            self._pump()
        return self.extract(v, off, size)

    def write(self, off, value, size):
        reg = off & ~3
        if reg not in KNOWN:
            self.unmodelled(off, 'W')
            return
        if not self._clk_on():
            self._gated(off, 'W')
            return
        if reg in READ_ONLY:
            self._log_once(('ro', reg), f"{self.name} write to read-only register at offset 0x{reg:03X} ignored")
            return
        if reg == SR:
            # rc_w0 bits: a 0 clears the flag, a 1 leaves it; bytes that are not written leave the flags alone
            self._w_sr(self.merge(0xFFFFFFFF, off, value, size))
            return
        self._w_reg(reg, self.merge(self._reg_read(reg), off, value, size))

    def _w_sr(self, eff):
        clear = ~eff & SR_RC_W0
        was_ovr = bool(self.flags & SR_OVR)
        if clear & SR_EOC:
            self.dr_valid = False           # DR is emptied by clearing EOC too (12.11.4)
        self.flags &= ~clear
        if was_ovr and clear & SR_OVR:
            self._not_ready_pulse('R')      # RCNR is set after the OVR bit is cleared (12.15.1 RCNR)
        self._irq_update()
        self._pump()

    def _w_reg(self, reg, new):
        if reg == CR1:
            self._w_cr1(new)
        elif reg == CR2:
            self._w_cr2(new)
        elif reg in self.smpr:
            if self.on:
                self._log_once(('smpr', reg), f"{self.name} SMPRx written while ADON=1 (RM0038 12.15.4: write only when ADON=0)")
            self.smpr[reg] = new & (SMPR0_MASK if reg == SMPR0 else SMPR_MASK)
        elif reg in JOFR:
            self.jofr[JOFR.index(reg)] = new & 0xFFF
        elif reg == HTR:
            self.htr = new & 0xFFF
        elif reg == LTR:
            self.ltr = new & 0xFFF
        elif SQR1 <= reg <= SQR5:
            i = (reg - SQR1) // 4
            self.sqr[i] = new & (0x01FFFFFF if i == 0 else 0x3FFFFFFF)
            if i == 0 and ((new >> 20) & 0x1F) > 27:
                self.unmodelled(reg, 'W')   # L[4:0] above 11011 is reserved (12.15.10); the sequence is clamped to 28
            self._abort_regular()
            self._pump()
        elif reg == JSQR:
            self.jsqr = new & 0x003FFFFF
            self._abort_injected()
            self._pump()
        elif reg == CCR:
            old = self.ccr
            self.ccr = new & CCR_MASK
            if (self.ccr >> 16) & 3 == 3:
                self.unmodelled(CCR, 'W')   # ADCPRE = 11 is reserved (12.15.20); ADCCLK is then not running
            if old != self.ccr:
                self._resume()

    def _w_cr1(self, new):
        new &= CR1_MASK
        if self.on and (new ^ self.cr1) & CR1_ON_ONLY:
            self._log_once('cr1on', f"{self.name} CR1 RES/PDI/PDD/DISCNUM/DISC/JAUTO/SCAN changed while ADON=1 "
                                    f"(RM0038 12.15.2: write only when ADON=0)")
        self.cr1 = new
        if new & CR1_JAUTO and new & (CR1_DISCEN | CR1_JDISCEN):
            self.unmodelled(CR1, 'W')       # auto-injected and discontinuous mode together (12.3.9, 12.3.10)
        if new & CR1_DISCEN and new & CR1_JDISCEN:
            self.unmodelled(CR1, 'W')       # discontinuous mode on both groups (12.3.10)
        self._irq_update()
        self._pump()

    def _w_cr2(self, new):
        new &= CR2_MASK
        old = self.cr2
        sw_r = bool(new & CR2_SWSTART) and not old & CR2_SWSTART
        sw_j = bool(new & CR2_JSWSTART) and not old & CR2_JSWSTART
        keep = new & ~(CR2_SWSTART | CR2_JSWSTART)
        if self.on and (keep ^ old) & CR2_DELS:
            self._log_once('dels', f"{self.name} DELS changed while ADON=1 (RM0038 12.15.3: write only when ADON=0)")
        if keep & CR2_DMA and not old & CR2_DMA:
            self.dma_blocked = False        # DMA written 0 then 1 re-arms the requests (12.11.1)
            if self.dma_request is None:
                self.unmodelled(CR2, 'W')   # DMA requests need a controller model
        self.cr2 = (old & (CR2_SWSTART | CR2_JSWSTART)) | keep
        if keep & CR2_ADON and not self.on:
            self.on = True
            if self.ready:
                self._gen += 1              # ADON set again before ADONS fell: cancel the pending ADONS fall
            else:
                self._power_up()
        elif not keep & CR2_ADON and self.on:
            self._power_down()
        if self.on:
            if sw_r:
                self.cr2 |= CR2_SWSTART
                self.sw_r = True
            if sw_j:
                self.cr2 |= CR2_JSWSTART
                self.sw_j = True
        self._kick()
        self._pump()
