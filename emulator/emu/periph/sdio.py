"""STM32L152 SDIO host (RM0038 chapter 29, Cat.4) with the SD card bus of the 121GW board; instance at 0x4001 2C00, NVIC IRQ 45.

    SDIO(0x40012C00, 45)

Board (schematic 121GW_circuit_diagram.pdf, connector CN4 PJS008U-3000-0 "Micro SD Card"): SD_CMD = PD2 (pin 3, 47 kOhm pull-up),
SD_CLK = PC12 (pin 5), SD_D0 = PC8 (pin 7, 47 kOhm pull-up); pins 1, 2 and 8 (DAT3, DAT2, DAT1) go to test points only; there is
no card-detect or write-protect contact and the card supply is VDD_P without a switch.  The firmware selects the pins with
AF12 (sdio_gpio_init at 0x08023D56) and keeps the bus 1 bit wide (sd_set_bus_width(0) at 0x08022ECE).  The model does not look
at the GPIO configuration: a card that is inserted answers whenever the SDIO is configured.

Registers (RM0038 29.9, register map table 194), 32-bit registers, offsets from the block base:
    0x00 SDIO_POWER (29.9.1)   0x04 SDIO_CLKCR (29.9.2)   0x08 SDIO_ARG (29.9.3)   0x0C SDIO_CMD (29.9.4)
    0x10 SDIO_RESPCMD (29.9.5) 0x14..0x20 SDIO_RESP1..4 (29.9.6)   0x24 SDIO_DTIMER (29.9.7)   0x28 SDIO_DLEN (29.9.8)
    0x2C SDIO_DCTRL (29.9.9)   0x30 SDIO_DCOUNT (29.9.10)  0x34 SDIO_STA (29.9.11)   0x38 SDIO_ICR (29.9.12)
    0x3C SDIO_MASK (29.9.13)   0x48 SDIO_FIFOCNT (29.9.14) 0x80..0xFC SDIO_FIFO (29.9.15, 32 sequential addresses)
Offsets 0x40, 0x44 and 0x4C..0x7C are reserved and go to unmodelled().  "The peripheral registers have to be accessed by words"
(29.9): a byte or halfword access is turned into a word access with the data replicated on the byte lanes, as the AHB/APB bridge
does (RM0038 11.3.4 "Addressing an AHB peripheral that does not support byte or halfword write operations"); the first one is
logged.  Clock gate RCC_APB2ENR.SDIOEN: while it is off reads return 0 and writes are ignored (RM0038 6.3.10 note), first access
logged.  RCC_APB2RSTR.SDIORST resets the block (rcc.reset_hooks['SDIO']).

SDIO clock (6.2.4): SDIOCLK = PLL VCO / 2, supplied by rcc.sdioclk_hz (0 while the PLL is not locked: then SDIO_CK cannot run and
commands wait).  SDIO_CK = SDIOCLK / (CLKDIV + 2), or SDIOCLK with BYPASS (29.9.2).  SDIO_CK runs only while POWER = 11b and
CLKEN = 1 (29.3.1 control unit: "inactive after reset, during the power-off or power-up phases").  Not modelled: PWRSAV and
NEGEDGE (no timing effect at this level), the 3 SDIOCLK + 2 PCLK2 write latency of POWER / CLKCR / CMD / DCTRL, the 7 HCLK
minimum between two POWER writes, and the PCLK2 >= 3/8 SDIO_CK rule (logged once when it is violated).

Command path (29.3.1 command path, figure 285 / 286, table 164-167): a write to SDIO_CMD with CPSMEN = 1 starts the command: 48
SDIO_CK clocks of command token (CMDACT = 1 from here), no response expected (WAITRESP 00 / 10): CMDSENT; response expected
(01 short, 11 long): the CPSM waits at most 64 clocks (fixed command timeout) for the response start bit: CTIMEOUT (a card
that answers late, or no card, gives this), else the 48 / 136 clock response is received and CMDREND (CRC7 matches) or
CCRCFAIL is set; RESPCMD and RESPx are loaded (also when the CRC fails: R3 has no CRC, its CRC field is 1111111, so CCRCFAIL is the
normal outcome and the driver ignores it, 29.3.1).  The CPSM then stays idle for at least 8 clocks (NCC / NRC).  A write to CMD
while the CPSM is busy is ignored (RM0038 does not define it, logged).  ATACMD, nIEN, ENCMDcompl, SDIOSuspend, WAITINT are
not modelled (reported); WAITPEND waits until the DPSM is idle.

Data path (29.3.1 data path, figure 288, table 168-170, 29.9.9): a write to SDIO_DCTRL with DTEN = 1 while the DPSM is idle loads
DCOUNT = DLEN and FIFOCNT, clears the FIFO and enters Wait_R (DTDIR = 1) or Wait_S (DTDIR = 0); a write with DTEN = 0 aborts.
 Receive: the DPSM waits for the start bit at most DTIMER SDIO_CK clocks (DTIMEOUT), receives the block as 32-bit words
 (first byte in bits 7:0), compares the received CRC16 with its own (DBCKEND, or DCRCFAIL and idle), repeats Wait_R for the next
 block and, when DCOUNT = 0, goes idle and sets DATAEND.  FIFO overrun: RXOVERR and idle.  Hardware flow control (CLKCR.HWFC_EN, 29.8:
 SDIO_CK stops while the FIFO cannot take / supply data) is not modelled (reported); overrun and underrun then happen as without it.
 Send: Wait_S waits for data in the FIFO (at least 2 clocks, NWR), Send transmits start bit, data, CRC16, end bit, TXUNDERR and idle
 if the FIFO runs empty, then Busy waits for the CRC status token (positive: DBCKEND, else DCRCFAIL and idle) and for the card's
 busy signal (data timer: DTIMEOUT), then Wait_S for the next block or, when DCOUNT = 0, idle with DATAEND.
 STA.RXACT = Receive, TXACT = Send or Busy, CMDACT = CPSM not idle.  FIFO flags follow tables 169 / 170 while the FIFO is in use;
 all FIFO flags read 0 before the first transfer.  Words left in the receive FIFO stay readable after the DPSM went idle (the polled
 drivers read them after DATAEND); the next DCTRL start clears them.  RM0038 29.3.1 says the DPSM leaves Wait_R only when the
 receive FIFO is empty; the model does not wait for that (unproven which of the two silicon does).
 One bit time = one SDIO_CK; with the 1-bit bus a word takes 32 clocks (a block: 1 + 4096 + 16 + 1 clocks).  The board wires DAT0
 only, so WIDBUS != 0 (or a card in 4-bit mode) cannot work: a read gets STBITERR (29.9.11), a write the card's CRC error token.
 Start bit error: RM0038 29.3.1 (Wait_R) says the DPSM then sets "the timeout status flag", while 29.9.11 defines STBITERR for exactly
 this case; the model sets STBITERR.
 Stream mode (DTMODE = 1) and SD I/O operations (SDIOEN, RWSTART...) are not modelled (reported).
Interrupt: IRQ = (STA & MASK) != 0, level (29.3.2).  DMA: the request line to DMA2 channel 4 (RM0038 table 56) is DMAEN & (RX FIFO
holds >= 8 words (RXFIFOHF) | TX FIFO has >= 8 free words (TXFIFOHE)), the flags 29.3.1 names as DMA requests.  The L1 DMA has no
peripheral flow control and moves one word per request, so a request that is only RXFIFOHF would leave the last 7 words of every
512 byte block in the FIFO; the model therefore also requests while the receive FIFO is not empty and no data is being shifted in
(DPSM not in Receive).  RM0038 does not say how silicon requests that tail (unproven).

Firmware use (EEVBlog2_05, listing analysis/decompile/EEVBlog2_05_listing.asm; the decompiled C is not reliable here, e.g. it hides the
state returned by FUN_080226AC): a StdPeriph style SD driver below a FatFs.  SD_Init FUN_080225D8: sdio_gpio_init, SDIORST pulse
(FUN_08024074), power on FUN_080226E6 (CLKCR 0x76 = 200 kHz at SDIOCLK 24 MHz, POWER 3, CLKEN, CMD0, CMD8 0x1AA, CMD55 + ACMD41 with
0x80100000 | HCS until OCR bit 31, 0xFFFF tries), FUN_08022942 (CMD2, CMD3, CMD9), CLKDIV 1 (8 MHz), CMD7, FindSCR FUN_08023A8C
(CMD16 8, CMD55, ACMD51; the FIFO is read by polling, the loop ends at STA & 0x62A), ACMD6 with 0 (1 bit).  Block read FUN_08022FCE:
CMD16 512, DataConfig (DTIMER 0xFFFFFFFF, 512 bytes, block size 9, card to host, DPSM on) before CMD17, then MASK 0x32A, DMAEN and
DMA2 channel 4 (FUN_08023E58); no wait function, the caller polls CMD13 until the state field is 4 (tran).  Block write FUN_08023100:
CMD16, CMD55 + ACMD23 (1 block), CMD25, DataConfig (host to card), MASK 0x32A, DMAEN, DMA2 channel 4 (FUN_08023DE8), then FUN_080232E0
waits (1000 iterations each) for the DMA TC interrupt / SDIO IRQ flags, then for STA.TXACT = 0, sends CMD12 and polls CMD13.
SDIO IRQ 45 (FUN_08023476) converts STA flags into error codes and clears them; DMA2 channel 4 IRQ 53 (FUN_08023524) sets a flag.
sdio_gpio_deinit (0x08023CD8) writes SDIO_CLKCR.CLKEN and SDIO_POWER before it switches SDIOEN off; its very first call after a reset
finds SDIOEN = 0, so those writes are ignored (gate) and the first one is logged.

Card side: see sdcard.py.  card = None means no card (lines pulled up by R162 / R163: no response, no data).
"""
from collections import deque

from .base import Periph
from .irqline import LevelIrq
from ..sdcard import crc7, crc16, TOKEN_OK, DATA, RCV

SDIO_SIZE = 0x400
POWER, CLKCR, ARG, CMD, RESPCMD, RESP1, RESP2, RESP3, RESP4 = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20
DTIMER, DLEN, DCTRL, DCOUNT, STA, ICR, MASK, FIFOCNT, FIFO = 0x24, 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x48, 0x80
FIFO_END = 0x100

# SDIO_CLKCR (29.9.2)
CLKEN, PWRSAV, BYPASS, NEGEDGE, HWFC_EN = 1 << 8, 1 << 9, 1 << 10, 1 << 13, 1 << 14
CLKCR_MASK = 0x7FFF
# SDIO_CMD (29.9.4)
WAITINT, WAITPEND, CPSMEN, SDIOSUSPEND, ENCMDCOMPL, NIEN, ATACMD = 1 << 8, 1 << 9, 1 << 10, 1 << 11, 1 << 12, 1 << 13, 1 << 14
CMD_MASK = 0x7FFF
WIDBUS_MASK = 0x1800              # CLKCR bits 12:11
# SDIO_DCTRL (29.9.9)
DTEN, DTDIR, DTMODE, DMAEN = 1, 2, 4, 8
SDIOEN_BIT, RWMOD, RWSTOP, RWSTART = 1 << 11, 1 << 10, 1 << 9, 1 << 8
DCTRL_MASK = 0xFFF
DLEN_MASK = 0x1FFFFFF
# SDIO_STA (29.9.11)
CCRCFAIL, DCRCFAIL, CTIMEOUT, DTIMEOUT, TXUNDERR, RXOVERR, CMDREND, CMDSENT, DATAEND, STBITERR, DBCKEND = (1 << i for i in
                                                                                                          (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
CMDACT, TXACT, RXACT, TXFIFOHE, RXFIFOHF, TXFIFOF, RXFIFOF, TXFIFOE, RXFIFOE, TXDAVL, RXDAVL, SDIOIT, CEATAEND = (
    1 << 11, 1 << 12, 1 << 13, 1 << 14, 1 << 15, 1 << 16, 1 << 17, 1 << 18, 1 << 19, 1 << 20, 1 << 21, 1 << 22, 1 << 23)
STATIC_MASK = 0x00C007FF          # static flags: bits 23:22 and 10:0 (29.9.11)
MASK_MASK = 0x00FFFFFF

FIFO_WORDS = 32
NCC_CLOCKS = 8                    # CPSM idle time after a command (29.3.1)
CMD_TIMEOUT_CLOCKS = 64           # fixed command timeout (29.3.1, 29.9.11 bit 2)
NWR_CLOCKS = 2                    # Wait_S minimum (29.3.1 note)
POLL_CYCLES = 2000                # recheck interval while a start waits for SDIO_CK (PLL lock is asynchronous)


class _Tl:
    """Absolute time line of one bus process in core cycles: durations given in SDIO_CK clocks are added to a running float
    time, so rounding and late event delivery do not accumulate; a change of the clocks applies from the next step on."""

    def __init__(self, sd):
        self.sd = sd
        self.t = float(sd.m.cycles)

    def adv(self, clocks):
        self.t += clocks * self.sd._cpc()
        return self.t

    def after(self, clocks, cb):
        self.sd._sched_at(self.adv(clocks), cb)


class SDIO(Periph):
    SIZE = SDIO_SIZE

    def __init__(self, base=0x40012C00, irq=45, name="SDIO", sdioclk_hz=None):
        """sdioclk_hz: fixed SDIOCLK for use without an RCC model (otherwise rcc.sdioclk_hz is read)."""
        super().__init__()
        self.base = base
        self.name = name
        self.irq = irq
        self.fixed_sdioclk = sdioclk_hz
        self.card = None
        self.dma_poke = None            # callable run when the DMA request level may have changed
        self.trace = False              # log every command (index, argument, response)
        self._irq = LevelIrq(self, irq, self._irq_line)
        self._noted = set()
        self._gen = 0                   # bumped by reset(): voids the host side events (command / data path)
        self._card_gen = 0              # bumped when the card is inserted or removed: voids the card side events
        self._rxs_gen = 0               # identity of the card -> host read stream (new read command, CMD12, card change)
        self.reset()

    # ------------------------------------------------------------------ reset / card
    def reset(self):
        """Power-on or SDIORST: every register to its reset value (all 0), both state machines idle, FIFO empty."""
        self._gen += 1                  # voids every scheduled event of the previous life
        self.power = 0
        self.clkcr = 0
        self.arg = 0
        self.cmd = 0
        self.respcmd = 0
        self.resp = [0, 0, 0, 0]
        self.dtimer = 0
        self.dlen = 0
        self.dctrl = 0
        self.dcount = 0
        self.fifocnt = 0
        self.mask = 0
        self.sta = 0
        self.fifo = deque()
        self.fifo_dir = None            # None: FIFO unused, flags 0 | 'rx' | 'tx'
        self.cpsm = 'idle'              # idle | pend | send | wait | recv (recv is folded into wait: response in progress)
        self.dpsm = 'idle'              # idle | wait_r | recv | wait_s | send | busy
        self._cpsm_free_at = 0.0
        self._tx_pending = False
        self._tx_polling = False
        self._cmd_token = None
        self._tid = getattr(self, '_tid', 0) + 1    # identity of the running data transfer: voids the timers of older ones
        self._irq.reset()
        if self.m is not None:
            self._changed()

    def set_card(self, card):
        """Insert (card object) or remove (None) the card; a newly inserted card powers up in idle state."""
        was = self.card
        self.card = card
        self._rxs_gen += 1
        self._card_gen += 1
        if card is not None:
            card.power_up()
        if self.m is not None and (card is not None or was is not None):
            self.m.log.append((self.m.cycles, "SDIO: card " + ("inserted" if card is not None else "removed")))

    def _note(self, key, text):
        if key not in self._noted:
            self._noted.add(key)
            self.m.log.append((self.m.cycles, f"SDIO: {text}"))

    # ------------------------------------------------------------------ clocks and time
    def _sdioclk(self):
        if self.fixed_sdioclk is not None:
            return self.fixed_sdioclk
        rcc = getattr(self.m, "rcc", None)
        return 48_000_000 if rcc is None else rcc.sdioclk_hz

    def _ck_hz(self):
        clk = self._sdioclk()
        if not clk:
            return 0
        return clk if self.clkcr & BYPASS else clk / ((self.clkcr & 0xFF) + 2)

    def _ck_running(self):
        return self.power == 3 and bool(self.clkcr & CLKEN) and self._ck_hz() > 0

    def _cpc(self):
        """Core cycles per SDIO_CK clock.  Used for timers also while the clock is stopped (then 400 kHz is assumed)."""
        ck = self._ck_hz() or 400_000
        return self.m.sysclk_hz / ck

    def _us(self, us):
        return us * self.m.sysclk_hz / 1_000_000

    def _sched_at(self, due, cb, gen=None, card=False):
        """Run cb at core cycle `due`.  Host side events die with reset() (SDIORST); card side events (card=True: the card's
        own timers and its data stream, which a host reset does not stop) die when the card is replaced."""
        g = (self._card_gen if card else self._gen) if gen is None else gen

        def run():
            if g == (self._card_gen if card else self._gen):
                cb()
        self.m.schedule(max(1, int(round(due - self.m.cycles))), run)

    # ------------------------------------------------------------------ status, interrupt, DMA request
    def _fifo_flags(self):
        n = len(self.fifo)
        v = 0
        if self.fifo_dir == 'rx':
            v |= RXDAVL if n else RXFIFOE
            if n >= FIFO_WORDS:
                v |= RXFIFOF
            if n >= 8:
                v |= RXFIFOHF
        elif self.fifo_dir == 'tx':
            v |= TXDAVL if n else TXFIFOE
            if n >= FIFO_WORDS:
                v |= TXFIFOF
            if FIFO_WORDS - n >= 8:
                v |= TXFIFOHE
        return v

    def _sta(self):
        v = self.sta & STATIC_MASK
        if self.cpsm != 'idle':
            v |= CMDACT
        if self.dpsm in ('send', 'busy'):
            v |= TXACT
        elif self.dpsm == 'recv':
            v |= RXACT
        return v | self._fifo_flags()

    def _irq_line(self):
        return bool(self._sta() & self.mask)

    def dma_request(self):
        if not self.dctrl & DMAEN:
            return False
        if self.fifo_dir == 'rx':
            n = len(self.fifo)
            return n >= 8 or (n > 0 and self.dpsm != 'recv')    # RXFIFOHF, or the tail once no data is being shifted in
        if self.fifo_dir == 'tx':
            return FIFO_WORDS - len(self.fifo) >= 8 and self.fifocnt > 0
        return False

    def _changed(self):
        """State, flags or enables changed: update the interrupt line and the DMA request."""
        self._irq.update()
        if self.dma_poke is not None and self.dma_request():
            self.dma_poke()

    # ------------------------------------------------------------------ registers
    def _clk_on(self):
        rcc = getattr(self.m, "rcc", None)
        return True if rcc is None else rcc.clock_enabled('SDIO')

    def _fifo_read(self):
        if self.fifo_dir == 'rx' and self.fifo:
            w = self.fifo.popleft()
            if self.fifocnt:
                self.fifocnt -= 1
            self._changed()
            return w
        self._note('fifo_rd', "read of the data FIFO while it holds no receive data (RM0038 gives no value, returns 0)")
        return 0

    def _fifo_write(self, w):
        if self.fifo_dir != 'tx':
            self._note('fifo_wr', "write to the data FIFO while no transmit transfer is enabled (data dropped, RM0038 29.3.1: "
                                  "transmit FIFO disabled)")
            return
        if len(self.fifo) >= FIFO_WORDS:
            self._note('fifo_full', "write to a full transmit FIFO (word dropped; RM0038 defines no overflow flag)")
            return
        self.fifo.append(w & 0xFFFFFFFF)
        if self.fifocnt:
            self.fifocnt -= 1
        self._changed()
        if self.dpsm == 'wait_s':
            self._tx_try_start()

    def _reg_read(self, reg):
        if reg == POWER:
            return self.power
        if reg == CLKCR:
            return self.clkcr
        if reg == ARG:
            return self.arg
        if reg == CMD:
            return self.cmd
        if reg == RESPCMD:
            return self.respcmd
        if RESP1 <= reg <= RESP4:
            return self.resp[(reg - RESP1) >> 2]
        if reg == DTIMER:
            return self.dtimer
        if reg == DLEN:
            return self.dlen
        if reg == DCTRL:
            return self.dctrl
        if reg == DCOUNT:
            return self.dcount
        if reg == STA:
            return self._sta()
        if reg == ICR:
            return 0                                        # write only (29.9.12)
        if reg == MASK:
            return self.mask
        if reg == FIFOCNT:
            return self.fifocnt
        if FIFO <= reg < FIFO_END:
            return None                                     # side effect: handled in read()
        return None

    def read(self, off, size):
        if not self._clk_on():
            self._note('gate', "access while RCC_APB2ENR.SDIOEN = 0 (reads give 0, writes are ignored, RM0038 6.3.10 note)")
            return 0
        reg = off & ~3
        if FIFO <= reg < FIFO_END:
            return self.extract(self._fifo_read(), off, size)
        val = self._reg_read(reg)
        if val is None:
            self.unmodelled(off, 'R')
            return 0
        if size < 4:
            self._note('subword', "byte / halfword access: the registers have to be accessed by words (RM0038 29.9)")
        return self.extract(val, off, size)

    def write(self, off, value, size):
        if not self._clk_on():
            self._note('gate', "access while RCC_APB2ENR.SDIOEN = 0 (reads give 0, writes are ignored, RM0038 6.3.10 note)")
            return
        if size < 4:
            self._note('subword', "byte / halfword access: the registers have to be accessed by words (RM0038 29.9)")
            value &= (1 << (8 * size)) - 1
            value = int.from_bytes(value.to_bytes(size, 'little') * (4 // size), 'little')   # lane replication (11.3.4)
        reg = off & ~3
        if FIFO <= reg < FIFO_END:
            self._fifo_write(value)
        elif reg == POWER:
            self._w_power(value & 3)
        elif reg == CLKCR:
            self._w_clkcr(value & CLKCR_MASK)
        elif reg == ARG:
            self.arg = value & 0xFFFFFFFF
        elif reg == CMD:
            self._w_cmd(value & CMD_MASK)
        elif reg == DTIMER:
            self.dtimer = value & 0xFFFFFFFF
        elif reg == DLEN:
            self.dlen = value & DLEN_MASK
        elif reg == DCTRL:
            self._w_dctrl(value & DCTRL_MASK)
        elif reg == ICR:
            self.sta &= ~(value & STATIC_MASK)
            self._changed()
        elif reg == MASK:
            self.mask = value & MASK_MASK
            self._changed()
        elif reg in (RESPCMD, RESP1, RESP2, RESP3, RESP4, DCOUNT, STA, FIFOCNT):
            pass                                            # read-only registers (29.9.5, 29.9.6, 29.9.10, 29.9.11, 29.9.14)
        else:
            self.unmodelled(off, 'W')

    def _w_power(self, v):
        old, self.power = self.power, v
        if v != old:
            self.m.log.append((self.m.cycles, f"SDIO: POWER = {v:02b}"))
        if v == 1:
            self._note('pwr01', "POWER = 01b is reserved (29.9.1)")
        self._wake()
        self._changed()

    def _w_clkcr(self, v):
        old, self.clkcr = self.clkcr, v
        if (v ^ old) & (CLKEN | BYPASS | 0xFF):
            ck = self._ck_hz()
            self.m.log.append((self.m.cycles, f"SDIO: CLKCR = 0x{v:04X} (SDIO_CK {ck / 1000:.1f} kHz from SDIOCLK "
                                              f"{self._sdioclk() / 1e6:.1f} MHz, CLKEN {v >> 8 & 1})"))
            rcc = getattr(self.m, "rcc", None)
            if ck and rcc is not None and rcc.pclk2_hz * 8 < 3 * ck:
                self._note('pclk2', f"PCLK2 {rcc.pclk2_hz} Hz is below 3/8 of SDIO_CK {ck:.0f} Hz (29.2 requirement)")
        if v & WIDBUS_MASK:
            self._note('widbus', "WIDBUS != 0: the board wires DAT0 only (schematic CN4), wide transfers will fail")
        if v & HWFC_EN:
            self.unmodelled(CLKCR, 'W')
            self._note('hwfc', "CLKCR.HWFC_EN (hardware flow control, 29.8) is not modelled")
        self._wake()
        self._changed()

    def _wake(self):
        """POWER / CLKCR changed: a command or data start that waits for SDIO_CK re-checks at once."""
        if self.cpsm == 'pend':
            self._cmd_wait()
        if self.dpsm == 'wait_s':
            self._tx_try_start()

    # ------------------------------------------------------------------ command path
    def _w_cmd(self, v):
        self.cmd = v
        if not v & CPSMEN:
            return
        if self.cpsm != 'idle':
            self._note('cmd_busy', "SDIO_CMD written while the command path is busy (RM0038 does not define it): write ignored")
            return
        for bit, name in ((WAITINT, 'WAITINT'), (SDIOSUSPEND, 'SDIOSuspend'), (ENCMDCOMPL, 'ENCMDcompl'),
                          (ATACMD, 'ATACMD'), (NIEN, 'nIEN')):
            if v & bit and name not in self._noted:
                self.unmodelled(CMD, 'W')
                self._note(name, f"SDIO_CMD.{name} is not modelled")
        self.cpsm = 'pend'
        self._changed()
        self._cmd_wait()

    def _cmd_wait(self):
        """(Re)start the wait for the conditions under which the command can be sent; an older wait chain dies."""
        self._cmd_token = tok = object()
        self._cmd_try(tok)

    def _cmd_try(self, tok):
        """Start sending once SDIO_CK runs, the NCC idle time is over and (WAITPEND) the data path is idle."""
        if tok is not self._cmd_token or self.cpsm != 'pend':
            return
        now = self.m.cycles
        if not self._ck_running():                          # woken by POWER / CLKCR writes; the PLL lock is asynchronous
            self._sched_at(now + POLL_CYCLES, lambda: self._cmd_try(tok))
            return
        if now < self._cpsm_free_at:
            self._sched_at(self._cpsm_free_at, lambda: self._cmd_try(tok))
            return
        if self.cmd & WAITPEND and self.dpsm != 'idle':
            self._sched_at(now + POLL_CYCLES, lambda: self._cmd_try(tok))
            return
        self.cpsm = 'send'
        self._cur = (self.cmd & 0x3F, self.arg, (self.cmd >> 6) & 3)    # the token that is sent is fixed from here on
        tl = _Tl(self)
        tl.after(48, lambda: self._cmd_sent(tl))
        self._changed()

    def _cpsm_end(self, tl):
        self.cpsm = 'idle'
        self._cpsm_free_at = tl.t + NCC_CLOCKS * self._cpc()
        self._changed()

    def _card_log(self):
        card = self.card                                    # the socket can be emptied (set_card(None)) at any time
        if card is None:
            return
        for t in card.log:
            self.m.log.append((self.m.cycles, f"SD card: {t}"))
        card.log.clear()

    def _cmd_sent(self, tl):
        idx, arg, wr = self._cur
        reply = None
        if self.card is not None:
            reply = self.card.command(idx, arg, True)
            self._card_log()
            if reply is not None:
                self._reply_effects(reply)
        if self.trace:
            self.m.log.append((self.m.cycles, f"SDIO: CMD{idx} arg 0x{arg:08X} -> "
                                              f"{'no response' if reply is None else f'0x{reply.frame:012X}'}"))
        if wr in (0, 2):                                    # no response expected: CMDSENT
            self.sta |= CMDSENT
            self._cpsm_end(tl)
            if reply is not None:
                self._after_response(reply, self._resp_end(tl, reply))
            return
        self.cpsm = 'wait'
        self._changed()
        if reply is None:
            tl.after(CMD_TIMEOUT_CLOCKS, lambda: self._cmd_timeout(tl))
            return
        rt = _Tl(self)
        rt.t = tl.t
        rt.after(self.card.ncr_clocks + reply.nbits, lambda: self._resp_done(tl, rt, reply, wr == 3))

    def _resp_end(self, tl, reply):
        return tl.t + (self.card.ncr_clocks + reply.nbits) * self._cpc()

    def _cmd_timeout(self, tl):
        self.sta |= CTIMEOUT
        self._cpsm_end(tl)

    def _resp_done(self, tl, rt, reply, expect_long):
        """Response received completely (rt.t is its end)."""
        f = reply.frame
        long_resp = reply.nbits == 136
        ok = True
        if long_resp != expect_long:
            ok = False                                      # RM0038 does not define a length mismatch; reported as a CRC failure
            self._note('resplen', "response length differs from the WAITRESP setting of the command (RM0038 does not define it); "
                                  "CCRCFAIL is reported")
        if long_resp:
            self.respcmd = (f >> 128) & 0x3F
            self.resp = [(f >> 96) & 0xFFFFFFFF, (f >> 64) & 0xFFFFFFFF, (f >> 32) & 0xFFFFFFFF, f & 0xFFFFFFFE]
            ok = ok and crc7((f >> 8) & ((1 << 120) - 1), 120) == (f >> 1) & 0x7F
        else:
            self.respcmd = (f >> 40) & 0x3F
            self.resp[0] = (f >> 8) & 0xFFFFFFFF
            ok = ok and crc7(f >> 8, 40) == (f >> 1) & 0x7F
        self.sta |= CMDREND if ok else CCRCFAIL
        self._cpsm_end(rt)
        self._after_response(reply, rt.t)

    def _reply_effects(self, reply):
        """Card-side timers that start with a response: initialisation (ACMD41) and busy (CMD38)."""
        g = self.card.init_pending()
        card = self.card
        if g is not None:
            self._sched_at(self.m.cycles + self._us(card.init_us), lambda: card.init_complete(g), card=True)
        if reply.stop_data:
            self._rxs_gen += 1
        if reply.busy_us:
            pid = reply.prog_id
            self._sched_at(self.m.cycles + self._us(reply.busy_us), lambda: card.program_done(pid), card=True)

    def _after_response(self, reply, t_end):
        """Start the data phase the command announced (read plan: the card sends after its latency)."""
        if reply.read is not None and self.card is not None:
            self._rxs_gen += 1
            sess = (self._rxs_gen, self.card, reply.read)
            start = t_end + self._us(reply.read.latency_us) + reply.read.latency_clocks * self._cpc()
            self._sched_at(start, lambda: self._rx_begin(sess, start), card=True)

    # ------------------------------------------------------------------ data path: start / abort
    def _block_bytes(self):
        return 1 << ((self.dctrl >> 4) & 0xF)

    def _w_dctrl(self, v):
        self.dctrl = v
        if v & DTEN:
            if self.dpsm == 'idle':
                self._dpsm_start()
        elif self.dpsm != 'idle':                           # disabled: back to Idle (figure 288), FIFO disabled
            self.dpsm = 'idle'
            self._tx_pending = False
            self._tid += 1
            self.fifo.clear()
            self.fifo_dir = None
        self._changed()

    def _dpsm_start(self):
        v = self.dctrl
        if v & SDIOEN_BIT:
            self.unmodelled(DCTRL, 'W')
            self._note('sdioen', "DCTRL.SDIOEN (SD I/O operations, RWSTART / RWSTOP / RWMOD) is not modelled")
        if v & DTMODE:
            self.unmodelled(DCTRL, 'W')
            self._note('stream', "DCTRL.DTMODE = 1 (stream / SDIO multibyte transfer) is not modelled: SD memory cards use block mode")
        if (v >> 4) & 0xF == 15:
            self._note('blk15', "DCTRL.DBLOCKSIZE = 15 is reserved (29.9.9): transfer not started")
            return
        self._tid += 1                                      # identity of this transfer: voids timers of earlier ones
        self.dcount = self.dlen
        self.fifocnt = (self.dlen + 3) // 4
        self.fifo.clear()
        self.fifo_dir = 'rx' if v & DTDIR else 'tx'
        if self.dlen % self._block_bytes():
            self._note('blkmul', "DLEN is not a multiple of the block size (29.9.8 requires it); the last block is short")
        if self.dlen == 0:
            self.sta |= DATAEND                             # Wait_R / Wait_S with a zero counter go Idle (29.3.1)
            return
        if v & DTDIR:
            self.dpsm = 'wait_r'
            self._timer_start('wait_r')
        else:
            self.dpsm = 'wait_s'
            self._tx_try_start()

    def _timer_start(self, state):
        """Data timer (29.9.7): DTIMER SDIO_CK clocks in Wait_R or Busy."""
        tid = self._tid
        tl = _Tl(self)
        tl.after(self.dtimer, lambda: self._data_timeout(tid, state))

    def _data_timeout(self, tid, state):
        if tid == self._tid and self.dpsm == state:
            self.dpsm = 'idle'
            self._tx_pending = False
            self.sta |= DTIMEOUT
            self._changed()

    # ------------------------------------------------------------------ data path: card -> host
    def _rx_begin(self, sess, t0):
        """The card starts its read transfer (first start bit at t0)."""
        self._rx_block(sess, 0, t0)

    def _rx_valid(self, sess):
        gen, card, plan = sess
        return card is not None and gen == self._rxs_gen and self.card is card and card.state == DATA

    def _rx_block(self, sess, blk, t0):
        """The card starts block `blk` of its transfer: start bit at t0, then the data, CRC16 and the end bit.  The card side
        (block end, next block, end of transfer) runs on its own time line; the host side (FIFO, CRC check, flags) only takes
        part while the DPSM is waiting for data."""
        gen, card, plan = sess
        if not self._rx_valid(sess):
            return
        if plan.kind == 'reg':
            if blk >= 1:
                card.read_end()
                return
            payload = plan.register
        else:
            payload = card.read_block()
            if payload is None:                             # past the end of the card: the card waits for CMD12
                return
        crc = crc16(payload)
        if plan.kind != 'reg' and card.faults.get('read_crc', 0) > 0:    # test fault (emu/sdcard.py SDCard.faults)
            card.faults['read_crc'] -= 1
            crc ^= 0x0001
        stream = payload + crc.to_bytes(2, 'big')
        cpc = self._cpc()
        t_end = t0 + (1 + 8 * len(payload) + 16 + 1) * cpc
        self._sched_at(t_end, lambda: self._rx_block_end(sess, blk, t_end), card=True)
        if self.dpsm != 'wait_r':
            return                                          # nobody receives this block
        self._tid += 1                                      # start bit seen: the data timer stops
        tid = self._tid
        self.dpsm = 'recv'
        self._changed()
        tl = _Tl(self)
        tl.t = t0
        if self._bad_bus():                                 # DAT1..DAT3 are not connected: no start bit on all lines (29.9.11)
            tl.after(1, lambda: self._rx_stbit(tid))
            return
        nb = min(self._block_bytes(), self.dcount)
        tl.after(1, lambda: self._rx_word(tid, sess, tl, stream, nb, 0))

    def _bad_bus(self):
        return bool(self.clkcr & WIDBUS_MASK) or (self.card is not None and self.card.bus_width != 1)

    def _rx_stbit(self, tid):
        """No start bit on all data lines (29.9.11 STBITERR); see the note on the timeout flag in the module docstring."""
        if tid != self._tid or self.dpsm != 'recv':
            return
        self.sta |= STBITERR
        self.dpsm = 'idle'
        self._changed()

    def _rx_word(self, tid, sess, tl, stream, nb, j):
        """Word j (1-4 bytes) of the block has been shifted in completely at the current time."""
        if tid != self._tid or self.dpsm != 'recv':
            return                                          # aborted (DTEN = 0, SDIORST) or superseded
        nbytes = min(4, nb - 4 * j)
        if len(self.fifo) >= FIFO_WORDS:
            self.sta |= RXOVERR
            self.dpsm = 'idle'
            self._changed()
            return
        data = stream[4 * j:4 * j + nbytes]
        if self.card is not sess[1]:
            data = b''                                      # card removed: DAT0 is pulled high by R163
        self.fifo.append(int.from_bytes(data.ljust(nbytes, b'\xff'), 'little'))
        self.dcount -= nbytes
        self._changed()
        if 4 * (j + 1) < nb:
            tl.after(8 * min(4, nb - 4 * (j + 1)), lambda: self._rx_word(tid, sess, tl, stream, nb, j + 1))
        else:
            tl.after(16, lambda: self._rx_crc(tid, sess, stream, nb))

    def _rx_crc(self, tid, sess, stream, nb):
        if tid != self._tid or self.dpsm != 'recv':
            return
        got = stream[nb:nb + 2] if self.card is sess[1] else b'\xff\xff'
        if len(got) == 2 and crc16(stream[:nb]) == int.from_bytes(got, 'big'):
            self.sta |= DBCKEND
            if self.dcount == 0:
                self.sta |= DATAEND
                self.dpsm = 'idle'
            else:
                self.dpsm = 'wait_r'
                self._timer_start('wait_r')
        else:
            self.sta |= DCRCFAIL
            self.dpsm = 'idle'
        self._changed()

    def _rx_block_end(self, sess, blk, t_end):
        """End bit of the block on the card side: next block of a multiple read, or the transfer is over."""
        gen, card, plan = sess
        if not self._rx_valid(sess):
            return
        if plan.kind == 'mem' and card.multi:
            self._rx_block(sess, blk + 1, t_end)
        else:
            card.read_end()

    # ------------------------------------------------------------------ data path: host -> card
    def _tx_try_start(self):
        if self._tx_pending or self.dpsm != 'wait_s' or not self.fifo:
            return
        if not self._ck_running():                          # SDIO_CK stopped: the DPSM cannot move on
            if not self._tx_polling:
                self._tx_polling = True
                self._sched_at(self.m.cycles + POLL_CYCLES, self._tx_repoll)
            return
        self._tx_pending = True
        tid = self._tid
        tl = _Tl(self)
        tl.after(NWR_CLOCKS, lambda: self._tx_begin(tid))

    def _tx_repoll(self):
        self._tx_polling = False
        self._tx_try_start()

    def _tx_begin(self, tid):
        self._tx_pending = False
        if tid != self._tid or self.dpsm != 'wait_s':
            return
        self.dpsm = 'send'
        nb = min(self._block_bytes(), self.dcount)
        tl = _Tl(self)
        self._changed()
        buf = bytearray()
        tl.after(1, lambda: self._tx_word(tid, tl, buf, nb, 0))      # start bit, then the first word is taken from the FIFO

    def _tx_word(self, tid, tl, buf, nb, j):
        if tid != self._tid or self.dpsm != 'send':
            return
        if not self.fifo:
            self.sta |= TXUNDERR
            self.dpsm = 'idle'
            self._changed()
            return
        w = self.fifo.popleft()
        nbytes = min(4, nb - 4 * j)
        buf += w.to_bytes(4, 'little')[:nbytes]
        self.dcount -= nbytes
        self._changed()                                              # the DMA refills the FIFO (TXFIFOHE)
        if 4 * (j + 1) < nb:
            tl.after(8 * nbytes if nbytes < 4 else 32, lambda: self._tx_word(tid, tl, buf, nb, j + 1))
        else:
            tl.after(8 * nbytes + 16 + 1, lambda: self._tx_block_end(tid, tl, bytes(buf)))

    def _tx_block_end(self, tid, tl, data):
        """CRC16 and end bit have been sent: the card checks the block and returns the CRC status token."""
        if tid != self._tid or self.dpsm != 'send':
            return
        self.dpsm = 'busy'
        self._changed()
        card = self.card
        token = busy_us = None
        if card is not None and card.state == RCV and card.data_dir == 'w':
            if self._bad_bus():
                token, busy_us = card.write_block(b'', 0)           # DAT1..DAT3 not connected: the card sees a CRC error
            else:
                token, busy_us = card.write_block(data, crc16(data))
            self._card_log()
            if busy_us:
                pid = card.prog_id
                self._sched_at(self.m.cycles + self._us(busy_us), lambda: card.program_done(pid), card=True)
        if token is None:                                           # nobody answers: no CRC status token
            self._timer_start('busy')
            return
        tl.after(card.token_gap_clocks + 5, lambda: self._tx_token(tid, tl, token, busy_us))

    def _tx_token(self, tid, tl, token, busy_us):
        if tid != self._tid or self.dpsm != 'busy':
            return
        if token != TOKEN_OK:
            self.sta |= DCRCFAIL
            self.dpsm = 'idle'
            self._changed()
            return
        self.sta |= DBCKEND
        self._changed()
        busy_clocks = busy_us * (self._ck_hz() or 400_000) / 1e6
        if busy_clocks > self.dtimer:                               # the card stays busy longer than the data timer allows
            self._timer_start('busy')
        else:
            self._sched_at(self.m.cycles + self._us(busy_us), lambda: self._tx_busy_done(tid))

    def _tx_busy_done(self, tid):
        if tid != self._tid or self.dpsm != 'busy':
            return
        if self.dcount == 0:
            self.sta |= DATAEND
            self.dpsm = 'idle'
        else:
            self.dpsm = 'wait_s'
            self._tx_try_start()
        self._changed()

