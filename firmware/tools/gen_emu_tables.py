#!/usr/bin/env python3
"""gen_emu_tables.py - write the v2.05 constant tables of a firmware build as a data file for the emulator.

Usage (from the repository root, after `make` in firmware/):
    python3 -I firmware/tools/gen_emu_tables.py firmware/build/121gw.elf firmware/build/EEVBlog.bin OUT.json

The emulator's calibrated front end (emulator/emu/frontend.py) inverts the arithmetic of the original v2.05 firmware.  It
needs the original's constant tables (the EEPROM record-base table at 0x08028EE8, the correction, thermocouple, burden and
interpolation tables) at their v2.05 addresses.  The firmware sources carry exactly these tables, each one introduced by
`TABLE_V205 <v2.05 address>, <length>` (firmware/src/inc/macros.inc), which writes a 12-byte record into the non-loaded
section .v205tab of the ELF: v2.05 address, length, address of the copy in the linked image.  This tool reads those records,
takes the bytes of every copy from the raw image, and writes them under their v2.05 addresses.  Nothing but the table
contents of the repository's own sources goes into the output; the original image is not read.

Output JSON:
    {"format": "121gw-v205-tables/1", "source": "...", "segments": [{"addr": <int>, "hex": "<bytes>"}, ...]}
Segments are sorted by address; tables that touch or overlap are merged.  Two tables that overlap with different bytes are an
error (the data would be ambiguous).  The ELF must be the one the raw image was made from: the tool checks that the image is
the loadable flash content of the ELF at every copy.

Exit status 0 = written, 1 = inconsistency, 2 = unusable input.
"""
import json
import struct
import sys

sys.dont_write_bytecode = True
IMAGE_BASE = 0x08006000                       # load address of the application image (firmware/link/121gw.ld)
FORMAT = '121gw-v205-tables/1'


class ToolError(Exception):
    pass


def elf_sections(path):
    """Minimal ELF32 little-endian reader: list of [name, type, flags, addr, offset, size] and the file bytes."""
    with open(path, 'rb') as f:
        b = f.read()
    if b[:4] != b'\x7fELF' or b[4] != 1 or b[5] != 1:
        raise ToolError('%s is not an ELF32 little-endian file' % path)
    shoff, = struct.unpack_from('<I', b, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 0x2E)
    secs = [list(struct.unpack_from('<IIIIII', b, shoff + i * shentsize)) for i in range(shnum)]
    stro = secs[shstrndx][4]
    for s in secs:
        e = b.index(b'\0', stro + s[0])
        s[0] = b[stro + s[0]:e].decode()
    return secs, b


def tables(elf_path, bin_path):
    """[(v2.05 address, bytes)] of every TABLE_V205 record, with the bytes read from the raw image."""
    secs, b = elf_sections(elf_path)
    tab = [s for s in secs if s[0] == '.v205tab']
    if not tab:
        raise ToolError('%s has no .v205tab section (not a build of this firmware)' % elf_path)
    with open(bin_path, 'rb') as f:
        img = f.read()
    loadable = [s for s in secs if s[1] == 1 and (s[2] & 2) and s[5] and s[3] >= IMAGE_BASE and s[3] < 0x08060000]
    out = []
    for i in range(0, tab[0][5], 12):
        addr, length, copy = struct.unpack_from('<III', b, tab[0][4] + i)
        off = copy - IMAGE_BASE
        if length == 0 or off < 0 or off + length > len(img):
            raise ToolError('table 0x%08X: copy at 0x%08X+%d is outside the image' % (addr, copy, length))
        data = img[off:off + length]
        inside = [s for s in loadable if s[3] <= copy and copy + length <= s[3] + s[5]]
        if not inside:
            raise ToolError('table 0x%08X: copy at 0x%08X is not inside a loaded section of the ELF' % (addr, copy))
        s = inside[0]
        if b[s[4] + copy - s[3]:s[4] + copy - s[3] + length] != data:
            raise ToolError('table 0x%08X: the raw image differs from the ELF at the copy 0x%08X' % (addr, copy))
        out.append((addr, data))
    if not out:
        raise ToolError('%s: .v205tab is empty' % elf_path)
    return out


def merge(entries):
    """Sorted, merged segments [(address, bytes)]; overlapping tables must agree byte for byte."""
    segs = []
    for addr, data in sorted(entries):
        if segs and addr <= segs[-1][0] + len(segs[-1][1]):
            base, cur = segs[-1]
            ov = base + len(cur) - addr
            if ov > 0 and cur[addr - base:] != data[:ov]:
                raise ToolError('tables overlapping at 0x%08X differ' % addr)
            segs[-1] = (base, cur + data[max(ov, 0):])
        else:
            segs.append((addr, data))
    return segs


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    elf_path, bin_path, out_path = argv
    try:
        ents = tables(elf_path, bin_path)
        segs = merge(ents)
    except ToolError as e:
        print('gen_emu_tables: ERROR %s' % e)
        return 2 if 'differ' not in str(e) else 1
    doc = {'format': FORMAT,
           'source': 'TABLE_V205 records of the firmware build (firmware/src/inc/macros.inc), %d tables' % len(ents),
           'segments': [{'addr': a, 'hex': d.hex()} for a, d in segs]}
    with open(out_path, 'w') as f:
        json.dump(doc, f, indent=0, separators=(',', ':'))
        f.write('\n')
    print('gen_emu_tables: %d tables in %d segments, %d bytes -> %s' % (len(ents), len(segs), sum(len(d) for _, d in segs), out_path))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
