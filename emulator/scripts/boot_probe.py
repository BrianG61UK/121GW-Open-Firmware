"""Milestone-1 probe: load bootloader + v2.05 + option bytes + EEPROM, run, report what is touched.

Usage: boot_probe.py [cycles] [eeprom_image]   (EEPROM image optional, raw bytes from offset 0)
"""
import sys, os, struct, collections
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from emu.core import Machine, FLASH_BASE, EEPROM_BASE, INFO_BASE
from emu.scs import SCS
IN = os.path.join(os.path.dirname(__file__), '..', '..', 'inputs', 'binaries')
m = Machine()
SCS(m)
m.load(FLASH_BASE, open(os.path.join(IN, 'bootloader.bin'), 'rb').read())
m.load(0x08006000, open(os.path.join(IN, 'EEVBlog2_05.bin'), 'rb').read())
if len(sys.argv) > 2:
    m.load(EEPROM_BASE, open(sys.argv[2], 'rb').read())
ob = bytearray(256)
for line in open(os.path.join(IN, 'option.bytes')):
    if line.startswith('0x1ff8'):
        a, rest = line.split(':', 1); off = int(a, 16) - INFO_BASE
        for i, b in enumerate(rest.split()):
            if off + i < 256: ob[off + i] = int(b, 16)
m.load(INFO_BASE, bytes(ob))
m.reset()
r = m.run(int(sys.argv[1]) if len(sys.argv) > 1 else 2_000_000)
print('stop:', r, '| reset:', m.reset_request, '| cycles', m.cycles, '| pc', hex(m.pc))
for c, t in m.log[:60]: print(f'{c:>10} {t}')
print('unmodelled distinct:', len(m.unmodelled))
