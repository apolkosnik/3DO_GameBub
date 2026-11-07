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
