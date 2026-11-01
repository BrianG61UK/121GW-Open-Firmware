#!/usr/bin/env python3
"""smoke.py - start-up check of a running emulator: it boots to a reading and models every access it makes.

    python3 -I emulator/tools/smoke.py [--url http://127.0.0.1:8121] [--timeout 90] [--volts 1.5] [--expect-direct]
                                       [--expect-synthetic]

The emulator is started by the caller (python emulator/app.py ..., or the packaged application) and must be listening on
--url.  The tool then
  1. waits for GET /state to answer,
  2. applies a DC voltage stimulus (POST /input {"input": {"kind": "V", "value": VOLTS}}), the meter being at its V dial
     position in DCV,
  3. waits until the main display shows a number (the five digits of the glass, emulator/ui/assets/lcd_bits.json) within
     0.002 V of VOLTS, which proves that the firmware has booted, configured the HY3131, taken conversions and applied its
     calibration to the front end's signal,
and fails (exit status 1) if the reading does not appear in time, if the emulator reports unmodelled peripheral accesses
(GET /state "unmodelled" is not 0), a stop reason, or a hardware-safety violation.  --expect-direct / --expect-synthetic
additionally check GET /state "machine": boot mode direct and EEPROM synthetic.  Standard library only.
"""
import json
import sys
import time
import urllib.request

sys.dont_write_bytecode = True
SEGMENTS = {  # 7-segment patterns a..g -> character
    'abcdef': '0', 'bc': '1', 'abdeg': '2', 'abcdg': '3', 'bcfg': '4', 'acdfg': '5', 'acdefg': '6', 'abc': '7',
    'abcdefg': '8', 'abcdfg': '9', '': ' ', 'g': '-', 'def': 'L', 'adef': 'C', 'aefg': 'F', 'abefg': 'P',
    'cdefg': 'b', 'defg': 't', 'cdeg': 'o', 'bcdefg': 'U', 'abcefg': 'A', 'adefg': 'E', 'cefg': 'h', 'ceg': 'n',
}


def get(url, path):
    with urllib.request.urlopen(url + path, timeout=10) as r:
        return json.load(r)


def post(url, body):
    req = urllib.request.Request(url + '/input', data=json.dumps(body).encode(), method='POST')
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def lit_names(state, bits):
    names = set()
    for w in range(8):
        for b in range(32):
            if state['lcd'][w] >> b & 1:
                names.update(bits.get('w%db%d' % (w, b), ()))
    return names


def main_reading(names):
    """The main display as text ('1.5000'), or None when a digit is not a known pattern."""
    out = ''
    for d in range(1, 6):
        segs = ''.join(c for c in 'abcdefg' if 'seg%d%s' % (d, c) in names)
        ch = SEGMENTS.get(segs)
        if ch is None:
            return None
        out += ch + ('.' if 'seg%ddp' % d in names else '')
    return out.strip()


def main(argv):
    opt = lambda k, d: argv[argv.index(k) + 1] if k in argv else d
    url = opt('--url', 'http://127.0.0.1:8121').rstrip('/')
    timeout = float(opt('--timeout', '90'))
    volts = float(opt('--volts', '1.5'))
    t0 = time.time()
    while True:
        try:
            state = get(url, '/state')
            break
        except OSError:
            if time.time() - t0 > timeout:
                print('smoke: FAIL no answer from %s/state within %gs' % (url, timeout))
                return 1
            time.sleep(0.5)
    bits = get(url, '/assets/lcd_bits.json')
    mach = state.get('machine', {})
    print('smoke: %s answers; machine %s' % (url, json.dumps(mach)))
    post(url, {'input': {'kind': 'V', 'value': volts}})
    shown = None
    while time.time() - t0 < timeout:
        state = get(url, '/state')
        shown = main_reading(lit_names(state, bits)) if state['lcd_on'] else None
        try:
            if shown is not None and abs(float(shown.replace(' ', '')) - volts) <= 0.002:
                break
        except ValueError:
            pass
        time.sleep(0.5)
    else:
        print('smoke: FAIL no reading of %g V within %gs (last display %r, firmware mode %s)'
              % (volts, timeout, shown, state.get('frontend', {}).get('mode_name')))
        return 1
    problems = []
    if state['unmodelled'] != 0:
        problems.append('%d unmodelled peripheral accesses' % state['unmodelled'])
    if state['stop']:
        problems.append('emulation stopped: %s' % state['stop'])
    if state['safety']:
        problems.append('hardware-safety violations: %s' % state['safety'])
    if '--expect-direct' in argv and mach.get('boot') != 'direct':
        problems.append('boot mode is %r, expected direct' % mach.get('boot'))
    if '--expect-synthetic' in argv and mach.get('eeprom') != 'synthetic':
        problems.append('EEPROM is %r, expected synthetic' % mach.get('eeprom'))
    print('smoke: display %s V after %.1f s wall, emulated %.3f s, mode %s range %s, unmodelled %d'
          % (shown, time.time() - t0, state['time_ms'] / 1000, state['frontend']['mode_name'], state['frontend']['range'],
             state['unmodelled']))
    for p in problems:
        print('smoke: FAIL ' + p)
    if not problems:
        print('smoke: PASS')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
