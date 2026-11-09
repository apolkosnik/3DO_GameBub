#!/usr/bin/env python3
"""Identify cataloged 3DO ROMs and prepare BIOS/Kanji files for Game Bub."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zlib


CATALOG = Path(__file__).resolve().parents[1] / "metadata" / "bios_catalog.json"


def load_catalog(path=CATALOG):
    return json.loads(Path(path).read_text())["roms"]


def identify(data, catalog):
    crc = f"{zlib.crc32(data):08x}"
    candidates = [rom for rom in catalog
                  if rom["size"] == len(data) and rom["crc32"] == crc]
    if candidates:
        md5 = hashlib.md5(data).hexdigest()
        match = next((rom for rom in candidates if rom["md5"] == md5), None)
        if match is not None:
            return match
    # Also identify a 512 KiB boot ROM prepared as two identical halves.
    if len(data) == 0x100000 and data[:0x80000] == data[0x80000:]:
        match = identify(data[:0x80000], [rom for rom in catalog if rom["kind"] == "bios"])
        if match is not None:
            return dict(match, mirrored=True)
    return None


def prepare(data, rom):
    if rom["kind"] == "m2":
        raise ValueError("M2 firmware requires different hardware and cannot run on this 3DO core")
    if rom["kind"] == "kanji":
        if len(data) != 0x100000:
            raise ValueError("Kanji ROM must be 1 MiB")
        return data
    if rom["kind"] != "bios":
        raise ValueError("Not a boot or Kanji ROM")
    if len(data) == 0x80000:
        return data * 2
    if len(data) == 0x100000:
        return data
    raise ValueError("Boot ROM must be 512 KiB or 1 MiB")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", type=Path, nargs="*", help="ROM files to identify")
    parser.add_argument("--list", action="store_true", help="list every catalog entry")
    parser.add_argument("--output", type=Path,
                        help="prepare one identified image as bios.bin or kanji.rom; mirrors 512 KiB BIOSes")
    args = parser.parse_args(argv)
    if args.output and len(args.images) != 1:
        parser.error("--output requires exactly one input image")
    if not args.images and not args.list:
        parser.error("provide an image or --list")
    catalog = load_catalog()
    if args.list:
        for rom in catalog:
            mode = ("unsupported M2" if rom["kind"] == "m2" else
                    "Kanji font" if rom["kind"] == "kanji" else
                    rom["region"] or "region unverified; NTSC default")
            print(f"{rom['filename']}: {mode}, {rom['size']} bytes")
    failures = 0
    for path in args.images:
        try:
            data = path.read_bytes()
            rom = identify(data, catalog)
            if rom is None:
                raise ValueError("size, CRC32 and MD5 do not match a catalog entry")
            mode = ("unsupported M2" if rom["kind"] == "m2" else
                    "Kanji font" if rom["kind"] == "kanji" else
                    rom["region"] or "region unverified; NTSC default")
            hashes = "source hashes match; mirrored 512 KiB image" if rom.get("mirrored") else "hashes match"
            print(f"{path}: {rom['filename']} ({mode}, {len(data)} bytes; {hashes})")
            if args.output:
                output = prepare(data, rom)
                args.output.write_bytes(output)
                print(f"Prepared {args.output} ({len(output)} bytes)")
        except (OSError, ValueError) as exc:
            print(f"{path}: {exc}", file=sys.stderr)
            failures += 1
    return int(failures != 0)


if __name__ == "__main__":
    raise SystemExit(main())
