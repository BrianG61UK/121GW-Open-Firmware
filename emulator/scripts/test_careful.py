"""Induced emulator test of the careful mode for meters with the old BLE112 Bluetooth module (firmware IMP-50:
ble/usart.s ble_tx_pump, ble/commands.s key codes 0x97 / 0x98, ble/bftsd.s LIST max and CHUNK len).

    python -I emulator/scripts/test_careful.py [image]                default firmware/build/EEVBlog.bin

Meters with the BLE112 module damage single bytes on the way from the meter to the computer (GitHub issue 9); the
companion recognises them by the negotiated packet size (MTU 23) and then asks for small answers and for every status
frame twice.  The firmware side:
  K1 key code 0x97: echoed; each status frame (F2) is then followed at once by its copy, which starts with F3 (the XOR
     byte adjusted) and has the same 17 value bytes
  K2 key code 0x98: echoed; single frames again
  K3 switching Bluetooth off and on clears the careful mode (RAM only)
  K4 page Ld, LIST start(2) max(1): at most max entries per answer, the pages together equal the plain LIST (start(2));
     max 0 is refused (0x22)
  K5 CHUNK idx(2) len(1): the staged bytes idx*len .. (len bytes, fewer at the end), equal to the plain 232-byte
     CHUNKs; len 0 and len 233 are refused (0x22)
  K6 (IMP-55, F-1.25) key codes 0x99..0x9C: echoed; the status frames then come at 2, 4, 10, 20 per second (code + 1
     in ble_rate_link); the saved rate (ble_rate) and the EEPROM byte 0x015 stay as they were
  K7 (IMP-55) page Ld, settings GET start(1) max(1): at most max entries, field = entries | 0x8000 with the last setting,
     the pages together equal the plain GET; max 0 and start beyond the table refused (0x22); start = the table's
     length: no entry and the end
RUN LIMIT: 1 run of this script (4 boots).
The helpers are those of test_bft_files.py, test_bt_upload.py, test_ble_version.py and test_backlight_timer.py.
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

ADDR_BLE_ON = 0x2000802B
FRAME = 19


def key_frame(code):
    return b'\xF4' + (b'%02X' % code) * 2


def frames_with_times(e, n0):
    """(time, frame) of every valid status frame (F2 + 18 bytes, XOR 0) and copy (F3, IMP-50) sent since index n0."""
    data = bytes(e.ble_rx[n0:])
    times = e.ble_rx_times[n0:]
    out, i = [], 0
    while i + FRAME <= len(data):
        if data[i] in (0xF2, 0xF3):
            x = 0
            for b in data[i:i + FRAME]:
                x ^= b
            if x == 0:
                out.append((times[i], data[i:i + FRAME]))
                i += FRAME
                continue
        i += 1
    return out


def boot(image):
    e = T.make(image)
    e.ble_rx_times = []
    e.usart2.on_tx.append(lambda b: e.ble_rx_times.append(float(e.m.elapsed_s())))
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    return e


def pairs(fr):
    """Count of F2 frames followed at once (less than 15 ms after it ended) by their F3 copy: the same 17 value bytes."""
    n = 0
    for (t0, f0), (t1, f1) in zip(fr, fr[1:]):
        if f0[0] == 0xF2 and f1[0] == 0xF3 and f0[1:18] == f1[1:18] and t1 - t0 < (FRAME * 10 / 19200) + 0.015:
            n += 1
    return n


def copies(fr):
    return sum(1 for _, f in fr if f[0] == 0xF3)


def run_tests(image):
    print('K1 / K2 / K3 the status frames')
    e = boot(image)
    T.check('Bluetooth on', T.rd(e, ADDR_BLE_ON) == 1)
    n0 = len(e.ble_rx)
    e.advance(3.0)
    fr = frames_with_times(e, n0)
    T.check('K1: without careful mode no copy is sent', copies(fr) == 0 and len(fr) >= 4, '%d frames' % len(fr))
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(key_frame(0x97))
    e.advance(0.5)
    T.check('K1: 0x97 echoed', key_frame(0x97) in bytes(e.ble_rx[n0:]))
    n0 = len(e.ble_rx)
    e.advance(3.0)
    fr = frames_with_times(e, n0)
    T.check('K1: every frame followed by its F3 copy, back to back', len(fr) >= 8 and pairs(fr) * 2 >= len(fr) - 1,
            '%d frames, %d pairs' % (len(fr), pairs(fr)))
    e.usart2.rx_feed(key_frame(0x98))
    e.advance(0.5)
    n0 = len(e.ble_rx)
    e.advance(3.0)
    fr = frames_with_times(e, n0)
    T.check('K2: after 0x98 single frames again', copies(fr) == 0 and len(fr) >= 4, '%d frames, %d copies' % (len(fr), copies(fr)))
    e.usart2.rx_feed(key_frame(0x97))
    e.advance(0.5)
    T.long_press(e, 'PEAK')
    e.advance(0.5)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    T.check('K3: Bluetooth off and on again', T.rd(e, ADDR_BLE_ON) == 1)
    n0 = len(e.ble_rx)
    e.advance(3.0)
    fr = frames_with_times(e, n0)
    T.check('K3: careful mode cleared by switching Bluetooth on', copies(fr) == 0 and len(fr) >= 4,
            '%d frames, %d copies' % (len(fr), copies(fr)))

    print('K6 frame rate for this power-on')
    e = boot(image)
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    rate_addr, link_addr = T.symbol(mp, 'ble_rate'), T.symbol(mp, 'ble_rate_link')
    saved = T.rd(e, rate_addr)
    ee_before = bytes(e.m.eeprom)
    for code, want in ((0x9C, 20), (0x9A, 4), (0x9B, 10), (0x99, 2)):
        n0 = len(e.ble_rx)
        e.usart2.rx_feed(key_frame(code))
        e.advance(0.6)
        T.check('K6: 0x%02X echoed, link rate %d, saved rate unchanged' % (code, code - 0x99),
                key_frame(code) in bytes(e.ble_rx[n0:]) and T.rd(e, link_addr) == code - 0x99 + 1 and T.rd(e, rate_addr) == saved,
                'ble_rate_link %d ble_rate %d' % (T.rd(e, link_addr), T.rd(e, rate_addr)))
        n0 = len(e.ble_rx)
        e.advance(4.0)
        n = len(frames_with_times(e, n0))
        T.check('K6: 0x%02X: %d frames per second' % (code, want), abs(n / 4.0 - want) <= max(0.6, want * 0.1),
                '%d frames in 4 s' % n)
    T.check('K6: the EEPROM is not written (0x015 keeps the saved rate)', bytes(e.m.eeprom) == ee_before)

    print('K4 / K5 page Ld: LIST max, CHUNK len')
    card, expect = F.build_card()
    e, link = U.open_page(image, card)
    f = F.Files(link)
    plain, _, a = f.list_all()
    T.check('K4: plain LIST works', plain is not None and len(plain) == len(expect), repr(a))
    out, start, ok, pages = [], 0, True, 0
    while pages < 60:
        a = f.ask(lambda seq, s: btft.packet(btft.T_LIST, seq, struct.pack('<HB', s, 3)), start)
        if F.status_of(a) != 0:
            ok = False
            break
        ents, end = btft.parse_list(a)
        ok &= len(ents) <= 3
        out += ents
        start += len(ents)
        pages += 1
        if end or not ents:
            break
    T.check('K4: LIST max 3: at most 3 entries per answer, together the plain list', ok and out == plain,
            '%d pages, %d entries' % (pages, len(out)))
    a = f.ask(lambda seq: btft.packet(btft.T_LIST, seq, struct.pack('<HB', 0, 0)))
    T.check('K4: LIST max 0 refused (0x22)', F.status_of(a) == 0x22, repr(a))
    name, size, data = next((n, s, d) for n, s, w, t, d in expect if 600 <= s <= 2000)
    a = f.read(name, 0, size)
    T.check('K5: READ %s (%d bytes) staged' % (name, size), F.status_of(a) == 0 and a.field == size, repr(a))
    whole = f.read_chunks(size)
    T.check('K5: plain CHUNKs give the file', whole == data)
    small = b''
    for idx in range(-(-size // 48)):
        a = f.ask(lambda seq, i: btft.packet(btft.T_CHUNK, seq, struct.pack('<HB', i, 48)), idx)
        if F.status_of(a) != 0 or a.field != idx:
            break
        small += a.data
    T.check('K5: CHUNK len 48 gives the same bytes', small == data, '%d of %d bytes' % (len(small), size))
    for bad in (0, 233):
        a = f.ask(lambda seq, n: btft.packet(btft.T_CHUNK, seq, struct.pack('<HB', 0, n)), bad)
        T.check('K5: CHUNK len %d refused (0x22)' % bad, F.status_of(a) == 0x22, repr(a))
    print('K7 page Ld: settings GET in pages')
    a = f.ask(lambda seq: btft.packet(0x16, seq, b''))
    whole, n_all = (a.data, a.field) if F.status_of(a) == 0 else (b'', 0)
    T.check('K7: plain GET unchanged: field = the count, no end flag', F.status_of(a) == 0 and 0 < n_all < 0x8000
            and len(whole) == 3 * n_all, repr(a))
    got, start, ok, end = b'', 0, True, False
    for _ in range(40):
        a = f.ask(lambda seq, st: btft.packet(0x16, seq, bytes([st, 4])), start)
        if F.status_of(a) != 0:
            ok = False
            break
        cnt, end = a.field & 0x7FFF, bool(a.field & 0x8000)
        ok &= cnt <= 4 and len(a.data) == 3 * cnt
        got += a.data
        start += cnt
        if end or not cnt:
            break
    T.check('K7: GET start max 4: at most 4 per answer, the last with the end flag, together the plain GET',
            ok and end and got == whole, '%d of %d bytes' % (len(got), len(whole)))
    for payload, why in ((bytes([0, 0]), 'max 0'), (bytes([n_all + 1, 4]), 'start beyond the table'), (b'\x00', 'one byte')):
        a = f.ask(lambda seq, pl: btft.packet(0x16, seq, pl), payload)
        T.check('K7: GET %s refused (0x22)' % why, F.status_of(a) == 0x22, repr(a))
    a = f.ask(lambda seq: btft.packet(0x16, seq, bytes([n_all, 4])))
    T.check('K7: GET start = the table length: no entry, the end', F.status_of(a) == 0 and a.field == 0x8000 and not a.data, repr(a))
    e.usart2.rx_feed(key_frame(0x9C))                    # a link rate of 20 a second
    e.advance(0.5)
    a = f.ask(lambda seq: btft.packet(0x16, seq, b''))
    T.check('K7: with a link rate set, GET reports the saved rate (0x015)', F.status_of(a) == 0 and a.data == whole,
            'GET data %r' % (a.data,))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'],
            'unmodelled %r safety %r' % (s['unmodelled'], s['safety']))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
