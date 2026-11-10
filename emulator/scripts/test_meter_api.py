"""Induced emulator test of the meter API (firmware F-1.33, DESIGN.md 10 IMP-65, firmware/src/ble/bfapi.s): WHERE (0x1B),
SHOW (0x1C), GET / PUT on every screen, through the key / clock parser of the USART2 handler outside the page Ld.

    python -I emulator/scripts/test_meter_api.py [image]         default firmware/build/EEVBlog.bin

One emulated meter with the bundled synthetic EEPROM, Bluetooth on.  Host side: emulator/tools/btft.py.
  T1 WHERE outside the page Ld: status 0, field 1 (API version), data = dial_latched, meter_mode, set_item, set_edit and
     flags 0, all read back from the emulator's RAM.
  T2 SHOW against the keys: for the functions OHM (9), BEEP (10, fixed and user threshold), DIODE (11), CAP (12), DCmA (19)
     the pages the keys reach are recorded first (SETUP presses from item 0 until item 0 again; long SETUP on SEt, then
     SETUP presses until item 0); then SHOW to each of them from item 0 gives status 0 and that page (set_edit 0), and
     SHOW to every other item 0..12, 20..46 gives 0x22 with item 0 kept; SHOW 13, 47 and 100 give 0x22.
  T3 refusals (status 3, nothing changed): SHOW and PUT with logging on and with the MEM view open (the power-on window
     is not induced), SHOW with a page being edited; in calibration mode GET, PUT and SHOW; WHERE is answered in each of these
     states with the matching flag bit.
  T4 the parser: requests whose bytes contain 0xF4, 0xF8, 0xFD and 0xFE are answered and leave the heartbeat flag
     (hb_on) as it was; a packet cut after 5 bytes, 0.3 s of silence, then a whole packet: the whole one is answered;
     a payload of 5 bytes and a wrong CRC get no answer; a key frame (F4 MODE) still works (echo; it stores the function
     in the dial memory 0x008..0x00E, which T7 allows).
  T5 PUT of the logging interval 0x018 (two-byte form) outside the page Ld: status 0, the value in effect, RAM
     set_log_interval, EEPROM 0x018..0x019 (big endian, set/settings.s fn_08011248) and no other EEPROM byte changed.
  T6 on the page Ld: WHERE has flag bit 0; SHOW 0 leaves the page (item 0) and the status frames come back.
  T7 the emulator reports no unmodelled access and no safety violation.
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

ADDR_ITEM = 0x20008037                               # set_item
ADDR_EDIT = 0x2000806E                               # set_edit
ADDR_MODE = 0x2000803C                               # meter_mode
ADDR_DIAL = 0x20008065                               # dial_latched
ADDR_CONT = 0x200080B6                               # set_cont_code
ADDR_MEMVIEW = 0x20007FE4                            # key_mem_view
ADDR_INTERVAL = 0x2000022C                           # set_log_interval (u16)
ADDR_LOGGING = F.ADDR_LOGGING
ADDR_CAL_MODE = F.ADDR_CAL_MODE
VALID = list(range(0, 13)) + list(range(20, 47))
FUNCS = [('OHM', 9, None), ('BEEP fixed', 10, 0), ('BEEP user', 10, 16), ('DIODE', 11, None), ('CAP', 12, None),
         ('DCmA', 19, None)]


class Api:
    def __init__(self, link):
        self.link, self.seq = link, 0

    def ask(self, build, *args, timeout=4.0):
        self.seq += 1
        a = self.link.send(build(self.seq, *args), timeout=timeout)
        if isinstance(a, btft.Answer2) and a.seq != self.seq:
            T.check('answer names the seq of its request', False, 'seq %d answered %d' % (self.seq, a.seq))
        return a


def keys_reach(e):
    """The pages the keys reach from item 0: SETUP presses until item 0 again, then from SEt the meter walk."""
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    e.advance(0.4)
    seen = [0]
    for _ in range(40):
        T.press(e, 'SETUP', gap=0.4)
        it = T.rd(e, ADDR_ITEM)
        if it == 0:
            break
        seen.append(it)
    if 43 in seen:
        e.m.uc.mem_write(ADDR_ITEM, bytes([43]))
        e.advance(0.4)
        T.long_press(e, 'SETUP')
        e.advance(0.4)
        for _ in range(40):
            it = T.rd(e, ADDR_ITEM)
            if it == 0:
                break
            seen.append(it)
            T.press(e, 'SETUP', gap=0.4)
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    e.advance(0.4)
    return sorted(set(seen))


def where(api):
    a = api.ask(btft.where_packet)
    return btft.parse_where(a) if F.status_of(a) == 0 else None


def run_tests(image):
    mapfile = os.path.join(os.path.dirname(image), '121gw.map')
    T.Emulator.sdcard_path = None
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')                          # Bluetooth on
    e.advance(1.0)
    link = U.Link(e)
    api = Api(link)
    eeprom_start = bytes(e.m.eeprom)

    print('T1 WHERE')
    a = api.ask(btft.where_packet)
    w = btft.parse_where(a) if F.status_of(a) == 0 else {}
    T.check('WHERE: status 0, version 1, 5 bytes', F.status_of(a) == 0 and a.field == 1 and len(a.data) == 5, repr(a))
    T.check('  dial, mode, item, edit as in RAM, flags 0',
            w == dict(w, dial=T.rd(e, ADDR_DIAL), mode=T.rd(e, ADDR_MODE), item=T.rd(e, ADDR_ITEM), edit=T.rd(e, ADDR_EDIT),
                      flags=0) and bool(w), repr(w))

    print('T2 SHOW against the keys')
    for name, mode, cont in FUNCS:
        e.m.uc.mem_write(ADDR_MODE, bytes([mode]))
        if cont is not None:
            e.m.uc.mem_write(ADDR_CONT, bytes([cont]))
        e.advance(0.6)
        reach = keys_reach(e)
        bad = []
        for item in VALID:
            e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
            e.advance(0.2)
            a = api.ask(btft.show_packet, item)
            got = T.rd(e, ADDR_ITEM)
            if item in reach:
                ok = F.status_of(a) == 0 and a.field == item and got == item and T.rd(e, ADDR_EDIT) == 0
            else:
                ok = F.status_of(a) == 0x22 and got == 0
            if not ok:
                bad.append((item, F.status_of(a), got))
        T.check('%s: the keys reach %s; SHOW reaches exactly these, 0x22 for the rest' % (name, reach), not bad, repr(bad))
    for item in (13, 47, 100):
        a = api.ask(btft.show_packet, item)
        T.check('SHOW %d (no such page): 0x22' % item, F.status_of(a) == 0x22, repr(a))
    e.m.uc.mem_write(ADDR_MODE, bytes([9]))
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    e.advance(0.6)

    print('T3 refusals')
    before = bytes(e.m.eeprom)
    # (the power-on window is not induced: key_window counts down in TIM3 and its end runs the window's close path)
    for name, addr, bit, width in (('logging on', ADDR_LOGGING, 0x02, 1), ('MEM view', ADDR_MEMVIEW, 0x04, 1)):
        e.m.uc.mem_write(addr, bytes([1] + [0] * (width - 1)))
        a1 = api.ask(btft.show_packet, 22)
        a2 = api.ask(btft.put_wide_packet, 0x017, 7)
        w = where(api)
        T.check('%s: SHOW and PUT status 3, WHERE flag 0x%02X' % (name, bit),
                F.status_of(a1) == 3 and F.status_of(a2) == 3 and w is not None and w['flags'] & bit, repr((a1, a2, w)))
        e.m.uc.mem_write(addr, bytes(width))
        e.advance(0.3)
    e.m.uc.mem_write(ADDR_EDIT, bytes([1]))
    a = api.ask(btft.show_packet, 22)
    T.check('a page being edited: SHOW status 3', F.status_of(a) == 3, repr(a))
    e.m.uc.mem_write(ADDR_EDIT, bytes([0]))
    e.m.uc.mem_write(ADDR_CAL_MODE, bytes([1]))
    sts = [F.status_of(api.ask(b, *x)) for b, x in ((btft.get_wide_packet, ()), (btft.put_wide_packet, (0x017, 7)),
                                                     (btft.show_packet, (22,)))]
    w = where(api)
    T.check('calibration mode: GET, PUT, SHOW status 3; WHERE flag 0x08', sts == [3, 3, 3] and w and w['flags'] & 0x08,
            repr((sts, w)))
    e.m.uc.mem_write(ADDR_CAL_MODE, bytes([0]))
    e.advance(0.3)
    T.check('the refusals changed nothing (EEPROM, item 0)', bytes(e.m.eeprom) == before and T.rd(e, ADDR_ITEM) == 0)

    print('T4 the parser')
    hb = T.symbol(mapfile, 'hb_on')
    hb_before = T.rd(e, hb)
    found = {}
    for seq in range(1, 4000):
        p = btft.where_packet(seq)
        for b in (0xF4, 0xF8, 0xFD, 0xFE):
            if b in p[2:] and b not in found:
                found[b] = seq
        if len(found) == 4:
            break
    T.check('requests with 0xF4, 0xF8, 0xFD, 0xFE inside found (seq %r)' % found, len(found) == 4)
    for b, seq in sorted(found.items()):
        a = link.send(btft.where_packet(seq), timeout=4.0)
        T.check('  byte 0x%02X inside (seq %d): answered' % (b, seq), F.status_of(a) == 0 and a.seq == seq, repr(a))
    T.check('  the heartbeat flag is unchanged', T.rd(e, hb) == hb_before, '%d -> %d' % (hb_before, T.rd(e, hb)))
    p = btft.where_packet(500)
    e.usart2.rx_feed(p[:5])
    e.advance(0.3)
    a = link.send(btft.where_packet(501), timeout=4.0)
    T.check('a packet cut after 5 bytes, 0.3 s, a whole packet: the whole one answered', F.status_of(a) == 0 and a.seq == 501,
            repr(a))
    a = link.send(btft.packet(btft.T_PUT, 502, bytes(5)), timeout=2.0)
    T.check('a 5-byte payload: no answer', a is None, repr(a))
    p = bytearray(btft.where_packet(503))
    p[-1] ^= 0x55
    a = link.send(bytes(p), timeout=2.0)
    T.check('a wrong CRC: no answer', a is None, repr(a))
    a = link.send(btft.where_packet(504), timeout=4.0)
    T.check('the next good packet is answered', F.status_of(a) == 0 and a.seq == 504, repr(a))
    n0 = len(e.ble_rx)
    before = bytes(e.m.eeprom)
    e.usart2.rx_feed(btft_key_frame(0x05))
    e.advance(1.0)
    T.check('a key frame (MODE) is still echoed', btft_key_frame(0x05) in bytes(e.ble_rx[n0:]))
    mode_diff = {i for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(b'\xB5' + btft_key_frame(0x92))  # a stray 0xB5, then the bootloader-version key frame (no key action)
    e.advance(1.0)
    T.check('a stray 0xB5 before a key frame: the key frame is still echoed', btft_key_frame(0x92) in bytes(e.ble_rx[n0:]))
    T.check('  MODE stored the function only in the dial memory 0x008..0x00E (%s)'
            % ' '.join('%03X' % i for i in sorted(mode_diff)), mode_diff <= set(range(0x008, 0x00F)), repr(sorted(mode_diff)))

    print('T5 PUT of the logging interval outside the page Ld')
    e.m.uc.mem_write(ADDR_MODE, bytes([9]))
    e.m.uc.mem_write(ADDR_ITEM, bytes([0]))
    e.advance(0.6)
    before = bytes(e.m.eeprom)
    a = api.ask(btft.put_wide_packet, 0x018, 0x123)
    T.check('PUT 0x018 = 291: status 0, id, value 291', F.status_of(a) == 0 and a.field == 0x018
            and a.data == struct.pack('<H', 0x123), repr(a))
    ram = T.rd(e, ADDR_INTERVAL) | T.rd(e, ADDR_INTERVAL + 1) << 8
    T.check('  RAM set_log_interval 291', ram == 0x123, 'RAM %d' % ram)
    T.check('  EEPROM 0x018..0x019 = 01 23 (big endian)', e.m.eeprom[0x018] == 0x01 and e.m.eeprom[0x019] == 0x23,
            '%02X %02X' % (e.m.eeprom[0x018], e.m.eeprom[0x019]))
    diff = {i for i in range(len(before)) if before[i] != e.m.eeprom[i]}
    T.check('  no other EEPROM byte changed', diff <= {0x018, 0x019}, repr(sorted(diff)))
    a = api.ask(btft.put_wide_packet, 0x018, 1000)
    T.check('PUT 0x018 = 1000: 0x22', F.status_of(a) == 0x22, repr(a))

    print('T6 the page Ld')
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('page Ld shown (item 39)', T.rd(e, ADDR_ITEM) == 39, 'item %d' % T.rd(e, ADDR_ITEM))
    e.advance(0.5)
    w = where(api)
    T.check('WHERE on the page Ld: item 39, flag bit 0', w is not None and w['item'] == 39 and w['flags'] & 1, repr(w))
    a = api.ask(btft.show_packet, 0)
    e.advance(0.5)
    T.check('SHOW 0 from the page Ld: status 0, item 0', F.status_of(a) == 0 and T.rd(e, ADDR_ITEM) == 0, repr(a))
    T.check('  the status frames come back', U.status_frames(e, 1.5) > 0)

    print('T7 emulator')
    diff = {i for i in range(len(eeprom_start)) if eeprom_start[i] != e.m.eeprom[i]}
    T.check('EEPROM differs from the start only in 0x018..0x019 and what MODE stored (T4)',
            diff <= {0x018, 0x019} | mode_diff, repr(sorted(diff)))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def btft_key_frame(code):
    """The F4 key frame of `code` (analysis/ble_packet.md 6): F4, the code's two hex digits twice."""
    h = b'%02X' % code
    return b'\xF4' + h + h


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
