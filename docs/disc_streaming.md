# Disc streaming

Game Bub firmware loads a core's files into memory at startup, which would limit the 3DO
core to discs of up to 22 MiB; commercial 3DO discs are 100-650 MB. Since framework and
firmware `v1.1.0-beta4`, a file marked `"on_demand": true` in `files.json` is not loaded:
the core reads it itself, at any offset, through core -> host requests. The disc is such
a file, so the core reads only the sectors the game asks for.

## Firmware

- **Stock firmware (`v1.1.0-beta4` or later):** a single-file image, an `.iso`
  (2048-byte sectors) or a raw `.bin` (2352-byte sectors, one data track), of any size.
  Stock firmware does not read `.cue` or `.chd` files: picked there, the core finds
  neither a raw image nor an ISO in it and starts without a disc (the BIOS's screen).
- **The fork's firmware** (`firmware/`) also reads `.cue` (with its `.bin` files, data
  and CD-DA tracks) and `.chd`. It serves any disc file as one raw image of 2352-byte
  sectors, track 1 at its start, and answers the core's DiscGetToc with the table of
  contents.

Firmware before `v1.1.0-beta4` cannot run this core: its input registers and requests
differ (the core is built on the `v1.1.0-beta4` framework).

## Protocol

Requests use the HostV0 core -> host channel (the framework's `commandCore`): the core
puts the opcode and up to five 32-bit parameters at `0xF000_1000`, raises `request`, and
waits for `done`; the host writes its result words (status first, 0 = OK) back to
`0xF000_1000` before `done`, and an error raises `error` with `done`. The core drops
`request`, and the host clears its answer.

| Request | Opcode | Parameters | Results |
|---|---|---|---|
| FileGetSize | `0x0400` | file id | status, size low, size high |
| FileRead | `0x0402` | file id, core address, offset low, offset high, byte count | status, bytes read |
| DiscGetToc (fork) | `0x8400` | file id, core address | status |

FileRead writes the file's bytes to the core address as little-endian 32-bit words, at
the file's `max_transfer_speed`; at the end of the file it returns fewer bytes. Stock
firmware answers DiscGetToc, which it does not know, with an error.

**The table of contents** (DiscGetToc, written to the core address; little-endian
32-bit words):

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

LBAs are absolute: track 1 starts at 150 (00:02:00). The raw image's sector at absolute
LBA L is at byte offset (L - 150) x 2352.

## In this core

- `files.json`: the disc file (id 0) has `"on_demand": true`, extensions `cue`, `bin`,
  `iso`, `chd`, and `"disc": true` (the fork firmware's mark for a disc image).
- **Setup** (`cdd_emu.sv`, `od_*`). When the core first runs after the host's setup
  without file 0 loaded, it sends DiscGetToc to the file's first 2 KiB (`0x1000_0000`).
  A valid table (1-99 tracks, the count matching its BCD copy) from the fork firmware
  makes it a raw image with those tracks. Otherwise it sends FileGetSize and a FileRead
  of the file's first 2352 bytes into ring slot 0: a sync pattern (`00 FF x10 00`) makes
  it a raw image of size / 2352 sectors, the Opera volume header (`01 5A 5A 5A 5A 5A 01`)
  an ISO of size / 2048 sectors, and the core writes a table of contents of one data
  track itself. Anything else (no answer, an error, a `.cue` read as text) leaves no
  disc. A disc loaded at setup (`FileWriteStart`/`FileWriteEnd` of file 0: an ISO in the
  SDRAM, up to 22 MiB, or a table of contents) is still taken; `tb_top +preload` keeps
  that path tested.
- **Sector reads.** `cdd_emu.sv` sends FileRead requests into a read-ahead ring of
  13 raw sectors in block RAM, mapped at host addresses `0x4000_0000`-`0x4000_7FFF`
  (slot s at `0x4000_0000 + 2352 s`): 2352 bytes at (L - 150) x 2352 for a raw image,
  2048 bytes at (L - 150) x 2048 to 16 bytes into the slot for an ISO, whose sync,
  header and EDC/ECC then read as zeros. The transfer never touches the SDRAM, and the
  3DO is not paused for it. The requests go one at a time, back to back: up to the end
  of the READ the drive controller sent, and while audio plays, as far ahead as the ring
  has room (13 sectors, 173 ms at 1x). A slow answer (an SD read, a file opened at a
  track boundary) then overlaps playback instead of delaying a sector. A READ of a sector
  that is not next in the ring (a seek) restarts the ring there; its first request goes
  out at once, so the firmware's latency overlaps the drive's seek time. With the
  default block length (2048 bytes), the core hands bytes 16-2063 (the MODE1 user data)
  to the controller, as MiSTer's HPS does. A request that fails, is not answered OK in
  full, or gets no answer (about 5 s) reads as an empty sector.
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

`tools/iso2bin.py image.iso` converts an ISO into `image.bin` (MODE1/2352: sync, header,
data, EDC, P/Q ECC) and `image.cue`.

## Verification

- `sim/run_tb.sh tb_top` (stock firmware: an ISO; the model answers DiscGetToc with an
  error, then FileGetSize and FileRead) and `tb_top +stream` (the fork firmware: a raw
  image with a data track and an audio track, its table of contents on DiscGetToc). The
  end of the run checks that the core set the disc up on demand, as an ISO or a raw
  image, with its tracks. With `+stream`, the test BIOS's CD
  tests run through it:
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
- `tb_boot +disc_bin=<image.bin>` (or `+disc_iso=<image.iso>`; `+fw_stock` for stock
  firmware): boots a real BIOS while streaming a real disc image on demand.
  The real Wolfenstein 3D image (133 MB) streams through the same path.
  `+audio_tracks=<n> [+data_sectors=<k>]` describes the image as a data track of k sectors
  (none with k = 0) followed by n audio tracks. The log shows every command the BIOS sends
  to the drive controller and the status it reads back. Every block is checked against
  the image at its block length, both as sent to the controller and as the CPU reads it.
  The spacing of audio sectors is reported.
