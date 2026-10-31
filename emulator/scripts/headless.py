"""Run the emulator without UI for N emulated seconds and print log, unmodelled accesses and LCD RAM.

Usage: headless.py [seconds] [eeprom_image] [sdcard_image]   (EEPROM image optional, raw bytes from offset 0;
       sdcard_image optional: raw SD card image, created and formatted FAT32 (512 MiB) when the file does not exist)
"""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from app import Emulator
IN = os.path.join(os.path.dirname(__file__), '..', '..', 'inputs', 'binaries')
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
if len(sys.argv) > 3:
    Emulator.sdcard_path = sys.argv[3]
e = Emulator(IN, eeprom=sys.argv[2] if len(sys.argv) > 2 else None)
t0 = time.time(); done = 0.0
while done < secs:
    r = e.m.run(int(e.m.sysclk_hz * 0.01)); done += 0.01
    if r or e.m.reset_request: break
print(f'stop={r} reset={e.m.reset_request} emulated~{done:.2f}s wall {time.time()-t0:.1f}s pc=0x{e.m.pc:08X} clk={e.m.sysclk_hz}')
for c, t in e.m.log[-25:]: print(f'  {c/e.m.sysclk_hz*1000:9.2f}ms {t}')
print('unmodelled:', len(e.m.unmodelled))
for (a, rw), (pc, n) in sorted(e.m.unmodelled.items())[:40]: print(f'  {rw} 0x{a:08X} first pc 0x{pc:08X} x{n}')
print('LCD enabled', e.lcd.enabled, 'display', [hex(x) for x in e.lcd.display[:8]])
