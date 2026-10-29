#!/usr/bin/env python3
"""Read Allwinner Android firmware images without vendor tools.

Handles the four layers of an Orange Pi / Allwinner Android .img:
  IMAGEWTY v3 container (unencrypted, PhoenixCard format)
  -> super.fex, an Android sparse image
  -> logical partitions (LP metadata: system_a, vendor_a, vendor_dlkm_a, ...)
  -> EROFS file systems (plain, inline and LZ4 with full or compacted indexes;
     not big pclusters, tail packing or fragments, which these images don't use)

usage:
  aw_android_image.py files IMG                     list the IMAGEWTY members
  aw_android_image.py extract IMG OUT [PART ...]    unpack PART (default vendor_a)
                                                    to OUT/PART/ as a directory tree
  aw_android_image.py ls EROFS_IMG                  list an EROFS image
"""
import os
import stat
import struct
import sys

# ---------------------------------------------------------------- IMAGEWTY


def imagewty_members(path):
    with open(path, "rb") as f:
        h = f.read(0x60)
        if h[:8] != b"IMAGEWTY":
            sys.exit(f"{path}: not an unencrypted IMAGEWTY image")
        n, = struct.unpack_from("<I", h, 0x3C)
        for i in range(n):
            f.seek(0x400 + i * 0x400)
            e = f.read(0x400)
            name = e[36:36 + 256].split(b"\0")[0].decode(errors="replace")
            _, _, length, _, off = struct.unpack_from("<IIIII", e, 36 + 256)
            yield os.path.basename(name.replace("\\", "/")), off, length

# ---------------------------------------------------------------- sparse


def unsparse(src, off, length, dst):
    """Android sparse image at src[off:off+length] -> dst (holes stay holes)."""
    with open(src, "rb") as f, open(dst, "wb") as o:
        f.seek(off)
        h = f.read(28)
        magic, _, _, fhs, chs, bs, blocks, chunks, _ = struct.unpack("<IHHHHIIII", h)
        if magic != 0xED26FF3A:
            sys.exit("super.fex is not a sparse image")
        f.seek(off + fhs)
        pos = 0
        for _ in range(chunks):
            ctype, _, nblk, total = struct.unpack("<HHII", f.read(12))
            f.seek(chs - 12, 1)
            size = nblk * bs
            if ctype == 0xCAC1:
                o.seek(pos)
                left = size
                while left:
                    b = f.read(min(left, 1 << 24))
                    o.write(b)
                    left -= len(b)
            elif ctype == 0xCAC2:
                fill = f.read(4)
                if fill != b"\0\0\0\0":
                    o.seek(pos)
                    o.write(fill * (size // 4))
            elif ctype == 0xCAC4:
                f.read(4)
            pos += size
        o.truncate(blocks * bs)

# ---------------------------------------------------------------- LP (super)


def lp_partitions(super_raw):
    with open(super_raw, "rb") as f:
        f.seek(4096 * 3)
        h = f.read(256)
        magic, _, _, hsize = struct.unpack_from("<IHHI", h)
        if magic != 0x414C5030:
            sys.exit("no LP metadata in super")
        tsize, = struct.unpack_from("<I", h, 44)
        p_off, p_n, p_sz, e_off, e_n, e_sz = struct.unpack_from("<6I", h, 80)
        f.seek(4096 * 3 + hsize)
        t = f.read(tsize)
    exts = [struct.unpack_from("<QIQI", t, e_off + i * e_sz) for i in range(e_n)]
    for i in range(p_n):
        b = t[p_off + i * p_sz:]
        name = b[:36].split(b"\0")[0].decode()
        _, first, n, _ = struct.unpack_from("<4I", b, 36)
        yield name, [(exts[first + k][2] * 512, exts[first + k][0] * 512) for k in range(n)]


def lp_extract(super_raw, extents, dst):
    with open(super_raw, "rb") as f, open(dst, "wb") as o:
        for off, size in extents:
            f.seek(off)
            while size:
                b = f.read(min(size, 1 << 24))
                o.write(b)
                size -= len(b)

# ---------------------------------------------------------------- EROFS


def lz4_block(src, i=0):
    out = bytearray()
    n = len(src)
    while i < n:
        tok = src[i]
        i += 1
        lit = tok >> 4
        if lit == 15:
            while True:
                b = src[i]
                i += 1
                lit += b
                if b != 255:
                    break
        out += src[i:i + lit]
        i += lit
        if i >= n:
            break
        dist = src[i] | src[i + 1] << 8
        i += 2
        ml = tok & 15
        if ml == 15:
            while True:
                b = src[i]
                i += 1
                ml += b
                if b != 255:
                    break
        ml += 4
        p = len(out) - dist
        if dist >= ml:
            out += out[p:p + ml]
        else:
            for k in range(ml):
                out.append(out[p + k])
    return bytes(out)


class Erofs:
    def __init__(self, path):
        self.f = open(path, "rb")
        sb = self.rd(1024, 128)
        magic, _, _, self.bits, _, self.root = struct.unpack_from("<IIIBBH", sb)
        self.meta, = struct.unpack_from("<I", sb, 40)
        if magic != 0xE0F5E1E2:
            sys.exit(f"{path}: not EROFS")
        self.bs = 1 << self.bits

    def rd(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def inode(self, nid):
        pos = self.meta * self.bs + nid * 32
        b = self.rd(pos, 64)
        fmt, xic, mode = struct.unpack_from("<HHH", b)
        if fmt & 1:
            size, = struct.unpack_from("<Q", b, 8)
            isz = 64
        else:
            size, = struct.unpack_from("<I", b, 8)
            isz = 32
        u, = struct.unpack_from("<I", b, 16)
        return dict(pos=pos, mode=mode, lay=(fmt >> 1) & 7, size=size, u=u,
                    tail=pos + isz + (0 if xic == 0 else 12 + (xic - 1) * 4))

    def data(self, ino):
        lay, size = ino["lay"], ino["size"]
        if lay == 0:
            return self.rd(ino["u"] * self.bs, size)
        if lay == 2:
            nfull = size // self.bs
            head = self.rd(ino["u"] * self.bs, nfull * self.bs) if nfull else b""
            return head + self.rd(ino["tail"], size - nfull * self.bs)
        if lay in (1, 3):
            return self.zdata(ino)
        raise NotImplementedError(f"data layout {lay}")

    def zdata(self, ino):
        hpos = (ino["tail"] + 7) & ~7
        _, _, advise, alg, cbits = struct.unpack_from("<HHHBB", self.rd(hpos, 8))
        if advise & ~0x11 or alg & 0xF:
            raise NotImplementedError(f"compression advise {advise:#x} alg {alg:#x}")
        lbits = self.bits + (cbits & 7)
        size = ino["size"]
        total = (size + (1 << lbits) - 1) >> lbits
        ebase = hpos + 8
        full = ino["lay"] == 1

        def load(lcn):
            """-> (type, clusterofs, delta0, pblk); type 2 = NONHEAD"""
            if full:
                adv, cofs, u = struct.unpack_from("<HHI", self.rd(ebase + lcn * 8, 8))
                if adv & 3 == 2:
                    return 2, 1 << lbits, u & 0xFFFF, None
                return adv & 3, cofs, 0, u
            init4 = ((32 - ebase % 32) // 4) & 7
            c2 = (total - init4) // 16 * 16 if advise & 1 and init4 < total else 0
            pos, shift, k = ebase, 2, lcn
            if k >= init4:
                pos += init4 * 4
                k -= init4
                if k < c2:
                    shift = 1
                else:
                    pos += c2 * 2
                    k -= c2
            pos += k << shift
            vcnt = 2 if shift == 2 else 16
            pack = vcnt << shift
            start = pos - (pos & (pack - 1))
            inb = self.rd(start, pack) + b"\0\0\0\0"
            lobits = max(lbits, 12)
            enc = (pack - 4) * 8 // vcnt
            i = (pos - start) >> shift

            def dec(j):
                bp = enc * j
                v = struct.unpack_from("<I", inb, bp // 8)[0] >> (bp & 7)
                return v & ((1 << lobits) - 1), (v >> lobits) & 3
            lo, t = dec(i)
            if t == 2:
                if i + 1 != vcnt:
                    return 2, 1 << lbits, lo, None
                lo2, t2 = dec(i - 1)
                return 2, 1 << lbits, (lo2 if t2 == 2 else 0) + 1, None
            nblk, j = 1, i
            while j > 0:
                j -= 1
                lo3, t3 = dec(j)
                if t3 == 2:
                    j -= lo3
                if j >= 0:
                    nblk += 1
            base, = struct.unpack_from("<I", inb, pack - 4)
            return t, lo, 0, base + nblk

        out = bytearray(size)
        cache = {}
        ofs = 0
        while ofs < size:
            lcn = ofs >> lbits
            t, cofs, d0, pblk = load(lcn)
            end = (lcn + 1) << lbits
            if t != 2 and ofs & ((1 << lbits) - 1) >= cofs:
                la = lcn << lbits | cofs
                head = t
            else:
                if t != 2:
                    end = lcn << lbits | cofs
                    d0 = 1
                while True:
                    lcn -= d0
                    t, cofs, d0, pblk = load(lcn)
                    if t != 2:
                        la, head = lcn << lbits | cofs, t
                        break
            end = min(end, size)
            if pblk not in cache:
                raw = self.rd(pblk * self.bs, self.bs)
                if head == 0:                      # stored uncompressed
                    if advise & 0x10:              # interlaced
                        r = la % self.bs
                        raw = raw[r:] + raw[:r]
                    cache[pblk] = raw
                else:                              # LZ4 with leading zero padding
                    z = len(raw) - len(raw.lstrip(b"\0"))
                    cache[pblk] = lz4_block(raw, z)
            seg = cache[pblk][:end - la]
            if la + len(seg) <= ofs:
                raise RuntimeError(f"no progress at offset {ofs}")
            out[la:la + len(seg)] = seg
            ofs = la + len(seg)
        return bytes(out)

    def walk(self, nid=None, path=""):
        ino = self.inode(self.root if nid is None else nid)
        yield path or "/", ino
        if not stat.S_ISDIR(ino["mode"]):
            return
        d = self.data(ino)
        for blk in range(0, len(d), self.bs):
            b = d[blk:blk + self.bs]
            if len(b) < 12:
                break
            n = struct.unpack_from("<H", b, 8)[0] // 12
            ents = [struct.unpack_from("<QH", b, k * 12) for k in range(n)]
            for k, (cn, no) in enumerate(ents):
                ne = ents[k + 1][1] if k + 1 < n else len(b)
                name = b[no:ne].split(b"\0")[0].decode(errors="replace")
                if name not in (".", ".."):
                    yield from self.walk(cn, f"{path}/{name}")

    def extract(self, out):
        for p, ino in self.walk():
            dst = os.path.join(out, p.lstrip("/"))
            if stat.S_ISDIR(ino["mode"]):
                os.makedirs(dst, exist_ok=True)
            elif stat.S_ISLNK(ino["mode"]):
                if os.path.lexists(dst):
                    os.remove(dst)
                os.symlink(self.data(ino).decode(), dst)
            elif stat.S_ISREG(ino["mode"]):
                with open(dst, "wb") as o:
                    o.write(self.data(ino))
                os.chmod(dst, ino["mode"] & 0o755 | 0o600)

# ---------------------------------------------------------------- main


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, img = sys.argv[1], sys.argv[2]
    if cmd == "files":
        for name, off, length in imagewty_members(img):
            print(f"{length:>12d} @{off:#012x} {name}")
    elif cmd == "ls":
        e = Erofs(img)
        for p, ino in e.walk():
            print("d" if stat.S_ISDIR(ino["mode"]) else "l" if stat.S_ISLNK(ino["mode"]) else "f",
                  ino["size"], p)
    elif cmd == "extract":
        out = sys.argv[3]
        parts = sys.argv[4:] or ["vendor_a"]
        os.makedirs(out, exist_ok=True)
        sup = next((m for m in imagewty_members(img) if m[0] == "super.fex"), None)
        if not sup:
            sys.exit("no super.fex in image")
        raw = os.path.join(out, "super.raw")
        unsparse(img, sup[1], sup[2], raw)
        try:
            found = dict(lp_partitions(raw))
            for part in parts:
                if not found.get(part):
                    sys.exit(f"{part}: not in super ({', '.join(k for k, v in found.items() if v)})")
                pimg = os.path.join(out, part + ".img")
                lp_extract(raw, found[part], pimg)
                Erofs(pimg).extract(os.path.join(out, part))
                os.remove(pimg)
                print(f"{part} -> {os.path.join(out, part)}")
        finally:
            os.remove(raw)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
