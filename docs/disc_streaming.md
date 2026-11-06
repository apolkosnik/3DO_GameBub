# Disc streaming

On stock Game Bub firmware, cores get their files loaded into memory at startup, which
limits the 3DO core to discs of up to 22 MiB. Commercial 3DO discs are 100–650 MB.

The PlayStation port in the [`neutralinsomniac/gamebub`](https://github.com/neutralinsomniac/gamebub/blob/psx/docs/psx.md)
fork (branch `psx`) added on-demand disc reads to the Game Bub firmware. This core
uses the same protocol, so **one firmware build serves both cores**.

## Firmware and framework support

- **Stock firmware (`v1.1-beta`):** a core can send requests to the MCU, but they are
  never answered. The framework's core→MCU channel exists (`commandCore`, interrupt bit
  4, parameters at `0xF000_1000`). The firmware declares its registers but never enables
  the interrupt or reads the parameters (`firmware/handheld/src/device/drivers/fpga/mod.rs`,
  `worker/mod.rs`).
- **The fork's firmware** answers them. A file marked `"disc": true` in `files.json` is
  opened as a CD image (`.cue` with its `.bin` files, or a lone `.bin` of raw 2352-byte
  sectors). The core then reads sectors on request (`firmware/handheld/src/core/disc.rs`,
  `CoreManager::handle_core_request` in `core/mod.rs`).

## Protocol (as implemented by the fork firmware)

**Loading a disc.** The firmware sends `FileWriteStart`, writes the disc's **table of
contents** to the file's address, then sends `FileWriteEnd` with the TOC's length.
Little-endian 32-bit words:

| Word | Content |
|---|---|
| 0 | number of tracks (bits 7-0), the same in BCD (bits 15-8) |
| 1 | lead-out LBA |
| 2 | lead-out position, BCD `0x00MMSSFF` |
| 3 | 0 |
| 4 + 4n | track n+1: first LBA (its pregap, if any) |
| 5 + 4n | last LBA |
| 6 + 4n | index 1 LBA |
| 7 + 4n | index 1 position, BCD `0x00MMSSFF`; bit 31: audio track |

LBAs are absolute: track 1 starts at 150 (00:02:00).

**Reading a sector.** The core writes `DISC_READ` (`0x0400`), the file id, an absolute
LBA and a destination address to its request words at `0xF000_1000`, then raises
`commandCore.request`. The firmware reads the raw 2352-byte sector (sectors outside the
image read as zeros) and writes it to the destination as little-endian words, at the
file's `max_transfer_speed`. It then answers `done` (or `error`) in `0xF100_1104`. The
core drops `request`, and the firmware clears the answer.

**Changing discs.** From the pause menu, the firmware sends the new disc's TOC while the
core runs.

## In this core

- `files.json`: the disc file has `"disc": true` and extensions `cue`, `bin`, `iso`.
- **Mode.** `gb_host.sv` tells the two modes apart by the file's length. Under 2 KiB is
  a TOC (streaming); anything else is an ISO image loaded into SDRAM (stock firmware, at
  most 22 MiB). A TOC is only used if its track count is 1–99 and matches its BCD copy,
  because stock firmware would deliver a `.cue` as plain text.
- **Sector reads.** `cdd_emu.sv` issues `DISC_READ` for the sector the 3DO's drive
  controller asks for. The destination is a block-RAM sector buffer mapped at host address
  `0x4000_0000`, so the transfer never touches the SDRAM and the 3DO is not paused for it.
  The core hands bytes 16–2063 (the MODE1 user data) to the controller, as MiSTer's HPS
  does. The request goes out when the drive's sector time starts, so the firmware's
  latency overlaps it. A failed or unanswered request (about 5 s timeout) reads as an
  empty sector.
- **Disc-info block.** Built from the TOC: tracks, audio flags, and lead-out converted
  from BCD to binary MSF, as the MiSTer core expects.
- **Disc swap.** A TOC arriving while the core runs resends the disc-info block, which
  the controller reports as a media change.

With the fork's firmware, use `.cue`/`.bin`. That firmware would read an `.iso` as raw
sectors, so `.iso` images only work through the preload path, on stock firmware.

## Verification

- `sim/run_tb.sh tb_top +stream`: a model of the fork firmware serves `DISC_READ`
  requests, and the test BIOS's CD test (read capacity, two-sector read) runs through it.
- `tb_boot +disc_bin=<image.bin>`: boots a real BIOS while streaming a real disc image.
  The real Wolfenstein 3D image (133 MB) streams through the same path.
