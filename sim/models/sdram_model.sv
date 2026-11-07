// Behavioural model of a 32 MiB x16 SDR SDRAM (8192 rows x 512 columns x 4
// banks, e.g. W9825G6KH / IS42S16160) for the Game Bub 3DO core tests.
//
// * Commands are sampled on the rising edge of the SDRAM clock.
// * Read data follows the CAS latency as a real part does: a word read at
//   edge n is valid at edge n+CL. The SDRAM turns its outputs on T_LZ after
//   edge n+CL-1, the data is valid from T_AC after that edge until T_OH
//   after edge n+CL, and the outputs turn off T_HZ after edge n+CL.
// * Board and FPGA I/O delays are modelled. The forwarded clock (ODDR) and
//   the command, address and write-data registers (packed into the IOBs)
//   reach the SDRAM T_OUT after their clk_mem edge; the DQ output enable
//   (one fabric register for all 16 pins, as the framework has a single
//   direction bit) arrives T_OE after it; read data reaches the FPGA's
//   input registers T_BACK after it leaves the SDRAM. The defaults are the
//   routed design's slow-corner delays (Vivado 2018.3) and the slowest
//   common 100 MHz CL2 parts. At clk_mem = 100 MHz with the SDRAM on the
//   inverted clock, read data is then valid at the FPGA's input registers
//   26.7-33.2 ns after the READ's clk_mem edge. Every delay can be changed
//   with a plusarg (+sdram_t_out=, +sdram_t_oe=, +sdram_t_back=,
//   +sdram_t_ac=, +sdram_t_oh=, +sdram_t_lz=, +sdram_t_hz=, in ns) to run
//   a test at other timing corners.
// * Protocol and timing are checked (errors are counted in `errors` and
//   printed): command before mode register set, ACTIVE on an open bank,
//   READ/WRITE on a closed bank, PRECHARGE too early (tRAS), ACTIVE too early
//   after PRECHARGE (tRP) or ACTIVE (tRC), READ/WRITE too early (tRCD),
//   AUTO REFRESH with a bank open, refresh interval, row open too long (tRAS max),
//   WRITE with the FPGA's DQ outputs not on at the clock edge, and DQ bus
//   contention at any time (the FPGA's outputs on while the SDRAM's are).
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module sdram_model #(
	parameter real T_CK   = 10.0,   // clock period
	parameter real T_OUT  = 4.0,    // FPGA output delay: clock, commands, address, write data
	parameter real T_OE   = 4.0,    // FPGA output delay: DQ output enable
	parameter real T_BACK = 1.7,    // read data: board + FPGA input buffer
	parameter real T_AC   = 6.0,    // access time from clock (CL2)
	parameter real T_OH   = 2.5,    // data hold after the clock
	parameter real T_LZ   = 1.0,    // outputs on after the clock
	parameter real T_HZ   = 6.0,    // outputs off after the clock
	parameter real T_RCD  = 18.0,
	parameter real T_RP   = 18.0,
	parameter real T_RAS  = 42.0,
	parameter real T_RAS_MAX = 100000.0,
	parameter real T_RC   = 60.0,
	parameter real T_RFC  = 60.0,
	parameter real T_REF_MAX = 70000.0, // max gap between AUTO REFRESH (8 postponed 7.8 us refreshes)
	parameter bit  VERBOSE_P = 0
)(
	input              clk,       // SDRAM_CLK as driven by the FPGA
	input              cke,
	input              cs_n,
	input              ras_n,
	input              cas_n,
	input              we_n,
	input       [ 1:0] dqm,
	input       [ 1:0] ba,
	input       [12:0] a,
	input       [15:0] dq_from_fpga,
	input              dq_oe_fpga,
	output      [15:0] dq_to_fpga
);
	real t_out, t_oe, t_back, t_ac, t_oh, t_lz, t_hz;
	initial begin
		t_out = T_OUT; t_oe = T_OE; t_back = T_BACK;
		t_ac = T_AC; t_oh = T_OH; t_lz = T_LZ; t_hz = T_HZ;
		void'($value$plusargs("sdram_t_out=%f", t_out));
		void'($value$plusargs("sdram_t_oe=%f", t_oe));
		void'($value$plusargs("sdram_t_back=%f", t_back));
		void'($value$plusargs("sdram_t_ac=%f", t_ac));
		void'($value$plusargs("sdram_t_oh=%f", t_oh));
		void'($value$plusargs("sdram_t_lz=%f", t_lz));
		void'($value$plusargs("sdram_t_hz=%f", t_hz));
		$display("SDRAM model timing (ns): out %0.2f, oe %0.2f, back %0.2f, ac %0.2f, oh %0.2f, lz %0.2f, hz %0.2f",
		         t_out, t_oe, t_back, t_ac, t_oh, t_lz, t_hz);
	end

	// ------------------------------------------------------------------
	// Delayed view of the FPGA outputs (board)
	// ------------------------------------------------------------------
	reg        clk_d;
	reg        cs_n_d, ras_n_d, cas_n_d, we_n_d;
	reg [ 1:0] dqm_d, ba_d;
	reg [12:0] a_d;
	reg [15:0] dqi_d;
	reg        dqoe_d;
	always @(clk)          clk_d   <= #(t_out) clk;
	always @(cs_n)         cs_n_d  <= #(t_out) cs_n;
	always @(ras_n)        ras_n_d <= #(t_out) ras_n;
	always @(cas_n)        cas_n_d <= #(t_out) cas_n;
	always @(we_n)         we_n_d  <= #(t_out) we_n;
	always @(dqm)          dqm_d   <= #(t_out) dqm;
	always @(ba)           ba_d    <= #(t_out) ba;
	always @(a)            a_d     <= #(t_out) a;
	always @(dq_from_fpga) dqi_d   <= #(t_out) dq_from_fpga;
	always @(dq_oe_fpga)   dqoe_d  <= #(t_oe) dq_oe_fpga;

	// ------------------------------------------------------------------
	// Storage
	// ------------------------------------------------------------------
	bit [15:0] mem [bit [23:0]];   // {bank, row, col}

	function automatic [15:0] peek(input [23:0] addr);
		peek = mem.exists(addr) ? mem[addr] : 16'h0000;
	endfunction
	function automatic void poke(input [23:0] addr, input [15:0] d);
		mem[addr] = d;
	endfunction

	// ------------------------------------------------------------------
	// State and checks
	// ------------------------------------------------------------------
	int  errors = 0;
	bit  VERBOSE;
	initial VERBOSE = VERBOSE_P | $test$plusargs("sdram_verbose");
	int  n_act = 0, n_rd = 0, n_wr = 0, n_pre = 0, n_ref = 0;
	bit  mode_set = 0;
	int  cas_latency = 2;
	bit        open_  [4];
	bit [12:0] row_   [4];
	realtime   t_act  [4];
	realtime   t_pre  [4];
	realtime   t_last_ref = 0;
	realtime   t_ref_gap_max = 0;
	bit        ref_seen = 0;

	initial begin
		for (int i = 0; i < 4; i++) begin
			open_[i] = 0; row_[i] = 0; t_act[i] = -1000; t_pre[i] = -1000;
		end
	end

	task automatic err(input string msg);
		errors++;
		if (errors <= 50) $display("[%0t] SDRAM ERROR: %s", $realtime, msg);
	endtask

	// read pipeline: a word read at edge n comes out after edge n+CL-1
	typedef struct { bit valid; bit [15:0] data; bit masked; } rd_t;
	rd_t rdq [4];
	reg [15:0] dq_out;          // value at the FPGA's input registers while driven
	int        sd_on = 0;       // SDRAM outputs on, at the SDRAM (reads in flight)
	int        fpga_on = 0;     // the same, as seen at the FPGA's inputs (T_BACK later)
	int        dq_tag = 0;
	int        rd_id = 0;
	assign dq_to_fpga = fpga_on != 0 ? dq_out : (dqoe_d ? dqi_d : 16'hxxxx);

	// contention: both sides' outputs on at the same time
	always @(dqoe_d, sd_on)
		if (dqoe_d && sd_on != 0) err("DQ contention: FPGA drives while SDRAM outputs read data");

	always @(posedge clk_d) begin
		bit [2:0] cmd;
		bit [23:0] addr;
		realtime now;
		now = $realtime;

		// shift the read pipeline; the word that comes out after this edge
		// is valid at the next one
		begin
			rd_t cur;
			cur = rdq[0];
			rdq[0] = rdq[1]; rdq[1] = rdq[2]; rdq[2] = rdq[3]; rdq[3] = '{0, 16'h0, 0};
			if (cur.valid) begin
				int id;
				rd_id++;
				id = rd_id;
				fork   // at the SDRAM
					begin
						#(t_lz);
						sd_on++;
						#(T_CK + t_hz - t_lz);
						sd_on--;
					end
				join_none
				fork   // at the FPGA's input registers
					begin
						#(t_lz + t_back);
						if (fpga_on == 0) dq_out = 16'hxxxx;   // turning on: undefined until T_AC
						fpga_on++;
						#(t_ac - t_lz);
						dq_out = cur.masked ? 16'hxxxx : cur.data;
						dq_tag = id;
						#(T_CK + t_oh - t_ac);
						if (dq_tag == id) dq_out = 16'hxxxx;   // after T_OH: undefined
						#(t_hz - t_oh);
						fpga_on--;
					end
				join_none
			end
		end

		if (cke && !cs_n_d) begin
			cmd = {ras_n_d, cas_n_d, we_n_d};
			case (cmd)
				3'b011: begin // ACTIVE
					n_act++;
					if (!mode_set) err("ACTIVE before LOAD MODE");
					if (open_[ba_d]) err($sformatf("ACTIVE on open bank %0d (row %0d open, new %0d)", ba_d, row_[ba_d], a_d));
					if (now - t_pre[ba_d] < T_RP - 0.01) err($sformatf("tRP violation bank %0d (%0.1f ns)", ba_d, now - t_pre[ba_d]));
					if (now - t_act[ba_d] < T_RC - 0.01) err($sformatf("tRC violation bank %0d (%0.1f ns)", ba_d, now - t_act[ba_d]));
					open_[ba_d] = 1;
					row_[ba_d]  = a_d;
					t_act[ba_d] = now;
					if (VERBOSE) $display("[%0t] SDRAM ACT  b%0d r%0d", now, ba_d, a_d);
				end
				3'b101, 3'b100: begin // READ / WRITE
					if (!open_[ba_d]) err($sformatf("%s on closed bank %0d", cmd[0] ? "READ" : "WRITE", ba_d));
					if (now - t_act[ba_d] < T_RCD - 0.01) err($sformatf("tRCD violation bank %0d (%0.1f ns)", ba_d, now - t_act[ba_d]));
					if (a_d[10]) err("auto-precharge is not expected");
					addr = {ba_d, row_[ba_d][12:0], a_d[8:0]};
					if (cmd[0]) begin
						n_rd++;
						rdq[cas_latency-2] = '{1, peek(addr), &dqm_d};
						if (VERBOSE) $display("[%0t] SDRAM RD   b%0d r%0d c%0d -> %h", now, ba_d, row_[ba_d], a_d[8:0], peek(addr));
					end else begin
						bit [15:0] d;
						n_wr++;
						if (!dqoe_d) err("WRITE without the FPGA driving DQ");
						d = peek(addr);
						if (!dqm_d[0]) d[ 7:0] = dqi_d[ 7:0];
						if (!dqm_d[1]) d[15:8] = dqi_d[15:8];
						poke(addr, d);
						if (VERBOSE) $display("[%0t] SDRAM WR   b%0d r%0d c%0d <- %h (dqm %b)", now, ba_d, row_[ba_d], a_d[8:0], dqi_d, dqm_d);
					end
				end
				3'b010: begin // PRECHARGE
					n_pre++;
					if (a_d[10]) begin
						for (int i = 0; i < 4; i++) begin
							if (open_[i] && now - t_act[i] < T_RAS - 0.01) err($sformatf("tRAS violation bank %0d (%0.1f ns)", i, now - t_act[i]));
							if (open_[i]) t_pre[i] = now;
							open_[i] = 0;
						end
					end else begin
						if (open_[ba_d] && now - t_act[ba_d] < T_RAS - 0.01) err($sformatf("tRAS violation bank %0d (%0.1f ns)", ba_d, now - t_act[ba_d]));
						if (open_[ba_d]) t_pre[ba_d] = now;
						open_[ba_d] = 0;
					end
				end
				3'b001: begin // AUTO REFRESH
					n_ref++;
					for (int i = 0; i < 4; i++) begin
						if (open_[i]) err($sformatf("AUTO REFRESH with bank %0d open", i));
						if (now - t_pre[i] < T_RP - 0.01) err("tRP violation before AUTO REFRESH");
						t_act[i] = now;   // tRFC handled as tRC
					end
					if (ref_seen && now - t_last_ref > t_ref_gap_max) t_ref_gap_max = now - t_last_ref;
					ref_seen = 1;
					t_last_ref = now;
				end
				3'b000: begin // LOAD MODE
					if (a_d[2:0] != 3'b000) err("burst length other than 1 is not expected");
					cas_latency = a_d[6:4];
					if (cas_latency != 2 && cas_latency != 3) err("invalid CAS latency");
					mode_set = 1;
				end
				default: ; // NOP / burst stop
			endcase
		end

		for (int i = 0; i < 4; i++)
			if (open_[i] && now - t_act[i] > T_RAS_MAX) begin
				err($sformatf("row open too long in bank %0d", i));
				t_act[i] = now;
			end
	end

	// Refresh interval check while the clock runs
	always @(posedge clk_d) begin
		if (ref_seen && $realtime - t_last_ref > T_REF_MAX && mode_set) begin
			err($sformatf("no AUTO REFRESH for %0.1f us", ($realtime - t_last_ref) / 1000.0));
			t_last_ref = $realtime;
		end
	end

	final begin
		$display("SDRAM model: ACT=%0d RD=%0d WR=%0d PRE=%0d REF=%0d max refresh gap=%0.2f us errors=%0d",
		         n_act, n_rd, n_wr, n_pre, n_ref, t_ref_gap_max / 1000.0, errors);
	end
endmodule
