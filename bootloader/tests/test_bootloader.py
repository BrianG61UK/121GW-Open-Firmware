"""Bootloader tests in the emulator (bootloader/DESIGN.md 2, 5, 6): starter + bootloader + this project's firmware.

    python3 -I bootloader/tests/test_bootloader.py        (after `make` in firmware/ and in bootloader/)

  B1 valid firmware mark, no key: the firmware starts; no safety violation
  B2 no firmware mark: update mode ("-IAP-" on both displays, Bluetooth on)
  B3 firmware over Bluetooth, two packets in flight: START (erase), DATA, END; the meter restarts into the new
     firmware; the flash holds the image, the firmware mark its length and CRC; the transfer time is printed
  B4 a power cut in the middle of B3: the bootloader comes up in update mode (mark erased), a second transfer works
  B5 the firmware's request (key code 0x91): restart into update mode
  B6 MEM + HOLD at power-on, nothing else: update mode, the firmware starts after 30 s
  B7 card update: MEM + HOLD at power-on, SETUP: EEVBlog.bin programmed, " Good", firmware mark, firmware runs
  B8 card file that is not a firmware image: " FAIL", nothing erased, the old firmware still starts
  B9 bootloader update over Bluetooth (kind 2): slot, INSTALL record, the starter installs it, the new bootloader
     confirms itself (control record OK) and starts the firmware
  6.5.1 (B3, B6, B7, B9): after an update over Bluetooth the release firmware starts with Bluetooth on (the note in
     RTC_BKP1R relayed by the bootloader); after the 30 s timeout start and a card update it stays off
The data EEPROM must be unchanged after every test.
"""
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.dont_write_bytecode = True
sys.path[:0] = [os.path.join(ROOT, 'bootloader', 'tools'), os.path.join(ROOT, 'emulator', 'scripts'),
                os.path.join(ROOT, 'emulator', 'tools')]
import blimage as B                                   # noqa: E402
import test_backlight_timer as T                      # noqa: E402
import test_bt_upload as U                            # noqa: E402
import btft                                           # noqa: E402
from diff.fat32 import Volume, fat_date, fat_time     # noqa: E402
from emu.sdcard import format_fat32                   # noqa: E402
import tempfile                                       # noqa: E402

BUILD = os.path.join(ROOT, 'bootloader', 'build')
STARTER = open(os.path.join(BUILD, 'starter.bin'), 'rb').read()
BOOT = open(os.path.join(BUILD, 'bootloader.bin'), 'rb').read()
IMAGE_PATH = os.path.join(ROOT, 'firmware', 'build', 'EEVBlog.bin')
APP = open(IMAGE_PATH, 'rb').read()
KIND_FW, KIND_BL = 0, 2


def bl_version():
    """BL_VERSION of bootloader/src/bl.inc (major << 16 | minor << 8 | patch) as the STATUS 0x80 answer gives it:
    major << 8 | minor << 4 | patch (src/bl_ble.s, protocol comment)."""
    for line in open(os.path.join(ROOT, 'bootloader', 'src', 'bl.inc')):
        f = line.split()
        if len(f) >= 3 and f[0] == '.equ' and f[1] == 'BL_VERSION,':
            v = int(f[2], 16)
            return (v >> 16 & 0xFF) << 8 | (v >> 8 & 0xFF) << 4 | (v & 0xFF)
    raise SystemExit('BL_VERSION not found in bootloader/src/bl.inc')


def fw_mark(img):
    w = struct.pack('<4I', B.FW_MAGIC, len(img), B.crc32(img), 0)
    return w + struct.pack('<I', B.crc32(w))


def flash_image(mark=True, app=APP):
    f = bytearray(0x60000)
    f[:len(STARTER)] = STARTER
    f[B.BL_BASE - 0x08000000:B.BL_BASE - 0x08000000 + len(BOOT)] = BOOT
    f[B.MARK - 0x08000000:B.MARK - 0x08000000 + 20] = B.header(BOOT, 0x10000)
    f[0x6000:0x6000 + len(app)] = app
    if mark:
        f[B.FW_MARK - 0x08000000:B.FW_MARK - 0x08000000 + 20] = fw_mark(app)
    return bytes(f)


def tmp(name, data):
    path = os.path.join(T.TMP, 'blt_%d_%s' % (os.getpid(), name))
    open(path, 'wb').write(data)
    return path


def meter(flash, keys=(), card=None):
    """An emulator booting `flash` (the whole 384 KiB) with `keys` held at power-on."""
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card or U.new_card(), 64
    T.Emulator.flash_allow_protected = True          # the starter writes the bootloader area (B9)
    e = T.make(IMAGE_PATH, bootloader=tmp('flash.bin', flash))
    e.m.uc.mem_write(0x08000000, flash)              # the firmware file loaded after it: the flash as given
    e.ee0 = bytes(e.m.eeprom)                        # the data EEPROM as loaded: compared after the test
    for k in keys:
        e.command({'key': k, 'down': True})         # held through the power cycle (power_cycle keeps the board)
    if keys:
        power_cycle(e)
    else:
        e.m.reset()
    return e


def power_cycle(e):
    """Power off and on: the flash content is kept, RAM and peripherals restart."""
    snap = flash(e, 0x08000000, 0x60000)
    e.power_cycle()
    e.m.uc.mem_write(0x08000000, snap)
    e.m.reset()


def release(e):
    for k in ('MEM', 'HOLD'):
        e.command({'key': k, 'down': False})


def flash(e, addr, n):
    return bytes(e.m.uc.mem_read(addr, n))


def app_running(e):
    hits = 0
    for _ in range(10):
        e.advance(0.05)
        if 0x08006000 <= e.m.pc < 0x08052000:
            hits += 1
    return hits >= 8


def ble_on(e):
    """The firmware's Bluetooth switch (RAM 0x2000802B, ble_enable): 1 = on.  The image is a release build
    (BLE_AT_POWERUP 0), so a plain start leaves it 0."""
    return T.rd(e, 0x2000802B) == 1


def texts(e):
    return T.DEC.text(e.snapshot()['lcd'])[:2]


class Host:
    """The companion's side: packets into USART2, answers from what the meter sends."""
    def __init__(self, e):
        self.e, self.parser, self.seen = e, btft.AnswerParser(), 0

    def answers(self):
        new = bytes(self.e.ble_rx[self.seen:])
        self.seen = len(self.e.ble_rx)
        return self.parser.feed(new)

    def wait(self, n, timeout):
        got, t = [], 0.0
        while len(got) < n and t < timeout:
            self.e.advance(0.02)
            t += 0.02
            got += self.answers()
        return got

    def send(self, pkt, timeout=10.0):
        self.answers()
        self.e.usart2.rx_feed(pkt)
        got = self.wait(1, timeout)
        return got[0] if got else None

    def transfer(self, data, kind, version=None, cut_after=None):
        """START, DATA with two packets in flight, END; returns (END answer, seconds of emulated time)."""
        t0 = T.now(self.e)
        pay = struct.pack('<IIB', len(data), zlib.crc32(data) & 0xFFFFFFFF, kind)
        if version is not None:
            pay += struct.pack('<I', version)
        a = self.send(btft.packet(btft.T_START, 0, pay), timeout=30.0)
        if a is None or a[1] != 0:
            return a, 0.0
        pkts = btft.data_packets(data)
        inflight, n_sent, n_done = 0, 0, 0
        while n_done < len(pkts):
            while inflight < 2 and n_sent < len(pkts):
                self.e.usart2.rx_feed(pkts[n_sent])
                n_sent += 1
                inflight += 1
            got = self.wait(1, 20.0)
            if not got:
                return None, 0.0
            for seq, status, nxt in got:
                if status != 0:
                    return (seq, status, nxt), 0.0
                n_done += 1
                inflight -= 1
            if cut_after is not None and n_done >= cut_after:
                return 'cut', 0.0
        a = self.send(btft.packet(btft.T_END, len(pkts)), timeout=30.0)
        return a, T.now(self.e) - t0


def check_ee(e, _ee0=None):
    T.check('data EEPROM unchanged', bytes(e.m.eeprom) == e.ee0)


def b1(ee0):
    print('B1 valid firmware mark')
    e = meter(flash_image())
    e.advance(2.0)
    T.check('the firmware starts', app_running(e))
    T.check('no safety violation', not e.snapshot()['safety'], repr(e.snapshot()['safety']))



def b2(ee0):
    print('B2 no firmware mark')
    e = meter(flash_image(mark=False))
    e.advance(2.0)
    T.check('update mode: "-IAP-" on both displays', texts(e) == ('-1AP-', '-1AP-'), repr(texts(e)))



def b3(ee0):
    print('B3 firmware over Bluetooth')
    e = meter(flash_image(mark=False, app=b''))      # no firmware at all
    e.advance(2.0)
    new = APP
    h = Host(e)
    seen = set()
    orig_wait = h.wait

    def wait(n, timeout):                            # the main display while the transfer runs
        r = orig_wait(n, timeout)
        seen.add(texts(e)[0])
        return r
    h.wait = wait
    a, secs = h.transfer(new, KIND_FW)
    T.check('END status 0', a is not None and a[1] == 0, repr(a))
    e.advance(0.3)
    seen.add(texts(e)[0])
    T.check('percent shown while receiving ("Ld nn"), "Ld oK" at the end',
            any(t.upper().startswith('LD') and t[2:].strip().isdigit() for t in seen)
            and 'LD OK' in {t.upper() for t in seen}, repr(sorted(seen)[-4:]))
    print('     %d bytes in %.1f s emulated (%.0f B/s)' % (len(new), secs, len(new) / secs if secs else 0))
    e.advance(2.0)
    T.check('flash holds the new image', flash(e, 0x08006000, len(new)) == new)
    T.check('firmware mark: length and CRC', flash(e, B.FW_MARK, 20) == fw_mark(new))
    T.check('the new firmware runs', app_running(e))
    T.check('6.5.1: Bluetooth on after the update over Bluetooth (the note relayed)', ble_on(e))
    check_ee(e, ee0)



def b4(ee0):
    print('B4 power cut in the middle of a transfer')
    e = meter(flash_image(), keys=('MEM', 'HOLD'))
    e.advance(1.0)
    release(e)
    h = Host(e)
    r, _ = h.transfer(APP, KIND_FW, cut_after=200)
    T.check('transfer cut after 200 packets', r == 'cut', repr(r))
    power_cycle(e)
    e.advance(2.0)
    T.check('after the cut: update mode (firmware mark erased)', texts(e) == ('-1AP-', '-1AP-'), repr(texts(e)))
    a, _ = Host(e).transfer(APP, KIND_FW)
    e.advance(2.0)
    T.check('second transfer: END status 0, firmware runs', a is not None and a[1] == 0 and app_running(e), repr(a))
    check_ee(e, ee0)



def b5(ee0):
    print('B5 update-mode request of the firmware (0x91)')
    e = meter(flash_image())
    e.advance(2.0)
    e.command({'dial': 2})
    e.advance(2.0)
    T.long_press(e, 'PEAK')                          # Bluetooth on in the firmware
    e.advance(1.0)
    e.usart2.rx_feed(b'\xF4' + b'9191')
    e.advance(2.0)
    T.check('update mode after the request', texts(e) == ('-1AP-', '-1AP-'), repr(texts(e)))
    st = Host(e).send(btft.packet(5, 0, b'\x80'))
    want = bl_version()
    T.check('STATUS 0x80 answers the bootloader version (bl.inc BL_VERSION, 0x%03X)' % want,
            st is not None and st[1] == 0 and st[2] == want, repr(st))



def b6(ee0):
    print('B6 MEM + HOLD at power-on, no action')
    e = meter(flash_image(), keys=('MEM', 'HOLD'))
    e.advance(1.0)
    T.check('update mode', texts(e) == ('-1AP-', '-1AP-'), repr(texts(e)))
    release(e)
    e.advance(27.0)
    T.check('still in update mode after 28 s', texts(e) == ('-1AP-', '-1AP-'), repr(texts(e)))
    e.advance(4.0)
    T.check('the firmware starts after 30 s', app_running(e))
    T.check('6.5.1: no note (no transfer): Bluetooth off', not ble_on(e))



def b7(ee0):
    print('B7 card update')
    new = APP
    old = APP[:-16] + b'OLD FIRMWARE....'           # installed: a different image with its own valid mark
    e = meter(flash_image(app=old), keys=('MEM', 'HOLD'), card=_card_with(new))
    e.advance(1.0)
    release(e)
    e.advance(0.5)
    T.press(e, 'SETUP', hold=0.3, gap=0.2)
    shown = set()
    for _ in range(250):                             # programming, then the result for 2 s, then the firmware
        e.advance(0.1)
        shown.add(texts(e)[0])
        if 0x08006000 <= e.m.pc < 0x08052000:
            break
    T.check('" Good" shown (the font draws G as on the old bootloader: "9ooD" to the decoder)',
            ' 9ooD' in shown, repr(sorted(shown)))
    T.check('flash and firmware mark of the card file', flash(e, 0x08006000, len(new)) == new
            and flash(e, B.FW_MARK, 20) == fw_mark(new))
    T.check('the new firmware runs', app_running(e))
    T.check('6.5.1: no note after a card update: Bluetooth off', not ble_on(e))
    check_ee(e, ee0)



def b8(ee0):
    print('B8 card file that is not a firmware image')
    e = meter(flash_image(), keys=('MEM', 'HOLD'), card=_card_with(bytes(0x400)))
    e.advance(1.0)
    release(e)
    e.advance(0.5)
    T.press(e, 'SETUP', hold=0.3, gap=0.2)
    shown = set()
    for _ in range(60):
        e.advance(0.1)
        shown.add(texts(e)[0])
    T.check('" FAIL" shown', any('FA1L' in s.upper() for s in shown), repr(sorted(shown)))
    T.check('nothing erased: firmware and mark unchanged', flash(e, 0x08006000, len(APP)) == APP
            and flash(e, B.FW_MARK, 20) == fw_mark(APP))



def b9(ee0):
    print('B9 bootloader update over Bluetooth')
    e = meter(flash_image(), keys=('MEM', 'HOLD'))
    e.advance(1.0)
    release(e)
    a, secs = Host(e).transfer(BOOT, KIND_BL, version=0x00010001)
    T.check('END status 0', a is not None and a[1] == 0, repr(a))
    e.advance(4.0)                                   # restart, the starter installs (about 1 s), the firmware starts
    area = flash(e, B.CTL_BASE, 64)
    recs = [struct.unpack_from('<III', area, o)[1:] for o in range(0, 64, 16) if any(area[o:o + 16])]
    # slot A is free (the running bootloader of this flash image did not come from a slot): INSTALL A, then the
    # starter's TRIAL with the previous slot B, then the new bootloader's OK
    T.check('records INSTALL slot A, TRIAL slot B, OK', recs[:3] == [(B.CMD_INSTALL, B.SLOT_A), (B.CMD_TRIAL, B.SLOT_B),
                                                                    (B.CMD_OK, 0)], repr(recs))
    T.check('bootloader mark: version 1.0.1', B.parse_header(flash(e, B.MARK, 20)) == (len(BOOT), B.crc32(BOOT),
                                                                                         0x00010001))
    T.check('the firmware runs', app_running(e))
    T.check('6.5.1: the new bootloader relays the note: Bluetooth on', ble_on(e))
    check_ee(e, ee0)


def main(argv):
    """Run the scenarios named in argv (e.g. B3 B7), or all."""
    names = [a.upper() for a in argv] or list(SCENARIOS)
    ee0 = None
    for n in names:
        ee0 = SCENARIOS[n](ee0)
    if T.fails:
        print('FAILED: %d checks' % len(T.fails))
        return 1
    print('bootloader: all checks passed (%s)' % ' '.join(names))
    return 0


def _card_with(data):
    """A 64 MiB FAT32 card image holding EEVBlog.bin = data."""
    path = os.path.join(tempfile.mkdtemp(prefix='blc_'), 'card.img')
    format_fat32(path, 64 * 1024 * 1024)
    with Volume(path, writable=True) as v:
        v.add_file('EEVBLOG.BIN', data, fat_date(2026, 11, 4), fat_time(12, 0, 0))
    return path


SCENARIOS = {n: globals()[n.lower()] for n in ['B1', 'B2', 'B3', 'B4', 'B5', 'B6', 'B7', 'B8', 'B9']}

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
