// Testbench replacement for rtl/gamebub/gb_clocks.sv: the clocks are driven
// by the testbench (clk_sys/clk_mem/clk_vid in the top-level testbench,
// named by TB_TOP, default tb_top).
`ifndef TB_TOP
`define TB_TOP tb_top
`endif
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
	assign clk_sys  = $root.`TB_TOP.clk_sys;
	assign clk_mem  = $root.`TB_TOP.clk_mem;
	assign clk_vid  = $root.`TB_TOP.clk_vid;
	assign clk_spi  = 1'b0;
	assign clk_disp = 1'b0;
	assign locked   = 1'b1;
endmodule
