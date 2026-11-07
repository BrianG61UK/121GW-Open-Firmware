"""Remote keys: the meter's eight keys as key frames F4 (firmware ble/commands.s fn_0800C332, key/keys.s fn_08014AE6).

The meter takes a key frame F4 hh hh (code as an ASCII hex pair twice, frames.key_frame) and runs the key as if it had
been pressed.  The codes (key/keys.s fn_08014AE6, branches 0x08014B06..0x08014B4E; the comment there names the keys):

    short press   1 RANGE   2 HOLD   3 REL   4 PEAK   5 MODE   6 MIN/MAX   7 MEM   8 SETUP
    long press    0x81 .. 0x88 = the same keys with bit 7 set (0x08014B68..0x08014B82)

Any other code runs no key (r5 stays 0: 0x08014B56 and 0x08014BB8 skip the handlers); 0x90 .. 0x95 are not keys
(version, update mode, bootloader version, extended diagnosis on / off / counters: frames.py).  A remote key counts as a key press for the backlight countdown
(pwr_bl_restart, keys.s fn_08014AE6) and a remote SETUP is refused by the meter while logging and starts an offset
calibration in calibration mode (FEATURES.md 2.11 stage 4), so the page asks for a deliberate click on SETUP.
Nothing arrives at the key routine while the SETUP page Ld owns the link (bft_active, ble/bft.s): the caller refuses then.
"""
from . import frames

# name -> short code; the names are the ones on the keys of the meter (the UI sends them in upper case, any case works)
CODES = {'RANGE': 1, 'HOLD': 2, 'REL': 3, 'PEAK': 4, 'MODE': 5, 'MINMAX': 6, 'MEM': 7, 'SETUP': 8}
LONG_BIT = 0x80
_ALIASES = {'MIN/MAX': 'MINMAX', 'MIN_MAX': 'MINMAX', 'MIN-MAX': 'MINMAX'}


def code(name, long=False):
    """Key code of the key `name` (short press, or long press when `long`); ValueError for an unknown name."""
    key = str(name).strip().upper()
    key = _ALIASES.get(key, key)
    if key not in CODES:
        raise ValueError('unknown key %r (keys: %s)' % (name, ', '.join(CODES)))
    return CODES[key] | (LONG_BIT if long else 0)


def frame(name, long=False):
    """The F4 frame that presses the key."""
    return frames.key_frame(code(name, long))
