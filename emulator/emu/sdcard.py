"""SD memory card model: High Capacity SD Memory Card (SDHC), SD mode, backed by a raw image file on the host.

Sources (cited as "PLS 2.00 n.n" = SD Group Physical Layer Simplified Specification Version 2.00, 25 Sep 2006, chapter n.n;
"RM0038 n.n" = STM32L152 reference manual):
    state machine and command table         PLS 2.00 4.2, 4.3, 4.7.4, 4.8 (table 4-28)
    responses R1, R1b, R2, R3, R6, R7       PLS 2.00 4.9
    card status                             PLS 2.00 4.10.1 (table 4-35)
    SD status                               PLS 2.00 4.10.2 (table 4-37)
    OCR, CID, CSD version 2.0, SCR          PLS 2.00 5.1, 5.2, 5.3.3, 5.6
    CRC7 / CRC16                            PLS 2.00 4.5 (the spec's own test vectors are asserted in crc7() / crc16() callers)
    SDHC command differences                PLS 2.00 4.3.14
    error handling, timeouts                PLS 2.00 4.6

What the model is.  The class is the protocol and storage side only.  It has no clock: the SDIO host model (periph/sdio.py)
drives it at the instants the 48-bit command token has been received, at the instants data blocks have been transferred, and
supplies the time conversion.  Where the specification gives a time, the card reports it in microseconds (times set by the card
itself, PLS 2.00 4.6.2, 5.3.3) or in bus clocks (times set by the bus protocol).

Commands implemented (everything else is an illegal command, PLS 2.00 4.6.1: no response, state unchanged, ILLEGAL_COMMAND
set in the card status that the next response carries):
    CMD0 2 3 4 7 8 9 10 12 13 15 16 17 18 24 25 32 33 38 55      ACMD6 13 22 23 41 42 51
CMD1 (MMC), CMD5 (SDIO), CMD6 (class 10), CMD27, CMD28-30 (write protection, not supported by SDHC, PLS 2.00 4.3.14),
CMD42 (lock/unlock, class 7) and CMD56 are not supported.  The CCC field of the CSD advertises exactly the classes that are
implemented: 0, 2, 4, 5 and 8 (PLS 2.00 5.3.2 CCC).  A real card is required to implement more: PLS 2.00 4.7.3 lists classes 0, 2,
4, 5, 7 and 8 for every card and 4.3.10 makes CMD6 mandatory from version 1.10; the model leaves them out because the firmware
uses none of them (a host that sends CMD6 or CMD42 gets no response).  Whether that matters to another host is unproven.

Unproven model parameters (the simplified specification leaves them to the full specification or to the card vendor):
    ncr_clocks          delay between the end bit of a command and the start bit of the response (PLS 2.00 gives none);
    read latency of the register reads ACMD13 / ACMD22 / ACMD51: the model applies the card's declared read access time
                        (TAAC, 1 ms) to them as to CMD17 / CMD18, measured from the end of the response; PLS 2.00 gives no
                        separate value.  This matters for the firmware: its polled SCR read (FUN_08023A8C) exits as soon as
                        DBCKEND is set without draining the FIFO, so it only works when the polling loop is already running
                        while the 8-byte block is on the bus (82 SDIO_CK clocks);
    token_gap_clocks    delay between the end bit of a written block and the CRC status token;
    init_us             duration of the card's internal initialisation after the first ACMD41 (PLS 2.00 4.2.2: at most 1 s);
    erase_busy_us       busy time of CMD38.
Times that the card itself declares are derived from its own CSD: read access time TAAC = 1 ms (PLS 2.00 5.3.3 "fixed to 0Eh,
which indicates 1 ms") and block programming time = TAAC * 4 (R2W_FACTOR = 2, "4 multiples").
"""
import os
import struct

# ---------------------------------------------------------------- CRC (PLS 2.00 4.5)


def crc7(value, nbits):
    """CRC7, generator x^7 + x^3 + 1, over the nbits most significant bits first of `value` (PLS 2.00 4.5).
    Spec examples: CMD0 arg 0 -> 0b1001010; CMD17 arg 0 -> 0b0101010; R1 of CMD17 status 0x900 -> 0b0110011."""
    crc = 0
    for i in range(nbits - 1, -1, -1):
        fb = ((crc >> 6) ^ (value >> i)) & 1
        crc = (crc << 1) & 0x7F
        if fb:
            crc ^= 0x09
    return crc


def crc16(data, crc=0):
    """CRC16, generator x^16 + x^12 + x^5 + 1 (CCITT), over the bytes, each most significant bit first (PLS 2.00 4.5).
    Spec example: 512 bytes of 0xFF -> 0x7FA1."""
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


# ---------------------------------------------------------------- frames
def cmd_frame(index, arg):
    """48-bit command token (PLS 2.00 table 4-15 / SDIO 29.3.1 table 164): 0, 1, index, argument, CRC7, 1."""
    body = (1 << 46) | ((index & 0x3F) << 40) | ((arg & 0xFFFFFFFF) << 8)
    return body | (crc7(body >> 8, 40) << 1) | 1


def short_frame(index, arg):
    """48-bit response token (R1, R1b, R6, R7): 0, 0, index, argument, CRC7, 1 (PLS 2.00 tables 4-29, 4-32, 4-33)."""
    body = ((index & 0x3F) << 40) | ((arg & 0xFFFFFFFF) << 8)
    return body | (crc7(body >> 8, 40) << 1) | 1


def r3_frame(ocr):
    """R3 (PLS 2.00 table 4-31): 0, 0, 111111, OCR, 1111111, 1.  No CRC: the CRC field is all ones."""
    return (0x3F << 40) | ((ocr & 0xFFFFFFFF) << 8) | (0x7F << 1) | 1


def r2_frame(reg128):
    """R2 (PLS 2.00 table 4-30): 0, 0, 111111, register bits [127:1] (CID / CSD with their own CRC7), end bit 1."""
    return (0x3F << 128) | (((reg128 >> 1) & ((1 << 127) - 1)) << 1) | 1


# ---------------------------------------------------------------- registers
def _pack(fields, width):
    """fields: (high bit, low bit, value) tuples -> integer of `width` bits."""
    v = 0
    for hi, lo, val in fields:
        n = hi - lo + 1
        assert 0 <= val < (1 << n), (hi, lo, val)
        v |= val << lo
    assert v < (1 << width)
    return v


def make_cid(mid=0x00, oid=b"EV", pnm=b"SDEMU", prv=0x10, psn=0x121B0001, year=2026, month=10):
    """CID (PLS 2.00 5.2 table 5-2).  MID 0x00 is not allocated to any manufacturer.  MDT: year code = year - 2000 in
    [19:12], month in [11:8]."""
    mdt = ((year - 2000) << 4) | month
    reg = _pack([(127, 120, mid), (119, 104, int.from_bytes(oid, "big")), (103, 64, int.from_bytes(pnm, "big")),
                 (63, 56, prv), (55, 24, psn), (19, 8, mdt)], 128)
    return reg | (crc7(reg >> 8, 120) << 1) | 1


def make_csd_v2(c_size):
    """CSD version 2.0 (PLS 2.00 5.3.3 table 5-16).  C_SIZE gives (C_SIZE + 1) * 512 KB.
    CCC = classes 0, 2, 4, 5, 8 (0x135): the classes the model implements."""
    reg = _pack([
        (127, 126, 1),          # CSD_STRUCTURE 01b
        (119, 112, 0x0E),       # TAAC = 1 ms
        (111, 104, 0x00),       # NSAC
        (103, 96, 0x32),        # TRAN_SPEED 25 MHz
        (95, 84, 0x135),        # CCC
        (83, 80, 9),            # READ_BL_LEN 512 B
        (79, 79, 0), (78, 78, 0), (77, 77, 0), (76, 76, 0),   # READ_BL_PARTIAL, WRITE_BLK_MISALIGN, READ_BLK_MISALIGN, DSR_IMP
        (69, 48, c_size),       # C_SIZE
        (46, 46, 1),            # ERASE_BLK_EN
        (45, 39, 0x7F),         # SECTOR_SIZE
        (38, 32, 0), (31, 31, 0),   # WP_GRP_SIZE, WP_GRP_ENABLE
        (28, 26, 2),            # R2W_FACTOR (4 multiples)
        (25, 22, 9),            # WRITE_BL_LEN 512 B
        (21, 21, 0),            # WRITE_BL_PARTIAL
    ], 128)
    return reg | (crc7(reg >> 8, 120) << 1) | 1


SCR = 0x0235000000000000
# SCR (PLS 2.00 5.6): SCR_STRUCTURE 0, SD_SPEC 2 (version 2.00), DATA_STAT_AFTER_ERASE 0, SD_SECURITY 3 (version 2.00,
# required for High Capacity), SD_BUS_WIDTHS 0101b (1 bit and 4 bit; every card supports both, PLS 2.00 table 5-21).

OCR_VOLTAGE = 0x00FF8000        # PLS 2.00 table 5-1: bits 23:15 = 2.7 V .. 3.6 V
OCR_CCS, OCR_BUSY = 1 << 30, 1 << 31

# card states (PLS 2.00 4.10.1 CURRENT_STATE)
IDLE, READY, IDENT, STBY, TRAN, DATA, RCV, PRG, DIS = range(9)
INA = 15            # inactive: not a CURRENT_STATE value, the card does not answer in this state
STATE_NAMES = {IDLE: "idle", READY: "ready", IDENT: "ident", STBY: "stby", TRAN: "tran", DATA: "data", RCV: "rcv",
               PRG: "prg", DIS: "dis", INA: "ina"}

# card status bits (PLS 2.00 table 4-35)
S_OUT_OF_RANGE, S_ADDRESS_ERROR, S_BLOCK_LEN_ERROR = 1 << 31, 1 << 30, 1 << 29
S_ERASE_SEQ_ERROR, S_ERASE_PARAM = 1 << 28, 1 << 27
S_COM_CRC_ERROR, S_ILLEGAL_COMMAND, S_ERROR = 1 << 23, 1 << 22, 1 << 19
S_READY_FOR_DATA, S_APP_CMD = 1 << 8, 1 << 5

ACMDS = (6, 13, 22, 23, 41, 42, 51)     # application commands implemented (PLS 2.00 table 4-26)

# data block CRC status tokens (PLS 2.00 4.3.4 / SDIO: positive 010, CRC error 101, programming error 110)
TOKEN_OK, TOKEN_CRC, TOKEN_WRITE_ERR = 0b010, 0b101, 0b110


class ReadPlan:
    """What the card sends on DAT0 after a read command: blocks of data followed by the CRC16 of each block."""

    def __init__(self, kind, latency_us=0.0, latency_clocks=0, register=None):
        self.kind = kind                    # 'mem' blocks from the array (CMD17/18) | 'reg' one register block
        self.latency_us = latency_us        # delay after the end of the response (time set by the card)
        self.latency_clocks = latency_clocks
        self.register = register            # bytes of the register block ('reg')


class Reply:
    def __init__(self, nbits, frame, read=None, write=False, stop_data=False):
        self.nbits = nbits                  # 48 or 136
        self.frame = frame                  # response token as an integer of nbits bits
        self.read = read                    # ReadPlan or None
        self.write = write                  # the card now waits for data blocks from the host
        self.stop_data = stop_data          # CMD12: a running read transfer ends at the end bit of this command
        self.busy_us = 0.0                  # CMD38: the card is busy (programming state) for this long after the response
        self.prog_id = 0                    # ... and card.program_done(prog_id) ends it


class SDCard:
    def __init__(self, path, read_latency_us=1000.0, write_busy_us=4000.0, init_us=20000.0, erase_busy_us=1000.0,
                 ncr_clocks=8, token_gap_clocks=2):
        self.path = path
        self.f = open(path, "r+b")
        size = os.fstat(self.f.fileno()).st_size
        self.blocks = (size // (512 * 1024)) * 1024            # whole multiples of 512 KB (CSD C_SIZE unit, PLS 2.00 5.3.3)
        if self.blocks < 1024:
            self.f.close()
            raise ValueError(f"SD card image {path}: needs at least 512 KB")
        self.capacity = self.blocks * 512
        self.read_latency_us = read_latency_us
        self.write_busy_us = write_busy_us
        self.init_us = init_us
        self.erase_busy_us = erase_busy_us
        self.ncr_clocks = ncr_clocks
        self.token_gap_clocks = token_gap_clocks
        self.cid = make_cid()
        self.csd = make_csd_v2(self.blocks // 1024 - 1)
        self.reads = 0                  # statistics: 512-byte blocks read / written
        self.writes = 0
        self.log = []                   # (text) protocol events for the host model to forward
        self.power_up()

    # ------------------------------------------------------------ power
    def power_up(self):
        """Power-up or insertion (PLS 2.00 6.4.1): idle state, default RCA 0, 1-bit bus, no pending error."""
        self.state = IDLE
        self.rca = 0
        self._rca_seq = 0x1234          # RCAs published by CMD3 are 0x1234, 0x1235, ... (any value except 0 is legal)
        self.bus_width = 1
        self.blocklen = 512
        self.app_pending = False
        self.v2_host = False            # CMD8 received (PLS 2.00 4.2.2)
        self.init_started = False
        self.init_done = False
        self.init_wanted_hcs = False
        self._init_gen = getattr(self, "_init_gen", 0) + 1           # timers of an earlier power-up are void
        self._init_start_gen = None
        self.busy = False               # programming / erase in progress (READY_FOR_DATA = 0)
        self.prog_id = getattr(self, "prog_id", 0) + 1   # identity of the running programming operation (see program_done)
        self.wr_failed = False          # a block of the running CMD25 had a CRC error: later blocks are ignored (PLS 2.00 4.3.4)
        # test faults (scripts only, never set by the UI): the next n data blocks are disturbed on the bus as by line noise:
        # 'write_crc' the card sees a CRC error in a block it receives (negative CRC status token, nothing written),
        # 'read_crc' the CRC16 the host receives after a block the card sends does not match (DCRCFAIL at the host)
        self.faults = {'write_crc': 0, 'read_crc': 0, 'write_slow': 0}
        self.write_slow_us = 900000.0   # test fault 'write_slow': busy time of such a block (longer than the firmware's 600 ms wait)
        self.b_bits = 0                 # status bits of type B (COM_CRC_ERROR, ILLEGAL_COMMAND): reported once
        self.c_bits = 0                 # status bits of type C (cleared by read)
        self.rd_addr = 0
        self.wr_addr = 0
        self.wr_blocks_ok = 0           # ACMD22: blocks written without error by the last write command
        self.erase_start = None
        self.erase_end = None
        self.preerase = 1
        self.data_dir = None            # 'r' while a read transfer is active, 'w' while the card accepts blocks
        self.multi = False

    # ------------------------------------------------------------ image access
    def _read_block(self, lba):
        try:
            self.f.seek(lba * 512)
            d = self.f.read(512)
        except OSError as e:                                         # host I/O error: general error, zero data
            self.log.append(f"image read error: {e}")
            self.c_bits |= S_ERROR
            return bytes(512)
        return d + bytes(512 - len(d))

    def _write_block(self, lba, data):
        """True when the block reached the image file (flushed to the host)."""
        try:
            self.f.seek(lba * 512)
            self.f.write(data)
            self.f.flush()
            return True
        except OSError as e:
            self.log.append(f"image write error: {e}")
            self.c_bits |= S_ERROR
            return False

    def _erase_range(self, first, last):
        """Overwrite blocks first..last (inclusive) with zeros in 1 MiB steps."""
        try:
            self.f.seek(first * 512)
            left = (last - first + 1) * 512
            chunk = bytes(1 << 20)
            while left:
                n = min(left, len(chunk))
                self.f.write(chunk[:n])
                left -= n
            self.f.flush()
        except OSError as e:
            self.log.append(f"image write error: {e}")
            self.c_bits |= S_ERROR

    def close(self):
        self.f.close()

    # ------------------------------------------------------------ helpers
    def _status(self, state, app_bit):
        """R1 card status (PLS 2.00 4.10.1): CURRENT_STATE is the state when the command was received."""
        s = (state << 9) | self.c_bits | self.b_bits
        if not self.busy:
            s |= S_READY_FOR_DATA
        if app_bit:
            s |= S_APP_CMD
        self.c_bits = 0
        self.b_bits = 0
        return s

    def _r1(self, index, state, app_bit, extra=0):
        self.c_bits |= extra
        return Reply(48, short_frame(index, self._status(state, app_bit)))

    def _illegal(self):
        """PLS 2.00 4.6.1: no response, no state change, ILLEGAL_COMMAND is reported in the next response."""
        self.b_bits |= S_ILLEGAL_COMMAND
        self.log.append("illegal command")
        return None

    def _start_busy(self):
        self.busy = True
        self.prog_id += 1
        return self.prog_id

    def program_done(self, prog_id):
        """The host model calls this when the busy time of the operation `prog_id` (the card's prog_id right after the
        command / block that started it) has elapsed: 'operation complete', prg -> tran, dis -> stby (PLS 2.00 table 4-28).
        A call for an operation that CMD0 / power-up has voided does nothing."""
        if prog_id != self.prog_id:
            return
        self.busy = False
        if self.state == PRG:
            self.state = TRAN
        elif self.state == DIS:
            self.state = STBY

    def read_end(self):
        """The data of a read transfer has been transmitted completely: data -> tran (PLS 2.00 table 4-28)."""
        if self.state == DATA:
            self.state = TRAN
        self.data_dir = None

    # ------------------------------------------------------------ command interface
    def command(self, index, arg, crc_ok):
        """Process a received command token.  Returns a Reply or None (no response)."""
        if self.state == INA:
            return None                     # inactive state: the card ignores everything until power-up (PLS 2.00 4.2.2, CMD15)
        if not crc_ok:
            self.b_bits |= S_COM_CRC_ERROR  # PLS 2.00 4.6.1: no response, no execution
            self.app_pending = False
            return None
        was_app = self.app_pending
        self.app_pending = False
        if was_app and index in ACMDS:
            return self._acmd(index, arg)
        return self._cmd(index, arg)

    # --- regular commands
    def _cmd(self, i, arg):
        st = self.state
        rca_arg = (arg >> 16) & 0xFFFF
        if i == 0:                                                   # GO_IDLE_STATE (any state)
            self.state = IDLE
            self.rca = 0
            self.busy = False
            self.prog_id += 1                                        # a running programming timer is void
            self.data_dir = None
            self.init_started = self.init_done = False
            self._init_gen += 1                                      # a running initialisation timer is void
            self._init_start_gen = None
            self.v2_host = False
            self.bus_width = 1
            self.b_bits = self.c_bits = 0
            return None                                              # bc, no response
        if i == 8:                                                   # SEND_IF_COND (idle only; PLS 2.00 4.3.13)
            if st != IDLE:
                return self._illegal()
            if (arg >> 8) & 0xF != 1:                                # 2.7-3.6 V is the only voltage the card supports
                return None                                          # voltage not supported: no response, stays idle
            self.v2_host = True
            return Reply(48, short_frame(8, arg & 0xFFF))            # R7: voltage accepted + echoed check pattern
        if i == 55:                                                  # APP_CMD
            if st in (READY, IDENT, INA):
                return self._illegal()
            if st != IDLE and rca_arg != self.rca:
                return None                                          # addressed command, other card
            self.app_pending = True
            return self._r1(55, st, True)
        if i == 2:                                                   # ALL_SEND_CID
            if st != READY:
                return self._illegal()
            self.state = IDENT
            return Reply(136, r2_frame(self.cid))
        if i == 3:                                                   # SEND_RELATIVE_ADDR
            if st not in (IDENT, STBY):
                return self._illegal()
            self.rca = self._rca_seq
            self._rca_seq += 1
            status = self._status(st, False)
            r6 = (self.rca << 16) | (((status >> 23) & 1) << 15) | (((status >> 22) & 1) << 14) | \
                 (((status >> 19) & 1) << 13) | (status & 0x1FFF)    # PLS 2.00 table 4-32 / 4-36
            if st == IDENT:
                self.state = STBY
            return Reply(48, short_frame(3, r6))
        if i == 4:                                                   # SET_DSR: DSR_IMP = 0 in the CSD, the card ignores it
            if st != STBY:
                return self._illegal()
            return None
        if i == 7:                                                   # SELECT/DESELECT_CARD
            if st not in (STBY, TRAN, DATA, RCV, PRG, DIS):
                return self._illegal()
            if rca_arg == self.rca and self.rca != 0:                # addressed
                if st == STBY:
                    r = self._r1(7, st, False)
                    self.state = TRAN
                    return r
                if st == DIS:
                    r = self._r1(7, st, False)
                    self.state = PRG
                    return r
                return self._illegal()                               # CMD7 in tran/data/rcv/prg addressed: '-' in table 4-28
            if st in (TRAN, DATA):                                   # not addressed: deselect -> stby, no response
                self.state = STBY
                self.data_dir = None
            elif st == PRG:
                self.state = DIS
            return None
        if i in (9, 10):                                             # SEND_CSD, SEND_CID (stby only)
            if st != STBY:
                return self._illegal()
            if rca_arg != self.rca:
                return None
            return Reply(136, r2_frame(self.csd if i == 9 else self.cid))
        if i == 12:                                                  # STOP_TRANSMISSION
            if st == DATA:
                self.state = TRAN
                self.data_dir = None
                return Reply(48, short_frame(12, self._status(st, False)), stop_data=True)
            if st == RCV:                                            # rcv -> prg; with no block being programmed the operation
                self.state = PRG if self.busy else TRAN              # is complete at once (prg -> tran, table 4-28)
                self.data_dir = None
                self.wr_failed = False
                return self._r1(12, st, False)
            return self._illegal()
        if i == 13:                                                  # SEND_STATUS
            if st not in (STBY, TRAN, DATA, RCV, PRG, DIS):
                return self._illegal()
            if rca_arg != self.rca:
                return None
            return self._r1(13, st, False)
        if i == 15:                                                  # GO_INACTIVE_STATE
            if st not in (STBY, TRAN, DATA, RCV, PRG, DIS):
                return self._illegal()
            if rca_arg != self.rca:
                return None
            self.state = INA
            return None
        if i == 16:                                                  # SET_BLOCKLEN (tran only)
            if st != TRAN:
                return self._illegal()
            if arg > 512:                                            # PLS 2.00 4.3.14: larger than 512 -> BLOCK_LEN_ERROR
                return self._r1(16, st, False, S_BLOCK_LEN_ERROR)
            self.blocklen = arg
            return self._r1(16, st, False)
        if i in (17, 18):                                            # READ_SINGLE_BLOCK, READ_MULTIPLE_BLOCK
            if st != TRAN:
                return self._illegal()
            if arg >= self.blocks:                                   # block address (SDHC, PLS 2.00 4.3.14)
                return self._r1(i, st, False, S_OUT_OF_RANGE)
            r = self._r1(i, st, False)
            self.state = DATA
            self.data_dir = 'r'
            self.rd_addr = arg
            self.multi = (i == 18)
            r.read = ReadPlan('mem', latency_us=self.read_latency_us)
            return r
        if i in (24, 25):                                            # WRITE_BLOCK, WRITE_MULTIPLE_BLOCK
            if st != TRAN:
                return self._illegal()
            if arg >= self.blocks:
                return self._r1(i, st, False, S_OUT_OF_RANGE)
            r = self._r1(i, st, False)
            self.state = RCV
            self.data_dir = 'w'
            self.wr_addr = arg
            self.multi = (i == 25)
            self.wr_blocks_ok = 0
            self.wr_failed = False
            r.write = True
            return r
        if i in (32, 33):                                            # ERASE_WR_BLK_START / END
            if st != TRAN:
                return self._illegal()
            if arg >= self.blocks:
                return self._r1(i, st, False, S_OUT_OF_RANGE | S_ERASE_PARAM)
            if i == 32:
                self.erase_start = arg
            else:
                self.erase_end = arg
            return self._r1(i, st, False)
        if i == 38:                                                  # ERASE
            if st != TRAN:
                return self._illegal()
            if self.erase_start is None or self.erase_end is None:
                return self._r1(38, st, False, S_ERASE_SEQ_ERROR)
            if self.erase_end < self.erase_start:
                self.erase_start = self.erase_end = None
                return self._r1(38, st, False, S_ERASE_PARAM)
            self._erase_range(self.erase_start, self.erase_end)     # SCR DATA_STAT_AFTER_ERASE = 0: erased blocks read 0
            self.erase_start = self.erase_end = None
            r = self._r1(38, st, False)
            self.state = PRG
            r.prog_id = self._start_busy()
            r.busy_us = self.erase_busy_us
            return r
        return self._illegal()

    # --- application commands (preceded by CMD55)
    def _acmd(self, i, arg):
        st = self.state
        if i == 41:                                                  # SD_SEND_OP_COND (idle only, PLS 2.00 table 4-28)
            if st != IDLE:
                return self._illegal()
            window = arg & 0x00FFFFFF
            if window == 0:                                          # query mode: card stays idle, does not initialise
                return Reply(48, r3_frame(self._ocr()))
            if window & OCR_VOLTAGE == 0:                            # OCR check fails: inactive state
                self.state = INA
                return None
            if not self.init_started:
                self.init_started = True
                self.init_wanted_hcs = bool(arg & OCR_CCS) and self.v2_host
                self._init_start_gen = self._init_gen                # the host model starts the init timer via init_pending()
            ocr = self._ocr()
            if self.init_done:
                self.state = READY
            return Reply(48, r3_frame(ocr))
        if st != TRAN:                                               # all other ACMDs: tran only
            return self._illegal()
        if i == 6:                                                   # SET_BUS_WIDTH: 00 = 1 bit, 10 = 4 bits (table 4-26)
            if arg & 3 == 0:
                self.bus_width = 1
            elif arg & 3 == 2:
                self.bus_width = 4
            else:
                return self._r1(6, st, True, S_ERROR)                # value not defined by the specification
            return self._r1(6, st, True)
        if i == 13:                                                  # SD_STATUS: 512 bits (table 4-37)
            r = self._r1(13, st, True)
            self.state = DATA
            self.data_dir = 'r'
            r.read = ReadPlan('reg', latency_us=self.read_latency_us, register=self._sd_status())
            return r
        if i == 22:                                                  # SEND_NUM_WR_BLOCKS: 32 bit
            r = self._r1(22, st, True)
            self.state = DATA
            self.data_dir = 'r'
            r.read = ReadPlan('reg', latency_us=self.read_latency_us, register=struct.pack(">I", self.wr_blocks_ok))
            return r
        if i == 23:                                                  # SET_WR_BLK_ERASE_COUNT
            self.preerase = arg & 0x7FFFFF
            return self._r1(23, st, True)
        if i == 42:                                                  # SET_CLR_CARD_DETECT: pull-up on DAT3 not wired, no effect
            return self._r1(42, st, True)
        if i == 51:                                                  # SEND_SCR: 64 bit, most significant byte first
            r = self._r1(51, st, True)
            self.state = DATA
            self.data_dir = 'r'
            r.read = ReadPlan('reg', latency_us=self.read_latency_us, register=SCR.to_bytes(8, "big"))
            return r
        return self._illegal()

    def _ocr(self):
        """OCR (PLS 2.00 5.1): bit 31 = power-up complete (0 while busy), bit 30 = CCS, valid after bit 31 is set."""
        ocr = OCR_VOLTAGE
        if self.init_done:
            ocr |= OCR_BUSY
            if self.init_wanted_hcs:
                ocr |= OCR_CCS
        return ocr

    def init_pending(self):
        """Generation number once, right after the first ACMD41 started the card's internal initialisation, else None:
        the host model must call init_complete(gen) init_us microseconds later (PLS 2.00 4.2.3: the card reports busy
        until then)."""
        g, self._init_start_gen = self._init_start_gen, None
        return g

    def init_complete(self, gen):
        if gen == self._init_gen and self.state == IDLE and self.init_started:
            # A High Capacity card never reports ready to a host that did not send CMD8 / HCS (PLS 2.00 4.2.3).
            if self.init_wanted_hcs:
                self.init_done = True

    def _sd_status(self):
        """SD status block (PLS 2.00 table 4-37): 512 bits, bit 511 first."""
        reg = (0b10 if self.bus_width == 4 else 0) << 510
        return reg.to_bytes(64, "big")

    # ------------------------------------------------------------ data interface used by the host model
    def read_block(self):
        """Next 512-byte block of the running read transfer; None when the address ran past the end of the card."""
        if self.rd_addr >= self.blocks:
            self.c_bits |= S_OUT_OF_RANGE
            return None
        d = self._read_block(self.rd_addr)
        self.rd_addr += 1
        self.reads += 1
        return d

    def write_block(self, data, host_crc):
        """A data block with its CRC16 has been received (PLS 2.00 4.3.4).  Returns (CRC status token, busy_us); when busy_us
        is not 0 the host model calls program_done(card.prog_id) that long later (read prog_id right after this call)."""
        if self.wr_failed:                                           # PLS 2.00 4.3.4: after a CRC error the later blocks of a
            return TOKEN_CRC, 0.0                                    # multiple block write are ignored
        if self.faults.get('write_crc', 0) > 0:                      # test fault: the block arrived disturbed
            self.faults['write_crc'] -= 1
            host_crc ^= 0x0001
        if len(data) != 512 or crc16(data) != host_crc:
            self.log.append(f"write block rejected: {'length' if len(data) != 512 else 'CRC'} error")
            self.state = TRAN if not self.multi else RCV
            if not self.multi:
                self.data_dir = None
            else:
                self.wr_failed = True
            return TOKEN_CRC, 0.0
        if self.wr_addr >= self.blocks:
            self.c_bits |= S_OUT_OF_RANGE
            return TOKEN_WRITE_ERR, 0.0
        if not self._write_block(self.wr_addr, data):
            return TOKEN_WRITE_ERR, 0.0
        self.wr_addr += 1
        self.writes += 1
        self.wr_blocks_ok += 1
        self._start_busy()
        if not self.multi:                                           # single block: rcv -> prg -> tran when done
            self.state = PRG
            self.data_dir = None
        if self.faults.get('write_slow', 0) > 0:                     # test fault: the card programs this block slowly (cards
            self.faults['write_slow'] -= 1                           # can exceed the 250 / 500 ms of PLS 4.6.2.2 in practice)
            return TOKEN_OK, self.write_slow_us
        return TOKEN_OK, self.write_busy_us

    def snapshot(self):
        return {"state": STATE_NAMES.get(self.state, str(self.state)), "rca": self.rca, "blocks": self.blocks,
                "reads": self.reads, "writes": self.writes, "bus_width": self.bus_width}


# ---------------------------------------------------------------- image creation (FAT32)
FAT32_MIN_BYTES = 64 * 1024 * 1024


def format_fat32(path, size_bytes, label=b"EEV121GW"):
    """Create `path` (must not exist) as a FAT32 volume of size_bytes without partition table, laid out as in the
    Microsoft FAT specification (fatgen103).  Only `path` is written.  Host tools are not needed.
    Cluster size by volume size (fatgen103 table for FAT32, 512-byte sectors): up to 260 MB 1 sector, up to 8 GB 8,
    up to 16 GB 16, up to 32 GB 32."""
    if size_bytes % (512 * 1024) or size_bytes < FAT32_MIN_BYTES:
        raise ValueError("SD card image size must be a multiple of 512 KB and at least 64 MiB (FAT32 needs 65525 clusters)")
    total = size_bytes // 512
    if size_bytes <= 260 * 1024 * 1024:
        spc = 1
    elif size_bytes <= 8 * 1024 ** 3:
        spc = 8
    elif size_bytes <= 16 * 1024 ** 3:
        spc = 16
    else:
        spc = 32
    rsvd, nfats = 32, 2
    tmp2 = ((256 * spc) + nfats) // 2
    fatsz = ((total - rsvd) + (tmp2 - 1)) // tmp2
    clusters = (total - rsvd - nfats * fatsz) // spc
    if clusters < 65525:
        raise ValueError("volume too small for FAT32 with this cluster size")
    label = label.ljust(11)[:11]
    bs = bytearray(512)
    bs[0:3] = b"\xEB\x58\x90"
    bs[3:11] = b"EEV121GW"
    struct.pack_into("<HBHBHHBHHHII", bs, 11, 512, spc, rsvd, nfats, 0, 0, 0xF8, 0, 63, 255, 0, total)
    struct.pack_into("<IHHIHH", bs, 36, fatsz, 0, 0, 2, 1, 6)        # FATSz32, ExtFlags, FSVer, RootClus, FSInfo, BkBootSec
    bs[64] = 0x80                                                    # DrvNum
    bs[66] = 0x29                                                    # BootSig
    struct.pack_into("<I", bs, 67, 0x121B0001)                       # VolID
    bs[71:82] = label
    bs[82:90] = b"FAT32   "
    bs[510:512] = b"\x55\xAA"
    fsinfo = bytearray(512)
    struct.pack_into("<I", fsinfo, 0, 0x41615252)
    struct.pack_into("<I", fsinfo, 484, 0x61417272)
    struct.pack_into("<II", fsinfo, 488, clusters - 1, 3)            # free clusters (root uses one), next free hint
    struct.pack_into("<I", fsinfo, 508, 0xAA550000)
    fat0 = struct.pack("<III", 0x0FFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF)   # media, EOC, root directory cluster end of chain
    root = bytearray(spc * 512)
    root[0:11] = label                                               # volume label entry
    root[11] = 0x08
    f = open(path, "xb")                                             # exclusive: an existing file is never touched
    try:
        with f:
            f.truncate(size_bytes)
            for base in (0, 6):                                      # boot sector and its backup (BkBootSec = 6)
                f.seek(base * 512)
                f.write(bs)
                f.seek((base + 1) * 512)
                f.write(fsinfo)
            for n in range(nfats):
                f.seek((rsvd + n * fatsz) * 512)
                f.write(fat0)
            f.seek((rsvd + nfats * fatsz) * 512)
            f.write(root)
    except BaseException:
        os.remove(path)                                              # no half formatted image is left behind
        raise
    return clusters


def open_card(path, size_mb=512, **kw):
    """Open the card image at `path`; if it does not exist create it with `size_mb` MiB and format it FAT32."""
    if not os.path.exists(path):
        format_fat32(path, size_mb * 1024 * 1024)
    return SDCard(path, **kw)
