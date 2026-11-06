// Lint-only clock stub (no testbench hierarchy available).
module gb_clocks #(parameter int DISPLAY_DIVIDER = 31) (
	input  wire clk_in_50mhz,
	output wire clk_sys, clk_mem, clk_spi, clk_disp, clk_vid, locked
);
	assign clk_sys = clk_in_50mhz; assign clk_mem = clk_in_50mhz; assign clk_vid = clk_in_50mhz;
	assign clk_spi = 1'b0; assign clk_disp = 1'b0; assign locked = 1'b1;
endmodule
