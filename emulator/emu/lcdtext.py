"""LCD text decoder: turns the LCD_DISPLAY words 0..7 of the emulated meter into display text.

Decoded segment names come from emulator/ui/assets/lcd_bits.json; the digit segments become characters with the firmware
font (analysis/lcd_map.md section 2).  Used by the emulator test scripts (emulator/scripts).
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
LCD_BITS = os.path.join(HERE, '..', 'ui', 'assets', 'lcd_bits.json')

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
