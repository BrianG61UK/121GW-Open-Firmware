"""Diagnosis values of the file transfer (STATUS requests, type 5, ble/bft.s bft_diag_tab) and their readable text.

The meter answers a STATUS request with index 0..20 with one value in the "next" field of the answer, in any state of
the page Ld (ble/bft.s .Lpk_status).  The values (bft.s comment above bft_diag_tab): 0 failed card sessions of the
transfer, 1 last card failure (step << 8 | FatFs result), 2 failed disk_read / disk_write calls since power-on, 3 their op
(low byte) and reason (high byte), 4 SDIO_STA, 5 sd_transfer_error, 6 sd_wait_write result, 7 end flags (transfer end << 1
| DMA end), 8 DMA2 channel 4 flags, 9 CNDTR, 10 SDIO_DCOUNT, 11 SDIO_STA high half, 12 reads taken on the hardware
counters, 13 / 14 low / high half of the card status of the last CMD13 answer before the failure, 15 10 ms ticks of the
failed status polling, 16 failed card start-ups since power-on, 17 the sd_init error code of the last one, 18 SCR reads
since power-on, 19 / 20 of these the reads whose polling loop had read no word / one word when the block end was seen.

explain() is a copy of explain_diag / card_diag of the firmware repository's emulator/tools/btft.py (this program does
not depend on that repository).
"""
COUNT = 21                                         # bft.s BFT_DIAG_N
CARD_STEP = {1: 'open', 2: 'seek', 3: 'write', 4: 'short write (card full?)', 5: 'close', 6: 'read back'}


def card_diag(v):
    """Value 1: failed step << 8 | FatFs result of that step."""
    return 'step %s, FatFs result %d' % (CARD_STEP.get(v >> 8, v >> 8), v & 0xFF)


def explain(values):
    """Readable text for the STATUS values (0..6 at least; 7..20 add detail when present)."""
    op, reason = values[3] & 0xFF, values[3] >> 8
    why = {(1, 1): 'read: card did not return to the transfer state', (1, 2): 'read: SDIO error flag',
           (1, 3): 'read: data end / DMA end not seen in time', (2, 1): 'write: card did not return to the transfer state',
           (2, 2): 'write: the end-of-write wait ran out of polls (or CMD12 failed)', (2, 3): 'write: SDIO error code'}
    sta = values[4]
    flags = [n for b, n in ((1, 'DCRCFAIL'), (3, 'DTIMEOUT'), (4, 'TXUNDERR'), (5, 'RXOVERR'), (9, 'STBITERR')) if sta >> b & 1]
    text = ('%d failed card sessions in this transfer, last card failure %s; driver: %d failed calls since power-on, last %s,'
            ' SDIO_STA 0x%04X %s, transfer error %d, wait result %d'
            % (values[0], card_diag(values[1]), values[2], why.get((op, reason), 'op %d reason %d' % (op, reason)), sta,
               flags, values[5], values[6]))
    if len(values) >= 13:
        f = values[7]
        text += ('; at the last end-wait timeout: data end flag %d, DMA end flag %d, DMA ch4 flags 0x%X, DMA words left %d,'
                 ' SDIO bytes left %d, SDIO_STA high 0x%04X; %d reads taken on the hardware counters'
                 % (f >> 1 & 1, f & 1, values[8], values[9], values[10], values[11], values[12]))
    if len(values) >= 16:
        r1 = values[13] | values[14] << 16
        states = ('idle', 'ready', 'ident', 'stby', 'tran', 'data', 'rcv', 'prg', 'dis')
        if r1 == 0xFFFFFFFF:
            card = 'no CMD13 answer'
        else:
            st = r1 >> 9 & 0xF
            errs = [n for b, n in ((31, 'OUT_OF_RANGE'), (30, 'ADDRESS_ERROR'), (29, 'BLOCK_LEN_ERROR'),
                                   (28, 'ERASE_SEQ_ERROR'), (27, 'ERASE_PARAM'), (26, 'WP_VIOLATION'), (23, 'COM_CRC_ERROR'),
                                   (22, 'ILLEGAL_COMMAND'), (21, 'CARD_ECC_FAILED'), (20, 'CC_ERROR'), (19, 'ERROR'),
                                   (8, 'READY_FOR_DATA')) if r1 >> b & 1]
            card = 'card status 0x%08X: state %s %s' % (r1, states[st] if st < len(states) else st, errs)
        text += '; last CMD13 before the failure: %s; the polling lasted %d ticks of 10 ms' % (card, values[15])
    if len(values) >= 18:
        text += '; %d failed card start-ups since power-on, last sd_init error %d' % (values[16], values[17])
    if len(values) >= 21:
        text += ('; %d SCR reads since power-on, %d of them with no word and %d with one word read before the block end'
                 % (values[18], values[19], values[20]))
    return text
