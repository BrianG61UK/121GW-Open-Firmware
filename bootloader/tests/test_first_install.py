"""First install of the two-part bootloader through the firmware, in the emulator (bootloader/DESIGN.md 6.4).

    python3 -I bootloader/tests/test_first_install.py [EEVBLOG_BOOTLOADER.bin ...]

The meter runs EEVblog's bootloader (default: the owner's dump inputs/binaries/dump_2026-11-04_bootloader.bin and the
2018 read-out inputs/binaries/bootloader.bin, not in the repository; a missing file is reported as SKIPPED) and this
project's firmware (firmware/build/EEVBlog.bin, `make` in firmware/).  The install file is the starter
(bootloader/build/starter.bin) and a pass-through test bootloader that starts the firmware at 0x08006000.
  I1 intermediate state: EEVblog's bootloader with pages 1..3 replaced by the starter's still starts the firmware
     (the first install writes those pages before page 0)
  I2 battery 4.5 V: END status 0x18 ("LdE 8"), nothing written
  I3 battery 6.0 V: END status 0, the meter restarts, the starter installs the bootloader from slot A, the firmware
     runs again; flash: starter, bootloader, mark, firmware mark of the running firmware, control records INSTALL then
     TRIAL; the data EEPROM is unchanged; no safety violation
  I4 a second install: END status 0x17 ("LdE 7"), nothing written
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(ROOT, 'bootloader', 'tools'))
sys.path.insert(0, os.path.join(ROOT, 'emulator', 'scripts'))
sys.path.insert(0, os.path.join(ROOT, 'emulator', 'tools'))
import blimage as B                                   # noqa: E402
import test_backlight_timer as T                      # noqa: E402
import test_bt_upload as U                            # noqa: E402
import btft                                           # noqa: E402
import zlib                                           # noqa: E402

IMAGE = os.path.join(ROOT, 'firmware', 'build', 'EEVBlog.bin')
STARTER = open(os.path.join(ROOT, 'bootloader', 'build', 'starter.bin'), 'rb').read()
INPUTS = os.path.normpath(os.path.join(ROOT, '..', '..', '121gw-re', 'inputs', 'binaries'))
DEFAULT_BL = [os.path.join(INPUTS, 'dump_2026-11-04_bootloader.bin'), os.path.join(INPUTS, 'bootloader.bin')]

# pass-through bootloader at 0x08000400: MSP and reset vector from the firmware's table at 0x08006000
#   0x408 ldr r0,[pc,#8]   0x40A ldr r1,[r0]   0x40C msr msp,r1   0x410 ldr r1,[r0,#4]   0x412 bx r1   0x414 .word
PASS = (struct.pack('<II', 0x20002000, B.BL_BASE + 8 + 1) + bytes.fromhex('0248016881f3088841680847')
        + struct.pack('<I', 0x08006000))


def flash(e, addr, n):
    return bytes(e.m.uc.mem_read(addr, n))


def send_install(link, data):
    link.send(btft.packet(btft.T_START, 0, struct.pack('<IIB', len(data), zlib.crc32(data) & 0xFFFFFFFF, 1)))
    pkts = btft.data_packets(data)
    for p in pkts:
        a = link.send(p, timeout=20.0)
        if a is None or a[1] != 0:
            return a
    return link.send(btft.packet(btft.T_END, len(pkts)), timeout=120.0)


def firmware_running(e):
    """The firmware's main loop runs: the program counter is in the firmware area for most samples."""
    hits = 0
    for _ in range(10):
        e.advance(0.05)
        if 0x08006000 <= e.m.pc < 0x08052000:
            hits += 1
    return hits >= 8


def run(bl_path):
    old = open(bl_path, 'rb').read()
    name = os.path.basename(bl_path)
    image = open(IMAGE, 'rb').read()
    T.Emulator.flash_allow_protected = True

    print('I1 %s with pages 1..3 of the starter' % name)
    mixed = old[:0x100] + STARTER[0x100:0x400] + old[0x400:]
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = U.new_card(), 64
    e = T.make(IMAGE, bootloader=_tmpfile('mixed.bin', mixed))
    e.advance(3.0)
    T.check('the firmware starts through the old bootloader with replaced pages 1..3', firmware_running(e))
    del e

    card = U.new_card()
    T.Emulator.sdcard_path, T.Emulator.sdcard_mb = card, 64
    e = T.make(IMAGE, bootloader=_tmpfile('old.bin', old))
    _open_page(e)
    link = U.Link(e)
    ee0 = bytes(e.m.eeprom)
    data = B.install(STARTER, PASS, 7)

    print('I2 battery 4.5 V')
    e.command({'battery': 4.5})
    e.advance(4.0)
    a = send_install(link, data)
    e.advance(0.3)
    T.check('END status 0x18, "LdE 8"', a is not None and a[1] == 0x18 and T.sub_text(e) == 'LDE 8',
            '%r sub %r' % (a, T.sub_text(e)))
    T.check('nothing written', flash(e, 0x08000000, 0x6000) == old and not any(flash(e, B.SLOT_A, 0x6000))
            and not any(flash(e, B.CTL_BASE, 0x2000)))

    print('I3 battery 6.0 V: install')
    e.command({'battery': 6.0})
    e.advance(4.0)
    a = send_install(link, data)
    T.check('END status 0', a is not None and a[1] == 0, repr(a))
    e.advance(3.0)                                   # 0.5 s quiet, restart, starter install (about 1 s), firmware start
    T.check('starter at 0x08000000', flash(e, 0x08000000, 0x400) == STARTER)
    T.check('bootloader at 0x08000400', flash(e, B.BL_BASE, len(PASS)) == PASS)
    T.check('bootloader mark valid', B.parse_header(flash(e, B.MARK, 20)) == (len(PASS), B.crc32(PASS), 7))
    fw = B.parse_fw_mark(flash(e, B.FW_MARK, 20))
    T.check('firmware mark of the running firmware',
            fw is not None and fw[1] == B.crc32(flash(e, B.APP_BASE, fw[0])) and image[:fw[0]] == flash(e, B.APP_BASE, fw[0]),
            repr(fw))
    recs = []
    area = flash(e, B.CTL_BASE, B.CTL_END - B.CTL_BASE)
    for off in range(0, len(area), 16):
        if not any(area[off:off + 16]):
            break
        recs.append(struct.unpack_from('<III', area, off)[1:])
    T.check('control records INSTALL slot A, then TRIAL slot B',
            recs == [(B.CMD_INSTALL, B.SLOT_A), (B.CMD_TRIAL, B.SLOT_B)], repr(recs))
    T.check('the firmware runs again', firmware_running(e))
    T.check('data EEPROM unchanged (calibration, serial, settings)', bytes(e.m.eeprom) == ee0)
    s = e.snapshot()
    T.check('no safety violation', not s['safety'], repr(s['safety']))

    print('I4 a second install is refused')
    _open_page(e)
    link = U.Link(e)
    before = flash(e, 0x08000000, 0x60000)
    a = send_install(link, data)
    e.advance(0.3)
    T.check('END status 0x17, "LdE 7"', a is not None and a[1] == 0x17 and T.sub_text(e) == 'LDE 7',
            '%r sub %r' % (a, T.sub_text(e)))
    T.check('nothing written', flash(e, 0x08000000, 0x60000) == before)


def _tmpfile(name, data):
    path = os.path.join(T.TMP, 'fi_%d_%s' % (os.getpid(), name))
    open(path, 'wb').write(data)
    return path


def _open_page(e):
    """Bluetooth on and the SETUP page Ld shown."""
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    e.m.uc.mem_write(U.ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('page Ld shown', T.rd(e, U.ADDR_ITEM) == 39 and T.sub_text(e) == 'LD-BT', T.sub_text(e))


def main(argv):
    paths = argv or DEFAULT_BL
    ran = 0
    for p in paths:
        if not os.path.isfile(p):
            print('SKIPPED %s: file not found (EEVblog bootloader images are not in the repository)' % p)
            continue
        run(p)
        ran += 1
    if T.fails:
        print('FAILED: %d checks' % len(T.fails))
        return 1
    print('first install: %d bootloader build(s), all checks passed' % ran if ran else 'nothing ran')
    return 0 if ran else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
