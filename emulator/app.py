"""121GW emulator application: builds the machine, loads the images, runs it and serves the UI.

Usage:
    python app.py [--port 8121] [--speed 1.0] [--no-ui] [--open] [--frontend calibrated|netlist]
                  [--firmware 2_fast|1_like_v2.05 | --app FILE] [--eeprom FILE] [--sdcard PATH]
                  [--inputs DIR | --no-inputs] [--bootloader FILE] [--option-bytes FILE] [--v205-image FILE] [--tables FILE]

Without any original image the emulator needs nothing but its own data directory (emu/bundle.py):
  * direct boot: no bootloader image is loaded and the core starts the application from its vector table at 0x08006000
    (stack pointer = word 0, reset vector = word 1, VTOR = 0x08006000), the state the bootloader hands over in
    (firmware/DESIGN.md 2.1) except for what DIRECT_BOOT_NOTE lists;
  * the application is a firmware build fetched on demand from the project's GitHub releases and cached
    (--firmware, default 2_fast; emu/fetch.py) or any image given with --app; with neither the meter stays dark;
  * the EEPROM is the bundled SYNTHETIC image (not a meter's calibration) unless --eeprom gives one;
  * the v2.05 constant tables the calibrated front end needs come from the bundled table data (emu/v205tables.py).
Original images, all optional:
  --inputs DIR      a directory with bootloader.bin, EEVBlog2_05.bin (or another application image via --app),
                    option.bytes and an optional EEPROM image (--eeprom, raw bytes from offset 0).  Without --inputs the
                    directory inputs/binaries of the source tree is used when it exists (the earlier behaviour);
                    --no-inputs ignores it.
  --bootloader FILE the bootloader image (raw, loaded at 0x08000000): the core then boots through it as a meter does.
  --option-bytes FILE  OpenOCD 'mdb 0x1FF80000 256' dump; without it the synthetic option bytes are used.
  --v205-image FILE the original v2.05 application image: the front end then reads its tables from it, not from the data.
--sdcard PATH attaches an SD card backed by the raw image file PATH (created and formatted FAT32 with --sdcard-mb MiB if
it does not exist; nothing outside PATH is written).  Without it the SD socket is empty.
"""
import argparse, os, sys, threading, time, webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from emu.core import Machine, FLASH_BASE, FLASH_SIZE, EEPROM_BASE, INFO_BASE, SRAM_BASE, SRAM_SIZE
from emu.scs import SCS
from emu.board import Board, DIAL
from emu.periph.rcc import RCC
from emu.periph.pwr import PWR
from emu.periph.flash import FLASH
from emu.periph.gpio import make_ports, GPIO_BASES, GPIO_SIZE
from emu.periph.syscfg import SYSCFG
from emu.periph.exti import EXTI
from emu.periph.lcd import LCD
from emu.periph.tim import Tim, Tim11
from emu.periph.usart import USART
from emu.periph.adc import ADC
from emu.periph.dma import DMA
from emu.periph.sdio import SDIO
from emu.sdcard import open_card
from emu.periph.rtc import RTC
from emu.nju6350 import NJU6350
from emu.hy3131 import HY3131
from emu.frontend import make_frontend, FrontendUnavailable
from emu.safety import Safety
from emu.v205tables import V205Tables
from emu import bundle, fetch

APP_BASE = 0x08006000
APP_MAX = FLASH_BASE + FLASH_SIZE - APP_BASE        # room for an application image above the bootloader (368 KiB)


def check_app_image(data):
    """Reasons why `data` cannot be a 121GW application image (raw binary for 0x08006000, the EEVBlog.bin a meter's
    bootloader takes from the SD card), as a list of sentences; empty when it can be run.  The test is the one the
    bootloader's hand-over relies on (firmware/DESIGN.md 2.1): word 0 is the initial stack pointer, inside the SRAM, and
    word 1 the reset vector, a Thumb address (bit 0 set) inside the image."""
    problems = []
    if len(data) < 8:
        return [f'the file has {len(data)} bytes; an application image starts with an 8-byte vector table']
    if len(data) > APP_MAX:
        problems.append(f'the file has {len(data)} bytes, more than the {APP_MAX} bytes of flash above the bootloader '
                        f'(a full flash dump that starts with the bootloader is not an application image)')
    sp, reset = int.from_bytes(data[0:4], 'little'), int.from_bytes(data[4:8], 'little')
    if not SRAM_BASE < sp <= SRAM_BASE + SRAM_SIZE:
        problems.append(f'word 0 (initial stack pointer) is 0x{sp:08X}, not an address in the RAM '
                        f'0x{SRAM_BASE:08X}..0x{SRAM_BASE + SRAM_SIZE:08X}')
    if not reset & 1 or not APP_BASE <= reset & ~1 < APP_BASE + len(data):
        problems.append(f'word 1 (reset vector) is 0x{reset:08X}, not a Thumb address inside the image '
                        f'(0x{APP_BASE:08X}..0x{APP_BASE + len(data) - 1:08X})')
    return problems
BAT_SENSE_RATIO = 330e3 / (1e6 + 330e3)   # PA5 / B+ (R69 1M, R70 330k; analysis/frontend_netlist.md)


def parse_option_bytes(path):
    """OpenOCD 'mdb 0x1FF80000 256' dump -> 256 bytes."""
    ob = bytearray(256)
    for line in open(path):
        line = line.strip()
        if line.lower().startswith('0x1ff8'):
            a, rest = line.split(':', 1)
            off = int(a, 16) - INFO_BASE
            for i, b in enumerate(rest.split()):
                if 0 <= off + i < 256:
                    ob[off + i] = int(b, 16)
    return bytes(ob)


def synthetic_option_bytes():
    """Option bytes 0x1FF80000..0x1FF8001F of an unprotected meter, used when no option-byte dump is given: RDP level 0
    (RDP = 0xAA), USER = 0xF0 (BOR off, software watchdog, no reset on STOP / STANDBY: firmware/DESIGN.md 2.1), all write
    protection words 0 (nothing protected).  Format RM0038 3.5: RDP / USER words are the byte in bits 7:0, its complement in
    bits 23:16 and 0xFF in bits 31:24; each WRP word holds a 16-bit value and its complement.  The rest of the 256-byte
    block (factory information) is 0."""
    ob = bytearray(256)
    for off, v in ((0x00, 0xAA), (0x04, 0xF0)):
        ob[off:off + 4] = (v | ((~v & 0xFF) << 16) | 0xFF000000).to_bytes(4, 'little')
    for off in range(0x08, 0x20, 4):
        ob[off:off + 4] = (0xFFFF0000).to_bytes(4, 'little')
    return bytes(ob)


# What direct boot (no bootloader image) does not reproduce of the state the bootloader leaves at the application's entry
# (firmware/DESIGN.md 2.1): the bootloader's own TIM2 set-up (counter running with its update interrupt enabled, so the
# first TIM2 updates of the application come at the bootloader's phase), NVIC enables of IRQ 28 / 45 / 53, SYSCLK = HSE
# with the PLL on but not selected (direct boot starts on the reset clock, MSI), FLASH_PECR = 0x00000004 (EEPROM and flash
# unlocked, direct boot: locked as after reset), the backup-domain reset, the lamp-test pattern on the LCD, and the GPIO
# levels it set (PE9 high, PF0..PF2 and PF6..PF10 outputs, PE8 high, PD7 low).  VTOR is 0x08006000 here, not the
# bootloader's 0x08000000, because the bootloader area is empty.  A system reset restarts the application directly again
# (a meter would run the bootloader first).  The replacement firmware does not depend on these (its start-up sequence,
# DESIGN.md 3.2, sets clocks, NVIC, VTOR and the flash lock itself); a firmware that does would behave differently from a
# meter.
DIRECT_BOOT_NOTE = ('direct boot: the application starts from its vector table (SP, reset vector, VTOR 0x08006000); the '
                    "bootloader's TIM2/NVIC/clock/FLASH_PECR/GPIO/LCD state is not reproduced (app.py DIRECT_BOOT_NOTE)")


class Emulator:
    # HY3131 front end: backend 'calibrated' or 'netlist' (emu/frontend.py), noise on/off and RNG seed
    frontend_kind = 'calibrated'
    hy_noise = True
    hy_seed = None
    # SD card image (emu/sdcard.py): path of the raw image or None for an empty socket, and its size when it is created
    sdcard_path = None
    sdcard_mb = 512
    flash_allow_protected = False       # True only in tests of the bootloader install (FLASH brick guard off)
    msi_error_ppm = 0                   # model settings of the MSI oscillator (emu/periph/rcc.py RCC.__init__): this
    msi_trim_ppm = 0                    # part's error and the change per MSITRIM code; 0 / 0 = nominal, trim inert

    def __init__(self, inputs=None, app=None, eeprom=None, speed=1.0, hw_cal=None, *, bootloader=None, option_bytes=None,
                 v205_image=None, tables=None, firmware=None):
        """inputs: directory with bootloader.bin, EEVBlog2_05.bin and option.bytes (None: none of them is needed).
        app: application image (default: inputs/EEVBlog2_05.bin, else the release build `firmware`, default 2_fast,
        fetched on demand by emu/fetch.py; when that fails the meter stays dark and firmware_note says why).
        eeprom: raw EEPROM image from offset 0 (default: the bundled synthetic image when `inputs` is None, else a blank
        EEPROM as before).  Keyword-only, each overriding the file of `inputs`: bootloader (without one the core boots
        the application directly), option_bytes (default: synthetic_option_bytes()), v205_image (original v2.05 image
        the front end reads its tables from; default the table data `tables` / bundle), firmware (release build name)."""
        self.inputs = inputs
        # physical calibration of the emulated front end (frontend._Base.hw_cal): the EEPROM as first loaded, or the
        # image given here (raw bytes from EEPROM offset 0), kept across power cycles and firmware EEPROM writes
        self.hw_cal = None
        self.hw_cal_path = hw_cal
        join = lambda name: os.path.join(inputs, name) if inputs else None
        self.bootloader_path = bootloader or join('bootloader.bin')
        self.option_path = option_bytes or join('option.bytes')
        self.v205_path = v205_image or join('EEVBlog2_05.bin')
        self.firmware_name = None           # release build name (emu/fetch.py) or None for an image file
        self.firmware_tag = None            # release tag of that build
        self.firmware_note = None           # why the build is a cached one or missing
        if app:
            self.app_path = app
        elif inputs:
            self.app_path = join('EEVBlog2_05.bin')
        else:
            self.firmware_name = firmware or fetch.DEFAULT_BUILD
            try:
                self.app_path, self.firmware_tag, self.firmware_note = fetch.fetch(self.firmware_name, check_app_image)
            except fetch.FirmwareUnavailable as e:
                self.app_path, self.firmware_note = None, str(e)
        if eeprom is None and inputs is None:
            self.eeprom_path, self.eeprom_kind = bundle.eeprom_path(), 'synthetic'
        else:
            self.eeprom_path, self.eeprom_kind = eeprom, ('file' if eeprom else 'blank')
        self.tables = None                  # v2.05 tables for the front end, unless an original image is given
        if not self.v205_path:
            self.tables = V205Tables.load(tables or bundle.tables_path())
        self.speed = speed                  # 1.0 = real time
        self.lock = threading.RLock()
        self.running = True
        self.board_state = {'keys': set(), 'dial': 2, 'jacks': set()}
        self.log_tail = []
        self.nju = NJU6350()                # battery-backed RTC chip: lives across power cycles of the meter
        # SD card: the image file and the inserted / removed state live across power cycles (the card state machine restarts)
        self.sdcard = open_card(self.sdcard_path, self.sdcard_mb) if self.sdcard_path else None
        self.sd_inserted = self.sdcard is not None
        self.build()

    # ------------------------------------------------------------------ machine
    def build(self):
        m = self.m = Machine()
        SCS(m)
        self.rcc = RCC(msi_error_ppm=self.msi_error_ppm, msi_trim_ppm=self.msi_trim_ppm)
        self.pwr, self.flash = PWR(), FLASH(allow_protected=self.flash_allow_protected)
        m.add_periph(0x40023800, 0x400, self.rcc)
        m.add_periph(0x40007000, 0x400, self.pwr)
        m.add_periph(0x40023C00, 0x400, self.flash)
        self.gpio = make_ports()
        for letter, port in self.gpio.items():
            m.add_periph(GPIO_BASES[letter], GPIO_SIZE, port)
        self.syscfg = SYSCFG()
        m.add_periph(0x40010000, 0x400, self.syscfg)
        self.exti = EXTI(self.syscfg)
        m.add_periph(0x40010400, 0x400, self.exti)
        for port in self.gpio.values():
            self.exti.attach_gpio(port)
        # an EXTI event pulse is the external event signal that sets the WFE event register (PM0056 2.5.3)
        self.exti.event_hook = lambda mask: setattr(m, 'event_reg', True)
        # internal RTC (RTC_AF1 = PC13) and the external NJU6350 (CE PC13, CLK PB6, DATA PB7; schematic nets
        # RTC_CE, EE_CLK, EE_DO)
        self.rtc = RTC(self.exti)
        m.add_periph(0x40002800, 0x400, self.rtc)
        self.rtc.attach_af1(self.gpio['C'], 13)
        self.nju.attach(m, (self.gpio['C'], 13), (self.gpio['B'], 6), (self.gpio['B'], 7))
        self.lcd = LCD()
        m.add_periph(0x40002400, 0x400, self.lcd)
        self.tim2, self.tim3 = Tim(0x40000000, 28, 'TIM2'), Tim(0x40000400, 29, 'TIM3')
        m.add_periph(0x40000000, 0x400, self.tim2)
        m.add_periph(0x40000400, 0x400, self.tim3)
        self.tim11 = Tim11()                # MSI measurement against HSE_RTC (firmware IMP-46)
        m.add_periph(0x40011000, 0x400, self.tim11)
        self.rcc.reset_hooks.setdefault('TIM11', []).append(self.tim11.reset)
        self.usart2 = USART(0x40004400, 38, 'USART2')
        m.add_periph(0x40004400, 0x400, self.usart2)
        # ADC: PA5 = battery sense, PA4 = thermistor (firmware: adc_ch5_process / adc_ch4_process).
        # Defaults: B+ = 6 V (BAT1 "6V") through R69 1M / R70 330k (wire-traced, analysis/frontend_netlist.md) at PA5;
        # NTC1 10k vs R38 10k at 25 C = half of VDDA.  Both are UI-adjustable (battery as B+, see command 'battery').
        self.adc = ADC(vref_volts=3.3)
        m.add_periph(0x40012400, 0x400, self.adc)
        self.analog = dict(self.board_state.get('analog', {'PA5': 6.0 * BAT_SENSE_RATIO, 'PA4': 1.65}))
        self.adc.set_channel_volts(5, self.analog['PA5'])
        self.adc.set_channel_volts(4, self.analog['PA4'])
        self.ble_rx = []
        self.usart2.on_tx.append(lambda b: self.ble_rx.append(b))
        # DMA1 / DMA2 and the SDIO host (SD socket CN4: PD2 CMD, PC12 CLK, PC8 D0); SDIO is DMA2 channel 4 (RM0038 table 56)
        self.dma1, self.dma2 = DMA('DMA1', 0x40026000, 7, 11), DMA('DMA2', 0x40026400, 5, 50)
        m.add_periph(0x40026000, 0x400, self.dma1)
        m.add_periph(0x40026400, 0x400, self.dma2)
        self.sdio = SDIO(0x40012C00, 45)
        m.add_periph(0x40012C00, 0x400, self.sdio)
        self.dma2.attach_request(4, self.sdio.dma_request)
        self.sdio.dma_poke = self.dma2.poke
        for name, model in (('DMA1', self.dma1), ('DMA2', self.dma2), ('SDIO', self.sdio)):
            self.rcc.reset_hooks.setdefault(name, []).append(model.reset)
        self.sdio.set_card(self.sdcard if self.sd_inserted else None)
        # HY3131 on PF0..PF3 with the front end that turns the jack stimulus into pin voltages
        self.frontend_error = None
        try:
            self.frontend = make_frontend(self.frontend_kind, m,
                                          netlist_path=os.path.join(HERE, '..', 'analysis', 'frontend_netlist.cir'),
                                          lib_path=os.environ.get('NGSPICE_LIB'))
        except FrontendUnavailable as e:
            self.frontend_error = f'{e}; using the calibrated backend'
            m.log.append((0, self.frontend_error))
            self.frontend = make_frontend('calibrated', m)
        self.hy = HY3131(m, self.gpio['F'], self.frontend, seed=self.hy_seed, noise=self.hy_noise)
        self.frontend.attach(self.hy)
        # default: test leads open; the environment (mains pickup, emu/frontend.py ENV_DEFAULT) is not part of the
        # meter, and both live across power cycles like the stimulus
        self.stimulus = getattr(self, 'stimulus', {'kind': 'open'})
        self.frontend.set_stimulus(self.stimulus)
        self.environment = getattr(self, 'environment', dict(self.frontend.env))
        self.frontend.set_environment(self.environment)
        if hasattr(self.frontend, 'set_pa4'):        # board temperature <-> PA4 thermistor (frontend.py)
            self.frontend.set_pa4(self.analog['PA4'], self.adc.vref_volts)
        # images.  With a bootloader image the core boots through it (boot_base 0x08000000); without one it starts the
        # application from its vector table (direct boot, DIRECT_BOOT_NOTE)
        if self.bootloader_path:
            m.load(FLASH_BASE, open(self.bootloader_path, 'rb').read())
        else:
            m.boot_base = APP_BASE
        if self.app_path:                       # no image: the meter stays dark (advance() / loop() do not run the core)
            m.load(APP_BASE, open(self.app_path, 'rb').read())
        m.load(INFO_BASE, parse_option_bytes(self.option_path) if self.option_path else synthetic_option_bytes())
        if self.eeprom_path:
            m.load(EEPROM_BASE, open(self.eeprom_path, 'rb').read())
        self.flash.reset()
        if self.hw_cal is None:                 # first build: the physical calibration is the EEPROM as loaded
            hw = bytearray(m.eeprom)
            if self.hw_cal_path:
                img = open(self.hw_cal_path, 'rb').read()
                hw[:len(img)] = img[:len(hw)]
            self.hw_cal = bytes(hw)
        self.frontend.hw_cal = self.hw_cal
        if self.v205_path:                      # original image supplied: its tables override the table data
            self.frontend.v205_image = open(self.v205_path, 'rb').read()
        else:
            self.frontend.v205_tables = self.tables
        # board
        self.board = Board(self.gpio)
        self.board.keys = set(self.board_state['keys'])
        self.board.dial = self.board_state['dial']
        self.board.jacks = set(self.board_state['jacks'])
        self.board.apply()
        self.frontend.board = self.board            # dial position for the netlist backend's rotary row
        self.safety = Safety(self)                  # hardware-safety monitor (emu/safety.py), stops the run on damage
        m.reset()

    def power_cycle(self):
        """Remove and restore power: everything except the EEPROM content restarts."""
        with self.lock:
            ee = bytes(self.m.eeprom)
            self.nju.detach()
            self.board_state = {'keys': set(self.board.keys), 'dial': self.board.dial, 'jacks': set(self.board.jacks),
                                'analog': dict(self.analog)}
            self.build()
            self.m.eeprom[:] = ee

    def system_reset(self, why):
        """System reset of the MCU in place (RM0038 6.1.1), as opposed to power_cycle() which is a power reset.
        `why` is the Machine.request_reset() reason (RCC.REQUEST_KIND) and selects the RCC_CSR reset flag.

        Kept (RM0038 6.1.1: "a system reset sets all registers to their reset values unless specified otherwise"):
          * SRAM and the data EEPROM (memories, no reset line); program flash and the option bytes
          * the RTC domain: RTC registers and backup registers (RM0038 6.1.3, 20.3.7, 20.6.x "System reset: not
            affected"), LSE and its start-up, RTCSEL / RTCEN / RTCRST / LSEBYP / CSS-on-LSE bits and the reset flags
            of RCC_CSR (RM0038 6.3.14), RCC_CR.RTCPRE / HSEBYP (6.3.1), PWR_CSR.SBF (5.4.2), DBGMCU_CR (30.16.3)
          * virtual time: the cycle counter, the elapsed-time record and every event of the chips outside the MCU
        Reset to their reset values: all other peripheral registers, the NVIC / SysTick / SCB (PM0056 4.3 - 4.5) and
        the CPU (PM0056 2.1.3: vector table at 0x08000000, boot from flash, so the bootloader runs again).
        Not touched: HY3131, NJU6350, the SD card and the board inputs, which the MCU reset does not reset.  Their
        connections to the MCU pins see the pins go to the reset state (inputs) and follow it.  Every event
        the reset peripherals scheduled earlier stays in the machine's queue but is void: each model's generation
        counter was advanced by its reset."""
        with self.lock:
            m = self.m
            m.reset_request = None
            m.log.append((m.cycles, f'system reset ({why})'))
            # RCC first: sets the reset flag, restores the MSI system clock and the reset values of the peripheral
            # clock enables; PWR and FLASH follow (DBP = 0 write-protects the RTC again, 20.3.5; the option bytes are
            # loaded again into FLASH_OBR / FLASH_WRPRx, 3.5)
            self.rcc.reset_for_request(why)
            self.pwr.reset('system')
            self.flash.reset()
            self.syscfg.reset(full=True)
            # the EXTI registers go first so that the pin changes below cannot set pending bits
            self.exti.reset()
            for port in self.gpio.values():
                port.reset()                    # pins return to inputs (RM0038 7.3.1), the chips on them see it
            self.board.apply()                  # front-panel inputs drive their pins again
            self.exti.resync()
            for periph in (self.lcd, self.adc, self.dma1, self.dma2, self.sdio, self.usart2, self.tim2, self.tim3,
                           self.tim11):
                periph.reset()
            self.rtc.reset('system')            # after the RCC: it may have changed the RTC clock
            m.nvic.reset()
            m.reset()

    # ------------------------------------------------------------------ run thread
    def _run_slice(self, cycles):
        """Run the machine for `cycles` core clock cycles (caller holds the lock); a requested reset is performed, a stop
        halts the run.  Returns the stop reason (None when the CPU did not stop)."""
        stop = self.m.run(cycles)
        if self.m.reset_request:
            self.system_reset(self.m.reset_request)
        if stop:
            self.running = False
        return stop

    def advance(self, seconds, slice_ms=10):
        """Run for `seconds` of emulated time without pacing: the headless interface (emulator/API.md, Python API).  Does
        nothing while the meter is off (dial at OFF) or paused.  Returns the stop reason or None."""
        done, stop = 0.0, None
        while done < seconds - 1e-12 and stop is None:
            with self.lock:
                if not self.running or not self.app_path or not self.board.powered():
                    return None
                stop = self._run_slice(int(self.m.sysclk_hz * slice_ms / 1000))
            done += slice_ms / 1000
        return stop

    def loop(self):
        slice_ms = 10
        while True:
            if not self.running or not self.app_path or not self.board.powered():
                time.sleep(0.02)
                continue
            t0 = time.monotonic()
            with self.lock:
                self._run_slice(int(self.m.sysclk_hz * slice_ms / 1000 * self.speed))
            dt = time.monotonic() - t0
            # always yield outside the lock: when emulation runs slower than real time the UI thread would
            # otherwise wait for an unfair lock release and /state answers late
            time.sleep(max(0.001, slice_ms / 1000 - dt))

    # ------------------------------------------------------------------ SD card
    def sd_snapshot(self):
        card = self.sdcard
        if card is None:
            return {'configured': False, 'present': False}
        d = {'configured': True, 'present': self.sd_inserted, 'image': os.path.basename(card.path),
             'capacity_mb': card.capacity // (1024 * 1024)}
        d.update(card.snapshot())
        return d

    def set_sdcard(self, present):
        """Insert or remove the card (the image file stays).  Raises ValueError when no image was configured."""
        if self.sdcard is None:
            raise ValueError('no SD card image configured (start with --sdcard PATH)')
        self.sd_inserted = bool(present)
        self.sdio.set_card(self.sdcard if self.sd_inserted else None)

    # ------------------------------------------------------------------ UI interface
    def machine_info(self):
        """What the emulated meter was started with (GET /state 'machine'): the application image (bundled build name or
        file name), the boot mode, the EEPROM source and where the v2.05 tables come from."""
        return {'firmware': self.firmware_name or os.path.basename(self.app_path or ''),
                'firmware_bundled': self.firmware_name is not None,
                'firmware_tag': self.firmware_tag,
                'firmware_note': self.firmware_note,
                'firmware_loaded': bool(self.app_path),
                'firmware_choices': [{'name': n, 'label': label} for n, (_, label) in fetch.BUILDS.items()],
                'boot': 'bootloader' if self.bootloader_path else 'direct',
                'boot_note': None if self.bootloader_path else DIRECT_BOOT_NOTE,
                'eeprom': self.eeprom_kind,
                'eeprom_note': ('SYNTHETIC calibration made up for the emulator, not a real meter\'s'
                                if self.eeprom_kind == 'synthetic' else None),
                'option_bytes': 'file' if self.option_path else 'synthetic',
                'v205_tables': 'original image' if self.v205_path else 'table data'}

    def snapshot(self):
        with self.lock:
            m = self.m
            return {
                'running': self.running and bool(self.app_path) and self.board.powered(),
                'time_ms': float(m.elapsed_s()) * 1000,
                'sysclk': m.sysclk_hz,
                'lcd': list(self.lcd.display[:8]),
                'lcd_on': bool(self.lcd.enabled) and self.board.powered(),
                'backlight': self.board.outputs.get('backlight', 0),
                'buzzer': self.board.outputs.get('buzzer', 0),
                'dial': self.board.dial,
                'keys': sorted(self.board.keys),
                'jacks': sorted(self.board.jacks),
                'unmodelled': len(m.unmodelled),
                'analog': self.analog,
                'battery': self.analog['PA5'] / BAT_SENSE_RATIO,
                'stimulus': self.frontend.stim,
                'environment': dict(self.frontend.env),
                'frontend': dict(self.frontend.status(), error=self.frontend_error),
                'hy3131': self.hy.snapshot(),
                'sdcard': self.sd_snapshot(),
                'stop': m._stop_reason,
                'machine': self.machine_info(),
                'safety': list(self.safety.violations),
                'log': [f'{c / max(1, m.sysclk_hz) * 1000:10.3f} ms  {t}' for c, t in m.log[-200:]],
            }

    def command(self, c):
        """One UI / test command (ui/server.py POST /input).  'input' sets the stimulus at the jacks:
        {'kind': 'open' | 'V' | 'A' | 'ohm' | 'Hz' | 'F' | 'degC' | 'diode' | 'VA', 'value': x, 'ac': bool,
         'freq': Hz, 'duty': 0..1, 'width': s, 'dc': V, 'amps': A, 'board': degC or None}
        (meaning of each field: emu/frontend.py module docstring; 'open' = test leads open, the default).
        'environment' sets the mains pickup around the meter (environment, not meter; emu/frontend.py ENV_DEFAULT):
        {'pickup_hz': 50 | 60, 'pickup_v': V rms of the open-circuit source (0 = shielded / off), 'coupling_pf': pF,
         'drift': 0..<1}; keys left out keep their value.  A 'board' temperature also sets the PA4
        thermistor voltage; an 'analog' PA4 command sets the voltage directly and the board temperature follows it.
        Currents flow only through a plugged current jack ('jack' command, A or mA).
        {'firmware': name} switches to a release build (machine_info()['firmware_choices'], fetched by select_firmware())
        and power cycles;
        load_app() runs an image given as bytes (the page's "load firmware file")."""
        if 'firmware' in c:                      # may download: not under the lock
            return self.select_firmware(c['firmware'])
        with self.lock:
            if 'key' in c:
                self.board.key(c['key'], bool(c['down']))
            elif 'dial' in c:
                was = self.board.powered()
                self.board.set_dial(int(c['dial']))
                if self.board.powered() and not was:
                    self.power_cycle()          # power restored: cold start
            elif 'jack' in c:
                self.board.jack(c['jack'], bool(c['plugged']))
            elif 'run' in c:
                self.running = bool(c['run'])
            elif 'reset' in c:
                self.power_cycle(); self.running = True
            elif 'sysreset' in c:                # same as the firmware writing SCB_AIRCR.SYSRESETREQ; no UI button
                self.system_reset('AIRCR.SYSRESETREQ')
            elif 'battery' in c:
                # battery (B+) voltage: PA5 sees it through R69 1M / R70 330k (analysis/frontend_netlist.md, battery
                # sense: B+ - R69 - LOW_BAT (PA5) - R70 - VSS; ratio 330/1330 at printed values)
                vbat = float(c['battery'])
                if not 0.0 <= vbat <= 12.0:
                    raise ValueError('battery voltage out of range 0..12 V')
                self.analog['PA5'] = vbat * BAT_SENSE_RATIO
                self.adc.set_channel_volts(5, self.analog['PA5'])
            elif 'analog' in c:
                pin, volts = c['analog'], float(c['volts'])
                ch = {'PA5': 5, 'PA4': 4}[pin]
                self.analog[pin] = volts
                self.adc.set_channel_volts(ch, volts)
                if pin == 'PA4' and hasattr(self.frontend, 'set_pa4'):
                    self.frontend.set_pa4(volts, self.adc.vref_volts)
                    self.frontend.clear_board()
                    self.stimulus = dict(self.frontend.stim)
            elif 'input' in c:
                self.frontend.set_stimulus(c['input'])
                self.stimulus = dict(self.frontend.stim)
                v = self.frontend.pa4_volts(self.adc.vref_volts) if hasattr(self.frontend, 'pa4_volts') else None
                if v is not None:                   # board temperature -> PA4 thermistor voltage
                    self.analog['PA4'] = v
                    self.adc.set_channel_volts(4, v)
                    self.frontend.set_pa4(v, self.adc.vref_volts)
            elif 'environment' in c:
                self.frontend.set_environment(c['environment'])
                self.environment = dict(self.frontend.env)
            elif 'sdcard' in c:
                self.set_sdcard(c['sdcard'])
            elif 'speed' in c:
                self.speed = float(c['speed'])
            else:
                raise ValueError('unknown command')

    def select_firmware(self, name):
        """Run release build `name`: fetched (or taken from the cache) outside the lock, so the meter keeps running
        during a download, then a power cycle with the new image (EEPROM, board inputs and clock chip stay, as when a
        meter is updated).  Raises ValueError when the build is unknown or cannot be had (the meter is unchanged)."""
        if name not in fetch.BUILDS:
            raise ValueError(f'unknown firmware {name!r}; builds: {list(fetch.BUILDS)}')
        try:
            path, tag, note = fetch.fetch(name, check_app_image)
        except fetch.FirmwareUnavailable as e:
            raise ValueError(str(e)) from e
        with self.lock:
            self.firmware_name, self.firmware_tag, self.firmware_note, self.app_path = name, tag, note, path
            self.power_cycle(); self.running = True

    def load_app(self, data, name):
        """Run the application image `data` (bytes, file name `name` for the display) instead of the present firmware:
        checked with check_app_image() (ValueError with the reasons when it fails), kept in a temporary file for the
        power cycles to come, then a power cycle as for a bundled build (EEPROM, board inputs and clock chip stay)."""
        problems = check_app_image(data)
        if problems:
            raise ValueError('not a 121GW application image: ' + '; '.join(problems))
        safe = ''.join(ch if ch.isalnum() or ch in '._-' else '_' for ch in os.path.basename(name or ''))[:80] or 'firmware.bin'
        if not getattr(self, '_upload_dir', None):
            import tempfile, atexit, shutil
            self._upload_dir = tempfile.mkdtemp(prefix='121gw-fw-')
            atexit.register(shutil.rmtree, self._upload_dir, True)
        path = os.path.join(self._upload_dir, safe)
        with open(path, 'wb') as f:
            f.write(data)
        with self.lock:
            self.firmware_name, self.firmware_tag, self.firmware_note, self.app_path = None, None, None, path
            self.power_cycle(); self.running = True


def start_server(emu, port, tries=1):
    """Start the UI server on `port`, or on the next free port of the following tries - 1.  Returns (httpd, port).
    An occupied port is reported with the option that changes it, never swallowed."""
    from ui.server import serve
    last = None
    for p in range(port, port + tries):
        try:
            return serve(emu, p), p
        except OSError as e:
            last = e
    raise SystemExit(f'cannot start the UI server on port {port}' + (f'..{port + tries - 1}' if tries > 1 else '')
                     + f': {last} (--port N chooses another port)')


def main(argv=None, on_ready=None):
    """Command-line entry.  on_ready(url): called once the UI server is up (launcher.py opens its window then)."""
    ap = argparse.ArgumentParser(description='121GW emulator (module docstring: bundled data, direct boot, original images)')
    ap.add_argument('--inputs', metavar='DIR', help='directory with bootloader.bin, EEVBlog2_05.bin, option.bytes (default: '
                    'inputs/binaries of the source tree when it exists)')
    ap.add_argument('--no-inputs', action='store_true', help='do not use inputs/binaries of the source tree')
    ap.add_argument('--app', metavar='FILE', help='application image (default: inputs/EEVBlog2_05.bin, else the release build --firmware)')
    ap.add_argument('--firmware', choices=list(fetch.BUILDS), default=None,
                    help='release build fetched on demand from GitHub and cached (default %s)' % fetch.DEFAULT_BUILD)
    ap.add_argument('--eeprom', metavar='FILE', help='EEPROM image, raw bytes from offset 0 (default: bundled SYNTHETIC image)')
    ap.add_argument('--bootloader', metavar='FILE', help='bootloader image: boot through it instead of starting the application directly')
    ap.add_argument('--option-bytes', metavar='FILE', help="OpenOCD 'mdb 0x1FF80000 256' dump (default: synthetic option bytes)")
    ap.add_argument('--v205-image', metavar='FILE', help='original v2.05 image: the front end reads its tables from it')
    ap.add_argument('--tables', metavar='FILE', help='v2.05 table data file (default: the bundled v205_tables.json)')
    ap.add_argument('--hw-cal', help='EEPROM image describing the physical calibration of the front end '
                    '(default: the EEPROM as loaded at start)')
    ap.add_argument('--port', type=int, default=8121)
    ap.add_argument('--port-tries', type=int, default=1, metavar='N',
                    help='try N consecutive ports from --port until one is free (default 1)')
    ap.add_argument('--speed', type=float, default=1.0)
    ap.add_argument('--no-ui', action='store_true')
    ap.add_argument('--open', action='store_true', help='open the UI in the default browser once the server is up')
    ap.add_argument('--frontend', choices=['calibrated', 'netlist'], default='calibrated')
    ap.add_argument('--sdcard', metavar='PATH', help='raw SD card image file (created and formatted FAT32 when missing)')
    ap.add_argument('--sdcard-mb', type=int, default=512, help='size in MiB of a newly created card image (default 512)')
    a = ap.parse_args(argv)
    if a.app and a.firmware:
        ap.error('--app and --firmware are alternatives')
    Emulator.frontend_kind = a.frontend
    Emulator.sdcard_path, Emulator.sdcard_mb = a.sdcard, a.sdcard_mb
    inputs = a.inputs
    if inputs is None and not a.no_inputs:                  # the earlier default, used when the directory exists
        d = os.path.join(HERE, '..', 'inputs', 'binaries')
        inputs = d if os.path.isdir(d) else None
    emu = Emulator(inputs, a.app, a.eeprom, a.speed, hw_cal=a.hw_cal, bootloader=a.bootloader, option_bytes=a.option_bytes,
                   v205_image=a.v205_image, tables=a.tables, firmware=a.firmware)
    info = emu.machine_info()
    print(f"121GW emulator: firmware {info['firmware']}{' ' + info['firmware_tag'] if info['firmware_tag'] else ''}, "
          f"boot {info['boot']}, EEPROM {info['eeprom']}, "
          f"v2.05 tables from {info['v205_tables']}", flush=True)
    if info['firmware_note']:
        print('  firmware: ' + info['firmware_note'], flush=True)
    if info['boot_note']:
        print('  ' + info['boot_note'], flush=True)
    if info['eeprom_note']:
        print('  EEPROM: ' + info['eeprom_note'], flush=True)
    if not a.no_ui:
        _, port = start_server(emu, a.port, a.port_tries)
        url = f'http://127.0.0.1:{port}'
        print(f'121GW emulator UI: {url}', flush=True)
        if a.open:
            threading.Timer(0.5, webbrowser.open, (url,)).start()
        if on_ready:
            on_ready(url)
    emu.loop()


if __name__ == '__main__':
    main()
