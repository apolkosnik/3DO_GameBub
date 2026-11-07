#!/usr/bin/env python3
"""Convert a 2048-byte-sector ISO (e.g. a homebrew 3DO disc) to a raw CD
image for the disc-streaming firmware: a .bin of 2352-byte MODE1 sectors
and a .cue sheet for it.

Usage: iso2bin.py <image.iso> [output.bin]

The streaming firmware opens every disc file that is not a .cue as raw
2352-byte sectors, so it rejects an .iso ("not a raw image"). Stock
firmware loads the .iso itself (up to 22 MiB); this is only needed for the
streaming firmware.

Each sector gets what a pressed disc has: the sync pattern, the header
(the sector's MSF address and mode 1), the ISO's 2048 bytes, the EDC and
the P and Q ECC (ECMA-130). Track 1 index 1 is the first sector, at
00:02:00 (LBA 150).
"""
import os
import sys

USER = 2048
RAW = 2352
SYNC = b"\x00" + b"\xff" * 10 + b"\x00"
FIRST_LBA = 150

# GF(2^8) tables for the ECC (x^8 + x^4 + x^3 + x^2 + 1) and the EDC table
# (CRC with polynomial 0xD8018001, reflected).
ECC_F = [0] * 256
ECC_B = [0] * 256
EDC = [0] * 256
for _i in range(256):
    _j = ((_i << 1) ^ (0x11D if _i & 0x80 else 0)) & 0xFF
    ECC_F[_i] = _j
    ECC_B[_i ^ _j] = _i
    _e = _i
    for _ in range(8):
        _e = (_e >> 1) ^ (0xD8018001 if _e & 1 else 0)
    EDC[_i] = _e


def edc(data):
    e = 0
    for b in data:
        e = (e >> 8) ^ EDC[(e ^ b) & 0xFF]
    return e


def ecc_block(src, major_count, minor_count, major_mult, minor_inc):
    """P (86, 24, 2, 86) or Q (52, 43, 86, 88) parity of src (the sector
    from its header on)."""
    size = major_count * minor_count
    out = bytearray(2 * major_count)
    for major in range(major_count):
        index = (major >> 1) * major_mult + (major & 1)
        a = b = 0
        for _ in range(minor_count):
            t = src[index]
            index += minor_inc
            if index >= size:
                index -= size
            a ^= t
            b ^= t
            a = ECC_F[a]
        a = ECC_B[ECC_F[a] ^ b]
        out[major] = a
        out[major + major_count] = a ^ b
    return out


def bcd(v):
    return ((v // 10) << 4) | (v % 10)


def raw_sector(lba, data):
    """The raw MODE1 sector at absolute address lba with user data data."""
    assert len(data) == USER
    s = bytearray(RAW)
    s[0:12] = SYNC
    s[12:16] = bytes([bcd(lba // 4500), bcd(lba // 75 % 60), bcd(lba % 75), 1])
    s[16:2064] = data
    s[2064:2068] = edc(s[0:2064]).to_bytes(4, "little")
    # 2068..2075: zero
    s[2076:2248] = ecc_block(memoryview(s)[12:], 86, 24, 2, 86)
    s[2248:2352] = ecc_block(memoryview(s)[12:], 52, 43, 86, 88)
    return bytes(s)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0] + ".bin"
    cue = os.path.splitext(out)[0] + ".cue"
    if os.path.abspath(out) == os.path.abspath(src):
        sys.exit("output would overwrite the input")
    size = os.path.getsize(src)
    with open(src, "rb") as f:
        head = f.read(16)
    if head[:12] == SYNC:
        sys.exit(f"{src} already starts with a CD sync pattern: it is a raw image, use it as it is")
    if size == 0:
        sys.exit(f"{src} is empty")
    if size % USER:
        print(f"note: {size} bytes is not a whole number of 2048-byte sectors; "
              "the last sector is padded with zeros")
    sectors = (size + USER - 1) // USER
    with open(src, "rb") as f, open(out, "wb") as o:
        for n in range(sectors):
            o.write(raw_sector(FIRST_LBA + n, f.read(USER).ljust(USER, b"\0")))
            if n % 2000 == 1999:
                print(f"  {n + 1}/{sectors} sectors", end="\r", flush=True)
    with open(cue, "w", newline="\r\n") as c:
        c.write(f'FILE "{os.path.basename(out)}" BINARY\n'
                "  TRACK 01 MODE1/2352\n"
                "    INDEX 01 00:00:00\n")
    print(f"{out}: {sectors} sectors ({sectors * RAW} bytes)")
    print(f"{cue}: select this file on the disc-streaming firmware")


if __name__ == "__main__":
    main()
