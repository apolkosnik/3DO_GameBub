########################################
# 3DO core constraints (Game Bub)
########################################
# The 3DO video encoder clock comes from its own MMCM (49.0625 MHz) and only
# crosses into the system/memory clocks through synchronisers, a dual-clock
# line buffer (VE_LINE_BUF) and a Gray-code FIFO (video_capture).
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clocks/mmcm1/CLKOUT0}]] \
    -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clocks/mmcm0/CLKOUT0}]] \
    -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ */clocks/mmcm0/CLKOUT1}]]

# clk_sys (50 MHz) and clk_mem (100 MHz) are both from MMCM 0 and phase
# aligned. They are timed against each other except through the explicit
# toggle/Gray synchronisers, which carry ASYNC_REG.
