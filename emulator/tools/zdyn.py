"""Reference model of the meter's deflate packer (firmware/src/sys/zdef.s, READZ; DESIGN.md 10 IMP-63).

The firmware's packer must produce exactly these bytes for the same input (emulator/scripts/test_packed.py compares
them); zlib must decode them to the input.  One final block, BTYPE 2 (dynamic code) or 1 (fixed code), whichever is
shorter by the exact bit count; the caller sends the bytes themselves when neither is shorter than the input.

LZ77 as zlib's deflate_slow at level 9 (lazy 258, nice 258), with a match window of MAXD bytes (measured 2026-11-09
on a meter log file: distances up to 255 pack better than 4096, being cheaper to code):
  hash of the next 3 bytes (Fibonacci, 10 bits) -> head (position + 1, 0 = none); prev[pos mod 512] chains positions
  with the same hash; a match is looked for only when pos + 3 <= n; candidates are walked while the distance is at
  most MAXD and positions decrease (at most MAXD candidates, so zlib's chain limit 4096 and good length 32 never act
  and are left out); the longest match wins (ties: the first, nearest); lazy: a match is emitted only when the match
  at the next position is not longer.  head is cleared before each pass (pass 1 counts, pass 2 writes); prev needs no
  clearing (an entry is read only for a position less than MAXD back, which was written in this pass).
Huffman code lengths (JPEG ITU-T T.81 Annex K.2 code sizes, K.3 limitation to 15 bits, 7 for the code length code):
  every tree gets at least two used symbols (zlib's rule; a code length code of one symbol is refused by zlib's
  inflate): missing ones get the frequency 1, the lowest symbols first.  Lengths are given in the order of the code
  sizes (ties: lower symbol first).  Code lengths of the literal / length and distance codes are one sequence (RFC
  1951 allows repeats across), run-length coded: zeros by 17 / 18, other values once and then 16.
"""

MIN_MATCH, MAX_MATCH = 3, 258
LAZY, NICE = 258, 258
MAXD = 255                         # longest distance looked for
PREV = 512                         # chain entries (a power of two above MAXD)
HBITS = 10
CLORD = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15)
LBASE = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258)
LEXT = (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0)
DBASE = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
         6145, 8193, 12289, 16385, 24577)
DEXT = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13)


def hash3(d, p):
    return (((d[p] | d[p + 1] << 8 | d[p + 2] << 16) * 0x9E3779B1) & 0xFFFFFFFF) >> (32 - HBITS)


def parse(d):
    """The LZ77 tokens of d: ('lit', byte) or ('match', length, distance), in order."""
    n = len(d)
    head, prev = [0] * (1 << HBITS), [0] * PREV
    out = []

    def insert(p):
        h = hash3(d, p)
        old = head[h]
        prev[p & (PREV - 1)] = old
        head[h] = p + 1
        return old

    def longest(p, cand, prev_len):
        best, best_d = prev_len, 0
        limit = min(MAX_MATCH, n - p)
        c = cand - 1
        while True:
            dist = p - c
            if dist > MAXD:
                break
            if best < limit and d[c + best] == d[p + best]:
                k = 0
                while k < limit and d[c + k] == d[p + k]:
                    k += 1
                if k > best:
                    best, best_d = k, dist
                    if k >= NICE or k >= limit:
                        break
            nxt = prev[c & (PREV - 1)]
            if nxt == 0 or nxt - 1 >= c:
                break
            c = nxt - 1
        return (best, best_d) if best_d else (MIN_MATCH - 1, 0)

    prev_len, prev_d, avail, p = MIN_MATCH - 1, 0, False, 0
    while p < n:
        cur_len, cur_d = MIN_MATCH - 1, 0
        if p + MIN_MATCH <= n:
            cand = insert(p)
            if cand and prev_len < LAZY and p - (cand - 1) <= MAXD:
                cur_len, cur_d = longest(p, cand, prev_len)
        if prev_len >= MIN_MATCH and cur_len <= prev_len:
            out.append(('match', prev_len, prev_d))
            for q in range(p + 1, p - 1 + prev_len):
                if q + MIN_MATCH <= n:
                    insert(q)
            p += prev_len - 1
            avail, prev_len = False, MIN_MATCH - 1
            continue
        if avail:
            out.append(('lit', d[p - 1]))
        avail, prev_len, prev_d = True, cur_len, cur_d
        p += 1
    if avail:
        out.append(('lit', d[n - 1]))
    return out


def lcode(length):
    i = 28
    while LBASE[i] > length:
        i -= 1
    return i


def dcode(dist):
    i = 29
    while DBASE[i] > dist:
        i -= 1
    return i


def huff_lengths(freq, maxlen):
    """Code lengths of the symbols (JPEG K.2 code sizes, K.3 limited to maxlen; at least two used symbols)."""
    f = list(freq)
    used = [i for i, x in enumerate(f) if x]
    for i in range(len(f)):                     # at least two used symbols, the lowest unused ones added
        if len(used) >= 2:
            break
        if not f[i]:
            f[i] = 1
            used.append(i)
    n = len(f)
    size, others, ff = [0] * n, [-1] * n, list(f)
    while True:
        v1 = v2 = -1
        for i in range(n):                      # least frequency, ties: the highest index (as K.2)
            if ff[i] and (v1 < 0 or ff[i] <= ff[v1]):
                v1 = i
        for i in range(n):
            if i != v1 and ff[i] and (v2 < 0 or ff[i] <= ff[v2]):
                v2 = i
        if v2 < 0:
            break
        ff[v1] += ff[v2]
        ff[v2] = 0
        size[v1] += 1
        while others[v1] >= 0:
            v1 = others[v1]
            size[v1] += 1
        others[v1] = v2
        size[v2] += 1
        while others[v2] >= 0:
            v2 = others[v2]
            size[v2] += 1
    bits = [0] * 33
    for s in size:
        if s:
            bits[s] += 1
    i = 32
    while i > maxlen:                           # K.3
        if bits[i]:
            j = i - 2
            while not bits[j]:
                j -= 1
            bits[i] -= 2
            bits[i - 1] += 1
            bits[j + 1] += 2
            bits[j] -= 1
        else:
            i -= 1
    out = [0] * n
    queue = [L for L in range(1, maxlen + 1) for _ in range(bits[L])]
    k = 0
    for s in range(1, 33):                      # in the order of the code sizes, ties: the lower symbol
        for i in range(n):
            if size[i] == s:
                out[i] = queue[k]
                k += 1
    return out


def canonical(lengths):
    """RFC 1951 3.2.2 codes of the lengths."""
    bl = [0] * 16
    for L in lengths:
        if L:
            bl[L] += 1
    code, nxt = 0, [0] * 16
    bl[0] = 0
    for b in range(1, 16):
        code = (code + bl[b - 1]) << 1
        nxt[b] = code
    out = [0] * len(lengths)
    for i, L in enumerate(lengths):
        if L:
            out[i] = nxt[L]
            nxt[L] += 1
    return out


def rle(seq):
    """(symbol, extra value) of the code length sequence."""
    out, i = [], 0
    while i < len(seq):
        v, r = seq[i], 1
        while i + r < len(seq) and seq[i + r] == v:
            r += 1
        i += r
        if v == 0:
            while r >= 11:
                k = min(r, 138)
                out.append((18, k - 11))
                r -= k
            if r >= 3:
                out.append((17, r - 3))
                r = 0
            out += [(0, 0)] * r
        else:
            out.append((v, 0))
            r -= 1
            while r >= 3:
                k = min(r, 6)
                out.append((16, k - 3))
                r -= k
            out += [(v, 0)] * r
    return out


FIXED_L = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
FIXED_D = [5] * 30
REXT = {16: 2, 17: 3, 18: 7}


class Bits:
    def __init__(self):
        self.out, self.acc, self.n = bytearray(), 0, 0

    def put(self, v, n):
        self.acc |= v << self.n
        self.n += n
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def code(self, c, n):                       # Huffman codes go most significant bit first
        self.put(int('{:0{}b}'.format(c, n)[::-1], 2) if n else 0, n)

    def done(self):
        if self.n:
            self.out.append(self.acc & 0xFF)
        return bytes(self.out)


def compress(d):
    """(raw deflate bytes, 'dynamic' or 'fixed') of d (len >= 1)."""
    toks = parse(d)
    lf, df = [0] * 286, [0] * 30
    extra = 0
    for t in toks:
        if t[0] == 'lit':
            lf[t[1]] += 1
        else:
            c, e = lcode(t[1]), dcode(t[2])
            lf[257 + c] += 1
            df[e] += 1
            extra += LEXT[c] + DEXT[e]
    lf[256] += 1
    ll, dl = huff_lengths(lf, 15), huff_lengths(df, 15)
    hlit = max(257, max(i for i in range(286) if ll[i]) + 1)
    hdist = max(1, max([i for i in range(30) if dl[i]] or [0]) + 1)
    rl = rle(ll[:hlit] + dl[:hdist])
    cf = [0] * 19
    for s, _ in rl:
        cf[s] += 1
    cl = huff_lengths(cf, 7)
    hclen = max(4, max(i for i in range(19) if cl[CLORD[i]]) + 1)
    dyn = 3 + 5 + 5 + 4 + 3 * hclen + sum(cl[s] + REXT.get(s, 0) for s, _ in rl) + \
        sum(a * b for a, b in zip(lf, ll)) + sum(a * b for a, b in zip(df, dl)) + extra
    fix = 3 + sum(a * b for a, b in zip(lf, FIXED_L)) + sum(a * b for a, b in zip(df, FIXED_D)) + extra
    b = Bits()
    if dyn < fix:
        b.put(1, 1)
        b.put(2, 2)
        b.put(hlit - 257, 5)
        b.put(hdist - 1, 5)
        b.put(hclen - 4, 4)
        for i in range(hclen):
            b.put(cl[CLORD[i]], 3)
        cc = canonical(cl)
        for s, x in rl:
            b.code(cc[s], cl[s])
            if s in REXT:
                b.put(x, REXT[s])
        lens_l, lens_d, kind = ll, dl, 'dynamic'
    else:
        b.put(1, 1)
        b.put(1, 2)
        lens_l, lens_d, kind = FIXED_L, FIXED_D, 'fixed'
    lc, dc = canonical(lens_l), canonical(lens_d)
    for t in toks:
        if t[0] == 'lit':
            b.code(lc[t[1]], lens_l[t[1]])
        else:
            c, e = lcode(t[1]), dcode(t[2])
            b.code(lc[257 + c], lens_l[257 + c])
            b.put(t[1] - LBASE[c], LEXT[c])
            b.code(dc[e], lens_d[e])
            b.put(t[2] - DBASE[e], DEXT[e])
    b.code(lc[256], lens_l[256])
    out = b.done()
    assert len(out) * 8 - (dyn if kind == 'dynamic' else fix) in range(0, 8)
    return out, kind
