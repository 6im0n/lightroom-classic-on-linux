#!/usr/bin/env python3
"""pe_realign.py IN OUT — rewrite a PE32+ image with FileAlignment = 0x1000.

Wine can only mmap a PE section straight from the file (shared page cache)
when its raw data sits at a page-aligned file offset. With the usual 0x200
file alignment wine copies the whole image into private memory instead, so
every process that loads the DLL pays its full size in RAM. For Edge
WebView2's 314 MB msedge.dll that is ~300 MB per process (~3 GB for the
Creative Cloud installer); realigned, each process keeps ~26 MB private.

Moves each section's raw data to a page-aligned offset, pads it to a page
multiple, fixes the debug-directory file offsets, and drops the Authenticode
certificate (its offset is no longer valid; wine never checks it).
Already-aligned images are copied unchanged. IN and OUT may be the same file.
"""
import struct
import sys

PAGE = 0x1000


def align(v, a=PAGE):
    return (v + a - 1) & ~(a - 1)


def main(src, dst):
    data = open(src, "rb").read()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise SystemExit(f"{src}: not a PE file")
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    optsz = struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    if struct.unpack_from("<H", data, opt)[0] != 0x20B:
        raise SystemExit(f"{src}: PE32+ only")
    if struct.unpack_from("<I", data, opt + 36)[0] >= PAGE:
        print(f"{src}: already page-aligned")
        if src != dst:
            open(dst, "wb").write(data)
        return
    sec_tab = opt + optsz

    secs = []
    for i in range(nsec):
        off = sec_tab + 40 * i
        vsize, va, rsize, rptr = struct.unpack_from("<IIII", data, off + 8)
        secs.append(dict(off=off, va=va, rsize=rsize, rptr=rptr))

    hdr_size = align(struct.unpack_from("<I", data, opt + 60)[0])
    out = bytearray(data[:hdr_size])
    out += bytes(hdr_size - len(out))

    pos = hdr_size
    for s in secs:
        if s["rsize"] == 0:
            s["new_rptr"], s["new_rsize"] = 0, 0
            continue
        raw = data[s["rptr"]:s["rptr"] + s["rsize"]]
        s["new_rptr"] = pos
        s["new_rsize"] = align(len(raw))
        out += raw + bytes(s["new_rsize"] - len(raw))
        pos += s["new_rsize"]

    def remap(fileoff):
        for s in secs:
            if s["rsize"] and s["rptr"] <= fileoff < s["rptr"] + s["rsize"]:
                return fileoff - s["rptr"] + s["new_rptr"]
        return fileoff

    for s in secs:
        struct.pack_into("<II", out, s["off"] + 16, s["new_rsize"], s["new_rptr"])

    struct.pack_into("<I", out, opt + 36, PAGE)       # FileAlignment
    struct.pack_into("<I", out, opt + 60, hdr_size)   # SizeOfHeaders
    struct.pack_into("<I", out, opt + 64, 0)          # CheckSum

    ndirs = struct.unpack_from("<I", out, opt + 108)[0]
    dirs = opt + 112
    if ndirs > 4:                                     # security dir: a file offset
        struct.pack_into("<II", out, dirs + 8 * 4, 0, 0)
    if ndirs > 6:                                     # debug entries hold file offsets
        dva, dsz = struct.unpack_from("<II", out, dirs + 8 * 6)
        for s in secs:
            if s["rsize"] and s["va"] <= dva < s["va"] + s["rsize"]:
                base = s["new_rptr"] + (dva - s["va"])
                for e in range(dsz // 28):
                    p = base + 28 * e + 24
                    old = struct.unpack_from("<I", out, p)[0]
                    if old:
                        struct.pack_into("<I", out, p, remap(old))
                break

    open(dst, "wb").write(out)
    print(f"{src}: {len(data)} -> {len(out)} bytes, {nsec} sections page-aligned")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: pe_realign.py IN OUT")
    main(sys.argv[1], sys.argv[2])
