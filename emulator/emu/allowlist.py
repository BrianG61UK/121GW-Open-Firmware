"""Deviation allowlist (firmware/deviations.txt), shared by the differential harness (emulator/diff/compare.py) and
the hardware-safety monitor (emu/safety.py).

One entry per line, '#' starts a comment:
    <ref> <stream> <scenario-glob> <condition>
  ref        the documented deviation: OF-<n> (firmware/ORIGINAL_FIRMWARE_ISSUES.md) or NF-, HW-, NVM-, IMP-, OPT-<n>
             (firmware/DESIGN.md section 10)
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
             tolerance:<stream>  a wider time tolerance for that stream; the condition is one number of seconds
             (for example "OPT-08 tolerance:lcd * 0.05"): the comparison uses the largest of the default and the
             matching entries
  scenario   fnmatch pattern of scenario names
  condition  'any', or clauses joined by 'and':  <field> in <lo>..<hi> | <field> == <v> | <field> != <v> |
             <field> ~ <glob>, numbers in any Python integer notation, strings quoted if they contain spaces;
             field 't' is the event time in seconds (in <lo>..<hi> accepts decimals).
"""
import fnmatch
import re
import shlex

REF_RE = re.compile(r'(OF|NF|HW|NVM|IMP|OPT)-\d+')
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


def load_allowlist(path, streams):
    """Entries of the file; `streams` is the set of stream names the caller accepts besides the safety_* ones (others
    are an error), None to accept every name."""
    devs = []
    for n, raw in enumerate(open(path, encoding='utf-8'), 1):
        t = shlex.split(raw, comments=True)
        if not t:
            continue
        if len(t) < 4:
            raise AllowlistError(f'{path}:{n}: expected <ref> <stream> <scenario-glob> <condition>')
        ref, stream, scen, cond = t[0], t[1], t[2], t[3:]
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
            d = Deviation(ref, stream, scen, [], raw.strip(), n)
            d.tolerance = secs
            devs.append(d)
            continue
        if streams is not None and stream not in streams and stream not in SAFETY_STREAMS:
            raise AllowlistError(f'{path}:{n}: unknown stream {stream!r}')
        if stream in SAFETY_STREAMS and scen != '*':
            raise AllowlistError(f'{path}:{n}: a {stream} entry must use the scenario glob *')
        clauses = []
        if cond != ['any']:
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
                    dec = field == 't'
                    try:
                        clauses.append((field, op, (_bound(lo, dec), _bound(hi, dec))))
                    except ValueError:
                        raise AllowlistError(f'{path}:{n}: bad range {val!r}') from None
                else:
                    clauses.append((field, op, val if op == '~' else _value(val)))
        devs.append(Deviation(ref, stream, scen, clauses, raw.strip(), n))
    return devs


