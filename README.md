# 3DO for Game Bub

A port of the [MiSTer 3DO core](https://github.com/MiSTer-devel/3DO_MiSTer) (by srg320) to
[Game Bub](https://gamebub.net/), using the
[Game Bub core framework](https://docs.gamebub.net/developing-cores/overview/)
(XC7A100T FPGA, one 32 MiB SDRAM chip).

**Status: experimental.** On Game Bub hardware the first build gave a black screen: the
SDRAM interface timing was wrong for the board (see *SDRAM interface timing* below). With
that fixed, games run on the handheld (Cannon Fodder, from a 2048-byte-sector ISO through
the patched streaming firmware). Testing there then showed phantom button presses in NTSC
mode and video lines shifted to the right; both are fixed in the current build (see
*Controller input* and *Video lines that started late*), which has not been tested on
hardware yet. In simulation, the core passes its test suite (see below), and the real
Panasonic FZ-10 BIOS boots a commercial disc (Wolfenstein 3D, streamed the way the
disc-streaming firmware serves it):

* The BIOS decompresses its kernel, displays the 3DO logo and brings up the CD drive
  (Read ID, Spin Up, Set Speed, Disc Info, Read TOC), answered by the core's drive
  emulation.
* It loads the disc's boot code and operating system, and resets into them. Every
  sector delivered is checked against the image (986 sectors in 16 s).
* The game then runs: it shows its animated 3DO logo, fades it out and starts its
  intro (CEL-engine 3D graphics over a starfield), 16 s after power-on.

The homebrew 3DO Controller Test (an `.iso`) boots both ways, preloaded as stock firmware
does it and streamed (converted with `tools/iso2bin.py`): the BIOS shows the disc's banner 4 s after
power-on, and the program its controller screen 8.5 s after. Its framebuffers match the
image on the disc, and every VRAM transfer of both boots (and of the Wolfenstein 3D
boot) is checked against a shadow of VRAM (see *Simulation*).

The SDRAM interface is now timed by Vivado against the SDRAM's data sheet values (see
*SDRAM interface timing*); the part on the board is not documented, so the slowest common
100 MHz parts are assumed.

## Installing

Copy to the microSD card:

```
/cores/apolkosnik.3DO/core.json
/cores/apolkosnik.3DO/files.json
/cores/apolkosnik.3DO/settings.json
/cores/apolkosnik.3DO/P3DOCore-gamebub_rev4.bit
/cores/apolkosnik.3DO/bios.bin      <- 3DO BIOS (512 KiB or 1 MiB), required
/cores/apolkosnik.3DO/kanji.rom     <- optional (Japanese BIOS font ROM)
```

The JSON files are in `metadata/`.

**BIOS images.** [metadata/bios_catalog.json](metadata/bios_catalog.json) lists every
boot ROM and Kanji ROM from the [3DO Development Repo](https://3dodev.com/software/roms),
including console, developer, prototype and arcade variants. Identify a file by its
size, CRC32 and MD5 with `python3 tools/bios.py /path/to/rom.bin`; `--list` shows the
catalog. The four European FZ-1/FZ-10E variants select PAL with **Region: By BIOS**.
Other images use NTSC by default; the two Sanyo HC-21 prototype regions are unverified,
so select their timing manually if needed. Region changes take effect after **Reset**.

The 512 KiB arcade BIOS mirrors across the core's 1 MiB ROM window. For firmware that
requires a 1 MiB file, `python3 tools/bios.py /path/to/3do_arcade_saot.bin --output bios.bin`
prepares the mirrored image. Kanji images belong in `kanji.rom`. M2 entries are identified
as unsupported: they require a different machine. Catalog recognition and loading do
not mean every developer, prototype or arcade BIOS has been boot-tested on this core.

**Discs.** Use the disc-streaming firmware from the
[neutralinsomniac/gamebub](https://github.com/neutralinsomniac/gamebub/blob/psx/docs/psx.md)
fork (the one its PlayStation core needs; release 0.1.3, whose firmware file is
`gamebub-handheld-rev4-1.1.0-beta3.uf2`) and select a `.cue` (or a lone `.bin`). Discs of
any size are read from the microSD card as the game needs them, and the disc can be
changed from the pause menu; see [docs/disc_streaming.md](docs/disc_streaming.md).

That firmware reads raw 2352-byte CD sectors only. Most 3DO images come as an `.iso`,
which it refuses ("not a raw image"). The release zip therefore includes that firmware with
a patch that reads 2048-byte-sector ISOs as well (see [firmware/](firmware/README.md)). With
the unpatched firmware, convert first: `tools/iso2bin.py image.iso` writes `image.bin` and
`image.cue` (with the sector headers, EDC and ECC of a pressed disc); select the `.cue`.

The handheld firmware in the release zip also reads **CHD** images (`.chd`, version 5, as
`chdman createcd` makes them, with its default codecs `cdlz`, `cdzl` and `cdfl`, the generic
`lzma` and `zlib`, or none). A CHD made from a CUE/BIN or an ISO reads sector for sector as
the image it was made from, CD audio tracks and pregaps included. CHDs compressed with zstd
(`cdzs`, `zstd`), CHDs that need a parent CHD, and hunks larger than chdman's default 8
frames are refused. See
[firmware/](firmware/README.md#chd-images).

Stock firmware cannot stream: it loads the selected file into SDRAM at startup, so only
`.iso` images (2048-byte sectors) of up to 22 MiB work there. `tools/cue2iso.py
image.cue` converts a CUE/BIN and tells you whether it fits. Commercial discs (100–650 MB)
do not.

**Saves.** The NVRAM is stored next to the disc image as `.sav`. If none exists, a blank
3DO NVRAM is created. It is written back when you leave the core, and with the fork's
firmware also when you pause.

### Limitations

* **Commercial discs need the disc-streaming firmware.** Stock firmware only runs `.iso`
  images of up to 22 MiB (see *Discs* above).
* CD audio tracks (from a `.cue` with its `.bin` files; an `.iso` has none) are read
  through the drive's data port and played on the DSP, as on the 3DO, which has no analog
  CD audio path. This is tested in simulation only, not yet on hardware.
* PAL games run at 50 Hz, but the handheld's LCD refreshes at 60 Hz, so every fifth frame
  is shown twice.
* In PAL mode the 3DO puts out about 288 picture lines, and only 240 of them are captured,
  so part of the picture is cut off (seen on hardware: the top of Cannon Fodder's title).
  With an NTSC BIOS, keep the Region setting on NTSC (or By BIOS); PAL discs then run in
  NTSC mode.
* Only the 64 KiB "BRAM1" VRAM block is on chip, because the framework's double
  framebuffer uses most of the block RAM. The rest of VRAM is in the SRAM (eight blocks)
  and the SDRAM, behind the original MiSTer DDR3 logic (`ddram.sv`). Video reads from it
  go through a prefetching cache (below), but CPU and CEL-engine accesses outside the
  block are slower than on MiSTer.
* Movies and other heavy scenes still show broken lines (Microcosm's intro, a line or two
  in Cannon Fodder's title), with the VRAM in the SRAM or in the SDRAM: being
  investigated. The SRAM removed the pauses between Microcosm's animated sequences.
* A band of wrong lines at the top of the screen, late in the BIOS boot, was seen on
  hardware. In simulation it comes from page copies holding VRAM past a line's transfers;
  v0.4 holds copies before each shown line (*Page copies before a line's transfers*), and
  also keeps the CEL engine and the video cache's prefetches out of the time before a
  line's transfers. Confirmed gone on hardware (v0.7, 2026-11-13).
  Copies now run between the shown lines, so a game that clears or copies its frame
  buffer while the picture is shown does so more slowly than before (most with the
  SRAM's safe timing).
* CLIO's horizontal and vertical interpolation are off: the picture is captured at
  320 x 240, which keeps neither the interpolated dots nor the interpolated lines.
* Video lines that start before their VRAM transfer (see *Video lines that started late*)
  are not all gone: before the two fixes there, the Wolfenstein 3D boot had 247 in its
  first 12.5 s, 216 of them from the CPU's CLIO accesses; the remaining ones in its 3D
  intro, where the 3DO is paused for the SDRAM a lot, are being measured.
* One controller (the handheld's buttons and the dock's gamepads all drive it). Buttons:
  see the Buttons setting; Start = P (play), Select = X (stop), L/R = L/R. The firmware
  has no button remapping of its own; its "Swap A/B and X/Y" setting swaps those of the
  dock's gamepads before the core sees them.

### Settings

* **CD Speed**: delay between sectors: real 2x drive (6.7 ms), MiSTer rate (3 ms,
  default), or fast (0.5 ms).
* **Region**: NTSC or PAL video timing, either by BIOS (a PAL Panasonic FZ-1 BIOS is
  recognised by its checksum, as on MiSTer) or set by hand. Takes effect at the next
  reset.
* **VRAM memory**: where the VRAM blocks outside the on-chip one live. `SRAM` (default):
  eight 64 KiB blocks in the 512 KiB SRAM, two 10 ns cycles per 16-bit word; `SRAM, safe
  timing`: three cycles per word, for a slower part (the board's SRAM is not documented);
  `SDRAM only`: all of them in the SDRAM, as before. Takes effect at the next reset or
  game start.
* **Buttons**: which Game Bub buttons are the 3DO's A, B, C and X (stop).
  `Y B A = A B C` (default): Y, B, A are A, B, C, left to right as on a 3DO pad, and X
  is stop. `A B X = A B C`: A, B, X are A, B, C and Y is stop, for a pad with A B C D in
  a row (Neo Geo style) that the dock reports as A B X Y. Which names the dock gives a
  pad's buttons is up to the dock; the 3DO Controller Test shows the result. Takes
  effect at once.
* **Reset**: resets the 3DO.

## How the port works

| MiSTer                                  | Game Bub                                                          |
|-----------------------------------------|-------------------------------------------------------------------|
| SDRAM: 3DO DRAM (`sdram.sv`)            | `sdram_3do.sv`, same MCLK-locked TDM scheduling, banks 0/1        |
| DDR3: VRAM overflow, BIOS, kanji, NVRAM | `ddram.sv` (two write fixes, below), on `ddr_bridge.sv` to SDRAM bank 2; eight 64 KiB VRAM blocks in the SRAM (`vram_sram.sv`, below) |
| HPS: CD image streaming                 | `cdd_emu.sv`: sectors on request from the firmware (fork), or an ISO preloaded into SDRAM |
| HPS: BIOS/save loading                  | framework file transfers, `gb_host.sv`                            |
| Altera megafunctions                    | `rtl/compat/altera_compat.sv`, Xilinx-inferable rewrites          |
| combinational `lpm_divide` (MADAM)      | sequential divider, same results (`MADAM_mem.sv`)                 |
| video_mixer / scaler                    | framework framebuffer, 320x240, 18-bit colour (`video_capture`)   |
| fast DDR3 for video reads               | `vram_rtcache.sv`, prefetching half-row cache (see below)        |

The SDRAM controller has a second, burst-capable port. It may only use the bus while the
3DO is frozen: either in reset, or paused through the core's existing `PAUSE` mechanism,
which MiSTer already uses for slow DDR3 accesses. Several changes were needed compared to
MiSTer's controller, because these pauses can now happen at any time:

* The TDM slots follow both edges of MADAM's PHASE1. A pause with PHASE1 high therefore
  no longer drops the DRAM writes of that MCLK.
* The slot-0 read is issued once, not repeated while paused.
* The controller refreshes the SDRAM itself if the 3DO has not done so for 15 µs (in
  reset, or before the BIOS enables refresh). It closes and re-opens open 3DO pages
  around the refresh.
* tRAS is respected when the 3DO closes a page in the MCLK right after opening it.
* When the controller's own refresh comes due, it asks for a pause. If the 3DO does a
  refresh itself before the pause takes effect, nothing is left to do, and the
  controller now releases the bus. It used to start a transfer anyway, from the
  secondary port's idle inputs: the last address written, with stale write data. In
  simulation that rewrote VRAM pixels the CEL engine had just drawn, a few times per
  second of Wolfenstein 3D's logo. The same could have hit the NVRAM (the save) right
  after the 3DO wrote it.

**SDRAM interface timing.** On the first hardware test the screen stayed black, and the
NVRAM the core saved showed why: in every 32-bit word the upper 16-bit half was a copy of
the lower one. Each SDRAM read returned the word of the read after it, and the last read
of a pair the bus as that read left it. Three things were wrong:

* **The read was taken a cycle late.** The SDRAM runs on the inverted `clk_mem`, at CAS
  latency 2, and its data reaches the FPGA's input registers about 27-33 ns after the
  `clk_mem` edge that issues the READ. `READ_STAGE` = 5 (MiSTer's value, which suits the
  longer delays of its add-on SDRAM board) sampled at 40 ns. It is 4 now (30 ns). The
  simulation model had hidden this: it put read data out a clock later than a real part
  does (as for CAS latency 3), which is exactly what `READ_STAGE` = 5 needs.
* **The command, address and write-data registers were not in the I/O blocks.** About
  6 ns of routing put them at the pins 7-10 ns after their clock edge, right where the
  SDRAM takes them (9 ns), so a command, an address bit or write data could be taken a
  cycle early or late. They are in the IOBs now. The DQ output enable is one register for
  all 16 pins (the framework has one direction bit), so it stays in the fabric and is
  timed like the data.
* **Nothing timed the interface,** and the constraints left every path between
  `clk_sys` and `clk_mem` untimed too (each clock was declared asynchronous to the other,
  although they are phase aligned and the MiSTer core uses them together).

`p3do.xdc` now describes the interface: the forwarded clock, the SDRAM's setup, hold,
access and output-hold times, and the capture edge `READ_STAGE` = 4 implies; the build
fails if it is not met. At 30 ns the hold margin at the fast process corner was -1.1 ns,
so the forwarded clock comes from its own MMCM output, 1.875 ns (67.5 degrees) after
`clk_mem`, which moves the read data later and leaves margin on both sides. The
simulation model now follows the CAS latency like a real part and uses the routed
design's delays; with `READ_STAGE` = 5 the tests fail as the hardware did (`tb_sdram`
reads the next word; `tb_top`: unformatted NVRAM, the test ROM never runs).

**VRAM read-transfer cache.** MADAM's video DMA loads a VRAM row into the serial
register and starts shifting it out about 160 ns later, and the video beam cannot be
paused. A transfer from the shared SDRAM takes 0.5–6 µs, so before this cache the BIOS
logo came out as garbage: 54,464 stale serial reads measured in `tb_boot`.
`vram_rtcache.sv` serves every external read transfer from 16 half-row entries in block
RAM, and each request prefetches the next two half-rows, because video DMA walks the
framebuffer sequentially. Writes are snooped where they reach SDRAM (and at flash
writes), which keeps `ddram.sv`'s own ordering. BIOS boot result: 99.9% hits and a clean
picture.

A video line needs its transfers (one per VRAM half) before it starts shifting out, and a
fill pauses the 3DO (and so MADAM's video DMA) for about 6 µs. Two cases made a line start
from the serial register's old contents, the VDL words of the CLUT transfer (a short cyan
strip at the top of the picture in Wolfenstein 3D):

* The top of a frame: the end of the previous frame does not lead to its first row, so
  that transfer missed. A VDL entry loads the frame buffer addresses about 7 µs before
  the first transfer from them. MADAM's address generator now passes them on (`VID_FB_*`,
  after the entry's own transfers) and the cache fetches the first half-row at once.
* A prefetch started right after a line's first transfer held back the other half's
  transfer, which comes ~0.1 µs later. Prefetches now wait until no transfer has been
  requested for 1.28 µs.
* When the VDL entry itself is processed late (in the BIOS: its VDL is in SDRAM, and the
  CPU's CLIO accesses come first), its addresses come too close to the line. The cache
  also fetches the first half-rows of the last two frame buffers at the start of every
  frame (MADAM's `LINE0`, in vertical blanking).
* The CPU's SPORT read transfer (the source of a VRAM page copy) prefetched like a video
  transfer, though the half-rows after a copy's source are not the next lines of a
  picture (a screen clear copies one row into many). Those fills paused the 3DO when
  MADAM's next video transfer came, which then started 5–15 µs late: the line showed the
  old row until the transfer moved the serial tap mid-line, and the rest of the line
  shifted. The copy's read transfer now marks itself as not for the display (`ESNP`, as
  a masked write's destination-row read already did), and prefetches nothing.
  `tb_rtcache` phase 14 checks it: the old RTL held the memory path the whole 1.5 µs after
  each copy's read transfer and fetched the next row.
* A CPU or CEL-engine write into a cached half-row dropped the whole entry. The renderer
  writes into the rows the video is about to show (the frame drawn and the one shown), so a
  line's two transfers could both miss, and their fills ran one after the other: the second
  ended after the line's read-out had begun. A single-beat write now updates the bytes it
  enables in an idle entry. Flash writes still drop entries, and so does a write into an
  entry being shifted out, whose read-out keeps the data it started with. `tb_rtcache`
  phase 15: the old RTL dropped both rows and missed on the line.
* A page copy (the CPU's SPORT read and write transfers) into a cached half-row dropped it
  too, and the next video transfer of that row missed: its fill (5.8 µs from the SDRAM,
  10.4 µs from the SRAM) ran past the line's scanout, in either VRAM memory. An audit found
  it: copying each displayed row onto itself, VRAM unchanged, corrupted 12 of 12 cases;
  without the copy, or with the rows fetched again afterwards, none. The copy's write
  transfer is two 128-beat bursts, and `ddram.sv` gives each burst's address with every
  beat, unchanged; the cache now counts the beats, and every beat, single or in a burst,
  updates an idle entry like a single write. `tb_rtcache` phase 16: copies of rows onto
  themselves and masked copies of other rows into cached rows leave the line's next
  transfers hits with the copied data (the old RTL dropped the rows and missed), and a copy
  whose beats reach an entry while it is delivered to one half (a split transfer) drops it.

`tb_boot` checks that every video line has had its transfers before it starts: a late line
while the 3DO was paused (the port's memory system) is an error; one delayed by MADAM's
own bus arbitration is counted separately (see *Limitations*).

**Controller input (fix to `MADAM_PLAYER.sv`).** MADAM drives the player bus clock from
the video timing (8 bits per line, from line 16) but took each bit in on its bus clock,
which the core's PAUSE stops. A pause longer than one bit (8 µs) lost a bit, and the
pad words after it arrived shifted: phantom presses (on hardware: L, R and X lit in the
controller tester, the "no more devices" 1s that follow the pad word slid into it), and
later a crash. Such pauses are common here (a VRAM page copy through the SDRAM takes
about 30 µs), and only in NTSC did they reach the player bus: games do their per-frame
work from vertical blanking, which leaves 2.5 ms before line 16 in NTSC and 5.7 ms in PAL.
Each bit is now taken on the video clock, 2 µs after its clock edge, into a queue that
the bus-clock side shifts in when it runs. `tb_boot +pad_walk` holds the buttons one
after the other and checks every frame's pad word: the controller test in NTSC lost
1031 bits in 298 of 716 frames before (148 of 405 pad words wrong).

**Video lines that started late (fixes to `MADAM_EXTPIF.sv` and `vram_rtcache.sv`).**
MADAM requests a line's VRAM transfers about 4 µs before the line starts; if they come
after, the line shows the serial register's old contents and is shifted to the right.
Two causes:

* **The CPU's accesses to CLIO.** A load/store multiple to CLIO (the BIOS reads the CD
  data port with 8-word LDMs; audio and CD streaming do the same) kept the bus: the
  next word's access started right after the previous one, while the CPU still had the
  bus, so MADAM's arbiter never saw the request low, and the video DMA waited up to
  3.7 µs. A CPU access to CLIO is now not started while a video, mid-line or VDL
  request waits; the CPU is stopped meanwhile (its grant), and since CLIO is
  idle-ready, its ready is held off from the CPU interface until the access has
  started. In the controller test's first 3.4 s this removed all 38 such late lines, and
  the lines with less than 2 µs to spare went from 650 to 12; every CD sector still
  checks out.
* **A cache miss on a line's first transfer.** The video DMA issues the transfers to the
  two VRAM halves one after the other, ~0.15 µs apart. When the first missed the RT
  cache, its fill (~3.8 µs) paused the 3DO before the second was issued. A one-sided
  demand fill now waits while MADAM is in its video DMA sequence, until the other side
  has asked too, at most 2 µs (`tb_rtcache` phase 11). These were the remaining 32 late
  lines of the controller test's first 3.4 s.
* **SDRAM transfers just before the request.** Every transfer on the SDRAM's secondary
  port pauses the 3DO (its DRAM shares the bus), while the scanout goes on. A 512-word one
  (an RT cache half-row fill, a CD sector read from a preloaded image, a host block) takes
  5.6 µs, more than the 4.4 µs between the line's request and its scanout (found by an
  audit: 512-word transfers at the request made 10 of 10 lines late), and short ones back
  to back keep the 3DO paused just as long (a second audit: 2- and 4-word requests with no
  gap, 64-word ones up to 20 cycles apart). MADAM_SPORT's `VID_GUARD` is now high from
  5.7 µs before the request until the line's second transfer is on the bus. While it is,
  `sec_arb.sv` starts no transfer (`vid_sec_guard.sv`), unless the 3DO is already paused
  for something else: a VRAM access waiting in `ddram.sv` or the cache, which may need
  that transfer (the 3DO's own random VRAM reads and writes keep `ddram.sv` busy until
  they are done, so they are never held). What waits is cache fills and prefetches, copy
  and flash bursts, CD and host transfers, at most about 6 µs per line in the test (15 µs
  at most by design). `tb_vidguard` runs the real SPORT, arbiter, video, guard, secondary
  port and SDRAM controller for PAL and NTSC with long transfers at every point of the line
  and streams of short ones back to back: no line is late and no transfer starts inside
  the guard. With the 3DO stalled, transfers start at once; the test holds that stall
  through the line's request, so those lines (one per run, PAL or NTSC) are late by
  construction and are counted apart: the guard cannot help a line while MADAM itself is
  stopped. With `+no_guard` (the arbiter as before) the same test finds the audits' late
  lines. Mid-line transfers (a line crossing a VRAM row) are not guarded.
* **Page copies before a line's transfers.** The guard does not cover the 3DO's own SPORT
  transfers: a page copy's read or write transfer (or a flash write) keeps its VRAM half
  busy until the row is in or out of the SRAM or SDRAM, 8 to 21 µs (real VRAM: about
  0.2 µs). A line's video transfer that comes in the meantime waits for it while the
  scanout goes on. The OS clears and copies frame buffers in the vertical blanking; here
  those copies reached into the top of the picture, and those lines showed the serial
  registers' old contents (the band of about 20 lines at the top). MADAM now keeps the
  CPU's SPORT accesses waiting before each shown line's request until the line's
  transfers are on the bus (`SPORT_HOLD`, MADAM_SPORT to MADAM_CPUIF's stretch cycle),
  from at least the longest CPU SPORT transfer before it: 45 µs with the SRAM (longest
  40 µs), 30 µs SDRAM only (27 µs), and with the SRAM's safe timing (56 µs) from the
  start of the scanout, so that copies start only right after a line's transfers (one
  transfer per shown line). Copies go on between the lines and freely in the vertical
  blanking. Test ROM test 15 turns the video DMA on (a VDL
  entry for 240 lines of a frame buffer outside the FPGA) and makes 600 page copies while
  the picture is shown, once into SDRAM rows and once into SRAM rows; `tb_top` checks
  every line's transfers and reports the longest CPU SPORT transfer. Without the hold
  367 of 474 lines were late (SRAM), with it none of 480 in every VRAM memory mode.
  On a line with a VDL fetch (HCOUNT 1279: the frame start, or an entry's last line) the
  hold starts 190 dots earlier: a copy still running there paused the fetch, and the
  next line's transfers came after its scanout. Test 15 used to stop the video DMA after
  one frame (its entry set bit 18, a relative next pointer, by mistake); with the entry
  repeating every frame the frame-start line was late in 4 of 5 frames before this.
* **The BIOS ROM behind a read-transfer fill.** ddram.sv serves the 3DO's slow bus (BIOS
  ROM, NVRAM) last, after the read-transfer cache's fills, and a fill is one burst of 128
  beats (about 5.5 µs from the SDRAM, 10-20 µs from the SRAM). The fill itself does not
  pause the 3DO, but a ROM fetch queued behind it does: in the PAL BIOS boot a VDL hint
  fill (a new frame buffer's first rows) held the CPU's next ROM fetch, the pause held
  MADAM, it could not post the next line's video request, and the line came out late
  (line 22 at 0.30 s, `tb_boot +late_diag`). Fills that are not demands (queued
  prefetches, VDL hints, frame start) now go in 32-beat chunks with a waiting slow-bus
  access between them, until a video transfer waits for the entry's rows; demand fills
  stay one burst. `tb_rtcache` phase 18 reads the slow bus during a prefetch fill (SDRAM
  and SRAM rows) and a hint fill: before, the read waited 5.9 to 20.8 µs; now 1.8 to
  4.1 µs, with the fill still running, the right word and the prefetched rows intact.
  `tb_boot +late_diag` now starts its count when a line is scheduled (VIDEO_TRANS_PEND),
  as the late-line check does, and reports how long the 3DO was already paused then.
* **CEL drawing into a shown frame buffer in the SDRAM.** Every CEL engine frame buffer
  read and write in the SDRAM pauses the 3DO; drawing while the picture is shown, the
  pauses took most of the 4.4 µs from a line's video request to its scanout, MADAM
  granted the request 3.9-4.3 µs late behind the CEL engine, and the line showed old data
  (the PAL BIOS CD player's visualizer: 10 late lines in 16 s). Three changes:
  `SE_HOLD` (MADAM_SPORT): from 80 dots (3.3 µs) before each shown line's request, and
  80 dots before a VDL fetch on a line with one, until the line's transfers are on the
  bus, the CEL engine leaves MADAM's bus at its next step and starts nothing new
  (MADAM_ARB `SE_YIELD`); about 7 % of a line, only while the video DMA is on. Prefetch
  fills (not demands, VDL hints or the frame start's) do not start while a line's
  transfers are due (`VID_GUARD`, `pf_hold`), and one under way stops between its 32-beat
  chunks: the secondary port's guard lets a transfer go as soon as the 3DO stalls on
  something else, such as a CEL read queued behind the fill in ddram.sv. Test ROM test
  18 turns the video DMA on and draws two translucent 256x100 cels (every pixel a frame
  buffer read and write) into the shown frame buffer: before, 169 of 2060 lines were
  late (SRAM mode); now none of the shown lines in any VRAM memory mode. `tb_rtcache`
  phase 19 checks the prefetch hold. `tb_top` counts late lines in the vertical blanking
  (not shown: the encoder shows 240 lines from line 22, PAL 45) apart; its late-line
  report says where the time went.
* **Copies queued behind copies.** A CPU SPORT access is now also held while a VRAM half
  still runs a CPU transfer (MADAM_CPUIF `SPORT_BUSY`, vram.sv `XBUSY_CPU`): issued
  then, it waited in the VRAM module and started when the previous copy's write transfer
  ended, inside `SPORT_HOLD` (a page copy's read transfer started 600 dots late and two
  lines came out late in `tb_top`). Only the CPU's own transfers count: counting the
  line's video transfer as well kept copies out of the short gap the safe SRAM timing
  leaves them, one transfer in about 16 lines.
* **Disc id for the per-game table.** MiSTer's 3DO.sv keys its per-game VRAM layout
  table (and its DSP-pause list, see the CLIO list below) on the disc label's volume
  unique identifier, which it takes from the disc-info block the HPS sends on insertion:
  bytes 0x400-0x47F of that block are the first 128 bytes of the *raw* sector 0
  (3docdd.cpp `GetDiscInfo`), and the id is at 0x458-0x45B, raw bytes 0x58-0x5B = user
  bytes 0x48-0x4B. `cdd_emu.sv` put the user data at 0x400, so the id came out 16 bytes
  off (Killing Time's `0A9B739E` read `00000001`) and no table entry ever matched. The
  block now carries the raw sector's first 128 bytes: streamed, the sector's sync and
  header then its data; preloaded ISO, 16 zero bytes then the data. `tb_top` compares the
  block's 128 bytes with the image and the id with the ISO's bytes 0x48-0x4B in every run
  (`+disc_id=<hex>` puts another id into the test ISO); `tb_boot +expect_disc_id=<hex>`
  checks the id a real image gives. The table's VRAM values are not applied on this port
  (they stay in `p3do_gamebub.sv` for reference): MiSTer's released build has its on-chip
  VRAM windows off (`USE_BRAM_BLOCKS_FOR_VRAM 0`), so of each game's three values only the
  third, the 64 KiB block kept on chip, ever took effect there, and its memory system is
  not this one. The port had repurposed the first two to choose its SRAM blocks
  (vram_sram.sv), and the first time an id matched (v0.7) Alone in the Dark's `{4,2,8}`
  moved the SRAM to blocks 2-8 and F, leaving the Portfolio screens at 0xC0000 in the
  SDRAM: the game looked broken (`tb_top +disc_id=274E924C` shows the late video lines of
  an SDRAM frame buffer). Applying the on-chip block alone (block 8 for that game) puts
  the test ROM's frame buffer in block 9 into the SRAM and a shown line starts late too:
  the port's layout, blocks 8-F in the SRAM with 9 on chip, was tuned as a set, and every
  game runs it, as all did before v0.7. MiSTer's DSP-pause entries (Blade Force,
  Decathlon, Killing Time, Snow Job, BattleSport) are not applied either: see the CLIO
  list.
* **CPU VRAM writes during fills.** A game decoding video (Killing Time's EZFlix intro:
  ~50k CPU VRAM accesses a picture, 12 pictures a second) writes VRAM all the time.
  A random VRAM access issued while the read-transfer cache fills a half-row waited in
  ddram.sv behind the whole fill with the 3DO paused, MADAM with it, so a line's video
  transfer request due meanwhile was issued after the line had started; and the next
  access came right after each was served, so letting them in between a fill's chunks
  just stretched the fill. Now: in a plain prefetch fill a waiting random access goes
  between the 32-beat chunks (ddram.sv `bplain`; the CPU is paused ~2 µs instead of ~5
  per prefetch, two a line) unless a VDL hint is waiting for the fill to end; during a
  VDL hint or demand fill the CPU's random VRAM accesses wait in MADAM_CPUIF's stretch
  cycle instead (`VRAM_HOLD`, from vram_rtcache's `d_fill_hold`: the CPU waits up to a
  fill, ~5-8 µs, once a frame or on a miss, and MADAM runs on), and a random access
  already waiting is served before a new fill starts (ddram.sv `brd_start`). Test ROM
  test 21 decodes three pictures the way EZFlix does (see `sim/tb/testrom.S`) with the
  video DMA on, its VDL laid out as the OS lays a screen out (16 lines without video
  DMA, then 240): no shown line is late in any VRAM memory mode, and every word written
  reads back right, both at random and through the cache. (With the 240 lines starting
  at line 5 the entry's refetch fell on a shown line and its two hint fills, current and
  previous frame buffer, could not both end before that line's request: a VDL entry
  ending on a shown line with different frame buffers next costs one late line per
  switch under heavy CPU VRAM traffic; the OS ends them in the vertical blanking.)

### Firmware statistics registers

The Game Bub firmware (the disc-streaming fork) reads two counters from every core when
the game is paused, the clocks the core was stalled and ran (`0x1000`, `0x1004`), logs the
run rate and writes 0 to both. The 3DO core had its CD Speed setting at `0x1000` and Reset
at `0x1004`, so every pause set CD Speed back to "2x (Original)". The settings are now at
`0x1020` (CD Speed) and `0x1024` (Reset), with the same ids, so saved values are kept;
`0x1000`/`0x1004` count the clocks the 3DO was paused / ran, cleared by a write.
**Copy the new `settings.json` with this core**: the old one sends CD Speed to the
counter. `tb_top` checks that both count, clear on a write, and that CD Speed reads back
at its new address.

### Mouse

The 3DO mouse (ID 0x49, after the pad) is on the control port when the **Controller**
setting is "Pad + mouse" (register `0x1014` = 2). The device is MiSTer's (`hps2pad.sv`);
`host_mouse.sv` turns the Game Bub registers into its PS/2 packets:

* `0x1030` motion: `{dy, dx}`, signed 16-bit each, the movement since the previous write,
  right and down positive; each write is one packet, clamped to -256..255 per axis. The
  3DO mouse moves one count per unit written (MiSTer doubled them for the HPS's raw PS/2
  deltas, which moved the cursor in steps of two; the firmware scales here) and the game
  reads at most 96 counts per control port read, the rest waits for the next reads.
* `0x1034` buttons: bit 0 left, bit 1 right, bit 2 middle, read as they stand (the
  firmware writes them alone when a button changes with the mouse still; MiSTer's
  `HPS2PAD` took the buttons from the last packet, so such a click would have reached
  the game with the next movement, and one held from before the mouse was switched on
  never).

A real mouse on the dock drives it. The dock firmware (branch `usb-mouse` of the
dock-firmware fork) takes USB mice (boot protocol, or any report descriptor) and
Bluetooth mice (bluepad32) and sends each as a gamepad whose buttons word has bit 30 set,
with the movement since the previous packet in the left stick fields (the dock's queue
adds a new movement into a packet still waiting, so none is lost); up to 8 HID
interfaces, so two mice and two controllers through a hub work. The handheld firmware
(branch `mouse-3do` of the fork) sums the movement of every mouse into one 3DO mouse (one
mouse count is one 3DO count), ORs their buttons, writes a packet for every report of
the mouse as it arrives (paced to one per 8 ms at first, a 125 Hz mouse's reports fell
into the 3DO's fields one or three at a time and the cursor stuttered; the stick's cursor
is still paced to 8 ms), and keeps the mouse out of the merged pad; without a mouse a
dock gamepad's right stick and buttons stand in. `tb_lightgun` checks
the packets through `host_mouse` and `HPS2PAD` (a packet, the clamp and the 96-count
reads, two packets adding, a button alone and one held from before the mouse was
switched on, dy -32768 clamped up rather than wrapped, the device off); test ROM test 20
reads the mouse through MADAM's player bus DMA. On hardware a USB mouse works in Lemmings
with the v0.5 bitstream and both firmware builds (the dock firmware's bluepad32 submodule
is at a public commit, with the dock's CMake giving bluepad32 the FreeRTOS CYW43 arch
instead of its own).

### Light gun (groundwork)

The 3DO light gun (ID 0x4D: American Laser Games titles, Corpse Killer, Space Pirates
and others) is in the core's control port, after the pad, for the GunCon 3 support that
is being added to the Game Bub firmware. The gun reports no position: a 20-bit count from
the start of the field to the moment its sensor saw the beam, and the number of line
pulses it saw. `HPS2PAD` turns an aim position into that count as Portfolio's light gun
driver decodes it (`count = ceil((y * 12707 + x * 10300 / 320) / 10) + 12835` for NTSC;
PAL 12796 / 1051 / 388 / 58995, the SDK's defaults, not checked on a PAL gun). Opera
rounds the division down, which put x = 0 at the end of the line above for the driver.
Core registers (host memory interface):

* `0x1014` Controller: 0 pad, 1 pad + light gun, 2 pad + mouse (the firmware sets 1 itself
  when a GunCon 3 is connected).
* `0x1018` aim: `{y, x}`, 0..65535 across the picture.
* `0x101C` buttons: bit 0 trigger, bit 1 option, bit 2 off screen (no hit: count 0,
  trigger set, as for a reload).

The light gun is not offered by the Controller setting in `settings.json`: without the
firmware driving it the gun would only report "off screen"; the firmware selects it when a
gun is connected. `tb_lightgun` checks 541 control port transfers
(NTSC and PAL, corners, edges, a grid, random aims, buttons, off screen) against the
formula and Portfolio's decoding; test ROM test 19 reads the gun through MADAM's player
bus DMA as Portfolio does (the first word is the port's leftover, as in Portfolio's
ControlPort.c).

`tb_boot` places the BIOS in the SDRAM directly; it now also gives `gb_host` the BIOS
checksum that streaming the file would have left, so Region "By BIOS" picks PAL for a PAL
BIOS (before, every BIOS ran as NTSC), and `+region=<0 by BIOS, 1 NTSC, 2 PAL>` sets the
Region setting; the run reports the standard the core chose. `tb_boot` checks every line from the point its transfers are scheduled (HCOUNT 1469, on
the dot clock); it used to start at MADAM's request, which a pause can hold until after the
scanout has begun, and such a line was then not counted or was checked against the
previous line's transfers. `tb_boot +late_diag` reports for every late or nearly late line where the time went
(grant, transfers, pauses by cause, MADAM's bus, the SDRAM work started), and
`+clio_trace=<µs>` traces MADAM's arbitration cycle by cycle.
`tb_boot` also compares every halfword the video shift registers shift out with what
real VRAM would shift out at that tap (a full read transfer loads the whole row, a split
transfer always loads its half), from the VRAM shadow; each difference is reported with
its line, dot, tap and the side's last transfers (`+tap_log=<n>`). A PAL BIOS boot
without a disc (to 5.6 s) gives none.

**Random reads after copies (fix to `ddram.sv`).** `ddram.sv` keeps the 32-word block of
each half's last random read and serves later reads in that block from it. Write bursts
(page copies, write transfers, masked flash writes) and lazy flash writes did not touch
it, so a translucent cel or the CPU read the frame buffer's old pixels after a SPORT
clear or copy (upstream behaviour). The blocks are now dropped when a write burst
starts and ends and on a flash write. `tb_rtcache` phase 17 reads words after a flash
write, a page copy and a masked flash write (before the fix: the old words).

**Random VRAM writes (fixes to `ddram.sv`).** On MiSTer, framebuffers are normally in
block RAM (a per-game table moves the on-chip blocks to where a game puts them). On Game
Bub only one 64 KiB block is on chip, so every pixel the CEL engine draws goes through
`ddram.sv`'s single posted-write slot to the SDRAM. Two problems in that path made the
animated 3DO logo at the start of a game come out dotted and streaky:

* When one pixel of a flash-cleared 64-bit word is written, `ddram.sv` completes the word
  with the clear colour. It looked up the "flash-cleared" flag and colour for the address
  on the bus. Once the write had been delayed (the SDRAM was busy), that was already the
  CEL engine's next pixel, so the colour overwrote pixels drawn just before.
* MADAM was paused only if `ddram.sv` was busy when a write arrived. If a read-transfer
  fill started in the next cycle (bursts are served first), the write waited without a
  pause, and the CEL engine's next pixel (one per MCLK) replaced it.

The lookup now uses the waiting write's own address, and a write that has not been issued
keeps MADAM paused. `tb_rtcache` reproduces both with MADAM's write timing, and `tb_boot`
checks every VRAM write during a boot.

**Write transfers with the VRAM halves out of step (fix to `ddram.sv`).** Games clear
their frame buffers with runs of the CPU's SPORT write transfers, one row after another
(Syndicate, every frame). Each VRAM half takes the transfer when it is free, and the
video DMA's transfers go to one half at a time, so one half can start its write burst
later than the other. `ddram.sv` writes a half's row in two passes of 128 beats and
serves the left half first; a pass counter bit says which pass ends the burst. A left
burst that started between the right half's two passes took that bit from the right
half's first pass and ended after one pass: the left VRAM module then waited for the rest
of its row for ever and the 3DO stayed paused (Syndicate hung 9.5-12 s after power-on
with every BIOS), and the right half's second pass was counted as a first one, so a third
ran on into the next row. Each pass now takes the bit from its own address. `tb_rtcache`
runs such loops with either half late, and `tb_boot` reports a pause of 500 µs as a hung
memory system.

**VRAM page copies (fix to `vram.sv`).** Software copies VRAM a row at a time (2 KiB per
VRAM half) through MADAM's SPORT address space: the CPU reads an address there (a read
transfer, the source row into the VRAM's serial register), then writes one (a write
transfer, the serial register into the destination row). Programs use this to restore a
background every frame. On the console the OS does it during vertical blanking, when no
video or VDL transfer needs the serial register. Here each transfer goes to the SDRAM, so
a copy takes about 30 µs and a frame's copies run on into the picture. MADAM can then
grant a video or VDL transfer between a copy's read and its write transfer. That
transfer replaced the serial register's contents, and the write transfer stored them in
the destination row: in the 3DO Controller Test, VDL words in the background, a streak
across picture lines 210–215. The VRAM modules now give the CPU's SPORT transfers
(MADAM's `CPU_SPORT_SEL`) a serial register of their own, so a copy stores the row it read
however long it takes, and copies leave the video serial register alone. MiSTer's VRAM
skips a split read transfer of the half-row the serial register already holds; a copy
into that row now makes the next one reload it.
`tb_rtcache` makes video transfers inside copies, and `tb_boot` checks every copy of a
boot (see *Simulation*).

**VRAM write masks and split transfers (fixes to `vram.sv`).** The data the CPU writes to
start a write transfer or a flash write (the SDK's `CopyVRAMPages` / `SetVRAMPages` mask)
is a write mask, one per VRAM half: 1 bits are written, 0 bits keep the row's bits. The
MiSTer core ignored it (its mask capture was commented out), so a copy or flash write with
a partial mask overwrote the protected bits, and one with mask 0 rewrote the whole row.
The mask now applies: mask FFFF works as before; 0 writes nothing; a partial mask merges
the new data with the row, on chip by reading and writing each 16-column block, outside
the FPGA by first reading the destination row (through the read-transfer cache, without
prefetch) and then writing it merged. The lazy flash fill of `ddram.sv` covers both VRAM
halves and has no mask, so it is used only when both halves have mask FFFF and start
together; otherwise each half writes its colour itself. In the core the CPU's write data
is on the bus from CAS (PHASE2 of the access), not yet when RAS falls, so the VRAM takes
the mask, as it took the flash colour, once CAS is low; a command taken late (after a
pause) finds CAS low already, which the old flash path, waiting for a CAS edge, missed.
Also, the skipped split read transfer (see above) now reloads its half-row after a flash
write or a random write into it, not only after a copy: it had returned the old pixels.
`tb_rtcache` phase 13 runs masked copies and flash writes and split transfers after each
kind of write in on-chip, SRAM and SDRAM rows (26,084 errors before the fix), and test 9
of the test BIOS makes them from the CPU (see *Simulation*).

**CLIO timers and interrupt summary (fixes to `CLIO.sv`).**

* INT0 bit 31 reads as the summary of the enabled INT1 interrupts, as the FIQ already
  was (Opera emulator). It was a latched bit, set by any player bus interrupt, enabled or
  not, until cleared through 0x44, and never by the other INT1 sources.
* A cascaded timer takes the borrow of the timer below it in the same count: a pair goes
  0001:0000, 0000:FFFF. It came one count (16 µs) late, through 0001:FFFF; the OS keeps
  its clock in cascaded timers.
* The timer controls read back at the set and the clear address of each bank (they read
  0).
* TimerSlack (0x220) sets the count period, 64 + TimerSlack ticks of 25 MHz (Opera); the
  OS writes 336 for 16 µs. It was fixed at 400 ticks and read 0. Its value after reset is
  not documented: 336 keeps the old period until the OS writes it.

* The DSP FIFOs (input and output, and the 32-bit DMA FIFOs): a read and a write in the
  same cycle on an empty FIFO (a DSP reading while a DMA refill arrives) advanced the
  write pointer but not the count, so the FIFO miscounted its words from then on (read
  twice or lost); a full FIFO read and written lost count the same way, and a write to a
  full FIFO overwrote its oldest word. Writes and reads are now taken by the FIFO's
  state (an empty FIFO hands the incoming word to a read in the same cycle) and the count
  follows them.
* The output FIFOs' status (0x3C0-0x3CC) returned input FIFOs 0-3 again.
* A 32-bit read of the DSP's output memory returned the even word twice; it now returns
  the even word in bits 31-16 and the odd one in bits 15-0, as 32-bit writes store them.
* A DSP read of an input FIFO (0x0F0-0x0FC, popped) or a peek (0x070-0x07C) gives the
  word the CPU last wrote at 0x070+n, once and without a pop, else the word at the head
  of the FIFO; an empty FIFO keeps giving the word it last handed over (Opera's
  CPUSupply and FIFO read; MAME only differs for the CPU's word). The audio folio zeroes
  that word with every FIFO reset (its FIFOHEAD), and a streamer's DSP program discards
  one read per channel after a reset to take it. The original gave the word of the
  *previous* read every time (one word late), so the CPU's word came out first only if
  the DMA had already filled the FIFO when the discard read happened: when it had not,
  Killing Time's DSP decoder (a 4-bit code to delta-pair expander for the EZFlix intro,
  its 16-entry table loaded through input FIFO 3) got a zero table entry and the rest
  shifted by one, and the whole intro came out embossed with wrong symbols. Each read
  also took the FIFO's next word even when it had none, so a drained sample read as a
  stale RAM word.
* The DSP's output FIFOs hold 64 words (the hardware's 8), and a DMA from one is
  requested whenever six words wait in it (MADAM takes three 32-bit words per burst), not
  only in the clock after a DSP write that leaves six. A DSP write to a full output FIFO is
  lost, and the port pauses the 3DO for its slow memory (the SDRAM: every uncached DRAM
  access, a VRAM fill, a secondary-port transfer): MADAM and CLIO's DMA side stop while
  the DSP runs on at its 44.1 kHz frame rate. Killing Time's EZFlix decoder writes 8
  output words per audio frame per channel, so the 8-word FIFOs overflowed in every pause
  longer than the two words of room left after a request, and the decoded pictures came
  out smeared although the DSP itself computed them right (the lockstep harness, which
  serves the DMA at once, matched Opera). MiSTer's answer, pausing the DSP with the 3DO
  for that game and four others (3DO.sv `NEED_DSP_PAUSE`), fits its rare DDR3 pauses, not
  this port's: tried here (build a23, once the disc id matched the table), the DSP fell
  behind its frames, the audio was badly corrupted and the pictures still wrong (a decoder
  counting DSP frames loses data with them). So the DSP is never paused here, and the
  deeper FIFO holds a pause's worth of output; a late burst then drains the backlog one
  request per burst. Confirmed on hardware (build a24): Killing Time's intro plays clean,
  with normal audio, and the game no longer hangs in its main menu when left alone (it
  did on v0.5, music stopping with it; never reproduced in simulation). The DSP's output
  FIFO status (0xE0-0xE3) saturates at 15; the CPU's 0x3C0-0x3CC read the full count.
* A DSP read of a data word an instruction writes in the same clock gets the new word:
  the MOVE's, or an ALU result whose write waits for the memory port behind a MOVE's
  write. Killing Time's DSP program increments its interrupt counter (ADD [108] + 1),
  moves another word, then moves [108] to the CPU interrupt register: the ADD's write
  landed in the clock of that read, which took the old count.
* The DSP's frame counter keeps the reload value the DSP wrote. Every frame start set it
  back to 565, so a program's own frame rate held for one frame. It is 565 from
  power-on, and a CPU reset leaves it (Opera).
* In audio lock the frames start only with the audio word strobe; the counter started
  them as well.
* CSTAT (0x28) writes as Opera takes them: power-on, rollover and DIPIR reset (bits 0,
  1, 6) are only cleared by writing 0 (a write set them again), the watchdog bits are
  not written, ClearDIPIR is not stored, and SoftReset with ClearDIPIR sets DIPIR reset.
  Writing 0x40 cleared the DIPIR reset flag.
* ADBIO (0x84) reads back its direction bits and the pads (Portfolio clio.h RWDIR /
  RWPADS; the pads as this core drives them, its output latch). It read the unconnected
  inputs, 0, so Portfolio's read/modify/write updates (cdipir.c) dropped the ROM bank
  select.

**Audio DMA (fixes to `MADAM_EXTPIF.sv`, `MADAM_AG.sv` and `CLIO.sv`).** Checked
against the DMA description in WO 94/10641:

* A transfer whose length ran out in the middle of a burst went on into the next
  buffer even when there was none (next address 0): it read from, or for the DSP's
  output FIFOs wrote to, address 0. The loop test now ends the burst when the next
  address is 0 ("These values of zero are used as control flags").
* A complete transfer (no next buffer) started again when the DSP's FIFO asked for
  more, at address 0. MADAM now tells CLIO which block ends loop and which complete
  (both still interrupt, as in Opera; Portfolio queues the next buffer from that
  interrupt), and a complete transfer clears the channel's DMA enable, which
  Portfolio sets again with every buffer (dsphSetDMANext, dsphSetFullDMA).
* A CPU write of an audio channel's current address or remaining length sets its
  next address or next length to zero in the next clock, as the patent describes
  (channels 0x00-0x0C and 0x10-0x13).

Not changed: a buffer that runs out in the middle of a burst and loops continues
the burst without an interrupt for that buffer end. Test 13 of the test BIOS checks
the three on the real system: a DSP program fills output FIFO 0 for a 4-word
transfer to memory with no next buffer.

**DSP core (fixes to `CLIO_DSP.sv`).**

* An arithmetic instruction without operands (INC, ACC transfer, ADDC...) computes in
  the clock it is fetched, before its timing is stored, and took the timing of the
  instruction before it (the other fields were already taken from the decode). After a
  reset that was none: the computation never ended and the DSP computed nothing more.
* Every frame starts with the accumulator and the flags clear (Opera); they carried over
  from the frame before.
* A shift with its control from an operand (BS = 1000) stored the instruction's own BS
  field instead of the operand (bits 3-0 the shift, bit 4 logical), and counted that
  operand among the instruction's operands, so the fetch ended one early and the result
  was never written to its output address. The count leaves it out, as the DSP patent
  says (WO 94/16383: "It does not include a Barrel Shifter operand") and MAME's DSPP
  does ("Implicit barrel shift", `++numops`); the Opera emulator counts it.
* INC and DEC added 1 to the 16-bit word (bit 4 of the 20-bit ALU): 16 times too much.
  They add 1 to the ALU's LSB, as in Opera (+0x1000 on its 32-bit Y) and MAME; a word
  goes up by one every 16 INCs. In comparisons of 4,100 programs with Opera's routines,
  these were every DSP difference.
* An arithmetic operand with an indirect address (D_I) took the pointer as the operand
  and lost the output write after it; it now reads the operand through the pointer, as
  the register operands' indirect forms already did.

**Expansion bus (fixes to `CLIO_XBUS.sv`).**

* XB_DMARESET (0x400 bit 14, "also does a flush", Portfolio clio.h) was ignored: a
  transfer stalled on the full FIFO kept its words and blocked the next one. It now
  stops the DMA and empties CLIO's expansion FIFO.
* The control register reads back the DMA direction, DMA on and reset bits at 0x400
  and 0x404 (they read 0).

`tb_clio` checks these on the CLIO module, accessed as MADAM does, with DSP programs
and a DMA refill, and the FIFO modules against a reference queue (before the timer and
interrupt fixes 30 of 63 checks fail; before the FIFO and DSP fixes 4,886 of 5,729;
before the DSP core, empty-FIFO and frame fixes 46 of 5,788; before the input FIFO
head and same-clock read fixes 9 of 5,867; before the 64-word output FIFOs 13 of
5,894), and test 10 of the test BIOS from the CPU. Its sections 8 and 9 check the shifts
and the expansion bus control (the testbench takes the expansion DMA's words as MADAM
does), 6c the input FIFO head word and 7g the same-clock read, through both address
ranges of the data memory (its 256 words are at 0x100-0x1FF and again at 0x200-0x2FF),
5b the output FIFO depth (40 words written with the DMA off all wait, the status reads
40, with the DMA on they come out six per burst with one request per burst and no
further DSP write, and the DSP's flush (0x3FD) requests the rest), and 5c a pause of
the 3DO while the DSP runs on: a Killing Time-like run of 24 output words with the 3DO
paused (IO_EN low) for 800 MCLKs at the first DMA request finishes during the pause, all
24 words wait, and come out in four bursts after it, each requested as six words remain
(the flush, issued while the first request was pending, is ignored, as in the original).

`tb_dsp_kt` runs the real CLIO on a game's DSP program with the I memory, the input
FIFO words and the CPU's writes (DSP memory, FIFO resets, DMA enables) of an
instrumented Opera run, playing MADAM for the DMA (buffer ends included), and logs the
DSP's writes and FIFO reads tick by tick for a comparison with Opera's per-instruction
trace. With Killing Time's intro program (9,560 ticks, two symbol-table reloads) every
tick's writes now match Opera's; before the fixes the first FIFO read of every tick
was a word late. `+dma_lat=<n>` serves every DMA request n MCLKs late and
`+dma_hold=<n> +dma_hold_every=<m>` holds every m-th one n MCLKs more (a pause of the
3DO); the harness fails when a DSP output write is lost on a full FIFO. It serves one
request at a time, so the latency loads the bus for every channel of the game's traffic
(three output and four input channels a frame): with the hardware's 8-word output FIFOs
nothing is lost at 10 MCLKs, 12 words at 20, 4,306 at 40, and 13,684 with
`+dma_lat=40 +dma_hold=300 +dma_hold_every=16`; the 64-word FIFOs lose nothing in any of
these. The suite runs `+dma_lat=10` and the hold configuration; the output matches
Opera's in both. The harness's audio clock is the core's (16.9344 MHz from the 50 MHz
clock, 44.1 kHz frames of ~567 MCLKs); its first version divided the clock by an integer
and gave 768-MCLK frames, a third more time for the DSP program than the real frame
leaves it, which the arm60_suite review found (the numbers above are at the real rate).
The whole-system simulation (`tb_boot +dsp_trace_from_ms`, whose trace counts the lost
output words) is where the real MADAM's timing shows: on the v0.6 RTL half a second of
Killing Time's intro lost 7,899 output words in 2,262 of 22,068 frames. The trace files
are not in the repository (they hold the game's code).

**Matrix engine (fix to `MADAM.sv`).** MADAM's matrix multiply summed signed products in
an expression made unsigned by an unsigned `'0` (SystemVerilog takes the signedness of
the whole expression from all its operands): the factors were zero-extended, so a
negative factor gave a wrong product (-0.5 x 0.5 = 7FFFC000 instead of FFFFC000). This
is in the MiSTer core too. The 3D games' transformations (and the perspective divide of
command 3) go through it. The CPU's reads of the matrix (0x600-0x63C) returned entry 0
at every address: the matrix memory was read only at the engine's address. `tb_math`
(MADAM module, 120 matrix commands of each kind, each with the matrix and vector read
back; 1,747 of 2,999 checks fail before) and test 11 of the test BIOS check it.
MSYS (0x04) is read only, as in Opera: it reports the memory configuration MADAM
decodes the DRAM from (Portfolio's kernel only reads it), and a write of 0 turned the
DRAM off. `tb_math` checks it first.

Not changed: the perspective divide's quotient is cut to bits 47..16 before it scales
rows 0 and 1, so 4/3 gives 0x15554 where Opera keeps the full quotient (0x15555); only
the console can tell which precision MADAM has.

**VRAM in the SRAM (`vram_sram.sv`, `sram_sec.sv`).** Every access to the SDRAM other
than the 3DO's own DRAM cycles (a read-transfer fill, a write-transfer burst, each random
VRAM write of the CPU or the CEL engine, a CD sector) first pauses the whole 3DO, video
DMA included, because the 3DO's DRAM uses the same SDRAM in lock step (the board's two
SDRAM chips share one bus). The board also has a 512 KiB asynchronous SRAM on a bus of
its own, which nothing else uses: VRAM there needs no pause. Eight 64 KiB VRAM blocks are
in it: MiSTer's BRAM4 and BRAM2 windows and the BRAM1 block (the per-game table moves
them to where a game keeps its frame buffers) and the highest block left, by default VRAM
0x80000-0xFFFFF, where Portfolio keeps its screens (the BIOS's and Cannon Fodder's frame
buffer is at 0xC0000). MiSTer's default placement (0x00000-0x6FFFF) left them in the
SDRAM, where every access pauses the 3DO, video DMA included: the top lines of the BIOS
screens showed stale data in every VRAM mode. `ddram.sv`, its lazy flash fill, the read-transfer cache and
`ddr_bridge.sv` are unchanged: each request of the bridge's 16-bit word stream goes to
the SRAM or to the SDRAM by its address. `sram_sec.sv` drives every SRAM pin from an I/O
block register (the Game Bub fork's SRAM controller found on the board that fabric
delays between the pins corrupted writes) and WE from an ODDR, both edges in the middle
of a cycle; two cycles of `clk_mem` per word (10 ns WE pulse, data taken 20 ns after the
address leaves its register) or three with the "safe timing" setting. A half-row fill
takes 10.4 µs from the SRAM (5.8 µs from the SDRAM, but with the 3DO paused), still a
beat (two columns of each VRAM half) every 80 ns, ahead of a line's serial read-out.
On hardware this removed the pauses between Microcosm's animated sequences.
`sim/models/sram_model.sv` checks the controller against a 10 ns part's datasheet times
with the routed design's I/O delays; `tb_rtcache` and `tb_top` run in all three modes.

Host file data is stored exactly as received. The byte order of the MCU's words is
detected from the Opera volume header of a preloaded ISO; otherwise little-endian is
assumed. Streamed sectors always arrive as little-endian words (the fork's protocol).

**ARM reset exception (fix to the MiSTer CPU).** The BIOS boots a disc through a
software reset (CLIO `CSTAT` bit 4, the "DIPIR reset"). The ARM6 core entered it like a
SWI: it set the I bit but left F (FIQ disable) as the interrupted code had it. As on the
ARM60 (and in the Opera emulator), a reset now disables FIQ too. Without this, the
pre-reset kernel's vertical-blank FIQ handler kept running through the reset. Once the
BIOS loaded the disc's operating system over that kernel, the handler jumped into the new
code and the CPU crashed (Wolfenstein 3D with the FZ-10 BIOS, 4.8 s after power-on).
`tb_top` checks the CPU state after a CLIO software reset (test 8 of the test BIOS).

**ARM60 (fixes to `ARM6_CORE.sv`, `ARM6_pkg.svh` and `ARM6_RB.sv`).** Two audits of the
CPU against the ARM60 datasheet found ten differences, all fixed:

* `MSR PSR_flg,#imm` was not decoded (it ran as no operation).
* MSR to the SPSR ignored the `_flg` form and replaced the whole SPSR, so the saved mode
  and interrupt masks were lost. MSR now follows the ARM60: the `_flg` forms write the
  condition flags only, the register form the whole PSR (the flags only in User mode).
  This replaces the field masks of upstream's `4970e53` (ARMv4 semantics).
* A word load (LDR, SWP) from an address that is not word aligned was not rotated. It is
  now rotated right by 8 times A[1:0], as the ARM60 does in either endianness; LDM is not
  rotated.
* STM with the S bit stored the current bank, not the User bank, when R15 was in the
  list.
* LSR #32 (the LSR #0 encoding) did not shift.
* LSL and LSR by a register amount of 64, 96 ... set the carry from the unshifted value
  instead of clearing it.
* Undefined instructions, and coprocessor instructions (there is no coprocessor), ran as
  no operations. They now take the undefined instruction trap: Undefined mode, SPSR_und,
  R14 = address + 4, vector 0x04. Other codes that are not defined do not trap, as on the
  ARM60.
* A write to R15 with bits [1:0] set (MOV PC, LDR PC, LDM {PC}) kept them, so every later
  read of the PC and every PC-relative address was off by them. R15 now reads with bits
  [1:0] zero; the fetch addresses still carry them on A[1:0].
* LDRT, STRT, LDRBT and STRBT (post-indexed with the W bit) made a privileged transfer.
  Their transfer cycle now has nTRANS LOW (a User mode access) in any mode. MADAM does
  not use nTRANS.
* The synthesised register bank wrote registers while the core was paused (EN low); the
  write enables now include EN, as the simulation-only bank's did. EN is tied high in
  this core.

`tb_arm6` runs an instruction set test (`sim/tb/arm6_isa.S`, 105 checks against values
from the datasheet) on the core, paused (EN low) at pseudo-random points. The core before
the fixes fails 30 of the checks. With every fix except the last three it fails 26 (39
when paused) and crashes after the R15 writes. With the R15 fix alone added, it fails 4
(the nTRANS checks), and 7 when paused.

`tb_arm6 +fiq +irq` with `sim/tb/arm6_fiq.S` checks interrupts: a kernel modelled on
Killing Time's EZFlix video decoder as Opera executes it (User mode, packed-byte
AND/ORR/ADD/SUB with immediate shifts, masks in r8-r11, the stream read with
`LDMIA r12!`, stores with `STMIA`/`STMDB`, `LDMIB` with writeback, LDM with the base and
PC in the list, no stack) runs once with interrupts masked and once with the testbench
taking nFIQ and nIRQ low at pseudo-random points, with the core also paused at random
points. The FIQ handler alternates a short path with a task-switch-like one (the User bank
saved with `STM ^`, every register clobbered, restored with `LDM ^`); both return with
`SUBS PC, R14, #4`. The outputs must be the same (5 checksums); a handler that skips the
restore fails it. The core passes (86 FIQs and 80 IRQs taken in the kernel).

**Cel engine, pixel processor and display path (fixes to `MADAM_SE.sv`, `CLIO_VIDEO.sv`
and `CLIO_CLUT.sv`).** Four audits of MADAM's cel engine and CLIO's display path against
the 3DO documentation found fifteen differences, all fixed:

* The pixel processor's final sum was 8 bits wide and, when not subtracting, was tested
  for overflow before its sign: with a sign-extended secondary source (AV bit 1) a
  negative result came out as 31 (white) instead of 0 (136 of 8,192 cases in the
  audit's sweep). The sum (-32 to 155) is now 9 bits wide, clamped to 0..31 unless AV
  bit 2 lets it wrap.
* With MS = 10 the primary divider is the decoder component's two LSBs; for 00 (divide
  by 16) the core used PIXC's DF instead.
* In a VDL display control word, 11 in the 2-bit subposition and blue LSB source fields
  (line and window) means "maintain prior setting" (the SDK's `VDL_*_NOP`, US patent
  5,502,462 Table 6); the core stored it as a setting of its own. (The SDK's default
  display control word sets these fields explicitly, so games that use it are not
  affected.)
* The CLUT bypass (pen MSB set) filled the 3 low bits of each 8-bit component with the
  component's own 3 LSBs. They are now zero, the component's 3 MSBs with MSBREP, or a
  pseudo-random value with RNDM (US patent 6,191,772; the console's generator is not
  documented, a 15-bit LFSR here).
* A VDL colour word that sets only the red or only the blue component (bits 30-29 = 11 or
  01) was written to the background entry instead of its own entry: bit 29 was taken for
  "background", which is the 111 word type.
* NOBLK clear (a cel flag) writes a result of 000 as 100 (red 1), which looks black but is
  not taken for background; the core wrote 000, so the background colour showed through
  black parts of cels. The computed blue LSB counts for this black detector only when
  B0POS = 2 puts it in the pen (WO 94/10642, after Table VI).
* The engine control word's CFBDLSB and IPNLSB (WO 94/10642 Table VI; the SDK's
  `CFBDLSB_*`, `PDCLSB_*`) select the blue LSB of the frame buffer pixel and of the
  decoder's pixel as they enter the pixel processor: 0, bit 0, bit 4 or bit 5. The core
  always used bit 0 (the SDK default, so most games are not affected). An unpacked cel
  ("totally literal") takes the decoder's selection from its second preamble word
  (PRE1 TLLSB, Table IX), as in the Opera emulator.
* SWAPHV (swap the subposition bits H and V, pen bits 0 and 15, for B0POS / B15POS =
  "same as source") applied even when an unpacked cel's PRE1 has NOSWAP.
* CFBDSUB (the engine control default) takes H and V from the frame buffer pixel instead
  of the cel when the pixel processor reads the frame buffer (1S = 1 or 2S = 2); the core
  always took the cel's. The Opera emulator has its version of this disabled ("causes the
  wing commander 3 movies to screw up"); it substitutes them without that condition.
* CLIO's display control word bit 10 (SwapPENms, the SDK's swapPenVH) swaps the pen's MSB
  and LSB before CLIO uses it (so the swapped MSB decides the CLUT bypass); the core
  ignored it.
* The CPU's PLUT access (0x03300180-0x033001FF, SDK madam.h) used the engine's
  addresses: a write went to the entry pair the last PLUT DMA load would fill next
  (writing 0x188 changed entries 0 and 1, not 4 and 5), and a read returned the entry
  the current pixel selects. A write to 0x180 + 4n now sets entries 2n (bits 31-16) and
  2n+1; a read of 0x180 + 4n returns entry n. Test 12 of the test BIOS checks it from
  the CPU (fails at the first read before).
* SPRSTOP (0x03300104) was not decoded, so the cel engine could not be aborted (the SDK's
  DrawSprytes writes it when a cel list runs too long). It now resets the engine's state
  (SPRON and the pause clear) but not the registers the CPU and the CCB DMA write.
* The regional fill's end below the clip rectangle (ASCALL) compared the row with the clip
  Y limit taken as signed: a limit of 1024 to 2047 (2047 is the largest, "no clipping")
  was negative, and every regional fill ended at once. The limit is unsigned, as in the
  clipping tests next to it.

* A VDL download (the display list's control and colour words, captured from both
  VRAM serial ports at once in the horizontal blanking, US patent 5,502,462) went
  down CLIO's pixel path as well: each word became a dot in the video encoder's line
  buffer. On a line without picture data (a letterbox border, for instance) a
  34-word download put 34 coloured dots at the line's left edge. Only single-port
  captures inside the line's read window are pixels now.
* CLIO accepted palette (VDL colour) words only inside a fixed window of the
  horizontal blanking, but MADAM starts a pending download whenever it gets the bus
  after that window opens. A download that started late (MADAM busy or paused) lost
  its last words: in a fade to black, entries 24-31 and the background kept their old
  colours for a frame. A VDL word (both serial ports captured together) now writes the
  palette wherever it falls; pixels never do.
* The video encoder kept its dot clock and blanking outputs as they were while the
  3DO was in reset (including every BIOS software reset). The capture to the Game
  Bub framebuffer keeps running, and a dot clock held at 1 sent a dot every clock:
  one malformed frame. In reset the encoder now outputs blanking and no dot clock.

Not changed: a partial PLUT load (fewer than 32 entries) starts at entry 0. The patent
describes loading into the bank PIPA selects; the Opera emulator also loads at entry 0,
so only the console can tell.
* A display control word with COLONLY ("colors only after this point") did not stop the
  later display control words of the same VDL entry from loading. They are now ignored
  until the next CLUT download window.

Against the Opera emulator (audit, November 2026):

* A VDL entry that does not load the current-line address (LDCURR clear, a palette-only
  entry) still set the field line from bit 1 of its (ignored) address word. On an odd
  line the line repeated the one above and every line below the entry moved down one.
  Only an entry with LDCURR sets the field line now (Opera's `vdlp_process_vdl_entry`).
* A VDL entry with no optional words (ListLen 0) shifted 64 words to CLIO: the count
  wrapped, and the words after the entry (the next entry's header among them, taken as
  colour words) changed the palette and display control. It shifts none now (Opera; the
  patent: "a number of optional additional control words ... if any").
* A cel's P-mode override 01 forced the first PIXC half. Only 10 (first half) and 11
  (second half) override; 01 uses the pixel's P-mode bit, as 00 does (Opera; the SDK
  defines 00, 10 and 11). Cels with two different PIXC halves were processed with the
  wrong one (a subtracting half shows as inverted colours).
* MADAM's arbiter acknowledged line-start and mid-line video requests with one signal. A
  mid-line grant while the line-start request was also pending acknowledged both, and
  the line got no transfers (the rest of the frame a line behind). Each has its own
  acknowledge now. A pending mid-line request is also posted only when no video sequence
  is on the bus: posting changed the register a running mid-line sequence advances.

`tb_viddma` checks these four on the real SPORT, arbiter, address generator, CLIO video
and encoder (all four fail before the fixes), `tb_gfx` the PIXC half per pixel for every
override value.

Against the Opera emulator, part 2 (cel engine, VDL processor, CD drive and XBUS):

* A VDL entry with header bit 18 set (VDL_RELSEL: the next entry's address is relative)
  went to the entry's address + 0x14, whatever its word 3 said, and the list fell apart.
  The next entry is now word 3 + the entry's address + 16 (the patent: REL = target -
  PC - 4; Opera `next_entry += curr_vdl + 16`). Portfolio's own VDLs are absolute; a
  game building relative ones got a broken display. Test ROM test 16 chains a relative
  entry to one 0x100 bytes further on and reads MADAM's next VDL address (0x584) back.
* Face culling on the cel engine's 1:1 path (HDX or HDY 1.0, VDY or VDX 1.0, no HDDX or
  HDDY) took the winding from the span's direction, the sign of HDX (or VDX) alone. A
  cel flipped up and down, or turned 90 degrees, with only one of ACW / ACCW was drawn
  when it should have been culled, and the other way round; the same cel at another
  scale (region fill) was right. The winding there is now the sign of HDX * VDY - HDY *
  VDX (Opera `TestInitVisual`). Test ROM test 17 draws a 4x4 cel on MADAM as stored,
  flipped and turned, with ACW or ACCW only, and counts its pixels.

Checked and left as they are: the PLUT load length (4, 8 or 16 words by BPP is the
patent's; Opera loads fewer), SKIP cels not loading state, a null next CCB pointer
without LAST, the default AMV for formats without one (Opera's 0x49 looks like an
emulator convention), the VDL frame-start line in PAL, background detection (the RTL
follows the patent's subposition bits). On the CD drive, commands the core does not
answer (seek, spin down, inject, reset, mode sense), Abort and Flush not dropping a
buffered block and the expansion interrupt being edge-latched differ from Opera but
match SataTo3DO, a drive emulator proven on hardware; they stay until a game shows one.


`tb_gfx` checks the pixel processor (224,608 whole pens: every PIXC field, NOBLK, the
blue LSB selections, B0POS / B15POS with SWAPHV, NOSWAP and CFBDSUB, against a model
written from the documentation and the Opera emulator's math, in full precision) and
the display path (the control word fields, COLONLY, the pen swap, the bypass expansion
and single-component palette writes, VDL downloads against pixel lines with real line
timing), the video encoder's outputs in reset, and the cel engine's SPRSTOP and clip
Y end (engine control by the CPU interface and the interrupt request). Before the first four
fixes it fails 20,252 of the first 224,693 checks; before the second four, 51,344 of
224,724; before the next five, 28,053 of 224,732; before the next two, 16 of 224,821;
before the P-mode override fix, 7 of 224,901. The
secondary divider code AV[4:3] = 11 ("use the two lowest bits of the color component",
divided by 4 here) is not checked: documentation, core and emulator differ.

Upstream files that were modified are marked with `GameBub` / `Game Bub port` comments.

**Upstream version.** The core follows the MiSTer 3DO core up to commit `2cf0583`
(2026-11-07), except `3ec27de`; the port was made from `b419cbb` (2026-11-05). Merged
since:

* CLIO RandSeed (0x38) and RandSample (0x3C), which had read as 0: the BIOS's audio CD
  player hung drawing a random track order (`6fcc997`, `af289c3`).
* ARM6: the MSR CPSR instruction, ASR #32, and the carry of zero-count shifts
  (`4970e53`; its MSR field masks are replaced by the ARM60's, see *ARM60*).

Not merged: `3ec27de`, MADAM's address decoding for other DRAM sizes (4 or 8 MB, an
experimental menu option). On Game Bub the extra DRAM would be in SDRAM banks 0/1 above
row 1023, where a preloaded ISO goes, so the option could not be offered; and its
comparators against size-dependent limits put MADAM's DMA address path into the SDRAM
controller 1.1 ns over its 10 ns budget. With the standard 2 MB + 1 MB both decode the
same addresses, except one word just past the end of VRAM that the new code also selects.

## Building

Requirements: Vivado 2023.2 or later (as the framework documents), a JDK (11 or later),
and Python 3.12 or 3.13. On Python 3.14 the framework's pinned `pex` dependency fails to
install.

Vivado 2018.3 also builds the core: `tools/build_vivado2018.sh` runs the framework flow,
removes the two `xpm_fifo_async` parameters that the 2018.3 XPM library does not have
from the generated wrappers, sets timing-driven implementation directives and fails if
timing is not met.

```
git clone --recurse-submodules https://github.com/apolkosnik/3DO_GameBub
cd 3DO_GameBub
./mill root.buildCore --target gamebub_rev4
```

The bitstream is written to `build/P3DOCore-gamebub_rev4/P3DOCore-gamebub_rev4.bit`.

## Simulation

Verilator 5 and an ARM cross assembler (`arm-none-linux-gnueabihf-`, or set `CROSS=`)
are needed.

```
sim/lint.sh                    # Verilator lint of the whole core
sim/run_tb.sh tb_div           # MADAM divider vs. LPM_DIVIDE semantics (20k cases)
sim/run_tb.sh tb_gfx           # MADAM pixel processor, CLIO display control word and CLUT bypass
                               # vs. the 3DO documentation
sim/run_tb.sh tb_viddma        # MADAM video DMA: line-start / mid-line acknowledges, mid-line register
                               # choice, field line across VDL entries, VDL entries with ListLen 0
sim/run_tb.sh tb_lightgun      # the light gun (count, buttons, off screen; NTSC, PAL) and the mouse
                               # (packets, clamp, 96-count reads) on the control port
sim/run_tb.sh tb_dsp_kt +nmem=... +imem=... +fifo=... +cpu=... +ticks=N +log=...
                               # the CLIO DSP on a game's program and input from an instrumented Opera
                               # run (see the CLIO section), for a tick-by-tick comparison with Opera;
                               # +dma_lat / +dma_hold make MADAM late (lost output words fail the run);
                               # the suite also runs +dma_lat=10 and +dma_lat=40 +dma_hold=300 +dma_hold_every=16
                               # the Opera patch and the scripts are in sim/tools/dsp_kt/
sim/run_tb.sh tb_clio          # CLIO interrupt summary, timer cascade, timer controls, TimerSlack,
                               # DSP output memory and FIFO status, FIFOs (DSP reads during DMA refills),
                               # DSP instructions without operands, frame start state, empty input FIFOs,
                               # the input FIFO head word (CPU's, then the FIFO's), same-clock reads,
                               # the 64-word output FIFOs drained by the DMA (a request per burst, flush),
                               # a pause of the 3DO while the DSP runs on,
                               # frame reload value, audio lock, shifts with operand control,
                               # XBUS control read-back and DMA reset flush, indirect operands,
                               # CSTAT writes, ADBIO read-back
sim/run_tb.sh tb_math          # MADAM matrix engine: 4x4, 3x3 and 3x3 with divide vs. signed reference,
                               # matrix and vector read-back, MSYS read only
sim/run_tb.sh tb_arm6          # ARM60 core vs. datasheet: shifts, MSR, unaligned loads, STM/LDM ^,
                               # undefined instruction trap, R15 writes, LDRT/STRT nTRANS, with the
                               # core paused at random points (needs sim/build_testrom.sh first)
sim/run_tb.sh tb_arm6 +bin=build/sim/arm6_fiq.bin +fiq +irq
                               # ARM60 interrupts: a video-decoder-like kernel in User mode with FIQs
                               # and IRQs injected at random points vs. the same kernel uninterrupted
sim/run_tb.sh tb_sdram         # SDRAM controller vs. timing-checking SDRAM model, including the 3DO
                               # refreshing just as the controller's own refresh comes due
sim/run_tb.sh tb_rtcache       # VRAM read-transfer cache and ddram.sv: coherence vs. reference VRAM model,
                               # CEL-engine framebuffer writes during cache fills, VDL frame buffer hints,
                               # page copies with video transfers between their read and write transfers,
                               # a line's two transfers apart with the first missing, write transfers
                               # with the VRAM halves out of step, write masks in on-chip, SRAM and
                               # SDRAM rows, split transfers after writes; +sram_mode=0/1/2 (VRAM
                               # memory setting)
sim/build_testrom.sh           # assemble the test BIOS (sim/tb/testrom.S), sim/tb/arm6_isa.S and
                               # sim/tb/arm6_fiq.S
sim/run_tb.sh tb_top           # whole core: boots the test BIOS (21 tests, among them an EZFlix-like
                               # in-place video decode into screens in the SDRAM); checks the Buttons setting
sim/run_tb.sh tb_top +be       # same with a big-endian host
sim/run_tb.sh tb_top +stream   # same, with the disc read through a model of the streaming firmware
```

Each testbench ends with `PASS` or `FAIL`; a failure (or a missing file or argument)
ends the simulation with `$fatal`, so `run_tb.sh` exits with a non-zero status.

```
VARGS="+define+TB_TOP=tb_boot" BUILD=build/sim_boot sim/run_tb.sh tb_boot \
    +bios=/path/to/panafz10.bin "+disc_bin=/path/to/game.bin" +run_ms=16000 +frame_every=30
```

`tb_boot` boots a real BIOS, with a disc either streamed from a raw `.bin`
(`+disc_bin=`, served the way the streaming firmware does) or preloaded from an ISO
(`+iso=`). It writes framework video frames to `build/sim/frames/` (PPM; `+out=<dir>`
for another directory), logs every CD command and checks every streamed sector against
the image, checks every random VRAM write that goes to the SDRAM and that every video
line has had its VRAM transfers before it starts, dumps VRAM as an image
at the end and measures stale serial reads during VRAM read transfers. If the CPU runs
outside the memory map, the last CPU bus cycles are written to `cpu_trace.txt`. About
2.5 ms of 3DO time per second of wall time. It fails on any TB error (a video line that
started late while the 3DO was paused is one, see *Limitations*) or SDRAM model error.

It also keeps a shadow of VRAM, updated from the VRAM bus by its semantics (random
writes, flash writes, read and write transfers under their write masks, with the CPU's
SPORT transfers on their own serial register). The destination-row reads of masked
writes are checked against it too. Every beat a read transfer gets from the SDRAM path (cache or
`ddram.sv`) must match the shadow row as it was when the transfer started, and at the end
all of SDRAM-backed VRAM must match the shadow. It counts the page copies that had a
video or VDL transfer between their two halves. `+vram_watch=<row>` (hex) logs one VRAM
row's events, from `+vram_watch_from=<ms>` on: the shadow's, and those of `ddram.sv` and
the cache. `+vram_watch_col=<col>` also logs the writes to one column pair of the row from
power-on, and every change of that 64-bit word in the SDRAM model (with its flash-cleared
flag and the row's clear colour), together with what the SDRAM's second port was doing.
At the end it prints how many split read transfers were skipped because the video serial
register already held their half-row, and the late lines per second.

If the 3DO stays paused for 500 µs, the memory system has hung: a TB error; the state of
every pause source (VRAM modules, read-transfer cache, `ddram.sv`, the SDRAM's second
port, MADAM's bus) is printed and the run ends. `+hang_trace_from_us=<µs>` (with
`+hang_trace_us=`) logs every change of those signals to `hang_trace.txt`.
`+sram_mode=0/1/2` selects the VRAM memory setting (default 0, SRAM); the end-of-run check
reads each off-chip VRAM word from the SRAM or the SDRAM model, wherever it is.
`+copy_log_ms=<ms>` logs the CPU's write transfers (page copies) for 50 ms with the video
line each starts in, and whether its source row holds one value (a frame buffer clear).
`+pad_ctl=<file>` presses buttons while the simulation runs: every 50 ms of 3DO time the
file is read again and its new lines carried out, `<button>[+<button>] <hold_ms>` or
`wait <ms>` (buttons `a b x y up down left right l r start select`), to get through a
disc's menus.

The SDRAM model (`sim/models/sdram_model.sv`, used by all of these) puts read data out as
a real part does at the programmed CAS latency, with the board and I/O delays of the routed
design and the slowest common parts' access and hold times (data valid 26.7-33.2 ns after
the READ's `clk_mem` edge). It checks every timing parameter, refresh, that the FPGA drives
DQ when a WRITE is taken, and DQ contention at any time. `+sdram_t_out=`, `+sdram_t_oe=`,
`+sdram_t_back=`, `+sdram_t_ac=`, `+sdram_t_oh=`, `+sdram_t_lz=`, `+sdram_t_hz=` (ns)
run a test at other timing corners; `tb_sdram` and `tb_top` pass at a slow corner
(+4.4/1.9 ns out/back), a fast one (2.0/0.4 ns, tAC 3.5 ns) and with the output enable
8.5 ns late.

`tb_top` runs the complete core against an SDRAM model that checks every SDRAM timing
parameter and refresh. A host model follows the framework's MCU protocol: it loads the
ISO and BIOS, formats NVRAM, then sends SetupComplete and CoreRun. The test BIOS
(ARMv3 assembly) checks:

* DRAM word and byte accesses
* VRAM in all three tiers (BRAM, VDL area, SDRAM overflow)
* ROM data
* NVRAM
* the CD drive through CLIO XBUS: read capacity, and a two-sector read
* SPORT copies and flash writes with write masks (some bits, none, all, different in
  the two VRAM halves) in on-chip, SRAM and SDRAM rows, every word of the destination
  row checked after each (run from DRAM)
* CLIO from the CPU: timer controls and TimerSlack read back, a cascaded timer pair
  right after the low timer's borrow, the INT1 summary in INT0 bit 31
* MADAM's matrix engine: a 3x3 matrix with negative entries times a vector
* the CLIO software reset the BIOS uses to boot a disc: the CPU must restart in
  supervisor mode with IRQ and FIQ disabled, the interrupted state in SPSR and R14

It writes its result to NVRAM, and the testbench reads it back through the host
interface while the core runs. Video timing to the framework (320x240) is also checked.
The simulation compiles the same sources Vivado synthesizes (`sim/prep_rtl.py` removes
the `translate_off` blocks that Verilator would otherwise compile).

## License

GPL-3.0-or-later (see `LICENSE`), like the MiSTer 3DO core it is based on. The Game Bub
framework (`framework/`) has its own license.
