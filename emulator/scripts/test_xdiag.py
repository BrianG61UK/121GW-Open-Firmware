"""Induced emulator test of the extended Bluetooth link diagnosis (firmware IMP-44, ble/xdiag.s, ble/commands.s, ble/bft.s).

    python -I emulator/scripts/test_xdiag.py [image]                default firmware/build/EEVBlog.bin

The key frame F4 carries the key codes 0x93 (counting on, counters cleared), 0x94 (counting off) and 0x95 (counters
request, answered with the frame F9: F9, nine u16 little-endian, XOR of the 19 bytes before it = 20 bytes).  The
counters are rx_bytes, err_ore, err_ne, err_fe, rx_dropped_hse, bad_frames, bft_crc_bad, tx_q_full and the battery
voltage; the same nine values are the page Ld STATUS indices 40 .. 48.  Faults are put on the emulated USART2 line with
the model's own rx_feed(fe=True / noise=True) and by keeping the receive interrupt (NVIC IRQ 38) off while two bytes
arrive (overrun, RM0038 27.3.3), as test_ble_overrun.py does.  Bluetooth on (long PEAK), DCV.
  T1 counting off: 0x95 is echoed and nothing else is sent
  T2 0x93 is echoed and nothing else is sent; the counters are 0
  T3 injected faults: 7 bytes of which 3 with a framing error and 2 with noise; two bytes back to back with the
     interrupt off (ORE with RXNE = 1: one byte kept, one lost); the OF-71 case (ORE with RXNE = 0: the byte lost,
     none kept); a key frame with unequal code pairs and a set-clock frame with a wrong XOR (bad frames); 3 bytes
     received while SYSCLK is HSE (NF-04: counted as received and as dropped); the counter saturates at 0xFFFF (not
     wrapping)
  T4 a flood of 0x95 requests faster than the 19200 baud link drains the answers: the transmit queue fills and
     tx_q_full counts (at least once)
  T5 0x95: F9 of 20 bytes, XOR ok, every value as expected (rx_bytes = every byte fed since 0x93, the exact error
     counts, tx_q_full equal to the RAM counter, battery equal to pwr_bat_cv)
  T6 page Ld: STATUS 40 .. 48 equal the F9 values (rx_bytes plus the bytes of the STATUS packets themselves), a packet
     with a wrong CRC is answered with status 1 and bft_crc_bad becomes 1, index 56 is refused (status 3)
  T7 0x94 (sent after leaving the page): echoed; bytes fed afterwards are not counted (STATUS 40 on the page again
     shows the old value plus the 5 bytes of the 0x94 frame), 0x95 is echoed only
The helpers are those of test_backlight_timer.py.
"""
import os
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
import test_backlight_timer as T  # noqa: E402
import test_ble_overrun as O  # noqa: E402
import test_ble_version as V  # noqa: E402
import test_bt_upload as U  # noqa: E402
import btft  # noqa: E402

ADDR_ITEM = 0x20008037
ADDR_BLE_ON = 0x2000802B
NAMES = ['rx_bytes', 'err_ore', 'err_ne', 'err_fe', 'rx_dropped_hse', 'bad_frames', 'bft_crc_bad', 'tx_q_full',
         'battery_cv']


def key_frame(code):
    return b'\xF4' + (b'%02X' % code) * 2


def ask(e, frame, seconds=1.0):
    """Feed `frame`, return the bytes the meter sent meanwhile without the status frames."""
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(frame)
    e.advance(seconds)
    return V.frames_after(e, n0)


def parse_f9(raw):
    """(values, ok): the nine u16 of an F9 frame at the start of `raw` and whether length and XOR are right."""
    if len(raw) != 20 or raw[0] != 0xF9:
        return None, False
    x = 0
    for b in raw[:19]:
        x ^= b
    return [raw[1 + 2 * i] | raw[2 + 2 * i] << 8 for i in range(9)], x == raw[19]


def counters(e, sym):
    return [T.rd(e, sym[n], 2) for n in ('xd_rx_bytes', 'xd_err_ore', 'xd_err_ne', 'xd_err_fe', 'xd_rx_dropped_hse',
                                         'xd_bad_frames', 'xd_bft_crc_bad', 'xd_tx_q_full')]


def run_tests(image):
    map_path = os.path.join(os.path.dirname(image), '121gw.map')
    sym = {n: T.symbol(map_path, n) for n in ('xd_on', 'xd_rx_bytes', 'xd_err_ore', 'xd_err_ne', 'xd_err_fe',
                                             'xd_rx_dropped_hse', 'xd_bad_frames', 'xd_bft_crc_bad', 'xd_tx_q_full',
                                             'pwr_bat_cv')}
    e = T.make(image)
    e.command({'dial': 2})
    e.advance(3.0)
    T.long_press(e, 'PEAK')
    e.advance(1.0)
    T.check('Bluetooth on', T.rd(e, ADDR_BLE_ON) == 1)
    T.check('counting is off after reset (RAM flag 0)', T.rd(e, sym['xd_on']) == 0)

    print('T1 counting off: 0x95 is echoed only')
    got = ask(e, key_frame(0x95))
    T.check('echo only, no F9', got == key_frame(0x95), 'got %r' % got)
    T.check('bytes fed while off are not counted', T.rd(e, sym['xd_rx_bytes'], 2) == 0)

    print('T2 0x93: echoed, counters cleared')
    got = ask(e, key_frame(0x93))
    T.check('echo only', got == key_frame(0x93), 'got %r' % got)
    T.check('counting on, counters 0', T.rd(e, sym['xd_on']) == 1 and counters(e, sym) == [0] * 8, repr(counters(e, sym)))

    print('T3 injected faults')
    rx = 0                                           # bytes fed since 0x93 was processed
    e.usart2.rx_feed(b'\x11\x11\x11')                # a first byte that is neither F4 nor F8 is ignored by the parser
    e.usart2.rx_feed(b'\x11', fe=True)
    e.usart2.rx_feed(b'\x11', fe=True)
    e.usart2.rx_feed(b'\x11', noise=True)
    e.usart2.rx_feed(b'\x11', fe=True, noise=True)
    e.advance(0.3)
    rx += 7
    T.check('7 bytes, 3 framing errors, 2 noise flags',
            counters(e, sym)[:4] == [rx, 0, 2, 3], repr(counters(e, sym)))
    # saturation: 0xFFFE + 3 bytes = 0xFFFF (stays), then the counter is put back
    e.m.uc.mem_write(sym['xd_rx_bytes'], (0xFFFE).to_bytes(2, 'little'))
    e.usart2.rx_feed(b'\x11\x11\x11')
    e.advance(0.2)
    T.check('rx_bytes saturates at 0xFFFF', T.rd(e, sym['xd_rx_bytes'], 2) == 0xFFFF, hex(T.rd(e, sym['xd_rx_bytes'], 2)))
    rx += 3
    e.m.uc.mem_write(sym['xd_rx_bytes'], rx.to_bytes(2, 'little'))
    # overrun with RXNE = 1: the handler is off while two bytes arrive
    O.irq_enable(e, False)
    e.advance(0.05)
    e.usart2.rx_feed(b'\x11\x11')
    e.advance(0.02)
    T.check('overrun state: RXNE = 1, ORE = 1', e.usart2.sr & (O.SR_RXNE | O.SR_ORE) == O.SR_RXNE | O.SR_ORE,
            'SR 0x%04X' % e.usart2.sr)
    O.irq_enable(e, True)
    e.advance(0.2)
    rx += 1                                          # one byte was kept, the second was lost
    T.check('ORE counted once, one byte kept', counters(e, sym)[:2] == [rx, 1], repr(counters(e, sym)))
    # OF-71: ORE with RXNE = 0
    O.irq_enable(e, False)
    e.advance(0.05)
    e.usart2.rx_feed(0x11)
    e.advance(0.02)
    e.usart2.read(0x00, 2)
    e.usart2.rx_feed(0x22)
    e.advance(0.02)
    e.usart2.read(0x04, 2)                           # the test took byte A: the firmware sees RXNE = 0, ORE = 1
    T.check('OF-71 state: RXNE = 0, ORE = 1', e.usart2.sr & (O.SR_RXNE | O.SR_ORE) == O.SR_ORE, 'SR 0x%04X' % e.usart2.sr)
    O.irq_enable(e, True)
    e.advance(0.2)
    T.check('ORE cleared, counted, no byte counted', counters(e, sym)[:2] == [rx, 2] and not e.usart2.sr & O.SR_ORE,
            '%r SR 0x%04X' % (counters(e, sym), e.usart2.sr))
    # bad frames: F4 with unequal code pairs, F8 with a wrong XOR (a correct one would set the clock)
    got = ask(e, b'\xF4' + b'9091')
    rx += 5
    T.check('F4 with unequal pairs: no echo', got == b'', 'got %r' % got)
    v = [26, 11, 5, 12, 30, 45]
    x = 0
    for b in v:
        x ^= b
    f8 = b'\xF8' + ''.join('%02X' % b for b in v + [x ^ 0xFF]).encode()
    got = ask(e, f8)
    rx += 15
    T.check('F8 with a wrong XOR: no echo', got == b'', 'got %r' % got)
    T.check('2 bad frames', counters(e, sym)[5] == 2, repr(counters(e, sym)))

    # bytes received while SYSCLK is not MSI (NF-04, a card session): SW = HSE through the RCC model, as the firmware does
    rcc = e.m.rcc
    cfgr, cr = rcc.read(0x08, 4), rcc.read(0x00, 4)
    rcc.write(0x00, cr | 1 << 16, 4)                 # RCC_CR.HSEON (the port keeps the crystal off outside card sessions)
    e.advance(0.05)
    rcc.write(0x08, (cfgr & ~3) | 2, 4)              # RCC_CFGR.SW = 10b (HSE)
    T.check('SYSCLK is HSE (SWS = 10b)', (rcc.read(0x08, 4) >> 2) & 3 == 2, 'CFGR 0x%08X' % rcc.read(0x08, 4))
    e.usart2.rx_feed(b'\x11\x11\x11')
    e.advance(0.1)
    rcc.write(0x08, cfgr, 4)                         # back to MSI
    rcc.write(0x00, cr, 4)                           # crystal off again
    T.check('SYSCLK is MSI again', (rcc.read(0x08, 4) >> 2) & 3 == 0, 'CFGR 0x%08X' % rcc.read(0x08, 4))
    e.advance(0.1)
    rx += 3
    T.check('3 bytes received on HSE: counted as received and as dropped', counters(e, sym)[0] == rx
            and counters(e, sym)[4] == 3, repr(counters(e, sym)))

    print('T4 transmit queue filled by a flood of 0x95 requests')
    n_flood = 300
    n0 = len(e.ble_rx)
    e.usart2.rx_feed(key_frame(0x95) * n_flood)      # back to back: 5 bytes in, up to 25 bytes (echo + F9) out
    e.advance(0.2 + n_flood * 5 * 10 / 19200.0)      # until the last byte has arrived
    rx += 5 * n_flood
    e.advance(3.0)                                   # the link drains
    sent = bytes(e.ble_rx[n0:])
    print('  %d requests fed, %d F9 frames sent' % (n_flood, sent.count(b'\xF9')))
    T.check('tx_q_full counted at least once', T.rd(e, sym['xd_tx_q_full'], 2) >= 1, repr(counters(e, sym)))

    print('T5 0x95: the frame F9')
    n0 = len(e.ble_rx)
    got = ask(e, key_frame(0x95))
    rx += 5
    T.check('echo then F9 (25 bytes)', len(got) == 25 and got[:5] == key_frame(0x95), 'got %d bytes' % len(got))
    vals, ok = parse_f9(got[5:])
    T.check('F9: 20 bytes, XOR ok', ok, repr(got[5:].hex(' ')))
    ram = counters(e, sym)
    bat = T.rd(e, sym['pwr_bat_cv'], 2)
    print('  F9 ' + ', '.join('%s %d' % (n, v) for n, v in zip(NAMES, vals or [])))
    T.check('rx_bytes = every byte fed since 0x93', vals and vals[0] == rx, 'F9 %r want %d' % (vals, rx))
    T.check('err_ore 2, err_ne 2, err_fe 3, dropped_hse 3, bad_frames 2, bft_crc_bad 0',
            vals and vals[1:7] == [2, 2, 3, 3, 2, 0], repr(vals))
    T.check('tx_q_full equals the RAM counter and is not 0', vals and vals[7] == ram[7] >= 1, '%r RAM %r' % (vals, ram))
    T.check('battery_cv equals pwr_bat_cv (within 0.02 V)', vals and abs(vals[8] - bat) <= 2 and vals[8] > 0,
            'F9 %r RAM %d' % (vals, bat))

    print('T6 page Ld: STATUS 40 .. 48')
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('page Ld shown', T.rd(e, ADDR_ITEM) == 39, 'item %d' % T.rd(e, ADDR_ITEM))
    link = U.Link(e)
    st = []
    for i in range(40, 49):
        a = link.send(btft.status_packet(i), timeout=3.0)
        T.check('STATUS %d answered, status 0' % i, a is not None and a[1] == 0, repr(a))
        st.append(a[2] if a else None)
    print('  STATUS 40..48: ' + ', '.join('%s %s' % (n, v) for n, v in zip(NAMES, st)))
    # each STATUS packet is 9 bytes (B5 5B type seq(2) len payload(1) crc(2)), counted before it is answered
    T.check('STATUS 40 = F9 rx_bytes + 9', st[0] == rx + 9, '%r want %d' % (st[0], rx + 9))
    T.check('STATUS 41 .. 47 = the F9 values', st[1:8] == vals[1:8], '%r vs %r' % (st[1:8], vals[1:8]))
    T.check('STATUS 48 = battery within 0.02 V', st[8] is not None and abs(st[8] - T.rd(e, sym['pwr_bat_cv'], 2)) <= 2,
            repr(st[8]))
    bad = bytearray(btft.status_packet(40))
    bad[-1] ^= 0xFF
    a = link.send(bytes(bad), timeout=3.0)
    T.check('wrong CRC: status 1', a is not None and a[1] == 1, repr(a))
    a = link.send(btft.status_packet(46), timeout=3.0)
    T.check('STATUS 46 (bft_crc_bad) = 1', a is not None and a[1] == 0 and a[2] == 1, repr(a))
    a = link.send(btft.status_packet(56), timeout=3.0)
    T.check('STATUS 56 is refused (status 3; 49 .. 55 are the clock measurement, test_msical.py)',
            a is not None and a[1] == 3, repr(a))
    a = link.send(btft.status_packet(40), timeout=3.0)
    rx_ld = a[2]                                     # includes the packet itself
    T.check('STATUS 40 counts the Ld packets (9 bytes each; 12 packets since the first read: 41 .. 48, the wrong CRC, '
            '46, 56 and this one)', rx_ld == st[0] + 9 * 12, '%r first %r' % (rx_ld, st[0]))

    print('T7 0x94: counting off')
    T.press(e, 'SETUP', gap=0.6)
    T.check('left the page (item 22)', T.rd(e, ADDR_ITEM) == 22, 'item %d' % T.rd(e, ADDR_ITEM))
    got = ask(e, key_frame(0x94))
    T.check('0x94 echoed, nothing else', got == key_frame(0x94), 'got %r' % got)
    T.check('counting off', T.rd(e, sym['xd_on']) == 0)
    e.usart2.rx_feed(b'\x11\x11\x11\x11', fe=True)
    e.advance(0.3)
    got = ask(e, key_frame(0x95))
    T.check('0x95 now echoed only', got == key_frame(0x95), 'got %r' % got)
    e.m.uc.mem_write(ADDR_ITEM, bytes([21]))
    T.press(e, 'SETUP', gap=0.6)
    T.check('page Ld shown again', T.rd(e, ADDR_ITEM) == 39, 'item %d' % T.rd(e, ADDR_ITEM))
    a = link.send(btft.status_packet(40), timeout=3.0)
    T.check('rx_bytes = the value before + the 5 bytes of the 0x94 frame (the 4 bytes, the 0x95 frame and the STATUS '
            'packet are not counted)', a is not None and a[2] == rx_ld + 5, '%r want %d' % (a, rx_ld + 5))
    a = link.send(btft.status_packet(43), timeout=3.0)
    T.check('err_fe unchanged by the 4 framing errors fed while off', a is not None and a[2] == 3, repr(a))

    print('T8 LEAVE (type 0x19): the page Ld is left as with a SETUP press (IMP-47)')
    a = link.send(btft.packet(btft.T_LEAVE, 0), timeout=3.0)
    T.check('LEAVE answered with status 0', a is not None and a[1] == 0, repr(a))
    e.advance(0.5)
    T.check('next page rEL (item 22; no two-part bootloader here)', T.rd(e, ADDR_ITEM) == 22, 'item %d' % T.rd(e, ADDR_ITEM))
    n0 = len(e.ble_rx)
    e.advance(2.0)
    frames_seen = bytes(e.ble_rx[n0:]).count(b'\xF2')
    T.check('status frames again (page Ld no longer owns the link)', frames_seen >= 2, '%d F2 bytes in 2 s' % frames_seen)
    got = ask(e, key_frame(0x90))
    T.check('keys reach the meter again: 0x90 echoed', got[:5] == key_frame(0x90), 'got %r' % got)
    s = e.snapshot()
    T.check('no unmodelled access, no safety violation', s['unmodelled'] == 0 and not s['safety'])


def main(argv):
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    run_tests(image)
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
