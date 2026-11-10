"""The meter's settings over the file-transfer link: read all, change one (GET / PUT of firmware/src/ble/bftset.s).

Works only while the meter shows the SETUP page Ld (as card.py).  THE BYTE LAYOUTS ARE IN THE FIRST SECTION, the table
of the settings in the second.

    0x16 GET    -                       answer: field = number of entries, data = entries id:u16 value:u8 (table order)
    0x17 PUT    id:u16 value:u8         answer: field = id, data = the value now in effect (1 byte)
Firmware F-1.33 and newer (IMP-64) also take GET start:u8 max:u8 flags:u8 = 1, answered with entries id:u16 value:u16
(little endian) of every setting, and PUT id:u16 value:u16 (answer value u16).  The two-byte setting 0x02D (user continuity
threshold 1..500 ohm) exists only in those forms; without the flags a GET answers the one-byte settings only.
Answers are type 0x82 (card.py).  PUT status 0 applied; 3 refused: a setting is being edited on the meter; 0x22 unknown id,
value out of range, or a payload that is not 3 bytes.  The meter applies a PUT as its setup page does when a value is
edited and saved (RAM variable, side effect, store to the EEPROM), so the companion never touches the EEPROM.

The id is the offset of the setting's byte in the data EEPROM and the value is the value of the setup page, which is the
stored byte for every id but 0x017 and 0x020.  Not offered by the meter: 0x018 (logging interval) and every byte of the
rotary memory, identity, calibration, restore and user zero; the table lists exactly the 19 ids of the firmware (id 0x020 as four rows).

The id 0x020 is ONE id with a value 0..31 (0..15 before firmware F-1.16): bit 0 the REL view, bits 2..1 the logging
trigger 0..2 (3 is refused), bit 3 the clock, bit 4 the capacitance anti-hunting (SETUP page HUnt, firmware F-1.16 and
newer); bits 7..5 are 0.  The page shows it as four rows (REL view, trigger, clock, anti-hunting) with their own ids 0x120,
0x220, 0x320, 0x420 (`id` of the state contract; `wire` is 0x020 for all four).  Changing one row is a read-modify-write on
this side: GET, replace the row's bits, PUT the whole value, so the other rows keep what the meter reported.  If the meter's
trigger bits read 3 (not valid) another row cannot be changed until the trigger is set (the meter would refuse the PUT).
Firmware older than F-1.16 refuses a value above 15, so the anti-hunting row is neither listed nor changed for it
(`Settings(client, hunt=False)`).
The answer's value is compared with what was sent, and the settings are read back.
"""
import struct
from collections import namedtuple

from . import card

# ---------------------------------------------------------------------------------------------------- byte layouts
T_GET, T_PUT = 0x16, 0x17
B20 = 0x020                                         # the shared bit field


def parse_get(field, data, wide=False):
    """[(id, value)] from the field (count) and data of a GET answer (`wide`: the two-byte form of F-1.33)."""
    size, fmt = (4, '<HH') if wide else (3, '<HB')
    if len(data) != size * field:
        raise card.CardError('GET answer: %d entries but %d bytes of data' % (field, len(data)))
    return [struct.unpack_from(fmt, data, i) for i in range(0, len(data), size)]


GET_PAGE_FIRST = 8                                  # entries of the first GET page on a damaging link (IMP-55)
GET_RETRIES = 8                                     # tries of one GET page before the read fails
GET_PAGE_WAIT = 3.0                                 # seconds for the answer to one page (a few dozen bytes)


def get_answer(pairs, wide=False):
    """(field, data) of a GET answer (counterpart of parse_get)."""
    return len(pairs), b''.join(struct.pack('<HH' if wide else '<HB', i, v) for i, v in pairs)


def put_request(wire_id, value, wide=False):
    return struct.pack('<HH' if wide else '<HB', wire_id, value)


def parse_put(wire_id, field, data, wide=False):
    """The value in effect from the answer to a PUT of `wire_id`."""
    n = 2 if wide else 1
    if field != wire_id or len(data) != n:
        raise card.CardError('PUT answer for id 0x%03X with %d bytes of data, expected 0x%03X and %d'
                             % (field, len(data), wire_id, n))
    return struct.unpack('<H', data)[0] if wide else data[0]


# ---------------------------------------------------------------------------------------------------- the settings
# id: the number the page and the commands use (equal to `wire` except for the four fields of the shared id 0x020);
# wire: id on the link; shift / mask: the bit field inside the wire value; code: the SETUP page; choices: names by value
# wide: a two-byte value (firmware F-1.33 and newer only, GET with flags 1 and the two-byte PUT)
Setting = namedtuple('Setting', 'id wire code name min max choices shift mask wide')


def _s(id_, code, name, lo, hi, choices=None, wire=None, shift=0, mask=0xFF, wide=False):
    return Setting(id_, id_ if wire is None else wire, code, name, lo, hi, choices, shift, mask, wide)


TABLE = [
    # bftset.s bfs_tab, in its order; the code is the SETUP page's (FEATURES.md 4; EEPROM_MAP.md 4.1 for the numbered
    # pages of v2.05, which have no letters there: "item N")
    _s(0x00F, 'tc', 'Thermocouple type (TEMP)', 0, 5, ['K', 'J', 'T', 'N', 'R', 'S']),
    _s(0x010, 'item 0', 'Temperature unit', 0, 1, ['degF', 'degC']),
    _s(0x011, 'r', 'dBm reference (ACV)', 0, 3, ['600 ohm', '50 ohm', '75 ohm', 'dBV']),
    _s(0x013, 'dSP', 'Display level', 0, 1, ['1 (steadiest)', '2 (quicker)']),
    _s(0x014, 'item 10', 'Continuity threshold (BEEP)', 0, 17, None),           # 16 DNUSr, 17 UPUSr: F-1.33 on (older: 0..15)
    _s(0x015, 'bt', 'Bluetooth frame rate', 0, 3, ['2 per second', '4 per second', '10 per second', '20 per second']),
    _s(0x016, 'item 2', 'Auto power-off disabled', 0, 1, ['no', 'yes']),
    _s(0x02B, 'APO', 'Auto power-off time', 0, 3, ['30 min', '1 min', '15 min', '60 min']),   # F-1.18 on (EEPROM 0x02B; older firmware does not report it, so the row is not listed)
    _s(0x02C, 'CHIrP', 'Diode contact chirp (DIODE)', 0, 1, ['off', 'on']),   # F-1.21 on (EEPROM 0x02C; older firmware does not report it, so the row is not listed)
    _s(0x017, 'bL', 'Backlight auto-off', 0, 100, None),                    # 0 off, 1 = 30 s, 2..100 = 1..99 min
    _s(0x01A, 'item 4', 'LCD contrast', 10, 17, None),
    _s(0x01B, 'item 11', 'VA burden "bd"', 0, 1, ['off', 'on']),
    _s(0x01E, 'item 3', 'Buzzer', 0, 2, ['off', 'on', 'quiet (keys silent)']),   # 2 qUiEt: F-1.24 on (GitHub issue 28)
    _s(0x120, 'rEL', 'REL display', 0, 1, ['difference', 'percent'], wire=B20, shift=0, mask=0x01),
    _s(0x220, 'tr', 'Logging trigger', 0, 2, ['interval', 'on change', 'on limit verdict'], wire=B20, shift=1, mask=0x03),
    _s(0x320, 'CL', 'Clock', 0, 1, ['24 hour', '12 hour'], wire=B20, shift=3, mask=0x01),
    _s(0x420, 'HUnt', 'Capacitance anti-hunting', 0, 1, ['off', 'on'], wire=B20, shift=4, mask=0x01),
    _s(0x021, 'bH', 'Continuity beep hold (BEEP)', 0, 3, ['100 ms', '50 ms', '25 ms', 'off (15 ms)']),
    _s(0x022, 'Ch', 'Logging change threshold', 1, 255, None),
    _s(0x028, 'LP', 'Current loop view (DC mA)', 0, 2, ['off', '4-20 mA', '0-20 mA']),
    _s(0x029, 'Pt', 'RTD temperature view (ohm)', 0, 2, ['off', 'Pt100', 'Pt1000']),
    _s(0x02A, 'BAT', 'Battery voltage trim', 50, 150, None),                # value = trim + 100, trim -50..50 = -10..+10 %
    _s(0x02F, 'HY', 'Continuity hysteresis, user codes (BEEP)', 1, 250, None),   # tenths of an ohm; F-1.33 on (IMP-64)
    _s(0x02D, 'th', 'Continuity threshold, user codes (BEEP)', 1, 500, None, wide=True),   # ohm; F-1.33 on (IMP-64)
]
BY_ID = {s.id: s for s in TABLE}

# Texts of the continuity threshold codes 0..17 as the meter's page 10 shows them (firmware set/setup.s set_cont_text;
# 16 DNUSr and 17 UPUSr use the thresholds of the pages th and HY, F-1.33 on); also used for the status frame (display.py)
BEEP_TEXT = ['DN 30', 'UP 30', 'DN300', 'UP300', 'DN  1', 'DN  5', 'DN 10', 'DN 50',
             'DN100', 'DN200', 'UP  1', 'UP  5', 'UP 10', 'UP 50', 'UP100', 'UP200', 'DNUSr', 'UPUSr']
TEXTS_MAX = 101                                     # settings with at most this many values get a text for every value
# the settings with too many values for a list: shown as a number with a unit and a scale (value x scale)
UNITS = {'Ch': ('', 1), 'th': ('ohm', 1), 'HY': ('ohm', 0.1)}


def field(s, raw):
    """The value of the setting `s` in the wire value `raw`."""
    if s.wide:
        return raw                                  # a two-byte setting is the whole value
    return (raw >> s.shift) & s.mask


def merge(s, raw, value):
    """The wire value to send: `raw` with the field of `s` replaced by `value`."""
    if s.wide:
        return value
    return (raw & ~(s.mask << s.shift) & 0xFF) | ((value & s.mask) << s.shift)


def text(s, v):
    """Readable value: the choice's name, or the formatted number."""
    if not s.min <= v <= s.max:
        return 'invalid (%d)' % v
    if s.choices:
        return s.choices[v]
    if s.code == 'bL':
        return 'off' if v == 0 else '30 s' if v == 1 else '%d min' % (v - 1)
    if s.id == 0x014:
        return BEEP_TEXT[v]                         # DN 30 .. UPUSr (codes 16 and 17: the thresholds of th and HY)
    if s.id == 0x01A:
        return 'Lcd-%d' % (v - 10)                  # as the meter's page 4 shows it (set/setup.s fn_08018410: "Lcd-" contrast - 10)
    if s.code == 'BAT':
        return '%+.1f %%' % ((v - 100) * 0.2)
    if s.code == 'HY':
        return '%.1f ohm' % (v / 10)
    if s.code == 'th':
        return '%d ohm' % v
    return '%d' % v


def check(setting_id, value):
    """(Setting, int value) after the range check; ValueError for an id not in the table or a value out of range."""
    if isinstance(setting_id, bool) or not isinstance(setting_id, int) or setting_id not in BY_ID:
        raise ValueError('setting %r is not one the companion changes' % (setting_id,))
    s = BY_ID[setting_id]
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError('%s: the value must be a whole number' % s.code)
    if not s.min <= value <= s.max:
        raise ValueError('%s: the value must be %d..%d' % (s.code, s.min, s.max))
    return s, value


def tag(s):
    """The page of the setting as the page shows it (GitHub issue 35): the meter's letters, or "page N" for the pages
    of v2.05 that show no letters ("item N" in `code`, which the reports and the API keep)."""
    return 'page ' + s.code[5:] if s.code.startswith('item ') else s.code


def texts(s):
    """The text of every value min..max (index = value - min), or None for the settings with too many values."""
    if s.max - s.min + 1 > TEXTS_MAX or s.code in UNITS:
        return None
    return [text(s, v) for v in range(s.min, s.max + 1)]


def item(s, raw):
    """The entry of state.settings.items for the setting `s` held in the byte `raw`.  `texts`: the text of each value
    min..max for the page's stepper; `unit` / `scale`: for the settings without texts, the number shown is value x
    scale with the unit (HY in 0.1 ohm steps)."""
    v = field(s, raw)
    unit, scale = UNITS.get(s.code, (None, 1))
    return {'id': s.id, 'code': s.code, 'tag': tag(s), 'name': s.name, 'value': v, 'min': s.min, 'max': s.max,
            'choices': list(s.choices) if s.choices else None, 'text': text(s, v), 'texts': texts(s),
            'unit': unit, 'scale': scale}


HUNT_ID = 0x420                                     # the anti-hunting row: firmware F-1.16 and newer only
BUZZER_ID = 0x01E                                   # the buzzer row: its third value qUiEt, firmware F-1.24 and newer only
CONT_ID = 0x014                                     # the continuity threshold: codes 16 and 17, firmware F-1.33 and newer only


class Settings:
    def __init__(self, client, hunt=True, quiet=True, paged=False, user_cont=True):
        """`hunt`: the meter's firmware knows the anti-hunting bit (F-1.16 or newer); without it the row HUnt is neither
        listed nor changed (older firmware refuses every value of id 0x020 above 15).  `quiet`: the firmware knows the
        buzzer's third value qUiEt (F-1.24 or newer); without it the buzzer row offers off and on only.  `paged`: the
        meter has the old BLE112 module and firmware F-1.25 or newer (GitHub issue 30): GET in pages of start(1) max(1),
        GET_PAGE_FIRST entries at first, halved after a page that did not arrive (down to 1), as the card list; one
        answer with every setting (68 bytes) rarely arrives intact on such a link.  `user_cont`: the firmware has the user
        continuity codes (F-1.33 or newer, IMP-64): GET and the PUT of the threshold use the two-byte forms; without it
        the threshold row offers the codes 0..15 only and the rows th and HY are not listed."""
        self.c = client
        self.hunt = hunt
        self.quiet = quiet
        self.paged = paged
        self.user_cont = user_cont

    def rows(self):
        out = []
        for s in TABLE:
            if s.id == HUNT_ID and not self.hunt:
                continue
            if s.id == BUZZER_ID and not self.quiet:
                s = s._replace(max=1, choices=s.choices[:2])     # older firmware refuses the value 2
            if not self.user_cont:
                if s.wide:
                    continue                                     # older firmware has no two-byte setting
                if s.id == CONT_ID:
                    s = s._replace(max=15)                       # older firmware refuses the codes 16 and 17
            out.append(s)
        return out

    def raw_all(self):
        """{wire id: value} as the meter reports; ids the table does not know are dropped (never written either)."""
        known = {s.wire for s in TABLE}
        if self.paged:
            pairs = self._paged_get()
        elif self.user_cont:
            field_, data = self.c.ok(T_GET, bytes([0, 255, 1]))     # every setting with two-byte values, one answer
            if not field_ & 0x8000:
                raise card.CardError('GET: the meter did not answer every setting (field 0x%04X)' % field_)
            pairs = parse_get(field_ & 0x7FFF, data, wide=True)
        else:
            pairs = parse_get(*self.c.ok(T_GET))
        return {i: v for i, v in pairs if i in known}

    def _paged_get(self):
        """[(id, value)] of every setting, fetched page by page (IMP-55); field = entries | 0x8000 with the last one."""
        out, start, most = [], 0, GET_PAGE_FIRST
        for _ in range(64):
            for _ in range(GET_RETRIES):
                try:
                    status, field, data = self.c.request(T_GET, bytes([start, most] + ([1] if self.user_cont else [])),
                                                         retries=1, timeout=GET_PAGE_WAIT)
                    break
                except card.CardError:
                    if self.c.cancelled:
                        raise
                    most = max(1, most // 2)
            else:
                raise card.CardError('no answer from the meter (is "Ld-bt" still shown on it?)')
            if status:
                raise card.CardError(card.describe(status, field), status)
            count, end = field & 0x7FFF, bool(field & 0x8000)
            out += parse_get(count, data, wide=self.user_cont)
            start += count
            if end or not count:
                return out
        raise card.CardError('GET: the settings did not end after 64 pages')

    def get_all(self):
        """state.settings.items: one entry per table setting the meter reports."""
        raw = self.raw_all()
        return [item(s, raw[s.wire]) for s in self.rows() if s.wire in raw]

    def put(self, setting_id, value):
        """Change one setting (range checked first, written, answer and read-back compared); returns get_all()."""
        s, value = check(setting_id, value)
        row = next((r for r in self.rows() if r.id == s.id), None)
        if row is None:
            raise ValueError('%s needs firmware %s or newer' % (s.code, 'F-1.33' if s.wide else 'F-1.16'))
        if value > row.max:
            raise ValueError('%s %s needs firmware %s or newer' % (s.code, s.choices[value] if s.choices else value,
                                                                   'F-1.33' if s.id == CONT_ID else 'F-1.24'))
        s = row
        raw = self.raw_all()
        if s.wire not in raw:
            raise card.CardError('the meter does not report %s' % s.code)
        if s.wire == B20 and (raw[B20] > 31 or (s.code != 'tr' and (raw[B20] >> 1) & 3 == 3)):
            raise card.CardError('%s: the meter reports the value 0x%02X of its shared setting, which it would refuse; '
                                 'set the logging trigger (tr) first' % (s.code, raw[B20]))
        send = merge(s, raw[s.wire], value)
        status, field_, data = self.c.request(T_PUT, put_request(s.wire, send, wide=s.wide))
        if status:
            raise card.CardError('%s: %s' % (s.code, card.describe(status, field_)), status)
        applied = parse_put(s.wire, field_, data, wide=s.wide)
        if applied != send:
            raise card.CardError('%s: the meter applied %d instead of %d' % (s.code, applied, send))
        after = self.raw_all()
        if s.wire not in after or field(s, after[s.wire]) != value:
            raise card.CardError('%s: the meter did not keep the value (read back %s)'
                                 % (s.code, field(s, after[s.wire]) if s.wire in after else 'nothing'))
        return [item(t, after[t.wire]) for t in self.rows() if t.wire in after]
