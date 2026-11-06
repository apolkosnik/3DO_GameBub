# Release files

`apolkosnik.3DO/` is the complete core directory to copy to `/cores/apolkosnik.3DO/` on the
microSD card (add `bios.bin`, see the top-level README). Built with Vivado 2018.3 via
`tools/build_vivado2018.sh`; timing met (WNS +0.41 ns), 33% LUTs, 85% block RAM.

This build is for hardware bring-up only: the BIOS boots, but the picture is corrupted by
the VRAM bandwidth limit described in the top-level README.
