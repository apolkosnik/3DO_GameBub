// Clock generation for the Game Bub 3DO core.
//
// MMCM 0 (VCO 800 MHz from the 50 MHz reference):
//   clk_sys     50 MHz   3DO system clock (MiSTer clk_sys), framework system clock
//   clk_mem    100 MHz   SDRAM / VRAM serial clock (MiSTer clk_mem), phase aligned
//   clk_spi    200 MHz   MCU SPI sampling clock (framework requirement > 160 MHz)
//   clk_disp   800/DISPLAY_DIVIDER MHz  LCD clock
// MMCM 1 (VCO 981.25 MHz):
//   clk_vid   49.0625 MHz   3DO video encoder clock (MiSTer pll2: 49.0908 MHz NTSC)
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module gb_clocks #(
	parameter int DISPLAY_DIVIDER = 31
)(
	input  wire clk_in_50mhz,
	output wire clk_sys,
	output wire clk_mem,
	output wire clk_spi,
	output wire clk_disp,
	output wire clk_vid,
	output wire locked
);
	wire fb0, fb1;
	wire sys_u, mem_u, spi_u, disp_u, vid_u;
	wire locked0, locked1;

	MMCME2_BASE #(
		.BANDWIDTH          ("OPTIMIZED"),
		.CLKIN1_PERIOD      (20.000),
		.CLKFBOUT_MULT_F    (16.000),   // VCO 800 MHz
		.DIVCLK_DIVIDE      (1),
		.CLKOUT0_DIVIDE_F   (16.000),   // 50 MHz
		.CLKOUT1_DIVIDE     (8),        // 100 MHz
		.CLKOUT2_DIVIDE     (4),        // 200 MHz
		.CLKOUT3_DIVIDE     (DISPLAY_DIVIDER),
		.CLKOUT0_PHASE      (0.0),
		.CLKOUT1_PHASE      (0.0),
		.CLKOUT2_PHASE      (0.0),
		.CLKOUT3_PHASE      (0.0),
		.CLKFBOUT_PHASE     (0.0),
		.STARTUP_WAIT       ("FALSE")
	) mmcm0 (
		.CLKIN1   (clk_in_50mhz),
		.CLKFBIN  (fb0),
		.CLKFBOUT (fb0),
		.CLKFBOUTB(),
		.CLKOUT0  (sys_u),
		.CLKOUT0B (),
		.CLKOUT1  (mem_u),
		.CLKOUT1B (),
		.CLKOUT2  (spi_u),
		.CLKOUT2B (),
		.CLKOUT3  (disp_u),
		.CLKOUT3B (),
		.CLKOUT4  (),
		.CLKOUT5  (),
		.CLKOUT6  (),
		.LOCKED   (locked0),
		.PWRDWN   (1'b0),
		.RST      (1'b0)
	);

	MMCME2_BASE #(
		.BANDWIDTH          ("OPTIMIZED"),
		.CLKIN1_PERIOD      (20.000),
		.CLKFBOUT_MULT_F    (19.625),   // VCO 981.25 MHz
		.DIVCLK_DIVIDE      (1),
		.CLKOUT0_DIVIDE_F   (20.000),   // 49.0625 MHz
		.CLKOUT0_PHASE      (0.0),
		.CLKFBOUT_PHASE     (0.0),
		.STARTUP_WAIT       ("FALSE")
	) mmcm1 (
		.CLKIN1   (clk_in_50mhz),
		.CLKFBIN  (fb1),
		.CLKFBOUT (fb1),
		.CLKFBOUTB(),
		.CLKOUT0  (vid_u),
		.CLKOUT0B (),
		.CLKOUT1  (),
		.CLKOUT1B (),
		.CLKOUT2  (),
		.CLKOUT2B (),
		.CLKOUT3  (),
		.CLKOUT3B (),
		.CLKOUT4  (),
		.CLKOUT5  (),
		.CLKOUT6  (),
		.LOCKED   (locked1),
		.PWRDWN   (1'b0),
		.RST      (1'b0)
	);

	// The system, SPI and display clocks are handed to the framework straight
	// from the MMCM, like the Game Bub example core: the framework's XDC refers
	// to them by its own net names (e.g. clk_dpi), and Vivado inserts the
	// global buffers. The two clocks used only inside the core get explicit
	// BUFGs.
	assign clk_sys  = sys_u;
	assign clk_spi  = spi_u;
	assign clk_disp = disp_u;
	BUFG bufg_mem (.I(mem_u), .O(clk_mem));
	BUFG bufg_vid (.I(vid_u), .O(clk_vid));

	assign locked = locked0 & locked1;
endmodule
