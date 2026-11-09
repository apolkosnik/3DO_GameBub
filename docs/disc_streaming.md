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
- **Sector reads.** `cdd_emu.sv` issues `DISC_READ` requests into a read-ahead ring of
  13 raw sectors in block RAM, mapped at host addresses `0x4000_0000`–`0x4000_7FFF`
  (slot s at `0x4000_0000 + 2352 s`). The transfer never touches the SDRAM, and the 3DO
  is not paused for it. The requests go one at a time, back to back: up to the end of
  the READ the drive controller sent, and while audio plays, as far ahead as the ring
  has room (13 sectors, 173 ms at 1x). A slow answer (an SD read, a file opened at a
  track boundary) then overlaps playback instead of delaying a sector. A READ of a sector
  that is not next in the ring (a seek) restarts the ring there; its first request goes
  out at once, so the firmware's latency overlaps the drive's seek time. With the
  default block length (2048 bytes), the core hands bytes 16–2063 (the MODE1 user data)
  to the controller, as MiSTer's HPS does. A failed or unanswered request (about 5 s
  timeout) reads as an empty sector.
- **CD-DA and raw sectors.** The 3DO has no analog CD audio path: its audio CD player
  reads CD-DA sectors through the drive's data port and plays them on the DSP. The drive
  commands this takes (`3DO_CDROM.sv`, as SataTo3DO's drive emulation implements them):
  - *Set Mode* `09 00 <density> <length hi> <length lo> <flags>` sets the block length.
    A block is taken from the raw 2352-byte sector: 2048 is the user data (bytes 16..),
    2352 the whole sector (CD-DA: 588 stereo samples, 16-bit little-endian), a shorter
    length the end of the sector (2340: bytes 12..). Flags bits 7–6 select 2353 (`10`,
    CD-DA and an error-flag byte), 2448 (`01`, CD-DA and subcode) or 2449 (`11`), whose
    extra bytes read as zeros. A drive reset restores 2048.
  - *Set Mode* `09 03 <speed>`: bit 7 of the speed byte is double speed (status bit 1).
  - *Read Sub-Q* `87`: `87 ctrl track index 00 absM absS absF relM relS relF status`, in
    binary, for the last sector read (ctrl `04` data, `00` audio; index 0 in a pregap,
    where the relative time counts down to index 1).
  - *Abort* `08` and *Flush* `0B` (7 bytes, like the other commands) stop a read and
    answer `08`/`0B` and the status.

  Each sector's track and audio flag come from the TOC. Audio sectors arrive at the
  drive's real rate, 75 per second (150 at double speed, exactly 50 MHz / 75 with the
  fraction spread over three sectors), as a real drive streams them: a sector clock
  runs at that rate and each audio sector takes one of its ticks. The player reads 8
  blocks per READ. A READ of the sector after the last one keeps the clock, so neither
  the time between two READs nor the 3DO's time to read a block slows playback down.
  Up to 8 ticks are kept, like a drive's read-ahead, so a sector the firmware sends late
  is made up by the next ones. A READ elsewhere (a seek) restarts the clock: its first
  sector comes one sector time later, or, if later, when it has arrived: the clock
  waits for it. Data sectors keep the CD speed setting. A preloaded ISO has no audio.
  In a longer block it gives its 2048 bytes and then zeros.
- **Disc-info block.** Built from the TOC: tracks, audio flags, and lead-out converted
  from BCD to binary MSF, as the MiSTer core expects.
- **Disc swap.** A TOC arriving while the core runs resends the disc-info block, which
  the controller reports as a media change.

With the fork's firmware, use `.cue`/`.bin`. That firmware opens any disc file that is
not a `.cue` as raw 2352-byte sectors (`DiscImage::open` in `disc.rs`): an `.iso` whose
size is not a multiple of 2352 is refused ("not a raw image"), and one whose size happens
to be would be read as garbage. `files.json` still lists `iso` for stock firmware, which
preloads it. `tools/iso2bin.py image.iso` converts an ISO into `image.bin` (MODE1/2352:
sync, header, data, EDC, P/Q ECC) and `image.cue` for the fork's firmware.

## Verification

- `sim/run_tb.sh tb_top +stream`: a model of the fork firmware serves `DISC_READ`
  requests for a disc with a data track and an audio track. The test BIOS's CD tests run
  through it:
  - read capacity and a two-sector read (test 7);
  - disc info and TOC (test 14);
  - two 2352-byte CD-DA blocks, then a third through a new READ that continues the
    stream, a raw data sector, and two 2448-byte CD-DA blocks at double speed;
  - Read Sub-Q on both tracks, then Abort and Flush.

  Every byte the CPU reads and every status is checked. So is the spacing of CD-DA
  sectors: one sector time at 1x and at 2x, to within 15 ns, also across the READ
  that continues the stream. The firmware model answers the request for that READ's
  sector 20 ms late (`+disc_spike_us`), and the sector still comes on time from the
  read-ahead. Every request must go to a slot of the ring.
- `tb_boot +disc_bin=<image.bin>`: boots a real BIOS while streaming a real disc image.
  The real Wolfenstein 3D image (133 MB) streams through the same path.
  `+audio_tracks=<n> [+data_sectors=<k>]` describes the image as a data track of k sectors
  (none with k = 0) followed by n audio tracks. The log shows every command the BIOS sends
  to the drive controller and the status it reads back. Every block is checked against
  the image at its block length, both as sent to the controller and as the CPU reads it.
  The spacing of audio sectors is reported.
