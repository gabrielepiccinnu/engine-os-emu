#!/usr/bin/env python3
"""Converts a QEMU monitor PPM screendump to PNG (no dependencies)."""
import zlib, struct, sys
d = open(sys.argv[1],'rb').read()
assert d[:2] == b'P6', d[:2]
# header: P6 whitespace W whitespace H whitespace MAX whitespace
i = 2; vals = []
while len(vals) < 3:
    while d[i:i+1].isspace(): i += 1
    if d[i:i+1] == b'#':
        while d[i:i+1] != b'\n': i += 1
        continue
    j = i
    while not d[j:j+1].isspace(): j += 1
    vals.append(int(d[i:j])); i = j
i += 1
W, H, MAX = vals
px = d[i:i+W*H*3]
print("PPM %dx%d max=%d, %d pixel bytes" % (W, H, MAX, len(px)))
rows = bytearray()
for y in range(H):
    rows.append(0); rows += px[y*W*3:(y+1)*W*3]
def chunk(t, b):
    c = t+b; return struct.pack('>I', len(b)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
with open(sys.argv[2],'wb') as f:
    f.write(b'\x89PNG\r\n\x1a\n')
    f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)))
    f.write(chunk(b'IDAT', zlib.compress(bytes(rows), 6)))
    f.write(chunk(b'IEND', b''))
print("wrote", sys.argv[2])
