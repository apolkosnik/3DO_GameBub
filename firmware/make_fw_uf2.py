# Build a firmware UF2 with the fork's own Uf2Builder: the new app image
# (espflash save-image of the ELF, as generate_firmware_uf2.py does) and the
# system_data partition copied byte for byte from an existing release UF2, so
# the built-in cores stay exactly as flashed.
#
#   make_fw_uf2.py <firmware/handheld dir> <elf> <release.uf2> <out.uf2> <hw revision> <commit>
import importlib.util
import os
import struct
import subprocess
import sys
import tempfile

fwdir, elf, old_uf2, out, hw, commit = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("gen", os.path.join(fwdir, "generate_firmware_uf2.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

with open(os.path.join(fwdir, "partitions.csv")) as f:
    table = gen.PartitionTable(f)
app = table.find("factory")
data = table.find("system_data")


def parse(path):
    """Flash contents ({address: byte payload}), family and extension tags of a UF2."""
    blob = open(path, "rb").read()
    pages, family, tags = {}, set(), None
    for i in range(0, len(blob), 512):
        m0, m1, flags, addr, size, bno, nblk, fam = struct.unpack_from("<8I", blob, i)
        assert m0 == gen.Uf2Builder.MAGIC_START_0 and m1 == gen.Uf2Builder.MAGIC_START_1, "bad UF2 block"
        assert struct.unpack_from("<I", blob, i + 508)[0] == gen.Uf2Builder.MAGIC_END
        payload = blob[i + 32 : i + 32 + 476]
        pages[addr] = payload[:size]
        family.add(fam)
        if flags & 0x8000 and tags is None:
            tags, j = [], size
            while True:
                hdr = struct.unpack_from("<I", payload, j)[0]
                if hdr == 0:
                    break
                ln, tag = hdr & 0xFF, hdr >> 8
                tags.append((tag, bytes(payload[j + 4 : j + ln])))
                j += (ln + 3) & ~3
    return pages, family, tags


def extract(pages, start, length):
    """The partition's bytes, up to the last page the UF2 has in it."""
    inside = {a: p for a, p in pages.items() if start <= a < start + length}
    end = max(a + len(p) for a, p in inside.items()) - start
    buf = bytearray(end)
    for a, p in inside.items():
        buf[a - start : a - start + len(p)] = p
    return bytes(buf), len(inside)


old_pages, old_family, old_tags = parse(old_uf2)
outside = [a for a in old_pages if not (app.offset <= a < app.offset + app.size or data.offset <= a < data.offset + data.size)]
assert not outside, f"release UF2 writes outside app/system_data: {min(outside):#x}"
system_data, n_sys = extract(old_pages, data.offset, data.size)
old_app, _ = extract(old_pages, app.offset, app.size)
print(f"release UF2: family {[hex(f) for f in old_family]}, tags {[(hex(t), d) for t, d in old_tags]}")
print(f"release UF2: app {len(old_app)} bytes, system_data {len(system_data)} bytes ({n_sys} pages)")

tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".app.bin")
tmp.close()
subprocess.run(["espflash", "save-image", "--chip", "esp32s3", elf, tmp.name], check=True)
firmware = open(tmp.name, "rb").read()
os.unlink(tmp.name)
assert len(firmware) <= app.size, "firmware overflows partition"
print(f"new app image: {len(firmware)} bytes; image header old {old_app[:8].hex()} new {firmware[:8].hex()}")

bundle = gen.Uf2Builder()
bundle.family_id = gen.UF2_FAMILY_ESP32S3
bundle.add_extension_tag(gen.UF2_EXT_DEVICE_TYPE, b"bub!" + bytes([0, 0, int(hw), 1]))
bundle.add_extension_tag(gen.UF2_EXT_COMMIT, commit.encode())
bundle.add_flash_segment(app.offset, firmware)
bundle.add_flash_segment(data.offset, system_data)
with open(out, "wb") as f:
    f.write(bundle.build())

# Check the result: system data identical, app identical to the image, tags.
new_pages, new_family, new_tags = parse(out)
new_sys, _ = extract(new_pages, data.offset, data.size)
new_app, _ = extract(new_pages, app.offset, app.size)
assert new_sys[: len(system_data)] == system_data and not any(new_sys[len(system_data):]), "system data differs"
assert new_app[: len(firmware)] == firmware, "app differs"
assert new_family == old_family
assert [t for t, _ in new_tags] == [t for t, _ in old_tags], "tag types differ"
print(f"{out}: {os.path.getsize(out)} bytes; system data identical to the release; tags {[(hex(t), d) for t, d in new_tags]}")
