#!/usr/bin/env python3
"""Convert a 3DO CUE/BIN (MODE1/2352 or MODE1/2048 data track) to a
2048-byte-sector ISO for the Game Bub 3DO core, and report whether it fits.

Usage: cue2iso.py <image.cue> [output.iso]

The Game Bub framework loads the whole disc into SDRAM when the core
starts, so images larger than 22 MiB (11264 sectors) cannot be used.
"""
import os
import sys

ISO_MAX_BYTES = (8192 + 7168 + 7168) * 1024


def parse_cue(path):
    base = os.path.dirname(os.path.abspath(path))
    tracks = []
    fname = None
    for line in open(path, encoding="latin-1"):
        tok = line.strip().split()
        if not tok:
            continue
        if tok[0] == "FILE":
            q = line.split('"')
            fname = os.path.join(base, q[1] if len(q) >= 3 else tok[1])
        elif tok[0] == "TRACK":
            tracks.append((fname, int(tok[1]), tok[2]))
    return tracks


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cue = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(cue)[0] + ".iso"
    tracks = parse_cue(cue)
    if not tracks:
        sys.exit("no tracks in cue sheet")
    fname, num, mode = tracks[0]
    if mode not in ("MODE1/2352", "MODE1/2048"):
        sys.exit(f"track 1 is {mode}; only MODE1 data tracks are supported")
    if len(tracks) > 1:
        print(f"note: {len(tracks) - 1} additional track(s) (CD audio) are dropped")
    ssize = 2352 if mode == "MODE1/2352" else 2048
    size = os.path.getsize(fname)
    sectors = size // ssize
    iso_bytes = sectors * 2048
    with open(fname, "rb") as f:
        first = f.read(ssize)
    data0 = first[16:16 + 2048] if ssize == 2352 else first[:2048]
    if data0[0:7] != b"\x01\x5a\x5a\x5a\x5a\x5a\x01":
        print("warning: sector 0 does not start with an Opera volume header")
    label = data0[0x28:0x48].split(b"\0")[0].decode("latin-1", "replace")
    print(f"{fname}: {sectors} sectors, volume '{label}', ISO size {iso_bytes} bytes")
    if iso_bytes > ISO_MAX_BYTES:
        print(f"does NOT fit: the core holds at most {ISO_MAX_BYTES} bytes ({ISO_MAX_BYTES // 2048} sectors)")
        sys.exit(2)
    with open(fname, "rb") as f, open(out, "wb") as o:
        for _ in range(sectors):
            s = f.read(ssize)
            o.write(s[16:16 + 2048] if ssize == 2352 else s)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
