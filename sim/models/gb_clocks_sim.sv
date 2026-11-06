// Testbench replacement for rtl/gamebub/gb_clocks.sv: the clocks are driven
// by the testbench (tb_clk_* signals in the top-level test harness).
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
	assign clk_sys  = $root.tb_top.clk_sys;
	assign clk_mem  = $root.tb_top.clk_mem;
	assign clk_vid  = $root.tb_top.clk_vid;
	assign clk_spi  = 1'b0;
	assign clk_disp = 1'b0;
	assign locked   = 1'b1;
endmodule
