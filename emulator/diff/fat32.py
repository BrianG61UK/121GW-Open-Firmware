"""FAT32 volume access for the differential test harness: list the files on an SD card image after a run and place
files on a card image before a run.

Layout facts used (Microsoft "FAT: General Overview of On-Disk Format", fatgen103):
    BPB fields at boot sector offsets 11 (BytsPerSec), 13 (SecPerClus), 14 (RsvdSecCnt), 16 (NumFATs),
    32 (TotSec32), 36 (FATSz32), 44 (RootClus), 48 (FSInfo sector); signature 0x55 0xAA at 510.
    FAT32 entries are 28 bits (the top 4 bits are reserved and preserved on write); 0 = free,
    >= 0x0FFFFFF8 = end of chain.  Cluster N starts at sector RsvdSecCnt + NumFATs * FATSz32 + (N - 2) * SecPerClus.
    Directory entries are 32 bytes: name 0..10 (8.3, space padded), attribute 11 (0x0F = long name part,
    0x08 = volume label, 0x10 = directory), WrtTime 22, WrtDate 24, FstClusHI 20, FstClusLO 26, FileSize 28.
    Name byte 0x00 ends the directory, 0xE5 marks a deleted entry.  Long name entries carry 13 UTF-16 characters at
    offsets 1, 14 and 28; their sequence number is byte 0 & 0x3F and bit 0x40 marks the last (first stored) part.
    FSInfo: lead signature 0x41615252 at 0, struct signature 0x61417272 at 484, free count at 488, next free at 492.
A card image may carry the volume directly at sector 0 (emu/sdcard.format_fat32 writes it that way) or behind an MBR
partition table (entry 1 at offset 446, type at +4, first LBA at +8); both are recognised.
"""
import hashlib
import struct

EOC = 0x0FFFFFF8


class FatError(ValueError):
    pass


class Volume:
    def __init__(self, path, writable=False):
        self.path = path
        self.f = open(path, 'r+b' if writable else 'rb')
        self.base = self._find_volume()
        bs = self._sector(0)
        (self.bps, self.spc, self.rsvd, self.nfats) = struct.unpack_from('<HBHB', bs, 11)
        self.total = struct.unpack_from('<I', bs, 32)[0]
        self.fatsz = struct.unpack_from('<I', bs, 36)[0]
        self.root = struct.unpack_from('<I', bs, 44)[0]
        self.fsinfo = struct.unpack_from('<H', bs, 48)[0]
        if self.bps != 512 or self.spc == 0 or self.fatsz == 0:
            raise FatError(f'{path}: not a FAT32 volume with 512-byte sectors')
        self.data0 = self.rsvd + self.nfats * self.fatsz
        self.clusters = (self.total - self.data0) // self.spc
        self.csize = self.spc * self.bps

    def close(self):
        self.f.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # ------------------------------------------------------------------ raw access
    def _find_volume(self):
        self.f.seek(0)
        s0 = self.f.read(512)
        if len(s0) < 512 or s0[510:512] != b'\x55\xAA':
            raise FatError(f'{self.path}: no boot sector signature')
        if s0[82:90] == b'FAT32   ':
            return 0
        for i in range(4):                                  # MBR partition entries
            e = s0[446 + 16 * i: 462 + 16 * i]
            if e[4] in (0x0B, 0x0C):
                return struct.unpack_from('<I', e, 8)[0]
        raise FatError(f'{self.path}: no FAT32 volume found')

    def _sector(self, n, count=1):
        self.f.seek((self.base + n) * 512)
        d = self.f.read(512 * count)
        return d + bytes(512 * count - len(d))

    def _write_sector(self, n, data):
        self.f.seek((self.base + n) * 512)
        self.f.write(data)

    def fat(self, n):
        off = n * 4
        sec = self._sector(self.rsvd + off // 512)
        return struct.unpack_from('<I', sec, off % 512)[0] & 0x0FFFFFFF

    def _set_fat(self, n, value):
        off = n * 4
        for k in range(self.nfats):
            s = self.rsvd + k * self.fatsz + off // 512
            sec = bytearray(self._sector(s))
            old = struct.unpack_from('<I', sec, off % 512)[0]
            struct.pack_into('<I', sec, off % 512, (old & 0xF0000000) | (value & 0x0FFFFFFF))
            self._write_sector(s, sec)

    def chain(self, first):
        out, n, seen = [], first, set()
        while 2 <= n < EOC:
            if n in seen or n - 2 >= self.clusters:
                raise FatError(f'{self.path}: broken cluster chain at {n}')
            seen.add(n)
            out.append(n)
            n = self.fat(n)
        return out

    def read_cluster(self, n):
        return self._sector(self.data0 + (n - 2) * self.spc, self.spc)

    def read_chain(self, first, size=None):
        data = b''.join(self.read_cluster(c) for c in self.chain(first)) if first else b''
        return data if size is None else data[:size]

    # ------------------------------------------------------------------ directories
    @staticmethod
    def _short_name(e):
        base = e[0:8].rstrip(b' ')
        ext = e[8:11].rstrip(b' ')
        if base[:1] == b'\x05':
            base = b'\xE5' + base[1:]
        name = base.decode('latin-1')
        return name + ('.' + ext.decode('latin-1') if ext else '')

    def entries(self, first):
        """Directory entries of the directory starting at cluster `first`: dicts with short and long name, attribute,
        first cluster, size and the raw write date/time words."""
        raw = self.read_chain(first)
        lfn = {}
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0x00:
                break
            if e[0] == 0xE5:
                lfn = {}
                continue
            attr = e[11]
            if attr == 0x0F:
                seq = e[0] & 0x3F
                chars = e[1:11] + e[14:26] + e[28:32]
                lfn[seq] = chars.decode('utf-16-le', 'replace').split('\x00')[0].replace('￿', '')
                continue
            long_name = ''.join(lfn[k] for k in sorted(lfn)) if lfn else None
            lfn = {}
            if attr & 0x08:
                continue                                    # volume label
            short = self._short_name(e)
            if short in ('.', '..'):
                continue
            hi, wtime, wdate, lo, size = struct.unpack_from('<HHHHI', e, 20)
            yield {'name': short, 'long': long_name, 'attr': attr, 'cluster': (hi << 16) | lo, 'size': size,
                   'wdate': wdate, 'wtime': wtime}

    def walk(self, first=None, prefix=''):
        """All files below the directory at cluster `first` (default the root): (path, entry) pairs."""
        for e in self.entries(self.root if first is None else first):
            path = prefix + '/' + e['name']
            if e['attr'] & 0x10:
                yield path + '/', e
                yield from self.walk(e['cluster'], path)
            else:
                yield path, e

    # ------------------------------------------------------------------ file creation
    def _free_clusters(self, count):
        found = []
        for n in range(2, self.clusters + 2):
            if self.fat(n) == 0:
                found.append(n)
                if len(found) == count:
                    return found
        raise FatError(f'{self.path}: not enough free clusters')

    def add_file(self, name83, data, wdate, wtime):
        """Create file `name83` (8.3 upper-case name such as 'CAL.BIN') with `data` in the root directory."""
        base, _, ext = name83.upper().partition('.')
        if not (1 <= len(base) <= 8 and len(ext) <= 3):
            raise FatError(f'{name83}: not an 8.3 name')
        field = base.ljust(8).encode('ascii') + ext.ljust(3).encode('ascii')
        for e in self.entries(self.root):
            if e['name'] == name83.upper():
                raise FatError(f'{name83}: already on the card')
        n = max(1, -(-len(data) // self.csize)) if data else 0
        cl = self._free_clusters(n) if n else []
        for i, c in enumerate(cl):
            chunk = data[i * self.csize:(i + 1) * self.csize]
            self._write_sector(self.data0 + (c - 2) * self.spc, chunk.ljust(self.csize, b'\x00'))
            self._set_fat(c, cl[i + 1] if i + 1 < len(cl) else 0x0FFFFFFF)
        # directory slot in the root's chain
        rc = self.chain(self.root)
        for c in rc:
            buf = bytearray(self.read_cluster(c))
            for i in range(0, len(buf), 32):
                if buf[i] in (0x00, 0xE5):
                    first = cl[0] if cl else 0
                    ent = field + bytes([0x20, 0, 0]) + struct.pack('<HHHHHHHI', wtime, wdate, wdate,
                                                                    first >> 16, wtime, wdate, first & 0xFFFF,
                                                                    len(data))
                    buf[i:i + 32] = ent
                    self._write_sector(self.data0 + (c - 2) * self.spc, bytes(buf))
                    self._fsinfo_take(len(cl))
                    self.f.flush()
                    return
        raise FatError(f'{self.path}: root directory cluster chain full')

    def _fsinfo_take(self, n):
        s = bytearray(self._sector(self.fsinfo))
        if struct.unpack_from('<I', s, 0)[0] != 0x41615252 or struct.unpack_from('<I', s, 484)[0] != 0x61417272:
            return
        free = struct.unpack_from('<I', s, 488)[0]
        if free != 0xFFFFFFFF:
            struct.pack_into('<I', s, 488, free - n)
        self._write_sector(self.fsinfo, bytes(s))


def fat_date(y, mo, d):
    return ((y - 1980) << 9) | (mo << 5) | d


def fat_time(h, mi, s):
    return (h << 11) | (mi << 5) | (s // 2)


def decode_date(wdate, wtime):
    return (f'{1980 + (wdate >> 9):04d}-{(wdate >> 5) & 15:02d}-{wdate & 31:02d} '
            f'{wtime >> 11:02d}:{(wtime >> 5) & 63:02d}:{(wtime & 31) * 2:02d}')


def listing(path):
    """Files on the card image: {path: {'size', 'sha256', 'date', 'long', 'data' (first 4 KiB)}}.  A card that holds no
    FAT32 volume is reported as {'<no FAT32 volume>': {'error': text}}."""
    out = {}
    try:
        with Volume(path) as v:
            for p, e in v.walk():
                if p.endswith('/'):
                    out[p] = {'dir': True, 'date': decode_date(e['wdate'], e['wtime']), 'long': e['long']}
                    continue
                data = v.read_chain(e['cluster'], e['size'])
                out[p] = {'size': e['size'], 'sha256': hashlib.sha256(data).hexdigest(),
                          'date': decode_date(e['wdate'], e['wtime']), 'long': e['long'], 'data': data[:4096]}
    except FatError as ex:
        out = {'<no FAT32 volume>': {'error': str(ex)}}
    return out
