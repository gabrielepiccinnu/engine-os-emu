#!/usr/bin/env python3
"""
Parser and extractor for the "AZ01" container used by inMusic updates (Engine OS).

Usage:
    python az01-extract.py <file.img>                    list the partitions
    python az01-extract.py <file.img> <outdir>           extract everything
    python az01-extract.py <file.img> <outdir> rootfs    extract a single partition

The "rootfs" payload is xz compressed: after extraction,
    xz -dc 02_rootfs.bin > rootfs.img
yields a mountable ext4 filesystem.

Format (little-endian), reconstructed by reverse engineering:

    header      "AZ01" | u32 version | u32 header_size | string build_name
                | u32 n + n*string compatible | u32 n + n*u32 ids | string desc
    partition   "PART" | u32 header_size | u64 data_size | string name
                | string compression | u32 flags | string hash_algo | blob hash
                data at entry_offset + header_size
    trailer     "EOF\0" | u32 0x10 | 8 zero bytes

    string := u32 len, len bytes, 1 NUL byte, padding to a 4-byte boundary.
"""

import os
import struct
import sys


def align4(x):
    return (x + 3) & ~3


class Reader:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.size = os.path.getsize(path)

    def at(self, off, n):
        self.f.seek(off)
        return self.f.read(n)

    def u32(self, off):
        return struct.unpack("<I", self.at(off, 4))[0]

    def u64(self, off):
        return struct.unpack("<Q", self.at(off, 8))[0]

    def string(self, off):
        n = self.u32(off)
        return self.at(off + 4, n).decode("utf-8", "replace"), align4(off + 4 + n + 1)

    def blob(self, off):
        n = self.u32(off)
        return self.at(off + 4, n), off + 4 + n


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    path = sys.argv[1]
    outdir = sys.argv[2] if len(sys.argv) > 2 else None
    only = sys.argv[3] if len(sys.argv) > 3 else None
    r = Reader(path)

    if r.at(0, 4) != b"AZ01":
        print("Not an AZ01 container:", r.at(0, 4))
        return 1

    header_size = r.u32(8)
    print("magic AZ01  version %d  header_size %d" % (r.u32(4), header_size))

    off = 12
    name, off = r.string(off)
    print("build:      ", name)

    n = r.u32(off)
    off += 4
    machines = []
    for _ in range(n):
        s, off = r.string(off)
        machines.append(s)
    print("compatible: ", ", ".join(machines))

    n = r.u32(off)
    off += 4
    print("ids:        ", ", ".join(hex(r.u32(off + 4 * i)) for i in range(n)))
    off += 4 * n

    desc, off = r.string(off)
    print("description:", desc)
    print()

    off = header_size
    idx = 0
    while off < r.size - 16:
        # records can be separated by zero padding (up to 8 bytes)
        skipped = 0
        while r.at(off, 4) == b"\0\0\0\0" and skipped < 16:
            off += 4
            skipped += 4

        magic = r.at(off, 4)
        if magic == b"EOF\0":
            print("EOF trailer at", hex(off))
            break
        if magic != b"PART":
            print("unknown record at", hex(off), r.at(off, 16).hex())
            break

        ehdr = r.u32(off + 4)
        size = r.u64(off + 8)
        p = off + 16
        pname, p = r.string(p)
        comp, p = r.string(p)
        flags = r.u32(p)
        p += 4
        halgo, p = r.string(p)
        hval, p = r.blob(p)
        data_off = off + ehdr

        print(
            "[%d] %-16s %-5s flags=%d %12d B (%7.2f MiB) data@%#x  %s=%s"
            % (idx, pname, comp, flags, size, size / 1048576.0, data_off, halgo, hval.hex())
        )

        if outdir and (only is None or only == pname):
            os.makedirs(outdir, exist_ok=True)
            dst = os.path.join(outdir, "%02d_%s.bin" % (idx, pname))
            with open(dst, "wb") as out:
                r.f.seek(data_off)
                rem = size
                while rem:
                    chunk = r.f.read(min(1 << 22, rem))
                    out.write(chunk)
                    rem -= len(chunk)
            print("     -> %s" % dst)

        off = align4(data_off + size)
        idx += 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
