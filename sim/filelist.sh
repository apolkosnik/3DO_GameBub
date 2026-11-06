# Core RTL in compile order (relative to the prepared RTL directory).
RTL_FILES=(
    compat/altera_compat.sv
    arm6/ARM6_pkg.sv
    p3do/3DO_pkg.sv
    gamebub/gb3do_pkg.sv
    arm6/ARM6_RB.sv
    arm6/ARM6_CORE.sv
    p3do/3DO_mem.sv
    p3do/MADAM_mem.sv p3do/MADAM_ARB.sv p3do/MADAM_CPUIF.sv p3do/MADAM_AG.sv p3do/MADAM_SE.sv
    p3do/MADAM_SPORT.sv p3do/MADAM_PLAYER.sv p3do/MADAM_SLOWBUS.sv p3do/MADAM_EXTPIF.sv p3do/MADAM.sv
    p3do/CLIO_mem.sv p3do/CLIO_CLUT.sv p3do/CLIO_INTERPOL.sv p3do/CLIO_VIDEO.sv p3do/CLIO_DSP.sv
    p3do/CLIO_XBUS.sv p3do/CLIO.sv
    p3do/OSA.sv p3do/VE.sv p3do/P3DO.sv
    p3do/vram.sv p3do/ddram.sv p3do/3DO_CDROM.sv p3do/hps2pad.sv
    gamebub/sdram_3do.sv gamebub/ddr_bridge.sv gamebub/sec_arb.sv gamebub/cdd_emu.sv
    gamebub/gb_host.sv gamebub/gb_util.sv gamebub/p3do_gamebub.sv
)
