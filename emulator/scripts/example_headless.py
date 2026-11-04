"""Headless use of the emulator from Python (emulator/API.md, "Python API"): boot a release build (fetched on demand), apply 1.5 V DC at
the test leads, read the display.  No server, no browser.

    python3 -I emulator/scripts/example_headless.py [2_fast | 1_like_v2.05]

Needs emulator/data (tools/prepare_data.py) or a release package's data folder (EEV121GW_DATA), and the
firmware build from the project's releases (downloaded once, then cached: emu/fetch.py).
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))                  # app.py
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))         # smoke.py: the display decoder
from app import Emulator                                       # noqa: E402
import smoke                                                   # noqa: E402

bits = json.load(open(os.path.join(HERE, '..', 'ui', 'assets', 'lcd_bits.json')))
e = Emulator(firmware=sys.argv[1] if len(sys.argv) > 1 else None)   # direct boot, release build, synthetic EEPROM
e.advance(2.0)                                                       # 2 s of emulated time: boot, splash, first readings
e.command({'input': {'kind': 'V', 'value': 1.5}})                    # 1.5 V DC at the V jack; the dial is at V (DCV)
e.advance(1.0)
s = e.snapshot()
print('display :', smoke.main_reading(smoke.lit_names(s, bits)), 'V')
print('mode    :', s['frontend']['mode_name'], 'range', s['frontend']['range'])
print('time    : %.3f s emulated' % (s['time_ms'] / 1000))
print('machine :', s['machine']['firmware'], s['machine']['boot'], 'boot,', s['machine']['eeprom'], 'EEPROM')
print('unmodelled accesses:', s['unmodelled'], '| safety violations:', len(s['safety']))
