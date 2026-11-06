"""The meter's settings over the file-transfer link: read all, change one (GET / PUT of firmware/src/ble/bftset.s).

Works only while the meter shows the SETUP page Ld (as card.py).  THE BYTE LAYOUTS ARE IN THE FIRST SECTION, the table
of the settings in the second.

    0x16 GET    -                       answer: field = number of entries, data = entries id:u16 value:u8 (table order)
    0x17 PUT    id:u16 value:u8         answer: field = id, data = the value now in effect (1 byte)
Answers are type 0x82 (card.py).  PUT status 0 applied; 3 refused: a setting is being edited on the meter; 0x22 unknown id,
value out of range, or a payload that is not 3 bytes.  The meter applies a PUT as its setup page does when a value is
edited and saved (RAM variable, side effect, store to the EEPROM), so the companion never touches the EEPROM.

The id is the offset of the setting's byte in the data EEPROM and the value is the value of the setup page, which is the
stored byte for every id but 0x017 and 0x020.  Not offered by the meter: 0x018 (logging interval) and every byte of the
rotary memory, identity, calibration, restore and user zero; the table lists exactly the 17 ids of the firmware (id 0x020 as four rows).

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


def parse_get(field, data):
    """[(id, value)] from the field (count) and data of a GET answer."""
    if len(data) != 3 * field:
        raise card.CardError('GET answer: %d entries but %d bytes of data' % (field, len(data)))
    return [struct.unpack_from('<HB', data, i) for i in range(0, len(data), 3)]


def get_answer(pairs):
    """(field, data) of a GET answer (counterpart of parse_get)."""
    return len(pairs), b''.join(struct.pack('<HB', i, v) for i, v in pairs)


def put_request(wire_id, value):
    return struct.pack('<HB', wire_id, value)


def parse_put(wire_id, field, data):
    """The value in effect from the answer to a PUT of `wire_id`."""
    if field != wire_id or len(data) != 1:
        raise card.CardError('PUT answer for id 0x%03X with %d bytes of data, expected 0x%03X and 1' % (field, len(data), wire_id))
    return data[0]


# ---------------------------------------------------------------------------------------------------- the settings
# id: the number the page and the commands use (equal to `wire` except for the four fields of the shared id 0x020);
# wire: id on the link; shift / mask: the bit field inside the wire value; code: the SETUP page; choices: names by value
Setting = namedtuple('Setting', 'id wire code name min max choices shift mask')


def _s(id_, code, name, lo, hi, choices=None, wire=None, shift=0, mask=0xFF):
    return Setting(id_, id_ if wire is None else wire, code, name, lo, hi, choices, shift, mask)


TABLE = [
    # bftset.s bfs_tab, in its order; the code is the SETUP page's (FEATURES.md 4; EEPROM_MAP.md 4.1 for the numbered
    # pages of v2.05, which have no letters there: "item N")
    _s(0x00F, 'tc', 'Thermocouple type (TEMP)', 0, 5, ['K', 'J', 'T', 'N', 'R', 'S']),
    _s(0x010, 'item 0', 'Temperature unit', 0, 1, ['degF', 'degC']),
    _s(0x011, 'r', 'dBm reference (ACV)', 0, 3, ['600 ohm', '50 ohm', '75 ohm', 'dBV']),
    _s(0x013, 'dSP', 'Display level', 0, 1, ['1 (steadiest)', '2 (quicker)']),
    _s(0x014, 'item 10', 'Continuity threshold (BEEP)', 0, 15, None),
    _s(0x015, 'bt', 'Bluetooth frame rate', 0, 3, ['2 per second', '4 per second', '10 per second', '20 per second']),
    _s(0x016, 'item 2', 'Auto power-off disabled', 0, 1, ['no', 'yes']),
    _s(0x017, 'bL', 'Backlight auto-off', 0, 100, None),                    # 0 off, 1 = 30 s, 2..100 = 1..99 min
    _s(0x01A, 'item 4', 'LCD contrast', 10, 17, None),
    _s(0x01B, 'item 11', 'VA burden "bd"', 0, 1, ['off', 'on']),
    _s(0x01E, 'item 3', 'Buzzer', 0, 1, ['off', 'on']),
    _s(0x120, 'rEL', 'REL display', 0, 1, ['difference', 'percent'], wire=B20, shift=0, mask=0x01),
    _s(0x220, 'tr', 'Logging trigger', 0, 2, ['interval', 'on change', 'on limit verdict'], wire=B20, shift=1, mask=0x03),
    _s(0x320, 'CL', 'Clock', 0, 1, ['24 hour', '12 hour'], wire=B20, shift=3, mask=0x01),
    _s(0x420, 'HUnt', 'Capacitance anti-hunting', 0, 1, ['off', 'on'], wire=B20, shift=4, mask=0x01),
    _s(0x021, 'bH', 'Continuity beep hold (BEEP)', 0, 3, ['100 ms', '50 ms', '25 ms', 'off (15 ms)']),
    _s(0x022, 'Ch', 'Logging change threshold', 1, 255, None),
    _s(0x028, 'LP', 'Current loop view (DC mA)', 0, 2, ['off', '4-20 mA', '0-20 mA']),
    _s(0x029, 'Pt', 'RTD temperature view (ohm)', 0, 2, ['off', 'Pt100', 'Pt1000']),
    _s(0x02A, 'BAT', 'Battery voltage trim', 50, 150, None),                # value = trim + 100, trim -50..50 = -10..+10 %
]
BY_ID = {s.id: s for s in TABLE}


def field(s, raw):
    """The value of the setting `s` in the wire value `raw`."""
    return (raw >> s.shift) & s.mask


def merge(s, raw, value):
    """The wire value to send: `raw` with the field of `s` replaced by `value`."""
    return (raw & ~(s.mask << s.shift) & 0xFF) | ((value & s.mask) << s.shift)


def text(s, v):
    """Readable value: the choice's name, or the formatted number."""
    if not s.min <= v <= s.max:
        return 'invalid (%d)' % v
    if s.choices:
        return s.choices[v]
    if s.code == 'bL':
        return 'off' if v == 0 else '30 s' if v == 1 else '%d min' % (v - 1)
    if s.code == 'BAT':
        return '%+.1f %%' % ((v - 100) * 0.2)
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


def item(s, raw):
    """The entry of state.settings.items for the setting `s` held in the byte `raw`."""
    v = field(s, raw)
    return {'id': s.id, 'code': s.code, 'name': s.name, 'value': v, 'min': s.min, 'max': s.max,
            'choices': list(s.choices) if s.choices else None, 'text': text(s, v)}


HUNT_ID = 0x420                                     # the anti-hunting row: firmware F-1.16 and newer only


class Settings:
    def __init__(self, client, hunt=True):
        """`hunt`: the meter's firmware knows the anti-hunting bit (F-1.16 or newer); without it the row HUnt is neither
        listed nor changed (older firmware refuses every value of id 0x020 above 15)."""
        self.c = client
        self.hunt = hunt

    def rows(self):
        return [s for s in TABLE if self.hunt or s.id != HUNT_ID]

    def raw_all(self):
        """{wire id: value} as the meter reports; ids the table does not know are dropped (never written either)."""
        known = {s.wire for s in TABLE}
        return {i: v for i, v in parse_get(*self.c.ok(T_GET)) if i in known}

    def get_all(self):
        """state.settings.items: one entry per table setting the meter reports."""
        raw = self.raw_all()
        return [item(s, raw[s.wire]) for s in self.rows() if s.wire in raw]

    def put(self, setting_id, value):
        """Change one setting (range checked first, written, answer and read-back compared); returns get_all()."""
        s, value = check(setting_id, value)
        if s not in self.rows():
            raise ValueError('%s needs firmware F-1.16 or newer' % s.code)
        raw = self.raw_all()
        if s.wire not in raw:
            raise card.CardError('the meter does not report %s' % s.code)
        if s.wire == B20 and (raw[B20] > 31 or (s.code != 'tr' and (raw[B20] >> 1) & 3 == 3)):
            raise card.CardError('%s: the meter reports the value 0x%02X of its shared setting, which it would refuse; '
                                 'set the logging trigger (tr) first' % (s.code, raw[B20]))
        send = merge(s, raw[s.wire], value)
        status, field_, data = self.c.request(T_PUT, put_request(s.wire, send))
        if status:
            raise card.CardError('%s: %s' % (s.code, card.describe(status, field_)), status)
        if parse_put(s.wire, field_, data) != send:
            raise card.CardError('%s: the meter applied %d instead of %d' % (s.code, data[0], send))
        after = self.raw_all()
        if s.wire not in after or field(s, after[s.wire]) != value:
            raise card.CardError('%s: the meter did not keep the value (read back %s)'
                                 % (s.code, field(s, after[s.wire]) if s.wire in after else 'nothing'))
        return [item(t, after[t.wire]) for t in self.rows() if t.wire in after]
