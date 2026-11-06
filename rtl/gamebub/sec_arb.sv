// Fixed-priority arbiter for the SDRAM secondary port.
// Client 0 has the highest priority. A grant is held until the client's
// transfer is finished (sec_done) and the client has dropped its request.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

module sec_arb #(parameter int N = 3) (
	input              clk,
	input              rst,

	// clients
	input      [N-1:0] c_req,
	input      [N-1:0] c_we,
	input      [23: 0] c_addr  [N],
	input      [ 9: 0] c_len   [N],
	input      [15: 0] c_wdata [N],
	input      [ 1: 0] c_wbe   [N],
	output     [N-1:0] c_wnext,
	output     [15: 0] c_rdata,
	output     [N-1:0] c_rvalid,
	output     [N-1:0] c_done,

	// to sdram_3do
	output             m_req,
	output             m_we,
	output     [23: 0] m_addr,
	output     [ 9: 0] m_len,
	output     [15: 0] m_wdata,
	output     [ 1: 0] m_wbe,
	input              m_wnext,
	input      [15: 0] m_rdata,
	input              m_rvalid,
	input              m_done
);
	localparam W = (N > 1) ? $clog2(N) : 1;
	reg [W-1:0] sel;
	reg         busy;
	reg         wait_drop;   // client saw done, wait for it to drop req

	always @(posedge clk) begin
		integer i;
		if (rst) begin
			busy      <= 0;
			wait_drop <= 0;
			sel       <= '0;
		end else if (!busy) begin
			for (i = N-1; i >= 0; i = i - 1)
				if (c_req[i]) begin
					sel  <= W'(i);
					busy <= 1;
				end
		end else begin
			if (m_done) wait_drop <= 1;
			if (wait_drop && !c_req[sel]) begin
				wait_drop <= 0;
				busy      <= 0;
			end
		end
	end

	assign m_req   = busy && !wait_drop && c_req[sel];
	assign m_we    = c_we[sel];
	assign m_addr  = c_addr[sel];
	assign m_len   = c_len[sel];
	assign m_wdata = c_wdata[sel];
	assign m_wbe   = c_wbe[sel];
	assign c_rdata = m_rdata;

	genvar g;
	generate
		for (g = 0; g < N; g = g + 1) begin : g_route
			assign c_wnext[g]  = busy && (sel == g) && m_wnext;
			assign c_rvalid[g] = busy && (sel == g) && m_rvalid;
			assign c_done[g]   = busy && (sel == g) && m_done;
		end
	endgenerate
endmodule
