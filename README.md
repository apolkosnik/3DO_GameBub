# 3DO for Game Bub

A port of the [MiSTer 3DO core](https://github.com/MiSTer-devel/3DO_MiSTer) (by srg320) to
[Game Bub](https://gamebub.net/), using the
[Game Bub core framework](https://docs.gamebub.net/developing-cores/overview/)
(XC7A100T FPGA, one 32 MiB SDRAM chip).

**Status: experimental.** It has not yet been run on Game Bub hardware. In simulation,
the core passes its test suite (see below) and the real Panasonic FZ-10 BIOS boots:

* It decompresses its kernel into DRAM and displays the 3DO logo correctly.
* It brings up the CD drive: Read ID, Spin Up, Set Speed, Disc Info and Read TOC, all
  answered by the core's drive emulation.
* It reads the disc's volume and directory sectors.

Commercial discs do not fit yet (see *Limitations*). The SDRAM read-capture timing
(`READ_STAGE` in `rtl/gamebub/sdram_3do.sv`) follows the MiSTer design and may need
tuning on real hardware.

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

**Discs.** With the disc-streaming firmware from the
[neutralinsomniac/gamebub](https://github.com/neutralinsomniac/gamebub/blob/psx/docs/psx.md)
fork (the one its PlayStation core needs), select a `.cue` (or a lone `.bin`). Discs of
any size are read from the microSD card as the game needs them; see
[docs/disc_streaming.md](docs/disc_streaming.md).

With stock firmware, only `.iso` images (2048-byte sectors) of up to 22 MiB work: they
are loaded into SDRAM at startup. `tools/cue2iso.py image.cue` converts a CUE/BIN and
tells you whether it fits. The NVRAM (saves) is stored next to the image as `.sav`. If no
save exists, a blank 3DO NVRAM is created.

### Limitations

* **Stock firmware: discs of up to 22 MiB, as `.iso`.** Larger discs need the
  disc-streaming firmware (see *Discs* above).
* CD audio tracks are listed in the disc's table of contents, but not played (as in the
  MiSTer core).
* PAL games run at 50 Hz, but the handheld's LCD refreshes at 60 Hz, so every fifth frame
  is shown twice.
* Only the 64 KiB "BRAM1" VRAM block is on chip, because the framework's double
  framebuffer uses most of the block RAM. The rest of VRAM is in SDRAM, behind the
  original MiSTer DDR3 logic (`ddram.sv`). Video reads from it go through a prefetching
  cache (below), but CPU and CEL-engine accesses outside the block are slower than on
  MiSTer.
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
| DDR3: VRAM overflow, BIOS, kanji, NVRAM | `ddram.sv` unchanged, on `ddr_bridge.sv` to SDRAM bank 2          |
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

**VRAM read-transfer cache.** MADAM's video DMA loads a VRAM row into the serial
register and starts shifting it out about 160 ns later, and the video beam cannot be
paused. A transfer from the shared SDRAM takes 0.5–6 µs, so before this cache the BIOS
logo came out as garbage: 54,464 stale serial reads measured in `tb_boot`.
`vram_rtcache.sv` serves every external read transfer from 16 half-row entries in block
RAM, and each request prefetches the next two half-rows, because video DMA walks the
framebuffer sequentially. Writes are snooped where they reach SDRAM (and at flash
writes), which keeps `ddram.sv`'s own ordering. BIOS boot result: 99.9% hits and a clean
picture.

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

Host file data is stored exactly as received. The byte order of the MCU's words is
detected from the Opera volume header of the ISO (little-endian if no ISO is loaded).

**ARM reset exception (fix to the MiSTer CPU).** The BIOS boots a disc through a
software reset (CLIO `CSTAT` bit 4, the "DIPIR reset"). The ARM6 core entered it like a
SWI: it set the I bit but left F (FIQ disable) as the interrupted code had it. As on the
ARM60 (and in the Opera emulator), a reset now disables FIQ too. Without this, the
pre-reset kernel's vertical-blank FIQ handler kept running through the reset. Once the
BIOS loaded the disc's operating system over that kernel, the handler jumped into the new
code and the CPU crashed (Wolfenstein 3D with the FZ-10 BIOS, 4.8 s after power-on).
`tb_top` checks the CPU state after a CLIO software reset (test 8 of the test BIOS).

Upstream files that were modified are marked with `GameBub` / `Game Bub port` comments.

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
sim/run_tb.sh tb_sdram         # SDRAM controller vs. timing-checking SDRAM model
sim/run_tb.sh tb_rtcache       # VRAM read-transfer cache and ddram.sv: coherence vs. reference VRAM model,
                               # including CEL-engine framebuffer writes during cache fills
sim/build_testrom.sh           # assemble the test BIOS (sim/tb/testrom.S)
sim/run_tb.sh tb_top           # whole core: boots the test BIOS
sim/run_tb.sh tb_top +be       # same with a big-endian host
sim/run_tb.sh tb_top +stream   # same, with the disc read through a model of the streaming firmware
```

```
VARGS="+define+TB_TOP=tb_boot" BUILD=build/sim_boot sim/run_tb.sh tb_boot \
    +bios=/path/to/panafz10.bin +iso=/path/to/disc.iso +run_ms=1000 +frame_every=6
```

`tb_boot` boots a real BIOS, with a disc either streamed from a raw `.bin`
(`+disc_bin=`, served the way the streaming firmware does) or preloaded from an ISO
(`+iso=`). It writes framework video frames to `build/sim/frames/` (PPM; `+out=<dir>`
for another directory), logs every CD command and checks every streamed sector against
the image, checks every random VRAM write that goes to the SDRAM, dumps VRAM as an image
at the end and measures stale serial reads during VRAM read transfers. If the CPU runs
outside the memory map, the last CPU bus cycles are written to `cpu_trace.txt`. About
2.5 ms of 3DO time per second of wall time.

`tb_top` runs the complete core against an SDRAM model that checks every SDRAM timing
parameter and refresh. A host model follows the framework's MCU protocol: it loads the
ISO and BIOS, formats NVRAM, then sends SetupComplete and CoreRun. The test BIOS
(ARMv3 assembly) checks:

* DRAM word and byte accesses
* VRAM in all three tiers (BRAM, VDL area, SDRAM overflow)
* ROM data
* NVRAM
* the CD drive through CLIO XBUS: read capacity, and a two-sector read

It writes its result to NVRAM, and the testbench reads it back through the host
interface while the core runs. Video timing to the framework (320x240) is also checked.
The simulation compiles the same sources Vivado synthesizes (`sim/prep_rtl.py` removes
the `translate_off` blocks that Verilator would otherwise compile).

## License

GPL-3.0-or-later (see `LICENSE`), like the MiSTer 3DO core it is based on. The Game Bub
framework (`framework/`) has its own license.
