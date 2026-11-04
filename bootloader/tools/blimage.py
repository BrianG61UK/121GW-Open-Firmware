"""Formats of the two-part bootloader (bootloader/DESIGN.md 6, src/starter.s): headers, slots, control records.

Header (slot header at the slot start, bootloader mark at MARK), five little-endian words:
    HDR_MAGIC, length (1..BL_MAX), CRC-32 of the image, version, CRC-32 of the four words before it
Slot: header, image from slot + SLOT_IMG.
Control record (CTL_BASE..CTL_END, 16 bytes, appended into erased words; the last valid record counts):
    CTL_MAGIC, command, argument, CRC-32 of the three words before it
CRC-32 is zlib's (reflected polynomial 0xEDB88320, initial value and final XOR 0xFFFFFFFF).  Erased flash reads 0x00.
The constants are the ones of src/starter.s; tests/test_starter.py checks the starter against this file.
"""
import struct
import zlib

BL_BASE, MARK, BL_END = 0x08000400, 0x08005F00, 0x08006000
BL_MAX = MARK - BL_BASE
SLOT_A, SLOT_B, SLOT_SIZE, SLOT_IMG = 0x08052000, 0x08058000, 0x6000, 0x100
CTL_BASE, CTL_END, CTL_REC = 0x0805E000, 0x0805FF00, 16
HDR_MAGIC, CTL_MAGIC = 0x32484C42, 0x4C525443
CMD_INSTALL, CMD_TRIAL, CMD_OK = 1, 2, 3


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def header(image, version):
    """The 20-byte header of a bootloader image."""
    if not 1 <= len(image) <= BL_MAX:
        raise ValueError('bootloader image of %d bytes: 1..%d allowed' % (len(image), BL_MAX))
    w = struct.pack('<4I', HDR_MAGIC, len(image), crc32(image), version)
    return w + struct.pack('<I', crc32(w))


def slot(image, version):
    """Slot contents from the slot start: header page (header, rest erased), image, padded to whole half-pages."""
    pad = -len(image) % 128
    return header(image, version) + bytes(SLOT_IMG - 20) + image + bytes(pad)


def record(cmd, arg):
    w = struct.pack('<3I', CTL_MAGIC, cmd, arg)
    return w + struct.pack('<I', crc32(w))


def parse_header(data):
    """(length, image CRC, version) of a valid header, else None."""
    magic, length, icrc, version, hcrc = struct.unpack_from('<5I', data)
    if magic != HDR_MAGIC or not 1 <= length <= BL_MAX or crc32(data[:16]) != hcrc:
        return None
    return length, icrc, version


def parse_control(area):
    """(last valid record as (cmd, arg) or None, offset of the first erased record or None) of the control area."""
    last, free = None, None
    for off in range(0, CTL_END - CTL_BASE, CTL_REC):
        rec = area[off:off + CTL_REC]
        if not any(rec):
            free = off
            break
        magic, cmd, arg, crc = struct.unpack('<4I', rec)
        if magic == CTL_MAGIC and crc32(rec[:12]) == crc:
            last = (cmd, arg)
    return last, free
