"""Scenario language and deterministic runner of the differential test harness.

A scenario is a list of timed steps run on one firmware image in the emulator.  The meter starts switched OFF
(dial position 0) at emulated time 0; the scenario turns the dial to power it.  Steps run one after the other; only
`wait`, `press`, `long`, `combo` and `powercycle` take emulated time.  The same scenario can be written as plain text
(one step per line, parse()) or built with the Python API (Scenario methods of the same names).

Plain-text format ('#' starts a comment; times in seconds; keys MODE SETUP MINMAX MEM RANGE HOLD REL PEAK):
    source <text>                      where the expected behaviour comes from (spec section / firmware address); repeatable
    flag <destructive|sd|long>         destructive: changes calibration records; sd: an SD card image is attached;
                                       long: takes more than a few emulated minutes
    sdfile <NAME.EXT> eeprom [<off>=<value>...]   before the run, copy the EEPROM image given to the harness onto the
                                       card as NAME.EXT, with the listed bytes changed
    eeprompatch <off>=<value> [...]    change bytes of the private EEPROM copy before the run (another unit's data)
    rtc <YYYY-MM-DD> <HH:MM:SS>        calendar of the NJU6350 clock chip when the run starts (default 2026-01-01 12:00:00)
    dial <0..9|off|lowz|v|mv|hz|ohm|va|ua|a>   turn the dial (emu/board.py DIAL order); leaving OFF powers the meter
    down <KEY> [<KEY>...] / up <KEY> [<KEY>...]    press / release keys without taking time
    press <KEY> [hold=<s>] [gap=<s>]   key down for `hold` (0.15) then up, then `gap` (0.35) of idle time
    long <KEY> [hold=<s>] [gap=<s>]    as press with hold 1.0 and gap 0.5 (long press: 50 ticks, keys_setup.md 2.1)
    combo <K1>+<K2>[+...] [hold=<s>] [gap=<s>]     several keys together (hold 1.0, gap 0.5)
    wait <s>
    jack <A|mA|COM|V> <in|out>
    input <kind> <value> [ac] [freq=<Hz>] [duty=<0..1>] [width=<s>] [dc=<V>] [amps=<A>] [board=<degC>]
                                       stimulus at the jacks (app.Emulator.command 'input', emu/frontend.py)
    analog <PA4|PA5> <volts>           thermistor / battery sense voltage
    powercycle [off=<s>]               dial to OFF, wait `off` (1.0), dial back to the previous position
    sd <insert|remove>
    ble <hex byte> [<hex byte>...]     bytes delivered to the USART2 receiver (analysis/ble_packet.md section 6)
    sysreset                           MCU system reset (SCB_AIRCR.SYSRESETREQ)
    mark <label>                       named time point for `since` in assertions
    expect lcd <main|sub> "<text>"     decoded display text (trace.LcdDecoder.text), exact
    expect lcd <main_chars|sub_chars> "<text>"     the same without the decimal points
    expect lcd <on|off>
    expect seg <NAME> <on|off>         one LCD element by its lcd_bits.json name
    expect eeprom <off> == <value>     present data EEPROM byte
    expect eeprom_written <off>[..<off>] [since <mark>]    at least one committed change in the range
    expect eeprom_unchanged <off>..<off> [since <mark>]    no committed change in the range
    expect gpio <name> <0|1|None>      present output drive of a pin (trace.PIN_NAMES names or P<port><pin>)
    expect uart_tx >= <n> [since <mark>]
    expect sdfile <NAME> [size=<n>]    file present on the card (path such as /CAL.BIN)

Determinism: the HY3131 noise generator is seeded (one seed for every run of a comparison; it can be switched off
for images whose timing differs, because a time shift below 1 us already changes the noise drawn for a conversion), the NJU6350 calendar starts
from the scenario's `rtc` value and counts emulated time only (the time the meter is OFF is the scripted OFF time), the
SD card image is created fresh for every run, and the EEPROM image is read from a private copy.
"""
import os
import re
import shlex
import shutil
import sys
import tempfile
import time
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
EMU = os.path.normpath(os.path.join(HERE, '..'))
if EMU not in sys.path:
    sys.path.insert(0, EMU)

from app import Emulator                         # noqa: E402
from emu.board import KEYS                       # noqa: E402
from emu.nju6350 import NJU6350                  # noqa: E402
from emu.sdcard import format_fat32              # noqa: E402
from diff import fat32                           # noqa: E402
from diff.trace import Recorder, PIN_NAMES       # noqa: E402

DIAL_NAMES = {'off': 0, 'lowz': 1, 'v': 2, 'mv': 3, 'hz': 4, 'ohm': 5, 'va': 6, 'ua': 7, 'a': 8}
FLAGS = {'destructive', 'sd', 'long'}
SD_MB = 64                                       # smallest FAT32 image emu/sdcard.format_fat32 accepts
NS = 1_000_000_000


class ScenarioError(ValueError):
    pass


class Step:
    __slots__ = ('op', 'args', 'line', 'text')

    def __init__(self, op, args, line=0, text=''):
        self.op, self.args, self.line, self.text = op, args, line, text or op


class Scenario:
    """Python API: each method appends one step and returns self."""
    def __init__(self, name, sources=(), flags=(), rtc='2026-01-01 12:00:00', path=None):
        self.name = name
        self.sources = list(sources)
        self.flags = set(flags)
        self.rtc = rtc
        self.sdfiles = []                        # (name, 'eeprom', {offset: value})
        self.eeprompatch = {}                    # offset -> value applied to the private EEPROM copy
        self.steps = []
        self.path = path

    def _add(self, op, line=0, text='', **args):
        self.steps.append(Step(op, args, line, text))
        return self

    def dial(self, pos, line=0, text=''):
        p = DIAL_NAMES.get(str(pos).lower(), None)
        p = int(pos) if p is None else p
        if not 0 <= p <= 9:
            raise ScenarioError(f'dial position {pos} out of range')
        return self._add('dial', line, text, pos=p)

    def down(self, *keys, line=0, text=''):
        return self._add('keys', line, text, keys=_keys(keys), down=True)

    def up(self, *keys, line=0, text=''):
        return self._add('keys', line, text, keys=_keys(keys), down=False)

    def press(self, key, hold=0.15, gap=0.35, line=0, text=''):
        return self._add('press', line, text, keys=_keys([key]), hold=hold, gap=gap)

    def long(self, key, hold=1.0, gap=0.5, line=0, text=''):
        return self._add('press', line, text, keys=_keys([key]), hold=hold, gap=gap)

    def combo(self, keys, hold=1.0, gap=0.5, line=0, text=''):
        """keys: 'K1+K2' or a list of key names."""
        return self._add('press', line, text, keys=_keys([keys] if isinstance(keys, str) else keys), hold=hold, gap=gap)

    def wait(self, secs, line=0, text=''):
        return self._add('wait', line, text, secs=float(secs))

    def jack(self, name, plugged, line=0, text=''):
        return self._add('jack', line, text, jack=name, plugged=bool(plugged))

    def input(self, kind, value, line=0, text='', **kw):
        return self._add('input', line, text, stim=dict(kind=kind, value=float(value), **kw))

    def analog(self, pin, volts, line=0, text=''):
        return self._add('analog', line, text, pin=pin, volts=float(volts))

    def powercycle(self, off=1.0, line=0, text=''):
        return self._add('powercycle', line, text, off=float(off))

    def sd(self, present, line=0, text=''):
        return self._add('sd', line, text, present=bool(present))

    def ble(self, data, line=0, text=''):
        return self._add('ble', line, text, data=bytes(data))

    def sysreset(self, line=0, text=''):
        return self._add('sysreset', line, text)

    def mark(self, label, line=0, text=''):
        return self._add('mark', line, text, label=label)

    def expect(self, what, line=0, text='', **args):
        return self._add('expect', line, text, what=what, **args)


def _keys(keys):
    out = []
    for k in keys:
        for part in str(k).upper().split('+'):
            if part not in KEYS:
                raise ScenarioError(f'unknown key {part}')
            out.append(part)
    return out


def _num(s):
    return int(s, 0)


def _range(s):
    if '..' in s:
        a, b = s.split('..')
        return _num(a), _num(b)
    return _num(s), _num(s)


def _opts(tokens, allowed):
    out = {}
    for t in tokens:
        if '=' not in t:
            raise ScenarioError(f'unexpected token {t!r}')
        k, v = t.split('=', 1)
        if k not in allowed:
            raise ScenarioError(f'unknown option {k}')
        out[k] = float(v)
    return out


def _since(tokens):
    if not tokens:
        return None
    if len(tokens) != 2 or tokens[0] != 'since':
        raise ScenarioError(f'expected "since <mark>", got {" ".join(tokens)}')
    return tokens[1]


def parse(text, name='scenario', path=None):
    """Plain text (module docstring) -> Scenario."""
    sc = Scenario(name, path=path)
    marks = set()
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        try:
            if line.split(None, 1)[0].lower() == 'source':        # free text, kept as written
                sc.sources.append(line.split(None, 1)[1] if ' ' in line else '')
                continue
            t = shlex.split(line, comments=True, posix=True)
            if not t:
                continue
            op, a = t[0].lower(), t[1:]
            kw = dict(line=n, text=line)
            if op == 'flag':
                for f in a:
                    if f not in FLAGS:
                        raise ScenarioError(f'unknown flag {f}')
                    sc.flags.add(f)
            elif op == 'sdfile':
                if len(a) < 2 or a[1] != 'eeprom':
                    raise ScenarioError('sdfile <NAME.EXT> eeprom [<off>=<value>...]')
                patch = {}
                for tok in a[2:]:
                    o, _, v = tok.partition('=')
                    patch[_num(o)] = _num(v)
                    if not 0 <= patch[_num(o)] <= 0xFF:
                        raise ScenarioError(f'patch value {v} is not a byte')
                sc.sdfiles.append((a[0].upper(), 'eeprom', patch))
                sc.flags.add('sd')
            elif op == 'eeprompatch':
                if not a:
                    raise ScenarioError('eeprompatch <off>=<value> [...]')
                for tok in a:
                    o, _, v = tok.partition('=')
                    if not 0 <= _num(v) <= 0xFF:
                        raise ScenarioError(f'patch value {v} is not a byte')
                    sc.eeprompatch[_num(o)] = _num(v)
            elif op == 'rtc':
                if len(a) != 2 or not re.fullmatch(r'\d{4}-\d\d-\d\d', a[0]) or not re.fullmatch(r'\d\d:\d\d:\d\d', a[1]):
                    raise ScenarioError('rtc YYYY-MM-DD HH:MM:SS')
                sc.rtc = f'{a[0]} {a[1]}'
            elif op == 'dial':
                sc.dial(a[0], **kw)
            elif op in ('down', 'up'):
                (sc.down if op == 'down' else sc.up)(*a, **kw)
            elif op in ('press', 'long', 'combo'):
                o = _opts(a[1:], ('hold', 'gap'))
                getattr(sc, op)(a[0], **o, **kw)
            elif op == 'wait':
                sc.wait(float(a[0]), **kw)
            elif op == 'jack':
                if len(a) != 2 or a[1] not in ('in', 'out'):
                    raise ScenarioError('jack <A|mA|COM|V> <in|out>')
                sc.jack(a[0], a[1] == 'in', **kw)
            elif op == 'input':
                extra = {}
                for tok in a[2:]:
                    if tok == 'ac':
                        extra['ac'] = True
                    else:
                        k, v = tok.split('=', 1)
                        if k not in ('freq', 'duty', 'width', 'dc', 'amps', 'board'):
                            raise ScenarioError(f'unknown input option {k}')
                        extra[k] = float(v)
                extra.setdefault('ac', False)
                sc.input(a[0], float(a[1]), **extra, **kw)
            elif op == 'analog':
                if a[0] not in ('PA4', 'PA5'):
                    raise ScenarioError('analog <PA4|PA5> <volts>')
                sc.analog(a[0], float(a[1]), **kw)
            elif op == 'powercycle':
                sc.powercycle(**_opts(a, ('off',)), **kw)
            elif op == 'sd':
                if a != ['insert'] and a != ['remove']:
                    raise ScenarioError('sd <insert|remove>')
                sc.sd(a[0] == 'insert', **kw)
                sc.flags.add('sd')
            elif op == 'ble':
                sc.ble(bytes(int(x, 16) for x in a), **kw)
            elif op == 'sysreset':
                sc.sysreset(**kw)
            elif op == 'mark':
                marks.add(a[0])
                sc.mark(a[0], **kw)
            elif op == 'expect':
                sc.expect(**_parse_expect(a, marks), **kw)
            else:
                raise ScenarioError(f'unknown step {op}')
        except (ScenarioError, ValueError, IndexError) as e:
            raise ScenarioError(f'{path or name}:{n}: {e}: {raw.strip()}') from None
    return sc


def _parse_expect(a, marks):
    what = a[0]
    r = a[1:]

    def since(tokens):
        s = _since(tokens)
        if s is not None and s not in marks:
            raise ScenarioError(f'mark {s} not defined before this line')
        return s
    if what == 'lcd' and r[0] in ('main', 'sub', 'main_chars', 'sub_chars') and len(r) == 2:
        return dict(what='lcd_text', row=r[0], value=r[1])
    if what == 'lcd' and r == ['on'] or what == 'lcd' and r == ['off']:
        return dict(what='lcd_on', value=r[0] == 'on')
    if what == 'seg' and len(r) == 2 and r[1] in ('on', 'off'):
        return dict(what='seg', name=r[0], value=r[1] == 'on')
    if what == 'eeprom' and len(r) == 3 and r[1] == '==':
        return dict(what='eeprom', off=_num(r[0]), value=_num(r[2]))
    if what in ('eeprom_written', 'eeprom_unchanged'):
        lo, hi = _range(r[0])
        return dict(what=what, lo=lo, hi=hi, since=since(r[1:]))
    if what == 'gpio' and len(r) == 2:
        return dict(what='gpio', name=r[0], value=None if r[1] == 'None' else int(r[1]))
    if what == 'uart_tx' and len(r) >= 2 and r[0] == '>=':
        return dict(what='uart_tx', n=int(r[1]), since=since(r[2:]))
    if what == 'sdfile':
        o = _opts(r[1:], ('size',))
        return dict(what='sdfile', name=r[0], size=None if 'size' not in o else int(o['size']))
    raise ScenarioError(f'unknown assertion: expect {" ".join(a)}')


def load(path):
    name = os.path.splitext(os.path.basename(path))[0]
    return parse(open(path, encoding='utf-8').read(), name=name, path=path)


def library(directory=os.path.join(HERE, 'scenarios')):
    """All scenarios of the library, sorted by name."""
    out = {}
    for fn in sorted(os.listdir(directory)):
        if fn.endswith('.txt'):
            sc = load(os.path.join(directory, fn))
            out[sc.name] = sc
    return out


# ---------------------------------------------------------------------------------------------- deterministic emulator
class FixedClockNJU(NJU6350):
    """NJU6350 whose calendar starts at a given time and counts only emulated time: the host-clock catch-up of
    NJU6350.detach()/attach() is replaced by the scripted OFF time (pending_off, seconds as a Fraction)."""
    def __init__(self, now):
        super().__init__(now=now)
        self.pending_off = Fraction(0)

    def detach(self):
        super().detach()
        self._wall = None

    def attach(self, m, ce, clk, data):
        self._phase += self.pending_off
        self.pending_off = Fraction(0)
        super().attach(m, ce, clk, data)


class DiffEmulator(Emulator):
    frontend_kind = 'calibrated'
    hy_noise = True

    def __init__(self, inputs, app, eeprom, seed, rtc, sdcard_path=None, gpio_all=False, noise=True):
        self.hy_seed = seed
        self.hy_noise = noise
        self.sdcard_path = sdcard_path
        self.sdcard_mb = SD_MB
        self._rtc = time.strptime(rtc, '%Y-%m-%d %H:%M:%S')
        self._gpio_all = gpio_all
        self.rec = None
        self.power_on_ns = 0
        super().__init__(inputs, app=app, eeprom=eeprom, speed=1.0)

    def build(self):
        if self.rec is None:                     # first build, from Emulator.__init__: meter OFF, fixed clock chip
            self.nju = FixedClockNJU(self._rtc)
            self.board_state = {'keys': set(), 'dial': 0, 'jacks': set()}
            self.rec = Recorder(self, gpio_all=self._gpio_all)
        super().build()
        self.rec.base_ns = self.power_on_ns
        self.rec.attach()

    def power_cycle(self):
        # the old machine is still current while the clock chip detaches: stamp its events at the power-on time
        self.rec.base_ns = self.power_on_ns - round(self.m.elapsed_s() * NS)
        self.rec.suspend_ee = True               # the EEPROM content carried over is not a write
        try:
            super().power_cycle()
        finally:
            self.rec.suspend_ee = False


# ---------------------------------------------------------------------------------------------- runner
class Runner:
    CHUNK_S = Fraction(1, 20)                    # longest single Machine.run() call, emulated seconds

    def __init__(self, scenario, image, inputs, eeprom, seed=1, gpio_all=False, workdir=None, keep=False, noise=True):
        self.sc = scenario
        self.image = image
        self.inputs = inputs
        self.eeprom_src = eeprom
        self.seed = seed
        self.gpio_all = gpio_all
        self.workdir = workdir
        self.keep = keep
        self.noise = noise

    # time --------------------------------------------------------------------------------------
    def now_ns(self):
        return self.e.rec.now_ns() if self.live() else self.idle_ns

    def live(self):
        return self.e.board.powered() and not self.halted

    def _emit(self, stream, key, info=None):
        self.e.rec.events.append((self.now_ns(), stream, key, info))

    def _advance(self, secs):
        target = self.now_ns() + round(Fraction(secs) * NS)
        while True:
            now = self.now_ns()
            if now >= target:
                return
            if not self.live():
                if not self.e.board.powered():
                    self.e.nju.pending_off += Fraction(target - now, NS)
                self.idle_ns = target
                return
            m = self.e.m
            n = max(1, int(min(Fraction(target - now, NS), self.CHUNK_S) * m.sysclk_hz))
            stop = m.run(n)
            if m.reset_request:
                why = m.reset_request
                self._emit('reset', ('system', why))
                self.e.system_reset(why)
            if stop:
                self._emit('fault', (f'CPU stopped: {stop}',))
                self.halted = True
                self.idle_ns = self.e.rec.now_ns()

    # steps -------------------------------------------------------------------------------------
    def _dial(self, pos):
        was = self.e.board.powered()
        if not was and 0 < pos < 9:
            self.e.power_on_ns = self.idle_ns
            self.halted = False
        if was and not (0 < pos < 9):
            self.idle_ns = self.now_ns()
        self.e.command({'dial': pos})
        if not was and self.e.board.powered():
            self._emit('reset', ('power-on', f'dial {pos}'))
        elif was and not self.e.board.powered():
            self._emit('reset', ('power-off', f'dial {pos}'))
            self.e.rec.power_off(self.idle_ns)

    def _step(self, st):
        a = st.args
        e = self.e
        if st.op == 'dial':
            self._dial(a['pos'])
        elif st.op == 'keys':
            for k in a['keys']:
                e.command({'key': k, 'down': a['down']})
        elif st.op == 'press':
            for k in a['keys']:
                e.command({'key': k, 'down': True})
            self._advance(a['hold'])
            for k in a['keys']:
                e.command({'key': k, 'down': False})
            self._advance(a['gap'])
        elif st.op == 'wait':
            self._advance(a['secs'])
        elif st.op == 'jack':
            e.command({'jack': a['jack'], 'plugged': a['plugged']})
        elif st.op == 'input':
            e.command({'input': dict(a['stim'])})
        elif st.op == 'analog':
            e.command({'analog': a['pin'], 'volts': a['volts']})
        elif st.op == 'powercycle':
            pos = e.board.dial
            self._dial(0)
            self._advance(a['off'])
            self._dial(pos)
        elif st.op == 'sd':
            e.command({'sdcard': a['present']})
        elif st.op == 'ble':
            e.usart2.rx_feed(a['data'])
        elif st.op == 'sysreset':
            self._emit('reset', ('system', 'AIRCR.SYSRESETREQ (scenario)'))
            e.command({'sysreset': True})
        elif st.op == 'mark':
            self.marks[a['label']] = self.now_ns()
        elif st.op == 'expect':
            ok, detail = self._check(a)
            self._emit('assert', (st.line, ok, st.text), {'detail': detail})
        else:
            raise ScenarioError(f'unknown step {st.op}')

    def _since_events(self, mark, stream):
        t0 = self.marks.get(mark, 0) if mark else 0
        return [ev for ev in self.e.rec.events if ev[1] == stream and ev[0] >= t0]

    def _check(self, a):
        w = a['what']
        rec = self.e.rec
        if w in ('lcd_text', 'lcd_on', 'seg'):
            on, words = rec.lcd_last
            main, sub, _ = rec.lcd.text(words)
            if w == 'lcd_text':
                got = main if a['row'].startswith('main') else sub
                if a['row'].endswith('_chars'):
                    got = got.replace('.', '')
                return got == a['value'], f'{a["row"]} display shows {got!r}'
            if w == 'lcd_on':
                return on == a['value'], f'display {"on" if on else "off"}'
            segs = rec.lcd.segments(words) if on else set()
            return (a['name'] in segs) == a['value'], f'{a["name"]} {"on" if a["name"] in segs else "off"}'
        if w == 'eeprom':
            v = self.e.m.eeprom[a['off']]
            return v == a['value'], f'EEPROM 0x{a["off"]:03X} = 0x{v:02X}'
        if w in ('eeprom_written', 'eeprom_unchanged'):
            hits = [ev for ev in self._since_events(a['since'], 'eeprom') if a['lo'] <= ev[2][0] <= a['hi']]
            desc = ', '.join(f'0x{ev[2][0]:03X}:{ev[2][1]:02X}->{ev[2][2]:02X}' for ev in hits[:12])
            ok = bool(hits) if w == 'eeprom_written' else not hits
            return ok, f'{len(hits)} committed changes in 0x{a["lo"]:03X}..0x{a["hi"]:03X}' + (f' ({desc})' if hits else '')
        if w == 'gpio':
            inv = {v: k for k, v in PIN_NAMES.items()}
            letter, pin = inv[a['name']] if a['name'] in inv else (a['name'][1], int(a['name'][2:]))
            lv = self.e.gpio[letter].output_level(pin)
            return lv == a['value'], f'{a["name"]} drive {lv}'
        if w == 'uart_tx':
            n = len(self._since_events(a['since'], 'uart_tx'))
            return n >= a['n'], f'{n} bytes transmitted'
        if w == 'sdfile':
            if self.sd_path is None:
                return False, 'no SD card attached'
            files = fat32.listing(self.sd_path)
            f = files.get(a['name']) or files.get('/' + a['name'].lstrip('/'))
            if f is None:
                return False, 'files: ' + ', '.join(sorted(files))
            ok = a['size'] is None or f.get('size') == a['size']
            return ok, f'{a["name"]} size {f.get("size")}'
        raise ScenarioError(f'unknown assertion {w}')

    # run ---------------------------------------------------------------------------------------
    def run(self):
        tmp = tempfile.mkdtemp(prefix='run-', dir=self.workdir)
        t_wall = time.time()
        try:
            ee = None
            if self.eeprom_src:
                ee = os.path.join(tmp, 'eeprom.bin')
                data = bytearray(open(self.eeprom_src, 'rb').read())
                for off, val in self.sc.eeprompatch.items():
                    if off >= len(data):
                        raise ScenarioError(f'eeprompatch offset 0x{off:X} beyond the EEPROM image')
                    data[off] = val
                open(ee, 'wb').write(data)
            elif self.sc.eeprompatch:
                raise ScenarioError('eeprompatch needs an EEPROM image')
            self.sd_path = None
            if 'sd' in self.sc.flags:
                self.sd_path = os.path.join(tmp, 'card.img')
                format_fat32(self.sd_path, SD_MB * 1024 * 1024)
                y, mo, d = (int(x) for x in self.sc.rtc.split()[0].split('-'))
                h, mi, s = (int(x) for x in self.sc.rtc.split()[1].split(':'))
                with fat32.Volume(self.sd_path, writable=True) as v:
                    for name, src, patch in self.sc.sdfiles:
                        if src != 'eeprom' or not self.eeprom_src:
                            raise ScenarioError(f'sdfile {name}: no EEPROM image given to copy')
                        data = bytearray(open(self.eeprom_src, 'rb').read())
                        for off, val in patch.items():
                            if off >= len(data):
                                raise ScenarioError(f'sdfile {name}: patch offset 0x{off:X} beyond the image')
                            data[off] = val
                        v.add_file(name, bytes(data), fat32.fat_date(y, mo, d), fat32.fat_time(h, mi, s))
            self.e = DiffEmulator(self.inputs, self.image, ee, self.seed, self.sc.rtc, self.sd_path, self.gpio_all,
                                  self.noise)
            self.idle_ns = 0
            self.halted = False
            self.marks = {}
            for st in self.sc.steps:
                self._emit('step', (st.line, st.text))
                self._step(st)
            end_ns = self.now_ns()
            rec = self.e.rec
            safety = [ev[2][0] for ev in rec.events if ev[1] == 'log' and ev[2][0].startswith('HARDWARE SAFETY:')]
            final = {'eeprom': bytes(self.e.m.eeprom), 'lcd': rec.lcd_last, 'safety': safety,
                     'sd_files': fat32.listing(self.sd_path) if self.sd_path else None,
                     'unmodelled': {f'{rw} 0x{a:08X}': (f'0x{pc:08X}', n) for (a, rw), (pc, n) in self.e.m.unmodelled.items()}}
            if self.e.sdcard is not None:
                self.e.sdcard.close()
            return {'scenario': self.sc.name, 'image': self.image, 'events': rec.events, 'final': final,
                    'end_ns': end_ns, 'wall_s': time.time() - t_wall, 'error': None}
        finally:
            if not self.keep:
                shutil.rmtree(tmp, ignore_errors=True)
