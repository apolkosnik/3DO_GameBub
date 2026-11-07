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
/cores/apolkosnik.3DO/bios.bin      <- 3DO BIOS (1 MiB, e.g. panafz10.bin), required
/cores/apolkosnik.3DO/kanji.rom     <- optional (Japanese BIOS font ROM)
```

The JSON files are in `metadata/`.

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
* CD audio tracks are listed in the disc's table of contents, but not played (as in the
  MiSTer core).
* PAL games run at 50 Hz, but the handheld's LCD refreshes at 60 Hz, so every fifth frame
  is shown twice.
* In PAL mode the 3DO puts out about 288 picture lines, and only 240 of them are captured,
  so part of the picture is cut off (seen on hardware: the top of Cannon Fodder's title).
  With an NTSC BIOS, keep the Region setting on NTSC (or By BIOS); PAL discs then run in
  NTSC mode.
* Only the 64 KiB "BRAM1" VRAM block is on chip, because the framework's double
  framebuffer uses most of the block RAM. The rest of VRAM is in SDRAM, behind the
  original MiSTer DDR3 logic (`ddram.sv`). Video reads from it go through a prefetching
  cache (below), but CPU and CEL-engine accesses outside the block are slower than on
  MiSTer.
* Video lines that start before their VRAM transfer (see *Video lines that started late*)
  are not all gone: before the two fixes there, the Wolfenstein 3D boot had 247 in its
  first 12.5 s, 216 of them from the CPU's CLIO accesses; the remaining ones in its 3D
  intro, where the 3DO is paused for the SDRAM a lot, are being measured.
* One controller. Buttons: Y/B/A = 3DO A/B/C, Start = P (play), Select/X = X (stop),
  L/R = L/R. They can be remapped in the Game Bub menu.

### Settings

* **CD Speed**: delay between sectors: real 2x drive (6.7 ms), MiSTer rate (3 ms,
  default), or fast (0.5 ms).
* **Region**: NTSC or PAL video timing, either by BIOS (a PAL Panasonic FZ-1 BIOS is
  recognised by its checksum, as on MiSTer) or set by hand. Takes effect at the next
  reset.
* **Reset**: resets the 3DO.

## How the port works

| MiSTer                                  | Game Bub                                                          |
|-----------------------------------------|-------------------------------------------------------------------|
| SDRAM: 3DO DRAM (`sdram.sv`)            | `sdram_3do.sv`, same MCLK-locked TDM scheduling, banks 0/1        |
| DDR3: VRAM overflow, BIOS, kanji, NVRAM | `ddram.sv` (two write fixes, below), on `ddr_bridge.sv` to SDRAM bank 2 |
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

`tb_boot +late_diag` reports for every late or nearly late line where the time went
(grant, transfers, pauses by cause, MADAM's bus, the SDRAM work started), and
`+clio_trace=<µs>` traces MADAM's arbitration cycle by cycle.

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
sim/run_tb.sh tb_arm6          # ARM60 core vs. datasheet: shifts, MSR, unaligned loads, STM/LDM ^,
                               # undefined instruction trap, R15 writes, LDRT/STRT nTRANS, with the
                               # core paused at random points (needs sim/build_testrom.sh first)
sim/run_tb.sh tb_sdram         # SDRAM controller vs. timing-checking SDRAM model, including the 3DO
                               # refreshing just as the controller's own refresh comes due
sim/run_tb.sh tb_rtcache       # VRAM read-transfer cache and ddram.sv: coherence vs. reference VRAM model,
                               # CEL-engine framebuffer writes during cache fills, VDL frame buffer hints,
                               # page copies with video transfers between their read and write transfers,
                               # a line's two transfers apart with the first missing
sim/build_testrom.sh           # assemble the test BIOS (sim/tb/testrom.S) and sim/tb/arm6_isa.S
sim/run_tb.sh tb_top           # whole core: boots the test BIOS
sim/run_tb.sh tb_top +be       # same with a big-endian host
sim/run_tb.sh tb_top +stream   # same, with the disc read through a model of the streaming firmware
```

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
2.5 ms of 3DO time per second of wall time.

It also keeps a shadow of VRAM, updated from the VRAM bus by its semantics (random
writes, flash writes, read and write transfers, with the CPU's SPORT transfers on their own
serial register). Every beat a read transfer gets from the SDRAM path (cache or
`ddram.sv`) must match the shadow row as it was when the transfer started, and at the end
all of SDRAM-backed VRAM must match the shadow. It counts the page copies that had a
video or VDL transfer between their two halves. `+vram_watch=<row>` (hex) logs one VRAM
row's events, from `+vram_watch_from=<ms>` on: the shadow's, and those of `ddram.sv` and
the cache. `+vram_watch_col=<col>` also logs the writes to one column pair of the row from
power-on, and every change of that 64-bit word in the SDRAM model (with its flash-cleared
flag and the row's clear colour), together with what the SDRAM's second port was doing.
At the end it prints how many split read transfers were skipped because the video serial
register already held their half-row, and the late lines per second.

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
* the CLIO software reset the BIOS uses to boot a disc: the CPU must restart in
  supervisor mode with IRQ and FIQ disabled, the interrupted state in SPSR and R14

It writes its result to NVRAM, and the testbench reads it back through the host
interface while the core runs. Video timing to the framework (320x240) is also checked.
The simulation compiles the same sources Vivado synthesizes (`sim/prep_rtl.py` removes
the `translate_off` blocks that Verilator would otherwise compile).

## License

GPL-3.0-or-later (see `LICENSE`), like the MiSTer 3DO core it is based on. The Game Bub
framework (`framework/`) has its own license.
