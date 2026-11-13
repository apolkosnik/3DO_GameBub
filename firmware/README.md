# Disc-streaming firmware with ISO support

The release zip contains `gamebub-handheld-rev4-1.1.0-beta3-iso2048.uf2`. This is the
disc-streaming firmware from the
[neutralinsomniac/gamebub](https://github.com/neutralinsomniac/gamebub) fork (branch `psx`,
commit `0a9e2746`, release 0.1.3, the firmware its PlayStation and SNES cores use) with one
change, [0001-disc-images-2048-byte-sector-isos.patch](0001-disc-images-2048-byte-sector-isos.patch).

That firmware opens every disc file except a `.cue` as raw 2352-byte CD sectors. It
therefore refuses an `.iso` of 2048-byte sectors ("not a raw image"), and that is how most
3DO images come. With the patch (`firmware/handheld/src/core/disc.rs`):

* A disc file other than a `.bin` is read as 2048-byte sectors, unless it starts with the CD
  sync pattern. A raw image named `.iso` is still read as raw. A `.bin` is raw, as before.
* A cue sheet's `MODE1/2048` track is read the same way.
* Each sector is returned raw, as a pressed disc has it. The firmware adds the sync pattern,
  the header (the MSF address and mode 1), the EDC and the P and Q ECC (ECMA-130) around
  the 2048 bytes.

The patch was tested on a PC with `disc.rs` unchanged. Every one of the 56,702 sectors of a
raw Wolfenstein 3D dump, rebuilt from its 2048-byte user data, is byte-identical to the dump.
On a Game Bub, Cannon Fodder runs from its `.iso`.

## CHD images

The handheld firmware of the fork's `mouse-3do` branch (from commit `f73f129a`) also opens
`.chd` files: MAME's CHD version 5, as `chdman createcd` makes them
(`firmware/handheld/src/core/chd.rs`, with MAME's `chd.cpp`, `chdcodec.cpp`, `huffman.cpp`
and `cdrom.cpp` as the reference).

* **Codecs:** the CD codecs `cdlz` (LZMA), `cdzl` (deflate) and `cdfl` (FLAC), chdman's
  default for CDs, the generic `lzma` and `zlib`, and uncompressed CHDs
  (`firmware/handheld/src/core/chd_codec.rs`: deflate after zlib's `puff.c`, LZMA after the
  LZMA SDK's `LzmaSpec.cpp`, FLAC after the format specification). Sectors whose sync
  pattern and ECC chdman dropped get them back. Every hunk's CRC is checked.
* **Tracks:** from the `CHT2` (or `CHTR`) metadata. A pregap stored in the CHD (`PGTYPE:V...`,
  from a cue sheet's `INDEX 00`) is read from it. Otherwise the pregap and any postgap read
  as silence, as in MAME's `cdrom_file`. A `MODE1` track (made from an ISO) holds 2048 bytes
  per sector, which get their raw sector built around them as for an `.iso`. CD-DA samples
  are big-endian in a CHD and are swapped back. Track 1 starts at LBA 150, as for the other
  formats.
* **Memory:** the handheld has no PSRAM, so the hunk map is not decoded into RAM (12 bytes per
  hunk, about 500 KiB for a full CD). The compressed map stays in the file. When the CHD is
  opened, the map is decoded once to check its CRC and to keep the decoder's state every 128
  hunks (24 bytes each, about 10 KiB for a full CD). A hunk's map entry is then decoded from
  the checkpoint before it. One decompressed hunk (8 sectors, 18.8 KiB) is kept, because the
  core mostly reads in order.
* **No allocation while the core runs:** with a core running, the heap is fragmented: a
  first version, built on general-purpose decoder crates, crashed the handheld at the 3DO
  logo when the LZMA decoder asked for 32 KiB with 40 KB free in blocks of at most 7.5 KB.
  Everything a CHD needs is now allocated when it is opened. The decoders write straight
  into the hunk (which is also the LZ window) and keep their tables on the stack or in the
  disc-read scratch buffer, which also holds the sector, its read-back and the compressed
  hunk (62.7 of its 64 KiB). zstd is refused because a zstd decoder needs more than that.
* **Refused:** CHD versions before 5 (convert them with a newer chdman), zstd compression
  (`cdzs`, `zstd`: recreate the CHD with chdman's default codecs), CHDs that need a parent,
  GD-ROM images, hunks of more than 8 frames, and track types other than `MODE1`,
  `MODE1_RAW`, `MODE2_RAW` and `AUDIO`.

Tested on a PC with the firmware's `chd.rs` and `disc.rs`. Each CHD made by chdman 0.288 reads
as the CUE/BIN or ISO it was made from, compared sector by sector: every sector in order plus
4,000 in a scrambled order, and the TOC words the core gets. The test also counts the heap
allocations made by the CHD's reads, which must be none, and its work buffer is misaligned
on purpose. The test CHDs:

* Killing Time and Microcosm (one raw data track; Killing Time with the default codecs,
  `cdzl` and `lzma,zlib`).
* A homebrew `.iso` (a `MODE1` track; the default codecs, uncompressed, `lzma,zlib` and
  `cdzl`).
* A made-up disc with a data track and two audio tracks: one with a `PREGAP`, one with an
  `INDEX 00`, track lengths not a multiple of 4. It was tested with the default codecs,
  uncompressed, `lzma,zlib`, `cdzl`, `cdlz`, `cdfl,cdzl` and `cdfl,cdlz`.

A corrupted CHD reads as errors, not as wrong data, and must not crash the handheld: copies
of the made-up disc's CHD (default codecs, `lzma,zlib` and `cdzl,cdfl`) with one to eight
random bits flipped past the header, 300 copies of each plus 2,000 more of the default one,
were read whole without a panic.

## Building

1. Check out the fork at `0a9e2746` and apply the patch (`git am`).
2. Install the ESP32-S3 Rust toolchain (`espup install --targets esp32s3`), plus `ldproxy`
   and `espflash`.
3. Build the firmware. In `firmware/handheld`, run `. ~/export-esp.sh`, then
   `cargo build --release --features=rev4`. ESP-IDF v5.4.3 is downloaded on the first build.

The fork's own `generate_firmware_uf2.py` also builds the system data partition, which holds
the built-in Game Boy and GBA cores and free BIOS replacements. That needs those bitstreams.
`make_fw_uf2.py` instead puts the new app image together with the system data partition
copied byte for byte from the fork's 0.1.3 release UF2:

```
cd firmware/handheld
python3 make_fw_uf2.py . target/xtensa-esp32s3-espidf/release/handheld \
    gamebub-handheld-rev4-1.1.0-beta3.uf2 out.uf2 4 $(git rev-parse HEAD)
```

Run it from `firmware/handheld` of the fork, because `espflash` reads the flash settings
there (8 MB, 80 MHz). It uses the fork's `Uf2Builder` and partition table, and checks its
own output.
