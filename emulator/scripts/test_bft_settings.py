"""Induced emulator test of the remote settings of the Bluetooth link (production image, DESIGN.md 10 IMP-37,
FEATURES.md 2.11 stage 6, firmware/src/ble/bftset.s): GET (type 0x16) and PUT (type 0x17).

    python -I emulator/scripts/test_bft_settings.py [image]         default firmware/build/EEVBlog.bin

Two emulated meters, both with the bundled synthetic EEPROM.  The reference meter is driven through the real SETUP pages
with the keys (item poked, long SETUP = edit, REL until the page's RAM variable has the wanted value, long SETUP = save);
for every setting the EEPROM byte and the RAM variable it ends with are recorded.  The second meter shows the page Ld
(Bluetooth on) and takes PUT requests over the emulated USART2 (host side emulator/tools/btft.py).
  T1 reference: the 17 pages (the four pages of EEPROM 0x020 together; the page APO for 0x016 and for the time 0x02B)
     give the recorded EEPROM byte and RAM value.
  T2 GET: the 18 ids in table order with the values of the synthetic EEPROM as the pages show them.
  T3 round trip: every id with 2 .. 4 values (the first is the one the reference meter's page gave): status 0, the answer
     names the id and the value now in effect, the EEPROM byte and the RAM variable equal the reference's for the first
     value and the page's rules for the others (byte = value, RAM = value - bias), and no other EEPROM byte changed (the
     whole 1280-byte EEPROM is compared after every PUT).
  T4 refusals: below the minimum and above the maximum of every id, a trigger of 3 and bits 7..5 in id 0x020, ids that
     are not settings (rotary memory, identity, calibration, restore, user zero, the logging interval 0x018), a payload of
     2 and of 4 bytes: status 0x22, nothing changed.
  T5 gate: with logging on, with calibration mode on and with another SETUP page shown a PUT gets no answer and changes
     nothing; with a setting being edited on the meter (set_edit) it is answered with status 3 and changes nothing.
  T6 the last GET equals the values written, the EEPROM differs from the start only in the ids written, and the
     emulator reports no unmodelled access and no safety violation (the NVM allow table was never offended).
The helpers are those of test_bft_files.py, test_bt_upload.py and test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_bft_files as F  # noqa: E402
import test_bt_upload as U  # noqa: E402
import btft  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_MODE = 0x2000803C
ADDR_EDIT = 0x2000806E                               # set_edit
ADDR_LOGGING = F.ADDR_LOGGING
ADDR_CAL_MODE = F.ADDR_CAL_MODE

# id, name, RAM variable (symbol of the map, or an address), bias, min, max, values (the first one is driven on the
# reference meter), setup item of the page, meter mode that the page needs (None: any), value shown by GET at the start
# pages that edit a copy and store the setting only on the save: the copy is what REL changes (set/setup.s:57)
EDIT_BUF = {0x01B: 0x200080A9}

SPEC = [
    (0x00F, 'tc', 'mtmp_tc_type', 0, 0, 5, [3, 5, 0], 23, None, 0),
    (0x010, 'temperature unit', 0x200080AB, 0, 0, 1, [0, 1], 0, None, 1),
    (0x011, 'dBm reference', 'set_dbm_ref', 0, 0, 3, [2, 3, 0], 11, 2, 0),
    (0x013, 'display level', 'func_dsp_level', 0, 0, 1, [1, 0], 24, None, 0),
    (0x014, 'continuity threshold', 0x200080B6, 0, 0, 15, [7, 15, 0], 10, 10, 0),
    (0x015, 'Bluetooth rate', 'ble_rate', 0, 0, 3, [3, 1, 0], 21, None, 0),
    (0x016, 'auto power-off off', 0x20008039, 0, 0, 1, [1, 0], 2, None, 0),
    (0x017, 'backlight auto-off', 'pwr_bl_setting', 0, 0, 100, [5, 100, 0], 20, None, 0),
    (0x01A, 'LCD contrast', 0x20000237, 0, 10, 17, [16, 10, 17, 14], 4, None, 14),
    (0x01B, 'VA burden bd', 0x200080A8, 0, 0, 1, [1, 0], 11, 15, 0),
    (0x01E, 'buzzer', 0x20008078, 0, 0, 1, [0, 1], 3, None, 1),
    (0x020, 'REL / trigger / clock / anti-hunting', None, 0, 0, 31, [0x1B, 0x04, 0x15, 0x00], None, None, 0),
    (0x021, 'continuity hold', 'set_bh_code', 0, 0, 3, [2, 3, 0], 26, None, 0),
    (0x022, 'change threshold', 'log_ch_thr', 0, 1, 255, [7, 255, 1], 31, None, 1),
    (0x028, 'current loop', 'set_lp_code', 0, 0, 2, [1, 2, 0], 37, None, 0),
    (0x029, 'RTD', 'set_rtd_code', 0, 0, 2, [2, 1, 0], 38, None, 0),
    (0x02A, 'battery trim', 'set_btrim', 100, 50, 150, [105, 50, 150, 100], 1, None, 100),
    (0x02B, 'auto power-off time', 'pwr_apo_code', 0, 0, 3, [3, 1, 0], 2, None, 0),
]
# EEPROM bytes a page's save writes: the page APO (item 2) saves its on / off byte 0x016 and its time 0x02B together
SAVES = {s[0]: {s[0]} for s in SPEC}
SAVES[0x016] = SAVES[0x02B] = {0x016, 0x02B}
NOT_SETTINGS = [0x000, 0x001, 0x003, 0x007, 0x008, 0x009, 0x00A, 0x00B, 0x00C, 0x00D, 0x00E, 0x012, 0x018, 0x019, 0x01F, 0x023,
                0x026, 0x02C, 0x030, 0x2D0, 0x2E0, 0x4D0, 0x4F8, 0x500, 0xFFFF]
B20_VARS = ('set_relp', 'log_trig', 'set_clk12', 'set_hunt_on')


class Meter:
    def __init__(self, image, mapfile):
        self.image, self.map = image, mapfile
        self.sym = {}

    def addr(self, ram):
        if isinstance(ram, int):
            return ram
        if ram not in self.sym:
            self.sym[ram] = T.symbol(self.map, ram)
        return self.sym[ram]

    def ram(self, e, spec):
        """The RAM variable(s) of a setting as a tuple of bytes."""
        names = B20_VARS if spec[2] is None else (spec[2],)
        return tuple(T.rd(e, self.addr(n)) for n in names)


def want_ram(spec, value):
    """RAM bytes the page leaves for `value` (EEPROM 0x020: the four variables)."""
    if spec[2] is None:
        return (value & 1, value >> 1 & 3, value >> 3 & 1, value >> 4 & 1)
    return ((value - spec[3]) & 0xFF,)


def reference(m, spec_list):
    """Drive the real SETUP pages on a meter with the synthetic EEPROM: {id: (EEPROM byte, RAM tuple)}."""
    T.Emulator.sdcard_path = None
    e = T.make(m.image)
    e.command({'dial': 2})
    e.advance(3.0)
    out = {}

    def page(spec, item, mode, target, ram_addr, watch=None):
        watch = ram_addr if watch is None else watch
        if mode is not None:
            e.m.uc.mem_write(ADDR_MODE, bytes([mode]))
        e.m.uc.mem_write(ADDR_ITEM, bytes([item]))
        e.advance(0.4)
        T.long_press(e, 'SETUP')
        T.check('%s: long SETUP starts the edit (item %d)' % (spec[1], item), T.rd(e, ADDR_EDIT) == 1)
        for _ in range(40):
            if T.rd(e, watch) == target:
                break
            T.press(e, 'REL', gap=0.4)
        T.check('%s: REL brought the page to %d' % (spec[1], target), T.rd(e, watch) == target, 'at %d' % T.rd(e, watch))
        T.long_press(e, 'SETUP')
        e.advance(1.0)
        T.check('%s: long SETUP saves, edit off' % spec[1], T.rd(e, ADDR_EDIT) == 0)

    for spec in spec_list:
        before = bytes(e.m.eeprom)
        if spec[2] is None:
            v = spec[6][0]                           # EEPROM 0x020: the four pages rEL (22), tr (30), CL (25), HUnt (41)
            page(spec, 22, None, v & 1, m.addr('set_relp'))
            page(spec, 30, None, v >> 1 & 3, m.addr('log_trig'))
            page(spec, 25, None, v >> 3 & 1, m.addr('set_clk12'))
            page(spec, 41, None, v >> 4 & 1, m.addr('set_hunt_on'))
        else:
            ram = m.addr(spec[2])
            target = (spec[6][0] - spec[3]) & 0xFF
            page(spec, spec[7], spec[8], target, ram, EDIT_BUF.get(spec[0]))
        diff = {i for i in range(len(before)) if before[i] != e.m.eeprom[i]}
        T.check('%s: the pages changed only EEPROM %s' % (spec[1], ', '.join('0x%03X' % i for i in sorted(SAVES[spec[0]]))),
                diff <= SAVES[spec[0]], 'diff %r' % sorted(diff))
        out[spec[0]] = (e.m.eeprom[spec[0]], m.ram(e, spec))
    return out


def run_tests(image):
    mapfile = os.path.join(os.path.dirname(image), '121gw.map')
    m = Meter(image, mapfile)
    print('T1 reference: the real SETUP pages')
    ref = reference(m, SPEC)
    for spec in SPEC:
        v = spec[6][0]
        eb, rv = ref[spec[0]]
        T.check('page 0x%03X %s = %d: EEPROM byte %d, RAM %r' % (spec[0], spec[1], v, eb, rv),
                eb == v and rv == want_ram(spec, v))

    print('T2 GET')
    e, link = U.open_page(image, U.new_card())
    f = F.Files(link)
    eeprom_start = bytes(e.m.eeprom)
    a = f.ask(btft.get_packet)
    got = btft.parse_get(a) if F.status_of(a) == 0 else {}
    T.check('GET: status 0, %d settings' % len(SPEC), F.status_of(a) == 0 and a.field == len(SPEC) and len(a.data) == 3 * len(SPEC),
            repr(a))
    T.check('ids in table order', list(got) == [s[0] for s in SPEC], repr([hex(i) for i in got]))
    T.check('values at the start (as the pages show them)', got == {s[0]: s[9] for s in SPEC},
            repr({hex(i): v for i, v in got.items() if v != {s[0]: s[9] for s in SPEC}[i]}))

    print('T3 round trip')
    last = {}
    for spec in SPEC:
        sid = spec[0]
        for n, value in enumerate(spec[6]):
            before = bytes(e.m.eeprom)
            a = f.ask(btft.put_packet, sid, value)
            ok = F.status_of(a) == 0 and a.field == sid and a.data == bytes([value])
            T.check('PUT 0x%03X %s = %d: status 0, id and value in the answer' % (sid, spec[1], value), ok, repr(a))
            diff = {i for i in range(len(before)) if before[i] != e.m.eeprom[i]}
            T.check('  only EEPROM %s may change' % ', '.join('0x%03X' % i for i in sorted(SAVES[sid])), diff <= SAVES[sid],
                    'diff %r' % sorted(diff))
            T.check('  EEPROM byte = %d' % value, e.m.eeprom[sid] == value, 'byte %d' % e.m.eeprom[sid])
            T.check('  RAM %r' % (want_ram(spec, value),), m.ram(e, spec) == want_ram(spec, value), 'RAM %r' % (m.ram(e, spec),))
            if n == 0:
                eb, rv = ref[sid]
                T.check('  equal to what the page gave: EEPROM %d, RAM %r' % (eb, rv), e.m.eeprom[sid] == eb and m.ram(e, spec) == rv)
            last[sid] = value
    # the side effects of the pages that have one, seen in the RAM they act on
    a = f.ask(btft.get_packet)
    T.check('GET after the round trip names the last values', F.status_of(a) == 0 and btft.parse_get(a) == last, repr(a))

    print('T4 refusals')
    before = bytes(e.m.eeprom)
    ram_before = {s[0]: m.ram(e, s) for s in SPEC}
    bad = 0
    for spec in SPEC:
        sid = spec[0]
        if spec[2] is None:
            values = [0x20, 0x06, 0x0E, 0xFF]        # bit 5 (bits 7..5 are no settings), trigger 3 (twice)
        else:
            values = ([spec[4] - 1] if spec[4] > 0 else []) + ([spec[5] + 1, 255] if spec[5] < 255 else [])
        for value in values:
            a = f.ask(btft.put_packet, sid, value)
            bad += F.status_of(a) != 0x22
            if F.status_of(a) != 0x22:
                T.check('PUT 0x%03X = %d refused (0x22)' % (sid, value), False, repr(a))
    T.check('every value outside the range of its id refused with 0x22', bad == 0)
    bad = 0
    for sid in NOT_SETTINGS:
        a = f.ask(btft.put_packet, sid, 1)
        bad += F.status_of(a) != 0x22
        if F.status_of(a) != 0x22:
            T.check('PUT 0x%03X (not a setting) refused (0x22)' % sid, False, repr(a))
    T.check('%d ids that are no settings refused with 0x22' % len(NOT_SETTINGS), bad == 0)
    for n in (2, 4):
        a = link.send(btft.packet(btft.T_PUT, 90 + n, bytes(n)))
        T.check('PUT with a %d-byte payload: 0x22' % n, F.status_of(a) == 0x22, repr(a))
    a = link.send(btft.packet(btft.T_GET, 95, b'\x00'))
    T.check('GET with a payload: 0x22', F.status_of(a) == 0x22, repr(a))
    T.check('nothing changed by the refusals', bytes(e.m.eeprom) == before and {s[0]: m.ram(e, s) for s in SPEC} == ram_before)

    print('T5 gate')
    eeprom_gate = bytes(e.m.eeprom)
    for name, addr in (('logging on', ADDR_LOGGING), ('calibration mode on', ADDR_CAL_MODE)):
        e.m.uc.mem_write(addr, bytes([1]))
        e.advance(0.5)
        a = link.send(F.quiet_packet(btft.put_packet, 0x017, 9), timeout=2.0)
        T.check('%s: no answer to PUT' % name, a is None, repr(a))
        e.m.uc.mem_write(addr, bytes([0]))
        e.advance(0.6)
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    e.advance(0.4)
    a = link.send(F.quiet_packet(btft.put_packet, 0x017, 9), timeout=2.0)
    T.check('another page shown: no answer to PUT', a is None, repr(a))
    F.reopen(e)
    e.m.uc.mem_write(ADDR_EDIT, bytes([1]))
    a = f.ask(btft.put_packet, 0x017, 9)
    T.check('a setting being edited on the meter: status 3', F.status_of(a) == 3, repr(a))
    a = f.ask(btft.get_packet)
    T.check('GET is still answered while an edit is on', F.status_of(a) == 0, repr(a))
    e.m.uc.mem_write(ADDR_EDIT, bytes([0]))
    T.check('the gate refusals changed nothing', bytes(e.m.eeprom) == eeprom_gate and T.rd(e, m.addr('pwr_bl_setting')) == 0)
    a = f.ask(btft.put_packet, 0x017, 9)
    T.check('edit off, page Ld, logging off: PUT 0x017 = 9 accepted again', F.status_of(a) == 0 and T.rd(e, m.addr('pwr_bl_setting')) == 9,
            repr(a))
    last[0x017] = 9

    print('T6 the whole EEPROM')
    diff = {i for i in range(len(eeprom_start)) if eeprom_start[i] != e.m.eeprom[i]}
    T.check('EEPROM differs from the start only in the ids written (%s)' % ' '.join('%03X' % i for i in sorted(diff)),
            diff <= set(last), repr(sorted(diff)))
    T.check('every id written holds its last value', all(e.m.eeprom[i] == v for i, v in last.items()))
    a = f.ask(btft.get_packet)
    T.check('the last GET equals the values written', F.status_of(a) == 0 and btft.parse_get(a) == last, repr(a))
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
