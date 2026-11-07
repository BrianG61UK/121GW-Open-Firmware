"""Induced emulator test of the wake from auto power-off (firmware OF-73 in brd/stop.s, IMP-48 in pwr/poweroff.s).

    python -I emulator/scripts/test_apo_wake.py [image]                default firmware/build/EEVBlog.bin

Auto power-off ("-oFF-") puts the MCU into STOP (its supply VDD_P stays on; PE9 switches off only the analog supply U1)
with the keys and the dial lines armed as EXTI wake-up lines.  On a meter (2026-11-07) F-1.17 woke from STOP on a key
(a marker beep sounded) and then hung: TIM2 / TIM3 had been stopped and their clocks gated with an update flag still set
and its interrupt enabled, so after the wake sys_nvic_init enabled IRQ28 / IRQ29, the handler could not clear the flag
(the timer's clock is off) and was entered again for ever.  The emulator re-pends a still-asserted timer interrupt at
the exception return (periph/tim.py _LevelIrq, core.py exc_exit_hooks), as the NVIC does, so it shows the same hang
with F-1.17 (exception 45, TIM3, stays active).  The countdown of the auto power-off (RAM 0x20000230, seconds) is set
to 3 s so the test does not wait 30 minutes.
  W1 Bluetooth on, auto power-off, HOLD: the meter is in STOP (MSI range 0), wakes, no exception stays active, the
     display is on with a reading, Bluetooth is on again (IMP-48) and status frames come
  W2 Bluetooth off, auto power-off, the dial to another position: the meter wakes with Bluetooth still off
RUN LIMIT: 1 run of this script (2 boots).
The helpers are those of test_backlight_timer.py.
"""
import os
import struct
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_backlight_timer as T  # noqa: E402

ADDR_APO = 0x20000230
ADDR_BLE_ON = 0x2000802B


def power_off(e):
    e.m.uc.mem_write(ADDR_APO, struct.pack('<H', 3))
    e.advance(9.0)
    return e.m.rcc.msirange == 0


def awake(e, name):
    T.check('%s: out of STOP (MSI range 6)' % name, e.m.rcc.msirange == 6, 'MSIRANGE %d' % e.m.rcc.msirange)
    T.check('%s: no exception stays active' % name, list(e.m.active) == [], repr(list(e.m.active)))
    s = e.snapshot()
    T.check('%s: display on with a reading' % name, s.get('lcd_on') and T.sub_text(e).strip() != '',
            'lcd_on %r sub %r' % (s.get('lcd_on'), T.sub_text(e)))


def run_tests(image):
    print('W1 Bluetooth on, auto power-off, HOLD')
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    T.check('W1: Bluetooth on', T.rd(e, ADDR_BLE_ON) == 1)
    T.check('W1: auto power-off reached STOP', power_off(e))
    T.check('W1: Bluetooth off while off', T.rd(e, ADDR_BLE_ON) == 0)
    T.press(e, 'HOLD', hold=0.3)
    e.advance(4.0)
    awake(e, 'W1')
    T.check('W1: Bluetooth on again after the wake (IMP-48)', T.rd(e, ADDR_BLE_ON) == 1)
    n0 = len(e.ble_rx)
    e.advance(2.0)
    T.check('W1: status frames after the wake', bytes(e.ble_rx[n0:]).count(b'\xF2') >= 2,
            '%d bytes in 2 s' % (len(e.ble_rx) - n0))

    print('W2 Bluetooth off, auto power-off, dial turn')
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    T.check('W2: Bluetooth off', T.rd(e, ADDR_BLE_ON) == 0)
    T.check('W2: auto power-off reached STOP', power_off(e))
    e.command({'dial': 3})
    e.advance(4.0)
    awake(e, 'W2')
    T.check('W2: Bluetooth still off', T.rd(e, ADDR_BLE_ON) == 0)
    s = e.snapshot()
    T.check('W2: no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'],
            'unmodelled %r safety %r' % (s['unmodelled'], s['safety']))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
