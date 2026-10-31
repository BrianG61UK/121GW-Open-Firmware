"""Comparison of two recorded runs (trace.Recorder streams) of the same scenario, deviation allowlist, report.

Streams compared by default: the pins, buses and non-volatile memory the meter exposes - lcd, gpio, spi, uart_tx,
eeprom, rtc, sd_cmd, sd_block, reset, fault - plus the scenario assertions (assert) and the end-of-run state (final
EEPROM image, files on the SD card, last LCD frame).  'power' is derived from gpio: the changes of the supply and enable
outputs PE9, PF15, PD1, PF6, PE12 (emu/safety.py), compared on their own so that a power-sequencing difference (order,
or timing beyond the tolerance) is reported as such in the hardware-safety section of the report.  Recorded but not compared by default (reported as information):
eeprom_store (CPU store pattern inside the MCU, includes program addresses), unmodelled and log (emulator
diagnostics), uart_rx (the scenario's own input), step (the scenario's own timeline).

Alignment.  Within one stream the n-th event of one run is paired with the n-th event of the other.  A pair diverges
when the keys differ ('value') or the times differ by more than the stream's tolerance ('timing'); an event without a
partner is 'missing' / 'extra', except when every unpaired event lies within the tolerance of the end of the run (it
was only cut off by the end of the scenario).  The first divergence of a scenario is the earliest of the first
divergences of all streams.

Default time tolerances (seconds), from the clocks the original firmware runs on in the emulator:
    lcd       0.0139  one LCD frame: 1/4 duty * 2**PS * (16 + DIV) / LCDCLK = 4 * 8 * 16 / 37000 Hz = 13.84 ms
                      (lcd_init values PS = 3, DIV = 0, analysis/lcd_map.md section 1; LSI 37 kHz, periph/lcd.py)
    others    0.0101  one TIM2 tick: 261 * 161 / 4 194 304 Hz = 10.02 ms (TIM2 PSC 0x104, ARR 0xA0,
                      analysis/ble_packet.md section 2; core clock 4.194304 MHz as logged by the RCC model)
    assert    no time check (an assertion runs at the same scenario step in both runs by construction)

Deviation allowlist (default file firmware/deviations.txt; format in emu/allowlist.py): every event of either run that
matches an entry for its stream and scenario is removed from both runs before alignment, so a documented deviation does
not count as a divergence; the report lists how many events each entry removed.  Fields per stream for the conditions:
  lcd main sub on | gpio pin level | power pin level | spi dir addr data | uart_tx byte pos | eeprom offset old new |
  rtc text | sd_cmd kind index arg | sd_block dir lba | reset kind reason | fault text | assert line passed |
  eeprom_final offset | sd_files path | lcd_final main sub.
'pos' of uart_tx is the index of the byte in its burst (bytes less than 2 ms apart; a BLE status frame is one burst,
pos 0 = the start byte 0xF2, pos 18 = its checksum).
Every compared stream (and assert) also has t, step, since and boot (emu/allowlist.py): the time, the scenario line of
the latest step that acts on the meter, the seconds since it started and the seconds since the latest power-on or system
reset, so that a deviation is tied to one scenario step or to the start-up (for example the stimulus that makes it
visible) instead of to absolute times.
The mask:lcd:sub and mask:lcd:main entries clear one display row of the matching LCD events before the comparison
(fields as for lcd); see emu/allowlist.py.
The safety_* entries of the same file are applied by the hardware-safety monitor (emu/safety.py), not here; the
tolerance:<stream> entries widen the time tolerance of that stream for the matching scenarios (the report counts each
use as one "removed" event of the entry).
"""
import bisect
import re

from diff.trace import LcdDecoder
from emu import allowlist

COMPARED = ('lcd', 'gpio', 'power', 'spi', 'uart_tx', 'eeprom', 'rtc', 'sd_cmd', 'sd_block', 'reset', 'fault', 'assert')
# supply and enable outputs (emu/safety.py POWER_PINS) under their trace.py gpio names: PE9, PF15, PD1, PF6, PE12
POWER_NAMES = ('supply', 'ble_supply', 'PD1', 'PF6', 'PE12')
INFORMATION = ('eeprom_store', 'unmodelled', 'log', 'uart_rx', 'step')
DEFAULT_TOL = {'lcd': 0.0139, 'assert': None}
OTHER_TOL = 0.0101
FINAL_STREAMS = ('eeprom_final', 'sd_files', 'lcd_final')
NS = 1_000_000_000
BURST_GAP_NS = 2_000_000                   # uart_tx bytes closer than this belong to one burst (19200 baud: 0.52 ms per byte)

_LCD = None


def lcd_decoder():
    global _LCD
    if _LCD is None:
        _LCD = LcdDecoder()
    return _LCD


def timeline(events):
    """(steps, boots) of a run: steps = (time ns, scenario line) of the steps that act on the meter, in order (the 'step'
    events without wait, mark and expect, whose text starts with the step word); boots = times of the power-ons and
    system resets (the 'reset' events other than power-off)."""
    steps = [(ev[0], ev[2][0]) for ev in events
             if ev[1] == 'step' and ev[2][1].split()[:1] not in (['wait'], ['mark'], ['expect'])]
    boots = [ev[0] for ev in events if ev[1] == 'reset' and ev[2][0] != 'power-off']
    return steps, boots


def fields(stream, key, t_ns, tl=((), ()), pos=None):
    """Named fields of an event for allowlist conditions; `tl` is timeline() of its run."""
    steps, boots = tl
    f = {'t': t_ns / NS}
    i = bisect.bisect_right(steps, (t_ns, float('inf'))) if steps else 0
    f['step'], f['since'] = (steps[i - 1][1], (t_ns - steps[i - 1][0]) / NS) if i else (0, t_ns / NS)
    j = bisect.bisect_right(boots, t_ns)
    f['boot'] = (t_ns - boots[j - 1]) / NS if j else t_ns / NS
    if pos is not None:
        f['pos'] = pos
    if stream == 'lcd':
        main, sub, _ = lcd_decoder().text(key[1])
        f.update(on=int(key[0]), main=main, sub=sub)
    elif stream in ('gpio', 'power'):
        f.update(pin=key[0], level='None' if key[1] is None else key[1])
    elif stream == 'spi':
        f.update(dir=key[0], addr=key[1], data=key[2])
    elif stream == 'uart_tx':
        f.update(byte=key[0])
    elif stream == 'eeprom':
        f.update(offset=key[0], old=key[1], new=key[2])
    elif stream == 'rtc':
        f.update(text=key[0])
    elif stream == 'sd_cmd':
        f.update(kind=key[0], index=key[1], arg=key[2])
    elif stream == 'sd_block':
        f.update(dir=key[0], lba=key[1])
    elif stream == 'reset':
        f.update(kind=key[0], reason=key[1])
    elif stream == 'fault':
        f.update(text=key[0])
    elif stream == 'assert':
        f.update(line=key[0], passed=int(key[1]))
    return f


# ---------------------------------------------------------------------------------------------- allowlist
def load_allowlist(path, build=None):
    """Entries of the deviation allowlist (emu/allowlist.py format) for the candidate's build mode (baseline,
    production or None); the safety_* entries are used by emu/safety.py."""
    return [d for d in allowlist.load_allowlist(path, COMPARED + FINAL_STREAMS, build)
            if d.stream not in allowlist.SAFETY_STREAMS]


def tolerance_for(stream, scenario, devs, tol):
    """Time tolerance of a stream in a scenario: the command-line / default value, widened by tolerance entries."""
    t = tol.get(stream, DEFAULT_TOL.get(stream, OTHER_TOL))
    for d in devs:
        if d.stream == 'tolerance:' + stream and d.applies(scenario) and t is not None:
            if d.tolerance > t:
                t = d.tolerance
            d.removed += 1
    return t


# ---------------------------------------------------------------------------------------------- comparison
def split_streams(events):
    """Events by stream, plus the derived stream 'power': the gpio events of the supply and enable outputs."""
    out = {}
    for ev in events:
        out.setdefault(ev[1], []).append(ev)
    out['power'] = [(t, 'power', k, i) for t, s, k, i in out.get('gpio', ()) if k[0] in POWER_NAMES]
    return out


def _filter(stream, evs, devs, scenario, tl=((), ())):
    active = [d for d in devs if d.stream == stream and d.applies(scenario)]
    if not active:
        return evs, []
    keep, gone = [], []
    pos, last = 0, None
    for ev in evs:
        if stream == 'uart_tx':                           # position of the byte in its burst (a BLE status frame is one)
            pos = pos + 1 if last is not None and ev[0] - last < BURST_GAP_NS else 0
            last = ev[0]
        f = fields(stream, ev[2], ev[0], tl, pos if stream == 'uart_tx' else None)
        hit = next((d for d in active if d.match(f)), None)
        if hit is None:
            keep.append(ev)
        else:
            hit.removed += 1
            gone.append(ev)
    return keep, gone


def _row_masks(group):
    """Per LCD word, the bit mask of the segments of one display row: group 'lcd:sub' or 'lcd:main'."""
    dec = lcd_decoder()
    pre, sign = ('sub', 'Sub-') if group == 'lcd:sub' else ('seg', 'Seg-')
    rx = re.compile(pre + r'[1-5](?:[a-g]|dp)')
    masks = [0] * 8
    for (w, b), names in dec.bit_names.items():
        if any(rx.fullmatch(n) or n == sign for n in names) and w < 8:
            masks[w] |= 1 << b
    return masks


_ROW_MASKS = {}


def row_mask(group):
    if group not in _ROW_MASKS:
        _ROW_MASKS[group] = _row_masks(group)
    return _ROW_MASKS[group]


def _masked_key(key, masks):
    return (key[0], tuple(w & ~masks[i] if i < 8 else w for i, w in enumerate(key[1])))


def _mask_lcd(evs, devs, scenario, tl=((), ())):
    """LCD events with the rows of the matching mask entries (mask:lcd:sub, mask:lcd:main) cleared in their key; an event
    that then equals the event before it (only the cleared row changed) is dropped."""
    active = [d for d in devs if d.stream.startswith('mask:lcd') and d.applies(scenario)]
    if not active:
        return evs
    out = []
    for ev in evs:
        f = fields('lcd', ev[2], ev[0], tl)
        masks = [0] * 8
        for d in active:
            if d.match(f):
                d.removed += 1
                masks = [a | b for a, b in zip(masks, row_mask(d.stream[5:]))]
        if not any(masks):
            out.append(ev)
            continue
        ev = (ev[0], ev[1], _masked_key(ev[2], masks), ev[3])
        if out and out[-1][2] == ev[2]:
            continue                                      # only the cleared row changed: no change of what is compared
        out.append(ev)
    return out


def compare_stream(stream, a, b, tol, end_a, end_b):
    """First divergence of one stream or None.  a, b: event lists of the reference and candidate runs."""
    tol_ns = None if tol is None else round(tol * NS)
    n = min(len(a), len(b))
    for i in range(n):
        ea, eb = a[i], b[i]
        if ea[2] != eb[2]:
            return {'stream': stream, 'index': i, 'kind': 'value', 'ref': ea, 'cand': eb, 't': min(ea[0], eb[0])}
        if tol_ns is not None and abs(ea[0] - eb[0]) > tol_ns:
            return {'stream': stream, 'index': i, 'kind': 'timing', 'ref': ea, 'cand': eb, 't': min(ea[0], eb[0]),
                    'dt_s': (eb[0] - ea[0]) / NS}
    if len(a) != len(b):
        longer, end_other, kind = (a, end_b, 'extra in reference') if len(a) > len(b) else (b, end_a, 'extra in candidate')
        rest = longer[n:]
        slack = 0 if tol_ns is None else tol_ns
        if all(ev[0] >= min(end_a, end_b) - slack for ev in rest):
            return None                                   # only cut off by the end of the run
        ev = rest[0]
        return {'stream': stream, 'index': n, 'kind': kind, 'ref': ev if longer is a else None,
                'cand': ev if longer is b else None, 't': ev[0]}
    return None


def compare_final(fa, fb, devs, scenario):
    diffs = []
    act = [d for d in devs if d.applies(scenario)]
    ea, eb = fa['eeprom'], fb['eeprom']
    for off, (x, y) in enumerate(zip(ea, eb)):
        if x != y:
            hit = next((d for d in act if d.stream == 'eeprom_final' and d.match({'offset': off})), None)
            if hit:
                hit.removed += 1
            else:
                diffs.append(('eeprom_final', f'0x{off:03X}', f'0x{x:02X}', f'0x{y:02X}'))
    sa, sb = fa['sd_files'] or {}, fb['sd_files'] or {}
    for path in sorted(set(sa) | set(sb)):
        x, y = sa.get(path), sb.get(path)
        kx = None if x is None else {k: v for k, v in x.items() if k != 'data'}
        ky = None if y is None else {k: v for k, v in y.items() if k != 'data'}
        if kx != ky:
            hit = next((d for d in act if d.stream == 'sd_files' and d.match({'path': path})), None)
            if hit:
                hit.removed += 1
            else:
                diffs.append(('sd_files', path, kx, ky))
    if fa['lcd'] != fb['lcd']:
        dec = lcd_decoder()
        ta, tb = dec.text(fa['lcd'][1]), dec.text(fb['lcd'][1])
        hit = next((d for d in act if d.stream == 'lcd_final' and d.match({'main': ta[0], 'sub': ta[1]})
                    and d.match({'main': tb[0], 'sub': tb[1]})), None)
        masked = [[0] * 8, [0] * 8]
        for side, (txt, fr) in enumerate(((ta, fa['lcd']), (tb, fb['lcd']))):
            for d in act:
                if d.stream.startswith('mask:lcd') and d.match({'main': txt[0], 'sub': txt[1], 'on': int(fr[0])}):
                    masked[side] = [x | y for x, y in zip(masked[side], row_mask(d.stream[5:]))]
        if not hit and (any(masked[0]) or any(masked[1])):
            both = [x | y for x, y in zip(*masked)]
            if _masked_key(fa['lcd'], both) == _masked_key(fb['lcd'], both):
                hit = next(d for d in act if d.stream.startswith('mask:lcd'))
        if hit:
            hit.removed += 1
        else:
            diffs.append(('lcd_final', '', fa['lcd'], fb['lcd']))
    return diffs


def compare(ra, rb, devs=(), tol=None, streams=COMPARED):
    """Compare two run results (scenario.Runner.run()).  Returns a dict with the first divergence per stream, the
    overall first divergence, final-state differences and allowlist statistics."""
    tol = dict(tol or {})
    scenario = ra['scenario']
    sa, sb = split_streams(ra['events']), split_streams(rb['events'])
    per = {}
    for s in streams:
        stA, stB = timeline(ra['events']), timeline(rb['events'])
        a, _ = _filter(s, sa.get(s, []), devs, scenario, stA)
        b, _ = _filter(s, sb.get(s, []), devs, scenario, stB)
        if s == 'lcd':
            a, b = _mask_lcd(a, devs, scenario, stA), _mask_lcd(b, devs, scenario, stB)
        t = tolerance_for(s, scenario, devs, tol)
        d = compare_stream(s, a, b, t, ra['end_ns'], rb['end_ns'])
        if d:
            per[s] = d
    first = min(per.values(), key=lambda d: (d['t'], streams.index(d['stream']))) if per else None
    final = compare_final(ra['final'], rb['final'], devs, scenario)
    return {'scenario': scenario, 'per_stream': per, 'first': first, 'final': final,
            'counts': {s: (len(sa.get(s, [])), len(sb.get(s, []))) for s in sorted(set(sa) | set(sb))}}


# ---------------------------------------------------------------------------------------------- report
def fmt_t(t_ns):
    return f'{t_ns / 1e6:.6f} ms'


def fmt_event(ev):
    if ev is None:
        return '(none)'
    t, s, k, info = ev
    if s == 'lcd':
        main, sub, ann = lcd_decoder().text(k[1])
        body = f'on={int(k[0])} main={main!r} sub={sub!r} words={" ".join(f"{w:08X}" for w in k[1])} ann={",".join(ann)}'
    elif s == 'eeprom':
        body = f'offset 0x{k[0]:03X}: 0x{k[1]:02X} -> 0x{k[2]:02X}' + (f' (pc 0x{info["pc"]:08X})' if info and info.get('pc') else '')
    elif s == 'eeprom_store':
        body = f'0x{k[0]:08X} <- 0x{k[1]:X} ({k[2]} bytes, pc 0x{info["pc"]:08X})'
    elif s == 'spi':
        body = f'{k[0]} 0x{k[1]:02X} {info["reg"] if info else ""} [{k[2]}]'
    elif s == 'uart_tx':
        body = k[0] if isinstance(k[0], str) else f'0x{k[0]:02X}'
    else:
        body = ' '.join(str(x) for x in k) + (f'  {info}' if info else '')
    return f'{fmt_t(t)}  {s:10s} {body}'


def lcd_diff(ka, kb):
    dec = lcd_decoder()
    sa = dec.segments(ka[1]) if ka[0] else set()
    sb = dec.segments(kb[1]) if kb[0] else set()
    return sorted(sa - sb), sorted(sb - sa)


def _step_at(events, t):
    last = None
    for ev in events:
        if ev[0] > t:
            break
        if ev[1] == 'step':
            last = ev
    return f'line {last[2][0]}: {last[2][1]}' if last else '(before the first step)'


def _lcd_at(events, t):
    last = None
    for ev in events:
        if ev[0] > t:
            break
        if ev[1] == 'lcd':
            last = ev[2]
    if last is None:
        return '(no frame)'
    main, sub, ann = lcd_decoder().text(last[1])
    return f'on={int(last[0])} main={main!r} sub={sub!r} ann={",".join(ann)}'


def describe(cmp, ra, rb, context=5):
    """Markdown lines describing the first divergence of a comparison with context."""
    out = []
    d = cmp['first']
    if d is None:
        return out
    s = d['stream']
    out.append(f'First divergence: stream `{s}`, event #{d["index"]}, kind **{d["kind"]}**'
               + (f', time difference {d["dt_s"] * 1000:.3f} ms' if 'dt_s' in d else '') + f', at {fmt_t(d["t"])}')
    out.append('')
    out.append(f'- scenario step (reference): {_step_at(ra["events"], d["t"])}')
    out.append(f'- LCD (reference) at that time: {_lcd_at(ra["events"], d["t"])}')
    out.append(f'- LCD (candidate) at that time: {_lcd_at(rb["events"], d["t"])}')
    if s == 'lcd' and d['ref'] is not None and d['cand'] is not None:
        only_a, only_b = lcd_diff(d['ref'][2], d['cand'][2])
        out.append(f'- segments lit only in reference: {", ".join(only_a) or "-"}; only in candidate: {", ".join(only_b) or "-"}')
    out.append('')
    for label, r, ev in (('reference', ra, d['ref']), ('candidate', rb, d['cand'])):
        evs = [e for e in r['events'] if e[1] == s]
        i = d['index']
        out.append(f'{label} `{s}` events {max(0, i - context)}..{i}:')
        out.append('```')
        for e in evs[max(0, i - context):i]:
            out.append('  ' + fmt_event(e))
        out.append('> ' + fmt_event(ev))
        out.append('```')
    return out
