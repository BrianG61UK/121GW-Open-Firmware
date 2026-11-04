"""Time for the meter's clock: an NTP query (SNTP, RFC 4330) and the meter's set-clock frame.

The meter's clock chip keeps local time without a time zone, so the frame carries the computer's local time at the
moment of sending, taken from the NTP answer (corrected by half the round trip) and the computer's time-zone rules.

Set-clock frame (analysis/ble_packet.md 6; the firmware's ble/commands.s fn_0800C332): F8 followed by seven pairs of
ASCII hex digits v0..v6, v0..v5 = year 0..99, month 1..12, day 1..31, hour 0..23, minute 0..59, second 0..59 as plain
numbers (the firmware converts them to BCD for the chip, rtc/nju6350.s rtc_write_reg), v6 = XOR of v0..v5.  The meter
echoes a valid frame; the fast firmware from F-1.02 applies every valid frame (IMP-31), v2.05 only the first one after
Bluetooth was switched on.
"""
import socket
import struct
import time

DEFAULT_SERVER = 'pool.ntp.org'
NTP_EPOCH = 2208988800                   # seconds from 1900-01-01 to 1970-01-01


class ClockError(Exception):
    pass


def ntp_time(server=DEFAULT_SERVER, timeout=3.0):
    """(unix time now from the server, offset = server - local clock in s, round trip in s)."""
    try:
        infos = socket.getaddrinfo(server, 123, type=socket.SOCK_DGRAM)
    except OSError as e:
        raise ClockError('NTP server %s: %s' % (server, e)) from e
    family, _, _, _, addr = infos[0]
    req = bytearray(48)
    req[0] = (0 << 6) | (4 << 3) | 3                   # leap 0, version 4, mode 3 (client)
    with socket.socket(family, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        t1 = time.time()
        struct.pack_into('!II', req, 40, int(t1) + NTP_EPOCH, int((t1 % 1) * 2 ** 32))   # transmit timestamp
        try:
            s.sendto(bytes(req), addr)
            data, _ = s.recvfrom(512)
        except OSError as e:
            raise ClockError('NTP server %s does not answer: %s' % (server, e)) from e
        t4 = time.time()
    if len(data) < 48:
        raise ClockError('NTP server %s: short answer' % server)
    mode, stratum = data[0] & 7, data[1]
    if mode != 4 or stratum == 0 or stratum > 15:
        raise ClockError('NTP server %s: not a usable answer (mode %d, stratum %d)' % (server, mode, stratum))
    ts = lambda o: struct.unpack_from('!I', data, o)[0] - NTP_EPOCH + struct.unpack_from('!I', data, o + 4)[0] / 2 ** 32
    t2, t3 = ts(32), ts(40)                            # server receive and transmit times
    offset = ((t2 - t1) + (t3 - t4)) / 2
    delay = (t4 - t1) - (t3 - t2)
    return time.time() + offset, offset, delay


def clock_frame(unix_time):
    """The set-clock frame for the local time of `unix_time`."""
    t = time.localtime(unix_time)
    v = [t.tm_year % 100, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec]
    x = 0
    for b in v:
        x ^= b
    return b'\xF8' + ''.join('%02X' % b for b in v + [x]).encode('ascii')
