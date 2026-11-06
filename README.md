# 3DO for Game Bub

A port of the [MiSTer 3DO core](https://github.com/MiSTer-devel/3DO_MiSTer) (by srg320) to
[Game Bub](https://gamebub.net/), using the
[Game Bub core framework](https://docs.gamebub.net/developing-cores/overview/)
(XC7A100T FPGA, one 32 MiB SDRAM chip).

**Status: experimental.** The core passes its simulation test suite (see below), but it
has not yet been run on Game Bub hardware. The SDRAM read capture timing in particular
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

The JSON files are in `metadata/`. Select an `.iso` disc image (2048-byte sectors)
when starting the core. Most 3DO dumps are CUE/BIN (MODE1/2352). Convert them with
`tools/cue2iso.py image.cue`, which also tells you whether the disc fits. The NVRAM (saves) is stored next to the image as `.sav`. If no
save exists, a blank 3DO NVRAM is created.

### Limitations

* **Disc size: at most 22 MiB.** The Game Bub framework loads files into the core when
  it starts, and cannot yet stream from the microSD card. So the whole ISO must fit into
  the SDRAM space left over (bank 3 plus the unused rows of banks 0 and 1). This is
  enough for homebrew, demos and small titles, but not for most commercial games. When the
  framework gets core-initiated file reads, `cdd_emu.sv` is the only module that needs to
  change.
* ISO images only (no CUE/BIN, no CD audio tracks).
* NTSC only (PAL video modes are not supported).
* Only the 64 KiB "BRAM1" VRAM block is on-chip. The framework's double framebuffer uses
  most of the block RAM. The rest of VRAM is in SDRAM, behind the original MiSTer DDR3
  logic (`ddram.sv`), so games that render outside that block run slower than on MiSTer.
* One controller. Buttons: Y/B/A = 3DO A/B/C, Start = P (play), Select/X = X (stop),
  L/R = L/R. They can be remapped in the Game Bub menu.

### Settings

* **CD Speed**: delay between sectors: real 2x drive (6.7 ms), MiSTer rate (3 ms,
  default), or fast (0.5 ms).
* **Reset**: resets the 3DO.

## How the port works

| MiSTer                                  | Game Bub                                                          |
|-----------------------------------------|-------------------------------------------------------------------|
| SDRAM: 3DO DRAM (`sdram.sv`)            | `sdram_3do.sv`, same MCLK-locked TDM scheduling, banks 0/1        |
| DDR3: VRAM overflow, BIOS, kanji, NVRAM | `ddram.sv` unchanged, on `ddr_bridge.sv` to SDRAM bank 2          |
| HPS: CD image streaming                 | ISO preloaded into SDRAM, `cdd_emu.sv` emulates the drive back end |
| HPS: BIOS/save loading                  | framework file transfers, `gb_host.sv`                            |
| Altera megafunctions                    | `rtl/compat/altera_compat.sv`, Xilinx-inferable rewrites          |
| combinational `lpm_divide` (MADAM)      | sequential divider, same results (`MADAM_mem.sv`)                 |
| video_mixer / scaler                    | framework framebuffer, 320x240, 18-bit colour (`video_capture`)   |

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

Host file data is stored exactly as received. The byte order of the MCU's words is
detected from the Opera volume header of the ISO (little-endian if no ISO is loaded).

Upstream files that were modified are marked with `GameBub` comments.

## Building

Requirements: Vivado 2023.2 or later (as the framework documents), a JDK (11 or later),
and Python 3.12 or 3.13. On Python 3.14 the framework's pinned `pex` dependency fails to
install.

Vivado 2018.3 also synthesizes the core. However, the framework's generated
`XpmFifoAsync*.sv` sets `CASCADE_HEIGHT`, which the 2018.3 XPM library does not have.
For a local 2018.3 build, delete those lines from `build/*/generated/XpmFifoAsync*.sv`
after the first (failing) run, and run `make` in that build directory.

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
sim/build_testrom.sh           # assemble the test BIOS (sim/tb/testrom.S)
sim/run_tb.sh tb_top           # whole core: boots the test BIOS
sim/run_tb.sh tb_top +be       # same with a big-endian host
```

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
