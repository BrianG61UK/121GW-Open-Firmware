"""Recorder for the differential test harness: attaches to an app.Emulator from the outside and writes timestamped
event streams of everything the meter shows or does on its pins, buses and non-volatile memory.

Attachment never changes emulated behaviour: every hook is an extra observer callback, a wrapper that calls the original
function with the same arguments and returns its result, or a container subclass whose mutating methods do the
original operation and then note it.  The recorder must be re-attached after every Emulator.build() (each power cycle
builds a new Machine and new peripheral models); scenario.DiffEmulator does that.

Time.  Every event carries the exact emulated time in integer nanoseconds: base + Machine.elapsed_s() rounded to the
nanosecond, where `base` is the time at which the present machine was powered (a power cycle starts a new Machine
whose clock starts at 0).  elapsed_s() integrates the cycle count over the core clock history (emu/core.py), so the
stamp is exact to the basic block at which the event happened (the machine advances its cycle count per basic block).

Streams (name: key that is compared; extra information that is reported but not compared)
    lcd           (on, w0..w7): LCD_DISPLAY words 0..7 after each display update that changes them, and each change
                  of the display enable (LCDEN with ENS, periph/lcd.py `enabled`).  The firmware drives the glass at
                  1/4 duty, words 2c / 2c+1 = COMc (analysis/lcd_map.md section 1), so only words 0..7 reach the glass.
                  At power-off (dial OFF) an all-off frame is recorded: the glass has no supply.
                  Decoded segment names come from emulator/ui/assets/lcd_bits.json; decode_text() turns the digit
                  segments into characters with the firmware font (analysis/lcd_map.md section 2).
    gpio          (pin, level): output drive changes of every GPIO pin (level 0, 1 or None = not driving), named
                  buzzer PE7, backlight PE8, supply PE9, ble_supply PF15 (emu/board.py, analysis/ble_packet.md 1).
                  Pins whose traffic is decoded by another stream are left out by default: PF0..PF2 (HY3131 CK, CS, DI;
                  stream spi) and PB6, PB7, PC13 (NJU6350 CLK, DATA, CE; stream rtc).
    spi           (dir, addr, data): HY3131 SPI frames (emu/hy3131.py transaction log), with register names from
                  analysis/hy3131_model.md section 2.
    uart_tx       (byte,): USART2 transmitted words (periph/usart.py on_tx); ('BREAK',) for break characters.
    uart_rx       (bytes,): bytes the scenario delivered to the USART2 receiver (rx_feed).
    eeprom        (offset, old, new): every data EEPROM byte whose stored value changed, at the moment the FLASH model
                  commits it; info: pc of the CPU store that requested it.
    eeprom_store  (address, value, size): every CPU store to the data EEPROM (FLASH.cpu_store); info: pc.
    sd_cmd        (kind, index, arg): commands that reached the SD card ('CMD' or 'ACMD'); info: response given.
    sd_block      (dir, lba, sha256 of the 512 bytes): blocks read from / written to the card image.
    rtc           (text,): decoded NJU6350 frames (emu/nju6350.py frame log: register reads with the value returned,
                  writes with the value committed).
    reset         (kind, reason): power-on of a new machine, MCU system resets, firmware reset requests.
    fault         (text,): the CPU stopped (invalid access, CPU exception, hardware-safety stop), or an emulator log
                  line starting with "BRICK-GUARD", "INVALID" or "HARDWARE SAFETY" (emu/safety.py).
    unmodelled    (rw, address): first access to an address no model claims; info: pc.
    log           (text,): every emulator log line (Machine.log), info: the machine cycle count.
    step          (line, text): the scenario step that started at this time (written by the scenario runner).
    assert        (line, passed, text): assertion results (scenario runner).
End-of-run state (Recorder.final): EEPROM image, files on the SD card, last LCD frame.
"""
import collections
import hashlib
import json
import os

from unicorn.arm_const import UC_ARM_REG_PC as _PC

HERE = os.path.dirname(os.path.abspath(__file__))
LCD_BITS = os.path.join(HERE, '..', 'ui', 'assets', 'lcd_bits.json')

PIN_NAMES = {('E', 7): 'buzzer', ('E', 8): 'backlight', ('E', 9): 'supply', ('F', 15): 'ble_supply'}
EXCLUDED_PINS = {('F', 0), ('F', 1), ('F', 2), ('B', 6), ('B', 7), ('C', 13)}

# HY3131 register names (analysis/hy3131_model.md section 2, DS p17)
HY_REG = {0x00: 'AD1', 0x03: 'AD2', 0x06: 'LPF', 0x09: 'RMS', 0x0E: 'PKHMIN', 0x11: 'PKHMAX', 0x14: 'CTSTA',
          0x15: 'CTC', 0x18: 'CTB', 0x1B: 'CTA', 0x1E: 'INTF', 0x1F: 'INTE'}
HY_REG.update({a: f'R{a:02X}' for a in range(0x20, 0x38)})

# Font of the firmware (analysis/lcd_map.md section 2, FUN_0801AFFC): bit0=b bit1=a bit2=g bit3=f bit4=c bit5=e bit7=d
_FONT_BITS = {0: 'b', 1: 'a', 2: 'g', 3: 'f', 4: 'c', 5: 'e', 7: 'd'}
_DIGITS = [0xBB, 0x11, 0xA7, 0x97, 0x1D, 0x9E, 0xBE, 0x1B, 0xBF, 0x9F]
_UPPER = [0x3F, 0xBC, 0xAA, 0xB5, 0xAE, 0x2E, 0x9F, 0x3D, 0x11, 0xB1, 0x2D, 0xA8, 0xBF, 0x3B, 0xBB, 0x2F, 0x1F, 0x2A,
          0x9E, 0xAC, 0xB9, 0xB9, 0xB9, 0x1C, 0x9D, 0x86]
_LOWER = [0x3F, 0xBC, 0xA4, 0xB5, 0xAE, 0x2E, 0x9F, 0x3C, 0x10, 0xB1, 0x2D, 0xA8, 0xBF, 0x34, 0xB4, 0x2F, 0x1F, 0x24,
          0x9E, 0xAC, 0xB0, 0xB0, 0xB0, 0x1C, 0x9D, 0x86]


def _segs(byte):
    return frozenset(s for bit, s in _FONT_BITS.items() if byte >> bit & 1)


def _glyph_table():
    """segment set -> character; when several characters share a pattern the first of digits, upper case, lower case
    wins (for example 0 / O, 5 / S), so the decode of a pattern is unique."""
    t = {frozenset(): ' ', _segs(0x04): '-', _segs(0x82): '='}
    for chars, codes in ((''.join(map(chr, range(0x30, 0x3A))), _DIGITS),
                         (''.join(map(chr, range(0x41, 0x5B))), _UPPER),
                         (''.join(map(chr, range(0x61, 0x7B))), _LOWER)):
        for ch, code in zip(chars, codes):
            t.setdefault(_segs(code), ch)
    return t


GLYPHS = _glyph_table()


class LcdDecoder:
    def __init__(self, path=LCD_BITS):
        bits = json.load(open(path))
        self.bit_names = {}                     # (word, bit) -> [names]
        for k, names in bits.items():
            w, b = k[1:].split('b')
            self.bit_names[(int(w), int(b))] = list(names)

    def segments(self, words):
        out = set()
        for w, v in enumerate(words):
            for b in range(32):
                if v >> b & 1:
                    out.update(self.bit_names.get((w, b), (f'w{w}b{b}',)))
        return out

    @staticmethod
    def _row(segs, prefix, sign):
        s = '-' if sign in segs else ''
        for pos in range(1, 6):
            on = frozenset(c for c in 'abcdefg' if f'{prefix}{pos}{c}' in segs)
            s += GLYPHS.get(on, '?')
            if f'{prefix}{pos}dp' in segs:
                s += '.'
        return s

    def text(self, words):
        """(main, sub, annunciators): main and sub display text and the other lit segments (sorted names)."""
        segs = self.segments(words)
        main = self._row(segs, 'seg', 'Seg-')
        sub = self._row(segs, 'sub', 'Sub-')
        digit = {f'{p}{i}{c}' for p in ('seg', 'sub') for i in range(1, 6) for c in ('a', 'b', 'c', 'd', 'e', 'f', 'g', 'dp')}
        ann = sorted(segs - digit - {'Seg-', 'Sub-'})
        return main, sub, ann


class _StampList(list):
    """List whose append() also hands the element to a callback (Machine.log, HY3131.trace)."""
    def __init__(self, items, cb):
        super().__init__(items)
        self._cb = cb

    def append(self, item):
        super().append(item)
        self._cb(item)


class _StampDeque(collections.deque):
    def __init__(self, items, maxlen, cb):
        super().__init__(items, maxlen)
        self._cb = cb

    def append(self, item):
        super().append(item)
        self._cb(item)


class TracedEEPROM(bytearray):
    """Machine.eeprom replacement: item assignment stores as before, then reports each byte whose value changed."""
    def __init__(self, data, rec):
        super().__init__(data)
        self._rec = rec

    def __setitem__(self, key, value):
        if isinstance(key, slice):
            start, stop, step = key.indices(len(self))
            old = bytes(self[key])
            super().__setitem__(key, value)
            new = bytes(self[key])
            if self._rec.suspend_ee or old == new:
                return
            for i, (a, b) in enumerate(zip(old, new)):
                if a != b:
                    self._rec.ee_change(start + i * step, a, b)
        else:
            idx = key % len(self)
            old = self[idx]
            super().__setitem__(key, value)
            if not self._rec.suspend_ee and self[idx] != old:
                self._rec.ee_change(idx, old, self[idx])


class Recorder:
    def __init__(self, emu, gpio_all=False):
        self.emu = emu
        self.events = []                # (t_ns, stream, key, info)
        self.base_ns = 0
        self.suspend_ee = False
        self.gpio_all = gpio_all
        self.last_store_pc = None
        self.lcd_last = None
        self._wrapped_card = None
        self._wrapped_nju = None
        self.lcd = LcdDecoder()

    # ------------------------------------------------------------------ time
    def now_ns(self):
        return self.base_ns + round(self.emu.m.elapsed_s() * 1_000_000_000)

    def emit(self, stream, key, info=None):
        self.events.append((self.now_ns(), stream, key, info))

    # ------------------------------------------------------------------ attachment
    def attach(self):
        """Called after every Emulator.build(): hook the new machine and peripheral models."""
        e, m = self.emu, self.emu.m
        m.eeprom = TracedEEPROM(m.eeprom, self)
        m.log = _StampList(m.log, self._log)
        for c, text in list(m.log):
            self.emit('log', (text,), {'cycles': c})
        fl = m.flash_ctl
        orig_store = fl.cpu_store

        def cpu_store(addr, value, size, _orig=orig_store):
            pc = m.uc.reg_read(_PC)
            self.last_store_pc = pc
            self.emit('eeprom_store', (addr, value, size), {'pc': pc})
            return _orig(addr, value, size)
        fl.cpu_store = cpu_store
        orig_note = m._note

        def note(addr, rw, _orig=orig_note):
            new = (addr, rw) not in m.unmodelled
            r = _orig(addr, rw)
            if new:
                self.emit('unmodelled', (rw, addr), {'pc': m.unmodelled[(addr, rw)][0]})
            return r
        m._note = note
        for letter, port in e.gpio.items():
            for pin in range(16):
                if (letter, pin) in EXCLUDED_PINS and not self.gpio_all:
                    continue
                port.on_output(pin, self._gpio_cb(PIN_NAMES.get((letter, pin), f'P{letter}{pin}')))
        lcd = e.lcd
        lcd.on_update.append(lambda d: self._lcd_check())
        for name in ('_boundary', '_enable', 'reset'):
            orig = getattr(lcd, name)

            def wrapped(*a, _orig=orig):
                r = _orig(*a)
                self._lcd_check()
                return r
            setattr(lcd, name, wrapped)
        self._lcd_check()
        e.usart2.on_tx.append(lambda w: self.emit('uart_tx', (w,)))
        e.usart2.on_break.append(lambda: self.emit('uart_tx', ('BREAK',)))
        orig_feed = e.usart2.rx_feed

        def rx_feed(data, *a, _orig=orig_feed, **k):
            b = bytes([data]) if isinstance(data, int) else bytes(data)
            self.emit('uart_rx', (b.hex(),))
            return _orig(data, *a, **k)
        e.usart2.rx_feed = rx_feed
        e.hy.trace_on = True
        e.hy.trace = _StampList(e.hy.trace, self._spi)
        if self._wrapped_nju is not e.nju:
            e.nju.frames = _StampDeque(e.nju.frames, e.nju.frames.maxlen, lambda fr: self.emit('rtc', (fr[1],)))
            self._wrapped_nju = e.nju
        if e.sdcard is not None and self._wrapped_card is not e.sdcard:
            self._wrap_card(e.sdcard)

    def _wrap_card(self, card):
        from emu.sdcard import ACMDS
        self._wrapped_card = card
        orig_cmd, orig_rd, orig_wr = card.command, card._read_block, card._write_block

        def command(index, arg, crc_ok, _o=orig_cmd):
            kind = 'ACMD' if card.app_pending and index in ACMDS else 'CMD'
            reply = _o(index, arg, crc_ok)
            self.emit('sd_cmd', (kind, index, arg), {'crc_ok': crc_ok, 'reply': None if reply is None else
                                                     f'{reply.frame:X}'})
            return reply

        def read_block(lba, _o=orig_rd):
            d = _o(lba)
            self.emit('sd_block', ('R', lba, hashlib.sha256(d).hexdigest()[:16]))
            return d

        def write_block(lba, data, _o=orig_wr):
            r = _o(lba, data)
            self.emit('sd_block', ('W', lba, hashlib.sha256(bytes(data)).hexdigest()[:16]), {'ok': r})
            return r
        card.command, card._read_block, card._write_block = command, read_block, write_block

    # ------------------------------------------------------------------ callbacks
    def _gpio_cb(self, name):
        def cb(pin, level, cycles):
            self.emit('gpio', (name, level))
        return cb

    def power_off(self, t_ns):
        """The meter lost its supply (dial OFF): the glass shows nothing until the next power-on."""
        state = (False, (0,) * 8)
        if state != self.lcd_last:
            self.lcd_last = state
            self.events.append((t_ns, 'lcd', state, None))

    def _lcd_check(self):
        lcd = self.emu.lcd
        on = bool(lcd.enabled)
        words = tuple(lcd.display[:8])
        state = (on, words)
        if state != self.lcd_last:
            self.lcd_last = state
            self.emit('lcd', state)

    def _spi(self, item):
        _, rw, addr, data = item
        self.emit('spi', (rw, addr, bytes(data).hex()), {'reg': HY_REG.get(addr, f'0x{addr:02X}')})

    def _log(self, item):
        c, text = item
        self.emit('log', (text,), {'cycles': c})
        if text.startswith(('BRICK-GUARD', 'INVALID', 'HARDWARE SAFETY:')):
            self.emit('fault', (text,))

    def ee_change(self, off, old, new):
        self.emit('eeprom', (off, old, new), {'pc': self.last_store_pc})



def lcd_state_at(events, t_ns):
    """Last lcd event at or before t_ns: (on, words) or None."""
    last = None
    for t, s, k, _ in events:
        if t > t_ns:
            break
        if s == 'lcd':
            last = k
    return last
