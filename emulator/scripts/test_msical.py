"""Induced emulator test of the MSI measurement and trim (firmware IMP-46, sys/msical.s; OF-72 in ble/usart.s).

    python -I emulator/scripts/test_msical.py [image]                default firmware/build/EEVBlog.bin

At power-on and at every wake from STOP the firmware counts MSI clocks on TIM11 between captures of HSE_RTC (HSE / 16,
every 8th edge: 32 us), trims MSI with MSITRIM one measured step at a time, and gives USART2 (19200 baud to the BLE112)
the measured frequency.  The emulator's MSI is set off nominal with the RCC model settings msi_error_ppm and
msi_trim_ppm (emu/periph/rcc.py: MODEL SETTINGS; the real MSI trim step is not in RM0038 or the data sheet, so the test
uses both signs).  Each case boots its own emulator.  Checks: ck_status, the measured frequency against the model's true
MSI frequency, MSITRIM, the number of measurements, HSE and TIM11 off afterwards, USART2 BRR and the baud on the line
(PCLK1 / BRR) within 0.25 % of 19200 after a successful run.
  C1 nominal MSI: no walk (one 8.192 ms measurement), BRR 218 as before; the frame FA (key code 0x96) and the page Ld
     STATUS 49 .. 55 carry the RAM values; STATUS 56 is refused
  C2 MSI +3 %, a trim code lowers it by 0.2 %: the walk goes up to +15, the clock ends within 0.1 %
  C3 MSI -3 %, a trim code lowers it by 0.2 %: the first step up is worse, the walk turns and goes down to -15
  C4 MSI +7 %: outside +-6 %, nothing changed (status 6, MSITRIM 0, BRR 218 from the nominal value)
  C5 MSI +2.4 %, MSITRIM without effect: no step is better, status 1, ck_hz = the first measurement; PCLK1 4.295 MHz
     is in the OF-72 window: BRR 224 (v2.05's computation gave 208, 7 % too fast)
  C6 wake from STOP (auto power-off) with MSI +1 % and a 0.2 % trim step: measured again; MSITRIM kept over STOP; then
     a wake with HSE that does not start (start-up time beyond the firmware's bound): status 4, MSITRIM unchanged,
     HSE off
RUN LIMIT: 1 run of this script (6 boots).
The helpers are those of test_backlight_timer.py, test_xdiag.py and test_bt_upload.py.
"""
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_ble_version as V  # noqa: E402
import test_bt_upload as U  # noqa: E402
import btft  # noqa: E402
from app import Emulator  # noqa: E402

NOM = 4194304
ADDR_ITEM = 0x20008037
ADDR_BLE_ON = 0x2000802B
ADDR_APO = 0x20000230
ST_OK, ST_NOHSE, ST_RANGE = 1, 4, 6


def key_frame(code):
    return b'\xF4' + (b'%02X' % code) * 2


def boot(image, err_ppm, trim_ppm):
    Emulator.msi_error_ppm, Emulator.msi_trim_ppm = err_ppm, trim_ppm
    try:
        e = T.make(image)
    finally:
        Emulator.msi_error_ppm, Emulator.msi_trim_ppm = 0, 0
    e.command({'dial': 2})
    e.advance(3.0)
    return e


def state(e, sym):
    raw = bytes(e.m.uc.mem_read(sym['ck_hz0'], 12))
    hz0, hz, trim, status, steps = struct.unpack('<IIbBH', raw)
    rcc = e.m.rcc
    return {'hz0': hz0, 'hz': hz, 'trim': trim, 'status': status, 'steps': steps,
            'msitrim': rcc.msitrim - 256 if rcc.msitrim & 0x80 else rcc.msitrim, 'msi_true': rcc.msi_hz,
            'hse_on': rcc._osc['HSE']['on'], 'tim11_clk': rcc.clock_enabled('TIM11')}


def show(tag, s):
    print('  %s: hz0 %d  hz %d  trim %d (MSITRIM %d)  status %d  steps %d  true MSI %d  HSE %s  TIM11 clock %s' % (
        tag, s['hz0'], s['hz'], s['trim'], s['msitrim'], s['status'], s['steps'], s['msi_true'], s['hse_on'],
        s['tim11_clk']), flush=True)


def ppm(a, b):
    return (a - b) * 1e6 / b


def bt_on(e):
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    return T.rd(e, ADDR_BLE_ON) == 1


def baud(e):
    brr = e.usart2.brr
    return brr, (e.m.rcc.pclk1_hz / brr if brr else 0.0)


def common(name, e, s, want_status):
    T.check('%s: status %d' % (name, want_status), s['status'] == want_status, 'status %d' % s['status'])
    T.check('%s: HSE off and TIM11 clock off afterwards' % name, not s['hse_on'] and not s['tim11_clk'])
    T.check('%s: ck_trim = MSITRIM' % name, s['trim'] == s['msitrim'], '%d / %d' % (s['trim'], s['msitrim']))


def check_ok(name, e, s, max_err_ppm):
    common(name, e, s, ST_OK)
    T.check('%s: the measurement equals the true MSI frequency within 40 ppm' % name,
            abs(ppm(s['hz'], s['msi_true'])) <= 40, '%+.1f ppm' % ppm(s['hz'], s['msi_true']))
    T.check('%s: MSI within %d ppm of nominal after the run' % (name, max_err_ppm),
            abs(ppm(s['msi_true'], NOM)) <= max_err_ppm, '%+.0f ppm' % ppm(s['msi_true'], NOM))
    T.check('%s: at most 24 measurements' % name, 1 <= s['steps'] <= 24, '%d' % s['steps'])
    T.check('%s: Bluetooth on' % name, bt_on(e))
    brr, bd = baud(e)
    T.check('%s: baud on the line within 0.25 %% of 19200' % name, abs(bd / 19200 - 1) <= 0.0025,
            'BRR %d (0x%03X) -> %.1f baud (%+.3f %%)' % (brr, brr, bd, (bd / 19200 - 1) * 100))
    return brr


def run_tests(image):
    map_path = os.path.join(os.path.dirname(image), '121gw.map')
    sym = {n: T.symbol(map_path, n) for n in ('ck_hz0', 'ck_status')}

    print('C1 nominal MSI')
    e = boot(image, 0, 2000)
    s = state(e, sym)
    show('C1', s)
    brr = check_ok('C1', e, s, 40)
    T.check('C1: no walk (one measurement), trim 0', s['steps'] == 1 and s['trim'] == 0, repr(s))
    T.check('C1: BRR 218 (as before)', brr == 218, '%d' % brr)
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(key_frame(0x96))
    e.advance(1.0)
    got = V.frames_after(e, n0)
    T.check('C1: 0x96 echoed, then the frame FA (25 bytes)', len(got) == 25 and got[:5] == key_frame(0x96),
            'got %r' % got.hex(' '))
    fa = got[5:]
    x = 0
    for b in fa:
        x ^= b
    T.check('C1: FA 20 bytes, XOR 0', len(fa) == 20 and fa[0] == 0xFA and x == 0, fa.hex(' '))
    if len(fa) == 20:
        hz0, hz, trim, status, steps, fbrr = struct.unpack('<IIbBHH', fa[1:15])
        T.check('C1: FA values = RAM and BRR', (hz0, hz, trim, status, steps, fbrr) ==
                (s['hz0'], s['hz'], s['trim'], s['status'], s['steps'], brr), repr((hz0, hz, trim, status, steps, fbrr)))
        cal = e.m.rcc.msical
        T.check('C1: FA bytes 15, 16 = MSICAL (after the run, now), 17, 18 = 0', fa[15] == fa[16] == cal
                and fa[17:19] == b'\0\0', '%s MSICAL 0x%02X' % (fa[15:19].hex(' '), cal))
        T.check('C1: RTC domain left without a clock source by ck_run, LSI selected by the start-up after it',
                e.m.rcc.rtcsel == 2, 'RTCSEL %d' % e.m.rcc.rtcsel)
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('C1: page Ld shown', T.rd(e, ADDR_ITEM) == 39, 'item %d' % T.rd(e, ADDR_ITEM))
    link = U.Link(e)
    st = []
    for i in range(49, 56):
        a = link.send(btft.status_packet(i), timeout=3.0)
        st.append(a[2] if a and a[1] == 0 else None)
    want = [s['hz0'] & 0xFFFF, s['hz0'] >> 16, s['hz'] & 0xFFFF, s['hz'] >> 16, (s['trim'] & 0xFF) | s['status'] << 8,
            s['steps'], brr]
    T.check('C1: STATUS 49 .. 55 = the RAM values and BRR', st == want, '%r want %r' % (st, want))
    a = link.send(btft.status_packet(56), timeout=3.0)
    T.check('C1: STATUS 56 refused (status 3)', a is not None and a[1] == 3, repr(a))

    print('C2 MSI +3 %, a trim code lowers it by 0.2 %')
    e = boot(image, 30000, -2000)
    s = state(e, sym)
    show('C2', s)
    check_ok('C2', e, s, 1000)
    T.check('C2: trim +15', s['trim'] == 15, '%d' % s['trim'])
    T.check('C2: first measurement = +3 %% within 40 ppm', abs(ppm(s['hz0'], NOM * 1.03)) <= 40, '%d' % s['hz0'])

    print('C3 MSI -3 %, a trim code lowers it by 0.2 %: the walk turns')
    e = boot(image, -30000, -2000)
    s = state(e, sym)
    show('C3', s)
    check_ok('C3', e, s, 1000)
    T.check('C3: trim -15', s['trim'] == -15, '%d' % s['trim'])

    print('C4 MSI +7 %: out of range')
    e = boot(image, 70000, 2000)
    s = state(e, sym)
    show('C4', s)
    common('C4', e, s, ST_RANGE)
    T.check('C4: one measurement, MSITRIM 0', s['steps'] == 1 and s['msitrim'] == 0, repr(s))
    T.check('C4: ck_hz0 = the true frequency within 40 ppm', abs(ppm(s['hz0'], s['msi_true'])) <= 40, '%d' % s['hz0'])
    T.check('C4: Bluetooth on', bt_on(e))
    brr, bd = baud(e)
    T.check('C4: BRR 218 from the nominal value (unchanged behaviour)', brr == 218, '%d' % brr)

    print('C5 MSI +2.4 %, MSITRIM without effect (OF-72 window)')
    e = boot(image, 24000, 0)
    s = state(e, sym)
    show('C5', s)
    brr = check_ok('C5', e, s, 24100)
    T.check('C5: no step kept: trim 0, ck_hz = ck_hz0, 3 measurements', s['trim'] == 0 and s['hz'] == s['hz0']
            and s['steps'] == 3, repr(s))
    T.check('C5: BRR 224 (fraction 16 carried into the mantissa, OF-72)', brr == 224, '%d' % brr)

    print('C6 wake from STOP')
    e = boot(image, 10000, 2000)
    s1 = state(e, sym)
    show('C6 power-on', s1)
    check_ok('C6 power-on', e, s1, 1000)
    e.m.uc.mem_write(ADDR_APO, struct.pack('<H', 3))
    e.advance(9.0)
    T.check('C6: meter in STOP (MSI range 0)', e.m.rcc.msirange == 0, 'MSIRANGE %d' % e.m.rcc.msirange)
    e.command({'dial': 3})
    e.advance(3.0)
    s2 = state(e, sym)
    show('C6 wake', s2)
    common('C6 wake', e, s2, ST_OK)
    T.check('C6 wake: MSITRIM kept over STOP: one measurement, same trim', s2['steps'] == 1 and s2['trim'] == s1['trim'],
            repr(s2))
    T.check('C6 wake: measurement = true MSI within 40 ppm', abs(ppm(s2['hz'], s2['msi_true'])) <= 40, repr(s2))
    e.m.rcc.hse_startup_us = 5_000_000              # the crystal does not start within the firmware's bound
    e.m.uc.mem_write(ADDR_APO, struct.pack('<H', 3))
    e.advance(9.0)
    e.command({'dial': 2})
    e.advance(6.0)
    s3 = state(e, sym)
    show('C6 wake without HSE', s3)
    T.check('C6 no HSE: status 4, nothing measured, MSITRIM unchanged', s3['status'] == ST_NOHSE and s3['steps'] == 0
            and s3['hz'] == 0 and s3['msitrim'] == s2['msitrim'], repr(s3))
    T.check('C6 no HSE: TIM11 clock off', not s3['tim11_clk'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
