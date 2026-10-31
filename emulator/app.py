"""121GW emulator application: builds the machine, loads the images, runs it and serves the UI.

Usage:
    python app.py [--inputs DIR] [--port 8121] [--speed 1.0] [--no-ui]
DIR holds bootloader.bin, EEVBlog2_05.bin (or another application image via --app),
option.bytes and an optional EEPROM image (--eeprom, raw bytes from offset 0).
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

APP_BASE = 0x08006000


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
    def __init__(self, inputs, app=None, eeprom=None, speed=1.0):
        self.inputs = inputs
        self.app_path = app or os.path.join(inputs, 'EEVBlog2_05.bin')
        self.eeprom_path = eeprom
        self.speed = speed                  # 1.0 = real time
        self.lock = threading.RLock()
        self.running = True
        self.board_state = {'keys': set(), 'dial': 2, 'jacks': set()}
        self.log_tail = []
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
        self.lcd = LCD()
        m.add_periph(0x40002400, 0x400, self.lcd)
        self.tim2, self.tim3 = Tim(0x40000000, 28, 'TIM2'), Tim(0x40000400, 29, 'TIM3')
        m.add_periph(0x40000000, 0x400, self.tim2)
        m.add_periph(0x40000400, 0x400, self.tim3)
        self.usart2 = USART(0x40004400, 38, 'USART2')
        m.add_periph(0x40004400, 0x400, self.usart2)
        # ADC: PA5 = battery sense, PA4 = thermistor (firmware: adc_ch5_process / adc_ch4_process).
        # Defaults: 6 V pack through R69 1M / R70 330k (schematic text; topology still to be confirmed
        # on the drawing) = 1.49 V; NTC1 10k vs R38 10k at 25 C = half of VDDA.  Both are UI-adjustable.
        self.adc = ADC(vref_volts=3.3)
        m.add_periph(0x40012400, 0x400, self.adc)
        self.analog = dict(self.board_state.get('analog', {'PA5': 1.49, 'PA4': 1.65}))
        self.adc.set_channel_volts(5, self.analog['PA5'])
        self.adc.set_channel_volts(4, self.analog['PA4'])
        self.ble_rx = []
        self.usart2.on_tx.append(lambda b: self.ble_rx.append(b))
        # images
        m.load(FLASH_BASE, open(os.path.join(self.inputs, 'bootloader.bin'), 'rb').read())
        m.load(APP_BASE, open(self.app_path, 'rb').read())
        m.load(INFO_BASE, parse_option_bytes(os.path.join(self.inputs, 'option.bytes')))
        if self.eeprom_path:
            m.load(EEPROM_BASE, open(self.eeprom_path, 'rb').read())
        self.flash.reset()
        # board
        self.board = Board(self.gpio)
        self.board.keys = set(self.board_state['keys'])
        self.board.dial = self.board_state['dial']
        self.board.jacks = set(self.board_state['jacks'])
        self.board.apply()
        m.reset()

    def power_cycle(self):
        """Remove and restore power: everything except the EEPROM content restarts."""
        with self.lock:
            ee = bytes(self.m.eeprom)
            self.board_state = {'keys': set(self.board.keys), 'dial': self.board.dial, 'jacks': set(self.board.jacks),
                                'analog': dict(self.analog)}
            self.build()
            self.m.eeprom[:] = ee

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
                    why = self.m.reset_request
                    self.m.log.append((self.m.cycles, f'system reset ({why})'))
                    self.power_cycle()
                if stop:
                    self.running = False
            dt = time.monotonic() - t0
            if dt < slice_ms / 1000:
                time.sleep(slice_ms / 1000 - dt)

    # ------------------------------------------------------------------ UI interface
    def snapshot(self):
        with self.lock:
            m = self.m
            return {
                'running': self.running and self.board.powered(),
                'time_ms': self.lcd.m.cycles / max(1, m.sysclk_hz) * 1000,
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
                'stop': m._stop_reason,
                'log': [f'{c / max(1, m.sysclk_hz) * 1000:10.3f} ms  {t}' for c, t in m.log[-200:]],
            }

    def command(self, c):
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
            elif 'analog' in c:
                pin, volts = c['analog'], float(c['volts'])
                ch = {'PA5': 5, 'PA4': 4}[pin]
                self.analog[pin] = volts
                self.adc.set_channel_volts(ch, volts)
            elif 'speed' in c:
                self.speed = float(c['speed'])
            else:
                raise ValueError('unknown command')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--inputs', default=os.path.join(HERE, '..', 'inputs', 'binaries'))
    ap.add_argument('--app'); ap.add_argument('--eeprom')
    ap.add_argument('--port', type=int, default=8121)
    ap.add_argument('--speed', type=float, default=1.0)
    ap.add_argument('--no-ui', action='store_true')
    a = ap.parse_args()
    emu = Emulator(a.inputs, a.app, a.eeprom, a.speed)
    if not a.no_ui:
        from ui.server import serve
        serve(emu, a.port)
        print(f'121GW emulator UI: http://127.0.0.1:{a.port}', flush=True)
    emu.loop()


if __name__ == '__main__':
    main()
