"""Deviation allowlist (firmware/deviations.txt), shared by the differential harness (emulator/diff/compare.py) and
the hardware-safety monitor (emu/safety.py).

One entry per line, '#' starts a comment:
    <ref> <stream> <scenario-glob> <condition>
  ref        the documented deviation: OF-<n> (firmware/ORIGINAL_FIRMWARE_ISSUES.md) or NF-, HW-, NVM-, IMP-, OPT-<n>
             (firmware/DESIGN.md section 10); several joined by '+' (OF-14+OF-15) when one event is the
             consequence of all of them
  stream     a stream of the comparison (diff/compare.py: COMPARED and the final-state streams) or one of the
             hardware-safety checks:
                 safety_write    fields reg, value          (an HY3131 register write outside the whitelist)
                 safety_frame    fields reg, count          (an HY3131 write frame shape outside the whitelist)
                 safety_state    field state                (registers 0x20..0x33 as written in the stop message,
                                                             e.g. "00 00 13 ...", '--' = not written)
                 safety_power    fields pins, old, new, ctx (a supply/enable step, as in the whitelist 'power' lines,
                                                             e.g. pins == PD1 and old == Z and new == 1 and
                                                             ctx == PE9=1,PD1=Z)
                 safety_contention  fields pin, text        (pin name such as PE10; text = the violation message)
             A safety_* entry must use the scenario glob '*': the monitor runs in every session, with or without a
             scenario.
             mask:lcd:bar   the same for the bargraph: its segments bar01..bar26 and its sign (Bar+, BarTick-); the
             scale labels and ticks, the digits and every annunciator stay compared
             mask:lcd:sub | mask:lcd:main   a persistent difference of one display row (for example the board
             temperature on the secondary display): in every LCD event of the matching scenarios whose fields satisfy
             the condition, the segments of that row (digits, decimal points, minus sign) are not compared, in both
             runs, so that the rest of the frame (the other row, the annunciators) still is, and an event that then
             equals the one before it (only the row changed) is dropped; the same for the final frame (lcd_final)
             when its row text satisfies the condition
             tolerance:<stream>  a wider time tolerance for that stream; the condition is one number of seconds
             (for example "OPT-08 tolerance:lcd * 0.05"): the comparison uses the largest of the default and the
             matching entries
  scenario   fnmatch pattern of scenario names
  condition  'any', or clauses joined by 'and':  <field> in <lo>..<hi> | <field> == <v> | <field> != <v> |
             <field> ~ <glob>, numbers in any Python integer notation, strings quoted if they contain spaces;
             field 't' is the event time in seconds and 'since' the time in seconds since the latest scenario step
             that acts on the meter started (in <lo>..<hi> accepts decimals for these two and for 'boot'); 'step' is the scenario
             file line of that step (dial, key, input, jack, analog, sd, ble, sysreset, powercycle; not wait, mark
             or expect), 0 before the first one; 'boot' is the time in seconds since the latest power-on or system
             reset of the run (the start-up phase of a power-on and of an MCU reset).  The four
             fields exist for every compared stream and for 'assert'; uart_tx events also have 'pos', the index of
             the byte in its burst (bytes less than 2 ms apart: a BLE status frame is one burst, pos 0 = its start
             byte, pos 18 = its checksum).
             The clause 'build == <baseline|production>' is not a field of an event: it restricts the entry to
             one build mode of the port (DESIGN 3.5: baseline = the like-v2.05 build of its branch, LOOP_V205=1; production = the fast build of main) and is
             given to the loader (diff/run.py --build).  An entry with the clause is used only when the loader's
             build is the same; without a build given, such entries are not used (nothing is hidden).  Entries
             without the clause apply to both builds.  A tolerance entry takes it after the number
             ("OPT-08 tolerance:lcd * 0.05 and build == production"); a safety_* entry may not carry it.
"""
import fnmatch
import re
import shlex

ONE_REF = r'(?:OF|NF|HW|NVM|IMP|OPT)-\d+'
REF_RE = re.compile(ONE_REF + '(?:\\+' + ONE_REF + ')*')
BUILDS = ('baseline', 'production')
MASKS = ('lcd:sub', 'lcd:main', 'lcd:bar')
SAFETY_STREAMS = ('safety_write', 'safety_frame', 'safety_state', 'safety_power', 'safety_contention')


class Deviation:
    def __init__(self, ref, stream, scen, clauses, text, lineno):
        self.ref, self.stream, self.scen, self.clauses, self.text, self.lineno = ref, stream, scen, clauses, text, lineno
        self.removed = 0
        self.tolerance = None

    def applies(self, scenario):
        return fnmatch.fnmatchcase(scenario, self.scen)

    def match(self, f):
        for field, op, val in self.clauses:
            if field not in f:
                return False
            v = f[field]
            if op == 'in':
                lo, hi = val
                if isinstance(v, str) or not lo <= v <= hi:
                    return False
            elif op in ('==', '!='):
                # text fields (levels such as '1' or 'Z', names) compare with the value token as written
                if isinstance(v, str) and not isinstance(val, str):
                    val = str(val)
                if (v == val) != (op == '=='):
                    return False
            elif op == '~':
                if not fnmatch.fnmatchcase(str(v), val):
                    return False
        return True


def _value(tok):
    try:
        return int(tok, 0)
    except ValueError:
        return tok


def _bound(tok, decimal):
    if decimal:
        return float(tok)
    return int(tok, 0)


class AllowlistError(ValueError):
    pass


def _split_build(tokens, path, n):
    """(tokens without the clause 'build == <name>', name or None) for one entry's condition tokens."""
    parts, cur = [], []
    for tok in tokens:
        if tok == 'and':
            parts.append(cur)
            cur = []
        else:
            cur.append(tok)
    parts.append(cur)
    build, rest = None, []
    for p in parts:
        if len(p) == 3 and p[0] == 'build':
            if p[1] != '==' or p[2] not in BUILDS or build is not None:
                raise AllowlistError(f'{path}:{n}: the build clause is "build == baseline" or "build == production", once')
            build = p[2]
        else:
            rest.append(p)
    out = []
    for i, p in enumerate(rest):
        if i:
            out.append('and')
        out.extend(p)
    return out, build


def load_allowlist(path, streams, build=None):
    """Entries of the file; `streams` is the set of stream names the caller accepts besides the safety_* ones (others
    are an error), None to accept every name.  `build` is the build mode of the candidate (baseline or production)
    or None: entries tagged with another build, or with any build when `build` is None, are left out."""
    devs = []
    for n, raw in enumerate(open(path, encoding='utf-8'), 1):
        t = shlex.split(raw, comments=True)
        if not t:
            continue
        if len(t) < 4:
            raise AllowlistError(f'{path}:{n}: expected <ref> <stream> <scenario-glob> <condition>')
        ref, stream, scen, cond = t[0], t[1], t[2], t[3:]
        cond, entry_build = _split_build(cond, path, n) if 'build' in cond else (cond, None)
        if build is not None and build not in BUILDS:
            raise AllowlistError(f'{path}: unknown build {build!r}')
        if not REF_RE.fullmatch(ref):
            raise AllowlistError(f'{path}:{n}: reference {ref!r} is not OF-, NF-, HW-, NVM-, IMP- or OPT-<number>')
        if stream.startswith('tolerance:'):
            inner = stream.split(':', 1)[1]
            if streams is not None and inner not in streams:
                raise AllowlistError(f'{path}:{n}: tolerance for unknown stream {inner!r}')
            try:
                secs = float(cond[0]) if len(cond) == 1 else None
            except ValueError:
                secs = None
            if secs is None or secs < 0:
                raise AllowlistError(f'{path}:{n}: tolerance entry needs one number of seconds as its condition')
            if entry_build is not None and entry_build != build:
                continue
            d = Deviation(ref, stream, scen, [], raw.strip(), n)
            d.tolerance = secs
            devs.append(d)
            continue
        if stream.startswith('mask:') and stream[5:] not in MASKS:
            raise AllowlistError(f'{path}:{n}: unknown mask {stream!r} (known: ' + ', '.join('mask:' + m for m in MASKS) + ')')
        if (streams is not None and stream not in streams and stream not in SAFETY_STREAMS
                and not stream.startswith('mask:')):
            raise AllowlistError(f'{path}:{n}: unknown stream {stream!r}')
        if stream in SAFETY_STREAMS and scen != '*':
            raise AllowlistError(f'{path}:{n}: a {stream} entry must use the scenario glob *')
        if stream in SAFETY_STREAMS and entry_build is not None:
            raise AllowlistError(f'{path}:{n}: a {stream} entry applies to every build')
        clauses = []
        if cond and cond != ['any']:
            parts, cur = [], []
            for tok in cond:
                if tok == 'and':
                    parts.append(cur)
                    cur = []
                else:
                    cur.append(tok)
            parts.append(cur)
            for p in parts:
                if len(p) != 3 or p[1] not in ('in', '==', '!=', '~'):
                    raise AllowlistError(f'{path}:{n}: bad clause {" ".join(p)!r}')
                field, op, val = p
                if op == 'in':
                    if '..' not in val:
                        raise AllowlistError(f'{path}:{n}: range must be <lo>..<hi>')
                    lo, hi = val.split('..')
                    dec = field in ('t', 'since', 'boot')
                    try:
                        clauses.append((field, op, (_bound(lo, dec), _bound(hi, dec))))
                    except ValueError:
                        raise AllowlistError(f'{path}:{n}: bad range {val!r}') from None
                else:
                    clauses.append((field, op, val if op == '~' else _value(val)))
        if entry_build is not None and entry_build != build:
            continue
        devs.append(Deviation(ref, stream, scen, clauses, raw.strip(), n))
    return devs


