#!/usr/bin/env python3
"""
Converts a splash/recoverysplash partition to PNG.

Usage:
    python splash2png.py 00_splash.bin splash.png

The payload is a raw 32 bpp BGRA framebuffer, 800x1280 (the MIPI panel is
mounted in portrait). It gets rotated 90 degrees to 1280x800 and the B/R
channels swapped. No external dependencies: the PNG is written by hand
with zlib.
"""

import struct
import sys
import zlib

SRC_W, SRC_H = 800, 1280
DST_W, DST_H = SRC_H, SRC_W


def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def convert(src_path, dst_path):
    raw = open(src_path, "rb").read()
    expected = SRC_W * SRC_H * 4
    if len(raw) != expected:
        raise SystemExit("unexpected size: %d bytes (expected %d)" % (len(raw), expected))

    mv = memoryview(raw)
    out = bytearray()
    for y in range(DST_H):
        out.append(0)  # PNG filter "None"
        sx = SRC_W - 1 - y
        row = bytearray()
        for x in range(DST_W):
            o = (x * SRC_W + sx) * 4
            row += bytes((mv[o + 2], mv[o + 1], mv[o], mv[o + 3]))  # BGRA -> RGBA
        out += row

    with open(dst_path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", DST_W, DST_H, 8, 6, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(out), 6)))
        f.write(chunk(b"IEND", b""))
    print("wrote %s (%dx%d)" % (dst_path, DST_W, DST_H))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
