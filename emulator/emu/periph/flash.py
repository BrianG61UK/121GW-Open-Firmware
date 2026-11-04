"""FLASH interface model for the STM32L152ZD (category 4 device), base 0x40023C00.

Covers the flash access control, the key sequences, program memory page erase / half page /
word programming, data EEPROM byte / half word / word / double word programming and erase,
and the option byte block.  Follows RM0038 chapter 3.  References use the section number and,
in brackets, the line of the RM0038 text conversion (rm0038.txt).

Machine integration
-------------------
* The model sets `machine.flash_ctl = self` when it is attached (Machine.add_periph).
* The machine routes every CPU store to non-volatile memory to `cpu_store(addr, value, size)`:
  the data EEPROM (0x08080000..0x08082FFF) already does; program flash (0x08000000..0x0805FFFF),
  the option bytes (0x1FF80000..) and system memory (0x1FF00000..) must be routed the same way,
  because those regions are read-only Unicorn memory.
* The data EEPROM contents live in `machine.eeprom`; program flash and the option bytes are
  written with `machine.uc.mem_write`.
* A wrong key sequence returns a bus error on the real device (rm0038.txt:3052).  The memory
  callback interface cannot raise a bus fault, so the event is written to the machine log and
  counted in `bus_errors`.
* While a program memory half page write runs, a read of the same bank (an instruction fetch or a
  data read) is a bus error (3.4.3 note 2, rm0038.txt:3230; banks Table 10: 0x08000000..0x0802FFFF
  and 0x08030000..0x0805FFFF).  Hooks on that bank are installed for the duration of the operation;
  a hit is logged, counted in `bus_errors` and stops the machine (stop reason "bus error ..."), so a
  program that would fault on the device cannot pass a test.
* `reset(power_on)` must be called by the machine on every system reset: it reloads the option
  bytes into FLASH_OBR / FLASH_WRPRx (3.5, rm0038.txt:3643) and re-locks everything.

Brick guard
-----------
Unless the constructor flag `allow_protected` is True, every write or erase that touches the
bootloader area 0x08000000-0x08005FFF, or the RDP / write-protection option words, is refused:
a line starting with "BRICK-GUARD" is written to the machine log, WRPERR is raised as if the
target were write protected, and no reset is requested.

Behaviour that RM0038 leaves open is listed in the "OPEN POINT" comments next to the code.
"""
from .base import Periph

# ------------------------------------------------------------------ memory map
FLASH_BASE, FLASH_SIZE = 0x08000000, 0x60000            # 384 Kbytes (Table 10, rm0038.txt:2686)
BOOT_END = 0x08006000                                   # bootloader area 0x08000000..0x08005FFF
EEPROM_BASE, EEPROM_SIZE = 0x08080000, 0x3000           # 12 Kbytes (Table 10, rm0038.txt:2716)
SYSMEM_BASE, SYSMEM_END = 0x1FF00000, 0x1FF80000        # system memory (Table 10, rm0038.txt:2724)
INFO_BASE, INFO_SIZE = 0x1FF80000, 0x1000               # option bytes + factory information
PAGE_SIZE = 256                                         # 3.2, rm0038.txt:2557
HALF_PAGE_SIZE = 128                                    # 32 words, 3.4.3, rm0038.txt:3204
SECTOR_SIZE = 4096                                      # write protection granularity, 3.2 / 3.7.2

# ------------------------------------------------------------------ keys (3.9.3 - 3.9.6)
PDKEY1, PDKEY2 = 0x04152637, 0xFAFBFCFD                 # rm0038.txt:4385
PEKEY1, PEKEY2 = 0x89ABCDEF, 0x02030405                 # rm0038.txt:4404
PRGKEY1, PRGKEY2 = 0x8C9DAEBF, 0x13141516               # rm0038.txt:4429
OPTKEY1, OPTKEY2 = 0xFBEAD9C8, 0x24252627               # rm0038.txt:4448

# ------------------------------------------------------------------ FLASH_ACR (3.9.1, rm0038.txt:4182)
ACR_LATENCY, ACR_PRFTEN, ACR_ACC64, ACR_SLEEP_PD, ACR_RUN_PD = 1, 2, 4, 8, 16

# ------------------------------------------------------------------ FLASH_PECR (3.9.2, rm0038.txt:4240)
PECR_PELOCK = 1 << 0
PECR_PRGLOCK = 1 << 1
PECR_OPTLOCK = 1 << 2
PECR_PROG = 1 << 3
PECR_DATA = 1 << 4
PECR_FTDW = 1 << 8
PECR_ERASE = 1 << 9
PECR_FPRG = 1 << 10
PECR_PARALLBANK = 1 << 15
PECR_EOPIE = 1 << 16
PECR_ERRIE = 1 << 17
PECR_OBL_LAUNCH = 1 << 18
PECR_RESET = 0x00000007
PECR_MODE_BITS = PECR_FPRG | PECR_ERASE | PECR_FTDW | PECR_DATA | PECR_PROG | PECR_PARALLBANK
PECR_CLEARED_BY_PELOCK = PECR_FPRG | PECR_ERASE | PECR_FTDW | PECR_DATA | PECR_PROG

# ------------------------------------------------------------------ FLASH_SR (3.9.7, rm0038.txt:4452)
SR_BSY, SR_EOP, SR_ENDHV, SR_READY = 1 << 0, 1 << 1, 1 << 2, 1 << 3
SR_WRPERR, SR_PGAERR, SR_SIZERR = 1 << 8, 1 << 9, 1 << 10
SR_OPTVERR, SR_OPTVERRUSR, SR_RDERR = 1 << 11, 1 << 12, 1 << 13
SR_W1C = SR_EOP | SR_WRPERR | SR_PGAERR | SR_SIZERR | SR_OPTVERR | SR_OPTVERRUSR | SR_RDERR
SR_RESET = SR_ENDHV                                     # reset value 0x00000004 (rm0038.txt:4454)

# Option words of a category 4 device (Table 18, rm0038.txt:3629).  WRP4 (0x80, 0x84) belongs to
# category 5 (Table 19 note 3, rm0038.txt:3772): it can be written, it is not loaded or verified.
OPT_USER_OFF = 0x04
OPT_GUARDED = {0x00, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x80, 0x84}      # RDP and write protection
OPT_WORDS = OPT_GUARDED | {OPT_USER_OFF}

# Modelling parameters.
TPROG_US_DEFAULT = 3280          # datasheet Table "Flash memory and data EEPROM characteristics": 3.28 ms typical
BUFFER_CLEAR_US_DEFAULT = 2      # BSY pulse after FPRG + PROG/DATA are set (3.4.3 says to wait; no duration given)
FLASH_WAKEUP_US_DEFAULT = 8      # delay until READY after leaving Flash power down (no duration given)

# Data-buffer loading sequences: kind -> (words, alignment in bytes)
SEQ_CFG = {
    'ee_dwrite': (2, 8),         # data EEPROM double word write (3.4.3, rm0038.txt:3251)
    'ee_derase': (2, 8),         # data EEPROM double word erase (3.4.2, rm0038.txt:3142)
    'prog_hp': (32, HALF_PAGE_SIZE),     # program memory half page write (3.4.3, rm0038.txt:3203)
}


class FLASH(Periph):
    name = "FLASH"
    base = 0x40023C00

    def __init__(self, allow_protected=False, tprog_us=TPROG_US_DEFAULT,
                 buffer_clear_us=BUFFER_CLEAR_US_DEFAULT, flash_wakeup_us=FLASH_WAKEUP_US_DEFAULT):
        self._m = None
        super().__init__()
        self.allow_protected = allow_protected
        self.tprog_us = tprog_us
        self.buffer_clear_us = buffer_clear_us
        self.flash_wakeup_us = flash_wakeup_us
        self.bus_errors = 0
        self._logged = set()
        self._op = None                       # operation in progress
        self._op_gen = 0
        self._wake_gen = 0
        self._obl_done = False
        self._init_regs()

    # ------------------------------------------------------------------ attach to the machine
    @property
    def m(self):
        return self._m

    @m.setter
    def m(self, machine):
        self._m = machine
        if machine is not None:
            machine.flash_ctl = self

    # ------------------------------------------------------------------ helpers
    def _log(self, text):
        self.m.log.append((self.m.cycles, "FLASH: " + text))

    def _log_once(self, key, text):
        if key not in self._logged:
            self._logged.add(key)
            self._log(text)

    def _cyc(self, us):
        return max(1, int(us * self.m.sysclk_hz / 1_000_000))

    def _irq(self):
        if self.m.nvic is not None:
            self.m.nvic.irq(4)                  # FLASH global interrupt, Table 51 (rm0038.txt:12998)

    def _error(self, flag, why):
        """Raise an error flag; an interrupt follows when ERRIE is set (3.8, rm0038.txt:4156)."""
        self.sr |= flag
        self._log(why)
        if self.pecr & PECR_ERRIE:
            self._irq()

    def _bus_error(self, why):
        self.bus_errors += 1
        self._log("BUS ERROR (not deliverable to the CPU by the memory callbacks): " + why)

    def _guard(self, what, addr, reason):
        """Brick guard: refuse the operation, log it, do not reset (task rule)."""
        self._log(f"BRICK-GUARD refused {what} at 0x{addr:08X} ({reason}); "
                  f"allow_protected is False, nothing was changed")
        self.sr |= SR_WRPERR
        if self.pecr & PECR_ERRIE:
            self._irq()

    @property
    def run_pd(self):
        return bool(self.acr & ACR_RUN_PD)

    # ------------------------------------------------------------------ reset
    def _init_regs(self):
        self.acr = 0                            # FLASH_ACR reset 0x00000000 (rm0038.txt:4184)
        self.pecr = PECR_RESET                  # FLASH_PECR reset 0x00000007 (rm0038.txt:4244)
        self.sr = SR_RESET                      # FLASH_SR reset 0x00000004 (rm0038.txt:4454)
        self.pd_unlocked = False
        self.key_state = {'PD': 0, 'PE': 0, 'PRG': 0, 'OPT': 0}   # 0 idle, 1 first key ok, 2 done, 3 locked out
        self._seq = None
        self._op = None
        self._op_gen += 1
        self._wake_gen += 1
        self.obr = 0
        self.wrpr = [0, 0, 0]
        self._opt_bad = False
        self._usr_bad = False

    def reset(self, power_on=False):
        """System reset.  Non-volatile contents are unchanged; an operation in progress is lost.
        The option bytes are loaded into FLASH_OBR and FLASH_WRPRx (3.5, rm0038.txt:3643)."""
        self._init_regs()
        self._load_option_bytes()

    def _ensure_loaded(self):
        if not self._obl_done:
            self._load_option_bytes()

    # ------------------------------------------------------------------ option byte loader
    def _opt_word(self, off):
        return int.from_bytes(bytes(self.m.uc.mem_read(INFO_BASE + off, 4)), 'little')

    @staticmethod
    def _word_valid(w):
        """A word holds each option byte and its complement (3.5, rm0038.txt:3655)."""
        return (w & 0xFFFF) == (~(w >> 16) & 0xFFFF)

    def _load_option_bytes(self):
        """Option byte loader.  A word whose complement does not match is not loaded: its fields
        read as 0 (RM0038 does not give the value) and OPTVERR is set; USER also sets OPTVERRUSR.
        With RDP = 0 the protection is level 1 (Table 22, rm0038.txt:4086)."""
        self._obl_done = True
        w0 = self._opt_word(0x00)
        w1 = self._opt_word(OPT_USER_OFF)
        rdp = (w0 & 0xFF) if self._word_valid(w0) else 0
        sprmod = (w0 >> 8 & 1) if self._word_valid(w0) else 0
        user = (w1 & 0xFF) if self._word_valid(w1) else 0
        # FLASH_OBR: RDPRT [7:0], SPRMOD [8], USER [23:16] (3.9.8, rm0038.txt:4532)
        self.obr = rdp | sprmod << 8 | user << 16
        wrpr = []
        bad = not self._word_valid(w0) or not self._word_valid(w1)
        for lo, hi in ((0x08, 0x0C), (0x10, 0x14), (0x18, 0x1C)):
            a, b = self._opt_word(lo), self._opt_word(hi)
            bad |= not (self._word_valid(a) and self._word_valid(b))
            wrpr.append(((a & 0xFFFF) if self._word_valid(a) else 0) |
                        (((b & 0xFFFF) if self._word_valid(b) else 0) << 16))
        self.wrpr = wrpr
        self._opt_bad = bad
        self._usr_bad = not self._word_valid(w1)
        self._refresh_optv()
        if bad:
            self._log("option byte verification failed (OPTVERR)")

    def _refresh_optv(self):
        if self._opt_bad:
            self.sr |= SR_OPTVERR
        if self._usr_bad:
            self.sr |= SR_OPTVERRUSR

    @property
    def rdp_level(self):
        rdprt = self.obr & 0xFF
        return 0 if rdprt == 0xAA else 2 if rdprt == 0xCC else 1

    # ------------------------------------------------------------------ registers: read
    def _reg_read(self, reg):
        if reg == 0x00:
            return self.acr                                      # FLASH_ACR 3.9.1 rm0038.txt:4182
        if reg == 0x04:
            return self.pecr                                         # FLASH_PECR 3.9.2 rm0038.txt:4240
        if reg in (0x08, 0x0C, 0x10, 0x14):
            return 0                                             # key registers are write-only (3.9.3-3.9.6)
        if reg == 0x18:
            bsy = SR_BSY if self._op is not None else 0           # FLASH_SR 3.9.7 rm0038.txt:4452
            endhv = 0 if self._op is not None else SR_ENDHV
            return (self.sr & ~(SR_BSY | SR_ENDHV)) | bsy | endhv
        if reg == 0x1C:
            return self.obr                                      # FLASH_OBR 3.9.8 rm0038.txt:4532
        if reg == 0x20:
            return self.wrpr[0]                                  # FLASH_WRPR1 3.9.9 rm0038.txt:4608
        if reg == 0x80:
            return self.wrpr[1]                                  # FLASH_WRPR2
        if reg == 0x84:
            return self.wrpr[2]                                  # FLASH_WRPR3
        return None                                              # 0x88 WRPR4 exists on category 5 only

    def read(self, off, size):
        self._ensure_loaded()
        val = self._reg_read(off & ~3)
        if val is None:
            self.unmodelled(off, 'R')
            return 0
        return self.extract(val, off, size)

    # ------------------------------------------------------------------ registers: write
    def write(self, off, value, size):
        self._ensure_loaded()
        reg = off & ~3
        if reg in (0x08, 0x0C, 0x10, 0x14):
            if size != 4 or off & 3:
                self._log_once(('keysize', reg), f"key register 0x{reg:02X} written with size {size}: ignored "
                               "(the key sequences are 32-bit writes)")
                return
            self._key_write(reg, value & 0xFFFFFFFF)
            return
        cur = self._reg_read(reg)
        if cur is None:
            self.unmodelled(off, 'W')
            return
        new = self.merge(cur, off, value, size)
        if reg == 0x00:
            self._w_acr(new)
        elif reg == 0x04:
            self._w_pecr(new)
        elif reg == 0x18:
            self._w_sr(new)
        else:
            self._log_once(('ro', reg), f"write to read-only register 0x{reg:02X} ignored (3.9.8 / 3.9.9)")

    # FLASH_ACR -------------------------------------------------------------
    def _w_acr(self, new):
        old = self.acr
        acc64, pf, lat = new >> 2 & 1, new >> 1 & 1, new & 1
        o_acc, o_pf, o_lat = old >> 2 & 1, old >> 1 & 1, old & 1
        # ACC64 cannot be written at the same time as LATENCY and PRFTEN (rm0038.txt:4226).
        # OPEN POINT: RM0038 does not say what a combined write does; only ACC64 is taken here.
        if acc64 != o_acc and (pf != o_pf or lat != o_lat):
            self._log_once('acr_combined', "ACR: ACC64 changed together with LATENCY/PRFTEN; "
                           "only ACC64 applied (rm0038.txt:4226)")
            pf, lat = o_pf, o_lat
        # LATENCY and PRFTEN can be set or cleared only if ACC64 is set (rm0038.txt:4230, 4236)
        if not o_acc:
            pf, lat = o_pf, o_lat
        # Table 14 (rm0038.txt:3016): with ACC64 = 0 only LATENCY = 0, PRFTEN = 0 is allowed
        if not acc64 and (pf or lat):
            self._log_once('acr_cfg', "ACR: ACC64 = 0 with LATENCY/PRFTEN set is not allowed (Table 14); "
                           "ACC64 stays set")
            acc64 = 1
        run_pd = old & ACR_RUN_PD
        if self.pd_unlocked:                                    # RUN_PD needs the PDKEYR sequence (rm0038.txt:4206)
            run_pd = new & ACR_RUN_PD
            self.pd_unlocked = False                            # OPEN POINT: re-lock after one write is assumed
        sleep_pd = new & ACR_SLEEP_PD
        self.acr = (acc64 << 2) | (pf << 1) | lat | sleep_pd | run_pd
        if run_pd and not old & ACR_RUN_PD:
            self._wake_gen += 1
            self.sr &= ~SR_READY                                # Flash module not ready in power down
        elif old & ACR_RUN_PD and not run_pd:
            self._wake_gen += 1
            g = self._wake_gen

            def ready():
                if g == self._wake_gen:
                    self.sr |= SR_READY                         # ready after low-power mode (rm0038.txt:4508)
            self.m.schedule(self._cyc(self.flash_wakeup_us), ready)

    # FLASH_SR --------------------------------------------------------------
    def _w_sr(self, new):
        self.sr &= ~(new & SR_W1C)
        self._refresh_optv()                    # OPTVERR is set again while the option bytes are bad (rm0038.txt:4494)

    # FLASH_PECR ------------------------------------------------------------
    def _w_pecr(self, new):
        old = self.pecr
        if old & PECR_PELOCK:
            self._log_once('pecr_locked', "write to FLASH_PECR ignored while PELOCK is set (rm0038.txt:4241)")
            return
        cur = old
        cur = (cur & ~(PECR_ERRIE | PECR_EOPIE)) | (new & (PECR_ERRIE | PECR_EOPIE))
        if self._op is None:                    # mode bits are writable only when no operation is ongoing
            cur = (cur & ~PECR_MODE_BITS) | (new & PECR_MODE_BITS)
        if new & PECR_OPTLOCK:                  # lock bits can only be written to 1 (rm0038.txt:4339)
            cur |= PECR_OPTLOCK
            self._key_relock('OPT')
        if new & PECR_PRGLOCK:
            cur |= PECR_PRGLOCK
            self._key_relock('PRG')
        if new & PECR_PELOCK:
            cur |= PECR_PELOCK | PECR_PRGLOCK | PECR_OPTLOCK    # set together with PELOCK (rm0038.txt:4344, 4352)
            cur &= ~PECR_CLEARED_BY_PELOCK                       # cleared when PELOCK is set (rm0038.txt:4297)
            for k in ('PE', 'PRG', 'OPT'):
                self._key_relock(k)
        launch = bool(new & PECR_OBL_LAUNCH) and not old & PECR_OPTLOCK
        self.pecr = cur
        if (cur ^ old) & PECR_MODE_BITS or cur & PECR_PELOCK:
            self._seq = None                    # a new loading sequence starts after a mode change
            if self._buffer_mode(cur) and not self._buffer_mode(old):
                self._start_op(self._cyc(self.buffer_clear_us), None)    # wait for BSY after FPRG + PROG/DATA
        if launch:
            self._launch_obl()

    @staticmethod
    def _buffer_mode(pecr):
        return bool(pecr & PECR_FPRG and pecr & (PECR_PROG | PECR_DATA) and not pecr & PECR_ERASE)

    def _launch_obl(self):
        """OBL_LAUNCH: the option bytes are loaded and a reset is generated (3.9.2 rm0038.txt:4271,
        6.1.1 rm0038.txt:6582).  The bit is cleared when loading has completed."""
        self._log("OBL_LAUNCH: reloading option bytes")
        self._load_option_bytes()
        self.m.request_reset("OBL_LAUNCH")

    # ------------------------------------------------------------------ key sequences (3.4.1)
    def _key_relock(self, which):
        if self.key_state[which] != 3:
            self.key_state[which] = 0

    def _key_write(self, reg, value):
        if reg == 0x08:
            self._pdkey_write(value)
            return
        which, k1, k2 = {0x0C: ('PE', PEKEY1, PEKEY2), 0x10: ('PRG', PRGKEY1, PRGKEY2),
                         0x14: ('OPT', OPTKEY1, OPTKEY2)}[reg]
        lockbit = {'PE': PECR_PELOCK, 'PRG': PECR_PRGLOCK, 'OPT': PECR_OPTLOCK}[which]
        if which != 'PE' and self.pecr & PECR_PELOCK:
            self._log_once(('keyreg', reg), f"{which}KEYR written while FLASH_PECR is locked: ignored "
                           "(the register is accessible only after the PEKEYR sequence, rm0038.txt:4410)")
            return
        st = self.key_state[which]
        if st == 3:
            self._bus_error(f"{which}KEYR written after a failed key sequence (locked until reset)")
            return
        ok = (st == 0 and value == k1) or (st == 1 and value == k2)
        if ok and st == 0:
            self.key_state[which] = 1
            return
        if ok:
            self.key_state[which] = 2
            self.pecr &= ~lockbit                               # unlock sequence complete
            return
        # wrong first key, wrong second key, or a third write: locked until the next reset
        self.key_state[which] = 3
        self.pecr |= lockbit
        if which == 'PE':
            self.pecr |= PECR_PRGLOCK | PECR_OPTLOCK
            self.pecr &= ~PECR_CLEARED_BY_PELOCK
        self._bus_error(f"wrong {which}KEYR sequence (value 0x{value:08X}, state {st})")

    def _pdkey_write(self, value):
        """FLASH_PDKEYR unlocks RUN_PD in FLASH_ACR (3.9.3, rm0038.txt:4372).
        OPEN POINT: RM0038 defines no lock-out or bus error for this register; a wrong value
        restarts the sequence."""
        st = self.key_state['PD']
        if st == 1 and value == PDKEY2:
            self.key_state['PD'] = 0
            self.pd_unlocked = True
        elif value == PDKEY1:
            self.key_state['PD'] = 1
        else:
            self.key_state['PD'] = 0

    # ------------------------------------------------------------------ operation engine
    def _start_op(self, cycles, commit):
        """Mark BSY, run `commit` after `cycles` and then set EOP (3.9.7 rm0038.txt:4512-4523).
        `commit` None means the BSY pulse of a buffer clear: no EOP."""
        self._op_gen += 1
        g = self._op_gen
        self._op = {'gen': g, 'due': self.m.cycles + cycles, 'commit': commit}
        self.m.schedule(cycles, lambda: self._finish(g))

    def _finish(self, gen):
        op = self._op
        if op is None or op['gen'] != gen:
            return
        self._op = None
        self._bank_guard_off()
        if op['commit'] is not None:
            op['commit']()
            self.sr |= SR_EOP
            if self.pecr & PECR_EOPIE:
                self._irq()

    def _stall(self):
        """A store while an operation is running stalls the bus until it ends (3.2, rm0038.txt:2562)."""
        op = self._op
        if op is not None:
            self.m.cycles = max(self.m.cycles, op['due'])
            self._finish(op['gen'])

    def _tprog(self, n=1):
        return self._cyc(self.tprog_us) * n

    # ------------------------------------------------------------------ CPU stores to non-volatile memory
    def cpu_store(self, addr, value, size):
        """A CPU store of `size` bytes to flash, EEPROM, system memory or option bytes."""
        self._ensure_loaded()
        self._stall()
        value &= (1 << (8 * size)) - 1
        if EEPROM_BASE <= addr < EEPROM_BASE + EEPROM_SIZE:
            self._st_eeprom(addr, value, size)
        elif FLASH_BASE <= addr < FLASH_BASE + FLASH_SIZE:
            self._st_program(addr, value, size)
        elif INFO_BASE <= addr < INFO_BASE + INFO_SIZE:
            self._st_option(addr, value, size)
        elif SYSMEM_BASE <= addr < SYSMEM_END:
            self._error(SR_WRPERR, f"store to system memory 0x{addr:08X} refused (3.7.3, rm0038.txt:4116)")
        else:
            self._log(f"store to 0x{addr:08X} is not non-volatile memory: ignored")

    # --- loading sequences (half page, double word) -----------------------------
    def _seq_store(self, kind, addr, value, precheck=None, commit=None):
        n_words, align = SEQ_CFG[kind]
        seq = self._seq
        if seq is None or seq['kind'] != kind:
            if addr % align:
                self._seq = None
                self._error(SR_PGAERR, f"{kind}: first address 0x{addr:08X} is not aligned to {align} bytes "
                            "(3.4.3 Alignment error flag, rm0038.txt:3574)")
                return
            ok = precheck(addr) if precheck else True
            seq = {'kind': kind, 'base': addr, 'words': [], 'dead': not ok}
            self._seq = seq
        elif addr != seq['base'] + 4 * len(seq['words']):
            # OPEN POINT: RM0038 requires sequential loading (rm0038.txt:3212); a store out of order is
            # reported as a programming alignment error and the whole sequence is aborted (Table 15 note 4).
            self._seq = None
            self._error(SR_PGAERR, f"{kind}: store 0x{addr:08X} breaks the sequential loading from "
                        f"0x{seq['base']:08X}; sequence aborted")
            return
        seq['words'].append(value)
        if len(seq['words']) == n_words:
            self._seq = None
            if not seq['dead']:
                commit(seq['base'], seq['words'])

    # --- data EEPROM -----------------------------------------------------------
    def _ee_read_word(self, o):
        return int.from_bytes(self.m.eeprom[o:o + 4], 'little')

    def _st_eeprom(self, addr, value, size):
        pecr = self.pecr
        if addr + size > EEPROM_BASE + EEPROM_SIZE:
            self._log(f"store of {size} bytes at 0x{addr:08X} crosses the end of the data EEPROM: ignored")
            return
        if pecr & PECR_PELOCK:
            self._error(SR_WRPERR, f"store to data EEPROM 0x{addr:08X} while PELOCK is set (3.7.3, rm0038.txt:4117)")
            return
        if pecr & PECR_PROG:
            self._log_once('ee_prog', "data EEPROM store with PROG set ignored: PROG selects program memory")
            return
        if pecr & PECR_PARALLBANK and pecr & (PECR_ERASE | PECR_FPRG):
            self.unmodelled(0x04, 'W')
            self._log_once('ee_par', "PARALLBANK with a data EEPROM double word operation: not described in RM0038")
            return
        if pecr & PECR_ERASE:
            if not pecr & PECR_DATA:
                self._log_once('ee_erase_nodata', "EEPROM store with ERASE but without DATA ignored (3.4.2, rm0038.txt:3146)")
                return
            if size != 4:
                self._error(SR_SIZERR, f"EEPROM double word erase needs word stores, got size {size}")
                return
            if value != 0:
                self._seq = None
                self._log("EEPROM double word erase: a non-zero word was stored; sequence aborted (3.4.2, rm0038.txt:3148)")
                return
            self._seq_store('ee_derase', addr, value, commit=self._commit_ee_derase)
            return
        if pecr & PECR_FPRG:
            if not pecr & PECR_DATA:
                self._log_once('ee_fprg_nodata', "EEPROM store with FPRG but without DATA ignored (3.4.3, rm0038.txt:3256)")
                return
            if size != 4:
                self._error(SR_SIZERR, f"EEPROM double word write needs word stores, got size {size}")
                return
            self._seq_store('ee_dwrite', addr, value, commit=self._commit_ee_dwrite)
            return
        self._ee_write_lanes(addr, value, size)

    def _commit_ee_derase(self, base, words):
        o = base - EEPROM_BASE
        self._start_op(self._tprog(1), lambda: self.m.eeprom.__setitem__(slice(o, o + 8), bytes(8)))

    def _commit_ee_dwrite(self, base, words):
        o = base - EEPROM_BASE
        data = b''.join(w.to_bytes(4, 'little') for w in words)
        self._start_op(self._tprog(1), lambda: self.m.eeprom.__setitem__(slice(o, o + 8), data))

    def _ee_write_lanes(self, addr, value, size):
        """Byte / half word / word write (3.4.3, rm0038.txt:3279-3416).  Per affected word the interface
        reads the word, merges the stored bytes, and writes it back; an erase phase comes first when
        FTDW = 1 or the word read is not 0 (Table 15, rm0038.txt:3430).  A word store of 0 is the word
        erase (rm0038.txt:3135).  OPEN POINT: bytes of the word that are not stored are kept."""
        o = addr - EEPROM_BASE
        data = value.to_bytes(size, 'little')
        words = {}
        for i, b in enumerate(data):
            words.setdefault((o + i) & ~3, {})[(o + i) & 3] = b
        plan = []
        tprogs = 0
        ftdw = bool(self.pecr & PECR_FTDW)
        for wo, lanes in words.items():
            old = self._ee_read_word(wo)
            cur = bytearray(old.to_bytes(4, 'little'))
            for lane, b in lanes.items():
                cur[lane] = b
            word_erase = (len(lanes) == 4 and value == 0 and size == 4)
            erase_phase = (not word_erase) and (ftdw or old != 0)
            tprogs += 2 if erase_phase else 1
            plan.append((wo, bytes(cur)))

        def commit():
            for wo, data4 in plan:
                self.m.eeprom[wo:wo + 4] = data4
        self._start_op(self._tprog(tprogs), commit)

    # --- program memory --------------------------------------------------------
    def _wrp_protected(self, addr):
        sector = (addr - FLASH_BASE) // SECTOR_SIZE
        return bool(self.wrpr[sector // 32] >> (sector % 32) & 1)

    def _prog_precheck(self, what, addr, length):
        """Brick guard and write protection for program memory targets."""
        if addr < BOOT_END and not self.allow_protected:
            self._guard(what, addr, "bootloader area 0x08000000-0x08005FFF")
            return False
        for a in range(addr & ~(SECTOR_SIZE - 1), addr + length, SECTOR_SIZE):
            if self._wrp_protected(a):
                self._error(SR_WRPERR, f"{what} at 0x{a:08X}: sector is write protected (3.7.3, rm0038.txt:4112)")
                return False
        return True

    def _st_program(self, addr, value, size):
        pecr = self.pecr
        if pecr & (PECR_PELOCK | PECR_PRGLOCK):
            self._error(SR_WRPERR, f"store to program memory 0x{addr:08X} while locked (3.7.3, rm0038.txt:4117)")
            return
        if pecr & PECR_DATA:
            self._log_once('prog_data', "program memory store with DATA set ignored: DATA selects the data EEPROM")
            return
        if pecr & PECR_PARALLBANK and pecr & (PECR_ERASE | PECR_FPRG):
            self.unmodelled(0x04, 'W')
            self._log_once('par', "parallel bank erase/programming: RM0038 3.4.2/3.4.3 do not give the address "
                           "pairing, not modelled")
            return
        if pecr & PECR_ERASE and pecr & PECR_FPRG:
            self._log_once('erase_fprg', "ERASE and FPRG both set: combination not described in RM0038; store ignored")
            return
        if pecr & PECR_ERASE:
            if not pecr & PECR_PROG:
                self._log_once('erase_noprog', "program memory store with ERASE but without PROG ignored (3.4.2, rm0038.txt:3165)")
                return
            if size != 4:
                self._error(SR_SIZERR, "program memory erase needs a word store (Table 17, rm0038.txt:3593)")
                return
            self._page_erase(addr, value)
            return
        if pecr & PECR_FPRG:
            if not pecr & PECR_PROG:
                self._log_once('fprg_noprog', "program memory store with FPRG but without PROG ignored (3.4.3, rm0038.txt:3209)")
                return
            if size != 4:
                self._error(SR_SIZERR, "half page write needs word stores (Table 17, rm0038.txt:3591)")
                return
            self._seq_store('prog_hp', addr, value,
                            precheck=lambda a: self._prog_precheck("half page write", a, HALF_PAGE_SIZE),
                            commit=self._commit_half_page)
            return
        # word programming (Fast Word Write, 3.4.3 rm0038.txt:3193)
        if size != 4:
            self._error(SR_SIZERR, "program memory byte/half word write prohibited (Table 17, rm0038.txt:3591)")
            return
        if addr & 3:
            self._log_once('prog_unaligned', "unaligned word write to program memory: no behaviour defined in RM0038, ignored")
            return
        if not self._prog_precheck("word write", addr, 4):
            return
        self._program_words(addr, [value], "word write")

    def _page_erase(self, addr, value):
        """Page erase: a word store of 0 to the first word of the page (3.4.2, rm0038.txt:3160-3167)."""
        if addr % PAGE_SIZE:
            # Table 21 note 2 (rm0038.txt:3963): a page is erased only at its start address.
            # OPEN POINT: the result of any other address is not given; nothing is erased.
            self._log_once('erase_unaligned', f"page erase at 0x{addr:08X}: not a page start address, ignored")
            return
        if value != 0:
            self._log_once('erase_value', "page erase store with a non-zero value ignored (3.4.2, rm0038.txt:3166)")
            return
        if not self._prog_precheck("page erase", addr, PAGE_SIZE):
            return
        self._start_op(self._tprog(1), lambda: self._flash_write(addr, bytes(PAGE_SIZE)))

    def _flash_write(self, addr, data):
        """Program-flash content changes (erase or programming): the memory, and Unicorn's translated code of that range
        is dropped, so code that runs there later is the new code (the starter installs a bootloader over code that
        ran before; Unicorn keeps translated blocks otherwise)."""
        self.m.uc.mem_write(addr, data)
        self.m.uc.ctl_remove_cache(addr, addr + len(data))

    def _commit_half_page(self, base, words):
        self._program_words(base, words, "half page write")
        self._bank_guard_on(base)

    # --- same-bank reads during a half page write (3.4.3 note 2, rm0038.txt:3230) ---------------------------
    BANK_SIZE = 0x30000                                 # 192 Kbytes per bank (Table 10, rm0038.txt:2686)

    def _bank_guard_on(self, base):
        from unicorn import UC_HOOK_CODE, UC_HOOK_MEM_READ
        lo = FLASH_BASE + (base - FLASH_BASE) // self.BANK_SIZE * self.BANK_SIZE
        hi = lo + self.BANK_SIZE - 1
        uc = self.m.uc

        def hit(kind, addr):
            self._bank_guard_off()
            self._bus_error(f"{kind} at 0x{addr:08X} while a half page write to 0x{base:08X} runs in the same bank "
                            "(3.4.3 note 2, rm0038.txt:3230)")
            self.m._stop_reason = f"bus error: {kind} at 0x{addr:08X} during a half page write"
            uc.emu_stop()
        self._bank_hooks = [
            uc.hook_add(UC_HOOK_CODE, lambda u, a, sz, ud: hit('instruction fetch', a), begin=lo, end=hi),
            uc.hook_add(UC_HOOK_MEM_READ, lambda u, acc, a, sz, v, ud: hit('data read', a), begin=lo, end=hi)]

    def _bank_guard_off(self):
        for h in getattr(self, '_bank_hooks', ()):
            self.m.uc.hook_del(h)
        self._bank_hooks = []

    def _program_words(self, base, words, what):
        data = b''.join(w.to_bytes(4, 'little') for w in words)

        def commit():
            cur = bytes(self.m.uc.mem_read(base, len(data)))
            # OPEN POINT: programming a word that is not erased is not defined by RM0038; erased
            # flash reads 0, programming only sets bits, and the target must be erased first.  The
            # write is refused unless the target is erased or already equal.
            if any(c != 0 and c != d for c, d in zip(cur, data)):
                self._log(f"{what} at 0x{base:08X}: target is not erased, nothing written")
                return
            self._flash_write(base, data)
        self._start_op(self._tprog(1), commit)

    # --- option bytes ----------------------------------------------------------
    def _st_option(self, addr, value, size):
        pecr = self.pecr
        off = addr - INFO_BASE
        if pecr & (PECR_PELOCK | PECR_OPTLOCK):
            self._error(SR_WRPERR, f"store to option bytes 0x{addr:08X} while locked (3.7.3, rm0038.txt:4117)")
            return
        if size != 4 or off & 3:
            self._error(SR_SIZERR, "option byte block accepts word stores only (Table 17, rm0038.txt:3594)")
            return
        if off not in OPT_WORDS:
            self._error(SR_WRPERR, f"0x{addr:08X} is not an option byte word of this device (Table 18, rm0038.txt:3629)")
            return
        if pecr & (PECR_ERASE | PECR_FPRG | PECR_DATA | PECR_PROG):
            self._log_once('opt_mode', "option byte store with ERASE/FPRG/DATA/PROG set ignored: "
                           "option bytes use Word Erase / Word Write only (3.5.1, rm0038.txt:3782)")
            return
        if off in OPT_GUARDED and not self.allow_protected:
            self._guard("option byte word write", addr, "RDP / write protection word")
            return
        if self.rdp_level == 2:
            self._error(SR_WRPERR, "option bytes cannot be changed in read protection level 2 (3.7.1, rm0038.txt:4038)")
            return
        old = self._opt_word(off)
        data = value.to_bytes(4, 'little')
        if value != 0 and not self._word_valid(value):
            self._log(f"option word 0x{addr:08X} = 0x{value:08X} does not hold complements; the loader will report OPTVERR")
        mass = False
        if off == 0x00 and self.rdp_level == 1 and (value & 0xFF) == 0xAA and self._word_valid(value):
            mass = True                         # level 1 -> level 0: mass erase first (3.7.1, rm0038.txt:4010)
        ftdw = bool(pecr & PECR_FTDW)
        word_erase = (value == 0)
        erase_phase = (not word_erase) and (ftdw or old != 0)
        n = (3 if mass else 2 if erase_phase else 1)

        def commit():
            if mass:
                self._log("RDP level 1 -> 0: mass erase of program memory, data EEPROM and option bytes")
                self.m.uc.mem_write(FLASH_BASE, bytes(FLASH_SIZE))
                self.m.eeprom[:] = bytes(EEPROM_SIZE)
                self.m.uc.mem_write(INFO_BASE, bytes(0x20))          # option bytes, bank 1
                self.m.uc.mem_write(INFO_BASE + 0x80, bytes(0x20))   # option bytes, bank 2 (Table 10)
            self.m.uc.mem_write(addr, data)
        self._start_op(self._tprog(n), commit)
