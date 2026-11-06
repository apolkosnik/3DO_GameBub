// Simulation-only stand-ins for the Xilinx primitives used by the core.
// gb_clocks (MMCMs) is replaced as a whole by the testbench clock model in
// sim/models/gb_clocks_sim.sv, so only the I/O DDR register is needed here.

module ODDR #(
	parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
	parameter INIT = 1'b0,
	parameter SRTYPE = "SYNC"
)(
	output reg Q,
	input      C,
	input      CE,
	input      D1,
	input      D2,
	input      R,
	input      S
);
	initial Q = INIT;
	always @(posedge C) if (CE) Q <= D1;
	always @(negedge C) if (CE) Q <= D2;
endmodule
