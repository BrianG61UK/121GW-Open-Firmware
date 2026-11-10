"""Approved-deviation list of the hardware-safety monitor (emu/safety.py; entries in emu/safety_allow.txt).

One entry per line, '#' starts a comment:
    <ref> <stream> * <condition>
  ref        the documented deviation: OF-<n> (firmware/ORIGINAL_FIRMWARE_ISSUES.md) or NF-, HW-, NVM-, IMP-, OPT-<n>
             (firmware/DESIGN.md section 10); several joined by '+' (OF-14+OF-15) when one event is the
             consequence of all of them
  stream     one of the hardware-safety checks of emu/safety.py:
                 safety_write    fields reg, value          (an HY3131 register write outside the whitelist)
                 safety_frame    fields reg, count          (an HY3131 write frame shape outside the whitelist)
                 safety_state    field state                (registers 0x20..0x33 as written in the stop message,
                                                             e.g. "00 00 13 ...", '--' = not written)
                 safety_power    fields pins, old, new, ctx (a supply/enable step, as in the whitelist 'power' lines,
                                                             e.g. pins == PD1 and old == Z and new == 1 and
                                                             ctx == PE9=1,PD1=Z)
                 safety_contention  fields pin, text        (pin name such as PE10; text = the violation message)
  scenario   always '*': the monitor runs in every session
  condition  'any', or clauses joined by 'and':  <field> in <lo>..<hi> | <field> == <v> | <field> != <v> |
             <field> ~ <glob>, numbers in any Python integer notation, strings quoted if they contain spaces
"""
import fnmatch
import re
import shlex

ONE_REF = r'(?:OF|NF|HW|NVM|IMP|OPT)-\d+'
REF_RE = re.compile(ONE_REF + '(?:\\+' + ONE_REF + ')*')
SAFETY_STREAMS = ('safety_write', 'safety_frame', 'safety_state', 'safety_power', 'safety_contention')


class Deviation:
    def __init__(self, ref, stream, scen, clauses, text, lineno):
        self.ref, self.stream, self.scen, self.clauses, self.text, self.lineno = ref, stream, scen, clauses, text, lineno

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


class AllowlistError(ValueError):
    pass


def load_allowlist(path):
    """Entries of the file; any malformed line is an error."""
    devs = []
    for n, raw in enumerate(open(path, encoding='utf-8'), 1):
        t = shlex.split(raw, comments=True)
        if not t:
            continue
        if len(t) < 4:
            raise AllowlistError(f'{path}:{n}: expected <ref> <stream> * <condition>')
        ref, stream, scen, cond = t[0], t[1], t[2], t[3:]
        if not REF_RE.fullmatch(ref):
            raise AllowlistError(f'{path}:{n}: reference {ref!r} is not OF-, NF-, HW-, NVM-, IMP- or OPT-<number>')
        if stream not in SAFETY_STREAMS:
            raise AllowlistError(f'{path}:{n}: unknown stream {stream!r}')
        if scen != '*':
            raise AllowlistError(f'{path}:{n}: a {stream} entry must use the scenario glob *')
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
                    try:
                        clauses.append((field, op, (int(lo, 0), int(hi, 0))))
                    except ValueError:
                        raise AllowlistError(f'{path}:{n}: bad range {val!r}') from None
                else:
                    clauses.append((field, op, val if op == '~' else _value(val)))
        devs.append(Deviation(ref, stream, scen, clauses, raw.strip(), n))
    return devs
