"""121GW emulator application: builds the machine, loads the images, runs it and serves the UI.

Usage:
    python app.py [--inputs DIR] [--port 8121] [--speed 1.0] [--no-ui] [--frontend calibrated|netlist]
DIR holds bootloader.bin, EEVBlog2_05.bin (or another application image via --app),
option.bytes and an optional EEPROM image (--eeprom, raw bytes from offset 0).
--sdcard PATH attaches an SD card backed by the raw image file PATH (created and formatted FAT32 with --sdcard-mb MiB if
it does not exist; nothing outside PATH is written).  Without it the SD socket is empty.
"""
import argparse, os, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from emu.core import Machine, FLASH_BASE, EEPROM_BASE, INFO_BASE
from emu.scs import SCS
from emu.board import Board, DIAL
from emu.periph.rcc import RCC
from emu.periph.pwr import PWR
from emu.periph.flash import FLASH
from emu.periph.gpio import make_ports, GPIO_BASES, GPIO_SIZE
from emu.periph.syscfg import SYSCFG
from emu.periph.exti import EXTI
from emu.periph.lcd import LCD
from emu.periph.tim import Tim
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

APP_BASE = 0x08006000
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


class Emulator:
    # HY3131 front end: backend 'calibrated' or 'netlist' (emu/frontend.py), noise on/off and RNG seed
    frontend_kind = 'calibrated'
    hy_noise = True
    hy_seed = None
    # SD card image (emu/sdcard.py): path of the raw image or None for an empty socket, and its size when it is created
    sdcard_path = None
    sdcard_mb = 512

    def __init__(self, inputs, app=None, eeprom=None, speed=1.0, hw_cal=None):
        self.inputs = inputs
        # physical calibration of the emulated front end (frontend._Base.hw_cal): the EEPROM as first loaded, or the
        # image given here (raw bytes from EEPROM offset 0), kept across power cycles and firmware EEPROM writes
        self.hw_cal = None
        self.hw_cal_path = hw_cal
        self.app_path = app or os.path.join(inputs, 'EEVBlog2_05.bin')
        self.eeprom_path = eeprom
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
        self.rcc, self.pwr, self.flash = RCC(), PWR(), FLASH(allow_protected=False)
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
        # images
        m.load(FLASH_BASE, open(os.path.join(self.inputs, 'bootloader.bin'), 'rb').read())
        m.load(APP_BASE, open(self.app_path, 'rb').read())
        m.load(INFO_BASE, parse_option_bytes(os.path.join(self.inputs, 'option.bytes')))
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
        self.frontend.v205_image = open(os.path.join(self.inputs, 'EEVBlog2_05.bin'), 'rb').read()
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
            for periph in (self.lcd, self.adc, self.dma1, self.dma2, self.sdio, self.usart2, self.tim2, self.tim3):
                periph.reset()
            self.rtc.reset('system')            # after the RCC: it may have changed the RTC clock
            m.nvic.reset()
            m.reset()

    # ------------------------------------------------------------------ run thread
    def loop(self):
        slice_ms = 10
        while True:
            if not self.running or not self.board.powered():
                time.sleep(0.02)
                continue
            t0 = time.monotonic()
            with self.lock:
                cyc = int(self.m.sysclk_hz * slice_ms / 1000 * self.speed)
                stop = self.m.run(cyc)
                if self.m.reset_request:
                    self.system_reset(self.m.reset_request)
                if stop:
                    self.running = False
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
    def snapshot(self):
        with self.lock:
            m = self.m
            return {
                'running': self.running and self.board.powered(),
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
        Currents flow only through a plugged current jack ('jack' command, A or mA)."""
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--inputs', default=os.path.join(HERE, '..', 'inputs', 'binaries'))
    ap.add_argument('--app'); ap.add_argument('--eeprom')
    ap.add_argument('--hw-cal', help='EEPROM image describing the physical calibration of the front end '
                    '(default: the EEPROM as loaded at start)')
    ap.add_argument('--port', type=int, default=8121)
    ap.add_argument('--speed', type=float, default=1.0)
    ap.add_argument('--no-ui', action='store_true')
    ap.add_argument('--frontend', choices=['calibrated', 'netlist'], default='calibrated')
    ap.add_argument('--sdcard', metavar='PATH', help='raw SD card image file (created and formatted FAT32 when missing)')
    ap.add_argument('--sdcard-mb', type=int, default=512, help='size in MiB of a newly created card image (default 512)')
    a = ap.parse_args()
    Emulator.frontend_kind = a.frontend
    Emulator.sdcard_path, Emulator.sdcard_mb = a.sdcard, a.sdcard_mb
    emu = Emulator(a.inputs, a.app, a.eeprom, a.speed, hw_cal=a.hw_cal)
    if not a.no_ui:
        from ui.server import serve
        serve(emu, a.port)
        print(f'121GW emulator UI: http://127.0.0.1:{a.port}', flush=True)
    emu.loop()


if __name__ == '__main__':
    main()
