########################################
# 3DO core constraints (Game Bub)
########################################
# The 3DO video encoder clock comes from its own MMCM (49.0625 MHz) and only
# crosses into the system/memory clocks through synchronisers, a dual-clock
# line buffer (VE_LINE_BUF) and a Gray-code FIFO (video_capture).
#
# clk_sys (50 MHz, MMCM 0 CLKOUT0) and clk_mem (100 MHz, CLKOUT1) are phase
# aligned and the MiSTer core uses them together synchronously (MADAM, the
# VRAM, the DRAM interface), so they are one group and timed against each
# other. (Before, each was a group of its own, which left every path
# between them untimed.)
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clocks/mmcm1/CLKOUT0}]] \
    -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clocks/mmcm0/CLKOUT0 || NAME =~ */clocks/mmcm0/CLKOUT1}]]

########################################
# SDRAM interface (sdram_3do.sv)
########################################
# The SDRAM clock is clk_sdram (clk_mem delayed by 1.875 ns, MMCM 0
# CLKOUT4) inverted, forwarded by an ODDR. The command, address, DQM and
# write-data registers are in the IOBs, so they reach the pins with about the
# same delay as the clock; the SDRAM takes them half a cycle plus 1.875 ns
# after they change. The DQ output enable is one register for all 16 pins
# (the framework has a single direction bit), so it stays in the fabric and
# is timed here like the data.
create_generated_clock -name sdram_clk_out -invert -divide_by 1 \
    -source [get_pins -hier -filter {NAME =~ */sdram/sdram_clk_oddr/C}] \
    [get_ports sdram_clk]

set_property IOB TRUE [get_cells -hier -filter {NAME =~ */sdram/SDRAM_* && IS_SEQUENTIAL && NAME !~ */sdram/SDRAM_DQ_OE_reg*}]

# SDRAM timing, the slowest common 100 MHz CL2 x16 parts (W9825G6KH-6,
# IS42S16160J-7, MT48LC16M16A2-75, AS4C16M16SA-7): input setup tIS 1.5 ns,
# hold tIH 0.8 ns, access time tAC 6.0 ns, output hold tOH 2.5 ns. The
# traces are short; 0.1-0.4 ns each way and 0.2 ns of skew between the
# clock and the other lines are allowed for.
set sdram_out [get_ports {sdram_cs_n[0] sdram_ras_n sdram_cas_n sdram_we_n sdram_ldqm sdram_udqm sdram_bs[*] sdram_a[*] sdram_dq[*]}]
set_output_delay -clock sdram_clk_out -max  1.7 $sdram_out
set_output_delay -clock sdram_clk_out -min -1.0 $sdram_out

# Read data: launched by the SDRAM clock edge after the one that takes the
# READ (CL2), valid from tAC after it until tOH after the next one. The IOB
# input registers take it at the second clk_mem edge after that launching
# edge, i.e. 30 ns after the clk_mem edge that issued the READ:
# READ_STAGE = 4 in sdram_3do.sv. (A setup multicycle of 2; the hold check
# then is the next word's launch against the same capture edge.) Capturing at
# 30 ns with the clock not delayed, the hold slack at the fast process corner
# was -1.1 ns; the 1.875 ns delay of clk_sdram moves the data later.
set_input_delay -clock sdram_clk_out -max 6.8 [get_ports sdram_dq[*]]
set_input_delay -clock sdram_clk_out -min 2.7 [get_ports sdram_dq[*]]
set_multicycle_path -setup 2 -from [get_clocks sdram_clk_out] \
    -to [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clocks/mmcm0/CLKOUT1}]]
