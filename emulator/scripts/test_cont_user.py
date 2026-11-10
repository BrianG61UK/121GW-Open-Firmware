"""Induced emulator test of the continuity thresholds and the user threshold (production image, FEATURES.md 2.38,
DESIGN.md 10 IMP-05 and IMP-64, firmware/src/mres/beep.s, set/cu.s).

    python -I emulator/scripts/test_cont_user.py [image]      default firmware/build/EEVBlog.bin (production build)

BEEP (dial Ohm/beep, EEPROM 0x0B = 10) with resistances applied at the input:
  T1 decision: for each of the 18 continuity codes (0..15 the table mres_beep_thr, 16 DNUSr and 17 UPUSr with a user
     threshold and hysteresis written to RAM) the tone state byte 0x200080B5 is read after five inputs: off at the start
     (open or short), on past the start threshold, still on between the start and the continue threshold (the
     hysteresis), off past the continue threshold, still off between them.  The input steps are 0.05 ohm from each
     threshold (up to 0.20 ohm where 0.05 ohm lands on an emulator torn-read code, edge_point); the point between them
     avoids those codes too (band_point).  For UPUSr with a hysteresis above the threshold the continue threshold is held at 0.01 ohm.
  T2 power-on load: EEPROM 0x02D..0x02F (threshold u16 big endian, hysteresis) and 0x014 (code) as found, defaults for
     blank and invalid bytes, the bytes left as found.
  T3 pages: the threshold page (item 10) steps through DNUSr and UPUSr in the display order and saves only 0x014; with
     a user code the walk goes dSP, bH, th (item 45), HY (item 46), Lt, with a fixed code bH, Lt; the texts "th 30",
     "HY 5.0"; REL / PEAK step and wrap; long SETUP saves only 0x02D..0x02E (th) or 0x02F (HY), the chirp byte 0x02C
     and every other byte unchanged; SETUP short ends an edit without a save.
  T4 Bluetooth status frame: codes 16 / 17 are sent as 0xBA / 0xBB with the threshold in ohm in the value bytes.
  T5 remote settings over page Ld: GET with flags 1 lists 22 entries of two-byte values (0x02D, then the logging interval
     0x018 last, IMP-65), the one-byte GET 20
     without 0x02D; the two-byte PUT of 0x02D writes 0x02D..0x02E only; refusals (0x22): 0 and 501, the one-byte PUT of
     0x02D, flags 2, 0x02F 0 and 251, 0x014 18; the whole EEPROM differs from the start only in 0x014 and 0x02D..0x02F.
The helpers are those of test_backlight_timer.py, test_bft_files.py and test_bt_upload.py.
"""
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_bft_files as F  # noqa: E402
import test_bt_upload as U  # noqa: E402
import btft  # noqa: E402

_trace = T._trace                                    # the LCD decoder module (emulator/emu/lcdtext.py)

ADDR_ITEM = 0x20008037
ADDR_MODE = 0x2000803C
ADDR_EDIT = 0x2000806E                               # set_edit
ADDR_TONE = 0x200080B5                               # continuity tone state (1 = on)
ADDR_CODE = 0x200080B6                               # continuity code (EEPROM 0x014)
ADDR_BLE_ON = 0x2000802B                             # transfer on (PEAK long)
ADDR_REDRAW = 0x20008062                             # set_redraw: the page is drawn again (set/setup.s)

# mres/beep.s mres_beep_thr {start, continue} in 0.01 ohm, codes 0..15; DN codes beep while v <= t, UP codes while v >= t
TABLE = [(3000, 3500), (3000, 2500), (30000, 30500), (30000, 29500), (100, 120), (500, 583), (1000, 1167), (5000, 5500),
         (10000, 10500), (20000, 20500), (100, 80), (500, 417), (1000, 833), (5000, 4500), (10000, 9500), (20000, 19500)]
UP = {1, 3, 10, 11, 12, 13, 14, 15, 17}
TEXT = ['DN 30', 'UP 30', 'DN300', 'UP300', 'DN  1', 'DN  5', 'DN 10', 'DN 50', 'DN100', 'DN200', 'UP  1', 'UP  5',
        'UP 10', 'UP 50', 'UP100', 'UP200', 'DNUSr', 'UPUSr']
ORDER = [4, 5, 6, 0, 7, 8, 9, 2, 16, 10, 11, 12, 1, 13, 14, 15, 3, 17]   # display order of the page (set/setup.s)
M = 5                                                # input step from a threshold, 0.01 ohm
# The point inside the hysteresis band stays away from the AD1 codes where byte 1 rolls over (multiples of 0x10000): the
# emulator's chip changes its result bytes at every conversion, so a read that a conversion overtakes is torn by
# 0x10000 there (52.50 ohm = code 0x060006, 297.50 ohm = 0x220030, measured in the emulator 2026-11-10).  On the meter
# the chip kept its result bytes between two reads 4.2 ms apart (98 of 98 pairs, no INTF read between them); whether
# the meter can tear is open.  CODES_PER_OHM: the emulator's BEEP codes per ohm (393222 / 52.50 and 2228273 / 297.50).
CODES_PER_OHM = 7490
TEAR_GUARD = 600                                     # codes kept from a multiple of 0x10000 (spread of 40 reads 130..210)


def clear_of_rollover(p):
    code = CODES_PER_OHM * p // 100
    return min(code % 0x10000, 0x10000 - code % 0x10000) >= TEAR_GUARD


def band_point(s, c):
    """The middle of the band from s to c (0.01 ohm), or its quarter points when the middle's code is near a roll-over."""
    for p in ((s + c) // 2, s + (c - s) // 4, s + 3 * (c - s) // 4):
        if clear_of_rollover(p):
            return p
    return (s + c) // 2


def edge_point(t, sign):
    """The input just past threshold t (0.01 ohm) on the side `sign`: M, or up to 4 M when that code is near a roll-over."""
    for k in (M, 2 * M, 3 * M, 4 * M):
        if clear_of_rollover(t + sign * k):
            return t + sign * k
    return t + sign * M


def shown(text):
    """The decoder's reading of `text` drawn with the firmware font (lcd/font.s; 'b' reads as 'B', 'O' as '0' ...)."""
    out = ''
    for ch in text:
        if ch == '.':
            out += '.'
            continue
        if ch == ' ':
            out += ' '
        elif ch.isdigit():
            out += _trace.GLYPHS[_trace._segs(_trace._DIGITS[int(ch)])]
        elif ch.isupper():
            out += _trace.GLYPHS[_trace._segs(_trace._UPPER[ord(ch) - 65])]
        else:
            out += _trace.GLYPHS[_trace._segs(_trace._LOWER[ord(ch) - 97])]
    return out


def beep_meter(image, patch=None):
    e = T.make(image, {0x0B: 10, **(patch or {})})
    e.command({'dial': 5})
    e.advance(3.0)
    return e


def put_input(e, centi):
    """Apply `centi` hundredths of an ohm (None: open) and let the decision run on the new readings."""
    e.command({'input': {'kind': 'open'}} if centi is None else {'input': {'kind': 'ohm', 'value': centi / 100.0}})
    e.advance(0.25)
    return T.rd(e, ADDR_TONE)


def thresholds(code, t_ohm, h_tenth):
    if code < 16:
        return TABLE[code]
    start = 100 * t_ohm
    if code == 16:
        return start, start + 10 * h_tenth
    return start, max(start - 10 * h_tenth, 1)


def decision(e, code, a_ut, a_uh, t_ohm=0, h_tenth=0, steps=None):
    e.m.uc.mem_write(a_ut, struct.pack('<H', t_ohm))
    e.m.uc.mem_write(a_uh, bytes([h_tenth]))
    put_input(e, None if code not in UP else 0)
    e.m.uc.mem_write(ADDR_CODE, bytes([code]))
    e.m.uc.mem_write(ADDR_TONE, bytes([0]))
    s, c = thresholds(code, t_ohm, h_tenth)
    mid = band_point(s, c)
    if steps is not None:
        pass
    elif code in UP:
        steps = [(0, 0), (edge_point(s, 1), 1), (mid, 1), (edge_point(c, -1), 0), (mid, 0)]
    else:
        steps = [(None, 0), (edge_point(s, -1), 1), (mid, 1), (edge_point(c, 1), 0), (mid, 0)]
    got = [put_input(e, v) for v, _ in steps]
    want = [w for _, w in steps]
    label = 'code %2d %s start %d continue %d' % (code, TEXT[code], s, c) + (' (T %d ohm, H %.1f ohm)' % (
        t_ohm, h_tenth / 10) if code >= 16 else '')
    T.check(label + ': tone %s' % want, got == want, 'got %r at %r' % (got, [v for v, _ in steps]))


def show_item(e, item):
    """Put the SETUP page `item` on the display (the item byte and the redraw request the pages use)."""
    e.m.uc.mem_write(ADDR_ITEM, bytes([item]))
    e.m.uc.mem_write(ADDR_REDRAW, bytes([1]))
    e.advance(0.6)


def ee_diff(before, e):
    return {i: (before[i], e.m.eeprom[i]) for i in range(len(before)) if before[i] != e.m.eeprom[i]}


def frame_values(e, seconds):
    """[(code byte 9, value bytes 11..12)] of the complete status frames of the next `seconds`."""
    start = len(e.ble_rx)
    e.advance(seconds)
    data = bytes(e.ble_rx[start:])
    out, i = [], 0
    while i + 19 <= len(data):
        if data[i] == 0xF2:
            x = 0
            for b in data[i:i + 19]:
                x ^= b
            if x == 0:
                out.append((data[i + 9], data[i + 11] << 8 | data[i + 12]))
                i += 19
                continue
        i += 1
    return out


def run_tests(image, a_ut, a_uh):
    print('T1 decision per code')
    e = beep_meter(image)
    T.check('BEEP mode', T.rd(e, ADDR_MODE) == 10, 'mode %d' % T.rd(e, ADDR_MODE))
    for code in range(16):
        decision(e, code, a_ut, a_uh, 30, 50)
    for t, h in ((30, 50), (1, 1), (123, 25), (500, 250), (500, 50)):
        decision(e, 16, a_ut, a_uh, t, h)
    for t, h in ((30, 50), (2, 1), (123, 25), (500, 250), (500, 50)):
        decision(e, 17, a_ut, a_uh, t, h)
    # UPUSr with the hysteresis above the threshold (3 ohm, 5.0 ohm): the continue threshold is 0.01 ohm, so the tone,
    # once on, holds at 0.20 ohm (without the floor 300 - 500 would wrap to a huge unsigned threshold: off at once)
    decision(e, 17, a_ut, a_uh, 3, 50, steps=[(0, 0), (300 + M, 1), (150, 1), (20, 1)])
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])

    print('T2 power-on load')
    for hi, lo, hy, code, want in ((0x00, 0x00, 0x00, 16, (30, 50, 16)), (0x01, 0xF4, 250, 17, (500, 250, 17)),
                                   (0x00, 0x01, 1, 15, (1, 1, 15)), (0x01, 0xF5, 251, 18, (30, 50, 0)),
                                   (0xFF, 0xFF, 0xFF, 0xFF, (30, 50, 0))):
        e = beep_meter(image, {0x2D: hi, 0x2E: lo, 0x2F: hy, 0x14: code})
        got = (T.rd(e, a_ut, 2), T.rd(e, a_uh), T.rd(e, ADDR_CODE))
        T.check('EEPROM 0x02D..0x02F = %02X %02X %02X, 0x014 = %d: threshold %d, hysteresis %d, code %d' % (
            hi, lo, hy, code, *want), got == want and bytes(e.m.eeprom[0x2D:0x30]) == bytes([hi, lo, hy]), 'got %r' % (got,))

    print('T3 pages')
    e = beep_meter(image, {0x14: 2})                 # DN300
    show_item(e, 10)
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    pos = ORDER.index(2)
    for k in range(1, 4):                            # DN300 -> DNUSr -> UP  1 -> UP  5
        T.press(e, 'REL', gap=0.5)
        e.advance(0.6)
        code = ORDER[(pos + k) % 18]
        texts = T.sample_texts(e)
        T.check('page 10 REL: code %d "%s"' % (code, TEXT[code]), T.rd(e, ADDR_CODE) == code and shown(TEXT[code]) in texts,
                'code %d samples %r' % (T.rd(e, ADDR_CODE), texts))
    e.m.uc.mem_write(ADDR_CODE, bytes([3]))          # UP300 -> UPUSr -> DN  1 (the wrap)
    for code in (17, 4):
        T.press(e, 'REL', gap=0.5)
        T.check('page 10 REL: code %d %s' % (code, TEXT[code]), T.rd(e, ADDR_CODE) == code, 'code %d' % T.rd(e, ADDR_CODE))
    for code in (17, 3):
        T.press(e, 'PEAK', gap=0.5)
        T.check('page 10 PEAK: code %d %s' % (code, TEXT[code]), T.rd(e, ADDR_CODE) == code, 'code %d' % T.rd(e, ADDR_CODE))
    T.press(e, 'REL', gap=0.5)                       # UPUSr
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    T.check('save wrote only 0x014 = 17', ee_diff(before, e) == {0x14: (2, 17)}, 'diff %r' % (ee_diff(before, e),))

    walks = ((16, [26, 45, 46, 27]), (17, [26, 45, 46, 27]), (0, [26, 27]), (15, [26, 27]))
    for code, want in walks:
        e = beep_meter(image, {0x14: code, 0x2C: 1})
        show_item(e, 24)                             # dSP
        got = []
        for _ in want:
            T.press(e, 'SETUP', gap=0.5)
            got.append(T.rd(e, ADDR_ITEM))
        T.check('code %d %s: SETUP short from dSP walks %r' % (code, TEXT[code], want), got == want, 'got %r' % got)

    e = beep_meter(image, {0x14: 16, 0x2C: 1})       # the chirp byte 0x02C shares the word 0x02C..0x02F
    show_item(e, 45)
    T.check('th shows "th 30" (blank EEPROM: 30 ohm)', shown('th 30') in T.sample_texts(e), repr(T.sample_texts(e)))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.check('long SETUP starts the edit of th', T.rd(e, ADDR_EDIT) == 1)
    for key, want in (('REL', 31), ('REL', 32), ('PEAK', 31)):
        T.press(e, key, gap=0.5)
        T.check('th %s: %d ohm' % (key, want), T.rd(e, a_ut, 2) == want, 'got %d' % T.rd(e, a_ut, 2))
    e.m.uc.mem_write(a_ut, struct.pack('<H', 500))
    T.press(e, 'REL', gap=0.5)
    T.check('th REL from 500: 1 ohm', T.rd(e, a_ut, 2) == 1, 'got %d' % T.rd(e, a_ut, 2))
    T.press(e, 'PEAK', gap=0.5)
    e.advance(0.6)
    texts = T.sample_texts(e)
    T.check('th PEAK from 1: 500 ohm, "th500"', T.rd(e, a_ut, 2) == 500 and shown('th500') in texts, repr(texts))
    T.check('nothing written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    T.check('save wrote only 0x02D..0x02E = 01 F4 (500, big endian)', ee_diff(before, e) == {0x2D: (0, 1), 0x2E: (0, 0xF4)},
            'diff %r' % (ee_diff(before, e),))
    T.press(e, 'SETUP', gap=0.5)
    T.check('SETUP short on th goes to HY (item 46)', T.rd(e, ADDR_ITEM) == 46)
    e.advance(0.6)
    T.check('HY shows "HY 5.0" (blank EEPROM: 5.0 ohm)', shown('HY 5.0') in T.sample_texts(e), repr(T.sample_texts(e)))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'PEAK', gap=0.5)
    T.check('HY PEAK: 4.9 ohm', T.rd(e, a_uh) == 49, 'got %d' % T.rd(e, a_uh))
    T.press(e, 'SETUP', gap=0.5)
    e.advance(1.0)
    T.check('SETUP short ends the edit without a save', T.rd(e, ADDR_EDIT) == 0 and bytes(e.m.eeprom) == before,
            'edit %d diff %r' % (T.rd(e, ADDR_EDIT), ee_diff(before, e)))
    e.m.uc.mem_write(a_uh, bytes([1]))
    show_item(e, 46)
    T.check('HY 0.1 ohm: "HY 0.1"', shown('HY 0.1') in T.sample_texts(e), repr(T.sample_texts(e)))
    T.long_press(e, 'SETUP')
    T.press(e, 'PEAK', gap=0.5)
    T.check('HY PEAK from 0.1: 25.0 ohm', T.rd(e, a_uh) == 250, 'got %d' % T.rd(e, a_uh))
    e.advance(0.6)
    T.check('HY 25.0 ohm: "HY25.0"', shown('HY25.0') in T.sample_texts(e), repr(T.sample_texts(e)))
    T.press(e, 'REL', gap=0.5)
    T.check('HY REL from 25.0: 0.1 ohm', T.rd(e, a_uh) == 1, 'got %d' % T.rd(e, a_uh))
    T.press(e, 'REL', gap=0.5)
    T.long_press(e, 'SETUP')
    e.advance(1.5)
    T.check('save wrote only 0x02F = 2 (0.2 ohm)', ee_diff(before, e) == {0x2F: (0, 2)}, 'diff %r' % (ee_diff(before, e),))
    T.check('the chirp byte 0x02C kept (1)', e.m.eeprom[0x2C] == 1)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])

    print('T4 Bluetooth status frame')
    for code, t in ((16, 123), (17, 500), (2, 123)):
        e = beep_meter(image, {0x14: code, 0x2D: t >> 8, 0x2E: t & 0xFF})
        show_item(e, 10)                             # the threshold page (the frame's sub display follows the page)
        T.long_press(e, 'PEAK')
        T.check('transfer on', T.rd(e, ADDR_BLE_ON) == 1)
        got = set(frame_values(e, 2.0))
        want = {(0xAA + code, t if code >= 16 else 0)}
        T.check('code %d %s: frames carry code 0x%02X, value %d' % (code, TEXT[code], 0xAA + code, t if code >= 16 else 0),
                got == want, 'got %r' % sorted(got))

    print('T5 remote settings')
    e, link = U.open_page(image, U.new_card())
    f = F.Files(link)
    start = bytes(e.m.eeprom)
    a = f.ask(btft.get_wide_packet)
    entries = btft.parse_get_wide(a) if F.status_of(a) == 0 else []
    # IMP-65: the logging interval 0x018 (two-byte, 0..999) is the last entry
    interval = T.rd(e, 0x2000022C) | T.rd(e, 0x2000022D) << 8          # set_log_interval (set/setup.s), u16
    T.check('GET flags 1: status 0, 22 entries of 4 bytes, the end', F.status_of(a) == 0 and a.field == 0x8000 | 22
            and len(a.data) == 88, repr(a))
    T.check('  0x02F (50), 0x02D (30), then 0x018 (the interval in RAM, %d) last' % interval,
            entries[-3:] == [(0x02F, 50), (0x02D, 30), (0x018, interval)], repr(entries[-3:]))
    a = f.ask(btft.get_packet)
    T.check('one-byte GET: 20 entries without 0x02D', F.status_of(a) == 0 and a.field == 20 and 0x02D not in btft.parse_get(a),
            repr(a))
    a = f.ask(btft.get_wide_packet, 20, 5)
    T.check('GET flags 1 from entry 20: 0x02D and 0x018, the end', F.status_of(a) == 0 and a.field == 0x8002
            and btft.parse_get_wide(a) == [(0x02D, 30), (0x018, interval)], repr(a))
    a = f.ask(btft.get_wide_packet, 0, 255, 2)
    T.check('GET flags 2: 0x22', F.status_of(a) == 0x22, repr(a))
    before = bytes(e.m.eeprom)
    a = f.ask(btft.put_wide_packet, 0x02D, 499)
    T.check('two-byte PUT 0x02D = 499: status 0, id, value 499 (2 bytes)', F.status_of(a) == 0 and a.field == 0x02D
            and a.data == struct.pack('<H', 499), repr(a))
    T.check('  only 0x02D..0x02E = 01 F3 written, RAM 499', ee_diff(before, e) == {0x2D: (0, 1), 0x2E: (0, 0xF3)}
            and T.rd(e, a_ut, 2) == 499, 'diff %r' % (ee_diff(before, e),))
    a = f.ask(btft.put_packet, 0x02F, 12)
    T.check('one-byte PUT 0x02F = 12: status 0, EEPROM 12, RAM 12', F.status_of(a) == 0 and a.data == bytes([12])
            and e.m.eeprom[0x2F] == 12 and T.rd(e, a_uh) == 12, repr(a))
    a = f.ask(btft.put_wide_packet, 0x014, 17)
    T.check('two-byte PUT 0x014 = 17: status 0, value 17 (2 bytes), EEPROM 17', F.status_of(a) == 0
            and a.data == struct.pack('<H', 17) and e.m.eeprom[0x14] == 17, repr(a))
    before = bytes(e.m.eeprom)
    for build, sid, v in ((btft.put_wide_packet, 0x02D, 0), (btft.put_wide_packet, 0x02D, 501),
                          (btft.put_packet, 0x02D, 30), (btft.put_packet, 0x02F, 0), (btft.put_packet, 0x02F, 251),
                          (btft.put_packet, 0x014, 18), (btft.put_wide_packet, 0x014, 18), (btft.put_wide_packet, 0x022, 256)):
        a = f.ask(build, sid, v)
        T.check('%s 0x%03X = %d refused (0x22)' % ('two-byte PUT' if build is btft.put_wide_packet else 'PUT', sid, v),
                F.status_of(a) == 0x22, repr(a))
    a = link.send(btft.packet(btft.T_PUT, 97, bytes(5)))
    T.check('PUT with a 5-byte payload: 0x22', F.status_of(a) == 0x22, repr(a))
    T.check('nothing changed by the refusals', bytes(e.m.eeprom) == before)
    diff = set(ee_diff(start, e))
    T.check('the whole EEPROM differs from the start only in 0x014, 0x02D..0x02F', diff <= {0x14, 0x2D, 0x2E, 0x2F},
            repr(sorted(diff)))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    run_tests(image, T.symbol(mp, 'set_ut_ohm'), T.symbol(mp, 'set_uh_tenth'))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
