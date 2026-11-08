// Simulation-only stand-ins for the Xilinx primitives used by the core.
// gb_clocks (MMCMs) is replaced as a whole by the testbench clock model in
// sim/models/gb_clocks_sim.sv, so only the I/O DDR register is needed here.

// ODDR (7 series). OPPOSITE_EDGE: D1 is taken at the rising edge and output
// for the first half of the cycle, D2 is taken at the falling edge and output
// for the second half. SAME_EDGE: both are taken at the rising edge; D1 is
// output first, D2 from the falling edge on.
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
	reg d2_same;
	initial Q = INIT;
	always @(posedge C) if (CE) begin
		Q <= D1;
		d2_same <= D2;
	end
	always @(negedge C) if (CE) Q <= (DDR_CLK_EDGE == "SAME_EDGE") ? d2_same : D2;
endmodule
