#!/usr/bin/env python3
"""Check catalog coverage and the BIOS identification/preparation tool."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("bios_tool", ROOT / "tools" / "bios.py")
bios = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bios)


class BiosCatalogTests(unittest.TestCase):
    def test_catalog_coverage(self):
        roms = bios.load_catalog()
        self.assertEqual(len(roms), 23)
        self.assertEqual(sum(r["kind"] == "bios" for r in roms), 19)
        self.assertEqual(sum(r["kind"] == "kanji" for r in roms), 2)
        self.assertEqual(sum(r["kind"] == "m2" for r in roms), 2)
        for field in ["filename", "md5", "crc32"]:
            self.assertEqual(len({r[field] for r in roms}), len(roms))
        for rom in roms:
            self.assertRegex(rom["md5"], r"^[0-9a-f]{32}$")
            self.assertRegex(rom["crc32"], r"^[0-9a-f]{8}$")
            if rom["kind"] == "bios":
                self.assertIn(rom["size"], [0x80000, 0x100000])

    def test_pal_detector_matches_catalog(self):
        roms = bios.load_catalog()
        expected = {r["sum_le"].upper() for r in roms if r["region"] == "PAL"}
        self.assertEqual(len(expected), 4)
        source = (ROOT / "rtl/gamebub/gb_host.sv").read_text()
        function = source.split("function automatic bit pal_sum", 1)[1].split("endfunction", 1)[0]
        self.assertEqual(set(re.findall(r"32'h([0-9A-F]{8})", function)), expected)

    def test_identification_checks_contents_and_size(self):
        data = bytes(range(256)) * 4
        entry = dict(filename="fixture.bin", kind="bios", region="NTSC", size=len(data),
                     crc32=f"{zlib.crc32(data):08x}", md5=hashlib.md5(data).hexdigest())
        self.assertEqual(bios.identify(data, [entry]), entry)
        self.assertIsNone(bios.identify(data[:-1], [entry]))
        altered = bytearray(data)
        altered[7] ^= 1
        self.assertIsNone(bios.identify(altered, [entry]))
        self.assertIsNone(bios.identify(data, [dict(entry, md5="0" * 32)]))

    def test_short_rom_mirrors_both_halves(self):
        data = bytes(range(256)) * 2048
        prepared = bios.prepare(data, {"kind": "bios"})
        self.assertEqual(len(prepared), 0x100000)
        self.assertEqual(prepared[:0x80000], data)
        self.assertEqual(prepared[0x80000:], data)
        self.assertEqual(bios.prepare(prepared, {"kind": "bios"}), prepared)

    def test_kanji_and_m2_are_separate(self):
        data = b"\xA5" * 0x100000
        self.assertEqual(bios.prepare(data, {"kind": "kanji"}), data)
        with self.assertRaisesRegex(ValueError, "M2"):
            bios.prepare(data, {"kind": "m2"})
        with self.assertRaisesRegex(ValueError, "512 KiB or 1 MiB"):
            bios.prepare(data[:1024], {"kind": "bios"})

    def test_prepared_short_rom_can_be_identified_again(self):
        data = bytes(range(256)) * 2048
        entry = dict(filename="arcade-fixture.bin", kind="bios", region="NTSC", size=len(data),
                     crc32=f"{zlib.crc32(data):08x}", md5=hashlib.md5(data).hexdigest())
        prepared = bios.prepare(data, entry)
        identified = bios.identify(prepared, [entry])
        self.assertEqual(identified, dict(entry, mirrored=True))
        self.assertEqual(bios.prepare(prepared, identified), prepared)
        changed = bytearray(prepared)
        changed[-1] ^= 1
        self.assertIsNone(bios.identify(changed, [entry]))

    def test_release_file_sizes(self):
        source = json.loads((ROOT / "metadata/files.json").read_text())
        release = json.loads((ROOT / "releases/apolkosnik.3DO/files.json").read_text())
        self.assertEqual(source, release)
        boot = next(f for f in source["files"] if f["id"] == 1)
        self.assertNotIn("exact_size", boot)
        self.assertEqual(int(boot["max_size"], 16), 0x100000)


if __name__ == "__main__":
    unittest.main()
