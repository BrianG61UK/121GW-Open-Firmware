"""Send a firmware file to a 121GW over Bluetooth LE; the meter stores it on its SD card as EEVBlog.bin (IMP-28).

    python bt_upload.py EEVBlog.bin            needs the Python package bleak (pip install bleak)

On the meter: Bluetooth on (long PEAK), then SETUP until the page "Ld-bt" (after the page bt).  The meter shows the
percent received ("Ld nn"), then "Ld oK" when EEVBlog.bin is written and read back correctly, or "LdE n" on an error.
Then switch the meter off and start the usual update: hold HOLD and MEM while switching on, then press SETUP.
The file is checked here first (size, initial stack pointer, reset vector), and again by the meter, which writes it to
a temporary file and replaces EEVBlog.bin only after length and CRC-32 match.
"""
import asyncio
import os
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import btft  # noqa: E402

SERVICE = '0bd51666-e7cb-469b-8e4d-2742f1ba77cc'
CHAR = 'e7add780-b042-4876-aae1-112855353cc1'
TIMEOUT_DATA = 20.0           # a card write of 16 KiB can take a second; generous
TIMEOUT_END = 120.0           # check, copy and read back of the whole file
RETRIES = 8


async def main(path):
    from bleak import BleakClient, BleakScanner
    data = open(path, 'rb').read()
    bad = btft.check_image(data)
    if bad:
        raise SystemExit('%s: refused: %s' % (path, bad))
    print('file %s: %d bytes' % (path, len(data)))
    devs = await BleakScanner.discover(timeout=8.0, return_adv=True)
    dev = next((d for d, adv in devs.values() if SERVICE in [str(u).lower() for u in adv.service_uuids]), None)
    if dev is None:
        raise SystemExit('no 121GW found: meter on, Bluetooth on (long PEAK), phone app closed?')
    parser, answers = btft.AnswerParser(), asyncio.Queue()

    def on_notify(_h, chunk):
        for a in parser.feed(chunk):
            answers.put_nowait(a)

    async with BleakClient(dev) as c:
        await c.start_notify(CHAR, on_notify)

        async def send(pkt, seq, timeout):
            for attempt in range(RETRIES):
                while not answers.empty():
                    answers.get_nowait()
                await c.write_gatt_char(CHAR, pkt, response=True)
                end = time.monotonic() + timeout
                while time.monotonic() < end:
                    try:
                        a_seq, status, nxt = await asyncio.wait_for(answers.get(), end - time.monotonic())
                    except asyncio.TimeoutError:
                        break
                    if status == 1:
                        break                       # CRC wrong (its seq field may be damaged too): send again
                    if a_seq != seq:
                        continue
                    return status, nxt
            raise SystemExit('no answer to packet %d after %d attempts (page "Ld-bt" shown on the meter?)' % (seq, RETRIES))

        status, _ = await send(btft.start_packet(data), 0, TIMEOUT_DATA)
        if status:
            raise SystemExit('START: %s' % btft.STATUS_TEXT.get(status, status))
        pkts = btft.data_packets(data)
        t0 = time.monotonic()
        n = 0
        while n < len(pkts):
            status, nxt = await send(pkts[n], n, TIMEOUT_DATA)
            if status == 2:
                n = nxt                             # the meter names the packet it expects
                continue
            if status == 0x11:
                raise SystemExit('packet %d: %s (%s)' % (n, btft.STATUS_TEXT[status], btft.card_diag(nxt)))
            if status:
                raise SystemExit('packet %d: %s' % (n, btft.STATUS_TEXT.get(status, status)))
            n += 1
            done = min(len(data), n * btft.MAX_PAYLOAD)
            rate = done / max(time.monotonic() - t0, 1e-6)
            print('\r%6d / %d bytes  %5.0f B/s' % (done, len(data), rate), end='', flush=True)
        print()
        print('checking and writing EEVBlog.bin on the card ...')
        status, info = await send(btft.packet(btft.T_END, len(pkts)), len(pkts), TIMEOUT_END)
        vals = []
        for i in range(26):
            st, v = await send(btft.status_packet(i), 0, TIMEOUT_DATA)
            vals.append(v if st == 0 else 0)
        print('diagnosis: ' + btft.explain_diag(vals))
        if status in (0x14, 0x15):
            raise SystemExit('END: %s.  EEVBlog.bin on the card may be incomplete: do NOT start the update; send the file'
                             ' again or copy it with a computer.' % btft.STATUS_TEXT[status])
        if status in (0x11, 0x16) or (status and info):
            raise SystemExit('END: %s (last card failure: %s)' % (btft.STATUS_TEXT.get(status, status), btft.card_diag(info)))
        if status:
            raise SystemExit('END: %s' % btft.STATUS_TEXT.get(status, status))
        if info:
            print('note: %d card write session(s) failed and were repeated successfully' % info)
        print('done in %.0f s: EEVBlog.bin is on the card and verified.  Switch the meter off, hold HOLD and MEM while'
              ' switching it on, then press SETUP.' % (time.monotonic() - t0))


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    asyncio.run(main(sys.argv[1]))
