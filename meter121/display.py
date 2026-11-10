"""Decode the 121GW status frame into the reading as the meter's display shows it.

Every table below comes from the firmware sources (branch main of the repository, firmware/src; the line numbers are
given where the table is used).  The frame (analysis/ble_packet.md 3, 4 of the firmware repository) carries mode, range,
an 18-bit magnitude, sign, overload, the sub display code and value, the bargraph and the symbols; it does NOT carry the
decimal point of the main value, which the meter takes from its table dec_table[mode][range] (mode/mode.s:968-994), nor
the unit prefix, which depends on mode and range (lcd/annun.s).  So both are tables here.

What the frame cannot tell (and is therefore not shown, rather than guessed): the main texts " LEAD", "-----", blanks
and calibration texts, the port-only main views (REL percent, loop percent, Pt100, statistics pages: the frame keeps the
counts), the sign of an overload, the sub display pages without a frame code (code 0), the dB reference (600 / 50 /
75 ohm or dBV) and the 12-hour clock setting.  While the main digits are blank the meter sends no new frames (OF-34),
so the last reading stays; the page marks a reading older than a few seconds as stale.
"""

MODES = ['LowZ', 'DCV', 'ACV', 'DCmV', 'ACmV', 'TEMP', 'FREQ', 'PULSE', 'DUTY', 'OHM', 'BEEP', 'DIODE', 'CAP',
         'uVA', 'mVA', 'VA', 'ACuA', 'DCuA', 'ACmA', 'DCmA', 'ACA', 'DCA', 'DCuVA', 'DCmVA', 'DCVA']

# (digits after the point, unit as lit on the glass) per reachable range: dp from dec_table (mode/mode.s:968-994),
# prefix and unit from the annunciator routines (lcd/annun.s, line per mode in the comment).  Ohm is written as the
# omega sign, temperature units come from the frame (byte [6] bits 5 / 4).
TABLE = {
    0: [(1, 'V')],                                                            # annun.s:96
    1: [(4, 'V'), (3, 'V'), (2, 'V'), (1, 'V')],                              # annun.s:182
    2: [(4, 'V'), (3, 'V'), (2, 'V'), (1, 'V')],                              # annun.s:148
    3: [(3, 'mV'), (2, 'mV')],                                                # annun.s:190
    4: [(3, 'mV'), (2, 'mV')],                                                # annun.s:156
    5: [(1, None)],                                                           # annun.s:1699 (unit from [6])
    6: [(3, 'Hz'), (2, 'Hz'), (4, 'kHz'), (3, 'kHz'), (2, 'kHz')],            # annun.s:203, 645-693
    7: [(4, 'ms'), (3, 'ms'), (2, 'ms')],                                     # annun.s:209
    8: [(1, '%')],                                                            # annun.s:217
    9: [(3, 'Ω'), (2, 'Ω'), (4, 'kΩ'), (3, 'kΩ'), (2, 'kΩ'), (4, 'MΩ'), (3, 'MΩ')],   # annun.s:244, 583-631
    10: [(2, 'Ω')],                                                           # annun.s:231 (with the beep symbol)
    11: [(4, 'V'), (3, 'V')],                                                 # mode.s:947-957 (3 V / 15 V source)
    12: [(3, 'nF'), (2, 'nF'), (4, 'µF'), (3, 'µF'), (2, 'µF'), (0, 'µF')],   # annun.s:225, 536-569
    13: [(2, 'µVA'), (1, 'µVA'), (1, 'µVA'), (0, 'µVA')],                     # annun.s:250
    14: [(3, 'mVA'), (2, 'mVA'), (2, 'mVA'), (1, 'mVA')],                     # annun.s:273
    15: [(1, 'mVA'), (0, 'mVA'), (3, 'VA'), (2, 'VA')],                       # annun.s:296, 497-522
    16: [(3, 'µA'), (2, 'µA')],                                               # annun.s:396
    17: [(3, 'µA'), (2, 'µA')],                                               # annun.s:439
    18: [(4, 'mA'), (3, 'mA')],                                               # annun.s:409
    19: [(4, 'mA'), (3, 'mA')],                                               # annun.s:452
    20: [(2, 'mA'), (4, 'A'), (3, 'A')],                                      # annun.s:422
    21: [(2, 'mA'), (4, 'A'), (3, 'A')],                                      # annun.s:465
    22: [(2, 'µVA'), (1, 'µVA'), (1, 'µVA'), (0, 'µVA')],                     # annun.s:323
    23: [(3, 'mVA'), (2, 'mVA'), (2, 'mVA'), (1, 'mVA')],                     # annun.s:346
    24: [(1, 'mVA'), (0, 'mVA'), (3, 'VA'), (2, 'VA')],                       # annun.s:369, 497-522
}

# Sub display texts of the continuity threshold (BEEP, codes 0xAA + 0..17; firmware set/setup.s set_cont_text), kept in
# settings.py.  Codes 16 and 17 (firmware F-1.33 and newer) use the user threshold, which the frame carries in its value
# bytes (ohm).
from .settings import BEEP_TEXT  # noqa: E402


def _fixed(mag, dp):
    return ('%d' % mag) if dp == 0 else '%.*f' % (dp, mag / 10 ** dp)


def _main(f, mode, rng):
    """(text, value, unit, dp) of the main display (rules M3..M7 of the mapping)."""
    mag = (((f[5] >> 6) & 3) << 16) | (f[7] << 8) | f[8]
    neg = bool(f[6] & 0x40)
    rows = TABLE.get(mode)
    if rows is None or rng >= len(rows):
        return None, None, '', None                     # a mode / range the meter cannot be in: nothing to show
    dp, unit = rows[rng]
    if mode == 5:
        unit = '°C' if f[6] & 0x20 else '°F' if f[6] & 0x10 else ''
    if f[6] & 0x80:                                     # overload: the meter shows " OFL " (M7); value bytes are stale
        return 'OFL', None, unit, dp
    if mag > 99999:                                     # only through REL: the display shows trunc(D/10), dp - 1 (M6)
        mag, dp = mag // 10, max(dp - 1, 0)
    text = _fixed(mag, dp)
    value = mag / 10 ** dp
    if neg:
        text, value = '-' + text, -value
    return text, value, unit, dp


def _sub(f, mode):
    """(label, text, unit) of the sub display (table B of the mapping, ble/packet.s and set/setup.s)."""
    code, fl = f[9], f[10]
    v = (f[11] << 8) | f[12]
    d = fl & 0x0F
    sign = '-' if fl & 0x40 else ''
    num = lambda val, dp: sign + _fixed(val, dp)
    if mode == 10 and 0xAA <= code < 0xAA + len(BEEP_TEXT):    # continuity threshold: before the codes of other pages,
        text = BEEP_TEXT[code - 0xAA]                           # the dB code 180 is the threshold code 10 (UP  1) here
        if code >= 0xAA + 16:
            text = '%s %d' % (text[:2], v)                      # DN / UP and the user threshold in ohm
        return 'threshold', text, 'Ω' if code >= 0xAA + 16 else ''
    if code in (100, 105):                              # board temperature (item 0), tenths of a degree
        if fl & 0x80:
            return 'temp', 'OPEN', ''
        return 'temp', num(v, 1), '°C' if code == 100 else '°F'
    if code == 110:                                     # battery (item 1): value / 10 = volts
        return 'battery', _fixed(v, 1), 'V'
    if code in (120, 125):                              # auto power-off (item 2)
        return 'auto off', 'on' if code == 120 else 'off', ''
    if code == 130:                                     # year (item 5)
        return 'year', '%d' % (2000 + f[12]), ''
    if code == 135:                                     # month - day (item 6)
        return 'date', '%02d-%02d' % (f[11], f[12]), ''
    if code == 140:                                     # hour - minute (item 7), always 0..23 in the frame
        return 'time', '%02d:%02d' % (f[11], f[12]), ''
    if code == 160:                                     # contrast (item 4): value = contrast - 10
        return 'contrast', '%d' % f[12], ''
    if code == 6:                                       # signal frequency (ACV / ACmV item 10, AC currents item 11)
        if fl & 0x80:
            return 'freq', 'OFL', ''
        return 'freq', num(v, d), 'kHz' if fl & 0x20 else 'Hz'
    if code == 180:                                     # dB (ACV item 11); reference (m or V) is not in the frame
        if fl & 0x80:
            return 'dB', 'OFL', ''
        return 'dB', num(v, d), 'dB'
    if code == 150:                                     # burden voltage (current modes item 11) or VA page 12
        unit = 'mV' if 16 <= mode <= 21 else ''
        return 'burden', num(v, d), unit
    if code in (0x9B, 0x9C):                            # burden display on / off
        return 'burden', 'on' if code == 0x9B else 'off', ''
    if code in (1, 2):                                  # VA modes: voltage page
        if fl & 0x80:
            return 'voltage', 'OFL', ''
        return 'voltage', num(v, d), 'V'
    if 0x10 <= code <= 0x15:                            # VA modes: current page; "m" lit except 15/24 at d = 3
        if fl & 0x80:
            return 'current', 'OFL', ''
        return 'current', num(v, d), 'A' if (mode in (15, 24) and d == 3) else 'mA'
    if code == 11:                                      # diode source (DIODE item 10)
        return 'source', '%d' % v, 'V'
    return '', '', ''                                   # code 0: a page the frame says nothing about


def _symbols(f):
    s15, s16, s17 = f[15], f[16], f[17]
    out = []
    if s15 & 0x10:
        out.append('AC')
    if s15 & 0x08:
        out.append('DC')
    if s15 & 0x04:
        out.append('AUTO')
    if s15 & 0x02:
        out.append('APO')
    if s15 & 0x01:
        out.append('BAT')
    if s15 & 0x40:
        out.append('1kHz')
    peak = bool(s15 & 0x20)
    if peak:
        out.append('PEAK')
    if s16 & 0x40:
        out.append('BT')
    if s16 & 0x20:
        out.append('HV')
    if s16 & 0x10:
        out.append('REL')
    mm = s16 & 0x07
    if peak:
        out += {1: ['MAX'], 2: ['MIN']}.get(mm, [])
    else:
        out += {1: ['MAX'], 2: ['MIN'], 3: ['AVG'], 4: ['MIN', 'MAX', 'AVG']}.get(mm, [])
    h = (s17 >> 2) & 3
    if h == 1:
        out.append('A-HOLD')
    elif h == 2:
        out.append('HOLD')
    if s17 & 0x10:
        out.append('MEM')
    return out


def _bar(f):
    """Bargraph (table C): shown unless [13] bit 4; segment 0 always lit plus [14] segments (capped at 25, OF-65);
    polarity [13] bit 2; full-scale label from the scale code [13] bits 1..0."""
    if f[13] & 0x10:
        return {'shown': False, 'lit': 0, 'negative': False, 'label': ''}
    count = min(f[14], 25)
    return {'shown': True, 'lit': count + 1, 'negative': bool(f[13] & 0x04),
            'label': ('5', '50', '500', '1000')[f[13] & 0x03]}


def decode(f, t):
    """Reading of a checked 19-byte status frame received at time t (seconds since the epoch)."""
    mode, rng = f[5] & 0x3F, f[6] & 0x0F
    text, value, unit, dp = _main(f, mode, rng)
    label, sub_text, sub_unit = _sub(f, mode)
    return {'t': t, 'mode': mode, 'mode_name': MODES[mode] if mode < len(MODES) else 'mode %d' % mode, 'range': rng,
            'text': text if text is not None else '-----', 'value': value, 'unit': unit, 'dp': dp,
            'overload': text == 'OFL', 'sub_label': label, 'sub_text': sub_text, 'sub_unit': sub_unit,
            'symbols': _symbols(f), 'bar': _bar(f), 'raw': f.hex()}
