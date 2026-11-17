# Release files

`apolkosnik.3DO/` is the complete core directory to copy to `/cores/apolkosnik.3DO/` on the
microSD card (add `bios.bin`, see the top-level README). Built with Vivado 2018.3 via
`tools/build_vivado2018.sh`; timing met (v0.11, build a32: WNS +0.138 ns, WHS +0.024 ns).

From v0.10 the core is built on the Game Bub framework `v1.1.0-beta4` and needs handheld
firmware `v1.1.0-beta4` or later; the disc file is read on demand, so discs of any size
work (see the top-level README and `docs/disc_streaming.md`).
