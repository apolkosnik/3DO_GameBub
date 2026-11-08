// Behavioural model of the Game Bub's asynchronous SRAM (256K x 16, 512 KiB;
// the part on the board is not documented: the defaults are a 10 ns part's,
// e.g. IS61WV25616BLL-10) for the 3DO core tests.
//
// * Board and FPGA I/O delays: address, write data, byte enables, OE and CE
//   (I/O block registers) reach the SRAM T_OUT after their clk_mem edge; WE
//   (an ODDR) T_WE after its edge; the data bus output enable (one fabric
//   register for all 16 pins, the framework has a single direction bit)
//   T_DIR after it; read data reaches the FPGA's input registers T_BACK
//   after it leaves the SRAM.
// * Reads: the SRAM drives the bus while CE and OE are low, WE is high and a
//   byte is enabled (T_LZ* after, until T_HZ* after that ends). Data is
//   valid T_AA after the address changes (and T_DOE after OE falls, T_BA
//   after a byte enable falls, T_AA after WE rises); the previous data is
//   held for T_OHA after an address change, then the bus carries garbage
//   until the new data is valid, so a controller that samples too early
//   reads wrong data. Disabled byte lanes read as garbage.
// * Writes end when WE rises (CE and the byte enables stay low through
//   them). Checked: WE pulse width (T_PWE with OE high, T_PWE2 with OE low),
//   address valid to the end of the write (T_AW), write data valid before
//   the end of the write (T_SD), no address or byte enable change while WE
//   is low, the FPGA driving the data bus when the write ends, and bus
//   contention (the FPGA's outputs on while the SRAM's are) at any time.
//   Errors are counted in `errors` and printed.
// * Every delay and timing parameter can be changed with a plusarg
//   (+sram_t_out=, +sram_t_we=, +sram_t_dir=, +sram_t_back=, +sram_t_aa=,
//   +sram_t_oha=, +sram_t_doe=, +sram_t_ba=, in ns) to run a test at other
//   corners or with a slower part.
//
// Copyright (c) 2026 Adam Polkosnik
// SPDX-License-Identifier: GPL-3.0-or-later

`timescale 1ns/1ps

module sram_model #(
	// FPGA output delays of the routed design (Vivado 2018.3, slow corner;
	// fast corner 1.4 ns for the I/O block registers and the ODDR)
	parameter real T_OUT   = 4.0,    // address, data, byte enables, OE, CE (I/O block registers, 4.05 ns)
	parameter real T_WE    = 4.0,    // WE (ODDR, 4.04 ns)
	parameter real T_DIR   = 10.5,   // data bus output enable (one fabric register for 16 pins, 10.3 ns)
	parameter real T_BACK  = 1.7,    // read data: board + FPGA input buffer
	parameter real T_AA    = 10.0,   // address access time
	parameter real T_OHA   = 2.5,    // output hold after an address change
	parameter real T_DOE   = 4.5,    // OE access time
	parameter real T_BA    = 4.5,    // byte enable access time
	parameter real T_HZOE  = 4.0,    // OE high to high-Z
	parameter real T_HZB   = 3.0,    // byte enable high to high-Z
	parameter real T_HZWE  = 5.0,    // WE low to high-Z
	parameter real T_PWE   = 8.0,    // WE pulse width, OE high
	parameter real T_PWE2  = 10.0,   // WE pulse width, OE low
	parameter real T_AW    = 8.0,    // address valid to the end of a write
	parameter real T_SD    = 6.0     // data setup to the end of a write
)(
	input              ce_n,
	input              we_n,
	input              oe_n,
	input       [ 1:0] mask_n,      // {UB#, LB#}
	input       [17:0] a,
	input       [15:0] dq_from_fpga,
	input              dq_dir,      // the FPGA drives the data bus
	output reg  [15:0] dq_to_fpga
);
	real t_out, t_we, t_dir, t_back, t_aa, t_oha, t_doe, t_ba;
	initial begin
		t_out = T_OUT; t_we = T_WE; t_dir = T_DIR; t_back = T_BACK;
		t_aa = T_AA; t_oha = T_OHA; t_doe = T_DOE; t_ba = T_BA;
		void'($value$plusargs("sram_t_out=%f", t_out));
		void'($value$plusargs("sram_t_we=%f", t_we));
		void'($value$plusargs("sram_t_dir=%f", t_dir));
		void'($value$plusargs("sram_t_back=%f", t_back));
		void'($value$plusargs("sram_t_aa=%f", t_aa));
		void'($value$plusargs("sram_t_oha=%f", t_oha));
		void'($value$plusargs("sram_t_doe=%f", t_doe));
		void'($value$plusargs("sram_t_ba=%f", t_ba));
		$display("SRAM model timing (ns): out %0.2f, we %0.2f, dir %0.2f, back %0.2f, aa %0.2f, oha %0.2f, doe %0.2f, ba %0.2f",
		         t_out, t_we, t_dir, t_back, t_aa, t_oha, t_doe, t_ba);
	end

	// the FPGA's outputs as they are at the SRAM's pins
	reg        ce_s = 1, we_s = 1, oe_s = 1, dir_s = 0;
	reg [ 1:0] mask_s = 2'b11;
	reg [17:0] a_s = '0;
	reg [15:0] d_s = '0;
	always @(ce_n)         ce_s   <= #(t_out) ce_n;
	always @(we_n)         we_s   <= #(t_we)  we_n;
	always @(oe_n)         oe_s   <= #(t_out) oe_n;
	always @(mask_n)       mask_s <= #(t_out) mask_n;
	always @(a)            a_s    <= #(t_out) a;
	always @(dq_from_fpga) d_s    <= #(t_out) dq_from_fpga;
	always @(dq_dir)       dir_s  <= #(t_dir) dq_dir;
	// inputs that never change (CE is tied low) are taken once at the start
	initial begin
		#0.001;
		ce_s = ce_n; we_s = we_n; oe_s = oe_n; mask_s = mask_n; a_s = a; d_s = dq_from_fpga; dir_s = dq_dir;
	end

	bit [15:0] mem [0:262143];
	int        errors = 0, writes = 0;
	task automatic err(input string msg);
		errors++;
		if (errors <= 50) $display("[%0t] SRAM ERROR: %s", $realtime, msg);
	endtask

	realtime t_a = 0, t_d = 0, t_we_fall = 0, t_we_rise = 0, t_oe_fall = 0, t_m_fall = 0, t_off = 0;
	reg [15:0] q = '0;       // data at the SRAM's pins
	reg        q_on = 0;     // the SRAM drives them
	bit        cond_d = 0;

	function automatic [15:0] garbage();
		return 16'hDEAD ^ a_s[15:0];
	endfunction

	task automatic eval();
		realtime now, valid;
		bit cond;
		bit [15:0] g;
		now = $realtime;
		cond = !ce_s && !oe_s && we_s && mask_s != 2'b11;
		if (cond) q_on = 1;
		else begin
			if (cond_d) t_off = now;
			if (now >= t_off + T_HZWE) q_on = 0;   // the longest of the turn-off times
		end
		cond_d = cond;
		valid = t_a + t_aa;
		if (t_oe_fall + t_doe > valid) valid = t_oe_fall + t_doe;
		if (t_m_fall + t_ba > valid) valid = t_m_fall + t_ba;
		if (t_we_rise + t_aa > valid) valid = t_we_rise + t_aa;
		g = garbage();
		if (now >= valid) q = {mask_s[1] ? g[15:8] : mem[a_s][15:8], mask_s[0] ? g[7:0] : mem[a_s][7:0]};
		else if (now >= t_a + t_oha) q = g;
		if (q_on && dir_s) err("data bus contention: the FPGA and the SRAM both drive it");
		dq_to_fpga <= #(t_back) q_on ? q : (dir_s ? d_s : 16'hFFFF);
	endtask
	task automatic eval_at(input real d);
		fork begin #(d) eval(); end join_none
	endtask

	always @(a_s) begin
		if (!we_s && !ce_s) err($sformatf("address changed while WE is low (%05h)", a_s));
		t_a = $realtime;
		eval(); eval_at(t_oha); eval_at(t_aa);
	end
	always @(d_s) t_d = $realtime;
	always @(mask_s) begin
		if (!we_s && !ce_s) err("byte enables changed while WE is low");
		if (mask_s != 2'b11) t_m_fall = $realtime;
		eval(); eval_at(t_ba); eval_at(T_HZB); eval_at(T_HZWE);
	end
	always @(oe_s) begin
		if (!oe_s) t_oe_fall = $realtime;
		eval(); eval_at(t_doe); eval_at(T_HZOE); eval_at(T_HZWE);
	end
	always @(dir_s) eval();
	always @(ce_s) eval();
	always @(negedge we_s) begin
		t_we_fall = $realtime;
		eval(); eval_at(T_HZWE);
	end
	always @(posedge we_s) begin
		realtime now;
		now = $realtime;
		if (!ce_s) begin
			if (now - t_we_fall < (oe_s ? T_PWE : T_PWE2))
				err($sformatf("WE pulse %0.2f ns (minimum %0.1f)", now - t_we_fall, oe_s ? T_PWE : T_PWE2));
			if (now - t_a < T_AW) err($sformatf("address valid %0.2f ns before the end of the write (minimum %0.1f)", now - t_a, T_AW));
			if (now - t_d < T_SD) err($sformatf("write data valid %0.2f ns before the end of the write (minimum %0.1f)", now - t_d, T_SD));
			if (!dir_s) err("the FPGA does not drive the data bus at the end of a write");
			if (mask_s == 2'b11) err("write with both byte enables off");
			if (!mask_s[1]) mem[a_s][15:8] = d_s[15:8];
			if (!mask_s[0]) mem[a_s][ 7:0] = d_s[ 7:0];
			writes++;
		end
		t_we_rise = now;
		eval(); eval_at(t_aa);
	end
endmodule
