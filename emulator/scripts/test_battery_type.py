"""Induced emulator test of the battery type, the power-on battery display and the low-battery beep (production image,
DESIGN.md 10 IMP-67, FEATURES.md 2.40, GitHub issue 36).

    python -I emulator/scripts/test_battery_type.py [image]      default firmware/build/EEVBlog.bin (production build)

The meter is switched on by the dial (DCV, dial 2) with B+ set first (command 'battery'); "t" is the time after the dial.
The power-on window closes at about t = 2 s; the display of the battery voltage then runs for 10 s of 200 ms readings.
  P1 the page bAt: the meter walk (SETUP short to SEt, long SETUP) goes 1 -> 47 -> 2; the page shows "bAtAL" (EEPROM
     0x023 = 0x00) and, with 0x023 = 1, "bAtnH"; 0x02 and 0xFF read as alkaline and the byte is left as found
  P2 long SETUP starts the edit (set_edit 1), REL switches to "bAtnH", long SETUP saves: the whole-EEPROM diff is exactly
     0x023 = 1; the page is in edit mode no longer
  P3 SETUP short with an unsaved edit leaves the EEPROM as it was and the saved type acts again (set_bat_nimh follows
     set_bat_saved at the next reading)
  P4 an edit that times out (induced: the counter 0x20008070 one tick before its end) re-reads the EEPROM
  D1 alkaline, B+ 4.95 V: at t = 0.8 s the version is on the sub display; at 2.6 s and 3.6 s (the 2 s after the window,
     PWR_BAT_SHOW) the sub display shows "  4.95" (pwr_bat_cv) with the V annunciator and the live display is otherwise
     as usual (item, edit, mode as before); a decimal point cleared by an apply (induced in the LCD shadow) is drawn
     again; at 5.5 s the live page is back and
     V is off; the whole EEPROM is unchanged (D7); no beep (the buzzer output PE7 sampled), no battery symbol
  D3 a dial turn at 2.6 s ends the display; in ACV (EEPROM 0x008 = 2, item 10, a live reading on the sub display) it is
     shown as well (owner 2026-11-10: in every function but the VA modes)
  D4 a key press at 2.6 s (SETUP, HOLD, MIN/MAX, REL, RANGE) ends the display at once; SETUP also walks to the next page
  D5 calibration mode (MODE + REL held at power-on), date-code mode (MODE + SETUP) and the cal.bin menu (MEM + PEAK), with
     B+ 4.0 V: no battery text and no beep
  E1 alkaline, B+ 4.0 V: one call of bzb_func_double after the window and PE7 sounds; the battery symbol is lit at 3 s
     and still at 13.5 s (one beep only); the hard flag 0x200080F9 and the warning flag pwr_bat_warn are equal; "  4.0x"
     is shown
  E2 alkaline, B+ 4.5 V: no beep, no symbol, flags 0; E4 NiMH (EEPROM 0x023 = 1), B+ 4.8 V: nothing
  E3 NiMH, B+ 4.5 V: beep and symbol, 0x200080F9 = 0 and pwr_bat_warn = 1; a save of the page bAt at 4.5 V is accepted
     (EEPROM 0x023 = 0, the symbol goes out); with 0x023 = 1 at B+ 4.0 V the save is refused as every EEPROM write is
  E5 buzzer off (EEPROM 0x01E = 0): the routine is called, PE7 stays low, the symbol is lit; qUiEt (2): PE7 sounds
The helpers are those of test_backlight_timer.py and test_battery_trim.py.
RUN LIMIT: 3 runs of this script (about 22 boots).
"""
import os
import re
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_backlight_timer as T  # noqa: E402
from unicorn import UC_HOOK_CODE  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_EDIT = 0x2000806E
ADDR_EDIT_TIMER = 0x20008070
ADDR_MODE = 0x2000803C
ADDR_HARD = 0x200080F9                               # low battery, < 4.1 V for both types (EEPROM and bootloader gates)
ADDR_SYMBOL = 0x2000803B                             # debounced low-battery symbol state
ADDR_SHADOW = 0x20007790                             # lcd_shadow, word 0: the sub decimal points are bits 21, 23, 25, 27
ADDR_CAL_MODE = 0x2000808A
ADDR_DATE_EDIT = 0x2000808B
EE_BAT, EE_BUZZER, EE_V_MEMORY = 0x023, 0x01E, 0x008
SHOWN = re.compile(r'^  (\d)\.(\d\d)$')              # "  4.95": only the voltage, with the V annunciator (owner 2026-11-10)
SYM = {}


def boot(image, patch=None, vbat=4.95, keys=()):
    """Switch on in DCV with B+ = vbat (and the keys down); the hook counts the calls of bzb_func_double."""
    e = T.make(image, patch)
    e.command({'battery': vbat})
    for k in keys:
        e.command({'key': k, 'down': True})
    e.command({'dial': 2})
    e.t0 = T.now(e)
    e.calls = [0]

    def hook(uc, address, size, user):
        e.calls[0] += 1
    a = SYM['bzb_func_double']
    e.m.uc.hook_add(UC_HOOK_CODE, hook, None, a & ~1, a & ~1)
    return e


def go(e, t):
    """Advance to t seconds after the dial."""
    e.advance(max(0.0, e.t0 + t - T.now(e)))


def ann(e):
    return T.DEC.text(e.snapshot()['lcd'])[2]


def shown(e):
    """The battery value in 0.01 V of the sub display text "  4.95", None when the sub display shows something else."""
    m = SHOWN.match(T.sub_text(e))
    return None if m is None else int(m.group(1)) * 100 + int(m.group(2))


def cv(e):
    return T.rd(e, SYM['pwr_bat_cv'], 2)


def showing(e, tol=2):
    s = shown(e)
    return s is not None and abs(s - cv(e)) <= tol and 'SubV' in ann(e)


def buzzer_samples(e, t_from, t_to):
    """Samples of PE7 every 10 ms between t_from and t_to; returns the number of samples with the buzzer on."""
    go(e, t_from)
    hi = 0
    while T.now(e) - e.t0 < t_to:
        e.advance(0.01)
        hi += e.snapshot()['buzzer'] or 0
    return hi


def clean(e):
    s = e.snapshot()
    return s['unmodelled'] == 0 and not s['safety']


def diff(before, after):
    return {i: (before[i], after[i]) for i in range(len(before)) if before[i] != after[i]}


def state(e):
    return (T.rd(e, ADDR_ITEM), T.rd(e, ADDR_EDIT), T.rd(e, ADDR_MODE))


def pages(image):
    print('P1 the page bAt in the meter walk')
    e = boot(image)
    go(e, 3.0)
    T.check('P1: the meter walk opens at the battery page (item 1)', T.to_meter_walk(e))
    T.press(e, 'SETUP', gap=0.6)
    T.check('P1: 1 -> bAt (item 47), "bAtAL" for EEPROM 0x023 = 0x00',
            T.rd(e, ADDR_ITEM) == 47 and T.sub_text(e) == 'BATAL' and 'SubV' not in ann(e), 'item %d sub %r ann %r' % (
                T.rd(e, ADDR_ITEM), T.sub_text(e), ann(e)))
    T.press(e, 'SETUP', gap=0.6)
    T.check('P1: bAt -> item 2 (APO)', T.rd(e, ADDR_ITEM) == 2, 'item %d' % T.rd(e, ADDR_ITEM))
    e.m.uc.mem_write(ADDR_ITEM, bytes([47]))
    e.advance(0.6)
    print('P2 edit and save')
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.check('P2: long SETUP starts the edit', T.rd(e, ADDR_EDIT) == 1)
    T.press(e, 'REL', gap=0.3)
    texts = T.sample_texts(e)
    T.check('P2: REL: "bAtnH" (set_bat_nimh 1), the page blinks', 'BATnH' in texts and T.rd(e, SYM['set_bat_nimh']) == 1,
            'samples %r nimh %d' % (texts, T.rd(e, SYM['set_bat_nimh'])))
    T.check('P2: nothing is written before the save', bytes(e.m.eeprom) == before)
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    d = diff(before, e.m.eeprom)
    T.check('P2: the save changes exactly EEPROM 0x023 (0 -> 1), edit off, page "bAtnH"',
            d == {EE_BAT: (0, 1)} and T.rd(e, ADDR_EDIT) == 0 and T.sub_text(e) == 'BATnH' and T.rd(e, SYM['set_bat_saved']) == 1,
            'diff %r sub %r' % (d, T.sub_text(e)))
    print('P3 SETUP short leaves an edit unsaved')
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.3)
    T.check('P3: REL in the edit: set_bat_nimh 0', T.rd(e, SYM['set_bat_nimh']) == 0)
    T.press(e, 'SETUP', gap=0.6)
    T.check('P3: edit off, the EEPROM and the saved type kept, set_bat_nimh follows the saved type again',
            T.rd(e, ADDR_EDIT) == 0 and bytes(e.m.eeprom) == before and T.rd(e, SYM['set_bat_nimh']) == 1
            and T.rd(e, SYM['set_bat_saved']) == 1, 'nimh %d saved %d' % (T.rd(e, SYM['set_bat_nimh']), T.rd(e, SYM['set_bat_saved'])))
    print('P4 edit timeout')
    e.m.uc.mem_write(ADDR_ITEM, bytes([47]))
    e.advance(0.6)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.3)
    T.check('P4: an edit started (set_bat_nimh 0)', T.rd(e, ADDR_EDIT) == 1 and T.rd(e, SYM['set_bat_nimh']) == 0)
    e.m.uc.mem_write(ADDR_EDIT_TIMER, bytes([0xF0]))
    e.advance(1.5)
    T.check('P4: timeout: edit off, the type re-read from the EEPROM (1)',
            T.rd(e, ADDR_EDIT) == 0 and T.rd(e, SYM['set_bat_nimh']) == 1 and T.rd(e, SYM['set_bat_saved']) == 1)
    T.check('P2-P4: no unmodelled access, no safety violation', clean(e))
    print('P1 the other stored values')
    for byte, text in ((0x02, 'BATAL'), (0xFF, 'BATAL'), (0x01, 'BATnH')):
        e = boot(image, {EE_BAT: byte})
        go(e, 2.5)
        before = bytes(e.m.eeprom)
        e.m.uc.mem_write(ADDR_ITEM, bytes([47]))
        e.advance(0.6)
        T.check('P1: EEPROM 0x023 = 0x%02X: page "%s", the byte as found' % (byte, text),
                T.sub_text(e) == text and bytes(e.m.eeprom) == before and e.m.eeprom[EE_BAT] == byte,
                'sub %r byte %02X' % (T.sub_text(e), e.m.eeprom[EE_BAT]))


def display(image):
    print('D1 the power-on battery display, alkaline, B+ 4.95 V')
    e = boot(image, vbat=4.95)
    eeprom0 = bytes(e.m.eeprom)
    go(e, 0.8)
    T.check('D1: at 0.8 s the version is on the sub display', '-' in T.sub_text(e) and shown(e) is None, repr(T.sub_text(e)))
    hi = buzzer_samples(e, 1.5, 3.0)
    state0 = state(e)
    T.check('D1: at 3 s "  4.95" and the V annunciator (pwr_bat_cv %d, text %r)' % (cv(e), T.sub_text(e)), showing(e)
            and abs(cv(e) - 495) <= 3, 'ann %r' % (ann(e),))
    T.check('D1: no beep (PE7), no battery symbol, both flags 0, no call of bzb_func_double',
            hi == 0 and 'Battery' not in ann(e) and T.rd(e, ADDR_HARD) == 0 and T.rd(e, SYM['pwr_bat_warn']) == 0
            and e.calls[0] == 0, 'hi %d ann %r calls %d' % (hi, ann(e), e.calls[0]))
    go(e, 3.2)
    T.check('D1: at 3.2 s still shown; item, edit and mode as before (the WHERE data)', showing(e) and state(e) == state0,
            'sub %r state %r was %r' % (T.sub_text(e), state(e), state0))
    # an apply clears the sub decimal points in the shadow: the text must be drawn again with its point
    a = ADDR_SHADOW
    w0 = T.rd(e, a, 4)
    T.check('D2: the decimal point 2 of the sub display is set in the shadow', w0 & 0x0AA00000 == 0x00800000, '%08X' % w0)
    e.m.uc.mem_write(a, (w0 & ~0x00800000).to_bytes(4, 'little'))
    e.advance(0.3)
    T.check('D2: the cleared decimal point is drawn again', showing(e), 'sub %r' % T.sub_text(e))
    go(e, 5.5)
    T.check('D1: at 5.5 s the live page is back, V off, no display state left',
            shown(e) is None and 'SubV' not in ann(e) and T.rd(e, SYM['pwr_bat_mode']) == 0 and state(e) == state0,
            'sub %r ann %r mode %d' % (T.sub_text(e), ann(e), T.rd(e, SYM['pwr_bat_mode'])))
    T.check('D7: the whole EEPROM is unchanged', bytes(e.m.eeprom) == eeprom0)
    T.check('D1: no unmodelled access, no safety violation', clean(e))

    print('D3 dial turn, ACV')
    e = boot(image)
    go(e, 2.6)
    T.check('D3: shown at 2.6 s', showing(e), 'sub %r' % T.sub_text(e))
    e.command({'dial': 3})
    go(e, 3.4)
    T.check('D3: a dial turn ends the display', shown(e) is None and T.rd(e, SYM['pwr_bat_mode']) == 0,
            'sub %r mode %d' % (T.sub_text(e), T.rd(e, SYM['pwr_bat_mode'])))
    e = boot(image, {EE_V_MEMORY: 2})
    go(e, 3.0)
    T.check('D3: ACV (item %d, the page with a live sub display) shows the battery voltage too' % T.rd(e, ADDR_ITEM),
            T.rd(e, ADDR_ITEM) == 10 and T.rd(e, ADDR_MODE) == 2 and showing(e),
            'item %d mode %d sub %r' % (T.rd(e, ADDR_ITEM), T.rd(e, ADDR_MODE), T.sub_text(e)))

    print('D4 a key press ends the display')
    for key in ('SETUP', 'HOLD', 'MINMAX', 'REL', 'RANGE'):
        e = boot(image)
        go(e, 2.6)
        was = showing(e)
        T.press(e, key, gap=0.4)
        ok = shown(e) is None and T.rd(e, SYM['pwr_bat_mode']) == 0 and 'SubV' not in ann(e)
        if key == 'SETUP':
            ok = ok and T.rd(e, ADDR_ITEM) == 22
        T.check('D4: %s at 2.6 s ends the display at once%s' % (key, ' (next page, item 22)' if key == 'SETUP' else ''),
                was and ok, 'was shown %r sub %r item %d' % (was, T.sub_text(e), T.rd(e, ADDR_ITEM)))

    print('D5 calibration mode, date-code mode, the cal.bin menu: no text, no beep (B+ 4.0 V)')
    for name, keys, flag in (('MODE + REL', ('MODE', 'REL'), ADDR_CAL_MODE), ('MODE + SETUP', ('MODE', 'SETUP'), ADDR_DATE_EDIT),
                             ('MEM + PEAK', ('MEM', 'PEAK'), None)):
        e = boot(image, vbat=4.0, keys=keys)
        go(e, 1.2)
        for k in keys:
            e.command({'key': k, 'down': False})
        hi = buzzer_samples(e, 1.3, 4.5)
        T.check('D5: %s: %s, no battery text, no beep' % (name, 'the service state is on' if flag else 'the cal.bin menu'),
                (flag is None or T.rd(e, flag) == 1) and shown(e) is None and T.rd(e, SYM['pwr_bat_mode']) == 0
                and e.calls[0] == 0 and hi == 0, 'sub %r calls %d hi %d' % (T.sub_text(e), e.calls[0], hi))


def low_battery(image):
    print('E1 alkaline, B+ 4.0 V')
    e = boot(image, vbat=4.0)
    hi = buzzer_samples(e, 1.5, 3.0)
    T.check('E1: one call of bzb_func_double, PE7 sounded (%d samples)' % hi, e.calls[0] == 1 and hi >= 5,
            'calls %d hi %d' % (e.calls[0], hi))
    T.check('E1: the symbol is lit, 0x2000803B = 1, hard flag = warning flag = 1',
            'Battery' in ann(e) and T.rd(e, ADDR_SYMBOL) == 1 and T.rd(e, ADDR_HARD) == 1 and T.rd(e, SYM['pwr_bat_warn']) == 1,
            'ann %r' % (ann(e),))
    T.check('E1: "  4.0x" with V is shown (pwr_bat_cv %d)' % cv(e), showing(e) and 395 <= cv(e) <= 405, 'sub %r' % T.sub_text(e))
    go(e, 13.5)
    T.check('E1: at 13.5 s the symbol is still lit and there was one beep only', 'Battery' in ann(e) and e.calls[0] == 1,
            'ann %r calls %d' % (ann(e), e.calls[0]))
    T.check('E1: no unmodelled access, no safety violation', clean(e))

    print('E2 alkaline, B+ 4.5 V')
    e = boot(image, vbat=4.5)
    hi = buzzer_samples(e, 1.5, 3.0)
    T.check('E2: no beep, no symbol, flags 0, "  4.5x" shown', e.calls[0] == 0 and hi == 0 and 'Battery' not in ann(e)
            and T.rd(e, ADDR_HARD) == 0 and T.rd(e, SYM['pwr_bat_warn']) == 0 and showing(e) and 445 <= cv(e) <= 455,
            'calls %d hi %d ann %r cv %d' % (e.calls[0], hi, ann(e), cv(e)))

    print('E3 NiMH, B+ 4.5 V')
    e = boot(image, {EE_BAT: 1}, vbat=4.5)
    hi = buzzer_samples(e, 1.5, 3.0)
    T.check('E3: beep and symbol; hard flag 0 (EEPROM writes allowed), warning flag 1',
            e.calls[0] == 1 and hi >= 5 and 'Battery' in ann(e) and T.rd(e, ADDR_SYMBOL) == 1 and T.rd(e, ADDR_HARD) == 0
            and T.rd(e, SYM['pwr_bat_warn']) == 1, 'calls %d hi %d ann %r hard %d warn %d' % (
                e.calls[0], hi, ann(e), T.rd(e, ADDR_HARD), T.rd(e, SYM['pwr_bat_warn'])))
    T.check('E3: the display shows "  4.5x"', showing(e), 'sub %r' % T.sub_text(e))
    T.to_meter_walk(e)
    T.press(e, 'SETUP', gap=0.6)
    T.check('E3: the page bAt shows "bAtnH"', T.rd(e, ADDR_ITEM) == 47 and T.sub_text(e) == 'BATnH', 'item %d sub %r' % (
        T.rd(e, ADDR_ITEM), T.sub_text(e)))
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.4)
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    d = diff(before, e.m.eeprom)
    T.check('E3: the save at 4.5 V is accepted: EEPROM 0x023 = 0 only', d == {EE_BAT: (1, 0)}, 'diff %r' % (d,))
    e.advance(3.0)
    T.check('E3: alkaline at 4.5 V: warning flag 0 and the symbol goes out (debounce)',
            T.rd(e, SYM['pwr_bat_warn']) == 0 and T.rd(e, ADDR_SYMBOL) == 0 and 'Battery' not in ann(e),
            'warn %d symbol %d ann %r' % (T.rd(e, SYM['pwr_bat_warn']), T.rd(e, ADDR_SYMBOL), ann(e)))
    e = boot(image, {EE_BAT: 1}, vbat=4.0)
    go(e, 3.0)
    e.m.uc.mem_write(ADDR_ITEM, bytes([47]))
    e.advance(0.6)
    before = bytes(e.m.eeprom)
    T.long_press(e, 'SETUP')
    T.press(e, 'REL', gap=0.4)
    T.long_press(e, 'SETUP')
    e.advance(1.0)
    T.check('E3: at 4.0 V (hard flag %d) the save is refused as every EEPROM write: nothing changed' % T.rd(e, ADDR_HARD),
            T.rd(e, ADDR_HARD) == 1 and bytes(e.m.eeprom) == before, 'diff %r' % (diff(before, e.m.eeprom),))

    print('E4 NiMH, B+ 4.8 V')
    e = boot(image, {EE_BAT: 1}, vbat=4.8)
    hi = buzzer_samples(e, 1.5, 3.0)
    T.check('E4: no beep, no symbol, warning flag 0', e.calls[0] == 0 and hi == 0 and 'Battery' not in ann(e)
            and T.rd(e, SYM['pwr_bat_warn']) == 0, 'calls %d hi %d ann %r cv %d' % (e.calls[0], hi, ann(e), cv(e)))

    print('E5 the buzzer setting')
    for setting, name in ((0, 'buzzer off'), (2, 'qUiEt')):
        e = boot(image, {EE_BUZZER: setting}, vbat=4.0)
        hi = buzzer_samples(e, 1.5, 3.0)
        want = hi == 0 if setting == 0 else hi >= 5
        T.check('E5: %s: the routine is called once, PE7 %s, the symbol is lit' % (name, 'stays low' if setting == 0 else 'sounds'),
                e.calls[0] == 1 and want and 'Battery' in ann(e), 'calls %d hi %d ann %r' % (e.calls[0], hi, ann(e)))
        T.check('E5: %s: no unmodelled access, no safety violation' % name, clean(e))


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    mp = os.path.join(os.path.dirname(os.path.abspath(image)), '121gw.map')
    for name in ('bzb_func_double', 'pwr_bat_cv', 'pwr_bat_warn', 'pwr_bat_mode', 'set_bat_nimh', 'set_bat_saved'):
        SYM[name] = T.symbol(mp, name)
    T.Emulator.sdcard_path = None
    display(image)
    low_battery(image)
    pages(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
